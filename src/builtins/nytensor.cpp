// builtins/nytensor.cpp — shared tensor kernels (see include/NyTensor.hpp)
// ─────────────────────────────────────────────────────────────────────────────
// Engine-neutral: nothing here knows about Value, Container or VMVal. Both the
// interpreter (tensor.cpp: dispatch_nt) and the VM (VirtualMachine.hpp:
// register_nt_natives) call nt::find(name)->fn(args), so every result is
// produced by this one compiled code path on both engines.
//
// Conventions for the nt_* family (the ND tensor natives):
//   * a tensor is passed as TWO arguments: flat row-major data, then shape.
//     Data may also be a bare number for a 0-d tensor (shape []).
//   * an op whose output shape differs from its input returns [data, shape];
//     an op whose output has the input's shape returns just the data.
//   * shapes, dims and indices must be integral; data may be ints or floats
//     (converted exactly — the interpreter used to read INTEGER elements
//     through the double member of the value union and get 0).
//   * shape mismatches raise ValueError, bad indices IndexError, bad argument
//     kinds TypeError, file problems IOError — never a silent wrong answer.

#include "NyTensor.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <numeric>
#include <random>
#include <sstream>
#include <unordered_map>

namespace nt {
namespace {

using Shape = std::vector<int64_t>;
using Vec = std::vector<double>;

thread_local const char* g_cur = "";

[[noreturn]] void fail(const std::string& type, const std::string& msg) {
    throw Error{type, std::string(g_cur) + ": " + msg};
}

std::string sstr(const Shape& s) {
    std::string r = "[";
    for (size_t i = 0; i < s.size(); i++) { if (i) r += ", "; r += std::to_string(s[i]); }
    return r + "]";
}

int64_t numel(const Shape& s) {
    int64_t n = 1;
    for (auto d : s) n *= d;
    return n;
}

// ── argument access ─────────────────────────────────────────────────────────
void need(const std::vector<Val>& a, size_t n, const char* sig) {
    if (a.size() < n) fail("TypeError", std::string("expected ") + sig);
}
bool is_none(const Val& v) { return v.k == Val::NONE; }
bool truthy(const Val& v) {
    switch (v.k) {
        case Val::NONE: return false;
        case Val::BOOL: return v.b;
        case Val::INT: return v.i != 0;
        case Val::FLOAT: return v.d != 0.0;
        case Val::STR: return !v.s.empty();
        default: return v.seq_len() > 0;
    }
}
double D(const Val& v, const char* what) {
    if (!v.is_num()) fail("TypeError", std::string(what) + " must be a number");
    return v.as_double();
}
double Dor(const std::vector<Val>& a, size_t i, double dflt, const char* what) {
    if (i >= a.size() || is_none(a[i])) return dflt;
    return D(a[i], what);
}
int64_t I(const Val& v, const char* what) {
    if (!v.is_num()) fail("TypeError", std::string(what) + " must be an integer");
    double x = v.as_double();
    if (x != std::floor(x) || !std::isfinite(x)) fail("TypeError", std::string(what) + " must be an integer, got " + std::to_string(x));
    return (int64_t)x;
}
int64_t Ior(const std::vector<Val>& a, size_t i, int64_t dflt, const char* what) {
    if (i >= a.size() || is_none(a[i])) return dflt;
    return I(a[i], what);
}
std::string Sstr(const Val& v, const char* what) {
    if (v.k != Val::STR) fail("TypeError", std::string(what) + " must be a string");
    return v.s;
}
// Flat numeric data. A bare number is a 0-d tensor's data; an empty list is
// an empty tensor.
Vec& V(Val& v, const char* what) {
    if (v.k == Val::VEC) return v.v;
    if (v.is_num()) { double x = v.as_double(); v = Val::vec({x}); return v.v; }
    if (v.k == Val::LIST && v.items.empty()) { v = Val::vec({}); return v.v; }
    fail("TypeError", std::string(what) + " must be a flat list of numbers");
}
// List of integers (shape, dims, indices). A bare integer is a 1-list.
std::vector<int64_t> IV(const Val& v, const char* what) {
    std::vector<int64_t> r;
    if (v.k == Val::NONE) return r;
    if (v.is_num()) { r.push_back(I(v, what)); return r; }
    if (v.k == Val::LIST && v.items.empty()) return r;
    if (v.k != Val::VEC) fail("TypeError", std::string(what) + " must be a list of integers");
    r.reserve(v.v.size());
    for (double x : v.v) {
        if (x != std::floor(x) || !std::isfinite(x)) fail("TypeError", std::string(what) + " must contain integers");
        r.push_back((int64_t)x);
    }
    return r;
}
Shape SH(const Val& v, const char* what) {
    if (v.is_num()) fail("TypeError", std::string(what) + " must be a list of dimension sizes (use [] for a scalar)");
    Shape s = IV(v, what);
    for (auto d : s) if (d < 0) fail("ValueError", std::string(what) + " has a negative dimension: " + sstr(s));
    return s;
}
// (data, shape) pair with a consistency check.
struct T { Vec* d; Shape s; };
T TS(std::vector<Val>& a, size_t i, const char* what) {
    need(a, i + 2, (std::string(what) + " data and shape").c_str());
    T t; t.d = &V(a[i], what); t.s = SH(a[i + 1], what);
    if ((int64_t)t.d->size() != numel(t.s))
        fail("ValueError", std::string(what) + " has " + std::to_string(t.d->size()) +
             " elements but shape " + sstr(t.s) + " needs " + std::to_string(numel(t.s)));
    return t;
}
int64_t norm_dim(int64_t d, int64_t nd, const char* what = "dim") {
    int64_t n = nd == 0 ? 1 : nd;
    if (d < -n || d >= n) fail("IndexError", std::string(what) + " " + std::to_string(d) + " out of range for a " + std::to_string(nd) + "-d tensor");
    return d < 0 ? d + n : d;
}
Val pair(Vec&& d, const Shape& s) {
    std::vector<Val> r;
    r.push_back(Val::vec(std::move(d)));
    r.push_back(Val::ivec(s));
    return Val::list(std::move(r));
}
std::vector<int64_t> contiguous_strides(const Shape& s) {
    std::vector<int64_t> st(s.size(), 1);
    for (int64_t i = (int64_t)s.size() - 2; i >= 0; --i) st[i] = st[i + 1] * s[i + 1];
    return st;
}

// ── broadcasting ────────────────────────────────────────────────────────────
Shape bshape(const Shape& a, const Shape& b) {
    size_t n = std::max(a.size(), b.size());
    Shape r(n);
    for (size_t i = 0; i < n; i++) {
        int64_t da = i < n - a.size() ? 1 : a[i - (n - a.size())];
        int64_t db = i < n - b.size() ? 1 : b[i - (n - b.size())];
        if (da == db || db == 1) r[i] = da;
        else if (da == 1) r[i] = db;
        else fail("ValueError", "shapes " + sstr(a) + " and " + sstr(b) + " are not broadcastable (dimension " +
                  std::to_string(i) + ": " + std::to_string(da) + " vs " + std::to_string(db) + ")");
    }
    return r;
}
// Strides of `s` read as a tensor of rank out.size(): 0 along broadcast dims.
std::vector<int64_t> bstrides(const Shape& s, const Shape& out) {
    std::vector<int64_t> st(out.size(), 0);
    auto cs = contiguous_strides(s);
    size_t off = out.size() - s.size();
    for (size_t i = 0; i < s.size(); i++) st[off + i] = s[i] == 1 ? 0 : cs[i];
    return st;
}
// Walk every element of `out` (odometer over its dims) and report the
// matching offsets into operands with strides sa and sb.
template <class F>
void walk2(const Shape& os, const std::vector<int64_t>& sa, const std::vector<int64_t>& sb, F f) {
    int64_t n = numel(os);
    if (n == 0) return;
    int64_t nd = (int64_t)os.size();
    if (nd == 0) { f(0, 0, 0, 1, 0, 0); return; }
    int64_t last = os[nd - 1], ia = sa[nd - 1], ib = sb[nd - 1];
    std::vector<int64_t> idx(nd, 0);
    int64_t oa = 0, ob = 0;
    for (int64_t o = 0; o < n; o += last) {
        f(o, oa, ob, last, ia, ib);
        for (int64_t d = nd - 2; d >= 0; --d) {
            idx[d]++; oa += sa[d]; ob += sb[d];
            if (idx[d] < os[d]) break;
            oa -= sa[d] * os[d]; ob -= sb[d] * os[d]; idx[d] = 0;
        }
    }
}
template <class F>
Vec bmap(const Vec& a, const Shape& as, const Vec& b, const Shape& bs, Shape& os, F f) {
    os = bshape(as, bs);
    Vec out((size_t)numel(os));
    if (as == bs) { for (size_t i = 0; i < out.size(); i++) out[i] = f(a[i], b[i]); return out; }
    if (b.size() == 1 && (int64_t)a.size() == numel(os)) { double y = b[0]; for (size_t i = 0; i < out.size(); i++) out[i] = f(a[i], y); return out; }
    if (a.size() == 1 && (int64_t)b.size() == numel(os)) { double x = a[0]; for (size_t i = 0; i < out.size(); i++) out[i] = f(x, b[i]); return out; }
    auto sa = bstrides(as, os), sb = bstrides(bs, os);
    walk2(os, sa, sb, [&](int64_t o, int64_t oa, int64_t ob, int64_t len, int64_t ia, int64_t ib) {
        for (int64_t j = 0; j < len; j++) out[o + j] = f(a[oa + j * ia], b[ob + j * ib]);
    });
    return out;
}
// Broadcast x (shape xs) up to shape ts.
Vec expand_to(const Vec& x, const Shape& xs, const Shape& ts) {
    Shape chk = bshape(xs, ts);
    if (chk != ts) fail("ValueError", "cannot expand shape " + sstr(xs) + " to " + sstr(ts));
    Vec out((size_t)numel(ts));
    if (xs == ts) return x;
    auto sx = bstrides(xs, ts);
    std::vector<int64_t> zero(ts.size(), 0);
    walk2(ts, sx, zero, [&](int64_t o, int64_t ox, int64_t, int64_t len, int64_t ix, int64_t) {
        for (int64_t j = 0; j < len; j++) out[o + j] = x[ox + j * ix];
    });
    return out;
}
// Reverse of broadcasting: sum g (shape gs) down to shape ts.
Vec sum_to(const Vec& g, const Shape& gs, const Shape& ts) {
    if (gs == ts) return g;
    Shape chk = bshape(ts, gs);
    if (chk != gs) fail("ValueError", "cannot reduce shape " + sstr(gs) + " to " + sstr(ts));
    Vec out((size_t)numel(ts), 0.0);
    auto st = bstrides(ts, gs);
    std::vector<int64_t> zero(gs.size(), 0);
    walk2(gs, st, zero, [&](int64_t o, int64_t ot, int64_t, int64_t len, int64_t it, int64_t) {
        for (int64_t j = 0; j < len; j++) out[ot + j * it] += g[o + j];
    });
    return out;
}

// ── elementwise ─────────────────────────────────────────────────────────────
double sigm(double x) { if (x >= 0) { double z = std::exp(-x); return 1.0 / (1.0 + z); } double z = std::exp(x); return z / (1.0 + z); }
double softplus(double x) { return x > 20.0 ? x : (x < -20.0 ? std::exp(x) : std::log1p(std::exp(x))); }
const double SQRT1_2 = 0.70710678118654752440;
const double INV_SQRT_2PI = 0.39894228040143267794;

using BinF = double (*)(double, double);
BinF bin_fn(const std::string& op) {
    static const std::unordered_map<std::string, BinF> m = {
        {"add", [](double x, double y) { return x + y; }},
        {"sub", [](double x, double y) { return x - y; }},
        {"mul", [](double x, double y) { return x * y; }},
        {"div", [](double x, double y) { return x / y; }},
        {"pow", [](double x, double y) { return std::pow(x, y); }},
        {"max", [](double x, double y) { return (x != x || x >= y) ? x : y; }},
        {"min", [](double x, double y) { return (x != x || x <= y) ? x : y; }},
        {"eq", [](double x, double y) { return x == y ? 1.0 : 0.0; }},
        {"ne", [](double x, double y) { return x != y ? 1.0 : 0.0; }},
        {"lt", [](double x, double y) { return x < y ? 1.0 : 0.0; }},
        {"le", [](double x, double y) { return x <= y ? 1.0 : 0.0; }},
        {"gt", [](double x, double y) { return x > y ? 1.0 : 0.0; }},
        {"ge", [](double x, double y) { return x >= y ? 1.0 : 0.0; }},
        {"atan2", [](double x, double y) { return std::atan2(x, y); }},
        {"fmod", [](double x, double y) { return std::fmod(x, y); }},
        {"floordiv", [](double x, double y) { return std::floor(x / y); }},
    };
    auto it = m.find(op);
    if (it == m.end()) fail("ValueError", "unknown binary op '" + op + "'");
    return it->second;
}
using UnF = double (*)(double);
UnF un_fn(const std::string& op) {
    static const std::unordered_map<std::string, UnF> m = {
        {"neg", [](double x) { return -x; }},
        {"exp", [](double x) { return std::exp(x); }},
        {"log", [](double x) { return std::log(x); }},
        {"log1p", [](double x) { return std::log1p(x); }},
        {"expm1", [](double x) { return std::expm1(x); }},
        {"sqrt", [](double x) { return std::sqrt(x); }},
        {"rsqrt", [](double x) { return 1.0 / std::sqrt(x); }},
        {"abs", [](double x) { return std::fabs(x); }},
        {"relu", [](double x) { return x > 0 ? x : 0.0; }},
        {"sigmoid", [](double x) { return sigm(x); }},
        {"tanh", [](double x) { return std::tanh(x); }},
        {"gelu", [](double x) { return 0.5 * x * (1.0 + std::erf(x * SQRT1_2)); }},
        {"gelu_tanh", [](double x) { return 0.5 * x * (1.0 + std::tanh(0.7978845608028654 * (x + 0.044715 * x * x * x))); }},
        {"silu", [](double x) { return x * sigm(x); }},
        {"softplus", [](double x) { return softplus(x); }},
        {"mish", [](double x) { return x * std::tanh(softplus(x)); }},
        {"sin", [](double x) { return std::sin(x); }},
        {"cos", [](double x) { return std::cos(x); }},
        {"tan", [](double x) { return std::tan(x); }},
        {"sign", [](double x) { return x > 0 ? 1.0 : (x < 0 ? -1.0 : 0.0); }},
        {"reciprocal", [](double x) { return 1.0 / x; }},
        {"square", [](double x) { return x * x; }},
        {"floor", [](double x) { return std::floor(x); }},
        {"ceil", [](double x) { return std::ceil(x); }},
        {"round", [](double x) { return std::nearbyint(x); }},
        {"trunc", [](double x) { return std::trunc(x); }},
        {"erf", [](double x) { return std::erf(x); }},
        {"isnan", [](double x) { return x != x ? 1.0 : 0.0; }},
        {"hardsigmoid", [](double x) { return x <= -3 ? 0.0 : (x >= 3 ? 1.0 : x / 6.0 + 0.5); }},
        {"hardswish", [](double x) { return x <= -3 ? 0.0 : (x >= 3 ? x : x * (x + 3.0) / 6.0); }},
        {"softsign", [](double x) { return x / (1.0 + std::fabs(x)); }},
        {"logsigmoid", [](double x) { return -softplus(-x); }},
    };
    auto it = m.find(op);
    if (it == m.end()) fail("ValueError", "unknown unary op '" + op + "'");
    return it->second;
}
// d(op(x))/dx * g, given x, y = op(x) and upstream g.
double un_grad(const std::string& op, double x, double y, double g) {
    if (op == "neg") return -g;
    if (op == "exp") return g * y;
    if (op == "log") return g / x;
    if (op == "log1p") return g / (1.0 + x);
    if (op == "expm1") return g * (y + 1.0);
    if (op == "sqrt") return g * 0.5 / y;
    if (op == "rsqrt") return g * -0.5 * y * y * y;
    if (op == "abs") return g * (x > 0 ? 1.0 : (x < 0 ? -1.0 : 0.0));
    if (op == "relu") return x > 0 ? g : 0.0;
    if (op == "sigmoid") return g * y * (1.0 - y);
    if (op == "tanh") return g * (1.0 - y * y);
    if (op == "gelu") return g * (0.5 * (1.0 + std::erf(x * SQRT1_2)) + x * INV_SQRT_2PI * std::exp(-0.5 * x * x));
    if (op == "gelu_tanh") {
        double k = 0.7978845608028654, u = k * (x + 0.044715 * x * x * x), t = std::tanh(u);
        return g * (0.5 * (1.0 + t) + 0.5 * x * (1.0 - t * t) * k * (1.0 + 3 * 0.044715 * x * x));
    }
    if (op == "silu") { double s = sigm(x); return g * s * (1.0 + x * (1.0 - s)); }
    if (op == "softplus") return g * sigm(x);
    if (op == "mish") { double sp = softplus(x), t = std::tanh(sp); return g * (t + x * (1.0 - t * t) * sigm(x)); }
    if (op == "sin") return g * std::cos(x);
    if (op == "cos") return -g * std::sin(x);
    if (op == "tan") return g * (1.0 + y * y);
    if (op == "reciprocal") return -g * y * y;
    if (op == "square") return g * 2.0 * x;
    if (op == "erf") return g * 2.0 / std::sqrt(M_PI) * std::exp(-x * x);
    if (op == "hardsigmoid") return (x > -3 && x < 3) ? g / 6.0 : 0.0;
    if (op == "hardswish") return x <= -3 ? 0.0 : (x >= 3 ? g : g * (2.0 * x + 3.0) / 6.0);
    if (op == "softsign") { double d = 1.0 + std::fabs(x); return g / (d * d); }
    if (op == "logsigmoid") return g * sigm(-x);
    if (op == "sign" || op == "floor" || op == "ceil" || op == "round" || op == "trunc" || op == "isnan") return 0.0;
    fail("ValueError", "no gradient rule for unary op '" + op + "'");
}
double un_s(const std::string& op, double x, double s) {
    if (op == "pow") return std::pow(x, s);
    if (op == "leaky_relu") return x > 0 ? x : s * x;
    if (op == "elu") return x > 0 ? x : s * (std::exp(x) - 1.0);
    if (op == "celu") return x > 0 ? x : s * (std::exp(x / s) - 1.0);
    if (op == "clamp_min") return x < s ? s : x;
    if (op == "clamp_max") return x > s ? s : x;
    if (op == "hardshrink") return (x > s || x < -s) ? x : 0.0;
    if (op == "softshrink") return x > s ? x - s : (x < -s ? x + s : 0.0);
    if (op == "threshold") return x > s ? x : 0.0;
    fail("ValueError", "unknown scalar op '" + op + "'");
}
double un_s_grad(const std::string& op, double x, double y, double s, double g) {
    if (op == "pow") return s == 0.0 ? 0.0 : g * s * std::pow(x, s - 1.0);
    if (op == "leaky_relu") return x > 0 ? g : g * s;
    if (op == "elu") return x > 0 ? g : g * (y + s);
    if (op == "celu") return x > 0 ? g : g * std::exp(x / s);
    if (op == "clamp_min") return x < s ? 0.0 : g;
    if (op == "clamp_max") return x > s ? 0.0 : g;
    if (op == "hardshrink") return (x > s || x < -s) ? g : 0.0;
    if (op == "softshrink") return (x > s || x < -s) ? g : 0.0;
    if (op == "threshold") return x > s ? g : 0.0;
    fail("ValueError", "no gradient rule for scalar op '" + op + "'");
}

// ── reductions ──────────────────────────────────────────────────────────────
struct Red {
    Shape keep;                 // output shape with reduced dims kept as 1
    Shape out;                  // output shape without them (or keep, if keepdim)
    std::vector<char> red;      // per input dim: reduced?
    std::vector<int64_t> ost;   // per input dim: stride into the output, 0 if reduced
    int64_t count = 1;          // elements folded into each output
};
Red plan_reduce(const Shape& s, const Val& dimsv, bool keepdim) {
    Red r;
    int64_t nd = (int64_t)s.size();
    r.red.assign(nd, 0);
    if (is_none(dimsv)) { for (auto& x : r.red) x = 1; }
    else {
        auto dims = IV(dimsv, "dim");
        if (dims.empty()) { for (auto& x : r.red) x = 1; }
        for (auto d : dims) {
            if (nd == 0) { norm_dim(d, 0); continue; }
            r.red[norm_dim(d, nd)] = 1;
        }
    }
    r.keep = s;
    for (int64_t d = 0; d < nd; d++) if (r.red[d]) { r.count *= s[d]; r.keep[d] = 1; }
    auto ks = contiguous_strides(r.keep);
    r.ost.assign(nd, 0);
    for (int64_t d = 0; d < nd; d++) r.ost[d] = r.red[d] ? 0 : ks[d];
    if (keepdim) r.out = r.keep;
    else for (int64_t d = 0; d < nd; d++) if (!r.red[d]) r.out.push_back(s[d]);
    return r;
}
// Call f(input_index, output_index, coordinate along `track` dim) for every input element.
template <class F>
void walk_red(const Shape& s, const Red& r, F f, int64_t track = -1) {
    int64_t n = numel(s), nd = (int64_t)s.size();
    if (n == 0) return;
    if (nd == 0) { f(0, 0, 0); return; }
    std::vector<int64_t> idx(nd, 0);
    int64_t o = 0;
    for (int64_t i = 0; i < n; i++) {
        f(i, o, track >= 0 ? idx[track] : 0);
        for (int64_t d = nd - 1; d >= 0; --d) {
            idx[d]++; o += r.ost[d];
            if (idx[d] < s[d]) break;
            o -= r.ost[d] * s[d]; idx[d] = 0;
        }
    }
}
Vec reduce(const std::string& op, const Vec& x, const Shape& s, const Red& r, double correction) {
    int64_t no = numel(r.keep);
    Vec out((size_t)no, 0.0);
    if (op == "sum" || op == "mean") {
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { out[o] += x[i]; });
        if (op == "mean") for (auto& v : out) v /= (double)r.count;
    } else if (op == "prod") {
        std::fill(out.begin(), out.end(), 1.0);
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { out[o] *= x[i]; });
    } else if (op == "max" || op == "min" || op == "amax" || op == "amin") {
        if (r.count == 0) fail("ValueError", op + " of an empty tensor (no identity value)");
        bool mx = op == "max" || op == "amax";
        std::vector<char> seen((size_t)no, 0);
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) {
            double v = x[i];
            if (!seen[o]) { out[o] = v; seen[o] = 1; return; }
            if (out[o] != out[o]) return;                       // NaN propagates
            if (v != v || (mx ? v > out[o] : v < out[o])) out[o] = v;
        });
    } else if (op == "argmax" || op == "argmin") {
        if (r.count == 0) fail("ValueError", op + " of an empty tensor");
        bool mx = op == "argmax";
        Vec best((size_t)no, 0.0);
        std::vector<char> seen((size_t)no, 0);
        // The position reported is the flat index within the reduced dims
        // (the coordinate along the dim when exactly one dim is reduced).
        std::vector<int64_t> pos((size_t)no, 0);
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) {
            double v = x[i];
            int64_t p = pos[o]++;
            if (!seen[o] || (best[o] == best[o] && (v != v || (mx ? v > best[o] : v < best[o])))) {
                best[o] = v; out[o] = (double)p; seen[o] = 1;
            }
        });
    } else if (op == "var" || op == "std") {
        Vec mean((size_t)no, 0.0);
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { mean[o] += x[i]; });
        for (auto& m : mean) m /= (double)r.count;
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { double d = x[i] - mean[o]; out[o] += d * d; });
        double den = (double)r.count - correction;
        for (auto& v : out) { v = den > 0 ? v / den : std::numeric_limits<double>::quiet_NaN(); if (op == "std") v = std::sqrt(v); }
    } else if (op == "logsumexp") {
        Vec mx((size_t)no, -std::numeric_limits<double>::infinity());
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { if (x[i] > mx[o]) mx[o] = x[i]; });
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { if (std::isfinite(mx[o])) out[o] += std::exp(x[i] - mx[o]); });
        for (int64_t o = 0; o < no; o++) out[o] = std::isfinite(mx[o]) ? mx[o] + std::log(out[o]) : mx[o];
    } else if (op == "norm") {
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { out[o] += x[i] * x[i]; });
        for (auto& v : out) v = std::sqrt(v);
    } else if (op == "count_nonzero") {
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { if (x[i] != 0) out[o] += 1; });
    } else fail("ValueError", "unknown reduction '" + op + "'");
    return out;
}
Vec reduce_bw(const std::string& op, const Vec& x, const Shape& s, const Red& r, const Vec& g, const Vec& y, double correction) {
    int64_t no = numel(r.keep);
    if ((int64_t)g.size() != no) fail("ValueError", "gradient has " + std::to_string(g.size()) + " elements, reduction output has " + std::to_string(no));
    Vec dx(x.size(), 0.0);
    if (op == "sum") walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { dx[i] = g[o]; });
    else if (op == "mean") walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { dx[i] = g[o] / (double)r.count; });
    else if (op == "max" || op == "min" || op == "amax" || op == "amin") {
        // Gradient goes to the first element equal to the result (the one
        // argmax/argmin report), matching torch.max(dim)'s indices.
        std::vector<char> taken((size_t)no, 0);
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { if (!taken[o] && x[i] == y[o]) { dx[i] = g[o]; taken[o] = 1; } });
    } else if (op == "prod") {
        Vec nz((size_t)no, 1.0); std::vector<int> zeros((size_t)no, 0);
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { if (x[i] == 0) zeros[o]++; else nz[o] *= x[i]; });
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) {
            if (zeros[o] == 0) dx[i] = g[o] * y[o] / x[i];
            else if (zeros[o] == 1 && x[i] == 0) dx[i] = g[o] * nz[o];
        });
    } else if (op == "var" || op == "std") {
        Vec mean((size_t)no, 0.0);
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { mean[o] += x[i]; });
        for (auto& m : mean) m /= (double)r.count;
        double den = (double)r.count - correction;
        walk_red(s, r, [&](int64_t i, int64_t o, int64_t) {
            double d = x[i] - mean[o];
            if (op == "var") dx[i] = g[o] * 2.0 * d / den;
            else dx[i] = y[o] > 0 ? g[o] * d / (den * y[o]) : 0.0;
        });
    } else if (op == "logsumexp") walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { dx[i] = g[o] * std::exp(x[i] - y[o]); });
    else if (op == "norm") walk_red(s, r, [&](int64_t i, int64_t o, int64_t) { dx[i] = y[o] > 0 ? g[o] * x[i] / y[o] : 0.0; });
    else fail("ValueError", "no gradient rule for reduction '" + op + "'");
    return dx;
}

