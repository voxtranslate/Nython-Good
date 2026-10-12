# nython: module    (import it by name: it runs in a module scope of its own)
# lib/_sqlite3.ny - CPython's C module _sqlite3 (3.12), written in Nython over
# libsqlite3 loaded at run time (src/builtins/nysqlite.cpp, natives _sql_*).
# lib/sqlite3/ is CPython's package over it: use `import sqlite3`.
#
#     import sqlite3
#     con = sqlite3.connect(":memory:")
#     con.execute("create table t(name, n)")
#     with con:                                     # commit, or roll back on an error
#         con.executemany("insert into t values (?, ?)", [("a", 1), ("b", 2)])
#     con.execute("select sum(n) from t where name > :x", {"x": ""}).fetchone()   # (3,)
#
# DB-API 2.0 as CPython 3.12 has it: connect() (paths, bytes and path-like
# objects, ":memory:", uri=, timeout=, detect_types=, isolation_level=,
# autocommit= with LEGACY_TRANSACTION_CONTROL, check_same_thread=, factory=,
# cached_statements=); Connection (cursor(factory), execute/executemany/
# executescript, commit/rollback/close with CPython's transaction rules -
# the implicit BEGIN before DML in legacy mode, autocommit True/False -,
# the context manager, row_factory, text_factory (str, bytes, bytearray or
# any callable), total_changes, in_transaction, isolation_level,
# create_function (deterministic=), create_aggregate,
# create_window_function, create_collation, set_authorizer,
# set_progress_handler, set_trace_callback, iterdump, backup (pages=,
# progress=, name=, sleep=), blobopen, interrupt, getlimit/setlimit,
# getconfig/setconfig, serialize/deserialize, enable_load_extension/
# load_extension, the exception classes as attributes); Cursor (execute
# with qmark and named parameters - sequences, dicts, any mapping or
# sequence object -, executemany over any iterable, executescript,
# fetchone/fetchmany/fetchall, iteration, description, rowcount, lastrowid,
# arraysize, row_factory, connection, close, setinputsizes/setoutputsize);
# Row (index by position, by case-insensitive name and by slice, keys(),
# len, iteration, ==, hash); Blob (read/write/seek/tell/close, len,
# indexing and slicing, slice assignment, the context manager);
# PrepareProtocol, adapt, adapters, converters, register_adapter,
# register_converter, PARSE_DECLTYPES / PARSE_COLNAMES, complete_statement,
# enable_callback_tracebacks, sqlite_version, threadsafety, and the
# SQLITE_* constants (result codes, authorizer actions, limits, db config).
# Errors from SQLite carry sqlite_errorcode (the extended code) and
# sqlite_errorname, and map onto the exception classes as CPython's do;
# every message is CPython's.
#
# How callbacks run: SQLite calls user functions, aggregates, collations and
# the authorizer/progress/trace hooks from inside sqlite3_step; the native
# layer runs that step on a coroutine of its own and returns a request at
# each callback, which _Callbacks below answers by calling the program's
# function as ordinary Nython code (src/builtins/nysqlite.cpp has the
# design). The GIL is released while SQLite works.
#
# Not provided: Connection.__call__ (CPython's statement objects), the
# statement cache's exact LRU accounting (statements are cached per SQL text
# up to cached_statements), PyErr_WriteUnraisable's exact report for a failed
# callback under enable_callback_tracebacks(True) (the traceback is printed
# with "Exception ignored in:" as CPython's default hook does). When the
# SQLite library cannot be found, importing this module raises ImportError
# naming it.

if not _sql_available():
    raise ImportError("No module named '_sqlite3': " + _sql_why())

_info = _sql_version()
sqlite_version = _info[0]
_sqlite_version_number = _info[1]
# CPython 3.11: threadsafety follows SQLite's default threading mode
threadsafety = {0: 0, 1: 3, 2: 1}.get(_info[2], 0)
_deprecated_version = "2.6.0"
_libname = _info[3]
del _info

PARSE_DECLTYPES = 1
PARSE_COLNAMES = 2
LEGACY_TRANSACTION_CONTROL = -1

