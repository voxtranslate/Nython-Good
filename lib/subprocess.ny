# nython: module    (import it by name: it runs in a module scope of its own)
# lib/subprocess.ny - Python's subprocess: run programs, talk to them.
#
#     run(args, *, stdin, input, stdout, stderr, capture_output, shell, cwd,
#         timeout, check, encoding, errors, text, env, universal_newlines)
#         -> CompletedProcess(args, returncode, stdout, stderr)
#     call, check_call, check_output, getoutput, getstatusoutput,
#     list2cmdline
#     Popen(args, bufsize, executable, stdin, stdout, stderr, ..., shell,
#           cwd, env, universal_newlines, ..., encoding, errors, text)
#         .args .pid .returncode .stdin .stdout .stderr .universal_newlines
#         .poll() .wait(timeout) .communicate(input, timeout)
#         .send_signal(sig) .terminate() .kill(), a context manager
#     PIPE, STDOUT, DEVNULL; SubprocessError, CalledProcessError,
#     TimeoutExpired
#
# Built on the native process layer (src/builtins/os_proc.cpp): os_run for
# run() and the helpers (one native call that feeds input, collects both
# streams and enforces the timeout - no deadlock however much is written
# either way), os_spawn / os_proc_read / os_proc_write / os_wait / os_kill
# for Popen. An argument list runs the program directly (fork + exec / no
# shell); shell=True runs a string through /bin/sh -c (cmd.exe, or the POSIX
# sh found, on Windows). Without text=True (or encoding, errors,
# universal_newlines) output is bytes, as in CPython; text mode decodes and
# translates "\r\n" and "\r" to "\n".
#
# Differences from CPython:
#   - stdin/stdout/stderr=None share this process's streams on POSIX (the
#     native inherit= option); on Windows the output is captured and then
#     written to sys.stdout / sys.stderr when the process is waited for.
#   - A file object (or a Nython file handle) as stdout/stderr receives the
#     output when the process is waited for, not as it is written; as stdin
#     its remaining content is the process's input.
#   - executable=, preexec_fn, pass_fds, user/group, umask, startupinfo and
#     creationflags are accepted and ignored. Every child leads a process
#     group of its own (kill() ends what it started too), as if
#     process_group=0 were given.
#   - Popen.communicate(input) writes the input in pieces between reads of
#     the output; a child that writes more than a pipe holds (64 KB) before
#     reading any input can still block, which run() never does.

import os

__all__ = ["Popen", "PIPE", "STDOUT", "call", "check_call", "getstatusoutput",
           "getoutput", "check_output", "run", "CalledProcessError", "DEVNULL",
           "SubprocessError", "TimeoutExpired", "CompletedProcess", "list2cmdline"]

PIPE = -1
STDOUT = -2
DEVNULL = -3

_mswindows = os_platform() == "windows"
_CAN_INHERIT = not _mswindows

_SIGNAL_NAMES = {1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP",
                 6: "SIGABRT", 7: "SIGBUS", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGUSR1",
                 11: "SIGSEGV", 12: "SIGUSR2", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
                 17: "SIGCHLD", 18: "SIGCONT", 19: "SIGSTOP", 20: "SIGTSTP", 21: "SIGTTIN",
                 22: "SIGTTOU", 23: "SIGURG", 24: "SIGXCPU", 25: "SIGXFSZ", 26: "SIGVTALRM",
                 27: "SIGPROF", 28: "SIGWINCH", 29: "SIGIO", 30: "SIGPWR", 31: "SIGSYS"}


class SubprocessError(Exception):
    pass


