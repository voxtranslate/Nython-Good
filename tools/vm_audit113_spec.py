#!/usr/bin/env python3
# The contents of examples/vm_audit113.ny (round 84): run under python3 (CPython
# 3.11, Unicode 14.0.0), this script writes the test with every check's
# expected value as python3 computes it:
#
#     python3 tools/vm_audit113_spec.py
#
# The normalization checks embed part of the Unicode Consortium's
# NormalizationTest-14.0.0.txt (all of parts 0 and 3, every 4th line of
# part 2, every 12th of part 1): give its path as NORMTEST=... or it is fetched from unicode.org.
import os
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

HEADER = '''# vm_audit113.ny - the Unicode database, Unicode-correct str, the CJK codecs
# (round 84), both engines:
#
#   unicodedata  every function over a sample of code points from every block
#                and category (category, bidirectional, combining,
#                east_asian_width, mirrored, decomposition, decimal/digit/
#                numeric, name), lookup with aliases and named sequences,
#                normalize/is_normalized (NormalizationTest.txt's parts 0, 2
#                and 3 and a sixth of part 1, checked as the standard's
#                conformance conditions), ucd_3_2_0, the errors
#   str          full case mapping (SpecialCasing, final sigma), casefold,
#                title/capitalize/swapcase/istitle with titlecase letters, the
#                is* predicates as CPython defines them, split/strip/
#                splitlines on Unicode whitespace and line boundaries,
#                int()/float()/complex()/Decimal() of Unicode digits
#   identifiers  PEP 3131 in the lexer (NFKC: `ﬁ = 1` binds `fi`)
#   re           \\w \\d \\s and IGNORECASE as CPython's sre (ß, ſ, K, ǅ, Σ)
#   codecs       the CJK codecs (CPython's bytes for sample texts, every
#                two-byte sequence and code point digested, errors,
#                incremental and stream use), utf-7, the single-byte code
#                pages, email charsets
#
# Every expected value is what CPython 3.11 computes (the file is generated
# by tools/vm_audit113_spec.py), so `python3 examples/vm_audit113.ny` passes
# too. The Nython-only additions are checked at the end, on Nython only.
#
#     ./build/nython-cli examples/vm_audit113.ny
#     ./build/nython-cli --vm examples/vm_audit113.ny
'''

PREAMBLE = '''try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import sys
import io
import codecs
import hashlib
import unicodedata

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f):
    # the exception f() raises: its type name and message
    try:
        f()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

def md5(x):
    if isinstance(x, str):
        x = x.encode("utf-8", "surrogatepass")
    return hashlib.md5(x).hexdigest()

def cps(s):
    return [ord(c) for c in s]

def unhex(t):
    return "".join(chr(int(h, 16)) for h in t.split())

'''

E = []


def code(s):
    E.append(("code", s))


def chk(name, expr):
    E.append(("check", name, expr))


# ── unicodedata ──────────────────────────────────────────────────────────────
SAMPLE_CODE = """
# ── unicodedata ──────────────────────────────────────────────────────────────
# the sample: every 541st code point, then whole stretches of the blocks
# with the most to get wrong (Latin, Greek, Cyrillic, Armenian, Hebrew,
# Arabic, Devanagari, Thai, Georgian, Hangul jamo, Cherokee, Greek extended,
# punctuation, letterlike, enclosed, Glagolitic, CJK symbols, compatibility
# forms, Deseret, Osage, mathematical alphanumerics, Adlam, tags, PUA ...)
def make_sample():
    s = set(range(0, 0x110000, 541))
    s |= set(range(0, 0x250))
    for a, b in [(0x370, 0x400), (0x400, 0x530), (0x530, 0x590), (0x590, 0x600), (0x600, 0x700), (0x900, 0x980),
                 (0xE00, 0xE80), (0x10A0, 0x1100), (0x1100, 0x1200), (0x13A0, 0x1400), (0x1C80, 0x1CC0),
                 (0x1E00, 0x1E20), (0x1F00, 0x2000), (0x2000, 0x2070), (0x2070, 0x20D0), (0x20D0, 0x2100),
                 (0x2100, 0x2190), (0x2460, 0x2500), (0x2C00, 0x2C80), (0x3000, 0x3100), (0x3130, 0x3190),
                 (0x3200, 0x3300), (0xA640, 0xA6A0), (0xAB70, 0xABC0), (0xD7B0, 0xD800), (0xF900, 0xF920),
                 (0xFB00, 0xFB50), (0xFE00, 0xFE20), (0xFE70, 0xFF00), (0xFF00, 0xFFF0), (0xFFF0, 0x10000),
                 (0x10400, 0x10450), (0x104B0, 0x10500), (0x1D400, 0x1D420), (0x1E900, 0x1E960),
                 (0x1F100, 0x1F120), (0x1F600, 0x1F610), (0xE0000, 0xE0080), (0xF0000, 0xF0004),
                 (0x10FFFC, 0x110000)]:
        s |= set(range(a, b, 3 if b - a > 120 else 1))
    s |= {0xAC00, 0xAC01, 0xD7A3, 0x4E00, 0x9FFF, 0x20000, 0x2A6DF, 0x2A700, 0x3134A, 0x17000, 0x18800, 0x18B00,
          0x1B170, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xF8FF, 0x16FE4, 0x1E030}
    return sorted(s)
SAMPLE = make_sample()
CHARS = [chr(c) for c in SAMPLE]
"""
_ns = {}
exec(SAMPLE_CODE, _ns)
SAMPLE = _ns["SAMPLE"]
code(SAMPLE_CODE)
chk("unidata_version", "[unicodedata.unidata_version, unicodedata.ucd_3_2_0.unidata_version]")
for fn in ("category", "bidirectional", "east_asian_width", "decomposition"):
    for k in range(0, len(SAMPLE), 1000):
        chk("%s over the sample [%d:%d]" % (fn, k, k + 1000), "'|'.join(unicodedata.%s(c) for c in CHARS[%d:%d])" % (fn, k, k + 1000))
chk("combining over the sample", "','.join(str(unicodedata.combining(c)) for c in CHARS)")
chk("mirrored over the sample", "''.join(str(unicodedata.mirrored(c)) for c in CHARS)")
chk("decimal over the sample", "[unicodedata.decimal(c, -1) for c in CHARS if unicodedata.decimal(c, -1) >= 0]")
chk("digit over the sample", "[(ord(c), unicodedata.digit(c)) for c in CHARS if unicodedata.digit(c, None) is not None]")
chk("numeric over the sample", "[(ord(c), unicodedata.numeric(c)) for c in CHARS if unicodedata.numeric(c, None) is not None]")
for k in range(0, len(SAMPLE), 1000):
    chk("name over the sample [%d:%d]" % (k, k + 1000), "'|'.join(unicodedata.name(c, '-') for c in CHARS[%d:%d])" % (k, k + 1000))
