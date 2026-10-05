# nython: module    (import it by name: it runs in a module scope of its own)
# lib/logging.ny - Python's logging: a flexible event logging system.
#
#     getLogger(name=None) - loggers form a hierarchy by dotted names under
#         the root logger; Logger.setLevel/getEffectiveLevel/isEnabledFor,
#         debug/info/warning/warn/error/exception/critical/fatal/log,
#         addHandler/removeHandler/hasHandlers, propagate, disabled,
#         addFilter/removeFilter, getChild, getChildren
#     Levels CRITICAL FATAL ERROR WARNING WARN INFO DEBUG NOTSET,
#         getLevelName, addLevelName, getLevelNamesMapping
#     Handler, StreamHandler (sys.stderr by default), FileHandler (mode,
#         encoding, delay), NullHandler, lastResort
#     Formatter (styles "%", "{", "$"; datefmt; defaults=; validate=),
#         BufferingFormatter, Filter, Filterer, LogRecord, LoggerAdapter,
#         makeLogRecord, setLogRecordFactory/getLogRecordFactory,
#         setLoggerClass/getLoggerClass, Manager, PlaceHolder, RootLogger
#     basicConfig(level, format, datefmt, style, filename, filemode, stream,
#         handlers, force, encoding, errors), shutdown, disable,
#         captureWarnings, getHandlerByName, getHandlerNames
#     module-level debug/info/warning/warn/error/exception/critical/fatal/log
#
# CPython 3.12's logging/__init__.py, followed closely: the PlaceHolder
# fix-ups that let "a.b" be created before "a", the per-logger level cache
# that makes a disabled call cost one dict lookup, lastResort (WARNING and
# above to stderr when no handler is found anywhere up the hierarchy), the
# handleError report, and one module RLock (lib/threading.ny) plus one per
# handler, so threads can log concurrently.
#
# LogRecord carries every standard attribute: name, msg, args, levelname,
# levelno, pathname, filename, module, exc_info, exc_text, stack_info,
# lineno, funcName, created, msecs, relativeCreated, thread, threadName,
# processName, process, taskName, message, asctime.
#
# Differences from CPython (Nython has no frame objects):
#   - pathname/filename/module/lineno/funcName are CPython's values for an
#     unknown caller: "(unknown file)", "(unknown file)", "(unknown file)",
#     0 and "(unknown function)"; stack_info=True records "Stack (most
#     recent call last):" with no frames.
#   - exc_info=True / exception() take the exception being handled from
#     the runtime (_ny_exc_current, the equivalent of sys.exc_info()), and
#     its text is "Traceback (most recent call last):" followed by the
#     exception line ("ValueError: boom") - there are no frame lines.
#   - captureWarnings() is accepted and does nothing (no warnings module).

import os
import sys
import threading

__all__ = ["BASIC_FORMAT", "BufferingFormatter", "CRITICAL", "DEBUG", "ERROR",
           "FATAL", "FileHandler", "Filter", "Formatter", "Handler", "INFO",
           "LogRecord", "Logger", "LoggerAdapter", "NOTSET", "NullHandler",
           "StreamHandler", "WARN", "WARNING", "addLevelName", "basicConfig",
           "captureWarnings", "critical", "debug", "disable", "error",
           "exception", "fatal", "getLevelName", "getLogger", "getLoggerClass",
           "info", "log", "makeLogRecord", "setLoggerClass", "shutdown",
           "warn", "warning", "getLogRecordFactory", "setLogRecordFactory",
           "lastResort", "raiseExceptions", "getLevelNamesMapping",
           "getHandlerByName", "getHandlerNames"]

__author__ = "Vinay Sajip <vinay_sajip@red-dove.com>"
__status__ = "production"
__version__ = "0.5.1.2"
__date__ = "07 February 2010"

_startTime = time_ns()

# raiseExceptions is used to see if exceptions during handling should be
# propagated
raiseExceptions = true

# If you don't want threading information in the log, set this to False
logThreads = true

# If you don't want multiprocessing information in the log, set this to False
logMultiprocessing = true

# If you don't want process information in the log, set this to False
logProcesses = true

# If you don't want asyncio task information in the log, set this to False
logAsyncioTasks = true

CRITICAL = 50
FATAL = CRITICAL
ERROR = 40
WARNING = 30
WARN = WARNING
INFO = 20
DEBUG = 10
NOTSET = 0

_levelToName = {
    CRITICAL: "CRITICAL",
    ERROR: "ERROR",
    WARNING: "WARNING",
    INFO: "INFO",
    DEBUG: "DEBUG",
    NOTSET: "NOTSET",
}
_nameToLevel = {
    "CRITICAL": CRITICAL,
    "FATAL": FATAL,
    "ERROR": ERROR,
    "WARN": WARNING,
    "WARNING": WARNING,
    "INFO": INFO,
    "DEBUG": DEBUG,
    "NOTSET": NOTSET,
}


def getLevelNamesMapping():
    return dict(_nameToLevel)


def getLevelName(level):
    """
    Return the textual or numeric representation of logging level 'level'.

    If the level is one of the predefined levels (CRITICAL, ERROR, WARNING,
    INFO, DEBUG) then you get the corresponding string. If you have
    associated levels with names using addLevelName then the name you have
    associated with 'level' is returned.

    If a numeric value corresponding to one of the defined levels is passed
    in, the corresponding string representation is returned.

    If a string representation of the level is passed in, the corresponding
    numeric value is returned.

    If no matching numeric or string value is passed in, the string
    'Level %s' % level is returned.
    """
    if isinstance(level, int) and not isinstance(level, bool) and level in _levelToName:
        return _levelToName[level]
    if isinstance(level, str) and level in _nameToLevel:
        return _nameToLevel[level]
    return "Level " + str(level)


def addLevelName(level, levelName):
    """
    Associate 'levelName' with 'level'.

    This is used when converting levels to text during message formatting.
    """
    _acquireLock()
    try:
        _levelToName[level] = levelName
        _nameToLevel[levelName] = level
    finally:
        _releaseLock()


def _checkLevel(level):
    if isinstance(level, int) and not isinstance(level, bool):
        return level
    if isinstance(level, bool):
        return int(level)
    if str(level) == level:
        if level not in _nameToLevel:
            raise ValueError("Unknown level: " + repr(level))
        return _nameToLevel[level]
    raise TypeError("Level not an integer or a valid string: " + repr(level))


# _lock is used to serialize access to shared data structures in this module.
# This needs to be an RLock because fileConfig() creates and configures
# Handlers, and so might arbitrary user threads. Since Handler code updates the
# shared dictionary _handlers, it needs to acquire the lock. But if configuring,
# the lock would already have been acquired - so we need an RLock.
_lock = threading.RLock()


def _acquireLock():
    """
    Acquire the module-level lock for serializing access to shared data.

    This should be released with _releaseLock().
    """
    if _lock:
        _lock.acquire()


def _releaseLock():
    """
    Release the module-level lock acquired by calling _acquireLock().
    """
    if _lock:
        _lock.release()


# ── LogRecord ────────────────────────────────────────────────────────────────

def _basename(p):
    var i = max(p.rfind("/"), p.rfind("\\"))
    return p[i + 1:]


def _splitext0(p):
    var i = p.rfind(".")
    if i <= 0:
        return p
    return p[:i]


