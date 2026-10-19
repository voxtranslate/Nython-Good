# nython: module    (import it by name: it runs in a module scope of its own)
# lib/nyxai/docgen.ny - drafts a docstring for a function from the facts
# the real parser gives (round 82).
#
#     from nyxai.docgen import draft_docstring, docstring_edit
#     text = draft_docstring(fn)          # Google style: summary, Args, Returns/Yields, Raises
#     edit = docstring_edit(fn)           # a line edit putting it under the def (or replacing one)
#
# What it says comes from the program, not from canned text:
#   - the summary from the name (get_x -> "Return the x.", is_valid ->
#     "Return whether valid.", parse_config -> "Parse the config."), or the
#     existing docstring's first line;
#   - Args: each parameter with its annotation or the type of its default,
#     its default, and how the body uses it (iterated over, called,
#     indexed, compared with None, passed to another function);
#   - Returns: the annotation, else the kind of value every return gives
#     (a bool, a str, a list ...) or the expressions returned; "None" when no
#     return gives a value; Yields for a generator;
#   - Raises: each exception a raise statement names, with the condition
#     the raise is control dependent on (text_defuse's predicates: "If lo >
#     hi."), and those a call lets through (when given the rule engine's
#     may_raise facts).
#
# Not here: descriptions of what a parameter means (that needs a person).

__all__ = ["draft_docstring", "docstring_edit", "summary_from_name"]

import re

VERBS = set(["add", "apply", "build", "check", "clamp", "clear", "close", "compute", "convert", "copy",
             "count", "create", "decode", "delete", "encode", "ensure", "find", "format", "generate",
             "handle", "init", "insert", "load", "make", "merge", "normalize", "open", "parse", "print",
             "process", "read", "remove", "render", "reset", "resolve", "run", "save", "scan", "search",
             "send", "sort", "split", "start", "stop", "update", "validate", "write", "fetch", "sum",
             "filter", "map", "reduce", "collect", "draw", "emit", "join", "match", "register", "flatten",
             "invert", "reverse", "swap", "wrap", "strip", "trim", "visit", "walk", "train", "predict"])


def _words(name):
    out = []
    for piece in name.strip("_").split("_"):
        if piece == "":
            continue
        cur = ""
        for i in range(len(piece)):
            ch = piece[i]
            if cur != "" and ch.isupper() and not piece[i - 1].isupper():
                out.append(cur.lower())
                cur = ""
            cur = cur + ch
        if cur != "":
            out.append(cur.lower())
    return out


def summary_from_name(name, cls=""):
    if name == "__init__":
        return "Initialize the " + (cls if cls != "" else "object") + "."
    if name == "__repr__" or name == "__str__":
        return "Return the text form of the " + (cls if cls != "" else "object") + "."
    if name == "__eq__":
        return "Return whether this equals another."
    if name == "__len__":
        return "Return the number of items."
    if name == "__iter__":
        return "Iterate over the items."
    w = _words(name)
    if len(w) == 0:
        return "Run " + name + "."
    rest = " ".join(w[1:])
    if w[0] in ["get", "compute", "calc", "calculate"] and rest != "":
        return "Return the " + rest + "."
    if w[0] in ["is", "has", "can", "should"] and rest != "":
        return "Return whether " + ("it has " if w[0] == "has" else "") + rest + "."
    if w[0] == "set" and rest != "":
        return "Set the " + rest + "."
    if w[0] == "to" and rest != "":
        return "Convert to " + rest + "."
    if w[0] in VERBS:
        v = w[0][0:1].upper() + w[0][1:]
        return v + (" the " + rest if rest != "" else "") + "."
    s = " ".join(w)
    return s[0:1].upper() + s[1:] + "."


