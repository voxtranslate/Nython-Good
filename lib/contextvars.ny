# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/contextvars.ny - Python's contextvars (PEP 567, 3.11): context-local
# state, per thread and per asyncio task.
#
#     from contextvars import ContextVar, copy_context
#     request_id = ContextVar("request_id", default=None)
#     token = request_id.set("r-17")
#     request_id.get()                    # 'r-17'
#     request_id.reset(token)             # back to what it was
#     ctx = copy_context()
#     ctx.run(handler, arg)               # handler's set()s stay inside ctx
#
# ContextVar(name, *, default) with name, get([default]) (LookupError(var)
# when unset), set(value) -> Token, reset(token), ContextVar[T]; Token with
# var, old_value and Token.MISSING; Context: Context() (empty), run(fn,
# *args, **kwargs), copy(), and the read-only mapping protocol (ctx[var],
# get, in, len, iteration, keys/values/items, ==); copy_context(). The
# errors and their messages are CPython's ("<Token ...> has already been
# used once", "... was created by a different ContextVar", "... was created
# in a different Context", "cannot enter context: ... is already entered",
# "a ContextVar key was expected, got 1", "Tokens can only be created by
# ContextVars").
#
# Where the context lives: each thread, and each asyncio task, has its own
# current context - a slot in the runtime's per-thread record (the
# "__ny_ctx_data" key of thread_local_get/set, which tasks have too, so a
# task switch moves it with the rest of the task's state: no extra work at
# a switch). As in CPython the data is an immutable mapping, replaced on
# every set(), so copying a context is copying one reference: when a task
# is made (asyncio.create_task, gather, ...), the runtime gives it the
# creating task's mapping (round 79, src/NyConc.cpp new_task_locked/grant),
# which is PEP 567's "each task runs in a copy of the context current when
# it was created". A new thread starts with an empty context (Python 3.11).
# lib/decimal.ny keeps its current Context in a ContextVar, so
# localcontext() in one task does not change another task's precision.
#
# Differences from CPython: the mapping is a plain dict copied on write
# (CPython: a HAMT, O(log n) per set); fine for the handful of variables
# programs keep, O(number of variables) per set() otherwise.

from types import GenericAlias

__all__ = ["Context", "ContextVar", "Token", "copy_context"]

_KEY_DATA = "__ny_ctx_data"
_KEY_OBJ = "__ny_ctx_obj"
_EMPTY = {}
_NOARG = object()


def _cur_data():
    return thread_local_get(_KEY_DATA, _EMPTY)


def _set_data(d):
    thread_local_set(_KEY_DATA, d)


def _cur_obj():
    # The Context object current on this thread/task: the one run() entered,
    # or the thread's implicit one (made on first need; it only identifies
    # the context for Token checks - no API hands it out, as in CPython).
    var o = thread_local_get(_KEY_OBJ, none)
    if o is none:
        o = Context()
        o._entered = true
        thread_local_set(_KEY_OBJ, o)
    return o


def _addr(o):
    return "0x%x" % id(o)


class _Missing:
    def __repr__(self):
        return "<Token.MISSING>"


