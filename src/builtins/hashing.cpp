// builtins/hashing.cpp - message digests, HMAC, PBKDF2, checksums, base
// encodings and the OS random source (round 77), for lib/hashlib.ny,
// lib/hmac.ny, lib/base64.ny, lib/binascii.ny and lib/secrets.ny. The
// algorithms are NyHash.hpp's; the VM reaches these through the builtin bridge.
//
//   _hash_new(name, data=b"", digest_size=0, key=b"") -> h    (none: unknown)
//   _hash_update(h, data)   _hash_digest(h[, length]) -> bytes   _hash_copy(h) -> h
//   _hash_free(h)           _hash_info(h) -> [name, digest_size, block_size]
//   _hash_algorithms() -> [names]
//   _hash_hmac(name, key, msg) -> bytes
//   _hash_pbkdf2(name, password, salt, iterations, dklen) -> bytes
//   _hash_crc32(data, value=0)   _hash_adler32(data, value=1)
//   _hash_b64encode(data, altchars=none, pad=true) -> bytes
//   _hash_b64decode(data, altchars=none, validate=false) -> bytes (binascii.Error)
//   _hash_b32encode(data) / _hash_b32decode(data)
//   _hash_compare(a, b) -> bool          constant time (hmac.compare_digest)
//   os_urandom(n) -> bytes               the OS's cryptographic random source
//   _ws_mask(data, key) -> bytes         RFC 6455 5.3 masking: data XOR the
//                                        4-byte key repeated (lib/websocket.ny)
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyHash.hpp"
#include "builtins/os.hpp"
#include <cstring>
#include <mutex>
#include <unordered_map>
#ifdef _WIN32
#  include <windows.h>
#else
#  include <fcntl.h>
#  include <unistd.h>
#endif

