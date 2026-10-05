# nython: module    (import it by name: it runs in a module scope of its own)
# lib/contextlib.ny - Python's contextlib: utilities for with-statement
# contexts.
#
#     from contextlib import contextmanager, suppress, ExitStack, redirect_stdout
#
# contextmanager(genfunc)   a generator function -> a context manager: the
#                           code before `yield` is __enter__ (the yielded value
#                           is bound by `as`), the code after it __exit__; an
#                           exception in the with block is raised at the yield,
#                           so the generator can catch it (suppressing it) or
#                           let it propagate; RuntimeError("generator didn't
#                           stop") / ("generator didn't yield") as Python. The
#                           result also works as a decorator (ContextDecorator).
# closing(thing)            calls thing.close() on exit
# suppress(*exceptions)     swallows the listed exception types
# nullcontext(enter_result=None)   does nothing
# ExitStack                 enter_context, callback, push, pop_all, close;
#                           exits run last-in first-out, each seeing the
#                           exception the later ones left (or none if one
#                           suppressed it); an exception raised by an exit
#                           replaces the pending one and records it as its
#                           __context__ (the runtime does not chain
#                           exceptions itself; this does it explicitly)
# redirect_stdout(new_target) / redirect_stderr(new_target)
#                           sys.stdout / sys.stderr replaced for the block;
#                           print() writes to whatever sys.stdout is
# chdir(path)               the working directory changed for the block
# AbstractContextManager    __enter__ returns self; __exit__ to implement
# ContextDecorator          a context manager usable as a decorator
#
# asynccontextmanager(agenfunc)   the same for an async generator function
#                           (async with; also an async decorator)
# aclosing(thing)           awaits thing.aclose() on exit
# AsyncExitStack            ExitStack plus enter_async_context,
#                           push_async_exit, push_async_callback, aclose
# AbstractAsyncContextManager, AsyncContextDecorator
#
# Not here: AbstractContextManager's isinstance check by structure
# (__subclasshook__ needs metaclasses).

import sys
import os

__all__ = ["asynccontextmanager", "contextmanager", "closing", "nullcontext",
           "AbstractContextManager", "AbstractAsyncContextManager",
           "AsyncExitStack", "ContextDecorator", "AsyncContextDecorator",
           "ExitStack", "redirect_stdout", "redirect_stderr", "suppress",
           "aclosing", "chdir"]


def _tname(x):
    return type(x).__name__


def _same(a, b):
    return id(a) == id(b)


def _attr_or_none(obj, name):
    try:
        return getattr(obj, name)
    except AttributeError:
        return none


class AbstractContextManager:
    "An abstract base class for context managers."

    def __enter__(self):
        "Return `self` upon entering the runtime context."
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        "Raise any exception triggered within the runtime context."
        return none


class ContextDecorator:
    "A base class or mixin that enables context managers to work as decorators."

    def _recreate_cm(self):
        """Return a recreated instance of self.

        Allows an otherwise one-shot context manager like
        _GeneratorContextManager to support use as
        a decorator via implicit recreation.

        This is a private interface just for _GeneratorContextManager.
        See issue #11647 for details.
        """
        return self

    def __call__(self, func):
        var cm_source = self
        def inner(*args, **kwds):
            with cm_source._recreate_cm():
                return func(*args, **kwds)
        _copy_wrapper_attrs(inner, func)
        return inner


def _copy_wrapper_attrs(wrapper, wrapped):
    # functools.wraps, without importing functools
    for attr in ["__module__", "__name__", "__qualname__", "__doc__"]:
        var v = none
        var have = true
        try:
            v = getattr(wrapped, attr)
        except AttributeError:
            have = false
        if have:
            setattr(wrapper, attr, v)
    wrapper.__wrapped__ = wrapped


