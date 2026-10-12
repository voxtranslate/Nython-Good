# nython: module    (import it by name: it runs in a module scope of its own)
# lib/getpass.ny - Python's getpass: portable password input.
#
#     getpass(prompt="Password: ", stream=None)   read a line without echo
#     getuser()                                   the user's login name
#     GetPassWarning
#
# getuser() checks LOGNAME, USER, LNAME and USERNAME, then asks the system
# (getpwuid on POSIX, as CPython's pwd lookup). An OSError is raised when
# nothing gives a name (CPython 3.13's behaviour; 3.12 raised KeyError).
#
# getpass(): on POSIX, when standard input is a terminal, echo is turned
# off with `stty -echo` around the read and the prompt goes to `stream`
# (sys.stderr by default; CPython writes to /dev/tty). Without a terminal,
# or on Windows (there is no msvcrt module here), it warns on stderr
# ("Warning: Password input may be echoed.", CPython's fallback_getpass)
# and reads the line normally. EOF raises EOFError; Ctrl+C at the prompt
# restores echo before KeyboardInterrupt propagates.

import os
import sys

__all__ = ["getpass", "getuser", "GetPassWarning"]

_WINDOWS = os_platform() == "windows"


class GetPassWarning(Exception):
    pass


def getuser():
    """Get the username from the environment or password database.

    First try various environment variables, then the password
    database.  This works on Windows as long as USERNAME is set.
    Any failure to find a username raises OSError.
    """
    for name in ["LOGNAME", "USER", "LNAME", "USERNAME"]:
        var user = os_getenv(name)
        if user:
            return user
    var u = os_username()
    if u:
        return u
    raise OSError("No username set in the environment")


def _write_prompt(prompt, stream):
    if stream is none:
        stream = sys.stderr
    stream.write(prompt)
    stream.flush()
    return stream


def _readline():
    var line = sys.stdin.readline()
    if not line:
        raise EOFError()
    if line[-1] == "\n":
        line = line[:-1]
    if line and line[-1] == "\r":
        line = line[:-1]
    return line


def fallback_getpass(prompt="Password: ", stream=none):
    if stream is none:
        stream = sys.stderr
    stream.write("Warning: Password input may be echoed.\n")
    _write_prompt(prompt, stream)
    return _readline()


def unix_getpass(prompt="Password: ", stream=none):
    """Prompt for a password, with echo turned off.

    Args:
      prompt: Written on stream to ask for the input.  Default: 'Password: '
      stream: A writable file object to display the prompt.  Defaults to
              sys.stderr.
    Returns:
      The seKr3t input.
    Raises:
      EOFError: If our input tty or stdin was closed.

    Always restores terminal settings before returning.
    """
    if not stream_isatty(0) or os_system("stty -echo 2>/dev/null") != 0:
        return fallback_getpass(prompt, stream)
    var out = _write_prompt(prompt, stream)
    var line = none
    try:
        line = _readline()
    finally:
        os_system("stty echo 2>/dev/null")
        out.write("\n")
        out.flush()
    return line


def win_getpass(prompt="Password: ", stream=none):
    """Prompt for password with echo off, using Windows getwch()."""
    return fallback_getpass(prompt, stream)


def getpass(prompt="Password: ", stream=none):
    """Prompt for a password, with echo turned off where the terminal
    allows it (see the module comment)."""
    if _WINDOWS:
        return win_getpass(prompt, stream)
    return unix_getpass(prompt, stream)
