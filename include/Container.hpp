#ifndef __CONTAINER__HPP
#define __CONTAINER__HPP

#include "Type.hpp"
#include "Value.hpp"
#include <functional>
#include <unordered_map>
#include "NyOrderedMap.hpp"
#include "Location.hpp"
#include "Collectable.hpp"

namespace nython::kernel {

using gc::Collectable;
using lexer::Location;

// Underlying type of every Value which has its own
// Value container (e.g. Object, Function, Class). Insertion-ordered, so a
// dict iterates in the order its keys were added (as in Python).
using ContainerType = nypy::OrderedMap<Value>;
class Container: public Collectable {
public:
    // A copy owns its own map (a shared one would be freed twice).
    Container(const Container& o);
    Container& operator=(const Container& o);


public:
    Location location;
    ContainerType* container = nullptr;

public:

    Container(Type type_arg, uint32_t initial_capacity = 4);
    Container(Runnable* runner_arg, Type type_arg, uint32_t initial_capacity = 4);
    ~Container() override;
    void clean();
    void copy_container_from(const Container* other);

    std::string toString();
    bool read(Value key, Value* result);              // reads a Value from the container
    Value read_or(Value key, Value fallback = NONE_VALUE); // reads a Value from the container or returns fall-back
    bool contains(Value key);                         // check whether the container contains some key
    int size() const;                                       // returns amount of keys inside container
    bool erase(Value key);                            // erases a key from the container, returns true on success
    void write(Value key, Value value);               // insert or assign to some key
    bool assign(Value key, Value value);              // assign to some key, returns false if key did not exist
    ContainerType::iterator find(const Value& value, bool* ok); // find if value is inside the container or not

    // The values it holds are counted references (NyGC.hpp).
    void gc_traverse(nython::gc::GcVisitFn visit, void* arg) override;
    void gc_clear() override;

    // Access the internal container data structure via a callback function
    void access_container(std::function<void(ContainerType*)> cb);
    void access_container_shared(std::function<void(ContainerType*)> cb);

};

}///nython

#endif // __CONTAINER__HPP


