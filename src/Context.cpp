#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wshadow"

#include "Lexer.hpp"
#include "Except.hpp"
#include "Context.hpp"
#include "NyGC.hpp"


using nython::lexer::Token;
using nython::exception::RuntimeError;

/// -pthread -lpthread -Wl,--no-as-needed
namespace nython{
namespace kernel{

// A scope is born with one reference, its creator's (NyGC.hpp): the call
// that runs in it (CtxReaper), the class or namespace body, the closure made
// from it. The creator releases it; whatever else still refers to it - a
// child scope's parent link, a function defined in it, an instance's fields
// - holds its own counted reference.
Context::Context(Runnable* runner, const std::string& name, Collectable* self, Collectable* klass, Context* parent): Container(runner, Type::CONTEXT), name{name},
self{self}, klass{klass}, parent{parent}, inFunction{},inClass{},inNameSpace{},inBlock{}, inModule{} {
    gc_rc = 1;
    if (this->parent) nygc::incref(this->parent);
    nygc::track(this);
}

Context::~Context(){
    Context* p = parent;
    parent = nullptr;
    if (p) nygc::decref(p);
    // a scope over a dict's map (exec(src, ns), round 77): the map is the
    // dict's, not freed here
    if (Collectable* o = ns_owner) { container = nullptr; ns_owner = nullptr; nygc::decref(o); }
}

void Context::gc_traverse(nython::gc::GcVisitFn visit, void* arg) {
    if (ns_owner) visit(ns_owner, arg);          // its variables are the dict's (round 77)
    else Container::gc_traverse(visit, arg);
    if (parent) visit(parent, arg);
}

void Context::gc_clear() {
    if (Collectable* o = ns_owner) { container = nullptr; ns_owner = nullptr; nygc::decref(o); }
    else Container::gc_clear();
    Context* p = parent;
    parent = nullptr;
    if (p) nygc::decref(p);
}

Context& Context::operator=(Context&& ctx){
    if(this!=&ctx){
        name        = std::move(ctx.name);
        Context* old_parent = parent;
        parent      = ctx.parent;
        ctx.parent  = nullptr;
        if (old_parent) nygc::decref(old_parent);
        self        = std::move(ctx.self);
        klass       = std::move(ctx.klass);
        runner      = std::move(ctx.runner);
        /// are we in a function or in a class or in a name space or in  a block
        inBlock     = std::move(ctx.inBlock);
        inFunction  = std::move(ctx.inFunction);
        inClass     = std::move(ctx.inClass);
        inNameSpace = std::move(ctx.inNameSpace);
        inModule    = std::move(ctx.inModule);
    }
    return *this;
}

Context* Context::makeChildContext(const std::string& name) {
    return new Context(runner, name, self, klass, this);
}

Context& Context::ancestor(int distance) {
    auto context = this;
    for (int i = 0; i < distance; i++) {
        context = context->parent;
    }

    return *context;
}

void Context::set(const Value& name, Value value) {
    if (contains(name)) {
        assign(name, value);
        return;
    }
    if (parent) {
        parent->set(name, value);
        return;
    }
    Token token = name.token;
    throw RuntimeError(token.location(), "Undefined variable \'" + token.value + "\'.");
}

void Context::setAt(int distance, const Value& name, Value value) {
    ancestor(distance).write(name, value);
}

Value Context::get(const Value& name) {
    // try to retrieve the value referred to by name
    bool ok;
    auto value = find(name, &ok);

    // if a value exists, return it
    if (ok) {
        return value->second;
    }

    // if no value has been found yet, recursively look it up in the enclosing scope
    if (parent) {
        return parent->get(name);
    }

    // if it still has not been found, the variable doesn't exist
    Token token = name.token;
    throw RuntimeError(token.location(), "Undefined variable \'" + token.value + "\'.");
}

Value Context::getAt(int distance, const Value& name) {
    Value result;
    ancestor(distance).read(name, &result);
    return result;
}

void Context::define(const Value &name, Value value) {
    assign(name, value);
}

bool Context::has(const Value& name) {
    bool ok;
    find(name, &ok);
    if(!ok && parent) return parent->has(name);
    return ok;
}

bool Context::has(const Value& name,Value* obj) {
    bool ok;
    auto it = find(name, &ok);
    if(ok) *obj = it->second;
    if(!ok && parent) return parent->has(name, obj);
    return ok;
}

Object* Context::getParent() {
    return (Object*)parent;
}

void Context::setParent(Object* parent) {
    Context* np = (Context*)parent;
    if (np) nygc::incref(np);
    Context* old = this->parent;
    this->parent = np;
    if (old) nygc::decref(old);
}


}
}



#pragma GCC diagnostic pop
