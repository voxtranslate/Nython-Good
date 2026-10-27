# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/tcl.ny - the Tcl layer under Nython's Tk (round 84).
#
# Tk is driven by Tcl commands; CPython's tkinter turns every method call
# into one (`self.tk.call(self._w, "configure", "-text", "hi")`) and every
# binding into a Tcl script.  This module is the part of Tcl that tkinter
# needs:
#
#   TclError                 the error every Tcl/Tk failure raises
#   tcl_str(v)               a Python value as Tcl sees it (lists as Tcl lists,
#                            True as 1, floats as Tcl prints them)
#   split_list(s)            Tcl list syntax -> list of str (braces, quotes,
#                            backslashes; "unmatched open brace in list")
#   join_list(items)         Tcl_Merge: a list -> a string that splits back
#   quote_elem(s)            one list element, quoted as Tcl_ConvertElement
#   get_int/get_double/get_boolean   Tcl_GetInt/GetDouble/GetBoolean, with
#                            Tcl's messages ('expected integer but got "x"')
#   Interp                   a small Tcl interpreter: words, braces, quotes,
#                            $var / ${var} / [command] / backslash
#                            substitution, comments; set unset incr append
#                            lappend list llength lindex lrange concat join
#                            split string expr if while for foreach break
#                            continue return catch error eval puts info
#                            proc global uplevel subst format rename; other
#                            names go to the Tk commands and the commands
#                            created with createcommand.
#   expr                     integers, floats, strings, $var, [cmd],
#                            unary - + ! ~, * / % + - << >> < > <= >= == !=
#                            eq ne in ni & ^ | && || ?: and abs int double
#                            round floor ceil sqrt min max
#
# Not provided: namespaces (other than ::name), arrays beyond name(index)
# variables, upvar, Tcl's full regexp syntax (re's is used), [clock], [file],
# channels, the bytecode compiler.  `proc` bodies run in a fresh frame
# whose variables are local; `global` links names to the global frame.

class TclError(Exception):
    pass


class _Break(Exception):
    pass


class _Continue(Exception):
    pass


class _Return(Exception):
    def __init__(self, value):
        Exception.__init__(self, "return")
        self.value = value


_SPECIAL = " \t\n\r\v\f{}[]$;\"\\"


def tcl_float(v):
    # Tcl 8.6 prints a double as the shortest string that reads back to it,
    # with ".0" for an integral value - which is repr() on CPython.
    if v != v:
        return "NaN"
    if v == float("inf"):
        return "Inf"
    if v == float("-inf"):
        return "-Inf"
    r = repr(v)
    return r


def tcl_str(v):
    # The string representation Tcl gives a value tkinter passed it.
    if isinstance(v, str):
        return v
    if v is True:
        return "1"
    if v is False:
        return "0"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return tcl_float(v)
    if v is None:
        return ""
    if isinstance(v, (tuple, list)):
        return join_list(v)
    s = getattr(v, "_tcl_string", None)
    if s is not None:
        return s()
    return str(v)


def quote_elem(s):
    # Tcl_ScanElement / Tcl_ConvertElement: bare when nothing in it is
    # special, braced when braces balance, backslashed otherwise.
    if s == "":
        return "{}"
    need = False
    if s[0] == "#" or s[0] == "{" or s[0] == "\"":
        need = True
    else:
        for c in s:
            if c in _SPECIAL:
                need = True
                break
    if not need:
        return s
    depth = 0
    ok = True
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            if i + 1 >= n:
                ok = False
                break
            i += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth < 0:
                ok = False
                break
        i += 1
    if ok and depth == 0 and s[-1] != "\\":
        return "{" + s + "}"
    out = []
    for c in s:
        if c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif c in _SPECIAL:
            out.append("\\" + c)
        else:
            out.append(c)
    return "".join(out)


def join_list(items):
    return " ".join([quote_elem(tcl_str(x)) for x in items])


_BS = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}


def _backslash(s, i):
    # s[i] is a backslash: (replacement, next index)
    n = len(s)
    if i + 1 >= n:
        return "\\", i + 1
    c = s[i + 1]
    if c in _BS:
        return _BS[c], i + 2
    if c == "\n":
        j = i + 2
        while j < n and s[j] in " \t":
            j += 1
        return " ", j
    if c == "x":
        j = i + 2
        h = ""
        while j < n and len(h) < 2 and s[j] in "0123456789abcdefABCDEF":
            h += s[j]
            j += 1
        if h == "":
            return "x", i + 2
        return chr(int(h, 16)), j
    if c == "u":
        j = i + 2
        h = ""
        while j < n and len(h) < 4 and s[j] in "0123456789abcdefABCDEF":
            h += s[j]
            j += 1
        if h == "":
            return "u", i + 2
        return chr(int(h, 16)), j
    if c in "01234567":
        j = i + 1
        o = ""
        while j < n and len(o) < 3 and s[j] in "01234567":
            o += s[j]
            j += 1
        return chr(int(o, 8) & 0xFF), j
    return c, i + 2