Value dispatch_hash(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> hash_builtin_names();
// DEFLATE / zlib / gzip (round 79, builtins/nyzlib.cpp): registered and
// dispatched through this module's entry points
Value dispatch_zlib(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> zlib_builtin_names();
// lib/codecs.ny's native (round 80, builtins/nycodecs.cpp): registered and
// dispatched through here, as zlib's.
Value dispatch_codec(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> codec_builtin_names();
// lib/pickle.ny's fast path for plain data (round 80, builtins/nypickle.cpp)
Value dispatch_pickle(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> pickle_builtin_names();
// lib/unicodedata.ny's native (round 84, builtins/nyunicode.cpp) and the
// CJK codecs' (builtins/nycjk.cpp)
Value dispatch_ucd(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> ucd_builtin_names();

namespace {

std::mutex& mu() { static std::mutex* m = new std::mutex(); return *m; }
std::unordered_map<int64_t, std::unique_ptr<nyhash::Hash>>& table() {
    static auto* t = new std::unordered_map<int64_t, std::unique_ptr<nyhash::Hash>>();
    return *t;
}
int64_t g_next = 1;

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }

std::string bytes_of(NythonExecutor& E, const Value& v, const char* what) {
    if (auto* bo = E.bytesOf(v)) return bo->s;
    if (E.isStringValue(v)) fail("TypeError", std::string("Strings must be encoded before ") + what);
    if (v.type == ValueType::NONE) return std::string();
    fail("TypeError", "a bytes-like object is required, not '" + E.typeNameOf(v) + "'");
}

nyhash::Hash* get(int64_t h) {
    auto it = table().find(h);
    if (it == table().end()) fail("ValueError", "invalid hash object");
    return it->second.get();
}

bool os_random(std::string& out, size_t n) {
    out.assign(n, '\0');
#ifdef _WIN32
    // RtlGenRandom (advapi32's SystemFunction036), Windows XP and later.
    typedef BOOLEAN (WINAPI* Fn)(PVOID, ULONG);
    static Fn fn = [] {
        HMODULE h = LoadLibraryA("advapi32.dll");
        return h ? (Fn)GetProcAddress(h, "SystemFunction036") : (Fn)nullptr;
    }();
    if (!fn) return false;
    size_t off = 0;
    while (off < n) {
        ULONG k = (ULONG)std::min<size_t>(n - off, 1u << 20);
        if (!fn(&out[off], k)) return false;
        off += k;
    }
    return true;
#else
    int fd = ::open("/dev/urandom", O_RDONLY);
    if (fd < 0) return false;
    size_t off = 0;
    while (off < n) {
        ssize_t r = ::read(fd, &out[off], n - off);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; ::close(fd); return false; }
        off += (size_t)r;
    }
    ::close(fd);
    return true;
#endif
}

// ── scrypt (RFC 7914; round 85): PBKDF2-HMAC-SHA256 around ROMix over
// BlockMix of Salsa20/8, as the RFC's reference code and OpenSSL's
// EVP_PBE_scrypt compute it (hashlib.scrypt) ─────────────────────────────
inline uint32_t rotl32(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }
void salsa20_8(uint32_t B[16]) {
    uint32_t x[16];
    std::memcpy(x, B, sizeof x);
    for (int i = 0; i < 8; i += 2) {
        x[4] ^= rotl32(x[0] + x[12], 7);  x[8] ^= rotl32(x[4] + x[0], 9);
        x[12] ^= rotl32(x[8] + x[4], 13); x[0] ^= rotl32(x[12] + x[8], 18);
        x[9] ^= rotl32(x[5] + x[1], 7);   x[13] ^= rotl32(x[9] + x[5], 9);
        x[1] ^= rotl32(x[13] + x[9], 13); x[5] ^= rotl32(x[1] + x[13], 18);
        x[14] ^= rotl32(x[10] + x[6], 7); x[2] ^= rotl32(x[14] + x[10], 9);
        x[6] ^= rotl32(x[2] + x[14], 13); x[10] ^= rotl32(x[6] + x[2], 18);
        x[3] ^= rotl32(x[15] + x[11], 7); x[7] ^= rotl32(x[3] + x[15], 9);
        x[11] ^= rotl32(x[7] + x[3], 13); x[15] ^= rotl32(x[11] + x[7], 18);
        x[1] ^= rotl32(x[0] + x[3], 7);   x[2] ^= rotl32(x[1] + x[0], 9);
        x[3] ^= rotl32(x[2] + x[1], 13);  x[0] ^= rotl32(x[3] + x[2], 18);
        x[6] ^= rotl32(x[5] + x[4], 7);   x[7] ^= rotl32(x[6] + x[5], 9);
        x[4] ^= rotl32(x[7] + x[6], 13);  x[5] ^= rotl32(x[4] + x[7], 18);
        x[11] ^= rotl32(x[10] + x[9], 7); x[8] ^= rotl32(x[11] + x[10], 9);
        x[9] ^= rotl32(x[8] + x[11], 13); x[10] ^= rotl32(x[9] + x[8], 18);
        x[12] ^= rotl32(x[15] + x[14], 7); x[13] ^= rotl32(x[12] + x[15], 9);
        x[14] ^= rotl32(x[13] + x[12], 13); x[15] ^= rotl32(x[14] + x[13], 18);
    }
    for (int i = 0; i < 16; i++) B[i] += x[i];
}
// BlockMix: B is 2r 64-byte blocks (as 32-bit words); Y the scratch
void blockmix(uint32_t* B, uint32_t* Y, size_t r) {
    uint32_t X[16];
    std::memcpy(X, &B[(2 * r - 1) * 16], 64);
    for (size_t i = 0; i < 2 * r; i++) {
        for (int k = 0; k < 16; k++) X[k] ^= B[i * 16 + k];
        salsa20_8(X);
        std::memcpy(&Y[i * 16], X, 64);
    }
    for (size_t i = 0; i < r; i++) std::memcpy(&B[i * 16], &Y[(2 * i) * 16], 64);
    for (size_t i = 0; i < r; i++) std::memcpy(&B[(i + r) * 16], &Y[(2 * i + 1) * 16], 64);
}
std::string scrypt(const std::string& pass, const std::string& salt, uint64_t N, uint32_t r, uint32_t p, size_t dklen) {
    const size_t words = 32 * (size_t)r;   // 128 r bytes
    std::string B = nyhash::pbkdf2_hmac("sha256", pass, salt, 1, (size_t)p * 128 * r);
    std::vector<uint32_t> X(words), Y(words), V(words * (size_t)N);
    for (uint32_t i = 0; i < p; i++) {
        unsigned char* blk = (unsigned char*)&B[(size_t)i * 128 * r];
        for (size_t k = 0; k < words; k++)
            X[k] = (uint32_t)blk[4 * k] | ((uint32_t)blk[4 * k + 1] << 8) | ((uint32_t)blk[4 * k + 2] << 16) | ((uint32_t)blk[4 * k + 3] << 24);
        for (uint64_t j = 0; j < N; j++) {
            std::memcpy(&V[(size_t)j * words], X.data(), words * 4);
            blockmix(X.data(), Y.data(), r);
        }
        for (uint64_t j = 0; j < N; j++) {
            uint64_t idx = X[(2 * r - 1) * 16] & (N - 1);
            const uint32_t* v = &V[(size_t)idx * words];
            for (size_t k = 0; k < words; k++) X[k] ^= v[k];
            blockmix(X.data(), Y.data(), r);
        }
        for (size_t k = 0; k < words; k++) {
            blk[4 * k] = (unsigned char)X[k]; blk[4 * k + 1] = (unsigned char)(X[k] >> 8);
            blk[4 * k + 2] = (unsigned char)(X[k] >> 16); blk[4 * k + 3] = (unsigned char)(X[k] >> 24);
        }
    }
    return nyhash::pbkdf2_hmac("sha256", pass, B, 1, dklen);
}

} // namespace

std::vector<std::string> hash_builtin_names() {
    std::vector<std::string> v{"_hash_new", "_hash_update", "_hash_digest", "_hash_copy", "_hash_free", "_hash_info",
            "_hash_algorithms", "_hash_hmac", "_hash_pbkdf2", "_hash_crc32", "_hash_adler32",
            "_hash_b64encode", "_hash_b64decode", "_hash_b32encode", "_hash_b32decode", "_hash_compare",
            "os_urandom", "_ws_mask", "_hash_scrypt"};
    for (auto& n : zlib_builtin_names()) v.push_back(n);   // round 79
    for (auto& n : codec_builtin_names()) v.push_back(n);  // round 80
    for (auto& n : pickle_builtin_names()) v.push_back(n); // round 80
    for (auto& n : ucd_builtin_names()) v.push_back(n);    // round 84
    return v;
}

Value dispatch_hash(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name == "os_urandom") {
        nyos::Args A(E, args, {"n", "size"});
        int64_t n = A.integer(0, "size", 0);
        if (n < 0) fail("ValueError", "negative argument not allowed");
        std::string out;
        if (!os_random(out, (size_t)n)) fail("OSError", "the operating system's random source is not available");
        return E.makeBytesValue(out);
    }
    if (name == "_ws_mask") {
        if (args.size() < 2) fail("TypeError", "_ws_mask(data, key) takes 2 arguments");
        std::string data = bytes_of(E, args[0], "masking");
        std::string key = bytes_of(E, args[1], "masking");
        if (key.size() != 4) fail("ValueError", "a WebSocket masking key is 4 bytes");
        // Eight bytes at a time: the key repeated to 64 bits.
        uint64_t k8 = 0;
        for (int i = 0; i < 8; i++) ((unsigned char*)&k8)[i] = (unsigned char)key[i & 3];
        size_t n = data.size(), i = 0;
        char* p = &data[0];
        for (; i + 8 <= n; i += 8) { uint64_t w; std::memcpy(&w, p + i, 8); w ^= k8; std::memcpy(p + i, &w, 8); }
        for (; i < n; i++) p[i] = (char)(p[i] ^ key[i & 3]);
        return E.makeBytesValue(data);
    }
    if (name.compare(0, 6, "_zlib_") == 0) return dispatch_zlib(E, name, args, ctx);   // round 79
    if (name == "_ny_codec") return dispatch_codec(E, name, args, ctx);   // round 80
    if (name == "_ny_pickle_dumps" || name == "_ny_pickle_loads") return dispatch_pickle(E, name, args, ctx);   // round 80
    if (name == "_ny_ucd" || name == "_ny_mbc") return dispatch_ucd(E, name, args, ctx);   // round 84
    if (name.compare(0, 6, "_hash_") != 0) return UNDEFINED_VALUE;
    nyos::Args A(E, args, {"h", "name", "data", "digest_size", "key", "length", "msg", "password", "salt",
                           "iterations", "dklen", "value", "altchars", "pad", "validate", "a", "b"});
    if (name == "_hash_new") {
        std::string algo = A.str(0, "name");
        size_t dsz = (size_t)A.integer(2, "digest_size", 0);
        std::string key = A.has(3, "key") ? bytes_of(E, A.get(3, "key"), "hashing") : std::string();
        if (algo.compare(0, 5, "blake") == 0) {
            size_t maxd = algo == "blake2s" ? 32 : 64;
            if (dsz > maxd) fail("ValueError", "digest_size must be between 1 and " + std::to_string(maxd) + " bytes");
            if (key.size() > maxd) fail("ValueError", "maximum key length is " + std::to_string(maxd) + " bytes");
        }
        auto h = nyhash::make(algo, dsz, key);
        if (!h) return NONE_VALUE;
        if (A.has(1, "data")) {
            std::string d = bytes_of(E, A.get(1, "data"), "hashing");
            h->update((const uint8_t*)d.data(), d.size());
        }
        std::lock_guard<std::mutex> l(mu());
        int64_t id = g_next++;
        table()[id] = std::move(h);
        return Value(id);
    }
    if (name == "_hash_update") {
        std::string d = bytes_of(E, A.get(1, "data"), "hashing");
        std::lock_guard<std::mutex> l(mu());
        get(A.integer(0, "h", 0))->update((const uint8_t*)d.data(), d.size());
        return NONE_VALUE;
    }
    if (name == "_hash_digest") {
        std::lock_guard<std::mutex> l(mu());
        nyhash::Hash* h = get(A.integer(0, "h", 0));
        auto c = h->clone();
        if (A.has(1, "length")) return E.makeBytesValue(c->final_len((size_t)A.integer(1, "length", 0)));
        return E.makeBytesValue(c->final());
    }
    if (name == "_hash_copy") {
        std::lock_guard<std::mutex> l(mu());
        auto c = get(A.integer(0, "h", 0))->clone();
        int64_t id = g_next++;
        table()[id] = std::move(c);
        return Value(id);
    }
    if (name == "_hash_free") {
        std::lock_guard<std::mutex> l(mu());
        table().erase(A.integer(0, "h", 0));
        return NONE_VALUE;
    }
    if (name == "_hash_info") {
        std::lock_guard<std::mutex> l(mu());
        nyhash::Hash* h = get(A.integer(0, "h", 0));
        std::vector<Value> v{E.makeStringValue(h->name()), Value((int64_t)h->digest_size()), Value((int64_t)h->block_size())};
        return E.makeListValue(v);
    }
    if (name == "_hash_algorithms") {
        std::vector<Value> v;
        for (const char* n : {"blake2b", "blake2s", "md5", "sha1", "sha224", "sha256", "sha384", "sha3_224",
                              "sha3_256", "sha3_384", "sha3_512", "sha512", "shake_128", "shake_256"})
            v.push_back(E.makeStringValue(n));
        return E.makeListValue(v);
    }
    if (name == "_hash_hmac") {
        std::string algo = A.str(0, "name");
        if (!nyhash::make(algo)) fail("ValueError", "unsupported hash type " + algo);
        return E.makeBytesValue(nyhash::hmac(algo, bytes_of(E, A.get(1, "key"), "hashing"), bytes_of(E, A.get(2, "msg"), "hashing")));
    }
    if (name == "_hash_pbkdf2") {
        std::string algo = A.str(0, "name");
        if (!nyhash::make(algo)) fail("ValueError", "unsupported hash type " + algo);
        int64_t it = A.integer(3, "iterations", 1);
        if (it < 1) fail("ValueError", "iteration value must be greater than 0.");
        int64_t dk = A.has(4, "dklen") && A.get(4, "dklen").type != ValueType::NONE ? A.integer(4, "dklen", 0) : 0;
        if (A.has(4, "dklen") && A.get(4, "dklen").type != ValueType::NONE && dk < 1) fail("ValueError", "key length must be greater than 0.");
        return E.makeBytesValue(nyhash::pbkdf2_hmac(algo, bytes_of(E, A.get(1, "password"), "hashing"),
                                                    bytes_of(E, A.get(2, "salt"), "hashing"), (uint64_t)it, (size_t)dk));
    }
    if (name == "_hash_scrypt") {
        // (round 85) hashlib.scrypt(password, salt, n, r, p, maxmem, dklen):
        // lib/hashlib.ny checked the types; the limits are OpenSSL's
        // (EVP_PBE_scrypt) with CPython's messages
        if (args.size() < 7) fail("TypeError", "_hash_scrypt takes 7 arguments");
        std::string pass = bytes_of(E, args[0], "hashing"), salt = bytes_of(E, args[1], "hashing");
        int64_t n = nyos::to_int(args[2], 0), r = nyos::to_int(args[3], 0), p = nyos::to_int(args[4], 0);
        int64_t maxmem = nyos::to_int(args[5], 0), dklen = nyos::to_int(args[6], 64);
        if (n < 2 || (n & (n - 1)) != 0) fail("ValueError", "n must be a power of 2.");
        if (maxmem < 0 || maxmem > INT32_MAX) fail("ValueError", "maxmem must be positive and smaller than " + std::to_string(INT32_MAX));
        if (dklen < 1 || dklen > INT32_MAX) fail("ValueError", "dklen must be greater than 0 and smaller than " + std::to_string(INT32_MAX));
        // OpenSSL's checks: r * p < 2^30, n < 2^(128 r / 8), memory within maxmem (32 MiB when 0)
        uint64_t mem_limit = maxmem ? (uint64_t)maxmem : (uint64_t)32 * 1024 * 1024;
        bool bad = r < 1 || p < 1 || (uint64_t)r * (uint64_t)p >= ((uint64_t)1 << 30);
        if (!bad && 16 * r <= 63 && (uint64_t)n >= ((uint64_t)1 << (16 * r))) bad = true;
        if (bad) fail("ValueError", "Invalid parameter combination for n, r, p, maxmem.");
        long double need = 128.0L * (long double)r * ((long double)n + (long double)p + 2.0L);
        if (need > (long double)mem_limit) fail("ValueError", "[digital envelope routines] memory limit exceeded");
        std::string out;
        {
            nyconc::GilRelease un;   // seconds of work at real parameters
            out = scrypt(pass, salt, (uint64_t)n, (uint32_t)r, (uint32_t)p, (size_t)dklen);
        }
        return E.makeBytesValue(out);
    }
    if (name == "_hash_crc32")
        return Value((int64_t)nyhash::crc32(bytes_of(E, A.get(0, "data"), "hashing"), (uint32_t)A.integer(1, "value", 0)));
    if (name == "_hash_adler32")
        return Value((int64_t)nyhash::adler32(bytes_of(E, A.get(0, "data"), "hashing"), (uint32_t)A.integer(1, "value", 1)));
    if (name == "_hash_b64encode" || name == "_hash_b64decode") {
        Value dv = A.get(0, "data");
        std::string data = E.isStringValue(dv) ? E.getStringValue(dv) : bytes_of(E, dv, "encoding");
        std::string alpha;
        if (A.has(1, "altchars") && A.get(1, "altchars").type != ValueType::NONE) {
            std::string alt = bytes_of(E, A.get(1, "altchars"), "encoding");
            if (alt.size() != 2) fail("ValueError", "altchars must be a bytes-like object of length 2");
            alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" + alt;
        }
        if (name == "_hash_b64encode")
            return E.makeBytesValue(nyhash::b64encode(data, alpha.empty() ? nullptr : alpha.c_str(), A.flag(2, "pad", true)));
        std::string out;
        if (!nyhash::b64decode(data, out, alpha.empty() ? nullptr : alpha.c_str(), A.flag(2, "validate", false)))
            fail("ValueError", "Incorrect padding or invalid base64-encoded string");
        return E.makeBytesValue(out);
    }
    if (name == "_hash_b32encode") return E.makeBytesValue(nyhash::b32encode(bytes_of(E, A.get(0, "data"), "encoding")));
    if (name == "_hash_b32decode") {
        Value dv = A.get(0, "data");
        std::string data = E.isStringValue(dv) ? E.getStringValue(dv) : bytes_of(E, dv, "encoding");
        std::string out;
        if (!nyhash::b32decode(data, out)) fail("ValueError", "Non-base32 digit found");
        return E.makeBytesValue(out);
    }
    if (name == "_hash_compare") {
        Value av = A.get(0, "a"), bv = A.get(1, "b");
        std::string a = E.isStringValue(av) ? E.getStringValue(av) : bytes_of(E, av, "comparing");
        std::string b = E.isStringValue(bv) ? E.getStringValue(bv) : bytes_of(E, bv, "comparing");
        unsigned diff = (unsigned)(a.size() ^ b.size());
        for (size_t i = 0; i < a.size(); i++) diff |= (unsigned)(unsigned char)a[i] ^ (unsigned char)(i < b.size() ? b[i] : 0);
        return Value(diff == 0);
    }
    return UNDEFINED_VALUE;
}