SQLITE_ABORT = 4
SQLITE_ABORT_ROLLBACK = 516
SQLITE_ALTER_TABLE = 26
SQLITE_ANALYZE = 28
SQLITE_ATTACH = 24
SQLITE_AUTH = 23
SQLITE_AUTH_USER = 279
SQLITE_BUSY = 5
SQLITE_BUSY_RECOVERY = 261
SQLITE_BUSY_SNAPSHOT = 517
SQLITE_BUSY_TIMEOUT = 773
SQLITE_CANTOPEN = 14
SQLITE_CANTOPEN_CONVPATH = 1038
SQLITE_CANTOPEN_DIRTYWAL = 1294
SQLITE_CANTOPEN_FULLPATH = 782
SQLITE_CANTOPEN_ISDIR = 526
SQLITE_CANTOPEN_NOTEMPDIR = 270
SQLITE_CANTOPEN_SYMLINK = 1550
SQLITE_CONSTRAINT = 19
SQLITE_CONSTRAINT_CHECK = 275
SQLITE_CONSTRAINT_COMMITHOOK = 531
SQLITE_CONSTRAINT_FOREIGNKEY = 787
SQLITE_CONSTRAINT_FUNCTION = 1043
SQLITE_CONSTRAINT_NOTNULL = 1299
SQLITE_CONSTRAINT_PINNED = 2835
SQLITE_CONSTRAINT_PRIMARYKEY = 1555
SQLITE_CONSTRAINT_ROWID = 2579
SQLITE_CONSTRAINT_TRIGGER = 1811
SQLITE_CONSTRAINT_UNIQUE = 2067
SQLITE_CONSTRAINT_VTAB = 2323
SQLITE_CORRUPT = 11
SQLITE_CORRUPT_INDEX = 779
SQLITE_CORRUPT_SEQUENCE = 523
SQLITE_CORRUPT_VTAB = 267
SQLITE_CREATE_INDEX = 1
SQLITE_CREATE_TABLE = 2
SQLITE_CREATE_TEMP_INDEX = 3
SQLITE_CREATE_TEMP_TABLE = 4
SQLITE_CREATE_TEMP_TRIGGER = 5
SQLITE_CREATE_TEMP_VIEW = 6
SQLITE_CREATE_TRIGGER = 7
SQLITE_CREATE_VIEW = 8
SQLITE_CREATE_VTABLE = 29
SQLITE_DBCONFIG_DEFENSIVE = 1010
SQLITE_DBCONFIG_DQS_DDL = 1014
SQLITE_DBCONFIG_DQS_DML = 1013
SQLITE_DBCONFIG_ENABLE_FKEY = 1002
SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER = 1004
SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION = 1005
SQLITE_DBCONFIG_ENABLE_QPSG = 1007
SQLITE_DBCONFIG_ENABLE_TRIGGER = 1003
SQLITE_DBCONFIG_ENABLE_VIEW = 1015
SQLITE_DBCONFIG_LEGACY_ALTER_TABLE = 1012
SQLITE_DBCONFIG_LEGACY_FILE_FORMAT = 1016
SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE = 1006
SQLITE_DBCONFIG_RESET_DATABASE = 1009
SQLITE_DBCONFIG_TRIGGER_EQP = 1008
SQLITE_DBCONFIG_TRUSTED_SCHEMA = 1017
SQLITE_DBCONFIG_WRITABLE_SCHEMA = 1011
SQLITE_DELETE = 9
SQLITE_DENY = 1
SQLITE_DETACH = 25
SQLITE_DONE = 101
SQLITE_DROP_INDEX = 10
SQLITE_DROP_TABLE = 11
SQLITE_DROP_TEMP_INDEX = 12
SQLITE_DROP_TEMP_TABLE = 13
SQLITE_DROP_TEMP_TRIGGER = 14
SQLITE_DROP_TEMP_VIEW = 15
SQLITE_DROP_TRIGGER = 16
SQLITE_DROP_VIEW = 17
SQLITE_DROP_VTABLE = 30
SQLITE_EMPTY = 16
SQLITE_ERROR = 1
SQLITE_ERROR_MISSING_COLLSEQ = 257
SQLITE_ERROR_RETRY = 513
SQLITE_ERROR_SNAPSHOT = 769
SQLITE_FORMAT = 24
SQLITE_FULL = 13
SQLITE_FUNCTION = 31
SQLITE_IGNORE = 2
SQLITE_INSERT = 18
SQLITE_INTERNAL = 2
SQLITE_INTERRUPT = 9
SQLITE_IOERR = 10
SQLITE_IOERR_ACCESS = 3338
SQLITE_IOERR_AUTH = 7178
SQLITE_IOERR_BEGIN_ATOMIC = 7434
SQLITE_IOERR_BLOCKED = 2826
SQLITE_IOERR_CHECKRESERVEDLOCK = 3594
SQLITE_IOERR_CLOSE = 4106
SQLITE_IOERR_COMMIT_ATOMIC = 7690
SQLITE_IOERR_CONVPATH = 6666
SQLITE_IOERR_CORRUPTFS = 8458
SQLITE_IOERR_DATA = 8202
SQLITE_IOERR_DELETE = 2570
SQLITE_IOERR_DELETE_NOENT = 5898
SQLITE_IOERR_DIR_CLOSE = 4362
SQLITE_IOERR_DIR_FSYNC = 1290
SQLITE_IOERR_FSTAT = 1802
SQLITE_IOERR_FSYNC = 1034
SQLITE_IOERR_GETTEMPPATH = 6410
SQLITE_IOERR_LOCK = 3850
SQLITE_IOERR_MMAP = 6154
SQLITE_IOERR_NOMEM = 3082
SQLITE_IOERR_RDLOCK = 2314
SQLITE_IOERR_READ = 266
SQLITE_IOERR_ROLLBACK_ATOMIC = 7946
SQLITE_IOERR_SEEK = 5642
SQLITE_IOERR_SHMLOCK = 5130
SQLITE_IOERR_SHMMAP = 5386
SQLITE_IOERR_SHMOPEN = 4618
SQLITE_IOERR_SHMSIZE = 4874
SQLITE_IOERR_SHORT_READ = 522
SQLITE_IOERR_TRUNCATE = 1546
SQLITE_IOERR_UNLOCK = 2058
SQLITE_IOERR_VNODE = 6922
SQLITE_IOERR_WRITE = 778
SQLITE_LIMIT_ATTACHED = 7
SQLITE_LIMIT_COLUMN = 2
SQLITE_LIMIT_COMPOUND_SELECT = 4
SQLITE_LIMIT_EXPR_DEPTH = 3
SQLITE_LIMIT_FUNCTION_ARG = 6
SQLITE_LIMIT_LENGTH = 0
SQLITE_LIMIT_LIKE_PATTERN_LENGTH = 8
SQLITE_LIMIT_SQL_LENGTH = 1
SQLITE_LIMIT_TRIGGER_DEPTH = 10
SQLITE_LIMIT_VARIABLE_NUMBER = 9
SQLITE_LIMIT_VDBE_OP = 5
SQLITE_LIMIT_WORKER_THREADS = 11
SQLITE_LOCKED = 6
SQLITE_LOCKED_SHAREDCACHE = 262
SQLITE_LOCKED_VTAB = 518
SQLITE_MISMATCH = 20
SQLITE_MISUSE = 21
SQLITE_NOLFS = 22
SQLITE_NOMEM = 7
SQLITE_NOTADB = 26
SQLITE_NOTFOUND = 12
SQLITE_NOTICE = 27
SQLITE_NOTICE_RECOVER_ROLLBACK = 539
SQLITE_NOTICE_RECOVER_WAL = 283
SQLITE_OK = 0
SQLITE_OK_LOAD_PERMANENTLY = 256
SQLITE_OK_SYMLINK = 512
SQLITE_PERM = 3
SQLITE_PRAGMA = 19
SQLITE_PROTOCOL = 15
SQLITE_RANGE = 25
SQLITE_READ = 20
SQLITE_READONLY = 8
SQLITE_READONLY_CANTINIT = 1288
SQLITE_READONLY_CANTLOCK = 520
SQLITE_READONLY_DBMOVED = 1032
SQLITE_READONLY_DIRECTORY = 1544
SQLITE_READONLY_RECOVERY = 264
SQLITE_READONLY_ROLLBACK = 776
SQLITE_RECURSIVE = 33
SQLITE_REINDEX = 27
SQLITE_ROW = 100
SQLITE_SAVEPOINT = 32
SQLITE_SCHEMA = 17
SQLITE_SELECT = 21
SQLITE_TOOBIG = 18
SQLITE_TRANSACTION = 22
SQLITE_UPDATE = 23
SQLITE_WARNING = 28
SQLITE_WARNING_AUTOINDEX = 284

_DBCONFIGS = (1010, 1014, 1013, 1002, 1004, 1005, 1007, 1003, 1015, 1012, 1016, 1006, 1009, 1008, 1017, 1011)
_SQLITE_DETERMINISTIC = 0x800
_SQLITE_OPEN_READWRITE = 2
_SQLITE_OPEN_CREATE = 4
_SQLITE_OPEN_URI = 0x40