chk("lookup(name(c)) over the sample", "[ord(c) for c in CHARS if unicodedata.name(c, None) and unicodedata.lookup(unicodedata.name(c)) != c]")
chk("numeric values", "[unicodedata.numeric(c) for c in '½⅓¾⅞↉௰௱௲፼万億兆㉈𐄳𑿀𒐲𖭡𞴳']")
chk("decimal/digit/numeric differ", "[[unicodedata.decimal(c, None), unicodedata.digit(c, None), unicodedata.numeric(c, None)] for c in '7٣²①Ⅳ½一']")
chk("defaults and errors", "[unicodedata.decimal('a', 'd'), unicodedata.digit('a', None), unicodedata.numeric('a', 0.5), unicodedata.name('\\x00', 'none'), "
    "err(lambda: unicodedata.decimal('a')), err(lambda: unicodedata.digit('x')), err(lambda: unicodedata.numeric('x')), err(lambda: unicodedata.name('\\x00'))]")
chk("argument errors", "[err(lambda: unicodedata.category('ab')), err(lambda: unicodedata.category(5)), err(lambda: unicodedata.name('')), "
    "err(lambda: unicodedata.mirrored(b'a')), err(lambda: unicodedata.normalize('NFX', 'a')), err(lambda: unicodedata.normalize('NFC', 5)), "
    "err(lambda: unicodedata.is_normalized('X', 'a')), unicodedata.is_normalized('X', ''), unicodedata.normalize('X', '')]")
chk("decomposition strings", "[unicodedata.decomposition(c) for c in 'éﬁ①½ǅÅ㍱가ẛ̣ⅳ']")
chk("east asian widths", "[unicodedata.east_asian_width(c) for c in 'aＡｱ中€α\\u0378\\U0001f600\\u3000\\u20a9']")
chk("lookup: names, aliases, named sequences", "[unicodedata.lookup(n) for n in ['LATIN SMALL LETTER A', 'latin small letter a', 'LATIN CAPITAL LETTER GHA', "
    "'BOM', 'nbsp', 'LINE FEED', 'lf', 'BYTE ORDER MARK', 'KEYCAP NUMBER SIGN', 'LATIN CAPITAL LETTER A WITH MACRON AND GRAVE', "
    "'HANGUL SYLLABLE GAG', 'CJK UNIFIED IDEOGRAPH-4E00', 'CJK UNIFIED IDEOGRAPH-20000', 'cjk compatibility ideograph-f900', "
    "'TANGUT COMPONENT-001', 'nushu character-1b170', 'SNOWMAN', 'EM DASH']]")
chk("lookup: spellings CPython refuses", "[err(lambda: unicodedata.lookup('cjk unified ideograph-4e00')), err(lambda: unicodedata.lookup('hangul syllable ga')), "
    "err(lambda: unicodedata.lookup('CJK UNIFIED IDEOGRAPH-4e00')), err(lambda: unicodedata.lookup('HANGUL SYLLABLE GAX')), "
    "err(lambda: unicodedata.lookup('NO SUCH NAME')), err(lambda: unicodedata.lookup('x' * 300)), err(lambda: unicodedata.lookup(5))]")
chk("\\\\N{} with aliases (not named sequences)", "[ascii('\\N{LATIN CAPITAL LETTER GHA}'), ascii('\\N{BOM}'), ascii('\\N{nbsp}'), ascii('\\N{EM DASH}')]")
chk("named sequences are refused in \\\\N{}", "err(lambda: eval(chr(34) + chr(92) + 'N{KEYCAP NUMBER SIGN}' + chr(34)))[:11]")
code('''
NORM_SAMPLE = ["e\\u0301", "\\u00e9", "\\u1e9b\\u0323", "\\u212b", "\\u2126", "\\ufb01", "\\u2460", "\\u00bd", "\\u1100\\u1161\\u11a8",
               "\\uac01", "\\u1100\\uac00\\u11a8", "\\u0041\\u0328\\u0301\\u0323\\u0307", "\\u05b8\\u05b9\\u05b1\\u0591\\u05c3\\u05b0\\u05ac\\u059f",
               "\\u0592\\u05b7\\u05bc\\u05a5\\u05b0\\u05c0\\u05c4\\u05ad", "\\u1100\\u1161\\u11a7", "\\u0344", "\\u0f73", "\\u2f868",
               "\\U0001d15e\\U0001d165", "\\u0958\\u0300", "a\\u0315\\u0300\\u05ae\\u0300b", "\\u00c5\\u0327", "\\u03d3", "\\u1e0b\\u0323",
               "\\u0071\\u0307\\u0323", "\\u1fed", "\\u2000\\u2001\\u3000", "\\uff76\\uff9e", "\\u3326", "\\u2163", "Straße", "ǅ", "ﬃ"]
''')
for form in ("NFC", "NFD", "NFKC", "NFKD"):
    chk("normalize %s" % form, "[cps(unicodedata.normalize(%r, s)) for s in NORM_SAMPLE]" % form)
    chk("is_normalized %s" % form, "[unicodedata.is_normalized(%r, s) for s in NORM_SAMPLE]" % form)
chk("normalize over the sample (each character, digested)", "[md5(''.join(unicodedata.normalize(f, c) for c in CHARS if not 0xd800 <= ord(c) < 0xe000)) for f in ('NFC', 'NFD', 'NFKC', 'NFKD')]")
code('''
import random
random.seed(113)
POOL = [0x41, 0x61, 0x65, 0x6f, 0x55, 0x300, 0x301, 0x302, 0x303, 0x308, 0x323, 0x327, 0x328, 0x31b, 0x345, 0x3b1, 0x3a9,
        0x1100, 0x1161, 0x11a8, 0xac00, 0xac01, 0x1112, 0x1175, 0x11c2, 0xfb01, 0x2126, 0x212b, 0xc5, 0xe9, 0x1e9b, 0x1ec7,
        0x5d0, 0x5b8, 0x5b9, 0x591, 0x3099, 0x309a, 0x304b, 0x30ab, 0xff76, 0xff9e, 0x2460, 0x3326, 0xf900, 0x2f868, 0x1d15e,
        0x1d165, 0x1d16e, 0x34f, 0x20, 0x2000]
RANDOM_STRINGS = ["".join(chr(random.choice(POOL)) for i in range(random.randint(1, 12))) for k in range(400)]
''')
for form in ("NFC", "NFD", "NFKC", "NFKD"):
    chk("normalize %s of 400 random strings (digested)" % form, "md5('|'.join(unicodedata.normalize(%r, s) for s in RANDOM_STRINGS))" % form)
    chk("is_normalized %s of them" % form, "''.join('1' if unicodedata.is_normalized(%r, s) else '0' for s in RANDOM_STRINGS)" % form)


