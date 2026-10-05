# nython: module    (import it by name: it runs in a module scope of its own)
# lib/time.ny - Python's time module (CPython 3.12).
#
#     import time
#     time.time(); time.sleep(0.1); time.monotonic(); time.perf_counter_ns()
#     time.localtime(); time.strftime("%Y-%m-%d", time.gmtime(0))
#     time.strptime("2024-01-02", "%Y-%m-%d"); time.mktime(t); time.ctime(0)
#
# Built on the natives of builtins/os_time.cpp (time_now, time_ns,
# time_monotonic, time_localtime, time_gmtime, time_mktime, time_strftime,
# sleep through the concurrency runtime - the GIL is released and an async
# task only parks itself). Every function here shadows the native of its
# name, so the module calls them by their time_* names.
#
# struct_time   9 fields as a tuple (indexing, slicing, unpacking, len 9,
#               == with tuples) plus tm_zone and tm_gmtoff; Python's repr
# clocks        time time_ns monotonic(_ns) perf_counter(_ns) process_time(_ns)
#               thread_time(_ns) get_clock_info
# conversions   localtime gmtime mktime asctime ctime strftime strptime
# zone          timezone altzone daylight tzname (from January and July)
#
# strptime is Python's _strptime algorithm (C locale): the same directives
# (%Y %m %d %H %M %S %f %z %Z %j %a %A %b %B %p %y %I %U %W %w %u %G %V %c %x
# %X %%), whitespace in the format matching any run of whitespace, case
# ignored, the same backtracking between alternatives a regex makes, and its
# errors ("time data '...' does not match format '...'", "unconverted data
# remains: ..."). lib/datetime.ny uses it for datetime.strptime.
#
# Differences: thread_time() is the process's CPU time (no per-thread clock
# native); strftime(fmt, secs, utc) also takes a timestamp in place of the
# tuple, as the old time.strftime builtin did.

_native_time_ns = time_ns

_STRUCT_TM_ITEMS = 11
_FIELDS = ["tm_year", "tm_mon", "tm_mday", "tm_hour", "tm_min", "tm_sec", "tm_wday", "tm_yday", "tm_isdst"]


class struct_time:
    """The time value as returned by gmtime(), localtime(), and strptime(), and
    accepted by asctime(), mktime() and strftime().  May be considered as a
    sequence of 9 integers."""

    n_fields = 11
    n_sequence_fields = 9
    n_unnamed_fields = 0

    def __init__(self, seq, dict=none):
        var items = list(seq)
        if len(items) < 9:
            raise TypeError("time.struct_time() takes an at least 9-sequence (" + str(len(items)) + "-sequence given)")
        if len(items) > 11:
            raise TypeError("time.struct_time() takes an at most 11-sequence (" + str(len(items)) + "-sequence given)")
        self._t = tuple(items[0:9])
        self.tm_year = items[0]
        self.tm_mon = items[1]
        self.tm_mday = items[2]
        self.tm_hour = items[3]
        self.tm_min = items[4]
        self.tm_sec = items[5]
        self.tm_wday = items[6]
        self.tm_yday = items[7]
        self.tm_isdst = items[8]
        self.tm_zone = items[9] if len(items) > 9 else none
        self.tm_gmtoff = items[10] if len(items) > 10 else none

    def __len__(self):
        return 9

    def __getitem__(self, i):
        return self._t[i]

    def __iter__(self):
        return iter(self._t)

    def __contains__(self, x):
        return x in self._t

    def __eq__(self, other):
        if isinstance(other, struct_time):
            return self._t == other._t
        if isinstance(other, tuple):
            return self._t == other
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def __lt__(self, other):
        return self._t < (other._t if isinstance(other, struct_time) else other)

    def __le__(self, other):
        return self._t <= (other._t if isinstance(other, struct_time) else other)

    def __gt__(self, other):
        return self._t > (other._t if isinstance(other, struct_time) else other)

    def __ge__(self, other):
        return self._t >= (other._t if isinstance(other, struct_time) else other)

    def __hash__(self):
        return hash(self._t)

    def __add__(self, other):
        return self._t + tuple(other)

    def count(self, x):
        return list(self._t).count(x)

    def index(self, x):
        return list(self._t).index(x)

    def __repr__(self):
        var parts = []
        for i in range(9):
            parts.append(_FIELDS[i] + "=" + repr(self._t[i]))
        return "time.struct_time(" + ", ".join(parts) + ")"

    def __str__(self):
        return self.__repr__()