# ── exceptions ──────────────────────────────────────────────────────────────
class Warning(Exception):
    __module__ = "sqlite3"

class Error(Exception):
    __module__ = "sqlite3"

class InterfaceError(Error):
    __module__ = "sqlite3"

class DatabaseError(Error):
    __module__ = "sqlite3"

class InternalError(DatabaseError):
    __module__ = "sqlite3"

class OperationalError(DatabaseError):
    __module__ = "sqlite3"

class ProgrammingError(DatabaseError):
    __module__ = "sqlite3"

class IntegrityError(DatabaseError):
    __module__ = "sqlite3"

class DataError(DatabaseError):
    __module__ = "sqlite3"

class NotSupportedError(DatabaseError):
    __module__ = "sqlite3"


def _exception_class(code):
    code = code & 0xff
    if code == 2 or code == 12:                      # INTERNAL, NOTFOUND
        return InternalError
    if code == 7:                                    # NOMEM
        return MemoryError
    if code in (1, 3, 4, 5, 6, 8, 9, 10, 13, 14, 15, 16, 17):
        return OperationalError
    if code == 11:                                   # CORRUPT
        return DatabaseError
    if code == 18:                                   # TOOBIG
        return DataError
    if code == 19 or code == 20:                     # CONSTRAINT, MISMATCH
        return IntegrityError
    if code == 21 or code == 25:                     # MISUSE, RANGE
        return ProgrammingError
    return DatabaseError


def _error_from(h):
    info = _sql_errinfo(h)
    cls = _exception_class(info[1])
    if cls is MemoryError:
        return MemoryError()
    exc = cls(info[3])
    exc.sqlite_errorcode = info[1]
    exc.sqlite_errorname = info[2]
    return exc


# ── adaptation (PEP 246 microprotocols, as the C module) ────────────────────
class PrepareProtocol:
    __module__ = "sqlite3"
    def __init__(self, *args, **kwargs):
        if args or kwargs:
            raise TypeError("PrepareProtocol() takes no arguments")

adapters = {}
converters = {}
_base_type_adapted = [False]
_callback_tracebacks = [False]
_MISSING = object()


def register_adapter(type, adapter, /):
    if type is int or type is float or type is str or type is bytearray:
        _base_type_adapted[0] = True
    adapters[(type, PrepareProtocol)] = adapter


def register_converter(typename, converter, /):
    if not isinstance(typename, str):
        raise TypeError("register_converter() argument 1 must be str, not " + type(typename).__name__)
    converters[typename.upper()] = converter


def adapt(obj, proto=PrepareProtocol, alt=_MISSING, /):
    adapter = adapters.get((type(obj), proto))
    if adapter is not None:
        return adapter(obj)
    proto_adapt = getattr(proto, "__adapt__", None)
    if proto_adapt is not None:
        adapted = proto_adapt(obj)
        if adapted is not None:
            return adapted
    conform = getattr(obj, "__conform__", None)
    if conform is not None:
        adapted = conform(proto)
        if adapted is not None:
            return adapted
    if alt is not _MISSING:
        return alt
    raise ProgrammingError("can't adapt")


def complete_statement(statement):
    if not isinstance(statement, str):
        raise TypeError("complete_statement() argument 'statement' must be str, not " + type(statement).__name__)
    return _sql_complete(statement)


def enable_callback_tracebacks(enable, /):
    _callback_tracebacks[0] = bool(enable)


def _need_adapt(v):
    if _base_type_adapted[0]:
        return True
    t = type(v)
    return not (t is int or t is float or t is str or t is bytearray)


# A value SQLite cannot take as it is: an int/float/str subclass, a buffer
def _plain(v):
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, int):
        return int(v)
    if isinstance(v, float):
        return float(v)
    if isinstance(v, str):
        return str(v)
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    try:
        if isinstance(v, memoryview):
            return v.tobytes()
    except NameError:
        pass
    return v


def _thread_ident():
    return thread_os_id()


def _report_callback_error(callable, exc):
    if not _callback_tracebacks[0]:
        return
    import sys
    import traceback
    hook = getattr(sys, "unraisablehook", None)
    if hook is not None:
        class _Unraisable:
            pass
        u = _Unraisable()
        u.exc_type = type(exc)
        u.exc_value = exc
        u.exc_traceback = exc.__traceback__
        u.err_msg = None
        u.object = callable
        hook(u)
        return
    sys.stderr.write("Exception ignored in: " + repr(callable) + "\n")
    traceback.print_exception(type(exc), exc, exc.__traceback__, file=sys.stderr)


# ── statements ──────────────────────────────────────────────────────────────
class _Statement:
    def __init__(self, h, sql, is_dml):
        self.h = h            # 0: an empty statement (blanks and comments only)
        self.sql = sql
        self.is_dml = is_dml

    def __del__(self):
        if self.h:
            _sql_finalize(self.h)
            self.h = 0


