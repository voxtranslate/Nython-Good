# nython: module    (import it by name: it runs in a module scope of its own)
# lib/unicodedata.ny - Python's unicodedata: the Unicode character database
# (names round 77, the rest round 84).
#
#     import unicodedata
#     unicodedata.name("—")                       # 'EM DASH'
#     unicodedata.lookup("snowman")               # '☃'
#     unicodedata.category("A"), unicodedata.bidirectional("א")   # 'Lu', 'R'
#     unicodedata.numeric("⅓"), unicodedata.decimal("٣")         # 0.333..., 3
#     unicodedata.normalize("NFC", "é")    # 'é'
#     unicodedata.ucd_3_2_0.category("ȡ")   # 'Cn' (IDNA's Unicode)
#
# Everything CPython 3.11's module has, over the same database (Unicode
# 14.0.0, the one CPython 3.11 ships, generated from python3's own by
# tools/gen_unicodedata.py - include/NyUniData.hpp, src/NyUniData.cpp, the
# _ny_ucd native on both engines):
#   lookup(name)         a character, an alias (LATIN CAPITAL LETTER GHA,
#                        BOM, NBSP, ...) or a named sequence (KEYCAP NUMBER
#                        SIGN); "HANGUL SYLLABLE ..." and "CJK UNIFIED
#                        IDEOGRAPH-..." as spelled, the rest without regard
#                        to case; KeyError "undefined character name 'x'"
#   name(chr[, default]) category, bidirectional, combining, mirrored,
#   east_asian_width, decomposition, decimal/digit/numeric(chr[, default])
#                        with CPython's ValueErrors ("not a decimal", "not a
#                        digit", "not a numeric character", "no such name")
#   normalize(form, s), is_normalized(form, s) - NFC, NFD, NFKC, NFKD:
#                        canonical ordering, Hangul composition and
#                        decomposition, the composition exclusions and
#                        CPython's quick check (UAX #15)
#   unidata_version      "14.0.0"
#   UCD, ucd_3_2_0       the database as Unicode 3.2.0 had it, for IDNA's
#                        stringprep: CPython's change records (categories,
#                        bidirectional classes, decimals, mirroring, east
#                        asian widths, the five corrected decompositions;
#                        characters added since are unassigned there)
#
# Nython's addition: stream_safe(s) - UAX #15's Stream-Safe Text Format
# (section 13): a COMBINING GRAPHEME JOINER before the 31st non-starter of
# a run, so text can be normalized in bounded buffers (a defence against
# the quadratic canonical-ordering inputs the standard describes).
#
# Not here: the _ucnhash_CAPI capsule (C extensions only).

__all__ = ["lookup", "name", "decimal", "digit", "numeric", "category", "bidirectional", "combining",
           "mirrored", "east_asian_width", "decomposition", "normalize", "is_normalized",
           "unidata_version", "ucd_3_2_0", "UCD"]

unidata_version = "14.0.0"

_no_default = object()


def _char(fn, chr):
    # CPython's "argument must be a unicode character" check
    if not isinstance(chr, str):
        raise TypeError(fn + "() argument must be a unicode character, not " + type(chr).__name__)
    if len(chr) != 1:
        raise TypeError(fn + "() argument must be a unicode character, not str")


def _char1(fn, chr):
    # (name() says "argument 1")
    if not isinstance(chr, str):
        raise TypeError(fn + "() argument 1 must be a unicode character, not " + type(chr).__name__)
    if len(chr) != 1:
        raise TypeError(fn + "() argument 1 must be a unicode character, not str")


