# ══════════════════════════════════════════════════════════════════════════════
#  lib/ide_workbench.ny — the workbench model behind nython_ide.ny
#
#  Everything here is independent of drawing and of SDL, so it is testable
#  without a window (examples/vm_audit42.ny exercises all of it on both
#  engines).
#
#  CommandRegistry  VS Code's command model. Every menu entry, palette entry,
#                   context-menu entry, status-bar item and keybinding refers
#                   to a command id. Before this, the menus, the palette and
#                   the keyboard each had their own list of label strings and
#                   their own if/elif chain; six of the palette's eleven
#                   entries matched nothing and silently did nothing.
#  HitMap           Clickable regions, registered by the code that DRAWS them
#                   in the same frame. Clicks resolve against what was painted,
#                   so a hit area cannot drift away from its drawing (the
#                   toolbar Run button's hit box was hard-coded and did).
#                   Pooled: the interpreter never reclaims instances
#                   (GC_NOTES.md), so the map reuses its entries every frame.
#  Frecency         Exponentially decayed visit counts (Firefox-style
#                   "frecency"), used to rank Quick Open and the palette.
#  QuickInput       The model behind VS Code's quick input widget: Quick Open,
#                   Command Palette, Go to Line, Go to Symbol and pickers.
#  Notifications    Toasts plus the history the bell in the status bar opens.
#  NavHistory       Alt+Left / Alt+Right cursor-location history.
# ══════════════════════════════════════════════════════════════════════════════

import "lib/gui_motion.ny"


# ─── commands and keybindings ─────────────────────────────────────────────────

class Command:
    def __init__(self, id, category, title, keys, when):
        self.id = id
        self.category = category
        self.title = title
        self.keys = keys          # display form: "Ctrl+Shift+P", "Ctrl+K Ctrl+O"
        self.when = when
        self.label = title
        if category != "":
            self.label = category + ": " + title


class Keybinding:
    def __init__(self, seq, cmd, when):
        self.seq = seq            # normalised: "ctrl+shift+p" or "ctrl+k ctrl+o"
        self.cmd = cmd
        self.when = when


