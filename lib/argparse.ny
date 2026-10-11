# nython: module    (import it by name: it runs in a module scope of its own)
# lib/argparse.ny - Python's argparse (round 77).
#
#     import argparse
#     ap = argparse.ArgumentParser(prog="tool", description="Does things.")
#     ap.add_argument("files", nargs="+")
#     ap.add_argument("-n", "--count", type=int, default=1, choices=[1, 2, 3])
#     ap.add_argument("-v", "--verbose", action="count", default=0)
#     args = ap.parse_args()            # sys.argv[1:]
#
# The parsing is Python's algorithm, so the same command lines give the same
# results: every argument is classified as an option ("O"), a value ("A") or
# the "--" separator ("-"); positionals take the values between options in
# chunks, matched against their nargs (None, "?", "*", "+", N, REMAINDER,
# PARSER) the way argparse's regular expressions match - greedy, leaving
# enough for the positionals after; an option takes what its nargs allows
# up to the next option. -abc runs of flags, -n3 / --name=x attached values
# and unique prefixes of long options work as in Python. Actions are
# classes (store, store_const, store_true/false, append, append_const,
# extend, count, help, version, BooleanOptionalAction, subparsers) and a
# user-defined Action subclass's __call__ is called the same way.
#
# HelpFormatter lays the usage and help out like Python's (the width of
# the terminal, help aligned at min(longest invocation + 4, 24), words
# wrapped, long usage lines split into options then positionals);
# RawDescriptionHelpFormatter, RawTextHelpFormatter,
# ArgumentDefaultsHelpFormatter and MetavarTypeHelpFormatter change it the
# same way.
#
# Beyond Python: an unknown option or a mistyped choice is answered with the
# nearest known one ("did you mean --verbose?"), found with the runtime's
# fuzzy matcher (suggest_on_error=False turns it off).
import sys

SUPPRESS = "==SUPPRESS=="
OPTIONAL = "?"
ZERO_OR_MORE = "*"
ONE_OR_MORE = "+"
REMAINDER = "..."
PARSER = "A..."
_UNRECOGNIZED_ARGS_ATTR = "_unrecognized_args"


def _action_name(a):
    # how errors name an argument: -n/--count, a metavar, the dest
    if a == none:
        return none
    if len(a.option_strings) > 0:
        return "/".join(a.option_strings)
    if a.metavar != none and a.metavar != SUPPRESS:
        if isinstance(a.metavar, "str"):
            return a.metavar
        return " ".join([str(m) for m in a.metavar])
    if a.dest != none and a.dest != SUPPRESS:
        return a.dest
    if a.choices != none:
        return "{" + ",".join([str(c) for c in a.choices]) + "}"
    return none


def _is_identifier(s):
    return isinstance(s, "str") and s.isidentifier()


def _is_negative_number(s):
    # Python's ^-\d+$|^-\d*\.\d+$
    if len(s) < 2 or s[0] != "-":
        return false
    var body = s[1:]
    var dot = body.find(".")
    if dot < 0:
        return body.isdigit()
    var whole = body[0:dot]
    var frac = body[dot + 1:]
    return (whole == "" or whole.isdigit()) and frac != "" and frac.isdigit()


def _close_match(word, options):
    # the option nearest to a mistyped word: fuzzy subsequence score, and
    # at least half the length in common
    var best = none
    var best_score = 0
    for o in options:
        var sc = fuzzy_score(word, o)
        if sc > best_score and len(word) * 2 >= len(o) and len(o) * 2 >= len(word):
            best_score = sc
            best = o
    return best


class ArgumentError(Exception):
    def __init__(self, argument, message):
        self.argument_name = _action_name(argument)
        self.message = message
        Exception.__init__(self, self.__str__())

    def __str__(self):
        if self.argument_name == none:
            return self.message
        return "argument " + self.argument_name + ": " + self.message


class ArgumentTypeError(Exception):
    pass


class Namespace:
    # attributes in the order they were set; repr, ==, `in` as Python's
    def __init__(self, **kwargs):
        for k in kwargs:
            setattr(self, k, kwargs[k])

    def _get_kwargs(self):
        var out = []
        var d = self.__dict__
        for k in d:
            out.append([k, d[k]])
        return out

    def __contains__(self, key):
        return key in self.__dict__

    def __eq__(self, other):
        if not isinstance(other, Namespace):
            return false
        return self._get_kwargs() == other._get_kwargs()

    def __ne__(self, other):
        return not self.__eq__(other)

    def __repr__(self):
        var parts = []
        var star = {}
        for kv in self._get_kwargs():
            if _is_identifier(kv[0]):
                parts.append(kv[0] + "=" + repr(kv[1]))
            else:
                star[kv[0]] = kv[1]
        if len(star) > 0:
            parts.append("**" + repr(star))
        return "Namespace(" + ", ".join(parts) + ")"

    def as_dict(self):
        var d = {}
        for kv in self._get_kwargs():
            d[kv[0]] = kv[1]
        return d


# ── actions ──────────────────────────────────────────────────────────────────
class Action:
    # Python's Action: what one argument is, and (its __call__) what giving
    # it does. Subclass it and define __call__(parser, namespace, values,
    # option_string) for an action of your own.
    def __init__(self, option_strings, dest, nargs=none, **kw):
        self.option_strings = list(option_strings)
        self.dest = dest
        self.nargs = nargs
        self.const = kw.get("const")
        self.default = kw.get("default")
        self.type = kw.get("type")
        self.choices = kw.get("choices")
        self.required = kw.get("required", false)
        self.help = kw.get("help")
        self.metavar = kw.get("metavar")
        self.container = none

    def is_optional(self):
        return len(self.option_strings) > 0

    def format_usage(self):
        return self.option_strings[0]

    def _get_kwargs(self):
        return [["option_strings", self.option_strings], ["dest", self.dest], ["nargs", self.nargs],
                ["const", self.const], ["default", self.default], ["type", self.type],
                ["choices", self.choices], ["required", self.required], ["help", self.help],
                ["metavar", self.metavar]]

    def __repr__(self):
        return type(self).__name__ + "(" + ", ".join([kv[0] + "=" + repr(kv[1]) for kv in self._get_kwargs()]) + ")"

    def __call__(self, parser, namespace, values, option_string=none):
        raise NotImplementedError(".__call__() not defined")


def _check_store_nargs(nargs, cst):
    if nargs == 0:
        raise ValueError("nargs for store actions must be != 0; if you have nothing to store, actions such as store true or store const may be more appropriate")
    if cst != none and nargs != OPTIONAL:
        raise ValueError("nargs must be " + repr(OPTIONAL) + " to supply const")


def _copy_items(items):
    if items == none:
        return []
    if isinstance(items, "list"):
        return list(items)
    return list(items)


class _StoreAction(Action):
    def __init__(self, option_strings, dest, nargs=none, **kw):
        _check_store_nargs(nargs, kw.get("const"))
        Action.__init__(self, option_strings, dest, nargs, **kw)

    def __call__(self, parser, namespace, values, option_string=none):
        setattr(namespace, self.dest, values)


class _StoreConstAction(Action):
    def __init__(self, option_strings, dest, **kw):
        Action.__init__(self, option_strings, dest, 0, **kw)

    def __call__(self, parser, namespace, values, option_string=none):
        setattr(namespace, self.dest, self.const)