// ── matrix multiply ─────────────────────────────────────────────────────────
// C[m,n] (+)= A[m,k] B[k,n]. i-p-j order, blocked over p and j so a panel of
// B stays in cache; every C[i,j] still accumulates p in ascending order, so
// the result does not depend on the block sizes.
void mm(const double* A, const double* B, double* C, int64_t m, int64_t k, int64_t n, bool acc) {
    if (!acc) std::fill(C, C + m * n, 0.0);
    const int64_t BP = 64, BJ = 512;
    for (int64_t j0 = 0; j0 < n; j0 += BJ) {
        int64_t j1 = std::min(n, j0 + BJ);
        for (int64_t p0 = 0; p0 < k; p0 += BP) {
            int64_t p1 = std::min(k, p0 + BP);
            for (int64_t i = 0; i < m; i++) {
                double* c = C + i * n;
                const double* a = A + i * k;
                for (int64_t p = p0; p < p1; p++) {
                    double av = a[p];
                    const double* b = B + p * n;
                    for (int64_t j = j0; j < j1; j++) c[j] += av * b[j];
                }
            }
        }
    }
}
// C[m,k] (+)= A[m,n] * B[k,n]^T
void mm_bt(const double* A, const double* B, double* C, int64_t m, int64_t n, int64_t k, bool acc) {
    if (!acc) std::fill(C, C + m * k, 0.0);
    for (int64_t i = 0; i < m; i++) {
        const double* a = A + i * n;
        for (int64_t p = 0; p < k; p++) {
            const double* b = B + p * n;
            double s = 0;
            for (int64_t j = 0; j < n; j++) s += a[j] * b[j];
            C[i * k + p] += s;
        }
    }
}
// C[k,n] (+)= A[m,k]^T * B[m,n]
void mm_at(const double* A, const double* B, double* C, int64_t m, int64_t k, int64_t n, bool acc) {
    if (!acc) std::fill(C, C + k * n, 0.0);
    for (int64_t i = 0; i < m; i++) {
        const double* a = A + i * k;
        const double* b = B + i * n;
        for (int64_t p = 0; p < k; p++) {
            double av = a[p];
            double* c = C + p * n;
            for (int64_t j = 0; j < n; j++) c[j] += av * b[j];
        }
    }
}
struct MM {
    Shape a2, b2;               // operands as >=2-d (1-d promoted)
    Shape batch;                // broadcast batch shape
    Shape out;                  // result shape (promoted dims removed)
    int64_t m, k, n;
    std::vector<int64_t> sa, sb; // batch strides in units of matrices (0 = broadcast)
};
MM plan_mm(const Shape& as, const Shape& bs) {
    if (as.empty() || bs.empty()) fail("ValueError", "matmul needs at least 1-d operands, got " + sstr(as) + " and " + sstr(bs));
    MM p;
    p.a2 = as.size() == 1 ? Shape{1, as[0]} : as;
    p.b2 = bs.size() == 1 ? Shape{bs[0], 1} : bs;
    p.m = p.a2[p.a2.size() - 2]; p.k = p.a2.back();
    int64_t kb = p.b2[p.b2.size() - 2]; p.n = p.b2.back();
    if (p.k != kb) fail("ValueError", "shapes " + sstr(as) + " and " + sstr(bs) + " cannot be multiplied (" +
                         std::to_string(p.k) + " != " + std::to_string(kb) + ")");
    Shape ab(p.a2.begin(), p.a2.end() - 2), bb(p.b2.begin(), p.b2.end() - 2);
    p.batch = bshape(ab, bb);
    p.sa = bstrides(ab, p.batch); p.sb = bstrides(bb, p.batch);
    p.out = p.batch;
    if (as.size() > 1) p.out.push_back(p.m);
    if (bs.size() > 1) p.out.push_back(p.n);
    return p;
}
template <class F>
void walk_batch(const MM& p, F f) {
    std::vector<int64_t> zero(p.batch.size(), 0);
    int64_t nb = numel(p.batch);
    if (p.batch.empty()) { f(0, 0, 0); return; }
    // Enumerate batch indices one at a time (walk2 hands us runs along the
    // last batch dim; expand them).
    walk2(p.batch, p.sa, p.sb, [&](int64_t o, int64_t oa, int64_t ob, int64_t len, int64_t ia, int64_t ib) {
        for (int64_t j = 0; j < len; j++) f(o + j, oa + j * ia, ob + j * ib);
    });
    (void)nb;
}
Vec matmul(const Vec& a, const Shape& as, const Vec& b, const Shape& bs, Shape& os) {
    MM p = plan_mm(as, bs);
    os = p.out;
    Vec out((size_t)(numel(p.batch) * p.m * p.n), 0.0);
    int64_t szA = p.m * p.k, szB = p.k * p.n, szC = p.m * p.n;
    walk_batch(p, [&](int64_t o, int64_t ia, int64_t ib) {
        mm(a.data() + ia * szA, b.data() + ib * szB, out.data() + o * szC, p.m, p.k, p.n, false);
    });
    return out;
}
void matmul_bw(const Vec& a, const Shape& as, const Vec& b, const Shape& bs, const Vec& g, Vec& da, Vec& db) {
    MM p = plan_mm(as, bs);
    int64_t szA = p.m * p.k, szB = p.k * p.n, szC = p.m * p.n;
    if ((int64_t)g.size() != numel(p.batch) * szC) fail("ValueError", "matmul gradient has the wrong size");
    da.assign(a.size(), 0.0); db.assign(b.size(), 0.0);
    walk_batch(p, [&](int64_t o, int64_t ia, int64_t ib) {
        const double* G = g.data() + o * szC;
        mm_bt(G, b.data() + ib * szB, da.data() + ia * szA, p.m, p.n, p.k, true);   // dA += G B^T
        mm_at(a.data() + ia * szA, G, db.data() + ib * szB, p.m, p.k, p.n, true);   // dB += A^T G
    });
}

// ── layout ops ──────────────────────────────────────────────────────────────
Vec permute(const Vec& x, const Shape& s, const std::vector<int64_t>& dims_in, Shape& os) {
    int64_t nd = (int64_t)s.size();
    if ((int64_t)dims_in.size() != nd) fail("ValueError", "permute needs " + std::to_string(nd) + " dims, got " + std::to_string(dims_in.size()));
    std::vector<int64_t> dims(nd);
    std::vector<char> used(nd, 0);
    for (int64_t i = 0; i < nd; i++) {
        int64_t d = norm_dim(dims_in[i], nd);
        if (used[d]) fail("ValueError", "permute: repeated dim " + std::to_string(d));
        used[d] = 1; dims[i] = d;
    }
    auto st = contiguous_strides(s);
    os.resize(nd);
    std::vector<int64_t> pst(nd);
    for (int64_t i = 0; i < nd; i++) { os[i] = s[dims[i]]; pst[i] = st[dims[i]]; }
    Vec out(x.size());
    std::vector<int64_t> zero(nd, 0);
    walk2(os, pst, zero, [&](int64_t o, int64_t ox, int64_t, int64_t len, int64_t ix, int64_t) {
        for (int64_t j = 0; j < len; j++) out[o + j] = x[ox + j * ix];
    });
    return out;
}
void outer_inner(const Shape& s, int64_t dim, int64_t& outer, int64_t& n, int64_t& inner) {
    outer = 1; inner = 1; n = s.empty() ? 1 : s[dim];
    for (int64_t d = 0; d < dim; d++) outer *= s[d];
    for (int64_t d = dim + 1; d < (int64_t)s.size(); d++) inner *= s[d];
}
struct SliceSpec { int64_t start, stop, step, len; };
SliceSpec slice_spec(int64_t n, const Val& a, const Val& b, const Val& c) {
    SliceSpec r;
    r.step = is_none(c) ? 1 : I(c, "step");
    if (r.step <= 0) fail("ValueError", "slice step must be positive");
    r.start = is_none(a) ? 0 : I(a, "start");
    r.stop = is_none(b) ? n : I(b, "stop");
    if (r.start < 0) r.start += n;
    if (r.stop < 0) r.stop += n;
    r.start = std::max<int64_t>(0, std::min(r.start, n));
    r.stop = std::max<int64_t>(0, std::min(r.stop, n));
    r.len = r.stop > r.start ? (r.stop - r.start + r.step - 1) / r.step : 0;
    return r;
}

// ── softmax ─────────────────────────────────────────────────────────────────
Vec softmax(const Vec& x, const Shape& s, int64_t dim, bool logv) {
    int64_t outer, n, inner;
    outer_inner(s, dim, outer, n, inner);
    Vec y(x.size());
    for (int64_t o = 0; o < outer; o++)
        for (int64_t in = 0; in < inner; in++) {
            int64_t base = o * n * inner + in;
            double mx = -std::numeric_limits<double>::infinity();
            for (int64_t j = 0; j < n; j++) mx = std::max(mx, x[base + j * inner]);
            double sum = 0;
            for (int64_t j = 0; j < n; j++) sum += std::exp(x[base + j * inner] - mx);
            double ls = std::log(sum);
            for (int64_t j = 0; j < n; j++) {
                double v = x[base + j * inner];
                y[base + j * inner] = logv ? (v - mx) - ls : std::exp(v - mx) / sum;
            }
        }
    return y;
}
Vec softmax_bw(const Vec& y, const Vec& g, const Shape& s, int64_t dim, bool logv) {
    int64_t outer, n, inner;
    outer_inner(s, dim, outer, n, inner);
    Vec dx(y.size());
    for (int64_t o = 0; o < outer; o++)
        for (int64_t in = 0; in < inner; in++) {
            int64_t base = o * n * inner + in;
            double acc = 0;
            for (int64_t j = 0; j < n; j++) acc += logv ? g[base + j * inner] : g[base + j * inner] * y[base + j * inner];
            for (int64_t j = 0; j < n; j++) {
                int64_t q = base + j * inner;
                dx[q] = logv ? g[q] - std::exp(y[q]) * acc : y[q] * (g[q] - acc);
            }
        }
    return dx;
}

// ── RNG ─────────────────────────────────────────────────────────────────────
// One generator for every random native on both engines, seeded once from
// the clock and random_device (the VM used to reseed rand() from time() on
// every call, so every randn within the same second returned the same
// numbers). manual_seed() makes runs reproducible — and, because both
// engines share this generator and these formulas, identical across engines.
std::mt19937_64& rng() {
    static std::mt19937_64 g([] {
        std::random_device rd;
        uint64_t s = ((uint64_t)rd() << 32) ^ rd();
        s ^= (uint64_t)std::chrono::high_resolution_clock::now().time_since_epoch().count();
        return s;
    }());
    return g;
}
double unif() { return (double)(rng()() >> 11) * (1.0 / 9007199254740992.0); }
double normal() {
    // Box-Muller, one draw per call (no cached spare, so the sequence only
    // depends on the seed and the number of draws).
    double u1 = unif(), u2 = unif();
    if (u1 < 1e-300) u1 = 1e-300;
    return std::sqrt(-2.0 * std::log(u1)) * std::cos(2.0 * M_PI * u2);
}
int64_t count_arg(const Val& v, const char* what) {
    // n, or a shape list whose product is n
    if (v.is_num()) { int64_t n = I(v, what); if (n < 0) fail("ValueError", std::string(what) + " must be >= 0"); return n; }
    return numel(SH(v, what));
}

// ── file format ─────────────────────────────────────────────────────────────
// NYTENSOR v2: "NYTENSOR" u32 version=2 u32 count, then per entry
//   u32 name_len, name, u32 ndim, i64 dims[ndim], u64 numel, f64 data[numel]
// float64 and the shape are preserved (v1 stored float32 and no shape, and
// wrote ints as 0). v1 files ('NYML' single tensor / 'NYMD' model) still load.
struct Entry { std::string name; Shape shape; Vec data; };
void save_entries(const std::string& path, const std::vector<Entry>& es) {
    std::ofstream f(path, std::ios::binary);
    if (!f.is_open()) fail("IOError", "cannot open '" + path + "' for writing");
    f.write("NYTENSOR", 8);
    uint32_t ver = 2, cnt = (uint32_t)es.size();
    f.write((const char*)&ver, 4); f.write((const char*)&cnt, 4);
    for (auto& e : es) {
        uint32_t nl = (uint32_t)e.name.size(); f.write((const char*)&nl, 4); f.write(e.name.data(), nl);
        uint32_t nd = (uint32_t)e.shape.size(); f.write((const char*)&nd, 4);
        for (auto d : e.shape) { int64_t dd = d; f.write((const char*)&dd, 8); }
        uint64_t n = e.data.size(); f.write((const char*)&n, 8);
        f.write((const char*)e.data.data(), (std::streamsize)(n * 8));
    }
    if (!f.good()) fail("IOError", "write to '" + path + "' failed");
}
bool load_entries(const std::string& path, std::vector<Entry>& es, bool missing_ok) {
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open()) { if (missing_ok) return false; fail("IOError", "cannot open '" + path + "'"); }
    char mg[8] = {0};
    f.read(mg, 4);
    if (f.gcount() != 4) fail("IOError", "'" + path + "' is empty or truncated");
    uint32_t m4; std::memcpy(&m4, mg, 4);
    auto rd32 = [&]() { uint32_t x = 0; f.read((char*)&x, 4); if (f.gcount() != 4) fail("IOError", "'" + path + "' is truncated"); return x; };
    if (m4 == 0x4E594D4C || m4 == 0x4E594D44) {             // v1: 'NYML' / 'NYMD'
        auto rdt = [&](const std::string& nm) {
            uint32_t n = rd32();
            Entry e; e.name = nm; e.shape = {(int64_t)n}; e.data.resize(n);
            for (uint32_t i = 0; i < n; i++) { float v; f.read((char*)&v, 4); if (f.gcount() != 4) fail("IOError", "'" + path + "' is truncated"); e.data[i] = v; }
            es.push_back(std::move(e));
        };
        if (m4 == 0x4E594D4C) rdt("0");
        else { uint32_t np = rd32(); for (uint32_t k = 0; k < np; k++) rdt(std::to_string(k)); }
        return true;
    }
    f.read(mg + 4, 4);
    if (std::string(mg, 8) != "NYTENSOR") fail("IOError", "'" + path + "' is not a nytorch tensor file");
    uint32_t ver = rd32();
    if (ver != 2) fail("IOError", "'" + path + "' has unsupported format version " + std::to_string(ver));
    uint32_t cnt = rd32();
    for (uint32_t k = 0; k < cnt; k++) {
        Entry e;
        uint32_t nl = rd32(); e.name.resize(nl); f.read(&e.name[0], nl);
        uint32_t nd = rd32();
        for (uint32_t d = 0; d < nd; d++) { int64_t x = 0; f.read((char*)&x, 8); e.shape.push_back(x); }
        uint64_t n = 0; f.read((char*)&n, 8);
        if (!f.good() || (int64_t)n != numel(e.shape)) fail("IOError", "'" + path + "' entry '" + e.name + "' is corrupt");
        e.data.resize(n);
        f.read((char*)e.data.data(), (std::streamsize)(n * 8));
        if ((uint64_t)f.gcount() != n * 8) fail("IOError", "'" + path + "' is truncated");
        es.push_back(std::move(e));
    }
    return true;
}

