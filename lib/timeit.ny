# nython: module    (import it by name: it runs in a module scope of its own)
# lib/timeit.ny - Python's timeit: time small bits of code (round 79).
#
#     import timeit
#     timeit.timeit("x = sum(range(100))", number=1000)
#     timeit.repeat("d[k]", setup="d = {'a': 1}; k = 'a'", repeat=3, number=10000)
#     t = timeit.Timer(lambda: sorted(xs))
#     t.autorange()                       # (number, seconds) with seconds >= 0.2
#
#     nython -m timeit [-n N] [-r N] [-s S] [-u U] [-p] [-v] [-h] [statement ...]
#
# Timer(stmt="pass", setup="pass", timer=default_timer, globals=None)
#   stmt / setup as source text (compiled first, so a syntax error is raised
#   when the Timer is made; several statements separated by ";" or newlines)
#   or as callables; the code runs in a function made from CPython's
#   template, in `globals` (the timeit module's own names when None) - so a
#   statement sees what setup bound;
#   timeit(number=1000000)  seconds for `number` executions, the cycle
#                           collector disabled meanwhile (gc_disable, as
#                           CPython's gc.disable) and re-enabled after
#   repeat(repeat=5, number=1000000)   a list of timeit() results
#   autorange(callback=None)   numbers 1, 2, 5, 10, 20, 50 ... until the total
#                           is at least 0.2 s: (number, time_taken);
#                           callback(number, time_taken) after each try
#   print_exc(file=None)    the traceback of the error the timed code raised,
#                           with the template's lines (<timeit-src> in
#                           linecache)
#   .src                    the generated source
# timeit(stmt, setup, timer, number, globals), repeat(stmt, setup, timer,
# repeat, number, globals), default_timer (time.perf_counter),
# default_number (1000000), default_repeat (5), main(args=None) - the
# command line, CPython's options and output ("10000 loops, best of 5:
# 1.23 usec per loop", -v adds every try and the raw times, the
# "results are likely unreliable" warning when the worst repeat is four
# times the best).
#
# Not here: the loop runs over range(number) rather than
# itertools.repeat(None, number) (the same number of iterations; the
# interpreter's range loop makes no object per step). The command line's
# sys.path insertion (there is no sys.path) - imports look in the working
# directory anyway.

import sys
import time

__all__ = ["Timer", "timeit", "repeat", "default_timer"]

dummy_src_name = "<timeit-src>"
default_number = 1000000
default_repeat = 5
default_timer = time.perf_counter

_module_globals = globals

# Don't change the indentation of the template; the reindent() calls
# in Timer.__init__() depend on setup being indented 4 spaces and stmt
# being indented 8 spaces.
template = """
def inner(_it, _timer{init}):
    {setup}
    _t0 = _timer()
    for _i in _it:
        {stmt}
        pass
    _t1 = _timer()
    return _t1 - _t0
"""


def reindent(src, indent):
    """Helper to reindent a multi-line statement."""
    return src.replace("\n", "\n" + " " * indent)


