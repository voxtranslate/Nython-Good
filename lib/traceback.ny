# nython: module    (import it by name: it runs in a module scope of its own)
# lib/traceback.ny - Python's traceback: extract, format and print stack
# traces and exceptions.
#
#     import traceback
#     try:
#         work()
#     except Exception:
#         traceback.print_exc()                 # as an uncaught one prints
#         text = traceback.format_exc()
#
# The engines give every exception a real traceback: e.__traceback__ is a
# chain of traceback objects (tb_frame, tb_lineno, tb_lasti, tb_next), one
# per frame the exception passed on its way to the except clause, outermost
# first, as in Python (a re-raised exception keeps its old frames behind the
# new ones). e.__context__ (the exception being handled when it was raised),
# e.__cause__ (raise X from Y) and e.__suppress_context__ are kept;
# sys.exc_info() is (type, value, traceback); sys._getframe(depth) gives the
# running frames (f_code.co_filename / co_name, f_lineno, f_back).
#
# print_tb(tb, limit=None, file=None)          format_tb(tb, limit=None)
# print_exception(exc, /, value, tb, limit=None, file=None, chain=True)
# format_exception(exc, /, value, tb, limit=None, chain=True)
# format_exception_only(exc, /, value)
# print_exc(limit=None, file=None, chain=True) format_exc(limit=None, chain=True)
# print_last(limit=None, file=None, chain=True)   (sys.last_value)
# print_stack(f=None, limit=None, file=None)   format_stack(f=None, limit=None)
# extract_tb(tb, limit=None)                   extract_stack(f=None, limit=None)
# format_list(extracted_list)                  print_list(extracted_list, file=None)
# walk_tb(tb)  walk_stack(f)                   (frame, lineno) pairs
# clear_frames(tb)
# FrameSummary(filename, lineno, name, *, lookup_line=True, locals=None,
#              line=None, end_lineno=None, colno=None, end_colno=None)
#     .filename .lineno .name .line (from linecache, stripped) .locals;
#     compares equal to a (filename, lineno, name, line) tuple, unpacks as one
# StackSummary   a list of FrameSummary: extract(frame_gen, *, limit=None,
#     lookup_lines=True, capture_locals=False), from_list(a_list), format(),
#     format_frame_summary(fs); "[Previous line repeated N more times]" after
#     three identical entries (deep recursion), as Python
# TracebackException(exc_type, exc_value, exc_traceback, *, limit=None,
#     lookup_lines=True, capture_locals=False, compact=False)
#     .from_exception(exc, **kw), .stack, .exc_type, .__cause__, .__context__,
#     .__suppress_context__, .__notes__, .format(chain=True),
#     .format_exception_only(), .print(file=None, chain=True); SyntaxError's
#     filename / lineno / text / offset shown with the caret line
#
# The text is Python's byte for byte - "Traceback (most recent call last):",
# '  File "f.ny", line 3, in g', the source line, "Type: message", notes
# (add_note), the chained exceptions first with "The above exception was the
# direct cause of the following exception:" / "During handling of the above
# exception, another exception occurred:" - except for what the runtime does
# not record: there are no column positions, so no "^^^^" lines under a
# source line; frames carry no local variables, so capture_locals adds
# nothing; exception groups are not formatted as groups; a frame's f_back is
# None for the frames of a traceback; frames of the runtime's own prelude
# (the code behind builtins such as open() and print(file=)) are not shown,
# as Python shows no frame for a function written in C.

import sys
import linecache

__all__ = ["extract_stack", "extract_tb", "format_exception",
           "format_exception_only", "format_list", "format_stack",
           "format_tb", "print_exc", "format_exc", "print_exception",
           "print_last", "print_stack", "print_tb", "clear_frames",
           "FrameSummary", "StackSummary", "TracebackException",
           "walk_stack", "walk_tb"]


class _TbSentinel:
    def __repr__(self):
        return "<implicit>"
_sentinel = _TbSentinel()

_cause_message = ("\nThe above exception was the direct cause " +
                  "of the following exception:\n\n")