def split_list(s):
    # TclFindElement over the whole string.
    if isinstance(s, (tuple, list)):
        return [tcl_str(x) for x in s]
    if not isinstance(s, str):
        s = tcl_str(s)
    out = []
    i = 0
    n = len(s)
    while True:
        while i < n and s[i] in " \t\n\r\v\f":
            i += 1
        if i >= n:
            break
        c = s[i]
        if c == "{":
            depth = 1
            j = i + 1
            while j < n:
                d = s[j]
                if d == "\\":
                    j += 2
                    continue
                if d == "{":
                    depth += 1
                elif d == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= n:
                raise TclError("unmatched open brace in list")
            out.append(s[i + 1:j])
            i = j + 1
            if i < n and s[i] not in " \t\n\r\v\f":
                raise TclError("list element in braces followed by \"" + _word_at(s, i) + "\" instead of space")
        elif c == "\"":
            j = i + 1
            buf = []
            while j < n and s[j] != "\"":
                if s[j] == "\\":
                    r, j = _backslash(s, j)
                    buf.append(r)
                else:
                    buf.append(s[j])
                    j += 1
            if j >= n:
                raise TclError("unmatched open quote in list")
            out.append("".join(buf))
            i = j + 1
            if i < n and s[i] not in " \t\n\r\v\f":
                raise TclError("list element in quotes followed by \"" + _word_at(s, i) + "\" instead of space")
        else:
            buf = []
            j = i
            while j < n and s[j] not in " \t\n\r\v\f":
                if s[j] == "\\":
                    r, j = _backslash(s, j)
                    buf.append(r)
                else:
                    buf.append(s[j])
                    j += 1
            out.append("".join(buf))
            i = j
    return out


def _word_at(s, i):
    j = i
    while j < len(s) and s[j] not in " \t\n":
        j += 1
    return s[i:j]


def get_int(v):
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        raise TclError("expected integer but got \"" + tcl_float(v) + "\"")
    s = tcl_str(v).strip()
    t = s
    neg = False
    if t[:1] in ("-", "+"):
        neg = t[0] == "-"
        t = t[1:]
    try:
        if t[:2] in ("0x", "0X"):
            r = int(t[2:], 16)
        elif t[:2] in ("0o", "0O"):
            r = int(t[2:], 8)
        elif t[:2] in ("0b", "0B"):
            r = int(t[2:], 2)
        elif t != "" and t.isdigit():
            r = int(t, 10)
        else:
            raise ValueError(t)
    except ValueError:
        raise TclError("expected integer but got \"" + tcl_str(v) + "\"")
    return -r if neg else r


def get_double(v):
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    s = tcl_str(v).strip()
    try:
        if s[:2] in ("0x", "0X") or s[:3] in ("-0x", "+0x"):
            return float(get_int(s))
        return float(s)
    except (ValueError, TclError):
        raise TclError("expected floating-point number but got \"" + tcl_str(v) + "\"")


_TRUE = ("1", "true", "yes", "on")
_FALSE = ("0", "false", "no", "off")


def get_boolean(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, int):
        return v != 0
    if isinstance(v, float):
        return v != 0.0
    s = tcl_str(v).strip().lower()
    if s != "":
        for t in _TRUE:
            if t.startswith(s) and not (s == "o"):
                return True
        for t in _FALSE:
            if t.startswith(s) and not (s == "o"):
                return False
        try:
            return float(s) != 0.0
        except ValueError:
            pass
    raise TclError("expected boolean value but got \"" + tcl_str(v) + "\"")


def match_prefix(word, choices, what="option"):
    # Tcl_GetIndexFromObj: an exact name or a unique abbreviation.
    if word in choices:
        return word
    found = []
    for c in choices:
        if c.startswith(word):
            found.append(c)
    if len(found) == 1 and word != "":
        return found[0]
    kind = "ambiguous " if len(found) > 1 else "bad "
    raise TclError(kind + what + " \"" + word + "\": must be " + _or_list(sorted(choices) if what == "option" else choices))


def _or_list(choices):
    choices = list(choices)
    if len(choices) == 1:
        return choices[0]
    if len(choices) == 2:
        return choices[0] + " or " + choices[1]
    return ", ".join(choices[:-1]) + ", or " + choices[-1]


def or_list(choices):
    return _or_list(choices)


# ── The interpreter ─────────────────────────────────────────────────────────

class _Frame:
    def __init__(self, parent):
        self.vars = {}
        self.parent = parent
        self.links = {}


class Proc:
    def __init__(self, name, params, body):
        self.name = name
        self.params = params
        self.body = body


