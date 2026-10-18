// builtins/nybuffer.cpp - the native half of memoryview and the buffer
// protocol (round 84; PEP 3118, PEP 688).
//
// A buffer is a region of native memory: the address of its first item, the
// item format and size, a shape and strides in bytes (the prelude's
// memoryview keeps them; exporters - bytes and bytearray through the
// engines' _ny_buf_export, array.array, mmap, ctypes, classes with
// __buffer__ - give them). These natives read and write such regions; they
// are served by the concurrency runtime's dispatcher
// (nyconc::register_extension), so both engines call the same code, with no
// value crossing between engines (addresses are ints).
//
//   _mv_fmt(fmt) -> [code, itemsize]   a native single-character format
//                                      ("@" optional), else None
//   _mv_get(addr, code) -> value       one item (int, float, bool, bytes; an
//                                      unsigned value past 2**63 as its text)
//   _mv_set(addr, code, v)             v already an int/float/bool/bytes of
//                                      range (the prelude checks ranges);
//                                      ValueError for an "e" overflow
//   _mv_read(addr, n) -> bytes         _mv_write(addr, data) -> n
//   _mv_move(dst, src, n)              memmove
//   _mv_tolist(addr, code, shape, strides) -> nested lists
//   _mv_tobytes(addr, itemsize, shape, strides, order) -> bytes ("C"/"F")
//   _mv_store(addr, itemsize, shape, strides, data)    C-ordered bytes into
//                                      the strided layout
//   _mv_cmp(addr1, fmt1, addr2, fmt2, shape, strides1, strides2) -> 1 / 0,
//                                      -1 when a format is not one this
//                                      unpacks (one code, an optional byte
//                                      order: the prelude then tries struct)
//
// Native sizes are this machine's C sizes (a long is 8 bytes on 64-bit
// Linux and macOS, 4 on Windows), as CPython's memoryview and struct use.
#include "NyConc.hpp"
#include <cstdint>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

