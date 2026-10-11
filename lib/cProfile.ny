# nython: module    (import it by name: it runs in a module scope of its own)
# lib/cProfile.ny - Python's cProfile: a deterministic profiler (round 79).
#
#     import cProfile
#     cProfile.run("work()", sort="cumulative")
#     with cProfile.Profile() as pr:
#         work()
#     pr.print_stats("tottime")
#
#     nython -m cProfile [-o OUTFILE] [-s SORT] [-m MODULE | script.ny] [args ...]
#
# Profile(timer=None, timeunit=0.0, subcalls=True, builtins=True)
#   enable(subcalls=True, builtins=True), disable(), runcall(func, *args,
#   **kw), run(cmd), runctx(cmd, globals, locals), create_stats(),
#   print_stats(sort=-1), dump_stats(file), getstats() (profiler_entry /
#   profiler_subentry records, as _lsprof's), __enter__/__exit__,
#   .stats after create_stats()
# run(statement, filename=None, sort=-1), runctx(statement, globals, locals,
# filename=None, sort=-1), label(code), main()
#
# It is CPython's _lsprof algorithm (the one cProfile is written in C as)
# over sys.setprofile: a context per call with its start time and the time
# of its sub-calls; at the return the call's total time goes to the
# function's cumulative time only when it is the outermost running call of
# that function (recursion level 0 - "3/1" calls), its time minus its
# sub-calls' to the internal time; the same per caller->callee pair
# (subcalls) gives each function's callers, in cProfile's tuple form
# (calls, primitive calls, internal time, cumulative time). c_call /
# c_return / c_exception events count builtins (builtins=True), named as
# _lsprof names them: "<built-in method builtins.len>", "<method 'append' of
# 'list' objects>". The disable() call is counted as CPython's
# "<method 'disable' of '_lsprof.Profiler' objects>".
#
# The profiler is written in Nython: each event runs its handler. The time
# the handlers take is measured and taken out of the clock the profile sees
# (an overhead offset, accumulated per event), so the reported times are
# the program's own; call counts are exact. The default timer is
# time.perf_counter (CPython's is the same clock in nanoseconds).
#
# Not here: dump_stats writes pstats' Nython format (see lib/pstats.ny),
# not marshal; timeunit is accepted and ignored (times are seconds).

import sys
import time
import pstats

__all__ = ["run", "runctx", "Profile"]

_DISABLE_LABEL = "<method 'disable' of '_lsprof.Profiler' objects>"


class profiler_entry:
    # one per function (_lsprof.profiler_entry): code, callcount,
    # reccallcount, totaltime, inlinetime, calls (its profiler_subentry list)
    def __init__(self, code, callcount, reccallcount, totaltime, inlinetime, calls):
        self.code = code
        self.callcount = callcount
        self.reccallcount = reccallcount
        self.totaltime = totaltime
        self.inlinetime = inlinetime
        self.calls = calls

    def __repr__(self):
        return ("_lsprof.profiler_entry(code=%r, callcount=%r, reccallcount=%r, totaltime=%r, inlinetime=%r, calls=%r)"
                % (self.code, self.callcount, self.reccallcount, self.totaltime, self.inlinetime, self.calls))


class profiler_subentry:
    def __init__(self, code, callcount, reccallcount, totaltime, inlinetime):
        self.code = code
        self.callcount = callcount
        self.reccallcount = reccallcount
        self.totaltime = totaltime
        self.inlinetime = inlinetime

    def __repr__(self):
        return ("_lsprof.profiler_subentry(code=%r, callcount=%r, reccallcount=%r, totaltime=%r, inlinetime=%r)"
                % (self.code, self.callcount, self.reccallcount, self.totaltime, self.inlinetime))


class _Entry:
    # ProfilerEntry: tt is the total (cumulative) time, it the inline time
    def __init__(self, key):
        self.key = key
        self.tt = 0.0
        self.it = 0.0
        self.callcount = 0
        self.recursivecallcount = 0
        self.recursionLevel = 0
        self.calls = {}     # callee key -> _Entry (a subentry: the same fields)


class _Context:
    def __init__(self, entry, previous, t0):
        self.entry = entry
        self.previous = previous
        self.subt = 0.0
        self.t0 = t0


def _builtin_label(fn):
    # _lsprof's normalizeUserObj
    name = getattr(fn, "__name__", None)
    if name is None:
        return repr(fn)
    owner = getattr(fn, "__self__", None)
    if owner is not None and type(owner).__name__ != "module":
        return "<method '%s' of '%s' objects>" % (name, type(owner).__name__)
    mod = getattr(fn, "__module__", None)
    if mod is None or mod == "builtins" or not isinstance(mod, str):
        mod = "builtins"
    return "<built-in method %s.%s>" % (mod, name)


def label(code):
    if isinstance(code, str):
        return ("~", 0, code)
    else:
        return (code.co_filename, code.co_firstlineno, code.co_name)


