# nython: module    (import it by name: it runs in a module scope of its own)
# lib/bisect.ny - Python's bisect: binary search in, and insertion into,
# sorted sequences.
#
#     from bisect import bisect_left, bisect_right, insort
#
# bisect_left(a, x, lo=0, hi=None, *, key=None)    first position x fits
# bisect_right(a, x, lo=0, hi=None, *, key=None)   last position (= bisect)
# insort_left / insort_right (= insort)(a, x, lo=0, hi=None, *, key=None)
#
# As in Python: only `<` is used to compare, key= applies to the elements
# of a (not to x, for bisect; insort applies it to x too), lo < 0 is a
# ValueError, and insort calls a.insert, so any sequence with insert works.

__all__ = ["bisect", "bisect_left", "bisect_right", "insort", "insort_left", "insort_right"]


def bisect_right(a, x, lo=0, hi=none, key=none):
    """Return the index where to insert item x in list a, assuming a is sorted.

    The return value i is such that all e in a[:i] have e <= x, and all e in
    a[i:] have e > x.  So if x already appears in the list, a.insert(i, x) will
    insert just after the rightmost x already there.

    Optional args lo (default 0) and hi (default len(a)) bound the
    slice of a to be searched.

    A custom key function can be supplied to customize the sort order.
    """
    if lo < 0:
        raise ValueError("lo must be non-negative")
    if hi is none:
        hi = len(a)
    if key is none:
        while lo < hi:
            var mid = (lo + hi) // 2
            if x < a[mid]:
                hi = mid
            else:
                lo = mid + 1
    else:
        while lo < hi:
            var mid2 = (lo + hi) // 2
            if x < key(a[mid2]):
                hi = mid2
            else:
                lo = mid2 + 1
    return lo


def bisect_left(a, x, lo=0, hi=none, key=none):
    """Return the index where to insert item x in list a, assuming a is sorted.

    The return value i is such that all e in a[:i] have e < x, and all e in
    a[i:] have e >= x.  So if x already appears in the list, a.insert(i, x) will
    insert just before the leftmost x already there.

    Optional args lo (default 0) and hi (default len(a)) bound the
    slice of a to be searched.

    A custom key function can be supplied to customize the sort order.
    """
    if lo < 0:
        raise ValueError("lo must be non-negative")
    if hi is none:
        hi = len(a)
    if key is none:
        while lo < hi:
            var mid = (lo + hi) // 2
            if a[mid] < x:
                lo = mid + 1
            else:
                hi = mid
    else:
        while lo < hi:
            var mid2 = (lo + hi) // 2
            if key(a[mid2]) < x:
                lo = mid2 + 1
            else:
                hi = mid2
    return lo


def insort_right(a, x, lo=0, hi=none, key=none):
    """Insert item x in list a, and keep it sorted assuming a is sorted.

    If x is already in a, insert it to the right of the rightmost x.

    Optional args lo (default 0) and hi (default len(a)) bound the
    slice of a to be searched.

    A custom key function can be supplied to customize the sort order.
    """
    if key is none:
        lo = bisect_right(a, x, lo, hi)
    else:
        lo = bisect_right(a, key(x), lo, hi, key=key)
    a.insert(lo, x)


def insort_left(a, x, lo=0, hi=none, key=none):
    """Insert item x in list a, and keep it sorted assuming a is sorted.

    If x is already in a, insert it to the left of the leftmost x.

    Optional args lo (default 0) and hi (default len(a)) bound the
    slice of a to be searched.

    A custom key function can be supplied to customize the sort order.
    """
    if key is none:
        lo = bisect_left(a, x, lo, hi)
    else:
        lo = bisect_left(a, key(x), lo, hi, key=key)
    a.insert(lo, x)


bisect = bisect_right
insort = insort_right
