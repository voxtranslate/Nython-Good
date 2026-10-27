# nython: module    (a package: concurrent.futures._base, .thread, .process)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/concurrent/futures - Python's concurrent.futures (3.11): run calls
# asynchronously on a pool of threads or of processes (round 79).
#
#     from concurrent.futures import ThreadPoolExecutor, as_completed
#     with ThreadPoolExecutor(max_workers=4) as ex:
#         futures = [ex.submit(pow, 2, n) for n in range(10)]
#         for f in as_completed(futures):
#             print(f.result())
#         print(list(ex.map(str.upper, ["a", "b"])))
#
# Future (result/exception with timeout, done, running, cancel, cancelled,
# add_done_callback, set_running_or_notify_cancel, set_result,
# set_exception, Future[int]), Executor (submit, map with timeout and
# chunksize, shutdown, the with statement), ThreadPoolExecutor
# (lib/concurrent/futures/thread.ny: CPython's thread.py), ProcessPoolExecutor
# (lib/concurrent/futures/process.ny: real worker processes, Nython's own
# transport - see there for what can be sent), wait (FIRST_COMPLETED,
# FIRST_EXCEPTION, ALL_COMPLETED), as_completed, CancelledError,
# TimeoutError (the builtin), InvalidStateError, BrokenExecutor (and the
# pools' BrokenThreadPool / BrokenProcessPool). The algorithms of _base.py
# and thread.py are CPython's, so callbacks, waiters and the order of
# as_completed behave the same.

from concurrent.futures._base import (FIRST_COMPLETED,
                                      FIRST_EXCEPTION,
                                      ALL_COMPLETED,
                                      CancelledError,
                                      TimeoutError,
                                      InvalidStateError,
                                      BrokenExecutor,
                                      Future,
                                      Executor,
                                      wait,
                                      as_completed)
from concurrent.futures.thread import ThreadPoolExecutor
from concurrent.futures.process import ProcessPoolExecutor

__all__ = (
    'FIRST_COMPLETED',
    'FIRST_EXCEPTION',
    'ALL_COMPLETED',
    'CancelledError',
    'TimeoutError',
    'BrokenExecutor',
    'Future',
    'Executor',
    'wait',
    'as_completed',
    'ProcessPoolExecutor',
    'ThreadPoolExecutor',
)
