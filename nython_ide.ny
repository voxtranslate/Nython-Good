# ══════════════════════════════════════════════════════════════════════════════
#  NythonIDE 5 — a VS Code-standard IDE for Nython
#
#  This file holds the application state, input routing and the frame loop.
#  The rest of the class lives in ide_core.ny (documents, commands, editing),
#  ide_ops.ny (find, quick input, run/build, settings, file operations),
#  ide_paint.ny (theme, layout, drawing) and ide_views.ny (side bar views);
#  see ide_core.ny's header for the chain. Launched by `nython --ide`.
#
#  Set NY_IDE_NO_RUN=1 to import this file without opening the window
#  (tests and tools/ construct NythonIDE() and drive it directly).
# ══════════════════════════════════════════════════════════════════════════════

import "ide_tools.ny"
import "ide_workshop.ny"
import "lib/aiagent.ny"
import "lib/gui_motion.ny"
import "lib/ide_toolchain.ny"
import "lib/ide_commands.ny"


def hit(rx, ry, rw, rh, px, py):
    return px >= rx and px < rx + rw and py >= ry and py < ry + rh


class NythonIDE(IDETools):
    def __init__(self):
        self.th = IDETheme()
        self.session_id = time_ms() % 100000000
        # ── window ────────────────────────────────────────────────────────────
        var want_w = 1600
        var want_h = 960
        var disp = gui_get_display_size()
        if disp != none and len(disp) >= 2:
            if disp[0] > 0 and want_w > disp[0] - 40:
                want_w = disp[0] - 40
            if disp[1] > 0 and want_h > disp[1] - 90:
                want_h = disp[1] - 90
        if want_w < 900:
            want_w = 900
        if want_h < 560:
            want_h = 560
        self.win = Window(want_w, want_h, "NythonIDE")
        self.win.resizable = true
        self.W = want_w
        self.H = want_h
        self.dpi = gui_display_scale()
        if self.dpi <= 0.0 or self.dpi > 8.0:
            self.dpi = 1.0
        # ── metrics (VS Code's) ───────────────────────────────────────────────
        self.TITLE_H = self.dp(30)
        self.ACT_W = self.dp(48)
        self.SIDEBAR_W = self.dp(270)
        self.SIDE_HEAD = self.dp(35)
        self.TAB_H = self.dp(35)
        self.CRUMB_H = self.dp(22)
        self.STATUS_H = self.dp(22)
        self.PANEL_HEAD = self.dp(35)
        self.MINIMAP_W = self.dp(80)
        self.ROW_H = self.dp(22)
        self.font_size = 13
        self.LINE_H = int(self.dp(13) * 1.4)
        # ── fonts ─────────────────────────────────────────────────────────────
        self.f_ui = Font("sans-serif", self.dp(13), false, false)
        self.f_ui_bold = Font("sans-serif", self.dp(13), true, false)
        self.f_small = Font("sans-serif", self.dp(11), false, false)
        self.f_small_bold = Font("sans-serif", self.dp(11), true, false)
        self.f_tiny = Font("sans-serif", self.dp(10), false, false)
        self.f_tab = Font("sans-serif", self.dp(11), false, false)
        self.f_code = Font("monospace", self.dp(13), false, false)
        self.f_mono_small = Font("monospace", self.dp(12), false, false)
        self.f_title = Font("sans-serif", self.dp(34), false, false)
        self.f_h2 = Font("sans-serif", self.dp(17), false, false)
        self.ui_h = self.dp(17)
        self.small_h = self.dp(15)
        self.code_h = self.dp(17)
        self.tab_h = self.dp(15)
        self.code_small_h = self.dp(16)
        self.char_w = 8
        self.want_col = -1
        # ── model objects ─────────────────────────────────────────────────────
        self.icons = Icons()
        self.scratch = []
        var si = 0
        while si < 64:
            self.scratch.append(Color(0, 0, 0, 0))
            si = si + 1
        self.scratch_i = 0
        self.num_cache = []
        var ni = 0
        while ni < 1000:
            self.num_cache.append(str(ni))
            ni = ni + 1
        self.line_nums = [""]
        self.hits = HitMap()
        self.reg = CommandRegistry()
        self.frecency = Frecency(30 * 60 * 1000)
        self.nav = NavHistory()
        self.qi = QuickInput()
        self.notes = Notifications()
        self.ease = Ease()
        self.hl = SyntaxHighlighter()
        self.selmodel = SelectionModel()
        self.ws = Workspace()
        self.git = GitRepo()
        self.linediff = LineDiff()
        self.dbg = DebugSession()
        self.ai = CodeAnalyzer()
        self.toolchain = Toolchain()
        self.cmdline = CommandLine(self.toolchain, self.ai)
        self.workshop = LangWorkshopPanel(0, 0, 100, 100)
        self.ctxk = {}
        # ── documents ─────────────────────────────────────────────────────────
        self.docs = [Doc("welcome", "Welcome", "", none)]
        self.active = 0
        self.untitled_seq = 0
        self.closed_stack = []
        self.pending_close = []
        self.pending_save_as = none
        # ── focus and UI state ────────────────────────────────────────────────
        self.focus = "editor"
        self.focus_before_qi = "editor"
        self.focus_before_modal = "editor"
        self.views = ["explorer", "search", "scm", "debug", "ext", "outline", "ai"]
        self.view_icons = ["files", "search", "source-control", "debug-alt", "extensions", "symbol-structure", "sparkle"]
        self.view_tips = ["Explorer (Ctrl+Shift+E)", "Search (Ctrl+Shift+F)", "Source Control (Ctrl+Shift+G)",
                          "Run and Debug (Ctrl+Shift+D)", "Extensions (Ctrl+Shift+X)", "Outline", "AI Assistant"]
        self.view_titles = ["EXPLORER", "SEARCH", "SOURCE CONTROL", "RUN AND DEBUG", "EXTENSIONS", "OUTLINE", "AI ASSISTANT"]
        self.active_view = "explorer"
        self.panel_keys = ["problems", "output", "debug", "terminal", "buildlog", "todo", "inspector", "workshop"]
        self.panel_labels = ["PROBLEMS", "OUTPUT", "DEBUG CONSOLE", "TERMINAL", "BUILD LOG", "TODO", "INSPECTOR", "LANGUAGE WORKSHOP"]
        self.active_panel = "problems"
        self.sidebar_open = true
        self.panel_open = true
        self.panel_max = false
        self.panel_ratio = 0.28
        self.sidebar_anim = 1.0
        self.panel_anim = 1.0
        self.minimap_on = true
        self.show_whitespace = false
        self.show_indent_guides = true
        self.tab_size = 4
        self.insert_spaces = true
        self.st_k_spaces = true
        self.default_tab_size = 4
        self.default_insert_spaces = true
        self.detect_indent = true
        self.indent_mode = "spaces"
        self.auto_save = "off"
        self.loading_settings = false
        self.menu_open = -1
        self.menu_sel = -1
        self.menu_x = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        # Responsive layout (ide_paint.ny, _layout): the menus fold into a
        # hamburger, the side bar floats over the editor, overflowing panel
        # tabs and activity-bar views go to a "..." menu.
        self.menu_compact = false
        self.side_overlay = false
        self.act_fit = 99
        self.panel_fit = 99
        self.panel_ai = 0
        self.ctx_open = false
        self.ctx_items = []
        self.ctx_x = 0
        self.ctx_y = 0
        self.ctx_sel = -1
        self.modal_open = false
        self.modal_title = ""
        self.modal_msg = ""
        self.modal_buttons = []
        self.modal_sel = 0
        self.notif_center = false
        self.sections_closed = {}
        self.cc_label = "NythonIDE"
        self.status_msg = ""
        self.status_t = 0
        self.last_status = ""
        self.tip_text = ""
        self.tip_t0 = 0
        self.tip_x = 0
        self.tip_y = 0
        self.tip_hit_cmd = ""
        self.tip_hit_arg = ""
        self.hover_info = ""
        self.hover_x = 0
        self.hover_y = 0
        self.hover_t0 = 0
        self.hover_done = true
        self.mx = 0
        self.my = 0
        self.mouse_down = false
        self.dragging = ""
        self.drag_off = 0
        self.drag_from = -1
        self.drag_x0 = 0
        self.overlay_up = false
        self.drawing_overlay = false
        self.cursor_shape = "arrow"
        self.caret_on = true
        self.caret_t = 0
        self.frames = 0
        self._dirty = true
        self._skipped = 0
        self._title_dirty = true
        self._code_handle = none
        self._hl_cache = {}
        self._diff_cache = {}
        self._hl_cache_n = 0
        self.clipboard = ""
        self.clip_line_mode = false
        self.tab_scroll_px = 0
        self.actions_w = 0
        self.tabs_total_w = 0
        self.gutter_lines = -1
        self.GUTTER_W = 60
        self.GLYPH_W = 18
        self.num_w = 24
        self.text_x0 = 0
        self.vs_thumb_y = 0
        self.vs_thumb_h = 0
        self.mm_first = 0
        self.mm_doc = none
        self.crumb_doc = none
        self.crumb_sym_row = -2
        self.crumb_path = ""
        self.crumb_title = ""
        self.crumb_parts = []
        self.crumb_kinds = []
        self.crumb_paths = []
        self.encl_state = -1
        self.encl_row_in = -1
        self.encl_doc = none
        self.encl_row_out = -1
        self.bm_state = -1
        self.bm_row = -1
        self.bm_col = -1
        self.bm_doc = none
        self.bm = none
        self._status_refresh_reset()
        # ── find ──────────────────────────────────────────────────────────────
        self.find_open = false
        self.find_replace_mode = false
        self.find_field = 0
        self.find_query = ""
        self.find_replace = ""
        self.find_case = false
        self.find_word = false
        self.find_regex = false
        self.find_hits = []
        self.find_n = 0
        self.find_index = 0
        self.find_error = ""
        self.find_info = "No results"
        # ── search view ───────────────────────────────────────────────────────
        self.search_query = ""
        self.search_replace = ""
        self.search_replace_open = false
        self.search_field = 0
        self.search_case = false
        self.search_word = false
        self.search_regex = false
        self.search_results = []
        self.search_summary = ""
        self.search_total = 0
        self.search_collapsed = {}
        self.search_rows = []
        self.search_rows_src = none
        self.search_rows_cn = -1
        self.search_due = 0
        # ── quick input / pickers ─────────────────────────────────────────────
        self.path_dirs_only = false
        self.ws_files = none
        self.ws_files_root = ""
        # ── autocomplete ──────────────────────────────────────────────────────
        self.ac_open = false
        self.ac_items = []
        self.ac_kinds = []
        self.ac_mark_key = ""
        self.ac_marks = []
        self.ac_n = 0
        self.ac_sel = 0
        self.ac_top = 0
        self.ac_prefix = ""
        # ── explorer ──────────────────────────────────────────────────────────
        self.tree_scroll = 0
        self.tree_sel = 0
        # ── panel content ─────────────────────────────────────────────────────
        self.panel_scroll = 0
        self.out_lines = []
        self.out_kinds = []
        self.out_follow = true
        self.term_lines = ["Nython terminal - shell commands run in the workspace folder.",
                           "':help' lists IDE commands, '>expr' evaluates Nython, '@explain' / '@fix' ask the analyser."]
        self.term_kinds = ["dim", "dim"]
        self.term_follow = true
        self.term_input = ""
        self.term_cwd = getcwd()
        self.term_prompt = "$"
        self.term_proc = none
        self.term_seq = 0
        self.dbgcon_lines = []
        self.dbgcon_kinds = []
        self.dbgcon_follow = true
        self.dbgcon_input = ""
        self.inspect_lines = []
        self.inspect_kind = ""
        self.inspect_scroll = 0
        # ── problems ──────────────────────────────────────────────────────────
        self.problems = []
        self.n_errors = 0
        self.n_warnings = 0
        self.problem_cursor = -1
        self.prob_rows = []
        self.prob_rows_src = none
        self.prob_rows_collapsed_n = -1
        self.prob_collapsed = {}
        self.prob_by_path = {}
        self.prob_by_path_src = none
        self._status_cache_key = ""
        self.check_due = 0
        # ── run / build ───────────────────────────────────────────────────────
        self.run_seq = 0
        self.job = none
        self.job_running = false
        self.job_mode = ""
        self.job_path = ""
        self.job_doc = none
        self.job_seq = 0
        self.job_t0 = 0
        self.job_killed = false
        self.job_in_profile = false
        self.job_text = ""
        self.job_text_n = 0
        self.last_run_ok = true
        # ── debugger ──────────────────────────────────────────────────────────
        self.breaks = {}
        self.break_list = []
        self.brk_gen = 0
        self.brk_rows = {}
        self.brk_rows_doc = none
        self.brk_rows_gen = -1
        self.dbg_line_row = -1
        self.dbg_line_path = ""
        self.dbg_doc = none
        self.dbg_run_path = ""
        self.dbg_trace = ""
        self.dbg_breaks = {}
        self.dbg_hits = []
        self.dbg_frame = -1
        self.dbg_vars = []
        self.dbg_vars_pos = -2
        self.dbg_vars_frame = -2
        self.dbg_stack = []
        self.dbg_stack_pos = -2
        self.dbg_recording = false
        self.watches = []
        self.dbg_var_sel = -1
        self.fields = {}           # input name -> LineEdit (caret + selection)
        self.wrap_cache = {}
        self.mm_codes = {}
        self.mm_codes_n = 0
        self.mm_cols = []
        self.mm_cols_dark = true
        # Title-bar actions of each side view, built once: a list literal in a
        # paint method is a new list every frame, and lists are never freed.
        self.acts_explorer = [["new-file", "explorer.newFile", "", "New File..."], ["new-folder", "explorer.newFolder", "", "New Folder..."], ["refresh", "workbench.files.action.refreshFilesExplorer", "", "Refresh Explorer"], ["collapse-all", "workbench.files.action.collapseExplorerFolders", "", "Collapse Folders in Explorer"]]
        self.acts_search = [["refresh", "@search.run", "", "Refresh"], ["clear-all", "@search.clear", "", "Clear Search Results"]]
        self.acts_scm = [["check", "git.commit", "", "Commit"], ["refresh", "git.refresh", "", "Refresh"], ["ellipsis", "@scm.more", "", "More Actions..."]]
        self.acts_ext = [["refresh", "@ext.refresh", "", "Refresh"]]
        self.acts_ai = [["refresh", "nython.ai.analyze", "", "Analyse Again"]]
        self.ac_row = -1
        self.ac_start = -1
        self.ac_doc = none
        self.ac_index = 0
        self.ac_scan_doc = none
        self.ac_scan_state = -1
        self.watch_t = 0
        self.watch_dirs = {}
        self.watch_git = -3
        self.term_input_y = 100000
        self.dbgcon_input_y = 100000
        self.field_vx = {}         # input name -> x of its first character, last frame
        # ── source control ────────────────────────────────────────────────────
        self.scm_stale = true
        self.scm_branch = ""
        self.scm_count = 0
        self.scm_by_path = {}
        self.scm_dirs = {}
        self.scm_msg = ""
        self.scm_diff_due = 0
        self.scm_poll_t = 0
        # ── extensions / outline / AI ─────────────────────────────────────────
        self.cat = none
        self.ext_query = ""
        self.ext_filter = []
        self.ext_filter_q = ""
        self.ext_open_path = ""
        self.outline_doc = none
        self.outline_state = -1
        self.outline_syms = []
        self.ai_issues = []
        self.ai_n = 0
        self.ai_key = ""
        # ── recent files ──────────────────────────────────────────────────────
        self.recent = []
        self.recent_folders = []
        self.autosave_due = 0
        self.fullscreen = false
        self.menu_mnemonics = []
        self._tools_init()
        # ── start ─────────────────────────────────────────────────────────────
        self._register_commands()
        self._load_state()
        self._open_initial_workspace()
        self._restore_session()
        self._layout()
        self.f_code.ensure_loaded()
        self.char_w = self.f_code.width("M")
        self._gutter_calc()

    def _status_refresh_reset(self):
        self.st_k_row = -9
        self.st_k_col = -9
        self.st_k_sel = -9
        self.st_k_err = -9
        self.st_k_warn = -9
        self.st_k_doc = none
        self.st_k_tab = -9
        self.st_k_branch = "?"
        self.st_k_dirtyrepo = -9
        self.st_k_dbg = -9
        self.st_k_job = false
        self.st_k_eol = ""
        self.st_k_bom = false
        self.st_k_lang = ""
        self.st_errors = "0"
        self.st_warnings = "0"
        self.st_branch = ""
        self.st_job = ""
        self.st_debug = ""
        self.st_pos = ""
        self.st_indent = ""
        self.st_enc = ""
        self.st_eol = ""
        self.st_lang = ""

    # The folder the IDE was started in, like `code .`. If it cannot be
    # opened, no folder: the Welcome page offers Open Folder.
    def _open_initial_workspace(self):
        var cwd = string_replace(getcwd(), "\\", "/")
        if cwd != "" and self.ws.open_folder(cwd):
            self.term_cwd = cwd
            self._remember_folder(cwd)
            self._load_settings()
            self._load_hl_rules(false)
        self.cc_label = self._workspace_name()

    def _workspace_name(self):
        if self.ws.root == "":
            return "NythonIDE"
        return os_path_basename(self.ws.root)

    # ══ input ══════════════════════════════════════════════════════════════════
    def handle_event(self, e):
        var t = e.type
        if t == "mousemove":
            self._on_move(e)
        elif t == "mousedown":
            self._on_down(e)
        elif t == "mouseup":
            self._on_up(e)
        elif t == "scroll":
            self._on_wheel(e)
        elif t == "keydown":
            self._on_key(e)
        elif t == "textinput":
            self._on_text(e)
        elif t == "expose":
            self._dirty = true

    def _close_overlays(self):
        self.menu_open = -1
        self.menu_sel = -1
        self.ctx_open = false
        self.notif_center = false

    # ── pointer ──────────────────────────────────────────────────────────────
    def _on_move(self, e):
        self.mx = e.x
        self.my = e.y
        if self.dragging != "":
            self._drag_to(e.x, e.y)
            self._dirty = true
            return
        var h = self.hits.at(e.x, e.y)
        var cmd = ""
        var arg = ""
        var tip = ""
        if h != none:
            cmd = h.cmd
            arg = h.arg
            tip = h.tip
        # Repaint only when what is under the pointer changed.
        if cmd != self.tip_hit_cmd or arg != self.tip_hit_arg:
            self.tip_hit_cmd = cmd
            self.tip_hit_arg = arg
            self._dirty = true
            self.tip_text = ""
            if tip != "" and not string_startswith(cmd, "@tree") and cmd != "@editor":
                self.tip_text = tip
                self.tip_t0 = time_ms()
                self.tip_x = e.x + self.dp(10)
                self.tip_y = e.y + self.dp(20)
            # Moving across the menu bar with a menu open switches menus.
            if self.menu_open >= 0 and cmd == "@menu" and arg != self.menu_open:
                self.menu_open = arg
                self.menu_sel = -1
            if self.menu_open >= 0 or self.ctx_open:
                self.menu_sel = -1
                self.ctx_sel = -1
        # Code hover (definition signature, or a variable's value while
        # debugging) after the pointer rests on a word.
        if cmd == "@editor":
            self.hover_t0 = time_ms()
            self.hover_done = false
            if self.hover_info != "":
                self.hover_info = ""
                self._dirty = true
        elif self.hover_info != "":
            self.hover_info = ""
            self._dirty = true
        self._set_cursor(cmd)

    def _set_cursor(self, cmd):
        var want = "arrow"
        if cmd == "@editor" or cmd == "@qi.input" or cmd == "@find.field" or cmd == "@search.field" or cmd == "@scm.msg" or cmd == "@term" or cmd == "@dbgcon" or cmd == "@ext.search":
            want = "ibeam"
        elif cmd == "@split.sidebar":
            want = "sizewe"
        elif cmd == "@split.panel":
            want = "sizens"
        elif cmd == "@split.sash":
            want = "sizewe"
            if self.split_dir == "rows":
                want = "sizens"
        elif cmd != "" and not string_startswith(cmd, "@side") and cmd != "@menu.bg" and cmd != "@qi.bg" and cmd != "@overlay.dismiss" and cmd != "@panel.body" and cmd != "@tabstrip" and cmd != "@modal.scrim" and cmd != "@qi.dismiss" and cmd != "@find.bg":
            want = "hand"
        if want != self.cursor_shape:
            self.cursor_shape = want
            gui_set_cursor(want)

    def _on_down(self, e):
        self.mx = e.x
        self.my = e.y
        self.mouse_down = true
        self.caret_on = true
        self.caret_t = time_ms()
        self.tip_text = ""
        self.hover_info = ""
        self._dirty = true
        var h = self.hits.at(e.x, e.y)
        if e.button == 3:
            self._close_overlays()
            if not self.qi.visible and not self.modal_open:
                self._context_menu(h, e)
            return
        if h == none:
            self._close_overlays()
            return
        if e.button == 2:
            if h.cmd == "@tab" or h.cmd == "@tab.close":
                self._close_doc(h.arg, false)
            elif h.cmd == "@editor":
                # Middle-button drag selects a column, as in VS Code.
                self._box_mouse_start(e.x, e.y)
            return
        self._click(h, e)

    def _on_up(self, e):
        self.mouse_down = false
        if self.dragging == "tab":
            self._finish_tab_drag(e.x)
        if self.dragging != "":
            if self.dragging == "sidebar" or self.dragging == "panel":
                self._save_settings()
            self.dragging = ""
            self._dirty = true

    def _drag_to(self, x, y):
        var d = self.dragging
        if d == "sidebar":
            var nw = x - self.ACT_W
            if nw < self.dp(170):
                nw = self.dp(170)
            if nw > self.W - self.dp(500):
                nw = self.W - self.dp(500)
            self.SIDEBAR_W = nw
            self._layout()
        elif d == "panel":
            var avail = self.content_h
            var ratio = (self.content_y + avail - y) * 1.0 / avail
            if ratio < 0.10:
                ratio = 0.10
            if ratio > 0.80:
                ratio = 0.80
            self.panel_ratio = ratio
            self.panel_max = false
            self._layout()
        elif d == "select":
            self._drag_select(x, y)
        elif d == "box":
            self._box_drag(x, y)
        elif d == "splitsash":
            self._split_drag(x, y)
        elif d == "lines":
            var p = self._pos_at(x, y)
            var b = self.buf()
            var dd = self.doc()
            if p[0] >= dd.sel_row:
                b.cursor_row = p[0] + 1
                b.cursor_col = 0
                if b.cursor_row >= b.line_count:
                    b.cursor_row = b.line_count - 1
                    b.cursor_col = len(b.get_line(b.cursor_row))
            else:
                b.cursor_row = p[0]
                b.cursor_col = 0
        elif d == "vscroll":
            self._vscroll_to(y - self.drag_off)
        elif d == "minimap":
            self._minimap_to(y)
        elif d == "dbgseek":
            self._dbg_seek_x(x)

    # Auto-scrolls while a selection drag leaves the text area.
    def _drag_select(self, x, y):
        var d = self.doc()
        if d.buf == none:
            return
        if y < self.ed_y:
            d.scroll_y = d.scroll_y - self.LINE_H
        elif y > self.ed_y + self.ed_h:
            d.scroll_y = d.scroll_y + self.LINE_H
        self._clamp_scroll()
        var p = self._pos_at(x, y)
        d.buf.cursor_row = p[0]
        d.buf.cursor_col = p[1]

    def _vscroll_to(self, thumb_y):
        var d = self.doc()
        if d.buf == none:
            return
        var total = (self._vis_count(d) - 1) * self.LINE_H + self.ed_h
        var maxs = total - self.ed_h
        var room = self.ed_h - self.vs_thumb_h
        if room <= 0:
            return
        var f = (thumb_y - self.ed_y) * 1.0 / room
        if f < 0.0:
            f = 0.0
        if f > 1.0:
            f = 1.0
        d.scroll_y = int(maxs * f)
        self._clamp_scroll()

    def _minimap_to(self, y):
        var d = self.doc()
        var row = self.mm_first + int((y - self.ed_y) / 2)
        if row >= d.buf.line_count:
            row = d.buf.line_count - 1
        d.scroll_y = (self._row_to_vrow(d, row) - int(self._rows_visible() / 2)) * self.LINE_H
        self._clamp_scroll()

    # Pixel -> [row, col] in the active editor.
    def _pos_at(self, x, y):
        var d = self.doc()
        var b = d.buf
        var vrow = int((y - self.ed_y + d.scroll_y) / self.LINE_H)
        var nv = self._vis_count(d)
        if vrow >= nv:
            vrow = nv - 1
        if vrow < 0:
            vrow = 0
        var row = self._vrow_to_row(d, vrow)
        if row >= b.line_count:
            row = b.line_count - 1
        var line = b.lines[row]
        var rel = x - (self.text_x0 - d.scroll_x)
        var col = 0
        if rel > 0:
            # Monospace estimate, then refine against the real measurement.
            col = int(rel / self.char_w + 0.5)
            if col > len(line):
                col = len(line)
            while col > 0 and self._col_x(line, col) > rel + self.char_w / 2:
                col = col - 1
            while col < len(line) and self._col_x(line, col + 1) < rel + self.char_w / 2:
                col = col + 1
        return [row, col]

    def _on_wheel_editor(self, e, dy):
        if not self._is_text():
            return
        var d = self.doc()
        if e.shift:
            d.scroll_x = d.scroll_x - dy * self.char_w * 6
            if d.scroll_x < 0:
                d.scroll_x = 0
        else:
            d.scroll_y = d.scroll_y - dy * self.LINE_H * 3
            self._clamp_scroll()

    def _on_wheel(self, e):
        if e.x > 0 or e.y > 0:
            self.mx = e.x
            self.my = e.y
        var dy = e.delta
        var h = self.hits.at(self.mx, self.my)
        self._dirty = true
        self.hover_info = ""
        if self.qi.visible:
            self.qi.top = self.qi.top - dy * 3
            if self.qi.top > self.qi.n - self.qi.max_rows:
                self.qi.top = self.qi.n - self.qi.max_rows
            if self.qi.top < 0:
                self.qi.top = 0
            return
        if h == none:
            return
        var c = h.cmd
        if c == "@group.focus":
            # Scrolling the other group scrolls it without moving the focus
            # (or touching the focused group's carets).
            var g = self.group
            if self._pane_swap():
                self.group = h.arg
                self._layout()
                self._on_wheel_editor(e, dy)
                self._pane_swap()
                self.group = g
                self._layout()
            return
        if e.ctrl and (c == "@editor" or c == "@gutter.glyph" or c == "@gutter.num" or c == "@gutter.fold"):
            if dy > 0:
                self._zoom(1)
            elif dy < 0:
                self._zoom(0 - 1)
            return
        if c == "@editor" or c == "@gutter.glyph" or c == "@gutter.num" or c == "@gutter.fold" or c == "@minimap" or c == "@vscroll" or c == "@find.bg":
            self._on_wheel_editor(e, dy)
        elif c == "@ac.item":
            self.ac_top = self.ac_top - dy
            if self.ac_top > self.ac_n - 10:
                self.ac_top = self.ac_n - 10
            if self.ac_top < 0:
                self.ac_top = 0
        elif c == "@tab" or c == "@tabstrip" or c == "@tab.close":
            var strip = self.col_w - self.actions_w
            self.tab_scroll_px = self.tab_scroll_px + dy * self.dp(60)
            if self.tab_scroll_px < strip - self.tabs_total_w:
                self.tab_scroll_px = strip - self.tabs_total_w
            if self.tab_scroll_px > 0:
                self.tab_scroll_px = 0
        elif c == "@panel.body" or c == "@term" or c == "@dbgcon" or c == "@problem" or c == "@problem.file":
            self.panel_scroll = self.panel_scroll - dy * 3
            if self.panel_scroll < 0:
                self.panel_scroll = 0
            if self.active_panel == "output":
                self.out_follow = false
            if self.active_panel == "terminal":
                self.term_follow = false
        elif self.mx >= self.side_x and self.mx < self.side_x + self.side_w:
            self.tree_scroll = self.tree_scroll - dy * 3
            if self.tree_scroll < 0:
                self.tree_scroll = 0

    # ── clicks ───────────────────────────────────────────────────────────────
    def _click(self, h, e):
        var cmd = h.cmd
        var arg = h.arg
        if not string_startswith(cmd, "@"):
            self._close_overlays()
            self._exec(cmd, arg)
            return
        # Any click that is not on the open overlay closes it.
        var overlay_cmd = cmd == "@menu" or cmd == "@menuitem" or cmd == "@menu.bg" or cmd == "@menu.pick" or cmd == "@ctx.item"
        if not overlay_cmd and (self.menu_open >= 0 or self.ctx_open or self.notif_center):
            if cmd != "@toast.close":
                self._close_overlays()
                if cmd == "@overlay.dismiss":
                    return
        if cmd == "@overlay.dismiss" or cmd == "@menu.bg" or cmd == "@qi.bg" or cmd == "@find.bg" or cmd == "@modal.scrim" or cmd == "@tabstrip" or cmd == "@side.bg":
            return
        if cmd == "@qi.dismiss":
            self.qi.close()
            self.focus = self.focus_before_qi
            return
        if cmd == "@menu":
            if self.menu_open == arg:
                self.menu_open = -1
            else:
                self.menu_open = arg
                self.menu_sel = -1
            return
        if cmd == "@menuitem":
            self.menu_open = -1
            self._exec(arg, none)
            return
        if cmd == "@act.more":
            var vitems = []
            var vi = self.act_fit
            while vi < len(self.views):
                vitems.append([self.view_titles[vi], "@view", self.views[vi]])
                vi = vi + 1
            self._open_ctx(e.x, e.y, vitems)
            return
        if cmd == "@panel.more":
            var pitems = []
            var pi = 0
            while pi < len(self.panel_keys):
                if not self._panel_tab_shown(pi):
                    pitems.append([self.panel_labels[pi], "@panel.tab", self.panel_keys[pi]])
                pi = pi + 1
            self._open_ctx(e.x, e.y, pitems)
            return
        if cmd == "@menu.pick":
            self.menu_open = arg
            self.menu_sel = -1
            return
        if cmd == "@side.dismiss":
            # A click beside the floating side bar closes it (the click is
            # not passed through, as for any other light-dismiss surface).
            self.sidebar_open = false
            self.focus = "editor"
            self._layout()
            return
        if cmd == "@ctx.item":
            var it = self.ctx_items[arg]
            self.ctx_open = false
            if string_startswith(it[1], "@"):
                self._ctx_internal(it[1], it[2], e)
            else:
                self._exec(it[1], it[2])
            return
        if cmd == "@modal.button":
            var bt = self.modal_buttons[arg]
            if string_startswith(bt[1], "@"):
                self._exec_modal_cmd(bt[1], bt[2])
            else:
                self._modal_close()
                self._exec(bt[1], bt[2])
            return
        if cmd == "@qi.item":
            self.qi.sel = arg
            self.qi.sel_moved = true
            self._qi_accept(self.qi.current())
            return
        if cmd == "@qi.input":
            self._field_click("qi", e)
            return
        if cmd == "@view":
            if self.active_view == arg and self.sidebar_open:
                self.sidebar_open = false
                self.focus = "editor"
            else:
                self._show_view(arg)
                if arg == "search":
                    self.focus = "search"
                elif arg == "explorer":
                    self.focus = "explorer"
                elif arg == "ai":
                    self._ai_analyze(true)
            self._layout()
            return
        if cmd == "@manage":
            self._open_ctx(self.dp(8), self.status_y - self.dp(200), [["Command Palette...", "workbench.action.showCommands", ""],
                           ["-", "", ""], ["Settings", "workbench.action.openSettings", ""],
                           ["Keyboard Shortcuts", "workbench.action.openGlobalKeybindings", ""],
                           ["Color Theme", "workbench.action.selectTheme", ""], ["-", "", ""],
                           ["About", "nython.about", ""]])
            return
        if cmd == "@tab":
            self._activate(arg)
            self.focus = "editor"
            self.dragging = "tab"
            self.drag_from = arg
            self.drag_x0 = e.x
            return
        if cmd == "@tab.close":
            self._close_doc(arg, false)
            return
        if cmd == "@editor.more":
            self._open_ctx(self.col_x + self.col_w - self.dp(270), self.content_y + self.TAB_H, [
                ["Run on Bytecode VM", "nython.runOnVM", ""], ["Profile", "nython.profile", ""],
                ["Check Syntax", "nython.checkSyntax", ""], ["-", "", ""],
                ["Show Tokens", "nython.tokenize", ""], ["Show AST", "nython.showAST", ""],
                ["Show Bytecode", "nython.disassemble", ""], ["-", "", ""],
                ["Close All", "workbench.action.closeAllEditors", ""], ["Close Saved", "workbench.action.closeUnmodifiedEditors", ""]])
            return
        if cmd == "@editor":
            self._editor_click(e)
            return
        if cmd == "@gutter.glyph":
            if self._is_text():
                var p = self._pos_at(e.x, e.y)
                self._toggle_break(p[0])
            return
        if cmd == "@gutter.num":
            if self._is_text():
                var p2 = self._pos_at(e.x, e.y)
                var d = self.doc()
                d.sel_on = true
                d.sel_row = p2[0]
                d.sel_col = 0
                self._goto_keep_sel(p2[0] + 1, 0)
                self.focus = "editor"
                self.dragging = "lines"
            return
        if cmd == "@vscroll":
            if e.y >= self.vs_thumb_y and e.y < self.vs_thumb_y + self.vs_thumb_h:
                self.drag_off = e.y - self.vs_thumb_y
            else:
                self.drag_off = int(self.vs_thumb_h / 2)
                self._vscroll_to(e.y - self.drag_off)
            self.dragging = "vscroll"
            return
        if cmd == "@minimap":
            self._minimap_to(e.y)
            self.dragging = "minimap"
            return
        if cmd == "@split.sidebar":
            self.dragging = "sidebar"
            return
        if cmd == "@split.panel":
            self.dragging = "panel"
            return
        if cmd == "@tree":
            self._tree_click(arg, e)
            return
        if cmd == "@panel.tab":
            self._show_panel(arg)
            if arg == "terminal":
                self.focus = "terminal"
            elif arg == "debug":
                self.focus = "dbgconsole"
            return
        if cmd == "@panel.body":
            self.focus = "panel"
            return
        if cmd == "@problem":
            self.problem_cursor = arg
            self._open_problem(arg)
            return
        if cmd == "@problem.file":
            if self.prob_collapsed.has_key(arg):
                self.prob_collapsed.remove(arg)
            else:
                self.prob_collapsed[arg] = true
            return
        if cmd == "@term":
            self.focus = "terminal"
            if e.y >= self.term_input_y:
                self._field_click("term", e)
            return
        if cmd == "@dbgcon":
            self.focus = "dbgconsole"
            if e.y >= self.dbgcon_input_y:
                self._field_click("dbgcon", e)
            return
        if cmd == "@find.field":
            self.focus = "find"
            self.find_field = arg
            self._field_click("find" + str(arg), e)
            return
        if cmd == "@find.toggle":
            if arg == "replace":
                self.find_replace_mode = not self.find_replace_mode
            elif arg == "case":
                self.find_case = not self.find_case
            elif arg == "word":
                self.find_word = not self.find_word
            elif arg == "regex":
                self.find_regex = not self.find_regex
            self._find_run()
            self._find_info_update()
            return
        if cmd == "@find.close":
            self.find_open = false
            self.focus = "editor"
            return
        if cmd == "@find.replace":
            self._replace_one()
            self._find_info_update()
            return
        if cmd == "@find.replaceall":
            self._replace_all()
            self._find_info_update()
            return
        if cmd == "@ac.item":
            self.ac_sel = arg
            self._ac_accept()
            return
        if cmd == "@toast.close":
            self.notes.dismiss(arg)
            return
        if cmd == "@recent":
            if string_startswith(arg, "dir:"):
                self._open_folder(string_slice(arg, 4, len(arg)))
            else:
                self._open_path(string_slice(arg, 5, len(arg)), -1, 0)
            return
        if cmd == "@job.stop":
            if self.dbg_recording:
                self._debug_stop()
            else:
                self._stop_job()
            return
        if cmd == "@section":
            if self.sections_closed.has_key(arg):
                self.sections_closed.remove(arg)
            else:
                self.sections_closed[arg] = true
            return
        if string_startswith(cmd, "@search"):
            self._search_click(cmd, arg, e)
            return
        if string_startswith(cmd, "@scm"):
            self._scm_click(cmd, arg, e)
            return
        if string_startswith(cmd, "@dbg") or string_startswith(cmd, "@break"):
            self._dbg_click(cmd, arg, e)
            return
        if string_startswith(cmd, "@ext"):
            if cmd == "@ext.search":
                self.focus = "extsearch"
                self._field_click("ext", e)
            elif cmd == "@ext.open":
                self._ext_page(arg)
            elif cmd == "@ext.import":
                self._ext_import(arg)
            elif cmd == "@ext.refresh":
                self.cat = none
                self.ext_filter_q = "\x01"
            return
        if cmd == "@workshop":
            self.focus = "workshop"
            self.workshop.handle_event(e)
            return
        if cmd == "@outline":
            var syms = self._outline_syms()
            if arg < len(syms):
                self._goto(syms[arg][2], syms[arg][3])
                self.focus = "editor"
            return
        if cmd == "@ai":
            self._goto(arg - 1, 0)
            self.focus = "editor"
            return
        if self._tools_click(cmd, arg, e):
            return
        self._notify("Unhandled click target " + cmd, "warn")

    # Context-menu entries that are UI actions rather than commands.
    def _ctx_internal(self, cmd, arg, e):
        if cmd == "@ctx.open":
            self._open_path(arg, -1, 0)
            self.focus = "editor"
        elif cmd == "@ctx.terminal":
            var dir = arg
            if not os_isdir(dir):
                dir = os_path_dirname(dir)
            self.term_cwd = dir
            self._show_panel("terminal")
            self.focus = "terminal"
            self._term_print("cd " + dir, "dim")
        elif cmd == "@ctx.copytext":
            self._set_clipboard(arg)
            self._notify("Copied to clipboard", "info")
        elif cmd == "@ctx.watch":
            var have = false
            var wi = 0
            while wi < len(self.watches):
                if self.watches[wi] == arg:
                    have = true
                wi = wi + 1
            if not have:
                self.watches.append(arg)
        elif cmd == "@ctx.copypanel":
            var src = self.out_lines
            if self.active_panel == "terminal":
                src = self.term_lines
            elif self.active_panel == "debug":
                src = self.dbgcon_lines
            self._set_clipboard(string_join(src, "\n"))
            self._notify("Copied " + str(len(src)) + " lines", "info")
        else:
            var fake = Hit()
            fake.cmd = cmd
            fake.arg = arg
            self._click(fake, e)

    def _goto_keep_sel(self, row, col):
        var b = self.buf()
        if row >= b.line_count:
            row = b.line_count - 1
            col = len(b.get_line(row))
        b.cursor_row = row
        b.cursor_col = col
        b.begin_group()

    def _editor_click(self, e):
        if not self._is_text():
            return
        self.focus = "editor"
        self.ac_open = false
        var d = self.doc()
        var b = d.buf
        var p = self._pos_at(e.x, e.y)
        b.begin_group()
        self.want_col = -1
        # Column selection: Shift+Alt+drag (VS Code), or any single-click drag
        # in column selection mode (Code::Blocks' rectangular selection).
        if (e.alt and e.shift) or (self.column_mode and e.clicks < 2 and not e.alt and not e.shift):
            self._box_mouse_start(e.x, e.y)
            return
        if e.alt:
            if self._add_caret(p[0], p[1]):
                self.status_msg = str(self.selmodel.count) + " cursors"
            return
        self._clear_extra_carets()
        if e.clicks == 2:
            var w = b.word_at(p[0], p[1])
            d.sel_on = true
            d.sel_row = p[0]
            d.sel_col = w[0]
            b.cursor_row = p[0]
            b.cursor_col = w[1]
            return
        if e.clicks >= 3:
            d.sel_on = true
            d.sel_row = p[0]
            d.sel_col = 0
            self._goto_keep_sel(p[0] + 1, 0)
            return
        if e.shift:
            self._sel_begin()
        else:
            d.sel_on = true
            d.sel_row = p[0]
            d.sel_col = p[1]
        b.cursor_row = p[0]
        b.cursor_col = p[1]
        self._nav_record()
        self.dragging = "select"

    def _finish_tab_drag(self, x):
        var frm = self.drag_from
        if frm < 0 or frm >= len(self.docs) or abs(x - self.drag_x0) < self.dp(12):
            return
        var to = frm
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if x >= d.tab_x and x < d.tab_x + d.tab_w:
                to = i
            i = i + 1
        if to == frm:
            return
        var moving = self.docs[frm]
        var rest = []
        i = 0
        while i < len(self.docs):
            if i != frm:
                rest.append(self.docs[i])
            i = i + 1
        var out = []
        i = 0
        while i < len(rest):
            if i == to:
                out.append(moving)
            out.append(rest[i])
            i = i + 1
        if to >= len(rest):
            out.append(moving)
        self.docs = out
        self.active = self._index_of(moving)

    def _search_click(self, cmd, arg, e):
        if cmd == "@search.field":
            self.focus = "search"
            self.search_field = arg
            self._field_click("search" + str(arg), e)
        elif cmd == "@search.toggle":
            if arg == "case":
                self.search_case = not self.search_case
            elif arg == "word":
                self.search_word = not self.search_word
            elif arg == "regex":
                self.search_regex = not self.search_regex
            self._run_search()
        elif cmd == "@search.togglereplace":
            self.search_replace_open = not self.search_replace_open
        elif cmd == "@search.replaceall":
            self._search_replace_all()
        elif cmd == "@search.run":
            self._run_search()
        elif cmd == "@search.clear":
            self.search_query = ""
            self.search_results = []
            self.search_summary = ""
        elif cmd == "@search.file":
            var p = self.search_results[arg][0]
            if self.search_collapsed.has_key(p):
                self.search_collapsed.remove(p)
            else:
                self.search_collapsed[p] = true
        elif cmd == "@search.match":
            self._open_search_match(arg)

    def _scm_click(self, cmd, arg, e):
        if cmd == "@scm.msg":
            self.focus = "scm"
            self._field_click("scm", e)
        elif cmd == "@scm.row":
            var staged = string_startswith(arg, "S:")
            var p = arg
            if staged:
                p = string_slice(arg, 2, len(arg))
            var c = self.git.status_of(p)
            if c != none:
                self._open_change(c, staged)
        elif cmd == "@scm.openfile":
            self._open_path(arg, -1, 0)
        elif cmd == "@scm.more":
            self._open_ctx(self.side_x + self.side_w - self.dp(250), self.content_y + self.SIDE_HEAD, [
                ["Checkout to...", "git.checkout", ""], ["Show Log", "git.showLog", ""], ["-", "", ""],
                ["Stage All Changes", "git.stageAll", ""], ["Unstage All Changes", "git.unstageAll", ""], ["-", "", ""],
                ["Refresh", "git.refresh", ""]])

    def _dbg_click(self, cmd, arg, e):
        if cmd == "@dbg.seek":
            self._dbg_seek_x(e.x)
            self.dragging = "dbgseek"
        elif cmd == "@dbg.addwatch":
            self._open_prompt("addwatch", "Add Watch Expression", "A variable name", "")
        elif cmd == "@dbg.rmwatch":
            var keep = []
            var i = 0
            while i < len(self.watches):
                if i != arg:
                    keep.append(self.watches[i])
                i = i + 1
            self.watches = keep
        elif cmd == "@dbg.frame":
            var st = self.dbg_stack_cache()
            if arg < len(st):
                var fr = st[arg]
                if fr[1] == self.dbg_run_path and self.dbg_doc != none:
                    var di = self._index_of(self.dbg_doc)
                    if di >= 0:
                        self._activate(di)
                        self._goto(fr[2] - 1, 0)
                else:
                    self._open_path(fr[1], fr[2] - 1, 0)
                self.dbg_frame = fr[3]
                if arg == 0:
                    self.dbg_frame = -1
        elif cmd == "@dbg.var":
            self.dbg_var_sel = arg
            self.focus = "debugvars"
        elif cmd == "@dbg.exception":
            self.dbg.seek(self.dbg.n - 1)
            self._dbg_sync()
        elif cmd == "@break.go":
            var c = self._break_parts(self.break_list[arg])
            if string_startswith(c[0], "untitled:"):
                var t = string_slice(c[0], 9, len(c[0]))
                var k = 0
                while k < len(self.docs):
                    if self.docs[k].title == t:
                        self._activate(k)
                        self._goto(c[1] - 1, 0)
                    k = k + 1
            else:
                self._open_path(c[0], c[1] - 1, 0)
        elif cmd == "@break.rm":
            var key = self.break_list[arg]
            self.breaks.remove(key)
            var keep2 = []
            var j = 0
            while j < len(self.break_list):
                if j != arg:
                    keep2.append(self.break_list[j])
                j = j + 1
            self.break_list = keep2
            self.brk_gen = self.brk_gen + 1

    # ── context menus ────────────────────────────────────────────────────────
    def _open_ctx(self, x, y, items):
        self.ctx_items = items
        self.ctx_x = x
        self.ctx_y = y
        self.ctx_open = true
        self.ctx_sel = -1

    def _context_menu(self, h, e):
        if h == none:
            return
        var c = h.cmd
        if c == "@tab" or c == "@tab.close":
            self._activate(h.arg)
            var p = self.docs[h.arg].path
            self._open_ctx(e.x, e.y, [["Close", "workbench.action.closeActiveEditor", ""],
                                      ["Close Others", "workbench.action.closeOtherEditors", h.arg],
                                      ["Close to the Right", "workbench.action.closeEditorsToTheRight", h.arg],
                                      ["Close Saved", "workbench.action.closeUnmodifiedEditors", ""],
                                      ["Close All", "workbench.action.closeAllEditors", ""], ["-", "", ""],
                                      ["Copy Path", "copyFilePath", p], ["Copy Relative Path", "copyRelativeFilePath", p], ["-", "", ""],
                                      ["Reveal in Explorer View", "workbench.files.action.showActiveFileInExplorer", p]])
        elif c == "@tree":
            self.tree_sel = h.arg
            self.focus = "explorer"
            var n = self.ws.rows[h.arg]
            var items = [["New File...", "explorer.newFile", n.path], ["New Folder...", "explorer.newFolder", n.path], ["-", "", ""]]
            if not n.is_dir:
                items.append(["Open", "@ctx.open", n.path])
            items.append(["Open in Integrated Terminal", "@ctx.terminal", n.path])
            items.append(["-", "", ""])
            items.append(["Copy Path", "copyFilePath", n.path])
            items.append(["Copy Relative Path", "copyRelativeFilePath", n.path])
            if n.path != self.ws.root:
                items.append(["-", "", ""])
                items.append(["Rename...", "renameFile", n.path])
                items.append(["Delete", "deleteFile", n.path])
            self._open_ctx(e.x, e.y, items)
        elif c == "@editor" or c == "@gutter.num":
            self.focus = "editor"
            self._open_ctx(e.x, e.y, [["Go to Definition", "editor.action.revealDefinition", ""],
                                      ["Find All References", "references-view.findReferences", ""], ["-", "", ""],
                                      ["Rename Symbol", "editor.action.rename", ""],
                                      ["Change All Occurrences", "editor.action.changeAll", ""], ["-", "", ""],
                                      ["Cut", "editor.action.clipboardCutAction", ""],
                                      ["Copy", "editor.action.clipboardCopyAction", ""],
                                      ["Paste", "editor.action.clipboardPasteAction", ""], ["-", "", ""],
                                      ["Toggle Breakpoint", "editor.debug.action.toggleBreakpoint", ""],
                                      ["Run Nython File", "workbench.action.debug.run", ""],
                                      ["Command Palette...", "workbench.action.showCommands", ""]])
            self.ctx_items = self._tools_editor_ctx(self.ctx_items)
        elif c == "@gutter.glyph":
            var gp = self._pos_at(e.x, e.y)
            self._open_ctx(e.x, e.y, [["Toggle Breakpoint", "@ctx.brktoggle", gp[0]],
                                      ["Edit Breakpoint...", "nython.debug.editBreakpoint", gp[0]],
                                      ["-", "", ""],
                                      ["Toggle Bookmark", "@ctx.bookmark", gp[0]]])
        elif c == "@scm.row":
            var staged = string_startswith(h.arg, "S:")
            var p2 = h.arg
            if staged:
                p2 = string_slice(h.arg, 2, len(h.arg))
            var its = [["Open Changes", "@scm.row", h.arg], ["Open File", "@scm.openfile", p2], ["-", "", ""]]
            if staged:
                its.append(["Unstage Changes", "git.unstage", p2])
            else:
                its.append(["Stage Changes", "git.stage", p2])
                its.append(["Discard Changes", "git.clean", p2])
            self._open_ctx(e.x, e.y, its)
        elif c == "@dbg.var":
            self.dbg_var_sel = h.arg
            var vs = self.dbg_vars_cache()
            if h.arg < len(vs):
                self._open_ctx(e.x, e.y, [["Copy Value", "@ctx.copytext", vs[h.arg][1]],
                                          ["Copy as Expression", "@ctx.copytext", vs[h.arg][0]],
                                          ["Add to Watch", "@ctx.watch", vs[h.arg][0]]])
        elif c == "@term" or c == "@panel.body" or c == "@dbgcon":
            self._open_ctx(e.x, e.y, [["Copy All", "@ctx.copypanel", ""], ["Clear", "workbench.action.terminal.clear", ""]])

    # ── keyboard ─────────────────────────────────────────────────────────────
    def _on_key(self, e):
        self.caret_on = true
        self.caret_t = time_ms()
        self._dirty = true
        self.hover_info = ""
        var k = e.key
        if k == "ctrl" or k == "shift" or k == "alt" or k == "super":
            return
        # The developer dumps observe the workbench and must not disturb it,
        # so they run whatever overlay is open (tools/ide_e2e.py relies on it).
        if e.ctrl and e.shift and e.alt and (k == "j" or k == "d"):
            if k == "j":
                self._dump_state()
            else:
                self._dump_hitmap()
            return
        if self.modal_open:
            self._modal_key(e)
            return
        if self.focus == "qi" and self.qi.visible:
            if self._qi_key(e):
                return
        if self.menu_open >= 0:
            self._menu_key(e)
            return
        if self.ctx_open:
            self._ctx_key(e)
            return
        if self.notif_center and k == "escape":
            self.notif_center = false
            return
        if self.ac_open and self.focus == "editor":
            if self._ac_key(e):
                return
        # Alt+letter opens a menu, as the underlined mnemonics do in VS Code.
        if e.alt and not e.ctrl and not e.shift and len(k) == 1 and (self.focus == "editor" or self.focus == "explorer"):
            var mi = self._menu_mnemonic(k)
            if mi >= 0:
                self.menu_open = mi
                self.menu_sel = -1
                return
        var cmd = self.reg.resolve(e, self._ctx_keys())
        if cmd == "__chord__":
            self.status_msg = "(" + self.reg.pretty(self.reg.pending) + ") was pressed. Waiting for second key of chord..."
            return
        if cmd == "__chord_miss__":
            self.status_msg = "The key combination (" + self.reg.pretty(self.reg.last_miss) + ") is not a command."
            return
        if cmd != "":
            self._exec(cmd, none)
            return
        var f = self.focus
        if f == "qi":
            # An unhandled key in Quick Input stays there; it used to fall
            # through to the editor underneath.
            return
        if f == "find":
            self._find_key(e)
        elif f == "search":
            self._search_key(e)
        elif f == "scm":
            self._line_input_key(e, "scm")
        elif f == "terminal":
            self._term_key(e)
        elif f == "dbgconsole":
            self._line_input_key(e, "dbgcon")
        elif f == "extsearch":
            self._line_input_key(e, "ext")
        elif f == "explorer":
            if not self._tree_key(e) and k == "escape":
                self.focus = "editor"
        elif f == "panel":
            if k == "escape":
                self.focus = "editor"
        elif f == "workshop":
            if k == "escape":
                self.focus = "editor"
            else:
                self.workshop.handle_event(e)
        else:
            self._editor_key(e)

    def _menu_mnemonic(self, k):
        var i = 0
        while i < len(self.menus):
            var m = string_lower(string_slice(self.menus[i], 0, 1))
            if i < len(self.menu_mnemonics):
                m = self.menu_mnemonics[i]
            if m == k:
                return i
            i = i + 1
        return -1

    def _modal_key(self, e):
        if self.key_capture != "" and self._capture_key(e):
            return
        var k = e.key
        var n = len(self.modal_buttons)
        if k == "escape":
            self._exec_modal_cmd("@modal.cancel", "")
        elif k == "left" or (k == "tab" and e.shift):
            self.modal_sel = (self.modal_sel + n - 1) % n
        elif k == "right" or k == "tab":
            self.modal_sel = (self.modal_sel + 1) % n
        elif k == "enter" or k == "space":
            var bt = self.modal_buttons[self.modal_sel]
            if string_startswith(bt[1], "@"):
                self._exec_modal_cmd(bt[1], bt[2])
            else:
                self._modal_close()
                self._exec(bt[1], bt[2])

    def _qi_key(self, e):
        var k = e.key
        if k == "escape":
            self.qi.close()
            self.focus = self.focus_before_qi
            return true
        if k == "enter":
            self._qi_accept(self.qi.current())
            return true
        if k == "down":
            self.qi.move(1)
            return true
        if k == "up":
            self.qi.move(0 - 1)
            return true
        if k == "pagedown":
            self.qi.page(1)
            return true
        if k == "pageup":
            self.qi.page(0 - 1)
            return true
        if k == "tab" and self.qi.kind == "path":
            var it = self.qi.current()
            if it != none:
                self.qi.set_value(it.value)
                self.qi.sel_moved = false
                self._path_items_refresh()
            return true
        return self._field_key(e)

    def _one_line(self, s):
        var t = string_replace(s, "\r", "")
        var nl = string_find(t, "\n")
        if nl >= 0:
            t = string_slice(t, 0, nl)
        return t

    def _menu_key(self, e):
        var k = e.key
        if self.menu_open >= len(self.menus):
            # The hamburger's list of menus.
            var n = len(self.menus)
            if k == "escape":
                self._close_overlays()
            elif k == "down":
                self.menu_sel = (self.menu_sel + 1) % n
            elif k == "up":
                self.menu_sel = (self.menu_sel + n - 1) % n
            elif (k == "enter" or k == "right" or k == "space") and self.menu_sel >= 0:
                self.menu_open = self.menu_sel
                self.menu_sel = -1
            return
        if k == "left" and self.menu_compact:
            self.menu_sel = self.menu_open
            self.menu_open = len(self.menus)
            return
        var items = self.menu_items[self.menus[self.menu_open]]
        if k == "escape":
            self._close_overlays()
        elif k == "down" or k == "up":
            var d = 1
            if k == "up":
                d = 0 - 1
            var i = self.menu_sel
            var guard = 0
            while guard <= len(items):
                i = (i + d + len(items)) % len(items)
                if items[i] != "-" and self._command_enabled(items[i]):
                    guard = len(items) + 1
                guard = guard + 1
            self.menu_sel = i
        elif k == "left" or k == "right":
            var d2 = 1
            if k == "left":
                d2 = 0 - 1
            self.menu_open = (self.menu_open + d2 + len(self.menus)) % len(self.menus)
            self.menu_sel = -1
        elif k == "enter" or k == "space":
            if self.menu_sel >= 0 and self.menu_sel < len(items) and items[self.menu_sel] != "-":
                var id = items[self.menu_sel]
                self._close_overlays()
                self._exec(id, none)

    def _ctx_key(self, e):
        var k = e.key
        if k == "escape":
            self.ctx_open = false
        elif k == "down" or k == "up":
            var d = 1
            if k == "up":
                d = 0 - 1
            var n = len(self.ctx_items)
            var i = self.ctx_sel
            var guard = 0
            while guard <= n:
                i = (i + d + n) % n
                if self.ctx_items[i][0] != "-":
                    guard = n + 1
                guard = guard + 1
            self.ctx_sel = i
        elif k == "enter":
            if self.ctx_sel >= 0:
                var fake = Hit()
                fake.cmd = "@ctx.item"
                fake.arg = self.ctx_sel
                self._click(fake, e)

    def _find_key(self, e):
        var k = e.key
        if self._field_key(e):
            return
        if k == "escape":
            self.find_open = false
            self.focus = "editor"
        elif k == "enter":
            if e.ctrl and e.alt:
                self._replace_all()
            elif self.find_field == 1:
                self._replace_one()
            elif e.shift:
                self._find_step(0 - 1)
            else:
                self._find_step(1)
        elif k == "tab":
            if self.find_replace_mode:
                self.find_field = 1 - self.find_field
                var fname = "find" + str(self.find_field)
                self._le(fname).reset(self._field_get(fname), true)
        elif e.alt and k == "c":
            self.find_case = not self.find_case
            self._find_run()
        elif e.alt and k == "w":
            self.find_word = not self.find_word
            self._find_run()
        elif e.alt and k == "r":
            self.find_regex = not self.find_regex
            self._find_run()
        self._find_info_update()

    def _find_type(self, t):
        self._field_type("find" + str(self.find_field), t)
        self._find_info_update()

    def _find_info_update(self):
        if self.find_error != "":
            self.find_info = self.find_error
        elif self.find_n == 0:
            self.find_info = "No results"
        else:
            self.find_info = str(self.find_index + 1) + " of " + str(self.find_n)

    def _search_key(self, e):
        var k = e.key
        if self._field_key(e):
            return
        if k == "escape":
            self.focus = "editor"
        elif k == "enter":
            if self.search_field == 1:
                self._search_replace_all()
            else:
                self._run_search()
        elif k == "tab":
            if self.search_replace_open:
                self.search_field = 1 - self.search_field
                var sname = "search" + str(self.search_field)
                self._le(sname).reset(self._field_get(sname), true)

    # Search as you type, once typing pauses (_field_set schedules it).
    def _search_type(self, t):
        self._field_type("search" + str(self.search_field), t)

    # Single-line inputs: the SCM message box, the Debug Console, the
    # extensions filter.
    def _line_input_key(self, e, which):
        var k = e.key
        var v = self._input_value(which)
        if self._field_key(e):
            return
        if k == "escape":
            self.focus = "editor"
            return
        if k == "enter":
            if which == "scm":
                self._git_command("git.commit", none)
            elif which == "dbgcon":
                self._dbg_eval(v)
                self.dbgcon_input = ""
            return

    def _input_value(self, which):
        if which == "scm":
            return self.scm_msg
        if which == "dbgcon":
            return self.dbgcon_input
        if which == "ext":
            return self.ext_query
        return ""

    def _set_input_value(self, which, v):
        if which == "scm":
            self.scm_msg = v
        elif which == "dbgcon":
            self.dbgcon_input = v
        elif which == "ext":
            self.ext_query = v
            self.tree_scroll = 0

    # ── single-line inputs ───────────────────────────────────────────────────
    # Every input edits through a LineEdit (lib/ide_workbench.ny); the value
    # itself stays in the attribute the rest of the IDE already reads.
    def _focused_field(self):
        var f = self.focus
        if f == "qi" and self.qi.visible:
            return "qi"
        if f == "find":
            return "find" + str(self.find_field)
        if f == "search":
            return "search" + str(self.search_field)
        if f == "scm":
            return "scm"
        if f == "terminal":
            return "term"
        if f == "dbgconsole":
            return "dbgcon"
        if f == "extsearch":
            return "ext"
        return ""

    def _le(self, name):
        if not self.fields.has_key(name):
            self.fields[name] = LineEdit()
        return self.fields[name]

    def _field_get(self, name):
        if name == "qi":
            return self.qi.value
        if name == "find0":
            return self.find_query
        if name == "find1":
            return self.find_replace
        if name == "search0":
            return self.search_query
        if name == "search1":
            return self.search_replace
        if name == "scm":
            return self.scm_msg
        if name == "term":
            return self.term_input
        if name == "dbgcon":
            return self.dbgcon_input
        if name == "ext":
            return self.ext_query
        return ""

    def _field_set(self, name, v):
        if name == "qi":
            self.qi.set_value(v)
            self._qi_value_changed()
        elif name == "find0":
            self.find_query = v
            self._find_run()
            self._find_info_update()
        elif name == "find1":
            self.find_replace = v
        elif name == "search0":
            self.search_query = v
            self.search_due = time_ms() + 300
        elif name == "search1":
            self.search_replace = v
        elif name == "scm":
            self.scm_msg = v
        elif name == "term":
            self.term_input = v
        elif name == "dbgcon":
            self.dbgcon_input = v
        elif name == "ext":
            self.ext_query = v
            self.tree_scroll = 0

    def _field_type(self, name, t):
        var v = self._field_get(name)
        self._field_set(name, self._le(name).insert(v, t))

    # Caret, selection and clipboard keys for the focused input. False for
    # the keys its owner handles (Enter, Escape, Tab, Up/Down, and Ctrl+C with
    # nothing selected, which interrupts in the terminal).
    def _field_key(self, e):
        var name = self._focused_field()
        if name == "":
            return false
        var le = self._le(name)
        var v = self._field_get(name)
        var k = e.key
        if e.ctrl and not e.alt and not e.shift and (k == "c" or k == "x"):
            if not le.has_sel():
                return false
            self._set_clipboard(le.selected(v))
            if k == "x":
                self._field_set(name, le.insert(v, ""))
            return true
        if e.ctrl and not e.alt and k == "v":
            self._field_type(name, self._one_line(self._get_clipboard()))
            return true
        var nv = le.key(v, e)
        if nv == none:
            return false
        if nv != v:
            self._field_set(name, nv)
        return true

    # A click inside an input puts the caret under the pointer (Shift+click
    # extends the selection; a double click selects the word).
    def _field_click(self, name, e):
        var v = self._field_get(name)
        var le = self._le(name)
        le.sync(v)
        var x0 = 0
        if self.field_vx.has_key(name):
            x0 = self.field_vx[name]
        var font = self.f_ui
        if name == "term" or name == "dbgcon":
            font = self.f_mono_small
        var i = 0
        var best = 0
        var bestd = 1000000
        while i <= len(v):
            var dx = abs(x0 + font.width(string_slice(v, 0, i)) - e.x)
            if dx < bestd:
                bestd = dx
                best = i
            i = i + 1
        if e.clicks >= 2:
            le.select(v, le.word_left(v, best), le.word_right(v, best))
        elif e.shift:
            le.caret = best
        else:
            le.select(v, best, best)

    # ── terminal ─────────────────────────────────────────────────────────────
    def _term_key(self, e):
        var k = e.key
        if self._field_key(e):
            return
        if k == "enter":
            var cmd = self.term_input
            self._term_print(self.term_prompt + " " + cmd, "cmd")
            self.term_input = ""
            self.term_follow = true
            self._term_run(cmd)
        elif k == "up":
            self.term_input = self.cmdline.history_prev()
        elif k == "down":
            self.term_input = self.cmdline.history_next()
        elif k == "tab":
            var comp = self.cmdline.complete(self.term_input)
            if len(comp) == 1:
                self.term_input = comp[0]
            elif len(comp) > 1:
                self._term_print(string_join(comp, "  "), "dim")
        elif e.ctrl and k == "c":
            if self.term_proc != none and self.term_proc.running:
                self.term_proc.stop()
                self._term_print("^C", "warn")
            else:
                self.term_input = ""
        elif e.ctrl and k == "l":
            self.term_lines = []
            self.term_kinds = []
        elif e.ctrl and k == "v":
            self.term_input = self.term_input + self._one_line(self._get_clipboard())
        elif k == "escape":
            self.focus = "editor"

    # ":" IDE command, ">" Nython expression, "@" analyser; anything else is a
    # shell command run in the background in the terminal's folder.
    def _term_run(self, raw):
        var c = string_strip(raw)
        if c == "":
            return
        if c == "clear" or c == "cls":
            self.term_lines = []
            self.term_kinds = []
            return
        if string_startswith(c, ":") or string_startswith(c, ">") or string_startswith(c, "@"):
            var res = self.cmdline.execute(c, self)
            var i = 0
            while i < len(res.lines):
                self._term_print(res.lines[i], "out")
                i = i + 1
            self._term_dispatch(res.action, res.arg)
            return
        self.cmdline.push_history(c)
        if c == "cd" or string_startswith(c, "cd "):
            var dest = string_strip(string_slice(c, 2, len(c)))
            if dest == "" or dest == "~":
                dest = getenv("HOME")
            elif not string_startswith(dest, "/"):
                dest = path_join(self.term_cwd, dest)
            var real = string_strip(os_exec("cd " + self._q(dest) + " 2>/dev/null && pwd"))
            if real != "" and os_isdir(real):
                self.term_cwd = real
            else:
                self._term_print("cd: no such directory: " + dest, "err")
            return
        if self.term_proc != none and self.term_proc.running:
            self._term_print("A command is still running (Ctrl+C stops it)", "warn")
            return
        self.term_seq = self.term_seq + 1
        self.term_proc = BgProc("/tmp/nyide_term_" + str(self.session_id) + "_" + str(self.term_seq))
        self.term_proc.start(c, self.term_cwd)

    def _poll_term(self):
        if self.term_proc == none or not self.term_proc.running:
            return
        var lines = self.term_proc.poll(80)
        var i = 0
        while i < len(lines):
            self._term_print(self._strip_ansi(lines[i]), "out")
            i = i + 1
        if not self.term_proc.running and self.term_proc.code != 0:
            self._term_print("[exit code " + str(self.term_proc.code) + "]", "dim")

    def _term_dispatch(self, action, arg):
        if action == "" or action == none:
            return
        if action == "clear":
            self.term_lines = []
            self.term_kinds = []
        elif action == "run" or action == "build":
            self._run_active("Run")
        elif action == "vm":
            self._run_active("VM")
        elif action == "tokens":
            self._run_active("Tokenize")
        elif action == "ast":
            self._run_active("AST")
        elif action == "disasm":
            self._run_active("Disasm")
        elif action == "profile":
            self._run_active("Profile")
        elif action == "save":
            self._exec("workbench.action.files.save", none)
        elif action == "theme":
            self._exec("nython.toggleTheme", none)
        elif action == "quit":
            self._quit(false)
        elif action == "open":
            if arg != "":
                var p = arg
                if not string_startswith(p, "/"):
                    p = path_join(self.term_cwd, p)
                self._open_path(p, -1, 0)
        elif action == "goto":
            if arg != "":
                self._goto(self._int_or(arg, 1) - 1, 0)
        elif action == "find":
            self.find_query = arg
            self._open_find(false)
        elif action == "panel":
            var i = 0
            while i < len(self.panel_keys):
                if string_lower(self.panel_labels[i]) == string_lower(arg) or self.panel_keys[i] == string_lower(arg):
                    self._show_panel(self.panel_keys[i])
                i = i + 1
        elif string_startswith(action, "agent:"):
            var verb = string_slice(action, 6, len(action))
            if verb == "fix" or verb == "explain":
                self._ai_analyze(true)
                if self.ai_n == 0:
                    self._term_print("no issues found in " + self.doc().title, "ok")
                var j = 0
                while j < self.ai_n:
                    var it = self.ai_issues[j]
                    self._term_print("line " + str(it["line"]) + ": " + it["message"], "out")
                    j = j + 1
            else:
                self._term_print("@" + verb + " needs a language model, which is not connected; @explain and @fix use the local analyser.", "warn")

    # ── editor keys ──────────────────────────────────────────────────────────
    def _editor_key(self, e):
        if not self._is_text():
            if e.key == "escape":
                self._close_overlays()
            return
        var k = e.key
        var d = self.doc()
        var b = d.buf
        var nav = k == "left" or k == "right" or k == "up" or k == "down" or k == "home" or k == "end" or k == "pageup" or k == "pagedown"
        if nav and self.column_mode and e.shift and not e.ctrl and not e.alt and (k == "left" or k == "right" or k == "up" or k == "down"):
            b.begin_group()
            self._box_key(k)
            return
        if nav:
            b.begin_group()
            var had_sel = self._sel_range()
            if e.shift:
                self._sel_begin()
            elif had_sel != none and (k == "left" or k == "right") and not e.ctrl:
                # Left/Right with a selection collapses it to that edge.
                d.sel_on = false
                if k == "left":
                    b.cursor_row = had_sel[0]
                    b.cursor_col = had_sel[1]
                else:
                    b.cursor_row = had_sel[2]
                    b.cursor_col = had_sel[3]
                self._reveal_caret()
                return
            else:
                d.sel_on = false
            self._move_caret(k, e.ctrl)
            if self.selmodel.count > 1 and not e.shift:
                self._move_extra_carets(k, e.ctrl)
            self._reveal_caret()
            self.ac_open = false
            return
        if k == "escape":
            if len(self.snip_marks) > 0:
                # Leaves snippet mode (the remaining tab stops), as in VS Code.
                self.snip_marks = []
                self.snip_cur = []
                d.sel_on = false
            elif self.selmodel.count > 1:
                self._clear_extra_carets()
            elif self.find_open:
                self.find_open = false
            elif d.sel_on:
                d.sel_on = false
            return
        if d.readonly:
            if k == "backspace" or k == "delete" or k == "enter" or k == "tab":
                self.status_msg = d.title + " is read-only"
            return
        if k == "backspace":
            self._edit_backspace(e.ctrl)
        elif k == "delete":
            self._edit_delete(e.ctrl)
        elif k == "enter":
            self._edit_enter()
        elif k == "tab":
            var sr = self._sel_range()
            if not e.shift and len(self.snip_marks) > 0 and self._snippet_next():
                return
            if not e.shift and sr == none and not self.ac_open and self._snippet_try():
                return
            if e.shift:
                self._indent_selection(false)
            elif sr != none and sr[0] != sr[2]:
                self._indent_selection(true)
            else:
                self._edit_type(self._spaces_to_tab_stop())
        else:
            return
        self._after_typing()

    def _spaces_to_tab_stop(self):
        if not self.insert_spaces:
            return "\t"
        var b = self.buf()
        # Measured in visual columns, so a tab earlier on the line counts as
        # the width it is drawn at.
        var vis = len(self._expand_tabs(string_slice(b.get_line(b.cursor_row), 0, b.cursor_col), 0))
        return " " * (self.tab_size - (vis % self.tab_size))

    def _move_caret(self, k, ctrl):
        var b = self.buf()
        if k == "left":
            if ctrl:
                var w = b.word_left(b.cursor_row, b.cursor_col)
                b.cursor_row = w[0]
                b.cursor_col = w[1]
            elif b.cursor_col > 0:
                b.cursor_col = b.cursor_col - 1
            elif b.cursor_row > 0:
                var dl = self.doc()
                b.cursor_row = self._vrow_to_row(dl, self._row_to_vrow(dl, b.cursor_row) - 1)
                b.cursor_col = len(b.get_line(b.cursor_row))
            self.want_col = -1
        elif k == "right":
            if ctrl:
                var w2 = b.word_right(b.cursor_row, b.cursor_col)
                b.cursor_row = w2[0]
                b.cursor_col = w2[1]
            elif b.cursor_col < len(b.get_line(b.cursor_row)):
                b.cursor_col = b.cursor_col + 1
            elif b.cursor_row + 1 < b.line_count:
                # Past the end of a folded header: to the next visible line.
                var dv = self.doc()
                var nxt = self._vrow_to_row(dv, self._row_to_vrow(dv, b.cursor_row) + 1)
                if nxt > b.cursor_row and nxt < b.line_count:
                    b.cursor_row = nxt
                    b.cursor_col = 0
            self.want_col = -1
        elif k == "up" or k == "down" or k == "pageup" or k == "pagedown":
            var dr = 1
            if k == "up":
                dr = 0 - 1
            elif k == "pageup":
                dr = 0 - (self._rows_visible() - 1)
            elif k == "pagedown":
                dr = self._rows_visible() - 1
            if ctrl and (k == "up" or k == "down"):
                # Ctrl+Up/Down scrolls without moving the caret.
                self.doc().scroll_y = self.doc().scroll_y + dr * self.LINE_H
                self._clamp_scroll()
                return
            # Vertical movement aims for the column the caret started in, and
            # counts screen rows: a folded region is stepped over in one.
            if self.want_col < 0:
                self.want_col = b.cursor_col
            var d = self.doc()
            var vr = self._row_to_vrow(d, b.cursor_row) + dr
            if vr < 0:
                b.cursor_row = 0
                b.cursor_col = 0
                return
            if vr >= self._vis_count(d):
                b.cursor_row = self._vrow_to_row(d, self._vis_count(d) - 1)
                b.cursor_col = len(b.get_line(b.cursor_row))
                return
            var nr = self._vrow_to_row(d, vr)
            b.cursor_row = nr
            b.cursor_col = self._clamp_col(nr, self.want_col)
            if k == "pageup" or k == "pagedown":
                self.doc().scroll_y = self.doc().scroll_y + dr * self.LINE_H
                self._clamp_scroll()
        elif k == "home":
            if ctrl:
                b.cursor_row = 0
                b.cursor_col = 0
            else:
                # Smart Home: first non-blank, then column 0.
                var ind = self._line_indent(b.get_line(b.cursor_row))
                if b.cursor_col == ind:
                    b.cursor_col = 0
                else:
                    b.cursor_col = ind
            self.want_col = -1
        elif k == "end":
            if ctrl:
                b.cursor_row = b.line_count - 1
            b.cursor_col = len(b.get_line(b.cursor_row))
            self.want_col = -1

    def _move_extra_carets(self, k, ctrl):
        var b = self.buf()
        var i = 1
        while i < self.selmodel.count:
            var s = self.selmodel.sels[i]
            var r = s.caret.row
            var c = s.caret.col
            if k == "left" and c > 0:
                c = c - 1
            elif k == "right" and c < len(b.get_line(r)):
                c = c + 1
            elif k == "up" and r > 0:
                r = r - 1
            elif k == "down" and r + 1 < b.line_count:
                r = r + 1
            elif k == "home":
                c = self._line_indent(b.get_line(r))
            elif k == "end":
                c = len(b.get_line(r))
            s.caret.row = r
            s.caret.col = self._clamp_col(r, c)
            s.anchor.row = s.caret.row
            s.anchor.col = s.caret.col
            i = i + 1

    def _edit_type(self, text):
        if not self._can_edit():
            return
        var b = self.buf()
        var d = self.doc()
        if self._sel_range() != none:
            b.begin_group()
            self._sel_delete()
            b.continue_group()
        b.insert_text_typed(text)
        self._apply_to_extra("text", text)
        d.sel_on = false

    def _edit_backspace(self, ctrl):
        var b = self.buf()
        if self._sel_range() != none:
            b.begin_group()
            self._sel_delete()
            self._apply_to_extra("backspace", "")
            b.begin_group()
            return
        if ctrl:
            var w = b.word_left(b.cursor_row, b.cursor_col)
            b.begin_group()
            b.delete_range(w[0], w[1], b.cursor_row, b.cursor_col)
            b.begin_group()
            return
        var line = b.get_line(b.cursor_row)
        var c = b.cursor_col
        # Deleting the opening half of an auto-closed pair removes both.
        if c > 0 and c < len(line) and self.selmodel.count <= 1:
            var pair = string_slice(line, c - 1, c + 1)
            if pair == "()" or pair == "[]" or pair == "{}" or pair == "\"\"" or pair == "''":
                b.delete_char_forward()
        # Backspace in leading whitespace removes to the previous tab stop.
        if c > 1 and self._line_indent(line) >= c and self.selmodel.count <= 1:
            var to = c - 1 - ((c - 1) % self.tab_size)
            b.delete_range(b.cursor_row, to, b.cursor_row, c)
            return
        b.delete_char_back()
        self._apply_to_extra("backspace", "")

    def _edit_delete(self, ctrl):
        var b = self.buf()
        if self._sel_range() != none:
            b.begin_group()
            self._sel_delete()
            b.begin_group()
            return
        if ctrl:
            var w = b.word_right(b.cursor_row, b.cursor_col)
            b.begin_group()
            b.delete_range(b.cursor_row, b.cursor_col, w[0], w[1])
            b.begin_group()
            return
        b.delete_char_forward()
        self._apply_to_extra("delete", "")

    def _edit_enter(self):
        var b = self.buf()
        if self._sel_range() != none:
            b.begin_group()
            self._sel_delete()
        # Enter between a pair of brackets opens an indented block.
        var line = b.get_line(b.cursor_row)
        var c = b.cursor_col
        var pr = string_slice(line, c - 1, c + 1)
        var between = c > 0 and c < len(line) and (pr == "()" or pr == "[]" or pr == "{}")
        b.insert_newline()
        if between and self.selmodel.count <= 1:
            var r = b.cursor_row
            b.insert_text(self._indent_unit())
            var save_c = b.cursor_col
            b.insert_newline_raw()
            b.insert_text(string_slice(b.get_line(r - 1), 0, self._line_indent(b.get_line(r - 1))))
            b.cursor_row = r
            b.cursor_col = save_c
        self._apply_to_extra("enter", "")
        self.doc().sel_on = false

    def _after_typing(self):
        self._after_edit()
        self._reveal_caret()
        if self.auto_save == "afterDelay" and self.doc().kind == "file":
            self.autosave_due = time_ms() + 1000

    def _on_text(self, e):
        var t = e.text
        if t == "" or t == none:
            return
        self._dirty = true
        self.caret_on = true
        self.caret_t = time_ms()
        var f = self.focus
        if self.modal_open:
            return
        if f == "qi" and self.qi.visible:
            self._field_type("qi", t)
            return
        if self.menu_open >= 0 or self.ctx_open:
            return
        if f == "find":
            self._find_type(t)
        elif self._focused_field() != "":
            self._field_type(self._focused_field(), t)
        elif f == "workshop":
            self.workshop.handle_event(e)
        elif f == "explorer" or f == "panel":
            return
        else:
            self._editor_text(t)

    def _editor_text(self, t):
        if not self._can_edit():
            return
        var b = self.buf()
        var closer = self._auto_closer(t)
        var line = b.get_line(b.cursor_row)
        var c = b.cursor_col
        # Typing a closing character that is already next to the caret
        # steps over it instead of doubling it.
        var is_close = t == ")" or t == "]" or t == "}" or t == "\"" or t == "'"
        if is_close and c < len(line) and string_slice(line, c, c + 1) == t and self.selmodel.count <= 1 and self._sel_range() == none:
            b.cursor_col = c + 1
            self._after_typing()
            return
        var sel = self._sel_range()
        if closer != "" and sel != none and sel[0] == sel[2] and self.selmodel.count <= 1:
            # Wrap the selection in the pair.
            var inner = self._sel_text()
            var g = b.open_group()
            self._sel_delete()
            b.insert_text(t + inner + closer)
            b.close_group(g)
            self._after_typing()
            return
        self._overwrite_prepare()
        self._edit_type(t)
        var next = string_slice(b.get_line(b.cursor_row), b.cursor_col, b.cursor_col + 1)
        var room = next == "" or next == " " or next == ")" or next == "]" or next == "}" or next == ","
        if closer != "" and room and self.selmodel.count <= 1:
            var prev_is_word = b.cursor_col >= 2 and self._is_word_ch(string_slice(b.get_line(b.cursor_row), b.cursor_col - 2, b.cursor_col - 1))
            if not ((t == "\"" or t == "'") and prev_is_word):
                b.insert_text_typed(closer)
                b.cursor_col = b.cursor_col - 1
        self._after_typing()
        self._ac_update(t)

    def _auto_closer(self, t):
        if t == "(":
            return ")"
        if t == "[":
            return "]"
        if t == "{":
            return "}"
        if t == "\"":
            return "\""
        if t == "'":
            return "'"
        return ""

    def _is_word_ch(self, ch):
        return (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_"

    # ── autocomplete ─────────────────────────────────────────────────────────
    # Opens by itself after two identifier characters (VS Code's quick
    # suggestions) or with Ctrl+Space. Candidates: this file's symbols and
    # identifiers, keywords and builtins, ranked by the fuzzy matcher.
    def _ac_word_bounds(self):
        var b = self.buf()
        var line = b.get_line(b.cursor_row)
        var st = b.cursor_col
        while st > 0 and self._is_word_ch(string_slice(line, st - 1, st)):
            st = st - 1
        return st

    def _ac_open_now(self, explicit):
        if not self._is_text() or self.doc().lang != "nython":
            return
        var b = self.buf()
        var st = self._ac_word_bounds()
        self.ac_prefix = string_slice(b.get_line(b.cursor_row), st, b.cursor_col)
        if not explicit and len(self.ac_prefix) < 2:
            self.ac_open = false
            return
        # One session per word: candidates are refreshed when a word starts
        # (or on Ctrl+Space), then only re-ranked as it grows. The session is
        # the word - row, start column, document - not whether the popup is
        # showing: a word with no candidates used to close the popup and so
        # re-gather the whole document on every following keystroke (280 ms
        # per key in a 1,800-line file).
        var row = b.cursor_row
        var d = self.doc()
        if explicit or self.ac_row != row or self.ac_start != st or self.ac_doc != d:
            self._ac_gather(explicit)
            self.ac_row = row
            self.ac_start = st
            self.ac_doc = d
        # Ranked natively over the index; the lists reuse cached strings.
        var res = ac_index_rank(self.ac_index, self.ac_prefix, 60, self.ac_prefix)
        self.ac_items = res[0]
        self.ac_kinds = res[1]
        # Snippets take part in completion, as in VS Code: an exact prefix
        # goes first (so Tab after "def" expands the snippet instead of
        # accepting some other word that merely contains "def"), others
        # that start with the typed text follow the ranked words.
        self._ac_add_snippets()
        self.ac_n = len(self.ac_items)
        self.ac_mark_key = ""
        self.ac_sel = 0
        self.ac_top = 0
        self.ac_open = self.ac_n > 0
        if explicit and self.ac_n == 0:
            self.status_msg = "No suggestions."

    # The candidates live in a native completion index (ac_index_*,
    # src/builtins/text.cpp): keywords and builtins once, and this
    # document's symbols and identifiers rescanned only when it changed.
    def _ac_gather(self, force):
        if self.ac_index == 0:
            self.ac_index = ac_index_new()
            var names = []
            var kinds = []
            var i = 0
            while i < len(self.hl.storage):
                names.append(self.hl.storage[i])
                kinds.append("keyword")
                i = i + 1
            i = 0
            while i < len(self.hl.keywords):
                names.append(self.hl.keywords[i])
                kinds.append("keyword")
                i = i + 1
            i = 0
            while i < len(self.hl.builtins):
                names.append(self.hl.builtins[i])
                kinds.append("builtin")
                i = i + 1
            ac_index_set_base(self.ac_index, names, kinds)
        var b = self.buf()
        if force or self.ac_scan_doc != self.doc() or self.ac_scan_state != b.state_id():
            ac_index_scan(self.ac_index, b.lines, 3)
            self.ac_scan_doc = self.doc()
            self.ac_scan_state = b.state_id()

    def _ac_update(self, typed):
        # While a snippet's tab stops are active, suggestions only open on
        # Ctrl+Space (VS Code's editor.suggest.snippetsPreventQuickSuggestions):
        # otherwise Tab, meant for the next stop, would accept a suggestion.
        if len(self.snip_marks) > 0:
            self.ac_open = false
            return
        if self._is_word_ch(typed):
            self._ac_open_now(false)
        else:
            self.ac_open = false

    def _ac_key(self, e):
        var k = e.key
        if k == "escape":
            self.ac_open = false
            return true
        if k == "down":
            self.ac_sel = (self.ac_sel + 1) % self.ac_n
        elif k == "up":
            self.ac_sel = (self.ac_sel + self.ac_n - 1) % self.ac_n
        elif k == "enter" or k == "tab":
            self._ac_accept()
            return true
        else:
            if k == "left" or k == "right" or k == "home" or k == "end" or k == "pageup" or k == "pagedown":
                self.ac_open = false
            return false
        if self.ac_sel < self.ac_top:
            self.ac_top = self.ac_sel
        if self.ac_sel >= self.ac_top + 10:
            self.ac_top = self.ac_sel - 9
        return true

    def _ac_accept(self):
        if self.ac_n == 0 or not self._can_edit():
            self.ac_open = false
            return
        var word = self.ac_items[self.ac_sel]
        var b = self.buf()
        var st = self._ac_word_bounds()
        if self.ac_kinds[self.ac_sel] == "snippet":
            var body = self._snippet_body(word)
            if body != none:
                self.ac_open = false
                var g0 = b.open_group()
                b.delete_range(b.cursor_row, st, b.cursor_row, b.cursor_col)
                b.cursor_col = st
                self._snippet_expand(body)
                b.close_group(g0)
                return
        var g = b.open_group()
        b.delete_range(b.cursor_row, st, b.cursor_row, b.cursor_col)
        b.insert_text(word)
        b.close_group(g)
        self.ac_open = false
        self._after_edit()

    # ── code hover ───────────────────────────────────────────────────────────
    def _update_hover_info(self):
        if self.hover_done or time_ms() - self.hover_t0 < 600:
            return
        self.hover_done = true
        if not self._is_text() or self.mouse_down or self._any_overlay():
            return
        var p = self._pos_at(self.mx, self.my)
        var b = self.buf()
        var w = b.word_at(p[0], p[1])
        if w[1] <= w[0]:
            return
        var word = string_slice(b.get_line(p[0]), w[0], w[1])
        var info = ""
        if self.dbg.active:
            var v = self.dbg.value_of(word)
            if v != none:
                info = word + " = " + v
        if info == "":
            var syms = self._outline_syms()
            var i = 0
            while i < len(syms) and info == "":
                if syms[i][0] == word:
                    info = string_strip(b.get_line(syms[i][2]))
                    if string_endswith(info, ":"):
                        info = string_slice(info, 0, len(info) - 1)
                i = i + 1
        if info == "" and self.hl._bi.has_key(word):
            info = "builtin function " + word
        if info != "":
            self.hover_info = info
            self.hover_x = self.mx
            self.hover_y = self.ed_y + (p[0] * self.LINE_H - self.doc().scroll_y)
            self._dirty = true

    # ══ frame loop ═════════════════════════════════════════════════════════════
    def _advance_panes(self):
        var moved = false
        var st = 0.0
        if self.sidebar_open:
            st = 1.0
        var ds = st - self.sidebar_anim
        if ds > 0.004 or ds < -0.004:
            self.sidebar_anim = self.sidebar_anim + ds * 0.3
            moved = true
        elif self.sidebar_anim != st:
            self.sidebar_anim = st
            moved = true
        var pt = 0.0
        if self.panel_open:
            pt = 1.0
        var dp = pt - self.panel_anim
        if dp > 0.004 or dp < -0.004:
            self.panel_anim = self.panel_anim + dp * 0.3
            moved = true
        elif self.panel_anim != pt:
            self.panel_anim = pt
            moved = true
        return moved

    # Work that happens on the clock rather than on an event.
    def _tick(self):
        var now = time_ms()
        if self.build_running:
            self._build_step()
        self._watch_tick(now)
        if self.job_running:
            self._poll_job()
        if self.term_proc != none and self.term_proc.running:
            self._poll_term()
            self._dirty = true
        if self.check_due > 0 and now > self.check_due:
            self.check_due = 0
            if self._is_text() and self.doc().lang == "nython":
                self._check_file(self.doc())
                self._dirty = true
        if self.search_due > 0 and now > self.search_due:
            self.search_due = 0
            self._run_search()
        if self.autosave_due > 0 and now > self.autosave_due:
            self.autosave_due = 0
            var i = 0
            while i < len(self.docs):
                if self.docs[i].kind == "file" and self.docs[i].dirty():
                    self._write_doc(self.docs[i], self.docs[i].path)
                i = i + 1
            self._dirty = true
        # Re-read git status whenever the watcher (or an action) says it may
        # have changed, and otherwise only rarely, as a backstop for edits to
        # files in folders that are not expanded.
        if self.ws.root != "" and (self.scm_stale or now - self.scm_poll_t > 60000):
            self.scm_poll_t = now
            self._scm_refresh()
        if self.scm_diff_due > 0 and now > self.scm_diff_due:
            self.scm_diff_due = 0
            self._dirty = true
        if self.tip_text != "" and now - self.tip_t0 >= 550 and now - self.tip_t0 < 700:
            self._dirty = true
        if not self.hover_done:
            self._update_hover_info()
        if self.status_msg != self.last_status:
            self.last_status = self.status_msg
            self.status_t = now
            self._dirty = true
        if self.find_open:
            self._find_info_update()
        if self._title_dirty:
            self._title_dirty = false
            self._update_title()
        self._update_prob_index()

    # VS Code's title: "● file.ny - folder - NythonIDE".
    def _update_title(self):
        var t = "NythonIDE"
        if self.ws.root != "":
            t = os_path_basename(self.ws.root) + " - " + t
        var d = self.doc()
        if d.kind != "welcome":
            var mark = ""
            if d.dirty():
                mark = "\xe2\x97\x8f "
            t = mark + d.title + " - " + t
        if t != self.win.title:
            self.win.set_title(t)
        self.cc_label = self._workspace_name()

    # Error counts per file for the explorer, rebuilt when problems change.
    def _update_prob_index(self):
        if self.prob_by_path_src == self.problems:
            return
        var m = {}
        var i = 0
        while i < len(self.problems):
            var p = self.problems[i]
            if p["sev"] == "err":
                var c = m.get(p["path"])
                if c == none:
                    c = 0
                m[p["path"]] = c + 1
            i = i + 1
        self.prob_by_path = m
        self.prob_by_path_src = self.problems

    def _frame(self, renderer, event):
        self.handle_event(event)
        self._tick()
        if event.type != "idle" and event.type != "keyup" and event.type != "mousemove":
            self._dirty = true
        if self._advance_panes():
            self._layout()
        var now = time_ms()
        var f = self.focus
        var blinking = f == "editor" or f == "terminal" or f == "find" or f == "search" or f == "qi" or f == "scm" or f == "dbgconsole" or f == "extsearch"
        if blinking and now - self.caret_t > 530:
            self.caret_t = now
            self.caret_on = not self.caret_on
            self._dirty = true
        # Safety net: repaint at least twice a second even if an expose event
        # is missed. Per-frame drawing allocates nothing (ide_paint.ny rule 2),
        # so this costs time, not memory.
        if self._skipped >= 30:
            self._dirty = true
        if not self._dirty:
            self._skipped = self._skipped + 1
            return false
        if not event.is_last:
            return false
        self._skipped = 0
        self._dirty = false
        self.draw(renderer)
        return true

    def run(self):
        self.win.on_resize(self.on_resize)
        self.win.on_close(self._on_window_close)
        self.win.run(self._frame)

    def _on_window_close(self):
        self._save_settings()
        self._save_state()


if getenv("NY_IDE_NO_RUN") != "1":
    var ide = NythonIDE()
    ide.run()
