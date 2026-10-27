// builtins/nywin.cpp - Windows' own modules (round 87): the natives behind
// lib/msvcrt.ny, lib/winreg.ny, lib/winsound.ny and lib/_winapi.ny, after
// CPython's PC/msvcrtmodule.c, PC/winreg.c, PC/winsound.c and
// Modules/_winapi.c. Served to both engines by the concurrency runtime's
// dispatcher (nyconc::register_extension); handles cross as ints (the .ny
// modules show them unsigned, as CPython's PyLong_FromVoidPtr does).
//
//   _msvcrt_*    locking, setmode, open_osfhandle, get_osfhandle, kbhit,
//                getch/getwch/getche/getwche, putch/putwch, ungetch/ungetwch,
//                heapmin, GetErrorMode/SetErrorMode, constants
//   _winreg_*    the registry over advapi32: open/create/close/connect,
//                delete key/value, enum key/value, query/set value(ex) with
//                every REG_* conversion (CPython's Reg2Py / Py2Reg), query
//                info, flush, load/save, expand environment strings,
//                reflection (by GetProcAddress), constants
//   _winsound_*  Beep, PlaySound (winmm, loaded at run time), MessageBeep
//   _winapi_*    pipes (anonymous and named, overlapped I/O with an
//                Overlapped record per operation), files, processes
//                (CreateProcess with STARTUPINFO's handles and a handle
//                list), waits, handles, file mappings, the code page,
//                LCMapStringEx, junctions, constants
//
// Errors are CPython's: OSError subclasses chosen by the Windows error's
// errno ("[WinError 2] The system cannot find the file specified" is a
// FileNotFoundError with winerror 2), the messages FormatMessage gives.
// Blocking calls (waits, ConnectNamedPipe, synchronous reads and writes,
// getch) release the GIL. The project targets Vista: newer APIs are looked
// up with GetProcAddress. Nothing here on POSIX (the .ny modules raise
// ModuleNotFoundError there, as CPython's).
#ifdef _WIN32
#include "NyConc.hpp"
#include <winsock2.h>
#include <windows.h>
#include <conio.h>
#include <io.h>
#include <fcntl.h>
#include <sys/locking.h>
#include <malloc.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <mutex>
#include <unordered_map>
#include <algorithm>

namespace {
using namespace nyconc;

[[noreturn]] void raise(const std::string& type, const std::string& msg) { throw NyError::make(type, msg); }

std::wstring W(const std::string& s) {
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}
std::string U(const wchar_t* w, size_t n) {
    if (n == 0) return std::string();
    int k = WideCharToMultiByte(CP_UTF8, 0, w, (int)n, nullptr, 0, nullptr, nullptr);
    std::string s((size_t)k, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, (int)n, &s[0], k, nullptr, nullptr);
    return s;
}
std::string U(const std::wstring& w) { return U(w.data(), w.size()); }

// CPython's winerror_to_errno, then the OSError subclass of that errno
const char* exc_for_winerror(DWORD e) {
    switch (e) {
        case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: case ERROR_INVALID_DRIVE: case ERROR_NO_MORE_FILES:
        case ERROR_BAD_NETPATH: case ERROR_BAD_NET_NAME: case ERROR_BAD_PATHNAME: case ERROR_FILENAME_EXCED_RANGE:
            return "FileNotFoundError";
        case ERROR_ACCESS_DENIED: case ERROR_SHARING_VIOLATION: case ERROR_LOCK_VIOLATION: case ERROR_CURRENT_DIRECTORY:
        case ERROR_NETWORK_ACCESS_DENIED: case ERROR_CANNOT_MAKE: case ERROR_FAIL_I24: case ERROR_DRIVE_LOCKED:
        case ERROR_SEEK_ON_DEVICE: case ERROR_NOT_LOCKED: case ERROR_LOCK_FAILED:
            return "PermissionError";
        case ERROR_FILE_EXISTS: case ERROR_ALREADY_EXISTS: return "FileExistsError";
        case ERROR_BROKEN_PIPE: case ERROR_NO_DATA: return "BrokenPipeError";
        case ERROR_DIRECTORY: return "NotADirectoryError";
        case ERROR_INVALID_HANDLE: case ERROR_INVALID_TARGET_HANDLE: case ERROR_DIRECT_ACCESS_HANDLE: return "OSError";
        case WAIT_TIMEOUT: case ERROR_SEM_TIMEOUT: return "TimeoutError";
        default: return "OSError";
    }
}
std::string win_message(DWORD e) {
    wchar_t* buf = nullptr;
    DWORD n = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                             nullptr, e, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPWSTR)&buf, 0, nullptr);
    std::string s;
    if (n && buf) {
        // trailing white space and the final period go (CPython's)
        while (n > 0 && (buf[n - 1] <= L' ' || buf[n - 1] == L'.')) n--;
        s = U(buf, n);
    }
    if (buf) LocalFree(buf);
    if (s.empty()) s = "Windows Error 0x" + [&] { char b[16]; snprintf(b, sizeof b, "%lx", (unsigned long)e); return std::string(b); }();
    return s;
}
[[noreturn]] void raise_win(DWORD e) {
    raise(exc_for_winerror(e), "[WinError " + std::to_string((unsigned long)e) + "] " + win_message(e));
}
[[noreturn]] void raise_last() { raise_win(GetLastError()); }
[[noreturn]] void raise_errno(int e) {
    const char* t = e == ENOENT ? "FileNotFoundError" : e == EACCES ? "PermissionError" : "OSError";
    raise(t, "[Errno " + std::to_string(e) + "] " + strerror(e));
}

HANDLE H(const Args& a, size_t i) { return (HANDLE)(intptr_t)a.as_int(i); }
HKEY K(const Args& a, size_t i) { return (HKEY)(intptr_t)a.as_int(i); }
Ret RH(HANDLE h) { return Ret::integer((int64_t)(intptr_t)h); }
std::string S(const Args& a, size_t i) { return i < a.size() && !a.is_none(i) ? a.as_str(i) : std::string(); }
int64_t I(const Args& a, size_t i, int64_t d = 0) { return i < a.size() && !a.is_none(i) ? a.as_int(i) : d; }

Ret consts(std::initializer_list<std::pair<const char*, int64_t>> l) {
    std::vector<Ret> out;
    for (auto& p : l) out.push_back(Ret::lst({Ret::str(p.first), Ret::integer(p.second)}));
    return Ret::lst(out);
}
#define C(x) {#x, (int64_t)(x)}
#define CH(x) {#x, (int64_t)(intptr_t)(x)}