def normtest():
    path = os.environ.get("NORMTEST", os.path.join(HERE, "unicode", "NormalizationTest-14.0.0.txt"))
    if not os.path.exists(path):
        import urllib.request
        data = urllib.request.urlopen("https://www.unicode.org/Public/14.0.0/ucd/NormalizationTest.txt").read()
        text = data.decode("utf-8")
    else:
        text = open(path, encoding="utf-8").read()
    parts = {}
    part = None
    n1 = 0
    for line in text.splitlines():
        if line.startswith("@Part"):
            part = int(line[5])
            parts[part] = []
            continue
        line = line.split("#")[0].strip()
        if not line or part is None:
            continue
        cols = [c.strip() for c in line.split(";")[:5]]
        if part in (1, 2):
            n1 += 1
            if n1 % (12 if part == 1 else 4):
                continue
        parts[part].append(";".join(cols))
    return parts


NT = normtest()
code('''
# NormalizationTest-14.0.0.txt (parts 0 and 3, every 4th line of part 2, every
# 12th of part 1):
# c1;c2;c3;c4;c5 with c2 == NFC(c1..c3), c4 == NFC(c4, c5), c3 == NFD(c1..c3),
# c5 == NFD(c4, c5), c4 == NFKC(c1..c5), c5 == NFKD(c1..c5)
NORMTEST = {0: %r,
            1: %r,
            2: %r,
            3: %r}

def conformance(lines):
    bad = []
    for k in range(len(lines)):
        c = [unhex(t) for t in lines[k].split(";")]
        n = unicodedata.normalize
        ok = (c[1] == n("NFC", c[0]) == n("NFC", c[1]) == n("NFC", c[2]) and c[3] == n("NFC", c[3]) == n("NFC", c[4])
              and c[2] == n("NFD", c[0]) == n("NFD", c[1]) == n("NFD", c[2]) and c[4] == n("NFD", c[3]) == n("NFD", c[4])
              and c[3] == n("NFKC", c[0]) == n("NFKC", c[1]) == n("NFKC", c[2]) == n("NFKC", c[3]) == n("NFKC", c[4])
              and c[4] == n("NFKD", c[0]) == n("NFKD", c[1]) == n("NFKD", c[2]) == n("NFKD", c[3]) == n("NFKD", c[4])
              and unicodedata.is_normalized("NFC", c[1]) and unicodedata.is_normalized("NFD", c[2])
              and unicodedata.is_normalized("NFKC", c[3]) and unicodedata.is_normalized("NFKD", c[4]))
        if not ok:
            bad.append(lines[k])
    return bad
''' % (NT[0], NT[1], NT[2], NT[3]))
for p in range(4):
    chk("NormalizationTest part %d (%d lines): the lines that fail" % (p, len(NT[p])), "conformance(NORMTEST[%d])" % p)
chk("characters outside part 1 normalize to themselves (every 97th)", "[c for c in range(0, 0x110000, 97) if not 0xd800 <= c < 0xe000 and "
    "unicodedata.decomposition(chr(c)) == '' and not 0xac00 <= c <= 0xd7a3 and any(unicodedata.normalize(f, chr(c)) != chr(c) for f in ('NFC', 'NFD', 'NFKC', 'NFKD'))]")
chk("ucd_3_2_0: properties", "[unicodedata.ucd_3_2_0.category(c) for c in '\\u0221\\u0234A\\u20ac\\u0e33\\u1d00\\u2183'] + [unicodedata.ucd_3_2_0.bidirectional(c) for c in '\\u0221\\u200e\\u0600'] "
    "+ [unicodedata.ucd_3_2_0.east_asian_width(c) for c in '\\u0221A\\u3000'] + [unicodedata.ucd_3_2_0.mirrored(c) for c in '\\u0221(\\u2201']")
chk("ucd_3_2_0: values and names", "[unicodedata.ucd_3_2_0.decimal('\\u0221', None), unicodedata.ucd_3_2_0.numeric('\\u0221', None), unicodedata.ucd_3_2_0.decimal('7'), "
    "unicodedata.ucd_3_2_0.name('\\u0221', 'none'), unicodedata.ucd_3_2_0.name('A'), err(lambda: unicodedata.ucd_3_2_0.lookup('LATIN SMALL LETTER D WITH CURL')), "
    "err(lambda: unicodedata.ucd_3_2_0.lookup('BOM')), unicodedata.ucd_3_2_0.decomposition('\\u0221'), unicodedata.ucd_3_2_0.combining('\\u0301')]")
chk("ucd_3_2_0: the corrected decompositions", "[cps(unicodedata.ucd_3_2_0.normalize('NFC', chr(c))) for c in (0x2f868, 0x2f874, 0x2f91f, 0x2f95f, 0x2f9bf)] + "
    "[cps(unicodedata.normalize('NFC', chr(c))) for c in (0x2f868, 0x2f874, 0x2f91f, 0x2f95f, 0x2f9bf)]")
chk("ucd_3_2_0 over the sample (digested)", "[md5('|'.join(getattr(unicodedata.ucd_3_2_0, f)(c) for c in CHARS)) for f in ('category', 'bidirectional', 'east_asian_width', 'decomposition')]")
chk("ucd_3_2_0 normalize over the sample (digested)", "md5(''.join(unicodedata.ucd_3_2_0.normalize('NFKC', c) for c in CHARS if not 0xd800 <= ord(c) < 0xe000))")
chk("UCD objects", "[type(unicodedata.ucd_3_2_0).__name__, err(lambda: type(unicodedata.ucd_3_2_0)()), unicodedata.ucd_3_2_0.unidata_version]")

