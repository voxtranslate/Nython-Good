# vm_audit78.ny - Python's re module, both engines (round 78).
#
# Written in the subset Nython and Python share, so the same file runs
# under python3 (`python3 examples/vm_audit78.ny` must also pass) - every
# expected value below is what CPython computes.
#
#   syntax      literals and escapes, classes, . ^ $ \A \Z \b \B, groups,
#               named groups and references, lookahead/lookbehind, comments,
#               inline and scoped flags, every quantifier (lazy, possessive),
#               atomic groups, conditionals, alternation
#   flags       values, combinations, IGNORECASE (Unicode and ASCII),
#               MULTILINE, DOTALL, VERBOSE, ASCII
#   text        Unicode \w \d \s and case folding, character positions,
#               bytes patterns
#   API         compile/search/match/fullmatch (pos, endpos), split,
#               findall, finditer, sub/subn (templates, functions, count),
#               escape, purge, Pattern and Match objects and their reprs
#   rules       Python 3.7+ empty matches in sub/split/findall/finditer,
#               sre's empty-iteration rule, captures across backtracking
#   errors      re.error messages, positions, lineno/colno; TypeError,
#               IndexError, ValueError, OverflowError
#   scale       catastrophic patterns finish (memoization; skipped under
#               CPython, whose sre would run for years), a 1,000,000
#               character subject
#
# Must pass on both engines (and python3):
#     ./build/nython-cli examples/vm_audit78.ny
#     ./build/nython-cli --vm examples/vm_audit78.ny
try:
    true
    IS_PY = False
except NameError:
    true = True
    false = False
    none = None
    IS_PY = True

import re

results = []


def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])


def err(f):
    try:
        f()
        return "no error"
    except re.error as e:
        return "error: " + str(e)
    except Exception as e:
        return type(e).__name__ + ": " + str(e)


def g0(m):
    if m:
        return m.group(0)
    return None


def spans(pattern, s, flags=0):
    return [m.span() for m in re.finditer(pattern, s, flags)]


# ── literals and escapes ─────────────────────────────────────────────────────
check("literal", g0(re.search("bc", "abcd")), "bc")
check("escapes", [g0(re.match(r"\t\n\r\f\v", "\t\n\r\f\v")), g0(re.match(r"a\\b", "a\\b"))], ["\t\n\r\f\v", "a\\b"])
check("hex/unicode", [g0(re.match(r"\x41é\U0001F600", "Aé\U0001F600")), g0(re.match(r"\0", "\0"))], ["Aé\U0001F600", "\0"])
check("octal", [g0(re.match(r"\101\0101", "AA")), g0(re.match(r"\08", "\x008"))], [None, "\x008"])
check("octal 2", [g0(re.match(r"\101", "A")), g0(re.match(r"[\101-\103]+", "ABCD"))], ["A", "ABC"])
check("escaped specials", g0(re.match(r"\.\*\+\?\(\)\[\]\{\}\|\^\$", ".*+?()[]{}|^$")), ".*+?()[]{}|^$")
check("non-letter escapes", g0(re.match(r"\-\#\ \&\~", "-# &~")), "-# &~")
check("categories", [re.findall(r"\d+", "a12b345"), re.findall(r"\w+", "hi, you_2!"), re.findall(r"\s", "a b\tc\n")],
      [["12", "345"], ["hi", "you_2"], [" ", "\t", "\n"]])
check("negated categories", [re.findall(r"\D+", "a12b"), re.findall(r"\W+", "a, b!"), re.findall(r"\S+", " ab  c ")],
      [["a", "b"], [", ", "!"], ["ab", "c"]])
check("dot", [g0(re.match(".+", "ab\ncd")), g0(re.match(".+", "ab\ncd", re.S)), g0(re.match("(?s).+", "a\nb"))], ["ab", "ab\ncd", "a\nb"])
check("braces literal", [g0(re.match("a{", "a{")), g0(re.match("a{,", "a{,")), g0(re.match("a{}", "a{}")), g0(re.match("x{1,2", "x{1,2"))],
      ["a{", "a{,", "a{}", "x{1,2"])

# ── character classes ────────────────────────────────────────────────────────
check("class ranges", re.findall("[a-cx-z0-2]+", "abcdxyz0123"), ["abc", "xyz012"])
check("class negation", re.findall("[^a-c]+", "abxyzcd"), ["xyz", "d"])
check("class specials", [g0(re.match("[]a]+", "]a]")), g0(re.match("[^]]+", "ab]")), g0(re.match("[a-]+", "a-a")), g0(re.match("[-a]+", "-a"))],
      ["]a]", "ab", "a-a", "-a"])
check("class escapes", [g0(re.match(r"[\d\s]+", "1 2\t3")), g0(re.match(r"[\w.]+", "a.b_c!")), g0(re.match(r"[\]\\]+", "]\\]"))],
      ["1 2\t3", "a.b_c", "]\\]"])
check("class \\b is backspace", g0(re.match(r"[\b]", "\b")), "\b")
check("class negated shorthand", [g0(re.match(r"[^\d]+", "ab1")), g0(re.match(r"[\W\d]+", "!1a"))], ["ab", "!1"])
check("class unicode range", re.findall("[Ѐ-ӿ]+", "abc привет x"), ["привет"])