// ── msvcrt ──────────────────────────────────────────────────────────────────
Ret m_locking(Engine&, const Args& a) {
    int fd = (int)a.as_int(0), mode = (int)a.as_int(1);
    long n = (long)a.as_int(2);
    int r, err;
    {
        GilRelease unlocked;
        r = _locking(fd, mode, n);
        err = errno;
    }
    if (r != 0) raise_errno(err);
    return Ret::none();
}
Ret m_setmode(Engine&, const Args& a) {
    int r = _setmode((int)a.as_int(0), (int)a.as_int(1));
    if (r == -1) raise_errno(errno);
    return Ret::integer(r);
}
Ret m_open_osfhandle(Engine&, const Args& a) {
    int fd = _open_osfhandle((intptr_t)a.as_int(0), (int)a.as_int(1));
    if (fd == -1) raise_errno(errno);
    return Ret::integer(fd);
}
Ret m_get_osfhandle(Engine&, const Args& a) {
    intptr_t h = _get_osfhandle((int)a.as_int(0));
    if (h == -1) raise_errno(errno);
    return Ret::integer((int64_t)h);
}
Ret m_kbhit(Engine&, const Args&) { return Ret::integer(_kbhit()); }
Ret m_getch(Engine&, const Args& a) {
    std::string which = a.as_str(0);
    if (which == "getch" || which == "getche") {
        int c;
        { GilRelease unlocked; c = which == "getch" ? _getch() : _getche(); }
        return Ret::bytes(std::string(1, (char)c));
    }
    wint_t c;
    { GilRelease unlocked; c = which == "getwch" ? _getwch() : _getwche(); }
    wchar_t w = (wchar_t)c;
    return Ret::str(U(&w, 1));
}
Ret m_putch(Engine&, const Args& a) {
    std::string which = a.as_str(0);
    if (which == "putch") { _putch((unsigned char)a.as_bytes(1)[0]); return Ret::none(); }
    if (which == "ungetch") {
        if (_ungetch((unsigned char)a.as_bytes(1)[0]) == EOF) raise_errno(errno);
        return Ret::none();
    }
    std::wstring w = W(a.as_str(1));
    if (w.size() != 1) raise("TypeError", which + "() argument must be a unicode character, not str");
    if (which == "putwch") { _putwch(w[0]); return Ret::none(); }
    if (_ungetwch(w[0]) == WEOF) raise_errno(errno);
    return Ret::none();
}
Ret m_heapmin(Engine&, const Args&) {
    if (_heapmin() != 0) raise_errno(errno);
    return Ret::none();
}
Ret m_errormode(Engine&, const Args& a) {
    if (a.size() == 0) {
        // GetErrorMode is Vista's: looked up, as the project targets Vista
        typedef UINT(WINAPI * GEM)(void);
        static GEM gem = (GEM)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "GetErrorMode");
        if (gem) return Ret::integer(gem());
        UINT m = SetErrorMode(0);
        SetErrorMode(m);
        return Ret::integer(m);
    }
    return Ret::integer(SetErrorMode((UINT)a.as_int(0)));
}
Ret m_consts(Engine&, const Args&) {
    return consts({C(LK_LOCK), C(LK_NBLCK), C(LK_NBRLCK), C(LK_RLCK), C(LK_UNLCK),
                   C(SEM_FAILCRITICALERRORS), C(SEM_NOALIGNMENTFAULTEXCEPT), C(SEM_NOGPFAULTERRORBOX),
                   C(SEM_NOOPENFILEERRORBOX), {"O_BINARY", _O_BINARY}, {"O_TEXT", _O_TEXT},
                   {"O_WTEXT", _O_WTEXT}, {"O_U8TEXT", _O_U8TEXT}, {"O_U16TEXT", _O_U16TEXT}});
}

// ── winreg ──────────────────────────────────────────────────────────────────
[[noreturn]] void raise_reg(LSTATUS r) { raise_win((DWORD)r); }

Ret reg_to_ret(DWORD type, const std::vector<BYTE>& d, DWORD n) {
    // CPython's Reg2Py
    switch (type) {
        case REG_DWORD: {
            uint32_t v = 0;
            if (n >= 4) memcpy(&v, d.data(), 4);
            return Ret::integer((int64_t)v);
        }
        case REG_QWORD: {
            uint64_t v = 0;
            if (n >= 8) memcpy(&v, d.data(), 8);
            // past 2**63: its digits (the .ny module makes the int)
            if ((int64_t)v < 0) return Ret::str(std::to_string(v));
            return Ret::integer((int64_t)v);
        }
        case REG_SZ: case REG_EXPAND_SZ: {
            const wchar_t* w = (const wchar_t*)d.data();
            size_t len = n / sizeof(wchar_t);
            while (len > 0 && w[len - 1] == 0) len--;
            // CPython stops at the first NUL
            for (size_t i = 0; i < len; i++) if (w[i] == 0) { len = i; break; }
            return Ret::str(U(w, len));
        }
        case REG_MULTI_SZ: {
            const wchar_t* w = (const wchar_t*)d.data();
            size_t len = n / sizeof(wchar_t);
            std::vector<Ret> items;
            size_t i = 0;
            while (i < len) {
                size_t j = i;
                while (j < len && w[j] != 0) j++;
                if (j == i) break;   // the closing empty string
                items.push_back(Ret::str(U(w + i, j - i)));
                i = j + 1;
            }
            return Ret::lst(items);
        }
        default:
            if (n == 0) return Ret::none();
            return Ret::bytes(std::string((const char*)d.data(), n));
    }
}

// value kinds the .ny wrapper sends: ("int", v) ("str", s) ("multi", [s...])
// ("bytes", b) ("none",)
std::vector<BYTE> ret_to_reg(DWORD type, const Args& a, size_t i) {
    std::vector<BYTE> out;
    auto put = [&](const void* p, size_t n) { out.insert(out.end(), (const BYTE*)p, (const BYTE*)p + n); };
    switch (type) {
        case REG_DWORD: { uint32_t v = a.is_none(i) ? 0 : (uint32_t)a.as_int(i); put(&v, 4); break; }
        case REG_QWORD: { uint64_t v = a.is_none(i) ? 0 : (uint64_t)a.as_int(i); put(&v, 8); break; }
        case REG_SZ: case REG_EXPAND_SZ: {
            std::wstring w = a.is_none(i) ? std::wstring() : W(a.as_str(i));
            put(w.c_str(), (w.size() + 1) * sizeof(wchar_t));
            break;
        }
        case REG_MULTI_SZ: {
            if (!a.is_none(i)) {
                auto l = a.list(i);
                for (size_t k = 0; k < l->size(); k++) {
                    std::wstring w = W(l->as_str(k));
                    put(w.c_str(), (w.size() + 1) * sizeof(wchar_t));
                }
            }
            wchar_t z = 0;
            put(&z, sizeof z);
            if (out.size() == sizeof(wchar_t)) put(&z, sizeof z);   // an empty list: two NULs
            break;
        }
        default:
            if (!a.is_none(i)) { std::string b = a.as_bytes(i); put(b.data(), b.size()); }
            break;
    }
    return out;
}

