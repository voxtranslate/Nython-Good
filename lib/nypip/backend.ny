# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/backend.ny - a PEP 517 build backend for pure-Python projects
# (round 87), in the manner of flit_core: everything comes from
# pyproject.toml's [project] table (PEP 621).
#
#     [build-system]
#     requires = []
#     build-backend = "nypip.backend"
#
#     [project]
#     name = "my-pkg"                 version = "1.0" (or dynamic = ["version"]:
#     dependencies = ["dep>=1"]       the package's __version__ = "...")
#     optional-dependencies = {fast = ["speedups"]}
#     requires-python = ">=3.8"       description, readme, license, authors,
#     scripts = {my-cmd = "my_pkg.cli:main"}   keywords, classifiers, urls,
#                                     gui-scripts, entry-points
#     [tool.nypip]                    optional: packages = ["pkg"], py-modules =
#                                     ["mod"] (default: the project's import
#                                     name as a package or module, under src/
#                                     or the root)
#
# The hooks: build_wheel, build_sdist, prepare_metadata_for_build_wheel,
# get_requires_for_build_wheel / _sdist (none). Written in the subset CPython
# runs too, so a project built with it builds the same under either.

import os
import re
import io
import tarfile

from nypip import metadata as _md
from nypip import wheel as _wheel


def _load_pyproject(src="."):
    try:
        import tomllib
    except ImportError:          # (python3 < 3.11)
        import tomli as tomllib
    with open(os.path.join(src, "pyproject.toml"), "rb") as f:
        return tomllib.load(f)


def _import_name(name):
    return re.sub(r"[-.]+", "_", name).lower()


def _find_sources(src, project, tool):
    """[(archive path, file path)] of the project's modules."""
    roots = []
    pkgs = tool.get("packages")
    mods = tool.get("py-modules")
    base = src
    if pkgs is None and mods is None:
        n = _import_name(project["name"])
        for b in (os.path.join(src, "src"), src):
            if os.path.isdir(os.path.join(b, n)):
                pkgs, base = [n], b
                break
            for ext in (".py", ".ny"):
                if os.path.isfile(os.path.join(b, n + ext)):
                    mods, base = [n + ext], b
                    break
            if pkgs or mods:
                break
        if pkgs is None and mods is None:
            raise ValueError("no package or module named %s in %s" % (n, src))
    elif os.path.isdir(os.path.join(src, "src")) and not os.path.exists(os.path.join(src, (pkgs or mods)[0])):
        base = os.path.join(src, "src")
    out = []
    for p in pkgs or []:
        top = os.path.join(base, *p.split("."))
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = sorted(d for d in dirnames if d != "__pycache__" and not d.startswith("."))
            for fn in sorted(filenames):
                if fn.endswith((".pyc", ".pyo")) or fn.startswith("."):
                    continue
                full = os.path.join(dirpath, fn)
                out.append((os.path.relpath(full, base).replace(os.sep, "/"), full))
    for m in mods or []:
        fn = m if m.endswith((".py", ".ny")) else m + ".py"
        out.append((fn, os.path.join(base, fn)))
    return out


def _version(src, project, sources):
    if "version" in project:
        return str(project["version"])
    if "version" not in project.get("dynamic", []):
        raise ValueError("[project] has no version")
    for arc, full in sources:
        if arc.endswith("__init__.py") or arc.endswith("__init__.ny") or arc.count("/") == 0:
            with open(full, encoding="utf-8") as f:
                m = re.search(r"^__version__\s*=\s*['\"]([^'\"]+)['\"]", f.read(), re.M)
            if m:
                return m.group(1)
    raise ValueError("dynamic version: no __version__ = '...' in the package")