class Interp:
    # A Tcl interpreter: the global variables, procedures, and the command
    # table (`commands`: name -> callable(interp, args) returning a value).
    def __init__(self):
        self.globals = _Frame(None)
        self.frame = self.globals
        self.commands = {}
        self.procs = {}
        self.var_hook = None       # (interp, name, op, value) for traces
        self.result = ""
        self.depth = 0

    # ── variables ──
    def _resolve(self, name):
        f = self.frame
        if name.startswith("::"):
            name = name[2:]
            f = self.globals
        elif name in f.links:
            f = self.globals
        return f, name

    def getvar(self, name):
        f, name = self._resolve(name)
        if self.var_hook is not None and f is self.globals:
            return self.var_hook(name, "read", None)
        if name not in f.vars:
            raise TclError("can't read \"" + name + "\": no such variable")
        return f.vars[name]

    def setvar(self, name, value):
        f, name = self._resolve(name)
        if self.var_hook is not None and f is self.globals:
            return self.var_hook(name, "write", value)
        f.vars[name] = value
        return value

    def unsetvar(self, name, nocomplain=False):
        f, name = self._resolve(name)
        if self.var_hook is not None and f is self.globals:
            return self.var_hook(name, "unset", nocomplain)
        if name not in f.vars:
            if nocomplain:
                return ""
            raise TclError("can't unset \"" + name + "\": no such variable")
        del f.vars[name]
        return ""

    def var_exists(self, name):
        f, name = self._resolve(name)
        if self.var_hook is not None and f is self.globals:
            return self.var_hook(name, "exists", None)
        return name in f.vars

    # ── evaluation ──
    def eval(self, script):
        if not isinstance(script, str):
            script = tcl_str(script)
        cmds = _PARSE_CACHE.get(script)
        if cmds is None:
            cmds = self.parse(script)
            if len(_PARSE_CACHE) > 2000:
                _PARSE_CACHE.clear()
            _PARSE_CACHE[script] = cmds
        self.depth += 1
        if self.depth > 1000:
            self.depth -= 1
            raise TclError("too many nested evaluations (infinite loop?)")
        try:
            result = ""
            for cmd in cmds:
                words = []
                for kind, text in cmd:
                    if kind == 0:
                        words.append(text)
                    elif kind == 1:
                        words.append(self.subst(text))
                    else:
                        words.extend(split_list(self.subst(text) if kind == 3 else text))
                if words:
                    result = self.invoke(words)
            return result
        finally:
            self.depth -= 1

    def invoke(self, words):
        name = tcl_str(words[0])
        cmd = self.commands.get(name)
        if cmd is not None:
            return cmd(self, words)
        # "::a::b" and "a::b" name the same command (the global namespace)
        if name.startswith("::"):
            name = name[2:]
            cmd = self.commands.get(name)
        else:
            cmd = self.commands.get("::" + name)
        if cmd is not None:
            return cmd(self, words)
        p = self.procs.get(name)
        if p is not None:
            return self.call_proc(p, words[1:])
        builtin = _BUILTINS.get(name)
        if builtin is not None:
            return builtin(self, words)
        unknown = self.commands.get("unknown")
        if unknown is not None:
            return unknown(self, ["unknown"] + list(words))
        raise TclError("invalid command name \"" + name + "\"")

    def call_proc(self, p, args):
        f = _Frame(self.frame)
        params = p.params
        i = 0
        for k in range(len(params)):
            pn = params[k]
            if pn[0] == "args" and k == len(params) - 1:
                f.vars["args"] = join_list(args[i:])
                i = len(args)
                break
            if i < len(args):
                f.vars[pn[0]] = args[i]
                i += 1
            elif len(pn) > 1:
                f.vars[pn[0]] = pn[1]
            else:
                raise TclError("wrong # args: should be \"" + p.name + " " + " ".join([q[0] for q in params]) + "\"")
        if i < len(args):
            raise TclError("wrong # args: should be \"" + p.name + " " + " ".join([q[0] for q in params]) + "\"")
        saved = self.frame
        self.frame = f
        try:
            return self.eval(p.body)
        except _Return as r:
            return r.value
        finally:
            self.frame = saved

    # ── parsing ──
    def parse(self, script):
        # The script as a list of commands, each a list of (kind, text)
        # word templates: 0 literal (braced, or nothing to substitute),
        # 1 to substitute when the command runs (so a command sees what the
        # previous one set, as in Tcl), 2/3 the same with {*} expansion.
        cmds = []
        i = 0
        n = len(script)
        while i < n:
            # skip whitespace and command separators
            while i < n and script[i] in " \t\r\n;\v\f":
                i += 1
            if i >= n:
                break
            if script[i] == "#":
                while i < n and script[i] != "\n":
                    if script[i] == "\\" and i + 1 < n:
                        i += 2
                        continue
                    i += 1
                continue
            words = []
            while i < n:
                while i < n and script[i] in " \t\v\f\r":
                    i += 1
                if i < n and script[i] == "\\" and i + 1 < n and script[i + 1] == "\n":
                    i += 2
                    continue
                if i >= n or script[i] in "\n;":
                    break
                expand = False
                if script.startswith("{*}", i) and i + 3 < n and script[i + 3] not in " \t\n;":
                    expand = True
                    i += 3
                kind, text, i = self._word_template(script, i)
                if expand:
                    kind = 2 if kind == 0 else 3
                words.append((kind, text))
            if words:
                cmds.append(words)
        return cmds

    def _word_template(self, s, i):
        n = len(s)
        c = s[i]
        if c == "{":
            w, j = self._word(s, i)
            return 0, w, j
        if c == "\"":
            j = i + 1
            while j < n and s[j] != "\"":
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == "[":
                    j = _matching_bracket(s, j) + 1
                    continue
                j += 1
            if j >= n:
                raise TclError("missing \"")
            body = s[i + 1:j]
            j += 1
            if j < n and s[j] not in " \t\n;\r":
                raise TclError("extra characters after close-quote")
            return (1 if _needs_subst(body) else 0), body, j
        j = i
        while j < n and s[j] not in " \t\n;\r":
            if s[j] == "\\":
                j += 2
                continue
            if s[j] == "[":
                j = _matching_bracket(s, j) + 1
                continue
            j += 1
        if j > n:
            j = n
        body = s[i:j]
        return (1 if _needs_subst(body) else 0), body, j

    def _word(self, s, i):
        n = len(s)
        c = s[i]
        if c == "{":
            depth = 1
            j = i + 1
            while j < n:
                d = s[j]
                if d == "\\":
                    j += 2
                    continue
                if d == "{":
                    depth += 1
                elif d == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= n:
                raise TclError("missing close-brace")
            body = s[i + 1:j]
            if "\\\n" in body:
                body = _fold_bs_newlines(body)
            j += 1
            if j < n and s[j] not in " \t\n;\r":
                raise TclError("extra characters after close-brace")
            return body, j
        if c == "\"":
            j = i + 1
            parts = []
            while j < n and s[j] != "\"":
                j = self._subst_one(s, j, parts)
            if j >= n:
                raise TclError("missing \"")
            j += 1
            if j < n and s[j] not in " \t\n;\r":
                raise TclError("extra characters after close-quote")
            return _join_parts(parts), j
        parts = []
        j = i
        while j < n and s[j] not in " \t\n;\r":
            j = self._subst_one(s, j, parts)
        return _join_parts(parts), j

    def _subst_one(self, s, j, parts):
        c = s[j]
        if c == "\\":
            r, j = _backslash(s, j)
            parts.append(r)
            return j
        if c == "$":
            v, k = self._var_ref(s, j)
            if k == j + 1 and v is None:
                parts.append("$")
                return k
            parts.append(v)
            return k
        if c == "[":
            k = _matching_bracket(s, j)
            parts.append(self.eval(s[j + 1:k]))
            return k + 1
        parts.append(c)
        return j + 1

    def _var_ref(self, s, j):
        n = len(s)
        k = j + 1
        if k < n and s[k] == "{":
            e = s.find("}", k)
            if e < 0:
                raise TclError("missing close-brace for variable name")
            return self.getvar(s[k + 1:e]), e + 1
        st = k
        while k < n and (s[k].isalnum() or s[k] == "_" or (s[k] == ":" and k + 1 < n and s[k + 1] == ":")):
            k += 2 if s[k] == ":" else 1
        if k == st:
            return None, j + 1
        name = s[st:k]
        if k < n and s[k] == "(":
            e = s.find(")", k)
            if e < 0:
                raise TclError("missing )")
            idx = self.subst(s[k + 1:e])
            return self.getvar(name + "(" + idx + ")"), e + 1
        return self.getvar(name), k

    def subst(self, s, backslashes=True, variables=True, commands=True):
        parts = []
        j = 0
        n = len(s)
        while j < n:
            c = s[j]
            if (c == "\\" and backslashes) or (c == "$" and variables) or (c == "[" and commands):
                j = self._subst_one(s, j, parts)
            else:
                parts.append(c)
                j += 1
        return _join_parts(parts)


