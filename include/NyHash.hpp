#pragma once
// NyHash.hpp - message digests for hashlib/hmac (round 77), written from the
// specifications (RFC 1321 MD5, FIPS 180-4 SHA-1/SHA-2, FIPS 202 SHA-3/SHAKE,
// RFC 7693 BLAKE2b/BLAKE2s) - no library needed, so they are the same on every
// platform and in both engines (src/builtins/hashing.cpp serves them).
//
// Every algorithm is incremental: update() any number of times, final()
// once (on a copy, so a digest can be taken and the object fed further).
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace nyhash {

static inline uint32_t rol32(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }
static inline uint32_t ror32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
static inline uint64_t rol64(uint64_t x, int n) { return n == 0 ? x : (x << n) | (x >> (64 - n)); }
static inline uint64_t ror64(uint64_t x, int n) { return (x >> n) | (x << (64 - n)); }

struct Hash {
    virtual ~Hash() = default;
    virtual void update(const uint8_t* p, size_t n) = 0;
    virtual std::string final() = 0;                 // destroys the state: call on a copy
    virtual std::unique_ptr<Hash> clone() const = 0;
    virtual size_t digest_size() const = 0;
    virtual size_t block_size() const = 0;
    virtual std::string name() const = 0;
    // SHAKE: a digest of any length
    virtual std::string final_len(size_t n) { (void)n; return final(); }
    std::string digest() const { return clone()->final(); }
};

// ── MD5 / SHA-1 / SHA-256 family: 64-byte blocks, 64-bit length ────────────
template <typename Self> struct Block64 : Hash {
    uint8_t buf[64];
    size_t used = 0;
    uint64_t total = 0;
    void update(const uint8_t* p, size_t n) override {
        total += n;
        while (n) {
            size_t k = std::min(n, (size_t)64 - used);
            std::memcpy(buf + used, p, k);
            used += k; p += k; n -= k;
            if (used == 64) { static_cast<Self*>(this)->block(buf); used = 0; }
        }
    }
    void pad(bool big_endian) {
        uint64_t bits = total * 8;
        uint8_t one = 0x80;
        update(&one, 1);
        uint8_t zero = 0;
        while (used != 56) update(&zero, 1);
        uint8_t len[8];
        for (int i = 0; i < 8; i++) len[i] = big_endian ? (uint8_t)(bits >> (56 - 8 * i)) : (uint8_t)(bits >> (8 * i));
        update(len, 8);
    }
    size_t block_size() const override { return 64; }
};

struct MD5 : Block64<MD5> {
    uint32_t h[4] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476};
    void block(const uint8_t* b) {
        static const uint32_t K[64] = {
            0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
            0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
            0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
            0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
            0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
            0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
            0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
            0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
        static const int R[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};
        uint32_t m[16];
        for (int i = 0; i < 16; i++) m[i] = (uint32_t)b[4 * i] | (uint32_t)b[4 * i + 1] << 8 | (uint32_t)b[4 * i + 2] << 16 | (uint32_t)b[4 * i + 3] << 24;
        uint32_t a = h[0], bb = h[1], c = h[2], d = h[3];
        for (int i = 0; i < 64; i++) {
            uint32_t f; int g;
            if (i < 16) { f = (bb & c) | (~bb & d); g = i; }
            else if (i < 32) { f = (d & bb) | (~d & c); g = (5 * i + 1) % 16; }
            else if (i < 48) { f = bb ^ c ^ d; g = (3 * i + 5) % 16; }
            else { f = c ^ (bb | ~d); g = (7 * i) % 16; }
            uint32_t t = d; d = c; c = bb;
            bb = bb + rol32(a + f + K[i] + m[g], R[i]);
            a = t;
        }
        h[0] += a; h[1] += bb; h[2] += c; h[3] += d;
    }
    std::string final() override {
        pad(false);
        std::string out(16, '\0');
        for (int i = 0; i < 16; i++) out[i] = (char)(h[i / 4] >> (8 * (i % 4)));
        return out;
    }
    std::unique_ptr<Hash> clone() const override { return std::make_unique<MD5>(*this); }
    size_t digest_size() const override { return 16; }
    std::string name() const override { return "md5"; }
};

struct SHA1 : Block64<SHA1> {
    uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
    void block(const uint8_t* b) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++) w[i] = (uint32_t)b[4 * i] << 24 | (uint32_t)b[4 * i + 1] << 16 | (uint32_t)b[4 * i + 2] << 8 | b[4 * i + 3];
        for (int i = 16; i < 80; i++) w[i] = rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        uint32_t a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4];
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) { f = (bb & c) | (~bb & d); k = 0x5A827999; }
            else if (i < 40) { f = bb ^ c ^ d; k = 0x6ED9EBA1; }
            else if (i < 60) { f = (bb & c) | (bb & d) | (c & d); k = 0x8F1BBCDC; }
            else { f = bb ^ c ^ d; k = 0xCA62C1D6; }
            uint32_t t = rol32(a, 5) + f + e + k + w[i];
            e = d; d = c; c = rol32(bb, 30); bb = a; a = t;
        }
        h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e;
    }
    std::string final() override {
        pad(true);
        std::string out(20, '\0');
        for (int i = 0; i < 20; i++) out[i] = (char)(h[i / 4] >> (24 - 8 * (i % 4)));
        return out;
    }
    std::unique_ptr<Hash> clone() const override { return std::make_unique<SHA1>(*this); }
    size_t digest_size() const override { return 20; }
    std::string name() const override { return "sha1"; }
};

