# nython: module    (import it by name: it runs in a module scope of its own)
# lib/readline.ny - Python's readline module (round 83), over the line
# editor of Nython's own interactive prompt (NythonREPL.hpp's
# MultilineEditor) rather than over GNU readline or libedit.
#
#     import readline, rlcompleter
#     readline.parse_and_bind("tab: complete")
#     readline.set_completer(rlcompleter.Completer(namespace).complete)
#     readline.read_history_file(path); readline.set_history_length(1000)
#     import atexit; atexit.register(readline.write_history_file, path)
#
# The history is the prompt's own (Up/Down walk the same list):
# add_history, get_history_item(index) (1-based; None when out of range),
# remove_history_item(pos), replace_history_item(pos, line) (0-based),
# clear_history, get_current_history_length, get/set_history_length (the
# files are cut to it), read_history_file / write_history_file /
# append_history_file (GNU readline's format, one entry a line, ~/.history by
# default), set_auto_history. Completion: set_completer(function) - Tab at
# the prompt calls function(text, state) for state 0, 1, 2, ... until it
# returns None and completes the common prefix (a second Tab lists the
# candidates) - get_completer, get_completer_delims / set_completer_delims,
# get_begidx / get_endidx / get_line_buffer (what is being completed),
# get_completion_type, set_completion_display_matches_hook,
# set_startup_hook / set_pre_input_hook (kept and checked; the editor does
# not call them), insert_text (the text starts the next prompt line),
# redisplay, parse_and_bind / read_init_file (the bindings
# Nython's editor has are fixed: "tab: complete" and the like are accepted),
# backend ("nython"), _READLINE_VERSION/_READLINE_RUNTIME_VERSION/
# _READLINE_LIBRARY_VERSION (those of GNU readline 8.2 it imitates).
#
# Not here: key bindings other than the editor's own (Emacs-style: Ctrl+A/E/
# K/U/W/L, arrows, Tab), vi mode, the display-matches hook's effect (it is
# kept and returned, the editor lists candidates itself). Without a terminal
# (a pipe), the prompt reads plain lines and nothing is completed.
import os as _os

__all__ = ["add_history", "append_history_file", "clear_history", "get_begidx", "get_completer",
           "get_completer_delims", "get_completion_type", "get_current_history_length", "get_endidx",
           "get_history_item", "get_history_length", "get_line_buffer", "insert_text", "parse_and_bind",
           "read_history_file", "read_init_file", "redisplay", "remove_history_item", "replace_history_item",
           "set_auto_history", "set_completer", "set_completer_delims", "set_completion_display_matches_hook",
           "set_history_length", "set_pre_input_hook", "set_startup_hook", "write_history_file"]

backend = "nython"
_READLINE_VERSION = 0x0802
_READLINE_RUNTIME_VERSION = 0x0802
_READLINE_LIBRARY_VERSION = "8.2"

_state = {"completer": None, "history_length": -1, "startup_hook": None, "pre_input_hook": None,
          "display_hook": None, "bindings": []}


def _path(filename):
    if filename is None:
        return _os.path.expanduser("~/.history")
    return _os.fspath(filename) if not isinstance(filename, str) else filename


def parse_and_bind(string, /):
    """Execute the init line provided in the string argument."""
    if not isinstance(string, str):
        raise TypeError("parse_and_bind() argument must be str, not " + type(string).__name__)
    _state["bindings"].append(string)


def read_init_file(filename=None, /):
    """Execute a readline initialization file."""
    var p = _path(filename) if filename is not None else _os.environ.get("INPUTRC", _os.path.expanduser("~/.inputrc"))
    with open(p) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                parse_and_bind(line)


def get_line_buffer():
    """Return the current contents of the line buffer."""
    return _rl_state()[0]


def insert_text(string, /):
    """Insert text into the line buffer at the cursor position."""
    _rl_insert_text(string)


def redisplay():
    """Change what's displayed on the screen to reflect contents of the line buffer."""
    pass


def read_history_file(filename=None, /):
    """Load a readline history file. The default filename is ~/.history."""
    _rl_read_history(_path(filename))


def write_history_file(filename=None, /):
    """Save a readline history file. The default filename is ~/.history."""
    _rl_write_history(_path(filename), _state["history_length"])


def append_history_file(nelements, filename=None, /):
    """Append the last nelements items of the history list to file."""
    _rl_append_history(nelements, _path(filename), _state["history_length"])


def get_history_length():
    """Return the maximum number of lines that will be written to the history file."""
    return _state["history_length"]


def set_history_length(length, /):
    """Set the maximal number of lines which will be written to the history file.
    A negative length is used to inhibit history truncation."""
    if not isinstance(length, int):
        raise TypeError("'" + type(length).__name__ + "' object cannot be interpreted as an integer")
    _state["history_length"] = length


def clear_history():
    """Clear the current readline history."""
    _rl_clear_history()


def get_current_history_length():
    """Return the current (not the maximum) length of history."""
    return _rl_history_len()


def get_history_item(index, /):
    """Return the current contents of history item at one-based index."""
    return _rl_get_history_item(index)


def remove_history_item(pos, /):
    """Remove history item given by its zero-based position."""
    _rl_remove_history_item(pos)


def replace_history_item(pos, line, /):
    """Replaces history item given by its position with contents of line."""
    _rl_replace_history_item(pos, line)


def add_history(string, /):
    """Add an item to the history buffer."""
    if not isinstance(string, str):
        raise TypeError("add_history() argument must be str, not " + type(string).__name__)
    _rl_add_history(string)


def set_auto_history(enabled, /):
    """Enables or disables automatic history."""
    _rl_set_auto_history(bool(enabled))


def set_completer(function=None, /):
    """Set or remove the completer function."""
    if function is not None and not callable(function):
        raise TypeError("set_completer(func): argument not callable")
    _state["completer"] = function


def get_completer():
    """Get the current completer function."""
    return _state["completer"]


def get_completion_type():
    """Get the type of completion being attempted."""
    return 9    # ord("\t"): plain completion


def get_begidx():
    """Get the beginning index of the completion scope."""
    return _rl_state()[1]


def get_endidx():
    """Get the ending index of the completion scope."""
    return _rl_state()[2]


def set_completer_delims(string, /):
    """Set the word delimiters for completion."""
    _rl_set_delims(string)


def get_completer_delims():
    """Get the word delimiters for completion."""
    return _rl_get_delims()


def set_completion_display_matches_hook(function=None, /):
    """Set or remove the completion display function."""
    if function is not None and not callable(function):
        raise TypeError("set_completion_display_matches_hook(func): argument not callable")
    _state["display_hook"] = function


def set_startup_hook(function=None, /):
    """Set or remove the function invoked by the rl_startup_hook callback."""
    if function is not None and not callable(function):
        raise TypeError("set_startup_hook(func): argument not callable")
    _state["startup_hook"] = function


def set_pre_input_hook(function=None, /):
    """Set or remove the function invoked by the rl_pre_input_hook callback."""
    if function is not None and not callable(function):
        raise TypeError("set_pre_input_hook(func): argument not callable")
    _state["pre_input_hook"] = function


def _ny_complete(text, line, begidx, endidx):
    # Tab at the prompt (src/main.cpp): the completer's candidates for text;
    # an exception in the completer is ignored, as GNU readline's binding does
    var f = _state["completer"]
    if f is None:
        return None
    var out = []
    var state = 0
    try:
        while state < 1000:
            var c = f(text, state)
            if c is None:
                break
            out.append(str(c))
            state += 1
    except Exception:
        pass
    return out
