# nython: module    (import it by name: it runs in a module scope of its own)
# lib/datetime.ny - Python's datetime module (CPython 3.12's Lib/_pydatetime.py
# algorithms, with the messages of its C implementation, _datetimemodule.c,
# which is what Python programs see).
#
#     from datetime import date, time, datetime, timedelta, timezone
#     datetime(2024, 1, 2, 3, 4, 5) + timedelta(days=1, hours=2)
#     datetime.strptime("2024-01-02 03:04", "%Y-%m-%d %H:%M").isoformat()
#     datetime.now(timezone.utc).astimezone(timezone(timedelta(hours=5, minutes=30)))
#
# timedelta  days/seconds/microseconds normalisation (floats rounded half to
#            even, as Python), + - * / // % divmod abs, total_seconds,
#            comparisons, str ("-1 day, 23:00:00") and repr, min/max/resolution
# date       today, fromtimestamp, fromordinal, fromisoformat,
#            fromisocalendar, toordinal, weekday, isoweekday, isocalendar
#            (IsoCalendarDate), isoformat, strftime/__format__, ctime,
#            timetuple, replace, arithmetic and comparisons
# time       hour..microsecond, tzinfo, fold, isoformat(timespec),
#            fromisoformat, strftime, utcoffset/dst/tzname, replace
# datetime   now/utcnow/today, fromtimestamp(ts, tz), utcfromtimestamp,
#            combine, strptime, fromisoformat (3.11 rules), timestamp,
#            astimezone, utctimetuple, date()/time()/timetz(), arithmetic
#            with timedelta, subtraction, comparisons (aware vs naive:
#            == is False, < is a TypeError), fold-aware local time
# tzinfo, timezone (utc, fixed offsets, names, "UTC+05:30"), UTC,
# MINYEAR, MAXYEAR
#
# Reprs are Python's ("datetime.datetime(2024, 1, 2, 3, 4, 5)",
# "datetime.timedelta(days=1, seconds=3600)"); strftime goes through
# time.strftime (the C library's, as CPython's does), strptime is
# lib/time.ny's port of _strptime.
#
# Differences from Python: classes are made by __init__ (Nython has no
# __new__), so timezone(timedelta(0)) is an object equal to timezone.utc
# rather than that same object; there is no pickling support; the objects'
# fields are read-only properties (assigning raises AttributeError, with
# Nython's wording).
import time as _time
import math

__all__ = ["date", "datetime", "time", "timedelta", "timezone", "tzinfo", "MINYEAR", "MAXYEAR", "UTC"]

MINYEAR = 1
MAXYEAR = 9999
_MAXORDINAL = 3652059

