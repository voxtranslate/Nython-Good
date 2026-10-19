// NyPreludePosix.cpp - the rest of CPython's posix module (nt on Windows) in
// the prelude (round 85): what posixmodule.c has and the "os" chunk
// (NyPrelude.hpp) did not - statvfs, sysconf/pathconf/confstr and their
// name tables, extended attributes, the scheduler and sched_param,
// priorities, the uid/gid setters, getgrouplist, eventfd, memfd_create,
// pidfd_open, pipe2, lockf, posix_fadvise/posix_fallocate, splice,
// copy_file_range, getrandom, posix_spawn/posix_spawnp, wait3/wait4/waitid,
// register_at_fork (run around os.fork and os.forkpty), tcgetpgrp/tcsetpgrp,
// setns/unshare, abort, chroot, ctermid, device_encoding, nice, setpgrp,
// sync, fchdir, fdatasync and the constants; and what os.py adds over them:
// popen and its _wrap_close, the spawn* family, fwalk, getenvb, the
// supports_* sets.
//
// Loaded by the os chunk (_ny_load_chunk("posix")) when a program first
// imports os; its _ny_posix_extend(m) appends the (name, value) members.
// The natives are _ny_os_call's ops in src/builtins/os_posix.cpp. It is a
// unit of its own so that editing it rebuilds one file, not every file that
// includes NyPrelude.hpp. Prelude rule: locals are declared with var.
#include <string>

