# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/resource.ny - Python's resource module (round 83): resource limits
# and usage of this process. POSIX only: on Windows `import resource`
# raises ModuleNotFoundError, as CPython's does.
#
#     import resource
#     soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
#     resource.setrlimit(resource.RLIMIT_CORE, (0, hard))
#     ru = resource.getrusage(resource.RUSAGE_SELF); ru.ru_maxrss, ru.ru_utime
#
# getrlimit(resource) -> (soft, hard); setrlimit(resource, (soft, hard));
# prlimit(pid, resource[, limits]) (Linux) -> the old (soft, hard);
# getrusage(who) -> struct_rusage (ru_utime, ru_stime as floats, ru_maxrss
# ... ru_nivcsw; a tuple-like structure sequence, indexable as CPython's);
# getpagesize(); error (OSError); RLIM_INFINITY (-1 on Linux, as CPython
# gives it); the RLIMIT_* and RUSAGE_* constants of the platform.
#
# Not here: nothing of CPython's module.

if not _sys_platform_posix():
    raise ModuleNotFoundError("No module named 'resource'", name="resource")

error = OSError


def _load():
    var g = globals()
    for pair in _sys_consts("resource"):
        g[pair[0]] = pair[1]


_load()
del _load


class struct_rusage(_NyStructSeq):
    __module__ = "resource"
    _ny_qual = "resource.struct_rusage"
    _ny_names = ("ru_utime", "ru_stime", "ru_maxrss", "ru_ixrss", "ru_idrss", "ru_isrss",
                 "ru_minflt", "ru_majflt", "ru_nswap", "ru_inblock", "ru_oublock",
                 "ru_msgsnd", "ru_msgrcv", "ru_nsignals", "ru_nvcsw", "ru_nivcsw")
    n_sequence_fields = 16
    n_fields = 16
    n_unnamed_fields = 0


def _limits(limits):
    var t = None
    try:
        t = tuple(limits)
    except TypeError:
        raise ValueError("expected a tuple of 2 integers") from None
    if len(t) != 2:
        raise ValueError("expected a tuple of 2 integers")
    for v in t:
        if not isinstance(v, int):
            raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")
    return t


def getrlimit(resource, /):
    return tuple(_sys_getrlimit(resource))


def setrlimit(resource, limits, /):
    _ny_sys_audit("resource.setrlimit", resource, limits)   # round 86: CPython's events
    var t = _limits(limits)
    _sys_setrlimit(resource, t[0], t[1])


def prlimit(pid, resource, limits=None, /):
    _ny_sys_audit("resource.prlimit", pid, resource, limits)
    if limits is None:
        return tuple(_sys_prlimit(pid, resource, 0, 0, 0))
    var t = _limits(limits)
    return tuple(_sys_prlimit(pid, resource, 1, t[0], t[1]))


def getrusage(who, /):
    return struct_rusage(_sys_getrusage(who))


def getpagesize():
    return _sys_getpagesize()
