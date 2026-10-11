# nython: module    (import it by name: it runs in a module scope of its own)
# lib/cmd.ny - Python's cmd: a framework for line-oriented command
# interpreters (round 79; lib/pdb.ny is built on it).
#
#     import cmd
#     class Shell(cmd.Cmd):
#         prompt = "(shell) "
#         def do_greet(self, arg):
#             "Greet someone: greet NAME"
#             self.stdout.write("hello " + arg + "\n")
#         def do_quit(self, arg):
#             return True
#     Shell(stdin=io.StringIO("greet bob\nquit\n"), stdout=out).cmdloop()
#
# Cmd(completekey="tab", stdin=None, stdout=None)   as CPython's cmd.Cmd:
#   cmdloop(intro=None)  preloop, the intro, then read - precmd - onecmd -
#                        postcmd until a command returns a true value, then
#                        postloop; commands queued in cmdqueue go first;
#                        with use_rawinput (the default) lines come from
#                        input(prompt), else from self.stdin.readline() with
#                        the prompt written to self.stdout; end of input is
#                        the command "EOF"
#   onecmd(line)         parseline, then do_<cmd>(arg); an empty line runs
#                        emptyline() (the last command again); an unknown
#                        command runs default(line) ("*** Unknown syntax")
#   parseline(line)      (cmd, arg, line); "?" is help, "!" is shell when
#                        do_shell exists; identchars ends the command name
#   do_help(arg)         a help_<arg> method, else do_<arg>'s docstring, else
#                        nohelp; without an argument the documented and
#                        undocumented commands and the help topics, in
#                        CPython's columns (columnize, print_topics)
#   completenames, complete_help, completedefault, get_names (dir of the
#   class), columnize(list, displaywidth=80), the class attributes prompt,
#   identchars, ruler, lastcmd, intro, doc_leader, doc_header, misc_header,
#   undoc_header, nohelp, use_rawinput, cmdqueue
#
# Not here: tab completion through readline (there is no readline module:
# cmdloop does not install a completer; complete(text, state) is still
# there for a caller that supplies its own line buffer through
# set_line_buffer()).

import string
import sys

__all__ = ["Cmd"]

PROMPT = "(Cmd) "
IDENTCHARS = string.ascii_letters + string.digits + "_"