class LogRecord:
    """
    A LogRecord instance represents an event being logged.

    LogRecord instances are created every time something is logged. They
    contain all the information pertinent to the event being logged. The
    main information passed in is in msg and args, which are combined
    using str(msg) % args to create the message field of the record. The
    record also includes information such as when the record was created,
    the source line where the logging call was made, and any exception
    information to be logged.
    """
    def __init__(self, name, level, pathname, lineno, msg, args, exc_info,
                 func=none, sinfo=none, **kwargs):
        """
        Initialize a logging record with interesting information.
        """
        var ct = time_ns()
        self.name = name
        self.msg = msg
        if args and len(args) == 1 and isinstance(args[0], dict) and args[0]:
            args = args[0]
        self.args = args
        self.levelname = getLevelName(level)
        self.levelno = level
        self.pathname = pathname
        self.filename = pathname
        self.module = "Unknown module"
        if isinstance(pathname, str):
            self.filename = _basename(pathname)
            self.module = _splitext0(self.filename)
        self.exc_info = exc_info
        self.exc_text = none      # used to cache the traceback text
        self.stack_info = sinfo
        self.lineno = lineno
        self.funcName = func
        self.created = ct / 1e9  # ns to float seconds
        # Get the number of whole milliseconds (0-999) in the fractional part of seconds.
        self.msecs = (ct % 1000000000) // 1000000 + 0.0
        self.relativeCreated = (ct - _startTime) / 1e6
        if logThreads:
            self.thread = threading.get_ident()
            self.threadName = threading.current_thread().name
        else:
            self.thread = none
            self.threadName = none
        if not logMultiprocessing:
            self.processName = none
        else:
            self.processName = "MainProcess"
        if logProcesses:
            self.process = os_getpid()
        else:
            self.process = none
        self.taskName = none

    def __repr__(self):
        return "<LogRecord: " + str(self.name) + ", " + str(self.levelno) + ", " + str(self.pathname) + ", " + str(self.lineno) + ", \"" + str(self.msg) + "\">"

    def getMessage(self):
        """
        Return the message for this LogRecord.

        Return the message for this LogRecord after merging any user-supplied
        arguments with the message.
        """
        var msg = str(self.msg)
        if self.args:
            msg = msg % self.args
        return msg


_logRecordFactory = LogRecord


def setLogRecordFactory(factory):
    """
    Set the factory to be used when instantiating a log record.

    :param factory: A callable which will be called to instantiate
    a log record.
    """
    global _logRecordFactory
    _logRecordFactory = factory


def getLogRecordFactory():
    """
    Return the factory to be used when instantiating a log record.
    """
    return _logRecordFactory


def makeLogRecord(dict):
    """
    Make a LogRecord whose attributes are defined by the specified dictionary,
    This function is useful for converting a logging event received over
    a socket connection (which is sent as a dictionary) into a LogRecord
    instance.
    """
    var rv = _logRecordFactory(none, none, "", 0, "", (), none, none)
    for k in dict:
        setattr(rv, k, dict[k])
    return rv


# ── Formatter styles ─────────────────────────────────────────────────────────

def _record_values(record, defaults):
    var values = {}
    if defaults:
        for k in defaults:
            values[k] = defaults[k]
    var d = record.__dict__
    for k in d:
        values[k] = d[k]
    return values


def _is_ident_start(c):
    return c == "_" or ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or ord(c) > 127


def _is_ident_char(c):
    return _is_ident_start(c) or ("0" <= c and c <= "9")


class PercentStyle:
    default_format = "%(message)s"
    asctime_format = "%(asctime)s"
    asctime_search = "%(asctime)"

    def __init__(self, fmt, defaults=none):
        self._fmt = fmt or self.default_format
        self._defaults = defaults

    def usesTime(self):
        return self._fmt.find(self.asctime_search) >= 0

    def _fields(self):
        # names in %(name)<flags><width><.prec><conv>, as CPython's
        # validation_pattern finds them
        var out = []
        var s = self._fmt
        var i = s.find("%(")
        while i >= 0:
            var j = s.find(")", i + 2)
            if j < 0:
                break
            var name = s[i + 2:j]
            var k = j + 1
            while k < len(s) and s[k] in "#0+ -":
                k = k + 1
            while k < len(s) and (s[k] in "0123456789*"):
                k = k + 1
            if k < len(s) and s[k] == ".":
                k = k + 1
                while k < len(s) and (s[k] in "0123456789*"):
                    k = k + 1
            if k < len(s) and s[k] in "diouxefgcrsa%" and name and all([_is_ident_char(c) for c in name]):
                out.append(name)
            i = s.find("%(", j + 1)
        return out

    def validate(self):
        """Validate the input format, ensure it matches the correct style"""
        if not self._fields():
            raise ValueError("Invalid format '" + self._fmt + "' for '" + self.default_format[0] + "' style")

    def _format(self, record):
        return self._fmt % _record_values(record, self._defaults)

    def format(self, record):
        try:
            return self._format(record)
        except KeyError as e:
            raise ValueError("Formatting field not found in record: " + str(e))


class StrFormatStyle(PercentStyle):
    default_format = "{message}"
    asctime_format = "{asctime}"
    asctime_search = "{asctime"

    def _format(self, record):
        return self._fmt.format(**_record_values(record, self._defaults))

    def validate(self):
        """Validate the input format, ensure it is the correct string formatting style"""
        var fields = []
        var s = self._fmt
        var i = 0
        var n = len(s)
        while i < n:
            var c = s[i]
            if c == "{":
                if i + 1 < n and s[i + 1] == "{":
                    i = i + 2
                    continue
                var j = s.find("}", i)
                if j < 0:
                    raise ValueError("invalid format: Single '{' encountered in format string")
                var body = s[i + 1:j]
                var name = body
                for sep in ["!", ":"]:
                    var p = name.find(sep)
                    if p >= 0:
                        name = name[:p]
                var field = name
                for sep in [".", "["]:
                    var p2 = field.find(sep)
                    if p2 >= 0:
                        field = field[:p2]
                if not field or not _is_ident_start(field[0]) or not all([_is_ident_char(ch) for ch in field]):
                    raise ValueError("invalid field name/expression: " + repr(name))
                var bang = body.find("!")
                if bang >= 0:
                    var conv = body[bang + 1:bang + 2]
                    if conv not in "rsa" or not conv:
                        raise ValueError("invalid conversion: " + repr(conv))
                fields.append(field)
                i = j + 1
                continue
            if c == "}":
                if i + 1 < n and s[i + 1] == "}":
                    i = i + 2
                    continue
                raise ValueError("invalid format: Single '}' encountered in format string")
            i = i + 1
        if not fields:
            raise ValueError("invalid format: no fields")


class StringTemplateStyle(PercentStyle):
    default_format = "$" + "{message}"     # "${" would interpolate in Nython
    asctime_format = "$" + "{asctime}"
    asctime_search = "$" + "{asctime}"

    def usesTime(self):
        var fmt = self._fmt
        return fmt.find("$asctime") >= 0 or fmt.find(self.asctime_search) >= 0

    def _scan(self, values):
        # string.Template's rules: $$, $identifier, ${identifier}
        var s = self._fmt
        var out = []
        var fields = []
        var i = 0
        var n = len(s)
        while i < n:
            var c = s[i]
            if c != "$":
                out.append(c)
                i = i + 1
                continue
            if i + 1 < n and s[i + 1] == "$":
                out.append("$")
                i = i + 2
                continue
            var name = none
            if i + 1 < n and s[i + 1] == "{":
                var j = s.find("}", i + 2)
                if j >= 0:
                    var nm = s[i + 2:j]
                    if nm and _is_ident_start(nm[0]) and all([_is_ident_char(ch) for ch in nm]):
                        name = nm
                        i = j + 1
            elif i + 1 < n and _is_ident_start(s[i + 1]):
                var k = i + 1
                while k < n and _is_ident_char(s[k]):
                    k = k + 1
                name = s[i + 1:k]
                i = k
            if name is none:
                if values is not none:
                    raise ValueError("Invalid placeholder in string: line 1, col " + str(i + 1))
                out.append("$")
                i = i + 1
                continue
            fields.append(name)
            if values is not none:
                if name not in values:
                    raise KeyError(name)
                out.append(str(values[name]))
        return ["".join(out), fields]

    def validate(self):
        if not self._scan(none)[1]:
            raise ValueError("invalid format: no fields")

    def _format(self, record):
        return self._scan(_record_values(record, self._defaults))[0]