class CalledProcessError(SubprocessError):
    """Raised when run() is called with check=True and the process
    returns a non-zero exit status.

    Attributes:
      cmd, returncode, stdout, stderr, output
    """
    def __init__(self, returncode, cmd, output=none, stderr=none):
        SubprocessError.__init__(self, returncode, cmd)
        self.returncode = returncode
        self.cmd = cmd
        self.output = output
        self.stderr = stderr

    def __str__(self):
        if self.returncode and self.returncode < 0:
            var sig = -self.returncode
            var name = _SIGNAL_NAMES.get(sig)
            if name is none:
                return "Command '" + _cmd_text(self.cmd) + "' died with unknown signal " + str(sig) + "."
            return "Command '" + _cmd_text(self.cmd) + "' died with <Signals." + name + ": " + str(sig) + ">."
        return "Command '" + _cmd_text(self.cmd) + "' returned non-zero exit status " + str(self.returncode) + "."

    @property
    def stdout(self):
        """Alias for output attribute, to match stderr"""
        return self.output


class TimeoutExpired(SubprocessError):
    """This exception is raised when the timeout expires while waiting for a
    child process.

    Attributes:
        cmd, output, stdout, stderr, timeout
    """
    def __init__(self, cmd, timeout, output=none, stderr=none):
        SubprocessError.__init__(self, cmd, timeout)
        self.cmd = cmd
        self.timeout = timeout
        self.output = output
        self.stderr = stderr

    def __str__(self):
        return "Command '" + _cmd_text(self.cmd) + "' timed out after " + str(self.timeout) + " seconds"

    @property
    def stdout(self):
        return self.output


def _cmd_text(cmd):
    # "%s" % cmd: a list shows as its repr
    return str(cmd)


class CompletedProcess:
    """A process that has finished running.

    This is returned by run().

    Attributes:
      args: The list or str args passed to run().
      returncode: The exit code of the process, negative for signals.
      stdout: The standard output (None if not captured).
      stderr: The standard error (None if not captured).
    """
    def __init__(self, args, returncode, stdout=none, stderr=none):
        self.args = args
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr

    def __repr__(self):
        var a = ["args=" + repr(self.args), "returncode=" + repr(self.returncode)]
        if self.stdout is not none:
            a.append("stdout=" + repr(self.stdout))
        if self.stderr is not none:
            a.append("stderr=" + repr(self.stderr))
        return "CompletedProcess(" + ", ".join(a) + ")"

    def check_returncode(self):
        """Raise CalledProcessError if the exit code is non-zero."""
        if self.returncode:
            raise CalledProcessError(self.returncode, self.args, self.stdout, self.stderr)


# ── helpers ──────────────────────────────────────────────────────────────────

# Python's name for a value's type (Nython calls dict "map", str "string").
_PY_TYPE_NAMES = {"map": "dict", "string": "str", "none": "NoneType", "builtin": "builtin_function_or_method"}


def _tname(x):
    var n = x.__class__.__name__ if hasattr(x, "__class__") else type(x).__name__
    return _PY_TYPE_NAMES.get(n, n)


def _fspath(p):
    if isinstance(p, str) or isinstance(p, bytes):
        return p
    if hasattr(p, "__fspath__"):
        return p.__fspath__()
    return p


def _arg_text(a):
    a = _fspath(a)
    if isinstance(a, bytes) or isinstance(a, bytearray):
        return bytes(a).decode("utf-8")
    if not isinstance(a, str):
        raise TypeError("expected str, bytes or os.PathLike object, not " + type(a).__name__)
    return a


# The native command: a list (no shell) or a string (through the shell).
def _native_cmd(args, shell):
    if isinstance(args, str) or isinstance(args, bytes) or hasattr(args, "__fspath__"):
        var s = _arg_text(args)
        if shell:
            return s
        if _mswindows:
            return s
        return [s]
    var argv = []
    for a in args:
        argv.append(_arg_text(a))
    if shell:
        if _mswindows:
            return list2cmdline(argv)
        if len(argv) == 0:
            raise IndexError("list index out of range")
        return ["/bin/sh", "-c"] + argv
    if len(argv) == 0:
        raise IndexError("list index out of range")
    return argv