def _ann_or_default_type(p):
    if p.annotation is not None:
        return p.annotation
    if p.default is None:
        return None
    d = p.default.strip()
    if d in ["True", "False", "true", "false"]:
        return "bool"
    if d.startswith("'") or d.startswith('"'):
        return "str"
    if d.startswith("["):
        return "list"
    if d.startswith("{"):
        return "dict"
    if d.startswith("("):
        return "tuple"
    t = d.lstrip("-")
    if t.isdigit():
        return "int"
    if t.replace(".", "", 1).isdigit():
        return "float"
    return None


def _uses(fn, p, lines):
    """How the body uses parameter p (from its source lines)."""
    name = p.name
    out = []
    body = "\n".join(lines[fn.line:fn.end])
    if re.search(r"\bfor\s+[^\n]*\bin\s+" + name + r"\s*:", body) is not None:
        out.append("iterated over")
    if re.search(r"\b" + name + r"\s*\(", body) is not None:
        out.append("called")
    meth = []
    for m in re.findall(r"\b" + name + r"\.([A-Za-z_][A-Za-z0-9_]*)\s*\(", body):
        if m not in meth:
            meth.append(m)
    if len(meth) > 0:
        out.append("its " + ", ".join(x + "()" for x in meth[0:3]) + (" is" if len(meth) == 1 else " are") + " called")
    if re.search(r"\b" + name + r"\s*\[", body) is not None:
        out.append("indexed")
    if re.search(r"\b" + name + r"\s+is\s+(not\s+)?(None|none)\b", body) is not None:
        out.append("may be None")
    # the innermost call it is an argument of (calls are listed outer first)
    passed = ""
    for c in fn.calls:
        if c[1] == name or c[1].startswith(name + "."):
            continue
        args_hit = re.search(r"\b" + re.escape(c[1]) + r"\s*\([^)]*\b" + name + r"\b", body)
        if args_hit is not None:
            passed = c[1]
    if passed != "" and len(out) < 4:
        out.append("passed to " + passed + "()")
    return out


def _value_kind(text):
    t = text.strip()
    if t in ["True", "False", "true", "false"] or t.startswith("not ") or re.search(r"(==|!=|<=|>=|<|>| in | is )", t) is not None:
        return "bool"
    if t.startswith("'") or t.startswith('"') or t.startswith("f'") or t.startswith('f"') or t.startswith("str("):
        return "str"
    if t.startswith("[") or t.startswith("list(") or t.startswith("sorted("):
        return "list"
    if t.startswith("{") or t.startswith("dict("):
        return "dict"
    if t.startswith("(") and "," in t:
        return "tuple"
    if t.startswith("len(") or t.startswith("int(") or t.isdigit():
        return "int"
    if t.startswith("float("):
        return "float"
    return None


def _predicate(fn, du, lines, ln):
    """The innermost condition a statement on line ln is control dependent on, as text."""
    if du is None or ln < 1 or ln > len(du):
        return ""
    e = du[ln - 1]
    if e is None or len(e.get("ctrl", [])) == 0:
        return ""
    cl = e["ctrl"][0]
    br = e["branch"][0]
    if cl < fn.line or cl > fn.end:
        return ""
    t = lines[cl - 1].strip()
    m = re.match(r"^(if|elif|while)\s+(.*):\s*(#.*)?$", t)
    if m is None:
        return ""
    cond = m.group(2).strip()
    if br == "else":
        return "Unless " + cond
    return "If " + cond


