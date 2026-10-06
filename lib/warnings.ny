# nython: module    (import it by name: it runs in a module scope of its own)
# lib/warnings.ny - Python's warnings: issue warning messages and control
# what happens to them (CPython's Lib/warnings.py).
#
#     import warnings
#     warnings.warn("old API", DeprecationWarning, stacklevel=2)
#     with warnings.catch_warnings(record=True) as w:
#         warnings.simplefilter("always")
#         f()
#     w[0].category, w[0].message, w[0].filename, w[0].lineno
#
# warn(message, category=None, stacklevel=1, source=None, *, skip_file_prefixes=())
#                           message: a string or a Warning instance; the
#                           location is the caller's (stacklevel 1) or a
#                           caller's caller's (2, 3 ...), from the running
#                           frames (sys._getframe); none that deep: "sys", 1
# warn_explicit(message, category, filename, lineno, module=None,
#               registry=None, module_globals=None, source=None)
# showwarning(message, category, filename, lineno, file=None, line=None)
#                           writes formatwarning(...) to file (sys.stderr);
#                           replace it (warnings.showwarning = f) to redirect
# formatwarning(message, category, filename, lineno, line=None)
#                           "file:line: Category: message\n  source line\n"
#                           (the line from linecache when not given);
#                           with source= and no tracemalloc, Python's
#                           "Category: Enable tracemalloc to get the object
#                           allocation traceback" line
# filterwarnings(action, message="", category=Warning, module="", lineno=0,
#                append=False)   message (case-insensitive) and module are
#                           regular expressions (lib/re.ny) matched at the
#                           start; inserted first unless append, a duplicate
#                           moved rather than added
# simplefilter(action, category=Warning, lineno=0, append=False)
# resetwarnings()           no filters at all
# filters                   [(action, message_re, category, module_re, lineno)],
#                           first match wins, else defaultaction ("default")
#                           - Python's defaults: default::DeprecationWarning:
#                           __main__, ignore::DeprecationWarning, ignore::
#                           PendingDeprecationWarning, ignore::ImportWarning,
#                           ignore::ResourceWarning
# actions                   "default" (once per location), "error" (raise
#                           it), "ignore", "always", "module" (once per
#                           module), "once" (once at all)
# catch_warnings(*, record=False, module=None, action=None, category=Warning,
#                lineno=0, append=False)   saves and restores the filters and
#                           showwarning; record=True gives the list of
#                           WarningMessage objects shown inside
# WarningMessage            .message .category .filename .lineno .file .line .source
# deprecated(message, /, *, category=DeprecationWarning, stacklevel=1)
#                           PEP 702 (Python 3.13): a decorator that makes a
#                           function, or a class's construction, warn on
#                           every use; sets __deprecated__
# PYTHONWARNINGS            processed at import as Python processes it and
#                           -W options ("action:message:category:module:lineno",
#                           comma-separated); sys.warnoptions too when the
#                           runtime has it
# Warning, UserWarning, DeprecationWarning, PendingDeprecationWarning,
# SyntaxWarning, RuntimeWarning, FutureWarning, ImportWarning,
# UnicodeWarning, BytesWarning, ResourceWarning, EncodingWarning are the
# builtin classes (include/NyExcTypes.hpp).
#
# "Once per location": the registry Python keeps in each module's globals
# as __warningregistry__ is kept here per module name (_registries); it is
# cleared whenever the filters change, as Python clears it. Not here: the
# registry as a variable of the warning's module, tracemalloc tracebacks
# for source=, the -W command-line option (the CLI has no -W; PYTHONWARNINGS
# works), and skipping importlib's frames for stacklevel (there are none).

import sys
import linecache
import warnings as _self   # this module's namespace: what callers rebind

__all__ = ["warn", "warn_explicit", "showwarning",
           "formatwarning", "filterwarnings", "simplefilter",
           "resetwarnings", "catch_warnings", "deprecated"]


def showwarning(message, category, filename, lineno, file=None, line=None):
    """Hook to write a warning to a file; replace if you like."""
    var msg = WarningMessage(message, category, filename, lineno, file, line)
    _showwarnmsg_impl(msg)