def _text_mode(text, universal_newlines, encoding, errors):
    return bool(encoding or errors or text or universal_newlines)


def _translate_newlines(s):
    if "\r" in s:
        s = s.replace("\r\n", "\n").replace("\r", "\n")
    return s


def _decode(b, encoding, errors):
    # b: the child's bytes as they came
    return _translate_newlines(b.decode(encoding or "utf-8", errors or "strict"))


def _as_bytes(raw):
    # The natives return output as a str holding the bytes as they came;
    # encoding it as UTF-8 gives those bytes back unchanged.
    return raw.encode("utf-8")


def _encode_input(data, text, encoding, errors):
    if data is none:
        return none
    if text:
        if not isinstance(data, str):
            raise TypeError("write() argument must be str, not " + _tname(data))
        if encoding is none or encoding.lower().replace("-", "").replace("_", "") == "utf8":
            return data
        return data.encode(encoding, errors or "strict")
    if isinstance(data, str):
        raise TypeError("memoryview: a bytes-like object is required, not 'str'")
    if not (isinstance(data, bytes) or isinstance(data, bytearray)):
        raise TypeError("memoryview: a bytes-like object is required, not '" + _tname(data) + "'")
    return bytes(data)


def _is_fileobj(x):
    return x is not none and not isinstance(x, int) and hasattr(x, "write")


# Where captured output goes once the process has been waited for: a file
# object, a Nython file handle, or the standard streams (Windows "inherit").
def _deliver(dest, data, text):
    if data is none or len(data) == 0:
        return
    if dest is none or (isinstance(dest, int) and (dest == 1 or dest == 2)):
        var stream = sys_stdout_() if dest is none or dest == 1 else sys_stderr_()
        stream.write(data if isinstance(data, str) else data.decode("utf-8", "replace"))
        stream.flush()
        return
    if isinstance(dest, int):
        file_write(dest, data)
        return
    if hasattr(dest, "mode") and "b" in dest.mode:
        dest.write(data if not isinstance(data, str) else data.encode("utf-8"))
    else:
        dest.write(data if isinstance(data, str) else data.decode("utf-8", "replace"))


def sys_stdout_():
    import sys
    return sys.stdout


def sys_stderr_():
    import sys
    return sys.stderr


def _read_stdin_source(stdin):
    # A file object or Nython handle as stdin: its remaining content.
    if isinstance(stdin, int):
        return file_read(stdin)
    return stdin.read()


# The plan for one process: native options plus where each stream goes.
class _SubprocessPlan:
    def __init__(self, stdin, stdout, stderr, text):
        self.inherit = ""
        self.merge = false
        self.keep_stdin = false
        self.input = none
        self.stdin_inherit = false
        # stdin
        if stdin is none or (isinstance(stdin, int) and stdin == 0):
            if _CAN_INHERIT:
                self.inherit = self.inherit + "0"
        elif isinstance(stdin, int) and stdin == PIPE:
            self.keep_stdin = true
        elif isinstance(stdin, int) and stdin == DEVNULL:
            pass
        else:
            var src = _read_stdin_source(stdin)
            self.input = src
        # stdout
        self.out_dest = none
        self.out_capture = false
        self.out_forward = false
        if stdout is none or (isinstance(stdout, int) and stdout == 1):
            if _CAN_INHERIT:
                self.inherit = self.inherit + "1"
            else:
                self.out_forward = true
        elif isinstance(stdout, int) and stdout == PIPE:
            self.out_capture = true
        elif isinstance(stdout, int) and stdout == DEVNULL:
            pass
        elif isinstance(stdout, int) and stdout == 2:
            self.out_dest = 2
            self.out_forward = true
        else:
            self.out_dest = stdout
            self.out_forward = true
        # stderr
        self.err_dest = none
        self.err_capture = false
        self.err_forward = false
        if isinstance(stderr, int) and stderr == STDOUT:
            self.merge = true
        elif stderr is none or (isinstance(stderr, int) and stderr == 2):
            if _CAN_INHERIT:
                self.inherit = self.inherit + "2"
            else:
                self.err_forward = true
                self.err_dest = 2
        elif isinstance(stderr, int) and stderr == PIPE:
            self.err_capture = true
        elif isinstance(stderr, int) and stderr == DEVNULL:
            pass
        else:
            self.err_dest = stderr
            self.err_forward = true


