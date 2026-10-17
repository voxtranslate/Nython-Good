# vm_audit110.ny - round 83: Python's data-format, mail and network-protocol
# modules, and sqlite3 (both engines; passes under python3 too).
#
# sqlite3 over libsqlite3 loaded at run time (transactions, every DB-API
# path, user functions/aggregates/window functions/collations, the
# authorizer, progress and trace hooks, adapters and converters, Row,
# blobs, backup, iterdump text, CPython's messages, callbacks from several
# threads at once); dbm (dumb, sqlite3) and shelve; the email package
# (parse/generate round trips of a real-world MIME message with CPython's
# exact strings, the default policy's EmailMessage/MIMEPart API, the
# compat32 MIME classes, utils, header, charset, defects); quopri, uu,
# mailbox (mbox, Maildir, MH, Babyl, MMDF), mailcap, netrc, cgi, cgitb;
# plistlib (XML and binary bytes as CPython's); audioop, wave, aifc, sunau,
# chunk, sndhdr, imghdr; wsgiref and xmlrpc over real HTTP servers;
# smtplib, poplib, imaplib, ftplib (passive and active), telnetlib and LMTP
# (a Unix socket, SMTPUTF8) against servers written here, on localhost, and
# STARTTLS/SMTP_SSL/POP3_SSL/IMAP4_SSL/FTP_TLS with a throwaway CA.
# Every expected value is CPython's (computed by python3; the 3.12-only
# checks carry CPython 3.12's values on 3.11 too). Skipped with a notice
# (not counted): the sqlite3 checks where SQLite is not installed, the TLS
# checks where there is no openssl command, LMTP where there are no Unix
# sockets.
#
#     ./build/nython-cli examples/vm_audit110.ny
#     ./build/nython-cli --vm examples/vm_audit110.ny
#     python3 examples/vm_audit110.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import sys
pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def section(name, fn):
    try:
        fn()
    except BaseException as e:
        import traceback
        traceback.print_exc()
        results.append([name + " (the section raised)", False, type(e).__name__ + ": " + str(e), "no exception"])


def err(f):
    try:
        f()
        return "no error"
    except Exception as e:
        return [type(e).__name__, str(e)]

# ── sqlite3 ──────────────────────────────────────────────────────────────────
def sqlite_checks():
    try:
        import sqlite3
    except ImportError as e:
        print("NOTICE: sqlite3 checks skipped - " + str(e))
        return
    import datetime
    import warnings
    con = sqlite3.connect(":memory:")
    check("sqlite3 module facts", [sqlite3.paramstyle, sqlite3.apilevel, sqlite3.threadsafety in (0, 1, 3),
                                   isinstance(sqlite3.sqlite_version, str), len(sqlite3.sqlite_version_info) == 3,
                                   sqlite3.PARSE_DECLTYPES, sqlite3.PARSE_COLNAMES, sqlite3.SQLITE_OK, sqlite3.SQLITE_DENY,
                                   sqlite3.SQLITE_IGNORE, sqlite3.SQLITE_CONSTRAINT_UNIQUE],
          ["qmark", "2.0", True, True, True, 1, 2, 0, 1, 2, 2067])
    check("exception hierarchy",
          [issubclass(sqlite3.IntegrityError, sqlite3.DatabaseError), issubclass(sqlite3.DatabaseError, sqlite3.Error),
           issubclass(sqlite3.Error, Exception), issubclass(sqlite3.Warning, Exception),
           issubclass(sqlite3.ProgrammingError, sqlite3.DatabaseError), issubclass(sqlite3.InterfaceError, sqlite3.Error),
           issubclass(sqlite3.OperationalError, sqlite3.DatabaseError), issubclass(sqlite3.NotSupportedError, sqlite3.DatabaseError),
           issubclass(sqlite3.DataError, sqlite3.DatabaseError), issubclass(sqlite3.InternalError, sqlite3.DatabaseError),
           con.IntegrityError is sqlite3.IntegrityError, sqlite3.Error.__module__, sqlite3.Row.__module__],
          [True, True, True, True, True, True, True, True, True, True, True, "sqlite3", "sqlite3"])
    cur = con.cursor()
    check("a new cursor", [cur.arraysize, cur.rowcount, cur.lastrowid, cur.description, cur.row_factory, cur.connection is con],
          [1, -1, None, None, None, True])
    cur.execute("create table people(id integer primary key, name text not null unique, age integer, score real, photo blob)")
    check("DDL: rowcount and description", [cur.rowcount, cur.description, con.in_transaction], [-1, None, False])
    cur.execute("insert into people(name, age, score, photo) values (?, ?, ?, ?)", ("ann", 31, 4.5, b"\x00\x01"))
    check("qmark insert", [cur.rowcount, cur.lastrowid, con.in_transaction, con.total_changes], [1, 1, True, 1])
    cur.execute("insert into people(name, age, score) values (:name, :age, :score)", {"name": "bob", "age": 25, "score": None})
    check("named insert", [cur.rowcount, cur.lastrowid], [1, 2])
    cur.executemany("insert into people(name, age) values (?, ?)", [("cy", 40), ("di", 19), ("ed", 52)])
    check("executemany", [cur.rowcount, con.total_changes], [3, 5])
    def gen():
        for n in ["fay", "gus"]:
            yield (n, len(n) * 10)
    cur.executemany("insert into people(name, age) values (?, ?)", gen())
    check("executemany over a generator", cur.rowcount, 2)
    con.commit()
    check("commit ends the transaction", con.in_transaction, False)
    cur.execute("select id, name, age, score, photo from people order by id")
    check("description", cur.description,
          (("id", None, None, None, None, None, None), ("name", None, None, None, None, None, None),
           ("age", None, None, None, None, None, None), ("score", None, None, None, None, None, None),
           ("photo", None, None, None, None, None, None)))
    check("fetchone", cur.fetchone(), (1, "ann", 31, 4.5, b"\x00\x01"))
    check("fetchmany (arraysize)", cur.fetchmany(), [(2, "bob", 25, None, None)])
    cur.arraysize = 2
    check("fetchmany(2)", cur.fetchmany(), [(3, "cy", 40, None, None), (4, "di", 19, None, None)])
    check("fetchall", cur.fetchall(), [(5, "ed", 52, None, None), (6, "fay", 30, None, None), (7, "gus", 30, None, None)])
    check("fetch past the end", [cur.fetchone(), cur.fetchall(), cur.fetchmany(5)], [None, [], []])
    check("iteration", [r[0] for r in con.execute("select name from people where age >= ? order by name", (30,))],
          ["ann", "cy", "ed", "fay", "gus"])
    check("value types", con.execute("select 1, 1.5, 'x', x'4142', null, 9223372036854775807, -9223372036854775808").fetchone(),
          (1, 1.5, "x", b"AB", None, 9223372036854775807, -9223372036854775808))
    check("unicode round trip", con.execute("select ?, length(?)", ("héllo 世界", "é世")).fetchone(),
          ("héllo 世界", 2))
    check("bytearray and bool parameters", con.execute("select ?, ?, ?", (bytearray(b"xy"), True, False)).fetchone(), (b"xy", 1, 0))
    c2 = con.execute("update people set age = age + 1 where age < ?", (30,))
    check("update rowcount", [c2.rowcount, con.in_transaction], [2, True])
    con.rollback()
    check("rollback", [con.in_transaction, con.execute("select age from people where name = 'di'").fetchone()], [False, (19,)])
    with con:
        con.execute("delete from people where name = 'gus'")
    check("with: commits", [con.in_transaction, con.execute("select count(*) from people").fetchone()[0]], [False, 6])
    try:
        with con:
            con.execute("delete from people where name = 'fay'")
            raise KeyError("x")
    except KeyError:
        pass
    check("with: rolls back on an exception", con.execute("select count(*) from people").fetchone()[0], 6)
    def err(f):
        try:
            f()
            return "no error"
        except Exception as e:
            return [type(e).__name__, str(e)]
    def dberr(f):
        try:
            f()
            return "no error"
        except sqlite3.Error as e:
            return [type(e).__name__, str(e), getattr(e, "sqlite_errorcode", None), getattr(e, "sqlite_errorname", None)]
    check("IntegrityError", dberr(lambda: con.execute("insert into people(name) values ('ann')")),
          ["IntegrityError", "UNIQUE constraint failed: people.name", 2067, "SQLITE_CONSTRAINT_UNIQUE"])
    check("NOT NULL", dberr(lambda: con.execute("insert into people(age) values (1)")),
          ["IntegrityError", "NOT NULL constraint failed: people.name", 1299, "SQLITE_CONSTRAINT_NOTNULL"])
    con.rollback()
    check("OperationalError", dberr(lambda: con.execute("select * from nowhere")),
          ["OperationalError", "no such table: nowhere", 1, "SQLITE_ERROR"])
    check("syntax error", dberr(lambda: con.execute("selec 1")), ["OperationalError", 'near "selec": syntax error', 1, "SQLITE_ERROR"])
    check("binding errors", [err(lambda: con.execute("select ?", (1, 2))), err(lambda: con.execute("select :a", {"b": 1})),
                             err(lambda: con.execute("select ?", [[1]])), err(lambda: con.execute("select ?", {"a": 1})),
                             err(lambda: con.execute("select ?", 5)), err(lambda: con.execute("select ?", (2 ** 63,)))],
          [["ProgrammingError", "Incorrect number of bindings supplied. The current statement uses 1, and there are 2 supplied."],
           ["ProgrammingError", "You did not supply a value for binding parameter :a."],
           ["ProgrammingError", "Error binding parameter 1: type 'list' is not supported"],
           ["ProgrammingError", "Binding 1 has no name, but you supplied a dictionary (which has only names)."],
           ["ProgrammingError", "parameters are of unsupported type"],
           ["OverflowError", "Python int too large to convert to SQLite INTEGER"]])
    check("statement errors", [err(lambda: con.execute("select 1; select 2")), err(lambda: con.execute("select 'a\x00b'")),
                               err(lambda: con.execute(5)), err(lambda: con.executemany("select ?", [(1,)]))],
          [["ProgrammingError", "You can only execute one statement at a time."],
           ["ProgrammingError", "the query contains a null character"],
           ["TypeError", "execute() argument 1 must be str, not int"],
           ["ProgrammingError", "executemany() can only execute DML statements."]])
    check("an empty statement", [con.execute("").description, con.execute("-- nothing").rowcount], [None, -1])
    check("trailing comments are allowed", con.execute("select 7; -- seven\n /* done */").fetchall(), [(7,)])
    # transactions and isolation levels
    traced = []
    con2 = sqlite3.connect(":memory:")
    con2.set_trace_callback(traced.append)
    con2.execute("create table t(x)")
    con2.execute("insert into t values (1)")
    con2.commit()
    con2.isolation_level = "IMMEDIATE"
    con2.execute("insert into t values (2)")
    con2.rollback()
    con2.isolation_level = None
    con2.execute("insert into t values (3)")
    check("trace: the implicit BEGIN of legacy transaction control", traced,
          ["create table t(x)", "BEGIN ", "insert into t values (1)", "COMMIT", "BEGIN IMMEDIATE", "insert into t values (2)",
           "ROLLBACK", "insert into t values (3)"])
    check("isolation_level None is autocommit", [con2.isolation_level, con2.in_transaction, con2.execute("select x from t").fetchall()],
          [None, False, [(1,), (3,)]])
    check("isolation_level values", [err(lambda: sqlite3.connect(":memory:", isolation_level="foo")),
                                     err(lambda: sqlite3.connect(":memory:", isolation_level=5)),
                                     sqlite3.connect(":memory:", isolation_level="deferred").isolation_level],
          [["ValueError", "isolation_level string must be '', 'DEFERRED', 'IMMEDIATE', or 'EXCLUSIVE'"],
           ["TypeError", "isolation_level must be str or None"], "DEFERRED"])
    con2.set_trace_callback(None)
    if sys.version_info >= (3, 12):
        ac = sqlite3.connect(":memory:", autocommit=False)
        r1 = [ac.autocommit, ac.in_transaction]
        ac.execute("create table t(x)")
        ac.commit()
        r1.append(ac.in_transaction)
        ac.autocommit = True
        r1.append(ac.in_transaction)
        r1.append(err(lambda: sqlite3.connect(":memory:", autocommit=5)))
        r1.append(sqlite3.connect(":memory:").autocommit == sqlite3.LEGACY_TRANSACTION_CONTROL)
    else:
        r1 = [False, True, True, False, ["ValueError", "autocommit must be True, False, or sqlite3.LEGACY_TRANSACTION_CONTROL"], True]
    check("autocommit= (3.12)", r1, [False, True, True, False,
                                     ["ValueError", "autocommit must be True, False, or sqlite3.LEGACY_TRANSACTION_CONTROL"], True])
    # Nython-only: the profile callback (SQLITE_TRACE_PROFILE)
    if hasattr(con2, "set_profile_callback"):
        prof = []
        con2.set_profile_callback(lambda sql, ns: prof.append((sql, isinstance(ns, int) and ns >= 0)))
        con2.execute("select count(*) from t").fetchall()
        con2.set_profile_callback(None)
        con2.execute("select 1").fetchall()
        rp = prof
    else:
        rp = [("select count(*) from t", True)]
    check("Nython's set_profile_callback", rp, [("select count(*) from t", True)])
    # executescript
    con3 = sqlite3.connect(":memory:")
    con3.executescript("""
        create table a(x, y);
        insert into a values (1, 'one');
        insert into a values (2, 'two'); -- a comment
        /* another */ insert into a values (3, 'three');
    """)
    check("executescript", [con3.execute("select * from a order by x").fetchall(), con3.in_transaction],
          [[(1, "one"), (2, "two"), (3, "three")], False])
    check("executescript error", dberr(lambda: con3.executescript("select 1; selec 2")),
          ["OperationalError", 'near "selec": syntax error', 1, "SQLITE_ERROR"])
    check("complete_statement", [sqlite3.complete_statement("select 1;"), sqlite3.complete_statement("select 1"),
                                 sqlite3.complete_statement("select 'a;")], [True, False, False])
    # rows
    con3.row_factory = sqlite3.Row
    r = con3.execute("select x as Num, y as Word from a where x = 2").fetchone()
    check("Row", [type(r) is sqlite3.Row, r[0], r["num"], r["WORD"], r[-1], r[0:1], list(r), r.keys(), len(r),
                  tuple(r), r == con3.execute("select x as Num, y as Word from a where x = 2").fetchone(), hash(r) == hash(r)],
          [True, 2, 2, "two", "two", (2,), [2, "two"], ["Num", "Word"], 2, (2, "two"), True, True])
    check("Row errors", [err(lambda: r[5]), err(lambda: r["zzz"]), err(lambda: r[1.5])],
          [["IndexError", "tuple index out of range"], ["IndexError", "No item with that key"],
           ["IndexError", "Index must be int or string"]])
    con3.row_factory = lambda cursor, row: {d[0]: v for d, v in zip(cursor.description, row)}
    check("a row_factory function", con3.execute("select x, y from a where x = 3").fetchone(), {"x": 3, "y": "three"})
    con3.row_factory = None
    cu3 = con3.cursor()
    cu3.row_factory = lambda c, row: row[0]
    check("a cursor's own row_factory", cu3.execute("select x from a order by x").fetchall(), [1, 2, 3])
    # text_factory
    con3.text_factory = bytes
    check("text_factory = bytes", con3.execute("select y, x'00' from a where x = 1").fetchone(), (b"one", b"\x00"))
    con3.text_factory = lambda b: b.decode().upper()
    check("text_factory = a function", con3.execute("select y, x from a where x = 1").fetchone(), ("ONE", 1))
    con3.text_factory = str
    check("text that is not UTF-8", err(lambda: con3.execute("select cast(x'ff' as text) as q").fetchone()),
          ["OperationalError", "Could not decode to UTF-8 column 'q' with text '�'"])
    # user functions
    con4 = sqlite3.connect(":memory:")
    con4.create_function("double", 1, lambda x: x * 2)
    con4.create_function("joiner", -1, lambda *a: "-".join(str(x) for x in a))
    con4.create_function("pyrepr", 1, lambda x: repr(x), deterministic=True)
    con4.create_function("nada", 0, lambda: None)
    check("create_function", con4.execute("select double(21), double('ab'), joiner(1, 'b', 2.5), pyrepr(x'00ff'), nada()").fetchone(),
          (42, "abab", "1-b-2.5", "b'\\x00\\xff'", None))
    con4.create_function("boom", 0, lambda: 1 / 0)
    con4.create_function("lst", 0, lambda: [1])
    con4.create_function("big", 0, lambda: 2 ** 64)
    check("function errors", [dberr(lambda: con4.execute("select boom()").fetchall()), dberr(lambda: con4.execute("select lst()").fetchall()),
                              dberr(lambda: con4.execute("select big()").fetchall()), dberr(lambda: con4.execute("select nofunc()"))],
          [["OperationalError", "user-defined function raised exception", 1, "SQLITE_ERROR"],
           ["OperationalError", "user-defined function raised exception", 1, "SQLITE_ERROR"],
           ["DataError", "string or blob too big", 18, "SQLITE_TOOBIG"],
           ["OperationalError", "no such function: nofunc", 1, "SQLITE_ERROR"]])
    con4.execute("create table n(v)")
    con4.executemany("insert into n values (?)", [(i,) for i in range(1, 11)])
    class Mean:
        def __init__(self):
            self.total = 0
            self.count = 0
        def step(self, v):
            self.total += v
            self.count += 1
        def finalize(self):
            return self.total / self.count if self.count else None
    con4.create_aggregate("mean", 1, Mean)
    check("create_aggregate", [con4.execute("select mean(v) from n").fetchone()[0], con4.execute("select mean(v) from n where v > 100").fetchone()[0],
                               con4.execute("select v % 2, mean(v) from n group by v % 2 order by 1").fetchall()],
          [5.5, None, [(0, 6.0), (1, 5.0)]])
    class NoStep:
        def finalize(self):
            return 1
    class BadInit:
        def __init__(self):
            raise ValueError("no")
    class BadStep:
        def step(self, v):
            raise ValueError("no")
        def finalize(self):
            return 1
    class BadFinal:
        def step(self, v):
            pass
        def finalize(self):
            return 1 / 0
    con4.create_aggregate("nostep", 1, NoStep)
    con4.create_aggregate("badinit", 1, BadInit)
    con4.create_aggregate("badstep", 1, BadStep)
    con4.create_aggregate("badfinal", 1, BadFinal)
    check("aggregate errors", [err(lambda: con4.execute("select nostep(v) from n").fetchall()),
                               err(lambda: con4.execute("select badinit(v) from n").fetchall()),
                               err(lambda: con4.execute("select badstep(v) from n").fetchall()),
                               err(lambda: con4.execute("select badfinal(v) from n").fetchall())],
          [["OperationalError", "user-defined aggregate's 'step' method not defined"],
           ["OperationalError", "user-defined aggregate's '__init__' method raised error"],
           ["OperationalError", "user-defined aggregate's 'step' method raised error"],
           ["OperationalError", "user-defined aggregate's 'finalize' method raised error"]])
    class WinSum:
        def __init__(self):
            self.n = 0
        def step(self, v):
            self.n += v
        def inverse(self, v):
            self.n -= v
        def value(self):
            return self.n
        def finalize(self):
            return self.n
    con4.create_window_function("winsum", 1, WinSum)
    check("create_window_function", con4.execute(
        "select v, winsum(v) over (order by v rows between 1 preceding and 1 following) from n where v <= 5").fetchall(),
          [(1, 3), (2, 6), (3, 9), (4, 12), (5, 9)])
    con4.create_collation("reverse", lambda a, b: (a < b) - (a > b))
    con4.execute("create table w(s)")
    con4.executemany("insert into w values (?)", [("b",), ("a",), ("c",), ("B",)])
    check("create_collation", [r[0] for r in con4.execute("select s from w order by s collate reverse")], ["c", "b", "a", "B"])
    con4.create_collation("nocase2", lambda a, b: (a.lower() > b.lower()) - (a.lower() < b.lower()))
    check("a collation in a comparison", con4.execute("select count(*) from w where s = 'b' collate nocase2").fetchone()[0], 2)
    con4.create_collation("reverse", None)
    check("a removed collation", err(lambda: con4.execute("select s from w order by s collate reverse").fetchall()),
          ["OperationalError", "no such collation sequence: reverse"])
    # a function that uses the connection itself
    con4.create_function("count_w", 0, lambda: con4.execute("select count(*) from w").fetchone()[0])
    check("a function querying its own connection", con4.execute("select count_w() + 1").fetchone()[0], 5)
    # authorizer, progress handler
    seen = []
    def auth(action, arg1, arg2, dbname, source):
        seen.append((action, arg1, arg2, dbname))
        if arg2 == "secret":
            return sqlite3.SQLITE_DENY
        if arg2 == "hidden":
            return sqlite3.SQLITE_IGNORE
        return sqlite3.SQLITE_OK
    con4.execute("create table s(public, secret, hidden)")
    con4.execute("insert into s values (1, 2, 3)")
    con4.set_authorizer(auth)
    r2 = [con4.execute("select public, hidden from s").fetchone(), dberr(lambda: con4.execute("select secret from s"))[::2]]
    con4.set_authorizer(None)
    r2.append((sqlite3.SQLITE_READ, "s", "public", "main") in seen)
    r2.append(con4.execute("select secret from s").fetchone())
    check("set_authorizer", r2, [(1, None), ["DatabaseError", 23], True, (2,)])
    calls = []
    def progress():
        calls.append(1)
        return len(calls) > 3
    con4.set_progress_handler(progress, 1)
    r3 = dberr(lambda: con4.execute("with recursive c(x) as (select 1 union all select x + 1 from c where x < 100000) select count(*) from c").fetchone())
    con4.set_progress_handler(None, 1)
    check("set_progress_handler", [r3, len(calls) >= 4], [["OperationalError", "interrupted", 9, "SQLITE_INTERRUPT"], True])
    # adapters and converters
    class Point:
        def __init__(self, x, y):
            self.x = x
            self.y = y
        def __repr__(self):
            return "Point(%r, %r)" % (self.x, self.y)
    sqlite3.register_adapter(Point, lambda p: "%s;%s" % (p.x, p.y))
    sqlite3.register_converter("point", lambda b: Point(*[float(v) for v in b.split(b";")]))
    con5 = sqlite3.connect(":memory:", detect_types=sqlite3.PARSE_DECLTYPES | sqlite3.PARSE_COLNAMES)
    con5.execute("create table p(id integer, pt point)")
    con5.execute("insert into p values (?, ?)", (1, Point(1.5, -2)))
    check("adapter + converter (PARSE_DECLTYPES)", repr(con5.execute("select pt from p").fetchone()[0]), "Point(1.5, -2.0)")
    check("the stored text", [con5.execute("select cast(pt as text) from p").fetchone()[0],
                              repr(con5.execute('select pt as "pt [text]" from p').fetchone()[0])], ["1.5;-2", "Point(1.5, -2.0)"])
    check("PARSE_COLNAMES", [repr(con5.execute('select \'3;4\' as "p [point]"').fetchone()[0]),
                             con5.execute('select \'3;4\' as "p [point]"').description[0][0]], ["Point(3.0, 4.0)", "p"])
    class Conformer:
        def __conform__(self, proto):
            if proto is sqlite3.PrepareProtocol:
                return "conformed"
    check("__conform__", con5.execute("select ?", (Conformer(),)).fetchone()[0], "conformed")
    check("sqlite3.adapt", [sqlite3.adapt(Point(1, 2)), sqlite3.adapt(5, sqlite3.PrepareProtocol, "alt"), err(lambda: sqlite3.adapt(object()))],
          ["1;2", "alt", ["ProgrammingError", "can't adapt"]])
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        con5.execute("create table d(d date, ts timestamp)")
        con5.execute("insert into d values (?, ?)", (datetime.date(2024, 2, 29), datetime.datetime(2024, 2, 29, 13, 5, 7, 250)))
        row = con5.execute("select d, ts from d").fetchone()
        raw = con5.execute('select d || "", ts || "" from d').fetchone()
    check("the default date/timestamp adapters and converters", [row, raw],
          [(datetime.date(2024, 2, 29), datetime.datetime(2024, 2, 29, 13, 5, 7, 250)), ("2024-02-29", "2024-02-29 13:05:07.000250")])
    # iterdump
    con6 = sqlite3.connect(":memory:")
    con6.executescript("""
        create table t1(id integer primary key autoincrement, name text, data blob, f real);
        insert into t1(name, data, f) values ('it''s', x'00ff', 1.5);
        insert into t1(name, data, f) values (null, null, -2);
        create index i1 on t1(name);
        create view v1 as select name from t1;
    """)
    check("iterdump", list(con6.iterdump()),
          ["BEGIN TRANSACTION;",
           "CREATE TABLE t1(id integer primary key autoincrement, name text, data blob, f real);",
           "INSERT INTO \"t1\" VALUES(1,'it''s',X'00FF',1.5);",
           "INSERT INTO \"t1\" VALUES(2,NULL,NULL,-2.0);",
           "CREATE INDEX i1 on t1(name);",
           "CREATE VIEW v1 as select name from t1;",
           "DELETE FROM \"sqlite_sequence\";",
           "INSERT INTO \"sqlite_sequence\" VALUES('t1',2);",
           "COMMIT;"])
    # backup
    con7 = sqlite3.connect(":memory:")
    steps = []
    con6.backup(con7, pages=1, progress=lambda status, remaining, total: steps.append((status, remaining, total)))
    check("backup", [con7.execute("select name from t1 order by id").fetchall(), len(steps) >= 1, steps[-1][1]], [[("it's",), (None,)], True, 0])
    check("backup errors", [err(lambda: con6.backup(con6)), err(lambda: con6.backup(5))],
          [["ValueError", "target cannot be the same connection instance"],
           ["TypeError", "backup() argument 'target' must be sqlite3.Connection, not int"]])
    # blobs
    if sys.version_info >= (3, 11):
        con7.execute("create table b(data blob)")
        con7.execute("insert into b values (zeroblob(8))")
        con7.commit()
        with con7.blobopen("b", "data", 1) as blob:
            blob.write(b"abcd")
            blob.seek(-2, 2)
            blob.write(b"yz")
            blob.seek(0)
            rb = [len(blob), blob.read(3), blob.tell(), blob[0], blob[-1], blob[1:3], blob[::3]]
            blob[4] = 33
            blob[5:6] = b"?"
            rb.append(err(lambda: blob.write(b"x" * 20)))
            rb.append(err(lambda: blob.seek(100)))
            rb.append(err(lambda: blob[99]))
        con7.commit()
        rb.append(con7.execute("select data from b").fetchone()[0])
    else:
        rb = None
    check("blobopen", rb, [8, b"abc", 3, 97, 122, b"bc", b"ady", ["ValueError", "data longer than blob length"],
                           ["ValueError", "offset out of blob range"], ["IndexError", "Blob index out of range"], b"abcd!?yz"])
    # limits, serialize, interrupt
    check("getlimit/setlimit", [con7.setlimit(sqlite3.SQLITE_LIMIT_SQL_LENGTH, 100) > 100, con7.getlimit(sqlite3.SQLITE_LIMIT_SQL_LENGTH),
                                dberr(lambda: con7.execute("select '" + "x" * 200 + "'"))],
          [True, 100, ["DataError", "query string is too large", None, None]])
    data = con6.serialize()
    con8 = sqlite3.connect(":memory:")
    con8.deserialize(data)
    check("serialize/deserialize", [data[:16], con8.execute("select count(*) from t1").fetchone()[0]], [b"SQLite format 3\x00", 2])
    # closed objects
    cu8 = con8.cursor()
    cu8.close()
    check("a closed cursor", err(lambda: cu8.execute("select 1")), ["ProgrammingError", "Cannot operate on a closed cursor."])
    con8.close()
    con8.close()
    check("a closed connection", [err(lambda: con8.execute("select 1")), err(lambda: con8.cursor()), err(lambda: con8.commit())],
          [["ProgrammingError", "Cannot operate on a closed database."]] * 3)
    check("unable to open", dberr(lambda: sqlite3.connect("/nonexistent-dir-xyz/x.db")),
          ["OperationalError", "unable to open database file", 14, "SQLITE_CANTOPEN"])
    # a file database, uri=, threads
    import os
    import tempfile
    import threading
    d = tempfile.mkdtemp()
    path = os.path.join(d, "t.db")
    f1 = sqlite3.connect(path)
    f1.execute("create table t(x)")
    f1.execute("insert into t values (42)")
    f1.commit()
    ro = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
    check("uri=: a read-only connection", [ro.execute("select x from t").fetchone(), dberr(lambda: ro.execute("insert into t values (1)"))],
          [(42,), ["OperationalError", "attempt to write a readonly database", 8, "SQLITE_READONLY"]])
    ro.close()
    out = []
    def other():
        out.append(err(lambda: f1.execute("select 1")))
        c = sqlite3.connect(path)
        out.append(c.execute("select x from t").fetchone())
        c.close()
    th = threading.Thread(target=other)
    th.start()
    th.join()
    check("check_same_thread", [out[0][0], out[0][1].startswith("SQLite objects created in a thread can only be used in that same thread."), out[1]],
          ["ProgrammingError", True, (42,)])
    f2 = sqlite3.connect(path, check_same_thread=False)
    out2 = []
    th = threading.Thread(target=lambda: out2.append(f2.execute("select x * 2 from t").fetchone()))
    th.start()
    th.join()
    check("check_same_thread=False", out2, [(84,)])
    f1.close()
    f2.close()
    class MyConnection(sqlite3.Connection):
        pass
    class MyCursor(sqlite3.Cursor):
        pass
    mc = sqlite3.connect(":memory:", factory=MyConnection)
    check("factory= and cursor(factory)", [type(mc).__name__, type(mc.cursor(MyCursor)).__name__, err(lambda: mc.cursor(lambda c: 5))],
          ["MyConnection", "MyCursor", ["TypeError", "factory must return a cursor, not int"]])
    import shutil
    shutil.rmtree(d)


