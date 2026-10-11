# nython: module    (import it by name: it runs in a module scope of its own)
# lib/code.ny - Python's code: read-eval-print loops in a program (round 79).
#
#     import code
#     console = code.InteractiveConsole({"x": 2})
#     console.push("y = x * 21")          # False: the statement ran
#     console.push("if y:")               # True: more input is needed
#     console.push("    print(y)")
#     console.push("")                    # prints 42
#     code.interact(banner="", readfunc=lines.pop, local={"x": 1})
#
# InteractiveInterpreter(locals=None)   locals default to {"__name__":
#   "__console__", "__doc__": None}
#   runsource(source, filename="<input>", symbol="single")  True when more
#     input is needed (codeop's compile_command said None), else False after
#     running it or reporting its syntax error
#   runcode(code)        exec in self.locals; SystemExit passes, any other
#                        exception is reported by showtraceback(); an
#                        expression in "single" mode has its repr printed and
#                        bound to builtins' _ (sys.displayhook's work)
#   showsyntaxerror(filename=None), showtraceback()   Python's report
#                        (traceback.format_exception_only / format_exception
#                        without the console's own frame), through write();
#                        sys.last_type / last_value / last_traceback set
#   write(data)          sys.stderr.write(data)
# InteractiveConsole(locals=None, filename="<console>")
#   push(line)           appends to the buffer and runs it (runsource);
#                        True while more input is needed
#   interact(banner=None, exitmsg=None)   the loop: prompts sys.ps1 / sys.ps2
#                        (">>> ", "... "), raw_input(prompt), EOFError ends it
#                        ("now exiting InteractiveConsole..."), a
#                        KeyboardInterrupt drops the buffer
#   raw_input(prompt="") input(prompt); replace it (or pass readfunc to
#                        interact) to script a session
#   resetbuffer()
# interact(banner=None, readfunc=None, local=None, exitmsg=None)
# compile_command (codeop's)
#
# Not here: readline history and completion (no readline module).

import sys
import traceback
from codeop import CommandCompiler, compile_command

__all__ = ["InteractiveInterpreter", "InteractiveConsole", "interact", "compile_command"]


class InteractiveInterpreter:
    """Base class for InteractiveConsole.

    This class deals with parsing and interpreter state (the user's
    namespace); it doesn't deal with input buffering or prompting or
    input file naming (the filename is always passed in explicitly).
    """

    def __init__(self, locals=None):
        """Constructor.

        The optional 'locals' argument specifies the dictionary in
        which code will be executed; it defaults to a newly created
        dictionary with key "__name__" set to "__console__" and key
        "__doc__" set to None.
        """
        if locals is None:
            locals = {"__name__": "__console__", "__doc__": None}
        self.locals = locals
        self.compile = CommandCompiler()

    def runsource(self, source, filename="<input>", symbol="single"):
        """Compile and run some source in the interpreter.

        One of several things can happen:

        1) The input is incorrect; compile_command() raised an
        exception (SyntaxError or OverflowError).  A syntax traceback
        will be printed by calling the showsyntaxerror() method.

        2) The input is incomplete, and more input is required;
        compile_command() returned None.  Nothing happens.

        3) The input is complete; compile_command() returned a code
        object.  The code is executed by calling self.runcode() (which
        also handles run-time exceptions, except for SystemExit).

        The return value is True in case 2, False in the other cases (unless
        an exception is raised).  The return value can be used to
        decide whether to use sys.ps1 or sys.ps2 to prompt the next
        line.
        """
        try:
            code = self.compile(source, filename, symbol)
        except (OverflowError, SyntaxError, ValueError):
            # Case 1
            self.showsyntaxerror(filename)
            return False
        if code is None:
            # Case 2
            return True
        # Case 3
        self.runcode(code)
        return False

    def runcode(self, code):
        """Execute a code object.

        When an exception occurs, self.showtraceback() is called to
        display a traceback.  All exceptions are caught except
        SystemExit, which is reraised.

        A note about KeyboardInterrupt: this exception may occur
        elsewhere in this code, and may not always be caught.  The
        caller should be prepared to deal with it.
        """
        try:
            expr = getattr(code, "_ny_single_expr", None)
            if expr is not None:
                value = eval(expr, self.locals)
                if value is not None:
                    self._display(value)
            else:
                exec(code, self.locals)
        except SystemExit:
            raise
        except BaseException:
            self.showtraceback()

    def _display(self, value):
        # sys.displayhook: print the repr and keep the value as _
        hook = getattr(sys, "displayhook", None)
        if hook is not None:
            hook(value)
            return
        self.locals["_"] = value
        print(repr(value))

    def showsyntaxerror(self, filename=None):
        """Display the syntax error that just occurred.

        This doesn't display a stack trace because there isn't one.

        If a filename is given, it is stuffed in the exception instead
        of what was there before (because Python's parser always uses
        "<string>" when reading from a string).

        The output is written by self.write(), below.
        """
        etype, value, tb = sys.exc_info()
        sys.last_type = etype
        sys.last_value = value
        sys.last_traceback = tb
        if filename and etype is SyntaxError:
            try:
                value.filename = filename
            except Exception:
                pass
        lines = traceback.format_exception_only(etype, value)
        self.write("".join(lines))

    def showtraceback(self):
        """Display the exception that just occurred.

        We remove the first stack item because it is our own code.

        The output is written by self.write(), below.
        """
        ei = sys.exc_info()
        sys.last_type = ei[0]
        sys.last_value = ei[1]
        last_tb = ei[2]
        sys.last_traceback = last_tb
        tb = last_tb
        # our own frames (this module's runcode) are not shown
        while tb is not None and tb.tb_frame.f_code.co_filename.endswith("code.ny"):
            tb = tb.tb_next
        lines = traceback.format_exception(ei[0], ei[1], tb)
        self.write("".join(lines))

    def write(self, data):
        """Write a string.

        The base implementation writes to sys.stderr; a subclass may
        replace this with a different implementation.
        """
        sys.stderr.write(data)