# ── str: case mapping, predicates, whitespace, numbers ───────────────────────
code('''
# ── str ──────────────────────────────────────────────────────────────────────
TRICKY = ["ΣΑΣ ΣΑΣ", "ὈΔΥΣΣΕΎΣ", "İstanbul", "ǅemal ǈubav ǋego", "ǆungla ǉ ǌ", "ﬀﬁﬂﬃﬄﬅﬆ", "ŉ ΐ ǰ ẖ ẗ ẘ ẙ ẚ",
          "ﬓﬔﬕﬖﬗ", "ß ẞ Straße", "ꭰꮿ Ꭰ", "ა ბ Ა", "𐐨𐐀 𐓘𐒰", "ᾳ ᾼ ῃ ῌ ῳ ῼ ᾈ ᾀ", "Ⅷ ⅷ ⓐ Ⓐ", "µ ſ ı K Å Ω",
          "hello world", "x1y 2z", "they're bill's friends", "ⅰⅱ ᵃ ª º", "Ǳ ǲ ǳ", "ﬁsh and ﬂour", "\\u0345 ͅ",
          "ΑΣ'", "Α'Σ", "ΑΣΑ", "Σ.", "ΑΣ.Α", "ἈΣ", "Σ", "ΑΣ\\u0301", "ΑΣ\\u0301Α", "ʼΣ", "ἈΣ", "\\U0001e900\\U0001e922"]
''')
for m in ("upper", "lower", "casefold", "title", "capitalize", "swapcase"):
    chk("str.%s of tricky strings" % m, "[s.%s() for s in TRICKY]" % m)
for m in ("isupper", "islower", "istitle", "isalpha", "isalnum", "isprintable", "isidentifier"):
    chk("str.%s of tricky strings" % m, "[s.%s() for s in TRICKY]" % m)
for m in ("upper", "lower", "casefold", "title", "swapcase"):
    chk("str.%s of every sampled character (digested)" % m, "md5('|'.join(c.%s() for c in CHARS))" % m)
for m in ("isalpha", "isdecimal", "isdigit", "isnumeric", "isalnum", "isspace", "isprintable", "isidentifier",
          "isupper", "islower", "istitle"):
    chk("str.%s of every sampled character" % m, "''.join('1' if c.%s() else '0' for c in CHARS)" % m)
chk("the lengths case mapping gives", "[len(c.upper()) for c in 'ßŉǰΐﬃﬁİ'] + [len(c.lower()) for c in 'İẞ'] + [len(c.casefold()) for c in 'ßẞﬁΐ']")
chk("istitle with titlecase letters", "['ǅ'.istitle(), 'ǅa'.istitle(), 'ǅA'.istitle(), 'Ǆa'.istitle(), 'aǅ'.istitle(), 'ǅ'.isupper(), 'ǅ'.islower(), 'Ǆ'.isupper()]")
chk("predicates of the empty str", "[''.isalpha(), ''.isdigit(), ''.isdecimal(), ''.isnumeric(), ''.isspace(), ''.isprintable(), ''.isidentifier(), ''.isupper(), ''.istitle()]")
code('''
SPACES = "".join(chr(c) for c in range(0x3001) if chr(c).isspace())
BREAKS = "\\n\\r\\x0b\\x0c\\x1c\\x1d\\x1e\\x85\\u2028\\u2029"
''')
chk("Unicode whitespace", "[cps(SPACES), [c for c in range(0x80, 0x3001) if chr(c).isspace()], '\\u200b'.isspace(), '\\ufeff'.isspace(), '\\x1f'.isspace(), '\\x1c'.isspace()]")
chk("split() and strip() on Unicode whitespace", "[('a' + SPACES + 'b' + SPACES).split(), (SPACES + 'x' + SPACES).strip(), (SPACES + 'x').lstrip(), ('x' + SPACES).rstrip(), "
    "'a\\u3000b\\u2003c'.split(maxsplit=1), 'a\\u3000b\\u2003c'.rsplit(maxsplit=1), '\\u00a0x\\u00a0'.strip(), '\\u200bx\\u200b'.strip()]")
chk("splitlines on every line boundary", "[('a' + BREAKS.join('bcdefghijkl')).splitlines(), 'x\\r\\ny\\u2028'.splitlines(True), 'a\\x1fb'.splitlines()]")
chk("int() of Unicode digits", "[int('٣٤'), int(' ३ '), int('\\u0e51\\u0e52'), int('١٢', 16), int('\\uff11\\uff10'), int('\\U0001d7ce\\U0001d7cf'), int('\\u3000-٥\\u2003'), int('٣_٣')]")
chk("float() and complex() of Unicode digits", "[float('١.٥'), float(' ٣e٢ '), float('\\uff11\\uff0e\\uff15'.replace('\\uff0e', '.')), complex('١+٢j'), complex(' ٣j ')]")
chk("what they refuse", "[err(lambda: int('²')), err(lambda: int('½')), err(lambda: int('٣x')), err(lambda: float('١٫٥')), err(lambda: float('\\u0661\\u2044')), "
    "err(lambda: int(b'\\xd9\\xa3')), err(lambda: int('\\x7f'))]")
code('''
from decimal import Decimal
''')
chk("Decimal() of Unicode digits", "[str(Decimal('١٢.٣')), str(Decimal(' ٣e٢ ')), str(Decimal('\\uff11\\uff12'))]")
chk("str.isdecimal vs isdigit vs isnumeric", "[[c.isdecimal(), c.isdigit(), c.isnumeric()] for c in '7٣²①Ⅳ½一壹〇𝟘']")

# ── PEP 3131 identifiers ─────────────────────────────────────────────────────
code('''
# ── PEP 3131: identifiers are NFKC-normalized ─────────────────────────────────
ns3131 = {}
exec("ﬁ = 1\\nℌ = 2\\ne\\u0301 = 3\\nµ = 4\\nｘ = 5\\nｶﾞ = 6\\nx\\u00b7y = 7\\n_\\u0662 = 8\\nΩmega = 9\\n", ns3131)
exec("class C3131:\\n    ﬁeld = 10\\n    def ℌelp(self, ﬂag=11):\\n        return ﬂag\\n", ns3131)
exec("def f3131(**kw):\\n    return sorted(kw)\\nkw3131 = f3131(ﬁ=1, ℌ=2)\\n", ns3131)
''')
chk("the names bound", "sorted(k for k in ns3131 if k not in ('__builtins__', 'C3131', 'f3131', 'kw3131'))")
chk("attributes, parameters, keyword arguments", "[ns3131['C3131'].field, ns3131['C3131']().Help(), ns3131['C3131']().Help(flag=12), ns3131['kw3131'], hasattr(ns3131['C3131'], 'ﬁeld')]")
chk("str.isidentifier is not normalized", "['ﬁ'.isidentifier(), 'ℌ'.isidentifier(), '·x'.isidentifier(), 'x·'.isidentifier(), '٣x'.isidentifier(), 'x٣'.isidentifier(), "
    "'℘'.isidentifier(), '℮'.isidentifier(), '゛'.isidentifier(), '_'.isidentifier(), '\\u2118\\u212e'.isidentifier()]")

