# nython: module    (import it by name: it runs in a module scope of its own)
# lib/heapq.ny - Python's heapq: the heap queue algorithm on plain lists.
#
#     from heapq import heappush, heappop, heapify, nsmallest, merge
#
# heappush(heap, item)        heappop(heap)          heapify(x)
# heapreplace(heap, item)     heappushpop(heap, item)
# nlargest(n, iterable, key=None)   nsmallest(n, iterable, key=None)
# merge(*iterables, key=None, reverse=False)   a lazy generator
#
# A heap is a list with heap[k] <= heap[2*k+1] and heap[k] <= heap[2*k+2];
# heap[0] is the smallest item. The sift loops are CPython's (Floyd's
# bottom-up heapify, the leaf-first siftup), so a heap holds its items in
# exactly the order CPython's would after the same operations, and only
# `<` is ever used to compare items. nlargest/nsmallest keep a heap of n
# (stable: equal items keep their input order) and merge keeps a heap of
# the inputs' current heads, reading each input only as far as needed.

__all__ = ["heappush", "heappop", "heapify", "heapreplace", "merge",
           "nlargest", "nsmallest", "heappushpop"]


def heappush(heap, item):
    "Push item onto heap, maintaining the heap invariant."
    heap.append(item)
    _siftdown(heap, 0, len(heap) - 1)


def heappop(heap):
    "Pop the smallest item off the heap, maintaining the heap invariant."
    if len(heap) == 0:
        raise IndexError("index out of range")
    var lastelt = heap.pop()
    if len(heap) > 0:
        var returnitem = heap[0]
        heap[0] = lastelt
        _siftup(heap, 0)
        return returnitem
    return lastelt


def heapreplace(heap, item):
    """Pop and return the current smallest value, and add the new item.

    This is more efficient than heappop() followed by heappush(), and can be
    more appropriate when using a fixed-size heap.  Note that the value
    returned may be larger than item!  That constrains reasonable uses of
    this routine unless written as part of a conditional replacement:

        if item > heap[0]:
            item = heapreplace(heap, item)
    """
    if len(heap) == 0:
        raise IndexError("index out of range")
    var returnitem = heap[0]
    heap[0] = item
    _siftup(heap, 0)
    return returnitem


def heappushpop(heap, item):
    "Fast version of a heappush followed by a heappop."
    if len(heap) > 0 and heap[0] < item:
        var top = heap[0]
        heap[0] = item
        _siftup(heap, 0)
        return top
    return item


def heapify(x):
    "Transform list into a heap, in-place, in O(len(x)) time."
    var i = len(x) // 2 - 1
    while i >= 0:
        _siftup(x, i)
        i -= 1


def _heappop_max(heap):
    "Maxheap version of a heappop."
    var lastelt = heap.pop()
    if len(heap) > 0:
        var returnitem = heap[0]
        heap[0] = lastelt
        _siftup_max(heap, 0)
        return returnitem
    return lastelt


def _heapreplace_max(heap, item):
    "Maxheap version of a heappop followed by a heappush."
    var returnitem = heap[0]
    heap[0] = item
    _siftup_max(heap, 0)
    return returnitem


def _heapify_max(x):
    "Transform list into a maxheap, in-place, in O(len(x)) time."
    var i = len(x) // 2 - 1
    while i >= 0:
        _siftup_max(x, i)
        i -= 1


# heap[startpos..pos] is a heap except possibly at pos: move the item at
# pos up towards startpos until it is no smaller than its parent.
def _siftdown(heap, startpos, pos):
    var newitem = heap[pos]
    while pos > startpos:
        var parentpos = (pos - 1) >> 1
        var parent = heap[parentpos]
        if newitem < parent:
            heap[pos] = parent
            pos = parentpos
            continue
        break
    heap[pos] = newitem


# Move the smaller child up until hitting a leaf, put the item there, then
# sift it down (fewer comparisons than stopping early, as CPython does).
def _siftup(heap, pos):
    var endpos = len(heap)
    var startpos = pos
    var newitem = heap[pos]
    var childpos = 2 * pos + 1
    while childpos < endpos:
        var rightpos = childpos + 1
        if rightpos < endpos and not (heap[childpos] < heap[rightpos]):
            childpos = rightpos
        heap[pos] = heap[childpos]
        pos = childpos
        childpos = 2 * pos + 1
    heap[pos] = newitem
    _siftdown(heap, startpos, pos)


def _siftdown_max(heap, startpos, pos):
    "Maxheap variant of _siftdown"
    var newitem = heap[pos]
    while pos > startpos:
        var parentpos = (pos - 1) >> 1
        var parent = heap[parentpos]
        if parent < newitem:
            heap[pos] = parent
            pos = parentpos
            continue
        break
    heap[pos] = newitem


