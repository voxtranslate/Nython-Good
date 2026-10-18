# vm_audit118.ny - the names CPython's system modules have and Nython's
# lacked, both engines (round 85): os/posix (statvfs, sysconf/pathconf/
# confstr, the uid/gid setters, getgrouplist, priorities, the scheduler and
# sched_param, eventfd, memfd_create, pidfd_open, pipe2, lockf,
# posix_fadvise/posix_fallocate, splice, copy_file_range, getrandom,
# extended attributes, posix_spawn/posix_spawnp, wait3/wait4/waitid,
# register_at_fork, popen, spawn*, fwalk, abort, a real posix module), time's
# POSIX clocks, signal's masks and synchronous waits and set_wakeup_fd,
# socket's ancillary data and interface calls, sys's int <-> str digit limit
# and unraisablehook, gc.get_objects/get_referents/get_referrers,
# ssl.RAND_*, hashlib.scrypt, locale's message catalogs, codecs,
# _sqlite3.enable_shared_cache.
#
# It runs under python3 too (`python3 examples/vm_audit118.ny`); every
# expected value is CPython's - fixed ones written here, the host's own
# (names, constants, what the system answers) asked of a python3 child
# process (`host(...)`, skipped when there is none). POSIX-only checks are
# skipped on Windows, Linux-only ones elsewhere, as CPython lacks the names.
#
#     ./build/nython-cli examples/vm_audit118.ny
#     ./build/nython-cli --vm examples/vm_audit118.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import sys
import io
import shutil
import tempfile
import subprocess
import json
import errno

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(f, *a, **k):
    try:
        f(*a, **k)
    except BaseException as e:
        return [type(e).__name__, str(e)]
    return None

def oserr(f, *a, **k):
    # an OSError's class, errno and filename, or the result
    try:
        return ["ok", f(*a, **k)]
    except OSError as e:
        return [type(e).__name__, e.errno, e.filename]

posix = sys.platform != "win32"
linux = sys.platform.startswith("linux")
TMP = tempfile.mkdtemp(prefix="ny118_" + str(os.getpid()) + "_")

def tpath(name):
    return os.path.join(TMP, name)

def write_bytes(path, data):
    with open(path, "wb") as f:
        f.write(data)

def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()

HOST = shutil.which("python3")

def host(code):
    # what the host's CPython answers: `code` sets the variable `out` to a
    # literal (lists, dicts, str, int, bool, None); NOHOST without python3
    if HOST is None:
        return "NOHOST"
    p = tpath("host_" + str(len(results)) + ".py")
    with open(p, "w") as f:
        f.write("import os, sys, json\n" + code + "\nprint(json.dumps(out))\n")
    r = subprocess.run([HOST, "-I", p], capture_output=True, timeout=120)
    text = r.stdout.decode("utf-8", "replace").strip().splitlines()
    if r.returncode != 0 or not text:
        return "HOSTFAIL " + r.stderr.decode("utf-8", "replace")[-300:]
    return json.loads(text[-1])

def hcheck(name, got, code):
    # got as JSON gives it (tuples as lists), against the host's
    want = host(code)
    if want == "NOHOST":
        return
    check(name, json.loads(json.dumps(got)), want)

