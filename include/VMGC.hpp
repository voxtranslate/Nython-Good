#pragma once
// VMGC.hpp - cycle collection for the VM's heap.
//
// VMVal holds its containers through std::shared_ptr: reference counting is
// exact and immediate, but a reference cycle (an instance whose field points
// back at it, a doubly linked structure, a closure scope that holds the
// function made in it) is never freed. This is the VM's cycle collector, the
// same algorithm as the interpreter's (NyGC.hpp):
//
//   - every list, dict/instance/scope map, iterator and generator the VM
//     creates is registered here once, by a weak_ptr (which does not keep
//     it alive), into generation 0;
//   - a collection locks the live ones of the generations collected, takes
//     use_count() as each one's reference count, subtracts the references
//     the candidates hold on each other (their VMVals' list/map/iter/gen/
//     closure_env pointers), keeps everything reachable from a candidate
//     with references left over, and clears the rest - which frees it;
//   - references the collector cannot see (a native's std::function
//     captures, a compiled code object's constants) simply look external:
//     the objects they reach survive. Missing a reference can only keep
//     something alive, never free it.
//
// Instances of a class with __del__ get a deleter that, instead of freeing
// them, hands their fields to a queue; __del__ runs at the next instruction
// boundary (once), as the interpreter runs it at the next statement.
// Unreachable cycles are finalized before they are cleared and survive if a
// finalizer resurrected them (PEP 442).
#include <atomic>
#include <cstddef>
#include <memory>
#include <string>
#include <utility>
#include <vector>
#include "NyOrderedMap.hpp"

namespace nython::vm {

struct VMVal;
struct GenState;
class VirtualMachine;

namespace vmgc {

using Map = nypy::OrderedMap<VMVal>;
using List = std::vector<VMVal>;
using IterPair = std::pair<int, std::vector<VMVal>>;

// Freeing a long chain (a linked list of instances, nested lists) used to
// recurse once per link through the destructors - a 30,000-node list
// crashed the VM when it was dropped. Lists, maps and iterators are
// allocated with DeepAlloc: when its destroy() runs already nested deeply,
// the object's contents are moved out and parked, and the outermost
// destruction frees what was parked, iteratively. The cost is paid once per
// container destroyed, not per value.
constexpr int kMaxDeepDepth = 200;
inline thread_local int t_deep_depth = 0;
void deep_park(void* obj, void (*destroy)(void*));
void deep_drain();
template<class U> inline void deep_destroy(U* p) {
    if (t_deep_depth < kMaxDeepDepth) {
        ++t_deep_depth;
        p->~U();
        --t_deep_depth;
        if (t_deep_depth == 0) deep_drain();
    } else {
        U* q = new U(std::move(*p));
        p->~U();
        deep_park(q, [](void* x) { delete static_cast<U*>(x); });
    }
}
template<class T> struct DeepAlloc {
    using value_type = T;
    DeepAlloc() noexcept = default;
    template<class U> DeepAlloc(const DeepAlloc<U>&) noexcept {}
    T* allocate(std::size_t n) { return std::allocator<T>().allocate(n); }
    void deallocate(T* p, std::size_t n) noexcept { std::allocator<T>().deallocate(p, n); }
    template<class U, class... A> void construct(U* p, A&&... a) { ::new ((void*)p) U(std::forward<A>(a)...); }
    template<class U> void destroy(U* p) { deep_destroy(p); }
    template<class U> bool operator==(const DeepAlloc<U>&) const noexcept { return true; }
    template<class U> bool operator!=(const DeepAlloc<U>&) const noexcept { return false; }
};
template<class T, class... A> inline std::shared_ptr<T> make_deep(A&&... a) {
    return std::allocate_shared<T>(DeepAlloc<T>(), std::forward<A>(a)...);
}

// Register a container where it is created (exactly once per object).
void track_list(const std::shared_ptr<List>& p);
void track_map(const std::shared_ptr<Map>& p);
void track_iter(const std::shared_ptr<IterPair>& p);
void track_gen(const std::shared_ptr<GenState>& p);

// Queued finalizers or a due collection: checked at every instruction.
extern std::atomic<bool> g_pending;
void safe_point_slow(VirtualMachine& vm);
inline void safe_point(VirtualMachine& vm) {
    if (g_pending.load(std::memory_order_relaxed)) safe_point_slow(vm);
}

// The fields of an instance whose class defines __del__ are owned through
// this deleter: when the last reference goes they move to a new map that
// waits for __del__ at the next safe point.
struct FinalDeleter {
    std::string cls;
    bool finalized = false;
    void operator()(Map* m) const;
};
std::shared_ptr<Map> new_finalizable_map(const std::string& cls);

long collect(VirtualMachine& vm, int generation = 2);
void set_enabled(bool on);
bool is_enabled();
void set_threshold(int gen, long v);
long threshold(int gen);
long long live_objects();          // registered containers still alive
extern bool g_shutdown;            // VM teardown: no finalizer, no collection

struct Stats {
    long long collections[3] = {0, 0, 0};
    long long collected = 0;       // unreachable containers freed
    long long uncollectable = 0;   // kept because a finalizer resurrected them
    long long finalized = 0;
    long long gen_count[3] = {0, 0, 0};
};
Stats stats();

} // namespace vmgc
} // namespace nython::vm
