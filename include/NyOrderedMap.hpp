#pragma once
// NyOrderedMap.hpp - an insertion-ordered string-keyed hash map with the
// std::unordered_map interface the engines use.
//
// Both engines kept dicts (and the interpreter also lists, instances' fields
// and scopes) in std::unordered_map<std::string, V>, so dict iteration came
// out in hash order: {"b": 1, "a": 2} printed as {a: 2, b: 1} and keys()
// disagreed between the engines. This keeps the entries in insertion order,
// the way Python's dict does: an array of slots (so references to values stay
// valid while the map grows, as they did with the node-based map) plus an
// open-addressing index of slot numbers.
//
// Erasing leaves a tombstone slot that iteration skips; the last slot is
// popped instead, so stack-like use stays compact. Tombstones are compacted
// away only by erase(key) once they dominate, never while inserting.
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <type_traits>
#include <iterator>
#include <functional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace nypy {

template<class V>
class OrderedMap {
public:
    using key_type = std::string;
    using mapped_type = V;
    using value_type = std::pair<std::string, V>;
    using size_type = size_t;

private:
    struct Slot {
        value_type kv;
        uint64_t hash = 0;
        bool live = false;
        Slot(value_type&& p, uint64_t h) : kv(std::move(p)), hash(h), live(true) {}
        Slot(std::string&& k, V&& v, uint64_t h) : kv(std::move(k), std::move(v)), hash(h), live(true) {}
        Slot(const Slot&) = default;
        Slot(Slot&&) = default;
    };
    // Slots live in geometrically growing chunks (B, 2B, 4B, ...) that never
    // move, so a reference to a value stays valid while the map grows, as it
    // did with the node-based std::unordered_map. (A std::deque would do the
    // same, but with values this large it allocates a block per element.)
    // B keeps the first chunk within malloc's per-thread cache (<= 1 KB).
    static constexpr size_t kChunkShift = sizeof(Slot) * 4 <= 1024 ? 2 : 1;
    static constexpr size_t kB = (size_t)1 << kChunkShift;
    class Slots {
        Slot* c0_ = nullptr;             // first chunk, inline: most maps stay in it
        std::vector<Slot*> more_;        // chunks 1, 2, ...
        size_t n_ = 0;
        static size_t chunk_of(size_t i, size_t& off) {
            size_t q = (i >> kChunkShift) + 1;
            size_t c = (size_t)(63 - __builtin_clzll((unsigned long long)q));
            off = i - kB * (((size_t)1 << c) - 1);
            return c;
        }
        Slot* chunk_ptr(size_t c) const { return c == 0 ? c0_ : more_[c - 1]; }
        size_t nchunks() const { return c0_ ? 1 + more_.size() : 0; }
        Slot* place() {
            size_t off; size_t c = chunk_of(n_, off);
            while (c >= nchunks()) {
                Slot* mem = static_cast<Slot*>(::operator new(sizeof(Slot) * (kB << nchunks())));
                if (!c0_) c0_ = mem; else more_.push_back(mem);
            }
            return &chunk_ptr(c)[off];
        }
    public:
        Slots() = default;
        Slots(const Slots& o) { for (size_t i = 0; i < o.n_; i++) push(Slot(o[i])); }
        Slots(Slots&& o) noexcept : c0_(o.c0_), more_(std::move(o.more_)), n_(o.n_) { o.c0_ = nullptr; o.n_ = 0; o.more_.clear(); }
        Slots& operator=(const Slots& o) { if (this != &o) { Slots t(o); swap(t); } return *this; }
        Slots& operator=(Slots&& o) noexcept { if (this != &o) { Slots t(std::move(o)); swap(t); } return *this; }
        ~Slots() { clear(); }
        size_t size() const { return n_; }
        bool empty() const { return n_ == 0; }
        Slot& operator[](size_t i) { if (i < kB) return c0_[i]; size_t off; size_t c = chunk_of(i, off); return chunk_ptr(c)[off]; }
        const Slot& operator[](size_t i) const { if (i < kB) return c0_[i]; size_t off; size_t c = chunk_of(i, off); return chunk_ptr(c)[off]; }
        Slot& back() { return (*this)[n_ - 1]; }
        const Slot* chunk(size_t c) const { return chunk_ptr(c); }
        void push(Slot&& s) { new (place()) Slot(std::move(s)); n_++; }
        void emplace(std::string&& k, V&& v, uint64_t h) { new (place()) Slot(std::move(k), std::move(v), h); n_++; }
        void pop_back() { n_--; (*this)[n_].~Slot(); }
        void clear() {
            for (size_t i = 0; i < n_; i++) (*this)[i].~Slot();
            n_ = 0;
            if (c0_) ::operator delete(static_cast<void*>(c0_));
            for (Slot* c : more_) ::operator delete(static_cast<void*>(c));
            c0_ = nullptr; more_.clear();
        }
        void swap(Slots& o) noexcept { std::swap(c0_, o.c0_); more_.swap(o.more_); std::swap(n_, o.n_); }
    };
    Slots slots_;
    // Index cells: kEmpty, kDeleted, or (high 32 bits of the hash << 32 | slot
    // number), so most probes are rejected without touching the slot.
    std::vector<uint64_t> index_;
    size_t live_ = 0;
    size_t used_ = 0;              // index cells that are not empty (live + deleted)