def child(code, env=None, args=()):
    # `code` in a fresh process of this engine family: [returncode, stdout, stderr]
    p = tpath("child_" + str(len(results)) + ".py")
    with open(p, "w") as f:
        f.write(code)
    e = dict(os.environ)
    if env:
        e.update(env)
    r = subprocess.run([sys.executable] + list(args) + [p], capture_output=True, env=e, timeout=60)
    return [r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")]

# ── the posix module ─────────────────────────────────────────────────────────
if posix:
    import posix as px
    import pickle
    check("posix is os's own functions", [px.getcwd is os.getcwd, px.stat is os.stat, px.fspath is os.fspath,
                                          px.stat_result is os.stat_result, px.error is OSError], [True] * 5)
    check("os.getcwd.__module__ is posix", [os.getcwd.__module__, os.fspath.__module__, os.statvfs.__module__,
                                            os.walk.__module__, os.popen.__module__], ["posix", "posix", "posix", "os", "os"])
    check("a pickle of os.getcwd names posix", [b"posix" in pickle.dumps(os.getcwd), pickle.loads(pickle.dumps(os.getcwd)) is os.getcwd],
          [True, True])
    check("posix.environ: bytes to bytes", [type(px.environ).__name__, all(isinstance(k, bytes) for k in px.environ),
                                            px.environ.get(b"PATH") == os.environb.get(b"PATH")], ["dict", True, True])
    hcheck("posix's names", sorted(n for n in dir(px) if not n.startswith("_") and not n.startswith(("BTPROTO",))
                                   and n in ("getcwd", "statvfs", "sysconf", "posix_spawn", "sched_param", "waitid_result",
                                             "eventfd", "memfd_create", "getxattr", "register_at_fork", "environ")),
           "import posix\nout = sorted(n for n in dir(posix) if n in ('getcwd', 'statvfs', 'sysconf', 'posix_spawn', 'sched_param', "
           "'waitid_result', 'eventfd', 'memfd_create', 'getxattr', 'register_at_fork', 'environ'))")

# ── os: constants and the name tables ────────────────────────────────────────
OS_CONSTS = ["CLD_CONTINUED", "CLD_DUMPED", "CLD_EXITED", "CLD_KILLED", "CLD_STOPPED", "CLD_TRAPPED", "EFD_CLOEXEC",
             "EFD_NONBLOCK", "EFD_SEMAPHORE", "EX_CANTCREAT", "EX_CONFIG", "EX_DATAERR", "EX_IOERR", "EX_NOHOST",
             "EX_NOINPUT", "EX_NOPERM", "EX_NOUSER", "EX_OK", "EX_OSERR", "EX_OSFILE", "EX_PROTOCOL", "EX_SOFTWARE",
             "EX_TEMPFAIL", "EX_UNAVAILABLE", "EX_USAGE", "F_LOCK", "F_TEST", "F_TLOCK", "F_ULOCK", "GRND_NONBLOCK",
             "GRND_RANDOM", "MFD_ALLOW_SEALING", "MFD_CLOEXEC", "MFD_HUGETLB", "MFD_HUGE_1GB", "MFD_HUGE_2MB",
             "MFD_HUGE_MASK", "MFD_HUGE_SHIFT", "NGROUPS_MAX", "O_FSYNC", "POSIX_FADV_DONTNEED", "POSIX_FADV_NOREUSE",
             "POSIX_FADV_NORMAL", "POSIX_FADV_RANDOM", "POSIX_FADV_SEQUENTIAL", "POSIX_FADV_WILLNEED",
             "POSIX_SPAWN_CLOSE", "POSIX_SPAWN_DUP2", "POSIX_SPAWN_OPEN", "PRIO_PGRP", "PRIO_PROCESS", "PRIO_USER",
             "P_ALL", "P_PGID", "P_PID", "P_PIDFD", "P_WAIT", "P_NOWAIT", "P_NOWAITO", "RTLD_DEEPBIND", "RTLD_GLOBAL",
             "RTLD_LAZY", "RTLD_LOCAL", "RTLD_NODELETE", "RTLD_NOLOAD", "RTLD_NOW", "RWF_APPEND", "RWF_DSYNC",
             "RWF_HIPRI", "RWF_NOWAIT", "RWF_SYNC", "SCHED_BATCH", "SCHED_FIFO", "SCHED_IDLE", "SCHED_OTHER",
             "SCHED_RESET_ON_FORK", "SCHED_RR", "SPLICE_F_MORE", "SPLICE_F_MOVE", "SPLICE_F_NONBLOCK", "ST_APPEND",
             "ST_MANDLOCK", "ST_NOATIME", "ST_NODEV", "ST_NODIRATIME", "ST_NOEXEC", "ST_NOSUID", "ST_RDONLY",
             "ST_RELATIME", "ST_SYNCHRONOUS", "ST_WRITE", "TMP_MAX", "WEXITED", "WNOWAIT", "WSTOPPED", "XATTR_CREATE",
             "XATTR_REPLACE", "XATTR_SIZE_MAX"]
hcheck("os constants are the platform's", {n: getattr(os, n) for n in OS_CONSTS if hasattr(os, n)},
       "out = {n: getattr(os, n) for n in " + repr(OS_CONSTS) + " if hasattr(os, n)}")
if posix:
    hcheck("os.sysconf_names", os.sysconf_names, "out = os.sysconf_names")
    hcheck("os.pathconf_names", os.pathconf_names, "out = os.pathconf_names")
    hcheck("os.confstr_names", os.confstr_names, "out = os.confstr_names")
    hcheck("sysconf values", [os.sysconf("SC_PAGESIZE"), os.sysconf("SC_NPROCESSORS_CONF"), os.sysconf(os.sysconf_names["SC_ARG_MAX"]),
                              os.sysconf("SC_CLK_TCK")],
           "out = [os.sysconf('SC_PAGESIZE'), os.sysconf('SC_NPROCESSORS_CONF'), os.sysconf(os.sysconf_names['SC_ARG_MAX']), os.sysconf('SC_CLK_TCK')]")
    hcheck("confstr / pathconf", [os.confstr("CS_PATH"), os.pathconf("/", "PC_NAME_MAX"), os.pathconf("/", os.pathconf_names["PC_PATH_MAX"])],
           "out = [os.confstr('CS_PATH'), os.pathconf('/', 'PC_NAME_MAX'), os.pathconf('/', os.pathconf_names['PC_PATH_MAX'])]")
    check("sysconf / confstr errors", [raises(os.sysconf, "SC_BOGUS"), raises(os.sysconf, 1.5), raises(os.confstr, "CS_NOPE"),
                                       oserr(os.pathconf, tpath("nope"), "PC_NAME_MAX")[:2]],
          [["ValueError", "unrecognized configuration name"], ["TypeError", "configuration names must be strings or integers"],
           ["ValueError", "unrecognized configuration name"], ["FileNotFoundError", 2]])
    fd = os.open(TMP, os.O_RDONLY)
    check("fpathconf / pathconf of a descriptor", [os.fpathconf(fd, "PC_NAME_MAX") == os.pathconf(TMP, "PC_NAME_MAX"),
                                                    os.pathconf(fd, "PC_NAME_MAX") == os.pathconf(TMP, "PC_NAME_MAX")], [True, True])
    # statvfs
    sv = os.statvfs(TMP)
    check("statvfs_result", [type(sv).__name__, type(sv).__module__, len(sv), sv.n_fields, sv.n_sequence_fields,
                             repr(sv).startswith("os.statvfs_result(f_bsize="), sv[0] == sv.f_bsize, isinstance(sv.f_fsid, int),
                             os.fstatvfs(fd).f_bsize == sv.f_bsize, os.statvfs(fd).f_namemax == sv.f_namemax],
          ["statvfs_result", "os", 10, 11, 10, True, True, True, True, True])
    hcheck("statvfs of / as the host sees it", [os.statvfs("/").f_bsize, os.statvfs("/").f_namemax, os.statvfs("/").f_flag & os.ST_RDONLY],
           "out = [os.statvfs('/').f_bsize, os.statvfs('/').f_namemax, os.statvfs('/').f_flag & os.ST_RDONLY]")
    check("statvfs errors", [oserr(os.statvfs, tpath("nope")), raises(os.fstatvfs, "x")[0]],
          [["FileNotFoundError", 2, tpath("nope")], "TypeError"])
    os.close(fd)
    check("ctermid, device_encoding", [os.ctermid(), os.device_encoding(os.open(TMP, os.O_RDONLY))], ["/dev/tty", None])

# ── os: ids, groups, priorities ──────────────────────────────────────────────
if posix:
    import pwd
    me = pwd.getpwuid(os.getuid()).pw_name
    hcheck("getgrouplist", sorted(os.getgrouplist(me, os.getgid())),
           "import pwd\nout = sorted(os.getgrouplist(pwd.getpwuid(os.getuid()).pw_name, os.getgid()))")
    check("getgrouplist errors", [raises(os.getgrouplist, 5, 0)[0]], ["TypeError"])
    hcheck("getpriority / nice", [os.getpriority(os.PRIO_PROCESS, 0), os.nice(0)],
           "out = [os.getpriority(os.PRIO_PROCESS, 0), os.nice(0)]")
    os.setpriority(os.PRIO_PROCESS, 0, os.getpriority(os.PRIO_PROCESS, 0))
    check("the uid/gid setters to what they are", [os.setuid(os.getuid()), os.setgid(os.getgid()), os.seteuid(os.geteuid()),
                                                  os.setegid(os.getegid()), os.setreuid(-1, -1), os.setregid(-1, -1)],
          [None] * 6)
    check("setter argument errors", [raises(os.setuid, "x")[0], raises(os.setreuid, 1)[0]], ["TypeError", "TypeError"])
    if linux:
        check("getresuid / getresgid", [os.getresuid() == (os.getuid(), os.geteuid(), os.getuid()) or len(os.getresuid()) == 3,
                                        type(os.getresgid()).__name__, os.setresuid(-1, -1, -1), os.setresgid(-1, -1, -1)],
              [True, "tuple", None, None])
    if os.geteuid() == 0:
        g = os.getgroups()
        check("setgroups / initgroups (root)", [os.setgroups(g), os.initgroups(me, os.getgid()), os.setgroups(g), sorted(os.getgroups()) == sorted(g)],
              [None, None, None, True])
    else:
        check("setuid(0) without privileges", oserr(os.setuid, 0)[0], "PermissionError")

# ── os: the scheduler ────────────────────────────────────────────────────────
if posix:
    hcheck("sched_get_priority_max/min", [os.sched_get_priority_max(os.SCHED_RR), os.sched_get_priority_min(os.SCHED_RR),
                                          os.sched_get_priority_max(os.SCHED_OTHER)],
           "out = [os.sched_get_priority_max(os.SCHED_RR), os.sched_get_priority_min(os.SCHED_RR), os.sched_get_priority_max(os.SCHED_OTHER)]")
    p5 = os.sched_param(5)
    check("sched_param", [repr(p5), p5.sched_priority, p5[0], len(p5), os.sched_param(sched_priority=3).sched_priority,
                          type(p5).__module__, os.sched_param.n_fields, p5 == os.sched_param(5), raises(os.sched_param),
                          raises(os.sched_param, 1, 2)],
          ["posix.sched_param(sched_priority=5)", 5, 5, 1, 3, "posix", 1, True,
           ["TypeError", "sched_param() missing required argument 'sched_priority' (pos 1)"],
           ["TypeError", "sched_param() takes at most 1 argument (2 given)"]])
    check("sched_yield", os.sched_yield(), None)
    if linux:
        check("sched_getscheduler / getparam", [os.sched_getscheduler(0), repr(os.sched_getparam(0)), type(os.sched_rr_get_interval(0)).__name__],
              [os.SCHED_OTHER, "posix.sched_param(sched_priority=0)", "float"])
        check("sched_setparam / setscheduler", [os.sched_setparam(0, os.sched_param(0)), raises(os.sched_setparam, 0, 5),
                                                os.sched_setscheduler(0, os.SCHED_OTHER, os.sched_param(0))],
              [None, ["TypeError", "must have a sched_param object"], None])
        aff = os.sched_getaffinity(0)
        os.sched_setaffinity(0, aff)
        check("sched_setaffinity", [os.sched_getaffinity(0) == aff, raises(os.sched_setaffinity, 0, [-1])],
              [True, ["ValueError", "negative CPU number"]])
        check("sched_getparam of no process", oserr(os.sched_getparam, 2 ** 22 + 12345)[0], "ProcessLookupError")

# ── os: descriptors ──────────────────────────────────────────────────────────
if linux:
    r, w = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
    check("pipe2", [os.get_blocking(r), os.get_inheritable(w), raises(os.read, r, 1)[0]], [False, False, "BlockingIOError"])
    os.close(r)
    os.close(w)
    efd = os.eventfd(5)
    check("eventfd", [os.eventfd_read(efd), os.eventfd_write(efd, 3), os.eventfd_read(efd), raises(os.eventfd_write, efd, -1)],
          [5, None, 3, ["ValueError", "value must be positive"]])
    os.close(efd)
    efd = os.eventfd(0, os.EFD_NONBLOCK | os.EFD_CLOEXEC | os.EFD_SEMAPHORE)
    os.eventfd_write(efd, 2)
    check("eventfd semaphore / non-blocking", [os.eventfd_read(efd), os.eventfd_read(efd), raises(os.eventfd_read, efd)[0]],
          [1, 1, "BlockingIOError"])
    os.close(efd)
    mfd = os.memfd_create("ny118")
    os.write(mfd, b"hello memfd")
    check("memfd_create", [os.lseek(mfd, 0, 0), os.read(mfd, 20), os.fstat(mfd).st_size, os.get_inheritable(mfd)],
          [0, b"hello memfd", 11, False])
    os.close(mfd)
    check("getrandom", [len(os.getrandom(16)), os.getrandom(0), type(os.getrandom(4, os.GRND_NONBLOCK)).__name__,
                        oserr(os.getrandom, -1)[:2]], [16, b"", "bytes", ["OSError", 22]])
    src = tpath("cfr_src")
    write_bytes(src, b"0123456789abcdef")
    a = os.open(src, os.O_RDONLY)
    b = os.open(tpath("cfr_dst"), os.O_WRONLY | os.O_CREAT, 0o644)
    n1 = os.copy_file_range(a, b, 6)
    n2 = os.copy_file_range(a, b, 4, 12)
    os.close(b)
    check("copy_file_range", [n1, n2, read_bytes(tpath("cfr_dst")), os.lseek(a, 0, 1)], [6, 4, b"012345cdef", 6])
    pr, pw = os.pipe()
    n3 = os.splice(a, pw, 5, 10)
    check("splice", [n3, os.read(pr, 10)], [5, b"abcde"])
    os.close(a)
    os.close(pr)
    os.close(pw)
    f = os.open(tpath("falloc"), os.O_RDWR | os.O_CREAT, 0o644)
    check("posix_fallocate / posix_fadvise", [os.posix_fallocate(f, 0, 4096), os.fstat(f).st_size,
                                              os.posix_fadvise(f, 0, 0, os.POSIX_FADV_SEQUENTIAL),
                                              oserr(os.posix_fadvise, f, 0, 0, 99)[:2]],
          [None, 4096, None, ["OSError", 22]])
    check("lockf", [os.lockf(f, os.F_TLOCK, 0), os.lockf(f, os.F_TEST, 0), os.lockf(f, os.F_ULOCK, 0)], [None, None, None])
    check("fdatasync / fsync of a descriptor", [os.fdatasync(f), os.fdatasync(open(tpath("falloc"), "rb"))], [None, None])
    os.close(f)
    check("fdatasync of a closed descriptor", oserr(os.fdatasync, f)[:2], ["OSError", 9])
    here = os.getcwd()
    dfd = os.open(TMP, os.O_RDONLY)
    os.fchdir(dfd)
    check("fchdir", os.path.realpath(os.getcwd()) == os.path.realpath(TMP), True)
    os.chdir(here)
    os.close(dfd)
    check("sync", os.sync(), None)
    check("tcgetpgrp of a file", oserr(os.tcgetpgrp, os.open(src, os.O_RDONLY))[:2], ["OSError", 25])

# ── os: extended attributes (the host's answers on the same file) ────────────
if linux:
    XA = tpath("xattr_file")
    write_bytes(XA, b"x")
    def xattr_ops(path):
        out = []
        for f in (lambda: os.setxattr(path, "user.ny118", b"value"), lambda: os.getxattr(path, "user.ny118"),
                  lambda: "user.ny118" in os.listxattr(path), lambda: os.setxattr(path, "user.ny118", b"v2", os.XATTR_REPLACE),
                  lambda: os.getxattr(path, b"user.ny118", follow_symlinks=False),
                  lambda: os.removexattr(path, "user.ny118"), lambda: os.getxattr(path, "user.ny118"),
                  lambda: os.setxattr(path, "user.ny118", b"x", os.XATTR_REPLACE), lambda: os.getxattr(path + "_nope", "user.a")):
            try:
                v = f()
                out.append(v.decode() if isinstance(v, bytes) else v)
            except OSError as e:
                out.append([type(e).__name__, e.errno])
        return out
    got = xattr_ops(XA)
    os.unlink(XA)
    write_bytes(XA, b"x")
    hcheck("getxattr / setxattr / listxattr / removexattr", got,
           "path = " + repr(XA) + "\nout = []\n"
           "for f in (lambda: os.setxattr(path, 'user.ny118', b'value'), lambda: os.getxattr(path, 'user.ny118'),\n"
           "          lambda: 'user.ny118' in os.listxattr(path), lambda: os.setxattr(path, 'user.ny118', b'v2', os.XATTR_REPLACE),\n"
           "          lambda: os.getxattr(path, b'user.ny118', follow_symlinks=False),\n"
           "          lambda: os.removexattr(path, 'user.ny118'), lambda: os.getxattr(path, 'user.ny118'),\n"
           "          lambda: os.setxattr(path, 'user.ny118', b'x', os.XATTR_REPLACE), lambda: os.getxattr(path + '_nope', 'user.a')):\n"
           "    try:\n"
           "        v = f()\n"
           "        out.append(v.decode() if isinstance(v, bytes) else v)\n"
           "    except OSError as e:\n"
           "        out.append([type(e).__name__, e.errno])")
    check("listxattr of a descriptor and of None", [isinstance(os.listxattr(os.open(XA, os.O_RDONLY)), list), isinstance(os.listxattr(), list)],
          [True, True])

# ── os: processes ────────────────────────────────────────────────────────────
if posix:
    out_path = tpath("spawn_out")
    fa = [(os.POSIX_SPAWN_OPEN, 1, out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644),
          (os.POSIX_SPAWN_DUP2, 1, 2), (os.POSIX_SPAWN_CLOSE, 0)]
    pid = os.posix_spawn("/bin/sh", ["sh", "-c", "echo spawned; echo err >&2; exit 3"], os.environ, file_actions=fa)
    st = os.waitpid(pid, 0)[1]
    check("posix_spawn with file_actions", [os.WEXITSTATUS(st), read_bytes(out_path)], [3, b"spawned\nerr\n"])
    pid = os.posix_spawnp("sh", ["sh", "-c", "exit $N"], {"N": "4", "PATH": os.environ.get("PATH", "/bin:/usr/bin")})
    check("posix_spawnp with env", os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]), 4)
    pid = os.posix_spawn("/bin/sleep", ["sleep", "5"], os.environ, setpgroup=0, setsigmask=[], setsigdef=[], resetids=False)
    check("posix_spawn setpgroup", os.getpgid(pid) == pid, True)
    os.kill(pid, 9)
    st = os.waitpid(pid, 0)[1]
    check("its kill", [os.WIFSIGNALED(st), os.WTERMSIG(st)], [True, 9])
    pid = os.posix_spawn("/bin/sh", ["sh", "-c", "exit 0"], os.environ, setsid=True, scheduler=(None, os.sched_param(0)))
    check("posix_spawn setsid + scheduler", os.waitpid(pid, 0)[1], 0)
    check("posix_spawn errors", [raises(os.posix_spawn, "/bin/sh", "x", os.environ), raises(os.posix_spawn, "/bin/sh", [], os.environ),
                                 raises(os.posix_spawn, "/bin/sh", [""], os.environ), raises(os.posix_spawn, "/bin/sh", ["sh"], 5),
                                 raises(os.posix_spawn, "/bin/sh", ["sh"], os.environ, file_actions=[(9,)]),
                                 raises(os.posix_spawn, "/bin/sh", ["sh"], os.environ, file_actions=[(os.POSIX_SPAWN_CLOSE,)]),
                                 oserr(os.posix_spawn, tpath("no_such_prog"), ["x"], os.environ)],
          [["TypeError", "posix_spawn: argv must be a tuple or list"], ["ValueError", "posix_spawn: argv must not be empty"],
           ["ValueError", "posix_spawn: argv first element cannot be empty"],
           ["TypeError", "posix_spawn: environment must be a mapping object"],
           ["TypeError", "Unknown file_actions identifier"], ["TypeError", "A close file_action tuple must have 2 elements"],
           ["FileNotFoundError", 2, tpath("no_such_prog")]])
    # wait3 / wait4 / waitid
    pid = os.posix_spawn("/bin/sh", ["sh", "-c", "exit 5"], os.environ)
    r4 = os.wait4(pid, 0)
    check("wait4", [r4[0] == pid, os.WEXITSTATUS(r4[1]), type(r4[2]).__name__, r4[2].ru_utime >= 0, len(r4)],
          [True, 5, "struct_rusage", True, 3])
    pid = os.posix_spawn("/bin/sh", ["sh", "-c", "exit 6"], os.environ)
    r3 = os.wait3(0)
    check("wait3", [r3[0] == pid, os.WEXITSTATUS(r3[1]), type(r3[2]).__name__], [True, 6, "struct_rusage"])
    check("wait3 with no children", raises(os.wait3, 0)[0], "ChildProcessError")
    if linux:
        pid = os.posix_spawn("/bin/sh", ["sh", "-c", "exit 7"], os.environ)
        wr = os.waitid(os.P_PID, pid, os.WEXITED)
        check("waitid", [type(wr).__name__, wr.si_pid == pid, wr.si_status, wr.si_code, wr.si_signo, len(wr),
                         repr(wr).startswith("posix.waitid_result(si_pid=")],
              ["waitid_result", True, 7, os.CLD_EXITED, 17, 5, True])
        check("waitid WNOHANG with nothing to report", oserr(os.waitid, os.P_ALL, 0, os.WEXITED | os.WNOHANG)[0], "ChildProcessError")
        pid = os.posix_spawn("/bin/sleep", ["sleep", "5"], os.environ)
        pfd = os.pidfd_open(pid)
        import signal
        signal.pidfd_send_signal(pfd, signal.SIGKILL)
        st = os.waitpid(pid, 0)[1]
        check("pidfd_open / pidfd_send_signal", [pfd >= 0, os.WTERMSIG(st), raises(signal.pidfd_send_signal, pfd, 0, 1)],
              [True, 9, ["TypeError", "siginfo must be None"]])
        os.close(pfd)
        if hasattr(os, "unshare"):   # 3.12
            check("unshare(0)", os.unshare(0), None)
    # spawn*
    check("spawnv / spawnvp P_WAIT", [os.spawnv(os.P_WAIT, "/bin/sh", ["sh", "-c", "exit 8"]),
                                      os.spawnvp(os.P_WAIT, "sh", ["sh", "-c", "exit 9"]),
                                      os.spawnl(os.P_WAIT, "/bin/sh", "sh", "-c", "kill -9 $$"),
                                      os.spawnve(os.P_WAIT, "/bin/sh", ["sh", "-c", "exit $X"], {"X": "10"})],
          [8, 9, -9, 10])
    pid = os.spawnlp(os.P_NOWAIT, "sh", "sh", "-c", "exit 11")
    check("spawnlp P_NOWAIT", os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]), 11)
    check("spawnv of no program", os.spawnv(os.P_WAIT, tpath("no_such_prog"), ["x"]), 127)
    # popen
    p = os.popen("echo popen-out; echo second")
    check("popen read", [p.read(), p.close()], ["popen-out\nsecond\n", None])
    check("popen status", os.popen("exit 3").close(), 768)
    with os.popen("cat > " + tpath("popen_w"), "w") as p:
        p.write("written\n")
    check("popen write, a context manager", read_bytes(tpath("popen_w")), b"written\n")
    check("popen iterates", [line for line in os.popen("printf 'a\\nb\\n'")], ["a\n", "b\n"])
    check("popen errors", [raises(os.popen, 5), raises(os.popen, "true", "x"), raises(os.popen, "true", "r", 0)],
          [["TypeError", "invalid cmd type (<class 'int'>, expected string)"], ["ValueError", "invalid mode 'x'"],
           ["ValueError", "popen() does not support unbuffered streams"]])
    # register_at_fork around os.fork
    order_path = tpath("atfork_order")
    log = []
    os.register_at_fork(before=lambda: log.append("before1"), after_in_parent=lambda: log.append("parent"),
                        after_in_child=lambda: write_bytes(order_path, b"child"))
    os.register_at_fork(before=lambda: log.append("before2"))
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    os.waitpid(pid, 0)
    check("register_at_fork: before last first, then the parent's; the child's ran there",
          [log, read_bytes(order_path)], [["before2", "before1", "parent"], b"child"])
    check("register_at_fork errors", [raises(os.register_at_fork), raises(os.register_at_fork, before=1)],
          [["TypeError", "At least one argument is required."], ["TypeError", "'before' must be callable, not int"]])
    r = child("import os\nos.setpgrp()\nprint(os.getpgrp() == os.getpid())\nos.abort()\n")
    check("setpgrp, abort (in a child)", [r[1].strip(), r[0]], ["True", -6])
    # fwalk
    os.makedirs(tpath("tree/a/b"))
    write_bytes(tpath("tree/f1"), b"1")
    write_bytes(tpath("tree/a/f2"), b"2")
    fw = []
    for top, dirs, files, dfd in os.fwalk(tpath("tree")):
        fw.append([os.path.relpath(top, TMP), sorted(dirs), sorted(files), isinstance(dfd, int) and dfd >= 0])
    wk = [[os.path.relpath(t, TMP), sorted(d), sorted(f), True] for t, d, f in os.walk(tpath("tree"))]
    check("fwalk", sorted(fw), sorted(wk))
    check("fwalk bottom-up", [x[0] for x in os.fwalk(tpath("tree"), topdown=False)][-1] == tpath("tree"), True)
    check("getenvb", os.getenvb(b"PATH") == os.environb.get(b"PATH"), True)
    check("the supports_* sets", [type(os.supports_fd).__name__, os.access in os.supports_effective_ids,
                                  os.chown in os.supports_fd, os.stat in os.supports_fd, os.access in os.supports_follow_symlinks,
                                  os.getxattr in os.supports_follow_symlinks if linux else False],
          ["set", True, True, True, True, False])
    if os.geteuid() == 0:
        r = child("import os\nos.chroot('/')\nprint(os.getcwd() != '')\n")
        check("chroot (root, in a child)", r[1].strip(), "True")