# ── the connection ──────────────────────────────────────────────────────────
class Connection:
    __module__ = "sqlite3"
    Warning = Warning
    Error = Error
    InterfaceError = InterfaceError
    DatabaseError = DatabaseError
    InternalError = InternalError
    OperationalError = OperationalError
    ProgrammingError = ProgrammingError
    IntegrityError = IntegrityError
    DataError = DataError
    NotSupportedError = NotSupportedError

    def __init__(self, database, timeout=5.0, detect_types=0, isolation_level="",
                 check_same_thread=True, factory=None, cached_statements=128, uri=False, *,
                 autocommit=LEGACY_TRANSACTION_CONTROL):
        self._h = None
        self._initialized = False
        if hasattr(database, "__fspath__"):
            database = database.__fspath__()
        if not isinstance(database, (str, bytes)):
            raise TypeError("expected str, bytes or os.PathLike object, not " + type(database).__name__)
        if isinstance(database, str) and "\0" in database:
            raise ValueError("embedded null character")
        level = _isolation_level(isolation_level)
        mode = _autocommit_mode(autocommit)
        if not isinstance(detect_types, int):
            raise TypeError("'" + type(detect_types).__name__ + "' object cannot be interpreted as an integer")
        flags = _SQLITE_OPEN_READWRITE | _SQLITE_OPEN_CREATE
        if uri:
            flags = flags | _SQLITE_OPEN_URI
        r = _sql_open(database, flags, None)
        if r[0] != 0:
            exc = _error_from(r[1]) if r[1] is not None else OperationalError("unable to open database file")
            if r[1] is not None:
                _sql_close(r[1])
            raise exc
        self._h = r[1]
        _sql_busy_timeout(self._h, int(timeout * 1000))
        self._isolation = level
        self._autocommit = mode
        self.detect_types = detect_types
        self.row_factory = None
        self.text_factory = str
        self._check_same_thread = bool(check_same_thread)
        self._thread = _thread_ident()
        self._cache = {}
        self._cache_size = cached_statements
        self._callables = {}
        self._next_fid = 1
        self._aggs = {}
        self._authorizer = None
        self._progress = None
        self._trace = None
        self._pending = None
        self._blobs = []
        self._initialized = True
        if mode == 0:
            self._exec_stmt("BEGIN")

    def __del__(self):
        h = getattr(self, "_h", None)
        if h is not None:
            self._h = None
            self._cache = {}
            _sql_close(h)

    # -- checks -------------------------------------------------------------
    def _check_thread(self):
        if self._check_same_thread:
            here = _thread_ident()
            if here != self._thread:
                raise ProgrammingError("SQLite objects created in a thread can only be used in that same thread. "
                                       "The object was created in thread id " + str(self._thread) +
                                       " and this is thread id " + str(here) + ".")

    def _check(self):
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Connection.__init__ not called.")
        self._check_thread()
        if self._h is None:
            raise ProgrammingError("Cannot operate on a closed database.")

    def _check_open(self):
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Connection.__init__ not called.")
        if self._h is None:
            raise ProgrammingError("Cannot operate on a closed database.")

    def _error(self):
        return _error_from(self._h)

    # -- callbacks ----------------------------------------------------------
    def _drive(self, r):
        # r is a native operation's result [0, ...] or a callback's request
        # [1, op, kind, fid, key, args]: answer requests until it is done.
        while r[0] == 1:
            r = self._answer(r)
        if self._pending is not None:
            exc = self._pending
            self._pending = None
            raise exc
        return r

    def _callback_failed(self, callable, exc):
        if not isinstance(exc, Exception):
            self._pending = exc            # KeyboardInterrupt, SystemExit: raised once SQLite is done
        _report_callback_error(callable, exc)

    def _answer(self, r):
        op = r[1]
        kind = r[2]
        fid = r[3]
        key = r[4]
        args = r[5]
        if kind == 1:                                  # a scalar function
            fn = self._callables.get(fid)
            try:
                v = fn(*args)
            except BaseException as e:
                self._callback_failed(fn, e)
                return _sql_resume(op, 1)
            t = type(v)
            if not (v is None or t is int or t is float or t is str or t is bytes or t is bool):
                v = _plain(v)
            return _sql_resume(op, 0, v)
        if kind == 2 or kind == 5:                     # an aggregate's step / a window's inverse
            cls = self._callables.get(fid)
            inst = self._aggs.get(key)
            if inst is None:
                try:
                    inst = cls()
                except BaseException as e:
                    self._callback_failed(cls, e)
                    return _sql_resume(op, 4)
                self._aggs[key] = inst
            try:
                m = getattr(inst, "step" if kind == 2 else "inverse")
            except AttributeError:
                return _sql_resume(op, 3)
            try:
                m(*args)
            except BaseException as e:
                self._callback_failed(m, e)
                return _sql_resume(op, 1)
            return _sql_resume(op, 0)
        if kind == 3 or kind == 4:                     # finalize / a window's value
            if kind == 3:
                inst = self._aggs.pop(key, None)
            else:
                inst = self._aggs.get(key)
            if inst is None:
                return _sql_resume(op, 0, None)
            try:
                m = getattr(inst, "finalize" if kind == 3 else "value")
            except AttributeError:
                return _sql_resume(op, 3)
            try:
                v = m()
            except BaseException as e:
                self._callback_failed(m, e)
                return _sql_resume(op, 1)
            t = type(v)
            if not (v is None or t is int or t is float or t is str or t is bytes or t is bool):
                v = _plain(v)
                t = type(v)
                if not (v is None or t is int or t is float or t is str or t is bytes or t is bool):
                    return _sql_resume(op, 1)
            return _sql_resume(op, 0, v)
        if kind == 6:                                  # a collation
            fn = self._callables.get(fid)
            try:
                v = fn(args[0], args[1])
            except BaseException as e:
                self._callback_failed(fn, e)
                return _sql_resume(op, 1)
            if isinstance(v, bool) or not isinstance(v, int):
                v = int(v) if isinstance(v, bool) else 0
            else:
                v = int(v)
            return _sql_resume(op, 0, v)
        if kind == 7:                                  # the authorizer
            fn = self._authorizer
            try:
                v = fn(args[0], args[1], args[2], args[3], args[4])
            except BaseException as e:
                self._callback_failed(fn, e)
                return _sql_resume(op, 1)
            if isinstance(v, int):
                return _sql_resume(op, 0, int(v))
            return _sql_resume(op, 0, None)
        if kind == 8:                                  # the progress handler
            fn = self._progress
            try:
                v = fn()
            except BaseException as e:
                self._callback_failed(fn, e)
                return _sql_resume(op, 1)
            return _sql_resume(op, 0, 1 if v else 0)
        if kind == 9:                                  # the trace callback
            fn = self._trace
            if fn is not None:
                try:
                    fn(args[0])
                except BaseException as e:
                    self._callback_failed(fn, e)
            return _sql_resume(op, 0)
        return _sql_resume(op, 1)

    # -- statements ---------------------------------------------------------
    def _prepare(self, sql):
        if "\0" in sql:
            raise ProgrammingError("the query contains a null character")
        r = self._drive(_sql_prepare(self._h, sql, 0))
        rc = r[1]
        sid = r[2]
        if rc != 0:
            if sid:
                _sql_finalize(sid)
            raise self._error()
        st = _Statement(sid, sql, r[5] != 0)
        if r[4]:
            raise ProgrammingError("You can only execute one statement at a time.")
        return st

    def _statement(self, sql):
        st = self._cache.get(sql)
        if st is not None and st.h:
            if _sql_busy(st.h):
                return self._prepare(sql)
            return st
        if st is not None:
            return st
        st = self._prepare(sql)
        if self._cache_size > 0:
            if len(self._cache) >= self._cache_size:
                for k in list(self._cache.keys())[:max(1, len(self._cache) - self._cache_size + 1)]:
                    del self._cache[k]
            self._cache[sql] = st
        return st

    def _step(self, st):
        return self._drive(_sql_step(st.h))[1]

    # prepare + step + finalize, as CPython's begin_transaction and
    # connection_exec_stmt
    def _exec_stmt(self, sql):
        r = self._drive(_sql_prepare(self._h, sql, 0))
        rc = r[1]
        sid = r[2]
        if rc == 0 and sid:
            try:
                self._drive(_sql_step(sid))
            finally:
                rc = _sql_finalize(sid)
        elif sid:
            _sql_finalize(sid)
        if rc != 0:
            raise self._error()

    def _begin(self):
        self._exec_stmt("BEGIN " + self._isolation)

    # -- the DB-API ---------------------------------------------------------
    def cursor(self, factory=_MISSING):
        self._check()
        if factory is _MISSING:
            factory = Cursor
        cur = factory(self)
        if not isinstance(cur, Cursor):
            raise TypeError("factory must return a cursor, not " + type(cur).__name__)
        if self.row_factory is not None:
            cur.row_factory = self.row_factory
        return cur

    def execute(self, sql, parameters=_MISSING, /):
        cur = self.cursor()
        if parameters is _MISSING:
            return cur.execute(sql)
        return cur.execute(sql, parameters)

    def executemany(self, sql, parameters, /):
        cur = self.cursor()
        return cur.executemany(sql, parameters)

    def executescript(self, sql_script, /):
        cur = self.cursor()
        return cur.executescript(sql_script)

    def commit(self):
        self._check()
        if self._autocommit == LEGACY_TRANSACTION_CONTROL:
            if not _sql_autocommit(self._h):
                self._exec_stmt("COMMIT")
        elif self._autocommit == 0:
            self._exec_stmt("COMMIT")
            self._exec_stmt("BEGIN")

    def rollback(self):
        self._check()
        if self._autocommit == LEGACY_TRANSACTION_CONTROL:
            if not _sql_autocommit(self._h):
                self._exec_stmt("ROLLBACK")
        elif self._autocommit == 0:
            self._exec_stmt("ROLLBACK")
            self._exec_stmt("BEGIN")

    def close(self):
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Connection.__init__ not called.")
        self._check_thread()
        if self._h is None:
            return
        for b in list(self._blobs):
            b.close()
        self._blobs = []
        if self._autocommit == 0 and not _sql_autocommit(self._h):
            self._exec_stmt("ROLLBACK")
        h = self._h
        for st in self._cache.values():
            st.h = 0
        self._cache = {}
        self._h = None
        rc = _sql_close(h)
        if rc != 0:
            raise OperationalError("unable to close due to unfinalized statements or unfinished backups")

    def __enter__(self):
        self._check_open()
        return self

    def __exit__(self, exc_type, exc_value, traceback, /):
        if exc_type is None and exc_value is None and traceback is None:
            try:
                self.commit()
            except BaseException:
                try:
                    self.rollback()
                except BaseException:
                    pass
                raise
        else:
            self.rollback()
        return False

    # -- attributes ---------------------------------------------------------
    @property
    def isolation_level(self):
        return self._isolation

    @isolation_level.setter
    def isolation_level(self, value):
        if value is None:
            self._isolation = None
            self.commit()
            return
        self._isolation = _isolation_level(value)

    @property
    def autocommit(self):
        self._check()
        if self._autocommit == 1:
            return True
        if self._autocommit == 0:
            return False
        return LEGACY_TRANSACTION_CONTROL

    @autocommit.setter
    def autocommit(self, value):
        self._check()
        mode = _autocommit_mode(value)
        self._autocommit = mode
        if mode == 1:
            if not _sql_autocommit(self._h):
                self._exec_stmt("COMMIT")
        elif mode == 0:
            if _sql_autocommit(self._h):
                self._exec_stmt("BEGIN")

    @property
    def in_transaction(self):
        self._check()
        return not _sql_autocommit(self._h)

    @property
    def total_changes(self):
        self._check()
        return _sql_total_changes(self._h)

    # -- user functions -----------------------------------------------------
    def _register(self, callable):
        fid = self._next_fid
        self._next_fid = fid + 1
        self._callables[fid] = callable
        return fid

    def create_function(self, name, narg, func, *, deterministic=False):
        self._check()
        if not isinstance(name, str):
            raise TypeError("create_function() argument 'name' must be str, not " + type(name).__name__)
        if not isinstance(narg, int):
            raise TypeError("'" + type(narg).__name__ + "' object cannot be interpreted as an integer")
        flags = 0
        if deterministic:
            flags = _SQLITE_DETERMINISTIC
        if func is None:
            rc = _sql_create_function(self._h, name, narg, flags, 0, 0)
        else:
            if not callable(func):
                raise TypeError("parameter must be callable")
            rc = _sql_create_function(self._h, name, narg, flags, 0, self._register(func))
        if rc != 0:
            raise OperationalError("Error creating function")

    def create_aggregate(self, name, n_arg, aggregate_class):
        self._check()
        if not isinstance(name, str):
            raise TypeError("create_aggregate() argument 'name' must be str, not " + type(name).__name__)
        if aggregate_class is None:
            rc = _sql_create_function(self._h, name, n_arg, 0, 1, 0)
        else:
            if not callable(aggregate_class):
                raise TypeError("parameter must be callable")
            rc = _sql_create_function(self._h, name, n_arg, 0, 1, self._register(aggregate_class))
        if rc != 0:
            raise OperationalError("Error creating aggregate")

    def create_window_function(self, name, num_params, aggregate_class, /):
        self._check()
        if not _sql_has("window"):
            raise NotSupportedError("create_window_function() requires SQLite 3.25.0 or higher")
        if aggregate_class is None:
            rc = _sql_create_function(self._h, name, num_params, 0, 2, 0)
        else:
            rc = _sql_create_function(self._h, name, num_params, 0, 2, self._register(aggregate_class))
        if rc != 0:
            raise self._error()

    def create_collation(self, name, callable_, /):
        self._check()
        if not isinstance(name, str):
            raise TypeError("create_collation() argument 1 must be str, not " + type(name).__name__)
        if callable_ is None:
            rc = _sql_create_collation(self._h, name, 0)
        else:
            if not callable(callable_):
                raise TypeError("parameter must be callable")
            rc = _sql_create_collation(self._h, name, self._register(callable_))
        if rc != 0:
            raise self._error()

    def set_authorizer(self, authorizer_callback):
        self._check()
        if authorizer_callback is not None and not callable(authorizer_callback):
            raise TypeError("parameter must be callable")
        self._authorizer = authorizer_callback
        rc = _sql_set_authorizer(self._h, authorizer_callback is not None)
        if rc != 0:
            self._authorizer = None
            raise OperationalError("Error setting authorizer callback")

    def set_progress_handler(self, progress_handler, n):
        self._check()
        if progress_handler is not None and not callable(progress_handler):
            raise TypeError("parameter must be callable")
        self._progress = progress_handler
        _sql_set_progress(self._h, progress_handler is not None, n)

    def set_trace_callback(self, trace_callback):
        self._check()
        if trace_callback is not None and not callable(trace_callback):
            raise TypeError("parameter must be callable")
        self._trace = trace_callback
        _sql_set_trace(self._h, trace_callback is not None)

    # -- the rest -----------------------------------------------------------
    def interrupt(self):
        self._check_open()
        _sql_interrupt(self._h)

    def iterdump(self):
        self._check()
        from sqlite3.dump import _iterdump
        return _iterdump(self)

    def backup(self, target, *, pages=-1, progress=None, name="main", sleep=0.250):
        self._check()
        if not isinstance(target, Connection):
            raise TypeError("backup() argument 'target' must be sqlite3.Connection, not " + type(target).__name__)
        target._check_open()
        if target is self:
            raise ValueError("target cannot be the same connection instance")
        if progress is not None and not callable(progress):
            raise TypeError("progress argument must be a callable")
        if pages == 0:
            pages = -1
        r = _sql_backup_init(target._h, "main", self._h, name)
        if r[0] != 0 or r[1] is None:
            raise target._error()
        b = r[1]
        while True:
            s = _sql_backup_step(b, pages)
            rc = s[1]
            if progress is not None:
                try:
                    progress(rc, s[2], s[3])
                except BaseException:
                    _sql_backup_finish(b)
                    raise
            if rc == 5 or rc == 6:                 # BUSY, LOCKED
                import time
                time.sleep(sleep)
            if not (rc == 0 or rc == 5 or rc == 6):
                break
        rc = _sql_backup_finish(b)
        if rc != 0:
            raise target._error()

    def blobopen(self, table, column, row, /, *, readonly=False, name="main"):
        self._check()
        r = _sql_blob_open(self._h, name, table, column, row, not readonly)
        if r[0] != 0:
            raise self._error()
        b = Blob._make(self, r[1])
        self._blobs.append(b)
        return b

    def getlimit(self, category, /):
        self._check()
        v = _sql_limit(self._h, category, -1)
        if v < 0:
            raise ProgrammingError("'category' is out of bounds")
        return v

    def setlimit(self, category, limit, /):
        self._check()
        if _sql_limit(self._h, category, -1) < 0:
            raise ProgrammingError("'category' is out of bounds")
        return _sql_limit(self._h, category, limit)

    def getconfig(self, op, /):
        self._check()
        if op not in _DBCONFIGS:
            raise ValueError("unknown config 'op': " + str(op))
        r = _sql_db_config(self._h, op, -1)
        if r[0] != 0:
            raise self._error()
        return r[1] != 0

    def setconfig(self, op, enable=True, /):
        self._check()
        if op not in _DBCONFIGS:
            raise ValueError("unknown config 'op': " + str(op))
        r = _sql_db_config(self._h, op, 1 if enable else 0)
        if r[0] != 0:
            raise self._error()
        return r[1] != 0

    def serialize(self, *, name="main"):
        self._check()
        data = _sql_serialize(self._h, name)
        if data is None:
            raise OperationalError("unable to serialize '" + name + "'")
        return data

    def deserialize(self, data, /, *, name="main"):
        self._check()
        rc = _sql_deserialize(self._h, name, bytes(data))
        if rc != 0:
            raise self._error()

    def enable_load_extension(self, enable, /):
        self._check()
        rc = _sql_enable_load_extension(self._h, enable)
        if rc != 0:
            raise OperationalError("Error enabling load extension")

    def load_extension(self, name, /, *, entrypoint=None):
        self._check()
        r = _sql_load_extension(self._h, name, entrypoint)
        if r[0] != 0:
            raise OperationalError(r[1])


