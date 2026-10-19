// ffi.cpp - the native half of ctypes (round 83): shared libraries, raw
// memory, foreign calls and C-callable callbacks, for lib/ctypes/.
//
// The builtins are served by the concurrency runtime's dispatcher
// (nyconc::register_extension), so both engines get them and a callback can
// call back into either engine (Engine::call) with the GIL re-taken.
//
// Foreign calls go through libffi, loaded at run time as tls.cpp loads
// OpenSSL (libffi.so.8/.7, libffi.dylib, libffi-8.dll ...): any signature,
// structs by value, variadic functions, closures. Without libffi a built-in
// caller covers what the platform's register conventions allow without
// generated code (Nython's own fallback, not in CPython):
//   - x86-64 System V and AArch64 (Linux): integer-class and float-class
//     arguments travel in separate register files in order, the excess on the
//     stack in order - so one fixed prototype (8 integer words, 8 doubles, 8
//     stack words) calls any function of scalar arguments, variadic ones too
//     (x86-64: %al is set by a variadic prototype); callbacks are trampolines
//     from a fixed pool that read every register;
//   - Windows x64: positional registers - one prototype per int/float mask
//     of the first four arguments, the rest as stack words; callbacks take
//     integer/pointer arguments only;
//   - 32-bit x86: every argument a stack word (cdecl; stdcall by word count).
// Structs by value and long double need libffi (an error says so).
//
//   _ffi_dlopen(path|None, mode) -> handle      _ffi_dlsym(h, name) -> addr
//   _ffi_dlclose(h)                             _ffi_typeinfo() -> [[code, size, align]...]
//   _ffi_alloc(n) / _ffi_free(a) / _ffi_realloc(a, n)
//   _ffi_get(a, code) / _ffi_set(a, code, v)    _ffi_getbits / _ffi_setbits
//   _ffi_read(a, n) -> bytes / _ffi_write(a, bytes) / _ffi_memmove / _ffi_memset
//   _ffi_strlen(a) / _ffi_wcslen(a) / _ffi_wencode(str) / _ffi_wdecode(bytes)
//   _ffi_call(fn, flags, nfixed, rtype, [atypes], [args])
//   _ffi_callback(fn, flags, rtype, [atypes]) -> [code_addr, id] / _ffi_callback_free(id)
//   _ffi_errno(set?, v) / _ffi_last_error(set?, v) / _ffi_backend()
//
// Type codes (as struct's/CPython's _type_): b B h H i I l L q Q n N f d g ?
// c u P z Z t (time_t) v (void); a struct by value is "{...}" of codes, an
// array inside it "[N<code>]".
#include "NyConc.hpp"
#include <cstdint>
#include <cstring>
#include <cerrno>
#include <cwchar>
#include <ctime>
#include <string>
#include <vector>
#include <deque>
#include <memory>
#include <mutex>
#include <cstdlib>
#include <cstdio>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {
using namespace nyconc;

[[noreturn]] void raise(const std::string& type, const std::string& msg) { throw NyError::make(type, msg); }

// ── dynamic loading ─────────────────────────────────────────────────────────
#ifdef _WIN32
std::string last_error_text() {
    DWORD e = GetLastError();
    char buf[512] = {0};
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, e, 0, buf, sizeof buf, nullptr);
    std::string s = buf;
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) s.pop_back();
    return "[WinError " + std::to_string((unsigned long)e) + "] " + s;
}
void* dl_open(const char* path) {
    if (!path) return (void*)GetModuleHandleA(nullptr);
    return (void*)LoadLibraryA(path);
}
void* dl_sym(void* h, const char* name) { return (void*)GetProcAddress((HMODULE)h, name); }
#else
std::string last_error_text() { const char* e = dlerror(); return e ? e : "unknown error"; }
void* dl_open(const char* path, int mode) { return dlopen(path, mode); }
void* dl_sym(void* h, const char* name) { dlerror(); return dlsym(h, name); }
#endif

// ── type codes ──────────────────────────────────────────────────────────────
struct TI { char code; size_t size, align; };
const std::vector<TI>& typeinfo() {
    static const std::vector<TI> t = {
        {'b', sizeof(signed char), alignof(signed char)}, {'B', sizeof(unsigned char), alignof(unsigned char)},
        {'h', sizeof(short), alignof(short)}, {'H', sizeof(unsigned short), alignof(unsigned short)},
        {'i', sizeof(int), alignof(int)}, {'I', sizeof(unsigned), alignof(unsigned)},
        {'l', sizeof(long), alignof(long)}, {'L', sizeof(unsigned long), alignof(unsigned long)},
        {'q', sizeof(long long), alignof(long long)}, {'Q', sizeof(unsigned long long), alignof(unsigned long long)},
        {'n', sizeof(ptrdiff_t), alignof(ptrdiff_t)}, {'N', sizeof(size_t), alignof(size_t)},
        {'f', sizeof(float), alignof(float)}, {'d', sizeof(double), alignof(double)},
        {'g', sizeof(long double), alignof(long double)}, {'?', sizeof(bool), alignof(bool)},
        {'c', sizeof(char), alignof(char)}, {'u', sizeof(wchar_t), alignof(wchar_t)},
        {'P', sizeof(void*), alignof(void*)}, {'z', sizeof(char*), alignof(char*)},
        {'Z', sizeof(wchar_t*), alignof(wchar_t*)}, {'t', sizeof(time_t), alignof(time_t)},
    };
    return t;
}
const TI* type_of(char c) {
    for (auto& t : typeinfo()) if (t.code == c) return &t;
    return nullptr;
}
bool is_signed_int(char c) { return c == 'b' || c == 'h' || c == 'i' || c == 'l' || c == 'q' || c == 'n' || c == 't'; }
bool is_float(char c) { return c == 'f' || c == 'd' || c == 'g'; }

// An integer of `size` bytes at p, sign- or zero-extended.
int64_t load_int(const void* p, size_t size, bool sign) {
    switch (size) {
        case 1: return sign ? (int64_t)*(const int8_t*)p : (int64_t)*(const uint8_t*)p;
        case 2: { int16_t s; uint16_t u; std::memcpy(&s, p, 2); std::memcpy(&u, p, 2); return sign ? (int64_t)s : (int64_t)u; }
        case 4: { int32_t s; uint32_t u; std::memcpy(&s, p, 4); std::memcpy(&u, p, 4); return sign ? (int64_t)s : (int64_t)u; }
        default: { int64_t v; std::memcpy(&v, p, 8); return v; }
    }
}
void store_int(void* p, size_t size, int64_t v) {
    switch (size) {
        case 1: { uint8_t x = (uint8_t)v; std::memcpy(p, &x, 1); break; }
        case 2: { uint16_t x = (uint16_t)v; std::memcpy(p, &x, 2); break; }
        case 4: { uint32_t x = (uint32_t)v; std::memcpy(p, &x, 4); break; }
        default: std::memcpy(p, &v, 8); break;
    }
}
// An unsigned 64-bit value: an int when it fits, else its decimal text (the
// library makes it an int; Args/Ret carry int64 only).
Ret uret(uint64_t u) {
    if (u <= (uint64_t)INT64_MAX) return Ret::integer((int64_t)u);
    return Ret::str(std::to_string(u));
}