# ── time: the POSIX clocks ───────────────────────────────────────────────────
import time
import threading
if posix:
    CLOCKS = ["CLOCK_BOOTTIME", "CLOCK_MONOTONIC", "CLOCK_MONOTONIC_RAW", "CLOCK_PROCESS_CPUTIME_ID", "CLOCK_REALTIME",
              "CLOCK_TAI", "CLOCK_THREAD_CPUTIME_ID", "CLOCK_HIGHRES", "CLOCK_PROF", "CLOCK_UPTIME", "CLOCK_UPTIME_RAW"]
    hcheck("time.CLOCK_*", {n: getattr(time, n) for n in CLOCKS if hasattr(time, n)},
           "import time\nout = {n: getattr(time, n) for n in " + repr(CLOCKS) + " if hasattr(time, n)}")
    hcheck("clock_getres", [time.clock_getres(time.CLOCK_REALTIME), time.clock_getres(time.CLOCK_MONOTONIC)],
           "import time\nout = [time.clock_getres(time.CLOCK_REALTIME), time.clock_getres(time.CLOCK_MONOTONIC)]")
    check("clock_gettime", [abs(time.clock_gettime(time.CLOCK_REALTIME) - time.time()) < 5,
                            type(time.clock_gettime_ns(time.CLOCK_MONOTONIC)).__name__,
                            time.clock_gettime_ns(time.CLOCK_REALTIME) > 1600000000 * 10 ** 9,
                            time.clock_gettime(time.CLOCK_MONOTONIC) <= time.clock_gettime(time.CLOCK_MONOTONIC)],
          [True, "int", True, True])
    check("clock errors", [raises(time.clock_gettime, "x"), raises(time.clock_gettime, 1.5)[0], oserr(time.clock_gettime, 999)[:2],
                           oserr(time.clock_settime, time.CLOCK_MONOTONIC, 5)[:2], raises(time.clock_settime_ns, time.CLOCK_MONOTONIC, 5.5),
                           raises(time.clock_settime, time.CLOCK_REALTIME, "x")],
          [["TypeError", "'str' object cannot be interpreted as an integer"], "TypeError", ["OSError", 22], ["OSError", 22],
           ["TypeError", "expect int, got float"], ["TypeError", "'str' object cannot be interpreted as an integer"]])
    if linux:
        cid = time.pthread_getcpuclockid(threading.get_ident())
        check("pthread_getcpuclockid", [type(cid).__name__, time.clock_gettime(cid) >= 0, time.thread_time() >= 0,
                                        type(time.thread_time_ns()).__name__], ["int", True, True, "int"])
        hcheck("get_clock_info('thread_time')", time.get_clock_info("thread_time").implementation,
               "import time\nout = time.get_clock_info('thread_time').implementation")