class _StoreTrueAction(_StoreConstAction):
    def __init__(self, option_strings, dest, **kw):
        kw["const"] = true
        if not ("default" in kw):
            kw["default"] = false
        _StoreConstAction.__init__(self, option_strings, dest, **kw)


class _StoreFalseAction(_StoreConstAction):
    def __init__(self, option_strings, dest, **kw):
        kw["const"] = false
        if not ("default" in kw):
            kw["default"] = true
        _StoreConstAction.__init__(self, option_strings, dest, **kw)


class _AppendAction(Action):
    def __init__(self, option_strings, dest, nargs=none, **kw):
        _check_store_nargs(nargs, kw.get("const"))
        Action.__init__(self, option_strings, dest, nargs, **kw)

    def __call__(self, parser, namespace, values, option_string=none):
        var items = _copy_items(getattr(namespace, self.dest, none))
        items.append(values)
        setattr(namespace, self.dest, items)


class _AppendConstAction(Action):
    def __init__(self, option_strings, dest, **kw):
        Action.__init__(self, option_strings, dest, 0, **kw)

    def __call__(self, parser, namespace, values, option_string=none):
        var items = _copy_items(getattr(namespace, self.dest, none))
        items.append(self.const)
        setattr(namespace, self.dest, items)


class _ExtendAction(_AppendAction):
    def __call__(self, parser, namespace, values, option_string=none):
        var items = _copy_items(getattr(namespace, self.dest, none))
        for v in values:
            items.append(v)
        setattr(namespace, self.dest, items)


class _CountAction(Action):
    def __init__(self, option_strings, dest, **kw):
        Action.__init__(self, option_strings, dest, 0, **kw)

    def __call__(self, parser, namespace, values, option_string=none):
        var count = getattr(namespace, self.dest, none)
        if count == none:
            count = 0
        setattr(namespace, self.dest, count + 1)


class _HelpAction(Action):
    def __init__(self, option_strings, dest=SUPPRESS, **kw):
        if not ("default" in kw):
            kw["default"] = SUPPRESS
        Action.__init__(self, option_strings, dest, 0, **kw)

    def __call__(self, parser, namespace, values, option_string=none):
        parser.print_help()
        parser.exit()


class _VersionAction(Action):
    def __init__(self, option_strings, dest=SUPPRESS, **kw):
        if not ("default" in kw):
            kw["default"] = SUPPRESS
        if kw.get("help") == none:
            kw["help"] = "show program's version number and exit"
        Action.__init__(self, option_strings, dest, 0, **kw)
        self.version = kw.get("version")

    def __call__(self, parser, namespace, values, option_string=none):
        var version = self.version
        if version == none:
            version = getattr(parser, "version", none)
        var formatter = parser._get_formatter()
        formatter.add_text(version)
        parser._print_message(formatter.format_help(), sys.stdout)
        parser.exit()


class BooleanOptionalAction(Action):
    # --flag and --no-flag
    def __init__(self, option_strings, dest, **kw):
        var strings = []
        for o in option_strings:
            strings.append(o)
            if o.startswith("--"):
                strings.append("--no-" + o[2:])
        Action.__init__(self, strings, dest, 0, **kw)

    def __call__(self, parser, namespace, values, option_string=none):
        if option_string in self.option_strings:
            setattr(namespace, self.dest, not option_string.startswith("--no-"))

    def format_usage(self):
        return " | ".join(self.option_strings)


class _ChoicesPseudoAction(Action):
    # one subcommand's line in the help
    def __init__(self, name, aliases, help):
        var metavar = name
        if len(aliases) > 0:
            metavar = metavar + " (" + ", ".join(aliases) + ")"
        Action.__init__(self, [], name, none, help=help, metavar=metavar)


class _SubParsersAction(Action):
    # add_subparsers(): its positional names the subcommand, whose parser
    # then parses every argument after it
    def __init__(self, option_strings, prog=none, parser_class=none, dest=SUPPRESS, required=false,
                 help=none, metavar=none):
        self._prog_prefix = prog
        self._parser_class = parser_class
        self._name_parser_map = {}
        self._choices_actions = []
        Action.__init__(self, option_strings, dest, PARSER, choices=self._name_parser_map,
                        required=required, help=help, metavar=metavar)

    def add_parser(self, name, **kwargs):
        if kwargs.get("prog") == none:
            kwargs["prog"] = self._prog_prefix + " " + name
        var aliases = kwargs.get("aliases", [])
        if "aliases" in kwargs:
            del kwargs["aliases"]
        if name in self._name_parser_map:
            raise ArgumentError(self, "conflicting subparser: " + name)
        for al in aliases:
            if al in self._name_parser_map:
                raise ArgumentError(self, "conflicting subparser alias: " + al)
        if "help" in kwargs:
            var h = kwargs["help"]
            del kwargs["help"]
            self._choices_actions.append(_ChoicesPseudoAction(name, aliases, h))
        var cls = self._parser_class
        var parser = cls(**kwargs)
        self._name_parser_map[name] = parser
        for al in aliases:
            self._name_parser_map[al] = parser
        return parser

    def _get_subactions(self):
        return self._choices_actions

    def __call__(self, parser, namespace, values, option_string=none):
        var name = values[0]
        var rest = values[1:]
        if self.dest != SUPPRESS:
            setattr(namespace, self.dest, name)
        if not (name in self._name_parser_map):
            raise ArgumentError(self, "unknown parser " + repr(name) + " (choices: " + ", ".join([str(k) for k in self._name_parser_map]) + ")")
        var sub = self._name_parser_map[name]
        var r = sub.parse_known_args(rest, none)
        for kv in r[0]._get_kwargs():
            setattr(namespace, kv[0], kv[1])
        if len(r[1]) > 0:
            if not (_UNRECOGNIZED_ARGS_ATTR in namespace.__dict__):
                setattr(namespace, _UNRECOGNIZED_ARGS_ATTR, [])
            var un = getattr(namespace, _UNRECOGNIZED_ARGS_ATTR)
            for x in r[1]:
                un.append(x)


_ACTIONS = {"store": _StoreAction, "store_const": _StoreConstAction, "store_true": _StoreTrueAction,
            "store_false": _StoreFalseAction, "append": _AppendAction, "append_const": _AppendConstAction,
            "extend": _ExtendAction, "count": _CountAction, "help": _HelpAction, "version": _VersionAction,
            "parsers": _SubParsersAction}


class FileType:
    # argparse.FileType("r"): the named file, opened ("-": stdin / stdout)
    def __init__(self, mode="r", bufsize=-1, encoding=none, errors=none):
        self._mode = mode
        self._encoding = encoding

    def __call__(self, s):
        if s == "-":
            if "r" in self._mode:
                return sys.stdin
            if "w" in self._mode or "a" in self._mode or "x" in self._mode:
                return sys.stdout
            raise ValueError("argument \"-\" with mode " + repr(self._mode))
        try:
            if self._encoding != none:
                return open(s, self._mode, self._encoding)
            return open(s, self._mode)
        except OSError as e:
            raise ArgumentTypeError("can't open '" + s + "': " + str(e))

    def __repr__(self):
        return "FileType(" + repr(self._mode) + ")"