// ── audio ───────────────────────────────────────────────────────────────────
void fft_inplace(std::vector<double>& re, std::vector<double>& im) {
    size_t n = re.size();
    for (size_t i = 1, j = 0; i < n; i++) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        double ang = -2 * M_PI / (double)len;
        for (size_t i = 0; i < n; i += len)
            for (size_t j = 0; j < len / 2; j++) {
                double wr = std::cos(ang * (double)j), wi = std::sin(ang * (double)j);
                double ur = re[i + j], ui = im[i + j];
                double vr = re[i + j + len / 2] * wr - im[i + j + len / 2] * wi;
                double vi = re[i + j + len / 2] * wi + im[i + j + len / 2] * wr;
                re[i + j] = ur + vr; im[i + j] = ui + vi;
                re[i + j + len / 2] = ur - vr; im[i + j + len / 2] = ui - vi;
            }
    }
}
// Magnitude spectrogram, torch.stft layout [n_fft/2+1, frames], periodic
// Hann window; center=true reflect-pads n_fft/2 on each side like torch.
Vec stft_mag(const Vec& sig, int64_t n_fft, int64_t hop, bool center, int64_t& frames) {
    if (n_fft <= 0 || hop <= 0) fail("ValueError", "n_fft and hop must be positive");
    Vec x = sig;
    if (center) {
        int64_t p = n_fft / 2, L = (int64_t)sig.size();
        if (L <= p) fail("ValueError", "signal of length " + std::to_string(L) + " is too short to reflect-pad by " + std::to_string(p));
        x.assign((size_t)(L + 2 * p), 0.0);
        for (int64_t i = 0; i < L; i++) x[p + i] = sig[i];
        for (int64_t i = 0; i < p; i++) { x[p - 1 - i] = sig[i + 1]; x[p + L + i] = sig[L - 2 - i]; }
    }
    int64_t L = (int64_t)x.size();
    if (L < n_fft) fail("ValueError", "signal of length " + std::to_string(L) + " is shorter than n_fft " + std::to_string(n_fft));
    frames = (L - n_fft) / hop + 1;
    int64_t bins = n_fft / 2 + 1;
    Vec win((size_t)n_fft);
    for (int64_t i = 0; i < n_fft; i++) win[i] = 0.5 - 0.5 * std::cos(2 * M_PI * (double)i / (double)n_fft);
    Vec out((size_t)(bins * frames));
    bool pow2 = (n_fft & (n_fft - 1)) == 0;
    std::vector<double> re((size_t)n_fft), im((size_t)n_fft);
    for (int64_t t = 0; t < frames; t++) {
        for (int64_t i = 0; i < n_fft; i++) { re[i] = x[t * hop + i] * win[i]; im[i] = 0; }
        if (pow2) {
            fft_inplace(re, im);
            for (int64_t k = 0; k < bins; k++) out[k * frames + t] = std::sqrt(re[k] * re[k] + im[k] * im[k]);
        } else {
            for (int64_t k = 0; k < bins; k++) {
                double sr = 0, si = 0;
                for (int64_t i = 0; i < n_fft; i++) { double a = -2 * M_PI * (double)(k * i) / (double)n_fft; sr += re[i] * std::cos(a); si += re[i] * std::sin(a); }
                out[k * frames + t] = std::sqrt(sr * sr + si * si);
            }
        }
    }
    return out;
}
double hz2mel(double f) { return 2595.0 * std::log10(1.0 + f / 700.0); }
double mel2hz(double m) { return 700.0 * (std::pow(10.0, m / 2595.0) - 1.0); }
// torchaudio.functional.melscale_fbanks(norm=None, mel_scale="htk"),
// transposed to [n_mels, n_freqs].
Vec mel_fbank(int64_t n_mels, int64_t n_freqs, double sr, double fmin, double fmax) {
    if (n_mels <= 0 || n_freqs <= 0) fail("ValueError", "n_mels and n_freqs must be positive");
    Vec allf((size_t)n_freqs);
    for (int64_t i = 0; i < n_freqs; i++) allf[i] = n_freqs == 1 ? 0.0 : (sr / 2.0) * (double)i / (double)(n_freqs - 1);
    double mmin = hz2mel(fmin), mmax = hz2mel(fmax);
    Vec fpts((size_t)(n_mels + 2));
    for (int64_t i = 0; i < n_mels + 2; i++) fpts[i] = mel2hz(mmin + (mmax - mmin) * (double)i / (double)(n_mels + 1));
    Vec fb((size_t)(n_mels * n_freqs), 0.0);
    for (int64_t m = 0; m < n_mels; m++) {
        double d0 = fpts[m + 1] - fpts[m], d1 = fpts[m + 2] - fpts[m + 1];
        for (int64_t f = 0; f < n_freqs; f++) {
            double down = (allf[f] - fpts[m]) / d0;
            double up = (fpts[m + 2] - allf[f]) / d1;
            fb[m * n_freqs + f] = std::max(0.0, std::min(down, up));
        }
    }
    return fb;
}
// torchaudio.functional.create_dct(n_mfcc, n_mels, norm="ortho"), as [n_mfcc, n_mels].
Vec dct_matrix(int64_t n_mfcc, int64_t n) {
    Vec m((size_t)(n_mfcc * n));
    for (int64_t k = 0; k < n_mfcc; k++)
        for (int64_t i = 0; i < n; i++)
            m[k * n + i] = std::cos(M_PI / (double)n * ((double)i + 0.5) * (double)k) * (k == 0 ? std::sqrt(1.0 / n) : std::sqrt(2.0 / n));
    return m;
}

// ── CTC ─────────────────────────────────────────────────────────────────────
double lse2(double a, double b) {
    if (a == -INFINITY) return b;
    if (b == -INFINITY) return a;
    double m = std::max(a, b);
    return m + std::log(std::exp(a - m) + std::exp(b - m));
}
// Negative log-likelihood of `tgt` under per-frame log-probabilities lp[T,C]
// (Graves et al. 2006 forward-backward in log space), and its gradient with
// respect to lp.
double ctc(const Vec& lp, int64_t T, int64_t C, const std::vector<int64_t>& tgt, int64_t blank, Vec& grad) {
    int64_t L = (int64_t)tgt.size(), S = 2 * L + 1;
    for (auto t : tgt) {
        if (t < 0 || t >= C) fail("IndexError", "target label " + std::to_string(t) + " out of range for " + std::to_string(C) + " classes");
        if (t == blank) fail("ValueError", "target contains the blank label " + std::to_string(blank));
    }
    std::vector<int64_t> ext((size_t)S);
    for (int64_t s = 0; s < S; s++) ext[s] = s % 2 == 0 ? blank : tgt[s / 2];
    const double NI = -INFINITY;
    Vec la((size_t)(T * S), NI), lb((size_t)(T * S), NI);
    auto LP = [&](int64_t t, int64_t c) { return lp[t * C + c]; };
    if (T == 0) { grad.assign(0, 0); return L == 0 ? 0.0 : INFINITY; }
    la[0] = LP(0, blank);
    if (S > 1) la[1] = LP(0, ext[1]);
    for (int64_t t = 1; t < T; t++)
        for (int64_t s = 0; s < S; s++) {
            double v = la[(t - 1) * S + s];
            if (s >= 1) v = lse2(v, la[(t - 1) * S + s - 1]);
            if (s >= 2 && ext[s] != blank && ext[s] != ext[s - 2]) v = lse2(v, la[(t - 1) * S + s - 2]);
            la[t * S + s] = v == NI ? NI : v + LP(t, ext[s]);
        }
    // beta excludes the emission at t: P = sum_s alpha_t(s) beta_t(s) for every t.
    lb[(T - 1) * S + S - 1] = 0.0;
    if (S > 1) lb[(T - 1) * S + S - 2] = 0.0;
    for (int64_t t = T - 2; t >= 0; t--)
        for (int64_t s = 0; s < S; s++) {
            double v = lb[(t + 1) * S + s] == NI ? NI : lb[(t + 1) * S + s] + LP(t + 1, ext[s]);
            if (s + 1 < S && lb[(t + 1) * S + s + 1] != NI) v = lse2(v, lb[(t + 1) * S + s + 1] + LP(t + 1, ext[s + 1]));
            if (s + 2 < S && ext[s + 2] != blank && ext[s + 2] != ext[s] && lb[(t + 1) * S + s + 2] != NI)
                v = lse2(v, lb[(t + 1) * S + s + 2] + LP(t + 1, ext[s + 2]));
            lb[t * S + s] = v;
        }
    double ll = la[(T - 1) * S + S - 1];
    if (S > 1) ll = lse2(ll, la[(T - 1) * S + S - 2]);
    grad.assign((size_t)(T * C), 0.0);
    if (ll == NI) return INFINITY;
    for (int64_t t = 0; t < T; t++) {
        std::vector<double> acc((size_t)C, NI);
        for (int64_t s = 0; s < S; s++) {
            double v = la[t * S + s];
            if (v == NI || lb[t * S + s] == NI) continue;
            acc[ext[s]] = lse2(acc[ext[s]], v + lb[t * S + s]);
        }
        for (int64_t c = 0; c < C; c++) grad[t * C + c] = acc[c] == NI ? 0.0 : -std::exp(acc[c] - ll);
    }
    return -ll;
}

// ── conv / pool (NCHW) ──────────────────────────────────────────────────────
struct Conv {
    int64_t N, C, H, W, O, Cg, KH, KW, OH, OW, sh, sw, ph, pw, dh, dw, G;
    bool batched;
};
std::vector<int64_t> pair_arg(const Val& v, const char* what, int64_t dflt) {
    if (is_none(v)) return {dflt, dflt};
    auto r = IV(v, what);
    if (r.size() == 1) return {r[0], r[0]};
    if (r.size() != 2) fail("ValueError", std::string(what) + " must be an int or a pair");
    return r;
}
Conv plan_conv(const Shape& xs, const Shape& ws, const std::vector<int64_t>& st, const std::vector<int64_t>& pd,
               const std::vector<int64_t>& dl, int64_t groups) {
    Conv c;
    c.batched = xs.size() == 4;
    if (xs.size() != 3 && xs.size() != 4) fail("ValueError", "conv2d input must be (N, C, H, W) or (C, H, W), got " + sstr(xs));
    if (ws.size() != 4) fail("ValueError", "conv2d weight must be (out_channels, in_channels/groups, kH, kW), got " + sstr(ws));
    c.N = c.batched ? xs[0] : 1;
    c.C = xs[xs.size() - 3]; c.H = xs[xs.size() - 2]; c.W = xs[xs.size() - 1];
    c.O = ws[0]; c.Cg = ws[1]; c.KH = ws[2]; c.KW = ws[3]; c.G = groups;
    if (groups <= 0 || c.C % groups != 0 || c.O % groups != 0) fail("ValueError", "groups must divide in and out channels");
    if (c.Cg * groups != c.C) fail("ValueError", "weight expects " + std::to_string(c.Cg * groups) + " input channels, input has " + std::to_string(c.C));
    c.sh = st[0]; c.sw = st[1]; c.ph = pd[0]; c.pw = pd[1]; c.dh = dl[0]; c.dw = dl[1];
    if (c.sh <= 0 || c.sw <= 0 || c.dh <= 0 || c.dw <= 0 || c.ph < 0 || c.pw < 0) fail("ValueError", "stride/dilation must be positive and padding >= 0");
    c.OH = (c.H + 2 * c.ph - c.dh * (c.KH - 1) - 1) / c.sh + 1;
    c.OW = (c.W + 2 * c.pw - c.dw * (c.KW - 1) - 1) / c.sw + 1;
    if (c.OH <= 0 || c.OW <= 0) fail("ValueError", "kernel " + sstr(Shape{c.KH, c.KW}) + " is larger than the padded input " + sstr(Shape{c.H + 2 * c.ph, c.W + 2 * c.pw}));
    return c;
}
void im2col(const double* x, const Conv& c, double* col) {
    // col: [Cg*KH*KW, OH*OW] for one group of one sample (x points at the group's first channel)
    int64_t L = c.OH * c.OW;
    for (int64_t ch = 0; ch < c.Cg; ch++)
        for (int64_t kh = 0; kh < c.KH; kh++)
            for (int64_t kw = 0; kw < c.KW; kw++) {
                double* row = col + ((ch * c.KH + kh) * c.KW + kw) * L;
                for (int64_t oh = 0; oh < c.OH; oh++) {
                    int64_t ih = oh * c.sh - c.ph + kh * c.dh;
                    for (int64_t ow = 0; ow < c.OW; ow++) {
                        int64_t iw = ow * c.sw - c.pw + kw * c.dw;
                        row[oh * c.OW + ow] = (ih >= 0 && ih < c.H && iw >= 0 && iw < c.W) ? x[(ch * c.H + ih) * c.W + iw] : 0.0;
                    }
                }
            }
}
void col2im(const double* col, const Conv& c, double* dx) {
    int64_t L = c.OH * c.OW;
    for (int64_t ch = 0; ch < c.Cg; ch++)
        for (int64_t kh = 0; kh < c.KH; kh++)
            for (int64_t kw = 0; kw < c.KW; kw++) {
                const double* row = col + ((ch * c.KH + kh) * c.KW + kw) * L;
                for (int64_t oh = 0; oh < c.OH; oh++) {
                    int64_t ih = oh * c.sh - c.ph + kh * c.dh;
                    if (ih < 0 || ih >= c.H) continue;
                    for (int64_t ow = 0; ow < c.OW; ow++) {
                        int64_t iw = ow * c.sw - c.pw + kw * c.dw;
                        if (iw >= 0 && iw < c.W) dx[(ch * c.H + ih) * c.W + iw] += row[oh * c.OW + ow];
                    }
                }
            }
}

// ── registry ────────────────────────────────────────────────────────────────
std::unordered_map<std::string, Op>& reg() {
    static std::unordered_map<std::string, Op> m;
    return m;
}
struct Adder {
    Adder(const char* name, Fn fn, std::vector<int> mut = {}) { reg()[name] = Op{std::move(fn), std::move(mut)}; }
};
#define NT_OP(name, ...) static Adder NT_CAT(nt_adder_, __LINE__)(name, [](std::vector<Val>& a) -> Val { g_cur = name; __VA_ARGS__ })
#define NT_OP_MUT(name, mut, ...) static Adder NT_CAT(nt_adder_, __LINE__)(name, [](std::vector<Val>& a) -> Val { g_cur = name; __VA_ARGS__ }, mut)
#define NT_CAT(a, b) NT_CAT2(a, b)
#define NT_CAT2(a, b) a##b

} // namespace

const Op* find(const std::string& name) {
    auto& m = reg();
    auto it = m.find(name);
    return it == m.end() ? nullptr : &it->second;
}
std::vector<std::string> names() {
    std::vector<std::string> r;
    for (auto& kv : reg()) r.push_back(kv.first);
    std::sort(r.begin(), r.end());
    return r;
}

