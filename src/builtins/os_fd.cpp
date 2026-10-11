#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/os_fd.cpp (round 80)
// The rest of Python's os module that needs the operating system: file
// descriptors (os.open/read/write/close/pipe/dup/dup2/fdopen/lseek/...),
// process and user ids, ownership, FIFOs and device numbers, the load
// average and CPU affinity, os.scandir's directory listing, the password
// and group databases (lib/pwd.ny, lib/grp.ny) and named shared-memory
// segments (lib/multiprocessing's Value/Array/SharedMemory).
//
// Reached as `_ny_os_call(op, ...)` (os.cpp forwards every op it does not
// know here); the os namespace's members are the prelude's wrappers in the
// "os" chunk (NyPrelude.hpp), loaded on the first `import os`. Every
// failure raises the OSError subclass of its errno, with errno, strerror
// and the file name, as Python's os functions do. A wait (read, write)
// releases the GIL.
// ─────────────────────────────────────────────────────────────────────────────

#include "platform_compat.hpp"

#include <cerrno>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <algorithm>

#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include "NyConc.hpp"
#include "NyRuntime.hpp"

#ifndef _WIN32
#  include <unistd.h>
#  include <fcntl.h>
#  include <sys/stat.h>
#  include <sys/types.h>
#  include <sys/mman.h>
#  include <dirent.h>
#  include <pwd.h>
#  include <grp.h>
#  include <stdlib.h>
#  if defined(__linux__)
#    include <sys/sysmacros.h>
#    include <sched.h>
#  endif
#else
#  include <io.h>
#  include <fcntl.h>
#  include <sys/stat.h>
#  include <dirent.h>
#  include <windows.h>
#endif

using namespace nython;
using namespace nython::kernel;

namespace {

using nyos::raise;
using nyos::raise_errno;
using nyos::make_int;
using nyos::make_list;

#ifdef _WIN32
std::wstring widen(const std::string& s) {
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}
int win_errno(DWORD e) {
    switch (e) {
        case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: return ENOENT;
        case ERROR_ACCESS_DENIED: case ERROR_SHARING_VIOLATION: return EACCES;
        case ERROR_ALREADY_EXISTS: case ERROR_FILE_EXISTS: return EEXIST;
        case ERROR_INVALID_HANDLE: return EBADF;
        case ERROR_NOT_ENOUGH_MEMORY: case ERROR_OUTOFMEMORY: return ENOMEM;
        case ERROR_BROKEN_PIPE: return EPIPE;
        default: return EINVAL;
    }
}
#endif

Value tuple_of(NythonExecutor& E, const std::vector<Value>& items) {
    Value t = make_list(E, items);
    if (auto* o = dynamic_cast<Object*>((Collectable*)t.value.p)) o->set("__tuple__", Value(1));
    return t;
}

// A file descriptor argument: an int, or a file object's handle (open()'s
// fileno() is the runtime's handle number, 1000 up), which stands for its
// FILE's descriptor.
int fd_arg(NythonExecutor& E, const Value& v) {
    if (v.type != ValueType::INTEGER && v.type != ValueType::BOOLEAN) {
        raise("TypeError", "an integer is required (got type " + E.typeNameOf(v) + ")");
    }
    long long fd = nyos::to_int(v, -1);
    if (fd >= 1000) {
        auto it = E.file_handles.find((int)fd);
        if (it != E.file_handles.end() && it->second) {
            std::fflush(it->second);
            return ::fileno(it->second);
        }
    }
    if (fd < INT32_MIN || fd > INT32_MAX) raise("OverflowError", "fd is greater than maximum");
    return (int)fd;
}

std::string bytes_arg(NythonExecutor& E, const Value& v) {
    if (auto* bo = E.bytesOf(v)) return bo->s;
    raise("TypeError", "a bytes-like object is required, not '" + E.typeNameOf(v) + "'");
}

// ── shared-memory segments (a file mapped by every process that opens it) ──
struct Segment {
    char* base = nullptr;
    size_t size = 0;
#ifdef _WIN32
    HANDLE file = INVALID_HANDLE_VALUE, map = nullptr;
#endif
};
std::mutex& seg_mutex() { static std::mutex m; return m; }
std::map<long long, Segment>& segments() { static std::map<long long, Segment> s; return s; }
long long next_segment = 1;

Segment& segment_of(long long id) {
    auto it = segments().find(id);
    if (it == segments().end()) raise("ValueError", "shared memory segment is closed");
    return it->second;
}

#ifndef _WIN32
char kind_of(unsigned char t) {
    switch (t) {
#ifdef DT_DIR
        case DT_DIR: return 'd';
        case DT_REG: return 'f';
        case DT_LNK: return 'l';
        case DT_UNKNOWN: return '?';
#endif
        default: return 'o';
    }
}
Value passwd_tuple(NythonExecutor& E, const struct passwd* p) {
    auto S = [&](const char* s) { return E.makeStringValue(s ? s : ""); };
    return tuple_of(E, {S(p->pw_name), S(p->pw_passwd), make_int((long long)p->pw_uid), make_int((long long)p->pw_gid),
                        S(p->pw_gecos), S(p->pw_dir), S(p->pw_shell)});
}
Value group_tuple(NythonExecutor& E, const struct group* g) {
    std::vector<Value> mem;
    for (char** m = g->gr_mem; m && *m; m++) mem.push_back(E.makeStringValue(*m));
    return tuple_of(E, {E.makeStringValue(g->gr_name ? g->gr_name : ""), E.makeStringValue(g->gr_passwd ? g->gr_passwd : ""),
                        make_int((long long)g->gr_gid), make_list(E, mem)});
}
std::mutex& pwd_mutex() { static std::mutex m; return m; }
#endif

} // namespace

