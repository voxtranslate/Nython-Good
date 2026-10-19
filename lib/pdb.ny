# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/pdb.ny - Python's pdb: the interactive source debugger (round 79), CPython
# 3.11's pdb over lib/bdb.ny (sys.settrace, frame objects) and lib/cmd.ny.
#
#     import pdb
#     pdb.run("work(3)")                  # stops at the first line run
#     pdb.runcall(work, 3)
#     pdb.set_trace()                     # (or breakpoint()) stop here
#     pdb.post_mortem(tb); pdb.pm()       # walk a traceback
#     p = pdb.Pdb(stdin=io.StringIO("b 12\nc\np x\nc\n"), stdout=out)
#     p.runcall(work, 3)                  # a scripted session
#
#     nython -m pdb [-c command] ... script.ny [arg] ...
#
# Pdb(completekey="tab", stdin=None, stdout=None, skip=None, nosigint=False,
#     readrc=True)  - commands (CPython 3.11's names, abbreviations, messages
#   and output layout; 3.13's where they differ: `help cmd` prints
#   "Usage: ...", a breakpoint on a function is reported at its first
#   statement):
#   h(elp) [command], w(here)/bt, u(p) [count], d(own) [count],
#   b(reak) [([file:]lineno | function) [, condition]], tbreak,
#   cl(ear) [file:lineno | bpnumber ...], disable / enable bpnumber ...,
#   condition bpnumber [expr], ignore bpnumber [count], commands [bpnumber]
#   (... end, silent), s(tep), n(ext), unt(il) [lineno], r(eturn),
#   c(ont(inue)), j(ump) lineno (refused, see below), l(ist) [first[,
#   last] | .], ll / longlist, a(rgs), p expr, pp expr, whatis expr,
#   source expr, display [expr] / undisplay [expr], retval / rv, interact,
#   alias [name [command]] / unalias name (%1 ... and %* parameters),
#   run / restart, debug code, q(uit) / exit / EOF, `!statement` and any
#   other line as a Python statement in the current frame (an expression's
#   value is shown; assignments change the frame's variables through
#   f_locals - PEP 667), ";;" separating commands, .pdbrc files and -c
#   commands
# run(statement, globals=None, locals=None), runeval, runctx, runcall,
# set_trace(*, header=None), post_mortem(t=None), pm(), main(), Restart,
# line_prefix
# breakpoint() calls sys.breakpointhook(), which honours PYTHONBREAKPOINT
# ("0" disables, "mod.func" calls that, unset is pdb.set_trace).
#
# Not here: readline completion (complete_* exist but nothing calls them);
# SIGINT during `continue` does not break into the debugger; `jump`: a
# frame's f_lineno cannot be assigned on Nython, so every jump is "Jump
# failed: ..." (CPython's message for a target before the function).

import os
import io
import re
import sys
import cmd
import bdb
import pprint
import traceback
import linecache

__all__ = ["run", "pm", "Pdb", "runeval", "runctx", "runcall", "set_trace", "post_mortem", "help"]


class Restart(Exception):
    """Causes a debugger to be restarted for the debugged python program."""
    pass


def find_function(funcname, filename):
    # (3.13) the function's first statement, where a breakpoint on it stops
    cre = re.compile(r"def\s+%s(\s*\[.+\])?\s*[(]" % re.escape(funcname))
    lines = linecache.getlines(filename)
    if not lines:
        try:
            fp = open(filename)
        except OSError:
            return None
        try:
            lines = [ln + "\n" for ln in fp.read().split("\n")]
        finally:
            fp.close()
    for i in range(len(lines)):
        if cre.match(lines[i]):
            return funcname, filename, _first_statement_line(lines, i)
    return None


def find_first_executable_line(code):
    # (3.13) the line of a function's first statement, where a breakpoint
    # set on the function stops; CPython reads it from the bytecode after
    # RESUME, this from the source
    lines = linecache.getlines(code.co_filename)
    i = code.co_firstlineno - 1
    if i < 0 or i >= len(lines):
        return code.co_firstlineno
    return _first_statement_line(lines, i)


def _first_statement_line(lines, i):
    # lines[i] is a def (or a decorator before one): the 1-based line of the
    # first statement of its body - past a header spread over lines and a
    # docstring; the def's own line for a one-line body
    first_line = i + 1
    while i < len(lines) and lines[i].lstrip().startswith("@"):
        i += 1
    depth = 0
    while i < len(lines):
        text = lines[i].split("#")[0].rstrip()
        for ch in text:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
        i += 1
        if depth <= 0 and text.endswith(":"):
            break
        if depth <= 0 and ":" in text:
            return first_line   # def f(): return 1
    in_doc = None
    first = True
    while i < len(lines):
        s = lines[i].strip()
        i += 1
        if in_doc is not None:
            if in_doc in s:
                in_doc = None
            continue
        if not s or s.startswith("#"):
            continue
        if first:
            first = False
            body = s.lstrip("rRuU")
            if body[:3] in ('"""', "'''"):
                q = body[:3]
                if q not in body[3:]:
                    in_doc = q
                continue
            if body[:1] in ('"', "'") and len(body) > 1 and body.rstrip()[-1:] == body[:1]:
                continue
        return i
    return first_line


class _rstr:
    """String that doesn't quote its repr."""
    def __init__(self, s):
        self.s = s

    def __repr__(self):
        return self.s

    def __str__(self):
        return self.s

    def __eq__(self, other):
        return isinstance(other, _rstr) and other.s == self.s

    def __hash__(self):
        return hash(self.s)


# Interaction prompt line will separate file and call info from code
# text using value of line_prefix string.  A newline and arrow may
# be to your liking.  You can set it once pdb is imported using the
# command "pdb.line_prefix = '\n% '".
# line_prefix = ': '    # Use this to get the old situation back
line_prefix = "\n-> "   # Probably a better default


def _getsourcelines(frame_or_obj):
    # (lines, first line number) of a function's source - a frame's
    # function, or a module frame's whole file - as inspect.getsourcelines
    import inspect
    code = getattr(frame_or_obj, "f_code", None)
    if code is not None:
        filename = code.co_filename
        lines = linecache.getlines(filename)
        if not lines:
            raise OSError("could not get source code")
        if code.co_name == "<module>":
            return lines, 1
        start = max(1, code.co_firstlineno)
        return _block(lines, start), start
    return inspect.getsourcelines(frame_or_obj)


def _block(lines, start):
    # the def at line `start` and the lines indented under it
    first = lines[start - 1]
    indent = len(first) - len(first.lstrip())
    out = [first]
    i = start
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if s and len(ln) - len(ln.lstrip()) <= indent and not s.startswith("#"):
            break
        out.append(ln)
        i += 1
    while len(out) > 1 and not out[-1].strip():
        out.pop()
    return out


