# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/turtledemo/_idle.ny - what turtledemo's viewer takes from idlelib
# (round 87; Nython has no idlelib): ColorDelegator and color_config (Python
# source coloured by tags in a Text widget, IDLE's classic colours),
# Percolator (the widget recoloured after each insert / delete) and
# view_text (a read-only text window), written over tkinter.
import builtins
import keyword
import re

from tkinter import Toplevel, Text, Button, Scrollbar, Frame, NONE, BOTH, LEFT, RIGHT, Y, END


def _any(name, alternates):
    return "(?P<%s>" % name + "|".join(alternates) + ")"


def _make_pat():
    kw = r"\b" + _any("KEYWORD", keyword.kwlist) + r"\b"
    names = [str(n) for n in dir(builtins) if not n.startswith("_") and n not in keyword.kwlist]
    builtin = r"([^.'\"\\#]\b|^)" + _any("BUILTIN", names) + r"\b"
    comment = _any("COMMENT", [r"#[^\n]*"])
    stringprefix = r"(?i:r|u|f|fr|rf|b|br|rb)?"
    sqstring = stringprefix + r"'[^'\\\n]*(\\.[^'\\\n]*)*'?"
    dqstring = stringprefix + r'"[^"\\\n]*(\\.[^"\\\n]*)*"?'
    sq3string = stringprefix + r"'''[^'\\]*((\\.|'(?!''))[^'\\]*)*(''')?"
    dq3string = stringprefix + r'"""[^"\\]*((\\.|"(?!""))[^"\\]*)*(""")?'
    string = _any("STRING", [sq3string, dq3string, sqstring, dqstring])
    return kw + "|" + builtin + "|" + comment + "|" + string + "|" + _any("SYNC", [r"\n"])


_PROG = re.compile(_make_pat(), re.S)
_IDPROG = re.compile(r"\s+(\w+)", re.S)

_TAGDEFS = {
    "COMMENT": {"foreground": "#dd0000", "background": "#ffffff"},
    "KEYWORD": {"foreground": "#ff7700", "background": "#ffffff"},
    "BUILTIN": {"foreground": "#900090", "background": "#ffffff"},
    "STRING": {"foreground": "#00aa00", "background": "#ffffff"},
    "DEFINITION": {"foreground": "#0000ff", "background": "#ffffff"},
}


def color_config(text):
    """Set the colours of a text widget that shows Python source."""
    text.config(foreground="#000000", background="#ffffff", insertbackground="#000000",
                selectforeground="#000000", selectbackground="#c0c0c0")


class ColorDelegator:
    """Colours the Python source in the text widget it is given to."""

    def __init__(self):
        self.text = None

    def recolorize(self):
        text = self.text
        if text is None:
            return
        for tag, cfg in _TAGDEFS.items():
            text.tag_configure(tag, **cfg)
            text.tag_remove(tag, "1.0", "end")
        chars = text.get("1.0", "end")
        for m in _PROG.finditer(chars):
            for key, value in m.groupdict().items():
                if value and key != "SYNC":
                    a, b = m.span(key)
                    text.tag_add(key, "1.0+%dc" % a, "1.0+%dc" % b)
                    if value in ("def", "class"):
                        m1 = _IDPROG.match(chars, b)
                        if m1:
                            a1, b1 = m1.span(1)
                            text.tag_add("DEFINITION", "1.0+%dc" % a1, "1.0+%dc" % b1)


class Percolator:
    """Recolours a text widget after each change through its filters."""

    def __init__(self, text):
        self.text = text
        self.filters = []
        self._insert = text.insert
        self._delete = text.delete
        text.insert = self.insert
        text.delete = self.delete

    def insertfilter(self, f):
        f.text = self.text
        self.filters.append(f)
        f.recolorize()

    def removefilter(self, f):
        self.filters.remove(f)

    def insert(self, index, chars, *args):
        self._insert(index, chars, *args)
        for f in self.filters:
            f.recolorize()

    def delete(self, index1, index2=None):
        self._delete(index1, index2)
        for f in self.filters:
            f.recolorize()

    def close(self):
        self.text.insert = self._insert
        self.text.delete = self._delete


def view_text(parent, title, contents, modal=True, wrap="word"):
    """A window showing `contents`, read only, with a Close button."""
    top = Toplevel(parent)
    top.title(title)
    frame = Frame(top)
    sb = Scrollbar(frame)
    text = Text(frame, wrap=wrap, width=80, height=25)
    sb["command"] = text.yview
    text["yscrollcommand"] = sb.set
    text.insert("1.0", contents)
    text["state"] = "disabled"
    sb.pack(side=RIGHT, fill=Y)
    text.pack(side=LEFT, fill=BOTH, expand=True)
    frame.pack(fill=BOTH, expand=True)
    Button(top, text="Close", command=top.destroy).pack()
    return top