# ── signal ───────────────────────────────────────────────────────────────────
import signal
if posix:
    SIGS = ["SIG_BLOCK", "SIG_UNBLOCK", "SIG_SETMASK", "SIGRTMIN", "SIGRTMAX", "SIGCLD", "SIGIOT", "SIGPOLL", "SIGPWR",
            "SIGSTKFLT", "NSIG"]
    hcheck("signal constants", {n: int(getattr(signal, n)) for n in SIGS if hasattr(signal, n)},
           "import signal\nout = {n: int(getattr(signal, n)) for n in " + repr(SIGS) + " if hasattr(signal, n)}")
    hcheck("valid_signals / strsignal", [len(signal.valid_signals()), signal.strsignal(signal.SIGUSR1)],
           "import signal\nout = [len(signal.valid_signals()), signal.strsignal(signal.SIGUSR1)]")
    rfd, wfd = os.pipe()
    check("set_wakeup_fd needs a non-blocking fd", raises(signal.set_wakeup_fd, wfd), ["ValueError", "the fd " + str(wfd) + " must be in non-blocking mode"])
    os.set_blocking(wfd, False)
    os.set_blocking(rfd, False)
    check("set_wakeup_fd returns the old fd", [signal.set_wakeup_fd(wfd), signal.set_wakeup_fd(-1), signal.set_wakeup_fd(wfd, warn_on_full_buffer=False)],
          [-1, wfd, -1])
    got = []
    old_h = signal.signal(signal.SIGUSR1, lambda s, f: got.append(s))
    os.kill(os.getpid(), signal.SIGUSR1)
    time.sleep(0.05)
    check("a signal's number reaches the wakeup fd", [os.read(rfd, 10), [int(x) for x in got]], [bytes([signal.SIGUSR1]), [int(signal.SIGUSR1)]])
    signal.set_wakeup_fd(-1)
    os.close(rfd)
    os.close(wfd)
    check("set_wakeup_fd errors", [oserr(signal.set_wakeup_fd, 99999)[:2], raises(signal.set_wakeup_fd, "x")[0]],
          [["OSError", 9], "TypeError"])
    def from_thread(out):
        out.append(raises(signal.set_wakeup_fd, -1))
    tout = []
    th = threading.Thread(target=from_thread, args=(tout,))
    th.start()
    th.join()
    check("set_wakeup_fd only in the main thread", tout, [["ValueError", "set_wakeup_fd only works in main thread of the main interpreter"]])
    check("siginterrupt", [signal.siginterrupt(signal.SIGUSR1, True), signal.siginterrupt(signal.SIGUSR1, False),
                           raises(signal.siginterrupt, 0, True)], [None, None, ["ValueError", "signal number out of range"]])
    signal.siginterrupt(signal.SIGUSR1, True)
    signal.signal(signal.SIGUSR1, old_h)
    # masks and synchronous waits
    old = signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGUSR2])
    check("pthread_sigmask", [signal.SIGUSR2 in signal.pthread_sigmask(signal.SIG_BLOCK, []), signal.SIGUSR2 in old],
          [True, False])
    signal.pthread_kill(threading.get_ident(), signal.SIGUSR2)
    check("sigpending / sigwait", [signal.SIGUSR2 in signal.sigpending(), signal.sigwait([signal.SIGUSR2])], [True, signal.SIGUSR2])
    if linux:
        signal.pthread_kill(threading.get_ident(), signal.SIGUSR2)
        info = signal.sigwaitinfo({signal.SIGUSR2})
        check("sigwaitinfo", [type(info).__name__, info.si_signo, info.si_pid == os.getpid(), info.si_code, len(info),
                              repr(info).startswith("signal.struct_siginfo(si_signo=12, si_code=0, si_errno=0, si_pid=")],
              ["struct_siginfo", 12, True, 0, 7, True])
        check("sigtimedwait", [signal.sigtimedwait([signal.SIGUSR2], 0.01), raises(signal.sigtimedwait, [signal.SIGUSR2], -1)],
              [None, ["ValueError", "timeout must be non-negative"]])
    check("pthread_sigmask errors", [oserr(signal.pthread_sigmask, 5, [])[:2], raises(signal.pthread_sigmask, signal.SIG_BLOCK, [0]),
                                     raises(signal.pthread_sigmask, signal.SIG_BLOCK, 5)[0]],
          [["OSError", 22], ["ValueError", "signal number 0 out of range [1; " + str(signal.NSIG - 1) + "]"], "TypeError"])
    signal.pthread_sigmask(signal.SIG_SETMASK, old)
    check("pthread_kill", [signal.pthread_kill(threading.get_ident(), 0), signal.pthread_kill(threading.main_thread().ident, 0)],
          [None, None])
    check("the enums", [int(signal.Signals.SIGINT), signal.Signals(2).name, signal.Signals.SIGTERM == signal.SIGTERM,
                        int(signal.Handlers.SIG_IGN), signal.Handlers(0).name, int(signal.Sigmasks.SIG_SETMASK),
                        "Signals" in dir(signal)],
          [2, "SIGINT", True, 1, "SIG_DFL", 2, True])
    check("ItimerError", [issubclass(signal.ItimerError, OSError), signal.ItimerError.__name__, signal.ItimerError.__module__,
                          raises(signal.setitimer, 99, 1.0)[0]], [True, "itimer_error", "signal", "itimer_error"])

