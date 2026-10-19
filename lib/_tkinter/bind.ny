# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/bind.ny - Tk's event bindings (round 84), after tkBind.c.
#
#   XEvent                  an event as Tk's binding code sees it (X's fields:
#                           type, serial, time, x/y, x_root/y_root, state,
#                           button, keycode, keysym, char, delta, width,
#                           height, detail, focus, mode, name, data ...)
#   parse_sequence(s)       "<Control-Shift-Key-a>", "<Double-Button-1>",
#                           "<B1-Motion>", "<<Paste>>", "ab" (two key
#                           presses), with Tk's messages for bad sequences
#   PatSeq.canonical        the sequence as `bind` prints it back
#                           ("<1>" -> "<Button-1>", "<a>" -> "<Key-a>")
#   BindingTable            one table of tag -> bindings, and the virtual
#                           events (`event add/delete/info`)
#   best_match(...)         Tk's choice among matching bindings: longer
#                           sequences, then patterns with a detail, then
#                           more modifiers; a physical binding beats a
#                           virtual one with the same pattern; ties go to
#                           the most recently defined physical binding
#   matches(seq, ring)      the event ring (30 events): earlier patterns of
#                           a sequence may be separated by events Tk calls
#                           superfluous (motion, releases, Enter/Leave,
#                           modifier keys between button presses); Double/
#                           Triple/Quadruple need the clicks within 500 ms
#                           and 5 pixels of each other (NEARBY_MS/PIXELS)
#   expand_percents(s, ev)  %x %y %K %A %W %# ... as ExpandPercents, values
#                           backslash-quoted (TCL_DONT_USE_BRACES), "??" for
#                           fields the event type does not have
#
# Event-type numbers are X's (KeyPress 2 ... MouseWheel 38), as %T gives.

from _tkinter.tcl import TclError, tcl_str
from _tkinter.keysyms import KEYSYMS

KeyPress = 2
KeyRelease = 3
ButtonPress = 4
ButtonRelease = 5
MotionNotify = 6
EnterNotify = 7
LeaveNotify = 8
FocusIn = 9
FocusOut = 10
Expose = 12
VisibilityNotify = 15
CreateNotify = 16
DestroyNotify = 17
UnmapNotify = 18
MapNotify = 19
ReparentNotify = 21
ConfigureNotify = 22
GravityNotify = 24
CirculateNotify = 26
PropertyNotify = 28
ColormapNotify = 32
VirtualEvent = 35
ActivateNotify = 36
DeactivateNotify = 37
MouseWheelEvent = 38

ShiftMask = 1
LockMask = 2
ControlMask = 4
Mod1Mask = 8
Mod2Mask = 16
Mod3Mask = 32
Mod4Mask = 64
Mod5Mask = 128
Button1Mask = 256
Button2Mask = 512
Button3Mask = 1024
Button4Mask = 2048
Button5Mask = 4096
ALT_MASK = Mod1Mask        # the Alt keys are Mod1 (as on most X servers)
META_MASK = Mod4Mask       # and the Super/Meta keys Mod4

# modArray in tkBind.c: printing uses the first name of a mask
MODS = [("Control", ControlMask, 0), ("Shift", ShiftMask, 0), ("Lock", LockMask, 0),
        ("Meta", META_MASK, 0), ("M", META_MASK, 0), ("Alt", ALT_MASK, 0), ("Extended", 0, 0),
        ("B1", Button1Mask, 0), ("Button1", Button1Mask, 0), ("B2", Button2Mask, 0),
        ("Button2", Button2Mask, 0), ("B3", Button3Mask, 0), ("Button3", Button3Mask, 0),
        ("B4", Button4Mask, 0), ("Button4", Button4Mask, 0), ("B5", Button5Mask, 0),
        ("Button5", Button5Mask, 0), ("Mod1", Mod1Mask, 0), ("M1", Mod1Mask, 0),
        ("Command", Mod1Mask, 0), ("Mod2", Mod2Mask, 0), ("M2", Mod2Mask, 0),
        ("Option", Mod2Mask, 0), ("Mod3", Mod3Mask, 0), ("M3", Mod3Mask, 0),
        ("Mod4", Mod4Mask, 0), ("M4", Mod4Mask, 0), ("Mod5", Mod5Mask, 0), ("M5", Mod5Mask, 0),
        ("Double", 0, 2), ("Triple", 0, 3), ("Quadruple", 0, 4), ("Any", 0, 0)]
