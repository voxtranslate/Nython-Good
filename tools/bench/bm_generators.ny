# bm_generators - a generator pipeline: a source generator, filtering and
# mapping generator stages, `yield from` delegation, generator expressions
# consumed by sum()/max(), and a tree walked by recursive generators. Runs
# under python3 too.
import time


def numbers(n):
    i = 0
    while i < n:
        yield i
        i += 1


def evens(src):
    for x in src:
        if x % 2 == 0:
            yield x


def squares(src):
    for x in src:
        yield x * x


def chunks(src, size):
    buf = []
    for x in src:
        buf.append(x)
        if len(buf) == size:
            yield buf
            buf = []
    if buf:
        yield buf


def chained(n):
    yield from numbers(n)
    yield from numbers(n // 2)


class Node(object):
    def __init__(self, value, left=None, right=None):
        self.value = value
        self.left = left
        self.right = right


def build(lo, hi):
    if lo > hi:
        return None
    mid = (lo + hi) // 2
    return Node(mid, build(lo, mid - 1), build(mid + 1, hi))


def inorder(node):
    if node is not None:
        yield from inorder(node.left)
        yield node.value
        yield from inorder(node.right)


def main():
    t0 = time.perf_counter()
    total = 0
    for rnd in range(16):
        total += sum(squares(evens(numbers(6000))))
        for c in chunks(numbers(3000), 7):
            total += len(c)
        total += sum(x for x in chained(4000) if x % 3 == 0)
        total += max(x * 2 for x in range(5000))
    tree = build(0, 1500)
    for rnd in range(10):
        acc = 0
        for v in inorder(tree):
            acc += v
        total += acc
    t1 = time.perf_counter()
    print("result", total)
    print("bench_time", t1 - t0)

main()