# ── socket ───────────────────────────────────────────────────────────────────
import socket
check("socket's exception names", [socket.error is OSError, socket.timeout is TimeoutError, issubclass(socket.gaierror, OSError),
                                   issubclass(socket.herror, OSError)], [True, True, True, True])
if posix:
    hcheck("CMSG_LEN / CMSG_SPACE", [socket.CMSG_LEN(0), socket.CMSG_LEN(4), socket.CMSG_SPACE(4), socket.CMSG_SPACE(13)],
           "import socket\nout = [socket.CMSG_LEN(0), socket.CMSG_LEN(4), socket.CMSG_SPACE(4), socket.CMSG_SPACE(13)]")
    check("CMSG_LEN out of range", raises(socket.CMSG_LEN, -1), ["OverflowError", "CMSG_LEN() argument out of range"])
    hcheck("if_nameindex / if_nametoindex / if_indextoname", [[list(x) for x in socket.if_nameindex()], socket.if_nametoindex("lo"),
                                                              socket.if_indextoname(1)],
           "import socket\nout = [[list(x) for x in socket.if_nameindex()], socket.if_nametoindex('lo'), socket.if_indextoname(1)]")
    check("interface errors", [raises(socket.if_nametoindex, "nope0"), oserr(socket.if_indextoname, 99999)[:2]],
          [["OSError", "no interface with this name"], ["OSError", 6]])
    hcheck("getprotobyname / gethostbyname_ex / has_dualstack_ipv6",
           [socket.getprotobyname("tcp"), socket.getprotobyname("udp"), list(socket.gethostbyname_ex("localhost")),
            socket.has_dualstack_ipv6(), raises(socket.getprotobyname, "nope")],
           "import socket\nout = [socket.getprotobyname('tcp'), socket.getprotobyname('udp'), list(socket.gethostbyname_ex('localhost')),"
           " socket.has_dualstack_ipv6()]\ntry:\n    socket.getprotobyname('nope')\nexcept OSError as e:\n    out.append([type(e).__name__, str(e)])")
    sa, sb = socket.socketpair()
    d = socket.dup(sa.fileno())
    socket.close(d)
    check("socket.dup / socket.close", [d != sa.fileno(), oserr(socket.close, d)[:2]], [True, ["OSError", 9]])
    s2 = socket.fromfd(sa.fileno(), socket.AF_UNIX, socket.SOCK_STREAM)
    check("socket.fromfd", [type(s2).__name__, s2.fileno() != sa.fileno()], ["socket", True])
    s2.close()
    sa.sendmsg([b"x", b"yz"])
    check("sendmsg / recvmsg", sb.recvmsg(10), (b"xyz", [], 0, None))
    pr, pw = os.pipe()
    check("send_fds", socket.send_fds(sa, [b"fds"], [pw]), 3)
    msg, fds, flags, addr = socket.recv_fds(sb, 10, 4)
    os.write(fds[0], b"through the passed fd")
    check("recv_fds: a descriptor passed over the socket works", [msg, len(fds), fds[0] != pw, os.read(pr, 100), flags],
          [b"fds", 1, True, b"through the passed fd", 0])
    for x in (pr, pw, fds[0]):
        os.close(x)
    sa.sendmsg([b"anc"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, bytes(4))]) if false else None
    sa.close()
    sb.close()
    hs = host("import socket\nout = sorted(n for n in dir(socket) if n.isupper() and not n.startswith('_') and "
              "isinstance(getattr(socket, n), int) and not n.startswith(('BTPROTO_', 'HCI_', 'SOL_HCI', 'BDADDR_')))")
    if isinstance(hs, list):
        # (Bluetooth's need headers this build may lack; a newer CPython
        # has more, which are not asked for)
        check("every integer constant of the host's socket", [n for n in hs if not hasattr(socket, n)], [])
    SOCKS = ["AF_PACKET", "AF_NETLINK", "AF_CAN", "AF_VSOCK", "AF_ALG", "SO_PEERCRED", "SO_PASSCRED", "SCM_RIGHTS",
             "SCM_CREDENTIALS", "MSG_NOSIGNAL", "MSG_CMSG_CLOEXEC", "TCP_CORK", "TCP_INFO", "IP_TOS", "IPV6_RECVPKTINFO",
             "EAI_NONAME", "NI_MAXHOST", "SOCK_CLOEXEC", "SOCK_NONBLOCK", "CAN_RAW", "CAN_BCM_TX_SETUP", "TIPC_ADDR_ID",
             "VMADDR_CID_ANY", "NETLINK_ROUTE", "IPPORT_RESERVED", "INADDR_NONE", "PF_PACKET", "ALG_SET_KEY", "SOL_TCP"]
    hcheck("socket constant values", {n: getattr(socket, n) for n in SOCKS if hasattr(socket, n)},
           "import socket\nout = {n: int(getattr(socket, n)) for n in " + repr(SOCKS) + " if hasattr(socket, n)}")
    check("socket's enums", [int(socket.AddressFamily.AF_INET), socket.SocketKind(socket.SOCK_STREAM).name,
                             int(socket.MsgFlag.MSG_PEEK), int(socket.AddressInfo.AI_PASSIVE), "AddressFamily" in dir(socket)],
          [2, "SOCK_STREAM", 2, 1, True])