BASIC_FORMAT = "%(levelname)s:%(name)s:%(message)s"

_STYLES = {
    "%": [PercentStyle, BASIC_FORMAT],
    "{": [StrFormatStyle, "{levelname}:{name}:{message}"],
    "$": [StringTemplateStyle, "$" + "{levelname}:$" + "{name}:$" + "{message}"],
}


def _exc_str(value):
    # str(exception) as CPython gives it: a KeyError shows its key's repr
    # (Nython's KeyError("k") reads k; the runtime's own carry the quotes)
    var s = str(value)
    if isinstance(value, KeyError):
        var a = getattr(value, "args", ())
        if len(a) == 1:
            var a0 = a[0]
            if not isinstance(a0, str):
                return repr(a0)
            if not (len(a0) >= 2 and a0[0] == a0[-1] and (a0[0] == "'" or a0[0] == "\"")):
                return repr(a0)
    return s


def _exception_text(ei):
    # "Traceback (most recent call last):" + the exception line, as
    # traceback.format_exception lays it out (Nython keeps no frames).
    var value = ei[1] if ei and len(ei) > 1 else none
    var etype = ei[0] if ei and len(ei) > 0 else none
    if value is none and etype is none:
        return "NoneType: None"
    if etype is none:
        etype = type(value)
    var tname = getattr(etype, "__qualname__", none) or getattr(etype, "__name__", none) or str(etype)
    var mod = getattr(etype, "__module__", none)
    if mod is not none and mod not in ["__main__", "builtins"] and isinstance(mod, str):
        tname = mod + "." + tname
    var msg = ""
    if value is not none:
        try:
            msg = _exc_str(value)
        except Exception:
            msg = "<exception str() failed>"
    var line = tname if msg == "" else tname + ": " + msg
    return "Traceback (most recent call last):\n" + line


class Formatter:
    """
    Formatter instances are used to convert a LogRecord to text.

    Formatters need to know how a LogRecord is constructed. They are
    responsible for converting a LogRecord to (usually) a string which can
    be interpreted by either a human or an external system. The base Formatter
    allows a formatting string to be specified. If none is supplied, the
    style-dependent default value, "%(message)s", "{message}", or
    "$\{message}", is used.
    """
    default_time_format = "%Y-%m-%d %H:%M:%S"
    default_msec_format = "%s,%03d"
    # time.localtime when None; converter = time.gmtime (on the class or an
    # instance) gives UTC, as in CPython
    converter = none

    def __init__(self, fmt=none, datefmt=none, style="%", validate=true, defaults=none):
        """
        Initialize the formatter with specified format strings.

        Initialize the formatter either with the specified format string, or a
        default as described above. Allow for specialized date formatting with
        the optional datefmt argument. If datefmt is omitted, you get an
        ISO8601-like (or RFC 3339-like) format.

        Use a style parameter of '%', '{' or '$' to specify that you want to
        use one of %-formatting, :meth:`str.format` (``{}``) formatting or
        :class:`string.Template` formatting in your format string.
        """
        if style not in _STYLES:
            raise ValueError("Style must be one of: " + ",".join(list(_STYLES.keys())))
        self._style = _STYLES[style][0](fmt, defaults)
        if validate:
            self._style.validate()
        self._fmt = self._style._fmt
        self.datefmt = datefmt

    def formatTime(self, record, datefmt=none):
        """
        Return the creation time of the specified LogRecord as formatted text.

        This method should be called from format() by a formatter which
        wants to make use of a formatted time. If datefmt (a string) is
        specified, it is used with time.strftime() to format the creation
        time of the record. Otherwise, an ISO8601-like (or RFC 3339-like)
        format is used: "%Y-%m-%d %H:%M:%S,uuu".
        """
        var conv = self.converter
        var ct = none
        if conv is none:
            ct = time_localtime(record.created)
        else:
            ct = conv(record.created)
        var tm = _broken_down(ct)
        var s = ""
        if datefmt:
            s = time_strftime(datefmt, tm)
        else:
            s = time_strftime(self.default_time_format, tm)
            if self.default_msec_format:
                s = self.default_msec_format % (s, record.msecs)
        return s

    def formatException(self, ei):
        """
        Format and return the specified exception information as a string.
        """
        var s = _exception_text(ei)
        if s[-1:] == "\n":
            s = s[:-1]
        return s

    def usesTime(self):
        """
        Check if the format uses the creation time of the record.
        """
        return self._style.usesTime()

    def formatMessage(self, record):
        return self._style.format(record)

    def formatStack(self, stack_info):
        """
        This method is provided as an extension point for specialized
        formatting of stack information.

        The input data is a string as returned from a call to
        :func:`traceback.print_stack`, but with the last trailing newline
        removed.
        """
        return stack_info

    def format(self, record):
        """
        Format the specified record as text.

        The record's attribute dictionary is used as the operand to a
        string formatting operation which yields the returned string.
        Before formatting the dictionary, a couple of preparatory steps
        are carried out. The message attribute of the record is computed
        using LogRecord.getMessage(). If the formatting string uses the
        time (as determined by a call to usesTime(), formatTime() is
        called to format the event time. If there is exception information,
        it is formatted using formatException() and appended to the message.
        """
        record.message = record.getMessage()
        if self.usesTime():
            record.asctime = self.formatTime(record, self.datefmt)
        var s = self.formatMessage(record)
        if record.exc_info:
            # Cache the traceback text to avoid converting it multiple times
            # (it's constant anyway)
            if not record.exc_text:
                record.exc_text = self.formatException(record.exc_info)
        if record.exc_text:
            if s[-1:] != "\n":
                s = s + "\n"
            s = s + record.exc_text
        if record.stack_info:
            if s[-1:] != "\n":
                s = s + "\n"
            s = s + self.formatStack(record.stack_info)
        return s


# A broken-down time for time_strftime: the natives' map, or a struct_time
# (a tuple with tm_* attributes) from a time module.
def _broken_down(ct):
    if isinstance(ct, dict):
        return ct
    if hasattr(ct, "tm_year"):
        return {"year": ct.tm_year, "month": ct.tm_mon, "day": ct.tm_mday,
                "hour": ct.tm_hour, "minute": ct.tm_min, "second": ct.tm_sec,
                "weekday": ct.tm_wday, "yearday": ct.tm_yday, "isdst": ct.tm_isdst}
    return {"year": ct[0], "month": ct[1], "day": ct[2], "hour": ct[3], "minute": ct[4],
            "second": ct[5], "weekday": ct[6], "yearday": ct[7], "isdst": ct[8]}


_defaultFormatter = Formatter()


