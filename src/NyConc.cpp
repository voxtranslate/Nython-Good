// ─────────────────────────────────────────────────────────────────────────────
// NyConc.cpp — concurrency runtime shared by the interpreter and the VM.
// See include/NyConc.hpp for the model. Sections:
//   1. runtime state, errors, handles
//   2. GIL
//   3. threads: registry, start/finish, the generic blocking wait
//   4. deadlock detection (wait-for graph) and lock-order validation
//   5. async event loop core (tasks are coroutines on the loop's thread)
//   6. primitives: mutex, rwlock, condition, semaphore, event, barrier, latch,
//      atomics, channels/queues + select, futures, pool, timer, task group
//   7. async: coroutines, tasks, await, gather, wait_for
//   8. builtin dispatch table
//   9. signals and I/O waits (round 77)
// ─────────────────────────────────────────────────────────────────────────────
#include "NyConc.hpp"
#include "NyCoro.hpp"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <csignal>
#ifdef _WIN32
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <winsock2.h>
#  include <windows.h>
#else
#  include <fcntl.h>
#  include <sys/time.h>
#  include <poll.h>
#  include <unistd.h>
#endif

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <new>
#include <set>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <unordered_set>

namespace nyconc {

using Clock = std::chrono::steady_clock;
using TP = Clock::time_point;
using WQ = std::vector<struct ThreadRec*>;

// ════════════════════════════════════════════════════════════════════════════
// 1. Runtime state, errors, handles
// ════════════════════════════════════════════════════════════════════════════

[[noreturn]] static void raise(const std::string& type, const std::string& msg) {
    throw NyError::make(type, msg);
}

// A builtin that a signal interrupts is run again once the handlers have
// run (dispatch); the deadline it computed the first time is kept, so a
// timeout counts from the original call (PEP 475).
struct DeadlineMemo { bool on = false, have = false, reuse = false; TP tp{}; };
static thread_local DeadlineMemo t_dl;

struct Deadline {
    bool finite = false; TP tp{};
    static Deadline never() { return Deadline(); }
    // ms < 0: wait forever; ms >= 0: finite (0 = do not wait).
    static Deadline in_ms(double ms) {
        Deadline d; if (ms < 0) return d;
        d.finite = true;
        if (t_dl.on && t_dl.reuse && t_dl.have) { d.tp = t_dl.tp; return d; }
        d.tp = Clock::now() + std::chrono::microseconds((long long)(ms * 1000.0));
        if (t_dl.on && !t_dl.have) { t_dl.have = true; t_dl.tp = d.tp; }
        return d;
    }
    bool expired() const { return finite && Clock::now() >= tp; }
};

// ── signals: what the C handler touches (section 9 has the rest) ────────────
std::atomic<int> g_sig_any{0};
static constexpr int kMaxSig = 65;
static std::atomic<int> g_sig_flags[kMaxSig];
static std::atomic<bool> g_sig_armed{false};   // a handler of ours is installed
static std::thread::id& main_tid() { static std::thread::id id = std::this_thread::get_id(); return id; }
static const bool g_main_tid_set = (main_tid(), true);   // captured at load, on the main thread
bool is_main_thread() { return std::this_thread::get_id() == main_tid(); }
// The main thread wakes from a lock/queue/join wait at least this often to
// see a signal (a condition variable cannot wait on the self-pipe).
static const auto kSignalSlice = std::chrono::milliseconds(50);
static bool sig_watch() { return g_sig_armed.load(std::memory_order_relaxed) && is_main_thread(); }
static NyError signal_interrupt() { return NyError::make("__signal__", ""); }

struct ThreadRec;
// Something a thread can wait for that has owner threads: the edges of the
// wait-for graph used by deadlock detection.
struct Waitable {
    virtual ~Waitable() = default;
    virtual void owners(std::vector<ThreadRec*>& out) const = 0;
    virtual std::string describe() const = 0;
};

struct Obj {
    int64_t id = 0;
    virtual ~Obj() = default;
};

struct Task;
struct Loop;

struct ThreadRec : Waitable {
    int64_t id = 0;
    std::string name;
    bool is_main = false, daemon = false, detached = false, native = false;
    Engine* engine = nullptr;
    void* estate = nullptr;
    // lifecycle / outcome
    bool started = false, done = false, failed = false, joined = false, reported = false;
    BoxPtr result;
    NyError error;
    // cancellation
    bool cancel_requested = false;
    bool cancel_sticky = true;      // threads: every checkpoint raises; tasks: once
    // blocking state (all guarded by the runtime mutex)
    std::condition_variable cv;
    bool blocking = false, blocked_forever = false, woken = false;
    const Waitable* waiting_on = nullptr;
    bool cond_signaled = false;
    std::vector<int64_t> held;      // lock ids held, in acquisition order
    std::unordered_map<std::string, BoxPtr> tls;
    Task* task = nullptr;           // non-null for an async task's thread
    int64_t group = 0;              // task group, if spawned into one
    WQ joiners;                     // threads waiting for this one to finish