_PARSE_CACHE = {}


def _needs_subst(body):
    return ("$" in body) or ("[" in body) or ("\\" in body)


def _fold_bs_newlines(body):
    out = []
    i = 0
    n = len(body)
    while i < n:
        if body[i] == "\\" and i + 1 < n and body[i + 1] == "\n":
            i += 2
            while i < n and body[i] in " \t":
                i += 1
            out.append(" ")
            continue
        out.append(body[i])
        i += 1
    return "".join(out)


def _join_parts(parts):
    if len(parts) == 1:
        return parts[0]
    return "".join([p if isinstance(p, str) else tcl_str(p) for p in parts])


def _matching_bracket(s, j):
    depth = 0
    k = j
    n = len(s)
    in_brace = 0
    while k < n:
        c = s[k]
        if c == "\\":
            k += 2
            continue
        if c == "{":
            in_brace += 1
        elif c == "}" and in_brace > 0:
            in_brace -= 1
        elif in_brace == 0:
            if c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
                if depth == 0:
                    return k
        k += 1
    raise TclError("missing close-bracket")


# ── expr ────────────────────────────────────────────────────────────────────

class _ExprParser:
    def __init__(self, interp, s):
        self.interp = interp
        self.s = s
        self.i = 0
        self.toks = self._tokenize(s)
        self.k = 0

    def _tokenize(self, s):
        toks = []
        i = 0
        n = len(s)
        ops = ["<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "**",
               "+", "-", "*", "/", "%", "<", ">", "!", "~", "&", "^", "|", "?", ":", "(", ")", ","]
        while i < n:
            c = s[i]
            if c in " \t\n\r":
                i += 1
                continue
            if c.isdigit() or (c == "." and i + 1 < n and s[i + 1].isdigit()):
                j = i
                if s.startswith("0x", i) or s.startswith("0X", i):
                    j = i + 2
                    while j < n and s[j] in "0123456789abcdefABCDEF":
                        j += 1
                    toks.append(("num", int(s[i + 2:j], 16)))
                    i = j
                    continue
                while j < n and (s[j].isdigit() or s[j] == "."):
                    j += 1
                if j < n and s[j] in "eE":
                    j += 1
                    if j < n and s[j] in "+-":
                        j += 1
                    while j < n and s[j].isdigit():
                        j += 1
                txt = s[i:j]
                toks.append(("num", float(txt) if ("." in txt or "e" in txt or "E" in txt) else int(txt)))
                i = j
                continue
            if c == "$":
                v, j = self.interp._var_ref(s, i)
                toks.append(("val", v))
                i = j
                continue
            if c == "[":
                k = _matching_bracket(s, i)
                toks.append(("val", self.interp.eval(s[i + 1:k])))
                i = k + 1
                continue
            if c == "\"":
                w, j = self.interp._word(s, i)
                toks.append(("str", w))
                i = j
                continue
            if c == "{":
                w, j = self.interp._word(s, i)
                toks.append(("str", w))
                i = j
                continue
            if c.isalpha() or c == "_":
                j = i
                while j < n and (s[j].isalnum() or s[j] == "_"):
                    j += 1
                word = s[i:j]
                if word in ("eq", "ne", "in", "ni"):
                    toks.append(("op", word))
                elif word in ("true", "false", "yes", "no", "on", "off"):
                    toks.append(("str", word))
                else:
                    toks.append(("fn", word))
                i = j
                continue
            matched = False
            for op in ops:
                if s.startswith(op, i):
                    toks.append(("op", op))
                    i += len(op)
                    matched = True
                    break
            if not matched:
                raise TclError("invalid character \"" + c + "\" in expression \"" + s + "\"")
        toks.append(("end", None))
        return toks

    def peek(self):
        return self.toks[self.k]

    def take(self):
        t = self.toks[self.k]
        self.k += 1
        return t

    def is_op(self, *names):
        t = self.toks[self.k]
        return t[0] == "op" and t[1] in names

    def parse(self):
        v = self.ternary()
        if self.peek()[0] != "end":
            raise TclError("syntax error in expression \"" + self.s + "\"")
        return v

    def ternary(self):
        c = self.lor()
        if self.is_op("?"):
            self.take()
            a = self.ternary()
            if not self.is_op(":"):
                raise TclError("missing \":\" in ternary expression")
            self.take()
            b = self.ternary()
            return a if _truth(c) else b
        return c

    def lor(self):
        v = self.land()
        while self.is_op("||"):
            self.take()
            w = self.land()
            v = 1 if (_truth(v) or _truth(w)) else 0
        return v

    def land(self):
        v = self.bor()
        while self.is_op("&&"):
            self.take()
            w = self.bor()
            v = 1 if (_truth(v) and _truth(w)) else 0
        return v

    def bor(self):
        v = self.bxor()
        while self.is_op("|"):
            self.take()
            v = _num(v) | _num(self.bxor())
        return v

    def bxor(self):
        v = self.band()
        while self.is_op("^"):
            self.take()
            v = _num(v) ^ _num(self.band())
        return v

    def band(self):
        v = self.equality()
        while self.is_op("&"):
            self.take()
            v = _num(v) & _num(self.equality())
        return v

    def equality(self):
        v = self.relational()
        while self.is_op("==", "!=", "eq", "ne", "in", "ni"):
            op = self.take()[1]
            w = self.relational()
            if op == "eq":
                v = 1 if tcl_str(v) == tcl_str(w) else 0
            elif op == "ne":
                v = 1 if tcl_str(v) != tcl_str(w) else 0
            elif op == "in":
                v = 1 if tcl_str(v) in split_list(w) else 0
            elif op == "ni":
                v = 0 if tcl_str(v) in split_list(w) else 1
            else:
                eq = _compare(v, w) == 0
                v = 1 if (eq if op == "==" else not eq) else 0
        return v

    def relational(self):
        v = self.shift()
        while self.is_op("<", ">", "<=", ">="):
            op = self.take()[1]
            w = self.shift()
            c = _compare(v, w)
            if op == "<":
                v = 1 if c < 0 else 0
            elif op == ">":
                v = 1 if c > 0 else 0
            elif op == "<=":
                v = 1 if c <= 0 else 0
            else:
                v = 1 if c >= 0 else 0
        return v

    def shift(self):
        v = self.additive()
        while self.is_op("<<", ">>"):
            op = self.take()[1]
            w = _num(self.additive())
            v = (_num(v) << w) if op == "<<" else (_num(v) >> w)
        return v

    def additive(self):
        v = self.mult()
        while self.is_op("+", "-"):
            op = self.take()[1]
            w = self.mult()
            v = _num(v) + _num(w) if op == "+" else _num(v) - _num(w)
        return v

    def mult(self):
        v = self.power()
        while self.is_op("*", "/", "%"):
            op = self.take()[1]
            w = _num(self.power())
            a = _num(v)
            if op == "*":
                v = a * w
            elif op == "/":
                if w == 0:
                    raise TclError("divide by zero")
                if isinstance(a, int) and isinstance(w, int):
                    v = a // w
                else:
                    v = a / w
            else:
                if w == 0:
                    raise TclError("divide by zero")
                v = a % w
        return v

    def power(self):
        v = self.unary()
        if self.is_op("**"):
            self.take()
            w = self.power()
            return _num(v) ** _num(w)
        return v

    def unary(self):
        if self.is_op("-"):
            self.take()
            return -_num(self.unary())
        if self.is_op("+"):
            self.take()
            return _num(self.unary())
        if self.is_op("!"):
            self.take()
            return 0 if _truth(self.unary()) else 1
        if self.is_op("~"):
            self.take()
            return ~_num(self.unary())
        return self.primary()

    def primary(self):
        t = self.take()
        kind = t[0]
        if kind == "num":
            return t[1]
        if kind == "val" or kind == "str":
            return _maybe_num(t[1])
        if kind == "op" and t[1] == "(":
            v = self.ternary()
            if not self.is_op(")"):
                raise TclError("unbalanced parentheses in expression \"" + self.s + "\"")
            self.take()
            return v
        if kind == "fn":
            name = t[1]
            if not self.is_op("("):
                raise TclError("invalid bareword \"" + name + "\"")
            self.take()
            args = []
            if not self.is_op(")"):
                args.append(self.ternary())
                while self.is_op(","):
                    self.take()
                    args.append(self.ternary())
            if not self.is_op(")"):
                raise TclError("missing close parenthesis")
            self.take()
            return _expr_func(name, args)
        raise TclError("syntax error in expression \"" + self.s + "\"")


