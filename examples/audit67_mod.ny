# Fixture module for examples/vm_audit67.ny (imported by name).
counter = 0
_hidden = "hidden"
__all__ = ["Queue", "helper", "Empty"]

def bump():
    global counter
    counter = counter + 1
    return counter

def bump_plain():
    counter = counter + 10
    return counter

def helper(n):
    return n * 21

def calls_helper():
    return helper(2)

def sees_main():
    try:
        return main_only_name
    except NameError:
        return "NameError"

def sleep(x):
    return "audit67_mod.sleep(" + str(x) + ")"

class Queue:
    def __init__(self):
        self.items = []
    def put(self, x):
        self.items.append(x)
    def kind(self):
        return "audit67_mod.Queue"

class LifoQueue(Queue):
    def kind(self):
        return "audit67_mod.LifoQueue"

class Empty(Exception):
    pass

error = OSError

def take(q):
    if len(q.items) == 0:
        raise Empty("empty queue")
    return q.items.pop()

def safe_take(q):
    try:
        return take(q)
    except Empty:
        return "caught inside"