// wchar_t text <-> UTF-8 (UTF-32 where wchar_t is 4 bytes, UTF-16 on Windows).
std::string w_to_utf8(const wchar_t* w, size_t n) {
    std::string out;
    for (size_t i = 0; i < n; i++) {
        uint32_t c = (uint32_t)w[i];
        if (sizeof(wchar_t) == 2 && c >= 0xD800 && c < 0xDC00 && i + 1 < n) {
            uint32_t d = (uint32_t)w[i + 1];
            if (d >= 0xDC00 && d < 0xE000) { c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00); i++; }
        }
        if (c < 0x80) out += (char)c;
        else if (c < 0x800) { out += (char)(0xC0 | (c >> 6)); out += (char)(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { out += (char)(0xE0 | (c >> 12)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
        else { out += (char)(0xF0 | (c >> 18)); out += (char)(0x80 | ((c >> 12) & 0x3F)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
    }
    return out;
}
std::wstring utf8_to_w(const std::string& s) {
    std::wstring out;
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        uint32_t cp; int extra;
        if (c < 0x80) { cp = c; extra = 0; }
        else if ((c >> 5) == 6) { cp = c & 0x1F; extra = 1; }
        else if ((c >> 4) == 14) { cp = c & 0x0F; extra = 2; }
        else { cp = c & 0x07; extra = 3; }
        i++;
        for (int k = 0; k < extra && i < s.size(); k++, i++) cp = (cp << 6) | ((unsigned char)s[i] & 0x3F);
        if (sizeof(wchar_t) == 2 && cp >= 0x10000) {
            cp -= 0x10000;
            out += (wchar_t)(0xD800 + (cp >> 10));
            out += (wchar_t)(0xDC00 + (cp & 0x3FF));
        } else out += (wchar_t)cp;
    }
    return out;
}

void* addr_arg(const Args& a, size_t i) { return (void*)(intptr_t)a.as_int(i); }
void* checked_addr(const Args& a, size_t i, const char* fn) {
    void* p = addr_arg(a, i);
    if (!p) raise("ValueError", std::string(fn) + ": NULL pointer access");
    return p;
}

// One value of type `code` at p, as a Ret.
Ret load(const void* p, char code) {
    const TI* t = type_of(code);
    if (!t) raise("TypeError", std::string("ctypes: unknown type code '") + code + "'");
    switch (code) {
        case 'f': { float f; std::memcpy(&f, p, sizeof f); return Ret::number(f); }
        case 'd': { double d; std::memcpy(&d, p, sizeof d); return Ret::number(d); }
        case 'g': { long double d; std::memcpy(&d, p, sizeof d); return Ret::number((double)d); }
        case '?': return Ret::boolean(*(const unsigned char*)p != 0);
        case 'c': return Ret::bytes(std::string((const char*)p, 1));
        case 'u': { wchar_t w; std::memcpy(&w, p, sizeof w); return Ret::str(w_to_utf8(&w, 1)); }
        case 'z': {
            const char* s; std::memcpy(&s, p, sizeof s);
            if (!s) return Ret::none();
            return Ret::bytes(std::string(s));
        }
        case 'Z': {
            const wchar_t* s; std::memcpy(&s, p, sizeof s);
            if (!s) return Ret::none();
            return Ret::str(w_to_utf8(s, std::wcslen(s)));
        }
        case 'P': {
            uintptr_t v; std::memcpy(&v, p, sizeof v);
            if (!v) return Ret::none();
            return uret((uint64_t)v);
        }
        default:
            if (is_signed_int(code)) return Ret::integer(load_int(p, t->size, true));
            return uret((uint64_t)load_int(p, t->size, false) & (t->size >= 8 ? ~0ULL : ((1ULL << (t->size * 8)) - 1)));
    }
}
// Store argument i of `a` (an int/float/bool/bytes/str per code) at p.
void store(void* p, char code, const Args& a, size_t i) {
    const TI* t = type_of(code);
    if (!t) raise("TypeError", std::string("ctypes: unknown type code '") + code + "'");
    switch (code) {
        case 'f': { float f = (float)a.as_num(i); std::memcpy(p, &f, sizeof f); return; }
        case 'd': { double d = a.as_num(i); std::memcpy(p, &d, sizeof d); return; }
        case 'g': { long double d = a.as_num(i); std::memcpy(p, &d, sizeof d); return; }
        case '?': { unsigned char b = a.truthy(i) ? 1 : 0; std::memcpy(p, &b, 1); return; }
        case 'c': {
            std::string s = a.is_bytes(i) ? a.as_bytes(i) : std::string(1, (char)a.as_int(i));
            char c = s.empty() ? 0 : s[0];
            std::memcpy(p, &c, 1);
            return;
        }
        case 'u': {
            std::wstring w = a.is_string(i) ? utf8_to_w(a.as_str(i)) : std::wstring(1, (wchar_t)a.as_int(i));
            wchar_t c = w.empty() ? 0 : w[0];
            std::memcpy(p, &c, sizeof c);
            return;
        }
        default: store_int(p, t->size, a.is_none(i) ? 0 : a.as_int(i)); return;
    }
}

// ── errno / GetLastError kept per thread, swapped around calls ─────────────
thread_local int t_errno = 0;
#ifdef _WIN32
thread_local DWORD t_last_error = 0;
#endif

// ── libffi, loaded at run time ──────────────────────────────────────────────
struct FfiType { size_t size; unsigned short alignment; unsigned short type; FfiType** elements; };
enum { FT_VOID = 0, FT_INT = 1, FT_FLOAT = 2, FT_DOUBLE = 3, FT_LONGDOUBLE = 4, FT_UINT8 = 5, FT_SINT8 = 6,
       FT_UINT16 = 7, FT_SINT16 = 8, FT_UINT32 = 9, FT_SINT32 = 10, FT_UINT64 = 11, FT_SINT64 = 12,
       FT_STRUCT = 13, FT_POINTER = 14 };
// FFI_DEFAULT_ABI and the Windows x86 ABIs, per platform (libffi >= 3.3)
#if defined(__x86_64__) || defined(_M_X64)
#  if defined(_WIN32)
const int ABI_DEFAULT = 1, ABI_STDCALL = 1;          // FFI_WIN64 (MSVC numbering) / GNUW64 = 2
#  else
const int ABI_DEFAULT = 2, ABI_STDCALL = 2;          // FFI_UNIX64
#  endif
#elif (defined(__i386__) || defined(_M_IX86)) && defined(_WIN32)
const int ABI_DEFAULT = 5, ABI_STDCALL = 2;          // FFI_MS_CDECL, FFI_STDCALL (X86_WIN32 numbering)
#elif defined(__i386__) || defined(_M_IX86)
const int ABI_DEFAULT = 1, ABI_STDCALL = 5;          // FFI_SYSV, FFI_STDCALL
#else
const int ABI_DEFAULT = 1, ABI_STDCALL = 1;          // FFI_SYSV (AArch64, ARM, ...)
#endif

struct Ffi {
    bool tried = false, ok = false;
    std::string why;
    int (*prep_cif)(void*, int, unsigned, FfiType*, FfiType**) = nullptr;
    int (*prep_cif_var)(void*, int, unsigned, unsigned, FfiType*, FfiType**) = nullptr;
    void (*call)(void*, void (*)(), void*, void**) = nullptr;
    void* (*closure_alloc)(size_t, void**) = nullptr;
    void (*closure_free)(void*) = nullptr;
    int (*prep_closure_loc)(void*, void*, void (*)(void*, void*, void**, void*), void*, void*) = nullptr;
    FfiType* t[15] = {nullptr};
    int abi_default = ABI_DEFAULT;
};
Ffi& ffi() {
    static Ffi f;
    if (f.tried) return f;
    f.tried = true;
    if (const char* off = std::getenv("NY_FFI_NO_LIBFFI")) if (*off && *off != '0') { f.why = "NY_FFI_NO_LIBFFI is set"; return f; }
#ifdef _WIN32
    const char* names[] = {"libffi-8.dll", "libffi-7.dll", "ffi-8.dll", "ffi-7.dll", "libffi.dll", "ffi.dll"};
#elif defined(__APPLE__)
    const char* names[] = {"libffi.8.dylib", "libffi.dylib", "/usr/lib/libffi.dylib", "/opt/homebrew/opt/libffi/lib/libffi.dylib", "/usr/local/opt/libffi/lib/libffi.dylib"};
#else
    const char* names[] = {"libffi.so.8", "libffi.so.7", "libffi.so.6", "libffi.so"};
#endif
    void* h = nullptr;
    for (const char* n : names) {
#ifdef _WIN32
        h = dl_open(n);
#else
        h = dl_open(n, RTLD_NOW | RTLD_LOCAL);
#endif
        if (h) break;
    }
    if (!h) { f.why = "libffi was not found"; return f; }
    auto sym = [&](const char* n) { return dl_sym(h, n); };
    f.prep_cif = (decltype(f.prep_cif))sym("ffi_prep_cif");
    f.prep_cif_var = (decltype(f.prep_cif_var))sym("ffi_prep_cif_var");
    f.call = (decltype(f.call))sym("ffi_call");
    f.closure_alloc = (decltype(f.closure_alloc))sym("ffi_closure_alloc");
    f.closure_free = (decltype(f.closure_free))sym("ffi_closure_free");
    f.prep_closure_loc = (decltype(f.prep_closure_loc))sym("ffi_prep_closure_loc");
    const char* tn[15] = {"ffi_type_void", nullptr, "ffi_type_float", "ffi_type_double", "ffi_type_longdouble",
                          "ffi_type_uint8", "ffi_type_sint8", "ffi_type_uint16", "ffi_type_sint16",
                          "ffi_type_uint32", "ffi_type_sint32", "ffi_type_uint64", "ffi_type_sint64",
                          nullptr, "ffi_type_pointer"};
    for (int k = 0; k < 15; k++) if (tn[k]) f.t[k] = (FfiType*)sym(tn[k]);
    if (!f.prep_cif || !f.call || !f.t[FT_SINT32] || !f.t[FT_POINTER] || !f.t[FT_DOUBLE]) { f.why = "libffi lacks ffi_prep_cif/ffi_call"; return f; }
#if defined(_WIN32) && (defined(__x86_64__) || defined(_M_X64)) && defined(__GNUC__)
    // a MinGW-built libffi defaults to FFI_GNUW64 (2); both lay arguments
    // out alike except for long double, which a GNU build wants
    f.abi_default = 2;
#endif
    f.ok = true;
    return f;
}

// Element type of a code for libffi.
FfiType* ffi_scalar(char c) {
    Ffi& f = ffi();
    const TI* t = type_of(c);
    auto sized = [&](size_t n, bool s) -> FfiType* {
        switch (n) {
            case 1: return f.t[s ? FT_SINT8 : FT_UINT8];
            case 2: return f.t[s ? FT_SINT16 : FT_UINT16];
            case 4: return f.t[s ? FT_SINT32 : FT_UINT32];
            default: return f.t[s ? FT_SINT64 : FT_UINT64];
        }
    };
    switch (c) {
        case 'v': return f.t[FT_VOID];
        case 'f': return f.t[FT_FLOAT];
        case 'd': return f.t[FT_DOUBLE];
        case 'g': return f.t[FT_LONGDOUBLE];
        case 'P': case 'z': case 'Z': return f.t[FT_POINTER];
        case 'c': return f.t[FT_SINT8];
        case 'u': return sized(sizeof(wchar_t), sizeof(wchar_t) == 4);
        case '?': return f.t[FT_UINT8];
        default:
            if (!t) raise("TypeError", std::string("ctypes: unknown type code '") + c + "'");
            return sized(t->size, is_signed_int(c));
    }
}

// A type spec ("i", "{id[4c]}") parsed into libffi types; the structures
// live as long as the Spec.
struct Spec {
    std::deque<FfiType> structs;
    std::deque<std::vector<FfiType*>> elems;
    FfiType* parse(const std::string& s, size_t& i) {
        if (i >= s.size()) raise("TypeError", "ctypes: bad type spec '" + s + "'");
        char c = s[i++];
        if (c != '{') return ffi_scalar(c);
        elems.emplace_back();
        auto& el = elems.back();
        while (i < s.size() && s[i] != '}') {
            if (s[i] == '[') {
                // an array member: its element n times (libffi has no arrays)
                i++;
                size_t n = 0;
                while (i < s.size() && s[i] >= '0' && s[i] <= '9') n = n * 10 + (size_t)(s[i++] - '0');
                FfiType* e = parse(s, i);
                for (size_t k = 0; k < n; k++) el.push_back(e);
                if (i < s.size() && s[i] == ']') i++;
            } else el.push_back(parse(s, i));
        }
        if (i < s.size()) i++;   // '}'
        el.push_back(nullptr);
        structs.push_back(FfiType{0, 0, FT_STRUCT, el.data()});
        return &structs.back();
    }
    FfiType* of(const std::string& s) { size_t i = 0; return parse(s, i); }
};
// The C size of a spec (struct layout as the C compiler lays it out).
void spec_layout(const std::string& s, size_t& i, size_t& size, size_t& align) {
    char c = s[i++];
    if (c != '{') {
        const TI* t = type_of(c);
        if (!t) raise("TypeError", std::string("ctypes: unknown type code '") + c + "'");
        size = t->size; align = t->align;
        return;
    }
    size_t off = 0, al = 1;
    while (i < s.size() && s[i] != '}') {
        size_t n = 1;
        bool arr = false;
        if (s[i] == '[') {
            arr = true; i++; n = 0;
            while (i < s.size() && s[i] >= '0' && s[i] <= '9') n = n * 10 + (size_t)(s[i++] - '0');
        }
        size_t es, ea;
        spec_layout(s, i, es, ea);
        if (arr && i < s.size() && s[i] == ']') i++;
        off = (off + ea - 1) / ea * ea + es * n;
        if (ea > al) al = ea;
    }
    if (i < s.size()) i++;
    size = (off + al - 1) / al * al;
    align = al;
}
size_t spec_size(const std::string& s) { size_t i = 0, sz, al; spec_layout(s, i, sz, al); return sz; }

// ── the built-in caller (no libffi) ─────────────────────────────────────────
using W = uint64_t;   // a register/stack word's bits
#if (defined(__x86_64__) && !defined(_WIN32)) || (defined(__aarch64__) && !defined(__APPLE__))
#  define NY_FFI_SPLIT_REGS 1
#  if defined(__x86_64__)
const int N_IREG = 6;
#  else
const int N_IREG = 8;
#  endif
const int N_FREG = 8, N_STACK = 8;
// Integer-class and float-class arguments fill their own registers in
// order; the excess goes on the stack in argument order (SysV x86-64 §3.2.3,
// AAPCS64 §6.8). A variadic prototype makes x86-64 set %al.
// round 84: 16 stack words for calls (structures passed in memory take
// several); the callback trampolines still read N_STACK
const int N_STACK_CALL = 16;
template <class R>
R split_call(void* fn, const W* ir, const double* fr, const W* st) {
#  if defined(__x86_64__)
    using F = R (*)(...);
    return ((F)fn)(ir[0], ir[1], ir[2], ir[3], ir[4], ir[5], fr[0], fr[1], fr[2], fr[3], fr[4], fr[5], fr[6], fr[7],
                   st[0], st[1], st[2], st[3], st[4], st[5], st[6], st[7], st[8], st[9], st[10], st[11], st[12], st[13], st[14], st[15]);
#  else
    using F = R (*)(W, W, W, W, W, W, W, W, double, double, double, double, double, double, double, double,
                    W, W, W, W, W, W, W, W, W, W, W, W, W, W, W, W);
    return ((F)fn)(ir[0], ir[1], ir[2], ir[3], ir[4], ir[5], ir[6], ir[7], fr[0], fr[1], fr[2], fr[3], fr[4], fr[5], fr[6], fr[7],
                   st[0], st[1], st[2], st[3], st[4], st[5], st[6], st[7], st[8], st[9], st[10], st[11], st[12], st[13], st[14], st[15]);
#  endif
}
// Result types the compiler returns as the ABIs return small structures:
// two eightbytes in RAX:RDX / XMM0:XMM1 / mixed (SysV), x0:x1 (AAPCS64), and
// blobs larger than 16 bytes, which every ABI returns through a hidden
// pointer the compiler passes itself (x8 on AArch64).
struct RII { W a, b; };
struct RDD { double a, b; };
struct RID { W a; double b; };
struct RDI { double a; W b; };
template <int N> struct RBlob { W w[N]; };
#elif defined(_WIN32) && (defined(__x86_64__) || defined(_M_X64))
#  define NY_FFI_WIN64 1
const int N_POS = 16;
// Windows x64: argument k < 4 in RCX/RDX/R8/R9 or XMM0-3 by its type; a
// variadic prototype also copies a double into the integer register, which
// variadic callees read. The rest are stack words. One instantiation per
// int/float mask of the first four.
template <class R, int M>
R win64_call(void* fn, const W* w) {
    using F = R (*)(...);
    auto a = [&](int k) { double d; std::memcpy(&d, &w[k], 8); return d; };
    if constexpr ((M & 15) == 0) return ((F)fn)(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
    else {
        // each of the first four as a double where the mask says so
        double d0 = a(0), d1 = a(1), d2 = a(2), d3 = a(3);
        W i0 = w[0], i1 = w[1], i2 = w[2], i3 = w[3];
        if constexpr (M == 1) return ((F)fn)(d0, i1, i2, i3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 2) return ((F)fn)(i0, d1, i2, i3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 3) return ((F)fn)(d0, d1, i2, i3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 4) return ((F)fn)(i0, i1, d2, i3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 5) return ((F)fn)(d0, i1, d2, i3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 6) return ((F)fn)(i0, d1, d2, i3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 7) return ((F)fn)(d0, d1, d2, i3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 8) return ((F)fn)(i0, i1, i2, d3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 9) return ((F)fn)(d0, i1, i2, d3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 10) return ((F)fn)(i0, d1, i2, d3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 11) return ((F)fn)(d0, d1, i2, d3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 12) return ((F)fn)(i0, i1, d2, d3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 13) return ((F)fn)(d0, i1, d2, d3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        if constexpr (M == 14) return ((F)fn)(i0, d1, d2, d3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
        return ((F)fn)(d0, d1, d2, d3, w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15]);
    }
}
template <class R>
R win64_dispatch(void* fn, int mask, const W* w) {
    switch (mask & 15) {
        case 0: return win64_call<R, 0>(fn, w);   case 1: return win64_call<R, 1>(fn, w);
        case 2: return win64_call<R, 2>(fn, w);   case 3: return win64_call<R, 3>(fn, w);
        case 4: return win64_call<R, 4>(fn, w);   case 5: return win64_call<R, 5>(fn, w);
        case 6: return win64_call<R, 6>(fn, w);   case 7: return win64_call<R, 7>(fn, w);
        case 8: return win64_call<R, 8>(fn, w);   case 9: return win64_call<R, 9>(fn, w);
        case 10: return win64_call<R, 10>(fn, w); case 11: return win64_call<R, 11>(fn, w);
        case 12: return win64_call<R, 12>(fn, w); case 13: return win64_call<R, 13>(fn, w);
        case 14: return win64_call<R, 14>(fn, w); default: return win64_call<R, 15>(fn, w);
    }
}
#elif defined(__i386__) || defined(_M_IX86)
#  define NY_FFI_X86 1
const int N_WORDS = 32;
using W32 = uint32_t;
template <class R>
R x86_cdecl(void* fn, const W32* w) {
    using F = R (*)(W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32,
                    W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32);
    return ((F)fn)(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15],
                   w[16], w[17], w[18], w[19], w[20], w[21], w[22], w[23], w[24], w[25], w[26], w[27], w[28], w[29], w[30], w[31]);
}
#  if defined(_WIN32)
// stdcall: the callee pops exactly its words, so the prototype must match
template <class R, int N> struct Std;
#    define NY_STD(N, ...) template <class R> struct Std<R, N> { static R call(void* fn, const W32* w) { (void)w; \
        using F = R (__stdcall *)(__VA_ARGS__); return ((F)fn)
NY_STD(0, void)(); } };
NY_STD(1, W32)(w[0]); } };
NY_STD(2, W32, W32)(w[0], w[1]); } };
NY_STD(3, W32, W32, W32)(w[0], w[1], w[2]); } };
NY_STD(4, W32, W32, W32, W32)(w[0], w[1], w[2], w[3]); } };
NY_STD(5, W32, W32, W32, W32, W32)(w[0], w[1], w[2], w[3], w[4]); } };
NY_STD(6, W32, W32, W32, W32, W32, W32)(w[0], w[1], w[2], w[3], w[4], w[5]); } };
NY_STD(7, W32, W32, W32, W32, W32, W32, W32)(w[0], w[1], w[2], w[3], w[4], w[5], w[6]); } };
NY_STD(8, W32, W32, W32, W32, W32, W32, W32, W32)(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]); } };
NY_STD(9, W32, W32, W32, W32, W32, W32, W32, W32, W32)(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8]); } };
NY_STD(10, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32)(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9]); } };
NY_STD(11, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32)(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10]); } };
NY_STD(12, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32, W32)(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11]); } };
#    undef NY_STD
template <class R>
R x86_stdcall(void* fn, int n, const W32* w) {
    switch (n) {
        case 0: return Std<R, 0>::call(fn, w);   case 1: return Std<R, 1>::call(fn, w);
        case 2: return Std<R, 2>::call(fn, w);   case 3: return Std<R, 3>::call(fn, w);
        case 4: return Std<R, 4>::call(fn, w);   case 5: return Std<R, 5>::call(fn, w);
        case 6: return Std<R, 6>::call(fn, w);   case 7: return Std<R, 7>::call(fn, w);
        case 8: return Std<R, 8>::call(fn, w);   case 9: return Std<R, 9>::call(fn, w);
        case 10: return Std<R, 10>::call(fn, w); case 11: return Std<R, 11>::call(fn, w);
        case 12: return Std<R, 12>::call(fn, w);
        default: raise("TypeError", "ctypes: a stdcall function of more than 12 argument words needs libffi");
    }
}
#  endif
#endif

