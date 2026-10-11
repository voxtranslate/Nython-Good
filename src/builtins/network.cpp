#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/network.cpp
// TCP/UDP, HTTP server, LAN agents
// ─────────────────────────────────────────────────────────────────────────────

// _WIN32_WINNT must be set before ANY Windows header — including indirectly
// included ones. 0x0600 = Vista+, required for inet_pton / InetPton.
#ifdef _WIN32
#  ifndef _WIN32_WINNT
#    define _WIN32_WINNT 0x0600
#  elif _WIN32_WINNT < 0x0600
#    undef  _WIN32_WINNT
#    define _WIN32_WINNT 0x0600
#  endif
#endif

// Platform compatibility (must come first)
#include "platform_compat.hpp"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <regex>
#include <cstdlib>
#include <cmath>
#include <chrono>
#include <random>
#include <thread>
#include <mutex>
#include <functional>
#include <iomanip>
#include <string>
#include <vector>
#include <map>
#include <ctime>
#include <cwctype>
#include <locale>

// Full executor definition (needed for E.getStringValue etc.)
#include "NythonExecutor.hpp"
#include "builtins/os.hpp"

// Portable setsockopt: Windows takes (const char*), POSIX takes (const void*)
#ifdef _WIN32
#define NY_SETSOCKOPT(s, level, optname, optval, optlen) \
    setsockopt((s), (level), (optname), reinterpret_cast<const char*>(optval), (optlen))
#else
#define NY_SETSOCKOPT(s, level, optname, optval, optlen) \
    setsockopt((s), (level), (optname), (optval), (optlen))
#endif
#include "builtins/network.hpp"
#include <cstring>
// ^ explicit: libstdc++ supplies these transitively, MinGW does not.

// ── Namespace imports (match main.cpp) ────────────────────────────────────────
using namespace std;
using namespace nython;
using namespace nython::io;
using namespace nython::node;
using namespace nython::lexer;
using namespace nython::kernel;
using namespace nython::parser;
using namespace nython::reader;
using namespace nython::exception;

