# ══════════════════════════════════════════════════════════════════════════════
#  ide_live.ny — IDELive: live debugging and the Profile view (round 81).
#  Part of the NythonIDE class chain (see ide_core.ny's header), between
#  IDETools and IDEAgent.
#
#  Live debugging: "Run with Live Debugging" (Alt+F5) starts the program as
#  `nython --debug-port N file.ny` - it runs under lib/ide_debugserver.ny -
#  and lib/ide_debugclient.ny's LiveDebugClient talks to it over a local
#  socket (the Debug Adapter Protocol's messages), polled once per frame.
#  The program's own output and input stay in the Output panel. The same
#  Run and Debug view, toolbar, keys and gutter breakpoints serve both
#  debuggers: record-and-replay (F5, lib/ide_debugger.ny) and live. Live
#  adds Pause (F6), an expandable Variables tree (children fetched by
#  reference when opened), Set Value (double-click a variable, or its
#  context menu), Watch and the Debug Console evaluated in the selected
#  frame, exception breakpoints (raised / uncaught) and - from the
#  server's ring buffer of recent statements - Step Back, Reverse Continue
#  and the Why? questions about the live program.
#
#  Profile: "Profile with cProfile (Flame Graph)" runs `nython -m cProfile
#  --stacks -o OUT file.ny`; the PROFILE panel shows lib/ide_profile.ny's
#  reading of OUT: a table sortable by each column (click a heading; again
#  flips it), the selected function's callers and callees, and the flame
#  graph as an icicle (exact stacks from the calling context tree). A click
#  on a function - row, caller, callee or bar - selects it and opens its
#  source.
#
#  Painters here follow ide_paint.ny's rules: every clickable registers
#  itself in the hit map as it is drawn, and the strings shown every frame
#  are made when what they show changes (_live_sync, _prof_select), not
#  per frame.
# ══════════════════════════════════════════════════════════════════════════════

import "ide_tools.ny"
import "lib/ide_debugclient.ny"
import "lib/ide_profile.ny"