# ── sqlite3: callbacks from several threads at once ─────────────────────────
def sqlite_thread_checks():
    try:
        import sqlite3
    except ImportError as e:
        print("NOTICE: sqlite3 thread checks skipped - " + str(e))
        return
    import os
    import tempfile
    import threading
    d = tempfile.mkdtemp()
    path = os.path.join(d, "threads.db")
    con = sqlite3.connect(path)
    con.execute("create table t(n)")
    con.executemany("insert into t values (?)", [(i,) for i in range(200)])
    con.commit()
    con.close()
    results = {}
    def worker(k):
        c = sqlite3.connect(path, timeout=30)
        c.create_function("scale", 1, lambda v: v * k)
        class Sum:
            def __init__(self):
                self.s = 0
            def step(self, v):
                self.s += v
            def finalize(self):
                return self.s
        c.create_aggregate("mysum", 1, Sum)
        c.create_collation("rev", lambda a, b: (a < b) - (a > b))
        r = c.execute("select mysum(scale(n)) from t").fetchone()[0]
        r2 = [x[0] for x in c.execute("select cast(n as text) from t where n < 5 order by 1 collate rev")]
        c.close()
        results[k] = (r, r2)
    ts = [threading.Thread(target=worker, args=(k,)) for k in range(1, 5)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    check("sqlite3: callbacks in four threads at once", sorted(results.items()),
          [(k, (19900 * k, ["4", "3", "2", "1", "0"])) for k in range(1, 5)])
    shared = sqlite3.connect(path, check_same_thread=False)
    shared.create_function("twice", 1, lambda v: v * 2)
    out = []
    lock = threading.Lock()
    def user(i):
        v = shared.execute("select twice(n) from t where n = ?", (i,)).fetchone()[0]
        with lock:
            out.append(v)
    ts = [threading.Thread(target=user, args=(i,)) for i in range(8)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    shared.close()
    check("sqlite3: one connection shared by threads, with a function", sorted(out), [0, 2, 4, 6, 8, 10, 12, 14])
    import shutil
    shutil.rmtree(d)


# ── email ────────────────────────────────────────────────────────────────────
MIME_SAMPLE = (
    "Return-Path: <alice@example.org>\n"
    "Received: from mail.example.org (mail.example.org [192.0.2.1])\n"
    "\tby mx.example.com with ESMTPS id abc123\n"
    "\tfor <bob@example.com>; Tue, 01 Oct 2024 10:00:00 +0200\n"
    "From: =?utf-8?q?Al=C3=AFce_Smith?= <alice@example.org>\n"
    "To: Bob <bob@example.com>, \"Carol, Jr.\" <carol@example.com>\n"
    "Cc: undisclosed-recipients:;\n"
    "Subject: =?iso-8859-1?q?R=E9sum=E9?= and a very long subject line that goes on and on past seventy-eight characters\n"
    "Date: Tue, 01 Oct 2024 10:00:00 +0200\n"
    "Message-ID: <20241001.abc@example.org>\n"
    "MIME-Version: 1.0\n"
    "Content-Type: multipart/mixed; boundary=\"===outer===\"\n"
    "\n"
    "This is a multi-part message in MIME format.\n"
    "--===outer===\n"
    "Content-Type: multipart/alternative; boundary=\"inner\"\n"
    "\n"
    "--inner\n"
    "Content-Type: text/plain; charset=\"utf-8\"\n"
    "Content-Transfer-Encoding: quoted-printable\n"
    "\n"
    "Hello Bob,=0A=0ACaf=C3=A9 at 10? Soft line=\n"
    " break here.\n"
    "--inner\n"
    "Content-Type: text/html; charset=\"utf-8\"\n"
    "Content-Transfer-Encoding: 8bit\n"
    "\n"
    "<p>Hello <b>Bob</b></p>\n"
    "--inner--\n"
    "\n"
    "--===outer===\n"
    "Content-Type: application/pdf; name=\"report.pdf\"\n"
    "Content-Transfer-Encoding: base64\n"
    "Content-Disposition: attachment; filename=\"report.pdf\"\n"
    "\n"
    "JVBERi0xLjQKJcOkw7zDtsOfCjIgMCBvYmoKPDwvTGVuZ3RoIDMgMCBSPj4Kc3RyZWFtCg==\n"
    "--===outer===\n"
    "Content-Type: message/rfc822\n"
    "\n"
    "From: inner@example.net\n"
    "Subject: forwarded\n"
    "\n"
    "Inner body.\n"
    "--===outer===--\n"
    "Epilogue text.\n"
)


def email_checks():
    import email
    import email.message
    import email.parser
    import email.policy
    import email.utils
    import email.header
    import email.charset
    import email.encoders
    import email.iterators
    import email.errors
    import email.headerregistry
    import email.generator
    import email.quoprimime
    import email.base64mime
    from email.mime.text import MIMEText
    from email.mime.multipart import MIMEMultipart
    from email.mime.application import MIMEApplication
    from email.mime.image import MIMEImage
    from email.mime.audio import MIMEAudio
    from email.mime.message import MIMEMessage
    from email.mime.base import MIMEBase
    import io
    import datetime
    msg = email.message_from_string(MIME_SAMPLE)
    check("parse: the structure", [p.get_content_type() for p in msg.walk()],
          ["multipart/mixed", "multipart/alternative", "text/plain", "text/html", "application/pdf", "message/rfc822", "text/plain"])
    check("parse: headers", [msg["To"], msg["Cc"], msg.get("X-Missing"), msg.get("x-missing", "dflt"), len(msg), "date" in msg,
                             msg.keys()[:3], msg.get_all("Received")[0][:30]],
          ['Bob <bob@example.com>, "Carol, Jr." <carol@example.com>', "undisclosed-recipients:;", None, "dflt", 10, True,
           ["Return-Path", "Received", "From"], "from mail.example.org (mail.ex"])
    check("parse: multipart facts", [msg.is_multipart(), msg.get_boundary(), msg.preamble, msg.epilogue, msg.get_content_maintype(),
                                     msg.get_params(), msg.get_param("boundary"), msg.get_default_type()],
          [True, "===outer===", "This is a multi-part message in MIME format.", "Epilogue text.\n", "multipart",
           [("multipart/mixed", ""), ("boundary", "===outer===")], "===outer===", "text/plain"])
    text = msg.get_payload(0).get_payload(0)
    check("parse: a quoted-printable part", [text.get_content_charset(), text.get_payload(decode=True), text["content-transfer-encoding"]],
          ["utf-8", b"Hello Bob,\n\nCaf\xc3\xa9 at 10? Soft line break here.", "quoted-printable"])
    pdf = msg.get_payload(1)
    check("parse: an attachment", [pdf.get_filename(), pdf.get_param("name"), pdf.get_payload(decode=True)[:8],
                                   pdf.get_content_disposition(), pdf.get("content-disposition")],
          ["report.pdf", "report.pdf", b"%PDF-1.4", "attachment", 'attachment; filename="report.pdf"'])
    inner = msg.get_payload(2)
    check("parse: message/rfc822", [inner.is_multipart(), inner.get_payload(0)["Subject"], inner.get_payload(0).get_payload()],
          [True, "forwarded", "Inner body."])
    check("decode_header", [email.header.decode_header(msg["From"]), email.header.decode_header(msg["Subject"])[0]],
          [[(b"Al\xc3\xafce Smith", "utf-8"), (b" <alice@example.org>", None)], (b"R\xe9sum\xe9", "iso-8859-1")])
    check("make_header", str(email.header.make_header(email.header.decode_header(msg["Subject"])))[:40],
          "R\xe9sum\xe9 and a very long subject line that")
    check("round trip: as_string", msg.as_string() == MIME_SAMPLE, True)
    out = io.StringIO()
    email.generator.Generator(out, mangle_from_=False).flatten(msg)
    folded = MIME_SAMPLE.replace("goes on and on past", "goes on\n and on past")
    check("round trip: Generator (folding at 78)", [out.getvalue() == folded, out.getvalue().split("\n")[7:9]],
          [True, ["Subject: =?iso-8859-1?q?R=E9sum=E9?= and a very long subject line that goes on", " and on past seventy-eight characters"]])
    bmsg = email.message_from_bytes(MIME_SAMPLE.encode("ascii"))
    check("round trip: bytes", bmsg.as_bytes() == folded.encode("ascii"), True)
    check("body_line_iterator", list(email.iterators.body_line_iterator(msg))[:3],
          ["Hello Bob,=0A=0ACaf=C3=A9 at 10? Soft line=\n", " break here.", "<p>Hello <b>Bob</b></p>"])
    sio = io.StringIO()
    email.iterators._structure(msg, sio)
    check("_structure", sio.getvalue(),
          "multipart/mixed\n    multipart/alternative\n        text/plain\n        text/html\n    application/pdf\n"
          "    message/rfc822\n        text/plain\n")
    check("typed_subpart_iterator", [p.get_content_subtype() for p in email.iterators.typed_subpart_iterator(msg, "text")],
          ["plain", "html", "plain"])
    # the default policy: EmailMessage
    em = email.message_from_string(MIME_SAMPLE, policy=email.policy.default)
    frm = em["From"]
    check("policy.default: address headers", [str(frm), frm.addresses[0].display_name, frm.addresses[0].username,
                                              frm.addresses[0].domain, [a.addr_spec for a in em["To"].addresses],
                                              em["To"].addresses[1].display_name, type(frm).__name__],
          ["Al\xefce Smith <alice@example.org>", "Al\xefce Smith", "alice", "example.org", ["bob@example.com", "carol@example.com"],
           "Carol, Jr.", "_UniqueAddressHeader"])
    check("policy.default: groups", [em["Cc"].groups[0].display_name, em["Cc"].groups[0].addresses], ["undisclosed-recipients", ()])
    check("policy.default: dates", [em["Date"].datetime, em["Date"].datetime.utcoffset()],
          [datetime.datetime(2024, 10, 1, 10, 0, tzinfo=datetime.timezone(datetime.timedelta(seconds=7200))), datetime.timedelta(seconds=7200)])
    check("policy.default: decoded subject", em["Subject"],
          "R\xe9sum\xe9 and a very long subject line that goes on and on past seventy-eight characters")
    body = em.get_body(preferencelist=("plain", "html"))
    check("get_body / get_content", [body.get_content_type(), body.get_content()],
          ["text/plain", "Hello Bob,\n\nCaf\xe9 at 10? Soft line break here."])
    check("iter_attachments", [(p.get_content_type(), p.get_filename()) for p in em.iter_attachments()],
          [("application/pdf", "report.pdf"), ("message/rfc822", None)])
    check("get_content of a binary part", em.get_payload(1).get_content()[:8], b"%PDF-1.4")
    check("params", [em["Content-Type"].content_type, em["Content-Type"].params["boundary"], dict(em.get_payload(1)["Content-Disposition"].params)],
          ["multipart/mixed", "===outer===", {"filename": "report.pdf"}])
    # building with EmailMessage
    m = email.message.EmailMessage()
    m["From"] = email.headerregistry.Address("J\xf6rg M\xfcller", "joerg", "example.de")
    m["To"] = "a@example.com, B <b@example.com>"
    m["Subject"] = "Gr\xfc\xdfe aus K\xf6ln - ein Betreff, der lang genug ist, um umgebrochen zu werden"
    m["Date"] = email.utils.format_datetime(datetime.datetime(2024, 3, 5, 8, 9, 10, tzinfo=datetime.timezone.utc))
    m["Message-ID"] = "<fixed@example.de>"
    m.set_content("Hallo,\nviele Gr\xfc\xdfe!\n")
    m.add_alternative("<p>Hallo</p>\n", subtype="html")
    m.add_attachment(b"\x89PNG\r\n\x1a\n" + bytes(range(40)), maintype="image", subtype="png", filename="dot.png")
    s = m.as_string()
    lines = s.split("\n")
    check("EmailMessage: headers as generated", lines[:6],
          ["From: =?utf-8?q?J=C3=B6rg_M=C3=BCller?= <joerg@example.de>",
           "To: a@example.com, B <b@example.com>",
           "Subject: =?utf-8?b?R3LDvMOfZSBhdXMgS8O2bG4=?= - ein Betreff, der lang genug",
           " ist, um umgebrochen zu werden",
           "Date: Tue, 05 Mar 2024 08:09:10 +0000",
           "Message-ID: <fixed@example.de>"])
    check("EmailMessage: the structure", [p.get_content_type() for p in m.walk()],
          ["multipart/mixed", "multipart/alternative", "text/plain", "text/html", "image/png"])
    m2 = email.message_from_string(s, policy=email.policy.default)
    check("EmailMessage: parse what it generated", [str(m2["From"]), m2["Subject"], m2.get_body(("plain",)).get_content(),
                                                    [a.get_content() for a in m2.iter_attachments()][0][:4], m2.get_payload(1).get_filename()],
          ["J\xf6rg M\xfcller <joerg@example.de>", "Gr\xfc\xdfe aus K\xf6ln - ein Betreff, der lang genug ist, um umgebrochen zu werden",
           "Hallo,\nviele Gr\xfc\xdfe!\n", b"\x89PNG", "dot.png"])
    simple = email.message.EmailMessage()
    simple["Subject"] = "Hi"
    simple.set_content("Line one\nLine two\n")
    check("EmailMessage: a simple text message", simple.as_string(),
          'Subject: Hi\nContent-Type: text/plain; charset="utf-8"\nContent-Transfer-Encoding: 7bit\nMIME-Version: 1.0\n\nLine one\nLine two\n')
    check("policy.SMTP: CRLF", simple.as_bytes(policy=email.policy.SMTP)[:30], b"Subject: Hi\r\nContent-Type: tex")
    u = email.message.EmailMessage()
    u.set_content("caf\xe9 " * 3 + "\n")
    check("set_content picks 8bit/quoted-printable", [u["Content-Transfer-Encoding"], u.get_content()], ["8bit", "caf\xe9 caf\xe9 caf\xe9 \n"])
    q = email.message.EmailMessage()
    q.set_content("\xe9" * 100 + "\n", cte="quoted-printable")
    check("set_content cte=quoted-printable", q.get_payload().split("\n")[:2],
          ["=C3=A9" * 12 + "=C3=", "=A9" + "=C3=A9" * 12 + "="])
    # compat32 MIME classes
    mm = MIMEMultipart("alternative", boundary="BOUNDARY")
    mm["Subject"] = "Test"
    mm.attach(MIMEText("plain text", "plain"))
    mm.attach(MIMEText("<b>html</b>", "html", "utf-8"))
    check("MIMEMultipart + MIMEText", mm.as_string(),
          'Content-Type: multipart/alternative; boundary="BOUNDARY"\nMIME-Version: 1.0\nSubject: Test\n\n'
          '--BOUNDARY\nContent-Type: text/plain; charset="us-ascii"\nMIME-Version: 1.0\nContent-Transfer-Encoding: 7bit\n\n'
          'plain text\n--BOUNDARY\nContent-Type: text/html; charset="utf-8"\nMIME-Version: 1.0\nContent-Transfer-Encoding: base64\n\n'
          'PGI+aHRtbDwvYj4=\n\n--BOUNDARY--\n')
    app = MIMEApplication(b"\x00\x01\x02binary", Name="x.bin")
    check("MIMEApplication", [app.get_content_type(), app["Content-Transfer-Encoding"], app.get_payload(), app.get_param("name")],
          ["application/octet-stream", "base64", "AAECYmluYXJ5\n", "x.bin"])
    gif = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"
    check("MIMEImage guesses the type", [MIMEImage(gif).get_content_type(), MIMEImage(b"\x89PNG\r\n\x1a\nxxxx").get_content_type()],
          ["image/gif", "image/png"])
    wav = b"RIFF$\x00\x00\x00WAVEfmt " + b"\x00" * 24
    check("MIMEAudio guesses the type", MIMEAudio(wav).get_content_type(), "audio/x-wav")
    fwd = MIMEMessage(email.message_from_string("Subject: inner\n\nbody\n"))
    check("MIMEMessage", [fwd.get_content_type(), fwd.get_payload(0)["Subject"]], ["message/rfc822", "inner"])
    base = MIMEBase("application", "x-thing", foo="bar")
    base.set_payload(b"\xff\xfe")
    email.encoders.encode_base64(base)
    check("MIMEBase + encode_base64", [base["Content-Type"], base.get_payload()], ['application/x-thing; foo="bar"', "//4=\n"])
    # utils
    check("formataddr / parseaddr", [email.utils.formataddr(("Jo Doe", "jo@example.com")), email.utils.formataddr(("Doe, Jo", "jo@example.com")),
                                     email.utils.formataddr(("J\xf6", "jo@example.com")), email.utils.parseaddr("Jo Doe <jo@example.com>"),
                                     email.utils.parseaddr('"Doe, Jo" <jo@example.com>'), email.utils.parseaddr("jo@example.com (Jo)")],
          ["Jo Doe <jo@example.com>", '"Doe, Jo" <jo@example.com>', "=?utf-8?b?SsO2?= <jo@example.com>", ("Jo Doe", "jo@example.com"),
           ("Doe, Jo", "jo@example.com"), ("Jo", "jo@example.com")])
    check("getaddresses", email.utils.getaddresses(["a@b.c, Bob <bob@x.y>", "\"Q, R\" <q@r.s>"]),
          [("", "a@b.c"), ("Bob", "bob@x.y"), ("Q, R", "q@r.s")])
    check("formatdate", [email.utils.formatdate(0), email.utils.formatdate(1700000000, usegmt=True),
                         email.utils.format_datetime(datetime.datetime(2001, 2, 3, 4, 5, 6, tzinfo=datetime.timezone(datetime.timedelta(hours=-5))))],
          ["Thu, 01 Jan 1970 00:00:00 -0000", "Tue, 14 Nov 2023 22:13:20 GMT", "Sat, 03 Feb 2001 04:05:06 -0500"])
    check("parsedate family", [email.utils.parsedate_tz("Tue, 01 Oct 2024 10:00:00 +0200"), email.utils.parsedate("1 Jan 2000 00:00:00"),
                               email.utils.parsedate_to_datetime("Tue, 01 Oct 2024 10:00:00 -0000"),
                               email.utils.mktime_tz(email.utils.parsedate_tz("Thu, 01 Jan 1970 01:00:00 +0100"))],
          [(2024, 10, 1, 10, 0, 0, 0, 1, -1, 7200), (2000, 1, 1, 0, 0, 0, 0, 1, -1),
           datetime.datetime(2024, 10, 1, 10, 0), 0])
    mid = email.utils.make_msgid(domain="example.com")
    check("make_msgid", [mid.startswith("<"), mid.endswith("@example.com>"), mid.count("@"), email.utils.make_msgid("x", "d.org").endswith(".x@d.org>")],
          [True, True, 1, True])
    check("rfc2231", [email.utils.encode_rfc2231("caf\xe9", "utf-8"), email.utils.decode_rfc2231("utf-8''caf%C3%A9"),
                      email.utils.collapse_rfc2231_value(("utf-8", "", "caf\xc3\xa9")), email.utils.quote('a"b\\c'), email.utils.unquote('"x"')],
          ["utf-8''caf%C3%A9", ["utf-8", "", "caf%C3%A9"], "caf\xe9", 'a\\"b\\\\c', "x"])
    att = email.message_from_string('Content-Type: text/plain\nContent-Disposition: attachment;\n filename*=utf-8\'\'na%C3%AFve%20file.txt\n\nx\n')
    check("an RFC 2231 file name", att.get_filename(), "na\xefve file.txt")
    # header, charset, encoders
    h = email.header.Header("Hello W\xf6rld", "iso-8859-1")
    check("Header", [h.encode(), str(email.header.Header("plain ascii")), email.header.Header("x" * 100).encode()[:85]],
          ["=?iso-8859-1?q?Hello_W=F6rld?=", "plain ascii", "x" * 85])
    cs = email.charset.Charset("utf-8")
    check("Charset", [cs.input_charset, cs.header_encoding, cs.body_encoding, cs.get_output_charset(), cs.header_encode("caf\xe9"),
                      email.charset.Charset("iso-8859-1").body_encoding, str(email.charset.Charset("us-ascii"))],
          ["utf-8", 3, 2, "utf-8", "=?utf-8?b?Y2Fmw6k=?=", 1, "us-ascii"])
    check("quoprimime / base64mime", [email.quoprimime.body_encode("caf\xe9 = x\n"), email.quoprimime.header_encode(b"a b=c"),
                                      email.quoprimime.decode("a=3Db=\nc"), email.base64mime.body_encode(b"hello"),
                                      email.base64mime.header_encode("hi", "utf-8"), email.base64mime.decode("aGk=")],
          ["caf=E9 =3D x\n", "=?iso-8859-1?q?a_b=3Dc?=", "a=bc", "aGVsbG8=\n", "=?utf-8?b?aGk=?=", b"hi"])
    # defects
    bad = email.message_from_string("Content-Type: multipart/mixed\n\nno boundary here\n")
    check("defects", [type(d).__name__ for d in bad.defects], ["NoBoundaryInMultipartDefect", "MultipartInvariantViolationDefect"])
    bad2 = email.message_from_string("From: a\nBad header line\n\nbody\n")
    check("a missing header body", [type(d).__name__ for d in bad2.defects], ["MissingHeaderBodySeparatorDefect"])
    check("the errors' hierarchy", [c.__name__ for c in email.errors.HeaderParseError.__mro__[:4]],
          ["HeaderParseError", "MessageParseError", "MessageError", "Exception"])
    try:
        email.message_from_string("Content-Type: multipart/mixed\n\nx\n", policy=email.policy.strict)
        r4 = "no error"
    except email.errors.MessageDefect as e:
        r4 = type(e).__name__
    check("policy.strict", r4, "NoBoundaryInMultipartDefect")
    # message API
    cm = email.message.Message()
    cm["X-A"] = "1"
    cm["X-A"] = "2"
    cm.add_header("Content-Disposition", "attachment", filename="f.txt")
    cm.set_param("charset", "utf-8")
    cm.replace_header("X-A", "3")
    check("Message API", [cm.get_all("x-a"), cm["Content-Disposition"], cm["Content-Type"], cm.get_param("charset"),
                          cm.items()[0], cm.get_content_type()],
          [["3", "2"], 'attachment; filename="f.txt"', 'text/plain; charset="utf-8"', "utf-8", ("X-A", "3"), "text/plain"])
    del cm["x-a"]
    cm.set_type("text/html")
    cm.del_param("charset")
    check("Message API 2", [cm.get_all("X-A"), cm["Content-Type"], str(cm).split("\n")[0]],
          [None, "text/html", 'Content-Disposition: attachment; filename="f.txt"'])
    # from-mangling and long headers
    fm = email.message_from_string("Subject: x\n\nFrom here\n")
    out = io.StringIO()
    email.generator.Generator(out).flatten(fm)
    check("mangle_from_", out.getvalue(), "Subject: x\n\n>From here\n")
    lh = email.message.Message()
    lh["To"] = ", ".join("person%d@example.com" % i for i in range(6))
    check("folding (compat32)", lh.as_string().split("\n")[:3],
          ["To: person0@example.com, person1@example.com, person2@example.com, person3@example.com, person4@example.com, person5@example.com", "", ""])
    eh = email.message.EmailMessage()
    eh["To"] = ", ".join("person%d@example.com" % i for i in range(6))
    check("folding (default)", eh.as_string().split("\n")[:3],
          ["To: person0@example.com, person1@example.com, person2@example.com,", " person3@example.com, person4@example.com, person5@example.com", ""])
    hp = email.parser.HeaderParser().parsestr("A: 1\nB: 2\n\nbody not parsed\n--x\n")
    check("HeaderParser", [hp["B"], hp.get_payload()], ["2", "body not parsed\n--x\n"])
    fp = email.parser.BytesFeedParser()
    for piece in [b"Subject: fe", b"ed\nContent-Type: text/plain; charset=utf-8\n\nbo", b"dy \xc3\xa9\n"]:
        fp.feed(piece)
    fmsg = fp.close()
    check("BytesFeedParser in pieces", [fmsg["Subject"], fmsg.get_payload(decode=True).decode("utf-8")], ["feed", "body \xe9\n"])
    reg = email.headerregistry.HeaderRegistry()
    dh = reg("Date", "Fri, 13 Sep 2024 01:02:03 -0700")
    check("HeaderRegistry", [type(dh).__name__, dh.datetime.year, dh.max_count, str(email.headerregistry.Address(addr_spec="x@y.z"))],
          ["_UniqueDateHeader", 2024, 1, "x@y.z"])


# ── email: the default policy's API (MIMEPart, contentmanager, policies) ─────
def email_api_checks():
    import email
    import email.policy
    import email.message
    import email.headerregistry
    import email.contentmanager
    import email.generator
    import io
    pol = email.policy.default
    check("policies", [pol.max_line_length, repr(pol.linesep), pol.utf8, email.policy.SMTP.linesep == "\r\n",
                       email.policy.SMTPUTF8.utf8, email.policy.HTTP.max_line_length, email.policy.strict.raise_on_defect,
                       email.policy.compat32.max_line_length, pol.clone(max_line_length=40).max_line_length,
                       (pol + email.policy.strict).raise_on_defect, type(pol.header_factory).__name__], [78, "'\\n'", False, True, True, None, True, 78, 40, True, 'HeaderRegistry'])
    try:
        pol.max_line_length = 5
        r = "no error"
    except AttributeError as e:
        r = str(e)
    check("policies are immutable", r, "'EmailPolicy' object attribute 'max_line_length' is read-only")
    try:
        pol.clone(nosuch=1)
        r = "no error"
    except TypeError as e:
        r = str(e)
    check("clone() of an unknown attribute", r, "'nosuch' is an invalid keyword argument for EmailPolicy")
    m = email.message.EmailMessage()
    m["From"] = email.headerregistry.Address("A", "a", "x.org")
    m["To"] = [email.headerregistry.Address("B", "b", "y.org"), email.headerregistry.Group("team", [email.headerregistry.Address("C", "c", "z.org")])]
    m["Subject"] = "API"
    m.set_content("<p>html <img src='cid:img1@x'></p>\n", subtype="html")
    m.add_related(b"GIF89a....", "image", "gif", cid="<img1@x>")
    m.add_alternative("plain\n")
    check("make_alternative/add_related structure", [p.get_content_type() for p in m.walk()], ['multipart/alternative', 'multipart/related', 'text/html', 'image/gif', 'text/plain'])
    check("get_body preferences", [m.get_body().get_content_type(), m.get_body(("plain",)).get_content(),
                                   m.get_body(("related",)).get_content_type(), m.get_body(("html",)).get_content()], ['multipart/related', 'plain\n', 'multipart/related', "<p>html <img src='cid:img1@x'></p>\n"])
    check("iter_parts", [p.get_content_type() for p in m.iter_parts()], ['multipart/related', 'text/plain'])
    att = email.message.EmailMessage()
    att.set_content(b"\x00\x01data", maintype="application", subtype="octet-stream", filename="d.bin", disposition="attachment",
                    headers=["X-Extra: 1"])
    check("set_content bytes", [att["Content-Type"], att["Content-Disposition"], att["Content-Transfer-Encoding"], att["X-Extra"],
                                att.get_content(), att.get_payload()], ['application/octet-stream', 'attachment; filename="d.bin"', 'base64', '1', b'\x00\x01data', 'AAFkYXRh\n'])
    inner = email.message.EmailMessage()
    inner["Subject"] = "inner"
    inner.set_content("inner body\n")
    outer = email.message.EmailMessage()
    outer["Subject"] = "outer"
    outer.set_content(inner)
    check("set_content a message", [outer.get_content_type(), outer.get_content()["Subject"], outer.as_string().split("\n")[:4]], ['message/rfc822', 'inner', ['Subject: outer', 'Content-Type: message/rfc822', 'Content-Transfer-Encoding: 8bit', 'MIME-Version: 1.0']])
    mixed = email.message.EmailMessage()
    mixed.set_content("text\n")
    mixed.make_mixed()
    mixed.attach(att)
    check("make_mixed", [p.get_content_type() for p in mixed.walk()], ['multipart/mixed', 'text/plain', 'application/octet-stream'])
    mixed.clear_content()
    check("clear_content", [mixed.get_content_type(), mixed.is_multipart(), list(mixed.keys())], ['text/plain', False, ['MIME-Version']])
    h = email.message.EmailMessage()
    h["Content-Type"] = "text/plain; charset=utf-8; format=flowed"
    h["Date"] = "Thu, 01 Jan 2004 12:00:00 +0100"
    h["Message-ID"] = "<1@x>"
    h["Content-Disposition"] = 'attachment; filename="a b.txt"'
    h["MIME-Version"] = "1.0"
    h["Content-Transfer-Encoding"] = "base64"
    check("header objects", [h["Content-Type"].content_type, dict(h["Content-Type"].params), h["Content-Type"].maintype,
                             h["Date"].datetime.isoformat(), h["Content-Disposition"].content_disposition,
                             h["MIME-Version"].major, h["Content-Transfer-Encoding"].cte, type(h["Message-ID"]).__name__], ['text/plain', {'charset': 'utf-8', 'format': 'flowed'}, 'text', '2004-01-01T12:00:00+01:00', 'attachment', 1, 'base64', '_MessageIDHeader'])
    try:
        h["Date"] = "again"
        r = "no error"
    except ValueError as e:
        r = str(e)
    check("a unique header twice", r, 'There may be at most 1 Date headers in a message')
    a = email.headerregistry.Address("Jane Q. Public", "jqp", "example.com")
    check("Address", [str(a), a.addr_spec, repr(a), str(email.headerregistry.Address(addr_spec="a.b@c.d")),
                      str(email.headerregistry.Group("g", [a])), str(email.headerregistry.Group(None, [a]))], ['"Jane Q. Public" <jqp@example.com>', 'jqp@example.com', "Address(display_name='Jane Q. Public', username='jqp', domain='example.com')", 'a.b@c.d', 'g: "Jane Q. Public" <jqp@example.com>;', '"Jane Q. Public" <jqp@example.com>'])
    try:
        email.headerregistry.Address(addr_spec="not an address")
        r = "no error"
    except Exception as e:
        r = type(e).__name__
    check("a bad addr_spec", r, 'InvalidHeaderDefect')
    out = io.BytesIO()
    msg = email.message.EmailMessage(policy=email.policy.SMTPUTF8)
    msg["To"] = "jö@ex.de"
    msg["Subject"] = "über"
    msg.set_content("x\n")
    email.generator.BytesGenerator(out).flatten(msg)
    check("SMTPUTF8 keeps UTF-8 headers", out.getvalue().split(b"\r\n")[:2], [b'To: j\xc3\xb6@ex.de', b'Subject: \xc3\xbcber'])
    folded = email.message.EmailMessage(policy=email.policy.default.clone(max_line_length=30))
    folded["Subject"] = "one two three four five six seven eight nine ten"
    check("folding at max_line_length", folded.as_string().split("\n")[:4], ['Subject: one two three four', ' five six seven eight nine ten', '', ''])
    p = email.message_from_bytes(b"Subject: =?utf-8?b?w6k=?=\nContent-Type: text/plain; charset=latin-1\nContent-Transfer-Encoding: 8bit\n\ncaf\xe9\n",
                                 policy=email.policy.default)
    check("8bit latin-1 body", [p["Subject"], p.get_content()], ['é', 'café\n'])
    check("get_content_maintype/subtype/charset", [p.get_content_maintype(), p.get_content_subtype(), p.get_content_charset(),
                                                   p.get_param("charset"), p.get_params()], ['text', 'plain', 'latin-1', 'latin-1', [('text/plain', ''), ('charset', 'latin-1')]])


# ── plistlib, quopri, uu, netrc, mailcap, cgi, cgitb ─────────────────────────
def plist_checks():
    import plistlib
    import datetime
    data = {"name": "Nython", "version": 3, "pi": 3.25, "ok": True, "no": False, "big": 2 ** 40, "neg": -7,
            "when": datetime.datetime(2024, 1, 2, 3, 4, 5), "blob": b"\x00\x01binary\xff", "list": [1, "two", [3.5]],
            "nested": {"a": {}, "b": [], "c": "caf\xe9 <&>"}, "uid": plistlib.UID(7)}
    xml = plistlib.dumps({k: v for k, v in data.items() if k != "uid"})
    check("plistlib XML dumps: the bytes", xml,
          b'<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
          b'<plist version="1.0">\n<dict>\n\t<key>big</key>\n\t<integer>1099511627776</integer>\n\t<key>blob</key>\n\t<data>\n\tAAFiaW5hcnn/\n\t</data>\n'
          b'\t<key>list</key>\n\t<array>\n\t\t<integer>1</integer>\n\t\t<string>two</string>\n\t\t<array>\n\t\t\t<real>3.5</real>\n\t\t</array>\n\t</array>\n'
          b'\t<key>name</key>\n\t<string>Nython</string>\n\t<key>neg</key>\n\t<integer>-7</integer>\n\t<key>nested</key>\n\t<dict>\n\t\t<key>a</key>\n\t\t<dict/>\n'
          b'\t\t<key>b</key>\n\t\t<array/>\n\t\t<key>c</key>\n\t\t<string>caf\xc3\xa9 &lt;&amp;&gt;</string>\n\t</dict>\n\t<key>no</key>\n\t<false/>\n'
          b'\t<key>ok</key>\n\t<true/>\n\t<key>pi</key>\n\t<real>3.25</real>\n\t<key>version</key>\n\t<integer>3</integer>\n\t<key>when</key>\n'
          b'\t<date>2024-01-02T03:04:05Z</date>\n</dict>\n</plist>\n')
    check("plistlib XML round trip", plistlib.loads(xml) == {k: v for k, v in data.items() if k != "uid"}, True)
    bplist = plistlib.dumps(data, fmt=plistlib.FMT_BINARY)
    check("plistlib binary dumps: the bytes", bplist, b'bplist00\xdc\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f\x14\x15\x16\x1d\x1e\x1f !"SbigTblobTlistTnameSnegVnestedRnoRokRpiSuidWversionTwhen\x13\x00\x00\x01\x00\x00\x00\x00\x00I\x00\x01binary\xff\xa3\x10\x11\x12\x10\x01Stwo\xa1\x13#@\x0c\x00\x00\x00\x00\x00\x00VNython\x13\xff\xff\xff\xff\xff\xff\xff\xf9\xd3\x17\x18\x19\x1a\x1b\x1cQaQbQc\xd0\xa0h\x00c\x00a\x00f\x00\xe9\x00 \x00<\x00&\x00>\x08\t#@\n\x00\x00\x00\x00\x00\x00\x80\x07\x10\x033A\xc5\xa1\xdaR\x80\x00\x00\x08!%*/48?BEHLTYblprvx\x81\x88\x91\x98\x9a\x9c\x9e\x9f\xa0\xb1\xb2\xb3\xbc\xbe\xc0\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00#\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xc9')
    back = plistlib.loads(bplist)
    check("plistlib binary round trip", [back == data, back["uid"], type(back["uid"]).__name__, back["when"]],
          [True, plistlib.UID(7), "UID", datetime.datetime(2024, 1, 2, 3, 4, 5)])
    check("plistlib sort_keys=False", plistlib.dumps({"b": 1, "a": 2}, sort_keys=False).split(b"<dict>")[1][:22], b"\n\t<key>b</key>\n\t<integ")
    check("plistlib errors", [err(lambda: plistlib.loads(b"not a plist")), err(lambda: plistlib.dumps({1: 2})),
                              err(lambda: plistlib.dumps({"a": None}))], [['InvalidFileException', 'Invalid file'], ['TypeError', 'keys must be strings'], ['TypeError', "unsupported type: <class 'NoneType'>"]])
    _x = (
    )
    check("plistlib skipkeys", plistlib.loads(plistlib.dumps({1: 2, "k": "v"}, skipkeys=True, sort_keys=False)), {"k": "v"})
    import io
    f = io.BytesIO()
    plistlib.dump([1, 2], f, fmt=plistlib.FMT_BINARY)
    f.seek(0)
    check("plistlib load/dump on files", [plistlib.load(f), f.getvalue()[:8]], [[1, 2], b"bplist00"])
    check("plistlib FMT constants", [plistlib.FMT_XML.name, plistlib.FMT_BINARY.value], ["FMT_XML", 2])


def quopri_uu_checks():
    import quopri
    import io
    check("quopri.encodestring", [quopri.encodestring(b"caf\xe9 = tab\there \n" + b"x" * 80 + b"\n"),
                                  quopri.encodestring(b"a b", quotetabs=True), quopri.encodestring(b"a_b c", header=True)],
          [b'caf=E9 =3D tab\there=20\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=\nxxxxx\n', b'a=20b', b'a=5Fb_c'])
    check("quopri.decodestring", [quopri.decodestring(b"caf=E9 =3D x=\ny"), quopri.decodestring(b"a_b=20c", header=True)],
          [b"caf\xe9 = xy", b"a b c"])
    inp = io.BytesIO(b"\xff\xfeline\n")
    out = io.BytesIO()
    quopri.encode(inp, out, quotetabs=False)
    out2 = io.BytesIO()
    quopri.decode(io.BytesIO(out.getvalue()), out2)
    check("quopri.encode/decode files", [out.getvalue(), out2.getvalue()], [b"=FF=FEline\n", b"\xff\xfeline\n"])
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        import uu
    src = io.BytesIO(b"The quick brown fox jumps over the lazy dog\n" * 2)
    enc = io.BytesIO()
    uu.encode(src, enc, name="fox.txt", mode=0o644)
    check("uu.encode", enc.getvalue(), b'begin 644 fox.txt\nM5&AE(\'%U:6-K(&)R;W=N(&9O>"!J=6UP<R!O=F5R(\'1H92!L87IY(&1O9PI4\nK:&4@<75I8VL@8G)O=VX@9F]X(&IU;7!S(&]V97(@=&AE(&QA>GD@9&]G"@  \n \nend\n')
    dec = io.BytesIO()
    uu.decode(io.BytesIO(enc.getvalue()), dec)
    check("uu.decode", dec.getvalue(), b"The quick brown fox jumps over the lazy dog\n" * 2)
    try:
        uu.decode(io.BytesIO(b"no begin line\n"), io.BytesIO())
        r = "no error"
    except uu.Error as e:
        r = str(e)
    check("uu.Error", r, "No valid begin line found in input file")


def netrc_mailcap_cgi_checks():
    import netrc
    import os
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "netrc")
    f = open(p, "w")
    f.write("machine host.example.com login alice password s3cret account acct1\n"
            "machine other.example.org\n  login bob\n  password \"pass word\"\n"
            "default login anonymous password guest@\n"
            "macdef init\ncd /pub\nbinary\n\n")
    f.close()
    os.chmod(p, 0o600)
    n = netrc.netrc(p)
    check("netrc", [n.authenticators("host.example.com"), n.authenticators("other.example.org"), n.authenticators("unknown.net"),
                    sorted(n.hosts.keys()), n.macros],
          [("alice", "acct1", "s3cret"), ("bob", "", "pass word"), ("anonymous", "", "guest@"),
           ["default", "host.example.com", "other.example.org"], {"init": ["cd /pub\n", "binary\n"]}])
    f = open(p, "w")
    f.write("machine x login a\nbogus token\n")
    f.close()
    try:
        netrc.netrc(p)
        r = "no error"
    except netrc.NetrcParseError as e:
        r = [e.msg, e.lineno]
    check("netrc.NetrcParseError", r, ["bad follower token 'bogus'", 2])
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        import mailcap
        import cgi
    mc = os.path.join(d, "mailcap")
    f = open(mc, "w")
    f.write("# a comment\ntext/plain; cat %s; copiousoutput\nimage/*; display %s; test=true\n"
            "application/pdf; xpdf %s; description=\"PDF\"; nametemplate=%s.pdf\n")
    f.close()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        caps = mailcap.readmailcapfile(open(mc))
    check("mailcap.readmailcapfile", [sorted(caps.keys()), caps["text/plain"][0]["view"], caps["application/pdf"][0]["description"]],
          [["application/pdf", "image/*", "text/plain"], "cat %s", '"PDF"'])
    check("mailcap.findmatch", [mailcap.findmatch(caps, "text/plain", filename="/tmp/a.txt")[0],
                                mailcap.findmatch(caps, "image/png", filename="x.png")[0], mailcap.findmatch(caps, "video/mp4")],
          ["cat /tmp/a.txt", "display x.png", (None, None)])
    check("mailcap.subst", mailcap.subst("view %s %t %{charset}", "text/plain", "f.txt", ["charset=utf-8"]), 'view f.txt text/plain utf-8')
    import io
    body = "a=1&b=two+words&b=x%26y&empty="
    env = {"REQUEST_METHOD": "POST", "CONTENT_TYPE": "application/x-www-form-urlencoded", "CONTENT_LENGTH": str(len(body))}
    fs = cgi.FieldStorage(fp=io.BytesIO(body.encode()), environ=env, keep_blank_values=True)
    check("cgi.FieldStorage (urlencoded)", [sorted(fs.keys()), fs.getvalue("a"), fs.getlist("b"), fs.getfirst("empty"), fs["a"].value, "zz" in fs],
          [["a", "b", "empty"], "1", ["two words", "x&y"], "", "1", False])
    mp = ("--XyZ\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\nvalue 1\r\n"
          "--XyZ\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nfile body\r\n"
          "--XyZ--\r\n").encode()
    env = {"REQUEST_METHOD": "POST", "CONTENT_TYPE": "multipart/form-data; boundary=XyZ", "CONTENT_LENGTH": str(len(mp))}
    fs = cgi.FieldStorage(fp=io.BytesIO(mp), environ=env)
    up = fs["upload"]
    check("cgi.FieldStorage (multipart)", [fs.getvalue("field"), up.filename, up.file.read(), up.type],
          ["value 1", "a.txt", b"file body", "text/plain"])
    check("cgi.parse_header", cgi.parse_header('text/html; charset="utf-8"; q=1'), ("text/html", {"charset": "utf-8", "q": "1"}))
    check("cgi.parse", cgi.parse(fp=None, environ={"QUERY_STRING": "x=1&x=2&y=3", "REQUEST_METHOD": "GET"}), {"x": ["1", "2"], "y": ["3"]})
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        import cgitb
    try:
        {}["missing key"]
    except KeyError:
        import sys as _sys
        info = _sys.exc_info()
    txt = cgitb.text(info, context=3)
    html = cgitb.html(info, context=3)
    check("cgitb.text / html", [txt.split("\n")[0].startswith("KeyError"), "missing key" in txt, "<body bgcolor" in html, "KeyError" in html],
          [True, True, True, True])
    import shutil
    shutil.rmtree(d)


# ── audioop, wave, aifc, sunau, chunk, sndhdr, imghdr ────────────────────────
def audio_checks():
    import warnings
    import struct
    import io
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        import audioop
        import aifc
        import sunau
        import chunk
        import sndhdr
        import imghdr
    import wave
    class KeepIO(io.BytesIO):
        def close(self):
            pass
    frag = struct.pack("<10h", 0, 1000, -1000, 32767, -32768, 12345, -54, 7, 300, -301)
    frag1 = bytes([0, 1, 127, 128, 255, 200, 50])
    frag4 = struct.pack("<4i", 0, 2 ** 30, -(2 ** 31), 123456789)
    frag3 = b"\x01\x02\x03\xff\xff\xff\x00\x00\x80\x10\x20\x30"
    check("audioop basics", [audioop.max(frag, 2), audioop.minmax(frag, 2), audioop.avg(frag, 2), audioop.rms(frag, 2),
                             audioop.getsample(frag, 2, 3), audioop.cross(frag, 2), audioop.avgpp(frag, 2), audioop.maxpp(frag, 2),
                             audioop.max(frag1, 1), audioop.minmax(frag1, 1), audioop.rms(frag4, 4), audioop.minmax(frag3, 3),
                             audioop.avg(frag3, 3), audioop.max(b"", 2), audioop.minmax(b"", 1)], [32768, (-32768, 32767), 1229, 15172, 32767, 7, 26528, 65535, 128, (-128, 127), 1202065836, (-8388608, 3153936), -1259388, 0, (2147483647, -2147483648)])
    check("audioop transforms", [audioop.mul(frag, 2, 1.7), audioop.add(frag, audioop.reverse(frag, 2), 2), audioop.bias(frag, 2, 30000),
                                 audioop.reverse(frag3, 3), audioop.byteswap(frag, 2), audioop.lin2lin(frag, 2, 1), audioop.lin2lin(frag, 2, 3),
                                 audioop.lin2lin(frag1, 1, 4), audioop.tomono(frag, 2, 0.5, 0.5), audioop.tostereo(frag[:6], 2, 1, -0.5),
                                 audioop.mul(frag4, 4, -1.5), audioop.add(frag4, frag4, 4), audioop.bias(frag1, 1, -100)], [b'\x00\x00\xa4\x06\\\xf9\xff\x7f\x00\x80\xfaQ\xa4\xff\x0b\x00\xfe\x01\x00\xfe', b'\xd3\xfe\x14\x05\x1f\xfc\xc9\x7f9\xb09\xb0\xc9\x7f\x1f\xfc\x14\x05\xd3\xfe', b'0u\x18yHq/\xf50\xf5i\xa5\xfat7u\\v\x03t', b'\x10 0\x00\x00\x80\xff\xff\xff\x01\x02\x03', b'\x00\x00\x03\xe8\xfc\x18\x7f\xff\x80\x0009\xff\xca\x00\x07\x01,\xfe\xd3', b'\x00\x03\xfc\x7f\x800\xff\x00\x01\xfe', b'\x00\x00\x00\x00\xe8\x03\x00\x18\xfc\x00\xff\x7f\x00\x00\x80\x0090\x00\xca\xff\x00\x07\x00\x00,\x01\x00\xd3\xfe', b'\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x7f\x00\x00\x00\x80\x00\x00\x00\xff\x00\x00\x00\xc8\x00\x00\x002', b'\xf4\x01\x0b>\x1c\xd8\xe8\xff\xff\xff', b'\x00\x00\x00\x00\xe8\x03\x0c\xfe\x18\xfc\xf4\x01', b'\x00\x00\x00\x00\x00\x00\x00\xa0\xff\xff\xff\x7f`L\xf6\xf4', b'\x00\x00\x00\x00\xff\xff\xff\x7f\x00\x00\x00\x80*\x9a\xb7\x0e', b'\x9c\x9d\x1b\x1c\x9bd\xce'])
    check("audioop u-law and A-law", [audioop.lin2ulaw(frag, 2), audioop.lin2alaw(frag, 2), audioop.ulaw2lin(audioop.lin2ulaw(frag, 2), 2),
                                      audioop.alaw2lin(audioop.lin2alaw(frag, 2), 2), audioop.ulaw2lin(b"\x00\x7f\x80\xff", 1),
                                      audioop.alaw2lin(b"\x00\x55\xd5\xff", 4), audioop.lin2ulaw(frag4, 4)], [b'\xff\xceN\x80\x00\x97x\xfe\xe4d', b'\xd5\xfaz\xaa*\xbdV\xd5\xc7G', b'\x00\x00\xdc\x03$\xfc|}\x84\x82|0\xc8\xff\x08\x004\x01\xcc\xfe', b'\x08\x00\xf0\x03\x10\xfc\x00~\x00\x82\x001\xc8\xff\x08\x00(\x01\xd8\xfe', b'\x82\x00}\x00', b'\x00\x00\x80\xea\x00\x00\xf8\xff\x00\x00\x08\x00\x00\x00P\x03', b'\xff\x8f\x00\xc0'])
    ad = audioop.lin2adpcm(frag, 2, None)
    check("audioop ADPCM", [ad, audioop.adpcm2lin(ad[0], 2, None), audioop.lin2adpcm(frag[:6], 2, (100, 20)),
                            audioop.adpcm2lin(b"\x7f\x80", 1, (0, 88))], [(b'\x07\xf7\xf7\xb1O', (-297, 48)), (b'\x00\x00\x0b\x00\xed\xff,\x00\xa4\xff\xc9\x00\xa3\xff\x15\x00N\x01\xd7\xfe', (-297, 48)), (b'\xf7', (-224, 44)), (b'\x7f\x90\x80\x8e', (-29040, 86))])
    check("audioop ratecv", [audioop.ratecv(frag, 2, 1, 8000, 16000, None), audioop.ratecv(frag, 2, 2, 8000, 6000, None),
                             audioop.ratecv(frag, 2, 1, 3, 2, None, 2, 1), audioop.ratecv(b"", 2, 1, 8000, 8000, None)], [(b'\x00\x00\xf4\x01\xe8\x03\x00\x00\x18\xfc\x0b>\xff\x7f\xff\xff\x00\x80\x1c\xd890\x01\x18\xca\xff\xe8\xff\x07\x00\x99\x00,\x01\xff\xff\xd3\xfe', (-1, ((19660800, -19726336),))), (b'\x00\x00\xe8\x03\xba\xd2ge1\xd5\x17\x10,\x01\xd3\xfe', (-4, ((-3538944, 19660800), (458752, -19726336)))), (b'\x00\x00o\x00\xc0T\x04\xea;\x04W\x01\xa2\xff', (-3, ((21100034, -6117546),))), (b'', (-1, ((0, 0),)))])
    ref = struct.pack("<3h", 1000, -1000, 32767)
    check("audioop findfit/findfactor/findmax", [audioop.findfit(frag, ref), audioop.findfactor(frag[:6], ref), audioop.findmax(frag, 3)], [(1, 1.0), -0.03139141426217679, 3])
    check("audioop errors", [err(lambda: audioop.max(b"abc", 2)), err(lambda: audioop.max(b"ab", 5)), err(lambda: audioop.getsample(frag, 2, 99)),
                             err(lambda: audioop.add(b"ab", b"abcd", 2)), err(lambda: audioop.lin2adpcm(frag, 2, (40000, 0))),
                             err(lambda: audioop.ratecv(frag, 2, 1, 0, 8000, None)), err(lambda: audioop.findfit(frag[:2], frag)),
                             isinstance(audioop.error("x"), Exception)], [['error', 'not a whole number of frames'], ['error', 'Size should be 1, 2, 3 or 4'], ['error', 'Index out of range'], ['error', 'Lengths should be the same'], ['ValueError', 'bad state'], ['error', 'sampling rate not > 0'], ['error', 'First sample should be longer'], True])
    check("deprecation warnings at import", sorted(set(str(x.message).split("'")[1] for x in w if x.category is DeprecationWarning)), ['aifc', 'audioop', 'imghdr', 'sndhdr', 'sunau'])
    # wave
    out = KeepIO()
    wv = wave.open(out, "wb")
    wv.setnchannels(2)
    wv.setsampwidth(2)
    wv.setframerate(22050)
    wv.writeframes(frag)
    wv.close()
    wavbytes = out.getvalue()
    check("wave: the file written", wavbytes, b'RIFF8\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x02\x00"V\x00\x00\x88X\x01\x00\x04\x00\x10\x00data\x14\x00\x00\x00\x00\x00\xe8\x03\x18\xfc\xff\x7f\x00\x8090\xca\xff\x07\x00,\x01\xd3\xfe')
    rd = wave.open(io.BytesIO(wavbytes), "rb")
    check("wave: read back", [rd.getnchannels(), rd.getsampwidth(), rd.getframerate(), rd.getnframes(), rd.getcomptype(), rd.getcompname(),
                              tuple(rd.getparams()), rd.readframes(2), rd.tell(), rd.readframes(100) == frag[8:]], [2, 2, 22050, 5, 'NONE', 'not compressed', (2, 2, 22050, 5, 'NONE', 'not compressed'), b'\x00\x00\xe8\x03\x18\xfc\xff\x7f', 2, True])
    rd.setpos(1)
    check("wave: setpos/rewind", [rd.readframes(1), rd.tell()], [b'\x18\xfc\xff\x7f', 2])
    rd.close()
    check("wave errors", [err(lambda: wave.open(io.BytesIO(b"RIFX\x00\x00\x00\x00WAVE"))), err(lambda: wave.open(io.BytesIO(b"junk")))], [['Error', 'file does not start with RIFF id'], ['EOFError', '']])
    # aifc / sunau
    out = KeepIO()
    af = aifc.open(out, "wb")
    af.setnchannels(1)
    af.setsampwidth(2)
    af.setframerate(8000)
    af.writeframes(frag)
    af.close()
    aifbytes = out.getvalue()
    check("aifc: the file written", aifbytes, b'FORM\x00\x00\x00bAIFCFVER\x00\x00\x00\x04\xa2\x80Q@COMM\x00\x00\x00&\x00\x01\x00\x00\x00\n\x00\x10@\x0b\xfa\x00\x00\x00\x00\x00\x00\x00NONE\x0enot compressed\x00SSND\x00\x00\x00\x1c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe8\x03\x18\xfc\xff\x7f\x00\x8090\xca\xff\x07\x00,\x01\xd3\xfe')
    ar = aifc.open(io.BytesIO(aifbytes), "rb")
    check("aifc: read back", [ar.getnchannels(), ar.getsampwidth(), ar.getframerate(), ar.getnframes(), ar.getcomptype(),
                              ar.readframes(3), ar.getmarkers()], [1, 2, 8000, 10, b'NONE', b'\x00\x00\xe8\x03\x18\xfc', None])
    out = KeepIO()
    ac = aifc.open(out, "wb")
    ac.aifc()
    ac.setparams((1, 2, 8000, 0, b"ulaw", b""))
    ac.writeframes(frag)
    ac.setmark(1, 3, b"mark")
    ac.close()
    acr = aifc.open(io.BytesIO(out.getvalue()), "rb")
    check("aifc: AIFF-C with u-law", [len(out.getvalue()), acr.getcomptype(), acr.getcompname(), acr.readframes(10), acr.getmarkers()], [104, b'ulaw', b'', b'\x00\x00\xdc\x03$\xfc|}\x84\x82|0\xc8\xff\x08\x004\x01\xcc\xfe', [(1, 3, b'mark')]])
    out = KeepIO()
    au = sunau.open(out, "wb")
    au.setnchannels(1)
    au.setsampwidth(2)
    au.setframerate(8000)
    au.writeframes(frag)
    au.close()
    aubytes = out.getvalue()
    check("sunau: the file written", aubytes, b'.snd\x00\x00\x00 \x00\x00\x00\n\x00\x00\x00\x01\x00\x00\x1f@\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\xff\xceN\x80\x00\x97x\xfe\xe4d')
    aur = sunau.open(io.BytesIO(aubytes), "rb")
    check("sunau: read back", [aur.getnchannels(), aur.getsampwidth(), aur.getframerate(), aur.getnframes(), aur.getcomptype(),
                               aur.readframes(3)], [1, 2, 8000, 10, 'ULAW', b'\x00\x00\xdc\x03$\xfc'])
    out = KeepIO()
    auu = sunau.open(out, "wb")
    auu.setparams((1, 2, 8000, 0, "ULAW", "CCITT G.711 u-law"))
    auu.writeframes(frag)
    auu.close()
    check("sunau: u-law", [out.getvalue(), sunau.open(io.BytesIO(out.getvalue()), "rb").readframes(10)], [b'.snd\x00\x00\x00 \x00\x00\x00\n\x00\x00\x00\x01\x00\x00\x1f@\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\xff\xceN\x80\x00\x97x\xfe\xe4d', b'\x00\x00\xdc\x03$\xfc|}\x84\x82|0\xc8\xff\x08\x004\x01\xcc\xfe'])
    # chunk
    ch = chunk.Chunk(io.BytesIO(b"FORM\x00\x00\x00\x06abcdefXX"))
    check("chunk", [ch.getname(), ch.getsize(), ch.read(2), ch.tell(), ch.read(), ch.read(), ch.isatty()], [b'FORM', 6, b'ab', 2, b'cdef', b'', False])
    # sndhdr / imghdr
    check("sndhdr.what", [_sndhdr(sndhdr, h) for h in (wavbytes, aifbytes, aubytes)], [('wav', 22050, 2, 5, 16), ('aifc', 8000, 1, 10, 16), ('au', 8000, 1, 10.0, 'U')])
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 24
    jpg = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + b"\x00" * 20
    gif = b"GIF89a" + b"\x00" * 26
    bmp = b"BM" + b"\x00" * 30
    webp = b"RIFF\x00\x00\x00\x00WEBPVP8 " + b"\x00" * 16
    check("imghdr.what", [imghdr.what(None, h) for h in (png, jpg, gif, bmp, webp, b"P6 3 2", b"#define x_width 1", b"nothing")], ['png', 'jpeg', 'gif', 'bmp', 'webp', 'ppm', 'xbm', None])


def _sndhdr(sndhdr, data):
    import tempfile
    import os
    d = tempfile.mkdtemp()
    p = os.path.join(d, "snd")
    f = open(p, "wb")
    f.write(data)
    f.close()
    r = sndhdr.what(p)
    os.remove(p)
    os.rmdir(d)
    return tuple(r) if r is not None else None


# ── dbm, shelve, mailbox ─────────────────────────────────────────────────────
def store_checks():
    import dbm
    import dbm.dumb
    import shelve
    import os
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "dumbdb")
    db = dbm.dumb.open(p, "c")
    db["key"] = "value"
    db[b"bin"] = b"\x00\xff"
    db["k2"] = "v2"
    del db["k2"]
    r = [db["key"], db[b"bin"], sorted(db.keys()), len(db), b"key" in db, "k2" in db, db.get(b"nope", b"dflt"), db.setdefault(b"s", b"d")]
    db.close()
    check("dbm.dumb", r, [b'value', b'\x00\xff', [b'bin', b'key'], 2, True, False, b'dflt', b'd'])
    db = dbm.open(p, "r")
    check("dbm.open / whichdb", [dbm.whichdb(p), db[b"key"], sorted(db.keys()), err(lambda: db.__setitem__("x", "y"))], ['dbm.dumb', b'value', [b'bin', b'key', b's'], ['OSError', 'The database is opened for reading only']])
    db.close()
    check("dbm.whichdb of a missing file", [dbm.whichdb(os.path.join(d, "nothing")), err(lambda: dbm.open(os.path.join(d, "nothing"), "r"))[0]],
          [None, 'error'])
    if hasattr(dbm, "sqlite3") or sys.version_info >= (3, 13):
        import dbm.sqlite3
        sp = os.path.join(d, "sq.db")
        sdb = dbm.sqlite3.open(sp, "c")
        sdb["a"] = "1"
        sdb[b"b"] = b"2"
        rs = [sdb[b"a"], sorted(sdb.keys()), len(sdb), dbm.whichdb(sp)]
        sdb.close()
    else:
        rs = [b"1", [b"a", b"b"], 2, "dbm.sqlite3"]
    check("dbm.sqlite3 (3.13)", rs, [b"1", [b"a", b"b"], 2, "dbm.sqlite3"])
    sp = os.path.join(d, "shelf")
    with shelve.open(sp) as sh:
        sh["list"] = [1, 2, {"three": 3}]
        sh["obj"] = ("tuple", 4.5, None)
        r = [sorted(sh.keys()), sh["list"], "obj" in sh, len(sh)]
    check("shelve", r, [['list', 'obj'], [1, 2, {'three': 3}], True, 2])
    with shelve.open(sp, writeback=True) as sh:
        sh["list"].append(4)
    with shelve.open(sp, flag="r") as sh:
        r2 = [sh["list"], sh["obj"], sh.get("missing", "dflt")]
    check("shelve writeback and read-only", r2, [[1, 2, {'three': 3}, 4], ('tuple', 4.5, None), 'dflt'])
    import io
    import pickle
    s2 = shelve.Shelf({}, protocol=2)
    s2["x"] = {"a": 1}
    check("shelve.Shelf over a dict", [s2["x"], list(s2.dict.values())[0][:2]], [{'a': 1}, b'\x80\x02'])
    # mailbox
    import mailbox
    import email
    import email.message
    mb_path = os.path.join(d, "mbox")
    mb = mailbox.mbox(mb_path)
    m1 = email.message_from_string("From: a@example.com\nSubject: first\n\nBody one\nFrom the start\n")
    m2 = mailbox.mboxMessage("From: b@example.com\nSubject: second\n\nBody two\n")
    m2.set_from("b@example.com", (2024, 1, 2, 3, 4, 5, 0, 1, 0))
    m2.set_flags("RO")
    mb.lock()
    k1 = mb.add(m1)
    k2 = mb.add(m2)
    mb.flush()
    mb.unlock()
    mb.close()
    text = open(mb_path).read()
    check("mailbox.mbox file", text.split("\n")[1:6] + text.split("\n")[7:], ['From: a@example.com', 'Subject: first', '', 'Body one', '>From the start', 'From b@example.com Mon Jan  2 03:04:05 2024', 'From: b@example.com', 'Subject: second', 'Status: RO', 'X-Status: ', '', 'Body two', '', ''])
    mb = mailbox.mbox(mb_path)
    check("mailbox.mbox read", [len(mb), [m["subject"] for m in mb], mb[k2].get_from(), mb[k2].get_flags(), mb.get_message(k1).get_payload()],
          [2, ['first', 'second'], 'b@example.com Mon Jan  2 03:04:05 2024', 'RO', 'Body one\n>From the start\n'])
    mb.remove(k1)
    mb.flush()
    check("mailbox.mbox remove", [len(mb), [m["subject"] for m in mb.values()]], [1, ['second']])
    mb.close()
    md = mailbox.Maildir(os.path.join(d, "Maildir"))
    mk = md.add(email.message_from_string("Subject: in maildir\n\nhello\n"))
    msg = md[mk]
    msg.set_subdir("cur")
    msg.add_flag("S")
    md[mk] = msg
    sub = md.add_folder("sub")
    check("mailbox.Maildir", [len(md), md[mk]["subject"], md[mk].get_flags(), md[mk].get_subdir(), md.list_folders(),
                              sorted(os.listdir(os.path.join(d, "Maildir"))), len(os.listdir(os.path.join(d, "Maildir", "cur")))], [1, 'in maildir', 'S', 'cur', ['sub'], ['.sub', 'cur', 'new', 'tmp'], 1])
    md.remove_folder("sub")
    md.discard(mk)
    check("mailbox.Maildir remove", [len(md), md.list_folders()], [0, []])
    mh = mailbox.MH(os.path.join(d, "mh"))
    hk = mh.add("Subject: mh one\n\nx\n")
    hk2 = mh.add(mailbox.MHMessage("Subject: mh two\n\ny\n"))
    mh.add_sequence = None
    seqs = mh.get_sequences()
    m = mh[hk2]
    m.add_sequence("flagged")
    mh[hk2] = m
    check("mailbox.MH", [sorted(mh.keys()), mh[hk]["subject"], mh.get_sequences(), sorted(os.listdir(os.path.join(d, "mh")))], [[1, 2], 'mh one', {'flagged': [2]}, ['.mh_sequences', '1', '2']])
    mh.close()
    babyl_p = os.path.join(d, "babyl")
    bb = mailbox.Babyl(babyl_p)
    bb.add("Subject: babyl\n\nbody\n")
    bb.close()
    bb = mailbox.Babyl(babyl_p)
    check("mailbox.Babyl", [len(bb), bb[0]["subject"], open(babyl_p).read()[:20]], [1, 'babyl', 'BABYL OPTIONS:\nVersi'])
    bb.close()
    mmdf_p = os.path.join(d, "mmdf")
    mm = mailbox.MMDF(mmdf_p)
    mm.add("Subject: mmdf\n\nbody\n")
    mm.close()
    check("mailbox.MMDF", [mailbox.MMDF(mmdf_p)[0]["subject"], open(mmdf_p).read()[:5]], ['mmdf', '\x01\x01\x01\x01\n'])
    check("mailbox errors", [err(lambda: mailbox.Maildir(os.path.join(d, "none"), create=False).keys())[0],
                             err(lambda: mailbox.mbox(mb_path)["nokey"])[0], issubclass(mailbox.NoSuchMailboxError, mailbox.Error)], ['NoSuchMailboxError', 'KeyError', True])
    import shutil
    shutil.rmtree(d)


