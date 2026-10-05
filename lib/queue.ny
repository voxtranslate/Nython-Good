# nython: module    (import it by name: it runs in a module scope of its own)
# lib/queue.ny - Python's queue: synchronized queues for threads.
#
#     Queue(maxsize=0)          FIFO
#     LifoQueue(maxsize=0)      LIFO (a stack)
#     PriorityQueue(maxsize=0)  lowest first (a binary heap, as heapq)
#     SimpleQueue()             unbounded FIFO without task tracking
#     put(item, block=True, timeout=None), put_nowait, get(block, timeout),
#     get_nowait, qsize, empty, full, task_done, join, maxsize
#     Empty, Full
#
# CPython's queue.py over lib/threading.ny: one mutex shared by three
# conditions (not_empty, not_full, all_tasks_done), so a blocked put/get
# releases the GIL and wakes as soon as the other side acts; timeouts are
# measured on the monotonic clock. Subclasses may override _init/_qsize/
# _put/_get as with CPython. Queue's storage is collections.deque (O(1) at
# both ends); PriorityQueue's heap is written here (no heapq module yet),
# with heapq's sift algorithms, so equal priorities come out in the same
# order as CPython's.

import threading
import collections as _collections_mod

__all__ = ["Empty", "Full", "Queue", "PriorityQueue", "LifoQueue", "SimpleQueue"]


class Empty(Exception):
    """Exception raised by Queue.get(block=0)/get_nowait()."""
    pass


class Full(Exception):
    """Exception raised by Queue.put(block=0)/put_nowait()."""
    pass


class Queue:
    """Create a queue object with a given maximum size.

    If maxsize is <= 0, the queue size is infinite.
    """
    def __init__(self, maxsize=0):
        self.maxsize = maxsize
        self._init(maxsize)
        # mutex must be held whenever the queue is mutating.  All methods
        # that acquire mutex must release it before returning.  mutex
        # is shared between the three conditions, so acquiring and
        # releasing the conditions also acquires and releases mutex.
        self.mutex = threading.Lock()
        # Notify not_empty whenever an item is added to the queue; a
        # thread waiting to get is notified then.
        self.not_empty = threading.Condition(self.mutex)
        # Notify not_full whenever an item is removed from the queue;
        # a thread waiting to put is notified then.
        self.not_full = threading.Condition(self.mutex)
        # Notify all_tasks_done whenever the number of unfinished tasks
        # drops to zero; thread waiting to join() is notified to resume
        self.all_tasks_done = threading.Condition(self.mutex)
        self.unfinished_tasks = 0

    def task_done(self):
        """Indicate that a formerly enqueued task is complete.

        Used by Queue consumer threads.  For each get() used to fetch a task,
        a subsequent call to task_done() tells the queue that the processing
        on the task is complete.

        Raises a ValueError if called more times than there were items
        placed in the queue.
        """
        with self.all_tasks_done:
            var unfinished = self.unfinished_tasks - 1
            if unfinished <= 0:
                if unfinished < 0:
                    raise ValueError("task_done() called too many times")
                self.all_tasks_done.notify_all()
            self.unfinished_tasks = unfinished

    def join(self):
        """Blocks until all items in the Queue have been gotten and processed.

        The count of unfinished tasks goes up whenever an item is added to the
        queue. The count goes down whenever a consumer thread calls task_done()
        to indicate the item was retrieved and all work on it is complete.

        When the count of unfinished tasks drops to zero, join() unblocks.
        """
        with self.all_tasks_done:
            while self.unfinished_tasks:
                self.all_tasks_done.wait()

    def qsize(self):
        """Return the approximate size of the queue (not reliable!)."""
        with self.mutex:
            return self._qsize()

    def empty(self):
        """Return True if the queue is empty, False otherwise (not reliable!)."""
        with self.mutex:
            return not self._qsize()

    def full(self):
        """Return True if the queue is full, False otherwise (not reliable!)."""
        with self.mutex:
            return 0 < self.maxsize and self.maxsize <= self._qsize()

    def put(self, item, block=true, timeout=none):
        """Put an item into the queue.

        If optional args 'block' is true and 'timeout' is None (the default),
        block if necessary until a free slot is available. If 'timeout' is
        a non-negative number, it blocks at most 'timeout' seconds and raises
        the Full exception if no free slot was available within that time.
        Otherwise ('block' is false), put an item on the queue if a free slot
        is immediately available, else raise the Full exception ('timeout'
        is ignored in that case).
        """
        with self.not_full:
            if self.maxsize > 0:
                if not block:
                    if self._qsize() >= self.maxsize:
                        raise Full()
                elif timeout is none:
                    while self._qsize() >= self.maxsize:
                        self.not_full.wait()
                elif timeout < 0:
                    raise ValueError("'timeout' must be a non-negative number")
                else:
                    var endtime = monotonic() + timeout
                    while self._qsize() >= self.maxsize:
                        var remaining = endtime - monotonic()
                        if remaining <= 0.0:
                            raise Full()
                        self.not_full.wait(remaining)
            self._put(item)
            self.unfinished_tasks = self.unfinished_tasks + 1
            self.not_empty.notify()

    def get(self, block=true, timeout=none):
        """Remove and return an item from the queue.

        If optional args 'block' is true and 'timeout' is None (the default),
        block if necessary until an item is available. If 'timeout' is
        a non-negative number, it blocks at most 'timeout' seconds and raises
        the Empty exception if no item was available within that time.
        Otherwise ('block' is false), return an item if one is immediately
        available, else raise the Empty exception ('timeout' is ignored
        in that case).
        """
        with self.not_empty:
            if not block:
                if not self._qsize():
                    raise Empty()
            elif timeout is none:
                while not self._qsize():
                    self.not_empty.wait()
            elif timeout < 0:
                raise ValueError("'timeout' must be a non-negative number")
            else:
                var endtime = monotonic() + timeout
                while not self._qsize():
                    var remaining = endtime - monotonic()
                    if remaining <= 0.0:
                        raise Empty()
                    self.not_empty.wait(remaining)
            var item = self._get()
            self.not_full.notify()
            return item

    def put_nowait(self, item):
        """Put an item into the queue without blocking.

        Only enqueue the item if a free slot is immediately available.
        Otherwise raise the Full exception.
        """
        return self.put(item, false)

    def get_nowait(self):
        """Remove and return an item from the queue without blocking.

        Only get an item if one is immediately available. Otherwise
        raise the Empty exception.
        """
        return self.get(false)

    # Override these methods to implement other queue organizations
    # (e.g. stack or priority queue).
    # These will only be called with appropriate locks held

    # Initialize the queue representation
    def _init(self, maxsize):
        self.queue = _collections_mod.deque()

    def _qsize(self):
        return len(self.queue)

    # Put a new item in the queue
    def _put(self, item):
        self.queue.append(item)

    # Get an item from the queue
    def _get(self):
        return self.queue.popleft()


