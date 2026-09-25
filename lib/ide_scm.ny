# ══════════════════════════════════════════════════════════════════════════════
#  lib/ide_scm.ny — Source Control for NythonIDE: real git, and live gutter
#  change markers.
#
#  GitRepo   shells out to the git on PATH (os_exec), like VS Code's built-in
#            git extension does. Nothing here is simulated: stage, unstage,
#            discard, commit, branch and checkout run the real commands and
#            the view re-reads `git status` afterwards.
#
#  LineDiff  Myers' O(ND) difference algorithm (E. Myers, "An O(ND) Difference
#            Algorithm and Its Variations", Algorithmica 1986) over lines, used
#            to paint VS Code's gutter change bars: green added, blue modified,
#            a red marker where lines were removed. It runs against the
#            UNSAVED buffer, so the markers move as you type, not only on save.
#            Two adaptations for this runtime, which never reclaims containers
#            (GC_NOTES.md): common prefix and suffix are trimmed before the
#            search (typical edits leave only a few lines in the middle), and
#            the edit distance is capped - past the cap the differing middle
#            is reported as modified rather than searched, bounding both time
#            and the permanent memory a single diff can cost.
#
#  Tested without a window or a repository by examples/vm_audit43.ny.
# ══════════════════════════════════════════════════════════════════════════════


class GitChange:
    def __init__(self, path, rel, x, y):
        self.path = path          # absolute
        self.rel = rel            # relative to the repository root
        self.x = x                # index status (porcelain column 1)
        self.y = y                # worktree status (porcelain column 2)

    def staged(self):
        return self.x != " " and self.x != "?"

    def unstaged(self):
        return self.y != " " or self.x == "?"

    # The single letter VS Code shows beside a file.
    def letter(self, staged_view):
        if self.x == "?":
            return "U"
        if staged_view:
            return self.x
        return self.y