    void owners(std::vector<ThreadRec*>& out) const override {
        if (!done) out.push_back(const_cast<ThreadRec*>(this));
    }
    std::string describe() const override { return "thread '" + name + "' to finish"; }
    std::string label() const { return "'" + name + "'"; }
};

struct Runtime {
    std::mutex m;                                  // the runtime mutex ("CM")
    int64_t next_id = 1;
    uint64_t seq = 0;                              // completion order counter
    std::unordered_map<int64_t, std::shared_ptr<ThreadRec>> threads;
    std::set<ThreadRec*> live;
    std::unordered_map<int64_t, std::shared_ptr<Obj>> objs;
    int64_t next_async_id = (int64_t)1 << 40;      // coroutines/tasks/awaitables
    int64_t main_id = 0;
    // lock-order validation (lockdep)
    bool lockdep = false;
    std::map<int64_t, std::set<int64_t>> order;    // a -> {b}: a was held when b was taken
    std::vector<int64_t> pools;                    // for shutdown at exit
    int thread_counter = 0;
};
// Deliberately leaked: threads (daemons, parked tasks) may still reference it
// while the process exits, so it must never be destroyed.
static Runtime& RT() { static Runtime* r = new Runtime(); return *r; }

template <class T>
static T* get_obj(int64_t h, const char* what) {
    auto& rt = RT();
    auto it = rt.objs.find(h);
    T* p = it == rt.objs.end() ? nullptr : dynamic_cast<T*>(it->second.get());
    if (!p) raise("ValueError", std::string("invalid ") + what + " handle " + std::to_string(h));
    return p;
}
template <class T>
static int64_t add_obj(std::shared_ptr<T> o, bool async_range = false) {
    auto& rt = RT();
    int64_t id = async_range ? rt.next_async_id++ : rt.next_id++;
    o->id = id;
    rt.objs[id] = o;
    return id;
}

// ════════════════════════════════════════════════════════════════════════════
// 2. GIL — FIFO ticket lock with a switch interval
// ════════════════════════════════════════════════════════════════════════════

std::atomic<int> g_gil_waiters{0};
// Times a thread went to sleep: queued for the GIL, or blocked on a lock,
// condition, queue, join, ... (thread_wait_count()).
static std::atomic<int64_t> g_waits{0};
static std::atomic<bool> g_active{false};
static const auto kSwitchInterval = std::chrono::milliseconds(5);

struct Gil {
    std::mutex m;
    std::condition_variable cv;
    uint64_t next_ticket = 0, serving = 0;
    ThreadRec* owner = nullptr;
    TP since{};
};
static Gil& G() { static Gil* g = new Gil(); return *g; }

static thread_local ThreadRec* t_self = nullptr;
static thread_local bool t_holds = false;
static thread_local unsigned t_tick = 0;
static thread_local bool t_async_token = false;   // run the next async body

bool active() { return g_active.load(std::memory_order_acquire); }
bool holds_gil() { return !g_active.load(std::memory_order_acquire) || t_holds; }

static void gil_acquire() {
    auto& g = G();
    {
        std::unique_lock<std::mutex> l(g.m);
        uint64_t my = g.next_ticket++;
        if (my != g.serving) {
            g_waits.fetch_add(1, std::memory_order_relaxed);
            g_gil_waiters.fetch_add(1, std::memory_order_relaxed);
            g.cv.wait(l, [&] { return g.serving == my; });
            g_gil_waiters.fetch_sub(1, std::memory_order_relaxed);
        }
        g.owner = t_self;
        g.since = Clock::now();
    }
    t_holds = true;
    if (t_self && t_self->engine) t_self->engine->swap_in(t_self->estate);
}

static void gil_release() {
    auto& g = G();
    if (t_self && t_self->engine) t_self->engine->swap_out(t_self->estate);
    t_holds = false;
    {
        std::lock_guard<std::mutex> l(g.m);
        g.owner = nullptr;
        g.serving++;
    }
    g.cv.notify_all();
}

void tick_slow() {
    if (!t_holds) return;
    if ((++t_tick & 15u) != 0) return;
    auto held_for = Clock::now() - G().since;
    if (held_for < kSwitchInterval) return;
    // Lock-holder preemption (the problem paravirtualised spinlocks and
    // Linux's time-slice extension address for vCPUs and threads): handing
    // the GIL over while this thread holds a Nython lock makes every thread
    // that wants that lock block on it, after which each lock operation is an
    // OS context switch - a convoy (8 threads x 10k lock/unlock: 625k context
    // switches, 6 s; 20 s and more under Wine). So while a lock is held the
    // hand-over waits for its release (held_erase makes the next tick check
    // again), for at most one more switch interval, so a thread that keeps a
    // lock for long still lets the others run.
    if (t_self && !t_self->held.empty() && held_for < 2 * kSwitchInterval) return;
    // Hand over: the ticket queue puts us behind every waiting thread.
    gil_release();
    gil_acquire();
}

GilRelease::GilRelease() {
    if (g_active.load(std::memory_order_acquire) && t_holds) { gil_release(); released = true; }
}
GilRelease::~GilRelease() { if (released) gil_acquire(); }

// ════════════════════════════════════════════════════════════════════════════
// 3. Threads
// ════════════════════════════════════════════════════════════════════════════

static std::string error_text(const NyError& e) {
    if (!e.type.empty()) return e.type + ": " + e.msg;
    std::string r = e.raw;
    if (r.rfind("__exc__:", 0) == 0) {
        r = r.substr(8);
        auto c = r.find(':');
        if (c != std::string::npos) {
            std::string rest = r.substr(c + 1);
            if (rest.rfind("__obj__:", 0) == 0) rest = "<exception object>";
            r = r.substr(0, c) + ": " + rest;
        }
    }
    return r;
}
static bool is_cancel_error(const NyError& e) {
    if (e.type == "CancelledError") return true;
    // Re-raised by user code: the interpreter's `except e: raise e` keeps only
    // the message, so also recognise the runtime's own wording.
    return e.raw.find("CancelledError") != std::string::npos ||
           e.raw.find(" was cancelled") != std::string::npos;
}

// The record for the calling OS thread, created on first use (the main thread,
// or any thread that reaches the runtime without having been started by it).
static ThreadRec* current(Engine& e) {
    if (t_self) return t_self;
    auto rec = std::make_shared<ThreadRec>();
    auto& rt = RT();
    {
        std::lock_guard<std::mutex> l(rt.m);
        rec->id = rt.next_id++;
        rec->is_main = rt.main_id == 0;
        if (rec->is_main) rt.main_id = rec->id;
        rec->name = rec->is_main ? "MainThread" : "Thread-" + std::to_string(++rt.thread_counter);
        rec->engine = &e;
        rec->estate = e.state_new();
        rec->started = true;
        rt.threads[rec->id] = rec;
        rt.live.insert(rec.get());
    }
    t_self = rec.get();
    return t_self;
}

// Switch the GIL on. Called by whatever creates the first extra thread, which
// is — necessarily — the only thread running engine code at that moment.
static void ensure_active(Engine& e) {
    current(e);
    e.on_thread_start();
    if (g_active.load(std::memory_order_acquire)) return;
    auto& g = G();
    {
        std::lock_guard<std::mutex> l(g.m);
        g.serving = 0; g.next_ticket = 1;
        g.owner = t_self; g.since = Clock::now();
    }
    t_holds = true;
    g_active.store(true, std::memory_order_release);
}

// Wake a waiter. For a plain thread: notify its condition variable. For an
// async task: put it on its loop's ready queue *now*, under the runtime mutex,
// so the order in which tasks resume is decided by the program, not by the OS.
static void make_ready(Task* t);
static void wake(ThreadRec* t) {
    t->woken = true;
    t->blocked_forever = false;
    if (t->task) make_ready(t->task);
    else t->cv.notify_all();
}
static void wake_all(WQ& q) {
    WQ copy = q;                         // wakers may re-register while we iterate
    for (auto* t : copy) wake(t);
}

static void check_cancel_locked(ThreadRec* self) {
    if (self->cancel_requested) {
        if (!self->cancel_sticky) self->cancel_requested = false;
        raise("CancelledError", "thread " + self->label() + " was cancelled");
    }
}

static void check_deadlock_locked(ThreadRec* self, const Waitable* on);
static void check_all_blocked_locked(ThreadRec* self);
static void task_park(std::unique_lock<std::mutex>& lk, ThreadRec* self, const Deadline& dl);

// The one blocking wait every primitive goes through. Called with the runtime
// mutex held (via `lk`) and the GIL released. `pred` runs under the runtime
// mutex and may consume the resource when it returns true. Returns false on
// timeout; throws CancelledError / DeadlockError.
static bool block(std::unique_lock<std::mutex>& lk, ThreadRec* self,
                  std::initializer_list<WQ*> qs, const std::function<bool()>& pred,
                  const Deadline& dl, const Waitable* on, bool cancellable = true) {
    if (pred()) return true;
    if (cancellable) check_cancel_locked(self);
    if (dl.expired()) return false;
    if (on && !dl.finite) check_deadlock_locked(self, on);
    std::vector<WQ*> regs(qs.begin(), qs.end());
    for (auto* q : regs) q->push_back(self);
    self->blocking = true;
    self->waiting_on = on;
    self->blocked_forever = !dl.finite;
    struct Unreg {
        ThreadRec* s; std::vector<WQ*>& r;
        ~Unreg() {
            for (auto* q : r) { auto it = std::find(q->begin(), q->end(), s); if (it != q->end()) q->erase(it); }
            s->blocking = false; s->waiting_on = nullptr; s->blocked_forever = false;
        }
    } unreg{self, regs};
    if (self->blocked_forever) check_all_blocked_locked(self);
    // A thread goes to sleep; a task only switches back to its loop.
    if (!self->task) g_waits.fetch_add(1, std::memory_order_relaxed);
    const bool watch = !self->task && sig_watch();
    while (true) {
        self->woken = false;
        if (watch && g_sig_any.load(std::memory_order_acquire)) throw signal_interrupt();
        if (self->task) task_park(lk, self, dl);
        else if (watch) {
            TP until = Clock::now() + kSignalSlice;
            if (dl.finite && dl.tp < until) until = dl.tp;
            self->cv.wait_until(lk, until);
        }
        else if (dl.finite) self->cv.wait_until(lk, dl.tp);
        else self->cv.wait(lk);
        if (pred()) return true;
        if (cancellable && self->cancel_requested) check_cancel_locked(self);
        if (dl.expired()) return false;
        self->blocked_forever = !dl.finite;
    }
}

// Release the GIL, then block. The fast path (pred already true) must have
// been tried by the caller while it still held the GIL.
static bool block_released(ThreadRec* self, std::initializer_list<WQ*> qs,
                           const std::function<bool()>& pred, const Deadline& dl,
                           const Waitable* on, bool cancellable = true) {
    GilRelease rel;
    std::unique_lock<std::mutex> lk(RT().m);
    return block(lk, self, qs, pred, dl, on, cancellable);
}

static void finish_group_child(ThreadRec* rec);

// A thread ends: publish the outcome and wake whoever waits for it.
static void finish_thread_locked(ThreadRec* rec, const BoxPtr& res, bool failed, const NyError& err) {
    rec->done = true;
    rec->result = res;
    rec->failed = failed;
    rec->error = err;
    RT().live.erase(rec);
    wake_all(rec->joiners);
    if (rec->group) finish_group_child(rec);
}

static void report_thread_error(ThreadRec* rec) {
    if (rec->reported) return;
    rec->reported = true;
    std::cerr << "Exception in thread " << rec->label() << ": " << error_text(rec->error) << std::endl;
}

using Body = std::function<BoxPtr(ThreadRec*)>;

static std::shared_ptr<ThreadRec> new_thread_rec(Engine& e, const std::string& name, bool daemon) {
    auto rec = std::make_shared<ThreadRec>();
    auto& rt = RT();
    rec->id = rt.next_id++;
    rec->name = name.empty() ? "Thread-" + std::to_string(++rt.thread_counter) : name;
    rec->daemon = daemon;
    rec->engine = &e;
    rt.threads[rec->id] = rec;
    rt.live.insert(rec.get());
    return rec;
}

static void launch(std::shared_ptr<ThreadRec> rec, Body body);

// Start an engine thread running `body` (with the GIL held). Called with the
// GIL held and the runtime mutex NOT held.
static int64_t start_thread(Engine& e, Body body, const std::string& name, bool daemon,
                            int64_t group = 0, bool cancelled_at_start = false) {
    ensure_active(e);
    std::shared_ptr<ThreadRec> rec;
    {
        std::lock_guard<std::mutex> l(RT().m);
        rec = new_thread_rec(e, name, daemon);
        rec->group = group;
        rec->cancel_requested = cancelled_at_start;
    }
    rec->estate = e.state_new();
    launch(rec, std::move(body));
    return rec->id;
}

static void launch(std::shared_ptr<ThreadRec> rec, Body body) {
    std::thread th([rec, body]() mutable {
        t_self = rec.get();
        gil_acquire();
        rec->started = true;
        BoxPtr res; bool failed = false; NyError err;
        try { res = body(rec.get()); }
        catch (NyError& x) { failed = true; err = x; }
        catch (std::exception& x) { failed = true; err = NyError::make("RuntimeError", x.what()); }
        catch (...) { failed = true; err = NyError::make("RuntimeError", "unknown error in thread"); }
        body = nullptr;               // release the captured engine values with the GIL held
        bool report = false;
        {
            std::lock_guard<std::mutex> l(RT().m);
            finish_thread_locked(rec.get(), res, failed, err);
            report = failed && rec->detached;
        }
        if (report) report_thread_error(rec.get());
        gil_release();
        if (rec->engine) rec->engine->state_free(rec->estate);
        rec->estate = nullptr;
    });
    th.detach();
}

static ThreadRec* get_thread_locked(int64_t h) {
    auto& rt = RT();
    auto it = rt.threads.find(h);
    if (it == rt.threads.end()) raise("ValueError", "invalid thread handle " + std::to_string(h));
    return it->second.get();
}

// Join: wait for the thread; return its result or re-raise its exception.
static BoxPtr join_thread(Engine& e, int64_t h, double timeout_ms) {
    ThreadRec* self = current(e);
    ThreadRec* t;
    {
        std::lock_guard<std::mutex> l(RT().m);
        t = get_thread_locked(h);
        if (t == self) raise("DeadlockError", "deadlock: thread " + self->label() + " cannot join itself");
        if (t->detached) raise("RuntimeError", "cannot join detached thread " + t->label());
        if (t->task) raise("RuntimeError", "cannot join an async task's thread; await the task");
    }
    bool ok;
    {
        std::unique_lock<std::mutex> lk(RT().m);
        if (t->done) ok = true;
        else {
            lk.unlock();
            ok = block_released(self, {&t->joiners}, [t] { return t->done; }, Deadline::in_ms(timeout_ms), t);
        }
    }
    if (!ok) raise("TimeoutError", "thread_join: thread " + t->label() + " still running after " +
                   std::to_string((long long)timeout_ms) + " ms");
    std::lock_guard<std::mutex> l(RT().m);
    t->joined = true;
    if (t->failed) { t->reported = true; throw t->error; }
    return t->result ? t->result : e.box_none();
}

// ════════════════════════════════════════════════════════════════════════════
// 4. Deadlock detection and lock-order validation
// ════════════════════════════════════════════════════════════════════════════

// Before `self` blocks forever on `on`: follow the owners of `on`, then what
// each owner is itself blocked on, and so on. Reaching `self` again means the
// wait can never end — raise instead of hanging.
static void check_deadlock_locked(ThreadRec* self, const Waitable* on) {
    struct Step { ThreadRec* t; const Waitable* w; ThreadRec* owner; };
    std::vector<Step> path;
    std::unordered_set<ThreadRec*> seen;
    std::function<bool(ThreadRec*, const Waitable*)> dfs = [&](ThreadRec* t, const Waitable* w) -> bool {
        std::vector<ThreadRec*> own;
        w->owners(own);
        for (auto* o : own) {
            path.push_back({t, w, o});
            if (o == self) return true;
            if (!seen.count(o) && o->blocking && o->blocked_forever && o->waiting_on) {
                seen.insert(o);
                if (dfs(o, o->waiting_on)) return true;
            }
            path.pop_back();
        }
        return false;
    };
    if (!dfs(self, on)) return;
    std::string msg = "deadlock detected: ";
    for (size_t i = 0; i < path.size(); i++) {
        if (i) msg += "; ";
        auto& s = path[i];
        if (s.w == s.owner) msg += "thread " + s.t->label() + " waits for " + s.w->describe();
        else msg += "thread " + s.t->label() + " waits for " + s.w->describe() + " held by " + s.owner->label();
    }
    raise("DeadlockError", msg);
}

// `self` is about to block with no timeout. If every other live thread is
// already blocked with no timeout, nothing can ever wake anyone.
static bool signals_can_wake();   // section 9
static void check_all_blocked_locked(ThreadRec* self) {
    auto& rt = RT();
    // A program with a signal handler or a signal channel of its own may be
    // woken by a signal: every thread blocked is then not a deadlock (the
    // default Ctrl+C handler does not count - it only ends the program).
    if (signals_can_wake()) return;
    std::string who;
    for (auto* t : rt.live) {
        if (t == self || t->done) continue;
        if (!t->blocking || !t->blocked_forever) return;
        who += (who.empty() ? "" : "; ") + t->label() + " waits for " +
               (t->waiting_on ? t->waiting_on->describe() : std::string("a wake-up"));
    }
    std::string mine = self->waiting_on ? self->waiting_on->describe() : std::string("a wake-up");
    raise("DeadlockError", "deadlock detected: all threads are blocked (" + self->label() + " waits for " +
          mine + (who.empty() ? "" : "; " + who) + ")");
}

static bool order_path(int64_t from, int64_t to, std::set<int64_t>& seen) {
    if (from == to) return true;
    if (!seen.insert(from).second) return false;
    auto it = RT().order.find(from);
    if (it == RT().order.end()) return false;
    for (auto n : it->second) if (order_path(n, to, seen)) return true;
    return false;
}
static std::string lock_name(int64_t id);

// lockdep: taking `id` while holding H. An earlier observed order id -> ... -> h
// means two threads could deadlock even if they did not this time.
static void lockdep_check_locked(ThreadRec* self, int64_t id) {
    auto& rt = RT();
    if (!rt.lockdep) return;
    for (auto h : self->held) {
        if (h == id) continue;
        std::set<int64_t> seen;
        if (order_path(id, h, seen))
            raise("LockOrderError", "lock order inversion: " + lock_name(h) + " is held while taking " +
                  lock_name(id) + ", but " + lock_name(id) + " was taken before " + lock_name(h) + " earlier");
    }
}
static void lockdep_note_locked(ThreadRec* self, int64_t id) {
    auto& rt = RT();
    if (rt.lockdep) for (auto h : self->held) if (h != id) rt.order[h].insert(id);
    self->held.push_back(id);
}
static void held_erase(ThreadRec* self, int64_t id) {
    for (auto it = self->held.rbegin(); it != self->held.rend(); ++it)
        if (*it == id) {
            self->held.erase(std::next(it).base());
            // Its last lock released: a GIL hand-over tick_slow deferred for
            // it happens at the next tick, not up to 16 ticks later.
            if (self->held.empty() && self == t_self) t_tick |= 15u;
            return;
        }
}

// ════════════════════════════════════════════════════════════════════════════
// 5. Async event loop core
// ════════════════════════════════════════════════════════════════════════════

// An async task is a coroutine (NyCoro.hpp) on the thread that runs its
// loop, not a thread of its own. Starting one maps a stack (or takes one from
// the pool) instead of creating an OS thread, and switching between tasks is
// a stack switch on that thread instead of handing a baton between threads
// through the GIL's queue - each switch used to put one thread to sleep and
// wake another. Everything else is unchanged: a task still has a ThreadRec
// (its id, its locals, its place in the wait-for graph), every blocking
// primitive still goes through block(), and a blocked task gives control
// back to its loop there (task_park), so a task waiting on a thread's mutex,
// queue or join lets the loop's other tasks run.
//
// At every switch the thread holds the GIL and not the runtime mutex, and
// the engine state (Engine::swap_in/swap_out: the VM's stacks, the
// interpreter's call depth, control flow and exception stack) moves with
// it: switch_state.
struct Task : Obj {
    Loop* loop = nullptr;
    Engine* engine = nullptr;
    std::shared_ptr<ThreadRec> thr;
    nycoro::Coro* co = nullptr;              // its stack, from the first grant until it finishes
    bool in_ready = false, started = false;
    bool done = false, cancelled = false, failed = false;
    bool cancel_before_start = false;
    BoxPtr result; NyError err;
    WQ wq;                                   // awaiters
    uint64_t done_seq = 0;
    std::string name;
    std::function<BoxPtr(Engine&)> entry;    // runs on the task's coroutine, GIL held
    bool timer_set = false;
    std::multimap<std::pair<TP, uint64_t>, Task*>::iterator timer_it;
};

// A task waiting for a socket or pipe to be ready (wait_io, section 9).
struct IoWait {
    Task* task = nullptr;
    intptr_t fd = -1;
    int events = 0;          // IO_READ | IO_WRITE
    int revents = 0;         // what poll() reported; 0 while waiting
};

struct Loop {
    std::deque<Task*> ready;
    std::multimap<std::pair<TP, uint64_t>, Task*> timers;
    Task* current = nullptr;
    ThreadRec* thread = nullptr;
    std::vector<std::shared_ptr<Task>> tasks;
    uint64_t seq = 0;
    std::condition_variable cv;              // wakes an idle loop (another thread made a task ready)
    // The I/O reactor (round 77): tasks blocked on a socket wait here, and
    // the loop polls their descriptors when nothing is ready instead of
    // sleeping on cv. A ready task from another thread interrupts the poll
    // through the wake pipe.
    std::vector<IoWait*> io;
    bool polling = false;
#ifndef _WIN32
    int wake_r = -1, wake_w = -1;
#endif
    ~Loop() {
#ifndef _WIN32
        if (wake_r >= 0) { ::close(wake_r); ::close(wake_w); }
#endif
    }
};

static void loop_wake_poll(Loop* L) {
#ifndef _WIN32
    if (L->polling && L->wake_w >= 0) { char c = 1; ssize_t r = ::write(L->wake_w, &c, 1); (void)r; }
#else
    (void)L;   // a polling Windows loop wakes every 10 ms (WSAPoll cannot wait on an event)
#endif
}

static void make_ready(Task* t) {
    Loop* L = t->loop;
    if (!L || t->done || t->in_ready || L->current == t) return;
    L->ready.push_back(t);
    t->in_ready = true;
    if (t->thr) { t->thr->blocked_forever = false; }
    if (L->thread) L->thread->blocked_forever = false;
    L->cv.notify_all();
    loop_wake_poll(L);
}

// The stack a task runs on: the generators' (NY_GEN_STACK_KB, 1 MB) on a
// 64-bit system, 256 KB on a 32-bit one, where 2000 tasks of 1 MB would use
// the whole 2 GB address space. A call that finds it nearly used continues on
// an extension stack, on both engines (nygen::call_on_new_stack, the VM's
// run_frame), so a task still recurses as deep as a thread.
static size_t task_stack_size() {
    if (sizeof(void*) >= 8) return nycoro::default_stack_size();
    return std::min<size_t>(nycoro::default_stack_size(), (size_t)256 << 10);
}

// Move the engine's per-thread state and the runtime's notion of "this
// thread" from one record to another. GIL held.
static void switch_state(ThreadRec* from, ThreadRec* to) {
    if (from->engine) from->engine->swap_out(from->estate);
    t_self = to;
    if (to->engine) to->engine->swap_in(to->estate);
}

// A task blocked inside a generator body (the interpreter runs each on a
// coroutine of its own, nested in the task's): it leaves through every
// coroutine it is nested in. relay asks the resumer to step out too.
static thread_local bool t_relay = false;

// Give control back to the loop, from the task's own stack or from a
// coroutine nested in it. GIL held, runtime mutex not held. Returns when the
// loop runs the task again.
static void task_switch_out(ThreadRec* self) {
    Task* T = self->task;
    if (nycoro::current() != T->co) {
        t_relay = true;
        nycoro::suspend();          // to the generator layer, which relays and resumes us
        return;
    }
    switch_state(self, T->loop->thread);
    nycoro::suspend();              // grant() switched our state back in
}

bool relay_requested() {
    bool r = t_relay;
    t_relay = false;
    return r;
}
void relay_park() { task_switch_out(t_self); }

// A task gives control back to its loop until the loop runs it again
// (because it was made ready, or its timer fired). Called from block() with
// the runtime mutex held and the GIL released; returns the same way.
static void task_park(std::unique_lock<std::mutex>& lk, ThreadRec* self, const Deadline& dl) {
    Task* T = self->task;
    Loop* L = T->loop;
    if (dl.finite) {
        T->timer_it = L->timers.emplace(std::make_pair(dl.tp, ++L->seq), T);
        T->timer_set = true;
    }
    // Not current any more: a wake from another thread from here on queues
    // it (it is run once it has switched out).
    if (L->current == T) L->current = nullptr;
    lk.unlock();
    gil_acquire();
    task_switch_out(self);
    gil_release();
    lk.lock();
    if (T->timer_set) { L->timers.erase(T->timer_it); T->timer_set = false; }
}

// ════════════════════════════════════════════════════════════════════════════
// 6. Primitives
// ════════════════════════════════════════════════════════════════════════════

struct Mutex : Obj, Waitable {
    bool recursive = false;
    ThreadRec* owner = nullptr;
    int count = 0;
    WQ wq;
    ThreadRec* heir = nullptr;      // the waiter woken to compete for it (mutex_wake_heir)
    void owners(std::vector<ThreadRec*>& out) const override { if (owner) out.push_back(owner); }
    std::string describe() const override { return (recursive ? "rmutex#" : "mutex#") + std::to_string(id); }
};

struct RWLock : Obj {
    ThreadRec* writer = nullptr;
    std::multiset<ThreadRec*> readers;
    int waiting_writers = 0;
    WQ rq, wq;                      // waiting readers, waiting writers
    ThreadRec* heir = nullptr;      // the writer woken to compete for it (rw_wake)
};
struct RWWait : Waitable {
    RWLock* rw; bool write;
    RWWait(RWLock* r, bool w) : rw(r), write(w) {}
    void owners(std::vector<ThreadRec*>& out) const override {
        if (rw->writer) out.push_back(rw->writer);
        if (write) for (auto* r : rw->readers) out.push_back(r);
    }
    std::string describe() const override { return "rwlock#" + std::to_string(rw->id) + (write ? " (write)" : " (read)"); }
};

static std::string lock_name(int64_t id) {
    auto it = RT().objs.find(id);
    if (it != RT().objs.end()) {
        if (auto* m = dynamic_cast<Mutex*>(it->second.get())) return m->describe();
        if (dynamic_cast<RWLock*>(it->second.get())) return "rwlock#" + std::to_string(id);
    }
    return "lock#" + std::to_string(id);
}

struct Cond : Obj { std::deque<ThreadRec*> waiters; };
struct Sema : Obj { int64_t count = 0, max = -1; WQ wq; };
struct Event : Obj { bool flag = false; WQ wq; };
struct Barrier : Obj { int64_t n = 1, count = 0, gen = 0; WQ wq; };
struct Latch : Obj { int64_t count = 0; WQ wq; };
struct Atom : Obj { int64_t v = 0; };

// ── mutex ───────────────────────────────────────────────────────────────────
// Competitive succession, as HotSpot's monitors, Windows' critical sections
// (since Vista) and futex-based mutexes do it: a released mutex is not handed
// to a sleeping waiter. Handing it over makes the new owner a thread that
// must first wait for the GIL, so the releasing thread - still running -
// blocks on its next lock, and from then on every lock operation is a thread
// switch: a convoy that, once formed, never dissolves (8 threads x 10k
// lock/unlock went from 0.8 s to 6 s whenever one formed). Instead one
// waiter, the heir, is woken and competes for the mutex once it runs again
// with the GIL; while an heir is awake no other waiter is woken, so a thread
// that locks and unlocks in a loop does not wake anyone in vain.
static void mutex_wake_heir(Mutex* m) {
    if (m->heir || m->owner || m->wq.empty()) return;
    m->heir = m->wq.front();
    wake(m->heir);
}
// The heir gave up (timed out, cancelled): pass the wake-up on.
static void mutex_heir_quit(Mutex* m, ThreadRec* self) {
    if (m->heir != self) return;
    m->heir = nullptr;
    mutex_wake_heir(m);
}
static bool mutex_acquire(Engine& e, int64_t h, double timeout_ms) {
    ThreadRec* self = current(e);
    const Deadline dl = Deadline::in_ms(timeout_ms);
    while (true) {
        Mutex* m;
        {
            std::lock_guard<std::mutex> l(RT().m);
            m = get_obj<Mutex>(h, "mutex");
            try {
                if (m->owner == self) {
                    if (m->recursive) { m->count++; return true; }
                    raise("DeadlockError", "deadlock detected: thread " + self->label() + " tried to lock " +
                          m->describe() + ", which it already holds (not recursive)");
                }
                check_cancel_locked(self);
                lockdep_check_locked(self, h);
            } catch (...) { mutex_heir_quit(m, self); throw; }
            if (m->heir == self) m->heir = nullptr;      // the heir competes now
            if (!m->owner) { m->owner = self; m->count = 1; lockdep_note_locked(self, h); return true; }
            if (timeout_ms == 0 || dl.expired()) return false;
        }
        bool woken;
        try {
            // Woken as the heir - or the mutex is free with no heir on the way:
            // it was released between the attempt above and this wait (the
            // GIL is released first), when there was no waiter to wake yet.
            woken = block_released(self, {&m->wq},
                [m, self] { return m->heir == self || (!m->owner && !m->heir); }, dl, m);
        } catch (...) {
            std::lock_guard<std::mutex> l(RT().m);
            mutex_heir_quit(m, self);
            throw;
        }
        if (!woken) {
            std::lock_guard<std::mutex> l(RT().m);
            mutex_heir_quit(m, self);
            return false;
        }
    }
}
static void mutex_release(Engine& e, int64_t h) {
    ThreadRec* self = current(e);
    std::lock_guard<std::mutex> l(RT().m);
    Mutex* m = get_obj<Mutex>(h, "mutex");
    if (m->owner != self)
        raise("RuntimeError", "cannot unlock " + m->describe() + ": not held by thread " + self->label());
    if (--m->count > 0) return;
    m->owner = nullptr;
    held_erase(self, h);
    mutex_wake_heir(m);
}

// ── rwlock ──────────────────────────────────────────────────────────────────
// Writers first: a reader does not take the lock while a writer waits. And
// competitive succession, as for the mutex: a released lock is not given to a
// sleeping waiter - its predicate used to take it as the waiter woke, before
// that thread had the GIL, so the lock sat with a thread that could not run
// and every other thread queued behind it (6 writers x 3000 operations: 34k
// thread sleeps). Now the lock is taken only by a running thread. When it
// becomes free, one waiting writer - the heir - is woken to compete for it
// (no other writer is woken while the heir is on its way), or, with no
// writer waiting, every waiting reader (they can all hold it at once).
static void rw_wake(RWLock* rw) {
    if (rw->writer) return;
    if (rw->waiting_writers > 0) {
        if (!rw->readers.empty() || rw->heir || rw->wq.empty()) return;
        rw->heir = rw->wq.front();
        wake(rw->heir);
        return;
    }
    wake_all(rw->rq);
}
// A woken writer gave up (timed out, cancelled): pass the wake-up on.
static void rw_heir_quit(RWLock* rw, ThreadRec* self) {
    if (rw->heir != self) return;
    rw->heir = nullptr;
    rw_wake(rw);
}
static bool rw_read_lock(Engine& e, int64_t h, double timeout_ms) {
    ThreadRec* self = current(e);
    const Deadline dl = Deadline::in_ms(timeout_ms);
    while (true) {
        RWLock* rw;
        {
            std::lock_guard<std::mutex> l(RT().m);
            rw = get_obj<RWLock>(h, "rwlock");
            if (rw->writer == self)
                raise("DeadlockError", "deadlock detected: thread " + self->label() + " holds rwlock#" +
                      std::to_string(h) + " for writing and asked to read it");
            check_cancel_locked(self);
            if (rw->readers.count(self)) { rw->readers.insert(self); return true; }   // re-entrant read
            lockdep_check_locked(self, h);
            if (!rw->writer && rw->waiting_writers == 0) { rw->readers.insert(self); lockdep_note_locked(self, h); return true; }
            if (timeout_ms == 0 || dl.expired()) return false;
        }
        RWWait w(rw, false);
        bool woken = block_released(self, {&rw->rq},
            [rw] { return !rw->writer && rw->waiting_writers == 0; }, dl, &w);
        if (!woken) return false;
    }
}
static bool rw_write_lock(Engine& e, int64_t h, double timeout_ms) {
    ThreadRec* self = current(e);
    const Deadline dl = Deadline::in_ms(timeout_ms);
    bool counted = false;           // in waiting_writers
    while (true) {
        RWLock* rw;
        {
            std::lock_guard<std::mutex> l(RT().m);
            rw = get_obj<RWLock>(h, "rwlock");
            try {
                if (rw->writer == self)
                    raise("DeadlockError", "deadlock detected: thread " + self->label() + " already holds rwlock#" +
                          std::to_string(h) + " for writing (not recursive)");
                if (rw->readers.count(self))
                    raise("DeadlockError", "deadlock detected: thread " + self->label() + " holds rwlock#" +
                          std::to_string(h) + " for reading; upgrading to write would wait for itself");
                check_cancel_locked(self);
                lockdep_check_locked(self, h);
            } catch (...) {
                if (counted) { rw->waiting_writers--; rw_heir_quit(rw, self); rw_wake(rw); }
                throw;
            }
            if (rw->heir == self) rw->heir = nullptr;      // the heir competes now
            if (!rw->writer && rw->readers.empty()) {
                rw->writer = self;
                if (counted) rw->waiting_writers--;
                lockdep_note_locked(self, h);
                return true;
            }
            if (timeout_ms == 0 || dl.expired()) {
                if (counted) { rw->waiting_writers--; rw_wake(rw); }   // readers held back by us may go
                return false;
            }
            if (!counted) { rw->waiting_writers++; counted = true; }
        }
        RWWait w(rw, true);
        bool woken;
        try {
            // Woken as the heir - or the lock is free with no heir on the way
            // (it was released between the attempt above and this wait).
            woken = block_released(self, {&rw->wq},
                [rw, self] { return rw->heir == self || (!rw->writer && rw->readers.empty() && !rw->heir); }, dl, &w);
        } catch (...) {
            std::lock_guard<std::mutex> l(RT().m);
            rw->waiting_writers--;
            rw_heir_quit(rw, self);
            rw_wake(rw);
            throw;
        }
        if (!woken) {
            std::lock_guard<std::mutex> l(RT().m);
            rw->waiting_writers--;
            rw_heir_quit(rw, self);
            rw_wake(rw);
            return false;
        }
    }
}
static void rw_unlock(Engine& e, int64_t h, bool write) {
    ThreadRec* self = current(e);
    std::lock_guard<std::mutex> l(RT().m);
    RWLock* rw = get_obj<RWLock>(h, "rwlock");
    if (write) {
        if (rw->writer != self) raise("RuntimeError", "rwlock#" + std::to_string(h) + " is not write-locked by this thread");
        rw->writer = nullptr;
        held_erase(self, h);
    } else {
        auto it = rw->readers.find(self);
        if (it == rw->readers.end()) raise("RuntimeError", "rwlock#" + std::to_string(h) + " is not read-locked by this thread");
        rw->readers.erase(it);
        if (!rw->readers.count(self)) held_erase(self, h);
    }
    rw_wake(rw);
}

// ── condition ───────────────────────────────────────────────────────────────
static bool cond_wait(Engine& e, int64_t ch, int64_t mh, double timeout_ms) {
    ThreadRec* self = current(e);
    Cond* c; Mutex* m; int saved = 0;
    {
        std::lock_guard<std::mutex> l(RT().m);
        c = get_obj<Cond>(ch, "condition");
        m = get_obj<Mutex>(mh, "mutex");
        if (m->owner != self)
            raise("RuntimeError", "cond_wait: " + m->describe() + " must be held by the waiting thread");
        check_cancel_locked(self);
        saved = m->count;
        m->owner = nullptr; m->count = 0;
        held_erase(self, mh);
        mutex_wake_heir(m);
        self->cond_signaled = false;
        c->waiters.push_back(self);
    }
    bool signaled = false;
    NyError pending; bool have_pending = false;
    {
        GilRelease rel;
        std::unique_lock<std::mutex> lk(RT().m);
        try {
            signaled = block(lk, self, {}, [self] { return self->cond_signaled; }, Deadline::in_ms(timeout_ms), nullptr);
        } catch (NyError& x) { pending = x; have_pending = true; }
        if (!signaled) {
            auto it = std::find(c->waiters.begin(), c->waiters.end(), self);
            if (it != c->waiters.end()) c->waiters.erase(it);
        }
        // Re-acquire the mutex whatever happened (as Python's Condition.wait).
        try {
            // (It takes the mutex as soon as it is free - a condition waiter
            // is woken by a notify, not in a lock loop - and as an heir that
            // finds it taken it lets the next release wake someone again.)
            block(lk, self, {&m->wq},
                  [m, self] {
                      if (m->heir == self) m->heir = nullptr;
                      if (!m->owner) { m->owner = self; return true; }
                      return false;
                  },
                  Deadline::never(), m, false);
        } catch (NyError& x) { if (!have_pending) { pending = x; have_pending = true; } }
        if (m->owner == self) { m->count = saved; self->held.push_back(mh); }
    }
    if (have_pending) throw pending;
    return signaled;
}
static int64_t cond_notify(Engine&, int64_t ch, int64_t n) {
    std::lock_guard<std::mutex> l(RT().m);
    Cond* c = get_obj<Cond>(ch, "condition");
    int64_t woke = 0;
    while (!c->waiters.empty() && (n < 0 || woke < n)) {
        ThreadRec* t = c->waiters.front();
        c->waiters.pop_front();
        t->cond_signaled = true;
        wake(t);
        woke++;
    }
    return woke;
}

// ── generic "wait until pred" for the simple primitives ─────────────────────
template <class P>
static bool simple_wait(Engine& e, WQ* q, P pred, double timeout_ms) {
    ThreadRec* self = current(e);
    {
        std::lock_guard<std::mutex> l(RT().m);
        check_cancel_locked(self);
        if (pred()) return true;
        if (timeout_ms == 0) return false;
    }
    return block_released(self, {q}, pred, Deadline::in_ms(timeout_ms), nullptr);
}

// ── channels / queues ───────────────────────────────────────────────────────
struct Chan : Obj {
    enum Kind { FIFO, LIFO, PRIO } kind = FIFO;
    int64_t cap = -1;                 // -1 unbounded, 0 rendezvous, n>0 bounded
    struct Item { BoxPtr v; double prio; uint64_t seq; };
    std::deque<Item> items;
    bool closed = false;
    uint64_t seq = 0, sent = 0, taken = 0;
    int recv_waiting = 0;
    WQ wq;
    bool can_put() const {
        if (cap < 0) return true;
        if (cap == 0) return recv_waiting > (int)items.size();
        return (int64_t)items.size() < cap;
    }
    void put(const BoxPtr& v, double prio) {
        Item it{v, prio, ++seq};
        if (kind == PRIO) {
            auto pos = std::upper_bound(items.begin(), items.end(), it, [](const Item& a, const Item& b) {
                return a.prio < b.prio || (a.prio == b.prio && a.seq < b.seq);
            });
            items.insert(pos, it);
        } else items.push_back(it);
        sent++;
        wake_all(wq);
    }
    BoxPtr take() {
        Item it;
        if (kind == LIFO) { it = items.back(); items.pop_back(); }
        else { it = items.front(); items.pop_front(); }
        taken++;
        wake_all(wq);
        return it.v;
    }
    std::string describe() const { return "channel#" + std::to_string(id); }
};

static Chan* chan_get_locked(int64_t h) { return get_obj<Chan>(h, "channel"); }

// Send. Returns false on timeout (timeout_ms >= 0) / when a try-send fails.
static bool chan_send(Engine& e, int64_t h, const BoxPtr& v, double prio, double timeout_ms) {
    ThreadRec* self = current(e);
    Chan* c;
    uint64_t ticket = 0;
    {
        std::lock_guard<std::mutex> l(RT().m);
        c = chan_get_locked(h);
        if (c->closed) raise("ChannelClosedError", "send on closed " + c->describe());
        if (timeout_ms != 0) check_cancel_locked(self);
        if (c->cap != 0 && c->can_put()) { c->put(v, prio); return true; }
        if (c->cap == 0) {
            if (timeout_ms == 0) {                       // try-send: only to a waiting receiver
                if (c->can_put()) { c->put(v, prio); return true; }
                return false;
            }
            c->put(v, prio); ticket = c->sent;          // hand over, then wait to be taken
        } else if (timeout_ms == 0) return false;
    }
    if (c->cap == 0) {
        bool ok = false; NyError err; bool thrown = false;
        try {
            ok = block_released(self, {&c->wq}, [c, ticket] { return c->taken >= ticket || c->closed; },
                                Deadline::in_ms(timeout_ms), nullptr);
        } catch (NyError& x) { err = x; thrown = true; }
        std::lock_guard<std::mutex> l(RT().m);
        if (c->taken >= ticket) return true;
        // Not taken: withdraw our item.
        for (auto it = c->items.begin(); it != c->items.end(); ++it)
            if (it->seq == ticket) { c->items.erase(it); c->sent--; break; }
        if (thrown) throw err;
        if (c->closed) raise("ChannelClosedError", "send on closed " + c->describe());
        return ok;
    }
    bool put_done = false;
    bool ok = block_released(self, {&c->wq}, [c, v, prio, &put_done] {
        if (c->closed) return true;
        if (c->can_put()) { c->put(v, prio); put_done = true; return true; }
        return false;
    }, Deadline::in_ms(timeout_ms), nullptr);
    if (ok && !put_done) raise("ChannelClosedError", "send on closed " + c->describe());
    return ok;
}

// Receive. out_ok=false when closed-and-drained or timed out.
static BoxPtr chan_recv(Engine& e, int64_t h, double timeout_ms, bool& out_ok) {
    ThreadRec* self = current(e);
    Chan* c;
    out_ok = false;
    {
        std::lock_guard<std::mutex> l(RT().m);
        c = chan_get_locked(h);
        if (timeout_ms != 0) check_cancel_locked(self);
        if (!c->items.empty()) { out_ok = true; return c->take(); }
        if (c->closed || timeout_ms == 0) return nullptr;
        c->recv_waiting++;
        wake_all(c->wq);                 // a rendezvous try-send may now succeed
    }
    BoxPtr got;
    struct Dec { Chan* c; ~Dec() { std::lock_guard<std::mutex> l(RT().m); c->recv_waiting--; } } dec{c};
    block_released(self, {&c->wq}, [c, &got, &out_ok] {
        if (!c->items.empty()) { got = c->take(); out_ok = true; return true; }
        return c->closed;
    }, Deadline::in_ms(timeout_ms), nullptr);
    return got;
}

struct SelCase { bool send; Chan* c; BoxPtr v; double prio; };

// Go's select: first ready case in list order (deterministic), or -1 on
// timeout / when nothing is ready and timeout_ms == 0 (the `default` case).
static int chan_select(Engine& e, std::vector<std::pair<bool, int64_t>> spec, std::vector<BoxPtr> vals,
                       std::vector<double> prios, double timeout_ms, BoxPtr& out_v, bool& out_ok) {
    ThreadRec* self = current(e);
    std::vector<SelCase> cs;
    out_ok = false;
    int chosen = -1;
    auto try_cases = [&]() -> bool {
        for (size_t i = 0; i < cs.size(); i++) {
            auto& k = cs[i];
            if (k.send) {
                if (k.c->closed) raise("ChannelClosedError", "select: send on closed " + k.c->describe());
                if (k.c->can_put()) { k.c->put(k.v, k.prio); chosen = (int)i; out_ok = true; return true; }
            } else {
                if (!k.c->items.empty()) { out_v = k.c->take(); out_ok = true; chosen = (int)i; return true; }
                if (k.c->closed) { chosen = (int)i; out_ok = false; return true; }
            }
        }
        return false;
    };
    {
        std::lock_guard<std::mutex> l(RT().m);
        for (size_t i = 0; i < spec.size(); i++)
            cs.push_back({spec[i].first, chan_get_locked(spec[i].second), vals[i], prios[i]});
        if (timeout_ms != 0) check_cancel_locked(self);
        if (try_cases()) return chosen;
        if (timeout_ms == 0) return -1;
        for (auto& k : cs) if (!k.send) { k.c->recv_waiting++; }
        for (auto& k : cs) if (!k.send) wake_all(k.c->wq);
    }
    struct Dec {
        std::vector<SelCase>& cs;
        ~Dec() { std::lock_guard<std::mutex> l(RT().m); for (auto& k : cs) if (!k.send) k.c->recv_waiting--; }
    } dec{cs};
    GilRelease rel;
    std::unique_lock<std::mutex> lk(RT().m);
    // Register on every channel's queue (duplicates are harmless).
    std::vector<WQ*> qs;
    for (auto& k : cs) qs.push_back(&k.c->wq);
    // block() takes an initializer_list; register manually for a dynamic set.
    for (auto* q : qs) q->push_back(self);
    struct Unreg { ThreadRec* s; std::vector<WQ*>& qs;
        ~Unreg() { for (auto* q : qs) { auto it = std::find(q->begin(), q->end(), s); if (it != q->end()) q->erase(it); } } } unreg{self, qs};
    bool ok = block(lk, self, {}, try_cases, Deadline::in_ms(timeout_ms), nullptr);
    return ok ? chosen : -1;
}

// ── futures ─────────────────────────────────────────────────────────────────
struct Future : Obj {
    bool done = false, cancelled = false, running = false, failed = false;
    BoxPtr result; NyError err;
    WQ wq;
    std::vector<BoxPtr> callbacks;
    uint64_t done_seq = 0;
    Engine* engine = nullptr;
};

// Complete a future (GIL held, runtime mutex NOT held), then run its callbacks.
static void future_complete(Engine& e, Future* f, const BoxPtr& res, bool failed, const NyError& err, bool cancelled) {
    std::vector<BoxPtr> cbs;
    {
        std::lock_guard<std::mutex> l(RT().m);
        if (f->done) return;
        f->done = true; f->running = false;
        f->result = res; f->failed = failed; f->err = err; f->cancelled = cancelled;
        f->done_seq = ++RT().seq;
        wake_all(f->wq);
        cbs.swap(f->callbacks);
    }
    for (auto& cb : cbs) {
        try { e.call(cb, {e.box_int(f->id)}); }
        catch (NyError& x) { std::cerr << "Exception in future callback: " << error_text(x) << std::endl; }
    }
}
static BoxPtr future_result(Engine& e, int64_t h, double timeout_ms, bool want_exception, std::string* exc_text) {
    ThreadRec* self = current(e);
    Future* f;
    {
        std::lock_guard<std::mutex> l(RT().m);
        f = get_obj<Future>(h, "future");
    }
    bool ok = simple_wait(e, &f->wq, [f] { return f->done; }, timeout_ms);
    (void)self;
    if (!ok) raise("TimeoutError", "future#" + std::to_string(h) + " not done after " +
                   std::to_string((long long)timeout_ms) + " ms");
    std::lock_guard<std::mutex> l(RT().m);
    if (f->cancelled) raise("CancelledError", "future#" + std::to_string(h) + " was cancelled");
    if (want_exception) {
        if (f->failed && exc_text) *exc_text = error_text(f->err);
        return nullptr;
    }
    if (f->failed) throw f->err;
    return f->result ? f->result : e.box_none();
}

// ── pool ────────────────────────────────────────────────────────────────────
struct Pool : Obj {
    struct Job { int64_t fid; BoxPtr fn; std::vector<BoxPtr> args; };
    std::deque<Job> jobs;
    bool shutdown = false;
    std::vector<int64_t> workers;
    WQ wq;
};

static BoxPtr pool_worker(Engine& e, Pool* p, ThreadRec* self) {
    while (true) {
        Pool::Job job;
        Future* f = nullptr;
        {
            std::unique_lock<std::mutex> lk(RT().m);
            // Another worker may take the job between our wake-up and here:
            // only an empty queue *after shutdown* ends the worker.
            while (p->jobs.empty()) {
                if (p->shutdown) return e.box_none();
                lk.unlock();
                block_released(self, {&p->wq}, [p] { return !p->jobs.empty() || p->shutdown; },
                               Deadline::never(), nullptr, false);
                lk.lock();
            }
            job = p->jobs.front(); p->jobs.pop_front();
            f = get_obj<Future>(job.fid, "future");
            if (f->done) continue;                        // cancelled while queued
            f->running = true;
        }
        BoxPtr res; bool failed = false; NyError err;
        try { res = e.call(job.fn, job.args); }
        catch (NyError& x) { failed = true; err = x; }
        future_complete(e, f, res, failed, err, false);
        {
            // A cancel request aimed at this worker's job must not leak into the next.
            std::lock_guard<std::mutex> l(RT().m);
            self->cancel_requested = false;
        }
    }
}

// ── timer ───────────────────────────────────────────────────────────────────
struct Timer : Obj { bool cancelled = false, fired = false; WQ wq; };

// ── task group (structured concurrency) ─────────────────────────────────────
struct Group : Obj {
    std::vector<int64_t> children;
    bool failed = false, cancelled = false, closed = false;
    NyError first;
    WQ wq;
};

static void cancel_thread_locked(ThreadRec* t) {
    if (t->done) return;
    t->cancel_requested = true;
    if (t->blocking) wake(t);
}

static void finish_group_child(ThreadRec* rec) {
    auto it = RT().objs.find(rec->group);
    if (it == RT().objs.end()) return;
    auto* g = dynamic_cast<Group*>(it->second.get());
    if (!g) return;
    if (rec->failed && !(g->cancelled && is_cancel_error(rec->error)) && !g->failed) {
        g->failed = true;
        g->first = rec->error;
        g->cancelled = true;
        for (auto cid : g->children) {
            auto t = RT().threads.find(cid);
            if (t != RT().threads.end() && t->second.get() != rec) cancel_thread_locked(t->second.get());
        }
    }
    wake_all(g->wq);
}

// ════════════════════════════════════════════════════════════════════════════
// 7. Async: coroutines, tasks, awaitables
// ════════════════════════════════════════════════════════════════════════════

struct Coro : Obj {
    BoxPtr fn; std::vector<BoxPtr> args; std::string name;
    bool is_def = false;            // created by an `async def` (body gated by the token)
    bool consumed = false;
    int64_t task = 0;
};
struct Awaitable : Obj {
    enum Kind { SLEEP, GATHER, WAIT_FOR, CALL_LATER } kind = SLEEP;
    double secs = 0;
    struct Item { bool is_handle; int64_t h; BoxPtr v; };
    std::vector<Item> items;
    Item target{};
    BoxPtr fn; std::vector<BoxPtr> args;
    bool return_exceptions = false;
};

static BoxPtr run_coro_body(Engine& e, Coro* c) {
    t_async_token = c->is_def;
    struct Clear { ~Clear() { t_async_token = false; } } clear;
    return e.call(c->fn, c->args);
}

static Task* new_task_locked(Loop* L, Engine& e, std::function<BoxPtr(Engine&)> entry, const std::string& name) {
    auto t = std::make_shared<Task>();
    t->loop = L; t->engine = &e; t->entry = std::move(entry); t->name = name;
    add_obj(t, true);
    L->tasks.push_back(t);
    L->ready.push_back(t.get());
    t->in_ready = true;
    L->cv.notify_all();
    return t.get();
}

static BoxPtr await_value(Engine& e, int64_t h, bool is_handle, const BoxPtr& v);
struct Awaitable;
static Ret gather_in_loop(Engine& e, Awaitable* a, ThreadRec* self, Loop* L);

// Turn an awaitable (coroutine / task / other awaitable / plain value) into a
// task of loop L. Called with the runtime mutex held.
static Task* ensure_task_locked(Loop* L, Engine& e, const Awaitable::Item& it) {
    if (it.is_handle) {
        auto oi = RT().objs.find(it.h);
        Obj* o = oi == RT().objs.end() ? nullptr : oi->second.get();
        if (auto* c = dynamic_cast<Coro*>(o)) {
            if (c->task) return get_obj<Task>(c->task, "task");
            if (c->consumed) raise("RuntimeError", "coroutine '" + c->name + "' was already awaited");
            c->consumed = true;
            Task* t = new_task_locked(L, e, [c](Engine& en) { return run_coro_body(en, c); }, c->name);
            c->task = t->id;
            return t;
        }
        if (auto* t = dynamic_cast<Task*>(o)) return t;
        if (dynamic_cast<Awaitable*>(o) || dynamic_cast<Future*>(o)) {
            int64_t h = it.h;
            return new_task_locked(L, e, [h](Engine& en) { return await_value(en, h, true, nullptr); }, "await");
        }
    }
    // A plain value: an already-finished task.
    auto t = std::make_shared<Task>();
    t->loop = L; t->engine = &e; t->done = true; t->started = true;
    t->result = it.is_handle ? e.box_int(it.h) : it.v;
    t->done_seq = ++RT().seq;
    add_obj(t, true);
    L->tasks.push_back(t);
    return t.get();
}

static void task_finish_locked(Task* t, const BoxPtr& res, bool failed, const NyError& err) {
    t->done = true;
    t->result = res; t->failed = failed; t->err = err;
    t->cancelled = failed && is_cancel_error(err);
    t->done_seq = ++RT().seq;
    wake_all(t->wq);
}

static bool task_cancel_locked(Task* t) {
    if (t->done) return false;
    if (!t->started) {
        t->in_ready = false;
        auto& r = t->loop->ready;
        r.erase(std::remove(r.begin(), r.end(), t), r.end());
        task_finish_locked(t, nullptr, true, NyError::make("CancelledError", "task '" + t->name + "' was cancelled"));
        return true;
    }
    if (t->thr) {
        t->thr->cancel_requested = true;
        if (t->thr->blocking) wake(t->thr.get());
    }
    return true;
}

static void task_finish_locked(Task* t, const BoxPtr& res, bool failed, const NyError& err);

// A task's coroutine: the body, then its outcome. Switched in by grant() with
// the GIL held and the task's (fresh) engine state in.
static void task_entry(void* arg) {
    Task* tp = static_cast<Task*>(arg);
    ThreadRec* r = tp->thr.get();
    BoxPtr res; bool failed = false; NyError err;
    // Nothing may unwind across the stack switch: everything is caught here.
    try { res = tp->entry(*tp->engine); }
    catch (NyError& x) { failed = true; err = x; }
    catch (std::exception& x) { failed = true; err = NyError::make("RuntimeError", x.what()); }
    catch (...) { failed = true; err = NyError::make("RuntimeError", "task '" + tp->name + "' was ended by an unknown exception"); }
    tp->entry = nullptr;      // captured engine values go while the GIL is held
    {
        std::lock_guard<std::mutex> l(RT().m);
        task_finish_locked(tp, res, failed, err);
        finish_thread_locked(r, res, failed, err);
    }
    res = nullptr; err = NyError();
    switch_state(r, tp->loop->thread);
}

// Start (first grant) or resume a task: run it on its coroutine until it
// parks or finishes. Loop thread, runtime mutex held, GIL released.
static void grant(std::unique_lock<std::mutex>& lk, Loop* L, Task* t) {
    t->in_ready = false;
    L->current = t;
    if (!t->thr) {
        t->started = true;
        auto rec = new_thread_rec(*t->engine, "task-" + t->name, true);
        rec->task = t;
        rec->cancel_sticky = false;
        rec->started = true;
        rec->estate = t->engine->state_new();
        t->thr = rec;
        try { t->co = nycoro::create(&task_entry, t, task_stack_size()); }
        catch (std::bad_alloc&) {
            NyError err = NyError::make("MemoryError", "cannot allocate a stack for task '" + t->name + "'");
            task_finish_locked(t, nullptr, true, err);
            finish_thread_locked(rec.get(), nullptr, true, err);
            L->current = nullptr;
            return;
        }
    }
    ThreadRec* loop_rec = L->thread;
    lk.unlock();
    gil_acquire();
    switch_state(loop_rec, t->thr.get());
    nycoro::resume(t->co);           // until it parks or returns; either switched the state back
    if (nycoro::done(t->co)) {
        nycoro::destroy(t->co);
        t->co = nullptr;
        t->engine->state_free(t->thr->estate);
        t->thr->estate = nullptr;
    }
    gil_release();
    lk.lock();
    if (L->current == t) L->current = nullptr;
}

static void loop_poll_io(std::unique_lock<std::mutex>& lk, Loop* L);
static void loop_run_signals(std::unique_lock<std::mutex>& lk);

// Run loop L until `until` holds. Loop thread, runtime mutex held, GIL released.
static void run_loop_until(std::unique_lock<std::mutex>& lk, Loop* L, const std::function<bool()>& until) {
    ThreadRec* self = L->thread;
    const bool watch = sig_watch();
    while (!until()) {
        if (watch && g_sig_any.load(std::memory_order_acquire)) { loop_run_signals(lk); continue; }
        TP now = Clock::now();
        while (!L->timers.empty() && L->timers.begin()->first.first <= now) {
            Task* t = L->timers.begin()->second;
            L->timers.erase(L->timers.begin());
            t->timer_set = false;
            make_ready(t);
        }
        if (!L->ready.empty()) {
            Task* t = L->ready.front();
            L->ready.pop_front();
            if (t->done) { t->in_ready = false; continue; }
            grant(lk, L, t);
            continue;
        }
        if (!L->io.empty()) { loop_poll_io(lk, L); continue; }
        if (!L->timers.empty()) {
            TP until_tp = L->timers.begin()->first.first;
            if (watch) until_tp = std::min(until_tp, Clock::now() + kSignalSlice);
            L->cv.wait_until(lk, until_tp);
            continue;
        }
        // Nothing ready, nothing timed: only another thread can wake a task.
        self->blocking = true; self->blocked_forever = true;
        try { check_all_blocked_locked(self); }
        catch (...) { self->blocking = false; self->blocked_forever = false; throw; }
        if (watch) L->cv.wait_for(lk, kSignalSlice);
        else L->cv.wait(lk);
        self->blocking = false; self->blocked_forever = false;
    }
}

// async_run: create a loop on the calling thread and drive it until the main
// task finishes; then cancel whatever is left and let it unwind.
static BoxPtr async_run(Engine& e, const Awaitable::Item& main_item) {
    ThreadRec* self = current(e);
    if (self->task) raise("RuntimeError", "async_run() cannot be called from a running event loop");
    ensure_active(e);
    auto L = std::make_shared<Loop>();
    L->thread = self;
    // Tasks still suspended at the end (blocked even after cancellation)
    // keep pointing at the loop: it is then kept, as their stacks are.
    struct KeepIfStuck {
        std::shared_ptr<Loop>& L;
        ~KeepIfStuck() {
            for (auto& t : L->tasks)
                if (t->co) { new std::shared_ptr<Loop>(L); return; }
        }
    } keep{L};
    Task* main_task;
    {
        std::lock_guard<std::mutex> l(RT().m);
        main_task = ensure_task_locked(L.get(), e, main_item);
    }
    NyError loop_err; bool loop_failed = false;
    {
        GilRelease rel;
        std::unique_lock<std::mutex> lk(RT().m);
        try { run_loop_until(lk, L.get(), [main_task] { return main_task->done; }); }
        catch (NyError& x) { loop_err = x; loop_failed = true; }
        // Cancel the rest (Python's asyncio.run does the same) and drain.
        for (auto& t : L->tasks) task_cancel_locked(t.get());
        try {
            run_loop_until(lk, L.get(), [&L] {
                for (auto& t : L->tasks) if (!t->done) return false;
                return true;
            });
        } catch (NyError&) { /* still blocked after cancellation: give up on them */ }
    }
    if (loop_failed) throw loop_err;
    std::lock_guard<std::mutex> l(RT().m);
    if (main_task->failed) throw main_task->err;
    return main_task->result ? main_task->result : e.box_none();
}

static BoxPtr task_outcome_locked(Engine& e, Task* t) {
    if (t->failed) throw t->err;
    return t->result ? t->result : e.box_none();
}

// await <handle-or-value>
static BoxPtr await_value(Engine& e, int64_t h, bool is_handle, const BoxPtr& v) {
    if (!is_handle) return v;
    ThreadRec* self = current(e);
    Obj* o;
    {
        std::lock_guard<std::mutex> l(RT().m);
        auto it = RT().objs.find(h);
        o = it == RT().objs.end() ? nullptr : it->second.get();
    }
    if (!o) return e.box_int(h);                       // an int that is not ours
    if (auto* c = dynamic_cast<Coro*>(o)) {
        int64_t tid;
        {
            std::lock_guard<std::mutex> l(RT().m);
            tid = c->task;
            if (!tid) {
                if (c->consumed) raise("RuntimeError", "coroutine '" + c->name + "' was already awaited");
                c->consumed = true;
            }
        }
        if (!tid) return run_coro_body(e, c);         // run inline, in this task
        return await_value(e, tid, true, nullptr);
    }
    if (auto* t = dynamic_cast<Task*>(o)) {
        {
            std::lock_guard<std::mutex> l(RT().m);
            if (t->done) return task_outcome_locked(e, t);
            if (self->task == t) raise("DeadlockError", "deadlock detected: task '" + t->name + "' awaits itself");
        }
        try {
            block_released(self, {&t->wq}, [t] { return t->done; }, Deadline::never(), nullptr);
        } catch (NyError& err) {
            // Cancelling a task cancels the task it awaits, as in Python
            // (round 77; asyncio.shield waits without awaiting, to opt out).
            if (is_cancel_error(err)) {
                std::lock_guard<std::mutex> l(RT().m);
                if (!t->done) task_cancel_locked(t);
            }
            throw;
        }
        std::lock_guard<std::mutex> l(RT().m);
        return task_outcome_locked(e, t);
    }
    if (auto* f = dynamic_cast<Future*>(o)) {
        (void)f;
        return future_result(e, h, -1, false, nullptr);
    }
    auto* a = dynamic_cast<Awaitable*>(o);
    if (!a) return e.box_int(h);
    if (a->kind == Awaitable::SLEEP) {
        double ms = a->secs * 1000.0;
        if (self->task && ms <= 0) {
            // sleep(0): go to the back of the ready queue.
            GilRelease rel;
            std::unique_lock<std::mutex> lk(RT().m);
            check_cancel_locked(self);
            Task* T = self->task;
            T->loop->ready.push_back(T); T->in_ready = true;
            task_park(lk, self, Deadline::never());
            check_cancel_locked(self);
            return e.box_none();
        }
        block_released(self, {}, [] { return false; }, Deadline::in_ms(ms < 0 ? 0 : ms), nullptr);
        return e.box_none();
    }
    if (a->kind == Awaitable::CALL_LATER) {
        block_released(self, {}, [] { return false; }, Deadline::in_ms(a->secs * 1000.0), nullptr);
        return e.call(a->fn, a->args);
    }
    // gather / wait_for need a loop; outside one, run a private loop for them.
    if (!self->task) {
        Awaitable::Item it{true, h, nullptr};
        return async_run(e, it);
    }
    Loop* L = self->task->loop;
    if (a->kind == Awaitable::GATHER) return e.from_ret(gather_in_loop(e, a, self, L));
    // WAIT_FOR
    Task* t;
    {
        std::lock_guard<std::mutex> l(RT().m);
        t = ensure_task_locked(L, e, a->target);
    }
    bool ok;
    try {
        ok = block_released(self, {&t->wq}, [t] { return t->done; }, Deadline::in_ms(a->secs * 1000.0), nullptr);
    } catch (NyError& err) {
        if (is_cancel_error(err)) {
            std::lock_guard<std::mutex> l(RT().m);
            if (!t->done) task_cancel_locked(t);
        }
        throw;
    }
    if (!ok) {
        {
            std::lock_guard<std::mutex> l(RT().m);
            task_cancel_locked(t);
        }
        block_released(self, {&t->wq}, [t] { return t->done; }, Deadline::never(), nullptr, false);
        { std::ostringstream os; os << a->secs; raise("TimeoutError", "wait_for: timed out after " + os.str() + " s"); }
    }
    std::lock_guard<std::mutex> l(RT().m);
    return task_outcome_locked(e, t);
}

// ════════════════════════════════════════════════════════════════════════════
// 8. Builtin dispatch
// ════════════════════════════════════════════════════════════════════════════

static int64_t H(const Args& a, size_t i, const char* fn) {
    if (i >= a.size() || !a.is_number(i))
        raise("TypeError", std::string(fn) + "() expects a handle as argument " + std::to_string(i + 1));
    return a.as_int(i);
}
static double opt_num(const Args& a, size_t i, double def) { return (i < a.size() && a.is_number(i)) ? a.as_num(i) : def; }
static std::vector<BoxPtr> rest(const Args& a, size_t from) {
    std::vector<BoxPtr> v;
    for (size_t i = from; i < a.size(); i++) v.push_back(a.box(i));
    return v;
}
static BoxPtr need_callable(Engine& e, const Args& a, size_t i, const char* fn) {
    if (i >= a.size()) raise("TypeError", std::string(fn) + "() missing the function argument");
    BoxPtr b = a.box(i);
    if (!e.is_callable(b)) raise("TypeError", std::string(fn) + "(): argument " + std::to_string(i + 1) + " is not callable");
    return b;
}
static double priority_of(const Args& a, size_t i) {
    if (i >= a.size()) return 0;
    if (a.is_number(i)) return a.as_num(i);
    if (a.is_list(i)) { auto l = a.list(i); if (l->size() > 0 && l->is_number(0)) return l->as_num(0); }
    return 0;
}
// An awaitable argument: a handle (coroutine, task, future, awaitable), or a
// value. An object with __await__ stands for what __await__() returns
// (round 77: asyncio's Task/Future objects, user awaitables); a plain value
// awaits to itself. Called without the runtime mutex (__await__ is Nython).
static Awaitable::Item item_of(Engine& e, const Args& a, size_t i) {
    Awaitable::Item it{false, 0, nullptr};
    if (a.is_number(i) && a.as_num(i) == (double)a.as_int(i)) { it.is_handle = true; it.h = a.as_int(i); return it; }
    BoxPtr v = a.box(i);
    for (int depth = 0; depth < 16; depth++) {
        BoxPtr r = e.await_target(v);
        if (!r) break;
        int64_t h;
        if (e.unbox_int(r, h)) { it.is_handle = true; it.h = h; return it; }
        v = r;
    }
    it.v = v;
    return it;
}
static Ret boxret(const BoxPtr& b) { return Ret::boxed(b); }

static Ret thread_ret(Engine& e, int64_t id) { (void)e; return Ret::integer(id); }

using Handler = Ret (*)(Engine&, const Args&);

static Ret do_thread_create(Engine& e, const Args& a, size_t fn_at, const std::string& name) {
    BoxPtr fn = need_callable(e, a, fn_at, "thread_create");
    auto args = rest(a, fn_at + 1);
    return thread_ret(e, start_thread(e, [fn, args](ThreadRec* self) { return self->engine->call(fn, args); }, name, false));
}

static bool sig_sleep_until(const Deadline& dl);
static Ret sleep_ms(Engine& e, double ms) {
    ThreadRec* self = current(e);
    if (!active()) {
        // Single-threaded: a plain sleep, as before the runtime existed - but
        // one a signal ends (its handler runs, then the rest is slept).
        if (ms > 0) {
            Deadline dl = Deadline::in_ms(ms);
            if (sig_sleep_until(dl)) throw signal_interrupt();
        }
        return Ret::none();
    }
    if (ms <= 0) {
        std::lock_guard<std::mutex> l(RT().m);
        check_cancel_locked(self);
    }
    if (self->task && ms <= 0) {
        // Behaves like `await async_sleep(0)`: let the other tasks run.
        int64_t h;
        { std::lock_guard<std::mutex> l(RT().m); auto aw = std::make_shared<Awaitable>(); aw->kind = Awaitable::SLEEP; h = add_obj(aw, true); }
        await_value(e, h, true, nullptr);
        return Ret::none();
    }
    if (ms <= 0) { GilRelease rel; std::this_thread::yield(); return Ret::none(); }
    block_released(self, {}, [] { return false; }, Deadline::in_ms(ms), nullptr);
    return Ret::none();
}

static std::unordered_map<std::string, Handler>& table();

bool dispatch(Engine& e, const std::string& name, const Args& a, Ret& out) {
    auto& t = table();
    auto it = t.find(name);
    if (it == t.end()) return false;
    // A wait a signal interrupts (main thread): run the handlers, then the
    // call again with its original deadline; a handler that raises ends it.
    DeadlineMemo saved = t_dl;
    t_dl = DeadlineMemo(); t_dl.on = true;
    struct Restore { DeadlineMemo s; ~Restore() { t_dl = s; } } restore{saved};
    while (true) {
        try { out = it->second(e, a); return true; }
        catch (NyError& x) { if (x.type != "__signal__") throw; }
        run_signal_handlers();
        t_dl.reuse = true;
    }
}

const std::vector<std::string>& builtin_names() {
    static std::vector<std::string> names = [] {
        std::vector<std::string> v;
        for (auto& kv : table()) v.push_back(kv.first);
        std::sort(v.begin(), v.end());
        return v;
    }();
    return names;
}
const std::vector<std::string>& exception_names() {
    static std::vector<std::string> v = {"DeadlockError", "LockOrderError", "CancelledError", "ChannelClosedError"};
    return v;
}

// gather: every awaitable becomes a task of the current loop; wait until all
// are done (or, without return_exceptions, until one fails) and return the
// outcomes in argument order.
static Ret gather_in_loop(Engine& e, Awaitable* a, ThreadRec* self, Loop* L) {
    std::vector<Task*> ts;
    {
        std::lock_guard<std::mutex> l(RT().m);
        for (auto& it : a->items) ts.push_back(ensure_task_locked(L, e, it));
    }
    bool rex = a->return_exceptions;
    auto all_or_fail = [ts, rex] {
        bool all = true;
        for (auto* t : ts) { if (!t->done) all = false; else if (t->failed && !rex) return true; }
        return all;
    };
    {
        GilRelease rel;
        std::unique_lock<std::mutex> lk(RT().m);
        std::vector<WQ*> qs;
        for (auto* t : ts) { qs.push_back(&t->wq); t->wq.push_back(self); }
        struct Unreg { ThreadRec* s; std::vector<WQ*>& qs;
            ~Unreg() { for (auto* q : qs) { auto it = std::find(q->begin(), q->end(), s); if (it != q->end()) q->erase(it); } } } unreg{self, qs};
        try {
            block(lk, self, {}, all_or_fail, Deadline::never(), nullptr);
        } catch (NyError& err) {
            // Cancelling the gather cancels its children (Python's rule).
            if (is_cancel_error(err)) for (auto* t : ts) if (!t->done) task_cancel_locked(t);
            throw;
        }
    }
    std::lock_guard<std::mutex> l(RT().m);
    Task* first_fail = nullptr;
    for (auto* t : ts) if (t->done && t->failed && (!first_fail || t->done_seq < first_fail->done_seq)) first_fail = t;
    if (first_fail && !rex) throw first_fail->err;
    std::vector<Ret> out;
    for (auto* t : ts) {
        if (t->failed) {
            BoxPtr ex = e.exception_object(t->err);
            out.push_back(ex ? Ret::boxed(ex) : Ret::str(error_text(t->err)));
        }
        else out.push_back(Ret::boxed(t->result ? t->result : e.box_none()));
    }
    return Ret::lst(std::move(out));
}

static void register_signal_builtins(std::unordered_map<std::string, Handler>& T);
static std::unordered_map<std::string, Handler>& table() {
    static std::unordered_map<std::string, Handler>* tbl = [] {
        auto* m = new std::unordered_map<std::string, Handler>();
        auto& T = *m;

        // ── threads ─────────────────────────────────────────────────────────
        T["thread_create"] = [](Engine& e, const Args& a) { return do_thread_create(e, a, 0, ""); };
        T["thread_start"] = T["thread_create"];
        T["thread_create_named"] = [](Engine& e, const Args& a) {
            std::string nm = a.size() > 0 ? a.as_str(0) : "";
            return do_thread_create(e, a, 1, nm);
        };
        T["thread_join"] = [](Engine& e, const Args& a) {
            return boxret(join_thread(e, H(a, 0, "thread_join"), opt_num(a, 1, -1)));
        };
        T["thread_is_alive"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(!get_thread_locked(H(a, 0, "thread_is_alive"))->done);
        };
        T["thread_id"] = [](Engine& e, const Args&) { return Ret::integer(current(e)->id); };
        T["thread_current"] = T["thread_id"];
        T["thread_main"] = [](Engine& e, const Args&) { current(e); return Ret::integer(RT().main_id); };
        T["thread_name"] = [](Engine& e, const Args& a) {
            ThreadRec* self = current(e);
            std::lock_guard<std::mutex> l(RT().m);
            ThreadRec* t = a.size() > 0 && a.is_number(0) ? get_thread_locked(a.as_int(0)) : self;
            return Ret::str(t->name);
        };
        T["thread_set_name"] = [](Engine& e, const Args& a) {
            ThreadRec* self = current(e);
            std::lock_guard<std::mutex> l(RT().m);
            if (a.size() == 1) { self->name = a.as_str(0); return Ret::none(); }
            get_thread_locked(H(a, 0, "thread_set_name"))->name = a.size() > 1 ? a.as_str(1) : "";
            return Ret::none();
        };
        T["thread_detach"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            ThreadRec* t = get_thread_locked(H(a, 0, "thread_detach"));
            t->detached = true; t->daemon = true;
            return Ret::boolean(true);
        };
        T["thread_set_daemon"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            get_thread_locked(H(a, 0, "thread_set_daemon"))->daemon = a.size() > 1 ? a.truthy(1) : true;
            return Ret::none();
        };
        T["thread_is_daemon"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_thread_locked(H(a, 0, "thread_is_daemon"))->daemon);
        };
        T["thread_yield"] = [](Engine& e, const Args&) { return sleep_ms(e, 0); };
        T["thread_count"] = [](Engine& e, const Args&) {
            current(e);
            std::lock_guard<std::mutex> l(RT().m);
            int64_t n = 0;
            for (auto* t : RT().live) if (!t->task) n++;
            return Ret::integer(n);
        };
        // How many times a thread has gone to sleep - queued for the GIL or
        // blocked on a lock, condition, queue, join... - since the program
        // started: the cost of switching, in a unit that does not depend on
        // the machine's speed.
        T["thread_wait_count"] = [](Engine&, const Args&) {
            return Ret::integer(g_waits.load(std::memory_order_relaxed));
        };
        T["thread_list"] = [](Engine& e, const Args&) {
            current(e);
            std::lock_guard<std::mutex> l(RT().m);
            std::vector<int64_t> ids;
            for (auto* t : RT().live) if (!t->task) ids.push_back(t->id);
            std::sort(ids.begin(), ids.end());
            std::vector<Ret> v;
            for (auto id : ids) v.push_back(Ret::integer(id));
            return Ret::lst(std::move(v));
        };
        T["thread_result"] = [](Engine& e, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            ThreadRec* t = get_thread_locked(H(a, 0, "thread_result"));
            if (!t->done) raise("RuntimeError", "thread " + t->label() + " has not finished");
            if (t->failed) { t->reported = true; throw t->error; }
            return boxret(t->result ? t->result : e.box_none());
        };
        T["thread_local_get"] = [](Engine& e, const Args& a) {
            ThreadRec* self = current(e);
            std::string k = a.size() > 0 ? a.as_str(0) : "";
            auto it = self->tls.find(k);
            if (it != self->tls.end()) return boxret(it->second);
            return a.size() > 1 ? boxret(a.box(1)) : Ret::none();
        };
        T["thread_local_set"] = [](Engine& e, const Args& a) {
            ThreadRec* self = current(e);
            if (a.size() < 2) raise("TypeError", "thread_local_set(key, value)");
            self->tls[a.as_str(0)] = a.box(1);
            return Ret::none();
        };
        T["thread_local_has"] = [](Engine& e, const Args& a) {
            ThreadRec* self = current(e);
            return Ret::boolean(a.size() > 0 && self->tls.count(a.as_str(0)));
        };
        T["thread_local_del"] = [](Engine& e, const Args& a) {
            ThreadRec* self = current(e);
            return Ret::boolean(a.size() > 0 && self->tls.erase(a.as_str(0)) > 0);
        };
        T["thread_cancel"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            ThreadRec* t = get_thread_locked(H(a, 0, "thread_cancel"));
            if (t->done) return Ret::boolean(false);
            cancel_thread_locked(t);
            return Ret::boolean(true);
        };
        T["thread_cancelled"] = [](Engine& e, const Args&) {
            ThreadRec* self = current(e);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(self->cancel_requested);
        };
        T["cancel_check"] = [](Engine& e, const Args&) {
            ThreadRec* self = current(e);
            std::lock_guard<std::mutex> l(RT().m);
            check_cancel_locked(self);
            return Ret::none();
        };
        T["sleep"] = [](Engine& e, const Args& a) { return sleep_ms(e, opt_num(a, 0, 0) * 1000.0); };
        T["time_sleep"] = T["sleep"];
        T["thread_sleep"] = [](Engine& e, const Args& a) { return sleep_ms(e, opt_num(a, 0, 0)); };
        T["sleep_ms"] = T["thread_sleep"];

        // ── mutex ───────────────────────────────────────────────────────────
        T["mutex_create"] = [](Engine& e, const Args&) {
            current(e);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(std::make_shared<Mutex>()));
        };
        T["mutex_new"] = T["mutex_create"];
        T["rmutex_create"] = [](Engine& e, const Args&) {
            current(e);
            std::lock_guard<std::mutex> l(RT().m);
            auto m = std::make_shared<Mutex>(); m->recursive = true;
            return Ret::integer(add_obj(m));
        };
        T["mutex_create_recursive"] = T["rmutex_create"];
        T["mutex_lock"] = [](Engine& e, const Args& a) { return Ret::boolean(mutex_acquire(e, H(a, 0, "mutex_lock"), -1)); };
        T["mutex_try_lock"] = [](Engine& e, const Args& a) { return Ret::boolean(mutex_acquire(e, H(a, 0, "mutex_try_lock"), 0)); };
        T["mutex_trylock"] = T["mutex_try_lock"];
        T["mutex_lock_timeout"] = [](Engine& e, const Args& a) {
            return Ret::boolean(mutex_acquire(e, H(a, 0, "mutex_lock_timeout"), std::max(0.0, opt_num(a, 1, 0))));
        };
        T["mutex_unlock"] = [](Engine& e, const Args& a) { mutex_release(e, H(a, 0, "mutex_unlock")); return Ret::boolean(true); };
        T["mutex_locked"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_obj<Mutex>(H(a, 0, "mutex_locked"), "mutex")->owner != nullptr);
        };
        T["mutex_owner"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            auto* m = get_obj<Mutex>(H(a, 0, "mutex_owner"), "mutex");
            return Ret::integer(m->owner ? m->owner->id : 0);
        };

        // ── rwlock ──────────────────────────────────────────────────────────
        T["rwlock_create"] = [](Engine& e, const Args&) {
            current(e);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(std::make_shared<RWLock>()));
        };
        T["rwlock_read_lock"] = [](Engine& e, const Args& a) { return Ret::boolean(rw_read_lock(e, H(a, 0, "rwlock_read_lock"), -1)); };
        T["rwlock_write_lock"] = [](Engine& e, const Args& a) { return Ret::boolean(rw_write_lock(e, H(a, 0, "rwlock_write_lock"), -1)); };
        T["rwlock_try_read_lock"] = [](Engine& e, const Args& a) { return Ret::boolean(rw_read_lock(e, H(a, 0, "rwlock_try_read_lock"), 0)); };
        T["rwlock_try_write_lock"] = [](Engine& e, const Args& a) { return Ret::boolean(rw_write_lock(e, H(a, 0, "rwlock_try_write_lock"), 0)); };
        T["rwlock_read_lock_timeout"] = [](Engine& e, const Args& a) { return Ret::boolean(rw_read_lock(e, H(a, 0, "rwlock_read_lock_timeout"), std::max(0.0, opt_num(a, 1, 0)))); };
        T["rwlock_write_lock_timeout"] = [](Engine& e, const Args& a) { return Ret::boolean(rw_write_lock(e, H(a, 0, "rwlock_write_lock_timeout"), std::max(0.0, opt_num(a, 1, 0)))); };
        T["rwlock_read_unlock"] = [](Engine& e, const Args& a) { rw_unlock(e, H(a, 0, "rwlock_read_unlock"), false); return Ret::boolean(true); };
        T["rwlock_write_unlock"] = [](Engine& e, const Args& a) { rw_unlock(e, H(a, 0, "rwlock_write_unlock"), true); return Ret::boolean(true); };
        T["rwlock_readers"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer((int64_t)get_obj<RWLock>(H(a, 0, "rwlock_readers"), "rwlock")->readers.size());
        };
        T["rwlock_writer"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            auto* rw = get_obj<RWLock>(H(a, 0, "rwlock_writer"), "rwlock");
            return Ret::integer(rw->writer ? rw->writer->id : 0);
        };
        T["rwlock_waiting_writers"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(get_obj<RWLock>(H(a, 0, "rwlock_waiting_writers"), "rwlock")->waiting_writers);
        };

        // ── condition ───────────────────────────────────────────────────────
        T["cond_create"] = [](Engine& e, const Args&) {
            current(e);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(std::make_shared<Cond>()));
        };
        T["condition_create"] = T["cond_create"];
        T["cond_wait"] = [](Engine& e, const Args& a) {
            return Ret::boolean(cond_wait(e, H(a, 0, "cond_wait"), H(a, 1, "cond_wait"), -1));
        };
        T["cond_wait_timeout"] = [](Engine& e, const Args& a) {
            return Ret::boolean(cond_wait(e, H(a, 0, "cond_wait_timeout"), H(a, 1, "cond_wait_timeout"), std::max(0.0, opt_num(a, 2, 0))));
        };
        T["cond_notify"] = [](Engine& e, const Args& a) {
            return Ret::integer(cond_notify(e, H(a, 0, "cond_notify"), (int64_t)opt_num(a, 1, 1)));
        };
        T["cond_notify_all"] = [](Engine& e, const Args& a) { return Ret::integer(cond_notify(e, H(a, 0, "cond_notify_all"), -1)); };
        T["condition_wait"] = T["cond_wait"];
        T["condition_wait_timeout"] = T["cond_wait_timeout"];
        T["condition_notify"] = T["cond_notify"];
        T["condition_notify_all"] = T["cond_notify_all"];

        // ── semaphore ───────────────────────────────────────────────────────
        T["semaphore_create"] = [](Engine& e, const Args& a) {
            current(e);
            auto s = std::make_shared<Sema>();
            s->count = (int64_t)opt_num(a, 0, 1);
            s->max = (int64_t)opt_num(a, 1, -1);
            if (s->count < 0) raise("ValueError", "semaphore_create: initial value must be >= 0");
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(s));
        };
        T["semaphore_acquire"] = [](Engine& e, const Args& a) {
            Sema* s;
            { std::lock_guard<std::mutex> l(RT().m); s = get_obj<Sema>(H(a, 0, "semaphore_acquire"), "semaphore"); }
            return Ret::boolean(simple_wait(e, &s->wq, [s] { if (s->count > 0) { s->count--; return true; } return false; }, -1));
        };
        T["semaphore_try_acquire"] = [](Engine& e, const Args& a) {
            Sema* s;
            { std::lock_guard<std::mutex> l(RT().m); s = get_obj<Sema>(H(a, 0, "semaphore_try_acquire"), "semaphore"); }
            return Ret::boolean(simple_wait(e, &s->wq, [s] { if (s->count > 0) { s->count--; return true; } return false; }, 0));
        };
        T["semaphore_acquire_timeout"] = [](Engine& e, const Args& a) {
            Sema* s;
            { std::lock_guard<std::mutex> l(RT().m); s = get_obj<Sema>(H(a, 0, "semaphore_acquire_timeout"), "semaphore"); }
            return Ret::boolean(simple_wait(e, &s->wq, [s] { if (s->count > 0) { s->count--; return true; } return false; },
                                            std::max(0.0, opt_num(a, 1, 0))));
        };
        T["semaphore_release"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Sema* s = get_obj<Sema>(H(a, 0, "semaphore_release"), "semaphore");
            int64_t n = (int64_t)opt_num(a, 1, 1);
            if (s->max >= 0 && s->count + n > s->max) return Ret::boolean(false);
            s->count += n;
            wake_all(s->wq);
            return Ret::boolean(true);
        };
        T["semaphore_value"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(get_obj<Sema>(H(a, 0, "semaphore_value"), "semaphore")->count);
        };

        // ── event ───────────────────────────────────────────────────────────
        T["event_create"] = [](Engine& e, const Args&) {
            current(e);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(std::make_shared<Event>()));
        };
        T["event_set"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Event* ev = get_obj<Event>(H(a, 0, "event_set"), "event");
            ev->flag = true; wake_all(ev->wq);
            return Ret::none();
        };
        T["event_clear"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            get_obj<Event>(H(a, 0, "event_clear"), "event")->flag = false;
            return Ret::none();
        };
        T["event_is_set"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_obj<Event>(H(a, 0, "event_is_set"), "event")->flag);
        };
        T["event_wait"] = [](Engine& e, const Args& a) {
            Event* ev;
            { std::lock_guard<std::mutex> l(RT().m); ev = get_obj<Event>(H(a, 0, "event_wait"), "event"); }
            return Ret::boolean(simple_wait(e, &ev->wq, [ev] { return ev->flag; }, -1));
        };
        T["event_wait_timeout"] = [](Engine& e, const Args& a) {
            Event* ev;
            { std::lock_guard<std::mutex> l(RT().m); ev = get_obj<Event>(H(a, 0, "event_wait_timeout"), "event"); }
            return Ret::boolean(simple_wait(e, &ev->wq, [ev] { return ev->flag; }, std::max(0.0, opt_num(a, 1, 0))));
        };

        // ── barrier ─────────────────────────────────────────────────────────
        T["barrier_create"] = [](Engine& e, const Args& a) {
            current(e);
            auto b = std::make_shared<Barrier>();
            b->n = (int64_t)opt_num(a, 0, 1);
            if (b->n < 1) raise("ValueError", "barrier_create: parties must be >= 1");
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(b));
        };
        T["barrier_wait"] = [](Engine& e, const Args& a) -> Ret {
            ThreadRec* self = current(e);
            Barrier* b; int64_t my;
            {
                std::lock_guard<std::mutex> l(RT().m);
                b = get_obj<Barrier>(H(a, 0, "barrier_wait"), "barrier");
                check_cancel_locked(self);
                my = b->gen;
                if (++b->count == b->n) { b->gen++; b->count = 0; wake_all(b->wq); return Ret::integer(my); }
            }
            try { block_released(self, {&b->wq}, [b, my] { return b->gen != my; }, Deadline::never(), nullptr); }
            catch (...) {
                std::lock_guard<std::mutex> l(RT().m);
                if (b->gen == my && b->count > 0) b->count--;
                throw;
            }
            return Ret::integer(my);
        };
        T["barrier_wait_timeout"] = [](Engine& e, const Args& a) -> Ret {
            ThreadRec* self = current(e);
            Barrier* b; int64_t my;
            double ms = std::max(0.0, opt_num(a, 1, 0));
            {
                std::lock_guard<std::mutex> l(RT().m);
                b = get_obj<Barrier>(H(a, 0, "barrier_wait_timeout"), "barrier");
                check_cancel_locked(self);
                my = b->gen;
                if (++b->count == b->n) { b->gen++; b->count = 0; wake_all(b->wq); return Ret::integer(my); }
            }
            bool ok = false;
            try { ok = block_released(self, {&b->wq}, [b, my] { return b->gen != my; }, Deadline::in_ms(ms), nullptr); }
            catch (...) {
                std::lock_guard<std::mutex> l(RT().m);
                if (b->gen == my && b->count > 0) b->count--;
                throw;
            }
            std::lock_guard<std::mutex> l(RT().m);
            if (!ok && b->gen == my) { if (b->count > 0) b->count--; return Ret::integer(-1); }
            return Ret::integer(my);
        };
        T["barrier_parties"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(get_obj<Barrier>(H(a, 0, "barrier_parties"), "barrier")->n);
        };
        T["barrier_waiting"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(get_obj<Barrier>(H(a, 0, "barrier_waiting"), "barrier")->count);
        };
        T["barrier_generation"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(get_obj<Barrier>(H(a, 0, "barrier_generation"), "barrier")->gen);
        };

        // ── latch ───────────────────────────────────────────────────────────
        T["latch_create"] = [](Engine& e, const Args& a) {
            current(e);
            auto x = std::make_shared<Latch>();
            x->count = std::max<int64_t>(0, (int64_t)opt_num(a, 0, 1));
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(x));
        };
        T["latch_count_down"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Latch* x = get_obj<Latch>(H(a, 0, "latch_count_down"), "latch");
            x->count = std::max<int64_t>(0, x->count - (int64_t)opt_num(a, 1, 1));
            if (x->count == 0) wake_all(x->wq);
            return Ret::integer(x->count);
        };
        T["latch_count"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(get_obj<Latch>(H(a, 0, "latch_count"), "latch")->count);
        };
        T["latch_wait"] = [](Engine& e, const Args& a) {
            Latch* x;
            { std::lock_guard<std::mutex> l(RT().m); x = get_obj<Latch>(H(a, 0, "latch_wait"), "latch"); }
            return Ret::boolean(simple_wait(e, &x->wq, [x] { return x->count == 0; }, -1));
        };
        T["latch_wait_timeout"] = [](Engine& e, const Args& a) {
            Latch* x;
            { std::lock_guard<std::mutex> l(RT().m); x = get_obj<Latch>(H(a, 0, "latch_wait_timeout"), "latch"); }
            return Ret::boolean(simple_wait(e, &x->wq, [x] { return x->count == 0; }, std::max(0.0, opt_num(a, 1, 0))));
        };

        // ── atomics ─────────────────────────────────────────────────────────
        T["atomic_new"] = [](Engine& e, const Args& a) {
            current(e);
            auto x = std::make_shared<Atom>();
            x->v = (int64_t)opt_num(a, 0, 0);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(x));
        };
        T["atomic_create"] = T["atomic_new"];
        T["atomic_get"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(get_obj<Atom>(H(a, 0, "atomic_get"), "atomic")->v);
        };
        T["atomic_set"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            get_obj<Atom>(H(a, 0, "atomic_set"), "atomic")->v = (int64_t)opt_num(a, 1, 0);
            return Ret::none();
        };
        T["atomic_add"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Atom* x = get_obj<Atom>(H(a, 0, "atomic_add"), "atomic");
            x->v += (int64_t)opt_num(a, 1, 1);
            return Ret::integer(x->v);
        };
        T["atomic_sub"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Atom* x = get_obj<Atom>(H(a, 0, "atomic_sub"), "atomic");
            x->v -= (int64_t)opt_num(a, 1, 1);
            return Ret::integer(x->v);
        };
        T["atomic_inc"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(++get_obj<Atom>(H(a, 0, "atomic_inc"), "atomic")->v);
        };
        T["atomic_dec"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(--get_obj<Atom>(H(a, 0, "atomic_dec"), "atomic")->v);
        };
        T["atomic_cas"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Atom* x = get_obj<Atom>(H(a, 0, "atomic_cas"), "atomic");
            int64_t expected = (int64_t)opt_num(a, 1, 0), nv = (int64_t)opt_num(a, 2, 0);
            if (x->v != expected) return Ret::boolean(false);
            x->v = nv;
            return Ret::boolean(true);
        };
        T["atomic_compare_and_swap"] = T["atomic_cas"];
        T["atomic_exchange"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Atom* x = get_obj<Atom>(H(a, 0, "atomic_exchange"), "atomic");
            int64_t old = x->v;
            x->v = (int64_t)opt_num(a, 1, 0);
            return Ret::integer(old);
        };

        // ── channels ────────────────────────────────────────────────────────
        T["chan_create"] = [](Engine& e, const Args& a) {
            current(e);
            auto c = std::make_shared<Chan>();
            c->cap = (int64_t)opt_num(a, 0, 0);
            if (c->cap < 0) c->cap = -1;
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(c));
        };
        T["channel_create"] = T["chan_create"];
        T["chan_send"] = [](Engine& e, const Args& a) {
            if (a.size() < 2) raise("TypeError", "chan_send(ch, value)");
            return Ret::boolean(chan_send(e, H(a, 0, "chan_send"), a.box(1), 0, -1));
        };
        T["chan_try_send"] = [](Engine& e, const Args& a) {
            if (a.size() < 2) raise("TypeError", "chan_try_send(ch, value)");
            return Ret::boolean(chan_send(e, H(a, 0, "chan_try_send"), a.box(1), 0, 0));
        };
        T["chan_send_timeout"] = [](Engine& e, const Args& a) {
            if (a.size() < 3) raise("TypeError", "chan_send_timeout(ch, value, ms)");
            return Ret::boolean(chan_send(e, H(a, 0, "chan_send_timeout"), a.box(1), 0, std::max(0.0, a.as_num(2))));
        };
        T["chan_recv"] = [](Engine& e, const Args& a) {
            bool ok; BoxPtr v = chan_recv(e, H(a, 0, "chan_recv"), -1, ok);
            return ok ? boxret(v) : Ret::none();
        };
        T["chan_recv_ok"] = [](Engine& e, const Args& a) {
            bool ok; BoxPtr v = chan_recv(e, H(a, 0, "chan_recv_ok"), -1, ok);
            return Ret::lst({ok ? boxret(v) : Ret::none(), Ret::boolean(ok)});
        };
        T["chan_try_recv"] = [](Engine& e, const Args& a) {
            bool ok; BoxPtr v = chan_recv(e, H(a, 0, "chan_try_recv"), 0, ok);
            return Ret::lst({ok ? boxret(v) : Ret::none(), Ret::boolean(ok)});
        };
        T["chan_recv_timeout"] = [](Engine& e, const Args& a) {
            bool ok; BoxPtr v = chan_recv(e, H(a, 0, "chan_recv_timeout"), std::max(0.0, opt_num(a, 1, 0)), ok);
            return Ret::lst({ok ? boxret(v) : Ret::none(), Ret::boolean(ok)});
        };
        T["chan_close"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Chan* c = chan_get_locked(H(a, 0, "chan_close"));
            if (c->closed) return Ret::boolean(false);
            c->closed = true; wake_all(c->wq);
            return Ret::boolean(true);
        };
        T["chan_closed"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(chan_get_locked(H(a, 0, "chan_closed"))->closed);
        };
        T["chan_drained"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Chan* c = chan_get_locked(H(a, 0, "chan_drained"));
            return Ret::boolean(c->closed && c->items.empty());
        };
        T["chan_len"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Chan* c = chan_get_locked(H(a, 0, "chan_len"));
            return Ret::integer(c->cap == 0 ? 0 : (int64_t)c->items.size());
        };
        T["chan_cap"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(chan_get_locked(H(a, 0, "chan_cap"))->cap);
        };
        T["chan_select"] = [](Engine& e, const Args& a) {
            if (a.size() < 1 || !a.is_list(0)) raise("TypeError", "chan_select(cases, timeout_ms=-1): cases is a list of [\"recv\", ch] / [\"send\", ch, value]");
            auto cases = a.list(0);
            std::vector<std::pair<bool, int64_t>> spec;
            std::vector<BoxPtr> vals; std::vector<double> prios;
            for (size_t i = 0; i < cases->size(); i++) {
                if (!cases->is_list(i)) raise("TypeError", "chan_select: case " + std::to_string(i) + " must be a list");
                auto c = cases->list(i);
                if (c->size() < 2) raise("TypeError", "chan_select: case " + std::to_string(i) + " is too short");
                std::string op = c->as_str(0);
                bool send = op == "send";
                if (!send && op != "recv") raise("ValueError", "chan_select: case op must be \"recv\" or \"send\", got \"" + op + "\"");
                if (send && c->size() < 3) raise("TypeError", "chan_select: send case needs a value");
                spec.push_back({send, H(*c, 1, "chan_select")});
                vals.push_back(send ? c->box(2) : nullptr);
                prios.push_back(send ? priority_of(*c, 2) : 0);
            }
            BoxPtr v; bool ok = false;
            int idx = chan_select(e, spec, vals, prios, opt_num(a, 1, -1), v, ok);
            return Ret::lst({Ret::integer(idx), ok && v ? boxret(v) : Ret::none(), Ret::boolean(ok)});
        };

        // ── queues (channels with a Python-style API) ───────────────────────
        T["queue_create"] = [](Engine& e, const Args& a) {
            current(e);
            auto c = std::make_shared<Chan>();
            int64_t maxsize = (int64_t)opt_num(a, 0, 0);
            c->cap = maxsize > 0 ? maxsize : -1;
            std::string kind = a.size() > 1 && a.is_string(1) ? a.as_str(1) : "fifo";
            if (kind == "lifo") c->kind = Chan::LIFO;
            else if (kind == "priority") c->kind = Chan::PRIO;
            else if (kind != "fifo") raise("ValueError", "queue_create: kind must be \"fifo\", \"lifo\" or \"priority\"");
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(c));
        };
        T["queue_put"] = [](Engine& e, const Args& a) {
            if (a.size() < 2) raise("TypeError", "queue_put(q, item)");
            return Ret::boolean(chan_send(e, H(a, 0, "queue_put"), a.box(1), priority_of(a, 1), -1));
        };
        T["queue_try_put"] = [](Engine& e, const Args& a) {
            if (a.size() < 2) raise("TypeError", "queue_try_put(q, item)");
            return Ret::boolean(chan_send(e, H(a, 0, "queue_try_put"), a.box(1), priority_of(a, 1), 0));
        };
        T["queue_put_timeout"] = [](Engine& e, const Args& a) {
            if (a.size() < 3) raise("TypeError", "queue_put_timeout(q, item, ms)");
            return Ret::boolean(chan_send(e, H(a, 0, "queue_put_timeout"), a.box(1), priority_of(a, 1), std::max(0.0, a.as_num(2))));
        };
        T["queue_peek"] = [](Engine& e, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Chan* c = chan_get_locked(H(a, 0, "queue_peek"));
            if (c->items.empty()) return Ret::lst({Ret::none(), Ret::boolean(false)});
            const auto& it = c->kind == Chan::LIFO ? c->items.back() : c->items.front();
            (void)e;
            return Ret::lst({boxret(it.v), Ret::boolean(true)});
        };
        T["chan_peek"] = T["queue_peek"];
        T["queue_get"] = T["chan_recv"];
        T["queue_try_get"] = T["chan_try_recv"];
        T["queue_get_timeout"] = T["chan_recv_timeout"];
        T["queue_close"] = T["chan_close"];
        T["queue_size"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer((int64_t)chan_get_locked(H(a, 0, "queue_size"))->items.size());
        };
        T["queue_empty"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(chan_get_locked(H(a, 0, "queue_empty"))->items.empty());
        };
        T["queue_full"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Chan* c = chan_get_locked(H(a, 0, "queue_full"));
            return Ret::boolean(c->cap > 0 && (int64_t)c->items.size() >= c->cap);
        };

        // ── futures ─────────────────────────────────────────────────────────
        T["future_create"] = [](Engine& e, const Args&) {
            current(e);
            auto f = std::make_shared<Future>(); f->engine = &e;
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(f));
        };
        T["future_set_result"] = [](Engine& e, const Args& a) {
            Future* f;
            { std::lock_guard<std::mutex> l(RT().m); f = get_obj<Future>(H(a, 0, "future_set_result"), "future");
              if (f->done) raise("RuntimeError", "future#" + std::to_string(f->id) + " is already done"); }
            future_complete(e, f, a.size() > 1 ? a.box(1) : e.box_none(), false, NyError(), false);
            return Ret::none();
        };
        T["future_set_exception"] = [](Engine& e, const Args& a) {
            Future* f;
            { std::lock_guard<std::mutex> l(RT().m); f = get_obj<Future>(H(a, 0, "future_set_exception"), "future");
              if (f->done) raise("RuntimeError", "future#" + std::to_string(f->id) + " is already done"); }
            std::string type = "RuntimeError", msg = a.size() > 1 ? a.as_str(1) : "";
            if (a.size() > 2) { type = a.as_str(1); msg = a.as_str(2); }
            future_complete(e, f, nullptr, true, NyError::make(type, msg), false);
            return Ret::none();
        };
        T["future_result"] = [](Engine& e, const Args& a) {
            return boxret(future_result(e, H(a, 0, "future_result"), opt_num(a, 1, -1), false, nullptr));
        };
        T["future_exception"] = [](Engine& e, const Args& a) {
            std::string txt;
            future_result(e, H(a, 0, "future_exception"), opt_num(a, 1, -1), true, &txt);
            return txt.empty() ? Ret::none() : Ret::str(txt);
        };
        T["future_done"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_obj<Future>(H(a, 0, "future_done"), "future")->done);
        };
        T["future_running"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_obj<Future>(H(a, 0, "future_running"), "future")->running);
        };
        T["future_cancelled"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_obj<Future>(H(a, 0, "future_cancelled"), "future")->cancelled);
        };
        T["future_cancel"] = [](Engine& e, const Args& a) {
            Future* f;
            {
                std::lock_guard<std::mutex> l(RT().m);
                f = get_obj<Future>(H(a, 0, "future_cancel"), "future");
                if (f->done || f->running) return Ret::boolean(false);
            }
            future_complete(e, f, nullptr, false, NyError(), true);
            return Ret::boolean(true);
        };
        T["future_add_done_callback"] = [](Engine& e, const Args& a) {
            BoxPtr cb = need_callable(e, a, 1, "future_add_done_callback");
            Future* f; bool run_now = false;
            {
                std::lock_guard<std::mutex> l(RT().m);
                f = get_obj<Future>(H(a, 0, "future_add_done_callback"), "future");
                if (f->done) run_now = true; else f->callbacks.push_back(cb);
            }
            if (run_now) e.call(cb, {e.box_int(f->id)});
            return Ret::none();
        };
        T["as_completed"] = [](Engine& e, const Args& a) {
            if (a.size() < 1 || !a.is_list(0)) raise("TypeError", "as_completed(futures, timeout_ms=-1)");
            auto l = a.list(0);
            std::vector<Future*> fs;
            {
                std::lock_guard<std::mutex> g(RT().m);
                for (size_t i = 0; i < l->size(); i++) fs.push_back(get_obj<Future>(H(*l, i, "as_completed"), "future"));
            }
            ThreadRec* self = current(e);
            auto all = [fs] { for (auto* f : fs) if (!f->done) return false; return true; };
            bool ok;
            {
                std::unique_lock<std::mutex> lk(RT().m);
                ok = all();
            }
            if (!ok) {
                GilRelease rel;
                std::unique_lock<std::mutex> lk(RT().m);
                std::vector<WQ*> qs;
                for (auto* f : fs) { qs.push_back(&f->wq); f->wq.push_back(self); }
                struct Unreg { ThreadRec* s; std::vector<WQ*>& qs;
                    ~Unreg() { for (auto* q : qs) { auto it = std::find(q->begin(), q->end(), s); if (it != q->end()) q->erase(it); } } } unreg{self, qs};
                ok = block(lk, self, {}, all, Deadline::in_ms(opt_num(a, 1, -1)), nullptr);
            }
            if (!ok) raise("TimeoutError", "as_completed: not all futures finished in time");
            std::lock_guard<std::mutex> g(RT().m);
            std::vector<Future*> sorted = fs;
            std::stable_sort(sorted.begin(), sorted.end(), [](Future* x, Future* y) { return x->done_seq < y->done_seq; });
            std::vector<Ret> out;
            for (auto* f : sorted) out.push_back(Ret::integer(f->id));
            return Ret::lst(std::move(out));
        };

        // lib/thread.ny defines an object-level as_completed(); the native stays
        // reachable under this name.
        T["futures_as_completed"] = T["as_completed"];

        // ── thread pool ─────────────────────────────────────────────────────
        T["pool_create"] = [](Engine& e, const Args& a) {
            ensure_active(e);
            int64_t n = std::max<int64_t>(1, (int64_t)opt_num(a, 0, 4));
            auto p = std::make_shared<Pool>();
            int64_t pid;
            {
                std::lock_guard<std::mutex> l(RT().m);
                pid = add_obj(p);
                RT().pools.push_back(pid);
            }
            Pool* pp = p.get();
            for (int64_t i = 0; i < n; i++) {
                int64_t tid = start_thread(e, [pp](ThreadRec* self) { return pool_worker(*self->engine, pp, self); },
                                           "pool-" + std::to_string(pid) + "-worker-" + std::to_string(i), true);
                std::lock_guard<std::mutex> l(RT().m);
                p->workers.push_back(tid);
            }
            return Ret::integer(pid);
        };
        T["pool_submit"] = [](Engine& e, const Args& a) {
            BoxPtr fn = need_callable(e, a, 1, "pool_submit");
            auto args = rest(a, 2);
            std::lock_guard<std::mutex> l(RT().m);
            Pool* p = get_obj<Pool>(H(a, 0, "pool_submit"), "pool");
            if (p->shutdown) raise("RuntimeError", "cannot submit to pool#" + std::to_string(p->id) + " after shutdown");
            auto f = std::make_shared<Future>(); f->engine = &e;
            int64_t fid = add_obj(f);
            p->jobs.push_back({fid, fn, args});
            wake_all(p->wq);
            return Ret::integer(fid);
        };
        T["pool_shutdown"] = [](Engine& e, const Args& a) {
            bool wait = a.size() > 1 ? a.truthy(1) : true;
            bool cancel = a.size() > 2 ? a.truthy(2) : false;
            std::vector<int64_t> workers;
            std::vector<Future*> dropped;
            {
                std::lock_guard<std::mutex> l(RT().m);
                Pool* p = get_obj<Pool>(H(a, 0, "pool_shutdown"), "pool");
                p->shutdown = true;
                if (cancel) {
                    for (auto& j : p->jobs) dropped.push_back(get_obj<Future>(j.fid, "future"));
                    p->jobs.clear();
                }
                wake_all(p->wq);
                workers = p->workers;
            }
            for (auto* f : dropped) future_complete(e, f, nullptr, false, NyError(), true);
            if (wait) for (auto t : workers) join_thread(e, t, -1);
            return Ret::boolean(true);
        };
        T["pool_size"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer((int64_t)get_obj<Pool>(H(a, 0, "pool_size"), "pool")->workers.size());
        };

        // ── timer ───────────────────────────────────────────────────────────
        T["timer_create"] = [](Engine& e, const Args& a) {
            double ms = opt_num(a, 0, 0);
            BoxPtr fn = need_callable(e, a, 1, "timer_create");
            auto args = rest(a, 2);
            auto tm = std::make_shared<Timer>();
            Timer* tp = tm.get();
            int64_t tid = start_thread(e, [tp, fn, args, ms](ThreadRec* self) -> BoxPtr {
                bool cancelled = block_released(self, {&tp->wq}, [tp] { return tp->cancelled; },
                                                Deadline::in_ms(std::max(0.0, ms)), nullptr, false);
                {
                    std::lock_guard<std::mutex> l(RT().m);
                    if (cancelled || tp->cancelled) return self->engine->box_none();
                    tp->fired = true;
                }
                return self->engine->call(fn, args);
            }, "timer", false);
            std::lock_guard<std::mutex> l(RT().m);
            tm->id = tid;
            RT().objs[tid] = tm;              // the timer is addressed by its thread handle
            return Ret::integer(tid);
        };
        T["timer_cancel"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Timer* t = get_obj<Timer>(H(a, 0, "timer_cancel"), "timer");
            if (t->fired || t->cancelled) return Ret::boolean(false);
            t->cancelled = true;
            wake_all(t->wq);
            return Ret::boolean(true);
        };
        T["timer_fired"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_obj<Timer>(H(a, 0, "timer_fired"), "timer")->fired);
        };

        // ── task groups ─────────────────────────────────────────────────────
        T["taskgroup_create"] = [](Engine& e, const Args&) {
            current(e);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(std::make_shared<Group>()));
        };
        T["taskgroup_spawn"] = [](Engine& e, const Args& a) {
            BoxPtr fn = need_callable(e, a, 1, "taskgroup_spawn");
            auto args = rest(a, 2);
            int64_t gid = H(a, 0, "taskgroup_spawn");
            Group* g; bool cancelled;
            {
                std::lock_guard<std::mutex> l(RT().m);
                g = get_obj<Group>(gid, "task group");
                if (g->closed) raise("RuntimeError", "task group#" + std::to_string(gid) + " has already been joined");
                cancelled = g->cancelled;
            }
            int64_t tid = start_thread(e, [fn, args](ThreadRec* self) { return self->engine->call(fn, args); },
                                       "", false, gid, cancelled);
            std::lock_guard<std::mutex> l(RT().m);
            g->children.push_back(tid);
            return Ret::integer(tid);
        };
        T["taskgroup_cancel"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Group* g = get_obj<Group>(H(a, 0, "taskgroup_cancel"), "task group");
            g->cancelled = true;
            for (auto cid : g->children) cancel_thread_locked(get_thread_locked(cid));
            return Ret::none();
        };
        T["taskgroup_join"] = [](Engine& e, const Args& a) {
            ThreadRec* self = current(e);
            Group* g;
            {
                std::lock_guard<std::mutex> l(RT().m);
                g = get_obj<Group>(H(a, 0, "taskgroup_join"), "task group");
            }
            auto all_done = [g] {
                for (auto cid : g->children) if (!RT().threads[cid]->done) return false;
                return true;
            };
            {
                std::unique_lock<std::mutex> lk(RT().m);
                if (!all_done()) {
                    lk.unlock();
                    // Waiting for our own children is not interrupted by our own
                    // cancellation: they must be collected either way.
                    block_released(self, {&g->wq}, all_done, Deadline::never(), nullptr, false);
                }
            }
            std::lock_guard<std::mutex> l(RT().m);
            g->closed = true;
            for (auto cid : g->children) { auto* t = RT().threads[cid].get(); t->joined = true; t->reported = true; }
            if (g->failed) throw g->first;
            std::vector<Ret> out;
            for (auto cid : g->children) {
                auto* t = RT().threads[cid].get();
                out.push_back(t->result ? Ret::boxed(t->result) : Ret::none());
            }
            return Ret::lst(std::move(out));
        };
        T["taskgroup_size"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer((int64_t)get_obj<Group>(H(a, 0, "taskgroup_size"), "task group")->children.size());
        };

        // ── deadlock / lock order ───────────────────────────────────────────
        T["lockdep_enable"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            bool prev = RT().lockdep;
            RT().lockdep = a.size() > 0 ? a.truthy(0) : true;
            return Ret::boolean(prev);
        };
        T["lockdep_enabled"] = [](Engine&, const Args&) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(RT().lockdep);
        };
        T["lockdep_reset"] = [](Engine&, const Args&) {
            std::lock_guard<std::mutex> l(RT().m);
            RT().order.clear();
            return Ret::none();
        };

        // ── async ───────────────────────────────────────────────────────────
        T["async_body_begin"] = [](Engine&, const Args&) {
            // true: this call of an `async def` should produce a coroutine;
            // false: the coroutine is being run now, execute the body.
            if (t_async_token) { t_async_token = false; return Ret::boolean(false); }
            return Ret::boolean(true);
        };
        T["async_coroutine_def"] = [](Engine& e, const Args& a) {
            current(e);
            auto c = std::make_shared<Coro>();
            c->fn = a.size() > 0 ? a.box(0) : nullptr;
            c->name = a.size() > 1 ? a.as_str(1) : "coroutine";
            c->args = rest(a, 2);
            c->is_def = true;
            if (!c->fn || !e.is_callable(c->fn)) raise("TypeError", "async function '" + c->name + "' could not refer to itself");
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(c, true));
        };
        T["async_coroutine"] = [](Engine& e, const Args& a) {
            current(e);
            auto c = std::make_shared<Coro>();
            c->fn = need_callable(e, a, 0, "async_coroutine");
            c->name = e.describe(c->fn);
            c->args = rest(a, 1);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(c, true));
        };
        T["async_is_coroutine"] = [](Engine&, const Args& a) {
            if (a.size() < 1 || !a.is_number(0)) return Ret::boolean(false);
            std::lock_guard<std::mutex> l(RT().m);
            auto it = RT().objs.find(a.as_int(0));
            return Ret::boolean(it != RT().objs.end() && dynamic_cast<Coro*>(it->second.get()));
        };
        T["async_await"] = [](Engine& e, const Args& a) -> Ret {
            if (a.size() < 1) return Ret::none();
            auto it = item_of(e, a, 0);
            return boxret(await_value(e, it.h, it.is_handle, it.v));
        };
        T["async_run"] = [](Engine& e, const Args& a) -> Ret {
            if (a.size() < 1) raise("TypeError", "async_run(coroutine)");
            Awaitable::Item it{false, 0, nullptr};
            if (a.is_number(0)) { it.is_handle = true; it.h = a.as_int(0); }
            else if (e.is_callable(a.box(0))) {
                // async_run(main): call the async function to get its coroutine.
                BoxPtr r = e.call(a.box(0), std::vector<BoxPtr>(rest(a, 1)));
                if (!e.unbox_int(r, it.h)) raise("TypeError", "async_run(): the function did not return a coroutine");
                it.is_handle = true;
            } else raise("TypeError", "async_run() expects a coroutine");
            return boxret(async_run(e, it));
        };
        T["async_sleep"] = [](Engine& e, const Args& a) {
            current(e);
            auto aw = std::make_shared<Awaitable>();
            aw->kind = Awaitable::SLEEP;
            aw->secs = opt_num(a, 0, 0);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(aw, true));
        };
        T["create_task"] = [](Engine& e, const Args& a) {
            ThreadRec* self = current(e);
            if (!self->task) raise("RuntimeError", "create_task: no running event loop (call it inside async_run)");
            if (a.size() < 1) raise("TypeError", "create_task(coroutine)");
            Awaitable::Item it = item_of(e, a, 0);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(ensure_task_locked(self->task->loop, e, it)->id);
        };
        T["async_create_task"] = T["create_task"];
        T["gather"] = [](Engine& e, const Args& a) {
            current(e);
            auto aw = std::make_shared<Awaitable>();
            aw->kind = Awaitable::GATHER;
            for (size_t i = 0; i < a.size(); i++) aw->items.push_back(item_of(e, a, i));
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(aw, true));
        };
        T["async_gather"] = T["gather"];
        T["gather_settled"] = [](Engine& e, const Args& a) {
            current(e);
            auto aw = std::make_shared<Awaitable>();
            aw->kind = Awaitable::GATHER;
            aw->return_exceptions = true;
            for (size_t i = 0; i < a.size(); i++) aw->items.push_back(item_of(e, a, i));
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(aw, true));
        };
        T["wait_for"] = [](Engine& e, const Args& a) {
            current(e);
            if (a.size() < 2) raise("TypeError", "wait_for(awaitable, timeout_seconds)");
            auto aw = std::make_shared<Awaitable>();
            aw->kind = Awaitable::WAIT_FOR;
            aw->target = item_of(e, a, 0);
            aw->secs = a.as_num(1);
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::integer(add_obj(aw, true));
        };
        T["async_wait_for"] = T["wait_for"];
        T["async_call_later"] = [](Engine& e, const Args& a) {
            current(e);
            auto aw = std::make_shared<Awaitable>();
            aw->kind = Awaitable::CALL_LATER;
            aw->secs = opt_num(a, 0, 0);
            aw->fn = need_callable(e, a, 1, "async_call_later");
            aw->args = rest(a, 2);
            ThreadRec* self = current(e);
            std::lock_guard<std::mutex> l(RT().m);
            int64_t h = add_obj(aw, true);
            if (self->task) return Ret::integer(ensure_task_locked(self->task->loop, e, Awaitable::Item{true, h, nullptr})->id);
            return Ret::integer(h);
        };
        T["task_cancel"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(task_cancel_locked(get_obj<Task>(H(a, 0, "task_cancel"), "task")));
        };
        T["task_done"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_obj<Task>(H(a, 0, "task_done"), "task")->done);
        };
        T["task_cancelled"] = [](Engine&, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            return Ret::boolean(get_obj<Task>(H(a, 0, "task_cancelled"), "task")->cancelled);
        };
        T["task_result"] = [](Engine& e, const Args& a) {
            std::lock_guard<std::mutex> l(RT().m);
            Task* t = get_obj<Task>(H(a, 0, "task_result"), "task");
            if (!t->done) raise("RuntimeError", "task '" + t->name + "' is not done");
            return boxret(task_outcome_locked(e, t));
        };
        T["async_current_task"] = [](Engine& e, const Args&) {
            ThreadRec* self = current(e);
            return Ret::integer(self->task ? self->task->id : 0);
        };

        // ── signals (section 9) ─────────────────────────────────────────────
        register_signal_builtins(T);

        // ── exception constructors ──────────────────────────────────────────
        // (engines turn the returned text into their own exception values)
        return m;
    }();
    return *tbl;
}