class Profile:
    """Profile(timer=None, timeunit=0.0, subcalls=True, builtins=True)

    Builds a profiler object using the specified timer function.
    The default timer is a fast built-in one based on real time.
    For custom timer functions returning integers, timeunit can
    be a float specifying a scale (i.e. how long each integer unit
    is, in seconds).
    """

    def __init__(self, timer=None, timeunit=0.0, subcalls=True, builtins=True):
        self.timer = timer if timer is not None else time.perf_counter
        self.timeunit = timeunit
        self.subcalls = subcalls
        self.builtins = builtins
        self.stats = {}
        self._entries = {}      # key -> _Entry
        self._order = []        # keys in first-seen order
        self._codes = {}        # key -> what getstats() reports as code
        self._cur = None        # the innermost running _Context
        self._ovh = 0.0         # the time spent in the handlers so far
        self._enabled = False
        self._disable_code = None

    # ── the events ───────────────────────────────────────────────────────
    def _entry(self, key, code):
        e = self._entries.get(key)
        if e is None:
            e = _Entry(key)
            self._entries[key] = e
            self._order.append(key)
            self._codes[key] = code
        return e

    def _sub(self, caller, callee):
        s = caller.calls.get(callee.key)
        if s is None:
            s = _Entry(callee.key)
            caller.calls[callee.key] = s
        return s

    def _enter(self, key, code, t):
        e = self._entry(key, code)
        ctx = _Context(e, self._cur, t)
        self._cur = ctx
        e.recursionLevel += 1
        if self.subcalls and ctx.previous is not None:
            self._sub(ctx.previous.entry, e).recursionLevel += 1

    def _leave(self, t):
        ctx = self._cur
        if ctx is None:
            return
        e = ctx.entry
        tt = t - ctx.t0
        it = tt - ctx.subt
        if ctx.previous is not None:
            ctx.previous.subt += tt
        self._cur = ctx.previous
        e.recursionLevel -= 1
        if e.recursionLevel == 0:
            e.tt += tt
        else:
            e.recursivecallcount += 1
        e.it += it
        e.callcount += 1
        if self.subcalls and ctx.previous is not None:
            s = self._sub(ctx.previous.entry, e)
            s.recursionLevel -= 1
            if s.recursionLevel == 0:
                s.tt += tt
            else:
                s.recursivecallcount += 1
            s.it += it
            s.callcount += 1

    def _dispatch(self, frame, event, arg):
        raw = self.timer()
        t = raw - self._ovh
        if event == "call":
            code = frame.f_code
            if self._disable_code is not None and code.co_name == "disable" and code.co_filename == self._disable_code[0] \
               and code.co_firstlineno == self._disable_code[1]:
                self._enter(("~", 0, _DISABLE_LABEL), _DISABLE_LABEL, t)
            else:
                self._enter((code.co_filename, code.co_firstlineno, code.co_name), code, t)
        elif event == "return":
            self._leave(t)
        elif event == "c_call":
            if self.builtins:
                lbl = _builtin_label(arg)
                self._enter(("~", 0, lbl), lbl, t)
        elif event == "c_return" or event == "c_exception":
            if self.builtins:
                self._leave(t)
        self._ovh += self.timer() - raw

    # ── the API ──────────────────────────────────────────────────────────
    def enable(self, subcalls=True, builtins=True):
        """enable(subcalls=True, builtins=True)

        Start collecting profiling information.
        If 'subcalls' is True, also records for each function
        statistics separated according to its current caller.
        If 'builtins' is True, records the time spent in
        built-in functions separately from their caller.
        """
        self.subcalls = subcalls
        self.builtins = builtins
        if self._disable_code is None:
            dc = Profile.disable.__code__
            self._disable_code = (dc.co_filename, dc.co_firstlineno)
        self._enabled = True
        sys.setprofile(self._dispatch)

    def disable(self):
        """disable()

        Stop collecting profiling information.
        """
        sys.setprofile(None)
        self._enabled = False
        self._flush()

    def _flush(self):
        # _lsprof's flush_unmatched: the calls still running end now
        t = self.timer() - self._ovh
        while self._cur is not None:
            self._leave(t)

    def getstats(self):
        """list of profiler_entry objects.

        getstats() -> list of profiler_entry objects

        Return all information collected by the profiler.
        Each profiler_entry is a tuple-like object with the
        following attributes:

            code          code object
            callcount     how many times this was called
            reccallcount  how many times called recursively
            totaltime     total time in this entry
            inlinetime    inline time in this entry (not in subcalls)
            calls         details of the calls

        The calls attribute is either None or a list of
        profiler_subentry objects:

            code          called code object
            callcount     how many times this is called
            reccallcount  how many times this is called recursively
            totaltime     total time spent in this call
            inlinetime    inline time (not in further subcalls)
        """
        out = []
        for key in self._order:
            e = self._entries[key]
            calls = None
            if e.calls:
                calls = []
                for ck, s in e.calls.items():
                    calls.append(profiler_subentry(self._codes.get(ck, ck), s.callcount, s.recursivecallcount, s.tt, s.it))
            out.append(profiler_entry(self._codes[key], e.callcount, e.recursivecallcount, e.tt, e.it, calls))
        return out

    def print_stats(self, sort=-1):
        pstats.Stats(self).strip_dirs().sort_stats(sort).print_stats()

    def dump_stats(self, file):
        self.create_stats()
        pstats.Stats(self).dump_stats(file)

    def create_stats(self):
        self.disable()
        self.snapshot_stats()

    def snapshot_stats(self):
        self.stats = {}
        callersdicts = {}
        # call information
        for key in self._order:
            e = self._entries[key]
            nc = e.callcount
            cc = nc - e.recursivecallcount
            callers = {}
            callersdicts[key] = callers
            self.stats[key] = (cc, nc, e.it, e.tt, callers)
        # subcall information
        for key in self._order:
            e = self._entries[key]
            for ck, s in e.calls.items():
                callers = callersdicts.get(ck)
                if callers is None:
                    continue
                nc = s.callcount
                cc = nc - s.recursivecallcount
                tt = s.it
                ct = s.tt
                if key in callers:
                    prev = callers[key]
                    nc += prev[0]
                    cc += prev[1]
                    tt += prev[2]
                    ct += prev[3]
                callers[key] = (nc, cc, tt, ct)

    # The following two methods can be called by clients to use
    # a profiler to profile a statement, given as a string.

    def run(self, cmd):
        import __main__
        d = __main__.__dict__
        return self.runctx(cmd, d, d)

    def runctx(self, cmd, globals, locals):
        self.enable()
        try:
            exec(cmd, globals, locals)
        finally:
            self.disable()
        return self

    # This method is more useful to profile a single function call.
    def runcall(self, func, *args, **kw):
        self.enable()
        try:
            return func(*args, **kw)
        finally:
            self.disable()

    def __enter__(self):
        self.enable()
        return self

    def __exit__(self, *exc_info):
        self.disable()


