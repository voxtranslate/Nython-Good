# nython: module    (import it by name: it runs in a module scope of its own)
# lib/profile.ny - Python's profile: the pure-Python deterministic profiler
# (round 79). lib/cProfile.ny is the same interface with _lsprof's
# bookkeeping; this is CPython's profile.py algorithm, as written there.
#
#     import profile
#     profile.run("work()")
#     p = profile.Profile(); p.runcall(work); p.print_stats()
#
#     nython -m profile [-o OUTFILE] [-s SORT] [-m MODULE | script.ny] [args ...]
#
# Profile(timer=None, bias=None)
#   run(cmd), runctx(cmd, globals, locals), runcall(func, *args, **kw),
#   print_stats(sort=-1), dump_stats(file), create_stats(),
#   snapshot_stats(), simulate_call(name), simulate_cmd_complete(),
#   set_cmd(cmd), calibrate(m, verbose=0), trace_dispatch* and the
#   dispatch table, fake_code / fake_frame, .timings, .stats, .bias
# run(statement, filename=None, sort=-1), runctx(statement, globals,
# locals, filename=None, sort=-1), main()
#
# Its stats are CPython's profile format: callers map each caller to a
# call count (pstats prints them as "file:line(name)(count) cumtime"); the
# profiler's own base entry is ("profile", 0, "profiler") and a builtin is
# ("", 0, its __name__), as profile.py names them.
#
# Not here: dump_stats writes pstats' Nython format, not marshal. The
# timer is time.process_time unless one is given (as CPython); a timer
# returning a tuple (os.times style) is accepted.

import sys
import time

__all__ = ["run", "runctx", "Profile"]


class _Utils:
    """Support class for utility functions which are shared by
    profile.py and cProfile.py modules.
    Not supposed to be used directly.
    """

    def __init__(self, profiler):
        self.profiler = profiler

    def run(self, statement, filename, sort):
        prof = self.profiler()
        try:
            prof.run(statement)
        except SystemExit:
            pass
        finally:
            self._show(prof, filename, sort)

    def runctx(self, statement, globals, locals, filename, sort):
        prof = self.profiler()
        try:
            prof.runctx(statement, globals, locals)
        except SystemExit:
            pass
        finally:
            self._show(prof, filename, sort)

    def _show(self, prof, filename, sort):
        if filename is not None:
            prof.dump_stats(filename)
        else:
            prof.print_stats(sort)


def run(statement, filename=None, sort=-1):
    """Run statement under profiler optionally saving results in filename

    This function takes a single argument that can be passed to the
    "exec" statement, and an optional file name.  In all cases this
    routine attempts to "exec" its first argument and gather profiling
    statistics from the execution. If no file name is present, then this
    function automatically prints a simple profiling report, sorted by the
    standard name string (file/line/function-name) that is presented in
    each line.
    """
    return _Utils(Profile).run(statement, filename, sort)


def runctx(statement, globals, locals, filename=None, sort=-1):
    """Run statement under profiler, supplying your own globals and locals,
    optionally saving results in filename.

    statement and filename have the same semantics as profile.run
    """
    return _Utils(Profile).runctx(statement, globals, locals, filename, sort)


class _fake_code:
    def __init__(self, filename, line, name):
        self.co_filename = filename
        self.co_line = line
        self.co_name = name
        self.co_firstlineno = 0

    def __repr__(self):
        return repr((self.co_filename, self.co_line, self.co_name))


class _fake_frame:
    def __init__(self, code, prior):
        self.f_code = code
        self.f_back = prior