def formatwarning(message, category, filename, lineno, line=None):
    """Function to format a warning the standard way."""
    var msg = WarningMessage(message, category, filename, lineno, None, line)
    return _formatwarnmsg_impl(msg)


def _showwarnmsg_impl(msg):
    var file = msg.file
    if file is None:
        file = sys.stderr
        if file is None:
            # sys.stderr is None when run with pythonw.exe:
            # warnings get lost
            return
    var text = _formatwarnmsg(msg)
    try:
        file.write(text)
    except OSError:
        # the file (probably stderr) is invalid - this warning gets lost.
        pass


def _formatwarnmsg_impl(msg):
    var category = msg.category.__name__
    var s = str(msg.filename) + ":" + str(msg.lineno) + ": " + category + ": " + str(msg.message) + "\n"

    var line = None
    if msg.line is None:
        try:
            line = linecache.getline(msg.filename, msg.lineno)
        except Exception:
            # When a warning is logged during Python shutdown, linecache
            # and the import machinery don't work anymore
            line = None
    else:
        line = msg.line
    if line:
        line = line.strip()
        s += "  " + line + "\n"

    if msg.source is not None:
        # tracemalloc is not available: Python's message when it is not tracing
        s += category + ": Enable tracemalloc to get the object allocation traceback\n"
    return s


# Keep a reference to check if the function was replaced
_showwarning_orig = showwarning


def _showwarnmsg(msg):
    """Hook to write a warning to a file; replace if you like."""
    var sw = getattr(_self, "showwarning", _showwarning_orig)
    if sw is not _showwarning_orig:
        # warnings.showwarning() was replaced
        if not callable(sw):
            raise TypeError("warnings.showwarning() must be set to a function or method")
        sw(msg.message, msg.category, msg.filename, msg.lineno, msg.file, msg.line)
        return
    getattr(_self, "_showwarnmsg_impl", _showwarnmsg_impl)(msg)


# Keep a reference to check if the function was replaced
_formatwarning_orig = formatwarning


def _formatwarnmsg(msg):
    """Function to format a warning the standard way."""
    var fw = getattr(_self, "formatwarning", _formatwarning_orig)
    if fw is not _formatwarning_orig:
        # warnings.formatwarning() was replaced
        return fw(msg.message, msg.category, msg.filename, msg.lineno, msg.line)
    return _formatwarnmsg_impl(msg)


_ACTIONS = ["error", "ignore", "always", "default", "module", "once"]


def _is_class(x):
    return isinstance(x, type)


def filterwarnings(action, message="", category=Warning, module="", lineno=0,
                   append=False):
    """Insert an entry into the list of warnings filters (at the front).

    'action' -- one of "error", "ignore", "always", "default", "module",
                or "once"
    'message' -- a regex that the warning message must match
    'category' -- a class that the warning must be a subclass of
    'module' -- a regex that the module name must match
    'lineno' -- an integer line number, 0 matches all warnings
    'append' -- if true, append to the list of filters
    """
    assert action in _ACTIONS, "invalid action: " + repr(action)
    assert isinstance(message, str), "message must be a string"
    assert _is_class(category), "category must be a class"
    assert issubclass(category, Warning), "category must be a Warning subclass"
    assert isinstance(module, str), "module must be a string"
    assert isinstance(lineno, int) and lineno >= 0, "lineno must be an int >= 0"

    var mre = None
    var modre = None
    if message or module:
        import re
        if message:
            mre = re.compile(message, re.I)
        if module:
            modre = re.compile(module)
    _add_filter(action, mre, category, modre, lineno, append=append)


def simplefilter(action, category=Warning, lineno=0, append=False):
    """Insert a simple entry into the list of warnings filters (at the front).

    A simple filter matches all modules and messages.
    'action' -- one of "error", "ignore", "always", "default", "module",
                or "once"
    'category' -- a class that the warning must be a subclass of
    'lineno' -- an integer line number, 0 matches all warnings
    'append' -- if true, append to the list of filters
    """
    assert action in _ACTIONS, "invalid action: " + repr(action)
    assert isinstance(lineno, int) and lineno >= 0, "lineno must be an int >= 0"
    _add_filter(action, None, category, None, lineno, append=append)


