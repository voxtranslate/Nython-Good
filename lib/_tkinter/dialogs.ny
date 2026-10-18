# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/dialogs.ny - Tk's standard dialogs (round 84):
#
# tk_messageBox      msgbox.tcl's dialog built from Tk widgets: the icon,
#                    message and detail, the buttons of -type with -default
#                    (Return invokes the focused button, Escape and the
#                    window's close the cancel one), modal (grab, nested
#                    event loop); Tk's option checks and messages
# tk_dialog          dialog.tcl's: the index of the button pressed
# tk_getOpenFile     the backend's native dialogs (gui_show_open_dialog /
# tk_getSaveFile     gui_show_save_dialog; SDL3's portal/GTK/Win32/Cocoa
# tk_chooseDirectory dialogs), waited for in a nested event loop; the
#                    headless stub answers them with its `dialog [PATH]`
#                    script command, and a quit while one is open is a
#                    cancel ("" - an empty list for -multiple)
# tk_chooseColor     a dialog of Tk widgets: red/green/blue scales, the
#                    colour as #rrggbb, a sample, OK/Cancel
#
# All of them can be answered by scripted input (the stub's event script,
# tkinter's Misc._ny_queue()). Not provided: Tk's own Tcl file dialog
# (tkfbox.tcl) - the native one is used everywhere - and -filetypes
# filtering beyond passing them on (SDL takes the patterns; the stub
# ignores them).

import os
from _tkinter.tcl import TclError, tcl_str, split_list, join_list, get_int, get_boolean, match_prefix, or_list
from _tkinter.util import parse_color
from _tkinter import core as C

_MB_OPTS = ["-default", "-detail", "-icon", "-message", "-parent", "-title", "-type"]
_MB_TYPES = {"abortretryignore": (["abort", "retry", "ignore"], "abort"),
             "ok": (["ok"], "ok"),
             "okcancel": (["ok", "cancel"], "cancel"),
             "retrycancel": (["retry", "cancel"], "cancel"),
             "yesno": (["yes", "no"], "no"),
             "yesnocancel": (["yes", "no", "cancel"], "cancel")}
_MB_LABELS = {"abort": "Abort", "retry": "Retry", "ignore": "Ignore", "ok": "OK", "cancel": "Cancel",
              "yes": "Yes", "no": "No"}


def _opts(args, names, what):
    if len(args) % 2 != 0:
        raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
    out = {}
    for i in range(0, len(args), 2):
        k = tcl_str(args[i])
        if k not in names:
            raise TclError("bad option \"" + k + "\": must be " + or_list(names))
        out[k] = args[i + 1]
    return out


def _ev(app, script):
    return app.interp.eval(script)


def _modal_wait(app, top, done):
    # a grab on the dialog and a nested event loop until it is answered
    try:
        app.interp.invoke(["grab", "set", top])
    except TclError:
        pass
    try:
        while not done() and top in app.widgets:
            if not app.do_one_event(C.DONT_WAIT):
                app.pump_native(10)
    finally:
        try:
            app.interp.invoke(["grab", "release", top])
        except TclError:
            pass


