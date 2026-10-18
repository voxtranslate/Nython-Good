# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/trace.ny - Python's trace: line counts, execution traces, called
# functions and calling relationships, over sys.settrace (round 79).
#
#     import trace
#     t = trace.Trace(count=1, trace=0)
#     t.runfunc(work, 3)
#     r = t.results()
#     r.counts                     # {(filename, lineno): times run}
#     r.write_results(show_missing=True, coverdir="/tmp/cov")
#
#     nython -m trace --count [-C DIR] [-m] [-s] script.ny [args ...]
#     nython -m trace --trace script.ny        # each line as it runs
#     nython -m trace --listfuncs script.ny    # the functions called
#     nython -m trace --trackcalls script.ny   # who called whom
#
# Trace(count=1, trace=1, countfuncs=0, countcallers=0, ignoremods=(),
#       ignoredirs=(), infile=None, outfile=None, timing=False)
#   run(cmd), runctx(cmd, globals=None, locals=None), runfunc(func, *args,
#   **kw), results(), the global / local trace functions (globaltrace_lt,
#   globaltrace_countfuncs, globaltrace_trackcallers, localtrace_count,
#   localtrace_trace, localtrace_trace_and_count) and
#   file_module_function_of(frame) - CPython's; --trace prints
#   "file(line):  source" per line (3.13's layout: 3.11 had one space) and
#   " --- modulename: m, funcname: f" per call, as CPython's
# CoverageResults(counts=None, calledfuncs=None, infile=None, callers=None,
#   outfile=None)   counts, calledfuncs, callers, update(other),
#   write_results(show_missing=True, summary=False, coverdir=None) - the
#   ".cover" files: each source line prefixed "%5d: " with its count, ">>>>>> "
#   for an executable line never run (show_missing; "#pragma NO COVER"
#   lines exempt), 7 spaces otherwise; "functions called:" and "calling
#   relationships:" reports; the "lines   cov%   module   (path)" summary;
#   write_results_file(path, lines, lnotab, lines_hit), is_ignored_filename
# main() - CPython's options: -c/--count, -t/--trace, -l/--listfuncs,
#   -T/--trackcalls, -r/--report, -R/--no-report, -f/--file, -C/--coverdir,
#   -m/--missing, -s/--summary, -g/--timing, --ignore-module, --ignore-dir,
#   --module
#
# Executable lines (show_missing) are the statements the real parser finds
# (text_defuse: the lines a statement starts on), not a code object's line
# table; a method's class in --listfuncs/--trackcalls comes from its
# __qualname__ (CPython searches gc referrers). The counts file (-f) is JSON,
# not pickle: a file CPython wrote cannot be read and the reverse.

import linecache
import os
import sys
import json
import threading
from time import monotonic as _time

__all__ = ["Trace", "CoverageResults"]

PRAGMA_NOCOVER = "#pragma NO COVER"


class _Ignore:
    def __init__(self, modules=None, dirs=None):
        self._mods = set() if not modules else set(modules)
        self._dirs = [] if not dirs else [os.path.normpath(d) for d in dirs]
        self._ignore = {"<string>": 1}

    def names(self, filename, modulename):
        if modulename in self._ignore:
            return self._ignore[modulename]
        # haven't seen this one before, so see if the module name is
        # on the ignore list.
        if modulename in self._mods:  # Identical names, so ignore
            self._ignore[modulename] = 1
            return 1
        # check if the module is a proper submodule of something on
        # the ignore list
        for mod in self._mods:
            # Need to take some care since ignoring
            # "cmp" mustn't mean ignoring "cmpcache" but ignoring
            # "Spam" must also mean ignoring "Spam.Eggs".
            if modulename.startswith(mod + "."):
                self._ignore[modulename] = 1
                return 1
        # Now check that filename isn't in one of the directories
        if filename is None:
            # must be a built-in, so we must ignore
            self._ignore[modulename] = 1
            return 1
        # Ignore a file when it contains one of the ignorable paths
        for d in self._dirs:
            # The '+ os.sep' is to ensure that d is a parent directory,
            # as compared to cases like:
            #  d = "/usr/local"
            #  filename = "/usr/local.py"
            # or
            #  d = "/usr/local.py"
            #  filename = "/usr/local.py"
            if filename.startswith(d + os.sep):
                self._ignore[modulename] = 1
                return 1
        # Tried the different ways, so we don't ignore this module
        self._ignore[modulename] = 0
        return 0


def _modname(path):
    """Return a plausible module name for the path."""
    base = os.path.basename(path)
    filename, ext = os.path.splitext(base)
    return filename