class BufferingFormatter:
    """
    A formatter suitable for formatting a number of records.
    """
    def __init__(self, linefmt=none):
        """
        Optionally specify a formatter which will be used to format each
        individual record.
        """
        if linefmt:
            self.linefmt = linefmt
        else:
            self.linefmt = _defaultFormatter

    def formatHeader(self, records):
        """
        Return the header string for the specified records.
        """
        return ""

    def formatFooter(self, records):
        """
        Return the footer string for the specified records.
        """
        return ""

    def format(self, records):
        """
        Format the specified records and return the result as a string.
        """
        var rv = ""
        if len(records) > 0:
            rv = rv + self.formatHeader(records)
            for record in records:
                rv = rv + self.linefmt.format(record)
            rv = rv + self.formatFooter(records)
        return rv


# ── Filter ───────────────────────────────────────────────────────────────────

class Filter:
    """
    Filter instances are used to perform arbitrary filtering of LogRecords.

    Loggers and Handlers can optionally use Filter instances to filter
    records as desired. The base filter class only allows events which are
    below a certain point in the logger hierarchy. For example, a filter
    initialized with "A.B" will allow events logged by loggers "A.B",
    "A.B.C", "A.B.C.D", "A.B.D" etc. but not "A.BB", "B.A.B" etc. If
    initialized with the empty string, all events are passed.
    """
    def __init__(self, name=""):
        """
        Initialize a filter.

        Initialize with the name of the logger which, together with its
        children, will have its events allowed through the filter. If no
        name is specified, allow every event.
        """
        self.name = name
        self.nlen = len(name)

    def filter(self, record):
        """
        Determine if the specified record is to be logged.

        Returns True if the record should be logged, or False otherwise.
        If deemed appropriate, the record may be modified in-place.
        """
        if self.nlen == 0:
            return true
        elif self.name == record.name:
            return true
        elif record.name.find(self.name, 0, self.nlen) != 0:
            return false
        return record.name[self.nlen:self.nlen + 1] == "."


class Filterer:
    """
    A base class for loggers and handlers which allows them to share
    common code.
    """
    def __init__(self):
        """
        Initialize the list of filters to be an empty list.
        """
        self.filters = []

    def addFilter(self, filter):
        """
        Add the specified filter to this handler.
        """
        if not _contains_same(self.filters, filter):
            self.filters.append(filter)

    def removeFilter(self, filter):
        """
        Remove the specified filter from this handler.
        """
        _remove_same(self.filters, filter)

    def filter(self, record):
        """
        Determine if a record is loggable by consulting all the filters.

        The default is to allow the record to be logged; any filter can veto
        this by returning a false value.
        If a filter attached to a handler returns a log record instance,
        then that instance is used in place of the original log record in
        any further processing of the event by that handler.
        If a filter returns any other true value, the original log record
        is used in any further processing of the event by that handler.

        If none of the filters return false values, this method returns
        a log record.
        If any of the filters return a false value, this method returns
        a false value.
        """
        for f in self.filters:
            var result = none
            if hasattr(f, "filter"):
                result = f.filter(record)
            else:
                result = f(record) # assume callable - will raise if not
            if not result:
                return false
            if isinstance(result, LogRecord):
                record = result
        return record


# Identity helpers: `is` in Nython is a type/membership test.
def _same(a, b):
    return id(a) == id(b)


def _contains_same(lst, x):
    for y in lst:
        if id(y) == id(x):
            return true
    return false


def _remove_same(lst, x):
    var i = 0
    while i < len(lst):
        if id(lst[i]) == id(x):
            del lst[i]
            return true
        i = i + 1
    return false


# ── Handlers ─────────────────────────────────────────────────────────────────

_handlers = {}      # map of handler names to handlers
_handlerList = []   # added to allow handlers to be removed in reverse of order initialized


def _addHandlerRef(handler):
    """
    Add a handler to the internal cleanup list using a weak reference.
    """
    _acquireLock()
    try:
        _handlerList.append(handler)
    finally:
        _releaseLock()


def getHandlerByName(name):
    """
    Get a handler with the specified *name*, or None if there isn't one with
    that name.
    """
    return _handlers.get(name)


def getHandlerNames():
    """
    Return all known handler names as an immutable set.
    """
    return frozenset(_handlers.keys())


class Handler(Filterer):
    """
    Handler instances dispatch logging events to specific destinations.

    The base handler class. Acts as a placeholder which defines the Handler
    interface. Handlers can optionally use Formatter instances to format
    records as desired. By default, no formatter is specified; in this case,
    the 'raw' message as determined by record.message is logged.
    """
    def __init__(self, level=NOTSET):
        """
        Initializes the instance - basically setting the formatter to None
        and the filter list to empty.
        """
        Filterer.__init__(self)
        self._name = none
        self.level = _checkLevel(level)
        self.formatter = none
        self._closed = false
        # Add the handler to the global _handlerList (for cleanup on shutdown)
        _addHandlerRef(self)
        self.createLock()

    def get_name(self):
        return self._name

    def set_name(self, name):
        _acquireLock()
        try:
            if self._name in _handlers:
                del _handlers[self._name]
            self._name = name
            if name:
                _handlers[name] = self
        finally:
            _releaseLock()

    @property
    def name(self):
        return self._name

    @name.setter
    def name(self, value):
        self.set_name(value)

    def createLock(self):
        """
        Acquire a thread lock for serializing access to the underlying I/O.
        """
        self.lock = threading.RLock()

    def _at_fork_reinit(self):
        self.createLock()

    def acquire(self):
        """
        Acquire the I/O thread lock.
        """
        if self.lock:
            self.lock.acquire()

    def release(self):
        """
        Release the I/O thread lock.
        """
        if self.lock:
            self.lock.release()

    def setLevel(self, level):
        """
        Set the logging level of this handler.  level must be an int or a str.
        """
        self.level = _checkLevel(level)

    def format(self, record):
        """
        Format the specified record.

        If a formatter is set, use it. Otherwise, use the default formatter
        for the module.
        """
        var fmt = self.formatter
        if not fmt:
            fmt = _defaultFormatter
        return fmt.format(record)

    def emit(self, record):
        """
        Do whatever it takes to actually log the specified logging record.

        This version is intended to be implemented by subclasses and so
        raises a NotImplementedError.
        """
        raise NotImplementedError("emit must be implemented by Handler subclasses")

    def handle(self, record):
        """
        Conditionally emit the specified logging record.

        Emission depends on filters which may have been added to the handler.
        Wrap the actual emission of the record with acquisition/release of
        the I/O thread lock.

        Returns an instance of the log record that was emitted
        if it passed all filters, otherwise a false value is returned.
        """
        var rv = self.filter(record)
        if isinstance(rv, LogRecord):
            record = rv
        if rv:
            self.acquire()
            try:
                self.emit(record)
            finally:
                self.release()
        return rv

    def setFormatter(self, fmt):
        """
        Set the formatter for this handler.
        """
        self.formatter = fmt

    def flush(self):
        """
        Ensure all logging output has been flushed.

        This version does nothing and is intended to be implemented by
        subclasses.
        """
        pass

    def close(self):
        """
        Tidy up any resources used by the handler.

        This version removes the handler from an internal map of handlers,
        _handlers, which is used for handler lookup by name. Subclasses
        should ensure that this gets called from overridden close()
        methods.
        """
        _acquireLock()
        try:
            self._closed = true
            if self._name and self._name in _handlers:
                del _handlers[self._name]
        finally:
            _releaseLock()

    def handleError(self, record):
        """
        Handle errors which occur during an emit() call.

        This method should be called from handlers when an exception is
        encountered during an emit() call. If raiseExceptions is false,
        exceptions get silently ignored. This is what is mostly wanted
        for a logging system - most users will not care about errors in
        the logging system, they are more interested in application errors.
        You could, however, replace this with a custom handler if you wish.
        The record which was being processed is passed in to this method.
        """
        if raiseExceptions:
            try:
                var err = sys.stderr
                err.write("--- Logging error ---\n")
                var e = _ny_exc_current()
                if e is not none:
                    err.write(_exception_text((type(e), e, none)) + "\n")
                err.write("Call stack:\n")
                try:
                    err.write("Message: " + repr(record.msg) + "\nArguments: " + str(record.args) + "\n")
                except RecursionError:
                    raise
                except Exception:
                    err.write("Unable to print the message and arguments - possible formatting error.\nUse the traceback above to help find the error.\n")
            except OSError:
                pass

    def __repr__(self):
        var level = getLevelName(self.level)
        return "<" + self.__class__.__name__ + " (" + str(level) + ")>"