def c_message_box(app, args):
    o = _opts(args, _MB_OPTS, "option")
    icon = tcl_str(o.get("-icon", "info"))
    if icon not in ("error", "info", "question", "warning"):
        raise TclError("bad -icon value \"" + icon + "\": must be error, info, question, or warning")
    typ = tcl_str(o.get("-type", "ok"))
    if typ not in _MB_TYPES:
        raise TclError("bad -type value \"" + typ + "\": must be abortretryignore, ok, okcancel, retrycancel, "
                       "yesno, or yesnocancel")
    names, cancel = _MB_TYPES[typ]
    default = tcl_str(o.get("-default", names[0]))
    if default not in names:
        raise TclError("invalid default button \"" + default + "\"")
    parent = tcl_str(o.get("-parent", "."))
    app.window(parent)
    top = (parent if parent != "." else "") + ".__tk__messagebox"
    if top in app.widgets:
        app.interp.invoke(["destroy", top])
    result = []

    def answer(name):
        if not result:
            result.append(name)
        return ""

    app.interp.invoke(["toplevel", top, "-class", "Dialog"])
    app.interp.invoke(["wm", "title", top, tcl_str(o.get("-title", ""))])
    app.interp.invoke(["wm", "iconname", top, "Dialog"])
    app.interp.invoke(["wm", "protocol", top, "WM_DELETE_WINDOW", "tk::mb_answer" + str(id(result)) + " " + cancel])
    if parent != "." or app.window(".").mapped:
        try:
            app.interp.invoke(["wm", "transient", top, parent])
        except TclError:
            pass
    cmdname = "tk::mb_answer" + str(id(result))
    app.interp.commands[cmdname] = lambda it, words: answer(tcl_str(words[1]))
    app.interp.invoke(["ttk::frame", top + ".bot"])
    app.interp.invoke(["ttk::frame", top + ".top"])
    app.interp.invoke(["pack", top + ".bot", "-side", "bottom", "-fill", "both"])
    app.interp.invoke(["pack", top + ".top", "-side", "top", "-fill", "both", "-expand", "1"])
    app.interp.invoke(["label", top + ".bitmap", "-bitmap", icon])
    app.interp.invoke(["grid", top + ".bitmap", "-in", top + ".top", "-row", 0, "-column", 0, "-rowspan", 2,
                       "-sticky", "nw", "-padx", "2m", "-pady", "2m"])
    app.interp.invoke(["ttk::label", top + ".msg", "-text", tcl_str(o.get("-message", "")), "-wraplength", "3i",
                       "-justify", "left", "-font", "TkCaptionFont"])
    app.interp.invoke(["grid", top + ".msg", "-in", top + ".top", "-row", 0, "-column", 1, "-sticky", "nsw",
                       "-padx", "2m", "-pady", "2m"])
    detail = tcl_str(o.get("-detail", ""))
    if detail:
        app.interp.invoke(["ttk::label", top + ".dtl", "-text", detail, "-wraplength", "3i", "-justify", "left",
                           "-font", "TkDefaultFont"])
        app.interp.invoke(["grid", top + ".dtl", "-in", top + ".top", "-row", 1, "-column", 1, "-sticky", "nsw",
                           "-padx", "2m", "-pady", "0 2m"])
    col = 0
    for n in names:
        b = top + "." + n
        app.interp.invoke(["ttk::button", b, "-text", _MB_LABELS[n], "-command", cmdname + " " + n,
                           "-default", "active" if n == default else "normal"])
        app.interp.invoke(["grid", b, "-in", top + ".bot", "-row", 0, "-column", col, "-padx", "3m", "-pady", "2m",
                           "-sticky", "ew"])
        app.interp.invoke(["grid", "columnconfigure", top + ".bot", col, "-uniform", "buttons"])
        col += 1
    # Return invokes the button with the focus, Escape the cancel button
    app.interp.invoke(["bind", top, "<Return>",
                       "if {[winfo class %W] in {Button TButton}} {%W invoke}"])
    app.interp.invoke(["bind", top, "<Escape>", top + "." + cancel + " invoke" if cancel in names else ""])
    app.update(True)
    app.interp.invoke(["focus", top + "." + default])
    _modal_wait(app, top, lambda: bool(result))
    if top in app.widgets:
        app.interp.invoke(["destroy", top])
    del app.interp.commands[cmdname]
    return result[0] if result else cancel


def c_dialog(app, args):
    # tk_dialog window title text bitmap default string ?string ...?
    if len(args) < 5:
        raise TclError("wrong # args: should be \"tk_dialog w title text bitmap default ?string ...?\"")
    w = tcl_str(args[0])
    title = tcl_str(args[1])
    text = tcl_str(args[2])
    bitmap = tcl_str(args[3])
    default = get_int(args[4])
    strings = [tcl_str(s) for s in args[5:]]
    if w in app.widgets:
        app.interp.invoke(["destroy", w])
    result = []
    cmdname = "tk::dialog_answer" + str(id(result))
    app.interp.commands[cmdname] = lambda it, words: result.append(get_int(words[1])) or ""
    app.interp.invoke(["toplevel", w, "-class", "Dialog"])
    app.interp.invoke(["wm", "title", w, title])
    app.interp.invoke(["wm", "iconname", w, "Dialog"])
    app.interp.invoke(["wm", "protocol", w, "WM_DELETE_WINDOW", cmdname + " -1"])
    app.interp.invoke(["frame", w + ".bot"])
    app.interp.invoke(["frame", w + ".top"])
    app.interp.invoke(["pack", w + ".bot", "-side", "bottom", "-fill", "both"])
    app.interp.invoke(["pack", w + ".top", "-side", "top", "-fill", "both", "-expand", "1"])
    app.interp.invoke(["label", w + ".msg", "-justify", "left", "-text", text, "-font", "TkCaptionFont",
                       "-wraplength", "3i"])
    app.interp.invoke(["pack", w + ".msg", "-in", w + ".top", "-side", "right", "-expand", "1", "-fill", "both",
                       "-padx", "3m", "-pady", "3m"])
    if bitmap:
        app.interp.invoke(["label", w + ".bitmap", "-bitmap", bitmap])
        app.interp.invoke(["pack", w + ".bitmap", "-in", w + ".top", "-side", "left", "-padx", "3m",
                           "-pady", "3m"])
    for i in range(len(strings)):
        b = w + ".button" + str(i)
        app.interp.invoke(["button", b, "-text", strings[i], "-command", cmdname + " " + str(i)])
        if i == default:
            app.interp.invoke([b, "configure", "-default", "active"])
        else:
            app.interp.invoke([b, "configure", "-default", "normal"])
        app.interp.invoke(["grid", b, "-in", w + ".bot", "-column", i, "-row", 0, "-sticky", "ew", "-padx", 10])
    if 0 <= default < len(strings):
        app.interp.invoke(["bind", w, "<Return>", w + ".button" + str(default) + " invoke"])
    app.update(True)
    if 0 <= default < len(strings):
        app.interp.invoke(["focus", w + ".button" + str(default)])
    else:
        app.interp.invoke(["focus", w])
    _modal_wait(app, w, lambda: bool(result))
    if w in app.widgets:
        app.interp.invoke(["destroy", w])
    del app.interp.commands[cmdname]
    return result[0] if result else -1


