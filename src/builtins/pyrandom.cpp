// builtins/pyrandom.cpp - the Mersenne Twister behind lib/random.ny, bit
// for bit CPython's Modules/_randommodule.c, so a seed gives the numbers
// Python gives. Both engines: the VM reaches these through the builtin
// bridge.
//
// A generator's state is a bytearray the Nython object owns (624 words and
// the position, little-endian: 2500 bytes) and these functions update in
// place - nothing to free, and copy.copy / getstate / setstate stay simple.
//
//   _mt_seed(n) -> state               random.seed(n) for an int n: init_by_array
//                                      over |n|'s 32-bit words, low word first
//   _mt_random(st) -> float            random(): (a*2**26 + b) / 2**53 from two
//                                      outputs, a = x >> 5, b = y >> 6
//   _mt_getrandbits(st, k) -> int      k bits; words fill from the low end and a
//                                      partial top word keeps its high bits
//   _mt_randbelow(st, n) -> int        0 <= r < n: getrandbits(n.bit_length())
//                                      until below n (Random._randbelow)
//   _mt_getstate(st) -> tuple          the 624 words and the position
//   _mt_setstate(t) -> state           ValueError / TypeError as CPython's
//   _mt_shuffle(st, list)              Random.shuffle's swaps on a list, in place
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include <cstring>

Value dispatch_pyrandom(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> pyrandom_builtin_names();

namespace {

constexpr int N = 624;
constexpr int M = 397;
constexpr uint32_t MATRIX_A = 0x9908b0dfU;
constexpr uint32_t UPPER_MASK = 0x80000000U;
constexpr uint32_t LOWER_MASK = 0x7fffffffU;
constexpr size_t kStateBytes = (N + 1) * 4;

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }

struct MT {
    uint32_t mt[N];
    uint32_t index;

    void init_genrand(uint32_t s) {
        mt[0] = s;
        for (int i = 1; i < N; i++) mt[i] = 1812433253U * (mt[i - 1] ^ (mt[i - 1] >> 30)) + (uint32_t)i;
        index = N;
    }
    void init_by_array(const std::vector<uint32_t>& key) {
        init_genrand(19650218U);
        size_t i = 1, j = 0, len = key.size();
        size_t k = (size_t)N > len ? (size_t)N : len;
        for (; k; k--) {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) * 1664525U)) + key[j] + (uint32_t)j;
            i++; j++;
            if (i >= (size_t)N) { mt[0] = mt[N - 1]; i = 1; }
            if (j >= len) j = 0;
        }
        for (k = N - 1; k; k--) {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) * 1566083941U)) - (uint32_t)i;
            i++;
            if (i >= (size_t)N) { mt[0] = mt[N - 1]; i = 1; }
        }
        mt[0] = 0x80000000U;
    }
    uint32_t next() {
        static const uint32_t mag01[2] = {0x0U, MATRIX_A};
        uint32_t y;
        if (index >= (uint32_t)N) {
            int kk;
            for (kk = 0; kk < N - M; kk++) {
                y = (mt[kk] & UPPER_MASK) | (mt[kk + 1] & LOWER_MASK);
                mt[kk] = mt[kk + M] ^ (y >> 1) ^ mag01[y & 0x1U];
            }
            for (; kk < N - 1; kk++) {
                y = (mt[kk] & UPPER_MASK) | (mt[kk + 1] & LOWER_MASK);
                mt[kk] = mt[kk + (M - N)] ^ (y >> 1) ^ mag01[y & 0x1U];
            }
            y = (mt[N - 1] & UPPER_MASK) | (mt[0] & LOWER_MASK);
            mt[N - 1] = mt[M - 1] ^ (y >> 1) ^ mag01[y & 0x1U];
            index = 0;
        }
        y = mt[index++];
        y ^= (y >> 11);
        y ^= (y << 7) & 0x9d2c5680U;
        y ^= (y << 15) & 0xefc60000U;
        y ^= (y >> 18);
        return y;
    }
    // k >= 1 bits as 32-bit words, low word first
    std::vector<uint32_t> bits(int64_t k) {
        std::vector<uint32_t> w;
        w.reserve((size_t)((k - 1) / 32 + 1));
        for (; k > 0; k -= 32) {
            uint32_t r = next();
            if (k < 32) r >>= (32 - k);
            w.push_back(r);
        }
        return w;
    }
};

