// builtins/nysqlite.cpp - SQLite for the sqlite3 module (round 83).
//
// libsqlite3 is loaded when a program first uses it - dlopen / LoadLibrary,
// nothing at build or link time - so Nython builds everywhere and sqlite3
// works wherever the library is installed (NY_LIBSQLITE3 names a library to
// try first; lib/_sqlite3.ny raises an ImportError naming the library when
// none is found). lib/_sqlite3.ny is the DB-API module (CPython's C module
// _sqlite3, written in Nython) over the natives here; lib/sqlite3/ is
// CPython's package over it.
//
// Callbacks into the program. SQLite calls user functions, aggregates,
// window functions, collations, the authorizer, the progress handler and the
// trace callback from inside sqlite3_prepare/step/exec. Calling back into
// either engine from there would need each engine's call path (and the VM's
// values crossing the builtin bridge); instead every such SQLite call runs on
// a stackful coroutine of its own (NyCoro), and a callback *suspends* it: the
// native returns [1, op, kind, fid, key, args] to the Nython caller, which
// calls the function and hands its result to _sql_resume(op, status, value),
// which resumes the coroutine where the callback stopped. So the program's
// function runs as ordinary Nython code on whichever engine runs the
// program (tracebacks, exceptions, generators, threads all as usual), and a
// callback may itself use the connection (a nested operation is a coroutine
// of its own). A connection with no callbacks registered runs SQLite
// directly. The GIL is released while SQLite runs (prepare, step, exec,
// backup, blob I/O) and taken back before a callback request is returned.
//
// Natives (results are plain values; errors are SQLite result codes the
// module turns into its exception classes through _sql_errinfo):
//   _sql_available() -> bool       _sql_why() -> text   _sql_version() -> [text, number, threadsafe]
//   _sql_open(path, flags, vfs) -> [rc, h]     _sql_close(h) -> rc
//   _sql_errinfo(h) -> [code, extended, name, message]   _sql_errname(code)  _sql_errstr(code)
//   _sql_busy_timeout(h, ms)  _sql_autocommit(h)  _sql_changes(h)  _sql_total_changes(h)
//   _sql_last_rowid(h)  _sql_interrupt(h)  _sql_limit(h, category, value)
//   _sql_db_config(h, op, value) -> [rc, value]   _sql_complete(sql)
//   _sql_prepare(h, sql, offset) -> [0, rc, stmt, tail, more, is_dml]  (or a callback request)
//   _sql_step(stmt) -> [0, rc]       _sql_exec(h, sql) -> [0, rc]
//   _sql_resume(op, status, value)   the suspended operation's result or next request
//   _sql_finalize(stmt)  _sql_reset(stmt)  _sql_clear_bindings(stmt)
//   _sql_bind_count(stmt)  _sql_bind_name(stmt, i)  _sql_bind(stmt, i, v) -> rc (-1: type, -2: overflow)
//   _sql_columns(stmt) -> [[name, decltype], ...]   _sql_column_count(stmt)
//   _sql_row(stmt, mode, raw_columns) -> [values] | (column, bytes) when a text is not UTF-8;
//     mode 0: text as str, 1: as bytes, 2: as bytes and [[values], [types]]
//   _sql_readonly(stmt)  _sql_busy(stmt)  _sql_stmt_sql(stmt)
//   _sql_create_function(h, name, narg, flags, kind, fid) -> rc  kind 0 scalar, 1 aggregate, 2 window
//   _sql_create_collation(h, name, fid) -> rc   _sql_set_authorizer(h, on)
//   _sql_set_progress(h, on, n)   _sql_set_trace(h, statements, profile)
//   _sql_backup_init(dst, dname, src, sname) -> [rc, b]  _sql_backup_step(b, n) -> [0, rc, remaining, pages]
//   _sql_backup_finish(b) -> rc
//   _sql_blob_open(h, db, table, column, row, writable) -> [rc, b]   _sql_blob_close(b)
//   _sql_blob_bytes(b)  _sql_blob_read(b, n, offset) -> bytes | rc   _sql_blob_write(b, data, offset) -> rc
//   _sql_serialize(h, name) -> bytes | None    _sql_deserialize(h, name, data) -> rc
//   _sql_enable_load_extension(h, on) -> rc    _sql_load_extension(h, path, entry) -> [rc, msg]
//   _sql_txn_state(h, name)  _sql_filename(h, name)
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyConc.hpp"
#include "NyCoro.hpp"
#include "builtins/os.hpp"
#include <cstring>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <unordered_map>
#ifdef _WIN32
#  include <winsock2.h>     // (before windows.h, as tls.cpp)
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif

