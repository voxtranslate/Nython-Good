#pragma once
// NyBigInt.hpp - arbitrary-precision integers with Python semantics, shared by
// both engines.
//
// Both engines keep small integers in a machine word (the interpreter in a
// one-limb nython::kernel::bigint, the VM in an int64_t) and only fall back to
// this type when a result does not fit. The library bigint in bigint.hpp is
// kept as the interpreter's storage type, but its arithmetic is not used:
// multiplication is bit-serial, bitwise operators are sign-magnitude (so
// -1 & 0xFF was 1, not 255), its `long long` conversion drops the sign, and
// division truncates instead of flooring.
//
// Representation: sign + magnitude in base 2^32, little-endian, no leading
// zero limbs; zero is an empty magnitude with neg == false.
#include <cstdint>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <algorithm>
#include <stdexcept>

namespace nypy {

// A Python exception raised by the shared code: each engine converts it to
// its own representation (the interpreter's "__exc__:Type:msg" string, the
// VM's runtime_error / exception instance).
struct PyError {
    std::string type, msg;
    PyError(std::string t, std::string m) : type(std::move(t)), msg(std::move(m)) {}
};
[[noreturn]] inline void raise(const char* type, const std::string& msg) { throw PyError(type, msg); }

struct BigInt {
    bool neg = false;
    std::vector<uint32_t> mag;

    BigInt() = default;
    BigInt(int64_t v) { set_i64(v); }
    static BigInt from_u64(uint64_t u) { BigInt r; r.set_u64(u); return r; }

    void set_u64(uint64_t u) {
        mag.clear(); neg = false;
        while (u) { mag.push_back((uint32_t)u); u >>= 32; }
    }
    void set_i64(int64_t v) {
        uint64_t u = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
        set_u64(u);
        neg = v < 0;
    }
    bool is_zero() const { return mag.empty(); }
    void trim() {
        while (!mag.empty() && mag.back() == 0) mag.pop_back();
        if (mag.empty()) neg = false;
    }
    // Fits in int64_t? Stores it in out when it does.
    bool to_i64(int64_t& out) const {
        if (mag.size() > 2) return false;
        uint64_t u = 0;
        if (mag.size() > 0) u = mag[0];
        if (mag.size() > 1) u |= (uint64_t)mag[1] << 32;
        if (!neg) { if (u > (uint64_t)INT64_MAX) return false; out = (int64_t)u; return true; }
        if (u > (uint64_t)INT64_MAX + 1) return false;
        out = (int64_t)((uint64_t)0 - u);
        return true;
    }
    bool fits_i64() const { int64_t t; return to_i64(t); }
    // Low 64 bits as two's complement (C cast semantics).
    int64_t wrap_i64() const {
        uint64_t u = 0;
        if (mag.size() > 0) u = mag[0];
        if (mag.size() > 1) u |= (uint64_t)mag[1] << 32;
        return neg ? (int64_t)((uint64_t)0 - u) : (int64_t)u;
    }
    // Correctly rounded (half to even), as Python's float(int): the top 64
    // bits with every lower bit folded into the last one (a sticky bit, far
    // below a double's 53), converted once; inf past the double range. The
    // top 96 bits through long double rounded twice and could be off by one
    // ulp (stdlib statistics/fractions rely on Python's exact rounding).
    double to_double() const {
        if (mag.empty()) return 0.0;
        size_t n = bit_length();
        uint64_t top;
        if (n <= 64) {
            top = mag[0];
            if (mag.size() > 1) top |= (uint64_t)mag[1] << 32;
            double d = (double)top;
            return neg ? -d : d;
        }
        size_t sh = n - 64;
        BigInt t = abs_shr(sh);
        top = t.mag[0] | ((uint64_t)t.mag[1] << 32);
        bool sticky = false;
        size_t limbs = sh / 32, bits = sh % 32;
        for (size_t i = 0; i < limbs && !sticky; i++) sticky = mag[i] != 0;
        if (!sticky && bits) sticky = (mag[limbs] & ((1u << bits) - 1)) != 0;
        if (sticky) top |= 1;
        double d = n - 64 > 2000 ? HUGE_VAL : std::ldexp((double)top, (int)sh);
        return neg ? -d : d;
    }
    // |this| >> n (to_double's helper; shr floors negative values).
    BigInt abs_shr(size_t n) const {
        BigInt a = *this;
        a.neg = false;
        return a.shr((int64_t)n);
    }
    // Exact conversion of an integral-valued double (the caller truncates).
    static BigInt from_double(double d) {
        BigInt r;
        if (!(d == d) || std::isinf(d)) return r;
        d = std::trunc(d);
        bool n = d < 0; if (n) d = -d;
        if (d < 18446744073709551616.0) { r.set_u64((uint64_t)d); r.neg = n && !r.is_zero(); return r; }
        int e; double m = std::frexp(d, &e);            // d = m * 2^e, 0.5 <= m < 1
        uint64_t mant = (uint64_t)std::ldexp(m, 64);    // exact: 53 significant bits
        r.set_u64(mant);
        r = r.shl(e - 64);
        r.neg = n && !r.is_zero();
        return r;
    }