def _fullmodname(path):
    """Return a plausible module name for the path."""
    base = path
    cwd = os.getcwd()
    if path.startswith(cwd + os.sep):
        base = path[len(cwd) + 1:]
    base = base.replace(os.sep, ".")
    filename, ext = os.path.splitext(base)
    return filename.lstrip(".")


class CoverageResults:
    def __init__(self, counts=None, calledfuncs=None, infile=None, callers=None, outfile=None):
        self.counts = counts
        if self.counts is None:
            self.counts = {}
        self.counter = self.counts.copy()  # map (filename, lineno) to count
        self.calledfuncs = calledfuncs
        if self.calledfuncs is None:
            self.calledfuncs = {}
        self.calledfuncs = self.calledfuncs.copy()
        self.callers = callers
        if self.callers is None:
            self.callers = {}
        self.callers = self.callers.copy()
        self.infile = infile
        self.outfile = outfile
        if self.infile:
            # Try to merge existing counts file.
            try:
                counts, calledfuncs, callers = _load_counts(self.infile)
                self.update(self.__class__(counts, calledfuncs, callers=callers))
            except (OSError, EOFError, ValueError) as err:
                print("Skipping counts file %r: %s" % (self.infile, err), file=sys.stderr)

    def is_ignored_filename(self, filename):
        """Return True if the filename does not refer to a file
        we want to have reported.
        """
        return filename.startswith("<") and filename.endswith(">")

    def update(self, other):
        """Merge in the data from another CoverageResults"""
        counts = self.counts
        calledfuncs = self.calledfuncs
        callers = self.callers
        other_counts = other.counts
        other_calledfuncs = other.calledfuncs
        other_callers = other.callers
        for key in other_counts:
            counts[key] = counts.get(key, 0) + other_counts[key]
        for key in other_calledfuncs:
            calledfuncs[key] = 1
        for key in other_callers:
            callers[key] = 1

    def write_results(self, show_missing=True, summary=False, coverdir=None):
        """
        Write the coverage results.

        :param show_missing: Show lines that had no hits.
        :param summary: Include coverage summary per module.
        :param coverdir: If None, the results of each module are placed in its
                         directory, otherwise it is included in the directory
                         specified.
        """
        if self.calledfuncs:
            print()
            print("functions called:")
            calls = self.calledfuncs
            for filename, modulename, funcname in sorted(calls):
                print("filename: %s, modulename: %s, funcname: %s" % (filename, modulename, funcname))
        if self.callers:
            print()
            print("calling relationships:")
            lastfile = ""
            lastcfile = ""
            for ((pfile, pmod, pfunc), (cfile, cmod, cfunc)) in sorted(self.callers):
                if pfile != lastfile:
                    print()
                    print("***", pfile, "***")
                    lastfile = pfile
                    lastcfile = ""
                if cfile != pfile and lastcfile != cfile:
                    print("  -->", cfile)
                    lastcfile = cfile
                print("    %s.%s -> %s.%s" % (pmod, pfunc, cmod, cfunc))
        # turn the counts data ("(filename, lineno) = count") into something
        # accessible on a per-file basis
        per_file = {}
        for filename, lineno in self.counts:
            lines_hit = per_file.get(filename, {})
            per_file[filename] = lines_hit
            lines_hit[lineno] = self.counts[(filename, lineno)]
        # accumulate summary info, if needed
        sums = {}
        for filename, count in per_file.items():
            if self.is_ignored_filename(filename):
                continue
            if coverdir is None:
                dir = os.path.dirname(os.path.abspath(filename))
                modulename = _modname(filename)
            else:
                dir = coverdir
                os.makedirs(dir, exist_ok=True)
                modulename = _fullmodname(filename)
            # If desired, get a list of the line numbers which represent
            # executable content (returned as a dict for better lookup speed)
            if show_missing:
                lnotab = _find_executable_linenos(filename)
            else:
                lnotab = {}
            source = linecache.getlines(filename)
            coverpath = os.path.join(dir, modulename + ".cover")
            n_hits, n_lines = self.write_results_file(coverpath, source, lnotab, count)
            if summary and n_lines:
                percent = int(100 * n_hits / n_lines)
                sums[modulename] = n_lines, percent, modulename, filename
        if summary and sums:
            print("lines   cov%   module   (path)")
            for m in sorted(sums):
                n_lines, percent, modulename, filename = sums[m]
                print("%5d   %3d%%   %s   (%s)" % sums[m])
        if self.outfile:
            # try and store counts and module info into self.outfile
            try:
                _save_counts(self.outfile, self.counts, self.calledfuncs, self.callers)
            except OSError as err:
                print("Can't save counts files because %s" % err, file=sys.stderr)

    def write_results_file(self, path, lines, lnotab, lines_hit, encoding=None):
        """Return a coverage results file in path."""
        # ``lnotab`` is a dict of executable lines, or a line number "table"
        try:
            outfile = open(path, "w")
        except OSError as err:
            print("trace: Could not open %r for writing: %s - skipping" % (path, err), file=sys.stderr)
            return 0, 0
        n_lines = 0
        n_hits = 0
        out = []
        lineno = 0
        for line in lines:
            lineno += 1
            # do the blank/comment match to try to mark more lines
            # (help the reader find stuff that hasn't been covered)
            if lineno in lines_hit:
                out.append("%5d: " % lines_hit[lineno])
                n_hits += 1
                n_lines += 1
            elif lineno in lnotab and not PRAGMA_NOCOVER in line:
                # Highlight never-executed lines, unless the line contains
                # #pragma: NO COVER
                out.append(">>>>>> ")
                n_lines += 1
            else:
                out.append("       ")
            out.append(line.expandtabs(8))
        try:
            outfile.write("".join(out))
        finally:
            outfile.close()
        return n_hits, n_lines