# ── contextmanager ───────────────────────────────────────────────────────────
class _GeneratorContextManager(ContextDecorator, AbstractContextManager):
    "Helper for @contextmanager decorator."

    def __init__(self, func, args, kwds):
        self.gen = func(*args, **kwds)
        self.func = func
        self.args = args
        self.kwds = kwds
        # the generator function's docstring, as Python's
        var doc = getattr(func, "__doc__", none)
        if doc is none:
            doc = "Helper for @contextmanager decorator."
        self.__doc__ = doc

    def _recreate_cm(self):
        # _GCMs are one-shot: a decorated function gets a fresh one per call
        return _GeneratorContextManager(self.func, self.args, self.kwds)

    def __enter__(self):
        # do not keep args and kwds alive unnecessarily
        # they are only needed for recreation, which is not possible anymore
        try:
            return next(self.gen)
        except StopIteration:
            raise RuntimeError("generator didn't yield")

    def __exit__(self, typ, value, traceback):
        if typ is none:
            var stopped = false
            try:
                next(self.gen)
            except StopIteration:
                stopped = true
            if stopped:
                return false
            try:
                raise RuntimeError("generator didn't stop")
            finally:
                self.gen.close()
        if value is none:
            # Need to force instantiation so we can reliably
            # tell if we get the same exception back
            value = typ()
        var outcome = _cm_throw(self.gen, value)
        if outcome == "stopped":
            # Suppress StopIteration *unless* it's the same exception that
            # was passed to throw().  This prevents a StopIteration
            # raised inside the "with" statement from being suppressed.
            return true
        if outcome == "propagate":
            return false
        # the generator yielded again
        try:
            raise RuntimeError("generator didn't stop after throw()")
        finally:
            self.gen.close()


def _cm_throw(gen, value):
    # Throws `value` into gen at its yield: "stopped" (it returned - the
    # exception was swallowed), "propagate" (the same exception came back
    # out: __exit__ returns false so it carries on), "yielded" (it yielded
    # again). Any other exception propagates from here.
    try:
        gen.throw(value)
    except StopIteration as exc:
        if _same(exc, value):
            return "propagate"
        return "stopped"
    except RuntimeError as exc:
        # Don't re-raise the passed in exception. (issue27122)
        if _same(exc, value):
            return "propagate"
        # A StopIteration thrown in and turned into a RuntimeError by the
        # generator machinery (PEP 479) is the original exception.
        if isinstance(value, StopIteration) and _same(_attr_or_none(exc, "__cause__"), value):
            return "propagate"
        if isinstance(value, StopIteration) and str(exc) == "generator raised StopIteration":
            return "propagate"
        raise
    except BaseException as exc:
        # only re-raise if it's *not* the exception that was
        # passed to throw(), because __exit__() must not raise
        # an exception unless __exit__() itself failed.  But throw()
        # has to raise the exception to signal propagation, so this
        # fixes the impedance mismatch between the throw() protocol
        # and the __exit__() protocol.
        if not _same(exc, value):
            raise
        return "propagate"
    return "yielded"


def contextmanager(func):
    """@contextmanager decorator.

    Typical usage:

        @contextmanager
        def some_generator(<arguments>):
            <setup>
            try:
                yield <value>
            finally:
                <cleanup>

    This makes this:

        with some_generator(<arguments>) as <variable>:
            <body>

    equivalent to this:

        <setup>
        try:
            <variable> = <value>
            <body>
        finally:
            <cleanup>
    """
    def helper(*args, **kwds):
        return _GeneratorContextManager(func, args, kwds)
    _copy_wrapper_attrs(helper, func)
    return helper


# ── the async variants ───────────────────────────────────────────────────────
# The runtime's async generator (prelude _NyAsyncGen) wraps a plain
# generator whose body awaits as it runs, so it is driven directly; any
# other async iterator through __anext__ / athrow / aclose.
def _agen_next(agen):
    if hasattr(agen, "_g"):
        try:
            return next(agen._g)
        except StopIteration:
            raise StopAsyncIteration()
    return async_await(agen.__anext__())