// ════════════════════════════════════════════════════════════════════════════════
// One HTTP/1.1 exchange for http_get / http_post / http_request /
// http_get_json / http_post_json (round 77). They used to open an IPv4
// socket with gethostbyname, send, and read to the close: no https, no
// timeout, the GIL held for the whole wait, chunked bodies returned with
// their chunk sizes, redirects not followed. Now: the socket layer
// (builtins/net.cpp: every address getaddrinfo gives, a timeout, waits that
// release the GIL and park an async task), TLS through builtins/tls.cpp with
// the system's trust store and host name checks, chunked and Content-Length
// bodies, and up to 10 redirects.
// ════════════════════════════════════════════════════════════════════════════════
namespace {
struct HttpOut {
    int status = 0;
    std::string reason, head, body, url, error;
    std::vector<std::pair<std::string, std::string>> headers;
};

std::string lower_ascii(std::string s) { for (auto& c : s) c = (char)std::tolower((unsigned char)c); return s; }

bool split_url(const std::string& url, std::string& scheme, std::string& host, int& port, std::string& target) {
    size_t p = url.find("://");
    std::string rest = url;
    scheme = "http";
    if (p != std::string::npos) { scheme = lower_ascii(url.substr(0, p)); rest = url.substr(p + 3); }
    if (scheme != "http" && scheme != "https") return false;
    size_t slash = rest.find_first_of("/?#");
    std::string auth = slash == std::string::npos ? rest : rest.substr(0, slash);
    target = slash == std::string::npos ? "/" : rest.substr(slash);
    size_t hash = target.find('#');
    if (hash != std::string::npos) target = target.substr(0, hash);
    if (target.empty() || target[0] != '/') target = "/" + target;
    size_t at = auth.rfind('@');
    if (at != std::string::npos) auth = auth.substr(at + 1);
    port = scheme == "https" ? 443 : 80;
    if (!auth.empty() && auth[0] == '[') {
        size_t e = auth.find(']');
        if (e == std::string::npos) return false;
        host = auth.substr(1, e - 1);
        if (e + 1 < auth.size() && auth[e + 1] == ':') port = std::atoi(auth.c_str() + e + 2);
    } else {
        size_t c = auth.rfind(':');
        if (c != std::string::npos) { host = auth.substr(0, c); port = std::atoi(auth.c_str() + c + 1); }
        else host = auth;
    }
    return !host.empty() && port > 0 && port < 65536;
}

std::string join_url(const std::string& base, const std::string& loc) {
    if (loc.find("://") != std::string::npos) return loc;
    size_t p = base.find("://");
    size_t path_at = base.find('/', p == std::string::npos ? 0 : p + 3);
    std::string origin = path_at == std::string::npos ? base : base.substr(0, path_at);
    if (loc.compare(0, 2, "//") == 0) return base.substr(0, p + 1) + loc;
    if (!loc.empty() && loc[0] == '/') return origin + loc;
    if (path_at == std::string::npos) return origin + "/" + loc;
    std::string path = base.substr(path_at);
    size_t q = path.find('?');
    if (q != std::string::npos) path = path.substr(0, q);
    return origin + path.substr(0, path.rfind('/') + 1) + loc;
}

HttpOut http_once(NythonExecutor& E, Context* ctx, const std::string& method, const std::string& url,
                  const std::vector<std::pair<std::string, std::string>>& extra, const std::string& body, double timeout) {
    HttpOut out;
    out.url = url;
    std::string scheme, host, target;
    int port = 0;
    if (!split_url(url, scheme, host, port, target)) { out.error = "unsupported URL: " + url; return out; }
    auto call = [&](const char* n, std::vector<Value> a) { return E.callBuiltin(n, a, ctx); };
    Value h = NONE_VALUE;
    std::string last_err = "no address";
    try {
        Value infos = call("_net_getaddrinfo", {E.makeStringValue(host), Value((int64_t)port), Value((int64_t)0), Value((int64_t)SOCK_STREAM)});
        for (auto& ai : E.listItems(infos)) {
            auto f = E.listItems(ai);
            if (f.size() < 5) continue;
            Value cand = NONE_VALUE;
            try {
                cand = call("_net_socket", {f[0], f[1], f[2]});
                call("_net_settimeout", {cand, Value(timeout)});
                call("_net_connect", {cand, f[4]});
                h = cand;
                break;
            } catch (std::string& e) {
                if (e.find("KeyboardInterrupt") != std::string::npos) throw;
                last_err = e;
                if (cand.type != ValueType::NONE) { try { call("_net_close", {cand}); } catch (...) {} }
            }
        }
    } catch (std::string& e) {
        if (e.find("KeyboardInterrupt") != std::string::npos) throw;
        last_err = e;
    }
    if (h.type == ValueType::NONE) { out.error = last_err; return out; }
    struct Closer {
        NythonExecutor& E; Context* ctx; Value h;
        ~Closer() { try { std::vector<Value> a{h}; E.callBuiltin("_net_close", a, ctx); } catch (...) {} }
    } closer{E, ctx, h};
    try {
        if (scheme == "https") {
            static int64_t tls_ctx = 0;
            if (!tls_ctx) {
                Value c = call("_tls_ctx_new", {Value(false)});
                call("_tls_ctx_default_paths", {c});
                tls_ctx = bigint_to_i64(c.value.i);
            }
            call("_tls_wrap", {h, Value(tls_ctx), Value(false), E.makeStringValue(host), Value(true), Value(true)});
        }
        std::string hosthdr = host.find(':') != std::string::npos ? "[" + host + "]" : host;
        if (port != (scheme == "https" ? 443 : 80)) hosthdr += ":" + std::to_string(port);
        std::string req = method + " " + target + " HTTP/1.1\r\nHost: " + hosthdr + "\r\n";
        bool has_ua = false, has_ct = false, has_accept = false;
        for (auto& kv : extra) {
            std::string k = lower_ascii(kv.first);
            has_ua |= k == "user-agent"; has_ct |= k == "content-type"; has_accept |= k == "accept";
        }
        if (!has_ua) req += "User-Agent: Nython/0.2.1\r\n";
        if (!has_accept) req += "Accept: */*\r\n";
        req += "Accept-Encoding: identity\r\nConnection: close\r\n";
        if (!body.empty() || method == "POST" || method == "PUT" || method == "PATCH") {
            req += "Content-Length: " + std::to_string(body.size()) + "\r\n";
            if (!has_ct && !body.empty()) req += "Content-Type: application/x-www-form-urlencoded\r\n";
        }
        for (auto& kv : extra) req += kv.first + ": " + kv.second + "\r\n";
        req += "\r\n";
        req += body;
        call("_net_sendall", {h, E.makeBytesValue(req)});
        std::string resp;
        while (true) {
            Value chunk = call("_net_recv", {h, Value((int64_t)65536)});
            auto* bo = E.bytesOf(chunk);
            if (!bo || bo->s.empty()) break;
            resp += bo->s;
        }
        size_t he = resp.find("\r\n\r\n");
        if (he == std::string::npos) { out.error = "malformed response"; out.body = resp; return out; }
        out.head = resp.substr(0, he);
        std::string raw = resp.substr(he + 4);
        size_t eol = out.head.find("\r\n");
        std::string status_line = out.head.substr(0, eol);
        size_t sp1 = status_line.find(' ');
        if (sp1 != std::string::npos) {
            out.status = std::atoi(status_line.c_str() + sp1 + 1);
            size_t sp2 = status_line.find(' ', sp1 + 1);
            if (sp2 != std::string::npos) out.reason = status_line.substr(sp2 + 1);
        }
        bool chunked = false;
        long long clen = -1;
        size_t pos = eol == std::string::npos ? out.head.size() : eol + 2;
        while (pos < out.head.size()) {
            size_t e = out.head.find("\r\n", pos);
            if (e == std::string::npos) e = out.head.size();
            std::string line = out.head.substr(pos, e - pos);
            size_t c = line.find(':');
            if (c != std::string::npos) {
                std::string k = line.substr(0, c), v = line.substr(c + 1);
                while (!v.empty() && (v[0] == ' ' || v[0] == '\t')) v.erase(0, 1);
                out.headers.push_back({k, v});
                std::string kl = lower_ascii(k);
                if (kl == "transfer-encoding" && lower_ascii(v).find("chunked") != std::string::npos) chunked = true;
                if (kl == "content-length") clen = std::atoll(v.c_str());
            }
            pos = e + 2;
        }
        if (chunked) {
            size_t i = 0;
            while (i < raw.size()) {
                size_t le = raw.find("\r\n", i);
                if (le == std::string::npos) break;
                long long n = std::strtoll(raw.substr(i, le - i).c_str(), nullptr, 16);
                if (n <= 0) break;
                out.body.append(raw, le + 2, (size_t)n);
                i = le + 2 + (size_t)n + 2;
            }
        } else if (clen >= 0 && (size_t)clen < raw.size()) {
            out.body = raw.substr(0, (size_t)clen);
        } else {
            out.body = raw;
        }
        if (method == "HEAD" || out.status == 204 || out.status == 304) out.body.clear();
    } catch (std::string& e) {
        if (e.find("KeyboardInterrupt") != std::string::npos) throw;
        out.error = e;
        out.status = 0;
    }
    return out;
}

HttpOut http_fetch(NythonExecutor& E, Context* ctx, std::string method, std::string url,
                   const std::vector<std::pair<std::string, std::string>>& extra, std::string body, double timeout) {
    HttpOut r;
    for (int hop = 0; hop <= 10; hop++) {
        r = http_once(E, ctx, method, url, extra, body, timeout);
        if (!r.error.empty()) return r;
        if (r.status != 301 && r.status != 302 && r.status != 303 && r.status != 307 && r.status != 308) return r;
        std::string loc;
        for (auto& kv : r.headers) if (lower_ascii(kv.first) == "location") loc = kv.second;
        if (loc.empty()) return r;
        url = join_url(url, loc);
        if (r.status == 303 || ((r.status == 301 || r.status == 302) && method == "POST")) {
            if (method != "HEAD") method = "GET";
            body.clear();
        }
    }
    return r;
}

// Headers given as "K: v\r\n..." text (the legacy form) or a map.
std::vector<std::pair<std::string, std::string>> header_args(NythonExecutor& E, const Value& v) {
    std::vector<std::pair<std::string, std::string>> out;
    if (v.type == ValueType::NONE || v.type == ValueType::UNDEFINED) return out;
    if (E.isStringValue(v)) {
        std::string t = E.getStringValue(v);
        size_t pos = 0;
        while (pos < t.size()) {
            size_t e = t.find('\n', pos);
            if (e == std::string::npos) e = t.size();
            std::string line = t.substr(pos, e - pos);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            size_t c = line.find(':');
            if (c != std::string::npos) {
                std::string val = line.substr(c + 1);
                while (!val.empty() && val[0] == ' ') val.erase(0, 1);
                out.push_back({line.substr(0, c), val});
            }
            pos = e + 1;
        }
        return out;
    }
    for (auto& kv : nyos::map_items(v))
        out.push_back({kv.first, E.isStringValue(kv.second) ? E.getStringValue(kv.second) : E.reprOf(kv.second)});
    return out;
}

std::string body_arg(NythonExecutor& E, const Value& v) {
    if (v.type == ValueType::NONE || v.type == ValueType::UNDEFINED) return std::string();
    if (auto* bo = E.bytesOf(v)) return bo->s;
    return E.getStringValue(v);
}

Value http_result_map(NythonExecutor& E, Runnable* runner, const HttpOut& r) {
    Object* m = new Object(runner, "map", Type::MAP);
    m->set("status", Value((int64_t)r.status));
    m->set("reason", E.makeStringValue(r.reason));
    m->set("headers", E.makeStringValue(r.head));
    Object* hm = new Object(runner, "map", Type::MAP);
    std::vector<std::pair<std::string, std::string>> joined;      // repeated fields joined with ", "
    for (auto& kv : r.headers) {
        std::string k = lower_ascii(kv.first);
        bool found = false;
        for (auto& j : joined) if (j.first == k) { j.second += ", " + kv.second; found = true; }
        if (!found) joined.push_back({k, kv.second});
    }
    for (auto& j : joined) hm->set(j.first, E.makeStringValue(j.second));
    m->set("header_map", Value((Collectable*)hm));
    m->set("body", E.makeStringValue(r.body));
    m->set("content", E.makeBytesValue(r.body));
    m->set("url", E.makeStringValue(r.url));
    m->set("error", r.error.empty() ? NONE_VALUE : E.makeStringValue(r.error));
    return Value((Collectable*)m);
}
} // namespace