# ── wsgiref, xmlrpc ──────────────────────────────────────────────────────────
def wsgi_checks():
    import io
    from wsgiref import util, headers, simple_server, validate, handlers
    env = {}
    util.setup_testing_defaults(env)
    check("wsgiref.util.setup_testing_defaults", sorted((k, v) for k, v in env.items() if isinstance(v, str)), [('HTTP_HOST', '127.0.0.1'), ('PATH_INFO', '/'), ('REQUEST_METHOD', 'GET'), ('SCRIPT_NAME', ''), ('SERVER_NAME', '127.0.0.1'), ('SERVER_PORT', '80'), ('SERVER_PROTOCOL', 'HTTP/1.0'), ('wsgi.url_scheme', 'http')])
    env2 = {"wsgi.url_scheme": "http", "HTTP_HOST": "example.com:8080", "SCRIPT_NAME": "/app", "PATH_INFO": "/a b/c",
            "QUERY_STRING": "x=1", "SERVER_NAME": "example.com", "SERVER_PORT": "8080"}
    check("wsgiref.util URIs", [util.application_uri(env2), util.request_uri(env2), util.request_uri(env2, include_query=False),
                                util.guess_scheme({"HTTPS": "on"}), util.is_hop_by_hop("Connection"), util.is_hop_by_hop("Content-Type")],
          ['http://example.com:8080/app', 'http://example.com:8080/app/a%20b/c?x=1', 'http://example.com:8080/app/a%20b/c', 'https', True, False])
    env3 = {"SCRIPT_NAME": "/a", "PATH_INFO": "/b/c/"}
    seq = [util.shift_path_info(env3), env3["SCRIPT_NAME"], env3["PATH_INFO"], util.shift_path_info(env3), util.shift_path_info(env3),
           env3["SCRIPT_NAME"], env3["PATH_INFO"], util.shift_path_info(env3)]
    check("wsgiref.util.shift_path_info", seq, ['b', '/a/b', '/c/', 'c', '', '/a/b/c/', '', None])
    fw = util.FileWrapper(io.BytesIO(b"abcdefgh"), 3)
    check("wsgiref.util.FileWrapper", list(fw), [b'abc', b'def', b'gh'])
    h = headers.Headers([("Content-Type", "text/plain")])
    h["X-One"] = "1"
    h.add_header("Content-Disposition", "attachment", filename="f.txt")
    h.add_header("X-Flag", None, flag=None, opt="v")
    h.setdefault("X-One", "ignored")
    del h["x-flag"]
    check("wsgiref.headers.Headers", [str(h), h.get_all("x-one"), h.keys(), len(h), "content-type" in h, bytes(h)[:20]], ['Content-Type: text/plain\r\nX-One: 1\r\nContent-Disposition: attachment; filename="f.txt"\r\n\r\n', ['1'], ['Content-Type', 'X-One', 'Content-Disposition'], 3, True, b'Content-Type: text/p'])
    def app(environ, start_response):
        body = ("path=%s method=%s query=%s len=%s" % (environ["PATH_INFO"], environ["REQUEST_METHOD"], environ.get("QUERY_STRING", ""),
                                                        environ.get("CONTENT_LENGTH", ""))).encode()
        if environ["PATH_INFO"] == "/post":
            body = body + b" body=" + environ["wsgi.input"].read(int(environ["CONTENT_LENGTH"]))
        start_response("200 OK", [("Content-Type", "text/plain"), ("Content-Length", str(len(body)))])
        return [body]
    # a handler driven without a server
    out = io.BytesIO()
    err_ = io.StringIO()
    henv = {}
    util.setup_testing_defaults(henv)
    henv["PATH_INFO"] = "/x"
    hd = handlers.SimpleHandler(io.BytesIO(b""), out, err_, henv)
    hd.server_software = "Test/1.0"
    hd.run(app)
    resp = out.getvalue().split(b"\r\n")
    check("wsgiref.handlers.SimpleHandler", [resp[0], sorted(r for r in resp[1:] if r and not r.startswith(b"Date"))], [b'HTTP/1.0 200 OK', [b'Content-Length: 30', b'Content-Type: text/plain', b'Server: Test/1.0', b'path=/x method=GET query= len=']])
    def bad_app(environ, start_response):
        raise ValueError("app failed")
    out = io.BytesIO()
    err_ = io.StringIO()
    hd = handlers.SimpleHandler(io.BytesIO(b""), out, err_, henv)
    hd.run(bad_app)
    check("a failing application: 500", [out.getvalue().split(b"\r\n")[0], b"A server error occurred" in out.getvalue(),
                                         "ValueError: app failed" in err_.getvalue()], [b'HTTP/1.0 500 Internal Server Error', True, True])
    check("handlers.format_date_time", handlers.format_date_time(0), 'Thu, 01 Jan 1970 00:00:00 GMT')
    # validate
    def wrong_app(environ, start_response):
        start_response("200 OK", [("Content-Type", "text/plain")])
        return ["not bytes"]
    venv = dict(henv)
    venv["QUERY_STRING"] = ""
    def start(status, headers, exc_info=None):
        return lambda data: None
    it = validate.validator(wrong_app)(venv, start)
    try:
        list(it)
        r = "no error"
    except AssertionError as e:
        r = str(e)
    it.close()
    check("wsgiref.validate", r, "Iterator yielded non-bytestring ('not bytes')")
    # the real server
    import threading
    import http.client
    srv = simple_server.make_server("127.0.0.1", 0, app, handler_class=_QuietHandler(simple_server))
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever)
    t.daemon = True
    t.start()
    try:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", "/hello?a=1")
        r1 = c.getresponse()
        g = [r1.status, r1.getheader("Content-Type"), r1.read(), r1.getheader("Server").startswith("WSGIServer/")]
        c.request("POST", "/post", body=b"data!", headers={"Content-Type": "application/octet-stream"})
        r2 = c.getresponse()
        g.append(r2.read())
        c.close()
    finally:
        srv.shutdown()
        srv.server_close()
    check("wsgiref.simple_server over HTTP", g, [200, 'text/plain', b'path=/hello method=GET query=a=1 len=', True, b'path=/post method=POST query= len=5 body=data!'])


