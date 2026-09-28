#ifndef NY_MEMBERS_HPP
#define NY_MEMBERS_HPP
// The members values of the builtin kinds answer, shared by both engines
// (round 75). Reading an attribute a value does not have raises
// AttributeError; for a string, list, dict, number ... "has" means one of the
// methods a call `x.name(...)` dispatches to, so a read of that name (a bound
// method), hasattr(x, name) and `x?.name(...)` agree with what the call does.
//
// The lists are the union of the names the two engines' method dispatch
// implements (NyStr.hpp's str_method, listMethod/list_method, dictMethod/
// call_map_method, the set helpers and the object protocol). A name listed
// here that one kind does not really implement reads as a bound method
// whose call then fails - never a spurious AttributeError on a read.
#include <cstdlib>
#include <string>
#include <unordered_set>

namespace nypy {

// Other: a function, class, builtin, undefined ... - no builtin methods.
enum class MemberKind { None, Bool, Int, Float, Str, List, Tuple, Dict, Set, Instance, Generator, Other };

// The object protocol every value answers (Nython-only; both engines).
inline const std::unordered_set<std::string>& protocol_members() {
    static const std::unordered_set<std::string> s = {
        "class_name", "type_name", "to_string", "str", "id", "hash", "is_a", "instance_of",
        "equals_to", "same_as", "fields", "attributes"};
    return s;
}

inline bool is_operator_member(const std::string& m) {
    static const std::unordered_set<std::string> s = {
        "+", "-", "*", "/", "//", "%", "**", "&", "|", "^", "<<", ">>",
        "==", "!=", "<", "<=", ">", ">="};
    return s.count(m) > 0;
}

inline bool kind_has_method(MemberKind k, const std::string& m) {
    static const std::unordered_set<std::string> str_m = {
        "__contains__", "capitalize", "casefold", "center", "charAt", "char_at", "contains", "count",
        "decode", "encode", "ends_with", "endswith", "expandtabs", "find", "format", "format_map",
        "includes", "index", "isalnum", "isalpha", "isascii", "isdecimal", "isdigit", "isidentifier",
        "islower", "isnumeric", "isprintable", "isspace", "istitle", "isupper", "join", "len", "length",
        "ljust", "lower", "lstrip", "partition", "removeprefix", "removesuffix", "repeat", "replace",
        "reverse", "reversed", "rfind", "rindex", "rjust", "rpartition", "rsplit", "rstrip", "size",
        "slice", "split", "splitlines", "starts_with", "startswith", "strip", "substr", "substring",
        "swapcase", "title", "to_float", "to_int", "to_integer", "to_number", "trim", "upper", "zfill"};
    static const std::unordered_set<std::string> list_m = {
        "__contains__", "add", "append", "clear", "contains", "copy", "count", "difference", "discard",
        "each", "extend", "filter", "fold", "forEach", "has", "includes", "index", "indexOf", "insert",
        "intersection", "join", "len", "length", "map", "max", "min", "pop", "push", "reduce", "remove",
        "reverse", "reversed", "size", "slice", "sort", "sorted", "sum", "union"};
    static const std::unordered_set<std::string> tuple_m = {
        "__contains__", "contains", "count", "copy", "each", "filter", "fold", "forEach", "has",
        "includes", "index", "indexOf", "join", "len", "length", "map", "max", "min", "reduce",
        "reversed", "size", "slice", "sorted", "sum"};
    static const std::unordered_set<std::string> dict_m = {
        "__len__", "clear", "contains", "containsKey", "copy", "delete", "entries", "get", "has",
        "has_key", "items", "keys", "length", "merge", "pop", "popitem", "remove", "setdefault",
        "size", "update", "values"};
    static const std::unordered_set<std::string> set_m = {
        "__contains__", "add", "clear", "contains", "copy", "difference", "discard", "has", "includes",
        "intersection", "len", "length", "pop", "remove", "size", "union", "update",
        "symmetric_difference", "issubset", "issuperset", "isdisjoint"};
    // Generators and the lazy iterators (round 75, NyGen.hpp).
    static const std::unordered_set<std::string> gen_m = {
        "__iter__", "__next__", "close", "next", "send", "throw"};
    if (k == MemberKind::Other) return false;
    if (protocol_members().count(m)) return true;
    switch (k) {
        case MemberKind::Str:   return str_m.count(m) > 0;
        case MemberKind::List:  return list_m.count(m) > 0;
        case MemberKind::Tuple: return tuple_m.count(m) > 0;
        case MemberKind::Dict:  return dict_m.count(m) > 0;
        case MemberKind::Set:   return set_m.count(m) > 0;
        case MemberKind::Generator: return gen_m.count(m) > 0;
        case MemberKind::Int: case MemberKind::Float: case MemberKind::Bool:
            return is_operator_member(m);
        default: return false;
    }
}

// How a missing read reports itself: NY_LENIENT_READS=log is a porting aid
// that, instead of raising, prints each missing attribute / key read once
// per source line to stderr and yields none (the behaviour before round 75).
inline bool lenient_reads_log() {
    static const bool on = [] {
        const char* e = std::getenv("NY_LENIENT_READS");
        return e && std::string(e) == "log";
    }();
    return on;
}

} // namespace nypy

#endif
