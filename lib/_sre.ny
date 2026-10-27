# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/_sre.ny - the part of CPython's _sre C module that re/_parser.py and
# re/_compiler.py use (round 87): the code size and limits, the case
# helpers sre's compiler calls, and compile(), which makes a Pattern over
# Nython's native engine (src/builtins/nyre.cpp) from the pattern's source -
# the code list CPython's compiler made is checked, not run.
#
#   MAGIC CODESIZE MAXREPEAT MAXGROUPS getcodesize()
#   ascii_iscased(ch) unicode_iscased(ch) ascii_tolower(ch) unicode_tolower(ch)
#   compile(pattern, flags, code, groups, groupindex, indexgroup)
#
# The case helpers use sre's simple (one character) mappings: a character
# whose full mapping is longer maps to the mapping's first character, as
# CPython's simple tables give for every such character in Unicode 14.

MAGIC = 20221023
CODESIZE = 4
MAXREPEAT = 4294967295
MAXGROUPS = 1073741823
copyright = " SRE 2.2.2 Copyright (c) 1997-2002 by Secret Labs AB "


def getcodesize():
    return CODESIZE


def ascii_iscased(ch):
    return ch < 128 and (65 <= ch <= 90 or 97 <= ch <= 122)


def ascii_tolower(ch):
    if 65 <= ch <= 90:
        return ch + 32
    return ch


def _simple(s, ch):
    if len(s) == 1:
        return ord(s)
    if not s:
        return ch
    return ord(s[0])


def unicode_tolower(ch):
    if ch < 128:
        return ascii_tolower(ch)
    return _simple(chr(ch).lower(), ch)


def _unicode_toupper(ch):
    if ch < 128:
        if 97 <= ch <= 122:
            return ch - 32
        return ch
    return _simple(chr(ch).upper(), ch)


def unicode_iscased(ch):
    if ch < 128:
        return ascii_iscased(ch)
    return unicode_tolower(ch) != ch or _unicode_toupper(ch) != ch


def compile(pattern, flags, code, groups, groupindex, indexgroup):
    # what re/_compiler.py's compile() returns: a Pattern for the source
    # (TEMPLATE and DEBUG are the compiler's own, not the matcher's)
    import re
    if pattern is None:
        raise TypeError("_sre.compile() needs the pattern's source on Nython")
    return re.compile(pattern, flags & ~(1 | 128))