_MODMAP = {}
for _m in MODS:
    _MODMAP[_m[0]] = _m
_PRINT_MODS = [("Control", ControlMask), ("Shift", ShiftMask), ("Lock", LockMask), ("Meta", META_MASK),
               ("Alt", ALT_MASK), ("B1", Button1Mask), ("B2", Button2Mask), ("B3", Button3Mask),
               ("B4", Button4Mask), ("B5", Button5Mask), ("Mod2", Mod2Mask), ("Mod3", Mod3Mask),
               ("Mod5", Mod5Mask)]

# eventArray in tkBind.c (the first name of a type is the one printed)
EVENTS = [("Key", KeyPress), ("KeyPress", KeyPress), ("KeyRelease", KeyRelease),
          ("Button", ButtonPress), ("ButtonPress", ButtonPress), ("ButtonRelease", ButtonRelease),
          ("Motion", MotionNotify), ("Enter", EnterNotify), ("Leave", LeaveNotify),
          ("FocusIn", FocusIn), ("FocusOut", FocusOut), ("Expose", Expose),
          ("Visibility", VisibilityNotify), ("Destroy", DestroyNotify), ("Unmap", UnmapNotify),
          ("Map", MapNotify), ("Reparent", ReparentNotify), ("Configure", ConfigureNotify),
          ("Gravity", GravityNotify), ("Circulate", CirculateNotify), ("Property", PropertyNotify),
          ("Colormap", ColormapNotify), ("Activate", ActivateNotify), ("Deactivate", DeactivateNotify),
          ("MouseWheel", MouseWheelEvent), ("CirculateRequest", 27), ("ConfigureRequest", 23),
          ("Create", CreateNotify), ("MapRequest", 20), ("ResizeRequest", 25)]
_EVMAP = {}
_EVNAME = {}
for _e in EVENTS:
    _EVMAP[_e[0]] = _e[1]
    if _e[1] not in _EVNAME:
        _EVNAME[_e[1]] = _e[0]

_KEYSYM_NAME = {}
for _k in KEYSYMS:
    if KEYSYMS[_k] not in _KEYSYM_NAME:
        _KEYSYM_NAME[KEYSYMS[_k]] = _k

MODIFIER_KEYSYMS = set([0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe5, 0xffe6, 0xffe7, 0xffe8, 0xffe9,
                        0xffea, 0xffeb, 0xffec, 0xffed, 0xffee, 0xff7f, 0xfe03])

NEARBY_PIXELS = 5
NEARBY_MS = 500


def keysym_number(name):
    v = KEYSYMS.get(name)
    if v is not None:
        return v
    if len(name) == 1:
        c = ord(name)
        if c < 0x100:
            return c
        return 0x1000000 + c
    if name.startswith("U") and len(name) > 1:
        try:
            return 0x1000000 + int(name[1:], 16)
        except ValueError:
            pass
    return None


def keysym_name(num):
    n = _KEYSYM_NAME.get(num)
    if n is not None:
        return n
    if num >= 0x1000000:
        return chr(num - 0x1000000)
    if 32 <= num < 256:
        return chr(num)
    return "??"


class XEvent:
    def __init__(self, type, window):
        self.type = type
        self.window = window       # the TkWin it is for
        self.serial = 0
        self.send_event = 0
        self.time = 0
        self.x = 0
        self.y = 0
        self.x_root = 0
        self.y_root = 0
        self.state = 0
        self.button = 0
        self.keycode = 0
        self.keysym = ""
        self.keysym_num = 0
        self.char = ""
        self.delta = 0
        self.width = 0
        self.height = 0
        self.detail = "NotifyAncestor"
        self.focus = 0
        self.mode = "NotifyNormal"
        self.name = ""             # the virtual event's name, without << >>
        self.data = ""             # its -data
        self.above = 0
        self.border = 0
        self.override = 0
        self.place = "PlaceOnTop"
        self.count = 0
        self.property = ""


