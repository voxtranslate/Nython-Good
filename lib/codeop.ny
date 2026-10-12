# nython: module    (import it by name: it runs in a module scope of its own)
# lib/codeop.ny - Python's codeop: compile source that may be incomplete
# (round 79; lib/code.ny's consoles read with it).
#
#     import codeop
#     codeop.compile_command("if x:")        # None: more input is needed
#     codeop.compile_command("x = 1")        # a code object
#     codeop.compile_command("1 +")          # SyntaxError
#
# compile_command(source, filename="<input>", symbol="single")
#   a code object when the source is complete, None when it is the start
#   of something longer (an open bracket, an unterminated triple-quoted
#   string, a trailing backslash, a line ending in ":", a decorator without
#   its def, a compound statement not yet followed by a newline, a try
#   without its handlers), SyntaxError (or OverflowError / ValueError) when
#   it is wrong whatever follows; a source of blank lines and comments is
#   "pass" (CPython's rules - the same answers for the same inputs).
# Compile()            a compile() that remembers `from __future__` imports
#                      (its flags) for the following calls
# CommandCompiler()    compile_command with that memory
# PyCF_DONT_IMPLY_DEDENT, PyCF_ALLOW_INCOMPLETE_INPUT (their values only)
#
# How "incomplete" is told: CPython's compiler flags an error found at the
# end of the input as incomplete input; here a lexical scan of the source
# (brackets, strings, continuation lines, block headers) answers first, and
# a syntax error the parser reports past the last line of the source is
# taken as incomplete too.
# In "single" mode an expression statement's value is printed by Python's
# compiled code (sys.displayhook); the code objects here run as "exec" -
# a code object made for a single expression carries it as
# `_ny_single_expr`, which lib/code.ny's runcode evaluates and displays.
#
# Not here: the compiler's own flags (only __future__ imports are seen).

__all__ = ["compile_command", "Compile", "CommandCompiler"]

PyCF_DONT_IMPLY_DEDENT = 0x200
PyCF_ALLOW_INCOMPLETE_INPUT = 0x4000

_FEATURES = ["nested_scopes", "generators", "division", "absolute_import", "with_statement",
             "print_function", "unicode_literals", "barry_as_FLUFL", "generator_stop", "annotations"]


def _scan(source):
    # (open brackets, inside a triple-quoted string, ends with a backslash
    # continuation, the last logical line)
    depth = 0
    i = 0
    n = len(source)
    triple = None
    last_line = ""
    cur = ""
    while i < n:
        c = source[i]
        if triple is not None:
            if source.startswith(triple, i):
                cur += triple
                i += 3
                triple = None
                continue
            if c == "\\":
                cur += source[i:i + 2]
                i += 2
                continue
            cur += c
            i += 1
            continue
        if c == "#":
            j = source.find("\n", i)
            if j < 0:
                j = n
            i = j
            continue
        if c == "\"" or c == "'":
            if source.startswith(c * 3, i):
                triple = c * 3
                cur += triple
                i += 3
                continue
            # a one-line string: to its closing quote or the end of the line
            j = i + 1
            while j < n and source[j] != c and source[j] != "\n":
                if source[j] == "\\":
                    j += 1
                j += 1
            cur += source[i:j + 1]
            i = j + 1
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "\n":
            if depth <= 0 and not cur.rstrip().endswith("\\"):
                if cur.strip():
                    last_line = cur
                cur = ""
                i += 1
                continue
        cur += c
        i += 1
    backslash = cur.rstrip("\n").endswith("\\") and not cur.endswith("\n")
    if cur.strip():
        last_line = cur
    return depth, triple is not None, backslash, last_line


def _first_logical_line(source):
    for line in source.split("\n"):
        s = line.strip()
        if s and not s.startswith("#"):
            return line
    return ""


_COMPOUND = ("if", "elif", "else", "for", "while", "try", "except", "finally", "with", "def",
             "class", "async", "match", "case")


def _starts_block(line):
    s = line.strip()
    if s.startswith("@"):
        return True
    word = ""
    for ch in s:
        if ch.isalnum() or ch == "_":
            word += ch
        else:
            break
    return word in _COMPOUND


def _first_word(line):
    word = ""
    for ch in line.strip():
        if ch.isalnum() or ch == "_":
            word += ch
        else:
            break
    return word