def _filter_list():
    return getattr(_self, "filters", filters)


def _same_filter(a, b):
    # filters compare as tuples; a compiled pattern equals one compiled
    # from the same text with the same flags (as Python's re.Pattern)
    if a[0] != b[0] or a[2] is not b[2] or a[4] != b[4]:
        return False
    for i in [1, 3]:
        var x = a[i]
        var y = b[i]
        if x is None or y is None:
            if not (x is None and y is None):
                return False
        elif x is not y:
            if getattr(x, "pattern", None) != getattr(y, "pattern", None) or getattr(x, "flags", None) != getattr(y, "flags", None):
                return False
    return True


def _add_filter(action, message, category, module, lineno, append=False):
    # Remove possible duplicate filters, so new one will be placed
    # in correct place. If append=True and duplicate exists, do nothing.
    var item = (action, message, category, module, lineno)
    var fl = _filter_list()
    var i = 0
    var found = -1
    while i < len(fl):
        if _same_filter(fl[i], item):
            found = i
            break
        i += 1
    if not append:
        if found >= 0:
            fl.pop(found)
        fl.insert(0, item)
    else:
        if found < 0:
            fl.append(item)
    _filters_mutated()


def resetwarnings():
    """Clear the list of warning filters, so that no filters are active."""
    var fl = _filter_list()
    fl[:] = []
    _filters_mutated()


class _OptionError(Exception):
    """Exception used by option processing helpers."""
    pass


# Helper to process -W options passed via sys.warnoptions
def _processoptions(args):
    for arg in args:
        try:
            _setoption(arg)
        except _OptionError as msg:
            sys.stderr.write("Invalid -W option ignored: " + str(msg) + "\n")


# Helper for _processoptions()
def _setoption(arg):
    var parts = arg.split(":")
    if len(parts) > 5:
        raise _OptionError("too many fields (max 5): " + repr(arg))
    while len(parts) < 5:
        parts.append("")
    var fields = [s.strip() for s in parts]
    var action = _getaction(fields[0])
    var message = fields[1]
    var category = _getcategory(fields[2])
    var module = fields[3]
    var lineno = fields[4]
    if message or module:
        import re
        if message:
            message = re.escape(message)
        if module:
            module = re.escape(module) + "\\Z"
    if lineno:
        var ok = True
        try:
            lineno = int(lineno)
            if lineno < 0:
                ok = False
        except (ValueError, OverflowError):
            ok = False
        if not ok:
            raise _OptionError("invalid lineno " + repr(lineno))
    else:
        lineno = 0
    filterwarnings(action, message, category, module, lineno)


# Helper for _setoption()
def _getaction(action):
    if not action:
        return "default"
    if action == "all":
        return "always"   # Alias
    for a in ["default", "always", "ignore", "module", "once", "error"]:
        if a.startswith(action):
            return a
    raise _OptionError("invalid action: " + repr(action))


_BUILTIN_CATEGORIES = {
    "Warning": Warning, "UserWarning": UserWarning,
    "DeprecationWarning": DeprecationWarning,
    "PendingDeprecationWarning": PendingDeprecationWarning,
    "SyntaxWarning": SyntaxWarning, "RuntimeWarning": RuntimeWarning,
    "FutureWarning": FutureWarning, "ImportWarning": ImportWarning,
    "UnicodeWarning": UnicodeWarning, "BytesWarning": BytesWarning,
    "ResourceWarning": ResourceWarning, "EncodingWarning": EncodingWarning,
}


# Helper for _setoption()
def _getcategory(category):
    if not category:
        return Warning
    if "." not in category:
        if category in _BUILTIN_CATEGORIES:
            return _BUILTIN_CATEGORIES[category]
        if category in ("Exception", "BaseException", "ValueError", "TypeError", "RuntimeError"):
            raise _OptionError("invalid warning category: " + repr(category))
        raise _OptionError("unknown warning category: " + repr(category))
    var cut = category.rfind(".")
    var modname = category[:cut]
    var klass = category[cut + 1:]
    var cat = None
    try:
        var m = __import__(modname)
        cat = getattr(m, klass)
    except ImportError:
        raise _OptionError("invalid module name: " + repr(modname)) from None
    except AttributeError:
        raise _OptionError("unknown warning category: " + repr(category)) from None
    except Exception:
        raise _OptionError("invalid module name: " + repr(modname)) from None
    if not (_is_class(cat) and issubclass(cat, Warning)):
        raise _OptionError("invalid warning category: " + repr(category))
    return cat