// The state bytes <-> MT, little-endian whatever the host.
void load(const std::string& b, MT& m) {
    const unsigned char* p = (const unsigned char*)b.data();
    for (int i = 0; i <= N; i++) {
        uint32_t v = (uint32_t)p[4 * i] | ((uint32_t)p[4 * i + 1] << 8) | ((uint32_t)p[4 * i + 2] << 16) | ((uint32_t)p[4 * i + 3] << 24);
        if (i < N) m.mt[i] = v; else m.index = v;
    }
}
void store(const MT& m, std::string& b) {
    b.resize(kStateBytes);
    unsigned char* p = (unsigned char*)&b[0];
    for (int i = 0; i <= N; i++) {
        uint32_t v = i < N ? m.mt[i] : m.index;
        p[4 * i] = (unsigned char)v; p[4 * i + 1] = (unsigned char)(v >> 8);
        p[4 * i + 2] = (unsigned char)(v >> 16); p[4 * i + 3] = (unsigned char)(v >> 24);
    }
}

// The generator a call works on, written back by the Use's destructor.
struct Use {
    nyheap::Bytes* bo;
    MT m;
    Use(NythonExecutor& E, const std::vector<Value>& args) : bo(args.empty() ? nullptr : E.bytesOf(args[0])), m() {
        if (!bo || !bo->mut || bo->s.size() != kStateBytes) fail("TypeError", "not a random generator state");
        load(bo->s, m);
        if (m.index > (uint32_t)N) m.index = N;
    }
    Use(const Use&) = delete;
    Use& operator=(const Use&) = delete;
    ~Use() { store(m, bo->s); }
};

nypy::BigInt big_of(const Value& v) {
    int64_t i;
    if (bigint_fits_i64(v.value.i, i)) return nypy::BigInt(i);
    return bigint_to_nbig(v.value.i);
}

Value from_words(const std::vector<uint32_t>& w) {
    nypy::BigInt b;
    b.mag = w;
    b.trim();
    return intValue(b);
}

} // namespace

std::vector<std::string> pyrandom_builtin_names() {
    return {"_mt_seed", "_mt_random", "_mt_getrandbits", "_mt_randbelow", "_mt_getstate", "_mt_setstate", "_mt_shuffle"};
}