def _native_file_dialog(app, kind, o):
    # one of the backend's native dialogs, waited for; "" when cancelled
    parent = tcl_str(o.get("-parent", "."))
    w = app.window(parent)
    top = w.top
    if top.native is None:
        app.update()
    if top.native is None:
        return None
    idir = tcl_str(o.get("-initialdir", ""))
    ifile = tcl_str(o.get("-initialfile", ""))
    loc = os.path.join(idir, ifile) if idir else ifile
    if not loc:
        loc = os.getcwd() + os.sep
    title = tcl_str(o.get("-title", ""))
    app.dialog_waiter = []
    try:
        if kind == "save":
            ok = gui_show_save_dialog(top.native, title, loc)
        else:
            ok = gui_show_open_dialog(top.native, title, loc, 1 if kind == "dir" else 0)
        if not ok:
            return None
        while not app.dialog_waiter:
            if not app.do_one_event(C.DONT_WAIT):
                app.pump_native(20)
        btn, text = app.dialog_waiter[0]
    finally:
        app.dialog_waiter = None
    return text if text else None


_OPEN_OPTS = ["-defaultextension", "-filetypes", "-initialdir", "-initialfile", "-multiple", "-parent", "-title",
              "-typevariable"]
_SAVE_OPTS = ["-confirmoverwrite", "-defaultextension", "-filetypes", "-initialdir", "-initialfile", "-parent",
              "-title", "-typevariable"]


def _check_filetypes(v):
    for ft in (v if isinstance(v, (tuple, list)) else split_list(tcl_str(v))):
        parts = ft if isinstance(ft, (tuple, list)) else split_list(tcl_str(ft))
        if len(parts) not in (2, 3):
            raise TclError("bad file type \"" + join_list(parts) + "\", should be \"typeName {extension ?extensions ...?} ?{macType ?macTypes ...?}?\"")


def c_get_open_file(app, args):
    o = _opts(args, _OPEN_OPTS, "option")
    if "-filetypes" in o:
        _check_filetypes(o["-filetypes"])
    multi = get_boolean(o["-multiple"]) if "-multiple" in o else False
    r = _native_file_dialog(app, "open", o)
    if r is None:
        return () if multi else ""
    return (r,) if multi else r


def c_get_save_file(app, args):
    o = _opts(args, _SAVE_OPTS, "option")
    if "-filetypes" in o:
        _check_filetypes(o["-filetypes"])
    r = _native_file_dialog(app, "save", o)
    if r is None:
        return ""
    ext = tcl_str(o.get("-defaultextension", ""))
    if ext and not os.path.splitext(r)[1]:
        r = r + (ext if ext.startswith(".") else "." + ext)
    return r


def c_choose_directory(app, args):
    o = _opts(args, ["-initialdir", "-mustexist", "-parent", "-title"], "option")
    r = _native_file_dialog(app, "dir", o)
    if r is None:
        return ""
    return r.rstrip(os.sep) if len(r) > 1 else r