    static constexpr uint64_t kEmpty = ~(uint64_t)0, kDeleted = ~(uint64_t)0 - 1;
    static bool is_ref(uint64_t c) { return c < kDeleted; }
    // The hash is 64 bits on every platform (a 32-bit size_t would leave no
    // high half for the tag, and h >> 32 would be undefined there).
    static uint64_t cell_of(uint64_t h, size_t n) { return ((h >> 32) << 32) | (uint64_t)n; }
    static size_t slot_of(uint64_t c) { return (size_t)(c & 0xFFFFFFFFu); }
    // FNV-1a plus a multiplicative finaliser: cheap on the short identifiers
    // and index keys ("0", "1", ...) these maps mostly hold, and the
    // finaliser spreads them over the low bits the index masks with.
    static uint64_t hash_of(std::string_view k) {
        uint64_t h = 1469598103934665603ull;
        for (unsigned char c : k) { h ^= c; h *= 1099511628211ull; }
        h ^= h >> 32; h *= 0x9E3779B97F4A7C15ull; h ^= h >> 29;
        return h;
    }

    // Keys are mostly short names: compared inline rather than via memcmp.
    static bool key_eq(const std::string& a, std::string_view b) {
        const size_t n = a.size();
        if (n != b.size()) return false;
        const char* x = a.data(); const char* y = b.data();
        if (n > 16) return std::memcmp(x, y, n) == 0;
        for (size_t i = 0; i < n; i++) if (x[i] != y[i]) return false;
        return true;
    }

    void rebuild_index(size_t cap) {
        size_t c = 8;
        while (c < cap) c <<= 1;
        index_.assign(c, kEmpty);
        used_ = 0;
        size_t mask = c - 1;
        for (size_t n = 0; n < slots_.size(); n++) {
            if (!slots_[n].live) continue;
            size_t i = (size_t)(slots_[n].hash & mask);
            while (index_[i] != kEmpty) i = (i + 1) & mask;
            index_[i] = cell_of(slots_[n].hash, n);
            used_++;
        }
    }
    void grow_if_needed() {
        if ((used_ + 1) * 2 > index_.size()) rebuild_index(live_ * 4 + 8);
    }
    // Index cell holding key, or -1 (hashed mode only); *sp is its slot.
    long find_cell(std::string_view k, uint64_t h, const Slot** sp = nullptr) const {
        size_t mask = index_.size() - 1, i = (size_t)(h & mask);
        const uint64_t tag = h >> 32;
        while (true) {
            uint64_t c = index_[i];
            if (c == kEmpty) return -1;
            if ((c >> 32) == tag && is_ref(c)) {
                const Slot& sl = slots_[slot_of(c)];
                if (sl.hash == h && key_eq(sl.kv.first, k)) { if (sp) *sp = &sl; return (long)i; }
            }
            i = (i + 1) & mask;
        }
    }
    // Maps of up to kSmall slots have no index and are searched linearly
    // without hashing (as libstdc++ does for small unordered_maps); most
    // scopes and objects never grow past it. Hashes are computed when a map
    // first needs its index.
    static constexpr size_t kSmall = 8;
    // Slot number holding key, or -1; *sp (when given) is the slot itself,
    // so callers need not locate it again.
    long find_slot(std::string_view k, const Slot** sp = nullptr) const {
        if (index_.empty()) {
            const size_t e = slots_.size(), ks = k.size();
            const char* kd = k.data();
            for (size_t c = 0, base = 0; base < e; c++) {
                const Slot* ch = slots_.chunk(c);
                size_t lim = std::min(kB << c, e - base);
                for (size_t o = 0; o < lim; o++) {
                    const std::string& key = ch[o].kv.first;
                    if (key.size() == ks && (ks == 0 || (key[0] == kd[0] && key_eq(key, k))) && ch[o].live) {
                        if (sp) *sp = &ch[o];
                        return (long)(base + o);
                    }
                }
                base += kB << c;
            }
            return -1;
        }
        long c = find_cell(k, hash_of(k), sp);
        return c < 0 ? -1 : (long)slot_of(index_[(size_t)c]);
    }
    // Inserts a key known to be absent; returns its slot number.
    void index_all() {
        for (size_t n = 0; n < slots_.size(); n++) if (slots_[n].live) slots_[n].hash = hash_of(slots_[n].kv.first);
    }
    size_t insert_new(std::string&& k, V&& v) {
        if (index_.empty()) {
            if (slots_.size() < kSmall) {
                size_t n = slots_.size();
                slots_.emplace(std::move(k), std::move(v), 0);
                live_++;
                return n;
            }
            index_all();
            rebuild_index(live_ * 4 + 8);
        }
        uint64_t h = hash_of(k);
        grow_if_needed();
        size_t mask = index_.size() - 1, i = (size_t)(h & mask);
        while (is_ref(index_[i])) i = (i + 1) & mask;
        if (index_[i] == kEmpty) used_++;
        size_t n = slots_.size();
        slots_.emplace(std::move(k), std::move(v), h);
        index_[i] = cell_of(h, n);
        live_++;
        return n;
    }
    void kill_slot(size_t n) {
        Slot& sl = slots_[n];
        if (!index_.empty()) {
            long c = find_cell(sl.kv.first, sl.hash);
            if (c >= 0) index_[(size_t)c] = kDeleted;
        }
        sl.live = false;
        sl.kv.second = V();
        std::string().swap(sl.kv.first);
        live_--;
        // Trailing tombstones are dropped outright.
        while (!slots_.empty() && !slots_.back().live) slots_.pop_back();
    }
    void compact() {
        Slots fresh;
        for (size_t n = 0; n < slots_.size(); n++) if (slots_[n].live) fresh.push(std::move(slots_[n]));
        slots_.swap(fresh);
        rebuild_index(live_ * 4 + 8);
    }

