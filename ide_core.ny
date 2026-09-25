# ══════════════════════════════════════════════════════════════════════════════
#  ide_core.ny — documents, commands and editing for NythonIDE
#
#  Class chain (split across files because one ~8,000-line class body is past
#  what the parser handles comfortably — see CLAUDE.md "File split"):
#
#      IDECore      (this file)   documents, command table + dispatcher,
#                                 editing operations, run/build, settings
#      IDEPaint     ide_paint.ny  theme, layout, every draw routine, hit map
#      IDEViews     ide_views.ny  side bar views: Explorer, Search, Source
#                                 Control, Run and Debug, Extensions, ...
#      NythonIDE    nython_ide.ny state, input routing, frame loop
#
#  Commands follow VS Code: an id, a category and a title, and a keybinding.
#  Menus, the Command Palette, context menus, the status bar and keybindings
#  all name command ids; `_exec` is the only place a command is carried out.
# ══════════════════════════════════════════════════════════════════════════════

import "ide_editor.ny"
import "ide_project.ny"
import "lib/ide_workbench.ny"


# One open editor. `kind` is file (on disk), untitled, welcome, or virtual (a
# generated read-only document such as Keyboard Shortcuts).
class Doc:
    def __init__(self, kind, title, path, buf):
        self.kind = kind
        self.title = title
        self.path = path
        self.buf = buf
        self.scroll_y = 0
        self.scroll_x = 0
        self.sel_on = false
        self.sel_row = 0
        self.sel_col = 0
        self.lang = "nython"
        self.bom = false
        self.readonly = false
        self.tab_x = 0
        self.tab_w = 0
        self.diff = none          # SCM gutter decorations, lib/ide_scm.ny
        self.diff_state = -1      # buffer state the decorations were computed for
        self.problem_stamp = -1
        self.mtime = -1            # file_mtime when last read or written
        self.disk_changed = false  # changed on disk while it had unsaved edits
        self.tab_size = 4          # per file, as in VS Code (detected on open)
        self.insert_spaces = true
        if buf != none:
            buf.coalesce = true

    def dirty(self):
        if self.buf == none or self.kind == "virtual" or self.kind == "welcome":
            return false
        if self.kind == "untitled":
            return self.buf.state_id() != 0
        return self.buf.is_dirty()