def draft_docstring(fn, du=None, may_raise=None, indent=""):
    """The docstring text (without quotes) for FunctionInfo fn. du:
    text_defuse of its module (computed when not given); may_raise:
    [[exception, via function]] the rule engine inferred."""
    lines = fn.module.lines
    if du is None:
        du = text_defuse(fn.module.text)
    out = []
    first = fn.doc_summary()
    out.append(first if first != "" else summary_from_name(fn.name, fn.cls))
    params = fn.explicit_params()
    if fn.kind() == "staticmethod":
        params = fn.params
    if len(params) > 0:
        out.append("")
        out.append("Args:")
        for p in params:
            t = _ann_or_default_type(p)
            head = p.name
            if p.kind == "var_positional":
                head = "*" + p.name
            elif p.kind == "var_keyword":
                head = "**" + p.name
            if t is not None:
                head = head + " (" + t + ")"
            desc = []
            u = _uses(fn, p, lines)
            if len(u) > 0:
                d0 = ", ".join(u)
                desc.append(d0[0:1].upper() + d0[1:] + ".")
            if p.default is not None:
                desc.append("Defaults to " + p.default + ".")
            if p.kind == "keyword_only":
                desc.append("Keyword-only.")
            if len(desc) == 0:
                desc.append("The " + " ".join(_words(p.name)) + ".")
            out.append("    " + head + ": " + " ".join(desc))
    valued = [r for r in fn.returns if r[1]]
    if fn.is_generator:
        out.append("")
        out.append("Yields:")
        out.append("    " + (fn.return_annotation if fn.return_annotation is not None else "The values it produces") + ".")
    elif fn.return_annotation is not None or len(valued) > 0:
        out.append("")
        out.append("Returns:")
        if fn.return_annotation is not None:
            rt = fn.return_annotation
        else:
            kinds = set()
            for r in valued:
                kinds.add(_value_kind(r[2]))
            rt = list(kinds)[0] if len(kinds) == 1 and None not in kinds else None
        exprs = []
        for r in valued:
            if r[2] not in exprs and len(exprs) < 4:
                exprs.append(r[2])
        if rt is not None:
            line = "    " + rt + ": "
        else:
            line = "    "
        if len(exprs) == 1:
            line = line + "`" + exprs[0] + "`."
        else:
            line = line + "One of " + ", ".join("`" + e + "`" for e in exprs) + "."
        if fn.end_reachable or len([r for r in fn.returns if not r[1]]) > 0:
            line = line + " None on the other paths."
        out.append(line)
    raised = []
    for r in fn.raises:
        if r[1] == "":
            continue
        en = r[1].split(".")[-1]
        cond = _predicate(fn, du, lines, r[0])
        raised.append([en, (cond + "." if cond != "" else "Raised on line " + str(r[0]) + ".")])
    if may_raise is not None:
        for mr in may_raise:
            if mr[0] not in [x[0] for x in raised]:
                raised.append([mr[0], "Propagated from " + mr[1] + "()."])
    if len(raised) > 0:
        out.append("")
        out.append("Raises:")
        for x in raised:
            out.append("    " + x[0] + ": " + x[1])
    return "\n".join(indent + l if l != "" else "" for l in out)


def docstring_edit(fn, du=None, may_raise=None):
    """{"line", "end", "new"}: the edit that puts a drafted docstring under the
    def (replacing an existing one)."""
    lines = fn.module.lines
    # the header ends at the line ending with ":" at bracket depth 0
    ln = fn.line
    depth = 0
    while ln <= len(lines):
        t = lines[ln - 1]
        for ch in t:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
        if depth <= 0 and t.rstrip().endswith(":"):
            break
        ln += 1
    body = lines[ln] if ln < len(lines) else ""
    ind = body[0:len(body) - len(body.lstrip())]
    if ind == "" or len(ind) <= len(lines[fn.line - 1]) - len(lines[fn.line - 1].lstrip()):
        d0 = lines[fn.line - 1]
        ind = d0[0:len(d0) - len(d0.lstrip())] + "    "
    text = draft_docstring(fn, du, may_raise, ind)
    new = (ind + '"""' + text.lstrip() + "\n" + ind + '"""').split("\n")
    if len(new) == 2:
        new = [ind + '"""' + text.strip() + '"""']
    if fn.doc_line > 0:
        # replace the existing docstring's lines
        start = fn.doc_line
        d = lines[start - 1]
        q = '"""' if '"""' in d else ("'''" if "'''" in d else "")
        end = start
        if q != "" and d.count(q) < 2:
            end = start + 1
            while end <= len(lines) and q not in lines[end - 1]:
                end += 1
        return {"line": start, "end": end, "new": new}
    return {"line": ln + 1, "end": ln, "new": new}