    // ── comparison ──────────────────────────────────────────────────────
    static int cmp_mag(const std::vector<uint32_t>& a, const std::vector<uint32_t>& b) {
        if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
        for (size_t i = a.size(); i-- > 0;) if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
        return 0;
    }
    static int cmp(const BigInt& a, const BigInt& b) {
        if (a.neg != b.neg) return a.neg ? -1 : 1;
        int c = cmp_mag(a.mag, b.mag);
        return a.neg ? -c : c;
    }
    bool operator==(const BigInt& o) const { return neg == o.neg && mag == o.mag; }
    bool operator!=(const BigInt& o) const { return !(*this == o); }
    bool operator<(const BigInt& o) const { return cmp(*this, o) < 0; }

    // ── magnitude helpers ───────────────────────────────────────────────
    static std::vector<uint32_t> add_mag(const std::vector<uint32_t>& a, const std::vector<uint32_t>& b) {
        const auto& x = a.size() >= b.size() ? a : b;
        const auto& y = a.size() >= b.size() ? b : a;
        std::vector<uint32_t> r(x.size() + 1);
        uint64_t c = 0;
        for (size_t i = 0; i < x.size(); i++) {
            uint64_t s = (uint64_t)x[i] + (i < y.size() ? y[i] : 0) + c;
            r[i] = (uint32_t)s; c = s >> 32;
        }
        r[x.size()] = (uint32_t)c;
        while (!r.empty() && r.back() == 0) r.pop_back();
        return r;
    }
    // a - b, requires |a| >= |b|
    static std::vector<uint32_t> sub_mag(const std::vector<uint32_t>& a, const std::vector<uint32_t>& b) {
        std::vector<uint32_t> r(a.size());
        int64_t br = 0;
        for (size_t i = 0; i < a.size(); i++) {
            int64_t s = (int64_t)a[i] - (i < b.size() ? b[i] : 0) - br;
            if (s < 0) { s += ((int64_t)1 << 32); br = 1; } else br = 0;
            r[i] = (uint32_t)s;
        }
        while (!r.empty() && r.back() == 0) r.pop_back();
        return r;
    }
    static std::vector<uint32_t> mul_mag(const std::vector<uint32_t>& a, const std::vector<uint32_t>& b) {
        if (a.empty() || b.empty()) return {};
        std::vector<uint32_t> r(a.size() + b.size());
        for (size_t i = 0; i < a.size(); i++) {
            uint64_t c = 0, ai = a[i];
            if (!ai) continue;
            for (size_t j = 0; j < b.size(); j++) {
                uint64_t t = ai * b[j] + r[i + j] + c;
                r[i + j] = (uint32_t)t; c = t >> 32;
            }
            size_t k = i + b.size();
            while (c) { uint64_t t = (uint64_t)r[k] + c; r[k] = (uint32_t)t; c = t >> 32; k++; }
        }
        while (!r.empty() && r.back() == 0) r.pop_back();
        return r;
    }
    // Divide magnitude by a single limb; returns remainder.
    static uint32_t divmod_small(std::vector<uint32_t>& a, uint32_t d) {
        uint64_t rem = 0;
        for (size_t i = a.size(); i-- > 0;) {
            uint64_t cur = (rem << 32) | a[i];
            a[i] = (uint32_t)(cur / d); rem = cur % d;
        }
        while (!a.empty() && a.back() == 0) a.pop_back();
        return (uint32_t)rem;
    }
    // Knuth algorithm D on magnitudes: q = a / b, r = a % b (truncating).
    static void divmod_mag(const std::vector<uint32_t>& a, const std::vector<uint32_t>& b,
                           std::vector<uint32_t>& q, std::vector<uint32_t>& r) {
        if (b.empty()) throw std::runtime_error("division by zero");
        if (cmp_mag(a, b) < 0) { q.clear(); r = a; return; }
        if (b.size() == 1) { q = a; uint32_t rm = divmod_small(q, b[0]); r.clear(); if (rm) r.push_back(rm); return; }
        int s = __builtin_clz(b.back());
        std::vector<uint32_t> bn(b.size()), an(a.size() + 1);
        for (size_t i = b.size() - 1; i > 0; i--) bn[i] = (b[i] << s) | (s ? (uint32_t)((uint64_t)b[i-1] >> (32 - s)) : 0);
        bn[0] = b[0] << s;
        an[a.size()] = s ? (uint32_t)((uint64_t)a.back() >> (32 - s)) : 0;
        for (size_t i = a.size() - 1; i > 0; i--) an[i] = (a[i] << s) | (s ? (uint32_t)((uint64_t)a[i-1] >> (32 - s)) : 0);
        an[0] = a[0] << s;
        size_t n = b.size(), m = a.size() - b.size();
        q.assign(m + 1, 0);
        const uint64_t B = (uint64_t)1 << 32;
        for (size_t j = m + 1; j-- > 0;) {
            uint64_t num = ((uint64_t)an[j + n] << 32) | an[j + n - 1];
            uint64_t qhat = num / bn[n - 1], rhat = num % bn[n - 1];
            while (qhat >= B || qhat * bn[n - 2] > ((rhat << 32) | an[j + n - 2])) {
                qhat--; rhat += bn[n - 1];
                if (rhat >= B) break;
            }
            int64_t borrow = 0; uint64_t carry = 0;
            for (size_t i = 0; i < n; i++) {
                uint64_t p = qhat * bn[i] + carry;
                carry = p >> 32;
                int64_t t = (int64_t)an[i + j] - (int64_t)(uint32_t)p - borrow;
                if (t < 0) { t += (int64_t)B; borrow = 1; } else borrow = 0;
                an[i + j] = (uint32_t)t;
            }
            int64_t t = (int64_t)an[j + n] - (int64_t)carry - borrow;
            if (t < 0) {
                an[j + n] = (uint32_t)(t + (int64_t)B);
                qhat--;
                uint64_t c = 0;
                for (size_t i = 0; i < n; i++) {
                    uint64_t s2 = (uint64_t)an[i + j] + bn[i] + c;
                    an[i + j] = (uint32_t)s2; c = s2 >> 32;
                }
                an[j + n] = (uint32_t)((uint64_t)an[j + n] + c);
            } else an[j + n] = (uint32_t)t;
            q[j] = (uint32_t)qhat;
        }
        while (!q.empty() && q.back() == 0) q.pop_back();
        r.assign(n, 0);
        for (size_t i = 0; i < n; i++) r[i] = (an[i] >> s) | (s ? (uint32_t)((uint64_t)an[i + 1] << (32 - s)) : 0);
        while (!r.empty() && r.back() == 0) r.pop_back();
    }