namespace {
// ════════════════════════════════════════════════════════════════════════════
// nt_* : the ND tensor natives
// ════════════════════════════════════════════════════════════════════════════

// nt_from_nested(x) -> [flat, shape]   nested lists (rectangular) -> flat + shape
void flatten_nested(const Val& v, size_t depth, Shape& shape, Vec& out) {
    if (v.is_num()) {
        if (depth != shape.size()) fail("ValueError", "ragged nested list (a number where a list was expected)");
        out.push_back(v.as_double());
        return;
    }
    if (v.k == Val::VEC) {
        if (shape.size() > depth + 1) fail("ValueError", "ragged nested list (a flat list where deeper nesting was expected)");
        if (depth == shape.size()) shape.push_back((int64_t)v.v.size());
        else if (shape[depth] != (int64_t)v.v.size()) fail("ValueError", "ragged nested list: expected length " + std::to_string(shape[depth]) + ", got " + std::to_string(v.v.size()));
        out.insert(out.end(), v.v.begin(), v.v.end());
        return;
    }
    if (v.k == Val::LIST) {
        if (v.items.empty() && shape.size() > depth + 1) fail("ValueError", "ragged nested list");
        if (depth == shape.size()) shape.push_back((int64_t)v.items.size());
        else if (shape[depth] != (int64_t)v.items.size()) fail("ValueError", "ragged nested list: expected length " + std::to_string(shape[depth]) + ", got " + std::to_string(v.items.size()));
        for (auto& it : v.items) flatten_nested(it, depth + 1, shape, out);
        return;
    }
    fail("TypeError", "tensor data must be numbers or (nested) lists of numbers");
}
NT_OP("nt_from_nested", {
    need(a, 1, "nt_from_nested(nested_list)");
    Shape s; Vec out;
    if (a[0].is_num()) return pair(Vec{a[0].as_double()}, Shape{});
    if (a[0].k == Val::VEC) { s.push_back((int64_t)a[0].v.size()); return pair(std::move(a[0].v), s); }
    // Establish the shape along the first path, then fill.
    flatten_nested(a[0], 0, s, out);
    if ((int64_t)out.size() != numel(s)) fail("ValueError", "ragged nested list");
    return pair(std::move(out), s);
});
// nt_to_nested(data, shape) -> nested list (or a number for a 0-d tensor)
Val nest(const Vec& d, const Shape& s, size_t dim, int64_t& off) {
    if (dim == s.size()) return Val::num(d[off++]);
    if (dim + 1 == s.size()) {
        Vec row(d.begin() + off, d.begin() + off + s[dim]); off += s[dim];
        return Val::vec(std::move(row));
    }
    std::vector<Val> items;
    for (int64_t i = 0; i < s[dim]; i++) items.push_back(nest(d, s, dim + 1, off));
    return Val::list(std::move(items));
}
NT_OP("nt_to_nested", {
    T t = TS(a, 0, "x");
    int64_t off = 0;
    return nest(*t.d, t.s, 0, off);
});

NT_OP("nt_full", {
    need(a, 2, "nt_full(shape, value)");
    Shape s = SH(a[0], "shape");
    return Val::vec(Vec((size_t)numel(s), D(a[1], "value")));
});
NT_OP("nt_arange", {
    need(a, 3, "nt_arange(start, stop, step)");
    double st = D(a[0], "start"), en = D(a[1], "stop"), sp = D(a[2], "step");
    if (sp == 0) fail("ValueError", "step must be nonzero");
    int64_t n = (int64_t)std::ceil((en - st) / sp);
    if (n < 0) n = 0;
    Vec r((size_t)n);
    for (int64_t i = 0; i < n; i++) r[i] = st + sp * (double)i;
    return Val::vec(std::move(r));
});
NT_OP("nt_linspace", {
    need(a, 3, "nt_linspace(start, stop, steps)");
    double st = D(a[0], "start"), en = D(a[1], "stop"); int64_t n = I(a[2], "steps");
    if (n < 0) fail("ValueError", "steps must be >= 0");
    Vec r((size_t)n);
    for (int64_t i = 0; i < n; i++) r[i] = n == 1 ? st : st + (en - st) * (double)i / (double)(n - 1);
    return Val::vec(std::move(r));
});
NT_OP("nt_eye", {
    need(a, 1, "nt_eye(n[, m])");
    int64_t n = I(a[0], "n"), m = Ior(a, 1, n, "m");
    Vec r((size_t)(n * m), 0.0);
    for (int64_t i = 0; i < std::min(n, m); i++) r[i * m + i] = 1.0;
    return pair(std::move(r), Shape{n, m});
});

// ── elementwise ──
NT_OP("nt_binary", {
    need(a, 5, "nt_binary(op, a, a_shape, b, b_shape)");
    std::string op = Sstr(a[0], "op");
    BinF f = bin_fn(op);
    T x = TS(a, 1, "a"), y = TS(a, 3, "b");
    Shape os;
    Vec out = bmap(*x.d, x.s, *y.d, y.s, os, f);
    return pair(std::move(out), os);
});
NT_OP("nt_unary", {
    need(a, 2, "nt_unary(op, x)");
    std::string op = Sstr(a[0], "op");
    UnF f = un_fn(op);
    Vec& x = V(a[1], "x");
    Vec out(x.size());
    for (size_t i = 0; i < x.size(); i++) out[i] = f(x[i]);
    return Val::vec(std::move(out));
});
NT_OP("nt_unary_bw", {
    need(a, 4, "nt_unary_bw(op, x, y, grad)");
    std::string op = Sstr(a[0], "op");
    Vec& x = V(a[1], "x"); Vec& y = V(a[2], "y"); Vec& g = V(a[3], "grad");
    if (x.size() != g.size() || y.size() != g.size()) fail("ValueError", "x, y and grad sizes differ");
    Vec out(x.size());
    for (size_t i = 0; i < x.size(); i++) out[i] = un_grad(op, x[i], y[i], g[i]);
    return Val::vec(std::move(out));
});
NT_OP("nt_unary_s", {
    need(a, 3, "nt_unary_s(op, x, scalar)");
    std::string op = Sstr(a[0], "op");
    Vec& x = V(a[1], "x"); double s = D(a[2], "scalar");
    un_s(op, 0.0, s);   // validates op
    Vec out(x.size());
    for (size_t i = 0; i < x.size(); i++) out[i] = un_s(op, x[i], s);
    return Val::vec(std::move(out));
});
NT_OP("nt_unary_s_bw", {
    need(a, 5, "nt_unary_s_bw(op, x, y, scalar, grad)");
    std::string op = Sstr(a[0], "op");
    Vec& x = V(a[1], "x"); Vec& y = V(a[2], "y"); double s = D(a[3], "scalar"); Vec& g = V(a[4], "grad");
    if (x.size() != g.size()) fail("ValueError", "x and grad sizes differ");
    Vec out(x.size());
    for (size_t i = 0; i < x.size(); i++) out[i] = un_s_grad(op, x[i], y.size() == x.size() ? y[i] : 0.0, s, g[i]);
    return Val::vec(std::move(out));
});
NT_OP("nt_clamp", {
    need(a, 3, "nt_clamp(x, lo, hi)");
    Vec& x = V(a[0], "x");
    double lo = Dor(a, 1, -INFINITY, "lo"), hi = Dor(a, 2, INFINITY, "hi");
    Vec out(x.size());
    for (size_t i = 0; i < x.size(); i++) out[i] = std::min(hi, std::max(lo, x[i]));
    return Val::vec(std::move(out));
});
NT_OP("nt_clamp_bw", {
    need(a, 4, "nt_clamp_bw(x, lo, hi, grad)");
    Vec& x = V(a[0], "x"); Vec& g = V(a[3], "grad");
    double lo = Dor(a, 1, -INFINITY, "lo"), hi = Dor(a, 2, INFINITY, "hi");
    Vec out(x.size());
    for (size_t i = 0; i < x.size(); i++) out[i] = (x[i] >= lo && x[i] <= hi) ? g[i] : 0.0;
    return Val::vec(std::move(out));
});
NT_OP("nt_where", {
    need(a, 6, "nt_where(cond, cond_shape, a, a_shape, b, b_shape)");
    T c = TS(a, 0, "cond"), x = TS(a, 2, "a"), y = TS(a, 4, "b");
    Shape s1 = bshape(c.s, x.s), os = bshape(s1, y.s);
    Vec cc = expand_to(*c.d, c.s, os), xx = expand_to(*x.d, x.s, os), yy = expand_to(*y.d, y.s, os);
    Vec out(cc.size());
    for (size_t i = 0; i < cc.size(); i++) out[i] = cc[i] != 0 ? xx[i] : yy[i];
    return pair(std::move(out), os);
});
NT_OP("nt_expand", {
    need(a, 3, "nt_expand(x, shape, target_shape)");
    T x = TS(a, 0, "x");
    Shape ts = SH(a[2], "target_shape");
    return Val::vec(expand_to(*x.d, x.s, ts));
});
NT_OP("nt_sum_to", {
    need(a, 3, "nt_sum_to(grad, grad_shape, target_shape)");
    T g = TS(a, 0, "grad");
    Shape ts = SH(a[2], "target_shape");
    return Val::vec(sum_to(*g.d, g.s, ts));
});
NT_OP("nt_allclose", {
    need(a, 2, "nt_allclose(a, b[, rtol, atol])");
    Vec& x = V(a[0], "a"); Vec& y = V(a[1], "b");
    double rtol = Dor(a, 2, 1e-5, "rtol"), atol = Dor(a, 3, 1e-8, "atol");
    if (x.size() != y.size()) return Val::boolean(false);
    for (size_t i = 0; i < x.size(); i++) if (!(std::fabs(x[i] - y[i]) <= atol + rtol * std::fabs(y[i]))) return Val::boolean(false);
    return Val::boolean(true);
});
NT_OP("nt_max_abs_diff", {
    need(a, 2, "nt_max_abs_diff(a, b)");
    Vec& x = V(a[0], "a"); Vec& y = V(a[1], "b");
    if (x.size() != y.size()) fail("ValueError", "sizes differ: " + std::to_string(x.size()) + " vs " + std::to_string(y.size()));
    double m = 0;
    for (size_t i = 0; i < x.size(); i++) m = std::max(m, std::fabs(x[i] - y[i]));
    return Val::num(m);
});

// ── reductions ──
NT_OP("nt_reduce", {
    need(a, 5, "nt_reduce(op, x, shape, dims, keepdim[, correction])");
    std::string op = Sstr(a[0], "op");
    T x = TS(a, 1, "x");
    Red r = plan_reduce(x.s, a[3], truthy(a[4]));
    double corr = Dor(a, 5, 1.0, "correction");
    Vec out = reduce(op, *x.d, x.s, r, corr);
    Val res = pair(std::move(out), r.out);
    if (op == "argmax" || op == "argmin") res.items[0].v_int = true;   // indices come back as ints
    return res;
});
NT_OP("nt_reduce_bw", {
    need(a, 6, "nt_reduce_bw(op, x, shape, dims, grad, out[, correction])");
    std::string op = Sstr(a[0], "op");
    T x = TS(a, 1, "x");
    Red r = plan_reduce(x.s, a[3], true);
    Vec& g = V(a[4], "grad"); Vec& y = V(a[5], "out");
    double corr = Dor(a, 6, 1.0, "correction");
    return Val::vec(reduce_bw(op, *x.d, x.s, r, g, y, corr));
});

// ── matmul ──
NT_OP("nt_matmul", {
    need(a, 4, "nt_matmul(a, a_shape, b, b_shape)");
    T x = TS(a, 0, "a"), y = TS(a, 2, "b");
    Shape os;
    Vec out = matmul(*x.d, x.s, *y.d, y.s, os);
    return pair(std::move(out), os);
});
NT_OP("nt_matmul_bw", {
    need(a, 5, "nt_matmul_bw(a, a_shape, b, b_shape, grad)");
    T x = TS(a, 0, "a"), y = TS(a, 2, "b");
    Vec& g = V(a[4], "grad");
    Vec da, db;
    matmul_bw(*x.d, x.s, *y.d, y.s, g, da, db);
    std::vector<Val> r; r.push_back(Val::vec(std::move(da))); r.push_back(Val::vec(std::move(db)));
    return Val::list(std::move(r));
});
// Fused affine layer: y = x W^T + b (torch.nn.functional.linear), W [out, in].
NT_OP("nt_linear", {
    need(a, 5, "nt_linear(x, x_shape, weight, weight_shape, bias_or_none)");
    T x = TS(a, 0, "x"), w = TS(a, 2, "weight");
    if (w.s.size() != 2) fail("ValueError", "weight must be 2-d (out_features, in_features), got " + sstr(w.s));
    if (x.s.empty()) fail("ValueError", "input must be at least 1-d");
    int64_t in = w.s[1], outf = w.s[0];
    if (x.s.back() != in) fail("ValueError", "input has " + std::to_string(x.s.back()) + " features, layer expects " + std::to_string(in) + " (input shape " + sstr(x.s) + ")");
    int64_t rows = numel(x.s) / std::max<int64_t>(in, 1);
    if (in == 0) rows = numel(Shape(x.s.begin(), x.s.end() - 1));
    Vec out((size_t)(rows * outf));
    mm_bt(x.d->data(), w.d->data(), out.data(), rows, in, outf, false);
    if (!is_none(a[4])) {
        Vec& b = V(a[4], "bias");
        if ((int64_t)b.size() != outf) fail("ValueError", "bias has " + std::to_string(b.size()) + " elements, expected " + std::to_string(outf));
        for (int64_t r = 0; r < rows; r++) for (int64_t j = 0; j < outf; j++) out[r * outf + j] += b[j];
    }
    Shape os = x.s; os.back() = outf;
    return pair(std::move(out), os);
});
NT_OP("nt_linear_bw", {
    need(a, 6, "nt_linear_bw(x, x_shape, weight, weight_shape, grad, has_bias)");
    T x = TS(a, 0, "x"), w = TS(a, 2, "weight");
    Vec& g = V(a[4], "grad");
    int64_t in = w.s[1], outf = w.s[0], rows = in ? numel(x.s) / in : 0;
    if ((int64_t)g.size() != rows * outf) fail("ValueError", "linear gradient has the wrong size");
    Vec dx((size_t)(rows * in), 0.0), dw((size_t)(outf * in), 0.0);
    mm(g.data(), w.d->data(), dx.data(), rows, outf, in, false);       // dx = g W
    mm_at(g.data(), x.d->data(), dw.data(), rows, outf, in, false);    // dW = g^T x
    std::vector<Val> r; r.push_back(Val::vec(std::move(dx))); r.push_back(Val::vec(std::move(dw)));
    if (truthy(a[5])) {
        Vec db((size_t)outf, 0.0);
        for (int64_t i = 0; i < rows; i++) for (int64_t j = 0; j < outf; j++) db[j] += g[i * outf + j];
        r.push_back(Val::vec(std::move(db)));
    } else r.push_back(Val::none());
    return Val::list(std::move(r));
});

// ── layout ──
NT_OP("nt_permute", {
    need(a, 3, "nt_permute(x, shape, dims)");
    T x = TS(a, 0, "x");
    Shape os;
    Vec out = permute(*x.d, x.s, IV(a[2], "dims"), os);
    return pair(std::move(out), os);
});
NT_OP("nt_reshape_shape", {
    // Resolve a target shape (one -1 allowed) against numel; ValueError if it does not fit.
    need(a, 2, "nt_reshape_shape(numel, shape)");
    int64_t n = I(a[0], "numel");
    auto s = IV(a[1], "shape");
    int64_t known = 1, neg = -1;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == -1) { if (neg >= 0) fail("ValueError", "only one dimension can be -1"); neg = (int64_t)i; }
        else if (s[i] < 0) fail("ValueError", "invalid shape dimension " + std::to_string(s[i]));
        else known *= s[i];
    }
    if (neg >= 0) {
        if (known == 0 || n % known != 0) fail("ValueError", "shape " + sstr(s) + " is invalid for input of size " + std::to_string(n));
        s[neg] = n / known;
    } else if (known != n) fail("ValueError", "shape " + sstr(s) + " is invalid for input of size " + std::to_string(n));
    return Val::ivec(s);
});
NT_OP("nt_cat", {
    need(a, 3, "nt_cat(datas, shapes, dim)");
    if (!a[0].is_seq() || !a[1].is_seq()) fail("TypeError", "datas and shapes must be lists");
    size_t k = a[0].seq_len();
    if (k == 0) fail("ValueError", "cat needs at least one tensor");
    if (a[1].seq_len() != k) fail("ValueError", "datas and shapes differ in length");
    auto item = [&](Val& lst, size_t i) -> Val& {
        if (lst.k == Val::LIST) return lst.items[i];
        fail("TypeError", "expected a list of lists");
    };
    std::vector<Vec*> ds; std::vector<Shape> ss;
    for (size_t i = 0; i < k; i++) {
        ds.push_back(&V(item(a[0], i), "data"));
        ss.push_back(SH(item(a[1], i), "shape"));
        if ((int64_t)ds.back()->size() != numel(ss.back())) fail("ValueError", "tensor " + std::to_string(i) + " data does not match its shape");
    }
    int64_t nd = (int64_t)ss[0].size();
    if (nd == 0) fail("ValueError", "cannot concatenate 0-d tensors");
    int64_t dim = norm_dim(I(a[2], "dim"), nd);
    Shape os = ss[0]; os[dim] = 0;
    for (size_t i = 0; i < k; i++) {
        if ((int64_t)ss[i].size() != nd) fail("ValueError", "all tensors must have the same number of dims");
        for (int64_t d = 0; d < nd; d++) if (d != dim && ss[i][d] != ss[0][d])
            fail("ValueError", "sizes must match except in dim " + std::to_string(dim) + ": " + sstr(ss[0]) + " vs " + sstr(ss[i]));
        os[dim] += ss[i][dim];
    }
    int64_t outer, n0, inner;
    outer_inner(ss[0], dim, outer, n0, inner);
    Vec out; out.reserve((size_t)numel(os));
    for (int64_t o = 0; o < outer; o++)
        for (size_t i = 0; i < k; i++) {
            int64_t chunk = ss[i][dim] * inner;
            out.insert(out.end(), ds[i]->begin() + o * chunk, ds[i]->begin() + (o + 1) * chunk);
        }
    return pair(std::move(out), os);
});
NT_OP("nt_split", {
    // Inverse of cat: split x along dim into pieces of the given sizes.
    need(a, 4, "nt_split(x, shape, dim, sizes)");
    T x = TS(a, 0, "x");
    int64_t dim = norm_dim(I(a[2], "dim"), (int64_t)x.s.size());
    auto sizes = IV(a[3], "sizes");
    int64_t tot = 0; for (auto z : sizes) { if (z < 0) fail("ValueError", "negative split size"); tot += z; }
    if (tot != x.s[dim]) fail("ValueError", "split sizes sum to " + std::to_string(tot) + ", dim has " + std::to_string(x.s[dim]));
    int64_t outer, n, inner;
    outer_inner(x.s, dim, outer, n, inner);
    std::vector<Val> r;
    int64_t off = 0;
    for (auto z : sizes) {
        Vec piece; piece.reserve((size_t)(outer * z * inner));
        for (int64_t o = 0; o < outer; o++)
            piece.insert(piece.end(), x.d->begin() + (o * n + off) * inner, x.d->begin() + (o * n + off + z) * inner);
        Shape ps = x.s; ps[dim] = z;
        r.push_back(pair(std::move(piece), ps));
        off += z;
    }
    return Val::list(std::move(r));
});
NT_OP("nt_slice", {
    need(a, 6, "nt_slice(x, shape, dim, start, stop, step)");
    T x = TS(a, 0, "x");
    if (x.s.empty()) fail("IndexError", "cannot slice a 0-d tensor");
    int64_t dim = norm_dim(I(a[2], "dim"), (int64_t)x.s.size());
    SliceSpec sp = slice_spec(x.s[dim], a[3], a[4], a[5]);
    int64_t outer, n, inner;
    outer_inner(x.s, dim, outer, n, inner);
    Shape os = x.s; os[dim] = sp.len;
    Vec out; out.reserve((size_t)numel(os));
    for (int64_t o = 0; o < outer; o++)
        for (int64_t j = 0; j < sp.len; j++) {
            int64_t src = (o * n + sp.start + j * sp.step) * inner;
            out.insert(out.end(), x.d->begin() + src, x.d->begin() + src + inner);
        }
    return pair(std::move(out), os);
});
NT_OP("nt_slice_bw", {
    need(a, 7, "nt_slice_bw(grad, shape, dim, start, stop, step, input_numel)");
    Vec& g = V(a[0], "grad");
    Shape s = SH(a[1], "shape");
    int64_t dim = norm_dim(I(a[2], "dim"), (int64_t)s.size());
    SliceSpec sp = slice_spec(s[dim], a[3], a[4], a[5]);
    int64_t outer, n, inner;
    outer_inner(s, dim, outer, n, inner);
    if ((int64_t)g.size() != outer * sp.len * inner) fail("ValueError", "slice gradient has the wrong size");
    Vec dx((size_t)numel(s), 0.0);
    int64_t gi = 0;
    for (int64_t o = 0; o < outer; o++)
        for (int64_t j = 0; j < sp.len; j++) {
            int64_t dst = (o * n + sp.start + j * sp.step) * inner;
            for (int64_t q = 0; q < inner; q++) dx[dst + q] += g[gi++];
        }
    return Val::vec(std::move(dx));
});
NT_OP("nt_index_select", {
    need(a, 4, "nt_index_select(x, shape, dim, indices)");
    T x = TS(a, 0, "x");
    if (x.s.empty()) fail("IndexError", "cannot index a 0-d tensor");
    int64_t dim = norm_dim(I(a[2], "dim"), (int64_t)x.s.size());
    auto idx = IV(a[3], "indices");
    int64_t outer, n, inner;
    outer_inner(x.s, dim, outer, n, inner);
    for (auto& i : idx) {
        if (i < -n || i >= n) fail("IndexError", "index " + std::to_string(i) + " is out of bounds for dimension " + std::to_string(dim) + " with size " + std::to_string(n));
        if (i < 0) i += n;
    }
    Shape os = x.s; os[dim] = (int64_t)idx.size();
    Vec out; out.reserve((size_t)numel(os));
    for (int64_t o = 0; o < outer; o++)
        for (auto i : idx) {
            int64_t src = (o * n + i) * inner;
            out.insert(out.end(), x.d->begin() + src, x.d->begin() + src + inner);
        }
    return pair(std::move(out), os);
});
NT_OP("nt_index_select_bw", {
    need(a, 4, "nt_index_select_bw(grad, shape, dim, indices)");
    Vec& g = V(a[0], "grad");
    Shape s = SH(a[1], "shape");
    int64_t dim = norm_dim(I(a[2], "dim"), (int64_t)s.size());
    auto idx = IV(a[3], "indices");
    int64_t outer, n, inner;
    outer_inner(s, dim, outer, n, inner);
    if ((int64_t)g.size() != outer * (int64_t)idx.size() * inner) fail("ValueError", "index gradient has the wrong size");
    Vec dx((size_t)numel(s), 0.0);
    int64_t gi = 0;
    for (int64_t o = 0; o < outer; o++)
        for (auto i : idx) {
            if (i < 0) i += n;
            int64_t dst = (o * n + i) * inner;
            for (int64_t q = 0; q < inner; q++) dx[dst + q] += g[gi++];
        }
    return Val::vec(std::move(dx));
});
// gather along dim (torch.gather): out[i][j][k] = x[i][idx[i][j][k]][k] for dim=1
NT_OP("nt_gather", {
    need(a, 5, "nt_gather(x, shape, dim, index, index_shape)");
    T x = TS(a, 0, "x");
    T ix = TS(a, 3, "index");
    int64_t nd = (int64_t)x.s.size();
    if ((int64_t)ix.s.size() != nd) fail("ValueError", "index must have the same number of dims as x");
    int64_t dim = norm_dim(I(a[2], "dim"), nd);
    auto xst = contiguous_strides(x.s);
    Vec out(ix.d->size());
    std::vector<int64_t> cid(nd, 0);
    for (size_t e = 0; e < ix.d->size(); e++) {
        int64_t rem = (int64_t)e, off = 0;
        for (int64_t d = nd - 1; d >= 0; --d) { cid[d] = rem % ix.s[d]; rem /= ix.s[d]; }
        for (int64_t d = 0; d < nd; d++) {
            int64_t c = cid[d];
            if (d == dim) {
                double v = (*ix.d)[e];
                c = (int64_t)v;
                if ((double)c != v || c < 0 || c >= x.s[d]) fail("IndexError", "gather index " + std::to_string(v) + " out of range for size " + std::to_string(x.s[d]));
            } else if (c >= x.s[d]) fail("ValueError", "index shape " + sstr(ix.s) + " exceeds x shape " + sstr(x.s));
            off += c * xst[d];
        }
        out[e] = (*x.d)[off];
    }
    return Val::vec(std::move(out));
});

// ── softmax / log_softmax ──
NT_OP("nt_softmax", {
    need(a, 4, "nt_softmax(x, shape, dim, log)");
    T x = TS(a, 0, "x");
    int64_t dim = x.s.empty() ? 0 : norm_dim(I(a[2], "dim"), (int64_t)x.s.size());
    return Val::vec(softmax(*x.d, x.s, dim, truthy(a[3])));
});
NT_OP("nt_softmax_bw", {
    need(a, 5, "nt_softmax_bw(y, grad, shape, dim, log)");
    Vec& y = V(a[0], "y"); Vec& g = V(a[1], "grad");
    Shape s = SH(a[2], "shape");
    if ((int64_t)y.size() != numel(s) || g.size() != y.size()) fail("ValueError", "softmax gradient sizes differ");
    int64_t dim = s.empty() ? 0 : norm_dim(I(a[3], "dim"), (int64_t)s.size());
    return Val::vec(softmax_bw(y, g, s, dim, truthy(a[4])));
});

