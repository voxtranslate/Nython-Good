// builtins/nycrypt.cpp - the native halves of crypt, spwd and nis (round 87),
// served to both engines by the concurrency runtime's dispatcher
// (nyconc::register_extension).
//
// crypt(3): libcrypt (libxcrypt or glibc's) is loaded when a program first
// hashes - dlopen, nothing at build or link time, as tls.cpp loads OpenSSL;
// NY_LIBCRYPT names the library, NY_NO_LIBCRYPT=1 refuses it. Without it
// (Windows, a C library without crypt, or refused) Nython's own SHA-512-crypt
// and SHA-256-crypt (Ulrich Drepper's specification, "Unix crypt using
// SHA-256 and SHA-512", 2007, with its rounds= parameter) and MD5-crypt
// (Poul-Henning Kamp's FreeBSD algorithm) give the hashes libcrypt gives,
// byte for byte; any other setting gives libxcrypt's failure token ("*0", or
// "*1" for a setting starting with "*0").
//
//   _crypt_crypt(word, salt) -> str | int    the hash, or errno when the
//                                            library returned NULL
//   _crypt_native(word, salt) -> str         Nython's own algorithms only
//   _crypt_backend() -> "libcrypt" | "native"
//
// spwd: the shadow password database through the C library (getspnam,
// setspent/getspent/endspent) where <shadow.h> exists.
//
//   _spwd_supported() -> bool
//   _spwd_getspnam(name) -> [9 fields] | int  errno (0: no such name)
//   _spwd_getspall() -> [[9 fields], ...] | int
//
// nis: NIS/YP through libnsl loaded at run time (yp_get_default_domain,
// yp_match, yp_first/yp_next, yp_maplist, yperr_string).
//
//   _nis_call("why") -> ""  (usable) or why not
//   _nis_call("domain") -> [err, domain]
//   _nis_call("match", key, map, domain) -> [err, value]   (bytes)
//   _nis_call("cat", map, domain) -> [err, [[key, value], ...]]
//   _nis_call("maps", domain) -> [err, [map, ...]]
//   _nis_call("errstr", err) -> str
#include "NyConc.hpp"
#include "NyHash.hpp"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#if defined(__has_include)
#if __has_include(<shadow.h>) && !defined(_WIN32)
#include <shadow.h>
#define NY_HAVE_SHADOW 1
#endif
#endif

using namespace nyconc;