class IDELive(IDETools):
    # Called from NythonIDE.__init__, before the commands are registered.
    def _live_init(self):
        self.live = LiveDebugClient()
        self.live_gen = -1
        self.live_brk_gen = -1
        self.live_extra_n = -1
        self.live_watch_n = -1
        self.live_restart = false
        self.live_exc_raised = false
        self.live_exc_uncaught = true
        self.live_status = ""
        self.live_logs_n = 0
        self.live_sel = -1
        self.live_why_seen = none
        self.live_last_stops = -1
        self.live_last_sel = -1
        self.live_frame_locs = []
        self.live_set_ref = 0
        self.live_set_name = ""
        self.prof = ProfileData()
        self.prof_out = ""
        self.prof_sel = -1
        self.prof_rel = []
        self.prof_title = ""
        self.prof_flame_title = ""
        self.prof_cols = ["ncalls", "tottime", "percall", "cumtime", "cumpercall", "name"]
        self.prof_heads = ["ncalls", "tottime", "percall", "cumtime", "percall", "filename:lineno(function)"]
        self.prof_widths = [80, 70, 70, 70, 70, 0]
        self.prof_sort_tips = ["Sort by calls", "Sort by internal time", "Sort by internal time per call",
                               "Sort by cumulative time", "Sort by cumulative time per call", "Sort by name"]
        # the flame graph's warm palette (Gregg's "hot" colours), made once
        self.prof_palette = []
        var pi = 0
        while pi < 10:
            self.prof_palette.append(Color(205 + int(pi * 5), 70 + int(pi * 15), 30 + int(pi * 4), 255))
            pi = pi + 1
        self.prof_bar_fg = Color(30, 24, 20, 255)

    # ── commands ─────────────────────────────────────────────────────────────
    def _tools_register(self):
        IDETools._tools_register(self)
        var c = self
        c._cmd("nython.debug.startLive", "Run", "Start Live Debugging", "Alt+F5", "!inDebugMode")
        c._cmd("workbench.action.debug.pause", "Debug", "Pause", "F6", "inDebugMode")
        c._cmd("nython.debug.setValue", "Debug", "Set Value", "", "inDebugMode")
        c._cmd("nython.debug.toggleRaised", "Debug", "Break on Raised Exceptions", "", "")
        c._cmd("nython.debug.toggleUncaught", "Debug", "Break on Uncaught Exceptions", "", "")
        c._cmd("nython.profile.cprofile", "Run", "Profile with cProfile (Flame Graph)", "", "")
        c._cmd("nython.profile.show", "View", "Profile", "", "")
        c._cmd("nython.profile.copyFolded", "Profile", "Copy Folded Stacks", "", "")
        var rn = self.menu_items["Run"]
        var out = []
        for id in rn:
            out.append(id)
            if id == "workbench.action.debug.start":
                out.append("nython.debug.startLive")
            elif id == "workbench.action.debug.restart":
                out.append("workbench.action.debug.pause")
            elif id == "nython.profile":
                out.append("nython.profile.cprofile")
        out.append("-")
        out.append("nython.debug.toggleRaised")
        out.append("nython.debug.toggleUncaught")
        self.menu_items["Run"] = out
        self.menu_items["View"].append("nython.profile.show")
        self.keymap_default = self.reg.snapshot()

    def _tools_exec(self, id, arg):
        if id == "nython.debug.startLive":
            self._live_start()
        elif id == "workbench.action.debug.pause":
            if self.live.active:
                self.live.pause()
        elif id == "nython.debug.setValue":
            self._live_set_value_prompt(arg)
        elif id == "nython.debug.toggleRaised":
            self.live_exc_raised = not self.live_exc_raised
            self._live_send_filters()
        elif id == "nython.debug.toggleUncaught":
            self.live_exc_uncaught = not self.live_exc_uncaught
            self._live_send_filters()
        elif id == "nython.profile.cprofile":
            self._profile_start()
        elif id == "nython.profile.show":
            self._toggle_panel_tab("profile")
        elif id == "nython.profile.copyFolded":
            if len(self.prof.flame) > 0:
                self._set_clipboard(string_join(self.prof.folded(), "\n") + "\n")
                self._notify("Copied " + str(len(self.prof.folded())) + " folded stacks (flamegraph.pl's input)", "info")
        else:
            return IDETools._tools_exec(self, id, arg)
        return true

    # Restart and Start mean the live session while one runs.
    def _exec(self, id, arg):
        if self.live.active and id == "workbench.action.debug.restart":
            self._dirty = true
            self._live_restart()
            return true
        return IDETools._exec(self, id, arg)

    def _ctx_keys(self):
        var k = IDETools._ctx_keys(self)
        k["inDebugMode"] = self.dbg.active or self.live.active
        return k

    def _command_enabled(self, id):
        if self.live.active:
            if id == "workbench.action.debug.pause":
                return self.live.state == "running"
            if string_startswith(id, "workbench.action.debug.step") or id == "workbench.action.debug.continue" or id == "workbench.action.debug.reverseContinue":
                return self.live.state == "paused"
            if id == "workbench.action.debug.stop" or id == "workbench.action.debug.restart":
                return true
            if id == "nython.debug.whyValue" or id == "nython.debug.whyNot" or id == "nython.debug.setValue":
                return self.live.state == "paused"
        if id == "workbench.action.debug.pause" or id == "nython.debug.setValue":
            return false
        return IDETools._command_enabled(self, id)

    # ── the debug commands, routed to the live session ───────────────────────
    def _debug_start(self):
        if self.live.active:
            self.live.cont()
            return
        IDETools._debug_start(self)

    def _debug_step(self, kind):
        if not self.live.active:
            IDETools._debug_step(self, kind)
            return
        if kind == "over":
            self.live.next()
        elif kind == "into":
            self.live.step_in()
        elif kind == "out":
            self.live.step_out()
        elif kind == "back":
            self.live.step_back()

    def _debug_continue(self, dir):
        if not self.live.active:
            IDETools._debug_continue(self, dir)
            return
        if dir > 0:
            self.live.cont()
        else:
            self.live.reverse_continue()

    def _debug_stop(self):
        if self.live.active or (self.job_running and self.job_mode == "Live"):
            self._live_stop()
            return
        IDETools._debug_stop(self)

    # The Debug Console evaluates in the selected frame of the live program.
    def _dbg_eval(self, expr):
        if not self.live.active:
            IDETools._dbg_eval(self, expr)
            return
        var e = string_strip(expr)
        if e == "":
            return
        self._dbg_print("> " + e, "cmd")
        if self.live.state != "paused":
            self._dbg_print("The program is running - pause it (F6) to evaluate in a frame.", "warn")
            return
        self.live.evaluate(e, "repl", "repl")

    def _dbg_why_value(self, name):
        if not self.live.active:
            IDETools._dbg_why_value(self, name)
            return
        if self.live.state != "paused":
            self._notify("Pause the program to ask why a variable has its value", "warn")
            return
        if name == none or name == "":
            if self.live_sel >= 0 and self.live_sel < len(self.live.rows) and self.live.rows[self.live_sel][5] != "scope":
                name = self.live.rows[self.live_sel][1]
            else:
                self._notify("Select a variable in the Variables pane first", "warn")
                return
        self.live.why_value(name)

    def _dbg_why_not(self, row):
        if not self.live.active:
            IDETools._dbg_why_not(self, row)
            return
        if not self._is_text() or self.live.state != "paused":
            return
        var d = self.doc()
        if row == none or row == "":
            row = self.buf().cursor_row
        var file = d.path
        if d == self.dbg_doc and d.kind != "file":
            file = self.dbg_run_path
        self.live.why_not(file, row + 1)

    # A Why? row travels through the history in a live session.
    def _dbg_why_go(self, i):
        if not self.live.active:
            IDETools._dbg_why_go(self, i)
            return
        if i < 0 or i >= len(self.dbg_why):
            return
        var row = self.dbg_why[i]
        if row[1] >= 0:
            self.live.seek(row[1])
        elif row[2] != "" and row[3] > 0:
            self._open_path(row[2], row[3] - 1, 0)

    # ── a live session ───────────────────────────────────────────────────────
    def _live_start(self):
        if self.live.active:
            if self.live.state == "paused":
                self.live.cont()
            return
        if not self._is_text() or self.doc().lang != "nython":
            self._notify("Open a Nython file to debug it", "warn")
            return
        if self.job_running and self.job_mode == "Live":
            # the last session's program is still going away: start once it has
            self.live_restart = true
            return
        if self.job_running:
            self._notify("A program is already running - stop it first (Shift+F5)", "warn")
            return
        if self.dbg.active:
            IDETools._debug_stop(self)
        var d = self.doc()
        var path = self._path_for_run(d)
        self.dbg_doc = d
        self.dbg_run_path = path
        var port = dap_free_port()
        self.live.exc_filters = self._live_filters()
        self.live.bp_files = self._live_bp_files()
        self.live.start(port)
        self.live.watches = self.watches        # (start() clears the session's state)
        self.live_brk_gen = self.brk_gen
        self.live_extra_n = len(self.brk_extra)
        self.live_watch_n = len(self.watches)
        self.live_logs_n = 0
        self.live_sel = -1
        self.live_why_seen = none
        self.live_last_stops = -1
        self.live_last_sel = -1
        self.dbg_why = []
        self.dbg_why_title = ""
        self.dbgcon_lines = []
        self.dbgcon_kinds = []
        self._dbg_print("Live debugging " + os_path_basename(path) + " ...", "info")
        self._output_clear()
        self._output_write("> Live Debug  " + self._rel(path), "cmd")
        self._show_view("debug")
        self._show_panel("output")
        self.job_mode = "Live"
        self.job_path = path
        self.job_doc = d
        var cwd = self.ws.root
        if cwd == "":
            cwd = os_path_dirname(path)
        self._start_job(self._interpreter() + " --debug-port " + str(port) + " ", path, cwd)
        self.live_gen = -1
        self._live_sync()

    def _live_stop(self):
        self.live_restart = false
        if self.live.active:
            self.live.stop()
        if self.job_running and self.job_mode == "Live":
            self._stop_job()
        self._live_end()

    def _live_restart(self):
        self._live_stop()
        if self.job_running:
            self.live_restart = true        # started again once the old one exits
        else:
            self._live_start()

    def _live_end(self):
        self._live_flush_logs()
        if self.live.exit_code != none:
            self._dbg_print("The program exited with code " + str(self.live.exit_code) + ".", "info" if self.live.exit_code == 0 else "err")
        if self.live.error != "":
            self._dbg_print(self.live.error, "err")
        self.live.close()
        self.dbg_line_row = -1
        self.dbg_line_path = ""
        self.live_status = ""
        self._dirty = true

    def _live_filters(self):
        var f = []
        if self.live_exc_raised:
            f.append("raised")
        if self.live_exc_uncaught:
            f.append("uncaught")
        return f

    def _live_send_filters(self):
        if self.live.active:
            self.live.set_exception_filters(self._live_filters())
        else:
            self.live.exc_filters = self._live_filters()
        self._dirty = true

    # The breakpoints as setBreakpoints wants them, per file (an untitled
    # editor's go to its temporary copy).
    def _live_bp_files(self):
        var files = {}
        var d = self.dbg_doc
        var i = 0
        while i < len(self.break_list):
            var key = self.break_list[i]
            var parts = self._break_parts(key)
            var file = parts[0]
            if d != none and file == self._doc_key(d):
                file = self.dbg_run_path
            var bp = {"line": parts[1]}
            if self.brk_extra.has_key(key):
                var ex = self.brk_extra[key]
                if ex.get("cond", "") != "":
                    bp["condition"] = ex["cond"]
                if ex.get("hits", "") != "":
                    bp["hitCondition"] = ex["hits"]
                if ex.get("log", "") != "":
                    bp["logMessage"] = ex["log"]
            if not files.has_key(file):
                files[file] = []
            files[file].append(bp)
            i = i + 1
        return files

    # Every frame (NythonIDE._tick).
    def _live_tick(self):
        if not self.live.active:
            return
        if self.brk_gen != self.live_brk_gen or len(self.brk_extra) != self.live_extra_n:
            self.live_brk_gen = self.brk_gen
            self.live_extra_n = len(self.brk_extra)
            var files = self._live_bp_files()
            for p in self.live.bp_files.keys():
                if not files.has_key(p):
                    self.live.set_breakpoints(p, [])
            for p2 in files.keys():
                self.live.set_breakpoints(p2, files[p2])
        if len(self.watches) != self.live_watch_n:
            self.live_watch_n = len(self.watches)
            self.live.watches = self.watches
            self.live.refresh_watches()
        self.live.poll()
        if self.live.gen != self.live_gen:
            self.live_gen = self.live.gen
            self._live_sync()

    def _live_flush_logs(self):
        var L = self.live
        while self.live_logs_n < len(L.logs):
            var lg = L.logs[self.live_logs_n]
            self._dbg_print(lg[0], lg[1])
            self.live_logs_n = self.live_logs_n + 1

    # What the client learnt, onto the workbench: the stopped line in the
    # editor, the status, the debug console, a Why? answer.
    def _live_sync(self):
        var L = self.live
        self._dirty = true
        self._live_flush_logs()
        if L.state == "ended":
            self._live_end()
            return
        if L.state == "connecting":
            self.live_status = "Starting " + os_path_basename(self.job_path) + " under the debug server ..."
        elif L.state == "running":
            self.live_status = "Running"
            self.dbg_line_row = -1
            self.dbg_line_path = ""
        elif L.state == "paused":
            var why = L.reason
            if why == "breakpoint":
                why = "Paused on breakpoint"
            elif why == "exception":
                why = "Paused on exception"
            elif why == "pause":
                why = "Paused"
            elif why == "entry":
                why = "Paused on entry"
            else:
                why = "Paused"
            if L.history != none:
                why = "History: step " + str(L.history[0] + 1) + " of " + str(L.history[1]) + " (Continue returns to the present)"
            self.live_status = why
        var locs = []
        for f in L.frames:
            locs.append(os_path_basename(f[2]) + ":" + str(f[3]))
        self.live_frame_locs = locs
        if L.state == "paused" and len(L.frames) > 0 and (L.stops != self.live_last_stops or L.frame_sel != self.live_last_sel):
            self.live_last_stops = L.stops
            self.live_last_sel = L.frame_sel
            self._live_show_line(L.path, L.line)
        if L.why != none and L.why is not self.live_why_seen:
            self.live_why_seen = L.why
            self._dbg_why_show(L.why_title, L.why)
        if self.live_sel >= len(L.rows):
            self.live_sel = -1

    def _live_show_line(self, path, line):
        self.dbg_line_path = path
        self.dbg_line_row = line - 1
        if path == self.dbg_run_path and self.dbg_doc != none and self.dbg_doc.kind != "file":
            var di = self._index_of(self.dbg_doc)
            if di >= 0:
                self._activate(di)
            self.dbg_line_path = self.doc().path
        elif path != "" and self.doc().path != path:
            self._open_path(path, -1, 0)
            self.dbg_line_path = self.doc().path
        if self._is_text():
            var b = self.buf()
            b.cursor_row = self.dbg_line_row
            if b.cursor_row >= b.line_count:
                b.cursor_row = b.line_count - 1
            if b.cursor_row < 0:
                b.cursor_row = 0
            b.cursor_col = 0
            self._reveal_row_center(b.cursor_row)

    def _finish_job(self, code):
        var mode = self.job_mode
        IDETools._finish_job(self, code)
        if mode == "Live":
            if self.live.active:
                self.live.poll()
                if self.live.state != "ended":
                    if self.live.state == "connecting":
                        self.live.error = "the program ended before the debugger could connect"
                    self.live._ended()
                self.live_gen = self.live.gen
                self._live_sync()
            if self.live_restart:
                self.live_restart = false
                self._live_start()
        elif mode == "cProfile":
            self._profile_loaded(code)

    # Set Value: a prompt pre-filled with the variable's value.
    def _live_set_value_prompt(self, i):
        if not self.live.active or self.live.state != "paused":
            return
        if i == none or i == "":
            i = self.live_sel
        if i < 0 or i >= len(self.live.rows):
            self._notify("Select a variable in the Variables pane first", "warn")
            return
        var row = self.live.rows[i]
        if row[5] == "scope" or row[5] == "loading":
            return
        self.live_set_ref = row[7]
        self.live_set_name = row[1]
        self._open_prompt("t.live.setvalue", "Set Value of " + row[1], "An expression, evaluated in the frame", row[2])

    def _tools_accept(self, action, value, item):
        if action == "t.live.setvalue":
            if string_strip(value) != "":
                self.live.set_variable(self.live_set_ref, self.live_set_name, value)
            return
        IDETools._tools_accept(self, action, value, item)

    # ── painting: Run and Debug ─────────────────────────────────────────────
    def _draw_debug_view(self, r, x, w):
        if self.live.active:
            self._draw_live_view(r, x, w)
            return
        if self.dbg.active or self.dbg_recording:
            IDETools._draw_debug_view(self, r, x, w)
            return
        var th = self.th
        var y = self.content_y + self.SIDE_HEAD
        self._button(r, x + self.dp(20), y + self.dp(8), w - self.dp(40), self.dp(28), "Run and Debug", "workbench.action.debug.start", "", true)
        var ty = self._draw_wrapped(r, "Records the program, then lets you step through it forwards and backwards (F10, F11, Ctrl+Shift+F11).",
                                    x + self.dp(20), y + self.dp(46), w - self.dp(40), self.f_small, th.text_faint, self.dp(16))
        self._button(r, x + self.dp(20), ty + self.dp(10), w - self.dp(40), self.dp(28), "Run with Live Debugging", "nython.debug.startLive", "", false)
        ty = self._draw_wrapped(r, "Stops the running program at breakpoints, on Pause (F6) or on exceptions; Step Back replays its last statements.",
                                x + self.dp(20), ty + self.dp(46), w - self.dp(40), self.f_small, th.text_faint, self.dp(16))
        self._button(r, x + self.dp(20), ty + self.dp(10), w - self.dp(40), self.dp(28), "Run Without Debugging", "workbench.action.debug.run", "", false)
        self._button(r, x + self.dp(20), ty + self.dp(46), w - self.dp(40), self.dp(28), "Profile (Flame Graph)", "nython.profile.cprofile", "", false)
        y = ty + self.dp(90)
        y = self._draw_live_exc_rows(r, x, y, w)
        if self._section(r, x, y, w, "BREAKPOINTS", "dbg.breaks", len(self.break_list)):
            if len(self.break_list) > 0:
                self._small_button(r, x + w - self.dp(70), y + self.dp(1), self.dp(20), self.dp(20), "close-all", "workbench.debug.viewlet.action.removeAllBreakpoints", "", "Remove All Breakpoints", false)
            y = y + self.ROW_H
            self._draw_breaks(r, x, y, w)

    # The two exception breakpoints, as checkboxes.
    def _draw_live_exc_rows(self, r, x, y, w):
        y = self._live_check_row(r, x, y, w, "Raised Exceptions", self.live_exc_raised, "nython.debug.toggleRaised",
                                 "Live debugging stops where an exception is raised")
        y = self._live_check_row(r, x, y, w, "Uncaught Exceptions", self.live_exc_uncaught, "nython.debug.toggleUncaught",
                                 "Live debugging stops on an exception nothing caught")
        return y + self.dp(4)

    def _live_check_row(self, r, x, y, w, label, on, cmd, tip):
        var th = self.th
        var lh = self.ROW_H
        if self._hov(x, y, w, lh):
            r.fill_xywh(x, y, w, lh, th.hover)
        var bx = x + self.dp(22)
        var by = y + int((lh - self.dp(14)) / 2)
        r.round_rect_xywh(bx, by, self.dp(14), self.dp(14), th.text_dim, self.dp(2), 1)
        if on:
            self.icons.draw(r, "check", bx - self.dp(1), by - self.dp(1), self.dp(16), th.text)
        r.text(label, bx + self.dp(22), y + int((lh - self.ui_h) / 2), self.f_ui, th.text)
        self._hit(x, y, w, lh, cmd, "", tip)
        return y + lh

    def _draw_live_view(self, r, x, w):
        var th = self.th
        var L = self.live
        var y = self.content_y + self.SIDE_HEAD
        var col = th.text_dim
        if L.state == "paused":
            col = th.warn
        r.text(self.live_status, x + self.dp(20), y + self.dp(4), self.f_small, col)
        y = y + self.dp(24)
        if L.exc_text != "" and L.state == "paused":
            r.fill_xywh(x + self.dp(8), y, w - self.dp(16), self.dp(40), self._a(th.err, 40))
            self.icons.draw(r, "error", x + self.dp(14), y + self.dp(4), self.dp(16), th.err)
            r.text(L.exc_text, x + self.dp(36), y + self.dp(4), self.f_small, th.text)
            r.text(L.description, x + self.dp(36), y + self.dp(20), self.f_small, th.text_faint)
            y = y + self.dp(46)
        if len(self.dbg_why) > 0:
            if self._section(r, x, y, w, "WHY", "dbg.why", -1):
                self._small_button(r, x + w - self.dp(30), y + self.dp(1), self.dp(20), self.dp(20), "close", "@dbg.whyclose", "", "Clear the Answer", false)
                y = y + self.ROW_H
                y = self._draw_dbg_why(r, x, y, w)
            else:
                y = y + self.ROW_H
        if self._section(r, x, y, w, "VARIABLES", "dbg.vars", -1):
            y = y + self.ROW_H
            y = self._draw_live_vars(r, x, y, w)
        else:
            y = y + self.ROW_H
        if self._section(r, x, y, w, "WATCH", "dbg.watch", -1):
            self._small_button(r, x + w - self.dp(30), y + self.dp(1), self.dp(20), self.dp(20), "add", "@dbg.addwatch", "", "Add Expression", false)
            y = y + self.ROW_H
            y = self._draw_live_watch(r, x, y, w)
        else:
            y = y + self.ROW_H
        if self._section(r, x, y, w, "CALL STACK", "dbg.stack", -1):
            y = y + self.ROW_H
            y = self._draw_live_stack(r, x, y, w)
        else:
            y = y + self.ROW_H
        if self._section(r, x, y, w, "BREAKPOINTS", "dbg.breaks", len(self.break_list)):
            if len(self.break_list) > 0:
                self._small_button(r, x + w - self.dp(70), y + self.dp(1), self.dp(20), self.dp(20), "close-all", "workbench.debug.viewlet.action.removeAllBreakpoints", "", "Remove All Breakpoints", false)
            y = y + self.ROW_H
            y = self._draw_live_exc_rows(r, x, y, w)
            self._draw_breaks(r, x, y, w)

    def _draw_live_vars(self, r, x, y, w):
        var th = self.th
        var L = self.live
        var lh = self.ROW_H
        if L.state != "paused":
            var msg = "Pause the program (F6) to see its variables"
            if L.state == "connecting":
                msg = "Starting ..."
            r.text(msg, x + self.dp(24), y + self.dp(4), self.f_small, th.text_faint)
            return y + lh
        if len(L.rows) == 0:
            r.text("Loading ...", x + self.dp(24), y + self.dp(4), self.f_small, th.text_faint)
            return y + lh
        var i = 0
        var limit = self.status_y - self.dp(150)
        while i < len(L.rows) and y + lh <= limit:
            var row = L.rows[i]
            var ix = x + self.dp(8) + row[0] * self.dp(12)
            if i == self.live_sel:
                r.fill_xywh(x, y, w, lh, th.list_inactive)
            elif self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            if row[3] != 0:
                self.icons.draw(r, "chevron-down" if row[4] else "chevron-right", ix, y + self.dp(3), self.dp(16), th.text_dim)
            var tx = ix + self.dp(18)
            var ty = y + int((lh - self.code_small_h) / 2)
            if row[5] == "scope":
                r.text(row[1], tx, y + int((lh - self.small_h) / 2), self.f_small_bold, th.text)
                self._hit(x, y, w, lh, "@live.var", i, "")
            elif row[5] == "loading":
                r.text(row[1], tx, ty, self.f_mono_small, th.text_faint)
            else:
                r.text(row[1], tx, ty, self.f_mono_small, th.info)
                var nw = self.f_mono_small.width(row[1])
                r.text(": ", tx + nw, ty, self.f_mono_small, th.text_dim)
                r.text(row[2], tx + nw + self.f_mono_small.width(": "), ty, self.f_mono_small, th.text)
                self._hit(x, y, w, lh, "@live.var", i, row[6])
                if row[0] == 1 and (self._hov(x, y, w, lh) or i == self.live_sel):
                    self._small_button(r, x + w - self.dp(28), y + self.dp(1), self.dp(20), self.dp(20), "question", "@live.why", i, "Why does it have this value?", false)
            y = y + lh
            i = i + 1
        return y

    def _draw_live_watch(self, r, x, y, w):
        var th = self.th
        var lh = self.ROW_H
        if len(self.watches) == 0:
            r.text("Add an expression with +", x + self.dp(24), y + self.dp(4), self.f_small, th.text_faint)
            return y + lh
        var i = 0
        while i < len(self.watches):
            var nm = self.watches[i]
            var v = self.live.watch_vals.get(nm)
            var vs = "not available"
            var vc = th.text_faint
            if v != none and self.live.state == "paused":
                vs = v[0]
                vc = th.text if v[1] else th.err
            var ty = y + int((lh - self.code_small_h) / 2)
            r.text(nm, x + self.dp(24), ty, self.f_mono_small, th.info)
            var nw = self.f_mono_small.width(nm)
            r.text(": ", x + self.dp(24) + nw, ty, self.f_mono_small, th.text_dim)
            r.text(vs, x + self.dp(24) + nw + self.f_mono_small.width(": "), ty, self.f_mono_small, vc)
            if self._hov(x, y, w, lh):
                self._small_button(r, x + w - self.dp(28), y + self.dp(1), self.dp(20), self.dp(20), "close", "@dbg.rmwatch", i, "Remove Expression", false)
            y = y + lh
            i = i + 1
        return y

    def _draw_live_stack(self, r, x, y, w):
        var th = self.th
        var lh = self.ROW_H
        var L = self.live
        if L.state != "paused" or len(L.frames) == 0:
            r.text("Running" if L.state == "running" else "", x + self.dp(24), y + self.dp(4), self.f_small, th.text_faint)
            return y + lh
        var i = 0
        while i < len(L.frames) and i < len(self.live_frame_locs):
            var fr = L.frames[i]
            if i == L.frame_sel:
                r.fill_xywh(x, y, w, lh, th.list_inactive)
            elif self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            if i == 0:
                self.icons.draw(r, "debug-stackframe", x + self.dp(6), y + self.dp(3), self.dp(16), th.warn)
            r.text(fr[1], x + self.dp(26), y + int((lh - self.ui_h) / 2), self.f_ui, th.text)
            var loc = self.live_frame_locs[i]
            r.text(loc, x + w - self.dp(12) - self.f_small.width(loc), y + int((lh - self.small_h) / 2), self.f_small, th.text_faint)
            self._hit(x, y, w, lh, "@live.frame", i, "")
            y = y + lh
            i = i + 1
        return y

    # The floating toolbar: Continue or Pause, the steps, Step Back,
    # Restart and Stop.
    def _draw_debug_toolbar(self, r):
        if not self.live.active:
            IDETools._draw_debug_toolbar(self, r)
            return
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
        if self.live.state == "running" or self.live.state == "connecting":
            self._dbg_button(r, bx, y, bw, h, "debug-pause", "workbench.action.debug.pause", "Pause (F6)", th.info)
        else:
            self._dbg_button(r, bx, y, bw, h, "debug-continue", "workbench.action.debug.continue", "Continue (F5)", th.info)
        self._dbg_button(r, bx + bw, y, bw, h, "debug-step-over", "workbench.action.debug.stepOver", "Step Over (F10)", th.info)
        self._dbg_button(r, bx + bw * 2, y, bw, h, "debug-step-into", "workbench.action.debug.stepInto", "Step Into (F11)", th.info)
        self._dbg_button(r, bx + bw * 3, y, bw, h, "debug-step-out", "workbench.action.debug.stepOut", "Step Out (Shift+F11)", th.info)
        self._dbg_button(r, bx + bw * 4, y, bw, h, "debug-step-back", "workbench.action.debug.stepBack", "Step Back through the recent history (Ctrl+Shift+F11)", th.info)
        self._dbg_button(r, bx + bw * 5, y, bw, h, "debug-restart", "workbench.action.debug.restart", "Restart (Ctrl+Shift+F5)", th.ok)
        self._dbg_button(r, bx + bw * 6, y, bw, h, "debug-stop", "workbench.action.debug.stop", "Stop (Shift+F5)", th.err)

    # ── clicks ───────────────────────────────────────────────────────────────
    def _tools_click(self, cmd, arg, e):
        if string_startswith(cmd, "@live."):
            self._live_click(cmd, arg, e)
            return true
        if string_startswith(cmd, "@prof."):
            self._prof_click(cmd, arg, e)
            return true
        return IDETools._tools_click(self, cmd, arg, e)

    def _live_click(self, cmd, arg, e):
        var L = self.live
        if cmd == "@live.var":
            if arg >= len(L.rows):
                return
            self.live_sel = arg
            self.focus = "debugvars"
            var row = L.rows[arg]
            if e != none and e.clicks >= 2 and row[5] != "scope":
                self._live_set_value_prompt(arg)
            elif row[3] != 0:
                L.toggle(arg)
        elif cmd == "@live.why":
            self.live_sel = arg
            if arg < len(L.rows):
                self._exec("nython.debug.whyValue", L.rows[arg][1])
        elif cmd == "@live.frame":
            L.select_frame(arg)

    # Right-click on a live variable.
    def _live_context(self, h, e):
        var L = self.live
        if h.cmd == "@live.var" and h.arg < len(L.rows):
            self.live_sel = h.arg
            var row = L.rows[h.arg]
            if row[5] == "scope":
                return
            var expr = row[6] if row[6] != "" else row[1]
            self._open_ctx(e.x, e.y, [["Set Value", "nython.debug.setValue", h.arg],
                                      ["Why Does It Have This Value?", "nython.debug.whyValue", row[1]],
                                      ["-", "", ""],
                                      ["Copy Value", "@ctx.copytext", row[2]],
                                      ["Copy as Expression", "@ctx.copytext", expr],
                                      ["Add to Watch", "@ctx.watch", expr]])

    # ── Profile ──────────────────────────────────────────────────────────────
    def _profile_start(self):
        if not self._is_text() or self.doc().lang != "nython":
            self._notify("Open a Nython file to profile it", "warn")
            return
        if self.job_running:
            self._notify("A program is already running - stop it first (Shift+F5)", "warn")
            return
        var d = self.doc()
        var path = self._path_for_run(d)
        self.prof_out = self.tmp + "/nyide_prof_" + str(self.session_id) + ".prof"
        if os_exists(self.prof_out):
            os_remove(self.prof_out)
        self.job_mode = "cProfile"
        self.job_path = path
        self.job_doc = d
        self._output_clear()
        self._output_write("> Profile (cProfile)  " + self._rel(path), "cmd")
        self._show_panel("output")
        var cwd = self.ws.root
        if cwd == "":
            cwd = os_path_dirname(path)
        self._start_job(self._interpreter() + " -m cProfile --stacks -o " + self.prof_out + " ", path, cwd)

    def _profile_loaded(self, code):
        if self.job_killed or not os_exists(self.prof_out):
            if not self.job_killed:
                self._notify("The profile was not written (the program failed?)", "err")
            return
        if not self.prof.load(self.prof_out):
            self._notify("The profile could not be read: " + self.prof.error, "err")
            return
        self.prof_sel = -1
        self.prof_rel = []
        self.prof_title = os_path_basename(self.job_path) + "  -  " + self.prof.summary
        if self.prof.flame_exact:
            self.prof_flame_title = "Flame graph - real call paths (calling context tree); click a bar to open its source"
        else:
            self.prof_flame_title = "Flame graph - derived from caller edges (no --stacks)"
        self._show_panel("profile")
        self._notify("Profiled: " + self.prof.summary, "ok")

    # The selected function: its callers' and callees' rows, made once.
    def _prof_select(self, fi):
        var P = self.prof
        if fi < 0 or fi >= len(P.funcs):
            return
        self.prof_sel = fi
        var rows = []
        var f = P.funcs[fi]
        rows.append(["Callers of " + f.name + "   (calls  tottime  cumtime)", -1, "head", ""])
        var cs = P.callers_of(fi)
        if len(cs) == 0:
            rows.append(["    (none: called from outside the profile)", -1, "none", ""])
        for c in cs:
            rows.append(["    " + self._prof_calls(c) + "  " + prof_fmt(c[3]) + "  " + prof_fmt(c[4]) + "   " + P.funcs[c[0]].short, c[0], "caller",
                         "Select and open " + P.funcs[c[0]].label])
        rows.append(["Callees of " + f.name, -1, "head", ""])
        var ce = P.callees_of(fi)
        if len(ce) == 0:
            rows.append(["    (none)", -1, "none", ""])
        for c2 in ce:
            rows.append(["    " + self._prof_calls(c2) + "  " + prof_fmt(c2[3]) + "  " + prof_fmt(c2[4]) + "   " + P.funcs[c2[0]].short, c2[0], "callee",
                         "Select and open " + P.funcs[c2[0]].label])
        self.prof_rel = rows
        self._dirty = true

    def _prof_calls(self, c):
        if c[1] == c[2]:
            return str(c[1])
        return str(c[1]) + "/" + str(c[2])

    def _prof_open(self, fi):
        var f = self.prof.funcs[fi]
        if f.builtin or not os_exists(f.file):
            self.status_msg = f.label + " is built in (no source)"
            return
        self._open_path(f.file, f.line - 1, 0)

    def _prof_click(self, cmd, arg, e):
        if cmd == "@prof.sort":
            self.prof.sort(self.prof_cols[arg])
            self.panel_scroll = 0
        elif cmd == "@prof.row" or cmd == "@prof.rel":
            if arg >= 0:
                self._prof_select(arg)
                self._prof_open(arg)
        elif cmd == "@prof.flame":
            if arg < len(self.prof.flame):
                var fi = self.prof.flame[arg][3]
                self._prof_select(fi)
                self._prof_open(fi)
        self._dirty = true

    def _draw_profile(self, r, x, y, w, h):
        var th = self.th
        var P = self.prof
        self._hit(x, y, w, h, "@panel.body", "profile", "")
        if len(P.funcs) == 0:
            r.text("Run > Profile with cProfile (Flame Graph) runs the active file under cProfile and shows where its time goes.",
                   x + self.dp(16), y + self.dp(10), self.f_ui, th.text_faint)
            return
        r.text(self.prof_title, x + self.dp(16), y + self.dp(6), self.f_ui_bold, th.text)
        var lh = self.dp(18)
        var tw = int(w * 0.55)
        var ty = y + self.dp(28)
        # the table's headings: click to sort
        var cx = x + self.dp(16)
        var k = 0
        while k < 6:
            var cw = self.dp(self.prof_widths[k])
            if k == 5:
                cw = x + tw - cx
            var active = self.prof_cols[k] == P.sort_key
            var hc = th.text if active else th.text_dim
            if self._hov(cx, ty, cw, lh):
                r.fill_xywh(cx, ty, cw, lh, th.hover)
            var hl = self.prof_heads[k]
            var hx = cx + cw - self.dp(8) - self.f_small_bold.width(hl)
            if k == 5:
                hx = cx + self.dp(4)
            r.text(hl, hx, ty + int((lh - self.small_h) / 2), self.f_small_bold, hc)
            if active:
                var ic = "chevron-down" if P.sort_desc else "chevron-up"
                self.icons.draw(r, ic, hx - self.dp(14) if k < 5 else hx + self.f_small_bold.width(hl) + self.dp(2), ty + self.dp(2), self.dp(14), th.accent)
            self._hit(cx, ty, cw, lh, "@prof.sort", k, self.prof_sort_tips[k])
            cx = cx + cw
            k = k + 1
        r.fill_xywh(x + self.dp(16), ty + lh, tw - self.dp(16), 1, th.panel_border)
        var rel_n = 0
        if self.prof_sel >= 0:
            rel_n = len(self.prof_rel)
            if rel_n > 8:
                rel_n = 8
        var rows_top = ty + lh + self.dp(2)
        var rows_h = y + h - rows_top - rel_n * lh - self.dp(6)
        var nrows = int(rows_h / lh)
        if nrows < 1:
            nrows = 1
        var n = len(P.order)
        var first = self.panel_scroll
        if first > n - nrows:
            first = n - nrows
        if first < 0:
            first = 0
        self.panel_scroll = first
        var i = 0
        var ry = rows_top
        while i < nrows and first + i < n:
            var fi = P.order[first + i]
            var f = P.funcs[fi]
            if fi == self.prof_sel:
                r.fill_xywh(x + self.dp(8), ry, tw - self.dp(8), lh, th.list_inactive)
            elif self._hov(x + self.dp(8), ry, tw - self.dp(8), lh):
                r.fill_xywh(x + self.dp(8), ry, tw - self.dp(8), lh, th.hover)
            var tyy = ry + int((lh - self.code_small_h) / 2)
            cx = x + self.dp(16)
            cx = self._prof_cell(r, cx, self.dp(self.prof_widths[0]), tyy, f.s_calls)
            cx = self._prof_cell(r, cx, self.dp(self.prof_widths[1]), tyy, f.s_tt)
            cx = self._prof_cell(r, cx, self.dp(self.prof_widths[2]), tyy, f.s_pc)
            cx = self._prof_cell(r, cx, self.dp(self.prof_widths[3]), tyy, f.s_ct)
            cx = self._prof_cell(r, cx, self.dp(self.prof_widths[4]), tyy, f.s_pc2)
            r.text(f.short, cx + self.dp(4), tyy, self.f_mono_small, th.info if not f.builtin else th.text_dim)
            self._hit(x + self.dp(8), ry, tw - self.dp(8), lh, "@prof.row", fi, f.label)
            ry = ry + lh
            i = i + 1
        # the selection's callers and callees
        if rel_n > 0:
            var yy = y + h - rel_n * lh - self.dp(4)
            r.fill_xywh(x + self.dp(16), yy - self.dp(2), tw - self.dp(16), 1, th.panel_border)
            var j = 0
            while j < rel_n:
                var rr = self.prof_rel[j]
                var rc = th.text
                if rr[2] == "head":
                    rc = th.text_dim
                elif rr[2] == "none":
                    rc = th.text_faint
                elif self._hov(x + self.dp(8), yy, tw - self.dp(8), lh):
                    r.fill_xywh(x + self.dp(8), yy, tw - self.dp(8), lh, th.hover)
                r.text(rr[0], x + self.dp(16), yy + int((lh - self.code_small_h) / 2), self.f_mono_small if rr[2] != "head" else self.f_small_bold, rc)
                if rr[1] >= 0:
                    self._hit(x + self.dp(8), yy, tw - self.dp(8), lh, "@prof.rel", rr[1], rr[3])
                yy = yy + lh
                j = j + 1
        # the flame graph (an icicle: the root at the top)
        var fx = x + tw + self.dp(16)
        var fw = x + w - fx - self.dp(12)
        if fw < self.dp(80):
            return
        r.text(self.prof_flame_title, fx, y + self.dp(6), self.f_small, th.text_dim)
        var fy = ty
        var bh = self.dp(18)
        var bottom = y + h - self.dp(4)
        var bi = 0
        var nb = len(P.flame)
        var np = len(self.prof_palette)
        while bi < nb:
            var b = P.flame[bi]
            var bx = fx + int(b[0] * fw)
            var bw = int((b[1] - b[0]) * fw)
            var by = fy + b[2] * bh
            if bw >= 1 and by + bh <= bottom:
                var bf = P.funcs[b[3]]
                r.fill_xywh(bx, by, bw - 1 if bw > 2 else bw, bh - 1, self.prof_palette[bf.color % np])
                if b[3] == self.prof_sel:
                    r.round_rect_xywh(bx, by, bw - 1 if bw > 2 else bw, bh - 1, th.text, 0, 1)
                if bw > self.dp(30):
                    r.clip_xywh(bx + self.dp(2), by, bw - self.dp(4), bh)
                    r.text(bf.name, bx + self.dp(3), by + int((bh - self.small_h) / 2), self.f_small, self.prof_bar_fg)
                    r.clip_xywh(x, y, w, h)
                self._hit(bx, by, bw, bh, "@prof.flame", bi, P.flame_tips[bi])
            bi = bi + 1

    def _prof_cell(self, r, cx, cw, ty, s):
        r.text(s, cx + cw - self.dp(8) - self.f_mono_small.width(s), ty, self.f_mono_small, self.th.text)
        return cx + cw

    # ── the state dump (tools/ide_e2e.py) ────────────────────────────────────
    def _tools_dump(self, st):
        IDETools._tools_dump(self, st)
        var L = self.live
        st["live_active"] = L.active
        st["live_state"] = L.state
        st["live_reason"] = L.reason
        st["live_line"] = L.line
        st["live_path"] = L.path
        st["live_stops"] = L.stops
        st["live_frames"] = [[f[1], f[3]] for f in L.frames]
        st["live_frame_sel"] = L.frame_sel
        st["live_vars"] = [[row[0], row[1], row[2]] for row in L.rows]
        var wv = {}
        for k in L.watch_vals.keys():
            wv[k] = L.watch_vals[k][0]
        st["live_watch"] = wv
        st["live_history"] = L.history
        st["live_exit"] = L.exit_code
        st["live_status"] = self.live_status
        st["live_exc"] = [self.live_exc_raised, self.live_exc_uncaught]
        st["live_exc_text"] = L.exc_text
        st["dbgcon"] = self.dbgcon_lines[-40:]
        st["prof_n"] = len(self.prof.funcs)
        st["prof_sort"] = [self.prof.sort_key, self.prof.sort_desc]
        st["prof_rows"] = [self.prof.funcs[i].name for i in self.prof.order[:12]]
        st["prof_flame_n"] = len(self.prof.flame)
        st["prof_exact"] = self.prof.flame_exact
        st["prof_sel"] = self.prof.funcs[self.prof_sel].name if self.prof_sel >= 0 else ""
        st["prof_rel"] = [row[0] for row in self.prof_rel]