// ════════════════════════════════════════════════════════════════════════════
// 9. Signals and I/O waits (round 77)
// ════════════════════════════════════════════════════════════════════════════
//
// Signals. The C-level handler only records the signal (one atomic flag per
// signal) and wakes the main thread: through a self-pipe that its I/O polls
// and its event loop also wait on (an event on Windows), and through the
// 50 ms slices of its other waits. The handlers themselves - Nython
// callables, or the default SIGINT one, which raises KeyboardInterrupt - run
// on the main thread, as in Python: at the next statement (the engines check
// signal_pending() where they call tick()), or, when the main thread was
// waiting, inside the interrupted builtin, which then resumes its wait with
// the deadline it started with (PEP 475; dispatch).
//
// A channel can subscribe to signals (signal_notify): every delivery is also
// sent to it, without ever blocking (a full channel drops it) - Go's
// signal.Notify, so one select can wait for signals and messages alike, and
// a thread or an async task can wait for a signal without a handler.

#ifdef _WIN32
static HANDLE g_sig_event = nullptr;
#else
static int g_sig_pipe[2] = {-1, -1};
#endif

static void sig_wake_open() {
#ifdef _WIN32
    if (!g_sig_event) g_sig_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
#else
    if (g_sig_pipe[0] >= 0) return;
    int p[2];
    if (::pipe(p) == 0) {
        for (int k = 0; k < 2; k++) {
            ::fcntl(p[k], F_SETFL, ::fcntl(p[k], F_GETFL) | O_NONBLOCK);
            ::fcntl(p[k], F_SETFD, FD_CLOEXEC);
        }
        g_sig_pipe[0] = p[0];
        g_sig_pipe[1] = p[1];
    }
#endif
}
static void sig_wake_drain() {
#ifdef _WIN32
    if (g_sig_event) ResetEvent(g_sig_event);
#else
    if (g_sig_pipe[0] < 0) return;
    char buf[64];
    while (::read(g_sig_pipe[0], buf, sizeof buf) > 0) {}
#endif
}
// Async-signal-safe: atomics and write(2) only.
static void ny_signal_trampoline(int sig) {
    int saved = errno;
    if (sig > 0 && sig < kMaxSig) g_sig_flags[sig].store(1, std::memory_order_relaxed);
    g_sig_any.store(1, std::memory_order_release);
#ifdef _WIN32
    if (g_sig_event) SetEvent(g_sig_event);
    std::signal(sig, ny_signal_trampoline);   // the CRT resets a handler once it runs
#else
    if (g_sig_pipe[1] >= 0) { char c = (char)sig; ssize_t r = ::write(g_sig_pipe[1], &c, 1); (void)r; }
#endif
    errno = saved;
}