// ── calls ───────────────────────────────────────────────────────────────────
enum { F_ERRNO = 1, F_LASTERR = 2, F_KEEPGIL = 4, F_STDCALL = 8, F_VARIADIC = 16 };

struct ErrnoSwap {
    int flags;
    explicit ErrnoSwap(int f) : flags(f) {
        if (flags & F_ERRNO) std::swap(errno, t_errno);
#ifdef _WIN32
        if (flags & F_LASTERR) SetLastError(t_last_error);
#endif
    }
    ~ErrnoSwap() {
        if (flags & F_ERRNO) std::swap(errno, t_errno);
#ifdef _WIN32
        if (flags & F_LASTERR) t_last_error = GetLastError();
#endif
    }
};

// The result `r` (raw bytes of rtype) as a Ret.
Ret result_of(const std::string& rtype, const unsigned char* r, bool widened) {
    if (rtype == "v") return Ret::none();
    if (rtype[0] == '{') return Ret::bytes(std::string((const char*)r, spec_size(rtype)));
    char c = rtype[0];
    if (widened && !is_float(c)) {
        // libffi widens integer results narrower than a word to ffi_arg
        uint64_t w; std::memcpy(&w, r, 8);
        const TI* t = type_of(c);
        unsigned char tmp[8];
        store_int(tmp, t->size, (int64_t)w);
        return load(tmp, c);
    }
    return load(r, c);
}

Ret call_libffi(void* fn, int flags, unsigned nfixed, const std::string& rtype, const std::vector<std::string>& atypes,
                const Args& av) {
    Ffi& f = ffi();
    Spec spec;
    std::vector<FfiType*> at;
    for (auto& s : atypes) at.push_back(spec.of(s));
    FfiType* rt = spec.of(rtype);
    alignas(16) unsigned char cif[512];
    std::memset(cif, 0, sizeof cif);
    int abi = (flags & F_STDCALL) ? ABI_STDCALL : f.abi_default;
    int st;
    if (flags & F_VARIADIC) {
        if (!f.prep_cif_var) raise("TypeError", "ctypes: this libffi cannot call variadic functions");
        st = f.prep_cif_var(cif, abi, nfixed, (unsigned)at.size(), rt, at.data());
    } else st = f.prep_cif(cif, abi, (unsigned)at.size(), rt, at.data());
    if (st != 0) raise("TypeError", "ctypes: ffi_prep_cif failed (status " + std::to_string(st) + ")");
    // argument storage: each value in a slot of its own size (structs: the
    // library passes the address of the struct's memory)
    std::vector<std::vector<unsigned char>> slots(atypes.size());
    std::vector<void*> vals(atypes.size());
    for (size_t k = 0; k < atypes.size(); k++) {
        const std::string& s = atypes[k];
        if (s[0] == '{') { vals[k] = addr_arg(av, k); if (!vals[k]) raise("ValueError", "ctypes: NULL struct argument"); continue; }
        slots[k].assign(16, 0);
        store(slots[k].data(), s[0], av, k);
        vals[k] = slots[k].data();
    }
    size_t rsize = rtype[0] == '{' ? spec_size(rtype) : 16;
    std::vector<unsigned char> ret(rsize < 16 ? 16 : rsize + 16, 0);
    {
        ErrnoSwap es(flags);
        if (flags & F_KEEPGIL) f.call(cif, (void (*)())fn, ret.data(), vals.data());
        else { GilRelease rel; f.call(cif, (void (*)())fn, ret.data(), vals.data()); }
    }
    return result_of(rtype, ret.data(), true);
}