# Code typically replaced by _warnings

def warn(message, category=None, stacklevel=1, source=None, *, skip_file_prefixes=()):
    """Issue a warning, or maybe ignore it or raise an exception."""
    # Check if message is already a Warning object
    if isinstance(message, Warning):
        category = message.__class__
    # Check category argument
    if category is None:
        category = UserWarning
    if not (_is_class(category) and issubclass(category, Warning)):
        raise TypeError("category must be a Warning subclass, not '" + _tname(category) + "'")
    if not isinstance(skip_file_prefixes, tuple):
        # The C version demands a tuple for implementation performance.
        raise TypeError("skip_file_prefixes must be a tuple of strs.")
    if skip_file_prefixes:
        stacklevel = max(2, stacklevel)
    # Get context information: the running frames, innermost first, as
    # (filename, lineno, function, module); index 0 is this function's own
    var st = _ny_stack()
    var level = stacklevel if stacklevel >= 1 else 1
    var i = level
    if skip_file_prefixes and level > 1:
        # the caller, then level - 1 frames further out, not counting the
        # frames of the files named (3.12)
        i = 1
        var n = 1
        while n < level:
            i += 1
            while i < len(st) and _starts_with_any(st[i][0], skip_file_prefixes):
                i += 1
            n += 1
    var filename = "sys"
    var lineno = 1
    var module = "sys"
    if i < len(st):
        filename = st[i][0]
        lineno = st[i][1]
        module = st[i][3]
    var registry = _registries.get(module)
    if registry is None:
        registry = {}
        _registries[module] = registry
    warn_explicit(message, category, filename, lineno, module, registry,
                  None, source)


def _starts_with_any(s, prefixes):
    for p in prefixes:
        if s.startswith(p):
            return True
    return False


def _tname(x):
    if x is None:
        return "NoneType"
    return type(x).__name__


def warn_explicit(message, category, filename, lineno,
                  module=None, registry=None, module_globals=None,
                  source=None):
    lineno = int(lineno)
    if module is None:
        module = filename or "<unknown>"
        if module[-3:].lower() == ".py" or module[-3:].lower() == ".ny":
            module = module[:-3]   # XXX What about leading pathname?
    if registry is None:
        registry = {}
    if registry.get("version", 0) != _version():
        registry.clear()
        registry["version"] = _version()
    var text = None
    if isinstance(message, Warning):
        text = str(message)
        category = message.__class__
    else:
        text = message
        message = category(message)
    var key = (text, category, lineno)
    # Quick test for common case
    if registry.get(key):
        return
    # Search the filters
    var action = None
    var item = None
    for it in _filter_list():
        var msg = it[1]
        var cat = it[2]
        var mod = it[3]
        var ln = it[4]
        if ((msg is None or _matches(msg, text)) and
            issubclass(category, cat) and
            (mod is None or _matches(mod, module)) and
            (ln == 0 or lineno == ln)):
            action = it[0]
            item = it
            break
    if action is None:
        action = getattr(_self, "defaultaction", defaultaction)
    # Early exit actions
    if action == "ignore":
        return

    # Prime the linecache for formatting, in case the
    # "file" is actually in a zipfile or something.
    linecache.getlines(filename, module_globals)

    if action == "error":
        raise message
    # Other actions
    if action == "once":
        registry[key] = True
        var oncekey = (text, category)
        var once = getattr(_self, "onceregistry", onceregistry)
        if once.get(oncekey):
            return
        once[oncekey] = True
    elif action == "always":
        pass
    elif action == "module":
        registry[key] = True
        var altkey = (text, category, 0)
        if registry.get(altkey):
            return
        registry[altkey] = True
    elif action == "default":
        registry[key] = True
    else:
        # Unrecognized actions are errors
        raise RuntimeError("Unrecognized action (" + repr(action) + ") in warnings.filters:\n " + repr(item))
    # Print message and context
    var wm = WarningMessage(message, category, filename, lineno, source=source)
    _showwarnmsg(wm)