# ── anchors ──────────────────────────────────────────────────────────────────
check("^ $", [g0(re.search("^b", "ab")), g0(re.search("a$", "ba")), g0(re.search("a$", "ba\n")), g0(re.search("a$", "ba\n\n"))],
      [None, "a", "a", None])
check("multiline", [re.findall("^\\w", "ab\ncd\nef", re.M), re.findall("\\w$", "ab\ncd\nef", re.M), re.findall("(?m)^$", "a\n\nb\n")],
      [["a", "c", "e"], ["b", "d", "f"], ["", ""]])
check("\\A \\Z", [g0(re.search(r"\Aa", "ba")), g0(re.search(r"a\Z", "ba\n")), g0(re.search(r"a\Z", "ba")), g0(re.search(r"\Ab", "ab\nb", re.M))],
      [None, None, "a", None])
check("\\b \\B", [re.findall(r"\bfoo\b", "foo foobar barfoo foo."), re.findall(r"\Boo\B", "foo boot"), spans(r"\b", "ab cd")],
      [["foo", "foo"], ["oo"], [(0, 0), (2, 2), (3, 3), (5, 5)]])
check("\\b on empty", [re.match(r"\b", ""), re.match(r"\B", ""), g0(re.match(r"\B", "-"))], [None, None, ""])
check("$ before final newline only", [spans("$", "a\n"), spans("$", "a\nb")], [[(1, 1), (2, 2)], [(3, 3)]])

# ── groups ───────────────────────────────────────────────────────────────────
m = re.match(r"(a)(b(c))(?:d)(?P<e>e)", "abcde")
check("groups", [m.groups(), m.group(0), m.group(3), m.group("e"), m.lastindex, m.lastgroup], [("a", "bc", "c", "e"), "abcde", "c", "e", 4, "e"])
check("group spans", [m.span(), m.span(2), m.start(3), m.end("e"), m.regs], [(0, 5), (1, 3), 2, 5, ((0, 5), (0, 1), (1, 3), (2, 3), (4, 5))])
check("group(*)", [m.group(1, "e", 0), m[2], m["e"]], [("a", "e", "abcde"), "bc", "e"])
m = re.match(r"(a)|(b)", "b")
check("unmatched group", [m.groups(), m.groups("-"), m.span(1), m.start(1), m.lastindex], [(None, "b"), ("-", "b"), (-1, -1), -1, 2])
m = re.match(r"(?P<first>\w+) (?P<last>\w+)?", "Jane ")
check("groupdict", [m.groupdict(), m.groupdict(""), dict(m.re.groupindex)], [{"first": "Jane", "last": None}, {"first": "Jane", "last": ""}, {"first": 1, "last": 2}])
check("lastindex nested", [re.match("((a)b)", "ab").lastindex, re.match("(a)(b)", "ab").lastindex, re.match("a", "a").lastindex, re.match("(?=(a))a", "a").lastindex],
      [1, 2, None, 1])
check("lastgroup", [re.match("(?P<x>a)(b)", "ab").lastgroup, re.match("(?P<x>a)(?P<y>b)", "ab").lastgroup], [None, "y"])
check("backreferences", [g0(re.match(r"(a+)b\1", "aabaa")), g0(re.search(r"(\w)\1", "abccd")), g0(re.match(r"(?P<q>['\"]).*?(?P=q)", "'it''s'"))],
      ["aabaa", "cc", "'it'"])
check("backref to unmatched group", [re.match(r"(a)?b\1", "b"), g0(re.match(r"(a)?b\1?", "b"))], [None, "b"])
check("backref ignorecase", [g0(re.match(r"(a)\1", "aA", re.I)), re.match(r"(s)\1", "sſ", re.I)], ["aA", None])
check("group in repeat keeps last", [re.match("(a|b)*", "abba").group(1), re.match("(?:(a)|b)*", "ab").groups(), re.match("(?:(a)|(b))*", "ab").groups()],
      ["a", ("a",), ("a", "b")])
check("comments", [g0(re.match("a(?#comment)b", "ab")), g0(re.match("a(?#x)+", "aaa"))], ["ab", "aaa"])
check("many groups", re.match("(a)" * 120, "a" * 120).group(120), "a")
check("deep nesting", g0(re.match("(" * 100 + "a" + ")" * 100, "a")), "a")

# ── lookaround ───────────────────────────────────────────────────────────────
check("lookahead", [re.findall(r"\w+(?=,)", "a, bb, c"), re.findall(r"\b\w+\b(?!,)", "a, bb, c"), g0(re.match(r"(?=(\w+))\w", "abc"))],
      [["a", "bb"], ["c"], "a"])
check("lookahead captures", re.match(r"(?=(\w+))\w", "abc").group(1), "abc")
check("lookbehind", [re.findall(r"(?<=\$)\d+", "$10 20 $30"), re.findall(r"(?<!\$)\b\d+", "$10 20 $30"), g0(re.search(r"(?<=ab)c", "abc"))],
      [["10", "30"], ["20"], "c"])
check("lookbehind sees before pos", [g0(re.compile(r"(?<=a)b").search("ab", 1)), g0(re.compile(r"(?<!a)b").search("ab", 1))], ["b", None])
check("lookbehind fixed width", [g0(re.search(r"(?<=a|b)c", "bc")), g0(re.search(r"(a)x(?<=\1x)y", "zaxy")), g0(re.search(r"(?<=\x41{2})B", "AAB"))],
      ["c", "axy", "B"])