class Timer:
    """Class for timing execution speed of small code snippets.

    The constructor takes a statement to be timed, an additional
    statement used for setup, and a timer function.  Both statements
    default to 'pass'; the timer function is platform-dependent (see
    module doc string).  If 'globals' is specified, the code will be
    executed within that namespace (as opposed to inside timeit's
    namespace).
    """

    def __init__(self, stmt="pass", setup="pass", timer=default_timer, globals=None):
        """Constructor.  See class doc string."""
        self.timer = timer
        local_ns = {}
        global_ns = _module_globals() if globals is None else globals
        init = ""
        if isinstance(setup, str):
            # Check that the code can be compiled outside a function
            compile(setup, dummy_src_name, "exec")
            stmtprefix = setup + "\n"
            setup = reindent(setup, 4)
        elif callable(setup):
            local_ns["_setup"] = setup
            init += ", _setup=_setup"
            stmtprefix = ""
            setup = "_setup()"
        else:
            raise ValueError("setup is neither a string nor callable")
        if isinstance(stmt, str):
            # Check that the code can be compiled outside a function
            compile(stmtprefix + stmt, dummy_src_name, "exec")
            stmt = reindent(stmt, 8)
        elif callable(stmt):
            local_ns["_stmt"] = stmt
            init += ", _stmt=_stmt"
            stmt = "_stmt()"
        else:
            raise ValueError("stmt is neither a string nor callable")
        src = template.replace("{stmt}", stmt).replace("{setup}", setup).replace("{init}", init)
        self.src = src  # Save for traceback display
        code = compile(src, dummy_src_name, "exec")
        exec(code, global_ns, local_ns)
        self.inner = local_ns["inner"]

    def print_exc(self, file=None):
        """Helper to print a traceback from the timed code.

        Typical use:

            t = Timer(...)       # outside the try/except
            try:
                t.timeit(...)    # or t.repeat(...)
            except:
                t.print_exc()
        """
        import linecache
        import traceback
        if self.src is not None:
            linecache.cache[dummy_src_name] = (len(self.src), None, self.src.split("\n"), dummy_src_name)
        traceback.print_exc(file=file)

    def timeit(self, number=default_number):
        """Time 'number' executions of the main statement.

        To be precise, this executes the setup statement once, and
        then returns the time it takes to execute the main statement
        a number of times, as float seconds if using the default timer.
        """
        it = range(number)
        gcold = gc_is_enabled()
        gc_disable()
        try:
            timing = self.inner(it, self.timer)
        finally:
            if gcold:
                gc_enable()
        return timing

    def repeat(self, repeat=default_repeat, number=default_number):
        """Call timeit() a few times.

        This is a convenience function that calls the timeit()
        repeatedly, returning a list of results.
        """
        r = []
        for i in range(repeat):
            t = self.timeit(number)
            r.append(t)
        return r

    def autorange(self, callback=None):
        """Return the number of loops and time taken so that total time >= 0.2.

        Calls the timeit method with increasing numbers from the sequence
        1, 2, 5, 10, 20, 50, ... until the time taken is at least 0.2
        second.  Returns (number, time_taken).

        If *callback* is given and is not None, it will be called after
        each trial with two arguments: ``callback(number, time_taken)``.
        """
        i = 1
        while True:
            for j in (1, 2, 5):
                number = i * j
                time_taken = self.timeit(number)
                if callback:
                    callback(number, time_taken)
                if time_taken >= 0.2:
                    return (number, time_taken)
            i *= 10


def timeit(stmt="pass", setup="pass", timer=default_timer, number=default_number, globals=None):
    """Convenience function to create Timer object and call timeit method."""
    return Timer(stmt, setup, timer, globals).timeit(number)


def repeat(stmt="pass", setup="pass", timer=default_timer, repeat=default_repeat, number=default_number, globals=None):
    """Convenience function to create Timer object and call repeat method."""
    return Timer(stmt, setup, timer, globals).repeat(repeat, number)


_USAGE = """Tool for measuring execution time of small code snippets.

Command line usage:
    nython -m timeit [-n N] [-r N] [-u U] [-s S] [-p] [-v] [-h] [--] [statement]

Options:
  -n/--number N: how many times to execute 'statement' (default: see below)
  -r/--repeat N: how many times to repeat the timer (default 5)
  -s/--setup S: statement to be executed once initially (default 'pass').
                Execution time of this setup statement is NOT timed.
  -p/--process: use time.process_time() (default is time.perf_counter())
  -v/--verbose: print raw timing results; repeat for more digits precision
  -u/--unit: set the output time unit (nsec, usec, msec, or sec)
  -h/--help: print this usage message and exit
  --: separate options from statement, use when statement starts with -
  statement: statement to be timed (default 'pass')

A multi-line statement may be given by specifying each line as a
separate argument; indented lines are possible by enclosing an
argument in quotes and using leading spaces.  Multiple -s options are
treated similarly.

If -n is not given, a suitable number of loops is calculated by trying
increasing numbers from the sequence 1, 2, 5, 10, 20, 50, ... until the
total time is at least 0.2 seconds.
"""


class _GetoptError(Exception):
    pass