def _agen_throw(agen, value):
    if hasattr(agen, "_g"):
        try:
            return agen._g.throw(value)
        except StopIteration:
            raise StopAsyncIteration()
    return async_await(agen.athrow(value))


def _await(x):
    # await the result of an async call (a coroutine); a plain value as it is
    if x is none or isinstance(x, bool) or not isinstance(x, int):
        return x
    return async_await(x)


class AbstractAsyncContextManager:
    "An abstract base class for asynchronous context managers."

    async def __aenter__(self):
        "Return `self` upon entering the runtime context."
        return self

    async def __aexit__(self, exc_type, exc_value, traceback):
        "Raise any exception triggered within the runtime context."
        return none


class AsyncContextDecorator:
    "A base class or mixin that enables async context managers to work as decorators."

    def _recreate_cm(self):
        "Return a recreated instance of self."
        return self

    def __call__(self, func):
        var cm_source = self
        async def inner(*args, **kwds):
            async with cm_source._recreate_cm():
                return await func(*args, **kwds)
        _copy_wrapper_attrs(inner, func)
        return inner


class _AsyncGeneratorContextManager(AbstractAsyncContextManager, AsyncContextDecorator):
    "Helper for @asynccontextmanager decorator."

    def __init__(self, func, args, kwds):
        self.gen = func(*args, **kwds)
        self.func = func
        self.args = args
        self.kwds = kwds
        var doc = getattr(func, "__doc__", none)
        if doc is none:
            doc = "Helper for @asynccontextmanager decorator."
        self.__doc__ = doc

    def _recreate_cm(self):
        return _AsyncGeneratorContextManager(self.func, self.args, self.kwds)

    async def __aenter__(self):
        try:
            return _agen_next(self.gen)
        except StopAsyncIteration:
            raise RuntimeError("generator didn't yield")

    async def __aexit__(self, typ, value, traceback):
        if typ is none:
            var stopped = false
            try:
                _agen_next(self.gen)
            except StopAsyncIteration:
                stopped = true
            if stopped:
                return false
            try:
                raise RuntimeError("generator didn't stop")
            finally:
                _await(self.gen.aclose())
        if value is none:
            value = typ()
        var outcome = _acm_throw(self.gen, value)
        if outcome == "stopped":
            return true
        if outcome == "propagate":
            return false
        try:
            raise RuntimeError("generator didn't stop after athrow()")
        finally:
            _await(self.gen.aclose())


def _acm_throw(agen, value):
    # _cm_throw for an async generator
    try:
        _agen_throw(agen, value)
    except StopAsyncIteration as exc:
        if _same(exc, value):
            return "propagate"
        return "stopped"
    except RuntimeError as exc:
        if _same(exc, value):
            return "propagate"
        if isinstance(value, (StopIteration, StopAsyncIteration)) and _same(_attr_or_none(exc, "__cause__"), value):
            return "propagate"
        if isinstance(value, (StopIteration, StopAsyncIteration)) and str(exc).startswith("generator raised StopIteration"):
            return "propagate"
        if isinstance(value, (StopIteration, StopAsyncIteration)) and str(exc).startswith("async generator raised StopAsyncIteration"):
            return "propagate"
        raise
    except BaseException as exc:
        if not _same(exc, value):
            raise
        return "propagate"
    return "yielded"


def asynccontextmanager(func):
    """@asynccontextmanager decorator.

    Typical usage:

        @asynccontextmanager
        async def some_async_generator(<arguments>):
            <setup>
            try:
                yield <value>
            finally:
                <cleanup>

    This makes this:

        async with some_async_generator(<arguments>) as <variable>:
            <body>

    equivalent to this:

        <setup>
        try:
            <variable> = <value>
            <body>
        finally:
            <cleanup>
    """
    def helper(*args, **kwds):
        return _AsyncGeneratorContextManager(func, args, kwds)
    _copy_wrapper_attrs(helper, func)
    return helper