class CommandRegistry:
    def __init__(self):
        self.cmds = {}
        self.order = []
        self.n = 0
        self.bindings = []        # every Keybinding, in registration order
        self.prefixes = {}        # first half of every chord
        self.pending = ""         # chord prefix waiting for its second key
        self.last_miss = ""

    # add(id, category, title, keys, when). `keys` may hold several
    # alternatives separated by " | ", e.g. "Ctrl+Y | Ctrl+Shift+Z"; the first
    # is the one menus display.
    def add(self, id, category, title, keys, when):
        var shown = keys
        var alts = []
        if keys != "":
            alts = string_split(keys, " | ")
            shown = string_strip(alts[0])
        var c = Command(id, category, title, shown, when)
        if not self.cmds.has_key(id):
            self.order.append(id)
            self.n = self.n + 1
        self.cmds[id] = c
        var i = 0
        while i < len(alts):
            self.bind(id, string_strip(alts[i]), when)
            i = i + 1
        return c

    def bind(self, id, keys, when):
        var seq = self.normalize(keys)
        if seq == "":
            return false
        self.bindings.append(Keybinding(seq, id, when))
        var sp = string_find(seq, " ")
        if sp > 0:
            self.prefixes[string_slice(seq, 0, sp)] = true
        return true

    # ── keymaps ───────────────────────────────────────────────────────────
    # set_keys(id, keys, when) gives a command a new set of keybindings, as a
    # keymap preset or a user rebinding does: the command's old bindings go,
    # and any other command bound to one of the new keys loses that binding
    # (its displayed shortcut falls back to its next remaining one). keys ""
    # unbinds the command.
    def set_keys(self, id, keys, when):
        if not self.cmds.has_key(id):
            return false
        var alts = []
        if keys != "":
            alts = string_split(keys, " | ")
        var seqs = {}
        var i = 0
        while i < len(alts):
            var sq = self.normalize(string_strip(alts[i]))
            if sq != "":
                seqs[sq] = true
            i = i + 1
        var kept = []
        var touched = {}
        i = 0
        while i < len(self.bindings):
            var b = self.bindings[i]
            if b.cmd == id:
                i = i + 1
                continue
            if seqs.has_key(b.seq):
                touched[b.cmd] = true
                i = i + 1
                continue
            kept.append(b)
            i = i + 1
        self.bindings = kept
        var shown = ""
        i = 0
        while i < len(alts):
            if self.bind(id, string_strip(alts[i]), when) and shown == "":
                shown = string_strip(alts[i])
            i = i + 1
        self.cmds[id].keys = shown
        var others = touched.keys()
        i = 0
        while i < len(others):
            self._refresh_keys(others[i])
            i = i + 1
        return true

    # The shortcut a menu shows for `id`: its first remaining binding.
    def _refresh_keys(self, id):
        if not self.cmds.has_key(id):
            return
        var i = 0
        while i < len(self.bindings):
            if self.bindings[i].cmd == id:
                self.cmds[id].keys = self.pretty(self.bindings[i].seq)
                return
            i = i + 1
        self.cmds[id].keys = ""

    # A copy of every binding and displayed shortcut, to return to later
    # (switching keymap presets starts from the defaults).
    def snapshot(self):
        var keys = {}
        var i = 0
        while i < len(self.order):
            keys[self.order[i]] = self.cmds[self.order[i]].keys
            i = i + 1
        var binds = []
        i = 0
        while i < len(self.bindings):
            binds.append(self.bindings[i])
            i = i + 1
        return [binds, keys]

    def restore(self, snap):
        var binds = []
        var i = 0
        while i < len(snap[0]):
            binds.append(snap[0][i])
            i = i + 1
        self.bindings = binds
        self.prefixes = {}
        i = 0
        while i < len(binds):
            var sp = string_find(binds[i].seq, " ")
            if sp > 0:
                self.prefixes[string_slice(binds[i].seq, 0, sp)] = true
            i = i + 1
        var ks = snap[1]
        i = 0
        while i < len(self.order):
            var id = self.order[i]
            if ks.has_key(id):
                self.cmds[id].keys = ks[id]
            i = i + 1

    # Commands bound to a key sequence, for "key already in use" warnings.
    def commands_for(self, keys):
        var seq = self.normalize(keys)
        var out = []
        var i = 0
        while i < len(self.bindings):
            if self.bindings[i].seq == seq:
                out.append(self.bindings[i].cmd)
            i = i + 1
        return out

    def has(self, id):
        return self.cmds.has_key(id)

    def get(self, id):
        if self.cmds.has_key(id):
            return self.cmds[id]
        return none

    def label(self, id):
        var c = self.get(id)
        if c == none:
            return id
        return c.label

    def title(self, id):
        var c = self.get(id)
        if c == none:
            return id
        return c.title

    def keys_of(self, id):
        var c = self.get(id)
        if c == none:
            return ""
        return c.keys

    # ── key normalisation ─────────────────────────────────────────────────
    # "Ctrl+Shift+P" -> "ctrl+shift+p". Modifiers are put in a fixed order so
    # "Shift+Ctrl+P" and "Ctrl+Shift+P" are the same binding.
    def normalize(self, keys):
        var parts = string_split(string_strip(keys), " ")
        var out = ""
        var i = 0
        while i < len(parts):
            var p = string_strip(parts[i])
            if p != "":
                var one = self._norm_part(p)
                if out == "":
                    out = one
                else:
                    out = out + " " + one
            i = i + 1
        return out

    def _norm_part(self, part):
        var p = string_lower(part)
        var key = ""
        var mods = ""
        if string_endswith(p, "++"):
            key = "+"
            mods = string_slice(p, 0, len(p) - 2)
        elif p == "+":
            key = "+"
        else:
            var cut = -1
            var i = 0
            while i < len(p):
                if string_slice(p, i, i + 1) == "+":
                    cut = i
                i = i + 1
            if cut < 0:
                key = p
            else:
                key = string_slice(p, cut + 1, len(p))
                mods = string_slice(p, 0, cut)
        return self._canon(string_find(mods, "ctrl") >= 0,
                           string_find(mods, "shift") >= 0,
                           string_find(mods, "alt") >= 0,
                           self._alias(key))

    def _alias(self, key):
        if key == "esc":
            return "escape"
        if key == "return":
            return "enter"
        if key == "pgup" or key == "page up":
            return "pageup"
        if key == "pgdn" or key == "page down":
            return "pagedown"
        if key == "del":
            return "delete"
        if key == "plus":
            return "+"
        if key == "minus":
            return "-"
        return key

    def _canon(self, ctrl, shift, alt, key):
        var s = ""
        if ctrl:
            s = "ctrl+"
        if shift:
            s = s + "shift+"
        if alt:
            s = s + "alt+"
        return s + key

    def event_key(self, e):
        return self._canon(e.ctrl, e.shift, e.alt, self._alias(e.key))

    # ── when-clauses ──────────────────────────────────────────────────────
    # The subset VS Code keybindings actually use here: "name", "!name" and
    # conjunctions with "&&". ctx is a map of context keys to booleans.
    def when_ok(self, when, ctx):
        if when == "":
            return true
        var terms = string_split(when, "&&")
        var i = 0
        while i < len(terms):
            var t = string_strip(terms[i])
            var neg = false
            if string_startswith(t, "!"):
                neg = true
                t = string_strip(string_slice(t, 1, len(t)))
            var v = false
            if ctx.has_key(t):
                v = ctx[t] == true
            if neg:
                v = not v
            if not v:
                return false
            i = i + 1
        return true

    # Later bindings win over earlier ones, as in VS Code, so a context-
    # specific rule registered after a general one overrides it.
    def _match(self, seq, ctx):
        var i = len(self.bindings) - 1
        while i >= 0:
            var b = self.bindings[i]
            if b.seq == seq:
                if self.when_ok(b.when, ctx):
                    return b.cmd
            i = i - 1
        return ""

    # Returns a command id, "" for no binding, "__chord__" when the key started
    # a chord (Ctrl+K ...), or "__chord_miss__" when the second key of a chord
    # matched nothing (self.last_miss holds the combination for the message).
    def resolve(self, e, ctx):
        var k = self.event_key(e)
        if k == "ctrl" or k == "shift" or k == "alt" or string_endswith(k, "+ctrl") or string_endswith(k, "+shift") or string_endswith(k, "+alt"):
            return ""
        if self.pending != "":
            var full = self.pending + " " + k
            self.pending = ""
            var hit = self._match(full, ctx)
            if hit != "":
                return hit
            self.last_miss = full
            return "__chord_miss__"
        var hit2 = self._match(k, ctx)
        if hit2 != "":
            return hit2
        if self.prefixes.has_key(k):
            self.pending = k
            return "__chord__"
        return ""

    # "ctrl+shift+p" -> "Ctrl+Shift+P", for messages about a chord in flight.
    def pretty(self, seq):
        var parts = string_split(seq, " ")
        var out = ""
        var i = 0
        while i < len(parts):
            var keys = string_split(parts[i], "+")
            var one = ""
            var j = 0
            while j < len(keys):
                var k = keys[j]
                var pk = k
                if len(k) == 1:
                    pk = string_upper(k)
                elif k == "ctrl":
                    pk = "Ctrl"
                elif k == "shift":
                    pk = "Shift"
                elif k == "alt":
                    pk = "Alt"
                elif string_startswith(k, "f") and len(k) <= 3:
                    pk = string_upper(k)
                else:
                    pk = string_upper(string_slice(k, 0, 1)) + string_slice(k, 1, len(k))
                if one == "":
                    one = pk
                else:
                    one = one + "+" + pk
                j = j + 1
            if out == "":
                out = one
            else:
                out = out + " " + one
            i = i + 1
        return out


