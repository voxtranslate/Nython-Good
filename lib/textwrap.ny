# nython: module    (import it by name: it runs in a module scope of its own)
# lib/textwrap.ny - Python's textwrap (3.12).
#
#     import textwrap
#     textwrap.wrap(text, width=40)            # a list of lines
#     textwrap.fill(text, 60, initial_indent="* ", subsequent_indent="  ")
#     textwrap.shorten("Hello  world!", width=11)        # 'Hello [...]'
#     textwrap.dedent(src); textwrap.indent(src, "> ")
#
# TextWrapper with every option Python's has: width, initial_indent,
# subsequent_indent, expand_tabs, tabsize, replace_whitespace,
# drop_whitespace, break_long_words, break_on_hyphens,
# fix_sentence_endings, max_lines and placeholder. The output is the same
# as CPython's, line for line: the text is split into the same chunks -
# whitespace runs, words, the parts of hyphenated words (goof-ball breaks
# after "goof-" only between letters), em-dashes (--) between words - and
# wrapped with the same algorithm. Python finds the chunks with a regular
# expression (TextWrapper.wordsep_re); here a scanner applies the same
# rules (lookbehinds and all) in one pass, so the module needs no regular
# expression engine. As in Python, \w is a letter, digit or underscore and
# a "letter" for hyphenation is \w that is not a digit.

__all__ = ["TextWrapper", "wrap", "fill", "dedent", "indent", "shorten"]

_whitespace = "\t\n\x0b\x0c\r "


def _is_ws(c):
    return c == " " or c == "\t" or c == "\n" or c == "\x0b" or c == "\x0c" or c == "\r"


def _is_word(c):
    # \w
    return c == "_" or c.isalnum()


def _is_letter(c):
    # [^\d\W]: a word character that is not a decimal digit
    return c == "_" or (c.isalnum() and not c.isdecimal())


def _is_wp(c):
    # [\w!"'&.,?]
    return _is_word(c) or c in "!\"'&.,?"


def _dashes_then_word(s, p):
    # (?=-{2,}\w) at p
    var n = len(s)
    var q = p
    while q < n and s[q] == "-":
        q = q + 1
    return q - p >= 2 and q < n and _is_word(s[q])


def _letter_at(s, k):
    return k >= 0 and k < len(s) and _is_letter(s[k])


def _runs(s):
    # the runs of whitespace and of other characters in s, as (is_ws,
    # start, end): str.split over a copy whose whitespace is all spaces
    # finds them without a loop over every character
    var t = s
    for c in "\t\n\x0b\x0c\r":
        if c in t:
            t = t.replace(c, " ")
    var parts = t.split(" ")
    var runs = []
    var pos = 0
    var ws_start = -1
    var last = len(parts) - 1
    for k in range(len(parts)):
        var part = parts[k]
        if part != "":
            if ws_start >= 0:
                runs.append((true, ws_start, pos))
                ws_start = -1
            runs.append((false, pos, pos + len(part)))
            pos = pos + len(part)
        if k < last:
            if ws_start < 0:
                ws_start = pos
            pos = pos + 1
    if ws_start >= 0:
        runs.append((true, ws_start, pos))
    return runs


def _split_word(s, i, n, chunks):
    # the chunks of the word s[i:n] (no whitespace in it) by
    # TextWrapper.wordsep_re; s is the whole text, for the lookbehinds
    while i < n:
        # an em-dash between words: (?<=wp) -{2,} (?=\w)
        if s[i] == "-" and i > 0 and _is_wp(s[i - 1]) and _dashes_then_word(s, i):
            var q = i
            while q < n and s[q] == "-":
                q = q + 1
            chunks.append(s[i:q])
            i = q
            continue
        # a word, possibly hyphenated: the shortest run after which one of
        # the three endings matches
        var p = i + 1
        var end = n
        while p < n:
            if s[p] == "-":
                # a hyphenated word: -(?:(?<=lt{2}-)|(?<=lt-lt-))(?=lt-?lt)
                var behind = (_letter_at(s, p - 2) and _letter_at(s, p - 1)) or (_letter_at(s, p - 3) and p - 2 >= 0 and s[p - 2] == "-" and _letter_at(s, p - 1))
                if behind and _letter_at(s, p + 1) and (_letter_at(s, p + 2) or (p + 2 < n and s[p + 2] == "-" and _letter_at(s, p + 3))):
                    end = p + 1
                    break
                # before an em-dash: (?<=wp)(?=-{2,}\w)
                if _is_wp(s[p - 1]) and _dashes_then_word(s, p):
                    end = p
                    break
            p = p + 1
        # (the end of the word, (?=ws|\Z), is n)
        chunks.append(s[i:end])
        i = end