class Pdb(bdb.Bdb, cmd.Cmd):

    _previous_sigint_handler = None

    # List of all the commands making the program resume execution.
    commands_resuming = ["do_continue", "do_step", "do_next", "do_return", "do_quit", "do_jump"]

    def __init__(self, completekey="tab", stdin=None, stdout=None, skip=None, nosigint=False, readrc=True):
        bdb.Bdb.__init__(self, skip=skip)
        cmd.Cmd.__init__(self, completekey, stdin, stdout)
        _ny_sys_audit("pdb.Pdb")   # round 86: CPython's event
        if stdout:
            self.use_rawinput = 0
        self.prompt = "(Pdb) "
        self.aliases = {}
        self.displaying = {}
        self.mainpyfile = ""
        self._wait_for_mainpyfile = False
        self._user_requested_quit = False
        self.tb_lineno = {}
        self.allow_kbdint = False
        self.nosigint = nosigint
        self.lineno = None
        self.stack = []
        self.curindex = 0
        self.curframe = None
        self.curframe_locals = {}
        # Read ~/.pdbrc and ./.pdbrc
        self.rcLines = []
        if readrc:
            for rc in (os.path.expanduser("~/.pdbrc"), ".pdbrc"):
                try:
                    f = open(rc)
                    try:
                        self.rcLines.extend([l + "\n" for l in f.read().split("\n")])
                    finally:
                        f.close()
                except OSError:
                    pass
        self.commands = {}           # associates a command list to breakpoint numbers
        self.commands_doprompt = {}  # for each bp num, tells if the prompt
                                     # must be disp. after execing the cmd list
        self.commands_silent = {}    # for each bp num, tells if the stack trace
                                     # must be disp. after execing the cmd list
        self.commands_defining = False  # True while in the process of defining
                                        # a command list
        self.commands_bnum = None    # The breakpoint number for which we are
                                     # defining a list

    def sigint_handler(self, signum, frame):
        if self.allow_kbdint:
            raise KeyboardInterrupt
        self.message("\nProgram interrupted. (Use 'cont' to resume).")
        self.set_step()
        self.set_trace(frame)

    def reset(self):
        bdb.Bdb.reset(self)
        self.forget()

    def forget(self):
        self.lineno = None
        self.stack = []
        self.curindex = 0
        self.curframe = None
        self.tb_lineno.clear()

    def setup(self, f, tb):
        self.forget()
        self.stack, self.curindex = self.get_stack(f, tb)
        while tb:
            # when setting up post-mortem debugging with a traceback, save all
            # the original line numbers to be displayed along the current line
            # numbers (which can be different, e.g. due to finally clauses)
            self.tb_lineno[tb.tb_frame] = tb.tb_lineno
            tb = tb.tb_next
        self.curframe = self.stack[self.curindex][0]
        # The f_locals dictionary is updated from the actual frame
        # locals whenever the .f_locals accessor is called, so we
        # cache it here to ensure that modifications are not overwritten.
        self.curframe_locals = self.curframe.f_locals
        if self.rcLines:
            self.cmdqueue = [line for line in self.rcLines
                             if line.strip() and not line.strip().startswith("#")]
            self.rcLines = []

    # Override Bdb methods

    def user_call(self, frame, argument_list):
        """This method is called when there is the remote possibility
        that we ever need to stop in this function."""
        if self._wait_for_mainpyfile:
            return
        if self.stop_here(frame):
            self.message("--Call--")
            self.interaction(frame, None)

    def user_line(self, frame):
        """This function is called when we stop or break at this line."""
        if self._wait_for_mainpyfile:
            if (self.mainpyfile != self.canonic(frame.f_code.co_filename) or frame.f_lineno <= 0):
                return
            self._wait_for_mainpyfile = False
        if self.bp_commands(frame):
            self.interaction(frame, None)

    def bp_commands(self, frame):
        """Call every command that was set for the current active breakpoint
        (if there is one).

        Returns True if the normal interaction function must be called,
        False otherwise."""
        # self.currentbp is set in bdb in Bdb.break_here if a breakpoint was hit
        if getattr(self, "currentbp", False) and self.currentbp in self.commands:
            currentbp = self.currentbp
            self.currentbp = 0
            lastcmd_back = self.lastcmd
            self.setup(frame, None)
            for line in self.commands[currentbp]:
                self.onecmd(line)
            self.lastcmd = lastcmd_back
            if not self.commands_silent[currentbp]:
                self.print_stack_entry(self.stack[self.curindex])
            if self.commands_doprompt[currentbp]:
                self._cmdloop()
            self.forget()
            return
        return 1

    def user_return(self, frame, return_value):
        """This function is called when a return trap is set here."""
        if self._wait_for_mainpyfile:
            return
        frame.f_locals["__return__"] = return_value
        self.message("--Return--")
        self.interaction(frame, None)

    def user_exception(self, frame, exc_info):
        """This function is called if an exception occurs,
        but only if we are to stop at or just below this level."""
        if self._wait_for_mainpyfile:
            return
        exc_type, exc_value, exc_traceback = exc_info
        frame.f_locals["__exception__"] = exc_type, exc_value
        # An 'Internal StopIteration' exception is an exception debug event
        # issued by the interpreter when handling a subgenerator run with
        # 'yield from' or a generator controlled by a for loop. No exception has
        # actually occurred in this case. The debugger uses this debug event to
        # stop when the debuggee is returning from such generators.
        prefix = "Internal " if (not exc_traceback and exc_type is StopIteration) else ""
        self.message("%s%s" % (prefix, traceback.format_exception_only(exc_type, exc_value)[-1].strip()))
        self.interaction(frame, exc_traceback)

    # General interaction function
    def _cmdloop(self):
        while True:
            try:
                # keyboard interrupts allow for an easy way to cancel
                # the current command, so allow them during interactive input
                self.allow_kbdint = True
                self.cmdloop()
                self.allow_kbdint = False
                break
            except KeyboardInterrupt:
                self.message("--KeyboardInterrupt--")

    # Called before loop, handles display expressions
    def preloop(self):
        displaying = self.displaying.get(self.curframe)
        if displaying:
            for expr in list(displaying.keys()):
                oldvalue = displaying[expr]
                newvalue = self._getval_except(expr)
                # check for identity first; this prevents custom __eq__ to
                # be called at every loop, and also prevents instances whose
                # fields are changed to be displayed
                if newvalue is not oldvalue and newvalue != oldvalue:
                    displaying[expr] = newvalue
                    self.message("display %s: %s  [old: %s]" % (expr, self._safe_repr(newvalue, expr),
                                                                 self._safe_repr(oldvalue, expr)))

    def interaction(self, frame, traceback):
        self.setup(frame, traceback)
        # if we have more commands to process, do not show the stack entry
        if not self.cmdqueue:
            self.print_stack_entry(self.stack[self.curindex])
        self._cmdloop()
        self.forget()

    def displayhook(self, obj):
        """Custom displayhook for the exec in default(), which prevents
        assignment of the _ variable in the builtins.
        """
        # reproduce the behavior of the standard displayhook, not printing None
        if obj is not None:
            self.message(repr(obj))

    def default(self, line):
        if line[:1] == "!":
            line = line[1:]
        line = line.strip()
        frame_locals = self.curframe_locals
        globals = self.curframe.f_globals
        ns = dict(frame_locals)
        before = dict(ns)
        save_stdout = sys.stdout
        save_stdin = sys.stdin
        try:
            sys.stdin = self.stdin
            sys.stdout = self.stdout
            try:
                # an expression: its value is shown (compile's "single" mode)
                code = compile(line + "\n", "<stdin>", "eval")
            except SyntaxError:
                code = None
            if code is not None:
                self.displayhook(eval(code, globals, ns))
            else:
                exec(compile(line + "\n", "<stdin>", "exec"), globals, ns)
        except BaseException:
            sys.stdout = save_stdout
            sys.stdin = save_stdin
            self._error_exc()
            return
        sys.stdout = save_stdout
        sys.stdin = save_stdin
        # what the statement bound reaches the frame (PEP 667's write-through)
        for k in ns:
            if k not in before or ns[k] is not before[k]:
                frame_locals[k] = ns[k]

    def precmd(self, line):
        """Handle alias expansion and ';;' separator."""
        if not line.strip():
            return line
        args = line.split()
        while args[0] in self.aliases:
            line = self.aliases[args[0]]
            ii = 1
            for tmpArg in args[1:]:
                line = line.replace("%" + str(ii), tmpArg)
                ii += 1
            line = line.replace("%*", " ".join(args[1:]))
            args = line.split()
        # split into ';;' separated commands
        # unless it's an alias command
        if args[0] != "alias":
            marker = line.find(";;")
            if marker >= 0:
                # queue up everything after marker
                nxt = line[marker + 2:].lstrip()
                self.cmdqueue.insert(0, nxt)
                line = line[:marker].rstrip()
        return line

    def onecmd(self, line):
        """Interpret the argument as though it had been typed in response
        to the prompt.

        Checks whether this line is typed at the normal prompt or in
        a breakpoint command list definition.
        """
        if not self.commands_defining:
            return cmd.Cmd.onecmd(self, line)
        else:
            return self.handle_command_def(line)

    def handle_command_def(self, line):
        """Handles one command line during command list definition."""
        cmdname, arg, line = self.parseline(line)
        if not cmdname:
            return False
        if cmdname == "silent":
            self.commands_silent[self.commands_bnum] = True
            return False  # continue to handle other cmd def in the cmd list
        elif cmdname == "end":
            return True  # end of cmd list
        cmdlist = self.commands[self.commands_bnum]
        if arg:
            cmdlist.append(cmdname + " " + arg)
        else:
            cmdlist.append(cmdname)
        # Determine if we must stop
        func = getattr(self, "do_" + cmdname, None)
        fname = getattr(func, "__name__", "default") if func is not None else "default"
        # one of the resuming commands
        if fname in self.commands_resuming:
            self.commands_doprompt[self.commands_bnum] = False
            return True
        return False

    # interface abstraction functions

    def message(self, msg):
        print(msg, file=self.stdout)

    def error(self, msg):
        print("***", msg, file=self.stdout)

    # Generic completion functions.

    def _complete_bpnumber(self, text, line, begidx, endidx):
        return [str(i) for i, bp in enumerate(bdb.Breakpoint.bpbynumber) if bp is not None and str(i).startswith(text)]

    def _complete_expression(self, text, line, begidx, endidx):
        # Complete an arbitrary expression.
        if not self.curframe:
            return []
        ns = dict(self.curframe.f_globals)
        ns.update(dict(self.curframe_locals))
        if "." in text:
            dotted = text.split(".")
            try:
                obj = ns[dotted[0]]
                for part in dotted[1:-1]:
                    obj = getattr(obj, part)
            except (KeyError, AttributeError):
                return []
            prefix = ".".join(dotted[:-1]) + "."
            return [prefix + n for n in dir(obj) if n.startswith(dotted[-1])]
        else:
            return [n for n in ns.keys() if n.startswith(text)]

    complete_print = _complete_expression
    complete_p = _complete_expression
    complete_pp = _complete_expression

    # Command definitions, called by cmdloop()
    # The argument is the remaining string on the command line
    # Return true to exit from the command loop

    def do_commands(self, arg):
        """commands [bpnumber]
        (com) ...
        (com) end
        (Pdb)

        Specify a list of commands for breakpoint number bpnumber.
        The commands themselves are entered on the following lines.
        Type a line containing just 'end' to terminate the commands.
        The commands are executed when the breakpoint is hit.

        To remove all commands from a breakpoint, type commands and
        follow it immediately with end; that is, give no commands.

        With no bpnumber argument, commands refers to the last
        breakpoint set.

        You can use breakpoint commands to start your program up
        again.  Simply use the continue command, or step, or any other
        command that resumes execution.

        Specifying any command resuming execution (currently continue,
        step, next, return, jump, quit and their abbreviations)
        terminates the command list (as if that command was
        immediately followed by end).  This is because any time you
        resume execution (even with a simple next or step), you may
        encounter another breakpoint -- which could have its own
        command list, leading to ambiguities about which list to
        execute.

        If you use the 'silent' command in the command list, the usual
        message about stopping at a breakpoint is not printed.  This
        may be desirable for breakpoints that are to print a specific
        message and then continue.  If none of the other commands
        print anything, you will see no sign that the breakpoint was
        reached.
        """
        if not arg:
            bnum = len(bdb.Breakpoint.bpbynumber) - 1
        else:
            try:
                bnum = int(arg)
            except BaseException:
                self.error("Usage: commands [bnum]\n        ...\n        end")
                return
        try:
            self.get_bpbynumber(bnum)
        except ValueError as err:
            self.error("cannot set commands: %s" % err)
            return
        self.commands_bnum = bnum
        # Save old definitions for the case of a keyboard interrupt.
        if bnum in self.commands:
            old_command_defs = (self.commands[bnum], self.commands_doprompt[bnum], self.commands_silent[bnum])
        else:
            old_command_defs = None
        self.commands[bnum] = []
        self.commands_doprompt[bnum] = True
        self.commands_silent[bnum] = False
        prompt_back = self.prompt
        self.prompt = "(com) "
        self.commands_defining = True
        try:
            self.cmdloop()
        except KeyboardInterrupt:
            # Restore old definitions.
            if old_command_defs:
                self.commands[bnum] = old_command_defs[0]
                self.commands_doprompt[bnum] = old_command_defs[1]
                self.commands_silent[bnum] = old_command_defs[2]
            else:
                del self.commands[bnum]
                del self.commands_doprompt[bnum]
                del self.commands_silent[bnum]
            self.error("command definition aborted, old commands restored")
        finally:
            self.commands_defining = False
            self.prompt = prompt_back

    complete_commands = _complete_bpnumber

    def do_break(self, arg, temporary=0):
        """b(reak) [ ([filename:]lineno | function) [, condition] ]
        Without argument, list all breaks.

        With a line number argument, set a break at this line in the
        current file.  With a function name, set a break at the first
        executable line of that function.  If a second argument is
        present, it is a string specifying an expression which must
        evaluate to true before the breakpoint is honored.

        The line number may be prefixed with a filename and a colon,
        to specify a breakpoint in another file (probably one that
        hasn't been loaded yet).  The file is searched for on
        sys.path; the .py suffix may be omitted.
        """
        if not arg:
            if self.breaks:  # There's at least one
                self.message("Num Type         Disp Enb   Where")
                for bp in bdb.Breakpoint.bpbynumber:
                    if bp:
                        self.message(bp.bpformat())
            return
        # parse arguments; comma has lowest precedence
        # and cannot occur in filename
        filename = None
        lineno = None
        cond = None
        comma = arg.find(",")
        if comma > 0:
            # parse stuff after comma: "condition"
            cond = arg[comma + 1:].lstrip()
            arg = arg[:comma].rstrip()
        # parse stuff before comma: [filename:]lineno | function
        colon = arg.rfind(":")
        funcname = None
        if colon >= 0:
            filename = arg[:colon].rstrip()
            f = self.lookupmodule(filename)
            if not f:
                self.error("%r not found from sys.path" % filename)
                return
            else:
                filename = f
            arg = arg[colon + 1:].lstrip()
            try:
                lineno = int(arg)
            except ValueError:
                self.error("Bad lineno: %s" % arg)
                return
        else:
            # no colon; can be lineno or function
            try:
                lineno = int(arg)
            except ValueError:
                try:
                    func = eval(arg, self.curframe.f_globals, dict(self.curframe_locals))
                except BaseException:
                    func = arg
                try:
                    if hasattr(func, "__func__"):
                        func = func.__func__
                    code = func.__code__
                    # use co_name to identify the bkpt (function names
                    # could be aliased, but co_name is invariant)
                    funcname = code.co_name
                    lineno = find_first_executable_line(code)   # (3.13)
                    filename = code.co_filename
                except BaseException:
                    # last thing to try
                    (ok, filename, ln) = self.lineinfo(arg)
                    if not ok:
                        self.error("The specified object %r is not a function or was not found along sys.path." % arg)
                        return
                    funcname = ok  # ok contains a function name
                    lineno = int(ln)
        if not filename:
            filename = self.defaultFile()
        # Check for reasonable breakpoint
        line = self.checkline(filename, lineno)
        if line:
            # now set the break point
            err = self.set_break(filename, line, temporary, cond, funcname)
            if err:
                self.error(err)
            else:
                bp = self.get_breaks(filename, line)[-1]
                self.message("Breakpoint %d at %s:%d" % (bp.number, bp.file, bp.line))

    # To be overridden in derived debuggers
    def defaultFile(self):
        """Produce a reasonable default."""
        filename = self.curframe.f_code.co_filename
        if filename == "<string>" and self.mainpyfile:
            filename = self.mainpyfile
        return filename

    do_b = do_break

    def do_tbreak(self, arg):
        """tbreak [ ([filename:]lineno | function) [, condition] ]
        Same arguments as break, but sets a temporary breakpoint: it
        is automatically deleted when first hit.
        """
        self.do_break(arg, 1)

    def lineinfo(self, identifier):
        failed = (None, None, None)
        # Input is identifier, may be in single quotes
        idstring = identifier.split("'")
        if len(idstring) == 1:
            # not in single quotes
            id = idstring[0].strip()
        elif len(idstring) == 3:
            # quoted
            id = idstring[1].strip()
        else:
            return failed
        if id == "":
            return failed
        parts = id.split(".")
        # Protection for derived debuggers
        if parts[0] == "self":
            del parts[0]
            if len(parts) == 0:
                return failed
        # Best first guess at file to look at
        fname = self.defaultFile()
        if len(parts) == 1:
            item = parts[0]
        else:
            # More than one part.
            # First is module, second is method/class
            f = self.lookupmodule(parts[0])
            if f:
                fname = f
            item = parts[1]
        answer = find_function(item, fname)
        return answer or failed

    def checkline(self, filename, lineno):
        """Check whether specified line seems to be executable.

        Return `lineno` if it is, 0 if not (e.g. a docstring, comment, blank
        line or EOF). Warning: testing is not comprehensive.
        """
        # this method should be callable before starting debugging, so default
        # to "no globals" if there is no current frame
        frame = getattr(self, "curframe", None)
        globs = frame.f_globals if frame else None
        line = linecache.getline(filename, lineno, globs)
        if not line:
            self.message("End of file")
            return 0
        line = line.strip()
        # Don't allow setting breakpoint at a blank line
        if (not line or (line[0] == "#") or (line[:3] == "\"\"\"") or line[:3] == "'''"):
            self.error("Blank or comment")
            return 0
        return lineno

    def do_enable(self, arg):
        """enable bpnumber [bpnumber ...]
        Enables the breakpoints given as a space separated list of
        breakpoint numbers.
        """
        args = arg.split()
        for i in args:
            try:
                bp = self.get_bpbynumber(i)
            except ValueError as err:
                self.error(err)
            else:
                bp.enable()
                self.message("Enabled %s" % bp)

    def do_disable(self, arg):
        """disable bpnumber [bpnumber ...]
        Disables the breakpoints given as a space separated list of
        breakpoint numbers.  Disabling a breakpoint means it cannot
        cause the program to stop execution, but unlike clearing a
        breakpoint, it remains in the list of breakpoints and can be
        (re-)enabled.
        """
        args = arg.split()
        for i in args:
            try:
                bp = self.get_bpbynumber(i)
            except ValueError as err:
                self.error(err)
            else:
                bp.disable()
                self.message("Disabled %s" % bp)

    def do_condition(self, arg):
        """condition bpnumber [condition]
        Set a new condition for the breakpoint, an expression which
        must evaluate to true before the breakpoint is honored.  If
        condition is absent, any existing condition is removed; i.e.,
        the breakpoint is made unconditional.
        """
        args = arg.split(" ", 1)
        cond = args[1] if len(args) > 1 else None
        try:
            bp = self.get_bpbynumber(args[0].strip())
        except IndexError:
            self.error("Breakpoint number expected")
        except ValueError as err:
            self.error(err)
        else:
            bp.cond = cond
            if not cond:
                self.message("Breakpoint %d is now unconditional." % bp.number)
            else:
                self.message("New condition set for breakpoint %d." % bp.number)

    def do_ignore(self, arg):
        """ignore bpnumber [count]
        Set the ignore count for the given breakpoint number.  If
        count is omitted, the ignore count is set to 0.  A breakpoint
        becomes active when the ignore count is zero.  When non-zero,
        the count is decremented each time the breakpoint is reached
        and the breakpoint is not disabled and any associated
        condition evaluates to true.
        """
        args = arg.split()
        try:
            count = int(args[1].strip())
        except BaseException:
            count = 0
        try:
            if not args:
                raise IndexError("no number")
            bp = self.get_bpbynumber(args[0].strip())
        except IndexError:
            self.error("Breakpoint number expected")
        except ValueError as err:
            self.error(err)
        else:
            bp.ignore = count
            if count > 0:
                if count > 1:
                    countstr = "%d crossings" % count
                else:
                    countstr = "1 crossing"
                self.message("Will ignore next %s of breakpoint %d." % (countstr, bp.number))
            else:
                self.message("Will stop next time breakpoint %d is reached." % bp.number)

    def do_clear(self, arg):
        """cl(ear) filename:lineno
cl(ear) [bpnumber [bpnumber...]]
        With a space separated list of breakpoint numbers, clear
        those breakpoints.  Without argument, clear all breaks (but
        first ask confirmation).  With a filename:lineno argument,
        clear all breaks at that line in that file.
        """
        if not arg:
            try:
                if self.use_rawinput:
                    reply = input("Clear all breaks? ")
                else:
                    self.stdout.write("Clear all breaks? ")
                    reply = self.stdin.readline()
                    if not reply:
                        raise EOFError()
            except EOFError:
                reply = "no"
            reply = reply.strip().lower()
            if reply in ("y", "yes"):
                bplist = [bp for bp in bdb.Breakpoint.bpbynumber if bp]
                self.clear_all_breaks()
                for bp in bplist:
                    self.message("Deleted %s" % bp)
            return
        if ":" in arg:
            # Make sure it works for "clear C:\foo\bar.py:12"
            i = arg.rfind(":")
            filename = arg[:i]
            arg = arg[i + 1:]
            bplist = []
            try:
                lineno = int(arg)
            except ValueError:
                err = "Invalid line number (%s)" % arg
            else:
                bplist = self.get_breaks(filename, lineno)[:]
                err = self.clear_break(filename, lineno)
            if err:
                self.error(err)
            else:
                for bp in bplist:
                    self.message("Deleted %s" % bp)
            return
        numberlist = arg.split()
        for i in numberlist:
            try:
                bp = self.get_bpbynumber(i)
            except ValueError as err:
                self.error(err)
            else:
                self.clear_bpbynumber(i)
                self.message("Deleted %s" % bp)

    do_cl = do_clear  # 'c' is already an abbreviation for 'continue'

    def do_where(self, arg):
        """w(here)
        Print a stack trace, with the most recent frame at the bottom.
        An arrow indicates the "current frame", which determines the
        context of most commands.  'bt' is an alias for this command.
        """
        self.print_stack_trace()

    do_w = do_where
    do_bt = do_where

    def _select_frame(self, number):
        self.curindex = number
        self.curframe = self.stack[self.curindex][0]
        self.curframe_locals = self.curframe.f_locals
        self.print_stack_entry(self.stack[self.curindex])
        self.lineno = None

    def do_up(self, arg):
        """u(p) [count]
        Move the current frame count (default one) levels up in the
        stack trace (to an older frame).
        """
        if self.curindex == 0:
            self.error("Oldest frame")
            return
        try:
            count = int(arg or 1)
        except ValueError:
            self.error("Invalid frame count (%s)" % arg)
            return
        if count < 0:
            newframe = 0
        else:
            newframe = max(0, self.curindex - count)
        self._select_frame(newframe)

    do_u = do_up

    def do_down(self, arg):
        """d(own) [count]
        Move the current frame count (default one) levels down in the
        stack trace (to a newer frame).
        """
        if self.curindex + 1 == len(self.stack):
            self.error("Newest frame")
            return
        try:
            count = int(arg or 1)
        except ValueError:
            self.error("Invalid frame count (%s)" % arg)
            return
        if count < 0:
            newframe = len(self.stack) - 1
        else:
            newframe = min(len(self.stack) - 1, self.curindex + count)
        self._select_frame(newframe)

    do_d = do_down

    def do_until(self, arg):
        """unt(il) [lineno]
        Without argument, continue execution until the line with a
        number greater than the current one is reached.  With a line
        number, continue execution until a line with a number greater
        or equal to that is reached.  In both cases, also stop when
        the current frame returns.
        """
        if arg:
            try:
                lineno = int(arg)
            except ValueError:
                self.error("Error in argument: %r" % arg)
                return
            if lineno <= self.curframe.f_lineno:
                self.error("\"until\" line number is smaller than current line number")
                return
        else:
            lineno = None
        self.set_until(self.curframe, lineno)
        return 1

    do_unt = do_until

    def do_step(self, arg):
        """s(tep)
        Execute the current line, stop at the first possible occasion
        (either in a function that is called or in the current
        function).
        """
        self.set_step()
        return 1

    do_s = do_step

    def do_next(self, arg):
        """n(ext)
        Continue execution until the next line in the current function
        is reached or it returns.
        """
        self.set_next(self.curframe)
        return 1

    do_n = do_next

    def do_run(self, arg):
        """run [args...]
        Restart the debugged python program. If a string is supplied
        it is split with "shlex", and the result is used as the new
        sys.argv.  History, breakpoints, actions and debugger options
        are preserved.  "restart" is an alias for "run".
        """
        if arg:
            argv0 = sys.argv[0:1]
            sys.argv = argv0 + arg.split()
        # this is caught in the main debugger loop
        raise Restart

    do_restart = do_run

    def do_return(self, arg):
        """r(eturn)
        Continue execution until the current function returns.
        """
        self.set_return(self.curframe)
        return 1

    do_r = do_return

    def do_continue(self, arg):
        """c(ont(inue))
        Continue execution, only stop when a breakpoint is encountered.
        """
        self.set_continue()
        return 1

    do_c = do_continue
    do_cont = do_continue

    def do_jump(self, arg):
        """j(ump) lineno
        Set the next line that will be executed.  Only available in
        the bottom-most frame.  This lets you jump back and execute
        code again, or jump forward to skip code that you don't want
        to run.

        It should be noted that not all jumps are allowed -- for
        instance it is not possible to jump into the middle of a
        for loop or out of a finally clause.
        """
        if self.curindex + 1 != len(self.stack):
            self.error("You can only jump within the bottom frame")
            return
        try:
            arg = int(arg)
        except ValueError:
            self.error("The 'jump' command requires a line number")
        else:
            try:
                # Do the jump, fix up our copy of the stack, and display the
                # new position
                self.curframe.f_lineno = arg
                self.stack[self.curindex] = self.stack[self.curindex][0], arg
                self.print_stack_entry(self.stack[self.curindex])
            except ValueError as e:
                self.error("Jump failed: %s" % e)

    do_j = do_jump

    def do_debug(self, arg):
        """debug code
        Enter a recursive debugger that steps through the code
        argument (which is an arbitrary expression or statement to be
        executed in the current environment).
        """
        sys.settrace(None)
        globals = self.curframe.f_globals
        locals = dict(self.curframe_locals)
        p = Pdb(self.completekey, self.stdin, self.stdout)
        p.prompt = "(%s) " % self.prompt.strip()
        self.message("ENTERING RECURSIVE DEBUGGER")
        try:
            p.run(arg, globals, locals)
        except Exception:
            self._error_exc()
        self.message("LEAVING RECURSIVE DEBUGGER")
        sys.settrace(self.trace_dispatch)
        self.lastcmd = p.lastcmd

    def do_quit(self, arg):
        """q(uit)
exit
        Quit from the debugger. The program being executed is aborted.
        """
        self._user_requested_quit = True
        self.set_quit()
        return 1

    do_q = do_quit
    do_exit = do_quit

    def do_EOF(self, arg):
        """EOF
        Handles the receipt of EOF as a command.
        """
        self.message("")
        self._user_requested_quit = True
        self.set_quit()
        return 1

    def do_args(self, arg):
        """a(rgs)
        Print the argument list of the current function.
        """
        co = self.curframe.f_code
        d = self.curframe_locals
        n = co.co_argcount + co.co_kwonlyargcount
        if co.co_flags & 4:
            n = n + 1
        if co.co_flags & 8:
            n = n + 1
        for i in range(n):
            if i >= len(co.co_varnames):
                break
            name = co.co_varnames[i]
            if name in d:
                self.message("%s = %s" % (name, self._safe_repr(d[name], name)))
            else:
                self.message("%s = *** undefined ***" % (name,))

    do_a = do_args

    def do_retval(self, arg):
        """retval
        Print the return value for the last return of a function.
        """
        if "__return__" in self.curframe_locals:
            self.message(self._safe_repr(self.curframe_locals["__return__"], "retval"))
        else:
            self.error("Not yet returned!")

    do_rv = do_retval

    def _getval(self, arg):
        try:
            return eval(arg, self.curframe.f_globals, dict(self.curframe_locals))
        except BaseException:
            self._error_exc()
            raise

    def _getval_except(self, arg, frame=None):
        try:
            if frame is None:
                return eval(arg, self.curframe.f_globals, dict(self.curframe_locals))
            else:
                return eval(arg, frame.f_globals, dict(frame.f_locals))
        except BaseException:
            exc_info = sys.exc_info()[:2]
            err = traceback.format_exception_only(exc_info[0], exc_info[1])[-1].strip()
            return _rstr("** raised %s **" % err)

    def _error_exc(self):
        exc_info = sys.exc_info()[:2]
        self.error(traceback.format_exception_only(exc_info[0], exc_info[1])[-1].strip())

    def _msg_val_func(self, arg, func):
        try:
            val = self._getval(arg)
        except BaseException:
            return  # _getval() has displayed the error
        try:
            self.message(func(val))
        except BaseException:
            self._error_exc()

    def _safe_repr(self, obj, expr):
        try:
            return repr(obj)
        except Exception as e:
            return _rstr("*** repr(%s) failed: %s ***" % (expr, self._format_exc(e)))

    def do_p(self, arg):
        """p expression
        Print the value of the expression.
        """
        self._msg_val_func(arg, repr)

    def do_pp(self, arg):
        """pp expression
        Pretty-print the value of the expression.
        """
        self._msg_val_func(arg, pprint.pformat)

    def do_list(self, arg):
        """l(ist) [first [,last] | .]

        List source code for the current file.  Without arguments,
        list 11 lines around the current line or continue the previous
        listing.  With . as argument, list 11 lines around the current
        line.  With one argument, list 11 lines starting at that line.
        With two arguments, list the given range; if the second
        argument is less than the first, it is a count.

        The current line in the current frame is indicated by "->".
        If an exception is being debugged, the line where the
        exception was originally raised or propagated is indicated by
        ">>", if it differs from the current line.
        """
        self.lastcmd = "list"
        last = None
        if arg and arg != ".":
            try:
                if "," in arg:
                    first, last = arg.split(",")
                    first = int(first.strip())
                    last = int(last.strip())
                    if last < first:
                        # assume it's a count
                        last = first + last
                else:
                    first = int(arg.strip())
                    first = max(1, first - 5)
            except ValueError:
                self.error("Error in argument: %r" % arg)
                return
        elif self.lineno is None or arg == ".":
            first = max(1, self.curframe.f_lineno - 5)
        else:
            first = self.lineno + 1
        if last is None:
            last = first + 10
        filename = self.curframe.f_code.co_filename
        breaklist = self.get_file_breaks(filename)
        lines = linecache.getlines(filename, self.curframe.f_globals)
        self._print_lines(lines[first - 1:last], first, breaklist, self.curframe)
        self.lineno = min(last, len(lines))
        if len(lines) < last:
            self.message("[EOF]")

    do_l = do_list

    def do_longlist(self, arg):
        """longlist | ll
        List the whole source code for the current function or frame.
        """
        filename = self.curframe.f_code.co_filename
        breaklist = self.get_file_breaks(filename)
        try:
            lines, lineno = self._getsourcelines(self.curframe)
        except OSError as err:
            self.error(err)
            return
        self._print_lines(lines, lineno, breaklist, self.curframe)

    do_ll = do_longlist

    def do_source(self, arg):
        """source expression
        Try to get source code for the given object and display it.
        """
        try:
            obj = self._getval(arg)
        except BaseException:
            return
        try:
            lines, lineno = self._getsourcelines(obj)
        except (OSError, TypeError) as err:
            self.error(err)
            return
        self._print_lines(lines, lineno)

    def _print_lines(self, lines, start, breaks=(), frame=None):
        """Print a range of lines."""
        if frame:
            current_lineno = frame.f_lineno
            exc_lineno = self.tb_lineno.get(frame, -1)
        else:
            current_lineno = -1
            exc_lineno = -1
        lineno = start
        for line in lines:
            s = str(lineno).rjust(3)
            if len(s) < 4:
                s += " "
            if lineno in breaks:
                s += "B"
            else:
                s += " "
            if lineno == current_lineno:
                s += "->"
            elif lineno == exc_lineno:
                s += ">>"
            self.message(s + "\t" + line.rstrip())
            lineno += 1

    def do_whatis(self, arg):
        """whatis arg
        Print the type of the argument.
        """
        try:
            value = self._getval(arg)
        except BaseException:
            # _getval() already printed the error
            return
        code = None
        # Is it an instance method?
        try:
            code = value.__func__.__code__
        except Exception:
            pass
        if code:
            self.message("Method %s" % code.co_name)
            return
        # Is it a function?
        try:
            code = value.__code__
        except Exception:
            pass
        if code:
            self.message("Function %s" % code.co_name)
            return
        # Is it a class?
        if value.__class__ is type:
            self.message("Class %s.%s" % (value.__module__, value.__qualname__))
            return
        # None of the above...
        self.message(type(value))

    def do_display(self, arg):
        """display [expression]

        Display the value of the expression if it changed, each time execution
        stops in the current frame.

        Without expression, list all display expressions for the current frame.
        """
        if not arg:
            self.message("Currently displaying:")
            for key, val in self.displaying.get(self.curframe, {}).items():
                self.message("%s: %s" % (key, self._safe_repr(val, key)))
        else:
            val = self._getval_except(arg)
            self.displaying.setdefault(self.curframe, {})[arg] = val
            self.message("display %s: %s" % (arg, self._safe_repr(val, arg)))

    def do_undisplay(self, arg):
        """undisplay [expression]

        Do not display the expression any more in the current frame.

        Without expression, clear all display expressions for the current frame.
        """
        if arg:
            try:
                del self.displaying.get(self.curframe, {})[arg]
            except KeyError:
                self.error("not displaying %s" % arg)
        else:
            self.displaying.pop(self.curframe, None)

    def complete_undisplay(self, text, line, begidx, endidx):
        return [e for e in self.displaying.get(self.curframe, {}) if e.startswith(text)]

    def do_interact(self, arg):
        """interact

        Start an interactive interpreter whose global namespace
        contains all the (global and local) names found in the current scope.
        """
        import code
        ns = dict(self.curframe.f_globals)
        ns.update(dict(self.curframe_locals))
        if self.use_rawinput:
            code.interact("*interactive*", local=ns)
            return

        def readfunc(prompt=""):
            self.stdout.write(prompt)
            line = self.stdin.readline()
            if not line:
                raise EOFError()
            return line.rstrip("\r\n")

        console = code.InteractiveConsole(ns)
        console.raw_input = readfunc
        console.write = self.stdout.write
        console.interact("*interactive*")

    def do_alias(self, arg):
        """alias [name [command [parameter parameter ...] ]]
        Create an alias called 'name' that executes 'command'.  The
        command must *not* be enclosed in quotes.  Replaceable
        parameters can be indicated by %1, %2, and so on, while %* is
        replaced by all the parameters.  If no command is given, the
        current alias for name is shown. If no name is given, all
        aliases are listed.

        Aliases may be nested and can contain anything that can be
        legally typed at the pdb prompt.  Note!  You *can* override
        internal pdb commands with aliases!  Those internal commands
        are then hidden until the alias is removed.  Aliasing is
        recursively applied to the first word of the command line; all
        other words in the line are left alone.

        As an example, here are two useful aliases (especially when
        placed in the .pdbrc file):

        # Print instance variables (usage "pi classInst")
        alias pi for k in %1.__dict__.keys(): print("%1.",k,"=",%1.__dict__[k])
        # Print instance variables in self
        alias ps pi self
        """
        args = arg.split()
        if len(args) == 0:
            keys = sorted(self.aliases.keys())
            for alias in keys:
                self.message("%s = %s" % (alias, self.aliases[alias]))
            return
        if len(args) == 1:
            if args[0] in self.aliases:
                self.message("%s = %s" % (args[0], self.aliases[args[0]]))
            else:
                self.error("Unknown alias '%s'" % args[0])
        else:
            self.aliases[args[0]] = " ".join(args[1:])

    def do_unalias(self, arg):
        """unalias name
        Delete the specified alias.
        """
        args = arg.split()
        if len(args) == 0:
            return
        if args[0] in self.aliases:
            del self.aliases[args[0]]

    def complete_unalias(self, text, line, begidx, endidx):
        return [a for a in self.aliases if a.startswith(text)]

    # Print a traceback starting at the top stack frame.
    # The most recently entered frame is printed last;
    # this is different from dbx and gdb, but consistent with
    # the Python interpreter's stack trace.
    # It is also consistent with the up/down commands (which are
    # compatible with dbx and gdb: up moves towards 'main()'
    # and down moves towards the most recent stack frame).

    def print_stack_trace(self):
        for frame_lineno in self.stack:
            self.print_stack_entry(frame_lineno)

    def print_stack_entry(self, frame_lineno, prompt_prefix=None):
        if prompt_prefix is None:
            prompt_prefix = line_prefix
        frame, lineno = frame_lineno
        if frame is self.curframe:
            prefix = "> "
        else:
            prefix = "  "
        self.message(prefix + self.format_stack_entry(frame_lineno, prompt_prefix))

    # Provide help

    def do_help(self, arg):
        """h(elp)
        Without argument, print the list of available commands.
        With a command name as argument, print help about that command.
        "help pdb" shows the full pdb documentation.
        "help exec" gives help on the ! command.
        """
        if not arg:
            return cmd.Cmd.do_help(self, arg)
        topic = getattr(self, "help_" + arg, None)
        if topic is not None:
            return topic()
        command = getattr(self, "do_" + arg, None)
        if command is None:
            self.error("No help for %r" % arg)
            return
        doc = getattr(command, "__doc__", None)
        if doc is None:
            self.error("No help for %r; __doc__ string missing" % arg)
            return
        self.message(self._help_message_from_doc(doc))

    def _help_message_from_doc(self, doc, usage_only=False):
        # (3.13) "Usage: " before the usage line, every line indented by the
        # prompt's width; the docstrings here keep 3.11's layout (no blank
        # line after the usage line), so one is put after the first line
        lines = [line.strip() for line in doc.rstrip().splitlines()]
        if not lines:
            return "No help message found."
        if "" in lines:
            usage_end = lines.index("")
        else:
            usage_end = 1
            lines.insert(1, "")
        if usage_only:
            lines = lines[:usage_end]
        formatted = []
        indent = " " * len(self.prompt)
        for i, line in enumerate(lines):
            if i == 0:
                prefix = "Usage: "
            elif i < usage_end:
                prefix = "       "
            else:
                prefix = ""
            formatted.append(indent + prefix + line)
        return "\n".join(formatted)

    do_h = do_help

    def help_exec(self):
        """(!) statement
        Execute the (one-line) statement in the context of the current
        stack frame.  The exclamation point can be omitted unless the
        first word of the statement resembles a debugger command.  To
        assign to a global variable you must always prefix the command
        with a 'global' command, e.g.:
        (Pdb) global list_options; list_options = ['-l']
        (Pdb)
        """
        self.message((Pdb.help_exec.__doc__ or "").strip())

    def help_pdb(self):
        help()

    # other helper functions

    def lookupmodule(self, filename):
        """Helper function for break/clear parsing -- may be overridden.

        lookupmodule() translates (possibly incomplete) file or module name
        into an absolute file name.
        """
        if os.path.isabs(filename) and os.path.exists(filename):
            return filename
        if os.path.exists(filename):
            return os.path.abspath(filename)
        if self.mainpyfile:
            f = os.path.join(os.path.dirname(self.mainpyfile), filename)
            if os.path.exists(f) and self.canonic(f) == self.mainpyfile:
                return f
        root, ext = os.path.splitext(filename)
        if ext == "":
            filename = filename + ".ny"
        if os.path.isabs(filename):
            return filename
        for dirname in ["", "lib"]:
            fullname = os.path.join(dirname, filename) if dirname else filename
            if os.path.exists(fullname):
                return os.path.abspath(fullname)
        return None

    def _run(self, filename, code, namespace):
        # When bdb sets tracing, a number of call and line events happen
        # BEFORE debugger even reaches user's code (and the exact sequence of
        # events depends on python version). Take special measures to
        # avoid stopping before reaching the main script (see user_line and
        # user_call for details).
        self._wait_for_mainpyfile = True
        self._user_requested_quit = False
        self.mainpyfile = self.canonic(filename)
        self.run(code, namespace)

    def _format_exc(self, exc):
        return traceback.format_exception_only(type(exc), exc)[-1].strip()

    def _getsourcelines(self, obj):
        lines, lineno = _getsourcelines(obj)
        lineno = max(1, lineno)
        return lines, lineno