def _maybe_num(v):
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return v
    s = tcl_str(v).strip()
    try:
        return get_int(s)
    except TclError:
        pass
    try:
        return float(s)
    except ValueError:
        return tcl_str(v)


def _num(v):
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, (int, float)):
        return v
    m = _maybe_num(v)
    if isinstance(m, str):
        low = m.lower()
        if low in _TRUE:
            return 1
        if low in _FALSE:
            return 0
        raise TclError("can't use non-numeric string \"" + m + "\" as operand of an arithmetic operator")
    return m


def _truth(v):
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return v != 0
    return get_boolean(v)


def _compare(a, b):
    na = _maybe_num(a)
    nb = _maybe_num(b)
    if not isinstance(na, str) and not isinstance(nb, str):
        return -1 if na < nb else (1 if na > nb else 0)
    sa = tcl_str(a)
    sb = tcl_str(b)
    return -1 if sa < sb else (1 if sa > sb else 0)


def _expr_func(name, args):
    import math
    if name == "abs":
        return abs(_num(args[0]))
    if name == "int" or name == "wide" or name == "entier":
        return int(_num(args[0]))
    if name == "double":
        return float(_num(args[0]))
    if name == "round":
        x = _num(args[0])
        return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))
    if name == "floor":
        return float(math.floor(_num(args[0])))
    if name == "ceil":
        return float(math.ceil(_num(args[0])))
    if name == "sqrt":
        return math.sqrt(_num(args[0]))
    if name == "min":
        return min([_num(a) for a in args])
    if name == "max":
        return max([_num(a) for a in args])
    if name == "sin":
        return math.sin(_num(args[0]))
    if name == "cos":
        return math.cos(_num(args[0]))
    if name == "pow":
        return float(_num(args[0])) ** _num(args[1])
    if name == "bool":
        return 1 if _truth(args[0]) else 0
    raise TclError("invalid command name \"tcl::mathfunc::" + name + "\"")