Value dispatch_pyrandom(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name.compare(0, 4, "_mt_") != 0) return UNDEFINED_VALUE;

    if (name == "_mt_random") {
        Use u(E, args);
        uint32_t a = u.m.next() >> 5, b = u.m.next() >> 6;
        return Value((a * 67108864.0 + b) * (1.0 / 9007199254740992.0));
    }
    if (name == "_mt_getrandbits" || name == "_mt_randbelow") {
        if (args.size() < 2 || args[1].type != ValueType::INTEGER) fail("TypeError", "an integer is required");
        nypy::BigInt n = big_of(args[1]);
        Use u(E, args);
        if (name == "_mt_getrandbits") {
            if (n.neg) fail("ValueError", "number of bits must be non-negative");
            int64_t k;
            if (!n.to_i64(k) || k > ((int64_t)1 << 40)) fail("OverflowError", "getrandbits() bit count is too large");
            if (k == 0) return intValue((int64_t)0);
            if (k <= 32) return intValue((int64_t)(u.m.next() >> (32 - k)));
            return from_words(u.m.bits(k));
        }
        if (n.neg || n.is_zero()) fail("ValueError", "empty range for randrange()");
        int64_t k = (int64_t)n.bit_length();
        int64_t small;
        if (n.to_i64(small) && k <= 32) {
            uint32_t r;
            do r = u.m.next() >> (32 - k); while ((int64_t)r >= small);
            return intValue((int64_t)r);
        }
        while (true) {
            nypy::BigInt r;
            r.mag = u.m.bits(k);
            r.trim();
            if (nypy::BigInt::cmp(r, n) < 0) return intValue(r);
        }
    }
    if (name == "_mt_shuffle") {
        // Random.shuffle on a list: for i from n-1 down to 1, swap x[i] with
        // x[_randbelow(i + 1)] - the same draws as Python's loop
        if (args.size() < 2) fail("TypeError", "_mt_shuffle(state, list)");
        Container* c = E.contOf(args[1]);
        int64_t n = c ? NythonExecutor::seqLen(c) : -1;
        if (n < 0 || NythonExecutor::isTupleCont(c) || NythonExecutor::isSetCont(c)) fail("TypeError", "shuffle() needs a list");
        Use u(E, args);
        auto& m = *c->container;
        for (int64_t i = n - 1; i >= 1; i--) {
            uint64_t bound = (uint64_t)i + 1;
            int k = 0;
            while ((bound >> k) != 0) k++;          // bound.bit_length()
            uint64_t r;
            if (k <= 32) {
                do r = u.m.next() >> (32 - k); while (r >= bound);
            } else {
                do {
                    uint64_t lo = u.m.next();                  // the low word first
                    uint64_t hi = u.m.next() >> (64 - k);
                    r = lo | (hi << 32);
                } while (r >= bound);
            }
            if ((int64_t)r == i) continue;
            std::swap(m[std::to_string(i)], m[std::to_string((int64_t)r)]);
        }
        return NONE_VALUE;
    }
    if (name == "_mt_seed") {
        if (args.empty() || args[0].type != ValueType::INTEGER) fail("TypeError", "_mt_seed() needs an int");
        nypy::BigInt n = big_of(args[0]);
        std::vector<uint32_t> key = n.mag;        // |n|, low word first
        if (key.empty()) key.push_back(0);
        MT m;
        m.init_by_array(key);
        std::string st;
        store(m, st);
        return E.makeBytesValue(st, true);
    }
    if (name == "_mt_getstate") {
        Use u(E, args);
        std::vector<Value> items;
        items.reserve(N + 1);
        for (int i = 0; i < N; i++) items.push_back(intValue((int64_t)u.m.mt[i]));
        items.push_back(intValue((int64_t)u.m.index));
        return E.makeListValue(items, true);
    }
    if (name == "_mt_setstate") {
        Container* c = args.empty() ? nullptr : E.contOf(args[0]);
        if (!c || NythonExecutor::seqLen(c) < 0 || !NythonExecutor::isTupleCont(c)) fail("TypeError", "state vector must be a tuple");
        std::vector<Value> items = NythonExecutor::seqItems(c);
        if (items.size() != (size_t)N + 1) fail("ValueError", "state vector is the wrong size");
        MT m;
        for (int i = 0; i <= N; i++) {
            const Value& v = items[(size_t)i];
            if (v.type != ValueType::INTEGER) fail("TypeError", "state vector items must be integers");
            nypy::BigInt b = big_of(v);
            if (i == N) {
                int64_t idx;
                if (!b.to_i64(idx) || idx < 0 || idx > N) fail("ValueError", "invalid state");
                m.index = (uint32_t)idx;
            } else {
                if (b.neg) fail("OverflowError", "can't convert negative int to unsigned");
                if (b.mag.size() > 2) fail("OverflowError", "Python int too large to convert to C unsigned long");
                m.mt[i] = b.mag.empty() ? 0 : b.mag[0];
            }
        }
        std::string st;
        store(m, st);
        return E.makeBytesValue(st, true);
    }
    return UNDEFINED_VALUE;
}
