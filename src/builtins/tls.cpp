// builtins/tls.cpp - TLS for the socket layer (round 77).
//
// OpenSSL (1.1.1 or 3.x) is loaded when a program first uses TLS - dlopen /
// LoadLibrary, nothing at build or link time - so Nython builds everywhere and
// TLS works wherever libssl is installed (NY_LIBSSL names a library to try
// first). A context (_tls_ctx_new) holds the configuration; _tls_wrap attaches
// a TLS session to a socket of the socket layer (net.cpp), which from then on
// routes the socket's send/recv through tls_write/tls_read. The socket stays
// non-blocking underneath, so the handshake and every read and write wait the
// way plain socket I/O does: within the socket's timeout, with the GIL
// released, parking an async task instead of blocking its loop, and running
// signal handlers.
//
// Defaults are Python's ssl.create_default_context(): a client verifies the
// server's certificate against the system's trust store and checks the host
// name (SNI and RFC 6125 matching, IP addresses too); TLS 1.2 is the minimum.
//
// Natives (lib/ssl.ny is the Python-style module over them):
//   _tls_available() -> bool          _tls_version_text() -> "OpenSSL 3.0.13 ..."
//   _tls_ctx_new(server) -> h         _tls_ctx_free(h)
//   _tls_ctx_set_verify(h, mode)      mode: 0 none, 1 optional, 2 required
//   _tls_ctx_default_paths(h)         the system trust store
//   _tls_ctx_load_verify(h, cafile, capath, cadata)
//   _tls_ctx_load_cert_chain(h, certfile, keyfile, password)
//   _tls_ctx_set_alpn(h, [protocols]) _tls_ctx_set_ciphers(h, text)
//   _tls_ctx_set_versions(h, min, max) (0x0303 TLS 1.2, 0x0304 TLS 1.3; 0: any)
//   _tls_wrap(sock, h, server_side, server_hostname, check_hostname, handshake)
//   _tls_handshake(sock)              _tls_unwrap(sock)
//   _tls_info(sock) -> {version, cipher, bits, alpn}
//   _tls_peer_cert(sock, binary)      the peer certificate as Python's dict / DER
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyConc.hpp"
#include "builtins/net.hpp"
#include "builtins/os.hpp"
#include <cstring>
#include <ctime>
#include <mutex>
#include <unordered_map>
#ifdef _WIN32
#  include <winsock2.h>
#  include <ws2tcpip.h>
#  include <windows.h>
#else
#  include <dlfcn.h>
#  include <arpa/inet.h>
#endif