def _native_opts(plan, cwd, env):
    var kw = {}
    if cwd is not none:
        kw["cwd"] = _arg_text(cwd)
    if env is not none:
        var e = {}
        for k in env:
            e[_arg_text(k)] = _arg_text(env[k])
        kw["env"] = e
        kw["env_replace"] = true
    if plan.merge:
        kw["merge"] = true
    if plan.inherit:
        kw["inherit"] = plan.inherit
    return kw


# ── run and friends ──────────────────────────────────────────────────────────

def run(*popenargs, input=none, capture_output=false, timeout=none, check=false, **kwargs):
    """Run command with arguments and return a CompletedProcess instance.

    The returned instance will have attributes args, returncode, stdout and
    stderr. By default, stdout and stderr are not captured, and those
    attributes will be None. Pass stdout=PIPE and/or stderr=PIPE in order
    to capture them, or pass capture_output=True to capture both.

    If check is True and the exit code was non-zero, it raises a
    CalledProcessError. If timeout is given, and the process takes too
    long, a TimeoutExpired exception will be raised.

    There is an optional argument "input", allowing you to pass bytes or a
    string to the subprocess's stdin.
    """
    if input is not none:
        if kwargs.get("stdin") is not none:
            raise ValueError("stdin and input arguments may not both be used.")
    if capture_output:
        if kwargs.get("stdout") is not none or kwargs.get("stderr") is not none:
            raise ValueError("stdout and stderr arguments may not be used with capture_output.")
        kwargs["stdout"] = PIPE
        kwargs["stderr"] = PIPE
    var args = popenargs[0] if len(popenargs) > 0 else kwargs.get("args")
    if args is none:
        raise TypeError("run() missing 1 required positional argument: 'args'")
    var shell = kwargs.get("shell", false)
    var encoding = kwargs.get("encoding")
    var errors = kwargs.get("errors")
    var text = _text_mode(kwargs.get("text"), kwargs.get("universal_newlines"), encoding, errors)
    var stdin = kwargs.get("stdin")
    if input is not none:
        stdin = DEVNULL
    var plan = _SubprocessPlan(stdin, kwargs.get("stdout"), kwargs.get("stderr"), text)
    if input is not none:
        plan.input = _encode_input(input, text, encoding, errors)
        plan.inherit = plan.inherit.replace("0", "")
    elif plan.input is not none:
        plan.inherit = plan.inherit.replace("0", "")
    var cmd = _native_cmd(args, shell)
    var kw = _native_opts(plan, kwargs.get("cwd"), kwargs.get("env"))
    if plan.input is not none:
        kw["input"] = plan.input
    if timeout is not none:
        kw["timeout"] = timeout
    var r = none
    try:
        r = os_run(cmd, **kw)
    except TimeoutError:
        raise TimeoutExpired(args, timeout)
    var out = none
    var err = none
    if plan.out_capture:
        out = _decode(_as_bytes(r["stdout"]), encoding, errors) if text else _as_bytes(r["stdout"])
    elif plan.out_forward:
        _deliver(plan.out_dest, _decode(_as_bytes(r["stdout"]), encoding, "replace") if text or plan.out_dest is none else _as_bytes(r["stdout"]), text)
    if plan.err_capture:
        err = _decode(_as_bytes(r["stderr"]), encoding, errors) if text else _as_bytes(r["stderr"])
    elif plan.err_forward:
        _deliver(plan.err_dest, _decode(_as_bytes(r["stderr"]), encoding, "replace") if text or plan.err_dest == 2 else _as_bytes(r["stderr"]), text)
    var retcode = r["code"]
    if check and retcode:
        raise CalledProcessError(retcode, args, out, err)
    return CompletedProcess(args, retcode, out, err)