// round 84: a structure's scalar leaves (offset, code), as spec_layout lays
// them out - what the ABIs classify a structure passed by value by.
void spec_leaves(const std::string& s, size_t& i, size_t base, std::vector<std::pair<size_t, char>>& out,
                 size_t& size, size_t& align) {
    char c = s[i++];
    if (c != '{') {
        const TI* t = type_of(c);
        if (!t) raise("TypeError", std::string("ctypes: unknown type code '") + c + "'");
        out.push_back({base, c});
        size = t->size; align = t->align;
        return;
    }
    size_t off = 0, al = 1;
    while (i < s.size() && s[i] != '}') {
        size_t n = 1;
        bool arr = false;
        if (s[i] == '[') {
            arr = true; i++; n = 0;
            while (i < s.size() && s[i] >= '0' && s[i] <= '9') n = n * 10 + (size_t)(s[i++] - '0');
        }
        size_t start = i, es, ea;
        std::vector<std::pair<size_t, char>> one;
        spec_leaves(s, i, 0, one, es, ea);
        if (arr && i < s.size() && s[i] == ']') i++;
        off = (off + ea - 1) / ea * ea;
        for (size_t k = 0; k < n; k++)
            for (auto& l : one) out.push_back({base + off + k * es + l.first, l.second});
        off += es * n;
        if (ea > al) al = ea;
        (void)start;
    }
    if (i < s.size()) i++;
    size = (off + al - 1) / al * al;
    align = al;
}
struct SLayout { size_t size = 0, align = 1; std::vector<std::pair<size_t, char>> leaves; };
SLayout struct_layout(const std::string& spec) {
    SLayout L; size_t i = 0;
    spec_leaves(spec, i, 0, L.leaves, L.size, L.align);
    return L;
}
[[noreturn]] void need_libffi(const char* what) {
    raise("TypeError", std::string("ctypes: ") + what + " needs libffi (" + ffi().why + ")");
}
#if defined(NY_FFI_SPLIT_REGS) && defined(__x86_64__)
// SysV x86-64 (§3.2.3): each eightbyte of a structure of at most 16 bytes is
// INTEGER when any integer leaf touches it, else SSE; larger ones, and any
// holding a long double, are MEMORY.
enum { C_NONE = 0, C_INT = 1, C_SSE = 2, C_MEM = 3 };
void sysv_classify(const SLayout& L, int cls[2]) {
    cls[0] = cls[1] = C_NONE;
    if (L.size > 16 || L.size == 0) { cls[0] = cls[1] = C_MEM; return; }
    for (auto& l : L.leaves) {
        if (l.second == 'g') { cls[0] = cls[1] = C_MEM; return; }
        const TI* t = type_of(l.second);
        for (size_t e = l.first / 8; e <= (l.first + t->size - 1) / 8 && e < 2; e++) {
            if (l.first % t->align) { cls[0] = cls[1] = C_MEM; return; }   // unaligned (packed)
            int want = is_float(l.second) ? C_SSE : C_INT;
            if (cls[e] == C_NONE || (cls[e] == C_SSE && want == C_INT)) cls[e] = want;
        }
    }
    if (L.size <= 8) cls[1] = C_NONE;
}
#endif
#if defined(NY_FFI_SPLIT_REGS) && defined(__aarch64__)
// AAPCS64: a homogeneous floating-point aggregate goes in SIMD registers;
// the built-in caller leaves those to libffi
bool aapcs_hfa(const SLayout& L) {
    if (L.leaves.empty() || L.leaves.size() > 4) return false;
    char c = L.leaves[0].second;
    if (!is_float(c)) return false;
    for (auto& l : L.leaves) if (l.second != c) return false;
    return true;
}
#endif

Ret call_builtin(void* fn, int flags, unsigned nfixed, const std::string& rtype, const std::vector<std::string>& atypes,
                 const Args& av) {
    (void)nfixed;
    // round 84: structures by value (it raised for every one): passed and
    // returned as each ABI does, from their layout (spec_leaves); long double
    // and what an ABI needs that the C++ calls below cannot express still
    // need libffi
    for (auto& s : atypes) if (s[0] == 'g') need_libffi("a long double argument");
    if (rtype[0] == 'g') need_libffi("a long double result");
    const bool rstruct = rtype[0] == '{';
    SLayout RL;
    if (rstruct) { RL = struct_layout(rtype); if (RL.size > 128) need_libffi("a structure result of more than 128 bytes"); }
    char rc = rtype[0];
    alignas(16) unsigned char rbuf[144] = {0};
    std::deque<std::vector<unsigned char>> copies;   // structures passed through a pointer to a copy
    auto word_of = [&](size_t k, bool& isf) -> W {
        char c = atypes[k][0];
        unsigned char tmp[16] = {0};
        store(tmp, c, av, k);
        isf = is_float(c);
        if (c == 'f') { W w = 0; std::memcpy(&w, tmp, 4); return w; }   // a float's bits in the low half
        if (c == 'd') { W w; std::memcpy(&w, tmp, 8); return w; }
        const TI* t = type_of(c);
        return (W)load_int(tmp, t->size, is_signed_int(c) || c == 'c');
    };
    auto struct_mem = [&](size_t k) -> const unsigned char* {
        const unsigned char* p = (const unsigned char*)addr_arg(av, k);
        if (!p) raise("ValueError", "ctypes: NULL struct argument");
        return p;
    };
    auto words_of = [&](const unsigned char* p, size_t size, W* out, size_t n) {
        std::memset(out, 0, n * sizeof(W));
        std::memcpy(out, p, size < n * sizeof(W) ? size : n * sizeof(W));
    };
#if defined(NY_FFI_SPLIT_REGS)
#  if defined(__aarch64__) && defined(__APPLE__)
    if (flags & F_VARIADIC) raise("TypeError", "ctypes: variadic calls need libffi on this platform");
#  endif
    W ir[N_IREG > 8 ? N_IREG : 8] = {0}; double fr[N_FREG] = {0}; W stk[N_STACK_CALL] = {0};
    int ni = 0, nf = 0, ns = 0;
    auto push_stack = [&](W w) {
        if (ns >= N_STACK_CALL) raise("TypeError", "ctypes: too many arguments for the built-in caller (libffi: " + ffi().why + ")");
        stk[ns++] = w;
    };
#  if defined(__x86_64__)
    int rcls[2] = {C_NONE, C_NONE};
    if (rstruct) {
        sysv_classify(RL, rcls);
        if (rcls[0] == C_MEM) ir[ni++] = (W)(uintptr_t)rbuf;   // the hidden result pointer, in %rdi
    }
#  endif
    for (size_t k = 0; k < atypes.size(); k++) {
        if (atypes[k][0] == '{') {
            SLayout L = struct_layout(atypes[k]);
            const unsigned char* p = struct_mem(k);
            size_t nw = (L.size + 7) / 8;
            W wv[16];
            if (nw > 16) need_libffi("a structure argument of more than 128 bytes");
            words_of(p, L.size, wv, nw);
#  if defined(__x86_64__)
            int cls[2];
            sysv_classify(L, cls);
            if (cls[0] != C_MEM) {
                int need_i = (cls[0] == C_INT) + (cls[1] == C_INT), need_f = (cls[0] == C_SSE) + (cls[1] == C_SSE);
                if (ni + need_i <= N_IREG && nf + need_f <= N_FREG) {   // all of it in registers, else all on the stack
                    for (size_t e = 0; e < nw; e++) {
                        if (cls[e] == C_INT) ir[ni++] = wv[e];
                        else std::memcpy(&fr[nf++], &wv[e], 8);
                    }
                    continue;
                }
            }
            for (size_t e = 0; e < nw; e++) push_stack(wv[e]);
#  else
            if (aapcs_hfa(L)) need_libffi("a structure of floating-point members by value on AArch64");
            if (L.size > 16) {
                // a copy in memory, its address in the next integer register
                copies.emplace_back(p, p + L.size);
                W a = (W)(uintptr_t)copies.back().data();
                if (ni < N_IREG) ir[ni++] = a; else push_stack(a);
                continue;
            }
            if (ni + (int)nw <= N_IREG) { for (size_t e = 0; e < nw; e++) ir[ni++] = wv[e]; continue; }
            ni = N_IREG;   // C.13: no more integer registers once one did not fit
            for (size_t e = 0; e < nw; e++) push_stack(wv[e]);
#  endif
            continue;
        }
        bool isf;
        W w = word_of(k, isf);
        if (isf && nf < N_FREG) { std::memcpy(&fr[nf++], &w, 8); continue; }
        if (!isf && ni < N_IREG) { ir[ni++] = w; continue; }
        push_stack(w);
    }
    ErrnoSwap es(flags);
    std::unique_ptr<GilRelease> rel;
    if (!(flags & F_KEEPGIL)) rel.reset(new GilRelease());
    if (rstruct) {
#  if defined(__x86_64__)
        if (rcls[0] == C_MEM) (void)split_call<W>(fn, ir, fr, stk);
        else if (RL.size <= 8) {
            if (rcls[0] == C_SSE) { double d = split_call<double>(fn, ir, fr, stk); std::memcpy(rbuf, &d, 8); }
            else { W w = split_call<W>(fn, ir, fr, stk); std::memcpy(rbuf, &w, 8); }
        } else if (rcls[0] == C_INT && rcls[1] == C_INT) { RII r = split_call<RII>(fn, ir, fr, stk); std::memcpy(rbuf, &r, 16); }
        else if (rcls[0] == C_SSE && rcls[1] == C_SSE) { RDD r = split_call<RDD>(fn, ir, fr, stk); std::memcpy(rbuf, &r, 16); }
        else if (rcls[0] == C_INT) { RID r = split_call<RID>(fn, ir, fr, stk); std::memcpy(rbuf, &r.a, 8); std::memcpy(rbuf + 8, &r.b, 8); }
        else { RDI r = split_call<RDI>(fn, ir, fr, stk); std::memcpy(rbuf, &r.a, 8); std::memcpy(rbuf + 8, &r.b, 8); }
#  else
        if (aapcs_hfa(RL)) { rel.reset(); need_libffi("a structure result of floating-point members on AArch64"); }
        size_t nw = (RL.size + 7) / 8;
        switch (nw) {
            case 0: case 1: { W w = split_call<W>(fn, ir, fr, stk); std::memcpy(rbuf, &w, 8); break; }
            case 2: { RII r = split_call<RII>(fn, ir, fr, stk); std::memcpy(rbuf, &r, 16); break; }
#    define NY_BLOB(N) case N: { RBlob<N> r = split_call<RBlob<N>>(fn, ir, fr, stk); std::memcpy(rbuf, &r, sizeof r); break; }
            NY_BLOB(3) NY_BLOB(4) NY_BLOB(5) NY_BLOB(6) NY_BLOB(7) NY_BLOB(8) NY_BLOB(9) NY_BLOB(10) NY_BLOB(11)
            NY_BLOB(12) NY_BLOB(13) NY_BLOB(14) NY_BLOB(15) NY_BLOB(16)
#    undef NY_BLOB
            default: rel.reset(); need_libffi("a structure result of more than 128 bytes");
        }
#  endif
    }
    else if (rc == 'd') { double d = split_call<double>(fn, ir, fr, stk); std::memcpy(rbuf, &d, 8); }
    else if (rc == 'f') { float x = split_call<float>(fn, ir, fr, stk); std::memcpy(rbuf, &x, 4); }
    else { W w = split_call<W>(fn, ir, fr, stk); std::memcpy(rbuf, &w, 8); }
    rel.reset();
#elif defined(NY_FFI_WIN64)
    // Windows x64: a structure of 1, 2, 4 or 8 bytes travels as an integer of
    // that size; any other is passed by reference to a copy, and returned
    // through a hidden pointer that comes first (RCX)
    W w[N_POS + 1] = {0};
    int mask = 0, n = 0;
    const bool rhidden = rstruct && !(RL.size == 1 || RL.size == 2 || RL.size == 4 || RL.size == 8);
    if (rhidden) w[n++] = (W)(uintptr_t)rbuf;
    for (size_t k = 0; k < atypes.size(); k++) {
        if (n >= N_POS) raise("TypeError", "ctypes: more than 16 arguments need libffi");
        if (atypes[k][0] == '{') {
            SLayout L = struct_layout(atypes[k]);
            const unsigned char* p = struct_mem(k);
            if (L.size == 1 || L.size == 2 || L.size == 4 || L.size == 8) { words_of(p, L.size, &w[n++], 1); continue; }
            copies.emplace_back(p, p + L.size);
            w[n++] = (W)(uintptr_t)copies.back().data();
            continue;
        }
        bool isf;
        w[n] = word_of(k, isf);
        // a float stays a float: its bits in the low half of the XMM register
        if (isf && n < 4) mask |= 1 << n;
        n++;
    }
    ErrnoSwap es(flags);
    std::unique_ptr<GilRelease> rel;
    if (!(flags & F_KEEPGIL)) rel.reset(new GilRelease());
    if (rstruct) {
        W r = win64_dispatch<W>(fn, mask, w);
        if (!rhidden) std::memcpy(rbuf, &r, 8);
    }
    else if (rc == 'd') { double d = win64_dispatch<double>(fn, mask, w); std::memcpy(rbuf, &d, 8); }
    else if (rc == 'f') { float x = win64_dispatch<float>(fn, mask, w); std::memcpy(rbuf, &x, 4); }
    else { W r = win64_dispatch<W>(fn, mask, w); std::memcpy(rbuf, &r, 8); }
    rel.reset();
#elif defined(NY_FFI_X86)
    (void)word_of; (void)words_of;
    W32 w[N_WORDS] = {0};
    int n = 0;
#  if defined(_WIN32)
    // structures of 1, 2, 4 or 8 bytes come back in EAX/EDX:EAX; the rest
    // through a hidden pointer the caller pushes first and pops itself (the
    // Microsoft convention, which DLLs follow)
    const bool rhidden = rstruct && !(RL.size == 1 || RL.size == 2 || RL.size == 4 || RL.size == 8);
    if (rhidden) w[n++] = (W32)(uintptr_t)rbuf;
#  else
    if (rstruct) need_libffi("a structure result on 32-bit x86");   // the callee pops the hidden pointer (SysV i386)
    const bool rhidden = false;
#  endif
    for (size_t k = 0; k < atypes.size(); k++) {
        if (atypes[k][0] == '{') {
            // copied onto the stack, in words of 4 bytes
            SLayout L = struct_layout(atypes[k]);
            const unsigned char* p = struct_mem(k);
            size_t words = (L.size + 3) / 4;
            if (n + (int)words > N_WORDS) raise("TypeError", "ctypes: too many arguments for the built-in caller");
            std::memcpy(&w[n], p, L.size);
            n += (int)words;
            continue;
        }
        char c = atypes[k][0];
        unsigned char tmp[16] = {0};
        store(tmp, c, av, k);
        const TI* t = type_of(c);
        size_t words = t->size > 4 ? 2 : 1;
        if (c == 'f') words = 1;
        if (n + (int)words > N_WORDS) raise("TypeError", "ctypes: too many arguments for the built-in caller");
        if (words == 1 && t->size < 4 && !is_float(c)) { W32 x = (W32)load_int(tmp, t->size, is_signed_int(c)); w[n++] = x; }
        else { std::memcpy(&w[n], tmp, words * 4); n += (int)words; }
    }
    ErrnoSwap es(flags);
    std::unique_ptr<GilRelease> rel;
    if (!(flags & F_KEEPGIL)) rel.reset(new GilRelease());
#  if defined(_WIN32)
    if (flags & F_STDCALL) {
        if (rc == 'd' && !rstruct) { double d = x86_stdcall<double>(fn, n, w); std::memcpy(rbuf, &d, 8); }
        else if (rc == 'f' && !rstruct) { float x = x86_stdcall<float>(fn, n, w); std::memcpy(rbuf, &x, 4); }
        else { uint64_t r = x86_stdcall<uint64_t>(fn, n, w); if (!rhidden) std::memcpy(rbuf, &r, 8); }
    } else
#  endif
    {
        if (rc == 'd' && !rstruct) { double d = x86_cdecl<double>(fn, w); std::memcpy(rbuf, &d, 8); }
        else if (rc == 'f' && !rstruct) { float x = x86_cdecl<float>(fn, w); std::memcpy(rbuf, &x, 4); }
        else { uint64_t r = x86_cdecl<uint64_t>(fn, w); if (!rhidden) std::memcpy(rbuf, &r, 8); }
    }
    rel.reset();
#else
    (void)word_of; (void)flags; (void)struct_mem; (void)words_of; (void)copies;
    raise("TypeError", "ctypes: foreign calls need libffi on this platform (" + ffi().why + ")");
#endif
    if (rstruct) return Ret::bytes(std::string((const char*)rbuf, RL.size));
    if (rc == 'v') return Ret::none();
    if (rc == 'd' || rc == 'f') return load(rbuf, rc);
    // an integer result: the low bytes of the word, extended by the type
    const TI* t = type_of(rc);
    unsigned char tmp[8];
    uint64_t wv; std::memcpy(&wv, rbuf, 8);
    store_int(tmp, t->size, (int64_t)wv);
    return load(tmp, rc);
}

