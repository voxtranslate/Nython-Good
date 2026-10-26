# vm_audit128.ny - Windows' own modules, virtual environments, and installing
# packages (round 87, part M).
#
#   A. PEP 440 / PEP 508 against packaging: nypip's version handling (a
#      vendored packaging 24.0) on a corpus of 1,233 versions and invalid
#      ones - str(), every segment and flag, the sort order, equality -,
#      specifiers' contains / filter / str over a sample, markers evaluated
#      in two environments, requirements normalised; the table is
#      examples/vm_audit128_pep440.json (tools/gen_vm_audit128_pep440.py,
#      from the host's packaging).
#   B. PubGrub (lib/nypip/pubgrub.ny): pub's documented examples - solved
#      graphs with backtracking, partial satisfiers - and its error
#      explanations, word for word.
#   C. Wheels: written, read, their RECORD checked (a corrupt one refused),
#      .data directories, entry points.
#   D. A package index served by http.server on localhost: PEP 503 HTML and
#      PEP 691 JSON by content negotiation, yanked files, PEP 658 metadata,
#      hashes.
#   E. venv: `nython -m venv` - CPython's layout, pyvenv.cfg, the activation
#      scripts, the environment's interpreter (sys.prefix / base_prefix,
#      site-packages on sys.path), ensurepip's installer in it.
#   F. The installer (Nython only): `nython -m pip install` from the index,
#      --find-links, requirement files with markers and hashes, sdists built
#      by PEP 517 backends in a subprocess (in-tree, and one installed into
#      an isolated build environment), console scripts, list / show / freeze
#      / check / download / uninstall, an unsatisfiable install explained,
#      `pip lock` for three platforms and `pip sync`.
#   G. importlib.metadata in the environment's interpreter (CPython's API
#      over what nypip installed).
#   H. site: .pth files (paths and import lines), sitecustomize, -S, the user
#      site and --system-site-packages, `-m site`.
#   I. Windows (os.name == "nt", under Wine): msvcrt, winreg (a key under
#      HKEY_CURRENT_USER\Software\NythonTest_<pid>, deleted after), winsound,
#      _winapi; elsewhere the four modules are ModuleNotFoundError.
#
# Under python3 the parts whose API is CPython's run too (A and B through a
# finder that loads lib/nypip, E with python3's venv, G and H with wheels
# installed by nypip's installer in-process):
#
#     ./build/nython-cli examples/vm_audit128.ny
#     ./build/nython-cli --vm examples/vm_audit128.ny
#     python3 examples/vm_audit128.ny
#     build-win/nywin examples/vm_audit128.ny           (Wine)

import os
import sys
import json
import shutil
import hashlib
import tempfile
import threading
import subprocess

NYTHON = sys.implementation.name == "nython"
VM = NYTHON and "--vm" in getattr(sys, "orig_argv", [])
WIN = os.name == "nt"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
results = []


TRACE = os.environ.get("NY128_TRACE")


def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])
    if TRACE and repr(got) != repr(want):
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))


if not NYTHON:
    import importlib.machinery
    import importlib.util

    class _NyFinder:
        # lib/nypip/*.ny for python3 (written in the subset CPython runs)
        @classmethod
        def find_spec(cls, name, path=None, target=None):
            if name.split(".")[0] != "nypip":
                return None
            base = os.path.join(ROOT, "lib", *name.split("."))
            if os.path.isdir(base):
                fn = os.path.join(base, "__init__.ny")
                return importlib.util.spec_from_file_location(
                    name, fn, loader=importlib.machinery.SourceFileLoader(name, fn), submodule_search_locations=[base])
            fn = base + ".ny"
            if os.path.exists(fn):
                return importlib.util.spec_from_file_location(name, fn, loader=importlib.machinery.SourceFileLoader(name, fn))
            return None
    sys.meta_path.insert(0, _NyFinder)

from nypip._packaging.version import Version, InvalidVersion
from nypip._packaging.specifiers import SpecifierSet, InvalidSpecifier
from nypip._packaging.markers import Marker, InvalidMarker
from nypip._packaging.requirements import Requirement, InvalidRequirement
from nypip import pubgrub

T = tempfile.mkdtemp(prefix="ny128_")


def run(args, **kw):
    kw.setdefault("capture_output", True)
    kw.setdefault("timeout", 300)
    r = subprocess.run(args, **kw)
    out = r.stdout.decode("utf-8", "replace").replace("\r\n", "\n") if isinstance(r.stdout, bytes) else r.stdout
    err = r.stderr.decode("utf-8", "replace").replace("\r\n", "\n") if isinstance(r.stderr, bytes) else r.stderr
    return r.returncode, out, err


# ── A. PEP 440 / PEP 508 ────────────────────────────────────────────────────
with open(os.path.join(HERE, "vm_audit128_pep440.json"), encoding="utf-8") as f:
    TABLE = json.load(f)

bad = []
parsed = {}
for s, want in TABLE["versions"]:
    try:
        v = Version(s)
    except InvalidVersion:
        if want is not None:
            bad.append((s, "InvalidVersion"))
        continue
    if want is None:
        bad.append((s, "parsed"))
        continue
    parsed[s] = v
    got = [str(v), v.public, v.base_version, list(v.release), v.epoch, list(v.pre) if v.pre else None, v.post,
           v.dev, v.local, v.is_prerelease, v.is_postrelease, v.is_devrelease, v.major, v.minor, v.micro]
    if got != want:
        bad.append((s, got, want))
check("PEP 440: %d versions parsed (or refused) with every field as packaging's" % len(TABLE["versions"]), bad[:3], [])
order = [s for s, v in sorted(parsed.items(), key=lambda x: (x[1], x[0]))]
check("... sorted as packaging sorts them", [i for i in range(len(order)) if order[i] != TABLE["order"][i]][:5], [])
bad = []
for grp in TABLE["equal"]:
    vs = [parsed[s] for s in grp]
    if not all(x == vs[0] and hash(x) == hash(vs[0]) for x in vs):
        bad.append(grp)
check("... equal spellings compare and hash equal (%d groups)" % len(TABLE["equal"]), bad[:3], [])
check("... ordering operators", [Version("1.0a1") < Version("1.0"), Version("1.0") < Version("1.0.post1"),
                                 Version("1.0.dev1") < Version("1.0a1"), Version("1!0.1") > Version("2.0"),
                                 Version("1.0+abc") > Version("1.0"), Version("1.0+5") > Version("1.0+abc"),
                                 Version("1.0") == Version("1.0.0"), Version("1.0") != Version("1.0+x")],
      [True, True, True, True, True, True, True, True])
bad = []
sample = TABLE["sample"]
for sp, sstr, pre, contains, contains_pre, filt in TABLE["specs"]:
    ss = SpecifierSet(sp)
    got = [str(ss), ss.prereleases, "".join("1" if ss.contains(s) else "0" for s in sample),
           "".join("1" if ss.contains(s, prereleases=True) else "0" for s in sample), list(ss.filter(sample))]
    if got != [sstr, pre, contains, contains_pre, filt]:
        bad.append(sp)
check("PEP 440 specifiers: %d sets, contains / filter over %d versions, str()" % (len(TABLE["specs"]), len(sample)),
      bad, [])
bad = []
for sp, ok in TABLE["bad_specs"]:
    try:
        SpecifierSet(sp)
        got = True
    except InvalidSpecifier:
        got = False
    if got != ok:
        bad.append(sp)
check("... invalid specifiers refused", bad, [])
bad = []
for row in TABLE["markers"]:
    mk = Marker(row[0])
    got = [row[0], str(mk)]
    for env in (TABLE["env_linux"], TABLE["env_win"]):
        for extra in ("", "test", "test-extra"):
            e = dict(env)
            e["extra"] = extra
            try:
                got.append(mk.evaluate(e))
            except Exception as ex:
                got.append(type(ex).__name__)
    if got != row:
        bad.append((row, got))
check("PEP 508 markers: %d evaluated in two environments, three extras" % len(TABLE["markers"]), bad[:2], [])
bad = []
for m, ok in TABLE["bad_markers"]:
    try:
        Marker(m)
        got = True
    except InvalidMarker:
        got = False
    if got != ok:
        bad.append(m)
check("... invalid markers refused", bad, [])
bad = []
for r, s, name, extras, spec, url, marker in TABLE["requirements"]:
    q = Requirement(r)
    got = [str(q), q.name, sorted(q.extras), str(q.specifier), q.url, str(q.marker) if q.marker else None]
    if got != [s, name, extras, spec, url, marker]:
        bad.append((r, got))