Ret r_open(Engine&, const Args& a) {
    // (key, sub_key, reserved, access, create)
    HKEY key = K(a, 0), out = nullptr;
    std::wstring sub = W(S(a, 1));
    LSTATUS r;
    {
        GilRelease unlocked;
        // create 2: CreateKey, RegCreateKeyW's (the most access allowed, as
        // CPython's); 1: CreateKeyEx with the access asked for
        if (I(a, 4) == 2) r = RegCreateKeyW(key, sub.c_str(), &out);
        else if (I(a, 4)) r = RegCreateKeyExW(key, sub.c_str(), (DWORD)I(a, 2), nullptr, 0, (REGSAM)I(a, 3), nullptr, &out, nullptr);
        else r = RegOpenKeyExW(key, sub.c_str(), (DWORD)I(a, 2), (REGSAM)I(a, 3), &out);
    }
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::integer((int64_t)(intptr_t)out);
}
Ret r_close(Engine&, const Args& a) {
    LSTATUS r = RegCloseKey(K(a, 0));
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::none();
}
Ret r_connect(Engine&, const Args& a) {
    HKEY out = nullptr;
    std::wstring m = W(S(a, 0));
    LSTATUS r;
    { GilRelease unlocked; r = RegConnectRegistryW(a.is_none(0) ? nullptr : m.c_str(), K(a, 1), &out); }
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::integer((int64_t)(intptr_t)out);
}
Ret r_delete_key(Engine&, const Args& a) {
    // (key, sub_key, access, reserved, ex)
    std::wstring sub = W(S(a, 1));
    LSTATUS r;
    if (I(a, 4)) {
        typedef LONG(WINAPI * DKE)(HKEY, LPCWSTR, REGSAM, DWORD);
        static DKE dke = (DKE)(void*)GetProcAddress(GetModuleHandleW(L"advapi32.dll"), "RegDeleteKeyExW");
        if (!dke) raise("NotImplementedError", "not implemented on this platform");
        r = dke(K(a, 0), sub.c_str(), (REGSAM)I(a, 2), (DWORD)I(a, 3));
    } else {
        r = RegDeleteKeyW(K(a, 0), sub.c_str());
    }
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::none();
}
Ret r_delete_value(Engine&, const Args& a) {
    std::wstring v = W(S(a, 1));
    LSTATUS r = RegDeleteValueW(K(a, 0), a.is_none(1) ? nullptr : v.c_str());
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::none();
}
Ret r_enum_key(Engine&, const Args& a) {
    wchar_t name[257];
    DWORD n = 257;
    LSTATUS r = RegEnumKeyExW(K(a, 0), (DWORD)a.as_int(1), name, &n, nullptr, nullptr, nullptr, nullptr);
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::str(U(name, n));
}
Ret r_enum_value(Engine&, const Args& a) {
    HKEY key = K(a, 0);
    DWORD maxname = 0, maxdata = 0;
    LSTATUS r = RegQueryInfoKeyW(key, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, &maxname, &maxdata, nullptr, nullptr);
    if (r != ERROR_SUCCESS) raise_reg(r);
    maxname++;
    if (maxdata == 0) maxdata = 1;
    for (;;) {
        std::vector<wchar_t> name(maxname + 1);
        std::vector<BYTE> data(maxdata + 2);
        DWORD nn = maxname + 1, dn = maxdata, type = 0;
        r = RegEnumValueW(key, (DWORD)a.as_int(1), name.data(), &nn, nullptr, &type, data.data(), &dn);
        if (r == ERROR_MORE_DATA) { maxdata *= 2; maxname *= 2; continue; }
        if (r != ERROR_SUCCESS) raise_reg(r);
        return Ret::lst({Ret::str(U(name.data(), nn)), reg_to_ret(type, data, dn), Ret::integer(type)});
    }
}
Ret r_query_value_ex(Engine&, const Args& a) {
    HKEY key = K(a, 0);
    std::wstring v = W(S(a, 1));
    const wchar_t* vn = a.is_none(1) ? nullptr : v.c_str();
    DWORD size = 256;
    for (;;) {
        std::vector<BYTE> data(size + 2);
        DWORD n = size, type = 0;
        LSTATUS r = RegQueryValueExW(key, vn, nullptr, &type, data.data(), &n);
        if (r == ERROR_MORE_DATA) { size = n > size ? n : size * 2; continue; }
        if (r != ERROR_SUCCESS) raise_reg(r);
        return Ret::lst({reg_to_ret(type, data, n), Ret::integer(type)});
    }
}
Ret r_query_value(Engine&, const Args& a) {
    // RegQueryValueW's (sub_key)'s default value, as a string
    HKEY key = K(a, 0), child = key;
    std::wstring sub = W(S(a, 1));
    if (!a.is_none(1) && !sub.empty()) {
        LSTATUS r = RegOpenKeyExW(key, sub.c_str(), 0, KEY_QUERY_VALUE, &child);
        if (r != ERROR_SUCCESS) raise_reg(r);
    }
    DWORD size = 256;
    std::string out;
    LSTATUS r;
    for (;;) {
        std::vector<BYTE> data(size + 2);
        DWORD n = size, type = 0;
        r = RegQueryValueExW(child, nullptr, nullptr, &type, data.data(), &n);
        if (r == ERROR_MORE_DATA) { size = n > size ? n : size * 2; continue; }
        if (r == ERROR_FILE_NOT_FOUND) { r = ERROR_SUCCESS; out.clear(); break; }   // no default value: ""
        if (r != ERROR_SUCCESS) break;
        if (type != REG_SZ) { r = ERROR_INVALID_DATA; break; }
        const wchar_t* w = (const wchar_t*)data.data();
        size_t len = n / sizeof(wchar_t);
        while (len > 0 && w[len - 1] == 0) len--;
        out = U(w, len);
        break;
    }
    if (child != key) RegCloseKey(child);
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::str(out);
}
Ret r_set_value(Engine&, const Args& a) {
    // (key, sub_key, value): REG_SZ in the sub key's default value
    HKEY key = K(a, 0), child = key;
    std::wstring sub = W(S(a, 1));
    if (!a.is_none(1) && !sub.empty()) {
        LSTATUS r = RegCreateKeyExW(key, sub.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &child, nullptr);
        if (r != ERROR_SUCCESS) raise_reg(r);
    }
    std::wstring v = W(a.as_str(2));
    LSTATUS r = RegSetValueExW(child, nullptr, 0, REG_SZ, (const BYTE*)v.c_str(), (DWORD)((v.size() + 1) * sizeof(wchar_t)));
    if (child != key) RegCloseKey(child);
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::none();
}
Ret r_set_value_ex(Engine&, const Args& a) {
    // (key, name, type, value)
    DWORD type = (DWORD)a.as_int(2);
    std::vector<BYTE> data = ret_to_reg(type, a, 3);
    std::wstring n = W(S(a, 1));
    LSTATUS r = RegSetValueExW(K(a, 0), a.is_none(1) ? nullptr : n.c_str(), 0, type, data.empty() ? nullptr : data.data(), (DWORD)data.size());
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::none();
}
Ret r_query_info(Engine&, const Args& a) {
    DWORD keys = 0, values = 0;
    FILETIME ft;
    LSTATUS r = RegQueryInfoKeyW(K(a, 0), nullptr, nullptr, nullptr, &keys, nullptr, nullptr, &values, nullptr, nullptr, nullptr, &ft);
    if (r != ERROR_SUCCESS) raise_reg(r);
    int64_t t = (int64_t)(((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime);
    return Ret::lst({Ret::integer(keys), Ret::integer(values), Ret::integer(t)});
}
Ret r_flush(Engine&, const Args& a) {
    LSTATUS r;
    { GilRelease unlocked; r = RegFlushKey(K(a, 0)); }
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::none();
}
Ret r_load_save(Engine&, const Args& a) {
    // ("load", key, sub_key, file) / ("save", key, file)
    std::string op = a.as_str(0);
    LSTATUS r;
    if (op == "load") {
        std::wstring sub = W(a.as_str(2)), f = W(a.as_str(3));
        r = RegLoadKeyW(K(a, 1), sub.c_str(), f.c_str());
    } else {
        std::wstring f = W(a.as_str(2));
        r = RegSaveKeyW(K(a, 1), f.c_str(), nullptr);
    }
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::none();
}
Ret r_expand(Engine&, const Args& a) {
    std::wstring s = W(a.as_str(0));
    DWORD n = ExpandEnvironmentStringsW(s.c_str(), nullptr, 0);
    if (n == 0) raise_last();
    std::vector<wchar_t> b(n + 1);
    DWORD m = ExpandEnvironmentStringsW(s.c_str(), b.data(), n + 1);
    if (m == 0) raise_last();
    return Ret::str(U(b.data(), wcslen(b.data())));
}
Ret r_reflection(Engine&, const Args& a) {
    std::string op = a.as_str(0);
    HMODULE adv = GetModuleHandleW(L"advapi32.dll");
    if (op == "query") {
        typedef LONG(WINAPI * QRK)(HKEY, BOOL*);
        QRK f = (QRK)(void*)GetProcAddress(adv, "RegQueryReflectionKey");
        if (!f) raise("NotImplementedError", "not implemented on this platform");
        BOOL res = FALSE;
        LSTATUS r = f(K(a, 1), &res);
        if (r != ERROR_SUCCESS) raise_reg(r);
        return Ret::boolean(res != FALSE);
    }
    typedef LONG(WINAPI * RK)(HKEY);
    RK f = (RK)(void*)GetProcAddress(adv, op == "disable" ? "RegDisableReflectionKey" : "RegEnableReflectionKey");
    if (!f) raise("NotImplementedError", "not implemented on this platform");
    LSTATUS r = f(K(a, 1));
    if (r != ERROR_SUCCESS) raise_reg(r);
    return Ret::none();
}
Ret r_consts(Engine&, const Args&) {
    return consts({CH(HKEY_CLASSES_ROOT), CH(HKEY_CURRENT_USER), CH(HKEY_LOCAL_MACHINE), CH(HKEY_USERS),
                   CH(HKEY_PERFORMANCE_DATA), CH(HKEY_CURRENT_CONFIG), {"HKEY_DYN_DATA", (int64_t)(intptr_t)(HKEY)(ULONG_PTR)((LONG)0x80000006)},
                   C(KEY_QUERY_VALUE), C(KEY_SET_VALUE), C(KEY_CREATE_SUB_KEY), C(KEY_ENUMERATE_SUB_KEYS),
                   C(KEY_NOTIFY), C(KEY_CREATE_LINK), C(KEY_READ), C(KEY_WRITE), C(KEY_EXECUTE),
                   C(KEY_ALL_ACCESS), C(KEY_WOW64_64KEY), C(KEY_WOW64_32KEY),
                   C(REG_OPTION_RESERVED), C(REG_OPTION_NON_VOLATILE), C(REG_OPTION_VOLATILE),
                   C(REG_OPTION_CREATE_LINK), C(REG_OPTION_BACKUP_RESTORE), C(REG_OPTION_OPEN_LINK),
                   C(REG_LEGAL_OPTION), C(REG_CREATED_NEW_KEY), C(REG_OPENED_EXISTING_KEY),
                   C(REG_WHOLE_HIVE_VOLATILE), C(REG_REFRESH_HIVE), C(REG_NO_LAZY_FLUSH),
                   C(REG_NOTIFY_CHANGE_NAME), C(REG_NOTIFY_CHANGE_ATTRIBUTES), C(REG_NOTIFY_CHANGE_LAST_SET),
                   C(REG_NOTIFY_CHANGE_SECURITY), C(REG_LEGAL_CHANGE_FILTER),
                   C(REG_NONE), C(REG_SZ), C(REG_EXPAND_SZ), C(REG_BINARY), C(REG_DWORD),
                   C(REG_DWORD_LITTLE_ENDIAN), C(REG_DWORD_BIG_ENDIAN), C(REG_LINK), C(REG_MULTI_SZ),
                   C(REG_RESOURCE_LIST), C(REG_FULL_RESOURCE_DESCRIPTOR), C(REG_RESOURCE_REQUIREMENTS_LIST),
                   C(REG_QWORD), C(REG_QWORD_LITTLE_ENDIAN)});
}

// ── winsound ────────────────────────────────────────────────────────────────
Ret s_beep(Engine&, const Args& a) {
    DWORD f = (DWORD)a.as_int(0), d = (DWORD)a.as_int(1);
    BOOL ok;
    DWORD err;
    { GilRelease unlocked; ok = Beep(f, d); err = GetLastError(); }
    if (!ok) raise_win(err);
    return Ret::none();
}
Ret s_play(Engine&, const Args& a) {
    // (sound: str | bytes | None, flags)
    typedef BOOL(WINAPI * PSW)(LPCWSTR, HMODULE, DWORD);
    static PSW psw = [] {
        HMODULE m = LoadLibraryW(L"winmm.dll");
        return m ? (PSW)(void*)GetProcAddress(m, "PlaySoundW") : (PSW) nullptr;
    }();
    if (!psw) raise("RuntimeError", "Failed to play sound");
    DWORD flags = (DWORD)a.as_int(1);
    BOOL ok;
    if (a.is_none(0)) {
        GilRelease unlocked;
        ok = psw(nullptr, nullptr, flags);
    } else if (flags & SND_MEMORY) {
        // the bytes stay alive for the call (synchronous: SND_ASYNC is refused)
        std::string b = a.as_bytes(0);
        GilRelease unlocked;
        ok = psw((LPCWSTR)b.data(), nullptr, flags);
    } else {
        std::wstring w = W(a.as_str(0));
        GilRelease unlocked;
        ok = psw(w.c_str(), nullptr, flags);
    }
    if (!ok) raise("RuntimeError", "Failed to play sound");
    return Ret::none();
}
Ret s_message_beep(Engine&, const Args& a) {
    if (!MessageBeep((UINT)a.as_int(0))) raise_last();
    return Ret::none();
}
Ret s_consts(Engine&, const Args&) {
    return consts({C(SND_ALIAS), C(SND_ASYNC), C(SND_FILENAME), C(SND_LOOP), C(SND_MEMORY), C(SND_NODEFAULT),
                   C(SND_NOSTOP), C(SND_NOWAIT), C(SND_PURGE), C(SND_APPLICATION),
                   C(MB_ICONASTERISK), C(MB_ICONEXCLAMATION), C(MB_ICONHAND), C(MB_ICONQUESTION), C(MB_OK)});
}

// ── _winapi ─────────────────────────────────────────────────────────────────
// An overlapped operation: its OVERLAPPED (with an event), the buffer a read
// fills or a write sends, and whether it is still pending. The .ny Overlapped
// object holds its id.
struct Ov {
    OVERLAPPED ov;
    HANDLE handle;
    std::string buf;        // read buffer / data written
    bool pending = false;
    bool read = false;
    DWORD transferred = 0;
    DWORD err = 0;
    bool completed = false;
};
std::mutex ov_mu;
std::unordered_map<int64_t, Ov*> ov_table;
int64_t ov_next = 1;

Ov* ov_get(int64_t id) {
    std::lock_guard<std::mutex> g(ov_mu);
    auto it = ov_table.find(id);
    if (it == ov_table.end()) raise("ValueError", "operation on a released Overlapped object");
    return it->second;
}
int64_t ov_new(HANDLE h, bool read) {
    Ov* o = new Ov();
    memset(&o->ov, 0, sizeof o->ov);
    o->ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!o->ov.hEvent) { delete o; raise_last(); }
    o->handle = h;
    o->read = read;
    std::lock_guard<std::mutex> g(ov_mu);
    int64_t id = ov_next++;
    ov_table[id] = o;
    return id;
}
Ret ov_ret(int64_t id, DWORD err) { return Ret::lst({Ret::integer(id), Ret::integer((int64_t)err)}); }

Ret w_close(Engine&, const Args& a) {
    if (!CloseHandle(H(a, 0))) raise_last();
    return Ret::none();
}
Ret w_create_pipe(Engine&, const Args& a) {
    HANDLE r = nullptr, w = nullptr;
    BOOL ok;
    { GilRelease unlocked; ok = CreatePipe(&r, &w, nullptr, (DWORD)I(a, 0)); }
    if (!ok) raise_last();
    return Ret::lst({RH(r), RH(w)});
}
Ret w_create_named_pipe(Engine&, const Args& a) {
    std::wstring n = W(a.as_str(0));
    HANDLE h;
    { GilRelease unlocked;
      h = CreateNamedPipeW(n.c_str(), (DWORD)a.as_int(1), (DWORD)a.as_int(2), (DWORD)a.as_int(3), (DWORD)a.as_int(4),
                           (DWORD)a.as_int(5), (DWORD)a.as_int(6), nullptr); }
    if (h == INVALID_HANDLE_VALUE) raise_last();
    return RH(h);
}
Ret w_connect_named_pipe(Engine&, const Args& a) {
    HANDLE h = H(a, 0);
    if (I(a, 1)) {
        int64_t id = ov_new(h, false);
        Ov* o = ov_get(id);
        BOOL ok = ConnectNamedPipe(h, &o->ov);
        DWORD err = ok ? 0 : GetLastError();
        if (!ok && err == ERROR_IO_PENDING) o->pending = true;
        else if (!ok && err == ERROR_PIPE_CONNECTED) { SetEvent(o->ov.hEvent); o->completed = true; }
        else if (ok) { o->completed = true; }
        else {
            std::lock_guard<std::mutex> g(ov_mu);
            ov_table.erase(id);
            CloseHandle(o->ov.hEvent);
            delete o;
            raise_win(err);
        }
        return ov_ret(id, err);
    }
    BOOL ok;
    DWORD err;
    { GilRelease unlocked; ok = ConnectNamedPipe(h, nullptr); err = GetLastError(); }
    if (!ok && err != ERROR_PIPE_CONNECTED) raise_win(err);
    return Ret::none();
}
Ret w_create_file(Engine&, const Args& a) {
    std::wstring n = W(a.as_str(0));
    HANDLE h;
    { GilRelease unlocked;
      h = CreateFileW(n.c_str(), (DWORD)a.as_int(1), (DWORD)a.as_int(2), nullptr, (DWORD)a.as_int(3),
                      (DWORD)a.as_int(4), nullptr); }
    if (h == INVALID_HANDLE_VALUE) raise_last();
    return RH(h);
}
Ret w_read_file(Engine&, const Args& a) {
    HANDLE h = H(a, 0);
    DWORD size = (DWORD)a.as_int(1);
    if (I(a, 2)) {
        int64_t id = ov_new(h, true);
        Ov* o = ov_get(id);
        o->buf.assign(size, '\0');
        DWORD n = 0;
        BOOL ok = ReadFile(h, size ? &o->buf[0] : nullptr, size, &n, &o->ov);
        DWORD err = ok ? 0 : GetLastError();
        if (!ok && err == ERROR_IO_PENDING) o->pending = true;
        else {
            o->completed = true;
            o->err = err;
            o->transferred = n;
            if (err && err != ERROR_MORE_DATA && err != ERROR_BROKEN_PIPE) {
                std::lock_guard<std::mutex> g(ov_mu);
                ov_table.erase(id);
                CloseHandle(o->ov.hEvent);
                delete o;
                raise_win(err);
            }
        }
        return ov_ret(id, err);
    }
    std::string buf(size, '\0');
    DWORD n = 0, err = 0;
    BOOL ok;
    { GilRelease unlocked; ok = ReadFile(h, size ? &buf[0] : nullptr, size, &n, nullptr); err = ok ? 0 : GetLastError(); }
    if (!ok && err != ERROR_MORE_DATA) raise_win(err);
    buf.resize(n);
    return Ret::lst({Ret::bytes(buf), Ret::integer((int64_t)err)});
}
Ret w_write_file(Engine&, const Args& a) {
    HANDLE h = H(a, 0);
    std::string data = a.as_bytes(1);
    if (I(a, 2)) {
        int64_t id = ov_new(h, false);
        Ov* o = ov_get(id);
        o->buf = data;
        DWORD n = 0;
        BOOL ok = WriteFile(h, o->buf.data(), (DWORD)o->buf.size(), &n, &o->ov);
        DWORD err = ok ? 0 : GetLastError();
        if (!ok && err == ERROR_IO_PENDING) o->pending = true;
        else {
            o->completed = true; o->err = err; o->transferred = n;
            if (err) {
                std::lock_guard<std::mutex> g(ov_mu);
                ov_table.erase(id);
                CloseHandle(o->ov.hEvent);
                delete o;
                raise_win(err);
            }
        }
        return ov_ret(id, err);
    }
    DWORD n = 0, err = 0;
    BOOL ok;
    { GilRelease unlocked; ok = WriteFile(h, data.data(), (DWORD)data.size(), &n, nullptr); err = ok ? 0 : GetLastError(); }
    if (!ok) raise_win(err);
    return Ret::lst({Ret::integer(n), Ret::integer((int64_t)err)});
}
// Overlapped: ("result", id, wait) -> [n, err]; ("buffer", id); ("cancel", id);
// ("event", id); ("pending", id); ("free", id)
Ret w_overlapped(Engine&, const Args& a) {
    std::string op = a.as_str(0);
    int64_t id = a.as_int(1);
    if (op == "free") {
        Ov* o = nullptr;
        {
            std::lock_guard<std::mutex> g(ov_mu);
            auto it = ov_table.find(id);
            if (it == ov_table.end()) return Ret::none();
            o = it->second;
            ov_table.erase(it);
        }
        if (o->pending) {
            // cancelled and waited for, so the kernel no longer writes into it
            typedef BOOL(WINAPI * CIE)(HANDLE, LPOVERLAPPED);
            static CIE cie = (CIE)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "CancelIoEx");
            if (cie) cie(o->handle, &o->ov); else CancelIo(o->handle);
            DWORD n;
            GilRelease unlocked;
            GetOverlappedResult(o->handle, &o->ov, &n, TRUE);
        }
        CloseHandle(o->ov.hEvent);
        delete o;
        return Ret::none();
    }
    Ov* o = ov_get(id);
    if (op == "event") return RH(o->ov.hEvent);
    if (op == "pending") return Ret::boolean(o->pending);
    if (op == "buffer") {
        if (o->pending) raise("ValueError", "can't get read buffer before GetOverlappedResult() signals the operation completed");
        return Ret::bytes(o->read ? o->buf.substr(0, o->transferred) : o->buf);
    }
    if (op == "cancel") {
        if (o->pending) {
            typedef BOOL(WINAPI * CIE)(HANDLE, LPOVERLAPPED);
            static CIE cie = (CIE)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "CancelIoEx");
            BOOL ok = cie ? cie(o->handle, &o->ov) : CancelIo(o->handle);
            if (!ok && GetLastError() != ERROR_NOT_FOUND) raise_last();
        }
        return Ret::none();
    }
    // result
    if (!o->pending && o->completed) return Ret::lst({Ret::integer(o->transferred), Ret::integer((int64_t)o->err)});
    DWORD n = 0, err = 0;
    BOOL ok;
    bool wait = a.size() > 2 && a.truthy(2);
    { GilRelease unlocked; ok = GetOverlappedResult(o->handle, &o->ov, &n, wait ? TRUE : FALSE); err = ok ? 0 : GetLastError(); }
    if (!ok && err == ERROR_IO_INCOMPLETE) return Ret::lst({Ret::integer(0), Ret::integer((int64_t)err)});
    o->pending = false;
    o->completed = true;
    o->transferred = n;
    o->err = err;
    if (!ok && err != ERROR_MORE_DATA && err != ERROR_OPERATION_ABORTED && err != ERROR_BROKEN_PIPE
        && err != ERROR_PIPE_CONNECTED && err != ERROR_NETNAME_DELETED)
        raise_win(err);
    return Ret::lst({Ret::integer(n), Ret::integer((int64_t)err)});
}
Ret w_peek_named_pipe(Engine&, const Args& a) {
    HANDLE h = H(a, 0);
    DWORD size = (DWORD)I(a, 1), navail = 0, nleft = 0, nread = 0;
    if (size) {
        std::string buf(size, '\0');
        if (!PeekNamedPipe(h, &buf[0], size, &nread, &navail, &nleft)) raise_last();
        buf.resize(nread);
        return Ret::lst({Ret::bytes(buf), Ret::integer(navail), Ret::integer(nleft)});
    }
    if (!PeekNamedPipe(h, nullptr, 0, nullptr, &navail, &nleft)) raise_last();
    return Ret::lst({Ret::integer(navail), Ret::integer(nleft)});
}
Ret w_set_named_pipe_state(Engine&, const Args& a) {
    DWORD mode = (DWORD)I(a, 1), count = (DWORD)I(a, 2), timeout = (DWORD)I(a, 3);
    if (!SetNamedPipeHandleState(H(a, 0), a.is_none(1) ? nullptr : &mode, a.is_none(2) ? nullptr : &count,
                                 a.is_none(3) ? nullptr : &timeout))
        raise_last();
    return Ret::none();
}
Ret w_wait_named_pipe(Engine&, const Args& a) {
    std::wstring n = W(a.as_str(0));
    BOOL ok;
    DWORD err;
    { GilRelease unlocked; ok = WaitNamedPipeW(n.c_str(), (DWORD)a.as_int(1)); err = GetLastError(); }
    if (!ok) raise_win(err);
    return Ret::none();
}
Ret w_wait_single(Engine&, const Args& a) {
    DWORD r;
    { GilRelease unlocked; r = WaitForSingleObject(H(a, 0), (DWORD)a.as_int(1)); }
    if (r == WAIT_FAILED) raise_last();
    return Ret::integer(r);
}
Ret w_wait_multiple(Engine&, const Args& a) {
    auto l = a.list(0);
    std::vector<HANDLE> hs;
    for (size_t i = 0; i < l->size(); i++) hs.push_back((HANDLE)(intptr_t)l->as_int(i));
    if (hs.size() > MAXIMUM_WAIT_OBJECTS - 1) raise("ValueError", "need at most 63 handles, got a sequence of length " + std::to_string(hs.size()));
    DWORD r;
    { GilRelease unlocked; r = WaitForMultipleObjects((DWORD)hs.size(), hs.data(), a.truthy(1) ? TRUE : FALSE, (DWORD)a.as_int(2)); }
    if (r == WAIT_FAILED) raise_last();
    return Ret::integer(r);
}
Ret w_process(Engine&, const Args& a) {
    // (op, ...): current / open(access, inherit, pid) / exitcode(h) /
    // terminate(h, code) / exit(code) / duplicate(sp, sh, tp, access, inherit, options)
    std::string op = a.as_str(0);
    if (op == "current") return RH(GetCurrentProcess());
    if (op == "open") {
        HANDLE h = OpenProcess((DWORD)a.as_int(1), a.truthy(2), (DWORD)a.as_int(3));
        if (!h) raise_last();
        return RH(h);
    }
    if (op == "exitcode") {
        DWORD c = 0;
        if (!GetExitCodeProcess(H(a, 1), &c)) raise_last();
        return Ret::integer((int64_t)c);
    }
    if (op == "terminate") {
        if (!TerminateProcess(H(a, 1), (UINT)a.as_int(2))) {
            DWORD err = GetLastError();
            // a process already gone: CPython ignores ERROR_ACCESS_DENIED then
            DWORD c = 0;
            if (!(err == ERROR_ACCESS_DENIED && GetExitCodeProcess(H(a, 1), &c) && c != STILL_ACTIVE)) raise_win(err);
        }
        return Ret::none();
    }
    if (op == "exit") { ExitProcess((UINT)a.as_int(1)); }
    if (op == "duplicate") {
        HANDLE out = nullptr;
        if (!DuplicateHandle(H(a, 1), H(a, 2), H(a, 3), &out, (DWORD)a.as_int(4), a.truthy(5), (DWORD)I(a, 6)))
            raise_last();
        return RH(out);
    }
    raise("ValueError", "unknown process operation " + op);
}
std::wstring quote_env(const Args& env) {
    // the environment block: "k=v\0...\0\0", sorted case-insensitively as
    // CreateProcess expects
    std::vector<std::wstring> items;
    for (size_t i = 0; i < env.size(); i++) items.push_back(W(env.as_str(i)));
    std::sort(items.begin(), items.end(), [](const std::wstring& x, const std::wstring& y) {
        return _wcsicmp(x.c_str(), y.c_str()) < 0;
    });
    std::wstring block;
    for (auto& s : items) { block += s; block.push_back(L'\0'); }
    if (items.empty()) block.push_back(L'\0');
    block.push_back(L'\0');
    return block;
}
Ret w_create_process(Engine&, const Args& a) {
    // (app_name, cmd_line, inherit, flags, env [k=v...] | None, cwd, startup
    // [dwFlags, hStdInput, hStdOutput, hStdError, wShowWindow], handle_list)
    std::wstring app = W(S(a, 0)), cmd = W(S(a, 1)), cwd = W(S(a, 5));
    std::wstring envb;
    bool has_env = !a.is_none(4);
    if (has_env) envb = quote_env(*a.list(4));
    STARTUPINFOEXW si;
    memset(&si, 0, sizeof si);
    si.StartupInfo.cb = sizeof si.StartupInfo;
    if (!a.is_none(6)) {
        auto s = a.list(6);
        si.StartupInfo.dwFlags = (DWORD)s->as_int(0);
        si.StartupInfo.hStdInput = (HANDLE)(intptr_t)s->as_int(1);
        si.StartupInfo.hStdOutput = (HANDLE)(intptr_t)s->as_int(2);
        si.StartupInfo.hStdError = (HANDLE)(intptr_t)s->as_int(3);
        si.StartupInfo.wShowWindow = (WORD)s->as_int(4);
    }
    DWORD flags = (DWORD)a.as_int(3) | CREATE_UNICODE_ENVIRONMENT;
    std::vector<HANDLE> handles;
    std::vector<char> attr_buf;
    typedef BOOL(WINAPI * IPTAL)(LPPROC_THREAD_ATTRIBUTE_LIST, DWORD, DWORD, PSIZE_T);
    typedef BOOL(WINAPI * UPTA)(LPPROC_THREAD_ATTRIBUTE_LIST, DWORD, DWORD_PTR, PVOID, SIZE_T, PVOID, PSIZE_T);
    typedef VOID(WINAPI * DPTAL)(LPPROC_THREAD_ATTRIBUTE_LIST);
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    static IPTAL iptal = (IPTAL)(void*)GetProcAddress(k32, "InitializeProcThreadAttributeList");
    static UPTA upta = (UPTA)(void*)GetProcAddress(k32, "UpdateProcThreadAttribute");
    static DPTAL dptal = (DPTAL)(void*)GetProcAddress(k32, "DeleteProcThreadAttributeList");
    bool attrs = false;
    if (a.size() > 7 && !a.is_none(7) && iptal && upta && dptal) {
        auto l = a.list(7);
        for (size_t i = 0; i < l->size(); i++) handles.push_back((HANDLE)(intptr_t)l->as_int(i));
        if (!handles.empty()) {
            SIZE_T sz = 0;
            iptal(nullptr, 1, 0, &sz);
            attr_buf.resize(sz);
            si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)attr_buf.data();
            if (!iptal(si.lpAttributeList, 1, 0, &sz)) raise_last();
            if (!upta(si.lpAttributeList, 0, 0x00020002 /* PROC_THREAD_ATTRIBUTE_HANDLE_LIST */, handles.data(),
                      handles.size() * sizeof(HANDLE), nullptr, nullptr)) {
                DWORD e = GetLastError();
                dptal(si.lpAttributeList);
                raise_win(e);
            }
            attrs = true;
            flags |= EXTENDED_STARTUPINFO_PRESENT;
            si.StartupInfo.cb = sizeof si;
        }
    }
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof pi);
    std::vector<wchar_t> cmdbuf(cmd.begin(), cmd.end());
    cmdbuf.push_back(0);
    BOOL ok;
    DWORD err;
    {
        GilRelease unlocked;
        ok = CreateProcessW(a.is_none(0) ? nullptr : app.c_str(), a.is_none(1) ? nullptr : cmdbuf.data(), nullptr, nullptr,
                            a.truthy(2) ? TRUE : FALSE, flags, has_env ? (LPVOID)envb.data() : nullptr,
                            a.is_none(5) ? nullptr : cwd.c_str(), (LPSTARTUPINFOW)&si, &pi);
        err = GetLastError();
    }
    if (attrs) dptal(si.lpAttributeList);
    if (!ok) raise_win(err);
    return Ret::lst({RH(pi.hProcess), RH(pi.hThread), Ret::integer(pi.dwProcessId), Ret::integer(pi.dwThreadId)});
}
Ret w_misc(Engine&, const Args& a) {
    // GetACP, GetFileType, GetStdHandle, GetLastError, GetModuleFileName,
    // GetVersion, NeedCurrentDirectoryForExePath, GetLongPathName,
    // GetShortPathName, CreateJunction
    std::string op = a.as_str(0);
    if (op == "GetACP") return Ret::integer(GetACP());
    if (op == "GetFileType") {
        DWORD t = GetFileType(H(a, 1));
        if (t == FILE_TYPE_UNKNOWN && GetLastError() != NO_ERROR) raise_last();
        return Ret::integer(t);
    }
    if (op == "GetStdHandle") {
        HANDLE h = GetStdHandle((DWORD)a.as_int(1));
        if (h == INVALID_HANDLE_VALUE) raise_last();
        if (!h) return Ret::none();
        return RH(h);
    }
    if (op == "GetLastError") return Ret::integer(GetLastError());
    if (op == "GetModuleFileName") {
        wchar_t b[32768];
        DWORD n = GetModuleFileNameW((HMODULE)H(a, 1), b, 32768);
        if (!n) raise_last();
        return Ret::str(U(b, n));
    }
    if (op == "GetVersion") {
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#endif
        return Ret::integer(GetVersion());
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
    }
    if (op == "NeedCurrentDirectoryForExePath") {
        typedef BOOL(WINAPI * N)(LPCWSTR);
        static N f = (N)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "NeedCurrentDirectoryForExePathW");
        std::wstring s = W(a.as_str(1));
        return Ret::boolean(f ? f(s.c_str()) != FALSE : true);
    }
    if (op == "GetLongPathName" || op == "GetShortPathName") {
        std::wstring s = W(a.as_str(1));
        DWORD n = op == "GetLongPathName" ? GetLongPathNameW(s.c_str(), nullptr, 0) : GetShortPathNameW(s.c_str(), nullptr, 0);
        if (!n) raise_last();
        std::vector<wchar_t> b(n + 1);
        n = op == "GetLongPathName" ? GetLongPathNameW(s.c_str(), b.data(), n + 1) : GetShortPathNameW(s.c_str(), b.data(), n + 1);
        if (!n) raise_last();
        return Ret::str(U(b.data(), n));
    }
    if (op == "CreateJunction") {
        // a directory junction: a reparse point naming the target's NT path
        std::wstring src = W(a.as_str(1)), dst = W(a.as_str(2));
        wchar_t full[MAX_PATH * 4];
        DWORD n = GetFullPathNameW(src.c_str(), MAX_PATH * 4, full, nullptr);
        if (!n) raise_last();
        std::wstring print(full, n);
        std::wstring sub = L"\\??\\" + print;
        if (!CreateDirectoryW(dst.c_str(), nullptr)) raise_last();
        HANDLE h = CreateFileW(dst.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                               FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
        if (h == INVALID_HANDLE_VALUE) { DWORD e = GetLastError(); RemoveDirectoryW(dst.c_str()); raise_win(e); }
        size_t subb = sub.size() * 2, printb = print.size() * 2;
        std::vector<BYTE> buf(8 + 8 + subb + 2 + printb + 2);
        DWORD tag = 0xA0000003;   // IO_REPARSE_TAG_MOUNT_POINT
        WORD datalen = (WORD)(8 + subb + 2 + printb + 2);
        memcpy(&buf[0], &tag, 4);
        memcpy(&buf[4], &datalen, 2);
        WORD v[4] = {0, (WORD)subb, (WORD)(subb + 2), (WORD)printb};
        memcpy(&buf[8], v, 8);
        memcpy(&buf[16], sub.data(), subb);
        memcpy(&buf[16 + subb + 2], print.data(), printb);
        DWORD ret = 0;
        BOOL ok = DeviceIoControl(h, 0x000900A4 /* FSCTL_SET_REPARSE_POINT */, buf.data(), (DWORD)buf.size(), nullptr, 0, &ret, nullptr);
        DWORD e = GetLastError();
        CloseHandle(h);
        if (!ok) { RemoveDirectoryW(dst.c_str()); raise_win(e); }
        return Ret::none();
    }
    if (op == "LCMapStringEx") {
        typedef int(WINAPI * L)(LPCWSTR, DWORD, LPCWSTR, int, LPWSTR, int, LPNLSVERSIONINFO, LPVOID, LPARAM);
        static L f = (L)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LCMapStringEx");
        if (!f) raise("NotImplementedError", "LCMapStringEx");
        std::wstring loc = W(a.as_str(1)), src = W(a.as_str(3));
        DWORD flags = (DWORD)a.as_int(2);
        int n = f(loc.empty() ? nullptr : loc.c_str(), flags, src.c_str(), (int)src.size(), nullptr, 0, nullptr, nullptr, 0);
        if (n <= 0) raise_last();
        std::vector<wchar_t> b((size_t)n + 1);
        n = f(loc.empty() ? nullptr : loc.c_str(), flags, src.c_str(), (int)src.size(), b.data(), n, nullptr, nullptr, 0);
        if (n <= 0) raise_last();
        return Ret::str(U(b.data(), (size_t)n));
    }
    if (op == "SetEvent" || op == "ResetEvent") {
        BOOL ok = op == "SetEvent" ? SetEvent(H(a, 1)) : ResetEvent(H(a, 1));
        if (!ok) raise_last();
        return Ret::none();
    }
    if (op == "CreateEvent") {
        HANDLE h = CreateEventW(nullptr, a.truthy(1), a.truthy(2), nullptr);
        if (!h) raise_last();
        return RH(h);
    }
    raise("ValueError", "unknown operation " + op);
}
Ret w_mapping(Engine&, const Args& a) {
    // ("create", file_handle, protect, size_hi, size_lo, name|None)
    // ("open", access, inherit, name) ("map", h, access, off_hi, off_lo, size)
    // ("unmap", address) ("size", address)
    std::string op = a.as_str(0);
    if (op == "create") {
        std::wstring n = W(S(a, 5));
        HANDLE h = CreateFileMappingW(H(a, 1), nullptr, (DWORD)a.as_int(2), (DWORD)a.as_int(3), (DWORD)a.as_int(4),
                                      a.is_none(5) ? nullptr : n.c_str());
        if (!h) raise_last();
        return RH(h);
    }
    if (op == "open") {
        std::wstring n = W(a.as_str(3));
        HANDLE h = OpenFileMappingW((DWORD)a.as_int(1), a.truthy(2), n.c_str());
        if (!h) raise_last();
        return RH(h);
    }
    if (op == "map") {
        LPVOID p = MapViewOfFile(H(a, 1), (DWORD)a.as_int(2), (DWORD)a.as_int(3), (DWORD)a.as_int(4), (SIZE_T)a.as_int(5));
        if (!p) raise_last();
        return Ret::integer((int64_t)(intptr_t)p);
    }
    if (op == "unmap") {
        if (!UnmapViewOfFile((LPCVOID)(intptr_t)a.as_int(1))) raise_last();
        return Ret::none();
    }
    if (op == "size") {
        MEMORY_BASIC_INFORMATION mi;
        if (!VirtualQuery((LPCVOID)(intptr_t)a.as_int(1), &mi, sizeof mi)) raise_last();
        return Ret::integer((int64_t)mi.RegionSize);
    }
    raise("ValueError", "unknown mapping operation " + op);
}
Ret w_consts(Engine&, const Args&) {
    return consts({
        C(ABOVE_NORMAL_PRIORITY_CLASS), C(BELOW_NORMAL_PRIORITY_CLASS), C(HIGH_PRIORITY_CLASS),
        C(IDLE_PRIORITY_CLASS), C(NORMAL_PRIORITY_CLASS), C(REALTIME_PRIORITY_CLASS),
        C(CREATE_NEW_CONSOLE), C(CREATE_NEW_PROCESS_GROUP), C(CREATE_DEFAULT_ERROR_MODE),
        C(CREATE_BREAKAWAY_FROM_JOB), C(CREATE_NO_WINDOW), C(DETACHED_PROCESS), C(CREATE_UNICODE_ENVIRONMENT),
        C(DUPLICATE_CLOSE_SOURCE), C(DUPLICATE_SAME_ACCESS),
        C(ERROR_ACCESS_DENIED), C(ERROR_ALREADY_EXISTS), C(ERROR_BROKEN_PIPE), C(ERROR_IO_PENDING),
        C(ERROR_MORE_DATA), C(ERROR_NETNAME_DELETED), C(ERROR_NO_DATA), C(ERROR_NO_SYSTEM_RESOURCES),
        C(ERROR_OPERATION_ABORTED), C(ERROR_PIPE_BUSY), C(ERROR_PIPE_CONNECTED), C(ERROR_SEM_TIMEOUT),
        C(ERROR_PRIVILEGE_NOT_HELD), C(ERROR_NOT_ENOUGH_MEMORY), C(ERROR_INVALID_PARAMETER),
        C(FILE_FLAG_FIRST_PIPE_INSTANCE), C(FILE_FLAG_OVERLAPPED), C(FILE_GENERIC_READ), C(FILE_GENERIC_WRITE),
        C(FILE_MAP_ALL_ACCESS), C(FILE_MAP_COPY), C(FILE_MAP_EXECUTE), C(FILE_MAP_READ), C(FILE_MAP_WRITE),
        C(FILE_TYPE_CHAR), C(FILE_TYPE_DISK), C(FILE_TYPE_PIPE), C(FILE_TYPE_REMOTE), C(FILE_TYPE_UNKNOWN),
        C(GENERIC_READ), C(GENERIC_WRITE), C(INFINITE), C(NMPWAIT_WAIT_FOREVER), C(OPEN_EXISTING),
        C(PIPE_ACCESS_DUPLEX), C(PIPE_ACCESS_INBOUND), C(PIPE_ACCESS_OUTBOUND), C(PIPE_READMODE_MESSAGE),
        C(PIPE_READMODE_BYTE), C(PIPE_TYPE_MESSAGE), C(PIPE_TYPE_BYTE), C(PIPE_UNLIMITED_INSTANCES), C(PIPE_WAIT),
        C(PIPE_NOWAIT), C(PROCESS_ALL_ACCESS), C(PROCESS_DUP_HANDLE), C(SYNCHRONIZE), C(PROCESS_TERMINATE),
        C(PROCESS_QUERY_INFORMATION),
        C(MEM_COMMIT), C(MEM_FREE), C(MEM_IMAGE), C(MEM_MAPPED), C(MEM_PRIVATE), C(MEM_RESERVE),
        C(PAGE_EXECUTE), C(PAGE_EXECUTE_READ), C(PAGE_EXECUTE_READWRITE), C(PAGE_EXECUTE_WRITECOPY),
        C(PAGE_GUARD), C(PAGE_NOACCESS), C(PAGE_NOCACHE), C(PAGE_READONLY), C(PAGE_READWRITE),
        C(PAGE_WRITECOMBINE), C(PAGE_WRITECOPY), C(SEC_COMMIT), C(SEC_IMAGE), C(SEC_LARGE_PAGES),
        C(SEC_NOCACHE), C(SEC_RESERVE), C(SEC_WRITECOMBINE),
        C(STARTF_USESHOWWINDOW), C(STARTF_USESTDHANDLES), C(STD_INPUT_HANDLE), C(STD_OUTPUT_HANDLE),
        C(STD_ERROR_HANDLE), C(STILL_ACTIVE), C(SW_HIDE), C(WAIT_OBJECT_0), C(WAIT_ABANDONED_0),
        C(WAIT_TIMEOUT), C(WAIT_FAILED), C(LCMAP_LOWERCASE), C(LCMAP_UPPERCASE), C(LCMAP_FULLWIDTH),
        C(LCMAP_HALFWIDTH), C(LCMAP_HIRAGANA), C(LCMAP_KATAKANA), C(LCMAP_LINGUISTIC_CASING),
        C(LCMAP_SIMPLIFIED_CHINESE), C(LCMAP_TRADITIONAL_CHINESE), {"LCMAP_TITLECASE", 0x00000300},  // (Windows 7's: not in the Vista headers)
        {"NULL", 0}, {"INVALID_HANDLE_VALUE", (int64_t)(intptr_t)INVALID_HANDLE_VALUE},
        C(CREATE_ALWAYS), C(CREATE_NEW), C(OPEN_ALWAYS), C(TRUNCATE_EXISTING),
        C(FILE_SHARE_READ), C(FILE_SHARE_WRITE), C(FILE_SHARE_DELETE), C(FILE_ATTRIBUTE_NORMAL),
    });
}