class aclosing(AbstractAsyncContextManager):
    """Async context manager for safely finalizing an asynchronously cleaned-up
    resource such as an async generator, calling its ``aclose()`` method.
    """
    def __init__(self, thing):
        self.thing = thing

    async def __aenter__(self):
        return self.thing

    async def __aexit__(self, *exc_info):
        _await(self.thing.aclose())


# ── closing / nullcontext / suppress ─────────────────────────────────────────
class closing(AbstractContextManager):
    """Context to automatically close something at the end of a block.

    Code like this:

        with closing(<module>.open(<arguments>)) as f:
            <block>

    is equivalent to this:

        f = <module>.open(<arguments>)
        try:
            <block>
        finally:
            f.close()

    """
    def __init__(self, thing):
        self.thing = thing

    def __enter__(self):
        return self.thing

    def __exit__(self, *exc_info):
        self.thing.close()


class nullcontext(AbstractContextManager):
    """Context manager that does no additional processing.

    Used as a stand-in for a normal context manager, when a particular
    block of code is only sometimes used with a normal context manager:

    cm = optional_cm if condition else nullcontext()
    with cm:
        # Perform operation, using optional_cm if condition is True
    """

    def __init__(self, enter_result=none):
        self.enter_result = enter_result

    def __enter__(self):
        return self.enter_result

    def __exit__(self, *excinfo):
        pass


class suppress(AbstractContextManager):
    """Context manager to suppress specified exceptions

    After the exception is suppressed, execution proceeds with the next
    statement following the with statement.

         with suppress(FileNotFoundError):
             os.remove(somefile)
         # Execution still resumes here if the file was already removed
    """

    def __init__(self, *exceptions):
        self._exceptions = tuple(exceptions)

    def __enter__(self):
        pass

    def __exit__(self, exctype, excinst, exctb):
        # Unlike isinstance and issubclass, CPython exception handling
        # currently only looks at the concrete type hierarchy (ignoring
        # the instance and subclass checking hooks).
        if exctype is none:
            return false
        for e in self._exceptions:
            if issubclass(exctype, e):
                return true
        return false


# ── redirect_stdout / redirect_stderr ────────────────────────────────────────
class _RedirectStream(AbstractContextManager):

    _stream = none

    def __init__(self, new_target):
        self._new_target = new_target
        # We use a list of old targets to make this CM re-entrant
        self._old_targets = []

    def __enter__(self):
        self._old_targets.append(getattr(sys, self._stream))
        setattr(sys, self._stream, self._new_target)
        return self._new_target

    def __exit__(self, exctype, excinst, exctb):
        setattr(sys, self._stream, self._old_targets.pop())


class redirect_stdout(_RedirectStream):
    """Context manager for temporarily redirecting stdout to another file.

        # How to send help() to stderr
        with redirect_stdout(sys.stderr):
            help(dir)

        # How to write help() to a file
        with open('help.txt', 'w') as f:
            with redirect_stdout(f):
                help(pow)
    """

    _stream = "stdout"


class redirect_stderr(_RedirectStream):
    "Context manager for temporarily redirecting stderr to another file."

    _stream = "stderr"


# ── chdir ────────────────────────────────────────────────────────────────────
class chdir(AbstractContextManager):
    "Non thread-safe context manager to change the current working directory."

    def __init__(self, path):
        self.path = path
        self._old_cwd = []

    def __enter__(self):
        self._old_cwd.append(os.getcwd())
        os.chdir(self.path)

    def __exit__(self, *excinfo):
        os.chdir(self._old_cwd.pop())


# ── ExitStack ────────────────────────────────────────────────────────────────
class _ExitStackCallback:
    # stack.callback(f, *args, **kwds): an exit function that calls f
    def __init__(self, callback, args, kwds):
        self.callback = callback
        self.args = args
        self.kwds = kwds
        self.__wrapped__ = callback

    def __call__(self, exc_type, exc, tb):
        self.callback(*self.args, **self.kwds)


class _ExitStackCMExit:
    # the __exit__ of a context manager, bound to it
    def __init__(self, cm):
        self.cm = cm
        self.__self__ = cm

    def __call__(self, exc_type, exc, tb):
        return self.cm.__exit__(exc_type, exc, tb)