_context_message = ("\nDuring handling of the above exception, " +
                    "another exception occurred:\n\n")

_RECURSIVE_CUTOFF = 3   # Also hardcoded in traceback.c.


def _stderr():
    return sys.stderr


def _print_lines(lines, file):
    if file is None:
        file = _stderr()
    for line in lines:
        file.write(line)


def _type_name(x):
    if x is None:
        return "NoneType"
    return type(x).__name__


def _is_exception(v):
    return isinstance(v, BaseException)


#
# Formatting and printing lists of traceback lines.
#

def print_list(extracted_list, file=None):
    """Print the list of tuples as returned by extract_tb() or
    extract_stack() as a formatted stack trace to the given file."""
    _print_lines(StackSummary.from_list(extracted_list).format(), file)


def format_list(extracted_list):
    """Format a list of tuples or FrameSummary objects for printing.

    Given a list of tuples or FrameSummary objects as returned by
    extract_tb() or extract_stack(), return a list of strings ready
    for printing."""
    return StackSummary.from_list(extracted_list).format()


#
# Printing and Extracting Tracebacks.
#

def print_tb(tb, limit=None, file=None):
    """Print up to 'limit' stack trace entries from the traceback 'tb'."""
    print_list(extract_tb(tb, limit=limit), file=file)


def format_tb(tb, limit=None):
    """A shorthand for 'format_list(extract_tb(tb, limit))'."""
    return extract_tb(tb, limit=limit).format()


def extract_tb(tb, limit=None):
    """Return a StackSummary object representing a list of pre-processed
    entries from traceback."""
    return StackSummary._extract_from_extended_frame_gen(_walk_tb_with_full_positions(tb), limit=limit)


#
# Exception formatting and output.
#

def _parse_value_tb(exc, value, tb):
    if (value is _sentinel) != (tb is _sentinel):
        raise ValueError("Both or neither of value and tb must be given")
    if value is _sentinel and tb is _sentinel:
        if exc is not None:
            if _is_exception(exc):
                return (exc, exc.__traceback__)
            raise TypeError("Exception expected for value, " + _type_name(exc) + " found")
        else:
            return (None, None)
    return (value, tb)


def print_exception(exc, value=_sentinel, tb=_sentinel, limit=None, file=None, chain=True):
    """Print exception up to 'limit' stack trace entries from 'tb' to 'file'.

    This differs from print_tb() in the following ways: (1) if
    traceback is not None, it prints a header "Traceback (most recent
    call last):"; (2) it prints the exception type and value after the
    stack trace; (3) if type is SyntaxError and value has the
    appropriate format, it prints the line where the syntax error
    occurred with a caret on the next line indicating the approximate
    position of the error."""
    var vt = _parse_value_tb(exc, value, tb)
    var te = TracebackException(type(vt[0]) if vt[0] is not None else None, vt[0], vt[1], limit=limit, compact=True)
    te.print(file=file, chain=chain)


def format_exception(exc, value=_sentinel, tb=_sentinel, limit=None, chain=True):
    """Format a stack trace and the exception information.

    The arguments have the same meaning as the corresponding arguments
    to print_exception().  The return value is a list of strings, each
    ending in a newline and some containing internal newlines.  When
    these lines are concatenated and printed, exactly the same text is
    printed as does print_exception()."""
    var vt = _parse_value_tb(exc, value, tb)
    var te = TracebackException(type(vt[0]) if vt[0] is not None else None, vt[0], vt[1], limit=limit, compact=True)
    return list(te.format(chain=chain))


def format_exception_only(exc, value=_sentinel):
    """Format the exception part of a traceback.

    The return value is a list of strings, each ending in a newline.

    The list contains the exception's message, which is
    normally a single string; however, for :exc:`SyntaxError` exceptions, it
    contains several lines that (when printed) display detailed information
    about where the syntax error occurred. Following the message, the list
    contains the exception's ``__notes__``."""
    if value is _sentinel:
        value = exc
    var te = TracebackException(type(value) if value is not None else None, value, None, compact=True)
    return list(te.format_exception_only())