namespace nyrt {

const char* prelude_posix_source() {
    return R"NYPOSIXPRELUDE(
_ny_px_nt = os_name == "nt"
_ny_px_linux = os_platform() == "linux"

# CPython's posix (nt) module's public names: these members' __module__ is
# "posix", and lib/posix.ny re-exports exactly them
_ny_px_names = set("""CLD_CONTINUED CLD_DUMPED CLD_EXITED CLD_KILLED CLD_STOPPED CLD_TRAPPED CLONE_FILES CLONE_FS
CLONE_NEWCGROUP CLONE_NEWIPC CLONE_NEWNET CLONE_NEWNS CLONE_NEWPID CLONE_NEWTIME CLONE_NEWUSER CLONE_NEWUTS
CLONE_SIGHAND CLONE_SYSVSEM CLONE_THREAD CLONE_VM DirEntry EFD_CLOEXEC EFD_NONBLOCK EFD_SEMAPHORE EX_CANTCREAT
EX_CONFIG EX_DATAERR EX_IOERR EX_NOHOST EX_NOINPUT EX_NOPERM EX_NOUSER EX_OK EX_OSERR EX_OSFILE EX_PROTOCOL
EX_SOFTWARE EX_TEMPFAIL EX_UNAVAILABLE EX_USAGE F_LOCK F_OK F_TEST F_TLOCK F_ULOCK GRND_NONBLOCK GRND_RANDOM
MFD_ALLOW_SEALING MFD_CLOEXEC MFD_HUGETLB MFD_HUGE_16GB MFD_HUGE_16MB MFD_HUGE_1GB MFD_HUGE_1MB MFD_HUGE_256MB
MFD_HUGE_2GB MFD_HUGE_2MB MFD_HUGE_32MB MFD_HUGE_512KB MFD_HUGE_512MB MFD_HUGE_64KB MFD_HUGE_8MB MFD_HUGE_MASK
MFD_HUGE_SHIFT NGROUPS_MAX O_ACCMODE O_APPEND O_ASYNC O_CLOEXEC O_CREAT O_DIRECT O_DIRECTORY O_DSYNC O_EXCL
O_FSYNC O_LARGEFILE O_NDELAY O_NOATIME O_NOCTTY O_NOFOLLOW O_NONBLOCK O_PATH O_RDONLY O_RDWR O_RSYNC O_SYNC
O_TMPFILE O_TRUNC O_WRONLY POSIX_FADV_DONTNEED POSIX_FADV_NOREUSE POSIX_FADV_NORMAL POSIX_FADV_RANDOM
POSIX_FADV_SEQUENTIAL POSIX_FADV_WILLNEED POSIX_SPAWN_CLOSE POSIX_SPAWN_DUP2 POSIX_SPAWN_OPEN PRIO_PGRP
PRIO_PROCESS PRIO_USER P_ALL P_PGID P_PID P_PIDFD RTLD_DEEPBIND RTLD_GLOBAL RTLD_LAZY RTLD_LOCAL RTLD_NODELETE
RTLD_NOLOAD RTLD_NOW RWF_APPEND RWF_DSYNC RWF_HIPRI RWF_NOWAIT RWF_SYNC R_OK SCHED_BATCH SCHED_FIFO SCHED_IDLE
SCHED_OTHER SCHED_RESET_ON_FORK SCHED_RR SEEK_DATA SEEK_HOLE SPLICE_F_MORE SPLICE_F_MOVE SPLICE_F_NONBLOCK
ST_APPEND ST_MANDLOCK ST_NOATIME ST_NODEV ST_NODIRATIME ST_NOEXEC ST_NOSUID ST_RDONLY ST_RELATIME
ST_SYNCHRONOUS ST_WRITE TMP_MAX WCONTINUED WCOREDUMP WEXITED WEXITSTATUS WIFCONTINUED WIFEXITED WIFSIGNALED
WIFSTOPPED WNOHANG WNOWAIT WSTOPPED WSTOPSIG WTERMSIG WUNTRACED W_OK XATTR_CREATE XATTR_REPLACE XATTR_SIZE_MAX
X_OK abort access chdir chmod chown chroot close closerange confstr confstr_names copy_file_range cpu_count
ctermid device_encoding dup dup2 environ error eventfd eventfd_read eventfd_write execv execve fchdir fchmod
fchown fdatasync fork forkpty fpathconf fspath fstat fstatvfs fsync ftruncate get_blocking get_inheritable
get_terminal_size getcwd getcwdb getegid geteuid getgid getgrouplist getgroups getloadavg getlogin getpgid
getpgrp getpid getppid getpriority getrandom getresgid getresuid getsid getuid getxattr initgroups isatty kill
killpg lchown link listdir listxattr lockf login_tty lseek lstat major makedev memfd_create minor mkdir mkfifo
mknod nice open openpty pathconf pathconf_names pidfd_open pipe pipe2 posix_fadvise posix_fallocate
posix_spawn posix_spawnp pread preadv putenv pwrite pwritev read readlink readv register_at_fork remove
removexattr rename replace rmdir scandir sched_get_priority_max sched_get_priority_min sched_getaffinity
sched_getparam sched_getscheduler sched_param sched_rr_get_interval sched_setaffinity sched_setparam
sched_setscheduler sched_yield sendfile set_blocking set_inheritable setegid seteuid setgid setgroups setns
setpgid setpgrp setpriority setregid setresgid setresuid setreuid setsid setuid setxattr splice stat
stat_result statvfs statvfs_result strerror symlink sync sysconf sysconf_names system tcgetpgrp tcsetpgrp
terminal_size times times_result truncate ttyname umask uname uname_result unlink unsetenv unshare urandom
utime wait wait3 wait4 waitid waitid_result waitpid waitstatus_to_exitcode write writev""".split())

def _ny_px_int(v):
    # an int argument as CPython's converters take it (__index__, no float)
    if isinstance(v, int):
        return int(v)
    if hasattr(type(v), "__index__"):
        return v.__index__()
    raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")

def _ny_px_fildes(fd):
    # a file descriptor: an int, or an object with fileno() (CPython's
    # PyObject_AsFileDescriptor)
    if not isinstance(fd, int) and hasattr(fd, "fileno"):
        fd = fd.fileno()
    if not isinstance(fd, int) and not hasattr(type(fd), "__index__"):
        raise TypeError("argument must be an int, or have a fileno() method.")
    var n = _ny_px_int(fd)
    if n < 0:
        raise ValueError("file descriptor cannot be a negative integer (" + str(n) + ")")
    return n

def _ny_px_path_or_fd(path):
    if isinstance(path, int) and not isinstance(path, bool):
        return path
    return _ny_os_str(path)

def _ny_px_ignored(e, obj):
    # an exception a callback raised, reported and ignored (CPython's
    # PyErr_WriteUnraisable): the program's sys.unraisablehook, or the default
    if not _ny_unraisable(e, None, obj):
        _ny_unraisablehook(_NyUnraisableHookArgs((type(e), e, getattr(e, "__traceback__", None), None, obj)))

# ── result types ─────────────────────────────────────────────────────────
class statvfs_result(_NyStructSeq):
    __module__ = "os"
    _ny_qual = "os.statvfs_result"
    _ny_names = ("f_bsize", "f_frsize", "f_blocks", "f_bfree", "f_bavail", "f_files", "f_ffree", "f_favail",
                 "f_flag", "f_namemax")
    _ny_extra = ("f_fsid",)
    _ny_exact = False
    n_sequence_fields = 10
    n_fields = 11
    n_unnamed_fields = 0
_ny_px_statvfs_result = statvfs_result
del statvfs_result

class waitid_result(_NyStructSeq):
    __module__ = "posix"
    _ny_qual = "posix.waitid_result"
    _ny_names = ("si_pid", "si_uid", "si_signo", "si_status", "si_code")
    n_sequence_fields = 5
    n_fields = 5
    n_unnamed_fields = 0
_ny_px_waitid_result = waitid_result
del waitid_result

class sched_param(_NyStructSeq):
    """Currently has only one field: sched_priority"""
    __module__ = "posix"
    _ny_qual = "posix.sched_param"
    _ny_names = ("sched_priority",)
    n_sequence_fields = 1
    n_fields = 1
    n_unnamed_fields = 0
    def __new__(cls, *args, **kw):
        return object.__new__(cls)
    def __init__(self, *args, **kw):
        if len(args) + len(kw) > 1:
            raise TypeError("sched_param() takes at most 1 argument (" + str(len(args) + len(kw)) + " given)")
        var p = None
        if args:
            p = args[0]
        elif "sched_priority" in kw:
            p = kw["sched_priority"]
        elif kw:
            raise TypeError("sched_param() got an unexpected keyword argument '" + list(kw)[0] + "'")
        else:
            raise TypeError("sched_param() missing required argument 'sched_priority' (pos 1)")
        _NyStructSeq.__init__(self, (p,))
    def __reduce__(self):
        return (type(self), (self.sched_priority,))
_ny_px_sched_param = sched_param
del sched_param

def _ny_px_priority_of(param, what):
    if not isinstance(param, _ny_px_sched_param):
        raise TypeError(what + " must have a sched_param object")
    return _ny_px_int(param.sched_priority)

# ── register_at_fork: the callbacks os.fork runs ─────────────────────────
_ny_px_atfork = ([], [], [])     # before (last registered runs first), after_in_child, after_in_parent

def _ny_px_register_at_fork(*, before=None, after_in_child=None, after_in_parent=None):
    if before is None and after_in_child is None and after_in_parent is None:
        raise TypeError("At least one argument is required.")
    for pair in (("before", before), ("after_in_child", after_in_child), ("after_in_parent", after_in_parent)):
        if pair[1] is not None and not callable(pair[1]):
            raise TypeError("'" + pair[0] + "' must be callable, not " + type(pair[1]).__name__)
    if before is not None:
        _ny_px_atfork[0].append(before)
    if after_in_child is not None:
        _ny_px_atfork[1].append(after_in_child)
    if after_in_parent is not None:
        _ny_px_atfork[2].append(after_in_parent)

def _ny_px_run_atfork(which):
    var fs = list(_ny_px_atfork[which])
    if which == 0:
        fs.reverse()
    for f in fs:
        try:
            f()
        except BaseException as e:
            _ny_px_ignored(e, f)

def _ny_px_fork():
    _ny_sys_audit("os.fork")
    _ny_px_run_atfork(0)
    var pid = 0
    try:
        pid = _sys_fork()
    except BaseException:
        _ny_px_run_atfork(2)
        raise
    _ny_px_run_atfork(1 if pid == 0 else 2)
    return pid

def _ny_px_forkpty():
    _ny_sys_audit("os.forkpty")
    _ny_px_run_atfork(0)
    var r = None
    try:
        r = tuple(_sys_forkpty())
    except BaseException:
        _ny_px_run_atfork(2)
        raise
    _ny_px_run_atfork(1 if r[0] == 0 else 2)
    return r

# ── the functions ────────────────────────────────────────────────────────
def _ny_px_abort():
    _ny_os_call("abort")

def _ny_px_chroot(path):
    _ny_os_call("chroot", _ny_os_str(path))

def _ny_px_ctermid():
    return _ny_os_call("ctermid")

def _ny_px_device_encoding(fd):
    # UTF-8 for a terminal (Nython is always in UTF-8 mode), else None
    if _ny_os_isatty(_ny_px_int(fd)):
        return "UTF-8"
    return None

def _ny_px_fchdir(fd):
    _ny_sys_audit("os.chdir", fd)   # round 86
    _ny_os_call("fchdir", _ny_px_fildes(fd))

def _ny_px_fdatasync(fd):
    _ny_os_call("fdatasync", _ny_px_fildes(fd))

def _ny_px_sync():
    _ny_os_call("sync")

def _ny_px_setpgrp():
    _ny_os_call("setpgrp")

def _ny_px_nice(increment):
    return _ny_os_call("nice", _ny_px_int(increment))

def _ny_px_getpriority(which, who):
    return _ny_os_call("getpriority", _ny_px_int(which), _ny_px_int(who))

def _ny_px_setpriority(which, who, priority):
    _ny_os_call("setpriority", _ny_px_int(which), _ny_px_int(who), _ny_px_int(priority))

def _ny_px_id_setter(op, n):
    def f(*ids):
        if len(ids) != n:
            raise TypeError(op + " expected " + str(n) + " argument" + ("s" if n != 1 else "") + ", got " + str(len(ids)))
        _ny_os_call(op, *[_ny_px_int(i) for i in ids])
    f.__name__ = op
    f.__qualname__ = op
    return f

def _ny_px_getresuid():
    return _ny_os_call("getresuid")

def _ny_px_getresgid():
    return _ny_os_call("getresgid")

def _ny_px_setgroups(groups):
    if isinstance(groups, (str, bytes)) or not hasattr(type(groups), "__iter__"):
        raise TypeError("setgroups argument must be a sequence")
    _ny_os_call("setgroups", [_ny_px_int(g) for g in groups])

def _ny_px_initgroups(username, gid):
    _ny_os_call("initgroups", _ny_os_str(username), _ny_px_int(gid))

def _ny_px_getgrouplist(user, group):
    if not isinstance(user, str):
        raise TypeError("getgrouplist() argument 1 must be str, not " + type(user).__name__)
    return _ny_os_call("getgrouplist", user, _ny_px_int(group))

def _ny_px_tcgetpgrp(fd):
    return _ny_os_call("tcgetpgrp", _ny_px_int(fd))

def _ny_px_tcsetpgrp(fd, pgid):
    _ny_os_call("tcsetpgrp", _ny_px_int(fd), _ny_px_int(pgid))

def _ny_px_setns(fd, nstype=0):
    _ny_os_call("setns", _ny_px_fildes(fd), _ny_px_int(nstype))

def _ny_px_unshare(flags):
    _ny_os_call("unshare", _ny_px_int(flags))

# wait3 / wait4: (pid, status, resource.struct_rusage)
def _ny_px_rusage(r):
    import resource
    return resource.struct_rusage(tuple(r))

def _ny_px_wait3(options):
    var r = _ny_os_call("wait3", _ny_px_int(options))
    return (r[0], r[1], _ny_px_rusage(r[2]))

def _ny_px_wait4(pid, options):
    var r = _ny_os_call("wait4", _ny_px_int(pid), _ny_px_int(options))
    return (r[0], r[1], _ny_px_rusage(r[2]))

def _ny_px_waitid(idtype, id, options):
    var r = _ny_os_call("waitid", _ny_px_int(idtype), _ny_px_int(id), _ny_px_int(options))
    if r is None:
        return None
    return _ny_px_waitid_result(tuple(r))

# the scheduler
def _ny_px_sched_get_priority_max(policy):
    return _ny_os_call("sched_get_priority_max", _ny_px_int(policy))

def _ny_px_sched_get_priority_min(policy):
    return _ny_os_call("sched_get_priority_min", _ny_px_int(policy))

def _ny_px_sched_getscheduler(pid):
    return _ny_os_call("sched_getscheduler", _ny_px_int(pid))

def _ny_px_sched_setscheduler(pid, policy, param):
    _ny_os_call("sched_setscheduler", _ny_px_int(pid), _ny_px_int(policy), _ny_px_priority_of(param, "sched_setscheduler()"))

def _ny_px_sched_getparam(pid):
    return _ny_px_sched_param(_ny_os_call("sched_getparam", _ny_px_int(pid)))

def _ny_px_sched_setparam(pid, param):
    if not isinstance(param, _ny_px_sched_param):
        raise TypeError("must have a sched_param object")
    _ny_os_call("sched_setparam", _ny_px_int(pid), _ny_px_int(param.sched_priority))

def _ny_px_sched_rr_get_interval(pid):
    return _ny_os_call("sched_rr_get_interval", _ny_px_int(pid))

def _ny_px_sched_setaffinity(pid, mask):
    _ny_os_call("sched_setaffinity", _ny_px_int(pid), [_ny_px_int(c) for c in mask])

def _ny_px_sched_yield():
    _ny_os_call("sched_yield")

# sysconf / pathconf / confstr and their tables
_ny_px_tables = {}
def _ny_px_table(kind):
    var t = _ny_px_tables.get(kind)
    if t is None:
        t = {}
        for pair in _ny_os_call(kind + "_names"):
            t[pair[0]] = pair[1]
        _ny_px_tables[kind] = t
    return t

def _ny_px_sysconf(name):
    return _ny_os_call("sysconf", name)

def _ny_px_fpathconf(fd, name):
    return _ny_os_call("fpathconf", _ny_px_fildes(fd), name)

def _ny_px_pathconf(path, name):
    return _ny_os_call("pathconf", _ny_px_path_or_fd(path), name)

def _ny_px_confstr(name):
    return _ny_os_call("confstr", name)

def _ny_px_statvfs(path):
    var r = _ny_os_call("statvfs", _ny_px_path_or_fd(path))
    return _ny_px_statvfs_result(tuple(r))

def _ny_px_fstatvfs(fd):
    return _ny_px_statvfs_result(tuple(_ny_os_call("fstatvfs", _ny_px_fildes(fd))))

# descriptors
def _ny_px_pipe2(flags):
    return _ny_os_call("pipe2", _ny_px_int(flags))

def _ny_px_lockf(fd, command, length):
    _ny_sys_audit("os.lockf", fd, command, length)
    _ny_os_call("lockf", _ny_px_fildes(fd), _ny_px_int(command), _ny_px_int(length))

def _ny_px_posix_fadvise(fd, offset, length, advice):
    _ny_os_call("posix_fadvise", _ny_px_fildes(fd), _ny_px_int(offset), _ny_px_int(length), _ny_px_int(advice))

def _ny_px_posix_fallocate(fd, offset, length):
    _ny_os_call("posix_fallocate", _ny_px_fildes(fd), _ny_px_int(offset), _ny_px_int(length))

def _ny_px_off(v):
    return None if v is None else _ny_px_int(v)

def _ny_px_copy_file_range(src, dst, count, offset_src=None, offset_dst=None):
    return _ny_os_call("copy_file_range", _ny_px_fildes(src), _ny_px_fildes(dst), _ny_px_int(count),
                       _ny_px_off(offset_src), _ny_px_off(offset_dst), 0)

def _ny_px_splice(src, dst, count, offset_src=None, offset_dst=None, flags=0):
    return _ny_os_call("splice", _ny_px_fildes(src), _ny_px_fildes(dst), _ny_px_int(count),
                       _ny_px_off(offset_src), _ny_px_off(offset_dst), _ny_px_int(flags))

def _ny_px_memfd_create(name, flags=1):
    return _ny_os_call("memfd_create", _ny_os_str(name), _ny_px_int(flags))

def _ny_px_pidfd_open(pid, flags=0):
    return _ny_os_call("pidfd_open", _ny_px_int(pid), _ny_px_int(flags))

def _ny_px_eventfd(initval, flags=524288):
    return _ny_os_call("eventfd", _ny_px_int(initval), _ny_px_int(flags))

def _ny_px_eventfd_read(fd):
    return _ny_os_call("eventfd_read", _ny_px_fildes(fd))

def _ny_px_eventfd_write(fd, value):
    var v = _ny_px_int(value)
    if v < 0:
        raise ValueError("value must be positive")
    _ny_os_call("eventfd_write", _ny_px_fildes(fd), v)

def _ny_px_getrandom(size, flags=0):
    return _ny_os_call("getrandom", _ny_px_int(size), _ny_px_int(flags))

# extended attributes: a path, a descriptor (int) or, for listxattr, None
def _ny_px_attr(attribute):
    if isinstance(attribute, bytes):
        return attribute
    return _ny_os_str(attribute)

def _ny_px_getxattr(path, attribute, *, follow_symlinks=True):
    _ny_sys_audit("os.getxattr", path, attribute)
    return _ny_os_call("getxattr", _ny_px_path_or_fd(path), _ny_px_attr(attribute), follow_symlinks)

def _ny_px_setxattr(path, attribute, value, flags=0, *, follow_symlinks=True):
    _ny_sys_audit("os.setxattr", path, attribute, value, flags)
    if not isinstance(value, (bytes, bytearray)):
        value = _ny_bytes_like(value)
    _ny_os_call("setxattr", _ny_px_path_or_fd(path), _ny_px_attr(attribute), bytes(value), _ny_px_int(flags), follow_symlinks)

def _ny_px_listxattr(path=None, *, follow_symlinks=True):
    _ny_sys_audit("os.listxattr", "." if path is None else path)
    return _ny_os_call("listxattr", None if path is None else _ny_px_path_or_fd(path), follow_symlinks)

def _ny_px_removexattr(path, attribute, *, follow_symlinks=True):
    _ny_sys_audit("os.removexattr", path, attribute)
    _ny_os_call("removexattr", _ny_px_path_or_fd(path), _ny_px_attr(attribute), follow_symlinks)

# posix_spawn / posix_spawnp (CPython's argument checks and messages)
def _ny_px_sigs(v, what):
    if v is None:
        return None
    try:
        return [_ny_px_int(s) for s in v]
    except TypeError:
        raise TypeError(what + " must be an iterable of signal numbers")

def _ny_px_spawn(fname, path, argv, env, file_actions, setpgroup, resetids, setsid, setsigmask, setsigdef, scheduler, use_path):
    var p = _ny_os_str(path)
    if not isinstance(argv, (list, tuple)):
        raise TypeError(fname + ": argv must be a tuple or list")
    if len(argv) == 0:
        raise ValueError(fname + ": argv must not be empty")
    var args = [_ny_os_str(a) for a in argv]
    if args[0] == "":
        raise ValueError(fname + ": argv first element cannot be empty")
    var envl = None
    if env is not None:
        if not hasattr(env, "keys"):
            raise TypeError(fname + ": environment must be a mapping object")
        envl = []
        for k in env.keys():
            var ks = _ny_os_str(k)
            if ks == "" or "=" in ks:
                raise ValueError("illegal environment variable name")
            envl.append(ks + "=" + _ny_os_str(env[k]))
    var acts = None
    if file_actions is not None:
        acts = []
        for a in file_actions:
            if not isinstance(a, tuple) or len(a) == 0:
                raise TypeError("Each file_actions element must be a non-empty tuple")
            var tag = a[0]
            if tag == 0:
                if len(a) != 5:
                    raise TypeError("A open file_action tuple must have 5 elements")
                acts.append((0, _ny_px_int(a[1]), _ny_os_str(a[2]), _ny_px_int(a[3]), _ny_px_int(a[4])))
            elif tag == 1:
                if len(a) != 2:
                    raise TypeError("A close file_action tuple must have 2 elements")
                acts.append((1, _ny_px_int(a[1])))
            elif tag == 2:
                if len(a) != 3:
                    raise TypeError("A dup2 file_action tuple must have 3 elements")
                acts.append((2, _ny_px_int(a[1]), _ny_px_int(a[2])))
            else:
                raise TypeError("Unknown file_actions identifier")
    var sch = None
    if scheduler is not None:
        if not isinstance(scheduler, tuple) or len(scheduler) != 2:
            raise TypeError(fname + ": scheduler must be a tuple or None")
        sch = (None if scheduler[0] is None else _ny_px_int(scheduler[0]), _ny_px_priority_of(scheduler[1], fname + ": scheduler"))
    _ny_sys_audit("os.posix_spawn", path, argv, env)
    return _ny_os_call("posix_spawn", p, args, envl, acts, None if setpgroup is None else _ny_px_int(setpgroup),
                       bool(resetids), bool(setsid), _ny_px_sigs(setsigmask, "setsigmask"),
                       _ny_px_sigs(setsigdef, "setsigdef"), sch, use_path)

def _ny_px_posix_spawn(path, argv, env, *, file_actions=None, setpgroup=None, resetids=False, setsid=False,
                       setsigmask=(), setsigdef=(), scheduler=None):
    return _ny_px_spawn("posix_spawn", path, argv, env, file_actions, setpgroup, resetids, setsid,
                        setsigmask, setsigdef, scheduler, False)

def _ny_px_posix_spawnp(path, argv, env, *, file_actions=None, setpgroup=None, resetids=False, setsid=False,
                        setsigmask=(), setsigdef=(), scheduler=None):
    return _ny_px_spawn("posix_spawnp", path, argv, env, file_actions, setpgroup, resetids, setsid,
                        setsigmask, setsigdef, scheduler, True)

# ── os.py's own over them ────────────────────────────────────────────────
# os.popen: CPython's, over subprocess, with its _wrap_close
class _wrap_close:
    __module__ = "os"
    def __init__(self, stream, proc):
        self._stream = stream
        self._proc = proc
    def close(self):
        self._stream.close()
        var returncode = self._proc.wait()
        if returncode == 0:
            return None
        if _ny_px_nt:
            return returncode
        return returncode << 8
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.close()
    def __getattr__(self, name):
        return getattr(self._stream, name)
    def __iter__(self):
        return iter(self._stream)
_ny_px_wrap_close = _wrap_close
del _wrap_close

def _ny_px_popen(cmd, mode="r", buffering=-1):
    if not isinstance(cmd, str):
        raise TypeError("invalid cmd type (" + str(type(cmd)) + ", expected string)")
    if mode not in ("r", "w"):
        raise ValueError("invalid mode " + repr(mode))
    if buffering == 0 or buffering is None:
        raise ValueError("popen() does not support unbuffered streams")
    import subprocess
    var proc = None
    if mode == "r":
        proc = subprocess.Popen(cmd, shell=True, text=True, stdout=subprocess.PIPE, bufsize=buffering)
        return _ny_px_wrap_close(proc.stdout, proc)
    proc = subprocess.Popen(cmd, shell=True, text=True, stdin=subprocess.PIPE, bufsize=buffering)
    return _ny_px_wrap_close(proc.stdin, proc)

# os.spawn*: os.py's, on fork + exec (P_WAIT: the exit code, or -signal;
# P_NOWAIT: the pid; a program that cannot be run exits 127)
def _ny_px_spawnvef(mode, file, args, env, func):
    if not isinstance(args, (tuple, list)):
        raise TypeError("argv must be a tuple or a list")
    if not args or not args[0]:
        raise ValueError("argv first element cannot be empty")
    var pid = _ny_px_fork()
    if not pid:
        try:
            if env is None:
                func(file, args)
            else:
                func(file, args, env)
        except BaseException:
            _ny_os__exit(127)
        _ny_os__exit(127)
    if mode == 1:
        return pid
    while True:
        var r = tuple(_sys_waitpid(pid, 0))
        var sts = r[1]
        if _sys_wstatus("stopped", sts):
            continue
        if _sys_wstatus("exited", sts):
            return _sys_wstatus("exitstatus", sts)
        if _sys_wstatus("signaled", sts):
            return -_sys_wstatus("termsig", sts)
        raise OSError("Not stopped, signaled or exited???")

def _ny_px_execv(path, args):
    _ny_sys_audit("os.exec", path, args, None)   # round 86
    _sys_execv(_ny_os_str(path), [_ny_os_str(a) for a in args], None)

def _ny_px_execve(path, args, env):
    _ny_sys_audit("os.exec", path, args, env)   # round 86
    _sys_execv(_ny_os_str(path), [_ny_os_str(a) for a in args],
               [_ny_os_str(k) + "=" + _ny_os_str(env[k]) for k in env])

def _ny_px_execvpe(file, args, env=None):
    if _ny_osp_dirname(file):
        if env is None:
            _ny_px_execv(file, args)
        else:
            _ny_px_execve(file, args, env)
        return
    var last = None
    for d in _ny_os_get_exec_path(env):
        var full = _ny_osp_join(d, file)
        try:
            if env is None:
                _ny_px_execv(full, args)
            else:
                _ny_px_execve(full, args, env)
        except OSError as e:
            last = e
    if last is not None:
        raise last
    raise FileNotFoundError(2, "No such file or directory", file)

def _ny_px_spawnv(mode, file, args):
    return _ny_px_spawnvef(mode, file, args, None, _ny_px_execv)

def _ny_px_spawnve(mode, file, args, env):
    return _ny_px_spawnvef(mode, file, args, env, _ny_px_execve)

def _ny_px_spawnvp(mode, file, args):
    return _ny_px_spawnvef(mode, file, args, None, _ny_px_execvpe)

def _ny_px_spawnvpe(mode, file, args, env):
    return _ny_px_spawnvef(mode, file, args, env, _ny_px_execvpe)

def _ny_px_spawnl(mode, file, *args):
    return _ny_px_spawnv(mode, file, args)

def _ny_px_spawnle(mode, file, *args):
    return _ny_px_spawnve(mode, file, args[:-1], args[-1])

def _ny_px_spawnlp(mode, file, *args):
    return _ny_px_spawnvp(mode, file, args)

def _ny_px_spawnlpe(mode, file, *args):
    return _ny_px_spawnvpe(mode, file, args[:-1], args[-1])

def _ny_px_getenvb(key, default=None):
    return _ny_os_environb().get(key, default)

# os.fwalk: (dirpath, dirnames, filenames, dirfd), each directory opened as a
# descriptor for the time its tuple is in use (CPython's walks by dir_fd;
# Nython's os has no dir_fd, so the descriptor is opened by path)
def _ny_px_fwalk(top=".", topdown=True, onerror=None, *, follow_symlinks=False, dir_fd=None):
    if dir_fd is not None:
        raise NotImplementedError("fwalk: dir_fd unavailable on this platform")
    _ny_sys_audit("os.fwalk", top, topdown, onerror, follow_symlinks, dir_fd)
    var stack = [_ny_os_fspath(top)]
    var flags = 0o200000 | 0o2000000      # O_DIRECTORY | O_CLOEXEC (Linux values)
    while stack:
        var cur = stack.pop()
        if isinstance(cur, tuple):
            yield cur[0], cur[1], cur[2], cur[3]
            _ny_os_close(cur[3])
            continue
        var fd = -1
        try:
            if not follow_symlinks and cur != _ny_os_fspath(top) and _ny_osp_islink(cur):
                continue
            fd = _ny_os_open(cur, flags)
        except OSError as err:
            if onerror is not None:
                onerror(err)
            continue
        var dirs = []
        var nondirs = []
        try:
            for entry in _ny_os_scandir(cur):
                var isdir = False
                try:
                    isdir = entry.is_dir(follow_symlinks=follow_symlinks)
                except OSError:
                    isdir = False
                if isdir:
                    dirs.append(entry.name)
                else:
                    nondirs.append(entry.name)
        except OSError as err:
            _ny_os_close(fd)
            if onerror is not None:
                onerror(err)
            continue
        if topdown:
            try:
                yield cur, dirs, nondirs, fd
            finally:
                _ny_os_close(fd)
            for d in reversed(dirs):
                stack.append(_ny_osp_join(cur, d))
        else:
            stack.append((cur, dirs, nondirs, fd))
            for d in reversed(dirs):
                stack.append(_ny_osp_join(cur, d))

# ── the members ──────────────────────────────────────────────────────────
def _ny_posix_extend(m):
    var add = []
    var c = []
    if not _ny_px_nt:
        add = [("abort", _ny_px_abort), ("chroot", _ny_px_chroot), ("ctermid", _ny_px_ctermid),
               ("device_encoding", _ny_px_device_encoding), ("fchdir", _ny_px_fchdir),
               ("fdatasync", _ny_px_fdatasync), ("sync", _ny_px_sync), ("setpgrp", _ny_px_setpgrp),
               ("nice", _ny_px_nice), ("getpriority", _ny_px_getpriority), ("setpriority", _ny_px_setpriority),
               ("setuid", _ny_px_id_setter("setuid", 1)), ("setgid", _ny_px_id_setter("setgid", 1)),
               ("seteuid", _ny_px_id_setter("seteuid", 1)), ("setegid", _ny_px_id_setter("setegid", 1)),
               ("setreuid", _ny_px_id_setter("setreuid", 2)), ("setregid", _ny_px_id_setter("setregid", 2)),
               ("setgroups", _ny_px_setgroups), ("initgroups", _ny_px_initgroups),
               ("getgrouplist", _ny_px_getgrouplist), ("tcgetpgrp", _ny_px_tcgetpgrp),
               ("tcsetpgrp", _ny_px_tcsetpgrp), ("wait3", _ny_px_wait3), ("wait4", _ny_px_wait4),
               ("waitid", _ny_px_waitid), ("waitid_result", _ny_px_waitid_result),
               ("sched_get_priority_max", _ny_px_sched_get_priority_max),
               ("sched_get_priority_min", _ny_px_sched_get_priority_min), ("sched_yield", _ny_px_sched_yield),
               ("sched_param", _ny_px_sched_param),
               ("sysconf", _ny_px_sysconf), ("sysconf_names", _ny_px_table("sysconf")),
               ("fpathconf", _ny_px_fpathconf), ("pathconf", _ny_px_pathconf),
               ("pathconf_names", _ny_px_table("pathconf")), ("confstr", _ny_px_confstr),
               ("confstr_names", _ny_px_table("confstr")), ("statvfs", _ny_px_statvfs),
               ("fstatvfs", _ny_px_fstatvfs), ("statvfs_result", _ny_px_statvfs_result),
               ("lockf", _ny_px_lockf), ("posix_spawn", _ny_px_posix_spawn), ("posix_spawnp", _ny_px_posix_spawnp),
               ("register_at_fork", _ny_px_register_at_fork), ("fork", _ny_px_fork), ("forkpty", _ny_px_forkpty),
               ("spawnv", _ny_px_spawnv), ("spawnve", _ny_px_spawnve), ("spawnvp", _ny_px_spawnvp),
               ("spawnvpe", _ny_px_spawnvpe), ("spawnl", _ny_px_spawnl), ("spawnle", _ny_px_spawnle),
               ("spawnlp", _ny_px_spawnlp), ("spawnlpe", _ny_px_spawnlpe), ("getenvb", _ny_px_getenvb),
               ("fwalk", _ny_px_fwalk), ("P_WAIT", 0), ("P_NOWAIT", 1), ("P_NOWAITO", 1)]
        if _ny_px_linux:
            add = add + [("getresuid", _ny_px_getresuid), ("getresgid", _ny_px_getresgid),
                         ("setresuid", _ny_px_id_setter("setresuid", 3)), ("setresgid", _ny_px_id_setter("setresgid", 3)),
                         ("setns", _ny_px_setns), ("unshare", _ny_px_unshare),
                         ("sched_getscheduler", _ny_px_sched_getscheduler),
                         ("sched_setscheduler", _ny_px_sched_setscheduler),
                         ("sched_getparam", _ny_px_sched_getparam), ("sched_setparam", _ny_px_sched_setparam),
                         ("sched_rr_get_interval", _ny_px_sched_rr_get_interval),
                         ("sched_setaffinity", _ny_px_sched_setaffinity), ("pipe2", _ny_px_pipe2),
                         ("posix_fadvise", _ny_px_posix_fadvise), ("posix_fallocate", _ny_px_posix_fallocate),
                         ("copy_file_range", _ny_px_copy_file_range), ("splice", _ny_px_splice),
                         ("memfd_create", _ny_px_memfd_create), ("pidfd_open", _ny_px_pidfd_open),
                         ("eventfd", _ny_px_eventfd), ("eventfd_read", _ny_px_eventfd_read),
                         ("eventfd_write", _ny_px_eventfd_write), ("getrandom", _ny_px_getrandom),
                         ("getxattr", _ny_px_getxattr), ("setxattr", _ny_px_setxattr),
                         ("listxattr", _ny_px_listxattr), ("removexattr", _ny_px_removexattr)]
        c = _ny_os_call("posix_constants")
    else:
        add = [("device_encoding", _ny_px_device_encoding), ("P_WAIT", 0), ("P_NOWAIT", 1), ("P_NOWAITO", 3),
               ("P_DETACH", 4), ("P_OVERLAY", 2)]
    add.append(("popen", _ny_px_popen))
    add.append(("_wrap_close", _ny_px_wrap_close))
    var ft = type(_ny_posix_extend)
    var mod = "nt" if _ny_px_nt else "posix"
    for pair in add:
        m.append(pair)
    for pair in c:
        m.append(pair)
    # the supports_* sets (os.py): the functions that take a descriptor for
    # their path, a follow_symlinks= or effective_ids=; Nython's os has no
    # dir_fd (an empty set, as on a platform without the *at() calls)
    var have = {}
    for pair in m:
        have[pair[0]] = pair[1]
    # the os members the engines bind from the prelude by name
    # (NyRuntime.hpp os_python_members)
    var bound = {"stat": _ny_os_stat, "lstat": _ny_os_lstat, "fstat": _ny_os_fstat,
                 "get_terminal_size": _ny_os_get_terminal_size, "times": _ny_os_times, "uname": _ny_os_uname,
                 "listdir": _ny_os_listdir, "rename": _ny_os_rename, "replace": _ny_os_replace,
                 "mkdir": _ny_os_mkdir, "link": _ny_os_link}
    for n in bound:
        if n not in have:
            have[n] = bound[n]
        try:
            bound[n].__module__ = mod
        except (AttributeError, TypeError):
            pass
    def pick(names):
        var s = set()
        for n in names:
            var f = have.get(n)
            if f is not None:
                s.add(f)
        return s
    m.append(("supports_dir_fd", set()))
    m.append(("supports_effective_ids", pick(("access",)) if not _ny_px_nt else set()))
    # (CPython's lists, less what Nython's do not take: chdir/listdir/
    # scandir/chmod/utime/execve of a descriptor, link/utime's follow_symlinks)
    m.append(("supports_fd", pick(("chown", "pathconf", "stat", "statvfs", "truncate"))))
    m.append(("supports_follow_symlinks", pick(("access", "chown", "stat"))))
    # CPython's posix functions show posix as their module (pickles of them
    # name it: lib/posix.ny)
    # os.py's own (walk, popen, makedirs ...) "os", os.path's "posixpath"
    # (ntpath on Windows)
    for pair in m:
        if type(pair[1]) is not ft:
            continue
        var want = "os"
        if pair[0] in _ny_px_names:
            want = mod
        elif pair[0].startswith("path."):
            want = "ntpath" if _ny_px_nt else "posixpath"
        try:
            pair[1].__module__ = want
        except (AttributeError, TypeError):
            pass
)NYPOSIXPRELUDE";
}

} // namespace nyrt