def call(*popenargs, timeout=none, **kwargs):
    """Run command with arguments.  Wait for command to complete or
    timeout, then return the returncode attribute.
    """
    return run(*popenargs, timeout=timeout, **kwargs).returncode


def check_call(*popenargs, **kwargs):
    """Run command with arguments.  Wait for command to complete.  If
    the exit code was zero then return, otherwise raise
    CalledProcessError.  The CalledProcessError object will have the
    return code in the returncode attribute.
    """
    var retcode = call(*popenargs, **kwargs)
    if retcode:
        var cmd = kwargs.get("args")
        if cmd is none:
            cmd = popenargs[0]
        raise CalledProcessError(retcode, cmd)
    return 0


def check_output(*popenargs, timeout=none, **kwargs):
    """Run command with arguments and return its output.

    If the exit code was non-zero it raises a CalledProcessError.  The
    CalledProcessError object will have the return code in the returncode
    attribute and output in the output attribute.
    """
    for kw in ["stdout", "check"]:
        if kw in kwargs:
            raise ValueError(kw + " argument not allowed, it will be overridden.")
    if "input" in kwargs and kwargs["input"] is none:
        # Explicitly passing input=None was previously equivalent to passing
        # an empty string. That is maintained here for backwards compatibility.
        if kwargs.get("universal_newlines") or kwargs.get("text") or kwargs.get("encoding") or kwargs.get("errors"):
            kwargs["input"] = ""
        else:
            kwargs["input"] = b""
    return run(*popenargs, stdout=PIPE, timeout=timeout, check=true, **kwargs).stdout


def getstatusoutput(cmd, encoding=none, errors=none):
    """Return (exitcode, output) of executing cmd in a shell.

    Execute the string 'cmd' in a shell with 'check_output' and
    return a 2-tuple (status, output). The locale encoding is used
    to decode the output and process newlines.

    A trailing newline is stripped from the output.
    """
    var data = none
    var exitcode = 0
    try:
        data = check_output(cmd, shell=true, text=true, stderr=STDOUT, encoding=encoding, errors=errors)
        exitcode = 0
    except CalledProcessError as ex:
        data = ex.output
        exitcode = ex.returncode
    if data[-1:] == "\n":
        data = data[:-1]
    return (exitcode, data)


def getoutput(cmd, encoding=none, errors=none):
    """Return output (stdout or stderr) of executing cmd in a shell.

    Like getstatusoutput(), except the exit status is ignored and the return
    value is a string containing the command's output.
    """
    return getstatusoutput(cmd, encoding, errors)[1]


def list2cmdline(seq):
    """
    Translate a sequence of arguments into a command line
    string, using the same rules as the MS C runtime:

    1) Arguments are delimited by white space, which is either a
       space or a tab.
    2) A string surrounded by double quotation marks is interpreted as a
       single argument, regardless of white space contained within.
    3) A double quotation mark preceded by a backslash is interpreted as a
       literal double quotation mark.
    4) Backslashes are interpreted literally, unless they immediately
       precede a double quotation mark.
    5) If backslashes immediately precede a double quotation mark, every
       pair of backslashes is interpreted as a literal backslash.
    """
    var result = []
    for a in seq:
        var arg = _arg_text(a)
        var bs_buf = []
        # Add a space to separate this argument from the others
        if result:
            result.append(" ")
        var needquote = (" " in arg) or ("\t" in arg) or not arg
        if needquote:
            result.append("\"")
        for c in arg:
            if c == "\\":
                # Don't know if we need to double yet.
                bs_buf.append(c)
            elif c == "\"":
                # Double backslashes.
                result.append("\\" * len(bs_buf) * 2)
                bs_buf = []
                result.append("\\\"")
            else:
                # Normal char
                if bs_buf:
                    result.extend(bs_buf)
                    bs_buf = []
                result.append(c)
        # Add remaining backslashes, if any.
        if bs_buf:
            result.extend(bs_buf)
        if needquote:
            result.extend(bs_buf)
            result.append("\"")
    return "".join(result)