for r, ok in TABLE["bad_requirements"]:
    try:
        Requirement(r)
        got = True
    except InvalidRequirement:
        got = False
    if got != ok:
        bad.append(r)
check("PEP 508 requirements normalised, invalid ones refused", bad, [])
if NYTHON:
    from nypip._packaging.markers import default_environment
    env = default_environment()
    check("markers see Nython's platform values", [env["implementation_name"], env["python_version"],
                                                   env["os_name"] == os.name, env["sys_platform"] == sys.platform],
          ["nython", "3.12", True, True])
    from nypip._packaging import tags
    st = [str(t) for t in tags.sys_tags()]
    check("Nython's wheel tags: pure-Python ones only, the most specific first",
          [st[-1], "py3-none-any" in st, any(t.startswith("cp") for t in st), st.index("py312-none-any") < st.index("py3-none-any")],
          ["py30-none-any", True, False, True])

# ── B. PubGrub ──────────────────────────────────────────────────────────────


def _vt(s):
    return tuple(int(x) for x in s.split("."))


def _caret(s):
    lo = _vt(s)
    hi = (lo[0] + 1, 0, 0) if lo[0] > 0 else (0, lo[1] + 1, 0)
    return lambda v: lo <= v < hi


class _Graph:
    # a provider over {name: {version: [(dep, label)]}} with caret labels
    def __init__(self, db):
        self.db = db
        self.calls = 0

    def versions(self, name):
        if name not in self.db:
            return None
        return sorted(_vt(k) for k in self.db[name])

    def dependencies(self, name, v):
        self.calls += 1
        out = []
        for dep, label in self.db[name][".".join(str(x) for x in v)]:
            if label.startswith("^"):
                f = _caret(label[1:])
            elif label.startswith(">="):
                f = (lambda x: lambda v: v >= x)(_vt(label[2:]))
            elif label.startswith("<"):
                f = (lambda x: lambda v: v < x)(_vt(label[1:]))
            else:
                f = lambda v: True
            out.append(pubgrub.Dependency(dep, f, " " + label if label else ""))
        return out

    def format_version(self, name, v):
        return " " + ".".join(str(x) for x in v)

    def version_text(self, name, v):
        return ".".join(str(x) for x in v)

    def cheap_dependencies(self, name, v):
        return self.dependencies(name, v)


def solve(db, root):
    g = _Graph(db)
    deps = []
    for dep, label in root:
        deps.extend(g.dependencies.__func__(_Graph({"<r>": {"0": [(dep, label)]}}), "<r>", (0,)))
    try:
        r = pubgrub.Solver(g, deps).solve()
        return {k: ".".join(str(x) for x in v) for k, v in sorted(r.items())}
    except pubgrub.SolveFailure as e:
        return str(e)


check("PubGrub: no conflicts", solve({"foo": {"1.0.0": [("bar", "^1.0.0")]}, "bar": {"1.0.0": [], "2.0.0": []}},
                                     [("foo", "^1.0.0")]), {"bar": "1.0.0", "foo": "1.0.0"})
check("... avoiding a conflict during decision making",
      solve({"foo": {"1.0.0": [], "1.1.0": [("bar", "^2.0.0")]}, "bar": {"1.0.0": [], "1.1.0": [], "2.0.0": []}},
            [("foo", "^1.0.0"), ("bar", "^1.0.0")]), {"bar": "1.1.0", "foo": "1.0.0"})
check("... conflict resolution (backtracking from foo 2.0.0)",
      solve({"foo": {"1.0.0": [], "2.0.0": [("bar", "^1.0.0")]}, "bar": {"1.0.0": [("foo", "^1.0.0")]}},
            [("foo", ">=1.0.0")]), {"foo": "1.0.0"})
check("... conflict resolution with a partial satisfier",
      solve({"foo": {"1.0.0": [], "1.1.0": [("left", "^1.0.0"), ("right", "^1.0.0")]},
             "left": {"1.0.0": [("shared", ">=1.0.0")]}, "right": {"1.0.0": [("shared", "<2.0.0")]},
             "shared": {"2.0.0": [], "1.0.0": [("target", "^1.0.0")]}, "target": {"2.0.0": [], "1.0.0": []}},
            [("foo", "^1.0.0"), ("target", "^2.0.0")]), {"foo": "1.0.0", "target": "2.0.0"})
check("... linear error reporting (pub's example)",
      solve({"foo": {"1.0.0": [("bar", "^2.0.0")]}, "bar": {"2.0.0": [("baz", "^3.0.0")]}, "baz": {"1.0.0": [], "3.0.0": []}},
            [("foo", "^1.0.0"), ("baz", "^1.0.0")]),
      "Because every version of foo depends on bar ^2.0.0 which depends on baz ^3.0.0, every version of foo requires baz ^3.0.0.\n"
      "So, because you require both foo ^1.0.0 and baz ^1.0.0, version solving failed.")
check("... branching error reporting, with a numbered line (pub's example)",
      solve({"foo": {"1.0.0": [("a", "^1.0.0"), ("b", "^1.0.0")], "1.1.0": [("x", "^1.0.0"), ("y", "^1.0.0")]},
             "a": {"1.0.0": [("b", "^2.0.0")]}, "b": {"1.0.0": [], "2.0.0": []},
             "x": {"1.0.0": [("y", "^2.0.0")]}, "y": {"1.0.0": [], "2.0.0": []}}, [("foo", "^1.0.0")]).split("\n"),
      ["    Because foo 1.0.0 depends on a ^1.0.0 which depends on b ^2.0.0, foo 1.0.0 requires b ^2.0.0.",
       "(1) So, because foo 1.0.0 depends on b ^1.0.0, foo 1.0.0 is forbidden.",
       "",
       "    Because foo 1.1.0 depends on x ^1.0.0 which depends on y ^2.0.0, foo 1.1.0 requires y ^2.0.0.",
       "    And because foo 1.1.0 depends on y ^1.0.0, foo 1.1.0 is forbidden.",
       "    And because foo 1.0.0 is forbidden (1), foo is forbidden.",
       "    So, because you require foo ^1.0.0, version solving failed."])
check("... a requirement no version meets, and a package that does not exist",
      [solve({"a": {"1.0.0": [("b", "^3.0.0")]}, "b": {"1.0.0": []}}, [("a", "^1.0.0")]),
       solve({"a": {"1.0.0": [("nope", "^1.0.0")], "1.1.0": [("nope", "^1.0.0")]}}, [("a", "^1.0.0")])],
      ["Because you require a ^1.0.0 which depends on b ^3.0.0, which doesn't match any versions, version solving failed.",
       "Because you require a ^1.0.0 which depends on nope ^1.0.0, which doesn't exist, version solving failed."])
check("... adjacent versions with the same dependency merged into one incompatibility",
      solve({"a": {"1.0.0": [("b", ">=2.0.0")], "1.1.0": [("b", ">=2.0.0")]}, "c": {"1.0.0": [("b", "<2.0.0")]},
             "b": {"1.0.0": [], "2.0.0": []}}, [("a", ""), ("c", "")]),
      "Because every version of c depends on b <2.0.0 and every version of a depends on b >=2.0.0, c is incompatible with a.\n"
      "So, because you require both a and c, version solving failed.")
# a deep backtrack: the newest x needs a y no z allows
deep = {"x": {}, "y": {}, "z": {"1.0.0": [("y", "<3.0.0")]}}
for i in range(1, 6):
    deep["x"]["%d.0.0" % i] = [("y", ">=%d.0.0" % i)]
    deep["y"]["%d.0.0" % i] = []
check("... backtracking through five versions of x", solve(deep, [("x", ""), ("z", "")]),
      {"x": "2.0.0", "y": "2.0.0", "z": "1.0.0"})

# ── C. wheels ───────────────────────────────────────────────────────────────
from nypip.wheel import write_wheel, WheelFile, WheelError
from nypip import metadata as nymd
from nypip import installed as nyinst

W = os.path.join(T, "wheels")
os.makedirs(W)


def wheel(name, ver, requires=(), files=None, **kw):
    mod = name.replace("-", "_")
    if files is None:
        files = {mod + "/__init__.py": "VERSION = %r\n" % ver}
    return write_wheel(W, name, ver, files, requires=requires, **kw)


