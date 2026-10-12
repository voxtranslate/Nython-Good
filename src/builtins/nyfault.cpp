// builtins/nyfault.cpp - the native side of faulthandler and tracemalloc
// (round 83), for lib/faulthandler.ny and lib/tracemalloc.ny.
//
// faulthandler: Python-level stacks written with nothing but write(2) and
// reads of the engines' frame records, so a signal handler can do it - the
// fatal handlers for SIGSEGV, SIGFPE, SIGABRT, SIGBUS and SIGILL (on an
// alternate signal stack, so a stack overflow is reported too; the previous
// handler is put back and the signal raised again, as CPython does), user
// signals (register/unregister, chained or not), a watchdog thread
// (dump_traceback_later) and dump_traceback() itself. A thread's frames
// come from its engine (nyconc::Engine::walk_frames: the interpreter's
// PyFrame records, src/builtins/threading.cpp; the VM's CallFrames,
// src/VMConc.cpp) - the live ones for the thread holding the GIL, the
// parked state of every other thread (nyconc::thread_snapshot). Output is
// CPython's, line for line ("Fatal Python error: Segmentation fault",
// "Current thread 0x... (most recent call first):", "  File \"f.py\", line
// 3 in g"); a thread's number is its threading.get_ident().
//
// tracemalloc: every memory block the process allocates through C++'s
// operator new while tracing is on - the engines' strings, lists, dicts,
// instances, frames - is recorded with its size and the Python stack that
// asked for it (up to start(nframe) frames, innermost first), and forgotten
// when it is freed. operator new/delete are replaced here; while tracing is
// off they cost one test of a byte (g_on) on top of malloc/free, as
// nytrace::t_hooks costs the engines one test per statement. The records use
// operator new themselves, so a thread-local guard keeps the hook from
// recording (or recursing into) its own bookkeeping.
//
//   _fault_enable(fd, all_threads, ident)     _fault_disable() -> bool
//   _fault_is_enabled() -> bool               _fault_dump(fd, all_threads, ident)
//   _fault_later(timeout, repeat, fd, exit, ident)   _fault_cancel_later()
//   _fault_register(signum, fd, all_threads, chain, ident) -> None
//   _fault_unregister(signum) -> bool         _fault_crash(kind)   (tests: "segv" "abrt" "fpe" "bus" "ill")
//   _tm_start(nframe)  _tm_stop()  _tm_is_tracing()  _tm_get_traceback_limit()
//   _tm_get_traced_memory() -> [current, peak]   _tm_reset_peak()   _tm_clear_traces()
//   _tm_get_traces() -> [[domain, size, ((file, line), ...), total_nframe], ...]
//   _tm_object_traceback(address) -> ((file, line), ...) or none   _tm_memory()
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyConc.hpp"
#include "builtins/os.hpp"
#include "builtins/sysmods.hpp"
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <thread>
#include <unordered_map>
#ifdef _WIN32
#  include <windows.h>
#  include <io.h>
#else
#  include <unistd.h>
#  include <signal.h>
#endif

void ny_interp_walk(const NythonExecutor::PyFrames* F, nython::node::Node* cur,
                    nyconc::Engine::FrameEmit emit, void* sink);

// ════════════════════════════════════════════════════════════════════════════
// tracemalloc's records (before operator new, which uses them)
// ════════════════════════════════════════════════════════════════════════════
namespace nytm {
std::atomic<bool> g_on{false};
thread_local bool t_in = false;          // inside the hook or the module's own code
void on_alloc(void* p, size_t n);
void on_free(void* p);
}

