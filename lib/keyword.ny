# nython: module    (import it by name: it runs in a module scope of its own)
# lib/keyword.ny - Python's keyword module (round 77).
#
#     import keyword
#     keyword.iskeyword("lambda")      # True
#
# kwlist          CPython 3.11's hard keywords, sorted ("False" ... "yield")
# softkwlist      CPython 3.11's soft keywords ("_", "case", "match")
# iskeyword(s)    s in kwlist (False for anything that is not a str)
# issoftkeyword(s)
#
# Nython only:
# nykwlist        the words Nython's lexer reserves beyond Python's: its
#                 keyword table (src/Lexer.cpp, KeywordTokens), read at run
#                 time through _ny_keywords(), minus kwlist and softkwlist -
#                 so it cannot drift from what the lexer really does (the
#                 aliases true/false/none/null, var/let/const, fn/func/fun,
#                 struct, enum, unless/until/repeat, throw/catch, ...). The
#                 parser still accepts several of them as names where a name
#                 is expected (a parameter called `default` or `func`, a
#                 method called `match`); `self`, `new` and `ref` are not
#                 usable as variable names.
# isnykeyword(s)  s in nykwlist
#
# Not here: nothing - this is the whole of CPython's module. Python 3.12
# added "type" to softkwlist (PEP 695 type statements); Nython has no
# `type X = ...` statement, so the 3.11 list is the honest one.

__all__ = ["iskeyword", "issoftkeyword", "kwlist", "softkwlist"]

kwlist = [
    "False",
    "None",
    "True",
    "and",
    "as",
    "assert",
    "async",
    "await",
    "break",
    "class",
    "continue",
    "def",
    "del",
    "elif",
    "else",
    "except",
    "finally",
    "for",
    "from",
    "global",
    "if",
    "import",
    "in",
    "is",
    "lambda",
    "nonlocal",
    "not",
    "or",
    "pass",
    "raise",
    "return",
    "try",
    "while",
    "with",
    "yield"
]

softkwlist = [
    "_",
    "case",
    "match"
]

_kwset = frozenset(kwlist)
_softkwset = frozenset(softkwlist)


def iskeyword(s):
    # frozenset(kwlist).__contains__, as CPython's: anything unhashable
    # raises TypeError, any other non-str is simply not a keyword
    if isinstance(s, (list, dict, set)):
        raise TypeError("unhashable type: '" + type(s).__name__ + "'")
    return isinstance(s, str) and s in _kwset


def issoftkeyword(s):
    if isinstance(s, (list, dict, set)):
        raise TypeError("unhashable type: '" + type(s).__name__ + "'")
    return isinstance(s, str) and s in _softkwset


def _nython_words():
    var out = []
    for w in _ny_keywords():
        if w not in _kwset and w not in _softkwset and w not in out:
            out.append(w)
    return sorted(out)

nykwlist = _nython_words()
_nykwset = frozenset(nykwlist)


def isnykeyword(s):
    return isinstance(s, str) and s in _nykwset