class StreamHandler(Handler):
    """
    A handler class which writes logging records, appropriately formatted,
    to a stream. Note that this class does not close the stream, as
    sys.stdout or sys.stderr may be used.
    """
    terminator = "\n"

    def __init__(self, stream=none):
        """
        Initialize the handler.

        If stream is not specified, sys.stderr is used.
        """
        Handler.__init__(self)
        if stream is none:
            stream = sys.stderr
        self.stream = stream

    def flush(self):
        """
        Flushes the stream.
        """
        self.acquire()
        try:
            if self.stream and hasattr(self.stream, "flush"):
                self.stream.flush()
        finally:
            self.release()

    def emit(self, record):
        """
        Emit a record.

        If a formatter is specified, it is used to format the record.
        The record is then written to the stream with a trailing newline.  If
        exception information is present, it is formatted using
        traceback.print_exception and appended to the stream.  If the stream
        has an 'encoding' attribute, it is used to determine how to do the
        output to the stream.
        """
        try:
            var msg = self.format(record)
            var stream = self.stream
            # issue 35046: merged two stream.writes into one.
            stream.write(msg + self.terminator)
            self.flush()
        except RecursionError:  # See issue 36272
            raise
        except Exception:
            self.handleError(record)

    def setStream(self, stream):
        """
        Sets the StreamHandler's stream to the specified value,
        if it is different.

        Returns the old stream, if the stream was changed, or None
        if it wasn't.
        """
        if id(stream) == id(self.stream):
            return none
        var result = self.stream
        self.acquire()
        try:
            self.flush()
            self.stream = stream
        finally:
            self.release()
        return result

    def __repr__(self):
        var level = getLevelName(self.level)
        var name = str(getattr(self.stream, "name", ""))
        #  bpo-36015: name can be an int
        if name:
            name = name + " "
        return "<" + self.__class__.__name__ + " " + name + "(" + str(level) + ")>"


class FileHandler(StreamHandler):
    """
    A handler class which writes formatted logging records to disk files.
    """
    def __init__(self, filename, mode="a", encoding=none, delay=false, errors=none):
        """
        Open the specified file and use it as the stream for logging.
        """
        # Issue #27493: add support for Path objects to be passed in
        if hasattr(filename, "__fspath__"):
            filename = filename.__fspath__()
        #keep the absolute path, otherwise derived classes which use this
        #may come a cropper when the current directory changes
        self.baseFilename = os_path_abspath(filename)
        self.mode = mode
        self.encoding = encoding
        if "b" not in mode and encoding is none:
            self.encoding = "utf-8"
        self.errors = errors
        self.delay = delay
        # bpo-26789: FileHandler keeps a reference to the builtin open()
        # function to be able to open or reopen the file during Python
        # finalization.
        if delay:
            # We don't open the stream, but we still need to call the
            # Handler constructor to set level, formatter, lock etc.
            Handler.__init__(self)
            self.stream = none
        else:
            StreamHandler.__init__(self, self._open())

    def close(self):
        """
        Closes the stream.
        """
        self.acquire()
        try:
            try:
                if self.stream:
                    try:
                        self.flush()
                    finally:
                        var stream = self.stream
                        self.stream = none
                        if hasattr(stream, "close"):
                            stream.close()
            finally:
                # Issue #19523: call unconditionally to
                # prevent a handler leak when delay is set
                # Also see Issue #42378: we also rely on
                # self._closed being set to True there
                StreamHandler.close(self)
        finally:
            self.release()

    def _open(self):
        """
        Open the current base file with the (original) mode and encoding.
        Return the resulting stream.
        """
        if "b" in self.mode:
            return open(self.baseFilename, self.mode)
        return open(self.baseFilename, self.mode, self.encoding)

    def emit(self, record):
        """
        Emit a record.

        If the stream was not opened because 'delay' was specified in the
        constructor, open it before calling the superclass's emit.

        If stream is not open, current mode is 'w' and `_closed=True`, record
        will not be emitted (see Issue #42378).
        """
        if self.stream is none:
            if self.mode != "w" or not self._closed:
                self.stream = self._open()
        if self.stream:
            StreamHandler.emit(self, record)

    def __repr__(self):
        var level = getLevelName(self.level)
        return "<" + self.__class__.__name__ + " " + self.baseFilename + " (" + str(level) + ")>"


class _StderrHandler(StreamHandler):
    """
    This class is like a StreamHandler using sys.stderr, but always uses
    whatever sys.stderr is currently set to rather than the value of
    sys.stderr at handler construction time.
    """
    def __init__(self, level=NOTSET):
        """
        Initialize the handler.
        """
        Handler.__init__(self, level)
        self.stream = none

    def emit(self, record):
        self.stream = sys.stderr
        StreamHandler.emit(self, record)

    def flush(self):
        self.stream = sys.stderr
        StreamHandler.flush(self)


_defaultLastResort = _StderrHandler(WARNING)
lastResort = _defaultLastResort


# ── Manager / Logger ─────────────────────────────────────────────────────────

class PlaceHolder:
    """
    PlaceHolder instances are used in the Manager logger hierarchy to take
    the place of nodes for which no loggers have been defined. This class is
    intended for internal use only and not as part of the public API.
    """
    def __init__(self, alogger):
        """
        Initialize with the specified logger being a child of this placeholder.
        """
        self.loggerMap = [alogger]

    def append(self, alogger):
        """
        Add the specified logger as a child of this placeholder.
        """
        if not _contains_same(self.loggerMap, alogger):
            self.loggerMap.append(alogger)


_loggerClass = none


def setLoggerClass(klass):
    """
    Set the class to be used when instantiating a logger. The class should
    define __init__() such that only a name argument is required, and the
    __init__() should call Logger.__init__()
    """
    global _loggerClass
    if not issubclass(klass, Logger):
        raise TypeError("logger not derived from logging.Logger: " + klass.__name__)
    _loggerClass = klass


def getLoggerClass():
    """
    Return the class to be used when instantiating a logger.
    """
    return _loggerClass