def _metadata(src, project, version):
    h = [("Metadata-Version", "2.2"), ("Name", project["name"]), ("Version", version)]
    if project.get("description"):
        h.append(("Summary", project["description"]))
    for k in project.get("keywords", []) and [",".join(project["keywords"])]:
        h.append(("Keywords", k))
    for a in project.get("authors", []):
        if a.get("email"):
            if a.get("name"):
                h.append(("Author-email", "%s <%s>" % (a["name"], a["email"])))
            else:
                h.append(("Author-email", a["email"]))
        elif a.get("name"):
            h.append(("Author", a["name"]))
    lic = project.get("license")
    if isinstance(lic, dict) and lic.get("text"):
        h.append(("License", lic["text"]))
    elif isinstance(lic, str):
        h.append(("License-Expression", lic))
    for c in project.get("classifiers", []):
        h.append(("Classifier", c))
    for k, v in project.get("urls", {}).items():
        h.append(("Project-URL", "%s, %s" % (k, v)))
    if project.get("requires-python"):
        h.append(("Requires-Python", project["requires-python"]))
    for r in project.get("dependencies", []):
        h.append(("Requires-Dist", r))
    for extra, reqs in project.get("optional-dependencies", {}).items():
        h.append(("Provides-Extra", extra))
        for r in reqs:
            if ";" in r:
                req, _, mk = r.partition(";")
                h.append(("Requires-Dist", '%s; (%s) and extra == "%s"' % (req.strip(), mk.strip(), extra)))
            else:
                h.append(("Requires-Dist", '%s; extra == "%s"' % (r, extra)))
    body = ""
    readme = project.get("readme")
    if isinstance(readme, str):
        readme = {"file": readme}
    if isinstance(readme, dict):
        if readme.get("file"):
            with open(os.path.join(src, readme["file"]), encoding="utf-8") as f:
                body = f.read()
            ctype = readme.get("content-type") or ("text/markdown" if readme["file"].endswith(".md") else
                                                    "text/x-rst" if readme["file"].endswith(".rst") else "text/plain")
        else:
            body = readme.get("text", "")
            ctype = readme.get("content-type", "text/plain")
        h.append(("Description-Content-Type", ctype))
    return _md.Metadata(h, body)


def _entry_points(project):
    eps = {}
    if project.get("scripts"):
        eps["console_scripts"] = sorted(project["scripts"].items())
    if project.get("gui-scripts"):
        eps["gui_scripts"] = sorted(project["gui-scripts"].items())
    for g, items in project.get("entry-points", {}).items():
        eps[g] = sorted(items.items())
    return eps


def _prepare(src="."):
    pp = _load_pyproject(src)
    project = pp["project"]
    tool = pp.get("tool", {}).get("nypip", {})
    sources = _find_sources(src, project, tool)
    version = _version(src, project, sources)
    return project, version, sources, _metadata(src, project, version)


def get_requires_for_build_wheel(config_settings=None):
    return []


def get_requires_for_build_sdist(config_settings=None):
    return []


def prepare_metadata_for_build_wheel(metadata_directory, config_settings=None):
    project, version, sources, meta = _prepare(".")
    di = _wheel.escape_name(project["name"]) + "-" + _wheel.escape_version(version) + ".dist-info"
    d = os.path.join(metadata_directory, di)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "METADATA"), "w", encoding="utf-8") as f:
        f.write(meta.as_text())
    eps = _entry_points(project)
    if eps:
        with open(os.path.join(d, "entry_points.txt"), "w", encoding="utf-8") as f:
            f.write(_md.format_entry_points(eps))
    return di


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None, src="."):
    project, version, sources, meta = _prepare(src)
    files = {}
    for arc, full in sources:
        with open(full, "rb") as f:
            files[arc] = f.read()
    path = _wheel.write_wheel(wheel_directory, project["name"], version, files,
                              entry_points=_entry_points(project) or None, metadata_text=meta.as_text())
    return os.path.basename(path)


def build_sdist(sdist_directory, config_settings=None, src="."):
    project, version, sources, meta = _prepare(src)
    stem = _wheel.escape_name(project["name"]) + "-" + str(version)
    os.makedirs(sdist_directory, exist_ok=True)
    path = os.path.join(sdist_directory, stem + ".tar.gz")
    files = [("pyproject.toml", os.path.join(src, "pyproject.toml"))]
    readme = project.get("readme")
    if isinstance(readme, dict):
        readme = readme.get("file")
    if isinstance(readme, str) and os.path.isfile(os.path.join(src, readme)):
        files.append((readme, os.path.join(src, readme)))
    for arc, full in sources:
        files.append((os.path.relpath(full, src).replace(os.sep, "/"), full))

    def add(tf, name, data):
        ti = tarfile.TarInfo(stem + "/" + name)
        ti.size = len(data)
        ti.mtime = 315532800
        ti.mode = 0o644
        tf.addfile(ti, io.BytesIO(data))

    with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as tf:
        add(tf, "PKG-INFO", meta.as_text().encode("utf-8"))
        for arc, full in sorted(set(files)):
            with open(full, "rb") as f:
                add(tf, arc, f.read())
    return os.path.basename(path)