namespace {

// ── the SQLite C API, resolved at run time ──────────────────────────────────
typedef void sqlite3;
typedef void sqlite3_stmt;
typedef void sqlite3_context;
typedef void sqlite3_value;
typedef void sqlite3_backup;
typedef void sqlite3_blob;
typedef long long sqlite3_int64;
typedef void (*xdestroy_t)(void*);
typedef void (*xfunc_t)(sqlite3_context*, int, sqlite3_value**);
typedef void (*xfinal_t)(sqlite3_context*);

constexpr int SQLITE_OK = 0, SQLITE_ERROR = 1, SQLITE_NOMEM = 7, SQLITE_MISUSE = 21,
              SQLITE_ROW = 100, SQLITE_DONE = 101, SQLITE_DENY = 1;
constexpr int SQLITE_INTEGER = 1, SQLITE_FLOAT = 2, SQLITE_TEXT = 3, SQLITE_BLOB = 4, SQLITE_NULL = 5;
constexpr int SQLITE_UTF8 = 1, SQLITE_TRACE_STMT = 1, SQLITE_TRACE_PROFILE = 2;
#define SQLITE_TRANSIENT_ ((xdestroy_t)(intptr_t)-1)

struct Api {
    bool tried = false, ok = false;
    std::string why;
    void* lib = nullptr;
    const char* (*libversion)() = nullptr;
    int (*libversion_number)() = nullptr;
    int (*threadsafe)() = nullptr;
    int (*open_v2)(const char*, sqlite3**, int, const char*) = nullptr;
    int (*close_v2)(sqlite3*) = nullptr;
    int (*errcode)(sqlite3*) = nullptr;
    int (*extended_errcode)(sqlite3*) = nullptr;
    const char* (*errmsg)(sqlite3*) = nullptr;
    const char* (*errstr)(int) = nullptr;
    int (*extended_result_codes)(sqlite3*, int) = nullptr;
    int (*busy_timeout)(sqlite3*, int) = nullptr;
    int (*get_autocommit)(sqlite3*) = nullptr;
    int (*changes)(sqlite3*) = nullptr;
    sqlite3_int64 (*changes64)(sqlite3*) = nullptr;
    int (*total_changes)(sqlite3*) = nullptr;
    sqlite3_int64 (*total_changes64)(sqlite3*) = nullptr;
    sqlite3_int64 (*last_insert_rowid)(sqlite3*) = nullptr;
    void (*interrupt)(sqlite3*) = nullptr;
    int (*limit)(sqlite3*, int, int) = nullptr;
    int (*db_config)(sqlite3*, int, ...) = nullptr;
    int (*prepare_v2)(sqlite3*, const char*, int, sqlite3_stmt**, const char**) = nullptr;
    int (*step)(sqlite3_stmt*) = nullptr;
    int (*reset)(sqlite3_stmt*) = nullptr;
    int (*finalize)(sqlite3_stmt*) = nullptr;
    int (*clear_bindings)(sqlite3_stmt*) = nullptr;
    int (*bind_parameter_count)(sqlite3_stmt*) = nullptr;
    const char* (*bind_parameter_name)(sqlite3_stmt*, int) = nullptr;
    int (*bind_null)(sqlite3_stmt*, int) = nullptr;
    int (*bind_int64)(sqlite3_stmt*, int, sqlite3_int64) = nullptr;
    int (*bind_double)(sqlite3_stmt*, int, double) = nullptr;
    int (*bind_text)(sqlite3_stmt*, int, const char*, int, xdestroy_t) = nullptr;
    int (*bind_blob)(sqlite3_stmt*, int, const void*, int, xdestroy_t) = nullptr;
    int (*column_count)(sqlite3_stmt*) = nullptr;
    const char* (*column_name)(sqlite3_stmt*, int) = nullptr;
    const char* (*column_decltype)(sqlite3_stmt*, int) = nullptr;
    int (*column_type)(sqlite3_stmt*, int) = nullptr;
    sqlite3_int64 (*column_int64)(sqlite3_stmt*, int) = nullptr;
    double (*column_double)(sqlite3_stmt*, int) = nullptr;
    const unsigned char* (*column_text)(sqlite3_stmt*, int) = nullptr;
    const void* (*column_blob)(sqlite3_stmt*, int) = nullptr;
    int (*column_bytes)(sqlite3_stmt*, int) = nullptr;
    int (*stmt_readonly)(sqlite3_stmt*) = nullptr;
    int (*stmt_busy)(sqlite3_stmt*) = nullptr;
    const char* (*sql)(sqlite3_stmt*) = nullptr;
    char* (*expanded_sql)(sqlite3_stmt*) = nullptr;
    sqlite3* (*db_handle)(sqlite3_stmt*) = nullptr;
    void (*free_)(void*) = nullptr;
    int (*create_function_v2)(sqlite3*, const char*, int, int, void*, xfunc_t, xfunc_t, xfinal_t, xdestroy_t) = nullptr;
    int (*create_window_function)(sqlite3*, const char*, int, int, void*, xfunc_t, xfinal_t, xfinal_t, xfunc_t, xdestroy_t) = nullptr;
    int (*create_collation_v2)(sqlite3*, const char*, int, void*, int (*)(void*, int, const void*, int, const void*), xdestroy_t) = nullptr;
    int (*set_authorizer)(sqlite3*, int (*)(void*, int, const char*, const char*, const char*, const char*), void*) = nullptr;
    void (*progress_handler)(sqlite3*, int, int (*)(void*), void*) = nullptr;
    int (*trace_v2)(sqlite3*, unsigned, int (*)(unsigned, void*, void*, void*), void*) = nullptr;
    int (*value_type)(sqlite3_value*) = nullptr;
    sqlite3_int64 (*value_int64)(sqlite3_value*) = nullptr;
    double (*value_double)(sqlite3_value*) = nullptr;
    const unsigned char* (*value_text)(sqlite3_value*) = nullptr;
    const void* (*value_blob)(sqlite3_value*) = nullptr;
    int (*value_bytes)(sqlite3_value*) = nullptr;
    void (*result_null)(sqlite3_context*) = nullptr;
    void (*result_int64)(sqlite3_context*, sqlite3_int64) = nullptr;
    void (*result_double)(sqlite3_context*, double) = nullptr;
    void (*result_text)(sqlite3_context*, const char*, int, xdestroy_t) = nullptr;
    void (*result_blob)(sqlite3_context*, const void*, int, xdestroy_t) = nullptr;
    void (*result_error)(sqlite3_context*, const char*, int) = nullptr;
    void (*result_error_nomem)(sqlite3_context*) = nullptr;
    void (*result_error_toobig)(sqlite3_context*) = nullptr;
    void* (*user_data)(sqlite3_context*) = nullptr;
    void* (*aggregate_context)(sqlite3_context*, int) = nullptr;
    sqlite3_backup* (*backup_init)(sqlite3*, const char*, sqlite3*, const char*) = nullptr;
    int (*backup_step)(sqlite3_backup*, int) = nullptr;
    int (*backup_finish)(sqlite3_backup*) = nullptr;
    int (*backup_remaining)(sqlite3_backup*) = nullptr;
    int (*backup_pagecount)(sqlite3_backup*) = nullptr;
    int (*blob_open)(sqlite3*, const char*, const char*, const char*, sqlite3_int64, int, sqlite3_blob**) = nullptr;
    int (*blob_close)(sqlite3_blob*) = nullptr;
    int (*blob_bytes)(sqlite3_blob*) = nullptr;
    int (*blob_read)(sqlite3_blob*, void*, int, int) = nullptr;
    int (*blob_write)(sqlite3_blob*, const void*, int, int) = nullptr;
    int (*complete)(const char*) = nullptr;
    const char* (*db_filename)(sqlite3*, const char*) = nullptr;
    unsigned char* (*serialize)(sqlite3*, const char*, sqlite3_int64*, unsigned) = nullptr;
    int (*deserialize)(sqlite3*, const char*, unsigned char*, sqlite3_int64, sqlite3_int64, unsigned) = nullptr;
    void* (*malloc64)(unsigned long long) = nullptr;
    int (*enable_load_extension)(sqlite3*, int) = nullptr;
    int (*load_extension)(sqlite3*, const char*, const char*, char**) = nullptr;
    int (*exec)(sqlite3*, const char*, int (*)(void*, int, char**, char**), void*, char**) = nullptr;
    int (*txn_state)(sqlite3*, const char*) = nullptr;
    const char* (*errmsg_raw)(sqlite3*) = nullptr;
};

void* sym(void* lib, const char* name) {
#ifdef _WIN32
    return (void*)GetProcAddress((HMODULE)lib, name);
#else
    return dlsym(lib, name);
#endif
}

template <typename F> bool bind(Api& a, F& f, const char* name, bool required = true) {
    f = reinterpret_cast<F>(sym(a.lib, name));
    if (!f && required && a.why.empty()) a.why = std::string("the SQLite library lacks ") + name;
    return f != nullptr;
}

std::string g_lib_name;

Api& api() {
    static Api a;
    static std::mutex m;
    std::lock_guard<std::mutex> l(m);
    if (a.tried) return a;
    a.tried = true;
    std::vector<std::string> names;
    if (const char* env = std::getenv("NY_LIBSQLITE3")) if (*env) names.push_back(env);
#ifdef _WIN32
    for (const char* n : {"sqlite3.dll", "libsqlite3-0.dll", "libsqlite3.dll"}) names.push_back(n);
#  ifdef _WIN64
    // Windows 10's own copy; its 32-bit build exports __stdcall functions,
    // which these cdecl pointers cannot call, so only on 64-bit Windows
    names.push_back("winsqlite3.dll");
#  endif
    for (auto& n : names) { HMODULE h = LoadLibraryA(n.c_str()); if (h) { a.lib = (void*)h; g_lib_name = n; break; } }
#elif defined(__APPLE__)
    for (const char* n : {"libsqlite3.dylib", "/usr/lib/libsqlite3.dylib", "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib",
                          "/usr/local/opt/sqlite/lib/libsqlite3.dylib"}) names.push_back(n);
    for (auto& n : names) { a.lib = dlopen(n.c_str(), RTLD_NOW | RTLD_LOCAL); if (a.lib) { g_lib_name = n; break; } }
#else
    for (const char* n : {"libsqlite3.so.0", "libsqlite3.so"}) names.push_back(n);
    for (auto& n : names) { a.lib = dlopen(n.c_str(), RTLD_NOW | RTLD_LOCAL); if (a.lib) { g_lib_name = n; break; } }
#endif
    if (!a.lib) {
#ifdef _WIN32
        a.why = "no SQLite library found: sqlite3.dll (put it beside nython.exe, or set NY_LIBSQLITE3)";
#elif defined(__APPLE__)
        a.why = "no SQLite library found: libsqlite3.dylib (install sqlite, or set NY_LIBSQLITE3)";
#else
        a.why = "no SQLite library found: libsqlite3.so.0 (install libsqlite3-0, or set NY_LIBSQLITE3)";
#endif
        return a;
    }
    bind(a, a.libversion, "sqlite3_libversion");
    bind(a, a.libversion_number, "sqlite3_libversion_number");
    bind(a, a.threadsafe, "sqlite3_threadsafe");
    bind(a, a.open_v2, "sqlite3_open_v2");
    bind(a, a.close_v2, "sqlite3_close_v2");
    bind(a, a.errcode, "sqlite3_errcode");
    bind(a, a.extended_errcode, "sqlite3_extended_errcode");
    bind(a, a.errmsg, "sqlite3_errmsg");
    bind(a, a.errstr, "sqlite3_errstr");
    bind(a, a.extended_result_codes, "sqlite3_extended_result_codes");
    bind(a, a.busy_timeout, "sqlite3_busy_timeout");
    bind(a, a.get_autocommit, "sqlite3_get_autocommit");
    bind(a, a.changes, "sqlite3_changes");
    bind(a, a.changes64, "sqlite3_changes64", false);
    bind(a, a.total_changes, "sqlite3_total_changes");
    bind(a, a.total_changes64, "sqlite3_total_changes64", false);
    bind(a, a.last_insert_rowid, "sqlite3_last_insert_rowid");
    bind(a, a.interrupt, "sqlite3_interrupt");
    bind(a, a.limit, "sqlite3_limit");
    bind(a, a.db_config, "sqlite3_db_config", false);
    bind(a, a.prepare_v2, "sqlite3_prepare_v2");
    bind(a, a.step, "sqlite3_step");
    bind(a, a.reset, "sqlite3_reset");
    bind(a, a.finalize, "sqlite3_finalize");
    bind(a, a.clear_bindings, "sqlite3_clear_bindings");
    bind(a, a.bind_parameter_count, "sqlite3_bind_parameter_count");
    bind(a, a.bind_parameter_name, "sqlite3_bind_parameter_name");
    bind(a, a.bind_null, "sqlite3_bind_null");
    bind(a, a.bind_int64, "sqlite3_bind_int64");
    bind(a, a.bind_double, "sqlite3_bind_double");
    bind(a, a.bind_text, "sqlite3_bind_text");
    bind(a, a.bind_blob, "sqlite3_bind_blob");
    bind(a, a.column_count, "sqlite3_column_count");
    bind(a, a.column_name, "sqlite3_column_name");
    bind(a, a.column_decltype, "sqlite3_column_decltype", false);
    bind(a, a.column_type, "sqlite3_column_type");
    bind(a, a.column_int64, "sqlite3_column_int64");
    bind(a, a.column_double, "sqlite3_column_double");
    bind(a, a.column_text, "sqlite3_column_text");
    bind(a, a.column_blob, "sqlite3_column_blob");
    bind(a, a.column_bytes, "sqlite3_column_bytes");
    bind(a, a.stmt_readonly, "sqlite3_stmt_readonly");
    bind(a, a.stmt_busy, "sqlite3_stmt_busy");
    bind(a, a.sql, "sqlite3_sql");
    bind(a, a.expanded_sql, "sqlite3_expanded_sql", false);
    bind(a, a.db_handle, "sqlite3_db_handle");
    bind(a, a.free_, "sqlite3_free");
    bind(a, a.create_function_v2, "sqlite3_create_function_v2");
    bind(a, a.create_window_function, "sqlite3_create_window_function", false);
    bind(a, a.create_collation_v2, "sqlite3_create_collation_v2");
    bind(a, a.set_authorizer, "sqlite3_set_authorizer", false);
    bind(a, a.progress_handler, "sqlite3_progress_handler", false);
    bind(a, a.trace_v2, "sqlite3_trace_v2", false);
    bind(a, a.value_type, "sqlite3_value_type");
    bind(a, a.value_int64, "sqlite3_value_int64");
    bind(a, a.value_double, "sqlite3_value_double");
    bind(a, a.value_text, "sqlite3_value_text");
    bind(a, a.value_blob, "sqlite3_value_blob");
    bind(a, a.value_bytes, "sqlite3_value_bytes");
    bind(a, a.result_null, "sqlite3_result_null");
    bind(a, a.result_int64, "sqlite3_result_int64");
    bind(a, a.result_double, "sqlite3_result_double");
    bind(a, a.result_text, "sqlite3_result_text");
    bind(a, a.result_blob, "sqlite3_result_blob");
    bind(a, a.result_error, "sqlite3_result_error");
    bind(a, a.result_error_nomem, "sqlite3_result_error_nomem");
    bind(a, a.result_error_toobig, "sqlite3_result_error_toobig");
    bind(a, a.user_data, "sqlite3_user_data");
    bind(a, a.aggregate_context, "sqlite3_aggregate_context");
    bind(a, a.backup_init, "sqlite3_backup_init", false);
    bind(a, a.backup_step, "sqlite3_backup_step", false);
    bind(a, a.backup_finish, "sqlite3_backup_finish", false);
    bind(a, a.backup_remaining, "sqlite3_backup_remaining", false);
    bind(a, a.backup_pagecount, "sqlite3_backup_pagecount", false);
    bind(a, a.blob_open, "sqlite3_blob_open", false);
    bind(a, a.blob_close, "sqlite3_blob_close", false);
    bind(a, a.blob_bytes, "sqlite3_blob_bytes", false);
    bind(a, a.blob_read, "sqlite3_blob_read", false);
    bind(a, a.blob_write, "sqlite3_blob_write", false);
    bind(a, a.complete, "sqlite3_complete");
    bind(a, a.db_filename, "sqlite3_db_filename", false);
    bind(a, a.serialize, "sqlite3_serialize", false);
    bind(a, a.deserialize, "sqlite3_deserialize", false);
    bind(a, a.malloc64, "sqlite3_malloc64", false);
    bind(a, a.enable_load_extension, "sqlite3_enable_load_extension", false);
    bind(a, a.load_extension, "sqlite3_load_extension", false);
    bind(a, a.exec, "sqlite3_exec");
    bind(a, a.txn_state, "sqlite3_txn_state", false);
    a.ok = a.why.empty();
    return a;
}

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }

