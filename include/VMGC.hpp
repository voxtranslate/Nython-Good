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
// crashed the VM when it was dropped. A VMVal's container pointers are
// DeepPtrs: when one holds the last reference and the destructors are
// already nested deeply, the object is parked and freed by the outermost
// release, iteratively.
void release_deep(std::shared_ptr<void>&& p);
template<class T> struct DeepPtr : std::shared_ptr<T> {
    using Base = std::shared_ptr<T>;
    using Base::Base;
    DeepPtr() noexcept = default;
    DeepPtr(const Base& b) noexcept : Base(b) {}
    DeepPtr(Base&& b) noexcept : Base(std::move(b)) {}
    DeepPtr(const DeepPtr&) noexcept = default;
    DeepPtr(DeepPtr&&) noexcept = default;
    DeepPtr& operator=(const DeepPtr&) noexcept = default;
    DeepPtr& operator=(DeepPtr&&) noexcept = default;
    DeepPtr& operator=(const Base& b) noexcept { Base::operator=(b); return *this; }
    DeepPtr& operator=(Base&& b) noexcept { Base::operator=(std::move(b)); return *this; }
    DeepPtr& operator=(std::nullptr_t) noexcept { Base::reset(); return *this; }
    ~DeepPtr() {
        if (this->get() && this->use_count() == 1)
            release_deep(std::shared_ptr<void>(std::move(static_cast<Base&>(*this))));
    }
};

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