struct SigEntry {
    int kind = 0;                 // 0 SIG_DFL, 1 SIG_IGN, 2 a callable, 3 default_int_handler
    Engine* eng = nullptr;
    BoxPtr fn;
    std::vector<std::pair<int64_t, Engine*>> chans;   // signal_notify subscribers
};
static std::mutex& sig_mu() { static std::mutex* m = new std::mutex(); return *m; }
static std::map<int, SigEntry>& sig_tab() { static auto* t = new std::map<int, SigEntry>(); return *t; }

static bool sig_valid(int sig) {
#ifdef _WIN32
    return sig == SIGINT || sig == SIGTERM || sig == SIGABRT || sig == SIGFPE || sig == SIGILL ||
           sig == SIGSEGV || sig == SIGBREAK;
#else
    return sig > 0 && sig < kMaxSig;
#endif
}
static void os_set_handler(int sig, bool ours, int kind) {
#ifdef _WIN32
    std::signal(sig, ours ? ny_signal_trampoline : kind == 1 ? SIG_IGN : SIG_DFL);
#else
    struct sigaction sa;
    std::memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    // No SA_RESTART: a blocking read returns EINTR, so input(), recv() and
    // the process waits notice the signal (and retry when its handler
    // returns), as in Python.
    sa.sa_flags = 0;
    sa.sa_handler = ours ? ny_signal_trampoline : kind == 1 ? SIG_IGN : SIG_DFL;
    sigaction(sig, &sa, nullptr);
#endif
}
static void sig_apply_locked(int sig, SigEntry& e) {
    bool ours = e.kind >= 2 || !e.chans.empty();
    os_set_handler(sig, ours, e.kind);
    if (ours) g_sig_armed.store(true, std::memory_order_relaxed);
}