def expr(interp, s):
    v = _ExprParser(interp, tcl_str(s)).parse()
    if isinstance(v, bool):
        return 1 if v else 0
    return v


# ── built-in commands ───────────────────────────────────────────────────────

def _wrong(usage):
    raise TclError("wrong # args: should be \"" + usage + "\"")


def _c_set(it, w):
    if len(w) == 2:
        return it.getvar(tcl_str(w[1]))
    if len(w) == 3:
        return it.setvar(tcl_str(w[1]), w[2])
    _wrong("set varName ?newValue?")


def _c_unset(it, w):
    args = list(w[1:])
    nocomplain = False
    if args and args[0] == "-nocomplain":
        nocomplain = True
        args = args[1:]
    if args and args[0] == "--":
        args = args[1:]
    for a in args:
        it.unsetvar(tcl_str(a), nocomplain)
    return ""


def _c_incr(it, w):
    if len(w) < 2 or len(w) > 3:
        _wrong("incr varName ?increment?")
    name = tcl_str(w[1])
    by = get_int(w[2]) if len(w) == 3 else 1
    cur = get_int(it.getvar(name)) if it.var_exists(name) else 0
    return it.setvar(name, cur + by)


def _c_append(it, w):
    if len(w) < 2:
        _wrong("append varName ?value ...?")
    name = tcl_str(w[1])
    cur = tcl_str(it.getvar(name)) if it.var_exists(name) else ""
    for v in w[2:]:
        cur += tcl_str(v)
    return it.setvar(name, cur)


def _c_lappend(it, w):
    if len(w) < 2:
        _wrong("lappend varName ?value ...?")
    name = tcl_str(w[1])
    cur = split_list(it.getvar(name)) if it.var_exists(name) else []
    for v in w[2:]:
        cur.append(tcl_str(v))
    return it.setvar(name, join_list(cur))


def _c_list(it, w):
    return join_list(w[1:])


def _c_llength(it, w):
    if len(w) != 2:
        _wrong("llength list")
    return len(split_list(w[1]))


def _index_arg(s, n):
    s = tcl_str(s)
    if s == "end":
        return n - 1
    if s.startswith("end-"):
        return n - 1 - get_int(s[4:])
    if s.startswith("end+"):
        return n - 1 + get_int(s[4:])
    if "+" in s[1:]:
        a, b = s.split("+", 1)
        return get_int(a) + get_int(b)
    if "-" in s[1:]:
        a, b = s.rsplit("-", 1)
        return get_int(a) - get_int(b)
    return get_int(s)


def _c_lindex(it, w):
    if len(w) < 2:
        _wrong("lindex list ?index ...?")
    v = w[1]
    for ix in w[2:]:
        items = split_list(v)
        k = _index_arg(ix, len(items))
        if k < 0 or k >= len(items):
            return ""
        v = items[k]
    return v


def _c_lrange(it, w):
    if len(w) != 4:
        _wrong("lrange list first last")
    items = split_list(w[1])
    a = max(0, _index_arg(w[2], len(items)))
    b = _index_arg(w[3], len(items))
    return join_list(items[a:b + 1])


def _c_concat(it, w):
    parts = []
    for v in w[1:]:
        s = tcl_str(v).strip()
        if s != "":
            parts.append(s)
    return " ".join(parts)


def _c_join(it, w):
    if len(w) < 2 or len(w) > 3:
        _wrong("join list ?joinString?")
    sep = tcl_str(w[2]) if len(w) == 3 else " "
    return sep.join(split_list(w[1]))


def _c_split(it, w):
    if len(w) < 2 or len(w) > 3:
        _wrong("split string ?splitChars?")
    s = tcl_str(w[1])
    chars = tcl_str(w[2]) if len(w) == 3 else " \t\n\r"
    if chars == "":
        return join_list(list(s))
    out = []
    cur = ""
    for c in s:
        if c in chars:
            out.append(cur)
            cur = ""
        else:
            cur += c
    out.append(cur)
    return join_list(out)


