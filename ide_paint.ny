# ══════════════════════════════════════════════════════════════════════════════
#  ide_paint.ny — IDEPaint: theme, layout and every draw routine.
#  Part of the NythonIDE class chain; see ide_core.ny's header.
#
#  Two rules hold throughout this file:
#
#  1. Everything clickable registers itself in self.hits WHILE it is drawn,
#     with the command it runs. Clicks are resolved against that map, so what
#     responds is exactly what was painted, topmost first.
#
#  2. Nothing here allocates per frame. The interpreter never reclaims
#     containers or class instances (GC_NOTES.md): the previous IDE built a
#     few hundred Color/Rect/dict objects every frame and grew ~750 KB per
#     repaint - ~114 MB a minute while idle, from the caret blink alone.
#     Colours come from the theme or from _a() (a reused scratch pool),
#     rectangles are passed as numbers, and strings shown every frame are
#     cached until what they display changes.
# ══════════════════════════════════════════════════════════════════════════════

import "ide_ops.ny"
import "ide_icons.ny"


class IDETheme:
    def __init__(self):
        self.dark = true
        self.apply()

    def toggle(self):
        self.dark = not self.dark
        self.apply()

    # VS Code "Default Dark+" and "Default Light+" workbench colours.
    def apply(self):
        if self.dark:
            self.bg          = Color(30, 30, 30, 255)      # editor.background
            self.editor_bg   = Color(30, 30, 30, 255)
            self.text        = Color(204, 204, 204, 255)   # foreground
            self.text_hi     = Color(255, 255, 255, 255)
            self.text_dim    = Color(170, 170, 170, 255)
            self.text_faint  = Color(133, 133, 133, 255)
            self.title_bg    = Color(60, 60, 60, 255)      # titleBar.activeBackground
            self.activity_bg = Color(51, 51, 51, 255)      # activityBar.background
            self.activity_fg = Color(255, 255, 255, 255)
            self.activity_dim= Color(255, 255, 255, 102)
            self.side_bg     = Color(37, 37, 38, 255)      # sideBar.background
            self.side_title  = Color(187, 187, 187, 255)
            self.tabs_bg     = Color(37, 37, 38, 255)      # editorGroupHeader.tabsBackground
            self.tab_active  = Color(30, 30, 30, 255)
            self.tab_inactive= Color(45, 45, 45, 255)
            self.tab_fg      = Color(255, 255, 255, 255)
            self.tab_fg_dim  = Color(255, 255, 255, 128)
            self.panel_bg    = Color(30, 30, 30, 255)
            self.panel_border= Color(128, 128, 128, 89)
            self.panel_title = Color(231, 231, 231, 255)
            self.panel_title_dim = Color(231, 231, 231, 153)
            self.status_bg   = Color(0, 122, 204, 255)     # statusBar.background
            self.status_dbg  = Color(204, 102, 51, 255)    # statusBar.debuggingBackground
            self.status_nofolder = Color(104, 33, 122, 255)
            self.status_fg   = Color(255, 255, 255, 255)
            self.status_hover= Color(255, 255, 255, 31)
            self.border      = Color(69, 69, 69, 255)
            self.border_soft = Color(255, 255, 255, 16)
            self.accent      = Color(0, 122, 204, 255)
            self.focus       = Color(0, 127, 212, 255)     # focusBorder
            self.link        = Color(55, 148, 255, 255)
            self.sym_method  = Color(177, 128, 215, 255)   # symbolIcon.methodForeground
            self.list_active = Color(4, 57, 94, 255)       # list.activeSelectionBackground
            self.list_inactive = Color(55, 55, 61, 255)
            self.hover       = Color(42, 45, 46, 255)      # list.hoverBackground
            self.menu_bg     = Color(37, 37, 38, 255)
            self.menu_sel    = Color(4, 57, 94, 255)
            self.menu_border = Color(69, 69, 69, 255)
            self.widget_bg   = Color(37, 37, 38, 255)
            self.widget_border = Color(69, 69, 69, 255)
            self.input_bg    = Color(60, 60, 60, 255)
            self.input_fg    = Color(204, 204, 204, 255)
            self.placeholder = Color(166, 166, 166, 255)
            self.button_bg   = Color(14, 99, 156, 255)
            self.button_hover= Color(17, 119, 187, 255)
            self.button_fg   = Color(255, 255, 255, 255)
            self.button2_bg  = Color(58, 61, 65, 255)
            self.badge_bg    = Color(77, 77, 77, 255)
            self.badge_fg    = Color(255, 255, 255, 255)
            self.gutter_fg   = Color(133, 133, 133, 255)
            self.gutter_active = Color(198, 198, 198, 255)
            self.line_border = Color(40, 40, 40, 255)      # editor.lineHighlightBorder
            self.selection   = Color(38, 79, 120, 255)
            self.selection_dim = Color(58, 61, 65, 255)
            self.find_match  = Color(81, 92, 106, 255)
            self.find_other  = Color(234, 92, 0, 85)
            self.caret       = Color(174, 175, 173, 255)
            self.indent_guide= Color(64, 64, 64, 255)
            self.whitespace  = Color(227, 228, 226, 41)
            self.bracket     = Color(136, 136, 136, 255)
            self.scroll      = Color(121, 121, 121, 102)
            self.scroll_hover= Color(100, 100, 100, 179)
            self.minimap_slider = Color(121, 121, 121, 51)
            self.err         = Color(241, 76, 76, 255)
            self.warn        = Color(204, 167, 0, 255)
            self.info        = Color(55, 148, 255, 255)
            self.ok          = Color(137, 209, 133, 255)
            self.git_mod     = Color(226, 192, 141, 255)
            self.git_add     = Color(129, 184, 139, 255)
            self.git_untracked = Color(115, 201, 145, 255)
            self.git_del     = Color(199, 78, 57, 255)
            self.gutter_mod  = Color(27, 129, 168, 255)
            self.gutter_add  = Color(72, 126, 2, 255)
            self.gutter_del  = Color(241, 76, 76, 255)
            self.diff_ins_bg = Color(155, 185, 85, 51)     # diffEditor.insertedLineBackground
            self.diff_del_bg = Color(255, 0, 0, 51)        # diffEditor.removedLineBackground
            self.fold_bg     = Color(255, 255, 255, 28)    # editor.foldPlaceholder
            self.diff_ins_fg = Color(129, 184, 139, 255)
            self.diff_del_fg = Color(244, 135, 113, 255)
            self.debug_bg    = Color(51, 51, 51, 255)
            self.debug_line  = Color(255, 255, 0, 51)
            self.breakpoint  = Color(229, 20, 0, 255)
            self.scrim       = Color(0, 0, 0, 80)
            self.shadow      = Color(0, 0, 0, 92)
            self.match_hi    = Color(24, 163, 255, 255)
            self.file_ny     = Color(81, 154, 186, 255)
            self.file_md     = Color(81, 154, 186, 255)
            self.file_other  = Color(170, 170, 170, 255)
            self.welcome_title = Color(230, 230, 230, 255)
        else:
            self.bg          = Color(255, 255, 255, 255)
            self.editor_bg   = Color(255, 255, 255, 255)
            self.text        = Color(97, 97, 97, 255)
            self.text_hi     = Color(0, 0, 0, 255)
            self.text_dim    = Color(97, 97, 97, 255)
            self.text_faint  = Color(130, 130, 130, 255)
            self.title_bg    = Color(221, 221, 221, 255)
            self.activity_bg = Color(44, 44, 44, 255)
            self.activity_fg = Color(255, 255, 255, 255)
            self.activity_dim= Color(255, 255, 255, 102)
            self.side_bg     = Color(243, 243, 243, 255)
            self.side_title  = Color(111, 111, 111, 255)
            self.tabs_bg     = Color(243, 243, 243, 255)
            self.tab_active  = Color(255, 255, 255, 255)
            self.tab_inactive= Color(236, 236, 236, 255)
            self.tab_fg      = Color(51, 51, 51, 255)
            self.tab_fg_dim  = Color(51, 51, 51, 179)
            self.panel_bg    = Color(255, 255, 255, 255)
            self.panel_border= Color(128, 128, 128, 89)
            self.panel_title = Color(66, 66, 66, 255)
            self.panel_title_dim = Color(66, 66, 66, 191)
            self.status_bg   = Color(0, 122, 204, 255)
            self.status_dbg  = Color(204, 102, 51, 255)
            self.status_nofolder = Color(104, 33, 122, 255)
            self.status_fg   = Color(255, 255, 255, 255)
            self.status_hover= Color(255, 255, 255, 31)
            self.border      = Color(200, 200, 200, 255)
            self.border_soft = Color(0, 0, 0, 20)
            self.accent      = Color(0, 122, 204, 255)
            self.focus       = Color(0, 144, 241, 255)
            self.link        = Color(0, 106, 204, 255)
            self.sym_method  = Color(101, 45, 144, 255)    # symbolIcon.methodForeground
            self.list_active = Color(0, 96, 192, 255)
            self.list_inactive = Color(228, 230, 241, 255)
            self.hover       = Color(232, 232, 232, 255)
            self.menu_bg     = Color(255, 255, 255, 255)
            self.menu_sel    = Color(0, 96, 192, 255)
            self.menu_border = Color(200, 200, 200, 255)
            self.widget_bg   = Color(243, 243, 243, 255)
            self.widget_border = Color(200, 200, 200, 255)
            self.input_bg    = Color(255, 255, 255, 255)
            self.input_fg    = Color(97, 97, 97, 255)
            self.placeholder = Color(118, 118, 118, 255)
            self.button_bg   = Color(0, 122, 204, 255)
            self.button_hover= Color(0, 98, 163, 255)
            self.button_fg   = Color(255, 255, 255, 255)
            self.button2_bg  = Color(95, 106, 121, 255)
            self.badge_bg    = Color(196, 196, 196, 255)
            self.badge_fg    = Color(51, 51, 51, 255)
            self.gutter_fg   = Color(35, 120, 147, 255)
            self.gutter_active = Color(11, 33, 111, 255)
            self.line_border = Color(238, 238, 238, 255)
            self.selection   = Color(173, 214, 255, 255)
            self.selection_dim = Color(229, 235, 241, 255)
            self.find_match  = Color(168, 172, 148, 255)
            self.find_other  = Color(234, 92, 0, 85)
            self.caret       = Color(0, 0, 0, 255)
            self.indent_guide= Color(211, 211, 211, 255)
            self.whitespace  = Color(51, 51, 51, 51)
            self.bracket     = Color(185, 185, 185, 255)
            self.scroll      = Color(100, 100, 100, 102)
            self.scroll_hover= Color(100, 100, 100, 179)
            self.minimap_slider = Color(100, 100, 100, 51)
            self.err         = Color(229, 20, 0, 255)
            self.warn        = Color(191, 136, 3, 255)
            self.info        = Color(26, 133, 255, 255)
            self.ok          = Color(56, 138, 52, 255)
            self.git_mod     = Color(137, 85, 3, 255)
            self.git_add     = Color(88, 124, 12, 255)
            self.git_untracked = Color(0, 113, 0, 255)
            self.git_del     = Color(173, 7, 7, 255)
            self.gutter_mod  = Color(102, 175, 224, 255)
            self.gutter_add  = Color(129, 184, 139, 255)
            self.gutter_del  = Color(202, 75, 81, 255)
            self.diff_ins_bg = Color(155, 185, 85, 64)
            self.diff_del_bg = Color(255, 0, 0, 51)
            self.fold_bg     = Color(0, 0, 0, 22)
            self.diff_ins_fg = Color(40, 120, 50, 255)
            self.diff_del_fg = Color(170, 40, 40, 255)
            self.debug_bg    = Color(243, 243, 243, 255)
            self.debug_line  = Color(255, 255, 102, 115)
            self.breakpoint  = Color(229, 20, 0, 255)
            self.scrim       = Color(0, 0, 0, 50)
            self.shadow      = Color(0, 0, 0, 40)
            self.match_hi    = Color(0, 102, 191, 255)
            self.file_ny     = Color(37, 111, 150, 255)
            self.file_md     = Color(37, 111, 150, 255)
            self.file_other  = Color(110, 110, 110, 255)
            self.welcome_title = Color(40, 40, 40, 255)