class InteractiveConsole(InteractiveInterpreter):
    """Closely emulate the behavior of the interactive Python interpreter.

    This class builds on InteractiveInterpreter and adds prompting
    using the familiar sys.ps1 and sys.ps2, and input buffering.
    """

    def __init__(self, locals=None, filename="<console>"):
        """Constructor.

        The optional locals argument will be passed to the
        InteractiveInterpreter base class.

        The optional filename argument should specify the (file)name
        of the input stream; it will show up in tracebacks.
        """
        InteractiveInterpreter.__init__(self, locals)
        self.filename = filename
        self.resetbuffer()

    def resetbuffer(self):
        """Reset the input buffer."""
        self.buffer = []

    def interact(self, banner=None, exitmsg=None):
        """Closely emulate the interactive Python console.

        The optional banner argument specifies the banner to print
        before the first interaction; by default it prints a banner
        similar to the one printed by the real Python interpreter,
        followed by the current class name in parentheses (so as not
        to confuse this with the real interpreter -- since it's so
        close!).

        The optional exitmsg argument specifies the exit message
        printed when exiting. Pass the empty string to suppress
        printing an exit message. If exitmsg is not given or None,
        a default message is printed.
        """
        ps1 = getattr(sys, "ps1", ">>> ")
        ps2 = getattr(sys, "ps2", "... ")
        cprt = 'Type "help", "copyright", "credits" or "license" for more information.'
        if banner is None:
            self.write("Nython %s on %s\n%s\n(%s)\n" % (sys.version, sys.platform, cprt, self.__class__.__name__))
        elif banner:
            self.write("%s\n" % str(banner))
        more = 0
        while 1:
            try:
                if more:
                    prompt = ps2
                else:
                    prompt = ps1
                try:
                    line = self.raw_input(prompt)
                except EOFError:
                    self.write("\n")
                    break
                more = self.push(line)
            except KeyboardInterrupt:
                self.write("\nKeyboardInterrupt\n")
                self.resetbuffer()
                more = 0
        if exitmsg is None:
            self.write("now exiting %s...\n" % self.__class__.__name__)
        elif exitmsg != "":
            self.write("%s\n" % exitmsg)

    def push(self, line):
        """Push a line to the interpreter.

        The line should not have a trailing newline; it may have
        internal newlines.  The line is appended to a buffer and the
        interpreter's runsource() method is called with the
        concatenated contents of the buffer as source.  If this
        indicates that the command was executed or invalid, the buffer
        is reset; otherwise, the command is incomplete, and the buffer
        is left as it was after the line was appended.  The return
        value is 1 if more input is required, 0 if the line was dealt
        with in some way (this is the same as runsource()).
        """
        self.buffer.append(line)
        source = "\n".join(self.buffer)
        more = self.runsource(source, self.filename)
        if not more:
            self.resetbuffer()
        return more

    def raw_input(self, prompt=""):
        """Write a prompt and read a line.

        The returned line does not include the trailing newline.
        When the user enters the EOF key sequence, EOFError is raised.

        The base implementation uses the built-in function
        input(); a subclass may replace this with a different
        implementation.
        """
        return input(prompt)


def interact(banner=None, readfunc=None, local=None, exitmsg=None):
    """Closely emulate the interactive Python interpreter.

    This is a backwards compatible interface to the InteractiveConsole
    class.  When readfunc is not specified, it attempts to import the
    readline module to enable GNU readline if it is available.

    Arguments (all optional, all default to None):

    banner -- passed to InteractiveConsole.interact()
    readfunc -- if not None, replaces InteractiveConsole.raw_input()
    local -- passed to InteractiveInterpreter.__init__()
    exitmsg -- passed to InteractiveConsole.interact()
    """
    console = InteractiveConsole(local)
    if readfunc is not None:
        console.raw_input = readfunc
    console.interact(banner, exitmsg)


if __name__ == "__main__":
    interact()