def _siftdown(heap, startpos, pos):
    var newitem = heap[pos]
    # Follow the path to the root, moving parents down until finding a place
    # newitem fits.
    while pos > startpos:
        var parentpos = (pos - 1) >> 1
        var parent = heap[parentpos]
        if newitem < parent:
            heap[pos] = parent
            pos = parentpos
            continue
        break
    heap[pos] = newitem


def _siftup(heap, pos):
    var endpos = len(heap)
    var startpos = pos
    var newitem = heap[pos]
    # Bubble up the smaller child until hitting a leaf.
    var childpos = 2 * pos + 1    # leftmost child position
    while childpos < endpos:
        # Set childpos to index of smaller child.
        var rightpos = childpos + 1
        if rightpos < endpos and not heap[childpos] < heap[rightpos]:
            childpos = rightpos
        # Move the smaller child up.
        heap[pos] = heap[childpos]
        pos = childpos
        childpos = 2 * pos + 1
    # The leaf at pos is empty now.  Put newitem there, and bubble it up
    # to its final resting place (by sifting its parents down).
    heap[pos] = newitem
    _siftdown(heap, startpos, pos)


def _heappush(heap, item):
    heap.append(item)
    _siftdown(heap, 0, len(heap) - 1)


def _heappop(heap):
    var lastelt = heap.pop()
    if heap:
        var returnitem = heap[0]
        heap[0] = lastelt
        _siftup(heap, 0)
        return returnitem
    return lastelt


class PriorityQueue(Queue):
    """Variant of Queue that retrieves open entries in priority order (lowest first).

    Entries are typically tuples of the form:  (priority number, data).
    """
    def _init(self, maxsize):
        self.queue = []

    def _qsize(self):
        return len(self.queue)

    def _put(self, item):
        _heappush(self.queue, item)

    def _get(self):
        return _heappop(self.queue)


class LifoQueue(Queue):
    """Variant of Queue that retrieves most recently added entries first."""
    def _init(self, maxsize):
        self.queue = []

    def _qsize(self):
        return len(self.queue)

    def _put(self, item):
        self.queue.append(item)

    def _get(self):
        return self.queue.pop()


class SimpleQueue:
    """Simple, unbounded, reentrant FIFO queue."""
    def __init__(self):
        self._queue = _collections_mod.deque()
        self._lock = threading.Lock()
        self._not_empty = threading.Condition(self._lock)

    def put(self, item, block=true, timeout=none):
        """Put the item on the queue.

        The optional 'block' and 'timeout' arguments are ignored, as this
        method never blocks.  They are provided for compatibility with the
        Queue class.
        """
        with self._not_empty:
            self._queue.append(item)
            self._not_empty.notify()

    def get(self, block=true, timeout=none):
        """Remove and return an item from the queue.

        If optional args 'block' is true and 'timeout' is None (the default),
        block if necessary until an item is available. If 'timeout' is
        a non-negative number, it blocks at most 'timeout' seconds and raises
        the Empty exception if no item was available within that time.
        Otherwise ('block' is false), return an item if one is immediately
        available, else raise the Empty exception ('timeout' is ignored
        in that case).
        """
        if timeout is not none and timeout < 0:
            raise ValueError("'timeout' must be a non-negative number")
        with self._not_empty:
            if not block:
                if not len(self._queue):
                    raise Empty()
            elif timeout is none:
                while not len(self._queue):
                    self._not_empty.wait()
            else:
                var endtime = monotonic() + timeout
                while not len(self._queue):
                    var remaining = endtime - monotonic()
                    if remaining <= 0.0:
                        raise Empty()
                    self._not_empty.wait(remaining)
            return self._queue.popleft()

    def put_nowait(self, item):
        """Put an item into the queue without blocking.

        This is exactly equivalent to `put(item, block=False)` and is only
        provided for compatibility with the Queue class.
        """
        return self.put(item, false)

    def get_nowait(self):
        """Remove and return an item from the queue without blocking.

        Only get an item if one is immediately available. Otherwise
        raise the Empty exception.
        """
        return self.get(false)

    def empty(self):
        """Return True if the queue is empty, False otherwise (not reliable!)."""
        return len(self._queue) == 0

    def qsize(self):
        """Return the approximate size of the queue (not reliable!)."""
        return len(self._queue)