// ── losses ──
// Layout shared by cross-entropy and nll: class dim is 1 for (N, C, d1...),
// 0 for an unbatched (C,) input.
struct ClsLayout { int64_t N, C, S; };
ClsLayout cls_layout(const Shape& s) {
    ClsLayout L;
    if (s.size() == 1) { L.N = 1; L.C = s[0]; L.S = 1; }
    else if (s.size() >= 2) { L.N = s[0]; L.C = s[1]; L.S = 1; for (size_t d = 2; d < s.size(); d++) L.S *= s[d]; }
    else fail("ValueError", "input must be (C,) or (N, C, ...), got a 0-d tensor");
    return L;
}
Shape cls_target_shape(const Shape& s) {
    Shape t;
    if (s.size() >= 2) { t.push_back(s[0]); for (size_t d = 2; d < s.size(); d++) t.push_back(s[d]); }
    return t;
}
// returns [loss (number, or data for 'none'), loss_shape, dlogits]
// dlogits is the gradient of the returned loss for 'mean'/'sum', and of each
// element for 'none' (multiply by the upstream gradient broadcast along dim 1).
Val class_loss(std::vector<Val>& a, bool from_logits) {
    const char* sig = from_logits ? "nt_cross_entropy(logits, shape, target, reduction, ignore_index, label_smoothing, weight)"
                                  : "nt_nll_loss(log_probs, shape, target, reduction, ignore_index, weight)";
    need(a, 5, sig);
    T x = TS(a, 0, "input");
    ClsLayout L = cls_layout(x.s);
    Vec& tg = V(a[2], "target");
    std::string red = Sstr(a[3], "reduction");
    if (red != "mean" && red != "sum" && red != "none") fail("ValueError", "reduction must be 'mean', 'sum' or 'none'");
    int64_t ignore = Ior(a, 4, -100, "ignore_index");
    double eps = from_logits ? Dor(a, 5, 0.0, "label_smoothing") : 0.0;
    size_t wi = from_logits ? 6 : 5;
    Vec w;
    if (wi < a.size() && !is_none(a[wi])) {
        w = V(a[wi], "weight");
        if ((int64_t)w.size() != L.C) fail("ValueError", "weight has " + std::to_string(w.size()) + " elements, input has " + std::to_string(L.C) + " classes");
    }
    auto W = [&](int64_t c) { return w.empty() ? 1.0 : w[c]; };
    int64_t P = L.N * L.S;
    bool probs = (int64_t)tg.size() == numel(x.s) && (int64_t)tg.size() != P;
    if (!probs && (int64_t)tg.size() != P)
        fail("ValueError", "target has " + std::to_string(tg.size()) + " elements; expected " + std::to_string(P) +
             " class indices (shape " + sstr(cls_target_shape(x.s)) + ") or " + std::to_string(numel(x.s)) + " probabilities");
    if (probs && !from_logits) fail("ValueError", "nll_loss needs class-index targets");
    Vec lp(x.d->size());
    auto at = [&](int64_t n, int64_t c, int64_t sp) { return (n * L.C + c) * L.S + sp; };
    if (from_logits) {
        for (int64_t n = 0; n < L.N; n++) for (int64_t sp = 0; sp < L.S; sp++) {
            double mx = -INFINITY;
            for (int64_t c = 0; c < L.C; c++) mx = std::max(mx, (*x.d)[at(n, c, sp)]);
            double sum = 0;
            for (int64_t c = 0; c < L.C; c++) sum += std::exp((*x.d)[at(n, c, sp)] - mx);
            double lse = mx + std::log(sum);
            for (int64_t c = 0; c < L.C; c++) lp[at(n, c, sp)] = (*x.d)[at(n, c, sp)] - lse;
        }
    } else lp = *x.d;
    Vec loss((size_t)P, 0.0), grad(x.d->size(), 0.0);
    double denom = 0;
    double Wsum = 0; for (int64_t c = 0; c < L.C; c++) Wsum += W(c);
    for (int64_t n = 0; n < L.N; n++) for (int64_t sp = 0; sp < L.S; sp++) {
        int64_t p = n * L.S + sp;
        if (!probs) {
            double tv = tg[p];
            int64_t y = (int64_t)tv;
            if ((double)y != tv) fail("ValueError", "class-index target must be integral, got " + std::to_string(tv) + " (pass probabilities with the same shape as the input instead)");
            if (y == ignore) continue;
            if (y < 0 || y >= L.C) fail("IndexError", "target " + std::to_string(y) + " is out of bounds for " + std::to_string(L.C) + " classes");
            double wy = W(y);
            double l = -(1.0 - eps) * wy * lp[at(n, y, sp)];
            double smooth = 0;
            if (eps > 0) for (int64_t c = 0; c < L.C; c++) smooth -= W(c) * lp[at(n, c, sp)];
            l += eps / (double)L.C * smooth;
            loss[p] = l;
            denom += wy;
            for (int64_t c = 0; c < L.C; c++) {
                double g;
                if (from_logits) {
                    double pc = std::exp(lp[at(n, c, sp)]);
                    g = (1.0 - eps) * wy * (pc - (c == y ? 1.0 : 0.0)) + (eps / (double)L.C) * (Wsum * pc - W(c));
                } else g = c == y ? -wy : 0.0;
                grad[at(n, c, sp)] = g;
            }
        } else {
            double l = 0, swt = 0;
            for (int64_t c = 0; c < L.C; c++) {
                double t = tg[at(n, c, sp)] * (1.0 - eps) + eps / (double)L.C;
                l -= W(c) * t * lp[at(n, c, sp)];
                swt += W(c) * t;
            }
            loss[p] = l;
            denom += 1.0;
            for (int64_t c = 0; c < L.C; c++) {
                double t = tg[at(n, c, sp)] * (1.0 - eps) + eps / (double)L.C;
                grad[at(n, c, sp)] = std::exp(lp[at(n, c, sp)]) * swt - W(c) * t;
            }
        }
    }
    std::vector<Val> r;
    if (red == "none") {
        r.push_back(Val::vec(std::move(loss)));
        r.push_back(Val::ivec(cls_target_shape(x.s)));
    } else {
        double tot = 0; for (auto v : loss) tot += v;
        double scale = 1.0;
        if (red == "mean") { scale = denom > 0 ? 1.0 / denom : std::numeric_limits<double>::quiet_NaN(); tot *= scale; }
        for (auto& g : grad) g *= scale;
        r.push_back(Val::num(tot));
        r.push_back(Val::ivec(Shape{}));
    }
    r.push_back(Val::vec(std::move(grad)));
    return Val::list(std::move(r));
}
NT_OP("nt_cross_entropy", { return class_loss(a, true); });
NT_OP("nt_nll_loss", { return class_loss(a, false); });
// Numerically stable binary cross-entropy on logits.
NT_OP("nt_bce_logits", {
    need(a, 4, "nt_bce_logits(logits, target, pos_weight_or_none, reduction)");
    Vec& x = V(a[0], "logits"); Vec& t = V(a[1], "target");
    if (x.size() != t.size()) fail("ValueError", "logits and target sizes differ: " + std::to_string(x.size()) + " vs " + std::to_string(t.size()));
    double pw = Dor(a, 2, 1.0, "pos_weight");
    std::string red = Sstr(a[3], "reduction");
    Vec loss(x.size()), grad(x.size());
    for (size_t i = 0; i < x.size(); i++) {
        loss[i] = pw * t[i] * softplus(-x[i]) + (1.0 - t[i]) * softplus(x[i]);
        grad[i] = sigm(x[i]) * (1.0 - t[i] + pw * t[i]) - pw * t[i];
    }
    std::vector<Val> r;
    if (red == "none") { r.push_back(Val::vec(std::move(loss))); r.push_back(Val::none()); }
    else {
        double tot = 0; for (auto v : loss) tot += v;
        double sc = red == "mean" ? (x.empty() ? std::numeric_limits<double>::quiet_NaN() : 1.0 / (double)x.size()) : 1.0;
        for (auto& g : grad) g *= sc;
        r.push_back(Val::num(tot * sc)); r.push_back(Val::none());
    }
    r.push_back(Val::vec(std::move(grad)));
    return Val::list(std::move(r));
});

// ── conv / pool ──
NT_OP("nt_conv2d", {
    need(a, 9, "nt_conv2d(x, x_shape, weight, weight_shape, bias_or_none, stride, padding, dilation, groups)");
    T x = TS(a, 0, "input"), w = TS(a, 2, "weight");
    Conv c = plan_conv(x.s, w.s, pair_arg(a[5], "stride", 1), pair_arg(a[6], "padding", 0), pair_arg(a[7], "dilation", 1), Ior(a, 8, 1, "groups"));
    Vec* b = nullptr;
    if (!is_none(a[4])) { b = &V(a[4], "bias"); if ((int64_t)b->size() != c.O) fail("ValueError", "bias must have " + std::to_string(c.O) + " elements"); }
    int64_t L = c.OH * c.OW, Og = c.O / c.G, K = c.Cg * c.KH * c.KW;
    Vec out((size_t)(c.N * c.O * L));
    Vec col((size_t)(K * L));
    for (int64_t n = 0; n < c.N; n++)
        for (int64_t g = 0; g < c.G; g++) {
            im2col(x.d->data() + (n * c.C + g * c.Cg) * c.H * c.W, c, col.data());
            mm(w.d->data() + g * Og * K, col.data(), out.data() + (n * c.O + g * Og) * L, Og, K, L, false);
        }
    if (b) for (int64_t n = 0; n < c.N; n++) for (int64_t o = 0; o < c.O; o++) {
        double bv = (*b)[o]; double* p = out.data() + (n * c.O + o) * L;
        for (int64_t j = 0; j < L; j++) p[j] += bv;
    }
    Shape os = c.batched ? Shape{c.N, c.O, c.OH, c.OW} : Shape{c.O, c.OH, c.OW};
    return pair(std::move(out), os);
});
NT_OP("nt_conv2d_bw", {
    need(a, 10, "nt_conv2d_bw(x, x_shape, weight, weight_shape, grad, stride, padding, dilation, groups, has_bias)");
    T x = TS(a, 0, "input"), w = TS(a, 2, "weight");
    Conv c = plan_conv(x.s, w.s, pair_arg(a[5], "stride", 1), pair_arg(a[6], "padding", 0), pair_arg(a[7], "dilation", 1), Ior(a, 8, 1, "groups"));
    Vec& gr = V(a[4], "grad");
    int64_t L = c.OH * c.OW, Og = c.O / c.G, K = c.Cg * c.KH * c.KW;
    if ((int64_t)gr.size() != c.N * c.O * L) fail("ValueError", "conv2d gradient has the wrong size");
    Vec dx(x.d->size(), 0.0), dw(w.d->size(), 0.0);
    Vec col((size_t)(K * L)), dcol((size_t)(K * L));
    for (int64_t n = 0; n < c.N; n++)
        for (int64_t g = 0; g < c.G; g++) {
            const double* G = gr.data() + (n * c.O + g * Og) * L;
            im2col(x.d->data() + (n * c.C + g * c.Cg) * c.H * c.W, c, col.data());
            mm_bt(G, col.data(), dw.data() + g * Og * K, Og, L, K, true);          // dW += G col^T
            mm_at(w.d->data() + g * Og * K, G, dcol.data(), Og, K, L, false);      // dcol = W^T G
            col2im(dcol.data(), c, dx.data() + (n * c.C + g * c.Cg) * c.H * c.W);
        }
    std::vector<Val> r; r.push_back(Val::vec(std::move(dx))); r.push_back(Val::vec(std::move(dw)));
    if (truthy(a[9])) {
        Vec db((size_t)c.O, 0.0);
        for (int64_t n = 0; n < c.N; n++) for (int64_t o = 0; o < c.O; o++) {
            const double* p = gr.data() + (n * c.O + o) * L;
            for (int64_t j = 0; j < L; j++) db[o] += p[j];
        }
        r.push_back(Val::vec(std::move(db)));
    } else r.push_back(Val::none());
    return Val::list(std::move(r));
});
struct Pool { int64_t N, C, H, W, KH, KW, sh, sw, ph, pw, OH, OW; bool batched; };
Pool plan_pool(const Shape& xs, const std::vector<int64_t>& k, const std::vector<int64_t>& st, const std::vector<int64_t>& pd) {
    Pool p;
    if (xs.size() != 3 && xs.size() != 4) fail("ValueError", "pool2d input must be (N, C, H, W) or (C, H, W), got " + sstr(xs));
    p.batched = xs.size() == 4;
    p.N = p.batched ? xs[0] : 1; p.C = xs[xs.size() - 3]; p.H = xs[xs.size() - 2]; p.W = xs[xs.size() - 1];
    p.KH = k[0]; p.KW = k[1]; p.sh = st[0]; p.sw = st[1]; p.ph = pd[0]; p.pw = pd[1];
    if (p.KH <= 0 || p.KW <= 0 || p.sh <= 0 || p.sw <= 0) fail("ValueError", "kernel and stride must be positive");
    if (2 * p.ph > p.KH || 2 * p.pw > p.KW) fail("ValueError", "padding should be at most half of the kernel size");
    p.OH = (p.H + 2 * p.ph - p.KH) / p.sh + 1; p.OW = (p.W + 2 * p.pw - p.KW) / p.sw + 1;
    if (p.OH <= 0 || p.OW <= 0) fail("ValueError", "kernel is larger than the padded input");
    return p;
}
NT_OP("nt_maxpool2d", {
    need(a, 5, "nt_maxpool2d(x, shape, kernel, stride_or_none, padding)");
    T x = TS(a, 0, "input");
    auto k = pair_arg(a[2], "kernel_size", 1);
    Pool p = plan_pool(x.s, k, is_none(a[3]) ? k : pair_arg(a[3], "stride", 1), pair_arg(a[4], "padding", 0));
    Vec out((size_t)(p.N * p.C * p.OH * p.OW)), idx(out.size());
    int64_t o = 0;
    for (int64_t nc = 0; nc < p.N * p.C; nc++)
        for (int64_t oh = 0; oh < p.OH; oh++)
            for (int64_t ow = 0; ow < p.OW; ow++, o++) {
                double best = -INFINITY; int64_t bi = -1;
                for (int64_t kh = 0; kh < p.KH; kh++) {
                    int64_t ih = oh * p.sh - p.ph + kh; if (ih < 0 || ih >= p.H) continue;
                    for (int64_t kw = 0; kw < p.KW; kw++) {
                        int64_t iw = ow * p.sw - p.pw + kw; if (iw < 0 || iw >= p.W) continue;
                        int64_t q = (nc * p.H + ih) * p.W + iw;
                        double v = (*x.d)[q];
                        if (bi < 0 || v > best || v != v) { best = v; bi = q; }
                    }
                }
                out[o] = best; idx[o] = (double)bi;
            }
    Shape os = p.batched ? Shape{p.N, p.C, p.OH, p.OW} : Shape{p.C, p.OH, p.OW};
    std::vector<Val> r; r.push_back(Val::vec(std::move(out))); r.push_back(Val::ivec(os)); r.push_back(Val::vec(std::move(idx), true));
    return Val::list(std::move(r));
});
NT_OP("nt_maxpool2d_bw", {
    need(a, 3, "nt_maxpool2d_bw(grad, indices, input_numel)");
    Vec& g = V(a[0], "grad"); Vec& idx = V(a[1], "indices");
    int64_t n = I(a[2], "input_numel");
    if (g.size() != idx.size()) fail("ValueError", "grad and indices sizes differ");
    Vec dx((size_t)n, 0.0);
    for (size_t i = 0; i < g.size(); i++) { int64_t q = (int64_t)idx[i]; if (q >= 0 && q < n) dx[q] += g[i]; }
    return Val::vec(std::move(dx));
});
NT_OP("nt_avgpool2d", {
    need(a, 5, "nt_avgpool2d(x, shape, kernel, stride_or_none, padding)");
    T x = TS(a, 0, "input");
    auto k = pair_arg(a[2], "kernel_size", 1);
    Pool p = plan_pool(x.s, k, is_none(a[3]) ? k : pair_arg(a[3], "stride", 1), pair_arg(a[4], "padding", 0));
    Vec out((size_t)(p.N * p.C * p.OH * p.OW));
    int64_t o = 0;
    double div = (double)(p.KH * p.KW);   // count_include_pad=True (torch default)
    for (int64_t nc = 0; nc < p.N * p.C; nc++)
        for (int64_t oh = 0; oh < p.OH; oh++)
            for (int64_t ow = 0; ow < p.OW; ow++, o++) {
                double s = 0;
                for (int64_t kh = 0; kh < p.KH; kh++) {
                    int64_t ih = oh * p.sh - p.ph + kh; if (ih < 0 || ih >= p.H) continue;
                    for (int64_t kw = 0; kw < p.KW; kw++) {
                        int64_t iw = ow * p.sw - p.pw + kw; if (iw < 0 || iw >= p.W) continue;
                        s += (*x.d)[(nc * p.H + ih) * p.W + iw];
                    }
                }
                out[o] = s / div;
            }
    Shape os = p.batched ? Shape{p.N, p.C, p.OH, p.OW} : Shape{p.C, p.OH, p.OW};
    return pair(std::move(out), os);
});
NT_OP("nt_avgpool2d_bw", {
    need(a, 6, "nt_avgpool2d_bw(grad, x_shape, kernel, stride_or_none, padding, unused)");
    Vec& g = V(a[0], "grad");
    Shape xs = SH(a[1], "x_shape");
    auto k = pair_arg(a[2], "kernel_size", 1);
    Pool p = plan_pool(xs, k, is_none(a[3]) ? k : pair_arg(a[3], "stride", 1), pair_arg(a[4], "padding", 0));
    if ((int64_t)g.size() != p.N * p.C * p.OH * p.OW) fail("ValueError", "avgpool gradient has the wrong size");
    Vec dx((size_t)numel(xs), 0.0);
    double div = (double)(p.KH * p.KW);
    int64_t o = 0;
    for (int64_t nc = 0; nc < p.N * p.C; nc++)
        for (int64_t oh = 0; oh < p.OH; oh++)
            for (int64_t ow = 0; ow < p.OW; ow++, o++)
                for (int64_t kh = 0; kh < p.KH; kh++) {
                    int64_t ih = oh * p.sh - p.ph + kh; if (ih < 0 || ih >= p.H) continue;
                    for (int64_t kw = 0; kw < p.KW; kw++) {
                        int64_t iw = ow * p.sw - p.pw + kw; if (iw < 0 || iw >= p.W) continue;
                        dx[(nc * p.H + ih) * p.W + iw] += g[o] / div;
                    }
                }
    return Val::vec(std::move(dx));
});