    // An iterator is a slot number plus that slot's address (slots never
    // move), so dereferencing costs no chunk arithmetic.
    template<class MapT, class ValT>
    class Iter {
        friend class OrderedMap;
        using SlotP = std::conditional_t<std::is_const_v<MapT>, const Slot*, Slot*>;
        MapT* m_ = nullptr;
        size_t n_ = 0;
        SlotP p_ = nullptr;
        void settle() {
            const size_t sz = m_->slots_.size();
            for (; n_ < sz; ++n_) { SlotP s = &m_->slots_[n_]; if (s->live) { p_ = s; return; } }
            p_ = nullptr;
        }
        Iter(MapT* m, size_t n, SlotP p) : m_(m), n_(n), p_(p) {}   // a live slot, known
    public:
        using iterator_category = std::forward_iterator_tag;
        using value_type = OrderedMap::value_type;
        using difference_type = std::ptrdiff_t;
        using pointer = ValT*;
        using reference = ValT&;
        Iter() = default;
        Iter(MapT* m, size_t n) : m_(m), n_(n) { settle(); }
        template<class M2, class V2, class = std::enable_if_t<std::is_const_v<MapT> && !std::is_const_v<M2>>>
        Iter(const Iter<M2, V2>& o) : m_(o.m_), n_(o.n_), p_(o.p_) {}
        reference operator*() const { return p_->kv; }
        pointer operator->() const { return &p_->kv; }
        Iter& operator++() { ++n_; settle(); return *this; }
        Iter operator++(int) { Iter t = *this; ++*this; return t; }
        template<class M2, class V2> bool operator==(const Iter<M2, V2>& o) const { return n_ == o.n_; }
        template<class M2, class V2> bool operator!=(const Iter<M2, V2>& o) const { return n_ != o.n_; }
        template<class, class> friend class Iter;
    };

public:
    using iterator = Iter<OrderedMap, value_type>;
    using const_iterator = Iter<const OrderedMap, const value_type>;

    OrderedMap() = default;
    OrderedMap(const OrderedMap&) = default;
    OrderedMap(OrderedMap&&) noexcept = default;
    OrderedMap& operator=(const OrderedMap&) = default;
    OrderedMap& operator=(OrderedMap&&) noexcept = default;
    OrderedMap(std::initializer_list<value_type> il) { for (auto& p : il) (*this)[p.first] = p.second; }

    iterator begin() { return iterator(this, 0); }
    iterator end() { return iterator(this, slots_.size()); }
    const_iterator begin() const { return const_iterator(this, 0); }
    const_iterator end() const { return const_iterator(this, slots_.size()); }
    const_iterator cbegin() const { return begin(); }
    const_iterator cend() const { return end(); }

    size_t size() const { return live_; }
    bool empty() const { return live_ == 0; }
    void reserve(size_t n) { if (n > kSmall && index_.size() < n * 2) { if (index_.empty()) index_all(); rebuild_index(n * 2); } }
    void clear() { slots_.clear(); index_.clear(); live_ = 0; used_ = 0; }