check("negative lookahead restores", re.match(r"(a)(?!(b)c)", "abd").groups(), ("a", None))
check("lookaround at edges", [re.match(r"(?<=a)", "a"), g0(re.search(r"(?<!a)$", "ba")), g0(re.search(r"(?!x)", ""))], [None, None, ""])

# ── flags ────────────────────────────────────────────────────────────────────
check("flag values", [int(re.I), int(re.M), int(re.S), int(re.X), int(re.A), int(re.U), int(re.L), int(re.IGNORECASE | re.MULTILINE), int(re.DOTALL | re.VERBOSE | re.ASCII)],
      [2, 8, 16, 64, 256, 32, 4, 10, 336])
check("Pattern.flags", [re.compile("a").flags, re.compile("a", re.I).flags, re.compile(b"a").flags, re.compile("(?im)a").flags, re.compile("a", re.A).flags],
      [32, 34, 0, 42, 256])
check("ignorecase", [g0(re.match("AbC", "aBc", re.I)), g0(re.match("[a-z]+", "HeLLo", re.I)), g0(re.match("[^a]", "A", re.I)), g0(re.match("(?i)x", "X"))],
      ["aBc", "HeLLo", None, "X"])
check("scoped flags", [g0(re.match("a(?i:b)c", "aBc")), re.match("a(?i:b)c", "aBC"), g0(re.match("(?i)a(?-i:b)c", "AbC")), re.match("(?i)a(?-i:b)c", "ABC")],
      ["aBc", None, "AbC", None])
check("scoped s and m", [g0(re.match("(?s:.)+", "\n\n")), re.findall("(?m:^a)", "a\na"), g0(re.match("a(?x: b c )d", "abcd"))], ["\n\n", ["a", "a"], "abcd"])
check("verbose", g0(re.match(r"""(?x)
        (\d+)   # digits
        \s* - \s*
        (\d+)   # more digits
        \#      # an escaped hash
    """, "12 - 34#")), "12 - 34#")
check("verbose class keeps spaces", g0(re.match("[ a]+ b", " a a b", re.X)), " a a b")
check("verbose escaped space", g0(re.match(r"a\ b", "a b", re.X)), "a b")
check("ascii flag", [re.findall(r"\w+", "café naïve", re.A), re.findall(r"(?a)\d", "1١"), g0(re.match("é", "É", re.I | re.A))],
      [["caf", "na", "ve"], ["1"], None])

# ── Unicode ──────────────────────────────────────────────────────────────────
check("unicode \\w", re.findall(r"\w+", "café καλη мир 日本 x_1"),
      ["café", "καλη", "мир", "日本", "x_1"])
check("unicode \\d \\s", [re.findall(r"\d", "1١१x"), re.findall(r"\s", "a b c　d\x1c")], [["1", "١", "१"], [" ", " ", "　", "\x1c"]])
check("character positions", [re.search("b", "ééb").span(), re.search("\U0001F600(.)", "a\U0001F600bc").span(1)], [(2, 3), (2, 3)])
check("unicode ignorecase", [g0(re.match("σ+", "Σσς", re.I)), g0(re.match("straße", "STRAẞE", re.I)), g0(re.match("[а-я]+", "ПРИ", re.I))],
      ["Σσς", "STRAẞE", "ПРИ"])
check("sre case equivalences", [g0(re.match("s", "ſ", re.I)), g0(re.match("k", "K", re.I)), g0(re.match("[k]", "K", re.I)), re.match("ss", "ß", re.I), g0(re.match("i", "İ", re.I))],
      ["ſ", "K", "K", None, "İ"])
check("unicode \\b", [re.findall(r"\b\w", "été café"), spans(r"\b", "é")], [["é", "c"], [(0, 0), (1, 1)]])
check("non-BMP", [re.findall(".", "a\U0001F600b"), g0(re.match("[\U0001F600-\U0001F64F]+", "\U0001F600\U0001F64Fx"))], [["a", "\U0001F600", "b"], "\U0001F600\U0001F64F"])
check("unicode sub positions", re.sub("é", "e", "café été"), "cafe ete")

# ── bytes ────────────────────────────────────────────────────────────────────
check("bytes", [g0(re.match(rb"\w+", b"abc def")), re.findall(rb"\d+", b"a1b22"), re.sub(rb"b", b"X", b"abcb"), re.split(rb",", b"a,b")],
      [b"abc", [b"1", b"22"], b"aXcX", [b"a", b"b"]])
check("bytes ascii semantics", [re.findall(rb"\w+", b"caf\xe9"), g0(re.match(rb"\xe9", b"\xc9", re.I)), g0(re.match(rb"[\x80-\xff]+", b"\x80\xff!"))],
      [[b"caf"], None, b"\x80\xff"])
check("bytes groups", [re.match(rb"(?P<n>a)(b)", b"ab").groupdict(), re.match(rb"(a)(b)", b"ab").groups(), re.escape(b"a.b")],
      [{"n": b"a"}, (b"a", b"b"), b"a\\.b"])
