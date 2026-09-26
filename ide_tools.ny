# ══════════════════════════════════════════════════════════════════════════════
#  ide_tools.ny — the Code::Blocks side of the workbench
#
#  NythonIDE is one class split across a chain of files (see IDE_FILES.md);
#  this link, IDETools(IDEViews), holds what a Code::Blocks user reaches for
#  and VS Code leaves to extensions:
#
#    Build     build targets (Debug/Release: main file, engine, arguments,
#              working directory, environment, pre/post-build steps) with
#              Build, Compile Current File, Run, Build and Run, Rebuild,
#              Clean and Abort; a BUILD LOG panel; build messages in
#              Problems. The build is time-sliced: a few files per frame
#              within a latency budget, so the window never stops answering.
#    Keys      keymap presets (VS Code, Code::Blocks) and rebinding any
#              command by pressing the new key, saved in .nyide.
#    Editing   bookmarks, insert/overwrite mode, duplicate and transpose
#              lines, case conversion, abbreviations (snippets with tab
#              stops), format document/selection, go to next/previous
#              function.
#    Tools     TODO list, code statistics, a class wizard, user-defined
#              tools with $(MACROS), environment variables.
#    Debugger  run to cursor; breakpoint conditions, hit counts and log
#              messages.
# ══════════════════════════════════════════════════════════════════════════════
import "ide_views.ny"


# Code::Blocks' default keys for the commands both IDEs have. Applied over
# the VS Code defaults by the "Code::Blocks" keymap (Preferences: Keymap).
var CB_KEYMAP = [
    ["nython.build", "Ctrl+F9"],
    ["nython.compileFile", "Ctrl+Shift+F9"],
    ["nython.runTarget", "Ctrl+F10"],
    ["nython.buildAndRun", "F9"],
    ["nython.rebuild", "Ctrl+F11"],
    ["editor.action.marker.next", "Alt+F2"],
    ["editor.action.marker.prev", "Alt+F1"],
    ["editor.debug.action.toggleBreakpoint", "F5"],
    ["workbench.action.debug.start", "F8"],
    ["workbench.action.debug.continue", "F8"],
    ["nython.debug.runToCursor", "F4"],
    ["workbench.action.debug.stepOver", "F7"],
    ["workbench.action.debug.stepInto", "Shift+F7"],
    ["workbench.action.debug.stepOut", "Ctrl+F7"],
    ["workbench.action.debug.stop", "Shift+F8"],
    ["nython.bookmarks.toggle", "Ctrl+B"],
    ["nython.bookmarks.next", "Alt+PageDown"],
    ["nython.bookmarks.prev", "Alt+PageUp"],
    ["editor.action.duplicateSelection", "Ctrl+D"],
    ["editor.action.deleteLines", "Ctrl+L"],
    ["nython.transposeLines", "Ctrl+T"],
    ["editor.action.startFindReplaceAction", "Ctrl+R"],
    ["workbench.action.replaceInFiles", "Ctrl+Shift+R"],
    ["workbench.action.gotoSymbol", "Ctrl+Shift+G"],
    ["workbench.action.quickOpen", "Ctrl+P | Alt+G"],
    ["nython.expandAbbreviation", "Ctrl+J"],
    ["editor.action.transformToUppercase", "Ctrl+Shift+U"],
    ["editor.action.transformToLowercase", "Ctrl+U"],
    ["workbench.action.togglePanel", "F2"],
    ["workbench.action.toggleSidebarVisibility", "Shift+F2"],
    ["workbench.action.toggleFullScreen", "Ctrl+Shift+F12"],
    ["editor.action.commentLine", "Ctrl+Shift+C | Ctrl+/"]
]

# Built-in abbreviations: prefix, body, description. $<n:text> is a tab stop
# with default text, $0 the final caret position. (Snippets from .nyide use
# the VS Code form ${n:text}; a string literal here cannot, because Nython
# interpolates ${...} in string literals.)
var SNIPPETS = [
    ["def", "def $<1:name>($<2:args>):\n    $<0:pass>", "function"],
    ["class", "class $<1:Name>:\n    def __init__(self$<2:, value>):\n        $<0:pass>", "class with a constructor"],
    ["classd", "class $<1:Name>($<2:Base>):\n    def __init__(self$<3:, value>):\n        super().__init__()\n        $<0:pass>", "derived class"],
    ["method", "def $<1:name>(self$<2:, args>):\n    $<0:pass>", "method"],
    ["for", "for $<1:item> in $<2:items>:\n    $<0:pass>", "for loop"],
    ["fori", "var i = 0\nwhile i < $<1:n>:\n    $<0:pass>\n    i = i + 1", "counting loop"],
    ["while", "while $<1:condition>:\n    $<0:pass>", "while loop"],
    ["if", "if $<1:condition>:\n    $<0:pass>", "if"],
    ["ife", "if $<1:condition>:\n    $<2:pass>\nelse:\n    $<0:pass>", "if / else"],
    ["try", "try:\n    $<1:pass>\nexcept $<2:Exception> as e:\n    $<0:print(e)>", "try / except"],
    ["tryf", "try:\n    $<1:pass>\nfinally:\n    $<0:pass>", "try / finally"],
    ["with", "with $<1:resource> as $<2:name>:\n    $<0:pass>", "with"],
    ["match", "match $<1:value>:\n    case $<2:pattern>:\n        $<0:pass>", "match / case"],
    ["main", "def main():\n    $<0:pass>\n\n\nmain()", "main function"],
    ["pr", "print($<0>)", "print"],
    ["imp", "import \"$<0:lib/stdlib.ny>\"", "import"],
    ["struct", "struct $<1:Point>: $<0:x, y>", "struct"],
    ["enum", "enum $<1:Color>: $<0:RED, GREEN, BLUE>", "enum"],
    ["lam", "lambda $<1:x>: $<0:x>", "lambda"],
    ["todo", "# TODO: $<0>", "TODO comment"]
]