Api& need() {
    Api& a = api();
    if (!a.ok) fail("ImportError", a.why);
    return a;
}

// ── SQLite's result code names (CPython's _sqlite/module.c table) ──────────
const char* code_name(int c) {
    switch (c) {
#define N(x, v) case v: return #x;
        N(SQLITE_OK, 0) N(SQLITE_ERROR, 1) N(SQLITE_INTERNAL, 2) N(SQLITE_PERM, 3) N(SQLITE_ABORT, 4)
        N(SQLITE_BUSY, 5) N(SQLITE_LOCKED, 6) N(SQLITE_NOMEM, 7) N(SQLITE_READONLY, 8) N(SQLITE_INTERRUPT, 9)
        N(SQLITE_IOERR, 10) N(SQLITE_CORRUPT, 11) N(SQLITE_NOTFOUND, 12) N(SQLITE_FULL, 13) N(SQLITE_CANTOPEN, 14)
        N(SQLITE_PROTOCOL, 15) N(SQLITE_EMPTY, 16) N(SQLITE_SCHEMA, 17) N(SQLITE_TOOBIG, 18) N(SQLITE_CONSTRAINT, 19)
        N(SQLITE_MISMATCH, 20) N(SQLITE_MISUSE, 21) N(SQLITE_NOLFS, 22) N(SQLITE_AUTH, 23) N(SQLITE_FORMAT, 24)
        N(SQLITE_RANGE, 25) N(SQLITE_NOTADB, 26) N(SQLITE_NOTICE, 27) N(SQLITE_WARNING, 28) N(SQLITE_ROW, 100)
        N(SQLITE_DONE, 101)
        N(SQLITE_ERROR_MISSING_COLLSEQ, 257) N(SQLITE_ERROR_RETRY, 513) N(SQLITE_ERROR_SNAPSHOT, 769)
        N(SQLITE_IOERR_READ, 266) N(SQLITE_IOERR_SHORT_READ, 522) N(SQLITE_IOERR_WRITE, 778) N(SQLITE_IOERR_FSYNC, 1034)
        N(SQLITE_IOERR_DIR_FSYNC, 1290) N(SQLITE_IOERR_TRUNCATE, 1546) N(SQLITE_IOERR_FSTAT, 1802)
        N(SQLITE_IOERR_UNLOCK, 2058) N(SQLITE_IOERR_RDLOCK, 2314) N(SQLITE_IOERR_DELETE, 2570)
        N(SQLITE_IOERR_BLOCKED, 2826) N(SQLITE_IOERR_NOMEM, 3082) N(SQLITE_IOERR_ACCESS, 3338)
        N(SQLITE_IOERR_CHECKRESERVEDLOCK, 3594) N(SQLITE_IOERR_LOCK, 3850) N(SQLITE_IOERR_CLOSE, 4106)
        N(SQLITE_IOERR_DIR_CLOSE, 4362) N(SQLITE_IOERR_SHMOPEN, 4618) N(SQLITE_IOERR_SHMSIZE, 4874)
        N(SQLITE_IOERR_SHMLOCK, 5130) N(SQLITE_IOERR_SHMMAP, 5386) N(SQLITE_IOERR_SEEK, 5642)
        N(SQLITE_IOERR_DELETE_NOENT, 5898) N(SQLITE_IOERR_MMAP, 6154) N(SQLITE_IOERR_GETTEMPPATH, 6410)
        N(SQLITE_IOERR_CONVPATH, 6666) N(SQLITE_IOERR_VNODE, 6922) N(SQLITE_IOERR_AUTH, 7178)
        N(SQLITE_IOERR_BEGIN_ATOMIC, 7434) N(SQLITE_IOERR_COMMIT_ATOMIC, 7690) N(SQLITE_IOERR_ROLLBACK_ATOMIC, 7946)
        N(SQLITE_IOERR_DATA, 8202) N(SQLITE_IOERR_CORRUPTFS, 8458)
        N(SQLITE_LOCKED_SHAREDCACHE, 262) N(SQLITE_LOCKED_VTAB, 518)
        N(SQLITE_BUSY_RECOVERY, 261) N(SQLITE_BUSY_SNAPSHOT, 517) N(SQLITE_BUSY_TIMEOUT, 773)
        N(SQLITE_CANTOPEN_NOTEMPDIR, 270) N(SQLITE_CANTOPEN_ISDIR, 526) N(SQLITE_CANTOPEN_FULLPATH, 782)
        N(SQLITE_CANTOPEN_CONVPATH, 1038) N(SQLITE_CANTOPEN_DIRTYWAL, 1294) N(SQLITE_CANTOPEN_SYMLINK, 1550)
        N(SQLITE_CORRUPT_VTAB, 267) N(SQLITE_CORRUPT_SEQUENCE, 523) N(SQLITE_CORRUPT_INDEX, 779)
        N(SQLITE_READONLY_RECOVERY, 264) N(SQLITE_READONLY_CANTLOCK, 520) N(SQLITE_READONLY_ROLLBACK, 776)
        N(SQLITE_READONLY_DBMOVED, 1032) N(SQLITE_READONLY_CANTINIT, 1288) N(SQLITE_READONLY_DIRECTORY, 1544)
        N(SQLITE_ABORT_ROLLBACK, 516)
        N(SQLITE_CONSTRAINT_CHECK, 275) N(SQLITE_CONSTRAINT_COMMITHOOK, 531) N(SQLITE_CONSTRAINT_FOREIGNKEY, 787)
        N(SQLITE_CONSTRAINT_FUNCTION, 1043) N(SQLITE_CONSTRAINT_NOTNULL, 1299) N(SQLITE_CONSTRAINT_PRIMARYKEY, 1555)
        N(SQLITE_CONSTRAINT_TRIGGER, 1811) N(SQLITE_CONSTRAINT_UNIQUE, 2067) N(SQLITE_CONSTRAINT_VTAB, 2323)
        N(SQLITE_CONSTRAINT_ROWID, 2579) N(SQLITE_CONSTRAINT_PINNED, 2835) N(SQLITE_CONSTRAINT_DATATYPE, 3091)
        N(SQLITE_NOTICE_RECOVER_WAL, 283) N(SQLITE_NOTICE_RECOVER_ROLLBACK, 539)
        N(SQLITE_WARNING_AUTOINDEX, 284) N(SQLITE_AUTH_USER, 279) N(SQLITE_OK_LOAD_PERMANENTLY, 256)
        N(SQLITE_OK_SYMLINK, 512)
#undef N
        default: return nullptr;
    }
}

// ── values crossing between SQLite and the program ──────────────────────────
struct Val {
    int t = SQLITE_NULL;
    int64_t i = 0;
    double d = 0;
    std::string s;
};

Val from_sqlite(Api& a, sqlite3_value* v) {
    Val r;
    r.t = a.value_type(v);
    switch (r.t) {
        case SQLITE_INTEGER: r.i = a.value_int64(v); break;
        case SQLITE_FLOAT: r.d = a.value_double(v); break;
        case SQLITE_TEXT: {
            const unsigned char* p = a.value_text(v);
            int n = a.value_bytes(v);
            if (p) r.s.assign((const char*)p, (size_t)n);
            break;
        }
        case SQLITE_BLOB: {
            const void* p = a.value_blob(v);
            int n = a.value_bytes(v);
            if (p && n > 0) r.s.assign((const char*)p, (size_t)n);
            break;
        }
        default: r.t = SQLITE_NULL;
    }
    return r;
}