struct SHA256 : Block64<SHA256> {
    uint32_t h[8];
    bool is224;
    explicit SHA256(bool b224 = false) : is224(b224) {
        static const uint32_t I256[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
        static const uint32_t I224[8] = {0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939, 0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4};
        std::memcpy(h, b224 ? I224 : I256, sizeof h);
    }
    void block(const uint8_t* b) {
        static const uint32_t K[64] = {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; i++) w[i] = (uint32_t)b[4 * i] << 24 | (uint32_t)b[4 * i + 1] << 16 | (uint32_t)b[4 * i + 2] << 8 | b[4 * i + 3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + S1 + ch + K[i] + w[i];
            uint32_t S0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22);
            uint32_t mj = (a & bb) ^ (a & c) ^ (bb & c);
            uint32_t t2 = S0 + mj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
        }
        h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    std::string final() override {
        pad(true);
        size_t n = is224 ? 28 : 32;
        std::string out(n, '\0');
        for (size_t i = 0; i < n; i++) out[i] = (char)(h[i / 4] >> (24 - 8 * (i % 4)));
        return out;
    }
    std::unique_ptr<Hash> clone() const override { return std::make_unique<SHA256>(*this); }
    size_t digest_size() const override { return is224 ? 28 : 32; }
    std::string name() const override { return is224 ? "sha224" : "sha256"; }
};

// ── SHA-512 family: 128-byte blocks ─────────────────────────────────────────
struct SHA512 : Hash {
    uint64_t h[8];
    uint8_t buf[128];
    size_t used = 0;
    uint64_t total = 0;
    size_t out_len;
    std::string nm;
    SHA512(size_t bits = 512) : out_len(bits / 8) {
        static const uint64_t I512[8] = {0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
                                         0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};
        static const uint64_t I384[8] = {0xcbbb9d5dc1059ed8ULL, 0x629a292a367cd507ULL, 0x9159015a3070dd17ULL, 0x152fecd8f70e5939ULL,
                                         0x67332667ffc00b31ULL, 0x8eb44a8768581511ULL, 0xdb0c2e0d64f98fa7ULL, 0x47b5481dbefa4fa4ULL};
        std::memcpy(h, bits == 384 ? I384 : I512, sizeof h);
        nm = bits == 384 ? "sha384" : "sha512";
    }
    void block(const uint8_t* b) {
        static const uint64_t K[80] = {
            0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL, 0x3956c25bf348b538ULL,
            0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL, 0xd807aa98a3030242ULL, 0x12835b0145706fbeULL,
            0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL, 0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL,
            0xc19bf174cf692694ULL, 0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
            0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL, 0x983e5152ee66dfabULL,
            0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL, 0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL,
            0x06ca6351e003826fULL, 0x142929670a0e6e70ULL, 0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL,
            0x53380d139d95b3dfULL, 0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
            0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL, 0xd192e819d6ef5218ULL,
            0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL, 0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL,
            0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL, 0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL,
            0x682e6ff3d6b2b8a3ULL, 0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
            0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL, 0xca273eceea26619cULL,
            0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL, 0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL,
            0x113f9804bef90daeULL, 0x1b710b35131c471bULL, 0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL,
            0x431d67c49c100d4cULL, 0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL};
        uint64_t w[80];
        for (int i = 0; i < 16; i++) {
            uint64_t v = 0;
            for (int j = 0; j < 8; j++) v = (v << 8) | b[8 * i + j];
            w[i] = v;
        }
        for (int i = 16; i < 80; i++) {
            uint64_t s0 = ror64(w[i - 15], 1) ^ ror64(w[i - 15], 8) ^ (w[i - 15] >> 7);
            uint64_t s1 = ror64(w[i - 2], 19) ^ ror64(w[i - 2], 61) ^ (w[i - 2] >> 6);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint64_t a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 80; i++) {
            uint64_t S1 = ror64(e, 14) ^ ror64(e, 18) ^ ror64(e, 41);
            uint64_t ch = (e & f) ^ (~e & g);
            uint64_t t1 = hh + S1 + ch + K[i] + w[i];
            uint64_t S0 = ror64(a, 28) ^ ror64(a, 34) ^ ror64(a, 39);
            uint64_t mj = (a & bb) ^ (a & c) ^ (bb & c);
            uint64_t t2 = S0 + mj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
        }
        h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    void update(const uint8_t* p, size_t n) override {
        total += n;
        while (n) {
            size_t k = std::min(n, (size_t)128 - used);
            std::memcpy(buf + used, p, k);
            used += k; p += k; n -= k;
            if (used == 128) { block(buf); used = 0; }
        }
    }
    std::string final() override {
        uint64_t bits = total * 8;
        uint8_t one = 0x80, zero = 0;
        update(&one, 1);
        while (used != 112) update(&zero, 1);
        uint8_t len[16] = {0};
        for (int i = 0; i < 8; i++) len[8 + i] = (uint8_t)(bits >> (56 - 8 * i));
        update(len, 16);
        std::string out(out_len, '\0');
        for (size_t i = 0; i < out_len; i++) out[i] = (char)(h[i / 8] >> (56 - 8 * (i % 8)));
        return out;
    }
    std::unique_ptr<Hash> clone() const override { return std::make_unique<SHA512>(*this); }
    size_t digest_size() const override { return out_len; }
    size_t block_size() const override { return 128; }
    std::string name() const override { return nm; }
};

// ── SHA-3 / SHAKE (Keccak-f[1600]) ──────────────────────────────────────────
struct SHA3 : Hash {
    uint64_t st[25] = {0};
    size_t rate, pos = 0, out_len;
    uint8_t dsep;          // 0x06 SHA-3, 0x1f SHAKE
    std::string nm;
    SHA3(size_t rate_bytes, size_t out, uint8_t ds, std::string n) : rate(rate_bytes), out_len(out), dsep(ds), nm(std::move(n)) {}
    static void keccakf(uint64_t s[25]) {
        static const uint64_t RC[24] = {
            0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
            0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
            0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
            0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
            0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
            0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};
        static const int rho[24] = {1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44};
        static const int pi[24] = {10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1};
        for (int round = 0; round < 24; round++) {
            uint64_t c[5];
            for (int x = 0; x < 5; x++) c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20];
            for (int x = 0; x < 5; x++) {
                uint64_t d = c[(x + 4) % 5] ^ rol64(c[(x + 1) % 5], 1);
                for (int y = 0; y < 25; y += 5) s[y + x] ^= d;
            }
            uint64_t t = s[1];
            for (int i = 0; i < 24; i++) {
                int j = pi[i];
                uint64_t tmp = s[j];
                s[j] = rol64(t, rho[i]);
                t = tmp;
            }
            for (int y = 0; y < 25; y += 5) {
                uint64_t row[5];
                for (int x = 0; x < 5; x++) row[x] = s[y + x];
                for (int x = 0; x < 5; x++) s[y + x] = row[x] ^ (~row[(x + 1) % 5] & row[(x + 2) % 5]);
            }
            s[0] ^= RC[round];
        }
    }
    void absorb_byte(uint8_t b) {
        st[pos / 8] ^= (uint64_t)b << (8 * (pos % 8));
        if (++pos == rate) { keccakf(st); pos = 0; }
    }
    void update(const uint8_t* p, size_t n) override { for (size_t i = 0; i < n; i++) absorb_byte(p[i]); }
    std::string squeeze(size_t n) {
        st[pos / 8] ^= (uint64_t)dsep << (8 * (pos % 8));
        st[(rate - 1) / 8] ^= (uint64_t)0x80 << (8 * ((rate - 1) % 8));
        keccakf(st);
        std::string out;
        out.reserve(n);
        size_t off = 0;
        while (out.size() < n) {
            out.push_back((char)(st[off / 8] >> (8 * (off % 8))));
            if (++off == rate && out.size() < n) { keccakf(st); off = 0; }
        }
        return out;
    }
    std::string final() override { return squeeze(out_len); }
    std::string final_len(size_t n) override { return squeeze(n); }
    std::unique_ptr<Hash> clone() const override { return std::make_unique<SHA3>(*this); }
    size_t digest_size() const override { return out_len; }
    size_t block_size() const override { return rate; }
    std::string name() const override { return nm; }
};

// ── BLAKE2b / BLAKE2s (RFC 7693), unkeyed or keyed ─────────────────────────
struct BLAKE2b : Hash {
    uint64_t h[8];
    uint8_t buf[128];
    size_t used = 0;
    uint64_t t0 = 0, t1 = 0;
    size_t out_len;
    static constexpr uint64_t IV[8] = {0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
                                       0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};
    BLAKE2b(size_t outlen = 64, const std::string& key = std::string()) : out_len(outlen) {
        for (int i = 0; i < 8; i++) h[i] = IV[i];
        h[0] ^= 0x01010000ULL ^ ((uint64_t)key.size() << 8) ^ outlen;
        if (!key.empty()) {
            uint8_t block[128] = {0};
            std::memcpy(block, key.data(), std::min<size_t>(key.size(), 64));
            update(block, 128);
        }
    }
    void compress(const uint8_t* b, bool last) {
        static const uint8_t S[12][16] = {
            {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
            {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4}, {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
            {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13}, {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
            {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11}, {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
            {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5}, {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0},
            {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3}};
        uint64_t m[16], v[16];
        for (int i = 0; i < 16; i++) { uint64_t x = 0; for (int j = 7; j >= 0; j--) x = (x << 8) | b[8 * i + j]; m[i] = x; }
        for (int i = 0; i < 8; i++) { v[i] = h[i]; v[i + 8] = IV[i]; }
        v[12] ^= t0; v[13] ^= t1;
        if (last) v[14] = ~v[14];
        auto G = [&](int a, int bb, int c, int d, uint64_t x, uint64_t y) {
            v[a] = v[a] + v[bb] + x; v[d] = ror64(v[d] ^ v[a], 32);
            v[c] = v[c] + v[d]; v[bb] = ror64(v[bb] ^ v[c], 24);
            v[a] = v[a] + v[bb] + y; v[d] = ror64(v[d] ^ v[a], 16);
            v[c] = v[c] + v[d]; v[bb] = ror64(v[bb] ^ v[c], 63);
        };
        for (int r = 0; r < 12; r++) {
            const uint8_t* s = S[r];
            G(0, 4, 8, 12, m[s[0]], m[s[1]]); G(1, 5, 9, 13, m[s[2]], m[s[3]]);
            G(2, 6, 10, 14, m[s[4]], m[s[5]]); G(3, 7, 11, 15, m[s[6]], m[s[7]]);
            G(0, 5, 10, 15, m[s[8]], m[s[9]]); G(1, 6, 11, 12, m[s[10]], m[s[11]]);
            G(2, 7, 8, 13, m[s[12]], m[s[13]]); G(3, 4, 9, 14, m[s[14]], m[s[15]]);
        }
        for (int i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
    }
    void update(const uint8_t* p, size_t n) override {
        while (n) {
            if (used == 128) {            // a full block is compressed only when more data follows
                t0 += 128; if (t0 < 128) t1++;
                compress(buf, false);
                used = 0;
            }
            size_t k = std::min(n, (size_t)128 - used);
            std::memcpy(buf + used, p, k);
            used += k; p += k; n -= k;
        }
    }
    std::string final() override {
        t0 += used; if (t0 < used) t1++;
        std::memset(buf + used, 0, 128 - used);
        compress(buf, true);
        std::string out(out_len, '\0');
        for (size_t i = 0; i < out_len; i++) out[i] = (char)(h[i / 8] >> (8 * (i % 8)));
        return out;
    }
    std::unique_ptr<Hash> clone() const override { return std::make_unique<BLAKE2b>(*this); }
    size_t digest_size() const override { return out_len; }
    size_t block_size() const override { return 128; }
    std::string name() const override { return "blake2b"; }
};

struct BLAKE2s : Hash {
    uint32_t h[8];
    uint8_t buf[64];
    size_t used = 0;
    uint32_t t0 = 0, t1 = 0;
    size_t out_len;
    static constexpr uint32_t IV[8] = {0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19};
    BLAKE2s(size_t outlen = 32, const std::string& key = std::string()) : out_len(outlen) {
        for (int i = 0; i < 8; i++) h[i] = IV[i];
        h[0] ^= 0x01010000U ^ ((uint32_t)key.size() << 8) ^ (uint32_t)outlen;
        if (!key.empty()) {
            uint8_t block[64] = {0};
            std::memcpy(block, key.data(), std::min<size_t>(key.size(), 32));
            update(block, 64);
        }
    }
    void compress(const uint8_t* b, bool last) {
        static const uint8_t S[10][16] = {
            {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
            {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4}, {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
            {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13}, {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
            {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11}, {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
            {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5}, {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0}};
        uint32_t m[16], v[16];
        for (int i = 0; i < 16; i++) m[i] = (uint32_t)b[4 * i] | (uint32_t)b[4 * i + 1] << 8 | (uint32_t)b[4 * i + 2] << 16 | (uint32_t)b[4 * i + 3] << 24;
        for (int i = 0; i < 8; i++) { v[i] = h[i]; v[i + 8] = IV[i]; }
        v[12] ^= t0; v[13] ^= t1;
        if (last) v[14] = ~v[14];
        auto G = [&](int a, int bb, int c, int d, uint32_t x, uint32_t y) {
            v[a] = v[a] + v[bb] + x; v[d] = ror32(v[d] ^ v[a], 16);
            v[c] = v[c] + v[d]; v[bb] = ror32(v[bb] ^ v[c], 12);
            v[a] = v[a] + v[bb] + y; v[d] = ror32(v[d] ^ v[a], 8);
            v[c] = v[c] + v[d]; v[bb] = ror32(v[bb] ^ v[c], 7);
        };
        for (int r = 0; r < 10; r++) {
            const uint8_t* s = S[r];
            G(0, 4, 8, 12, m[s[0]], m[s[1]]); G(1, 5, 9, 13, m[s[2]], m[s[3]]);
            G(2, 6, 10, 14, m[s[4]], m[s[5]]); G(3, 7, 11, 15, m[s[6]], m[s[7]]);
            G(0, 5, 10, 15, m[s[8]], m[s[9]]); G(1, 6, 11, 12, m[s[10]], m[s[11]]);
            G(2, 7, 8, 13, m[s[12]], m[s[13]]); G(3, 4, 9, 14, m[s[14]], m[s[15]]);
        }
        for (int i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
    }
    void update(const uint8_t* p, size_t n) override {
        while (n) {
            if (used == 64) {
                t0 += 64; if (t0 < 64) t1++;
                compress(buf, false);
                used = 0;
            }
            size_t k = std::min(n, (size_t)64 - used);
            std::memcpy(buf + used, p, k);
            used += k; p += k; n -= k;
        }
    }
    std::string final() override {
        t0 += (uint32_t)used; if (t0 < used) t1++;
        std::memset(buf + used, 0, 64 - used);
        compress(buf, true);
        std::string out(out_len, '\0');
        for (size_t i = 0; i < out_len; i++) out[i] = (char)(h[i / 4] >> (8 * (i % 4)));
        return out;
    }
    std::unique_ptr<Hash> clone() const override { return std::make_unique<BLAKE2s>(*this); }
    size_t digest_size() const override { return out_len; }
    size_t block_size() const override { return 64; }
    std::string name() const override { return "blake2s"; }
};

// The algorithm named `name` (hashlib's names), nullptr if unknown.
inline std::unique_ptr<Hash> make(std::string name, size_t digest_size = 0, const std::string& key = std::string()) {
    for (auto& c : name) c = (char)std::tolower((unsigned char)c);
    for (auto& c : name) if (c == '-') c = '_';
    if (name == "md5") return std::make_unique<MD5>();
    if (name == "sha1") return std::make_unique<SHA1>();
    if (name == "sha224") return std::make_unique<SHA256>(true);
    if (name == "sha256") return std::make_unique<SHA256>(false);
    if (name == "sha384") return std::make_unique<SHA512>(384);
    if (name == "sha512") return std::make_unique<SHA512>(512);
    if (name == "sha3_224") return std::make_unique<SHA3>(144, 28, 0x06, "sha3_224");
    if (name == "sha3_256") return std::make_unique<SHA3>(136, 32, 0x06, "sha3_256");
    if (name == "sha3_384") return std::make_unique<SHA3>(104, 48, 0x06, "sha3_384");
    if (name == "sha3_512") return std::make_unique<SHA3>(72, 64, 0x06, "sha3_512");
    if (name == "shake_128") return std::make_unique<SHA3>(168, 0, 0x1f, "shake_128");
    if (name == "shake_256") return std::make_unique<SHA3>(136, 0, 0x1f, "shake_256");
    if (name == "blake2b") return std::make_unique<BLAKE2b>(digest_size ? digest_size : 64, key);
    if (name == "blake2s") return std::make_unique<BLAKE2s>(digest_size ? digest_size : 32, key);
    return nullptr;
}

inline std::string hmac(const std::string& algo, const std::string& key, const std::string& msg) {
    auto h = make(algo);
    if (!h) return std::string();
    size_t bs = h->block_size();
    std::string k = key;
    if (k.size() > bs) { auto kh = make(algo); kh->update((const uint8_t*)k.data(), k.size()); k = kh->final(); }
    k.resize(bs, '\0');
    std::string ipad(bs, '\0'), opad(bs, '\0');
    for (size_t i = 0; i < bs; i++) { ipad[i] = (char)(k[i] ^ 0x36); opad[i] = (char)(k[i] ^ 0x5c); }
    auto inner = make(algo);
    inner->update((const uint8_t*)ipad.data(), bs);
    inner->update((const uint8_t*)msg.data(), msg.size());
    std::string ih = inner->final();
    auto outer = make(algo);
    outer->update((const uint8_t*)opad.data(), bs);
    outer->update((const uint8_t*)ih.data(), ih.size());
    return outer->final();
}

inline std::string pbkdf2_hmac(const std::string& algo, const std::string& pass, const std::string& salt,
                               uint64_t iterations, size_t dklen) {
    auto probe = make(algo);
    if (!probe) return std::string();
    size_t hlen = probe->digest_size();
    if (dklen == 0) dklen = hlen;
    std::string out;
    for (uint32_t block = 1; out.size() < dklen; block++) {
        std::string s = salt;
        s.push_back((char)(block >> 24)); s.push_back((char)(block >> 16)); s.push_back((char)(block >> 8)); s.push_back((char)block);
        std::string u = hmac(algo, pass, s), t = u;
        for (uint64_t i = 1; i < iterations; i++) {
            u = hmac(algo, pass, u);
            for (size_t j = 0; j < t.size(); j++) t[j] ^= u[j];
        }
        out += t;
    }
    out.resize(dklen);
    return out;
}

inline uint32_t crc32(const std::string& data, uint32_t crc = 0) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320U ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = true;
    }
    crc = ~crc;
    for (unsigned char ch : data) crc = table[(crc ^ ch) & 0xff] ^ (crc >> 8);
    return ~crc;
}

inline uint32_t adler32(const std::string& data, uint32_t value = 1) {
    uint32_t a = value & 0xffff, b = (value >> 16) & 0xffff;
    for (unsigned char ch : data) { a = (a + ch) % 65521; b = (b + a) % 65521; }
    return (b << 16) | a;
}

// ── base64 / base32 / base16 (RFC 4648) ─────────────────────────────────────
inline std::string b64encode(const std::string& in, const char* alphabet = nullptr, bool pad = true) {
    static const char* std_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const char* A = alphabet ? alphabet : std_alpha;
    std::string out;
    out.reserve((in.size() + 2) / 3 * 4);
    size_t i = 0;
    for (; i + 2 < in.size(); i += 3) {
        uint32_t v = (uint8_t)in[i] << 16 | (uint8_t)in[i + 1] << 8 | (uint8_t)in[i + 2];
        out += A[v >> 18]; out += A[(v >> 12) & 63]; out += A[(v >> 6) & 63]; out += A[v & 63];
    }
    if (i + 1 == in.size()) {
        uint32_t v = (uint8_t)in[i] << 16;
        out += A[v >> 18]; out += A[(v >> 12) & 63];
        if (pad) out += "==";
    } else if (i + 2 == in.size()) {
        uint32_t v = (uint8_t)in[i] << 16 | (uint8_t)in[i + 1] << 8;
        out += A[v >> 18]; out += A[(v >> 12) & 63]; out += A[(v >> 6) & 63];
        if (pad) out += '=';
    }
    return out;
}
// false on malformed input (validate: non-alphabet characters are errors,
// otherwise they are skipped, as Python's b64decode does).
inline bool b64decode(const std::string& in, std::string& out, const char* alphabet = nullptr, bool validate = false) {
    static const char* std_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const char* A = alphabet ? alphabet : std_alpha;
    int rev[256];
    for (int i = 0; i < 256; i++) rev[i] = -1;
    for (int i = 0; i < 64; i++) rev[(unsigned char)A[i]] = i;
    out.clear();
    uint32_t acc = 0;
    int bits = 0, pads = 0, quads = 0;
    for (unsigned char c : in) {
        if (c == '=') { pads++; continue; }
        if (rev[c] < 0) { if (validate) return false; continue; }
        if (pads) return false;                  // data after padding
        acc = (acc << 6) | (uint32_t)rev[c];
        bits += 6;
        quads++;
        if (bits >= 8) { bits -= 8; out.push_back((char)((acc >> bits) & 0xff)); }
    }
    if (quads % 4 == 1) return false;            // impossible length
    // Python's rule: the padding must complete the last group
    if (quads % 4 == 2 && pads < 2) return false;
    if (quads % 4 == 3 && pads < 1) return false;
    return true;
}
inline std::string b32encode(const std::string& in) {
    static const char* A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    std::string out;
    uint64_t acc = 0;
    int bits = 0;
    for (unsigned char c : in) {
        acc = (acc << 8) | c; bits += 8;
        while (bits >= 5) { bits -= 5; out += A[(acc >> bits) & 31]; }
    }
    if (bits) out += A[(acc << (5 - bits)) & 31];
    while (out.size() % 8) out += '=';
    return out;
}
inline bool b32decode(const std::string& in, std::string& out) {
    out.clear();
    uint64_t acc = 0;
    int bits = 0;
    for (unsigned char c : in) {
        if (c == '=') break;
        int v;
        if (c >= 'A' && c <= 'Z') v = c - 'A';
        else if (c >= 'a' && c <= 'z') v = c - 'a';
        else if (c >= '2' && c <= '7') v = c - '2' + 26;
        else return false;
        acc = (acc << 5) | (uint64_t)v; bits += 5;
        if (bits >= 8) { bits -= 8; out.push_back((char)((acc >> bits) & 0xff)); }
    }
    return true;
}

} // namespace nyhash