class IDETools(IDEViews):

    # ══ state ══════════════════════════════════════════════════════════════════
    def _tools_init(self):
        # Build targets and the time-sliced build.
        self.build_target = "Debug"
        self.targets = []
        self.targets_key = ""
        self.build_lines = []
        self.build_kinds = []
        self.build_queue = []
        self.build_i = 0
        self.build_running = false
        self.build_errors = 0
        self.build_t0 = 0
        self.build_then_run = false
        self.build_scope = "all"
        self.build_budget_ms = 8
        # Keymaps and rebinding.
        self.keymap = "vscode"
        self.keymap_default = none
        self.user_keys = []            # [keys, command id] from .nyide
        self.key_capture = ""          # command being rebound; "" when not capturing
        self.key_capture_seq = ""
        # Editing.
        self.overwrite = false
        self.ovr_doc = none
        self.ovr_seq = -1
        self.ovr_row = -1
        self.ovr_col = -1
        self.user_snippets = []        # [prefix, body] from .nyide
        self.snip_marks = []           # remaining tab stops: [row, col, len]
        self.snip_cur = []             # the tab stop being edited: [row, col, len]
        # Tools and environment.
        self.user_tools = []           # [name, command] from .nyide
        self.user_env = []             # "KEY=VALUE" from .nyide
        self.backup_on_save = false
        self.restore_editors = true
        self.tool_seq = 0
        # TODO list.
        self.todo_items = []
        self.todo_scope = "workspace"
        self.todo_key = ""
        # Class wizard answers so far.
        self.cw_name = ""
        self.cw_base = ""
        # Breakpoint extras: "file:line" -> {"cond": ..., "hits": ..., "log": ...}
        self.brk_extra = {}
        self.brk_edit_key = ""
        # Session restore: [path, row, col] of the editors open at exit.
        self.session_open = []
        self.session_active = ""
        self.session_root = ""

    # ══ commands and menus ═════════════════════════════════════════════════════
    # Called at the end of _register_commands (ide_core.ny).
    def _tools_register(self):
        var c = self
        # Build (Code::Blocks' Build menu; Ctrl+Shift+B is VS Code's build).
        c._cmd("nython.build", "Build", "Build", "Ctrl+Shift+B", "")
        c._cmd("nython.compileFile", "Build", "Compile Current File", "", "")
        c._cmd("nython.runTarget", "Build", "Run Target", "", "")
        c._cmd("nython.buildAndRun", "Build", "Build and Run", "", "")
        c._cmd("nython.rebuild", "Build", "Rebuild", "", "")
        c._cmd("nython.clean", "Build", "Clean", "", "")
        c._cmd("nython.abort", "Build", "Abort", "Shift+F5", "!inDebugMode")
        c._cmd("nython.selectTarget", "Build", "Select Target...", "", "")
        c._cmd("nython.editTargets", "Build", "Edit Build Targets...", "", "")
        c._cmd("nython.showBuildLog", "View", "Build Log", "", "")
        # Edit
        c._cmd("editor.action.duplicateSelection", "Edit", "Duplicate Selection", "", "editorFocus")
        c._cmd("nython.transposeLines", "Edit", "Transpose Lines", "", "editorFocus")
        c._cmd("editor.action.transformToUppercase", "Edit", "Transform to Uppercase", "", "editorFocus")
        c._cmd("editor.action.transformToLowercase", "Edit", "Transform to Lowercase", "", "editorFocus")
        c._cmd("editor.action.transformToTitlecase", "Edit", "Transform to Title Case", "", "editorFocus")
        c._cmd("editor.action.toggleOvertypeInsertMode", "Edit", "Toggle Insert/Overwrite Mode", "Insert", "editorFocus")
        c._cmd("editor.action.formatDocument", "Edit", "Format Document", "Shift+Alt+F", "editorFocus")
        c._cmd("editor.action.formatSelection", "Edit", "Format Selection", "Ctrl+K Ctrl+F", "editorFocus")
        c._cmd("nython.insertSnippet", "Edit", "Insert Snippet...", "", "editorFocus")
        c._cmd("nython.expandAbbreviation", "Edit", "Expand Abbreviation", "", "editorFocus")
        # Bookmarks (the VS Code Bookmarks extension's keys).
        c._cmd("nython.bookmarks.toggle", "Bookmarks", "Toggle Bookmark", "Ctrl+Alt+K", "editorFocus")
        c._cmd("nython.bookmarks.next", "Bookmarks", "Next Bookmark", "Ctrl+Alt+L", "editorFocus")
        c._cmd("nython.bookmarks.prev", "Bookmarks", "Previous Bookmark", "Ctrl+Alt+J", "editorFocus")
        c._cmd("nython.bookmarks.clear", "Bookmarks", "Clear Bookmarks", "", "")
        c._cmd("nython.bookmarks.list", "Bookmarks", "List Bookmarks...", "", "")
        # Folding
        c._cmd("editor.fold", "View", "Fold", "Ctrl+Shift+[", "editorFocus")
        c._cmd("editor.unfold", "View", "Unfold", "Ctrl+Shift+]", "editorFocus")
        c._cmd("editor.toggleFold", "View", "Toggle Fold", "Ctrl+K Ctrl+L", "editorFocus")
        c._cmd("editor.foldAll", "View", "Fold All", "Ctrl+K Ctrl+0", "editorFocus")
        c._cmd("editor.unfoldAll", "View", "Unfold All", "Ctrl+K Ctrl+J", "editorFocus")
        # Go
        c._cmd("nython.gotoNextFunction", "Go", "Go to Next Function", "", "editorFocus")
        c._cmd("nython.gotoPrevFunction", "Go", "Go to Previous Function", "", "editorFocus")
        # Tools
        c._cmd("nython.codeStats", "Tools", "Code Statistics", "", "")
        c._cmd("nython.newClass", "Tools", "New Class...", "", "")
        c._cmd("nython.todo", "View", "TODO List", "", "")
        c._cmd("nython.configureTools", "Tools", "Configure Tools...", "", "")
        c._cmd("nython.editEnvironment", "Tools", "Environment Variables...", "", "")
        c._cmd("nython.selectKeymap", "Preferences", "Keymap...", "", "")
        c._cmd("nython.rebindKey", "Preferences", "Change Keybinding...", "", "")
        # Debug
        c._cmd("nython.debug.runToCursor", "Debug", "Run to Cursor", "", "inDebugMode")
        c._cmd("nython.debug.editBreakpoint", "Run", "Edit Breakpoint...", "", "")
        c._cmd("nython.addToWatch", "Debug", "Add to Watch", "", "")
        # Window
        c._cmd("workbench.action.toggleFullScreen", "View", "Toggle Full Screen", "F11", "!inDebugMode")

        # Menus: Code::Blocks' Build and Tools join VS Code's bar.
        self.menus = ["File", "Edit", "Selection", "View", "Go", "Build", "Run", "Terminal", "Tools", "Help"]
        self.menu_mnemonics = ["f", "e", "s", "v", "g", "b", "r", "t", "o", "h"]
        var ed = self.menu_items["Edit"]
        ed.append("-")
        ed.append("editor.action.duplicateSelection")
        ed.append("nython.transposeLines")
        ed.append("editor.action.transformToUppercase")
        ed.append("editor.action.transformToLowercase")
        ed.append("editor.action.toggleOvertypeInsertMode")
        ed.append("-")
        ed.append("editor.action.formatDocument")
        ed.append("nython.insertSnippet")
        var vw = self.menu_items["View"]
        vw.append("-")
        vw.append("editor.fold")
        vw.append("editor.unfold")
        vw.append("editor.foldAll")
        vw.append("editor.unfoldAll")
        vw.append("-")
        vw.append("nython.showBuildLog")
        vw.append("nython.todo")
        vw.append("workbench.action.toggleFullScreen")
        var go = self.menu_items["Go"]
        go.append("-")
        go.append("nython.gotoPrevFunction")
        go.append("nython.gotoNextFunction")
        go.append("-")
        go.append("nython.bookmarks.toggle")
        go.append("nython.bookmarks.next")
        go.append("nython.bookmarks.prev")
        go.append("nython.bookmarks.list")
        go.append("nython.bookmarks.clear")
        var rn = self.menu_items["Run"]
        rn.append("-")
        rn.append("nython.debug.runToCursor")
        rn.append("nython.debug.editBreakpoint")
        self.menu_items["Build"] = ["nython.build", "nython.compileFile", "nython.runTarget", "nython.buildAndRun",
                                    "nython.rebuild", "nython.clean", "-", "nython.abort", "-",
                                    "nython.selectTarget", "nython.editTargets", "-",
                                    "editor.action.marker.next", "editor.action.marker.prev", "-", "nython.showBuildLog"]
        self._tools_menu()
        self.keymap_default = self.reg.snapshot()

    # The Tools menu, rebuilt when user tools change.
    def _tools_menu(self):
        var items = ["nython.codeStats", "editor.action.formatDocument", "nython.newClass", "nython.todo", "-"]
        var i = 0
        while i < len(self.user_tools):
            var id = "nython.tool." + str(i)
            self.reg.add(id, "Tools", self.user_tools[i][0], "", "")
            items.append(id)
            i = i + 1
        if len(self.user_tools) > 0:
            items.append("-")
        items.append("nython.configureTools")
        items.append("nython.editEnvironment")
        items.append("-")
        items.append("nython.selectKeymap")
        items.append("nython.rebindKey")
        self.menu_items["Tools"] = items

    # Commands this file implements; false for anything else.
    def _tools_exec(self, id, arg):
        if id == "nython.build":
            self._build_start("all", false)
        elif id == "nython.compileFile":
            self._build_start("current", false)
        elif id == "nython.runTarget":
            self._run_target()
        elif id == "nython.buildAndRun":
            self._build_start("all", true)
        elif id == "nython.rebuild":
            self._build_clean(false)
            self._build_start("all", false)
        elif id == "nython.clean":
            self._build_clean(true)
        elif id == "nython.abort":
            self._abort()
        elif id == "nython.selectTarget":
            self._target_picker()
        elif id == "nython.editTargets":
            self._edit_targets()
        elif id == "nython.showBuildLog":
            self._show_panel("buildlog")
        elif id == "editor.action.duplicateSelection":
            self._duplicate_selection()
        elif id == "nython.transposeLines":
            self._transpose_lines()
        elif id == "editor.action.transformToUppercase":
            self._transform_case("upper")
        elif id == "editor.action.transformToLowercase":
            self._transform_case("lower")
        elif id == "editor.action.transformToTitlecase":
            self._transform_case("title")
        elif id == "editor.action.toggleOvertypeInsertMode":
            self.overwrite = not self.overwrite
            if self.overwrite:
                self.status_msg = "Overwrite mode"
            else:
                self.status_msg = "Insert mode"
        elif id == "editor.action.formatDocument":
            self._format(false)
        elif id == "editor.action.formatSelection":
            self._format(true)
        elif id == "nython.insertSnippet":
            self._snippet_picker()
        elif id == "nython.expandAbbreviation":
            if not self._snippet_try():
                self._snippet_picker()
        elif id == "nython.bookmarks.toggle":
            self._bookmark_toggle()
        elif id == "nython.bookmarks.next":
            self._bookmark_jump(1)
        elif id == "nython.bookmarks.prev":
            self._bookmark_jump(0 - 1)
        elif id == "nython.bookmarks.clear":
            self._bookmark_clear()
        elif id == "nython.bookmarks.list":
            self._bookmark_list()
        elif id == "editor.fold":
            self._fold_at(true)
        elif id == "editor.unfold":
            self._fold_at(false)
        elif id == "editor.toggleFold":
            self._fold_toggle_at()
        elif id == "editor.foldAll":
            self._fold_all(true)
        elif id == "editor.unfoldAll":
            self._fold_all(false)
        elif id == "nython.gotoNextFunction":
            self._goto_function(1)
        elif id == "nython.gotoPrevFunction":
            self._goto_function(0 - 1)
        elif id == "nython.codeStats":
            self._code_stats()
        elif id == "nython.newClass":
            self._class_wizard()
        elif id == "nython.todo":
            self.todo_key = ""
            self._show_panel("todo")
        elif id == "nython.configureTools":
            self._configure_tools()
        elif id == "nython.editEnvironment":
            self._edit_environment()
        elif id == "nython.selectKeymap":
            self._pick("t.keymap", "Select Keymap", ["VS Code (default)", "Code::Blocks"], ["vscode", "codeblocks"], self.keymap)
        elif id == "nython.rebindKey":
            self._rebind_pick()
        elif id == "nython.debug.runToCursor":
            self._run_to_cursor()
        elif id == "nython.debug.editBreakpoint":
            self._edit_breakpoint(arg)
        elif id == "nython.addToWatch":
            self._add_to_watch(arg)
        elif id == "workbench.action.toggleFullScreen":
            self._toggle_fullscreen()
        elif string_startswith(id, "nython.tool."):
            self._run_tool(int(string_slice(id, 12, len(id))))
        else:
            return false
        return true

    # Quick Input actions this file owns ("t." prefix): prompts and pickers.
    def _tools_accept(self, action, value, item):
        var v = value
        if item != none:
            v = item.value
        if action == "t.keymap":
            self._apply_keymap(v)
            self._save_settings()
            self._notify("Keymap: " + self._keymap_name(), "ok")
        elif action == "t.target":
            if v == "__edit_targets__":
                self._edit_targets()
            else:
                self.build_target = v
                self._save_settings()
                self.status_msg = "Build target: " + v
        elif action == "t.snippet":
            self._snippet_insert(v)
        elif action == "t.rebind":
            self._rebind_start(v)
        elif action == "t.bookmark":
            var bar = string_find(v, "|")
            self._open_path(string_slice(v, 0, bar), int(string_slice(v, bar + 1, len(v))), 0)
        elif action == "t.classname":
            self._class_wizard_name(string_strip(value))
        elif action == "t.classbase":
            self.cw_base = string_strip(value)
            self._open_prompt("t.classfields", "New Class: Fields", "Constructor parameters stored as fields, separated by commas (optional)", "")
        elif action == "t.classfields":
            self._class_wizard_create(string_strip(value))
        elif action == "t.brkkind":
            self._edit_breakpoint_kind(v)
        elif action == "t.brkcond":
            self._set_brk_extra("cond", string_strip(value))
        elif action == "t.brkhits":
            self._set_brk_extra("hits", string_strip(value))
        elif action == "t.brklog":
            self._set_brk_extra("log", string_strip(value))

    # ══ build targets ══════════════════════════════════════════════════════════
    # A target is a map: name, main (relative to the project folder; "" runs
    # the active file), engine (interp | vm), args, cwd (relative), env
    # ("K=V; K2=V2"), pre and post (shell commands). They come from [target
    # Name] sections of the project's .nyproj; a folder without one gets
    # Debug (interpreter) and Release (bytecode VM) on the active file.
    def _target(self, name, main, engine):
        return {"name": name, "main": main, "engine": engine, "args": "", "cwd": "", "env": "", "pre": "", "post": ""}

    def _manifest(self):
        var p = self.ws.project
        if p.loaded and p.manifest != "" and os_exists(p.manifest):
            return p.manifest
        if self.ws.root != "":
            # A folder whose root holds exactly one .nyproj is that project.
            var ents = os_listdir(self.ws.root)
            var found = ""
            var n = 0
            var i = 0
            while ents != none and i < len(ents):
                if string_endswith(ents[i], ".nyproj"):
                    found = self.ws.root + "/" + ents[i]
                    n = n + 1
                i = i + 1
            if n == 1:
                return found
        return ""

    def _targets_list(self):
        var man = self._manifest()
        var key = man + "|" + str(file_mtime(man))
        if key == self.targets_key and len(self.targets) > 0:
            return self.targets
        var out = []
        var default_main = ""
        if man != "":
            var text = read_file(man)
            var lines = []
            if text != none:
                lines = string_split(text, "\n")
            var cur = none
            var i = 0
            while i < len(lines):
                var ln = string_strip(lines[i])
                if string_startswith(ln, "[target ") and string_endswith(ln, "]"):
                    cur = self._target(string_strip(string_slice(ln, 8, len(ln) - 1)), "", "interp")
                    out.append(cur)
                elif len(ln) > 0 and not string_startswith(ln, "#"):
                    var eq = string_find(ln, "=")
                    if eq > 0:
                        var k = string_strip(string_slice(ln, 0, eq))
                        var v = string_strip(string_slice(ln, eq + 1, len(ln)))
                        if cur == none:
                            if k == "target":
                                default_main = v
                        elif k == "main" or k == "engine" or k == "args" or k == "cwd" or k == "env" or k == "pre" or k == "post":
                            cur[k] = v
                i = i + 1
            # Sections without a main file use the project's target file.
            i = 0
            while i < len(out):
                if out[i]["main"] == "":
                    out[i]["main"] = default_main
                i = i + 1
        if len(out) == 0:
            out = [self._target("Debug", default_main, "interp"), self._target("Release", default_main, "vm")]
        self.targets = out
        self.targets_key = key
        return out

    def _active_target(self):
        var ts = self._targets_list()
        var i = 0
        while i < len(ts):
            if ts[i]["name"] == self.build_target:
                return ts[i]
            i = i + 1
        self.build_target = ts[0]["name"]
        return ts[0]

    def _target_picker(self):
        var ts = self._targets_list()
        var labels = []
        var values = []
        var i = 0
        while i < len(ts):
            var t = ts[i]
            var eng = "interpreter"
            if t["engine"] == "vm":
                eng = "bytecode VM"
            var main = t["main"]
            if main == "":
                main = "active file"
            labels.append(t["name"] + "  -  " + main + ", " + eng)
            values.append(t["name"])
            i = i + 1
        labels.append("Edit Build Targets...")
        values.append("__edit_targets__")
        self._pick("t.target", "Select Build Target", labels, values, self.build_target)

    # Opens the project file; a folder without one gets a project with the
    # two standard targets written out, so the format is there to edit.
    def _edit_targets(self):
        if self.ws.root == "":
            self._notify("Open a folder first", "warn")
            return
        var man = self._manifest()
        var body = ""
        if man == "":
            man = self.ws.root + "/" + os_path_basename(self.ws.root) + ".nyproj"
            body = "# Nython project\nname = " + os_path_basename(self.ws.root) + "\ntarget = main.ny\n"
        else:
            body = read_file(man)
            if body == none:
                body = ""
        if string_find(body, "[target ") < 0:
            if len(body) > 0 and not string_endswith(body, "\n"):
                body = body + "\n"
            body = body + "\n# Build targets (Build > Select Target). main is relative to this folder;\n"
            body = body + "# engine: interp | vm; args are passed to the program; env: K=V; K2=V2;\n"
            body = body + "# pre / post: shell commands run before / after a build.\n"
            body = body + "[target Debug]\nengine = interp\nargs =\ncwd =\nenv =\npre =\npost =\n\n"
            body = body + "[target Release]\nengine = vm\nargs =\ncwd =\nenv =\npre =\npost =\n"
            write_file(man, body)
            self.targets_key = ""
        if not self.ws.project.loaded:
            self.ws.project.load(man)
        self._open_path(man, -1, 0)

    # ══ the build ══════════════════════════════════════════════════════════════
    # Nython is interpreted, so "building" means what compiling does for a
    # Code::Blocks project: every source file of the target goes through the
    # real lexer and parser (ny_check_file / ny_check_syntax), errors land in
    # the BUILD LOG and in Problems, then the post-build step runs. Files are
    # checked a few at a time inside a per-frame budget (_build_step, from
    # _tick), so a large project never freezes the window.
    def _build_log(self, text, kind):
        self.build_lines.append(text)
        self.build_kinds.append(kind)
        if len(self.build_lines) > 5000:
            self.build_lines = self.build_lines[1000:]
            self.build_kinds = self.build_kinds[1000:]
        self._dirty = true

    def _build_clean(self, announce):
        self.build_lines = []
        self.build_kinds = []
        var i = 0
        var keep = []
        while i < len(self.problems):
            if self.problems[i]["src"] != "build":
                keep.append(self.problems[i])
            i = i + 1
        self.problems = keep
        self._count_problems()
        if announce:
            self._build_log("Cleaned: build messages and log cleared.", "info")
            self._show_panel("buildlog")

    def _build_start(self, scope, then_run):
        if self.build_running:
            self._notify("A build is already running (Build > Abort stops it)", "warn")
            return
        if scope == "current" and not self._is_text():
            self._notify("Open a Nython file to compile it", "warn")
            return
        if self.ws.root == "":
            scope = "current"
            if not self._is_text():
                self._notify("Open a folder or a Nython file to build", "warn")
                return
        var t = self._active_target()
        self.build_lines = []
        self.build_kinds = []
        self.build_t0 = time_ms()
        self.build_errors = 0
        self.build_then_run = then_run
        self.build_scope = scope
        var what = "folder " + os_path_basename(self.ws.root)
        if self._manifest() != "":
            what = self.ws.project.name
        if scope == "current":
            what = self.doc().title
        self._build_log("-------------- Build: " + t["name"] + " in " + what + " (" + self._engine_name(t["engine"]) + ") ---------------", "cmd")
        if t["pre"] != "" and scope == "all":
            if not self._build_shell_step("pre-build", t["pre"]):
                self._build_done()
                return
        var files = []
        if scope == "current":
            files.append(self.doc().path)
        else:
            var all = fs_list_files(self.ws.root, {"max": 4000, "full": true, "skip": ["build", "node_modules", "__pycache__"]})
            var i = 0
            while i < len(all):
                if string_endswith(all[i], ".ny"):
                    files.append(all[i])
                i = i + 1
        self.build_queue = files
        self.build_i = 0
        self.build_running = true
        self._show_panel("buildlog")
        self._build_step()

    def _engine_name(self, e):
        if e == "vm":
            return "bytecode VM"
        return "interpreter"

    # A pre/post-build command, synchronously: its output goes to the log.
    def _build_shell_step(self, label, cmd):
        self._build_log("Running " + label + " step: " + cmd, "info")
        var out = os_exec("cd " + self._q(self.ws.root) + " && ( " + self._env_prefix(self._active_target()) + cmd + " ) 2>&1; echo \"__nyrc=$?\"")
        if out == none:
            out = ""
        var lines = string_split(out, "\n")
        var rc = 0
        var i = 0
        while i < len(lines):
            if string_startswith(lines[i], "__nyrc="):
                rc = int_or_zero(string_slice(lines[i], 7, len(lines[i])))
            elif lines[i] != "":
                self._build_log("  " + lines[i], "out")
            i = i + 1
        if rc != 0:
            self._build_log(label + " step failed with exit status " + str(rc), "err")
            self.build_errors = self.build_errors + 1
            return false
        return true

    # Called every frame while a build runs.
    def _build_step(self):
        if not self.build_running:
            return
        var t0 = time_ms()
        while self.build_i < len(self.build_queue) and time_ms() - t0 < self.build_budget_ms:
            self._build_one(self.build_queue[self.build_i])
            self.build_i = self.build_i + 1
        if self.build_i >= len(self.build_queue):
            self._build_done()
        self._dirty = true

    def _build_one(self, path):
        var rel = self._rel(path)
        var diags = none
        var di = self._find_doc(path)
        if di >= 0 and self.docs[di].buf != none:
            diags = ny_check_syntax(self.docs[di].buf.lines)
        else:
            diags = ny_check_file(path)
        var probs = []
        var i = 0
        while i < len(diags):
            var g = diags[i]
            probs.append({"sev": "err", "msg": g[2], "path": path, "line": g[0] + 1, "col": g[1] + 1, "src": "syntax"})
            self._build_log(rel + ":" + str(g[0] + 1) + ":" + str(g[1] + 1) + ": error: " + g[2], "err")
            i = i + 1
        if len(diags) == 0:
            self._build_log("Checking " + rel + " ... ok", "dim")
        self.build_errors = self.build_errors + len(diags)
        self._set_problems_for(path, "syntax", probs)

    def _build_done(self):
        var t = self._active_target()
        self.build_running = false
        if self.build_errors == 0 and t["post"] != "" and self.build_scope == "all":
            self._build_shell_step("post-build", t["post"])
        var dt = time_ms() - self.build_t0
        var secs = str(int(dt / 1000)) + "." + string_slice(str(1000 + dt % 1000), 1, 3)
        var files = str(len(self.build_queue)) + " file(s)"
        if self.build_errors == 0:
            self._build_log("=== Build finished: 0 error(s), 0 warning(s), " + files + " (" + secs + " s) ===", "ok")
            self._notify("Build succeeded (" + files + ", " + secs + " s)", "ok")
            if self.build_then_run:
                self.build_then_run = false
                self._run_target()
        else:
            self._build_log("=== Build failed: " + str(self.build_errors) + " error(s), 0 warning(s), " + files + " (" + secs + " s) ===", "err")
            self._notify("Build failed: " + str(self.build_errors) + " error(s)", "err")
            self.build_then_run = false
            self._show_panel("problems")

    # Build > Abort, and Shift+F5 outside a debug session: whatever is
    # running - the build, the program, or a debug recording - stops.
    def _abort(self):
        if self.build_running:
            self.build_running = false
            self.build_then_run = false
            self._build_log("=== Build aborted ===", "warn")
            self.status_msg = "Build aborted"
            return
        if self.job_running:
            if self.dbg_recording:
                self._debug_stop()
            else:
                self._stop_job()
            self.status_msg = "Stopped"
            return
        self.status_msg = "Nothing is running"

    # ══ running a target ═══════════════════════════════════════════════════════
    def _env_prefix(self, t):
        var parts = []
        var i = 0
        while i < len(self.user_env):
            parts.append(self.user_env[i])
            i = i + 1
        if t != none and t["env"] != "":
            var te = string_split(t["env"], ";")
            i = 0
            while i < len(te):
                if string_strip(te[i]) != "":
                    parts.append(string_strip(te[i]))
                i = i + 1
        # `export K=v; cmd`, not `K=v cmd`: in the second form the shell
        # expands $K in cmd before the assignment exists, so a tool line
        # like `echo $GREET` saw nothing.
        var out = ""
        i = 0
        while i < len(parts):
            var eq = string_find(parts[i], "=")
            if eq > 0:
                var k = string_strip(string_slice(parts[i], 0, eq))
                if self._is_ident(k):
                    out = out + "export " + k + "=" + self._q(string_slice(parts[i], eq + 1, len(parts[i]))) + "; "
            i = i + 1
        return out

    def _run_target(self):
        if self.job_running:
            self._notify("A program is already running - stop it first (Shift+F5)", "warn")
            return
        var t = self._active_target()
        var path = ""
        if t["main"] != "" and self.ws.root != "":
            path = self.ws.root + "/" + t["main"]
            if not os_exists(path):
                self._notify("Target " + t["name"] + ": main file not found: " + t["main"], "err")
                return
        else:
            if not self._is_text():
                self._notify("Open a Nython file to run it", "warn")
                return
            path = self._path_for_run(self.doc())
        var cwd = self.ws.root
        if cwd == "":
            cwd = os_path_dirname(path)
        if t["cwd"] != "":
            cwd = cwd + "/" + t["cwd"]
        var flag = ""
        if t["engine"] == "vm":
            flag = "--vm "
        var line = self._env_prefix(t) + self._q(self._interpreter()) + " " + flag + self._q(path)
        if t["args"] != "":
            line = line + " " + t["args"]
        self.job_mode = "Run (" + t["name"] + ")"
        self.job_path = path
        self.job_doc = self.doc()
        self._output_clear()
        self._output_write("> " + t["name"] + ": " + self._rel(path) + " " + t["args"], "cmd")
        self._show_panel("output")
        self._start_job_line(line, cwd)

    # A background job from a complete shell command line (see BgProc).
    def _start_job_line(self, line, cwd):
        self.job_seq = self.job_seq + 1
        self.job = BgProc("/tmp/nyide_job_" + str(self.session_id) + "_" + str(self.job_seq))
        self.job.start(line, cwd)
        self.job_running = true
        self.job_t0 = time_ms()
        self.job_text = ""
        self.job_text_n = 0

    # ══ keymaps and rebinding ══════════════════════════════════════════════════
    def _keymap_name(self):
        if self.keymap == "codeblocks":
            return "Code::Blocks"
        return "VS Code"

    # Back to the defaults, then the preset, then the user's own bindings.
    def _apply_keymap(self, name):
        if self.keymap_default != none:
            self.reg.restore(self.keymap_default)
        self.keymap = "vscode"
        if name == "codeblocks":
            self.keymap = "codeblocks"
            var i = 0
            while i < len(CB_KEYMAP):
                var id = CB_KEYMAP[i][0]
                if self.reg.has(id):
                    self.reg.set_keys(id, CB_KEYMAP[i][1], self.reg.get(id).when)
                i = i + 1
        var j = 0
        while j < len(self.user_keys):
            var uk = self.user_keys[j]
            if self.reg.has(uk[1]):
                self.reg.set_keys(uk[1], uk[0], self.reg.get(uk[1]).when)
            j = j + 1

    def _rebind_pick(self):
        var items = []
        var i = 0
        while i < len(self.reg.order):
            var id = self.reg.order[i]
            var k = self.reg.keys_of(id)
            if k == "":
                k = "(unbound)"
            items.append(QuickItem(self.reg.label(id), k, id, "keyboard"))
            i = i + 1
        self._qi_focus()
        self.qi.open("pick", "Change Keybinding", "Choose the command to rebind", items, "")
        self.qi.action = "t.rebind"

    # The next key pressed becomes the command's binding (Enter confirms,
    # Escape cancels, Backspace removes the binding): the key-capture modal.
    def _rebind_start(self, id):
        self.key_capture = id
        self.key_capture_seq = ""
        self._modal("Press the new key combination for '" + self.reg.label(id) + "'",
                    "Currently: " + self._or_none(self.reg.keys_of(id)) + ". Press keys now; Enter to save, Escape to cancel, Backspace to remove the binding.",
                    [["Cancel", "@modal.cancel", ""]])

    def _or_none(self, s):
        if s == "":
            return "(unbound)"
        return s

    # Called by _modal_key while key_capture is set. True when handled.
    def _capture_key(self, e):
        if self.key_capture == "":
            return false
        var k = e.key
        if k == "escape":
            self.key_capture = ""
            self._modal_close()
            return true
        if k == "enter" and self.key_capture_seq != "":
            self._rebind_commit(self.key_capture, self.key_capture_seq)
            return true
        if k == "backspace" and self.key_capture_seq == "":
            self._rebind_commit(self.key_capture, "")
            return true
        var seq = self.reg.event_key(e)
        if seq == "" or seq == "ctrl" or seq == "shift" or seq == "alt" or string_endswith(seq, "+ctrl") or string_endswith(seq, "+shift") or string_endswith(seq, "+alt"):
            return true
        self.key_capture_seq = self.reg.pretty(seq)
        var used = self.reg.commands_for(self.key_capture_seq)
        var note = ""
        if len(used) > 0 and used[0] != self.key_capture:
            note = "  (currently " + self.reg.label(used[0]) + " - it will lose this key)"
        self.modal_msg = "Enter to bind " + self.key_capture_seq + note + ". Escape cancels."
        return true

    def _rebind_commit(self, id, keys):
        var kept = []
        var i = 0
        while i < len(self.user_keys):
            if self.user_keys[i][1] != id:
                kept.append(self.user_keys[i])
            i = i + 1
        kept.append([keys, id])
        self.user_keys = kept
        self.reg.set_keys(id, keys, self.reg.get(id).when)
        self.key_capture = ""
        self._modal_close()
        self._save_settings()
        if keys == "":
            self._notify(self.reg.label(id) + " is now unbound", "ok")
        else:
            self._notify(self.reg.label(id) + " is now " + keys, "ok")

    # ══ bookmarks ══════════════════════════════════════════════════════════════
    # Per document, a sorted list of rows; they move with lines inserted or
    # deleted above them (_tools_after_edit).
    def _bookmarks(self, d):
        if d.bookmarks == none:
            d.bookmarks = []
        return d.bookmarks

    def _bookmark_toggle(self):
        if not self._is_text():
            return
        var d = self.doc()
        var bm = self._bookmarks(d)
        var row = d.buf.cursor_row
        var out = []
        var had = false
        var i = 0
        while i < len(bm):
            if bm[i] == row:
                had = true
            else:
                out.append(bm[i])
            i = i + 1
        if not had:
            out.append(row)
            out = sorted(out)
        d.bookmarks = out
        if had:
            self.status_msg = "Bookmark removed from line " + str(row + 1)
        else:
            self.status_msg = "Bookmark set on line " + str(row + 1)

    def _bookmark_jump(self, dir):
        if not self._is_text():
            return
        var d = self.doc()
        var bm = self._bookmarks(d)
        if len(bm) == 0:
            self.status_msg = "No bookmarks in " + d.title
            return
        var row = d.buf.cursor_row
        var target = -1
        var i = 0
        if dir > 0:
            while i < len(bm) and target < 0:
                if bm[i] > row:
                    target = bm[i]
                i = i + 1
            if target < 0:
                target = bm[0]
        else:
            i = len(bm) - 1
            while i >= 0 and target < 0:
                if bm[i] < row:
                    target = bm[i]
                i = i - 1
            if target < 0:
                target = bm[len(bm) - 1]
        self._goto(target, 0)

    def _bookmark_clear(self):
        var i = 0
        while i < len(self.docs):
            self.docs[i].bookmarks = []
            i = i + 1
        self.status_msg = "All bookmarks cleared"

    def _bookmark_list(self):
        var items = []
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.buf != none and d.bookmarks != none:
                var j = 0
                while j < len(d.bookmarks):
                    var row = d.bookmarks[j]
                    if row < d.buf.line_count:
                        var text = string_strip(d.buf.get_line(row))
                        items.append(QuickItem(text, d.title + ":" + str(row + 1), d.path + "|" + str(row), "bookmark"))
                    j = j + 1
            i = i + 1
        if len(items) == 0:
            self._notify("No bookmarks (Toggle Bookmark: " + self._or_none(self.reg.keys_of("nython.bookmarks.toggle")) + ")", "info")
            return
        self._qi_focus()
        self.qi.open("pick", "Bookmarks", "Go to bookmark", items, "")
        self.qi.action = "t.bookmark"

    # After every edit: rows below an inserted/deleted block move with it.
    def _tools_after_edit(self):
        if not self._is_text():
            return
        var d = self.doc()
        var n = d.buf.line_count
        var delta = n - d.buf.track_lines
        d.buf.track_lines = n
        if delta == 0:
            return
        var at = d.buf.cursor_row - delta
        if delta < 0:
            at = d.buf.cursor_row
        # Lines were inserted inside row `at`. A mark on that row stays when
        # the break came after its text, and moves down with the text when
        # the break came before it (Enter at column 0 - the row left behind
        # is blank and the text now sits `delta` rows lower), which is what
        # Scintilla's markers and VS Code's decorations do.
        var carry = false
        if delta > 0:
            carry = string_strip(d.buf.get_line(at)) == "" and string_strip(d.buf.get_line(at + delta)) != ""
        if d.bookmarks != none and len(d.bookmarks) > 0:
            d.bookmarks = self._shift_rows(d.bookmarks, at, delta, n, carry)
        if d.folds != none and len(d.folds) > 0:
            d.folds = self._shift_rows(d.folds, at, delta, n, carry)
            d.fold_key = ""

    def _shift_rows(self, rows, at, delta, n, carry):
        var out = []
        var last = -1
        var i = 0
        while i < len(rows):
            var r = rows[i]
            if r == at and carry:
                r = r + delta
            elif r > at:
                r = r + delta
                if r <= at:
                    r = at
            if r >= 0 and r < n and r != last:
                out.append(r)
                last = r
            i = i + 1
        return out

    # ══ insert / overwrite ═════════════════════════════════════════════════════
    # Before a typed character in overwrite mode: the character under the
    # caret goes, in the same undo step as the one that replaces it.
    def _overwrite_prepare(self):
        if not self.overwrite or self.selmodel.count > 1 or self._sel_range() != none:
            return
        var b = self.buf()
        var line = b.get_line(b.cursor_row)
        if b.cursor_col < len(line):
            # A run of overtyping is one undo step, like a run of typing:
            # it continues when nothing happened since the last overtyped
            # character (same document, the caret right after it, and the
            # top undo entry still the character it typed).
            var d = self.doc()
            if self.ovr_doc == d and self.ovr_seq == b.state_id() and self.ovr_row == b.cursor_row and self.ovr_col == b.cursor_col:
                b.continue_group()
            else:
                b.begin_group()
            b.delete_range(b.cursor_row, b.cursor_col, b.cursor_row, b.cursor_col + 1)
            b.continue_group()
            # The character typed next is recorded with the next id.
            self.ovr_doc = d
            self.ovr_seq = b.op_seq + 1
            self.ovr_row = b.cursor_row
            self.ovr_col = b.cursor_col + 1

    # ══ line operations ════════════════════════════════════════════════════════
    # With a selection, the selection is inserted again after itself and the
    # copy selected (VS Code); without, the line is copied below (Code::Blocks'
    # Duplicate Line).
    def _duplicate_selection(self):
        if not self._can_edit():
            return
        var sel = self._sel_range()
        if sel == none:
            self._exec("editor.action.copyLinesDownAction", none)
            return
        var b = self.buf()
        var text = b.text_range(sel[0], sel[1], sel[2], sel[3])
        b.begin_group()
        b.cursor_row = sel[2]
        b.cursor_col = sel[3]
        b.insert_text(text)
        b.begin_group()
        var d = self.doc()
        d.sel_on = true
        d.sel_row = sel[2]
        d.sel_col = sel[3]
        self._after_edit()
        self._reveal_caret()

    # Code::Blocks' Transpose (Ctrl+T there): the caret's line swaps with the
    # line above; the caret stays on the same line number.
    def _transpose_lines(self):
        if not self._can_edit():
            return
        var b = self.buf()
        var row = b.cursor_row
        if row == 0 or row >= b.line_count:
            return
        var above = b.get_line(row - 1)
        var here = b.get_line(row)
        var col = b.cursor_col
        var g = b.open_group()
        b.delete_range(row - 1, 0, row, len(here))
        b.cursor_row = row - 1
        b.cursor_col = 0
        b.insert_text(here + "\n" + above)
        b.close_group(g)
        b.cursor_row = row
        b.cursor_col = col
        if b.cursor_col > len(above):
            b.cursor_col = len(above)
        self._sel_clear()
        self._after_edit()

    # The selection, or the word at the caret, in upper/lower/title case.
    def _transform_case(self, how):
        if not self._can_edit():
            return
        var b = self.buf()
        var d = self.doc()
        var sel = self._sel_range()
        if sel == none:
            var w = b.word_at(b.cursor_row, b.cursor_col)
            if w == none or w[0] >= w[1]:
                return
            sel = [b.cursor_row, w[0], b.cursor_row, w[1]]
        var text = b.text_range(sel[0], sel[1], sel[2], sel[3])
        var out = text
        if how == "upper":
            out = string_upper(text)
        elif how == "lower":
            out = string_lower(text)
        else:
            out = self._title_case(text)
        if out == text:
            return
        var g = b.open_group()
        b.delete_range(sel[0], sel[1], sel[2], sel[3])
        b.cursor_row = sel[0]
        b.cursor_col = sel[1]
        b.insert_text(out)
        b.close_group(g)
        d.sel_on = true
        d.sel_row = sel[0]
        d.sel_col = sel[1]
        self._after_edit()

    def _title_case(self, s):
        var out = ""
        var start = true
        var i = 0
        while i < len(s):
            var ch = string_slice(s, i, i + 1)
            var letter = (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")
            if letter and start:
                out = out + string_upper(ch)
            elif letter:
                out = out + string_lower(ch)
            else:
                out = out + ch
            start = not (letter or (ch >= "0" and ch <= "9") or ch == "'")
            i = i + 1
        return out

    # ══ abbreviations (snippets) ═══════════════════════════════════════════════
    def _snippet_body(self, prefix):
        var i = 0
        while i < len(self.user_snippets):
            if self.user_snippets[i][0] == prefix:
                return self.user_snippets[i][1]
            i = i + 1
        i = 0
        while i < len(SNIPPETS):
            if SNIPPETS[i][0] == prefix:
                return SNIPPETS[i][1]
            i = i + 1
        return none

    # Tab (or Expand Abbreviation) right after a snippet's prefix expands it.
    def _snippet_try(self):
        if not self._can_edit() or self._sel_range() != none or self.selmodel.count > 1:
            return false
        var b = self.buf()
        var line = b.get_line(b.cursor_row)
        var st = b.cursor_col
        while st > 0 and self._is_word_ch(string_slice(line, st - 1, st)):
            st = st - 1
        if st == b.cursor_col:
            return false
        var prefix = string_slice(line, st, b.cursor_col)
        var body = self._snippet_body(prefix)
        if body == none:
            return false
        var g = b.open_group()
        b.delete_range(b.cursor_row, st, b.cursor_row, b.cursor_col)
        b.cursor_col = st
        self._snippet_expand(body)
        b.close_group(g)
        return true

    # Snippet entries for the suggest popup: an exact prefix first, then
    # snippets whose prefix starts with the typed word, after the words.
    def _ac_add_snippets(self):
        var p = self.ac_prefix
        if len(p) < 1:
            return
        var exact = none
        var more = []
        var seen = {}
        var i = 0
        while i < len(self.user_snippets) + len(SNIPPETS):
            var name = ""
            if i < len(self.user_snippets):
                name = self.user_snippets[i][0]
            else:
                name = SNIPPETS[i - len(self.user_snippets)][0]
            if not seen.has_key(name):
                seen[name] = true
                if name == p:
                    exact = name
                elif len(name) > len(p) and string_slice(name, 0, len(p)) == p:
                    more.append(name)
            i = i + 1
        if exact == none and len(more) == 0:
            return
        var items = []
        var kinds = []
        if exact != none:
            items.append(exact)
            kinds.append("snippet")
        i = 0
        while i < len(self.ac_items):
            items.append(self.ac_items[i])
            kinds.append(self.ac_kinds[i])
            i = i + 1
        i = 0
        while i < len(more):
            items.append(more[i])
            kinds.append("snippet")
            i = i + 1
        self.ac_items = items
        self.ac_kinds = kinds

    def _snippet_picker(self):
        var labels = []
        var values = []
        var i = 0
        while i < len(self.user_snippets):
            labels.append(self.user_snippets[i][0] + "  -  your snippet")
            values.append(self.user_snippets[i][0])
            i = i + 1
        i = 0
        while i < len(SNIPPETS):
            labels.append(SNIPPETS[i][0] + "  -  " + SNIPPETS[i][2])
            values.append(SNIPPETS[i][0])
            i = i + 1
        self._pick("t.snippet", "Insert Snippet", labels, values, "")

    def _snippet_insert(self, prefix):
        var body = self._snippet_body(prefix)
        if body == none or not self._can_edit():
            return
        var b = self.buf()
        b.begin_group()
        if self._sel_range() != none:
            self._sel_delete()
        self._snippet_expand(body)

    # Inserts the body at the caret: continuation lines take the caret line's
    # indentation, four-space indents become the document's unit, and the tab
    # stops are remembered so Tab walks them ($1, $2, ... then $0).
    def _snippet_expand(self, body):
        var b = self.buf()
        var line = b.get_line(b.cursor_row)
        var ind = ""
        var k = 0
        while k < len(line) and (string_slice(line, k, k + 1) == " " or string_slice(line, k, k + 1) == "\t"):
            k = k + 1
        ind = string_slice(line, 0, k)
        var unit = b.indent_unit
        if unit == none or unit == "":
            unit = "    "
        var text = ""
        var marks = []       # [n, dr, dc, len]
        var dr = 0
        var dc = 0
        var i = 0
        var n = len(body)
        while i < n:
            var ch = string_slice(body, i, i + 1)
            if ch == "$" and i + 1 < n:
                var nx = string_slice(body, i + 1, i + 2)
                if nx == "{" or nx == "<":
                    var closer = "}"
                    if nx == "<":
                        closer = ">"
                    var close = string_find(string_slice(body, i, n), closer)
                    var inner = string_slice(body, i + 2, i + close)
                    var colon = string_find(inner, ":")
                    var num = inner
                    var dflt = ""
                    if colon >= 0:
                        num = string_slice(inner, 0, colon)
                        dflt = string_slice(inner, colon + 1, len(inner))
                    marks.append([int_or_zero(num), dr, dc, len(dflt)])
                    text = text + dflt
                    dc = dc + len(dflt)
                    i = i + close + 1
                    continue
                if nx >= "0" and nx <= "9":
                    marks.append([int_or_zero(nx), dr, dc, 0])
                    i = i + 2
                    continue
            if ch == "\n":
                text = text + "\n" + ind
                dr = dr + 1
                dc = len(ind)
                i = i + 1
                # Leading four-space groups -> the document's indent unit.
                while string_slice(body, i, i + 4) == "    ":
                    text = text + unit
                    dc = dc + len(unit)
                    i = i + 4
                continue
            text = text + ch
            dc = dc + 1
            i = i + 1
        var row0 = b.cursor_row
        var col0 = b.cursor_col
        b.insert_text(text)
        b.begin_group()
        # Absolute tab stops in order: 1, 2, ..., then 0 (the exit).
        var order = []
        var num2 = 1
        while num2 <= 9:
            var j = 0
            while j < len(marks):
                if marks[j][0] == num2:
                    order.append(marks[j])
                j = j + 1
            num2 = num2 + 1
        var j2 = 0
        while j2 < len(marks):
            if marks[j2][0] == 0:
                order.append(marks[j2])
            j2 = j2 + 1
        var stops = []
        j2 = 0
        while j2 < len(order):
            var m = order[j2]
            var c = m[2]
            if m[1] == 0:
                c = col0 + m[2]
            stops.append([row0 + m[1], c, m[3]])
            j2 = j2 + 1
        self._after_edit()
        self.snip_cur = []
        if len(stops) == 0:
            self.snip_marks = []
            return
        self.snip_marks = stops
        self._snippet_next()

    # Tab inside an expanded snippet: to the next tab stop, selecting its
    # default text. Stops on the same line after the one just edited move by
    # however much that edit changed its length.
    def _snippet_next(self):
        if len(self.snip_marks) == 0:
            return false
        var b = self.buf()
        var d = self.doc()
        if len(self.snip_cur) == 3 and b.cursor_row == self.snip_cur[0] and self._sel_range() == none:
            var delta = b.cursor_col - (self.snip_cur[1] + self.snip_cur[2])
            var i = 0
            while i < len(self.snip_marks):
                var m = self.snip_marks[i]
                if m[0] == self.snip_cur[0] and m[1] > self.snip_cur[1]:
                    m[1] = m[1] + delta
                i = i + 1
        var nx = self.snip_marks[0]
        var rest = []
        var k = 1
        while k < len(self.snip_marks):
            rest.append(self.snip_marks[k])
            k = k + 1
        self.snip_marks = rest
        self.snip_cur = nx
        if nx[0] >= b.line_count:
            self.snip_marks = []
            return false
        b.cursor_row = nx[0]
        b.cursor_col = nx[1] + nx[2]
        if nx[2] > 0:
            d.sel_on = true
            d.sel_row = nx[0]
            d.sel_col = nx[1]
        else:
            d.sel_on = false
        self._reveal_caret()
        return true

    # ══ formatting ═════════════════════════════════════════════════════════════
    # text_format_nython never reorders tokens: indentation re-expressed in
    # the document's unit by nesting level, trailing whitespace removed,
    # spacing after commas and around comparison/assignment operators, blank
    # runs capped. One undo step.
    def _format(self, selection_only):
        if not self._can_edit():
            return
        var d = self.doc()
        if d.lang != "nython":
            self._notify("Formatting is available for Nython files", "info")
            return
        var b = d.buf
        var unit = b.indent_unit
        if unit == none or unit == "":
            unit = "    "
        var r0 = 0
        var r1 = b.line_count - 1
        var sel = self._sel_range()
        if selection_only:
            if sel == none:
                r0 = b.cursor_row
                r1 = b.cursor_row
            else:
                r0 = sel[0]
                r1 = sel[2]
        var lines = []
        var i = r0
        while i <= r1:
            lines.append(b.get_line(i))
            i = i + 1
        # A slice is formatted relative to its first line's indentation.
        var base = ""
        if selection_only and len(lines) > 0:
            var k = 0
            var l0 = lines[0]
            while k < len(l0) and (string_slice(l0, k, k + 1) == " " or string_slice(l0, k, k + 1) == "\t"):
                k = k + 1
            base = string_slice(l0, 0, k)
            var j = 0
            while j < len(lines):
                if string_startswith(lines[j], base):
                    lines[j] = string_slice(lines[j], len(base), len(lines[j]))
                j = j + 1
        var out = text_format_nython(lines, unit, {})
        var new_lines = string_split(out, "\n")
        if selection_only:
            var j2 = 0
            while j2 < len(new_lines):
                if new_lines[j2] != "":
                    new_lines[j2] = base + new_lines[j2]
                j2 = j2 + 1
        # Trailing empty line of a whole document is the final newline.
        var changed = len(new_lines) != len(lines)
        i = 0
        while not changed and i < len(lines):
            if lines[i] != new_lines[i]:
                changed = true
            i = i + 1
        if not changed:
            self.status_msg = "Already formatted"
            return
        var row = b.cursor_row
        var col = b.cursor_col
        var g = b.open_group()
        b.delete_range(r0, 0, r1, len(b.get_line(r1)))
        b.cursor_row = r0
        b.cursor_col = 0
        b.insert_text(string_join(new_lines, "\n"))
        b.close_group(g)
        if row >= b.line_count:
            row = b.line_count - 1
        b.cursor_row = row
        b.cursor_col = col
        if b.cursor_col > len(b.get_line(row)):
            b.cursor_col = len(b.get_line(row))
        self._sel_clear()
        self._after_edit()
        self.status_msg = "Formatted " + str(r1 - r0 + 1) + " line(s)"

    # ══ code folding ═══════════════════════════════════════════════════════════
    # Indentation blocks and # region markers (text_fold_ranges). A document
    # keeps the header rows it has folded (d.folds); everything that maps
    # between buffer rows and screen rows - painting, clicks, scrolling,
    # caret movement - goes through _vrow_to_row / _row_to_vrow, which are
    # the identity until something is folded. The mapping is a short list of
    # visible spans, rebuilt only when the buffer or the folds change, so it
    # costs one entry per fold, not one per line.
    def _fold_ranges(self, d):
        var sid = d.buf.state_id()
        if d.fold_state != sid or d.fold_ranges == none:
            d.fold_ranges = text_fold_ranges(d.buf.lines, d.tab_size)
            d.fold_state = sid
        return d.fold_ranges

    # [start, end] of the fold region whose header is `row`, or none.
    def _fold_range_at(self, d, row):
        var rs = self._fold_ranges(d)
        var lo = 0
        var hi = len(rs) - 1
        while lo <= hi:
            var mid = int((lo + hi) / 2)
            if rs[mid][0] < row:
                lo = mid + 1
            elif rs[mid][0] > row:
                hi = mid - 1
            else:
                return rs[mid]
        return none

    # The innermost region containing `row` (header included).
    def _fold_range_around(self, d, row):
        var rs = self._fold_ranges(d)
        var best = none
        var i = 0
        while i < len(rs) and rs[i][0] <= row:
            if rs[i][1] >= row:
                best = rs[i]
            i = i + 1
        return best

    def _is_folded(self, d, row):
        if d.folds == none:
            return false
        var i = 0
        while i < len(d.folds):
            if d.folds[i] == row:
                return true
            i = i + 1
        return false

    # Visible spans [first_row, last_row] and their first screen rows.
    def _fold_map(self, d):
        var key = str(d.buf.state_id()) + ":" + str(len(d.folds))
        var i = 0
        while i < len(d.folds):
            key = key + "," + str(d.folds[i])
            i = i + 1
        if d.fold_key == key:
            return d.fold_spans
        var spans = []
        var starts = []
        var row = 0
        var v = 0
        var n = d.buf.line_count
        var fi = 0
        var folds = d.folds
        while row < n:
            # The next folded header at or after row.
            while fi < len(folds) and folds[fi] < row:
                fi = fi + 1
            var end = n - 1
            var skip_to = n
            if fi < len(folds):
                var rg = self._fold_range_at(d, folds[fi])
                if rg != none:
                    end = folds[fi]
                    skip_to = rg[1] + 1
                else:
                    fi = fi + 1
                    continue
            spans.append([row, end])
            starts.append(v)
            v = v + (end - row + 1)
            row = skip_to
            fi = fi + 1
        d.fold_spans = [spans, starts, v]
        d.fold_key = key
        return d.fold_spans

    def _vis_count(self, d):
        if d.folds == none or len(d.folds) == 0:
            return d.buf.line_count
        return self._fold_map(d)[2]

    def _vrow_to_row(self, d, v):
        if d.folds == none or len(d.folds) == 0:
            return v
        var m = self._fold_map(d)
        var spans = m[0]
        var starts = m[1]
        var k = len(spans) - 1
        while k > 0 and starts[k] > v:
            k = k - 1
        if k < 0:
            return v
        return spans[k][0] + (v - starts[k])

    def _row_to_vrow(self, d, row):
        if d.folds == none or len(d.folds) == 0:
            return row
        var m = self._fold_map(d)
        var spans = m[0]
        var starts = m[1]
        var k = 0
        while k < len(spans):
            if row < spans[k][0]:
                # Hidden: inside the fold whose header ended the previous span.
                if k == 0:
                    return 0
                return starts[k - 1] + (spans[k - 1][1] - spans[k - 1][0])
            if row <= spans[k][1]:
                return starts[k] + (row - spans[k][0])
            k = k + 1
        if len(spans) == 0:
            return 0
        return starts[len(spans) - 1] + (spans[len(spans) - 1][1] - spans[len(spans) - 1][0])

    # Unfolds whatever hides `row` (a jump, a search hit, a debug step).
    def _fold_reveal(self, d, row):
        if d.folds == none or len(d.folds) == 0:
            return
        var keep = []
        var changed = false
        var i = 0
        while i < len(d.folds):
            var rg = self._fold_range_at(d, d.folds[i])
            if rg != none and row > rg[0] and row <= rg[1]:
                changed = true
            else:
                keep.append(d.folds[i])
            i = i + 1
        if changed:
            d.folds = keep
            d.fold_key = ""

    def _fold_set(self, d, row, on):
        if d.folds == none:
            d.folds = []
        var keep = []
        var i = 0
        while i < len(d.folds):
            if d.folds[i] != row:
                keep.append(d.folds[i])
            i = i + 1
        if on:
            keep.append(row)
            keep = sorted(keep)
        d.folds = keep
        d.fold_key = ""
        self._clamp_scroll()
        self._dirty = true

    # Fold / Unfold act on the region the caret is in (its header, or the
    # innermost region containing the caret line).
    def _fold_at(self, on):
        if not self._is_text():
            return
        var d = self.doc()
        var row = d.buf.cursor_row
        var rg = self._fold_range_at(d, row)
        if rg == none:
            rg = self._fold_range_around(d, row)
        if rg == none:
            self.status_msg = "Nothing to fold here"
            return
        if on:
            d.buf.cursor_row = rg[0]
            if d.buf.cursor_col > len(d.buf.get_line(rg[0])):
                d.buf.cursor_col = len(d.buf.get_line(rg[0]))
            self._sel_clear()
        self._fold_set(d, rg[0], on)

    def _fold_toggle_at(self):
        if not self._is_text():
            return
        var d = self.doc()
        var row = d.buf.cursor_row
        if self._is_folded(d, row):
            self._fold_set(d, row, false)
        else:
            self._fold_at(true)

    def _fold_toggle_row(self, row):
        if not self._is_text():
            return
        var d = self.doc()
        if self._is_folded(d, row):
            self._fold_set(d, row, false)
        elif self._fold_range_at(d, row) != none:
            if d.buf.cursor_row > row and d.buf.cursor_row <= self._fold_range_at(d, row)[1]:
                d.buf.cursor_row = row
                d.buf.cursor_col = 0
            self._fold_set(d, row, true)

    def _fold_all(self, on):
        if not self._is_text():
            return
        var d = self.doc()
        if not on:
            d.folds = []
            d.fold_key = ""
            self._clamp_scroll()
            return
        # Top-level regions only (Fold All in VS Code folds every region;
        # folding the outermost ones hides the rest just the same).
        var rs = self._fold_ranges(d)
        var out = []
        var end = -1
        var i = 0
        while i < len(rs):
            if rs[i][0] > end:
                out.append(rs[i][0])
                end = rs[i][1]
            i = i + 1
        d.folds = out
        d.fold_key = ""
        var cr = d.buf.cursor_row
        var hdr = self._fold_range_around(d, cr)
        if hdr != none and self._is_folded(d, hdr[0]) and cr != hdr[0]:
            d.buf.cursor_row = hdr[0]
            d.buf.cursor_col = 0
        self._clamp_scroll()

    # ══ go to next / previous function ═════════════════════════════════════════
    def _goto_function(self, dir):
        if not self._is_text():
            return
        var syms = self._outline_syms()
        var row = self.buf().cursor_row
        var target = -1
        var col = 0
        var i = 0
        if dir > 0:
            while i < len(syms) and target < 0:
                var k = syms[i][1]
                if (k == "function" or k == "method" or k == "class") and syms[i][2] > row:
                    target = syms[i][2]
                    col = syms[i][3]
                i = i + 1
        else:
            i = len(syms) - 1
            while i >= 0 and target < 0:
                var k2 = syms[i][1]
                if (k2 == "function" or k2 == "method" or k2 == "class") and syms[i][2] < row:
                    target = syms[i][2]
                    col = syms[i][3]
                i = i - 1
        if target < 0:
            self.status_msg = "No more functions in this direction"
            return
        self._goto(target, col)

    # ══ TODO list ══════════════════════════════════════════════════════════════
    # TODO, FIXME, BUG, HACK, XXX, NOTE, OPTIMIZE and REVIEW in comments (not
    # strings), with an owner in parentheses: "# TODO(ana): ...". Workspace
    # (fs_todos) or current file (text_todos).
    def _todo_refresh(self):
        var key = self.todo_scope
        if self.todo_scope == "file":
            if not self._is_text():
                self.todo_items = []
                self.todo_key = "file:none"
                return
            key = "file:" + self.doc().title + ":" + str(self.buf().state_id())
        else:
            key = "ws:" + self.ws.root
        if key == self.todo_key:
            return
        self.todo_key = key
        var out = []
        if self.todo_scope == "file" or self.ws.root == "":
            var d = self.doc()
            if d.buf != none:
                var t = text_todos(d.buf.lines)
                var i = 0
                while i < len(t):
                    out.append([d.path, t[i][0], t[i][1], t[i][2], t[i][3], t[i][4], d.title])
                    i = i + 1
        else:
            var w = fs_todos(self.ws.root, [], 2000)
            var j = 0
            while j < len(w):
                out.append([self.ws.root + "/" + w[j][0], w[j][1], w[j][2], w[j][3], w[j][4], w[j][5], w[j][0]])
                j = j + 1
        self.todo_items = out

    def _todo_color(self, tag):
        var th = self.th
        if tag == "FIXME" or tag == "BUG":
            return th.err
        if tag == "HACK" or tag == "XXX":
            return th.warn
        if tag == "NOTE" or tag == "REVIEW":
            return th.text_faint
        return th.info

    def _draw_todo(self, r, x, y, w, h):
        var th = self.th
        self._todo_refresh()
        var lh = self.dp(22)
        # Scope switch and refresh.
        var sx = x + self.dp(14)
        var sy = y + self.dp(4)
        var labels = ["Workspace", "Current File"]
        var keys = ["workspace", "file"]
        var i = 0
        while i < 2:
            var lw = self.f_small.width(labels[i]) + self.dp(16)
            var on = self.todo_scope == keys[i]
            if on:
                r.fill_round_xywh(sx, sy, lw, self.dp(20), th.badge_bg, self.dp(4))
            elif self._hov(sx, sy, lw, self.dp(20)):
                r.fill_round_xywh(sx, sy, lw, self.dp(20), th.hover, self.dp(4))
            var fg = th.text_dim
            if on:
                fg = th.badge_fg
            r.text(labels[i], sx + self.dp(8), sy + int((self.dp(20) - self.small_h) / 2), self.f_small, fg)
            self._hit(sx, sy, lw, self.dp(20), "@todo.scope", keys[i], "Show TODOs in the " + string_lower(labels[i]))
            sx = sx + lw + self.dp(6)
            i = i + 1
        self._small_button(r, sx, sy - self.dp(2), self.dp(24), self.dp(24), "refresh", "@todo.refresh", "", "Rescan", false)
        var count = self._num(len(self.todo_items)) + " item(s)"
        r.text(count, sx + self.dp(34), sy + int((self.dp(20) - self.small_h) / 2), self.f_small, th.text_faint)
        var ty = y + self.dp(30)
        var rows = int((h - self.dp(34)) / lh)
        var n = len(self.todo_items)
        if n == 0:
            r.text("No TODO, FIXME, BUG, HACK, XXX or NOTE comments found.", x + self.dp(16), ty + self.dp(6), self.f_ui, th.text_faint)
            return
        var first = self.panel_scroll
        if first > n - rows:
            first = n - rows
        if first < 0:
            first = 0
        self.panel_scroll = first
        i = 0
        while i < rows and first + i < n:
            var it = self.todo_items[first + i]
            var ry = ty + i * lh
            if self._hov(x, ry, w, lh):
                r.fill_xywh(x, ry, w, lh, th.hover)
            var tc = self._todo_color(it[3])
            r.text(it[3], x + self.dp(16), ry + int((lh - self.small_h) / 2), self.f_small, tc)
            var tx = x + self.dp(86)
            r.text(it[4], tx, ry + int((lh - self.ui_h) / 2), self.f_ui, th.text)
            var where = it[6] + ":" + self._num(it[1] + 1)
            var ww = self.f_small.width(where)
            r.text(where, x + w - self.dp(16) - ww, ry + int((lh - self.small_h) / 2), self.f_small, th.text_faint)
            if it[5] != "":
                r.text("(" + it[5] + ")", x + w - self.dp(28) - ww - self.f_small.width("(" + it[5] + ")"), ry + int((lh - self.small_h) / 2), self.f_small, th.text_faint)
            self._hit(x, ry, w, lh, "@todo.item", first + i, it[6] + ":" + self._num(it[1] + 1))
            i = i + 1

    # ══ code statistics ════════════════════════════════════════════════════════
    # Code::Blocks' Code Statistics plugin: lines of code, comments, blank
    # lines and docstrings per file and for the whole workspace.
    def _code_stats(self):
        var rows = []
        if self.ws.root != "":
            rows = fs_line_stats(self.ws.root, "*.ny")
        elif self._is_text():
            var s = text_line_stats(self.buf().lines)
            rows = [[self.doc().title, s[0], s[1], s[2], s[3], s[4]]]
        if len(rows) == 0:
            self._notify("No Nython files to measure", "info")
            return
        var tot = [0, 0, 0, 0, 0]
        var i = 0
        while i < len(rows):
            var k = 0
            while k < 5:
                tot[k] = tot[k] + rows[i][k + 1]
                k = k + 1
            i = i + 1
        # Largest files first.
        var order = []
        i = 0
        while i < len(rows):
            order.append([0 - rows[i][2], i])
            i = i + 1
        order = sorted(order)
        var out = "Code Statistics - " + self._workspace_name() + "\n\n"
        out = out + "Files:            " + str(len(rows)) + "\n"
        out = out + "Total lines:      " + str(tot[0]) + "\n"
        out = out + "Code:             " + str(tot[1]) + self._pct(tot[1], tot[0]) + "\n"
        out = out + "Comments:         " + str(tot[2]) + self._pct(tot[2], tot[0]) + "\n"
        out = out + "Docstrings:       " + str(tot[4]) + self._pct(tot[4], tot[0]) + "\n"
        out = out + "Blank:            " + str(tot[3]) + self._pct(tot[3], tot[0]) + "\n"
        var cr = 0
        if tot[1] > 0:
            cr = int(((tot[2] + tot[4]) * 100) / tot[1])
        out = out + "Comments per 100 lines of code: " + str(cr) + "\n\n"
        out = out + self._pad("File", 52) + self._lpad("Total", 8) + self._lpad("Code", 8) + self._lpad("Comment", 9) + self._lpad("Blank", 8) + self._lpad("Doc", 7) + "\n"
        out = out + self._rep("-", 92) + "\n"
        i = 0
        while i < len(order):
            var rw = rows[order[i][1]]
            out = out + self._pad(rw[0], 52) + self._lpad(str(rw[1]), 8) + self._lpad(str(rw[2]), 8) + self._lpad(str(rw[3]), 9) + self._lpad(str(rw[4]), 8) + self._lpad(str(rw[5]), 7) + "\n"
            i = i + 1
        self._open_virtual("Code Statistics", out)

    def _rep(self, s, n):
        var out = ""
        var i = 0
        while i < n:
            out = out + s
            i = i + 1
        return out

    def _rfind(self, s, sub):
        var at = -1
        var i = string_find(s, sub)
        var base = 0
        while i >= 0:
            at = base + i
            base = at + 1
            i = string_find(string_slice(s, base, len(s)), sub)
        return at

    # Developer: Dump Workbench State - what these features believe.
    def _tools_dump(self, st):
        var d = self.doc()
        if d.buf != none:
            st["bookmarks"] = d.bookmarks
            st["folds"] = d.folds
            st["vis_rows"] = self._vis_count(d)
        st["overwrite"] = self.overwrite
        st["keymap"] = self.keymap
        st["build_target"] = self.build_target
        st["build_running"] = self.build_running
        st["build_log"] = self.build_lines
        st["todo_n"] = len(self.todo_items)
        st["snip_marks"] = len(self.snip_marks)
        st["menus"] = self.menus
        st["menu_compact"] = self.menu_compact
        st["side_overlay"] = self.side_overlay
        st["ac_open"] = self.ac_open

    def _pct(self, a, b):
        if b == 0:
            return ""
        return "  (" + str(int((a * 100) / b)) + "%)"

    def _pad(self, s, n):
        if len(s) >= n - 1:
            return string_slice(s, 0, n - 2) + "~ "
        return s + self._rep(" ", n - len(s))

    def _lpad(self, s, n):
        if len(s) >= n:
            return s
        return self._rep(" ", n - len(s)) + s

    # ══ class wizard ═══════════════════════════════════════════════════════════
    def _class_wizard(self):
        self.cw_name = ""
        self.cw_base = ""
        self._open_prompt("t.classname", "New Class", "Class name, e.g. ShoppingCart", "")

    def _is_ident(self, s):
        if s == "":
            return false
        var i = 0
        while i < len(s):
            var ch = string_slice(s, i, i + 1)
            var ok = (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or ch == "_" or (i > 0 and ch >= "0" and ch <= "9")
            if not ok:
                return false
            i = i + 1
        return true

    def _class_wizard_name(self, name):
        if not self._is_ident(name):
            self._notify("'" + name + "' is not a valid class name", "err")
            return
        self.cw_name = name
        self._open_prompt("t.classbase", "New Class: Base Class", "Base class to inherit from (leave empty for none)", "")

    # "ShoppingCart" -> "shopping_cart"
    def _snake(self, name):
        var out = ""
        var i = 0
        while i < len(name):
            var ch = string_slice(name, i, i + 1)
            if ch >= "A" and ch <= "Z":
                if i > 0 and string_slice(name, i - 1, i) != "_":
                    out = out + "_"
                out = out + string_lower(ch)
            else:
                out = out + ch
            i = i + 1
        return out

    # The folder new files go to: the selected folder in the Explorer, else
    # the active file's folder, else the workspace.
    def _target_folder(self):
        if self.tree_sel >= 0 and self.tree_sel < len(self.ws.rows):
            var row = self.ws.rows[self.tree_sel]
            if row.is_dir:
                return row.path
            return os_path_dirname(row.path)
        if self.doc().kind == "file":
            return os_path_dirname(self.doc().path)
        return self.ws.root

    def _class_wizard_create(self, fields_text):
        var name = self.cw_name
        if name == "":
            return
        var base = self.cw_base
        if base != "" and not self._is_ident(base):
            self._notify("'" + base + "' is not a valid base class name", "err")
            return
        var fields = []
        var parts = string_split(fields_text, ",")
        var i = 0
        while i < len(parts):
            var f = string_strip(parts[i])
            if f != "":
                if not self._is_ident(f):
                    self._notify("'" + f + "' is not a valid field name", "err")
                    return
                fields.append(f)
            i = i + 1
        var dir = self._target_folder()
        if dir == "":
            self._notify("Open a folder first", "warn")
            return
        var path = dir + "/" + self._snake(name) + ".ny"
        if os_exists(path):
            self._notify(os_path_basename(path) + " already exists", "err")
            return
        var decl = "class " + name + ":"
        if base != "":
            decl = "class " + name + "(" + base + "):"
        var params = ""
        i = 0
        while i < len(fields):
            params = params + ", " + fields[i]
            i = i + 1
        var body = "# " + os_path_basename(path) + " - " + name + "\n\n\n" + decl + "\n"
        body = body + "    def __init__(self" + params + "):\n"
        if base != "":
            body = body + "        super().__init__()\n"
        i = 0
        while i < len(fields):
            body = body + "        self." + fields[i] + " = " + fields[i] + "\n"
            i = i + 1
        if len(fields) == 0 and base == "":
            body = body + "        pass\n"
        body = body + "\n    def __str__(self):\n"
        if len(fields) == 0:
            body = body + "        return \"" + name + "()\"\n"
        else:
            var repr = "\"" + name + "(\""
            i = 0
            while i < len(fields):
                var sep = ", "
                if i == 0:
                    sep = ""
                repr = repr + " + \"" + sep + fields[i] + "=\" + str(self." + fields[i] + ")"
                i = i + 1
            body = body + "        return " + repr + " + \")\"\n"
        if not write_file(path, body):
            self._notify("Could not write " + path, "err")
            return
        self._refresh_tree_keep()
        self._open_path(path, 3, 0)
        self._notify("Created class " + name + " in " + self._rel(path), "ok")

    # ══ user tools and environment ═════════════════════════════════════════════
    # .nyide lines:  tool = Name | command with $(MACROS)
    #                env = KEY=VALUE
    # Tools appear in the Tools menu and the palette; their output goes to the
    # Output panel. Environment variables apply to runs, targets and tools.
    def _macro(self, s):
        var d = self.doc()
        var file = d.path
        var out = s
        out = string_replace(out, "$(FILE)", file)
        out = string_replace(out, "$(FILE_NAME)", os_path_basename(file))
        out = string_replace(out, "$(FILE_DIR)", os_path_dirname(file))
        var base = os_path_basename(file)
        var dot = self._rfind(base, ".")
        if dot > 0:
            base = string_slice(base, 0, dot)
        out = string_replace(out, "$(FILE_BASE)", base)
        out = string_replace(out, "$(PROJECT_DIR)", self.ws.root)
        out = string_replace(out, "$(WORKSPACE)", self.ws.root)
        out = string_replace(out, "$(NYTHON)", self._interpreter())
        var t = self._active_target()
        out = string_replace(out, "$(TARGET)", t["name"])
        out = string_replace(out, "$(TARGET_MAIN)", t["main"])
        if d.buf != none:
            out = string_replace(out, "$(LINE)", str(d.buf.cursor_row + 1))
            out = string_replace(out, "$(COLUMN)", str(d.buf.cursor_col + 1))
            out = string_replace(out, "$(WORD)", self._selected_word())
            out = string_replace(out, "$(SELECTION)", self._sel_text())
        return out

    def _run_tool(self, i):
        if i < 0 or i >= len(self.user_tools):
            return
        if self.job_running:
            self._notify("A program is already running - stop it first (Shift+F5)", "warn")
            return
        var t = self.user_tools[i]
        var cmd = self._macro(t[1])
        var cwd = self.ws.root
        if cwd == "":
            cwd = os_path_dirname(self.doc().path)
        if cwd == "":
            cwd = "."
        self.job_mode = t[0]
        self.job_path = self.doc().path
        self.job_doc = self.doc()
        self._output_clear()
        self._output_write("> " + t[0] + ": " + cmd, "cmd")
        self._show_panel("output")
        self._start_job_line(self._env_prefix(none) + cmd, cwd)

    # Opens .nyide at the section, adding an example the first time.
    def _settings_section(self, key, example):
        var p = self._settings_path()
        if p == "":
            self._notify("Open a folder first: settings live in its .nyide", "warn")
            return
        if not os_exists(p):
            write_file(p, self._settings_text())
        var text = read_file(p)
        if text == none:
            text = ""
        if string_find(text, "\n" + key + " =") < 0 and string_find(text, "\n# " + key + " =") < 0:
            if not string_endswith(text, "\n"):
                text = text + "\n"
            text = text + example
            write_file(p, text)
        var lines = string_split(read_file(p), "\n")
        var row = 0
        var i = 0
        while i < len(lines):
            if string_startswith(lines[i], key + " =") or string_startswith(lines[i], "# " + key + " ="):
                row = i
                i = len(lines)
            i = i + 1
        self._open_path(p, row, 0)

    def _configure_tools(self):
        self._settings_section("tool", "# User tools (Tools menu): tool = Name | command. Macros: $(FILE) $(FILE_NAME)\n# $(FILE_DIR) $(FILE_BASE) $(PROJECT_DIR) $(LINE) $(COLUMN) $(WORD) $(SELECTION)\n# $(NYTHON) $(TARGET) $(TARGET_MAIN). Save the file to apply.\n# tool = Word count | wc -l $(FILE)\n")

    def _edit_environment(self):
        self._settings_section("env", "# Environment variables for runs, build targets and tools: env = KEY=VALUE\n# env = NYTHON_DEBUG=1\n")

    # ══ settings and session hooks ═════════════════════════════════════════════
    def _tools_settings_reset(self):
        self.user_tools = []
        self.user_env = []
        self.user_snippets = []
        self.user_keys = []

    # One "key = value" line of .nyide; true when it was one of these keys.
    def _tools_setting(self, k, v):
        if k == "keymap":
            if v == "codeblocks" or v == "vscode":
                self.keymap = v
        elif k == "build_target":
            self.build_target = v
        elif k == "backup_on_save":
            self.backup_on_save = v == "true"
        elif k == "restore_editors":
            self.restore_editors = v != "false"
        elif k == "tool":
            var bar = string_find(v, "|")
            if bar > 0:
                self.user_tools.append([string_strip(string_slice(v, 0, bar)), string_strip(string_slice(v, bar + 1, len(v)))])
        elif k == "env":
            if string_find(v, "=") > 0:
                self.user_env.append(v)
        elif k == "snippet":
            var bar2 = string_find(v, "|")
            if bar2 > 0:
                var body = string_strip(string_slice(v, bar2 + 1, len(v)))
                body = string_replace(string_replace(body, "\\n", "\n"), "\\t", "\t")
                self.user_snippets.append([string_strip(string_slice(v, 0, bar2)), body])
        elif k == "keybinding":
            var bar3 = string_find(v, "|")
            if bar3 >= 0:
                self.user_keys.append([string_strip(string_slice(v, 0, bar3)), string_strip(string_slice(v, bar3 + 1, len(v)))])
        else:
            return false
        return true

    def _tools_settings_loaded(self):
        self._tools_menu()
        self._apply_keymap(self.keymap)
        self.targets_key = ""

    def _tools_settings_text(self):
        var body = "# vscode | codeblocks\nkeymap = " + self.keymap + "\n"
        body = body + "build_target = " + self.build_target + "\n"
        body = body + "backup_on_save = " + str(self.backup_on_save) + "\n"
        body = body + "restore_editors = " + str(self.restore_editors) + "\n"
        var i = 0
        while i < len(self.user_keys):
            body = body + "keybinding = " + self.user_keys[i][0] + " | " + self.user_keys[i][1] + "\n"
            i = i + 1
        i = 0
        while i < len(self.user_tools):
            body = body + "tool = " + self.user_tools[i][0] + " | " + self.user_tools[i][1] + "\n"
            i = i + 1
        i = 0
        while i < len(self.user_env):
            body = body + "env = " + self.user_env[i] + "\n"
            i = i + 1
        i = 0
        while i < len(self.user_snippets):
            var b = string_replace(string_replace(self.user_snippets[i][1], "\n", "\\n"), "\t", "\\t")
            body = body + "snippet = " + self.user_snippets[i][0] + " | " + b + "\n"
            i = i + 1
        return body

    # Before a file is overwritten on save, Code::Blocks-style: the old
    # content goes to <file>.bak (setting backup_on_save).
    def _tools_before_write(self, path):
        if self.backup_on_save and os_exists(path) and not string_endswith(path, ".bak"):
            file_copy(path, path + ".bak")

    def _tools_after_save(self, d):
        self.todo_key = ""

    # The editors open at exit, reopened next time in the same folder.
    def _tools_state_text(self):
        var body = ""
        if self.ws.root != "":
            body = body + "session=" + self.ws.root + "\n"
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.kind == "file" and d.path != "" and d.buf != none:
                body = body + "open=" + d.path + "|" + str(d.buf.cursor_row) + "|" + str(d.buf.cursor_col) + "\n"
            i = i + 1
        if self._is_text() and self.doc().kind == "file":
            body = body + "active=" + self.doc().path + "\n"
        return body

    def _tools_state_line(self, ln):
        if string_startswith(ln, "session="):
            self.session_root = string_slice(ln, 8, len(ln))
            self.session_open = []
        elif string_startswith(ln, "open="):
            var p = string_split(string_slice(ln, 5, len(ln)), "|")
            if len(p) >= 3:
                self.session_open.append([p[0], int_or_zero(p[1]), int_or_zero(p[2])])
        elif string_startswith(ln, "active="):
            self.session_active = string_slice(ln, 7, len(ln))

    def _restore_session(self):
        if not self.restore_editors or self.ws.root == "" or self.session_root != self.ws.root:
            return
        var i = 0
        var opened = 0
        while i < len(self.session_open):
            var s = self.session_open[i]
            if os_exists(s[0]) and self._find_doc(s[0]) < 0:
                if self._open_path(s[0], s[1], s[2]):
                    opened = opened + 1
            i = i + 1
        if self.session_active != "":
            var ai = self._find_doc(self.session_active)
            if ai >= 0:
                self._activate(ai)
        if opened > 0:
            self.focus = "editor"

    # ══ debugger additions ═════════════════════════════════════════════════════
    def _run_to_cursor(self):
        if not self.dbg.active:
            self._notify("Run to Cursor works while debugging (start with F5)", "info")
            return
        var key = self.doc().path + ":" + str(self.buf().cursor_row + 1)
        var m = {}
        var ks = self.dbg_breaks.keys()
        var i = 0
        while i < len(ks):
            m[ks[i]] = self.dbg_breaks[ks[i]]
            i = i + 1
        m[key] = true
        if not self.dbg.continue_fwd(m):
            self._dbg_end_reached()
        self._dbg_flush_logs()
        self._dbg_sync()

    # Condition / hit count / log message for the breakpoint on a line (a
    # breakpoint is set first if there is none).
    def _edit_breakpoint(self, arg):
        if not self._is_text():
            return
        var row = self.buf().cursor_row
        if arg != none and arg != "":
            row = int(arg)
        var key = self._break_key(row)
        if not self._has_break(row):
            self._toggle_break(row)
        self.brk_edit_key = key
        var ex = self._brk_spec(key)
        var labels = ["Condition...  " + ex["cond"], "Hit Count...  " + ex["hits"], "Log Message...  " + ex["log"], "Remove Breakpoint"]
        self._pick("t.brkkind", "Edit Breakpoint (line " + str(row + 1) + ")", labels, ["cond", "hits", "log", "remove"], "")

    def _brk_spec(self, key):
        if self.brk_extra.has_key(key):
            return self.brk_extra[key]
        return {"cond": "", "hits": "", "log": ""}

    def _edit_breakpoint_kind(self, v):
        var key = self.brk_edit_key
        var ex = self._brk_spec(key)
        if v == "cond":
            self._open_prompt("t.brkcond", "Breakpoint Condition", "Break when true, e.g.  x > 3   or   name == \"bob\"   (empty: always)", ex["cond"])
        elif v == "hits":
            self._open_prompt("t.brkhits", "Breakpoint Hit Count", "Break on the Nth hit: 5, >5, >=5 or %5 (every fifth)", ex["hits"])
        elif v == "log":
            self._open_prompt("t.brklog", "Log Message", "Print instead of stopping; {name} shows a variable", ex["log"])
        elif v == "remove":
            var cut = self._rfind(key, ":")
            var row = int(string_slice(key, cut + 1, len(key))) - 1
            if self._has_break(row):
                self._toggle_break(row)
            if self.brk_extra.has_key(key):
                self.brk_extra.remove(key)

    def _set_brk_extra(self, kind, value):
        var key = self.brk_edit_key
        var ex = self._brk_spec(key)
        ex[kind] = value
        if ex["cond"] == "" and ex["hits"] == "" and ex["log"] == "":
            if self.brk_extra.has_key(key):
                self.brk_extra.remove(key)
        else:
            self.brk_extra[key] = ex
        self.brk_gen = self.brk_gen + 1
        if self.dbg.active:
            self._dbg_rebuild_breaks()
        self.status_msg = "Breakpoint updated"

    # Log messages a continue passed over, into the Debug Console.
    def _dbg_flush_logs(self):
        var i = 0
        while i < len(self.dbg.logs):
            self._dbg_print(self.dbg.logs[i], "info")
            i = i + 1
        self.dbg.logs = []

    def _add_to_watch(self, arg):
        var w = arg
        if w == none or w == "":
            w = self._sel_text()
            if w == "" or string_find(w, "\n") >= 0:
                w = self._selected_word()
        w = string_strip(w)
        if w == "":
            return
        var i = 0
        while i < len(self.watches):
            if self.watches[i] == w:
                return
            i = i + 1
        self.watches.append(w)
        self.status_msg = "Watching " + w

    # ══ window ═════════════════════════════════════════════════════════════════
    def _toggle_fullscreen(self):
        try:
            gui_set_fullscreen(self.win._handle, not self.fullscreen)
            self.fullscreen = not self.fullscreen
        except Exception as e:
            self._notify("Full screen is not available with this GUI backend", "warn")

    # ══ clicks this file owns ══════════════════════════════════════════════════
    def _tools_click(self, cmd, arg, e):
        if cmd == "@todo.item":
            if arg < len(self.todo_items):
                var it = self.todo_items[arg]
                if it[0] != "":
                    self._open_path(it[0], it[1], it[2])
                else:
                    self._goto(it[1], it[2])
                self.focus = "editor"
            return true
        if cmd == "@todo.scope":
            self.todo_scope = arg
            self.todo_key = ""
            self.panel_scroll = 0
            return true
        if cmd == "@todo.refresh":
            self.todo_key = ""
            return true
        if cmd == "@gutter.fold":
            if self._is_text():
                var row = self._row_at_y(e.y)
                if row >= 0:
                    self._fold_toggle_row(row)
            return true
        if cmd == "@fold.marker":
            self._fold_set(self.doc(), arg, false)
            return true
        if cmd == "@ctx.brktoggle":
            if self._is_text():
                self._toggle_break(arg)
            return true
        if cmd == "@ctx.bookmark":
            if self._is_text():
                var keep_row = self.buf().cursor_row
                self.buf().cursor_row = arg
                self._bookmark_toggle()
                self.buf().cursor_row = keep_row
            return true
        if cmd == "@status.target":
            self._target_picker()
            return true
        if cmd == "@status.ovr":
            self._exec("editor.action.toggleOvertypeInsertMode", none)
            return true
        return false

    def _row_at_y(self, y):
        return self._pos_at(self.text_x0, y)[0]

    # Editor context-menu entries this file adds.
    def _tools_editor_ctx(self, items):
        items.append(["-", "", ""])
        if self.dbg.active:
            items.append(["Run to Cursor", "nython.debug.runToCursor", ""])
            items.append(["Add to Watch", "nython.addToWatch", ""])
        items.append(["Toggle Bookmark", "nython.bookmarks.toggle", ""])
        items.append(["Format Document", "editor.action.formatDocument", ""])
        items.append(["Fold", "editor.fold", ""])
        return items