struct Registrar {
    Registrar() {
        struct { const char* n; ExtHandler h; } t[] = {
            {"_msvcrt_locking", m_locking}, {"_msvcrt_setmode", m_setmode}, {"_msvcrt_open_osfhandle", m_open_osfhandle},
            {"_msvcrt_get_osfhandle", m_get_osfhandle}, {"_msvcrt_kbhit", m_kbhit}, {"_msvcrt_getch", m_getch},
            {"_msvcrt_putch", m_putch}, {"_msvcrt_heapmin", m_heapmin}, {"_msvcrt_errormode", m_errormode},
            {"_msvcrt_consts", m_consts},
            {"_winreg_open", r_open}, {"_winreg_close", r_close}, {"_winreg_connect", r_connect},
            {"_winreg_delete_key", r_delete_key}, {"_winreg_delete_value", r_delete_value},
            {"_winreg_enum_key", r_enum_key}, {"_winreg_enum_value", r_enum_value},
            {"_winreg_query_value_ex", r_query_value_ex}, {"_winreg_query_value", r_query_value},
            {"_winreg_set_value", r_set_value}, {"_winreg_set_value_ex", r_set_value_ex},
            {"_winreg_query_info", r_query_info}, {"_winreg_flush", r_flush}, {"_winreg_load_save", r_load_save},
            {"_winreg_expand", r_expand}, {"_winreg_reflection", r_reflection}, {"_winreg_consts", r_consts},
            {"_winsound_beep", s_beep}, {"_winsound_play", s_play}, {"_winsound_message_beep", s_message_beep},
            {"_winsound_consts", s_consts},
            {"_winapi_close", w_close}, {"_winapi_create_pipe", w_create_pipe},
            {"_winapi_create_named_pipe", w_create_named_pipe}, {"_winapi_connect_named_pipe", w_connect_named_pipe},
            {"_winapi_create_file", w_create_file}, {"_winapi_read_file", w_read_file},
            {"_winapi_write_file", w_write_file}, {"_winapi_overlapped", w_overlapped},
            {"_winapi_peek_named_pipe", w_peek_named_pipe}, {"_winapi_set_named_pipe_state", w_set_named_pipe_state},
            {"_winapi_wait_named_pipe", w_wait_named_pipe}, {"_winapi_wait_single", w_wait_single},
            {"_winapi_wait_multiple", w_wait_multiple}, {"_winapi_process", w_process},
            {"_winapi_create_process", w_create_process}, {"_winapi_misc", w_misc}, {"_winapi_mapping", w_mapping},
            {"_winapi_consts", w_consts},
        };
        for (auto& x : t) register_extension(x.n, x.h);
    }
};
Registrar g_registrar;

} // namespace
#endif // _WIN32