def _isolation_level(value):
    if value is None:
        return None
    if not isinstance(value, str):
        raise TypeError("isolation_level must be str or None")
    if "\0" in value:
        raise ValueError("embedded null character")
    up = value.upper()
    if up in ("", "DEFERRED", "IMMEDIATE", "EXCLUSIVE"):
        return up
    raise ValueError("isolation_level string must be '', 'DEFERRED', 'IMMEDIATE', or 'EXCLUSIVE'")


def _autocommit_mode(value):
    if value is True:
        return 1
    if value is False:
        return 0
    if isinstance(value, int) and not isinstance(value, bool) and value == LEGACY_TRANSACTION_CONTROL:
        return LEGACY_TRANSACTION_CONTROL
    raise ValueError("autocommit must be True, False, or sqlite3.LEGACY_TRANSACTION_CONTROL")


def connect(database, *args, **kwargs):
    factory = Connection
    if "factory" in kwargs:
        factory = kwargs["factory"]
    elif len(args) > 4:
        factory = args[4]
    if factory is None:
        factory = Connection
    return factory(database, *args, **kwargs)


# ── cursors ─────────────────────────────────────────────────────────────────
def _column_name(name, detect_types):
    if detect_types & PARSE_COLNAMES:
        i = name.find("[")
        if i >= 0:
            if i > 0 and name[i - 1] == " ":
                i = i - 1
            return name[:i]
    return name


