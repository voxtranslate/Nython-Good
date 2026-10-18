# nython: module    (a package: the Tcl/Tk under Nython's tkinter)
# lib/_tkinter - CPython's _tkinter, implemented by Nython over its own SDL
# GUI backend instead of a Tcl/Tk library (round 84).
#
#     import _tkinter
#     app = _tkinter.create(None, "demo", "Tk", False, 1, True, False, None)
#     app.call("button", ".b", "-text", "OK"); app.call(".b", "cget", "-text")
#
# create(...)          a tkapp: Tcl variables, commands, and Tk (wantTk) - the
#                      application object of lib/_tkinter/core.ny
# TclError, TK_VERSION ("8.6"), TCL_VERSION ("8.6"), READABLE/WRITABLE/
# EXCEPTION, WINDOW_EVENTS/FILE_EVENTS/TIMER_EVENTS/IDLE_EVENTS/ALL_EVENTS/
# DONT_WAIT, getbusywaitinterval/setbusywaitinterval, Tcl_Obj, _flatten
#
# The parts:  tcl.ny (Tcl lists, a small interpreter, expr), core.ny (the
# application, events, bindings' dispatch, the loop, focus, wm, winfo ...),
# bind.ny (sequences, matching, %-substitution), geom.ny (pack, grid,
# place), win.ny (the window record and option tables), util.ny (units,
# colours, fonts, drawing), widgets.ny, entry.ny, text.ny, canvas.ny,
# menu.ny, image.ny (photo and bitmap images, PNG/GIF/PPM codecs) - the
# classic widgets; ttk.ny (ttk's style engine: themes, elements, layouts,
# state maps, and the simple ttk widgets), ttk2.ny (ttk's entry, combobox,
# spinbox, scrollbar, scale, progressbar, notebook, panedwindow,
# treeview), dialogs.ny (tk_messageBox, tk_dialog, tk_getOpenFile/
# tk_getSaveFile/tk_chooseDirectory over the native file dialogs,
# tk_chooseColor); colors.ny / keysyms.ny (tables generated from X11's
# rgb.txt and keysymdef.h).
#
# Several Tk applications (a second Tk(), turtle's Screen beside a
# program's root) share one event loop, as Tcl's notifier is the thread's:
# whichever application's loop runs serves every application's window
# events, timers and idle handlers.
#
# Not provided: a real Tcl (only the subset tcl.ny lists), file handlers
# (createfilehandler raises TclError), `send`, threads calling into Tk from
# other threads (Nython's GIL serialises them, but Tk's thread check is
# not emulated), Tcl_Obj results (plain str/int/float/tuple are returned).

from _tkinter.tcl import TclError, tcl_str, split_list, join_list
from _tkinter import core
from _tkinter import widgets
from _tkinter import entry
from _tkinter import menu
from _tkinter import text
from _tkinter import canvas
from _tkinter import image
from _tkinter import ttk
from _tkinter import ttk2
from _tkinter import dialogs

TK_VERSION = core.TK_VERSION
TCL_VERSION = core.TCL_VERSION
READABLE = 2
WRITABLE = 4
EXCEPTION = 8
WINDOW_EVENTS = core.WINDOW_EVENTS
FILE_EVENTS = core.FILE_EVENTS
TIMER_EVENTS = core.TIMER_EVENTS
IDLE_EVENTS = core.IDLE_EVENTS
ALL_EVENTS = core.ALL_EVENTS
DONT_WAIT = core.DONT_WAIT

TkappType = core.App

_busy = [20]


def getbusywaitinterval():
    return _busy[0]


def setbusywaitinterval(ms):
    if not isinstance(ms, int):
        raise TypeError("an integer is required")
    if ms < 0:
        raise ValueError("interval must be positive")
    _busy[0] = ms


class Tcl_Obj:
    # what _tkinter gives for Tcl objects of a type it does not convert;
    # Nython's Tk returns plain values, so this only wraps on request
    def __init__(self, value, typename="string"):
        self.typename = typename
        self.string = tcl_str(value)

    def __str__(self):
        return self.string

    def __repr__(self):
        return "<%s object: %r>" % (self.typename, self.string)

    def _tcl_string(self):
        return self.string


def create(screenName=None, baseName="", className="Tk", interactive=False, wantobjects=1, wantTk=True,
           sync=False, use=None):
    return core.App(screenName, baseName, className, interactive, wantobjects, wantTk, sync, use)


def _flatten(seq):
    res = ()
    for item in seq:
        if isinstance(item, (tuple, list)):
            res = res + _flatten(item)
        elif item is not None:
            res = res + (item,)
    return res
