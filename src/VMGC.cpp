// VMGC.cpp - the VM's cycle collector and finalizer queue (include/VMGC.hpp).
#include "VirtualMachine.hpp"

#include <deque>
#include <limits>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace nython::vm::vmgc {

std::atomic<bool> g_pending{false};
bool g_shutdown = false;

namespace {

enum Kind : uint8_t { K_LIST, K_MAP, K_ITER, K_GEN };
struct Entry {
    std::weak_ptr<void> w;
    void* raw;
    Kind k;
};

// Never destroyed: containers die during process exit too.
std::vector<Entry>& gen(int g) {
    static auto* gens = new std::vector<Entry>[3];
    return gens[g];
}
std::deque<std::pair<std::string, std::shared_ptr<Map>>>& final_queue() {
    static auto* q = new std::deque<std::pair<std::string, std::shared_ptr<Map>>>();
    return *q;
}

long counts[3] = {0, 0, 0};
long thresholds[3] = {2000, 10, 10};
bool enabled = true;
bool collecting = false;
bool in_safe_point = false;
long long long_lived_total = 0, long_lived_pending = 0;
Stats st;

void note_new() {
    if (++counts[0] > thresholds[0] && enabled && !collecting)
        g_pending.store(true, std::memory_order_relaxed);
}

// ── traversal ───────────────────────────────────────────────────────────────
template<class F> inline void visit_val(const VMVal& x, F& f) {
    if (x.list) f((void*)x.list.get());
    if (x.map) f((void*)x.map.get());
    if (x.iter) f((void*)x.iter.get());
    if (x.gen) f((void*)x.gen.get());
    if (x.closure_env) f((void*)x.closure_env.get());
}
// The objects a stored dict key names (an object key, or object keys inside
// a tuple key), from the VM's key table.
template<class F> void vm_visit_key_objects(const std::string& key, std::unordered_map<std::string, VMVal>& tab, F& f) {
    if (key.size() < 2 || key[0] != '\x01') return;
    if (key[1] == 'o') {
        auto it = tab.find(key.substr(2));
        if (it != tab.end()) visit_val(it->second, f);
    } else if (key[1] == 't') {
        for (auto& part : nypy::key_tuple_parts(key)) vm_visit_key_objects(part, tab, f);
    }
}
template<class F> void traverse(const Entry& e, F& f) {
    switch (e.k) {
        case K_LIST: for (auto& v : *static_cast<List*>(e.raw)) visit_val(v, f); break;
        case K_MAP: for (auto& kv : *static_cast<Map*>(e.raw)) visit_val(kv.second, f); break;
        case K_ITER: for (auto& v : static_cast<IterPair*>(e.raw)->second) visit_val(v, f); break;
        case K_GEN: {
            auto* g = static_cast<GenState*>(e.raw);
            for (auto& kv : g->locals) visit_val(kv.second, f);
            for (auto& v : g->saved_stack) visit_val(v, f);
            if (g->self_val) visit_val(*g->self_val, f);
            if (g->closure) f((void*)g->closure.get());
            break;
        }
    }
}
// Drops what the object holds (only for unreachable objects).
void clear(const Entry& e) {
    switch (e.k) {
        case K_LIST: { List dead; dead.swap(*static_cast<List*>(e.raw)); break; }
        case K_MAP: { Map dead; dead.swap(*static_cast<Map*>(e.raw)); break; }
        case K_ITER: { List dead; dead.swap(static_cast<IterPair*>(e.raw)->second); break; }
        case K_GEN: {
            auto* g = static_cast<GenState*>(e.raw);
            Map dl; dl.swap(g->locals);
            List ds; ds.swap(g->saved_stack);
            std::optional<VMVal> dself; dself.swap(g->self_val);
            std::shared_ptr<Map> dc; dc.swap(g->closure);
            g->done = true;
            break;
        }
    }
}

// Pointer -> candidate index, open addressing (std::unordered_map allocated
// a node per candidate and dominated a collection of 50,000 instances).
struct PtrIndex {
    std::vector<std::pair<void*, size_t>> slots;
    size_t mask = 0;
    explicit PtrIndex(size_t n) {
        size_t cap = 16;
        while (cap < n * 2) cap <<= 1;
        slots.assign(cap, {nullptr, 0});
        mask = cap - 1;
    }
    static size_t hash(void* p) {
        uint64_t x = (uint64_t)(uintptr_t)p;
        x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33;
        return (size_t)x;
    }
    void put(void* p, size_t i) {
        size_t h = hash(p) & mask;
        while (slots[h].first) h = (h + 1) & mask;
        slots[h] = {p, i};
    }
    // SIZE_MAX when absent.
    size_t find(void* p) const {
        size_t h = hash(p) & mask;
        while (slots[h].first) {
            if (slots[h].first == p) return slots[h].second;
            h = (h + 1) & mask;
        }
        return (size_t)-1;
    }
};

long collect_impl(VirtualMachine& vm, int g) {
    if (collecting) return 0;
    collecting = true;
    st.collections[g]++;
    std::vector<Entry> cand;
    for (int i = 0; i <= g; i++) {
        auto& v = gen(i);
        for (auto& e : v) cand.push_back(std::move(e));
        v.clear();
        counts[i] = 0;
    }
    if (g + 1 < 3) counts[g + 1]++;
    // Lock the live ones (this reference is subtracted below); the dead
    // ones' entries go, releasing their control blocks.
    std::vector<std::shared_ptr<void>> alive;
    std::vector<Entry> ents;
    alive.reserve(cand.size());
    ents.reserve(cand.size());
    for (auto& e : cand) {
        auto sp = e.w.lock();
        if (!sp) continue;
        alive.push_back(std::move(sp));
        ents.push_back(std::move(e));
    }
    cand.clear();
    cand.shrink_to_fit();
    size_t n = alive.size();
    PtrIndex idx(n);
    for (size_t i = 0; i < n; i++) idx.put(ents[i].raw, i);
    std::vector<int64_t> refs(n);
    for (size_t i = 0; i < n; i++) refs[i] = (int64_t)alive[i].use_count() - 1;
    // Trial deletion: subtract the references the candidates hold on each other.
    auto subtract = [&](void* p) {
        size_t k = idx.find(p);
        if (k != (size_t)-1) refs[k]--;
    };
    for (size_t i = 0; i < n; i++) traverse(ents[i], subtract);
    // Objects used as dict keys (round 76; NyGC.hpp, KeyTable, for the
    // interpreter): the table vm_key_objs() keeps them by, in a full
    // collection, counts as the dicts' references - discounted here, and
    // followed from the dicts reached below - and loses the ones found
    // unreachable. It kept every object ever used as a key alive.
    auto& keytab = vm_key_objs();
    const bool keys = g == 2 && !keytab.empty();
    if (keys) for (auto& kv : keytab) visit_val(kv.second, subtract);
    auto key_edges = [&](const Entry& e, auto& f) {
        if (!keys || e.k != K_MAP) return;
        for (auto& kv : *static_cast<Map*>(e.raw)) vm_visit_key_objects(kv.first, keytab, f);
    };
    // Reachable from outside.
    std::vector<char> reach(n, 0);
    std::vector<size_t> work;
    for (size_t i = 0; i < n; i++) if (refs[i] > 0) { reach[i] = 1; work.push_back(i); }
    auto mark = [&](void* p) {
        size_t k = idx.find(p);
        if (k != (size_t)-1 && !reach[k]) { reach[k] = 1; work.push_back(k); }
    };
    while (!work.empty()) {
        size_t i = work.back();
        work.pop_back();
        traverse(ents[i], mark);
        key_edges(ents[i], mark);
    }
    int older = g + 1 < 3 ? g + 1 : g;
    std::vector<size_t> garbage;
    long long promoted = 0;
    for (size_t i = 0; i < n; i++) {
        if (reach[i]) { gen(older).push_back(ents[i]); promoted++; }
        else garbage.push_back(i);
    }
    if (g == 1) long_lived_pending += promoted;
    if (g == 2) { long_lived_pending = 0; long_lived_total = (long long)gen(2).size(); }
    long found = (long)garbage.size();
    if (found == 0) { collecting = false; return 0; }

    // Finalizers first (PEP 442), on the objects themselves.
    bool ran = false;
    for (size_t i : garbage) {
        if (ents[i].k == K_GEN) {
            // A suspended generator: closed first (its finally blocks run).
            if (vm.gc_close_generator(*static_cast<GenState*>(ents[i].raw))) { st.finalized++; ran = true; }
            continue;
        }
        if (ents[i].k != K_MAP) continue;
        auto* d = std::get_deleter<FinalDeleter>(alive[i]);
        if (!d || d->finalized) continue;
        d->finalized = true;
        st.finalized++;
        ran = true;
        vm.gc_run_finalizer(d->cls, std::static_pointer_cast<Map>(alive[i]));
    }
    if (ran) {
        // Resurrected? Recount among the garbage alone.
        std::unordered_map<void*, size_t> gidx;
        for (size_t k = 0; k < garbage.size(); k++) gidx.emplace(ents[garbage[k]].raw, k);
        std::vector<int64_t> r2(garbage.size());
        for (size_t k = 0; k < garbage.size(); k++) r2[k] = (int64_t)alive[garbage[k]].use_count() - 1;
        auto sub2 = [&](void* p) { auto it = gidx.find(p); if (it != gidx.end()) r2[it->second]--; };
        for (size_t k = 0; k < garbage.size(); k++) traverse(ents[garbage[k]], sub2);
        if (keys) for (auto& kv : keytab) visit_val(kv.second, sub2);
        bool resurrected = false;
        for (auto v : r2) if (v > 0) { resurrected = true; break; }
        if (resurrected) {
            for (size_t i : garbage) gen(2).push_back(ents[i]);
            st.uncollectable += found;
            collecting = false;
            return 0;
        }
    }
    if (keys) {
        // `alive` still holds the garbage: dropping an entry frees nothing yet.
        std::unordered_set<void*> dead;
        for (size_t i : garbage) dead.insert(ents[i].raw);
        std::vector<VMVal> dropped;
        for (auto it = keytab.begin(); it != keytab.end();) {
            const VMVal& v = it->second;
            void* id = v.map ? (void*)v.map.get() : v.gen ? (void*)v.gen.get() : v.iter ? (void*)v.iter.get() : nullptr;
            bool gone = (id && dead.count(id)) || (!id && v.closure_env && dead.count(v.closure_env.get()));
            if (gone) { dropped.push_back(v); it = keytab.erase(it); }
            else ++it;
        }
    }
    for (size_t i : garbage) clear(ents[i]);
    st.collected += found;
    // Dropping `alive` frees the garbage.
    alive.clear();
    collecting = false;
    return found;
}

size_t heap_after_full = 0;
size_t heap_factor = 2;

void collect_due(VirtualMachine& vm) {
    // A full collection also when the heap has doubled since the last one
    // (NyGC.cpp explains why object counts alone are not enough; the factor
    // backs off to 4 and 8 while collections find little).
    size_t h = nygc::heap_bytes();
    if (h && !heap_after_full) heap_after_full = h;
    if (h > heap_factor * heap_after_full && h > heap_after_full + ((size_t)16 << 20)) {
        size_t before = gen(0).size() + gen(1).size() + gen(2).size();
        long n = collect_impl(vm, 2);
        heap_factor = ((size_t)n * 8 < before) ? std::min<size_t>(heap_factor * 2, 8) : 2;
        nygc::trim_heap();
        heap_after_full = nygc::heap_bytes();
        return;
    }
    for (int g = 2; g >= 0; g--) {
        if (counts[g] <= thresholds[g]) continue;
        if (g == 2 && long_lived_pending < long_lived_total / 4) continue;
        collect_impl(vm, g);
        if (g == 2) { nygc::trim_heap(); heap_after_full = nygc::heap_bytes(); }
        break;
    }
}

std::mutex& queue_mutex() { static auto* m = new std::mutex(); return *m; }

template<class P> void track_any(const std::shared_ptr<P>& p, Kind k) {
    if (!p) return;
    gen(0).push_back(Entry{std::weak_ptr<void>(p), (void*)p.get(), k});
    note_new();
}

} // namespace

