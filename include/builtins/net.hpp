#pragma once
// builtins/net.hpp - the socket layer (src/builtins/net.cpp) and the TLS
// layer over it (src/builtins/tls.cpp), round 77. Both reached by the VM
// through the builtin bridge.
#include "Value.hpp"
#include "Context.hpp"
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct NythonExecutor;

Value dispatch_net(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> net_builtin_names();
Value dispatch_tls(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> tls_builtin_names();

namespace nynet {

// A TLS session over a socket (tls.cpp). The socket layer routes a socket's
// send/recv through it once it is set, so every blocking rule (timeouts,
// the GIL, async tasks, signals) is the same for TLS.
struct TlsConn;
// One step: bytes moved, or -1 with *wait = the event to wait for (IO_READ /
// IO_WRITE) or 0 for a final error (*err an errno-style code, or < 0 for a
// TLS error whose text tls_error() gives).
long tls_write(TlsConn* t, const char* p, size_t n, int* wait, int* err);
long tls_read(TlsConn* t, char* p, size_t n, int* wait, int* err);
long tls_pending(TlsConn* t);          // decrypted bytes ready to read
void tls_free(TlsConn* t);

// The last TLS error's text ("[SSL: ...] reason"), for SSLError.
std::string tls_error_text(TlsConn* t);

struct Sock;
std::shared_ptr<Sock> get(int64_t handle);   // raises OSError for a closed one
[[noreturn]] void raise(const std::string& type, const std::string& msg);
[[noreturn]] void raise_err(int e);
std::string err_text(int e);

// For the TLS layer: a socket's descriptor, its TLS session slot and
// timeout, and one wait for its readiness within `left_ms` (< 0: no limit;
// false: timed out; a non-blocking socket raises BlockingIOError).
intptr_t sock_fd(const Sock& s);
TlsConn*& sock_tls(Sock& s);
double sock_timeout(const Sock& s);
bool sock_wait(Sock& s, int events, double left_ms);
void run_pending_signals();

} // namespace nynet