// ── callbacks ───────────────────────────────────────────────────────────────
struct Callback {
    int64_t id = 0;
    Engine* eng = nullptr;
    BoxPtr fn;
    std::string rtype;
    std::vector<std::string> atypes;
    void* closure = nullptr;   // libffi closure (or nullptr: a pool trampoline)
    void* code = nullptr;
    int slot = -1;
    alignas(16) unsigned char cif[512];
    std::unique_ptr<Spec> spec;
    std::vector<FfiType*> at;
};
std::mutex g_cb_mu;
std::vector<std::unique_ptr<Callback>> g_callbacks;   // by id - 1 (nullptr once freed)

// Run callback `cb` with C argument values read from `argp[k]` (each the
// address of argument k), writing the result to `ret`.
void run_callback(Callback* cb, void** argp, void* ret, bool widen) {
    GilReacquire gil;
    Engine& e = *cb->eng;
    if (!holds_gil()) {
        std::fprintf(stderr, "ctypes: a callback was called on a thread Nython did not start; not supported\n");
        return;
    }
    std::vector<BoxPtr> args;
    for (size_t k = 0; k < cb->atypes.size(); k++) {
        const std::string& s = cb->atypes[k];
        Ret r = s[0] == '{' ? Ret::bytes(std::string((const char*)argp[k], spec_size(s))) : load(argp[k], s[0]);
        if (r.k == Ret::NONE && (s[0] == 'P' || s[0] == 'z' || s[0] == 'Z')) r = Ret::none();
        args.push_back(e.from_ret(r));
    }
    char rc = cb->rtype[0];
    size_t rsize = rc == 'v' ? 0 : rc == '{' ? spec_size(cb->rtype) : (widen && !is_float(rc) ? 8 : type_of(rc)->size);
    if (rsize) std::memset(ret, 0, rsize);
    BoxPtr res;
    try {
        res = e.call(cb->fn, args);
    } catch (NyError& err) {
        // CPython prints the error and returns 0 ("Exception ignored on calling ctypes callback function")
        std::string what = !err.type.empty() ? err.type + ": " + err.msg : err.raw;
        if (what.rfind("__exc__:", 0) == 0) {
            what = what.substr(8);
            auto c = what.find(':');
            if (c != std::string::npos) what = what.substr(0, c) + ": " + what.substr(c + 1);
        }
        std::fprintf(stderr, "Exception ignored on calling ctypes callback function: %s\n", e.describe(cb->fn).c_str());
        std::fprintf(stderr, "%s\n", what.c_str());
        return;
    }
    if (rc == 'v') return;
    if (is_float(rc)) {
        double d = 0;
        e.unbox_num(res, d);
        if (rc == 'f') { float f = (float)d; std::memcpy(ret, &f, 4); }
        else if (rc == 'd') std::memcpy(ret, &d, 8);
        else { long double g = d; std::memcpy(ret, &g, sizeof g); }
        return;
    }
    int64_t v = 0;
    if (!e.unbox_int(res, v)) { double d; if (e.unbox_num(res, d)) v = (int64_t)d; }
    if (widen) { int64_t w = v; std::memcpy(ret, &w, 8); }
    else store_int(ret, type_of(rc) ? type_of(rc)->size : 8, v);
}

void ffi_closure_entry(void* /*cif*/, void* ret, void** args, void* user) {
    run_callback((Callback*)user, args, ret, true);
}

