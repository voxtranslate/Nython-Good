#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wshadow"
#include <sstream>
#include "Object.hpp"
#include "Container.hpp"
#include "Collectable.hpp"
#include "NyGC.hpp"
#include <utility>
#include <functional>
// ^ explicit: libstdc++ supplies these transitively, MinGW does not.

namespace nython {
namespace kernel {

// ── Maps kept for reuse (round 81) ──────────────────────────────────────────
// Every call makes a scope and every list or dict literal a container, each
// with a map whose first chunk of slots is allocated on its first entry and
// freed with it. Emptied maps that never grew past that chunk are kept here
// (per thread, a few dozen) and handed to the next container, storage and
// all: two allocations and two frees less per call. Emptying one destroys
// its entries in order, as deleting it did. The state is trivially
// destructible; the reaper frees what is kept when the thread ends, and a
// map released after that is deleted as before.
namespace {
struct MapPool {
    static constexpr int kCap = 64;
    ContainerType* maps[kCap];
    int n;
    bool dead;
};
thread_local MapPool t_map_pool;   // zero-initialized
struct MapPoolReaper {
    bool armed = false;
    ~MapPoolReaper() {
        MapPool& p = t_map_pool;
        p.dead = true;
        while (p.n > 0) delete p.maps[--p.n];
    }
};
thread_local MapPoolReaper t_map_pool_reaper;
ContainerType* acquire_map() {
    MapPool& p = t_map_pool;
    if (p.n > 0) return p.maps[--p.n];
    return new ContainerType();
}
}
// Not static: Container's destructor and the executor's scope switches use it.
void release_container_map(ContainerType* m) {
    if (!m) return;
    MapPool& p = t_map_pool;
    if (!p.dead && p.n < MapPool::kCap && m->pool_small()) {
        t_map_pool_reaper.armed = true;   // (its first use in this thread registers its destructor)
        m->clear_keep();
        if (!p.dead && p.n < MapPool::kCap) { p.maps[p.n++] = m; return; }
    }
    delete m;
}

Container::Container(Type type_arg, uint32_t initial_capacity): Collectable(type_arg), location{} {
    gc_flags |= nygc::F_KCONT;   // round 81: NythonExecutor::contOf
    this->container = acquire_map();   // (round 81: from the pool when one is kept)
    this->container->reserve(initial_capacity);
}

Container::Container(Runnable* runner, Type type, uint32_t initial_capacity): Collectable(runner,type), location{} {
    gc_flags |= nygc::F_KCONT;   // round 81
    this->container = acquire_map();
    this->container->reserve(initial_capacity);
}

Container::Container(const Container& o) : Collectable(o), location{o.location} {
    gc_flags |= nygc::F_KCONT;   // round 81
    this->container = o.container ? new ContainerType(*o.container) : nullptr;
}

Container& Container::operator=(const Container& o) {
    if (this != &o) {
        Collectable::operator=(o);
        location = o.location;
        ContainerType* fresh = o.container ? new ContainerType(*o.container) : nullptr;
        ContainerType* old = this->container;
        this->container = fresh;
        delete old;
    }
    return *this;
}

// The map is this object's: its values are released with it (they are
// counted references). It used to be leaked on purpose, because nothing
// ever freed a container and a shallow copy could have shared the map.
Container::~Container() {
    ContainerType* m = this->container;
    this->container = nullptr;
    release_container_map(m);   // round 81: kept for reuse when small (deleted otherwise)
}

void Container::gc_traverse(nython::gc::GcVisitFn visit, void* arg) {
    if (!this->container) return;
    for (auto& kv : *this->container) {
        if (kv.second.value.o) visit(kv.second.value.o, arg);
        // A full collection's reachability pass: the objects this dict's
        // keys name are reached through it (NyGC.hpp, KeyTable).
        if (nygc::g_key_edges) nygc::visit_key_objects(kv.first, visit, arg);
    }
}

void Container::gc_clear() {
    if (!this->container) return;
    // Swap the entries out first: releasing them can run destructors that
    // look at this (now empty, still valid) map.
    ContainerType dead;
    dead.swap(*this->container);
}

std::string Container::toString() {
    std::stringstream ret;
    std::hex(ret);
    ret << this;
    return std::string("< container object at ").append(ret.str()).append(" of type ").append(TypeToString(type)).append(">");
}

void Container::copy_container_from(const Container* other) {
  if(!this->container) return;
  this->container->insert(other->container->begin(), other->container->end());
}

bool Container::read(Value key, Value* result) {
  if(!this->container) {
     result = nullptr;
     return false;
  }
  if(this->container->count(key.toString()) == 0) return false;
  *result = (* this->container)[key.toString()];
  return true;
}

Value Container::read_or(Value key, Value fallback) {
  if(!this->container) return fallback;
  if (this->container->count(key.toString()) == 1) {
    return (* this->container)[key.toString()];
  }
  return fallback;
}

bool Container::contains(Value key) {
  if(!this->container) return false;
  return this->container->count(key.toString());
}

int Container::size() const {
  if(!this->container) return -1;
  return this->container->size();
}

bool Container::erase(Value key) {
  if(!this->container) return false;
  return this->container->erase(key.toString()) > 0;
}

void Container::write(Value key, Value value) {
  if(!this->container) return;
  (* this->container)[key.toString()] = value;
}

bool Container::assign(Value key, Value value) {
  if(!this->container) return false;
  if(this->container->count(key.toString()) == 0) return false;
  this->container->insert(std::make_pair(key.toString(), value));
  return true;
}

void Container::access_container(std::function<void(ContainerType*)> cb) {
  if(!this->container) return;
  cb(this->container);
}

void Container::access_container_shared(std::function<void(ContainerType*)> cb) {
  if(!this->container) return;
  cb(this->container);
}

void Container::clean() {
  Collectable::clean();
  if(this->container) {
    for(auto& it: *container) {
        Value second = it.second;
        if(second.isCollectable()) {
            second->clean();
        }
    }
    delete this->container;
    this->container = nullptr;
  }
}

ContainerType::iterator Container::find(const Value& value, bool* ok) {
    const std::string name = Value(value).getName();
    ContainerType::iterator it = this->container->find(name);
    if(it!=this->container->end()) {
        *ok = true;
    } else *ok = false;
    return it;
}

}
}


#pragma GCC diagnostic pop
