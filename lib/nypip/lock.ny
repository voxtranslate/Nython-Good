# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/lock.ny - the lock file, nython.lock (round 87).
#
# One resolution per target platform (linux, windows, macos: markers and
# wheel tags of each, this Python's version), merged: a package every
# target needs is listed once without a marker; one some targets need gets
# the marker naming them (sys_platform == "linux" or ...). Each package
# records its version, its dependencies, and every file a target installs -
# the wheel each target's tags pick, or the sdist - with its URL and sha256.
# The layout is PEP 751's (pylock.toml: lock-version, environments,
# [[packages]] with name, version, marker, requires-python, dependencies,
# wheels, sdist), with the inputs under [tool.nypip] so `nypip lock` can be
# run again. `nypip sync` installs exactly the lock for the running
# platform: the packages whose marker holds, at their versions, every file
# checked against its sha256, and removes the installed distributions the
# lock does not list.
#
#     text = write_lock(results, requirements, platforms, python_version)
#     lock = read_lock(path)
#     wanted = select(lock, env, tags)   -> {name: (package table, file table)}
#
# Written in the subset CPython runs too.

import os
import hashlib

_PLATFORM_MARKERS = {
    "linux": 'sys_platform == "linux"',
    "windows": 'sys_platform == "win32"',
    "macos": 'sys_platform == "darwin"',
}


def platform_marker(name):
    return _PLATFORM_MARKERS.get(name, 'platform_tag == "%s"' % name)


def _toml_str(s):
    out = '"'
    for ch in s:
        if ch == '"':
            out += '\\"'
        elif ch == "\\":
            out += "\\\\"
        elif ch == "\n":
            out += "\\n"
        elif ord(ch) < 32:
            out += "\\u%04x" % ord(ch)
        else:
            out += ch
    return out + '"'


def _inline(d):
    parts = []
    for k in d:
        v = d[k]
        if isinstance(v, dict):
            parts.append("%s = %s" % (k, _inline(v)))
        elif isinstance(v, list):
            parts.append("%s = [%s]" % (k, ", ".join(_toml_str(x) if isinstance(x, str) else _inline(x) for x in v)))
        else:
            parts.append("%s = %s" % (k, _toml_str(str(v))))
    return "{" + ", ".join(parts) + "}"


def file_entry(link, sha256):
    e = {"name": link.filename, "url": link.url_nofrag}
    e["hashes"] = {"sha256": sha256}
    return e


def link_sha256(finder, link, cache_dir):
    h = link.hashes.get("sha256")
    if h:
        return h
    path = finder.download(link, cache_dir)
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def write_lock(results, requirements, platforms, python_version, finder, cache_dir):
    """results: {platform: {name: Pick}} -> the lock file's text."""
    merged = {}
    order = []
    for plat in platforms:
        for name, pick in results[plat].items():
            key = (name, str(pick.version))
            if key not in merged:
                merged[key] = {"pick": pick, "platforms": [], "files": {}}
                order.append(key)
            m = merged[key]
            m["platforms"].append(plat)
            if pick.link is not None and pick.link.filename not in m["files"]:
                m["files"][pick.link.filename] = pick.link
    lines = ["# nython.lock - written by nypip (`nython -m pip lock`); install it with",
             "# `nython -m pip sync`. Run `nypip lock` again after changing the requirements.",
             'lock-version = "1.0"',
             'created-by = "nypip"',
             "environments = [%s]" % ", ".join(_toml_str(platform_marker(p)) for p in platforms),
             "",
             "[tool.nypip]",
             "requirements = [%s]" % ", ".join(_toml_str(r) for r in requirements),
             "platforms = [%s]" % ", ".join(_toml_str(p) for p in platforms),
             "python-version = %s" % _toml_str(str(python_version)),
             ""]
    for key in sorted(order):
        m = merged[key]
        pick = m["pick"]
        lines.append("[[packages]]")
        lines.append("name = %s" % _toml_str(pick.name))
        lines.append("version = %s" % _toml_str(str(pick.version)))
        if len(m["platforms"]) != len(platforms):
            lines.append("marker = %s" % _toml_str(" or ".join(platform_marker(p) for p in m["platforms"])))
        rp = pick.metadata.requires_python if pick.metadata is not None else None
        if rp:
            lines.append("requires-python = %s" % _toml_str(rp))
        deps = sorted(set(pick.requires))
        if deps:
            lines.append("dependencies = [%s]" % ", ".join(_inline({"name": d}) for d in deps))
        wheels = []
        sdist = None
        for fn in sorted(m["files"]):
            link = m["files"][fn]
            e = file_entry(link, link_sha256(finder, link, cache_dir))
            if link.kind == "wheel":
                wheels.append(e)
            else:
                sdist = e
        if sdist is not None:
            lines.append("sdist = %s" % _inline(sdist))
        if wheels:
            lines.append("wheels = [")
            for w in wheels:
                lines.append("    %s," % _inline(w))
            lines.append("]")
        lines.append("")
    return "\n".join(lines)


def read_lock(path):
    try:
        import tomllib
    except ImportError:
        import tomli as tomllib
    with open(path, "rb") as f:
        return tomllib.load(f)


def select(lock, env, tags):
    """{canonical name: (package, file)} the running platform installs."""
    from nypip._packaging.markers import Marker
    from nypip._packaging.utils import canonicalize_name, parse_wheel_filename
    rank = {}
    for i, t in enumerate(tags):
        rank.setdefault(t, i)
    out = {}
    for pkg in lock.get("packages", []):
        mk = pkg.get("marker")
        if mk:
            e = dict(env)
            e.setdefault("extra", "")
            if not Marker(mk).evaluate(e):
                continue
        best = None
        best_rank = None
        for w in pkg.get("wheels", []):
            try:
                n, v, b, ts = parse_wheel_filename(w["name"])
            except Exception:
                continue
            r = min([rank.get(t, 1 << 30) for t in ts])
            if r < (1 << 30) and (best is None or r < best_rank):
                best, best_rank = w, r
        if best is None:
            best = pkg.get("sdist")
        if best is None:
            raise ValueError("the lock has no file of %s %s for this platform" % (pkg["name"], pkg["version"]))
        out[canonicalize_name(pkg["name"])] = (pkg, best)
    return out
