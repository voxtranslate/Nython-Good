// NyCoro.cpp — stackful coroutines; see include/NyCoro.hpp for the contract.
#include "NyCoro.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <stdexcept>
#include <unordered_set>
#include <vector>

// ── Backend selection ───────────────────────────────────────────────────────
#if defined(_WIN32)
#  define NYCORO_FIBERS 1
#elif !defined(NYCORO_FORCE_UCONTEXT) && defined(__ELF__) && defined(__x86_64__)
#  define NYCORO_ASM_X64 1
#elif !defined(NYCORO_FORCE_UCONTEXT) && defined(__ELF__) && defined(__aarch64__)
#  define NYCORO_ASM_A64 1
#else
#  define NYCORO_UCONTEXT 1
#endif

#if defined(NYCORO_FIBERS)
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#else
#  include <pthread.h>
#  include <sys/mman.h>
#  include <unistd.h>
#  if defined(NYCORO_UCONTEXT)
#    if defined(__APPLE__) && !defined(_XOPEN_SOURCE)
#      define _XOPEN_SOURCE 700
#    endif
#    include <ucontext.h>
#  endif
#endif

// ── AddressSanitizer fiber annotations ──────────────────────────────────────
#if defined(__SANITIZE_ADDRESS__)
#  define NYCORO_ASAN 1
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define NYCORO_ASAN 1
#  endif
#endif
#if defined(NYCORO_ASAN) && !defined(NYCORO_FIBERS)
extern "C" {
void __sanitizer_start_switch_fiber(void** fake_stack_save, const void* bottom, size_t size);
void __sanitizer_finish_switch_fiber(void* fake_stack_save, const void** bottom_old, size_t* size_old);
}
#  define ASAN_START(save, bottom, size) __sanitizer_start_switch_fiber((save), (bottom), (size))
#  define ASAN_FINISH(save, bottom, size) __sanitizer_finish_switch_fiber((save), (bottom), (size))
#else
#  define ASAN_START(save, bottom, size) ((void)0)
#  define ASAN_FINISH(save, bottom, size) ((void)0)
#endif