# ── argument matching (argparse's nargs patterns, without regexes) ───────────
# A command line is a pattern string: "O" an option, "A" a value, "-" the
# "--" separator. Each nargs is the pattern argparse builds a regex from;
# _lengths lists, longest first, how many pattern characters it can take
# from position p - the order a greedy regex tries them in, so a sequence
# matched by backtracking over these lists ends where the regex would.
def _run(pat, p, chars):
    var q = p
    var n = len(pat)
    while q < n and pat[q] in chars:
        q = q + 1
    return q - p


def _down(hi, lo):
    return list(range(hi, lo - 1, -1))


def _lengths(nargs, pat, p, positional):
    var n = len(pat)
    if not positional:
        # an option's values: no "-" in its pattern
        if nargs == none:
            return [1] if p < n and pat[p] == "A" else []
        if nargs == OPTIONAL:
            return [1, 0] if p < n and pat[p] == "A" else [0]
        if nargs == ZERO_OR_MORE:
            return _down(_run(pat, p, "A"), 0)
        if nargs == ONE_OR_MORE:
            var r1 = _run(pat, p, "A")
            return _down(r1, 1) if r1 >= 1 else []
        if nargs == REMAINDER:
            return _down(_run(pat, p, "AO"), 0)
        if nargs == PARSER:
            if p < n and pat[p] == "A":
                return _down(_run(pat, p, "AO"), 1)
            return []
        if nargs == SUPPRESS:
            return [0]
        return [nargs] if _run(pat, p, "A") >= nargs else []
    var d = _run(pat, p, "-")
    var has_a = p + d < n and pat[p + d] == "A"
    if nargs == none:
        if not has_a:
            return []
        return _down(d + 1 + _run(pat, p + d + 1, "-"), d + 1)
    if nargs == OPTIONAL:
        if has_a:
            return _down(d + 1 + _run(pat, p + d + 1, "-"), 0)
        return _down(d, 0)
    if nargs == ZERO_OR_MORE:
        return _down(_run(pat, p, "A-"), 0)
    if nargs == ONE_OR_MORE:
        if not has_a:
            return []
        return _down(d + 1 + _run(pat, p + d + 1, "A-"), d + 1)
    if nargs == REMAINDER:
        return _down(n - p, 0)
    if nargs == PARSER:
        if not has_a:
            return []
        return _down(n - p, d + 1)
    if nargs == SUPPRESS:
        return _down(d, 0)
    # N values, "--" allowed between them
    var q = p
    for j in range(nargs):
        q = q + _run(pat, q, "-")
        if q >= n or pat[q] != "A":
            return []
        q = q + 1
    return _down(q - p + _run(pat, q, "-"), q - p)


def _match_seq(actions, upto, pat, p, k):
    if k == upto:
        return []
    for ln in _lengths(actions[k].nargs, pat, p, true):
        var rest = _match_seq(actions, upto, pat, p + ln, k + 1)
        if rest != none:
            return [ln] + rest
    return none


def _match_partial(actions, pat, p):
    # as many of the positionals as can match, each one's count
    var i = len(actions)
    while i > 0:
        var r = _match_seq(actions, i, pat, p, 0)
        if r != none:
            return r
        i = i - 1
    return []


class _ParseState:
    def __init__(self, ns, args):
        self.ns = ns
        self.args = args
        self.pat = ""
        self.opt_at = {}
        self.seen = {}
        self.seen_nd = {}
        self.positionals = []
        self.extras = []


# ── text layout ──────────────────────────────────────────────────────────────
def _collapse(text):
    # runs of whitespace to one space, ends stripped (Python's \s+ -> " ")
    return " ".join(text.split())


def _chunks(text):
    # textwrap's chunks: words, the spaces between them, and words split
    # after a hyphen between letters ("long-option" can wrap after "long-")
    var out = []
    var words = text.split(" ")
    var first = true
    for w in words:
        if not first:
            out.append(" ")
        first = false
        if w == "":
            continue
        var start = 0
        var i = 2
        while i < len(w) - 1:
            if w[i] == "-" and w[i - 1].isalpha() and w[i - 2].isalpha() and w[i + 1].isalpha():
                out.append(w[start:i + 1])
                start = i + 1
            i = i + 1
        out.append(w[start:])
    return out


def _wrap(text, width):
    # textwrap.wrap(text, width) for collapsed text: greedy, long words
    # broken (after a hyphen when one fits)
    var chunks = _chunks(text)
    chunks.reverse()
    var lines = []
    while len(chunks) > 0:
        var cur = []
        var cur_len = 0
        if chunks[len(chunks) - 1].strip() == "" and len(lines) > 0:
            chunks.pop()
        while len(chunks) > 0:
            var ln = len(chunks[len(chunks) - 1])
            if cur_len + ln <= width:
                cur.append(chunks.pop())
                cur_len = cur_len + ln
            else:
                break
        if len(chunks) > 0 and len(chunks[len(chunks) - 1]) > width:
            var space_left = width - cur_len if width >= 1 else 1
            var chunk = chunks[len(chunks) - 1]
            var end = space_left
            var hyphen = chunk.rfind("-", 0, space_left)
            if hyphen > 0 and chunk[0:hyphen].strip("-") != "":
                end = hyphen + 1
            cur.append(chunk[0:end])
            chunks[len(chunks) - 1] = chunk[end:]
        if len(cur) > 0 and cur[len(cur) - 1].strip() == "":
            cur.pop()
        if len(cur) > 0:
            lines.append("".join(cur))
    return lines


def _usage_tokens(text):
    # Python's \(.*?\)+(?=\s|$)|\[.*?\]+(?=\s|$)|\S+ over a usage string
    var out = []
    var i = 0
    var n = len(text)
    while i < n:
        if text[i] == " ":
            i = i + 1
            continue
        var j = -1
        var c = text[i]
        if c == "(" or c == "[":
            var close = ")" if c == "(" else "]"
            var k = i + 1
            while k < n:
                if text[k] == close:
                    var m = k
                    while m < n and text[m] == close:
                        m = m + 1
                    if m == n or text[m] == " ":
                        j = m
                        break
                k = k + 1
        if j < 0:
            j = i
            while j < n and text[j] != " ":
                j = j + 1
        out.append(text[i:j])
        i = j
    return out


def _usage_lines(parts, indent, text_width, prefix):
    var lines = []
    var line = []
    var line_len = len(prefix) - 1 if prefix != none else len(indent) - 1
    for part in parts:
        if line_len + 1 + len(part) > text_width and len(line) > 0:
            lines.append(indent + " ".join(line))
            line = []
            line_len = len(indent) - 1
        line.append(part)
        line_len = line_len + len(part) + 1
    if len(line) > 0:
        lines.append(indent + " ".join(line))
    if prefix != none and len(lines) > 0:
        lines[0] = lines[0][len(indent):]
    return lines


def _terminal_columns():
    try:
        return os_get_terminal_size()[0]
    except Exception:
        return 80


class _Section:
    def __init__(self, parent, heading):
        self.parent = parent
        self.heading = heading
        self.items = []