# ── re ───────────────────────────────────────────────────────────────────────
code('''
# ── re: \\\\w \\\\d \\\\s and IGNORECASE as CPython's sre ───────────────────────
import re
def m(p, s, f=0):
    return bool(re.fullmatch(p, s, f))
''')
chk("IGNORECASE: ß, ſ, Kelvin, Ω, µ", "[m('ß', 'SS', re.I), m('ß', 'ẞ', re.I), m('ẞ', 'ß', re.I), m('s', 'ſ', re.I), m('S', 'ſ', re.I), m('ſ', 's', re.I), "
    "m('k', '\\u212a', re.I), m('\\u212a', 'K', re.I), m('ω', 'Ω', re.I), m('\\u2126', 'ω', re.I), m('µ', 'μ', re.I), m('µ', 'Μ', re.I)]")
chk("IGNORECASE: titlecase, sigma, dotless i, ﬁ", "[m('ǅ', 'ǆ', re.I), m('ǅ', 'Ǆ', re.I), m('σ', 'ς', re.I), m('Σ', 'ς', re.I), m('i', 'İ', re.I), m('ı', 'I', re.I), "
    "m('ﬁ', 'FI', re.I), m('[a-z]', 'K', re.I), m('[a-z]', '\\u212a', re.I), m('[^k]', '\\u212a', re.I), m('\\u0345', 'ι', re.I), m('\\u1fbe', 'Ι', re.I)]")
chk("IGNORECASE with ASCII", "[m('k', '\\u212a', re.I | re.A), m('s', 'ſ', re.I | re.A), m('ß', 'ẞ', re.I | re.A)]")
chk("\\\\w \\\\d \\\\s over the sample", "[''.join(c for c in CHARS if re.fullmatch(r'\\w', c)) == ''.join(c for c in CHARS if c.isalnum() or c == '_'), "
    "''.join(c for c in CHARS if re.fullmatch(r'\\d', c)) == ''.join(c for c in CHARS if c.isdecimal()), "
    "''.join(c for c in CHARS if re.fullmatch(r'\\s', c)) == ''.join(c for c in CHARS if c.isspace())]")
chk("findall over text", "[re.findall(r'\\w+', 'naïve café ₁₂ ½ x²'), re.findall(r'\\d', '١٢३४²'), re.findall(r'\\s', 'a\\u3000b\\u200bc\\x1fd'), "
    "re.findall(r'\\b\\w', 'ǅemal ünal'), re.findall(r'(?i)straße', 'STRASSE straße STRAẞE')]")
chk("case-insensitive backreferences and sub", "[bool(re.fullmatch(r'(?i)(\\w)\\1', 'Ǆǆ')), re.sub(r'(?i)σ', '-', 'ΣσςΣ'), re.sub(r'\\W', '_', 'a·b‿c€d')]")

# ── the CJK codecs ───────────────────────────────────────────────────────────
CJK = ["gb2312", "gbk", "gb18030", "hz", "euc_kr", "cp949", "johab", "big5", "cp950", "big5hkscs",
       "shift_jis", "cp932", "euc_jp", "shift_jis_2004", "euc_jis_2004", "euc_jisx0213", "shift_jisx0213",
       "iso2022_kr", "iso2022_jp", "iso2022_jp_1", "iso2022_jp_2", "iso2022_jp_2004", "iso2022_jp_3", "iso2022_jp_ext"]
TEXTS = {
    "zh": "中文汉字简体：你好，世界！电脑。¥€",
    "tw": "繁體中文：臺灣，電腦。",
    "ja": "日本語のテキスト：ひらがな、カタカナ、漢字。ｶﾀｶﾅ～＼",
    "ko": "한국어 텍스트: 안녕하세요, 세계! 漢字 똠",
    "mix": "Latin é ü ß — “quotes” ①②③ ×÷ αβγ АБВ ¥ ‾ ~\\",
}
code('''
# ── the CJK codecs ───────────────────────────────────────────────────────────
CJK = %r
TEXTS = %r
''' % (CJK, TEXTS))
chk("lookup names and aliases", "[codecs.lookup(n).name for n in ['GBK', 'cp936', 'ms936', 'euc-cn', 'gb18030-2000', 'Big5', 'big5-tw', 'cp950', 'ms950', "
    "'big5-hkscs', 'hkscs', 'sjis', 'shift-jis', 'ms932', 'mskanji', 'eucjp', 'ujis', 'euc-jisx0213', 'shift_jis_2004', 'csiso2022jp', "
    "'iso-2022-jp-2', 'iso2022jp_ext', 'ISO-2022-KR', 'euc-kr', 'ks_c-5601-1987', 'uhc', 'cp1361', 'hz-gb-2312', 'hzgb']]")
for name in CJK:
    for t in TEXTS:
        chk("%s: %s text encoded" % (name, t), "TEXTS[%r].encode(%r, 'backslashreplace')" % (t, name))
    chk("%s: round trip of what it encodes" % name, "[TEXTS[k].encode(%r, 'replace').decode(%r) for k in sorted(TEXTS)]" % (name, name))
code('''
def all_pairs(lo=0x81, hi=0xff):
    out = bytearray()
    for a in range(lo, hi):
        for b in range(0x40, 0xff):
            out.append(a)
            out.append(b)
        out.append(0x0a)
    return bytes(out)
PAIRS = all_pairs()
TEXT_RANGE = "".join(chr(c) for c in list(range(0x80, 0xd800, 3)) + list(range(0xe000, 0x10000, 3)) + list(range(0x20000, 0x2b000, 7)))
''')
for name in CJK:
    if name.startswith("iso2022") or name == "hz":
        continue
    chk("%s: every two-byte sequence decoded (digested)" % name, "md5(PAIRS.decode(%r, 'backslashreplace'))" % name)
    chk("%s: a third of the code points encoded (digested)" % name, "md5(TEXT_RANGE.encode(%r, 'xmlcharrefreplace'))" % name)
code('''
def iso_body(esc):
    out = bytearray(esc)
    for a in range(0x21, 0x7f):
        for b in range(0x21, 0x7f):
            out.append(a)
            out.append(b)
        out.append(0x0a)
        out += esc
    return bytes(out)
''')
for name, escs in [("iso2022_jp", ["\\x1b$B", "\\x1b$@", "\\x1b(J"]), ("iso2022_jp_1", ["\\x1b$(D"]),
                   ("iso2022_jp_2", ["\\x1b$A", "\\x1b$(C", "\\x1b.A\\x1bN", "\\x1b.F\\x1bN"]),
                   ("iso2022_jp_2004", ["\\x1b$(Q", "\\x1b$(P"]), ("iso2022_jp_3", ["\\x1b$(O", "\\x1b$(P"]),
                   ("iso2022_jp_ext", ["\\x1b(I"]), ("iso2022_kr", ["\\x1b$)C\\x0e"])]:
    for e in escs:
        chk("%s: the set after %r decoded (digested)" % (name, e), "md5(iso_body(b'%s').decode(%r, 'backslashreplace'))" % (e, name))
    chk("%s: a third of the code points encoded (digested)" % name, "md5(TEXT_RANGE.encode(%r, 'xmlcharrefreplace'))" % name)