# Simplified interface

def run(statement, globals=None, locals=None):
    Pdb().run(statement, globals, locals)


def runeval(expression, globals=None, locals=None):
    return Pdb().runeval(expression, globals, locals)


def runctx(statement, globals, locals):
    # B/W compatibility
    run(statement, globals, locals)


def runcall(*args, **kwds):
    return Pdb().runcall(*args, **kwds)


def set_trace(*, header=None):
    pdb = Pdb()
    if header is not None:
        pdb.message(header)
    pdb.set_trace(sys._getframe().f_back)


# Post-Mortem interface

def post_mortem(t=None):
    # handling the default
    if t is None:
        # sys.exc_info() returns (type, value, traceback) if an exception is
        # being handled, otherwise it returns None
        t = sys.exc_info()[2]
    if t is None:
        raise ValueError("A valid traceback must be passed if no exception is being handled")
    p = Pdb()
    p.reset()
    p.interaction(None, t)


def pm():
    post_mortem(sys.last_traceback)


def help():
    for name in _help_order:
        doc = getattr(Pdb, "do_" + name).__doc__
        if doc:
            print(doc.strip())
            print()


_help_order = [
    "help", "where", "down", "up", "break", "tbreak", "clear", "disable",
    "enable", "ignore", "condition", "commands", "step", "next", "until",
    "jump", "return", "retval", "run", "continue", "list", "longlist",
    "args", "p", "pp", "whatis", "source", "display", "undisplay",
    "interact", "alias", "unalias", "debug", "quit",
]