class GitRepo:
    def __init__(self):
        self.root = ""            # repository top level, "" when none
        self.branch = ""
        self.available = false
        self.changes = []
        self.error = ""
        self.head_cache = {}      # "rel@commit" -> list of lines
        self.head_commit = ""
        self.last_output = ""

    def _q(self, s):
        return "'" + string_replace(s, "'", "'\\''") + "'"

    def _git(self, args):
        var out = os_exec("git -C " + self._q(self.root) + " " + args + " 2>&1")
        if out == none:
            out = ""
        self.last_output = out
        return out

    def probe(self, folder):
        self.root = ""
        self.branch = ""
        self.changes = []
        self.error = ""
        var v = os_exec("git --version 2>&1")
        self.available = v != none and string_startswith(v, "git version")
        if not self.available or folder == "":
            return false
        var top = os_exec("git -C " + self._q(folder) + " rev-parse --show-toplevel 2>/dev/null")
        top = string_strip(top)
        if top == "" or not os_isdir(top):
            return false
        self.root = top
        self.refresh()
        return true

    def is_repo(self):
        return self.root != ""

    def refresh(self):
        if self.root == "":
            return
        var b = string_strip(self._git("symbolic-ref --short -q HEAD"))
        if b == "" or string_find(b, "fatal") >= 0:
            b = string_strip(self._git("rev-parse --short HEAD"))
        self.branch = b
        self.head_commit = string_strip(self._git("rev-parse -q --verify HEAD"))
        var out = self._git("status --porcelain=v1 -uall")
        var lines = string_split(out, "\n")
        var ch = []
        var i = 0
        while i < len(lines):
            var ln = lines[i]
            if len(ln) > 3 and not string_startswith(ln, "fatal"):
                var x = string_slice(ln, 0, 1)
                var y = string_slice(ln, 1, 2)
                var rel = string_slice(ln, 3, len(ln))
                var arrow = string_find(rel, " -> ")
                if arrow >= 0:
                    rel = string_slice(rel, arrow + 4, len(rel))
                if string_startswith(rel, "\"") and string_endswith(rel, "\""):
                    rel = string_slice(rel, 1, len(rel) - 1)
                ch.append(GitChange(path_join(self.root, rel), rel, x, y))
            i = i + 1
        self.changes = ch

    def staged(self):
        var out = []
        var i = 0
        while i < len(self.changes):
            if self.changes[i].staged():
                out.append(self.changes[i])
            i = i + 1
        return out

    def unstaged(self):
        var out = []
        var i = 0
        while i < len(self.changes):
            if self.changes[i].unstaged():
                out.append(self.changes[i])
            i = i + 1
        return out

    def status_of(self, path):
        var i = 0
        while i < len(self.changes):
            if self.changes[i].path == path:
                return self.changes[i]
            i = i + 1
        return none

    def stage(self, rel):
        self._git("add -- " + self._q(rel))
        self.refresh()

    def stage_all(self):
        self._git("add -A")
        self.refresh()

    def unstage(self, rel):
        if self.head_commit == "":
            self._git("rm --cached -q -- " + self._q(rel))
        else:
            self._git("reset -q HEAD -- " + self._q(rel))
        self.refresh()

    def unstage_all(self):
        if self.head_commit == "":
            self._git("rm --cached -r -q -- .")
        else:
            self._git("reset -q HEAD")
        self.refresh()

    # Discard working-tree changes: a tracked file goes back to its index
    # version; an untracked one is deleted, as VS Code's "Discard Changes".
    def discard(self, change):
        if change.x == "?":
            os_remove(change.path)
        else:
            self._git("checkout -q -- " + self._q(change.rel))
        self.refresh()

    def commit(self, message, tmp_path):
        if string_strip(message) == "":
            self.error = "Commit message is empty"
            return false
        write_file(tmp_path, message)
        var out = self._git("commit -q -F " + self._q(tmp_path))
        os_remove(tmp_path)
        self.refresh()
        if string_find(out, "nothing to commit") >= 0 or string_find(out, "no changes added") >= 0:
            self.error = "There are no staged changes to commit"
            return false
        if string_find(out, "Please tell me who you are") >= 0 or string_find(out, "empty ident") >= 0:
            self.error = "git needs user.name and user.email configured to commit"
            return false
        if string_find(out, "fatal") >= 0 or string_find(out, "error") >= 0:
            self.error = string_strip(out)
            return false
        self.error = ""
        return true

    def branches(self):
        var out = self._git("branch --format=%(refname:short)")
        var raw = string_split(out, "\n")
        var res = []
        var i = 0
        while i < len(raw):
            var b = string_strip(raw[i])
            if b != "" and string_find(b, "fatal") < 0:
                res.append(b)
            i = i + 1
        return res

    def checkout(self, name):
        var out = self._git("checkout -q " + self._q(name))
        self.refresh()
        if string_find(out, "error") >= 0 or string_find(out, "fatal") >= 0:
            self.error = string_strip(out)
            return false
        return true

    def create_branch(self, name):
        var out = self._git("checkout -q -b " + self._q(name))
        self.refresh()
        return string_find(out, "fatal") < 0

    # NOT named `init`: the interpreter treats a method called `init` as a
    # constructor alias, so GitRepo() itself ran `git init` on a folder named
    # "none" in the working directory.
    def init_repo(self, folder):
        var out = os_exec("git init -q " + self._q(folder) + " 2>&1")
        return self.probe(folder)

    def log(self, n):
        var out = self._git("log --oneline -" + str(n))
        if string_find(out, "fatal") >= 0:
            return []
        return string_split(string_strip(out), "\n")

    # The HEAD version of a file as lines, cached per (file, commit). none
    # when the file is not in HEAD (new or untracked).
    def head_lines(self, path):
        if self.root == "" or self.head_commit == "":
            return none
        if not string_startswith(path, self.root + "/"):
            return none
        var rel = string_slice(path, len(self.root) + 1, len(path))
        var key = rel + "@" + self.head_commit
        if self.head_cache.has_key(key):
            return self.head_cache[key]
        var probe = string_strip(os_exec("git -C " + self._q(self.root) + " cat-file -t " + self._q("HEAD:" + rel) + " 2>/dev/null"))
        var lines = none
        if probe == "blob":
            var text = os_exec("git -C " + self._q(self.root) + " show " + self._q("HEAD:" + rel) + " 2>/dev/null")
            if text == none:
                text = ""
            text = string_replace(text, "\r\n", "\n")
            lines = string_split(text, "\n")
            if len(lines) > 1 and lines[len(lines) - 1] == "":
                lines.pop()
        self.head_cache[key] = lines
        return lines

    # Unified diff of one file, for "Open Changes".
    def diff_text(self, change, staged):
        var args = "diff --no-color -- "
        if staged:
            args = "diff --no-color --cached -- "
        if change.x == "?":
            return "(untracked file - every line is new)\n\n" + read_file(change.path)
        return self._git(args + self._q(change.rel))