class Pat:
    def __init__(self, type, detail, mods):
        self.type = type
        self.detail = detail       # button number, keysym number, virtual name, or 0
        self.mods = mods


class PatSeq:
    def __init__(self, pats, virtual, nearby, canonical):
        self.pats = pats
        self.virtual = virtual     # True for <<Name>>
        self.nearby = nearby
        self.canonical = canonical


def parse_sequence(seq, allow_virtual=True):
    seq = tcl_str(seq)
    pats = []
    nearby = False
    i = 0
    n = len(seq)
    if n == 0:
        raise TclError("no events specified in binding")
    if seq.startswith("<<"):
        e = seq.find(">>")
        if e < 0 or e != n - 2:
            raise TclError("missing \">\" in virtual binding" if e < 0 else "virtual event \"" + seq + "\" is badly formed")
        name = seq[2:e]
        if name == "":
            raise TclError("virtual event \"<<>>\" is badly formed")
        if not allow_virtual:
            raise TclError("virtual event not allowed in definition of another virtual event")
        return PatSeq([Pat(VirtualEvent, name, 0)], True, False, "<<" + name + ">>")
    while i < n:
        c = seq[i]
        if c == "<":
            e = seq.find(">", i)
            if e < 0:
                raise TclError("missing \">\" in binding")
            body = seq[i + 1:e]
            if body.startswith("<"):
                raise TclError("virtual events may not be composed")
            i = e + 1
            pat, count = _parse_pattern(body)
            for k in range(count):
                pats.append(pat)
            if count > 1:
                nearby = True
        else:
            if c == " ":
                ks = 0x20
            else:
                ks = keysym_number(c)
            pats.append(Pat(KeyPress, ks, 0))
            i += 1
    if not pats:
        raise TclError("no events specified in binding")
    return PatSeq(pats, False, nearby, _canonical(pats))


def _parse_pattern(body):
    fields = [f for f in body.replace(" ", "-").split("-")]
    # "<Key-minus>" / "<Control-->": a trailing empty field after '-' means the keysym '-'?
    # Tk reads fields separated by '-' or white space.
    fields = [f for f in fields if f != ""] if "--" not in body else _fields_keep_minus(body)
    mods = 0
    count = 1
    k = 0
    while k < len(fields):
        m = _MODMAP.get(fields[k])
        if m is None:
            break
        mods |= m[1]
        if m[2]:
            count = m[2]
        k += 1
    evtype = 0
    detail = 0
    if k < len(fields) and fields[k] in _EVMAP:
        evtype = _EVMAP[fields[k]]
        k += 1
        if k < len(fields):
            f = fields[k]
            if evtype in (ButtonPress, ButtonRelease):
                if len(f) == 1 and f in "123456789":
                    detail = int(f)
                else:
                    raise TclError("bad button number \"" + f + "\"")
            elif evtype in (KeyPress, KeyRelease):
                ks = keysym_number(f)
                if ks is None:
                    raise TclError("bad keysym \"" + f + "\"")
                detail = ks
            else:
                raise TclError("specified keysym \"" + f + "\" for non-key event")
            k += 1
    elif k < len(fields):
        f = fields[k]
        if len(f) == 1 and f in "12345":
            evtype = ButtonPress
            detail = int(f)
        else:
            ks = keysym_number(f)
            if ks is None:
                raise TclError("bad event type or keysym \"" + f + "\"")
            evtype = KeyPress
            detail = ks
        k += 1
    else:
        raise TclError("no event type or button # or keysym")
    if k < len(fields):
        raise TclError("extra characters after detail in binding")
    return Pat(evtype, detail, mods), count