# ── the module functions ─────────────────────────────────────────────────
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
    prof = Profile()
    try:
        prof.run(statement)
    except SystemExit:
        pass
    finally:
        _show(prof, filename, sort)


def runctx(statement, globals, locals, filename=None, sort=-1):
    """Run statement under profiler, supplying your own globals and locals,
    optionally saving results in filename.

    statement and filename have the same semantics as profile.run
    """
    prof = Profile()
    try:
        prof.runctx(statement, globals, locals)
    except SystemExit:
        pass
    finally:
        _show(prof, filename, sort)


def _show(prof, filename, sort):
    if filename is not None:
        prof.dump_stats(filename)
    else:
        prof.print_stats(sort)


def main():
    return _main_with(runctx, "cProfile.py")


def _main_with(runctx_fn, progname):
    # the command line of cProfile.py / profile.py
    import os
    usage = progname + " [-o output_file_path] [-s sort] [-m module | scriptfile] [arg] ..."
    args = sys.argv[1:]
    outfile = None
    sort = -1
    module = False
    valid = sorted(pstats.Stats.sort_arg_dict_default)
    while args and args[0].startswith("-") and args[0] != "-":
        a = args[0]
        args = args[1:]
        if a in ("-o", "--outfile"):
            outfile = args[0]
            args = args[1:]
        elif a.startswith("--outfile="):
            outfile = a[10:]
        elif a in ("-s", "--sort"):
            sort = args[0]
            args = args[1:]
            if sort not in valid:
                print("Usage: " + usage, file=sys.stderr)
                print(progname + ": error: option -s: invalid choice: %r (choose from %s)"
                      % (sort, ", ".join([repr(v) for v in valid])), file=sys.stderr)
                sys.exit(2)
        elif a.startswith("--sort="):
            sort = a[7:]
        elif a == "-m":
            module = True
        elif a in ("-h", "--help"):
            print("Usage: " + usage)
            sys.exit(0)
        elif a == "--":
            break
        else:
            print("Usage: " + usage, file=sys.stderr)
            print(progname + ": error: no such option: " + a, file=sys.stderr)
            sys.exit(2)
    if not args:
        print("Usage: " + usage)
        sys.exit(2)
    target = args[0]
    if module:
        path = target.replace(".", "/") + ".ny"
        if not os.path.exists(path) and os.path.exists(os.path.join("lib", path)):
            path = os.path.join("lib", path)
        target = path
    sys.argv[:] = args
    f = open(target)
    try:
        src = f.read()
    finally:
        f.close()
    code = compile(src, target, "exec")
    globs = {"__file__": target, "__name__": "__main__", "__package__": None, "__cached__": None}
    try:
        runctx_fn(code, globs, None, outfile, sort)
    except BrokenPipeError as exc:
        # Prevent "Exception ignored" during interpreter shutdown.
        sys.stdout = None
        sys.exit(exc.errno)
    return 0


if __name__ == "__main__":
    main()