namespace {

// ── the OpenSSL API, resolved at run time ───────────────────────────────────
struct Api {
    bool tried = false, ok = false;
    std::string why;
    void* lib = nullptr;
    const void* (*TLS_client_method)() = nullptr;
    const void* (*TLS_server_method)() = nullptr;
    void* (*SSL_CTX_new)(const void*) = nullptr;
    void (*SSL_CTX_free)(void*) = nullptr;
    long (*SSL_CTX_ctrl)(void*, int, long, void*) = nullptr;
    void (*SSL_CTX_set_verify)(void*, int, void*) = nullptr;
    int (*SSL_CTX_set_default_verify_paths)(void*) = nullptr;
    int (*SSL_CTX_load_verify_locations)(void*, const char*, const char*) = nullptr;
    int (*SSL_CTX_use_certificate_chain_file)(void*, const char*) = nullptr;
    int (*SSL_CTX_use_PrivateKey_file)(void*, const char*, int) = nullptr;
    int (*SSL_CTX_check_private_key)(const void*) = nullptr;
    int (*SSL_CTX_set_cipher_list)(void*, const char*) = nullptr;
    int (*SSL_CTX_set_alpn_protos)(void*, const unsigned char*, unsigned) = nullptr;
    void (*SSL_CTX_set_alpn_select_cb)(void*, int (*)(void*, const unsigned char**, unsigned char*,
                                                      const unsigned char*, unsigned, void*), void*) = nullptr;
    void (*SSL_CTX_set_default_passwd_cb_userdata)(void*, void*) = nullptr;
    void* (*SSL_CTX_get_cert_store)(const void*) = nullptr;
    void* (*SSL_new)(void*) = nullptr;
    void (*SSL_free)(void*) = nullptr;
    int (*SSL_set_fd)(void*, int) = nullptr;
    int (*SSL_connect)(void*) = nullptr;
    int (*SSL_accept)(void*) = nullptr;
    int (*SSL_read)(void*, void*, int) = nullptr;
    int (*SSL_write)(void*, const void*, int) = nullptr;
    int (*SSL_shutdown)(void*) = nullptr;
    int (*SSL_get_error)(const void*, int) = nullptr;
    int (*SSL_pending)(const void*) = nullptr;
    long (*SSL_ctrl)(void*, int, long, void*) = nullptr;
    int (*SSL_set1_host)(void*, const char*) = nullptr;
    void* (*SSL_get0_param)(void*) = nullptr;
    int (*X509_VERIFY_PARAM_set1_ip_asc)(void*, const char*) = nullptr;
    long (*SSL_get_verify_result)(const void*) = nullptr;
    void* (*SSL_get_peer_cert)(const void*) = nullptr;   // SSL_get1_peer_certificate / SSL_get_peer_certificate
    const char* (*SSL_get_version)(const void*) = nullptr;
    const void* (*SSL_get_current_cipher)(const void*) = nullptr;
    const char* (*SSL_CIPHER_get_name)(const void*) = nullptr;
    int (*SSL_CIPHER_get_bits)(const void*, int*) = nullptr;
    void (*SSL_get0_alpn_selected)(const void*, const unsigned char**, unsigned*) = nullptr;
    unsigned long (*ERR_get_error)() = nullptr;
    void (*ERR_error_string_n)(unsigned long, char*, size_t) = nullptr;
    void (*ERR_clear_error)() = nullptr;
    const char* (*ERR_reason_error_string)(unsigned long) = nullptr;
    void (*X509_free)(void*) = nullptr;
    void* (*X509_get_subject_name)(const void*) = nullptr;
    void* (*X509_get_issuer_name)(const void*) = nullptr;
    int (*X509_NAME_entry_count)(const void*) = nullptr;
    void* (*X509_NAME_get_entry)(const void*, int) = nullptr;
    void* (*X509_NAME_ENTRY_get_object)(const void*) = nullptr;
    void* (*X509_NAME_ENTRY_get_data)(const void*) = nullptr;
    int (*X509_NAME_ENTRY_set)(const void*) = nullptr;
    int (*OBJ_obj2nid)(const void*) = nullptr;
    const char* (*OBJ_nid2ln)(int) = nullptr;
    const unsigned char* (*ASN1_STRING_get0_data)(const void*) = nullptr;
    int (*ASN1_STRING_length)(const void*) = nullptr;
    int (*i2d_X509)(const void*, unsigned char**) = nullptr;
    void* (*X509_get_ext_d2i)(const void*, int, int*, int*) = nullptr;
    int (*OPENSSL_sk_num)(const void*) = nullptr;
    void* (*OPENSSL_sk_value)(const void*, int) = nullptr;
    void (*GENERAL_NAMES_free)(void*) = nullptr;
    const void* (*X509_get0_notBefore)(const void*) = nullptr;
    const void* (*X509_get0_notAfter)(const void*) = nullptr;
    int (*ASN1_TIME_to_tm)(const void*, struct tm*) = nullptr;
    long (*X509_get_version)(const void*) = nullptr;
    void* (*X509_get_serialNumber)(void*) = nullptr;
    void* (*ASN1_INTEGER_to_BN)(const void*, void*) = nullptr;
    char* (*BN_bn2hex)(const void*) = nullptr;
    void (*BN_free)(void*) = nullptr;
    void (*CRYPTO_free)(void*, const char*, int) = nullptr;
    const char* (*X509_verify_cert_error_string)(long) = nullptr;
    const char* (*OpenSSL_version)(int) = nullptr;
    void* (*BIO_new_mem_buf)(const void*, int) = nullptr;
    void (*BIO_free)(void*) = nullptr;
    void* (*PEM_read_bio_X509)(void*, void*, void*, void*) = nullptr;
    int (*X509_STORE_add_cert)(void*, void*) = nullptr;
};

static void* sym(void* lib, const char* name) {
#ifdef _WIN32
    return (void*)GetProcAddress((HMODULE)lib, name);
#else
    return dlsym(lib, name);
#endif
}

template <typename F> static bool bind(Api& a, F& f, const char* name, bool required = true) {
    f = reinterpret_cast<F>(sym(a.lib, name));
    if (!f && required && a.why.empty()) a.why = std::string("missing ") + name;
    return f != nullptr;
}

static Api& api() {
    static Api a;
    static std::mutex m;
    std::lock_guard<std::mutex> l(m);
    if (a.tried) return a;
    a.tried = true;
    std::vector<std::string> names;
    if (const char* env = std::getenv("NY_LIBSSL")) if (*env) names.push_back(env);
#ifdef _WIN32
    for (const char* n : {"libssl-3-x64.dll", "libssl-3.dll", "libssl-1_1-x64.dll", "libssl-1_1.dll"}) names.push_back(n);
    std::vector<std::string> crypto = {"libcrypto-3-x64.dll", "libcrypto-3.dll", "libcrypto-1_1-x64.dll", "libcrypto-1_1.dll"};
    for (auto& n : names) { HMODULE h = LoadLibraryA(n.c_str()); if (h) { a.lib = (void*)h; break; } }
    // libcrypto's functions are not reachable through libssl's handle on
    // Windows: look them up in it separately.
    void* cr = nullptr;
    for (auto& n : crypto) { HMODULE h = LoadLibraryA(n.c_str()); if (h) { cr = (void*)h; break; } }
#elif defined(__APPLE__)
    for (const char* n : {"libssl.3.dylib", "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
                          "/usr/local/opt/openssl@3/lib/libssl.3.dylib", "libssl.1.1.dylib",
                          "/opt/homebrew/opt/openssl@1.1/lib/libssl.1.1.dylib", "/usr/local/opt/openssl@1.1/lib/libssl.1.1.dylib"})
        names.push_back(n);
    for (auto& n : names) { a.lib = dlopen(n.c_str(), RTLD_NOW | RTLD_GLOBAL); if (a.lib) break; }
    void* cr = a.lib;
#else
    for (const char* n : {"libssl.so.3", "libssl.so.1.1", "libssl.so"}) names.push_back(n);
    for (auto& n : names) { a.lib = dlopen(n.c_str(), RTLD_NOW | RTLD_GLOBAL); if (a.lib) break; }
    void* cr = a.lib;
#endif
    if (!a.lib) { a.why = "no OpenSSL library found (install libssl, or set NY_LIBSSL)"; return a; }
    bind(a, a.TLS_client_method, "TLS_client_method");
    bind(a, a.TLS_server_method, "TLS_server_method");
    bind(a, a.SSL_CTX_new, "SSL_CTX_new");
    bind(a, a.SSL_CTX_free, "SSL_CTX_free");
    bind(a, a.SSL_CTX_ctrl, "SSL_CTX_ctrl");
    bind(a, a.SSL_CTX_set_verify, "SSL_CTX_set_verify");
    bind(a, a.SSL_CTX_set_default_verify_paths, "SSL_CTX_set_default_verify_paths");
    bind(a, a.SSL_CTX_load_verify_locations, "SSL_CTX_load_verify_locations");
    bind(a, a.SSL_CTX_use_certificate_chain_file, "SSL_CTX_use_certificate_chain_file");
    bind(a, a.SSL_CTX_use_PrivateKey_file, "SSL_CTX_use_PrivateKey_file");
    bind(a, a.SSL_CTX_check_private_key, "SSL_CTX_check_private_key");
    bind(a, a.SSL_CTX_set_cipher_list, "SSL_CTX_set_cipher_list");
    bind(a, a.SSL_CTX_set_alpn_protos, "SSL_CTX_set_alpn_protos");
    bind(a, a.SSL_CTX_set_alpn_select_cb, "SSL_CTX_set_alpn_select_cb");
    bind(a, a.SSL_CTX_set_default_passwd_cb_userdata, "SSL_CTX_set_default_passwd_cb_userdata");
    bind(a, a.SSL_CTX_get_cert_store, "SSL_CTX_get_cert_store");
    bind(a, a.SSL_new, "SSL_new");
    bind(a, a.SSL_free, "SSL_free");
    bind(a, a.SSL_set_fd, "SSL_set_fd");
    bind(a, a.SSL_connect, "SSL_connect");
    bind(a, a.SSL_accept, "SSL_accept");
    bind(a, a.SSL_read, "SSL_read");
    bind(a, a.SSL_write, "SSL_write");
    bind(a, a.SSL_shutdown, "SSL_shutdown");
    bind(a, a.SSL_get_error, "SSL_get_error");
    bind(a, a.SSL_pending, "SSL_pending");
    bind(a, a.SSL_ctrl, "SSL_ctrl");
    bind(a, a.SSL_set1_host, "SSL_set1_host");
    bind(a, a.SSL_get0_param, "SSL_get0_param");
    bind(a, a.SSL_get_verify_result, "SSL_get_verify_result");
    if (!bind(a, a.SSL_get_peer_cert, "SSL_get1_peer_certificate", false))
        bind(a, a.SSL_get_peer_cert, "SSL_get_peer_certificate");
    bind(a, a.SSL_get_version, "SSL_get_version");
    bind(a, a.SSL_get_current_cipher, "SSL_get_current_cipher");
    bind(a, a.SSL_CIPHER_get_name, "SSL_CIPHER_get_name");
    bind(a, a.SSL_CIPHER_get_bits, "SSL_CIPHER_get_bits");
    bind(a, a.SSL_get0_alpn_selected, "SSL_get0_alpn_selected");
    // libcrypto
    void* keep = a.lib;
    a.lib = cr ? cr : keep;
    bind(a, a.ERR_get_error, "ERR_get_error");
    bind(a, a.ERR_error_string_n, "ERR_error_string_n");
    bind(a, a.ERR_clear_error, "ERR_clear_error");
    bind(a, a.ERR_reason_error_string, "ERR_reason_error_string");
    bind(a, a.X509_VERIFY_PARAM_set1_ip_asc, "X509_VERIFY_PARAM_set1_ip_asc");
    bind(a, a.X509_free, "X509_free");
    bind(a, a.X509_get_subject_name, "X509_get_subject_name");
    bind(a, a.X509_get_issuer_name, "X509_get_issuer_name");
    bind(a, a.X509_NAME_entry_count, "X509_NAME_entry_count");
    bind(a, a.X509_NAME_get_entry, "X509_NAME_get_entry");
    bind(a, a.X509_NAME_ENTRY_get_object, "X509_NAME_ENTRY_get_object");
    bind(a, a.X509_NAME_ENTRY_get_data, "X509_NAME_ENTRY_get_data");
    bind(a, a.X509_NAME_ENTRY_set, "X509_NAME_ENTRY_set");
    bind(a, a.OBJ_obj2nid, "OBJ_obj2nid");
    bind(a, a.OBJ_nid2ln, "OBJ_nid2ln");
    bind(a, a.ASN1_STRING_get0_data, "ASN1_STRING_get0_data");
    bind(a, a.ASN1_STRING_length, "ASN1_STRING_length");
    bind(a, a.i2d_X509, "i2d_X509");
    bind(a, a.X509_get_ext_d2i, "X509_get_ext_d2i");
    bind(a, a.OPENSSL_sk_num, "OPENSSL_sk_num");
    bind(a, a.OPENSSL_sk_value, "OPENSSL_sk_value");
    bind(a, a.GENERAL_NAMES_free, "GENERAL_NAMES_free");
    bind(a, a.X509_get0_notBefore, "X509_get0_notBefore");
    bind(a, a.X509_get0_notAfter, "X509_get0_notAfter");
    bind(a, a.ASN1_TIME_to_tm, "ASN1_TIME_to_tm");
    bind(a, a.X509_get_version, "X509_get_version");
    bind(a, a.X509_get_serialNumber, "X509_get_serialNumber");
    bind(a, a.ASN1_INTEGER_to_BN, "ASN1_INTEGER_to_BN");
    bind(a, a.BN_bn2hex, "BN_bn2hex");
    bind(a, a.BN_free, "BN_free");
    bind(a, a.CRYPTO_free, "CRYPTO_free");
    bind(a, a.X509_verify_cert_error_string, "X509_verify_cert_error_string");
    bind(a, a.OpenSSL_version, "OpenSSL_version");
    bind(a, a.BIO_new_mem_buf, "BIO_new_mem_buf");
    bind(a, a.BIO_free, "BIO_free");
    bind(a, a.PEM_read_bio_X509, "PEM_read_bio_X509");
    bind(a, a.X509_STORE_add_cert, "X509_STORE_add_cert");
    a.lib = keep;
    a.ok = a.why.empty();
    return a;
}

constexpr int SSL_ERROR_SSL = 1, SSL_ERROR_WANT_READ = 2, SSL_ERROR_WANT_WRITE = 3,
              SSL_ERROR_SYSCALL = 5, SSL_ERROR_ZERO_RETURN = 6;
constexpr int SSL_CTRL_MODE = 33, SSL_CTRL_SET_TLSEXT_HOSTNAME = 55,
              SSL_CTRL_SET_MIN_PROTO_VERSION = 123, SSL_CTRL_SET_MAX_PROTO_VERSION = 124;
constexpr int NID_subject_alt_name = 85, GEN_DNS = 2, GEN_IPADD = 7;

[[noreturn]] void raise_ssl(const std::string& type, const std::string& msg) { nynet::raise(type, msg); }

Api& need_api() {
    Api& a = api();
    if (!a.ok) raise_ssl("SSLError", "TLS is not available: " + a.why);
    return a;
}

// The OpenSSL error queue as one message: "[SSL] reason (library error text)".
std::string queue_text(Api& a) {
    std::string out;
    unsigned long e;
    while ((e = a.ERR_get_error()) != 0) {
        char buf[256];
        a.ERR_error_string_n(e, buf, sizeof buf);
        const char* reason = a.ERR_reason_error_string ? a.ERR_reason_error_string(e) : nullptr;
        std::string one = reason ? std::string(reason) : std::string(buf);
        if (!out.empty()) out += "; ";
        out += one;
    }
    return out;
}

// ── contexts ────────────────────────────────────────────────────────────────
struct Ctx {
    void* ctx = nullptr;
    bool server = false;
    int verify = 2;
    std::string password;
    std::vector<unsigned char> alpn;      // wire format, for the server's selection
    ~Ctx() { if (ctx) api().SSL_CTX_free(ctx); }
};
std::mutex& ctx_mu() { static std::mutex* m = new std::mutex(); return *m; }
std::unordered_map<int64_t, std::shared_ptr<Ctx>>& ctxs() {
    static auto* t = new std::unordered_map<int64_t, std::shared_ptr<Ctx>>();
    return *t;
}
int64_t g_next_ctx = 1;

std::shared_ptr<Ctx> get_ctx(int64_t h) {
    std::lock_guard<std::mutex> l(ctx_mu());
    auto it = ctxs().find(h);
    if (it == ctxs().end()) raise_ssl("ValueError", "invalid TLS context");
    return it->second;
}

void apply_verify(Api& a, Ctx& c) {
    int mode = c.verify == 0 ? 0 : c.verify == 1 ? 1 : (c.server ? 1 | 2 : 1);
    a.SSL_CTX_set_verify(c.ctx, mode, nullptr);
}

int alpn_select(void* ssl, const unsigned char** out, unsigned char* outlen,
                const unsigned char* in, unsigned inlen, void* arg) {
    (void)ssl;
    auto* c = static_cast<Ctx*>(arg);
    // the server's preference order: its first protocol the client offers
    size_t i = 0;
    while (i < c->alpn.size()) {
        unsigned n = c->alpn[i];
        const unsigned char* mine = &c->alpn[i + 1];
        for (unsigned j = 0; j < inlen;) {
            unsigned m = in[j];
            if (m == n && std::memcmp(in + j + 1, mine, n) == 0) {
                *out = in + j + 1; *outlen = (unsigned char)m; return 0;   // SSL_TLSEXT_ERR_OK
            }
            j += 1 + m;
        }
        i += 1 + n;
    }
    return 3;   // SSL_TLSEXT_ERR_NOACK
}

bool is_ip_literal(const std::string& h) {
    unsigned char buf[16];
    return inet_pton(AF_INET, h.c_str(), buf) == 1 || inet_pton(AF_INET6, h.c_str(), buf) == 1;
}

} // namespace