static bool signals_can_wake() {
    std::lock_guard<std::mutex> l(sig_mu());
    for (auto& kv : sig_tab()) if (kv.second.kind == 2 || !kv.second.chans.empty()) return true;
    return false;
}

void install_default_signals() {
    sig_wake_open();
#ifndef _WIN32
    // As Python: a write to a closed socket or pipe fails with EPIPE
    // (BrokenPipeError) instead of killing the process.
    std::signal(SIGPIPE, SIG_IGN);
#endif
    std::lock_guard<std::mutex> l(sig_mu());
    auto& e = sig_tab()[SIGINT];
    if (e.kind == 0 && !e.fn && e.chans.empty()) { e.kind = 3; sig_apply_locked(SIGINT, e); }
}

static void mark_rest_pending(int from) {
    for (int s = from; s < kMaxSig; s++)
        if (g_sig_flags[s].load(std::memory_order_relaxed)) { g_sig_any.store(1, std::memory_order_release); return; }
}

void run_signal_handlers() {
    if (!g_sig_any.load(std::memory_order_acquire) || !is_main_thread()) return;
    g_sig_any.store(0, std::memory_order_release);
    sig_wake_drain();
    for (int sig = 1; sig < kMaxSig; sig++) {
        if (!g_sig_flags[sig].exchange(0, std::memory_order_acq_rel)) continue;
        SigEntry ent;
        {
            std::lock_guard<std::mutex> l(sig_mu());
            auto it = sig_tab().find(sig);
            if (it == sig_tab().end()) continue;
            ent = it->second;
        }
        for (auto& ch : ent.chans) {
            try { chan_send(*ch.second, ch.first, ch.second->box_int(sig), 0, 0); }
            catch (NyError&) { /* a closed channel just misses it */ }
        }
        try {
            if (ent.kind == 3) throw NyError::make("KeyboardInterrupt", "");
            if (ent.kind == 2 && ent.eng && ent.fn)
                ent.eng->call(ent.fn, {ent.eng->box_int(sig), ent.eng->box_none()});
        } catch (...) {
            mark_rest_pending(sig + 1);   // the others run at the next check
            throw;
        }
    }
}