chk("hz: GB2312 in ~{ ~} (digested) and its escapes", "[md5(('~{' + ''.join(chr(a) + chr(b) for a in range(0x21, 0x7f) for b in range(0x21, 0x7f)) + '~}').encode('ascii').decode('hz', 'replace')), "
    "b'~~a~\\nb~{<;~}c'.decode('hz'), 'a~b中'.encode('hz'), err(lambda: b'~x'.decode('hz')), b'~{\\x80'.decode('hz', 'replace')]")
chk("decoding errors (message and extent)", "[err(lambda: b'\\x81'.decode('gbk')), err(lambda: b'\\x81\\x20'.decode('gbk')), err(lambda: b'abc\\xff\\xfe'.decode('big5')), "
    "err(lambda: b'\\x8f\\xa1'.decode('euc_jp')), err(lambda: b'\\x81\\x30\\x81'.decode('gb18030')), err(lambda: b'\\xa4\\xd4\\xa4\\xa1'.decode('euc_kr')), "
    "err(lambda: b'\\x1b$B\\x21'.decode('iso2022_jp')), err(lambda: b'\\x1b$Z'.decode('iso2022_jp')), err(lambda: b'\\xa9\\xa1'.decode('euc_jisx0213'))]")
chk("decoding with each error handler", "[b'a\\x81b\\xff'.decode('gbk', e) for e in ('replace', 'ignore', 'backslashreplace', 'surrogateescape')] + "
    "[err(lambda: b'\\x81'.decode('gbk', 'xmlcharrefreplace')), err(lambda: b'\\x81'.decode('gbk', 'surrogatepass')), err(lambda: b'\\x81'.decode('gbk', 'nosuch'))]")
chk("encoding errors and handlers", "[err(lambda: '\\u20ac'.encode('gb2312')), err(lambda: 'ab\\u0100c'.encode('shift_jis')), "
    "[('x\\u20ac\\u0100y').encode('euc_kr', e) for e in ('replace', 'ignore', 'backslashreplace', 'xmlcharrefreplace', 'namereplace')], "
    "'\\udc81'.encode('gbk', 'surrogateescape'), err(lambda: '\\u20ac'.encode('gbk', 'surrogatepass')), '\\u3042\\u20ac'.encode('iso2022_jp', 'xmlcharrefreplace'), "
    "'\\u3042\\u20ac'.encode('iso2022_jp', 'replace')]")
code('''
def dots(e):
    return ("." * (e.end - e.start), e.end)
codecs.register_error("dots113", dots)
def mark(e):
    return ("[%d:%d]" % (e.start, e.end), e.end)
codecs.register_error("mark113", mark)
''')
chk("handlers registered with register_error", "[b'a\\x81b\\xff\\xfe'.decode('big5', 'dots113'), b'\\x1b$B\\x7f\\x7f\\x1b(B'.decode('iso2022_jp', 'mark113'), "
    "'a\\u20acb'.encode('gbk', 'mark113'), '\\u3042\\u20ac\\u3044'.encode('iso2022_jp', 'mark113')]")
chk("gb18030: the four-byte ranges", "[c.encode('gb18030') for c in '\\x80\\u00a5\\u0452\\u2e81\\ue5e5\\ufffd\\U00010000\\U0010ffff'] + "
    "[b.decode('gb18030') for b in (b'\\x81\\x30\\x81\\x30', b'\\x84\\x31\\xa4\\x39', b'\\x90\\x30\\x81\\x30', b'\\xe3\\x32\\x9a\\x35')]")
chk("euc_kr: KS X 1001:1998 Annex 3 make-up sequences", "['똠'.encode('euc_kr'), b'\\xa4\\xd4\\xa4\\xa8\\xa4\\xd1\\xa4\\xb1'.decode('euc_kr'), '똠'.encode('cp949'), '똠'.encode('johab')]")
chk("big5hkscs: its pairs", "['\\u00ca\\u0304\\u00ca\\u030c\\u00ea\\u0304\\u00ea\\u030c\\u00ca\\u00ea'.encode('big5hkscs'), b'\\x88\\x62\\x88\\x64\\x88\\xa3\\x88\\xa5\\x88\\x66'.decode('big5hkscs'), "
    "'\\U00020021\\U0002003e'.encode('big5hkscs'), '\\U00020000'.encode('big5hkscs', 'replace')]")
chk("JIS X 0213: pairs and plane 2", "['\\u304b\\u309a\\u00e6\\u0300\\u02e9\\u02e5'.encode(c) for c in ('euc_jis_2004', 'shift_jis_2004', 'iso2022_jp_2004')] + "
    "['\\u9b1d\\U00020b9f'.encode(c, 'replace') for c in ('euc_jis_2004', 'euc_jisx0213', 'iso2022_jp_3')]")
chk("iso2022_jp_2: the designations it switches between", "(lambda b: [b, b.decode('iso2022_jp_2')])('日本 한국 中文 Ωé'.encode('iso2022_jp_2'))")
code('''
def inc_encode(name, text, step):
    e = codecs.getincrementalencoder(name)()
    out = [e.encode(text[k:k + step]) for k in range(0, len(text), step)]
    out.append(e.encode("", True))
    return b"".join(out)
def inc_decode(name, data, step):
    d = codecs.getincrementaldecoder(name)()
    out = [d.decode(data[k:k + step]) for k in range(0, len(data), step)]
    out.append(d.decode(b"", True))
    return "".join(out)
INC_TEXT = TEXTS["ja"] + "\\u304b\\u309a\\u00e6\\u0300" + TEXTS["ko"] + TEXTS["zh"]
''')
for name in CJK:
    chk("%s: incremental, one character and one byte at a time" % name,
        "[inc_encode(%r, INC_TEXT.encode(%r, 'replace').decode(%r), 1) == INC_TEXT.encode(%r, 'replace').decode(%r).encode(%r), "
        "inc_decode(%r, INC_TEXT.encode(%r, 'replace'), 1) == INC_TEXT.encode(%r, 'replace').decode(%r)]"
        % (name, name, name, name, name, name, name, name, name, name))