def _incomplete(source):
    if _first_word(_first_logical_line(source)) in ("else", "elif", "except", "finally"):
        return False    # a clause without its statement: wrong whatever follows
    depth, in_triple, backslash, last = _scan(source)
    if in_triple or backslash:
        return True
    if depth > 0:
        return True
    if depth < 0:
        return False
    code = last.split("#")[0].rstrip() if "#" in last and "'" not in last and "\"" not in last else last.rstrip()
    if code.endswith(":"):
        return True
    if last.strip().startswith("@"):
        return True
    first = _first_logical_line(source)
    if first and _starts_block(first) and not source.endswith("\n"):
        # a compound statement is complete at a newline after its body
        return True
    return False


def _error_past_end(e, source):
    lines = source.rstrip("\n").split("\n")
    ln = getattr(e, "lineno", None)
    msg = str(getattr(e, "msg", "") or e)
    if "EOF" in msg or "end of file" in msg or "unexpected end" in msg or "expected an indented block" in msg:
        return True
    return ln is not None and ln > len(lines)


def _maybe_compile(compiler, source, filename, symbol):
    # Check for source consisting of only blank lines and comments.
    blank = True
    for line in source.split("\n"):
        line = line.strip()
        if line and line[0] != "#":
            blank = False
            break
    if blank:
        if symbol != "eval":
            source = "pass"     # Replace it with a 'pass' statement
    elif _incomplete(source):
        return None
    try:
        return compiler(source, filename, symbol)
    except SyntaxError as e:
        if source.endswith("\n") and _error_past_end(e, source):
            lines = [l for l in source.split("\n") if l.strip()]
            if lines and lines[-1][:1] in (" ", "\t"):
                return None
        raise


def _compile(source, filename, symbol):
    return compile(source, filename, symbol)


def compile_command(source, filename="<input>", symbol="single"):
    r"""Compile a command and determine whether it is incomplete.

    Arguments:

    source -- the source string; may contain \n characters
    filename -- optional filename from which source was read; default
                "<input>"
    symbol -- optional grammar start symbol; "single" (default), "exec"
              or "eval"

    Return value / exceptions raised:

    - Return a code object if the command is complete and valid
    - Return None if the command is incomplete
    - Raise SyntaxError, ValueError or OverflowError if the command is a
      syntax error (OverflowError and ValueError can be produced by
      malformed literals).
    """
    return _maybe_compile(Compile(), source, filename, symbol)


class Compile:
    """Instances of this class behave much like the built-in compile
    function, but if one is used to compile text containing a future
    statement, it "remembers" and compiles all subsequent program texts
    with the statement in force."""

    def __init__(self):
        self.flags = PyCF_DONT_IMPLY_DEDENT | PyCF_ALLOW_INCOMPLETE_INPUT
        self.features = []

    def __call__(self, source, filename, symbol, **kwargs):
        if symbol not in ("exec", "eval", "single"):
            raise ValueError("compile() mode must be 'exec', 'eval' or 'single'")
        prefix = ""
        for f in self.features:
            prefix += "from __future__ import " + f + "\n"
        text = source
        if prefix and symbol != "eval":
            text = prefix + source
        codeob = compile(text, filename, "eval" if symbol == "eval" else "exec")
        if symbol == "single":
            try:
                expr = compile(source.strip(), filename, "eval")
                codeob._ny_single_expr = expr
            except SyntaxError:
                pass
        for line in source.split("\n"):
            s = line.strip()
            if s.startswith("from __future__ import"):
                for name in s[len("from __future__ import"):].replace("(", "").replace(")", "").split(","):
                    name = name.strip().split(" ")[0]
                    if name in _FEATURES and name not in self.features:
                        self.features.append(name)
        return codeob


class CommandCompiler:
    """Instances of this class have __call__ methods identical in
    signature to compile_command; the difference is that if the
    instance compiles program text containing a __future__ statement,
    the instance 'remembers' and compiles all subsequent program texts
    with the statement in force."""

    def __init__(self):
        self.compiler = Compile()

    def __call__(self, source, filename="<input>", symbol="single"):
        r"""Compile a command and determine whether it is incomplete.

        Arguments:

        source -- the source string; may contain \n characters
        filename -- optional filename from which source was read;
                    default "<input>"
        symbol -- optional grammar start symbol; "single" (default) or
                  "eval"

        Return value / exceptions raised:

        - Return a code object if the command is complete and valid
        - Return None if the command is incomplete
        - Raise SyntaxError, ValueError or OverflowError if the command is a
          syntax error (OverflowError and ValueError can be produced by
          malformed literals).
        """
        return _maybe_compile(self.compiler, source, filename, symbol)