# ─── hit map ──────────────────────────────────────────────────────────────────

class Hit:
    def __init__(self):
        self.x = 0
        self.y = 0
        self.w = 0
        self.h = 0
        self.cmd = ""
        self.arg = ""
        self.tip = ""


class HitMap:
    def __init__(self):
        self.pool = []
        self.n = 0

    def clear(self):
        self.n = 0

    # Later registrations are on top: overlays are drawn after the chrome
    # beneath them, so they win automatically, and a click can no longer fall
    # through an open menu onto the toolbar under it.
    def add(self, x, y, w, h, cmd, arg, tip):
        var it = none
        if self.n < len(self.pool):
            it = self.pool[self.n]
        else:
            it = Hit()
            self.pool.append(it)
        it.x = x
        it.y = y
        it.w = w
        it.h = h
        it.cmd = cmd
        it.arg = arg
        it.tip = tip
        self.n = self.n + 1
        return it

    def at(self, x, y):
        var i = self.n - 1
        while i >= 0:
            var it = self.pool[i]
            if x >= it.x and x < it.x + it.w and y >= it.y and y < it.y + it.h:
                return it
            i = i - 1
        return none

    def count(self):
        return self.n

    # One line per region, for the dead-click audit (tools/ide_e2e.py).
    def dump(self):
        var out = ""
        var i = 0
        while i < self.n:
            var it = self.pool[i]
            out = out + str(it.x) + "\t" + str(it.y) + "\t" + str(it.w) + "\t" + str(it.h) + "\t" + it.cmd + "\t" + str(it.arg) + "\t" + it.tip + "\n"
            i = i + 1
        return out