#if defined(NY_FFI_SPLIT_REGS)
// The pool of callback trampolines for the built-in caller: each reads every
// argument register and stack word, and the signature says which to use.
const int POOL = 32;
Callback* g_pool[3][POOL];   // [int, double, float result][slot]
W pool_dispatch(int kind, int slot, const W* ir, const double* fr, const W* st, double* dret) {
    Callback* cb = g_pool[kind][slot];
    std::vector<std::vector<unsigned char>> store_(cb->atypes.size(), std::vector<unsigned char>(16, 0));
    std::vector<void*> argp(cb->atypes.size());
    int ni = 0, nf = 0, ns = 0;
    auto next_stack = [&]() -> W { return ns < N_STACK ? st[ns++] : 0; };
    for (size_t k = 0; k < cb->atypes.size(); k++) {
        char c = cb->atypes[k][0];
        if (c == '{') {
            // round 84: a structure by value, from where call_builtin puts one
            SLayout L = struct_layout(cb->atypes[k]);
            size_t nw = (L.size + 7) / 8;
            store_[k].assign(nw * 8 + 8, 0);
            W* out = (W*)store_[k].data();
#  if defined(__x86_64__)
            int cls[2];
            sysv_classify(L, cls);
            int need_i = cls[0] == C_MEM ? 99 : (cls[0] == C_INT) + (cls[1] == C_INT);
            int need_f = cls[0] == C_MEM ? 99 : (cls[0] == C_SSE) + (cls[1] == C_SSE);
            if (ni + need_i <= N_IREG && nf + need_f <= N_FREG) {
                for (size_t e = 0; e < nw; e++) {
                    if (cls[e] == C_INT) out[e] = ir[ni++];
                    else std::memcpy(&out[e], &fr[nf++], 8);
                }
            } else for (size_t e = 0; e < nw; e++) out[e] = next_stack();
#  else
            if (L.size > 16) {
                W a = ni < N_IREG ? ir[ni++] : next_stack();
                store_[k].assign(L.size + 8, 0);
                if (a) std::memcpy(store_[k].data(), (const void*)(uintptr_t)a, L.size);
            } else if (ni + (int)nw <= N_IREG) { for (size_t e = 0; e < nw; e++) out[e] = ir[ni++]; }
            else { ni = N_IREG; for (size_t e = 0; e < nw; e++) out[e] = next_stack(); }
#  endif
            argp[k] = store_[k].data();
            continue;
        }
        W w;
        if (is_float(c) && nf < N_FREG) std::memcpy(&w, &fr[nf++], 8);
        else if (!is_float(c) && ni < N_IREG) w = ir[ni++];
        else w = next_stack();
        std::memcpy(store_[k].data(), &w, 8);
        argp[k] = store_[k].data();
    }
    unsigned char ret[16] = {0};
    run_callback(cb, argp.data(), ret, false);
    char rc = cb->rtype[0];
    if (rc == 'd') { std::memcpy(dret, ret, 8); return 0; }
    if (rc == 'f') { float f; std::memcpy(&f, ret, 4); *dret = f; return 0; }
    if (rc == 'v') return 0;
    const TI* t = type_of(rc);
    return (W)load_int(ret, t->size, is_signed_int(rc));
}
#  if defined(__x86_64__)
#    define NY_TRAMP_PARAMS W i0, W i1, W i2, W i3, W i4, W i5, double f0, double f1, double f2, double f3, double f4, double f5, double f6, double f7, W s0, W s1, W s2, W s3, W s4, W s5, W s6, W s7
#    define NY_TRAMP_IR {i0, i1, i2, i3, i4, i5, 0, 0}
#  else
#    define NY_TRAMP_PARAMS W i0, W i1, W i2, W i3, W i4, W i5, W i6, W i7, double f0, double f1, double f2, double f3, double f4, double f5, double f6, double f7, W s0, W s1, W s2, W s3, W s4, W s5, W s6, W s7
#    define NY_TRAMP_IR {i0, i1, i2, i3, i4, i5, i6, i7}
#  endif
template <int S> W tramp_i(NY_TRAMP_PARAMS) {
    W ir[8] = NY_TRAMP_IR; double fr[8] = {f0, f1, f2, f3, f4, f5, f6, f7}; W st[8] = {s0, s1, s2, s3, s4, s5, s6, s7};
    double d; return pool_dispatch(0, S, ir, fr, st, &d);
}
template <int S> double tramp_d(NY_TRAMP_PARAMS) {
    W ir[8] = NY_TRAMP_IR; double fr[8] = {f0, f1, f2, f3, f4, f5, f6, f7}; W st[8] = {s0, s1, s2, s3, s4, s5, s6, s7};
    double d = 0; pool_dispatch(1, S, ir, fr, st, &d); return d;
}
template <int S> float tramp_f(NY_TRAMP_PARAMS) {
    W ir[8] = NY_TRAMP_IR; double fr[8] = {f0, f1, f2, f3, f4, f5, f6, f7}; W st[8] = {s0, s1, s2, s3, s4, s5, s6, s7};
    double d = 0; pool_dispatch(2, S, ir, fr, st, &d); return (float)d;
}
template <int... S> struct TrampTable {
    static void* get(int kind, int s) {
        static void* ti[] = {(void*)&tramp_i<S>...};
        static void* td[] = {(void*)&tramp_d<S>...};
        static void* tf[] = {(void*)&tramp_f<S>...};
        return kind == 0 ? ti[s] : kind == 1 ? td[s] : tf[s];
    }
};
using Pool = TrampTable<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
                        26, 27, 28, 29, 30, 31>;
#elif defined(NY_FFI_WIN64)
// round 84: callbacks without libffi on Windows x64. Its first four
// arguments are positional - RCX/RDX/R8/R9 or XMM0-3 by their type - so a
// trampoline is one per float mask of those four (M): each parameter has
// the type of the register the caller put the argument in. The rest are
// stack words. A structure of 1, 2, 4 or 8 bytes arrives as such a word,
// any other as a pointer to the caller's copy.
const int POOL = 16;
Callback* g_pool[3][16][POOL];   // [int, double, float result][mask][slot]
W pool_dispatch(int kind, int mask, int slot, const W* w, double* dret) {
    Callback* cb = g_pool[kind][mask][slot];
    std::vector<std::vector<unsigned char>> store_(cb->atypes.size(), std::vector<unsigned char>(16, 0));
    std::vector<void*> argp(cb->atypes.size());
    for (size_t k = 0; k < cb->atypes.size() && k < 16; k++) {
        const std::string& s = cb->atypes[k];
        if (s[0] == '{') {
            size_t size = spec_size(s);
            store_[k].assign(size + 8, 0);
            if (size == 1 || size == 2 || size == 4 || size == 8) std::memcpy(store_[k].data(), &w[k], size);
            else if (w[k]) std::memcpy(store_[k].data(), (const void*)(uintptr_t)w[k], size);
        } else std::memcpy(store_[k].data(), &w[k], 8);
        argp[k] = store_[k].data();
    }
    unsigned char ret[16] = {0};
    run_callback(cb, argp.data(), ret, false);
    char rc = cb->rtype[0];
    if (rc == 'd') { std::memcpy(dret, ret, 8); return 0; }
    if (rc == 'f') { float f; std::memcpy(&f, ret, 4); *dret = f; return 0; }
    if (rc == 'v') return 0;
    const TI* t = type_of(rc);
    return (W)load_int(ret, t->size, is_signed_int(rc));
}
template <int M, int K> using P64 = std::conditional_t<((M >> K) & 1) != 0, double, W>;
template <class T> W bits64(T v) { W w = 0; std::memcpy(&w, &v, sizeof v); return w; }
#  define NY_T64_PARAMS P64<M, 0> a0, P64<M, 1> a1, P64<M, 2> a2, P64<M, 3> a3, W s4, W s5, W s6, W s7, W s8, W s9, W s10, W s11, W s12, W s13, W s14, W s15
#  define NY_T64_WORDS W w[16] = {bits64(a0), bits64(a1), bits64(a2), bits64(a3), s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15}
template <int M, int S> W tramp_i(NY_T64_PARAMS) { NY_T64_WORDS; double d; return pool_dispatch(0, M, S, w, &d); }
template <int M, int S> double tramp_d(NY_T64_PARAMS) { NY_T64_WORDS; double d = 0; pool_dispatch(1, M, S, w, &d); return d; }
template <int M, int S> float tramp_f(NY_T64_PARAMS) { NY_T64_WORDS; double d = 0; pool_dispatch(2, M, S, w, &d); return (float)d; }
#  undef NY_T64_PARAMS
#  undef NY_T64_WORDS
template <int M, int... S> struct TrampRow {
    static void* get(int kind, int s) {
        static void* ti[] = {(void*)&tramp_i<M, S>...};
        static void* td[] = {(void*)&tramp_d<M, S>...};
        static void* tf[] = {(void*)&tramp_f<M, S>...};
        return kind == 0 ? ti[s] : kind == 1 ? td[s] : tf[s];
    }
};
template <int M> using Row = TrampRow<M, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>;
void* pool_code(int kind, int mask, int s) {
    switch (mask & 15) {
        case 0: return Row<0>::get(kind, s);   case 1: return Row<1>::get(kind, s);
        case 2: return Row<2>::get(kind, s);   case 3: return Row<3>::get(kind, s);
        case 4: return Row<4>::get(kind, s);   case 5: return Row<5>::get(kind, s);
        case 6: return Row<6>::get(kind, s);   case 7: return Row<7>::get(kind, s);
        case 8: return Row<8>::get(kind, s);   case 9: return Row<9>::get(kind, s);
        case 10: return Row<10>::get(kind, s); case 11: return Row<11>::get(kind, s);
        case 12: return Row<12>::get(kind, s); case 13: return Row<13>::get(kind, s);
        case 14: return Row<14>::get(kind, s); default: return Row<15>::get(kind, s);
    }
}
#elif defined(NY_FFI_X86)
// round 84: callbacks without libffi on 32-bit x86: every argument is a
// stack word (or two), read from the trampoline's 32 word parameters (round
// 85: 16 were too few for a 40-byte structure among others); a
// cdecl caller pops them itself, a stdcall trampoline pops exactly its
// signature's words (one instantiation per word count, 0-12). A structure
// argument is its words copied onto the stack.
const int POOL = 8;
const int N_CBW = 32;
Callback* g_pool[3][14][POOL];   // [int, double, float result][0 cdecl, 1 + words: stdcall][slot]
uint64_t pool_dispatch(int kind, int conv, int slot, const W32* w, double* dret) {
    Callback* cb = g_pool[kind][conv][slot];
    std::vector<std::vector<unsigned char>> store_(cb->atypes.size(), std::vector<unsigned char>(16, 0));
    std::vector<void*> argp(cb->atypes.size());
    int n = 0;
    for (size_t k = 0; k < cb->atypes.size(); k++) {
        const std::string& s = cb->atypes[k];
        size_t size = s[0] == '{' ? spec_size(s) : type_of(s[0])->size;
        size_t words = s[0] == '{' ? (size + 3) / 4 : (size > 4 ? 2 : 1);
        store_[k].assign(words * 4 + 8, 0);
        for (size_t q = 0; q < words && n < N_CBW; q++, n++) std::memcpy(store_[k].data() + q * 4, &w[n], 4);
        argp[k] = store_[k].data();
    }
    unsigned char ret[16] = {0};
    run_callback(cb, argp.data(), ret, false);
    char rc = cb->rtype[0];
    if (rc == 'd') { std::memcpy(dret, ret, 8); return 0; }
    if (rc == 'f') { float f; std::memcpy(&f, ret, 4); *dret = f; return 0; }
    if (rc == 'v') return 0;
    const TI* t = type_of(rc);
    return (uint64_t)load_int(ret, t->size, is_signed_int(rc));
}
#  define NY_T32_PARAMS W32 w0, W32 w1, W32 w2, W32 w3, W32 w4, W32 w5, W32 w6, W32 w7, W32 w8, W32 w9, W32 w10, W32 w11, \
        W32 w12, W32 w13, W32 w14, W32 w15, W32 w16, W32 w17, W32 w18, W32 w19, W32 w20, W32 w21, W32 w22, W32 w23, \
        W32 w24, W32 w25, W32 w26, W32 w27, W32 w28, W32 w29, W32 w30, W32 w31
#  define NY_T32_WORDS W32 w[N_CBW] = {w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15, \
        w16, w17, w18, w19, w20, w21, w22, w23, w24, w25, w26, w27, w28, w29, w30, w31}