// ── normalization ──
// batch norm over dim 1 of (N, C) or (N, C, *). Returns [out, mean, invstd];
// in training mode updates running_mean/running_var in place (torch's
// momentum convention; running_var uses the unbiased batch variance).
NT_OP_MUT("nt_batchnorm", (std::vector<int>{4, 5}), {
    need(a, 9, "nt_batchnorm(x, shape, gamma, beta, running_mean, running_var, training, momentum, eps)");
    T x = TS(a, 0, "input");
    if (x.s.size() < 2) fail("ValueError", "batch norm expects (N, C) or (N, C, ...), got " + sstr(x.s));
    int64_t N = x.s[0], C = x.s[1], S = 1;
    for (size_t d = 2; d < x.s.size(); d++) S *= x.s[d];
    bool training = truthy(a[6]);
    double mom = D(a[7], "momentum"), eps = D(a[8], "eps");
    Vec* gm = is_none(a[2]) ? nullptr : &V(a[2], "weight");
    Vec* bt = is_none(a[3]) ? nullptr : &V(a[3], "bias");
    Vec* rm = is_none(a[4]) ? nullptr : &V(a[4], "running_mean");
    Vec* rv = is_none(a[5]) ? nullptr : &V(a[5], "running_var");
    for (Vec* p : {gm, bt, rm, rv}) if (p && (int64_t)p->size() != C) fail("ValueError", "per-channel parameters must have " + std::to_string(C) + " elements");
    int64_t M = N * S;
    Vec mean((size_t)C, 0.0), invstd((size_t)C, 0.0);
    if (training) {
        if (M <= 1) fail("ValueError", "expected more than 1 value per channel when training, got input shape " + sstr(x.s));
        for (int64_t c = 0; c < C; c++) {
            double s = 0;
            for (int64_t n = 0; n < N; n++) for (int64_t q = 0; q < S; q++) s += (*x.d)[(n * C + c) * S + q];
            double m = s / (double)M, v = 0;
            for (int64_t n = 0; n < N; n++) for (int64_t q = 0; q < S; q++) { double d = (*x.d)[(n * C + c) * S + q] - m; v += d * d; }
            double var = v / (double)M;
            mean[c] = m; invstd[c] = 1.0 / std::sqrt(var + eps);
            if (rm) (*rm)[c] = (1.0 - mom) * (*rm)[c] + mom * m;
            if (rv) (*rv)[c] = (1.0 - mom) * (*rv)[c] + mom * v / (double)(M - 1);
        }
    } else {
        if (!rm || !rv) fail("ValueError", "evaluation mode needs running statistics");
        for (int64_t c = 0; c < C; c++) { mean[c] = (*rm)[c]; invstd[c] = 1.0 / std::sqrt((*rv)[c] + eps); }
    }
    Vec out(x.d->size());
    for (int64_t n = 0; n < N; n++) for (int64_t c = 0; c < C; c++) {
        double gg = gm ? (*gm)[c] : 1.0, bb = bt ? (*bt)[c] : 0.0;
        for (int64_t q = 0; q < S; q++) { int64_t i = (n * C + c) * S + q; out[i] = ((*x.d)[i] - mean[c]) * invstd[c] * gg + bb; }
    }
    std::vector<Val> r; r.push_back(Val::vec(std::move(out))); r.push_back(Val::vec(std::move(mean))); r.push_back(Val::vec(std::move(invstd)));
    return Val::list(std::move(r));
});
NT_OP("nt_batchnorm_bw", {
    need(a, 7, "nt_batchnorm_bw(x, shape, gamma, mean, invstd, grad, training)");
    T x = TS(a, 0, "input");
    int64_t N = x.s[0], C = x.s[1], S = 1;
    for (size_t d = 2; d < x.s.size(); d++) S *= x.s[d];
    Vec* gm = is_none(a[2]) ? nullptr : &V(a[2], "weight");
    Vec& mean = V(a[3], "mean"); Vec& inv = V(a[4], "invstd"); Vec& g = V(a[5], "grad");
    bool training = truthy(a[6]);
    int64_t M = N * S;
    Vec dx(x.d->size()), dg((size_t)C, 0.0), db((size_t)C, 0.0);
    for (int64_t c = 0; c < C; c++) {
        double sg = 0, sgx = 0, gg = gm ? (*gm)[c] : 1.0;
        for (int64_t n = 0; n < N; n++) for (int64_t q = 0; q < S; q++) {
            int64_t i = (n * C + c) * S + q;
            double xh = ((*x.d)[i] - mean[c]) * inv[c];
            sg += g[i]; sgx += g[i] * xh;
        }
        dg[c] = sgx; db[c] = sg;
        for (int64_t n = 0; n < N; n++) for (int64_t q = 0; q < S; q++) {
            int64_t i = (n * C + c) * S + q;
            if (!training) { dx[i] = g[i] * gg * inv[c]; continue; }
            double xh = ((*x.d)[i] - mean[c]) * inv[c];
            dx[i] = gg * inv[c] / (double)M * ((double)M * g[i] - sg - xh * sgx);
        }
    }
    std::vector<Val> r; r.push_back(Val::vec(std::move(dx))); r.push_back(Val::vec(std::move(dg))); r.push_back(Val::vec(std::move(db)));
    return Val::list(std::move(r));
});
NT_OP("nt_layernorm", {
    need(a, 6, "nt_layernorm(x, shape, n_last_dims, gamma, beta, eps)");
    T x = TS(a, 0, "input");
    int64_t k = I(a[2], "n_last_dims");
    if (k < 1 || k > (int64_t)x.s.size()) fail("ValueError", "normalized_shape does not fit input shape " + sstr(x.s));
    int64_t M = 1; for (size_t d = x.s.size() - k; d < x.s.size(); d++) M *= x.s[d];
    int64_t R = M ? numel(x.s) / M : 0;
    double eps = D(a[5], "eps");
    Vec* gm = is_none(a[3]) ? nullptr : &V(a[3], "weight");
    Vec* bt = is_none(a[4]) ? nullptr : &V(a[4], "bias");
    for (Vec* p : {gm, bt}) if (p && (int64_t)p->size() != M) fail("ValueError", "layer norm parameters must have " + std::to_string(M) + " elements");
    Vec out(x.d->size()), mean((size_t)R), rstd((size_t)R);
    for (int64_t r = 0; r < R; r++) {
        const double* p = x.d->data() + r * M;
        double s = 0; for (int64_t j = 0; j < M; j++) s += p[j];
        double m = s / (double)M, v = 0;
        for (int64_t j = 0; j < M; j++) { double d = p[j] - m; v += d * d; }
        double rs = 1.0 / std::sqrt(v / (double)M + eps);
        mean[r] = m; rstd[r] = rs;
        for (int64_t j = 0; j < M; j++) out[r * M + j] = (p[j] - m) * rs * (gm ? (*gm)[j] : 1.0) + (bt ? (*bt)[j] : 0.0);
    }
    std::vector<Val> res; res.push_back(Val::vec(std::move(out))); res.push_back(Val::vec(std::move(mean))); res.push_back(Val::vec(std::move(rstd)));
    return Val::list(std::move(res));
});
NT_OP("nt_layernorm_bw", {
    need(a, 7, "nt_layernorm_bw(x, shape, n_last_dims, gamma, mean, rstd, grad)");
    T x = TS(a, 0, "input");
    int64_t k = I(a[2], "n_last_dims");
    int64_t M = 1; for (size_t d = x.s.size() - k; d < x.s.size(); d++) M *= x.s[d];
    int64_t R = M ? numel(x.s) / M : 0;
    Vec* gm = is_none(a[3]) ? nullptr : &V(a[3], "weight");
    Vec& mean = V(a[4], "mean"); Vec& rstd = V(a[5], "rstd"); Vec& g = V(a[6], "grad");
    Vec dx(x.d->size()), dg((size_t)M, 0.0), db((size_t)M, 0.0);
    for (int64_t r = 0; r < R; r++) {
        double s1 = 0, s2 = 0;
        for (int64_t j = 0; j < M; j++) {
            int64_t i = r * M + j;
            double xh = ((*x.d)[i] - mean[r]) * rstd[r];
            double dxh = g[i] * (gm ? (*gm)[j] : 1.0);
            s1 += dxh; s2 += dxh * xh;
            dg[j] += g[i] * xh; db[j] += g[i];
        }
        for (int64_t j = 0; j < M; j++) {
            int64_t i = r * M + j;
            double xh = ((*x.d)[i] - mean[r]) * rstd[r];
            double dxh = g[i] * (gm ? (*gm)[j] : 1.0);
            dx[i] = rstd[r] * (dxh - s1 / (double)M - xh * s2 / (double)M);
        }
    }
    std::vector<Val> res; res.push_back(Val::vec(std::move(dx))); res.push_back(Val::vec(std::move(dg))); res.push_back(Val::vec(std::move(db)));
    return Val::list(std::move(res));
});
NT_OP("nt_embedding", {
    need(a, 4, "nt_embedding(weight, weight_shape, indices, indices_shape)");
    T w = TS(a, 0, "weight");
    if (w.s.size() != 2) fail("ValueError", "embedding weight must be (num_embeddings, dim)");
    T ix = TS(a, 2, "indices");
    int64_t V_ = w.s[0], Dm = w.s[1];
    Vec out; out.reserve(ix.d->size() * (size_t)Dm);
    for (double v : *ix.d) {
        int64_t i = (int64_t)v;
        if ((double)i != v || i < 0 || i >= V_) fail("IndexError", "index " + std::to_string(v) + " out of range for an embedding of " + std::to_string(V_) + " rows");
        out.insert(out.end(), w.d->begin() + i * Dm, w.d->begin() + (i + 1) * Dm);
    }
    Shape os = ix.s; os.push_back(Dm);
    return pair(std::move(out), os);
});
NT_OP("nt_embedding_bw", {
    need(a, 4, "nt_embedding_bw(grad, indices, weight_shape, padding_idx_or_none)");
    Vec& g = V(a[0], "grad"); Vec& ix = V(a[1], "indices");
    Shape ws = SH(a[2], "weight_shape");
    int64_t pad = is_none(a[3]) ? -1 : I(a[3], "padding_idx");
    int64_t Dm = ws[1];
    if ((int64_t)g.size() != (int64_t)ix.size() * Dm) fail("ValueError", "embedding gradient has the wrong size");
    Vec dw((size_t)numel(ws), 0.0);
    for (size_t k = 0; k < ix.size(); k++) {
        int64_t i = (int64_t)ix[k];
        if (i == pad) continue;
        for (int64_t j = 0; j < Dm; j++) dw[i * Dm + j] += g[k * Dm + j];
    }
    return Val::vec(std::move(dw));
});

// ── random ──
NT_OP("nt_manual_seed", {
    need(a, 1, "manual_seed(seed)");
    int64_t s = I(a[0], "seed");
    rng().seed((uint64_t)s);
    std::srand((unsigned)s);   // legacy natives still drawing from rand()
    return Val::integer(s);
});
NT_OP("nt_rand", { need(a, 1, "nt_rand(n_or_shape)"); int64_t n = count_arg(a[0], "size"); Vec r((size_t)n); for (auto& v : r) v = unif(); return Val::vec(std::move(r)); });
NT_OP("nt_randn", { need(a, 1, "nt_randn(n_or_shape)"); int64_t n = count_arg(a[0], "size"); Vec r((size_t)n); for (auto& v : r) v = normal(); return Val::vec(std::move(r)); });
NT_OP("nt_uniform", {
    need(a, 3, "nt_uniform(n_or_shape, low, high)");
    int64_t n = count_arg(a[0], "size"); double lo = D(a[1], "low"), hi = D(a[2], "high");
    Vec r((size_t)n); for (auto& v : r) v = lo + (hi - lo) * unif();
    return Val::vec(std::move(r));
});
NT_OP("nt_normal", {
    need(a, 3, "nt_normal(n_or_shape, mean, std)");
    int64_t n = count_arg(a[0], "size"); double m = D(a[1], "mean"), s = D(a[2], "std");
    Vec r((size_t)n); for (auto& v : r) v = m + s * normal();
    return Val::vec(std::move(r));
});
NT_OP("nt_randint", {
    need(a, 3, "nt_randint(low, high, n_or_shape)");
    int64_t lo = I(a[0], "low"), hi = I(a[1], "high"), n = count_arg(a[2], "size");
    if (hi <= lo) fail("ValueError", "high must be greater than low");
    Vec r((size_t)n);
    for (auto& v : r) v = (double)(lo + (int64_t)(unif() * (double)(hi - lo)));
    return Val::vec(std::move(r), true);
});
NT_OP("nt_randperm", {
    need(a, 1, "nt_randperm(n)");
    int64_t n = I(a[0], "n");
    std::vector<int64_t> p((size_t)n);
    std::iota(p.begin(), p.end(), 0);
    for (int64_t i = n - 1; i > 0; --i) { int64_t j = (int64_t)(unif() * (double)(i + 1)); if (j > i) j = i; std::swap(p[i], p[j]); }
    return Val::ivec(p);
});
NT_OP("nt_dropout_mask", {
    need(a, 2, "nt_dropout_mask(n, p)");
    int64_t n = count_arg(a[0], "size"); double p = D(a[1], "p");
    if (p < 0 || p > 1) fail("ValueError", "dropout probability has to be between 0 and 1, got " + std::to_string(p));
    Vec r((size_t)n);
    double keep = 1.0 - p;
    for (auto& v : r) v = (p >= 1.0) ? 0.0 : (unif() < keep ? 1.0 / keep : 0.0);
    return Val::vec(std::move(r));
});

// ── in-place parameter updates (the optimizers' inner loops) ──
NT_OP_MUT("nt_axpy", (std::vector<int>{0}), {
    need(a, 3, "nt_axpy(y, alpha, x)   # y += alpha * x, in place");
    Vec& y = V(a[0], "y"); double al = D(a[1], "alpha"); Vec& x = V(a[2], "x");
    if (x.size() != y.size()) fail("ValueError", "sizes differ: " + std::to_string(y.size()) + " vs " + std::to_string(x.size()));
    for (size_t i = 0; i < y.size(); i++) y[i] += al * x[i];
    return Val::none();
});
NT_OP_MUT("nt_scale_", (std::vector<int>{0}), {
    need(a, 2, "nt_scale_(y, s)");
    Vec& y = V(a[0], "y"); double s = D(a[1], "s");
    for (auto& v : y) v *= s;
    return Val::none();
});
NT_OP_MUT("nt_fill_", (std::vector<int>{0}), {
    need(a, 2, "nt_fill_(y, value)");
    Vec& y = V(a[0], "y"); double s = D(a[1], "value");
    for (auto& v : y) v = s;
    return Val::none();
});
NT_OP_MUT("nt_copy_", (std::vector<int>{0}), {
    need(a, 2, "nt_copy_(dst, src)");
    Vec& y = V(a[0], "dst"); Vec& x = V(a[1], "src");
    if (x.size() != y.size()) fail("ValueError", "cannot copy " + std::to_string(x.size()) + " elements into " + std::to_string(y.size()));
    y = x;
    return Val::none();
});
NT_OP_MUT("nt_sgd_step", (std::vector<int>{0, 2}), {
    need(a, 9, "nt_sgd_step(p, grad, buf, lr, momentum, dampening, weight_decay, nesterov, first)");
    Vec& p = V(a[0], "param"); Vec& g = V(a[1], "grad"); Vec& buf = V(a[2], "momentum_buffer");
    double lr = D(a[3], "lr"), mom = D(a[4], "momentum"), damp = D(a[5], "dampening"), wd = D(a[6], "weight_decay");
    bool nest = truthy(a[7]), first = truthy(a[8]);
    if (g.size() != p.size()) fail("ValueError", "grad has " + std::to_string(g.size()) + " elements, param has " + std::to_string(p.size()));
    if (mom != 0 && buf.size() != p.size()) fail("ValueError", "momentum buffer has the wrong size");
    for (size_t i = 0; i < p.size(); i++) {
        double d = g[i] + wd * p[i];
        if (mom != 0) {
            buf[i] = first ? d : mom * buf[i] + (1.0 - damp) * d;
            d = nest ? d + mom * buf[i] : buf[i];
        }
        p[i] -= lr * d;
    }
    return Val::none();
});
NT_OP_MUT("nt_adam_step", (std::vector<int>{0, 2, 3}), {
    need(a, 11, "nt_adam_step(p, grad, m, v, lr, beta1, beta2, eps, weight_decay, step, decoupled)");
    Vec& p = V(a[0], "param"); Vec& g = V(a[1], "grad"); Vec& m = V(a[2], "exp_avg"); Vec& v = V(a[3], "exp_avg_sq");
    double lr = D(a[4], "lr"), b1 = D(a[5], "beta1"), b2 = D(a[6], "beta2"), eps = D(a[7], "eps"), wd = D(a[8], "weight_decay");
    int64_t t = I(a[9], "step"); bool decoupled = truthy(a[10]);
    if (g.size() != p.size() || m.size() != p.size() || v.size() != p.size()) fail("ValueError", "param/grad/state sizes differ");
    double bc1 = 1.0 - std::pow(b1, (double)t), bc2 = 1.0 - std::pow(b2, (double)t);
    double step_size = lr / bc1, sbc2 = std::sqrt(bc2);
    for (size_t i = 0; i < p.size(); i++) {
        double gi = g[i];
        if (decoupled) p[i] *= (1.0 - lr * wd);
        else gi += wd * p[i];
        m[i] = b1 * m[i] + (1.0 - b1) * gi;
        v[i] = b2 * v[i] + (1.0 - b2) * gi * gi;
        p[i] -= step_size * m[i] / (std::sqrt(v[i]) / sbc2 + eps);
    }
    return Val::none();
});
NT_OP_MUT("nt_rmsprop_step", (std::vector<int>{0, 2, 8}), {
    need(a, 9, "nt_rmsprop_step(p, grad, square_avg, lr, alpha, eps, weight_decay, momentum, buf)");
    Vec& p = V(a[0], "param"); Vec& g = V(a[1], "grad"); Vec& sq = V(a[2], "square_avg");
    double lr = D(a[3], "lr"), al = D(a[4], "alpha"), eps = D(a[5], "eps"), wd = D(a[6], "weight_decay"), mom = D(a[7], "momentum");
    Vec& buf = V(a[8], "momentum_buffer");
    if (g.size() != p.size() || sq.size() != p.size()) fail("ValueError", "param/grad/state sizes differ");
    if (mom > 0 && buf.size() != p.size()) fail("ValueError", "momentum buffer has the wrong size");
    for (size_t i = 0; i < p.size(); i++) {
        double gi = g[i] + wd * p[i];
        sq[i] = al * sq[i] + (1.0 - al) * gi * gi;
        double avg = std::sqrt(sq[i]) + eps;
        if (mom > 0) { buf[i] = mom * buf[i] + gi / avg; p[i] -= lr * buf[i]; }
        else p[i] -= lr * gi / avg;
    }
    return Val::none();
});
NT_OP_MUT("nt_adagrad_step", (std::vector<int>{0, 2}), {
    need(a, 6, "nt_adagrad_step(p, grad, sum, lr, eps, weight_decay)");
    Vec& p = V(a[0], "param"); Vec& g = V(a[1], "grad"); Vec& sum = V(a[2], "sum");
    double lr = D(a[3], "lr"), eps = D(a[4], "eps"), wd = D(a[5], "weight_decay");
    if (g.size() != p.size() || sum.size() != p.size()) fail("ValueError", "param/grad/state sizes differ");
    for (size_t i = 0; i < p.size(); i++) {
        double gi = g[i] + wd * p[i];
        sum[i] += gi * gi;
        p[i] -= lr * gi / (std::sqrt(sum[i]) + eps);
    }
    return Val::none();
});
NT_OP("nt_sqnorm", {
    need(a, 1, "nt_sqnorm(x)");
    Vec& x = V(a[0], "x"); double s = 0; for (auto v : x) s += v * v; return Val::num(s);
});

// ── save / load ──
NT_OP("nt_save", {
    need(a, 2, "nt_save(path, entries)   # entries: [[name, data, shape], ...]");
    std::string path = Sstr(a[0], "path");
    if (a[1].k != Val::LIST && !(a[1].k == Val::VEC && a[1].v.empty())) fail("TypeError", "entries must be a list of [name, data, shape]");
    std::vector<Entry> es;
    for (auto& e : a[1].items) {
        if (e.k != Val::LIST || e.items.size() != 3) fail("TypeError", "each entry must be [name, data, shape]");
        Entry en; en.name = Sstr(e.items[0], "name");
        Val dv = e.items[1];
        en.data = V(dv, "data");
        en.shape = SH(e.items[2], "shape");
        if ((int64_t)en.data.size() != numel(en.shape)) fail("ValueError", "entry '" + en.name + "' data does not match its shape " + sstr(en.shape));
        es.push_back(std::move(en));
    }
    save_entries(path, es);
    return Val::boolean(true);
});
NT_OP("nt_load", {
    need(a, 1, "nt_load(path)");
    std::string path = Sstr(a[0], "path");
    std::vector<Entry> es;
    load_entries(path, es, false);
    std::vector<Val> r;
    for (auto& e : es) {
        std::vector<Val> t;
        t.push_back(Val::str(e.name)); t.push_back(Val::vec(std::move(e.data))); t.push_back(Val::ivec(e.shape));
        r.push_back(Val::list(std::move(t)));
    }
    return Val::list(std::move(r));
});

// ── audio ──
NT_OP("nt_stft", {
    need(a, 3, "nt_stft(signal, n_fft, hop_length[, center=true])");
    Vec& s = V(a[0], "signal");
    int64_t frames = 0;
    Vec m = stft_mag(s, I(a[1], "n_fft"), I(a[2], "hop_length"), a.size() > 3 ? truthy(a[3]) : true, frames);
    return pair(std::move(m), Shape{I(a[1], "n_fft") / 2 + 1, frames});
});
NT_OP("nt_mel_filterbank", {
    need(a, 5, "nt_mel_filterbank(n_mels, n_fft, sample_rate, f_min, f_max)");
    int64_t nm = I(a[0], "n_mels"), nf = I(a[1], "n_fft") / 2 + 1;
    double sr = D(a[2], "sample_rate");
    double fmax = Dor(a, 4, sr / 2.0, "f_max");
    return pair(mel_fbank(nm, nf, sr, Dor(a, 3, 0.0, "f_min"), fmax), Shape{nm, nf});
});
NT_OP("nt_dct_matrix", {
    need(a, 2, "nt_dct_matrix(n_mfcc, n_mels)");
    int64_t k = I(a[0], "n_mfcc"), n = I(a[1], "n_mels");
    if (k <= 0 || n <= 0 || k > n) fail("ValueError", "need 0 < n_mfcc <= n_mels");
    return pair(dct_matrix(k, n), Shape{k, n});
});
NT_OP("nt_ctc_loss", {
    need(a, 4, "nt_ctc_loss(log_probs, shape [T, C], targets, blank)");
    T x = TS(a, 0, "log_probs");
    if (x.s.size() != 2) fail("ValueError", "log_probs must be (T, C) for one sequence, got " + sstr(x.s));
    auto tg = IV(a[2], "targets");
    Vec grad;
    double l = ctc(*x.d, x.s[0], x.s[1], tg, I(a[3], "blank"), grad);
    std::vector<Val> r; r.push_back(Val::num(l)); r.push_back(Val::vec(std::move(grad)));
    return Val::list(std::move(r));
});