def _from_map(m, zone, gmtoff):
    return struct_time((m["year"], m["month"], m["day"], m["hour"], m["minute"], m["second"],
                        m["weekday"], m["yearday"], m["isdst"], zone, gmtoff))


def _to_map(t):
    # a struct_time or 9-tuple as the natives' map
    return {"year": t[0], "month": t[1], "day": t[2], "hour": t[3], "minute": t[4],
            "second": t[5], "weekday": t[6], "yearday": t[7], "isdst": t[8]}


def _secs(secs):
    if secs is none:
        return time_now()
    if isinstance(secs, bool) or not (isinstance(secs, int) or isinstance(secs, float)):
        raise TypeError("'" + type(secs).__name__ + "' object cannot be interpreted as an integer")
    if secs != secs:
        raise ValueError("Invalid value NaN (not a number)")
    return secs


# ── clocks ──
def time():
    """Return the current time in seconds since the Epoch."""
    return time_now()


def time_ns():
    """Return the current time in nanoseconds since the Epoch."""
    return _native_time_ns()


def sleep(secs):
    """Delay execution for a given number of seconds."""
    if isinstance(secs, bool) or not (isinstance(secs, int) or isinstance(secs, float)):
        raise TypeError("'" + type(secs).__name__ + "' object cannot be interpreted as an integer")
    if secs < 0:
        raise ValueError("sleep length must be non-negative")
    time_sleep(secs)
    return none


def monotonic():
    """Monotonic clock, cannot go backward."""
    return time_monotonic()


def monotonic_ns():
    """Monotonic clock, cannot go backward, as nanoseconds."""
    return int(time_monotonic() * 1000000000)


def perf_counter():
    """Performance counter for benchmarking."""
    return time_perf_counter()


def perf_counter_ns():
    """Performance counter for benchmarking as nanoseconds."""
    return int(time_perf_counter() * 1000000000)


def process_time():
    """Process time for profiling: sum of the kernel and user-space CPU time."""
    return time_process()


def process_time_ns():
    """Process time for profiling as nanoseconds."""
    return int(time_process() * 1000000000)


def thread_time():
    """CPU time (here: of the whole process)."""
    return time_process()


def thread_time_ns():
    return int(time_process() * 1000000000)


class _ClockInfo:
    def __init__(self, implementation, monotonic, adjustable, resolution):
        self.implementation = implementation
        self.monotonic = monotonic
        self.adjustable = adjustable
        self.resolution = resolution

    def __repr__(self):
        return ("namespace(implementation=" + repr(self.implementation) + ", monotonic=" + repr(self.monotonic) +
                ", adjustable=" + repr(self.adjustable) + ", resolution=" + repr(self.resolution) + ")")


def get_clock_info(name):
    """Get information of the specified clock."""
    if name == "time":
        return _ClockInfo("clock_gettime(CLOCK_REALTIME)", false, true, 1e-09)
    if name == "monotonic" or name == "perf_counter":
        return _ClockInfo("clock_gettime(CLOCK_MONOTONIC)", true, false, 1e-09)
    if name == "process_time" or name == "thread_time":
        return _ClockInfo("clock_gettime(CLOCK_PROCESS_CPUTIME_ID)", true, false, 1e-09)
    raise ValueError("unknown clock")


# ── conversions ──
def gmtime(secs=none):
    """Convert seconds since the Epoch to a time tuple expressing UTC."""
    var s = _secs(secs)
    return _from_map(time_gmtime(s), "GMT", 0)


def localtime(secs=none):
    """Convert seconds since the Epoch to a time tuple expressing local time."""
    var s = _secs(secs)
    var m = time_localtime(s)
    var whole = s // 1
    var gmtoff = int(time_timegm(m) - whole)
    return _from_map(m, time_strftime("%Z", whole), gmtoff)


def _tuple_arg(t, fn):
    if isinstance(t, struct_time):
        return t
    if not (isinstance(t, tuple) or isinstance(t, list)):
        raise TypeError("Tuple or struct_time argument required")
    if len(t) != 9:
        raise TypeError(fn + "(): illegal time tuple argument")
    for x in t:
        if not isinstance(x, int):
            raise TypeError("'" + type(x).__name__ + "' object cannot be interpreted as an integer")
    return t


