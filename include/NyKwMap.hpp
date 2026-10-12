#pragma once
// NyKwMap.hpp - keyword arguments in the order they were passed (round 77).
//
// The interpreter collected keyword arguments in an unordered_map, so a
// function's **kwargs listed them in hash order (f(a=1, b=2) could see
// {'b': 2, 'a': 1}); PEP 468 makes it the call order, as the VM already
// had it. Calls pass a handful of keywords, so a vector searched linearly
// is the map: the interface is the part of unordered_map the call paths
// use (find/count/[]/insert/emplace/erase/iteration).
#include <string>
#include <utility>
#include <vector>

namespace nyrt {

template <class V>
class OrderedKw {
public:
    using value_type = std::pair<std::string, V>;
    using iterator = typename std::vector<value_type>::iterator;
    using const_iterator = typename std::vector<value_type>::const_iterator;

    iterator begin() { return items_.begin(); }
    iterator end() { return items_.end(); }
    const_iterator begin() const { return items_.begin(); }
    const_iterator end() const { return items_.end(); }
    bool empty() const { return items_.empty(); }
    size_t size() const { return items_.size(); }
    void clear() { items_.clear(); }

    iterator find(const std::string& k) {
        for (auto it = items_.begin(); it != items_.end(); ++it) if (it->first == k) return it;
        return items_.end();
    }
    const_iterator find(const std::string& k) const {
        for (auto it = items_.begin(); it != items_.end(); ++it) if (it->first == k) return it;
        return items_.end();
    }
    size_t count(const std::string& k) const { return find(k) != items_.end() ? 1 : 0; }
    V& operator[](const std::string& k) {
        auto it = find(k);
        if (it != items_.end()) return it->second;
        items_.emplace_back(k, V());
        return items_.back().second;
    }
    V& at(const std::string& k) { return find(k)->second; }
    const V& at(const std::string& k) const { return find(k)->second; }
    std::pair<iterator, bool> insert(const value_type& kv) {
        auto it = find(kv.first);
        if (it != items_.end()) return {it, false};
        items_.push_back(kv);
        return {items_.end() - 1, true};
    }
    std::pair<iterator, bool> emplace(const std::string& k, const V& v) { return insert(value_type(k, v)); }
    size_t erase(const std::string& k) {
        auto it = find(k);
        if (it == items_.end()) return 0;
        items_.erase(it);
        return 1;
    }
    iterator erase(iterator it) { return items_.erase(it); }

private:
    std::vector<value_type> items_;
};

}  // namespace nyrt