namespace {
using namespace nyconc;

[[noreturn]] void raise(const std::string& type, const std::string& msg) { throw NyError::make(type, msg); }

char* addr_of(const Args& a, size_t i) { return (char*)(intptr_t)a.as_int(i); }

std::vector<int64_t> ints(const Args& a, size_t i) {
    std::vector<int64_t> out;
    auto l = a.list(i);
    for (size_t k = 0; k < l->size(); k++) out.push_back(l->as_int(k));
    return out;
}

// ── formats ─────────────────────────────────────────────────────────────────
// CPython's get_native_fmtchar: the size of a native single-character
// format, -1 for anything else.
int native_size(char c) {
    switch (c) {
        case 'c': case 'b': case 'B': return 1;
        case 'h': case 'H': return (int)sizeof(short);
        case 'i': case 'I': return (int)sizeof(int);
        case 'l': case 'L': return (int)sizeof(long);
        case 'q': case 'Q': return (int)sizeof(long long);
        case 'n': case 'N': return (int)sizeof(size_t);
        case 'f': return (int)sizeof(float);
        case 'd': return (int)sizeof(double);
        case 'e': return 2;
        case '?': return (int)sizeof(bool);
        case 'P': return (int)sizeof(void*);
        default: return -1;
    }
}
// struct's standard sizes (the "<", ">", "!", "=" byte orders)
int std_size(char c) {
    switch (c) {
        case 'c': case 'b': case 'B': case '?': return 1;
        case 'h': case 'H': case 'e': return 2;
        case 'i': case 'I': case 'l': case 'L': case 'f': return 4;
        case 'q': case 'Q': case 'd': return 8;
        default: return -1;
    }
}
bool host_little() { uint16_t x = 1; unsigned char b; std::memcpy(&b, &x, 1); return b == 1; }

// One item's layout: its code, size and byte order.
struct Fmt {
    char code = 0;
    int size = 0;
    bool little = true;
    bool native = true;
};
// A format of one code and an optional byte order ("@i", "<H", "!d", "c"),
// as memoryview and struct read it; false for anything else.
bool parse_fmt(const std::string& f, Fmt& out) {
    size_t i = 0;
    char order = '@';
    if (!f.empty() && (f[0] == '@' || f[0] == '=' || f[0] == '<' || f[0] == '>' || f[0] == '!')) { order = f[0]; i = 1; }
    if (f.size() != i + 1) return false;
    char c = f[i];
    out.code = c;
    out.native = order == '@';
    out.size = out.native ? native_size(c) : std_size(c);
    if (out.size < 0) return false;
    out.little = (order == '@' || order == '=') ? host_little() : order == '<';
    return true;
}

// ── half precision (CPython's PyFloat_Pack2 / PyFloat_Unpack2) ──────────────
bool pack_half(double x, uint16_t& out) {
    unsigned sign;
    int e;
    unsigned short bits;
    if (x == 0.0) { sign = std::signbit(x) ? 1 : 0; e = 0; bits = 0; }
    else if (std::isinf(x)) { sign = x < 0.0; e = 0x1f; bits = 0; }
    else if (std::isnan(x)) { sign = std::signbit(x) ? 1 : 0; e = 0x1f; bits = 512; }
    else {
        sign = x < 0.0;
        if (sign) x = -x;
        double f = std::frexp(x, &e);
        f *= 2.0;
        e--;
        if (e >= 16) return false;
        else if (e < -25) { f = 0.0; e = 0; }
        else if (e < -14) { f = std::ldexp(f, 14 + e); e = 0; }
        else { e += 15; f -= 1.0; }
        f *= 1024.0;
        bits = (unsigned short)f;
        if ((f - bits > 0.5) || ((f - bits == 0.5) && (bits % 2 == 1))) {
            ++bits;
            if (bits == 1024) {
                bits = 0;
                ++e;
                if (e == 31) return false;
            }
        }
    }
    out = (uint16_t)(bits | (e << 10) | (sign << 15));
    return true;
}
double unpack_half(uint16_t h) {
    unsigned sign = (h >> 15) & 1;
    int e = (h >> 10) & 0x1f;
    unsigned f = h & 0x3ff;
    if (e == 0x1f) {
        if (f == 0) return sign ? -HUGE_VAL : HUGE_VAL;
        return sign ? -std::fabs(NAN) : std::fabs(NAN);
    }
    double x = (double)f / 1024.0;
    if (e == 0) e = -14;
    else { x += 1.0; e -= 15; }
    x = std::ldexp(x, e);
    return sign ? -x : x;
}

// ── one item ────────────────────────────────────────────────────────────────
// An unpacked item: what it compares as.
struct Item {
    enum K { I, U, F, B } k = I;     // signed, unsigned, float, bytes (c)
    int64_t i = 0; uint64_t u = 0; double d = 0; char c = 0;
};
void load_bytes(const char* p, const Fmt& f, unsigned char* out) {
    // the item's bytes in the host's order
    if (f.little == host_little()) std::memcpy(out, p, (size_t)f.size);
    else for (int k = 0; k < f.size; k++) out[k] = (unsigned char)p[f.size - 1 - k];
}
uint64_t load_u(const unsigned char* b, int size) {
    uint64_t v = 0;
    if (host_little()) for (int k = size - 1; k >= 0; k--) v = (v << 8) | b[k];
    else for (int k = 0; k < size; k++) v = (v << 8) | b[k];
    return v;
}
bool is_signed_code(char c) { return c == 'b' || c == 'h' || c == 'i' || c == 'l' || c == 'q' || c == 'n'; }
Item unpack(const char* p, const Fmt& f) {
    unsigned char b[16];
    load_bytes(p, f, b);
    Item it;
    switch (f.code) {
        case 'c': it.k = Item::B; it.c = (char)b[0]; return it;
        case '?': it.k = Item::I; it.i = b[0] != 0; return it;
        case 'f': { float x; std::memcpy(&x, b, 4); it.k = Item::F; it.d = x; return it; }
        case 'd': { double x; std::memcpy(&x, b, 8); it.k = Item::F; it.d = x; return it; }
        case 'e': { uint16_t h; std::memcpy(&h, b, 2); it.k = Item::F; it.d = unpack_half(h); return it; }
        default: break;
    }
    uint64_t u = load_u(b, f.size);
    if (is_signed_code(f.code)) {
        int bits = f.size * 8;
        int64_t v = bits >= 64 ? (int64_t)u : (int64_t)((u ^ (1ULL << (bits - 1))) - (1ULL << (bits - 1)));
        it.k = Item::I; it.i = v;
    } else { it.k = Item::U; it.u = u; }
    return it;
}
Ret to_ret(const Item& it, char code) {
    switch (it.k) {
        case Item::B: return Ret::bytes(std::string(1, it.c));
        case Item::F: return Ret::number(it.d);
        case Item::I: return code == '?' ? Ret::boolean(it.i != 0) : Ret::integer(it.i);
        case Item::U:
            if (it.u > (uint64_t)INT64_MAX) return Ret::str(std::to_string(it.u));   // the prelude makes it an int
            return Ret::integer((int64_t)it.u);
    }
    return Ret::none();
}
// Python's == between two unpacked items.
bool num_eq_if(int64_t a, double d) {
    if (std::isnan(d) || std::isinf(d) || d != std::floor(d)) return false;
    if (d < -9.3e18 || d > 9.3e18) return false;
    return (double)a == d && (int64_t)d == a;
}
bool num_eq_uf(uint64_t a, double d) {
    if (std::isnan(d) || std::isinf(d) || d != std::floor(d) || d < 0 || d > 1.9e19) return false;
    return (double)a == d && (uint64_t)d == a;
}
bool item_eq(const Item& x, const Item& y) {
    if (x.k == Item::B || y.k == Item::B) return x.k == y.k && x.c == y.c;
    if (x.k == Item::F && y.k == Item::F) return x.d == y.d;
    if (x.k == Item::F) return y.k == Item::I ? num_eq_if(y.i, x.d) : num_eq_uf(y.u, x.d);
    if (y.k == Item::F) return x.k == Item::I ? num_eq_if(x.i, y.d) : num_eq_uf(x.u, y.d);
    if (x.k == Item::I && y.k == Item::I) return x.i == y.i;
    if (x.k == Item::U && y.k == Item::U) return x.u == y.u;
    if (x.k == Item::I) return x.i >= 0 && (uint64_t)x.i == y.u;
    return y.i >= 0 && (uint64_t)y.i == x.u;
}

void store_u(char* p, uint64_t v, const Fmt& f) {
    unsigned char b[8];
    for (int k = 0; k < f.size; k++) b[k] = (unsigned char)(v >> (8 * k));   // little-endian
    if (f.little) std::memcpy(p, b, (size_t)f.size);
    else for (int k = 0; k < f.size; k++) p[k] = (char)b[f.size - 1 - k];
}

// ── strided walks ───────────────────────────────────────────────────────────
// Calls fn(ptr) for every item, in C order (the last index fastest) or in
// Fortran order (the first fastest).
template <class F>
void walk(char* base, const std::vector<int64_t>& shape, const std::vector<int64_t>& strides, bool fortran, F&& fn) {
    size_t nd = shape.size();
    if (nd == 0) { fn(base); return; }
    for (auto s : shape) if (s <= 0) return;
    std::vector<int64_t> idx(nd, 0);
    while (true) {
        char* p = base;
        for (size_t k = 0; k < nd; k++) p += idx[k] * strides[k];
        fn(p);
        // the next index
        if (!fortran) {
            size_t k = nd;
            while (k > 0) {
                k--;
                if (++idx[k] < shape[k]) break;
                idx[k] = 0;
                if (k == 0) return;
            }
        } else {
            size_t k = 0;
            while (true) {
                if (++idx[k] < shape[k]) break;
                idx[k] = 0;
                if (++k == nd) return;
            }
        }
    }
}

Ret tolist_rec(char* p, const Fmt& f, const std::vector<int64_t>& shape, const std::vector<int64_t>& strides, size_t dim) {
    std::vector<Ret> out;
    int64_t n = shape[dim];
    out.reserve((size_t)std::max<int64_t>(n, 0));
    for (int64_t k = 0; k < n; k++) {
        char* q = p + k * strides[dim];
        if (dim + 1 == shape.size()) out.push_back(to_ret(unpack(q, f), f.code));
        else out.push_back(tolist_rec(q, f, shape, strides, dim + 1));
    }
    return Ret::lst(std::move(out));
}

// ── the builtins ────────────────────────────────────────────────────────────
Ret b_fmt(Engine&, const Args& a) {
    std::string f = a.as_str(0);
    size_t i = (!f.empty() && f[0] == '@') ? 1 : 0;
    if (f.size() != i + 1) return Ret::none();
    int n = native_size(f[i]);
    if (n < 0) return Ret::none();
    return Ret::lst({Ret::str(std::string(1, f[i])), Ret::integer(n)});
}
Ret b_get(Engine&, const Args& a) {
    char* p = addr_of(a, 0);
    std::string c = a.as_str(1);
    Fmt f;
    if (c.empty() || !parse_fmt(c, f)) raise("NotImplementedError", "memoryview: format " + c + " not supported");
    if (!p) raise("ValueError", "memoryview: NULL pointer access");
    return to_ret(unpack(p, f), f.code);
}
Ret b_set(Engine&, const Args& a) {
    char* p = addr_of(a, 0);
    std::string c = a.as_str(1);
    Fmt f;
    if (c.empty() || !parse_fmt(c, f)) raise("NotImplementedError", "memoryview: format " + c + " not supported");
    if (!p) raise("ValueError", "memoryview: NULL pointer access");
    switch (f.code) {
        case 'c': {
            std::string s = a.as_bytes(2);
            p[0] = s.empty() ? 0 : s[0];
            return Ret::none();
        }
        case '?': p[0] = a.truthy(2) ? 1 : 0; return Ret::none();
        case 'f': {
            float x = (float)a.as_num(2);
            unsigned char b[4]; std::memcpy(b, &x, 4);
            if (f.little != host_little()) std::swap(b[0], b[3]), std::swap(b[1], b[2]);
            std::memcpy(p, b, 4);
            return Ret::none();
        }
        case 'd': {
            double x = a.as_num(2);
            unsigned char b[8]; std::memcpy(b, &x, 8);
            if (f.little != host_little()) for (int k = 0; k < 4; k++) std::swap(b[k], b[7 - k]);
            std::memcpy(p, b, 8);
            return Ret::none();
        }
        case 'e': {
            uint16_t h;
            if (!pack_half(a.as_num(2), h)) raise("ValueError", "memoryview: invalid value for format 'e'");
            store_u(p, h, f);
            return Ret::none();
        }
        default: break;
    }
    store_u(p, (uint64_t)a.as_int(2), f);
    return Ret::none();
}
Ret b_read(Engine&, const Args& a) {
    int64_t n = a.as_int(1);
    if (n <= 0) return Ret::bytes("");
    const char* p = addr_of(a, 0);
    if (!p) raise("ValueError", "memoryview: NULL pointer access");
    return Ret::bytes(std::string(p, (size_t)n));
}
Ret b_write(Engine&, const Args& a) {
    std::string s = a.as_bytes(1);
    if (s.empty()) return Ret::integer(0);
    char* p = addr_of(a, 0);
    if (!p) raise("ValueError", "memoryview: NULL pointer access");
    std::memcpy(p, s.data(), s.size());
    return Ret::integer((int64_t)s.size());
}
Ret b_move(Engine&, const Args& a) {
    int64_t n = a.as_int(2);
    if (n > 0) std::memmove(addr_of(a, 0), addr_of(a, 1), (size_t)n);
    return Ret::none();
}
Ret b_tolist(Engine&, const Args& a) {
    char* p = addr_of(a, 0);
    std::string c = a.as_str(1);
    Fmt f;
    if (c.empty() || !parse_fmt(c, f)) raise("NotImplementedError", "memoryview: format " + c + " not supported");
    std::vector<int64_t> shape = ints(a, 2), strides = ints(a, 3);
    if (shape.empty()) return to_ret(unpack(p, f), f.code);
    return tolist_rec(p, f, shape, strides, 0);
}
Ret b_tobytes(Engine&, const Args& a) {
    char* p = addr_of(a, 0);
    int64_t isz = a.as_int(1);
    std::vector<int64_t> shape = ints(a, 2), strides = ints(a, 3);
    bool fortran = a.size() > 4 && a.as_str(4) == "F";
    std::string out;
    int64_t total = isz;
    for (auto s : shape) total *= s;
    if (total <= 0) return Ret::bytes("");
    out.reserve((size_t)total);
    walk(p, shape, strides, fortran, [&](char* q) { out.append(q, (size_t)isz); });
    return Ret::bytes(out);
}
Ret b_store(Engine&, const Args& a) {
    char* p = addr_of(a, 0);
    int64_t isz = a.as_int(1);
    std::vector<int64_t> shape = ints(a, 2), strides = ints(a, 3);
    std::string data = a.as_bytes(4);
    size_t off = 0;
    walk(p, shape, strides, false, [&](char* q) {
        if (off + (size_t)isz <= data.size()) std::memcpy(q, data.data() + off, (size_t)isz);
        off += (size_t)isz;
    });
    return Ret::none();
}
Ret b_cmp(Engine&, const Args& a) {
    char* p1 = addr_of(a, 0);
    std::string f1s = a.as_str(1);
    char* p2 = addr_of(a, 2);
    std::string f2s = a.as_str(3);
    Fmt f1, f2;
    if (!parse_fmt(f1s, f1) || !parse_fmt(f2s, f2)) return Ret::integer(-1);
    std::vector<int64_t> shape = ints(a, 4), s1 = ints(a, 5), s2 = ints(a, 6);
    size_t nd = shape.size();
    if (nd == 0) return Ret::integer(item_eq(unpack(p1, f1), unpack(p2, f2)) ? 1 : 0);
    for (auto s : shape) if (s <= 0) return Ret::integer(1);
    std::vector<int64_t> idx(nd, 0);
    while (true) {
        char* q1 = p1; char* q2 = p2;
        for (size_t k = 0; k < nd; k++) { q1 += idx[k] * s1[k]; q2 += idx[k] * s2[k]; }
        if (!item_eq(unpack(q1, f1), unpack(q2, f2))) return Ret::integer(0);
        size_t k = nd;
        bool done = false;
        while (k > 0) {
            k--;
            if (++idx[k] < shape[k]) break;
            idx[k] = 0;
            if (k == 0) done = true;
        }
        if (done) break;
    }
    return Ret::integer(1);
}

struct Registrar {
    Registrar() {
        struct { const char* n; ExtHandler h; } t[] = {
            {"_mv_fmt", b_fmt}, {"_mv_get", b_get}, {"_mv_set", b_set}, {"_mv_read", b_read},
            {"_mv_write", b_write}, {"_mv_move", b_move}, {"_mv_tolist", b_tolist}, {"_mv_tobytes", b_tobytes},
            {"_mv_store", b_store}, {"_mv_cmp", b_cmp},
        };
        for (auto& x : t) register_extension(x.n, x.h);
    }
};
Registrar g_registrar;

} // namespace