# ── sys ──────────────────────────────────────────────────────────────────────
check("sys's digit limit", [sys.get_int_max_str_digits(), sys.int_info.default_max_str_digits, sys.int_info.str_digits_check_threshold,
                            sys.flags.int_max_str_digits], [4300, 4300, 640, -1])
big = 10 ** 5000
check("int <-> str beyond the limit", [raises(int, "1" * 5000), raises(str, big), raises(repr, big), raises(lambda: "%d" % big),
                                       raises(lambda: f"{big}"), raises(format, big, ","), raises(int, "1" * 4301 + "x")],
      [["ValueError", "Exceeds the limit (4300 digits) for integer string conversion: value has 5000 digits; use sys.set_int_max_str_digits() to increase the limit"],
       ["ValueError", "Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"],
       ["ValueError", "Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"],
       ["ValueError", "Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"],
       ["ValueError", "Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"],
       ["ValueError", "Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"],
       ["ValueError", "Exceeds the limit (4300 digits) for integer string conversion: value has 4301 digits; use sys.set_int_max_str_digits() to increase the limit"]])
check("within the limit, powers of two, negative", [len(str(10 ** 4299)), len(str(-(10 ** 4299))), int("1" * 5000, 16) > 0,
                                                     len(hex(big)) > 0, int("1" * 4300) > 0, raises(str, -(10 ** 4300))[0]],
      [4300, 4301, True, True, True, "ValueError"])
check("set_int_max_str_digits", [raises(sys.set_int_max_str_digits, 100), raises(sys.set_int_max_str_digits, "5")[0],
                                 sys.set_int_max_str_digits(640), raises(int, "1" * 641)[1][:38], sys.set_int_max_str_digits(0),
                                 len(str(big)), sys.set_int_max_str_digits(maxdigits=4300), sys.get_int_max_str_digits()],
      [["ValueError", "maxdigits must be 0 or larger than 640"], "TypeError", None, "Exceeds the limit (640 digits) for int",
       None, 5001, None, 4300])
r = child("import sys\nprint(sys.get_int_max_str_digits(), sys.flags.int_max_str_digits)\n", args=("-X", "int_max_str_digits=1000"))
check("-X int_max_str_digits", r[1].split(), ["1000", "1000"])
r = child("import sys\nprint(sys.get_int_max_str_digits(), sys.flags.int_max_str_digits)\n", env={"PYTHONINTMAXSTRDIGITS": "2000"})
check("PYTHONINTMAXSTRDIGITS", r[1].split(), ["2000", "2000"])
r = child("pass\n", args=("-X", "int_max_str_digits=10"))
check("an invalid -X int_max_str_digits", [r[0], "invalid limit; must be >= 640 or 0 for unlimited" in r[2]], [1, True])

# sys.unraisablehook
seen = []
def hook(u):
    seen.append([u.exc_type.__name__, str(u.exc_value), u.err_msg, type(u).__name__, u.exc_traceback is not None,
                 "__del__" in repr(u.object) or "cb" in repr(u.object) or u.object is None or "generator" in repr(u.object)])
sys.unraisablehook = hook
class Dying:
    def __del__(self):
        raise ZeroDivisionError("in __del__")
d1 = Dying()
del d1
import gc
gc.collect()
import weakref
class Target:
    pass
t1 = Target()
def cb(r):
    raise KeyError("in callback")
wr = weakref.ref(t1, cb)
del t1
gc.collect()
def gen():
    try:
        yield 1
    finally:
        raise ValueError("in finally")
g1 = gen()
next(g1)
del g1
gc.collect()
sys.unraisablehook = sys.__unraisablehook__
check("sys.unraisablehook gets __del__, weakref callback and generator errors",
      seen, [["ZeroDivisionError", "in __del__", None, "UnraisableHookArgs", True, True],
             ["KeyError", "'in callback'", None, "UnraisableHookArgs", True, True],
             ["ValueError", "in finally", None, "UnraisableHookArgs", True, True]])