template <int S> uint64_t tramp_i(NY_T32_PARAMS) { NY_T32_WORDS; double d; return pool_dispatch(0, 0, S, w, &d); }
template <int S> double tramp_d(NY_T32_PARAMS) { NY_T32_WORDS; double d = 0; pool_dispatch(1, 0, S, w, &d); return d; }
template <int S> float tramp_f(NY_T32_PARAMS) { NY_T32_WORDS; double d = 0; pool_dispatch(2, 0, S, w, &d); return (float)d; }
#  undef NY_T32_PARAMS
#  undef NY_T32_WORDS
template <int... S> struct TrampTable {
    static void* get(int kind, int s) {
        static void* ti[] = {(void*)&tramp_i<S>...};
        static void* td[] = {(void*)&tramp_d<S>...};
        static void* tf[] = {(void*)&tramp_f<S>...};
        return kind == 0 ? ti[s] : kind == 1 ? td[s] : tf[s];
    }
};
using Pool = TrampTable<0, 1, 2, 3, 4, 5, 6, 7>;
#  if defined(_WIN32)
// stdcall: the words the signature takes, popped by the trampoline
template <class R, int N, int S> struct StdTramp;
#    define NY_STDT(N, ...) template <class R, int S> struct StdTramp<R, N, S> { \
        static R __stdcall run(__VA_ARGS__) { W32 w[N_CBW] = {0}; NY_STDT_FILL_##N; double d = 0; \
            uint64_t r = pool_dispatch(std::is_same<R, double>::value ? 1 : std::is_same<R, float>::value ? 2 : 0, N + 1, S, w, &d); \
            if constexpr (std::is_same<R, double>::value || std::is_same<R, float>::value) return (R)d; else return (R)r; } };
#    define NY_STDT_FILL_0 (void)0
#    define NY_STDT_FILL_1 w[0] = a0
#    define NY_STDT_FILL_2 NY_STDT_FILL_1; w[1] = a1
#    define NY_STDT_FILL_3 NY_STDT_FILL_2; w[2] = a2
#    define NY_STDT_FILL_4 NY_STDT_FILL_3; w[3] = a3
#    define NY_STDT_FILL_5 NY_STDT_FILL_4; w[4] = a4
#    define NY_STDT_FILL_6 NY_STDT_FILL_5; w[5] = a5
#    define NY_STDT_FILL_7 NY_STDT_FILL_6; w[6] = a6
#    define NY_STDT_FILL_8 NY_STDT_FILL_7; w[7] = a7
#    define NY_STDT_FILL_9 NY_STDT_FILL_8; w[8] = a8
#    define NY_STDT_FILL_10 NY_STDT_FILL_9; w[9] = a9
#    define NY_STDT_FILL_11 NY_STDT_FILL_10; w[10] = a10
#    define NY_STDT_FILL_12 NY_STDT_FILL_11; w[11] = a11
NY_STDT(0, void)
NY_STDT(1, W32 a0)
NY_STDT(2, W32 a0, W32 a1)
NY_STDT(3, W32 a0, W32 a1, W32 a2)
NY_STDT(4, W32 a0, W32 a1, W32 a2, W32 a3)
NY_STDT(5, W32 a0, W32 a1, W32 a2, W32 a3, W32 a4)
NY_STDT(6, W32 a0, W32 a1, W32 a2, W32 a3, W32 a4, W32 a5)
NY_STDT(7, W32 a0, W32 a1, W32 a2, W32 a3, W32 a4, W32 a5, W32 a6)
NY_STDT(8, W32 a0, W32 a1, W32 a2, W32 a3, W32 a4, W32 a5, W32 a6, W32 a7)
NY_STDT(9, W32 a0, W32 a1, W32 a2, W32 a3, W32 a4, W32 a5, W32 a6, W32 a7, W32 a8)
NY_STDT(10, W32 a0, W32 a1, W32 a2, W32 a3, W32 a4, W32 a5, W32 a6, W32 a7, W32 a8, W32 a9)
NY_STDT(11, W32 a0, W32 a1, W32 a2, W32 a3, W32 a4, W32 a5, W32 a6, W32 a7, W32 a8, W32 a9, W32 a10)
NY_STDT(12, W32 a0, W32 a1, W32 a2, W32 a3, W32 a4, W32 a5, W32 a6, W32 a7, W32 a8, W32 a9, W32 a10, W32 a11)
#    undef NY_STDT
template <class R, int N, int... S> void* std_get(int s) { static void* t[] = {(void*)&StdTramp<R, N, S>::run...}; return t[s]; }
template <int N> void* std_code(int kind, int s) {
    if (kind == 1) return std_get<double, N, 0, 1, 2, 3, 4, 5, 6, 7>(s);
    if (kind == 2) return std_get<float, N, 0, 1, 2, 3, 4, 5, 6, 7>(s);
    return std_get<uint64_t, N, 0, 1, 2, 3, 4, 5, 6, 7>(s);
}
void* stdcall_code(int kind, int words, int s) {
    switch (words) {
        case 0: return std_code<0>(kind, s);   case 1: return std_code<1>(kind, s);
        case 2: return std_code<2>(kind, s);   case 3: return std_code<3>(kind, s);
        case 4: return std_code<4>(kind, s);   case 5: return std_code<5>(kind, s);
        case 6: return std_code<6>(kind, s);   case 7: return std_code<7>(kind, s);
        case 8: return std_code<8>(kind, s);   case 9: return std_code<9>(kind, s);
        case 10: return std_code<10>(kind, s); case 11: return std_code<11>(kind, s);
        default: return std_code<12>(kind, s);
    }
}
#  endif
#endif

// ── the builtins ────────────────────────────────────────────────────────────
std::vector<std::string> str_list(const Args& a, size_t i) {
    std::vector<std::string> out;
    auto l = a.list(i);
    for (size_t k = 0; k < l->size(); k++) out.push_back(l->as_str(k));
    return out;
}