p = wheel("alpha", "1.0", ["beta>=1.0"])
wheel("alpha", "2.0", ["beta>=2.0", "gamma", 'extra-dep; extra == "fancy"'], extras=["fancy"])
wheel("beta", "1.0")
wheel("beta", "1.5")
wheel("beta", "2.0", ["gamma<2"])
wheel("gamma", "1.0")
wheel("gamma", "2.0")
wheel("extra-dep", "1.0")
wheel("tool", "1.0", files={"tool/__init__.py": "def main():\n    print('tool says hi')\n    return 0\n"},
      entry_points={"console_scripts": [("ny-tool", "tool:main")]},
      data_files={"data/share/tool/readme.txt": "shared data\n", "scripts/tool-sh": "#!python\nprint('from a script')\n"})
wheel("conflict-a", "1.0", ["shared>=2"])
wheel("conflict-a", "1.1", ["shared>=2"])
wheel("conflict-c", "1.0", ["shared<2"])
wheel("shared", "1.0")
wheel("shared", "2.0")
wheel("needs-new-python", "1.0", requires_python=">=3.99")
wheel("plat", "1.0", tag="py3-none-win_amd64", files={"plat/__init__.py": "KIND = 'windows'\n"}, requires=['winhelp; sys_platform == "win32"'])
wheel("plat", "1.0", tag="py3-none-manylinux_2_17_x86_64", files={"plat/__init__.py": "KIND = 'linux'\n"})
wheel("plat", "1.0", tag="py3-none-any", files={"plat/__init__.py": "KIND = 'any'\n"})
wheel("winhelp", "1.0")
corrupt = os.path.join(T, "corrupt")
os.makedirs(corrupt)
cp = write_wheel(corrupt, "broken", "1.0", {"broken/__init__.py": "X = 1\n"}, bad_hash="broken/__init__.py")
with WheelFile(p) as w:
    check("a wheel read back: name, version, tags, METADATA, dist-info", [w.name, str(w.version), sorted(str(t) for t in w.tags),
          w.metadata.requires_dist, w.dist_info, w.wheel_meta.get("Root-Is-Purelib")],
          ["alpha", "1.0", ["py3-none-any"], ["beta>=1.0"], "alpha-1.0.dist-info", "true"])
    w.verify()
    rec = w.record()
    check("... its RECORD lists every file with a sha256 (RECORD itself without)",
          [sorted(rec), rec["alpha-1.0.dist-info/RECORD"][1], rec["alpha/__init__.py"][1] == nymd.record_hash(b"VERSION = '1.0'\n")],
          [["alpha-1.0.dist-info/METADATA", "alpha-1.0.dist-info/RECORD", "alpha-1.0.dist-info/WHEEL", "alpha/__init__.py"], "", True])
try:
    with WheelFile(cp) as w:
        w.install(nyinst.scheme(target=os.path.join(T, "never")))
    got = "installed"
except WheelError as e:
    got = str(e)
check("a wheel whose file does not match RECORD is refused, nothing installed",
      [got, os.path.exists(os.path.join(T, "never", "broken"))],
      ["broken-1.0-py3-none-any.whl: the hash of broken/__init__.py does not match RECORD", False])
tw = os.path.join(W, "tool-1.0-py3-none-any.whl")
tgt = os.path.join(T, "tgt")
with WheelFile(tw) as w:
    check("... entry points read from entry_points.txt", w.entry_points(), {"console_scripts": [("ny-tool", "tool:main")]})
    written = w.install(nyinst.scheme(target=tgt), requested=True)
d = nyinst.get_distribution("tool", [tgt])
check("installed by the wheel installer: dist-info with INSTALLER, REQUESTED, RECORD",
      [d.version, d.installer(), d.requested(), sorted(os.path.relpath(f, tgt).replace(os.sep, "/") for f in d.files())],
      ["1.0", "nypip", True, sorted(["bin/ny-tool" if not WIN else "bin/ny-tool-script.py"] + (["bin/ny-tool.cmd"] if WIN else []) +
                                     ["bin/tool-sh", "share/tool/readme.txt", "tool-1.0.dist-info/INSTALLER",
                                      "tool-1.0.dist-info/METADATA", "tool-1.0.dist-info/RECORD",
                                      "tool-1.0.dist-info/REQUESTED", "tool-1.0.dist-info/WHEEL",
                                      "tool-1.0.dist-info/entry_points.txt", "tool/__init__.py"])])
bad = []
for f, h, n in d.record():
    if h:
        with open(os.path.join(tgt, f), "rb") as fh:
            data = fh.read()
        if nymd.record_hash(data) != h or str(len(data)) != n:
            bad.append(f)
check("... every installed file matches its RECORD hash and size", bad, [])
with open(os.path.join(tgt, "bin", "tool-sh"), encoding="utf-8") as f:
    first = f.readline().rstrip("\n")
check("... a #!python script's first line runs this interpreter", first, "#!" + sys.executable)
removed = d.uninstall()
check("... uninstalled by its RECORD: nothing left, emptied directories too", sorted(os.listdir(tgt)), [])
check("... the package, its dist-info, its scripts and data gone",
      [os.path.exists(os.path.join(tgt, x)) for x in ("tool", "tool-1.0.dist-info", "bin/tool-sh", "share/tool/readme.txt")],
      [False, False, False, False])

# ── D. a package index on localhost ─────────────────────────────────────────
import http.server
import socketserver
import html as _html

INDEX = {}            # project -> [filename]
for fn in sorted(os.listdir(W)):
    proj = fn.split("-")[0].replace("_", "-").lower()
    INDEX.setdefault(proj, []).append(fn)
YANKED = {"gamma-2.0-py3-none-any.whl": "broken build"}