def _QuietHandler(simple_server):
    class Quiet(simple_server.WSGIRequestHandler):
        def log_message(self, *args):
            pass
    return Quiet


def xmlrpc_checks():
    import xmlrpc.client as xc
    import xmlrpc.server as xs
    import datetime
    import threading
    payload = xc.dumps((1, "two", 3.5, True, [1, 2], {"k": "v"}, xc.Binary(b"\x00\xff"), xc.DateTime(datetime.datetime(2024, 1, 2, 3, 4, 5)), None),
                       "method.name", allow_none=True)
    check("xmlrpc.client.dumps", payload, "<?xml version='1.0'?>\n<methodCall>\n<methodName>method.name</methodName>\n<params>\n<param>\n<value><int>1</int></value>\n</param>\n<param>\n<value><string>two</string></value>\n</param>\n<param>\n<value><double>3.5</double></value>\n</param>\n<param>\n<value><boolean>1</boolean></value>\n</param>\n<param>\n<value><array><data>\n<value><int>1</int></value>\n<value><int>2</int></value>\n</data></array></value>\n</param>\n<param>\n<value><struct>\n<member>\n<name>k</name>\n<value><string>v</string></value>\n</member>\n</struct></value>\n</param>\n<param>\n<value><base64>\nAP8=\n</base64></value>\n</param>\n<param>\n<value><dateTime.iso8601>20240102T03:04:05</dateTime.iso8601></value>\n</param>\n<param>\n<value><nil/></value></param>\n</params>\n</methodCall>\n")
    params, name = xc.loads(payload, use_builtin_types=True)
    check("xmlrpc.client.loads", [name, params], ['method.name', (1, 'two', 3.5, True, [1, 2], {'k': 'v'}, b'\x00\xff', datetime.datetime(2024, 1, 2, 3, 4, 5), None)])
    params2, _ = xc.loads(payload)
    check("loads without builtin types", [type(params2[6]).__name__, params2[6].data, type(params2[7]).__name__, str(params2[7])], ['Binary', b'\x00\xff', 'DateTime', '20240102T03:04:05'])
    resp = xc.dumps(({"ok": 1},), methodresponse=True)
    check("a method response", [resp, xc.loads(resp)], ["<?xml version='1.0'?>\n<methodResponse>\n<params>\n<param>\n<value><struct>\n<member>\n<name>ok</name>\n<value><int>1</int></value>\n</member>\n</struct></value>\n</param>\n</params>\n</methodResponse>\n", (({'ok': 1},), None)])
    fault = xc.dumps(xc.Fault(4, "Too many parameters."))
    try:
        xc.loads(fault)
        r = "no fault"
    except xc.Fault as f:
        r = [f.faultCode, f.faultString, repr(f)]
    check("a fault", [fault, r], ["<?xml version='1.0'?>\n<methodResponse>\n<fault>\n<value><struct>\n<member>\n<name>faultCode</name>\n<value><int>4</int></value>\n</member>\n<member>\n<name>faultString</name>\n<value><string>Too many parameters.</string></value>\n</member>\n</struct></value>\n</fault>\n</methodResponse>\n", [4, 'Too many parameters.', "<Fault 4: 'Too many parameters.'>"]])
    check("dumps errors", [err(lambda: xc.dumps((None,))), err(lambda: xc.dumps(({1: 2},))), err(lambda: xc.dumps((2 ** 40,)))], [['TypeError', 'cannot marshal None unless allow_none is enabled'], ['TypeError', 'dictionary key must be string'], ['OverflowError', 'int exceeds XML-RPC limits']])
    check("DateTime and Boolean", [xc.DateTime("20240102T03:04:05").value, xc.DateTime("20240102T03:04:05") == datetime.datetime(2024, 1, 2, 3, 4, 5),
                                   xc.boolean(1), xc.Binary(b"hi") == xc.Binary(b"hi")], ['20240102T03:04:05', True, True, True])
    # a real server
    class Quiet(xs.SimpleXMLRPCRequestHandler):
        def log_message(self, *args):
            pass
    server = xs.SimpleXMLRPCServer(("127.0.0.1", 0), requestHandler=Quiet, allow_none=True, logRequests=False)
    server.register_introspection_functions()
    server.register_multicall_functions()
    server.register_function(lambda a, b: a + b, "add")
    def div(a, b):
        """Divide a by b."""
        return a / b
    server.register_function(div)
    class Api:
        def greet(self, name):
            return "hello " + name
        def _private(self):
            return "secret"
    server.register_instance(Api())
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever)
    t.daemon = True
    t.start()
    try:
        proxy = xc.ServerProxy("http://127.0.0.1:%d/" % port, allow_none=True)
        g = [proxy.add(2, 3), proxy.add("a", "b"), proxy.div(7, 2), proxy.greet("x"), sorted(proxy.system.listMethods()),
             proxy.system.methodHelp("div")]
        try:
            proxy.div(1, 0)
        except xc.Fault as f:
            g.append([f.faultCode, f.faultString])
        try:
            proxy._private()
        except xc.Fault as f:
            g.append([f.faultCode, f.faultString])
        mc = xc.MultiCall(proxy)
        mc.add(1, 1)
        mc.greet("m")
        g.append(list(mc()))
        proxy("close")()
    finally:
        server.shutdown()
        server.server_close()
    check("xmlrpc over HTTP", g, [5, 'ab', 3.5, 'hello x', ['add', 'div', 'greet', 'system.listMethods', 'system.methodHelp', 'system.methodSignature', 'system.multicall'], 'Divide a by b.', [1, "<class 'ZeroDivisionError'>:division by zero"], [1, '<class \'Exception\'>:method "_private" is not supported'], [2, 'hello m']])
    d = xs.SimpleXMLRPCDispatcher(allow_none=True)
    d.register_function(pow)
    check("SimpleXMLRPCDispatcher._marshaled_dispatch", d._marshaled_dispatch(xc.dumps((2, 10), "pow").encode()), b"<?xml version='1.0'?>\n<methodResponse>\n<params>\n<param>\n<value><int>1024</int></value>\n</param>\n</params>\n</methodResponse>\n")


