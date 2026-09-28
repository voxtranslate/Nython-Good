#pragma once
// NyHeap.hpp - the interpreter's reference-counted heap payloads.
//
// A string, a function, a bound method and an instance are USERDATA values:
// `value.p` points at an identity the executor's side tables are keyed by
// (func_names, instance_to_class, closure_contexts, string_ptrs_...), and
// `value.o` at the object below that owns it (NyGC.hpp). The identity is a
// member of the owning object, so it stays valid exactly as long as the
// object does, and the object's destructor removes every side-table entry
// keyed by it: a new object allocated at the same address never inherits a
// dead one's metadata.
//
// The definitions that need the whole executor are in NyHeapImpl.hpp,
// included at the end of NythonExecutor.hpp.
#include <string>
#include "Collectable.hpp"
#include "Value.hpp"
#include "Context.hpp"
#include "NyGC.hpp"

struct NythonExecutor;

namespace nyheap {

using nython::gc::Collectable;
using nython::gc::GcVisitFn;
using nython::kernel::Context;
using nython::kernel::Value;

// Whether an executor still exists: an object that outlives the executor
// that made it (a literal interned in an AST freed later) must not touch
// its side tables.
inline bool executor_alive(const NythonExecutor* e);
inline void executor_born(const NythonExecutor* e);
inline void executor_died(const NythonExecutor* e);

// A string: value.p == &s. Untracked (it refers to nothing).
struct Str final : Collectable {
    std::string s;
    NythonExecutor* E;
    Str(NythonExecutor* e, const std::string& x);
    Str(NythonExecutor* e, std::string&& x);
    ~Str() override;
};

// A function or lambda: value.p == &id. Holds the scope it closes over and
// the default values evaluated when its def ran (fn_defaults_val_).
struct Func final : Collectable {
    int64_t id;
    NythonExecutor* E;
    Context* scope = nullptr;           // counted
    Func(NythonExecutor* e, int64_t i);
    ~Func() override;
    void setScope(Context* c) {
        if (c) nygc::incref(c);
        Context* old = scope;
        scope = c;
        if (old) nygc::decref(old);
    }
    void gc_traverse(GcVisitFn visit, void* arg) override;
    void gc_clear() override;
};

// A method read off an instance as a value: value.p == &tag. Holds the
// function and the instance.
struct Bound final : Collectable {
    std::string tag;
    NythonExecutor* E;
    Value fn;                            // counted
    Value self;                          // counted
    void* key_fn = nullptr;              // its bound_cache_ key
    void* key_self = nullptr;
    Bound(NythonExecutor* e, const std::string& t);
    ~Bound() override;
    void gc_traverse(GcVisitFn visit, void* arg) override;
    void gc_clear() override;
};

// An instance of a user class: value.p == &tag. Its fields live in `props`
// (instance_properties).
struct Inst final : Collectable {
    std::string tag;
    NythonExecutor* E;
    Context* props = nullptr;           // counted
    void* cls = nullptr;                // the class node (immortal)
    Inst(NythonExecutor* e, const std::string& t, void* class_node);
    ~Inst() override;
    void gc_traverse(GcVisitFn visit, void* arg) override;
    void gc_clear() override;
    bool gc_has_finalizer() override;
    void gc_finalize() override;
};

// weakref(obj): a callable that gives the instance back while it is alive
// and none afterwards. value.p == &tag, which func_names lists as the
// builtin "__weakref__:<n>". Only instances can be weakly referenced (as in
// Python, not a list, dict, number or string).
struct Weak final : Collectable {
    std::string tag;
    NythonExecutor* E;
    int64_t id;
    Collectable* target = nullptr;      // not counted; cleared when it dies
    void* payload = nullptr;
    Weak(NythonExecutor* e, int64_t i);
    ~Weak() override;
};
// A target died: its weak references now give none.
inline void weak_target_died(Collectable* target);
inline void weak_register(Weak* w);          // w->target is set

// A value that holds `owner` and shows `payload` (a USERDATA value).
inline Value userValue(Collectable* owner, void* payload) {
    Value v;
    v.type = nython::kernel::ValueType::USERDATA;
    v.value.p = payload;
    v.value.own(owner);
    return v;
}

} // namespace nyheap