class _BaseExitStack:
    "A base class for ExitStack and AsyncExitStack."

    def __init__(self):
        self._exit_callbacks = []

    def pop_all(self):
        "Preserve the context stack by transferring it to a new instance."
        var new_stack = self.__class__()
        new_stack._exit_callbacks = self._exit_callbacks
        self._exit_callbacks = []
        return new_stack

    def push(self, exit):
        """Registers a callback with the standard __exit__ method signature.

        Can suppress exceptions the same way __exit__ method can.
        Also accepts any object with an __exit__ method (registering a call
        to the method instead of the object itself).
        """
        # We use an unbound method rather than a bound method to follow
        # the standard lookup behaviour for special methods.
        if _has_method(exit, "__exit__"):
            self._exit_callbacks.append(_ExitStackCMExit(exit))
        else:
            # Not a context manager, so assume it's a callable.
            self._exit_callbacks.append(exit)
        return exit  # Allow use as a decorator.

    def enter_context(self, cm):
        """Enters the supplied context manager.

        If successful, also pushes its __exit__ method as a callback and
        returns the result of the __enter__ method.
        """
        if not _has_method(cm, "__enter__") or not _has_method(cm, "__exit__"):
            raise TypeError("'" + _cls_label(cm) + "' object does not support the context manager protocol")
        var result = cm.__enter__()
        self._exit_callbacks.append(_ExitStackCMExit(cm))
        return result

    def callback(self, callback, *args, **kwds):
        """Registers an arbitrary callback and arguments.

        Cannot suppress exceptions.
        """
        self._exit_callbacks.append(_ExitStackCallback(callback, args, kwds))
        return callback  # Allow use as a decorator


def _has_method(obj, name):
    # the class defines it (special methods are looked up on the type)
    if not hasattr(obj, "__class__"):
        return false
    return hasattr(obj.__class__, name)


def _cls_label(obj):
    var cls = obj.__class__ if hasattr(obj, "__class__") else none
    if cls is none:
        return "builtins." + _tname(obj)
    var mod = getattr(cls, "__module__", "builtins")
    var name = getattr(cls, "__qualname__", cls.__name__)
    return mod + "." + name


class ExitStack(_BaseExitStack, AbstractContextManager):
    """Context manager for dynamic management of a stack of exit callbacks.

    For example:
        with ExitStack() as stack:
            files = [stack.enter_context(open(fname)) for fname in filenames]
            # All opened files will automatically be closed at the end of
            # the with statement, even if attempts to open files later
            # in the list raise an exception.
    """

    def __enter__(self):
        return self

    def __exit__(self, *exc_details):
        return _unwind(self, exc_details)

    def close(self):
        "Immediately unwind the context stack."
        self.__exit__(none, none, none)


class _AsyncExitStackCMExit:
    # the __aexit__ of an async context manager, bound to it
    def __init__(self, cm):
        self.cm = cm
        self.__self__ = cm

    def __call__(self, exc_type, exc, tb):
        return _await(self.cm.__aexit__(exc_type, exc, tb))


class _AsyncExitStackCallback:
    # stack.push_async_callback(f, *args, **kwds)
    def __init__(self, callback, args, kwds):
        self.callback = callback
        self.args = args
        self.kwds = kwds
        self.__wrapped__ = callback

    def __call__(self, exc_type, exc, tb):
        _await(self.callback(*self.args, **self.kwds))


class _AsyncExitFn:
    # push_async_exit(f) of a plain async function: awaited when called
    def __init__(self, fn):
        self.fn = fn

    def __call__(self, exc_type, exc, tb):
        return _await(self.fn(exc_type, exc, tb))