class Profile:
    """Profiler class.

    self.cur is always a tuple.  Each such tuple corresponds to a stack
    frame that is currently active (self.cur[-2]).  The following are the
    definitions of its members.  We use this external "parallel stack" to
    avoid contaminating the program that we are profiling. (old profiler
    used to write into the frames local dictionary!!) Derived classes
    can change the definition of some entries, as long as they leave
    [-2:] intact (frame and previous tuple).  In case an internal error is
    detected, the -3 element is used as the function name.

    [ 0] = Time that needs to be charged to the parent frame's function.
           It is used so that a function call will not have to access the
           timing data for the parent frame.
    [ 1] = Total time spent in this frame's function, excluding time in
           subfunctions (this latter is tallied in cur[2]).
    [ 2] = Total time spent in subfunctions, excluding time executing the
           frame's function (this latter is tallied in cur[1]).
    [-3] = Name of the function that corresponds to this frame.
    [-2] = Actual frame that we correspond to (used to sync exception handling).
    [-1] = Our parent 6-tuple (corresponds to frame.f_back).

    Timing data for each function is stored as a 5-tuple in the dictionary
    self.timings[].  The index is always the name stored in self.cur[-3].
    The following are the definitions of the members:

    [0] = The number of times this function was called, not counting direct
          or indirect recursion,
    [1] = Number of times this function appears on the stack, minus one
    [2] = Total time spent internal to this function
    [3] = Cumulative time that this function was present on the stack.  In
          non-recursive functions, this is the total execution time from start
          to finish of each invocation of a function, including time spent in
          all subfunctions.
    [4] = A dictionary indicating for each function name, the number of times
          it was called by us.
    """

    bias = 0  # calibration constant

    fake_code = _fake_code
    fake_frame = _fake_frame

    def __init__(self, timer=None, bias=None):
        self.timings = {}
        self.cur = None
        self.cmd = ""
        self.c_func_name = ""
        self.stats = {}
        if bias is None:
            bias = self.bias
        self.bias = bias     # Materialize in local dict for lookup speed.
        if not timer:
            self.timer = time.process_time
            self.get_time = time.process_time
            self._tuple_timer = False
        else:
            self.timer = timer
            t = self.timer()  # test out timer function
            self._tuple_timer = isinstance(t, (tuple, list))
            if self._tuple_timer:
                def get_time_timer(timer=timer):
                    var tt = timer()
                    return tt[0] + tt[1]
                self.get_time = get_time_timer
            else:
                self.get_time = timer
        self.dispatcher = self.trace_dispatch
        # Following is a hack to make "profiler" the base of the stack
        self.t = self.get_time()
        self.simulate_call("profiler")

    # Heavily optimized dispatch routine for time.process_time() timer
    def trace_dispatch(self, frame, event, arg):
        t = self.get_time() - self.t - self.bias
        if event == "c_call":
            self.c_func_name = arg.__name__
        if self._dispatch(event, frame, t):
            self.t = self.get_time()
        else:
            self.t = self.get_time() - t  # put back unrecorded delta

    trace_dispatch_i = trace_dispatch
    trace_dispatch_l = trace_dispatch

    def _dispatch(self, event, frame, t):
        if event == "call":
            return self.trace_dispatch_call(frame, t)
        if event == "exception":
            return self.trace_dispatch_exception(frame, t)
        if event == "return":
            return self.trace_dispatch_return(frame, t)
        if event == "c_call":
            return self.trace_dispatch_c_call(frame, t)
        if event == "c_exception" or event == "c_return":
            return self.trace_dispatch_return(frame, t)
        return 0

    # In the event handlers, the first 3 elements of self.cur are unpacked
    # into vrbls w/ 3-letter names.  The last two characters are meant to be
    # mnemonic:
    #     _pt  self.cur[0] "parent time"   time to be charged to parent frame
    #     _it  self.cur[1] "internal time" time spent directly in the function
    #     _et  self.cur[2] "external time" time spent in subfunctions

    def trace_dispatch_exception(self, frame, t):
        rpt, rit, ret, rfn, rframe, rcur = self.cur
        if (rframe is not frame) and rcur:
            return self.trace_dispatch_return(rframe, t)
        self.cur = rpt, rit + t, ret, rfn, rframe, rcur
        return 1

    def trace_dispatch_call(self, frame, t):
        if self.cur and frame.f_back is not self.cur[-2]:
            rpt, rit, ret, rfn, rframe, rcur = self.cur
            if not isinstance(rframe, _fake_frame):
                self.trace_dispatch_return(rframe, 0)
        fcode = frame.f_code
        fn = (fcode.co_filename, fcode.co_firstlineno, fcode.co_name)
        self.cur = (t, 0, 0, fn, frame, self.cur)
        timings = self.timings
        if fn in timings:
            cc, ns, tt, ct, callers = timings[fn]
            timings[fn] = cc, ns + 1, tt, ct, callers
        else:
            timings[fn] = 0, 0, 0, 0, {}
        return 1

    def trace_dispatch_c_call(self, frame, t):
        fn = ("", 0, self.c_func_name)
        self.cur = (t, 0, 0, fn, frame, self.cur)
        timings = self.timings
        if fn in timings:
            cc, ns, tt, ct, callers = timings[fn]
            timings[fn] = cc, ns + 1, tt, ct, callers
        else:
            timings[fn] = 0, 0, 0, 0, {}
        return 1

    def trace_dispatch_return(self, frame, t):
        if frame is not self.cur[-2]:
            if self.cur[-2] is not None and frame is getattr(self.cur[-2], "f_back", None):
                self.trace_dispatch_return(self.cur[-2], 0)
            elif self.cur[-1] is None:
                return 0   # a return of a frame that started before the profiler did
        # Prefix "r" means part of the Returning or exiting frame.
        # Prefix "p" means part of the Previous or Parent or older frame.
        rpt, rit, ret, rfn, frame, rcur = self.cur
        if rcur is None:
            return 0
        rit = rit + t
        frame_total = rit + ret
        ppt, pit, pet, pfn, pframe, pcur = rcur
        self.cur = ppt, pit + rpt, pet + frame_total, pfn, pframe, pcur
        timings = self.timings
        cc, ns, tt, ct, callers = timings[rfn]
        if not ns:
            # This is the only occurrence of the function on the stack.
            # Else this is a (directly or indirectly) recursive call, and
            # its cumulative time will get updated when the topmost call to
            # it returns.
            ct = ct + frame_total
            cc = cc + 1
        if pfn in callers:
            callers[pfn] = callers[pfn] + 1  # hack: gather more
        else:
            callers[pfn] = 1
        timings[rfn] = cc, ns - 1, tt + rit, ct, callers
        return 1

    dispatch = {
        "call": trace_dispatch_call,
        "exception": trace_dispatch_exception,
        "return": trace_dispatch_return,
        "c_call": trace_dispatch_c_call,
        "c_exception": trace_dispatch_return,  # the C function returned
        "c_return": trace_dispatch_return,
    }

    # The next few functions play with self.cmd. By carefully preloading
    # our parallel stack, we can force the profiled result to include
    # an arbitrary string as the name of the calling function.
    # We use self.cmd as that string, and the resulting stats look
    # very nice :-).

    def set_cmd(self, cmd):
        if self.cur[-1]:
            return   # already set
        self.cmd = cmd
        self.simulate_call(cmd)

    def simulate_call(self, name):
        code = _fake_code("profile", 0, name)
        if self.cur:
            pframe = self.cur[-2]
        else:
            pframe = None
        frame = _fake_frame(code, pframe)
        self.trace_dispatch_call(frame, 0)

    # collect stats from pending stack, including getting final
    # timings for self.cmd frame.

    def simulate_cmd_complete(self):
        get_time = self.get_time
        t = get_time() - self.t
        while self.cur[-1]:
            # We *can* cause assertion errors here if
            # dispatch_trace_return checks for a frame match!
            self.trace_dispatch_return(self.cur[-2], t)
            t = 0
        self.t = get_time() - t

    def print_stats(self, sort=-1):
        import pstats
        pstats.Stats(self).strip_dirs().sort_stats(sort).print_stats()

    def dump_stats(self, file):
        import pstats
        self.create_stats()
        pstats.Stats(self).dump_stats(file)

    def create_stats(self):
        self.simulate_cmd_complete()
        self.snapshot_stats()

    def snapshot_stats(self):
        self.stats = {}
        for func, (cc, ns, tt, ct, callers) in self.timings.items():
            callers = callers.copy()
            nc = 0
            for callcnt in callers.values():
                nc += callcnt
            self.stats[func] = cc, nc, tt, ct, callers

    # The following two methods can be called by clients to use
    # a profiler to profile a statement, given as a string.

    def run(self, cmd):
        import __main__
        d = __main__.__dict__
        return self.runctx(cmd, d, d)

    def runctx(self, cmd, globals, locals):
        self.set_cmd(cmd)
        sys.setprofile(self.dispatcher)
        try:
            exec(cmd, globals, locals)
        finally:
            sys.setprofile(None)
        return self

    # This method is more useful to profile a single function call.
    def runcall(self, func, *args, **kw):
        self.set_cmd(repr(func))
        sys.setprofile(self.dispatcher)
        try:
            return func(*args, **kw)
        finally:
            sys.setprofile(None)

    def calibrate(self, m, verbose=0):
        """Measure the profiler's own overhead per event (CPython's
        calibrate): returns the bias to subtract from each event's time."""
        get_time = self.get_time

        def f1(n):
            for i in range(n):
                x = 1

        def f(m, f1=f1):
            for i in range(m):
                f1(100)

        f(m)    # warm up the cache
        t0 = get_time()
        f(m)
        t1 = get_time()
        elapsed_noprofile = t1 - t0
        if verbose:
            print("elapsed time without profiling =", elapsed_noprofile)
        p = Profile(timer=get_time)
        t0 = get_time()
        p.runcall(f, m)
        t1 = get_time()
        elapsed_profile = t1 - t0
        if verbose:
            print("elapsed time with profiling =", elapsed_profile)
        total_calls = 0.0
        reported_time = 0.0
        for (filename, line, funcname), (cc, ns, tt, ct, callers) in p.timings.items():
            if funcname in ("f", "f1"):
                total_calls += cc
                reported_time += tt
        if verbose:
            print("'CPU seconds' profiler reported =", reported_time)
            print("total # calls =", total_calls)
        if total_calls != m + 1:
            raise ValueError("internal error: total calls = %d" % total_calls)
        mean = (reported_time - elapsed_noprofile) / 2.0 / total_calls
        if verbose:
            print("mean stopwatch overhead per profile event =", mean)
        return mean


def main():
    import cProfile
    return cProfile._main_with(runctx, "profile.py")


if __name__ == "__main__":
    main()