# ── Popen ────────────────────────────────────────────────────────────────────

class _SubprocessPipeIn:
    # Popen.stdin with stdin=PIPE: writes go to the child's standard input.
    def __init__(self, proc):
        self._proc = proc
        self.closed = false
        self.mode = "w" if proc.text_mode else "wb"

    def write(self, data):
        if self.closed:
            raise ValueError("write to closed file")
        var p = self._proc
        var raw = _encode_input(data, p.text_mode, p._encoding, p._errors)
        p._write_input(raw)
        return len(data)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def flush(self):
        if self.closed:
            raise ValueError("flush of closed file")

    def close(self):
        if not self.closed:
            self.closed = true
            try:
                os_proc_close_stdin(self._proc.pid)
            except Exception:
                pass

    def writable(self):
        return true

    def readable(self):
        return false

    def __enter__(self):
        return self

    def __exit__(self, t=none, v=none, tb=none):
        self.close()
        return false


class _SubprocessPipeOut:
    # Popen.stdout / Popen.stderr with PIPE: reads come from the child.
    # The data waits in the Popen's buffers as bytes.
    def __init__(self, proc, which):
        self._proc = proc
        self._which = which
        self.closed = false
        self.mode = "r" if proc.text_mode else "rb"

    def _result(self, raw):
        var p = self._proc
        if p.text_mode:
            return _decode(raw, p._encoding, p._errors)
        return raw

    def read(self, size=-1):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        var p = self._proc
        var w = self._which
        if size is none or size < 0:
            while not p._eof:
                p._pump(true)
            var all = p._bufs[w]
            p._bufs[w] = b""
            return self._result(all)
        while len(p._bufs[w]) < size and not p._eof:
            p._pump(true)
        if not p.text_mode:
            var part = p._bufs[w][:size]
            p._bufs[w] = p._bufs[w][size:]
            return part
        var text = self._result(p._bufs[w])
        p._bufs[w] = text[size:].encode(p._encoding or "utf-8")
        return text[:size]

    def readline(self, size=-1):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        var p = self._proc
        var w = self._which
        while b"\n" not in p._bufs[w] and not p._eof:
            p._pump(true)
        var b = p._bufs[w]
        var i = b.find(b"\n")
        var end = len(b) if i < 0 else i + 1
        if size is not none and size >= 0 and size < end:
            end = size
        var line = b[:end]
        p._bufs[w] = b[end:]
        return self._result(line)

    def readlines(self, hint=-1):
        var out = []
        var line = self.readline()
        while len(line) > 0:
            out.append(line)
            line = self.readline()
        return out

    def __iter__(self):
        return self

    def __next__(self):
        var line = self.readline()
        if len(line) == 0:
            raise StopIteration()
        return line

    def close(self):
        self.closed = true

    def readable(self):
        return true

    def writable(self):
        return false

    def fileno(self):
        raise OSError("a Popen pipe has no file descriptor in Nython")

    def __enter__(self):
        return self

    def __exit__(self, t=none, v=none, tb=none):
        self.close()
        return false