class Manager:
    """
    There is [under normal circumstances] just one Manager instance, which
    holds the hierarchy of loggers.
    """
    def __init__(self, rootnode):
        """
        Initialize the manager with the root node of the logger hierarchy.
        """
        self.root = rootnode
        self.disable = 0
        self.emittedNoHandlerWarning = false
        self.loggerDict = {}
        self.loggerClass = none
        self.logRecordFactory = none

    def getLogger(self, name):
        """
        Get a logger with the specified name (channel name), creating it
        if it doesn't yet exist. This name is a dot-separated hierarchical
        name, such as "a", "a.b", "a.b.c" or similar.

        If a PlaceHolder existed for the specified name [i.e. the logger
        didn't exist but a child of it did], replace it with the created
        logger and fix up the parent/child references which pointed to the
        placeholder to now point to the logger.
        """
        var rv = none
        if not isinstance(name, str):
            raise TypeError("A logger name must be a string")
        _acquireLock()
        try:
            if name in self.loggerDict:
                rv = self.loggerDict[name]
                if isinstance(rv, PlaceHolder):
                    var ph = rv
                    rv = (self.loggerClass or _loggerClass)(name)
                    rv.manager = self
                    self.loggerDict[name] = rv
                    self._fixupChildren(ph, rv)
                    self._fixupParents(rv)
            else:
                rv = (self.loggerClass or _loggerClass)(name)
                rv.manager = self
                self.loggerDict[name] = rv
                self._fixupParents(rv)
        finally:
            _releaseLock()
        return rv

    def setLoggerClass(self, klass):
        """
        Set the class to be used when instantiating a logger with this Manager.
        """
        if not id(klass) == id(Logger):
            if not issubclass(klass, Logger):
                raise TypeError("logger not derived from logging.Logger: " + klass.__name__)
        self.loggerClass = klass

    def setLogRecordFactory(self, factory):
        """
        Set the factory to be used when instantiating a log record with this
        Manager.
        """
        self.logRecordFactory = factory

    def _fixupParents(self, alogger):
        """
        Ensure that there are either loggers or placeholders all the way
        from the specified logger to the root of the logger hierarchy.
        """
        var name = alogger.name
        var i = name.rfind(".")
        var rv = none
        while (i > 0) and not rv:
            var substr = name[:i]
            if substr not in self.loggerDict:
                self.loggerDict[substr] = PlaceHolder(alogger)
            else:
                var obj = self.loggerDict[substr]
                if isinstance(obj, Logger):
                    rv = obj
                else:
                    obj.append(alogger)
            i = name.rfind(".", 0, i - 1)
        if not rv:
            rv = self.root
        alogger.parent = rv

    def _fixupChildren(self, ph, alogger):
        """
        Ensure that children of the placeholder ph are connected to the
        specified logger.
        """
        var name = alogger.name
        var namelen = len(name)
        for c in ph.loggerMap:
            #The if means ... if not c.parent.name.startswith(nm)
            if c.parent.name[:namelen] != name:
                alogger.parent = c.parent
                c.parent = alogger

    def _clear_cache(self):
        """
        Clear the cache for all loggers in loggerDict
        Called when level changes are made
        """
        _acquireLock()
        try:
            for name in self.loggerDict:
                var logger = self.loggerDict[name]
                if isinstance(logger, Logger):
                    logger._cache.clear()
            self.root._cache.clear()
        finally:
            _releaseLock()