class IDECore:
    # ══ documents ═════════════════════════════════════════════════════════════
    def doc(self):
        return self.docs[self.active]

    def buf(self):
        return self.docs[self.active].buf

    def _is_text(self):
        return self.docs[self.active].buf != none

    def _activate(self, i):
        if i < 0 or i >= len(self.docs):
            return
        if self.active != i:
            self._nav_record()
        self.active = i
        var d = self.docs[i]
        if d.buf != none:
            d.buf.begin_group()
            self._sync_indent(d)
        self.ac_open = false
        self.hover_info = ""
        self._clear_extra_carets()
        self._reveal_tab(i)
        self._title_dirty = true
        self._dirty = true

    def _find_doc(self, path):
        var i = 0
        while i < len(self.docs):
            if self.docs[i].path != "" and self.docs[i].path == path:
                return i
            i = i + 1
        return -1

    def _add_doc(self, d):
        d.tab_size = self.default_tab_size
        d.insert_spaces = self.default_insert_spaces
        # A pristine Welcome tab is replaced by the first real editor, as in
        # VS Code, rather than accumulating beside it.
        if len(self.docs) == 1 and self.docs[0].kind == "welcome" and d.kind != "welcome":
            self.docs = [d]
            self.active = 0
            self._activate(0)
            return 0
        self.docs.append(d)
        self._activate(len(self.docs) - 1)
        return len(self.docs) - 1

    def _new_untitled(self):
        self.untitled_seq = self.untitled_seq + 1
        var name = "Untitled-" + str(self.untitled_seq)
        var d = Doc("untitled", name, "", EditorBuffer(name, ""))
        self._add_doc(d)
        self.focus = "editor"
        return d

    def _lang_for(self, path):
        var ext = os_path_ext(path)
        if ext == ".ny" or ext == ".nyx":
            return "nython"
        if ext == ".md":
            return "markdown"
        return "plaintext"

    # Opens a file in an editor (or activates the one already showing it).
    # row/col are zero-based; -1 leaves the caret where it was.
    def _open_path(self, path, row, col):
        if path == none or path == "":
            return false
        var p = path
        if not os_exists(p):
            self._notify("File not found: " + p, "err")
            return false
        if os_isdir(p):
            self._notify(os_path_basename(p) + " is a folder - use File > Open Folder", "warn")
            return false
        var i = self._find_doc(p)
        if i < 0:
            var size = file_size(p)
            if size > 4000000:
                self._notify("File is too large to open in the editor (" + str(int(size / 1024)) + " KB)", "err")
                return false
            var text = read_file(p)
            if text == none:
                self._notify("Could not read " + p, "err")
                return false
            var bom = false
            if string_startswith(text, "\xef\xbb\xbf"):
                bom = true
                text = string_slice(text, 3, len(text))
            var d = Doc("file", os_path_basename(p), p, EditorBuffer(os_path_basename(p), text))
            d.bom = bom
            d.lang = self._lang_for(p)
            d.mtime = file_mtime(p)
            i = self._add_doc(d)
            if self.detect_indent:
                self._detect_indent(d, false)
            self._remember_recent(p)
            self._check_file(d)
        else:
            self._activate(i)
        if row >= 0:
            self._goto(row, col)
        self.focus = "editor"
        return true

    def _open_virtual(self, title, text):
        var i = 0
        while i < len(self.docs):
            if self.docs[i].kind == "virtual" and self.docs[i].title == title:
                self.docs[i].buf = EditorBuffer(title, text)
                self.docs[i].buf.coalesce = true
                self._activate(i)
                return self.docs[i]
            i = i + 1
        var d = Doc("virtual", title, "", EditorBuffer(title, text))
        d.readonly = true
        d.lang = "plaintext"
        self._add_doc(d)
        return d

    def _open_welcome(self):
        var i = 0
        while i < len(self.docs):
            if self.docs[i].kind == "welcome":
                self._activate(i)
                return
            i = i + 1
        self.docs.append(Doc("welcome", "Welcome", "", none))
        self._activate(len(self.docs) - 1)

    # ── saving ───────────────────────────────────────────────────────────────
    # Returns true when the document is on disk afterwards. An untitled
    # document opens the Save As prompt and returns false; the prompt's
    # accept handler finishes the save.
    def _save_doc(self, d):
        if d.buf == none or d.kind == "virtual" or d.kind == "welcome":
            return true
        if d.kind == "untitled" or d.path == "":
            self._prompt_save_as(d, "")
            return false
        # Someone else wrote the file since we read it: VS Code refuses to
        # overwrite silently and asks.
        var disk = file_mtime(d.path)
        if d.mtime >= 0 and disk >= 0 and disk != d.mtime:
            self._modal("Failed to save '" + d.title + "': The content of the file is newer.",
                        "Compare your version with the file on disk, or overwrite it with your changes.",
                        [["Overwrite", "@save.overwrite", self._index_of(d)], ["Revert", "@save.revert", self._index_of(d)],
                         ["Cancel", "@modal.cancel", ""]])
            return false
        return self._write_doc(d, d.path)

    def _write_doc(self, d, path):
        var text = d.buf.text_for_save()
        if d.bom:
            text = "\xef\xbb\xbf" + text
        var ok = write_file(path, text)
        if ok == false or not os_exists(path):
            self._notify("Could not write " + path, "err")
            return false
        var was_untitled = d.kind == "untitled"
        d.kind = "file"
        d.path = path
        d.title = os_path_basename(path)
        d.buf.name = d.title
        d.buf.mark_saved()
        d.mtime = file_mtime(path)
        d.disk_changed = false
        if was_untitled:
            d.lang = self._lang_for(path)
        self._remember_recent(path)
        self._title_dirty = true
        self.status_msg = "Saved " + d.title
        # Saving the settings file applies it, as VS Code does.
        if path == self._settings_path():
            self._load_settings()
            self._notify("Settings applied", "ok")
        if self.ws.root != "":
            self.ws.rebuild()
        self.scm_stale = true
        self._check_file(d)
        return true

    def _prompt_save_as(self, d, after):
        var base = self.ws.root
        if base == "":
            base = getcwd()
        var name = d.title
        if d.kind == "untitled":
            name = d.title + ".ny"
        var start = path_join(base, name)
        if d.path != "":
            start = d.path
        self._open_path_prompt("saveas", "Save As", "Path to save " + d.title + " to", start, false)
        self.qi.data = {"doc": d, "after": after}

    def _save_all(self):
        var n = 0
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.dirty():
                if d.kind == "untitled":
                    self._activate(i)
                    self._prompt_save_as(d, "saveall")
                    return n
                if self._write_doc(d, d.path):
                    n = n + 1
            i = i + 1
        if n == 0:
            self.status_msg = "Nothing to save"
        else:
            self._notify("Saved " + str(n) + " file(s)", "ok")
        return n

    def _revert_doc(self):
        var d = self.doc()
        if d.kind != "file":
            self._notify("Only files on disk can be reverted", "warn")
            return
        if self._reload_from_disk(d):
            self._notify("Reverted " + d.title, "info")

    # Replaces a file editor's buffer with the file's current content,
    # keeping the caret and scroll position where they were (clamped).
    def _reload_from_disk(self, d):
        var text = read_file(d.path)
        if text == none:
            return false
        var bom = false
        if string_startswith(text, "\xef\xbb\xbf"):
            bom = true
            text = string_slice(text, 3, len(text))
        var row = 0
        var col = 0
        if d.buf != none:
            row = d.buf.cursor_row
            col = d.buf.cursor_col
        d.buf = EditorBuffer(d.title, text)
        d.buf.coalesce = true
        d.bom = bom
        if row >= d.buf.line_count:
            row = d.buf.line_count - 1
        d.buf.cursor_row = row
        var n = len(d.buf.get_line(row))
        if col > n:
            col = n
        d.buf.cursor_col = col
        d.sel_on = false
        d.mtime = file_mtime(d.path)
        d.disk_changed = false
        d.diff = none
        self._sync_indent(d)
        self._hl_reset()
        if d == self.doc():
            self._clear_extra_carets()
        self._dirty = true
        return true

    # ── closing ──────────────────────────────────────────────────────────────
    # A dirty editor asks first: Save / Don't Save / Cancel, exactly the three
    # choices VS Code offers. The old IDE closed tabs without asking.
    def _close_doc(self, i, force):
        if i < 0 or i >= len(self.docs):
            return true
        var d = self.docs[i]
        if not force and d.dirty():
            self._activate(i)
            self._modal("Do you want to save the changes you made to " + d.title + "?",
                        "Your changes will be lost if you don't save them.",
                        [["Save", "@close.save", i], ["Don't Save", "@close.discard", i], ["Cancel", "@modal.cancel", ""]])
            return false
        if d.path != "":
            self.closed_stack.append(d.path)
        var keep = []
        var k = 0
        while k < len(self.docs):
            if k != i:
                keep.append(self.docs[k])
            k = k + 1
        self.docs = keep
        if len(self.docs) == 0:
            self.docs = [Doc("welcome", "Welcome", "", none)]
            self.active = 0
        elif self.active >= i and self.active > 0:
            self.active = self.active - 1
        self._activate(self.active)
        self.status_msg = "Closed " + d.title
        return true

    # Closes a set of editors. Clean ones close immediately; if any are dirty
    # one dialog covers them all.
    def _close_many(self, which):
        var dirty_n = 0
        var i = 0
        while i < len(which):
            if self.docs[which[i]].dirty():
                dirty_n = dirty_n + 1
            i = i + 1
        if dirty_n > 0:
            self.pending_close = which
            self._modal("Do you want to save the changes to " + str(dirty_n) + " file(s)?",
                        "Your changes will be lost if you don't save them.",
                        [["Save All", "@closemany.save", ""], ["Don't Save", "@closemany.discard", ""], ["Cancel", "@modal.cancel", ""]])
            return false
        self._close_indices(which)
        return true

    def _close_indices(self, which):
        var drop = {}
        var i = 0
        while i < len(which):
            drop[str(which[i])] = true
            i = i + 1
        var keep = []
        var cur = self.docs[self.active]
        var k = 0
        while k < len(self.docs):
            if not drop.has_key(str(k)):
                keep.append(self.docs[k])
            elif self.docs[k].path != "":
                self.closed_stack.append(self.docs[k].path)
            k = k + 1
        self.docs = keep
        if len(self.docs) == 0:
            self.docs = [Doc("welcome", "Welcome", "", none)]
        var ni = 0
        var j = 0
        while j < len(self.docs):
            if self.docs[j] == cur:
                ni = j
            j = j + 1
        self.active = ni
        self._activate(ni)

    def _others(self, idx, mode):
        var out = []
        var i = 0
        while i < len(self.docs):
            if mode == "others" and i != idx:
                out.append(i)
            elif mode == "right" and i > idx:
                out.append(i)
            elif mode == "all":
                out.append(i)
            elif mode == "saved" and not self.docs[i].dirty():
                out.append(i)
            i = i + 1
        return out

    def _dirty_count(self):
        var n = 0
        var i = 0
        while i < len(self.docs):
            if self.docs[i].dirty():
                n = n + 1
            i = i + 1
        return n

    def _quit(self, force):
        if not force and self._dirty_count() > 0:
            self._modal("Do you want to save the changes to " + str(self._dirty_count()) + " file(s) before exiting?",
                        "Your changes will be lost if you don't save them.",
                        [["Save All", "@quit.save", ""], ["Don't Save", "@quit.discard", ""], ["Cancel", "@modal.cancel", ""]])
            return
        self._save_settings()
        self._save_state()
        self.win.running = false

    # ══ commands ═══════════════════════════════════════════════════════════════
    def _cmd(self, id, cat, title, keys, when):
        self.reg.add(id, cat, title, keys, when)

    def _register_commands(self):
        var c = self
        # File
        c._cmd("workbench.action.files.newUntitledFile", "File", "New Text File", "Ctrl+N", "")
        c._cmd("workbench.action.files.openFile", "File", "Open File...", "Ctrl+O", "")
        c._cmd("workbench.action.files.openFolder", "File", "Open Folder...", "Ctrl+K Ctrl+O", "")
        c._cmd("workbench.action.openRecent", "File", "Open Recent...", "Ctrl+R", "")
        c._cmd("nython.newProject", "File", "New Project...", "", "")
        c._cmd("nython.openProject", "File", "Open Project...", "", "")
        c._cmd("workbench.action.files.save", "File", "Save", "Ctrl+S", "")
        c._cmd("workbench.action.files.saveAs", "File", "Save As...", "Ctrl+Shift+S", "")
        c._cmd("workbench.action.files.saveAll", "File", "Save All", "Ctrl+K S", "")
        c._cmd("workbench.action.files.revert", "File", "Revert File", "", "")
        c._cmd("workbench.action.closeActiveEditor", "View", "Close Editor", "Ctrl+W | Ctrl+F4", "")
        c._cmd("workbench.action.closeAllEditors", "View", "Close All Editors", "Ctrl+K Ctrl+W", "")
        c._cmd("workbench.action.closeOtherEditors", "View", "Close Other Editors", "", "")
        c._cmd("workbench.action.closeEditorsToTheRight", "View", "Close Editors to the Right", "", "")
        c._cmd("workbench.action.closeUnmodifiedEditors", "View", "Close Saved Editors", "Ctrl+K U", "")
        c._cmd("workbench.action.reopenClosedEditor", "View", "Reopen Closed Editor", "Ctrl+Shift+T", "")
        c._cmd("workbench.action.closeFolder", "File", "Close Folder", "Ctrl+K F", "")
        c._cmd("workbench.action.openSettings", "Preferences", "Open Settings", "Ctrl+,", "")
        c._cmd("workbench.action.openGlobalKeybindings", "Preferences", "Open Keyboard Shortcuts", "Ctrl+K Ctrl+S", "")
        c._cmd("workbench.action.selectTheme", "Preferences", "Color Theme", "Ctrl+K Ctrl+T", "")
        c._cmd("workbench.action.quit", "File", "Exit", "Ctrl+Q", "")
        # Edit
        c._cmd("undo", "Edit", "Undo", "Ctrl+Z", "!inputFocus")
        c._cmd("redo", "Edit", "Redo", "Ctrl+Y | Ctrl+Shift+Z", "!inputFocus")
        c._cmd("editor.action.clipboardCutAction", "Edit", "Cut", "Ctrl+X", "editorFocus")
        c._cmd("editor.action.clipboardCopyAction", "Edit", "Copy", "Ctrl+C", "editorFocus")
        c._cmd("editor.action.clipboardPasteAction", "Edit", "Paste", "Ctrl+V", "editorFocus")
        c._cmd("actions.find", "Edit", "Find", "Ctrl+F", "")
        c._cmd("editor.action.startFindReplaceAction", "Edit", "Replace", "Ctrl+H", "")
        c._cmd("editor.action.nextMatchFindAction", "Edit", "Find Next", "F3", "")
        c._cmd("editor.action.previousMatchFindAction", "Edit", "Find Previous", "Shift+F3", "")
        c._cmd("workbench.action.findInFiles", "Edit", "Find in Files", "Ctrl+Shift+F", "")
        c._cmd("workbench.action.replaceInFiles", "Edit", "Replace in Files", "Ctrl+Shift+H", "")
        c._cmd("editor.action.commentLine", "Edit", "Toggle Line Comment", "Ctrl+/", "editorFocus")
        # Selection
        c._cmd("editor.action.selectAll", "Selection", "Select All", "Ctrl+A", "editorFocus")
        c._cmd("editor.action.expandLineSelection", "Selection", "Expand Line Selection", "Ctrl+L", "editorFocus")
        c._cmd("editor.action.copyLinesUpAction", "Selection", "Copy Line Up", "Shift+Alt+Up", "editorFocus")
        c._cmd("editor.action.copyLinesDownAction", "Selection", "Copy Line Down", "Shift+Alt+Down", "editorFocus")
        c._cmd("editor.action.moveLinesUpAction", "Selection", "Move Line Up", "Alt+Up", "editorFocus")
        c._cmd("editor.action.moveLinesDownAction", "Selection", "Move Line Down", "Alt+Down", "editorFocus")
        c._cmd("editor.action.deleteLines", "Selection", "Delete Line", "Ctrl+Shift+K", "editorFocus")
        c._cmd("editor.action.insertLineAfter", "Selection", "Insert Line Below", "Ctrl+Enter", "editorFocus")
        c._cmd("editor.action.insertLineBefore", "Selection", "Insert Line Above", "Ctrl+Shift+Enter", "editorFocus")
        c._cmd("editor.action.indentLines", "Selection", "Indent Line", "Ctrl+]", "editorFocus")
        c._cmd("editor.action.outdentLines", "Selection", "Outdent Line", "Ctrl+[", "editorFocus")
        c._cmd("editor.action.insertCursorAbove", "Selection", "Add Cursor Above", "Ctrl+Alt+Up", "editorFocus")
        c._cmd("editor.action.insertCursorBelow", "Selection", "Add Cursor Below", "Ctrl+Alt+Down", "editorFocus")
        c._cmd("editor.action.addSelectionToNextFindMatch", "Selection", "Add Next Occurrence", "Ctrl+D", "editorFocus")
        c._cmd("editor.action.selectHighlights", "Selection", "Select All Occurrences", "Ctrl+Shift+L", "editorFocus")
        c._cmd("editor.action.jumpToBracket", "Go", "Go to Bracket", "Ctrl+Shift+\\", "editorFocus")
        # View
        c._cmd("workbench.action.showCommands", "View", "Command Palette...", "Ctrl+Shift+P | F1", "")
        c._cmd("workbench.action.quickOpen", "Go", "Go to File...", "Ctrl+P", "")
        c._cmd("workbench.view.explorer", "View", "Explorer", "Ctrl+Shift+E", "")
        c._cmd("workbench.view.search", "View", "Search", "", "")
        c._cmd("workbench.view.scm", "View", "Source Control", "Ctrl+Shift+G", "")
        c._cmd("workbench.view.debug", "View", "Run and Debug", "Ctrl+Shift+D", "")
        c._cmd("workbench.view.extensions", "View", "Extensions", "Ctrl+Shift+X", "")
        c._cmd("outline.focus", "View", "Outline", "", "")
        c._cmd("nython.view.ai", "View", "AI Assistant", "", "")
        c._cmd("workbench.action.toggleSidebarVisibility", "View", "Toggle Primary Side Bar Visibility", "Ctrl+B", "")
        c._cmd("workbench.action.togglePanel", "View", "Toggle Panel Visibility", "Ctrl+J", "")
        c._cmd("workbench.action.toggleMaximizedPanel", "View", "Toggle Maximized Panel", "", "")
        c._cmd("workbench.actions.view.problems", "View", "Problems", "Ctrl+Shift+M", "")
        c._cmd("workbench.action.output.toggleOutput", "View", "Output", "Ctrl+Shift+U", "")
        c._cmd("workbench.debug.action.toggleRepl", "View", "Debug Console", "Ctrl+Shift+Y", "")
        c._cmd("workbench.action.terminal.toggleTerminal", "View", "Terminal", "Ctrl+`", "")
        c._cmd("nython.view.inspector", "View", "Compiler Inspector", "", "")
        c._cmd("nython.view.workshop", "View", "Language Workshop", "", "")
        c._cmd("editor.action.toggleMinimap", "View", "Toggle Minimap", "", "")
        c._cmd("editor.action.toggleRenderWhitespace", "View", "Toggle Render Whitespace", "", "")
        c._cmd("workbench.action.zoomIn", "View", "Zoom In", "Ctrl+= | Ctrl++ | Ctrl+Shift+=", "")
        c._cmd("workbench.action.zoomOut", "View", "Zoom Out", "Ctrl+-", "")
        c._cmd("workbench.action.zoomReset", "View", "Reset Zoom", "Ctrl+0", "")
        c._cmd("nython.toggleTheme", "View", "Toggle Light/Dark Theme", "", "")
        # Go
        c._cmd("workbench.action.gotoLine", "Go", "Go to Line/Column...", "Ctrl+G", "")
        c._cmd("workbench.action.gotoSymbol", "Go", "Go to Symbol in Editor...", "Ctrl+Shift+O", "")
        c._cmd("workbench.action.showAllSymbols", "Go", "Go to Symbol in Workspace...", "Ctrl+T", "")
        c._cmd("editor.action.revealDefinition", "Go", "Go to Definition", "F12", "editorFocus")
        c._cmd("references-view.findReferences", "Go", "Find All References", "Shift+F12", "editorFocus")
        c._cmd("editor.action.rename", "Edit", "Rename Symbol", "F2", "editorFocus")
        c._cmd("editor.action.changeAll", "Edit", "Change All Occurrences", "Ctrl+F2", "editorFocus")
        c._cmd("workbench.action.navigateBack", "Go", "Back", "Alt+Left", "")
        c._cmd("workbench.action.navigateForward", "Go", "Forward", "Alt+Right", "")
        c._cmd("workbench.action.nextEditor", "View", "Open Next Editor", "Ctrl+PageDown | Ctrl+Tab", "")
        c._cmd("workbench.action.previousEditor", "View", "Open Previous Editor", "Ctrl+PageUp | Ctrl+Shift+Tab", "")
        c._cmd("editor.action.marker.next", "Go", "Next Problem", "F8", "")
        c._cmd("editor.action.marker.prev", "Go", "Previous Problem", "Shift+F8", "")
        c._cmd("editor.action.triggerSuggest", "Edit", "Trigger Suggest", "Ctrl+Space", "editorFocus")
        # Run
        c._cmd("workbench.action.debug.start", "Run", "Start Debugging", "F5", "!inDebugMode")
        c._cmd("workbench.action.debug.run", "Run", "Run Without Debugging", "Ctrl+F5", "")
        c._cmd("workbench.action.debug.continue", "Debug", "Continue", "F5", "inDebugMode")
        c._cmd("workbench.action.debug.stop", "Debug", "Stop", "Shift+F5", "inDebugMode")
        c._cmd("workbench.action.debug.restart", "Debug", "Restart", "Ctrl+Shift+F5", "inDebugMode")
        c._cmd("workbench.action.debug.stepOver", "Debug", "Step Over", "F10", "inDebugMode")
        c._cmd("workbench.action.debug.stepInto", "Debug", "Step Into", "F11", "inDebugMode")
        c._cmd("workbench.action.debug.stepOut", "Debug", "Step Out", "Shift+F11", "inDebugMode")
        c._cmd("workbench.action.debug.stepBack", "Debug", "Step Back", "Ctrl+Shift+F11", "inDebugMode")
        c._cmd("workbench.action.debug.reverseContinue", "Debug", "Reverse Continue", "", "inDebugMode")
        c._cmd("editor.debug.action.toggleBreakpoint", "Run", "Toggle Breakpoint", "F9", "")
        c._cmd("workbench.debug.viewlet.action.removeAllBreakpoints", "Run", "Remove All Breakpoints", "", "")
        c._cmd("nython.runOnVM", "Run", "Run on Bytecode VM", "", "")
        c._cmd("nython.profile", "Run", "Profile", "", "")
        c._cmd("nython.tokenize", "Run", "Show Tokens", "", "")
        c._cmd("nython.showAST", "Run", "Show AST", "", "")
        c._cmd("nython.disassemble", "Run", "Show Bytecode", "", "")
        c._cmd("nython.checkSyntax", "Run", "Check Syntax", "", "")
        # Terminal
        c._cmd("workbench.action.terminal.new", "Terminal", "New Terminal", "Ctrl+Shift+`", "")
        c._cmd("workbench.action.terminal.clear", "Terminal", "Clear", "", "")
        c._cmd("workbench.action.terminal.runActiveFile", "Terminal", "Run Active File", "", "")
        # Source control
        c._cmd("git.refresh", "Git", "Refresh", "", "")
        c._cmd("git.commit", "Git", "Commit", "", "")
        c._cmd("git.stageAll", "Git", "Stage All Changes", "", "")
        c._cmd("git.unstageAll", "Git", "Unstage All Changes", "", "")
        c._cmd("git.stage", "Git", "Stage Changes", "", "")
        c._cmd("git.unstage", "Git", "Unstage Changes", "", "")
        c._cmd("git.clean", "Git", "Discard Changes", "", "")
        c._cmd("git.openChange", "Git", "Open Changes", "", "")
        c._cmd("git.checkout", "Git", "Checkout to...", "", "")
        c._cmd("git.init", "Git", "Initialize Repository", "", "")
        c._cmd("git.showLog", "Git", "Show Log", "", "")
        # Explorer
        c._cmd("explorer.newFile", "Explorer", "New File...", "", "")
        c._cmd("explorer.newFolder", "Explorer", "New Folder...", "", "")
        c._cmd("workbench.files.action.refreshFilesExplorer", "Explorer", "Refresh Explorer", "", "")
        c._cmd("workbench.files.action.collapseExplorerFolders", "Explorer", "Collapse Folders in Explorer", "", "")
        c._cmd("renameFile", "Explorer", "Rename...", "F2", "explorerFocus")
        c._cmd("deleteFile", "Explorer", "Delete", "Delete", "explorerFocus")
        c._cmd("copyFilePath", "File", "Copy Path", "Shift+Alt+C", "")
        c._cmd("copyRelativeFilePath", "File", "Copy Relative Path", "Ctrl+K Ctrl+Shift+Alt+C", "")
        c._cmd("workbench.files.action.showActiveFileInExplorer", "File", "Reveal Active File in Explorer View", "", "")
        # Status bar pickers
        c._cmd("changeEditorIndentation", "Editor", "Change Indentation...", "", "")
        c._cmd("editor.action.indentUsingSpaces", "Editor", "Indent Using Spaces", "", "")
        c._cmd("editor.action.indentUsingTabs", "Editor", "Indent Using Tabs", "", "")
        c._cmd("editor.action.detectIndentation", "Editor", "Detect Indentation from Content", "", "")
        c._cmd("editor.action.indentationToSpaces", "Editor", "Convert Indentation to Spaces", "", "")
        c._cmd("editor.action.indentationToTabs", "Editor", "Convert Indentation to Tabs", "", "")
        c._cmd("workbench.action.editor.changeEOL", "Editor", "Change End of Line Sequence", "", "")
        c._cmd("workbench.action.editor.changeEncoding", "Editor", "Change File Encoding", "", "")
        c._cmd("workbench.action.editor.changeLanguageMode", "Editor", "Change Language Mode", "Ctrl+K M", "")
        c._cmd("notifications.showList", "Notifications", "Show Notifications", "", "")
        c._cmd("notifications.clearAll", "Notifications", "Clear All Notifications", "", "")
        # Tools and help
        c._cmd("nython.ai.analyze", "AI", "Analyse Current File", "", "")
        c._cmd("nython.addHighlightToken", "Preferences", "Add Highlight Token...", "", "")
        c._cmd("nython.reloadHighlightRules", "Preferences", "Reload Highlight Rules", "", "")
        c._cmd("workbench.action.showWelcomePage", "Help", "Welcome", "", "")
        c._cmd("workbench.action.openDocumentationUrl", "Help", "Documentation", "", "")
        c._cmd("workbench.action.keybindingsReference", "Help", "Keyboard Shortcuts Reference", "Ctrl+K Ctrl+R", "")
        c._cmd("nython.about", "Help", "About", "", "")
        c._cmd("developer.dumpHitMap", "Developer", "Dump Clickable Regions", "Ctrl+Shift+Alt+D", "")
        c._cmd("developer.dumpState", "Developer", "Dump Workbench State", "Ctrl+Shift+Alt+J", "")

        self.menus = ["File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Help"]
        self.menu_items = {
            "File": ["workbench.action.files.newUntitledFile", "nython.newProject", "-",
                     "workbench.action.files.openFile", "workbench.action.files.openFolder", "nython.openProject", "workbench.action.openRecent", "-",
                     "workbench.action.files.save", "workbench.action.files.saveAs", "workbench.action.files.saveAll", "-",
                     "workbench.action.openSettings", "workbench.action.openGlobalKeybindings", "workbench.action.selectTheme", "-",
                     "workbench.action.files.revert", "workbench.action.closeActiveEditor", "workbench.action.closeFolder", "-",
                     "workbench.action.quit"],
            "Edit": ["undo", "redo", "-",
                     "editor.action.clipboardCutAction", "editor.action.clipboardCopyAction", "editor.action.clipboardPasteAction", "-",
                     "actions.find", "editor.action.startFindReplaceAction", "-",
                     "workbench.action.findInFiles", "workbench.action.replaceInFiles", "-",
                     "editor.action.commentLine", "editor.action.rename", "editor.action.changeAll"],
            "Selection": ["editor.action.selectAll", "editor.action.expandLineSelection", "-",
                          "editor.action.copyLinesUpAction", "editor.action.copyLinesDownAction",
                          "editor.action.moveLinesUpAction", "editor.action.moveLinesDownAction", "editor.action.deleteLines", "-",
                          "editor.action.insertCursorAbove", "editor.action.insertCursorBelow",
                          "editor.action.addSelectionToNextFindMatch", "editor.action.selectHighlights"],
            "View": ["workbench.action.showCommands", "-",
                     "workbench.view.explorer", "workbench.view.search", "workbench.view.scm", "workbench.view.debug",
                     "workbench.view.extensions", "outline.focus", "nython.view.ai", "-",
                     "workbench.actions.view.problems", "workbench.action.output.toggleOutput", "workbench.debug.action.toggleRepl",
                     "workbench.action.terminal.toggleTerminal", "nython.view.inspector", "nython.view.workshop", "-",
                     "workbench.action.toggleSidebarVisibility", "workbench.action.togglePanel", "editor.action.toggleMinimap",
                     "editor.action.toggleRenderWhitespace", "nython.toggleTheme", "-",
                     "workbench.action.zoomIn", "workbench.action.zoomOut", "workbench.action.zoomReset"],
            "Go": ["workbench.action.navigateBack", "workbench.action.navigateForward", "-",
                   "workbench.action.quickOpen", "workbench.action.nextEditor", "workbench.action.previousEditor", "-",
                   "workbench.action.gotoSymbol", "workbench.action.showAllSymbols", "-",
                   "editor.action.revealDefinition", "references-view.findReferences", "-",
                   "workbench.action.gotoLine", "editor.action.jumpToBracket", "-",
                   "editor.action.marker.next", "editor.action.marker.prev"],
            "Run": ["workbench.action.debug.start", "workbench.action.debug.run", "workbench.action.debug.stop",
                    "workbench.action.debug.restart", "-",
                    "workbench.action.debug.stepOver", "workbench.action.debug.stepInto", "workbench.action.debug.stepOut",
                    "workbench.action.debug.stepBack", "workbench.action.debug.continue", "-",
                    "editor.debug.action.toggleBreakpoint", "workbench.debug.viewlet.action.removeAllBreakpoints", "-",
                    "nython.runOnVM", "nython.profile", "nython.checkSyntax", "-",
                    "nython.tokenize", "nython.showAST", "nython.disassemble"],
            "Terminal": ["workbench.action.terminal.new", "workbench.action.terminal.runActiveFile", "workbench.action.terminal.clear"],
            "Help": ["workbench.action.showWelcomePage", "workbench.action.showCommands", "workbench.action.openDocumentationUrl", "-",
                     "workbench.action.keybindingsReference", "-", "nython.about"]
        }

    # Context keys for keybinding when-clauses.
    def _ctx_keys(self):
        var k = self.ctxk
        k["editorFocus"] = self.focus == "editor" and self._is_text()
        k["inputFocus"] = self.focus != "editor" and self.focus != "explorer" and self.focus != ""
        k["explorerFocus"] = self.focus == "explorer"
        k["inDebugMode"] = self.dbg.active
        k["terminalFocus"] = self.focus == "terminal"
        return k

    def _command_enabled(self, id):
        if id == "undo":
            return self._is_text() and self.buf().can_undo()
        if id == "redo":
            return self._is_text() and self.buf().can_redo()
        if id == "workbench.action.navigateBack":
            return self.nav.can_back()
        if id == "workbench.action.navigateForward":
            return self.nav.can_forward()
        if id == "workbench.action.reopenClosedEditor":
            return len(self.closed_stack) > 0
        if string_startswith(id, "workbench.action.debug.step") or id == "workbench.action.debug.continue" or id == "workbench.action.debug.stop" or id == "workbench.action.debug.restart" or id == "workbench.action.debug.reverseContinue":
            return self.dbg.active
        if id == "workbench.action.files.revert":
            return self.doc().kind == "file"
        return true

    # ── the dispatcher ───────────────────────────────────────────────────────
    # Every command, from every entry point, is carried out here. Returns true
    # when the id was recognised; an unknown id reports itself instead of
    # silently doing nothing (the old palette's failure mode).
    def _exec(self, id, arg):
        self._dirty = true
        # ── File ──
        if id == "workbench.action.files.newUntitledFile":
            self._new_untitled()
        elif id == "workbench.action.files.openFile":
            var base = self.ws.root
            if base == "":
                base = getcwd()
            self._open_path_prompt("openfile", "Open File", "Type a path; Tab completes, Enter opens", base + "/", false)
        elif id == "workbench.action.files.openFolder":
            var base2 = self.ws.root
            if base2 == "":
                base2 = getcwd()
            self._open_path_prompt("openfolder", "Open Folder", "Folder to open; Enter opens the folder shown", base2 + "/", true)
        elif id == "workbench.action.openRecent":
            self._open_recent_picker()
        elif id == "nython.newProject":
            var base3 = self.ws.root
            if base3 == "":
                base3 = getcwd()
            self._open_path_prompt("newproject", "New Project", "Folder to create the project in", path_join(base3, "MyProject"), true)
        elif id == "nython.openProject":
            var base4 = self.ws.root
            if base4 == "":
                base4 = getcwd()
            self._open_path_prompt("openproject", "Open Project", "Path to a .nyproj manifest", base4 + "/", false)
        elif id == "workbench.action.files.save":
            if self._save_doc(self.doc()) and self.doc().kind == "file":
                self._notify("Saved " + self.doc().title, "ok")
        elif id == "workbench.action.files.saveAs":
            if self._is_text() and self.doc().kind != "virtual":
                self._prompt_save_as(self.doc(), "")
        elif id == "workbench.action.files.saveAll":
            self._save_all()
        elif id == "workbench.action.files.revert":
            self._revert_doc()
        elif id == "workbench.action.closeActiveEditor":
            self._close_doc(self.active, false)
        elif id == "workbench.action.closeAllEditors":
            self._close_many(self._others(self.active, "all"))
        elif id == "workbench.action.closeOtherEditors":
            var t = self.active
            if arg != none and arg != "":
                t = arg
            self._close_many(self._others(t, "others"))
        elif id == "workbench.action.closeEditorsToTheRight":
            var t2 = self.active
            if arg != none and arg != "":
                t2 = arg
            self._close_many(self._others(t2, "right"))
        elif id == "workbench.action.closeUnmodifiedEditors":
            self._close_many(self._others(self.active, "saved"))
        elif id == "workbench.action.reopenClosedEditor":
            if len(self.closed_stack) > 0:
                var p = self.closed_stack[len(self.closed_stack) - 1]
                self.closed_stack.pop()
                self._open_path(p, -1, 0)
        elif id == "workbench.action.closeFolder":
            self._close_folder()
        elif id == "workbench.action.openSettings":
            self._open_settings_file()
        elif id == "workbench.action.openGlobalKeybindings" or id == "workbench.action.keybindingsReference":
            self._open_virtual("Keyboard Shortcuts", self._keybindings_text())
        elif id == "workbench.action.selectTheme":
            self._theme_picker()
        elif id == "workbench.action.quit":
            self._quit(false)
        # ── Edit ──
        elif id == "undo":
            self._undo()
        elif id == "redo":
            self._redo()
        elif id == "editor.action.clipboardCutAction":
            self._cut()
        elif id == "editor.action.clipboardCopyAction":
            self._copy()
        elif id == "editor.action.clipboardPasteAction":
            self._paste()
        elif id == "actions.find":
            self._open_find(false)
        elif id == "editor.action.startFindReplaceAction":
            self._open_find(true)
        elif id == "editor.action.nextMatchFindAction":
            if not self.find_open:
                self._open_find(false)
            self._find_step(1)
        elif id == "editor.action.previousMatchFindAction":
            if not self.find_open:
                self._open_find(false)
            self._find_step(0 - 1)
        elif id == "workbench.action.findInFiles" or id == "workbench.view.search":
            self._show_view("search")
            self.search_replace_open = false
            self.focus = "search"
            self.search_field = 0
            var w = self._selected_word()
            if w != "" and w != self.search_query:
                self.search_query = w
                self._run_search()
            self._le("search0").reset(self.search_query, true)
        elif id == "workbench.action.replaceInFiles":
            self._show_view("search")
            self.search_replace_open = true
            self.focus = "search"
            self.search_field = 0
            self._le("search0").reset(self.search_query, true)
        elif id == "editor.action.commentLine":
            self._toggle_comment()
        # ── Selection ──
        elif id == "editor.action.selectAll":
            self._select_all()
        elif id == "editor.action.expandLineSelection":
            self._expand_line_selection()
        elif id == "editor.action.copyLinesUpAction":
            self._copy_lines(0 - 1)
        elif id == "editor.action.copyLinesDownAction":
            self._copy_lines(1)
        elif id == "editor.action.moveLinesUpAction":
            self._move_lines(0 - 1)
        elif id == "editor.action.moveLinesDownAction":
            self._move_lines(1)
        elif id == "editor.action.deleteLines":
            self._delete_lines()
        elif id == "editor.action.insertLineAfter":
            self._insert_line(1)
        elif id == "editor.action.insertLineBefore":
            self._insert_line(0)
        elif id == "editor.action.indentLines":
            self._indent_selection(true)
        elif id == "editor.action.outdentLines":
            self._indent_selection(false)
        elif id == "editor.action.insertCursorAbove":
            self._add_caret_vertical(0 - 1)
        elif id == "editor.action.insertCursorBelow":
            self._add_caret_vertical(1)
        elif id == "editor.action.addSelectionToNextFindMatch":
            self._add_next_occurrence()
        elif id == "editor.action.selectHighlights" or id == "editor.action.changeAll":
            self._select_all_occurrences()
        elif id == "editor.action.jumpToBracket":
            self._jump_to_bracket()
        # ── View ──
        elif id == "workbench.action.showCommands":
            self._open_palette(">")
        elif id == "workbench.action.quickOpen":
            var pre = ""
            if arg != none and arg != "":
                pre = arg
            self._open_palette(pre)
        elif id == "workbench.view.explorer":
            self._show_view("explorer")
            self.focus = "explorer"
        elif id == "workbench.view.scm":
            self._show_view("scm")
            self.focus = "scm"
        elif id == "workbench.view.debug":
            self._show_view("debug")
        elif id == "workbench.view.extensions":
            self._show_view("ext")
            self.focus = "extsearch"
        elif id == "outline.focus":
            self._show_view("outline")
        elif id == "nython.view.ai":
            self._show_view("ai")
            self._ai_analyze(true)
        elif id == "workbench.action.toggleSidebarVisibility":
            self.sidebar_open = not self.sidebar_open
            self._save_settings()
        elif id == "workbench.action.togglePanel":
            self.panel_open = not self.panel_open
            if self.panel_open and self.active_panel == "terminal":
                self.focus = "terminal"
            elif not self.panel_open and self.focus != "editor":
                self.focus = "editor"
            self._save_settings()
        elif id == "workbench.action.toggleMaximizedPanel":
            self.panel_max = not self.panel_max
            self.panel_open = true
        elif id == "workbench.actions.view.problems":
            self._toggle_panel_tab("problems")
        elif id == "workbench.action.output.toggleOutput":
            self._toggle_panel_tab("output")
        elif id == "workbench.debug.action.toggleRepl":
            self._toggle_panel_tab("debug")
        elif id == "workbench.action.terminal.toggleTerminal":
            self._toggle_panel_tab("terminal")
        elif id == "nython.view.inspector":
            self._show_panel("inspector")
        elif id == "nython.view.workshop":
            self._show_panel("workshop")
        elif id == "editor.action.toggleMinimap":
            self.minimap_on = not self.minimap_on
            self._save_settings()
        elif id == "editor.action.toggleRenderWhitespace":
            self.show_whitespace = not self.show_whitespace
            self._save_settings()
        elif id == "workbench.action.zoomIn":
            self._zoom(1)
        elif id == "workbench.action.zoomOut":
            self._zoom(0 - 1)
        elif id == "workbench.action.zoomReset":
            self._zoom(13 - self.font_size)
        elif id == "nython.toggleTheme":
            self._set_theme(not self.th.dark)
            self._save_settings()
        # ── Go ──
        elif id == "workbench.action.gotoLine":
            self._open_palette(":")
        elif id == "workbench.action.gotoSymbol":
            self._open_palette("@")
        elif id == "workbench.action.showAllSymbols":
            self._open_palette("#")
        elif id == "editor.action.revealDefinition":
            self._goto_definition()
        elif id == "references-view.findReferences":
            self._find_references()
        elif id == "editor.action.rename":
            self._rename_symbol_prompt()
        elif id == "workbench.action.navigateBack":
            self._nav_go(self.nav.back())
        elif id == "workbench.action.navigateForward":
            self._nav_go(self.nav.forward())
        elif id == "workbench.action.nextEditor":
            self._activate((self.active + 1) % len(self.docs))
        elif id == "workbench.action.previousEditor":
            self._activate((self.active + len(self.docs) - 1) % len(self.docs))
        elif id == "editor.action.marker.next":
            self._next_problem(1)
        elif id == "editor.action.marker.prev":
            self._next_problem(0 - 1)
        elif id == "editor.action.triggerSuggest":
            self._ac_open_now(true)
        # ── Run ──
        elif id == "workbench.action.debug.start":
            self._debug_start()
        elif id == "workbench.action.debug.run" or id == "workbench.action.terminal.runActiveFile":
            self._run_active("Run")
        elif id == "nython.runOnVM":
            self._run_active("VM")
        elif id == "nython.profile":
            self._run_active("Profile")
        elif id == "nython.tokenize":
            self._run_active("Tokenize")
        elif id == "nython.showAST":
            self._run_active("AST")
        elif id == "nython.disassemble":
            self._run_active("Disasm")
        elif id == "nython.checkSyntax":
            if self._is_text():
                self._check_file(self.doc())
                self._show_panel("problems")
        elif id == "workbench.action.debug.continue":
            self._debug_continue(1)
        elif id == "workbench.action.debug.reverseContinue":
            self._debug_continue(0 - 1)
        elif id == "workbench.action.debug.stop":
            self._debug_stop()
        elif id == "workbench.action.debug.restart":
            self._debug_stop()
            self._debug_start()
        elif id == "workbench.action.debug.stepOver":
            self._debug_step("over")
        elif id == "workbench.action.debug.stepInto":
            self._debug_step("into")
        elif id == "workbench.action.debug.stepOut":
            self._debug_step("out")
        elif id == "workbench.action.debug.stepBack":
            self._debug_step("back")
        elif id == "editor.debug.action.toggleBreakpoint":
            if self._is_text():
                var row = self.buf().cursor_row
                if arg != none and arg != "":
                    row = arg
                self._toggle_break(row)
        elif id == "workbench.debug.viewlet.action.removeAllBreakpoints":
            self.breaks = {}
            self.break_list = []
            self.brk_gen = self.brk_gen + 1
            self._notify("All breakpoints removed", "info")
        # ── Terminal ──
        elif id == "workbench.action.terminal.new":
            self._show_panel("terminal")
            self.focus = "terminal"
            self._term_print("", "")
        elif id == "workbench.action.terminal.clear":
            self._panel_clear()
        # ── Source control ──
        elif string_startswith(id, "git."):
            self._git_command(id, arg)
        # ── Explorer ──
        elif id == "explorer.newFile":
            self._explorer_new(false, arg)
        elif id == "explorer.newFolder":
            self._explorer_new(true, arg)
        elif id == "workbench.files.action.refreshFilesExplorer":
            if self.ws.root != "":
                self.ws.rebuild()
                self.status_msg = "Explorer refreshed"
        elif id == "workbench.files.action.collapseExplorerFolders":
            if self.ws.root != "":
                self.ws.expanded = {}
                self.ws.expanded[self.ws.root] = true
                self.ws.rebuild()
                self.tree_scroll = 0
        elif id == "renameFile":
            self._explorer_rename(arg)
        elif id == "deleteFile":
            self._explorer_delete(arg)
        elif id == "copyFilePath":
            var cp = self._arg_path(arg)
            if cp != "":
                self._set_clipboard(cp)
                self._notify("Copied " + cp, "info")
        elif id == "copyRelativeFilePath":
            var cp2 = self._arg_path(arg)
            if cp2 != "":
                var rel = self._rel(cp2)
                self._set_clipboard(rel)
                self._notify("Copied " + rel, "info")
        elif id == "workbench.files.action.showActiveFileInExplorer":
            self._reveal_in_explorer(self._arg_path(arg))
        # ── Status bar pickers ──
        elif id == "changeEditorIndentation":
            self._indent_picker()
        elif id == "editor.action.indentUsingSpaces":
            self._indent_size_picker("spaces")
        elif id == "editor.action.indentUsingTabs":
            self._indent_size_picker("tabs")
        elif id == "editor.action.detectIndentation":
            if self._is_text():
                self._detect_indent(self.doc(), true)
        elif id == "editor.action.indentationToSpaces":
            self._convert_indent(false)
        elif id == "editor.action.indentationToTabs":
            self._convert_indent(true)
        elif id == "workbench.action.editor.changeEOL":
            self._eol_picker()
        elif id == "workbench.action.editor.changeEncoding":
            self._encoding_picker()
        elif id == "workbench.action.editor.changeLanguageMode":
            self._language_picker()
        elif id == "notifications.showList":
            self.notif_center = not self.notif_center
            self.notes.mark_read()
        elif id == "notifications.clearAll":
            self.notes.clear()
            self.notif_center = false
        # ── Tools and help ──
        elif id == "nython.ai.analyze":
            self._show_view("ai")
            self._ai_analyze(true)
            self._notify(str(self.ai_n) + " suggestion(s) for " + self.doc().title, "info")
        elif id == "nython.addHighlightToken":
            self._open_prompt("addtoken", "Add Highlight Token", "word, or word=r,g,b for a custom colour", "")
        elif id == "nython.reloadHighlightRules":
            self._load_hl_rules(true)
        elif id == "workbench.action.showWelcomePage":
            self._open_welcome()
        elif id == "workbench.action.openDocumentationUrl":
            self._open_docs()
        elif id == "nython.about":
            self._about()
        elif id == "developer.dumpHitMap":
            self._dump_hitmap()
        elif id == "developer.dumpState":
            self._dump_state()
        else:
            self._notify("Command '" + id + "' is not available", "warn")
            return false
        return true

    # ══ small shared helpers ═══════════════════════════════════════════════════
    def _notify(self, text, kind):
        self.notes.push(text, kind, time_ms())
        self.status_msg = text
        self._dirty = true

    def _set_clipboard(self, text):
        self.clipboard = text
        self.clip_line_mode = false
        gui_set_clipboard(text)

    def _get_clipboard(self):
        var sys = gui_get_clipboard()
        if sys != none and sys != "":
            if sys != self.clipboard:
                # Copied in another application since our last copy.
                self.clip_line_mode = false
            return sys
        return self.clipboard

    def _rel(self, path):
        if self.ws.root != "" and string_startswith(path, self.ws.root + "/"):
            return string_slice(path, len(self.ws.root) + 1, len(path))
        return path

    def _arg_path(self, arg):
        if arg != none and arg != "":
            return arg
        return self.doc().path

    def _hl_reset(self):
        self._hl_cache = {}
        self._diff_cache = {}
        self._hl_cache_n = 0

    # The highlight cache is keyed by a line's text, so an edit leaves every
    # unchanged line's entry valid; it is not cleared here. (Clearing it on
    # every keystroke re-tokenised every visible line per key, and on the
    # interpreter those segment lists are never reclaimed.)
    def _after_edit(self):
        self._dirty = true
        self._title_dirty = true
        self.scm_diff_due = time_ms() + 400
        self.check_due = time_ms() + 900

    # ══ editing ════════════════════════════════════════════════════════════════
    def _can_edit(self):
        if not self._is_text():
            return false
        if self.doc().readonly:
            self.status_msg = self.doc().title + " is read-only"
            return false
        return true

    def _sel_clear(self):
        self.doc().sel_on = false

    def _sel_begin(self):
        var d = self.doc()
        if not d.sel_on:
            d.sel_row = d.buf.cursor_row
            d.sel_col = d.buf.cursor_col
            d.sel_on = true

    # Ordered range, or none when nothing is selected.
    def _sel_range(self):
        var d = self.doc()
        if d.buf == none or not d.sel_on:
            return none
        var ar = d.sel_row
        var ac = d.sel_col
        var br = d.buf.cursor_row
        var bc = d.buf.cursor_col
        if ar == br and ac == bc:
            return none
        if br < ar or (br == ar and bc < ac):
            return [br, bc, ar, ac]
        return [ar, ac, br, bc]

    def _sel_text(self):
        var g = self._sel_range()
        if g == none:
            return ""
        return self.buf().text_range(g[0], g[1], g[2], g[3])

    def _sel_delete(self):
        var g = self._sel_range()
        if g == none:
            return false
        self.buf().delete_range(g[0], g[1], g[2], g[3])
        self.doc().sel_on = false
        self._after_edit()
        return true

    def _selected_word(self):
        if not self._is_text():
            return ""
        var s = self._sel_text()
        if s != "" and string_find(s, "\n") < 0:
            return s
        var b = self.buf()
        var w = b.word_at(b.cursor_row, b.cursor_col)
        return string_slice(b.get_line(b.cursor_row), w[0], w[1])

    def _select_all(self):
        if not self._is_text():
            return
        var d = self.doc()
        d.sel_on = true
        d.sel_row = 0
        d.sel_col = 0
        d.buf.cursor_row = d.buf.line_count - 1
        d.buf.cursor_col = len(d.buf.get_line(d.buf.cursor_row))
        self._clear_extra_carets()

    def _expand_line_selection(self):
        if not self._is_text():
            return
        var d = self.doc()
        var b = d.buf
        if not d.sel_on or self._sel_range() == none:
            d.sel_on = true
            d.sel_row = b.cursor_row
            d.sel_col = 0
        if b.cursor_row + 1 < b.line_count:
            b.cursor_row = b.cursor_row + 1
            b.cursor_col = 0
        else:
            b.cursor_col = len(b.get_line(b.cursor_row))
        self._reveal_caret()

    def _line_span(self):
        var g = self._sel_range()
        if g == none:
            var cr = self.buf().cursor_row
            return [cr, cr]
        var last = g[2]
        # A selection ending at column 0 does not include that line.
        if g[3] == 0 and g[2] > g[0]:
            last = g[2] - 1
        return [g[0], last]

    # Coarse multi-line edits: one snapshot, then rewrite the lines.
    def _toggle_comment(self):
        if not self._can_edit():
            return
        var b = self.buf()
        var sp = self._line_span()
        var all_commented = true
        var any_text = false
        var i = sp[0]
        var min_ind = 1000
        while i <= sp[1]:
            var line = b.get_line(i)
            var st = string_strip(line)
            if st != "":
                any_text = true
                if string_find(st, "#") != 0:
                    all_commented = false
                var ind = 0
                while ind < len(line) and string_slice(line, ind, ind + 1) == " ":
                    ind = ind + 1
                if ind < min_ind:
                    min_ind = ind
            i = i + 1
        if not any_text:
            return
        var crow = b.cursor_row
        var ccol = b.cursor_col
        var was = b.open_group()
        i = sp[0]
        while i <= sp[1]:
            var line2 = b.get_line(i)
            if string_strip(line2) != "":
                if all_commented:
                    var at = string_find(line2, "#")
                    var k = 1
                    if string_slice(line2, at + 1, at + 2) == " ":
                        k = 2
                    b.delete_range(i, at, i, at + k)
                    if i == crow and ccol > at:
                        ccol = ccol - k
                        if ccol < at:
                            ccol = at
                else:
                    b.insert_at(i, min_ind, "# ")
                    if i == crow and ccol >= min_ind:
                        ccol = ccol + 2
            i = i + 1
        b.close_group(was)
        b.cursor_row = crow
        b.cursor_col = self._clamp_col(crow, ccol)
        self._after_edit()

    def _clamp_col(self, row, col):
        var n = len(self.buf().get_line(row))
        if col > n:
            return n
        if col < 0:
            return 0
        return col

    def _copy_lines(self, dir):
        if not self._can_edit():
            return
        var b = self.buf()
        var sp = self._line_span()
        var blk = b.text_range(sp[0], 0, sp[1], len(b.get_line(sp[1])))
        var d = self.doc()
        b.begin_group()
        var save_c = b.cursor_col
        var save_r = b.cursor_row
        b.cursor_row = sp[1]
        b.cursor_col = len(b.get_line(sp[1]))
        b.insert_text("\n" + blk)
        var n = sp[1] - sp[0] + 1
        if dir > 0:
            b.cursor_row = save_r + n
            if d.sel_on:
                d.sel_row = d.sel_row + n
        else:
            b.cursor_row = save_r
        b.cursor_col = save_c
        b.begin_group()
        self._after_edit()
        self._reveal_caret()

    def _move_lines(self, dir):
        if not self._can_edit():
            return
        var b = self.buf()
        var sp = self._line_span()
        if dir < 0 and sp[0] == 0:
            return
        if dir > 0 and sp[1] >= b.line_count - 1:
            return
        var d = self.doc()
        var crow = b.cursor_row
        var ccol = b.cursor_col
        var was = b.open_group()
        if dir < 0:
            # The line above the block moves below it.
            var above = b.get_line(sp[0] - 1)
            b.delete_range(sp[0] - 1, 0, sp[0], 0)
            b.insert_at(sp[1] - 1, len(b.get_line(sp[1] - 1)), "\n" + above)
        else:
            var below = b.get_line(sp[1] + 1)
            b.delete_range(sp[1], len(b.get_line(sp[1])), sp[1] + 1, len(below))
            b.insert_at(sp[0], 0, below + "\n")
        b.close_group(was)
        b.cursor_row = crow + dir
        b.cursor_col = self._clamp_col(crow + dir, ccol)
        if d.sel_on:
            d.sel_row = d.sel_row + dir
        self._after_edit()
        self._reveal_caret()

    def _delete_lines(self):
        if not self._can_edit():
            return
        var b = self.buf()
        var sp = self._line_span()
        b.begin_group()
        if sp[1] + 1 < b.line_count:
            b.delete_range(sp[0], 0, sp[1] + 1, 0)
        elif sp[0] > 0:
            b.delete_range(sp[0] - 1, len(b.get_line(sp[0] - 1)), sp[1], len(b.get_line(sp[1])))
            b.cursor_row = sp[0] - 1
        else:
            b.delete_range(0, 0, sp[1], len(b.get_line(sp[1])))
        b.cursor_col = self._clamp_col(b.cursor_row, b.cursor_col)
        self.doc().sel_on = false
        b.begin_group()
        self._after_edit()

    def _insert_line(self, below):
        if not self._can_edit():
            return
        var b = self.buf()
        var line = b.get_line(b.cursor_row)
        var ind = 0
        while ind < len(line) and string_slice(line, ind, ind + 1) == " ":
            ind = ind + 1
        var pad = string_slice(line, 0, ind)
        b.begin_group()
        if below == 1:
            b.cursor_col = len(line)
            b.insert_text("\n" + pad)
        else:
            b.cursor_col = 0
            b.insert_text(pad + "\n")
            b.cursor_row = b.cursor_row - 1
            b.cursor_col = ind
        b.begin_group()
        self.doc().sel_on = false
        self._after_edit()
        self._reveal_caret()

    def _indent_selection(self, indent):
        if not self._can_edit():
            return
        var sp = self._line_span()
        var b = self.buf()
        var unit = self._indent_unit()
        b.begin_group()
        if indent:
            b.indent_lines(sp[0], sp[1], unit)
            var d = self.doc()
            if d.sel_on and string_strip(b.get_line(d.sel_row)) != "":
                d.sel_col = d.sel_col + len(unit)
            if string_strip(b.get_line(b.cursor_row)) != "":
                b.cursor_col = b.cursor_col + len(unit)
        else:
            var before = len(b.get_line(b.cursor_row))
            b.outdent_lines(sp[0], sp[1], unit)
            var removed = before - len(b.get_line(b.cursor_row))
            b.cursor_col = self._clamp_col(b.cursor_row, b.cursor_col - removed)
            var d2 = self.doc()
            if d2.sel_on:
                d2.sel_col = self._clamp_col(d2.sel_row, d2.sel_col)
        b.begin_group()
        self._after_edit()

    def _indent_unit(self):
        if not self.insert_spaces:
            return "\t"
        return " " * self.tab_size

    # The active editor's indentation becomes the workbench's (rendering of
    # tabs, Tab/Backspace, auto-indent all read tab_size / insert_spaces).
    def _sync_indent(self, d):
        if d.buf != none:
            if d.insert_spaces:
                d.buf.indent_unit = " " * d.tab_size
            else:
                d.buf.indent_unit = "\t"
        if self.tab_size != d.tab_size or self.insert_spaces != d.insert_spaces:
            self.tab_size = d.tab_size
            self.insert_spaces = d.insert_spaces
            self._hl_reset()
            self._status_cache_key = ""

    def _detect_indent(self, d, announce):
        if d.buf == none:
            return
        var g = detect_indentation(d.buf)
        if g == none:
            if announce:
                self._notify("Nothing indented to detect from; keeping " + self._indent_label(d), "info")
            return
        d.insert_spaces = g[0]
        if g[1] > 0:
            d.tab_size = g[1]
        if d == self.doc():
            self._sync_indent(d)
        if announce:
            self._notify("Detected " + self._indent_label(d), "info")

    def _indent_label(self, d):
        if d.insert_spaces:
            return "Spaces: " + str(d.tab_size)
        return "Tab Size: " + str(d.tab_size)

    def _convert_indent(self, to_tabs):
        if not self._can_edit():
            return
        var d = self.doc()
        d.buf.begin_group()
        var n = d.buf.convert_indentation(to_tabs, d.tab_size)
        d.buf.begin_group()
        d.insert_spaces = not to_tabs
        self._sync_indent(d)
        self._after_edit()
        var what = "spaces"
        if to_tabs:
            what = "tabs"
        self._notify("Converted " + str(n) + " line(s) to " + what, "info")

    # ── clipboard ────────────────────────────────────────────────────────────
    # Copy with no selection copies the whole line, and pasting such a copy
    # inserts it above the current line - VS Code's behaviour, which the old
    # _copy_line/_paste approximated by inserting BELOW and storing the text,
    # newlines included, as one entry in the line list.
    def _copy(self):
        if not self._is_text():
            return
        var s = self._sel_text()
        if s != "":
            self._set_clipboard(s)
            self.status_msg = "Copied " + str(len(s)) + " characters"
            return
        var b = self.buf()
        self._set_clipboard(b.get_line(b.cursor_row) + "\n")
        self.clip_line_mode = true
        self.status_msg = "Copied line " + str(b.cursor_row + 1)

    def _cut(self):
        if not self._can_edit():
            return
        var s = self._sel_text()
        if s != "":
            self._set_clipboard(s)
            self.buf().begin_group()
            self._sel_delete()
            self.buf().begin_group()
            return
        var b = self.buf()
        var row = b.cursor_row
        self._set_clipboard(b.get_line(row) + "\n")
        self.clip_line_mode = true
        self._delete_lines()

    def _paste(self):
        if not self._can_edit():
            return
        var text = self._get_clipboard()
        if text == "" or text == none:
            self.status_msg = "Clipboard is empty"
            return
        var b = self.buf()
        b.begin_group()
        if self._sel_range() != none:
            self._sel_delete()
            b.insert_text(text)
        elif self.clip_line_mode and string_endswith(text, "\n"):
            var col = b.cursor_col
            b.cursor_col = 0
            b.insert_text(text)
            b.cursor_col = col
        else:
            b.insert_text(text)
        b.begin_group()
        self.doc().sel_on = false
        self._after_edit()
        self._reveal_caret()

    # ── undo ─────────────────────────────────────────────────────────────────
    def _undo(self):
        if not self._is_text():
            return
        var b = self.buf()
        if not b.can_undo():
            self.status_msg = "Nothing to undo"
            return
        b.undo()
        self._clear_extra_carets()
        self.doc().sel_on = false
        self._after_edit()
        self._reveal_caret()

    def _redo(self):
        if not self._is_text():
            return
        var b = self.buf()
        if not b.can_redo():
            self.status_msg = "Nothing to redo"
            return
        b.redo()
        self.doc().sel_on = false
        self._after_edit()
        self._reveal_caret()

    # ── navigation ───────────────────────────────────────────────────────────
    def _goto(self, row, col):
        if not self._is_text():
            return
        var b = self.buf()
        var r = row
        if r < 0:
            r = 0
        if r >= b.line_count:
            r = b.line_count - 1
        b.cursor_row = r
        b.cursor_col = self._clamp_col(r, col)
        b.begin_group()
        self.doc().sel_on = false
        self._clear_extra_carets()
        self._reveal_caret_center()
        self._nav_record()

    def _nav_record(self):
        if len(self.docs) == 0 or self.active >= len(self.docs):
            return
        var d = self.docs[self.active]
        if d.buf == none or d.path == "":
            return
        self.nav.push(d.path, d.buf.cursor_row, d.buf.cursor_col)

    def _nav_go(self, loc):
        if loc == none:
            return
        var i = self._find_doc(loc["path"])
        if i < 0:
            if not self._open_path(loc["path"], -1, 0):
                return
            i = self.active
        self.active = i
        self._reveal_tab(i)
        var b = self.buf()
        b.cursor_row = loc["row"]
        if b.cursor_row >= b.line_count:
            b.cursor_row = b.line_count - 1
        b.cursor_col = self._clamp_col(b.cursor_row, loc["col"])
        self._reveal_caret_center()

    def _jump_to_bracket(self):
        if not self._is_text():
            return
        var m = self._bracket_partner()
        if m != none:
            self.buf().cursor_row = m[0]
            self.buf().cursor_col = m[1]
            self._reveal_caret()

    # The bracket at (or just before) the caret and its partner, searched
    # across lines. Returns [row, col] of the partner or none.
    def _bracket_partner(self):
        var b = self.buf()
        var row = b.cursor_row
        var line = b.get_line(row)
        var col = b.cursor_col
        var opens = "([{"
        var closes = ")]}"
        var ch = string_slice(line, col, col + 1)
        if string_find(opens + closes, ch) < 0 or ch == "":
            if col > 0:
                col = col - 1
                ch = string_slice(line, col, col + 1)
        if ch == "":
            return none
        var oi = string_find(opens, ch)
        var ci = string_find(closes, ch)
        if oi < 0 and ci < 0:
            return none
        var want = ""
        var step = 1
        if oi >= 0:
            want = string_slice(closes, oi, oi + 1)
        else:
            want = string_slice(opens, ci, ci + 1)
            step = 0 - 1
        var depth = 0
        var r = row
        var c = col
        var budget = 20000
        while budget > 0:
            var ln = b.get_line(r)
            while c >= 0 and c < len(ln):
                var cc = string_slice(ln, c, c + 1)
                if cc == ch:
                    depth = depth + 1
                elif cc == want:
                    depth = depth - 1
                    if depth == 0:
                        return [r, c, row, col]
                c = c + step
                budget = budget - 1
            r = r + step
            if r < 0 or r >= b.line_count:
                return none
            if step > 0:
                c = 0
            else:
                c = len(b.get_line(r)) - 1
        return none
