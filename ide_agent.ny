# ══════════════════════════════════════════════════════════════════════════════
#  ide_agent.ny — IDEAgent: the programming agent in the IDE (round 82).
#  Part of the NythonIDE class chain (see ide_core.ny's header), between
#  IDELive and NythonIDE.
#
#  lib/aiagent.ny's NyxAgent answers from the workspace itself - no model,
#  no network - and is reached three ways:
#    - the Terminal's command line: @ask <question>, @explain <symbol>,
#      @test <function>, @doc <function>, @review [file], @fix [file];
#    - the Command Palette: "Agent: Ask...", "Agent: Explain Symbol",
#      "Agent: Generate Tests", "Agent: Draft Docstring", "Agent: Review
#      File", "Agent: Fix File", "Agent: Apply Fix", "Agent: Index
#      Workspace" (explain/test/doc take the word under the caret);
#    - the AGENT view (the activity bar's sparkle): the last answer, every
#      file:line in it a link, with Apply / Discard for a fix or a
#      docstring (applied to the editor as one undoable edit, after the diff
#      was shown).
#  Each answer is also written to the Output panel.
#
#  The workspace is indexed on first use (and the index kept in the IDE's
#  temporary directory, refreshed by modification times next time); a saved
#  or reloaded file is re-indexed at once, and every command first picks up
#  files changed on disk. The completion list is re-ranked by the agent's
#  model of the workspace's code once it has been trained
#  (lib/nytorch/agent_learn.ny's CompletionRanker).
#
#  Painters follow ide_paint.ny's rules: the strings drawn every frame are
#  made when an answer arrives (_agent_show), and every clickable registers
#  itself in the hit map as it is drawn.
# ══════════════════════════════════════════════════════════════════════════════

import "ide_live.ny"