namespace {
thread_local std::vector<std::pair<void*, void (*)(void*)>>* t_parked = nullptr;
}
void deep_park(void* obj, void (*destroy)(void*)) {
    if (!t_parked) t_parked = new std::vector<std::pair<void*, void (*)(void*)>>();
    t_parked->emplace_back(obj, destroy);
}
void deep_drain() {
    if (!t_parked || t_parked->empty()) return;
    ++t_deep_depth;
    while (!t_parked->empty()) {
        auto item = t_parked->back();
        t_parked->pop_back();
        item.second(item.first);
    }
    --t_deep_depth;
}

void track_list(const std::shared_ptr<List>& p) { track_any(p, K_LIST); }
void track_map(const std::shared_ptr<Map>& p) { track_any(p, K_MAP); }
void track_iter(const std::shared_ptr<IterPair>& p) { track_any(p, K_ITER); }
void track_gen(const std::shared_ptr<GenState>& p) { track_any(p, K_GEN); }

void FinalDeleter::operator()(Map* m) const {
    if (finalized || g_shutdown) {
        deep_destroy(m);
        ::operator delete(static_cast<void*>(m));
        return;
    }
    // Alive again under a new identity, for __del__ at the next safe point.
    auto fresh = make_deep<Map>(std::move(*m));
    delete m;
    {
        // The last reference can be dropped by a thread in a blocking wait
        // (a runtime box), without the GIL: the queue has its own lock and
        // the new map is registered by the thread that runs __del__.
        std::lock_guard<std::mutex> l(queue_mutex());
        final_queue().emplace_back(cls, std::move(fresh));
    }
    g_pending.store(true, std::memory_order_release);
}

