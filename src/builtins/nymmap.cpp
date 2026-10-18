// builtins/nymmap.cpp - memory-mapped files for lib/mmap.ny (round 83).
//
// A map is a region from mmap(2) (MapViewOfFile on Windows) kept in a table
// by handle; lib/mmap.ny's mmap class holds the handle, the position and the
// access mode and does Python's argument checking; these natives touch the
// memory. Anonymous maps (fileno -1) are MAP_ANONYMOUS (a pagefile-backed
// mapping on Windows, named by tagname when given); a file's map keeps a
// duplicate of its descriptor (handle) for size() and resize().
//
//   _mmap_new(fileno, length, flags, prot, access, offset, tagname) -> [h, length]
//   _mmap_close(h)                 _mmap_len(h)            _mmap_filesize(h)
//   _mmap_read(h, start, stop, step) -> bytes     _mmap_byte(h, i) -> int
//   _mmap_write(h, start, data)    _mmap_setbyte(h, i, v)
//   _mmap_find(h, sub, start, end, reverse) -> index or -1
//   _mmap_line_end(h, pos) -> index just past the next b"\n" (or the end)
//   _mmap_flush(h, offset, size)   _mmap_madvise(h, option, start, length)
//   _mmap_move(h, dest, src, count)
//   _mmap_resize(h, newsize)       _mmap_consts() -> [[name, value], ...]
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include "builtins/sysmods.hpp"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>
#ifdef _WIN32
#  include <windows.h>
#  include <io.h>
#else
#  include <fcntl.h>
#  include <unistd.h>
#  include <sys/mman.h>
#  include <sys/stat.h>
#endif

namespace {

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }
[[noreturn]] void fail_errno(int err) { nyos::raise_errno(err, ""); }

struct MMap {
    char* data = nullptr;
    int64_t size = 0;        // the mapped length
    int64_t offset = 0;
    int access = 0;
    int flags = 0, prot = 0;
#ifdef _WIN32
    HANDLE file = INVALID_HANDLE_VALUE;
    HANDLE mapping = nullptr;
    std::string tagname;
#else
    int fd = -1;
#endif
    ~MMap() { close(); }
    void close() {
#ifdef _WIN32
        if (data) UnmapViewOfFile(data);
        if (mapping) CloseHandle(mapping);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        mapping = nullptr;
        file = INVALID_HANDLE_VALUE;
#else
        if (data && size > 0) munmap(data, (size_t)size);
        if (fd >= 0) ::close(fd);
        fd = -1;
#endif
        data = nullptr;
    }
};

std::mutex& mu() { static std::mutex* m = new std::mutex(); return *m; }
std::unordered_map<int64_t, std::shared_ptr<MMap>>& table() {
    static auto* t = new std::unordered_map<int64_t, std::shared_ptr<MMap>>();
    return *t;
}
int64_t g_next = 1;

std::shared_ptr<MMap> get(int64_t h) {
    std::lock_guard<std::mutex> l(mu());
    auto it = table().find(h);
    if (it == table().end() || !it->second->data) {
        if (it != table().end() && it->second->size == 0) return it->second;   // an empty anonymous map
        fail("ValueError", "mmap closed or invalid");
    }
    return it->second;
}

int64_t iarg(std::vector<Value>& a, size_t i, int64_t dflt = 0) {
    if (i >= a.size() || a[i].type == ValueType::NONE) return dflt;
    return (int64_t)nyos::to_int(a[i], dflt);
}
std::string barg(NythonExecutor& E, const Value& v) {
    if (auto* b = E.bytesOf(v)) return b->s;
    fail("TypeError", "a bytes-like object is required, not '" + E.typeNameOf(v) + "'");
}

int64_t page_granularity() {
#ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return si.dwAllocationGranularity;
#else
    return sysconf(_SC_PAGESIZE);
#endif
}

} // namespace

std::vector<std::string> mmap_builtin_names() {
    return {"_mmap_new", "_mmap_close", "_mmap_len", "_mmap_filesize", "_mmap_read", "_mmap_byte", "_mmap_write",
            "_mmap_setbyte", "_mmap_find", "_mmap_line_end", "_mmap_flush", "_mmap_madvise", "_mmap_move",
            "_mmap_resize", "_mmap_consts"};
}