namespace nyos {

// `_ny_os_call(op, a1, a2, ...)`: args[0] is op. UNDEFINED_VALUE for an op
// not handled here.
Value os_call_ext(NythonExecutor& E, const std::string& op, std::vector<Value>& args) {
    auto A = [&](size_t i) -> Value { return i + 1 < args.size() ? args[i + 1] : NONE_VALUE; };
    auto I = [&](size_t i, long long d) -> long long { return i + 1 < args.size() ? to_int(args[i + 1], d) : d; };
    auto S = [&](size_t i) -> std::string { return i + 1 < args.size() ? E.getStringValue(args[i + 1]) : std::string(); };
    auto B = [&](size_t i) -> bool { return i + 1 < args.size() && E.isTruthy(args[i + 1]); };
    auto Str = [&](const std::string& s) { return E.makeStringValue(s); };

    // ── the platform's constants: [(name, value), ...] ─────────────────────
    if (op == "constants") {
        std::vector<Value> out;
        auto C = [&](const char* n, long long v) { out.push_back(tuple_of(E, {Str(n), make_int(v)})); };
        C("O_RDONLY", O_RDONLY); C("O_WRONLY", O_WRONLY); C("O_RDWR", O_RDWR); C("O_APPEND", O_APPEND);
        C("O_CREAT", O_CREAT); C("O_EXCL", O_EXCL); C("O_TRUNC", O_TRUNC);
#ifdef _WIN32
        C("O_BINARY", O_BINARY); C("O_TEXT", O_TEXT); C("O_NOINHERIT", O_NOINHERIT);
        C("O_TEMPORARY", _O_TEMPORARY); C("O_RANDOM", _O_RANDOM); C("O_SEQUENTIAL", _O_SEQUENTIAL);
        C("O_SHORT_LIVED", _O_SHORT_LIVED);
#else
        C("O_NONBLOCK", O_NONBLOCK); C("O_NDELAY", O_NDELAY); C("O_SYNC", O_SYNC); C("O_NOCTTY", O_NOCTTY);
        C("O_CLOEXEC", O_CLOEXEC); C("O_NOFOLLOW", O_NOFOLLOW); C("O_DIRECTORY", O_DIRECTORY);
        C("O_ACCMODE", O_ACCMODE);
#  ifdef O_DSYNC
        C("O_DSYNC", O_DSYNC);
#  endif
#  ifdef O_RSYNC
        C("O_RSYNC", O_RSYNC);
#  endif
#  ifdef O_ASYNC
        C("O_ASYNC", O_ASYNC);
#  endif
#  ifdef O_NOATIME
        C("O_NOATIME", O_NOATIME);
#  endif
#  ifdef O_PATH
        C("O_PATH", O_PATH);
#  endif
#  ifdef O_TMPFILE
        C("O_TMPFILE", O_TMPFILE);
#  endif
#  ifdef O_DIRECT
        C("O_DIRECT", O_DIRECT);
#  endif
#  ifdef O_LARGEFILE
        C("O_LARGEFILE", O_LARGEFILE);
#  endif
#  ifdef SEEK_DATA
        C("SEEK_DATA", SEEK_DATA); C("SEEK_HOLE", SEEK_HOLE);
#  endif
#endif
        return make_list(E, out);
    }

    // ── file descriptors ──────────────────────────────────────────────────
    if (op == "open") {
        std::string p = S(0);
        int flags = (int)I(1, 0), mode = (int)I(2, 0777);
#ifdef _WIN32
        int fd = ::_wopen(widen(p).c_str(), flags | _O_NOINHERIT, mode);
#else
        int fd;
        {
            nyconc::GilRelease unlocked;   // a FIFO's open waits for its other end
            do { fd = ::open(p.c_str(), flags | O_CLOEXEC, mode); } while (fd < 0 && errno == EINTR);
        }
#endif
        if (fd < 0) raise_errno(errno, p);
        return make_int(fd);
    }
    if (op == "read") {
        int fd = fd_arg(E, A(0));
        long long n = I(1, 0);
        if (n < 0) raise("ValueError", "negative length");
        std::string buf((size_t)n, '\0');
        long long got;
        int err = 0;
        {
            nyconc::GilRelease unlocked;
            do {
#ifdef _WIN32
                got = ::_read(fd, n ? &buf[0] : nullptr, (unsigned)std::min<long long>(n, 0x7fffffff));
#else
                got = ::read(fd, n ? &buf[0] : nullptr, (size_t)n);
#endif
            } while (got < 0 && errno == EINTR);
            if (got < 0) err = errno;
        }
        if (got < 0) raise_errno(err, "");
        buf.resize((size_t)got);
        return E.makeBytesValue(buf);
    }
    if (op == "write") {
        int fd = fd_arg(E, A(0));
        std::string data = bytes_arg(E, A(1));
        long long put;
        int err = 0;
        {
            nyconc::GilRelease unlocked;
            do {
#ifdef _WIN32
                put = ::_write(fd, data.data(), (unsigned)std::min<size_t>(data.size(), 0x7fffffff));
#else
                put = ::write(fd, data.data(), data.size());
#endif
            } while (put < 0 && errno == EINTR);
            if (put < 0) err = errno;
        }
        if (put < 0) raise_errno(err, "");
        return make_int(put);
    }
    if (op == "close") {
        int fd = fd_arg(E, A(0));
#ifdef _WIN32
        if (::_close(fd) != 0) raise_errno(errno, "");
#else
        if (::close(fd) != 0 && errno != EINTR) raise_errno(errno, "");
#endif
        return NONE_VALUE;
    }
    if (op == "closerange") {
        long long lo = I(0, 0), hi = I(1, 0);
        for (long long fd = std::max(lo, 0LL); fd < hi && fd < 65536; fd++) {
#ifdef _WIN32
            ::_close((int)fd);
#else
            ::close((int)fd);
#endif
        }
        return NONE_VALUE;
    }
    if (op == "pipe") {
        int fds[2];
#ifdef _WIN32
        if (::_pipe(fds, 65536, _O_BINARY | _O_NOINHERIT) != 0) raise_errno(errno, "");
#else
        if (::pipe(fds) != 0) raise_errno(errno, "");
        ::fcntl(fds[0], F_SETFD, FD_CLOEXEC);
        ::fcntl(fds[1], F_SETFD, FD_CLOEXEC);
#endif
        return tuple_of(E, {make_int(fds[0]), make_int(fds[1])});
    }
    if (op == "dup") {
        int fd = fd_arg(E, A(0));
#ifdef _WIN32
        int r = ::_dup(fd);
        if (r < 0) raise_errno(errno, "");
        SetHandleInformation((HANDLE)_get_osfhandle(r), HANDLE_FLAG_INHERIT, 0);
#else
        int r = ::fcntl(fd, F_DUPFD_CLOEXEC, 0);
        if (r < 0) raise_errno(errno, "");
#endif
        return make_int(r);
    }
    if (op == "dup2") {
        int fd = fd_arg(E, A(0)), fd2 = (int)I(1, -1);
        bool inheritable = args.size() > 3 ? B(2) : true;
#ifdef _WIN32
        if (::_dup2(fd, fd2) != 0) raise_errno(errno, "");
        if (!inheritable) SetHandleInformation((HANDLE)_get_osfhandle(fd2), HANDLE_FLAG_INHERIT, 0);
#else
        if (::dup2(fd, fd2) < 0) raise_errno(errno, "");
        if (!inheritable) ::fcntl(fd2, F_SETFD, FD_CLOEXEC);
#endif
        return make_int(fd2);
    }
    if (op == "get_inheritable" || op == "set_inheritable") {
        int fd = fd_arg(E, A(0));
#ifdef _WIN32
        HANDLE h = (HANDLE)_get_osfhandle(fd);
        if (h == INVALID_HANDLE_VALUE) raise_errno(EBADF, "");
        if (op == "set_inheritable") {
            if (!SetHandleInformation(h, HANDLE_FLAG_INHERIT, B(1) ? HANDLE_FLAG_INHERIT : 0)) raise_errno(EBADF, "");
            return NONE_VALUE;
        }
        DWORD f = 0;
        if (!GetHandleInformation(h, &f)) raise_errno(EBADF, "");
        return Value((f & HANDLE_FLAG_INHERIT) != 0);
#else
        int f = ::fcntl(fd, F_GETFD);
        if (f < 0) raise_errno(errno, "");
        if (op == "set_inheritable") {
            f = B(1) ? (f & ~FD_CLOEXEC) : (f | FD_CLOEXEC);
            if (::fcntl(fd, F_SETFD, f) < 0) raise_errno(errno, "");
            return NONE_VALUE;
        }
        return Value((f & FD_CLOEXEC) == 0);
#endif
    }
#ifndef _WIN32
    if (op == "get_blocking" || op == "set_blocking") {
        int fd = fd_arg(E, A(0));
        int f = ::fcntl(fd, F_GETFL);
        if (f < 0) raise_errno(errno, "");
        if (op == "set_blocking") {
            f = B(1) ? (f & ~O_NONBLOCK) : (f | O_NONBLOCK);
            if (::fcntl(fd, F_SETFL, f) < 0) raise_errno(errno, "");
            return NONE_VALUE;
        }
        return Value((f & O_NONBLOCK) == 0);
    }
#endif
    if (op == "lseek") {
        int fd = fd_arg(E, A(0));
        long long pos = I(1, 0);
        int how = (int)I(2, 0);
#ifdef _WIN32
        long long r = ::_lseeki64(fd, pos, how);
#else
        long long r = (long long)::lseek(fd, (off_t)pos, how);
#endif
        if (r < 0) raise_errno(errno, "");
        return make_int(r);
    }
    if (op == "fsync") {
        int fd = fd_arg(E, A(0));
#ifdef _WIN32
        if (::_commit(fd) != 0) raise_errno(errno, "");
#else
        if (::fsync(fd) != 0) raise_errno(errno, "");
#endif
        return NONE_VALUE;
    }
    if (op == "isatty") {
        int fd = (int)I(0, -1);
        if (fd >= 1000) fd = fd_arg(E, A(0));
#ifdef _WIN32
        return Value(::_isatty(fd) != 0);
#else
        return Value(::isatty(fd) != 0);
#endif
    }
    if (op == "ftruncate") {
        int fd = fd_arg(E, A(0));
        long long n = I(1, 0);
#ifdef _WIN32
        if (::_chsize(fd, (long)n) != 0) raise_errno(errno, "");
#else
        if (::ftruncate(fd, (off_t)n) != 0) raise_errno(errno, "");
#endif
        return NONE_VALUE;
    }
    if (op == "truncate") {
        std::string p = S(0);
        long long n = I(1, 0);
#ifdef _WIN32
        int fd = ::_wopen(widen(p).c_str(), _O_WRONLY | _O_BINARY);
        if (fd < 0) raise_errno(errno, p);
        int rc = ::_chsize(fd, (long)n);
        int e = errno;
        ::_close(fd);
        if (rc != 0) raise_errno(e, p);
#else
        if (::truncate(p.c_str(), (off_t)n) != 0) raise_errno(errno, p);
#endif
        return NONE_VALUE;
    }
    if (op == "fdopen") {
        // a FILE over the descriptor, registered as a file handle (open()'s
        // file objects use them); the prelude wraps it in a NythonFile
        int fd = fd_arg(E, A(0));
        std::string mode = S(1);
        std::string m;
        bool plus = mode.find('+') != std::string::npos;
        if (mode.find('r') != std::string::npos) m = plus ? "r+" : "r";
        else if (mode.find('a') != std::string::npos) m = plus ? "a+" : "a";
        else m = plus ? "w+" : "w";
        m += "b";
#ifdef _WIN32
        FILE* f = ::_fdopen(fd, m.c_str());
#else
        FILE* f = ::fdopen(fd, m.c_str());
#endif
        if (!f) raise_errno(errno, "");
        int handle = E.next_file_handle++;
        E.file_handles[handle] = f;
        return make_int(handle);
    }
    if (op == "fd_of") {
        // the descriptor under a file object's handle
        return make_int(fd_arg(E, A(0)));
    }
    if (op == "strerror") {
        return Str(std::strerror((int)I(0, 0)));
    }
    if (op == "umask") {
#ifdef _WIN32
        return make_int(::_umask((int)I(0, 0)));
#else
        return make_int((long long)::umask((mode_t)I(0, 0)));
#endif
    }
    if (op == "getlogin") {
#ifdef _WIN32
        // GetUserNameW, looked up at run time (advapi32 is not linked)
        typedef BOOL (WINAPI *GetUserNameW_t)(LPWSTR, LPDWORD);
        HMODULE adv = LoadLibraryA("advapi32.dll");
        GetUserNameW_t gun = adv ? (GetUserNameW_t)(void*)GetProcAddress(adv, "GetUserNameW") : nullptr;
        wchar_t buf[257];
        DWORD n = 257;
        if (!gun || !gun(buf, &n)) raise_errno(gun ? win_errno(GetLastError()) : ENOSYS, "");
        int k = WideCharToMultiByte(CP_UTF8, 0, buf, -1, nullptr, 0, nullptr, nullptr);
        std::string s((size_t)(k > 0 ? k - 1 : 0), '\0');
        if (k > 1) WideCharToMultiByte(CP_UTF8, 0, buf, -1, &s[0], k, nullptr, nullptr);
        return Str(s);
#else
        errno = 0;
        const char* n = ::getlogin();
        // no controlling terminal (a service, a container): OSError, as CPython
        if (!n) raise_errno(errno ? errno : ENXIO, "");
        return Str(n);
#endif
    }
    if (op == "access") {
        // access(path, mode, effective_ids, follow_symlinks) -> bool
        std::string p = S(0);
        int mode = (int)I(1, 0);
#ifdef _WIN32
        DWORD attr = GetFileAttributesW(widen(p).c_str());
        if (attr == INVALID_FILE_ATTRIBUTES) return Value(false);
        // as CPython: only W_OK on a read-only file (not a directory) fails
        return Value(!((mode & 2) && !(attr & FILE_ATTRIBUTE_DIRECTORY) && (attr & FILE_ATTRIBUTE_READONLY)));
#else
        int flags = 0;
        if (B(2)) flags |= AT_EACCESS;
        if (args.size() > 4 && !B(3)) flags |= AT_SYMLINK_NOFOLLOW;
        return Value(::faccessat(AT_FDCWD, p.c_str(), mode, flags) == 0);
#endif
    }
    if (op == "scandir") {
        // [(name, kind, inode), ...] - kind 'd' / 'f' / 'l' / 'o' (another
        // type) or '?' when the file system does not say (DirEntry then asks
        // stat)
        std::string p = S(0);
        if (p.empty()) p = ".";
        std::vector<Value> out;
#ifdef _WIN32
        std::wstring pat = widen(p);
        if (!pat.empty() && pat.back() != L'\\' && pat.back() != L'/') pat += L"\\";
        pat += L"*";
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW(pat.c_str(), &fd);
        if (h == INVALID_HANDLE_VALUE) {
            DWORD e = GetLastError();
            DWORD attr = GetFileAttributesW(widen(p).c_str());
            if (attr == INVALID_FILE_ATTRIBUTES) raise_errno(ENOENT, p);
            if (!(attr & FILE_ATTRIBUTE_DIRECTORY)) raise_errno(ENOTDIR, p);
            if (e == ERROR_FILE_NOT_FOUND) return make_list(E, out);
            raise_errno(win_errno(e), p);
        }
        do {
            std::wstring wn = fd.cFileName;
            if (wn == L"." || wn == L"..") continue;
            int k = WideCharToMultiByte(CP_UTF8, 0, wn.c_str(), (int)wn.size(), nullptr, 0, nullptr, nullptr);
            std::string n((size_t)k, '\0');
            WideCharToMultiByte(CP_UTF8, 0, wn.c_str(), (int)wn.size(), &n[0], k, nullptr, nullptr);
            bool link = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && fd.dwReserved0 == 0xA000000C;
            char kind = link ? 'l' : (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 'd' : 'f';
            out.push_back(tuple_of(E, {Str(n), Str(std::string(1, kind)), make_int(0)}));
        } while (FindNextFileW(h, &fd));
        FindClose(h);
#else
        DIR* d = ::opendir(p.c_str());
        if (!d) raise_errno(errno, p);
        struct dirent* e;
        while ((e = ::readdir(d)) != nullptr) {
            std::string n = e->d_name;
            if (n == "." || n == "..") continue;
#ifdef DT_DIR
            char kind = kind_of(e->d_type);
#else
            char kind = '?';
#endif
            out.push_back(tuple_of(E, {Str(n), Str(std::string(1, kind)), make_int((long long)e->d_ino)}));
        }
        ::closedir(d);
#endif
        return make_list(E, out);
    }

    // ── shared memory ─────────────────────────────────────────────────────
    if (op == "shm_open") {
        // shm_open(path, size, create) -> id: the file mapped shared; create
        // makes it (exclusively) at that size, else its size is the file's
        std::string p = S(0);
        long long size = I(1, 0);
        bool create = B(2);
        Segment seg;
#ifdef _WIN32
        seg.file = CreateFileW(widen(p).c_str(), GENERIC_READ | GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                               create ? CREATE_NEW : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (seg.file == INVALID_HANDLE_VALUE) raise_errno(win_errno(GetLastError()), p);
        LARGE_INTEGER li;
        if (create) {
            li.QuadPart = size;
            if (!SetFilePointerEx(seg.file, li, nullptr, FILE_BEGIN) || !SetEndOfFile(seg.file)) {
                CloseHandle(seg.file);
                raise_errno(EINVAL, p);
            }
        } else {
            GetFileSizeEx(seg.file, &li);
            size = li.QuadPart;
        }
        if (size <= 0) { CloseHandle(seg.file); raise("ValueError", "cannot map an empty segment"); }
        seg.map = CreateFileMappingW(seg.file, nullptr, PAGE_READWRITE, (DWORD)((unsigned long long)size >> 32),
                                     (DWORD)(size & 0xFFFFFFFF), nullptr);
        if (!seg.map) { CloseHandle(seg.file); raise_errno(win_errno(GetLastError()), p); }
        seg.base = (char*)MapViewOfFile(seg.map, FILE_MAP_ALL_ACCESS, 0, 0, (SIZE_T)size);
        if (!seg.base) { CloseHandle(seg.map); CloseHandle(seg.file); raise_errno(ENOMEM, p); }
#else
        int fd = ::open(p.c_str(), O_RDWR | O_CLOEXEC | (create ? (O_CREAT | O_EXCL) : 0), 0600);
        if (fd < 0) raise_errno(errno, p);
        if (create) {
            if (::ftruncate(fd, (off_t)size) != 0) { int e = errno; ::close(fd); raise_errno(e, p); }
        } else {
            struct stat st;
            if (::fstat(fd, &st) != 0) { int e = errno; ::close(fd); raise_errno(e, p); }
            size = (long long)st.st_size;
        }
        if (size <= 0) { ::close(fd); raise("ValueError", "cannot map an empty segment"); }
        void* m = ::mmap(nullptr, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        int e = errno;
        ::close(fd);
        if (m == MAP_FAILED) raise_errno(e, p);
        seg.base = (char*)m;
#endif
        seg.size = (size_t)size;
        std::lock_guard<std::mutex> lk(seg_mutex());
        long long id = next_segment++;
        segments()[id] = seg;
        return make_int(id);
    }
    if (op == "shm_size") {
        std::lock_guard<std::mutex> lk(seg_mutex());
        return make_int((long long)segment_of(I(0, 0)).size);
    }
    if (op == "shm_read") {
        // shm_read(id, offset, n) -> bytes
        std::string out;
        {
            std::lock_guard<std::mutex> lk(seg_mutex());
            Segment& s = segment_of(I(0, 0));
            long long off = I(1, 0), n = I(2, -1);
            if (off < 0 || (size_t)off > s.size) raise("IndexError", "offset out of range");
            if (n < 0 || (size_t)(off + n) > s.size) n = (long long)(s.size - (size_t)off);
            out.assign(s.base + off, (size_t)n);
        }
        return E.makeBytesValue(out);
    }
    if (op == "shm_write") {
        // shm_write(id, offset, data) -> n
        std::string data = bytes_arg(E, A(2));
        std::lock_guard<std::mutex> lk(seg_mutex());
        Segment& s = segment_of(I(0, 0));
        long long off = I(1, 0);
        if (off < 0 || (size_t)off + data.size() > s.size) raise("IndexError", "data out of the segment's range");
        std::memcpy(s.base + off, data.data(), data.size());
        return make_int((long long)data.size());
    }
    if (op == "shm_close") {
        std::lock_guard<std::mutex> lk(seg_mutex());
        auto it = segments().find(I(0, 0));
        if (it == segments().end()) return NONE_VALUE;
#ifdef _WIN32
        UnmapViewOfFile(it->second.base);
        CloseHandle(it->second.map);
        CloseHandle(it->second.file);
#else
        ::munmap(it->second.base, it->second.size);
#endif
        segments().erase(it);
        return NONE_VALUE;
    }

#ifndef _WIN32
    // ── ids, ownership, devices (POSIX) ───────────────────────────────────
    if (op == "ids") {
        return tuple_of(E, {make_int((long long)::getuid()), make_int((long long)::geteuid()),
                            make_int((long long)::getgid()), make_int((long long)::getegid()),
                            make_int((long long)::getpgrp())});
    }
    if (op == "getgroups") {
        int n = ::getgroups(0, nullptr);
        if (n < 0) raise_errno(errno, "");
        std::vector<gid_t> g((size_t)n);
        n = ::getgroups(n, g.data());
        if (n < 0) raise_errno(errno, "");
        std::vector<Value> out;
        for (int i = 0; i < n; i++) out.push_back(make_int((long long)g[(size_t)i]));
        return make_list(E, out);
    }
    if (op == "setsid") {
        pid_t r = ::setsid();
        if (r < 0) raise_errno(errno, "");
        return NONE_VALUE;
    }
    if (op == "getsid") {
        pid_t r = ::getsid((pid_t)I(0, 0));
        if (r < 0) raise_errno(errno, "");
        return make_int((long long)r);
    }
    if (op == "getpgid") {
        pid_t r = ::getpgid((pid_t)I(0, 0));
        if (r < 0) raise_errno(errno, "");
        return make_int((long long)r);
    }
    if (op == "setpgid") {
        if (::setpgid((pid_t)I(0, 0), (pid_t)I(1, 0)) != 0) raise_errno(errno, "");
        return NONE_VALUE;
    }
    if (op == "chown" || op == "lchown" || op == "fchown") {
        long long uid = I(1, -1), gid = I(2, -1);
        int rc;
        std::string p;
        if (op == "fchown") rc = ::fchown(fd_arg(E, A(0)), (uid_t)uid, (gid_t)gid);
        else {
            p = S(0);
            bool follow = op == "chown" && !(args.size() > 4 && !B(3));
            rc = follow ? ::chown(p.c_str(), (uid_t)uid, (gid_t)gid) : ::lchown(p.c_str(), (uid_t)uid, (gid_t)gid);
        }
        if (rc != 0) raise_errno(errno, p);
        return NONE_VALUE;
    }
    if (op == "fchmod") {
        if (::fchmod(fd_arg(E, A(0)), (mode_t)I(1, 0)) != 0) raise_errno(errno, "");
        return NONE_VALUE;
    }
    if (op == "lchmod_nofollow") {
        std::string p = S(0);
        if (::fchmodat(AT_FDCWD, p.c_str(), (mode_t)I(1, 0), AT_SYMLINK_NOFOLLOW) != 0) raise_errno(errno, p);
        return NONE_VALUE;
    }
    if (op == "mknod") {
        std::string p = S(0);
        if (::mknod(p.c_str(), (mode_t)I(1, 0600), (dev_t)I(2, 0)) != 0) raise_errno(errno, p);
        return NONE_VALUE;
    }
    if (op == "mkfifo") {
        std::string p = S(0);
        if (::mkfifo(p.c_str(), (mode_t)I(1, 0666)) != 0) raise_errno(errno, p);
        return NONE_VALUE;
    }
    if (op == "major" || op == "minor" || op == "makedev") {
#if defined(__linux__) || defined(__APPLE__) || defined(__FreeBSD__)
        if (op == "major") return make_int((long long)major((dev_t)I(0, 0)));
        if (op == "minor") return make_int((long long)minor((dev_t)I(0, 0)));
        return make_int((long long)makedev((unsigned)I(0, 0), (unsigned)I(1, 0)));
#else
        raise("OSError", "device numbers are not available");
#endif
    }
    if (op == "getloadavg") {
        double la[3];
        if (::getloadavg(la, 3) != 3) raise("OSError", "Load averages are unobtainable");
        return tuple_of(E, {Value(la[0]), Value(la[1]), Value(la[2])});
    }
    if (op == "sched_getaffinity") {
#if defined(__linux__)
        cpu_set_t set;
        CPU_ZERO(&set);
        if (::sched_getaffinity((pid_t)I(0, 0), sizeof set, &set) != 0) raise_errno(errno, "");
        std::vector<Value> out;
        for (int i = 0; i < CPU_SETSIZE; i++) if (CPU_ISSET(i, &set)) out.push_back(make_int(i));
        return make_list(E, out);
#else
        raise("OSError", "sched_getaffinity is not available");
#endif
    }
    if (op == "kill") {
        if (::kill((pid_t)I(0, 0), (int)I(1, 15)) != 0) raise_errno(errno, "");
        return NONE_VALUE;
    }
    if (op == "killpg") {
        if (::killpg((pid_t)I(0, 0), (int)I(1, 15)) != 0) raise_errno(errno, "");
        return NONE_VALUE;
    }
    // ── the password and group databases (lib/pwd.ny, lib/grp.ny) ─────────
    if (op == "getpwnam" || op == "getpwuid") {
        std::lock_guard<std::mutex> lk(pwd_mutex());
        errno = 0;
        struct passwd* p = op == "getpwnam" ? ::getpwnam(S(0).c_str()) : ::getpwuid((uid_t)I(0, 0));
        if (!p) return NONE_VALUE;
        return passwd_tuple(E, p);
    }
    if (op == "getpwall") {
        std::lock_guard<std::mutex> lk(pwd_mutex());
        std::vector<Value> out;
        ::setpwent();
        while (struct passwd* p = ::getpwent()) out.push_back(passwd_tuple(E, p));
        ::endpwent();
        return make_list(E, out);
    }
    if (op == "getgrnam" || op == "getgrgid") {
        std::lock_guard<std::mutex> lk(pwd_mutex());
        struct group* g = op == "getgrnam" ? ::getgrnam(S(0).c_str()) : ::getgrgid((gid_t)I(0, 0));
        if (!g) return NONE_VALUE;
        return group_tuple(E, g);
    }
    if (op == "getgrall") {
        std::lock_guard<std::mutex> lk(pwd_mutex());
        std::vector<Value> out;
        ::setgrent();
        while (struct group* g = ::getgrent()) out.push_back(group_tuple(E, g));
        ::endgrent();
        return make_list(E, out);
    }
#else
    if (op == "kill") {
        // os.kill on Windows: TerminateProcess with the signal as exit code
        // (CTRL_C_EVENT / CTRL_BREAK_EVENT are not sent)
        HANDLE h = OpenProcess(PROCESS_TERMINATE, 0, (DWORD)I(0, 0));
        if (!h) raise_errno(win_errno(GetLastError()), "");
        BOOL ok = TerminateProcess(h, (UINT)I(1, 1));
        CloseHandle(h);
        if (!ok) raise_errno(win_errno(GetLastError()), "");
        return NONE_VALUE;
    }
#endif
    (void)Str;
    return UNDEFINED_VALUE;
}

} // namespace nyos

#pragma GCC diagnostic pop
