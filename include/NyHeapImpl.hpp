#pragma once
// NyHeapImpl.hpp - the parts of NyHeap.hpp that need the whole executor.
// Included once, at the end of NythonExecutor.hpp.
#include <algorithm>
#include <vector>

namespace nyheap {

namespace detail {
// Never destroyed: objects released during process exit may ask.
inline std::vector<const NythonExecutor*>& live_executors() {
    static auto* v = new std::vector<const NythonExecutor*>();
    return *v;
}
}
inline bool executor_alive(const NythonExecutor* e) {
    for (auto* x : detail::live_executors()) if (x == e) return true;
    return false;
}
inline void executor_born(const NythonExecutor* e) { detail::live_executors().push_back(e); }
inline void executor_died(const NythonExecutor* e) {
    auto& v = detail::live_executors();
    v.erase(std::remove(v.begin(), v.end(), e), v.end());
}

// ── Str ──────────────────────────────────────────────────────────────────
inline Str::Str(NythonExecutor* e, const std::string& x) : Collectable(nython::kernel::Type::STRING), s(x), E(e) {
    gc_counted = 0;
    nython::gc::collectables_created()--;
    nygc::g_live_strings++;
    nygc::g_string_bytes += (long long)s.size();
}
inline Str::Str(NythonExecutor* e, std::string&& x) : Collectable(nython::kernel::Type::STRING), s(std::move(x)), E(e) {
    gc_counted = 0;
    nython::gc::collectables_created()--;
    nygc::g_live_strings++;
    nygc::g_string_bytes += (long long)s.size();
}
inline Str::~Str() {
    nygc::g_live_strings--;
    nygc::g_string_bytes -= (long long)s.size();
    if (E && executor_alive(E)) E->string_ptrs_.erase((void*)&s);
}

// ── Func ─────────────────────────────────────────────────────────────────
inline Func::Func(NythonExecutor* e, int64_t i) : Collectable(nython::kernel::Type::FUNCTION), id(i), E(e) {}
inline Func::~Func() {
    if (E && executor_alive(E)) E->forgetFunction((void*)&id);
    Context* s = scope;
    scope = nullptr;
    if (s) nygc::decref(s);
}
inline void Func::gc_traverse(GcVisitFn visit, void* arg) {
    if (scope) visit(scope, arg);
    if (E && executor_alive(E)) {
        auto it = E->fn_defaults_val_.find((void*)&id);
        if (it != E->fn_defaults_val_.end())
            for (auto& v : it->second) if (v.value.o) visit(v.value.o, arg);
        auto fa = E->func_attrs_.find((void*)&id);
        if (fa != E->func_attrs_.end())
            for (auto& kv : fa->second) if (kv.second.value.o) visit(kv.second.value.o, arg);
    }
}
inline void Func::gc_clear() {
    if (E && executor_alive(E)) {
        E->closure_contexts.erase((void*)&id);
        std::vector<Value> dead;
        auto it = E->fn_defaults_val_.find((void*)&id);
        if (it != E->fn_defaults_val_.end()) { dead.swap(it->second); E->fn_defaults_val_.erase(it); }
        std::unordered_map<std::string, Value> dead_attrs;
        auto fa = E->func_attrs_.find((void*)&id);
        if (fa != E->func_attrs_.end()) { dead_attrs.swap(fa->second); E->func_attrs_.erase(fa); }
    }
    setScope(nullptr);
}

// ── Bound ────────────────────────────────────────────────────────────────
inline Bound::Bound(NythonExecutor* e, const std::string& t) : Collectable(nython::kernel::Type::METHOD), tag(t), E(e) {}
inline Bound::~Bound() {
    if (E && executor_alive(E)) E->forgetBound(this);
}
inline void Bound::gc_traverse(GcVisitFn visit, void* arg) {
    if (fn.value.o) visit(fn.value.o, arg);
    if (self.value.o) visit(self.value.o, arg);
}
inline void Bound::gc_clear() {
    if (E && executor_alive(E)) E->closure_contexts.erase((void*)&tag);
    Value f = fn, s = self;
    fn = Value();
    self = Value();
}

// ── Inst ─────────────────────────────────────────────────────────────────
inline Inst::Inst(NythonExecutor* e, const std::string& t, void* class_node)
    : Collectable(nython::kernel::Type::INSTANCE), tag(t), E(e), cls(class_node) {}
inline Inst::~Inst() {
    if (E && executor_alive(E)) E->forgetInstance((void*)&tag);
    Context* p = props;
    props = nullptr;
    if (p) nygc::decref(p);
}
// The field scope is not tracked on its own (newInstance): its references
// are reported as the instance's.
inline void Inst::gc_traverse(GcVisitFn visit, void* arg) {
    if (props) props->gc_traverse(visit, arg);
}
inline void Inst::gc_clear() {
    if (E && executor_alive(E)) E->instance_properties.erase((void*)&tag);
    Context* p = props;
    props = nullptr;
    if (p) { p->gc_clear(); nygc::decref(p); }
}
inline bool Inst::gc_has_finalizer() {
    return E && executor_alive(E) && E->classHasFinalizer(cls);
}
inline void Inst::gc_finalize() {
    if (E && executor_alive(E)) E->runFinalizer(this);
}

// ── Weak ─────────────────────────────────────────────────────────────────
namespace detail {
inline std::unordered_map<Collectable*, std::vector<Weak*>>& weak_targets() {
    static auto* m = new std::unordered_map<Collectable*, std::vector<Weak*>>();
    return *m;
}
}
inline void weak_target_died(Collectable* target) {
    auto& m = detail::weak_targets();
    auto it = m.find(target);
    if (it == m.end()) return;
    for (Weak* w : it->second) { w->target = nullptr; w->payload = nullptr; }
    m.erase(it);
}
inline void weak_register(Weak* w) {
    w->target->gc_flags |= nygc::F_WEAKREFD;
    detail::weak_targets()[w->target].push_back(w);
}
inline Weak::Weak(NythonExecutor* e, int64_t i)
    : Collectable(nython::kernel::Type::FUNCTION), tag("__weakref__:" + std::to_string(i)), E(e), id(i) {}
inline Weak::~Weak() {
    if (target) {
        auto& m = detail::weak_targets();
        auto it = m.find(target);
        if (it != m.end()) {
            auto& v = it->second;
            v.erase(std::remove(v.begin(), v.end(), this), v.end());
            if (v.empty()) { m.erase(it); target->gc_flags &= (uint16_t)~nygc::F_WEAKREFD; }
        }
    }
    if (E && executor_alive(E)) E->forgetWeak(this);
}

} // namespace nyheap