    // ── arithmetic ──────────────────────────────────────────────────────
    friend BigInt operator-(const BigInt& a) { BigInt r = a; if (!r.is_zero()) r.neg = !r.neg; return r; }
    friend BigInt operator+(const BigInt& a, const BigInt& b) {
        BigInt r;
        if (a.neg == b.neg) { r.mag = add_mag(a.mag, b.mag); r.neg = a.neg; }
        else {
            int c = cmp_mag(a.mag, b.mag);
            if (c == 0) return r;
            if (c > 0) { r.mag = sub_mag(a.mag, b.mag); r.neg = a.neg; }
            else { r.mag = sub_mag(b.mag, a.mag); r.neg = b.neg; }
        }
        r.trim(); return r;
    }
    friend BigInt operator-(const BigInt& a, const BigInt& b) { return a + (-b); }
    friend BigInt operator*(const BigInt& a, const BigInt& b) {
        BigInt r; r.mag = mul_mag(a.mag, b.mag); r.neg = (a.neg != b.neg); r.trim(); return r;
    }
    // Floor division and modulo (Python): q = floor(a / b), r = a - q*b,
    // r has the sign of b.
    static void floordivmod(const BigInt& a, const BigInt& b, BigInt& q, BigInt& r) {
        if (b.is_zero()) throw std::runtime_error("division by zero");
        BigInt qq, rr;
        divmod_mag(a.mag, b.mag, qq.mag, rr.mag);
        qq.neg = (a.neg != b.neg); rr.neg = a.neg;
        qq.trim(); rr.trim();
        if (!rr.is_zero() && (rr.neg != b.neg)) { qq = qq - BigInt(1); rr = rr + b; }
        q = qq; r = rr;
    }
    BigInt pow(uint64_t e) const {
        BigInt result(1), base = *this;
        while (e) { if (e & 1) result = result * base; e >>= 1; if (e) base = base * base; }
        return result;
    }
    BigInt shl(int64_t n) const {
        if (n < 0) return shr(-n);
        if (is_zero() || n == 0) return *this;
        BigInt r; r.neg = neg;
        size_t limbs = (size_t)(n / 32); int bits = (int)(n % 32);
        r.mag.assign(limbs, 0);
        uint32_t carry = 0;
        for (uint32_t x : mag) {
            r.mag.push_back(bits ? ((x << bits) | carry) : x);
            carry = bits ? (uint32_t)((uint64_t)x >> (32 - bits)) : 0;
        }
        if (carry) r.mag.push_back(carry);
        r.trim(); return r;
    }
    // Arithmetic (floor) right shift: -5 >> 1 == -3.
    BigInt shr(int64_t n) const {
        if (n < 0) return shl(-n);
        if (is_zero() || n == 0) return *this;
        if (neg) {
            // floor(a / 2^n) for negative a == -(((-a) - 1) >> n) - 1
            BigInt t = (-*this) - BigInt(1);
            BigInt s = t.shr(n);
            return -s - BigInt(1);
        }
        size_t limbs = (size_t)(n / 32); int bits = (int)(n % 32);
        BigInt r;
        if (limbs >= mag.size()) return r;
        for (size_t i = limbs; i < mag.size(); i++) {
            uint32_t lo = mag[i] >> bits;
            uint32_t hi = (bits && i + 1 < mag.size()) ? (uint32_t)((uint64_t)mag[i + 1] << (32 - bits)) : 0;
            r.mag.push_back(lo | hi);
        }
        r.trim(); return r;
    }
    // Two's complement limbs of width n (n > magnitude size).
    std::vector<uint32_t> twos(size_t n) const {
        std::vector<uint32_t> r(n, 0);
        for (size_t i = 0; i < mag.size() && i < n; i++) r[i] = mag[i];
        if (neg) {
            uint64_t c = 1;
            for (size_t i = 0; i < n; i++) { uint64_t t = (uint64_t)(uint32_t)~r[i] + c; r[i] = (uint32_t)t; c = t >> 32; }
        }
        return r;
    }
    static BigInt from_twos(std::vector<uint32_t> r) {
        BigInt out;
        bool n = !r.empty() && (r.back() & 0x80000000u);
        if (n) {
            uint64_t c = 1;
            for (size_t i = 0; i < r.size(); i++) { uint64_t t = (uint64_t)(uint32_t)~r[i] + c; r[i] = (uint32_t)t; c = t >> 32; }
        }
        out.mag = std::move(r); out.neg = n; out.trim();
        return out;
    }
    static BigInt bitop(const BigInt& a, const BigInt& b, char op) {
        size_t n = std::max(a.mag.size(), b.mag.size()) + 1;
        auto x = a.twos(n), y = b.twos(n);
        for (size_t i = 0; i < n; i++) {
            if (op == '&') x[i] &= y[i]; else if (op == '|') x[i] |= y[i]; else x[i] ^= y[i];
        }
        return from_twos(std::move(x));
    }
    size_t bit_length() const {
        if (mag.empty()) return 0;
        return 32 * (mag.size() - 1) + (32 - __builtin_clz(mag.back()));
    }