def _format_final_exc_line(etype, value):
    var valuestr = _safe_string(value, "exception")
    if value is None or not valuestr:
        return etype + "\n"
    return etype + ": " + valuestr + "\n"


def _safe_string(value, what, func=str):
    if value is None:
        return "None"
    try:
        if func is repr:
            return repr(value)
        return str(value)
    except Exception:
        return "<" + what + " " + func.__name__ + "() failed>"


def print_exc(limit=None, file=None, chain=True):
    """Shorthand for 'print_exception(*sys.exc_info(), limit, file, chain)'."""
    var ei = sys.exc_info()
    print_exception(ei[0], ei[1], ei[2], limit=limit, file=file, chain=chain)


def format_exc(limit=None, chain=True):
    """Like print_exc() but return a string."""
    var ei = sys.exc_info()
    return "".join(format_exception(ei[0], ei[1], ei[2], limit=limit, chain=chain))


def print_last(limit=None, file=None, chain=True):
    """This is a shorthand for 'print_exception(sys.last_type,
    sys.last_value, sys.last_traceback, limit, file, chain)'."""
    var lv = getattr(sys, "last_value", None)
    if lv is None:
        raise ValueError("no last exception")
    print_exception(type(lv), lv, getattr(sys, "last_traceback", None), limit, file, chain)


#
# Printing and Extracting Stacks.
#

def print_stack(f=None, limit=None, file=None):
    """Print a stack trace from its invocation point.

    The optional 'f' argument can be used to specify an alternate
    stack frame at which to start. The optional 'limit' and 'file'
    arguments have the same meaning as for print_exception()."""
    if f is None:
        f = sys._getframe().f_back
    print_list(extract_stack(f, limit=limit), file=file)


def format_stack(f=None, limit=None):
    """Shorthand for 'format_list(extract_stack(f, limit))'."""
    if f is None:
        f = sys._getframe().f_back
    return format_list(extract_stack(f, limit=limit))


def extract_stack(f=None, limit=None):
    """Extract the raw traceback from the current stack frame.

    The return value has the same format as for extract_tb().  The
    optional 'f' and 'limit' arguments have the same meaning as for
    print_stack().  Each item in the list is a quadruple (filename,
    line number, function name, text), and the entries are in order
    from oldest to newest stack frame."""
    if f is None:
        f = sys._getframe().f_back
    var stack = StackSummary.extract(walk_stack(f), limit=limit)
    stack.reverse()
    return stack


def clear_frames(tb):
    "Clear all references to local variables in the frames of a traceback."
    while tb is not None:
        tb.tb_frame.clear()
        tb = tb.tb_next


class FrameSummary:
    """Information about a single frame from a traceback.

    - :attr:`filename` The filename for the frame.
    - :attr:`lineno` The line within filename for the frame that was
      active when the frame was captured.
    - :attr:`name` The name of the function or method that was executing
      when the frame was captured.
    - :attr:`line` The text from the linecache module for the
      of code that was running when the frame was captured.
    - :attr:`locals` Either None if locals were not supplied, or a dict
      mapping the name to the repr() of the variable.
    """

    def __init__(self, filename, lineno, name, *, lookup_line=True,
                 locals=None, line=None,
                 end_lineno=None, colno=None, end_colno=None):
        """Construct a FrameSummary.

        :param lookup_line: If True, `linecache` is consulted for the source
            code line. Otherwise, the line will be looked up when first needed.
        :param locals: If supplied the frame locals, which will be captured as
            object representations.
        :param line: If provided, use this instead of looking up the line in
            the linecache.
        """
        self.filename = filename
        self.lineno = lineno
        self.name = name
        self._line = line
        if lookup_line:
            self.line
        self.locals = None
        if locals:
            self.locals = {}
            for k in locals:
                self.locals[k] = repr(locals[k])
        self.end_lineno = end_lineno
        self.colno = colno
        self.end_colno = end_colno

    def __eq__(self, other):
        if isinstance(other, FrameSummary):
            return (self.filename == other.filename and
                    self.lineno == other.lineno and
                    self.name == other.name and
                    self.locals == other.locals)
        if isinstance(other, tuple):
            return (self.filename, self.lineno, self.name, self.line) == other
        return NotImplemented

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return NotImplemented
        return not r

    def __getitem__(self, pos):
        return (self.filename, self.lineno, self.name, self.line)[pos]

    def __iter__(self):
        return iter([self.filename, self.lineno, self.name, self.line])

    def __repr__(self):
        return "<FrameSummary file " + str(self.filename) + ", line " + str(self.lineno) + " in " + str(self.name) + ">"

    def __len__(self):
        return 4

    @property
    def _original_line(self):
        # Returns the line as-is from the source, without modifying whitespace.
        self.line
        return self._line

    @property
    def line(self):
        if self._line is None:
            if self.lineno is None:
                return None
            self._line = linecache.getline(self.filename, self.lineno)
        return self._line.strip()