def mktime(t):
    """Convert a time tuple in local time to seconds since the Epoch."""
    t = _tuple_arg(t, "mktime")
    return float(time_mktime(_to_map(t)))


def _checked(t):
    # time.strftime's checktm: out-of-range fields are ValueErrors; a zero
    # month, day of month or day of year stands for the first
    var y = t[0]
    var mon = t[1]
    var mday = t[2]
    var yday = t[7]
    var isdst = t[8]
    if mon == 0:
        mon = 1
    elif mon < 0 or mon > 12:
        raise ValueError("month out of range")
    if mday == 0:
        mday = 1
    elif mday < 0 or mday > 31:
        raise ValueError("day of month out of range")
    if t[3] < 0 or t[3] > 23:
        raise ValueError("hour out of range")
    if t[4] < 0 or t[4] > 59:
        raise ValueError("minute out of range")
    if t[5] < 0 or t[5] > 61:
        raise ValueError("seconds out of range")
    if t[6] < 0:
        raise ValueError("day of week out of range")
    if yday == 0:
        yday = 1
    elif yday < 0 or yday > 366:
        raise ValueError("day of year out of range")
    if isdst < -1:
        isdst = -1
    elif isdst > 1:
        isdst = 1
    return {"year": y, "month": mon, "day": mday, "hour": t[3], "minute": t[4],
            "second": t[5], "weekday": t[6] % 7, "yearday": yday, "isdst": isdst}


def _offset_text(gmtoff, colon):
    var sign = "+"
    var off = gmtoff
    if off < 0:
        sign = "-"
        off = -off
    var hh = off // 3600
    var mm = (off % 3600) // 60
    return sign + ("%02d" % hh) + (":" if colon else "") + ("%02d" % mm)


def strftime(format, t=none, utc=false):
    """Convert a time tuple to a string according to a format specification."""
    if not isinstance(format, str):
        raise TypeError("strftime() argument 1 must be str, not " + type(format).__name__)
    if t is none:
        t = localtime()
    elif (isinstance(t, int) or isinstance(t, float)) and not isinstance(t, bool):
        # the old time.strftime(fmt, secs, utc) builtin
        return time_strftime(format, t, utc)
    t = _tuple_arg(t, "strftime")
    var m = _checked(t)
    # %z and %Z from the tuple's zone, as CPython hands tm_zone/tm_gmtoff on
    var zone = getattr(t, "tm_zone", none)
    var gmtoff = getattr(t, "tm_gmtoff", none)
    if zone is none or gmtoff is none:
        var lt = localtime(mktime(t)) if t[8] >= 0 else localtime()
        if zone is none:
            zone = lt.tm_zone if t[8] >= 0 else ""
        if gmtoff is none:
            gmtoff = lt.tm_gmtoff
    var out = []
    var i = 0
    var n = len(format)
    var plain = ""
    while i < n:
        var ch = format[i]
        if ch == "%" and i + 1 < n:
            var d = format[i + 1]
            if d == "z" or d == "Z":
                if len(plain) > 0:
                    out.append(time_strftime(plain, m))
                    plain = ""
                out.append(_offset_text(gmtoff, false) if d == "z" else zone)
                i = i + 2
                continue
            plain = plain + ch + d
            i = i + 2
            continue
        plain = plain + ch
        i = i + 1
    if len(plain) > 0:
        out.append(time_strftime(plain, m))
    return "".join(out)


_DAYNAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
_MONTHNAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def asctime(t=none):
    """Convert a time tuple to a string, e.g. 'Sat Jun 06 16:26:11 1998'."""
    if t is none:
        t = localtime()
    t = _tuple_arg(t, "asctime")
    var m = _checked(t)
    return "%s %s%3d %.2d:%.2d:%.2d %d" % (_DAYNAMES[m["weekday"] % 7], _MONTHNAMES[m["month"] - 1],
                                           m["day"], m["hour"], m["minute"], m["second"], m["year"])


def ctime(secs=none):
    """Convert a time in seconds since the Epoch to a string in local time."""
    return asctime(localtime(secs))


