# ══════════════════════════════════════════════════════════════════════════════
#  ide_ops.ny — IDEOps: multi-cursor, find/replace, quick input, run/build,
#  diagnostics, settings, explorer file operations and symbols.
#  Part of the NythonIDE class chain; see ide_core.ny's header.
# ══════════════════════════════════════════════════════════════════════════════

import "ide_core.ny"
import "lib/ide_selection.ny"


# A shell command running in the background with its output captured to a
# file and read incrementally. Run, the debugger's recording and the terminal
# all use it, so none of them can freeze the IDE; the old IDE blocked in popen
# until a program finished, with no way to stop it.
class BgProc:
    def __init__(self, base):
        self.base = base
        self.log = base + ".log"
        self.exitf = base + ".exit"
        self.pidf = base + ".pid"
        self.running = false
        self.code = 0
        self.read = 0
        self.carry = ""
        self.poll_t = 0
        self.t0 = 0
        self.killed = false

    def _q(self, s):
        return "'" + string_replace(s, "'", "'\\''") + "'"

    # `inner` is a shell command line; stdout and stderr go to the log.
    def start(self, inner, cwd):
        write_file(self.log, "")
        if os_exists(self.exitf):
            os_remove(self.exitf)
        var script = "cd " + self._q(cwd) + " && { " + inner + " ; } < /dev/null > " + self._q(self.log) + " 2>&1; echo $? > " + self._q(self.exitf)
        os_exec("(sh -c " + self._q(script) + " & echo $! > " + self._q(self.pidf) + ") > /dev/null 2>&1")
        self.running = true
        self.code = 0
        self.read = 0
        self.carry = ""
        self.killed = false
        self.t0 = time_ms()
        self.poll_t = 0

    # Complete new lines since the last poll ([] if none); sets running=false
    # and code once the process has exited and everything has been read.
    def poll(self, min_ms):
        var out = []
        if not self.running:
            return out
        var now = time_ms()
        if now - self.poll_t < min_ms:
            return out
        self.poll_t = now
        var done = os_exists(self.exitf)
        var size = file_size(self.log)
        if size != none and size > self.read:
            var chunk = os_exec("tail -c +" + str(self.read + 1) + " " + self._q(self.log))
            if chunk != none and chunk != "":
                self.read = self.read + len(chunk)
                var lines = string_split(self.carry + chunk, "\n")
                var n = len(lines)
                var i = 0
                while i < n - 1:
                    out.append(lines[i])
                    i = i + 1
                self.carry = lines[n - 1]
        if done:
            var size2 = file_size(self.log)
            if size2 == none or size2 <= self.read:
                if self.carry != "":
                    out.append(self.carry)
                    self.carry = ""
                var cs = read_file(self.exitf)
                if cs == none:
                    cs = "1"
                self.code = int_or_zero(string_strip(cs))
                if self.killed:
                    self.code = 143
                self.running = false
        return out

    def stop(self):
        if not self.running:
            return
        var pid = string_strip(read_file(self.pidf))
        if pid != "":
            # The sh -c wrapper and everything it started.
            os_exec("pkill -TERM -P " + pid + " > /dev/null 2>&1; kill " + pid + " > /dev/null 2>&1")
        self.killed = true
        write_file(self.exitf, "143")

    def elapsed(self):
        return time_ms() - self.t0


def int_or_zero(s):
    var t = string_strip(s)
    if t == "":
        return 0
    var i = 0
    while i < len(t):
        var ch = string_slice(t, i, i + 1)
        if (ch < "0" or ch > "9") and not (i == 0 and ch == "-"):
            return 0
        i = i + 1
    return int(t)