class IDEPaint(IDEOps):
    def dp(self, v):
        return int(float(v) * self.dpi + 0.5)

    # A colour with a different alpha, from a reused pool (see rule 2 above).
    # Valid until 64 more calls; every draw call reads its colour immediately.
    def _a(self, c, alpha):
        self.scratch_i = (self.scratch_i + 1) % 64
        var s = self.scratch[self.scratch_i]
        s.r = c.r
        s.g = c.g
        s.b = c.b
        s.a = alpha
        return s

    def _hit(self, x, y, w, h, cmd, arg, tip):
        self.hits.add(x, y, w, h, cmd, arg, tip)

    # Hover feedback is suppressed under any open overlay, so nothing appears
    # to respond beneath a menu or a dialog.
    def _hov(self, x, y, w, h):
        if self.overlay_up and not self.drawing_overlay:
            return false
        return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h

    def _any_overlay(self):
        return self.menu_open >= 0 or self.ctx_open or self.qi.visible or self.modal_open or self.notif_center

    # ══ layout ═════════════════════════════════════════════════════════════════
    def _layout(self):
        self._dirty = true
        var W = self.W
        var H = self.H
        self.content_y = self.TITLE_H
        self.status_y = H - self.STATUS_H
        var ch = self.status_y - self.content_y
        if ch < 120:
            ch = 120
        self.content_h = ch
        self.side_x = self.ACT_W
        # Responsive ladder. Each step has two thresholds (hysteresis), so a
        # window resized across one does not flicker between layouts:
        #  - the side bar stops pushing the editor and floats over it (with
        #    a shadow; a click outside closes it) when the editor would be
        #    narrower than 360 dp;
        #  - the minimap goes when the editor is narrower than 560 dp;
        #  - the menus fold into a hamburger and the command centre
        #    shrinks, then hides (_draw_titlebar);
        #  - status-bar items drop lowest-priority first (_draw_statusbar);
        #  - panel tabs and activity-bar views that do not fit go to a
        #    "..." menu (_draw_panel, _draw_activitybar).
        var sw = self.SIDEBAR_W
        var need = self.ACT_W + sw + self.dp(360)
        if self.side_overlay and W > need + self.dp(48):
            self.side_overlay = false
        elif not self.side_overlay and W < need:
            self.side_overlay = true
        if self.side_overlay:
            if sw > W - self.ACT_W - self.dp(40):
                sw = W - self.ACT_W - self.dp(40)
        elif sw > W - self.ACT_W - 320:
            sw = W - self.ACT_W - 320
        if sw < 0:
            sw = 0
        self.side_w = 0
        if self.sidebar_open:
            self.side_w = int(float(sw) * self.sidebar_anim)
        elif self.sidebar_anim > 0.0:
            self.side_w = int(float(sw) * self.sidebar_anim)
        self.col_x = self.ACT_W + self.side_w
        if self.side_overlay:
            self.col_x = self.ACT_W
        self.col_w = W - self.col_x
        if self.col_w < self.dp(120):
            self.col_w = self.dp(120)
        var ph = int(float(ch) * self.panel_ratio)
        if self.panel_max:
            ph = ch - self.TAB_H - 40
        if ph < 100:
            ph = 100
        if ph > ch - self.TAB_H - 60:
            ph = ch - self.TAB_H - 60
        if ph < 0:
            ph = 0
        self.panel_h = int(float(ph) * self.panel_anim)
        self.panel_y = self.content_y + ch - self.panel_h
        self.tab_y = self.content_y
        self.crumb_y = self.content_y + self.TAB_H
        self.ed_x = self.col_x
        self.ed_y = self.crumb_y + self.CRUMB_H
        self.ed_h = self.panel_y - self.ed_y
        if self.ed_h < 40:
            self.ed_h = 40
        self.mm_w = 0
        if self.minimap_on and self.col_w > self.dp(560):
            self.mm_w = self.MINIMAP_W
        self.vs_w = self.dp(14)
        self.ed_w = self.col_w - self.mm_w - self.vs_w
        self.workshop.set_pos(self.col_x + 10, self.panel_y + self.PANEL_HEAD + 6)
        self.workshop.set_size(self.col_w - 20, self.panel_h - self.PANEL_HEAD - 12)
        self._gutter_calc()
        self._split_layout()

    # Gutter = glyph margin (breakpoints) + line numbers + change bar.
    def _gutter_calc(self):
        var digits = 3
        if len(self.docs) > 0 and self._is_text():
            var n = self.buf().line_count
            while n >= 1000 and digits < 7:
                digits = digits + 1
                n = int(n / 10)
        self.num_w = digits * self.f_code.width("0")
        self.GLYPH_W = self.dp(18)
        self.FOLD_W = self.dp(16)
        self.GUTTER_W = self.GLYPH_W + self.num_w + self.dp(20) + self.FOLD_W
        self.text_x0 = self.ed_x + self.GUTTER_W + self.dp(4)

    def on_resize(self, w, h):
        self.W = w
        self.H = h
        self._layout()

    def _show_view(self, key):
        self.active_view = key
        self.sidebar_open = true
        self.tree_scroll = 0
        self._layout()
        if key == "scm":
            self.scm_stale = true

    def _show_panel(self, key):
        self.active_panel = key
        self.panel_open = true
        self.panel_scroll = 0
        self._layout()

    def _toggle_panel_tab(self, key):
        if self.panel_open and self.active_panel == key:
            self.panel_open = false
            if self.focus == "terminal" or self.focus == "dbgconsole":
                self.focus = "editor"
        else:
            self._show_panel(key)
            if key == "terminal":
                self.focus = "terminal"
            elif key == "debug":
                self.focus = "dbgconsole"
        self._layout()

    # ── reveal helpers ───────────────────────────────────────────────────────
    def _rows_visible(self):
        var r = int(self.ed_h / self.LINE_H)
        if r < 1:
            r = 1
        return r

    def _reveal_row(self, row):
        if not self._is_text():
            return
        var d = self.doc()
        row = self._row_to_vrow(d, row)
        var top = int(d.scroll_y / self.LINE_H)
        var vis = self._rows_visible()
        if row < top:
            d.scroll_y = row * self.LINE_H
        elif row >= top + vis - 1:
            d.scroll_y = (row - vis + 2) * self.LINE_H
        self._clamp_scroll()

    def _reveal_row_center(self, row):
        if not self._is_text():
            return
        var d = self.doc()
        row = self._row_to_vrow(d, row)
        var top = int(d.scroll_y / self.LINE_H)
        var vis = self._rows_visible()
        if row < top or row >= top + vis - 1:
            d.scroll_y = (row - int(vis / 2)) * self.LINE_H
        self._clamp_scroll()

    def _reveal_caret(self):
        if not self._is_text():
            return
        var b = self.buf()
        self._reveal_row(b.cursor_row)
        # Horizontal: keep the caret inside the text area.
        var d = self.doc()
        var cx = b.cursor_col * self.char_w
        var avail = self.ed_w - self.GUTTER_W - self.dp(24)
        if cx - d.scroll_x > avail:
            d.scroll_x = cx - avail + self.char_w * 4
        if cx < d.scroll_x:
            d.scroll_x = cx - self.char_w * 4
            if d.scroll_x < 0:
                d.scroll_x = 0

    def _reveal_caret_center(self):
        if not self._is_text():
            return
        self._reveal_row_center(self.buf().cursor_row)
        self._reveal_caret()

    def _clamp_scroll(self):
        if not self._is_text():
            return
        var d = self.doc()
        # VS Code lets the last line scroll up to the top of the viewport.
        var maxs = (self._vis_count(d) - 1) * self.LINE_H
        if d.scroll_y > maxs:
            d.scroll_y = maxs
        if d.scroll_y < 0:
            d.scroll_y = 0

    def _reveal_tab(self, i):
        if i < 0 or i >= len(self.docs):
            return
        var d = self.docs[i]
        if d.tab_w == 0:
            return
        var left = self.col_x + self.tab_scroll_px
        if d.tab_x < self.col_x:
            self.tab_scroll_px = self.tab_scroll_px + (self.col_x - d.tab_x)
        elif d.tab_x + d.tab_w > self.col_x + self.col_w - self.actions_w:
            self.tab_scroll_px = self.tab_scroll_px - (d.tab_x + d.tab_w - (self.col_x + self.col_w - self.actions_w))

    def _reveal_tree_row(self, i):
        var vis = int((self.status_y - self.content_y - self.SIDE_HEAD) / self.ROW_H) - 1
        if i < self.tree_scroll:
            self.tree_scroll = i
        elif i >= self.tree_scroll + vis:
            self.tree_scroll = i - vis + 1
        if self.tree_scroll < 0:
            self.tree_scroll = 0

    # ── output / terminal / debug console models ────────────────────────────
    def _output_write(self, text, kind):
        self.out_lines.append(text)
        self.out_kinds.append(kind)
        if len(self.out_lines) > 5000:
            self.out_lines = self._tail(self.out_lines, 4000)
            self.out_kinds = self._tail(self.out_kinds, 4000)
        self.out_follow = true
        self._dirty = true

    def _output_clear(self):
        self.out_lines = []
        self.out_kinds = []
        self.panel_scroll = 0

    def _tail(self, lst, n):
        var out = []
        var i = len(lst) - n
        if i < 0:
            i = 0
        while i < len(lst):
            out.append(lst[i])
            i = i + 1
        return out

    def _term_print(self, text, kind):
        self.term_lines.append(text)
        self.term_kinds.append(kind)
        if len(self.term_lines) > 3000:
            self.term_lines = self._tail(self.term_lines, 2500)
            self.term_kinds = self._tail(self.term_kinds, 2500)
        self.term_follow = true
        self._dirty = true

    def _dbg_print(self, text, kind):
        self.dbgcon_lines.append(text)
        self.dbgcon_kinds.append(kind)
        self.dbgcon_follow = true
        self._dirty = true

    def _panel_clear(self):
        if self.active_panel == "output":
            self._output_clear()
        elif self.active_panel == "terminal":
            self.term_lines = []
            self.term_kinds = []
        elif self.active_panel == "debug":
            self.dbgcon_lines = []
            self.dbgcon_kinds = []
        elif self.active_panel == "inspector":
            self.inspect_lines = []
        elif self.active_panel == "buildlog":
            self.build_lines = []
            self.build_kinds = []
        self.panel_scroll = 0

    # ══ draw ═══════════════════════════════════════════════════════════════════
    def draw(self, r):
        self.frames = self.frames + 1
        self.hits.clear()
        self.overlay_up = self._any_overlay()
        self.drawing_overlay = false
        self.f_code.ensure_loaded()
        self._code_handle = self.f_code._handle
        var th = self.th
        r.fill_xywh(0, 0, self.W, self.H, th.bg)
        self._draw_titlebar(r)
        self._draw_activitybar(r)
        if self.side_w > 0 and not self.side_overlay:
            self._draw_sidebar(r)
        self._draw_tabs(r)
        if not self.split_on or not self._draw_split(r):
            self._draw_breadcrumbs(r)
            if self.doc().kind == "welcome":
                self._draw_welcome(r)
            else:
                self._draw_editor(r)
                if self.mm_w > 0:
                    self._draw_minimap(r)
                self._draw_vscroll(r)
                if self.find_open:
                    self._draw_find(r)
        if self.panel_h > 0:
            self._draw_panel(r)
        if self.side_w > 0 and self.side_overlay:
            # Floating: a click anywhere else in the workbench closes it.
            self._hit(self.ACT_W, self.content_y, self.W - self.ACT_W, self.content_h, "@side.dismiss", "", "")
            r.shadow_xywh(self.ACT_W, self.content_y, self.side_w, self.content_h, 14, 2, 0, th.shadow)
            self._draw_sidebar(r)
        self._draw_statusbar(r)
        if self.dbg.active:
            self._draw_debug_toolbar(r)
        # Overlays, topmost last.
        self.drawing_overlay = true
        if self.ac_open:
            self._draw_ac(r)
        if self.hover_info != "" and not self.overlay_up:
            self._draw_hover_info(r)
        if self.menu_open >= 0:
            self._draw_dropdown(r)
        if self.ctx_open:
            self._draw_ctx(r)
        if self.notif_center:
            self._draw_notif_center(r)
        self._draw_toasts(r)
        if self.qi.visible:
            self._draw_qi(r)
        if self.modal_open:
            self._draw_modal(r)
        self._draw_tooltip(r)
        self.drawing_overlay = false

    # ── title bar: menus, command center, layout controls ───────────────────
    def _draw_titlebar(self, r):
        var th = self.th
        var h = self.TITLE_H
        r.fill_xywh(0, 0, self.W, h, th.title_bg)
        self.icons.draw(r, "code", self.dp(10), int((h - self.dp(16)) / 2), self.dp(16), th.accent)
        var x = self.dp(34)
        # The menus, or - when they would crowd out the command centre and
        # the layout buttons - one hamburger that opens them (VS Code's
        # compact menu). Folds below full + 140 dp, unfolds above + 200 dp.
        var full = 0
        var i = 0
        while i < len(self.menus):
            full = full + self.f_ui.width(self.menus[i]) + self.dp(16)
            i = i + 1
        var room = self.W - self.dp(34) - self.dp(72)
        if self.menu_compact and room > full + self.dp(200):
            self.menu_compact = false
        elif not self.menu_compact and room < full + self.dp(140):
            self.menu_compact = true
        if self.menu_compact:
            var hw = self.dp(30)
            if self.menu_open >= 0 or self._hov(x, 0, hw, h):
                r.fill_round_xywh(x, self.dp(4), hw, h - self.dp(8), self._a(th.text, 30), self.dp(4))
            self.icons.draw(r, "menu", x + int((hw - self.dp(16)) / 2), int((h - self.dp(16)) / 2), self.dp(16), th.text)
            self._hit(x, 0, hw, h, "@menu", len(self.menus), "Application Menu")
            i = 0
            while i <= len(self.menus):
                self.menu_x[i] = x
                i = i + 1
            x = x + hw
        else:
            i = 0
            while i < len(self.menus):
                var name = self.menus[i]
                var w = self.f_ui.width(name) + self.dp(16)
                var open = self.menu_open == i
                if open or (self.menu_open < 0 and self._hov(x, 0, w, h)):
                    r.fill_round_xywh(x, self.dp(4), w, h - self.dp(8), self._a(th.text, 30), self.dp(4))
                r.text(name, x + self.dp(8), int((h - self.ui_h) / 2), self.f_ui, th.text)
                self._hit(x, 0, w, h, "@menu", i, "")
                self.menu_x[i] = x
                x = x + w
                i = i + 1
        var menus_end = x
        # Command center: VS Code's search box in the title bar.
        var ccw = int(self.W * 0.36)
        if ccw > self.dp(600):
            ccw = self.dp(600)
        var ccx = int((self.W - ccw) / 2)
        if ccx < menus_end + self.dp(12):
            ccx = menus_end + self.dp(12)
            ccw = self.W - ccx - self.dp(84)
        if ccw > self.dp(120):
            var cch = self.dp(22)
            var ccy = int((h - cch) / 2)
            var ccbg = self._a(th.text, 18)
            if self._hov(ccx, ccy, ccw, cch):
                ccbg = self._a(th.text, 34)
            r.fill_round_xywh(ccx, ccy, ccw, cch, ccbg, self.dp(6))
            r.round_rect_xywh(ccx, ccy, ccw, cch, self._a(th.text, 40), self.dp(6), 1)
            var label = self.cc_label
            var lw = self.f_ui.width(label)
            var lx = ccx + int((ccw - lw) / 2)
            self.icons.draw(r, "search", lx - self.dp(20), ccy + self.dp(3), self.dp(15), th.text_faint)
            r.text(label, lx, ccy + int((cch - self.ui_h) / 2), self.f_ui, th.text_dim)
            self._hit(ccx, ccy, ccw, cch, "workbench.action.quickOpen", "", "Search files by name (Ctrl+P)")
        # Layout toggles, right-aligned.
        var bx = self.W - self.dp(34)
        self._icon_button(r, bx, 0, self.dp(30), h, "layout-panel", "workbench.action.togglePanel", "", "Toggle Panel (Ctrl+J)", self.panel_open)
        bx = bx - self.dp(30)
        self._icon_button(r, bx, 0, self.dp(30), h, "layout-sidebar-left", "workbench.action.toggleSidebarVisibility", "", "Toggle Primary Side Bar (Ctrl+B)", self.sidebar_open)

    def _icon_button(self, r, x, y, w, h, icon, cmd, arg, tip, on):
        var th = self.th
        if self._hov(x, y, w, h):
            r.fill_round_xywh(x + 2, y + self.dp(4), w - 4, h - self.dp(8), self._a(th.text, 30), self.dp(5))
        var col = th.text_dim
        if on:
            col = th.text
        var s = self.dp(16)
        self.icons.draw(r, icon, x + int((w - s) / 2), y + int((h - s) / 2), s, col)
        self._hit(x, y, w, h, cmd, arg, tip)

    # ── activity bar ─────────────────────────────────────────────────────────
    def _draw_activitybar(self, r):
        var th = self.th
        var y0 = self.content_y
        r.fill_xywh(0, y0, self.ACT_W, self.status_y - y0, th.activity_bg)
        var i = 0
        var y = y0
        var s = self.dp(24)
        # Views that do not fit above the gear go to a "..." item.
        var fit = int((self.status_y - self.ACT_W - y0) / self.ACT_W)
        if fit < len(self.views):
            fit = fit - 1
        if fit < 0:
            fit = 0
        self.act_fit = fit
        while i < len(self.views) and i < fit:
            var key = self.views[i]
            var active = self.sidebar_open and self.active_view == key
            var hov = self._hov(0, y, self.ACT_W, self.ACT_W)
            var col = th.activity_dim
            if active or hov:
                col = th.activity_fg
            if active:
                r.fill_xywh(0, y, self.dp(2), self.ACT_W, th.activity_fg)
            self.icons.draw(r, self.view_icons[i], int((self.ACT_W - s) / 2), y + int((self.ACT_W - s) / 2), s, col)
            var badge = 0
            if key == "scm":
                badge = self.scm_count
            elif key == "debug" and self.dbg.active:
                badge = -1
            if badge != 0:
                var bx = int(self.ACT_W / 2) + self.dp(3)
                var by = y + int(self.ACT_W / 2) + self.dp(1)
                r.fill_round_xywh(bx, by, self.dp(16), self.dp(16), th.accent, self.dp(8))
                if badge > 0:
                    var bs = self._num(badge)
                    r.text(bs, bx + int((self.dp(16) - self.f_tiny.width(bs)) / 2), by + self.dp(1), self.f_tiny, th.status_fg)
            self._hit(0, y, self.ACT_W, self.ACT_W, "@view", key, self.view_tips[i])
            y = y + self.ACT_W
            i = i + 1
        if fit < len(self.views):
            var mh = self._hov(0, y, self.ACT_W, self.ACT_W)
            var mc = th.activity_dim
            if mh:
                mc = th.activity_fg
            self.icons.draw(r, "ellipsis", int((self.ACT_W - s) / 2), y + int((self.ACT_W - s) / 2), s, mc)
            self._hit(0, y, self.ACT_W, self.ACT_W, "@act.more", "", "Additional Views")
        # Manage (gear) at the bottom, as in VS Code.
        var gy = self.status_y - self.ACT_W
        var ghov = self._hov(0, gy, self.ACT_W, self.ACT_W)
        var gc = th.activity_dim
        if ghov:
            gc = th.activity_fg
        self.icons.draw(r, "settings-gear", int((self.ACT_W - s) / 2), gy + int((self.ACT_W - s) / 2), s, gc)
        self._hit(0, gy, self.ACT_W, self.ACT_W, "@manage", "", "Manage")

    # Small integers as strings without allocating a new string every frame.
    def _num(self, n):
        if n >= 0 and n < len(self.num_cache):
            return self.num_cache[n]
        return str(n)

    # ── editor tabs ──────────────────────────────────────────────────────────
    def _draw_tabs(self, r):
        var th = self.th
        var y = self.tab_y
        var h = self.TAB_H
        r.fill_xywh(self.col_x, y, self.col_w, h, th.tabs_bg)
        # Editor actions at the right end of the tab strip (VS Code's
        # "editor/title" area): Run, Debug, and "..." for everything else.
        var aw = self.dp(28)
        self.actions_w = aw * 3 + self.dp(8)
        var ax = self.col_x + self.col_w - self.actions_w + self.dp(4)
        var strip_w = self.col_w - self.actions_w
        r.clip_xywh(self.col_x, y, strip_w, h)
        var x = self.col_x + self.tab_scroll_px
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            var tw = self.f_ui.width(d.title) + self.dp(58)
            if tw < self.dp(100):
                tw = self.dp(100)
            d.tab_x = x
            d.tab_w = tw
            var active = i == self.active
            var hov = self._hov(x, y, tw, h)
            var bg = th.tab_inactive
            if active:
                bg = th.tab_active
            r.fill_xywh(x, y, tw, h, bg)
            if active and self.focus == "editor":
                r.fill_xywh(x, y, tw, self.dp(1), th.focus)
            r.fill_xywh(x + tw - 1, y, 1, h, th.tabs_bg)
            var icon = "file"
            var icol = th.file_other
            if d.kind == "welcome":
                icon = "info"
                icol = th.link
            elif d.kind == "virtual":
                icon = "record-keys"
                icol = th.text_dim
            elif d.lang == "nython":
                icon = "file-code"
                icol = th.file_ny
            elif d.lang == "markdown":
                icon = "markdown"
                icol = th.file_md
            self.icons.draw(r, icon, x + self.dp(10), y + int((h - self.dp(16)) / 2), self.dp(16), icol)
            var fg = th.tab_fg_dim
            if active:
                fg = th.tab_fg
            r.text(d.title, x + self.dp(32), y + int((h - self.ui_h) / 2), self.f_ui, fg)
            # Close button: always on the active tab, on hover elsewhere; a
            # modified editor shows a dot instead until hovered.
            var cx = x + tw - self.dp(26)
            var cy = y + int((h - self.dp(20)) / 2)
            var cs = self.dp(20)
            var dirty = d.dirty()
            var chov = self._hov(cx, cy, cs, cs)
            if chov:
                r.fill_round_xywh(cx, cy, cs, cs, self._a(th.text, 40), self.dp(4))
            if dirty and not chov:
                r.fill_circle(cx + int(cs / 2), cy + int(cs / 2), self.dp(4), fg)
            elif active or hov or chov:
                self.icons.draw(r, "close", cx + self.dp(2), cy + self.dp(2), self.dp(16), fg)
            self._hit(x, y, tw, h, "@tab", i, d.path)
            self._hit(cx, cy, cs, cs, "@tab.close", i, "Close (Ctrl+W)")
            x = x + tw
            i = i + 1
        self.tabs_total_w = x - (self.col_x + self.tab_scroll_px)
        r.clear_clip()
        # Tab strip scrolls with the wheel; the hit lets the wheel find it.
        self._hit(self.col_x, y, strip_w, h, "@tabstrip", "", "")
        self._reorder_hits(y, h)
        var can_run = self._is_text() and self.doc().lang == "nython"
        var rc = th.text_dim
        if can_run:
            rc = th.ok
        self._icon_button(r, ax, y, aw, h, "play", "workbench.action.debug.run", "", "Run Nython File (Ctrl+F5)", can_run)
        self._icon_button(r, ax + aw, y, aw, h, "debug-alt", "workbench.action.debug.start", "", "Debug Nython File (F5)", can_run)
        self._icon_button(r, ax + aw * 2, y, aw, h, "ellipsis", "@editor.more", "", "More Actions...", true)

    # Tab hit rectangles are re-registered on top of the strip hit so a tab
    # click resolves to the tab, not to the strip background behind it.
    def _reorder_hits(self, y, h):
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.tab_x + d.tab_w > self.col_x and d.tab_x < self.col_x + self.col_w - self.actions_w:
                var cs = self.dp(20)
                self._hit(d.tab_x, y, d.tab_w, h, "@tab", i, d.path)
                self._hit(d.tab_x + d.tab_w - self.dp(26), y + int((h - cs) / 2), cs, cs, "@tab.close", i, "Close (Ctrl+W)")
            i = i + 1

    # ── breadcrumbs ──────────────────────────────────────────────────────────
    def _draw_breadcrumbs(self, r):
        var th = self.th
        var y = self.crumb_y
        var h = self.CRUMB_H
        r.fill_xywh(self.col_x, y, self.col_w, h, th.editor_bg)
        var d = self.doc()
        if d.kind == "welcome":
            return
        self._crumbs_refresh()
        var x = self.col_x + self.dp(14)
        var ty = y + int((h - self.small_h) / 2)
        var i = 0
        var n = len(self.crumb_parts)
        while i < n:
            if i > 0:
                self.icons.draw(r, "chevron-right", x, y + int((h - self.dp(14)) / 2), self.dp(14), th.text_faint)
                x = x + self.dp(16)
            var part = self.crumb_parts[i]
            var kind = self.crumb_kinds[i]
            var w = self.f_small.width(part)
            var col = th.text_faint
            if self._hov(x - 2, y, w + 4, h):
                col = th.text
            if kind == "file":
                self.icons.draw(r, "file-code", x, y + int((h - self.dp(14)) / 2), self.dp(14), th.file_ny)
                x = x + self.dp(18)
            elif kind == "symbol":
                self.icons.draw(r, "symbol-method", x, y + int((h - self.dp(14)) / 2), self.dp(14), th.warn)
                x = x + self.dp(18)
            r.text(part, x, ty, self.f_small, col)
            var arg = self.crumb_paths[i]
            if kind == "folder":
                self._hit(x - 2, y, w + 4, h, "workbench.files.action.showActiveFileInExplorer", arg, "Reveal in Explorer")
            else:
                self._hit(x - 2, y, w + 4, h, "workbench.action.gotoSymbol", "", "Go to Symbol in Editor (Ctrl+Shift+O)")
            x = x + w + self.dp(4)
            i = i + 1

    # Recomputed only when the document or the enclosing symbol changes.
    def _crumbs_refresh(self):
        var d = self.doc()
        var row = -1
        if d.buf != none:
            row = d.buf.cursor_row
        var sym_row = self._enclosing_row(row)
        if self.crumb_doc == d and self.crumb_sym_row == sym_row and self.crumb_path == d.path and self.crumb_title == d.title:
            return
        self.crumb_doc = d
        self.crumb_sym_row = sym_row
        self.crumb_path = d.path
        self.crumb_title = d.title
        var parts = []
        var kinds = []
        var paths = []
        if d.path != "" and self.ws.root != "" and string_startswith(d.path, self.ws.root + "/"):
            var rel = self._rel(os_path_dirname(d.path))
            var acc = self.ws.root
            if rel != self._rel(self.ws.root) and os_path_dirname(d.path) != self.ws.root:
                var segs = string_split(rel, "/")
                var k = 0
                while k < len(segs):
                    acc = path_join(acc, segs[k])
                    parts.append(segs[k])
                    kinds.append("folder")
                    paths.append(acc)
                    k = k + 1
        parts.append(d.title)
        kinds.append("file")
        paths.append(d.path)
        if sym_row >= 0:
            var sym = self._symbol_on_line(d.buf.get_line(sym_row))
            if sym != none:
                parts.append(sym[0])
                kinds.append("symbol")
                paths.append("")
        self.crumb_parts = parts
        self.crumb_kinds = kinds
        self.crumb_paths = paths

    # Row of the nearest class/def at or above row with less indentation than
    # the caret line, or -1.
    def _enclosing_row(self, row):
        if row < 0 or not self._is_text():
            return -1
        var b = self.buf()
        if self.encl_state == b.state_id() and self.encl_row_in == row and self.encl_doc == self.doc():
            return self.encl_row_out
        # Innermost def/class whose body contains `row`: walk up, and only a
        # line indented less than everything seen so far can open the scope.
        var i = row
        var found = -1
        var lim = 100000
        while i >= 0:
            var ln = b.get_line(i)
            var j = 0
            var ind = 0
            while j < len(ln) and (string_slice(ln, j, j + 1) == " " or string_slice(ln, j, j + 1) == "\t"):
                if string_slice(ln, j, j + 1) == "\t":
                    ind = ind + 4
                else:
                    ind = ind + 1
                j = j + 1
            if j < len(ln) and (ind < lim or i == row):
                var head = string_slice(ln, j, j + 6)
                if string_startswith(head, "def ") or string_startswith(head, "class "):
                    found = i
                    i = -1
                elif ind == 0:
                    i = -1
                else:
                    lim = ind
            i = i - 1
        self.encl_state = b.state_id()
        self.encl_row_in = row
        self.encl_doc = self.doc()
        self.encl_row_out = found
        return found

    # ── editor ───────────────────────────────────────────────────────────────
    def _draw_editor(self, r):
        var th = self.th
        var d = self.doc()
        var b = d.buf
        var lh = self.LINE_H
        var ex = self.ed_x
        var ey = self.ed_y
        r.fill_xywh(ex, ey, self.ed_w, self.ed_h, th.editor_bg)
        if b == none:
            return
        if self.gutter_lines != b.line_count:
            self.gutter_lines = b.line_count
            self._gutter_calc()
        var top = int(d.scroll_y / lh)
        var yoff = d.scroll_y - top * lh
        var rows = int(self.ed_h / lh) + 2
        var text_x = self.text_x0 - d.scroll_x
        var tx_clip = ex + self.GUTTER_W
        self._hit(ex + self.GUTTER_W, ey, self.ed_w - self.GUTTER_W, self.ed_h, "@editor", "", "")
        self._hit(ex, ey, self.GLYPH_W, self.ed_h, "@gutter.glyph", "", "")
        self._hit(ex + self.GLYPH_W, ey, self.GUTTER_W - self.GLYPH_W, self.ed_h, "@gutter.num", "", "")
        var fold_x = ex + self.GUTTER_W - self.FOLD_W
        self._hit(fold_x, ey, self.FOLD_W, self.ed_h, "@gutter.fold", "", "")
        # Screen rows, not buffer rows: a folded region is one row.
        var nvis = self._vis_count(d)
        var has_folds = len(d.folds) > 0
        # Text area, clipped so horizontal scroll never paints over the gutter.
        r.clip_xywh(tx_clip, ey, self.ed_w - self.GUTTER_W, self.ed_h)
        var sel = self._sel_range()
        var cur_row = b.cursor_row
        var is_diff = d.lang == "diff"
        var i = 0
        while i < rows:
            var vr = top + i
            if vr < nvis:
                var ln = vr
                if has_folds:
                    ln = self._vrow_to_row(d, vr)
                var y = ey + i * lh - yoff
                var line = b.lines[ln]
                if ln == self.dbg_line_row and self.dbg.active and self._dbg_doc_is_active():
                    r.fill_xywh(tx_clip, y, self.ed_w - self.GUTTER_W, lh, th.debug_line)
                elif ln == cur_row and sel == none and self.focus == "editor":
                    r.fill_xywh(tx_clip, y, self.ed_w - self.GUTTER_W, 1, th.line_border)
                    r.fill_xywh(tx_clip, y + lh - 1, self.ed_w - self.GUTTER_W, 1, th.line_border)
                if is_diff and len(line) > 0:
                    var c0 = string_slice(line, 0, 1)
                    if c0 == "+" and not string_startswith(line, "+++"):
                        r.fill_xywh(tx_clip, y, self.ed_w - self.GUTTER_W, lh, th.diff_ins_bg)
                    elif c0 == "-" and not string_startswith(line, "---"):
                        r.fill_xywh(tx_clip, y, self.ed_w - self.GUTTER_W, lh, th.diff_del_bg)
                if sel != none and ln >= sel[0] and ln <= sel[2]:
                    self._draw_sel_band(r, line, ln, sel, text_x, y, lh, th.selection)
                if self.selmodel.count > 1:
                    self._draw_extra_sel_bands(r, line, ln, text_x, y, lh)
                if self.find_open and self.find_n > 0:
                    self._draw_find_marks(r, line, ln, text_x, y, lh)
                var segs = self._line_layout(line)
                if self.show_indent_guides:
                    var ind = self._line_indent(line)
                    var g = self.tab_size
                    while g < ind:
                        r.fill_xywh(text_x + g * self.char_w - self.tab_size * self.char_w, y, 1, lh, th.indent_guide)
                        g = g + self.tab_size
                if self.show_whitespace:
                    self._draw_whitespace(r, line, text_x, y, lh)
                self._draw_segs(r, segs, text_x, y + int((lh - self.code_h) / 2))
                if has_folds and self._is_folded(d, ln):
                    # The folded region's placeholder; clicking it unfolds.
                    var fx = text_x + self._col_x(line, len(line)) + self.dp(8)
                    var fw = self.dp(28)
                    r.fill_round_xywh(fx, y + self.dp(3), fw, lh - self.dp(6), th.fold_bg, self.dp(3))
                    r.text("...", fx + self.dp(6), y + int((lh - self.code_h) / 2) - self.dp(2), self.f_code, th.text_dim)
                    self._hit(fx, y, fw, lh, "@fold.marker", ln, "Unfold")
            i = i + 1
        if not has_folds:
            self._draw_bracket_match(r, b, top, yoff, text_x)
        # Carets: primary, then extras in the same blink phase.
        if self.caret_on and self.focus == "editor" and not d.readonly:
            var crow = self._row_to_vrow(d, cur_row) - top
            if crow >= 0 and crow < rows:
                var cy = ey + crow * lh - yoff
                var cx = text_x + self._col_x(b.lines[cur_row], b.cursor_col)
                if self.overwrite:
                    # Overwrite mode: a block over the character it replaces.
                    r.fill_xywh(cx, cy + 1, self.char_w, lh - 2, self._a(th.caret, 110))
                else:
                    r.fill_xywh(cx, cy + 1, self.dp(2), lh - 2, th.caret)
            if self.selmodel.count > 1:
                var ei = 1
                while ei < self.selmodel.count:
                    var s = self.selmodel.sels[ei]
                    var er = self._row_to_vrow(d, s.caret.row) - top
                    if er >= 0 and er < rows and s.caret.row < b.line_count:
                        var ecx = text_x + self._col_x(b.lines[s.caret.row], s.caret.col)
                        r.fill_xywh(ecx, ey + er * lh - yoff + 1, self.dp(2), lh - 2, th.caret)
                    ei = ei + 1
        r.clear_clip()
        # Gutter, painted after the text so a scrolled line cannot overdraw it.
        r.fill_xywh(ex, ey, self.GUTTER_W, self.ed_h, th.editor_bg)
        r.clip_xywh(ex, ey, self.GUTTER_W, self.ed_h)
        var diff = self._diff_for(d)
        var glyph_hover_row = -1
        if self._hov(ex, ey, self.GLYPH_W, self.ed_h):
            glyph_hover_row = self._vrow_to_row(d, top + int((self.my - ey + yoff) / lh))
        var gutter_hov = self._hov(ex, ey, self.GUTTER_W, self.ed_h)
        var bm = d.bookmarks
        var bj = 0
        i = 0
        while i < rows:
            var vr2 = top + i
            if vr2 < nvis:
                var ln2 = vr2
                if has_folds:
                    ln2 = self._vrow_to_row(d, vr2)
                var y2 = ey + i * lh - yoff
                var ns = self._line_num(ln2 + 1)
                var gc = th.gutter_fg
                if ln2 == cur_row:
                    gc = th.gutter_active
                var nw = self.f_code.width(ns)
                r.text(ns, ex + self.GLYPH_W + self.num_w - nw, y2 + int((lh - self.code_h) / 2), self.f_code, gc)
                var bcx = ex + int(self.GLYPH_W / 2) + 2
                var bcy = y2 + int(lh / 2)
                if self._has_break(ln2):
                    r.fill_circle(bcx, bcy, self.dp(5), th.breakpoint)
                elif ln2 == glyph_hover_row:
                    r.fill_circle(bcx, bcy, self.dp(5), self._a(th.breakpoint, 90))
                if ln2 == self.dbg_line_row and self.dbg.active and self._dbg_doc_is_active():
                    self.icons.draw(r, "debug-stackframe", bcx - self.dp(8), bcy - self.dp(8), self.dp(16), th.warn)
                # Bookmarks (sorted rows; walked alongside the visible rows).
                while bj < len(bm) and bm[bj] < ln2:
                    bj = bj + 1
                if bj < len(bm) and bm[bj] == ln2:
                    self.icons.draw(r, "bookmark", ex + self.dp(1), bcy - self.dp(7), self.dp(14), th.info)
                # Folding: a chevron on every region header while the pointer
                # is over the gutter, and always on a folded one.
                var folded = has_folds and self._is_folded(d, ln2)
                if folded or (gutter_hov and self._fold_range_at(d, ln2) != none):
                    var chev = "chevron-down"
                    if folded:
                        chev = "chevron-right"
                    self.icons.draw(r, chev, fold_x + int((self.FOLD_W - self.dp(14)) / 2), y2 + int((lh - self.dp(14)) / 2), self.dp(14), th.text_dim)
                if diff != none and ln2 < len(diff):
                    var dk = diff[ln2]
                    var dx = ex + self.GLYPH_W + self.num_w + self.dp(8)
                    if dk == 1:
                        r.fill_xywh(dx, y2, self.dp(3), lh, th.gutter_add)
                    elif dk == 2:
                        r.fill_xywh(dx, y2, self.dp(3), lh, th.gutter_mod)
                    elif dk == 3:
                        r.fill_xywh(dx - 1, y2 + lh - 3, self.dp(6), 4, th.gutter_del)
            i = i + 1
        r.clear_clip()

    def _dbg_doc_is_active(self):
        return self.dbg_line_path != "" and self.doc().path == self.dbg_line_path

    # Pixel offset of column col in line (UTF-8 aware via the font).
    def _col_x(self, line, col):
        if col <= 0:
            return 0
        var pre = line
        if col < len(line):
            pre = string_slice(line, 0, col)
        if string_find(pre, "\t") >= 0:
            return self.f_code.width(self._expand_tabs(pre, 0))
        return self.f_code.width(pre)

    # Tabs drawn as spaces up to the next tab stop; `vcol` is the visual
    # column the text starts at.
    def _expand_tabs(self, s, vcol):
        if string_find(s, "\t") < 0:
            return s
        var parts = string_split(s, "\t")
        var out = parts[0]
        var v = vcol + len(parts[0])
        var i = 1
        while i < len(parts):
            var pad = self.tab_size - (v % self.tab_size)
            out = out + " " * pad + parts[i]
            v = v + pad + len(parts[i])
            i = i + 1
        return out

    def _line_num(self, n):
        while len(self.line_nums) <= n:
            self.line_nums.append(str(len(self.line_nums)))
        return self.line_nums[n]

    def _line_indent(self, line):
        var i = 0
        var n = len(line)
        while i < n and string_slice(line, i, i + 1) == " ":
            i = i + 1
        return i

    # Highlight layout for one line, cached by content (see rule 2).
    def _line_layout(self, line):
        var lang = self.doc().lang
        if lang == "diff":
            return self._diff_layout(line)
        if self._hl_cache.has_key(line):
            return self._hl_cache[line]
        var segs = none
        if lang == "nython":
            segs = self.hl.tokenise_line(line)
        else:
            segs = [{"text": line, "color": self.hl.c_default}]
        var dx = 0
        var k = 0
        var has_tab = string_find(line, "\t") >= 0
        var vcol = 0
        while k < len(segs):
            segs[k]["dx"] = dx
            if has_tab:
                var shown = self._expand_tabs(segs[k]["text"], vcol)
                segs[k]["text"] = shown
                vcol = vcol + len(shown)
            dx = dx + self.f_code.width(segs[k]["text"])
            k = k + 1
        if self._hl_cache_n > 3000:
            self._hl_cache = {}
            self._hl_cache_n = 0
        self._hl_cache[line] = segs
        self._hl_cache_n = self._hl_cache_n + 1
        return segs

    # A unified diff (Source Control's Open Changes): added lines green,
    # removed red, hunk headers blue, file headers dim. Its own cache, since
    # "+x" means something else in a Nython file.
    def _diff_layout(self, line):
        if self._diff_cache.has_key(line):
            return self._diff_cache[line]
        var th = self.th
        var col = self.hl.c_default
        if string_startswith(line, "+++") or string_startswith(line, "---") or string_startswith(line, "diff ") or string_startswith(line, "index "):
            col = th.text_faint
        elif string_startswith(line, "+"):
            col = th.diff_ins_fg
        elif string_startswith(line, "-"):
            col = th.diff_del_fg
        elif string_startswith(line, "@@"):
            col = th.info
        var segs = [{"text": self._expand_tabs(line, 0), "color": col, "dx": 0}]
        if len(self._diff_cache) > 3000:
            self._diff_cache = {}
        self._diff_cache[line] = segs
        return segs

    def _draw_segs(self, r, segs, x, y):
        var fh = self._code_handle
        var n = len(segs)
        var i = 0
        while i < n:
            var s = segs[i]
            var c = s["color"]
            gui_draw_text(r.handle, s["text"], x + s["dx"], y, fh, c.r, c.g, c.b, c.a)
            i = i + 1

    def _draw_sel_band(self, r, line, ln, sel, text_x, y, lh, col):
        var a = 0
        var e = len(line)
        if ln == sel[0]:
            a = sel[1]
        if ln == sel[2]:
            e = sel[3]
        var xa = self._col_x(line, a)
        var xb = self._col_x(line, e)
        var w = xb - xa
        if ln != sel[2]:
            w = w + self.char_w
        if w < 2:
            w = 2
        r.fill_xywh(text_x + xa, y, w, lh, col)

    def _draw_extra_sel_bands(self, r, line, ln, text_x, y, lh):
        var i = 1
        while i < self.selmodel.count:
            var s = self.selmodel.sels[i]
            if not s.is_empty():
                var st = s.start()
                var en = s.end()
                if ln >= st.row and ln <= en.row:
                    var a = 0
                    var e = len(line)
                    if ln == st.row:
                        a = st.col
                    if ln == en.row:
                        e = en.col
                    var xa = self._col_x(line, a)
                    var xb = self._col_x(line, e)
                    r.fill_xywh(text_x + xa, y, xb - xa, lh, self.th.selection)
            i = i + 1

    def _draw_find_marks(self, r, line, ln, text_x, y, lh):
        # find_hits is sorted by row: binary search the first hit on this row.
        var lo = 0
        var hi = self.find_n
        while lo < hi:
            var mid = int((lo + hi) / 2)
            if self.find_hits[mid][0] < ln:
                lo = mid + 1
            else:
                hi = mid
        var k = lo
        while k < self.find_n and self.find_hits[k][0] == ln:
            var h = self.find_hits[k]
            var xa = self._col_x(line, h[1])
            var xb = self._col_x(line, h[1] + h[2])
            var col = self.th.find_other
            if k == self.find_index:
                col = self.th.find_match
            r.fill_xywh(text_x + xa, y, xb - xa, lh, col)
            k = k + 1

    def _draw_whitespace(self, r, line, x, y, lh):
        var n = len(line)
        var i = 0
        var cy = y + int(lh / 2)
        while i < n:
            if string_slice(line, i, i + 1) == " ":
                r.fill_xywh(x + i * self.char_w + int(self.char_w / 2), cy, 2, 2, self.th.whitespace)
            i = i + 1

    def _draw_bracket_match(self, r, b, top, yoff, text_x):
        if self.focus != "editor":
            return
        # Cached per caret position and buffer state.
        var key_state = b.state_id()
        if self.bm_state != key_state or self.bm_row != b.cursor_row or self.bm_col != b.cursor_col or self.bm_doc != self.doc():
            self.bm_state = key_state
            self.bm_row = b.cursor_row
            self.bm_col = b.cursor_col
            self.bm_doc = self.doc()
            self.bm = self._bracket_partner()
        if self.bm == none:
            return
        var lh = self.LINE_H
        var pr = self.bm[0]
        var pc = self.bm[1]
        var sr = self.bm[2]
        var sc = self.bm[3]
        var w = self.char_w
        if pr >= top and pr < top + self._rows_visible() + 1:
            r.rect_xywh(text_x + self._col_x(b.lines[pr], pc), self.ed_y + (pr - top) * lh - yoff, w, lh, self.th.bracket, 1)
        if sr >= top and sr < top + self._rows_visible() + 1:
            r.rect_xywh(text_x + self._col_x(b.lines[sr], sc), self.ed_y + (sr - top) * lh - yoff, w, lh, self.th.bracket, 1)

    # ── welcome page ─────────────────────────────────────────────────────────
    def _draw_welcome(self, r):
        var th = self.th
        var x0 = self.ed_x
        var y0 = self.crumb_y
        var w = self.col_w
        var h = self.ed_y + self.ed_h - y0
        r.fill_xywh(x0, y0, w, h, th.editor_bg)
        var cx = x0 + int(w * 0.12)
        if cx < x0 + self.dp(40):
            cx = x0 + self.dp(40)
        var y = y0 + self.dp(48)
        r.text("Nython", cx, y, self.f_title, th.welcome_title)
        y = y + self.dp(44)
        r.text("Editing evolved", cx, y, self.f_h2, th.text_faint)
        y = y + self.dp(48)
        var col2 = cx + int(w * 0.38)
        r.text("Start", cx, y, self.f_h2, th.text)
        r.text("Recent", col2, y, self.f_h2, th.text)
        var ys = y + self.dp(34)
        ys = self._welcome_link(r, cx, ys, "new-file", "New File...", "workbench.action.files.newUntitledFile")
        ys = self._welcome_link(r, cx, ys, "go-to-file", "Open File...", "workbench.action.files.openFile")
        ys = self._welcome_link(r, cx, ys, "folder-opened", "Open Folder...", "workbench.action.files.openFolder")
        ys = self._welcome_link(r, cx, ys, "project", "New Project...", "nython.newProject")
        ys = ys + self.dp(18)
        r.text("Help", cx, ys, self.f_h2, th.text)
        ys = ys + self.dp(34)
        ys = self._welcome_link(r, cx, ys, "terminal-cmd", "Show All Commands", "workbench.action.showCommands")
        ys = self._welcome_link(r, cx, ys, "record-keys", "Keyboard Shortcuts", "workbench.action.openGlobalKeybindings")
        ys = self._welcome_link(r, cx, ys, "book", "Documentation", "workbench.action.openDocumentationUrl")
        ys = self._welcome_link(r, cx, ys, "info", "About", "nython.about")
        var yr = y + self.dp(34)
        var i = 0
        var shown = 0
        while i < len(self.recent_folders) and shown < 5:
            yr = self._welcome_recent(r, col2, yr, self.recent_folders[i], true)
            shown = shown + 1
            i = i + 1
        i = 0
        while i < len(self.recent) and shown < 10:
            yr = self._welcome_recent(r, col2, yr, self.recent[i], false)
            shown = shown + 1
            i = i + 1
        if shown == 0:
            r.text("You have no recent folders or files.", col2, yr, self.f_ui, th.text_faint)
            yr = yr + self.dp(26)
            self._welcome_link(r, col2, yr, "folder-opened", "Open a folder", "workbench.action.files.openFolder")
        elif len(self.recent) + len(self.recent_folders) > shown:
            self._welcome_link(r, col2, yr + self.dp(4), "history", "More...", "workbench.action.openRecent")

    def _welcome_link(self, r, x, y, icon, label, cmd):
        var th = self.th
        var w = self.f_ui.width(label) + self.dp(26)
        var h = self.dp(24)
        var col = th.link
        if self._hov(x, y, w, h):
            col = th.focus
            r.fill_xywh(x + self.dp(24), y + h - self.dp(4), w - self.dp(24), 1, col)
        self.icons.draw(r, icon, x, y + self.dp(4), self.dp(16), col)
        r.text(label, x + self.dp(24), y + int((h - self.ui_h) / 2), self.f_ui, col)
        self._hit(x, y, w, h, cmd, "", self.reg.keys_of(cmd))
        return y + self.dp(28)

    def _welcome_recent(self, r, x, y, path, folder):
        var th = self.th
        var name = os_path_basename(path)
        var w = self.f_ui.width(name)
        var h = self.dp(24)
        var col = th.link
        if self._hov(x, y, w + self.dp(24), h):
            col = th.focus
        self.icons.draw(r, "folder", x, y + self.dp(4), self.dp(16), col)
        if not folder:
            self.icons.draw(r, "file", x, y + self.dp(4), self.dp(16), col)
        r.text(name, x + self.dp(24), y + int((h - self.ui_h) / 2), self.f_ui, col)
        r.text(os_path_dirname(path), x + self.dp(34) + w, y + int((h - self.small_h) / 2), self.f_small, th.text_faint)
        var arg = "file:" + path
        if folder:
            arg = "dir:" + path
        self._hit(x, y, w + self.dp(34) + self.f_small.width(os_path_dirname(path)), h, "@recent", arg, path)
        return y + self.dp(26)

    # ── minimap and scrollbar ────────────────────────────────────────────────
    def _draw_minimap(self, r):
        var th = self.th
        var d = self.doc()
        var b = d.buf
        if b == none:
            return
        var x = self.col_x + self.ed_w
        var y0 = self.ed_y
        r.fill_xywh(x, y0, self.mm_w, self.ed_h, th.editor_bg)
        var cols = self._mm_colors()
        var ph = 2
        var cap = int(self.ed_h / ph)
        var n = b.line_count
        # Scroll the minimap with the editor once the file is taller than it.
        var first = 0
        if n > cap:
            var maxs = (n - 1) * self.LINE_H
            var frac = 0.0
            if maxs > 0:
                frac = d.scroll_y * 1.0 / maxs
            first = int((n - cap) * frac)
        var i = 0
        var scale = 1
        while i < cap and first + i < n:
            var code = self._mm_code(b.lines[first + i])
            var ln = (code // 4) % 4096
            var ind = code // 16384
            if ln > ind:
                var w = ln - ind
                if w > 60:
                    w = 60
                r.fill_xywh(x + self.dp(6) + ind, y0 + i * ph, w, 1, cols[code % 4])
            i = i + 1
        var top = int(d.scroll_y / self.LINE_H)
        var vis = self._rows_visible()
        var sy = y0 + (top - first) * ph
        var sh = vis * ph
        if self._hov(x, y0, self.mm_w, self.ed_h) or self.dragging == "minimap":
            r.fill_xywh(x, sy, self.mm_w, sh, self._a(th.minimap_slider, 90))
        else:
            r.fill_xywh(x, sy, self.mm_w, sh, th.minimap_slider)
        self.mm_first = first
        self._hit(x, y0, self.mm_w, self.ed_h, "@minimap", "", "")

    # One int per distinct line text - indent, length and colour class packed
    # together - so drawing the minimap allocates nothing and an edit costs
    # one new entry for the line it changed. The previous model rebuilt an
    # [indent, length, colour] list per line of the file on every keystroke.
    def _mm_code(self, line):
        if self.mm_codes.has_key(line):
            return self.mm_codes[line]
        var ind = self._line_indent(line)
        var cls = 0
        var head = string_slice(line, ind, ind + 4)
        if string_startswith(head, "#"):
            cls = 1
        elif string_startswith(head, "def ") or string_startswith(head, "clas"):
            cls = 2
        var n = len(line)
        if n > 4095:
            n = 4095
        if ind > 4095:
            ind = 4095
        var code = (ind * 4096 + n) * 4 + cls
        if self.mm_codes_n > 20000:
            self.mm_codes.clear()
            self.mm_codes_n = 0
        self.mm_codes[line] = code
        self.mm_codes_n = self.mm_codes_n + 1
        return code

    # The three minimap colours, made once per theme.
    def _mm_colors(self):
        if self.mm_cols_dark != self.th.dark or len(self.mm_cols) == 0:
            var dim = self.th.text
            self.mm_cols = [Color(dim.r, dim.g, dim.b, 110),
                            Color(self.hl.c_comment.r, self.hl.c_comment.g, self.hl.c_comment.b, 150),
                            Color(self.hl.c_storage.r, self.hl.c_storage.g, self.hl.c_storage.b, 170)]
            self.mm_cols_dark = self.th.dark
        return self.mm_cols

    def _draw_vscroll(self, r):
        var th = self.th
        var d = self.doc()
        if d.buf == none:
            return
        var x = self.col_x + self.col_w - self.vs_w
        var y0 = self.ed_y
        var total = (d.buf.line_count - 1) * self.LINE_H + self.ed_h
        if total <= self.ed_h:
            return
        var th_h = int(self.ed_h * (self.ed_h * 1.0 / total))
        if th_h < self.dp(20):
            th_h = self.dp(20)
        var maxs = total - self.ed_h
        var ty = y0 + int((self.ed_h - th_h) * (d.scroll_y * 1.0 / maxs))
        var col = th.scroll
        if self.dragging == "vscroll" or self._hov(x, ty, self.vs_w, th_h):
            col = th.scroll_hover
        r.fill_xywh(x + 3, ty, self.vs_w - 6, th_h, col)
        # Problems and find matches as overview-ruler ticks, like VS Code.
        var lines = d.buf.line_count
        if self.find_open and self.find_n > 0 and self.find_n < 800:
            var k = 0
            while k < self.find_n:
                var fy = y0 + int(self.find_hits[k][0] * 1.0 / lines * self.ed_h)
                r.fill_xywh(x + 2, fy, self.vs_w - 4, 2, th.find_other)
                k = k + 1
        self.vs_thumb_y = ty
        self.vs_thumb_h = th_h
        self._hit(x, y0, self.vs_w, self.ed_h, "@vscroll", "", "")

    # ── find widget ──────────────────────────────────────────────────────────
    def _draw_find(self, r):
        var th = self.th
        var w = self.dp(420)
        if w > self.ed_w - self.dp(40):
            w = self.ed_w - self.dp(40)
        var row_h = self.dp(33)
        var h = row_h
        if self.find_replace_mode:
            h = row_h * 2 - self.dp(4)
        var x = self.col_x + self.ed_w - w - self.dp(14)
        var y = self.ed_y
        r.shadow_xywh(x, y, w, h, 8, 0, 2, th.shadow)
        r.fill_xywh(x, y, w, h, th.widget_bg)
        r.fill_xywh(x, y, self.dp(3), h, th.widget_border)
        self._hit(x, y, w, h, "@find.bg", "", "")
        # Toggle replace
        var tg = "chevron-right"
        if self.find_replace_mode:
            tg = "chevron-down"
        self._small_button(r, x + self.dp(5), y + self.dp(6), self.dp(18), h - self.dp(12), tg, "@find.toggle", "replace", "Toggle Replace", false)
        var fx = x + self.dp(26)
        var fw = w - self.dp(26) - self.dp(160)
        var fy = y + self.dp(5)
        var fh = self.dp(24)
        self._input(r, fx, fy, fw, fh, self.find_query, "Find", self.focus == "find" and self.find_field == 0, "@find.field", 0)
        # Option toggles inside the find field: Aa  ab  .*
        var ox = fx + fw - self.dp(66)
        self._toggle(r, ox, fy + self.dp(3), "case-sensitive", self.find_case, "case", "Match Case (Alt+C)")
        self._toggle(r, ox + self.dp(22), fy + self.dp(3), "whole-word", self.find_word, "word", "Match Whole Word (Alt+W)")
        self._toggle(r, ox + self.dp(44), fy + self.dp(3), "regex", self.find_regex, "regex", "Use Regular Expression (Alt+R)")
        var info = self.find_info
        var ix = fx + fw + self.dp(8)
        var icol = th.text
        if self.find_n == 0 and self.find_query != "":
            icol = th.err
        r.text(info, ix, fy + int((fh - self.small_h) / 2), self.f_small, icol)
        var bx = x + w - self.dp(78)
        self._small_button(r, bx, fy, self.dp(22), fh, "arrow-up", "editor.action.previousMatchFindAction", "", "Previous Match (Shift+F3)", false)
        self._small_button(r, bx + self.dp(24), fy, self.dp(22), fh, "arrow-down", "editor.action.nextMatchFindAction", "", "Next Match (F3)", false)
        self._small_button(r, bx + self.dp(50), fy, self.dp(22), fh, "close", "@find.close", "", "Close (Escape)", false)
        if self.find_replace_mode:
            var ry = fy + row_h - self.dp(4)
            self._input(r, fx, ry, fw, fh, self.find_replace, "Replace", self.focus == "find" and self.find_field == 1, "@find.field", 1)
            self._small_button(r, fx + fw + self.dp(6), ry, self.dp(22), fh, "replace", "@find.replace", "", "Replace (Ctrl+Shift+1)", false)
            self._small_button(r, fx + fw + self.dp(30), ry, self.dp(22), fh, "replace-all", "@find.replaceall", "", "Replace All (Ctrl+Alt+Enter)", false)

    # Word-wrapped text. Wrapping is measured once per (text, width) and
    # cached by the text itself, so a repaint allocates nothing.
    def _wrapped(self, text, font, w):
        if self.wrap_cache.has_key(text):
            var c = self.wrap_cache[text]
            if c[0] == w:
                return c[1]
        var words = string_split(text, " ")
        var lines = []
        var cur = ""
        var i = 0
        while i < len(words):
            var cand = words[i]
            if cur != "":
                cand = cur + " " + words[i]
            if cur != "" and font.width(cand) > w:
                lines.append(cur)
                cur = words[i]
            else:
                cur = cand
            i = i + 1
        if cur != "":
            lines.append(cur)
        if len(self.wrap_cache) > 200:
            self.wrap_cache = {}
        self.wrap_cache[text] = [w, lines]
        return lines

    def _draw_wrapped(self, r, text, x, y, w, font, col, lh):
        var ls = self._wrapped(text, font, w)
        var i = 0
        while i < len(ls):
            r.text(ls[i], x, y + i * lh, font, col)
            i = i + 1
        return y + len(ls) * lh

    def _qi_item_marks(self, it, qi):
        it.pos_q = qi.value
        it.pos_x = []
        it.pos_ch = []
        var q = qi.query()
        if q == "" or qi.kind == "prompt" or qi.kind == "line":
            return
        var ps = fuzzy_positions(q, it.label)
        if ps == none:
            return
        var i = 0
        while i < len(ps):
            it.pos_x.append(self.f_ui.width(string_slice(it.label, 0, ps[i])))
            it.pos_ch.append(string_slice(it.label, ps[i], ps[i] + 1))
            i = i + 1

    def _field_of(self, cmd, arg):
        if cmd == "@qi.input":
            return "qi"
        if cmd == "@find.field":
            return "find" + str(arg)
        if cmd == "@search.field":
            return "search" + str(arg)
        if cmd == "@scm.msg":
            return "scm"
        if cmd == "@ext.search":
            return "ext"
        return ""

    def _input(self, r, x, y, w, h, value, placeholder, focused, cmd, arg):
        var th = self.th
        var name = self._field_of(cmd, arg)
        r.fill_xywh(x, y, w, h, th.input_bg)
        if focused:
            r.rect_xywh(x, y, w, h, th.focus, 1)
        var ty = y + int((h - self.ui_h) / 2)
        r.clip_xywh(x + 2, y, w - 4, h)
        var vx = x + self.dp(6)
        if value == "":
            r.text(placeholder, vx, ty, self.f_ui, th.placeholder)
            if focused and self.caret_on:
                r.fill_xywh(vx, y + self.dp(4), 1, h - self.dp(8), th.input_fg)
        else:
            var le = self._le(name)
            le.sync(value)
            var cw = self.f_ui.width(string_slice(value, 0, le.caret))
            # Keep the caret in view when the value is wider than the box.
            if cw > w - self.dp(40):
                vx = x + w - self.dp(40) - cw
            if focused and le.has_sel():
                var sx = vx + self.f_ui.width(string_slice(value, 0, le.lo()))
                var sw = self.f_ui.width(string_slice(value, le.lo(), le.hi()))
                r.fill_xywh(sx, y + self.dp(3), sw, h - self.dp(6), th.selection)
            r.text(value, vx, ty, self.f_ui, th.input_fg)
            if focused and self.caret_on:
                r.fill_xywh(vx + cw, y + self.dp(4), 1, h - self.dp(8), th.input_fg)
        self.field_vx[name] = vx
        r.clear_clip()
        self._hit(x, y, w, h, cmd, arg, "")

    # A prompt line in a panel (terminal, Debug Console) with caret and
    # selection from its LineEdit.
    def _prompt_line(self, r, name, value, px, yy, lh, focused):
        var th = self.th
        var le = self._le(name)
        le.sync(value)
        var f = self.f_mono_small
        if focused and le.has_sel():
            r.fill_xywh(px + f.width(string_slice(value, 0, le.lo())), yy, f.width(string_slice(value, le.lo(), le.hi())), lh - 2, th.selection)
        r.text(value, px, yy, f, th.text)
        if focused and self.caret_on:
            var cx = px + f.width(string_slice(value, 0, le.caret))
            if le.caret < len(value):
                r.fill_xywh(cx, yy, 2, lh - 2, self._a(th.text, 200))
            else:
                r.fill_xywh(cx, yy, self.dp(7), lh - 2, self._a(th.text, 180))
        self.field_vx[name] = px

    def _toggle(self, r, x, y, icon, on, key, tip):
        var th = self.th
        var s = self.dp(20)
        if on:
            r.fill_round_xywh(x, y, s, s, self._a(th.accent, 90), self.dp(3))
            r.round_rect_xywh(x, y, s, s, th.accent, self.dp(3), 1)
        elif self._hov(x, y, s, s):
            r.fill_round_xywh(x, y, s, s, self._a(th.text, 30), self.dp(3))
        self.icons.draw(r, icon, x + self.dp(2), y + self.dp(2), self.dp(16), th.text)
        self._hit(x, y, s, s, "@find.toggle", key, tip)

    def _small_button(self, r, x, y, w, h, icon, cmd, arg, tip, on):
        var th = self.th
        if on:
            r.fill_round_xywh(x, y, w, h, self._a(th.accent, 90), self.dp(3))
        elif self._hov(x, y, w, h):
            r.fill_round_xywh(x, y, w, h, self._a(th.text, 30), self.dp(3))
        var s = self.dp(16)
        self.icons.draw(r, icon, x + int((w - s) / 2), y + int((h - s) / 2), s, th.text)
        self._hit(x, y, w, h, cmd, arg, tip)

    def _button(self, r, x, y, w, h, label, cmd, arg, primary):
        var th = self.th
        var bg = th.button2_bg
        if primary:
            bg = th.button_bg
            if self._hov(x, y, w, h):
                bg = th.button_hover
        elif self._hov(x, y, w, h):
            bg = self._a(th.button2_bg, 200)
        r.fill_round_xywh(x, y, w, h, bg, self.dp(2))
        var lw = self.f_ui.width(label)
        r.text(label, x + int((w - lw) / 2), y + int((h - self.ui_h) / 2), self.f_ui, th.button_fg)
        self._hit(x, y, w, h, cmd, arg, "")

    # ── panel ────────────────────────────────────────────────────────────────
    def _draw_panel(self, r):
        var th = self.th
        var x = self.col_x
        var y = self.panel_y
        var w = self.col_w
        var h = self.panel_h
        r.fill_xywh(x, y, w, h, th.panel_bg)
        r.fill_xywh(x, y, w, 1, th.panel_border)
        self._hit(x, y - self.dp(3), w, self.dp(6), "@split.panel", "", "")
        var tx = x + self.dp(12)
        var hh = self.PANEL_HEAD
        # Tabs that do not fit before the action buttons go to a "..." menu;
        # the active tab always stays visible (it takes the last slot).
        var nbtn = 2
        if self.active_panel == "output" or self.active_panel == "terminal" or self.active_panel == "debug" or self.active_panel == "inspector" or self.active_panel == "buildlog":
            nbtn = 3
        if self.active_panel == "output" and self.job_running:
            nbtn = 4
        var limit = x + w - self.dp(34) - self.dp(28) * (nbtn - 1) - self.dp(6)
        var n = len(self.panel_keys)
        var ai = 0
        var fit = 0
        var need = tx
        var i = 0
        while i < n:
            if self.panel_keys[i] == self.active_panel:
                ai = i
            i = i + 1
        i = 0
        while i < n:
            var tw0 = self._panel_tab_w(i)
            var room = limit
            if i < n - 1:
                room = limit - self.dp(30)
            if need + tw0 > room:
                i = n
            else:
                need = need + tw0
                fit = fit + 1
                i = i + 1
        if fit < 1:
            fit = 1
        self.panel_fit = fit
        self.panel_ai = ai
        i = 0
        while i < n:
            if not self._panel_tab_shown(i):
                i = i + 1
                continue
            var key = self.panel_keys[i]
            var label = self.panel_labels[i]
            var lw = self.f_tab.width(label)
            var tw = self._panel_tab_w(i)
            var badge = 0
            if key == "problems":
                badge = self.n_errors + self.n_warnings
            var active = self.active_panel == key
            var col = th.panel_title_dim
            if active or self._hov(tx, y, tw, hh):
                col = th.panel_title
            r.text(label, tx + self.dp(10), y + int((hh - self.tab_h) / 2), self.f_tab, col)
            if badge > 0:
                var bs = self._num(badge)
                var bw = self.f_tiny.width(bs) + self.dp(10)
                var bx = tx + self.dp(14) + lw
                r.fill_round_xywh(bx, y + int((hh - self.dp(16)) / 2), bw, self.dp(16), th.badge_bg, self.dp(8))
                r.text(bs, bx + self.dp(5), y + int((hh - self.dp(16)) / 2) + self.dp(1), self.f_tiny, th.badge_fg)
            if active:
                r.fill_xywh(tx + self.dp(10), y + hh - self.dp(4), tw - self.dp(20), 1, th.panel_title)
            self._hit(tx, y, tw, hh, "@panel.tab", key, "")
            tx = tx + tw
            i = i + 1
        if fit < n:
            self._small_button(r, tx + self.dp(2), y + self.dp(6), self.dp(26), hh - self.dp(12), "ellipsis", "@panel.more", "", "More Panels", false)
        # Panel actions: Clear, Maximize/Restore, Close.
        var ax = x + w - self.dp(34)
        self._small_button(r, ax, y + self.dp(6), self.dp(26), hh - self.dp(12), "close", "workbench.action.togglePanel", "", "Hide Panel (Ctrl+J)", false)
        var mx_icon = "chevron-up"
        var mx_tip = "Maximize Panel Size"
        if self.panel_max:
            mx_icon = "chevron-down"
            mx_tip = "Restore Panel Size"
        self._small_button(r, ax - self.dp(28), y + self.dp(6), self.dp(26), hh - self.dp(12), mx_icon, "workbench.action.toggleMaximizedPanel", "", mx_tip, false)
        if self.active_panel == "output" or self.active_panel == "terminal" or self.active_panel == "debug" or self.active_panel == "inspector" or self.active_panel == "buildlog":
            self._small_button(r, ax - self.dp(56), y + self.dp(6), self.dp(26), hh - self.dp(12), "clear-all", "workbench.action.terminal.clear", "", "Clear", false)
        if self.active_panel == "output" and self.job_running:
            self._small_button(r, ax - self.dp(84), y + self.dp(6), self.dp(26), hh - self.dp(12), "debug-stop", "@job.stop", "", "Stop the running program (Shift+F5)", false)
        var by = y + hh
        var bh = h - hh
        r.clip_xywh(x, by, w, bh)
        var ap = self.active_panel
        if ap == "problems":
            self._draw_problems(r, x, by, w, bh)
        elif ap == "output":
            self._draw_lines(r, x, by, w, bh, self.out_lines, self.out_kinds, "output", "No output yet. Run a file with Ctrl+F5 to see its output here.")
        elif ap == "terminal":
            self._draw_terminal(r, x, by, w, bh)
        elif ap == "debug":
            self._draw_dbg_console(r, x, by, w, bh)
        elif ap == "inspector":
            self._draw_inspector(r, x, by, w, bh)
        elif ap == "buildlog":
            self._draw_lines(r, x, by, w, bh, self.build_lines, self.build_kinds, "buildlog", "No build output yet. Build with " + self._or_none(self.reg.keys_of("nython.build")) + ".")
        elif ap == "todo":
            self._draw_todo(r, x, by, w, bh)
        elif ap == "workshop":
            self.workshop.draw(r)
            self._hit(x, by, w, bh, "@workshop", "", "")
        r.clear_clip()

    def _panel_tab_w(self, i):
        var tw = self.f_tab.width(self.panel_labels[i]) + self.dp(20)
        if self.panel_keys[i] == "problems" and self.n_errors + self.n_warnings > 0:
            tw = tw + self.dp(22)
        return tw

    # Which panel tabs the strip shows (see _draw_panel): the first
    # panel_fit, except that an active tab beyond them takes the last slot.
    def _panel_tab_shown(self, i):
        var fit = self.panel_fit
        if fit >= len(self.panel_keys):
            return true
        if self.panel_ai < fit:
            return i < fit
        return i < fit - 1 or i == self.panel_ai

    def _kind_color(self, kind):
        var th = self.th
        if kind == "err":
            return th.err
        if kind == "ok":
            return th.ok
        if kind == "warn":
            return th.warn
        if kind == "info" or kind == "cmd":
            return th.info
        if kind == "dim":
            return th.text_faint
        return th.text

    # A scrolling list of lines. Follows the tail while new output arrives
    # unless the user has scrolled up, as VS Code's output channel does.
    def _draw_lines(self, r, x, y, w, h, lines, kinds, which, empty_msg):
        var th = self.th
        var lh = self.dp(18)
        var rows = int((h - self.dp(8)) / lh)
        var n = len(lines)
        if n == 0:
            r.text(empty_msg, x + self.dp(16), y + self.dp(10), self.f_ui, th.text_faint)
            self._hit(x, y, w, h, "@panel.body", which, "")
            return
        var first = self.panel_scroll
        if self.out_follow and which == "output":
            first = n - rows
        if first > n - rows:
            first = n - rows
        if first < 0:
            first = 0
        self.panel_scroll = first
        var i = 0
        while i < rows and first + i < n:
            var k = kinds[first + i]
            r.text(lines[first + i], x + self.dp(16), y + self.dp(6) + i * lh, self.f_mono_small, self._kind_color(k))
            i = i + 1
        self._hit(x, y, w, h, "@panel.body", which, "")

    def _draw_terminal(self, r, x, y, w, h):
        var th = self.th
        var lh = self.dp(18)
        var rows = int((h - self.dp(8)) / lh) - 1
        var n = len(self.term_lines)
        var first = self.panel_scroll
        if self.term_follow:
            first = n - rows
        if first > n - rows:
            first = n - rows
        if first < 0:
            first = 0
        self.panel_scroll = first
        var i = 0
        var yy = y + self.dp(6)
        while i < rows and first + i < n:
            r.text(self.term_lines[first + i], x + self.dp(16), yy, self.f_mono_small, self._kind_color(self.term_kinds[first + i]))
            yy = yy + lh
            i = i + 1
        var prompt = self.term_prompt
        r.text(prompt, x + self.dp(16), yy, self.f_mono_small, th.ok)
        var px = x + self.dp(16) + self.f_mono_small.width(prompt) + self.dp(6)
        self._prompt_line(r, "term", self.term_input, px, yy, lh, self.focus == "terminal")
        self.term_input_y = yy - self.dp(2)
        self._hit(x, y, w, h, "@term", "", "")

    def _draw_dbg_console(self, r, x, y, w, h):
        var th = self.th
        var lh = self.dp(18)
        var rows = int((h - self.dp(8)) / lh) - 1
        var n = len(self.dbgcon_lines)
        var first = n - rows
        if first < 0:
            first = 0
        var i = 0
        var yy = y + self.dp(6)
        if n == 0:
            var msg = "Start debugging (F5), then evaluate expressions here against the paused program's variables."
            r.text(msg, x + self.dp(16), yy, self.f_ui, th.text_faint)
            yy = yy + lh + self.dp(4)
        while i < rows and first + i < n:
            r.text(self.dbgcon_lines[first + i], x + self.dp(16), yy, self.f_mono_small, self._kind_color(self.dbgcon_kinds[first + i]))
            yy = yy + lh
            i = i + 1
        r.text(">", x + self.dp(16), yy, self.f_mono_small, th.info)
        self._prompt_line(r, "dbgcon", self.dbgcon_input, x + self.dp(30), yy, lh, self.focus == "dbgconsole")
        self.dbgcon_input_y = yy - self.dp(2)
        self._hit(x, y, w, h, "@dbgcon", "", "")

    def _draw_inspector(self, r, x, y, w, h):
        var th = self.th
        if len(self.inspect_lines) == 0:
            r.text("Run > Show Tokens / Show AST / Show Bytecode fills this view with what the compiler produced.", x + self.dp(16), y + self.dp(10), self.f_ui, th.text_faint)
            self._hit(x, y, w, h, "@panel.body", "inspector", "")
            return
        r.text(self.inspect_kind + "  -  " + self._num(len(self.inspect_lines)) + " lines", x + self.dp(16), y + self.dp(6), self.f_ui_bold, th.text)
        var lh = self.dp(17)
        var rows = int((h - self.dp(34)) / lh)
        var n = len(self.inspect_lines)
        var first = self.panel_scroll
        if first > n - rows:
            first = n - rows
        if first < 0:
            first = 0
        self.panel_scroll = first
        var i = 0
        while i < rows and first + i < n:
            r.text(self.inspect_lines[first + i], x + self.dp(16), y + self.dp(28) + i * lh, self.f_mono_small, th.text_dim)
            i = i + 1
        self._hit(x, y, w, h, "@panel.body", "inspector", "")

    # Problems grouped by file, VS Code style. The display rows are rebuilt
    # only when the problem list changes.
    def _problem_rows(self):
        if self.prob_rows_src == self.problems and self.prob_rows_collapsed_n == len(self.prob_collapsed):
            return self.prob_rows
        var rows = []
        var files = []
        var i = 0
        while i < len(self.problems):
            var p = self.problems[i]
            var seen = false
            var k = 0
            while k < len(files):
                if files[k] == p["path"]:
                    seen = true
                k = k + 1
            if not seen:
                files.append(p["path"])
            i = i + 1
        var f = 0
        while f < len(files):
            var path = files[f]
            var cnt = 0
            var j = 0
            while j < len(self.problems):
                if self.problems[j]["path"] == path:
                    cnt = cnt + 1
                j = j + 1
            rows.append([-1, path, cnt])
            if not self.prob_collapsed.has_key(path):
                j = 0
                while j < len(self.problems):
                    if self.problems[j]["path"] == path:
                        rows.append([j, path, 0])
                    j = j + 1
            f = f + 1
        self.prob_rows = rows
        self.prob_rows_src = self.problems
        self.prob_rows_collapsed_n = len(self.prob_collapsed)
        return rows

    def _draw_problems(self, r, x, y, w, h):
        var th = self.th
        if len(self.problems) == 0:
            r.text("No problems have been detected in the workspace.", x + self.dp(16), y + self.dp(10), self.f_ui, th.text_faint)
            self._hit(x, y, w, h, "@panel.body", "problems", "")
            return
        var rows = self._problem_rows()
        var lh = self.ROW_H
        var vis = int(h / lh)
        var first = self.panel_scroll
        if first > len(rows) - vis:
            first = len(rows) - vis
        if first < 0:
            first = 0
        self.panel_scroll = first
        self._hit(x, y, w, h, "@panel.body", "problems", "")
        var i = 0
        while i < vis and first + i < len(rows):
            var row = rows[first + i]
            var yy = y + i * lh
            var hov = self._hov(x, yy, w, lh)
            if hov:
                r.fill_xywh(x, yy, w, lh, th.hover)
            var ty = yy + int((lh - self.ui_h) / 2)
            if row[0] < 0:
                var chev = "chevron-down"
                if self.prob_collapsed.has_key(row[1]):
                    chev = "chevron-right"
                self.icons.draw(r, chev, x + self.dp(8), yy + self.dp(3), self.dp(16), th.text)
                self.icons.draw(r, "file-code", x + self.dp(26), yy + self.dp(3), self.dp(16), th.file_ny)
                var fname = os_path_basename(row[1])
                r.text(fname, x + self.dp(46), ty, self.f_ui, th.text)
                var fw = self.f_ui.width(fname)
                r.text(self._rel(os_path_dirname(row[1])), x + self.dp(54) + fw, ty, self.f_small, th.text_faint)
                var cs = self._num(row[2])
                r.fill_round_xywh(x + w - self.dp(40), yy + self.dp(3), self.dp(22), self.dp(16), th.badge_bg, self.dp(8))
                r.text(cs, x + w - self.dp(40) + int((self.dp(22) - self.f_tiny.width(cs)) / 2), yy + self.dp(4), self.f_tiny, th.badge_fg)
                self._hit(x, yy, w, lh, "@problem.file", row[1], "")
            else:
                var p = self.problems[row[0]]
                var icon = "error"
                var col = th.err
                if p["sev"] == "warn":
                    icon = "warning"
                    col = th.warn
                elif p["sev"] == "info":
                    icon = "info"
                    col = th.info
                self.icons.draw(r, icon, x + self.dp(34), yy + self.dp(3), self.dp(16), col)
                r.text(p["msg"], x + self.dp(56), ty, self.f_ui, th.text)
                var loc = p["src"] + "  [Ln " + str(p["line"]) + ", Col " + str(p["col"]) + "]"
                r.text(loc, x + self.dp(64) + self.f_ui.width(p["msg"]), ty, self.f_small, th.text_faint)
                self._hit(x, yy, w, lh, "@problem", row[0], "")
            i = i + 1

    # ── status bar ───────────────────────────────────────────────────────────
    # Every item is clickable and does what VS Code's does. Three segments
    # (UTF-8, Nython, the window size) used to be inert labels that swallowed
    # the click, which read as a broken UI (HANDOFF 5.7).
    def _draw_statusbar(self, r):
        var th = self.th
        var y = self.status_y
        var h = self.STATUS_H
        var bg = th.status_bg
        if self.dbg.active:
            bg = th.status_dbg
        elif self.ws.root == "":
            bg = th.status_nofolder
        r.fill_xywh(0, y, self.W, h, bg)
        self._status_refresh()
        var ty = y + int((h - self.small_h) / 2)
        var x = self.dp(8)
        # Left: branch, problems, running program, transient message.
        if self.scm_branch != "":
            x = self._status_item(r, x, y, h, "source-control", self.st_branch, "git.checkout", "", "Checkout Branch/Tag...")
        x = self._status_item(r, x, y, h, "error", self.st_errors, "workbench.actions.view.problems", "", "Problems (Ctrl+Shift+M)")
        x = x - self.dp(6)
        x = self._status_item(r, x, y, h, "warning", self.st_warnings, "workbench.actions.view.problems", "", "Problems (Ctrl+Shift+M)")
        if self.ws.root != "" and self.W > self.dp(640):
            x = self._status_item(r, x, y, h, "tools", self._status_target(), "@status.target", "", "Build target (Build > Select Target)")
        if self.build_running:
            x = self._status_item(r, x, y, h, "loading", "Building", "nython.abort", "", "Click to abort the build")
        if self.job_running:
            x = self._status_item(r, x, y, h, "loading", self.st_job, "@job.stop", "", "Click to stop the running program")
        if self.dbg.active:
            x = self._status_item(r, x, y, h, "debug-alt", self.st_debug, "workbench.view.debug", "", "Run and Debug")
        # Right side, laid out right-to-left. Items that do not fit beside the
        # left group drop out lowest-priority first: encoding, line endings,
        # language, indentation; the cursor position goes last.
        var rx = self.W - self.dp(8)
        rx = self._status_item_r(r, rx, y, h, "bell", "", "notifications.showList", "", "Notifications")
        if self.notes.unread > 0:
            r.fill_circle(rx + self.dp(21), y + self.dp(6), self.dp(3), th.status_fg)
        if self._is_text():
            var w_lang = self._status_w("", self.st_lang)
            var w_eol = self._status_w("", self.st_eol)
            var w_enc = self._status_w("", self.st_enc)
            var w_ind = self._status_w("", self.st_indent)
            var w_pos = self._status_w("", self.st_pos)
            var avail = rx - x - self.dp(12)
            var total = w_lang + w_eol + w_enc + w_ind + w_pos
            var s_enc = true
            var s_eol = true
            var s_lang = true
            var s_ind = true
            var s_pos = true
            if total > avail:
                s_enc = false
                total = total - w_enc
            if total > avail:
                s_eol = false
                total = total - w_eol
            if total > avail:
                s_lang = false
                total = total - w_lang
            if total > avail:
                s_ind = false
                total = total - w_ind
            if total > avail:
                s_pos = false
            if s_lang:
                rx = self._status_item_r(r, rx, y, h, "", self.st_lang, "workbench.action.editor.changeLanguageMode", "", "Select Language Mode")
            if s_eol:
                rx = self._status_item_r(r, rx, y, h, "", self.st_eol, "workbench.action.editor.changeEOL", "", "Select End of Line Sequence")
            if s_enc:
                rx = self._status_item_r(r, rx, y, h, "", self.st_enc, "workbench.action.editor.changeEncoding", "", "Select Encoding")
            if s_ind:
                rx = self._status_item_r(r, rx, y, h, "", self.st_indent, "changeEditorIndentation", "", "Select Indentation")
            if s_pos:
                rx = self._status_item_r(r, rx, y, h, "", self.st_pos, "workbench.action.gotoLine", "", "Go to Line/Column (Ctrl+G)")
            if self.overwrite:
                rx = self._status_item_r(r, rx, y, h, "", "OVR", "@status.ovr", "", "Overwrite mode (Insert toggles)")
        # The transient message fits in whatever is left between the groups.
        if self.status_msg != "" and time_ms() - self.status_t < 8000 and rx - x > self.dp(40):
            r.clip_xywh(x, y, rx - x - self.dp(4), h)
            r.text(self.status_msg, x + self.dp(8), ty, self.f_small, self._a(th.status_fg, 200))
            r.clear_clip()

    def _status_item(self, r, x, y, h, icon, label, cmd, arg, tip):
        var th = self.th
        var w = self.dp(10)
        if icon != "":
            w = w + self.dp(16)
        if label != "":
            w = w + self.f_small.width(label) + self.dp(4)
        if self._hov(x, y, w, h):
            r.fill_xywh(x, y, w, h, th.status_hover)
        var cx = x + self.dp(5)
        if icon != "":
            self.icons.draw(r, icon, cx, y + int((h - self.dp(14)) / 2), self.dp(14), th.status_fg)
            cx = cx + self.dp(18)
        if label != "":
            r.text(label, cx, y + int((h - self.small_h) / 2), self.f_small, th.status_fg)
        self._hit(x, y, w, h, cmd, arg, tip)
        return x + w

    def _status_w(self, icon, label):
        var w = self.dp(10)
        if icon != "":
            w = w + self.dp(16)
        if label != "":
            w = w + self.f_small.width(label) + self.dp(4)
        return w

    def _status_item_r(self, r, right, y, h, icon, label, cmd, arg, tip):
        var w = self.dp(10)
        if icon != "":
            w = w + self.dp(16)
        if label != "":
            w = w + self.f_small.width(label) + self.dp(4)
        self._status_item(r, right - w, y, h, icon, label, cmd, arg, tip)
        return right - w

    # Status strings, rebuilt only when what they show changes.
    def _status_refresh(self):
        var b = none
        var row = -1
        var col = -1
        var nsel = 0
        if self._is_text():
            b = self.buf()
            row = b.cursor_row
            col = b.cursor_col
            var g = self._sel_range()
            if g != none:
                nsel = len(b.text_range(g[0], g[1], g[2], g[3]))
        var key_same = self.st_k_row == row and self.st_k_col == col and self.st_k_sel == nsel
        key_same = key_same and self.st_k_err == self.n_errors and self.st_k_warn == self.n_warnings
        key_same = key_same and self.st_k_doc == self.doc() and self.st_k_tab == self.tab_size and self.st_k_spaces == self.insert_spaces
        key_same = key_same and self.st_k_branch == self.scm_branch and self.st_k_dirtyrepo == self.scm_count
        key_same = key_same and self.st_k_dbg == self.dbg_line_row and self.st_k_job == self.job_running
        if key_same and b != none and self.st_k_eol == b.eol and self.st_k_bom == self.doc().bom and self.st_k_lang == self.doc().lang:
            return
        self.st_k_row = row
        self.st_k_col = col
        self.st_k_sel = nsel
        self.st_k_err = self.n_errors
        self.st_k_warn = self.n_warnings
        self.st_k_doc = self.doc()
        self.st_k_tab = self.tab_size
        self.st_k_spaces = self.insert_spaces
        self.st_k_branch = self.scm_branch
        self.st_k_dirtyrepo = self.scm_count
        self.st_k_dbg = self.dbg_line_row
        self.st_k_job = self.job_running
        self.st_errors = str(self.n_errors)
        self.st_warnings = str(self.n_warnings)
        self.st_branch = self.scm_branch
        if self.scm_count > 0:
            self.st_branch = self.scm_branch + "*"
        self.st_job = "Running " + os_path_basename(self.job_path)
        self.st_debug = "Debugging"
        if b != none:
            self.st_k_eol = b.eol
            self.st_k_bom = self.doc().bom
            self.st_k_lang = self.doc().lang
            self.st_pos = "Ln " + str(row + 1) + ", Col " + str(col + 1)
            if nsel > 0:
                self.st_pos = self.st_pos + " (" + str(nsel) + " selected)"
            self.st_indent = "Spaces: " + str(self.tab_size)
            if not self.insert_spaces:
                self.st_indent = "Tab Size: " + str(self.tab_size)
            self.st_enc = "UTF-8"
            if self.doc().bom:
                self.st_enc = "UTF-8 with BOM"
            self.st_eol = "LF"
            if b.eol == "\r\n":
                self.st_eol = "CRLF"
            self.st_lang = "Nython"
            if self.doc().lang == "plaintext":
                self.st_lang = "Plain Text"
            elif self.doc().lang == "markdown":
                self.st_lang = "Markdown"

    # ── floating debug toolbar ───────────────────────────────────────────────
    def _draw_debug_toolbar(self, r):
        var th = self.th
        var bw = self.dp(28)
        var n = 7
        var w = bw * n + self.dp(16)
        var h = self.dp(30)
        var x = self.col_x + int((self.col_w - w) / 2)
        var y = self.content_y + self.dp(2)
        r.shadow_xywh(x, y, w, h, 8, 0, 2, th.shadow)
        r.fill_round_xywh(x, y, w, h, th.debug_bg, self.dp(4))
        r.fill_xywh(x + self.dp(4), y + self.dp(8), self.dp(4), h - self.dp(16), self._a(th.text, 60))
        var bx = x + self.dp(12)
        self._dbg_button(r, bx, y, bw, h, "debug-continue", "workbench.action.debug.continue", "Continue (F5)", th.info)
        self._dbg_button(r, bx + bw, y, bw, h, "debug-step-over", "workbench.action.debug.stepOver", "Step Over (F10)", th.info)
        self._dbg_button(r, bx + bw * 2, y, bw, h, "debug-step-into", "workbench.action.debug.stepInto", "Step Into (F11)", th.info)
        self._dbg_button(r, bx + bw * 3, y, bw, h, "debug-step-out", "workbench.action.debug.stepOut", "Step Out (Shift+F11)", th.info)
        self._dbg_button(r, bx + bw * 4, y, bw, h, "debug-step-back", "workbench.action.debug.stepBack", "Step Back (Ctrl+Shift+F11)", th.info)
        self._dbg_button(r, bx + bw * 5, y, bw, h, "debug-restart", "workbench.action.debug.restart", "Restart (Ctrl+Shift+F5)", th.ok)
        self._dbg_button(r, bx + bw * 6, y, bw, h, "debug-stop", "workbench.action.debug.stop", "Stop (Shift+F5)", th.err)

    def _dbg_button(self, r, x, y, w, h, icon, cmd, tip, col):
        if self._hov(x, y, w, h):
            r.fill_round_xywh(x + 2, y + self.dp(4), w - 4, h - self.dp(8), self._a(self.th.text, 40), self.dp(4))
        self.icons.draw(r, icon, x + int((w - self.dp(16)) / 2), y + int((h - self.dp(16)) / 2), self.dp(16), col)
        self._hit(x, y, w, h, cmd, "", tip)

    # ══ overlays ═══════════════════════════════════════════════════════════════
    # A transparent full-window region under each overlay: a click outside the
    # overlay dismisses it and goes nowhere else.
    def _scrim_hit(self, cmd):
        self._hit(0, 0, self.W, self.H, cmd, "", "")

    def _menu_item_h(self):
        return self.dp(24)

    def _draw_dropdown(self, r):
        var th = self.th
        self._scrim_hit("@overlay.dismiss")
        # The menu bar stays live above the dismiss layer: moving along it
        # switches menus and clicking the open one closes it, as in VS Code.
        var mi = 0
        if self.menu_compact:
            self._hit(self.menu_x[0], 0, self.dp(30), self.TITLE_H, "@menu", len(self.menus), "")
        else:
            while mi < len(self.menus):
                self._hit(self.menu_x[mi], 0, self.f_ui.width(self.menus[mi]) + self.dp(16), self.TITLE_H, "@menu", mi, "")
                mi = mi + 1
        var ih = self._menu_item_h()
        if self.menu_open >= len(self.menus):
            self._draw_menu_list(r, ih)
            return
        var items = self.menu_items[self.menus[self.menu_open]]
        var x = self.menu_x[self.menu_open]
        var y = self.TITLE_H
        var w = self.dp(300)
        var h = self.dp(8)
        if self.menu_compact:
            h = h + ih + self.dp(9)
        var i = 0
        while i < len(items):
            if items[i] == "-":
                h = h + self.dp(9)
            else:
                h = h + ih
            i = i + 1
        if y + h > self.H - self.dp(4):
            # Short window: the menu starts higher rather than running off
            # the bottom (it may then cover the title bar).
            y = self.H - self.dp(4) - h
            if y < 0:
                y = 0
        if x + w > self.W - 4:
            x = self.W - w - 4
        r.shadow_xywh(x, y, w, h, 12, 0, 4, th.shadow)
        r.fill_round_xywh(x, y, w, h, th.menu_bg, self.dp(5))
        r.round_rect_xywh(x, y, w, h, th.menu_border, self.dp(5), 1)
        self._hit(x, y, w, h, "@menu.bg", "", "")
        var yy = y + self.dp(4)
        if self.menu_compact:
            # Back to the list of menus.
            var bsel = self._hov(x, yy, w, ih)
            if bsel:
                r.fill_round_xywh(x + self.dp(4), yy, w - self.dp(8), ih, th.menu_sel, self.dp(3))
            self.icons.draw(r, "chevron-left", x + self.dp(8), yy + int((ih - self.dp(14)) / 2), self.dp(14), th.text_dim)
            r.text(self.menus[self.menu_open], x + self.dp(26), yy + int((ih - self.ui_h) / 2), self.f_ui, th.text_dim)
            self._hit(x, yy, w, ih, "@menu.pick", len(self.menus), "All menus")
            yy = yy + ih
            r.fill_xywh(x + self.dp(10), yy + self.dp(4), w - self.dp(20), 1, th.menu_border)
            yy = yy + self.dp(9)
        i = 0
        while i < len(items):
            var id = items[i]
            if id == "-":
                r.fill_xywh(x + self.dp(10), yy + self.dp(4), w - self.dp(20), 1, th.menu_border)
                yy = yy + self.dp(9)
            else:
                var enabled = self._command_enabled(id)
                var sel = self.menu_sel == i or (self.menu_sel < 0 and self._hov(x, yy, w, ih))
                var fg = th.text
                if sel and enabled:
                    r.fill_round_xywh(x + self.dp(4), yy, w - self.dp(8), ih, th.menu_sel, self.dp(3))
                    fg = th.text_hi
                if not enabled:
                    fg = th.text_faint
                r.text(self.reg.title(id), x + self.dp(26), yy + int((ih - self.ui_h) / 2), self.f_ui, fg)
                var keys = self.reg.keys_of(id)
                if keys != "":
                    var kw = self.f_small.width(keys)
                    r.text(keys, x + w - self.dp(16) - kw, yy + int((ih - self.small_h) / 2), self.f_small, th.text_faint)
                if enabled:
                    self._hit(x, yy, w, ih, "@menuitem", id, "")
                else:
                    self._hit(x, yy, w, ih, "@menu.bg", "", "")
                yy = yy + ih
            i = i + 1

    # The hamburger's list: one row per menu; choosing one opens it in place.
    def _draw_menu_list(self, r, ih):
        var th = self.th
        var x = self.menu_x[0]
        var y = self.TITLE_H
        var w = self.dp(220)
        var h = self.dp(8) + ih * len(self.menus)
        r.shadow_xywh(x, y, w, h, 12, 0, 4, th.shadow)
        r.fill_round_xywh(x, y, w, h, th.menu_bg, self.dp(5))
        r.round_rect_xywh(x, y, w, h, th.menu_border, self.dp(5), 1)
        self._hit(x, y, w, h, "@menu.bg", "", "")
        var yy = y + self.dp(4)
        var i = 0
        while i < len(self.menus):
            var sel = self.menu_sel == i or (self.menu_sel < 0 and self._hov(x, yy, w, ih))
            var fg = th.text
            if sel:
                r.fill_round_xywh(x + self.dp(4), yy, w - self.dp(8), ih, th.menu_sel, self.dp(3))
                fg = th.text_hi
            r.text(self.menus[i], x + self.dp(26), yy + int((ih - self.ui_h) / 2), self.f_ui, fg)
            self.icons.draw(r, "chevron-right", x + w - self.dp(24), yy + int((ih - self.dp(14)) / 2), self.dp(14), th.text_faint)
            self._hit(x, yy, w, ih, "@menu.pick", i, "")
            yy = yy + ih
            i = i + 1

    def _draw_ctx(self, r):
        var th = self.th
        self._scrim_hit("@overlay.dismiss")
        var ih = self._menu_item_h()
        var w = self.dp(260)
        var h = self.dp(8)
        var i = 0
        while i < len(self.ctx_items):
            if self.ctx_items[i][0] == "-":
                h = h + self.dp(9)
            else:
                h = h + ih
            i = i + 1
        var x = self.ctx_x
        var y = self.ctx_y
        if x + w > self.W - 4:
            x = self.W - w - 4
        if y + h > self.H - 4:
            y = self.H - h - 4
        r.shadow_xywh(x, y, w, h, 12, 0, 4, th.shadow)
        r.fill_round_xywh(x, y, w, h, th.menu_bg, self.dp(5))
        r.round_rect_xywh(x, y, w, h, th.menu_border, self.dp(5), 1)
        self._hit(x, y, w, h, "@menu.bg", "", "")
        var yy = y + self.dp(4)
        i = 0
        while i < len(self.ctx_items):
            var it = self.ctx_items[i]
            if it[0] == "-":
                r.fill_xywh(x + self.dp(10), yy + self.dp(4), w - self.dp(20), 1, th.menu_border)
                yy = yy + self.dp(9)
            else:
                var enabled = it[1] == "" or string_startswith(it[1], "@") or self._command_enabled(it[1])
                var sel = self.ctx_sel == i or (self.ctx_sel < 0 and self._hov(x, yy, w, ih))
                var fg = th.text
                if sel and enabled:
                    r.fill_round_xywh(x + self.dp(4), yy, w - self.dp(8), ih, th.menu_sel, self.dp(3))
                    fg = th.text_hi
                if not enabled:
                    fg = th.text_faint
                r.text(it[0], x + self.dp(22), yy + int((ih - self.ui_h) / 2), self.f_ui, fg)
                var keys = ""
                if it[1] != "" and not string_startswith(it[1], "@"):
                    keys = self.reg.keys_of(it[1])
                if keys != "":
                    r.text(keys, x + w - self.dp(14) - self.f_small.width(keys), yy + int((ih - self.small_h) / 2), self.f_small, th.text_faint)
                if enabled:
                    self._hit(x, yy, w, ih, "@ctx.item", i, "")
                yy = yy + ih
            i = i + 1

    def _draw_ac(self, r):
        var th = self.th
        if not self._is_text():
            return
        var b = self.buf()
        var d = self.doc()
        var top = int(d.scroll_y / self.LINE_H)
        var x = self.text_x0 - d.scroll_x + self._col_x(b.get_line(b.cursor_row), b.cursor_col - len(self.ac_prefix))
        var y = self.ed_y + (b.cursor_row - top + 1) * self.LINE_H - (d.scroll_y - top * self.LINE_H)
        var rows = self.ac_n
        if rows > 10:
            rows = 10
        var ih = self.dp(22)
        var w = self.dp(360)
        var h = rows * ih + self.dp(4)
        if x + w > self.W - 8:
            x = self.W - w - 8
        if y + h > self.status_y:
            y = y - h - self.LINE_H
        r.shadow_xywh(x, y, w, h, 10, 0, 3, th.shadow)
        r.fill_xywh(x, y, w, h, th.widget_bg)
        r.rect_xywh(x, y, w, h, th.widget_border, 1)
        var first = self.ac_top
        var i = 0
        while i < rows and first + i < self.ac_n:
            var k = first + i
            var yy = y + self.dp(2) + i * ih
            if k == self.ac_sel:
                r.fill_xywh(x + 1, yy, w - 2, ih, th.list_active)
            elif self._hov(x, yy, w, ih):
                r.fill_xywh(x + 1, yy, w - 2, ih, th.hover)
            var kind = self.ac_kinds[k]
            var icon = "symbol-variable"
            var icol = th.info
            if kind == "keyword":
                icon = "symbol-keyword"
                icol = th.text
            elif kind == "function" or kind == "method" or kind == "builtin":
                icon = "symbol-method"
                icol = th.sym_method
            elif kind == "class":
                icon = "symbol-class"
                icol = th.git_mod
            elif kind == "snippet":
                icon = "symbol-snippet"
                icol = th.text
            self.icons.draw(r, icon, x + self.dp(6), yy + self.dp(3), self.dp(16), icol)
            var label = self.ac_items[k]
            var ty = yy + int((ih - self.code_h) / 2)
            r.text(label, x + self.dp(28), ty, self.f_code, th.text)
            # The characters the fuzzy matcher actually matched, in the
            # highlight colour (not just the first len(prefix) characters,
            # which for "def" -> "undefined" marked the wrong three).
            var ms = self._ac_marks_for(k)
            var j = 0
            while j < len(ms):
                r.text(string_slice(label, ms[j], ms[j] + 1), x + self.dp(28) + ms[j] * self.char_w, ty, self.f_code, th.match_hi)
                j = j + 1
            var kl = kind
            if kind == "snippet":
                kl = "snippet"
            r.text(kl, x + w - self.dp(10) - self.f_small.width(kl), yy + int((ih - self.small_h) / 2), self.f_small, th.text_faint)
            self._hit(x, yy, w, ih, "@ac.item", k, "")
            i = i + 1

    # Matched positions per suggestion, computed once per prefix and item.
    def _ac_marks_for(self, k):
        if self.ac_mark_key != self.ac_prefix:
            self.ac_mark_key = self.ac_prefix
            self.ac_marks = []
            var i = 0
            while i < self.ac_n:
                self.ac_marks.append(none)
                i = i + 1
        if k >= len(self.ac_marks):
            return []
        var ms = self.ac_marks[k]
        if ms == none:
            ms = []
            if len(self.ac_prefix) > 0:
                var ps = fuzzy_positions(self.ac_prefix, self.ac_items[k])
                if ps != none:
                    ms = ps
            self.ac_marks[k] = ms
        return ms

    def _draw_hover_info(self, r):
        var th = self.th
        var w = self.f_code.width(self.hover_info) + self.dp(20)
        var h = self.dp(28)
        var x = self.hover_x
        var y = self.hover_y - h - self.dp(4)
        if x + w > self.W - 8:
            x = self.W - w - 8
        if y < self.content_y:
            y = self.hover_y + self.LINE_H
        r.shadow_xywh(x, y, w, h, 8, 0, 2, th.shadow)
        r.fill_xywh(x, y, w, h, th.widget_bg)
        r.rect_xywh(x, y, w, h, th.widget_border, 1)
        r.text(self.hover_info, x + self.dp(10), y + int((h - self.code_h) / 2), self.f_code, th.text)

    # ── quick input (palette, quick open, pickers, prompts) ─────────────────
    def _draw_qi(self, r):
        var th = self.th
        var qi = self.qi
        self._scrim_hit("@qi.dismiss")
        var w = int(self.W * 0.44)
        if w < self.dp(420):
            w = self.dp(420)
        if w > self.dp(700):
            w = self.dp(700)
        if w > self.W - self.dp(40):
            w = self.W - self.dp(40)
        var x = int((self.W - w) / 2)
        var y = self.TITLE_H + self.dp(6)
        var ih = self.dp(24)
        var rows = qi.n - qi.top
        if rows > qi.max_rows:
            rows = qi.max_rows
        if rows < 0:
            rows = 0
        var head = self.dp(40)
        if qi.title != "":
            head = head + self.dp(24)
        var h = head + rows * ih + self.dp(6)
        r.shadow_xywh(x, y, w, h, 14, 0, 4, th.shadow)
        r.fill_round_xywh(x, y, w, h, th.widget_bg, self.dp(6))
        r.round_rect_xywh(x, y, w, h, th.widget_border, self.dp(6), 1)
        self._hit(x, y, w, h, "@qi.bg", "", "")
        var iy = y + self.dp(7)
        if qi.title != "":
            var tw = self.f_ui_bold.width(qi.title)
            r.text(qi.title, x + int((w - tw) / 2), y + self.dp(6), self.f_ui_bold, th.text)
            iy = iy + self.dp(24)
        var ph = qi.placeholder
        self._input(r, x + self.dp(8), iy, w - self.dp(16), self.dp(26), qi.value, ph, true, "@qi.input", "")
        var yy = iy + self.dp(32)
        if qi.value != "" and ph != "" and (qi.kind == "prompt" or qi.kind == "path"):
            r.text(ph, x + self.dp(10), yy - self.dp(4) + rows * ih + self.dp(6), self.f_small, th.text_faint)
        var i = 0
        while i < rows:
            var k = qi.top + i
            var it = qi.shown[k]
            var ry = yy + i * ih
            var selected = k == qi.sel
            if selected:
                r.fill_round_xywh(x + self.dp(4), ry, w - self.dp(8), ih, th.list_active, self.dp(3))
            elif self._hov(x, ry, w, ih):
                r.fill_round_xywh(x + self.dp(4), ry, w - self.dp(8), ih, th.hover, self.dp(3))
            var lx = x + self.dp(12)
            if it.icon != "":
                var ic = it.icon
                var icc = th.text_dim
                if ic == "file":
                    ic = "file-code"
                    icc = th.file_ny
                elif ic == "folder":
                    icc = th.text_dim
                elif ic == "class" or ic == "struct" or ic == "enum" or ic == "interface":
                    ic = "symbol-class"
                    icc = th.git_mod
                elif ic == "function" or ic == "method":
                    ic = "symbol-method"
                    icc = th.sym_method
                elif ic == "variable":
                    ic = "symbol-variable"
                    icc = th.info
                self.icons.draw(r, ic, lx, ry + self.dp(4), self.dp(16), icc)
                lx = lx + self.dp(22)
            var fg = th.text
            if selected:
                fg = th.text_hi
            var ty = ry + int((ih - self.ui_h) / 2)
            r.text(it.label, lx, ty, self.f_ui, fg)
            # Matched characters in the highlight colour. Worked out once per
            # query for each item shown, not sliced and measured every frame.
            if it.pos_q != qi.value:
                self._qi_item_marks(it, qi)
            var p = 0
            while p < len(it.pos_x):
                r.text(it.pos_ch[p], lx + it.pos_x[p], ty, self.f_ui_bold, th.match_hi)
                p = p + 1
            var lw = self.f_ui.width(it.label)
            if it.detail != "":
                r.text(it.detail, lx + lw + self.dp(10), ry + int((ih - self.small_h) / 2), self.f_small, th.text_faint)
            var right = x + w - self.dp(14)
            if it.keys != "":
                var kw = self.f_small.width(it.keys) + self.dp(10)
                r.fill_round_xywh(right - kw, ry + self.dp(4), kw, ih - self.dp(8), self._a(th.text, 30), self.dp(3))
                r.text(it.keys, right - kw + self.dp(5), ry + int((ih - self.small_h) / 2), self.f_small, th.text)
                right = right - kw - self.dp(8)
            if it.group != "":
                var gw = self.f_small.width(it.group)
                r.text(it.group, right - gw, ry + int((ih - self.small_h) / 2), self.f_small, th.link)
                if i > 0:
                    r.fill_xywh(x + self.dp(8), ry, w - self.dp(16), 1, th.widget_border)
            self._hit(x, ry, w, ih, "@qi.item", k, "")
            i = i + 1

    # ── notifications ────────────────────────────────────────────────────────
    def _draw_toasts(self, r):
        if self.notif_center:
            return
        var th = self.th
        var now = time_ms()
        if not self.notes.any_active(now):
            return
        var act = self.notes.active(now, 3)
        if len(act) == 0:
            return
        var w = self.dp(420)
        var h = self.dp(46)
        var x = self.W - w - self.dp(12)
        var y = self.status_y - h - self.dp(10)
        var i = 0
        while i < len(act):
            var n = act[i]
            var age = now - n.t
            var fade = 1.0
            if age > self.notes.ttl - 500:
                fade = (self.notes.ttl - age) / 500.0
            if fade < 0.0:
                fade = 0.0
            var alpha = int(255.0 * fade)
            var slide = 0
            if age < 180:
                slide = int((1.0 - self.ease.out_cubic(age / 180.0)) * 40.0)
            var tx = x + slide
            r.shadow_xywh(tx, y, w, h, 10, 0, 3, self._a(th.shadow, int(92.0 * fade)))
            r.fill_xywh(tx, y, w, h, self._a(th.widget_bg, alpha))
            r.rect_xywh(tx, y, w, h, self._a(th.widget_border, alpha), 1)
            var icon = "info"
            var ic = th.info
            if n.kind == "err":
                icon = "error"
                ic = th.err
            elif n.kind == "warn":
                icon = "warning"
                ic = th.warn
            elif n.kind == "ok":
                icon = "pass"
                ic = th.ok
            self.icons.draw(r, icon, tx + self.dp(12), y + int((h - self.dp(16)) / 2), self.dp(16), self._a(ic, alpha))
            r.clip_xywh(tx, y, w - self.dp(36), h)
            r.text(n.text, tx + self.dp(38), y + int((h - self.ui_h) / 2), self.f_ui, self._a(th.text, alpha))
            r.clear_clip()
            self._small_button(r, tx + w - self.dp(30), y + self.dp(12), self.dp(22), self.dp(22), "close", "@toast.close", n.id, "Clear Notification", false)
            y = y - h - self.dp(8)
            i = i + 1
        self._dirty = true

    def _draw_notif_center(self, r):
        var th = self.th
        self._scrim_hit("@overlay.dismiss")
        var w = self.dp(440)
        var rows = len(self.notes.items)
        if rows > 12:
            rows = 12
        var ih = self.dp(30)
        var head = self.dp(34)
        var h = head + rows * ih + self.dp(8)
        if rows == 0:
            h = head + self.dp(40)
        var x = self.W - w - self.dp(12)
        var y = self.status_y - h - self.dp(8)
        r.shadow_xywh(x, y, w, h, 12, 0, 4, th.shadow)
        r.fill_xywh(x, y, w, h, th.widget_bg)
        r.rect_xywh(x, y, w, h, th.widget_border, 1)
        self._hit(x, y, w, h, "@menu.bg", "", "")
        r.text("NOTIFICATIONS", x + self.dp(12), y + int((head - self.small_h) / 2), self.f_small, th.text)
        self._small_button(r, x + w - self.dp(58), y + self.dp(6), self.dp(22), self.dp(22), "clear-all", "notifications.clearAll", "", "Clear All Notifications", false)
        self._small_button(r, x + w - self.dp(32), y + self.dp(6), self.dp(22), self.dp(22), "chevron-down", "notifications.showList", "", "Hide Notifications", false)
        if rows == 0:
            r.text("No new notifications", x + self.dp(12), y + head + self.dp(10), self.f_ui, th.text_faint)
            return
        var i = 0
        var yy = y + head
        var k = len(self.notes.items) - 1
        while i < rows:
            var n = self.notes.items[k]
            var icon = "info"
            var ic = th.info
            if n.kind == "err":
                icon = "error"
                ic = th.err
            elif n.kind == "warn":
                icon = "warning"
                ic = th.warn
            elif n.kind == "ok":
                icon = "pass"
                ic = th.ok
            self.icons.draw(r, icon, x + self.dp(12), yy + self.dp(7), self.dp(16), ic)
            r.clip_xywh(x, yy, w - self.dp(10), ih)
            r.text(n.text, x + self.dp(36), yy + int((ih - self.ui_h) / 2), self.f_ui, th.text)
            r.clear_clip()
            yy = yy + ih
            i = i + 1
            k = k - 1

    # ── modal dialog ─────────────────────────────────────────────────────────
    def _draw_modal(self, r):
        var th = self.th
        r.fill_xywh(0, 0, self.W, self.H, th.scrim)
        self._scrim_hit("@modal.scrim")
        var w = self.dp(460)
        var lines = string_split(self.modal_msg, "\n")
        var h = self.dp(118) + len(lines) * self.dp(18)
        var x = int((self.W - w) / 2)
        var y = int(self.H * 0.26)
        r.shadow_xywh(x, y, w, h, 16, 0, 6, th.shadow)
        r.fill_round_xywh(x, y, w, h, th.widget_bg, self.dp(6))
        r.round_rect_xywh(x, y, w, h, th.widget_border, self.dp(6), 1)
        self._hit(x, y, w, h, "@menu.bg", "", "")
        self.icons.draw(r, "warning", x + self.dp(20), y + self.dp(22), self.dp(28), th.warn)
        r.clip_xywh(x, y, w - self.dp(12), h)
        r.text(self.modal_title, x + self.dp(62), y + self.dp(22), self.f_ui_bold, th.text)
        var i = 0
        while i < len(lines):
            r.text(lines[i], x + self.dp(62), y + self.dp(48) + i * self.dp(18), self.f_small, th.text_dim)
            i = i + 1
        r.clear_clip()
        var bh = self.dp(28)
        var by = y + h - bh - self.dp(16)
        var bx = x + w - self.dp(16)
        var k = len(self.modal_buttons) - 1
        while k >= 0:
            var bt = self.modal_buttons[k]
            var bw = self.f_ui.width(bt[0]) + self.dp(28)
            if bw < self.dp(80):
                bw = self.dp(80)
            bx = bx - bw
            self._button(r, bx, by, bw, bh, bt[0], "@modal.button", k, k == self.modal_sel)
            if k == self.modal_sel:
                r.round_rect_xywh(bx - 2, by - 2, bw + 4, bh + 4, th.focus, self.dp(3), 1)
            bx = bx - self.dp(8)
            k = k - 1

    # ── tooltip ──────────────────────────────────────────────────────────────
    def _draw_tooltip(self, r):
        if self.tip_text == "" or time_ms() - self.tip_t0 < 550:
            return
        if self.dragging != "" or self.mouse_down:
            return
        var th = self.th
        var w = self.f_small.width(self.tip_text) + self.dp(16)
        var h = self.dp(24)
        var x = self.tip_x
        var y = self.tip_y
        if x + w > self.W - 6:
            x = self.W - w - 6
        if y + h > self.H - 4:
            y = self.tip_y - h - self.dp(30)
        r.shadow_xywh(x, y, w, h, 8, 0, 2, th.shadow)
        r.fill_xywh(x, y, w, h, th.widget_bg)
        r.rect_xywh(x, y, w, h, th.widget_border, 1)
        r.text(self.tip_text, x + self.dp(8), y + int((h - self.small_h) / 2), self.f_small, th.text)