class HelpFormatter:
    # Python's HelpFormatter: usage, text and argument sections, laid out
    # when format_help() is called (help is aligned to the longest
    # invocation of the whole parser)
    def __init__(self, prog, indent_increment=2, max_help_position=24, width=none):
        if width == none:
            width = _terminal_columns() - 2
        self._prog = prog
        self._indent_increment = indent_increment
        self._max_help_position = min(max_help_position, max(width - 20, indent_increment * 2))
        self._width = width
        self._current_indent = 0
        self._level = 0
        self._action_max_length = 0
        self._root_section = _Section(none, none)
        self._current_section = self._root_section

    def _indent(self):
        self._current_indent = self._current_indent + self._indent_increment
        self._level = self._level + 1

    def _dedent(self):
        self._current_indent = self._current_indent - self._indent_increment
        self._level = self._level - 1

    # ── what the parser adds ──
    def start_section(self, heading):
        self._indent()
        var section = _Section(self._current_section, heading)
        self._current_section.items.append(["section", section])
        self._current_section = section

    def end_section(self):
        self._current_section = self._current_section.parent
        self._dedent()

    def add_text(self, text):
        if text != SUPPRESS and text != none:
            self._current_section.items.append(["text", text])

    def add_usage(self, usage, actions, groups, prefix=none):
        if usage != SUPPRESS:
            self._current_section.items.append(["usage", [usage, actions, groups, prefix]])

    def add_argument(self, action):
        if action.help != SUPPRESS:
            var invocations = [self._format_action_invocation(action)]
            if hasattr(action, "_get_subactions"):
                for sub in action._get_subactions():
                    invocations.append(self._format_action_invocation(sub))
            var longest = 0
            for inv in invocations:
                if len(inv) > longest:
                    longest = len(inv)
            self._action_max_length = max(self._action_max_length, longest + self._current_indent)
            self._current_section.items.append(["action", action])

    def add_arguments(self, actions):
        for a in actions:
            self.add_argument(a)

    # ── layout ──
    def format_help(self):
        var h = self._render_section(self._root_section)
        if h != "":
            while "\n\n\n" in h:
                h = h.replace("\n\n\n", "\n\n")
            h = h.strip("\n") + "\n"
        return h

    def _join_parts(self, parts):
        return "".join([p for p in parts if p != none and p != "" and p != SUPPRESS])

    def _render_section(self, sec):
        if sec.parent != none:
            self._indent()
        var parts = []
        for it in sec.items:
            var kind = it[0]
            if kind == "text":
                parts.append(self._format_text(it[1]))
            elif kind == "usage":
                parts.append(self._format_usage(it[1][0], it[1][1], it[1][2], it[1][3]))
            elif kind == "action":
                parts.append(self._format_action(it[1]))
            else:
                parts.append(self._render_section(it[1]))
        var body = self._join_parts(parts)
        if sec.parent != none:
            self._dedent()
        if body == "":
            return ""
        var heading = ""
        if sec.heading != none and sec.heading != SUPPRESS:
            heading = " " * self._current_indent + sec.heading + ":\n"
        return self._join_parts(["\n", heading, body, "\n"])

    def _format_usage(self, usage, actions, groups, prefix):
        if prefix == none:
            prefix = "usage: "
        if usage != none:
            usage = usage % {"prog": self._prog}
        elif len(actions) == 0:
            usage = self._prog
        else:
            var prog = self._prog
            var optionals = [a for a in actions if a.is_optional()]
            var positionals = [a for a in actions if not a.is_optional()]
            var action_usage = self._format_actions_usage(optionals + positionals, groups)
            usage = " ".join([s for s in [prog, action_usage] if s != ""])
            var text_width = self._width - self._current_indent
            if len(prefix) + len(usage) > text_width:
                var opt_parts = _usage_tokens(self._format_actions_usage(optionals, groups))
                var pos_parts = _usage_tokens(self._format_actions_usage(positionals, groups))
                var lines = []
                if len(prefix) + len(prog) <= 0.75 * text_width:
                    var indent = " " * (len(prefix) + len(prog) + 1)
                    if len(opt_parts) > 0:
                        lines = _usage_lines([prog] + opt_parts, indent, text_width, prefix)
                        lines = lines + _usage_lines(pos_parts, indent, text_width, none)
                    elif len(pos_parts) > 0:
                        lines = _usage_lines([prog] + pos_parts, indent, text_width, prefix)
                    else:
                        lines = [prog]
                else:
                    var indent2 = " " * len(prefix)
                    lines = _usage_lines(opt_parts + pos_parts, indent2, text_width, none)
                    if len(lines) > 1:
                        lines = _usage_lines(opt_parts, indent2, text_width, none) + _usage_lines(pos_parts, indent2, text_width, none)
                    lines = [prog] + lines
                usage = "\n".join(lines)
        return prefix + usage + "\n\n"

    def _format_actions_usage(self, actions, groups):
        # one part per argument; a mutually exclusive group whose members
        # are listed together is one part, "[-a | -b]" or "(-a | -b)"
        var ids = [id(a) for a in actions]
        var group_at = {}
        var grouped = {}
        for g in groups:
            if len(g._group_actions) == 0:
                continue
            var first = id(g._group_actions[0])
            if first in ids:
                var start = ids.index(first)
                var gids = [id(a) for a in g._group_actions]
                if ids[start:start + len(gids)] == gids:
                    group_at[start] = g
                    for x in gids:
                        grouped[x] = true
        var parts = []
        var i = 0
        while i < len(actions):
            if i in group_at:
                var g2 = group_at[i]
                var members = [self._usage_part(a, true) for a in g2._group_actions if a.help != SUPPRESS]
                if len(members) > 0:
                    var inner = " | ".join(members)
                    if not g2.required:
                        parts.append("[" + inner + "]")
                    elif len(members) > 1:
                        parts.append("(" + inner + ")")
                    else:
                        parts.append(inner)
                i = i + len(g2._group_actions)
                continue
            var a2 = actions[i]
            if a2.help != SUPPRESS:
                var p = self._usage_part(a2, false)
                if p != "":
                    parts.append(p)
            i = i + 1
        return " ".join(parts)

    def _usage_part(self, a, grouped):
        if not a.is_optional():
            var part = self._format_args(a, self._get_default_metavar_for_positional(a))
            if grouped and len(part) > 1 and part[0] == "[" and part[len(part) - 1] == "]":
                part = part[1:len(part) - 1]
            return part
        var part2 = ""
        if a.nargs == 0:
            part2 = a.format_usage()
        else:
            part2 = a.option_strings[0] + " " + self._format_args(a, self._get_default_metavar_for_optional(a))
        if not a.required and not grouped:
            part2 = "[" + part2 + "]"
        return part2

    def _format_text(self, text):
        if "%(prog)" in text:
            text = text % {"prog": self._prog}
        var text_width = max(self._width - self._current_indent, 11)
        var indent = " " * self._current_indent
        return self._fill_text(text, text_width, indent) + "\n\n"

    def _format_action(self, action):
        var help_position = min(self._action_max_length + 2, self._max_help_position)
        var help_width = max(self._width - help_position, 11)
        var action_width = help_position - self._current_indent - 2
        var header = self._format_action_invocation(action)
        var indent_first = 0
        if action.help == none or action.help == "":
            header = " " * self._current_indent + header + "\n"
        elif len(header) <= action_width:
            header = " " * self._current_indent + header + " " * (action_width - len(header)) + "  "
        else:
            header = " " * self._current_indent + header + "\n"
            indent_first = help_position
        var parts = [header]
        if action.help != none and action.help.strip() != "":
            var help_text = self._expand_help(action)
            if help_text != "":
                var help_lines = self._split_lines(help_text, help_width)
                if len(help_lines) == 0:
                    help_lines = [""]
                parts.append(" " * indent_first + help_lines[0] + "\n")
                for line in help_lines[1:]:
                    parts.append(" " * help_position + line + "\n")
        elif not header.endswith("\n"):
            parts.append("\n")
        if hasattr(action, "_get_subactions"):
            self._indent()
            for sub in action._get_subactions():
                parts.append(self._format_action(sub))
            self._dedent()
        return self._join_parts(parts)

    def _format_action_invocation(self, action):
        if not action.is_optional():
            return self._metavars(action, self._get_default_metavar_for_positional(action), 1)[0]
        if action.nargs == 0:
            return ", ".join(action.option_strings)
        var args_string = self._format_args(action, self._get_default_metavar_for_optional(action))
        return ", ".join([o + " " + args_string for o in action.option_strings])

    def _metavar_value(self, action, default_metavar):
        if action.metavar != none:
            return action.metavar
        if action.choices != none:
            return "{" + ",".join([str(c) for c in action.choices]) + "}"
        return default_metavar

    def _metavars(self, action, default_metavar, size):
        var r = self._metavar_value(action, default_metavar)
        if isinstance(r, "str"):
            return [r] * size
        return [str(m) for m in r]

    def _format_args(self, action, default_metavar):
        var n = action.nargs
        if n == none:
            return self._metavars(action, default_metavar, 1)[0]
        if n == OPTIONAL:
            return "[" + self._metavars(action, default_metavar, 1)[0] + "]"
        if n == ZERO_OR_MORE:
            var m = self._metavars(action, default_metavar, 1)
            if len(m) == 2:
                return "[" + m[0] + " [" + m[1] + " ...]]"
            return "[" + m[0] + " ...]"
        if n == ONE_OR_MORE:
            var m2 = self._metavars(action, default_metavar, 2)
            if len(m2) != 2:
                raise ValueError("length of metavar tuple does not match nargs")
            return m2[0] + " [" + m2[1] + " ...]"
        if n == REMAINDER:
            return "..."
        if n == PARSER:
            return self._metavars(action, default_metavar, 1)[0] + " ..."
        if n == SUPPRESS:
            return ""
        if not isinstance(n, "int"):
            raise ValueError("invalid nargs value")
        var ms = self._metavars(action, default_metavar, n)
        if len(ms) != n:
            raise ValueError("length of metavar tuple does not match nargs")
        return " ".join(ms)

    def _expand_help(self, action):
        var params = {}
        for kv in action._get_kwargs():
            var v = kv[1]
            if isinstance(v, "str") and v == SUPPRESS:
                continue
            if v != none and not isinstance(v, "str") and callable(v) and hasattr(v, "__name__"):
                v = v.__name__
            params[kv[0]] = v
        params["prog"] = self._prog
        if params.get("choices") != none:
            params["choices"] = ", ".join([str(c) for c in params["choices"]])
        return self._get_help_string(action) % params

    # ── what the formatter classes change ──
    def _get_help_string(self, action):
        return action.help

    def _split_lines(self, text, width):
        return _wrap(_collapse(text), width)

    def _fill_text(self, text, width, indent):
        return "\n".join([indent + line for line in _wrap(_collapse(text), width)])

    def _get_default_metavar_for_optional(self, action):
        return action.dest.upper()

    def _get_default_metavar_for_positional(self, action):
        return action.dest