def _matches(pat, s):
    # a compiled pattern (filterwarnings) or the exact text (Python's own
    # default filter for __main__)
    if isinstance(pat, str):
        return pat == s
    return pat.match(s) is not None


class WarningMessage:

    _WARNING_DETAILS = ("message", "category", "filename", "lineno", "file",
                        "line", "source")

    def __init__(self, message, category, filename, lineno, file=None,
                 line=None, source=None):
        self.message = message
        self.category = category
        self.filename = filename
        self.lineno = lineno
        self.file = file
        self.line = line
        self.source = source
        self._category_name = category.__name__ if category else None

    def __str__(self):
        return ("{message : " + _repr(self.message) + ", category : " + _repr(self._category_name) +
                ", filename : " + _repr(self.filename) + ", lineno : " + str(self.lineno) +
                ", line : " + _repr(self.line) + "}")


def _repr(x):
    # repr() as Python spells None
    if x is None:
        return "None"
    return repr(x)


class catch_warnings:

    """A context manager that copies and restores the warnings filter upon
    exiting the context.

    The 'record' argument specifies whether warnings should be captured by a
    custom implementation of warnings.showwarning() and be appended to a list
    returned by the context manager. Otherwise None is returned by the context
    manager. The objects appended to the list are arguments whose attributes
    mirror the arguments to showwarning().

    The 'module' argument is to specify an alternative module to the module
    named 'warnings' and imported under that name. This argument is only useful
    when testing the warnings module itself.

    If the 'action' argument is not None, the remaining arguments are passed
    to warnings.simplefilter() as if it were called immediately on entering the
    context.
    """

    def __init__(self, *, record=False, module=None,
                 action=None, category=Warning, lineno=0, append=False):
        """Specify whether to record warnings and if an alternative module
        should be used other than sys.modules['warnings'].

        For compatibility with Python 3.0, please consider all arguments to be
        keyword-only.

        """
        self._record = record
        self._module = _self if module is None else module
        self._entered = False
        if action is None:
            self._filter = None
        else:
            self._filter = (action, category, lineno, append)

    def __repr__(self):
        var args = []
        if self._record:
            args.append("record=True")
        if self._module is not _self:
            args.append("module=" + repr(self._module))
        var name = type(self).__name__
        return name + "(" + ", ".join(args) + ")"

    def __enter__(self):
        if self._entered:
            raise RuntimeError("Cannot enter " + repr(self) + " twice")
        self._entered = True
        # The list object itself stays (the module's functions hold it); its
        # contents are saved and put back.
        self._filters = getattr(self._module, "filters", filters)
        self._saved_filters = self._filters[:]
        self._module._filters_mutated()
        self._showwarning = self._module.showwarning
        self._showwarnmsg_impl = self._module._showwarnmsg_impl
        if self._filter is not None:
            var f = self._filter
            self._module.simplefilter(f[0], f[1], f[2], f[3])
        if self._record:
            var log = []
            self._module._showwarnmsg_impl = log.append
            # Reset showwarning() to the default implementation to make sure
            # that _showwarnmsg() calls _showwarnmsg_impl()
            self._module.showwarning = self._module._showwarning_orig
            return log
        return None

    def __exit__(self, *exc_info):
        if not self._entered:
            raise RuntimeError("Cannot exit " + repr(self) + " without entering first")
        self._filters[:] = self._saved_filters
        self._module._filters_mutated()
        self._module.showwarning = self._showwarning
        self._module._showwarnmsg_impl = self._showwarnmsg_impl
        return False