check("bytes template", [re.sub(rb"(a)", rb"[\1]", b"xa"), re.match(rb"(a)", b"a").expand(rb"<\g<1>>")], [b"x[a]", b"<a>"])
check("bytes repr", [repr(re.compile(b"a+", re.I)), repr(re.search(rb"\d", b"x5"))], ["re.compile(b'a+', re.IGNORECASE)", "<re.Match object; span=(1, 2), match=b'5'>"])

# ── quantifiers ──────────────────────────────────────────────────────────────
check("greedy", [g0(re.match("a*", "aaa")), g0(re.match("a+", "aaab")), g0(re.match("a?", "aa")), g0(re.match("a{2}", "aaa")), g0(re.match("a{2,}", "aaaa")), g0(re.match("a{,2}", "aaa")), g0(re.match("a{1,3}", "aaaa"))],
      ["aaa", "aaa", "a", "aa", "aaaa", "aa", "aaa"])
check("lazy", [g0(re.match("a*?", "aaa")), g0(re.match("a+?", "aaa")), g0(re.match("a??", "a")), g0(re.match("a{2,}?", "aaaa")), g0(re.match("<.*?>", "<a><b>")), g0(re.match("a{1,3}?b", "aaab"))],
      ["", "a", "", "aa", "<a>", "aaab"])
check("possessive", [g0(re.match("a*+", "aaa")), re.match("a*+a", "aaa"), g0(re.match("a++b", "aab")), re.match('"[^"]*+"x', '"ab"'), g0(re.match("(?:ab)++a", "ababa"))],
      ["aaa", None, "aab", None, "ababa"])
check("possessive group", [re.match("(?:a|ab)++c", "abc"), g0(re.match("(?:ab|a)++c", "abc")), re.match("(?:a|b)*+b", "ab")], [None, "abc", None])
check("atomic", [re.match("(?>a+)a", "aaa"), g0(re.match("(?>a+)b", "aab")), re.match("(?>ab|a)b", "ab"), g0(re.match("(?>a|ab)b", "ab"))],
      [None, "aab", None, "ab"])
check("atomic keeps captures", re.match("(?>(a)+)b", "aab").groups(), ("a",))
check("counted groups", [g0(re.match("(?:ab){2,3}", "abababab")), g0(re.match("(?:ab){2,3}?", "abababab")), re.match("(ab){3}", "abab"), g0(re.match("(?:a|bc){3}", "abca"))],
      ["ababab", "abab", None, "abca"])
check("large counts", [len(g0(re.match("(?:ab){1000}", "ab" * 1200))), len(g0(re.match("a{3000,}", "a" * 3500))), len(g0(re.match("(?:a|b){2500,2600}?", "ab" * 2000)))],
      [2000, 3500, 2500])
check("large counted group", [len(g0(re.match("(?:x(y)){1500,}", "xy" * 1600))), re.match("(?:x(y)){1500,}", "xy" * 1600).span(1)], [3200, (3199, 3200)])
check("repeat of empty", [g0(re.match("(?:)*", "a")), g0(re.match("(?:a*)*", "aaa")), re.match("(a*)*", "aa").group(1), re.match("(a|)*", "b").group(1), re.match("(a*)+", "b").group(1)],
      ["", "aaa", "", "", ""])
check("empty iteration rule", [re.match(r"(?:(?=a)()|a)+b", "ab").groups(), re.match(r"(?:(?=a)()|a)*b", "ab").groups(), re.match(r"(?:()|a)*$", "a").span(1)],
      [("",), (None,), (1, 1)])
check("nested quantifiers", [g0(re.match("(?:a+)+b", "aaab")), g0(re.match("(a|b)*?c", "abac")), g0(re.match("(?:(?:ab)*c)+", "abcabcc"))], ["aaab", "abac", "abcabcc"])

# ── alternation and conditionals ─────────────────────────────────────────────
check("alternation order", [g0(re.match("a|ab", "ab")), g0(re.match("ab|a", "ab")), g0(re.fullmatch("a|ab", "ab")), re.findall("cat|dog|bird", "dog cat bird")],
      ["a", "ab", "ab", ["dog", "cat", "bird"]])
check("empty alternatives", [g0(re.match("a|", "b")), g0(re.match("|a", "a")), re.findall("x|", "ax")], ["", "", ["", "x", ""]])
check("conditional", [g0(re.match(r"(<)?\w+(?(1)>)", "<a>")), g0(re.match(r"(<)?\w+(?(1)>)", "a>")), g0(re.match(r"(<)?\w+(?(1)>|!)", "a!")), re.match(r"(<)?\w+(?(1)>|!)", "<a!")],
      ["<a>", "a", "a!", None])
check("named conditional", [g0(re.match(r"(?P<q>')?\w+(?(q)')", "'x'")), g0(re.match(r"(?P<q>')?\w+(?(q)')", "x'"))], ["'x'", "x"])

# ── search / match / fullmatch, pos and endpos ───────────────────────────────
p = re.compile(r"\d+")
check("pos/endpos", [g0(p.search("a12b345", 3)), g0(p.search("a12b345", 0, 2)), g0(p.match("a12", 1)), p.match("a12"), g0(p.fullmatch("a123b", 1, 4)), p.fullmatch("a123b", 1)],
      ["345", "1", "12", None, "123", None])
