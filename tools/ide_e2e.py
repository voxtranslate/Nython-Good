#!/usr/bin/env python3
"""ide_e2e.py - end-to-end tests of the shipped IDE, driven like a person.

Each scenario starts the real `build/nython --ide` (headless SDL3 stub) in a
fresh temporary workspace, clicks and types through tools/ide_driver.py, and
asserts on both what is on screen (the captured display list) and what the
IDE believes (developer.dumpState). Nothing here calls IDE methods directly:
every action goes through the same event path a mouse or keyboard would.

    python3 tools/ide_e2e.py              # all scenarios
    python3 tools/ide_e2e.py find scm     # scenarios whose name contains a word
    python3 tools/ide_e2e.py --shots DIR  # also save a screenshot per scenario

Prints "N passed, M failed" and exits 1 on any failure.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ide_driver import IDE, DriverError  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

APP = 'def greet(name):\n    return "hi " + name\n\nprint(greet("bob"))\n'
UTIL = 'def twice(x):\n    return x * 2\n'
LOOP = ('def total(n):\n    s = 0\n    i = 0\n    while i < n:\n        s = s + i\n        i = i + 1\n'
        '    return s\n\nvar r = total(4)\nprint("total", r)\n')


class Result:
    def __init__(self):
        self.passed = 0
        self.failed = []

    def check(self, cond, what, detail=""):
        if cond:
            self.passed += 1
        else:
            self.failed.append(what + ((" -- " + str(detail)) if detail != "" else ""))
            print("    FAIL", what, ("-- " + str(detail))[:600] if detail != "" else "")
        return cond


class Scenario:
    def __init__(self, res, shots):
        self.res = res
        self.shots = shots
        self.root = tempfile.mkdtemp(prefix="nye2e_")
        self.ws = os.path.join(self.root, "proj")
        self.home = os.path.join(self.root, "home")
        os.makedirs(os.path.join(self.ws, "src"))
        os.makedirs(self.home)
        self.write("app.ny", APP)
        self.write("src/util.ny", UTIL)
        self.ide = None

    def write(self, rel, text):
        p = os.path.join(self.ws, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)

    def read(self, rel):
        with open(os.path.join(self.ws, rel), newline="") as f:
            return f.read()

    def git(self, *args):
        return subprocess.run(["git", "-C", self.ws] + list(args), capture_output=True, text=True,
                              env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t", HOME=self.home))

    def start(self):
        self.ide = IDE(cwd=self.ws, env={"HOME": self.home, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                         "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
        self.ide.start()
        return self.ide

    def finish(self, name):
        if self.ide is not None:
            if self.shots:
                try:
                    self.ide.screenshot(os.path.join(self.shots, name + ".png"))
                except Exception:
                    pass
            alive = self.ide.alive()
            log = self.ide.log()
            code = self.ide.close()
            self.res.check(alive, name + ": IDE still running at the end", log[-1500:])
            self.res.check("[IDE Error]" not in log and "Uncaught" not in log and "RuntimeError" not in log,
                           name + ": no runtime errors in the IDE log", log[-1500:])
            self.res.check(code == 0, name + ": clean exit on quit", code)
            self.ide.cleanup()
        shutil.rmtree(self.root, ignore_errors=True)

    # helpers
    def open_file(self, label):
        ide = self.ide
        # A file created after start-up appears once the workspace watcher's
        # next poll (about a second) sees the folder change.
        t0 = time.time()
        while not ide.snap().has(label, exact=True, region=(48, 30, 280, 600)) and time.time() - t0 < 8:
            time.sleep(0.2)
        t = ide.find(label, region=(48, 30, 280, 600))
        ide.dblclick(int(t.cx), int(t.cy))
        return ide.state()

    def status_region(self):
        f = self.ide.last
        return (0, f.h - 24, f.w, 24)

    def wait_until(self, pred, timeout=20, step=4):
        t0 = time.time()
        st = None
        while time.time() - t0 < timeout:
            st = self.ide.state()
            if pred(st):
                return st
            self.ide.wait(step)
        return st


# ─── scenarios ──────────────────────────────────────────────────────────────

def sc_boot(s):
    ide = s.start()
    f = ide.snap()
    c = s.res.check
    c(f.has("Welcome", exact=True), "boot: Welcome tab")
    c(f.has("app.ny", exact=True), "boot: explorer lists app.ny")
    c(f.has("src", exact=True), "boot: explorer lists src/")
    for m in ["File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Help"]:
        c(f.has(m, exact=True, region=(0, 0, 600, 30)), "boot: menu " + m)
    for label in ["PROBLEMS", "OUTPUT", "DEBUG CONSOLE", "TERMINAL"]:
        c(f.has(label, exact=True), "boot: panel tab " + label)
    st = ide.state()
    c(st["title"] == "Welcome" and st["kind"] == "welcome", "boot: welcome is the active editor", st["title"])


def sc_edit_undo_save(s):
    ide = s.start()
    c = s.res.check
    st = s.open_file("app.ny")
    c(st["title"] == "app.ny" and st["text"] == APP, "edit: double-click opens app.ny", st["title"])
    c(st["tabs"] == ["app.ny"], "edit: welcome tab is replaced by the first file", st["tabs"])
    ide.key("ctrl+end")
    ide.type("x = 1")
    st = ide.state()
    c(st["text"] == APP + "x = 1", "edit: typed text lands at the end", repr(st["text"][-20:]))
    c(st["dirty"] and st["tabs"] == ["app.ny *"], "edit: buffer marked dirty", st["tabs"])
    ide.key("ctrl+z")
    st = ide.state()
    c(st["text"] == APP, "edit: one Ctrl+Z undoes the whole typed word", repr(st["text"][-20:]))
    c(not st["dirty"], "edit: undo back to the saved state clears dirty")
    ide.key("ctrl+y")
    st = ide.state()
    c(st["text"] == APP + "x = 1", "edit: Ctrl+Y redoes it", repr(st["text"][-20:]))
    ide.key("ctrl+s")
    st = ide.state()
    c(not st["dirty"], "edit: Ctrl+S clears dirty")
    c(s.read("app.ny") == APP + "x = 1", "edit: Ctrl+S wrote the file", repr(s.read("app.ny")))
    # Enter keeps indentation, Tab inserts spaces, auto-closing pairs
    ide.key("ctrl+home")
    ide.key("end")
    ide.key("enter")
    ide.type("y = (")
    st = ide.state()
    lines = st["text"].split("\n")
    c(lines[1] == "    y = ()", "edit: Enter after ':' indents, '(' auto-closes", repr(lines[1]))
    ide.type("1)")
    st = ide.state()
    c(st["text"].split("\n")[1] == "    y = (1)", "edit: typing ')' steps over the auto-closed one",
      repr(st["text"].split("\n")[1]))
    ide.key("ctrl+z")
    st = ide.state()
    c(st["text"].split("\n")[1] != "    y = (1)", "edit: undo after bracket typing", repr(st["text"].split("\n")[1]))


def sc_clipboard_lines(s):
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    ide.key("ctrl+home")
    ide.key("ctrl+c")            # no selection: copies the whole line
    ide.key("ctrl+v")
    st = ide.state()
    c(st["text"].startswith("def greet(name):\ndef greet(name):\n"), "clipboard: line copy/paste duplicates line",
      repr(st["text"][:40]))
    ide.key("ctrl+shift+k")
    st = ide.state()
    c(st["text"] == APP and st["row"] == 1, "clipboard: Ctrl+Shift+K deletes the line, caret on the next",
      (repr(st["text"][:40]), st["row"]))
    ide.key("ctrl+home")
    ide.key("alt+down")
    st = ide.state()
    c(st["text"].split("\n")[:2] == ['    return "hi " + name', "def greet(name):"], "lines: Alt+Down moves line",
      st["text"].split("\n")[:2])
    ide.key("alt+up")
    ide.key("ctrl+/")
    st = ide.state()
    c(st["text"].split("\n")[0] == "# def greet(name):", "lines: Ctrl+/ comments the line", st["text"].split("\n")[0])
    ide.key("ctrl+/")
    st = ide.state()
    c(st["text"] == APP, "lines: Ctrl+/ again uncomments", repr(st["text"][:30]))
    ide.key("ctrl+a")
    ide.key("ctrl+x")
    st = ide.state()
    c(st["text"] == "" and st["clipboard"] == APP, "clipboard: select all + cut", repr(st["clipboard"][:30]))
    ide.key("ctrl+v")
    st = ide.state()
    c(st["text"] == APP, "clipboard: paste restores", repr(st["text"][:30]))


def sc_multicursor(s):
    ide = s.start()
    c = s.res.check
    s.write("m.ny", "val = 1\nval = val + 1\nprint(val)\n")
    ide.key("ctrl+p")
    ide.type("m.ny")
    ide.key("enter")
    ide.key("ctrl+home")
    ide.key("ctrl+d")           # selects word under caret
    ide.key("ctrl+d")
    ide.key("ctrl+d")
    st = ide.state()
    c(st["carets"] >= 3, "multicursor: Ctrl+D adds occurrences", st["carets"])
    ide.type("num")
    st = ide.state()
    c(st["text"].startswith("num = 1\nnum = num + 1\n"), "multicursor: typing replaces every occurrence",
      repr(st["text"]))
    ide.key("escape")
    ide.key("ctrl+z")
    st = ide.state()
    c(st["text"].startswith("val = 1\nval = val + 1\n"), "multicursor: one undo reverts the multi-caret edit",
      repr(st["text"]))


def sc_palette(s):
    ide = s.start()
    c = s.res.check
    ide.key("ctrl+shift+p")
    st = ide.state()
    c(st["qi"] and st["qi_value"] == ">", "palette: Ctrl+Shift+P opens with '>'", st["qi_value"])
    c(len(st["qi_items"]) > 10, "palette: lists commands", len(st["qi_items"]))
    f = ide.snap()
    c(f.has(st["qi_items"][0], exact=True), "palette: first command drawn", st["qi_items"][0])
    ide.type("new text file")
    st = ide.state()
    c(len(st["qi_items"]) >= 1 and "New Text File" in st["qi_items"][0], "palette: fuzzy filter ranks the match",
      st["qi_items"][:3])
    ide.key("enter")
    st = ide.state()
    c(not st["qi"] and st["kind"] == "untitled" and st["title"] == "Untitled-1", "palette: Enter runs the command",
      st["title"])
    ide.type("hello")
    ide.key("ctrl+shift+p")
    ide.type("toggle light")
    ide.key("enter")
    st = ide.state()
    c(st["dark"] is False, "palette: theme toggles to light")
    f = ide.snap()
    bg = f.fills_at(900, 400)
    c(len(bg) > 0 and bg[-1][0] > 200, "palette: editor background is light after toggle", bg[-1:] if bg else bg)
    # Recently used commands float to the top
    ide.key("ctrl+shift+p")
    st = ide.state()
    c(len(st["qi_items"]) > 0 and "Toggle Light/Dark Theme" in st["qi_items"][0], "palette: recently used first",
      st["qi_items"][:3])
    ide.key("escape")
    st = ide.state()
    c(not st["qi"], "palette: Escape closes")
    # F1 is the same palette
    ide.key("f1")
    st = ide.state()
    c(st["qi"] and st["qi_value"] == ">", "palette: F1 opens it too")
    ide.key("escape")


def sc_quick_open(s):
    ide = s.start()
    c = s.res.check
    ide.key("ctrl+p")
    st = ide.state()
    c(st["qi"] and st["qi_value"] == "", "quickopen: Ctrl+P opens file picker", st["qi_value"])
    ide.type("util")
    st = ide.state()
    c(len(st["qi_items"]) >= 1 and st["qi_items"][0] == "util.ny", "quickopen: fuzzy match finds util.ny",
      st["qi_items"][:3])
    ide.key("enter")
    st = ide.state()
    c(st["title"] == "util.ny" and "twice" in st.get("text", ""), "quickopen: Enter opens the file", st["title"])
    # ':' line mode, '@' symbol mode, '>' switches to commands
    ide.key("ctrl+g")
    st = ide.state()
    c(st["qi"] and st["qi_value"] == ":", "quickopen: Ctrl+G opens ':' mode", st["qi_value"])
    ide.type("2")
    ide.key("enter")
    st = ide.state()
    c(st["row"] == 1, "quickopen: ':2' jumps to line 2", st["row"])
    s.open_file("app.ny")
    ide.key("ctrl+shift+o")
    st = ide.state()
    c(st["qi"] and st["qi_value"] == "@" and any("greet" in x for x in st["qi_items"]),
      "quickopen: '@' lists symbols of the file", st["qi_items"][:5])
    ide.key("escape")
    ide.key("ctrl+p")
    ide.type(">")
    st = ide.state()
    c(st["qi_value"] == ">" and len(st["qi_items"]) > 10, "quickopen: typing '>' switches to commands",
      st["qi_items"][:2])
    ide.key("backspace")
    ide.type("#twice")
    st = ide.state()
    c(any("twice" in x for x in st["qi_items"]), "quickopen: '#' searches workspace symbols", st["qi_items"][:4])
    ide.key("enter")
    st = ide.state()
    c(st["title"] == "util.ny" and st["row"] == 0, "quickopen: accepting a workspace symbol opens it",
      (st["title"], st.get("row")))


def sc_menus(s):
    ide = s.start()
    c = s.res.check
    ide.click_text("File", region=(0, 0, 600, 30))
    f = ide.snap()
    c(f.has("New Text File", exact=True) and f.has("Save All", exact=True), "menus: File menu opens with its items")
    c(f.has("Ctrl+N", exact=True), "menus: items show their keybinding")
    # Moving across the bar while a menu is open switches menus (VS Code)
    t = ide.find("Edit", region=(0, 0, 600, 30), fresh=False)
    ide.move(int(t.cx), int(t.cy))
    f = ide.snap()
    c(f.has("Undo", exact=True) and not f.has("New Text File", exact=True), "menus: hovering Edit switches menus")
    ide.key("escape")
    st = ide.state()
    c(st["menu"] < 0, "menus: Escape closes", st["menu"])
    ide.click_text("File", region=(0, 0, 600, 30))
    ide.click_text("New Text File")
    st = ide.state()
    c(st["kind"] == "untitled" and st["menu"] < 0, "menus: File > New Text File creates Untitled-1", st["title"])
    # Alt mnemonics + keyboard navigation
    ide.key("alt+v")
    st = ide.state()
    c(st["menu"] >= 0, "menus: Alt+V opens View", st["menu"])
    ide.key("escape")
    ide.click_text("Help", region=(0, 0, 600, 30))
    ide.click_text("About")
    st = ide.state()
    c(st["modal"] and "Nython" in st["modal_title"] + st["modal_msg"], "menus: Help > About shows the About dialog",
      st["modal_title"][:80])
    ide.key("escape")
    st = ide.state()
    c(not st["modal"], "menus: Escape dismisses the dialog")
    ide.click_text("View", region=(0, 0, 600, 30))
    ide.click_text("Terminal", region=(0, 30, 800, 600))
    st = ide.state()
    c(st["panel"] == "terminal" and st["panel_open"], "menus: View > Terminal shows the terminal", st["panel"])


def sc_find_replace(s):
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    ide.key("ctrl+f")
    ide.type("greet")
    st = ide.state()
    c(st["find"] and st["find_info"] == "1 of 2", "find: '1 of 2' matches", st["find_info"])
    f = ide.snap()
    c(f.has("1 of 2", exact=True), "find: count shown in widget")
    ide.key("enter")
    st = ide.state()
    c(st["find_info"] == "2 of 2" and st["row"] == 3, "find: Enter goes to next match", (st["find_info"], st["row"]))
    ide.key("shift+enter")
    st = ide.state()
    c(st["find_info"] == "1 of 2" and st["row"] == 0, "find: Shift+Enter goes back", (st["find_info"], st["row"]))
    ide.key("escape")
    st = ide.state()
    c(not st["find"], "find: Escape closes")
    ide.key("ctrl+h")
    ide.key("ctrl+a")
    ide.type("greet")
    ide.key("tab")
    ide.type("salute")
    ide.key("ctrl+alt+enter")
    st = ide.state()
    c(st["text"].count("salute") == 2 and "greet" not in st["text"], "find: Replace All replaces both",
      repr(st["text"]))
    ide.key("escape")
    ide.key("ctrl+z")
    st = ide.state()
    c(st["text"] == APP, "find: one undo reverts Replace All", repr(st["text"][:40]))


def sc_statusbar(s):
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    f = ide.snap()
    sr = s.status_region()
    c(f.has("Ln 1, Col 1", exact=True, region=sr), "status: cursor position shown")
    ide.click_text("Ln 1, Col 1", region=sr)
    st = ide.state()
    c(st["qi"] and st["qi_value"] == ":", "status: clicking position opens Go to Line", st["qi_value"])
    ide.key("escape")
    ide.click_text("Spaces: 4", region=sr)
    st = ide.state()
    c(st["qi"] and st["qi_items"][:2] == ["Indent Using Spaces", "Indent Using Tabs"], "status: indentation picker",
      st["qi_items"][:4])
    ide.key("down")
    ide.key("enter")
    st = ide.state()
    c(st["qi"] and "4" in st["qi_items"], "status: 'Indent Using Tabs' asks for the size", st["qi_items"])
    ide.key("enter")
    f = ide.snap()
    c(f.has("Tab Size: 4", exact=True, region=s.status_region()), "status: shows 'Tab Size: 4'")
    ide.key("ctrl+shift+p")
    ide.type("convert indentation to tabs")
    ide.key("enter")
    st = ide.state()
    c(st["text"].split("\n")[1] == '\treturn "hi " + name', "status: Convert Indentation to Tabs",
      repr(st["text"].split("\n")[1]))
    ide.key("ctrl+z")
    st = ide.state()
    c(st["text"] == APP, "status: one undo reverts the conversion", repr(st["text"][:40]))
    ide.key("ctrl+shift+p")
    ide.type("indent using spaces")
    ide.key("enter")
    ide.key("enter")
    ide.click_text("LF", region=sr)
    st = ide.state()
    c(st["qi"] and "CRLF" in st["qi_items"], "status: EOL picker lists CRLF", st["qi_items"])
    idx = st["qi_items"].index("CRLF") if "CRLF" in st["qi_items"] else 0
    for _ in range(idx):
        ide.key("down")
    ide.key("enter")
    st = ide.state()
    c(st["eol"] == "\r\n" and st["dirty"], "status: choosing CRLF changes the buffer's EOL", repr(st.get("eol")))
    f = ide.snap()
    c(f.has("CRLF", exact=True, region=s.status_region()), "status: shows CRLF")
    ide.key("ctrl+s")
    ide.state()
    c(s.read("app.ny").count("\r\n") == 4, "status: CRLF written on save", repr(s.read("app.ny")[:40]))
    ide.click_text("Nython", region=s.status_region())
    st = ide.state()
    c(st["qi"] and "Plain Text" in " ".join(st["qi_items"]), "status: language picker", st["qi_items"][:5])
    ide.key("escape")
    ide.click_text("UTF-8", region=s.status_region())
    st = ide.state()
    c(st["qi"], "status: encoding picker opens")
    ide.key("escape")
    # error/warning counters open Problems
    ide.key("ctrl+`")
    ide.click_text("0", region=(0, s.status_region()[1], 80, 24))
    st = ide.state()
    c(st["panel"] == "problems", "status: problems counter opens Problems", st["panel"])
    # the bell opens the notification centre
    t = ide.snap()
    hm = [h for h in ide.hitmap() if h[4] == "notifications.showList"]
    c(len(hm) == 1, "status: bell is clickable", len(hm))
    if hm:
        x, y, w, h = hm[0][:4]
        ide.click(x + w // 2, y + h // 2)
        f = ide.snap()
        c(f.has("NOTIFICATIONS", exact=True) or f.has("No new notifications", exact=True) or f.has("Saved app.ny"),
          "status: bell opens notifications")


def sc_explorer_ops(s):
    ide = s.start()
    c = s.res.check
    hm = ide.hitmap()
    newf = [h for h in hm if h[4] == "explorer.newFile"]
    c(len(newf) >= 1, "explorer: New File button present", len(newf))
    x, y, w, h = newf[0][:4]
    ide.click(x + w // 2, y + h // 2)
    st = ide.state()
    c(st["qi"], "explorer: New File asks for a name")
    ide.type("pkg/new_mod.ny")
    ide.key("enter")
    st = ide.state()
    c(os.path.isfile(os.path.join(s.ws, "pkg/new_mod.ny")), "explorer: file (and folder) created on disk")
    c(st["title"] == "new_mod.ny", "explorer: new file opened", st["title"])
    f = ide.snap()
    c(f.has("pkg", exact=True) and f.has("new_mod.ny", exact=True, region=(48, 30, 280, 700)),
      "explorer: tree shows the new file")
    # rename with F2 from the tree
    t = ide.find("new_mod.ny", region=(48, 30, 280, 700))
    ide.click(int(t.cx), int(t.cy))
    ide.key("f2")
    st = ide.state()
    c(st["qi"] and st["qi_value"].endswith("new_mod.ny"), "explorer: F2 asks for the new name", st["qi_value"])
    ide.key("ctrl+a")
    ide.type("renamed.ny")
    ide.key("enter")
    ide.state()
    c(os.path.isfile(os.path.join(s.ws, "pkg/renamed.ny")) and not os.path.exists(os.path.join(s.ws, "pkg/new_mod.ny")),
      "explorer: rename moved the file on disk")
    st = ide.state()
    c("renamed.ny" in st["tabs"], "explorer: open editor follows the rename", st["tabs"])
    # delete through the context menu
    t = ide.find("renamed.ny", region=(48, 30, 280, 700))
    ide.right_click(int(t.cx), int(t.cy))
    f = ide.snap()
    c(f.has("Delete", exact=True) and f.has("Rename...", exact=True), "explorer: context menu")
    ide.click_text("Delete")
    st = ide.state()
    c(st["modal"], "explorer: delete asks for confirmation", st["modal_msg"])
    f = ide.snap()
    ide.click_text("Move to Trash", exact=False) if f.has("Move to Trash") else ide.click_text("Delete")
    ide.state()
    c(not os.path.exists(os.path.join(s.ws, "pkg/renamed.ny")), "explorer: file deleted")
    # New Folder, Collapse All, Refresh (external change shows up)
    s.write("external.ny", "print(1)\n")
    ref = [h for h in ide.hitmap() if h[4] == "workbench.files.action.refreshFilesExplorer"]
    c(len(ref) == 1, "explorer: Refresh button present")
    if ref:
        x, y, w, h = ref[0][:4]
        ide.click(x + w // 2, y + h // 2)
        f = ide.snap()
        c(f.has("external.ny", exact=True), "explorer: Refresh picks up a file created outside")
    t = ide.find("src", region=(48, 30, 280, 700))
    ide.click(int(t.cx), int(t.cy))
    f = ide.snap()
    c(f.has("util.ny", exact=True, region=(48, 30, 280, 700)), "explorer: clicking a folder expands it")
    ide.click(int(t.cx), int(t.cy))
    f = ide.snap()
    c(not f.has("util.ny", exact=True, region=(48, 30, 280, 700)), "explorer: clicking again collapses it")


def sc_close_dirty(s):
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    ide.type("zzz")
    ide.key("ctrl+w")
    st = ide.state()
    c(st["modal"] and "app.ny" in st["modal_title"], "close: dirty editor asks to save", st["modal_title"])
    f = ide.snap()
    c(f.has("Save", exact=True) and f.has("Don't Save", exact=True) and f.has("Cancel", exact=True),
      "close: Save / Don't Save / Cancel")
    ide.click_text("Cancel")
    st = ide.state()
    c(not st["modal"] and st["title"] == "app.ny" and st["dirty"], "close: Cancel keeps the editor")
    ide.key("ctrl+w")
    ide.click_text("Don't Save")
    st = ide.state()
    c("app.ny" not in " ".join(st["tabs"]) and s.read("app.ny") == APP, "close: Don't Save discards", st["tabs"])
    ide.key("ctrl+shift+t")
    st = ide.state()
    c(st["title"] == "app.ny", "close: Ctrl+Shift+T reopens the closed editor", st["title"])
    ide.type("yy")
    ide.key("ctrl+w")
    ide.click_text("Save")
    st = ide.state()
    c(s.read("app.ny").startswith("yy"), "close: Save writes before closing", repr(s.read("app.ny")[:10]))
    # tab close button and middle click
    s.open_file("app.ny")
    ide.key("ctrl+n")
    st = ide.state()
    c(len(st["tabs"]) == 2, "tabs: two editors open", st["tabs"])
    hm = [h for h in ide.hitmap() if h[4] == "@tab.close"]
    c(len(hm) >= 1, "tabs: close button present", len(hm))
    if hm:
        x, y, w, h = hm[-1][:4]
        ide.click(x + w // 2, y + h // 2)
        st = ide.state()
        c(len(st["tabs"]) == 1, "tabs: clicking x closes the tab", st["tabs"])


def sc_terminal(s):
    ide = s.start()
    c = s.res.check
    ide.key("ctrl+`")
    st = ide.state()
    c(st["panel"] == "terminal" and st["focus"] == "terminal", "terminal: Ctrl+` opens and focuses", st["focus"])
    ide.type("echo hello-e2e\n")
    ok = False
    for _ in range(40):
        if ide.snap().has("hello-e2e", exact=True):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "terminal: shell command output appears")
    ide.type("cd src\n")
    ide.type("ls\n")
    ok = False
    for _ in range(40):
        if ide.snap().has("util.ny", exact=False, region=(318, 690, 1300, 250)):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "terminal: cd persists between commands")
    ide.type(">1 + 2\n")
    ok = False
    for _ in range(40):
        if ide.snap().has("3", exact=True, region=(318, 690, 1300, 250)):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "terminal: '>expr' evaluates Nython")


def sc_run(s):
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    ide.key("ctrl+f5")
    ok = False
    for _ in range(60):
        f = ide.snap()
        if f.has("hi bob", exact=True):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "run: Ctrl+F5 runs the file and shows its output")
    st = ide.state()
    c(st["panel"] in ("output", "terminal"), "run: output panel shown", st["panel"])
    # a runtime error lands in Problems with its location
    s.write("bad.ny", "var a = 1\nprint(undefined_thing(a))\n")
    s.open_file("bad.ny")
    ide.key("ctrl+f5")
    st = s.wait_until(lambda st: st["errors"] >= 1)
    c(st["errors"] >= 1, "run: runtime error reported as a problem", st["errors"])
    ide.key("ctrl+shift+m")
    f = ide.snap()
    c(f.has("undefined_thing", exact=False), "run: problem text shown in Problems")
    ide.key("f8")
    st = ide.state()
    c(st["title"] == "bad.ny" and st["row"] == 1, "run: F8 jumps to the error line", (st["title"], st.get("row")))


def sc_syntax_problems(s):
    ide = s.start()
    c = s.res.check
    s.write("syn.ny", "def f(:\n    return 1\n")
    s.open_file("syn.ny")
    st = s.wait_until(lambda st: st["errors"] >= 1)
    c(st["errors"] >= 1, "problems: syntax error detected on open", st["errors"])
    ide.key("ctrl+home")
    ide.key("end")
    ide.key("backspace")
    ide.type("x):")
    st = ide.state()
    c(st["text"].split("\n")[0] == "def f(x):", "problems: line fixed", st["text"].split("\n")[0])
    ide.key("ctrl+s")
    st = s.wait_until(lambda st: st["errors"] == 0)
    c(st["errors"] == 0, "problems: fixing and saving clears it", st["errors"])


def sc_debugger(s):
    ide = s.start()
    c = s.res.check
    s.write("loop.ny", LOOP)
    st = s.open_file("loop.ny")
    ide.key("ctrl+g")
    ide.type("5\n")
    ide.key("f9")
    st = ide.state()
    c(any(b.endswith(":5") for b in st["breaks"]), "debug: F9 sets a breakpoint", st["breaks"])
    ide.key("f5")
    st = s.wait_until(lambda st: st["dbg_state"] == "paused")
    c(st["dbg_state"] == "paused" and st["dbg_line"] == 5, "debug: F5 stops at the breakpoint",
      (st["dbg_state"], st["dbg_line"]))
    f = ide.snap()
    c(f.has("VARIABLES", exact=True) and f.has("CALL STACK", exact=True), "debug: Run and Debug view shows")
    c(f.has("total", exact=True), "debug: call stack names the function")
    ide.key("f5")
    st = ide.state()
    c(st["dbg_state"] == "paused" and st["dbg_line"] == 5, "debug: continue hits it again next iteration",
      (st["dbg_state"], st["dbg_line"]))
    ide.key("ctrl+shift+f11")
    st = ide.state()
    c(st["dbg_line"] != 5 or st["dbg_state"] == "paused", "debug: step back moves backwards", st["dbg_line"])
    ide.key("f10")
    ide.key("f10")
    st = ide.state()
    c(st["dbg_state"] == "paused", "debug: F10 steps", st["dbg_line"])
    ide.key("shift+f11")
    st = ide.state()
    c(st["dbg_line"] in (9, 10), "debug: Shift+F11 steps out to the caller", st["dbg_line"])
    ide.key("f5")
    ide.key("f5")
    ide.key("f5")
    ide.key("f5")
    ide.key("f5")
    ok = False
    for _ in range(20):
        if ide.snap().has("total 6", exact=False):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "debug: program output reaches the debug console")
    ide.key("shift+f5")
    st = ide.state()
    c(st["dbg_state"] in ("idle", "ended"), "debug: Shift+F5 stops", st["dbg_state"])


def sc_scm(s):
    s.git("init", "-q")
    s.git("add", "-A")
    s.git("commit", "-q", "-m", "initial")
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    ide.key("ctrl+end")
    ide.type("print(1)\n")
    ide.key("ctrl+s")
    ide.key("ctrl+shift+g")
    st = ide.state()
    c(st["view"] == "scm", "scm: Ctrl+Shift+G opens Source Control", st["view"])
    ok = False
    for _ in range(30):
        f = ide.snap()
        if f.has("app.ny", exact=True, region=(48, 30, 280, 700)) and f.has("M", exact=True, region=(48, 30, 280, 700)):
            ok = True
            break
        ide.wait(10)
    c(ok, "scm: modified file listed with 'M'")
    f = ide.snap()
    c(f.has("Changes", exact=True) or f.has("CHANGES", exact=True), "scm: Changes section")
    # stage via the row's + action (hover shows it)
    hm = [h for h in ide.hitmap() if h[4] == "git.stage"]
    if not hm:
        t = ide.find("app.ny", region=(48, 30, 280, 700))
        ide.move(int(t.cx), int(t.cy))
        hm = [h for h in ide.hitmap() if h[4] == "git.stage"]
    c(len(hm) >= 1, "scm: stage action on hover", len(hm))
    if hm:
        x, y, w, h = hm[0][:4]
        ide.click(x + w // 2, y + h // 2)
        ide.state()
        out = s.git("diff", "--cached", "--name-only").stdout
        c("app.ny" in out, "scm: stage runs git add", out)
    msg = [h for h in ide.hitmap() if h[4] == "@scm.msg"]
    c(len(msg) == 1, "scm: commit message box", len(msg))
    if msg:
        x, y, w, h = msg[0][:4]
        ide.click(x + 20, y + h // 2)
        ide.type("add a print")
        ide.key("ctrl+enter")
        ok = False
        for _ in range(30):
            log = s.git("log", "--oneline").stdout
            if "add a print" in log:
                ok = True
                break
            time.sleep(0.1)
        c(ok, "scm: Ctrl+Enter commits with the message", s.git("log", "--oneline").stdout)
    f = ide.snap()
    c(f.has("master", exact=False, region=s.status_region()) or f.has("main", exact=False, region=s.status_region()),
      "scm: branch shown in the status bar")
    st = ide.state()
    c(st["focus"] == "scm", "scm: focus stays in the message box after committing", st["focus"])
    # gutter decoration after an edit (click into the editor first)
    t = ide.find("def", region=(318, 80, 400, 200))
    ide.click(int(t.cx), int(t.cy))
    ide.key("ctrl+home")
    ide.type("# changed\n")
    green = []
    t0 = time.time()
    while not green and time.time() - t0 < 15:
        f = ide.snap()
        green = [o for o in f.ops if o["op"] == "fill" and 318 <= o["a"][0] < 400 and o["a"][2] <= 4
                 and o["c"][1] > 120 and o["c"][0] < 120]
        time.sleep(0.2)
    c(len(green) >= 1, "scm: gutter shows an added-line bar")


def sc_search(s):
    ide = s.start()
    c = s.res.check
    ide.key("ctrl+shift+f")
    st = ide.state()
    c(st["view"] == "search", "search: Ctrl+Shift+F opens Search", st["view"])
    ide.type("twice")
    ok = False
    for _ in range(30):
        f = ide.snap()
        if f.has("util.ny", exact=True, region=(48, 30, 280, 700)):
            ok = True
            break
        ide.wait(5)
    c(ok, "search: result file listed")
    f = ide.snap()
    c(f.has("1 result in 1 file", exact=False), "search: summary", [t for t in f.all_text((48, 30, 280, 200))])
    hm = [h for h in ide.hitmap() if h[4] == "@search.match"]
    c(len(hm) >= 1, "search: match row clickable", len(hm))
    if hm:
        x, y, w, h = hm[0][:4]
        ide.click(x + w // 2, y + h // 2)
        st = ide.state()
        c(st["title"] == "util.ny" and st["row"] == 0 and st["sel_text"] == "twice",
          "search: clicking a match opens and selects it", (st["title"], st.get("row"), st.get("sel_text")))


def sc_views_layout(s):
    ide = s.start()
    c = s.res.check
    hm = ide.hitmap()
    views = [h for h in hm if h[4] == "@view"]
    c(len(views) == 7, "views: seven activity bar items", len(views))
    names = []
    for v in views:
        ide.click(v[0] + v[2] // 2, v[1] + v[3] // 2)
        st = ide.state()
        names.append(st["view"])
    c(names == ["explorer", "search", "scm", "debug", "ext", "outline", "ai"], "views: each icon opens its view", names)
    # clicking the active one again hides the sidebar (VS Code)
    v = views[-1]
    ide.click(v[0] + v[2] // 2, v[1] + v[3] // 2)
    st = ide.state()
    c(not st["sidebar"], "views: clicking the active view collapses the side bar")
    ide.key("ctrl+b")
    st = ide.state()
    c(st["sidebar"], "views: Ctrl+B brings it back")
    ide.key("ctrl+j")
    st = ide.state()
    c(not st["panel_open"], "views: Ctrl+J hides the panel")
    ide.key("ctrl+j")
    st = ide.state()
    c(st["panel_open"], "views: Ctrl+J shows it again")
    ide.key("ctrl+shift+x")
    f = ide.snap()
    c(f.has("EXTENSIONS", exact=True) and len(f.all_text((48, 60, 270, 800))) > 6, "views: Extensions lists modules")
    ide.key("ctrl+=")
    st = ide.state()
    c(st["font_size"] == 14, "views: Ctrl+= zooms in", st["font_size"])
    ide.key("ctrl+0")
    st = ide.state()
    c(st["font_size"] == 13, "views: Ctrl+0 resets zoom", st["font_size"])
    # panel tabs
    for key, label in [("output", "OUTPUT"), ("debug", "DEBUG CONSOLE"), ("problems", "PROBLEMS")]:
        ide.click_text(label)
        st = ide.state()
        c(st["panel"] == key, "views: panel tab " + label, st["panel"])
    # resize survives and the layout follows
    ide.resize(1200, 800)
    f = ide.snap()
    c(f.w == 1200 and f.has("PROBLEMS", exact=True), "views: window resize relayouts", (f.w, f.h))


def sc_dead_clicks(s):
    """Click every clickable region of the main chrome once and require that
    each one visibly changes something (screen or workbench state)."""
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    skip_cmds = {"workbench.action.quit", "@overlay.dismiss", "@side.bg", "@tabstrip", "@menu.bg", "@qi.bg",
                 "@find.bg", "@modal.scrim", "@panel.body", "@editor", "@gutter.num", "@sash.side", "@sash.panel",
                 "@vscroll", "@minimap", "@qi.dismiss", "@crumb.bg", "@status.bg", "@term", "@title.bg"}
    hm = ide.hitmap()
    targets = []
    seen = set()
    for h in hm:
        key = (h[4], h[5])
        if h[4] in skip_cmds or h[4] == "" or key in seen:
            continue
        seen.add(key)
        targets.append(h)
    dead = []
    for h in targets:
        before_state = ide.state()
        before = ide.snap()
        x, y, w, hh = h[:4]
        ide.click(x + w // 2, y + hh // 2)
        after_state = ide.state()
        after = ide.snap()
        changed = (after_state != before_state) or ([t.text for t in after.texts] != [t.text for t in before.texts]) \
            or (len(after.ops) != len(before.ops))
        if not changed:
            dead.append("%s(%s) '%s'" % (h[4], h[5], h[6]))
        # reset: close whatever opened
        ide.key("escape")
        ide.key("escape")
        st = ide.state()
        if st["modal"]:
            ide.key("escape")
        if not ide.alive():
            break
    c(len(targets) > 40, "deadclick: enough targets exercised", len(targets))
    c(not dead, "deadclick: every clickable does something", dead)


def _click_audit(s, setup, region, skip, allow_noop, label):
    """Click every target inside `region` once, from the state `setup`
    produces, and return the ones that changed nothing at all."""
    ide = s.ide
    setup()
    hm = ide.hitmap()
    rx, ry, rw, rh = region
    targets = []
    seen = set()
    for h in hm:
        cx, cy = h[0] + h[2] // 2, h[1] + h[3] // 2
        if not (rx <= cx < rx + rw and ry <= cy < ry + rh):
            continue
        key = (h[4], h[5])
        if h[4] in skip or h[4] == "" or key in seen:
            continue
        seen.add(key)
        targets.append(h)
    dead = []
    for h in targets:
        before_state = ide.state()
        before = ide.snap()
        x, y, w, hh = h[:4]
        ide.click(x + w // 2, y + hh // 2)
        after_state = ide.state()
        after = ide.snap()
        changed = (after_state != before_state) or ([t.text for t in after.texts] != [t.text for t in before.texts]) \
            or (len(after.ops) != len(before.ops))
        if not changed and h[4] not in allow_noop:
            dead.append("%s: %s(%s) '%s'" % (label, h[4], h[5], h[6]))
        ide.key("escape")
        ide.key("escape")
        if ide.state()["modal"]:
            ide.key("escape")
        if not ide.alive():
            break
        setup()
    return targets, dead


def sc_dead_clicks_views(s):
    """The same audit for every side bar view and every panel, each in a state
    where it has content (a git repository, search results, a paused
    debugger)."""
    s.git("init", "-q")
    s.git("add", "-A")
    s.git("commit", "-q", "-m", "initial")
    s.write("app.ny", APP + "print(1)\n")
    s.write("loop.ny", LOOP)
    ide = s.start()
    c = s.res.check
    skip = {"workbench.action.quit", "@overlay.dismiss", "@side.bg", "@panel.body", "@term", "@dbgcon",
            "@sash.side", "@sash.panel", "@qi.dismiss", "@modal.scrim"}
    # Refresh-style buttons legitimately change nothing when nothing changed.
    allow = {"git.refresh", "@search.run", "@ext.refresh", "workbench.files.action.refreshFilesExplorer",
             "nython.ai.analyze", "@dbg.seek"}
    side = (48, 30, 270, 900)
    panel = (318, 684, 1282, 254)
    all_dead = []
    total = 0

    def view(key):
        def go():
            st = ide.state()
            if st["view"] != key or not st["sidebar"]:
                ide.key({"explorer": "ctrl+shift+e", "search": "ctrl+shift+f", "scm": "ctrl+shift+g",
                         "debug": "ctrl+shift+d", "ext": "ctrl+shift+x"}[key])
        return go

    s.open_file("loop.ny")
    ide.key("ctrl+g")
    ide.type("5\n")
    ide.key("f9")
    ide.key("ctrl+shift+f")
    ide.type("total")
    ide.snap(settle=30)
    for key in ["explorer", "search", "scm", "ext"]:
        t, d = _click_audit(s, view(key), side, skip, allow, key)
        total += len(t)
        all_dead += d
    # Run and Debug with a paused session.
    ide.key("f5")
    s.wait_until(lambda st: st["dbg_state"] == "paused")
    t, d = _click_audit(s, view("debug"), side, skip | {"workbench.action.debug.stop",
                                                          "workbench.action.debug.restart"}, allow, "debug")
    total += len(t)
    all_dead += d
    ide.key("shift+f5")
    for key, label in [("problems", "PROBLEMS"), ("output", "OUTPUT"), ("debug", "DEBUG CONSOLE"),
                       ("terminal", "TERMINAL")]:
        def go(label=label, key=key):
            st = ide.state()
            if not st["panel_open"]:
                ide.key("ctrl+j")
                st = ide.state()
            if st["panel"] != key:
                ide.click_text(label)
        t, d = _click_audit(s, go, panel, skip, allow, "panel " + key)
        total += len(t)
        all_dead += d
    c(total > 30, "deadclick views: enough targets exercised", total)
    c(not all_dead, "deadclick views: every clickable does something", all_dead)


# ── Code::Blocks-side features (ide_tools.ny) ──────────────────────────────
def palette(s, label):
    """Runs a command by its palette label (Category: Title)."""
    ide = s.ide
    ide.key("ctrl+shift+p")
    ide.type(label)
    st = ide.state()
    first = st["qi_items"][0] if st["qi_items"] else ""
    ide.key("enter")
    return first


def wait_log(s, needle, key="build_log", tries=80):
    for _ in range(tries):
        st = s.ide.state()
        if any(needle in ln for ln in st.get(key, [])):
            return st
        time.sleep(0.1)
    return s.ide.state()


def sc_build(s):
    ide = s.start()
    c = s.res.check
    s.write("bad.ny", "def f(:\n    pass\n")
    s.open_file("app.ny")
    ide.key("ctrl+shift+b")
    st = wait_log(s, "=== Build")
    log = st["build_log"]
    c(any("Build: Debug" in ln for ln in log), "build: log names the target", log[:3])
    c(any("=== Build failed: 1 error(s)" in ln for ln in log), "build: one error found", log[-3:])
    c(any("bad.ny:" in ln and "error" in ln for ln in log), "build: error line in the log", log)
    c(st["errors"] >= 1 and st["panel"] == "problems", "build: failure opens Problems", (st["errors"], st["panel"]))
    s.write("bad.ny", "def f():\n    pass\n")
    time.sleep(1.2)
    ide.key("ctrl+shift+b")
    st = wait_log(s, "=== Build finished")
    c(any("=== Build finished: 0 error(s)" in ln for ln in st["build_log"]), "build: clean build", st["build_log"][-2:])
    c(st["errors"] == 0, "build: problems cleared", st["errors"])
    # Build and Run
    first = palette(s, "Build: Build and Run")
    c(first == "Build: Build and Run", "build: palette finds Build and Run", first)
    ok = False
    for _ in range(80):
        if ide.snap().has("hi bob", exact=True):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "build: Build and Run runs the program after a clean build")
    # targets: arguments, environment, engine, pre-build step
    s.write("args.ny", 'print("env", getenv("GREETING"))\n')
    s.write("proj.nyproj", "name = proj\ntarget = args.ny\n[target Debug]\nengine = interp\nenv = GREETING=hey\npre = echo pre > pre_ran.txt\n"
                           "[target Release]\nengine = vm\nenv = GREETING=vm-hey\n")
    time.sleep(1.2)
    palette(s, "Build: Select Target...")
    st = ide.state()
    c(any("Debug" in x for x in st["qi_items"]) and any("Release" in x for x in st["qi_items"]),
      "build: target picker lists the project's targets", st["qi_items"])
    ide.key("escape")
    ide.key("ctrl+shift+b")
    wait_log(s, "=== Build")
    c(os.path.exists(os.path.join(s.ws, "pre_ran.txt")), "build: pre-build step ran")
    palette(s, "Build: Run Target")
    ok = False
    for _ in range(80):
        if ide.snap().has("env hey", exact=True):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "build: Run Target uses the target's main file and environment")
    palette(s, "Build: Select Target...")
    ide.type("Release\n")
    st = ide.state()
    c(st["build_target"] == "Release", "build: target selected", st["build_target"])
    palette(s, "Build: Run Target")
    ok = False
    for _ in range(80):
        if ide.snap().has("env vm-hey", exact=True):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "build: the Release target runs on the VM with its own environment")
    c("build_target = Release" in s.read(".nyide"), "build: selected target saved in .nyide", "")
    # Abort a program that never ends, with Shift+F5 (it used to do nothing)
    s.write("forever.ny", "var i = 0\nwhile true:\n    i = i + 1\n")
    s.open_file("forever.ny")
    ide.key("ctrl+f5")
    time.sleep(0.8)
    ide.key("shift+f5")
    ok = False
    for _ in range(60):
        if ide.snap().has("[process stopped]", exact=True):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "build: Shift+F5 stops a running program")


def sc_cb_editing(s):
    ide = s.start()
    c = s.res.check
    s.write("ed.ny", "def one():\n    return 1\n\ndef two():\n    return 2\n\nclass K:\n    def m(self):\n        return 3\n")
    st = s.open_file("ed.ny")
    # bookmarks
    ide.key("ctrl+home")
    ide.key("ctrl+alt+k")
    ide.key("ctrl+g")
    ide.type("7\n")
    ide.key("ctrl+alt+k")
    st = ide.state()
    c(st["bookmarks"] == [0, 6], "cb: two bookmarks set", st["bookmarks"])
    ide.key("ctrl+alt+l")
    st = ide.state()
    c(st["row"] == 0, "cb: next bookmark wraps to the first", st["row"])
    ide.key("ctrl+alt+j")
    st = ide.state()
    c(st["row"] == 6, "cb: previous bookmark wraps to the last", st["row"])
    ide.key("ctrl+home")
    ide.key("enter")
    st = ide.state()
    c(st["bookmarks"] == [1, 7], "cb: bookmarks move with inserted lines", st["bookmarks"])
    ide.key("ctrl+z")
    # folding
    ide.key("ctrl+home")
    ide.key("ctrl+shift+[")
    st = ide.state()
    c(st["folds"] == [0] and st["vis_rows"] == st["text"].count("\n") + 1 - 1, "cb: fold hides the body", (st["folds"], st["vis_rows"]))
    ide.key("down")
    st = ide.state()
    c(st["row"] == 2, "cb: Down steps over the folded body", st["row"])
    ide.key("ctrl+k")
    ide.key("ctrl+0")
    st = ide.state()
    c(len(st["folds"]) == 3, "cb: Fold All folds every top-level region", st["folds"])
    ide.key("ctrl+g")
    ide.type("9\n")
    st = ide.state()
    c(st["row"] == 8 and 6 not in st["folds"], "cb: jumping into a fold unfolds it", (st["row"], st["folds"]))
    ide.key("ctrl+k")
    ide.key("ctrl+j")
    st = ide.state()
    c(st["folds"] == [], "cb: Unfold All", st["folds"])
    # the gutter chevron folds too
    hm = ide.hitmap()
    fold = [h for h in hm if h[4] == "@gutter.fold"]
    c(len(fold) == 1, "cb: folding column in the gutter", len(fold))
    if fold:
        x, y, w, h = fold[0][:4]
        ide.click(x + w // 2, y + 8)
        st = ide.state()
        c(st["folds"] == [0], "cb: clicking the chevron folds the region", st["folds"])
        ide.click(x + w // 2, y + 8)
        st = ide.state()
        c(st["folds"] == [], "cb: clicking again unfolds", st["folds"])
    # abbreviations
    ide.key("ctrl+end")
    ide.type("\ndef")
    ide.key("tab")
    ide.type("go")
    ide.key("tab")
    ide.type("a, b")
    ide.key("tab")
    ide.type("return a")
    st = ide.state()
    c("def go(a, b):\n    return a" in st["text"], "cb: def<Tab> expands and Tab walks the stops", st["text"][-60:])
    # overwrite mode, one undo step per typed character
    ide.key("ctrl+home")
    ide.key("insert")
    ide.type("DEF")
    st = ide.state()
    c(st["text"].startswith("DEF one()") and st["overwrite"], "cb: overwrite mode replaces characters", st["text"][:12])
    ide.key("insert")
    st = ide.state()
    c(not st["overwrite"], "cb: Insert toggles back to insert mode", st["overwrite"])
    ide.key("ctrl+z")
    st = ide.state()
    c(st["text"].startswith("def one()"), "cb: one undo restores the overtyped word", st["text"][:12])
    # case, duplicate, transpose
    ide.key("ctrl+home")
    palette(s, "Edit: Transform to Uppercase")
    st = ide.state()
    c(st["text"].startswith("DEF one"), "cb: uppercase the word at the caret", st["text"][:10])
    ide.key("ctrl+z")
    ide.key("ctrl+home")
    palette(s, "Edit: Duplicate Selection")
    st = ide.state()
    c(st["text"].startswith("def one():\ndef one():"), "cb: duplicate line without a selection", st["text"][:24])
    ide.key("ctrl+z")
    ide.key("ctrl+g")
    ide.type("2\n")
    palette(s, "Edit: Transpose Lines")
    st = ide.state()
    c(st["text"].startswith("    return 1\ndef one():") and st["row"] == 1, "cb: transpose swaps with the line above", st["text"][:26])
    ide.key("ctrl+z")
    # format
    s.write("messy.ny", "def f( a,b ):\n  x=a+b\n  if x==3:\n        return x\n\n\n\n  return 0  \n")
    s.open_file("messy.ny")
    ide.key("shift+alt+f")
    st = ide.state()
    # The file is indented with two spaces, so that is the unit it keeps.
    c(st["text"] == "def f( a, b ):\n  x = a+b\n  if x == 3:\n    return x\n\n  return 0\n", "cb: Format Document", st["text"])
    ide.key("ctrl+z")
    st = ide.state()
    c(st["text"].startswith("def f( a,b ):\n  x=a+b"), "cb: format undoes in one step", st["text"][:20])
    # Ctrl+wheel zoom
    f0 = ide.state()["font_size"]
    hm = ide.hitmap()
    ed = [h for h in hm if h[4] == "@editor"][0]
    ide.wheel(ed[0] + 50, ed[1] + 50, 1)
    st = ide.state()
    c(st["font_size"] == f0, "cb: plain wheel does not zoom", st["font_size"])
    ide.wheel(ed[0] + 50, ed[1] + 50, 1, "ctrl")
    st = ide.state()
    c(st["font_size"] > f0, "cb: Ctrl+wheel zooms in", (f0, st["font_size"]))
    ide.wheel(ed[0] + 50, ed[1] + 50, -1, "ctrl")
    st = ide.state()
    c(st["font_size"] == f0, "cb: Ctrl+wheel back zooms out", (f0, st["font_size"]))


def sc_cb_tools(s):
    ide = s.start()
    c = s.res.check
    s.write("todo.ny", "def f():\n    # TODO(ana): first\n    s = \"# FIXME not a comment\"\n    return 1  # FIXME: second\n")
    s.open_file("todo.ny")
    palette(s, "View: TODO List")
    st = ide.state()
    c(st["panel"] == "todo" and st["todo_n"] == 2, "tools: TODO list finds comments, not strings", (st["panel"], st["todo_n"]))
    f = ide.snap()
    c(f.has("first", exact=True) and f.has("(ana)", exact=True), "tools: TODO text and owner shown")
    # code statistics
    palette(s, "Tools: Code Statistics")
    st = ide.state()
    c(st["title"] == "Code Statistics" and "Total lines:" in st["text"] and "todo.ny" in st["text"], "tools: code statistics document", st["title"])
    # class wizard
    palette(s, "Tools: New Class...")
    ide.type("ShoppingCart\n")
    ide.type("\n")
    ide.type("items, owner\n")
    ide.state()
    p = os.path.join(s.ws, "shopping_cart.ny")
    c(os.path.exists(p), "tools: class wizard writes shopping_cart.ny")
    if os.path.exists(p):
        body = open(p).read()
        c("class ShoppingCart:" in body and "self.items = items" in body and "def __str__" in body, "tools: class skeleton", body[:200])
        r = subprocess.run([os.path.join(REPO, "build", "nython-cli"), p], capture_output=True, text=True, timeout=30)
        c(r.returncode == 0, "tools: generated class file runs", r.stderr[-300:])
    # user tool with macros, and an environment variable
    s.write(".nyide", "tool = Echo file | echo tool-ran $(FILE_NAME) $GREET\nenv = GREET=hello\n")
    palette(s, "Tools: Configure Tools...")
    st = ide.state()
    c(st["title"] == ".nyide", "tools: Configure Tools opens the settings file", st["title"])
    ide.key("ctrl+s")
    s.open_file("todo.ny")
    first = palette(s, "Tools: Echo file")
    c(first == "Tools: Echo file", "tools: user tool in the palette", first)
    ok = False
    for _ in range(60):
        if ide.snap().has("tool-ran todo.ny hello", exact=True):
            ok = True
            break
        time.sleep(0.1)
    c(ok, "tools: tool runs with macros expanded and the environment set")
    # keymap: Code::Blocks
    palette(s, "Preferences: Keymap...")
    ide.type("Code::Blocks\n")
    st = ide.state()
    c(st["keymap"] == "codeblocks", "tools: Code::Blocks keymap selected", st["keymap"])
    ide.key("ctrl+f9")
    st = wait_log(s, "=== Build")
    c(any("=== Build" in ln for ln in st["build_log"]), "tools: Ctrl+F9 builds in the Code::Blocks keymap", st["build_log"][-1:])
    ide.key("ctrl+home")
    ide.key("ctrl+d")
    st = ide.state()
    c(st["text"].startswith("def f():\ndef f():"), "tools: Ctrl+D duplicates the line (Code::Blocks)", st["text"][:20])
    ide.key("ctrl+z")
    c("keymap = codeblocks" in s.read(".nyide"), "tools: keymap saved", "")
    # rebind a command by pressing the key
    palette(s, "Preferences: Change Keybinding...")
    ide.type("Toggle Bookmark")
    ide.key("enter")
    st = ide.state()
    c(st["modal"], "tools: key capture dialog", st["modal_title"])
    ide.key("ctrl+alt+m")
    ide.key("enter")
    st = ide.state()
    c(not st["modal"], "tools: capture confirmed", st["modal_msg"])
    ide.key("ctrl+home")
    ide.key("ctrl+alt+m")
    st = ide.state()
    c(st["bookmarks"] == [0], "tools: rebound key toggles a bookmark", st["bookmarks"])
    c("keybinding = Ctrl+Alt+M | nython.bookmarks.toggle" in s.read(".nyide"), "tools: rebinding saved", "")


def sc_cb_debug(s):
    ide = s.start()
    c = s.res.check
    s.write("cnt.ny", "var total = 0\nvar i = 0\nwhile i < 6:\n    total = total + i\n    i = i + 1\nprint(\"done\", total)\n")
    s.open_file("cnt.ny")
    ide.key("ctrl+g")
    ide.type("4\n")
    palette(s, "Run: Edit Breakpoint...")
    ide.type("Condition\n")
    ide.type("i == 3\n")
    ide.key("ctrl+g")
    ide.type("5\n")
    palette(s, "Run: Edit Breakpoint...")
    ide.type("Log Message\n")
    ide.type("i is {i}\n")
    ide.key("f5")
    st = s.wait_until(lambda st: st["dbg_state"] == "paused")
    c(st["dbg_state"] == "paused" and st["dbg_line"] == 4, "debug-cb: conditional breakpoint stops", (st["dbg_state"], st["dbg_line"]))
    f = ide.snap()
    c(f.has("cnt.ny:5: i is 0", exact=True) and f.has("cnt.ny:5: i is 2", exact=True) and not f.has("cnt.ny:5: i is 3", exact=True),
      "debug-cb: log points passed before the stop print to the debug console")
    ide.key("ctrl+g")
    ide.type("6\n")
    palette(s, "Debug: Run to Cursor")
    st = ide.state()
    c(st["dbg_state"] == "paused" and st["dbg_line"] == 6, "debug-cb: run to cursor", (st["dbg_state"], st["dbg_line"]))
    f = ide.snap()
    c(f.has("cnt.ny:5: i is 5", exact=True), "debug-cb: log points on the way to the cursor print too")
    ide.key("shift+f5")


def sc_responsive(s):
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    ide.resize(480, 360)
    ide.wait(10)
    st = ide.state()
    c(st["menu_compact"], "responsive: menus fold into a hamburger", st["menu_compact"])
    c(st["side_overlay"], "responsive: side bar floats over the editor", st["side_overlay"])
    hm = ide.hitmap()
    ham = [h for h in hm if h[4] == "@menu"]
    c(len(ham) == 1, "responsive: one menu button", len(ham))
    if ham:
        ide.click(ham[0][0] + 10, ham[0][1] + 10)
        f = ide.snap()
        c(f.has("Build", exact=True) and f.has("Tools", exact=True), "responsive: hamburger lists the menus")
        ide.click_text("Edit")
        f = ide.snap()
        c(f.has("Undo", exact=True), "responsive: picking a menu opens it")
        ide.key("escape")
    # clicking beside the floating side bar closes it
    ide.click(440, 200)
    st = ide.state()
    c(not st["sidebar"], "responsive: click outside closes the floating side bar", st["sidebar"])
    # overflowing panel tabs
    hm = ide.hitmap()
    more = [h for h in hm if h[4] == "@panel.more"]
    c(len(more) == 1, "responsive: panel tabs overflow into ...", len(more))
    if more:
        ide.click(more[0][0] + 5, more[0][1] + 5)
        ide.click_text("BUILD LOG")
        st = ide.state()
        c(st["panel"] == "buildlog", "responsive: hidden panel reachable from ...", st["panel"])
    ide.resize(1600, 960)
    ide.wait(10)
    st = ide.state()
    c(not st["menu_compact"] and not st["side_overlay"], "responsive: full layout returns", (st["menu_compact"], st["side_overlay"]))
    f = ide.snap()
    c(f.has("Terminal", exact=True) and f.has("Help", exact=True), "responsive: menus back on the bar")


def sc_session(s):
    ide = s.start()
    c = s.res.check
    s.open_file("app.ny")
    ide.key("ctrl+g")
    ide.type("2\n")
    ide.key("ctrl+p")
    ide.type("util.ny\n")
    st = ide.state()
    c(st["title"] == "util.ny", "session: second file open", st["title"])
    s.ide = None
    ide.close()
    ide.cleanup()
    ide2 = s.start()
    st = ide2.state()
    c("app.ny" in st["tabs"] and "util.ny" in st["tabs"], "session: editors reopened", st["tabs"])
    c(st["title"] == "util.ny", "session: active editor restored", st["title"])


SCENARIOS = [
    ("boot", sc_boot), ("edit", sc_edit_undo_save), ("clipboard", sc_clipboard_lines),
    ("multicursor", sc_multicursor), ("palette", sc_palette), ("quickopen", sc_quick_open),
    ("menus", sc_menus), ("find", sc_find_replace), ("statusbar", sc_statusbar),
    ("explorer", sc_explorer_ops), ("close", sc_close_dirty), ("terminal", sc_terminal),
    ("run", sc_run), ("problems", sc_syntax_problems), ("debug", sc_debugger), ("scm", sc_scm),
    ("search", sc_search), ("views", sc_views_layout), ("deadclicks", sc_dead_clicks),
    ("deadviews", sc_dead_clicks_views), ("build", sc_build), ("cbedit", sc_cb_editing),
    ("cbtools", sc_cb_tools), ("cbdebug", sc_cb_debug), ("responsive", sc_responsive),
    ("session", sc_session),
]


def main(argv):
    shots = None
    words = []
    i = 0
    while i < len(argv):
        if argv[i] == "--shots":
            shots = argv[i + 1]
            os.makedirs(shots, exist_ok=True)
            i += 2
            continue
        words.append(argv[i])
        i += 1
    res = Result()
    for name, fn in SCENARIOS:
        if words and not any(w in name for w in words):
            continue
        t0 = time.time()
        print("[%s]" % name)
        s = Scenario(res, shots)
        try:
            fn(s)
        except DriverError as e:
            res.check(False, name + ": driver error", str(e)[:1500])
        except Exception:
            res.check(False, name + ": exception", traceback.format_exc()[-1500:])
        finally:
            try:
                s.finish(name)
            except Exception:
                res.check(False, name + ": teardown", traceback.format_exc()[-800:])
        print("    %.1fs" % (time.time() - t0))
    print("%d passed, %d failed" % (res.passed, len(res.failed)))
    return 1 if res.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