class deprecated:
    """Indicate that a class, function or overload is deprecated (PEP 702,
    Python 3.13).

    When this decorator is applied to an object, the type checker
    will generate a diagnostic on usage of the deprecated object.

    Usage:

        @deprecated("Use B instead")
        class A:
            pass

        @deprecated("Use g instead")
        def f():
            pass

    The warning specified by *category* will be emitted at runtime
    on use of deprecated objects. For functions, that happens on calls;
    for classes, on instantiation and on creation of subclasses.
    If the *category* is ``None``, no warning is emitted at runtime.
    The *stacklevel* determines where the
    warning is emitted. If it is ``1`` (the default), the warning
    is emitted at the direct caller of the deprecated object; if it
    is higher, it is emitted further up the stack.
    The deprecation message passed to the decorator is saved in the
    ``__deprecated__`` attribute on the decorated object.
    """

    def __init__(self, message, *, category=DeprecationWarning, stacklevel=1):
        if not isinstance(message, str):
            raise TypeError("Expected an object of type str for 'message', not " + repr(_tname(message)))
        self.message = message
        self.category = category
        self.stacklevel = stacklevel

    def __call__(self, arg):
        var msg = self.message
        var category = self.category
        var stacklevel = self.stacklevel
        if category is None:
            arg.__deprecated__ = msg
            return arg
        if _is_class(arg):
            # instantiating it warns: a subclass made here whose __init__
            # (or __new__) warns first, standing in for the class
            var original_init = getattr(arg, "__init__", None)

            def wrapped_init(self, *args, **kwargs):
                if type(self) is arg:
                    warn(msg, category=category, stacklevel=stacklevel + 1)
                if original_init is not None:
                    return original_init(self, *args, **kwargs)
                return None

            arg.__init__ = wrapped_init
            arg.__deprecated__ = msg
            return arg
        if callable(arg):
            def wrapper(*args, **kwargs):
                warn(msg, category=category, stacklevel=stacklevel + 1)
                return arg(*args, **kwargs)

            for name in ("__module__", "__name__", "__qualname__", "__doc__"):
                if hasattr(arg, name):
                    try:
                        setattr(wrapper, name, getattr(arg, name))
                    except Exception:
                        pass
            wrapper.__wrapped__ = arg
            wrapper.__deprecated__ = msg
            arg.__deprecated__ = msg
            return wrapper
        raise TypeError("@deprecated decorator with non-None category must be applied to " +
                        "a class or callable, not " + repr(arg))


# Private utility function called by _PyErr_WarnUnawaitedCoroutine
def _warn_unawaited_coroutine(coro):
    var msg = "coroutine '" + str(getattr(coro, "__qualname__", coro)) + "' was never awaited"
    warn(msg, category=RuntimeWarning, stacklevel=2, source=coro)


# filters is a list of tuples of the form (action, message, category,
# module, lineno); the message and module of Python's own defaults: None or
# the exact text "__main__" (as the C implementation keeps it)
filters = []
defaultaction = "default"
onceregistry = {}
_registries = {}
_filters_version = [1]


def _version():
    return _filters_version[0]


def _filters_mutated():
    _filters_version[0] = _filters_version[0] + 1


_warnings_defaults = False
# Python's default filters (a release build)
filters.append(("default", None, DeprecationWarning, "__main__", 0))
filters.append(("ignore", None, DeprecationWarning, None, 0))
filters.append(("ignore", None, PendingDeprecationWarning, None, 0))
filters.append(("ignore", None, ImportWarning, None, 0))
filters.append(("ignore", None, ResourceWarning, None, 0))

# -W options and PYTHONWARNINGS, as Python processes them at startup
def _startup_options():
    var opts = []
    var env = None
    try:
        env = os_getenv("PYTHONWARNINGS")
    except Exception:
        env = None
    if env:
        for part in env.split(","):
            if part.strip():
                opts.append(part.strip())
    for o in getattr(sys, "warnoptions", []):
        opts.append(o)
    return opts


def _init_options():
    # filterwarnings works on the module's own list while the namespace is
    # not yet built
    var opts = _startup_options()
    for arg in opts:
        try:
            _setoption(arg)
        except _OptionError as msg:
            sys.stderr.write("Invalid -W option ignored: " + str(msg) + "\n")
        except Exception as e:
            sys.stderr.write("Invalid -W option ignored: " + str(e) + "\n")

_init_options()