_DAYS_IN_MONTH = [-1, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
_DAYS_BEFORE_MONTH = [-1, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
_MONTHNAMES = [none, "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
_DAYNAMES = [none, "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def _cmp(x, y):
    return 0 if x == y else (1 if x > y else -1)


def _same(a, b):
    # identity (Nython's `is` tests membership, not identity)
    if a is none or b is none:
        return a is none and b is none
    return id(a) == id(b)


def _tname(o):
    # Python's type name for messages: 'datetime.date' for this module's types
    var n = type(o).__name__
    if n == "date" or n == "datetime" or n == "time" or n == "timedelta" or n == "timezone" or n == "tzinfo":
        return "datetime." + n
    return n


def _cls_name(self):
    # the name a repr starts with: "datetime.date" for this module's own
    # classes, the bare class name for a subclass (as the C type's tp_name)
    var c = self.__class__
    if c == timedelta or c == date or c == datetime or c == time or c == timezone:
        return "datetime." + c.__name__
    return c.__name__


def _index(x):
    if isinstance(x, bool):
        return 1 if x else 0
    if isinstance(x, int):
        return x
    if hasattr(x, "__index__"):
        return x.__index__()
    raise TypeError("'" + type(x).__name__ + "' object cannot be interpreted as an integer")


def _is_leap(year):
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def _days_before_year(year):
    var y = year - 1
    return y * 365 + y // 4 - y // 100 + y // 400


def _days_in_month(year, month):
    if month == 2 and _is_leap(year):
        return 29
    return _DAYS_IN_MONTH[month]


def _days_before_month(year, month):
    return _DAYS_BEFORE_MONTH[month] + (1 if month > 2 and _is_leap(year) else 0)


def _ymd2ord(year, month, day):
    return _days_before_year(year) + _days_before_month(year, month) + day


_DI400Y = _days_before_year(401)
_DI100Y = _days_before_year(101)
_DI4Y = _days_before_year(5)


def _ord2ymd(n):
    n = n - 1
    var n400 = n // _DI400Y
    n = n % _DI400Y
    var year = n400 * 400 + 1
    var n100 = n // _DI100Y
    n = n % _DI100Y
    var n4 = n // _DI4Y
    n = n % _DI4Y
    var n1 = n // 365
    n = n % 365
    year = year + n100 * 100 + n4 * 4 + n1
    if n1 == 4 or n100 == 4:
        return [year - 1, 12, 31]
    var leapyear = n1 == 3 and (n4 != 24 or n100 == 3)
    var month = (n + 50) >> 5
    var preceding = _DAYS_BEFORE_MONTH[month] + (1 if month > 2 and leapyear else 0)
    if preceding > n:
        month = month - 1
        preceding = preceding - (_DAYS_IN_MONTH[month] + (1 if month == 2 and leapyear else 0))
    n = n - preceding
    return [year, month, n + 1]


def _isoweek1monday(year):
    var firstday = _ymd2ord(year, 1, 1)
    var firstweekday = (firstday + 6) % 7
    var week1monday = firstday - firstweekday
    if firstweekday > 3:
        week1monday = week1monday + 7
    return week1monday


def _build_struct_time(y, m, d, hh, mm, ss, dstflag):
    var wday = (_ymd2ord(y, m, d) + 6) % 7
    var dnum = _days_before_month(y, m) + d
    return _time.struct_time((y, m, d, hh, mm, ss, wday, dnum, dstflag))


def _format_time(hh, mm, ss, us, timespec="auto"):
    if timespec == "auto":
        timespec = "microseconds" if us else "seconds"
    elif timespec == "milliseconds":
        us = us // 1000
    if timespec == "hours":
        return "%02d" % hh
    if timespec == "minutes":
        return "%02d:%02d" % (hh, mm)
    if timespec == "seconds":
        return "%02d:%02d:%02d" % (hh, mm, ss)
    if timespec == "milliseconds":
        return "%02d:%02d:%02d.%03d" % (hh, mm, ss, us)
    if timespec == "microseconds":
        return "%02d:%02d:%02d.%06d" % (hh, mm, ss, us)
    raise ValueError("Unknown timespec value")


def _format_offset(off, sep=":"):
    var s = ""
    if off is not none:
        var sign = "+"
        if off.days < 0:
            sign = "-"
            off = -off
        var hm = off.__divmod__(timedelta(hours=1))
        var ms = hm[1].__divmod__(timedelta(minutes=1))
        var ss = ms[1]
        s = s + "%s%02d%s%02d" % (sign, hm[0], sep, ms[0])
        if ss or ss.microseconds:
            s = s + "%s%02d" % (sep, ss.seconds)
            if ss.microseconds:
                s = s + ".%06d" % ss.microseconds
    return s


def _wrap_strftime(obj, format, timetuple):
    # %f, %z, %:z and %Z from the object; the rest is time.strftime's
    if not isinstance(format, str):
        raise TypeError("strftime() argument 1 must be str, not " + type(format).__name__)
    var freplace = none
    var zreplace = none
    var colonzreplace = none
    var Zreplace = none
    var newformat = []
    var i = 0
    var n = len(format)
    while i < n:
        var ch = format[i]
        i = i + 1
        if ch == "%":
            if i < n:
                ch = format[i]
                i = i + 1
                if ch == "f":
                    if freplace is none:
                        freplace = "%06d" % getattr(obj, "microsecond", 0)
                    newformat.append(freplace)
                elif ch == "z":
                    if zreplace is none:
                        zreplace = _format_offset(obj.utcoffset(), "") if hasattr(obj, "utcoffset") else ""
                    newformat.append(zreplace)
                elif ch == ":":
                    if i < n:
                        var ch2 = format[i]
                        i = i + 1
                        if ch2 == "z":
                            if colonzreplace is none:
                                colonzreplace = _format_offset(obj.utcoffset(), ":") if hasattr(obj, "utcoffset") else ""
                            newformat.append(colonzreplace)
                        else:
                            newformat.append("%")
                            newformat.append(ch)
                            newformat.append(ch2)
                elif ch == "Z":
                    if Zreplace is none:
                        Zreplace = ""
                        if hasattr(obj, "tzname"):
                            var s = obj.tzname()
                            if s is not none:
                                Zreplace = s.replace("%", "%%")
                    newformat.append(Zreplace)
                else:
                    newformat.append("%")
                    newformat.append(ch)
            else:
                newformat.append("%")
        else:
            newformat.append(ch)
    return _time.strftime("".join(newformat), timetuple)


def _is_ascii_digit(c):
    return c in "0123456789"


def _find_isoformat_datetime_separator(dtstr):
    var len_dtstr = len(dtstr)
    if len_dtstr == 7:
        return 7
    if dtstr[4] == "-":
        if dtstr[5] == "W":
            if len_dtstr < 8:
                raise ValueError("Invalid ISO string")
            if len_dtstr > 8 and dtstr[8] == "-":
                if len_dtstr == 9:
                    raise ValueError("Invalid ISO string")
                if len_dtstr > 10 and _is_ascii_digit(dtstr[10]):
                    return 8
                return 10
            return 8
        return 10
    if dtstr[4] == "W":
        var idx = 7
        while idx < len_dtstr:
            if not _is_ascii_digit(dtstr[idx]):
                break
            idx = idx + 1
        if idx < 9:
            return idx
        if idx % 2 == 0:
            return 7
        return 8
    return 8


def _int_digits(s):
    # int() of an all-ASCII-digit string, else ValueError
    if len(s) == 0:
        raise ValueError("empty")
    for c in s:
        if not _is_ascii_digit(c):
            raise ValueError("not a digit")
    return int(s)


def _parse_isoformat_date(dtstr):
    if not (len(dtstr) == 7 or len(dtstr) == 8 or len(dtstr) == 10):
        raise ValueError("bad length")
    var year = _int_digits(dtstr[0:4])
    var has_sep = 1 if dtstr[4] == "-" else 0
    var pos = 4 + has_sep
    if dtstr[pos:pos + 1] == "W":
        pos = pos + 1
        var weekno = _int_digits(dtstr[pos:pos + 2])
        pos = pos + 2
        var dayno = 1
        if len(dtstr) > pos:
            if (dtstr[pos:pos + 1] == "-") != (has_sep == 1):
                raise ValueError("Inconsistent use of dash separator")
            pos = pos + has_sep
            dayno = _int_digits(dtstr[pos:pos + 1])
        return ["W", year, weekno, dayno]
    var month = _int_digits(dtstr[pos:pos + 2])
    pos = pos + 2
    if (dtstr[pos:pos + 1] == "-") != (has_sep == 1):
        raise ValueError("Inconsistent use of dash separator")
    pos = pos + has_sep
    var day = _int_digits(dtstr[pos:pos + 2])
    if len(dtstr[pos:pos + 2]) != 2:
        raise ValueError("bad day")
    return [year, month, day]


_FRACTION_CORRECTION = [100000, 10000, 1000, 100, 10]


def _parse_hh_mm_ss_ff(tstr):
    var len_str = len(tstr)
    var time_comps = [0, 0, 0, 0]
    var pos = 0
    var has_sep = false
    for comp in range(0, 3):
        if (len_str - pos) < 2:
            raise ValueError("Incomplete time component")
        time_comps[comp] = _int_digits(tstr[pos:pos + 2])
        pos = pos + 2
        var next_char = tstr[pos:pos + 1]
        if comp == 0:
            has_sep = next_char == ":"
        if not next_char or comp >= 2:
            break
        if has_sep and next_char != ":":
            raise ValueError("Invalid time separator: " + next_char)
        pos = pos + (1 if has_sep else 0)
    if pos < len_str:
        if not (tstr[pos] == "." or tstr[pos] == ","):
            raise ValueError("Invalid microsecond component")
        pos = pos + 1
        var len_remainder = len_str - pos
        var to_parse = 6 if len_remainder >= 6 else len_remainder
        time_comps[3] = _int_digits(tstr[pos:(pos + to_parse)])
        if to_parse < 6:
            time_comps[3] = time_comps[3] * _FRACTION_CORRECTION[to_parse - 1]
        if len_remainder > to_parse:
            for c in tstr[(pos + to_parse):]:
                if not _is_ascii_digit(c):
                    raise ValueError("Non-digit values in unparsed fraction")
    return time_comps


def _parse_isoformat_time(tstr):
    var len_str = len(tstr)
    if len_str < 2:
        raise ValueError("Isoformat time too short")
    var tz_pos = tstr.find("-") + 1
    if tz_pos == 0:
        tz_pos = tstr.find("+") + 1
    if tz_pos == 0:
        tz_pos = tstr.find("Z") + 1
    var timestr = tstr[:tz_pos - 1] if tz_pos > 0 else tstr
    var time_comps = _parse_hh_mm_ss_ff(timestr)
    var tzi = none
    if tz_pos == len_str and tstr[-1] == "Z":
        tzi = timezone.utc
    elif tz_pos > 0:
        var tzstr = tstr[tz_pos:]
        if len(tzstr) == 0 or len(tzstr) == 1 or len(tzstr) == 3:
            raise ValueError("Malformed time zone string")
        var tz_comps = _parse_hh_mm_ss_ff(tzstr)
        if tz_comps[0] == 0 and tz_comps[1] == 0 and tz_comps[2] == 0 and tz_comps[3] == 0:
            tzi = timezone.utc
        else:
            var tzsign = -1 if tstr[tz_pos - 1] == "-" else 1
            var td = timedelta(hours=tz_comps[0], minutes=tz_comps[1],
                               seconds=tz_comps[2], microseconds=tz_comps[3])
            tzi = timezone(tzsign * td)
    time_comps.append(tzi)
    return time_comps


def _isoweek_to_gregorian(year, week, day):
    if not (MINYEAR <= year and year <= MAXYEAR):
        raise ValueError("Year is out of range: " + str(year))
    if not (0 < week and week < 53):
        var out_of_range = true
        if week == 53:
            var first_weekday = _ymd2ord(year, 1, 1) % 7
            if first_weekday == 4 or (first_weekday == 3 and _is_leap(year)):
                out_of_range = false
        if out_of_range:
            raise ValueError("Invalid week: " + str(week))
    if not (0 < day and day < 8):
        raise ValueError("Invalid day: " + str(day) + " (range is [1, 7])")
    var day_offset = (week - 1) * 7 + (day - 1)
    var day_1 = _isoweek1monday(year)
    return _ord2ymd(day_1 + day_offset)


def _check_tzname(name):
    if name is not none and not isinstance(name, str):
        raise TypeError("tzinfo.tzname() must return None or a string, not '" + type(name).__name__ + "'")


def _check_utc_offset(name, offset):
    if offset is none:
        return none
    if not isinstance(offset, timedelta):
        raise TypeError("tzinfo." + name + "() must return None or timedelta, not '" + type(offset).__name__ + "'")
    if not (-timedelta(1) < offset and offset < timedelta(1)):
        raise ValueError("offset must be a timedelta strictly between -timedelta(hours=24) and timedelta(hours=24), not " + repr(offset) + ".")
    return none


def _check_date_fields(year, month, day):
    # (ints are taken as they are without calling _index: a hot path)
    if not isinstance(year, int) or isinstance(year, bool):
        year = _index(year)
    if not isinstance(month, int) or isinstance(month, bool):
        month = _index(month)
    if not isinstance(day, int) or isinstance(day, bool):
        day = _index(day)
    if not (MINYEAR <= year and year <= MAXYEAR):
        raise ValueError("year " + str(year) + " is out of range")
    if not (1 <= month and month <= 12):
        raise ValueError("month must be in 1..12")
    if not (1 <= day and day <= _days_in_month(year, month)):
        raise ValueError("day is out of range for month")
    return [year, month, day]


def _check_time_fields(hour, minute, second, microsecond, fold):
    if not isinstance(hour, int) or isinstance(hour, bool):
        hour = _index(hour)
    if not isinstance(minute, int) or isinstance(minute, bool):
        minute = _index(minute)
    if not isinstance(second, int) or isinstance(second, bool):
        second = _index(second)
    if not isinstance(microsecond, int) or isinstance(microsecond, bool):
        microsecond = _index(microsecond)
    if not (0 <= hour and hour <= 23):
        raise ValueError("hour must be in 0..23")
    if not (0 <= minute and minute <= 59):
        raise ValueError("minute must be in 0..59")
    if not (0 <= second and second <= 59):
        raise ValueError("second must be in 0..59")
    if not (0 <= microsecond and microsecond <= 999999):
        raise ValueError("microsecond must be in 0..999999")
    if not (fold == 0 or fold == 1):
        raise ValueError("fold must be either 0 or 1")
    return [hour, minute, second, microsecond, fold]


def _check_tzinfo_arg(tz):
    if tz is not none and not isinstance(tz, tzinfo):
        raise TypeError("tzinfo argument must be None or of a tzinfo subclass, not type '" + type(tz).__name__ + "'")


def _divide_and_round(a, b):
    var qr = divmod(a, b)
    var q = qr[0]
    var r = qr[1] * 2
    var greater_than_half = (r > b) if b > 0 else (r < b)
    if greater_than_half or (r == b and q % 2 == 1):
        q = q + 1
    return q


def _binop_error(op, a, b):
    raise TypeError("unsupported operand type(s) for " + op + ": '" + _tname(a) + "' and '" + _tname(b) + "'")


def _order_error(op, a, b):
    raise TypeError("'" + op + "' not supported between instances of '" + _tname(a) + "' and '" + _tname(b) + "'")


# ── timedelta ────────────────────────────────────────────────────────────────
class timedelta:
    """Represent the difference between two datetime objects.

    Supported operators: add, subtract timedelta; unary plus, minus, abs;
    compare to timedelta; multiply, divide by int.

    Representation: (days, seconds, microseconds).
    """

    def __init__(self, days=0, seconds=0, microseconds=0, milliseconds=0, minutes=0, hours=0, weeks=0):
        if (isinstance(days, int) and isinstance(seconds, int) and isinstance(microseconds, int) and
                isinstance(milliseconds, int) and isinstance(minutes, int) and isinstance(hours, int) and
                isinstance(weeks, int)):
            # all integers (the usual case): exact through total microseconds,
            # the same result as the general path below
            var total = ((((weeks * 7 + days) * 24 + hours) * 60 + minutes) * 60 + seconds) * 1000000 + milliseconds * 1000 + microseconds
            var dd = total // 86400000000
            if dd > 999999999 or dd < -999999999:
                raise OverflowError("days=" + str(dd) + "; must have magnitude <= 999999999")
            var rest = total % 86400000000
            self._days = int(dd)
            self._seconds = int(rest // 1000000)
            self._microseconds = int(rest % 1000000)
            return none
        var names = ["days", "seconds", "microseconds", "milliseconds", "minutes", "hours", "weeks"]
        var vals = [days, seconds, microseconds, milliseconds, minutes, hours, weeks]
        for i in range(7):
            if not (isinstance(vals[i], int) or isinstance(vals[i], float)):
                raise TypeError("unsupported type for timedelta " + names[i] + " component: " + type(vals[i]).__name__)
        var d = 0
        var s = 0
        var us = 0
        days = days + weeks * 7
        seconds = seconds + minutes * 60 + hours * 3600
        microseconds = microseconds + milliseconds * 1000
        var daysecondsfrac = 0.0
        if isinstance(days, float):
            var mf = math.modf(days)
            var dayfrac = mf[0]
            var ds = math.modf(dayfrac * (24.0 * 3600.0))
            daysecondsfrac = ds[0]
            s = int(ds[1])
            d = int(mf[1])
        else:
            d = days
        var secondsfrac = daysecondsfrac
        if isinstance(seconds, float):
            var sf = math.modf(seconds)
            seconds = int(sf[1])
            secondsfrac = sf[0] + daysecondsfrac
        var dv = divmod(seconds, 24 * 3600)
        d = d + dv[0]
        s = s + int(dv[1])
        var usdouble = secondsfrac * 1e6
        if isinstance(microseconds, float):
            microseconds = round(microseconds + usdouble)
            var sv = divmod(microseconds, 1000000)
            var dv2 = divmod(sv[0], 24 * 3600)
            d = d + dv2[0]
            s = s + dv2[1]
            microseconds = sv[1]
        else:
            microseconds = int(microseconds)
            var sv2 = divmod(microseconds, 1000000)
            var dv3 = divmod(sv2[0], 24 * 3600)
            d = d + dv3[0]
            s = s + dv3[1]
            microseconds = round(sv2[1] + usdouble)
        var su = divmod(microseconds, 1000000)
        s = s + su[0]
        us = su[1]
        var ds2 = divmod(s, 24 * 3600)
        d = d + ds2[0]
        s = ds2[1]
        if abs(d) > 999999999:
            raise OverflowError("days=" + str(d) + "; must have magnitude <= 999999999")
        self._days = int(d)
        self._seconds = int(s)
        self._microseconds = int(us)

    def __repr__(self):
        var args = []
        if self._days:
            args.append("days=%d" % self._days)
        if self._seconds:
            args.append("seconds=%d" % self._seconds)
        if self._microseconds:
            args.append("microseconds=%d" % self._microseconds)
        if not args:
            args.append("0")
        return "%s(%s)" % (_cls_name(self), ", ".join(args))

    def __str__(self):
        var mm = self._seconds // 60
        var ss = self._seconds % 60
        var hh = mm // 60
        mm = mm % 60
        var s = "%d:%02d:%02d" % (hh, mm, ss)
        if self._days:
            s = ("%d day%s, " % (self._days, "s" if abs(self._days) != 1 else "")) + s
        if self._microseconds:
            s = s + ".%06d" % self._microseconds
        return s

    def total_seconds(self):
        """Total seconds in the duration."""
        return ((self._days * 86400 + self._seconds) * 10 ** 6 + self._microseconds) / 10 ** 6

    @property
    def days(self):
        """days"""
        return self._days

    @property
    def seconds(self):
        """seconds"""
        return self._seconds

    @property
    def microseconds(self):
        """microseconds"""
        return self._microseconds

    def _to_microseconds(self):
        return (self._days * (24 * 3600) + self._seconds) * 1000000 + self._microseconds

    def __add__(self, other):
        if isinstance(other, timedelta):
            return timedelta(self._days + other._days, self._seconds + other._seconds,
                             self._microseconds + other._microseconds)
        if isinstance(other, _date_class):
            return other.__add__(self)
        _binop_error("+", self, other)

    def __radd__(self, other):
        if isinstance(other, timedelta) or isinstance(other, _date_class):
            return self.__add__(other)
        _binop_error("+", other, self)

    def __sub__(self, other):
        if isinstance(other, timedelta):
            return timedelta(self._days - other._days, self._seconds - other._seconds,
                             self._microseconds - other._microseconds)
        _binop_error("-", self, other)

    def __rsub__(self, other):
        if isinstance(other, timedelta):
            return -self + other
        if isinstance(other, _date_class):
            return other.__sub__(self)
        _binop_error("-", other, self)

    def __neg__(self):
        return timedelta(-self._days, -self._seconds, -self._microseconds)

    def __pos__(self):
        return self

    def __abs__(self):
        if self._days < 0:
            return -self
        return self

    def __mul__(self, other):
        if isinstance(other, int) and not isinstance(other, bool):
            return timedelta(self._days * other, self._seconds * other, self._microseconds * other)
        if isinstance(other, bool):
            return self.__mul__(1 if other else 0)
        if isinstance(other, float):
            var usec = self._to_microseconds()
            var ab = other.as_integer_ratio()
            return timedelta(0, 0, _divide_and_round(usec * ab[0], ab[1]))
        _binop_error("*", self, other)

    def __rmul__(self, other):
        if isinstance(other, int) or isinstance(other, float):
            return self.__mul__(other)
        _binop_error("*", other, self)

    def __floordiv__(self, other):
        if isinstance(other, timedelta):
            var d = other._to_microseconds()
            if d == 0:
                raise ZeroDivisionError("integer division or modulo by zero")
            return self._to_microseconds() // d
        if isinstance(other, int) and not isinstance(other, bool):
            if other == 0:
                raise ZeroDivisionError("integer division or modulo by zero")
            return timedelta(0, 0, self._to_microseconds() // other)
        _binop_error("//", self, other)

    def __truediv__(self, other):
        var usec = self._to_microseconds()
        if isinstance(other, timedelta):
            var d = other._to_microseconds()
            if d == 0:
                raise ZeroDivisionError("division by zero")
            return usec / d
        if isinstance(other, int) and not isinstance(other, bool):
            if other == 0:
                raise ZeroDivisionError("integer division or modulo by zero")
            return timedelta(0, 0, _divide_and_round(usec, other))
        if isinstance(other, float):
            var ab = other.as_integer_ratio()
            if ab[0] == 0:
                raise ZeroDivisionError("integer division or modulo by zero")
            return timedelta(0, 0, _divide_and_round(ab[1] * usec, ab[0]))
        _binop_error("/", self, other)

    def __mod__(self, other):
        if isinstance(other, timedelta):
            var d = other._to_microseconds()
            if d == 0:
                raise ZeroDivisionError("integer division or modulo by zero")
            return timedelta(0, 0, self._to_microseconds() % d)
        _binop_error("%", self, other)

    def __divmod__(self, other):
        if isinstance(other, timedelta):
            var d = other._to_microseconds()
            if d == 0:
                raise ZeroDivisionError("integer division or modulo by zero")
            var qr = divmod(self._to_microseconds(), d)
            return (qr[0], timedelta(0, 0, qr[1]))
        _binop_error("divmod()", self, other)

    def _getstate(self):
        return (self._days, self._seconds, self._microseconds)

    def _cmp(self, other):
        return _cmp(self._getstate(), other._getstate())

    def __eq__(self, other):
        if isinstance(other, timedelta):
            return self._cmp(other) == 0
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def __le__(self, other):
        if isinstance(other, timedelta):
            return self._cmp(other) <= 0
        _order_error("<=", self, other)

    def __lt__(self, other):
        if isinstance(other, timedelta):
            return self._cmp(other) < 0
        _order_error("<", self, other)

    def __ge__(self, other):
        if isinstance(other, timedelta):
            return self._cmp(other) >= 0
        _order_error(">=", self, other)

    def __gt__(self, other):
        if isinstance(other, timedelta):
            return self._cmp(other) > 0
        _order_error(">", self, other)

    def __hash__(self):
        return hash(self._getstate())

    def __bool__(self):
        return self._days != 0 or self._seconds != 0 or self._microseconds != 0

    def __reduce__(self):
        return (self.__class__, self._getstate())


timedelta.min = timedelta(-999999999)
timedelta.max = timedelta(days=999999999, hours=23, minutes=59, seconds=59, microseconds=999999)
timedelta.resolution = timedelta(microseconds=1)


# ── date ─────────────────────────────────────────────────────────────────────
class date:
    """date(year, month, day) --> date object"""

    def __init__(self, year, month=none, day=none):
        var ymd = _check_date_fields(year, month, day)
        self._year = ymd[0]
        self._month = ymd[1]
        self._day = ymd[2]

    @classmethod
    def fromtimestamp(cls, t):
        "Construct a date from a POSIX timestamp (like time.time())."
        var tt = _time.localtime(t)
        return cls(tt[0], tt[1], tt[2])

    @classmethod
    def today(cls):
        "Construct a date from time.time()."
        return cls.fromtimestamp(_time.time())

    @classmethod
    def fromordinal(cls, n):
        """Construct a date from a proleptic Gregorian ordinal.

        January 1 of year 1 is day 1."""
        n = _index(n)
        if n < 1:
            raise ValueError("ordinal must be >= 1")
        if n > _MAXORDINAL:
            raise ValueError("year " + str(_ord2ymd(n)[0]) + " is out of range")
        var ymd = _ord2ymd(n)
        return cls(ymd[0], ymd[1], ymd[2])

    @classmethod
    def fromisoformat(cls, date_string):
        """Construct a date from a string in ISO 8601 format."""
        if not isinstance(date_string, str):
            raise TypeError("fromisoformat: argument must be str")
        var parts = none
        try:
            if not (len(date_string) == 7 or len(date_string) == 8 or len(date_string) == 10):
                raise ValueError("bad length")
            parts = _parse_isoformat_date(date_string)
        except ValueError:
            raise ValueError("Invalid isoformat string: " + repr(date_string))
        if parts[0] == "W":
            var ymd = _isoweek_to_gregorian(parts[1], parts[2], parts[3])
            return cls(ymd[0], ymd[1], ymd[2])
        return cls(parts[0], parts[1], parts[2])

    @classmethod
    def fromisocalendar(cls, year, week, day):
        """Construct a date from the ISO year, week number and weekday."""
        var ymd = _isoweek_to_gregorian(year, week, day)
        return cls(ymd[0], ymd[1], ymd[2])

    def __repr__(self):
        return "%s(%d, %d, %d)" % (_cls_name(self),
                                      self._year, self._month, self._day)

    def ctime(self):
        "Return ctime() style string."
        var weekday = self.toordinal() % 7 or 7
        return "%s %s %2d 00:00:00 %04d" % (_DAYNAMES[weekday], _MONTHNAMES[self._month],
                                             self._day, self._year)

    def strftime(self, format):
        """Format using strftime()."""
        return _wrap_strftime(self, format, self.timetuple())

    def __format__(self, fmt):
        if not isinstance(fmt, str):
            raise TypeError("must be str, not " + type(fmt).__name__)
        if len(fmt) != 0:
            return self.strftime(fmt)
        return str(self)

    def isoformat(self):
        """Return the date formatted according to ISO: 'YYYY-MM-DD'."""
        return "%04d-%02d-%02d" % (self._year, self._month, self._day)

    def __str__(self):
        return self.isoformat()

    @property
    def year(self):
        """year (1-9999)"""
        return self._year

    @property
    def month(self):
        """month (1-12)"""
        return self._month

    @property
    def day(self):
        """day (1-31)"""
        return self._day

    def timetuple(self):
        "Return local time tuple compatible with time.localtime()."
        return _build_struct_time(self._year, self._month, self._day, 0, 0, 0, -1)

    def toordinal(self):
        """Return proleptic Gregorian ordinal for the year, month and day."""
        return _ymd2ord(self._year, self._month, self._day)

    def replace(self, year=none, month=none, day=none):
        """Return a new date with new values for the specified fields."""
        if year is none:
            year = self._year
        if month is none:
            month = self._month
        if day is none:
            day = self._day
        return self.__class__(year, month, day)

    def _cmpdate(self, other):
        return _cmp((self._year, self._month, self._day), (other._year, other._month, other._day))

    def _check_order(self, op, other):
        # date vs date only: a datetime on either side is a TypeError
        if isinstance(other, _datetime_class):
            raise TypeError("can't compare " + _tname(other) + " to " + _tname(self))
        if not isinstance(other, _date_class):
            _order_error(op, self, other)

    def __eq__(self, other):
        if isinstance(other, _datetime_class):
            return false
        if isinstance(other, _date_class):
            return self._cmpdate(other) == 0
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def __le__(self, other):
        self._check_order("<=", other)
        return self._cmpdate(other) <= 0

    def __lt__(self, other):
        self._check_order("<", other)
        return self._cmpdate(other) < 0

    def __ge__(self, other):
        self._check_order(">=", other)
        return self._cmpdate(other) >= 0

    def __gt__(self, other):
        self._check_order(">", other)
        return self._cmpdate(other) > 0

    def __hash__(self):
        return hash((self._year, self._month, self._day))

    def __add__(self, other):
        "Add a date to a timedelta."
        if isinstance(other, timedelta):
            var o = self.toordinal() + other.days
            if 0 < o and o <= _MAXORDINAL:
                var ymd = _ord2ymd(o)
                return self.__class__(ymd[0], ymd[1], ymd[2])
            raise OverflowError("date value out of range")
        _binop_error("+", self, other)

    def __radd__(self, other):
        if isinstance(other, timedelta):
            return self.__add__(other)
        _binop_error("+", other, self)

    def __sub__(self, other):
        """Subtract two dates, or a date and a timedelta."""
        if isinstance(other, timedelta):
            return self + timedelta(-other.days)
        if isinstance(other, _date_class) and not isinstance(other, _datetime_class):
            return timedelta(self.toordinal() - other.toordinal())
        _binop_error("-", self, other)

    def __rsub__(self, other):
        _binop_error("-", other, self)

    def weekday(self):
        "Return day of the week, where Monday == 0 ... Sunday == 6."
        return (self.toordinal() + 6) % 7

    def isoweekday(self):
        "Return day of the week, where Monday == 1 ... Sunday == 7."
        return self.toordinal() % 7 or 7

    def isocalendar(self):
        """Return a named tuple containing ISO year, week number, and weekday."""
        var year = self._year
        var week1monday = _isoweek1monday(year)
        var today = _ymd2ord(self._year, self._month, self._day)
        var week = (today - week1monday) // 7
        var day = (today - week1monday) % 7
        if week < 0:
            year = year - 1
            week1monday = _isoweek1monday(year)
            week = (today - week1monday) // 7
            day = (today - week1monday) % 7
        elif week >= 52:
            if today >= _isoweek1monday(year + 1):
                year = year + 1
                week = 0
        return IsoCalendarDate(year, week + 1, day + 1)

    def __reduce__(self):
        return (self.__class__, (self._year, self._month, self._day))


class IsoCalendarDate:
    """date.isocalendar()'s result: a (year, week, weekday) tuple with names."""

    def __init__(self, year, week, weekday):
        self._t = (year, week, weekday)

    @property
    def year(self):
        return self._t[0]

    @property
    def week(self):
        return self._t[1]

    @property
    def weekday(self):
        return self._t[2]

    def __len__(self):
        return 3

    def __getitem__(self, i):
        return self._t[i]

    def __iter__(self):
        return iter(self._t)

    def __eq__(self, other):
        if isinstance(other, IsoCalendarDate):
            return self._t == other._t
        if isinstance(other, tuple):
            return self._t == other
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def __lt__(self, other):
        return self._t < tuple(other)

    def __hash__(self):
        return hash(self._t)

    def __repr__(self):
        return "datetime.IsoCalendarDate(year=%d, week=%d, weekday=%d)" % self._t


_date_class = date

date.min = date(1, 1, 1)
date.max = date(9999, 12, 31)
date.resolution = timedelta(days=1)


# ── tzinfo ───────────────────────────────────────────────────────────────────
class tzinfo:
    """Abstract base class for time zone info classes.

    Subclasses must override the tzname(), utcoffset() and dst() methods.
    """

    def tzname(self, dt):
        "datetime -> string name of time zone."
        raise NotImplementedError("a tzinfo subclass must implement tzname()")

    def utcoffset(self, dt):
        "datetime -> timedelta, positive for east of UTC, negative for west of UTC"
        raise NotImplementedError("a tzinfo subclass must implement utcoffset()")

    def dst(self, dt):
        """datetime -> DST offset as timedelta, positive for east of UTC."""
        raise NotImplementedError("a tzinfo subclass must implement dst()")

    def fromutc(self, dt):
        "datetime in UTC -> datetime in local time."
        if not isinstance(dt, _datetime_class):
            raise TypeError("fromutc: argument must be a datetime")
        if not _same(dt.tzinfo, self):
            raise ValueError("fromutc: dt.tzinfo is not self")
        var dtoff = dt.utcoffset()
        if dtoff is none:
            raise ValueError("fromutc: non-None utcoffset() result required")
        var dtdst = dt.dst()
        if dtdst is none:
            raise ValueError("fromutc: non-None dst() result required")
        var delta = dtoff - dtdst
        if delta:
            dt = dt + delta
            dtdst = dt.dst()
            if dtdst is none:
                raise ValueError("fromutc: tz.dst() gave inconsistent results; cannot convert")
        return dt + dtdst


_tzinfo_class = tzinfo


# ── time ─────────────────────────────────────────────────────────────────────
class time:
    """time([hour[, minute[, second[, microsecond[, tzinfo]]]]]) --> a time object"""

    def __init__(self, hour=0, minute=0, second=0, microsecond=0, tzinfo=none, *, fold=0):
        var f = _check_time_fields(hour, minute, second, microsecond, fold)
        _check_tzinfo_arg(tzinfo)
        self._hour = f[0]
        self._minute = f[1]
        self._second = f[2]
        self._microsecond = f[3]
        self._tzinfo = tzinfo
        self._fold = f[4]

    @property
    def hour(self):
        """hour (0-23)"""
        return self._hour

    @property
    def minute(self):
        """minute (0-59)"""
        return self._minute

    @property
    def second(self):
        """second (0-59)"""
        return self._second

    @property
    def microsecond(self):
        """microsecond (0-999999)"""
        return self._microsecond

    @property
    def tzinfo(self):
        """timezone info object"""
        return self._tzinfo

    @property
    def fold(self):
        return self._fold

    def _cmptime(self, other, allow_mixed=false):
        var mytz = self._tzinfo
        var ottz = other._tzinfo
        var myoff = none
        var otoff = none
        var base_compare = true
        if not _same(mytz, ottz):
            myoff = self.utcoffset()
            otoff = other.utcoffset()
            base_compare = myoff == otoff
        if base_compare:
            return _cmp((self._hour, self._minute, self._second, self._microsecond),
                        (other._hour, other._minute, other._second, other._microsecond))
        if myoff is none or otoff is none:
            if allow_mixed:
                return 2
            raise TypeError("can't compare offset-naive and offset-aware times")
        var myhhmm = self._hour * 60 + self._minute - myoff // timedelta(minutes=1)
        var othhmm = other._hour * 60 + other._minute - otoff // timedelta(minutes=1)
        return _cmp((myhhmm, self._second, self._microsecond), (othhmm, other._second, other._microsecond))

    def __eq__(self, other):
        if isinstance(other, _time_class):
            return self._cmptime(other, true) == 0
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def _check_order(self, op, other):
        if not isinstance(other, _time_class):
            _order_error(op, self, other)

    def __le__(self, other):
        self._check_order("<=", other)
        return self._cmptime(other) <= 0

    def __lt__(self, other):
        self._check_order("<", other)
        return self._cmptime(other) < 0

    def __ge__(self, other):
        self._check_order(">=", other)
        return self._cmptime(other) >= 0

    def __gt__(self, other):
        self._check_order(">", other)
        return self._cmptime(other) > 0

    def __hash__(self):
        var t = self.replace(fold=0) if self._fold else self
        var tzoff = t.utcoffset()
        if not tzoff:
            return hash((t._hour, t._minute, t._second, t._microsecond))
        var hm = (timedelta(hours=self._hour, minutes=self._minute) - tzoff).__divmod__(timedelta(hours=1))
        var m = hm[1] // timedelta(minutes=1)
        return hash((hm[0], m, self._second, self._microsecond))

    def _tzstr(self):
        return _format_offset(self.utcoffset())

    def __repr__(self):
        var s = ""
        if self._microsecond != 0:
            s = ", %d, %d" % (self._second, self._microsecond)
        elif self._second != 0:
            s = ", %d" % self._second
        s = "%s(%d, %d%s)" % (_cls_name(self),
                                 self._hour, self._minute, s)
        if self._tzinfo is not none:
            s = s[:-1] + ", tzinfo=" + repr(self._tzinfo) + ")"
        if self._fold:
            s = s[:-1] + ", fold=1)"
        return s

    def isoformat(self, timespec="auto"):
        """Return the time formatted according to ISO: 'HH:MM:SS.mmmmmm+zz:zz'."""
        var s = _format_time(self._hour, self._minute, self._second, self._microsecond, timespec)
        var tz = self._tzstr()
        if tz:
            s = s + tz
        return s

    def __str__(self):
        return self.isoformat()

    @classmethod
    def fromisoformat(cls, time_string):
        """Construct a time from a string in one of the ISO 8601 formats."""
        if not isinstance(time_string, str):
            raise TypeError("fromisoformat: argument must be str")
        var ts = time_string[1:] if time_string.startswith("T") else time_string
        var comps = none
        try:
            comps = _parse_isoformat_time(ts)
        except ValueError:
            raise ValueError("Invalid isoformat string: " + repr(time_string))
        return cls(comps[0], comps[1], comps[2], comps[3], comps[4])

    def strftime(self, format):
        """Format using strftime().  The date part is 1900-01-01."""
        var timetuple = (1900, 1, 1, self._hour, self._minute, self._second, 0, 1, -1)
        return _wrap_strftime(self, format, timetuple)

    def __format__(self, fmt):
        if not isinstance(fmt, str):
            raise TypeError("must be str, not " + type(fmt).__name__)
        if len(fmt) != 0:
            return self.strftime(fmt)
        return str(self)

    def utcoffset(self):
        """Return the timezone offset as timedelta, positive east of UTC."""
        if self._tzinfo is none:
            return none
        var offset = self._tzinfo.utcoffset(none)
        _check_utc_offset("utcoffset", offset)
        return offset

    def tzname(self):
        """Return the timezone name."""
        if self._tzinfo is none:
            return none
        var name = self._tzinfo.tzname(none)
        _check_tzname(name)
        return name

    def dst(self):
        """Return 0 if DST is not in effect, or the DST offset."""
        if self._tzinfo is none:
            return none
        var offset = self._tzinfo.dst(none)
        _check_utc_offset("dst", offset)
        return offset

    def replace(self, hour=none, minute=none, second=none, microsecond=none, tzinfo=true, *, fold=none):
        """Return a new time with new values for the specified fields."""
        if hour is none:
            hour = self._hour
        if minute is none:
            minute = self._minute
        if second is none:
            second = self._second
        if microsecond is none:
            microsecond = self._microsecond
        if isinstance(tzinfo, bool) and tzinfo == true:
            tzinfo = self._tzinfo
        if fold is none:
            fold = self._fold
        return self.__class__(hour, minute, second, microsecond, tzinfo, fold=fold)

    def __add__(self, other):
        _binop_error("+", self, other)

    def __radd__(self, other):
        _binop_error("+", other, self)

    def __sub__(self, other):
        _binop_error("-", self, other)


_time_class = time

time.min = time(0, 0, 0)
time.max = time(23, 59, 59, 999999)
time.resolution = timedelta(microseconds=1)


# ── datetime ─────────────────────────────────────────────────────────────────
class datetime(date):
    """datetime(year, month, day[, hour[, minute[, second[, microsecond[,tzinfo]]]]])

    The year, month and day arguments are required. tzinfo may be None, or an
    instance of a tzinfo subclass. The remaining arguments may be ints.
    """

    def __init__(self, year, month=none, day=none, hour=0, minute=0, second=0,
                 microsecond=0, tzinfo=none, *, fold=0):
        var ymd = _check_date_fields(year, month, day)
        var f = _check_time_fields(hour, minute, second, microsecond, fold)
        _check_tzinfo_arg(tzinfo)
        self._year = ymd[0]
        self._month = ymd[1]
        self._day = ymd[2]
        self._hour = f[0]
        self._minute = f[1]
        self._second = f[2]
        self._microsecond = f[3]
        self._tzinfo = tzinfo
        self._fold = f[4]

    @property
    def hour(self):
        """hour (0-23)"""
        return self._hour

    @property
    def minute(self):
        """minute (0-59)"""
        return self._minute

    @property
    def second(self):
        """second (0-59)"""
        return self._second

    @property
    def microsecond(self):
        """microsecond (0-999999)"""
        return self._microsecond

    @property
    def tzinfo(self):
        """timezone info object"""
        return self._tzinfo

    @property
    def fold(self):
        return self._fold

    @classmethod
    def _fromtimestamp(cls, t, utc, tz):
        var mf = math.modf(t)
        var frac = mf[0]
        t = mf[1]
        var us = round(frac * 1e6)
        if us >= 1000000:
            t = t + 1
            us = us - 1000000
        elif us < 0:
            t = t - 1
            us = us + 1000000
        var tt = _time.gmtime(t) if utc else _time.localtime(t)
        var ss = min(tt[5], 59)
        var result = cls(tt[0], tt[1], tt[2], tt[3], tt[4], ss, us, tz)
        if tz is none and not utc:
            var max_fold_seconds = 24 * 3600
            var p1 = _time.localtime(t - max_fold_seconds)
            var probe1 = cls(p1[0], p1[1], p1[2], p1[3], p1[4], min(p1[5], 59), us, tz)
            var trans = result - probe1 - timedelta(0, max_fold_seconds)
            if trans.days < 0:
                var p2 = _time.localtime(t + trans // timedelta(0, 1))
                var probe2 = cls(p2[0], p2[1], p2[2], p2[3], p2[4], min(p2[5], 59), us, tz)
                if probe2 == result:
                    result._fold = 1
        elif tz is not none:
            result = tz.fromutc(result)
        return result

    @classmethod
    def fromtimestamp(cls, timestamp, tz=none):
        """Construct a datetime from a POSIX timestamp (like time.time())."""
        _check_tzinfo_arg(tz)
        return cls._fromtimestamp(timestamp, tz is not none, tz)

    @classmethod
    def utcfromtimestamp(cls, t):
        """Construct a naive UTC datetime from a POSIX timestamp."""
        return cls._fromtimestamp(t, true, none)

    @classmethod
    def now(cls, tz=none):
        "Construct a datetime from time.time() and optional time zone info."
        return cls.fromtimestamp(_time.time(), tz)

    @classmethod
    def utcnow(cls):
        "Construct a UTC datetime from time.time()."
        return cls._fromtimestamp(_time.time(), true, none)

    @classmethod
    def combine(cls, date, time, tzinfo=true):
        "Construct a datetime from a given date and a given time."
        if not isinstance(date, _date_class):
            raise TypeError("combine() argument 1 must be datetime.date, not " + type(date).__name__)
        if not isinstance(time, _time_class):
            raise TypeError("combine() argument 2 must be datetime.time, not " + type(time).__name__)
        if isinstance(tzinfo, bool) and tzinfo == true:
            tzinfo = time.tzinfo
        return cls(date.year, date.month, date.day, time.hour, time.minute, time.second,
                   time.microsecond, tzinfo, fold=time.fold)

    @classmethod
    def fromisoformat(cls, date_string):
        """Construct a datetime from a string in one of the ISO 8601 formats."""
        if not isinstance(date_string, str):
            raise TypeError("fromisoformat: argument must be str")
        if len(date_string) < 7:
            raise ValueError("Invalid isoformat string: " + repr(date_string))
        var dparts = none
        var tparts = [0, 0, 0, 0, none]
        try:
            var sep = _find_isoformat_datetime_separator(date_string)
            var dstr = date_string[0:sep]
            var tstr = date_string[(sep + 1):]
            dparts = _parse_isoformat_date(dstr)
            if tstr:
                tparts = _parse_isoformat_time(tstr)
        except ValueError:
            raise ValueError("Invalid isoformat string: " + repr(date_string))
        if dparts[0] == "W":
            dparts = _isoweek_to_gregorian(dparts[1], dparts[2], dparts[3])
        return cls(dparts[0], dparts[1], dparts[2], tparts[0], tparts[1], tparts[2], tparts[3], tparts[4])

    def timetuple(self):
        "Return local time tuple compatible with time.localtime()."
        var dst = self.dst()
        if dst is none:
            dst = -1
        elif dst:
            dst = 1
        else:
            dst = 0
        return _build_struct_time(self._year, self._month, self._day, self._hour, self._minute, self._second, dst)

    def _mktime(self):
        """Return integer POSIX timestamp."""
        var epoch = _datetime_class(1970, 1, 1)
        var max_fold_seconds = 24 * 3600
        var t = (self - epoch) // timedelta(0, 1)
        var a = _local_seconds(t) - t
        var u1 = t - a
        var t1 = _local_seconds(u1)
        var b = 0
        if t1 == t:
            var u2a = u1 + (max_fold_seconds if self._fold else -max_fold_seconds)
            b = _local_seconds(u2a) - u2a
            if a == b:
                return u1
        else:
            b = t1 - u1
        var u2 = t - b
        var t2 = _local_seconds(u2)
        if t2 == t:
            return u2
        if t1 == t:
            return u1
        return min(u1, u2) if self._fold else max(u1, u2)

    def timestamp(self):
        "Return POSIX timestamp as float"
        if self._tzinfo is none:
            var s = self._mktime()
            return s + self._microsecond / 1e6
        return (self - _EPOCH).total_seconds()

    def utctimetuple(self):
        "Return UTC time tuple compatible with time.gmtime()."
        var me = self
        var offset = self.utcoffset()
        if offset:
            me = self - offset
        return _build_struct_time(me.year, me.month, me.day, me.hour, me.minute, me.second, 0)

    def date(self):
        "Return the date part."
        return _date_class(self._year, self._month, self._day)

    def time(self):
        "Return the time part, with tzinfo None."
        return _time_class(self._hour, self._minute, self._second, self._microsecond, fold=self._fold)

    def timetz(self):
        "Return the time part, with same tzinfo."
        return _time_class(self._hour, self._minute, self._second, self._microsecond, self._tzinfo, fold=self._fold)

    def replace(self, year=none, month=none, day=none, hour=none, minute=none, second=none,
                microsecond=none, tzinfo=true, *, fold=none):
        """Return a new datetime with new values for the specified fields."""
        if year is none:
            year = self._year
        if month is none:
            month = self._month
        if day is none:
            day = self._day
        if hour is none:
            hour = self._hour
        if minute is none:
            minute = self._minute
        if second is none:
            second = self._second
        if microsecond is none:
            microsecond = self._microsecond
        if isinstance(tzinfo, bool) and tzinfo == true:
            tzinfo = self._tzinfo
        if fold is none:
            fold = self._fold
        return self.__class__(year, month, day, hour, minute, second, microsecond, tzinfo, fold=fold)

    def _local_timezone(self):
        var ts = 0
        if self._tzinfo is none:
            ts = self._mktime()
            var ts2 = self.replace(fold=1 - self._fold)._mktime()
            if ts2 != ts:
                if (ts2 > ts) == (self._fold == 1):
                    ts = ts2
        else:
            ts = (self - _EPOCH) // timedelta(seconds=1)
        var localtm = _time.localtime(ts)
        return timezone(timedelta(seconds=localtm.tm_gmtoff), localtm.tm_zone)

    def astimezone(self, tz=none):
        """tz -> convert to local time in new timezone tz"""
        if tz is none:
            tz = self._local_timezone()
        elif not isinstance(tz, _tzinfo_class):
            raise TypeError("astimezone() argument 1 must be datetime.tzinfo, not " + type(tz).__name__)
        var mytz = self._tzinfo
        var myoffset = none
        if mytz is none:
            mytz = self._local_timezone()
            myoffset = mytz.utcoffset(self)
        else:
            myoffset = mytz.utcoffset(self)
            if myoffset is none:
                mytz = self.replace(tzinfo=none)._local_timezone()
                myoffset = mytz.utcoffset(self)
        if _same(tz, mytz):
            return self
        var utc = (self - myoffset).replace(tzinfo=tz)
        return tz.fromutc(utc)

    def ctime(self):
        "Return ctime() style string."
        var weekday = self.toordinal() % 7 or 7
        return "%s %s %2d %02d:%02d:%02d %04d" % (_DAYNAMES[weekday], _MONTHNAMES[self._month], self._day,
                                                 self._hour, self._minute, self._second, self._year)

    def isoformat(self, sep="T", timespec="auto"):
        """[sep] -> string in ISO 8601 format, YYYY-MM-DDT[HH[:MM[:SS[.mmm[uuu]]]]][+HH:MM]."""
        var s = "%04d-%02d-%02d%s" % (self._year, self._month, self._day, sep) + _format_time(self._hour, self._minute, self._second, self._microsecond, timespec)
        var tz = _format_offset(self.utcoffset())
        if tz:
            s = s + tz
        return s

    def __repr__(self):
        var L = [self._year, self._month, self._day, self._hour, self._minute, self._second, self._microsecond]
        if L[-1] == 0:
            L.pop()
        if L[-1] == 0:
            L.pop()
        var s = "%s(%s)" % (_cls_name(self), ", ".join([str(x) for x in L]))
        if self._tzinfo is not none:
            s = s[:-1] + ", tzinfo=" + repr(self._tzinfo) + ")"
        if self._fold:
            s = s[:-1] + ", fold=1)"
        return s

    def __str__(self):
        return self.isoformat(" ")

    def __format__(self, fmt):
        if not isinstance(fmt, str):
            raise TypeError("must be str, not " + type(fmt).__name__)
        if len(fmt) != 0:
            return self.strftime(fmt)
        return str(self)

    @classmethod
    def strptime(cls, date_string, format):
        """string, format -> new datetime parsed from a string (like time.strptime())."""
        var r = _time._strptime(date_string, format)
        var tt = r[0]
        var tzname = tt[9]
        var gmtoff = tt[10]
        if gmtoff is not none:
            var tzdelta = timedelta(seconds=gmtoff, microseconds=r[2])
            var tz = timezone(tzdelta, tzname) if tzname else timezone(tzdelta)
            return cls(tt[0], tt[1], tt[2], tt[3], tt[4], tt[5], r[1], tz)
        return cls(tt[0], tt[1], tt[2], tt[3], tt[4], tt[5], r[1])

    def utcoffset(self):
        """Return the timezone offset as timedelta positive east of UTC."""
        if self._tzinfo is none:
            return none
        var offset = self._tzinfo.utcoffset(self)
        _check_utc_offset("utcoffset", offset)
        return offset

    def tzname(self):
        """Return the timezone name."""
        if self._tzinfo is none:
            return none
        var name = self._tzinfo.tzname(self)
        _check_tzname(name)
        return name

    def dst(self):
        """Return 0 if DST is not in effect, or the DST offset."""
        if self._tzinfo is none:
            return none
        var offset = self._tzinfo.dst(self)
        _check_utc_offset("dst", offset)
        return offset

    def _cmpdt(self, other, allow_mixed=false):
        var mytz = self._tzinfo
        var ottz = other._tzinfo
        var myoff = none
        var otoff = none
        var base_compare = true
        if not _same(mytz, ottz):
            myoff = self.utcoffset()
            otoff = other.utcoffset()
            if allow_mixed:
                if myoff != self.replace(fold=1 - self._fold).utcoffset():
                    return 2
                if otoff != other.replace(fold=1 - other._fold).utcoffset():
                    return 2
            base_compare = myoff == otoff
        if base_compare:
            return _cmp((self._year, self._month, self._day, self._hour, self._minute, self._second, self._microsecond),
                        (other._year, other._month, other._day, other._hour, other._minute, other._second, other._microsecond))
        if myoff is none or otoff is none:
            if allow_mixed:
                return 2
            raise TypeError("can't compare offset-naive and offset-aware datetimes")
        var diff = self - other
        if diff.days < 0:
            return -1
        return 1 if diff else 0

    def _check_order(self, op, other):
        if isinstance(other, _datetime_class):
            return none
        if isinstance(other, _date_class):
            raise TypeError("can't compare " + _tname(self) + " to " + _tname(other))
        _order_error(op, self, other)

    def __eq__(self, other):
        if isinstance(other, _datetime_class):
            return self._cmpdt(other, true) == 0
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def __le__(self, other):
        self._check_order("<=", other)
        return self._cmpdt(other) <= 0

    def __lt__(self, other):
        self._check_order("<", other)
        return self._cmpdt(other) < 0

    def __ge__(self, other):
        self._check_order(">=", other)
        return self._cmpdt(other) >= 0

    def __gt__(self, other):
        self._check_order(">", other)
        return self._cmpdt(other) > 0

    def __add__(self, other):
        "Add a datetime and a timedelta."
        if not isinstance(other, timedelta):
            _binop_error("+", self, other)
        # in whole microseconds (what Python's timedelta arithmetic comes to)
        var us = ((self.toordinal() * 86400 + self._hour * 3600 + self._minute * 60 + self._second) * 1000000 +
                  self._microsecond + other._to_microseconds())
        var days = us // 86400000000
        var rem = us % 86400000000
        if 0 < days and days <= _MAXORDINAL:
            var ymd = _ord2ymd(days)
            var secs = rem // 1000000
            return self.__class__(ymd[0], ymd[1], ymd[2], secs // 3600, (secs % 3600) // 60, secs % 60,
                                  rem % 1000000, self._tzinfo)
        raise OverflowError("date value out of range")

    def __radd__(self, other):
        if isinstance(other, timedelta):
            return self.__add__(other)
        _binop_error("+", other, self)

    def __sub__(self, other):
        "Subtract two datetimes, or a datetime and a timedelta."
        if not isinstance(other, _datetime_class):
            if isinstance(other, timedelta):
                return self + -other
            _binop_error("-", self, other)
        var days1 = self.toordinal()
        var days2 = other.toordinal()
        var secs1 = self._second + self._minute * 60 + self._hour * 3600
        var secs2 = other._second + other._minute * 60 + other._hour * 3600
        var base = timedelta(days1 - days2, secs1 - secs2, self._microsecond - other._microsecond)
        if _same(self._tzinfo, other._tzinfo):
            return base
        var myoff = self.utcoffset()
        var otoff = other.utcoffset()
        if myoff == otoff:
            return base
        if myoff is none or otoff is none:
            raise TypeError("can't subtract offset-naive and offset-aware datetimes")
        return base + otoff - myoff

    def __hash__(self):
        var t = self.replace(fold=0) if self._fold else self
        var tzoff = t.utcoffset()
        if tzoff is none:
            return hash((t._year, t._month, t._day, t._hour, t._minute, t._second, t._microsecond))
        var days = _ymd2ord(self._year, self._month, self._day)
        var seconds = self._hour * 3600 + self._minute * 60 + self._second
        return hash(timedelta(days, seconds, self._microsecond) - tzoff)

    def __reduce__(self):
        return (self.__class__, (self._year, self._month, self._day, self._hour, self._minute,
                                 self._second, self._microsecond, self._tzinfo))


_datetime_class = datetime

datetime.min = datetime(1, 1, 1)
datetime.max = datetime(9999, 12, 31, 23, 59, 59, 999999)
datetime.resolution = timedelta(microseconds=1)


def _local_seconds(u):
    # datetime._mktime's local(): seconds of the local wall clock at u
    var tt = _time.localtime(u)
    return (_ymd2ord(tt[0], tt[1], tt[2]) - 719163) * 86400 + tt[3] * 3600 + tt[4] * 60 + tt[5]


# ── timezone ─────────────────────────────────────────────────────────────────
class timezone(tzinfo):
    """Fixed offset from UTC implementation of tzinfo."""

    def __init__(self, offset, name=none):
        if not isinstance(offset, timedelta):
            raise TypeError("timezone() argument 1 must be datetime.timedelta, not " + type(offset).__name__)
        if name is not none and not isinstance(name, str):
            raise TypeError("timezone() argument 2 must be str, not " + type(name).__name__)
        if not (_TZ_MINOFFSET <= offset and offset <= _TZ_MAXOFFSET):
            raise ValueError("offset must be a timedelta strictly between -timedelta(hours=24) and timedelta(hours=24), not " + repr(offset) + ".")
        self._offset = offset
        self._name = name

    def __getinitargs__(self):
        if self._name is none:
            return (self._offset,)
        return (self._offset, self._name)

    def __eq__(self, other):
        if isinstance(other, timezone):
            return self._offset == other._offset
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash(self._offset)

    def __repr__(self):
        if self._name is none and not self._offset:
            return "datetime.timezone.utc"
        if self._name is none:
            return "%s(%s)" % (_cls_name(self), repr(self._offset))
        return "%s(%s, %s)" % (_cls_name(self), repr(self._offset), repr(self._name))

    def __str__(self):
        return self.tzname(none)

    def utcoffset(self, dt):
        if isinstance(dt, _datetime_class) or dt is none:
            return self._offset
        raise TypeError("utcoffset(dt) argument must be a datetime instance or None, not " + type(dt).__name__)

    def tzname(self, dt):
        if isinstance(dt, _datetime_class) or dt is none:
            if self._name is none:
                return timezone._name_from_offset(self._offset)
            return self._name
        raise TypeError("tzname(dt) argument must be a datetime instance or None, not " + type(dt).__name__)

    def dst(self, dt):
        if isinstance(dt, _datetime_class) or dt is none:
            return none
        raise TypeError("dst(dt) argument must be a datetime instance or None, not " + type(dt).__name__)

    def fromutc(self, dt):
        if isinstance(dt, _datetime_class):
            if not _same(dt.tzinfo, self) and not (isinstance(dt.tzinfo, timezone) and dt.tzinfo == self):
                raise ValueError("fromutc: dt.tzinfo is not self")
            return dt + self._offset
        raise TypeError("fromutc: argument must be a datetime")

    @staticmethod
    def _name_from_offset(delta):
        if not delta:
            return "UTC"
        var sign = "+"
        if delta < timedelta(0):
            sign = "-"
            delta = -delta
        var hr = delta.__divmod__(timedelta(hours=1))
        var mr = hr[1].__divmod__(timedelta(minutes=1))
        var seconds = mr[1].seconds
        var microseconds = mr[1].microseconds
        if microseconds:
            return "UTC%s%02d:%02d:%02d.%06d" % (sign, hr[0], mr[0], seconds, microseconds)
        if seconds:
            return "UTC%s%02d:%02d:%02d" % (sign, hr[0], mr[0], seconds)
        return "UTC%s%02d:%02d" % (sign, hr[0], mr[0])


_TZ_MAXOFFSET = timedelta(hours=24, microseconds=-1)
_TZ_MINOFFSET = -_TZ_MAXOFFSET
timezone._maxoffset = _TZ_MAXOFFSET
timezone._minoffset = _TZ_MINOFFSET
timezone.utc = timezone(timedelta(0))
UTC = timezone.utc
timezone.min = timezone(-timedelta(hours=23, minutes=59))
timezone.max = timezone(timedelta(hours=23, minutes=59))
_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