class Cmd:
    """A simple framework for writing line-oriented command interpreters.

    These are often useful for test harnesses, administrative tools, and
    prototypes that will later be wrapped in a more sophisticated interface.

    A Cmd instance or subclass instance is a line-oriented interpreter
    framework.  There is no good reason to instantiate Cmd itself; rather,
    it's useful as a superclass of an interpreter class you define yourself
    in order to inherit Cmd's methods and encapsulate action methods.
    """
    prompt = PROMPT
    identchars = IDENTCHARS
    ruler = "="
    lastcmd = ""
    intro = None
    doc_leader = ""
    doc_header = "Documented commands (type help <topic>):"
    misc_header = "Miscellaneous help topics:"
    undoc_header = "Undocumented commands:"
    nohelp = "*** No help on %s"
    use_rawinput = 1
    completion_matches = None
    _line_buffer = ""
    _begidx = 0
    _endidx = 0

    def __init__(self, completekey="tab", stdin=None, stdout=None):
        """Instantiate a line-oriented interpreter framework.

        The optional argument 'completekey' is the readline name of a
        completion key; it defaults to the Tab key. If completekey is
        not None and the readline module is available, command completion
        is done automatically. The optional arguments stdin and stdout
        specify alternate input and output file objects; if not specified,
        sys.stdin and sys.stdout are used.
        """
        if stdin is not None:
            self.stdin = stdin
        else:
            self.stdin = sys.stdin
        if stdout is not None:
            self.stdout = stdout
        else:
            self.stdout = sys.stdout
        self.cmdqueue = []
        self.completekey = completekey

    def cmdloop(self, intro=None):
        """Repeatedly issue a prompt, accept input, parse an initial prefix
        off the received input, and dispatch to action methods, passing them
        the remainder of the line as argument.
        """
        self.preloop()
        if intro is not None:
            self.intro = intro
        if self.intro:
            self.stdout.write(str(self.intro) + "\n")
        stop = None
        while not stop:
            if self.cmdqueue:
                line = self.cmdqueue.pop(0)
            else:
                if self.use_rawinput:
                    try:
                        line = input(self.prompt)
                    except EOFError:
                        line = "EOF"
                else:
                    self.stdout.write(self.prompt)
                    self.stdout.flush()
                    line = self.stdin.readline()
                    if not len(line):
                        line = "EOF"
                    else:
                        line = line.rstrip("\r\n")
            line = self.precmd(line)
            stop = self.onecmd(line)
            stop = self.postcmd(stop, line)
        self.postloop()

    def precmd(self, line):
        """Hook method executed just before the command line is
        interpreted, but after the input prompt is generated and issued.
        """
        return line

    def postcmd(self, stop, line):
        """Hook method executed just after a command dispatch is finished."""
        return stop

    def preloop(self):
        """Hook method executed once when the cmdloop() method is called."""
        pass

    def postloop(self):
        """Hook method executed once when the cmdloop() method is about to
        return.
        """
        pass

    def parseline(self, line):
        """Parse the line into a command name and a string containing
        the arguments.  Returns a tuple containing (command, args, line).
        'command' and 'args' may be None if the line couldn't be parsed.
        """
        line = line.strip()
        if not line:
            return None, None, line
        elif line[0] == "?":
            line = "help " + line[1:]
        elif line[0] == "!":
            if hasattr(self, "do_shell"):
                line = "shell " + line[1:]
            else:
                return None, None, line
        i = 0
        n = len(line)
        while i < n and line[i] in self.identchars:
            i = i + 1
        cmd = line[:i]
        arg = line[i:].strip()
        return cmd, arg, line

    def onecmd(self, line):
        """Interpret the argument as though it had been typed in response
        to the prompt.

        This may be overridden, but should not normally need to be;
        see the precmd() and postcmd() methods for useful execution hooks.
        The return value is a flag indicating whether interpretation of
        commands by the interpreter should stop.
        """
        cmd, arg, line = self.parseline(line)
        if not line:
            return self.emptyline()
        if cmd is None:
            return self.default(line)
        self.lastcmd = line
        if line == "EOF":
            self.lastcmd = ""
        if cmd == "":
            return self.default(line)
        else:
            func = getattr(self, "do_" + cmd, None)
            if func is None:
                return self.default(line)
            return func(arg)

    def emptyline(self):
        """Called when an empty line is entered in response to the prompt.

        If this method is not overridden, it repeats the last nonempty
        command entered.
        """
        if self.lastcmd:
            return self.onecmd(self.lastcmd)

    def default(self, line):
        """Called on an input line when the command prefix is not recognized.

        If this method is not overridden, it prints an error message and
        returns.
        """
        self.stdout.write("*** Unknown syntax: %s\n" % line)

    def completedefault(self, *ignored):
        """Method called to complete an input line when no command-specific
        complete_*() method is available.

        By default, it returns an empty list.
        """
        return []

    def completenames(self, text, *ignored):
        dotext = "do_" + text
        return [a[3:] for a in self.get_names() if a.startswith(dotext)]

    def set_line_buffer(self, line, begidx=None, endidx=None):
        # Nython: what readline would report for complete() (no readline here)
        self._line_buffer = line
        self._begidx = len(line) if begidx is None else begidx
        self._endidx = len(line) if endidx is None else endidx

    def complete(self, text, state):
        """Return the next possible completion for 'text'.

        If a command has not been entered, then complete against command list.
        Otherwise try to call complete_<command> to get list of completions.
        """
        if state == 0:
            origline = self._line_buffer
            line = origline.lstrip()
            stripped = len(origline) - len(line)
            begidx = self._begidx - stripped
            endidx = self._endidx - stripped
            if begidx > 0:
                cmd, args, foo = self.parseline(line)
                if cmd == "":
                    compfunc = self.completedefault
                else:
                    compfunc = getattr(self, "complete_" + cmd, None)
                    if compfunc is None:
                        compfunc = self.completedefault
            else:
                compfunc = self.completenames
            self.completion_matches = compfunc(text, line, begidx, endidx)
        if self.completion_matches is not None and 0 <= state and state < len(self.completion_matches):
            return self.completion_matches[state]
        return None

    def get_names(self):
        # This method used to pull in base class attributes
        # at a time dir() didn't do it yet.
        return dir(self.__class__)

    def complete_help(self, *args):
        commands = set(self.completenames(*args))
        topics = set([a[5:] for a in self.get_names() if a.startswith("help_" + args[0])])
        return list(commands | topics)

    def do_help(self, arg):
        'List available commands with "help" or detailed help with "help cmd".'
        if arg:
            func = getattr(self, "help_" + arg, None)
            if func is None:
                m = getattr(self, "do_" + arg, None)
                if m is not None:
                    doc = getattr(m, "__doc__", None)
                    if doc:
                        self.stdout.write("%s\n" % str(doc))
                        return
                self.stdout.write("%s\n" % str(self.nohelp % (arg,)))
                return
            func()
        else:
            names = self.get_names()
            cmds_doc = []
            cmds_undoc = []
            topics = set()
            for name in names:
                if name[:5] == "help_":
                    topics.add(name[5:])
            names.sort()
            # There can be duplicates if routines overridden
            prevname = ""
            for name in names:
                if name[:3] == "do_":
                    if name == prevname:
                        continue
                    prevname = name
                    cmd = name[3:]
                    if cmd in topics:
                        cmds_doc.append(cmd)
                        topics.remove(cmd)
                    elif getattr(getattr(self, name), "__doc__", None):
                        cmds_doc.append(cmd)
                    else:
                        cmds_undoc.append(cmd)
            self.stdout.write("%s\n" % str(self.doc_leader))
            self.print_topics(self.doc_header, cmds_doc, 15, 80)
            self.print_topics(self.misc_header, sorted(topics), 15, 80)
            self.print_topics(self.undoc_header, cmds_undoc, 15, 80)

    def print_topics(self, header, cmds, cmdlen, maxcol):
        if cmds:
            self.stdout.write("%s\n" % str(header))
            if self.ruler:
                self.stdout.write("%s\n" % str(self.ruler * len(header)))
            self.columnize(cmds, maxcol - 1)
            self.stdout.write("\n")

    def columnize(self, list, displaywidth=80):
        """Display a list of strings as a compact set of columns.

        Each column is only as wide as necessary.
        Columns are separated by two spaces (one was not legible enough).
        """
        if not list:
            self.stdout.write("<empty>\n")
            return
        nonstrings = [i for i in range(len(list)) if not isinstance(list[i], str)]
        if nonstrings:
            raise TypeError("list[i] not a string for i in %s" % ", ".join([str(i) for i in nonstrings]))
        size = len(list)
        if size == 1:
            self.stdout.write("%s\n" % str(list[0]))
            return
        # Try every row count from 1 upwards
        found = False
        nrows = 1
        ncols = 1
        colwidths = [0]
        for nr in range(1, len(list)):
            nrows = nr
            ncols = (size + nrows - 1) // nrows
            colwidths = []
            totwidth = -2
            for col in range(ncols):
                colwidth = 0
                for row in range(nrows):
                    i = row + nrows * col
                    if i >= size:
                        break
                    x = list[i]
                    colwidth = max(colwidth, len(x))
                colwidths.append(colwidth)
                totwidth += colwidth + 2
                if totwidth > displaywidth:
                    break
            if totwidth <= displaywidth:
                found = True
                break
        if not found:
            nrows = len(list)
            ncols = 1
            colwidths = [0]
        for row in range(nrows):
            texts = []
            for col in range(ncols):
                i = row + nrows * col
                if i >= size:
                    x = ""
                else:
                    x = list[i]
                texts.append(x)
            while texts and not texts[-1]:
                del texts[-1]
            for col in range(len(texts)):
                texts[col] = texts[col].ljust(colwidths[col])
            self.stdout.write("%s\n" % str("  ".join(texts)))