class Cursor:
    __module__ = "sqlite3"

    def __init__(self, connection, /):
        if not isinstance(connection, Connection):
            raise TypeError("Cursor() argument 1 must be sqlite3.Connection, not " + type(connection).__name__)
        self._connection = connection
        self.arraysize = 1
        self.description = None
        self.rowcount = -1
        self.lastrowid = None
        self.row_factory = None
        self._stmt = None
        self._casts = None
        self._closed = False
        self._locked = False
        self._initialized = True

    @property
    def connection(self):
        return self._connection

    def _check(self):
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Cursor.__init__ not called.")
        if self._closed:
            raise ProgrammingError("Cannot operate on a closed cursor.")
        self._connection._check()
        if self._locked:
            raise ProgrammingError("Recursive use of cursors not allowed.")

    def _reset(self):
        st = self._stmt
        if st is not None and st.h:
            _sql_reset(st.h)

    def _bind(self, st, params):
        con = self._connection
        h = st.h
        needed = _sql_bind_count(h)
        t = type(params)
        if t is tuple or t is list or (not isinstance(params, dict) and hasattr(params, "__getitem__") and hasattr(params, "__len__")):
            n = len(params)
            if n != needed:
                raise ProgrammingError("Incorrect number of bindings supplied. The current statement uses " +
                                       str(needed) + ", and there are " + str(n) + " supplied.")
            for i in range(n):
                nm = _sql_bind_name(h, i + 1)
                if nm is not None and nm[0] != "?":
                    import warnings
                    warnings.warn("Binding " + str(i + 1) + " ('" + nm + "') is a named parameter, but you supplied a "
                                  "sequence which requires nameless (qmark) placeholders. Starting with Python 3.14 an "
                                  "sqlite3.ProgrammingError will be raised.", DeprecationWarning, stacklevel=4)
                self._bind_one(h, i + 1, params[i])
        elif isinstance(params, dict):
            for i in range(1, needed + 1):
                nm = _sql_bind_name(h, i)
                if nm is None:
                    raise ProgrammingError("Binding " + str(i) + " has no name, but you supplied a dictionary "
                                           "(which has only names).")
                key = nm[1:]
                try:
                    v = params[key]
                except LookupError:
                    raise ProgrammingError("You did not supply a value for binding parameter :" + key + ".") from None
                self._bind_one(h, i, v)
        else:
            raise ProgrammingError("parameters are of unsupported type")

    def _bind_one(self, h, i, v):
        if _need_adapt(v):
            v = adapt(v, PrepareProtocol, v)
        rc = _sql_bind(h, i, v)
        if rc == -1:
            p = _plain(v)
            if p is not v:
                rc = _sql_bind(h, i, p)
            if rc == -1:
                raise ProgrammingError("Error binding parameter " + str(i) + ": type '" + type(v).__name__ +
                                       "' is not supported")
        if rc == -2:
            raise OverflowError("Python int too large to convert to SQLite INTEGER")
        if rc != 0:
            raise self._connection._error()

    def _build_casts(self, st):
        con = self._connection
        dt = con.detect_types
        if not dt or not st.h:
            self._casts = None
            return
        casts = []
        any_ = False
        for col in _sql_columns(st.h):
            conv = None
            if dt & PARSE_COLNAMES and col[0] is not None:
                name = col[0]
                start = -1
                for k in range(len(name)):
                    ch = name[k]
                    if ch == "[":
                        start = k + 1
                    elif ch == "]" and start >= 0:
                        conv = converters.get(name[start:k].upper())
                        break
            if conv is None and dt & PARSE_DECLTYPES and col[1] is not None:
                decl = col[1]
                k = 0
                while k < len(decl) and decl[k] != " " and decl[k] != "(":
                    k = k + 1
                conv = converters.get(decl[:k].upper())
            casts.append(conv)
            if conv is not None:
                any_ = True
        self._casts = casts if any_ else None

    def _execute(self, multiple, sql, second):
        self._check()
        con = self._connection
        self._locked = True
        try:
            if multiple:
                params_iter = iter(second)
            else:
                params_iter = iter([() if second is _MISSING else second])
            self._reset()
            self.description = None
            st = con._statement(sql)
            self._stmt = st
            if not st.h:                         # nothing but blanks and comments
                self._stmt = None
                self.rowcount = -1
                return self
            if multiple and _sql_readonly(st.h):
                raise ProgrammingError("executemany() can only execute DML statements.")
            if _sql_busy(st.h):
                st = con._prepare(sql)
                self._stmt = st
            _sql_reset(st.h)
            self.rowcount = 0 if st.is_dml else -1
            if (con._autocommit == LEGACY_TRANSACTION_CONTROL and con._isolation is not None and st.is_dml
                    and _sql_autocommit(con._h)):
                con._begin()
            for params in params_iter:
                self._bind(st, params)
                rc = con._step(st)
                if rc != 100 and rc != 101:
                    raise con._error()
                self._build_casts(st)
                if self.description is None:
                    cols = _sql_columns(st.h)
                    if len(cols) > 0:
                        dt = con.detect_types
                        self.description = tuple([(_column_name(c[0], dt), None, None, None, None, None, None)
                                                  for c in cols])
                if rc == 101:
                    if st.is_dml:
                        self.rowcount = self.rowcount + _sql_changes(con._h)
                    _sql_reset(st.h)
            if not multiple:
                self.lastrowid = _sql_last_rowid(con._h)
        except BaseException:
            if self._stmt is not None:
                self._reset()
                self._stmt = None
            self.rowcount = -1
            raise
        finally:
            self._locked = False
        if self._stmt is not None and not _sql_busy(self._stmt.h):
            self._stmt = None
        return self

    def execute(self, sql, parameters=_MISSING, /):
        if not isinstance(sql, str):
            raise TypeError("execute() argument 1 must be str, not " + type(sql).__name__)
        return self._execute(False, sql, parameters)

    def executemany(self, sql, seq_of_parameters, /):
        if not isinstance(sql, str):
            raise TypeError("executemany() argument 1 must be str, not " + type(sql).__name__)
        return self._execute(True, sql, seq_of_parameters)

    def executescript(self, sql_script, /):
        if not isinstance(sql_script, str):
            raise TypeError("executescript() argument must be str, not " + type(sql_script).__name__)
        self._check()
        if "\0" in sql_script:
            raise ValueError("embedded null character")
        con = self._connection
        h = con._h
        self._reset()
        self._stmt = None
        if con._autocommit == LEGACY_TRANSACTION_CONTROL and not _sql_autocommit(h):
            r = con._drive(_sql_exec(h, "COMMIT"))
            if r[1] != 0:
                raise con._error()
        script = sql_script.encode("utf-8")
        off = 0
        n = len(script)
        while True:
            r = con._drive(_sql_prepare(h, script, off))
            rc = r[1]
            sid = r[2]
            if rc == 0 and sid:
                try:
                    while True:
                        s = con._drive(_sql_step(sid))[1]
                        if s != 100:
                            break
                finally:
                    rc = _sql_finalize(sid)
            if rc != 0:
                raise con._error()
            off = r[3]
            if off >= n or script[off] == 0:
                break
        return self

    def _next_row(self):
        st = self._stmt
        con = self._connection
        tf = con.text_factory
        casts = self._casts
        h = st.h
        if tf is str:
            row = _sql_row(h, 0, casts)
            if type(row) is tuple:
                names = _sql_columns(h)
                raise OperationalError("Could not decode to UTF-8 column '" + names[row[0]][0] +
                                       "' with text '" + row[1].decode("utf-8", "replace") + "'")
        elif tf is bytes:
            row = _sql_row(h, 1, casts)
        else:
            pr = _sql_row(h, 2, casts)
            row = pr[0]
            types = pr[1]
            for i in range(len(row)):
                if types[i] == 3 and (casts is None or casts[i] is None):
                    if tf is bytearray:
                        row[i] = bytearray(row[i])
                    else:
                        row[i] = tf(row[i])
        if casts is not None:
            for i in range(len(row)):
                c = casts[i]
                if c is not None and row[i] is not None:
                    row[i] = c(row[i])
        return tuple(row)

    def __iter__(self):
        return self

    def __next__(self):
        self._check()
        st = self._stmt
        if st is None:
            raise StopIteration
        con = self._connection
        self._locked = True
        try:
            row = self._next_row()
        finally:
            self._locked = False
        rc = con._step(st)
        if rc == 101:
            if st.is_dml:
                self.rowcount = _sql_changes(con._h)
            _sql_reset(st.h)
            self._stmt = None
        elif rc != 100:
            exc = con._error()
            _sql_reset(st.h)
            self._stmt = None
            raise exc
        if self.row_factory is not None:
            row = self.row_factory(self, row)
        return row

    def fetchone(self):
        try:
            return self.__next__()
        except StopIteration:
            return None

    def fetchmany(self, size=_MISSING):
        if size is _MISSING:
            size = self.arraysize
        out = []
        n = 0
        while True:
            try:
                row = self.__next__()
            except StopIteration:
                break
            out.append(row)
            n = n + 1
            if n == size:
                break
        return out

    def fetchall(self):
        out = []
        while True:
            try:
                row = self.__next__()
            except StopIteration:
                break
            out.append(row)
        return out

    def close(self):
        if self._locked:
            raise ProgrammingError("Recursive use of cursors not allowed.")
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Cursor.__init__ not called.")
        self._connection._check()
        if self._stmt is not None:
            self._reset()
            self._stmt = None
        self._closed = True

    def setinputsizes(self, sizes, /):
        pass

    def setoutputsize(self, size, column=None, /):
        pass