r = child("import sys, gc\nclass D:\n    def __del__(self):\n        raise RuntimeError('boom')\n"
          "got = []\nsys.unraisablehook = got.append\nd = D()\ndel d\ngc.collect()\nsys.unraisablehook = sys.__unraisablehook__\n"
          "print(len(got))\nsys.__unraisablehook__(got[0])\n")
check("the default unraisablehook's report", [r[1].strip(), r[2].splitlines()[0].startswith("Exception ignored in: <function D.__del__"),
                                              r[2].strip().splitlines()[-1]],
      ["1", True, "RuntimeError: boom"])
hcheck("sys's other members", [sys.getdlopenflags() if posix else 2, sys.abiflags if posix else "", sys.pycache_prefix,
                               sys.thread_info.name, len(sys.thread_info), sys.get_coroutine_origin_tracking_depth()],
       "out = [sys.getdlopenflags(), sys.abiflags, sys.pycache_prefix, sys.thread_info.name, len(sys.thread_info), sys.get_coroutine_origin_tracking_depth()]")
check("getallocatedblocks", [type(sys.getallocatedblocks()).__name__, sys.getallocatedblocks() > 0], ["int", True])
if posix:
    old = sys.getdlopenflags()
    sys.setdlopenflags(os.RTLD_NOW | os.RTLD_GLOBAL)
    check("setdlopenflags", [sys.getdlopenflags(), raises(sys.setdlopenflags, "x")[0]], [258, "TypeError"])
    sys.setdlopenflags(old)
check("coroutine origin tracking depth", [sys.set_coroutine_origin_tracking_depth(2), sys.get_coroutine_origin_tracking_depth(),
                                          raises(sys.set_coroutine_origin_tracking_depth, -1), sys.set_coroutine_origin_tracking_depth(0)],
      [None, 2, ["ValueError", "depth must be >= 0"], None])

# ── gc ───────────────────────────────────────────────────────────────────────
class Holder:
    def __init__(self):
        self.x = [1]
        self.y = "s"
hold = Holder()
mine = [hold, "marker"]
objs = gc.get_objects()
check("get_objects has what the program made", [any(o is mine for o in objs), any(o is hold for o in objs),
                                               isinstance(gc.get_objects(0), list), len(gc.get_objects(-1)) > 0],
      [True, True, True, True])
check("get_objects errors", [raises(gc.get_objects, 3), raises(gc.get_objects, -2), raises(gc.get_objects, "x")],
      [["ValueError", "generation parameter must be less than the number of available generations (3)"],
       ["ValueError", "generation parameter cannot be negative"],
       ["TypeError", "argument should be integer or None, not 'str'"]])
check("get_referents", [gc.get_referents([1, "a", mine]) == [mine, "a", 1], gc.get_referents((1, [2])), gc.get_referents({"a": [1], "b": 2}),
                        gc.get_referents({1: [1], (2,): 3}), gc.get_referents(hold) == [[1], "s", Holder],
                        sorted(gc.get_referents({1, 2})), gc.get_referents(1, "x"), gc.get_referents()],
      [True, [[2], 1], [[1], 2], [[1], 1, 3, (2,)], True, [1, 2], [], []])
refs = gc.get_referrers(hold)
check("get_referrers", [any(r is mine for r in refs), any(isinstance(r, dict) for r in refs), gc.get_referrers()],
      [True, True, []])
check("is_tracked", [gc.is_tracked([]), gc.is_tracked({}), gc.is_tracked({"a": 1}), gc.is_tracked({"a": []}), gc.is_tracked(()),
                     gc.is_tracked(([],)), gc.is_tracked(hold), gc.is_tracked(1), gc.is_tracked("s")],
      [True, False, False, True, False, True, True, False, False])

# ── ssl, hashlib, functools, locale, codecs, _sqlite3 ────────────────────────
import ssl
check("ssl.RAND_*", [len(ssl.RAND_bytes(16)), type(ssl.RAND_bytes(1)).__name__, ssl.RAND_bytes(0), ssl.RAND_status(),
                     ssl.RAND_add(b"entropy", 1.0), ssl.RAND_add("text", 0.5), raises(ssl.RAND_bytes, -1)],
      [16, "bytes", b"", True, None, None, ["ValueError", "num must be positive"]])
if hasattr(ssl, "RAND_pseudo_bytes"):
    import warnings
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        rp = ssl.RAND_pseudo_bytes(8)
    check("ssl.RAND_pseudo_bytes", [len(rp[0]), rp[1], w[0].category.__name__], [8, True, "DeprecationWarning"])
der = bytes(range(70))
pem = ssl.DER_cert_to_PEM_cert(der)
check("DER <-> PEM", [pem.splitlines()[0], pem.splitlines()[-1], len(pem.splitlines()), ssl.PEM_cert_to_DER_cert(pem) == der,
                      raises(ssl.PEM_cert_to_DER_cert, "x")],
      ["-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----", 4, True,
       ["ValueError", "Invalid PEM encoding; must start with -----BEGIN CERTIFICATE-----"]])
check("cert_time_to_seconds / get_protocol_name", [ssl.cert_time_to_seconds("May  9 00:00:00 2007 GMT"),
                                                   ssl.cert_time_to_seconds("Jan  5 09:34:43 2018 GMT"),
                                                   raises(ssl.cert_time_to_seconds, "Xyz  9 00:00:00 2007 GMT")[0],
                                                   ssl.get_protocol_name(ssl.PROTOCOL_TLS_CLIENT), ssl.get_protocol_name(99)],
      [1178668800, 1515144883, "ValueError", "PROTOCOL_TLS_CLIENT", "<unknown>"])
SSLC = ["OP_NO_COMPRESSION", "OP_NO_TICKET", "OP_NO_TLSv1", "OP_CIPHER_SERVER_PREFERENCE", "ALERT_DESCRIPTION_HANDSHAKE_FAILURE",
        "ALERT_DESCRIPTION_UNKNOWN_CA", "SSL_ERROR_WANT_READ", "SSL_ERROR_EOF", "VERIFY_X509_STRICT", "VERIFY_CRL_CHECK_CHAIN",
        "PROTOCOL_TLSv1_2", "PROTOCOL_SSLv23"]
hcheck("ssl constants", {n: int(getattr(ssl, n)) for n in SSLC if hasattr(ssl, n)},
       "import ssl, warnings\nwarnings.simplefilter('ignore')\nout = {n: int(getattr(ssl, n)) for n in " + repr(SSLC) + " if hasattr(ssl, n)}")
check("ssl's enums and flags", [int(ssl.VerifyMode.CERT_REQUIRED), int(ssl.Options.OP_NO_COMPRESSION), ssl.AlertDescription(48).name,
                                int(ssl.SSLErrorNumber.SSL_ERROR_EOF), int(ssl.VerifyFlags.VERIFY_X509_STRICT), ssl.HAS_SSLv2,
                                ssl.CHANNEL_BINDING_TYPES, ssl.socket_error is OSError, len(ssl.OPENSSL_VERSION_INFO)],
      [2, 131072, "ALERT_DESCRIPTION_UNKNOWN_CA", 8, 32, False, ["tls-unique"], True, 5])
dvp = ssl.get_default_verify_paths()
check("get_default_verify_paths", [type(dvp).__name__, dvp._fields[:2], dvp.openssl_cafile_env, dvp.openssl_capath_env],
      ["DefaultVerifyPaths", ("cafile", "capath"), "SSL_CERT_FILE", "SSL_CERT_DIR"])

import hashlib
check("hashlib.scrypt: RFC 7914's vectors",
      [hashlib.scrypt(b"", salt=b"", n=16, r=1, p=1, dklen=64).hex(),
       hashlib.scrypt(b"password", salt=b"NaCl", n=1024, r=8, p=16, dklen=64).hex(),
       hashlib.scrypt(b"pleaseletmein", salt=b"SodiumChloride", n=16384, r=8, p=1, dklen=64).hex()],
      ["77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906",
       "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640",
       "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887"])
