#pragma once
// NyGC.hpp - memory management for the interpreter's heap (Collectable).
//
// The model is CPython's: exact reference counting frees an object the moment
// the last reference to it goes, and a generational cycle collector finds the
// groups of objects that only keep each other alive (a node whose field points
// back at itself, parent <-> child, a closure stored in the scope it closes
// over) and frees those too.
//
// Reference counting needs no stack scanning: a Value in a C++ local, in a
// container, on another thread's stack or on a coroutine stack counts exactly
// like any other. The cycle collector needs only each object's outgoing
// references (Collectable::gc_traverse): for the objects of the generations
// being collected it subtracts the references they hold on each other from
// their counts ("trial deletion"); what keeps a positive count is referenced
// from outside the group, everything reachable from there survives, and the
// rest is garbage - cleared (gc_clear) so the counts fall to zero.
//
// Invariants (GC_NOTES.md has the full list):
//   - Counts are plain integers: every Value is touched with the GIL held
//     (NyConc.hpp), or by the only thread when there is no GIL yet.
//   - A tracked object with a count of zero is being built by native code
//     that holds it by pointer (new Object, then fill, then wrap in a
//     Value): the collector treats it as a root, never as garbage.
//   - Finalizers (__del__) never run inside a decrement: an object with a
//     finalizer that reaches zero is queued and finalized at the next safe
//     point (a statement boundary), once (PEP 442); cyclic garbage is
//     finalized first and only freed if the finalizers did not resurrect it.
//   - Freeing is iterative past a small depth (a trash list), so dropping a
//     long linked list cannot overflow the C++ stack.
// Through Value.hpp: Collectable.hpp cannot come first (Runnable.hpp
// includes Value.hpp, which needs it).
#include "Value.hpp"
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace nygc {

enum : uint16_t {
    F_TRACKED    = 1,    // linked into a generation list
    F_FINALIZED  = 2,    // __del__ has run (it runs at most once)
    F_QUEUED     = 4,    // waiting in the finalizer queue
    F_REACHABLE  = 8,    // scratch: reached during a collection
    F_COLLECTING = 16,   // scratch: in the generations being collected
    F_DEALLOC    = 32,   // being destroyed
    F_WEAKREFD   = 64,   // weakref() targets it: tell g_weak_hook when it dies
};
// Called when an object with F_WEAKREFD is destroyed (its weak references
// then give none).
extern void (*g_weak_hook)(Collectable*);

constexpr int kGenerations = 3;

// Link a new object that can hold references into generation 0 / unlink it.
void track(Collectable* c);
void untrack(Collectable* c);

// Work is waiting for a safe point: queued finalizers, a due collection, or
// values released by a thread that did not hold the GIL. One relaxed load
// per statement.
extern std::atomic<bool> g_pending;
void safe_point_slow();
inline void safe_point() { if (g_pending.load(std::memory_order_relaxed)) safe_point_slow(); }
// A value dropped by a thread that does not hold the GIL (a runtime object
// freed from a blocking wait): its reference is released at the next safe
// point, by the thread that holds it.
void release_later(Collectable* owner);

// A full or partial collection now. Returns the number of unreachable
// objects found (and freed, unless a finalizer resurrected them).
long collect(int generation = kGenerations - 1);

// Automatic collection (the thresholds); explicit collect() always runs.
void set_enabled(bool on);
bool is_enabled();
void set_threshold(int gen, long value);
long threshold(int gen);

// During teardown decrements to zero leave objects alone: what outlives the
// engine that owns it (an AST's interned literal, a value parked in a static
// table) is reclaimed by the process exit.
extern bool g_shutdown;

struct Stats {
    long long collections[kGenerations] = {0, 0, 0};
    long long collected[kGenerations] = {0, 0, 0};   // unreachable objects freed
    long long uncollectable = 0;                     // resurrected by a finalizer
    long long finalized = 0;                         // __del__ calls
    long long freed_by_refcount = 0;
    long long gen_count[kGenerations] = {0, 0, 0};   // objects in each generation
    long long tracked = 0;
    long long live_strings = 0;
    long long string_bytes = 0;
};
Stats stats();
long long tracked_objects();

// Strings (untracked, counted for gc_stats()).
extern long long g_live_strings;
extern long long g_string_bytes;

// Bytes the C allocator has handed out and not got back (glibc; 0 where
// unknown). Both engines run a full collection when it has doubled since
// their last one.
size_t heap_bytes();
// Give the allocator's free pages back to the system (after a full
// collection; glibc malloc_trim, a no-op elsewhere).
void trim_heap();

// Resident set size of the process in KB (Linux /proc; 0 where unknown).
long long rss_kb();
long long peak_rss_kb();

} // namespace nygc