// ── operator new / delete (round 83): the allocation hook ──────────────────
void* operator new(std::size_t n) {
    void* p = std::malloc(n ? n : 1);
    while (!p) {
        std::new_handler h = std::get_new_handler();
        if (!h) throw std::bad_alloc();
        h();
        p = std::malloc(n ? n : 1);
    }
    if (__builtin_expect(nytm::g_on.load(std::memory_order_relaxed), 0)) nytm::on_alloc(p, n);
    return p;
}
void* operator new[](std::size_t n) { return ::operator new(n); }
void* operator new(std::size_t n, const std::nothrow_t&) noexcept {
    try { return ::operator new(n); } catch (...) { return nullptr; }
}
void* operator new[](std::size_t n, const std::nothrow_t&) noexcept {
    try { return ::operator new(n); } catch (...) { return nullptr; }
}
void operator delete(void* p) noexcept {
    if (__builtin_expect(nytm::g_on.load(std::memory_order_relaxed), 0) && p) nytm::on_free(p);
    std::free(p);
}
void operator delete[](void* p) noexcept { ::operator delete(p); }
void operator delete(void* p, std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void* p, std::size_t) noexcept { ::operator delete(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { ::operator delete(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { ::operator delete(p); }

namespace {

// ── which engine runs the program ───────────────────────────────────────────
std::atomic<nyconc::Engine*> g_vm_engine{nullptr};
std::atomic<const void*> g_vm_runnable{nullptr};
std::atomic<bool> g_vm_mode{false};
// the interpreter thread that last called in: its frames are the live ones
// while there is no second thread (no GIL)
std::atomic<const NythonExecutor::PyFrames*> g_frames{nullptr};
std::atomic<nython::node::Node* const*> g_cur{nullptr};
std::atomic<int64_t> g_ident{0};
thread_local bool t_python = false;      // this thread has run Python code (its frames are initialized)

void note_caller(NythonExecutor& E, int64_t ident) {
    const void* vmr = g_vm_runnable.load();
    bool vm = vmr && (const void*)E.runner == vmr;
    g_vm_mode.store(vm);
    if (!vm) {
        g_frames.store(&NythonExecutor::py_frames());
        g_cur.store(&NythonExecutor::cur_stmt());
    }
    if (ident) g_ident.store(ident);
    t_python = true;
}

// ── async-signal-safe output ────────────────────────────────────────────────
void wr(int fd, const char* s, size_t n) {
    while (n) {
#ifdef _WIN32
        int k = ::_write(fd, s, (unsigned)n);
#else
        ssize_t k = ::write(fd, s, n);
#endif
        if (k <= 0) {
            if (k < 0 && errno == EINTR) continue;
            return;
        }
        s += k;
        n -= (size_t)k;
    }
}
void ws(int fd, const char* s) { wr(fd, s, std::strlen(s)); }
void wdec(int fd, unsigned long long v) {
    char b[32];
    int i = 32;
    do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    wr(fd, b + i, (size_t)(32 - i));
}
void whex(int fd, unsigned long long v, int width) {
    char b[32];
    int i = 32;
    do { b[--i] = "0123456789abcdef"[v & 15]; v >>= 4; width--; } while (v || width > 0);
    wr(fd, b + i, (size_t)(32 - i));
}
// CPython's _Py_DumpASCII: printable ASCII as is, the rest escaped
void wascii(int fd, const char* s) {
    const unsigned char* p = (const unsigned char*)s;
    while (*p) {
        unsigned char c = *p;
        uint32_t cp;
        int n;
        if (c < 0x80) { cp = c; n = 1; }
        else if ((c >> 5) == 6) { cp = c & 0x1F; n = 2; }
        else if ((c >> 4) == 14) { cp = c & 0x0F; n = 3; }
        else { cp = c & 0x07; n = 4; }
        for (int k = 1; k < n; k++) {
            if (!p[k]) { n = k; break; }
            cp = (cp << 6) | (p[k] & 0x3F);
        }
        p += n;
        if (cp >= ' ' && cp <= 126) { char ch = (char)cp; wr(fd, &ch, 1); }
        else if (cp <= 0xff) { ws(fd, "\\x"); whex(fd, cp, 2); }
        else if (cp <= 0xffff) { ws(fd, "\\u"); whex(fd, cp, 4); }
        else { ws(fd, "\\U"); whex(fd, cp, 8); }
    }
}

bool ends_with(const char* s, const char* tail) {
    size_t a = std::strlen(s), b = std::strlen(tail);
    return a >= b && std::memcmp(s + a - b, tail, b) == 0;
}
// faulthandler's own Nython code is not shown (CPython's is C)
bool own_file(const char* f) { return ends_with(f, "faulthandler.ny"); }

struct DumpSink { int fd; int depth; bool started; };
void dump_emit(void* s, const char* file, long line, const char* name) {
    auto* d = static_cast<DumpSink*>(s);
    if (!d->started && own_file(file)) return;
    d->started = true;
    if (d->depth == 100) { ws(d->fd, "  ...\n"); d->depth++; return; }
    if (d->depth > 100) return;
    ws(d->fd, "  File \"");
    wascii(d->fd, file);
    ws(d->fd, "\", line ");
    wdec(d->fd, (unsigned long long)(line < 0 ? 0 : line));
    ws(d->fd, " in ");
    wascii(d->fd, name);
    ws(d->fd, "\n");
    d->depth++;
}

// the frames running now (the GIL holder's, or the only thread's)
void walk_live(nyconc::Engine::FrameEmit emit, void* sink, bool self) {
    if (g_vm_mode.load()) {
        if (nyconc::Engine* e = g_vm_engine.load()) e->walk_frames(nullptr, emit, sink);
        return;
    }
    if (self && t_python) {
        ny_interp_walk(&NythonExecutor::py_frames(), NythonExecutor::cur_stmt(), emit, sink);
        return;
    }
    const NythonExecutor::PyFrames* F = g_frames.load();
    nython::node::Node* const* cur = g_cur.load();
    if (F) ny_interp_walk(F, cur ? *cur : nullptr, emit, sink);
}
void dump_frames(int fd, nyconc::Engine* eng, const void* estate, bool live, bool self) {
    DumpSink d{fd, 0, false};
    if (live) walk_live(dump_emit, &d, self);
    else if (g_vm_mode.load() && g_vm_engine.load()) g_vm_engine.load()->walk_frames(estate, dump_emit, &d);
    else if (eng) eng->walk_frames(estate, dump_emit, &d);
    if (d.depth == 0) ws(fd, "  <no Python frame>\n");
}
void thread_header(int fd, int64_t id, bool current) {
    ws(fd, current ? "Current thread 0x" : "Thread 0x");
    whex(fd, (unsigned long long)id, (int)sizeof(unsigned long) * 2);
    ws(fd, " (most recent call first):\n");
}
// current: whether the calling thread is a Python thread (false: the watchdog)
void dump_traceback(int fd, bool all_threads, bool current) {
    nyconc::ThreadSnap snaps[64];
    size_t n = nyconc::thread_snapshot(snaps, 64);
    bool gil = nyconc::active();
    if (!all_threads) {
        ws(fd, "Stack (most recent call first):\n");
        for (size_t i = 0; i < n; i++)
            if (snaps[i].current && gil && !snaps[i].gil_owner) { dump_frames(fd, snaps[i].engine, snaps[i].estate, false, true); return; }
        dump_frames(fd, nullptr, nullptr, true, current);
        return;
    }
    if (n == 0 || !gil) {
        int64_t id = g_ident.load();
        for (size_t i = 0; i < n; i++) if (snaps[i].current || n == 1) id = snaps[i].id;
        thread_header(fd, id, current);
        dump_frames(fd, nullptr, nullptr, true, current);
        return;
    }
    // newest first, as CPython lists its thread states
    for (size_t i = 1; i < n; i++)
        for (size_t j = i; j > 0 && snaps[j - 1].id < snaps[j].id; j--) std::swap(snaps[j - 1], snaps[j]);
    for (size_t i = 0; i < n; i++) {
        if (i) ws(fd, "\n");
        thread_header(fd, snaps[i].id, current && snaps[i].current);
        dump_frames(fd, snaps[i].engine, snaps[i].estate, snaps[i].gil_owner, current && snaps[i].current);
    }
}

// ── the fatal signals ───────────────────────────────────────────────────────
struct Fatal {
    int signum;
    const char* name;
    bool enabled;
#ifndef _WIN32
    struct sigaction previous;
#else
    void (*previous)(int);
#endif
};
Fatal g_fatal[] = {
#ifdef SIGBUS
    {SIGBUS, "Bus error", false, {}},
#endif
#ifdef SIGILL
    {SIGILL, "Illegal instruction", false, {}},
#endif
    {SIGFPE, "Floating point exception", false, {}},
    {SIGABRT, "Aborted", false, {}},
    {SIGSEGV, "Segmentation fault", false, {}},
};
const size_t kFatal = sizeof g_fatal / sizeof g_fatal[0];
std::atomic<bool> g_enabled{false};
int g_fatal_fd = 2;
bool g_fatal_all = true;
volatile sig_atomic_t g_reentrant = 0;

void disable_fatal(Fatal& f) {
    if (!f.enabled) return;
    f.enabled = false;
#ifndef _WIN32
    sigaction(f.signum, &f.previous, nullptr);
#else
    std::signal(f.signum, f.previous);
#endif
}

void fatal_handler(int signum) {
    int save = errno;
    if (!g_enabled.load()) return;
    Fatal* h = nullptr;
    for (size_t i = 0; i < kFatal; i++) if (g_fatal[i].signum == signum) h = &g_fatal[i];
    if (!h) return;
    disable_fatal(*h);
    int fd = g_fatal_fd;
    ws(fd, "Fatal Python error: ");
    ws(fd, h->name);
    ws(fd, "\n\n");
    if (!g_reentrant) {
        g_reentrant = 1;
        dump_traceback(fd, g_fatal_all, true);
        g_reentrant = 0;
    }
    errno = save;
#ifdef _WIN32
    if (signum == SIGSEGV) return;
#endif
    std::raise(signum);
}

#ifndef _WIN32
std::atomic<bool> g_altstack{false};
void ensure_altstack() {
    bool expect = false;
    if (!g_altstack.compare_exchange_strong(expect, true)) return;
    stack_t ss;
    size_t size = (size_t)SIGSTKSZ * 2;
    if (size < 65536) size = 65536;
    ss.ss_sp = std::malloc(size);
    ss.ss_size = size;
    ss.ss_flags = 0;
    if (ss.ss_sp) sigaltstack(&ss, nullptr);
}
#endif

bool enable_fatal() {
    for (size_t i = 0; i < kFatal; i++) {
        Fatal& f = g_fatal[i];
        if (f.enabled) continue;
#ifndef _WIN32
        struct sigaction act;
        std::memset(&act, 0, sizeof act);
        act.sa_handler = fatal_handler;
        sigemptyset(&act.sa_mask);
        act.sa_flags = SA_NODEFER | SA_ONSTACK;
        if (sigaction(f.signum, &act, &f.previous) != 0) return false;
#else
        f.previous = std::signal(f.signum, fatal_handler);
        if (f.previous == SIG_ERR) return false;
#endif
        f.enabled = true;
    }
    return true;
}

// ── user signals (register) ─────────────────────────────────────────────────
#ifndef _WIN32
struct User {
    bool enabled = false;
    int fd = 2;
    bool all_threads = true, chain = false;
    struct sigaction previous;
};
User g_user[NSIG];
void user_handler(int signum) {
    if (signum <= 0 || signum >= NSIG) return;
    User& u = g_user[signum];
    if (!u.enabled) return;
    int save = errno;
    dump_traceback(u.fd, u.all_threads, true);
    if (u.chain) {
        errno = save;
        // call the previous handler: put it back, raise, take ours again
        struct sigaction mine;
        sigaction(signum, &u.previous, &mine);
        std::raise(signum);
        sigaction(signum, &mine, nullptr);
    }
    errno = save;
}
#endif

// ── dump_traceback_later's watchdog ─────────────────────────────────────────
struct Later {
    std::mutex m;
    std::condition_variable cv;
    std::thread th;
    bool running = false, cancel = false;
};
Later& later() { static Later* l = new Later(); return *l; }
void cancel_later() {
    Later& L = later();
    std::thread th;
    {
        std::lock_guard<std::mutex> g(L.m);
        if (!L.running) return;
        L.cancel = true;
        th = std::move(L.th);
    }
    L.cv.notify_all();
    if (th.joinable()) th.join();
    std::lock_guard<std::mutex> g(L.m);
    L.running = false;
    L.cancel = false;
}
std::string timeout_header(double t) {
    // CPython's format_timeout: "Timeout (0:00:05)!\n", microseconds when any
    unsigned long long us = (unsigned long long)(t * 1e6 + 0.5);
    unsigned long long sec = us / 1000000, frac = us % 1000000;
    unsigned long long h = sec / 3600, m = (sec / 60) % 60, s = sec % 60;
    char buf[96];
    if (frac) std::snprintf(buf, sizeof buf, "Timeout (%llu:%02llu:%02llu.%06llu)!\n", h, m, s, frac);
    else std::snprintf(buf, sizeof buf, "Timeout (%llu:%02llu:%02llu)!\n", h, m, s);
    return buf;
}

// ════════════════════════════════════════════════════════════════════════════
// tracemalloc
// ════════════════════════════════════════════════════════════════════════════
struct TFrame { uint32_t file; int32_t line; };
struct TBKey {
    std::vector<TFrame> frames;
    uint32_t total;
    bool operator==(const TBKey& o) const {
        if (total != o.total || frames.size() != o.frames.size()) return false;
        for (size_t i = 0; i < frames.size(); i++)
            if (frames[i].file != o.frames[i].file || frames[i].line != o.frames[i].line) return false;
        return true;
    }
};
struct TBHash {
    size_t operator()(const TBKey& k) const {
        uint64_t h = 1469598103934665603ULL ^ k.total;
        for (auto& f : k.frames) { h = (h ^ f.file) * 1099511628211ULL; h = (h ^ (uint32_t)f.line) * 1099511628211ULL; }
        return (size_t)h;
    }
};
struct Trace { size_t size; uint32_t tb; };
struct TM {
    std::mutex m;
    int nframe = 1;
    std::vector<std::string> files;
    std::unordered_map<std::string, uint32_t> file_ids;
    std::vector<TBKey> tbs;
    std::unordered_map<TBKey, uint32_t, TBHash> tb_ids;
    std::unordered_map<void*, Trace> traces;
    size_t cur = 0, peak = 0;
};
TM* g_tm = nullptr;

struct Capture {
    TM* tm = nullptr;
    TFrame frames[64] = {};
    int n = 0;
    uint32_t total = 0;
};
uint32_t intern_file(TM* tm, const char* f) {
    auto it = tm->file_ids.find(f);
    if (it != tm->file_ids.end()) return it->second;
    uint32_t id = (uint32_t)tm->files.size();
    tm->files.push_back(f);
    tm->file_ids.emplace(f, id);
    return id;
}
void capture_emit(void* s, const char* file, long line, const char* name) {
    (void)name;
    auto* c = static_cast<Capture*>(s);
    c->total++;
    if (c->n < c->tm->nframe && c->n < 64) c->frames[c->n++] = TFrame{intern_file(c->tm, file), (int32_t)line};
}

} // namespace

void nyfault_set_vm_engine(nyconc::Engine* eng, const void* vm_runnable) {
    g_vm_engine.store(eng);
    g_vm_runnable.store(vm_runnable);
}

namespace nytm {
// The calling thread's Python stack (the hook runs inside the allocating
// thread): the engine's live frames when this thread holds the GIL.
static void capture(Capture& c) {
    if (!nyconc::holds_gil() || (!t_python && !nyconc::active())) return;
    if (g_vm_mode.load()) {
        if (nyconc::Engine* e = g_vm_engine.load()) e->walk_frames(nullptr, capture_emit, &c);
        return;
    }
    if (t_python) ny_interp_walk(&NythonExecutor::py_frames(), NythonExecutor::cur_stmt(), capture_emit, &c);
}
static uint32_t intern_tb(TM* tm, Capture& c) {
    TBKey k;
    if (c.n == 0) {
        k.frames.push_back(TFrame{intern_file(tm, "<unknown>"), 0});
        k.total = 1;
    } else {
        k.frames.assign(c.frames, c.frames + c.n);
        k.total = c.total;
    }
    auto it = tm->tb_ids.find(k);
    if (it != tm->tb_ids.end()) return it->second;
    uint32_t id = (uint32_t)tm->tbs.size();
    tm->tbs.push_back(k);
    tm->tb_ids.emplace(std::move(k), id);
    return id;
}
void on_alloc(void* p, size_t n) {
    if (t_in) return;
    TM* tm = g_tm;
    if (!tm) return;
    t_in = true;
    {
        std::lock_guard<std::mutex> l(tm->m);
        if (g_on.load(std::memory_order_relaxed)) {
            Capture c;
            c.tm = tm;
            capture(c);
            uint32_t tb = intern_tb(tm, c);
            auto ins = tm->traces.emplace(p, Trace{n, tb});
            if (!ins.second) { tm->cur -= ins.first->second.size; ins.first->second = Trace{n, tb}; }
            tm->cur += n;
            if (tm->cur > tm->peak) tm->peak = tm->cur;
        }
    }
    t_in = false;
}
void on_free(void* p) {
    if (t_in) return;
    TM* tm = g_tm;
    if (!tm) return;
    t_in = true;
    {
        std::lock_guard<std::mutex> l(tm->m);
        auto it = tm->traces.find(p);
        if (it != tm->traces.end()) {
            tm->cur -= it->second.size;
            tm->traces.erase(it);
        }
    }
    t_in = false;
}
} // namespace nytm

namespace {

int64_t iarg(std::vector<Value>& a, size_t i, int64_t d = 0) {
    if (i >= a.size() || a[i].type == ValueType::NONE) return d;
    return (int64_t)nyos::to_int(a[i], d);
}
bool barg(std::vector<Value>& a, size_t i, bool d) {
    if (i >= a.size() || a[i].type == ValueType::NONE) return d;
    if (a[i].type == ValueType::BOOLEAN) return a[i].value.b;
    return nyos::to_int(a[i], d ? 1 : 0) != 0;
}

// A traceback's frames, copied while the records are locked (the records
// grow under other threads - and under this one: making the values below
// allocates, and so records).
using TBCopy = std::vector<std::pair<std::string, int32_t>>;
TBCopy copy_tb(TM* tm, uint32_t tb) {
    TBCopy out;
    for (auto& f : tm->tbs[tb].frames) out.push_back({tm->files[f.file], f.line});
    return out;
}
Value frames_value(NythonExecutor& E, const TBCopy& tb) {
    std::vector<Value> fr;
    for (auto& f : tb) {
        std::vector<Value> pair{E.makeStringValue(f.first), Value((int64_t)f.second)};
        fr.push_back(E.makeListValue(pair, true));
    }
    return E.makeListValue(fr, true);
}

} // namespace

std::vector<std::string> fault_builtin_names() {
    return {"_fault_enable", "_fault_disable", "_fault_is_enabled", "_fault_dump", "_fault_later",
            "_fault_cancel_later", "_fault_register", "_fault_unregister", "_fault_crash",
            "_tm_start", "_tm_stop", "_tm_is_tracing", "_tm_get_traceback_limit", "_tm_get_traced_memory",
            "_tm_reset_peak", "_tm_clear_traces", "_tm_get_traces", "_tm_object_traceback", "_tm_memory"};
}

Value dispatch_fault(NythonExecutor& E, const std::string& name, std::vector<Value>& a, Context* ctx) {
    (void)ctx;
    // ── faulthandler ────────────────────────────────────────────────────────
    if (name == "_fault_enable") {
        note_caller(E, iarg(a, 2));
        g_fatal_fd = (int)iarg(a, 0, 2);
        g_fatal_all = barg(a, 1, true);
#ifndef _WIN32
        ensure_altstack();
#endif
        if (!enable_fatal()) nyos::raise_errno(errno, "");
        g_enabled.store(true);
        return NONE_VALUE;
    }
    if (name == "_fault_disable") {
        bool was = g_enabled.exchange(false);
        for (size_t i = 0; i < kFatal; i++) disable_fatal(g_fatal[i]);
        return Value(was);
    }
    if (name == "_fault_is_enabled") return Value(g_enabled.load());
    if (name == "_fault_dump") {
        note_caller(E, iarg(a, 2));
        std::fflush(stdout);
        std::fflush(stderr);
        dump_traceback((int)iarg(a, 0, 2), barg(a, 1, true), true);
        return NONE_VALUE;
    }
    if (name == "_fault_later") {
        double timeout = nyos::to_num(a[0], 0.0);
        bool repeat = barg(a, 1, false), exit_ = barg(a, 3, false);
        int fd = (int)iarg(a, 2, 2);
        note_caller(E, iarg(a, 4));
        cancel_later();
        Later& L = later();
        std::string header = timeout_header(timeout);
        std::lock_guard<std::mutex> g(L.m);
        L.running = true;
        L.cancel = false;
        L.th = std::thread([timeout, repeat, exit_, fd, header] {
            Later& LL = later();
            std::unique_lock<std::mutex> lk(LL.m);
            while (true) {
                bool cancelled = LL.cv.wait_for(lk, std::chrono::duration<double>(timeout), [&] { return LL.cancel; });
                if (cancelled) return;
                wr(fd, header.data(), header.size());
                dump_traceback(fd, true, false);
                if (exit_) ::_exit(1);
                if (!repeat) return;
            }
        });
        return NONE_VALUE;
    }
    if (name == "_fault_cancel_later") { cancel_later(); return NONE_VALUE; }
    if (name == "_fault_crash") {
        std::string k = E.strOf(a[0]);
        std::fflush(stdout);
        std::fflush(stderr);
        if (k == "segv") std::raise(SIGSEGV);
        else if (k == "abrt") std::abort();
        else if (k == "fpe") std::raise(SIGFPE);
#ifdef SIGBUS
        else if (k == "bus") std::raise(SIGBUS);
#endif
#ifdef SIGILL
        else if (k == "ill") std::raise(SIGILL);
#endif
        else if (k == "read_null") { volatile int* p = nullptr; return Value((int64_t)*p); }
        return NONE_VALUE;
    }
#ifndef _WIN32
    if (name == "_fault_register") {
        int sig = (int)iarg(a, 0);
        if (sig <= 0 || sig >= NSIG) nyos::raise("ValueError", "signal number out of range");
        for (size_t i = 0; i < kFatal; i++)
            if (g_fatal[i].signum == sig)
                nyos::raise("RuntimeError", "signal " + std::to_string(sig) + " cannot be registered, use enable() instead");
        note_caller(E, iarg(a, 4));
        User& u = g_user[sig];
        u.fd = (int)iarg(a, 1, 2);
        u.all_threads = barg(a, 2, true);
        u.chain = barg(a, 3, false);
        if (!u.enabled) {
            struct sigaction act;
            std::memset(&act, 0, sizeof act);
            act.sa_handler = user_handler;
            sigemptyset(&act.sa_mask);
            act.sa_flags = SA_RESTART | SA_ONSTACK | (u.chain ? SA_NODEFER : 0);
            if (sigaction(sig, &act, &u.previous) != 0) nyos::raise_errno(errno, "");
            u.enabled = true;
        }
        return NONE_VALUE;
    }
    if (name == "_fault_unregister") {
        int sig = (int)iarg(a, 0);
        if (sig <= 0 || sig >= NSIG) nyos::raise("ValueError", "signal number out of range");
        User& u = g_user[sig];
        if (!u.enabled) return Value(false);
        u.enabled = false;
        sigaction(sig, &u.previous, nullptr);
        return Value(true);
    }
#endif
    // ── tracemalloc ─────────────────────────────────────────────────────────
    if (name == "_tm_start") {
        int64_t nf = iarg(a, 0, 1);
        if (nf < 1 || nf > 65535) nyos::raise("ValueError", "the number of frames must be in range [1; 65535]");
        note_caller(E, 0);
        if (nytm::g_on.load()) return NONE_VALUE;
        nytm::t_in = true;
        if (!g_tm) g_tm = new TM();
        {
            std::lock_guard<std::mutex> l(g_tm->m);
            g_tm->nframe = (int)std::min<int64_t>(nf, 64);
            g_tm->traces.clear();
            g_tm->cur = g_tm->peak = 0;
        }
        nytm::t_in = false;
        nytm::g_on.store(true);
        return NONE_VALUE;
    }
    if (name == "_tm_stop") {
        nytm::g_on.store(false);
        if (g_tm) {
            nytm::t_in = true;
            {
                std::lock_guard<std::mutex> l(g_tm->m);
                std::unordered_map<void*, Trace>().swap(g_tm->traces);
                g_tm->cur = g_tm->peak = 0;
            }
            nytm::t_in = false;
        }
        return NONE_VALUE;
    }
    if (name == "_tm_is_tracing") return Value(nytm::g_on.load());
    if (name == "_tm_get_traceback_limit") return Value((int64_t)(g_tm ? g_tm->nframe : 1));
    if (name == "_tm_get_traced_memory") {
        size_t cur = 0, peak = 0;
        if (g_tm && nytm::g_on.load()) {
            nytm::t_in = true;
            { std::lock_guard<std::mutex> l(g_tm->m); cur = g_tm->cur; peak = g_tm->peak; }
            nytm::t_in = false;
        }
        std::vector<Value> v{Value((int64_t)cur), Value((int64_t)peak)};
        return E.makeListValue(v, true);
    }
    if (name == "_tm_reset_peak") {
        if (g_tm && nytm::g_on.load()) {
            nytm::t_in = true;
            { std::lock_guard<std::mutex> l(g_tm->m); g_tm->peak = g_tm->cur; }
            nytm::t_in = false;
        }
        return NONE_VALUE;
    }
    if (name == "_tm_clear_traces") {
        if (g_tm) {
            nytm::t_in = true;
            { std::lock_guard<std::mutex> l(g_tm->m); g_tm->traces.clear(); g_tm->cur = g_tm->peak = 0; }
            nytm::t_in = false;
        }
        return NONE_VALUE;
    }
    if (name == "_tm_get_traces") {
        // a copy of the records, taken without recording itself
        std::vector<std::pair<size_t, uint32_t>> recs;
        std::unordered_map<uint32_t, std::pair<TBCopy, uint32_t>> tbs;
        if (g_tm && nytm::g_on.load()) {
            nytm::t_in = true;
            {
                std::lock_guard<std::mutex> l(g_tm->m);
                recs.reserve(g_tm->traces.size());
                for (auto& kv : g_tm->traces) {
                    recs.push_back({kv.second.size, kv.second.tb});
                    if (!tbs.count(kv.second.tb)) tbs.emplace(kv.second.tb, std::make_pair(copy_tb(g_tm, kv.second.tb), g_tm->tbs[kv.second.tb].total));
                }
            }
            nytm::t_in = false;
        }
        std::vector<Value> out;
        out.reserve(recs.size());
        std::unordered_map<uint32_t, Value> tbv;
        for (auto& r : recs) {
            auto it = tbv.find(r.second);
            if (it == tbv.end()) it = tbv.emplace(r.second, frames_value(E, tbs[r.second].first)).first;
            std::vector<Value> t{Value((int64_t)0), Value((int64_t)r.first), it->second,
                                 Value((int64_t)tbs[r.second].second)};
            out.push_back(E.makeListValue(t, true));
        }
        return E.makeListValue(out);
    }
    if (name == "_tm_object_traceback") {
        if (!g_tm || !nytm::g_on.load()) return NONE_VALUE;
        uintptr_t addr = (uintptr_t)(uint64_t)iarg(a, 0);
        if (!addr) return NONE_VALUE;
        int64_t tb = -1;
        TBCopy copy;
        nytm::t_in = true;
        {
            std::lock_guard<std::mutex> l(g_tm->m);
            auto it = g_tm->traces.find((void*)addr);
            if (it != g_tm->traces.end()) tb = it->second.tb;
            else {
                // a block that holds the object (a shared_ptr's control block)
                uintptr_t best = 0;
                for (auto& kv : g_tm->traces) {
                    uintptr_t p = (uintptr_t)kv.first;
                    if (p <= addr && addr < p + kv.second.size && p > best) { best = p; tb = kv.second.tb; }
                }
            }
            if (tb >= 0) copy = copy_tb(g_tm, (uint32_t)tb);
        }
        nytm::t_in = false;
        if (tb < 0) return NONE_VALUE;
        return frames_value(E, copy);
    }
    if (name == "_tm_memory") {
        size_t n = 0;
        if (g_tm) {
            nytm::t_in = true;
            {
                std::lock_guard<std::mutex> l(g_tm->m);
                n = g_tm->traces.size() * (sizeof(void*) + sizeof(Trace) + 2 * sizeof(void*)) +
                    g_tm->tbs.size() * (sizeof(TBKey) + 16) + g_tm->files.size() * 64;
            }
            nytm::t_in = false;
        }
        return Value((int64_t)n);
    }
    return UNDEFINED_VALUE;
}