// ════════════════════════════════════════════════════════════════════════════════
// dispatch_network
// ════════════════════════════════════════════════════════════════════════════════
Value dispatch_network(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx) {
    ny_platform::ensure_winsock();

    // Local aliases — identical names to original main.cpp code so the
    // extracted if-blocks compile unchanged.
    auto  makeStringValue  = [&](const std::string& s) { return E.makeStringValue(s); };
    auto  getStringValue   = [&](const Value& v)       { return E.getStringValue(v); };
    auto  isStringValue    = [&](const Value& v)       { return E.isStringValue(v); };
    auto  callBuiltin      = [&](const std::string& n, std::vector<Value>& a, Context* c)
                                { return E.callBuiltin(n, a, c); };
    auto  callFunctionValue= [&](Value fn, std::vector<Value>& a, Context* c)
                                { return E.callFunctionValue(fn, a, c); };
    auto  isTruthy         = [&](Value v) { return E.isTruthy(v); };
    auto  evalNode         = [&](node_ptr n, Context* c) { return E.evalNode(n, c); };
    auto& file_handles     = E.file_handles;
    auto& next_file_handle = E.next_file_handle;
    Runnable* runner       = E.runner;
    auto& func_names       = E.func_names;
    auto& instance_to_class= E.instance_to_class;
    auto& instance_properties = E.instance_properties;
    auto& class_by_name    = E.class_by_name;
    auto& class_parent     = E.class_parent;
    auto& super_parent_stack = E.super_parent_stack;
    auto& func_ast_nodes   = E.func_ast_nodes;
    auto& func_id_store    = E.func_id_store;
    auto& instance_store   = E.instance_store;
    auto& string_store     = E.string_store;
    auto  registerBuiltin  = [&](const std::string& n) { E.registerBuiltin(n); };
    auto  callMethod       = [&](Value inst, const std::string& mname, std::vector<Value>& a, Context* c)
                                { return E.callMethod(inst, mname, a, c); };
    auto  printValue       = [&](const Value& v, Context* c = nullptr) { E.printValue(v, c ? c : ctx); };

    // ── shape_to_size helper (used by tensor builtins) ───────────────────────
    auto shape_to_size = [&](const Value& v) -> int {
        if (v.type == ValueType::INTEGER) return (int)bigint_to_i64(v.value.i);
        if (v.type == ValueType::DOUBLE)  return (int)v.value.d;
        if (v.isCollectable()) {
            auto* c = dynamic_cast<Container*>(v.value.gc);
            if (c && c->container) {
                auto li = c->container->find("__len__");
                int len = (li != c->container->end()) ? (int)bigint_to_i64(li->second.value.i) : 0;
                if (len == 0) return 0;
                int total = 1;
                for (int k = 0; k < len; k++) {
                    auto ei = c->container->find(std::to_string(k));
                    if (ei != c->container->end()) {
                        if (ei->second.type == ValueType::INTEGER)
                            total *= (int)bigint_to_i64(ei->second.value.i);
                        else if (ei->second.type == ValueType::DOUBLE)
                            total *= (int)ei->second.value.d;
                    }
                }
                return total;
            }
        }
        return 0;
    };

// ── Extracted builtin implementations ────────────────────────────────────────
    // ── from main.cpp lines 2927–2957 ──────────────────────────────────────────
        // NYTORCH AGENT NETWORK: HTTP JSON helpers
        // =====================================================================
        if (name == "http_post_json") {
            // http_post_json(url, json_body) -> {status, body}
            if (args.size() >= 2) {
                std::string url  = getStringValue(args[0]);
                std::string body = getStringValue(args[1]);
                // Reuse http_request by composing args
                std::vector<Value> req_args = {
                    makeStringValue("POST"), makeStringValue(url),
                    makeStringValue("Content-Type: application/json\r\n"), makeStringValue(body)
                };
                return callBuiltin("http_request", req_args, ctx);
            }
            return NONE_VALUE;
        }
        if (name == "http_get_json") {
            // http_get_json(url) -> {status, body}
            if (!args.empty()) {
                std::string url = getStringValue(args[0]);
                std::vector<Value> req_args = {
                    makeStringValue("GET"), makeStringValue(url),
                    makeStringValue("Accept: application/json\r\n"), makeStringValue("")
                };
                return callBuiltin("http_request", req_args, ctx);
            }
            return NONE_VALUE;
        }
        // =====================================================================
        // NYTORCH AGENT NETWORK: UDP BROADCAST (agent-to-agent LAN communication)
        // =====================================================================
    // ── from main.cpp lines 2958–3061 ──────────────────────────────────────────
        if (name == "agent_broadcast") {
            // agent_broadcast(port, message) -> bool — UDP broadcast on LAN
#ifndef _WIN32
            if (args.size() >= 2) {
                int port = (int)bigint_to_i64(args[0].value.i);
                std::string msg = getStringValue(args[1]);
                int sock = ::socket(AF_INET, SOCK_DGRAM, 0);
                if (sock < 0) return Value(false);
                int bcast = 1;
                NY_SETSOCKOPT(sock, SOL_SOCKET, SO_BROADCAST, &bcast, sizeof(bcast));
                struct sockaddr_in addr{};
                addr.sin_family = AF_INET;
                addr.sin_port = htons((uint16_t)port);
                addr.sin_addr.s_addr = INADDR_BROADCAST;
                bool ok = sendto(sock, msg.c_str(), msg.size(), 0, (struct sockaddr*)&addr, sizeof(addr)) > 0;
                ny_close_socket(sock);
                return Value(ok);
            }
#endif
            return Value(false);
        }
        if (name == "agent_listen") {
            // agent_listen(port, timeout_ms=500) -> message_str or none — receive UDP broadcast
#ifndef _WIN32
            if (!args.empty()) {
                int port = (int)bigint_to_i64(args[0].value.i);
                int timeout_ms = (args.size() >= 2) ? (int)bigint_to_i64(args[1].value.i) : 500;
                int sock = ::socket(AF_INET, SOCK_DGRAM, 0);
                if (sock < 0) return NONE_VALUE;
                int reuse = 1;
                NY_SETSOCKOPT(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
                struct sockaddr_in addr{};
                addr.sin_family = AF_INET;
                addr.sin_port = htons((uint16_t)port);
                addr.sin_addr.s_addr = INADDR_ANY;
                if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) { ny_close_socket(sock); return NONE_VALUE; }
                struct timeval tv{0, (suseconds_t)(timeout_ms * 1000)};
                NY_SETSOCKOPT(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                std::vector<char> buf(65536);   // heap: see dispatch_io's (io.cpp)
                ssize_t n = recv(sock, buf.data(), (int)buf.size() - 1, 0);
                ny_close_socket(sock);
                if (n > 0) return makeStringValue(std::string(buf.data(), (size_t)n));
            }
#endif
            return NONE_VALUE;
        }
        if (name == "agent_send") {
            // agent_send(host, port, message) -> bool — UDP unicast to specific agent
#ifndef _WIN32
            if (args.size() >= 3) {
                std::string host = getStringValue(args[0]);
                int port = (int)bigint_to_i64(args[1].value.i);
                std::string msg  = getStringValue(args[2]);
                int sock = ::socket(AF_INET, SOCK_DGRAM, 0);
                if (sock < 0) return Value(false);
                struct sockaddr_in addr{};
                addr.sin_family = AF_INET;
                addr.sin_port = htons((uint16_t)port);
                struct hostent* he = ::gethostbyname(host.c_str());
                if (!he) { ny_close_socket(sock); return Value(false); }
                memcpy(&addr.sin_addr, he->h_addr_list[0], (size_t)he->h_length);
                bool ok = sendto(sock, msg.c_str(), msg.size(), 0, (struct sockaddr*)&addr, sizeof(addr)) > 0;
                ny_close_socket(sock);
                return Value(ok);
            }
#endif
            return Value(false);
        }
        if (name == "agent_recv") {
            // agent_recv(port, timeout_ms=1000) -> {from:str, msg:str} or none
#ifndef _WIN32
            if (!args.empty()) {
                int port = (int)bigint_to_i64(args[0].value.i);
                int timeout_ms = (args.size() >= 2) ? (int)bigint_to_i64(args[1].value.i) : 1000;
                int sock = ::socket(AF_INET, SOCK_DGRAM, 0);
                if (sock < 0) return NONE_VALUE;
                int reuse = 1;
                NY_SETSOCKOPT(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
                struct sockaddr_in addr{};
                addr.sin_family = AF_INET;
                addr.sin_port = htons((uint16_t)port);
                addr.sin_addr.s_addr = INADDR_ANY;
                if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) { ny_close_socket(sock); return NONE_VALUE; }
                struct timeval tv{0, (suseconds_t)(timeout_ms * 1000)};
                NY_SETSOCKOPT(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                std::vector<char> buf_v(65536);   // heap: see dispatch_io's (io.cpp)
                char* buf = buf_v.data();
                struct sockaddr_in sender{}; socklen_t slen = sizeof(sender);
                ssize_t n = recvfrom(sock, buf, (int)buf_v.size() - 1, 0, (struct sockaddr*)&sender, &slen);
                ny_close_socket(sock);
                if (n > 0) {
                    buf[n] = '\0';
                    auto* obj = new Object((Runnable*)runner, "map", Type::MAP);
                    obj->set("from", makeStringValue(std::string(inet_ntoa(sender.sin_addr))));
                    obj->set("msg",  makeStringValue(std::string(buf, (size_t)n)));
                    obj->set("port", Value((int)ntohs(sender.sin_port)));
                    return Value((Collectable*)obj);
                }
            }
#endif
            return NONE_VALUE;
        }
        // =====================================================================
        // NYTORCH NETWORK: TCP SOCKET PRIMITIVES (low-level + HTTP server)
        // =====================================================================
    // ── from main.cpp lines 3062–3255 ──────────────────────────────────────────
        if (name == "tcp_server_create") {
            // tcp_server_create(port, backlog=16) -> fd (int) or -1
#ifndef _WIN32
            if (!args.empty()) {
                int port = (int)bigint_to_i64(args[0].value.i);
                int backlog = (args.size() >= 2) ? (int)bigint_to_i64(args[1].value.i) : 16;
                int fd = ::socket(AF_INET, SOCK_STREAM, 0);
                if (fd < 0) return Value(-1);
                int opt = 1;
                NY_SETSOCKOPT(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
                #ifdef SO_REUSEPORT
                NY_SETSOCKOPT(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
                #endif
                struct sockaddr_in addr{};
                addr.sin_family = AF_INET;
                addr.sin_port = htons((uint16_t)port);
                addr.sin_addr.s_addr = INADDR_ANY;
                if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { ny_close_socket(fd); return Value(-1); }
                if (listen(fd, backlog) < 0) { ny_close_socket(fd); return Value(-1); }
                return Value(fd);
            }
#endif
            return Value(-1);
        }
        if (name == "tcp_accept") {
            // tcp_accept(server_fd, timeout_ms=1000) -> {fd, from} or none
#ifndef _WIN32
            if (!args.empty()) {
                int sfd = (int)bigint_to_i64(args[0].value.i);
                int timeout_ms = (args.size() >= 2) ? (int)bigint_to_i64(args[1].value.i) : 1000;
                fd_set rfds; FD_ZERO(&rfds); FD_SET(sfd, &rfds);
                struct timeval tv{timeout_ms/1000, (timeout_ms%1000)*1000};
                int sel = select(sfd+1, &rfds, nullptr, nullptr, &tv);
                if (sel <= 0) return NONE_VALUE;
                struct sockaddr_in caddr{}; socklen_t clen = sizeof(caddr);
                int cfd = accept(sfd, (struct sockaddr*)&caddr, &clen);
                if (cfd < 0) return NONE_VALUE;
                auto* obj = new Object((Runnable*)runner, "map", Type::MAP);
                obj->set("fd",   Value(cfd));
                obj->set("from", makeStringValue(std::string(inet_ntoa(caddr.sin_addr))));
                obj->set("port", Value((int)ntohs(caddr.sin_port)));
                return Value((Collectable*)obj);
            }
#endif
            return NONE_VALUE;
        }
        if (name == "tcp_connect") {
            // tcp_connect(host, port, timeout_ms=3000) -> fd or -1
#ifndef _WIN32
            if (args.size() >= 2) {
                std::string host = getStringValue(args[0]);
                int port = (int)bigint_to_i64(args[1].value.i);
                int fd = ::socket(AF_INET, SOCK_STREAM, 0);
                if (fd < 0) return Value(-1);
                struct hostent* he = ::gethostbyname(host.c_str());
                if (!he) { ny_close_socket(fd); return Value(-1); }
                struct sockaddr_in addr{};
                addr.sin_family = AF_INET;
                addr.sin_port = htons((uint16_t)port);
                memcpy(&addr.sin_addr, he->h_addr_list[0], (size_t)he->h_length);
                int timeout_ms = (args.size() >= 3) ? (int)bigint_to_i64(args[2].value.i) : 3000;
                struct timeval tv{timeout_ms/1000, (timeout_ms%1000)*1000};
                NY_SETSOCKOPT(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                NY_SETSOCKOPT(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
                if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { ny_close_socket(fd); return Value(-1); }
                return Value(fd);
            }
#endif
            return Value(-1);
        }
        if (name == "tcp_send") {
            // tcp_send(fd, data_str) -> bytes_sent
#ifndef _WIN32
            if (args.size() >= 2) {
                int fd = (int)bigint_to_i64(args[0].value.i);
                std::string data = getStringValue(args[1]);
                ssize_t sent = 0, total = 0;
                while ((size_t)total < data.size()) {
                    sent = ::send(fd, data.c_str()+total, data.size()-(size_t)total, MSG_NOSIGNAL);
                    if (sent <= 0) break;
                    total += sent;
                }
                return Value((int)total);
            }
#endif
            return Value(0);
        }
        if (name == "tcp_recv") {
            // tcp_recv(fd, max_bytes=65536, timeout_ms=2000) -> string or none
#ifndef _WIN32
            if (!args.empty()) {
                int fd = (int)bigint_to_i64(args[0].value.i);
                int max_bytes = (args.size() >= 2) ? (int)bigint_to_i64(args[1].value.i) : 65536;
                int timeout_ms = (args.size() >= 3) ? (int)bigint_to_i64(args[2].value.i) : 2000;
                struct timeval tv{timeout_ms/1000, (timeout_ms%1000)*1000};
                NY_SETSOCKOPT(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                std::string result;
                std::vector<char> buf((size_t)max_bytes);
                ssize_t n = recv(fd, buf.data(), (size_t)max_bytes, 0);
                if (n > 0) return makeStringValue(std::string(buf.data(), (size_t)n));
            }
#endif
            return NONE_VALUE;
        }
        if (name == "tcp_recv_all") {
            // tcp_recv_all(fd, timeout_ms=3000) -> full response string
#ifndef _WIN32
            if (!args.empty()) {
                int fd = (int)bigint_to_i64(args[0].value.i);
                int timeout_ms = (args.size() >= 2) ? (int)bigint_to_i64(args[1].value.i) : 3000;
                struct timeval tv{timeout_ms/1000, (timeout_ms%1000)*1000};
                NY_SETSOCKOPT(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                std::string result;
                char buf[4096];
                ssize_t n;
                while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) result.append(buf, (size_t)n);
                if (!result.empty()) return makeStringValue(result);
            }
#endif
            return NONE_VALUE;
        }
        if (name == "tcp_close") {
            // tcp_close(fd) -> bool
#ifndef _WIN32
            if (!args.empty()) {
                int fd = (int)bigint_to_i64(args[0].value.i);
                return Value(ny_close_socket(fd) == 0);
            }
#endif
            return Value(false);
        }
        if (name == "http_respond") {
            // http_respond(fd, status_code, body, content_type="text/plain") -> bool
            // Sends a complete HTTP/1.1 response and closes the connection
#ifndef _WIN32
            if (args.size() >= 3) {
                int fd = (int)bigint_to_i64(args[0].value.i);
                int status = (int)bigint_to_i64(args[1].value.i);
                std::string body = getStringValue(args[2]);
                std::string ct = (args.size() >= 4) ? getStringValue(args[3]) : "text/plain";
                std::string status_text = "OK";
                if (status == 201) status_text = "Created";
                else if (status == 204) status_text = "No Content";
                else if (status == 400) status_text = "Bad Request";
                else if (status == 404) status_text = "Not Found";
                else if (status == 500) status_text = "Internal Server Error";
                std::string resp = "HTTP/1.1 " + std::to_string(status) + " " + status_text + "\r\n";
                resp += "Content-Type: " + ct + "; charset=utf-8\r\n";
                resp += "Content-Length: " + std::to_string(body.size()) + "\r\n";
                resp += "Connection: close\r\n";
                resp += "Access-Control-Allow-Origin: *\r\n";
                resp += "\r\n" + body;
                ssize_t sent = ::send(fd, resp.c_str(), resp.size(), MSG_NOSIGNAL);
                ny_close_socket(fd);
                return Value(sent > 0);
            }
#endif
            return Value(false);
        }
        if (name == "http_parse_request") {
            // http_parse_request(raw_str) -> {method, path, headers, body, query}
            if (!args.empty()) {
                std::string raw = getStringValue(args[0]);
                auto* obj = new Object((Runnable*)runner, "map", Type::MAP);
                // First line: METHOD /path?query HTTP/1.1
                size_t nl1 = raw.find("\r\n");
                std::string first_line = (nl1 != std::string::npos) ? raw.substr(0, nl1) : raw;
                size_t sp1 = first_line.find(' ');
                size_t sp2 = first_line.find(' ', sp1+1);
                std::string method = (sp1 != std::string::npos) ? first_line.substr(0, sp1) : "GET";
                std::string full_path = (sp1 != std::string::npos && sp2 != std::string::npos) ? first_line.substr(sp1+1, sp2-sp1-1) : "/";
                // Split path and query string
                std::string path = full_path, query = "";
                size_t qpos = full_path.find('?');
                if (qpos != std::string::npos) { path = full_path.substr(0, qpos); query = full_path.substr(qpos+1); }
                // Find headers and body
                size_t header_end = raw.find("\r\n\r\n");
                std::string headers_str = (header_end != std::string::npos) ? raw.substr(nl1+2, header_end-nl1-2) : "";
                std::string body = (header_end != std::string::npos) ? raw.substr(header_end+4) : "";
                obj->set("method",  makeStringValue(method));
                obj->set("path",    makeStringValue(path));
                obj->set("query",   makeStringValue(query));
                obj->set("headers", makeStringValue(headers_str));
                obj->set("body",    makeStringValue(body));
                return Value((Collectable*)obj);
            }
            return NONE_VALUE;
        }
        if (name == "tcp_server_create" || name == "tcp_accept" || name == "tcp_connect" ||
            name == "tcp_send" || name == "tcp_recv" || name == "tcp_recv_all" || name == "tcp_close" ||
            name == "http_respond" || name == "http_parse_request") {
            return NONE_VALUE; // already handled above
        }
        // =====================================================================
        // NYTORCH AGENT I/O: FILESYSTEM UTILITIES
        // =====================================================================
    // ── from main.cpp lines 8730–9120 ──────────────────────────────────────────
        // ===================== COMPLETE NETWORK MODULE =====================
        if (name == "socket_udp" || name == "socket_create_udp") {
            int sockfd = ::socket(AF_INET, SOCK_DGRAM, 0);
            return Value(sockfd);
        }
        if (name == "socket_tcp" || name == "socket_create_tcp") {
            int sockfd = ::socket(AF_INET, SOCK_STREAM, 0);
            return Value(sockfd);
        }
        if (name == "socket_sendto") {
            // socket_sendto(sockfd, data, host, port)
            if (args.size() >= 4) {
                int sockfd = static_cast<int>(bigint_to_i64(args[0].value.i));
                std::string data = getStringValue(args[1]);
                std::string host = getStringValue(args[2]);
                int port = static_cast<int>(bigint_to_i64(args[3].value.i));
                struct sockaddr_in addr;
                memset(&addr, 0, sizeof(addr));
                addr.sin_family = AF_INET;
                addr.sin_port = htons(static_cast<uint16_t>(port));
                struct hostent* he = gethostbyname(host.c_str());
                if (he) {
                    memcpy(&addr.sin_addr, he->h_addr_list[0], static_cast<size_t>(he->h_length));
                    ssize_t sent = sendto(sockfd, data.c_str(), data.size(), 0, (struct sockaddr*)&addr, sizeof(addr));
                    return Value(static_cast<int>(sent));
                }
            }
            return Value(-1);
        }
        if (name == "socket_recvfrom") {
            // socket_recvfrom(sockfd, bufsize) -> [data, host, port]
            if (args.size() >= 1) {
                int sockfd = static_cast<int>(bigint_to_i64(args[0].value.i));
                int bufsize = (args.size() >= 2) ? static_cast<int>(bigint_to_i64(args[1].value.i)) : 4096;
                std::vector<char> buf(static_cast<size_t>(bufsize));
                struct sockaddr_in addr;
                socklen_t addrlen = sizeof(addr);
                ssize_t received = recvfrom(sockfd, buf.data(), static_cast<size_t>(bufsize), 0, (struct sockaddr*)&addr, &addrlen);
                if (received > 0) {
                    Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                    result->set("0", makeStringValue(std::string(buf.data(), static_cast<size_t>(received))));
                    result->set("1", makeStringValue(std::string(inet_ntoa(addr.sin_addr))));
                    result->set("2", Value(static_cast<int>(ntohs(addr.sin_port))));
                    result->set("__len__", Value(3));
                    return Value((Collectable*)result);
                }
            }
            return NONE_VALUE;
        }
        if (name == "socket_shutdown") {
            if (args.size() >= 1) {
                int sockfd = static_cast<int>(bigint_to_i64(args[0].value.i));
                int how = (args.size() >= 2) ? static_cast<int>(bigint_to_i64(args[1].value.i)) : SHUT_RDWR;
                return Value(shutdown(sockfd, how) == 0);
            }
            return Value(false);
        }
        if (name == "socket_setsockopt") {
            // socket_setsockopt(sockfd, option, value) - simplified
            if (args.size() >= 3) {
                int sockfd = static_cast<int>(bigint_to_i64(args[0].value.i));
                std::string opt_name = getStringValue(args[1]);
                int val = static_cast<int>(bigint_to_i64(args[2].value.i));
                int optname = SO_REUSEADDR;
                if (opt_name == "reuseaddr") optname = SO_REUSEADDR;
                else if (opt_name == "reuseport") {
                    #ifdef SO_REUSEPORT
                    optname = SO_REUSEPORT;
                    #else
                    optname = SO_REUSEADDR; // fallback
                    #endif
                }
                else if (opt_name == "keepalive") optname = SO_KEEPALIVE;
                else if (opt_name == "broadcast") optname = SO_BROADCAST;
                else if (opt_name == "rcvbuf") optname = SO_RCVBUF;
                else if (opt_name == "sndbuf") optname = SO_SNDBUF;
                return Value(NY_SETSOCKOPT(sockfd, SOL_SOCKET, optname, &val, sizeof(val)) == 0);
            }
            return Value(false);
        }
        if (name == "socket_getpeername") {
            // Returns [host, port] of connected peer
            if (args.size() >= 1) {
                int sockfd = static_cast<int>(bigint_to_i64(args[0].value.i));
                struct sockaddr_in addr;
                socklen_t addrlen = sizeof(addr);
                if (getpeername(sockfd, (struct sockaddr*)&addr, &addrlen) == 0) {
                    Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                    result->set("0", makeStringValue(std::string(inet_ntoa(addr.sin_addr))));
                    result->set("1", Value(static_cast<int>(ntohs(addr.sin_port))));
                    result->set("__len__", Value(2));
                    return Value((Collectable*)result);
                }
            }
            return NONE_VALUE;
        }
        if (name == "socket_getsockname") {
            // Returns [host, port] of this socket
            if (args.size() >= 1) {
                int sockfd = static_cast<int>(bigint_to_i64(args[0].value.i));
                struct sockaddr_in addr;
                socklen_t addrlen = sizeof(addr);
                if (getsockname(sockfd, (struct sockaddr*)&addr, &addrlen) == 0) {
                    Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                    result->set("0", makeStringValue(std::string(inet_ntoa(addr.sin_addr))));
                    result->set("1", Value(static_cast<int>(ntohs(addr.sin_port))));
                    result->set("__len__", Value(2));
                    return Value((Collectable*)result);
                }
            }
            return NONE_VALUE;
        }
        if (name == "socket_select") {
            // socket_select(read_fds, timeout_ms) -> list of ready fds
            if (args.size() >= 1 && args[0].isCollectable()) {
                auto* fds = dynamic_cast<Container*>(args[0].value.gc);
                if (fds && fds->container) {
                    auto li = fds->container->find("__len__");
                    int nfds = (li != fds->container->end()) ? static_cast<int>(bigint_to_i64(li->second.value.i)) : 0;
                    fd_set readfds;
                    FD_ZERO(&readfds);
                    int maxfd = 0;
                    for (int i = 0; i < nfds; i++) {
                        auto it = fds->container->find(std::to_string(i));
                        if (it != fds->container->end()) {
                            int fd = static_cast<int>(bigint_to_i64(it->second.value.i));
                            FD_SET(fd, &readfds);
                            if (fd > maxfd) maxfd = fd;
                        }
                    }
                    struct timeval tv;
                    int timeout_ms = (args.size() >= 2) ? static_cast<int>(bigint_to_i64(args[1].value.i)) : 1000;
                    tv.tv_sec = timeout_ms / 1000;
                    tv.tv_usec = (timeout_ms % 1000) * 1000;
                    int ready = select(maxfd + 1, &readfds, nullptr, nullptr, &tv);
                    Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                    int idx = 0;
                    if (ready > 0) {
                        for (int i = 0; i < nfds; i++) {
                            auto it = fds->container->find(std::to_string(i));
                            if (it != fds->container->end()) {
                                int fd = static_cast<int>(bigint_to_i64(it->second.value.i));
                                if (FD_ISSET(fd, &readfds))
                                    result->set(std::to_string(idx++), Value(fd));
                            }
                        }
                    }
                    result->set("__len__", Value(idx));
                    return Value((Collectable*)result);
                }
            }
            return NONE_VALUE;
        }
        if (name == "gethostbyname" || name == "dns_resolve") {
            if (args.size() >= 1) {
                std::string hostname = getStringValue(args[0]);
                struct hostent* he = ::gethostbyname(hostname.c_str());
                if (he && he->h_addr_list[0]) {
                    struct in_addr addr;
                    memcpy(&addr, he->h_addr_list[0], static_cast<size_t>(he->h_length));
                    return makeStringValue(std::string(inet_ntoa(addr)));
                }
            }
            return NONE_VALUE;
        }
        if (name == "inet_ntoa" || name == "ip_to_string") {
            if (args.size() >= 1) {
                uint32_t ip = static_cast<uint32_t>(bigint_to_i64(args[0].value.i));
                struct in_addr addr;
                addr.s_addr = htonl(ip);
                return makeStringValue(std::string(inet_ntoa(addr)));
            }
            return NONE_VALUE;
        }
        if (name == "inet_aton" || name == "string_to_ip") {
            if (args.size() >= 1) {
                std::string ip = getStringValue(args[0]);
                struct in_addr addr = {};
                // ny_inet_pton is defined in platform_compat.hpp — works on all
                // platforms and MinGW versions with no OS version dependency.
                if (ny_inet_pton(AF_INET, ip.c_str(), &addr) == 1)
                    return Value(static_cast<int>(ntohl(addr.s_addr)));
            }
            return Value(0);
        }
        if (name == "htons" || name == "ntohs" || name == "htonl" || name == "ntohl") {
            if (args.size() >= 1) {
                uint32_t v = static_cast<uint32_t>(bigint_to_i64(args[0].value.i));
                if (name == "htons") return Value(static_cast<int>(htons(static_cast<uint16_t>(v))));
                if (name == "ntohs") return Value(static_cast<int>(ntohs(static_cast<uint16_t>(v))));
                if (name == "htonl") return Value(static_cast<int>(htonl(v)));
                if (name == "ntohl") return Value(static_cast<int>(ntohl(v)));
            }
            return Value(0);
        }
        if (name == "http_request") {
            // http_request(method, url, headers="" | {..}, body="", timeout=30)
            //   -> {status, reason, headers (text), header_map, body, content,
            //       url (after redirects), error}; none when it cannot connect.
            if (args.size() < 2) return NONE_VALUE;
            std::string method = getStringValue(args[0]);
            for (auto& c : method) c = (char)std::toupper((unsigned char)c);
            Value hv = args.size() > 2 ? args[2] : NONE_VALUE;
            Value bv = args.size() > 3 ? args[3] : NONE_VALUE;
            double timeout = 30.0;
            if (args.size() > 4) { Value t = args[4]; if (t.type == ValueType::DOUBLE) timeout = (double)t.value.d; else if (t.type == ValueType::INTEGER) timeout = (double)bigint_to_i64(t.value.i); }
            HttpOut r = http_fetch(E, ctx, method, getStringValue(args[1]), header_args(E, hv), body_arg(E, bv), timeout);
            if (!r.error.empty() && r.head.empty()) return NONE_VALUE;
            return http_result_map(E, runner, r);
        }
        if (name == "socket_create") {
            int sockfd = ::socket(AF_INET, SOCK_STREAM, 0);
            return Value(sockfd);
        }
        if (name == "socket_connect") {
            if (args.size() >= 3) {
                int sockfd = (int)bigint_to_i64(args[0].value.i);
                std::string host = getStringValue(args[1]);
                int port = (int)bigint_to_i64(args[2].value.i);
                struct sockaddr_in addr;
                addr.sin_family = AF_INET;
                addr.sin_port = htons(static_cast<uint16_t>(port));
                struct hostent* he = gethostbyname(host.c_str());
                if (he) {
                    memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);
                    return Value(connect(sockfd, (struct sockaddr*)&addr, sizeof(addr)) == 0);
                }
            }
            return Value(false);
        }
        if (name == "socket_send") {
            if (args.size() >= 2) {
                int sockfd = (int)bigint_to_i64(args[0].value.i);
                std::string data = getStringValue(args[1]);
                ssize_t sent = send(sockfd, data.c_str(), data.size(), 0);
                return Value((int)sent);
            }
            return Value(-1);
        }
        if (name == "socket_recv") {
            if (args.size() >= 1) {
                int sockfd = (int)bigint_to_i64(args[0].value.i);
                int bufsize = (args.size() >= 2) ? (int)bigint_to_i64(args[1].value.i) : 4096;
                std::vector<char> buf(bufsize);
                ssize_t received = recv(sockfd, buf.data(), bufsize, 0);
                if (received > 0) return makeStringValue(std::string(buf.data(), received));
            }
            return makeStringValue("");
        }
        if (name == "socket_close") {
            if (args.size() >= 1) ny_close_socket((int)bigint_to_i64(args[0].value.i));
            return NONE_VALUE;
        }
        if (name == "socket_bind") {
            if (args.size() >= 2) {
                int sockfd = (int)bigint_to_i64(args[0].value.i);
                int port = (int)bigint_to_i64(args[1].value.i);
                struct sockaddr_in addr;
                addr.sin_family = AF_INET;
                addr.sin_addr.s_addr = INADDR_ANY;
                addr.sin_port = htons(static_cast<uint16_t>(port));
                int opt = 1;
#ifdef _WIN32
                // Windows' SO_REUSEADDR lets a second socket bind a port that
                // is in use - both then get connections - where POSIX's only
                // allows rebinding past TIME_WAIT. Windows' default already
                // allows the latter, so it is left alone there, as Python's
                // socket.create_server does: a second listener gets a bind
                // error, as on Linux (a program can still ask for "reuseaddr").
                (void)opt;
#else
                NY_SETSOCKOPT(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif
                return Value(bind(sockfd, (struct sockaddr*)&addr, sizeof(addr)) == 0);
            }
            return Value(false);
        }
        if (name == "socket_listen") {
            if (args.size() >= 1) {
                int sockfd = (int)bigint_to_i64(args[0].value.i);
                int backlog = (args.size() >= 2) ? (int)bigint_to_i64(args[1].value.i) : 5;
                return Value(listen(sockfd, backlog) == 0);
            }
            return Value(false);
        }
        if (name == "socket_accept") {
            if (args.size() >= 1) {
                int sockfd = (int)bigint_to_i64(args[0].value.i);
                struct sockaddr_in addr;
                socklen_t addrlen = sizeof(addr);
                int client = accept(sockfd, (struct sockaddr*)&addr, &addrlen);
                return Value(client);
            }
            return Value(-1);
        }
        if (name == "http_get" || name == "http_post") {
            // http_get(url, headers=none, timeout=30) / http_post(url, body,
            // headers=none, timeout=30) -> the body text ("" when it fails).
            if (args.empty()) return makeStringValue("");
            std::string url = getStringValue(args[0]);
            Value hv = NONE_VALUE, bv = NONE_VALUE;
            double timeout = 30.0;
            auto num = [&](const Value& t) { return t.type == ValueType::DOUBLE ? (double)t.value.d : t.type == ValueType::INTEGER ? (double)bigint_to_i64(t.value.i) : 30.0; };
            if (name == "http_post") {
                if (args.size() > 1) bv = args[1];
                if (args.size() > 2) hv = args[2];
                if (args.size() > 3) timeout = num(args[3]);
            } else {
                if (args.size() > 1) hv = args[1];
                if (args.size() > 2) timeout = num(args[2]);
            }
            HttpOut r = http_fetch(E, ctx, name == "http_post" ? "POST" : "GET", url, header_args(E, hv), body_arg(E, bv), timeout);
            return makeStringValue(r.body);
        }

        // ===================== COLLECTIONS MODULE =====================

    return UNDEFINED_VALUE;  // not handled by this module
}

#pragma GCC diagnostic pop
