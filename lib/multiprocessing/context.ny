# nython: module    (import it by name: it runs in a module scope of its own)
# lib/multiprocessing/context.ny - start-method contexts (round 80). Nython
# starts processes one way, "spawn" (a fresh interpreter that re-runs the
# main program as __mp_main__): get_context() / get_context("spawn") give
# the context with every factory (Process, Queue, Pool, Lock, Value, ...);
# "fork" and "forkserver" are not available (ValueError, as CPython for a
# method the platform lacks), get_all_start_methods() is ["spawn"].

import os
import sys
from multiprocessing import process as _process

__all__ = []


class ProcessError(Exception):
    pass


class BufferTooShort(ProcessError):
    pass


class TimeoutError(ProcessError):
    pass


class AuthenticationError(ProcessError):
    pass


class BaseContext(object):

    ProcessError = ProcessError
    BufferTooShort = BufferTooShort
    TimeoutError = TimeoutError
    AuthenticationError = AuthenticationError

    current_process = staticmethod(_process.current_process)
    parent_process = staticmethod(_process.parent_process)
    active_children = staticmethod(_process.active_children)

    def cpu_count(self):
        """Returns the number of CPUs in the system"""
        var num = os.cpu_count()
        if num is None:
            raise NotImplementedError('cannot determine number of cpus')
        return num

    def Manager(self):
        from multiprocessing.managers import SyncManager
        var m = SyncManager()
        m.start()
        return m

    def Pipe(self, duplex=True):
        from multiprocessing.connection import Pipe
        return Pipe(duplex)

    def Lock(self):
        from multiprocessing.synchronize import Lock
        return Lock()

    def RLock(self):
        from multiprocessing.synchronize import RLock
        return RLock()

    def Condition(self, lock=None):
        from multiprocessing.synchronize import Condition
        return Condition(lock)

    def Semaphore(self, value=1):
        from multiprocessing.synchronize import Semaphore
        return Semaphore(value)

    def BoundedSemaphore(self, value=1):
        from multiprocessing.synchronize import BoundedSemaphore
        return BoundedSemaphore(value)

    def Event(self):
        from multiprocessing.synchronize import Event
        return Event()

    def Barrier(self, parties, action=None, timeout=None):
        from multiprocessing.synchronize import Barrier
        return Barrier(parties, action, timeout)

    def Queue(self, maxsize=0):
        from multiprocessing.queues import Queue
        return Queue(maxsize)

    def JoinableQueue(self, maxsize=0):
        from multiprocessing.queues import JoinableQueue
        return JoinableQueue(maxsize)

    def SimpleQueue(self):
        from multiprocessing.queues import SimpleQueue
        return SimpleQueue()

    def Pool(self, processes=None, initializer=None, initargs=(), maxtasksperchild=None):
        from multiprocessing.pool import Pool
        return Pool(processes, initializer, initargs, maxtasksperchild)

    def RawValue(self, typecode_or_type, *args):
        from multiprocessing.sharedctypes import RawValue
        return RawValue(typecode_or_type, *args)

    def RawArray(self, typecode_or_type, size_or_initializer):
        from multiprocessing.sharedctypes import RawArray
        return RawArray(typecode_or_type, size_or_initializer)

    def Value(self, typecode_or_type, *args, lock=True):
        from multiprocessing.sharedctypes import Value
        return Value(typecode_or_type, *args, lock=lock)

    def Array(self, typecode_or_type, size_or_initializer, *, lock=True):
        from multiprocessing.sharedctypes import Array
        return Array(typecode_or_type, size_or_initializer, lock=lock)

    def freeze_support(self):
        pass

    def get_logger(self):
        import logging
        return logging.getLogger("multiprocessing")

    def log_to_stderr(self, level=None):
        import logging
        var logger = logging.getLogger("multiprocessing")
        var handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter('[%(levelname)s/%(processName)s] %(message)s'))
        logger.addHandler(handler)
        if level:
            logger.setLevel(level)
        return logger

    def allow_connection_pickling(self):
        pass

    def set_executable(self, executable):
        from multiprocessing.spawn import set_executable
        set_executable(executable)

    def set_forkserver_preload(self, module_names):
        pass

    def get_context(self, method=None):
        if method is None:
            return self
        if method not in _concrete_contexts:
            raise ValueError('cannot find context for %r' % method)
        return _concrete_contexts[method]

    def get_start_method(self, allow_none=False):
        return self._name

    def set_start_method(self, method, force=False):
        raise ValueError('cannot set start method of concrete context')

    @property
    def reducer(self):
        import pickle
        return pickle

    def _check_available(self):
        pass


Process = _process.Process
SpawnProcess = _process.Process


class SpawnContext(BaseContext):
    _name = 'spawn'
    Process = _process.Process


class DefaultContext(BaseContext):
    Process = _process.Process

    def __init__(self, context):
        self._default_context = context
        self._actual_context = None

    def get_context(self, method=None):
        if method is None:
            if self._actual_context is None:
                self._actual_context = self._default_context
            return self._actual_context
        return BaseContext.get_context(self, method)

    def set_start_method(self, method, force=False):
        if self._actual_context is not None and not force:
            raise RuntimeError('context has already been set')
        if method is None and force:
            self._actual_context = None
            return
        self._actual_context = self.get_context(method)

    def get_start_method(self, allow_none=False):
        if self._actual_context is None:
            if allow_none:
                return None
            self._actual_context = self._default_context
        return self._actual_context._name

    def get_all_start_methods(self):
        return ['spawn']

    @property
    def _name(self):
        return self.get_start_method()


_concrete_contexts = {'spawn': SpawnContext()}
_default_context = DefaultContext(_concrete_contexts['spawn'])