def walk_stack(f):
    """Walk a stack yielding the frame and line number for each frame.

    This will follow f.f_back from the given frame. If no frame is given, the
    current stack is used. Usually used with StackSummary.extract.
    """
    if f is None:
        f = sys._getframe(1)
    while f is not None:
        yield (f, f.f_lineno)
        f = f.f_back


def walk_tb(tb):
    """Walk a traceback yielding the frame and line number for each frame.

    This will follow tb.tb_next (and thus is in the opposite order to
    walk_stack). Usually used with StackSummary.extract.
    """
    while tb is not None:
        yield (tb.tb_frame, tb.tb_lineno)
        tb = tb.tb_next


def _walk_tb_with_full_positions(tb):
    # (frame, (lineno, end_lineno, colno, end_colno)): no column positions here
    while tb is not None:
        yield (tb.tb_frame, (tb.tb_lineno, None, None, None))
        tb = tb.tb_next


def _get_code_position(code, instruction_index):
    return (None, None, None, None)


class StackSummary:
    """A list of FrameSummary objects, representing a stack of frames."""

    def __init__(self, items=None):
        self._items = []
        if items is not None:
            for x in items:
                self._items.append(x)

    # ── the list protocol (a StackSummary is a list in Python) ──
    def __len__(self):
        return len(self._items)

    def __getitem__(self, i):
        if isinstance(i, slice):
            return StackSummary(self._items[i])
        return self._items[i]

    def __setitem__(self, i, v):
        self._items[i] = v

    def __iter__(self):
        return iter(self._items)

    def __reversed__(self):
        return iter(list(reversed(self._items)))

    def __contains__(self, x):
        for y in self._items:
            if y == x:
                return True
        return False

    def __eq__(self, other):
        if isinstance(other, StackSummary):
            other = other._items
        if not isinstance(other, list):
            return False
        if len(other) != len(self._items):
            return False
        var i = 0
        while i < len(self._items):
            if not (self._items[i] == other[i]):
                return False
            i += 1
        return True

    def __ne__(self, other):
        return not self.__eq__(other)

    def __bool__(self):
        return len(self._items) > 0

    def __repr__(self):
        return "[" + ", ".join([repr(x) for x in self._items]) + "]"

    def __add__(self, other):
        return StackSummary(self._items + list(other))

    def append(self, x):
        self._items.append(x)

    def extend(self, xs):
        for x in xs:
            self._items.append(x)

    def insert(self, i, x):
        self._items.insert(i, x)

    def pop(self, i=-1):
        return self._items.pop(i)

    def reverse(self):
        self._items.reverse()

    def index(self, x):
        var i = 0
        while i < len(self._items):
            if self._items[i] == x:
                return i
            i += 1
        raise ValueError(repr(x) + " is not in list")

    def count(self, x):
        var n = 0
        for y in self._items:
            if y == x:
                n += 1
        return n

    def copy(self):
        return StackSummary(self._items)

    @classmethod
    def extract(klass, frame_gen, *, limit=None, lookup_lines=True,
            capture_locals=False):
        """Create a StackSummary from a traceback or stack object.

        :param frame_gen: A generator that yields (frame, lineno) tuples
            whose summaries are to be included in the stack.
        :param limit: None to include all frames or the number of frames to
            include.
        :param lookup_lines: If True, lookup lines for each frame immediately,
            otherwise lookup is deferred until the frame is rendered.
        :param capture_locals: If True, the local variables from each frame will
            be captured as object representations into the FrameSummary.
        """
        def extended_frame_gen():
            for pair in frame_gen:
                yield (pair[0], (pair[1], None, None, None))

        return klass._extract_from_extended_frame_gen(
            extended_frame_gen(), limit=limit, lookup_lines=lookup_lines,
            capture_locals=capture_locals)

    @classmethod
    def _extract_from_extended_frame_gen(klass, frame_gen, *, limit=None,
            lookup_lines=True, capture_locals=False):
        # Same as extract but operates on a frame generator that yields
        # (frame, (lineno, end_lineno, colno, end_colno)) in the stack.
        # Only lineno is required, the remaining fields can be None if the
        # information is not available.
        var frames = list(frame_gen)
        if limit is None:
            limit = getattr(sys, "tracebacklimit", None)
            if limit is not None and limit < 0:
                limit = 0
        if limit is not None:
            if limit >= 0:
                frames = frames[:limit]
            else:
                frames = frames[len(frames) + limit:] if -limit < len(frames) else frames
        var result = klass()
        var fnames = []
        for pair in frames:
            var f = pair[0]
            var pos = pair[1]
            var co = f.f_code
            var filename = co.co_filename
            var name = co.co_name
            if filename not in fnames:
                fnames.append(filename)
            linecache.lazycache(filename, f.f_globals)
            # Must defer line lookups until we have called checkcache.
            var f_locals = f.f_locals if capture_locals else None
            result.append(FrameSummary(
                filename, pos[0], name, lookup_line=False, locals=f_locals,
                end_lineno=pos[1], colno=pos[2], end_colno=pos[3]))
        for filename in fnames:
            linecache.checkcache(filename)
        # If immediate lookup was desired, trigger lookups now.
        if lookup_lines:
            for f in result:
                f.line
        return result

    @classmethod
    def from_list(klass, a_list):
        """
        Create a StackSummary object from a supplied list of
        FrameSummary objects or old-style list of tuples.
        """
        # While doing a fast-path check for isinstance(a_list, StackSummary) is
        # appealing, idlelib.run.cleanup_traceback and other similar code may
        # break this by making arbitrary frames plain tuples, so we need to
        # check on a frame by frame basis.
        var result = StackSummary()
        for frame in a_list:
            if isinstance(frame, FrameSummary):
                result.append(frame)
            else:
                result.append(FrameSummary(frame[0], frame[1], frame[2], line=frame[3]))
        return result

    def format_frame_summary(self, frame_summary):
        """Format the lines for a single FrameSummary.

        Returns a string representing one frame involved in the stack. This
        gets called for every frame to be printed in the stack summary.
        """
        var row = []
        row.append("  File \"" + str(frame_summary.filename) + "\", line " +
                   str(frame_summary.lineno) + ", in " + str(frame_summary.name) + "\n")
        if frame_summary.line:
            var stripped_line = frame_summary.line.strip()
            row.append("    " + stripped_line + "\n")
        if frame_summary.locals:
            for name in sorted(frame_summary.locals.keys()):
                row.append("    " + name + " = " + str(frame_summary.locals[name]) + "\n")
        return "".join(row)

    def format(self):
        """Format the stack ready for printing.

        Returns a list of strings ready for printing.  Each string in the
        resulting list corresponds to a single frame from the stack.
        Each string ends in a newline; the strings may contain internal
        newlines as well, for those items with source text lines.

        For long sequences of the same frame and line, the first few
        repetitions are shown, followed by a summary line stating the exact
        number of further repetitions.
        """
        var result = []
        var last_file = None
        var last_line = None
        var last_name = None
        var count = 0
        for frame_summary in self._items:
            var formatted_frame = self.format_frame_summary(frame_summary)
            if formatted_frame is None:
                continue
            if (last_file is None or last_file != frame_summary.filename or
                last_line is None or last_line != frame_summary.lineno or
                last_name is None or last_name != frame_summary.name):
                if count > _RECURSIVE_CUTOFF:
                    count -= _RECURSIVE_CUTOFF
                    result.append("  [Previous line repeated " + str(count) + " more time" +
                                  ("s" if count > 1 else "") + "]\n")
                last_file = frame_summary.filename
                last_line = frame_summary.lineno
                last_name = frame_summary.name
                count = 0
            count += 1
            if count > _RECURSIVE_CUTOFF:
                continue
            result.append(formatted_frame)

        if count > _RECURSIVE_CUTOFF:
            count -= _RECURSIVE_CUTOFF
            result.append("  [Previous line repeated " + str(count) + " more time" +
                          ("s" if count > 1 else "") + "]\n")
        return result