// ── einsum (explicit or implicit output, no ellipsis) ──
NT_OP("nt_einsum", {
    need(a, 3, "nt_einsum(equation, datas, shapes)");
    std::string eq = Sstr(a[0], "equation");
    eq.erase(std::remove(eq.begin(), eq.end(), ' '), eq.end());
    std::string lhs = eq, rhs; bool explicit_out = false;
    auto arrow = eq.find("->");
    if (arrow != std::string::npos) { lhs = eq.substr(0, arrow); rhs = eq.substr(arrow + 2); explicit_out = true; }
    std::vector<std::string> ins;
    { std::string cur; for (char ch : lhs) { if (ch == ',') { ins.push_back(cur); cur.clear(); } else cur += ch; } ins.push_back(cur); }
    if (a[1].k != Val::LIST || a[2].k != Val::LIST || a[1].items.size() != ins.size() || a[2].items.size() != ins.size())
        fail("ValueError", "equation has " + std::to_string(ins.size()) + " operands but datas/shapes do not match");
    std::vector<Vec*> ds; std::vector<Shape> ss;
    std::unordered_map<char, int64_t> dimsz;
    for (size_t i = 0; i < ins.size(); i++) {
        ds.push_back(&V(a[1].items[i], "data"));
        ss.push_back(SH(a[2].items[i], "shape"));
        if (ss[i].size() != ins[i].size()) fail("ValueError", "operand " + std::to_string(i) + " has " + std::to_string(ss[i].size()) + " dims but subscript '" + ins[i] + "'");
        if ((int64_t)ds[i]->size() != numel(ss[i])) fail("ValueError", "operand " + std::to_string(i) + " data does not match its shape");
        for (size_t d = 0; d < ins[i].size(); d++) {
            char ch = ins[i][d];
            if (!std::isalpha((unsigned char)ch)) fail("ValueError", "invalid subscript '" + std::string(1, ch) + "'");
            auto it = dimsz.find(ch);
            if (it == dimsz.end()) dimsz[ch] = ss[i][d];
            else if (it->second != ss[i][d]) fail("ValueError", "subscript '" + std::string(1, ch) + "' has sizes " + std::to_string(it->second) + " and " + std::to_string(ss[i][d]));
        }
    }
    if (!explicit_out) {
        std::unordered_map<char, int> cnt;
        for (auto& s : ins) for (char ch : s) cnt[ch]++;
        for (auto& kv : cnt) if (kv.second == 1) rhs += kv.first;
        std::sort(rhs.begin(), rhs.end());
    }
    std::string all = rhs;
    for (auto& kv : dimsz) if (all.find(kv.first) == std::string::npos) all += kv.first;
    for (char ch : rhs) if (!dimsz.count(ch)) fail("ValueError", "output subscript '" + std::string(1, ch) + "' does not appear in the inputs");
    Shape os; for (char ch : rhs) os.push_back(dimsz[ch]);
    Shape full; for (char ch : all) full.push_back(dimsz[ch]);
    std::vector<std::vector<int64_t>> str(ins.size(), std::vector<int64_t>(all.size(), 0));
    for (size_t i = 0; i < ins.size(); i++) {
        auto cs = contiguous_strides(ss[i]);
        for (size_t d = 0; d < ins[i].size(); d++) str[i][all.find(ins[i][d])] += cs[d];
    }
    auto ostr = contiguous_strides(os);
    Vec out((size_t)numel(os), 0.0);
    int64_t tot = numel(full);
    std::vector<int64_t> idx(all.size(), 0);
    for (int64_t it = 0; it < tot; it++) {
        double prod = 1;
        for (size_t i = 0; i < ins.size(); i++) { int64_t off = 0; for (size_t d = 0; d < all.size(); d++) off += idx[d] * str[i][d]; prod *= (*ds[i])[off]; }
        int64_t o = 0; for (size_t d = 0; d < rhs.size(); d++) o += idx[d] * ostr[d];
        out[o] += prod;
        for (int64_t d = (int64_t)all.size() - 1; d >= 0; --d) { if (++idx[d] < full[d]) break; idx[d] = 0; }
    }
    return pair(std::move(out), os);
});

// ── detection ──
// Greedy non-maximum suppression (torchvision.ops.nms). boxes: flat N*4 or
// nested [[...], ...]; fmt "xyxy" (default) or "cxcywh". Returns kept
// indices, highest score first.
NT_OP("nms", {
    need(a, 3, "nms(boxes, scores, iou_threshold[, fmt])");
    Vec bx;
    if (a[0].k == Val::VEC) bx = a[0].v;
    else if (a[0].k == Val::LIST) { Shape s; flatten_nested(a[0], 0, s, bx); }
    else fail("TypeError", "boxes must be a list");
    Vec& sc = V(a[1], "scores");
    double thr = D(a[2], "iou_threshold");
    std::string fmt = a.size() > 3 && !is_none(a[3]) ? Sstr(a[3], "fmt") : "xyxy";
    size_t n = sc.size();
    if (bx.size() != 4 * n) fail("ValueError", "boxes must have 4 numbers per score (" + std::to_string(n) + " scores, " + std::to_string(bx.size()) + " numbers)");
    std::vector<double> x1(n), y1(n), x2(n), y2(n);
    for (size_t i = 0; i < n; i++) {
        double p = bx[4 * i], q = bx[4 * i + 1], r = bx[4 * i + 2], s = bx[4 * i + 3];
        if (fmt == "cxcywh") { x1[i] = p - r / 2; y1[i] = q - s / 2; x2[i] = p + r / 2; y2[i] = q + s / 2; }
        else if (fmt == "xyxy") { x1[i] = p; y1[i] = q; x2[i] = r; y2[i] = s; }
        else fail("ValueError", "fmt must be 'xyxy' or 'cxcywh'");
    }
    std::vector<int64_t> order(n); std::iota(order.begin(), order.end(), 0);
    std::stable_sort(order.begin(), order.end(), [&](int64_t i, int64_t j) { return sc[i] > sc[j]; });
    std::vector<char> dead(n, 0); std::vector<int64_t> keep;
    for (size_t oi = 0; oi < n; oi++) {
        int64_t i = order[oi]; if (dead[i]) continue;
        keep.push_back(i);
        double ai = std::max(0.0, x2[i] - x1[i]) * std::max(0.0, y2[i] - y1[i]);
        for (size_t oj = oi + 1; oj < n; oj++) {
            int64_t j = order[oj]; if (dead[j]) continue;
            double iw = std::max(0.0, std::min(x2[i], x2[j]) - std::max(x1[i], x1[j]));
            double ih = std::max(0.0, std::min(y2[i], y2[j]) - std::max(y1[i], y1[j]));
            double inter = iw * ih, aj = std::max(0.0, x2[j] - x1[j]) * std::max(0.0, y2[j] - y1[j]);
            double iou = inter / (ai + aj - inter);
            if (iou > thr) dead[j] = 1;
        }
    }
    return Val::ivec(keep);
});

// ════════════════════════════════════════════════════════════════════════════
// Legacy flat-list natives, now shared by both engines
// ════════════════════════════════════════════════════════════════════════════
// These names predate the ND tensor and are used across ~15,000 lines of
// lib/nytorch. They keep their 1-d contracts, but: integers are read as
// numbers (not as garbage doubles), length mismatches broadcast a length-1
// operand NumPy-style and otherwise raise ValueError instead of silently
// padding with zeros, and the VM stops running its own divergent copies.

Vec flat_bin(std::vector<Val>& a, BinF f, const char* sig) {
    need(a, 2, sig);
    Vec& x = V(a[0], "a"); Vec& y = V(a[1], "b");
    if (x.size() == y.size()) { Vec r(x.size()); for (size_t i = 0; i < x.size(); i++) r[i] = f(x[i], y[i]); return r; }
    if (y.size() == 1) { Vec r(x.size()); for (size_t i = 0; i < x.size(); i++) r[i] = f(x[i], y[0]); return r; }
    if (x.size() == 1) { Vec r(y.size()); for (size_t i = 0; i < y.size(); i++) r[i] = f(x[0], y[i]); return r; }
    fail("ValueError", "length mismatch: " + std::to_string(x.size()) + " vs " + std::to_string(y.size()) + " (only a length-1 operand broadcasts)");
}
NT_OP("tensor", {
    if (a.empty()) return Val::vec({});
    if (a[0].k == Val::VEC) return Val::vec(std::move(a[0].v));
    return a[0];          // nested / mixed lists pass through unchanged
});
NT_OP("tensor_add", { return Val::vec(flat_bin(a, bin_fn("add"), "tensor_add(a, b)")); });
NT_OP("tensor_sub", { return Val::vec(flat_bin(a, bin_fn("sub"), "tensor_sub(a, b)")); });
NT_OP("tensor_mul", { return Val::vec(flat_bin(a, bin_fn("mul"), "tensor_mul(a, b)")); });
NT_OP("tensor_div", { return Val::vec(flat_bin(a, bin_fn("div"), "tensor_div(a, b)")); });
NT_OP("tensor_dot", {
    need(a, 2, "tensor_dot(a, b)");
    Vec& x = V(a[0], "a"); Vec& y = V(a[1], "b");
    if (x.size() != y.size()) fail("ValueError", "length mismatch: " + std::to_string(x.size()) + " vs " + std::to_string(y.size()));
    double s = 0; for (size_t i = 0; i < x.size(); i++) s += x[i] * y[i];
    return Val::num(s);
});
static Adder nt_alias_dot_product("tensor_dot_product", find("tensor_dot")->fn);
NT_OP("tensor_scale", {
    need(a, 2, "tensor_scale(t, factor)");
    if (a[1].is_seq()) return Val::vec(flat_bin(a, bin_fn("mul"), "tensor_scale(t, factor)"));
    Vec& x = V(a[0], "t"); double s = D(a[1], "factor");
    Vec r(x.size()); for (size_t i = 0; i < x.size(); i++) r[i] = x[i] * s;
    return Val::vec(std::move(r));
});
Val flat_reduce(std::vector<Val>& a, const std::string& op) {
    need(a, 1, "tensor reduction(t)");
    Vec& x = V(a[0], "t");
    if (op == "sum") { double s = 0; for (auto v : x) s += v; return Val::num(s); }
    if (op == "mean") { if (x.empty()) return Val::num(0.0); double s = 0; for (auto v : x) s += v; return Val::num(s / (double)x.size()); }
    if (x.empty()) fail("ValueError", op + " of an empty tensor");
    double m = x[0];
    for (auto v : x) m = op == "max" ? std::max(m, v) : std::min(m, v);
    return Val::num(m);
}
NT_OP("tensor_sum", { return flat_reduce(a, "sum"); });
NT_OP("tensor_mean", { return flat_reduce(a, "mean"); });
NT_OP("tensor_max", { return flat_reduce(a, "max"); });
NT_OP("tensor_min", { return flat_reduce(a, "min"); });
Val flat_un(std::vector<Val>& a, double (*f)(double)) {
    need(a, 1, "tensor op(t)");
    if (a[0].is_num()) return Val::num(f(a[0].as_double()));
    Vec& x = V(a[0], "t"); Vec r(x.size());
    for (size_t i = 0; i < x.size(); i++) r[i] = f(x[i]);
    return Val::vec(std::move(r));
}
NT_OP("tensor_exp", { return flat_un(a, [](double x) { return std::exp(x); }); });
NT_OP("tensor_log", { return flat_un(a, [](double x) { return std::log(x); }); });
// Legacy contract (both engines agreed): negative input clamps to 0.
NT_OP("tensor_sqrt", { return flat_un(a, [](double x) { return std::sqrt(std::max(0.0, x)); }); });
NT_OP("tensor_abs", { return flat_un(a, [](double x) { return std::fabs(x); }); });
NT_OP("tensor_neg", { return flat_un(a, [](double x) { return -x; }); });
NT_OP("tensor_sign", { return flat_un(a, [](double x) { return x > 0 ? 1.0 : (x < 0 ? -1.0 : 0.0); }); });
NT_OP("tensor_pow", {
    need(a, 2, "tensor_pow(t, exponent)");
    if (a[1].is_seq()) return Val::vec(flat_bin(a, bin_fn("pow"), "tensor_pow(t, exponent)"));
    Vec& x = V(a[0], "t"); double p = D(a[1], "exponent");
    Vec r(x.size()); for (size_t i = 0; i < x.size(); i++) r[i] = std::pow(x[i], p);
    return Val::vec(std::move(r));
});
// matmul / tensor_matmul:
//   (A, B, m, k, n)   flat row-major A[m*k], B[k*n] -> flat C[m*n]   (legacy)
//   (A, B) nested     2-d lists -> nested 2-d result
//   (x, W) flat       x[k] times W[k*n] (row-major k x n) -> flat [n]
Val legacy_matmul(std::vector<Val>& a) {
    if (a.size() >= 5) {
        Vec& A = V(a[0], "A"); Vec& B = V(a[1], "B");
        int64_t m = I(a[2], "rows_a"), k = I(a[3], "cols_a"), n = I(a[4], "cols_b");
        if ((int64_t)A.size() != m * k) fail("ValueError", "A has " + std::to_string(A.size()) + " elements, " + std::to_string(m) + "x" + std::to_string(k) + " needs " + std::to_string(m * k));
        if ((int64_t)B.size() != k * n) fail("ValueError", "B has " + std::to_string(B.size()) + " elements, " + std::to_string(k) + "x" + std::to_string(n) + " needs " + std::to_string(k * n));
        Vec C((size_t)(m * n));
        mm(A.data(), B.data(), C.data(), m, k, n, false);
        return Val::vec(std::move(C));
    }
    need(a, 2, "matmul(A, B[, rows_a, cols_a, cols_b])");
    if (a.size() != 2) fail("TypeError", "matmul takes 2 arguments (nested or vector-matrix) or 5 (flat with dimensions)");
    if (a[0].k == Val::LIST && a[1].k == Val::LIST) {
        Shape sa, sb; Vec A, B;
        flatten_nested(a[0], 0, sa, A); flatten_nested(a[1], 0, sb, B);
        if (sa.size() != 2 || sb.size() != 2) fail("ValueError", "nested matmul needs 2-d lists");
        Shape os; Vec C = matmul(A, sa, B, sb, os);
        int64_t off = 0;
        return nest(C, os, 0, off);
    }
    Vec& x = V(a[0], "x"); Vec& W = V(a[1], "W");
    int64_t k = (int64_t)x.size();
    if (k == 0 || W.size() % (size_t)k != 0) fail("ValueError", "vector of length " + std::to_string(k) + " cannot multiply a flat matrix of " + std::to_string(W.size()) + " elements (need k*n)");
    int64_t n = (int64_t)W.size() / k;
    Vec C((size_t)n);
    mm(x.data(), W.data(), C.data(), 1, k, n, false);
    return Val::vec(std::move(C));
}
NT_OP("matmul", { return legacy_matmul(a); });
NT_OP("tensor_matmul", { return legacy_matmul(a); });
NT_OP("tensor_transpose", {
    need(a, 1, "tensor_transpose(t, rows, cols)");
    if (a.size() >= 3) {
        Vec& x = V(a[0], "t"); int64_t r = I(a[1], "rows"), c = I(a[2], "cols");
        if ((int64_t)x.size() != r * c) fail("ValueError", "tensor has " + std::to_string(x.size()) + " elements, not " + std::to_string(r) + "x" + std::to_string(c));
        Shape os; Vec out = permute(x, Shape{r, c}, {1, 0}, os);
        return Val::vec(std::move(out));
    }
    if (a[0].k == Val::LIST) {
        Shape s; Vec x; flatten_nested(a[0], 0, s, x);
        if (s.size() != 2) fail("ValueError", "nested transpose needs a 2-d list");
        Shape os; Vec out = permute(x, s, {1, 0}, os);
        int64_t off = 0; return nest(out, os, 0, off);
    }
    fail("TypeError", "tensor_transpose(t, rows, cols) needs the matrix dimensions for a flat list");
});
NT_OP("tensor_reshape", {
    need(a, 2, "tensor_reshape(t, shape)");
    Vec& x = V(a[0], "t"); Shape s = SH(a[1], "shape");
    if (numel(s) != (int64_t)x.size()) fail("ValueError", "cannot reshape " + std::to_string(x.size()) + " elements to " + sstr(s));
    return Val::vec(std::move(x));   // flat storage: the shape is the caller's metadata
});
Val soft1d(std::vector<Val>& a) {
    need(a, 1, "softmax(t)");
    Vec& x = V(a[0], "t");
    if (x.empty()) return Val::vec({});
    return Val::vec(softmax(x, Shape{(int64_t)x.size()}, 0, false));
}
NT_OP("softmax", { return soft1d(a); });
NT_OP("tensor_softmax", { return soft1d(a); });
NT_OP("log_softmax", {
    need(a, 1, "log_softmax(t)");
    Vec& x = V(a[0], "t");
    if (x.empty()) return Val::vec({});
    return Val::vec(softmax(x, Shape{(int64_t)x.size()}, 0, true));
});
NT_OP("logsumexp", {
    need(a, 1, "logsumexp(t)");
    Vec& x = V(a[0], "t");
    Red r = plan_reduce(Shape{(int64_t)x.size()}, Val::none(), false);
    return Val::num(reduce("logsumexp", x, Shape{(int64_t)x.size()}, r, 0)[0]);
});
void same_len(const Vec& x, const Vec& y, const char*) {
    if (x.size() != y.size()) fail("ValueError", "length mismatch: " + std::to_string(x.size()) + " vs " + std::to_string(y.size()));
    if (x.empty()) fail("ValueError", "empty input");
}
NT_OP("mse_loss", {
    need(a, 2, "mse_loss(pred, target)");
    Vec& p = V(a[0], "pred"); Vec& t = V(a[1], "target"); same_len(p, t, "mse_loss");
    double s = 0; for (size_t i = 0; i < p.size(); i++) s += (p[i] - t[i]) * (p[i] - t[i]);
    return Val::num(s / (double)p.size());
});
static Adder nt_alias_mse("nt_mse_loss", find("mse_loss")->fn);
// Legacy contract: -sum(target * log(pred)) on PROBABILITIES (not logits).
// CrossEntropyLoss (lib/nytorch/nn.ny) is the logits + class-index version.
NT_OP("cross_entropy_loss", {
    need(a, 2, "cross_entropy_loss(pred_probs, target)");
    Vec& p = V(a[0], "pred"); Vec& t = V(a[1], "target"); same_len(p, t, "cross_entropy_loss");
    double s = 0; for (size_t i = 0; i < p.size(); i++) s += -t[i] * std::log(std::max(p[i], 1e-7));
    return Val::num(s);
});
NT_OP("binary_cross_entropy", {
    need(a, 2, "binary_cross_entropy(pred_probs, target)");
    Vec& p = V(a[0], "pred"); Vec& t = V(a[1], "target"); same_len(p, t, "binary_cross_entropy");
    double s = 0;
    for (size_t i = 0; i < p.size(); i++) { double q = std::max(1e-7, std::min(1.0 - 1e-7, p[i])); s += -(t[i] * std::log(q) + (1 - t[i]) * std::log(1 - q)); }
    return Val::num(s / (double)p.size());
});
NT_OP("huber_loss", {
    need(a, 2, "huber_loss(pred, target[, delta])");
    Vec& p = V(a[0], "pred"); Vec& t = V(a[1], "target"); same_len(p, t, "huber_loss");
    double dl = Dor(a, 2, 1.0, "delta"), s = 0;
    for (size_t i = 0; i < p.size(); i++) { double d = std::fabs(p[i] - t[i]); s += d <= dl ? 0.5 * d * d : dl * (d - 0.5 * dl); }
    return Val::num(s / (double)p.size());
});
NT_OP("accuracy", {
    need(a, 2, "accuracy(pred, target)");
    Vec& p = V(a[0], "pred"); Vec& t = V(a[1], "target"); same_len(p, t, "accuracy");
    int64_t c = 0; for (size_t i = 0; i < p.size(); i++) if (std::round(p[i]) == std::round(t[i])) c++;
    return Val::num((double)c / (double)p.size());
});
Val flat_arg(std::vector<Val>& a, bool mx) {
    need(a, 1, "argmax(t)");
    Vec& x = V(a[0], "t");
    if (x.empty()) fail("ValueError", "argmax/argmin of an empty tensor");
    size_t b = 0; for (size_t i = 1; i < x.size(); i++) if (mx ? x[i] > x[b] : x[i] < x[b]) b = i;
    return Val::integer((int64_t)b);
}
NT_OP("argmax", { return flat_arg(a, true); });
NT_OP("tensor_argmax", { return flat_arg(a, true); });
NT_OP("argmin", { return flat_arg(a, false); });
NT_OP("tensor_argmin", { return flat_arg(a, false); });
Val flat_norm(std::vector<Val>& a) { need(a, 1, "norm(t)"); Vec& x = V(a[0], "t"); double s = 0; for (auto v : x) s += v * v; return Val::num(std::sqrt(s)); }
NT_OP("tensor_norm", { return flat_norm(a); });
NT_OP("norm", { return flat_norm(a); });
NT_OP("tensor_normalize", {
    need(a, 1, "tensor_normalize(t)");
    Vec& x = V(a[0], "t"); double s = 0; for (auto v : x) s += v * v;
    double n = std::max(std::sqrt(s), 1e-12);
    Vec r(x.size()); for (size_t i = 0; i < x.size(); i++) r[i] = x[i] / n;
    return Val::vec(std::move(r));
});
Val flat_var(std::vector<Val>& a, bool sd) {
    need(a, 1, "variance(t)");
    Vec& x = V(a[0], "t");
    if (x.empty()) return Val::num(0.0);
    double m = 0; for (auto v : x) m += v; m /= (double)x.size();
    double s = 0; for (auto v : x) s += (v - m) * (v - m);
    s /= (double)x.size();                  // population variance (legacy contract)
    return Val::num(sd ? std::sqrt(s) : s);
}
NT_OP("tensor_var", { return flat_var(a, false); });
NT_OP("tensor_variance", { return flat_var(a, false); });
NT_OP("variance", { return flat_var(a, false); });
NT_OP("tensor_std", { return flat_var(a, true); });
NT_OP("std_dev", { return flat_var(a, true); });
Val fill_n(std::vector<Val>& a, double v) {
    need(a, 1, "zeros(n_or_shape)");
    return Val::vec(Vec((size_t)count_arg(a[0], "size"), v));
}
NT_OP("zeros", { return fill_n(a, 0.0); });
NT_OP("tensor_zeros", { return fill_n(a, 0.0); });
NT_OP("ones", { return fill_n(a, 1.0); });
NT_OP("tensor_ones", { return fill_n(a, 1.0); });
Val rnd_n(std::vector<Val>& a, bool gauss) {
    need(a, 1, "rand(n_or_shape)");
    int64_t n = count_arg(a[0], "size");
    Vec r((size_t)n); for (auto& v : r) v = gauss ? normal() : unif();
    return Val::vec(std::move(r));
}
NT_OP("rand_tensor", { return rnd_n(a, false); });
NT_OP("tensor_rand", { return rnd_n(a, false); });
NT_OP("random_tensor", { return rnd_n(a, false); });
NT_OP("randn_tensor", { return rnd_n(a, true); });
NT_OP("tensor_randn", { return rnd_n(a, true); });
static Adder nt_alias_seed("manual_seed", find("nt_manual_seed")->fn);
NT_OP("tensor_arange", {
    need(a, 1, "tensor_arange(start, stop[, step])");
    double st = 0, en, sp = 1;
    if (a.size() == 1) en = D(a[0], "stop"); else { st = D(a[0], "start"); en = D(a[1], "stop"); sp = Dor(a, 2, 1.0, "step"); }
    if (sp == 0) fail("ValueError", "step must be nonzero");
    int64_t n = std::max<int64_t>(0, (int64_t)std::ceil((en - st) / sp));
    Vec r((size_t)n); for (int64_t i = 0; i < n; i++) r[i] = st + sp * (double)i;
    return Val::vec(std::move(r));
});