class RawDescriptionHelpFormatter(HelpFormatter):
    # the description and epilog as written
    def _fill_text(self, text, width, indent):
        return "".join([indent + line for line in text.splitlines(true)])


class RawTextHelpFormatter(RawDescriptionHelpFormatter):
    # every help text as written
    def _split_lines(self, text, width):
        return text.splitlines()


class ArgumentDefaultsHelpFormatter(HelpFormatter):
    # "(default: ...)" after each argument's help
    def _get_help_string(self, action):
        var h = action.help
        if h == none:
            h = ""
        if not ("%(default)" in h) and not (isinstance(action.default, "str") and action.default == SUPPRESS):
            if action.is_optional() or action.nargs == OPTIONAL or action.nargs == ZERO_OR_MORE:
                h = h + " (default: %(default)s)"
        return h


class MetavarTypeHelpFormatter(HelpFormatter):
    # metavars from the argument types (int, float, ...)
    def _get_default_metavar_for_optional(self, action):
        return action.type.__name__

    def _get_default_metavar_for_positional(self, action):
        return action.type.__name__


# ── groups ───────────────────────────────────────────────────────────────────
class _ArgumentGroup:
    # add_argument_group(): a titled section of the help
    def __init__(self, parser, title=none, description=none):
        self._parser = parser
        self.title = title
        self.description = description
        self._group_actions = []

    def add_argument(self, *args, **kwargs):
        return self._parser._add_argument_in(self, args, kwargs)

    def add_mutually_exclusive_group(self, required=false):
        var g = _MutuallyExclusiveGroup(self._parser, self, required)
        self._parser._mutually_exclusive_groups.append(g)
        return g

    def set_defaults(self, **kwargs):
        self._parser.set_defaults(**kwargs)

    def get_default(self, dest):
        return self._parser.get_default(dest)


class _MutuallyExclusiveGroup:
    # at most one of its arguments; with required=True exactly one
    def __init__(self, parser, container, required=false):
        self._parser = parser
        self._container = container
        self.required = required
        self.title = none
        self.description = none
        self._group_actions = []

    def add_argument(self, *args, **kwargs):
        var a = self._parser._add_argument_in(self._container, args, kwargs)
        if a.required:
            raise ValueError("mutually exclusive arguments must be optional")
        self._group_actions.append(a)
        return a