def c_choose_color(app, args):
    # tk_chooseColor -initialcolor -parent -title: red, green and blue
    # scales, the #rrggbb entry and a sample (clrpick.tcl's choices)
    o = _opts(args, ["-initialcolor", "-parent", "-title"], "option")
    init = tcl_str(o.get("-initialcolor", ""))
    c = parse_color(init) if init else 0xd9d9d9
    parent = tcl_str(o.get("-parent", "."))
    app.window(parent)
    top = (parent if parent != "." else "") + ".__tk__color"
    if top in app.widgets:
        app.interp.invoke(["destroy", top])
    result = []
    rgb = [(c >> 16) & 255, (c >> 8) & 255, c & 255]
    key = str(id(result))
    cmd_ok = "tk::color_ok" + key
    cmd_cancel = "tk::color_cancel" + key
    cmd_set = "tk::color_set" + key

    def hexs():
        return "#%02x%02x%02x" % (rgb[0], rgb[1], rgb[2])

    def refresh():
        if top + ".sample" in app.widgets:
            app.interp.invoke([top + ".sample", "configure", "-background", hexs()])
            app.interp.invoke([top + ".entry", "delete", 0, "end"])
            app.interp.invoke([top + ".entry", "insert", 0, hexs()])

    def setc(i, v):
        try:
            rgb[i] = max(0, min(255, int(float(tcl_str(v)))))
        except ValueError:
            return ""
        refresh()
        return ""

    def ok():
        s = tcl_str(app.interp.invoke([top + ".entry", "get"]))
        try:
            v = parse_color(s)
            result.append("#%06x" % v if s.startswith("#") else s)
        except TclError:
            result.append(hexs())
        return ""

    title = tcl_str(o.get("-title", "Choose Color"))
    app.interp.commands[cmd_ok] = lambda it, w: ok()
    app.interp.commands[cmd_cancel] = lambda it, w: result.append("") or ""
    app.interp.commands[cmd_set] = lambda it, w: setc(get_int(w[1]), w[2])
    app.interp.invoke(["toplevel", top, "-class", "TkColorDialog"])
    app.interp.invoke(["wm", "title", top, title])
    app.interp.invoke(["wm", "protocol", top, "WM_DELETE_WINDOW", cmd_cancel])
    for i, nm in enumerate(("Red", "Green", "Blue")):
        app.interp.invoke(["scale", top + ".s" + str(i), "-label", nm, "-from", 0, "-to", 255, "-orient",
                           "horizontal", "-length", 200, "-command", cmd_set + " " + str(i)])
        app.interp.invoke([top + ".s" + str(i), "set", rgb[i]])
        app.interp.invoke(["pack", top + ".s" + str(i), "-side", "top", "-fill", "x", "-padx", 4])
    app.interp.invoke(["frame", top + ".sample", "-width", 60, "-height", 24, "-relief", "sunken",
                       "-borderwidth", 2, "-background", hexs()])
    app.interp.invoke(["pack", top + ".sample", "-side", "top", "-fill", "x", "-padx", 4, "-pady", 4])
    app.interp.invoke(["entry", top + ".entry", "-width", 10])
    app.interp.invoke([top + ".entry", "insert", 0, hexs()])
    app.interp.invoke(["pack", top + ".entry", "-side", "top", "-padx", 4])
    app.interp.invoke(["frame", top + ".bot"])
    app.interp.invoke(["pack", top + ".bot", "-side", "bottom", "-fill", "x"])
    app.interp.invoke(["button", top + ".ok", "-text", "OK", "-width", 8, "-command", cmd_ok, "-default", "active"])
    app.interp.invoke(["button", top + ".cancel", "-text", "Cancel", "-width", 8, "-command", cmd_cancel])
    app.interp.invoke(["pack", top + ".ok", top + ".cancel", "-in", top + ".bot", "-side", "left", "-expand", 1,
                       "-padx", 4, "-pady", 4])
    app.interp.invoke(["bind", top, "<Return>", cmd_ok])
    app.interp.invoke(["bind", top, "<Escape>", cmd_cancel])
    app.update(True)
    app.interp.invoke(["focus", top + ".entry"])
    _modal_wait(app, top, lambda: bool(result))
    if top in app.widgets:
        app.interp.invoke(["destroy", top])
    for n in (cmd_ok, cmd_cancel, cmd_set):
        app.interp.commands.pop(n, None)
    return result[0] if result else ""


for _name, _f in (("tk_messageBox", c_message_box), ("tk_dialog", c_dialog), ("tk_getOpenFile", c_get_open_file),
                  ("tk_getSaveFile", c_get_save_file), ("tk_chooseDirectory", c_choose_directory),
                  ("tk_chooseColor", c_choose_color)):
    C.TK_COMMANDS[_name] = _f