def _fields_keep_minus(body):
    parts = body.split("-")
    out = []
    i = 0
    while i < len(parts):
        if parts[i] == "" and i + 1 < len(parts) and parts[i + 1] == "":
            out.append("minus")
            i += 2
            continue
        if parts[i] != "":
            out.append(parts[i])
        i += 1
    return out


def _pat_text(p, count):
    s = "<"
    if count == 2:
        s += "Double-"
    elif count == 3:
        s += "Triple-"
    elif count >= 4:
        s += "Quadruple-"
    for name, mask in _PRINT_MODS:
        if p.mods & mask:
            s += name + "-"
    s += _EVNAME.get(p.type, "Key")
    if p.detail:
        if p.type in (KeyPress, KeyRelease):
            s += "-" + keysym_name(p.detail)
        else:
            s += "-" + str(p.detail)
    return s + ">"


def _canonical(pats):
    out = ""
    i = 0
    while i < len(pats):
        p = pats[i]
        j = i + 1
        while j < len(pats) and j - i < 4 and _same(pats[j], p):
            j += 1
        count = j - i
        out += _pat_text(p, count if count > 1 else 1)
        i = j
    return out


def _same(a, b):
    return a.type == b.type and a.detail == b.detail and a.mods == b.mods


class Binding:
    def __init__(self, seq, script, serial):
        self.seq = seq
        self.script = script
        self.serial = serial


class BindingTable:
    def __init__(self):
        self.tags = {}          # tag -> list of Binding (newest last)
        self.virtuals = {}      # name -> list of PatSeq (physical)
        self.serial = 0

    def set(self, tag, seq, script):
        ps = parse_sequence(seq)
        lst = self.tags.get(tag)
        if lst is None:
            lst = []
            self.tags[tag] = lst
        for i in range(len(lst)):
            if lst[i].seq.canonical == ps.canonical:
                if script == "":
                    del lst[i]
                    return
                if script.startswith("+"):
                    old = lst[i].script
                    lst[i].script = (old + "\n" + script[1:]) if old != "" else script[1:]
                else:
                    lst[i].script = script
                return
        if script == "":
            return
        if script.startswith("+"):
            script = script[1:]
        self.serial += 1
        lst.append(Binding(ps, script, self.serial))

    def get(self, tag, seq):
        ps = parse_sequence(seq)
        for b in self.tags.get(tag, []):
            if b.seq.canonical == ps.canonical:
                return b.script
        return ""

    def sequences(self, tag):
        return [b.seq.canonical for b in reversed(self.tags.get(tag, []))]

    def delete_tag(self, tag):
        if tag in self.tags:
            del self.tags[tag]

    # virtual events
    def event_add(self, name, seqs):
        lst = self.virtuals.setdefault(name, [])
        for s in seqs:
            ps = parse_sequence(s, False)
            if ps.virtual:
                raise TclError("virtual event not allowed in definition of another virtual event")
            if not any([q.canonical == ps.canonical for q in lst]):
                lst.append(ps)

    def event_delete(self, name, seqs):
        if name not in self.virtuals:
            return
        if not seqs:
            del self.virtuals[name]
            return
        keep = []
        drop = set([parse_sequence(s, False).canonical for s in seqs])
        for q in self.virtuals[name]:
            if q.canonical not in drop:
                keep.append(q)
        if keep:
            self.virtuals[name] = keep
        else:
            del self.virtuals[name]

    def event_info(self, name=None):
        if name is None:
            return ["<<" + v + ">>" for v in self.virtuals]
        return [q.canonical for q in self.virtuals.get(name, [])]

    def best_match(self, tag, ring, ev):
        # The script of the binding of `tag` that Tk picks for the newest
        # event of the ring, or None.
        lst = self.tags.get(tag)
        if not lst:
            return None
        best = None
        bestseq = None
        if ev.type == VirtualEvent:
            for b in reversed(lst):
                if b.seq.virtual and b.seq.pats[0].detail == ev.name:
                    return b.script
            return None
        for b in reversed(lst):
            if b.seq.virtual:
                continue
            if matches(b.seq, ring, ev):
                if best is None or more_specific(b.seq, bestseq):
                    best = b
                    bestseq = b.seq
        # virtual bindings whose physical pattern matches
        for b in lst:
            if not b.seq.virtual:
                continue
            vname = b.seq.pats[0].detail
            for ps in self.virtuals.get(vname, []):
                if matches(ps, ring, ev):
                    if best is None or more_specific(ps, bestseq):
                        best = b
                        bestseq = ps
        return best.script if best is not None else None