// ── sessions ────────────────────────────────────────────────────────────────
namespace nynet {

struct TlsConn {
    void* ssl = nullptr;
    std::shared_ptr<Ctx> ctx;
    bool server = false;
    bool handshaken = false;
    std::string hostname;
    std::string last_error;
    ~TlsConn() { if (ssl) api().SSL_free(ssl); }
};

std::string tls_error_text(TlsConn* t) {
    return t && !t->last_error.empty() ? t->last_error : std::string("[SSL] TLS error");
}

// A failed SSL call: what to wait for, or a final error.
static long tls_fail(TlsConn* t, int r, int* wait, int* err) {
    Api& a = api();
    int e = a.SSL_get_error(t->ssl, r);
    if (e == SSL_ERROR_WANT_READ) { *wait = nyconc::IO_READ; *err = 0; return -1; }
    if (e == SSL_ERROR_WANT_WRITE) { *wait = nyconc::IO_WRITE; *err = 0; return -1; }
    *wait = 0;
    if (e == SSL_ERROR_ZERO_RETURN) { *err = 0; return 0; }      // close_notify: end of stream
    if (e == SSL_ERROR_SYSCALL) {
        int en = errno;
        std::string q = queue_text(a);
        if (en == 0 && q.empty()) return 0;                       // EOF without close_notify
        if (en != 0) { *err = en; return -1; }
        t->last_error = "[SSL] " + q;
        *err = -1;
        return -1;
    }
    std::string q = queue_text(a);
    // A peer that closed without close_notify (OpenSSL 3: "unexpected eof
    // while reading") ends the stream, as Python's suppress_ragged_eofs.
    if (q.find("unexpected eof") != std::string::npos) return 0;
    t->last_error = "[SSL] " + (q.empty() ? std::string("TLS protocol error") : q);
    *err = -1;
    return -1;
}

long tls_write(TlsConn* t, const char* p, size_t n, int* wait, int* err) {
    Api& a = api();
    a.ERR_clear_error();
    errno = 0;
    int r = a.SSL_write(t->ssl, p, (int)std::min<size_t>(n, 1u << 30));
    if (r > 0) return r;
    long f = tls_fail(t, r, wait, err);
    if (f == 0 && !*wait) { *err = 32; return -1; }      // EPIPE: writing after the peer closed
    return f;
}
long tls_read(TlsConn* t, char* p, size_t n, int* wait, int* err) {
    Api& a = api();
    a.ERR_clear_error();
    errno = 0;
    int r = a.SSL_read(t->ssl, p, (int)std::min<size_t>(n, 1u << 30));
    if (r > 0) return r;
    return tls_fail(t, r, wait, err);
}
long tls_pending(TlsConn* t) { return t && t->ssl ? api().SSL_pending(t->ssl) : 0; }
void tls_free(TlsConn* t) { delete t; }

} // namespace nynet