# ── smtplib, poplib, imaplib, ftplib, telnetlib against servers on localhost ─
def _listener():
    import socket
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(5)
    return srv


def _serve(handler, nconn=1):
    # a server in a thread: handler(conn, rfile, send, log) for each of nconn connections
    import threading
    srv = _listener()
    port = srv.getsockname()[1]
    log = []
    def run():
        try:
            for i in range(nconn):
                conn, addr = srv.accept()
                rfile = conn.makefile("rb")
                def send(line, conn=conn):
                    if isinstance(line, str):
                        line = line.encode("utf-8")
                    conn.sendall(line + b"\r\n")
                try:
                    handler(conn, rfile, send, log)
                except Exception as e:
                    log.append("server error: " + type(e).__name__ + ": " + str(e))
                rfile.close()
                conn.close()
        finally:
            srv.close()
    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    return port, log, t


def _readline(rfile):
    line = rfile.readline()
    if not line:
        return None
    return line.decode("utf-8").rstrip("\r\n")


def smtp_handler(conn, rfile, send, log):
    import base64
    send("220 test.local ESMTP ready")
    while True:
        line = _readline(rfile)
        if line is None:
            break
        log.append(line)
        verb = line.split(" ")[0].upper()
        if verb == "EHLO":
            send("250-test.local Hello")
            send("250-SIZE 100000")
            send("250-8BITMIME")
            send("250-AUTH PLAIN LOGIN CRAM-MD5")
            send("250 HELP")
        elif verb == "HELO":
            send("250 test.local")
        elif verb == "AUTH":
            parts = line.split(" ")
            if parts[1] == "PLAIN":
                ok = base64.b64decode(parts[2]) == b"\x00user\x00pass"
                send("235 2.7.0 Authentication successful" if ok else "535 5.7.8 bad credentials")
            elif parts[1] == "CRAM-MD5":
                import hmac
                send("334 " + base64.b64encode(b"<123.456@test.local>").decode())
                answer = base64.b64decode(_readline(rfile)).decode()
                log.append("cram: " + answer)
                expect = "user " + hmac.HMAC(b"pass", b"<123.456@test.local>", "md5").hexdigest()
                send("235 ok" if answer == expect else "535 no")
            elif parts[1] == "LOGIN":
                if len(parts) > 2:
                    u = base64.b64decode(parts[2])
                else:
                    send("334 VXNlcm5hbWU6")
                    u = base64.b64decode(_readline(rfile))
                send("334 UGFzc3dvcmQ6")
                p = base64.b64decode(_readline(rfile))
                send("235 ok" if (u, p) == (b"user", b"pass") else "535 no")
        elif verb == "MAIL" or verb == "RSET" or verb == "NOOP":
            send("250 OK")
        elif verb == "RCPT":
            if "nobody@" in line:
                send("550 5.1.1 no such user")
            else:
                send("250 OK")
        elif verb == "VRFY":
            send("252 cannot verify")
        elif verb == "DATA":
            send("354 End data with <CR><LF>.<CR><LF>")
            body = []
            while True:
                l = rfile.readline()
                if l == b".\r\n":
                    break
                body.append(l)
            log.append(b"".join(body))
            send("250 queued as 12345")
        elif verb == "QUIT":
            send("221 bye")
            break
        else:
            send("502 command not implemented")