def more_specific(a, b):
    # True when sequence a beats sequence b (ties keep b)
    if len(a.pats) != len(b.pats):
        return len(a.pats) > len(b.pats)
    for i in range(len(a.pats)):
        pa = a.pats[i]
        pb = b.pats[i]
        if pa.detail != pb.detail:
            if not pa.detail:
                return False
            if not pb.detail:
                return True
        if pa.mods != pb.mods:
            if (pa.mods & pb.mods) == pa.mods:
                return False
            if (pa.mods & pb.mods) == pb.mods:
                return True
    return False


def pat_matches(p, e):
    if p.type != e.type:
        return False
    if p.detail:
        if p.type in (ButtonPress, ButtonRelease):
            if e.button != p.detail:
                return False
        elif p.type in (KeyPress, KeyRelease):
            if e.keysym_num != p.detail:
                return False
    if p.mods and (e.state & p.mods) != p.mods:
        return False
    return True


def matches(seq, ring, ev):
    pats = seq.pats
    last = len(pats) - 1
    if not pat_matches(pats[last], ev):
        return False
    if last == 0:
        return True
    window = ev.window
    ri = len(ring) - 2
    pi = last - 1
    first = ev
    while pi >= 0:
        if ri < 0:
            return False
        e = ring[ri]
        ri -= 1
        if e.window is not window:
            return False
        p = pats[pi]
        if e.type != p.type:
            if p.type in (KeyPress, KeyRelease):
                if e.type in (ButtonPress, ButtonRelease):
                    return False
            elif p.type in (ButtonPress, ButtonRelease):
                if e.type in (KeyPress, KeyRelease):
                    if e.keysym_num in MODIFIER_KEYSYMS:
                        continue
                    return False
            continue
        if not pat_matches(p, e):
            return False
        first = e
        pi -= 1
    if seq.nearby:
        if abs(first.x_root - ev.x_root) > NEARBY_PIXELS or abs(first.y_root - ev.y_root) > NEARBY_PIXELS:
            return False
        if ev.time - first.time > NEARBY_MS:
            return False
    return True


# ── % substitution ───────────────────────────────────────────────────────────

_KEY = 1
_BUTTON = 2
_MOTION = 4
_CROSSING = 8
_FOCUS = 16
_EXPOSE = 32
_VISIBILITY = 64
_CREATE = 128
_DESTROY = 256
_UNMAP = 512
_MAP = 1024
_REPARENT = 2048
_CONFIG = 4096
_GRAVITY = 8192
_CIRC = 16384
_PROP = 32768
_COLORMAP = 65536
_VIRTUAL = 131072
_ACTIVATE = 262144
_WHEEL = 524288

_FLAGS = {KeyPress: _KEY, KeyRelease: _KEY, ButtonPress: _BUTTON, ButtonRelease: _BUTTON,
          MotionNotify: _MOTION, EnterNotify: _CROSSING, LeaveNotify: _CROSSING, FocusIn: _FOCUS,
          FocusOut: _FOCUS, Expose: _EXPOSE, VisibilityNotify: _VISIBILITY, CreateNotify: _CREATE,
          DestroyNotify: _DESTROY, UnmapNotify: _UNMAP, MapNotify: _MAP, ReparentNotify: _REPARENT,
          ConfigureNotify: _CONFIG, GravityNotify: _GRAVITY, CirculateNotify: _CIRC,
          PropertyNotify: _PROP, ColormapNotify: _COLORMAP, VirtualEvent: _VIRTUAL,
          ActivateNotify: _ACTIVATE, DeactivateNotify: _ACTIVATE, MouseWheelEvent: _WHEEL}