namespace {

using nynet::TlsConn;

// The handshake, within the socket's timeout. A certificate that does not
// verify is SSLCertVerificationError with OpenSSL's reason, as in Python.
void handshake(nynet::Sock& s, TlsConn* t) {
    Api& a = api();
    double timeout = nynet::sock_timeout(s);
    auto start = std::chrono::steady_clock::now();
    while (true) {
        a.ERR_clear_error();
        errno = 0;
        int r = t->server ? a.SSL_accept(t->ssl) : a.SSL_connect(t->ssl);
        if (r == 1) { t->handshaken = true; return; }
        int e = a.SSL_get_error(t->ssl, r);
        int ev = e == SSL_ERROR_WANT_READ ? nyconc::IO_READ : e == SSL_ERROR_WANT_WRITE ? nyconc::IO_WRITE : 0;
        if (ev) {
            double left = -1;
            if (timeout >= 0) {
                double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
                left = (timeout - used) * 1000.0;
                if (left <= 0) raise_ssl("TimeoutError", "_ssl.c: The handshake operation timed out");
            }
            if (!nynet::sock_wait(s, ev, left)) raise_ssl("TimeoutError", "_ssl.c: The handshake operation timed out");
            continue;
        }
        long vr = a.SSL_get_verify_result(t->ssl);
        std::string q = queue_text(a);
        if (vr != 0 && (q.find("certificate verify failed") != std::string::npos || e == SSL_ERROR_SSL)) {
            std::string why = a.X509_verify_cert_error_string(vr);
            if (vr == 62) why = "Hostname mismatch, certificate is not valid for '" + t->hostname + "'.";
            if (vr == 64) why = "IP address mismatch, certificate is not valid for '" + t->hostname + "'.";
            raise_ssl("SSLCertVerificationError", "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: " + why);
        }
        if (e == SSL_ERROR_SYSCALL && q.empty()) {
            if (errno) nynet::raise_err(errno);
            raise_ssl("SSLEOFError", "[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol");
        }
        if (e == SSL_ERROR_ZERO_RETURN || q.find("unexpected eof") != std::string::npos)
            raise_ssl("SSLEOFError", "[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol");
        raise_ssl("SSLError", "[SSL] " + (q.empty() ? std::string("handshake failed") : q));
    }
}

std::string asn1_text(Api& a, const void* s) {
    if (!s) return std::string();
    return std::string((const char*)a.ASN1_STRING_get0_data(s), (size_t)a.ASN1_STRING_length(s));
}

// Python's name form: ((('commonName', 'x'),), (('organizationName', 'y'),))
Value name_value(NythonExecutor& E, Api& a, void* name) {
    std::vector<Value> rdns;
    int n = name ? a.X509_NAME_entry_count(name) : 0;
    for (int i = 0; i < n; i++) {
        void* ent = a.X509_NAME_get_entry(name, i);
        int nid = a.OBJ_obj2nid(a.X509_NAME_ENTRY_get_object(ent));
        const char* ln = a.OBJ_nid2ln(nid);
        std::vector<Value> pair{E.makeStringValue(ln ? ln : "?"), E.makeStringValue(asn1_text(a, a.X509_NAME_ENTRY_get_data(ent)))};
        std::vector<Value> rdn{E.makeListValue(pair, true)};
        rdns.push_back(E.makeListValue(rdn, true));
    }
    return E.makeListValue(rdns, true);
}

std::string time_text(Api& a, const void* t) {
    struct tm tmv;
    std::memset(&tmv, 0, sizeof tmv);
    if (!t || !a.ASN1_TIME_to_tm || a.ASN1_TIME_to_tm(t, &tmv) != 1) return std::string();
    static const char* mon[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    char buf[64];
    snprintf(buf, sizeof buf, "%s %2d %02d:%02d:%02d %d GMT", mon[tmv.tm_mon % 12], tmv.tm_mday,
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, tmv.tm_year + 1900);
    return buf;
}

Value peer_cert(NythonExecutor& E, TlsConn* t, bool binary) {
    Api& a = need_api();
    void* cert = a.SSL_get_peer_cert(t->ssl);
    if (!cert) return NONE_VALUE;
    struct Free { Api& a; void* c; ~Free() { a.X509_free(c); } } fr{a, cert};
    if (binary) {
        unsigned char* der = nullptr;
        int n = a.i2d_X509(cert, &der);
        if (n <= 0) return NONE_VALUE;
        std::string out((const char*)der, (size_t)n);
        a.CRYPTO_free(der, __FILE__, __LINE__);
        return E.makeBytesValue(out);
    }
    Value d = E.makeDictValue();
    Container* dc = E.contOf(d);
    E.dictSet(dc, E.makeStringValue("subject"), name_value(E, a, a.X509_get_subject_name(cert)));
    E.dictSet(dc, E.makeStringValue("issuer"), name_value(E, a, a.X509_get_issuer_name(cert)));
    E.dictSet(dc, E.makeStringValue("version"), Value((int64_t)a.X509_get_version(cert) + 1));
    if (a.X509_get_serialNumber && a.ASN1_INTEGER_to_BN && a.BN_bn2hex) {
        void* bn = a.ASN1_INTEGER_to_BN(a.X509_get_serialNumber(cert), nullptr);
        if (bn) {
            char* hex = a.BN_bn2hex(bn);
            if (hex) { E.dictSet(dc, E.makeStringValue("serialNumber"), E.makeStringValue(hex)); a.CRYPTO_free(hex, __FILE__, __LINE__); }
            a.BN_free(bn);
        }
    }
    E.dictSet(dc, E.makeStringValue("notBefore"), E.makeStringValue(time_text(a, a.X509_get0_notBefore(cert))));
    E.dictSet(dc, E.makeStringValue("notAfter"), E.makeStringValue(time_text(a, a.X509_get0_notAfter(cert))));
    void* sans = a.X509_get_ext_d2i(cert, NID_subject_alt_name, nullptr, nullptr);
    if (sans) {
        std::vector<Value> alt;
        int n = a.OPENSSL_sk_num(sans);
        struct GenName { int type; void* ptr; };
        for (int i = 0; i < n; i++) {
            auto* g = static_cast<GenName*>(a.OPENSSL_sk_value(sans, i));
            if (!g) continue;
            if (g->type == GEN_DNS) {
                std::vector<Value> pr{E.makeStringValue("DNS"), E.makeStringValue(asn1_text(a, g->ptr))};
                alt.push_back(E.makeListValue(pr, true));
            } else if (g->type == GEN_IPADD) {
                std::string raw = asn1_text(a, g->ptr);
                char buf[64] = {0};
                if (raw.size() == 4) inet_ntop(AF_INET, raw.data(), buf, sizeof buf);
                else if (raw.size() == 16) inet_ntop(AF_INET6, raw.data(), buf, sizeof buf);
                std::string ip = buf;
                if (raw.size() == 16) {   // Python prints IPv6 in full, upper-case
                    char full[64];
                    const unsigned char* b = (const unsigned char*)raw.data();
                    snprintf(full, sizeof full, "%X:%X:%X:%X:%X:%X:%X:%X", b[0] << 8 | b[1], b[2] << 8 | b[3], b[4] << 8 | b[5],
                             b[6] << 8 | b[7], b[8] << 8 | b[9], b[10] << 8 | b[11], b[12] << 8 | b[13], b[14] << 8 | b[15]);
                    ip = full;
                }
                std::vector<Value> pr{E.makeStringValue("IP Address"), E.makeStringValue(ip)};
                alt.push_back(E.makeListValue(pr, true));
            }
        }
        a.GENERAL_NAMES_free(sans);
        E.dictSet(dc, E.makeStringValue("subjectAltName"), E.makeListValue(alt, true));
    }
    return d;
}

std::string str_arg(NythonExecutor& E, const nyos::Args& A, size_t i, const char* name) {
    if (!A.has(i, name)) return std::string();
    Value v = A.get(i, name);
    if (v.type == ValueType::NONE) return std::string();
    if (auto* bo = E.bytesOf(v)) return bo->s;
    return E.strOf(v, E.globalContext());
}
int64_t int_arg(NythonExecutor& E, const nyos::Args& A, size_t i, const char* name, int64_t dflt) {
    if (!A.has(i, name)) return dflt;
    Value v = A.get(i, name);
    if (v.type == ValueType::NONE) return dflt;
    if (v.type == ValueType::BOOLEAN) return v.value.b ? 1 : 0;
    if (v.type != ValueType::INTEGER) raise_ssl("TypeError", std::string(name) + " must be an integer");
    return bigint_to_i64(v.value.i);
}
bool bool_arg(NythonExecutor& E, const nyos::Args& A, size_t i, const char* name, bool dflt) {
    if (!A.has(i, name)) return dflt;
    return E.isTruthy(A.get(i, name));
}

} // namespace

std::vector<std::string> tls_builtin_names() {
    return {"_tls_available", "_tls_version_text", "_tls_ctx_new", "_tls_ctx_free", "_tls_ctx_set_verify",
            "_tls_ctx_default_paths", "_tls_ctx_load_verify", "_tls_ctx_load_cert_chain", "_tls_ctx_set_alpn",
            "_tls_ctx_set_ciphers", "_tls_ctx_set_versions", "_tls_wrap", "_tls_handshake", "_tls_unwrap",
            "_tls_info", "_tls_peer_cert"};
}

Value dispatch_tls(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name.compare(0, 5, "_tls_") != 0) return UNDEFINED_VALUE;
    nyos::Args A(E, args, {"server", "ctx", "mode", "cafile", "capath", "cadata", "certfile", "keyfile",
                           "password", "protocols", "ciphers", "minimum", "maximum", "sock", "server_side",
                           "server_hostname", "check_hostname", "do_handshake", "binary_form"});
    if (name == "_tls_available") return Value(api().ok);
    if (name == "_tls_version_text") {
        Api& a = api();
        if (!a.ok || !a.OpenSSL_version) return E.makeStringValue("");
        return E.makeStringValue(a.OpenSSL_version(0));
    }
    if (name == "_tls_ctx_new") {
        Api& a = need_api();
        auto c = std::make_shared<Ctx>();
        c->server = bool_arg(E, A, 0, "server", false);
        c->ctx = a.SSL_CTX_new(c->server ? a.TLS_server_method() : a.TLS_client_method());
        if (!c->ctx) raise_ssl("SSLError", "[SSL] cannot make a TLS context: " + queue_text(a));
        // partial writes, a moving write buffer, retries inside OpenSSL
        a.SSL_CTX_ctrl(c->ctx, SSL_CTRL_MODE, 1 | 2 | 4, nullptr);
        a.SSL_CTX_ctrl(c->ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, 0x0303, nullptr);   // TLS 1.2
        c->verify = c->server ? 0 : 2;
        apply_verify(a, *c);
        std::lock_guard<std::mutex> l(ctx_mu());
        int64_t h = g_next_ctx++;
        ctxs()[h] = c;
        return Value(h);
    }
    if (name == "_tls_ctx_free") {
        std::lock_guard<std::mutex> l(ctx_mu());
        ctxs().erase(int_arg(E, A, 0, "ctx", 0));
        return NONE_VALUE;
    }
    if (name == "_tls_ctx_set_verify") {
        Api& a = need_api();
        auto c = get_ctx(int_arg(E, A, 0, "ctx", 0));
        int64_t m = int_arg(E, A, 1, "mode", 2);
        if (m < 0 || m > 2) raise_ssl("ValueError", "invalid value for verify_mode");
        c->verify = (int)m;
        apply_verify(a, *c);
        return NONE_VALUE;
    }
    if (name == "_tls_ctx_default_paths") {
        Api& a = need_api();
        auto c = get_ctx(int_arg(E, A, 0, "ctx", 0));
        a.SSL_CTX_set_default_verify_paths(c->ctx);
        return NONE_VALUE;
    }
    if (name == "_tls_ctx_load_verify") {
        Api& a = need_api();
        auto c = get_ctx(int_arg(E, A, 0, "ctx", 0));
        std::string cafile = str_arg(E, A, 1, "cafile"), capath = str_arg(E, A, 2, "capath"), cadata = str_arg(E, A, 3, "cadata");
        if (cafile.empty() && capath.empty() && cadata.empty())
            raise_ssl("TypeError", "cafile, capath and cadata cannot be all omitted");
        a.ERR_clear_error();
        if (!cafile.empty() || !capath.empty()) {
            if (!a.SSL_CTX_load_verify_locations(c->ctx, cafile.empty() ? nullptr : cafile.c_str(), capath.empty() ? nullptr : capath.c_str())) {
                std::string q = queue_text(a);
                raise_ssl("FileNotFoundError", "[Errno 2] No such file or directory" + (q.empty() ? std::string() : " (" + q + ")"));
            }
        }
        if (!cadata.empty()) {
            void* bio = a.BIO_new_mem_buf(cadata.data(), (int)cadata.size());
            void* store = a.SSL_CTX_get_cert_store(c->ctx);
            int added = 0;
            while (void* x = a.PEM_read_bio_X509(bio, nullptr, nullptr, nullptr)) {
                a.X509_STORE_add_cert(store, x);
                a.X509_free(x);
                added++;
            }
            a.BIO_free(bio);
            a.ERR_clear_error();
            if (!added) raise_ssl("SSLError", "[SSL] no certificate in cadata");
        }
        return NONE_VALUE;
    }
    if (name == "_tls_ctx_load_cert_chain") {
        Api& a = need_api();
        auto c = get_ctx(int_arg(E, A, 0, "ctx", 0));
        std::string cert = str_arg(E, A, 1, "certfile"), key = str_arg(E, A, 2, "keyfile");
        c->password = str_arg(E, A, 3, "password");
        if (key.empty()) key = cert;
        if (!c->password.empty()) a.SSL_CTX_set_default_passwd_cb_userdata(c->ctx, (void*)c->password.c_str());
        a.ERR_clear_error();
        if (a.SSL_CTX_use_certificate_chain_file(c->ctx, cert.c_str()) != 1) {
            std::string q = queue_text(a);
            if (q.find("No such file") != std::string::npos || q.find("system lib") != std::string::npos)
                raise_ssl("FileNotFoundError", "[Errno 2] No such file or directory: '" + cert + "'");
            raise_ssl("SSLError", "[SSL] " + q);
        }
        if (a.SSL_CTX_use_PrivateKey_file(c->ctx, key.c_str(), 1) != 1)
            raise_ssl("SSLError", "[SSL] " + queue_text(a));
        if (a.SSL_CTX_check_private_key(c->ctx) != 1)
            raise_ssl("SSLError", "[SSL: KEY_VALUES_MISMATCH] key values mismatch");
        return NONE_VALUE;
    }
    if (name == "_tls_ctx_set_alpn") {
        Api& a = need_api();
        auto c = get_ctx(int_arg(E, A, 0, "ctx", 0));
        std::vector<unsigned char> wire;
        if (A.has(1, "protocols")) for (auto& p : E.iterItems(A.get(1, "protocols"), E.globalContext())) {
            std::string s = E.strOf(p, E.globalContext());
            if (s.empty() || s.size() > 255) raise_ssl("ValueError", "invalid ALPN protocol name");
            wire.push_back((unsigned char)s.size());
            wire.insert(wire.end(), s.begin(), s.end());
        }
        c->alpn = wire;
        if (c->server) a.SSL_CTX_set_alpn_select_cb(c->ctx, alpn_select, c.get());
        else if (a.SSL_CTX_set_alpn_protos(c->ctx, wire.data(), (unsigned)wire.size()) != 0)
            raise_ssl("SSLError", "[SSL] cannot set ALPN protocols");
        return NONE_VALUE;
    }
    if (name == "_tls_ctx_set_ciphers") {
        Api& a = need_api();
        auto c = get_ctx(int_arg(E, A, 0, "ctx", 0));
        std::string list = str_arg(E, A, 1, "ciphers");
        a.ERR_clear_error();
        if (a.SSL_CTX_set_cipher_list(c->ctx, list.c_str()) != 1)
            raise_ssl("SSLError", "[SSL: NO_CIPHER_MATCH] No cipher can be selected.");
        return NONE_VALUE;
    }
    if (name == "_tls_ctx_set_versions") {
        Api& a = need_api();
        auto c = get_ctx(int_arg(E, A, 0, "ctx", 0));
        int64_t lo = int_arg(E, A, 1, "minimum", -1), hi = int_arg(E, A, 2, "maximum", -1);
        if (lo >= 0) a.SSL_CTX_ctrl(c->ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, (long)lo, nullptr);
        if (hi >= 0) a.SSL_CTX_ctrl(c->ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, (long)hi, nullptr);
        return NONE_VALUE;
    }
    if (name == "_tls_wrap") {
        Api& a = need_api();
        auto s = nynet::get(int_arg(E, A, 0, "sock", 0));
        auto c = get_ctx(int_arg(E, A, 1, "ctx", 0));
        bool server_side = bool_arg(E, A, 2, "server_side", false);
        std::string host = str_arg(E, A, 3, "server_hostname");
        bool check = bool_arg(E, A, 4, "check_hostname", !server_side);
        bool do_hs = bool_arg(E, A, 5, "do_handshake", true);
        if (nynet::sock_tls(*s)) raise_ssl("ValueError", "the socket already speaks TLS");
        if (server_side && !c->server) raise_ssl("ValueError", "a client context cannot wrap a server-side socket");
        if (!server_side && c->server) raise_ssl("ValueError", "a server context cannot wrap a client socket");
        if (!server_side && check && c->verify != 0 && host.empty())
            raise_ssl("ValueError", "check_hostname requires server_hostname");
        auto* t = new TlsConn();
        t->ctx = c;
        t->server = server_side;
        t->hostname = host;
        t->ssl = a.SSL_new(c->ctx);
        if (!t->ssl) { delete t; raise_ssl("SSLError", "[SSL] " + queue_text(a)); }
        a.SSL_set_fd(t->ssl, (int)nynet::sock_fd(*s));
        if (!server_side && !host.empty()) {
            bool ip = is_ip_literal(host);
            if (!ip) a.SSL_ctrl(t->ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, (void*)host.c_str());   // SNI
            if (check && c->verify != 0) {
                if (ip) a.X509_VERIFY_PARAM_set1_ip_asc(a.SSL_get0_param(t->ssl), host.c_str());
                else a.SSL_set1_host(t->ssl, host.c_str());
            }
        }
        nynet::sock_tls(*s) = t;
        if (do_hs) {
            try { handshake(*s, t); }
            catch (...) { nynet::sock_tls(*s) = nullptr; delete t; throw; }
        }
        return NONE_VALUE;
    }
    if (name == "_tls_handshake") {
        auto s = nynet::get(int_arg(E, A, 0, "sock", 0));
        TlsConn* t = nynet::sock_tls(*s);
        if (!t) raise_ssl("ValueError", "the socket does not speak TLS");
        if (!t->handshaken) handshake(*s, t);
        return NONE_VALUE;
    }
    if (name == "_tls_unwrap") {
        Api& a = need_api();
        auto s = nynet::get(int_arg(E, A, 0, "sock", 0));
        TlsConn* t = nynet::sock_tls(*s);
        if (!t) raise_ssl("ValueError", "the socket does not speak TLS");
        a.ERR_clear_error();
        a.SSL_shutdown(t->ssl);                 // send close_notify; the peer's is not awaited
        a.ERR_clear_error();
        nynet::sock_tls(*s) = nullptr;
        delete t;
        return NONE_VALUE;
    }
    if (name == "_tls_info") {
        Api& a = need_api();
        auto s = nynet::get(int_arg(E, A, 0, "sock", 0));
        TlsConn* t = nynet::sock_tls(*s);
        Value d = E.makeDictValue();
        if (!t || !t->handshaken) return d;
        Container* dc = E.contOf(d);
        E.dictSet(dc, E.makeStringValue("version"), E.makeStringValue(a.SSL_get_version(t->ssl)));
        const void* ci = a.SSL_get_current_cipher(t->ssl);
        if (ci) {
            E.dictSet(dc, E.makeStringValue("cipher"), E.makeStringValue(a.SSL_CIPHER_get_name(ci)));
            E.dictSet(dc, E.makeStringValue("bits"), Value((int64_t)a.SSL_CIPHER_get_bits(ci, nullptr)));
        }
        const unsigned char* alpn = nullptr;
        unsigned alen = 0;
        a.SSL_get0_alpn_selected(t->ssl, &alpn, &alen);
        E.dictSet(dc, E.makeStringValue("alpn"), alpn && alen ? E.makeStringValue(std::string((const char*)alpn, alen)) : NONE_VALUE);
        E.dictSet(dc, E.makeStringValue("server_side"), Value(t->server));
        E.dictSet(dc, E.makeStringValue("server_hostname"), t->hostname.empty() ? NONE_VALUE : E.makeStringValue(t->hostname));
        return d;
    }
    if (name == "_tls_peer_cert") {
        auto s = nynet::get(int_arg(E, A, 0, "sock", 0));
        TlsConn* t = nynet::sock_tls(*s);
        if (!t || !t->handshaken) raise_ssl("ValueError", "handshake not done yet");
        return peer_cert(E, t, bool_arg(E, A, 1, "binary_form", false));
    }
    return UNDEFINED_VALUE;
}