    iterator find(std::string_view k) {
        const Slot* sp = nullptr;
        long n = find_slot(k, &sp);
        return n < 0 ? end() : iterator(this, (size_t)n, const_cast<Slot*>(sp));
    }
    const_iterator find(std::string_view k) const {
        const Slot* sp = nullptr;
        long n = find_slot(k, &sp);
        return n < 0 ? end() : const_iterator(this, (size_t)n, sp);
    }
    iterator find(const std::string& k) { return find(std::string_view(k)); }
    const_iterator find(const std::string& k) const { return find(std::string_view(k)); }
    iterator find(const char* k) { return find(std::string_view(k)); }
    const_iterator find(const char* k) const { return find(std::string_view(k)); }
    size_t count(std::string_view k) const { return find_slot(k) >= 0 ? 1 : 0; }
    size_t count(const std::string& k) const { return count(std::string_view(k)); }
    size_t count(const char* k) const { return count(std::string_view(k)); }
    bool contains(std::string_view k) const { return count(k) > 0; }

    V& operator[](const std::string& k) {
        const Slot* sp = nullptr;
        if (find_slot(k, &sp) >= 0) return const_cast<Slot*>(sp)->kv.second;
        return slots_[insert_new(std::string(k), V())].kv.second;
    }
    V& operator[](std::string&& k) {
        const Slot* sp = nullptr;
        if (find_slot(k, &sp) >= 0) return const_cast<Slot*>(sp)->kv.second;
        return slots_[insert_new(std::move(k), V())].kv.second;
    }
    V& operator[](const char* k) { return (*this)[std::string(k)]; }
    V& at(const std::string& k) {
        auto it = find(k);
        if (it == end()) throw std::out_of_range("OrderedMap::at");
        return it->second;
    }
    const V& at(const std::string& k) const {
        auto it = find(k);
        if (it == end()) throw std::out_of_range("OrderedMap::at");
        return it->second;
    }

    std::pair<iterator, bool> insert(const value_type& p) {
        long f = find_slot(p.first);
        if (f >= 0) return {iterator(this, (size_t)f), false};
        size_t n = insert_new(std::string(p.first), V(p.second));
        return {iterator(this, n), true};
    }
    std::pair<iterator, bool> insert(value_type&& p) {
        long f = find_slot(p.first);
        if (f >= 0) return {iterator(this, (size_t)f), false};
        size_t n = insert_new(std::move(p.first), std::move(p.second));
        return {iterator(this, n), true};
    }
    // Hinted insert: the hint is ignored (entries always go at the end);
    // like std::unordered_map, an existing key is left unchanged.
    iterator insert(const_iterator, const value_type& p) { return insert(p).first; }
    iterator insert(const_iterator, value_type&& p) { return insert(std::move(p)).first; }
    template<class It> void insert(It first, It last) { for (; first != last; ++first) insert(value_type(first->first, first->second)); }
    template<class K, class... A> std::pair<iterator, bool> emplace(K&& k, A&&... a) {
        return insert(value_type(std::string(std::forward<K>(k)), V(std::forward<A>(a)...)));
    }
    template<class K, class... A> std::pair<iterator, bool> try_emplace(K&& k, A&&... a) {
        std::string key(std::forward<K>(k));
        auto it = find(key);
        if (it != end()) return {it, false};
        return insert(value_type(std::move(key), V(std::forward<A>(a)...)));
    }
    template<class M> std::pair<iterator, bool> insert_or_assign(const std::string& k, M&& v) {
        auto it = find(k);
        if (it != end()) { it->second = std::forward<M>(v); return {it, false}; }
        return insert(value_type(k, V(std::forward<M>(v))));
    }

    size_t erase(std::string_view k) {
        long n = find_slot(k);
        if (n < 0) return 0;
        kill_slot((size_t)n);
        if (!index_.empty() && slots_.size() > 32 && slots_.size() > live_ * 3) compact();
        return 1;
    }
    size_t erase(const std::string& k) { return erase(std::string_view(k)); }
    size_t erase(const char* k) { return erase(std::string_view(k)); }
    // Erase at an iterator; returns the next live entry. Never compacts, so
    // `it = m.erase(it)` loops stay valid.
    iterator erase(iterator pos) {
        if (pos.n_ >= slots_.size()) return end();
        size_t n = pos.n_;
        size_t next = n + 1;
        if (slots_[n].live) kill_slot(n);
        return iterator(this, std::min(next, slots_.size()));
    }
    iterator erase(const_iterator pos) { return erase(iterator(this, pos.n_)); }
    void swap(OrderedMap& o) noexcept {
        slots_.swap(o.slots_); index_.swap(o.index_);
        std::swap(live_, o.live_); std::swap(used_, o.used_);
    }
    bool operator==(const OrderedMap& o) const {
        if (size() != o.size()) return false;
        for (auto& kv : *this) {
            auto it = o.find(kv.first);
            if (it == o.end() || !(it->second == kv.second)) return false;
        }
        return true;
    }
};

} // namespace nypy