_KBMC = _KEY | _BUTTON | _MOTION | _CROSSING | _VIRTUAL | _WHEEL


def percent_value(c, ev):
    # One field as ExpandPercents gives it (a str or an int), "??" when the
    # event type has no such field.
    f = _FLAGS.get(ev.type, 0)
    if c == "#":
        return ev.serial
    if c == "W":
        return ev.window.path if ev.window is not None else "??"
    if c == "T":
        return ev.type
    if c == "E":
        return ev.send_event
    if c == "x":
        return ev.x if f & (_KBMC | _EXPOSE | _CONFIG | _GRAVITY | _REPARENT | _CREATE) else "??"
    if c == "y":
        return ev.y if f & (_KBMC | _EXPOSE | _CONFIG | _GRAVITY | _REPARENT | _CREATE) else "??"
    if c == "X":
        return ev.x_root if f & (_KBMC) else "??"
    if c == "Y":
        return ev.y_root if f & (_KBMC) else "??"
    if c == "b":
        return ev.button if f & _BUTTON else "??"
    if c == "k":
        return ev.keycode if f & _KEY else "??"
    if c == "K":
        return ev.keysym if f & _KEY else "??"
    if c == "N":
        return ev.keysym_num if f & _KEY else "??"
    if c == "A":
        return ev.char if f & _KEY else "??"
    if c == "s":
        if f & (_KBMC):
            return ev.state
        if f & _VISIBILITY:
            return "VisibilityUnobscured"
        return "??"
    if c == "t":
        return ev.time if f & (_KBMC | _PROP) else "??"
    if c == "w":
        return ev.width if f & (_EXPOSE | _CONFIG | _CREATE) else "??"
    if c == "h":
        return ev.height if f & (_EXPOSE | _CONFIG | _CREATE) else "??"
    if c == "D":
        return ev.delta if f & _WHEEL else "??"
    if c == "d":
        if f & (_CROSSING | _FOCUS):
            return ev.detail
        if f & _VIRTUAL:
            return ev.data
        return "??"
    if c == "f":
        return ev.focus if f & _CROSSING else "??"
    if c == "m":
        return ev.mode if f & (_CROSSING | _FOCUS) else "??"
    if c == "c":
        return ev.count if f & _EXPOSE else "??"
    if c == "a":
        return ev.above if f & _CONFIG else "??"
    if c == "B":
        return ev.border if f & (_CONFIG | _CREATE) else "??"
    if c == "o":
        return ev.override if f & (_MAP | _REPARENT | _CONFIG | _CREATE) else "??"
    if c == "p":
        return ev.place if f & _CIRC else "??"
    if c == "P":
        return ev.property if f & _PROP else "??"
    if c == "i":
        return id(ev.window) & 0xffffff if ev.window is not None else 0
    if c == "R" or c == "S":
        return 0
    if c == "M":
        return 0
    return "??"


_SPECIALS = " \t\n\r{}[]$;\"\\"


def bs_quote(s):
    # Tcl_ConvertElement with TCL_DONT_USE_BRACES
    if s == "":
        return "{}"
    out = []
    for c in s:
        if c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif c == "\r":
            out.append("\\r")
        elif c in _SPECIALS:
            out.append("\\" + c)
        else:
            out.append(c)
    if out[0] == "#":
        out[0] = "\\#"
    return "".join(out)


def expand_percents(script, ev):
    if "%" not in script:
        return script
    out = []
    i = 0
    n = len(script)
    while i < n:
        c = script[i]
        if c != "%":
            j = script.find("%", i)
            if j < 0:
                out.append(script[i:])
                break
            out.append(script[i:j])
            i = j
            continue
        if i + 1 >= n:
            out.append("%")
            break
        d = script[i + 1]
        i += 2
        if d == "%":
            out.append("%")
            continue
        v = percent_value(d, ev)
        out.append(bs_quote(v if isinstance(v, str) else str(v)))
    return "".join(out)