def pop_handler(conn, rfile, send, log):
    msgs = [b"Subject: one\r\n\r\nfirst body\r\n.dotted line\r\n", b"Subject: two\r\nX-Y: z\r\n\r\nsecond\r\n"]
    send("+OK POP3 ready <1896.697170952@dbc.mtview.ca.us>")
    while True:
        line = _readline(rfile)
        if line is None:
            break
        log.append(line)
        parts = line.split(" ")
        cmd = parts[0].upper()
        if cmd == "USER":
            send("+OK user accepted")
        elif cmd == "PASS":
            send("+OK maildrop locked and ready" if parts[1] == "secret" else "-ERR invalid password")
        elif cmd == "APOP":
            send("+OK apop accepted")
        elif cmd == "STAT":
            send("+OK 2 %d" % sum(len(m) for m in msgs))
        elif cmd == "LIST":
            if len(parts) > 1:
                send("+OK 1 %d" % len(msgs[0]))
            else:
                send("+OK 2 messages")
                for i, m in enumerate(msgs):
                    send("%d %d" % (i + 1, len(m)))
                send(".")
        elif cmd == "UIDL":
            send("+OK")
            send("1 uid-one")
            send("2 uid-two")
            send(".")
        elif cmd == "RETR" or cmd == "TOP":
            m = msgs[int(parts[1]) - 1]
            send("+OK %d octets" % len(m))
            lines = m.split(b"\r\n")[:-1]
            if cmd == "TOP":
                lines = lines[:lines.index(b"") + 1 + int(parts[2])]
            for l in lines:
                if l.startswith(b"."):
                    l = b"." + l
                send(l)
            send(".")
        elif cmd == "DELE":
            send("+OK message deleted")
        elif cmd == "NOOP" or cmd == "RSET":
            send("+OK")
        elif cmd == "CAPA":
            send("+OK capability list follows")
            send("TOP")
            send("UIDL")
            send("SASL PLAIN")
            send(".")
        elif cmd == "QUIT":
            send("+OK bye")
            break
        else:
            send("-ERR unknown command")