namespace {

// ── loading a library at run time ───────────────────────────────────────────
void* lib_open(const std::vector<std::string>& names) {
    for (auto& n : names) {
#ifdef _WIN32
        HMODULE h = LoadLibraryA(n.c_str());
        if (h) return (void*)h;
#else
        void* h = dlopen(n.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (h) return h;
#endif
    }
    return nullptr;
}
void* lib_sym(void* lib, const char* name) {
#ifdef _WIN32
    return (void*)GetProcAddress((HMODULE)lib, name);
#else
    return dlsym(lib, name);
#endif
}

// ── crypt: the library ──────────────────────────────────────────────────────
struct CryptApi {
    bool tried = false;
    void* lib = nullptr;
    char* (*crypt_r)(const char*, const char*, void*) = nullptr;
    char* (*crypt)(const char*, const char*) = nullptr;
};
CryptApi& crypt_api() {
    static CryptApi a;
    static std::mutex m;
    std::lock_guard<std::mutex> l(m);
    if (a.tried) return a;
    a.tried = true;
    if (const char* no = std::getenv("NY_NO_LIBCRYPT")) if (*no && std::strcmp(no, "0") != 0) return a;
    std::vector<std::string> names;
    if (const char* env = std::getenv("NY_LIBCRYPT")) if (*env) names.push_back(env);
#if defined(_WIN32)
    (void)names;
    return a;
#elif defined(__APPLE__)
    names.push_back("/usr/lib/libSystem.B.dylib");
#else
    for (const char* n : {"libcrypt.so.1", "libcrypt.so.2", "libcrypt.so"}) names.push_back(n);
#endif
    a.lib = lib_open(names);
    if (!a.lib) return a;
    a.crypt_r = reinterpret_cast<char* (*)(const char*, const char*, void*)>(lib_sym(a.lib, "crypt_r"));
    a.crypt = reinterpret_cast<char* (*)(const char*, const char*)>(lib_sym(a.lib, "crypt"));
    if (!a.crypt_r && !a.crypt) a.lib = nullptr;
    return a;
}

// ── crypt: Nython's own SHA-crypt and MD5-crypt ─────────────────────────────
const char kB64[] = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

void b64_24(std::string& out, unsigned b2, unsigned b1, unsigned b0, int n) {
    unsigned w = (b2 << 16) | (b1 << 8) | b0;
    while (n-- > 0) { out += kB64[w & 0x3f]; w >>= 6; }
}

std::string hdigest(const char* algo, const std::string& data) {
    auto h = nyhash::make(algo);
    h->update((const uint8_t*)data.data(), data.size());
    return h->final();
}

struct Hasher {
    std::unique_ptr<nyhash::Hash> h;
    explicit Hasher(const char* algo) : h(nyhash::make(algo)) {}
    void add(const std::string& s) { h->update((const uint8_t*)s.data(), s.size()); }
    void add(const char* p, size_t n) { h->update((const uint8_t*)p, n); }
    std::string done() { return h->final(); }
};

// Drepper's SHA-crypt: "$5$" (SHA-256) or "$6$" (SHA-512)
std::string sha_crypt(const std::string& key, const std::string& setting, bool is512) {
    const char* algo = is512 ? "sha512" : "sha256";
    const size_t hl = is512 ? 64 : 32;
    std::string prefix = is512 ? "$6$" : "$5$";
    size_t p = 3;
    unsigned long rounds = 5000;
    bool custom = false;
    static const char kRounds[] = "rounds=";
    if (setting.compare(p, 7, kRounds) == 0) {
        size_t q = p + 7;
        size_t e = q;
        while (e < setting.size() && setting[e] >= '0' && setting[e] <= '9') e++;
        if (e == q || e >= setting.size() || setting[e] != '$') return std::string();
        std::string digits = setting.substr(q, e - q);
        if (digits.size() > 1 && digits[0] == '0') return std::string();   // libxcrypt: no leading zeros
        if (digits.size() > 10) return std::string();
        unsigned long long r = std::strtoull(digits.c_str(), nullptr, 10);
        // libxcrypt refuses a count out of range (glibc's crypt clamped it)
        if (r < 1000 || r > 999999999ULL) return std::string();
        rounds = (unsigned long)r;
        custom = true;
        p = e + 1;
    }
    size_t se = p;
    while (se < setting.size() && se - p < 16 && setting[se] != '$' && setting[se] != ':' && setting[se] != '\n') se++;
    std::string salt = setting.substr(p, se - p);
    const size_t kl = key.size(), sl = salt.size();

    // B = H(key salt key)
    Hasher hb(algo);
    hb.add(key); hb.add(salt); hb.add(key);
    std::string B = hb.done();
    // A = H(key salt B... bits of len(key))
    Hasher ha(algo);
    ha.add(key); ha.add(salt);
    size_t cnt = kl;
    for (; cnt > hl; cnt -= hl) ha.add(B);
    ha.add(B.data(), cnt);
    for (cnt = kl; cnt > 0; cnt >>= 1) {
        if (cnt & 1) ha.add(B); else ha.add(key);
    }
    std::string A = ha.done();
    // P = H(key x len(key)), stretched to len(key)
    Hasher hp(algo);
    for (size_t i = 0; i < kl; i++) hp.add(key);
    std::string DP = hp.done();
    std::string P;
    P.reserve(kl);
    for (cnt = kl; cnt >= hl; cnt -= hl) P += DP;
    P.append(DP, 0, cnt);
    // S = H(salt x (16 + A[0])), stretched to len(salt)
    Hasher hs(algo);
    for (size_t i = 0; i < 16u + (unsigned char)A[0]; i++) hs.add(salt);
    std::string DS = hs.done();
    std::string S;
    for (cnt = sl; cnt >= hl; cnt -= hl) S += DS;
    S.append(DS, 0, cnt);
    // the rounds
    std::string C = A;
    for (unsigned long r = 0; r < rounds; r++) {
        Hasher hc(algo);
        if (r & 1) hc.add(P); else hc.add(C);
        if (r % 3) hc.add(S);
        if (r % 7) hc.add(P);
        if (r & 1) hc.add(C); else hc.add(P);
        C = hc.done();
    }
    const unsigned char* c = (const unsigned char*)C.data();
    std::string out = prefix;
    if (custom) out += "rounds=" + std::to_string(rounds) + "$";
    out += salt;
    out += '$';
    if (is512) {
        static const int T[21][3] = {
            {0, 21, 42}, {22, 43, 1}, {44, 2, 23}, {3, 24, 45}, {25, 46, 4}, {47, 5, 26}, {6, 27, 48},
            {28, 49, 7}, {50, 8, 29}, {9, 30, 51}, {31, 52, 10}, {53, 11, 32}, {12, 33, 54}, {34, 55, 13},
            {56, 14, 35}, {15, 36, 57}, {37, 58, 16}, {59, 17, 38}, {18, 39, 60}, {40, 61, 19}, {62, 20, 41}};
        for (auto& t : T) b64_24(out, c[t[0]], c[t[1]], c[t[2]], 4);
        b64_24(out, 0, 0, c[63], 2);
    } else {
        static const int T[10][3] = {
            {0, 10, 20}, {21, 1, 11}, {12, 22, 2}, {3, 13, 23}, {24, 4, 14},
            {15, 25, 5}, {6, 16, 26}, {27, 7, 17}, {18, 28, 8}, {9, 19, 29}};
        for (auto& t : T) b64_24(out, c[t[0]], c[t[1]], c[t[2]], 4);
        b64_24(out, 0, c[31], c[30], 3);
    }
    return out;
}

// Poul-Henning Kamp's MD5-crypt: "$1$"
std::string md5_crypt(const std::string& pw, const std::string& setting) {
    const std::string magic = "$1$";
    size_t p = 3, se = p;
    while (se < setting.size() && se - p < 8 && setting[se] != '$' && setting[se] != ':' && setting[se] != '\n') se++;
    std::string salt = setting.substr(p, se - p);
    Hasher ctx("md5");
    ctx.add(pw); ctx.add(magic); ctx.add(salt);
    std::string fin = hdigest("md5", pw + salt + pw);
    for (long pl = (long)pw.size(); pl > 0; pl -= 16) ctx.add(fin.data(), (size_t)(pl > 16 ? 16 : pl));
    for (size_t i = pw.size(); i; i >>= 1) {
        if (i & 1) ctx.add("\0", 1); else ctx.add(pw.data(), 1);
    }
    fin = ctx.done();
    for (int i = 0; i < 1000; i++) {
        Hasher c1("md5");
        if (i & 1) c1.add(pw); else c1.add(fin);
        if (i % 3) c1.add(salt);
        if (i % 7) c1.add(pw);
        if (i & 1) c1.add(fin); else c1.add(pw);
        fin = c1.done();
    }
    const unsigned char* f = (const unsigned char*)fin.data();
    std::string out = magic + salt + "$";
    b64_24(out, f[0], f[6], f[12], 4);
    b64_24(out, f[1], f[7], f[13], 4);
    b64_24(out, f[2], f[8], f[14], 4);
    b64_24(out, f[3], f[9], f[15], 4);
    b64_24(out, f[4], f[10], f[5], 4);
    b64_24(out, 0, 0, f[11], 2);
    return out;
}

std::string native_crypt(const std::string& key, const std::string& setting) {
    std::string r;
    if (setting.compare(0, 3, "$6$") == 0) r = sha_crypt(key, setting, true);
    else if (setting.compare(0, 3, "$5$") == 0) r = sha_crypt(key, setting, false);
    else if (setting.compare(0, 3, "$1$") == 0) r = md5_crypt(key, setting);
    if (r.empty()) return setting.compare(0, 2, "*0") == 0 ? "*1" : "*0";   // libxcrypt's failure token
    return r;
}

Ret c_crypt(Engine&, const Args& a) {
    std::string word = a.as_str(0), salt = a.as_str(1);
    CryptApi& api = crypt_api();
    if (!api.lib) {
        std::string r;
        {
            GilRelease unlocked;
            r = native_crypt(word, salt);
        }
        return Ret::str(r);
    }
    std::string r;
    int err = 0;
    bool ok = false;
    {
        GilRelease unlocked;
        if (api.crypt_r) {
            // libxcrypt's struct crypt_data is 32 KB, glibc's 128 KB
            std::vector<char> data(256 * 1024, 0);
            errno = 0;
            char* p = api.crypt_r(word.c_str(), salt.c_str(), data.data());
            if (p) { r = p; ok = true; } else err = errno;
        } else {
            static std::mutex m;   // crypt() keeps its result in a static buffer
            std::lock_guard<std::mutex> l(m);
            errno = 0;
            char* p = api.crypt(word.c_str(), salt.c_str());
            if (p) { r = p; ok = true; } else err = errno;
        }
    }
    if (!ok) return Ret::integer(err ? err : EINVAL);
    return Ret::str(r);
}
Ret c_native(Engine&, const Args& a) {
    std::string word = a.as_str(0), salt = a.as_str(1), r;
    {
        GilRelease unlocked;
        r = native_crypt(word, salt);
    }
    return Ret::str(r);
}
Ret c_backend(Engine&, const Args&) { return Ret::str(crypt_api().lib ? "libcrypt" : "native"); }

// ── spwd ────────────────────────────────────────────────────────────────────
#ifdef NY_HAVE_SHADOW
Ret spent(const struct spwd* p) {
    std::vector<Ret> v;
    v.push_back(Ret::str(p->sp_namp ? p->sp_namp : ""));
    v.push_back(Ret::str(p->sp_pwdp ? p->sp_pwdp : ""));
    v.push_back(Ret::integer((int64_t)p->sp_lstchg));
    v.push_back(Ret::integer((int64_t)p->sp_min));
    v.push_back(Ret::integer((int64_t)p->sp_max));
    v.push_back(Ret::integer((int64_t)p->sp_warn));
    v.push_back(Ret::integer((int64_t)p->sp_inact));
    v.push_back(Ret::integer((int64_t)p->sp_expire));
    v.push_back(Ret::integer((int64_t)(long)p->sp_flag));
    return Ret::lst(std::move(v));
}
std::mutex& spwd_mutex() { static std::mutex m; return m; }
#endif
Ret s_supported(Engine&, const Args&) {
#ifdef NY_HAVE_SHADOW
    return Ret::boolean(true);
#else
    return Ret::boolean(false);
#endif
}
Ret s_getspnam(Engine&, const Args& a) {
#ifdef NY_HAVE_SHADOW
    std::string name = a.as_str(0);
    std::lock_guard<std::mutex> l(spwd_mutex());
    errno = 0;
    struct spwd* p = getspnam(name.c_str());
    if (!p) return Ret::integer(errno == ENOENT ? 0 : errno);
    return spent(p);
#else
    (void)a;
    return Ret::none();
#endif
}
Ret s_getspall(Engine&, const Args&) {
#ifdef NY_HAVE_SHADOW
    std::lock_guard<std::mutex> l(spwd_mutex());
    std::vector<Ret> out;
    setspent();
    errno = 0;
    while (struct spwd* p = getspent()) out.push_back(spent(p));
    endspent();
    return Ret::lst(std::move(out));
#else
    return Ret::none();
#endif
}

// ── nis ─────────────────────────────────────────────────────────────────────
struct YpMapList { char* map; YpMapList* next; };
struct NisApi {
    bool tried = false;
    void* lib = nullptr;
    std::string why;
    int (*get_default_domain)(char**) = nullptr;
    int (*match)(const char*, const char*, const char*, int, char**, int*) = nullptr;
    int (*first)(const char*, const char*, char**, int*, char**, int*) = nullptr;
    int (*next)(const char*, const char*, const char*, int, char**, int*, char**, int*) = nullptr;
    int (*maplist)(const char*, YpMapList**) = nullptr;
    const char* (*errstr)(int) = nullptr;
};
NisApi& nis_api() {
    static NisApi a;
    static std::mutex m;
    std::lock_guard<std::mutex> l(m);
    if (a.tried) return a;
    a.tried = true;
#ifdef _WIN32
    a.why = "NIS is not available on Windows";
    return a;
#else
    std::vector<std::string> names;
    if (const char* env = std::getenv("NY_LIBNSL")) if (*env) names.push_back(env);
#ifdef __APPLE__
    names.push_back("/usr/lib/libSystem.B.dylib");
#else
    for (const char* n : {"libnsl.so.1", "libnsl.so.2", "libnsl.so"}) names.push_back(n);
#endif
    a.lib = lib_open(names);
    if (!a.lib) { a.why = "no NIS library (libnsl) was found"; return a; }
    a.get_default_domain = reinterpret_cast<int (*)(char**)>(lib_sym(a.lib, "yp_get_default_domain"));
    a.match = reinterpret_cast<int (*)(const char*, const char*, const char*, int, char**, int*)>(lib_sym(a.lib, "yp_match"));
    a.first = reinterpret_cast<int (*)(const char*, const char*, char**, int*, char**, int*)>(lib_sym(a.lib, "yp_first"));
    a.next = reinterpret_cast<int (*)(const char*, const char*, const char*, int, char**, int*, char**, int*)>(lib_sym(a.lib, "yp_next"));
    a.maplist = reinterpret_cast<int (*)(const char*, YpMapList**)>(lib_sym(a.lib, "yp_maplist"));
    a.errstr = reinterpret_cast<const char* (*)(int)>(lib_sym(a.lib, "yperr_string"));
    if (!a.get_default_domain || !a.match || !a.first || !a.next || !a.errstr) {
        a.why = "the NIS library lacks the yp_* functions";
        a.lib = nullptr;
    }
    return a;
#endif
}

Ret pair(int err, Ret v) { std::vector<Ret> o; o.push_back(Ret::integer(err)); o.push_back(std::move(v)); return Ret::lst(std::move(o)); }

Ret n_call(Engine&, const Args& a) {
    std::string op = a.as_str(0);
    NisApi& api = nis_api();
    if (op == "why") return Ret::str(api.lib ? "" : api.why);
    if (!api.lib) return pair(-1, Ret::none());
    if (op == "errstr") {
        const char* s = api.errstr((int)a.as_int(1));
        return Ret::str(s ? s : "unknown NIS error");
    }
    if (op == "domain") {
        char* dom = nullptr;
        int err;
        { GilRelease unlocked; err = api.get_default_domain(&dom); }
        return pair(err, err ? Ret::none() : Ret::str(dom ? dom : ""));
    }
    if (op == "match") {
        std::string key = a.as_bytes(1), map = a.as_str(2), dom = a.as_str(3);
        char* out = nullptr;
        int len = 0, err;
        { GilRelease unlocked; err = api.match(dom.c_str(), map.c_str(), key.data(), (int)key.size(), &out, &len); }
        if (err) return pair(err, Ret::none());
        std::string v(out ? out : "", out ? (size_t)len : 0);
        std::free(out);
        return pair(0, Ret::bytes(v));
    }
    if (op == "cat") {
        std::string map = a.as_str(1), dom = a.as_str(2);
        std::vector<Ret> items;
        char *k = nullptr, *v = nullptr;
        int kl = 0, vl = 0, err;
        { GilRelease unlocked; err = api.first(dom.c_str(), map.c_str(), &k, &kl, &v, &vl); }
        while (err == 0) {
            std::vector<Ret> kv;
            kv.push_back(Ret::bytes(std::string(k, (size_t)kl)));
            kv.push_back(Ret::bytes(std::string(v, (size_t)vl)));
            items.push_back(Ret::lst(std::move(kv)));
            std::string prev(k, (size_t)kl);
            std::free(k); std::free(v);
            k = v = nullptr;
            { GilRelease unlocked; err = api.next(dom.c_str(), map.c_str(), prev.data(), (int)prev.size(), &k, &kl, &v, &vl); }
        }
        if (err != 7 /* YPERR_NOMORE */) return pair(err, Ret::none());
        return pair(0, Ret::lst(std::move(items)));
    }
    if (op == "maps") {
        std::string dom = a.as_str(1);
        if (!api.maplist) return pair(1 /* YPERR_BADARGS */, Ret::none());
        YpMapList* ml = nullptr;
        int err;
        { GilRelease unlocked; err = api.maplist(dom.c_str(), &ml); }
        if (err) return pair(err, Ret::none());
        std::vector<Ret> names;
        for (YpMapList* m = ml; m; m = m->next) names.push_back(Ret::str(m->map ? m->map : ""));
        return pair(0, Ret::lst(std::move(names)));
    }
    return pair(-1, Ret::none());
}

struct Registrar {
    Registrar() {
        struct { const char* n; ExtHandler h; } t[] = {
            {"_crypt_crypt", c_crypt}, {"_crypt_native", c_native}, {"_crypt_backend", c_backend},
            {"_spwd_supported", s_supported}, {"_spwd_getspnam", s_getspnam}, {"_spwd_getspall", s_getspall},
            {"_nis_call", n_call},
        };
        for (auto& x : t) register_extension(x.n, x.h);
    }
};
Registrar g_registrar;

} // namespace