class Logger(Filterer):
    """
    Instances of the Logger class represent a single logging channel. A
    "logging channel" indicates an area of an application. Exactly how an
    "area" is defined is up to the application developer. Since an
    application can have any number of areas, logging channels are identified
    by a unique string. Application areas can be nested (e.g. an area
    of "input processing" might include sub-areas "read CSV files", "read
    XLS files" and "read Gnumeric files"). To cater for this natural nesting,
    channel names are organized into a namespace hierarchy where levels are
    separated by periods, much like the Java or Python package namespace. So
    in the instance given above, channel names might be "input" for the upper
    level, and "input.csv", "input.xls" and "input.gnu" for the sub-levels.
    There is no arbitrary limit to the depth of nesting.
    """
    def __init__(self, name, level=NOTSET):
        """
        Initialize the logger with a name and an optional level.
        """
        Filterer.__init__(self)
        self.name = name
        self.level = _checkLevel(level)
        self.parent = none
        self.propagate = true
        self.handlers = []
        self.disabled = false
        self._cache = {}

    def setLevel(self, level):
        """
        Set the logging level of this logger.  level must be an int or a str.
        """
        self.level = _checkLevel(level)
        self.manager._clear_cache()

    def debug(self, msg, *args, **kwargs):
        """
        Log 'msg % args' with severity 'DEBUG'.
        """
        if self.isEnabledFor(DEBUG):
            self._log(DEBUG, msg, args, **kwargs)

    def info(self, msg, *args, **kwargs):
        """
        Log 'msg % args' with severity 'INFO'.
        """
        if self.isEnabledFor(INFO):
            self._log(INFO, msg, args, **kwargs)

    def warning(self, msg, *args, **kwargs):
        """
        Log 'msg % args' with severity 'WARNING'.
        """
        if self.isEnabledFor(WARNING):
            self._log(WARNING, msg, args, **kwargs)

    def warn(self, msg, *args, **kwargs):
        self.warning(msg, *args, **kwargs)

    def error(self, msg, *args, **kwargs):
        """
        Log 'msg % args' with severity 'ERROR'.
        """
        if self.isEnabledFor(ERROR):
            self._log(ERROR, msg, args, **kwargs)

    def exception(self, msg, *args, exc_info=true, **kwargs):
        """
        Convenience method for logging an ERROR with exception information.
        """
        self.error(msg, *args, exc_info=exc_info, **kwargs)

    def critical(self, msg, *args, **kwargs):
        """
        Log 'msg % args' with severity 'CRITICAL'.
        """
        if self.isEnabledFor(CRITICAL):
            self._log(CRITICAL, msg, args, **kwargs)

    def fatal(self, msg, *args, **kwargs):
        """
        Don't use this method, use critical() instead.
        """
        self.critical(msg, *args, **kwargs)

    def log(self, level, msg, *args, **kwargs):
        """
        Log 'msg % args' with the integer severity 'level'.
        """
        if not isinstance(level, int):
            if raiseExceptions:
                raise TypeError("level must be an integer")
            else:
                return
        if self.isEnabledFor(level):
            self._log(level, msg, args, **kwargs)

    def findCaller(self, stack_info=false, stacklevel=1):
        """
        Find the stack frame of the caller so that we can note the source
        file name, line number and function name. Nython keeps no frames:
        CPython's values for an unknown caller.
        """
        var sinfo = none
        if stack_info:
            sinfo = "Stack (most recent call last):"
        return ("(unknown file)", 0, "(unknown function)", sinfo)

    def makeRecord(self, name, level, fn, lno, msg, args, exc_info,
                   func=none, extra=none, sinfo=none):
        """
        A factory method which can be overridden in subclasses to create
        specialized LogRecords.
        """
        var factory = self.manager.logRecordFactory or _logRecordFactory
        var rv = factory(name, level, fn, lno, msg, args, exc_info, func, sinfo)
        if extra is not none:
            for key in extra:
                if (key in ["message", "asctime"]) or hasattr(rv, key):
                    raise KeyError("Attempt to overwrite " + repr(key) + " in LogRecord")
                setattr(rv, key, extra[key])
        return rv

    def _log(self, level, msg, args, exc_info=none, extra=none, stack_info=false,
             stacklevel=1):
        """
        Low-level logging routine which creates a LogRecord and then calls
        all the handlers of this logger to handle the record.
        """
        var fc = self.findCaller(stack_info, stacklevel)
        if exc_info:
            if isinstance(exc_info, BaseException):
                exc_info = (type(exc_info), exc_info, none)
            elif not isinstance(exc_info, tuple):
                var e = _ny_exc_current()
                if e is none:
                    exc_info = (none, none, none)
                else:
                    exc_info = (type(e), e, none)
        var record = self.makeRecord(self.name, level, fc[0], fc[1], msg, args,
                                     exc_info, fc[2], extra, fc[3])
        self.handle(record)

    def handle(self, record):
        """
        Call the handlers for the specified record.

        This method is used for unpickled records received from a socket, as
        well as those created locally. Logger-level filtering is applied.
        """
        if self.disabled:
            return
        var maybe_record = self.filter(record)
        if not maybe_record:
            return
        if isinstance(maybe_record, LogRecord):
            record = maybe_record
        self.callHandlers(record)

    def addHandler(self, hdlr):
        """
        Add the specified handler to this logger.
        """
        _acquireLock()
        try:
            if not _contains_same(self.handlers, hdlr):
                self.handlers.append(hdlr)
        finally:
            _releaseLock()

    def removeHandler(self, hdlr):
        """
        Remove the specified handler from this logger.
        """
        _acquireLock()
        try:
            _remove_same(self.handlers, hdlr)
        finally:
            _releaseLock()

    def hasHandlers(self):
        """
        See if this logger has any handlers configured.

        Loop through all handlers for this logger and its parents in the
        logger hierarchy. Return True if a handler was found, else False.
        Stop searching up the hierarchy whenever a logger with the "propagate"
        attribute set to zero is found - that will be the last logger which
        is checked for the existence of handlers.
        """
        var c = self
        var rv = false
        while c:
            if c.handlers:
                rv = true
                break
            if not c.propagate:
                break
            else:
                c = c.parent
        return rv

    def callHandlers(self, record):
        """
        Pass a record to all relevant handlers.

        Loop through all handlers for this logger and its parents in the
        logger hierarchy. If no handler was found, output a one-off error
        message to sys.stderr. Stop searching up the hierarchy whenever a
        logger with the "propagate" attribute set to zero is found - that
        will be the last logger whose handlers are called.
        """
        var c = self
        var found = 0
        while c:
            for hdlr in list(c.handlers):
                found = found + 1
                if record.levelno >= hdlr.level:
                    hdlr.handle(record)
            if not c.propagate:
                c = none    #break out
            else:
                c = c.parent
        if found == 0:
            if lastResort:
                if record.levelno >= lastResort.level:
                    lastResort.handle(record)
            elif raiseExceptions and not self.manager.emittedNoHandlerWarning:
                sys.stderr.write("No handlers could be found for logger \"" + self.name + "\"\n")
                self.manager.emittedNoHandlerWarning = true

    def getEffectiveLevel(self):
        """
        Get the effective level for this logger.

        Loop through this logger and its parents in the logger hierarchy,
        looking for a non-zero logging level. Return the first one found.
        """
        var logger = self
        while logger:
            if logger.level:
                return logger.level
            logger = logger.parent
        return NOTSET

    def isEnabledFor(self, level):
        """
        Is this logger enabled for level 'level'?
        """
        if self.disabled:
            return false
        var hit = self._cache.get(level)
        if hit is not none:
            return hit
        _acquireLock()
        var is_enabled = false
        try:
            if self.manager.disable >= level:
                is_enabled = false
            else:
                is_enabled = level >= self.getEffectiveLevel()
            self._cache[level] = is_enabled
        finally:
            _releaseLock()
        return is_enabled

    def getChild(self, suffix):
        """
        Get a logger which is a descendant to this one.

        This is a convenience method, such that

        logging.getLogger('abc').getChild('def.ghi')

        is the same as

        logging.getLogger('abc.def.ghi')

        It's useful, for example, when the parent logger is named using
        __name__ rather than a literal string.
        """
        if not _same(self.root, self):
            suffix = self.name + "." + suffix
        return self.manager.getLogger(suffix)

    def getChildren(self):
        """
        Return the set of loggers that are immediate children of this one.
        """
        var out = []
        _acquireLock()
        try:
            for name in self.manager.loggerDict:
                var item = self.manager.loggerDict[name]
                if isinstance(item, Logger) and item.parent is not none and _same(item.parent, self):
                    out.append(item)
        finally:
            _releaseLock()
        return set(out)

    def __repr__(self):
        var level = getLevelName(self.getEffectiveLevel())
        return "<" + self.__class__.__name__ + " " + self.name + " (" + str(level) + ")>"


class RootLogger(Logger):
    """
    A root logger is not that different to any other logger, except that
    it must have a logging level and there is only one instance of it in
    the hierarchy.
    """
    def __init__(self, level):
        """
        Initialize the logger with the name "root".
        """
        Logger.__init__(self, "root", level)

    def __repr__(self):
        var level = getLevelName(self.getEffectiveLevel())
        return "<RootLogger root (" + str(level) + ")>"


_loggerClass = Logger


class LoggerAdapter:
    """
    An adapter for loggers which makes it easier to specify contextual
    information in logging output.
    """
    def __init__(self, logger, extra=none, merge_extra=false):
        """
        Initialize the adapter with a logger and a dict-like object which
        provides contextual information. This constructor signature allows
        easy stacking of LoggerAdapters, if so desired.

        You can effectively pass keyword arguments as shown in the
        following example:

        adapter = LoggerAdapter(someLogger, dict(p1=v1, p2="v2"))
        """
        self.logger = logger
        self.extra = extra
        self.merge_extra = merge_extra

    def process(self, msg, kwargs):
        """
        Process the logging message and keyword arguments passed in to
        a logging call to insert contextual information. You can either
        manipulate the message itself, the keyword args or both. Return
        the message and kwargs modified (or not) to suit your needs.

        Normally, you'll only need to override this one method in a
        LoggerAdapter subclass for your specific needs.
        """
        if self.merge_extra and "extra" in kwargs:
            var merged = dict(self.extra or {})
            for k in kwargs["extra"]:
                merged[k] = kwargs["extra"][k]
            kwargs["extra"] = merged
        else:
            kwargs["extra"] = self.extra
        return (msg, kwargs)

    def debug(self, msg, *args, **kwargs):
        self.log(DEBUG, msg, *args, **kwargs)

    def info(self, msg, *args, **kwargs):
        self.log(INFO, msg, *args, **kwargs)

    def warning(self, msg, *args, **kwargs):
        self.log(WARNING, msg, *args, **kwargs)

    def warn(self, msg, *args, **kwargs):
        self.warning(msg, *args, **kwargs)

    def error(self, msg, *args, **kwargs):
        self.log(ERROR, msg, *args, **kwargs)

    def exception(self, msg, *args, exc_info=true, **kwargs):
        self.log(ERROR, msg, *args, exc_info=exc_info, **kwargs)

    def critical(self, msg, *args, **kwargs):
        self.log(CRITICAL, msg, *args, **kwargs)

    def log(self, level, msg, *args, **kwargs):
        """
        Delegate a log call to the underlying logger, after adding
        contextual information from this adapter instance.
        """
        if self.isEnabledFor(level):
            var mk = self.process(msg, kwargs)
            self.logger.log(level, mk[0], *args, **mk[1])

    def isEnabledFor(self, level):
        return self.logger.isEnabledFor(level)

    def setLevel(self, level):
        self.logger.setLevel(level)

    def getEffectiveLevel(self):
        return self.logger.getEffectiveLevel()

    def hasHandlers(self):
        return self.logger.hasHandlers()

    def _log(self, level, msg, args, **kwargs):
        return self.logger._log(level, msg, args, **kwargs)

    @property
    def manager(self):
        return self.logger.manager

    @property
    def name(self):
        return self.logger.name

    def __repr__(self):
        var logger = self.logger
        var level = getLevelName(logger.getEffectiveLevel())
        return "<" + self.__class__.__name__ + " " + logger.name + " (" + str(level) + ")>"


