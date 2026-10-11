#pragma once
// NyRange.hpp - range objects and dict views, the parts both engines share
// (round 78).
//
// range() returned a list and d.keys()/values()/items() lists. They are
// Python's types now: `range`, `dict_keys`, `dict_values`, `dict_items` are
// classes of the prelude (NyPrelude.hpp), whose methods are the general
// case (ints of any size, slices, the set operations of a keys or items
// view). The engines make the objects natively and take a native path for
// what programs do with them all the time - iterate, len(), `in`, an index,
// list()/sum()/sorted() of one - when a range's start, stop and step are
// 64-bit ints. These are those paths' arithmetic, written once.
//
// The arithmetic is done in uint64_t where a signed result could overflow
// on the way (stop - start of two 64-bit ints needs 65 bits): the true
// result always fits, and C++20 defines the conversion back as modular.
#include <cstdint>
#include <string>
#include "NyBigInt.hpp"

namespace nyrt {

// The number of values range(start, stop, step) holds (step != 0); false
// when it does not fit in an int64 (len() is an OverflowError there, as
// CPython's "Python int too large to convert to C ssize_t").
inline bool range_len(int64_t start, int64_t stop, int64_t step, int64_t& n) {
    uint64_t span, st;
    if (step > 0) {
        if (start >= stop) { n = 0; return true; }
        span = (uint64_t)stop - (uint64_t)start;
        st = (uint64_t)step;
    } else {
        if (start <= stop) { n = 0; return true; }
        span = (uint64_t)start - (uint64_t)stop;
        st = (uint64_t)0 - (uint64_t)step;
    }
    uint64_t c = (span - 1) / st + 1;
    if (c > (uint64_t)INT64_MAX) return false;
    n = (int64_t)c;
    return true;
}
// The value at position i (0 <= i < len): it lies between start and stop,
// so it fits even when i * step alone would not.
inline int64_t range_at(int64_t start, int64_t step, int64_t i) {
    return (int64_t)((uint64_t)start + (uint64_t)i * (uint64_t)step);
}
// Whether x is one of the values (CPython's range_contains_long), and its
// position when it is.
inline bool range_has(int64_t start, int64_t stop, int64_t step, int64_t x, int64_t* pos = nullptr) {
    uint64_t d, st;
    if (step > 0) {
        if (x < start || x >= stop) return false;
        d = (uint64_t)x - (uint64_t)start;
        st = (uint64_t)step;
    } else {
        if (x > start || x <= stop) return false;
        d = (uint64_t)start - (uint64_t)x;
        st = (uint64_t)0 - (uint64_t)step;
    }
    if (d % st != 0) return false;
    if (pos) *pos = (int64_t)(d / st);
    return true;
}
// sum(range(start, stop, step)) in O(1): n*start + step*n*(n-1)/2, exact at
// any size (n*(n-1) is even). The same value the loop adds up to, without
// the loop - sum(range(10**9)) is instant (round 78).
inline nypy::BigInt range_sum(int64_t start, int64_t step, int64_t n) {
    nypy::BigInt bn(n), q, r;
    nypy::BigInt::floordivmod(bn * nypy::BigInt(n - 1), nypy::BigInt(2), q, r);
    return bn * nypy::BigInt(start) + nypy::BigInt(step) * q;
}
// Whether an iterator from `first` by `step` for n values stays within 64
// bits (its last value fits): the native range_iterator; otherwise the
// prelude's generator (CPython's longrange_iterator).
inline bool range_iter_fits(int64_t first, int64_t step, int64_t n) {
    if (n <= 0) return true;
    int64_t last;
    return (nypy::BigInt(first) + nypy::BigInt(n - 1) * nypy::BigInt(step)).to_i64(last);
}

// A dict view's kind: what the engines' native dict iterators produce.
enum DictIterKind { DI_KEYS = 0, DI_VALUES = 1, DI_ITEMS = 2 };
inline const char* dict_iter_name(int kind, bool rev) {
    static const char* const fwd[] = {"dict_keyiterator", "dict_valueiterator", "dict_itemiterator"};
    static const char* const bwd[] = {"dict_reversekeyiterator", "dict_reversevalueiterator", "dict_reverseitemiterator"};
    return (rev ? bwd : fwd)[kind < 0 || kind > 2 ? 0 : kind];
}
// The view classes of the prelude, by name; -1 for any other class.
inline int dict_view_kind(const std::string& cls) {
    if (cls == "dict_keys") return DI_KEYS;
    if (cls == "dict_values") return DI_VALUES;
    if (cls == "dict_items") return DI_ITEMS;
    return -1;
}
// The hidden field holding a view's dict (also what the prelude reads).
inline const std::string& view_field() { static const std::string f("_ny_mapping"); return f; }

}  // namespace nyrt