m = p.search("xx123", -5, 100)
check("pos clipped", [m.pos, m.endpos, m.span()], [0, 5, (2, 5)])
check("pos beyond", [p.search("123", 2, 1), p.match("123", 5), g0(re.compile("").search("abc", 5)), re.compile("").search("abc", 5).span()], [None, None, "", (3, 3)])
check("^ and pos", [re.compile("^a").search("ba", 1), g0(re.compile("^a", re.M).search("b\na", 1)), g0(re.compile("a$").search("ab", 0, 1))], [None, "a", "a"])
check("endpos hides the rest", [re.compile("ab").search("abc", 0, 1), g0(re.compile(r"\w\b").search("abc", 0, 2)), re.compile("(?=c)").search("abc", 0, 2)], [None, "b", None])
check("fullmatch backtracks", [g0(re.fullmatch("a|ab", "ab")), g0(re.fullmatch(r"\w+?", "abc")), re.fullmatch("a*", "aab"), g0(re.fullmatch("(?:a|ab)(?:c|bcd)", "abcd"))],
      ["ab", "abc", None, "abcd"])
check("Match.string/re", [m.string, m.re.pattern, m.re is p or m.re == p], ["xx123", r"\d+", True])

# ── findall / finditer ───────────────────────────────────────────────────────
check("findall groups", [re.findall(r"(\w)(\d)?", "a1b"), re.findall(r"(\w)=(\w)", "a=1 b=2"), re.findall(r"a(b)?", "ab a")], [[("a", "1"), ("b", "")], [("a", "1"), ("b", "2")], ["b", ""]])
check("finditer", [[m.group() for m in re.finditer(r"\d+", "a1b22c333")], spans("a*", "baac")], [["1", "22", "333"], [(0, 0), (1, 3), (3, 3), (4, 4)]])
check("finditer pos", [[m.span() for m in re.compile("a").finditer("aaaa", 1, 3)], [m.pos for m in re.compile("a").finditer("aa", 1)]], [[(1, 2), (2, 3)], [1]])
check("finditer many", len(list(re.finditer("a", "a" * 3000))), 3000)
check("findall pos", [re.compile("a").findall("aaaa", 1, 3), re.compile("").findall("ab", 1)], [["a", "a"], ["", ""]])

# ── empty matches (Python 3.7+) ──────────────────────────────────────────────
check("sub empty matches", [re.sub("x*", "-", "abxd"), re.sub("", "-", "ab"), re.sub("a*", "-", "baac"), re.sub(r"\b", "|", "ab cd")],
      ["-a-b--d-", "-a-b-", "-b--c-", "|ab| |cd|"])
check("split empty matches", [re.split("x*", "axbc"), re.split(r"\b", "a b"), re.split("", "ab"), re.split(r"\W*", "a, b")],
      [["", "a", "", "b", "c", ""], ["", "a", " ", "b", ""], ["", "a", "b", ""], ["", "a", "", "b", ""]])
check("findall empty matches", [re.findall("a??", "a"), re.findall("x*", "ab"), re.findall(r"\b|:", "a:b")], [["", "a", ""], ["", "", ""], ["", "", ":", "", ""]])
check("subn empty", re.subn("x*", "-", "abc"), ("-a-b-c-", 4))

# ── split ────────────────────────────────────────────────────────────────────
check("split", [re.split(r",\s*", "a, b,c"), re.split(r"(,)", "a,b"), re.split(r"(x)|(y)", "axbyc"), re.split(",", "a,b,c,d", 2), re.split(",", "a,b", maxsplit=1)],
      [["a", "b", "c"], ["a", ",", "b"], ["a", "x", None, "b", None, "y", "c"], ["a", "b", "c,d"], ["a", "b"]])
check("split edge", [re.split(",", ""), re.split(",", ","), re.split("a", "bab", -1), re.split("(?:)", "")], [[""], ["", ""], ["bab"], ["", ""]])

# ── sub / subn ───────────────────────────────────────────────────────────────
check("sub templates", [re.sub(r"(\w+)@(\w+)", r"\2 at \1", "joe@site"), re.sub(r"(?P<a>\d)", r"<\g<a>\g<1>\g<0>>", "x5"), re.sub("a", r"\n\t\\", "a"), re.sub("a", r"\-\.", "a")],
      ["site at joe", "x<555>", "\n\t\\", "\\-\\."])
check("sub template digits", [re.sub("(a)", r"\g<1>0", "a"), re.sub("(a)", r"\1\0", "a"), re.sub("x", r"\101\0", "x"), re.sub("x", r"\g<0>0", "x")], ["a0", "a\x00", "A\x00", "x0"])
check("sub unmatched group", re.sub(r"(a)|b", r"[\1]", "ab"), "[a][]")
check("sub count", [re.sub("a", "b", "aaa", 2), re.sub("a", "b", "aaa", count=1), re.subn("a", "b", "aaa"), re.sub("a", "b", "aaa", -1)],
      ["bba", "baa", ("bbb", 3), "aaa"])
check("sub function", [re.sub(r"\d+", lambda m: str(int(m.group()) * 2), "a1b22"), re.subn(r"\w", lambda m: m.group().upper(), "ab", 1), re.sub("a", lambda m: "", "banana")],
      ["a2b44", ("Ab", 1), "bnn"])