class LineDiff:
    def __init__(self):
        self.max_d = 160

    # Per line of `b`: 0 unchanged, 1 added, 2 modified, 3 unchanged but with
    # lines deleted just below it (row -1 deletions mark row 0).
    # a: old lines (list); b: new lines (list, first nb entries used).
    def classify(self, a, b, nb):
        var kinds = []
        var i = 0
        while i < nb:
            kinds.append(0)
            i = i + 1
        if a == none:
            i = 0
            while i < nb:
                kinds[i] = 1
                i = i + 1
            return kinds
        var na = len(a)
        # Common prefix and suffix.
        var p = 0
        while p < na and p < nb and a[p] == b[p]:
            p = p + 1
        var s = 0
        while s < na - p and s < nb - p and a[na - 1 - s] == b[nb - 1 - s]:
            s = s + 1
        var a0 = p
        var a1 = na - s
        var b0 = p
        var b1 = nb - s
        if a0 == a1 and b0 == b1:
            return kinds
        if a0 == a1:
            i = b0
            while i < b1:
                kinds[i] = 1
                i = i + 1
            return kinds
        if b0 == b1:
            self._mark_del(kinds, b0 - 1, nb)
            return kinds
        var ops = self._myers(a, a0, a1, b, b0, b1)
        if ops == none:
            i = b0
            while i < b1:
                kinds[i] = 2
                i = i + 1
            return kinds
        self._apply_ops(kinds, ops, b0, nb)
        return kinds

    def _mark_del(self, kinds, row, nb):
        var r = row
        if r < 0:
            r = 0
        if r < nb and kinds[r] == 0:
            kinds[r] = 3

    # Edit script as a list of [op, a_index, b_index] with op "=", "-", "+",
    # or none when the distance exceeds max_d.
    def _myers(self, a, a0, a1, b, b0, b1):
        var n = a1 - a0
        var m = b1 - b0
        var maxd = n + m
        if maxd > self.max_d:
            maxd = self.max_d
        var off = maxd + 1
        var size = 2 * maxd + 3
        var v = []
        var i = 0
        while i < size:
            v.append(0)
            i = i + 1
        var trace = []
        var d = 0
        var found = -1
        while d <= maxd and found < 0:
            trace.append(self._copy(v))
            var k = 0 - d
            while k <= d and found < 0:
                var x = 0
                if k == 0 - d or (k != d and v[off + k - 1] < v[off + k + 1]):
                    x = v[off + k + 1]
                else:
                    x = v[off + k - 1] + 1
                var y = x - k
                while x < n and y < m and a[a0 + x] == b[b0 + y]:
                    x = x + 1
                    y = y + 1
                v[off + k] = x
                if x >= n and y >= m:
                    found = d
                k = k + 2
            d = d + 1
        if found < 0:
            return none
        # Backtrack through the saved V arrays.
        var ops = []
        var x2 = n
        var y2 = m
        var dd = found
        while dd > 0:
            var vv = trace[dd]
            var k2 = x2 - y2
            var prev_k = 0
            if k2 == 0 - dd or (k2 != dd and vv[off + k2 - 1] < vv[off + k2 + 1]):
                prev_k = k2 + 1
            else:
                prev_k = k2 - 1
            var prev_x = vv[off + prev_k]
            var prev_y = prev_x - prev_k
            while x2 > prev_x and y2 > prev_y:
                ops.append(["=", a0 + x2 - 1, b0 + y2 - 1])
                x2 = x2 - 1
                y2 = y2 - 1
            if x2 == prev_x:
                ops.append(["+", a0 + x2, b0 + y2 - 1])
            else:
                ops.append(["-", a0 + x2 - 1, b0 + y2])
            x2 = prev_x
            y2 = prev_y
            dd = dd - 1
        while x2 > 0 and y2 > 0:
            ops.append(["=", a0 + x2 - 1, b0 + y2 - 1])
            x2 = x2 - 1
            y2 = y2 - 1
        # ops were collected back to front.
        var fwd = []
        var j = len(ops) - 1
        while j >= 0:
            fwd.append(ops[j])
            j = j - 1
        return fwd

    def _copy(self, v):
        var out = []
        var i = 0
        while i < len(v):
            out.append(v[i])
            i = i + 1
        return out

    # A run of deletions directly followed (or preceded) by insertions is a
    # modification, as VS Code draws it: blue, not red plus green.
    def _apply_ops(self, kinds, ops, b0, nb):
        var i = 0
        var n = len(ops)
        while i < n:
            var op = ops[i][0]
            if op == "=":
                i = i + 1
            else:
                var dels = 0
                var adds = []
                var j = i
                while j < n and ops[j][0] != "=":
                    if ops[j][0] == "-":
                        dels = dels + 1
                    else:
                        adds.append(ops[j][2])
                    j = j + 1
                var t = 0
                while t < len(adds):
                    if t < dels:
                        kinds[adds[t]] = 2
                    else:
                        kinds[adds[t]] = 1
                    t = t + 1
                if dels > len(adds):
                    # A removal sits between two lines of b: mark the bottom
                    # edge of the line above it (the last added line, if any).
                    var at = ops[i][2] - 1
                    if len(adds) > 0:
                        at = adds[len(adds) - 1]
                    self._mark_del(kinds, at, nb)
                i = j