class Popen:
    """ Execute a child program in a new process.

    For a complete description of the arguments see the Python documentation.

    Arguments:
      args: A string, or a sequence of program arguments.
      stdin, stdout and stderr: These specify the executed programs' standard
          input, standard output and standard error file handles: None
          (shared with this process), PIPE, DEVNULL, a file object, or
          STDOUT (for stderr).
      shell: If true, the command will be executed through the shell.
      cwd: Sets the current directory before the child is executed.
      env: Defines the environment variables for the new process.
      text / universal_newlines / encoding / errors: text mode.

    Attributes:
        stdin, stdout, stderr, pid, returncode
    """
    def __init__(self, args, bufsize=-1, executable=none,
                 stdin=none, stdout=none, stderr=none,
                 preexec_fn=none, close_fds=true,
                 shell=false, cwd=none, env=none, universal_newlines=none,
                 startupinfo=none, creationflags=0,
                 restore_signals=true, start_new_session=false,
                 pass_fds=(), user=none, group=none, extra_groups=none,
                 encoding=none, errors=none, text=none, umask=-1, pipesize=-1,
                 process_group=none):
        self.args = args
        self.returncode = none
        self.stdin = none
        self.stdout = none
        self.stderr = none
        self.pid = none
        self._encoding = encoding
        self._errors = errors
        if universal_newlines is not none and text is not none and bool(universal_newlines) != bool(text):
            raise SubprocessError("Cannot disambiguate when both text and universal_newlines are supplied but different. Pass one or the other.")
        self.text_mode = _text_mode(text, universal_newlines, encoding, errors)
        self._plan = _SubprocessPlan(stdin, stdout, stderr, self.text_mode)
        self._bufs = {"stdout": b"", "stderr": b""}
        self._eof = false
        self._communication_started = false
        self._delivered = false
        var cmd = _native_cmd(args, shell)
        var kw = _native_opts(self._plan, cwd, env)
        if self._plan.keep_stdin:
            kw["stdin"] = true
        elif self._plan.input is not none:
            var data = self._plan.input
            if self.text_mode and isinstance(data, str):
                data = _encode_input(data, true, encoding, errors)
            kw["input"] = data
        self.pid = os_spawn(cmd, **kw)
        if self._plan.keep_stdin:
            self.stdin = _SubprocessPipeIn(self)
        if self._plan.out_capture:
            self.stdout = _SubprocessPipeOut(self, "stdout")
        if self._plan.err_capture:
            self.stderr = _SubprocessPipeOut(self, "stderr")

    @property
    def universal_newlines(self):
        return self.text_mode

    def __repr__(self):
        return "<Popen: returncode: " + ("None" if self.returncode is none else str(self.returncode)) + " args: " + repr(self.args) + ">"

    def __enter__(self):
        return self

    def __exit__(self, exc_type, value, traceback):
        if self.stdout:
            self.stdout.close()
        if self.stderr:
            self.stderr.close()
        try:
            if self.stdin:
                self.stdin.close()
        finally:
            self.wait()
        return false

    # Moves what the child wrote since the last call into the buffers.
    # `block`: wait a little first when there is nothing yet.
    def _pump(self, block):
        var r = os_proc_read(self.pid)
        var got = len(r["stdout"]) + len(r["stderr"])
        if len(r["stdout"]) > 0:
            self._bufs["stdout"] = self._bufs["stdout"] + _as_bytes(r["stdout"])
        if len(r["stderr"]) > 0:
            self._bufs["stderr"] = self._bufs["stderr"] + _as_bytes(r["stderr"])
        if r["done"]:
            self._eof = true
            if self.returncode is none:
                self.returncode = os_poll(self.pid)
            return
        if block and got == 0:
            sleep_ms(2)

    def _write_input(self, raw):
        # In pieces, draining the child's output in between, so a child
        # that answers as it reads does not block on a full pipe.
        var n = len(raw)
        var i = 0
        var piece = 16384
        if n == 0:
            return
        while i < n:
            self._pump(false)
            try:
                os_proc_write(self.pid, raw[i:i + piece])
            except BrokenPipeError:
                return
            except OSError:
                return
            i = i + piece

    def _deliver_rest(self):
        # Output bound for files or (on Windows) the standard streams.
        var plan = self._plan
        if plan.out_forward and self._bufs["stdout"]:
            var o = self._bufs["stdout"]
            self._bufs["stdout"] = b""
            _deliver(plan.out_dest, _decode(o, self._encoding, "replace") if self.text_mode or plan.out_dest is none else o, self.text_mode)
        if plan.err_forward and self._bufs["stderr"]:
            var e = self._bufs["stderr"]
            self._bufs["stderr"] = b""
            _deliver(plan.err_dest, _decode(e, self._encoding, "replace") if self.text_mode or plan.err_dest == 2 else e, self.text_mode)
        if not plan.out_capture and not plan.out_forward:
            self._bufs["stdout"] = b""
        if not plan.err_capture and not plan.err_forward:
            self._bufs["stderr"] = b""

    def poll(self):
        """Check if child process has terminated. Set and return returncode
        attribute."""
        if self.returncode is none:
            var c = os_poll(self.pid)
            if c is not none:
                self.returncode = c
        if self.returncode is not none and not (self._plan.out_capture or self._plan.err_capture):
            self._pump(false)
            self._deliver_rest()
        return self.returncode

    def wait(self, timeout=none):
        """Wait for child process to terminate; returns self.returncode."""
        if self.returncode is none:
            try:
                if timeout is not none:
                    self.returncode = os_wait(self.pid, timeout=timeout)
                else:
                    self.returncode = os_wait(self.pid)
            except TimeoutError:
                raise TimeoutExpired(self.args, timeout)
        if not (self._plan.out_capture or self._plan.err_capture):
            self._pump(false)
            self._deliver_rest()
        return self.returncode

    def communicate(self, input=none, timeout=none):
        """Interact with process: Send data to stdin and close it.
        Read data from stdout and stderr, until end-of-file is
        reached.  Wait for process to terminate.

        The optional "input" argument should be data to be sent to the
        child process, or None, if no data should be sent to the child.
        communicate() returns a tuple (stdout, stderr).

        By default, all communication is in bytes, and therefore any
        "input" should be bytes, and the (stdout, stderr) will be bytes.
        If in text mode (indicated by self.text_mode), any "input" should
        be a string, and (stdout, stderr) will be strings decoded
        according to locale encoding, or by "encoding" if set. Text mode
        is triggered by setting any of text, encoding, errors or
        universal_newlines.
        """
        if self._communication_started and input:
            raise ValueError("Cannot send input after starting communication")
        var first = not self._communication_started
        self._communication_started = true
        if first and self.stdin is not none:
            if input:
                var raw = _encode_input(input, self.text_mode, self._encoding, self._errors)
                self._write_input(raw)
            self.stdin.close()
        var deadline = none
        if timeout is not none:
            deadline = monotonic() + timeout
        while not self._eof:
            if deadline is not none and monotonic() >= deadline:
                var po = self._bufs["stdout"] if self._plan.out_capture else none
                var pe = self._bufs["stderr"] if self._plan.err_capture else none
                raise TimeoutExpired(self.args, timeout,
                                     self.stdout._result(po) if po is not none else none,
                                     self.stderr._result(pe) if pe is not none else none)
            self._pump(true)
        self.wait()
        var out = none
        var err = none
        if self._plan.out_capture:
            out = self.stdout._result(self._bufs["stdout"])
            self._bufs["stdout"] = b""
            self.stdout.close()
        if self._plan.err_capture:
            err = self.stderr._result(self._bufs["stderr"])
            self._bufs["stderr"] = b""
            self.stderr.close()
        self._deliver_rest()
        return (out, err)

    def send_signal(self, sig):
        """Send a signal to the process."""
        self.poll()
        if self.returncode is not none:
            # Skip signalling a process that we know has already died.
            return
        os_kill(self.pid, sig)

    def terminate(self):
        """Terminate the process with SIGTERM
        """
        self.send_signal(15)

    def kill(self):
        """Kill the process with SIGKILL
        """
        self.send_signal(9)