check("sub function match", re.sub(r"(?P<w>\w)(\d)", lambda m: m.group("w") + str(m.span()) + str(m.lastindex), "a1-b2"), "a(0, 2)2-b(3, 5)2")
check("sub flags", [re.sub("A", "x", "aA", flags=re.I), re.sub("^a", "x", "a\na", flags=re.M), re.subn("a", "b", "AaA", 0, re.I)], ["xx", "x\nx", ("bbb", 3)])
check("sub literal fast path", re.sub("o", "0", "foo boo"), "f00 b00")
check("expand", [re.match(r"(\w+) (?P<b>\w+)", "hi you").expand(r"\2-\1-\g<b>"), re.match("(a)|(b)", "a").expand(r"[\2]")], ["you-hi-you", "[]"])

# ── escape / purge / compile cache ───────────────────────────────────────────
check("escape", [re.escape("a.b*c\n é-"), re.escape("_x1"), re.escape("()[]{}?*+-|^$\\.&~# \t\n\r\v\f")],
      ["a\\.b\\*c\\\n\\ é\\-", "_x1", "\\(\\)\\[\\]\\{\\}\\?\\*\\+\\-\\|\\^\\$\\\\\\.\\&\\~\\#\\ \\\t\\\n\\\r\\\x0b\\\x0c"])
check("escape round trip", g0(re.match(re.escape("1+1=2? [yes]"), "1+1=2? [yes]")), "1+1=2? [yes]")
p1 = re.compile("ab+")
re.purge()
check("purge", [g0(re.match("ab+", "abb")), g0(p1.match("abbb")), re.compile(p1) is p1 or re.compile(p1) == p1], ["abb", "abbb", True])

# ── Pattern and Match objects ────────────────────────────────────────────────
check("Pattern attributes", [re.compile(r"(a)(?P<n>b)").groups, dict(re.compile(r"(a)(?P<n>b)").groupindex), re.compile("x").pattern, re.compile("x").groups], [2, {"n": 2}, "x", 0])
check("Pattern repr", [repr(re.compile("a+")), repr(re.compile("a+", re.I | re.M)), repr(re.compile("(?i)a")), repr(re.compile("a", re.A)), repr(re.compile("a", re.S | re.X))],
      ["re.compile('a+')", "re.compile('a+', re.IGNORECASE|re.MULTILINE)", "re.compile('(?i)a', re.IGNORECASE)", "re.compile('a', re.ASCII)", "re.compile('a', re.DOTALL|re.VERBOSE)"])
check("Pattern repr quotes", [repr(re.compile("it's")), repr(re.compile('a"b'))], ["re.compile(\"it's\")", "re.compile('a\"b')"])
check("Pattern equality", [re.compile("a") == re.compile("a"), re.compile("a") == re.compile("a", re.I), re.compile("a") == re.compile(b"a"), hash(re.compile("ab")) == hash(re.compile("ab"))],
      [True, False, False, True])
check("Match repr", [repr(re.match("ab", "abc")), repr(re.search("", "x")), repr(re.search(r"\d", "a'1")), repr(re.match("a'", "a'"))],
      ["<re.Match object; span=(0, 2), match='ab'>", "<re.Match object; span=(0, 0), match=''>", "<re.Match object; span=(2, 3), match='1'>", "<re.Match object; span=(0, 2), match=\"a'\">"])
check("Match repr truncated", repr(re.match(".*", "x" * 80)), "<re.Match object; span=(0, 80), match='" + "x" * 49 + ">")
check("Match truthiness", [bool(re.match("", "")), bool(re.match("a", "b")), "yes" if re.match("a", "a") else "no"], [True, False, "yes"])
check("compile with flags twice", err(lambda: re.compile(re.compile("a"), re.I)), "ValueError: cannot process flags argument with a compiled pattern")

# ── errors ───────────────────────────────────────────────────────────────────
check("syntax errors 1", [err(lambda: re.compile("(a")), err(lambda: re.compile("*a")), err(lambda: re.compile("a**")), err(lambda: re.compile("(?<x)")), err(lambda: re.compile("a)"))],
      ["error: missing ), unterminated subpattern at position 0", "error: nothing to repeat at position 0", "error: multiple repeat at position 2",
       "error: unknown extension ?<x at position 1", "error: unbalanced parenthesis at position 1"])
check("syntax errors 2", [err(lambda: re.compile("[a")), err(lambda: re.compile("[z-a]")), err(lambda: re.compile(r"\q")), err(lambda: re.compile("a{3,2}")), err(lambda: re.compile(r"(a)\2"))],
      ["error: unterminated character set at position 0", "error: bad character range z-a at position 1", "error: bad escape \\q at position 0",
       "error: min repeat greater than max repeat at position 2", "error: invalid group reference 2 at position 4"])
check("syntax errors 3", [err(lambda: re.compile("(?P<1a>x)")), err(lambda: re.compile("(?P<a>x)(?P<a>y)")), err(lambda: re.compile("(?P=b)")), err(lambda: re.compile(r"(?<=a+)b")), err(lambda: re.compile(r"\x4"))],
      ["error: bad character in group name '1a' at position 4", "error: redefinition of group name 'a' as group 2; was group 1 at position 12",
       "error: unknown group name 'b' at position 4", "error: look-behind requires fixed-width pattern", "error: incomplete escape \\x4 at position 0"])
