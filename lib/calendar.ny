# nython: module    (import it by name: it runs in a module scope of its own)
# lib/calendar.ny - Python's calendar (3.12).
#
#     import calendar
#     print(calendar.month(2024, 2))           # a month as text, like cal(1)
#     calendar.prcal(2024)                     # a whole year
#     calendar.isleap(2024); calendar.monthrange(2024, 2)   # (3, 29)
#     calendar.Calendar(firstweekday=6).monthdayscalendar(2024, 2)
#     calendar.timegm((2024, 2, 29, 12, 0, 0))
#
# isleap, leapdays, weekday, monthrange, monthcalendar, month/prmonth,
# calendar/prcal, week/prweek, weekheader, format/formatstring, timegm,
# firstweekday/setfirstweekday, month_name/month_abbr/day_name/day_abbr,
# the JANUARY..DECEMBER and MONDAY..SUNDAY constants, mdays,
# IllegalMonthError/IllegalWeekdayError; Calendar (iterweekdays,
# itermonthdays/2/3/4, monthdayscalendar, monthdays2calendar,
# yeardayscalendar, yeardays2calendar, and with lib/datetime.ny the
# date-returning itermonthdates, monthdatescalendar, yeardatescalendar),
# TextCalendar and HTMLCalendar laid out character for character as
# Python's. Dates are computed on the proleptic Gregorian calendar here
# (Python asks datetime.date), with datetime's errors for impossible dates.
#
# Differences: weekday() and monthrange() return plain ints where 3.12
# returns Day members (equal to the ints); there are no Month/Day enum
# classes yet. Names are the C locale's (English); LocaleTextCalendar and
# LocaleHTMLCalendar accept a locale and use them too.
import sys

