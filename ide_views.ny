# ══════════════════════════════════════════════════════════════════════════════
#  ide_views.ny — IDEViews: the side bar views and the logic behind them.
#  Part of the NythonIDE class chain; see ide_core.ny's header.
#
#  Explorer, Search, Source Control, Run and Debug, Extensions, Outline and the
#  AI assistant. Three of these (Source Control, Run and Debug, Extensions)
#  used to draw "No content yet".
# ══════════════════════════════════════════════════════════════════════════════

import "ide_paint.ny"
import "lib/ide_scm.ny"
import "lib/ide_debugger.ny"


class IDEViews(IDEPaint):
    # ══ side bar frame ═════════════════════════════════════════════════════════
    def _draw_sidebar(self, r):
        var th = self.th
        var x = self.side_x
        var w = self.side_w
        var y0 = self.content_y
        r.fill_xywh(x, y0, w, self.status_y - y0, th.side_bg)
        self._hit(x + w - self.dp(3), y0, self.dp(6), self.status_y - y0, "@split.sidebar", "", "")
        r.clip_xywh(x, y0, w, self.status_y - y0)
        var title = self.view_titles[self._view_index(self.active_view)]
        r.text(title, x + self.dp(20), y0 + int((self.SIDE_HEAD - self.small_h) / 2), self.f_small, th.side_title)
        self._hit(x, y0, w, self.status_y - y0, "@side.bg", "", "")
        var v = self.active_view
        if v == "explorer":
            self._draw_explorer(r, x, w)
        elif v == "search":
            self._draw_search(r, x, w)
        elif v == "scm":
            self._draw_scm(r, x, w)
        elif v == "debug":
            self._draw_debug_view(r, x, w)
        elif v == "ext":
            self._draw_extensions(r, x, w)
        elif v == "outline":
            self._draw_outline(r, x, w)
        elif v == "ai":
            self._draw_ai(r, x, w)
        r.clear_clip()

    def _view_index(self, key):
        var i = 0
        while i < len(self.views):
            if self.views[i] == key:
                return i
            i = i + 1
        return 0

    # Title-bar actions of a view, right-aligned: [[icon, cmd, arg, tip], ...]
    def _view_actions(self, r, x, w, acts):
        var bx = x + w - self.dp(8)
        var i = len(acts) - 1
        while i >= 0:
            var a = acts[i]
            bx = bx - self.dp(24)
            self._small_button(r, bx, self.content_y + self.dp(7), self.dp(22), self.dp(22), a[0], a[1], a[2], a[3], false)
            i = i - 1

    # Collapsible section header ("STAGED CHANGES", "BREAKPOINTS", ...).
    def _section(self, r, x, y, w, label, key, count):
        var th = self.th
        var h = self.ROW_H
        var open = not self.sections_closed.has_key(key)
        if self._hov(x, y, w, h):
            r.fill_xywh(x, y, w, h, th.hover)
        var chev = "chevron-down"
        if not open:
            chev = "chevron-right"
        self.icons.draw(r, chev, x + self.dp(4), y + self.dp(3), self.dp(16), th.text)
        r.text(label, x + self.dp(22), y + int((h - self.small_h) / 2), self.f_small_bold, th.text)
        if count >= 0:
            var cs = self._num(count)
            var cw = self.f_tiny.width(cs) + self.dp(10)
            r.fill_round_xywh(x + w - cw - self.dp(10), y + self.dp(3), cw, self.dp(16), th.badge_bg, self.dp(8))
            r.text(cs, x + w - cw - self.dp(5), y + self.dp(4), self.f_tiny, th.badge_fg)
        self._hit(x, y, w, h, "@section", key, "")
        return open

    # ══ Explorer ═══════════════════════════════════════════════════════════════
    def _draw_explorer(self, r, x, w):
        var th = self.th
        self._view_actions(r, x, w, self.acts_explorer)
        var y = self.content_y + self.SIDE_HEAD
        if self.ws.root == "":
            r.text("You have not yet opened a folder.", x + self.dp(20), y + self.dp(12), self.f_ui, th.text)
            self._button(r, x + self.dp(20), y + self.dp(40), w - self.dp(40), self.dp(28), "Open Folder", "workbench.action.files.openFolder", "", true)
            self._button(r, x + self.dp(20), y + self.dp(76), w - self.dp(40), self.dp(28), "Open Recent", "workbench.action.openRecent", "", false)
            return
        var lh = self.ROW_H
        var bottom = self.status_y
        var i = self.tree_scroll
        var focused = self.focus == "explorer"
        while i < self.ws.row_count and y + lh <= bottom:
            var n = self.ws.rows[i]
            var ix = x + self.dp(8) + n.depth * self.dp(10)
            if i == self.tree_sel:
                if focused:
                    r.fill_xywh(x, y, w, lh, th.list_active)
                    r.rect_xywh(x, y, w, lh, th.focus, 1)
                else:
                    r.fill_xywh(x, y, w, lh, th.list_inactive)
            elif self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            var ty = y + int((lh - self.ui_h) / 2)
            var col = th.text
            var letter = ""
            var lcol = th.text
            var ch = self.scm_by_path.get(n.path)
            if ch != none:
                letter = ch.letter(false)
                if letter == "U" or letter == "A":
                    col = th.git_untracked
                elif letter == "D":
                    col = th.git_del
                else:
                    col = th.git_mod
                lcol = col
            elif n.is_dir and self.scm_dirs.has_key(n.path):
                col = th.git_mod
            if n.is_dir:
                var chev = "chevron-right"
                if n.expanded:
                    chev = "chevron-down"
                self.icons.draw(r, chev, ix, y + self.dp(3), self.dp(16), th.text)
                r.text(n.name, ix + self.dp(20), ty, self.f_ui, col)
            else:
                var ic = "file"
                var icol = th.file_other
                if n.kind == "code":
                    ic = "file-code"
                    icol = th.file_ny
                elif n.kind == "project":
                    ic = "project"
                    icol = th.ok
                elif n.kind == "text":
                    ic = "markdown"
                    icol = th.file_md
                self.icons.draw(r, ic, ix + self.dp(18), y + self.dp(3), self.dp(16), icol)
                r.text(n.name, ix + self.dp(38), ty, self.f_ui, col)
            var rx = x + w - self.dp(14)
            if letter != "":
                r.text(letter, rx - self.f_small.width(letter), y + int((lh - self.small_h) / 2), self.f_small, lcol)
                rx = rx - self.dp(16)
            var perr = self.prob_by_path.get(n.path)
            if perr != none and perr > 0:
                var ps = self._num(perr)
                r.text(ps, rx - self.f_small.width(ps), y + int((lh - self.small_h) / 2), self.f_small, th.err)
            self._hit(x, y, w, lh, "@tree", i, n.path)
            y = y + lh
            i = i + 1

    def _tree_click(self, idx, e):
        if idx < 0 or idx >= self.ws.row_count:
            return
        self.tree_sel = idx
        self.focus = "explorer"
        var n = self.ws.rows[idx]
        if n.is_dir:
            self.ws.toggle(n.path)
        else:
            self._open_path(n.path, -1, 0)
            # A single click previews; focus stays in the tree unless the
            # user double-clicks, as in VS Code.
            if e.clicks >= 2:
                self.focus = "editor"
            else:
                self.focus = "explorer"

    def _tree_key(self, e):
        var k = e.key
        if k == "down":
            if self.tree_sel < self.ws.row_count - 1:
                self.tree_sel = self.tree_sel + 1
            self._reveal_tree_row(self.tree_sel)
            return true
        if k == "up":
            if self.tree_sel > 0:
                self.tree_sel = self.tree_sel - 1
            self._reveal_tree_row(self.tree_sel)
            return true
        if self.tree_sel < 0 or self.tree_sel >= self.ws.row_count:
            return false
        var n = self.ws.rows[self.tree_sel]
        if k == "right":
            if n.is_dir and not n.expanded:
                self.ws.toggle(n.path)
            return true
        if k == "left":
            if n.is_dir and n.expanded:
                self.ws.toggle(n.path)
            elif n.depth > 0:
                var i = self.tree_sel - 1
                while i >= 0 and self.ws.rows[i].depth >= n.depth:
                    i = i - 1
                if i >= 0:
                    self.tree_sel = i
                    self._reveal_tree_row(i)
            return true
        if k == "enter" or k == "space":
            if n.is_dir:
                self.ws.toggle(n.path)
            else:
                self._open_path(n.path, -1, 0)
                if k == "enter":
                    self.focus = "editor"
            return true
        return false

    # ══ Search ═════════════════════════════════════════════════════════════════
    def _draw_search(self, r, x, w):
        var th = self.th
        self._view_actions(r, x, w, self.acts_search)
        var y = self.content_y + self.SIDE_HEAD
        var tg = "chevron-right"
        if self.search_replace_open:
            tg = "chevron-down"
        self._small_button(r, x + self.dp(4), y + self.dp(2), self.dp(16), self.dp(24), tg, "@search.togglereplace", "", "Toggle Replace", false)
        var fx = x + self.dp(22)
        var fw = w - self.dp(30)
        self._input(r, fx, y, fw, self.dp(26), self.search_query, "Search", self.focus == "search" and self.search_field == 0, "@search.field", 0)
        var ox = fx + fw - self.dp(68)
        self._search_toggle(r, ox, y + self.dp(3), "case-sensitive", self.search_case, "case", "Match Case")
        self._search_toggle(r, ox + self.dp(22), y + self.dp(3), "whole-word", self.search_word, "word", "Match Whole Word")
        self._search_toggle(r, ox + self.dp(44), y + self.dp(3), "regex", self.search_regex, "regex", "Use Regular Expression")
        y = y + self.dp(30)
        if self.search_replace_open:
            self._input(r, fx, y, fw - self.dp(28), self.dp(26), self.search_replace, "Replace", self.focus == "search" and self.search_field == 1, "@search.field", 1)
            self._small_button(r, fx + fw - self.dp(24), y + self.dp(2), self.dp(22), self.dp(22), "replace-all", "@search.replaceall", "", "Replace All", false)
            y = y + self.dp(30)
        if self.search_query == "":
            return
        r.text(self.search_summary, x + self.dp(20), y + self.dp(4), self.f_small, th.text_faint)
        y = y + self.dp(24)
        var lh = self.ROW_H
        var rows = self._search_rows()
        var i = self.tree_scroll
        while i < len(rows) and y + lh <= self.status_y:
            var row = rows[i]
            var fr = self.search_results[row[0]]
            if self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            var ty = y + int((lh - self.ui_h) / 2)
            if row[1] < 0:
                var chev = "chevron-down"
                if self.search_collapsed.has_key(fr[0]):
                    chev = "chevron-right"
                self.icons.draw(r, chev, x + self.dp(4), y + self.dp(3), self.dp(16), th.text)
                self.icons.draw(r, "file-code", x + self.dp(22), y + self.dp(3), self.dp(16), th.file_ny)
                var nm = os_path_basename(fr[0])
                r.text(nm, x + self.dp(42), ty, self.f_ui, th.text)
                r.text(self._rel(os_path_dirname(fr[0])), x + self.dp(48) + self.f_ui.width(nm), y + int((lh - self.small_h) / 2), self.f_small, th.text_faint)
                var cs = self._num(len(fr[1]))
                var cw = self.f_tiny.width(cs) + self.dp(10)
                r.fill_round_xywh(x + w - cw - self.dp(10), y + self.dp(3), cw, self.dp(16), th.badge_bg, self.dp(8))
                r.text(cs, x + w - cw - self.dp(5), y + self.dp(4), self.f_tiny, th.badge_fg)
                self._hit(x, y, w, lh, "@search.file", row[0], fr[0])
            else:
                var m = fr[1][row[1]]
                var text = m[3]
                var tx = x + self.dp(40)
                var pre = string_slice(text, 0, m[4])
                var hit_s = string_slice(text, m[4], m[4] + m[2])
                r.text(pre, tx, ty, self.f_ui, th.text_dim)
                var px = tx + self.f_ui.width(pre)
                var hw = self.f_ui.width(hit_s)
                r.fill_xywh(px, y + self.dp(3), hw, lh - self.dp(6), th.find_other)
                r.text(hit_s, px, ty, self.f_ui, th.text)
                r.text(string_slice(text, m[4] + m[2], len(text)), px + hw, ty, self.f_ui, th.text_dim)
                self._hit(x, y, w, lh, "@search.match", row[0] * 100000 + row[1], "")
            y = y + lh
            i = i + 1

    def _search_toggle(self, r, x, y, icon, on, key, tip):
        var th = self.th
        var s = self.dp(20)
        if on:
            r.fill_round_xywh(x, y, s, s, self._a(th.accent, 90), self.dp(3))
            r.round_rect_xywh(x, y, s, s, th.accent, self.dp(3), 1)
        elif self._hov(x, y, s, s):
            r.fill_round_xywh(x, y, s, s, self._a(th.text, 30), self.dp(3))
        self.icons.draw(r, icon, x + self.dp(2), y + self.dp(2), self.dp(16), th.text)
        self._hit(x, y, s, s, "@search.toggle", key, tip)

    # Flattened [result_index, match_index or -1] display rows, rebuilt only
    # when results or collapsed state change.
    def _search_rows(self):
        if self.search_rows_src == self.search_results and self.search_rows_cn == len(self.search_collapsed):
            return self.search_rows
        var rows = []
        var i = 0
        while i < len(self.search_results):
            rows.append([i, -1])
            if not self.search_collapsed.has_key(self.search_results[i][0]):
                var j = 0
                while j < len(self.search_results[i][1]):
                    rows.append([i, j])
                    j = j + 1
            i = i + 1
        self.search_rows = rows
        self.search_rows_src = self.search_results
        self.search_rows_cn = len(self.search_collapsed)
        return rows

    # Results: [[path, [[row, col, len, display_text, display_col], ...]], ...]
    # Matches in open editors come from the buffer (unsaved text), everything
    # else from disk - what VS Code searches too.
    def _run_search(self):
        self.search_results = []
        self.tree_scroll = 0
        var q = self.search_query
        if q == "" or self.ws.root == "":
            self.search_summary = ""
            return
        var total = 0
        var nfiles = 0
        # Open documents are searched in memory, so unsaved edits count; every
        # other file natively (fs_search). This used to read and split up to
        # 4,000 files in the interpreter, 300 ms after each keystroke in the
        # search box.
        var skip_rel = []
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.kind == "file" and d.buf != none and d.path != "" and string_startswith(d.path, self.ws.root + "/"):
                skip_rel.append(self._rel(d.path))
                if total < 2000:
                    var ms = self._search_lines(d.buf.lines_view(), q)
                    if len(ms) > 0:
                        self.search_results.append([d.path, ms])
                        total = total + len(ms)
                        nfiles = nfiles + 1
            i = i + 1
        if total < 2000:
            var hits = fs_search(self.ws.root, q, {"case": self.search_case, "word": self.search_word,
                                                   "regex": self.search_regex, "max_results": 2000 - total,
                                                   "max_size": 800000, "skip_files": skip_rel,
                                                   "skip": ["build", "node_modules", "__pycache__"]})
            var cur_path = ""
            var cur = none
            var h = 0
            while h < len(hits):
                var m = hits[h]
                var p = self.ws.root + "/" + m[0]
                if p != cur_path:
                    cur_path = p
                    cur = []
                    self.search_results.append([p, cur])
                    nfiles = nfiles + 1
                cur.append(self._search_match(m[3], m[1], m[2], m[4]))
                total = total + 1
                h = h + 1
        self.search_total = total
        if total == 0:
            self.search_summary = "No results found."
        else:
            var rw = " results in "
            if total == 1:
                rw = " result in "
            var fw = " files"
            if nfiles == 1:
                fw = " file"
            self.search_summary = str(total) + rw + str(nfiles) + fw
        self._dirty = true

    def _is_texty(self, p):
        var ext = os_path_ext(p)
        return ext == ".ny" or ext == ".nyx" or ext == ".md" or ext == ".txt" or ext == ".cpp" or ext == ".hpp" or ext == ".h" or ext == ".c" or ext == ".py" or ext == ".json" or ext == ".cbp" or ext == ".bat" or ext == ".sh" or ext == "" or ext == ".nyproj" or ext == ".cfg" or ext == ".toml" or ext == ".yml" or ext == ".yaml"

    def _search_lines(self, lines, q):
        var out = []
        var ql = string_lower(q)
        var r = 0
        while r < len(lines) and len(out) < 500:
            var line = lines[r]
            var hits = []
            if self.search_regex:
                var ms = re_findall(q, line)
                if ms != none:
                    var frm = 0
                    var k = 0
                    while k < len(ms):
                        if len(ms[k]) > 0:
                            var at = string_find(string_slice(line, frm, len(line)), ms[k])
                            if at >= 0:
                                hits.append([frm + at, len(ms[k])])
                                frm = frm + at + len(ms[k])
                        k = k + 1
            else:
                var hay = line
                var needle = q
                if not self.search_case:
                    hay = string_lower(line)
                    needle = ql
                var from2 = 0
                var guard = 0
                while from2 <= len(hay) and guard < 200:
                    var at2 = string_find(string_slice(hay, from2, len(hay)), needle)
                    if at2 < 0:
                        from2 = len(hay) + 1
                    else:
                        var c = from2 + at2
                        if not self.search_word or self._is_whole_in(line, c, len(q)):
                            hits.append([c, len(q)])
                        from2 = c + len(q)
                    guard = guard + 1
            var h = 0
            while h < len(hits):
                out.append(self._search_match(line, r, hits[h][0], hits[h][1]))
                h = h + 1
            r = r + 1
        return out

    # [row, col, len, display text, display col]: the line trimmed of its
    # indentation, with a little leading context when the match sits far to
    # the right.
    def _search_match(self, line, r, col, n):
        var ind = 0
        while ind < len(line) and string_slice(line, ind, ind + 1) == " ":
            ind = ind + 1
        var start = ind
        if col - start > 30:
            start = col - 20
        return [r, col, n, string_slice(line, start, len(line)), col - start]

    def _is_whole_in(self, line, at, n):
        if at > 0:
            var c = string_slice(line, at - 1, at)
            if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_":
                return false
        if at + n < len(line):
            var d = string_slice(line, at + n, at + n + 1)
            if (d >= "a" and d <= "z") or (d >= "A" and d <= "Z") or (d >= "0" and d <= "9") or d == "_":
                return false
        return true

    def _open_search_match(self, code):
        var ri = int(code / 100000)
        var mi = code - ri * 100000
        if ri >= len(self.search_results):
            return
        var fr = self.search_results[ri]
        var m = fr[1][mi]
        if self._open_path(fr[0], m[0], m[1]):
            var d = self.doc()
            d.sel_on = true
            d.sel_row = m[0]
            d.sel_col = m[1]
            d.buf.cursor_col = m[1] + m[2]
            self._reveal_caret_center()

    # Replace All across the workspace: open editors are edited in their
    # buffers (undoable, left unsaved like VS Code); other files on disk.
    def _search_replace_all(self):
        if len(self.search_results) == 0:
            return
        var files = 0
        var n = 0
        var i = 0
        while i < len(self.search_results):
            var fr = self.search_results[i]
            var p = fr[0]
            var ms = fr[1]
            var di = self._find_doc(p)
            if di >= 0 and self.docs[di].buf != none:
                var b = self.docs[di].buf
                b.begin_group()
                var was = b.hold
                b.hold = true
                var k = len(ms) - 1
                while k >= 0:
                    var m = ms[k]
                    b.delete_range(m[0], m[1], m[0], m[1] + m[2])
                    b.cursor_row = m[0]
                    b.cursor_col = m[1]
                    b.insert_text(self.search_replace)
                    k = k - 1
                b.hold = was
                b.begin_group()
            else:
                var text = read_file(p)
                var lines = string_split(text, "\n")
                var k2 = len(ms) - 1
                while k2 >= 0:
                    var m2 = ms[k2]
                    var ln = lines[m2[0]]
                    lines[m2[0]] = string_slice(ln, 0, m2[1]) + self.search_replace + string_slice(ln, m2[1] + m2[2], len(ln))
                    k2 = k2 - 1
                write_file(p, string_join(lines, "\n"))
            files = files + 1
            n = n + len(ms)
            i = i + 1
        self._after_edit()
        self._notify("Replaced " + str(n) + " occurrence(s) across " + str(files) + " file(s)", "ok")
        self._run_search()

    # ══ Source Control ═════════════════════════════════════════════════════════
    def _scm_refresh(self):
        self.scm_stale = false
        if self.ws.root == "":
            self.git.root = ""
            self.git.changes = []
        elif self.git.root == "" or not string_startswith(self.ws.root, self.git.root):
            self.git.probe(self.ws.root)
        else:
            self.git.refresh()
        self.scm_branch = self.git.branch
        self.scm_count = len(self.git.changes)
        var by = {}
        var dirs = {}
        var i = 0
        while i < len(self.git.changes):
            var c = self.git.changes[i]
            by[c.path] = c
            var d = os_path_dirname(c.path)
            var guard = 0
            while d != "" and string_startswith(d, self.git.root) and guard < 40:
                dirs[d] = true
                d = os_path_dirname(d)
                guard = guard + 1
            i = i + 1
        self.scm_by_path = by
        self.scm_dirs = dirs
        # HEAD may have moved (commit, checkout): recompute gutter markers.
        var k = 0
        while k < len(self.docs):
            self.docs[k].diff_state = -2
            k = k + 1
        self._dirty = true

    def _draw_scm(self, r, x, w):
        var th = self.th
        if self.scm_stale:
            self._scm_refresh()
        self._view_actions(r, x, w, self.acts_scm)
        var y = self.content_y + self.SIDE_HEAD
        if not self.git.available:
            r.text("Git was not found on this system.", x + self.dp(20), y + self.dp(10), self.f_ui, th.text)
            r.text("Install git and reopen the folder to use Source Control.", x + self.dp(20), y + self.dp(32), self.f_small, th.text_faint)
            return
        if self.ws.root == "":
            r.text("Open a folder to use Source Control.", x + self.dp(20), y + self.dp(10), self.f_ui, th.text)
            self._button(r, x + self.dp(20), y + self.dp(36), w - self.dp(40), self.dp(28), "Open Folder", "workbench.action.files.openFolder", "", true)
            return
        if not self.git.is_repo():
            r.text("The folder currently open doesn't have a", x + self.dp(20), y + self.dp(10), self.f_ui, th.text)
            r.text("git repository.", x + self.dp(20), y + self.dp(28), self.f_ui, th.text)
            self._button(r, x + self.dp(20), y + self.dp(56), w - self.dp(40), self.dp(28), "Initialize Repository", "git.init", "", true)
            return
        var mx = x + self.dp(12)
        var mw = w - self.dp(24)
        var ph = "Message (Ctrl+Enter to commit on '" + self.git.branch + "')"
        self._input(r, mx, y, mw, self.dp(28), self.scm_msg, ph, self.focus == "scm", "@scm.msg", "")
        y = y + self.dp(34)
        self._button(r, mx, y, mw, self.dp(28), "Commit", "git.commit", "", true)
        self.icons.draw(r, "check", mx + int(mw / 2) - self.f_ui.width("Commit") / 2 - self.dp(22), y + self.dp(6), self.dp(16), th.button_fg)
        y = y + self.dp(38)
        if self.git.error != "":
            r.text(self.git.error, mx, y, self.f_small, th.err)
            y = y + self.dp(20)
        var staged = self.git.staged()
        var unstaged = self.git.unstaged()
        if len(staged) > 0:
            if self._section(r, x, y, w, "STAGED CHANGES", "scm.staged", len(staged)):
                self._small_button(r, x + w - self.dp(70), y + self.dp(1), self.dp(20), self.dp(20), "remove", "git.unstageAll", "", "Unstage All Changes", false)
                y = y + self.ROW_H
                y = self._scm_rows(r, x, y, w, staged, true)
            else:
                y = y + self.ROW_H
        if self._section(r, x, y, w, "CHANGES", "scm.changes", len(unstaged)):
            if len(unstaged) > 0:
                self._small_button(r, x + w - self.dp(70), y + self.dp(1), self.dp(20), self.dp(20), "add", "git.stageAll", "", "Stage All Changes", false)
            y = y + self.ROW_H
            if len(unstaged) == 0 and len(staged) == 0:
                r.text("No changes. The working tree is clean.", x + self.dp(24), y + self.dp(4), self.f_small, th.text_faint)
            y = self._scm_rows(r, x, y, w, unstaged, false)

    def _scm_rows(self, r, x, y, w, list, staged_view):
        var th = self.th
        var lh = self.ROW_H
        var i = 0
        while i < len(list) and y + lh <= self.status_y:
            var c = list[i]
            var hov = self._hov(x, y, w, lh)
            if hov:
                r.fill_xywh(x, y, w, lh, th.hover)
            var letter = c.letter(staged_view)
            var col = th.git_mod
            if letter == "U" or letter == "A":
                col = th.git_untracked
            elif letter == "D":
                col = th.git_del
            self.icons.draw(r, "file-code", x + self.dp(22), y + self.dp(3), self.dp(16), th.file_ny)
            var nm = os_path_basename(c.rel)
            r.text(nm, x + self.dp(42), y + int((lh - self.ui_h) / 2), self.f_ui, col)
            var dir = os_path_dirname(c.rel)
            if dir != "":
                r.text(dir, x + self.dp(48) + self.f_ui.width(nm), y + int((lh - self.small_h) / 2), self.f_small, th.text_faint)
            r.text(letter, x + w - self.dp(20), y + int((lh - self.small_h) / 2), self.f_small, col)
            var arg = c.path
            if staged_view:
                arg = "S:" + c.path
            self._hit(x, y, w, lh, "@scm.row", arg, c.rel)
            if hov:
                var bx = x + w - self.dp(90)
                self._small_button(r, bx, y + self.dp(1), self.dp(20), self.dp(20), "go-to-file", "@scm.openfile", c.path, "Open File", false)
                if staged_view:
                    self._small_button(r, bx + self.dp(22), y + self.dp(1), self.dp(20), self.dp(20), "remove", "git.unstage", c.path, "Unstage Changes", false)
                else:
                    self._small_button(r, bx + self.dp(22), y + self.dp(1), self.dp(20), self.dp(20), "discard", "git.clean", c.path, "Discard Changes", false)
                    self._small_button(r, bx + self.dp(44), y + self.dp(1), self.dp(20), self.dp(20), "add", "git.stage", c.path, "Stage Changes", false)
            y = y + lh
            i = i + 1
        return y

    def _git_command(self, id, arg):
        if id == "git.refresh":
            self._scm_refresh()
            self.status_msg = "Source control refreshed"
            return
        if id == "git.init":
            if self.ws.root == "":
                return
            if self.git.init_repo(self.ws.root):
                self._notify("Initialized an empty git repository in " + os_path_basename(self.ws.root), "ok")
            else:
                self._notify("git init failed: " + self.git.last_output, "err")
            self._scm_refresh()
            return
        if not self.git.is_repo():
            self._scm_refresh()
            if not self.git.is_repo():
                self._notify("No git repository in this folder", "warn")
                return
        var c = none
        if arg != none and arg != "":
            c = self.git.status_of(arg)
        if id == "git.stage" and c != none:
            self.git.stage(c.rel)
        elif id == "git.unstage" and c != none:
            self.git.unstage(c.rel)
        elif id == "git.stageAll":
            self.git.stage_all()
        elif id == "git.unstageAll":
            self.git.unstage_all()
        elif id == "git.clean" and c != none:
            var what = "your changes in"
            if c.x == "?":
                what = "the untracked file"
            self._modal("Are you sure you want to discard " + what + " '" + os_path_basename(c.rel) + "'?",
                        "This is IRREVERSIBLE. Your current working set will be forever lost.",
                        [["Discard", "@git.discard.confirm", c.path], ["Cancel", "@modal.cancel", ""]])
            return
        elif id == "git.commit":
            var msg = string_strip(self.scm_msg)
            if msg == "":
                self._show_view("scm")
                self.focus = "scm"
                self._notify("Type a commit message first", "warn")
                return
            if len(self.git.staged()) == 0 and len(self.git.unstaged()) > 0:
                # VS Code's "smart commit": nothing staged means commit everything.
                self.git.stage_all()
            if self.git.commit(msg, "/tmp/nyide_commit_" + str(self.session_id) + ".txt"):
                self._notify("Committed to " + self.git.branch + ": " + msg, "ok")
                self.scm_msg = ""
            else:
                self._notify(self.git.error, "err")
        elif id == "git.openChange" and c != none:
            self._open_change(c, false)
        elif id == "git.checkout":
            self._checkout_picker()
            return
        elif id == "git.showLog":
            var log = self.git.log(60)
            self._open_virtual("Git Log (" + self.git.branch + ")", string_join(log, "\n") + "\n")
            return
        self._scm_refresh()

    def _git_discard(self, path):
        var c = self.git.status_of(path)
        if c == none:
            return
        self.git.discard(c)
        # Reload an open editor of the file so it shows the restored text.
        var i = self._find_doc(path)
        if i >= 0 and not self.docs[i].dirty():
            if os_exists(path):
                var text = read_file(path)
                self.docs[i].buf = EditorBuffer(self.docs[i].title, text)
                self.docs[i].buf.coalesce = true
                self._hl_reset()
            else:
                self._close_doc(i, true)
        self.ws.rebuild()
        self.ws_files = none
        self._scm_refresh()
        self._notify("Discarded changes in " + os_path_basename(path), "info")

    def _open_change(self, c, staged):
        var text = self.git.diff_text(c, staged)
        var d = self._open_virtual(os_path_basename(c.rel) + " (changes)", text)
        d.lang = "diff"

    def _checkout_picker(self):
        var bs = self.git.branches()
        var labels = []
        var values = []
        var i = 0
        while i < len(bs):
            var lab = bs[i]
            if bs[i] == self.git.branch:
                lab = bs[i] + "  (current)"
            labels.append(lab)
            values.append(bs[i])
            i = i + 1
        labels.append("+ Create new branch...")
        values.append("__new__")
        self._pick("checkout", "Select a branch to checkout", labels, values, self.git.branch)

    def _git_checkout(self, v):
        if v == "__new__":
            self._open_prompt("newbranch", "Create Branch", "New branch name", "")
            return
        if v == self.git.branch:
            return
        if self._dirty_count() > 0:
            self._notify("Save your changes before switching branches", "warn")
            return
        if self.git.checkout(v):
            self._reload_clean_docs()
            self._notify("Switched to branch " + v, "ok")
        else:
            self._notify(self.git.error, "err")
        self.ws.rebuild()
        self.ws_files = none
        self._scm_refresh()

    # Files change on disk under a checkout; unmodified editors follow.
    def _reload_clean_docs(self):
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.kind == "file" and not d.dirty() and os_exists(d.path):
                self._reload_from_disk(d)
            i = i + 1

    # Gutter change markers for a document, recomputed shortly after edits
    # stop (scm_diff_due) and whenever HEAD moves.
    def _diff_for(self, d):
        if d.kind != "file" or not self.git.is_repo() or d.buf == none:
            return none
        var sid = d.buf.state_id()
        if d.diff != none and d.diff_state == sid:
            return d.diff
        if d.diff_state != -2 and d.diff != none and time_ms() < self.scm_diff_due:
            return d.diff
        var base = self.git.head_lines(d.path)
        if base == none and self.git.status_of(d.path) == none:
            d.diff = none
            d.diff_state = sid
            return none
        # Native Myers diff (text_diff_classify): the same per-line kinds as
        # LineDiff.classify, without running the diff as a script loop in
        # the painter.
        d.diff = text_diff_classify(base, d.buf.lines, d.buf.line_count)
        d.diff_state = sid
        return d.diff

    # ══ Run and Debug ══════════════════════════════════════════════════════════
    def _draw_debug_view(self, r, x, w):
        var th = self.th
        var y = self.content_y + self.SIDE_HEAD
        if not self.dbg.active:
            if self.dbg_recording:
                r.text("Recording " + os_path_basename(self.job_path) + " ...", x + self.dp(20), y + self.dp(10), self.f_ui, th.text)
                self._button(r, x + self.dp(20), y + self.dp(36), w - self.dp(40), self.dp(28), "Stop", "workbench.action.debug.stop", "", false)
                y = y + self.dp(80)
            else:
                self._button(r, x + self.dp(20), y + self.dp(8), w - self.dp(40), self.dp(28), "Run and Debug", "workbench.action.debug.start", "", true)
                var ty = self._draw_wrapped(r, "Records the program, then lets you step through it forwards and backwards (F10, F11, Ctrl+Shift+F11).",
                                            x + self.dp(20), y + self.dp(46), w - self.dp(40), self.f_small, th.text_faint, self.dp(16))
                self._button(r, x + self.dp(20), ty + self.dp(10), w - self.dp(40), self.dp(28), "Run Without Debugging", "workbench.action.debug.run", "", false)
                y = ty + self.dp(54)
        else:
            y = self._draw_dbg_timeline(r, x, y, w)
            if self.dbg.exception != "":
                r.fill_xywh(x + self.dp(8), y, w - self.dp(16), self.dp(40), self._a(th.err, 40))
                self.icons.draw(r, "error", x + self.dp(14), y + self.dp(4), self.dp(16), th.err)
                r.text("Exception: " + self.dbg.exception, x + self.dp(36), y + self.dp(4), self.f_small, th.text)
                r.text(self.dbg.exception_at, x + self.dp(36), y + self.dp(20), self.f_small, th.text_faint)
                self._hit(x, y, w, self.dp(40), "@dbg.exception", "", "Go to where the exception was raised")
                y = y + self.dp(46)
            if self._section(r, x, y, w, "VARIABLES", "dbg.vars", -1):
                y = y + self.ROW_H
                y = self._draw_dbg_vars(r, x, y, w)
            else:
                y = y + self.ROW_H
            if self._section(r, x, y, w, "WATCH", "dbg.watch", -1):
                self._small_button(r, x + w - self.dp(30), y + self.dp(1), self.dp(20), self.dp(20), "add", "@dbg.addwatch", "", "Add Expression", false)
                y = y + self.ROW_H
                y = self._draw_dbg_watch(r, x, y, w)
            else:
                y = y + self.ROW_H
            if self._section(r, x, y, w, "CALL STACK", "dbg.stack", -1):
                y = y + self.ROW_H
                y = self._draw_dbg_stack(r, x, y, w)
            else:
                y = y + self.ROW_H
        if self._section(r, x, y, w, "BREAKPOINTS", "dbg.breaks", len(self.break_list)):
            if len(self.break_list) > 0:
                self._small_button(r, x + w - self.dp(70), y + self.dp(1), self.dp(20), self.dp(20), "close-all", "workbench.debug.viewlet.action.removeAllBreakpoints", "", "Remove All Breakpoints", false)
            y = y + self.ROW_H
            self._draw_breaks(r, x, y, w)

    # The recording as a scrubbable timeline: step i of n, click to jump.
    def _draw_dbg_timeline(self, r, x, y, w):
        var th = self.th
        var n = self.dbg.n
        var label = "Step " + str(self.dbg.pos + 1) + " of " + str(n)
        if self.dbg.state == "ended":
            label = label + "  (end of recording)"
        if self.dbg.capped:
            label = label + "  (recording truncated)"
        r.text(label, x + self.dp(20), y + self.dp(4), self.f_small, th.text_dim)
        var tx = x + self.dp(20)
        var tw = w - self.dp(40)
        var ty = y + self.dp(24)
        r.fill_round_xywh(tx, ty, tw, self.dp(6), self._a(th.text, 40), self.dp(3))
        if n > 1:
            var fx = tx + int(tw * (self.dbg.pos * 1.0 / (n - 1)))
            r.fill_round_xywh(tx, ty, fx - tx + 1, self.dp(6), th.accent, self.dp(3))
            r.fill_circle(fx, ty + self.dp(3), self.dp(6), th.accent)
            # Breakpoint hits as ticks on the timeline.
            if len(self.dbg_hits) < 300:
                var k = 0
                while k < len(self.dbg_hits):
                    var hx = tx + int(tw * (self.dbg_hits[k] * 1.0 / (n - 1)))
                    r.fill_xywh(hx, ty - self.dp(3), 2, self.dp(12), th.breakpoint)
                    k = k + 1
        self._hit(tx - self.dp(6), ty - self.dp(8), tw + self.dp(12), self.dp(22), "@dbg.seek", "", "Drag or click to travel through the recording")
        return y + self.dp(44)

    def _draw_dbg_vars(self, r, x, y, w):
        var th = self.th
        var vars = self.dbg_vars_cache()
        var lh = self.ROW_H
        if len(vars) == 0:
            r.text("No variables in this frame", x + self.dp(24), y + self.dp(4), self.f_small, th.text_faint)
            return y + lh
        var i = 0
        while i < len(vars) and y + lh <= self.status_y - self.dp(80):
            var nm = vars[i][0]
            var v = vars[i][1]
            if i == self.dbg_var_sel:
                r.fill_xywh(x, y, w, lh, th.list_inactive)
            elif self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            r.text(nm, x + self.dp(24), y + int((lh - self.code_small_h) / 2), self.f_mono_small, th.info)
            var nw = self.f_mono_small.width(nm)
            r.text(": ", x + self.dp(24) + nw, y + int((lh - self.code_small_h) / 2), self.f_mono_small, th.text_dim)
            r.text(v, x + self.dp(24) + nw + self.f_mono_small.width(": "), y + int((lh - self.code_small_h) / 2), self.f_mono_small, th.text)
            self._hit(x, y, w, lh, "@dbg.var", i, nm + " = " + v)
            y = y + lh
            i = i + 1
        return y

    def dbg_vars_cache(self):
        if self.dbg_vars_pos == self.dbg.pos and self.dbg_vars_frame == self.dbg_frame:
            return self.dbg_vars
        var saved = self.dbg.pos
        if self.dbg_frame >= 0 and self.dbg_frame != self.dbg.pos:
            self.dbg.pos = self.dbg_frame
        self.dbg_vars = self.dbg.variables()
        self.dbg.pos = saved
        self.dbg_vars_pos = self.dbg.pos
        self.dbg_vars_frame = self.dbg_frame
        return self.dbg_vars

    def _draw_dbg_watch(self, r, x, y, w):
        var th = self.th
        var lh = self.ROW_H
        if len(self.watches) == 0:
            r.text("Add an expression with +", x + self.dp(24), y + self.dp(4), self.f_small, th.text_faint)
            return y + lh
        var i = 0
        while i < len(self.watches):
            var nm = self.watches[i]
            var v = self.dbg.value_of(nm)
            var vs = "not available"
            var vc = th.text_faint
            if v != none:
                vs = v
                vc = th.text
            r.text(nm + ": ", x + self.dp(24), y + int((lh - self.code_small_h) / 2), self.f_mono_small, th.info)
            r.text(vs, x + self.dp(24) + self.f_mono_small.width(nm + ": "), y + int((lh - self.code_small_h) / 2), self.f_mono_small, vc)
            if self._hov(x, y, w, lh):
                self._small_button(r, x + w - self.dp(28), y + self.dp(1), self.dp(20), self.dp(20), "close", "@dbg.rmwatch", i, "Remove Expression", false)
            y = y + lh
            i = i + 1
        return y

    def _draw_dbg_stack(self, r, x, y, w):
        var th = self.th
        var lh = self.ROW_H
        var st = self.dbg_stack_cache()
        var i = 0
        while i < len(st):
            var fr = st[i]
            var sel = (self.dbg_frame < 0 and i == 0) or fr[3] == self.dbg_frame
            if sel:
                r.fill_xywh(x, y, w, lh, th.list_inactive)
            elif self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            if i == 0:
                self.icons.draw(r, "debug-stackframe", x + self.dp(6), y + self.dp(3), self.dp(16), th.warn)
            r.text(fr[0], x + self.dp(26), y + int((lh - self.ui_h) / 2), self.f_ui, th.text)
            var loc = os_path_basename(fr[1]) + ":" + str(fr[2])
            r.text(loc, x + w - self.dp(12) - self.f_small.width(loc), y + int((lh - self.small_h) / 2), self.f_small, th.text_faint)
            self._hit(x, y, w, lh, "@dbg.frame", i, "")
            y = y + lh
            i = i + 1
        return y

    # [function, file, line, event_index] per frame, innermost first.
    def dbg_stack_cache(self):
        if self.dbg_stack_pos == self.dbg.pos:
            return self.dbg_stack
        var raw = self.dbg.stack()
        var out = []
        var i = 0
        var saved = self.dbg.pos
        # Recover each frame's event index so selecting a frame can show its
        # variables as they were when it made the call.
        var want = 0
        var ei = saved
        while i < len(raw):
            var fr = raw[i]
            var found = saved
            if i > 0:
                var k = ei - 1
                while k >= 0:
                    if self.dbg.lines[k] == fr[2] and self.dbg.file_at(k) == fr[1] and self.dbg.depths[k] < self.dbg.depths[ei]:
                        found = k
                        k = -1
                    k = k - 1
                ei = found
            out.append([fr[0], fr[1], fr[2], found])
            i = i + 1
        self.dbg_stack = out
        self.dbg_stack_pos = self.dbg.pos
        return out

    def _draw_breaks(self, r, x, y, w):
        var th = self.th
        var lh = self.ROW_H
        if len(self.break_list) == 0:
            r.text("Click the gutter (or press F9) to add one", x + self.dp(24), y + self.dp(4), self.f_small, th.text_faint)
            return
        var i = 0
        while i < len(self.break_list) and y + lh <= self.status_y:
            var key = self.break_list[i]
            var c = self._break_parts(key)
            if self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            r.fill_circle(x + self.dp(28), y + int(lh / 2), self.dp(5), th.breakpoint)
            var nm = os_path_basename(c[0])
            r.text(nm, x + self.dp(42), y + int((lh - self.ui_h) / 2), self.f_ui, th.text)
            r.text(str(c[1]), x + self.dp(48) + self.f_ui.width(nm), y + int((lh - self.small_h) / 2), self.f_small, th.text_faint)
            self._hit(x, y, w, lh, "@break.go", i, key)
            if self._hov(x, y, w, lh):
                self._small_button(r, x + w - self.dp(30), y + self.dp(1), self.dp(20), self.dp(20), "close", "@break.rm", i, "Remove Breakpoint", false)
            y = y + lh
            i = i + 1

    # ── breakpoints ──────────────────────────────────────────────────────────
    # Keyed "path:line" with a 1-based line, the same shape the recording uses,
    # so a breakpoint needs no translation to be matched against a step.
    def _doc_key(self, d):
        if d.path != "":
            return d.path
        return "untitled:" + d.title

    def _break_key(self, row):
        return self._doc_key(self.doc()) + ":" + str(row + 1)

    def _break_parts(self, key):
        var c = -1
        var i = 0
        while i < len(key):
            if string_slice(key, i, i + 1) == ":":
                c = i
            i = i + 1
        return [string_slice(key, 0, c), int(string_slice(key, c + 1, len(key)))]

    # The active editor's breakpoints as {row: true}, rebuilt only when the
    # breakpoints or the editor change. The gutter asks once per visible line
    # per frame, and building a "path:line" key for each ask was a new
    # permanent string per line per frame.
    def _break_rows(self):
        var d = self.doc()
        if self.brk_rows_doc == d and self.brk_rows_gen == self.brk_gen:
            return self.brk_rows
        var rows = {}
        var pre = self._doc_key(d) + ":"
        var i = 0
        while i < len(self.break_list):
            var k = self.break_list[i]
            if string_startswith(k, pre):
                rows[int(string_slice(k, len(pre), len(k))) - 1] = true
            i = i + 1
        self.brk_rows = rows
        self.brk_rows_doc = d
        self.brk_rows_gen = self.brk_gen
        return rows

    def _has_break(self, row):
        return self._break_rows().has_key(row)

    def _toggle_break(self, row):
        var k = self._break_key(row)
        if self.breaks.has_key(k):
            self.breaks.remove(k)
            var keep = []
            var i = 0
            while i < len(self.break_list):
                if self.break_list[i] != k:
                    keep.append(self.break_list[i])
                i = i + 1
            self.break_list = keep
            self.brk_gen = self.brk_gen + 1
            self.status_msg = "Breakpoint removed at line " + str(row + 1)
        else:
            self.breaks[k] = true
            self.break_list.append(k)
            self.brk_gen = self.brk_gen + 1
            self.status_msg = "Breakpoint set at line " + str(row + 1)
        if self.dbg.active:
            self._dbg_compute_hits()

    # ── debug session ────────────────────────────────────────────────────────
    def _debug_start(self):
        if self.dbg.active:
            self._debug_continue(1)
            return
        if not self._is_text() or self.doc().lang != "nython":
            self._notify("Open a Nython file to debug it", "warn")
            return
        if self.job_running:
            self._notify("A program is already running", "warn")
            return
        var d = self.doc()
        var path = self._path_for_run(d)
        self.dbg_doc = d
        self.dbg_run_path = path
        self.dbg_trace = "/tmp/nyide_trace_" + str(self.session_id) + ".jsonl"
        write_file(self.dbg_trace, "")
        # Breakpoints of an untitled editor apply to its temporary copy.
        self.dbg_breaks = {}
        var i = 0
        while i < len(self.break_list):
            var parts = self._break_parts(self.break_list[i])
            var file = parts[0]
            if file == self._doc_key(d):
                file = path
            self.dbg_breaks[file + ":" + str(parts[1])] = true
            i = i + 1
        self.dbgcon_lines = []
        self.dbgcon_kinds = []
        self._dbg_print("Recording " + os_path_basename(path) + " ...", "info")
        self._show_view("debug")
        self._show_panel("debug")
        self.job_mode = "Debug"
        self.job_path = path
        self.job_doc = d
        self.dbg_recording = true
        var cwd = self.ws.root
        if cwd == "":
            cwd = os_path_dirname(path)
        os_setenv("NY_TRACE_MAX", "20000")
        self._start_job(self._interpreter() + " --trace " + self.dbg_trace + " ", path, cwd)

    # Called when the recording job exits (from _finish_job's caller).
    def _debug_loaded(self):
        self.dbg_recording = false
        if not self.dbg.load(self.dbg_trace):
            self._notify("The debug recording could not be read", "err")
            return
        if self.dbg.n == 0:
            self._notify("Nothing to debug: no statements were recorded (did the file fail to parse?)", "warn")
            self._show_panel("problems")
            return
        self._dbg_compute_hits()
        self.dbg.start(self.dbg_breaks)
        self.dbg_frame = -1
        self._dbg_print("Recorded " + str(self.dbg.n) + " steps. Paused at line " + str(self.dbg.line_at(self.dbg.pos)) + ".", "info")
        if self.dbg.exception != "":
            self._dbg_print("The program raised: " + self.dbg.exception + "  (" + self.dbg.exception_at + ")", "err")
        self._dbg_sync()

    def _dbg_compute_hits(self):
        var hits = []
        var i = 0
        while i < self.dbg.n and len(hits) < 1000:
            if self.dbg_breaks.has_key(self.dbg.file_at(i) + ":" + str(self.dbg.lines[i])):
                hits.append(i)
            i = i + 1
        self.dbg_hits = hits

    # Moves the editor to the current step and refreshes the output shown.
    def _dbg_sync(self):
        if not self.dbg.active:
            return
        self.dbg_frame = -1
        var pos = self.dbg.pos
        var file = self.dbg.file_at(pos)
        var line = self.dbg.line_at(pos)
        self.dbg_line_path = file
        self.dbg_line_row = line - 1
        if file == self.dbg_run_path and self.dbg_doc != none and self.dbg_doc.kind != "file":
            var di = self._index_of(self.dbg_doc)
            if di >= 0:
                self._activate(di)
            self.dbg_line_path = self.doc().path
        elif file != "":
            if self.doc().path != file:
                self._open_path(file, -1, 0)
        if self._is_text():
            var b = self.buf()
            b.cursor_row = self.dbg_line_row
            if b.cursor_row >= b.line_count:
                b.cursor_row = b.line_count - 1
            b.cursor_col = 0
            self._reveal_row_center(b.cursor_row)
        # Program output up to this step, in the Debug Console; all of it once
        # the end is reached (the last statement's output comes after the
        # last recorded step).
        var upto = self.dbg.output_so_far()
        if self.dbg.state == "ended":
            upto = len(self.dbg.outputs)
        var keep_l = []
        var keep_k = []
        var i = 0
        while i < len(self.dbgcon_lines):
            if self.dbgcon_kinds[i] != "out":
                keep_l.append(self.dbgcon_lines[i])
                keep_k.append(self.dbgcon_kinds[i])
            i = i + 1
        i = 0
        while i < upto:
            keep_l.append(self.dbg.outputs[i])
            keep_k.append("out")
            i = i + 1
        self.dbgcon_lines = keep_l
        self.dbgcon_kinds = keep_k
        self._dirty = true

    def _debug_step(self, kind):
        if not self.dbg.active:
            return
        var moved = false
        if kind == "over":
            moved = self.dbg.step_over()
        elif kind == "into":
            moved = self.dbg.step_into()
        elif kind == "out":
            moved = self.dbg.step_out()
        elif kind == "back":
            moved = self.dbg.step_back()
        if not moved and self.dbg.state == "ended":
            self._dbg_end_reached()
        self._dbg_sync()

    def _debug_continue(self, dir):
        if not self.dbg.active:
            return
        if dir > 0:
            if not self.dbg.continue_fwd(self.dbg_breaks):
                self._dbg_end_reached()
        else:
            self.dbg.continue_back(self.dbg_breaks)
        self._dbg_sync()

    def _dbg_end_reached(self):
        if self.dbg.exception != "":
            self.status_msg = "Paused on exception: " + self.dbg.exception
        else:
            self.status_msg = "End of the recording - Step Back (Ctrl+Shift+F11) travels backwards"

    def _debug_stop(self):
        if self.dbg_recording and self.job_running:
            self._stop_job()
        self.dbg_recording = false
        if self.dbg.active:
            self.dbg.stop()
            self._dbg_print("Debug session ended.", "info")
        self.dbg_line_row = -1
        self.dbg_line_path = ""
        self._dirty = true

    def _dbg_seek_x(self, mx):
        var x = self.side_x + self.dp(20)
        var tw = self.side_w - self.dp(40)
        if tw <= 0 or self.dbg.n <= 1:
            return
        var f = (mx - x) * 1.0 / tw
        if f < 0.0:
            f = 0.0
        if f > 1.0:
            f = 1.0
        self.dbg.seek(int(f * (self.dbg.n - 1) + 0.5))
        self._dbg_sync()

    # Debug Console input: a variable of the selected frame, by name.
    def _dbg_eval(self, expr):
        var e = string_strip(expr)
        if e == "":
            return
        self._dbg_print("> " + e, "cmd")
        if not self.dbg.active:
            self._dbg_print("No debug session. Start one with F5.", "warn")
            return
        var v = self.dbg.value_of(e)
        if v != none:
            self._dbg_print(v, "ok")
            return
        # A dotted name: show the object's recorded fields when present.
        self._dbg_print("'" + e + "' is not a variable of this frame. The recording holds each frame's variables; type one of: " + self._var_names(), "warn")

    def _var_names(self):
        var vars = self.dbg.variables()
        var out = ""
        var i = 0
        while i < len(vars) and i < 12:
            if i > 0:
                out = out + ", "
            out = out + vars[i][0]
            i = i + 1
        return out

    # ══ Extensions: the Nython library catalog ═════════════════════════════════
    # VS Code's Extensions view lists installable packages. Nython's
    # "extensions" are its libraries: every module under lib/, with its own
    # description (the file's leading comment) and API (classes, functions),
    # each one openable and importable into the current file.
    def _catalog(self):
        if self.cat != none:
            return self.cat
        var out = []
        var home = getenv("NYTHON_HOME")
        if home == none or home == "":
            home = getcwd()
        var libdir = path_join(home, "lib")
        var ents = os_listdir(libdir)
        if ents != none:
            ents = sorted(ents)
            var i = 0
            while i < len(ents):
                var nm = ents[i]
                if os_path_ext(nm) == ".ny":
                    out.append(self._catalog_entry(path_join(libdir, nm), "lib/" + nm))
                i = i + 1
        var sub = path_join(libdir, "nytorch")
        var ents2 = os_listdir(sub)
        if ents2 != none:
            ents2 = sorted(ents2)
            var j = 0
            while j < len(ents2):
                if os_path_ext(ents2[j]) == ".ny":
                    out.append(self._catalog_entry(path_join(sub, ents2[j]), "lib/nytorch/" + ents2[j]))
                j = j + 1
        self.cat = out
        return out

    # [name, import_path, description, classes, functions, full_path]
    def _catalog_entry(self, path, imp):
        var text = read_file(path)
        var desc = ""
        var classes = 0
        var funcs = 0
        if text != none:
            var lines = string_split(text, "\n")
            var i = 0
            while i < len(lines) and i < 400:
                var ln = lines[i]
                var st = string_strip(ln)
                if desc == "" and string_startswith(st, "#"):
                    var t = string_strip(string_slice(st, 1, len(st)))
                    var ok = t != "" and not string_startswith(t, "=") and not string_startswith(t, "-") and not string_startswith(t, "\xe2") and not string_startswith(t, "Usage")
                    if ok:
                        desc = t
                if string_startswith(ln, "class "):
                    classes = classes + 1
                elif string_startswith(ln, "def "):
                    funcs = funcs + 1
                i = i + 1
            var j = 400
            while j < len(lines):
                if string_startswith(lines[j], "class "):
                    classes = classes + 1
                elif string_startswith(lines[j], "def "):
                    funcs = funcs + 1
                j = j + 1
        var name = string_replace(os_path_basename(path), ".ny", "")
        if desc == "":
            desc = "Nython library module"
        return [name, imp, desc, classes, funcs, path]

    def _draw_extensions(self, r, x, w):
        var th = self.th
        self._view_actions(r, x, w, self.acts_ext)
        var y = self.content_y + self.SIDE_HEAD
        self._input(r, x + self.dp(12), y, w - self.dp(24), self.dp(26), self.ext_query, "Search libraries", self.focus == "extsearch", "@ext.search", "")
        y = y + self.dp(34)
        var cat = self._ext_filtered()
        if self._section(r, x, y, w, "INSTALLED  (standard library)", "ext.installed", len(cat)):
            y = y + self.ROW_H
            var ih = self.dp(52)
            var i = self.tree_scroll
            while i < len(cat) and y + ih <= self.status_y:
                var e = cat[i]
                var hov = self._hov(x, y, w, ih)
                if hov:
                    r.fill_xywh(x, y, w, ih, th.hover)
                r.fill_round_xywh(x + self.dp(14), y + self.dp(8), self.dp(34), self.dp(34), self._a(th.accent, 60), self.dp(4))
                self.icons.draw(r, "extensions", x + self.dp(21), y + self.dp(15), self.dp(20), th.link)
                r.text(e[0], x + self.dp(58), y + self.dp(6), self.f_ui_bold, th.text)
                r.clip_xywh(x, y, w - self.dp(8), ih)
                r.text(e[2], x + self.dp(58), y + self.dp(24), self.f_small, th.text_dim)
                r.clear_clip()
                var api = str(e[3]) + " classes, " + str(e[4]) + " functions"
                r.text(api, x + self.dp(58), y + self.dp(38), self.f_tiny, th.text_faint)
                self._hit(x, y, w, ih, "@ext.open", i, e[1])
                if hov:
                    self._button(r, x + w - self.dp(76), y + self.dp(14), self.dp(64), self.dp(22), "Import", "@ext.import", i, true)
                y = y + ih
                i = i + 1

    def _ext_filtered(self):
        var cat = self._catalog()
        if self.ext_query == "":
            return cat
        if self.ext_filter_q == self.ext_query:
            return self.ext_filter
        var q = string_lower(self.ext_query)
        var out = []
        var i = 0
        while i < len(cat):
            var e = cat[i]
            if string_find(string_lower(e[0]), q) >= 0 or string_find(string_lower(e[2]), q) >= 0:
                out.append(e)
            i = i + 1
        self.ext_filter = out
        self.ext_filter_q = self.ext_query
        return out

    # A generated overview page: description, how to import, the API.
    def _ext_page(self, i):
        var cat = self._ext_filtered()
        if i < 0 or i >= len(cat):
            return
        var e = cat[i]
        var text = e[0] + "\n" + e[2] + "\n\nimport \"" + e[1] + "\"\n\n"
        var src = read_file(e[5])
        var lines = string_split(src, "\n")
        var cls = ""
        var k = 0
        while k < len(lines):
            var ln = lines[k]
            if string_startswith(ln, "class "):
                cls = string_strip(string_slice(ln, 6, len(ln)))
                text = text + "class " + cls + "\n"
            elif string_startswith(ln, "    def ") and not string_startswith(ln, "    def _"):
                text = text + "    " + string_strip(ln) + "\n"
            elif string_startswith(ln, "def "):
                text = text + string_strip(ln) + "\n"
            k = k + 1
        var d = self._open_virtual("Library: " + e[0], text)
        d.lang = "nython"
        self.ext_open_path = e[5]

    def _ext_import(self, i):
        var cat = self._ext_filtered()
        if i < 0 or i >= len(cat):
            return
        if not self._can_edit() or self.doc().lang != "nython":
            self._notify("Open a Nython file to import " + cat[i][0] + " into", "warn")
            return
        var line = "import \"" + cat[i][1] + "\""
        var b = self.buf()
        var r = 0
        while r < b.line_count:
            if string_strip(b.get_line(r)) == line:
                self._notify(cat[i][0] + " is already imported", "info")
                return
            r = r + 1
        # After the last existing import, else at the top.
        var at = 0
        r = 0
        while r < b.line_count and r < 200:
            if string_startswith(b.get_line(r), "import ") or string_startswith(b.get_line(r), "from "):
                at = r + 1
            r = r + 1
        var save_r = b.cursor_row
        var save_c = b.cursor_col
        b.begin_group()
        b.cursor_row = at
        b.cursor_col = 0
        b.insert_text(line + "\n")
        b.begin_group()
        b.cursor_row = save_r + 1
        b.cursor_col = save_c
        self._after_edit()
        self._notify("Added " + line, "ok")

    # ══ Outline ════════════════════════════════════════════════════════════════
    def _outline_syms(self):
        if not self._is_text():
            return []
        var b = self.buf()
        if self.outline_doc == self.doc() and self.outline_state == b.state_id():
            return self.outline_syms
        self.outline_syms = self._doc_symbols(b)
        self.outline_doc = self.doc()
        self.outline_state = b.state_id()
        return self.outline_syms

    def _draw_outline(self, r, x, w):
        var th = self.th
        var y = self.content_y + self.SIDE_HEAD
        var syms = self._outline_syms()
        if len(syms) == 0:
            r.text("The active editor has no symbols.", x + self.dp(20), y + self.dp(8), self.f_ui, th.text_faint)
            return
        var cur = self._enclosing_row(self.buf().cursor_row)
        var lh = self.ROW_H
        var i = self.tree_scroll
        while i < len(syms) and y + lh <= self.status_y:
            var s = syms[i]
            var ix = x + self.dp(12) + s[6] * self.dp(12)
            if s[2] == cur:
                r.fill_xywh(x, y, w, lh, th.list_inactive)
            elif self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            var icon = "symbol-variable"
            var icol = th.info
            var k = s[1]
            if k == "class" or k == "struct":
                icon = "symbol-class"
                icol = th.git_mod
            elif k == "enum":
                icon = "symbol-enum"
                icol = th.git_mod
            elif k == "interface":
                icon = "symbol-interface"
                icol = th.git_mod
            elif k == "namespace":
                icon = "symbol-namespace"
                icol = th.text_faint
            elif k == "function" or k == "method":
                icon = "symbol-method"
                icol = th.sym_method
            elif k == "field":
                icon = "symbol-field"
                icol = th.info
            elif k == "constant":
                icon = "symbol-constant"
                icol = th.info
            self.icons.draw(r, icon, ix, y + self.dp(3), self.dp(16), icol)
            r.text(s[0], ix + self.dp(22), y + int((lh - self.ui_h) / 2), self.f_ui, th.text)
            r.text(self._line_num(s[2] + 1), x + w - self.dp(16) - self.f_small.width(self._line_num(s[2] + 1)), y + int((lh - self.small_h) / 2), self.f_small, th.text_faint)
            self._hit(x, y, w, lh, "@outline", i, s[1] + " " + s[0])
            y = y + lh
            i = i + 1

    # ══ AI assistant ═══════════════════════════════════════════════════════════
    def _draw_ai(self, r, x, w):
        var th = self.th
        self._view_actions(r, x, w, self.acts_ai)
        self._ai_analyze(false)
        var y = self.content_y + self.SIDE_HEAD
        if not self._is_text():
            r.text("Open a file to analyse it.", x + self.dp(20), y + self.dp(8), self.f_ui, th.text_faint)
            return
        r.text(self.doc().title, x + self.dp(20), y + self.dp(4), self.f_ui_bold, th.text)
        y = y + self.dp(26)
        if self.ai_n == 0:
            self.icons.draw(r, "pass", x + self.dp(20), y, self.dp(16), th.ok)
            r.text("No suggestions for this file", x + self.dp(42), y, self.f_ui, th.text_dim)
            r.text("Pattern review by lib/aiagent.ny's CodeAnalyzer", x + self.dp(20), y + self.dp(24), self.f_small, th.text_faint)
            return
        var ih = self.dp(44)
        var i = self.tree_scroll
        while i < self.ai_n and y + ih <= self.status_y:
            var it = self.ai_issues[i]
            if self._hov(x, y, w, ih):
                r.fill_xywh(x, y, w, ih, th.hover)
            self.icons.draw(r, "lightbulb", x + self.dp(14), y + self.dp(4), self.dp(16), th.warn)
            r.clip_xywh(x, y, w - self.dp(8), ih)
            r.text(it["message"], x + self.dp(38), y + self.dp(4), self.f_ui, th.text)
            r.text("line " + str(it["line"]) + "   " + string_strip(it["code"]), x + self.dp(38), y + self.dp(22), self.f_small, th.text_faint)
            r.clear_clip()
            self._hit(x, y, w, ih, "@ai", it["line"], "")
            y = y + ih
            i = i + 1