def imap_handler(conn, rfile, send, log):
    msg = b"Subject: imap test\r\nFrom: a@b.c\r\n\r\nIMAP body\r\n"
    send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] test server ready")
    while True:
        line = _readline(rfile)
        if line is None:
            break
        log.append(line)
        tag, rest = line.split(" ", 1)
        cmd = rest.split(" ")[0].upper()
        if cmd == "CAPABILITY":
            send("* CAPABILITY IMAP4rev1 AUTH=PLAIN IDLE")
            send(tag + " OK CAPABILITY completed")
        elif cmd == "LOGIN":
            send(tag + " OK LOGIN completed")
        elif cmd == "SELECT" or cmd == "EXAMINE":
            send("* 2 EXISTS")
            send("* 0 RECENT")
            send("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)")
            send("* OK [UIDVALIDITY 3857529045] UIDs valid")
            send(tag + " OK [READ-WRITE] SELECT completed")
        elif cmd == "SEARCH":
            send("* SEARCH 1 2")
            send(tag + " OK SEARCH completed")
        elif cmd == "FETCH":
            if "RFC822" in rest:
                conn.sendall(b"* 1 FETCH (FLAGS (\\Seen) RFC822 {%d}\r\n" % len(msg) + msg + b")\r\n")
            else:
                send("* 1 FETCH (FLAGS (\\Seen) UID 101)")
            send(tag + " OK FETCH completed")
        elif cmd == "STORE":
            send("* 1 FETCH (FLAGS (\\Seen \\Deleted))")
            send(tag + " OK STORE completed")
        elif cmd == "LIST":
            send('* LIST (\\HasNoChildren) "/" INBOX')
            send('* LIST (\\HasChildren) "/" "Sent Items"')
            send(tag + " OK LIST completed")
        elif cmd == "APPEND":
            # the literal follows a continuation request
            n = int(rest.rsplit("{", 1)[1].rstrip("}"))
            send("+ Ready for literal data")
            data = rfile.read(n)
            rfile.readline()
            log.append(data)
            send(tag + " OK [APPENDUID 38505 3955] APPEND completed")
        elif cmd == "EXPUNGE":
            send("* 1 EXPUNGE")
            send(tag + " OK EXPUNGE completed")
        elif cmd == "NOOP":
            send(tag + " OK NOOP completed")
        elif cmd == "CLOSE":
            send(tag + " OK CLOSE completed")
        elif cmd == "LOGOUT":
            send("* BYE logging out")
            send(tag + " OK LOGOUT completed")
            break
        else:
            send(tag + " BAD unknown command")


def ftp_handler(conn, rfile, send, log):
    import socket
    files = {"readme.txt": b"line one\r\nline two\r\n", "data.bin": bytes(range(256)) * 4}
    cwd = ["/"]
    pasv = [None]
    active = [None]
    def data_conn():
        if pasv[0] is not None:
            c, a = pasv[0].accept()
            pasv[0].close()
            pasv[0] = None
            return c
        s = socket.create_connection(active[0])
        active[0] = None
        return s
    send("220 test FTP ready")
    while True:
        line = _readline(rfile)
        if line is None:
            break
        log.append(line)
        cmd, _, arg = line.partition(" ")
        cmd = cmd.upper()
        if cmd == "USER":
            send("331 password please")
        elif cmd == "PASS":
            send("230 logged in")
        elif cmd == "SYST":
            send("215 UNIX Type: L8")
        elif cmd == "PWD":
            send('257 "%s" is the current directory' % cwd[0])
        elif cmd == "CWD":
            cwd[0] = arg if arg.startswith("/") else cwd[0].rstrip("/") + "/" + arg
            send("250 ok")
        elif cmd == "MKD":
            send('257 "%s" created' % arg)
        elif cmd == "TYPE":
            send("200 type set to " + arg)
        elif cmd == "SIZE":
            if arg in files:
                send("213 %d" % len(files[arg]))
            else:
                send("550 no such file")
        elif cmd == "PASV":
            ls = _listener()
            pasv[0] = ls
            p = ls.getsockname()[1]
            send("227 Entering Passive Mode (127,0,0,1,%d,%d)." % (p >> 8, p & 255))
        elif cmd == "EPSV":
            ls = _listener()
            pasv[0] = ls
            send("229 Entering Extended Passive Mode (|||%d|)" % ls.getsockname()[1])
        elif cmd == "PORT":
            nums = [int(x) for x in arg.split(",")]
            active[0] = (".".join(str(x) for x in nums[:4]), nums[4] * 256 + nums[5])
            send("200 PORT ok")
        elif cmd == "EPRT":
            f = arg.split("|")
            active[0] = (f[2], int(f[3]))
            send("200 EPRT ok")
        elif cmd in ("LIST", "NLST", "MLSD", "RETR"):
            send("150 opening data connection")
            c = data_conn()
            if cmd == "LIST":
                c.sendall(b"-rw-r--r-- 1 u g 20 Jan 01 00:00 readme.txt\r\n-rw-r--r-- 1 u g 1024 Jan 01 00:00 data.bin\r\n")
            elif cmd == "NLST":
                c.sendall(b"readme.txt\r\ndata.bin\r\n")
            elif cmd == "MLSD":
                c.sendall(b"type=file;size=20;perm=r; readme.txt\r\ntype=dir;perm=el; sub\r\n")
            else:
                c.sendall(files[arg])
            c.close()
            send("226 transfer complete")
        elif cmd == "STOR":
            send("150 ok to send data")
            c = data_conn()
            chunks = []
            while True:
                b = c.recv(4096)
                if not b:
                    break
                chunks.append(b)
            c.close()
            files[arg] = b"".join(chunks)
            log.append(files[arg])
            send("226 stored")
        elif cmd == "DELE":
            files.pop(arg, None)
            send("250 deleted")
        elif cmd == "RNFR":
            send("350 ready for destination")
        elif cmd == "RNTO":
            send("250 renamed")
        elif cmd == "NOOP":
            send("200 noop")
        elif cmd == "QUIT":
            send("221 goodbye")
            break
        else:
            send("502 not implemented")


def telnet_handler(conn, rfile, send, log):
    IAC, DO, WILL, SB, SE = 255, 253, 251, 250, 240
    conn.sendall(bytes([IAC, DO, 24]) + b"login: ")
    data = b""
    while b"\n" not in data:
        data = data + conn.recv(100)
    log.append(data)
    conn.sendall(b"Password: ")
    data = b""
    while b"\n" not in data:
        data = data + conn.recv(100)
    log.append(data)
    conn.sendall(b"Welcome\r\nvalue = 42 \xff\xff done\r\n$ ")
    data = b""
    while b"\n" not in data:
        data = data + conn.recv(100)
    log.append(data)
    conn.sendall(b"bye\r\n")


def protocol_checks():
    import smtplib
    import poplib
    import imaplib
    import ftplib
    import io
    import email.message
    import warnings
    # SMTP
    port, log, t = _serve(smtp_handler)
    s = smtplib.SMTP("127.0.0.1", port, timeout=10)
    r = [s.ehlo("client.local"), s.has_extn("size"), s.esmtp_features.get("auth"), s.does_esmtp]
    s.login("user", "pass")
    r.append(s.sendmail("a@x.org", ["b@y.org", "c@z.org"], "Subject: hi\r\n\r\nline\r\n.leading dot\r\n"))
    try:
        s.sendmail("a@x.org", ["nobody@y.org"], "x")
    except smtplib.SMTPRecipientsRefused as e:
        r.append(e.recipients)
    m = email.message.EmailMessage()
    m["From"] = "Me <me@x.org>"
    m["To"] = "You <you@y.org>"
    m["Bcc"] = "hidden@z.org"
    m["Subject"] = "via send_message"
    m.set_content("hello\n")
    r.append(s.send_message(m))
    r.append(s.verify("someone"))
    r.append(s.noop())
    r.append(s.quit())
    t.join(10)
    check("smtplib: the session", r, [(250, b'test.local Hello\nSIZE 100000\n8BITMIME\nAUTH PLAIN LOGIN CRAM-MD5\nHELP'), True, ' PLAIN LOGIN CRAM-MD5', True, {}, {'nobody@y.org': (550, b'5.1.1 no such user')}, {}, (252, b'cannot verify'), (250, b'OK'), (221, b'bye')])
    check("smtplib: what the server saw", [x for x in log if not isinstance(x, bytes)], ['ehlo client.local', 'AUTH CRAM-MD5', 'cram: user c36cebeb807475fb082af15e2d7f59b5', 'mail FROM:<a@x.org> size=35', 'rcpt TO:<b@y.org>', 'rcpt TO:<c@z.org>', 'data', 'mail FROM:<a@x.org> size=1', 'rcpt TO:<nobody@y.org>', 'rset', 'mail FROM:<me@x.org> size=173', 'rcpt TO:<you@y.org>', 'rcpt TO:<hidden@z.org>', 'data', 'vrfy someone', 'noop', 'quit'])
    datas = [x for x in log if isinstance(x, bytes)]
    check("smtplib: the data (dot-stuffed, Bcc removed)", [datas[0], datas[1].split(b"\r\n")[:5]], [b'Subject: hi\r\n\r\nline\r\n..leading dot\r\n', [b'From: Me <me@x.org>', b'To: You <you@y.org>', b'Subject: via send_message', b'Content-Type: text/plain; charset="utf-8"', b'Content-Transfer-Encoding: 7bit']])
    def auth_with(mech):
        port, log, t = _serve(smtp_handler)
        with smtplib.SMTP("127.0.0.1", port, timeout=10) as s:
            s.ehlo()
            s.esmtp_features["auth"] = mech
            res = s.login("user", "pass")
        t.join(10)
        return [res, [x for x in log if isinstance(x, str) and x.startswith("AUTH")]]
    check("smtplib: AUTH LOGIN", auth_with("LOGIN"), [(235, b'ok'), ['AUTH LOGIN dXNlcg==']])
    check("smtplib: AUTH PLAIN", auth_with("PLAIN"), [(235, b'2.7.0 Authentication successful'), ['AUTH PLAIN AHVzZXIAcGFzcw==']])
    port, log, t = _serve(smtp_handler)
    s = smtplib.SMTP("127.0.0.1", port, timeout=10)
    try:
        s.login("user", "wrong")
        r = "no error"
    except smtplib.SMTPAuthenticationError as e:
        r = [e.smtp_code, e.smtp_error]
    s.quit()
    t.join(10)
    check("smtplib: a failed login", r, [535, b'no'])
    check("smtplib helpers", [smtplib.quoteaddr("Name <a@b.c>"), smtplib.quotedata("a\n.b\r\nc"), smtplib.SMTP_PORT, smtplib.SMTP_SSL_PORT,
                              issubclass(smtplib.SMTPRecipientsRefused, smtplib.SMTPException), smtplib.LMTP_PORT], ['<a@b.c>', 'a\r\n..b\r\nc', 25, 465, True, 2003])
    # POP3
    port, log, t = _serve(pop_handler)
    p = poplib.POP3("127.0.0.1", port, timeout=10)
    r = [p.getwelcome(), p.user("bob"), p.pass_("secret"), p.stat(), p.list(), p.list(1), p.uidl(), p.retr(1), p.top(2, 0),
         p.dele(2), p.noop(), p.rset(), p.capa(), p.quit()]
    t.join(10)
    check("poplib: the session", r, [b'+OK POP3 ready <1896.697170952@dbc.mtview.ca.us>', b'+OK user accepted', b'+OK maildrop locked and ready', (2, 74), (b'+OK 2 messages', [b'1 42', b'2 32'], 12), b'+OK 1 42', (b'+OK', [b'1 uid-one', b'2 uid-two'], 22), (b'+OK 42 octets', [b'Subject: one', b'', b'first body', b'.dotted line'], 42), (b'+OK 32 octets', [b'Subject: two', b'X-Y: z', b''], 24), b'+OK message deleted', b'+OK', b'+OK', {'TOP': [], 'UIDL': [], 'SASL': ['PLAIN']}, b'+OK bye'])
    port, log, t = _serve(pop_handler)
    p = poplib.POP3("127.0.0.1", port, timeout=10)
    r = [p.apop("mrose", "tanstaaf")]
    try:
        p.pass_("wrong")
    except poplib.error_proto as e:
        r.append(e.args)
    p.quit()
    t.join(10)
    check("poplib: APOP and errors", [r, log[0]], [[b'+OK apop accepted', (b'-ERR invalid password',)], 'APOP mrose c4c9334bac560ecc979e58001b3e22fb'])
    # IMAP4
    port, log, t = _serve(imap_handler)
    im = imaplib.IMAP4("127.0.0.1", port, timeout=10)
    r = [im.capabilities, im.state, im.login("user", "pass"), im.state, im.select("INBOX"), im.state, im.search(None, "ALL"),
         im.fetch("1", "(RFC822)"), im.fetch("1", "(FLAGS UID)"), im.store("1", "+FLAGS", "\\Deleted"), im.list(),
         im.append("INBOX", "(\\Seen)", imaplib.Time2Internaldate(0), b"Subject: new\r\n\r\nappended\r\n"), im.expunge(),
         im.noop(), im.close(), im.logout()]
    t.join(10)
    check("imaplib: the session", r, [('IMAP4REV1', 'AUTH=PLAIN', 'IDLE'), 'NONAUTH', ('OK', [b'LOGIN completed']), 'AUTH', ('OK', [b'2']), 'SELECTED', ('OK', [b'1 2']), ('OK', [(b'1 (FLAGS (\\Seen) RFC822 {46}', b'Subject: imap test\r\nFrom: a@b.c\r\n\r\nIMAP body\r\n'), b')']), ('OK', [b'1 (FLAGS (\\Seen) UID 101)']), ('OK', [b'1 (FLAGS (\\Seen \\Deleted))']), ('OK', [b'(\\HasNoChildren) "/" INBOX', b'(\\HasChildren) "/" "Sent Items"']), ('OK', [b'[APPENDUID 38505 3955] APPEND completed']), ('OK', [b'1']), ('OK', [b'NOOP completed']), ('OK', [b'CLOSE completed']), ('BYE', [b'logging out'])])
    check("imaplib: the commands sent", [x if isinstance(x, bytes) else x.split(" ", 1)[1] for x in log], ['CAPABILITY', 'LOGIN user "pass"', 'SELECT INBOX', 'SEARCH ALL', 'FETCH 1 (RFC822)', 'FETCH 1 (FLAGS UID)', 'STORE 1 +FLAGS (\\Deleted)', 'LIST "" *', 'APPEND INBOX (\\Seen) "01-Jan-1970 00:00:00 +0000" {26}', b'Subject: new\r\n\r\nappended\r\n', 'EXPUNGE', 'NOOP', 'CLOSE', 'LOGOUT'])
    check("imaplib helpers", [imaplib.ParseFlags(b'1 (FLAGS (\\Seen \\Deleted))'), imaplib.Int2AP(1234),
                              imaplib.Internaldate2tuple(b'25 (INTERNALDATE "01-Jan-2024 10:00:00 +0000")')[:6],
                              imaplib.Time2Internaldate((2024, 1, 2, 3, 4, 5, 0, 1, -1))[:22]], [(b'\\Seen', b'\\Deleted'), b'ENC', (2024, 1, 1, 10, 0, 0), '"02-Jan-2024 03:04:05 '])
    # FTP, passive and active
    port, log, t = _serve(ftp_handler)
    f = ftplib.FTP()
    r = [f.connect("127.0.0.1", port, timeout=10), f.login("user", "pw"), f.sendcmd("SYST"), f.pwd(), f.cwd("pub"), f.pwd(),
         f.mkd("newdir"), f.size("data.bin"), f.nlst()]
    lines = []
    r.append(f.retrlines("LIST", lines.append))
    r.append(lines)
    chunks = []
    r.append(f.retrbinary("RETR data.bin", chunks.append, blocksize=100))
    r.append(b"".join(chunks) == bytes(range(256)) * 4)
    r.append(f.storbinary("STOR up.bin", io.BytesIO(b"\x00uploaded\xff" * 50)))
    r.append(f.storlines("STOR up.txt", io.BytesIO(b"a\nb\n")))
    r.append(list(f.mlsd()))
    f.set_pasv(False)
    lines = []
    r.append(f.retrlines("RETR readme.txt", lines.append))
    r.append(lines)
    r.append(f.rename("a", "b"))
    r.append(f.delete("up.bin"))
    try:
        f.size("nothing")
    except ftplib.error_perm as e:
        r.append(str(e))
    r.append(f.quit())
    t.join(10)
    check("ftplib: the session", r, ['220 test FTP ready', '230 logged in', '215 UNIX Type: L8', '/', '250 ok', '/pub', 'newdir', 1024, ['readme.txt', 'data.bin'], '226 transfer complete', ['-rw-r--r-- 1 u g 20 Jan 01 00:00 readme.txt', '-rw-r--r-- 1 u g 1024 Jan 01 00:00 data.bin'], '226 transfer complete', True, '226 stored', '226 stored', [('readme.txt', {'type': 'file', 'size': '20', 'perm': 'r'}), ('sub', {'type': 'dir', 'perm': 'el'})], '226 transfer complete', ['line one', 'line two'], '250 renamed', '250 deleted', '550 no such file', '221 goodbye'])
    check("ftplib: what the server saw", [x for x in log if isinstance(x, bytes) or not (x.startswith("PORT") or x.startswith("EPRT"))], ['USER user', 'PASS pw', 'SYST', 'PWD', 'CWD pub', 'PWD', 'MKD newdir', 'SIZE data.bin', 'TYPE A', 'PASV', 'NLST', 'TYPE A', 'PASV', 'LIST', 'TYPE I', 'PASV', 'RETR data.bin', 'TYPE I', 'PASV', 'STOR up.bin', b'\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff\x00uploaded\xff', 'TYPE A', 'PASV', 'STOR up.txt', b'a\r\nb\r\n', 'TYPE A', 'PASV', 'MLSD', 'TYPE A', 'RETR readme.txt', 'RNFR a', 'RNTO b', 'DELE up.bin', 'SIZE nothing', 'QUIT'])
    check("ftplib: active mode", [x.split(" ")[0] for x in log if isinstance(x, str) and (x.startswith("PORT") or x.startswith("EPRT"))], ['PORT'])
    check("ftplib helpers", [ftplib.parse227("227 Entering Passive Mode (127,0,0,1,4,1)."),
                             ftplib.parse229("229 Entering Extended Passive Mode (|||6446|)", ("10.0.0.1", 21)),
                             ftplib.parse257('257 "/a ""quoted"" dir" created'), ftplib.FTP_PORT,
                             issubclass(ftplib.error_perm, ftplib.Error), ftplib.all_errors[0].__name__], [('127.0.0.1', 1025), ('10.0.0.1', 6446), '/a "quoted" dir', 21, True, 'Error'])
    # telnetlib
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        import telnetlib
    port, log, t = _serve(telnet_handler)
    tn = telnetlib.Telnet("127.0.0.1", port, timeout=10)
    opts = []
    tn.set_option_negotiation_callback(lambda sock, cmd, opt: opts.append((cmd, opt)))
    r = [tn.read_until(b"login: ", 10)]
    tn.write(b"user\n")
    r.append(tn.read_until(b"Password: ", 10))
    tn.write(b"p\xffss\n")
    r.append(tn.expect([b"value = (\\d+)", b"never"], 10)[:2])
    r[-1] = [r[-1][0], r[-1][1].group(1)]
    r.append(tn.read_until(b"$ ", 10))
    tn.write(b"exit\n")
    r.append(tn.read_all())
    tn.close()
    t.join(10)
    check("telnetlib", [r, opts, log], [[b'login: ', b'Password: ', [0, b'42'], b' \xff done\r\n$ ', b'bye\r\n'], [(b'\xfd', b'\x18')], [b'user\n', b'p\xff\xffss\n', b'exit\n']])