chk("incremental state and reset", "(lambda e, d: [e.encode('\\u3042'), e.getstate(), e.reset(), e.encode('a'), d.decode(b'\\x1b$B$'), d.getstate(), d.decode(b'\"'), d.reset(), d.decode(b'$\"')])"
    "(codecs.getincrementalencoder('iso2022_jp')(), codecs.getincrementaldecoder('iso2022_jp')())")
chk("a pending JIS X 0213 pair", "(lambda e: [e.encode('\\u304b'), e.getstate(), e.encode('\\u309a'), e.encode('\\u304b'), e.encode('', True)])(codecs.getincrementalencoder('euc_jis_2004')())")
code('''
sw_buf = io.BytesIO()
codecs.getwriter("shift_jis")(sw_buf).write("日本語テキスト")
''')
chk("stream reader and writer", "[sw_buf.getvalue(), codecs.getreader('shift_jis')(io.BytesIO(sw_buf.getvalue())).read(), "
    "codecs.getreader('iso2022_jp')(io.BytesIO('一\\n二\\n'.encode('iso2022_jp'))).readlines(), "
    "codecs.getreader('gb18030')(io.BytesIO('中文'.encode('gb18030'))).read(1)]")
chk("incremental encoder/decoder classes", "[[k.__name__ for k in type(codecs.lookup('gbk').incrementalencoder()).__mro__[1:2]], codecs.lookup('gbk').incrementalencoder().errors, "
    "codecs.lookup('big5').incrementaldecoder('replace').errors]")
chk("str(b, codec), bytes(s, codec), bytearray(s, codec)", "[str('中文'.encode('gbk'), 'gbk'), bytes('中文', 'big5'), bytearray('かな', 'euc_jp')]")
chk("codecs.encode/decode", "[codecs.encode('かな', 'shift_jis'), codecs.decode(b'\\x82\\xa9\\x82\\xc8', 'shift_jis'), codecs.lookup('shift_jis').encode('かな'), codecs.lookup('shift_jis').decode(b'\\x82\\xa9')]")

# ── utf-7 ────────────────────────────────────────────────────────────────────
code('''
# ── utf-7 ────────────────────────────────────────────────────────────────────
UTF7_TEXTS = ["Hi Mom -\\u263a-!", "A\\u2262\\u0391.", "\\U0001f600", "+", "~\\\\", "a-b", "\\ud800", "x\\u00e9y", "1 + 1 = 2",
              "\\u65e5\\u672c\\u8a9e", "a\\tb\\nc", "!\\"#$%&*;<=>@[]^_`{|}"]
UTF7_BYTES = [b"+\\x80", b"\\x80", b"+AGE", b"+AGE-", b"+AGEx", b"a+", b"+2D3cAA-", b"+2D3cAA", b"+-", b"+AGEA", b"+AGEAAQ-",
              b"+ZeVnLIqe-", b"+AAA", b"+2D3c-", b"+2D3cAEE-"]
''')
chk("utf-7 encode", "[s.encode('utf-7') for s in UTF7_TEXTS]")
chk("utf-7 decode of what it encodes", "[s.encode('utf-7').decode('utf-7') == s for s in UTF7_TEXTS]")
for e in ("strict", "replace", "ignore", "backslashreplace", "surrogateescape"):
    chk("utf-7 decode, %s" % e, "[err(lambda: b.decode('utf-7', %r)) if %r in ('strict', 'surrogateescape') else b.decode('utf-7', %r) for b in UTF7_BYTES]" % (e, e, e))
chk("utf-7 incremental", "[codecs.utf_7_decode(b'a+AGE', 'strict', False), codecs.utf_7_decode(b'a+AGEA', 'strict', False), codecs.utf_7_decode(b'+ZeVnLIqe', 'strict', False), "
    "codecs.utf_7_encode('\\u00e9'), codecs.lookup('utf7').name, codecs.lookup('u7').name, codecs.lookup('unicode-1-1-utf-7').name, inc_decode('utf-7', b'+ZeVnLIqe-x+AGE-', 1)]")

# ── the single-byte code pages ───────────────────────────────────────────────
import encodings.aliases
SINGLE = sorted(n[:-3] for n in os.listdir("/usr/lib/python3.11/encodings")
                if n.endswith(".py") and n[:-3] not in CJK and n[:-3] not in (
                    "__init__", "aliases", "base64_codec", "bz2_codec", "charmap", "hex_codec", "idna", "mbcs", "oem",
                    "palmos", "punycode", "quopri_codec", "raw_unicode_escape", "rot_13", "undefined", "unicode_escape",
                    "utf_16", "utf_16_be", "utf_16_le", "utf_32", "utf_32_be", "utf_32_le", "utf_7", "utf_8", "utf_8_sig",
                    "uu_codec", "zlib_codec"))
SINGLE.append("palmos")
code('''
# ── the single-byte code pages ───────────────────────────────────────────────
SINGLE = %r
ALL_BYTES = bytes(range(256))
''' % SINGLE)
chk("every byte of every single-byte code page (digested)", "[(n, md5(ALL_BYTES.decode(n, 'replace'))) for n in SINGLE]")
chk("every byte of cp1250-cp1258, mac_roman, koi8_r, cp437", "[ALL_BYTES[128:].decode(n, 'replace') for n in ('cp1250', 'cp1251', 'cp1252', 'cp1253', 'cp1254', 'cp1255', 'cp1256', 'cp1257', 'cp1258', 'mac_roman', 'koi8_r', 'cp437')]")
chk("encoding back what they decode", "[n for n in SINGLE if ALL_BYTES.decode(n, 'ignore').encode(n) != bytes(b for b in ALL_BYTES if ALL_BYTES[b:b + 1].decode(n, 'ignore'))]")
chk("cp1250-cp1258 and mac_roman: errors", "[err(lambda: b'\\x81'.decode('cp1252')), err(lambda: '\\u4e00'.encode('cp1250')), '\\u20ac\\u2030'.encode('cp1252'), "
    "'\\u0160\\u0161'.encode('cp1250'), '\\u20ac'.encode('mac_roman', 'replace'), b'\\xf0'.decode('mac_roman')]")

# ── idna: nameprep over unicodedata.ucd_3_2_0 ────────────────────────────────
chk("idna with RFC 3491 nameprep", "[s.encode('idna') for s in ('Straße.de', 'Bücher.example', 'ﬁ.com', 'ＡＢＣ.jp', 'Ⅻ.org', 'δοκιμή.gr', 'münchen\\u00ad.de', 'пример.рф')]")
chk("idna decode and its errors", "[b'xn--bcher-kva.example'.decode('idna'), b'www.xn--bcher-kva.example.'.decode('idna'), err(lambda: 'a\\u0000b.c'.encode('idna')), "
    "'Violation of BIDI requirement 2' in err(lambda: '\\u0627a\\u0628.c'.encode('idna')), err(lambda: '\\u0221.c'.encode('idna') and None)]")