Ret b_dlopen(Engine&, const Args& a) {
    std::string path = a.size() > 0 && !a.is_none(0) ? a.as_str(0) : std::string();
    void* h;
#ifdef _WIN32
    h = dl_open(path.empty() ? nullptr : path.c_str());
    if (!h) raise("OSError", last_error_text());
#else
    int mode = a.size() > 1 && !a.is_none(1) ? (int)a.as_int(1) : (RTLD_NOW | RTLD_LOCAL);
    h = dl_open(path.empty() ? nullptr : path.c_str(), mode);
    if (!h) raise("OSError", last_error_text());
#endif
    return Ret::integer((int64_t)(intptr_t)h);
}
Ret b_dlsym(Engine&, const Args& a) {
    void* h = addr_arg(a, 0);
    std::string name = a.as_str(1);
    void* p = dl_sym(h, name.c_str());
    if (!p) {
        // _ffi_dlsym(h, name, true): the loader's own message, as CPython's AttributeError
        if (a.size() > 2 && a.truthy(2)) {
#ifdef _WIN32
            raise("AttributeError", "function '" + name + "' not found");
#else
            raise("AttributeError", last_error_text());
#endif
        }
        return Ret::none();
    }
    return Ret::integer((int64_t)(intptr_t)p);
}
Ret b_dlclose(Engine&, const Args& a) {
#ifdef _WIN32
    return Ret::boolean(FreeLibrary((HMODULE)addr_arg(a, 0)) != 0);
#else
    return Ret::boolean(dlclose(addr_arg(a, 0)) == 0);
#endif
}
Ret b_typeinfo(Engine&, const Args&) {
    std::vector<Ret> out;
    for (auto& t : typeinfo())
        out.push_back(Ret::lst({Ret::str(std::string(1, t.code)), Ret::integer((int64_t)t.size), Ret::integer((int64_t)t.align)}));
    return Ret::lst(std::move(out));
}
Ret b_alloc(Engine&, const Args& a) {
    int64_t n = a.as_int(0);
    if (n < 0) raise("ValueError", "ctypes: negative size");
    void* p = std::calloc((size_t)(n ? n : 1), 1);
    if (!p) raise("MemoryError", "");
    return Ret::integer((int64_t)(intptr_t)p);
}
Ret b_free(Engine&, const Args& a) { std::free(addr_arg(a, 0)); return Ret::none(); }
Ret b_realloc(Engine&, const Args& a) {
    int64_t n = a.as_int(1);
    void* p = std::realloc(addr_arg(a, 0), (size_t)(n ? n : 1));
    if (!p) raise("MemoryError", "");
    return Ret::integer((int64_t)(intptr_t)p);
}
Ret b_get(Engine&, const Args& a) {
    void* p = checked_addr(a, 0, "ctypes");
    std::string c = a.as_str(1);
    return load(p, c[0]);
}
Ret b_set(Engine&, const Args& a) {
    void* p = checked_addr(a, 0, "ctypes");
    std::string c = a.as_str(1);
    store(p, c[0], a, 2);
    return Ret::none();
}
// Bit fields: `nbits` bits at bit `off` of the storage unit of type `code`
// (the C compiler's allocation for GCC/Clang/MSVC is computed by the library).
Ret b_getbits(Engine&, const Args& a) {
    void* p = checked_addr(a, 0, "ctypes");
    char c = a.as_str(1)[0];
    int off = (int)a.as_int(2), n = (int)a.as_int(3);
    const TI* t = type_of(c);
    uint64_t u = (uint64_t)load_int(p, t->size, false);
    uint64_t mask = n >= 64 ? ~0ULL : ((1ULL << n) - 1);
    uint64_t v = (u >> off) & mask;
    if (is_signed_int(c) && n < 64 && (v >> (n - 1)) & 1) return Ret::integer((int64_t)(v | ~mask));
    if (c == '?') return Ret::boolean(v != 0);
    return uret(v);
}
Ret b_setbits(Engine&, const Args& a) {
    void* p = checked_addr(a, 0, "ctypes");
    char c = a.as_str(1)[0];
    int off = (int)a.as_int(2), n = (int)a.as_int(3);
    const TI* t = type_of(c);
    uint64_t u = (uint64_t)load_int(p, t->size, false);
    uint64_t mask = n >= 64 ? ~0ULL : ((1ULL << n) - 1);
    uint64_t v = (uint64_t)a.as_int(4) & mask;
    u = (u & ~(mask << off)) | (v << off);
    store_int(p, t->size, (int64_t)u);
    return Ret::none();
}
Ret b_read(Engine&, const Args& a) {
    int64_t n = a.as_int(1);
    if (n <= 0) return Ret::bytes("");
    const char* p = (const char*)checked_addr(a, 0, "ctypes");
    return Ret::bytes(std::string(p, (size_t)n));
}
Ret b_write(Engine&, const Args& a) {
    std::string s = a.as_bytes(1);
    if (s.empty()) return Ret::integer(0);
    std::memcpy(checked_addr(a, 0, "ctypes"), s.data(), s.size());
    return Ret::integer((int64_t)s.size());
}
Ret b_memmove(Engine&, const Args& a) {
    std::memmove(addr_arg(a, 0), addr_arg(a, 1), (size_t)a.as_int(2));
    return Ret::integer(a.as_int(0));
}
Ret b_memset(Engine&, const Args& a) {
    std::memset(addr_arg(a, 0), (int)a.as_int(1), (size_t)a.as_int(2));
    return Ret::integer(a.as_int(0));
}
Ret b_strlen(Engine&, const Args& a) { return Ret::integer((int64_t)std::strlen((const char*)checked_addr(a, 0, "ctypes"))); }
Ret b_wcslen(Engine&, const Args& a) { return Ret::integer((int64_t)std::wcslen((const wchar_t*)checked_addr(a, 0, "ctypes"))); }
Ret b_wencode(Engine&, const Args& a) {
    std::wstring w = utf8_to_w(a.as_str(0));
    return Ret::bytes(std::string((const char*)w.data(), w.size() * sizeof(wchar_t)));
}
Ret b_wdecode(Engine&, const Args& a) {
    std::string b = a.as_bytes(0);
    std::wstring w(b.size() / sizeof(wchar_t), L'\0');
    std::memcpy(&w[0], b.data(), w.size() * sizeof(wchar_t));
    return Ret::str(w_to_utf8(w.data(), w.size()));
}
Ret b_call(Engine&, const Args& a) {
    void* fn = addr_arg(a, 0);
    if (!fn) raise("ValueError", "NULL function pointer");
    int flags = (int)a.as_int(1);
    unsigned nfixed = (unsigned)a.as_int(2);
    std::string rtype = a.as_str(3);
    std::vector<std::string> atypes = str_list(a, 4);
    auto av = a.list(5);
    if (av->size() != atypes.size()) raise("TypeError", "ctypes: argument count mismatch");
    if (ffi().ok) return call_libffi(fn, flags, nfixed, rtype, atypes, *av);
    return call_builtin(fn, flags, nfixed, rtype, atypes, *av);
}
Ret b_callback(Engine& e, const Args& a) {
    auto cb = std::make_unique<Callback>();
    cb->eng = &e;
    cb->fn = a.box(0);
    int flags = (int)a.as_int(1);
    cb->rtype = a.as_str(2);
    cb->atypes = str_list(a, 3);
    if (cb->rtype[0] == '{') raise("TypeError", "ctypes: a callback returning a structure is not supported");
    Ffi& f = ffi();
    if (f.ok && f.closure_alloc && f.prep_closure_loc) {
        cb->spec.reset(new Spec());
        for (auto& s : cb->atypes) cb->at.push_back(cb->spec->of(s));
        FfiType* rt = cb->spec->of(cb->rtype);
        std::memset(cb->cif, 0, sizeof cb->cif);
        int abi = (flags & F_STDCALL) ? ABI_STDCALL : f.abi_default;
        if (f.prep_cif(cb->cif, abi, (unsigned)cb->at.size(), rt, cb->at.data()) != 0)
            raise("TypeError", "ctypes: ffi_prep_cif failed for the callback");
        cb->closure = f.closure_alloc(512, &cb->code);
        if (!cb->closure) raise("MemoryError", "ctypes: ffi_closure_alloc failed");
        if (f.prep_closure_loc(cb->closure, cb->cif, ffi_closure_entry, cb.get(), cb->code) != 0) {
            f.closure_free(cb->closure);
            raise("TypeError", "ctypes: ffi_prep_closure_loc failed");
        }
    } else {
#if defined(NY_FFI_SPLIT_REGS) || defined(NY_FFI_WIN64) || defined(NY_FFI_X86)
        // round 84: structures as arguments (classified as call_builtin
        // passes them); a structure result and long double need libffi
        for (auto& s : cb->atypes) {
            if (s[0] == 'g') raise("TypeError", "ctypes: callbacks taking long double need libffi");
#  if defined(NY_FFI_SPLIT_REGS) && defined(__aarch64__)
            if (s[0] == '{' && aapcs_hfa(struct_layout(s))) raise("TypeError", "ctypes: callbacks taking structures of floating-point members need libffi on AArch64");
#  endif
        }
        char rc = cb->rtype[0];
        if (rc == '{' || rc == 'g') raise("TypeError", "ctypes: callbacks returning structures or long double need libffi");
        int kind = rc == 'd' ? 1 : rc == 'f' ? 2 : 0;
        std::lock_guard<std::mutex> l(g_cb_mu);
        int slot = -1;
#  if defined(NY_FFI_SPLIT_REGS)
        for (int k = 0; k < POOL; k++) if (!g_pool[kind][k]) { slot = k; break; }
        if (slot < 0) raise("MemoryError", "ctypes: all " + std::to_string(POOL) + " callback trampolines are in use (libffi: " + f.why + ")");
        g_pool[kind][slot] = cb.get();
        cb->slot = kind * POOL + slot;
        cb->code = Pool::get(kind, slot);
#  elif defined(NY_FFI_WIN64)
        if (cb->atypes.size() > 16) raise("TypeError", "ctypes: callbacks of more than 16 arguments need libffi");
        int mask = 0;
        for (size_t k = 0; k < cb->atypes.size() && k < 4; k++) if (is_float(cb->atypes[k][0])) mask |= 1 << k;
        for (int k = 0; k < POOL; k++) if (!g_pool[kind][mask][k]) { slot = k; break; }
        if (slot < 0) raise("MemoryError", "ctypes: all " + std::to_string(POOL) + " callback trampolines of this shape are in use (libffi: " + f.why + ")");
        g_pool[kind][mask][slot] = cb.get();
        cb->slot = (kind * 16 + mask) * POOL + slot;
        cb->code = pool_code(kind, mask, slot);
#  else
        int words = 0;
        for (auto& s : cb->atypes) words += s[0] == '{' ? (int)((spec_size(s) + 3) / 4) : (type_of(s[0])->size > 4 ? 2 : 1);
        if (words > N_CBW) raise("TypeError", "ctypes: callbacks of more than " + std::to_string(N_CBW) + " argument words need libffi");
        int conv = 0;
        if (flags & F_STDCALL) {
#    if defined(_WIN32)
            if (words > 12) raise("TypeError", "ctypes: a stdcall callback of more than 12 argument words needs libffi");
            conv = 1 + words;
#    else
            raise("TypeError", "ctypes: stdcall callbacks are a Windows convention");
#    endif
        }
        for (int k = 0; k < POOL; k++) if (!g_pool[kind][conv][k]) { slot = k; break; }
        if (slot < 0) raise("MemoryError", "ctypes: all " + std::to_string(POOL) + " callback trampolines of this shape are in use (libffi: " + f.why + ")");
        g_pool[kind][conv][slot] = cb.get();
        cb->slot = (kind * 14 + conv) * POOL + slot;
#    if defined(_WIN32)
        cb->code = conv ? stdcall_code(kind, conv - 1, slot) : Pool::get(kind, slot);
#    else
        cb->code = Pool::get(kind, slot);
#    endif
#  endif
#else
        raise("TypeError", "ctypes: callbacks need libffi on this platform (" + f.why + ")");
#endif
    }
    std::lock_guard<std::mutex> l(g_cb_mu);
    cb->id = (int64_t)g_callbacks.size() + 1;
    int64_t code = (int64_t)(intptr_t)cb->code, id = cb->id;
    g_callbacks.push_back(std::move(cb));
    return Ret::lst({Ret::integer(code), Ret::integer(id)});
}
Ret b_callback_free(Engine&, const Args& a) {
    int64_t id = a.as_int(0);
    std::unique_ptr<Callback> cb;
    {
        std::lock_guard<std::mutex> l(g_cb_mu);
        if (id < 1 || id > (int64_t)g_callbacks.size() || !g_callbacks[(size_t)id - 1]) return Ret::boolean(false);
        cb = std::move(g_callbacks[(size_t)id - 1]);
#if defined(NY_FFI_SPLIT_REGS)
        if (cb->slot >= 0) g_pool[cb->slot / POOL][cb->slot % POOL] = nullptr;
#elif defined(NY_FFI_WIN64)
        if (cb->slot >= 0) g_pool[cb->slot / POOL / 16][cb->slot / POOL % 16][cb->slot % POOL] = nullptr;
#elif defined(NY_FFI_X86)
        if (cb->slot >= 0) g_pool[cb->slot / POOL / 14][cb->slot / POOL % 14][cb->slot % POOL] = nullptr;
#endif
    }
    if (cb->closure) ffi().closure_free(cb->closure);
    return Ret::boolean(true);   // cb (and its function) go with the GIL held: a builtin
}
Ret b_errno(Engine&, const Args& a) {
    int old = t_errno;
    if (a.size() > 0 && a.truthy(0)) t_errno = (int)a.as_int(1);
    return Ret::integer(old);
}
Ret b_last_error(Engine&, const Args& a) {
#ifdef _WIN32
    DWORD old = t_last_error;
    if (a.size() > 0 && a.truthy(0)) t_last_error = (DWORD)a.as_int(1);
    return Ret::integer((int64_t)old);
#else
    (void)a;
    return Ret::integer(0);
#endif
}
Ret b_backend(Engine&, const Args&) {
    Ffi& f = ffi();
    if (f.ok) return Ret::str("libffi");
#if defined(NY_FFI_SPLIT_REGS) || defined(NY_FFI_WIN64) || defined(NY_FFI_X86)
    return Ret::str("builtin: " + f.why);
#else
    return Ret::str("none: " + f.why);
#endif
}
Ret b_cstr(Engine&, const Args& a) {
    // a NUL-terminated copy of bytes in fresh memory (the library frees it)
    std::string s = a.as_bytes(0);
    char* p = (char*)std::malloc(s.size() + 1);
    if (!p) raise("MemoryError", "");
    std::memcpy(p, s.data(), s.size());
    p[s.size()] = 0;
    return Ret::integer((int64_t)(intptr_t)p);
}
Ret b_platform(Engine&, const Args&) {
#if defined(_WIN32)
    const char* os = "win32";
#elif defined(__APPLE__)
    const char* os = "darwin";
#else
    const char* os = "posix";
#endif
    return Ret::lst({Ret::str(os), Ret::integer((int64_t)sizeof(void*)),
#if defined(_WIN32)
                     Ret::integer(0), Ret::integer(0)
#else
                     Ret::integer(RTLD_LOCAL), Ret::integer(RTLD_GLOBAL)
#endif
    });
}

struct Registrar {
    Registrar() {
        struct { const char* n; ExtHandler h; } t[] = {
            {"_ffi_dlopen", b_dlopen}, {"_ffi_dlsym", b_dlsym}, {"_ffi_dlclose", b_dlclose},
            {"_ffi_typeinfo", b_typeinfo}, {"_ffi_alloc", b_alloc}, {"_ffi_free", b_free},
            {"_ffi_realloc", b_realloc}, {"_ffi_get", b_get}, {"_ffi_set", b_set},
            {"_ffi_getbits", b_getbits}, {"_ffi_setbits", b_setbits}, {"_ffi_read", b_read},
            {"_ffi_write", b_write}, {"_ffi_memmove", b_memmove}, {"_ffi_memset", b_memset},
            {"_ffi_strlen", b_strlen}, {"_ffi_wcslen", b_wcslen}, {"_ffi_wencode", b_wencode},
            {"_ffi_wdecode", b_wdecode}, {"_ffi_call", b_call}, {"_ffi_callback", b_callback},
            {"_ffi_callback_free", b_callback_free}, {"_ffi_errno", b_errno},
            {"_ffi_last_error", b_last_error}, {"_ffi_backend", b_backend}, {"_ffi_cstr", b_cstr},
            {"_ffi_platform", b_platform},
        };
        for (auto& x : t) register_extension(x.n, x.h);
    }
};
Registrar g_registrar;

} // namespace

// Referenced from the engines so the linker always keeps this unit (a static
// library would drop an object nothing refers to).
namespace nyffi { int linked() { return 1; } }