def _save_counts(path, counts, calledfuncs, callers):
    data = {"counts": [[k[0], k[1], v] for k, v in counts.items()],
            "calledfuncs": [list(k) for k in calledfuncs],
            "callers": [[list(k[0]), list(k[1])] for k in callers]}
    f = open(path, "w")
    try:
        f.write(json.dumps(data))
    finally:
        f.close()


def _load_counts(path):
    f = open(path)
    try:
        text = f.read()
    finally:
        f.close()
    try:
        data = json.loads(text)
    except Exception:
        raise ValueError("not a counts file")
    counts = {}
    for e in data.get("counts", []):
        counts[(e[0], e[1])] = e[2]
    calledfuncs = {}
    for e in data.get("calledfuncs", []):
        calledfuncs[tuple(e)] = 1
    callers = {}
    for e in data.get("callers", []):
        callers[(tuple(e[0]), tuple(e[1]))] = 1
    return counts, calledfuncs, callers


def _find_executable_linenos(filename):
    """Return dict where keys are line numbers in the line number table."""
    try:
        f = open(filename)
        try:
            prog = f.read()
        finally:
            f.close()
    except OSError as err:
        print("Not printing coverage data for %r: %s" % (filename, err), file=sys.stderr)
        return {}
    # the lines a statement starts on, from the parser (docstrings left out)
    out = {}
    info = text_defuse(prog)
    for ln in range(len(info)):
        e = info[ln]
        if e is not None and e.get("stmt") and not e.get("doc"):
            out[ln + 1] = 1
    return out


def _print_line(filename, lineno):
    # (3.13's layout) "file(line):  source" - print(": ", line) puts the
    # separator's space before the line - or "file(line)" when there is no
    # source
    bname = os.path.basename(filename)
    line = linecache.getline(filename, lineno)
    print("%s(%d)" % (bname, lineno), end="")
    if line:
        print(": ", line, end="")
    else:
        print()