Value dispatch_mmap(NythonExecutor& E, const std::string& name, std::vector<Value>& a, Context* ctx) {
    (void)ctx;
    if (name == "_mmap_consts") {
        std::vector<std::pair<std::string, int64_t>> kv;
#define K(n) kv.push_back({#n, (int64_t)(n)})
#ifndef _WIN32
        K(MAP_SHARED); K(MAP_PRIVATE); K(PROT_READ); K(PROT_WRITE); K(PROT_EXEC);
#ifdef MAP_ANONYMOUS
        K(MAP_ANONYMOUS);
        kv.push_back({"MAP_ANON", (int64_t)MAP_ANONYMOUS});
#else
        K(MAP_ANON);
        kv.push_back({"MAP_ANONYMOUS", (int64_t)MAP_ANON});
#endif
#ifdef MAP_DENYWRITE
        K(MAP_DENYWRITE);
#endif
#ifdef MAP_EXECUTABLE
        K(MAP_EXECUTABLE);
#endif
#ifdef MAP_POPULATE
        K(MAP_POPULATE);
#endif
#ifdef MAP_STACK
        K(MAP_STACK);
#endif
#ifdef MAP_NORESERVE
        K(MAP_NORESERVE);
#endif
#ifdef MAP_ALIGNED_SUPER
        K(MAP_ALIGNED_SUPER);
#endif
#ifdef MAP_CONCEAL
        K(MAP_CONCEAL);
#endif
        K(MADV_NORMAL); K(MADV_RANDOM); K(MADV_SEQUENTIAL); K(MADV_WILLNEED); K(MADV_DONTNEED);
#ifdef MADV_REMOVE
        K(MADV_REMOVE);
#endif
#ifdef MADV_DONTFORK
        K(MADV_DONTFORK); K(MADV_DOFORK);
#endif
#ifdef MADV_HWPOISON
        K(MADV_HWPOISON);
#endif
#ifdef MADV_MERGEABLE
        K(MADV_MERGEABLE); K(MADV_UNMERGEABLE);
#endif
#ifdef MADV_SOFT_OFFLINE
        K(MADV_SOFT_OFFLINE);
#endif
#ifdef MADV_HUGEPAGE
        K(MADV_HUGEPAGE); K(MADV_NOHUGEPAGE);
#endif
#ifdef MADV_DONTDUMP
        K(MADV_DONTDUMP); K(MADV_DODUMP);
#endif
#ifdef MADV_FREE
        K(MADV_FREE);
#endif
#ifdef MADV_NOSYNC
        K(MADV_NOSYNC); K(MADV_AUTOSYNC); K(MADV_NOCORE); K(MADV_CORE); K(MADV_PROTECT);
#endif
#ifdef MADV_FREE_REUSABLE
        K(MADV_FREE_REUSABLE); K(MADV_FREE_REUSE);
#endif
#endif
#undef K
        kv.push_back({"PAGESIZE", (int64_t)
#ifdef _WIN32
            [] { SYSTEM_INFO si; GetSystemInfo(&si); return (int64_t)si.dwPageSize; }()
#else
            sysconf(_SC_PAGESIZE)
#endif
        });
        kv.push_back({"ALLOCATIONGRANULARITY", page_granularity()});
        std::vector<Value> out;
        for (auto& p : kv) {
            std::vector<Value> pair{E.makeStringValue(p.first), Value((int64_t)p.second)};
            out.push_back(E.makeListValue(pair));
        }
        return E.makeListValue(out);
    }
    if (name == "_mmap_new") {
        int64_t fileno = iarg(a, 0, -1), length = iarg(a, 1, 0);
        int flags = (int)iarg(a, 2, 0), prot = (int)iarg(a, 3, 0), access = (int)iarg(a, 4, 0);
        int64_t offset = iarg(a, 5, 0);
        auto m = std::make_shared<MMap>();
        m->access = access;
        m->flags = flags;
        m->prot = prot;
        m->offset = offset;
#ifdef _WIN32
        std::string tag = a.size() > 6 && a[6].type != ValueType::NONE ? E.strOf(a[6]) : std::string();
        m->tagname = tag;
        DWORD fl_protect, dw_access;
        switch (access) {
        case 1: fl_protect = PAGE_READONLY; dw_access = FILE_MAP_READ; break;
        case 3: fl_protect = PAGE_WRITECOPY; dw_access = FILE_MAP_COPY; break;
        default: fl_protect = PAGE_READWRITE; dw_access = FILE_MAP_WRITE; break;
        }
        if (fileno != -1) {
            HANDLE fh = (HANDLE)_get_osfhandle((int)fileno);
            if (fh == INVALID_HANDLE_VALUE) fail_errno(EBADF);
            if (!DuplicateHandle(GetCurrentProcess(), fh, GetCurrentProcess(), &m->file, 0, 0, DUPLICATE_SAME_ACCESS))
                fail("OSError", "[WinError " + std::to_string(GetLastError()) + "] DuplicateHandle failed");
            LARGE_INTEGER fs;
            if (!GetFileSizeEx(m->file, &fs)) fail("OSError", "[WinError " + std::to_string(GetLastError()) + "] cannot get the file size");
            if (length == 0) {
                if (fs.QuadPart == 0) fail("ValueError", "cannot mmap an empty file");
                if (offset >= fs.QuadPart) fail("ValueError", "mmap offset is greater than file size");
                length = fs.QuadPart - offset;
            }
        } else if (length == 0) {
            fail("ValueError", "cannot mmap an empty file");   // CPython: anonymous needs a length
        }
        int64_t end = offset + length;
        m->mapping = CreateFileMappingA(m->file, nullptr, fl_protect, (DWORD)(end >> 32), (DWORD)(end & 0xFFFFFFFF),
                                        tag.empty() ? nullptr : tag.c_str());
        if (!m->mapping) fail("OSError", "[WinError " + std::to_string(GetLastError()) + "] CreateFileMapping failed");
        m->data = (char*)MapViewOfFile(m->mapping, dw_access, (DWORD)(offset >> 32), (DWORD)(offset & 0xFFFFFFFF), (SIZE_T)length);
        if (!m->data) fail("OSError", "[WinError " + std::to_string(GetLastError()) + "] MapViewOfFile failed");
        m->size = length;
#else
        if (fileno != -1) {
            struct stat st;
            if (fstat((int)fileno, &st) == 0 && S_ISREG(st.st_mode)) {
                if (length == 0) {
                    if (st.st_size == 0) fail("ValueError", "cannot mmap an empty file");
                    if (offset >= st.st_size) fail("ValueError", "mmap offset is greater than file size");
                    length = st.st_size - offset;
                } else if (offset > st.st_size || st.st_size - offset < length) {
                    fail("ValueError", "mmap length is greater than file size");
                }
            }
            m->fd = ::dup((int)fileno);
            if (m->fd < 0) fail_errno(errno);
        } else {
#ifdef MAP_ANONYMOUS
            flags |= MAP_ANONYMOUS;
#else
            flags |= MAP_ANON;
#endif
        }
        m->flags = flags;
        if (length > 0) {
            void* p = ::mmap(nullptr, (size_t)length, prot, flags, m->fd, (off_t)offset);
            if (p == MAP_FAILED) { int err = errno; m->close(); fail_errno(err); }
            m->data = (char*)p;
        }
        m->size = length;
#endif
        std::lock_guard<std::mutex> l(mu());
        int64_t id = g_next++;
        table()[id] = m;
        std::vector<Value> v{Value((int64_t)id), Value((int64_t)length)};
        return E.makeListValue(v);
    }
    if (name == "_mmap_close") {
        std::lock_guard<std::mutex> l(mu());
        auto it = table().find(iarg(a, 0));
        if (it != table().end()) { it->second->close(); table().erase(it); }
        return NONE_VALUE;
    }
    auto m = get(iarg(a, 0));
    if (name == "_mmap_len") return Value((int64_t)m->size);
    if (name == "_mmap_filesize") {
#ifdef _WIN32
        if (m->file == INVALID_HANDLE_VALUE) return Value((int64_t)m->size);
        LARGE_INTEGER fs;
        if (!GetFileSizeEx(m->file, &fs)) fail("OSError", "cannot get the file size");
        return Value((int64_t)fs.QuadPart);
#else
        if (m->fd < 0) return Value((int64_t)m->size);
        struct stat st;
        if (fstat(m->fd, &st) < 0) fail_errno(errno);
        return Value((int64_t)st.st_size);
#endif
    }
    if (name == "_mmap_read") {
        int64_t start = iarg(a, 1), stop = iarg(a, 2), step = iarg(a, 3, 1);
        std::string out;
        if (step == 1) {
            if (stop > start) out.assign(m->data + start, (size_t)(stop - start));
        } else {
            for (int64_t i = start; step > 0 ? i < stop : i > stop; i += step) out.push_back(m->data[i]);
        }
        return E.makeBytesValue(out);
    }
    if (name == "_mmap_byte") {
        int64_t i = iarg(a, 1);
        return Value((int64_t)(unsigned char)m->data[i]);
    }
    if (name == "_mmap_write") {
        int64_t start = iarg(a, 1);
        std::string d = barg(E, a[2]);
        int64_t step = iarg(a, 3, 1);
        if (step == 1) { if (!d.empty()) std::memcpy(m->data + start, d.data(), d.size()); }
        else { int64_t i = start; for (char c : d) { m->data[i] = c; i += step; } }
        return NONE_VALUE;
    }
    if (name == "_mmap_setbyte") {
        m->data[iarg(a, 1)] = (char)(unsigned char)iarg(a, 2);
        return NONE_VALUE;
    }
    if (name == "_mmap_find") {
        std::string sub = barg(E, a[1]);
        int64_t start = iarg(a, 2), end = iarg(a, 3);
        bool rev = a.size() > 4 && nyos::to_int(a[4], 0) != 0;
        if (end > m->size) end = m->size;
        if (start < 0) start = 0;
        if (end - start < (int64_t)sub.size()) return Value((int64_t)-1);
        if (!rev) {
            for (int64_t i = start; i + (int64_t)sub.size() <= end; i++)
                if (std::memcmp(m->data + i, sub.data(), sub.size()) == 0) return Value((int64_t)i);
        } else {
            for (int64_t i = end - (int64_t)sub.size(); i >= start; i--)
                if (std::memcmp(m->data + i, sub.data(), sub.size()) == 0) return Value((int64_t)i);
        }
        return Value((int64_t)-1);
    }
    if (name == "_mmap_line_end") {
        int64_t pos = iarg(a, 1);
        if (pos >= m->size) return Value((int64_t)m->size);
        const void* nl = std::memchr(m->data + pos, '\n', (size_t)(m->size - pos));
        if (!nl) return Value((int64_t)m->size);
        return Value((int64_t)((const char*)nl - m->data + 1));
    }
    if (name == "_mmap_flush") {
        int64_t off = iarg(a, 1), size = iarg(a, 2);
        if (size == 0) return NONE_VALUE;
#ifdef _WIN32
        if (!FlushViewOfFile(m->data + off, (SIZE_T)size)) fail("OSError", "[WinError " + std::to_string(GetLastError()) + "] FlushViewOfFile failed");
#else
        if (msync(m->data + off, (size_t)size, MS_SYNC) < 0) fail_errno(errno);
#endif
        return NONE_VALUE;
    }
    if (name == "_mmap_madvise") {
#ifndef _WIN32
        int opt = (int)iarg(a, 1);
        int64_t start = iarg(a, 2), len = iarg(a, 3);
        if (len > 0 && madvise(m->data + start, (size_t)len, opt) < 0) fail_errno(errno);
#endif
        return NONE_VALUE;
    }
    if (name == "_mmap_move") {
        int64_t dest = iarg(a, 1), src = iarg(a, 2), count = iarg(a, 3);
        if (count > 0) std::memmove(m->data + dest, m->data + src, (size_t)count);
        return NONE_VALUE;
    }
    if (name == "_mmap_resize") {
        int64_t newsize = iarg(a, 1);
#ifdef _WIN32
        // CPython's: unmap, set the file's end, map again
        if (m->file == INVALID_HANDLE_VALUE && !m->tagname.empty())
            fail("OSError", "[WinError 87] cannot resize a named anonymous map");
        UnmapViewOfFile(m->data); m->data = nullptr;
        CloseHandle(m->mapping); m->mapping = nullptr;
        int64_t end = m->offset + newsize;
        if (m->file != INVALID_HANDLE_VALUE) {
            LARGE_INTEGER li; li.QuadPart = end;
            if (!SetFilePointerEx(m->file, li, nullptr, FILE_BEGIN) || !SetEndOfFile(m->file))
                fail("OSError", "[WinError " + std::to_string(GetLastError()) + "] cannot resize the file");
        }
        m->mapping = CreateFileMappingA(m->file, nullptr, PAGE_READWRITE, (DWORD)(end >> 32), (DWORD)(end & 0xFFFFFFFF),
                                        m->tagname.empty() ? nullptr : m->tagname.c_str());
        if (!m->mapping) fail("OSError", "[WinError " + std::to_string(GetLastError()) + "] CreateFileMapping failed");
        m->data = (char*)MapViewOfFile(m->mapping, FILE_MAP_WRITE, (DWORD)(m->offset >> 32), (DWORD)(m->offset & 0xFFFFFFFF), (SIZE_T)newsize);
        if (!m->data) fail("OSError", "[WinError " + std::to_string(GetLastError()) + "] MapViewOfFile failed");
        m->size = newsize;
#else
        if (m->fd >= 0 && ftruncate(m->fd, (off_t)(m->offset + newsize)) < 0) fail_errno(errno);
#if defined(__linux__)
        void* p = mremap(m->data, (size_t)m->size, (size_t)newsize, MREMAP_MAYMOVE);
        if (p == MAP_FAILED) fail_errno(errno);
        m->data = (char*)p;
#else
        if (m->fd < 0) fail("SystemError", "mmap: resizing not available--no mremap()");
        void* p = ::mmap(nullptr, (size_t)newsize, m->prot, m->flags, m->fd, (off_t)m->offset);
        if (p == MAP_FAILED) fail_errno(errno);
        munmap(m->data, (size_t)m->size);
        m->data = (char*)p;
#endif
        m->size = newsize;
#endif
        return NONE_VALUE;
    }
    return UNDEFINED_VALUE;
}