namespace nycoro {

namespace {

// ── Stack memory ────────────────────────────────────────────────────────────
struct StackMem {
    char* map = nullptr;     // start of the mapping (the guard page)
    size_t map_size = 0;
    char* lo = nullptr;      // lowest usable address
    size_t size = 0;         // usable bytes, lo .. lo + size
};

std::atomic<size_t> g_live{0}, g_created{0}, g_mapped_bytes{0}, g_stacks_mapped{0};

size_t page_size() {
#if defined(NYCORO_FIBERS)
    return 4096;
#else
    static size_t p = (size_t)sysconf(_SC_PAGESIZE);
    return p ? p : 4096;
#endif
}

// Safety margin kept free below the RecursionError check: native code that
// runs between two interpreter calls (formatting, regex, a builtin walking a
// nested value) must fit in it. Instrumented builds use bigger frames.
size_t floor_margin(size_t size) {
#if defined(NYCORO_ASAN)
    size_t m = 256 * 1024;
#else
    size_t m = 96 * 1024;
#endif
    if (m > size / 4) m = size / 4;
    return m;
}

#if !defined(NYCORO_FIBERS)
StackMem map_stack(size_t size) {
    size_t pg = page_size();
    size = (size + pg - 1) / pg * pg;
    size_t total = size + pg;   // + one guard page below the stack
    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
#  ifdef MAP_NORESERVE
    flags |= MAP_NORESERVE;
#  endif
#  ifdef MAP_STACK
    flags |= MAP_STACK;
#  endif
    void* p = mmap(nullptr, total, PROT_READ | PROT_WRITE, flags, -1, 0);
    if (p == MAP_FAILED) throw std::bad_alloc();
    if (mprotect(p, pg, PROT_NONE) != 0) { munmap(p, total); throw std::bad_alloc(); }
    StackMem s;
    s.map = (char*)p; s.map_size = total; s.lo = (char*)p + pg; s.size = size;
    g_mapped_bytes += total;
    g_stacks_mapped++;
    return s;
}
void unmap_stack(StackMem& s) {
    if (!s.map) return;
    munmap(s.map, s.map_size);
    g_mapped_bytes -= s.map_size;
    s = StackMem();
}

// Finished coroutines leave their stacks here; creating a generator then
// costs no system call. Pages below the top `kKeepHot` bytes go back to the
// kernel (a deep recursion inside one generator must not stay resident).
struct Pool {
    std::mutex mu;
    std::vector<StackMem> free;
};
Pool& pool() { static Pool* p = new Pool(); return *p; }   // never destroyed: coroutines may finish during exit
constexpr size_t kPoolMax = 64;
constexpr size_t kKeepHot = 64 * 1024;

StackMem take_stack(size_t size) {
    {
        Pool& P = pool();
        std::lock_guard<std::mutex> lk(P.mu);
        for (size_t i = P.free.size(); i-- > 0;) {
            if (P.free[i].size == size) {
                StackMem s = P.free[i];
                P.free[i] = P.free.back();
                P.free.pop_back();
                return s;
            }
        }
    }
    return map_stack(size);
}
void give_stack(StackMem s, bool deep) {
    if (!s.map) return;
    Pool& P = pool();
    {
        std::lock_guard<std::mutex> lk(P.mu);
        if (P.free.size() < kPoolMax) {
            // Only a stack that went below its top kKeepHot bytes can hold
            // more than that resident (the RecursionError check notices it
            // on its way down): give those pages back. Doing it for every
            // stack cost ~450 ns per finished generator.
            if (deep && s.size > kKeepHot) {
#  if defined(MADV_DONTNEED)
                madvise(s.lo, s.size - kKeepHot, MADV_DONTNEED);
#  endif
            }
            P.free.push_back(s);
            return;
        }
    }
    unmap_stack(s);
}
#endif  // !NYCORO_FIBERS

}  // namespace

// ── The coroutine record ────────────────────────────────────────────────────
struct Coro {
    EntryFn fn = nullptr;
    void* arg = nullptr;
    Coro* prev = nullptr;          // Tls::cur when this was resumed
    uintptr_t prev_mark = 0;       // Tls::mark when this was resumed
    uintptr_t floor = 0;           // RecursionError below this
    uintptr_t hot = 0;             // reaching below this marks the stack deep
    bool deep = false;             // went below `hot` (its pages get released)
    uint64_t owner = 0;
    bool is_started = false, is_done = false, is_running = false;
#if defined(NYCORO_FIBERS)
    LPVOID fiber = nullptr;
    LPVOID caller_fiber = nullptr;
    size_t reserve = 0;
#else
    StackMem stack;
    // ASan: the fake stack of this coroutine while it is switched out, and
    // the bounds of the stack that resumed it (to switch back to).
    void* asan_fake = nullptr;
    const void* caller_bottom = nullptr;
    size_t caller_size = 0;
#  if defined(NYCORO_UCONTEXT)
    ucontext_t uc;
    ucontext_t caller_uc;
#  else
    void* sp = nullptr;            // saved stack pointer while switched out
    void* caller_sp = nullptr;     // the resumer's, while this runs
#  endif
#endif
};

// Runs on the coroutine's stack: the function, then a final switch back.
extern "C" void nycoro_main(Coro* c);

// ── Context switch ──────────────────────────────────────────────────────────
#if defined(NYCORO_ASM_X64)
// void nycoro_switch(void** save_sp, void* new_sp)
// Saves the SysV callee-saved registers (rbx, rbp, r12-r15), MXCSR and the
// x87 control word on the current stack, stores the stack pointer in
// *save_sp, loads new_sp and restores the same set from there.
extern "C" void nycoro_switch(void** save_sp, void* new_sp);
extern "C" void nycoro_trampoline();
asm(R"(
    .text
    .globl nycoro_switch
    .type nycoro_switch,@function
    .p2align 4
nycoro_switch:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $8, %rsp
    stmxcsr (%rsp)
    fnstcw 4(%rsp)
    movq %rsp, (%rdi)
    movq %rsi, %rsp
    ldmxcsr (%rsp)
    fldcw 4(%rsp)
    addq $8, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size nycoro_switch,.-nycoro_switch

    .globl nycoro_trampoline
    .type nycoro_trampoline,@function
    .p2align 4
nycoro_trampoline:
    .cfi_startproc
    .cfi_undefined rip
    movq %r12, %rdi
    callq *%r13
    ud2
    .cfi_endproc
    .size nycoro_trampoline,.-nycoro_trampoline
    .section .note.GNU-stack,"",@progbits
    .text
)");

static void prepare(Coro* c) {
    // Initial frame, laid out as nycoro_switch leaves one (from low to high):
    // [mxcsr|fpucw] r15 r14 r13 r12 rbx rbp ret. r12 = the coroutine, r13 =
    // nycoro_main, ret = the trampoline, which calls r13(r12) with the stack
    // 16-byte aligned.
    char* top = c->stack.lo + c->stack.size;
    top = (char*)((uintptr_t)top & ~(uintptr_t)15);
    uint64_t* sp = (uint64_t*)(top - 80);
    uint32_t mxcsr = 0x1F80; uint16_t fpucw = 0x037F;
    asm volatile("stmxcsr %0" : "=m"(mxcsr));
    asm volatile("fnstcw %0" : "=m"(fpucw));
    sp[0] = (uint64_t)mxcsr | ((uint64_t)fpucw << 32);
    sp[1] = 0;                                  // r15
    sp[2] = 0;                                  // r14
    sp[3] = (uint64_t)(uintptr_t)&nycoro_main;  // r13
    sp[4] = (uint64_t)(uintptr_t)c;             // r12
    sp[5] = 0;                                  // rbx
    sp[6] = 0;                                  // rbp
    sp[7] = (uint64_t)(uintptr_t)&nycoro_trampoline;
    c->sp = sp;
}
static inline void switch_in(Coro* c) { nycoro_switch(&c->caller_sp, c->sp); }
static inline void switch_out(Coro* c) { nycoro_switch(&c->sp, c->caller_sp); }

#elif defined(NYCORO_ASM_A64)
// void nycoro_switch(void** save_sp, void* new_sp)
// AAPCS64 callee-saved: x19-x28, x29 (fp), x30 (lr), d8-d15, plus FPCR.
extern "C" void nycoro_switch(void** save_sp, void* new_sp);
extern "C" void nycoro_trampoline();
asm(R"(
    .text
    .globl nycoro_switch
    .type nycoro_switch,%function
    .p2align 4
nycoro_switch:
    sub sp, sp, #176
    stp x19, x20, [sp, #0]
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    stp x29, x30, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mrs x9, fpcr
    str x9, [sp, #160]
    mov x9, sp
    str x9, [x0]
    mov sp, x1
    ldp x19, x20, [sp, #0]
    ldp x21, x22, [sp, #16]
    ldp x23, x24, [sp, #32]
    ldp x25, x26, [sp, #48]
    ldp x27, x28, [sp, #64]
    ldp x29, x30, [sp, #80]
    ldp d8, d9, [sp, #96]
    ldp d10, d11, [sp, #112]
    ldp d12, d13, [sp, #128]
    ldp d14, d15, [sp, #144]
    ldr x9, [sp, #160]
    msr fpcr, x9
    add sp, sp, #176
    ret
    .size nycoro_switch,.-nycoro_switch

    .globl nycoro_trampoline
    .type nycoro_trampoline,%function
    .p2align 4
nycoro_trampoline:
    .cfi_startproc
    .cfi_undefined x30
    mov x0, x19
    blr x20
    brk #0
    .cfi_endproc
    .size nycoro_trampoline,.-nycoro_trampoline
    .section .note.GNU-stack,"",%progbits
    .text
)");

static void prepare(Coro* c) {
    // Initial frame as nycoro_switch leaves one: x19 = the coroutine, x20 =
    // nycoro_main, x30 = the trampoline (which calls x20(x19)), FPCR = ours.
    char* top = c->stack.lo + c->stack.size;
    top = (char*)((uintptr_t)top & ~(uintptr_t)15);
    uint64_t* sp = (uint64_t*)(top - 176);
    std::memset(sp, 0, 176);
    uint64_t fpcr = 0;
    asm volatile("mrs %0, fpcr" : "=r"(fpcr));
    sp[0] = (uint64_t)(uintptr_t)c;             // x19
    sp[1] = (uint64_t)(uintptr_t)&nycoro_main;  // x20
    sp[10] = 0;                                 // x29
    sp[11] = (uint64_t)(uintptr_t)&nycoro_trampoline;  // x30
    sp[20] = fpcr;
    c->sp = sp;
}
static inline void switch_in(Coro* c) { nycoro_switch(&c->caller_sp, c->sp); }
static inline void switch_out(Coro* c) { nycoro_switch(&c->sp, c->caller_sp); }

#elif defined(NYCORO_UCONTEXT)
static void uc_entry(unsigned lo, unsigned hi) {
    nycoro_main((Coro*)(((uintptr_t)hi << 32) | (uintptr_t)lo));
}
static void prepare(Coro* c) {
    if (getcontext(&c->uc) != 0) throw std::bad_alloc();
    c->uc.uc_stack.ss_sp = c->stack.lo;
    c->uc.uc_stack.ss_size = c->stack.size;
    c->uc.uc_link = nullptr;
    uintptr_t p = (uintptr_t)c;
    makecontext(&c->uc, (void (*)())uc_entry, 2, (unsigned)(p & 0xffffffffu), (unsigned)((uint64_t)p >> 32));
}
static inline void switch_in(Coro* c) { swapcontext(&c->caller_uc, &c->uc); }
static inline void switch_out(Coro* c) { swapcontext(&c->uc, &c->caller_uc); }

#elif defined(NYCORO_FIBERS)
// Not compiled or tested in the Linux development container: written
// against the documented Win32 fiber API. A thread becomes a fiber the first
// time it resumes a coroutine (or uses the fiber it already is).
static thread_local LPVOID t_thread_fiber = nullptr;
static VOID WINAPI fiber_entry(LPVOID p) { nycoro_main((Coro*)p); }
static void prepare(Coro* c) {
    c->fiber = CreateFiberEx(64 * 1024, c->reserve, FIBER_FLAG_FLOAT_SWITCH, fiber_entry, c);
    if (!c->fiber) throw std::bad_alloc();
}
static inline void switch_in(Coro* c) {
    if (!t_thread_fiber) {
        if (IsThreadAFiber()) t_thread_fiber = GetCurrentFiber();
        else t_thread_fiber = ConvertThreadToFiberEx(nullptr, FIBER_FLAG_FLOAT_SWITCH);
        if (!t_thread_fiber) throw std::runtime_error("cannot convert the thread to a fiber");
    }
    c->caller_fiber = GetCurrentFiber();
    SwitchToFiber(c->fiber);
}
static inline void switch_out(Coro* c) { SwitchToFiber(c->caller_fiber); }
#endif

extern "C" void nycoro_main(Coro* c) {
#if !defined(NYCORO_FIBERS)
    ASAN_FINISH(nullptr, &c->caller_bottom, &c->caller_size);
#else
    {
        ULONG_PTR lo = 0, hi = 0;
        GetCurrentThreadStackLimits(&lo, &hi);
        size_t m = floor_margin((size_t)(hi - lo));
        c->floor = (uintptr_t)lo + m + 3 * 4096;   // + the fiber's guard pages
        c->hot = c->floor;
        Tls::mark = c->floor;
    }
#endif
    try {
        c->fn(c->arg);
    } catch (...) {
        // The contract says the function catches everything; an exception
        // here cannot unwind further (there is no frame above this one).
        std::fputs("nycoro: exception escaped a coroutine\n", stderr);
        std::abort();
    }
    c->is_done = true;
    // The final switch: pass no fake-stack slot, so ASan frees this one.
    ASAN_START(nullptr, c->caller_bottom, c->caller_size);
    switch_out(c);
    std::abort();   // a finished coroutine is never resumed
}

// ── API ─────────────────────────────────────────────────────────────────────
size_t default_stack_size() {
    static size_t sz = [] {
        size_t kb = 1024;
        if (const char* e = std::getenv("NY_GEN_STACK_KB")) {
            long v = std::strtol(e, nullptr, 10);
            if (v >= 64 && v <= 1024 * 1024) kb = (size_t)v;
        }
        return kb * 1024;
    }();
    return sz;
}

Coro* create(EntryFn fn, void* arg, size_t stack_size) {
    if (!stack_size) stack_size = default_stack_size();
    Coro* c = new Coro();
    c->fn = fn;
    c->arg = arg;
    try {
#if defined(NYCORO_FIBERS)
        c->reserve = stack_size;
        prepare(c);
#else
        c->stack = take_stack(stack_size);
        c->floor = (uintptr_t)c->stack.lo + floor_margin(c->stack.size);
        uintptr_t top = (uintptr_t)c->stack.lo + c->stack.size;
        c->hot = c->stack.size > 2 * kKeepHot ? top - kKeepHot : c->floor;
        if (c->hot < c->floor) c->hot = c->floor;
        prepare(c);
#endif
    } catch (...) {
#if !defined(NYCORO_FIBERS)
        if (c->stack.map) give_stack(c->stack, false);
#endif
        delete c;
        throw;
    }
    g_live++;
    g_created++;
    return c;
}

void resume(Coro* c) {
    if (!c || c->is_done) throw std::runtime_error("nycoro: resume of a finished coroutine");
    if (c->is_running) throw std::runtime_error("nycoro: resume of a running coroutine");
    uint64_t me = thread_token();
    if (c->is_started && c->owner != me)
        throw std::runtime_error("nycoro: a coroutine started on one thread was resumed on another");
    if (!c->is_started) { c->is_started = true; c->owner = me; }
    c->prev = Tls::cur;
    c->prev_mark = Tls::mark;
    Tls::cur = c;
    Tls::mark = c->deep ? c->floor : c->hot;
    c->is_running = true;
#if !defined(NYCORO_FIBERS)
    [[maybe_unused]] void* fake = nullptr;
    ASAN_START(&fake, c->stack.lo, c->stack.size);
    switch_in(c);
    ASAN_FINISH(fake, nullptr, nullptr);
#else
    switch_in(c);
#endif
    c->is_running = false;
    Tls::cur = c->prev;
    Tls::mark = c->prev_mark;
}

uintptr_t os_stack_floor() {
    uintptr_t lo = 0, size = 0;
#if defined(NYCORO_FIBERS)
    ULONG_PTR l = 0, h = 0;
    GetCurrentThreadStackLimits(&l, &h);
    lo = (uintptr_t)l; size = (uintptr_t)(h - l);
#elif defined(__APPLE__)
    char* top = (char*)pthread_get_stackaddr_np(pthread_self());
    size = (uintptr_t)pthread_get_stacksize_np(pthread_self());
    lo = (uintptr_t)top - size;
#elif defined(__linux__) || defined(__FreeBSD__)
    pthread_attr_t attr;
#  if defined(__FreeBSD__)
    pthread_attr_init(&attr);
    if (pthread_attr_get_np(pthread_self(), &attr) == 0) {
#  else
    if (pthread_getattr_np(pthread_self(), &attr) == 0) {
#  endif
        void* addr = nullptr; size_t sz = 0;
        if (pthread_attr_getstack(&attr, &addr, &sz) == 0) { lo = (uintptr_t)addr; size = sz; }
        pthread_attr_destroy(&attr);
    }
#endif
    uintptr_t f = 0;
    if (lo && size) {
        size_t m = floor_margin(size) * 2;   // room for native code, as on a coroutine
        f = lo + m;
    }
    Tls::os_floor = f;
    return f;
}

bool stack_exhausted_slow(uintptr_t frame) {
    Coro* c = Tls::cur;
    if (!c) return false;
    if (frame < c->floor) return true;
    // Past the hot top of the stack for the first time: remember it, and
    // check against the floor from now on.
    c->deep = true;
    Tls::mark = c->floor;
    return false;
}

void suspend() {
    Coro* c = Tls::cur;
    if (!c) throw std::runtime_error("nycoro: suspend() outside a coroutine");
#if !defined(NYCORO_FIBERS)
    ASAN_START(&c->asan_fake, c->caller_bottom, c->caller_size);
    switch_out(c);
    ASAN_FINISH(c->asan_fake, &c->caller_bottom, &c->caller_size);
#else
    switch_out(c);
#endif
}

bool done(const Coro* c) { return c->is_done; }
bool started(const Coro* c) { return c->is_started; }
bool running(const Coro* c) { return c->is_running; }
uint64_t owner(const Coro* c) { return c->owner; }

// Thread tokens: std::thread::id values are reused once a thread ends, and a
// coroutine started on a thread that has ended must never be resumed by a
// newer one (its frames point at the dead thread's thread_local data).
namespace {
std::atomic<uint64_t> g_next_token{1};
std::mutex& token_mu() { static auto* m = new std::mutex(); return *m; }
std::unordered_set<uint64_t>& alive_tokens() { static auto* s = new std::unordered_set<uint64_t>(); return *s; }
struct TokenHolder {
    uint64_t id = 0;
    ~TokenHolder() {
        if (!id) return;
        std::lock_guard<std::mutex> lk(token_mu());
        alive_tokens().erase(id);
    }
};
thread_local TokenHolder t_token;
}  // namespace

uint64_t thread_token() {
    if (!t_token.id) {
        t_token.id = g_next_token++;
        std::lock_guard<std::mutex> lk(token_mu());
        alive_tokens().insert(t_token.id);
    }
    return t_token.id;
}

bool thread_alive(uint64_t token) {
    if (!token) return false;
    std::lock_guard<std::mutex> lk(token_mu());
    return alive_tokens().count(token) > 0;
}
Coro* current() { return Tls::cur; }
uintptr_t stack_floor(const Coro* c) { return c->floor; }

void destroy(Coro* c) {
    if (!c) return;
    if (c->is_running) { std::fputs("nycoro: destroy() of a running coroutine\n", stderr); std::abort(); }
    if (c->is_started && !c->is_done) {
        // Suspended: frames on its stack were never unwound. Their memory is
        // left mapped (something may still point into it) and the record is
        // dropped; the generator layer only gets here when a generator
        // refused every request to finish.
        g_live--;
        delete c;
        return;
    }
#if defined(NYCORO_FIBERS)
    if (c->fiber) DeleteFiber(c->fiber);
#else
    give_stack(c->stack, c->deep);
#endif
    g_live--;
    delete c;
}

Stats stats() {
    Stats s;
    s.live = g_live.load();
    s.created = g_created.load();
    s.mapped_bytes = g_mapped_bytes.load();
    s.stacks_mapped = g_stacks_mapped.load();
#if !defined(NYCORO_FIBERS)
    {
        Pool& P = pool();
        std::lock_guard<std::mutex> lk(P.mu);
        s.pooled = P.free.size();
    }
#endif
    return s;
}

const char* backend() {
#if defined(NYCORO_ASM_X64)
    return "x86-64 asm";
#elif defined(NYCORO_ASM_A64)
    return "aarch64 asm";
#elif defined(NYCORO_UCONTEXT)
    return "ucontext";
#else
    return "fibers";
#endif
}

}  // namespace nycoro
