#pragma once
// ─────────────────────────────────────────────────────────────────────────────
// NyCoro.hpp — stackful coroutines (round 75).
//
// A coroutine runs a function on a C stack of its own and can suspend itself
// in the middle of that function, from any depth of C++ calls, and be resumed
// later exactly where it stopped. The interpreter runs every generator body on
// one: a `yield` deep inside evalNode -> evalFor -> evalIf -> ... simply
// suspends the coroutine, and next()/send() resumes it (src/NyGen.cpp).
//
// Backends, chosen at compile time:
//   * x86-64 / AArch64 on ELF systems (Linux, the BSDs): a hand-written
//     switch that saves the callee-saved registers and the floating-point
//     control words, and swaps stack pointers (~20 ns, no system call);
//   * everything else POSIX: ucontext (makecontext/swapcontext), which also
//     saves the signal mask with a system call per switch;
//   * Windows: fibers (CreateFiberEx / SwitchToFiber), pooled; built with
//     MinGW-w64 and run under Wine here, never on a real Windows machine.
// Define NYCORO_FORCE_UCONTEXT to use ucontext on x86-64/AArch64 as well.
//
// Stacks are reserved with mmap and committed lazily by the kernel as they
// are touched, with a PROT_NONE guard page below each one, so a stack
// overflow faults instead of silently writing into the next stack. Finished
// coroutines return their stack to a small pool for reuse.
//
// Rules for users of this API:
//   * a coroutine's function must not let a C++ exception escape: catch it at
//     the top (an exception can never unwind across a stack switch) and hand
//     it to the resumer, which rethrows it (std::exception_ptr);
//   * a started coroutine must be resumed on the thread that started it
//     (thread_local variables are reached through addresses the compiler may
//     keep in registers across the switch); NyCoro checks this and throws;
//   * a coroutine is destroyed only when it has finished or never started.
//     To get rid of a suspended one, resume it with a request to unwind
//     (the generator layer throws GeneratorExit / a forced unwind at the
//     yield point) and let its function return.
//
// AddressSanitizer: the switches are annotated with
// __sanitizer_start_switch_fiber / __sanitizer_finish_switch_fiber when the
// build uses -fsanitize=address, so ASan follows the stack changes.
// ─────────────────────────────────────────────────────────────────────────────
#include <cstddef>
#include <cstdint>
#if defined(_MSC_VER) && !defined(__clang__)
#include <intrin.h>
#endif

namespace nycoro {

struct Coro;
using EntryFn = void (*)(void* arg);

// The stack reserved for each coroutine, in bytes: NY_GEN_STACK_KB (read
// once) or the built-in default. Address space only; memory is committed as
// the coroutine touches it.
size_t default_stack_size();

// A coroutine that runs fn(arg) on its own stack the first time it is
// resumed. Throws std::bad_alloc when no stack can be mapped.
Coro* create(EntryFn fn, void* arg, size_t stack_size = 0);

// Switches into `c` until it suspends or its function returns. Throws
// std::runtime_error (without switching) when `c` was started on another
// thread, is already running, or has finished.
void resume(Coro* c);

// From inside the running coroutine: switch back to whoever resumed it.
void suspend();

// Its function has returned.
bool done(const Coro* c);
// It has been resumed at least once.
bool started(const Coro* c);
// It is running (between resume() and the matching suspend()/return).
bool running(const Coro* c);
// The thread that started it: a token unique to that thread and never
// reused after it ends (0 before the first resume).
uint64_t owner(const Coro* c);
// The calling thread's token.
uint64_t thread_token();
// Whether the thread with this token is still running.
bool thread_alive(uint64_t token);

// Frees `c`, returning its stack to the pool. `c` must be done, or never
// resumed.
void destroy(Coro* c);

// The innermost coroutine running on this thread, nullptr on a thread's own
// stack.
Coro* current();

// Lowest address a frame may reach while running on c's stack before the
// caller should refuse to go deeper (RecursionError): the stack's lowest
// usable address plus a safety margin for native code between two checks.
uintptr_t stack_floor(const Coro* c);

// Per-thread state the switch keeps current, readable inline on hot paths.
// `mark` is 0 on a thread's own stack (whose depth the interpreter's call
// counter bounds); on a coroutine's stack it is the address below which
// stack_exhausted() takes its slow path: first a point near the top of the
// stack (reaching it marks the stack as used deeply, so its pages are
// returned to the kernel when it is pooled), then the stack's floor.
struct Tls {
    static inline thread_local uintptr_t mark = 0;
    static inline thread_local Coro* cur = nullptr;
    static inline thread_local uintptr_t os_floor = 1;   // 1: not looked up yet
};
bool stack_exhausted_slow(uintptr_t frame);
// The caller's position on its stack: the address of a local. Not
// __builtin_frame_address(0), which forces a frame pointer in every function
// this is inlined into (evalCall, runFunctionBody, ...) - and for a Windows
// x64 function that has a frame pointer and also saves XMM registers, GCC's
// unwind info records those saves relative to the final RSP while the
// unwinder reads them relative to the frame pointer. Every exception
// unwinding through such a frame then restored XMM6/XMM7 from the wrong
// address, and at the top of a fiber's stack read past its end (the crash a
// deep recursion raising inside a generator hit, 64-bit Windows, -O2).
inline uintptr_t stack_position() {
    volatile char here = 0;
    return (uintptr_t)&here;
}
// Whether the calling frame is below the running coroutine's floor: the
// caller should raise RecursionError instead of going deeper.
inline bool stack_exhausted() {
    uintptr_t fp = stack_position();
#if defined(_MSC_VER) && !defined(__clang__)
    if (fp < Tls::mark) return stack_exhausted_slow(fp);
#else
    if (__builtin_expect(fp < Tls::mark, 0)) return stack_exhausted_slow(fp);
#endif
    return false;
}

// The same question for whatever stack the caller is on: a coroutine's, or
// the thread's own (its bounds are looked up once per thread; 0 where the
// platform cannot tell, and then only the callers' depth counters apply).
uintptr_t os_stack_floor();
inline bool native_stack_exhausted() {
    if (Tls::cur) return stack_exhausted();
    uintptr_t fp = stack_position();
    uintptr_t f = Tls::os_floor;
    if (f == 1) f = os_stack_floor();
    return fp < f;
}

struct Stats {
    size_t live = 0;          // coroutines created and not destroyed
    size_t pooled = 0;        // stacks waiting in the pool
    size_t mapped_bytes = 0;  // address space reserved for stacks (live + pooled)
    size_t created = 0;       // coroutines created so far
    size_t stacks_mapped = 0; // stacks mmapped so far (the rest came from the pool)
};
Stats stats();

// Name of the switch backend compiled in ("x86-64 asm", "aarch64 asm",
// "ucontext", "fibers").
const char* backend();

}  // namespace nycoro