check("syntax errors 4", [err(lambda: re.compile("a(?i)b")), err(lambda: re.compile("(?z)")), err(lambda: re.compile("(?i")), err(lambda: re.compile("(a)(?(2)b)")), err(lambda: re.compile("^*"))],
      ["error: global flags not at the start of the expression at position 1", "error: unknown extension ?z at position 1", "error: missing -, : or ) at position 3",
       "error: invalid group reference 2 at position 6", "error: nothing to repeat at position 1"])
check("syntax errors 5", [err(lambda: re.compile("(?#abc")), err(lambda: re.compile("a\\")), err(lambda: re.compile(r"\400")), err(lambda: re.compile(r"[\d-z]")), err(lambda: re.compile("(?(1)a|b|c)"))],
      ["error: missing ), unterminated comment at position 0", "error: bad escape (end of pattern) at position 1", "error: octal escape value \\400 outside of range 0-0o377 at position 0",
       "error: bad character range \\d-z at position 1", "error: conditional backref with more than two branches at position 8"])
check("syntax errors 6", [err(lambda: re.compile("(a)(?P=a)")), err(lambda: re.compile("(?P<a>a(?P=a))")), err(lambda: re.compile("a{2}{3}")), err(lambda: re.compile("(?-i)a")), err(lambda: re.compile("(?P"))],
      ["error: unknown group name 'a' at position 7", "error: cannot refer to an open group at position 11", "error: multiple repeat at position 4",
       "error: missing : at position 4", "error: unexpected end of pattern at position 3"])
check("inline flag errors", [err(lambda: re.compile("(?au)a")), err(lambda: re.compile("(?L)a")), err(lambda: re.compile(b"(?u)a")), err(lambda: re.compile("(?i-i:a)")),
                             err(lambda: re.compile("(?-a:a)")), err(lambda: re.compile("(?i-q:a)")), err(lambda: re.compile("(?i-:a)")), err(lambda: re.compile("a(?i:b)(?m)"))],
      ["error: bad inline flags: flags 'a', 'u' and 'L' are incompatible at position 4", "error: bad inline flags: cannot use 'L' flag with a str pattern at position 3",
       "error: bad inline flags: cannot use 'u' flag with a bytes pattern at position 3", "error: bad inline flags: flag turned on and off at position 5",
       "error: bad inline flags: cannot turn off flags 'a', 'u' and 'L' at position 4", "error: unknown flag at position 4", "error: missing flag at position 4",
       "error: global flags not at the start of the expression at position 7"])
check("inline flags", [re.compile(b"(?L)a").flags, re.compile("(?u)a").flags, re.compile("(?x)(?i)a").flags, re.compile("(?i)(?a)\\w").flags], [4, 32, 98, 258])
check("group name errors", [err(lambda: re.compile("(?P<a-b>x)")), err(lambda: re.compile("(?P<>x)")), err(lambda: re.compile("(?P<a")), err(lambda: re.compile("(?P=a")),
                            err(lambda: re.compile("(?(a)b)")), err(lambda: re.compile("(?(0)b)")), err(lambda: re.compile("(?(1a)b)"))],
      ["error: bad character in group name 'a-b' at position 4", "error: missing group name at position 4", "error: missing >, unterminated name at position 4",
       "error: missing ), unterminated name at position 4", "error: unknown group name 'a' at position 3", "error: bad group number at position 3",
       "error: bad character in group name '1a' at position 3"])
check("unterminated", [err(lambda: re.compile("(?")), err(lambda: re.compile("(?<")), err(lambda: re.compile("(?Px")), err(lambda: re.compile("(?<=a")), err(lambda: re.compile("[^]"))],
      ["error: unexpected end of pattern at position 2", "error: unexpected end of pattern at position 3", "error: unknown extension ?Px at position 1",
       "error: missing ), unterminated subpattern at position 0", "error: unterminated character set at position 0"])
check("escape errors", [err(lambda: re.compile(r"\8")), err(lambda: re.compile(r"[\8]")), err(lambda: re.compile(r"\U0011ffff")), err(lambda: re.compile(r"[\A]")), err(lambda: re.compile(r"\x4g")), err(lambda: re.compile(b"\\u1234"))],
      ["error: invalid group reference 8 at position 1", "error: bad escape \\8 at position 1", "error: bad escape \\U0011ffff at position 0", "error: bad escape \\A at position 1",
       "error: incomplete escape \\x4 at position 0", "error: bad escape \\u at position 0"])
check("lookbehind and groups", [err(lambda: re.compile(r"(?<=a\1)(a)")), g0(re.search(r"(a)(?<=\1)b", "ab")), g0(re.search(r"(?<=(?P<x>a))(?P=x)", "aa")), err(lambda: re.compile(r"(?<=x|yy)"))],
      ["error: invalid group reference 1 at position 6", "ab", "a", "error: look-behind requires fixed-width pattern"])
check("repeat forms", [err(lambda: re.compile(r"\b*")), g0(re.match("(?=a)*a", "a")), g0(re.match("()*a", "a")), g0(re.match("(|a)+?b", "aab")), g0(re.match("a{,}", "aa")), g0(re.match("a{ 1}", "a{ 1}"))],
      ["error: nothing to repeat at position 2", "a", "a", "aab", "aa", "a{ 1}"])