# ── the local zone ──
def _zone_info():
    var year = 365 * 24 * 3600 + 6 * 3600
    var t = (time_now() // year) * year
    var jan = localtime(t)
    var jul = localtime(t + year // 2)
    var janzone = -jan.tm_gmtoff
    var julzone = -jul.tm_gmtoff
    if janzone < julzone:
        return [julzone, janzone, 1 if janzone != julzone else 0, (jul.tm_zone, jan.tm_zone)]
    return [janzone, julzone, 1 if janzone != julzone else 0, (jan.tm_zone, jul.tm_zone)]


_zi = _zone_info()
timezone = _zi[0]
altzone = _zi[1]
daylight = _zi[2]
tzname = _zi[3]


def tzset():
    """Initialize, or reinitialize, the local timezone from the TZ variable."""
    return none


# ── strptime (Lib/_strptime.py, C locale) ──
_A_WEEKDAY = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
_F_WEEKDAY = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
_A_MONTH = ["", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
_F_MONTH = ["", "january", "february", "march", "april", "may", "june", "july", "august",
            "september", "october", "november", "december"]
_AM_PM = ["am", "pm"]
_DIGITS = "0123456789"


def _d(s, i):
    return i < len(s) and s[i] in _DIGITS


def _alts(directive):
    # TimeRE's patterns as ordered alternatives; each entry is a list of
    # character classes ("d" a digit, "05" a digit in that range, a literal
    # character) - the order is the regex's, so the match is the same
    if directive == "d":
        return [["3", "01"], ["12", "d"], ["0", "19"], ["19"], [" ", "19"]]
    if directive == "f":
        return [["d", "d", "d", "d", "d", "d"], ["d", "d", "d", "d", "d"], ["d", "d", "d", "d"],
                ["d", "d", "d"], ["d", "d"], ["d"]]
    if directive == "H":
        return [["2", "03"], ["01", "d"], ["d"]]
    if directive == "I":
        return [["1", "02"], ["0", "19"], ["19"]]
    if directive == "G" or directive == "Y":
        return [["d", "d", "d", "d"]]
    if directive == "j":
        return [["3", "6", "06"], ["3", "05", "d"], ["12", "d", "d"], ["0", "19", "d"], ["0", "0", "19"],
                ["19", "d"], ["0", "19"], ["19"]]
    if directive == "m":
        return [["1", "02"], ["0", "19"], ["19"]]
    if directive == "M":
        return [["05", "d"], ["d"]]
    if directive == "S":
        return [["6", "01"], ["05", "d"], ["d"]]
    if directive == "U" or directive == "W":
        return [["5", "03"], ["04", "d"], ["d"]]
    if directive == "w":
        return [["06"]]
    if directive == "u":
        return [["17"]]
    if directive == "V":
        return [["5", "03"], ["0", "19"], ["14", "d"], ["d"]]
    if directive == "y":
        return [["d", "d"]]
    return none


def _class_ok(cls, c):
    if cls == "d":
        return c in _DIGITS
    if len(cls) == 2 and cls[0] in _DIGITS and cls[1] in _DIGITS:
        return c in _DIGITS and cls[0] <= c and c <= cls[1]
    return c == cls


def _match_len(alt, s, i):
    if i + len(alt) > len(s):
        return -1
    for k in range(len(alt)):
        if not _class_ok(alt[k], s[i + k]):
            return -1
    return len(alt)


def _words_by_length(words):
    var ws = [w for w in words if len(w) > 0]
    return sorted(ws, key=lambda w: -len(w))


_ALTS = {}
for _dk in "dfHIGYjmMSUWwuVy":
    _ALTS[_dk] = _alts(_dk)
_WORDS = {"a": _words_by_length(_A_WEEKDAY), "A": _words_by_length(_F_WEEKDAY),
          "b": _words_by_length(_A_MONTH), "B": _words_by_length(_F_MONTH), "p": _words_by_length(_AM_PM)}
_TOKENS = {}


def _sixty(s, i):
    # [0-5]\d at s[i]
    return i < len(s) and s[i] in "012345" and _d(s, i + 1)


def _z_lengths(s, i):
    # (?P<z>[+-]\d\d:?[0-5]\d(:?[0-5]\d(\.\d{1,6})?)?|(?-i:Z)), its
    # lengths in the order a backtracking regex tries them
    var out = []
    if i < len(s) and s[i] == "Z":
        return [1]
    if not (i < len(s) and (s[i] == "+" or s[i] == "-") and _d(s, i + 1) and _d(s, i + 2)):
        return out
    for c1 in [true, false]:
        var j = i + 3
        if c1:
            if not (j < len(s) and s[j] == ":"):
                continue
            j = j + 1
        if not _sixty(s, j):
            continue
        j = j + 2
        # the optional seconds group (greedy: tried first)
        for c2 in [true, false]:
            var k = j
            if c2:
                if not (k < len(s) and s[k] == ":"):
                    continue
                k = k + 1
            if not _sixty(s, k):
                continue
            k = k + 2
            if k < len(s) and s[k] == "." and _d(s, k + 1):
                var q = k + 1
                var nd = 0
                while nd < 6 and _d(s, q):
                    q = q + 1
                    nd = nd + 1
                while q > k + 1:
                    out.append(q - i)
                    q = q - 1
            out.append(k - i)
        out.append(j - i)
    return out


class _NyStrptime:
    def __init__(self, data, fmt):
        self.data = data
        self.low = data.lower()
        self.fmt = fmt
        self.found = {}

    def candidates(self, directive, i):
        # the lengths one directive can match at data[i], in the order the
        # regex alternatives would try them
        var s = self.data
        var out = []
        var alts = _ALTS.get(directive)
        if alts is not none:
            for alt in alts:
                var n = _match_len(alt, s, i)
                if n > 0:
                    out.append(n)
            return out
        if directive == "z":
            return _z_lengths(s, i)
        var words = _WORDS.get(directive)
        if directive == "Z":
            var zs = ["utc", "gmt"]
            for z in tzname:
                zs.append(z.lower())
            words = _words_by_length(zs)
        if words is none:
            return out
        for w in words:
            if self.low[i:i + len(w)] == w:
                out.append(len(w))
        return out

    def tokens(self):
        # the format as [kind, value]: "%" directives, "ws" runs, literals
        var f = self.fmt
        var out = []
        var i = 0
        while i < len(f):
            var ch = f[i]
            if ch == "%":
                if i + 1 >= len(f):
                    raise ValueError("stray % in format '" + f + "'")
                var d = f[i + 1]
                if d == "c":
                    out = out + _NyStrptime("", "%a %b %d %H:%M:%S %Y").tokens()
                elif d == "x":
                    out = out + _NyStrptime("", "%m/%d/%y").tokens()
                elif d == "X":
                    out = out + _NyStrptime("", "%H:%M:%S").tokens()
                elif d == "%":
                    out.append(["lit", "%"])
                elif d in "dfHIGYjmMSUWwuVyaAbBpZz":
                    out.append(["dir", d])
                else:
                    raise ValueError("'" + d + "' is a bad directive in format '" + f + "'")
                i = i + 2
            elif ch.isspace():
                while i < len(f) and f[i].isspace():
                    i = i + 1
                out.append(["ws", ""])
            else:
                out.append(["lit", ch])
                i = i + 1
        return out

    def match(self, toks, t, i):
        # the end index of a match of toks[t:] at data[i], or -1; found
        # holds the directives' texts of the successful path
        var s = self.data
        if t == len(toks):
            return i
        var kind = toks[t][0]
        var val = toks[t][1]
        if kind == "lit":
            if i < len(s) and s[i].lower() == val.lower():
                return self.match(toks, t + 1, i + 1)
            return -1
        if kind == "ws":
            var j = i
            while j < len(s) and s[j].isspace():
                j = j + 1
            while j > i:
                var r = self.match(toks, t + 1, j)
                if r >= 0:
                    return r
                j = j - 1
            return -1
        for n in self.candidates(val, i):
            var r2 = self.match(toks, t + 1, i + n)
            if r2 >= 0:
                self.found[val] = s[i:i + n]
                return r2
        return -1


def _calc_julian_from_U_or_W(year, week_of_year, day_of_week, week_starts_Mon):
    var first_weekday = _weekday0(year, 1, 1)
    if not week_starts_Mon:
        first_weekday = (first_weekday + 1) % 7
        day_of_week = (day_of_week + 1) % 7
    var week_0_length = (7 - first_weekday) % 7
    if week_of_year == 0:
        return 1 + day_of_week - first_weekday
    var days_to_week = week_0_length + (7 * (week_of_year - 1))
    return 1 + days_to_week + day_of_week


def _is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


_DBM = [0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


def _ord(y, m, d):
    var p = y - 1
    return p * 365 + p // 4 - p // 100 + p // 400 + _DBM[m] + (1 if m > 2 and _is_leap(y) else 0) + d


def _weekday0(y, m, d):
    return (_ord(y, m, d) + 6) % 7


def _ymd_of_ord(n):
    # date.fromordinal
    n = n - 1
    var n400 = n // 146097
    n = n % 146097
    var year = n400 * 400 + 1
    var n100 = n // 36524
    n = n % 36524
    var n4 = n // 1461
    n = n % 1461
    var n1 = n // 365
    n = n % 365
    year = year + n100 * 100 + n4 * 4 + n1
    if n1 == 4 or n100 == 4:
        return [year - 1, 12, 31]
    var month = 1
    var leap = _is_leap(year)
    while month < 12:
        var nxt = _DBM[month + 1] + (1 if month + 1 > 2 and leap else 0)
        if nxt > n:
            break
        month = month + 1
    return [year, month, n - (_DBM[month] + (1 if month > 2 and leap else 0)) + 1]


def _days_in_month(y, m):
    if m == 2:
        return 29 if _is_leap(y) else 28
    return [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m]


def _strptime(data_string, format="%a %b %d %H:%M:%S %Y"):
    # Lib/_strptime.py's _strptime: (the 11-field tuple, fraction, gmtoff_fraction)
    if not isinstance(data_string, str):
        raise TypeError("strptime() argument 0 must be str, not " + repr(type(data_string)))
    if not isinstance(format, str):
        raise TypeError("strptime() argument 1 must be str, not " + repr(type(format)))
    var p = _NyStrptime(data_string, format)
    # a format's tokens are kept, as _strptime keeps its compiled regexes
    var toks = _TOKENS.get(format)
    if toks is none:
        toks = p.tokens()
        if len(_TOKENS) > 100:
            _TOKENS.clear()
        _TOKENS[format] = toks
    # the regex is matched at the start (re.match): the longest prefix the
    # first successful path reaches, then "unconverted data remains"
    var end = p.match(toks, 0, 0)
    if end < 0:
        raise ValueError("time data " + repr(data_string) + " does not match format " + repr(format))
    if end != len(data_string):
        raise ValueError("unconverted data remains: " + data_string[end:])
    var found = p.found
    # the directives in the format's order (a regex's groupdict order)
    var order = []
    for tok in toks:
        if tok[0] == "dir" and tok[1] in found and not (tok[1] in order):
            order.append(tok[1])
    var iso_year = none
    var year = none
    var month = 1
    var day = 1
    var hour = 0
    var minute = 0
    var second = 0
    var fraction = 0
    var tz = -1
    var gmtoff = none
    var gmtoff_fraction = 0
    var iso_week = none
    var week_of_year = none
    var week_of_year_start = none
    var weekday = none
    var julian = none
    for key in order:
        var v = found[key]
        if key == "y":
            year = int(v)
            year = year + 2000 if year <= 68 else year + 1900
        elif key == "Y":
            year = int(v)
        elif key == "G":
            iso_year = int(v)
        elif key == "m":
            month = int(v)
        elif key == "B":
            month = _F_MONTH.index(v.lower())
        elif key == "b":
            month = _A_MONTH.index(v.lower())
        elif key == "d":
            day = int(v)
        elif key == "H":
            hour = int(v)
        elif key == "I":
            hour = int(v)
            var ampm = found.get("p", "").lower()
            if ampm == "" or ampm == "am":
                if hour == 12:
                    hour = 0
            elif ampm == "pm":
                if hour != 12:
                    hour = hour + 12
        elif key == "M":
            minute = int(v)
        elif key == "S":
            second = int(v)
        elif key == "f":
            fraction = int(v + "0" * (6 - len(v)))
        elif key == "A":
            weekday = _F_WEEKDAY.index(v.lower())
        elif key == "a":
            weekday = _A_WEEKDAY.index(v.lower())
        elif key == "w":
            weekday = int(v)
            weekday = 6 if weekday == 0 else weekday - 1
        elif key == "u":
            weekday = int(v) - 1
        elif key == "j":
            julian = int(v)
        elif key == "U" or key == "W":
            week_of_year = int(v)
            week_of_year_start = 6 if key == "U" else 0
        elif key == "V":
            iso_week = int(v)
        elif key == "z":
            var z = v
            if z == "Z":
                gmtoff = 0
            else:
                if z[3] == ":":
                    z = z[:3] + z[4:]
                    if len(z) > 5:
                        if z[5] != ":":
                            raise ValueError("Inconsistent use of : in " + v)
                        z = z[:5] + z[6:]
                var hours = int(z[1:3])
                var minutes = int(z[3:5])
                var seconds = int(z[5:7]) if len(z[5:7]) > 0 else 0
                gmtoff = (hours * 60 * 60) + (minutes * 60) + seconds
                var rem = z[8:]
                gmtoff_fraction = int(rem + "0" * (6 - len(rem)))
                if z.startswith("-"):
                    gmtoff = -gmtoff
                    gmtoff_fraction = -gmtoff_fraction
        elif key == "Z":
            var fz = v.lower()
            if fz == "utc" or fz == "gmt" or fz == tzname[0].lower():
                tz = 0
            elif daylight and fz == tzname[1].lower():
                tz = 1
            if tzname[0] == tzname[1] and daylight and fz != "utc" and fz != "gmt":
                tz = -1
    if year is none and iso_year is not none:
        if iso_week is none or weekday is none:
            raise ValueError("ISO year directive '%G' must be used with the ISO week directive '%V' and a weekday directive ('%A', '%a', '%w', or '%u').")
        if julian is not none:
            raise ValueError("Day of the year directive '%j' is not compatible with ISO year directive '%G'. Use '%Y' instead.")
    elif week_of_year is none and iso_week is not none:
        if weekday is none:
            raise ValueError("ISO week directive '%V' must be used with the ISO year directive '%G' and a weekday directive ('%A', '%a', '%w', or '%u').")
        raise ValueError("ISO week directive '%V' is incompatible with the year directive '%Y'. Use the ISO year '%G' instead.")
    var leap_year_fix = false
    if year is none and month == 2 and day == 29:
        year = 1904
        leap_year_fix = true
    elif year is none:
        year = 1900
    if julian is none and weekday is not none:
        if week_of_year is not none:
            julian = _calc_julian_from_U_or_W(year, week_of_year, weekday, week_of_year_start == 0)
        elif iso_year is not none and iso_week is not none:
            var first = _ord(iso_year, 1, 1)
            var fwd = (first + 6) % 7
            var w1 = first - fwd + (7 if fwd > 3 else 0)
            var ymd = _ymd_of_ord(w1 + (iso_week - 1) * 7 + weekday)
            year = ymd[0]
            month = ymd[1]
            day = ymd[2]
        if julian is not none and julian <= 0:
            year = year - 1
            julian = julian + (366 if _is_leap(year) else 365)
    if julian is none:
        if day > _days_in_month(year, month):
            raise ValueError("day is out of range for month")
        julian = _ord(year, month, day) - _ord(year, 1, 1) + 1
    else:
        var ymd2 = _ymd_of_ord((julian - 1) + _ord(year, 1, 1))
        year = ymd2[0]
        month = ymd2[1]
        day = ymd2[2]
    if weekday is none:
        weekday = _weekday0(year, month, day)
    var tzn = found.get("Z")
    if leap_year_fix:
        year = 1900
    return [(year, month, day, hour, minute, second, weekday, julian, tz, tzn, gmtoff), fraction, gmtoff_fraction]


def strptime(string, format="%a %b %d %H:%M:%S %Y"):
    """Parse a string to a time tuple according to a format specification."""
    var r = _strptime(string, format)
    return struct_time(r[0])


# CPython's time functions are builtins, which a class does not bind: a
# class attribute `converter = time.gmtime` (logging.Formatter) is called
# with the seconds alone. Ours are Nython functions, so they are wrapped as
# staticmethods - callable as they are, never bound to an instance.
time = staticmethod(time)
time_ns = staticmethod(time_ns)
sleep = staticmethod(sleep)
monotonic = staticmethod(monotonic)
monotonic_ns = staticmethod(monotonic_ns)
perf_counter = staticmethod(perf_counter)
perf_counter_ns = staticmethod(perf_counter_ns)
process_time = staticmethod(process_time)
process_time_ns = staticmethod(process_time_ns)
thread_time = staticmethod(thread_time)
thread_time_ns = staticmethod(thread_time_ns)
gmtime = staticmethod(gmtime)
localtime = staticmethod(localtime)
mktime = staticmethod(mktime)
strftime = staticmethod(strftime)
strptime = staticmethod(strptime)
asctime = staticmethod(asctime)
ctime = staticmethod(ctime)
