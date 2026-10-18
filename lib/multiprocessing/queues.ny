# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/multiprocessing/queues.ny - Queue, SimpleQueue, JoinableQueue across
# processes (round 80).
#
# The queue lives on its creator's object server (lib/multiprocessing/
# managers.ny); an item is pickled when it is put (later changes to the
# object do not reach the queue, as in CPython) and unpickled by the getter,
# so anything picklable crosses. put(obj, block=True, timeout=None) /
# get(block=True, timeout=None) raise queue.Full / queue.Empty; qsize,
# empty, full, put_nowait, get_nowait, close, join_thread,
# cancel_join_thread; JoinableQueue adds task_done (ValueError when called
# too often) and join. A Queue pickles as its address, so it can be given to
# a Process or put in another queue. There is no feeder thread: put()
# returns once the server has the item.

import pickle
from queue import Empty, Full
from multiprocessing import managers as _mg

__all__ = ['Queue', 'SimpleQueue', 'JoinableQueue']


class Queue(object):

    def __init__(self, maxsize=0, *, ctx=None):
        if maxsize <= 0:
            maxsize = 0
        self._maxsize = maxsize
        self._ref = _mg._create("Queue", maxsize)
        self._closed = False

    def __reduce__(self):
        return (_from_ref, (type(self).__name__, self._ref, self._maxsize))

    def _check_closed(self):
        if self._closed:
            raise ValueError("Queue " + repr(self) + " is closed")

    def put(self, obj, block=True, timeout=None):
        self._check_closed()
        if timeout is not None and timeout < 0:
            timeout = 0
        self._ref.ocall("put", pickle.dumps(obj, 5), block, timeout)

    def get(self, block=True, timeout=None):
        self._check_closed()
        if timeout is not None and timeout < 0:
            timeout = 0
        return pickle.loads(self._ref.ocall("get", block, timeout))

    def qsize(self):
        return self._ref.ocall("qsize")

    def empty(self):
        return self._ref.ocall("qsize") == 0

    def full(self):
        return self._maxsize > 0 and self._ref.ocall("qsize") >= self._maxsize

    def get_nowait(self):
        return self.get(False)

    def put_nowait(self, obj):
        return self.put(obj, False)

    def close(self):
        self._closed = True

    def join_thread(self):
        assert self._closed, "Queue {0!r} not closed".format(self)

    def cancel_join_thread(self):
        pass

    def _put_many(self, objs):
        # several items in one round trip (Pool's tasks)
        self._ref.ocall("put_many", [pickle.dumps(o, 5) for o in objs])


class JoinableQueue(Queue):

    def task_done(self):
        self._ref.ocall("task_done")

    def join(self):
        self._ref.ocall("join")


class SimpleQueue(object):

    def __init__(self, *, ctx=None):
        self._ref = _mg._create("Queue", 0)
        self._closed = False

    def __reduce__(self):
        return (_from_ref, ("SimpleQueue", self._ref, 0))

    def close(self):
        self._closed = True

    def empty(self):
        return self._ref.ocall("qsize") == 0

    def get(self):
        if self._closed:
            raise ValueError("Queue is closed")
        return pickle.loads(self._ref.ocall("get", True, None))

    def put(self, obj):
        if self._closed:
            raise ValueError("Queue is closed")
        self._ref.ocall("put", pickle.dumps(obj, 5), True, None)


def _from_ref(kind, ref, maxsize):
    var cls = {"Queue": Queue, "JoinableQueue": JoinableQueue, "SimpleQueue": SimpleQueue}[kind]
    var q = object.__new__(cls)
    q._ref = ref
    q._closed = False
    if cls is not SimpleQueue:
        q._maxsize = maxsize
    return q