class UCD:
    """The Unicode database of one version (unicodedata.UCD)."""

    def __init__(self, *args, **kwargs):
        raise TypeError("cannot create 'unicodedata.UCD' instances")

    def _old(self):
        return self.unidata_version == "3.2.0"

    def lookup(self, name):
        """Look up character by name."""
        if isinstance(name, (bytes, bytearray)):
            name = bytes(name).decode("latin-1")
        elif not isinstance(name, str):
            raise TypeError("a bytes-like object is required, not '" + type(name).__name__ + "'")
        if len(name) > 256:
            raise KeyError("name too long")
        var c = _ny_ucd("lookup", name, self._old())
        if c is None:
            raise KeyError("undefined character name '" + name + "'")
        return c

    def name(self, chr, default=_no_default):
        """Returns the name assigned to the character chr as a string."""
        _char1("name", chr)
        var n = _ny_ucd("name", chr, self._old())
        if n == "":
            if default is _no_default:
                raise ValueError("no such name")
            return default
        return n

    def decimal(self, chr, default=_no_default):
        """Converts a Unicode character into its equivalent decimal value."""
        _char("decimal", chr)
        var v = _ny_ucd("decimal", chr, self._old())
        if v is None:
            if default is _no_default:
                raise ValueError("not a decimal")
            return default
        return v

    def digit(self, chr, default=_no_default):
        """Converts a Unicode character into its equivalent digit value."""
        _char("digit", chr)
        var v = _ny_ucd("digit", chr, self._old())
        if v is None:
            if default is _no_default:
                raise ValueError("not a digit")
            return default
        return v

    def numeric(self, chr, default=_no_default):
        """Converts a Unicode character into its equivalent numeric value."""
        _char("numeric", chr)
        var v = _ny_ucd("numeric", chr, self._old())
        if v is None:
            if default is _no_default:
                raise ValueError("not a numeric character")
            return default
        return v

    def category(self, chr):
        """Returns the general category assigned to the character chr as string."""
        _char("category", chr)
        return _ny_ucd("category", chr, self._old())

    def bidirectional(self, chr):
        """Returns the bidirectional class assigned to the character chr as string."""
        _char("bidirectional", chr)
        return _ny_ucd("bidirectional", chr, self._old())

    def combining(self, chr):
        """Returns the canonical combining class assigned to the character chr as integer."""
        _char("combining", chr)
        return _ny_ucd("combining", chr, self._old())

    def mirrored(self, chr):
        """Returns the mirrored property assigned to the character chr as integer."""
        _char("mirrored", chr)
        return _ny_ucd("mirrored", chr, self._old())

    def east_asian_width(self, chr):
        """Returns the east asian width assigned to the character chr as string."""
        _char("east_asian_width", chr)
        return _ny_ucd("east_asian_width", chr, self._old())

    def decomposition(self, chr):
        """Returns the character decomposition mapping assigned to the character chr as string."""
        _char("decomposition", chr)
        return _ny_ucd("decomposition", chr, self._old())

    def normalize(self, form, unistr):
        """Return the normal form 'form' for the Unicode string unistr."""
        if not isinstance(form, str):
            raise TypeError("normalize() argument 1 must be str, not " + type(form).__name__)
        if not isinstance(unistr, str):
            raise TypeError("normalize() argument 2 must be str, not " + type(unistr).__name__)
        return _ny_ucd("normalize", form, unistr, self._old())

    def is_normalized(self, form, unistr):
        """Return whether the Unicode string unistr is in the normal form 'form'."""
        if not isinstance(form, str):
            raise TypeError("is_normalized() argument 1 must be str, not " + type(form).__name__)
        if not isinstance(unistr, str):
            raise TypeError("is_normalized() argument 2 must be str, not " + type(unistr).__name__)
        if unistr == "":
            return True      # (before the form is checked, as CPython's)
        return _ny_ucd("is_normalized", form, unistr, self._old())

    def __repr__(self):
        return "<unicodedata.UCD object at %#x>" % id(self)


UCD.__module__ = "unicodedata"


def _make_ucd(version):
    var u = object.__new__(UCD)
    u.unidata_version = version
    return u


_current = _make_ucd("14.0.0")
ucd_3_2_0 = _make_ucd("3.2.0")


def lookup(name):
    """Look up character by name."""
    return _current.lookup(name)


def name(chr, default=_no_default):
    """Returns the name assigned to the character chr as a string."""
    return _current.name(chr, default)


def decimal(chr, default=_no_default):
    """Converts a Unicode character into its equivalent decimal value."""
    return _current.decimal(chr, default)


def digit(chr, default=_no_default):
    """Converts a Unicode character into its equivalent digit value."""
    return _current.digit(chr, default)


def numeric(chr, default=_no_default):
    """Converts a Unicode character into its equivalent numeric value."""
    return _current.numeric(chr, default)


def category(chr):
    """Returns the general category assigned to the character chr as string."""
    return _current.category(chr)


def bidirectional(chr):
    """Returns the bidirectional class assigned to the character chr as string."""
    return _current.bidirectional(chr)


def combining(chr):
    """Returns the canonical combining class assigned to the character chr as integer."""
    return _current.combining(chr)


def mirrored(chr):
    """Returns the mirrored property assigned to the character chr as integer."""
    return _current.mirrored(chr)


def east_asian_width(chr):
    """Returns the east asian width assigned to the character chr as string."""
    return _current.east_asian_width(chr)


def decomposition(chr):
    """Returns the character decomposition mapping assigned to the character chr as string."""
    return _current.decomposition(chr)


def normalize(form, unistr):
    """Return the normal form 'form' for the Unicode string unistr."""
    return _current.normalize(form, unistr)


def is_normalized(form, unistr):
    """Return whether the Unicode string unistr is in the normal form 'form'."""
    return _current.is_normalized(form, unistr)


def stream_safe(unistr):
    """Nython: unistr in UAX #15's Stream-Safe Text Format (a U+034F COMBINING
    GRAPHEME JOINER before the 31st of a run of non-starters)."""
    if not isinstance(unistr, str):
        raise TypeError("stream_safe() argument must be str, not " + type(unistr).__name__)
    return _ny_ucd("stream_safe", unistr)