_usage = """usage: pdb.py [-c command] ... [-m module | pyfile] [arg] ...

Debug the Python program given by pyfile. Alternatively,
an executable module or package to debug can be specified using
the -m switch.

Initial commands are read from .pdbrc files in your home directory
and in the current directory, if they exist.  Commands supplied with
-c are executed after commands from .pdbrc files.

To let the script run until an exception occurs, use "-c continue".
To let the script run up to a given line X in the debugged file, use
"-c 'until X'"."""


def main():
    args = sys.argv[1:]
    commands = []
    module_indicated = False
    while args and args[0].startswith("-"):
        a = args[0]
        args = args[1:]
        if a in ("-h", "--help"):
            print(_usage)
            sys.exit(0)
        elif a == "-m":
            module_indicated = True
        elif a in ("-c", "--command"):
            commands.append(args[0])
            args = args[1:]
        elif a.startswith("-c"):
            commands.append(a[2:])
        elif a.startswith("--command="):
            commands.append(a[10:])
        elif a == "--":
            break
        else:
            print("pdb.py: error: option %s not recognized" % a)
            print(_usage)
            sys.exit(2)
    if not args:
        print(_usage)
        sys.exit(2)
    target = args[0]
    if module_indicated:
        path = target.replace(".", "/") + ".ny"
        if not os.path.exists(path) and os.path.exists(os.path.join("lib", path)):
            path = os.path.join("lib", path)
        target = path
    if not os.path.exists(target):
        print("Error:", target, "does not exist")
        sys.exit(1)
    if os.path.isdir(target):
        print("Error:", target, "is a directory")
        sys.exit(1)
    target = os.path.realpath(target)
    sys.argv[:] = args      # Hide "pdb.py" and pdb options from argument list
    pdb = Pdb()
    pdb.rcLines.extend(commands)
    while True:
        f = open(target)
        try:
            src = f.read()
        finally:
            f.close()
        try:
            code = compile(src, target, "exec")
            pdb._run(target, code, {"__name__": "__main__", "__file__": target, "__spec__": None})
            if pdb._user_requested_quit:
                break
            print("The program finished and will be restarted")
        except Restart:
            print("Restarting", target, "with arguments:")
            print("\t" + " ".join(sys.argv[1:]))
        except SystemExit:
            # In most cases SystemExit does not warrant a post-mortem session.
            print("The program exited via sys.exit(). Exit status:", end=" ")
            print(sys.exc_info()[1])
        except SyntaxError:
            traceback.print_exc()
            sys.exit(1)
        except BaseException:
            traceback.print_exc()
            print("Uncaught exception. Entering post mortem debugging")
            print("Running 'cont' or 'step' will restart the program")
            t = sys.exc_info()[2]
            pdb.interaction(None, t)
            print("Post mortem debugger finished. The " + target + " will be restarted")


# When invoked as main program, invoke the debugger on a script
if __name__ == "__main__":
    main()