class _ExceptionPrintContext:
    def __init__(self):
        self.seen = []
        self.exception_group_depth = 0
        self.need_close = False

    def indent(self):
        return " " * (2 * self.exception_group_depth)

    def emit(self, text_gen, margin_char=None):
        if margin_char is None:
            margin_char = "|"
        var indent_str = self.indent()
        if self.exception_group_depth:
            indent_str += margin_char + " "
        var out = []
        if isinstance(text_gen, str):
            out.append(_indent_lines(text_gen, indent_str))
        else:
            for text in text_gen:
                out.append(_indent_lines(text, indent_str))
        return out


def _indent_lines(text, prefix):
    # textwrap.indent(text, prefix): prefix every line that is not blank
    if prefix == "":
        return text
    var lines = text.splitlines(True)
    var out = ""
    for ln in lines:
        if ln.strip() != "":
            out += prefix + ln
        else:
            out += ln
    return out


def _exc_qualname(t):
    var q = getattr(t, "__qualname__", None)
    if q is None:
        q = getattr(t, "__name__", "Exception")
    return q


class TracebackException:
    """An exception ready for rendering.

    The traceback module captures enough attributes from the original exception
    to this intermediary form to ensure that no references are held, while
    still being able to fully print or format it.

    max_group_width and max_group_depth control the formatting of exception
    groups (not formatted as groups here).

    Use `from_exception` to create TracebackException instances from exception
    objects, or the constructor to create TracebackException instances from
    individual components.

    - :attr:`__cause__` A TracebackException of the original *__cause__*.
    - :attr:`__context__` A TracebackException of the original *__context__*.
    - :attr:`__suppress_context__` The *__suppress_context__* value from the
      original exception.
    - :attr:`stack` A `StackSummary` representing the traceback.
    - :attr:`exc_type` The class of the original traceback.
    - :attr:`filename` For syntax errors - the filename where the error
      occurred.
    - :attr:`lineno` For syntax errors - the linenumber where the error
      occurred.
    - :attr:`end_lineno` For syntax errors - the end linenumber where the error
      occurred. Can be `None` if not present.
    - :attr:`text` For syntax errors - the text where the error
      occurred.
    - :attr:`offset` For syntax errors - the offset into the text where the
      error occurred.
    - :attr:`end_offset` For syntax errors - the end offset into the text where
      the error occurred. Can be `None` if not present.
    - :attr:`msg` For syntax errors - the compiler error message.
    """

    def __init__(self, exc_type, exc_value, exc_traceback, *, limit=None,
            lookup_lines=True, capture_locals=False, compact=False,
            max_group_width=15, max_group_depth=10, _seen=None):
        # NB: we need to accept exc_traceback, exc_value, exc_traceback to
        # permit backwards compat with the existing API, otherwise we
        # need stub thunk objects just to glue it together.
        # Handle loops in __cause__ or __context__.
        var is_recursive_call = _seen is not None
        if _seen is None:
            _seen = []
        self._seen = _seen
        self.max_group_width = max_group_width
        self.max_group_depth = max_group_depth

        self.stack = StackSummary._extract_from_extended_frame_gen(
            _walk_tb_with_full_positions(exc_traceback),
            limit=limit, lookup_lines=lookup_lines,
            capture_locals=capture_locals)
        self.exc_type = exc_type
        # Capture now to permit freeing resources: only complication is in the
        # unofficial API _format_final_exc_line
        self._str = _safe_string(exc_value, "exception")
        self.__notes__ = getattr(exc_value, "__notes__", None) if exc_value is not None else None
        self._is_none = exc_value is None
        self.__cause__ = None
        self.__context__ = None
        self.exceptions = None
        self._exc_value_id = id(exc_value)
        if exc_value is not None:
            _seen.append(id(exc_value))

        if exc_type is not None and exc_value is not None and isinstance(exc_value, SyntaxError):
            # Handle SyntaxError's specially
            self.filename = getattr(exc_value, "filename", None)
            var lno = getattr(exc_value, "lineno", None)
            self.lineno = str(lno) if lno is not None else None
            var end_lno = getattr(exc_value, "end_lineno", None)
            self.end_lineno = str(end_lno) if end_lno is not None else None
            self.text = getattr(exc_value, "text", None)
            self.offset = getattr(exc_value, "offset", None)
            self.end_offset = getattr(exc_value, "end_offset", None)
            self.msg = getattr(exc_value, "msg", None)
        if lookup_lines:
            self._load_lines()
        self.__suppress_context__ = exc_value.__suppress_context__ if exc_value is not None else False

        # Convert __cause__ and __context__ to `TracebackExceptions`s, use a
        # queue to avoid recursion (only the top-level call gets _seen == None)
        if not is_recursive_call:
            var queue = [(self, exc_value)]
            while queue:
                var pair = queue.pop()
                var te = pair[0]
                var e = pair[1]
                var cause = None
                if (e is not None and getattr(e, "__cause__", None) is not None
                        and id(e.__cause__) not in _seen):
                    cause = TracebackException(
                        type(e.__cause__),
                        e.__cause__,
                        e.__cause__.__traceback__,
                        limit=limit,
                        lookup_lines=lookup_lines,
                        capture_locals=capture_locals,
                        max_group_width=max_group_width,
                        max_group_depth=max_group_depth,
                        _seen=_seen)
                var need_context = True
                if compact:
                    need_context = (cause is None and
                                    e is not None and
                                    not e.__suppress_context__)
                var context = None
                if (e is not None and getattr(e, "__context__", None) is not None
                        and need_context and id(e.__context__) not in _seen):
                    context = TracebackException(
                        type(e.__context__),
                        e.__context__,
                        e.__context__.__traceback__,
                        limit=limit,
                        lookup_lines=lookup_lines,
                        capture_locals=capture_locals,
                        max_group_width=max_group_width,
                        max_group_depth=max_group_depth,
                        _seen=_seen)
                te.__cause__ = cause
                te.__context__ = context
                te.exceptions = None
                if cause is not None:
                    queue.append((te.__cause__, e.__cause__))
                if context is not None:
                    queue.append((te.__context__, e.__context__))

    @classmethod
    def from_exception(cls, exc, *args, **kwargs):
        """Create a TracebackException from an exception."""
        return cls(type(exc), exc, exc.__traceback__, *args, **kwargs)

    def _load_lines(self):
        """Private API. force all lines in the stack to be loaded."""
        for frame in self.stack:
            frame.line

    def __eq__(self, other):
        if isinstance(other, TracebackException):
            return (self.exc_type == other.exc_type and self._str == other._str and
                    self.stack == other.stack and self.__cause__ == other.__cause__ and
                    self.__context__ == other.__context__ and
                    self.__suppress_context__ == other.__suppress_context__)
        return NotImplemented

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return NotImplemented
        return not r

    def __str__(self):
        return self._str

    def format_exception_only(self):
        """Format the exception part of the traceback.

        The return value is a generator of strings, each ending in a newline.

        Generator yields the exception message.
        For :exc:`SyntaxError` exceptions, it
        also yields (before the exception message)
        several lines that (when printed)
        display detailed information about where the syntax error occurred.
        Following the message, generator also yields
        all the exception's ``__notes__``.
        """
        var out = []
        if self.exc_type is None:
            out.append(_format_final_exc_line("NoneType" if self._is_none else None, self._str))
            return out

        var stype = _exc_qualname(self.exc_type)
        var smod = getattr(self.exc_type, "__module__", "builtins")
        if smod != "__main__" and smod != "builtins":
            if not isinstance(smod, str):
                smod = "<unknown>"
            stype = smod + "." + stype

        if not issubclass(self.exc_type, SyntaxError):
            out.append(_format_final_exc_line(stype, self._str))
        else:
            for x in self._format_syntax_error(stype):
                out.append(x)
        if isinstance(self.__notes__, list) or isinstance(self.__notes__, tuple):
            for note in self.__notes__:
                note = _safe_string(note, "note")
                for l in note.split("\n"):
                    out.append(l + "\n")
        elif self.__notes__ is not None:
            out.append(_safe_string(self.__notes__, "__notes__", func=repr))
        return out

    def _format_syntax_error(self, stype):
        """Format SyntaxError exceptions (internal helper)."""
        # Show exactly where the problem was found.
        var out = []
        var filename_suffix = ""
        if self.lineno is not None:
            out.append("  File \"" + str(self.filename or "<string>") + "\", line " + str(self.lineno) + "\n")
        elif self.filename is not None:
            filename_suffix = " (" + str(self.filename) + ")"

        var text = self.text
        if text is not None:
            # text  = "   foo\n"
            # rtext = "   foo"
            # ltext =    "foo"
            var rtext = text.rstrip("\n")
            var ltext = rtext.lstrip(" \n\f")
            var spaces = len(rtext) - len(ltext)
            out.append("    " + ltext + "\n")

            if self.offset is not None:
                var offset = self.offset
                var end_offset = self.end_offset if self.end_offset not in (None, 0) else offset
                if offset == end_offset or end_offset == -1:
                    end_offset = offset + 1

                # Convert 1-based column offset to 0-based index into stripped text
                var colno = offset - 1 - spaces
                var end_colno = end_offset - 1 - spaces
                if colno >= 0:
                    # non-space whitespace (likes tabs) must be kept for alignment
                    var caretspace = ""
                    for c in ltext[:colno]:
                        caretspace += c if c.isspace() else " "
                    out.append("    " + caretspace + ("^" * (end_colno - colno)) + "\n")
        var msg = self.msg if self.msg is not None else "<no detail available>"
        out.append(stype + ": " + str(msg) + filename_suffix + "\n")
        return out

    def format(self, *, chain=True, _ctx=None):
        """Format the exception.

        If chain is not *True*, *__cause__* and *__context__* will not be formatted.

        The return value is a generator of strings, each ending in a newline and
        some containing internal newlines. `print_exception` is a wrapper around
        this method which just prints the lines to a file.

        The message indicating which exception occurred is always the last
        string in the output.
        """
        if _ctx is None:
            _ctx = _ExceptionPrintContext()

        var output = []
        var exc = self
        if chain:
            while exc is not None:
                var chained_msg = None
                var chained_exc = None
                if exc.__cause__ is not None:
                    chained_msg = _cause_message
                    chained_exc = exc.__cause__
                elif (exc.__context__ is not None and
                      not exc.__suppress_context__):
                    chained_msg = _context_message
                    chained_exc = exc.__context__
                output.append((chained_msg, exc))
                exc = chained_exc
        else:
            output.append((None, exc))

        var lines = []
        var i = len(output) - 1
        while i >= 0:
            var msg = output[i][0]
            var e = output[i][1]
            if msg is not None:
                lines.extend(_ctx.emit(msg))
            if e.stack:
                lines.extend(_ctx.emit("Traceback (most recent call last):\n"))
                lines.extend(_ctx.emit(e.stack.format()))
            lines.extend(_ctx.emit(e.format_exception_only()))
            i -= 1
        return lines

    def print(self, *, file=None, chain=True):
        """Print the result of self.format(chain=chain) to 'file'."""
        if file is None:
            file = _stderr()
        for line in self.format(chain=chain):
            file.write(line)