def _split_hyphenated(s):
    # TextWrapper.wordsep_re.split(s), without the empty strings: only a
    # word with a hyphen in it can split into more than one chunk
    var chunks = []
    for r in _runs(s):
        if r[0]:
            chunks.append(s[r[1]:r[2]])
        else:
            var w = s[r[1]:r[2]]
            if "-" in w:
                _split_word(s, r[1], r[2], chunks)
            else:
                chunks.append(w)
    return chunks


def _split_simple(s):
    # TextWrapper.wordsep_simple_re.split(s): whitespace runs and the rest
    var chunks = []
    for r in _runs(s):
        chunks.append(s[r[1]:r[2]])
    return chunks


def _sentence_end(chunk):
    # [a-z][.!?]["']?\Z
    var n = len(chunk)
    var k = n - 1
    if k >= 0 and (chunk[k] == "\"" or chunk[k] == "'"):
        k = k - 1
    return k >= 1 and chunk[k] in ".!?" and "a" <= chunk[k - 1] and chunk[k - 1] <= "z"


class TextWrapper:
    def __init__(self, width=70, initial_indent="", subsequent_indent="", expand_tabs=True,
                 replace_whitespace=True, fix_sentence_endings=False, break_long_words=True,
                 drop_whitespace=True, break_on_hyphens=True, tabsize=8, *, max_lines=None,
                 placeholder=" [...]"):
        self.width = width
        self.initial_indent = initial_indent
        self.subsequent_indent = subsequent_indent
        self.expand_tabs = expand_tabs
        self.replace_whitespace = replace_whitespace
        self.fix_sentence_endings = fix_sentence_endings
        self.break_long_words = break_long_words
        self.drop_whitespace = drop_whitespace
        self.break_on_hyphens = break_on_hyphens
        self.tabsize = tabsize
        self.max_lines = max_lines
        self.placeholder = placeholder

    def _munge_whitespace(self, text):
        if self.expand_tabs:
            text = text.expandtabs(self.tabsize)
        if self.replace_whitespace:
            for c in "\t\n\x0b\x0c\r":
                if c in text:
                    text = text.replace(c, " ")
        return text

    def _split(self, text):
        # Python tests `is True`: break_on_hyphens=1 splits only on spaces
        if isinstance(self.break_on_hyphens, bool) and self.break_on_hyphens:
            return _split_hyphenated(text)
        return _split_simple(text)

    def _fix_sentence_endings(self, chunks):
        var i = 0
        while i < len(chunks) - 1:
            if chunks[i + 1] == " " and _sentence_end(chunks[i]):
                chunks[i + 1] = "  "
                i = i + 2
            else:
                i = i + 1

    def _handle_long_word(self, reversed_chunks, cur_line, cur_len, width):
        var space_left = 1 if width < 1 else width - cur_len
        if self.break_long_words:
            var end = space_left
            var chunk = reversed_chunks[-1]
            if self.break_on_hyphens and len(chunk) > space_left:
                # break after the last hyphen, if there are non-hyphens
                # before it
                var hyphen = chunk.rfind("-", 0, space_left)
                if hyphen > 0 and len(chunk[:hyphen].replace("-", "")) > 0:
                    end = hyphen + 1
            cur_line.append(chunk[:end])
            reversed_chunks[-1] = chunk[end:]
        elif not cur_line:
            cur_line.append(reversed_chunks.pop())

    def _wrap_chunks(self, chunks):
        var lines = []
        if self.width <= 0:
            raise ValueError("invalid width %r (must be > 0)" % self.width)
        var indent = ""
        if self.max_lines is not None:
            if self.max_lines > 1:
                indent = self.subsequent_indent
            else:
                indent = self.initial_indent
            if len(indent) + len(self.placeholder.lstrip()) > self.width:
                raise ValueError("placeholder too large for max width")
        chunks.reverse()
        while chunks:
            var cur_line = []
            var cur_len = 0
            if lines:
                indent = self.subsequent_indent
            else:
                indent = self.initial_indent
            var width = self.width - len(indent)
            if self.drop_whitespace and chunks[-1].strip() == "" and lines:
                chunks.pop()
            while chunks:
                var l = len(chunks[-1])
                if cur_len + l <= width:
                    cur_line.append(chunks.pop())
                    cur_len = cur_len + l
                else:
                    break
            if chunks and len(chunks[-1]) > width:
                self._handle_long_word(chunks, cur_line, cur_len, width)
                cur_len = 0
                for piece in cur_line:
                    cur_len = cur_len + len(piece)
            if self.drop_whitespace and cur_line and cur_line[-1].strip() == "":
                cur_len = cur_len - len(cur_line[-1])
                cur_line.pop()
            if cur_line:
                var rest_blank = (not chunks) or (self.drop_whitespace and len(chunks) == 1 and not chunks[0].strip())
                if self.max_lines is None or len(lines) + 1 < self.max_lines or (rest_blank and cur_len <= width):
                    lines.append(indent + "".join(cur_line))
                else:
                    var placed = false
                    while cur_line:
                        if cur_line[-1].strip() and cur_len + len(self.placeholder) <= width:
                            cur_line.append(self.placeholder)
                            lines.append(indent + "".join(cur_line))
                            placed = true
                            break
                        cur_len = cur_len - len(cur_line[-1])
                        cur_line.pop()
                    if not placed:
                        var done = false
                        if lines:
                            var prev_line = lines[-1].rstrip()
                            if len(prev_line) + len(self.placeholder) <= self.width:
                                lines[-1] = prev_line + self.placeholder
                                done = true
                        if not done:
                            lines.append(indent + self.placeholder.lstrip())
                    break
        return lines

    def _split_chunks(self, text):
        return self._split(self._munge_whitespace(text))

    def wrap(self, text):
        var chunks = self._split_chunks(text)
        if self.fix_sentence_endings:
            self._fix_sentence_endings(chunks)
        return self._wrap_chunks(chunks)

    def fill(self, text):
        return "\n".join(self.wrap(text))


