# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 86)
# lib/nylsp/workspace.ny - the files of a workspace for lib/nylsp (round 86):
# URIs and paths, the engines' module search, an index of every module's
# exports and imports, and the dependency graph between them.
#
#     ws = Workspace()
#     ws.add_root("/path/to/project")
#     ws.resolve_module("/p/app.ny", "pkg.util", 0)   # the file `import pkg.util` loads
#     e = ws.entry(path)        # FileEntry: .exports {name: symbol}, .imports, .symbols
#     ws.importers_of(path)     # the files that import it
#
# The module search is the engines' (NythonExecutor::moduleDirs and
# findModulePath): the importer's directory and its lib/ (not for a module
# of a package), the workspace's roots (as sys.path), the working
# directory's lib/, the installation's library, then four ancestors of the
# importer and their lib/; each directory for name.ny and name/__init__.ny
# first, then all of them again for name.py and name/__init__.py. A quoted
# import (`import "lib/x.ny"`) is looked for beside the importer, in the
# roots and in the installation. Relative imports (`from . import a`) go
# from the importer's package.
#
# Incremental: an entry is analysed again when its file changed (mtime) or
# its open document did; when what it exports changed (names, kinds,
# signatures) its version moves on, and the server re-checks the open
# documents that import it (the dependency graph, `importers_of`).

import os
import sys

__all__ = ["Workspace", "FileEntry", "uri_to_path", "path_to_uri", "BUILTIN_MODULES"]

_HEX = "0123456789ABCDEF"
_SAFE = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

# modules the engines provide without a file of their own
BUILTIN_MODULES = set(["sys", "math", "os", "time", "builtins", "gc", "_thread", "marshal", "posix", "nt",
                       "itertools", "errno", "_io", "_weakref", "_signal", "_socket", "_string"])


def _unquote(s):
    if "%" not in s:
        return s
    out = bytearray()
    raw = s.encode("utf-8")
    i = 0
    n = len(raw)
    while i < n:
        c = raw[i]
        if c == 37 and i + 2 < n:
            try:
                out.append(int(raw[i + 1:i + 3].decode("ascii"), 16))
                i += 3
                continue
            except ValueError:
                pass
        out.append(c)
        i += 1
    return bytes(out).decode("utf-8", "replace")


def _quote(s):
    out = []
    for ch in s:
        if ch in _SAFE:
            out.append(ch)
        else:
            for b in ch.encode("utf-8"):
                out.append("%" + _HEX[b >> 4] + _HEX[b & 15])
    return "".join(out)


def uri_to_path(uri):
    """The file path a file: URI names (other schemes are returned as they are)."""
    if not uri.startswith("file:"):
        return uri
    p = uri[5:]
    if p.startswith("//"):
        p = p[2:]
        slash = p.find("/")
        host = p[:slash] if slash >= 0 else p
        p = p[slash:] if slash >= 0 else "/"
        if host not in ("", "localhost"):
            p = "//" + host + p
    p = _unquote(p)
    # file:///C:/x on Windows
    if len(p) > 2 and p[0] == "/" and p[2] == ":" and p[1].isalpha():
        p = p[1:]
    return p


def path_to_uri(path):
    p = path.replace("\\", "/")
    if len(p) > 1 and p[1] == ":":
        p = "/" + p
    return "file://" + _quote(p)


def _norm(p):
    return os.path.normpath(os.path.abspath(p))


class FileEntry:
    """What the index knows about one module file."""
    def __init__(self, path):
        self.path = path
        self.mtime = -2
        self.seen_edits = -1
        self.version = 0          # moves on when the exports change
        self.export_key = None
        self.exports = {}         # name -> symbol (dict, as _ny_lsp("exports"))
        self.imports = []         # as _ny_lsp("imports")
        self.deps = set()         # the files it imports (resolved)
        self.symbols = None       # flattened document symbols (workspace/symbol), made when asked
        self.star = False         # a star / quoted import: its names are not all known
        self.has_getattr = False  # a module __getattr__ (PEP 562): any name may exist
        self.error = None