// Sleep until `dl`; on the main thread with handlers installed, wake for a
// signal and return true (the caller lets dispatch run the handlers).
static bool sig_sleep_until(const Deadline& dl) {
    if (!sig_watch()) { std::this_thread::sleep_until(dl.tp); return false; }
    while (true) {
        if (g_sig_any.load(std::memory_order_acquire)) return true;
        TP now = Clock::now();
        if (now >= dl.tp) return false;
        double ms = std::chrono::duration<double, std::milli>(dl.tp - now).count();
        ms = std::min(ms + 1.0, 3600000.0);
#ifdef _WIN32
        if (g_sig_event) WaitForSingleObject(g_sig_event, (DWORD)ms);
        else std::this_thread::sleep_for(std::chrono::milliseconds((long long)std::min(ms, 50.0)));
#else
        struct pollfd p;
        p.fd = g_sig_pipe[0]; p.events = POLLIN; p.revents = 0;
        if (g_sig_pipe[0] >= 0) ::poll(&p, 1, (int)ms);
        else std::this_thread::sleep_for(std::chrono::milliseconds((long long)std::min(ms, 50.0)));
#endif
    }
}

// ── I/O waits ───────────────────────────────────────────────────────────────
// One call for "until this descriptor is ready" that is right in every
// context: a thread releases the GIL and polls; an async task parks on its
// loop's reactor, so other tasks run meanwhile - the socket API is the same
// in both ("colourless" I/O: a coroutine needs no separate async socket API).

