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

} // namespace

std::vector<std::string> hash_builtin_names() {
    return {"_hash_new", "_hash_update", "_hash_digest", "_hash_copy", "_hash_free", "_hash_info",
            "_hash_algorithms", "_hash_hmac", "_hash_pbkdf2", "_hash_crc32", "_hash_adler32",
            "_hash_b64encode", "_hash_b64decode", "_hash_b32encode", "_hash_b32decode", "_hash_compare",
            "os_urandom", "_ws_mask"};
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
