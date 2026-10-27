#pragma once
// NyTensor.hpp — the one tensor kernel library both engines call.
// ─────────────────────────────────────────────────────────────────────────────
// Every tensor native (the nt_* family, plus the legacy tensor_* / matmul /
// softmax / loss / audio names that used to be implemented twice) is written
// ONCE, in src/builtins/nytensor.cpp, against the small engine-neutral value
// type below. Each engine only converts its own values to nt::Val, calls
// nt::call(), and converts the result back:
//
//   interpreter  src/builtins/tensor.cpp   dispatch_nt()      (Value <-> Val)
//   bytecode VM  include/VirtualMachine.hpp register_nt_natives() (VMVal <-> Val)
//
// so the arithmetic is literally the same compiled code on both engines and
// results are bit-identical. Before this, the VM carried its own copies of
// ~100 tensor natives, several of them stubs (matmul returned [], transpose
// and attention returned their input), and the interpreter read every
// element as a double without checking whether it was an INTEGER.
//
// Representation (see the design note in lib/nytorch/tensor.ny): a tensor is
// a FLAT row-major list of floats plus a shape list. Kernels receive the flat
// data as std::vector<double> (Val::VEC) and return new flat data (and the
// output shape where it changes). A handful of natives update a list IN
// PLACE (optimizer steps, gradient accumulation, running statistics); their
// Op::mutates lists which arguments the adapter writes back into the
// caller's list object.
//
// Errors are raised as nt::Error{type, message}; the adapters turn them into
// the engine's catchable exception of that type (ValueError, IndexError, ...).

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace nt {

struct Error {
    std::string type;   // "ValueError", "IndexError", "TypeError", "IOError", ...
    std::string msg;
};

struct Val {
    enum Kind : uint8_t { NONE, BOOL, INT, FLOAT, STR, VEC, LIST };
    Kind k = NONE;
    bool b = false;
    int64_t i = 0;
    double d = 0.0;
    std::string s;
    std::vector<double> v;   // VEC: a list whose elements are all numbers
    bool v_int = false;      // VEC: every element was an INT (in) / emit INTs (out)
    std::vector<Val> items;  // LIST: any other list (nested, mixed, strings)

    static Val none() { return Val{}; }
    static Val boolean(bool x) { Val r; r.k = BOOL; r.b = x; return r; }
    static Val integer(int64_t x) { Val r; r.k = INT; r.i = x; return r; }
    static Val num(double x) { Val r; r.k = FLOAT; r.d = x; return r; }
    static Val str(std::string x) { Val r; r.k = STR; r.s = std::move(x); return r; }
    static Val vec(std::vector<double> x, bool ints = false) {
        Val r; r.k = VEC; r.v = std::move(x); r.v_int = ints; return r;
    }
    static Val ivec(const std::vector<int64_t>& x) {
        Val r; r.k = VEC; r.v_int = true; r.v.reserve(x.size());
        for (auto e : x) r.v.push_back((double)e);
        return r;
    }
    static Val list(std::vector<Val> x) { Val r; r.k = LIST; r.items = std::move(x); return r; }

    bool is_num() const { return k == BOOL || k == INT || k == FLOAT; }
    bool is_seq() const { return k == VEC || k == LIST; }
    double as_double() const { return k == FLOAT ? d : k == INT ? (double)i : k == BOOL ? (b ? 1.0 : 0.0) : 0.0; }
    size_t seq_len() const { return k == VEC ? v.size() : k == LIST ? items.size() : 0; }
};

using Fn = std::function<Val(std::vector<Val>&)>;

struct Op {
    Fn fn;
    std::vector<int> mutates;   // argument indices written back in place
};

// nullptr when `name` is not a shared tensor native.
const Op* find(const std::string& name);
std::vector<std::string> names();

} // namespace nt
