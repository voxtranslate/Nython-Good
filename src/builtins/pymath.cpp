// builtins/pymath.cpp - Python's math module for both engines (round 77).
// `import math` binds a namespace whose members are these math_* builtins
// (the VM reaches them through the builtin bridge), so math.log10 is the same
// function on either engine. It used to be: on the VM `math` was not defined
// at all; on the interpreter math.log10/log2 returned none and math.log(x, b)
// ignored its base.
//
// Every function of Python 3.12's math module, with its errors: a domain
// error is ValueError("math domain error"), an overflow OverflowError("math
// range error"); floor/ceil/trunc/factorial/gcd/lcm/isqrt/comb/perm/prod are
// exact on integers of any size. fsum is exact (Shewchuk's algorithm, as
// Python's); log of an integer too large for a double is computed from its
// digits.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include <cfloat>
#include <cmath>
#include <limits>

Value dispatch_pymath(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> pymath_builtin_names();

namespace {

using nypy::BigInt;
using Num = NythonExecutor::Num;

[[noreturn]] void raise(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }
[[noreturn]] void domain() { raise("ValueError", "math domain error"); }
[[noreturn]] void range_err() { raise("OverflowError", "math range error"); }

const char* kNames[] = {
    "acos", "acosh", "asin", "asinh", "atan", "atan2", "atanh", "cbrt", "ceil", "comb", "copysign",
    "cos", "cosh", "degrees", "dist", "erf", "erfc", "exp", "exp2", "expm1", "fabs", "factorial",
    "floor", "fmod", "frexp", "fsum", "gamma", "gcd", "hypot", "isclose", "isfinite", "isinf",
    "isnan", "isqrt", "lcm", "ldexp", "lgamma", "log", "log10", "log1p", "log2", "modf",
    "nextafter", "perm", "pow", "prod", "radians", "remainder", "sin", "sinh", "sqrt", "sumprod",
    "tan", "tanh", "trunc", "ulp"};

std::string tname(NythonExecutor& E, const Value& v) { return E.typeNameOf(v); }

// A real number argument as a double (ints of any size, bools, floats, an
// object with __float__).
double real(NythonExecutor& E, const Value& v, Context* ctx) {
    Num n;
    if (NythonExecutor::asNum(v, n)) {
        if (n.k == 2) {
            double d = NythonExecutor::numD(n);
            if (std::isinf(d)) raise("OverflowError", "int too large to convert to float");
            return d;
        }
        return NythonExecutor::numD(n);
    }
    if (E.isInstanceValue(v) && E.instanceHasMethod(v, "__float__")) {
        std::vector<Value> no;
        Value r = E.callMethod(v, "__float__", no, ctx);
        Num m;
        if (NythonExecutor::asNum(r, m)) return NythonExecutor::numD(m);
    }
    raise("TypeError", "must be real number, not " + tname(E, v));
}

bool is_int(const Value& v) { return v.type == ValueType::INTEGER || v.type == ValueType::BOOLEAN; }

BigInt big(NythonExecutor& E, const Value& v, const char* fn) {
    Num n;
    if (!NythonExecutor::asNum(v, n) || n.k == 3) {
        if (E.isInstanceValue(v) && E.instanceHasMethod(v, "__index__")) {
            std::vector<Value> no;
            Value r = E.callMethod(v, "__index__", no, nullptr);
            if (NythonExecutor::asNum(r, n) && n.k != 3) return NythonExecutor::numBig(n);
        }
        raise("TypeError", "'" + E.typeNameOf(v) + "' object cannot be interpreted as an integer");
    }
    (void)fn;
    return NythonExecutor::numBig(n);
}

Value F(double d) { return Value(d); }

// The result of a float function: OverflowError on an overflow from finite
// arguments, ValueError for a NaN from non-NaN ones (C99 Annex F as Python).
Value checked(double r, double x, bool can_overflow = true) {
    if (std::isnan(r) && !std::isnan(x)) domain();
    if (can_overflow && std::isinf(r) && std::isfinite(x)) range_err();
    return F(r);
}

Value int_of_double(double d) {
    if (std::isnan(d)) raise("ValueError", "cannot convert float NaN to integer");
    if (std::isinf(d)) raise("OverflowError", "cannot convert float infinity to integer");
    if (d >= -9.2e18 && d <= 9.2e18) return intValue((int64_t)d);
    return intValue(BigInt::from_double(d));
}

BigInt babs(BigInt a) { a.neg = false; return a; }

BigInt bgcd(BigInt a, BigInt b) {
    a = babs(a); b = babs(b);
    while (!b.is_zero()) { BigInt q, r; BigInt::floordivmod(a, b, q, r); a = b; b = r; }
    return a;
}

// floor(sqrt(n)) for n >= 0, by Newton's iteration from a power of two above it.
BigInt bisqrt(const BigInt& n) {
    if (n.is_zero()) return BigInt(0);
    size_t bits = n.mag.size() * 32;
    BigInt x = BigInt(1);
    x = x * BigInt(2).pow((bits + 1) / 2 + 1);
    while (true) {
        BigInt q, r;
        BigInt::floordivmod(n, x, q, r);
        BigInt y; BigInt::floordivmod(x + q, BigInt(2), y, r);
        if (BigInt::cmp(y, x) >= 0) return x;
        x = y;
    }
}

// log(n) of a positive integer of any size.
double big_log(const BigInt& n) {
    double d = n.to_double();
    if (std::isfinite(d)) return std::log(d);
    std::string s = n.to_string();
    double lead = std::stod(s.substr(0, 17));
    return std::log(lead) + (double)(s.size() - 17) * std::log(10.0);
}

double logn(NythonExecutor& E, const Value& v, Context* ctx) {
    if (v.type == ValueType::INTEGER) {
        BigInt b = big(E, v, "log");
        if (b.neg || b.is_zero()) domain();
        return big_log(b);
    }
    double x = real(E, v, ctx);
    if (std::isnan(x)) return x;
    if (x <= 0) domain();
    return std::log(x);
}

// Shewchuk's exact sum of doubles (Python's math.fsum).
double fsum(const std::vector<double>& xs) {
    std::vector<double> partials;
    double special = 0.0, inf_sum = 0.0;
    for (double x : xs) {
        if (!std::isfinite(x)) {
            if (std::isinf(x)) inf_sum += x;
            special += x;
            continue;
        }
        size_t i = 0;
        for (double y : partials) {
            if (std::fabs(x) < std::fabs(y)) std::swap(x, y);
            double hi = x + y, lo = y - (hi - x);
            if (lo != 0.0) partials[i++] = lo;
            x = hi;
        }
        partials.resize(i);
        partials.push_back(x);
    }
    if (special != 0.0) {
        if (std::isnan(inf_sum)) raise("ValueError", "-inf + inf in fsum");
        return special;
    }
    double hi = 0.0;
    if (!partials.empty()) {
        size_t n = partials.size();
        hi = partials[--n];
        double lo = 0.0;
        while (n > 0) {
            double x = hi, y = partials[--n];
            hi = x + y;
            double yr = hi - x;
            lo = y - yr;
            if (lo != 0.0) break;
        }
        // half-even correction (as CPython)
        if (n > 0 && ((lo < 0 && partials[n - 1] < 0) || (lo > 0 && partials[n - 1] > 0))) {
            double y = lo * 2, x = hi + y, yr = x - hi;
            if (y == yr) hi = x;
        }
    }
    return hi;
}

} // namespace

std::vector<std::string> pymath_builtin_names() {
    std::vector<std::string> v;
    for (const char* n : kNames) v.push_back(std::string("math_") + n);
    return v;
}

Value dispatch_pymath(NythonExecutor& E, const std::string& full, std::vector<Value>& args, Context* ctx) {
    if (full.compare(0, 5, "math_") != 0) return UNDEFINED_VALUE;
    const std::string name = full.substr(5);
    nyos::Args A(E, args, {"x", "y", "base", "start", "rel_tol", "abs_tol", "steps", "k", "n"});
    auto need = [&](size_t n) {
        if (args.size() < n) raise("TypeError", "math." + name + "() takes " + std::to_string(n) + " argument" + (n == 1 ? "" : "s") + " (" + std::to_string(args.size()) + " given)");
    };
    auto x0 = [&]() { need(1); return real(E, args[0], ctx); };

    // ── one-argument float functions ──
    struct F1 { const char* n; double (*f)(double); bool overflow; };
    static const F1 f1[] = {
        {"sin", [](double x) { return std::sin(x); }, false}, {"cos", [](double x) { return std::cos(x); }, false},
        {"tan", [](double x) { return std::tan(x); }, false}, {"asin", [](double x) { return std::asin(x); }, false},
        {"acos", [](double x) { return std::acos(x); }, false}, {"atan", [](double x) { return std::atan(x); }, false},
        {"sinh", [](double x) { return std::sinh(x); }, true}, {"cosh", [](double x) { return std::cosh(x); }, true},
        {"tanh", [](double x) { return std::tanh(x); }, false}, {"asinh", [](double x) { return std::asinh(x); }, false},
        {"acosh", [](double x) { return std::acosh(x); }, false}, {"exp", [](double x) { return std::exp(x); }, true},
        {"exp2", [](double x) { return std::exp2(x); }, true}, {"expm1", [](double x) { return std::expm1(x); }, true},
        {"fabs", [](double x) { return std::fabs(x); }, false}, {"cbrt", [](double x) { return std::cbrt(x); }, false},
        {"erf", [](double x) { return std::erf(x); }, false}, {"erfc", [](double x) { return std::erfc(x); }, false},
        {"degrees", [](double x) { return x * (180.0 / 3.14159265358979323846); }, true}, {"radians", [](double x) { return x * (3.14159265358979323846 / 180.0); }, false},
    };
    for (auto& e : f1)
        if (name == e.n) { double x = x0(); return checked(e.f(x), x, e.overflow); }

    if (name == "sqrt") {
        double x = x0();
        if (x < 0) domain();
        return F(std::sqrt(x));
    }
    if (name == "atanh") {
        double x = x0();
        if (x <= -1.0 || x >= 1.0) domain();
        return F(std::atanh(x));
    }
    if (name == "log") {
        need(1);
        double l = logn(E, args[0], ctx);
        if (A.has(1, "base")) {
            double b = logn(E, A.get(1, "base"), ctx);
            if (b == 0.0) raise("ZeroDivisionError", "float division by zero");
            return F(l / b);
        }
        return F(l);
    }
    if (name == "log2" || name == "log10") {
        need(1);
        double l = logn(E, args[0], ctx);
        if (args[0].type != ValueType::INTEGER) {
            double x = real(E, args[0], ctx);
            return F(name == "log2" ? std::log2(x) : std::log10(x));
        }
        BigInt b = big(E, args[0], "log");
        double d = b.to_double();
        if (std::isfinite(d)) return F(name == "log2" ? std::log2(d) : std::log10(d));
        return F(l / std::log(name == "log2" ? 2.0 : 10.0));
    }
    if (name == "log1p") {
        double x = x0();
        if (x <= -1.0) domain();
        return F(std::log1p(x));
    }
    if (name == "gamma") {
        double x = x0();
        if (x == std::floor(x) && x <= 0) domain();
        double r = std::tgamma(x);
        if (std::isinf(r) && std::isfinite(x)) range_err();
        return F(r);
    }
    if (name == "lgamma") {
        double x = x0();
        if (x == std::floor(x) && x <= 0) domain();
        double r = std::lgamma(x);
        if (std::isinf(r) && std::isfinite(x)) range_err();
        return F(r);
    }

    // ── integer-valued ──
    if (name == "floor" || name == "ceil" || name == "trunc") {
        need(1);
        if (is_int(args[0])) return args[0].type == ValueType::BOOLEAN ? intValue(args[0].value.b ? 1 : 0) : args[0];
        if (E.isInstanceValue(args[0]) && E.instanceHasMethod(args[0], "__" + name + "__")) {
            std::vector<Value> no;
            return E.callMethod(args[0], "__" + name + "__", no, ctx);
        }
        double x = real(E, args[0], ctx);
        return int_of_double(name == "floor" ? std::floor(x) : name == "ceil" ? std::ceil(x) : std::trunc(x));
    }
    if (name == "factorial") {
        need(1);
        if (args[0].type == ValueType::DOUBLE) raise("TypeError", "'float' object cannot be interpreted as an integer");
        BigInt n = big(E, args[0], "factorial");
        if (n.neg) raise("ValueError", "factorial() not defined for negative values");
        int64_t k;
        if (!n.to_i64(k) || k > 100000) raise("OverflowError", "factorial() argument should not exceed 100000");
        // product tree: balanced multiplications stay fast for large n
        std::vector<BigInt> terms;
        for (int64_t i = 2; i <= k; i++) terms.push_back(BigInt(i));
        if (terms.empty()) return intValue(1);
        while (terms.size() > 1) {
            std::vector<BigInt> next;
            for (size_t i = 0; i + 1 < terms.size(); i += 2) next.push_back(terms[i] * terms[i + 1]);
            if (terms.size() % 2) next.push_back(terms.back());
            terms.swap(next);
        }
        return intValue(terms[0]);
    }
    if (name == "gcd" || name == "lcm") {
        if (args.empty()) return intValue(name == "gcd" ? 0 : 1);
        BigInt acc = babs(big(E, args[0], name.c_str()));
        for (size_t i = 1; i < args.size(); i++) {
            BigInt b = babs(big(E, args[i], name.c_str()));
            if (name == "gcd") acc = bgcd(acc, b);
            else {
                if (acc.is_zero() || b.is_zero()) { acc = BigInt(0); continue; }
                BigInt g = bgcd(acc, b), q, r;
                BigInt::floordivmod(acc, g, q, r);
                acc = q * b;
            }
        }
        return intValue(acc);
    }
    if (name == "isqrt") {
        need(1);
        BigInt n = big(E, args[0], "isqrt");
        if (n.neg) raise("ValueError", "isqrt() argument must be nonnegative");
        return intValue(bisqrt(n));
    }
    if (name == "comb" || name == "perm") {
        need(1);
        BigInt n = big(E, args[0], name.c_str());
        bool has_k = A.has(1, "k") && A.get(1, "k").type != ValueType::NONE;
        if (name == "comb") need(2);
        BigInt k = has_k ? big(E, A.get(1, "k"), name.c_str()) : n;
        if (n.neg) raise("ValueError", "n must be a non-negative integer");
        if (k.neg) raise("ValueError", "k must be a non-negative integer");
        if (BigInt::cmp(k, n) > 0) return intValue(0);
        int64_t kk;
        if (!k.to_i64(kk)) raise("OverflowError", "min(n - k, k) must not exceed 9223372036854775807");
        if (name == "comb") {
            BigInt nk = n - k;
            int64_t alt;
            if (nk.to_i64(alt) && alt < kk) kk = alt;
            BigInt r(1);
            for (int64_t i = 1; i <= kk; i++) {
                BigInt q, rem;
                r = r * (n - BigInt(kk) + BigInt(i));
                BigInt::floordivmod(r, BigInt(i), q, rem);
                r = q;
            }
            return intValue(r);
        }
        BigInt r(1);
        for (int64_t i = 0; i < kk; i++) r = r * (n - BigInt(i));
        return intValue(r);
    }

    // ── two-argument and the rest ──
    if (name == "pow") {
        need(2);
        double x = real(E, args[0], ctx), y = real(E, args[1], ctx);
        if (x == 0.0 && y < 0 && std::isfinite(y)) domain();
        if (x < 0 && std::isfinite(x) && std::isfinite(y) && y != std::floor(y)) domain();
        double r = std::pow(x, y);
        if (std::isinf(r) && std::isfinite(x) && std::isfinite(y)) range_err();
        return F(r);
    }
    if (name == "atan2") { need(2); return F(std::atan2(real(E, args[0], ctx), real(E, args[1], ctx))); }
    if (name == "copysign") { need(2); return F(std::copysign(real(E, args[0], ctx), real(E, args[1], ctx))); }
    if (name == "fmod") {
        need(2);
        double x = real(E, args[0], ctx), y = real(E, args[1], ctx);
        if (std::isinf(x) && !std::isnan(y)) domain();
        if (y == 0.0 && !std::isnan(x)) domain();
        return F(std::fmod(x, y));
    }
    if (name == "remainder") {
        need(2);
        double x = real(E, args[0], ctx), y = real(E, args[1], ctx);
        if ((std::isinf(x) && !std::isnan(y)) || (y == 0.0 && !std::isnan(x))) domain();
        return F(std::remainder(x, y));
    }
    if (name == "ldexp") {
        need(2);
        double x = real(E, args[0], ctx);
        if (args[1].type == ValueType::DOUBLE) raise("TypeError", "Expected an int as second argument to ldexp.");
        BigInt e = big(E, args[1], "ldexp");
        int64_t ei;
        if (!e.to_i64(ei)) ei = e.neg ? INT64_MIN / 2 : INT64_MAX / 2;
        if (ei > 100000) ei = 100000;
        if (ei < -100000) ei = -100000;
        double r = std::ldexp(x, (int)ei);
        if (std::isinf(r) && std::isfinite(x)) range_err();
        return F(r);
    }
    if (name == "frexp") {
        double x = x0();
        int e = 0;
        double m = std::frexp(x, &e);
        std::vector<Value> t{F(m), intValue((int64_t)e)};
        return E.makeListValue(t, true);
    }
    if (name == "modf") {
        double x = x0();
        double ip = 0;
        double fp = std::isinf(x) ? std::copysign(0.0, x) : std::modf(x, &ip);
        if (std::isinf(x)) ip = x;
        std::vector<Value> t{F(fp), F(ip)};
        return E.makeListValue(t, true);
    }
    if (name == "isfinite") return Value((bool)std::isfinite(x0()));
    if (name == "isinf") return Value((bool)std::isinf(x0()));
    if (name == "isnan") return Value((bool)std::isnan(x0()));
    if (name == "isclose") {
        need(2);
        double a = real(E, args[0], ctx), b = real(E, args[1], ctx);
        double rel = A.has(2, "rel_tol") ? real(E, A.get(2, "rel_tol"), ctx) : 1e-9;
        double abs_ = A.has(3, "abs_tol") ? real(E, A.get(3, "abs_tol"), ctx) : 0.0;
        if (rel < 0 || abs_ < 0) raise("ValueError", "tolerances must be non-negative");
        if (a == b) return Value(true);
        if (std::isinf(a) || std::isinf(b)) return Value(false);
        double d = std::fabs(b - a);
        return Value(d <= std::fabs(rel * b) || d <= std::fabs(rel * a) || d <= abs_);
    }
    if (name == "hypot") {
        double acc = 0, scale = 0;
        bool any_inf = false, any_nan = false;
        std::vector<double> xs;
        for (auto& v : args) { double x = std::fabs(real(E, v, ctx)); xs.push_back(x); any_inf |= std::isinf(x); any_nan |= std::isnan(x); if (x > scale) scale = x; }
        if (any_inf) return F(INFINITY);
        if (any_nan) return F(NAN);
        if (scale == 0) return F(0.0);
        for (double x : xs) { double t = x / scale; acc += t * t; }
        return F(scale * std::sqrt(acc));
    }
    if (name == "dist") {
        need(2);
        std::vector<Value> p = E.iterItems(args[0], ctx), q = E.iterItems(args[1], ctx);
        if (p.size() != q.size()) raise("ValueError", "both points must have the same number of dimensions");
        double scale = 0, acc = 0;
        std::vector<double> ds;
        for (size_t i = 0; i < p.size(); i++) { double d = std::fabs(real(E, p[i], ctx) - real(E, q[i], ctx)); ds.push_back(d); if (d > scale) scale = d; }
        if (std::isinf(scale)) return F(INFINITY);
        if (scale == 0) return F(0.0);
        for (double d : ds) { double t = d / scale; acc += t * t; }
        return F(scale * std::sqrt(acc));
    }
    if (name == "fsum") {
        need(1);
        std::vector<double> xs;
        for (auto& v : E.iterItems(args[0], ctx)) xs.push_back(real(E, v, ctx));
        double r = fsum(xs);
        if (std::isinf(r)) {
            bool all_finite = true;
            for (double x : xs) all_finite = all_finite && std::isfinite(x);
            if (all_finite) raise("OverflowError", "intermediate overflow in fsum");
        }
        return F(r);
    }
    if (name == "prod" || name == "sumprod") {
        if (name == "sumprod") {
            need(2);
            std::vector<Value> p = E.iterItems(args[0], ctx), q = E.iterItems(args[1], ctx);
            if (p.size() != q.size()) raise("ValueError", "Inputs are not the same length");
            bool all_int = true;
            for (auto& v : p) all_int = all_int && is_int(v);
            for (auto& v : q) all_int = all_int && is_int(v);
            if (all_int) {
                BigInt s(0);
                for (size_t i = 0; i < p.size(); i++) s = s + big(E, p[i], "sumprod") * big(E, q[i], "sumprod");
                return intValue(s);
            }
            // Each product exactly, as its rounded value plus the rounding
            // error (fma), and fsum's correctly rounded total of those: the
            // nearest double to the exact dot product, which is what
            // Python's extended-precision sumprod gives. Summing the
            // rounded products could be an ulp off (statistics.correlation
            // and linear_regression differed from CPython's).
            std::vector<double> terms;
            for (size_t i = 0; i < p.size(); i++) {
                double a = real(E, p[i], ctx), b = real(E, q[i], ctx);
                double pr = a * b;
                terms.push_back(pr);
                if (std::isfinite(pr)) terms.push_back(std::fma(a, b, -pr));
            }
            return F(fsum(terms));
        }
        need(1);
        Value start = A.has(1, "start") ? A.get(1, "start") : intValue(1);
        std::vector<Value> items = E.iterItems(args[0], ctx);
        bool all_int = is_int(start);
        for (auto& v : items) all_int = all_int && is_int(v);
        if (all_int) {
            BigInt r = big(E, start, "prod");
            for (auto& v : items) r = r * big(E, v, "prod");
            return intValue(r);
        }
        double r = real(E, start, ctx);
        for (auto& v : items) r *= real(E, v, ctx);
        return F(r);
    }
    if (name == "nextafter") {
        need(2);
        double x = real(E, args[0], ctx), y = real(E, args[1], ctx);
        int64_t steps = 1;
        if (A.has(2, "steps") && A.get(2, "steps").type != ValueType::NONE) {
            BigInt s = big(E, A.get(2, "steps"), "nextafter");
            if (s.neg) raise("ValueError", "steps must be a non-negative integer");
            if (!s.to_i64(steps)) steps = INT64_MAX;
        }
        for (int64_t i = 0; i < steps && x != y; i++) x = std::nextafter(x, y);
        return F(x);
    }
    if (name == "ulp") {
        double x = std::fabs(x0());
        if (std::isnan(x) || std::isinf(x)) return F(x);
        if (x == DBL_MAX) return F(x - std::nextafter(x, 0.0));
        return F(std::nextafter(x, INFINITY) - x);
    }
    return UNDEFINED_VALUE;
}