class IDEAgent(IDELive):
    # Called from NythonIDE.__init__, before the commands are registered.
    def _agent_init(self):
        self.agent = none
        self.agent_reply = none
        self.agent_items = []          # AgentItem rows of the reply shown
        self.agent_n = 0
        self.agent_title = ""
        self.agent_busy = ""
        self.agent_count = 0           # answers so far
        self.agent_pending = none      # a fix / docstring reply that can be applied
        self.agent_applied = 0
        self.agent_last_verb = ""
        self.agent_rerank_n = 0        # completion lists the model re-ranked
        self.acts_agent = [["comment-discussion", "nython.agent.ask", "", "Ask the Agent..."],
                           ["checklist", "nython.agent.review", "", "Review File"],
                           ["lightbulb-autofix", "nython.agent.fix", "", "Fix File"],
                           ["database", "nython.agent.index", "", "Index Workspace"]]
        self.agent_apply_label = "Apply Fix"
        self.view_tips[6] = "Agent"
        self.view_titles[6] = "AGENT"

    # ── commands ─────────────────────────────────────────────────────────────
    def _tools_register(self):
        IDELive._tools_register(self)
        var c = self
        c._cmd("nython.agent.ask", "Agent", "Ask...", "", "")
        c._cmd("nython.agent.explain", "Agent", "Explain Symbol", "", "")
        c._cmd("nython.agent.test", "Agent", "Generate Tests", "", "")
        c._cmd("nython.agent.doc", "Agent", "Draft Docstring", "", "")
        c._cmd("nython.agent.review", "Agent", "Review File", "", "")
        c._cmd("nython.agent.fix", "Agent", "Fix File", "", "")
        c._cmd("nython.agent.applyFix", "Agent", "Apply Fix", "", "")
        c._cmd("nython.agent.discard", "Agent", "Discard Fix", "", "")
        c._cmd("nython.agent.index", "Agent", "Index Workspace", "", "")
        self.menu_items["View"].append("nython.agent.ask")
        self.keymap_default = self.reg.snapshot()

    # "AI: Analyse Current File" (round 73) is the agent's review now.
    def _exec(self, id, arg):
        if id == "nython.ai.analyze":
            self._dirty = true
            self._agent_command("review", "")
            return true
        return IDELive._exec(self, id, arg)

    def _command_enabled(self, id):
        if id == "nython.agent.applyFix" or id == "nython.agent.discard":
            return self.agent_pending != none
        return IDELive._command_enabled(self, id)

    def _tools_exec(self, id, arg):
        if not string_startswith(id, "nython.agent."):
            return IDELive._tools_exec(self, id, arg)
        var verb = string_slice(id, 13, len(id))
        if verb == "ask":
            if arg != none and arg != "":
                self._agent_command("ask", arg)
            else:
                self._open_prompt("t.agent.ask", "Ask the Agent", "A question about this workspace (where is ..., what calls ..., how does ...)", "")
        elif verb == "explain" or verb == "test" or verb == "doc":
            var sym = arg
            if sym == none or sym == "":
                sym = self._agent_symbol()
            if sym == "":
                self._open_prompt("t.agent." + verb, "Agent: " + verb, "A function or class name", "")
            else:
                self._agent_command(verb, sym)
        elif verb == "review" or verb == "fix":
            self._agent_command(verb, arg if arg != none else "")
        elif verb == "applyFix":
            self._agent_apply()
        elif verb == "discard":
            self.agent_pending = none
            self._notify("Fix discarded", "info")
        elif verb == "index":
            self._agent_index(true)
        return true

    def _tools_accept(self, action, value, item):
        if string_startswith(action, "t.agent."):
            var v = string_strip(value)
            if v != "":
                self._agent_command(string_slice(action, 8, len(action)), v)
            return
        IDELive._tools_accept(self, action, value, item)

    # The word under the caret (or the selection), for explain/test/doc.
    def _agent_symbol(self):
        if not self._is_text():
            return ""
        return self._selected_word()

    # ── the agent ────────────────────────────────────────────────────────────
    def _agent_root(self):
        if self.ws.root != "":
            return self.ws.root
        if self._is_text() and self.doc().path != "":
            return os_path_dirname(self.doc().path)
        return os_getcwd()

    def _agent_get(self):
        var root = self._agent_root()
        if self.agent == none or self.agent.root != os_path_abspath(root):
            var key = string_replace(string_replace(string_replace(os_path_abspath(root), "/", "_"), "\\", "_"), ":", "_")
            self.agent = NyxAgent(root, self.tmp + "/nyide_agent/" + key)
        return self.agent

    def _agent_index(self, force):
        var a = self._agent_get()
        if a.indexed and not force:
            a.sync()
            return a
        var t0 = time_ms()
        var n = a.index_workspace()
        a.save()
        self._notify("Agent: indexed " + str(n) + " files of " + os_path_basename(a.root) + " in " + str(int(time_ms() - t0)) + " ms", "info")
        return a

    # The document's text when it is open (unsaved edits included).
    def _agent_doc_text(self, path):
        var i = 0
        while i < len(self.docs):
            var d = self.docs[i]
            if d.kind == "file" and d.path == path and d.buf != none:
                return d.buf.get_all_text()
            i = i + 1
        return none

    def _agent_command(self, verb, arg):
        var a = self._agent_index(false)
        self.agent_last_verb = verb
        var rep = none
        try:
            if verb == "review" or verb == "fix":
                var p = arg
                if p == "" and self._is_text():
                    p = self.doc().path
                if p == "":
                    self._notify("Open a file first", "warn")
                    return none
                if not os_path_isabs(p):
                    p = path_join(a.root, p)
                if verb == "review":
                    rep = a.review(p, self._agent_doc_text(p))
                else:
                    rep = a.fix(p, self._agent_doc_text(p))
            else:
                rep = a.run_command(verb, arg, "")
        except Exception as e:
            rep = AgentReply("error", "@" + verb + " " + arg)
            rep.ok = false
            rep.add(type(e).__name__ + ": " + str(e), "err")
        self._agent_show(rep)
        return rep

    # Shows a reply: in the AGENT view, and in the Output panel.
    def _agent_show(self, rep):
        self.agent_reply = rep
        self.agent_items = rep.items
        self.agent_n = len(rep.items)
        self.agent_title = rep.title
        self.agent_count = self.agent_count + 1
        self.agent_pending = none
        if (rep.kind == "fix" or rep.kind == "doc") and rep.new_text != none and rep.diff != "":
            self.agent_pending = rep
            self.agent_apply_label = "Apply Fix" if rep.kind == "fix" else "Insert Docstring"
        self.tree_scroll = 0
        self._show_view("ai")
        self._output_write("── " + rep.title, "info")
        for it in rep.items:
            var k = "out"
            if it.style == "err" or it.style == "diff-":
                k = "err"
            elif it.style == "ok" or it.style == "diff+":
                k = "ok"
            elif it.style == "warn":
                k = "warn"
            elif it.style == "dim" or it.style == "code":
                k = "dim"
            self._output_write(it.text, k)
        if self.agent_pending != none:
            self._output_write("(Agent: Apply Fix - or the button in the AGENT view - applies it to the editor)", "dim")
        self._layout()
        self._dirty = true

    # Applies a pending fix or docstring to its editor: one undoable edit.
    def _agent_apply(self):
        var rep = self.agent_pending
        if rep == none:
            return false
        if not self._open_path(rep.path, -1, 0):
            return false
        var b = self.buf()
        var row = b.cursor_row
        var g = b.open_group()
        var last = b.line_count - 1
        b.delete_range(0, 0, last, len(b.get_line(last)))
        b.cursor_row = 0
        b.cursor_col = 0
        b.insert_text(rep.new_text)
        b.close_group(g)
        if row < b.line_count:
            b.cursor_row = row
            b.cursor_col = 0
        self._after_edit()
        self.agent_pending = none
        self.agent_applied = self.agent_applied + 1
        self._notify("Agent: " + ("fixes" if rep.kind == "fix" else "docstring") + " applied to " + os_path_basename(rep.path) + " (Ctrl+Z undoes)", "ok")
        self._dirty = true
        return true

    # A file was written or reloaded: the agent learns it at once.
    def _agent_file_changed(self, path):
        if self.agent != none and self.agent.indexed:
            self.agent.file_changed(path)

    def _write_doc(self, d, path):
        var ok = IDELive._write_doc(self, d, path)
        if ok:
            self._agent_file_changed(path)
        return ok

    def _reload_from_disk(self, d):
        IDELive._reload_from_disk(self, d)
        if d.path != "":
            self._agent_file_changed(d.path)

    # The completion list, re-ranked by the agent's model of this workspace's
    # code (NythonIDE._ac_open_now calls it after the native ranking).
    def _agent_rerank(self, row_text, start, typed):
        if self.agent == none or not self.agent.ranker.trained() or len(self.ac_items) < 2:
            return
        var rr = self.agent.rerank(self.ac_items, self.ac_kinds, string_slice(row_text, 0, start), typed)
        self.ac_items = rr[0]
        self.ac_kinds = rr[1]
        self.agent_rerank_n = self.agent_rerank_n + 1

    # ── painting: the AGENT view ─────────────────────────────────────────────
    def _draw_ai(self, r, x, w):
        var th = self.th
        self._view_actions(r, x, w, self.acts_agent)
        var y = self.content_y + self.SIDE_HEAD
        if self.agent_reply == none:
            self._draw_agent_intro(r, x, w, y)
            return
        r.clip_xywh(x, y, w - self.dp(4), self.status_y - y)
        r.text(self.agent_title, x + self.dp(14), y + self.dp(4), self.f_ui_bold, th.text)
        y = y + self.dp(26)
        if self.agent_pending != none:
            var bw = int((w - self.dp(36)) / 2)
            self._button(r, x + self.dp(14), y, bw, self.dp(24), self.agent_apply_label, "nython.agent.applyFix", "", true)
            self._button(r, x + self.dp(22) + bw, y, bw, self.dp(24), "Discard", "nython.agent.discard", "", false)
            y = y + self.dp(32)
        var lh = self.ROW_H
        var i = self.tree_scroll
        while i < self.agent_n and y + lh <= self.status_y:
            var it = self.agent_items[i]
            var linked = it.path != ""
            if linked and self._hov(x, y, w, lh):
                r.fill_xywh(x, y, w, lh, th.hover)
            var font = self.f_small
            var col = th.text
            var st = it.style
            if st == "head":
                font = self.f_small_bold
            elif st == "code" or st == "diff+" or st == "diff-":
                font = self.f_mono_small
                col = th.text_dim
                if st == "diff+":
                    col = th.git_add
                elif st == "diff-":
                    col = th.git_del
            elif st == "dim":
                col = th.text_faint
            elif st == "ok":
                col = th.ok
            elif st == "warn":
                col = th.warn
            elif st == "err":
                col = th.err
            if linked and st != "code":
                col = th.link if st == "head" else col
            r.text(it.text, x + self.dp(14), y + int((lh - self.small_h) / 2), font, col)
            if linked:
                self._hit(x, y, w, lh, "@agent.link", i, "")
            y = y + lh
            i = i + 1
        r.clear_clip()

    def _draw_agent_intro(self, r, x, w, y):
        var th = self.th
        r.text("Ask about this workspace:", x + self.dp(14), y + self.dp(6), self.f_ui_bold, th.text)
        self._button(r, x + self.dp(14), y + self.dp(30), w - self.dp(28), self.dp(26), "Ask the Agent...", "nython.agent.ask", "", true)
        self._button(r, x + self.dp(14), y + self.dp(62), w - self.dp(28), self.dp(26), "Review This File", "nython.agent.review", "", false)
        var ty = y + self.dp(100)
        r.text("In the Terminal:", x + self.dp(14), ty, self.f_small_bold, th.text_dim)
        r.text("@ask <question>   @explain <symbol>", x + self.dp(14), ty + self.dp(18), self.f_mono_small, th.text_faint)
        r.text("@test <function>  @doc <function>", x + self.dp(14), ty + self.dp(34), self.f_mono_small, th.text_faint)
        r.text("@review [file]    @fix [file]", x + self.dp(14), ty + self.dp(50), self.f_mono_small, th.text_faint)
        r.text("Answers come from your code: no model, no network.", x + self.dp(14), ty + self.dp(76), self.f_small, th.text_faint)

    # ── clicks ───────────────────────────────────────────────────────────────
    def _tools_click(self, cmd, arg, e):
        if cmd == "@agent.link":
            if arg < self.agent_n:
                var it = self.agent_items[arg]
                if it.path != "":
                    self._open_path(it.path, max(it.line - 1, 0), 0)
                    self.focus = "editor"
            return true
        return IDELive._tools_click(self, cmd, arg, e)

    # ── the state dump (tools/ide_e2e.py) ────────────────────────────────────
    def _tools_dump(self, st):
        IDELive._tools_dump(self, st)
        st["agent_kind"] = self.agent_reply.kind if self.agent_reply != none else ""
        st["agent_ok"] = self.agent_reply.ok if self.agent_reply != none else false
        st["agent_title"] = self.agent_title
        st["agent_items"] = [it.text for it in self.agent_items[0:60]]
        st["agent_links"] = [[os_path_basename(it.path), it.line] for it in self.agent_items[0:60] if it.path != ""]
        st["agent_pending"] = self.agent_pending != none
        st["agent_applied"] = self.agent_applied
        st["agent_count"] = self.agent_count
        st["agent_files"] = len(self.agent.index.files) if self.agent != none else 0
        st["agent_trained"] = self.agent.ranker.files if self.agent != none else 0
        st["agent_rerank_n"] = self.agent_rerank_n