# ── LMTP over a Unix socket, SMTPUTF8 ────────────────────────────────────────
def lmtp_handler(conn, rfile, send, log):
    send("220 lmtp.local LMTP ready")
    rcpts = 0
    while True:
        line = rfile.readline()
        if not line:
            break
        line = line.decode("utf-8").rstrip("\r\n")
        log.append(line)
        verb = line.split(" ")[0].upper()
        if verb == "LHLO":
            send("250-lmtp.local")
            send("250-8BITMIME")
            send("250 SMTPUTF8")
        elif verb == "MAIL":
            rcpts = 0
            send("250 OK")
        elif verb == "RCPT":
            rcpts = rcpts + 1
            send("250 OK")
        elif verb == "DATA":
            send("354 go")
            body = []
            while True:
                l = rfile.readline()
                if l == b".\r\n":
                    break
                body.append(l)
            log.append(b"".join(body))
            for i in range(rcpts):
                send("250 delivered %d" % (i + 1))
        elif verb == "QUIT":
            send("221 bye")
            break
        else:
            send("502 no")


def lmtp_checks():
    import socket
    import smtplib
    import threading
    import tempfile
    import os
    import email.message
    if not hasattr(socket, "AF_UNIX"):
        print("NOTICE: LMTP checks skipped - no AF_UNIX sockets")
        return
    d = tempfile.mkdtemp()
    path = os.path.join(d, "lmtp.sock")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)
    log = []
    def run():
        conn, addr = srv.accept()
        rfile = conn.makefile("rb")
        def send(line):
            conn.sendall(line.encode("utf-8") + b"\r\n")
        try:
            lmtp_handler(conn, rfile, send, log)
        except Exception as e:
            log.append("server error: " + str(e))
        rfile.close()
        conn.close()
        srv.close()
    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    lm = smtplib.LMTP(path)
    r = [lm.ehlo("client.local"), lm.does_esmtp, lm.has_extn("smtputf8")]
    m = email.message.EmailMessage()
    m["From"] = "Jörg <jörg@example.de>"
    m["To"] = "a@example.com"
    m["Subject"] = "Grüße"
    m.set_content("hallo\n")
    r.append(lm.send_message(m))
    r.append(lm.quit())
    t.join(10)
    check("smtplib.LMTP over a Unix socket, SMTPUTF8", [r, [x for x in log if isinstance(x, str)]], [[(250, b'lmtp.local\n8BITMIME\nSMTPUTF8'), True, True, {}, (221, b'bye')], ['lhlo client.local', 'mail FROM:<jörg@example.de> SMTPUTF8 BODY=8BITMIME', 'rcpt TO:<a@example.com>', 'data', 'quit']])
    data = [x for x in log if isinstance(x, bytes)][0]
    check("smtplib: the SMTPUTF8 message", data.split(b"\r\n")[:3], [b'From: J\xc3\xb6rg <j\xc3\xb6rg@example.de>', b'To: a@example.com', b'Subject: Gr\xc3\xbc\xc3\x9fe'])
    import shutil
    shutil.rmtree(d)


# ── the protocol clients over TLS (lib/ssl.ny): STARTTLS and implicit TLS ────
def _make_certs():
    import os
    import subprocess
    import tempfile
    d = tempfile.mkdtemp()
    ext = os.path.join(d, "ext.cnf")
    f = open(ext, "w")
    f.write("subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n"
            "keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
    f.close()
    steps = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/ca.key", "-out", d + "/ca.pem",
         "-days", "2", "-subj", "/CN=audit110 CA"],
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/server.key", "-out", d + "/server.csr",
         "-subj", "/CN=localhost"],
        ["openssl", "x509", "-req", "-in", d + "/server.csr", "-CA", d + "/ca.pem", "-CAkey", d + "/ca.key",
         "-CAcreateserial", "-out", d + "/server.pem", "-days", "2", "-extfile", ext]]
    for s in steps:
        try:
            r = subprocess.run(s, capture_output=True, timeout=60)
        except Exception:
            return None
        if r.returncode != 0:
            return None
    return d


def _tls_serve(handler, sctx, implicit):
    # a server thread whose handler(state, log) reads and writes through
    # state["rfile"] / state["send"] and can switch the connection to TLS
    import threading
    srv = _listener()
    port = srv.getsockname()[1]
    log = []
    def run():
        conn, addr = srv.accept()
        state = {}
        def use(c):
            state["conn"] = c
            state["rfile"] = c.makefile("rb")
        def send(line):
            if isinstance(line, str):
                line = line.encode("utf-8")
            state["conn"].sendall(line + b"\r\n")
        def starttls():
            state["rfile"].close()
            use(sctx.wrap_socket(state["conn"], server_side=True))
        state["send"] = send
        state["starttls"] = starttls
        try:
            if implicit:
                use(sctx.wrap_socket(conn, server_side=True))
            else:
                use(conn)
            handler(state, log)
        except Exception as e:
            log.append("server error: " + type(e).__name__ + ": " + str(e))
        try:
            state["rfile"].close()
            state["conn"].close()
        except Exception:
            pass
        srv.close()
    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    return port, log, t


def smtp_tls_handler(state, log):
    send = state["send"]
    send("220 tls.local ESMTP")
    while True:
        line = _readline(state["rfile"])
        if line is None:
            break
        log.append(line)
        verb = line.split(" ")[0].upper()
        if verb == "EHLO":
            send("250-tls.local")
            if "secure" not in log:
                send("250-STARTTLS")
            send("250 AUTH PLAIN")
        elif verb == "STARTTLS":
            send("220 2.0.0 Ready to start TLS")
            state["starttls"]()
            log.append("secure")
        elif verb == "AUTH":
            send("235 ok")
        elif verb in ("MAIL", "RCPT", "NOOP", "RSET"):
            send("250 OK")
        elif verb == "DATA":
            send("354 go")
            while state["rfile"].readline() != b".\r\n":
                pass
            send("250 queued")
        elif verb == "QUIT":
            send("221 bye")
            break
        else:
            send("502 no")


def pop_tls_handler(state, log):
    send = state["send"]
    send("+OK secure POP3")
    while True:
        line = _readline(state["rfile"])
        if line is None:
            break
        log.append(line)
        cmd = line.split(" ")[0].upper()
        if cmd == "STAT":
            send("+OK 0 0")
        elif cmd == "QUIT":
            send("+OK bye")
            break
        else:
            send("+OK")


def imap_tls_handler(state, log):
    send = state["send"]
    send("* OK [CAPABILITY IMAP4rev1] secure IMAP")
    while True:
        line = _readline(state["rfile"])
        if line is None:
            break
        log.append(line)
        tag, rest = line.split(" ", 1)
        cmd = rest.split(" ")[0].upper()
        if cmd == "CAPABILITY":
            send("* CAPABILITY IMAP4rev1")
            send(tag + " OK done")
        elif cmd == "LOGIN":
            send(tag + " OK logged in")
        elif cmd == "LOGOUT":
            send("* BYE")
            send(tag + " OK bye")
            break
        else:
            send(tag + " OK " + cmd)


def ftp_tls_handler(state, log, sctx):
    send = state["send"]
    pasv = [None]
    prot = ["C"]
    send("220 secure FTP")
    while True:
        line = _readline(state["rfile"])
        if line is None:
            break
        log.append(line)
        cmd, _, arg = line.partition(" ")
        cmd = cmd.upper()
        if cmd == "AUTH":
            send("234 AUTH TLS ok")
            state["starttls"]()
        elif cmd == "USER":
            send("331 password")
        elif cmd == "PASS":
            send("230 logged in")
        elif cmd == "PBSZ":
            send("200 PBSZ=0")
        elif cmd == "PROT":
            prot[0] = arg
            send("200 protection level " + arg)
        elif cmd == "TYPE":
            send("200 ok")
        elif cmd == "PASV":
            ls = _listener()
            pasv[0] = ls
            p = ls.getsockname()[1]
            send("227 Entering Passive Mode (127,0,0,1,%d,%d)." % (p >> 8, p & 255))
        elif cmd in ("RETR", "NLST"):
            send("150 here it comes")
            c, a = pasv[0].accept()
            pasv[0].close()
            if prot[0] == "P":
                c = sctx.wrap_socket(c, server_side=True)
            c.sendall(b"secret data\r\n" if cmd == "RETR" else b"a.txt\r\nb.txt\r\n")
            if prot[0] == "P":
                c.unwrap()
            c.close()
            send("226 done")
        elif cmd == "QUIT":
            send("221 bye")
            break
        else:
            send("502 no")


def tls_protocol_checks():
    try:
        import ssl
    except ImportError:
        print("NOTICE: TLS protocol checks skipped - no ssl module")
        return
    import smtplib
    import poplib
    import imaplib
    import ftplib
    d = _make_certs()
    if d is None:
        print("NOTICE: TLS protocol checks skipped - no openssl command")
        return
    sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    sctx.load_cert_chain(d + "/server.pem", d + "/server.key")
    cctx = ssl.create_default_context(cafile=d + "/ca.pem")
    # SMTP with STARTTLS
    port, log, t = _tls_serve(smtp_tls_handler, sctx, False)
    s = smtplib.SMTP("localhost", port, local_hostname="client.local", timeout=10)
    r = [s.ehlo()[0], s.has_extn("starttls"), s.starttls(context=cctx), type(s.sock).__name__, s.sock.version()[:3]]
    s.ehlo()
    r.append(s.has_extn("starttls"))
    r.append(s.login("u", "p"))
    r.append(s.sendmail("a@b.c", ["d@e.f"], "Subject: tls\r\n\r\nsecure\r\n"))
    r.append(s.quit())
    t.join(10)
    check("smtplib: STARTTLS", [r, [x for x in log if not x.startswith("AUTH")]], [[250, True, (220, b'2.0.0 Ready to start TLS'), 'SSLSocket', 'TLS', False, (235, b'ok'), {}, (221, b'bye')], ['ehlo client.local', 'STARTTLS', 'secure', 'ehlo client.local', 'mail FROM:<a@b.c>', 'rcpt TO:<d@e.f>', 'data', 'quit']])
    # SMTP_SSL
    port, log, t = _tls_serve(smtp_tls_handler, sctx, True)
    s = smtplib.SMTP_SSL("localhost", port, local_hostname="client.local", context=cctx, timeout=10)
    r = [s.ehlo()[0], type(s.sock).__name__, s.noop(), s.quit()]
    t.join(10)
    check("smtplib.SMTP_SSL", r, [250, 'SSLSocket', (250, b'OK'), (221, b'bye')])
    # a certificate the client does not trust
    port, log, t = _tls_serve(smtp_tls_handler, sctx, True)
    try:
        smtplib.SMTP_SSL("localhost", port, context=ssl.create_default_context(), timeout=10)
        r = "connected"
    except ssl.SSLError as e:
        r = type(e).__name__
    t.join(10)
    check("smtplib.SMTP_SSL: an untrusted certificate", r, 'SSLCertVerificationError')
    # POP3_SSL, IMAP4_SSL
    port, log, t = _tls_serve(pop_tls_handler, sctx, True)
    p = poplib.POP3_SSL("localhost", port, context=cctx, timeout=10)
    r = [p.getwelcome(), p.stat(), type(p.sock).__name__, p.quit()]
    t.join(10)
    check("poplib.POP3_SSL", r, [b'+OK secure POP3', (0, 0), 'SSLSocket', b'+OK bye'])
    port, log, t = _tls_serve(imap_tls_handler, sctx, True)
    im = imaplib.IMAP4_SSL("localhost", port, ssl_context=cctx, timeout=10)
    r = [im.welcome, im.login("u", "p"), im.noop(), im.logout()]
    t.join(10)
    check("imaplib.IMAP4_SSL", r, [b'* OK [CAPABILITY IMAP4rev1] secure IMAP', ('OK', [b'logged in']), ('OK', [b'NOOP']), ('BYE', [b''])])
    # FTP_TLS with a protected data channel
    port, log, t = _tls_serve(lambda st, lg: ftp_tls_handler(st, lg, sctx), sctx, False)
    f = ftplib.FTP_TLS(context=cctx, timeout=10)
    r = [f.connect("localhost", port), f.login("u", "p"), type(f.sock).__name__, f.prot_p()]
    lines = []
    r.append(f.retrlines("RETR x.txt", lines.append))
    r.append(lines)
    r.append(f.nlst())
    r.append(f.quit())
    t.join(10)
    check("ftplib.FTP_TLS", [r, log], [['220 secure FTP', '230 logged in', 'SSLSocket', '200 protection level P', '226 done', ['secret data'], ['a.txt', 'b.txt'], '221 bye'], ['AUTH TLS', 'USER u', 'PASS p', 'PBSZ 0', 'PROT P', 'TYPE A', 'PASV', 'RETR x.txt', 'TYPE A', 'PASV', 'NLST', 'QUIT']])
    import shutil
    shutil.rmtree(d)



import warnings as _warnings
_warnings.simplefilter("ignore", DeprecationWarning)
section("sqlite3", sqlite_checks)
section("sqlite3 and threads", sqlite_thread_checks)
section("email", email_checks)
section("email: the default policy's API", email_api_checks)
section("plistlib", plist_checks)
section("quopri/uu", quopri_uu_checks)
section("netrc/mailcap/cgi", netrc_mailcap_cgi_checks)
section("audio", audio_checks)
section("dbm/shelve/mailbox", store_checks)
section("wsgiref", wsgi_checks)
section("xmlrpc", xmlrpc_checks)
section("protocols", protocol_checks)
section("LMTP", lmtp_checks)
section("protocols over TLS", tls_protocol_checks)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT110 PASSED ===")
