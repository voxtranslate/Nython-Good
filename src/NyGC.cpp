// NyGC.cpp - reference counting and the generational cycle collector for the
// interpreter's heap. See include/NyGC.hpp for the model and its invariants,
// and GC_NOTES.md for how the engine's objects plug into it.
#include "NyGC.hpp"
#include "NyStr.hpp"
#if defined(_WIN32)
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#  include <psapi.h>
#endif

#include <cstdio>
#include <cstdlib>
#if defined(__GLIBC__)
#include <malloc.h>
#endif
#include <cstring>
#include <deque>
#include <mutex>
#include <algorithm>
#include <limits>
#include <vector>

namespace nygc {

std::atomic<bool> g_pending{false};
void (*g_weak_hook)(Collectable*) = nullptr;
KeyTable g_keys;
bool g_key_edges = false;

void visit_key_objects(const std::string& key, nython::gc::GcVisitFn visit, void* arg) {
    if (key.size() < 2 || key[0] != '\x01' || !g_keys.lookup) return;
    if (key[1] == 'o') {
        if (Collectable* o = g_keys.lookup(key.substr(2))) visit(o, arg);
    } else if (key[1] == 't') {
        for (auto& part : nypy::key_tuple_parts(key)) visit_key_objects(part, visit, arg);
    }
}
bool g_shutdown = false;
long long g_live_strings = 0;
long long g_string_bytes = 0;

namespace {

// Lists 0..2 are the generations; 3 holds the objects of a collection in
// progress, 4 the ones it found unreachable. An object's gc_gen names the
// list it is on, so unlinking works whichever list that is.
constexpr int kYoung = 3, kUnreachable = 4, kLists = 5;

struct List {
    Collectable* head = nullptr;
    long long size = 0;
};
List lists[kLists];
// Allocations minus deallocations since generation 0 was last collected;
// for generations 1 and 2, collections of the generation below.
long counts[kGenerations] = {0, 0, 0};
long thresholds[kGenerations] = {2000, 10, 10};   // CPython 3.13's young threshold
bool enabled = true;
bool collecting = false;
bool in_safe_point = false;
// CPython's guard against quadratic full collections: a full collection
// runs only once the objects promoted into the oldest generation since the
// last one are a quarter of those it kept.
long long long_lived_total = 0;
long long long_lived_pending = 0;
Stats st;
// Never destroyed: values held in other static tables may still be released
// while the process exits, after this file's statics would be gone.
std::deque<Collectable*>& final_queue = *new std::deque<Collectable*>();
std::vector<Collectable*>& trash = *new std::vector<Collectable*>();
int dealloc_depth = 0;
constexpr int kMaxDeallocDepth = 64;

void link(int li, Collectable* c) {
    List& l = lists[li];
    c->gc_prev = nullptr;
    c->gc_next = l.head;
    if (l.head) l.head->gc_prev = c;
    l.head = c;
    c->gc_gen = (uint8_t)li;
    l.size++;
}

void unlink(Collectable* c) {
    List& l = lists[c->gc_gen];
    if (c->gc_prev) c->gc_prev->gc_next = c->gc_next;
    else l.head = c->gc_next;
    if (c->gc_next) c->gc_next->gc_prev = c->gc_prev;
    c->gc_prev = c->gc_next = nullptr;
    l.size--;
}

void move_all(int from, int to) {
    while (lists[from].head) {
        Collectable* c = lists[from].head;
        unlink(c);
        link(to, c);
    }
}

void note_due() {
    if (enabled && !collecting && counts[0] > thresholds[0]) g_pending.store(true, std::memory_order_relaxed);
}

void destroy(Collectable* c) {
    ++dealloc_depth;
    delete c;
    --dealloc_depth;
}

void drain_trash() {
    while (!trash.empty()) {
        Collectable* c = trash.back();
        trash.pop_back();
        destroy(c);
    }
}

// ── trial deletion ────────────────────────────────────────────────────────
void visit_subtract(Collectable* child, void*) {
    if (child && (child->gc_flags & F_COLLECTING)) child->gc_refs--;
}

void visit_reach(Collectable* child, void* arg) {
    if (!child) return;
    if ((child->gc_flags & F_COLLECTING) && !(child->gc_flags & F_REACHABLE)) {
        child->gc_flags |= F_REACHABLE;
        static_cast<std::vector<Collectable*>*>(arg)->push_back(child);
    }
}

// Collect generations 0..gen. Returns the number of unreachable objects.
long collect_impl(int gen) {
    if (collecting) return 0;
    collecting = true;
    st.collections[gen]++;
    // The generations being collected, as one list.
    for (int g = 0; g <= gen; g++) move_all(g, kYoung);
    for (int g = 0; g <= gen; g++) counts[g] = 0;
    if (gen + 1 < kGenerations) counts[gen + 1]++;

    // 1. Every candidate's count, less the references the candidates hold on
    //    each other. A count of zero means native code is still building the
    //    object by pointer (the invariant in NyGC.hpp): a root.
    for (Collectable* c = lists[kYoung].head; c; c = c->gc_next) {
        c->gc_flags |= F_COLLECTING;
        c->gc_flags &= (uint16_t)~F_REACHABLE;
        c->gc_refs = c->gc_rc == 0 ? (std::numeric_limits<int64_t>::max() / 2) : (int64_t)c->gc_rc;
    }
    for (Collectable* c = lists[kYoung].head; c; c = c->gc_next) c->gc_traverse(visit_subtract, nullptr);
    // The object-key table's references are the dicts' (NyGC.hpp, KeyTable):
    // discounted here, and followed from the dicts that are reached.
    const bool keys = gen == kGenerations - 1 && g_keys.any && g_keys.any();
    if (keys) g_keys.each(visit_subtract, nullptr);

    // 2. What is still referenced from outside, and everything it reaches.
    std::vector<Collectable*> work;
    for (Collectable* c = lists[kYoung].head; c; c = c->gc_next)
        if (c->gc_refs > 0) { c->gc_flags |= F_REACHABLE; work.push_back(c); }
    g_key_edges = keys;
    while (!work.empty()) {
        Collectable* c = work.back();
        work.pop_back();
        c->gc_traverse(visit_reach, &work);
    }
    g_key_edges = false;

    // 3. Survivors move up a generation; the rest is garbage.
    int older = gen + 1 < kGenerations ? gen + 1 : gen;
    std::vector<Collectable*> unreachable;
    long long promoted = 0;
    while (lists[kYoung].head) {
        Collectable* c = lists[kYoung].head;
        unlink(c);
        if (c->gc_flags & F_REACHABLE) {
            c->gc_flags &= (uint16_t)~(F_REACHABLE | F_COLLECTING);
            link(older, c);
            promoted++;
        } else {
            link(kUnreachable, c);
            unreachable.push_back(c);
        }
    }
    if (gen == kGenerations - 2) long_lived_pending += promoted;
    if (gen == kGenerations - 1) { long_lived_pending = 0; long_lived_total = lists[kGenerations - 1].size; }

    long n = (long)unreachable.size();
    if (n == 0) { collecting = false; return 0; }

    // Hold every garbage object while finalizers run and while clearing, so
    // none is destroyed in the middle of the pass.
    for (Collectable* u : unreachable) incref(u);

    // 4. PEP 442: finalizers first, once each...
    bool ran = false;
    for (Collectable* u : unreachable) {
        if (!(u->gc_flags & F_FINALIZED) && u->gc_has_finalizer()) {
            u->gc_flags |= F_FINALIZED;
            st.finalized++;
            ran = true;
            u->gc_finalize();
        }
    }
    // ...then, if any ran, check that none of them made the group reachable
    // again. If one did, the whole group survives this collection.
    if (ran) {
        for (Collectable* u : unreachable) u->gc_refs = (int64_t)u->gc_rc - 1;
        for (Collectable* u : unreachable) u->gc_traverse(visit_subtract, nullptr);
        if (keys) g_keys.each(visit_subtract, nullptr);
        bool resurrected = false;
        for (Collectable* u : unreachable) if (u->gc_refs > 0) { resurrected = true; break; }
        if (resurrected) {
            for (Collectable* u : unreachable) u->gc_flags &= (uint16_t)~(F_REACHABLE | F_COLLECTING);
            move_all(kUnreachable, kGenerations - 1);
            st.uncollectable += n;
            for (Collectable* u : unreachable) decref(u);
            collecting = false;
            return 0;
        }
    }

    // 5. Break the cycles; dropping the holds then frees the objects. The
    //    key table lets go of the garbage first (the holds keep it alive).
    if (keys) g_keys.drop_garbage();
    for (Collectable* u : unreachable) u->gc_flags &= (uint16_t)~(F_REACHABLE | F_COLLECTING);
    for (Collectable* u : unreachable) u->gc_clear();
    st.collected[gen] += n;
    for (Collectable* u : unreachable) decref(u);
    // Anything a traversal under-reported is still alive: keep it.
    move_all(kUnreachable, kGenerations - 1);
    collecting = false;
    return n;
}

// After a full collection, give the pages the allocator holds free back to
// the system (glibc keeps them otherwise: a phase that built and dropped
// 60 MB of floats kept the process 60 MB larger for the rest of its life).
void release_free_pages() {
#if defined(__GLIBC__)
    malloc_trim(0);
#endif
}

size_t heap_after_full = 0;
size_t heap_factor = 2;

void collect_due() {
    // The generation thresholds count objects, not bytes: a few hundred
    // objects that each hold 100,000 floats (a model's parameters) are old
    // before they become garbage, and waited for a full collection that the
    // object counts put off - four models built in turn kept all four
    // (263 MB). So a full collection also runs when the heap has doubled
    // since the last one (and grown by 16 MB): memory stays within about
    // twice what is live, and the work is amortised over what was allocated.
    //
    // While a program is only building (the full collections find little),
    // the factor backs off to 4 and 8, so growing a large live structure
    // does not pay a full collection at every doubling.
    size_t h = heap_bytes();
    if (h && !heap_after_full) heap_after_full = h;
    if (h > heap_factor * heap_after_full && h > heap_after_full + ((size_t)16 << 20)) {
        long long before = tracked_objects();
        long n = collect_impl(kGenerations - 1);
        heap_factor = (n * 8 < before) ? std::min<size_t>(heap_factor * 2, 8) : 2;
        release_free_pages();
        heap_after_full = heap_bytes();
        return;
    }
    for (int g = kGenerations - 1; g >= 0; g--) {
        if (counts[g] <= thresholds[g]) continue;
        if (g == kGenerations - 1 && long_lived_pending < long_lived_total / 4) continue;
        collect_impl(g);
        if (g == kGenerations - 1) { release_free_pages(); heap_after_full = heap_bytes(); }
        break;
    }
}

} // namespace

void track(Collectable* c) {
    if (c->gc_flags & F_TRACKED) return;
    c->gc_flags |= F_TRACKED;
    link(0, c);
    counts[0]++;
    note_due();
}

void untrack(Collectable* c) {
    if (!(c->gc_flags & F_TRACKED)) return;
    unlink(c);
    c->gc_flags &= (uint16_t)~F_TRACKED;
    if (counts[0] > 0) counts[0]--;
}

void dealloc(Collectable* c) {
    if (g_shutdown) return;
    if (c->gc_flags & F_DEALLOC) return;
    // A finalizer never runs inside a decrement: the object waits, alive,
    // for the next safe point.
    if (!(c->gc_flags & F_FINALIZED) && c->gc_has_finalizer()) {
        c->gc_rc = 1;
        c->gc_flags |= F_QUEUED;
        final_queue.push_back(c);
        g_pending.store(true, std::memory_order_relaxed);
        return;
    }
    if ((c->gc_flags & F_WEAKREFD) && g_weak_hook) g_weak_hook(c);
    untrack(c);
    c->gc_flags |= F_DEALLOC;
    st.freed_by_refcount++;
    if (dealloc_depth >= kMaxDeallocDepth) { trash.push_back(c); return; }
    destroy(c);
    if (dealloc_depth == 0 && !trash.empty()) drain_trash();
}

namespace {
std::mutex& later_mutex() { static auto* m = new std::mutex(); return *m; }
std::vector<Collectable*>& later() { static auto* v = new std::vector<Collectable*>(); return *v; }
}

void release_later(Collectable* owner) {
    if (!owner) return;
    {
        std::lock_guard<std::mutex> l(later_mutex());
        later().push_back(owner);
    }
    g_pending.store(true, std::memory_order_release);
}

void safe_point_slow() {
    if (in_safe_point || collecting || g_shutdown) return;
    in_safe_point = true;
    g_pending.store(false, std::memory_order_relaxed);
    {
        std::vector<Collectable*> rel;
        {
            std::lock_guard<std::mutex> l(later_mutex());
            rel.swap(later());
        }
        for (Collectable* c : rel) decref(c);
    }
    // Objects whose count reached zero and that have a finalizer: run it,
    // then drop the queue's reference (freeing them unless resurrected).
    while (!final_queue.empty()) {
        Collectable* c = final_queue.front();
        final_queue.pop_front();
        c->gc_flags &= (uint16_t)~F_QUEUED;
        if (!(c->gc_flags & F_FINALIZED)) {
            c->gc_flags |= F_FINALIZED;
            st.finalized++;
            c->gc_finalize();
        }
        decref(c);
    }
    if (enabled) collect_due();
    in_safe_point = false;
    if (!final_queue.empty()) g_pending.store(true, std::memory_order_relaxed);
}

long collect(int generation) {
    if (generation < 0) generation = 0;
    if (generation >= kGenerations) generation = kGenerations - 1;
    if (collecting) return 0;
    // Finalizers waiting from reference counting run first, as they would
    // have at the next statement.
    bool saved = in_safe_point;
    if (!in_safe_point && !final_queue.empty()) { safe_point_slow(); }
    in_safe_point = saved;
    long n = collect_impl(generation);
    if (generation == kGenerations - 1) { release_free_pages(); heap_after_full = heap_bytes(); }
    return n;
}

void set_enabled(bool on) { enabled = on; note_due(); }
bool is_enabled() { return enabled; }
void set_threshold(int gen, long value) {
    if (gen >= 0 && gen < kGenerations) thresholds[gen] = value < 1 ? 1 : value;
    note_due();
}
long threshold(int gen) { return gen >= 0 && gen < kGenerations ? thresholds[gen] : 0; }

long long tracked_objects() {
    long long n = 0;
    for (int i = 0; i < kLists; i++) n += lists[i].size;
    return n;
}

Stats stats() {
    Stats s = st;
    for (int g = 0; g < kGenerations; g++) s.gen_count[g] = lists[g].size;
    s.tracked = tracked_objects();
    s.live_strings = g_live_strings;
    s.string_bytes = g_string_bytes;
    return s;
}

#if defined(_WIN32)
// The process's working set (resident memory), current and peak, in KB.
// GetProcessMemoryInfo is K32GetProcessMemoryInfo in kernel32 from Windows 7
// on, and only in psapi.dll on Vista (the oldest target): looked up, so the
// program links and runs on both. mem_rss_kb() used to read 0 on Windows.
static bool win_memory(long long& rss, long long& peak) {
    using Fn = BOOL (WINAPI*)(HANDLE, PROCESS_MEMORY_COUNTERS*, DWORD);
    static Fn fn = [] {
        Fn f = (Fn)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "K32GetProcessMemoryInfo");
        if (!f) {
            if (HMODULE ps = LoadLibraryW(L"psapi.dll")) f = (Fn)(void*)GetProcAddress(ps, "GetProcessMemoryInfo");
        }
        return f;
    }();
    if (!fn) return false;
    PROCESS_MEMORY_COUNTERS pmc;
    std::memset(&pmc, 0, sizeof pmc);
    pmc.cb = sizeof pmc;
    if (!fn(GetCurrentProcess(), &pmc, sizeof pmc)) return false;
    rss = (long long)(pmc.WorkingSetSize / 1024);
    peak = (long long)(pmc.PeakWorkingSetSize / 1024);
    return true;
}
#endif

static long long proc_status_kb(const char* key) {
    FILE* f = std::fopen("/proc/self/status", "r");
    if (!f) return 0;
    char line[256];
    long long v = 0;
    size_t kl = std::strlen(key);
    while (std::fgets(line, sizeof line, f)) {
        if (std::strncmp(line, key, kl) == 0) { v = std::atoll(line + kl); break; }
    }
    std::fclose(f);
    return v;
}
long long rss_kb() {
#if defined(_WIN32)
    long long rss = 0, peak = 0;
    return win_memory(rss, peak) ? rss : 0;
#else
    return proc_status_kb("VmRSS:");
#endif
}

void trim_heap() { release_free_pages(); }

size_t heap_bytes() {
#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 33))
    struct mallinfo2 mi = mallinfo2();
    return mi.uordblks + mi.hblkhd;
#else
    return 0;   // no byte trigger: the generation counts alone
#endif
}
long long peak_rss_kb() {
#if defined(_WIN32)
    long long rss = 0, peak = 0;
    return win_memory(rss, peak) ? peak : 0;
#else
    return proc_status_kb("VmHWM:");
#endif
}

} // namespace nygc