class Workspace:
    def __init__(self):
        self.roots = []
        here = os.path.dirname(os.path.abspath(__file__))
        self.lib_dirs = [os.path.dirname(here)]          # the installation's library (lib/)
        self.install_root = os.path.dirname(self.lib_dirs[0])
        self.files = {}           # path -> FileEntry
        self.importers = {}       # path -> set of paths importing it
        self.handles = {}         # path -> native handle of a file that is not open
        self.lru = []
        self.open_docs = {}       # path -> native handle of an open document (the server's)
        self.pending = []         # workspace files still to index
        self.listed = []          # every workspace module file
        self.max_handles = 48

    # ── roots ──
    def add_root(self, path):
        p = _norm(path)
        if p not in self.roots and os.path.isdir(p):
            self.roots.append(p)

    def scan(self, max_files=5000):
        """The module files under the roots; queued for indexing."""
        out = []
        for r in self.roots:
            for f in fs_list_files(r, {"full": True, "max": max_files}):
                if f.endswith(".ny") or f.endswith(".py"):
                    out.append(_norm(f))
        self.listed = out
        self.pending = list(out)
        return len(out)

    def in_workspace(self, path):
        for r in self.roots:
            if path == r or path.startswith(r + os.sep):
                return True
        return False

    # ── native handles ──
    def handle(self, path):
        """The analysis handle for a file: its open document's, else one read
        from disk (kept for a while)."""
        h = self.open_docs.get(path)
        if h is not None:
            return h
        h = self.handles.get(path)
        try:
            mt = os.stat(path).st_mtime
        except OSError:
            return None
        if h is not None:
            e = self.files.get(path)
            if e is not None and e.mtime == mt:
                if path in self.lru:
                    self.lru.remove(path)
                self.lru.append(path)
                return h
            _ny_lsp("close", h)
            del self.handles[path]
            if path in self.lru:
                self.lru.remove(path)
        s = _ny_lsp("open_file", path)
        if s == "":
            return None
        h = int(s)
        self.handles[path] = h
        self.lru.append(path)
        while len(self.lru) > self.max_handles:
            old = self.lru.pop(0)
            oh = self.handles.pop(old, None)
            if oh is not None:
                _ny_lsp("close", oh)
        return h

    def forget_handle(self, path):
        h = self.handles.pop(path, None)
        if h is not None:
            _ny_lsp("close", h)
        if path in self.lru:
            self.lru.remove(path)

    # ── the index ──
    def entry(self, path, edits=None):
        """The file's entry, analysed again when it changed. `edits`: the open
        document's edit count (its text, not the file's)."""
        path = _norm(path)
        e = self.files.get(path)
        if e is None:
            e = FileEntry(path)
            self.files[path] = e
        opened = self.open_docs.get(path)
        if opened is not None:
            if edits is not None and e.seen_edits == edits and e.export_key is not None:
                return e
            h = opened
            e.seen_edits = edits if edits is not None else -1
            e.mtime = -3
        else:
            try:
                mt = os.stat(path).st_mtime
            except OSError:
                e.error = "missing"
                return e
            if mt == e.mtime and e.export_key is not None:
                return e
            h = self.handle(path)
            if h is None:
                e.error = "unreadable"
                return e
            e.mtime = mt
        self._refresh(e, h)
        return e

    def _refresh(self, e, h):
        exports = json_decode(_ny_lsp("exports", h))
        imports = json_decode(_ny_lsp("imports", h))
        e.exports = {}
        key = []
        for s in exports:
            e.exports[s["name"]] = s
            key.append(s["name"] + ":" + s["kind"] + ":" + s["detail"])
        key.sort()
        e.has_getattr = "__getattr__" in e.exports
        e.imports = imports
        e.symbols = None
        e.star = False
        for old in e.deps:
            s2 = self.importers.get(old)
            if s2 is not None:
                s2.discard(e.path)
        e.deps = set()
        for im in imports:
            if im["name"] == "*" or im["quoted"]:
                e.star = True
            p = self.resolve_import(e.path, im)
            if p is not None:
                e.deps.add(p)
                self.importers.setdefault(p, set()).add(e.path)
        k = "\n".join(key)
        if k != e.export_key:
            e.export_key = k
            e.version += 1

    def importers_of(self, path):
        return set(self.importers.get(_norm(path), set()))

    def index_step(self, budget_ms=30):
        """Index pending files for about budget_ms; how many are left."""
        t0 = time_ms()
        while self.pending and time_ms() - t0 < budget_ms:
            p = self.pending.pop(0)
            self.entry(p)
            # a file analysed for the index need not stay loaded
            if p not in self.open_docs:
                self.forget_handle(p)
        return len(self.pending)

    def workspace_symbols(self):
        """(name, kind, path, range, container) of every indexed module's
        definitions."""
        out = []
        for p in self.listed:
            e = self.files.get(p)
            if e is None:
                continue
            if e.symbols is None:
                h = self.handle(p)
                if h is None:
                    continue
                e.symbols = []
                _flatten(json_decode(_ny_lsp("symbols", h)), "", e.symbols)
                if p not in self.open_docs:
                    self.forget_handle(p)
            for s in e.symbols:
                out.append((s[0], s[1], p, s[2], s[3]))
        return out

    # ── the module search ──
    def search_dirs(self, importer):
        here = os.path.dirname(importer) if importer else ""
        dirs = []
        in_package = here and (os.path.exists(os.path.join(here, "__init__.ny")) or os.path.exists(os.path.join(here, "__init__.py")))
        if here and not in_package:
            dirs.append(here)
            dirs.append(os.path.join(here, "lib"))
        for r in self.roots:
            dirs.append(r)
            dirs.append(os.path.join(r, "lib"))
        for d in self.lib_dirs:
            dirs.append(d)
        anc = os.path.dirname(here) if here else ""
        up = 0
        while anc and up < 4:
            dirs.append(anc)
            dirs.append(os.path.join(anc, "lib"))
            nxt = os.path.dirname(anc)
            if nxt == anc:
                break
            anc = nxt
            up += 1
        seen = set()
        out = []
        for d in dirs:
            if d not in seen:
                seen.add(d)
                out.append(d)
        return out

    def resolve_module(self, importer, module, level=0):
        """The file `import module` loads from `importer` (None: not found)."""
        if module is None:
            module = ""
        dots = 0
        while dots < len(module) and module[dots] == ".":
            dots += 1
        if dots > level:
            level = dots
        name = module[dots:]
        rel = name.replace(".", os.sep)
        if level > 0:
            base = os.path.dirname(importer) if importer else os.getcwd()
            for _ in range(level - 1):
                base = os.path.dirname(base)
            dirs = [base]
        else:
            dirs = self.search_dirs(importer)
        for ext in (".ny", ".py"):
            for d in dirs:
                if rel == "":
                    f = os.path.join(d, "__init__" + ext)
                    if os.path.isfile(f):
                        return _norm(f)
                    continue
                f = os.path.join(d, rel + ext)
                if os.path.isfile(f):
                    return _norm(f)
                f = os.path.join(d, rel, "__init__" + ext)
                if os.path.isfile(f):
                    return _norm(f)
        return None

    def resolve_quoted(self, importer, path):
        if os.path.isabs(path):
            return _norm(path) if os.path.isfile(path) else None
        cands = []
        if importer:
            cands.append(os.path.join(os.path.dirname(importer), path))
        for r in self.roots:
            cands.append(os.path.join(r, path))
        cands.append(os.path.join(os.getcwd(), path))
        for d in self.lib_dirs:
            cands.append(os.path.join(d, path))
        cands.append(os.path.join(self.install_root, path))
        for c in cands:
            if os.path.isfile(c):
                return _norm(c)
        return None

    def resolve_import(self, importer, im):
        """The file an import record (as _ny_lsp("imports")) loads."""
        if im["quoted"]:
            return self.resolve_quoted(importer, im["module"])
        return self.resolve_module(importer, im["module"], im["level"])

    def package_dir(self, importer, module, level=0):
        """The directory of package `module`, None when it is not one."""
        p = self.resolve_module(importer, module, level)
        if p is not None and os.path.basename(p).startswith("__init__."):
            return os.path.dirname(p)
        return None

    def module_name(self, path):
        """The dotted name a file is imported by (from a root or the library)."""
        best = None
        for d in self.roots + self.lib_dirs:
            if path.startswith(d + os.sep):
                rel = path[len(d) + 1:]
                if best is None or len(rel) < len(best):
                    best = rel
        if best is None:
            best = os.path.basename(path)
        if best.endswith(".ny") or best.endswith(".py"):
            best = best[:-3]
        parts = best.replace("\\", "/").split("/")
        if parts and parts[-1] == "__init__":
            parts = parts[:-1]
        return ".".join(parts)

    def list_modules(self, importer, package):
        """The module names `import package.` can complete: (name, is_package)."""
        out = {}
        if package:
            pd = self.package_dir(importer, package)
            dirs = [pd] if pd is not None else []
        else:
            dirs = self.search_dirs(importer)
        for d in dirs:
            try:
                names = os.listdir(d)
            except OSError:
                continue
            for n in names:
                if n.startswith(".") or n == "__pycache__":
                    continue
                full = os.path.join(d, n)
                if (n.endswith(".ny") or n.endswith(".py")) and os.path.isfile(full):
                    m = n[:-3]
                    if m != "__init__" and m != "__main__" and m.isidentifier() and m not in out:
                        out[m] = False
                elif os.path.isdir(full) and n.isidentifier() and (os.path.exists(os.path.join(full, "__init__.ny")) or os.path.exists(os.path.join(full, "__init__.py"))):
                    out[n] = True
        if not package:
            for m in BUILTIN_MODULES:
                if m not in out:
                    out[m] = False
        return sorted(out.items())


def _flatten(syms, container, out):
    for s in syms:
        out.append((s["name"], s["kind"], s["selectionRange"], container))
        if s.get("children"):
            _flatten(s["children"], s["name"], out)