    // ── text ────────────────────────────────────────────────────────────
    std::string to_string(int base = 10) const {
        if (mag.empty()) return "0";
        std::string out;
        std::vector<uint32_t> t = mag;
        if (base == 10) {
            while (!t.empty()) {
                uint32_t rem = divmod_small(t, 1000000000u);
                char buf[16]; int len = 0;
                for (int k = 0; k < 9; k++) { buf[len++] = (char)('0' + rem % 10); rem /= 10; if (t.empty() && rem == 0) break; }
                out.append(buf, (size_t)len);
            }
        } else {
            static const char* D = "0123456789abcdefghijklmnopqrstuvwxyz";
            while (!t.empty()) out.push_back(D[divmod_small(t, (uint32_t)base)]);
        }
        while (out.size() > 1 && out.back() == '0') out.pop_back();
        if (neg) out.push_back('-');
        std::reverse(out.begin(), out.end());
        return out;
    }
    // Parses optional sign and digits in `base` (no prefix, no underscores,
    // no whitespace). Returns false on any invalid character.
    static bool parse(const std::string& s, int base, BigInt& out) {
        out = BigInt();
        size_t i = 0; bool n = false;
        if (i < s.size() && (s[i] == '+' || s[i] == '-')) { n = s[i] == '-'; i++; }
        if (i >= s.size()) return false;
        std::vector<uint32_t> m;
        // Accumulate chunks: m = m * base^k + chunk
        while (i < s.size()) {
            uint32_t chunk = 0, mul = 1;
            while (i < s.size() && (uint64_t)mul * (uint64_t)base <= 0xFFFFFFFFull) {
                char c = s[i]; int d;
                if (c >= '0' && c <= '9') d = c - '0';
                else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
                else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
                else return false;
                if (d >= base) return false;
                chunk = chunk * (uint32_t)base + (uint32_t)d; mul *= (uint32_t)base; i++;
            }
            uint64_t c = chunk;
            for (auto& limb : m) { uint64_t t = (uint64_t)limb * mul + c; limb = (uint32_t)t; c = t >> 32; }
            if (c) m.push_back((uint32_t)c);
        }
        while (!m.empty() && m.back() == 0) m.pop_back();
        out.mag = std::move(m); out.neg = n && !out.mag.empty();
        return true;
    }
};

// 64-bit fast paths with overflow detection, used by both engines before
// falling back to BigInt.
inline bool add_ovf(int64_t a, int64_t b, int64_t& r) { return __builtin_add_overflow(a, b, &r); }
inline bool sub_ovf(int64_t a, int64_t b, int64_t& r) { return __builtin_sub_overflow(a, b, &r); }
inline bool mul_ovf(int64_t a, int64_t b, int64_t& r) { return __builtin_mul_overflow(a, b, &r); }
// Python floor division / modulo on int64 (caller checks b != 0 and the
// INT64_MIN / -1 overflow).
inline int64_t floordiv_i64(int64_t a, int64_t b) {
    int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
    return q;
}
inline int64_t floormod_i64(int64_t a, int64_t b) {
    int64_t m = a % b;
    if (m != 0 && ((m < 0) != (b < 0))) m += b;
    return m;
}
// Python float floor-division and modulo.
inline double floormod_f(double a, double b) {
    double m = std::fmod(a, b);
    if (m != 0.0) { if ((b < 0) != (m < 0)) m += b; }
    else m = std::copysign(0.0, b);
    return m;
}
inline double floordiv_f(double a, double b) {
    double m = std::fmod(a, b);
    double div = (a - m) / b;
    if (m != 0.0 && ((b < 0) != (m < 0))) div -= 1.0;
    double fl;
    if (div != 0.0) { fl = std::floor(div); if (div - fl > 0.5) fl += 1.0; }
    else fl = std::copysign(0.0, a / b);
    return fl;
}

// ── numbers, engine-neutral ─────────────────────────────────────────────
// A numeric operand or result: k = 1 machine int, 2 big int, 3 float. bool
// is an int. Both engines convert their values to NumV for arithmetic, so
// the rules (ints never overflow, `/` is true division, `//` and `%` floor,
// the error for each bad case) are written once.
struct NumV {
    int k = 1;
    int64_t i = 0;
    double d = 0.0;
    BigInt b;
    static NumV I(int64_t v) { NumV n; n.k = 1; n.i = v; return n; }
    static NumV F(double v) { NumV n; n.k = 3; n.d = v; return n; }
    static NumV B(BigInt v) { int64_t t; if (v.to_i64(t)) return I(t); NumV n; n.k = 2; n.b = std::move(v); return n; }
    BigInt big() const { return k == 2 ? b : BigInt(i); }
    double dbl() const { return k == 3 ? d : k == 2 ? b.to_double() : (double)i; }
    bool zero() const { return k == 3 ? d == 0.0 : k == 1 ? i == 0 : false; }
    bool neg() const { return k == 3 ? d < 0 : k == 1 ? i < 0 : b.neg; }
};
enum ArithOp { A_ADD = 1, A_SUB, A_MUL, A_DIV, A_FLOORDIV, A_MOD, A_POW, A_AND, A_OR, A_XOR, A_LSHIFT, A_RSHIFT };
inline const char* arith_symbol(int op) {
    static const char* s[] = {"?", "+", "-", "*", "/", "//", "%", "**", "&", "|", "^", "<<", ">>"};
    return (op >= 1 && op <= A_RSHIFT) ? s[op] : "?";
}
// -1/0/1, or 2 when unordered (a NaN is involved).
inline int num_cmp(const NumV& a, const NumV& b) {
    if (a.k == 1 && b.k == 1) return a.i < b.i ? -1 : a.i > b.i ? 1 : 0;
    if (a.k != 3 && b.k != 3) return BigInt::cmp(a.big(), b.big());
    double x = a.dbl(), y = b.dbl();
    if (x != x || y != y) return 2;
    if (a.k == 3 && b.k == 3) return x < y ? -1 : x > y ? 1 : 0;
    // int vs float: exact when the float is integral and large
    const NumV& f = a.k == 3 ? a : b;
    const NumV& n = a.k == 3 ? b : a;
    int sgn = a.k == 3 ? -1 : 1;   // result from n's point of view, flipped if n is b
    double fd = f.d;
    int r;
    if (std::isinf(fd)) r = fd > 0 ? -1 : 1;
    else if (fd == std::trunc(fd) && std::fabs(fd) >= 9007199254740992.0) r = BigInt::cmp(n.big(), BigInt::from_double(fd));
    else { double nd = n.dbl(); r = nd < fd ? -1 : nd > fd ? 1 : 0; }
    return sgn == 1 ? r : -r;
}
// a / b for integers, correctly rounded as Python's (CPython's
// long_true_divide): the quotient to at least 55 significant bits, a sticky
// bit for a nonzero remainder, one rounding half to even - so 10**25 / 7 is
// the nearest double and 10**400 / 10**399 is 10.0 (both were computed as
// double / double: off by an ulp, and nan past the double range).
inline double int_true_div(const BigInt& a, const BigInt& b) {
    const int MANT = 53, MIN_EXP = -1021, MAX_EXP = 1024;
    bool negr = a.neg != b.neg;
    if (a.is_zero()) return negr ? -0.0 : 0.0;
    BigInt x = a, y = b;
    x.neg = false; y.neg = false;
    int64_t na = (int64_t)x.bit_length(), nb = (int64_t)y.bit_length();
    if (na <= MANT && nb <= MANT) {
        double r = x.to_double() / y.to_double();     // exact operands, one rounding
        return negr ? -r : r;
    }
    int64_t diff = na - nb;
    if (diff > MAX_EXP) raise("OverflowError", "integer division result too large for a float");
    if (diff < MIN_EXP - MANT - 1) return negr ? -0.0 : 0.0;
    int64_t shift = std::max<int64_t>(diff, MIN_EXP) - MANT - 2;
    BigInt q, r;
    if (shift >= 0) BigInt::floordivmod(x, y.shl(shift), q, r);
    else BigInt::floordivmod(x.shl(-shift), y, q, r);
    uint64_t low = q.mag.empty() ? 0 : q.mag[0];
    if (q.mag.size() > 1) low |= (uint64_t)q.mag[1] << 32;
    int64_t xbits = (int64_t)q.bit_length();
    int64_t extra = std::max<int64_t>(xbits, MIN_EXP - shift) - MANT;
    if (!r.is_zero()) low |= 1;
    uint64_t mask = (uint64_t)1 << (extra - 1);
    if ((low & mask) && (low & (3 * mask - 1))) low += mask;
    low &= ~(2 * mask - 1);
    double dx = (double)low;                             // exact: <= 53 significant bits
    if (shift + xbits >= MAX_EXP && (shift + xbits > MAX_EXP || dx == std::ldexp(1.0, (int)xbits)))
        raise("OverflowError", "integer division result too large for a float");
    double res = std::ldexp(dx, (int)shift);
    return negr ? -res : res;
}
inline bool fits_mant53(const NumV& v) {
    return v.k == 1 && v.i >= -9007199254740992LL && v.i <= 9007199254740992LL;
}

inline NumV arith(int op, const NumV& a, const NumV& b) {
    bool fl = a.k == 3 || b.k == 3;
    switch (op) {
    case A_ADD: case A_SUB: case A_MUL: {
        if (fl) { double x = a.dbl(), y = b.dbl(); return NumV::F(op == A_ADD ? x + y : op == A_SUB ? x - y : x * y); }
        if (a.k == 1 && b.k == 1) {
            int64_t r;
            bool o = op == A_ADD ? add_ovf(a.i, b.i, r) : op == A_SUB ? sub_ovf(a.i, b.i, r) : mul_ovf(a.i, b.i, r);
            if (!o) return NumV::I(r);
        }
        BigInt x = a.big(), y = b.big();
        return NumV::B(op == A_ADD ? x + y : op == A_SUB ? x - y : x * y);
    }
    case A_DIV:
        if (b.zero()) raise("ZeroDivisionError", fl ? "float division by zero" : "division by zero");
        if (!fl && !(fits_mant53(a) && fits_mant53(b))) return NumV::F(int_true_div(a.big(), b.big()));
        return NumV::F(a.dbl() / b.dbl());
    case A_FLOORDIV: case A_MOD: {
        if (b.zero()) raise("ZeroDivisionError", fl ? (op == A_MOD ? "float modulo" : "float floor division by zero")
                                                    : (op == A_MOD ? "integer modulo by zero" : "integer division or modulo by zero"));
        if (fl) { double x = a.dbl(), y = b.dbl(); return NumV::F(op == A_MOD ? floormod_f(x, y) : floordiv_f(x, y)); }
        if (a.k == 1 && b.k == 1 && !(a.i == INT64_MIN && b.i == -1))
            return NumV::I(op == A_MOD ? floormod_i64(a.i, b.i) : floordiv_i64(a.i, b.i));
        BigInt q, r;
        BigInt::floordivmod(a.big(), b.big(), q, r);
        return NumV::B(op == A_MOD ? r : q);
    }
    case A_POW: {
        if (!fl) {
            if (b.neg()) {
                if (a.zero()) raise("ZeroDivisionError", "0.0 cannot be raised to a negative power");
                return NumV::F(std::pow(a.dbl(), b.dbl()));
            }
            if (b.k == 2) {
                if (a.k == 1 && (a.i == 0 || a.i == 1)) return NumV::I(a.i);
                if (a.k == 1 && a.i == -1) return NumV::I((b.b.mag[0] & 1) ? -1 : 1);
                raise("OverflowError", "exponent too large");
            }
            if (a.k == 1) {
                int64_t base = a.i, r = 1; uint64_t e = (uint64_t)b.i; bool ovf = false;
                while (e) {
                    if (e & 1) { if (mul_ovf(r, base, r)) { ovf = true; break; } }
                    e >>= 1;
                    if (e && mul_ovf(base, base, base)) { ovf = true; break; }
                }
                if (!ovf) return NumV::I(r);
            }
            if (b.i > 100000000) raise("OverflowError", "exponent too large");
            return NumV::B(a.big().pow((uint64_t)b.i));
        }
        double x = a.dbl(), y = b.dbl();
        if (x == 0.0 && y < 0) raise("ZeroDivisionError", "0.0 cannot be raised to a negative power");
        if (x < 0 && y != std::trunc(y)) raise("ValueError", "negative number cannot be raised to a fractional power");
        double r = std::pow(x, y);
        if (std::isinf(r) && !std::isinf(x) && !std::isinf(y)) raise("OverflowError", "(34, 'Numerical result out of range')");
        return NumV::F(r);
    }
    case A_AND: case A_OR: case A_XOR: case A_LSHIFT: case A_RSHIFT: {
        if (fl) raise("TypeError", std::string("unsupported operand type(s) for ") + arith_symbol(op) + ": '" + (a.k == 3 ? "float" : "int") + "' and '" + (b.k == 3 ? "float" : "int") + "'");
        if (op == A_LSHIFT || op == A_RSHIFT) {
            if (b.neg()) raise("ValueError", "negative shift count");
            if (b.k == 2) {
                if (op == A_RSHIFT) return NumV::I(a.neg() ? -1 : 0);
                if (a.zero()) return NumV::I(0);
                raise("OverflowError", "too many digits in integer");
            }
            if (a.k == 1) {
                if (op == A_RSHIFT) return NumV::I(b.i >= 63 ? (a.i < 0 ? -1 : 0) : (a.i >> b.i));
                if (b.i < 63) {
                    int64_t r = (int64_t)((uint64_t)a.i << b.i);
                    if ((r >> b.i) == a.i) return NumV::I(r);
                }
            }
            if (b.i > 100000000) raise("OverflowError", "too many digits in integer");
            return NumV::B(op == A_LSHIFT ? a.big().shl(b.i) : a.big().shr(b.i));
        }
        if (a.k == 1 && b.k == 1) return NumV::I(op == A_AND ? (a.i & b.i) : op == A_OR ? (a.i | b.i) : (a.i ^ b.i));
        return NumV::B(BigInt::bitop(a.big(), b.big(), op == A_AND ? '&' : op == A_OR ? '|' : '^'));
    }
    default: raise("TypeError", "bad operand");
    }
}
inline NumV num_neg(const NumV& a) {
    if (a.k == 3) return NumV::F(-a.d);
    if (a.k == 1 && a.i != INT64_MIN) return NumV::I(-a.i);
    return NumV::B(-a.big());
}
inline NumV num_invert(const NumV& a) {
    if (a.k == 3) raise("TypeError", "bad operand type for unary ~: 'float'");
    if (a.k == 1) return NumV::I(~a.i);
    return NumV::B(-(a.b + BigInt(1)));
}
inline NumV num_abs(const NumV& a) { return a.neg() ? num_neg(a) : a; }
// pow(b, e, m)
inline NumV pow_mod(const NumV& b, const NumV& e, const NumV& m) {
    if (b.k == 3 || e.k == 3 || m.k == 3) raise("TypeError", "pow() 3rd argument not allowed unless all arguments are integers");
    if (m.zero()) raise("ValueError", "pow() 3rd argument cannot be 0");
    if (e.neg()) raise("ValueError", "pow() negative exponent with modulus is not supported");
    BigInt mod = m.big(), base = b.big(), ex = e.big(), q, r, result(1);
    BigInt::floordivmod(base, mod, q, base);
    BigInt::floordivmod(result, mod, q, result);
    size_t bits = ex.bit_length();
    for (size_t i = 0; i < bits; i++) {
        if ((ex.mag[i / 32] >> (i % 32)) & 1) { result = result * base; BigInt::floordivmod(result, mod, q, result); }
        base = base * base; BigInt::floordivmod(base, mod, q, base);
    }
    return NumV::B(result);
}

} // namespace nypy