# ── the parser ───────────────────────────────────────────────────────────────
class ArgumentParser:
    def __init__(self, prog=none, usage=none, description=none, epilog=none, parents=none,
                 formatter_class=none, prefix_chars="-", fromfile_prefix_chars=none,
                 argument_default=none, conflict_handler="error", add_help=true, allow_abbrev=true,
                 exit_on_error=true, suggest_on_error=true, version=none):
        if prog == none:
            prog = "nython"
            if len(sys.argv) > 0 and sys.argv[0] != "":
                prog = os_path_basename(sys.argv[0])
        self.prog = prog
        self.usage = usage
        self.description = description
        self.epilog = epilog
        self.formatter_class = formatter_class if formatter_class != none else HelpFormatter
        self.prefix_chars = prefix_chars
        self.fromfile_prefix_chars = fromfile_prefix_chars
        self.argument_default = argument_default
        self.conflict_handler = conflict_handler
        self.add_help = add_help
        self.allow_abbrev = allow_abbrev
        self.exit_on_error = exit_on_error
        self.suggest_on_error = suggest_on_error
        self.version = version
        self._registries = {"action": dict(_ACTIONS), "type": {}}
        self._actions = []
        self._option_string_actions = {}
        self._positionals_list = []
        self._action_groups = []
        self._mutually_exclusive_groups = []
        self._defaults = {}
        self._has_negative_number_optionals = false
        self._subparsers = none
        self._positionals = self.add_argument_group("positional arguments")
        self._optionals = self.add_argument_group("options")
        if add_help:
            var default_prefix = "-" if "-" in prefix_chars else prefix_chars[0]
            self.add_argument(default_prefix + "h", default_prefix * 2 + "help", action="help",
                              default=SUPPRESS, help="show this help message and exit")
        if parents != none:
            for par in parents:
                self._add_container_actions(par)
                for k in par._defaults:
                    self._defaults[k] = par._defaults[k]

    def __repr__(self):
        return "ArgumentParser(prog=" + repr(self.prog) + ", usage=" + repr(self.usage) + ", description=" + repr(self.description) + ", formatter_class=" + repr(self.formatter_class) + ", conflict_handler=" + repr(self.conflict_handler) + ", add_help=" + repr(self.add_help) + ")"

    # ── definition ──
    def register(self, registry_name, value, obj):
        if not (registry_name in self._registries):
            self._registries[registry_name] = {}
        self._registries[registry_name][value] = obj

    def add_argument(self, *args, **kwargs):
        return self._add_argument_in(none, args, kwargs)

    def _add_argument_in(self, group, args, kwargs):
        var kw = dict(kwargs)
        var chars = self.prefix_chars
        if len(args) == 0 or (len(args) == 1 and not (args[0][0:1] in chars and args[0] != "")):
            if len(args) > 0 and "dest" in kw:
                raise ValueError("dest supplied twice for positional argument")
            if "required" in kw:
                raise TypeError("'required' is an invalid argument for positionals")
            if len(args) > 0:
                kw["dest"] = args[0]
            if not (kw.get("nargs") == OPTIONAL or kw.get("nargs") == ZERO_OR_MORE):
                kw["required"] = true
            if kw.get("nargs") == ZERO_OR_MORE and not ("default" in kw):
                kw["required"] = true
            kw["option_strings"] = []
        else:
            var strings = []
            var longs = []
            for o in args:
                if o == "" or not (o[0] in chars):
                    raise ValueError("invalid option string " + repr(o) + ": must start with a character " + repr(chars))
                strings.append(o)
                if len(o) > 1 and o[1] in chars:
                    longs.append(o)
            if kw.get("dest") == none:
                var pick = longs[0] if len(longs) > 0 else strings[0]
                var dest = pick.lstrip(chars)
                if dest == "":
                    raise ValueError("dest= is required for options like " + repr(pick))
                kw["dest"] = dest.replace("-", "_")
            kw["option_strings"] = strings
        if not ("default" in kw):
            if kw["dest"] in self._defaults:
                kw["default"] = self._defaults[kw["dest"]]
            elif self.argument_default != none:
                kw["default"] = self.argument_default
        var action_class = kw.get("action")
        if "action" in kw:
            del kw["action"]
        if action_class == none:
            action_class = "store"
        if isinstance(action_class, "str"):
            if not (action_class in self._registries["action"]):
                raise ValueError("unknown action " + repr(action_class))
            action_class = self._registries["action"][action_class]
        if not callable(action_class):
            raise ValueError("unknown action " + repr(action_class))
        var opts = kw["option_strings"]
        var dest2 = kw["dest"]
        del kw["option_strings"]
        del kw["dest"]
        var action = action_class(opts, dest2, **kw)
        var tf = action.type
        if isinstance(tf, "str") and tf in self._registries["type"]:
            tf = self._registries["type"][tf]
            action.type = tf
        if tf != none and not callable(tf):
            raise ValueError(repr(tf) + " is not callable")
        if tf == FileType:
            raise ValueError(repr(tf) + " is a FileType class object, instance of it must be passed")
        self._get_formatter()._format_args(action, "x")
        return self._add_action(action, group)

    def _add_action(self, action, group=none):
        self._check_conflict(action)
        self._actions.append(action)
        action.container = self
        for o in action.option_strings:
            self._option_string_actions[o] = action
            if _is_negative_number(o):
                self._has_negative_number_optionals = true
        if not action.is_optional():
            self._positionals_list.append(action)
        var g = group
        if g == none:
            g = self._optionals if action.is_optional() else self._positionals
        g._group_actions.append(action)
        return action

    def _remove_action(self, action):
        self._actions = [x for x in self._actions if id(x) != id(action)]
        self._positionals_list = [x for x in self._positionals_list if id(x) != id(action)]
        for g in self._action_groups:
            g._group_actions = [x for x in g._group_actions if id(x) != id(action)]

    def _check_conflict(self, action):
        var conflicts = []
        for o in action.option_strings:
            if o in self._option_string_actions:
                conflicts.append([o, self._option_string_actions[o]])
        if len(conflicts) == 0:
            return
        if self.conflict_handler == "resolve":
            for c in conflicts:
                var old = c[1]
                old.option_strings = [s for s in old.option_strings if s != c[0]]
                del self._option_string_actions[c[0]]
                if len(old.option_strings) == 0:
                    self._remove_action(old)
            return
        var names = ", ".join([c[0] for c in conflicts])
        raise ArgumentError(action, ("conflicting option string: " if len(conflicts) == 1 else "conflicting option strings: ") + names)

    def _add_container_actions(self, container):
        # a parent parser's arguments, groups and exclusive groups
        var by_title = {}
        for g in self._action_groups:
            by_title[g.title] = g
        var group_of = {}
        for g in container._action_groups:
            if not (g.title in by_title):
                by_title[g.title] = self.add_argument_group(g.title, g.description)
            for a in g._group_actions:
                group_of[id(a)] = by_title[g.title]
        var mutex_of = {}
        for mg in container._mutually_exclusive_groups:
            var nm = self.add_mutually_exclusive_group(mg.required)
            for a2 in mg._group_actions:
                mutex_of[id(a2)] = nm
        for a3 in container._actions:
            self._add_action(a3, group_of.get(id(a3)))
            if id(a3) in mutex_of:
                mutex_of[id(a3)]._group_actions.append(a3)

    def add_argument_group(self, title=none, description=none, **kwargs):
        var g = _ArgumentGroup(self, title, description)
        self._action_groups.append(g)
        return g

    def add_mutually_exclusive_group(self, required=false):
        var g = _MutuallyExclusiveGroup(self, none, required)
        self._mutually_exclusive_groups.append(g)
        return g

    def add_subparsers(self, **kwargs):
        if self._subparsers != none:
            self.error("cannot have multiple subparser arguments")
        if kwargs.get("parser_class") == none:
            kwargs["parser_class"] = ArgumentParser
        var group = self._positionals
        if "title" in kwargs or "description" in kwargs:
            var title = kwargs.get("title", "subcommands")
            var description = kwargs.get("description")
            if "title" in kwargs:
                del kwargs["title"]
            if "description" in kwargs:
                del kwargs["description"]
            group = self.add_argument_group(title, description)
        if kwargs.get("prog") == none:
            var formatter = self._get_formatter()
            formatter.add_usage(self.usage, self._positionals_list, self._mutually_exclusive_groups, "")
            kwargs["prog"] = formatter.format_help().strip()
        var cls = kwargs.get("action", _SubParsersAction)
        if "action" in kwargs:
            del kwargs["action"]
        if isinstance(cls, "str"):
            cls = self._registries["action"][cls]
        var action = cls([], **kwargs)
        self._subparsers = group
        self._add_action(action, group)
        return action

    def set_defaults(self, **kwargs):
        for k in kwargs:
            self._defaults[k] = kwargs[k]
        for a in self._actions:
            if a.dest in kwargs:
                a.default = kwargs[a.dest]

    def get_default(self, dest):
        for a in self._actions:
            if a.dest == dest and a.default != none:
                return a.default
        return self._defaults.get(dest)

    def convert_arg_line_to_args(self, arg_line):
        return [arg_line]

    # ── parsing ──
    def parse_args(self, args=none, namespace=none):
        var r = self.parse_known_args(args, namespace)
        if len(r[1]) > 0:
            var msg = "unrecognized arguments: " + " ".join(r[1])
            var first = r[1][0]
            if self.suggest_on_error and len(first) > 1 and first[0] in self.prefix_chars:
                var word = first.split("=")[0]
                if word in self._option_string_actions:
                    # known here, so it came back from a subcommand
                    msg = msg + " (" + word + " is an option of " + self.prog + ": give it before the subcommand)"
                else:
                    var near = _close_match(word, [o for o in self._option_string_actions])
                    if near != none:
                        msg = msg + " (did you mean " + near + "?)"
            self.error(msg)
        return r[0]

    def parse_known_args(self, args=none, namespace=none):
        if args == none:
            args = list(sys.argv[1:])
        else:
            args = list(args)
        if namespace == none:
            namespace = Namespace()
        for a in self._actions:
            if a.dest != SUPPRESS and not hasattr(namespace, a.dest):
                if not (isinstance(a.default, "str") and a.default == SUPPRESS):
                    setattr(namespace, a.dest, a.default)
        for k in self._defaults:
            if not hasattr(namespace, k):
                setattr(namespace, k, self._defaults[k])
        var r = none
        if self.exit_on_error:
            try:
                r = self._parse_known_args(args, namespace)
            except ArgumentError as err:
                self.error(str(err))
        else:
            r = self._parse_known_args(args, namespace)
        var extras = r[1]
        if _UNRECOGNIZED_ARGS_ATTR in namespace.__dict__:
            for x in getattr(namespace, _UNRECOGNIZED_ARGS_ATTR):
                extras.append(x)
            delattr(namespace, _UNRECOGNIZED_ARGS_ATTR)
        return (r[0], extras)

    def parse_intermixed_args(self, args=none, namespace=none):
        var r = self.parse_known_intermixed_args(args, namespace)
        if len(r[1]) > 0:
            self.error("unrecognized arguments: " + " ".join(r[1]))
        return r[0]

    def parse_known_intermixed_args(self, args=none, namespace=none):
        # options first (positionals set aside), then the positionals from
        # what is left, wherever they stood among the options
        var positionals = self._positionals_list
        for a in positionals:
            if a.nargs == PARSER or a.nargs == REMAINDER:
                raise TypeError("parse_intermixed_args: positional arg with nargs=" + str(a.nargs))
        var saved = []
        for a in positionals:
            saved.append([a, a.nargs, a.default])
            a.nargs = SUPPRESS
            a.default = SUPPRESS
        var r1 = none
        try:
            r1 = self.parse_known_args(args, namespace)
        finally:
            for s in saved:
                s[0].nargs = s[1]
                s[0].default = s[2]
        var ns = r1[0]
        var optionals = [a for a in self._actions if a.is_optional()]
        var saved_req = []
        for a in optionals:
            saved_req.append([a, a.required])
            a.required = false
        var saved_groups = []
        for g in self._mutually_exclusive_groups:
            saved_groups.append([g, g.required])
            g.required = false
        var r2 = none
        try:
            r2 = self.parse_known_args(r1[1], ns)
        finally:
            for s in saved_req:
                s[0].required = s[1]
            for s in saved_groups:
                s[0].required = s[1]
        return r2

    def _read_args_from_files(self, arg_strings):
        var out = []
        for s in arg_strings:
            if s == "" or not (s[0] in self.fromfile_prefix_chars):
                out.append(s)
                continue
            var text = ""
            try:
                var fh = open(s[1:])
                text = fh.read()
                fh.close()
            except OSError as err:
                self.error(str(err))
            var inner = []
            for line in text.splitlines():
                for arg in self.convert_arg_line_to_args(line):
                    inner.append(arg)
            for x in self._read_args_from_files(inner):
                out.append(x)
        return out

    def _parse_optional(self, s):
        # [action or none, option string, explicit value or none] for an
        # option, none for a value
        if s == "" or not (s[0] in self.prefix_chars):
            return none
        if s in self._option_string_actions:
            return [self._option_string_actions[s], s, none]
        if len(s) == 1:
            return none
        var eq = s.find("=")
        if eq >= 0:
            var name = s[0:eq]
            if name in self._option_string_actions:
                return [self._option_string_actions[name], name, s[eq + 1:]]
        var tuples = self._get_option_tuples(s)
        if len(tuples) > 1:
            raise ArgumentError(none, "ambiguous option: " + s + " could match " + ", ".join([t[1] for t in tuples]))
        if len(tuples) == 1:
            return tuples[0]
        if _is_negative_number(s) and not self._has_negative_number_optionals:
            return none
        if " " in s:
            return none
        return [none, s, none]

    def _get_option_tuples(self, s):
        var out = []
        var chars = self.prefix_chars
        if s[0] in chars and s[1] in chars:
            if self.allow_abbrev:
                var prefix = s
                var explicit = none
                var eq = s.find("=")
                if eq >= 0:
                    prefix = s[0:eq]
                    explicit = s[eq + 1:]
                for o in self._option_string_actions:
                    if o.startswith(prefix):
                        out.append([self._option_string_actions[o], o, explicit])
        elif s[0] in chars:
            var short_prefix = s[0:2]
            var short_explicit = s[2:]
            for o in self._option_string_actions:
                if o == short_prefix:
                    out.append([self._option_string_actions[o], o, short_explicit])
                elif self.allow_abbrev and o.startswith(s):
                    out.append([self._option_string_actions[o], o, none])
        return out

    def _parse_known_args(self, arg_strings, namespace):
        if self.fromfile_prefix_chars != none:
            arg_strings = self._read_args_from_files(arg_strings)
        var st = _ParseState(namespace, arg_strings)
        var pattern = []
        var n = len(arg_strings)
        var i = 0
        while i < n:
            var s = arg_strings[i]
            if s == "--":
                pattern.append("-")
                i = i + 1
                while i < n:
                    pattern.append("A")
                    i = i + 1
                break
            var t = self._parse_optional(s)
            if t == none:
                pattern.append("A")
            else:
                st.opt_at[i] = t
                pattern.append("O")
            i = i + 1
        st.pat = "".join(pattern)
        st.positionals = list(self._positionals_list)
        var max_opt = -1
        for k in st.opt_at:
            if k > max_opt:
                max_opt = k
        var start = 0
        while start <= max_opt:
            var nxt = n
            for k2 in st.opt_at:
                if k2 >= start and k2 < nxt:
                    nxt = k2
            if start != nxt:
                var pend = self._consume_positionals(st, start)
                if pend > start:
                    start = pend
                    continue
                start = pend
            if not (start in st.opt_at):
                for x in arg_strings[start:nxt]:
                    st.extras.append(x)
                start = nxt
            start = self._consume_optional(st, start)
        var stop = self._consume_positionals(st, start)
        for x2 in arg_strings[stop:]:
            st.extras.append(x2)
        var required = []
        for a in self._actions:
            if not (id(a) in st.seen):
                if a.required:
                    required.append(_action_name(a))
                elif isinstance(a.default, "str") and a.default != SUPPRESS and a.dest != SUPPRESS and hasattr(namespace, a.dest):
                    var cur = getattr(namespace, a.dest)
                    if isinstance(cur, "str") and cur == a.default:
                        setattr(namespace, a.dest, self._get_value(a, a.default))
        if len(required) > 0:
            self.error("the following arguments are required: " + ", ".join(required))
        for g in self._mutually_exclusive_groups:
            if g.required:
                var hit = false
                for a2 in g._group_actions:
                    if id(a2) in st.seen_nd:
                        hit = true
                if not hit:
                    self.error("one of the arguments " + " ".join([_action_name(a3) for a3 in g._group_actions if a3.help != SUPPRESS]) + " is required")
        return [namespace, st.extras]

    def _consume_positionals(self, st, start):
        var counts = _match_partial(st.positionals, st.pat, start)
        # positionals that matched nothing where an option follows wait for
        # the values after it (Python 3.13's rule; 3.11 consumed them empty,
        # so `cmd --opt x a b` left a and b unrecognized)
        var end = start
        for c0 in counts:
            end = end + c0
        if end < len(st.pat) and st.pat[end] == "O":
            while len(counts) > 0 and counts[len(counts) - 1] == 0:
                counts.pop()
        var k = 0
        for c in counts:
            var a = st.positionals[k]
            var vals = st.args[start:start + c]
            # the "--" that ended the options is not a value
            if a.nargs == PARSER:
                if c > 0 and st.pat[start] == "-":
                    vals = vals[1:]
            elif a.nargs != REMAINDER:
                if "-" in st.pat[start:start + c]:
                    vals = list(vals)
                    vals.remove("--")
            self._take_action(st, a, vals, none)
            start = start + c
            k = k + 1
        st.positionals = st.positionals[len(counts):]
        return start

    def _match_argument(self, action, pat, p):
        var ls = _lengths(action.nargs, pat, p, false)
        if len(ls) == 0:
            var msg = none
            if action.nargs == none:
                msg = "expected one argument"
            elif action.nargs == OPTIONAL:
                msg = "expected at most one argument"
            elif action.nargs == ONE_OR_MORE:
                msg = "expected at least one argument"
            elif isinstance(action.nargs, "int"):
                msg = "expected " + str(action.nargs) + " argument" + ("" if action.nargs == 1 else "s")
            else:
                msg = "expected " + str(action.nargs) + " arguments"
            raise ArgumentError(action, msg)
        return ls[0]

    def _consume_optional(self, st, start):
        var t = st.opt_at[start]
        var action = t[0]
        var option_string = t[1]
        var explicit = t[2]
        var todo = []
        var stop = start + 1
        var chars = self.prefix_chars
        while true:
            if action == none:
                st.extras.append(st.args[start])
                return start + 1
            if explicit != none:
                var cnt = self._match_argument(action, "A", 0)
                if cnt == 0 and not (option_string[1] in chars) and explicit != "":
                    # -abc: -a takes nothing, so b is the next option
                    todo.append([action, [], option_string])
                    option_string = option_string[0] + explicit[0]
                    var rest = explicit[1:]
                    if option_string in self._option_string_actions:
                        action = self._option_string_actions[option_string]
                        explicit = rest if rest != "" else none
                    else:
                        raise ArgumentError(action, "ignored explicit argument " + repr(explicit))
                elif cnt == 1:
                    stop = start + 1
                    todo.append([action, [explicit], option_string])
                    break
                else:
                    raise ArgumentError(action, "ignored explicit argument " + repr(explicit))
            else:
                var s0 = start + 1
                var cnt2 = self._match_argument(action, st.pat, s0)
                stop = s0 + cnt2
                todo.append([action, st.args[s0:stop], option_string])
                break
        for tup in todo:
            self._take_action(st, tup[0], tup[1], tup[2])
        return stop

    def _take_action(self, st, action, strings, option_string):
        st.seen[id(action)] = true
        var values = self._get_values(action, strings)
        var nondefault = action.is_optional() or len(strings) > 0 or (action.nargs == ZERO_OR_MORE and action.default == none)
        if nondefault:
            st.seen_nd[id(action)] = true
            for g in self._mutually_exclusive_groups:
                var ids = [id(x) for x in g._group_actions]
                if id(action) in ids:
                    for other in g._group_actions:
                        if id(other) != id(action) and id(other) in st.seen_nd:
                            raise ArgumentError(action, "not allowed with argument " + _action_name(other))
        if not (isinstance(values, "str") and values == SUPPRESS):
            action(self, st.ns, values, option_string)

    def _get_values(self, action, strings):
        var n = action.nargs
        if len(strings) == 0 and n == OPTIONAL:
            var v = action.const if action.is_optional() else action.default
            if isinstance(v, "str"):
                v = self._get_value(action, v)
                self._check_value(action, v)
            return v
        if len(strings) == 0 and n == ZERO_OR_MORE and not action.is_optional():
            var v2 = action.default if action.default != none else []
            if not isinstance(v2, "list"):
                self._check_value(action, v2)
            return v2
        if len(strings) == 1 and (n == none or n == OPTIONAL):
            var v3 = self._get_value(action, strings[0])
            self._check_value(action, v3)
            return v3
        if n == REMAINDER:
            return [self._get_value(action, s) for s in strings]
        if n == PARSER:
            var v4 = [self._get_value(action, s) for s in strings]
            self._check_value(action, v4[0])
            return v4
        if n == SUPPRESS:
            return SUPPRESS
        var v5 = [self._get_value(action, s) for s in strings]
        for x in v5:
            self._check_value(action, x)
        return v5

    def _get_value(self, action, s):
        var f = action.type
        if f == none:
            return s
        if not callable(f):
            raise ArgumentError(action, repr(f) + " is not callable")
        try:
            return f(s)
        except ArgumentTypeError as err:
            raise ArgumentError(action, str(err))
        except (TypeError, ValueError):
            var name = getattr(f, "__name__", repr(f))
            raise ArgumentError(action, "invalid " + str(name) + " value: " + repr(s))

    def _check_value(self, action, value):
        if action.choices != none and not (value in action.choices):
            var msg = "invalid choice: " + repr(value)
            if self.suggest_on_error and isinstance(value, "str"):
                var names = [c for c in action.choices if isinstance(c, "str")]
                var near = _close_match(value, names)
                if near != none:
                    msg = msg + ", maybe you meant " + repr(near) + "?"
            raise ArgumentError(action, msg + " (choose from " + ", ".join([repr(c) for c in action.choices]) + ")")

    # ── help ──
    def _get_formatter(self):
        var cls = self.formatter_class
        return cls(self.prog)

    def format_usage(self):
        var f = self._get_formatter()
        f.add_usage(self.usage, self._actions, self._mutually_exclusive_groups)
        return f.format_help()

    def format_help(self):
        var f = self._get_formatter()
        f.add_usage(self.usage, self._actions, self._mutually_exclusive_groups)
        f.add_text(self.description)
        for g in self._action_groups:
            f.start_section(g.title)
            f.add_text(g.description)
            f.add_arguments(g._group_actions)
            f.end_section()
        f.add_text(self.epilog)
        return f.format_help()

    def print_usage(self, file=none):
        self._print_message(self.format_usage(), file if file != none else sys.stdout)

    def print_help(self, file=none):
        self._print_message(self.format_help(), file if file != none else sys.stdout)

    def _print_message(self, message, file=none):
        if message != none and message != "":
            if file == none:
                file = sys.stderr
            file.write(message)

    def exit(self, status=0, message=none):
        if message != none:
            self._print_message(message, sys.stderr)
        sys.exit(status)

    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, self.prog + ": error: " + message + "\n")