def _siftup_max(heap, pos):
    "Maxheap variant of _siftup"
    var endpos = len(heap)
    var startpos = pos
    var newitem = heap[pos]
    var childpos = 2 * pos + 1
    while childpos < endpos:
        var rightpos = childpos + 1
        if rightpos < endpos and not (heap[rightpos] < heap[childpos]):
            childpos = rightpos
        heap[pos] = heap[childpos]
        pos = childpos
        childpos = 2 * pos + 1
    heap[pos] = newitem
    _siftdown_max(heap, startpos, pos)


def merge(*iterables, key=none, reverse=false):
    """Merge multiple sorted inputs into a single sorted output.

    Similar to sorted(itertools.chain(*iterables)) but returns a generator,
    does not pull the data into memory all at once, and assumes that each of
    the input streams is already sorted (smallest to largest).

    >>> list(merge([1,3,5,7], [0,2,4,8], [5,10,15,20], [], [25]))
    [0, 1, 2, 3, 4, 5, 5, 7, 8, 10, 15, 20, 25]

    If *key* is not None, applies a key function to each element to determine
    its sort order.

    >>> list(merge(['dog', 'horse'], ['cat', 'fish', 'kangaroo'], key=len))
    ['dog', 'cat', 'fish', 'horse', 'kangaroo']
    """
    # Each heap entry is [key, order, value, iterator]: `order` (the input's
    # position, negated when reversed) breaks ties, so equal items come out
    # in input order and iterators are never compared.
    var h = []
    var direction = -1 if reverse else 1
    var order = 0
    for src in iterables:
        var it = iter(src)
        try:
            var value = next(it)
            h.append([value if key is none else key(value), order * direction, value, it])
        except StopIteration:
            pass
        order += 1
    if reverse:
        _heapify_max(h)
    else:
        heapify(h)
    while len(h) > 1:
        var s = h[0]
        yield s[2]
        try:
            var nv = next(s[3])
            s[0] = nv if key is none else key(nv)
            s[2] = nv
            if reverse:
                _heapreplace_max(h, s)
            else:
                heapreplace(h, s)
        except StopIteration:
            if reverse:
                _heappop_max(h)
            else:
                heappop(h)
    if len(h) > 0:
        # one input left: the rest of it as it is
        var last = h[0]
        yield last[2]
        for v in last[3]:
            yield v


def nsmallest(n, iterable, key=none):
    """Find the n smallest elements in a dataset.

    Equivalent to:  sorted(iterable, key=key)[:n]
    """
    if n == 1:
        var found = false
        var best = none
        var bestk = none
        for elem in iterable:
            var k = elem if key is none else key(elem)
            if not found or k < bestk:
                best = elem
                bestk = k
                found = true
        return [best] if found else []
    var size = -1
    try:
        size = len(iterable)
    except TypeError:
        pass
    except AttributeError:
        pass
    if size >= 0 and n >= size:
        return sorted(iterable, key=key)[:n]
    var it = iter(iterable)
    # the first n items, decorated with their position (so equal items keep
    # their order and the items themselves are compared only when the keys
    # are equal... never, as positions differ)
    var result = []
    var i = 0
    while i < n:
        try:
            var e = next(it)
        except StopIteration:
            break
        if key is none:
            result.append((e, i))
        else:
            result.append((key(e), i, e))
        i += 1
    if len(result) == 0:
        return result
    _heapify_max(result)
    var top = result[0][0]
    var order = n
    for elem in it:
        var k = elem if key is none else key(elem)
        if k < top:
            if key is none:
                _heapreplace_max(result, (elem, order))
            else:
                _heapreplace_max(result, (k, order, elem))
            top = result[0][0]
            order += 1
    result.sort()
    if key is none:
        return [r[0] for r in result]
    return [r[2] for r in result]


def nlargest(n, iterable, key=none):
    """Find the n largest elements in a dataset.

    Equivalent to:  sorted(iterable, key=key, reverse=True)[:n]
    """
    if n == 1:
        var found = false
        var best = none
        var bestk = none
        for elem in iterable:
            var k = elem if key is none else key(elem)
            if not found or bestk < k:
                best = elem
                bestk = k
                found = true
        return [best] if found else []
    var size = -1
    try:
        size = len(iterable)
    except TypeError:
        pass
    except AttributeError:
        pass
    if size >= 0 and n >= size:
        return sorted(iterable, key=key, reverse=true)[:n]
    var it = iter(iterable)
    var result = []
    var i = 0
    while i < n:
        try:
            var e = next(it)
        except StopIteration:
            break
        if key is none:
            result.append((e, -i))
        else:
            result.append((key(e), -i, e))
        i += 1
    if len(result) == 0:
        return result
    heapify(result)
    var top = result[0][0]
    var order = -n
    for elem in it:
        var k = elem if key is none else key(elem)
        if top < k:
            if key is none:
                heapreplace(result, (elem, order))
            else:
                heapreplace(result, (k, order, elem))
            top = result[0][0]
            order -= 1
    result.sort(reverse=true)
    if key is none:
        return [r[0] for r in result]
    return [r[2] for r in result]