def wrap(text, width=70, **kwargs):
    return TextWrapper(width=width, **kwargs).wrap(text)


def fill(text, width=70, **kwargs):
    return TextWrapper(width=width, **kwargs).fill(text)


def shorten(text, width, **kwargs):
    var w = TextWrapper(width=width, max_lines=1, **kwargs)
    return w.fill(" ".join(text.strip().split()))


def dedent(text):
    # remove the common leading whitespace (spaces and tabs, compared as
    # they are) of the lines; lines of only spaces and tabs become empty
    var lines = text.split("\n")
    var margin = None
    for k in range(len(lines)):
        var line = lines[k]
        var j = 0
        while j < len(line) and (line[j] == " " or line[j] == "\t"):
            j = j + 1
        if j == len(line):
            if j > 0:
                lines[k] = ""
            continue
        var ind = line[:j]
        if margin is None:
            margin = ind
        elif ind.startswith(margin):
            pass
        elif margin.startswith(ind):
            margin = ind
        else:
            for i in range(min(len(margin), len(ind))):
                if margin[i] != ind[i]:
                    margin = margin[:i]
                    break
    if margin:
        var ml = len(margin)
        for k in range(len(lines)):
            if lines[k].startswith(margin):
                lines[k] = lines[k][ml:]
    return "\n".join(lines)


def indent(text, prefix, predicate=None):
    # prefix every line for which predicate(line) is true (by default the
    # lines that are not just whitespace)
    var out = []
    for line in text.splitlines(True):
        var add = line.strip() if predicate is None else predicate(line)
        if add:
            out.append(prefix + line)
        else:
            out.append(line)
    return "".join(out)