# ─── frecency ─────────────────────────────────────────────────────────────────
# Each visit adds 1 and every score halves over `half_life_ms`. Only a score
# and a timestamp are stored per key, and ranking needs no visit log: the
# decay is applied lazily at read time. A command used five times an hour ago
# and one used once a minute ago end up close, which is the behaviour a
# "recently used" list wants and a plain counter or a plain MRU list lacks.

class Frecency:
    def __init__(self, half_life_ms):
        self.half = float(half_life_ms)
        self.scores = {}
        self.stamps = {}

    def touch(self, key, now):
        self.scores[key] = self.score(key, now) + 1.0
        self.stamps[key] = now

    def score(self, key, now):
        if not self.scores.has_key(key):
            return 0.0
        var dt = float(now - self.stamps[key])
        if dt < 0.0:
            dt = 0.0
        return self.scores[key] * pow(2.0, 0.0 - dt / self.half)

    def known(self, key):
        return self.scores.has_key(key)


# ─── quick input ──────────────────────────────────────────────────────────────

class QuickItem:
    def __init__(self, label, detail, value, icon):
        self.label = label
        self.detail = detail
        self.value = value
        self.icon = icon
        self.keys = ""            # keybinding shown at the right (palette)
        self.boost = 0.0          # frecency bonus
        self.score = 0
        self.pos = []             # matched character positions, for bolding
        self.pos_q = "\x01"       # the query `pos` was computed for
        self.pos_x = []           # x offset of each matched character
        self.pos_ch = []          # each matched character
        self.hit = 0              # refilter generation that last matched it
        self.idx = 0
        self.group = ""           # section header drawn above this item


