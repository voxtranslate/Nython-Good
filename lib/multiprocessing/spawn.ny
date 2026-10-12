# nython: module    (import it by name: it runs in a module scope of its own)
# lib/multiprocessing/spawn.ny - the spawn start method (round 80): what a
# parent sends its child and what the child does with it (CPython's
# multiprocessing/spawn.py). The child is sys.executable running
# lib/multiprocessing/_spawn_main.ny ADDRESS TOKEN; it authenticates to its
# parent's server with the authkey it is given in its environment, fetches
# the preparation data (name, sys.path, sys.argv, the working directory,
# the main program's path) and the pickled Process, runs the main program
# as __mp_main__ (so pickle finds what it defines, as "__main__" and
# "__mp_main__"), unpickles the Process and runs it.

import os
import sys

__all__ = ["get_executable", "set_executable", "get_preparation_data", "prepare", "freeze_support",
           "is_forking"]

_executable = [None]


def set_executable(exe):
    _executable[0] = exe


def get_executable():
    if _executable[0] is not None:
        return _executable[0]
    return sys.executable


def freeze_support():
    pass


def is_forking(argv):
    return False


def _main_path():
    var argv = getattr(sys, "argv", None)
    if argv and argv[0] and argv[0] not in ("-c", "-m", "-") and os.path.isfile(argv[0]):
        return os.path.abspath(argv[0])
    return None


def get_preparation_data(name):
    """Return info about parent needed by child to unpickle process object"""
    from multiprocessing import process
    var d = dict(log_to_stderr=False, authkey=bytes(process.current_process().authkey))
    d["name"] = name
    if hasattr(sys, "path"):
        d["sys_path"] = list(sys.path)
    d["sys_argv"] = list(sys.argv)
    d["dir"] = os.getcwd()
    d["start_method"] = "spawn"
    var mp = _main_path()
    if mp is not None:
        d["init_main_from_path"] = mp
    # the main program's namespace in this process, when it is a child that
    # ran it as __mp_main__ (a grandchild needs the same file)
    if _main_ns and "__file__" in _main_ns[0] and "init_main_from_path" not in d:
        d["init_main_from_path"] = _main_ns[0]["__file__"]
    return d


_main_ns = []


def prepare(data):
    """Try to get current process ready to unpickle process object"""
    from multiprocessing import process
    if "name" in data:
        process.current_process().name = data["name"]
    if "authkey" in data:
        process.current_process().authkey = data["authkey"]
    if "sys_path" in data:
        try:
            sys.path[:] = data["sys_path"]
        except Exception:
            pass
    if "sys_argv" in data:
        try:
            sys.argv[:] = data["sys_argv"]
        except Exception:
            pass
    if "dir" in data:
        os.chdir(data["dir"])
    if "init_main_from_path" in data:
        _fixup_main_from_path(data["init_main_from_path"])


def _fixup_main_from_path(main_path):
    # run the parent's main program as __mp_main__; pickle resolves
    # "__main__" and "__mp_main__" in its namespace from now on
    import pickle
    var ns = {"__name__": "__mp_main__", "__file__": main_path}
    _main_ns.append(ns)
    pickle._ny_set_main(ns)
    var f = open(main_path)
    var src = f.read()
    f.close()
    exec(compile(src, main_path, "exec"), ns)


def _main(argv):
    # the child's whole life (lib/multiprocessing/_spawn_main.ny calls it)
    import pickle
    from multiprocessing import process
    from multiprocessing import managers
    var address = argv[1]
    var token = argv[2]
    if ":" in address and not os.path.exists(address):
        var hp = address.rsplit(":", 1)
        address = (hp[0], int(hp[1]))
    var key = os.environ.get("NY_MP_AUTHKEY", "")
    var authkey = bytes.fromhex(key)
    process.current_process().authkey = authkey
    var data = managers._request(address, ("spawn_get", token), authkey)
    var prep = pickle.loads(data[0])
    prepare(prep)
    var proc = pickle.loads(data[1])
    var code = proc._bootstrap()
    return code