def _sha(fn):
    with open(os.path.join(W, fn), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def _meta_of(fn):
    import zipfile
    with zipfile.ZipFile(os.path.join(W, fn)) as z:
        for n in z.namelist():
            if n.endswith(".dist-info/METADATA"):
                return z.read(n)


class _Index(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        parts = [p for p in path.split("/") if p]
        if len(parts) == 2 and parts[0] == "files":
            fn = parts[1]
            if fn.endswith(".metadata"):
                return self.send(200, _meta_of(fn[:-9]), "text/plain")
            with open(os.path.join(W, fn), "rb") as f:
                return self.send(200, f.read(), "application/octet-stream")
        if len(parts) == 2 and parts[0] == "simple":
            files = INDEX.get(parts[1])
            if files is None:
                return self.send(404, b"not found", "text/plain")
            accept = self.headers.get("Accept", "")
            if "application/vnd.pypi.simple.v1+json" in accept and not self.server.html_only:
                doc = {"meta": {"api-version": "1.1"}, "name": parts[1], "files": []}
                for fn in files:
                    e = {"filename": fn, "url": "/files/" + fn, "hashes": {"sha256": _sha(fn)}}
                    if fn.endswith(".whl"):
                        e["core-metadata"] = {"sha256": hashlib.sha256(_meta_of(fn)).hexdigest()}
                    if fn in YANKED:
                        e["yanked"] = YANKED[fn]
                    doc["files"].append(e)
                self.server.json_hits += 1
                return self.send(200, json.dumps(doc).encode(), "application/vnd.pypi.simple.v1+json")
            rows = []
            for fn in files:
                extra = ""
                if fn.endswith(".whl"):
                    extra = ' data-core-metadata="sha256=%s"' % hashlib.sha256(_meta_of(fn)).hexdigest()
                if fn in YANKED:
                    extra += ' data-yanked="%s"' % _html.escape(YANKED[fn])
                rows.append('<a href="../../files/%s#sha256=%s"%s>%s</a><br/>' % (fn, _sha(fn), extra, fn))
            body = "<!DOCTYPE html><html><body>%s</body></html>" % "\n".join(rows)
            self.server.html_hits += 1
            return self.send(200, body.encode(), "text/html")
        self.send(404, b"not found", "text/plain")


class _Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


srv = _Server(("127.0.0.1", 0), _Index)
srv.html_only = False
srv.json_hits = 0
srv.html_hits = 0
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:%d/simple/" % srv.server_address[1]

from nypip import index as nyindex
fi = nyindex.Finder(index_urls=[URL])
ls = fi.links("gamma")
check("the index's JSON page (PEP 691, by content negotiation): files, hashes, yanked, metadata",
      [[l.filename, l.yanked, bool(l.hashes.get("sha256")), isinstance(l.metadata, dict)] for l in ls],
      [["gamma-1.0-py3-none-any.whl", None, True, True], ["gamma-2.0-py3-none-any.whl", "broken build", True, True]])
check("... its metadata file (PEP 658), hash checked", nymd.Metadata.parse(fi.fetch_metadata(ls[0])).version, "1.0")
srv.html_only = True
fi2 = nyindex.Finder(index_urls=[URL])
ls2 = fi2.links("gamma")
check("... the HTML page (PEP 503): the same files", [[l.filename, l.yanked, l.hashes.get("sha256") == _sha(l.filename),
                                                       isinstance(l.metadata, dict)] for l in ls2],
      [["gamma-1.0-py3-none-any.whl", None, True, True], ["gamma-2.0-py3-none-any.whl", "broken build", True, True]])
srv.html_only = False
check("... a project the index does not have", fi.links("no-such-project"), None)
check("... both kinds of page were asked for", [srv.json_hits >= 1, srv.html_hits >= 1], [True, True])
dl = fi.download(ls[0], os.path.join(T, "dl"))
check("... a download, its hash checked", os.path.basename(dl), "gamma-1.0-py3-none-any.whl")
bad_link = nyindex.Link(ls[0].url_nofrag + "#sha256=" + "0" * 64)
try:
    fi.download(bad_link, os.path.join(T, "dl2"))
    got = "downloaded"
except nyindex.HashMismatch as e:
    got = "HashMismatch"
check("... a file whose hash does not match is refused", got, "HashMismatch")

# ── E. venv ─────────────────────────────────────────────────────────────────
EXE = sys.executable
ENGINE = ["--vm"] if VM else []
BIN = "Scripts" if WIN else "bin"
PYNAME = ("nython" if NYTHON else "python") + (".exe" if WIN else "")
SITE_REL = (os.path.join("Lib", "site-packages") if WIN else
            os.path.join("lib", ("nython%d.%d" if NYTHON else "python%d.%d") % sys.version_info[:2], "site-packages"))
ENV = os.path.join(T, "env")
venv_args = [EXE] + ENGINE + ["-m", "venv", ENV, "--prompt", "demo"]
if not NYTHON:
    venv_args.append("--without-pip")      # (python3's own pip is not what is tested)
rc, out, err = run(venv_args)
check("`-m venv DIR`: exit status", [rc, err[-300:]], [0, ""])
cfg = {}
with open(os.path.join(ENV, "pyvenv.cfg"), encoding="utf-8") as f:
    for line in f:
        k, _, v = line.partition("=")
        cfg[k.strip()] = v.strip()
base_exe = getattr(sys, "_base_executable", sys.executable)
check("pyvenv.cfg: home, include-system-site-packages, version, prompt",
      [os.path.normcase(cfg.get("home", "")) == os.path.normcase(os.path.dirname(os.path.abspath(base_exe))),
       cfg.get("include-system-site-packages"), cfg.get("version"), cfg.get("prompt")],
      [True, "false", "%d.%d.%d" % sys.version_info[:3], "'demo'"])
envpy = os.path.join(ENV, BIN, PYNAME)
check("the layout: the interpreter, site-packages, the activation scripts",
      [os.path.exists(envpy), os.path.isdir(os.path.join(ENV, SITE_REL)),
       sorted(x for x in os.listdir(os.path.join(ENV, BIN)) if x.lower().startswith(("activate", "deactivate")))],
      [True, True, sorted(["activate", "Activate.ps1"] + (["activate.bat", "deactivate.bat"] if WIN else ["activate.csh", "activate.fish"]))])
with open(os.path.join(ENV, BIN, "activate"), encoding="utf-8") as f:
    act = f.read()
check("... activate names the environment and its prompt",
      ["VIRTUAL_ENV=" + ENV in act or "VIRTUAL_ENV='" + ENV + "'" in act, "PS1='(demo) '" in act], [True, True])
if not WIN:
    check("... the interpreter is a link to the installation's", os.path.islink(envpy), True)
probe = ("import sys, os, json\nprint(json.dumps([sys.prefix, sys.base_prefix, sys.exec_prefix, sys.executable,"
         " [p for p in sys.path if 'site-packages' in p]]))\n")
rc, out, err = run([envpy] + ENGINE + ["-c", probe])
try:
    pr = json.loads(out)
except Exception:
    pr = [out, err]
check("the environment's interpreter: sys.prefix, sys.base_prefix, sys.exec_prefix, sys.executable, site-packages",
      [os.path.normcase(pr[0]) == os.path.normcase(ENV), os.path.normcase(pr[1]) == os.path.normcase(sys.base_prefix),
       os.path.normcase(pr[2]) == os.path.normcase(ENV), os.path.normcase(pr[3]) == os.path.normcase(envpy),
       [os.path.normcase(x) for x in pr[4]]],
      [True, True, True, True, [os.path.normcase(os.path.join(ENV, SITE_REL))]])
rc, out, err = run([EXE] + ENGINE + ["-c", "import sys; print(int(sys.prefix == sys.base_prefix))"])
check("... outside it sys.prefix is the installation's", out.strip(), "1")


def env_run(code, env_path=ENV, extra=(), **kw):
    py = os.path.join(env_path, BIN, PYNAME)
    return run([py] + ENGINE + list(extra) + ["-c", code], **kw)


if NYTHON:
    sp = os.path.join(ENV, SITE_REL)
    check("ensurepip put nypip in the environment: its dist-info and commands",
          [os.path.isdir(os.path.join(sp, "nypip-0.2.1.dist-info")),
           sorted(x for x in os.listdir(os.path.join(ENV, BIN)) if x.startswith(("pip", "nypip")))],
          [True, sorted(["nypip", "pip", "pip3", "pip3.12"] if not WIN else
                        ["nypip-script.py", "nypip.cmd", "pip-script.py", "pip.cmd", "pip3-script.py", "pip3.cmd",
                         "pip3.12-script.py", "pip3.12.cmd"])])
    rc, out, err = run([envpy] + ENGINE + ["-m", "pip", "--version"])
    check("`-m pip --version` in it is nypip", [rc, out.split(" from ")[0]], [0, "nypip 0.2.1"])
    if not WIN:
        rc, out, err = run([os.path.join(ENV, BIN, "pip"), "list"])
        check("... the pip command runs the environment's interpreter", [rc, out.split("\n")[:3]],
              [0, ["Package Version", "------- -------", "nypip   0.2.1  "]])

# ── F. the installer ────────────────────────────────────────────────────────


def pip(*args, env_path=ENV, stdin=None):
    py = os.path.join(env_path, BIN, PYNAME)
    return run([py] + ENGINE + ["-m", "pip"] + list(args), input=stdin)


if NYTHON:
    rc, out, err = pip("install", "--index-url", URL, "alpha")
    check("install from the index: the newest alpha and what it needs", [rc, out.strip().split("\n")[-1], err],
          [0, "Successfully installed gamma-1.0 beta-2.0 alpha-2.0", ""])
    rc, out, err = env_run("import alpha, beta, gamma; print(alpha.VERSION, beta.VERSION, gamma.VERSION)")
    check("... importable in the environment (gamma 2.0 is yanked, beta 2.0 needs gamma<2)", out.strip(), "2.0 2.0 1.0")
    rc, out, err = run([EXE] + ENGINE + ["-c", "import alpha"])
    check("... not outside it", "ModuleNotFoundError" in err or "ImportError" in err, True)
    rc, out, err = pip("install", "--index-url", URL, "alpha")
    check("... again: already satisfied", out.strip().split("\n")[-1].split(" in ")[0],
          "Requirement already satisfied: alpha")
    rc, out, err = pip("install", "--index-url", URL, "alpha[fancy]")
    check("... an extra adds its requirement", [rc, out.strip().split("\n")[-1]], [0, "Successfully installed extra-dep-1.0"])
    rc, out, err = pip("install", "--no-index", "--find-links", W, "tool")
    check("--find-links: a local directory of wheels", [rc, out.strip().split("\n")[-1]], [0, "Successfully installed tool-1.0"])
    if not WIN:
        rc, out, err = run([os.path.join(ENV, BIN, "ny-tool")])
        check("... its console script runs in the environment", [rc, out], [0, "tool says hi\n"])
        rc, out, err = run([os.path.join(ENV, BIN, "tool-sh")])
        check("... its .data script too", [rc, out], [0, "from a script\n"])
    rc, out, err = pip("list")
    check("list", out.split("\n"), ["Package   Version", "--------- -------", "alpha     2.0    ", "beta      2.0    ",
                                    "extra-dep 1.0    ", "gamma     1.0    ", "nypip     0.2.1  ", "tool      1.0    ", ""])
    rc, out, err = pip("freeze")
    check("freeze (the installer itself left out)", out, "alpha==2.0\nbeta==2.0\nextra-dep==1.0\ngamma==1.0\ntool==1.0\n")
    rc, out, err = pip("show", "beta")
    sh = dict(l.split(": ", 1) if ": " in l else (l.rstrip(":"), "") for l in out.strip().split("\n"))
    check("show: requires and required-by", [sh.get("Name"), sh.get("Version"), sh.get("Requires"), sh.get("Required-by"),
                                            os.path.normcase(sh.get("Location", "")) == os.path.normcase(os.path.join(ENV, SITE_REL))],
          ["beta", "2.0", "gamma", "alpha", True])
    rc, out, err = pip("check")
    check("check: nothing broken", [rc, out.strip()], [0, "No broken requirements found."])
    rc, out, err = pip("install", "--no-index", "--find-links", W, "conflict-a", "conflict-c")
    check("an unsatisfiable install: exit status 1 and PubGrub's explanation", [rc, err.strip().split("\n")],
          [1, ["ERROR: Cannot install the requirements because they conflict:", "",
               "Because every version of conflict-c depends on shared<2 and every version of conflict-a depends on shared>=2, conflict-c is incompatible with conflict-a.",
               "So, because you require both conflict-a and conflict-c, version solving failed."]])
    rc, out, err = pip("install", "--no-index", "--find-links", W, "needs-new-python")
    check("... Requires-Python another Python's", [rc, err.strip().split("\n")[-1]],
          [1, "Because you require needs-new-python which requires Python>=3.99 (the Python version is 3.12.0), version solving failed."])
    rc, out, err = pip("install", "--no-index", "--find-links", W, "gamma>=3")
    check("... no version matches", [rc, err.strip().split("\n")[-1]],
          [1, "Because you require gamma>=3, which doesn't match any versions, version solving failed."])
    # a requirements file: markers, a hash, an option line, a comment
    reqf = os.path.join(T, "reqs.txt")
    with open(reqf, "w") as f:
        f.write("# pinned\n--find-links %s\nshared==1.0 --hash=sha256:%s\nwinhelp==1.0; sys_platform == 'win32' --hash=sha256:%s  # Windows only\n"
                % (W, _sha("shared-1.0-py3-none-any.whl"), _sha("winhelp-1.0-py3-none-any.whl")))
    rc, out, err = pip("install", "--no-index", "-r", reqf)
    check("-r FILE: an option line, a hash, a marker for another platform", [rc, out.strip().split("\n")[-1]],
          [0, "Successfully installed shared-1.0" + (" winhelp-1.0" if WIN else "")])
    with open(reqf, "w") as f:
        f.write("shared==2.0 --hash=sha256:%s\n" % ("0" * 64))
    rc, out, err = pip("install", "--no-index", "-f", W, "-r", reqf)
    check("... a hash that does not match: refused", [rc, err.startswith("ERROR: shared-2.0-py3-none-any.whl does not match")],
          [1, True])
    # sdists built by PEP 517 backends
    src = os.path.join(T, "src", "srcpkg")
    os.makedirs(os.path.join(src, "srcpkg"))
    os.makedirs(os.path.join(src, "_build"))
    with open(os.path.join(src, "srcpkg", "__init__.py"), "w") as f:
        f.write("ANSWER = 42\n")
    with open(os.path.join(src, "_build", "mybackend.py"), "w") as f:
        f.write("# an in-tree backend: nypip's own, renamed (backend-path)\n"
                "from nypip.backend import build_wheel, build_sdist, get_requires_for_build_wheel, get_requires_for_build_sdist\n"
                "import os\nopen(os.path.join(os.path.dirname(__file__), 'ran'), 'w').write('yes')\n")
    with open(os.path.join(src, "pyproject.toml"), "w") as f:
        f.write('[build-system]\nrequires = []\nbuild-backend = "mybackend"\nbackend-path = ["_build"]\n\n'
                '[project]\nname = "srcpkg"\nversion = "3.1"\ndependencies = ["gamma"]\n'
                '[project.scripts]\nsrcpkg-run = "srcpkg:ANSWER.__str__"\n')
    rc, out, err = pip("install", "--no-index", "-f", W, src)
    check("a source tree: built by its in-tree backend in a subprocess, then installed", [rc, out.strip().split("\n")[-1],
          os.path.exists(os.path.join(src, "_build", "ran"))], [0, "Successfully installed srcpkg-3.1", True])
    rc, out, err = env_run("import srcpkg; print(srcpkg.ANSWER)")
    check("... importable", out.strip(), "42")
    # an sdist whose backend is a build requirement on the index
    bsrc = os.path.join(T, "src", "simplebuild")
    os.makedirs(os.path.join(bsrc, "simplebuild"))
    with open(os.path.join(bsrc, "simplebuild", "__init__.py"), "w") as f:
        f.write("from nypip.backend import build_wheel, build_sdist, get_requires_for_build_wheel\n"
                "MARK = 'simplebuild backend'\n")
    with open(os.path.join(bsrc, "pyproject.toml"), "w") as f:
        f.write('[build-system]\nrequires = []\nbuild-backend = "nypip.backend"\n[project]\nname = "simplebuild"\nversion = "1.0"\n')
    from nypip import backend as nyback
    here = os.getcwd()
    os.chdir(bsrc)
    try:
        bw = nyback.build_wheel(W)
    finally:
        os.chdir(here)
    INDEX.setdefault("simplebuild", []).append(bw)
    ssrc = os.path.join(T, "src", "needsbuild")
    os.makedirs(os.path.join(ssrc, "needsbuild"))
    with open(os.path.join(ssrc, "needsbuild", "__init__.py"), "w") as f:
        f.write("X = 'built with simplebuild'\n")
    with open(os.path.join(ssrc, "pyproject.toml"), "w") as f:
        f.write('[build-system]\nrequires = ["simplebuild"]\nbuild-backend = "simplebuild"\n'
                '[project]\nname = "needsbuild"\nversion = "0.5"\n')
    os.chdir(ssrc)
    try:
        sd = nyback.build_sdist(os.path.join(T, "sdists"))
    finally:
        os.chdir(here)
    shutil.copy(os.path.join(T, "sdists", sd), W)
    INDEX.setdefault("needsbuild", []).append(sd)
    check("nypip.backend made an sdist with PKG-INFO", [sd, "needsbuild-0.5/PKG-INFO" in
                                                        __import__("tarfile").open(os.path.join(W, sd)).getnames()],
          ["needsbuild-0.5.tar.gz", True])
    rc, out, err = pip("install", "--index-url", URL, "needsbuild")
    check("an sdist from the index: its build requirement installed in an isolated build environment",
          [rc, "Installing build dependencies: simplebuild" in out, out.strip().split("\n")[-1]],
          [0, True, "Successfully installed needsbuild-0.5"])
    rc, out, err = env_run("import needsbuild; print(needsbuild.X)\ntry:\n    import simplebuild\n    print('leaked')\nexcept ImportError:\n    print('isolated')\n")
    check("... installed, and its backend not in the environment", out.split(), ["built", "with", "simplebuild", "isolated"])
    # download
    dd = os.path.join(T, "downloads")
    rc, out, err = pip("download", "--index-url", URL, "-d", dd, "alpha==1.0")
    check("download: the files of a resolution", [rc, sorted(os.listdir(dd))],
          [0, ["alpha-1.0-py3-none-any.whl", "beta-2.0-py3-none-any.whl", "gamma-1.0-py3-none-any.whl"]])
    rc, out, err = pip("download", "--no-index", "-f", W, "-d", os.path.join(T, "dlwin"), "--platform", "windows", "plat")
    check("... for another platform: its wheel and its marker's dependency", sorted(os.listdir(os.path.join(T, "dlwin"))),
          ["plat-1.0-py3-none-win_amd64.whl", "winhelp-1.0-py3-none-any.whl"])
    # uninstall
    sp = os.path.join(ENV, SITE_REL)
    rc, out, err = pip("uninstall", "-y", "tool")
    check("uninstall: its files and commands gone", [rc, out.strip().split("\n"),
          os.path.exists(os.path.join(sp, "tool")), os.path.exists(os.path.join(ENV, BIN, "ny-tool"))],
          [0, ["Found existing installation: tool 1.0", "Uninstalling tool-1.0:", "  Successfully uninstalled tool-1.0"], False, False])
    rc, out, err = pip("uninstall", "-y", "nothing-here")
    check("... a package not installed", err.strip(), "WARNING: Skipping nothing-here as it is not installed.")
    rc, out, err = pip("install", "--no-index", "-f", W, "tool")     # (again, for importlib.metadata below)
    # the lock file, resolved for three platforms
    os.chdir(T)
    try:
        rc, out, err = pip("lock", "--no-index", "-f", W, "alpha==1.0", "plat")
        with open(os.path.join(T, "nython.lock"), encoding="utf-8") as f:
            lock_text = f.read()
    finally:
        os.chdir(here)
    import tomllib
    lock = tomllib.loads(lock_text)
    pk = {p["name"]: p for p in lock["packages"]}
    check("lock: one resolution per platform, merged", [rc, lock["lock-version"], sorted(pk),
                                                        lock["tool"]["nypip"]["platforms"]],
          [0, "1.0", ["alpha", "beta", "gamma", "plat", "winhelp"], ["linux", "windows", "macos"]])
    check("... a package one platform needs has that platform's marker", [pk["winhelp"].get("marker"), pk["alpha"].get("marker")],
          ['sys_platform == "win32"', None])
    check("... each platform's wheel, with its sha256", sorted((w["name"], w["hashes"]["sha256"] == _sha(w["name"])) for w in pk["plat"]["wheels"]),
          [("plat-1.0-py3-none-any.whl", True), ("plat-1.0-py3-none-manylinux_2_17_x86_64.whl", True),
           ("plat-1.0-py3-none-win_amd64.whl", True)])
    ENV2 = os.path.join(T, "env2")
    rc, out, err = run([EXE] + ENGINE + ["-m", "venv", "--without-pip", ENV2])
    rc0, out0, err0 = pip("install", "--no-index", "-f", W, "shared==2.0", env_path=ENV2)
    rc, out, err = pip("sync", os.path.join(T, "nython.lock"), env_path=ENV2)
    want_plat = "windows" if WIN else "linux"
    check("sync: exactly the lock for this platform (what it does not list removed)", [rc0, rc, out.strip().split("\n")],
          [0, 0, ["Uninstalled shared-2.0", "Installed alpha-1.0 beta-2.0 gamma-1.0 plat-1.0" + (" winhelp-1.0" if WIN else "")]])
    rc, out, err = env_run("import plat, alpha; print(plat.KIND, alpha.VERSION)", ENV2)
    check("... this platform's wheel of plat", out.strip(), want_plat + " 1.0")
    rc, out, err = pip("sync", os.path.join(T, "nython.lock"), env_path=ENV2)
    check("... a second sync has nothing to do", out.strip(), "Everything is in sync with " + os.path.join(T, "nython.lock"))
else:
    # python3: nypip's wheel installer, in-process, into python3's venv
    sp = os.path.join(ENV, SITE_REL)
    scheme = {"purelib": sp, "platlib": sp, "scripts": os.path.join(ENV, BIN), "data": ENV, "headers": os.path.join(ENV, "include")}
    for fn in ("alpha-2.0-py3-none-any.whl", "beta-2.0-py3-none-any.whl", "gamma-1.0-py3-none-any.whl",
               "tool-1.0-py3-none-any.whl", "extra_dep-1.0-py3-none-any.whl"):
        with WheelFile(os.path.join(W, fn)) as w:
            w.install(scheme, requested=fn.startswith(("alpha", "tool")), executable=envpy)
    rc, out, err = env_run("import alpha, beta, gamma; print(alpha.VERSION, beta.VERSION, gamma.VERSION)")
    check("nypip's wheel installer under python3: the packages import in python3's venv", out.strip(), "2.0 2.0 1.0")
    rc, out, err = run([os.path.join(ENV, BIN, "ny-tool")])
    check("... its console script runs python3's venv interpreter", [rc, out], [0, "tool says hi\n"])

# ── G. importlib.metadata ───────────────────────────────────────────────────
MPROBE = r'''
import json
from importlib.metadata import (version, distribution, distributions, entry_points, files, requires,
                                metadata, packages_distributions, PackageNotFoundError)
out = {}
out["version"] = version("alpha")
d = distribution("alpha")
out["name"] = [d.metadata["Name"], d.name, d.version]
out["requires"] = requires("alpha")
out["beta_requires"] = requires("beta")
out["files"] = sorted(str(f) for f in files("alpha"))
f = [x for x in files("alpha") if x.name == "__init__.py"][0]
out["file"] = [f.hash.mode, len(f.hash.value) > 20, f.size, f.read_text()]
eps = entry_points(group="console_scripts")
out["eps"] = sorted([e.name, e.value, e.group] for e in eps if e.name == "ny-tool")
ep = entry_points(group="console_scripts", name="ny-tool")
out["ep_attrs"] = [[e.module, e.attr, e.dist.name if e.dist else None] for e in ep]
out["ep_load"] = [e.load().__name__ for e in ep]
names = sorted(x.metadata["Name"] for x in distributions())
out["dists"] = [n for n in names if n in ("alpha", "beta", "gamma", "tool", "extra-dep")]
out["meta"] = [metadata("alpha")["Metadata-Version"], metadata("alpha").get_all("Requires-Dist"),
               metadata("alpha").get_all("Provides-Extra")]
try:
    version("no-such-dist")
    out["missing"] = "found"
except PackageNotFoundError as e:
    out["missing"] = [type(e).__name__, str(e)]
out["pkgs"] = packages_distributions().get("alpha")
out["read_text"] = [distribution("tool").read_text("INSTALLER"), distribution("alpha").read_text("NOPE")]
print(json.dumps(out))
'''
rc, out, err = env_run(MPROBE)
try:
    md = json.loads(out)
except Exception:
    md = {"error": (out + err)[-600:]}
check("importlib.metadata: version(), distribution(): Name, name, version", [md.get("version"), md.get("name")],
      ["2.0", ["alpha", "alpha", "2.0"]])
check("... requires()", [md.get("requires"), md.get("beta_requires")],
      [["beta>=2.0", "gamma", 'extra-dep; extra == "fancy"'], ["gamma<2"]])
check("... files() from RECORD, a file's hash, size and text", [md.get("files"), md.get("file")],
      [["alpha-2.0.dist-info/INSTALLER", "alpha-2.0.dist-info/METADATA", "alpha-2.0.dist-info/RECORD",
        "alpha-2.0.dist-info/REQUESTED", "alpha-2.0.dist-info/WHEEL", "alpha/__init__.py"],
       ["sha256", True, 16, "VERSION = '2.0'\n"]])
check("... entry_points(group=, name=), EntryPoint.module / attr / dist / load()",
      [md.get("eps"), md.get("ep_attrs"), md.get("ep_load")],
      [[["ny-tool", "tool:main", "console_scripts"]], [["tool", "main", "tool"]], ["main"]])
check("... distributions(), metadata()'s headers", [md.get("dists"), md.get("meta")],
      [["alpha", "beta", "extra-dep", "gamma", "tool"],
       ["2.1", ["beta>=2.0", "gamma", 'extra-dep; extra == "fancy"'], ["fancy"]]])
check("... PackageNotFoundError, packages_distributions(), read_text()",
      [md.get("missing"), md.get("pkgs"), md.get("read_text")],
      [["PackageNotFoundError", "No package metadata was found for no-such-dist"], ["alpha"], ["nypip\n", None]])

# ── H. site ─────────────────────────────────────────────────────────────────
sp = os.path.join(ENV, SITE_REL)
extra_dir = os.path.join(T, "extra_dir")
os.makedirs(extra_dir)
with open(os.path.join(extra_dir, "pthmod.py"), "w") as f:
    f.write("WHERE = 'extra_dir'\n")
with open(os.path.join(sp, "zz_extra.pth"), "w") as f:
    f.write("# a comment\n%s\nimport os; os.environ['NY128_PTH'] = 'ran'\n%s\n" % (extra_dir, os.path.join(T, "does-not-exist")))
with open(os.path.join(sp, "sitecustomize.py"), "w") as f:
    f.write("import sys\nsys.ny128_sitecustomize = True\n")
rc, out, err = env_run("import sys, os, pthmod\nprint(pthmod.WHERE, os.environ.get('NY128_PTH'), int(getattr(sys, 'ny128_sitecustomize', False)),"
                       " int(%r in sys.path), int(%r in sys.path))" % (extra_dir, os.path.join(T, "does-not-exist")))
# (Debian's python3 has a sitecustomize module of its own in the standard
# library, found before the environment's)
import shlex
SC = not os.path.exists(os.path.join(os.path.dirname(shlex.__file__), "sitecustomize.py"))
check("site: a .pth file's directory on sys.path, its import line run, a missing directory left out; sitecustomize",
      [out.strip(), err[-300:]], ["extra_dir ran %d 1 0" % int(SC), ""])
rc, out, err = env_run("import sys\ntry:\n    import pthmod\n    print('found')\nexcept ImportError:\n    print('no site')\n", extra=["-S"])
check("... -S: no site-packages", out.strip(), "no site")
rc, out, err = env_run("import site, sys; print(repr(site.ENABLE_USER_SITE) in ('False', 'false'), int(%r in site.getsitepackages()), sys.flags.no_site)" % sp)
check("... site.ENABLE_USER_SITE False in an environment, getsitepackages() its own", out.strip().lower(), "true 1 0")
ub = os.path.join(T, "userbase")
usite = os.path.join(ub, "Nython312" if (WIN and NYTHON) else "Python%d%d" % sys.version_info[:2] if WIN else "lib",
                     *(["site-packages"] if WIN else [("nython%d.%d" if NYTHON else "python%d.%d") % sys.version_info[:2], "site-packages"]))
os.makedirs(usite)
with open(os.path.join(usite, "usermod.py"), "w") as f:
    f.write("U = 'user site'\n")
ENV3 = os.path.join(T, "env3")
run([EXE] + ENGINE + ["-m", "venv", "--without-pip", "--system-site-packages", ENV3])
uenv = dict(os.environ)
uenv["PYTHONUSERBASE"] = ub
code = "try:\n    import usermod\n    print(usermod.U)\nexcept ImportError:\n    print('no user site')\n"
rc3, out3, err3 = env_run(code, ENV3, env=uenv)
rc1, out1, err1 = env_run(code, ENV, env=uenv)
check("... --system-site-packages: the user site is seen; without it, not", [out3.strip(), out1.strip()],
      ["user site", "no user site"])
with open(os.path.join(ENV3, "pyvenv.cfg"), encoding="utf-8") as f:
    check("... and pyvenv.cfg says so", "include-system-site-packages = true" in f.read(), True)
rc, out, err = run([os.path.join(ENV, BIN, PYNAME)] + ENGINE + ["-m", "site"])
lines = out.split("\n")
check("`-m site`: sys.path and the user site's state", [lines[0], any(os.path.normcase(sp) in os.path.normcase(l) for l in lines),
                                                         [l.split(":")[0] for l in lines if l.startswith(("USER_BASE", "USER_SITE", "ENABLE_USER_SITE"))]],
      ["sys.path = [", True, ["USER_BASE", "USER_SITE", "ENABLE_USER_SITE"]])

# ── I. Windows' own modules ─────────────────────────────────────────────────
if not WIN:
    got = []
    for m in ("msvcrt", "winreg", "winsound", "_winapi"):
        try:
            __import__(m)
            got.append("imported")
        except ModuleNotFoundError as e:
            got.append(str(e))
    check("msvcrt, winreg, winsound, _winapi are Windows-only (ModuleNotFoundError)", got,
          ["No module named 'msvcrt'", "No module named 'winreg'", "No module named 'winsound'", "No module named '_winapi'"])
else:
    import msvcrt
    import winreg
    import winsound
    import _winapi
    # msvcrt
    fn = os.path.join(T, "m.bin")
    fd = os.open(fn, os.O_RDWR | os.O_CREAT | os.O_BINARY)
    os.write(fd, b"0123456789")
    old = msvcrt.setmode(fd, os.O_TEXT)
    back = msvcrt.setmode(fd, os.O_BINARY)
    check("msvcrt.setmode returns the previous mode", [old, back, msvcrt.O_BINARY == os.O_BINARY], [os.O_BINARY, os.O_TEXT, True])
    os.lseek(fd, 0, 0)
    msvcrt.locking(fd, msvcrt.LK_NBLCK, 4)
    fd2 = os.open(fn, os.O_RDWR | os.O_BINARY)
    try:
        msvcrt.locking(fd2, msvcrt.LK_NBLCK, 4)
        got = "locked twice"
    except OSError as e:
        got = type(e).__name__
    os.lseek(fd, 0, 0)
    msvcrt.locking(fd, msvcrt.LK_UNLCK, 4)
    msvcrt.locking(fd2, msvcrt.LK_NBLCK, 4)
    msvcrt.locking(fd2, msvcrt.LK_UNLCK, 4)
    check("msvcrt.locking: a region locked through one descriptor is refused to another, then released",
          [got, msvcrt.LK_LOCK, msvcrt.LK_NBLCK, msvcrt.LK_UNLCK], ["PermissionError", 1, 2, 0])
    h = msvcrt.get_osfhandle(fd)
    fd3 = msvcrt.open_osfhandle(_winapi.DuplicateHandle(_winapi.GetCurrentProcess(), h, _winapi.GetCurrentProcess(), 0, False,
                                                       _winapi.DUPLICATE_SAME_ACCESS), os.O_RDONLY)
    os.lseek(fd3, 2, 0)
    check("msvcrt.get_osfhandle / open_osfhandle: a descriptor over a duplicated handle", [h > 0, os.read(fd3, 3)], [True, b"234"])
    for x in (fd, fd2, fd3):
        os.close(x)
    msvcrt.ungetch(b"q")
    a1 = msvcrt.getch()
    msvcrt.ungetwch("\u00e9")
    a2 = msvcrt.getwch()
    check("msvcrt.ungetch / getch, ungetwch / getwch", [a1, a2], [b"q", "\u00e9"])
    try:
        msvcrt.putch("x")
        got = "accepted"
    except TypeError:
        got = "TypeError"
    mode = msvcrt.GetErrorMode()
    prev = msvcrt.SetErrorMode(mode | msvcrt.SEM_FAILCRITICALERRORS)
    now = msvcrt.GetErrorMode()
    msvcrt.SetErrorMode(mode)
    check("msvcrt: putch wants bytes, heapmin, Get/SetErrorMode", [got, msvcrt.heapmin(), prev == mode,
                                                                    bool(now & msvcrt.SEM_FAILCRITICALERRORS)],
          ["TypeError", None, True, True])
    # winreg
    base = r"Software\NythonTest_%d" % os.getpid()
    k = winreg.CreateKey(winreg.HKEY_CURRENT_USER, base)
    check("winreg.CreateKey: a PyHKEY", [type(k).__name__, bool(k), int(k) == k.handle, repr(k).startswith("<PyHKEY:0x")],
          ["PyHKEY", True, True, True])
    vals = [("d", winreg.REG_DWORD, 0xFFFFFFFF), ("q", winreg.REG_QWORD, 2 ** 64 - 1), ("s", winreg.REG_SZ, "h\u00e9llo"),
            ("e", winreg.REG_EXPAND_SZ, "%PATH%;x"), ("m", winreg.REG_MULTI_SZ, ["a", "b"]),
            ("b", winreg.REG_BINARY, b"\x00\x01\xff"), ("n", winreg.REG_NONE, None), ("z", winreg.REG_BINARY, b"")]
    for name, t, v in vals:
        winreg.SetValueEx(k, name, 0, t, v)
    got = [winreg.QueryValueEx(k, name) for name, t, v in vals]
    check("winreg.SetValueEx / QueryValueEx for every type", got,
          [(0xFFFFFFFF, 4), (2 ** 64 - 1, 11), ("h\u00e9llo", 1), ("%PATH%;x", 2), (["a", "b"], 7), (b"\x00\x01\xff", 3),
           (None, 0), (None, 3)])
    names = sorted(winreg.EnumValue(k, i)[0] for i in range(len(vals)))
    try:
        winreg.EnumValue(k, len(vals))
        got = "more"
    except OSError as e:
        got = [type(e).__name__, e.winerror]
    check("winreg.EnumValue: every value, then OSError 259", [names, got], [sorted(n for n, t, v in vals), ["OSError", 259]])
    sub = winreg.CreateKeyEx(k, "child", 0, winreg.KEY_ALL_ACCESS)
    winreg.SetValue(k, "child", winreg.REG_SZ, "default text")
    check("winreg.SetValue / QueryValue: a sub key's default value", winreg.QueryValue(k, "child"), "default text")
    info = winreg.QueryInfoKey(k)
    check("winreg.QueryInfoKey / EnumKey", [info[0], info[1], info[2] > 10 ** 17, winreg.EnumKey(k, 0)], [1, len(vals), True, "child"])
    sub.Close()
    check("... a closed PyHKEY is false", [bool(sub), sub.handle], [False, 0])
    for bad, exc in ((("d", 0, winreg.REG_DWORD, -1), "OverflowError"), (("d", 0, winreg.REG_DWORD, 2 ** 32), "OverflowError"),
                     (("s", 0, winreg.REG_SZ, 5), "ValueError"), (("m", 0, winreg.REG_MULTI_SZ, "abc"), "ValueError"),
                     (("b", 0, winreg.REG_BINARY, "text"), "TypeError")):
        try:
            winreg.SetValueEx(k, *bad)
            got = "stored"
        except Exception as e:
            got = type(e).__name__
        check("winreg.SetValueEx refuses %r for type %d (%s)" % (bad[3], bad[2], exc), got, exc)
    try:
        winreg.OpenKey(winreg.HKEY_CURRENT_USER, base + r"\missing")
        got = "opened"
    except OSError as e:
        got = [type(e).__name__, e.winerror, e.errno]
    check("winreg.OpenKey of a missing key: FileNotFoundError [WinError 2]", got, ["FileNotFoundError", 2, 2])
    winreg.DeleteValue(k, "d")
    try:
        winreg.QueryValueEx(k, "d")
        got = "still there"
    except FileNotFoundError:
        got = "deleted"
    check("winreg.DeleteValue", got, "deleted")
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, base, 0, winreg.KEY_READ) as rk:
        check("winreg.OpenKey as a context manager", winreg.QueryValueEx(rk, "s")[0], "h\u00e9llo")
    check("... closed after the with block", bool(rk), False)
    os.environ["NY128_X"] = "expanded"
    check("winreg.ExpandEnvironmentStrings", winreg.ExpandEnvironmentStrings("[%NY128_X%]"), "[expanded]")
    events = []
    sys.addaudithook(lambda ev, args: events.append(ev) if ev.startswith(("winreg.", "msvcrt.")) else None)
    winreg.QueryValueEx(k, "s")
    winreg.FlushKey(k)
    winreg.DeleteKey(k, "child")
    h2 = k.Detach()
    winreg.CloseKey(h2)
    winreg.DeleteKey(winreg.HKEY_CURRENT_USER, base)
    try:
        winreg.OpenKey(winreg.HKEY_CURRENT_USER, base)
        got = "still there"
    except FileNotFoundError:
        got = "deleted"
    msvcrt.get_osfhandle(1)
    check("winreg.DeleteKey / Detach / CloseKey: the test key gone", got, "deleted")
    check("... the winreg.* and msvcrt.* audit events", events,
          ["winreg.QueryValue", "winreg.DeleteKey", "winreg.PyHKEY.Detach", "winreg.DeleteKey", "winreg.OpenKey",
           "msvcrt.get_osfhandle"])
    # winsound
    errs = []
    for args in ((36, 10), (32768, 10)):
        try:
            winsound.Beep(*args)
        except ValueError as e:
            errs.append(str(e))
    try:
        winsound.PlaySound(b"RIFF", winsound.SND_MEMORY | winsound.SND_ASYNC)
    except RuntimeError as e:
        errs.append(str(e))
    try:
        winsound.PlaySound(b"x", 0)
    except TypeError as e:
        errs.append(str(e))
    try:
        winsound.PlaySound("x", winsound.SND_MEMORY)
    except TypeError as e:
        errs.append(str(e))
    check("winsound's argument checks", errs,
          ["frequency must be in 37 thru 32767", "frequency must be in 37 thru 32767", "Cannot play asynchronously from memory",
           "'sound' must be str or None, not 'bytes'", "a bytes-like object is required, not 'str'"])
    import io, wave
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wv:
        wv.setnchannels(1)
        wv.setsampwidth(1)
        wv.setframerate(8000)
        wv.writeframes(b"\x80" * 80)
    try:
        winsound.PlaySound(buf.getvalue(), winsound.SND_MEMORY | winsound.SND_NODEFAULT)
        got = "played"
    except RuntimeError as e:
        got = str(e)       # (no sound device under Wine)
    check("winsound.PlaySound of a WAV in memory (played, or Failed to play sound without a device)",
          got in ("played", "Failed to play sound"), True)
    check("winsound.PlaySound(None, SND_PURGE), constants", [winsound.PlaySound(None, winsound.SND_PURGE),
                                                            winsound.SND_MEMORY, winsound.SND_ASYNC, winsound.MB_OK],
          [None, 4, 1, 0])
    # _winapi
    r, w = _winapi.CreatePipe(None, 0)
    n, e = _winapi.WriteFile(w, b"pipe data")
    data, e2 = _winapi.ReadFile(r, 4)
    check("_winapi.CreatePipe / WriteFile / ReadFile / PeekNamedPipe", [n, e, data, e2, _winapi.PeekNamedPipe(r)],
          [9, 0, b"pipe", 0, (5, 0)])
    check("_winapi.GetFileType of a pipe", _winapi.GetFileType(r), _winapi.FILE_TYPE_PIPE)
    _winapi.CloseHandle(r)
    _winapi.CloseHandle(w)
    pname = r"\\.\pipe\ny128_%d" % os.getpid()
    srv_h = _winapi.CreateNamedPipe(pname, _winapi.PIPE_ACCESS_DUPLEX | _winapi.FILE_FLAG_OVERLAPPED,
                                    _winapi.PIPE_TYPE_MESSAGE | _winapi.PIPE_READMODE_MESSAGE | _winapi.PIPE_WAIT,
                                    1, 4096, 4096, _winapi.NMPWAIT_WAIT_FOREVER, _winapi.NULL)
    ov = _winapi.ConnectNamedPipe(srv_h, overlapped=True)
    cli = _winapi.CreateFile(pname, _winapi.GENERIC_READ | _winapi.GENERIC_WRITE, 0, _winapi.NULL, _winapi.OPEN_EXISTING,
                             _winapi.FILE_FLAG_OVERLAPPED, _winapi.NULL)
    _winapi.SetNamedPipeHandleState(cli, _winapi.PIPE_READMODE_MESSAGE, None, None)
    wr = _winapi.WaitForMultipleObjects([ov.event], False, 5000)
    check("_winapi named pipe: ConnectNamedPipe overlapped, a client, the event signalled",
          [wr, ov.GetOverlappedResult(True)[1]], [0, 0])
    wov, err = _winapi.WriteFile(cli, b"message one", overlapped=True)
    wov.GetOverlappedResult(True)
    rov, err = _winapi.ReadFile(srv_h, 100, overlapped=True)
    _winapi.WaitForSingleObject(rov.event, 5000)
    n, err = rov.GetOverlappedResult(True)
    check("... an overlapped write and read of a message", [n, err, rov.getbuffer()], [11, 0, b"message one"])
    rov2, err = _winapi.ReadFile(srv_h, 100, overlapped=True)
    check("... a read with nothing to read waits (WAIT_TIMEOUT), cancel() ends it",
          [_winapi.WaitForSingleObject(rov2.event, 50), _winapi.WAIT_TIMEOUT], [_winapi.WAIT_TIMEOUT, 258])
    rov2.cancel()
    del rov2, rov, wov, ov
    _winapi.CloseHandle(cli)
    _winapi.CloseHandle(srv_h)
    cmd = '"%s" %s-c "import sys; sys.exit(7)"' % (sys.executable, "--vm " if VM else "")
    hp, ht, pid, tid = _winapi.CreateProcess(None, cmd, None, None, False, 0, None, None, None)
    w = _winapi.WaitForSingleObject(hp, 60000)
    check("_winapi.CreateProcess / WaitForSingleObject / GetExitCodeProcess", [w, _winapi.GetExitCodeProcess(hp), pid > 0],
          [_winapi.WAIT_OBJECT_0, 7, True])
    _winapi.CloseHandle(hp)
    _winapi.CloseHandle(ht)
    check("_winapi: GetCurrentProcess, GetACP, GetStdHandle, GetModuleFileName, constants",
          [_winapi.GetCurrentProcess() == 2 ** (64 if sys.maxsize > 2 ** 32 else 32) - 1, _winapi.GetACP() > 0,
           _winapi.GetStdHandle(_winapi.STD_OUTPUT_HANDLE) is not None,
           os.path.normcase(_winapi.GetModuleFileName(0)) == os.path.normcase(os.path.realpath(sys.executable)) or
           _winapi.GetModuleFileName(0).lower().endswith(".exe"), _winapi.INFINITE, _winapi.WAIT_OBJECT_0],
          [True, True, True, True, 4294967295, 0])
    fm = _winapi.CreateFileMapping(_winapi.INVALID_HANDLE_VALUE, _winapi.NULL, _winapi.PAGE_READWRITE, 0, 8192, "ny128_map_%d" % os.getpid())
    addr = _winapi.MapViewOfFile(fm, _winapi.FILE_MAP_WRITE, 0, 0, 0)
    size = _winapi.VirtualQuerySize(addr)
    _winapi.UnmapViewOfFile(addr)
    _winapi.CloseHandle(fm)
    check("_winapi file mappings: CreateFileMapping / MapViewOfFile / VirtualQuerySize", size >= 8192, True)

srv.shutdown()
os.chdir(HERE)
shutil.rmtree(T, ignore_errors=True)

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT128 PASSED ===")