class Trace:
    def __init__(self, count=1, trace=1, countfuncs=0, countcallers=0, ignoremods=(), ignoredirs=(),
                 infile=None, outfile=None, timing=False):
        """
        @param count true iff it should count number of times each
                     line is executed
        @param trace true iff it should print out each line that is
                     being counted
        @param countfuncs true iff it should just output a list of
                     (filename, modulename, funcname,) for functions
                     that were called at least once;  This overrides
                     `count' and `trace'
        @param ignoremods a list of the names of modules to ignore
        @param ignoredirs a list of the names of directories to ignore
                     all of the (recursive) contents of
        @param infile file from which to read stored counts to be
                     added into the results
        @param outfile file in which to write the results
        @param timing true iff timing information be displayed
        """
        self.infile = infile
        self.outfile = outfile
        self.ignore = _Ignore(ignoremods, ignoredirs)
        self.counts = {}   # keys are (filename, linenumber)
        self.pathtobasename = {}  # for memoizing os.path.basename
        self.donothing = 0
        self.trace = trace
        self._calledfuncs = {}
        self._callers = {}
        self._caller_cache = {}
        self.start_time = None
        if timing:
            self.start_time = _time()
        if countcallers:
            self.globaltrace = self.globaltrace_trackcallers
        elif countfuncs:
            self.globaltrace = self.globaltrace_countfuncs
        elif trace and count:
            self.globaltrace = self.globaltrace_lt
            self.localtrace = self.localtrace_trace_and_count
        elif trace:
            self.globaltrace = self.globaltrace_lt
            self.localtrace = self.localtrace_trace
        elif count:
            self.globaltrace = self.globaltrace_lt
            self.localtrace = self.localtrace_count
        else:
            # Ahem -- do nothing?  Okay.
            self.donothing = 1

    def run(self, cmd):
        d = _ny_main_globals()
        self.runctx(cmd, d, d)

    def runctx(self, cmd, globals=None, locals=None):
        if globals is None:
            globals = {}
        if locals is None:
            locals = {}
        if not self.donothing:
            threading.settrace(self.globaltrace)
            sys.settrace(self.globaltrace)
        try:
            exec(cmd, globals, locals)
        finally:
            if not self.donothing:
                sys.settrace(None)
                threading.settrace(None)

    def runfunc(self, func, *args, **kw):
        result = None
        if not self.donothing:
            sys.settrace(self.globaltrace)
        try:
            result = func(*args, **kw)
        finally:
            if not self.donothing:
                sys.settrace(None)
        return result

    def file_module_function_of(self, frame):
        code = frame.f_code
        filename = code.co_filename
        if filename:
            modulename = _modname(filename)
        else:
            modulename = None
        funcname = code.co_name
        # a method: its class, from the qualified name
        qn = getattr(code, "co_qualname", funcname)
        if "<locals>" not in qn and qn.endswith("." + funcname):
            funcname = qn[qn[:-len(funcname) - 1].rfind(".") + 1:]
        return filename, modulename, funcname

    def globaltrace_trackcallers(self, frame, why, arg):
        """Handler for call events.

        Adds information about who called who to the self._callers dict.
        """
        if why == "call":
            # XXX Should do a better job of identifying methods
            this_func = self.file_module_function_of(frame)
            parent_func = self.file_module_function_of(frame.f_back)
            self._callers[(parent_func, this_func)] = 1

    def globaltrace_countfuncs(self, frame, why, arg):
        """Handler for call events.

        Adds (filename, modulename, funcname) to the self._calledfuncs dict.
        """
        if why == "call":
            this_func = self.file_module_function_of(frame)
            self._calledfuncs[this_func] = 1

    def globaltrace_lt(self, frame, why, arg):
        """Handler for call events.

        If the code block being entered is to be ignored, returns `None',
        else returns self.localtrace.
        """
        if why == "call":
            code = frame.f_code
            filename = frame.f_globals.get("__file__", None)
            if filename:
                # XXX _modname() doesn't work right for packages, so
                # the ignore support won't work right for packages
                modulename = _modname(filename)
                if modulename is not None:
                    ignore_it = self.ignore.names(filename, modulename)
                    if not ignore_it:
                        if self.trace:
                            print(" --- modulename: %s, funcname: %s" % (modulename, code.co_name))
                        return self.localtrace
            else:
                return None

    def localtrace_trace_and_count(self, frame, why, arg):
        if why == "line":
            # record the file name and line number of every trace
            filename = frame.f_code.co_filename
            lineno = frame.f_lineno
            key = filename, lineno
            self.counts[key] = self.counts.get(key, 0) + 1
            if self.start_time:
                print("%.2f" % (_time() - self.start_time), end=" ")
            _print_line(filename, lineno)
        return self.localtrace

    def localtrace_trace(self, frame, why, arg):
        if why == "line":
            # record the file name and line number of every trace
            filename = frame.f_code.co_filename
            lineno = frame.f_lineno
            if self.start_time:
                print("%.2f" % (_time() - self.start_time), end=" ")
            _print_line(filename, lineno)
        return self.localtrace

    def localtrace_count(self, frame, why, arg):
        if why == "line":
            filename = frame.f_code.co_filename
            lineno = frame.f_lineno
            key = filename, lineno
            self.counts[key] = self.counts.get(key, 0) + 1
        return self.localtrace

    def results(self):
        return CoverageResults(self.counts, infile=self.infile, outfile=self.outfile,
                               calledfuncs=self._calledfuncs, callers=self._callers)