class AsyncExitStack(_BaseExitStack, AbstractAsyncContextManager):
    """Async context manager for dynamic management of a stack of exit
    callbacks.

    For example:
        async with AsyncExitStack() as stack:
            connections = [await stack.enter_async_context(get_connection())
                for i in range(5)]
            # All opened connections will automatically be released at the
            # end of the async with statement, even if attempts to open a
            # connection later in the list raise an exception.
    """

    async def enter_async_context(self, cm):
        """Enters the supplied async context manager.

        If successful, also pushes its __aexit__ method as a callback and
        returns the result of the __aenter__ method.
        """
        if not _has_method(cm, "__aenter__") or not _has_method(cm, "__aexit__"):
            raise TypeError("'" + _cls_label(cm) + "' object does not support the asynchronous context manager protocol")
        var result = _await(cm.__aenter__())
        self._exit_callbacks.append(_AsyncExitStackCMExit(cm))
        return result

    def push_async_exit(self, exit):
        """Registers a coroutine function with the standard __aexit__ method
        signature.

        Can suppress exceptions the same way __aexit__ method can.
        Also accepts any object with an __aexit__ method (registering a call
        to the method instead of the object itself).
        """
        if _has_method(exit, "__aexit__"):
            self._exit_callbacks.append(_AsyncExitStackCMExit(exit))
        else:
            self._exit_callbacks.append(_AsyncExitFn(exit))
        return exit  # Allow use as a decorator

    def push_async_callback(self, callback, *args, **kwds):
        """Registers an arbitrary coroutine function and arguments.

        Cannot suppress exceptions.
        """
        self._exit_callbacks.append(_AsyncExitStackCallback(callback, args, kwds))
        return callback  # Allow use as a decorator

    async def aclose(self):
        "Immediately unwind the context stack."
        _unwind(self, (none, none, none))

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc_details):
        # the exits are called in turn as ExitStack's; the async ones are
        # awaited inside their wrappers
        return _unwind(self, exc_details)


def _unwind(stack, exc_details):
    # the exits of an ExitStack / AsyncExitStack, last in first out
    var exc_type = exc_details[0] if len(exc_details) > 0 else none
    var exc = exc_details[1] if len(exc_details) > 1 else none
    var tb = exc_details[2] if len(exc_details) > 2 else none
    var received_exc = exc_type is not none
    # the exception being handled while the exits run (Python's
    # sys.exc_info()): the one the with block raised
    var frame_exc = exc
    var suppressed_exc = false
    var pending_raise = false
    # Callbacks are invoked in LIFO order to match the behaviour of
    # nested context managers
    while len(stack._exit_callbacks) > 0:
        var cb = stack._exit_callbacks.pop()
        var raised = none
        var suppressing = false
        try:
            suppressing = cb(exc_type, exc, tb)
        except BaseException as new_exc:
            raised = new_exc
        if raised is not none:
            # Python chains an exception raised there to frame_exc by
            # itself; the runtime does not, so it is done here first
            if frame_exc is not none and not _same(raised, frame_exc) and _attr_or_none(raised, "__context__") is none:
                raised.__context__ = frame_exc
            # simulate the stack of exceptions by setting the context
            _fix_exception_context(raised, exc, frame_exc)
            pending_raise = true
            exc_type = raised.__class__
            exc = raised
            tb = none
        elif suppressing:
            suppressed_exc = true
            pending_raise = false
            exc_type = none
            exc = none
            tb = none
    if pending_raise:
        raise exc
    return received_exc and suppressed_exc


def _fix_exception_context(new_exc, old_exc, frame_exc):
    # Python's: the context chain of new_exc is followed to the end, or to
    # the exception that was being handled anyway (frame_exc), and old_exc
    # becomes the context there
    var e = new_exc
    var seen = 0
    while seen < 10000:
        var exc_context = _attr_or_none(e, "__context__")
        if exc_context is none or _same(exc_context, old_exc):
            # context is already set correctly (see issue 20317)
            return
        if _same(exc_context, frame_exc):
            break
        e = exc_context
        seen += 1
    # change the end of the chain to point to the exception we expect it
    # to reference
    e.__context__ = old_exc