# ── rows ────────────────────────────────────────────────────────────────────
class Row:
    __module__ = "sqlite3"

    def __init__(self, cursor, data, /):
        if not isinstance(cursor, Cursor):
            raise TypeError("Row() argument 1 must be sqlite3.Cursor, not " + type(cursor).__name__)
        if not isinstance(data, tuple):
            raise TypeError("Row() argument 2 must be tuple, not " + type(data).__name__)
        self._data = data
        self._description = cursor.description

    def keys(self):
        d = self._description
        if d is None:
            return []
        return [c[0] for c in d]

    def __len__(self):
        return len(self._data)

    def __iter__(self):
        return iter(self._data)

    def __getitem__(self, idx):
        if isinstance(idx, int):
            return self._data[idx]
        if isinstance(idx, str):
            want = idx.upper()
            d = self._description
            if d is not None:
                for i in range(len(d)):
                    if d[i][0].upper() == want:
                        return self._data[i]
            raise IndexError("No item with that key")
        if isinstance(idx, slice):
            return self._data[idx]
        raise IndexError("Index must be int or string")

    def __eq__(self, other):
        if not isinstance(other, Row):
            return NotImplemented
        return self._description == other._description and self._data == other._data

    def __ne__(self, other):
        if not isinstance(other, Row):
            return NotImplemented
        return not (self._description == other._description and self._data == other._data)

    def __hash__(self):
        return hash(self._description) ^ hash(self._data)