bool valid_utf8(const std::string& s) {
    const unsigned char* p = (const unsigned char*)s.data();
    size_t n = s.size(), i = 0;
    while (i < n) {
        unsigned c = p[i];
        if (c < 0x80) { i++; continue; }
        int len; unsigned cp;
        if ((c & 0xE0) == 0xC0) { len = 2; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { len = 3; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { len = 4; cp = c & 0x07; }
        else return false;
        if (i + len > n) return false;
        for (int k = 1; k < len; k++) {
            if ((p[i + k] & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (p[i + k] & 0x3F);
        }
        if ((len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) || (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)))
            return false;
        if (cp >= 0xD800 && cp <= 0xDFFF) return false;
        i += len;
    }
    return true;
}

Value to_value(NythonExecutor& E, const Val& v, bool text_as_bytes = false) {
    switch (v.t) {
        case SQLITE_INTEGER: return intValue((int64_t)v.i);
        case SQLITE_FLOAT: return Value(v.d);
        case SQLITE_TEXT: return text_as_bytes ? E.makeBytesValue(v.s) : E.makeStringValue(v.s);
        case SQLITE_BLOB: return E.makeBytesValue(v.s);
        default: return NONE_VALUE;
    }
}

// A program value as SQLite's: 0 ok, -1 a type SQLite does not store, -2 an
// int beyond 64 bits.
int from_value(NythonExecutor& E, const Value& v, Val& out) {
    switch (v.type) {
        case ValueType::NONE: out.t = SQLITE_NULL; return 0;
        case ValueType::BOOLEAN: out.t = SQLITE_INTEGER; out.i = v.value.b ? 1 : 0; return 0;
        case ValueType::INTEGER: {
            int64_t x;
            if (!bigint_fits_i64(v.value.i, x)) return -2;
            out.t = SQLITE_INTEGER; out.i = x; return 0;
        }
        case ValueType::DOUBLE: out.t = SQLITE_FLOAT; out.d = (double)v.value.d; return 0;
        default: break;
    }
    if (auto* bo = E.bytesOf(v)) { out.t = SQLITE_BLOB; out.s = bo->s; return 0; }
    if (E.isStringValue(v)) { out.t = SQLITE_TEXT; out.s = E.strOf(v, E.globalContext()); return 0; }
    return -1;
}

// ── handles ─────────────────────────────────────────────────────────────────
struct Conn {
    sqlite3* db = nullptr;
    int hooks = 0;            // callbacks registered: operations run on coroutines
    bool authorizer = false, progress = false, trace = false;
};
struct Stmt {
    sqlite3_stmt* st = nullptr;
    int64_t conn = 0;
};
struct FnData {                // a registered function's or collation's identity
    int64_t conn = 0, fid = 0;
};

std::mutex g_mu;
int64_t g_next = 1;
std::unordered_map<int64_t, std::shared_ptr<Conn>> g_conns;
std::unordered_map<int64_t, std::shared_ptr<Stmt>> g_stmts;
std::unordered_map<int64_t, sqlite3_backup*> g_backups;
std::unordered_map<int64_t, sqlite3_blob*> g_blobs;
std::unordered_map<void*, int64_t> g_conn_of_db;   // the callbacks' way back to the handle

int64_t new_id() { return g_next++; }

std::shared_ptr<Conn> get_conn(int64_t h) {
    std::lock_guard<std::mutex> l(g_mu);
    auto it = g_conns.find(h);
    if (it == g_conns.end() || !it->second->db) fail("ValueError", "invalid SQLite connection handle");
    return it->second;
}
std::shared_ptr<Stmt> get_stmt(int64_t h) {
    std::lock_guard<std::mutex> l(g_mu);
    auto it = g_stmts.find(h);
    if (it == g_stmts.end() || !it->second->st) fail("ValueError", "invalid SQLite statement handle");
    return it->second;
}

// ── operations on coroutines ────────────────────────────────────────────────
enum Kind { K_FUNC = 1, K_STEP = 2, K_FINAL = 3, K_VALUE = 4, K_INVERSE = 5, K_COLLATE = 6,
            K_AUTH = 7, K_PROGRESS = 8, K_TRACE = 9, K_PROFILE = 10 };

struct Op {
    int64_t id = 0;
    nycoro::Coro* coro = nullptr;
    std::function<void()> body;
    std::vector<Val> out;                  // the operation's results
    // a callback's request
    int kind = 0;
    int64_t fid = 0, key = 0;
    std::vector<Val> args;
    // the program's reply
    int status = 0;                        // 0 value, 1 the callable raised, 2 cannot convert, 3 AttributeError
    Val reply;
    bool waiting = false;
};

thread_local Op* t_cur = nullptr;
std::unordered_map<int64_t, std::shared_ptr<Op>> g_ops;
std::atomic<int64_t> g_next_key{1};

void op_entry(void* arg) {
    Op* op = (Op*)arg;
    try { op->body(); }
    catch (...) { op->out.clear(); Val v; v.t = SQLITE_INTEGER; v.i = SQLITE_NOMEM; op->out.push_back(v); }
}

// From a SQLite callback: ask the program, wait for its reply. False when no
// operation of ours is running on this coroutine (the callback then gives
// SQLite a neutral answer).
bool ask(int kind, int64_t fid, int64_t key, std::vector<Val>&& args) {
    Op* op = t_cur;
    if (!op || !op->coro || nycoro::current() != op->coro) return false;
    op->kind = kind; op->fid = fid; op->key = key; op->args = std::move(args);
    op->status = 0; op->reply = Val();
    op->waiting = true;
    nycoro::suspend();
    op->waiting = false;
    return true;
}

Value make_result(NythonExecutor& E, Op& op) {
    std::vector<Value> r{intValue((int64_t)0)};
    for (auto& v : op.out) r.push_back(to_value(E, v));
    return E.makeListValue(r);
}

Value make_request(NythonExecutor& E, Op& op) {
    std::vector<Value> args;
    for (auto& v : op.args) args.push_back(to_value(E, v, op.kind == K_COLLATE ? false : false));
    std::vector<Value> r{intValue((int64_t)1), intValue(op.id), intValue((int64_t)op.kind), intValue(op.fid),
                         intValue(op.key), E.makeListValue(args)};
    return E.makeListValue(r);
}

// Resume (or start) an operation; its result, or the request it stopped at.
Value drive(NythonExecutor& E, std::shared_ptr<Op> op) {
    {
        nyconc::GilRelease g;
        Op* saved = t_cur;
        t_cur = op.get();
        nycoro::resume(op->coro);
        t_cur = saved;
    }
    if (nycoro::done(op->coro)) {
        nycoro::destroy(op->coro);
        op->coro = nullptr;
        { std::lock_guard<std::mutex> l(g_mu); g_ops.erase(op->id); }
        return make_result(E, *op);
    }
    return make_request(E, *op);
}

// Run `body` (which fills op->out): on a coroutine when the connection has
// callbacks, else here with the GIL released.
Value run(NythonExecutor& E, const std::shared_ptr<Conn>& c, std::function<void(Op&)> body) {
    auto op = std::make_shared<Op>();
    Op* raw = op.get();
    op->body = [raw, body]() { body(*raw); };
    if (!c || c->hooks == 0) {
        {
            nyconc::GilRelease g;
            Op* saved = t_cur;
            t_cur = nullptr;
            op->body();
            t_cur = saved;
        }
        return make_result(E, *op);
    }
    op->coro = nycoro::create(op_entry, raw, 0);
    {
        std::lock_guard<std::mutex> l(g_mu);
        op->id = new_id();
        g_ops[op->id] = op;
    }
    return drive(E, op);
}

Val ival(int64_t x) { Val v; v.t = SQLITE_INTEGER; v.i = x; return v; }

// (round 83) Every SQLite call that may take the connection's mutex runs with
// the GIL released. A thread whose statement is paused in a callback holds
// that (recursive) mutex while it runs the callback's Nython code, which needs
// the GIL: another thread waiting for the mutex with the GIL held would
// deadlock them both. Nothing inside touches a Value.
template <class F> auto nogil(F&& f) -> decltype(f()) { nyconc::GilRelease g; return f(); }

// ── the C callbacks (on an operation's coroutine, GIL released) ─────────────
void set_result(Api& a, sqlite3_context* ctx, Op* op, const char* errmsg) {
    if (op->status == 5) { a.result_error_toobig(ctx); return; }   // an int beyond 64 bits, as CPython
    if (op->status != 0) { a.result_error(ctx, errmsg, -1); return; }
    Val& r = op->reply;
    switch (r.t) {
        case SQLITE_INTEGER: a.result_int64(ctx, r.i); break;
        case SQLITE_FLOAT: a.result_double(ctx, r.d); break;
        case SQLITE_TEXT: a.result_text(ctx, r.s.data(), (int)r.s.size(), SQLITE_TRANSIENT_); break;
        case SQLITE_BLOB: a.result_blob(ctx, r.s.data(), (int)r.s.size(), SQLITE_TRANSIENT_); break;
        default: a.result_null(ctx);
    }
}

std::vector<Val> args_of(Api& a, int argc, sqlite3_value** argv) {
    std::vector<Val> v;
    v.reserve(argc);
    for (int i = 0; i < argc; i++) v.push_back(from_sqlite(a, argv[i]));
    return v;
}

void cb_func(sqlite3_context* ctx, int argc, sqlite3_value** argv) {
    Api& a = api();
    FnData* fd = (FnData*)a.user_data(ctx);
    if (!ask(K_FUNC, fd->fid, 0, args_of(a, argc, argv))) {
        a.result_error(ctx, "user-defined function called outside of a statement", -1);
        return;
    }
    set_result(a, ctx, t_cur, "user-defined function raised exception");
}

int64_t agg_key(Api& a, sqlite3_context* ctx, bool create) {
    int64_t* p = (int64_t*)a.aggregate_context(ctx, create ? (int)sizeof(int64_t) : 0);
    if (!p) return 0;
    if (*p == 0 && create) *p = g_next_key++;
    return *p;
}

void cb_step(sqlite3_context* ctx, int argc, sqlite3_value** argv) {
    Api& a = api();
    FnData* fd = (FnData*)a.user_data(ctx);
    int64_t key = agg_key(a, ctx, true);
    if (!key) { a.result_error_nomem(ctx); return; }
    if (!ask(K_STEP, fd->fid, key, args_of(a, argc, argv))) { a.result_error(ctx, "aggregate called outside of a statement", -1); return; }
    Op* op = t_cur;
    if (op->status == 3) a.result_error(ctx, "user-defined aggregate's 'step' method not defined", -1);
    else if (op->status == 4) a.result_error(ctx, "user-defined aggregate's '__init__' method raised error", -1);
    else if (op->status != 0) a.result_error(ctx, "user-defined aggregate's 'step' method raised error", -1);
}

void cb_inverse(sqlite3_context* ctx, int argc, sqlite3_value** argv) {
    Api& a = api();
    FnData* fd = (FnData*)a.user_data(ctx);
    int64_t key = agg_key(a, ctx, true);
    if (!key) { a.result_error_nomem(ctx); return; }
    if (!ask(K_INVERSE, fd->fid, key, args_of(a, argc, argv))) { a.result_error(ctx, "aggregate called outside of a statement", -1); return; }
    Op* op = t_cur;
    if (op->status == 3) a.result_error(ctx, "user-defined aggregate's 'inverse' method not defined", -1);
    else if (op->status != 0) a.result_error(ctx, "user-defined aggregate's 'inverse' method raised error", -1);
}

void final_like(sqlite3_context* ctx, int kind, const char* method) {
    Api& a = api();
    FnData* fd = (FnData*)a.user_data(ctx);
    int64_t key = agg_key(a, ctx, kind == K_VALUE);
    if (!ask(kind, fd->fid, key, {})) { a.result_error(ctx, "aggregate called outside of a statement", -1); return; }
    Op* op = t_cur;
    std::string m = std::string("user-defined aggregate's '") + method + "' method ";
    if (op->status == 3) a.result_error(ctx, (m + "not defined").c_str(), -1);
    else if (op->status == 4) a.result_error(ctx, "user-defined aggregate's '__init__' method raised error", -1);
    else if (op->status != 0) a.result_error(ctx, (m + "raised error").c_str(), -1);
    else set_result(a, ctx, op, "");
}
void cb_final(sqlite3_context* ctx) { final_like(ctx, K_FINAL, "finalize"); }
void cb_value(sqlite3_context* ctx) { final_like(ctx, K_VALUE, "value"); }

void cb_destroy(void* p) { delete (FnData*)p; }

int cb_collate(void* p, int n1, const void* s1, int n2, const void* s2) {
    FnData* fd = (FnData*)p;
    std::vector<Val> args(2);
    args[0].t = args[1].t = SQLITE_TEXT;
    args[0].s.assign((const char*)s1, (size_t)n1);
    args[1].s.assign((const char*)s2, (size_t)n2);
    if (!ask(K_COLLATE, fd->fid, 0, std::move(args))) return 0;
    Op* op = t_cur;
    if (op->status != 0 || op->reply.t != SQLITE_INTEGER) return 0;
    return op->reply.i < 0 ? -1 : op->reply.i > 0 ? 1 : 0;
}

int cb_auth(void* p, int action, const char* a1, const char* a2, const char* a3, const char* a4) {
    (void)p;
    std::vector<Val> args;
    args.push_back(ival(action));
    for (const char* s : {a1, a2, a3, a4}) {
        Val v;
        if (s) { v.t = SQLITE_TEXT; v.s = s; }
        args.push_back(v);
    }
    if (!ask(K_AUTH, 0, 0, std::move(args))) return 0;
    Op* op = t_cur;
    if (op->status != 0 || op->reply.t != SQLITE_INTEGER) return SQLITE_DENY;
    return (int)op->reply.i;
}

int cb_progress(void* p) {
    (void)p;
    if (!ask(K_PROGRESS, 0, 0, {})) return 0;
    Op* op = t_cur;
    if (op->status != 0) return 1;
    return op->reply.t == SQLITE_INTEGER && op->reply.i != 0 ? 1 : 0;
}

int cb_trace(unsigned type, void* p, void* stmt, void* x) {
    (void)p;
    Api& a = api();
    if (type == SQLITE_TRACE_STMT) {
        Val v;
        v.t = SQLITE_TEXT;
        char* ex = a.expanded_sql ? a.expanded_sql(stmt) : nullptr;
        if (ex) { v.s = ex; a.free_(ex); }
        else if (x) v.s = (const char*)x;
        std::vector<Val> args{v};
        ask(K_TRACE, 0, 0, std::move(args));
    } else if (type == SQLITE_TRACE_PROFILE) {
        // (Nython-only: Connection.set_profile_callback) the statement that
        // finished and the nanoseconds it ran
        Val v;
        v.t = SQLITE_TEXT;
        char* ex = a.expanded_sql ? a.expanded_sql(stmt) : nullptr;
        if (ex) { v.s = ex; a.free_(ex); }
        else { const char* q = a.sql(stmt); if (q) v.s = q; }
        std::vector<Val> args{v, ival(x ? (int64_t)*(sqlite3_int64*)x : 0)};
        ask(K_PROFILE, 0, 0, std::move(args));
    }
    return 0;
}

// The first character of `sql` that is not a blank or inside a comment
// (CPython 3.12's lstrip_sql), nullptr when there is none.
const char* lstrip_sql(const char* pos, const char* end) {
    for (; pos < end && *pos; pos++) {
        switch (*pos) {
            case ' ': case '\t': case '\f': case '\n': case '\r': break;
            case '-':
                if (pos + 1 < end && pos[1] == '-') {
                    pos += 2;
                    while (pos < end && *pos && *pos != '\n') pos++;
                    if (pos >= end || !*pos) return nullptr;
                    continue;
                }
                return pos;
            case '/':
                if (pos + 1 < end && pos[1] == '*') {
                    pos += 2;
                    while (pos < end && *pos && (*pos != '*' || pos + 1 >= end || pos[1] != '/')) pos++;
                    if (pos >= end || !*pos) return nullptr;
                    pos++;
                    continue;
                }
                return pos;
            default: return pos;
        }
    }
    return nullptr;
}

// ── natives ─────────────────────────────────────────────────────────────────
int64_t iarg(NythonExecutor& E, std::vector<Value>& A, size_t i, int64_t dflt = 0) {
    (void)E;
    if (i >= A.size()) return dflt;
    const Value& v = A[i];
    if (v.type == ValueType::NONE) return dflt;
    if (v.type == ValueType::BOOLEAN) return v.value.b ? 1 : 0;
    if (v.type != ValueType::INTEGER) fail("TypeError", "an integer is required");
    int64_t x;
    if (!bigint_fits_i64(v.value.i, x)) fail("OverflowError", "Python int too large to convert to C int");
    return x;
}
std::string sarg(NythonExecutor& E, std::vector<Value>& A, size_t i) {
    if (i >= A.size() || A[i].type == ValueType::NONE) return std::string();
    if (auto* bo = E.bytesOf(A[i])) return bo->s;
    return E.strOf(A[i], E.globalContext());
}
bool has_arg(std::vector<Value>& A, size_t i) { return i < A.size() && A[i].type != ValueType::NONE; }

} // namespace

std::vector<std::string> sqlite_builtin_names() {
    return {"_sql_available", "_sql_why", "_sql_version", "_sql_open", "_sql_close", "_sql_errinfo", "_sql_errname",
            "_sql_errstr", "_sql_busy_timeout", "_sql_autocommit", "_sql_changes", "_sql_total_changes",
            "_sql_last_rowid", "_sql_interrupt", "_sql_limit", "_sql_db_config", "_sql_complete", "_sql_prepare",
            "_sql_step", "_sql_exec", "_sql_resume", "_sql_finalize", "_sql_reset", "_sql_clear_bindings",
            "_sql_bind_count", "_sql_bind_name", "_sql_bind", "_sql_columns", "_sql_column_count", "_sql_row",
            "_sql_readonly", "_sql_busy", "_sql_stmt_sql", "_sql_create_function", "_sql_create_collation",
            "_sql_set_authorizer", "_sql_set_progress", "_sql_set_trace", "_sql_backup_init", "_sql_backup_step",
            "_sql_backup_finish", "_sql_blob_open", "_sql_blob_close", "_sql_blob_bytes", "_sql_blob_read",
            "_sql_blob_write", "_sql_serialize", "_sql_deserialize", "_sql_enable_load_extension",
            "_sql_load_extension", "_sql_txn_state", "_sql_filename", "_sql_has"};
}

Value dispatch_sqlite(NythonExecutor& E, const std::string& name, std::vector<Value>& A, Context* ctx) {
    (void)ctx;
    if (name.compare(0, 5, "_sql_") != 0) return UNDEFINED_VALUE;
    if (name == "_sql_available") return Value(api().ok);
    if (name == "_sql_why") return E.makeStringValue(api().why);
    if (name == "_sql_version") {
        Api& a = need();
        std::vector<Value> r{E.makeStringValue(a.libversion()), intValue((int64_t)a.libversion_number()),
                             intValue((int64_t)a.threadsafe()), E.makeStringValue(g_lib_name)};
        return E.makeListValue(r);
    }
    if (name == "_sql_has") {   // an optional entry point: window functions, backup, blob, serialize ...
        Api& a = need();
        std::string w = sarg(E, A, 0);
        bool r = w == "window" ? a.create_window_function != nullptr
               : w == "backup" ? a.backup_init != nullptr
               : w == "blob" ? a.blob_open != nullptr
               : w == "serialize" ? (a.serialize && a.deserialize && a.malloc64)
               : w == "load_extension" ? (a.enable_load_extension && a.load_extension)
               : w == "db_config" ? a.db_config != nullptr
               : w == "authorizer" ? a.set_authorizer != nullptr
               : w == "progress" ? a.progress_handler != nullptr
               : w == "trace" ? a.trace_v2 != nullptr
               : w == "txn_state" ? a.txn_state != nullptr : false;
        return Value(r);
    }
    if (name == "_sql_errname") {
        const char* n = code_name((int)iarg(E, A, 0));
        return n ? E.makeStringValue(n) : E.makeStringValue("SQLITE_UNKNOWN");
    }
    if (name == "_sql_errstr") { Api& a = need(); return E.makeStringValue(a.errstr((int)iarg(E, A, 0))); }
    if (name == "_sql_complete") {
        Api& a = need();
        std::string s = sarg(E, A, 0);
        return Value(a.complete(s.c_str()) != 0);
    }
    if (name == "_sql_open") {
        Api& a = need();
        std::string path = sarg(E, A, 0);
        int flags = (int)iarg(E, A, 1, 6);
        std::string vfs = sarg(E, A, 2);
        sqlite3* db = nullptr;
        int rc;
        {
            nyconc::GilRelease g;
            rc = a.open_v2(path.c_str(), &db, flags, vfs.empty() ? nullptr : vfs.c_str());
        }
        auto c = std::make_shared<Conn>();
        c->db = db;
        int64_t h;
        {
            std::lock_guard<std::mutex> l(g_mu);
            h = new_id();
            g_conns[h] = c;
            if (db) g_conn_of_db[db] = h;
        }
        std::vector<Value> r{intValue((int64_t)rc), db ? intValue(h) : NONE_VALUE};
        return E.makeListValue(r);
    }
    if (name == "_sql_close") {
        Api& a = need();
        int64_t h = iarg(E, A, 0);
        std::shared_ptr<Conn> c;
        std::vector<std::shared_ptr<Stmt>> mine;
        {
            std::lock_guard<std::mutex> l(g_mu);
            auto it = g_conns.find(h);
            if (it == g_conns.end() || !it->second->db) return intValue((int64_t)0);
            c = it->second;
            for (auto it2 = g_stmts.begin(); it2 != g_stmts.end();) {
                if (it2->second->conn == h) { mine.push_back(it2->second); it2 = g_stmts.erase(it2); }
                else ++it2;
            }
        }
        int rc;
        {
            nyconc::GilRelease g;
            for (auto& s : mine) if (s->st) { a.finalize(s->st); s->st = nullptr; }
            rc = a.close_v2(c->db);
        }
        std::lock_guard<std::mutex> l(g_mu);
        g_conn_of_db.erase(c->db);
        c->db = nullptr;
        g_conns.erase(h);
        return intValue((int64_t)rc);
    }
    if (name == "_sql_errinfo") {
        Api& a = need();
        auto c = get_conn(iarg(E, A, 0));
        int code = 0, ext = 0;
        std::string msg;
        nogil([&] {
            code = a.errcode(c->db); ext = a.extended_errcode(c->db);
            const char* m = a.errmsg(c->db);
            if (m) msg = m;
        });
        const char* n = code_name(ext);
        if (!n) n = code_name(code);
        std::vector<Value> r{intValue((int64_t)code), intValue((int64_t)ext), E.makeStringValue(n ? n : "SQLITE_UNKNOWN"),
                             E.makeStringValue(msg)};
        return E.makeListValue(r);
    }
    if (name == "_sql_busy_timeout") {
        Api& a = need(); auto c = get_conn(iarg(E, A, 0)); int ms = (int)iarg(E, A, 1);
        return intValue((int64_t)nogil([&] { return a.busy_timeout(c->db, ms); }));
    }
    if (name == "_sql_autocommit") { Api& a = need(); auto c = get_conn(iarg(E, A, 0)); return Value(nogil([&] { return a.get_autocommit(c->db); }) != 0); }
    if (name == "_sql_changes") {
        Api& a = need(); auto c = get_conn(iarg(E, A, 0));
        return intValue(nogil([&] { return a.changes64 ? (int64_t)a.changes64(c->db) : (int64_t)a.changes(c->db); }));
    }
    if (name == "_sql_total_changes") {
        Api& a = need(); auto c = get_conn(iarg(E, A, 0));
        return intValue(nogil([&] { return a.total_changes64 ? (int64_t)a.total_changes64(c->db) : (int64_t)a.total_changes(c->db); }));
    }
    if (name == "_sql_last_rowid") { Api& a = need(); auto c = get_conn(iarg(E, A, 0)); return intValue((int64_t)nogil([&] { return a.last_insert_rowid(c->db); })); }
    if (name == "_sql_interrupt") { Api& a = need(); auto c = get_conn(iarg(E, A, 0)); a.interrupt(c->db); return NONE_VALUE; }
    if (name == "_sql_limit") {
        Api& a = need(); auto c = get_conn(iarg(E, A, 0));
        int id = (int)iarg(E, A, 1), nv = (int)iarg(E, A, 2, -1);
        return intValue((int64_t)nogil([&] { return a.limit(c->db, id, nv); }));
    }
    if (name == "_sql_db_config") {
        Api& a = need(); auto c = get_conn(iarg(E, A, 0));
        if (!a.db_config) fail("NotSupportedError", "sqlite3_db_config is not available");
        int out = 0, op = (int)iarg(E, A, 1), on = (int)iarg(E, A, 2, -1);
        int rc = nogil([&] { return a.db_config(c->db, op, on, &out); });
        std::vector<Value> r{intValue((int64_t)rc), intValue((int64_t)out)};
        return E.makeListValue(r);
    }
    if (name == "_sql_txn_state") {
        Api& a = need(); auto c = get_conn(iarg(E, A, 0));
        std::string s = sarg(E, A, 1);
        if (!a.txn_state) return intValue((int64_t)-1);
        bool named = has_arg(A, 1);
        return intValue((int64_t)nogil([&] { return a.txn_state(c->db, named ? s.c_str() : nullptr); }));
    }
    if (name == "_sql_filename") {
        Api& a = need(); auto c = get_conn(iarg(E, A, 0));
        std::string s = has_arg(A, 1) ? sarg(E, A, 1) : std::string("main");
        bool got = false;
        std::string fn;
        nogil([&] {
            const char* f = a.db_filename ? a.db_filename(c->db, s.c_str()) : nullptr;
            if (f) { got = true; fn = f; }
        });
        return got ? E.makeStringValue(fn) : NONE_VALUE;
    }
    if (name == "_sql_prepare") {
        Api& a = need();
        int64_t h = iarg(E, A, 0);
        auto c = get_conn(h);
        auto sql = std::make_shared<std::string>(sarg(E, A, 1));
        size_t off = (size_t)iarg(E, A, 2);
        if (off > sql->size()) off = sql->size();
        sqlite3* db = c->db;
        return run(E, c, [&a, db, sql, off, h](Op& op) {
            sqlite3_stmt* st = nullptr;
            const char* tail = nullptr;
            const char* base = sql->c_str();
            int rc = a.prepare_v2(db, base + off, (int)(sql->size() - off), &st, &tail);
            int64_t sid = 0;
            if (st) {
                auto s = std::make_shared<Stmt>();
                s->st = st;
                s->conn = h;
                std::lock_guard<std::mutex> l(g_mu);
                sid = new_id();
                g_stmts[sid] = s;
            }
            // CPython 3.12's statement checks: anything but blanks and
            // comments after the statement, and whether it is DML
            const char* end = base + sql->size();
            const char* rest = tail ? lstrip_sql(tail, end) : nullptr;
            const char* p = lstrip_sql(base + off, end);
            bool dml = false;
            if (p) {
                auto starts = [&](const char* w) {
                    size_t n = strlen(w);
                    if ((size_t)(end - p) < n) return false;
                    for (size_t k = 0; k < n; k++) if (tolower((unsigned char)p[k]) != w[k]) return false;
                    return true;
                };
                dml = starts("insert") || starts("update") || starts("delete") || starts("replace");
            }
            op.out = {ival(rc), ival(sid), ival(tail ? (int64_t)(tail - base) : (int64_t)sql->size()),
                      ival(rest ? 1 : 0), ival(dml ? 1 : 0)};
        });
    }
    if (name == "_sql_step") {
        Api& a = need();
        auto s = get_stmt(iarg(E, A, 0));
        std::shared_ptr<Conn> c;
        { std::lock_guard<std::mutex> l(g_mu); auto it = g_conns.find(s->conn); if (it != g_conns.end()) c = it->second; }
        return run(E, c, [&a, s](Op& op) { op.out = {ival(a.step(s->st))}; });
    }
    if (name == "_sql_exec") {
        Api& a = need();
        auto c = get_conn(iarg(E, A, 0));
        auto sql = std::make_shared<std::string>(sarg(E, A, 1));
        sqlite3* db = c->db;
        return run(E, c, [&a, db, sql](Op& op) { op.out = {ival(a.exec(db, sql->c_str(), nullptr, nullptr, nullptr))}; });
    }
    if (name == "_sql_resume") {
        int64_t id = iarg(E, A, 0);
        std::shared_ptr<Op> op;
        {
            std::lock_guard<std::mutex> l(g_mu);
            auto it = g_ops.find(id);
            if (it == g_ops.end()) fail("ValueError", "no such SQLite operation");
            op = it->second;
        }
        if (!op->waiting) fail("RuntimeError", "the SQLite operation is not waiting for a callback");
        op->status = (int)iarg(E, A, 1);
        op->reply = Val();
        if (op->status == 0 && A.size() > 2) {
            int r = from_value(E, A[2], op->reply);
            if (r != 0) op->status = r == -2 ? 5 : 2;
        }
        return drive(E, op);
    }
    if (name == "_sql_finalize") {
        Api& a = need();
        int64_t sid = iarg(E, A, 0);
        std::shared_ptr<Stmt> s;
        {
            std::lock_guard<std::mutex> l(g_mu);
            auto it = g_stmts.find(sid);
            if (it == g_stmts.end()) return intValue((int64_t)0);
            s = it->second;
            g_stmts.erase(it);
        }
        int rc = s->st ? nogil([&] { return a.finalize(s->st); }) : 0;
        s->st = nullptr;
        return intValue((int64_t)rc);
    }
    if (name == "_sql_reset") { Api& a = need(); auto s = get_stmt(iarg(E, A, 0)); return intValue((int64_t)nogil([&] { return a.reset(s->st); })); }
    if (name == "_sql_clear_bindings") { Api& a = need(); auto s = get_stmt(iarg(E, A, 0)); return intValue((int64_t)nogil([&] { return a.clear_bindings(s->st); })); }
    if (name == "_sql_bind_count") { Api& a = need(); auto s = get_stmt(iarg(E, A, 0)); return intValue((int64_t)a.bind_parameter_count(s->st)); }
    if (name == "_sql_bind_name") {
        Api& a = need(); auto s = get_stmt(iarg(E, A, 0));
        const char* n = a.bind_parameter_name(s->st, (int)iarg(E, A, 1));
        return n ? E.makeStringValue(n) : NONE_VALUE;
    }
    if (name == "_sql_bind") {
        Api& a = need();
        auto s = get_stmt(iarg(E, A, 0));
        int i = (int)iarg(E, A, 1);
        Val v;
        int r = A.size() > 2 ? from_value(E, A[2], v) : 0;
        if (r != 0) return intValue((int64_t)r);
        int rc = nogil([&] {
            switch (v.t) {
                case SQLITE_INTEGER: return a.bind_int64(s->st, i, v.i);
                case SQLITE_FLOAT: return a.bind_double(s->st, i, v.d);
                case SQLITE_TEXT: return a.bind_text(s->st, i, v.s.data(), (int)v.s.size(), SQLITE_TRANSIENT_);
                case SQLITE_BLOB: return a.bind_blob(s->st, i, v.s.data(), (int)v.s.size(), SQLITE_TRANSIENT_);
                default: return a.bind_null(s->st, i);
            }
        });
        return intValue((int64_t)rc);
    }
    if (name == "_sql_column_count") { Api& a = need(); auto s = get_stmt(iarg(E, A, 0)); return intValue((int64_t)a.column_count(s->st)); }
    if (name == "_sql_columns") {
        Api& a = need();
        auto s = get_stmt(iarg(E, A, 0));
        std::vector<Val> names, decls;      // SQLITE_NULL for a column without one
        nogil([&] {
            int n = a.column_count(s->st);
            names.resize(n); decls.resize(n);
            for (int i = 0; i < n; i++) {
                const char* nm = a.column_name(s->st, i);
                const char* dt = a.column_decltype ? a.column_decltype(s->st, i) : nullptr;
                if (nm) { names[i].t = SQLITE_TEXT; names[i].s = nm; }
                if (dt) { decls[i].t = SQLITE_TEXT; decls[i].s = dt; }
            }
        });
        std::vector<Value> cols;
        for (size_t i = 0; i < names.size(); i++) {
            std::vector<Value> pr{names[i].t == SQLITE_TEXT ? E.makeStringValue(names[i].s) : NONE_VALUE,
                                  decls[i].t == SQLITE_TEXT ? E.makeStringValue(decls[i].s) : NONE_VALUE};
            cols.push_back(E.makeListValue(pr));
        }
        return E.makeListValue(cols);
    }
    if (name == "_sql_row") {
        Api& a = need();
        auto s = get_stmt(iarg(E, A, 0));
        int64_t mode = iarg(E, A, 1, 0);         // 0 text as str, 1 as bytes, 2 as bytes plus the types
        bool text_bytes = mode != 0;
        std::vector<Value> types;
        std::vector<bool> raw;
        if (has_arg(A, 2)) for (auto& v : E.listItems(A[2])) raw.push_back(E.isTruthy(v));
        // the columns are read with the GIL released, the values made after
        std::vector<int> ts;
        std::vector<Val> vs;
        nogil([&] {
            int n = a.column_count(s->st);
            ts.resize(n); vs.resize(n);
            for (int i = 0; i < n; i++) {
                int t = ts[i] = a.column_type(s->st, i);
                Val& v = vs[i];
                if (t == SQLITE_NULL) continue;
                bool blob = (i < (int)raw.size() && raw[i]) || (t != SQLITE_INTEGER && t != SQLITE_FLOAT && t != SQLITE_TEXT);
                if (blob) {
                    const void* p = a.column_blob(s->st, i);
                    int nb = a.column_bytes(s->st, i);
                    v.t = SQLITE_BLOB;
                    if (p) v.s.assign((const char*)p, (size_t)nb);
                } else if (t == SQLITE_INTEGER) { v.t = SQLITE_INTEGER; v.i = (int64_t)a.column_int64(s->st, i); }
                else if (t == SQLITE_FLOAT) { v.t = SQLITE_FLOAT; v.d = a.column_double(s->st, i); }
                else {
                    const unsigned char* p = a.column_text(s->st, i);
                    int nb = a.column_bytes(s->st, i);
                    v.t = SQLITE_TEXT;
                    if (p) v.s.assign((const char*)p, (size_t)nb);
                }
            }
        });
        std::vector<Value> row;
        row.reserve(vs.size());
        for (size_t i = 0; i < vs.size(); i++) {
            if (mode == 2) types.push_back(intValue((int64_t)ts[i]));
            Val& v = vs[i];
            if (ts[i] == SQLITE_NULL) { row.push_back(NONE_VALUE); continue; }
            switch (v.t) {
                case SQLITE_INTEGER: row.push_back(intValue(v.i)); break;
                case SQLITE_FLOAT: row.push_back(Value(v.d)); break;
                case SQLITE_TEXT:
                    if (text_bytes) { row.push_back(E.makeBytesValue(v.s)); break; }
                    if (!valid_utf8(v.s)) {
                        std::vector<Value> bad{intValue((int64_t)i), E.makeBytesValue(v.s)};
                        return E.makeListValue(bad, true);    // a tuple: the column that is not UTF-8
                    }
                    row.push_back(E.makeStringValue(v.s));
                    break;
                default: row.push_back(E.makeBytesValue(v.s));
            }
        }
        if (mode == 2) { std::vector<Value> pr{E.makeListValue(row), E.makeListValue(types)}; return E.makeListValue(pr); }
        return E.makeListValue(row);
    }
    if (name == "_sql_readonly") { Api& a = need(); auto s = get_stmt(iarg(E, A, 0)); return Value(a.stmt_readonly(s->st) != 0); }
    if (name == "_sql_busy") { Api& a = need(); auto s = get_stmt(iarg(E, A, 0)); return Value(a.stmt_busy(s->st) != 0); }
    if (name == "_sql_stmt_sql") { Api& a = need(); auto s = get_stmt(iarg(E, A, 0)); const char* q = a.sql(s->st); return E.makeStringValue(q ? q : ""); }
    if (name == "_sql_create_function") {
        Api& a = need();
        int64_t h = iarg(E, A, 0);
        auto c = get_conn(h);
        std::string fname = sarg(E, A, 1);
        int narg = (int)iarg(E, A, 2, -1), flags = (int)iarg(E, A, 3, 0) | SQLITE_UTF8;
        int kind = (int)iarg(E, A, 4, 0);
        int64_t fid = iarg(E, A, 5, 0);
        if (kind == 2 && !a.create_window_function) fail("NotSupportedError", "create_window_function() requires SQLite 3.25.0 or higher");
        int rc = nogil([&] {
            if (kind == 2) {
                if (!fid) return a.create_window_function(c->db, fname.c_str(), narg, flags, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
                auto* fd = new FnData{h, fid};
                return a.create_window_function(c->db, fname.c_str(), narg, flags, fd, cb_step, cb_final, cb_value, cb_inverse, cb_destroy);
            }
            if (!fid) return a.create_function_v2(c->db, fname.c_str(), narg, flags, nullptr, nullptr, nullptr, nullptr, nullptr);
            auto* fd = new FnData{h, fid};
            if (kind == 1) return a.create_function_v2(c->db, fname.c_str(), narg, flags, fd, nullptr, cb_step, cb_final, cb_destroy);
            return a.create_function_v2(c->db, fname.c_str(), narg, flags, fd, cb_func, nullptr, nullptr, cb_destroy);
        });
        if (rc == SQLITE_OK) c->hooks += fid ? 1 : 0;
        return intValue((int64_t)rc);
    }
    if (name == "_sql_create_collation") {
        Api& a = need();
        int64_t h = iarg(E, A, 0);
        auto c = get_conn(h);
        std::string cname = sarg(E, A, 1);
        int64_t fid = iarg(E, A, 2, 0);
        int rc = nogil([&] {
            if (!fid) return a.create_collation_v2(c->db, cname.c_str(), SQLITE_UTF8, nullptr, nullptr, nullptr);
            return a.create_collation_v2(c->db, cname.c_str(), SQLITE_UTF8, new FnData{h, fid}, cb_collate, cb_destroy);
        });
        if (rc == SQLITE_OK && fid) c->hooks++;
        return intValue((int64_t)rc);
    }
    if (name == "_sql_set_authorizer") {
        Api& a = need();
        auto c = get_conn(iarg(E, A, 0));
        bool on = A.size() > 1 && E.isTruthy(A[1]);
        if (!a.set_authorizer) fail("NotSupportedError", "sqlite3_set_authorizer is not available");
        int rc = nogil([&] { return a.set_authorizer(c->db, on ? cb_auth : nullptr, nullptr); });
        if (on != c->authorizer) { c->hooks += on ? 1 : -1; c->authorizer = on; }
        return intValue((int64_t)rc);
    }
    if (name == "_sql_set_progress") {
        Api& a = need();
        auto c = get_conn(iarg(E, A, 0));
        bool on = A.size() > 1 && E.isTruthy(A[1]);
        if (!a.progress_handler) fail("NotSupportedError", "sqlite3_progress_handler is not available");
        int every = (int)iarg(E, A, 2, 0);
        nogil([&] { a.progress_handler(c->db, every, on ? cb_progress : nullptr, nullptr); });
        if (on != c->progress) { c->hooks += on ? 1 : -1; c->progress = on; }
        return NONE_VALUE;
    }
    if (name == "_sql_set_trace") {     // (h, statements, profile)
        Api& a = need();
        auto c = get_conn(iarg(E, A, 0));
        bool on = A.size() > 1 && E.isTruthy(A[1]);
        bool prof = A.size() > 2 && E.isTruthy(A[2]);
        if (!a.trace_v2) fail("NotSupportedError", "sqlite3_trace_v2 is not available");
        unsigned mask = (on ? SQLITE_TRACE_STMT : 0) | (prof ? SQLITE_TRACE_PROFILE : 0);
        nogil([&] { return a.trace_v2(c->db, mask, mask ? cb_trace : nullptr, nullptr); });
        bool any = mask != 0;
        if (any != c->trace) { c->hooks += any ? 1 : -1; c->trace = any; }
        return NONE_VALUE;
    }
    if (name == "_sql_backup_init") {
        Api& a = need();
        if (!a.backup_init) fail("NotSupportedError", "the SQLite library has no backup API");
        auto dst = get_conn(iarg(E, A, 0));
        std::string dn = sarg(E, A, 1);
        auto src = get_conn(iarg(E, A, 2));
        std::string sn = sarg(E, A, 3);
        sqlite3_backup* b;
        int err = 0;
        {
            nyconc::GilRelease g;
            b = a.backup_init(dst->db, dn.c_str(), src->db, sn.c_str());
            if (!b) err = a.errcode(dst->db);
        }
        if (!b) { std::vector<Value> r{intValue((int64_t)err), NONE_VALUE}; return E.makeListValue(r); }
        std::lock_guard<std::mutex> l(g_mu);
        int64_t id = new_id();
        g_backups[id] = b;
        std::vector<Value> r{intValue((int64_t)0), intValue(id)};
        return E.makeListValue(r);
    }
    if (name == "_sql_backup_step") {
        Api& a = need();
        sqlite3_backup* b;
        {
            std::lock_guard<std::mutex> l(g_mu);
            auto it = g_backups.find(iarg(E, A, 0));
            if (it == g_backups.end()) fail("ValueError", "invalid SQLite backup handle");
            b = it->second;
        }
        int rc;
        int n = (int)iarg(E, A, 1, -1);
        {
            nyconc::GilRelease g;
            rc = a.backup_step(b, n);
        }
        std::vector<Value> r{intValue((int64_t)0), intValue((int64_t)rc), intValue((int64_t)a.backup_remaining(b)),
                             intValue((int64_t)a.backup_pagecount(b))};
        return E.makeListValue(r);
    }
    if (name == "_sql_backup_finish") {
        Api& a = need();
        sqlite3_backup* b;
        {
            std::lock_guard<std::mutex> l(g_mu);
            auto it = g_backups.find(iarg(E, A, 0));
            if (it == g_backups.end()) return intValue((int64_t)0);
            b = it->second;
            g_backups.erase(it);
        }
        return intValue((int64_t)nogil([&] { return a.backup_finish(b); }));
    }
    if (name == "_sql_blob_open") {
        Api& a = need();
        if (!a.blob_open) fail("NotSupportedError", "the SQLite library has no incremental blob I/O");
        auto c = get_conn(iarg(E, A, 0));
        std::string db = sarg(E, A, 1), table = sarg(E, A, 2), column = sarg(E, A, 3);
        int64_t row = iarg(E, A, 4);
        int flags = A.size() > 5 && E.isTruthy(A[5]) ? 1 : 0;
        sqlite3_blob* b = nullptr;
        int rc;
        {
            nyconc::GilRelease g;
            rc = a.blob_open(c->db, db.c_str(), table.c_str(), column.c_str(), row, flags, &b);
        }
        int64_t id = 0;
        if (rc == SQLITE_OK && b) {
            std::lock_guard<std::mutex> l(g_mu);
            id = new_id();
            g_blobs[id] = b;
        }
        std::vector<Value> r{intValue((int64_t)rc), id ? intValue(id) : NONE_VALUE};
        return E.makeListValue(r);
    }
    auto get_blob = [&](int64_t id) -> sqlite3_blob* {
        std::lock_guard<std::mutex> l(g_mu);
        auto it = g_blobs.find(id);
        if (it == g_blobs.end()) fail("ValueError", "invalid SQLite blob handle");
        return it->second;
    };
    if (name == "_sql_blob_close") {
        Api& a = need();
        sqlite3_blob* b;
        {
            std::lock_guard<std::mutex> l(g_mu);
            auto it = g_blobs.find(iarg(E, A, 0));
            if (it == g_blobs.end()) return intValue((int64_t)0);
            b = it->second;
            g_blobs.erase(it);
        }
        return intValue((int64_t)nogil([&] { return a.blob_close(b); }));
    }
    if (name == "_sql_blob_bytes") { Api& a = need(); return intValue((int64_t)a.blob_bytes(get_blob(iarg(E, A, 0)))); }
    if (name == "_sql_blob_read") {
        Api& a = need();
        sqlite3_blob* b = get_blob(iarg(E, A, 0));
        int n = (int)iarg(E, A, 1), off = (int)iarg(E, A, 2);
        std::string buf((size_t)(n > 0 ? n : 0), '\0');
        int rc;
        {
            nyconc::GilRelease g;
            rc = n > 0 ? a.blob_read(b, &buf[0], n, off) : 0;
        }
        if (rc != SQLITE_OK) return intValue((int64_t)rc);
        return E.makeBytesValue(buf);
    }
    if (name == "_sql_blob_write") {
        Api& a = need();
        sqlite3_blob* b = get_blob(iarg(E, A, 0));
        std::string data = sarg(E, A, 1);
        int off = (int)iarg(E, A, 2);
        int rc;
        {
            nyconc::GilRelease g;
            rc = data.empty() ? 0 : a.blob_write(b, data.data(), (int)data.size(), off);
        }
        return intValue((int64_t)rc);
    }
    if (name == "_sql_serialize") {
        Api& a = need();
        if (!a.serialize) fail("NotSupportedError", "serialize() is not available");
        auto c = get_conn(iarg(E, A, 0));
        std::string nm = has_arg(A, 1) ? sarg(E, A, 1) : std::string("main");
        std::string out;
        bool got = nogil([&] {
            sqlite3_int64 size = 0;
            unsigned char* p = a.serialize(c->db, nm.c_str(), &size, 0);
            if (!p) return false;
            out.assign((const char*)p, (size_t)size);
            a.free_(p);
            return true;
        });
        if (!got) return NONE_VALUE;
        return E.makeBytesValue(out);
    }
    if (name == "_sql_deserialize") {
        Api& a = need();
        if (!a.deserialize || !a.malloc64) fail("NotSupportedError", "deserialize() is not available");
        auto c = get_conn(iarg(E, A, 0));
        std::string nm = has_arg(A, 1) ? sarg(E, A, 1) : std::string("main");
        std::string data = sarg(E, A, 2);
        unsigned char* buf = (unsigned char*)a.malloc64(data.size() ? data.size() : 1);
        if (!buf) fail("MemoryError", "");
        if (!data.empty()) memcpy(buf, data.data(), data.size());
        // SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE, as CPython
        int rc = nogil([&] { return a.deserialize(c->db, nm.c_str(), buf, (sqlite3_int64)data.size(), (sqlite3_int64)data.size(), 1 | 2); });
        return intValue((int64_t)rc);
    }
    if (name == "_sql_enable_load_extension") {
        Api& a = need();
        if (!a.enable_load_extension) fail("AttributeError", "'sqlite3.Connection' object has no attribute 'enable_load_extension'");
        auto c = get_conn(iarg(E, A, 0));
        int on = A.size() > 1 && E.isTruthy(A[1]) ? 1 : 0;
        return intValue((int64_t)nogil([&] { return a.enable_load_extension(c->db, on); }));
    }
    if (name == "_sql_load_extension") {
        Api& a = need();
        if (!a.load_extension) fail("AttributeError", "'sqlite3.Connection' object has no attribute 'load_extension'");
        auto c = get_conn(iarg(E, A, 0));
        std::string path = sarg(E, A, 1), entry = sarg(E, A, 2);
        bool named = has_arg(A, 2);
        std::string msg;
        int rc = nogil([&] {
            char* err = nullptr;
            int r = a.load_extension(c->db, path.c_str(), named ? entry.c_str() : nullptr, &err);
            if (err) { msg = err; a.free_(err); }
            return r;
        });
        std::vector<Value> r{intValue((int64_t)rc), E.makeStringValue(msg)};
        return E.makeListValue(r);
    }
    return UNDEFINED_VALUE;
}