check("hashlib.scrypt's checks", [raises(hashlib.scrypt, b"x", salt=b"y", n=3, r=1, p=1), raises(hashlib.scrypt, b"x", salt=b"y", n=16, r=1, p=1, dklen=0),
                                  raises(hashlib.scrypt, b"x", salt=b"y", n=2 ** 20, r=8, p=1),
                                  raises(hashlib.scrypt, b"x", salt=b"y", n=16, r=0, p=1),
                                  raises(hashlib.scrypt, b"x", salt=b"y", n=16, r=1, p=1, maxmem=-1),
                                  raises(hashlib.scrypt, "x", salt=b"y", n=16, r=1, p=1),
                                  raises(hashlib.scrypt, b"x", salt=b"y", n=16, r=1),
                                  len(hashlib.scrypt(memoryview(b"pw"), salt=bytearray(b"s"), n=2, r=1, p=1, dklen=10))],
      [["ValueError", "n must be a power of 2."], ["ValueError", "dklen must be greater than 0 and smaller than 2147483647"],
       ["ValueError", "[digital envelope routines] memory limit exceeded"],
       ["ValueError", "Invalid parameter combination for n, r, p, maxmem."],
       ["ValueError", "maxmem must be positive and smaller than 2147483647"],
       ["TypeError", "a bytes-like object is required, not 'str'"], ["TypeError", "p is required and must be an unsigned int"], 10])
check("hashlib.pbkdf2_hmac: RFC 6070", hashlib.pbkdf2_hmac("sha1", b"password", b"salt", 1, 20).hex(),
      "0c60c80f961f0e71f3a9b524af6012062fe037a6")
import functools
import abc
check("functools.get_cache_token", [functools.get_cache_token() == abc.get_cache_token(), callable(functools.get_cache_token)],
      [True, True])

import locale
if linux and hasattr(locale, "textdomain"):
    check("locale's message catalogs", [locale.textdomain(None), locale.gettext("hello"), locale.dgettext(None, "x"),
                                        locale.dcgettext(None, "y", locale.LC_MESSAGES), locale.bindtextdomain("ny118", TMP),
                                        locale.bindtextdomain("ny118", None), locale.bind_textdomain_codeset("ny118", None),
                                        locale.bind_textdomain_codeset("ny118", "UTF-8"), locale.textdomain("ny118"),
                                        locale.textdomain("messages")],
          ["messages", "hello", "x", "y", TMP, TMP, None, "UTF-8", "ny118", "messages"])
    check("locale's catalog errors", [raises(locale.gettext, 5), raises(locale.bindtextdomain, "", None), raises(locale.dgettext, 1, "x")],
          [["TypeError", "gettext() argument must be str, not int"], ["Error", "domain must be a non-empty string"],
           ["TypeError", "dgettext() argument 1 must be str or None, not int"]])

import codecs
check("codecs.utf_32_ex_decode", [codecs.utf_32_ex_decode(codecs.BOM_UTF32_BE + "ab".encode("utf-32-be")),
                                  codecs.utf_32_ex_decode("ab".encode("utf-32-le"), None, -1),
                                  codecs.utf_32_ex_decode(b"a\x00\x00", None, -1, False),
                                  codecs.utf_32_ex_decode(codecs.BOM_UTF32_LE + b"a", "strict", 0, False)],
      [("ab", 12, 1), ("ab", 8, -1), ("", 0, -1), ("", 4, -1)])
check("codecs.readbuffer_encode", [codecs.readbuffer_encode(b"abc"), codecs.readbuffer_encode("h\xe9"),
                                   codecs.readbuffer_encode(memoryview(b"xy")), codecs.readbuffer_encode(bytearray(b"q"))],
      [(b"abc", 3), (b"h\xc3\xa9", 3), (b"xy", 2), (b"q", 1)])
try:
    import _sqlite3
    if hasattr(_sqlite3, "enable_shared_cache"):   # 3.11
        import warnings
        import sqlite3
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            r = _sqlite3.enable_shared_cache(False)
            r2 = sqlite3.enable_shared_cache(False)
        check("_sqlite3.enable_shared_cache (sqlite3's warns)", [r, r2, [x.category.__name__ for x in w],
                                                                 raises(_sqlite3.enable_shared_cache)[0]],
              [None, None, ["DeprecationWarning"], "TypeError"])
except ImportError:
    pass

# ── select.epoll, selectors.EpollSelector ────────────────────────────────────
import select
import selectors
if linux:
    EP = ["EPOLLIN", "EPOLLOUT", "EPOLLPRI", "EPOLLERR", "EPOLLHUP", "EPOLLET", "EPOLLONESHOT", "EPOLLEXCLUSIVE", "EPOLLRDHUP",
          "EPOLLRDNORM", "EPOLLRDBAND", "EPOLLWRNORM", "EPOLLWRBAND", "EPOLLMSG", "EPOLL_CLOEXEC", "POLLRDNORM", "POLLRDBAND",
          "POLLWRNORM", "POLLWRBAND", "POLLMSG", "POLLRDHUP", "PIPE_BUF"]
    hcheck("select's constants", {n: getattr(select, n) for n in EP if hasattr(select, n)},
           "import select\nout = {n: getattr(select, n) for n in " + repr(EP) + " if hasattr(select, n)}")
    ep = select.epoll()
    r, w = os.pipe()
    ep.register(r, select.EPOLLIN)
    check("epoll", [ep.fileno() > 0, ep.closed, repr(ep).startswith("<select.epoll object"), raises(ep.register, r)[0],
                    ep.poll(0)], [True, False, True, "FileExistsError", []])
    os.write(w, b"x")
    check("epoll.poll", [ep.poll(1), ep.poll(timeout=0, maxevents=1), raises(ep.poll, 0, 0)],
          [[(r, select.EPOLLIN)], [(r, select.EPOLLIN)], ["ValueError", "maxevents must be greater than 0, got 0"]])
    ep.modify(r, select.EPOLLOUT)
    ep.unregister(r)
    check("epoll modify / unregister", [oserr(ep.unregister, r)[:2], oserr(ep.modify, 99999, 1)[:2]],
          [["FileNotFoundError", 2], ["OSError", 9]])
    ep.close()
    check("epoll closed", [ep.closed, raises(ep.fileno), raises(ep.poll), raises(select.epoll, -2)],
          [True, ["ValueError", "I/O operation on closed epoll object"], ["ValueError", "I/O operation on closed epoll object"],
           ["ValueError", "negative sizehint"]])
    with select.epoll() as e2:
        e3 = select.epoll.fromfd(os.dup(e2.fileno()))
        check("epoll.fromfd, a context manager", [type(e3).__name__, e3.closed], ["epoll", False])
        e3.close()
    sel = selectors.EpollSelector()
    k = sel.register(r, selectors.EVENT_READ, "data")
    check("EpollSelector", [isinstance(sel, selectors.BaseSelector), k.fd, k.data, [(x[0].fd, x[1]) for x in sel.select(0)],
                            sel.get_key(r).events, len(sel.get_map())],
          [True, r, "data", [(r, selectors.EVENT_READ)], selectors.EVENT_READ, 1])
    sel.unregister(r)
    check("EpollSelector after unregister", [sel.select(0), raises(sel.get_key, r)[0]], [[], "KeyError"])
    sel.close()
    os.close(r)
    os.close(w)

# ── what CPython's os has that this one still lacks ──────────────────────────
if posix:
    STILL_MISSING = set()   # (none left on Linux: tools/api_diff.py -m os)
    hn = host("out = sorted(n for n in dir(os) if not n.startswith('_'))")
    if hn != "NOHOST" and isinstance(hn, list):
        lacking = [n for n in hn if not hasattr(os, n) and n not in STILL_MISSING and n not in ("abc", "st", "sys", "GenericAlias",
                   "Mapping", "MutableMapping", "setns", "unshare") and not n.startswith("CLONE_")]
        check("every public name of the host's os", lacking, [])

# ── done ─────────────────────────────────────────────────────────────────────
shutil.rmtree(TMP, ignore_errors=True)
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT118 PASSED ===")