class QuickInput:
    def __init__(self):
        self.fuzzy = Fuzzy()
        self.visible = false
        self.kind = ""            # files | commands | line | symbols | pick | prompt
        self.title = ""
        self.placeholder = ""
        self.value = ""
        self.items = []
        self.shown = []
        self.n = 0
        self.sel = 0
        self.top = 0
        self.free_text = false    # Enter accepts the typed text itself
        self.action = ""          # what accepting means, interpreted by the IDE
        self.data = none
        self.strip_prefix = ""    # e.g. ">" in the command palette
        self.max_rows = 12
        self.sel_moved = false    # the user picked an item with the keyboard
        # Ranking inputs, built once per item list (not per keystroke):
        # labels, "folder/label" paths, and each item's frecency bonus.
        self._labels = none
        self._paths = none
        self._bonus = none
        self.gen = 0

    def open(self, kind, title, placeholder, items, value):
        self.visible = true
        self.kind = kind
        self.title = title
        self.placeholder = placeholder
        self.free_text = false
        self.action = ""
        self.data = none
        self.strip_prefix = ""
        self.sel_moved = false
        self.items = items
        var i = 0
        while i < len(items):
            items[i].idx = i
            i = i + 1
        self._labels = none
        self.value = value
        self.refilter()

    def close(self):
        self.visible = false
        self.items = []
        self.shown = []
        self.n = 0

    def set_items(self, items):
        self.items = items
        var i = 0
        while i < len(items):
            items[i].idx = i
            i = i + 1
        self._labels = none
        self.refilter()

    def _index(self):
        var labels = []
        var paths = []
        var bonus = []
        var any_detail = false
        var i = 0
        while i < len(self.items):
            var it = self.items[i]
            labels.append(it.label)
            if it.detail != "":
                any_detail = true
                paths.append(it.detail + "/" + it.label)
            else:
                paths.append(it.label)
            bonus.append(int(it.boost * 20.0))
            i = i + 1
        self._labels = labels
        self._paths = none
        if any_detail:
            self._paths = paths
        self._bonus = bonus

    def query(self):
        var q = self.value
        if self.strip_prefix != "" and string_startswith(q, self.strip_prefix):
            q = string_slice(q, len(self.strip_prefix), len(q))
        return string_strip(q)

    def set_value(self, v):
        self.value = v
        self.refilter()

    # Empty query: items in their given order (the IDE pre-sorts by frecency).
    # Otherwise: items whose label matches, ranked by match score plus the
    # frecency boost, then items that match only through their folder
    # ("src/util" finds util.ny). Ranking is the native fuzzy_rank
    # (include/NyFuzzy.hpp): best alignment, and nothing allocated per item.
    def refilter(self):
        var q = self.query()
        var out = []
        var i = 0
        if q == "" or self.kind == "prompt" or self.kind == "line":
            while i < len(self.items):
                out.append(self.items[i])
                i = i + 1
        else:
            if self._labels == none:
                self._index()
            self.gen = self.gen + 1
            var idx = fuzzy_rank(q, self._labels, 0, self._bonus)
            while i < len(idx):
                var it = self.items[idx[i]]
                it.hit = self.gen
                out.append(it)
                i = i + 1
            if self._paths != none:
                var idx2 = fuzzy_rank(q, self._paths, 0, self._bonus)
                i = 0
                while i < len(idx2):
                    var it2 = self.items[idx2[i]]
                    if it2.hit != self.gen:
                        it2.hit = self.gen
                        out.append(it2)
                    i = i + 1
        self.shown = out
        self.n = len(out)
        self.sel = 0
        self.top = 0

    def move(self, d):
        if self.n == 0:
            return
        self.sel_moved = true
        self.sel = self.sel + d
        if self.sel < 0:
            self.sel = self.n - 1
        if self.sel >= self.n:
            self.sel = 0
        if self.sel < self.top:
            self.top = self.sel
        if self.sel >= self.top + self.max_rows:
            self.top = self.sel - self.max_rows + 1

    def page(self, d):
        var i = 0
        while i < self.max_rows - 1:
            if (d > 0 and self.sel < self.n - 1) or (d < 0 and self.sel > 0):
                self.move(d)
            i = i + 1

    def current(self):
        if self.sel >= 0 and self.sel < self.n:
            return self.shown[self.sel]
        return none

    def backspace(self):
        if len(self.value) > 0:
            self.set_value(string_slice(self.value, 0, len(self.value) - 1))

    def type_text(self, t):
        self.set_value(self.value + t)