class Context:
    # A mapping of ContextVars to values. Context() is an empty one;
    # copy_context() a copy of the current one.
    def __init__(self):
        self._data = _EMPTY
        self._entered = false

    def _live(self):
        # while this context is the current one, set() updates the slot
        if self._entered and thread_local_get(_KEY_OBJ, none) is self:
            return _cur_data()
        return self._data

    def run(self, callable, *args, **kwargs):
        if self._entered:
            raise RuntimeError("cannot enter context: " + repr(self) + " is already entered")
        var prev_obj = thread_local_get(_KEY_OBJ, none)
        var prev_data = _cur_data()
        if prev_obj is not none:
            prev_obj._data = prev_data
        self._entered = true
        thread_local_set(_KEY_OBJ, self)
        _set_data(self._data)
        try:
            return callable(*args, **kwargs)
        finally:
            self._data = _cur_data()
            self._entered = false
            _set_data(prev_data)
            if prev_obj is none:
                thread_local_del(_KEY_OBJ)
            else:
                thread_local_set(_KEY_OBJ, prev_obj)

    def copy(self):
        var c = Context()
        c._data = self._live()
        return c

    def _check(self, key):
        if not isinstance(key, ContextVar):
            raise TypeError("a ContextVar key was expected, got " + repr(key))

    def __getitem__(self, key):
        self._check(key)
        var d = self._live()
        if key in d:
            return d[key]
        raise KeyError(key)

    def __contains__(self, key):
        self._check(key)
        return key in self._live()

    def __len__(self):
        return len(self._live())

    def __iter__(self):
        return iter(list(self._live().keys()))

    def get(self, key, default=none):
        self._check(key)
        var d = self._live()
        if key in d:
            return d[key]
        return default

    def keys(self):
        return list(self._live().keys())

    def values(self):
        return list(self._live().values())

    def items(self):
        return list(self._live().items())

    def __eq__(self, other):
        if not isinstance(other, Context):
            return NotImplemented
        var a = self._live()
        var b = other._live()
        if len(a) != len(b):
            return false
        for k in a:
            if not (k in b) or not (b[k] == a[k]):
                return false
        return true

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r

    __hash__ = none

    def __repr__(self):
        return "<_contextvars.Context object at " + _addr(self) + ">"


class ContextVar:
    def __init__(self, name, *, default=_NOARG):
        if not isinstance(name, str):
            raise TypeError("context variable name must be a str")
        self._name = name
        self._default = default

    @property
    def name(self):
        return self._name

    def get(self, *args):
        if len(args) > 1:
            raise TypeError("get expected at most 1 argument, got " + str(len(args)))
        var d = thread_local_get(_KEY_DATA, _EMPTY)
        if self in d:
            return d[self]
        if len(args) == 1:
            return args[0]
        if self._default is not _NOARG:
            return self._default
        raise LookupError(self)

    def set(self, value):
        var obj = _cur_obj()
        var d = _cur_data()
        var old = Token.MISSING
        if self in d:
            old = d[self]
        var nd = dict(d)
        nd[self] = value
        _set_data(nd)
        return Token._make(obj, self, old)

    def reset(self, token):
        if not isinstance(token, Token):
            raise TypeError("expected an instance of Token, got " + repr(token))
        if token._used:
            raise RuntimeError(repr(token) + " has already been used once")
        if token._var is not self:
            raise ValueError(repr(token) + " was created by a different ContextVar")
        if token._ctx is not _cur_obj():
            raise ValueError(repr(token) + " was created in a different Context")
        var nd = dict(_cur_data())
        if token._old is Token.MISSING:
            if self in nd:
                del nd[self]
        else:
            nd[self] = token._old
        _set_data(nd)
        token._used = true

    def __class_getitem__(cls, item):
        return GenericAlias(cls, item)

    def __repr__(self):
        var s = "<ContextVar name=" + repr(self._name)
        if self._default is not _NOARG:
            s += " default=" + repr(self._default)
        return s + " at " + _addr(self) + ">"


_token_maker = [false]


class Token:
    MISSING = _Missing()

    def __init__(self, *args):
        if not _token_maker[0]:
            raise RuntimeError("Tokens can only be created by ContextVars")
        self._ctx = args[0]
        self._var = args[1]
        self._old = args[2]
        self._used = false

    @staticmethod
    def _make(ctx, var_, old):
        _token_maker[0] = true
        try:
            return Token(ctx, var_, old)
        finally:
            _token_maker[0] = false

    @property
    def var(self):
        return self._var

    @property
    def old_value(self):
        return self._old

    def __class_getitem__(cls, item):
        return GenericAlias(cls, item)

    def __repr__(self):
        var u = " used" if self._used else ""
        return "<Token" + u + " var=" + repr(self._var) + " at " + _addr(self) + ">"


def copy_context():
    var c = Context()
    c._data = _cur_data()
    return c