#ifdef _WIN32
static short poll_events(int ev) { return (short)(((ev & IO_READ) ? POLLRDNORM : 0) | ((ev & IO_WRITE) ? POLLWRNORM : 0)); }
static int io_revents(short r) {
    int o = 0;
    if (r & (POLLRDNORM | POLLRDBAND | POLLIN | POLLHUP)) o |= IO_READ;
    if (r & (POLLWRNORM | POLLOUT)) o |= IO_WRITE;
    if (r & (POLLERR | POLLNVAL | POLLHUP)) o |= IO_ERR;
    return o;
}
#else
static short poll_events(int ev) { return (short)(((ev & IO_READ) ? POLLIN : 0) | ((ev & IO_WRITE) ? POLLOUT : 0)); }
static int io_revents(short r) {
    int o = 0;
    if (r & (POLLIN | POLLPRI | POLLHUP)) o |= IO_READ;
    if (r & POLLOUT) o |= IO_WRITE;
    if (r & (POLLERR | POLLNVAL | POLLHUP)) o |= IO_ERR;
    return o;
}
#endif
static int ms_until(const Deadline& dl) {
    if (!dl.finite) return -1;
    double ms = std::chrono::duration<double, std::milli>(dl.tp - Clock::now()).count();
    if (ms <= 0) return 0;
    return (int)std::min(ms + 0.999, 3600000.0);
}

static int wait_io_thread(std::vector<IoReq>& reqs, const Deadline& dl) {
    const bool watch = sig_watch();
    GilRelease rel;
    while (true) {
        if (watch && g_sig_any.load(std::memory_order_acquire)) throw signal_interrupt();
        int ms = ms_until(dl);
#ifdef _WIN32
        if (watch && (ms < 0 || ms > 50)) ms = 50;   // WSAPoll cannot wait on the signal event
        std::vector<WSAPOLLFD> p(reqs.size());
        for (size_t i = 0; i < reqs.size(); i++) { p[i].fd = (SOCKET)reqs[i].fd; p[i].events = poll_events(reqs[i].events); p[i].revents = 0; }
        int r = p.empty() ? (Sleep((DWORD)(ms < 0 ? 50 : ms)), 0) : WSAPoll(p.data(), (ULONG)p.size(), ms);
        if (r < 0) { for (auto& q : reqs) q.revents = IO_ERR; return (int)reqs.size(); }
        if (r == 0) { if (dl.finite && ms_until(dl) == 0) return 0; continue; }
        int n = 0;
        for (size_t i = 0; i < reqs.size(); i++) { reqs[i].revents = io_revents(p[i].revents); if (reqs[i].revents) n++; }
        return n;
#else
        std::vector<struct pollfd> p(reqs.size());
        for (size_t i = 0; i < reqs.size(); i++) { p[i].fd = (int)reqs[i].fd; p[i].events = poll_events(reqs[i].events); p[i].revents = 0; }
        if (watch && g_sig_pipe[0] >= 0) { struct pollfd q; q.fd = g_sig_pipe[0]; q.events = POLLIN; q.revents = 0; p.push_back(q); }
        int r = ::poll(p.data(), (nfds_t)p.size(), ms);
        if (r < 0) { if (errno == EINTR) continue; for (auto& q : reqs) q.revents = IO_ERR; return (int)reqs.size(); }
        if (r == 0) return 0;
        int n = 0;
        for (size_t i = 0; i < reqs.size(); i++) { reqs[i].revents = io_revents(p[i].revents); if (reqs[i].revents) n++; }
        if (n) return n;
        // only the signal pipe: the check at the top
#endif
    }
}

static int wait_io_task(ThreadRec* self, std::vector<IoReq>& reqs, const Deadline& dl) {
    Task* T = self->task;
    Loop* L = T->loop;
    std::vector<IoWait> ws(reqs.size());
    for (size_t i = 0; i < reqs.size(); i++) { ws[i].task = T; ws[i].fd = reqs[i].fd; ws[i].events = reqs[i].events; }
    GilRelease rel;
    std::unique_lock<std::mutex> lk(RT().m);
    check_cancel_locked(self);
    for (auto& w : ws) L->io.push_back(&w);
    // Blocking, so a cancellation wakes it (task_cancel_locked): it was woken
    // only by its descriptor, and a socket closed under it - Server.close()
    // cancelling its accept loop - is reported by Linux's poll (POLLNVAL)
    // but never by Windows', so asyncio.run waited forever there (round 77).
    // Not blocked_forever: the reactor wakes it, no deadlock to report.
    self->blocking = true;
    struct Unreg {
        Loop* L; std::vector<IoWait>& ws; ThreadRec* self;
        ~Unreg() {
            auto& v = L->io;
            v.erase(std::remove_if(v.begin(), v.end(), [this](IoWait* p) {
                return p >= ws.data() && p < ws.data() + ws.size(); }), v.end());
            self->blocking = false;
        }
    } unreg{L, ws, self};
    auto ready = [&] { for (auto& w : ws) if (w.revents) return true; return false; };
    while (!ready()) {
        if (dl.expired()) return 0;
        if (ws.empty() && !dl.finite) { check_cancel_locked(self); }
        task_park(lk, self, dl);
        if (self->cancel_requested) check_cancel_locked(self);
    }
    int n = 0;
    for (size_t i = 0; i < ws.size(); i++) { reqs[i].revents = ws[i].revents; if (ws[i].revents) n++; }
    return n;
}