static Adder nt_alias_arange("arange", find("tensor_arange")->fn);
static Adder nt_alias_dotp2("dot_product", find("tensor_dot")->fn);
// ── legacy save/load, now the versioned float64 format (see save_entries) ──
NT_OP("tensor_save", {
    need(a, 2, "tensor_save(t, path[, shape])");
    Entry e; e.name = "tensor"; e.data = V(a[0], "t");
    e.shape = a.size() > 2 && !is_none(a[2]) ? SH(a[2], "shape") : Shape{(int64_t)e.data.size()};
    if (numel(e.shape) != (int64_t)e.data.size()) fail("ValueError", "shape " + sstr(e.shape) + " does not match " + std::to_string(e.data.size()) + " elements");
    std::string path = Sstr(a[1], "path");
    try { save_entries(path, {e}); } catch (Error&) { return Val::boolean(false); }
    return Val::boolean(true);
});
NT_OP("tensor_load", {
    need(a, 1, "tensor_load(path)");
    std::vector<Entry> es;
    if (!load_entries(Sstr(a[0], "path"), es, true)) return Val::none();
    if (es.empty()) fail("IOError", "file holds no tensors");
    return Val::vec(std::move(es[0].data));
});
NT_OP("model_save", {
    need(a, 2, "model_save(params, path)");
    std::vector<Entry> es;
    if (a[0].k == Val::LIST) {
        for (size_t i = 0; i < a[0].items.size(); i++) {
            Entry e; e.name = std::to_string(i); e.data = V(a[0].items[i], "param");
            e.shape = Shape{(int64_t)e.data.size()}; es.push_back(std::move(e));
        }
    } else if (a[0].k == Val::VEC) {
        if (!a[0].v.empty()) fail("TypeError", "params must be a list of tensors (lists of numbers)");
    } else fail("TypeError", "params must be a list of tensors (lists of numbers)");
    std::string path = Sstr(a[1], "path");
    try { save_entries(path, es); } catch (Error&) { return Val::boolean(false); }
    return Val::boolean(true);
});
NT_OP("model_load", {
    need(a, 1, "model_load(path)");
    std::vector<Entry> es;
    if (!load_entries(Sstr(a[0], "path"), es, true)) return Val::none();
    std::vector<Val> r;
    for (auto& e : es) r.push_back(Val::vec(std::move(e.data)));
    return Val::list(std::move(r));
});
Val lin(std::vector<Val>& a) {
    need(a, 3, "linspace(start, stop, n)");
    double st = D(a[0], "start"), en = D(a[1], "stop"); int64_t n = I(a[2], "n");
    if (n < 0) fail("ValueError", "n must be >= 0");
    Vec r((size_t)n); for (int64_t i = 0; i < n; i++) r[i] = n == 1 ? st : st + (en - st) * (double)i / (double)(n - 1);
    return Val::vec(std::move(r));
}
NT_OP("tensor_linspace", { return lin(a); });
NT_OP("linspace", { return lin(a); });
NT_OP("logspace", {
    Val v = lin(a);
    double base = Dor(a, 3, 10.0, "base");
    for (auto& x : v.v) x = std::pow(base, x);
    return v;
});
NT_OP("one_hot", {
    need(a, 2, "one_hot(index, num_classes)");
    int64_t i = I(a[0], "index"), n = I(a[1], "num_classes");
    if (n < 0) fail("ValueError", "num_classes must be >= 0");
    if (i < 0 || i >= n) fail("IndexError", "class " + std::to_string(i) + " out of range for " + std::to_string(n) + " classes");
    Vec r((size_t)n, 0.0); r[i] = 1.0;
    return Val::vec(std::move(r));
});
NT_OP("tensor_slice", {
    need(a, 3, "tensor_slice(t, start, stop)");
    Vec& x = V(a[0], "t");
    SliceSpec sp = slice_spec((int64_t)x.size(), a[1], a[2], Val::none());
    return Val::vec(Vec(x.begin() + sp.start, x.begin() + sp.start + sp.len));
});
NT_OP("tensor_clip", {
    need(a, 3, "tensor_clip(t, lo, hi)");
    Vec& x = V(a[0], "t"); double lo = Dor(a, 1, -INFINITY, "lo"), hi = Dor(a, 2, INFINITY, "hi");
    Vec r(x.size()); for (size_t i = 0; i < x.size(); i++) r[i] = std::max(lo, std::min(hi, x[i]));
    return Val::vec(std::move(r));
});
static Adder nt_alias_clamp("tensor_clamp", find("tensor_clip")->fn);
NT_OP("tensor_cumsum", { need(a, 1, "tensor_cumsum(t)"); Vec& x = V(a[0], "t"); Vec r(x.size()); double s = 0; for (size_t i = 0; i < x.size(); i++) { s += x[i]; r[i] = s; } return Val::vec(std::move(r)); });
NT_OP("tensor_cumprod", { need(a, 1, "tensor_cumprod(t)"); Vec& x = V(a[0], "t"); Vec r(x.size()); double s = 1; for (size_t i = 0; i < x.size(); i++) { s *= x[i]; r[i] = s; } return Val::vec(std::move(r)); });
NT_OP("tensor_diff", { need(a, 1, "tensor_diff(t)"); Vec& x = V(a[0], "t"); Vec r; for (size_t i = 1; i < x.size(); i++) r.push_back(x[i] - x[i - 1]); return Val::vec(std::move(r)); });
NT_OP("tensor_outer", {
    need(a, 2, "tensor_outer(a, b)");
    Vec& x = V(a[0], "a"); Vec& y = V(a[1], "b");
    Vec r; r.reserve(x.size() * y.size());
    for (auto u : x) for (auto v : y) r.push_back(u * v);
    return Val::vec(std::move(r));
});
static Adder nt_alias_outer("outer_product", find("tensor_outer")->fn);
Val cosine(std::vector<Val>& a) {
    need(a, 2, "cosine_similarity(a, b)");
    Vec& x = V(a[0], "a"); Vec& y = V(a[1], "b");
    if (x.size() != y.size()) fail("ValueError", "length mismatch: " + std::to_string(x.size()) + " vs " + std::to_string(y.size()));
    double d = 0, na = 0, nb = 0;
    for (size_t i = 0; i < x.size(); i++) { d += x[i] * y[i]; na += x[i] * x[i]; nb += y[i] * y[i]; }
    double den = std::sqrt(na) * std::sqrt(nb);
    return Val::num(den > 1e-12 ? d / den : 0.0);
}
NT_OP("cosine_similarity", { return cosine(a); });
NT_OP("cos_sim", { return cosine(a); });
NT_OP("tensor_cosine_sim", { return cosine(a); });
NT_OP("conv1d", {
    need(a, 2, "conv1d(input, kernel)   # 1-d valid cross-correlation");
    Vec& x = V(a[0], "input"); Vec& k = V(a[1], "kernel");
    if (k.empty() || k.size() > x.size()) fail("ValueError", "kernel of length " + std::to_string(k.size()) + " does not fit input of length " + std::to_string(x.size()));
    size_t n = x.size() - k.size() + 1;
    Vec r(n);
    for (size_t i = 0; i < n; i++) { double s = 0; for (size_t j = 0; j < k.size(); j++) s += x[i + j] * k[j]; r[i] = s; }
    return Val::vec(std::move(r));
});
Val pool1(std::vector<Val>& a, bool mx) {
    need(a, 1, "max_pool1d(input[, kernel])");
    Vec& x = V(a[0], "input"); int64_t k = Ior(a, 1, 2, "kernel_size");
    if (k < 1) fail("ValueError", "kernel_size must be >= 1");
    int64_t n = (int64_t)x.size() / k;
    Vec r((size_t)n);
    for (int64_t i = 0; i < n; i++) {
        double s = mx ? -INFINITY : 0.0;
        for (int64_t j = 0; j < k; j++) { double v = x[i * k + j]; if (mx) s = std::max(s, v); else s += v; }
        r[i] = mx ? s : s / (double)k;
    }
    return Val::vec(std::move(r));
}
NT_OP("max_pool1d", { return pool1(a, true); });
NT_OP("avg_pool1d", { return pool1(a, false); });
Val flatnorm(std::vector<Val>& a) {
    need(a, 1, "layer_norm(t[, gamma, beta, eps])");
    Vec& x = V(a[0], "t");
    if (x.empty()) return Val::vec({});
    Vec* g = a.size() > 1 && a[1].is_seq() ? &V(a[1], "gamma") : nullptr;
    Vec* b = a.size() > 2 && a[2].is_seq() ? &V(a[2], "beta") : nullptr;
    double eps = Dor(a, 3, 1e-5, "eps");
    if ((g && g->size() != x.size()) || (b && b->size() != x.size())) fail("ValueError", "gamma/beta must match the input length");
    double m = 0; for (auto v : x) m += v; m /= (double)x.size();
    double s = 0; for (auto v : x) s += (v - m) * (v - m);
    double sd = std::sqrt(s / (double)x.size() + eps);
    Vec r(x.size());
    for (size_t i = 0; i < x.size(); i++) r[i] = (x[i] - m) / sd * (g ? (*g)[i] : 1.0) + (b ? (*b)[i] : 0.0);
    return Val::vec(std::move(r));
}
NT_OP("layer_norm", { return flatnorm(a); });
NT_OP("layernorm", { return flatnorm(a); });
NT_OP("batch_norm", { return flatnorm(a); });
NT_OP("batchnorm", { return flatnorm(a); });
// attention(Q, K, V, d_k): one query Q[d_k] against seq_len keys K[seq_len*d_k]
// and values V[seq_len*d_v] -> [d_v]  (softmax(Q K^T / sqrt(d_k)) V)
Val att1(const Vec& Q, const Vec& K, const Vec& Vv, int64_t dk) {
    if (dk <= 0) fail("ValueError", "d_k must be positive");
    if ((int64_t)Q.size() != dk) fail("ValueError", "query has " + std::to_string(Q.size()) + " elements, d_k is " + std::to_string(dk));
    if (K.size() % (size_t)dk != 0 || K.empty()) fail("ValueError", "keys must be a non-empty multiple of d_k");
    int64_t S = (int64_t)K.size() / dk;
    if (Vv.size() % (size_t)S != 0) fail("ValueError", "values must hold seq_len = " + std::to_string(S) + " rows");
    int64_t dv = (int64_t)Vv.size() / S;
    Vec sc((size_t)S);
    for (int64_t s = 0; s < S; s++) { double d = 0; for (int64_t j = 0; j < dk; j++) d += Q[j] * K[s * dk + j]; sc[s] = d / std::sqrt((double)dk); }
    sc = softmax(sc, Shape{S}, 0, false);
    Vec out((size_t)dv, 0.0);
    for (int64_t s = 0; s < S; s++) for (int64_t j = 0; j < dv; j++) out[j] += sc[s] * Vv[s * dv + j];
    return Val::vec(std::move(out));
}
Val att_legacy(std::vector<Val>& a) {
    need(a, 3, "attention(Q, K, V[, d_k])");
    Vec& Q = V(a[0], "Q"); Vec& K = V(a[1], "K"); Vec& Vv = V(a[2], "V");
    int64_t dk = a.size() > 3 ? (int64_t)std::llround(D(a[3], "d_k")) : (int64_t)Q.size();
    return att1(Q, K, Vv, dk);
}
NT_OP("attention", { return att_legacy(a); });
NT_OP("scaled_dot_attention", { return att_legacy(a); });
NT_OP("multi_head_attention", {
    need(a, 4, "multi_head_attention(Q, K, V, num_heads) or (Q, K, V, d_model, num_heads)");
    Vec& Q = V(a[0], "Q"); Vec& K = V(a[1], "K"); Vec& Vv = V(a[2], "V");
    int64_t dm = (int64_t)Q.size(), h = a.size() >= 5 ? I(a[4], "num_heads") : I(a[3], "num_heads");
    if (a.size() >= 5 && I(a[3], "d_model") != dm) fail("ValueError", "d_model does not match the query length " + std::to_string(dm));
    if (h <= 0 || dm % h != 0) fail("ValueError", "num_heads must divide d_model " + std::to_string(dm));
    if (K.size() % (size_t)dm != 0 || K.empty() || K.size() != Vv.size()) fail("ValueError", "K and V must hold seq_len rows of d_model");
    int64_t S = (int64_t)K.size() / dm, dh = dm / h;
    Vec out; out.reserve((size_t)dm);
    for (int64_t hh = 0; hh < h; hh++) {
        Vec q(Q.begin() + hh * dh, Q.begin() + (hh + 1) * dh), k, v;
        for (int64_t s = 0; s < S; s++) {
            k.insert(k.end(), K.begin() + s * dm + hh * dh, K.begin() + s * dm + (hh + 1) * dh);
            v.insert(v.end(), Vv.begin() + s * dm + hh * dh, Vv.begin() + s * dm + (hh + 1) * dh);
        }
        Val o = att1(q, k, v, dh);
        out.insert(out.end(), o.v.begin(), o.v.end());
    }
    return Val::vec(std::move(out));
});
Val emb_legacy(std::vector<Val>& a) {
    need(a, 3, "embedding(table, indices, dim)");
    Vec& tb = V(a[0], "table"); int64_t dim = I(a[2], "dim");
    auto idx = IV(a[1], "indices");
    if (dim <= 0 || tb.size() % (size_t)dim != 0) fail("ValueError", "table length must be a multiple of dim");
    int64_t rows = (int64_t)tb.size() / dim;
    Vec out;
    for (auto i : idx) {
        if (i < 0 || i >= rows) fail("IndexError", "index " + std::to_string(i) + " out of range for " + std::to_string(rows) + " rows");
        out.insert(out.end(), tb.begin() + i * dim, tb.begin() + (i + 1) * dim);
    }
    return Val::vec(std::move(out));
}
NT_OP("embedding", { return emb_legacy(a); });
NT_OP("embedding_lookup", { return emb_legacy(a); });
NT_OP("dropout", {
    // inverted dropout: keep with probability 1-p and scale by 1/(1-p)
    need(a, 2, "dropout(t, p)");
    Vec& x = V(a[0], "t"); double p = D(a[1], "p");
    if (p < 0 || p > 1) fail("ValueError", "dropout probability has to be between 0 and 1");
    Vec r(x.size());
    for (size_t i = 0; i < x.size(); i++) r[i] = p >= 1 ? 0.0 : (unif() < 1.0 - p ? x[i] / (1.0 - p) : 0.0);
    return Val::vec(std::move(r));
});
NT_OP("tensor_gather", {
    need(a, 2, "tensor_gather(t, indices)");
    Vec& x = V(a[0], "t"); auto idx = IV(a[1], "indices");
    Vec r;
    for (auto i : idx) {
        if (i < -(int64_t)x.size() || i >= (int64_t)x.size()) fail("IndexError", "index " + std::to_string(i) + " out of range for length " + std::to_string(x.size()));
        r.push_back(x[i < 0 ? i + (int64_t)x.size() : i]);
    }
    return Val::vec(std::move(r));
});
NT_OP("tensor_scatter_add", {
    need(a, 3, "tensor_scatter_add(t, indices, values)");
    Vec r = V(a[0], "t"); auto idx = IV(a[1], "indices"); Vec& vals = V(a[2], "values");
    if (idx.size() != vals.size()) fail("ValueError", "indices and values lengths differ");
    for (size_t k = 0; k < idx.size(); k++) {
        int64_t i = idx[k];
        if (i < 0 || i >= (int64_t)r.size()) fail("IndexError", "index " + std::to_string(i) + " out of range for length " + std::to_string(r.size()));
        r[i] += vals[k];
    }
    return Val::vec(std::move(r));
});
NT_OP("tensor_pad", {
    need(a, 3, "tensor_pad(t, pad_left, pad_right[, value])");
    Vec& x = V(a[0], "t"); int64_t l = I(a[1], "pad_left"), r = I(a[2], "pad_right"); double v = Dor(a, 3, 0.0, "value");
    if (l < 0 || r < 0) fail("ValueError", "padding must be >= 0");
    Vec out((size_t)l, v); out.insert(out.end(), x.begin(), x.end()); out.insert(out.end(), (size_t)r, v);
    return Val::vec(std::move(out));
});
// ── audio (real) ──
NT_OP("stft_magnitude", {
    // [frames][n_fft/2+1] magnitude spectrogram, no centre padding (frames =
    // (len - n_fft) / hop + 1). Previously this returned one RMS energy per
    // frame under a spectrogram's name.
    need(a, 1, "stft_magnitude(signal[, n_fft=512, hop=128])");
    Vec& s = V(a[0], "signal");
    int64_t nf = Ior(a, 1, 512, "n_fft"), hop = Ior(a, 2, 128, "hop");
    int64_t frames = 0;
    Vec m = stft_mag(s, nf, hop, false, frames);
    int64_t bins = nf / 2 + 1;
    std::vector<Val> rows;
    for (int64_t t = 0; t < frames; t++) { Vec r((size_t)bins); for (int64_t k = 0; k < bins; k++) r[k] = m[k * frames + t]; rows.push_back(Val::vec(std::move(r))); }
    return Val::list(std::move(rows));
});
NT_OP("mel_filterbank", {
    // [n_mels][n_fft/2+1] triangular HTK mel filters (torchaudio
    // melscale_fbanks, transposed). Previously: n_mels centre frequencies.
    need(a, 1, "mel_filterbank(n_mels[, n_fft=512, sample_rate=22050, f_min=0, f_max=sr/2])");
    int64_t nm = I(a[0], "n_mels"), nfft = Ior(a, 1, 512, "n_fft");
    double sr = Dor(a, 2, 22050.0, "sample_rate");
    int64_t nf = nfft / 2 + 1;
    Vec fb = mel_fbank(nm, nf, sr, Dor(a, 3, 0.0, "f_min"), Dor(a, 4, sr / 2.0, "f_max"));
    std::vector<Val> rows;
    for (int64_t m = 0; m < nm; m++) rows.push_back(Val::vec(Vec(fb.begin() + m * nf, fb.begin() + (m + 1) * nf)));
    return Val::list(std::move(rows));
});
NT_OP("mfcc", {
    // Orthonormal DCT-II of a vector of log-mel energies, first n_mfcc coefficients.
    need(a, 1, "mfcc(log_mel_energies[, n_mfcc=13])");
    Vec& x = V(a[0], "log_mel_energies"); int64_t k = Ior(a, 1, 13, "n_mfcc");
    int64_t n = (int64_t)x.size();
    if (n == 0 || k <= 0 || k > n) fail("ValueError", "need 0 < n_mfcc <= number of mel energies (" + std::to_string(n) + ")");
    Vec m = dct_matrix(k, n), r((size_t)k, 0.0);
    for (int64_t i = 0; i < k; i++) for (int64_t j = 0; j < n; j++) r[i] += m[i * n + j] * x[j];
    return Val::vec(std::move(r));
});
NT_OP("ctc_loss", {
    // ctc_loss(log_probs [T][C] (nested) or flat with C, targets, blank=0)
    need(a, 2, "ctc_loss(log_probs, targets[, blank=0])");
    if (a[0].is_num() && a[1].is_num())
        fail("TypeError", "ctc_loss needs per-frame log-probabilities [T][C] and the target label ids; the old ctc_loss(input_len, target_len) returned a made-up number");
    Vec lp; Shape s;
    if (a[0].k == Val::LIST) flatten_nested(a[0], 0, s, lp);
    else fail("TypeError", "log_probs must be a nested [T][C] list");
    if (s.size() != 2) fail("ValueError", "log_probs must be 2-d [T][C]");
    auto tg = IV(a[1], "targets");
    Vec grad;
    return Val::num(ctc(lp, s[0], s[1], tg, Ior(a, 2, 0, "blank"), grad));
});

} // namespace

} // namespace nt