root = RootLogger(WARNING)
Logger.root = root
Logger.manager = Manager(Logger.root)
root.manager = Logger.manager


# ── configuration and module-level functions ────────────────────────────────

def basicConfig(**kwargs):
    """
    Do basic configuration for the logging system.

    This function does nothing if the root logger already has handlers
    configured, unless the keyword argument *force* is set to ``True``.
    It is a convenience method intended for use by simple scripts
    to do one-shot configuration of the logging package.

    The default behaviour is to create a StreamHandler which writes to
    sys.stderr, set a formatter using the BASIC_FORMAT format string, and
    add the handler to the root logger.

    A number of optional keyword arguments may be specified, which can alter
    the default behaviour: filename, filemode, format, datefmt, style,
    level, stream, handlers, force, encoding, errors.
    """
    _acquireLock()
    try:
        var force = kwargs.pop("force", false)
        var encoding = kwargs.pop("encoding", none)
        var errors = kwargs.pop("errors", "backslashreplace")
        if force:
            for h in list(root.handlers):
                root.removeHandler(h)
                h.close()
        if len(root.handlers) == 0:
            var handlers = kwargs.pop("handlers", none)
            if handlers is none:
                if "stream" in kwargs and "filename" in kwargs:
                    raise ValueError("'stream' and 'filename' should not be specified together")
            else:
                if "stream" in kwargs or "filename" in kwargs:
                    raise ValueError("'stream' or 'filename' should not be specified together with 'handlers'")
            if handlers is none:
                var filename = kwargs.pop("filename", none)
                var mode = kwargs.pop("filemode", "a")
                var h = none
                if filename:
                    if "b" in mode:
                        errors = none
                    h = FileHandler(filename, mode, encoding, false, errors)
                else:
                    var stream = kwargs.pop("stream", none)
                    h = StreamHandler(stream)
                handlers = [h]
            var dfs = kwargs.pop("datefmt", none)
            var style = kwargs.pop("style", "%")
            if style not in _STYLES:
                raise ValueError("Style must be one of: " + ",".join(list(_STYLES.keys())))
            var fs = kwargs.pop("format", _STYLES[style][1])
            var fmt = Formatter(fs, dfs, style)
            for hd in handlers:
                if hd.formatter is none:
                    hd.setFormatter(fmt)
                root.addHandler(hd)
            var level = kwargs.pop("level", none)
            if level is not none:
                root.setLevel(level)
            if kwargs:
                var keys = ", ".join(list(kwargs.keys()))
                raise ValueError("Unrecognised argument(s): " + keys)
    finally:
        _releaseLock()


def getLogger(name=none):
    """
    Return a logger with the specified name, creating it if necessary.

    If no name is specified, return the root logger.
    """
    if not name or (isinstance(name, str) and name == root.name):
        return root
    return Logger.manager.getLogger(name)


def critical(msg, *args, **kwargs):
    """
    Log a message with severity 'CRITICAL' on the root logger. If the logger
    has no handlers, call basicConfig() to add a console handler with a
    pre-defined format.
    """
    if len(root.handlers) == 0:
        basicConfig()
    root.critical(msg, *args, **kwargs)


def fatal(msg, *args, **kwargs):
    """
    Don't use this function, use critical() instead.
    """
    critical(msg, *args, **kwargs)


def error(msg, *args, **kwargs):
    """
    Log a message with severity 'ERROR' on the root logger. If the logger has
    no handlers, call basicConfig() to add a console handler with a pre-defined
    format.
    """
    if len(root.handlers) == 0:
        basicConfig()
    root.error(msg, *args, **kwargs)


def exception(msg, *args, exc_info=true, **kwargs):
    """
    Log a message with severity 'ERROR' on the root logger, with exception
    information. If the logger has no handlers, basicConfig() is called to add
    a console handler with a pre-defined format.
    """
    error(msg, *args, exc_info=exc_info, **kwargs)


def warning(msg, *args, **kwargs):
    """
    Log a message with severity 'WARNING' on the root logger. If the logger has
    no handlers, call basicConfig() to add a console handler with a pre-defined
    format.
    """
    if len(root.handlers) == 0:
        basicConfig()
    root.warning(msg, *args, **kwargs)


def warn(msg, *args, **kwargs):
    warning(msg, *args, **kwargs)


def info(msg, *args, **kwargs):
    """
    Log a message with severity 'INFO' on the root logger. If the logger has
    no handlers, call basicConfig() to add a console handler with a pre-defined
    format.
    """
    if len(root.handlers) == 0:
        basicConfig()
    root.info(msg, *args, **kwargs)


def debug(msg, *args, **kwargs):
    """
    Log a message with severity 'DEBUG' on the root logger. If the logger has
    no handlers, call basicConfig() to add a console handler with a pre-defined
    format.
    """
    if len(root.handlers) == 0:
        basicConfig()
    root.debug(msg, *args, **kwargs)


def log(level, msg, *args, **kwargs):
    """
    Log 'msg % args' with the integer severity 'level' on the root logger. If
    the logger has no handlers, call basicConfig() to add a console handler
    with a pre-defined format.
    """
    if len(root.handlers) == 0:
        basicConfig()
    root.log(level, msg, *args, **kwargs)


def disable(level=CRITICAL):
    """
    Disable all logging calls of severity 'level' and below.
    """
    root.manager.disable = level
    root.manager._clear_cache()


def shutdown(handlerList=none):
    """
    Perform any cleanup actions in the logging system (e.g. flushing
    buffers).

    Should be called at application exit.
    """
    if handlerList is none:
        handlerList = _handlerList
    var hs = list(handlerList)
    hs.reverse()
    for h in hs:
        try:
            if h:
                try:
                    h.acquire()
                    # MemoryHandlers might not want to be flushed on close,
                    # but circular imports prevent us scoping this to just
                    # those handlers.  See #9501
                    if getattr(h, "flushOnClose", true):
                        h.flush()
                    h.close()
                except (OSError, ValueError):
                    # Ignore errors which might be caused
                    # because handlers have been closed but
                    # references to them are still around at
                    # application exit.
                    pass
                finally:
                    h.release()
        except Exception:
            if raiseExceptions:
                raise


class NullHandler(Handler):
    """
    This handler does nothing. It's intended to be used to avoid the
    "No handlers could be found for logger XXX" one-off warning. This is
    important for library code, which may contain code to log events. If a user
    of the library does not configure logging, the one-off warning might be
    produced; to avoid this, the library developer simply needs to instantiate
    a NullHandler and add it to the top-level logger of the library module or
    package.
    """
    def handle(self, record):
        """Stub."""
        pass

    def emit(self, record):
        """Stub."""
        pass

    def createLock(self):
        self.lock = none

    def _at_fork_reinit(self):
        pass


def captureWarnings(capture):
    """
    If capture is true, redirect all warnings to the logging package.
    If capture is False, ensure that warnings are not redirected to logging
    but to their original destinations. (Nython has no warnings module:
    nothing to redirect.)
    """
    pass