check("unicode words", [re.findall(r"\w+", "\u0928\u092e\u0938\u094d\u0924\u0947"), re.findall(r"(?i)stra\u00dfe", "STRASSE stra\u00dfe STRA\u1e9eE")],
      [["\u0928\u092e\u0938", "\u0924"], ["stra\u00dfe", "STRA\u1e9eE"]])
check("misc API", [re.findall(r"((a)|b)+", "ab"), re.sub(r"(a)|b", lambda m: str(m.lastindex or 0), "ab"), re.subn(r"(?=a)", "-", "aaa"), re.split(r"(?<=a)", "aab"),
                   re.compile(r"(?P<a>x)|(?P<b>y)").match("y").lastgroup, re.match("(a)(b)?", "a").expand(r"\1-\2-")],
      [[("b", "a")], "10", ("-a-a-a", 3), ["a", "a", "b"], "b", "a--"])

try:
    re.compile("ab\n(cd")
    e = None
except re.error as ex:
    e = ex
check("error attributes", [e.msg, e.pos, e.pattern, e.lineno, e.colno, str(e)],
      ["missing ), unterminated subpattern", 3, "ab\n(cd", 2, 1, "missing ), unterminated subpattern at position 3 (line 2, column 1)"])
check("error class", [issubclass(re.error, Exception), not hasattr(re, "PatternError") or re.PatternError is re.error], [True, True])
check("value errors", [err(lambda: re.compile("a", re.A | re.U)), err(lambda: re.compile(b"a", re.U)), err(lambda: re.compile("a", re.L)), err(lambda: re.compile("a{4294967296}"))],
      ["ValueError: ASCII and UNICODE flags are incompatible", "ValueError: cannot use UNICODE flag with a bytes pattern", "ValueError: cannot use LOCALE flag with a str pattern",
       "OverflowError: the repetition number is too large"])
check("type errors", [err(lambda: re.search("a", b"a")), err(lambda: re.search(b"a", "a")), err(lambda: re.search(5, "a")), err(lambda: re.search("a", 5))],
      ["TypeError: cannot use a string pattern on a bytes-like object", "TypeError: cannot use a bytes pattern on a string-like object",
       "TypeError: first argument must be string or compiled pattern", "TypeError: expected string or bytes-like object, got 'int'"])
check("group errors", [err(lambda: re.match("(a)", "a").group(2)), err(lambda: re.match("(a)", "a").group("x")), err(lambda: re.match("(a)", "a").start(5)), err(lambda: re.match("a", "a")[1])],
      ["IndexError: no such group", "IndexError: no such group", "IndexError: no such group", "IndexError: no such group"])
check("template errors", [err(lambda: re.sub("(a)", r"\2", "a")), err(lambda: re.sub("(a)", r"\g<x>", "a")), err(lambda: re.sub("a", "\\", "a")), err(lambda: re.sub("a", r"\q", "a")), err(lambda: re.sub("a", r"\g<1", "a"))],
      ["error: invalid group reference 2 at position 1", "IndexError: unknown group name 'x'", "error: bad escape (end of pattern) at position 0",
       "error: bad escape \\q at position 0", "error: missing >, unterminated name at position 3"])

# ── scale ────────────────────────────────────────────────────────────────────
# Exponential for a plain backtracker (CPython's sre included, so python3
# only records the expected values); the memoized engine answers at once.
if IS_PY:
    redos = [None, None, None, None, 5000]
else:
    redos = [re.match("(a|aa)*c", "a" * 5000), re.match("(x+x+)+y", "x" * 5000), re.match(r"(\w+\s?)*$", "word " * 2000 + "!"),
             re.match("(a*)*b", "a" * 5000), len(g0(re.match("(?:a|a)*", "a" * 5000)))]
check("catastrophic patterns", redos, [None, None, None, None, 5000])
big = "ab" * 500000
check("1M subject", [re.search("c", big), g0(re.search("(ab)+$", big)) == big, re.search("ba$", big), re.match(r"(?:ab)*\Z", big).end(), re.fullmatch("[ab]*", big).span()],
      [None, True, None, 1000000, (0, 1000000)])
big2 = "x" * 999990 + "key=value"
check("1M subject 2", [re.search(r"(\w+)=(\w+)", big2).span(2), re.findall("=.", big2), re.subn("x", "", big2), re.split("=", big2)[1], len(re.sub("y", "Y", big2)), re.search(r"\bkey", big2)],
      [(999994, 999999), ["=v"], ("key=value", 999990), "value", 999999, None])
check("1M many matches", [re.subn("b", "", big)[1], len(re.findall("b", "ab" * 5000)), len(re.split("b", "ab" * 5000))], [500000, 5000, 5001])
check("1M unicode subject", [re.search("\u00e9", "a" * 999999 + "\u00e9").span(), re.subn("\u00e9", "e", "\u00e9a" * 300000)[1], re.search("(a\u00e9)+$", "\u00e9a" * 300000 + "\u00e9").span()],
      [(999999, 1000000), 300000, (1, 600001)])

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT78 PASSED ===")