def _c_string(it, w):
    if len(w) < 2:
        _wrong("string subcommand ?arg ...?")
    sub = match_prefix(tcl_str(w[1]), ["compare", "equal", "first", "index", "is", "last", "length",
                                       "map", "match", "range", "repeat", "replace", "reverse",
                                       "tolower", "totitle", "toupper", "trim", "trimleft", "trimright"],
                       "option")
    a = [tcl_str(x) for x in w[2:]]
    if sub == "length":
        return len(a[0])
    if sub == "equal":
        nocase = "-nocase" in a
        a = [x for x in a if x not in ("-nocase",)]
        if nocase:
            return 1 if a[-2].lower() == a[-1].lower() else 0
        return 1 if a[-2] == a[-1] else 0
    if sub == "compare":
        x, y = a[-2], a[-1]
        return -1 if x < y else (1 if x > y else 0)
    if sub == "tolower":
        return a[0].lower()
    if sub == "toupper":
        return a[0].upper()
    if sub == "totitle":
        return a[0][:1].upper() + a[0][1:].lower()
    if sub == "trim":
        return a[0].strip(a[1]) if len(a) > 1 else a[0].strip()
    if sub == "trimleft":
        return a[0].lstrip(a[1]) if len(a) > 1 else a[0].lstrip()
    if sub == "trimright":
        return a[0].rstrip(a[1]) if len(a) > 1 else a[0].rstrip()
    if sub == "index":
        k = _index_arg(a[1], len(a[0]))
        return a[0][k] if 0 <= k < len(a[0]) else ""
    if sub == "range":
        s = a[0]
        i0 = max(0, _index_arg(a[1], len(s)))
        i1 = _index_arg(a[2], len(s))
        return s[i0:i1 + 1]
    if sub == "first":
        return a[1].find(a[0])
    if sub == "last":
        return a[1].rfind(a[0])
    if sub == "repeat":
        return a[0] * get_int(a[1])
    if sub == "reverse":
        return a[0][::-1]
    if sub == "match":
        import fnmatch
        nocase = "-nocase" in a
        a = [x for x in a if x != "-nocase"]
        pat, s = a[-2], a[-1]
        if nocase:
            pat, s = pat.lower(), s.lower()
        return 1 if fnmatch.fnmatchcase(s, pat) else 0
    if sub == "map":
        m = split_list(a[-2])
        s = a[-1]
        out = ""
        i = 0
        while i < len(s):
            done = False
            for k in range(0, len(m) - 1, 2):
                if m[k] != "" and s.startswith(m[k], i):
                    out += m[k + 1]
                    i += len(m[k])
                    done = True
                    break
            if not done:
                out += s[i]
                i += 1
        return out
    if sub == "replace":
        s = a[0]
        i0 = max(0, _index_arg(a[1], len(s)))
        i1 = _index_arg(a[2], len(s))
        return s[:i0] + (a[3] if len(a) > 3 else "") + s[i1 + 1:]
    if sub == "is":
        cls = a[0]
        rest = [x for x in a[1:] if x != "-strict"]
        s = rest[-1] if rest else ""
        if cls == "integer" or cls == "entier" or cls == "wide":
            try:
                get_int(s)
                return 1
            except TclError:
                return 1 if (s == "" and "-strict" not in a) else 0
        if cls == "double":
            try:
                get_double(s)
                return 1
            except TclError:
                return 1 if (s == "" and "-strict" not in a) else 0
        if cls == "boolean":
            try:
                get_boolean(s)
                return 1
            except TclError:
                return 1 if (s == "" and "-strict" not in a) else 0
        if cls == "digit":
            return 1 if (s.isdigit() or s == "") else 0
        if cls == "alpha":
            return 1 if (s.isalpha() or s == "") else 0
        if cls == "alnum":
            return 1 if (s.isalnum() or s == "") else 0
        if cls == "space":
            return 1 if (s.isspace() or s == "") else 0
        if cls == "upper":
            return 1 if (s.isupper() or s == "") else 0
        if cls == "lower":
            return 1 if (s.islower() or s == "") else 0
        raise TclError("bad class \"" + cls + "\"")
    raise TclError("string " + sub + " is not supported by Nython's Tcl")


def _c_expr(it, w):
    if len(w) < 2:
        _wrong("expr arg ?arg ...?")
    return expr(it, " ".join([tcl_str(x) for x in w[1:]]))


def _c_if(it, w):
    i = 1
    n = len(w)
    while i < n:
        cond = w[i]
        i += 1
        if i < n and w[i] == "then":
            i += 1
        if i >= n:
            raise TclError("wrong # args: no script following \"" + tcl_str(cond) + "\" argument")
        body = w[i]
        i += 1
        if _truth(expr(it, cond)):
            return it.eval(body)
        if i >= n:
            return ""
        kw = w[i]
        if kw == "elseif":
            i += 1
            continue
        if kw == "else":
            i += 1
            if i >= n:
                raise TclError("wrong # args: no script following \"else\" argument")
            return it.eval(w[i])
        return it.eval(kw)
    return ""


def _c_while(it, w):
    if len(w) != 3:
        _wrong("while test command")
    while _truth(expr(it, w[1])):
        try:
            it.eval(w[2])
        except _Break:
            break
        except _Continue:
            pass
    return ""


def _c_for(it, w):
    if len(w) != 5:
        _wrong("for start test next command")
    it.eval(w[1])
    while _truth(expr(it, w[2])):
        try:
            it.eval(w[4])
        except _Break:
            break
        except _Continue:
            pass
        it.eval(w[3])
    return ""


def _c_foreach(it, w):
    if len(w) < 4 or len(w) % 2 != 0:
        _wrong("foreach varList list ?varList list ...? command")
    names = split_list(w[1])
    items = split_list(w[2])
    k = 0
    while k < len(items):
        for nm in names:
            it.setvar(nm, items[k] if k < len(items) else "")
            k += 1
        try:
            it.eval(w[-1])
        except _Break:
            break
        except _Continue:
            pass
    return ""


def _c_break(it, w):
    raise _Break()


def _c_continue(it, w):
    raise _Continue()


def _c_return(it, w):
    args = list(w[1:])
    while len(args) >= 2 and tcl_str(args[0]).startswith("-"):
        args = args[2:]
    raise _Return(args[0] if args else "")


def _c_error(it, w):
    if len(w) < 2:
        _wrong("error message ?errorInfo? ?errorCode?")
    raise TclError(tcl_str(w[1]))


def _c_catch(it, w):
    if len(w) < 2:
        _wrong("catch script ?resultVarName? ?optionVarName?")
    code = 0
    try:
        res = it.eval(w[1])
    except TclError as e:
        res = str(e)
        code = 1
    except _Return as r:
        res = r.value
        code = 2
    except _Break:
        res = ""
        code = 3
    except _Continue:
        res = ""
        code = 4
    if len(w) >= 3:
        it.setvar(tcl_str(w[2]), res)
    return code