class IDEOps(IDECore):
    # ══ multi-cursor ═══════════════════════════════════════════════════════════
    # The primary caret is the buffer's own cursor; selmodel.sels[1:] are the
    # extra carets, each with an anchor so it can hold a selection (Ctrl+D).
    def _sync_primary_caret(self):
        var b = self.buf()
        self.selmodel.sels[0].caret.row = b.cursor_row
        self.selmodel.sels[0].caret.col = b.cursor_col

    def _clear_extra_carets(self):
        if self.selmodel.count > 1:
            self.selmodel.clear_secondary()
            self._dirty = true

    def _add_caret(self, row, col):
        if not self._is_text():
            return false
        self._sync_primary_caret()
        return self.selmodel.add_caret(row, col)

    def _add_selection(self, ar, ac, cr, cc):
        self._sync_primary_caret()
        if self.selmodel.add_caret(cr, cc):
            var s = self.selmodel.sels[self.selmodel.count - 1]
            s.anchor.row = ar
            s.anchor.col = ac
            return true
        return false

    def _add_caret_vertical(self, delta):
        if not self._is_text():
            return
        var b = self.buf()
        self._sync_primary_caret()
        var from_row = b.cursor_row
        var from_col = b.cursor_col
        if self.selmodel.count > 1:
            var last = self.selmodel.sels[self.selmodel.count - 1]
            from_row = last.caret.row
            from_col = last.caret.col
        var nrow = from_row + delta
        if nrow < 0 or nrow >= b.line_count:
            return
        self.selmodel.add_caret(nrow, self._clamp_col(nrow, from_col))
        self._reveal_row(nrow)

    # Replays an edit already applied to the primary caret at every extra
    # caret, all in ONE undo step. kind: "text" (with text), "backspace",
    # "enter", "delete". Each edit is described as a replaced region
    # (start, old_end) -> new_end, and every OTHER caret - the primary and the
    # extras already processed - is transformed through it. The previous
    # version relied on processing order alone, which kept unprocessed carets
    # valid but left processed ones behind when a later edit earlier on the
    # same line shifted them: the second keystroke landed a column off.
    def _apply_to_extra(self, kind, text):
        if self.selmodel.count <= 1:
            return
        var b = self.buf()
        var prim = Pos(b.cursor_row, b.cursor_col)
        var was = b.hold
        b.hold = true
        var i = 1
        while i < self.selmodel.count:
            var s = self.selmodel.sels[i]
            if s.caret.row < b.line_count and s.anchor.row < b.line_count:
                var st = s.start().clone()
                var en = s.end().clone()
                st.col = self._clamp_col(st.row, st.col)
                en.col = self._clamp_col(en.row, en.col)
                var e_start = st.clone()
                var e_old = en.clone()
                if kind == "backspace" and s.is_empty():
                    if st.col > 0:
                        e_start = Pos(st.row, st.col - 1)
                    elif st.row > 0:
                        e_start = Pos(st.row - 1, len(b.get_line(st.row - 1)))
                if kind == "delete" and s.is_empty():
                    if en.col < len(b.get_line(en.row)):
                        e_old = Pos(en.row, en.col + 1)
                    elif en.row + 1 < b.line_count:
                        e_old = Pos(en.row + 1, 0)
                if not s.is_empty():
                    b.delete_range(st.row, st.col, en.row, en.col)
                b.cursor_row = st.row
                b.cursor_col = st.col
                if kind == "text":
                    b.insert_text(text)
                elif kind == "backspace":
                    if s.is_empty():
                        b.delete_char_back()
                elif kind == "enter":
                    b.insert_newline()
                elif kind == "delete":
                    if s.is_empty():
                        b.delete_char_forward()
                var e_new = Pos(b.cursor_row, b.cursor_col)
                self._xform(prim, e_start, e_old, e_new)
                var j = 1
                while j < self.selmodel.count:
                    if j != i:
                        var o = self.selmodel.sels[j]
                        self._xform(o.caret, e_start, e_old, e_new)
                        self._xform(o.anchor, e_start, e_old, e_new)
                    j = j + 1
                s.caret.row = b.cursor_row
                s.caret.col = b.cursor_col
                s.anchor.row = b.cursor_row
                s.anchor.col = b.cursor_col
            i = i + 1
        b.hold = was
        b.cursor_row = prim.row
        b.cursor_col = self._clamp_col(prim.row, prim.col)

    # Moves p through an edit that replaced [start, old_end) with text ending
    # at new_end. Positions before the edit stay; positions inside a removed
    # region collapse to its end; positions after it shift.
    def _xform(self, p, start, old_end, new_end):
        if p.row < start.row or (p.row == start.row and p.col < start.col):
            return
        if p.row < old_end.row or (p.row == old_end.row and p.col < old_end.col):
            p.row = new_end.row
            p.col = new_end.col
            return
        if p.row == old_end.row:
            p.col = new_end.col + (p.col - old_end.col)
            p.row = new_end.row
        else:
            p.row = p.row + (new_end.row - old_end.row)

    # Ctrl+D: select the word, then add the next occurrence as another
    # selection, as VS Code does. Typing then replaces every occurrence.
    def _add_next_occurrence(self):
        if not self._is_text():
            return
        var b = self.buf()
        var d = self.doc()
        var g = self._sel_range()
        if g == none:
            var w = b.word_at(b.cursor_row, b.cursor_col)
            if w[1] <= w[0]:
                return
            d.sel_on = true
            d.sel_row = b.cursor_row
            d.sel_col = w[0]
            b.cursor_col = w[1]
            self.status_msg = "Ctrl+D again adds the next occurrence"
            return
        var needle = self._sel_text()
        if needle == "" or string_find(needle, "\n") >= 0:
            return
        # Search after the last selection (primary or extra).
        var from_r = g[2]
        var from_c = g[3]
        if self.selmodel.count > 1:
            var last = self.selmodel.sels[self.selmodel.count - 1]
            from_r = last.end().row
            from_c = last.end().col
        var hit = self._find_from(needle, from_r, from_c)
        if hit == none:
            self.status_msg = "No more occurrences of '" + needle + "'"
            return
        if hit[0] == g[0] and hit[1] == g[1]:
            self.status_msg = "All occurrences of '" + needle + "' are selected"
            return
        if self._add_selection(hit[0], hit[1], hit[0], hit[1] + len(needle)):
            self._reveal_row(hit[0])
            self.status_msg = str(self.selmodel.count) + " selections"
        else:
            self.status_msg = "All occurrences of '" + needle + "' are selected"

    # Next occurrence at or after (row, col), wrapping once.
    def _find_from(self, needle, row, col):
        var b = self.buf()
        var r = row
        var c = col
        var n = 0
        while n <= b.line_count:
            var line = b.get_line(r)
            var at = -1
            if c <= len(line):
                var rest = string_slice(line, c, len(line))
                var k = string_find(rest, needle)
                if k >= 0:
                    at = c + k
            if at >= 0:
                return [r, at]
            r = r + 1
            c = 0
            if r >= b.line_count:
                r = 0
            n = n + 1
        return none

    def _select_all_occurrences(self):
        if not self._is_text():
            return
        var needle = self._selected_word()
        if needle == "" or string_find(needle, "\n") >= 0:
            return
        var b = self.buf()
        var d = self.doc()
        var whole = self._sel_range() == none
        var hits = self._occurrences(needle, whole)
        if len(hits) == 0:
            return
        self._clear_extra_carets()
        var first = hits[0]
        d.sel_on = true
        d.sel_row = first[0]
        d.sel_col = first[1]
        b.cursor_row = first[0]
        b.cursor_col = first[1] + len(needle)
        var i = 1
        while i < len(hits):
            self._add_selection(hits[i][0], hits[i][1], hits[i][0], hits[i][1] + len(needle))
            i = i + 1
        self.status_msg = str(len(hits)) + " occurrences selected"

    # Every [row, col] of needle in the active buffer. whole: word boundaries.
    def _occurrences(self, needle, whole):
        var out = []
        var b = self.buf()
        var r = 0
        while r < b.line_count and len(out) < 5000:
            var line = b.get_line(r)
            var frm = 0
            var guard = 0
            while frm <= len(line) and guard < 1000:
                var rest = string_slice(line, frm, len(line))
                var k = string_find(rest, needle)
                if k < 0:
                    frm = len(line) + 1
                else:
                    var at = frm + k
                    if not whole or self._is_whole(line, at, len(needle)):
                        out.append([r, at])
                    frm = at + len(needle)
                    if len(needle) == 0:
                        frm = frm + 1
                guard = guard + 1
            r = r + 1
        return out

    def _is_whole(self, line, at, n):
        var b = self.buf()
        if b == none:
            return true
        if at > 0 and b._is_word(string_slice(line, at - 1, at)):
            return false
        if at + n < len(line) and b._is_word(string_slice(line, at + n, at + n + 1)):
            return false
        return true

    # ══ find / replace ════════════════════════════════════════════════════════
    def _open_find(self, replace):
        if not self._is_text():
            return
        self.find_open = true
        self.find_replace_mode = replace
        self.focus = "find"
        self.find_field = 0
        var s = self._sel_text()
        if s != "" and string_find(s, "\n") < 0:
            self.find_query = s
        self._find_run()

    # All matches in the active buffer, honouring Match Case, Match Whole Word
    # and Use Regular Expression. Rebuilt only when the query, the options or
    # the text change - never per frame.
    def _find_run(self):
        self.find_hits = []
        self.find_n = 0
        self.find_error = ""
        if not self._is_text() or self.find_query == "":
            return
        var b = self.buf()
        var q = self.find_query
        var ql = q
        if not self.find_case:
            ql = string_lower(q)
        var r = 0
        while r < b.line_count and self.find_n < 5000:
            var line = b.get_line(r)
            if self.find_regex:
                var ms = re_findall(q, line)
                if ms == none:
                    self.find_error = "Invalid regular expression"
                    return
                var frm = 0
                var mi = 0
                while mi < len(ms):
                    var m = ms[mi]
                    if len(m) > 0:
                        var k = string_find(string_slice(line, frm, len(line)), m)
                        if k >= 0:
                            self.find_hits.append([r, frm + k, len(m)])
                            self.find_n = self.find_n + 1
                            frm = frm + k + len(m)
                    mi = mi + 1
            else:
                var hay = line
                if not self.find_case:
                    hay = string_lower(line)
                var from2 = 0
                var guard = 0
                while from2 <= len(hay) and guard < 2000:
                    var k2 = string_find(string_slice(hay, from2, len(hay)), ql)
                    if k2 < 0:
                        from2 = len(hay) + 1
                    else:
                        var at = from2 + k2
                        if not self.find_word or self._is_whole(line, at, len(q)):
                            self.find_hits.append([r, at, len(q)])
                            self.find_n = self.find_n + 1
                        from2 = at + len(q)
                    guard = guard + 1
            r = r + 1
        # The current match is the first one at or after the caret.
        self.find_index = 0
        var i = 0
        while i < self.find_n:
            var h = self.find_hits[i]
            if h[0] > b.cursor_row or (h[0] == b.cursor_row and h[1] >= b.cursor_col - len(q)):
                self.find_index = i
                i = self.find_n
            i = i + 1
        self._find_select_current(false)

    def _find_select_current(self, move_caret):
        if self.find_n == 0:
            return
        var h = self.find_hits[self.find_index]
        if move_caret:
            var d = self.doc()
            d.sel_on = true
            d.sel_row = h[0]
            d.sel_col = h[1]
            d.buf.cursor_row = h[0]
            d.buf.cursor_col = h[1] + h[2]
        self._reveal_row_center(h[0])

    def _find_step(self, delta):
        if self.find_n == 0:
            self._find_run()
            if self.find_n == 0:
                return
        self.find_index = (self.find_index + delta + self.find_n) % self.find_n
        self._find_select_current(true)

    def _replace_one(self):
        if not self._can_edit() or self.find_n == 0:
            return
        var h = self.find_hits[self.find_index]
        var b = self.buf()
        b.begin_group()
        b.delete_range(h[0], h[1], h[0], h[1] + h[2])
        b.insert_text(self._replacement_for(b.get_line(h[0]), h))
        b.begin_group()
        self._after_edit()
        var idx = self.find_index
        self._find_run()
        if self.find_n > 0:
            self.find_index = idx % self.find_n
            self._find_select_current(true)

    def _replacement_for(self, line, h):
        if self.find_regex:
            var matched = string_slice(line, h[1], h[1] + h[2])
            var out = re_sub(self.find_query, self.find_replace, matched)
            if out != none:
                return out
        return self.find_replace

    def _replace_all(self):
        if not self._can_edit() or self.find_n == 0:
            return
        var b = self.buf()
        var n = self.find_n
        b.begin_group()
        var was = b.hold
        b.hold = true
        var i = self.find_n - 1
        while i >= 0:
            var h = self.find_hits[i]
            var rep = self._replacement_for(b.get_line(h[0]), h)
            b.delete_range(h[0], h[1], h[0], h[1] + h[2])
            b.cursor_row = h[0]
            b.cursor_col = h[1]
            b.insert_text(rep)
            i = i - 1
        b.hold = was
        b.begin_group()
        self._after_edit()
        self._find_run()
        self._notify("Replaced " + str(n) + " occurrence(s)", "ok")

    # ══ quick input sources ═══════════════════════════════════════════════════
    # Ctrl+P opens Quick Open over files; the first character switches mode
    # exactly as in VS Code: ">" commands, ":" go to line, "@" symbols in the
    # file, "#" symbols in the workspace.
    def _qi_focus(self):
        if self.focus != "qi":
            self.focus_before_qi = self.focus
        self.focus = "qi"

    def _open_palette(self, prefix):
        self._qi_focus()
        self.qi.open("files", "", "", [], prefix)
        self._qi_mode_for_value()

    def _qi_mode_for_value(self):
        var v = self.qi.value
        var kind = "files"
        if string_startswith(v, ">"):
            kind = "commands"
        elif string_startswith(v, ":"):
            kind = "line"
        elif string_startswith(v, "@"):
            kind = "symbols"
        elif string_startswith(v, "#"):
            kind = "wsymbols"
        if kind == self.qi.kind and len(self.qi.items) > 0:
            self.qi.refilter()
            return
        self.qi.kind = kind
        self.qi.action = kind
        if kind == "commands":
            self.qi.strip_prefix = ">"
            self.qi.placeholder = "Type the name of a command to run"
            self.qi.set_items(self._command_items())
        elif kind == "line":
            self.qi.strip_prefix = ":"
            self.qi.set_items([])
            self._qi_line_items()
        elif kind == "symbols":
            self.qi.strip_prefix = "@"
            self.qi.placeholder = "Go to symbol in editor"
            self.qi.set_items(self._symbol_items())
        elif kind == "wsymbols":
            self.qi.strip_prefix = "#"
            self.qi.placeholder = "Go to symbol in workspace"
            self.qi.set_items(self._workspace_symbol_items())
        else:
            self.qi.strip_prefix = ""
            self.qi.placeholder = "Search files by name (append : to go to line or @ to go to symbol)"
            self.qi.set_items(self._file_items())

    def _qi_value_changed(self):
        var k = self.qi.kind
        if k == "files" or k == "commands" or k == "line" or k == "symbols" or k == "wsymbols":
            self._qi_mode_for_value()
            if self.qi.kind == "line":
                self._qi_line_items()
        else:
            self.qi.refilter()
            if k == "path":
                self._path_items_refresh()

    def _command_items(self):
        var out = []
        var now = time_ms()
        var i = 0
        while i < self.reg.n:
            var id = self.reg.order[i]
            if id != "developer.dumpHitMap" and self._command_enabled(id):
                var c = self.reg.get(id)
                var it = QuickItem(c.label, "", id, "")
                it.keys = c.keys
                it.boost = self.frecency.score(id, now)
                out.append(it)
            i = i + 1
        # Recently used first when nothing is typed, as VS Code does.
        out = sorted(out, key=lambda q: q.boost, reverse=true)
        var j = 0
        while j < len(out):
            if out[j].boost > 0.05 and j == 0:
                out[j].group = "recently used"
            elif j > 0 and out[j - 1].boost > 0.05 and out[j].boost <= 0.05:
                out[j].group = "other commands"
            j = j + 1
        return out

    def _qi_line_items(self):
        var q = self.qi.query()
        var items = []
        if not self._is_text():
            self.qi.placeholder = "Open a text editor first to go to a line"
        else:
            var b = self.buf()
            var total = b.line_count
            if q == "":
                items.append(QuickItem("Current line: " + str(b.cursor_row + 1) + ", Character: " + str(b.cursor_col + 1) + ". Type a line number between 1 and " + str(total) + " to navigate to.", "", "", ""))
            else:
                var parts = string_split(q, ":")
                var ln = self._int_or(parts[0], -1)
                var cn = 1
                if len(parts) > 1:
                    cn = self._int_or(parts[1], 1)
                if ln >= 1:
                    if ln > total:
                        ln = total
                    items.append(QuickItem("Go to line " + str(ln) + ", character " + str(cn), "", str(ln) + ":" + str(cn), ""))
                else:
                    items.append(QuickItem("Not a line number: " + q, "", "", ""))
        self.qi.items = items
        self.qi.shown = items
        self.qi.n = len(items)
        self.qi.sel = 0

    def _int_or(self, s, dflt):
        var t = string_strip(s)
        if t == "":
            return dflt
        var i = 0
        while i < len(t):
            var ch = string_slice(t, i, i + 1)
            if ch < "0" or ch > "9":
                return dflt
            i = i + 1
        return int(t)

    # Every file under the workspace (not just the expanded tree rows),
    # cached until the explorer changes. Build output and VCS folders skipped.
    def _workspace_files(self):
        if self.ws_files_root == self.ws.root and self.ws_files != none:
            return self.ws_files
        var out = []
        if self.ws.root != "":
            self._walk_files(self.ws.root, 0, out)
        self.ws_files = out
        self.ws_files_root = self.ws.root
        return out

    def _walk_files(self, dir, depth, out):
        if depth > 8 or len(out) >= 4000:
            return
        var ents = os_listdir(dir)
        if ents == none:
            return
        ents = sorted(ents)
        var i = 0
        while i < len(ents):
            var nm = ents[i]
            if not string_startswith(nm, ".") and nm != "build" and nm != "node_modules" and nm != "__pycache__":
                var full = path_join(dir, nm)
                if os_isdir(full):
                    self._walk_files(full, depth + 1, out)
                else:
                    out.append(full)
            i = i + 1

    def _file_items(self):
        var out = []
        var now = time_ms()
        var files = self._workspace_files()
        var i = 0
        while i < len(files):
            var p = files[i]
            var it = QuickItem(os_path_basename(p), self._rel(os_path_dirname(p)), p, "file")
            if self.ws.root != "" and os_path_dirname(p) == self.ws.root:
                it.detail = ""
            it.boost = self.frecency.score("file:" + p, now)
            out.append(it)
            i = i + 1
        # Open editors and recently opened files first.
        out = sorted(out, key=lambda q: q.boost, reverse=true)
        if len(out) > 0 and out[0].boost > 0.05:
            out[0].group = "recently opened"
        var j = 1
        while j < len(out):
            if out[j - 1].boost > 0.05 and out[j].boost <= 0.05:
                out[j].group = "files"
            j = j + 1
        return out

    def _symbol_items(self):
        var out = []
        if not self._is_text():
            return out
        var syms = self._doc_symbols(self.buf())
        var i = 0
        while i < len(syms):
            var s = syms[i]
            var it = QuickItem(s[0], s[1] + "  line " + str(s[2] + 1), str(s[2]) + ":" + str(s[3]), s[1])
            out.append(it)
            i = i + 1
        return out

    def _workspace_symbol_items(self):
        var out = []
        var files = self._workspace_files()
        var i = 0
        while i < len(files) and len(out) < 3000:
            var p = files[i]
            if os_path_ext(p) == ".ny" and file_size(p) < 600000:
                var text = read_file(p)
                if text != none:
                    var lines = string_split(text, "\n")
                    var r = 0
                    while r < len(lines):
                        var sym = self._symbol_on_line(lines[r])
                        if sym != none:
                            var it = QuickItem(sym[0], self._rel(p) + ":" + str(r + 1), p + "|" + str(r), sym[1])
                            out.append(it)
                        r = r + 1
            i = i + 1
        return out

    # [name, kind, row, col] for class / def / top-level var declarations.
    def _doc_symbols(self, b):
        var out = []
        var r = 0
        while r < b.line_count:
            var sym = self._symbol_on_line(b.get_line(r))
            if sym != none:
                out.append([sym[0], sym[1], r, sym[2]])
            r = r + 1
        return out

    def _symbol_on_line(self, raw):
        var st = string_strip(raw)
        var kind = ""
        var rest = ""
        if string_startswith(st, "class "):
            kind = "class"
            rest = string_slice(st, 6, len(st))
        elif string_startswith(st, "def "):
            kind = "function"
            rest = string_slice(st, 4, len(st))
        elif string_startswith(st, "struct "):
            kind = "struct"
            rest = string_slice(st, 7, len(st))
        elif string_startswith(st, "enum "):
            kind = "enum"
            rest = string_slice(st, 5, len(st))
        elif string_startswith(st, "interface "):
            kind = "interface"
            rest = string_slice(st, 10, len(st))
        elif string_startswith(raw, "var "):
            kind = "variable"
            rest = string_slice(st, 4, len(st))
        if kind == "":
            return none
        var cut = len(rest)
        var stops = "(: =,"
        var i = 0
        while i < len(rest):
            if string_find(stops, string_slice(rest, i, i + 1)) >= 0:
                cut = i
                i = len(rest)
            i = i + 1
        var name = string_strip(string_slice(rest, 0, cut))
        if name == "":
            return none
        var indent = 0
        while indent < len(raw) and string_slice(raw, indent, indent + 1) == " ":
            indent = indent + 1
        if kind == "function" and indent > 0:
            kind = "method"
        return [name, kind, indent]

    # ── prompts and pickers ──────────────────────────────────────────────────
    def _open_prompt(self, action, title, hint, value):
        self._qi_focus()
        self.qi.open("prompt", title, hint, [], value)
        self.qi.action = action
        self.qi.free_text = true

    # A simple file dialog in the quick input, like VS Code's own simple
    # dialog: the typed path, its folder's entries as completions (Tab or a
    # click on a folder descends into it), Enter to accept.
    def _open_path_prompt(self, action, title, hint, value, dirs_only):
        self._qi_focus()
        self.qi.open("path", title, hint, [], value)
        self.qi.action = action
        self.qi.free_text = true
        self.qi.data = none
        self.path_dirs_only = dirs_only
        self._path_items_refresh()

    def _path_items_refresh(self):
        var v = self.qi.value
        var dir = v
        var stem = ""
        if not string_endswith(v, "/"):
            dir = os_path_dirname(v)
            stem = os_path_basename(v)
        if dir == "":
            dir = "/"
        var items = []
        if os_isdir(dir):
            var ents = os_listdir(dir)
            if ents != none:
                ents = sorted(ents)
                var up = os_path_dirname(string_slice(dir, 0, len(dir) - 1))
                if string_endswith(dir, "/") and len(dir) > 1:
                    items.append(QuickItem("..", "parent folder", up + "/", "folder"))
                var i = 0
                while i < len(ents) and len(items) < 400:
                    var nm = ents[i]
                    var full = path_join(dir, nm)
                    var isd = os_isdir(full)
                    if (not self.path_dirs_only or isd) and (not string_startswith(nm, ".") or string_startswith(stem, ".")):
                        var lower_ok = stem == "" or string_startswith(string_lower(nm), string_lower(stem))
                        if lower_ok:
                            var ic = "file"
                            var dv = full
                            if isd:
                                ic = "folder"
                                dv = full + "/"
                            items.append(QuickItem(nm, "", dv, ic))
                    i = i + 1
        self.qi.items = items
        self.qi.shown = items
        self.qi.n = len(items)
        if self.qi.sel >= self.qi.n:
            self.qi.sel = 0

    def _pick(self, action, title, labels, values, current):
        var items = []
        var i = 0
        var sel = 0
        while i < len(labels):
            var it = QuickItem(labels[i], "", values[i], "")
            if values[i] == current:
                it.detail = "current"
                sel = i
            items.append(it)
            i = i + 1
        self._qi_focus()
        self.qi.open("pick", title, title, items, "")
        self.qi.action = action
        self.qi.sel = sel

    def _theme_picker(self):
        var cur = "dark"
        if not self.th.dark:
            cur = "light"
        self._pick("theme", "Select Color Theme", ["Dark+ (default dark)", "Light+ (default light)"], ["dark", "light"], cur)

    def _indent_picker(self):
        self._pick("indent", "Select Tab Size", ["Indent Using Spaces: 2", "Indent Using Spaces: 4", "Indent Using Spaces: 8"], ["2", "4", "8"], str(self.tab_size))

    def _eol_picker(self):
        if not self._is_text():
            return
        var cur = "LF"
        if self.buf().eol == "\r\n":
            cur = "CRLF"
        self._pick("eol", "Select End of Line Sequence", ["LF", "CRLF"], ["LF", "CRLF"], cur)

    def _encoding_picker(self):
        if not self._is_text():
            return
        var cur = "utf8"
        if self.doc().bom:
            cur = "utf8bom"
        self._pick("encoding", "Save with Encoding", ["UTF-8", "UTF-8 with BOM"], ["utf8", "utf8bom"], cur)

    def _language_picker(self):
        if not self._is_text():
            return
        self._pick("lang", "Select Language Mode", ["Nython (nython)", "Markdown (markdown)", "Plain Text (plaintext)"], ["nython", "markdown", "plaintext"], self.doc().lang)

    def _open_recent_picker(self):
        var labels = []
        var values = []
        var i = 0
        while i < len(self.recent_folders):
            labels.append(os_path_basename(self.recent_folders[i]) + "   (folder)  " + self.recent_folders[i])
            values.append("dir:" + self.recent_folders[i])
            i = i + 1
        i = 0
        while i < len(self.recent):
            labels.append(os_path_basename(self.recent[i]) + "   " + self.recent[i])
            values.append("file:" + self.recent[i])
            i = i + 1
        if len(labels) == 0:
            self._notify("No recently opened files or folders", "info")
            return
        self._pick("recent", "Open Recent", labels, values, "")

    # Enter / click in the quick input.
    def _qi_accept(self, item):
        var action = self.qi.action
        var value = self.qi.value
        var data = self.qi.data
        if action == "path" or self.qi.kind == "path":
            action = self.qi.action
            if item != none and (not os_exists(self._strip_slash(value)) or self.qi.sel_moved):
                value = item.value
            if item != none and os_isdir(self._strip_slash(value)) and action != "openfolder" and action != "newproject" and action != "saveas":
                self.qi.set_value(value)
                self.qi.sel_moved = false
                self._path_items_refresh()
                return
        self.qi.close()
        self.focus = self.focus_before_qi
        if action == "commands":
            if item != none:
                self._exec(item.value, none)
        elif action == "files":
            if item != none:
                self.frecency.touch("file:" + item.value, time_ms())
                self._open_path(item.value, -1, 0)
        elif action == "line":
            if item != none and item.value != "":
                var p = string_split(item.value, ":")
                self._goto(int(p[0]) - 1, int(p[1]) - 1)
                self.focus = "editor"
        elif action == "symbols":
            if item != none:
                var p2 = string_split(item.value, ":")
                self._goto(int(p2[0]), int(p2[1]))
                self.focus = "editor"
        elif action == "wsymbols":
            if item != none:
                var bar = string_find(item.value, "|")
                self._open_path(string_slice(item.value, 0, bar), int(string_slice(item.value, bar + 1, len(item.value))), 0)
        elif action == "openfile":
            self._open_path(self._strip_slash(value), -1, 0)
        elif action == "openfolder":
            self._open_folder(self._strip_slash(value))
        elif action == "saveas":
            self._accept_save_as(self._strip_slash(value), data)
        elif action == "newproject":
            self._new_project(self._strip_slash(value))
        elif action == "openproject":
            self._open_project(self._strip_slash(value))
        elif action == "newfile" or action == "newfolder":
            self._explorer_create(action == "newfolder", data, value)
        elif action == "rename":
            self._explorer_do_rename(data, value)
        elif action == "renamesymbol":
            self._rename_symbol(data, string_strip(value))
        elif action == "addtoken":
            self._add_highlight_token(value)
        elif action == "newbranch":
            var bn = string_strip(value)
            if bn != "":
                if self.git.create_branch(bn):
                    self._notify("Created and switched to branch " + bn, "ok")
                else:
                    self._notify("Could not create branch " + bn + ": " + self.git.last_output, "err")
                self._scm_refresh()
        elif action == "addwatch":
            var wv = string_strip(value)
            if wv != "":
                self.watches.append(wv)
        elif action == "commitmsg":
            self.scm_msg = value
            self._git_command("git.commit", none)
        elif item != none:
            self._accept_pick(action, item.value)

    def _strip_slash(self, p):
        if len(p) > 1 and string_endswith(p, "/"):
            return string_slice(p, 0, len(p) - 1)
        return p

    def _accept_pick(self, action, v):
        if action == "theme":
            self._set_theme(v == "dark")
            self._save_settings()
        elif action == "indent":
            self.tab_size = int(v)
            self._save_settings()
            self._notify("Tab size: " + v, "info")
        elif action == "eol":
            var b = self.buf()
            var want = "\n"
            if v == "CRLF":
                want = "\r\n"
            if b.eol != want:
                b.eol = want
                # Changing line endings is an edit: it must be saved.
                b.saved_id = -1
                self._title_dirty = true
        elif action == "encoding":
            var nb = v == "utf8bom"
            if self.doc().bom != nb:
                self.doc().bom = nb
                self.buf().saved_id = -1
                self._title_dirty = true
        elif action == "lang":
            self.doc().lang = v
            self._hl_reset()
        elif action == "recent":
            if string_startswith(v, "dir:"):
                self._open_folder(string_slice(v, 4, len(v)))
            else:
                self._open_path(string_slice(v, 5, len(v)), -1, 0)
        elif action == "checkout":
            self._git_checkout(v)
        elif action == "runmode":
            self._exec(v, none)
        elif action == "explorerctx" or action == "ctx":
            self._exec(v, none)

    def _accept_save_as(self, path, data):
        if path == "" or data == none:
            return
        var d = data["doc"]
        if os_isdir(path):
            self._notify(path + " is a folder", "err")
            return
        if os_exists(path) and path != d.path and not data.has_key("confirmed"):
            data["confirmed"] = true
            self.pending_save_as = [path, data]
            self._modal("'" + os_path_basename(path) + "' already exists. Do you want to replace it?",
                        "A file with the same name already exists in " + os_path_dirname(path) + ". Replacing it will overwrite its current contents.",
                        [["Replace", "@saveas.replace", ""], ["Cancel", "@modal.cancel", ""]])
            return
        var dir = os_path_dirname(path)
        if dir != "" and not os_isdir(dir):
            self._notify("Folder does not exist: " + dir, "err")
            return
        if self._write_doc(d, path):
            self._notify("Saved " + d.title, "ok")
            var after = data["after"]
            if after == "close":
                var i = self._index_of(d)
                if i >= 0:
                    self._close_doc(i, true)
            elif after == "saveall":
                self._save_all()
            elif after == "quit":
                if self._dirty_count() == 0:
                    self._quit(true)
                else:
                    self._exec_modal_cmd("@quit.save", "")
            elif after == "closemany":
                self._exec_modal_cmd("@closemany.save", "")

    def _index_of(self, d):
        var i = 0
        while i < len(self.docs):
            if self.docs[i] == d:
                return i
            i = i + 1
        return -1

    # ══ modal dialogs ═════════════════════════════════════════════════════════
    def _modal(self, title, message, buttons):
        self.modal_open = true
        self.modal_title = title
        self.modal_msg = message
        self.modal_buttons = buttons
        self.modal_sel = 0
        self.focus_before_modal = self.focus
        self.focus = "modal"

    def _modal_close(self):
        self.modal_open = false
        self.focus = self.focus_before_modal
        if self.focus == "modal" or self.focus == "":
            self.focus = "editor"

    # The internal "@..." actions behind dialog buttons.
    def _exec_modal_cmd(self, cmd, arg):
        self._modal_close()
        if cmd == "@modal.cancel":
            self.pending_close = []
            return
        if cmd == "@close.save":
            var d = self.docs[arg]
            if d.kind == "untitled":
                self._prompt_save_as(d, "close")
                return
            if self._save_doc(d):
                self._close_doc(self._index_of(d), true)
        elif cmd == "@close.discard":
            self._close_doc(arg, true)
        elif cmd == "@closemany.save":
            var i = 0
            while i < len(self.pending_close):
                var d2 = self.docs[self.pending_close[i]]
                if d2.dirty():
                    if d2.kind == "untitled":
                        self._activate(self.pending_close[i])
                        self._prompt_save_as(d2, "closemany")
                        return
                    self._write_doc(d2, d2.path)
                i = i + 1
            self._close_indices(self.pending_close)
            self.pending_close = []
        elif cmd == "@closemany.discard":
            self._close_indices(self.pending_close)
            self.pending_close = []
        elif cmd == "@quit.save":
            var j = 0
            while j < len(self.docs):
                var d3 = self.docs[j]
                if d3.dirty():
                    if d3.kind == "untitled":
                        self._activate(j)
                        self._prompt_save_as(d3, "quit")
                        return
                    self._write_doc(d3, d3.path)
                j = j + 1
            self._quit(true)
        elif cmd == "@quit.discard":
            self._quit(true)
        elif cmd == "@saveas.replace":
            var ps = self.pending_save_as
            self.pending_save_as = none
            if ps != none:
                self._accept_save_as(ps[0], ps[1])
        elif cmd == "@delete.confirm":
            self._explorer_do_delete(arg)
        elif cmd == "@git.discard.confirm":
            self._git_discard(arg)
        elif cmd == "@about.copy":
            self._set_clipboard(self._about_text())
            self._notify("Copied version information", "info")

    # ══ run and build ═════════════════════════════════════════════════════════
    # The interpreter that runs programs: the binary the IDE itself runs in
    # (NYTHON_EXE, set by the launcher), else one beside the workspace, else
    # PATH. Looking only in the working directory meant Run failed whenever
    # the IDE was opened on a project folder.
    def _interpreter(self):
        var env = getenv("NYTHON_EXE")
        if env != none and env != "" and os_exists(env):
            return env
        var home = getenv("NYTHON_HOME")
        var cands = []
        if home != none and home != "":
            cands.append(path_join(home, "build/nython-cli"))
            cands.append(path_join(home, "build/nython"))
            cands.append(path_join(home, "nython"))
            cands.append(path_join(home, "nython.exe"))
        cands.append(path_join(getcwd(), "nython"))
        cands.append(path_join(getcwd(), "nython.exe"))
        var i = 0
        while i < len(cands):
            if os_exists(cands[i]):
                return cands[i]
            i = i + 1
        return "nython"

    def _q(self, s):
        return "'" + string_replace(s, "'", "'\\''") + "'"

    # The file to hand the interpreter: saved first if it lives on disk, else
    # a temporary copy of the buffer (an untitled editor can still be run).
    def _path_for_run(self, d):
        if d.kind == "file":
            if d.dirty():
                self._write_doc(d, d.path)
            return d.path
        self.run_seq = self.run_seq + 1
        var tmp = "/tmp/nyide_run_" + str(self.run_seq) + ".ny"
        write_file(tmp, d.buf.get_all_text())
        return tmp

    def _run_active(self, mode):
        if not self._is_text():
            self._notify("Open a Nython file to run it", "warn")
            return
        if self.job_running:
            self._notify("A program is already running - stop it first (Shift+F5)", "warn")
            return
        var d = self.doc()
        var path = self._path_for_run(d)
        var flag = ""
        if mode == "VM":
            flag = "--vm "
        elif mode == "Tokenize":
            flag = "--tokenize "
        elif mode == "AST":
            flag = "--ast "
        elif mode == "Disasm":
            flag = "--disasm "
        elif mode == "Profile":
            flag = "--profile "
        var exe = self._interpreter()
        var cwd = self.ws.root
        if cwd == "":
            cwd = os_path_dirname(path)
        self.job_mode = mode
        self.job_path = path
        self.job_doc = d
        if mode == "Tokenize" or mode == "AST" or mode == "Disasm":
            var out = os_exec("cd " + self._q(cwd) + " && " + self._q(exe) + " " + flag + self._q(path) + " < /dev/null 2>&1")
            self.inspect_lines = self._clean_lines(out, 3000)
            self.inspect_kind = mode
            self.inspect_scroll = 0
            self._show_panel("inspector")
            self._set_problems_for(path, "run", self._parse_diagnostics(out, path, cwd))
            self._notify(mode + ": " + str(len(self.inspect_lines)) + " lines", "info")
            return
        self._output_clear()
        self._output_write("> " + mode + "  " + self._rel(path), "cmd")
        self._show_panel("output")
        self._start_job(exe + " " + flag, path, cwd)

    # Runs the program in the background with its output streamed into the
    # panel as it is produced (see BgProc).
    def _start_job(self, cmdline, path, cwd):
        self.job_seq = self.job_seq + 1
        self.job = BgProc("/tmp/nyide_job_" + str(self.session_id) + "_" + str(self.job_seq))
        var parts = string_split(cmdline, " ")
        var exe = parts[0]
        var flag = string_slice(cmdline, len(exe), len(cmdline))
        self.job.start(self._q(exe) + flag + self._q(path), cwd)
        self.job_running = true
        self.job_t0 = time_ms()
        self.job_text = ""
        self.job_text_n = 0

    # Called every frame.
    def _poll_job(self):
        if not self.job_running:
            return
        var lines = self.job.poll(100)
        var i = 0
        while i < len(lines):
            self._job_line(lines[i])
            i = i + 1
        if len(lines) > 0:
            self._dirty = true
        if not self.job.running:
            self.job_running = false
            self.job_killed = self.job.killed
            self._finish_job(self.job.code)

    def _stop_job(self):
        if self.job_running:
            self.job.stop()

    def _job_line(self, raw):
        var ln = self._strip_ansi(raw)
        if self.job_mode == "Debug":
            # Program output is replayed from the recording step by step;
            # only errors are shown as they arrive.
            if string_find(ln, "Error") >= 0 or string_find(ln, "Uncaught") >= 0 or string_startswith(ln, "  at "):
                self._dbg_print(ln, "err")
            self.job_text = self.job_text + ln + "\n"
            return
        if ln == "__NY_PROFILE__":
            self.job_in_profile = true
            self._output_write("── profile (name, calls, total ms, self ms) ──", "info")
            return
        var kind = "out"
        if string_find(ln, "Error") >= 0 or string_find(ln, "error:") >= 0 or string_find(ln, "Uncaught") >= 0:
            kind = "err"
        self._output_write(ln, kind)
        self.job_text_n = self.job_text_n + 1
        if self.job_text_n < 400:
            self.job_text = self.job_text + ln + "\n"

    def _finish_job(self, code):
        var dt = time_ms() - self.job_t0
        self.job_running = false
        self.job_in_profile = false
        if self.job_mode == "Debug":
            var dprobs = self._parse_diagnostics(self.job_text, self.job_path, self.ws.root)
            self._set_problems_for(self.job_path, "run", dprobs)
            self.job_text = ""
            self.job_killed = false
            self._debug_loaded()
            return
        var probs = self._parse_diagnostics(self.job_text, self.job_path, self.ws.root)
        self._set_problems_for(self.job_path, "run", probs)
        self.job_text = ""
        self.job_text_n = 0
        if self.job_killed:
            self.job_killed = false
            self._output_write("[process stopped]", "warn")
            self.last_run_ok = false
        elif code == 0 and len(probs) == 0:
            self._output_write("[process exited with code 0 in " + str(dt) + " ms]", "ok")
            self._notify(self.job_mode + " finished in " + str(dt) + " ms", "ok")
            self.last_run_ok = true
        else:
            self._output_write("[process exited with code " + str(code) + "]", "err")
            var msg = self.job_mode + " failed"
            if len(probs) > 0:
                msg = msg + " - " + probs[0]["msg"]
            self._notify(msg, "err")
            self.last_run_ok = false
        self._dirty = true

    def _clean_lines(self, out, limit):
        var raw = string_split(out, "\n")
        var keep = []
        var i = 0
        while i < len(raw) and len(keep) < limit:
            var s = self._strip_ansi(raw[i])
            if string_strip(s) != "":
                keep.append(s)
            i = i + 1
        return keep

    def _strip_ansi(self, text):
        if string_find(text, "\x1b") < 0:
            return text
        var out = ""
        var i = 0
        var n = len(text)
        while i < n:
            var ch = string_slice(text, i, i + 1)
            if ch == "\x1b":
                while i < n and string_slice(text, i, i + 1) != "m":
                    i = i + 1
                i = i + 1
            else:
                out = out + ch
                i = i + 1
        return out

    # ── diagnostics ──────────────────────────────────────────────────────────
    # The formats the toolchain really emits (checked against both engines):
    #   file.ny:3:1: syntax error: Unexpected token: newline
    #   [Nython] Uncaught exception — NameError: 'f' is not defined at line 2, column 13
    #   [Nython] Uncaught exception — ValueError: bad thing        (+ "  at file.ny:2")
    #   VM Error: __exc__:NameError:'f' is not defined at line 2
    #   [VMError] ZeroDivisionError: division by zero
    # The old parser looked only for the word "line", so a syntax error's
    # file:line:col location was never recognised.
    def _parse_diagnostics(self, out, path, cwd):
        var probs = []
        if out == none:
            return probs
        var lines = string_split(self._strip_ansi(out), "\n")
        var i = 0
        while i < len(lines):
            var ln = string_strip(lines[i])
            var p = self._diag_located(ln, cwd)
            if p != none:
                probs.append(p)
            elif string_find(ln, "Uncaught exception") >= 0 or string_startswith(ln, "VM Error:") or string_startswith(ln, "[VMError]") or string_startswith(ln, "[IDE Error]"):
                var msg = ln
                var dash = string_find(ln, "exception")
                if dash >= 0:
                    msg = string_strip(string_slice(ln, dash + 9, len(ln)))
                    while len(msg) > 0 and (string_startswith(msg, "\xe2") or string_startswith(msg, "\x80") or string_startswith(msg, "\x94") or string_startswith(msg, "-") or string_startswith(msg, " ")):
                        msg = string_slice(msg, 1, len(msg))
                if string_startswith(msg, "VM Error: __exc__:"):
                    msg = string_slice(msg, 18, len(msg))
                    var c1 = string_find(msg, ":")
                    if c1 > 0:
                        msg = string_slice(msg, 0, c1) + ": " + string_slice(msg, c1 + 1, len(msg))
                if string_startswith(msg, "[VMError] "):
                    msg = string_slice(msg, 10, len(msg))
                var row = 0
                var col = 0
                var at = string_find(msg, " at line ")
                if at >= 0:
                    var tail = string_slice(msg, at + 9, len(msg))
                    row = self._leading_int(tail)
                    var cc = string_find(tail, "column ")
                    if cc >= 0:
                        col = self._leading_int(string_slice(tail, cc + 7, len(tail)))
                    msg = string_slice(msg, 0, at)
                # "  at file.ny:LINE" on the next line (the interpreter's
                # statement-location trailer).
                if row == 0 and i + 1 < len(lines):
                    var nxt = string_strip(lines[i + 1])
                    if string_startswith(nxt, "at "):
                        var loc = self._diag_located(string_slice(nxt, 3, len(nxt)) + ": x", cwd)
                        if loc != none:
                            row = loc["line"]
                            col = loc["col"]
                            i = i + 1
                probs.append({"sev": "err", "msg": msg, "path": path, "line": row, "col": col, "src": "runtime"})
            i = i + 1
        return probs

    # "<path>:<line>:<col>: <message>" or "<path>:<line>: <message>".
    def _diag_located(self, ln, cwd):
        var ny = string_find(ln, ".ny:")
        if ny < 0:
            return none
        var file = string_slice(ln, 0, ny + 3)
        var rest = string_slice(ln, ny + 4, len(ln))
        var row = self._leading_int(rest)
        if row <= 0:
            return none
        var after = string_slice(rest, len(str(row)), len(rest))
        var col = 0
        if string_startswith(after, ":"):
            var c = self._leading_int(string_slice(after, 1, len(after)))
            if c > 0:
                col = c
                after = string_slice(after, 1 + len(str(c)), len(after))
        var msg = string_strip(after)
        if string_startswith(msg, ":"):
            msg = string_strip(string_slice(msg, 1, len(msg)))
        var sev = "err"
        if string_startswith(msg, "warning"):
            sev = "warn"
        var full = file
        if not string_startswith(file, "/") and cwd != "":
            full = path_join(cwd, file)
        return {"sev": sev, "msg": msg, "path": full, "line": row, "col": col, "src": "syntax"}

    def _leading_int(self, s):
        var digits = ""
        var i = 0
        while i < len(s):
            var ch = string_slice(s, i, i + 1)
            if ch >= "0" and ch <= "9":
                digits = digits + ch
            else:
                i = len(s)
            i = i + 1
        if digits == "":
            return 0
        return int(digits)

    # Problems are kept per (path, source) so a syntax re-check does not wipe
    # a runtime error and vice versa.
    def _set_problems_for(self, path, src, probs):
        var keep = []
        var i = 0
        while i < len(self.problems):
            var p = self.problems[i]
            if not (p["path"] == path and p["src"] == src) and not (src == "run" and p["path"] == path and p["src"] == "runtime"):
                if not (src == "run" and p["src"] == "syntax" and p["path"] == path):
                    keep.append(p)
            i = i + 1
        var j = 0
        while j < len(probs):
            keep.append(probs[j])
            j = j + 1
        self.problems = keep
        self._count_problems()

    def _count_problems(self):
        var e = 0
        var w = 0
        var i = 0
        while i < len(self.problems):
            if self.problems[i]["sev"] == "err":
                e = e + 1
            else:
                w = w + 1
            i = i + 1
        self.n_errors = e
        self.n_warnings = w
        self._status_cache_key = ""

    # Syntax check without running: `--ast` parses and reports, executes
    # nothing. Run on open, on save and shortly after typing stops, so
    # Problems reflects the text as it is, not as it was at the last Run.
    def _check_file(self, d):
        if d == none or d.buf == none or d.lang != "nython":
            return
        var path = d.path
        var target = path
        if d.kind != "file" or d.dirty():
            self.run_seq = self.run_seq + 1
            target = "/tmp/nyide_check_" + str(self.session_id) + ".ny"
            write_file(target, d.buf.get_all_text())
        if target == "":
            return
        var out = os_exec(self._q(self._interpreter()) + " --ast " + self._q(target) + " 2>&1 > /dev/null < /dev/null")
        var probs = self._parse_diagnostics(out, target, "")
        var key = path
        if key == "":
            key = "untitled:" + d.title
        var i = 0
        while i < len(probs):
            probs[i]["path"] = key
            probs[i]["src"] = "syntax"
            i = i + 1
        self._set_problems_for(key, "syntax", probs)
        d.problem_stamp = d.buf.state_id()

    def _next_problem(self, dir):
        if len(self.problems) == 0:
            self.status_msg = "No problems"
            return
        self.problem_cursor = (self.problem_cursor + dir + len(self.problems)) % len(self.problems)
        self._open_problem(self.problem_cursor)

    def _open_problem(self, i):
        if i < 0 or i >= len(self.problems):
            return
        var p = self.problems[i]
        var path = p["path"]
        var row = p["line"] - 1
        if row < 0:
            row = 0
        var col = p["col"] - 1
        if col < 0:
            col = 0
        if string_startswith(path, "untitled:"):
            var t = string_slice(path, 9, len(path))
            var k = 0
            while k < len(self.docs):
                if self.docs[k].title == t:
                    self._activate(k)
                    self._goto(row, col)
                k = k + 1
        elif string_startswith(path, "/tmp/nyide_run_"):
            if self.job_doc != none:
                var ji = self._index_of(self.job_doc)
                if ji >= 0:
                    self._activate(ji)
                    self._goto(row, col)
        else:
            self._open_path(path, row, col)
        self.status_msg = p["msg"]

    # ══ settings ══════════════════════════════════════════════════════════════
    # Workspace preferences live in .nyide in the workspace root (plain
    # "key = value"), editable in the IDE: Preferences: Open Settings opens it
    # and saving it applies it. Recently opened files and folders are
    # per-user, in ~/.nyide_state.
    def _settings_path(self):
        var root = self.ws.root
        if root == "":
            root = getcwd()
        return path_join(root, ".nyide")

    def _settings_text(self):
        var mode = "dark"
        if not self.th.dark:
            mode = "light"
        var body = "# NythonIDE settings. Save this file (Ctrl+S) to apply changes.\n"
        body = body + "theme = " + mode + "\n"
        body = body + "font_size = " + str(self.font_size) + "\n"
        body = body + "tab_size = " + str(self.tab_size) + "\n"
        body = body + "sidebar_width = " + str(self.SIDEBAR_W) + "\n"
        body = body + "minimap = " + str(self.minimap_on) + "\n"
        body = body + "panel = " + str(self.panel_open) + "\n"
        body = body + "sidebar = " + str(self.sidebar_open) + "\n"
        body = body + "render_whitespace = " + str(self.show_whitespace) + "\n"
        body = body + "# off | afterDelay\n"
        body = body + "auto_save = " + self.auto_save + "\n"
        return body

    def _save_settings(self):
        if self.loading_settings:
            return
        write_file(self._settings_path(), self._settings_text())
        # Keep an open settings editor in step with what was just written.
        var i = self._find_doc(self._settings_path())
        if i >= 0 and not self.docs[i].dirty():
            self.docs[i].buf = EditorBuffer(".nyide", self._settings_text())
            self.docs[i].buf.coalesce = true

    def _load_settings(self):
        var path = self._settings_path()
        if not os_exists(path):
            return false
        var text = read_file(path)
        if text == none or text == "":
            return false
        self.loading_settings = true
        var lines = string_split(text, "\n")
        var i = 0
        while i < len(lines):
            var ln = string_strip(lines[i])
            if len(ln) > 0 and not string_startswith(ln, "#"):
                var eq = string_find(ln, "=")
                if eq > 0:
                    var k = string_strip(string_slice(ln, 0, eq))
                    var v = string_strip(string_slice(ln, eq + 1, len(ln)))
                    if k == "theme":
                        self._set_theme(v == "dark")
                    elif k == "font_size":
                        self._zoom(self._int_or(v, 13) - self.font_size)
                    elif k == "tab_size":
                        var ts = self._int_or(v, 4)
                        if ts >= 1 and ts <= 16:
                            self.tab_size = ts
                    elif k == "sidebar_width":
                        var sw = self._int_or(v, 258)
                        if sw >= 150 and sw <= 700:
                            self.SIDEBAR_W = sw
                    elif k == "minimap":
                        self.minimap_on = (v == "true")
                    elif k == "panel":
                        self.panel_open = (v == "true")
                    elif k == "sidebar":
                        self.sidebar_open = (v == "true")
                    elif k == "render_whitespace":
                        self.show_whitespace = (v == "true")
                    elif k == "auto_save":
                        if v == "afterDelay" or v == "off":
                            self.auto_save = v
            i = i + 1
        self.loading_settings = false
        self._layout()
        return true

    def _open_settings_file(self):
        var p = self._settings_path()
        if not os_exists(p):
            write_file(p, self._settings_text())
        self._open_path(p, -1, 0)

    def _state_path(self):
        var home = getenv("HOME")
        if home == none or home == "":
            home = getenv("USERPROFILE")
        if home == none or home == "":
            return ""
        return path_join(home, ".nyide_state")

    def _load_state(self):
        var p = self._state_path()
        if p == "" or not os_exists(p):
            return
        var text = read_file(p)
        if text == none:
            return
        var lines = string_split(text, "\n")
        var i = 0
        while i < len(lines):
            var ln = lines[i]
            if string_startswith(ln, "file=") and len(self.recent) < 12:
                var fp = string_slice(ln, 5, len(ln))
                if os_exists(fp):
                    self.recent.append(fp)
            elif string_startswith(ln, "folder=") and len(self.recent_folders) < 8:
                var dp = string_slice(ln, 7, len(ln))
                if os_isdir(dp):
                    self.recent_folders.append(dp)
            i = i + 1

    def _save_state(self):
        var p = self._state_path()
        if p == "":
            return
        var body = ""
        var i = 0
        while i < len(self.recent_folders):
            body = body + "folder=" + self.recent_folders[i] + "\n"
            i = i + 1
        i = 0
        while i < len(self.recent):
            body = body + "file=" + self.recent[i] + "\n"
            i = i + 1
        write_file(p, body)

    def _remember_recent(self, path):
        if path == "" or string_startswith(path, "/tmp/nyide_"):
            return
        self.frecency.touch("file:" + path, time_ms())
        var keep = [path]
        var i = 0
        while i < len(self.recent) and len(keep) < 12:
            if self.recent[i] != path:
                keep.append(self.recent[i])
            i = i + 1
        self.recent = keep
        self._save_state()

    def _remember_folder(self, path):
        var keep = [path]
        var i = 0
        while i < len(self.recent_folders) and len(keep) < 8:
            if self.recent_folders[i] != path:
                keep.append(self.recent_folders[i])
            i = i + 1
        self.recent_folders = keep
        self._save_state()

    # ══ workspace ═════════════════════════════════════════════════════════════
    def _open_folder(self, path):
        if path == "" or not os_isdir(path):
            self._notify("Not a folder: " + path, "err")
            return false
        if not self.ws.open_folder(path):
            self._notify(self.ws.error, "err")
            return false
        self.ws_files = none
        self.tree_scroll = 0
        self.tree_sel = 0
        self._remember_folder(path)
        self._load_settings()
        self._load_hl_rules(false)
        self.scm_stale = true
        self.term_cwd = path
        self._title_dirty = true
        self._show_view("explorer")
        self._notify("Opened folder " + os_path_basename(path), "info")
        return true

    def _close_folder(self):
        if self._dirty_count() > 0:
            self._notify("Save or close modified editors before closing the folder", "warn")
            return
        self.ws.root = ""
        self.ws.rebuild()
        self.ws_files = none
        self.docs = [Doc("welcome", "Welcome", "", none)]
        self.active = 0
        self.problems = []
        self._count_problems()
        self.scm_stale = true
        self._title_dirty = true

    def _new_project(self, path):
        var pr = Project()
        if pr.create(path, os_path_basename(path)):
            self.ws.project = pr
            self._open_folder(path)
            self._open_path(pr.target, -1, 0)
            self._notify("Created project " + pr.name, "ok")
        else:
            self._notify("Could not create a project at " + path, "err")

    def _open_project(self, path):
        var pr = Project()
        if pr.load(path):
            self.ws.project = pr
            self._open_folder(pr.root)
            if os_exists(pr.target):
                self._open_path(pr.target, -1, 0)
            self._notify("Opened project " + pr.name, "ok")
        else:
            self._notify("Not a project manifest: " + path, "err")

    # ── explorer file operations ─────────────────────────────────────────────
    def _explorer_target_dir(self, arg):
        var p = arg
        if p == none or p == "":
            if self.tree_sel >= 0 and self.tree_sel < self.ws.row_count:
                p = self.ws.rows[self.tree_sel].path
            else:
                p = self.ws.root
        if p == "" or p == none:
            return ""
        if os_isdir(p):
            return p
        return os_path_dirname(p)

    def _explorer_new(self, folder, arg):
        if self.ws.root == "":
            self._notify("Open a folder first", "warn")
            return
        var dir = self._explorer_target_dir(arg)
        var title = "New File"
        var act = "newfile"
        if folder:
            title = "New Folder"
            act = "newfolder"
        self._open_prompt(act, title, "Name, relative to " + self._rel(dir) + "/  (a/b/c.ny creates folders)", "")
        self.qi.data = dir

    def _explorer_create(self, folder, dir, name):
        var nm = string_strip(name)
        if nm == "" or dir == none:
            return
        var full = path_join(dir, nm)
        if os_exists(full):
            self._notify("'" + nm + "' already exists", "err")
            return
        # Intermediate folders, as VS Code creates them for "a/b/c.ny".
        var parts = string_split(nm, "/")
        var cur = dir
        var n = len(parts)
        if not folder:
            n = n - 1
        var i = 0
        while i < n:
            cur = path_join(cur, parts[i])
            if not os_isdir(cur):
                os_mkdir(cur)
            self.ws.expanded[cur] = true
            i = i + 1
        self.ws.expanded[dir] = true
        if not folder:
            write_file(full, "")
        self.ws.rebuild()
        self.ws_files = none
        self.scm_stale = true
        self._select_tree_path(full)
        if not folder:
            self._open_path(full, -1, 0)

    def _explorer_rename(self, arg):
        var p = arg
        if p == none or p == "":
            if self.tree_sel >= 0 and self.tree_sel < self.ws.row_count:
                p = self.ws.rows[self.tree_sel].path
        if p == none or p == "" or p == self.ws.root:
            return
        self._open_prompt("rename", "Rename", "New name for " + os_path_basename(p), os_path_basename(p))
        self.qi.data = p

    def _explorer_do_rename(self, old, name):
        var nm = string_strip(name)
        if nm == "" or old == none:
            return
        var dest = path_join(os_path_dirname(old), nm)
        if dest == old:
            return
        if os_exists(dest):
            self._notify("'" + nm + "' already exists", "err")
            return
        if not os_rename(old, dest):
            self._notify("Could not rename " + os_path_basename(old), "err")
            return
        # Open editors follow the rename, including files inside a renamed folder.
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.path == old:
                d.path = dest
                d.title = os_path_basename(dest)
            elif d.path != "" and string_startswith(d.path, old + "/"):
                d.path = dest + string_slice(d.path, len(old), len(d.path))
            i = i + 1
        self.ws.rebuild()
        self.ws_files = none
        self.scm_stale = true
        self._title_dirty = true
        self._select_tree_path(dest)
        self._notify("Renamed to " + nm, "ok")

    def _explorer_delete(self, arg):
        var p = arg
        if p == none or p == "":
            if self.tree_sel >= 0 and self.tree_sel < self.ws.row_count:
                p = self.ws.rows[self.tree_sel].path
        if p == none or p == "" or p == self.ws.root:
            return
        var what = "file"
        if os_isdir(p):
            what = "folder"
        self._modal("Are you sure you want to delete '" + os_path_basename(p) + "'?",
                    "The " + what + " and its contents are removed from disk. This cannot be undone.",
                    [["Delete", "@delete.confirm", p], ["Cancel", "@modal.cancel", ""]])

    def _explorer_do_delete(self, p):
        if not self._rm_tree(p, 0):
            self._notify("Could not delete " + os_path_basename(p), "err")
        else:
            self._notify("Deleted " + os_path_basename(p), "info")
        # Editors of deleted files become untitled-like: kept, marked modified.
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.path == p or (d.path != "" and string_startswith(d.path, p + "/")):
                d.buf.saved_id = -1
            i = i + 1
        self.ws.rebuild()
        self.ws_files = none
        self.scm_stale = true
        if self.tree_sel >= self.ws.row_count:
            self.tree_sel = self.ws.row_count - 1

    def _rm_tree(self, p, depth):
        if depth > 32:
            return false
        if os_isdir(p):
            var ents = os_listdir(p)
            if ents != none:
                var i = 0
                while i < len(ents):
                    self._rm_tree(path_join(p, ents[i]), depth + 1)
                    i = i + 1
        return os_remove(p)

    def _select_tree_path(self, p):
        # Expand every ancestor so the row exists, then select it.
        var dir = os_path_dirname(p)
        while dir != "" and string_startswith(dir, self.ws.root) and dir != self.ws.root:
            self.ws.expanded[dir] = true
            dir = os_path_dirname(dir)
        self.ws.rebuild()
        var i = 0
        while i < self.ws.row_count:
            if self.ws.rows[i].path == p:
                self.tree_sel = i
                self._reveal_tree_row(i)
            i = i + 1

    def _reveal_in_explorer(self, p):
        if p == "" or self.ws.root == "":
            return
        self._show_view("explorer")
        self._select_tree_path(p)
        self.focus = "explorer"

    # ══ symbols ═══════════════════════════════════════════════════════════════
    # Go to Definition: the declaration of the word under the caret, in this
    # file first, then anywhere in the workspace.
    def _goto_definition(self):
        var w = self._selected_word()
        if w == "":
            return
        var syms = self._doc_symbols(self.buf())
        var i = 0
        while i < len(syms):
            if syms[i][0] == w:
                self._goto(syms[i][2], syms[i][3])
                return
            i = i + 1
        var files = self._workspace_files()
        var f = 0
        while f < len(files):
            var p = files[f]
            if os_path_ext(p) == ".ny" and file_size(p) < 600000:
                var text = read_file(p)
                if text != none and string_find(text, w) >= 0:
                    var lines = string_split(text, "\n")
                    var r = 0
                    while r < len(lines):
                        var sym = self._symbol_on_line(lines[r])
                        if sym != none and sym[0] == w:
                            self._open_path(p, r, sym[2])
                            return
                        r = r + 1
            f = f + 1
        self._notify("No definition found for '" + w + "'", "info")

    def _find_references(self):
        var w = self._selected_word()
        if w == "":
            return
        self.search_query = w
        self.search_word = true
        self.search_case = true
        self.search_regex = false
        self._show_view("search")
        self._run_search()

    def _rename_symbol_prompt(self):
        if not self._can_edit():
            return
        var w = self._selected_word()
        if w == "":
            return
        var n = len(self._occurrences(w, true))
        self._open_prompt("renamesymbol", "Rename Symbol", "New name for '" + w + "' (" + str(n) + " occurrence(s) in this file)", w)
        self.qi.data = w

    def _rename_symbol(self, old, newname):
        if old == none or newname == "" or newname == old:
            return
        var hits = self._occurrences(old, true)
        if len(hits) == 0:
            return
        var b = self.buf()
        b.begin_group()
        var was = b.hold
        b.hold = true
        var i = len(hits) - 1
        while i >= 0:
            b.delete_range(hits[i][0], hits[i][1], hits[i][0], hits[i][1] + len(old))
            b.cursor_row = hits[i][0]
            b.cursor_col = hits[i][1]
            b.insert_text(newname)
            i = i - 1
        b.hold = was
        b.begin_group()
        self._after_edit()
        self._notify("Renamed " + str(len(hits)) + " occurrence(s) of '" + old + "'", "ok")

    # ══ theme, zoom, highlight rules ══════════════════════════════════════════
    def _set_theme(self, dark):
        self.th.dark = dark
        self.th.apply()
        self.hl.set_dark(dark)
        self._hl_reset()
        self._dirty = true

    def _zoom(self, delta):
        var ns = self.font_size + delta
        if ns < 8:
            ns = 8
        if ns > 30:
            ns = 30
        if ns == self.font_size:
            return
        self.font_size = ns
        self.f_code = Font("monospace", self.dp(ns), false, false)
        self.f_code.ensure_loaded()
        self.LINE_H = int(self.dp(ns) * 1.4)
        self.char_w = self.f_code.width("M")
        self._hl_reset()
        self.status_msg = "Editor font size " + str(ns)
        self._layout()
        self._save_settings()

    def _load_hl_rules(self, announce):
        if self.ws.root == "":
            return
        var n = self.hl.load_rules(path_join(self.ws.root, ".nyhighlight"))
        self._hl_reset()
        if n > 0 and announce:
            self._notify(str(n) + " highlight rule(s) loaded from .nyhighlight", "ok")
        elif announce:
            self._notify("No .nyhighlight file in this workspace", "warn")

    def _add_highlight_token(self, v):
        var eqp = string_find(v, "=")
        if eqp > 0:
            var wname = string_strip(string_slice(v, 0, eqp))
            var cparts = string_split(string_slice(v, eqp + 1, len(v)), ",")
            if len(cparts) >= 3:
                self.hl.add_token(wname, Color(self._int_or(cparts[0], 200), self._int_or(cparts[1], 200), self._int_or(cparts[2], 200), 255))
                self._notify("Highlighting '" + wname + "'", "ok")
        elif string_strip(v) != "":
            self.hl.add_keyword(string_strip(v))
            self._notify("'" + string_strip(v) + "' is now highlighted as a keyword", "ok")
        self._hl_reset()

    # ══ generated documents ═══════════════════════════════════════════════════
    def _keybindings_text(self):
        var out = "Keyboard Shortcuts - every command, as the menus and the Command Palette see it\n"
        out = out + "(generated from the live command registry; Ctrl+K X is a chord: Ctrl+K, then X)\n\n"
        var i = 0
        while i < self.reg.n:
            var c = self.reg.get(self.reg.order[i])
            var k = c.keys
            if k == "":
                k = "-"
            var lab = c.label
            while len(lab) < 58:
                lab = lab + " "
            out = out + lab + k + "\n"
            i = i + 1
        return out

    def _about_text(self):
        var t = "NythonIDE 5.0\n"
        t = t + "Nython " + str(lang_version()) + "\n"
        t = t + "SDL " + str(gui_sdl_version()) + "\n"
        t = t + "Interpreter: " + self._interpreter() + "\n"
        var home = getenv("NYTHON_HOME")
        if home == none:
            home = "(not set)"
        t = t + "Install folder: " + home + "\n"
        t = t + "Workspace: " + self.ws.root + "\n"
        return t

    def _about(self):
        self._modal("NythonIDE", self._about_text(), [["Copy", "@about.copy", ""], ["OK", "@modal.cancel", ""]])

    def _open_docs(self):
        var home = getenv("NYTHON_HOME")
        var cands = []
        if home != none and home != "":
            cands.append(path_join(home, "CLAUDE.md"))
            cands.append(path_join(home, "HANDOFF.md"))
            cands.append(path_join(home, "README.md"))
        cands.append(path_join(getcwd(), "README.md"))
        var i = 0
        while i < len(cands):
            if os_exists(cands[i]):
                self._open_path(cands[i], 0, 0)
                self.doc().readonly = true
                return
            i = i + 1
        self._notify("Documentation files were not found next to the IDE", "warn")

    def _dump_hitmap(self):
        var p = getenv("NY_IDE_DUMP")
        if p == none or p == "":
            p = "/tmp/nyide_hitmap.tsv"
        write_file(p, self.hits.dump())
        self.status_msg = str(self.hits.count()) + " clickable regions written to " + p

    # ══ AI assistant ══════════════════════════════════════════════════════════
    def _ai_analyze(self, force):
        if not self._is_text():
            self.ai_issues = []
            self.ai_n = 0
            return
        var key = self.doc().title + ":" + str(self.buf().state_id())
        if not force and self.ai_key == key:
            return
        var found = self.ai.analyze(self.buf().get_all_text())
        self.ai_issues = found
        self.ai_n = len(found)
        self.ai_key = key
