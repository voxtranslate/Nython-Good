# nython: module    (a package: multiprocessing.process, .queues, .synchronize, .connection, .pool, ...)
# lib/multiprocessing - Python's multiprocessing (round 80): processes,
# their communication and synchronisation, shared memory, pools and
# managers, with CPython 3.11's API, on the spawn start method.
#
#     from multiprocessing import Process, Queue, Pool
#     def work(q, n):
#         q.put(n * n)
#     if __name__ == "__main__":
#         q = Queue()
#         ps = [Process(target=work, args=(q, i)) for i in range(4)]
#         for p in ps: p.start()
#         print(sorted(q.get() for p in ps))
#         for p in ps: p.join()
#         with Pool(4) as pool:
#             print(pool.map(abs, [-1, -2, 3]))
#
# Process, current_process, parent_process, active_children, cpu_count;
# Queue, SimpleQueue, JoinableQueue; Pipe (Connection: send/recv/poll/
# send_bytes/recv_bytes/close); Lock, RLock, Semaphore, BoundedSemaphore,
# Condition, Event, Barrier; Value, Array, RawValue, RawArray (shared memory)
# and multiprocessing.shared_memory.SharedMemory; Pool (map, imap,
# imap_unordered, starmap, apply_async, ... with work stealing between the
# workers) and pool.ThreadPool; Manager() (dict, list, Namespace, Queue,
# Lock, Value, ... on a server process) and managers.BaseManager with
# register(); connection.Listener/Client; get_context, get_start_method,
# set_start_method, get_all_start_methods, set_executable, freeze_support,
# ProcessError, BufferTooShort, TimeoutError, AuthenticationError.
#
# How it is built - see lib/multiprocessing/managers.ny: every Queue, Lock,
# Pipe, Event ... lives on an object server of the process that made it (a
# thread; a Manager's is a process), reached over a local socket with an
# HMAC challenge on the process tree's authkey; everything that crosses is
# pickled (lib/pickle.ny, CPython's format). Value/Array are a file mapped
# shared (mmap / CreateFileMapping). Children are spawned: the interpreter
# runs lib/multiprocessing/_spawn_main.ny, which runs the parent's main
# program as __mp_main__, so a target must be defined at the top level of a
# module or of the main program, and the main program's top level must sit
# under `if __name__ == "__main__":` - exactly CPython's spawn rules.
#
# Not here, honestly: the fork and forkserver start methods; sentinels as
# waitable OS handles (connection.wait polls); a feeder thread (put returns
# once the server holds the item); Lock/Queue objects keep living on their
# server until it exits; a Barrier's action runs in the process that gets
# index 0, after the barrier opens; a Pipe end held by a killed process is
# not closed for the reader; ctypes types are named by strings ("c_int").
# POSIX and Windows alike (TCP loopback instead of AF_UNIX on Windows; a
# child's output passed on by a thread of the parent there).

from multiprocessing import context as _ctx
from multiprocessing import process as _process
from multiprocessing.process import current_process, parent_process, active_children, Process
from multiprocessing.context import ProcessError, BufferTooShort, TimeoutError, AuthenticationError
from multiprocessing.queues import Queue, SimpleQueue, JoinableQueue
from multiprocessing.synchronize import Lock, RLock, Semaphore, BoundedSemaphore, Condition, Event, Barrier
from multiprocessing.connection import Pipe
from multiprocessing.sharedctypes import Value, Array, RawValue, RawArray

__all__ = ["Array", "AuthenticationError", "Barrier", "BoundedSemaphore", "BufferTooShort", "Condition",
           "Event", "JoinableQueue", "Lock", "Manager", "Pipe", "Pool", "Process", "ProcessError", "Queue",
           "RLock", "RawArray", "RawValue", "Semaphore", "SimpleQueue", "TimeoutError", "Value",
           "active_children", "allow_connection_pickling", "cpu_count", "current_process", "freeze_support",
           "get_all_start_methods", "get_context", "get_logger", "get_start_method", "log_to_stderr",
           "parent_process", "reducer", "set_executable", "set_forkserver_preload", "set_start_method"]

SUBDEBUG = 5
SUBWARNING = 25

_default = _ctx._default_context


def cpu_count():
    """Returns the number of CPUs in the system"""
    var num = os_cpu_count()
    if num is None or num < 1:
        raise NotImplementedError('cannot determine number of cpus')
    return num


def Pool(processes=None, initializer=None, initargs=(), maxtasksperchild=None):
    """Returns a process pool object"""
    from multiprocessing.pool import Pool as _Pool
    return _Pool(processes, initializer, initargs, maxtasksperchild)


def Manager():
    """Returns a manager associated with a running server process"""
    from multiprocessing.managers import SyncManager
    var m = SyncManager()
    m.start()
    return m


def get_context(method=None):
    return _default.get_context(method)


def get_start_method(allow_none=False):
    return _default.get_start_method(allow_none)


def set_start_method(method, force=False):
    return _default.set_start_method(method, force)


def get_all_start_methods():
    return _default.get_all_start_methods()


def set_executable(executable):
    from multiprocessing.spawn import set_executable as _se
    _se(executable)


def freeze_support():
    pass


def set_forkserver_preload(module_names):
    pass


def allow_connection_pickling():
    pass


def get_logger():
    return _default.get_logger()


def log_to_stderr(level=None):
    return _default.log_to_stderr(level)


import pickle as reducer