__all__ = ["IllegalMonthError", "IllegalWeekdayError", "setfirstweekday", "firstweekday",
           "isleap", "leapdays", "weekday", "monthrange", "monthcalendar", "prmonth",
           "month", "prcal", "calendar", "timegm", "month_name", "month_abbr", "day_name",
           "day_abbr", "Calendar", "TextCalendar", "HTMLCalendar", "LocaleTextCalendar",
           "LocaleHTMLCalendar", "weekheader", "JANUARY", "FEBRUARY", "MARCH", "APRIL",
           "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
           "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]

error = ValueError


class IllegalMonthError(ValueError):
    def __init__(self, month):
        self.month = month

    def __str__(self):
        return "bad month number %r; must be 1-12" % (self.month,)


class IllegalWeekdayError(ValueError):
    def __init__(self, weekday):
        self.weekday = weekday

    def __str__(self):
        return "bad weekday number %r; must be 0 (Monday) to 6 (Sunday)" % (self.weekday,)


JANUARY = 1
FEBRUARY = 2
MARCH = 3
APRIL = 4
MAY = 5
JUNE = 6
JULY = 7
AUGUST = 8
SEPTEMBER = 9
OCTOBER = 10
NOVEMBER = 11
DECEMBER = 12
MONDAY = 0
TUESDAY = 1
WEDNESDAY = 2
THURSDAY = 3
FRIDAY = 4
SATURDAY = 5
SUNDAY = 6

mdays = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

_MONTH_NAMES = ["", "January", "February", "March", "April", "May", "June", "July",
                "August", "September", "October", "November", "December"]
_DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


class _CalNames:
    # month_name, month_abbr, day_name, day_abbr: indexable, sliceable,
    # iterable, with len()
    def __init__(self, names):
        self._names = names

    def __getitem__(self, i):
        return self._names[i]

    def __len__(self):
        return len(self._names)

    def __iter__(self):
        return iter(self._names)

    def __repr__(self):
        return "<calendar names " + repr(self._names) + ">"


day_name = _CalNames(_DAY_NAMES)
day_abbr = _CalNames([d[:3] for d in _DAY_NAMES])
month_name = _CalNames(_MONTH_NAMES)
month_abbr = _CalNames([m[:3] for m in _MONTH_NAMES])

_DAYS_BEFORE_MONTH = [-1, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
_MINYEAR = 1
_MAXYEAR = 9999


def isleap(year):
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def leapdays(y1, y2):
    y1 = y1 - 1
    y2 = y2 - 1
    return (y2 // 4 - y1 // 4) - (y2 // 100 - y1 // 100) + (y2 // 400 - y1 // 400)


def _monthlen(year, month):
    return mdays[month] + (1 if month == FEBRUARY and isleap(year) else 0)


def _check_date(year, month, day):
    # datetime.date's checks
    if not isinstance(year, int) or not isinstance(month, int) or not isinstance(day, int):
        raise TypeError("'" + type(year).__name__ + "' object cannot be interpreted as an integer")
    if year < _MINYEAR or year > _MAXYEAR:
        raise ValueError("year " + str(year) + " is out of range")
    if month < 1 or month > 12:
        raise ValueError("month must be in 1..12")
    if day < 1 or day > _monthlen(year, month):
        raise ValueError("day is out of range for month")


def _ordinal(year, month, day):
    # datetime.date(year, month, day).toordinal()
    var y = year - 1
    var before = _DAYS_BEFORE_MONTH[month] + (1 if month > 2 and isleap(year) else 0)
    return y * 365 + y // 4 - y // 100 + y // 400 + before + day


def weekday(year, month, day):
    # 0 (Monday) .. 6 (Sunday)
    if not (_MINYEAR <= year and year <= _MAXYEAR):
        year = 2000 + year % 400
    _check_date(year, month, day)
    return (_ordinal(year, month, day) + 6) % 7


def monthrange(year, month):
    if not (1 <= month and month <= 12):
        raise IllegalMonthError(month)
    var day1 = weekday(year, month, 1)
    return (day1, _monthlen(year, month))


def _prevmonth(year, month):
    if month == 1:
        return (year - 1, 12)
    return (year, month - 1)


def _nextmonth(year, month):
    if month == 12:
        return (year + 1, 1)
    return (year, month + 1)


def _date(y, m, d):
    # a datetime.date (lib/datetime.ny)
    try:
        import datetime
        return datetime.date(y, m, d)
    except (NameError, AttributeError, ImportError):
        raise NotImplementedError("calendar's date methods need datetime.date (lib/datetime.ny)")


class Calendar:
    def __init__(self, firstweekday=0):
        self.firstweekday = firstweekday

    def getfirstweekday(self):
        return self._firstweekday % 7

    def setfirstweekday(self, firstweekday):
        self._firstweekday = firstweekday

    @property
    def firstweekday(self):
        return self._firstweekday % 7

    @firstweekday.setter
    def firstweekday(self, value):
        self._firstweekday = value

    def iterweekdays(self):
        var fw = self.firstweekday
        for i in range(fw, fw + 7):
            yield i % 7

    def _monthdays(self, year, month):
        var r = monthrange(year, month)
        var day1 = r[0]
        var ndays = r[1]
        var fw = self.firstweekday
        var days = [0] * ((day1 - fw) % 7)
        days.extend(range(1, ndays + 1))
        days.extend([0] * ((fw - day1 - ndays) % 7))
        return days

    def itermonthdays(self, year, month):
        for d in self._monthdays(year, month):
            yield d

    def itermonthdays2(self, year, month):
        var i = self.firstweekday
        for d in self._monthdays(year, month):
            yield (d, i % 7)
            i = i + 1

    def _monthdays3(self, year, month):
        var r = monthrange(year, month)
        var day1 = r[0]
        var ndays = r[1]
        var fw = self.firstweekday
        var days_before = (day1 - fw) % 7
        var days_after = (fw - day1 - ndays) % 7
        var out = []
        var pm = _prevmonth(year, month)
        var end = _monthlen(pm[0], pm[1]) + 1
        for d in range(end - days_before, end):
            out.append((pm[0], pm[1], d))
        for d in range(1, ndays + 1):
            out.append((year, month, d))
        var nm = _nextmonth(year, month)
        for d in range(1, days_after + 1):
            out.append((nm[0], nm[1], d))
        return out

    def itermonthdays3(self, year, month):
        for t in self._monthdays3(year, month):
            yield t

    def itermonthdays4(self, year, month):
        var i = 0
        var fw = self.firstweekday
        for t in self._monthdays3(year, month):
            yield (t[0], t[1], t[2], (fw + i) % 7)
            i = i + 1

    def itermonthdates(self, year, month):
        for t in self._monthdays3(year, month):
            yield _date(t[0], t[1], t[2])

    def monthdatescalendar(self, year, month):
        var dates = list(self.itermonthdates(year, month))
        return [dates[i:i + 7] for i in range(0, len(dates), 7)]

    def monthdays2calendar(self, year, month):
        var days = list(self.itermonthdays2(year, month))
        return [days[i:i + 7] for i in range(0, len(days), 7)]

    def monthdayscalendar(self, year, month):
        var days = self._monthdays(year, month)
        return [days[i:i + 7] for i in range(0, len(days), 7)]

    def yeardatescalendar(self, year, width=3):
        var months = [self.monthdatescalendar(year, m) for m in range(1, 13)]
        return [months[i:i + width] for i in range(0, len(months), width)]

    def yeardays2calendar(self, year, width=3):
        var months = [self.monthdays2calendar(year, m) for m in range(1, 13)]
        return [months[i:i + width] for i in range(0, len(months), width)]

    def yeardayscalendar(self, year, width=3):
        var months = [self.monthdayscalendar(year, m) for m in range(1, 13)]
        return [months[i:i + width] for i in range(0, len(months), width)]


class TextCalendar(Calendar):
    def prweek(self, theweek, width):
        print(self.formatweek(theweek, width), end="")

    def formatday(self, day, weekday, width):
        var s = "" if day == 0 else "%2d" % day
        return s.center(width)

    def formatweek(self, theweek, width):
        return " ".join([self.formatday(dw[0], dw[1], width) for dw in theweek])

    def formatweekday(self, day, width):
        var names = day_name if width >= 9 else day_abbr
        return names[day][:width].center(width)

    def formatweekheader(self, width):
        return " ".join([self.formatweekday(i, width) for i in self.iterweekdays()])

    def formatmonthname(self, theyear, themonth, width, withyear=True):
        var s = month_name[themonth]
        if withyear:
            s = "%s %r" % (s, theyear)
        return s.center(width)

    def prmonth(self, theyear, themonth, w=0, l=0):
        print(self.formatmonth(theyear, themonth, w, l), end="")

    def formatmonth(self, theyear, themonth, w=0, l=0):
        w = max(2, w)
        l = max(1, l)
        var s = self.formatmonthname(theyear, themonth, 7 * (w + 1) - 1)
        s = s.rstrip()
        s = s + "\n" * l
        s = s + self.formatweekheader(w).rstrip()
        s = s + "\n" * l
        for week in self.monthdays2calendar(theyear, themonth):
            s = s + self.formatweek(week, w).rstrip()
            s = s + "\n" * l
        return s

    def formatyear(self, theyear, w=2, l=1, c=6, m=3):
        w = max(2, w)
        l = max(1, l)
        c = max(2, c)
        var colwidth = (w + 1) * 7 - 1
        var v = []
        v.append(repr(theyear).center(colwidth * m + c * (m - 1)).rstrip())
        v.append("\n" * l)
        var header = self.formatweekheader(w)
        var rows = self.yeardays2calendar(theyear, m)
        for i in range(len(rows)):
            var row = rows[i]
            var months = range(m * i + 1, min(m * (i + 1) + 1, 13))
            v.append("\n" * l)
            v.append(formatstring([self.formatmonthname(theyear, k, colwidth, False) for k in months], colwidth, c).rstrip())
            v.append("\n" * l)
            v.append(formatstring([header for k in months], colwidth, c).rstrip())
            v.append("\n" * l)
            var height = 0
            for cal in row:
                if len(cal) > height:
                    height = len(cal)
            for j in range(height):
                var weeks = []
                for cal in row:
                    if j >= len(cal):
                        weeks.append("")
                    else:
                        weeks.append(self.formatweek(cal[j], w))
                v.append(formatstring(weeks, colwidth, c).rstrip())
                v.append("\n" * l)
        return "".join(v)

    def pryear(self, theyear, w=0, l=0, c=6, m=3):
        print(self.formatyear(theyear, w, l, c, m), end="")


class HTMLCalendar(Calendar):
    cssclasses = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    cssclasses_weekday_head = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    cssclass_noday = "noday"
    cssclass_month_head = "month"
    cssclass_month = "month"
    cssclass_year_head = "year"
    cssclass_year = "year"

    def formatday(self, day, weekday):
        if day == 0:
            return "<td class=\"%s\">&nbsp;</td>" % self.cssclass_noday
        return "<td class=\"%s\">%d</td>" % (self.cssclasses[weekday], day)

    def formatweek(self, theweek):
        return "<tr>%s</tr>" % "".join([self.formatday(dw[0], dw[1]) for dw in theweek])

    def formatweekday(self, day):
        return "<th class=\"%s\">%s</th>" % (self.cssclasses_weekday_head[day], day_abbr[day])

    def formatweekheader(self):
        return "<tr>%s</tr>" % "".join([self.formatweekday(i) for i in self.iterweekdays()])

    def formatmonthname(self, theyear, themonth, withyear=True):
        var s = month_name[themonth]
        if withyear:
            s = "%s %s" % (month_name[themonth], theyear)
        return "<tr><th colspan=\"7\" class=\"%s\">%s</th></tr>" % (self.cssclass_month_head, s)

    def formatmonth(self, theyear, themonth, withyear=True):
        var v = []
        v.append("<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" class=\"%s\">" % self.cssclass_month)
        v.append("\n")
        v.append(self.formatmonthname(theyear, themonth, withyear=withyear))
        v.append("\n")
        v.append(self.formatweekheader())
        v.append("\n")
        for week in self.monthdays2calendar(theyear, themonth):
            v.append(self.formatweek(week))
            v.append("\n")
        v.append("</table>")
        v.append("\n")
        return "".join(v)

    def formatyear(self, theyear, width=3):
        var v = []
        width = max(width, 1)
        v.append("<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" class=\"%s\">" % self.cssclass_year)
        v.append("\n")
        v.append("<tr><th colspan=\"%d\" class=\"%s\">%s</th></tr>" % (width, self.cssclass_year_head, theyear))
        for i in range(JANUARY, JANUARY + 12, width):
            v.append("<tr>")
            for m in range(i, min(i + width, 13)):
                v.append("<td>")
                v.append(self.formatmonth(theyear, m, withyear=False))
                v.append("</td>")
            v.append("</tr>")
        v.append("</table>")
        return "".join(v)

    def formatyearpage(self, theyear, width=3, css="calendar.css", encoding=None):
        if encoding is None:
            encoding = "utf-8"
        var v = []
        v.append("<?xml version=\"1.0\" encoding=\"%s\"?>\n" % encoding)
        v.append("<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">\n")
        v.append("<html>\n")
        v.append("<head>\n")
        v.append("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=%s\" />\n" % encoding)
        if css is not None:
            v.append("<link rel=\"stylesheet\" type=\"text/css\" href=\"%s\" />\n" % css)
        v.append("<title>Calendar for %d</title>\n" % theyear)
        v.append("</head>\n")
        v.append("<body>\n")
        v.append(self.formatyear(theyear, width))
        v.append("</body>\n")
        v.append("</html>\n")
        return "".join(v).encode(encoding, "xmlcharrefreplace")


class LocaleTextCalendar(TextCalendar):
    def __init__(self, firstweekday=0, locale=None):
        TextCalendar.__init__(self, firstweekday)
        self.locale = locale


class LocaleHTMLCalendar(HTMLCalendar):
    def __init__(self, firstweekday=0, locale=None):
        HTMLCalendar.__init__(self, firstweekday)
        self.locale = locale


_c = TextCalendar()


def firstweekday():
    return _c.getfirstweekday()


def setfirstweekday(firstweekday):
    if not (MONDAY <= firstweekday and firstweekday <= SUNDAY):
        raise IllegalWeekdayError(firstweekday)
    _c.firstweekday = firstweekday


def monthcalendar(year, month):
    return _c.monthdayscalendar(year, month)


def prweek(theweek, width):
    _c.prweek(theweek, width)


def week(theweek, width):
    return _c.formatweek(theweek, width)


def weekheader(width):
    return _c.formatweekheader(width)


def prmonth(theyear, themonth, w=0, l=0):
    _c.prmonth(theyear, themonth, w, l)


def month(theyear, themonth, w=0, l=0):
    return _c.formatmonth(theyear, themonth, w, l)


def calendar(theyear, w=2, l=1, c=6, m=3):
    return _c.formatyear(theyear, w, l, c, m)


def prcal(theyear, w=0, l=0, c=6, m=3):
    _c.pryear(theyear, w, l, c, m)


_colwidth = 7 * 3 - 1
_spacing = 6


def format(cols, colwidth=_colwidth, spacing=_spacing):
    print(formatstring(cols, colwidth, spacing))


def formatstring(cols, colwidth=_colwidth, spacing=_spacing):
    return (" " * spacing).join([c.center(colwidth) for c in cols])


EPOCH = 1970
_EPOCH_ORD = 719163


def timegm(tuple):
    # seconds since the epoch of a UTC time tuple
    var year = tuple[0]
    var month = tuple[1]
    var day = tuple[2]
    _check_date(year, month, 1)
    var days = _ordinal(year, month, 1) - _EPOCH_ORD + day - 1
    var hours = days * 24 + tuple[3]
    var minutes = hours * 60 + tuple[4]
    return minutes * 60 + tuple[5]