# ── incremental blob I/O ────────────────────────────────────────────────────
class Blob:
    __module__ = "sqlite3"

    def __init__(self, *args, **kwargs):
        raise TypeError("cannot create 'sqlite3.Blob' instances")

    @staticmethod
    def _make(con, h):
        b = object.__new__(Blob)
        b._con = con
        b._h = h
        b._offset = 0
        return b

    def _check(self):
        self._con._check_thread()
        if self._h is None:
            raise ProgrammingError("Cannot operate on a closed blob.")
        self._con._check_open()

    def _length(self):
        return _sql_blob_bytes(self._h)

    def _read(self, n, offset):
        r = _sql_blob_read(self._h, n, offset)
        if isinstance(r, int):
            raise self._con._error()
        return r

    def close(self):
        self._con._check_thread()
        self._con._check_open()
        if self._h is not None:
            _sql_blob_close(self._h)
            self._h = None
            if self in self._con._blobs:
                self._con._blobs.remove(self)

    def __len__(self):
        self._check()
        return self._length()

    def read(self, length=-1, /):
        self._check()
        size = self._length()
        if length < 0 or length > size - self._offset:
            length = size - self._offset
        if length <= 0:
            return b""
        data = self._read(length, self._offset)
        self._offset = self._offset + length
        return data

    def write(self, data, /):
        self._check()
        data = bytes(data)
        if len(data) > self._length() - self._offset:
            raise ValueError("data longer than blob length")
        rc = _sql_blob_write(self._h, data, self._offset)
        if rc != 0:
            raise self._con._error()
        self._offset = self._offset + len(data)

    def seek(self, offset, origin=0, /):
        self._check()
        size = self._length()
        if origin == 0:
            pass
        elif origin == 1:
            offset = self._offset + offset
        elif origin == 2:
            offset = size + offset
        else:
            raise ValueError("'origin' should be os.SEEK_SET, os.SEEK_CUR, or os.SEEK_END")
        if offset < 0 or offset > size:
            raise ValueError("offset out of blob range")
        self._offset = offset

    def tell(self):
        self._check()
        return self._offset

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, *args):
        self.close()
        return False

    def __getitem__(self, idx):
        self._check()
        size = self._length()
        if isinstance(idx, int):
            if idx < 0:
                idx = idx + size
            if idx < 0 or idx >= size:
                raise IndexError("Blob index out of range")
            return self._read(1, idx)[0]
        if isinstance(idx, slice):
            start, stop, step = idx.indices(size)
            if step == 1:
                if stop <= start:
                    return b""
                return self._read(stop - start, start)
            data = self._read(size, 0) if size > 0 else b""
            return data[start:stop:step]
        raise TypeError("Blob indices must be integers")

    def __setitem__(self, idx, value):
        self._check()
        size = self._length()
        if isinstance(idx, int):
            if idx < 0:
                idx = idx + size
            if idx < 0 or idx >= size:
                raise IndexError("Blob index out of range")
            if not isinstance(value, int):
                raise TypeError("'" + type(value).__name__ + "' object cannot be interpreted as an integer")
            if value < 0 or value > 255:
                raise ValueError("byte must be in range(0, 256)")
            rc = _sql_blob_write(self._h, bytes([value]), idx)
            if rc != 0:
                raise self._con._error()
            return
        if isinstance(idx, slice):
            start, stop, step = idx.indices(size)
            value = bytes(value)
            count = len(range(start, stop, step))
            if len(value) != count:
                raise IndexError("Blob slice assignment is wrong size")
            if count == 0:
                return
            if step == 1:
                rc = _sql_blob_write(self._h, value, start)
            else:
                data = bytearray(self._read(size, 0))
                j = 0
                for k in range(start, stop, step):
                    data[k] = value[j]
                    j = j + 1
                rc = _sql_blob_write(self._h, bytes(data), 0)
            if rc != 0:
                raise self._con._error()
            return
        raise TypeError("Blob indices must be integers")

    def __delitem__(self, idx):
        raise TypeError("Blob doesn't support item deletion")