def _c_eval(it, w):
    if len(w) < 2:
        _wrong("eval arg ?arg ...?")
    if len(w) == 2:
        return it.eval(w[1])
    return it.eval(_c_concat(it, w))


def _c_uplevel(it, w):
    args = list(w[1:])
    if args and (tcl_str(args[0]).startswith("#") or tcl_str(args[0]).isdigit()):
        args = args[1:]
    saved = it.frame
    it.frame = it.globals
    try:
        return it.eval(" ".join([tcl_str(a) for a in args]) if len(args) > 1 else args[0])
    finally:
        it.frame = saved


def _c_puts(it, w):
    import sys
    args = [tcl_str(x) for x in w[1:]]
    newline = True
    if args and args[0] == "-nonewline":
        newline = False
        args = args[1:]
    chan = "stdout"
    if len(args) == 2:
        chan = args[0]
        args = args[1:]
    if len(args) != 1:
        _wrong("puts ?-nonewline? ?channelId? string")
    out = sys.stderr if chan == "stderr" else sys.stdout
    out.write(args[0] + ("\n" if newline else ""))
    return ""


def _c_info(it, w):
    if len(w) < 2:
        _wrong("info subcommand ?arg ...?")
    sub = tcl_str(w[1])
    if sub == "exists":
        return 1 if it.var_exists(tcl_str(w[2])) else 0
    if sub == "patchlevel":
        return it.getvar("tcl_patchLevel")
    if sub == "tclversion":
        return it.getvar("tcl_version")
    if sub == "commands":
        import fnmatch
        names = sorted(set(list(it.commands.keys()) + list(it.procs.keys()) + list(_BUILTINS.keys())))
        if len(w) > 2:
            names = [x for x in names if fnmatch.fnmatchcase(x, tcl_str(w[2]))]
        return join_list(names)
    if sub == "procs":
        return join_list(sorted(it.procs.keys()))
    if sub == "body":
        p = it.procs.get(tcl_str(w[2]))
        if p is None:
            raise TclError("\"" + tcl_str(w[2]) + "\" isn't a procedure")
        return p.body
    if sub == "args":
        p = it.procs.get(tcl_str(w[2]))
        if p is None:
            raise TclError("\"" + tcl_str(w[2]) + "\" isn't a procedure")
        return join_list([q[0] for q in p.params])
    if sub == "level":
        return 0 if it.frame is it.globals else 1
    if sub == "vars" or sub == "globals" or sub == "locals":
        f = it.globals if sub == "globals" else it.frame
        return join_list(sorted(f.vars.keys()))
    raise TclError("info " + sub + " is not supported by Nython's Tcl")


def _c_proc(it, w):
    if len(w) != 4:
        _wrong("proc name args body")
    name = tcl_str(w[1])
    if name.startswith("::"):
        name = name[2:]
    params = [split_list(p) for p in split_list(w[2])]
    it.procs[name] = Proc(name, params, tcl_str(w[3]))
    return ""


def _c_global(it, w):
    for n in w[1:]:
        it.frame.links[tcl_str(n)] = True
    return ""


def _c_subst(it, w):
    args = [tcl_str(x) for x in w[1:]]
    bs = "-nobackslashes" not in args
    vs = "-novariables" not in args
    cs = "-nocommands" not in args
    return it.subst(args[-1], bs, vs, cs)


def _c_format(it, w):
    if len(w) < 2:
        _wrong("format formatString ?arg ...?")
    fmt = tcl_str(w[1])
    args = []
    for a in w[2:]:
        args.append(_maybe_num(a))
    try:
        return fmt % tuple(args)
    except (TypeError, ValueError):
        raise TclError("bad format \"" + fmt + "\"")


def _c_rename(it, w):
    if len(w) != 3:
        _wrong("rename oldName newName")
    old = tcl_str(w[1])
    new = tcl_str(w[2])
    if old in it.commands:
        f = it.commands.pop(old)
        if new != "":
            it.commands[new] = f
        return ""
    if old in it.procs:
        p = it.procs.pop(old)
        if new != "":
            it.procs[new] = p
        return ""
    raise TclError("can't rename \"" + old + "\": command doesn't exist")


def _c_regexp(it, w):
    import re
    args = [tcl_str(x) for x in w[1:]]
    flags = 0
    while args and args[0].startswith("-"):
        a = args.pop(0)
        if a == "-nocase":
            flags |= re.I
        elif a == "--":
            break
    m = re.search(args[0], args[1], flags)
    if not m:
        return 0
    if len(args) > 2:
        it.setvar(args[2], m.group(0))
        for k in range(3, len(args)):
            g = k - 2
            it.setvar(args[k], m.group(g) if g <= (m.lastindex or 0) and m.group(g) is not None else "")
    return 1


_BUILTINS = {
    "set": _c_set, "unset": _c_unset, "incr": _c_incr, "append": _c_append, "lappend": _c_lappend,
    "list": _c_list, "llength": _c_llength, "lindex": _c_lindex, "lrange": _c_lrange,
    "concat": _c_concat, "join": _c_join, "split": _c_split, "string": _c_string, "expr": _c_expr,
    "if": _c_if, "while": _c_while, "for": _c_for, "foreach": _c_foreach, "break": _c_break,
    "continue": _c_continue, "return": _c_return, "error": _c_error, "catch": _c_catch,
    "eval": _c_eval, "uplevel": _c_uplevel, "puts": _c_puts, "info": _c_info, "proc": _c_proc,
    "global": _c_global, "subst": _c_subst, "format": _c_format, "rename": _c_rename,
    "regexp": _c_regexp,
}


def builtin_names():
    return list(_BUILTINS.keys())
