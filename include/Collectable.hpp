#ifndef __COLLECTABLE__HPP
#define __COLLECTABLE__HPP

#include <string>
#include <cstdint>
#include "Type.hpp"
#include "Runnable.hpp"
#include "Definitions.hpp"


using nython::kernel::Type;
using nython::kernel::Class;
using nython::kernel::Object;

namespace nython::gc {

// Heap objects currently alive (lists, maps, instances, call frames...):
// created minus destroyed. --profile attributes the growth per function to
// find what makes memory climb.
inline long long& collectables_created() { static long long n = 0; return n; }

class Collectable;
// A traversal callback: called once per counted reference an object holds.
typedef void (*GcVisitFn)(Collectable* child, void* arg);

// Metadata which is stores in every heap Value
//
// Every interpreter heap object is reference counted (NyGC.hpp): a Value
// that holds one counts a reference (TValue::o), and so do the handful of
// internal owners listed in GC_NOTES.md (a scope's parent, a closure's
// scope, an instance's field scope, a call in progress). The object is
// destroyed when the count returns to zero. Objects that can hold references
// to other objects are also "tracked" - linked into a generation list - so
// the cycle collector (src/NyGC.cpp) can find reference cycles among them.
class Collectable {
public:
    // Copying an object never copies its place in the heap: the copy starts
    // with no references and is not tracked.
    Collectable(const Collectable& o) : type{o.type}, marked{false}, runner{o.runner} { collectables_created()++; }
    Collectable& operator=(const Collectable& o) { type = o.type; runner = o.runner; return *this; }


protected:
    Type  type{};
    bool marked = false;   // set by the GC to mark reachable Values
    Runnable* runner = nullptr;

public:
    // ── reference counting and cycle collection (NyGC.hpp) ──────────────
    uint32_t gc_rc = 0;          // counted references
    uint16_t gc_flags = 0;       // nygc::F_* bits
    uint8_t  gc_gen = 0;         // generation, when tracked
    uint8_t  gc_counted = 1;     // counts toward collectables_created()
    Collectable* gc_prev = nullptr;
    Collectable* gc_next = nullptr;
    int64_t  gc_refs = 0;        // scratch during a collection

    // Report each counted reference this object holds (to a Collectable).
    // Reporting fewer than it holds is safe (the target just looks
    // externally referenced); reporting one it does not hold is not.
    virtual void gc_traverse(GcVisitFn, void*) {}
    // Drop the references this object holds, to break a cycle it is part of.
    virtual void gc_clear() {}
    // Whether destroying this object must first run a finalizer (__del__)
    // that has not run yet, and running it.
    virtual bool gc_has_finalizer() { return false; }
    virtual void gc_finalize() {}

    Collectable(Type type_arg);
    Collectable(Runnable* runner_arg, Type type_arg);
    Runnable* getRunner() const { return runner; }
    virtual ~Collectable();

    virtual void clean();
    virtual std::string toString();
    virtual std::string typeName();

    virtual std::string getName() {
        return "";
    }

    virtual std::string shortName(){
        return "";
    }

    virtual std::string address(){
        return "";
    }

    virtual std::string qualifiedName(){
        return "";
    }

    virtual Type getType();
    virtual void setType(Type type_arg);
    virtual uint64_t id();
    virtual Object* getParent();
    virtual Class* getClass();
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Woverloaded-virtual"
    virtual bool equals(Collectable* that);
#pragma GCC diagnostic pop
    virtual bool isClass();

    bool get_gc_mark();
    void set_gc_mark();
    void clear_gc_mark();

    template<typename T>
    T* as();

};
}

namespace nygc {
using nython::gc::Collectable;
// Out of line (src/NyGC.cpp): the count reached zero.
void dealloc(Collectable* c);
inline void incref(Collectable* c) { ++c->gc_rc; }
inline void decref(Collectable* c) { if (--c->gc_rc == 0) dealloc(c); }
}


#endif // __COLLECTABLE__HPP