std::shared_ptr<Map> new_finalizable_map(const std::string& cls) {
    std::shared_ptr<Map> p(new Map(), FinalDeleter{cls, false});
    track_map(p);
    return p;
}

void safe_point_slow(VirtualMachine& vm) {
    if (in_safe_point || collecting || g_shutdown) return;
    in_safe_point = true;
    g_pending.store(false, std::memory_order_relaxed);
    for (;;) {
        std::pair<std::string, std::shared_ptr<Map>> item;
        {
            std::lock_guard<std::mutex> l(queue_mutex());
            if (final_queue().empty()) break;
            item = std::move(final_queue().front());
            final_queue().pop_front();
        }
        track_map(item.second);
        st.finalized++;
        vm.gc_run_finalizer(item.first, item.second);
    }
    if (enabled) collect_due(vm);
    in_safe_point = false;
    std::lock_guard<std::mutex> l(queue_mutex());
    if (!final_queue().empty()) g_pending.store(true, std::memory_order_relaxed);
}

long collect(VirtualMachine& vm, int generation) {
    if (generation < 0) generation = 0;
    if (generation > 2) generation = 2;
    if (collecting) return 0;
    if (!in_safe_point) safe_point_slow(vm);
    long n = collect_impl(vm, generation);
    if (generation == 2) { nygc::trim_heap(); heap_after_full = nygc::heap_bytes(); }
    return n;
}

void set_enabled(bool on) {
    enabled = on;
    if (on && counts[0] > thresholds[0]) g_pending.store(true, std::memory_order_relaxed);
}
bool is_enabled() { return enabled; }
void set_threshold(int g, long v) { if (g >= 0 && g < 3) thresholds[g] = v < 1 ? 1 : v; }
long threshold(int g) { return g >= 0 && g < 3 ? thresholds[g] : 0; }

long long live_objects() {
    long long n = 0;
    for (int g = 0; g < 3; g++) for (auto& e : gen(g)) if (!e.w.expired()) n++;
    return n;
}

Stats stats() {
    Stats s = st;
    for (int g = 0; g < 3; g++) s.gen_count[g] = (long long)gen(g).size();
    return s;
}

} // namespace nython::vm::vmgc