int wait_io_many(std::vector<IoReq>& reqs, double timeout_ms) {
    for (auto& q : reqs) q.revents = 0;
    Deadline dl;
    if (timeout_ms >= 0) {
        dl.finite = true;
        dl.tp = Clock::now() + std::chrono::microseconds((long long)(timeout_ms * 1000.0));
    }
    ThreadRec* self = t_self;
    if (self && self->task) return wait_io_task(self, reqs, dl);
    while (true) {
        try { return wait_io_thread(reqs, dl); }
        catch (NyError& x) { if (x.type != "__signal__") throw; }
        run_signal_handlers();   // GIL held again; a handler that raises ends the wait
    }
}

bool in_async_task() { return t_self && t_self->task; }

int wait_io(intptr_t fd, int events, double timeout_ms) {
    std::vector<IoReq> one(1);
    one[0].fd = fd; one[0].events = events;
    return wait_io_many(one, timeout_ms) ? one[0].revents : 0;
}

void announce_input_request() {
    const char* on = std::getenv("NY_INPUT_REQUEST");
    if (!on || !*on || std::strcmp(on, "0") == 0) return;
    std::cout << INPUT_REQUEST_MARK << std::flush;
    std::fflush(stdout);
}

bool read_stdin_line(std::string& out) {
    announce_input_request();
    while (true) {
        bool ok;
        {
            GilRelease rel;
            ok = (bool)std::getline(std::cin, out);
        }
        if (ok) {
            if (!out.empty() && out.back() == '\r') out.pop_back();
            return true;
        }
        // A signal makes the read fail (EINTR, no SA_RESTART): run its
        // handler, then read again. Otherwise it is the end of input.
        std::cin.clear();
        std::clearerr(stdin);
        if (g_sig_any.load(std::memory_order_acquire) && is_main_thread()) { run_signal_handlers(); continue; }
        return false;
    }
}

// The loop's reactor: poll every waiting task's descriptor (and the wake
// pipe, and on the main thread the signal pipe) until the next timer.
// Runtime mutex held on entry and exit, released while polling.
static void loop_poll_io(std::unique_lock<std::mutex>& lk, Loop* L) {
    const bool watch = sig_watch();
    int ms = -1;
    if (!L->timers.empty()) {
        double d = std::chrono::duration<double, std::milli>(L->timers.begin()->first.first - Clock::now()).count();
        ms = d <= 0 ? 0 : (int)std::min(d + 0.999, 3600000.0);
    }
    std::vector<IoWait*> ws = L->io;
#ifdef _WIN32
    if (ms < 0 || ms > 10) ms = 10;   // no wake socket: other threads' wake-ups are seen within 10 ms
    std::vector<WSAPOLLFD> fds(ws.size());
    for (size_t i = 0; i < ws.size(); i++) { fds[i].fd = (SOCKET)ws[i]->fd; fds[i].events = poll_events(ws[i]->events); fds[i].revents = 0; }
    L->polling = true;
    lk.unlock();
    int r = WSAPoll(fds.data(), (ULONG)fds.size(), ms);
    lk.lock();
    L->polling = false;
    (void)watch;
    if (r < 0) {
        // One invalid socket (closed while a task waited on it) fails the
        // whole call, where poll() would flag just that one POLLNVAL: find
        // it and report it as an error to its task, instead of failing
        // every poll from now on (a busy loop) (round 77).
        for (size_t i = 0; i < ws.size(); i++) {
            WSAPOLLFD one = fds[i];
            one.revents = 0;
            if (WSAPoll(&one, 1, 0) >= 0 && !(one.revents & POLLNVAL)) continue;
            IoWait* w = ws[i];
            if (std::find(L->io.begin(), L->io.end(), w) == L->io.end()) continue;
            w->revents = IO_ERR;
            make_ready(w->task);
        }
        return;
    }
    if (r == 0) return;
    for (size_t i = 0; i < ws.size(); i++) {
        if (!fds[i].revents) continue;
        IoWait* w = ws[i];
        if (std::find(L->io.begin(), L->io.end(), w) == L->io.end()) continue;
        w->revents = io_revents(fds[i].revents);
        make_ready(w->task);
    }
#else
    if (L->wake_r < 0) {
        int p[2];
        if (::pipe(p) == 0) {
            for (int k = 0; k < 2; k++) {
                ::fcntl(p[k], F_SETFL, ::fcntl(p[k], F_GETFL) | O_NONBLOCK);
                ::fcntl(p[k], F_SETFD, FD_CLOEXEC);
            }
            L->wake_r = p[0]; L->wake_w = p[1];
        }
    }
    std::vector<struct pollfd> fds;
    fds.reserve(ws.size() + 2);
    for (auto* w : ws) { struct pollfd p; p.fd = (int)w->fd; p.events = poll_events(w->events); p.revents = 0; fds.push_back(p); }
    if (L->wake_r >= 0) { struct pollfd p; p.fd = L->wake_r; p.events = POLLIN; p.revents = 0; fds.push_back(p); }
    if (watch && g_sig_pipe[0] >= 0) { struct pollfd p; p.fd = g_sig_pipe[0]; p.events = POLLIN; p.revents = 0; fds.push_back(p); }
    L->polling = true;
    lk.unlock();
    int r = ::poll(fds.data(), (nfds_t)fds.size(), ms);
    lk.lock();
    L->polling = false;
    if (L->wake_r >= 0) { char buf[64]; while (::read(L->wake_r, buf, sizeof buf) > 0) {} }
    if (r <= 0) return;
    for (size_t i = 0; i < ws.size(); i++) {
        if (!fds[i].revents) continue;
        IoWait* w = ws[i];
        if (std::find(L->io.begin(), L->io.end(), w) == L->io.end()) continue;
        w->revents = io_revents(fds[i].revents);
        make_ready(w->task);
    }
#endif
}

// The event loop's thread (the main thread) runs the signal handlers between
// tasks. Runtime mutex held on entry and exit; a handler's exception leaves
// through run_loop_until (async_run then cancels the tasks).
static void loop_run_signals(std::unique_lock<std::mutex>& lk) {
    lk.unlock();
    gil_acquire();
    struct Back {
        std::unique_lock<std::mutex>& lk;
        ~Back() { gil_release(); lk.lock(); }
    } back{lk};
    run_signal_handlers();
}

// ── signal builtins ─────────────────────────────────────────────────────────
// lib/signal.ny is the Python-shaped module over these. A handler crosses as
// 0 (SIG_DFL), 1 (SIG_IGN), "default_int_handler" or the callable itself.
static Ret sig_handler_ret(const SigEntry& e) {
    switch (e.kind) {
        case 0: return Ret::integer(0);
        case 1: return Ret::integer(1);
        case 3: return Ret::str("default_int_handler");
        default: return Ret::boxed(e.fn);
    }
}
static int sig_arg(const Args& a, size_t i, const char* fn) {
    if (i >= a.size() || !a.is_number(i)) raise("TypeError", std::string(fn) + "() expects a signal number");
    int sig = (int)a.as_int(i);
    if (!sig_valid(sig)) raise("ValueError", "signal number out of range");
    return sig;
}

static void register_signal_builtins(std::unordered_map<std::string, Handler>& T) {
    T["_sig_signal"] = [](Engine& e, const Args& a) {
        int sig = sig_arg(a, 0, "signal");
        if (!is_main_thread()) raise("ValueError", "signal only works in main thread of the main interpreter");
#ifndef _WIN32
        if (sig == SIGKILL || sig == SIGSTOP) raise("OSError", "[Errno 22] Invalid argument");
#endif
        if (a.size() < 2) raise("TypeError", "signal() missing required argument 'handler'");
        SigEntry nw;
        if (a.is_number(1)) {
            int64_t k = a.as_int(1);
            if (k != 0 && k != 1) raise("TypeError", "signal handler must be signal.SIG_IGN, signal.SIG_DFL, or a callable object");
            nw.kind = (int)k;
        } else if (a.is_string(1) && a.as_str(1) == "default_int_handler") {
            nw.kind = 3;
        } else {
            BoxPtr fn = a.box(1);
            if (!e.is_callable(fn)) raise("TypeError", "signal handler must be signal.SIG_IGN, signal.SIG_DFL, or a callable object");
            nw.kind = 2; nw.eng = &e; nw.fn = fn;
        }
        sig_wake_open();
        std::lock_guard<std::mutex> l(sig_mu());
        auto& cur = sig_tab()[sig];
        Ret prev = sig_handler_ret(cur);
        nw.chans = cur.chans;
        cur = nw;
        sig_apply_locked(sig, cur);
        return prev;
    };
    T["_sig_getsignal"] = [](Engine&, const Args& a) {
        int sig = sig_arg(a, 0, "getsignal");
        std::lock_guard<std::mutex> l(sig_mu());
        auto it = sig_tab().find(sig);
        if (it == sig_tab().end()) return Ret::integer(0);
        return sig_handler_ret(it->second);
    };
    T["_sig_raise"] = [](Engine&, const Args& a) {
        int sig = sig_arg(a, 0, "raise_signal");
        if (std::raise(sig) != 0) raise("OSError", "raise_signal failed");
        run_signal_handlers();   // as Python: the handler runs before raise_signal returns
        return Ret::none();
    };
    T["_sig_notify"] = [](Engine& e, const Args& a) {
        int64_t ch = H(a, 0, "signal_notify");
        int sig = sig_arg(a, 1, "signal_notify");
        sig_wake_open();
        std::lock_guard<std::mutex> l(sig_mu());
        auto& ent = sig_tab()[sig];
        for (auto& c : ent.chans) if (c.first == ch) return Ret::none();
        ent.chans.push_back({ch, &e});
        // Delivered to the channel only: a subscribed SIGINT no longer raises
        // KeyboardInterrupt (Go's rule), until signal_stop.
        if (ent.kind == 3) ent.kind = 0;
        sig_apply_locked(sig, ent);
        return Ret::none();
    };
    T["_sig_stop"] = [](Engine&, const Args& a) {
        int64_t ch = H(a, 0, "signal_stop");
        std::lock_guard<std::mutex> l(sig_mu());
        for (auto& kv : sig_tab()) {
            auto& v = kv.second.chans;
            size_t before = v.size();
            v.erase(std::remove_if(v.begin(), v.end(), [ch](const std::pair<int64_t, Engine*>& c) { return c.first == ch; }), v.end());
            if (v.size() != before) {
                if (kv.first == SIGINT && kv.second.kind == 0 && !kv.second.fn && v.empty()) kv.second.kind = 3;
                sig_apply_locked(kv.first, kv.second);
            }
        }
        return Ret::none();
    };
    T["_sig_pause"] = [](Engine&, const Args&) {
        // Until a signal arrives and its handler has run (POSIX pause()).
        if (!is_main_thread()) raise("ValueError", "pause() only works in the main thread");
        Deadline never; never.finite = true; never.tp = Clock::now() + std::chrono::hours(24 * 365);
        sig_wake_open();
        {
            bool armed = g_sig_armed.load();
            g_sig_armed.store(true);
            struct Back { bool a; ~Back() { g_sig_armed.store(a); } } back{armed};
            GilRelease rel;
            while (!sig_sleep_until(never)) {}
        }
        run_signal_handlers();
        return Ret::none();
    };
    T["_sig_alarm"] = [](Engine&, const Args& a) {
#ifdef _WIN32
        (void)a;
        raise("OSError", "signal.alarm is not available on Windows");
        return Ret::none();
#else
        int64_t sec = a.size() > 0 && a.is_number(0) ? a.as_int(0) : 0;
        if (sec < 0) raise("ValueError", "alarm() argument must be non-negative");
        return Ret::integer((int64_t)::alarm((unsigned)sec));
#endif
    };
    T["_sig_setitimer"] = [](Engine&, const Args& a) {
#ifdef _WIN32
        (void)a;
        raise("OSError", "signal.setitimer is not available on Windows");
        return Ret::none();
#else
        int which = a.size() > 0 && a.is_number(0) ? (int)a.as_int(0) : ITIMER_REAL;
        double secs = opt_num(a, 1, 0), interval = opt_num(a, 2, 0);
        struct itimerval nv, ov;
        auto put = [](struct timeval& tv, double x) { tv.tv_sec = (time_t)x; tv.tv_usec = (suseconds_t)((x - (double)tv.tv_sec) * 1e6); };
        put(nv.it_value, secs); put(nv.it_interval, interval);
        if (::setitimer(which, &nv, &ov) != 0) raise("OSError", "setitimer: invalid timer");
        auto get = [](const struct timeval& tv) { return (double)tv.tv_sec + (double)tv.tv_usec / 1e6; };
        return Ret::lst({Ret::number(get(ov.it_value)), Ret::number(get(ov.it_interval))});
#endif
    };
    T["_sig_getitimer"] = [](Engine&, const Args& a) {
#ifdef _WIN32
        (void)a;
        raise("OSError", "signal.getitimer is not available on Windows");
        return Ret::none();
#else
        int which = a.size() > 0 && a.is_number(0) ? (int)a.as_int(0) : ITIMER_REAL;
        struct itimerval ov;
        if (::getitimer(which, &ov) != 0) raise("OSError", "getitimer: invalid timer");
        auto get = [](const struct timeval& tv) { return (double)tv.tv_sec + (double)tv.tv_usec / 1e6; };
        return Ret::lst({Ret::number(get(ov.it_value)), Ret::number(get(ov.it_interval))});
#endif
    };
    T["_sig_constants"] = [](Engine&, const Args&) {
        std::vector<Ret> out;
        auto add = [&](const char* n, int v) { out.push_back(Ret::lst({Ret::str(n), Ret::integer(v)})); };
        add("SIGINT", SIGINT); add("SIGTERM", SIGTERM); add("SIGABRT", SIGABRT);
        add("SIGFPE", SIGFPE); add("SIGILL", SIGILL); add("SIGSEGV", SIGSEGV);
#ifdef _WIN32
        add("SIGBREAK", SIGBREAK);
        add("CTRL_C_EVENT", 0); add("CTRL_BREAK_EVENT", 1);
#else
        add("SIGHUP", SIGHUP); add("SIGQUIT", SIGQUIT); add("SIGTRAP", SIGTRAP); add("SIGKILL", SIGKILL);
        add("SIGBUS", SIGBUS); add("SIGUSR1", SIGUSR1); add("SIGUSR2", SIGUSR2); add("SIGPIPE", SIGPIPE);
        add("SIGALRM", SIGALRM); add("SIGCHLD", SIGCHLD); add("SIGCONT", SIGCONT); add("SIGSTOP", SIGSTOP);
        add("SIGTSTP", SIGTSTP); add("SIGTTIN", SIGTTIN); add("SIGTTOU", SIGTTOU); add("SIGURG", SIGURG);
        add("SIGXCPU", SIGXCPU); add("SIGXFSZ", SIGXFSZ); add("SIGVTALRM", SIGVTALRM); add("SIGPROF", SIGPROF);
        add("SIGWINCH", SIGWINCH); add("SIGIO", SIGIO); add("SIGSYS", SIGSYS);
#  ifdef SIGPWR
        add("SIGPWR", SIGPWR);
#  endif
        add("ITIMER_REAL", ITIMER_REAL); add("ITIMER_VIRTUAL", ITIMER_VIRTUAL); add("ITIMER_PROF", ITIMER_PROF);
#endif
        return Ret::lst(std::move(out));
    };
    T["_sig_valid"] = [](Engine&, const Args&) {
        std::vector<Ret> out;
        for (int s = 1; s < kMaxSig; s++) if (sig_valid(s)) out.push_back(Ret::integer(s));
        return Ret::lst(std::move(out));
    };
    T["_sig_strsignal"] = [](Engine&, const Args& a) {
        int sig = a.size() > 0 && a.is_number(0) ? (int)a.as_int(0) : 0;
        if (!sig_valid(sig)) raise("ValueError", "signal number out of range");
#ifdef _WIN32
        switch (sig) {
            case SIGINT: return Ret::str("Interrupt"); case SIGTERM: return Ret::str("Terminated");
            case SIGABRT: return Ret::str("Aborted"); case SIGFPE: return Ret::str("Floating-point exception");
            case SIGILL: return Ret::str("Illegal instruction"); case SIGSEGV: return Ret::str("Segmentation fault");
            case SIGBREAK: return Ret::str("Break");
        }
        return Ret::none();
#else
        const char* d = ::strsignal(sig);
        return d ? Ret::str(d) : Ret::none();
#endif
    };
}

// ════════════════════════════════════════════════════════════════════════════
// Exit
// ════════════════════════════════════════════════════════════════════════════

void join_nondaemon_at_exit() {
    if (!g_active.load(std::memory_order_acquire) || !t_self) return;
    ThreadRec* self = t_self;
    Engine* e = self->engine;
    if (!e) return;
    // Pools: let queued work finish (their workers are daemons).
    std::vector<int64_t> pools;
    {
        std::lock_guard<std::mutex> l(RT().m);
        pools = RT().pools;
    }
    for (auto pid : pools) {
        std::vector<int64_t> workers;
        {
            std::lock_guard<std::mutex> l(RT().m);
            Pool* p = get_obj<Pool>(pid, "pool");
            if (p->shutdown) continue;
            p->shutdown = true;
            wake_all(p->wq);
            workers = p->workers;
        }
        for (auto t : workers) { try { join_thread(*e, t, -1); } catch (NyError&) {} }
    }
    while (true) {
        std::vector<int64_t> pending;
        {
            std::lock_guard<std::mutex> l(RT().m);
            for (auto* t : RT().live)
                if (t != self && !t->done && !t->daemon && !t->task) pending.push_back(t->id);
        }
        if (pending.empty()) break;
        for (auto id : pending) {
            // Wait for completion without re-raising: a failure nobody joined is
            // reported below instead.
            ThreadRec* t;
            {
                std::lock_guard<std::mutex> l(RT().m);
                t = RT().threads[id].get();
            }
            try {
                block_released(self, {&t->joiners}, [t] { return t->done; }, Deadline::never(), t, false);
            } catch (NyError& x) {
                if (x.type == "__signal__") return;   // Ctrl+C while waiting at exit: stop waiting
                std::lock_guard<std::mutex> l(RT().m);
                if (!t->done) {
                    // Blocked for good (a deadlock found while waiting): stop waiting.
                    std::cerr << "[Nython] at exit: " << error_text(x) << std::endl;
                    t->daemon = true;
                }
            }
        }
    }
    // Uncaught exceptions of threads nobody joined must not vanish.
    std::vector<ThreadRec*> unreported;
    {
        std::lock_guard<std::mutex> l(RT().m);
        for (auto& kv : RT().threads) {
            auto* t = kv.second.get();
            if (t->done && t->failed && !t->joined && !t->reported && !t->task) unreported.push_back(t);
        }
    }
    std::sort(unreported.begin(), unreported.end(), [](ThreadRec* a, ThreadRec* b) { return a->id < b->id; });
    for (auto* t : unreported) report_thread_error(t);
}

} // namespace nyconc