def main():
    import argparse
    parser = argparse.ArgumentParser(prog="trace.py")
    parser.add_argument("--version", action="version", version="trace 2.0")
    grp = parser.add_argument_group("Main options", "One of these (or --report) must be given")
    grp.add_argument("-c", "--count", action="store_true",
                     help="Count the number of times each line is executed and write "
                          "the counts to <module>.cover for each module executed, in "
                          "the module's directory. See also --coverdir, --file, "
                          "--no-report below.")
    grp.add_argument("-t", "--trace", action="store_true",
                     help="Print each line to sys.stdout before it is executed")
    grp.add_argument("-l", "--listfuncs", action="store_true",
                     help="Keep track of which functions are executed at least once "
                          "and write the results to sys.stdout after the program exits. "
                          "Cannot be specified alongside --trace or --count.")
    grp.add_argument("-T", "--trackcalls", action="store_true",
                     help="Keep track of caller/called pairs and write the results to "
                          "sys.stdout after the program exits.")
    grp = parser.add_argument_group("Modifiers")
    _grp = grp.add_mutually_exclusive_group()
    _grp.add_argument("-r", "--report", action="store_true",
                     help="Generate a report from a counts file; does not execute any "
                          "code. --file must specify the results file to read, which "
                          "must have been created in a previous run with --count "
                          "--file=FILE")
    _grp.add_argument("-R", "--no-report", action="store_true",
                     help="Do not generate the coverage report files. "
                          "Useful if you want to accumulate over several runs.")
    grp.add_argument("-f", "--file", help="File to accumulate counts over several runs")
    grp.add_argument("-C", "--coverdir",
                     help="Directory where the report files go. The coverage report "
                          "for <package>.<module> will be written to file "
                          "<dir>/<package>/<module>.cover")
    grp.add_argument("-m", "--missing", action="store_true",
                     help="Annotate executable lines that were not executed with \">>>>>> \"")
    grp.add_argument("-s", "--summary", action="store_true",
                     help="Write a brief summary for each file to sys.stdout. "
                          "Can only be used with --count or --report")
    grp.add_argument("-g", "--timing", action="store_true",
                     help="Prefix each line with the time since the program started. "
                          "Only used while tracing")
    grp = parser.add_argument_group("Filters", "Can be specified multiple times")
    grp.add_argument("--ignore-module", action="append", default=[],
                     help="Ignore the given module(s) and its submodules "
                          "(if it is a package). Accepts comma separated list of "
                          "module names.")
    grp.add_argument("--ignore-dir", action="append", default=[],
                     help="Ignore files in the given directory "
                          "(multiple directories can be joined by os.pathsep).")
    parser.add_argument("--module", action="store_true", default=False, help="Trace a module. ")
    parser.add_argument("progname", nargs="?", help="file to run as main program")
    parser.add_argument("arguments", nargs=argparse.REMAINDER, help="arguments to the program")
    opts = parser.parse_args()
    ignore_module = []
    for i in opts.ignore_module:
        for mod in i.split(","):
            ignore_module.append(mod.strip())
    ignore_dir = []
    for i in opts.ignore_dir:
        for s in i.split(os.pathsep):
            ignore_dir.append(os.path.normpath(os.path.expanduser(s)))
    if opts.report:
        if not opts.file:
            parser.error("-r/--report requires -f/--file")
        results = CoverageResults(infile=opts.file, outfile=opts.file)
        return results.write_results(opts.missing, opts.summary, opts.coverdir)
    if not any([opts.trace, opts.count, opts.listfuncs, opts.trackcalls]):
        parser.error("must specify one of --trace, --count, --report, --listfuncs, or --trackcalls")
    if opts.listfuncs and (opts.count or opts.trace):
        parser.error("cannot specify both --listfuncs and (--trace or --count)")
    if opts.summary and not opts.count:
        parser.error("--summary can only be used with --count or --report")
    if opts.progname is None:
        parser.error("progname is missing: required with the main options")
    t = Trace(opts.count, opts.trace, countfuncs=opts.listfuncs, countcallers=opts.trackcalls,
              ignoremods=ignore_module, ignoredirs=ignore_dir, infile=opts.file,
              outfile=opts.file, timing=opts.timing)
    progname = opts.progname
    if opts.module:
        path = progname.replace(".", "/") + ".ny"
        if not os.path.exists(path) and os.path.exists(os.path.join("lib", path)):
            path = os.path.join("lib", path)
        progname = path
    try:
        sys.argv[:] = [progname] + list(opts.arguments)
        f = open(progname)
        try:
            src = f.read()
        finally:
            f.close()
        code = compile(src, progname, "exec")
        # try to emulate __main__ namespace as much as possible
        globs = {"__file__": progname, "__name__": "__main__", "__package__": None, "__cached__": None}
        t.runctx(code, globs, globs)
    except OSError as err:
        sys.exit("Cannot run file %r because: %s" % (sys.argv[0], err))
    except SystemExit:
        pass
    results = t.results()
    if not opts.no_report:
        results.write_results(opts.missing, opts.summary, opts.coverdir)


if __name__ == "__main__":
    main()