# ── email charsets ───────────────────────────────────────────────────────────
code('''
# ── email charsets that need the CJK codecs ──────────────────────────────────
import email.charset, email.header, email.message, email.policy
''')
chk("email.charset", "[(lambda c: [c.input_codec, c.output_codec, c.header_encoding, c.body_encoding, c.get_output_charset()])(email.charset.Charset(n)) "
    "for n in ('iso-2022-jp', 'euc-jp', 'shift_jis', 'gb2312', 'big5', 'euc-kr', 'utf-7')]")
chk("email.header encode", "[email.header.Header('日本語のテキスト', 'iso-2022-jp').encode(), email.header.Header('中文', 'gb2312').encode(), "
    "email.header.Header('한국어', 'euc-kr').encode(), email.header.Header('繁體', 'big5').encode()]")
chk("email.header decode", "[email.header.decode_header('=?iso-2022-jp?b?GyRCRnxLXDhsGyhC?='), str(email.header.make_header(email.header.decode_header('=?iso-2022-jp?b?GyRCRnxLXDhsGyhC?='))), "
    "str(email.header.make_header(email.header.decode_header('=?gb2312?b?1tDOxA==?= =?euc-kr?b?x9Gxub7u?=')))]")
code('''
msg113 = email.message.EmailMessage()
msg113["Subject"] = "日本語の件名"
msg113.set_content("本文です。", charset="iso-2022-jp")
msg113b = email.message.Message()
msg113b.set_payload("中文正文", "gb2312")
''')
chk("email messages in CJK charsets", "[msg113.get_content(), msg113['Content-Type'], msg113.get_payload(decode=True), msg113b.get_payload(decode=True).decode('gb2312'), msg113b['Content-Transfer-Encoding']]")

NYTHON_ONLY = '''
# ── Nython only ──────────────────────────────────────────────────────────────
if nython:
    # unicodedata.stream_safe: UAX #15's Stream-Safe Text Format
    many = "a" + "\\u0301" * 40 + "b"
    safe = unicodedata.stream_safe(many)
    check("stream_safe inserts U+034F before the 31st non-starter", [cps(safe).count(0x34f), safe.index("\\u034f"), len(safe), unicodedata.normalize("NFC", safe).count("\\u034f")],
          [1, 31, 43, 1])
    check("stream_safe leaves ordinary text alone", [unicodedata.stream_safe(s) == s for s in ["", "abc", "e\\u0301", "\\uac00\\u11a8", "a" + "\\u0301" * 30]], [True, True, True, True, True])
    check("stream_safe counts NFKD's non-starters", [cps(unicodedata.stream_safe("\\u0344" * 16)).count(0x34f), cps(unicodedata.stream_safe("\\u0344" * 15)).count(0x34f)], [1, 0])
    check("unicodedata.UCD is the type of ucd_3_2_0", [isinstance(unicodedata.ucd_3_2_0, unicodedata.UCD), unicodedata.UCD.__module__], [True, "unicodedata"])
    # fuzzy matching (Quick Open) by search keys: NFKD without accents, folded
    check("fuzzy_score matches across accents, ligatures, ß and width", [fuzzy_score("resume", "résumé") is not None, fuzzy_score("file", "ﬁle.txt") is not None,
          fuzzy_score("strasse", "Straße") is not None, fuzzy_score("abc", "ＡＢＣ") is not None, fuzzy_score("xyz", "résumé")],
          [True, True, True, True, None])
    check("fuzzy_positions are the original characters", [fuzzy_positions("resume", "résumé"), fuzzy_positions("strasse", "Straße"), fuzzy_positions("fi", "ﬁ")],
          [[0, 1, 2, 3, 4, 5], [0, 1, 2, 3, 4, 5], [0]])
    check("fuzzy_rank with accents: an accented name ranks as its plain spelling", [fuzzy_rank("cafe", ["Cafeteria.ny", "x.ny", "Café.ny", "c-a-f-e.ny"]),
          fuzzy_rank("cafe", ["Cafeteria.ny", "x.ny", "Cafe.ny", "c-a-f-e.ny"]), fuzzy_score("cafe", "Café.ny") == fuzzy_score("cafe", "Cafe.ny")], [[3, 2, 0], [3, 2, 0], True])
    check("ASCII scores are unchanged", [fuzzy_score("sal", "File: Save All"), fuzzy_positions("sal", "File: Save All")], [22, [6, 11, 12]])
    # PEP 3131 in Nython source too: an identifier Python refuses stays as written
    nsny = {}
    exec("x\\U0001f600 = 1", nsny)
    check("a Nython identifier with an emoji", "x\\U0001f600" in nsny, True)
'''

FOOTER = '''
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        g = repr(r[2])
        w = repr(r[3])
        if len(g) > 400 or len(w) > 400:
            k = 0
            while k < len(g) and k < len(w) and g[k] == w[k]:
                k += 1
            print("FAIL " + r[0] + ": differs at " + str(k) + ": got ..." + g[max(0, k - 80):k + 120] + " want ..." + w[max(0, k - 80):k + 120])
        else:
            print("FAIL " + r[0] + ": got " + g + " want " + w)
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT113 PASSED ===")
'''


def main():
    ns = {"__name__": "__gen113__"}
    out = [HEADER, PREAMBLE]
    exec(PREAMBLE, ns)
    count = 0
    for e in E:
        if e[0] == "code":
            exec(e[1], ns)
            out.append(e[1].rstrip("\n") + "\n")
            continue
        name, expr = e[1], e[2]
        try:
            v = eval(expr, ns)
        except Exception as ex:
            raise SystemExit("check %r failed under python3: %r" % (name, ex))
        want = repr(v)
        try:
            if eval(want, ns) != v:
                raise SystemExit("repr does not round-trip: %r -> %s" % (name, want[:200]))
        except SystemExit:
            raise
        except Exception as ex:
            raise SystemExit("repr does not evaluate: %r -> %s (%r)" % (name, want[:200], ex))
        out.append("check(%r, %s,\n      %s)\n" % (name, expr, want))
        count += 1
    out.append(NYTHON_ONLY)
    out.append(FOOTER)
    with open(os.path.join(ROOT, "examples", "vm_audit113.ny"), "w", encoding="utf-8") as f:
        f.write("".join(out))
    print(count, "checks generated")


if __name__ == "__main__":
    main()