def _getopt(args, shortopts, longopts):
    # getopt.getopt's rules (there is no getopt module here)
    opts = []
    args = list(args)
    while args and args[0].startswith("-") and args[0] != "-":
        if args[0] == "--":
            args = args[1:]
            break
        if args[0].startswith("--"):
            body = args[0][2:]
            args = args[1:]
            val = None
            if "=" in body:
                body, val = body.split("=", 1)
            matches = [o for o in longopts if o.startswith(body)]
            if not matches:
                raise _GetoptError("option --%s not recognized" % body)
            exact = [o for o in matches if o == body or o == body + "="]
            if exact:
                matches = exact
            if len(matches) > 1:
                raise _GetoptError("option --%s not a unique prefix" % body)
            o = matches[0]
            if o.endswith("="):
                if val is None:
                    if not args:
                        raise _GetoptError("option --%s requires argument" % o[:-1])
                    val = args[0]
                    args = args[1:]
                opts.append(("--" + o[:-1], val))
            else:
                if val is not None:
                    raise _GetoptError("option --%s must not have an argument" % o)
                opts.append(("--" + o, ""))
        else:
            s = args[0][1:]
            args = args[1:]
            while s != "":
                c = s[0]
                s = s[1:]
                k = shortopts.find(c)
                if c == ":" or k < 0:
                    raise _GetoptError("option -%s not recognized" % c)
                if k + 1 < len(shortopts) and shortopts[k + 1] == ":":
                    if s == "":
                        if not args:
                            raise _GetoptError("option -%s requires argument" % c)
                        s = args[0]
                        args = args[1:]
                    opts.append(("-" + c, s))
                    s = ""
                else:
                    opts.append(("-" + c, ""))
    return opts, args


def main(args=None, *, _wrap_timer=None):
    """Main program, used when run as a script.

    The optional 'args' argument specifies the command line to be parsed,
    defaulting to sys.argv[1:].

    The return value is an exit code to be passed to sys.exit(); it
    may be None to indicate success.

    When an exception happens during timing, a traceback is printed to
    stderr and the return value is 1.  Exceptions at other times
    (including the template compilation) are not caught.
    """
    if args is None:
        args = sys.argv[1:]
    try:
        opts, args = _getopt(args, "n:u:s:r:tcpvh",
                             ["number=", "setup=", "repeat=", "time", "clock", "process", "verbose", "unit=", "help"])
    except _GetoptError as err:
        print(err)
        print("use -h/--help for command line help")
        return 2

    timer = default_timer
    stmt = "\n".join(args) or "pass"
    number = 0  # auto-determine
    setup = []
    repeat = default_repeat
    verbose = 0
    time_unit = None
    units = {"nsec": 1e-9, "usec": 1e-6, "msec": 1e-3, "sec": 1.0}
    precision = 3
    for o, a in opts:
        if o in ("-n", "--number"):
            number = int(a)
        if o in ("-s", "--setup"):
            setup.append(a)
        if o in ("-u", "--unit"):
            if a in units:
                time_unit = a
            else:
                print("Unrecognized unit. Please select nsec, usec, msec, or sec.", file=sys.stderr)
                return 2
        if o in ("-r", "--repeat"):
            repeat = int(a)
            if repeat <= 0:
                repeat = 1
        if o in ("-p", "--process"):
            timer = time.process_time
        if o in ("-v", "--verbose"):
            if verbose:
                precision += 1
            verbose += 1
        if o in ("-h", "--help"):
            print(_USAGE, end=" ")
            return 0
    setup = "\n".join(setup) or "pass"
    if _wrap_timer is not None:
        timer = _wrap_timer(timer)

    t = Timer(stmt, setup, timer)
    if number == 0:
        # determine number so that 0.2 <= total time < 2.0
        callback = None
        if verbose:
            def callback(number, time_taken):
                plural = number != 1
                print("%d loop%s -> %s secs" % (number, "s" if plural else "", _g(time_taken, precision)))
        try:
            number, _ = t.autorange(callback)
        except BaseException:
            t.print_exc()
            return 1
        if verbose:
            print()

    try:
        raw_timings = t.repeat(repeat, number)
    except BaseException:
        t.print_exc()
        return 1

    def format_time(dt):
        unit = time_unit
        if unit is not None:
            scale = units[unit]
        else:
            scales = [(scale, unit) for unit, scale in units.items()]
            scales.sort(reverse=True)
            for scale, unit in scales:
                if dt >= scale:
                    break
        return "%s %s" % (_g(dt / scale, precision), unit)

    if verbose:
        print("raw times: %s" % ", ".join([format_time(x) for x in raw_timings]))
        print()
    timings = [dt / number for dt in raw_timings]

    best = min(timings)
    print("%d loop%s, best of %d: %s per loop" % (number, "s" if number != 1 else "", repeat, format_time(best)))

    worst = max(timings)
    if worst >= best * 4:
        import warnings
        warnings.warn_explicit("The test results are likely unreliable. "
                               "The worst time (%s) was more than four times "
                               "slower than the best time (%s)." % (format_time(worst), format_time(best)),
                               UserWarning, "", 0)
    return None


def _g(x, precision):
    # "%.*g" % (precision, x)
    return ("%." + str(precision) + "g") % x


if __name__ == "__main__":
    sys.exit(main())