# ─── single-line text field ───────────────────────────────────────────────────
# A caret and an anchor over a string that lives elsewhere (each workbench
# input keeps its value in its own attribute). Quick Input, Find/Replace,
# Search, the SCM message, the terminal and Debug Console prompts all edit
# through one of these, so each behaves like a VS Code input: the caret moves,
# Shift extends, Ctrl jumps by word, and typing replaces the selection.
#
# `known` is the value as this field last left it. When the owner replaces the
# value by other means (history recall, a picker filling it in) the field
# notices on the next sync and puts the caret at the end, so no setter in the
# IDE has to remember to reposition it.

class LineEdit:
    def __init__(self):
        self.caret = 0
        self.anchor = 0
        self.known = ""

    def sync(self, v):
        if v != self.known:
            self.caret = len(v)
            self.anchor = self.caret
            self.known = v
        if self.caret > len(v):
            self.caret = len(v)
        if self.anchor > len(v):
            self.anchor = len(v)

    # Take `v` as the field's value; select all of it (a prompt pre-filled
    # with a name to replace) or put the caret at the end.
    def reset(self, v, select_all):
        self.known = v
        self.caret = len(v)
        self.anchor = self.caret
        if select_all:
            self.anchor = 0

    def select(self, v, a, b):
        self.known = v
        self.anchor = a
        self.caret = b

    def has_sel(self):
        return self.caret != self.anchor

    def lo(self):
        if self.caret < self.anchor:
            return self.caret
        return self.anchor

    def hi(self):
        if self.caret > self.anchor:
            return self.caret
        return self.anchor

    def selected(self, v):
        self.sync(v)
        return string_slice(v, self.lo(), self.hi())

    def insert(self, v, t):
        self.sync(v)
        var a = self.lo()
        var out = string_slice(v, 0, a) + t + string_slice(v, self.hi(), len(v))
        self.caret = a + len(t)
        self.anchor = self.caret
        self.known = out
        return out

    def _is_word(self, ch):
        return (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_"

    def word_left(self, v, i):
        while i > 0 and not self._is_word(string_slice(v, i - 1, i)):
            i = i - 1
        while i > 0 and self._is_word(string_slice(v, i - 1, i)):
            i = i - 1
        return i

    def word_right(self, v, i):
        var n = len(v)
        while i < n and not self._is_word(string_slice(v, i, i + 1)):
            i = i + 1
        while i < n and self._is_word(string_slice(v, i, i + 1)):
            i = i + 1
        return i

    def _move(self, p, extend):
        self.caret = p
        if not extend:
            self.anchor = p

    def _cut_range(self, v, a, b):
        var out = string_slice(v, 0, a) + string_slice(v, b, len(v))
        self.caret = a
        self.anchor = a
        self.known = out
        return out

    # Editing and caret keys. Returns the new value, or none when `e` is not
    # a key a single-line field handles (Enter, Escape, Up, Down, Tab...).
    def key(self, v, e):
        self.sync(v)
        var k = e.key
        var n = len(v)
        if k == "left":
            if self.has_sel() and not e.shift:
                self._move(self.lo(), false)
            elif e.ctrl:
                self._move(self.word_left(v, self.caret), e.shift)
            elif self.caret > 0:
                self._move(self.caret - 1, e.shift)
            return v
        if k == "right":
            if self.has_sel() and not e.shift:
                self._move(self.hi(), false)
            elif e.ctrl:
                self._move(self.word_right(v, self.caret), e.shift)
            elif self.caret < n:
                self._move(self.caret + 1, e.shift)
            return v
        if k == "home":
            self._move(0, e.shift)
            return v
        if k == "end":
            self._move(n, e.shift)
            return v
        if k == "backspace":
            if self.has_sel():
                return self._cut_range(v, self.lo(), self.hi())
            if e.ctrl:
                return self._cut_range(v, self.word_left(v, self.caret), self.caret)
            if self.caret > 0:
                return self._cut_range(v, self.caret - 1, self.caret)
            return v
        if k == "delete":
            if self.has_sel():
                return self._cut_range(v, self.lo(), self.hi())
            if e.ctrl:
                return self._cut_range(v, self.caret, self.word_right(v, self.caret))
            if self.caret < n:
                return self._cut_range(v, self.caret, self.caret + 1)
            return v
        if e.ctrl and not e.alt and k == "a":
            self.anchor = 0
            self.caret = n
            return v
        return none


# ─── notifications ────────────────────────────────────────────────────────────

class Notice:
    def __init__(self, id, text, kind, t):
        self.id = id
        self.text = text
        self.kind = kind          # info | ok | warn | err
        self.t = t
        self.dismissed = false


class Notifications:
    def __init__(self):
        self.items = []
        self.seq = 0
        self.unread = 0
        self.ttl = 3800
        self.max_kept = 60

    def push(self, text, kind, now):
        self.seq = self.seq + 1
        var n = Notice(self.seq, text, kind, now)
        self.items.append(n)
        self.unread = self.unread + 1
        if len(self.items) > self.max_kept:
            var keep = []
            var i = len(self.items) - self.max_kept
            while i < len(self.items):
                keep.append(self.items[i])
                i = i + 1
            self.items = keep
        return n

    # Toasts still on screen, newest first, at most `limit`.
    def active(self, now, limit):
        var out = []
        var i = len(self.items) - 1
        while i >= 0 and len(out) < limit:
            var n = self.items[i]
            if not n.dismissed and now - n.t < self.ttl:
                out.append(n)
            i = i - 1
        return out

    def any_active(self, now):
        var i = len(self.items) - 1
        while i >= 0:
            var n = self.items[i]
            if not n.dismissed and now - n.t < self.ttl:
                return true
            if now - n.t >= self.ttl:
                return false
            i = i - 1
        return false

    def dismiss(self, id):
        var i = 0
        while i < len(self.items):
            if self.items[i].id == id:
                self.items[i].dismissed = true
            i = i + 1

    def clear(self):
        self.items = []
        self.unread = 0

    def mark_read(self):
        self.unread = 0


# ─── navigation history ───────────────────────────────────────────────────────

class NavHistory:
    def __init__(self):
        self.stack = []
        self.idx = -1
        self.limit = 50

    # Records a jump. Locations within 10 lines of the current entry in the
    # same file replace it instead of stacking, as VS Code does, so moving the
    # caret around one function does not bury the previous file.
    def push(self, path, row, col):
        if self.idx >= 0:
            var cur = self.stack[self.idx]
            if cur["path"] == path and abs(cur["row"] - row) < 10:
                cur["row"] = row
                cur["col"] = col
                return
        var keep = []
        var i = 0
        while i <= self.idx:
            keep.append(self.stack[i])
            i = i + 1
        keep.append({"path": path, "row": row, "col": col})
        if len(keep) > self.limit:
            var trimmed = []
            var j = len(keep) - self.limit
            while j < len(keep):
                trimmed.append(keep[j])
                j = j + 1
            keep = trimmed
        self.stack = keep
        self.idx = len(keep) - 1

    def can_back(self):
        return self.idx > 0

    def can_forward(self):
        return self.idx >= 0 and self.idx < len(self.stack) - 1

    def back(self):
        if not self.can_back():
            return none
        self.idx = self.idx - 1
        return self.stack[self.idx]

    def forward(self):
        if not self.can_forward():
            return none
        self.idx = self.idx + 1
        return self.stack[self.idx]
