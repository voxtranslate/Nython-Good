# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/installed.ny - the distributions installed in site-packages
# directories, and where an installation goes (round 87).
#
#     dists = find_distributions(paths)      # .dist-info directories found
#     d = get_distribution("pkg", paths)     # by canonical name, or None
#     d.name, d.version, d.location, d.metadata, d.requires(), d.files()
#     d.uninstall()                          # every file its RECORD lists
#     scheme(user=False, prefix=None, target=None)
#         -> {purelib, platlib, scripts, data, headers}: sysconfig's scheme
#            for this interpreter (a virtual environment's when in one)
#     site_dirs()                            # where installed distributions are
#
# Written in the subset CPython runs too.

import os
import sys
import shutil

from nypip import metadata as _md
from nypip._packaging.utils import canonicalize_name


class InstalledDist:
    def __init__(self, path):
        self.path = path
        self.location = os.path.dirname(path)
        self.metadata = _md.Metadata.parse(self.read_text("METADATA") or self.read_text("PKG-INFO") or "")
        base = os.path.basename(path)
        stem = base[:-10] if base.endswith(".dist-info") else base[:-9]
        self.name = self.metadata.name or stem.rsplit("-", 1)[0]
        self.version = self.metadata.version or (stem.rsplit("-", 1)[1] if "-" in stem else "")
        self.canonical_name = canonicalize_name(self.name)

    def read_text(self, name):
        p = os.path.join(self.path, name)
        try:
            with open(p, encoding="utf-8") as f:
                return f.read()
        except OSError:
            return None

    def requires(self):
        return self.metadata.requires_dist

    def entry_points(self):
        t = self.read_text("entry_points.txt")
        return _md.parse_entry_points(t) if t else {}

    def installer(self):
        t = self.read_text("INSTALLER")
        return t.strip() if t else ""

    def requested(self):
        return os.path.exists(os.path.join(self.path, "REQUESTED"))

    def record(self):
        t = self.read_text("RECORD")
        return _md.parse_record(t) if t else []

    def files(self):
        out = []
        for p, h, n in self.record():
            out.append(os.path.normpath(os.path.join(self.location, p)))
        return out

    def uninstall(self):
        """Remove every file the RECORD lists, the directories left empty,
        and the .dist-info directory; the paths removed."""
        removed = []
        dirs = set()
        for f in self.files():
            if os.path.isfile(f) or os.path.islink(f):
                os.remove(f)
                removed.append(f)
                dirs.add(os.path.dirname(f))
                if f.endswith(".py"):
                    # a stale bytecode cache of the module (CPython's)
                    c = os.path.join(os.path.dirname(f), "__pycache__")
                    if os.path.isdir(c):
                        stem = os.path.basename(f)[:-3] + "."
                        for x in os.listdir(c):
                            if x.startswith(stem) and x.endswith(".pyc"):
                                os.remove(os.path.join(c, x))
        if os.path.isdir(self.path):
            shutil.rmtree(self.path, ignore_errors=True)
            removed.append(self.path)
        # empty directories, deepest first, never above site-packages
        stop = os.path.normpath(self.location)
        for d in sorted(dirs, key=len, reverse=True):
            d = os.path.normpath(d)
            while d.startswith(stop + os.sep) and os.path.isdir(d):
                c = os.path.join(d, "__pycache__")
                if os.path.isdir(c) and not os.listdir(c):
                    os.rmdir(c)
                if os.listdir(d):
                    break
                os.rmdir(d)
                d = os.path.dirname(d)
        return removed

    def __repr__(self):
        return "<InstalledDist %s %s at %s>" % (self.name, self.version, self.location)


def site_dirs():
    """The directories of sys.path that hold installed distributions."""
    out = []
    for p in sys.path:
        if not p:
            p = os.getcwd()
        if os.path.isdir(p) and p not in out:
            out.append(p)
    return out


def find_distributions(paths=None):
    seen = set()
    out = []
    for d in (paths if paths is not None else site_dirs()):
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if not (n.endswith(".dist-info") or n.endswith(".egg-info")):
                continue
            p = os.path.join(d, n)
            if not os.path.isdir(p):
                continue
            dist = InstalledDist(p)
            if dist.canonical_name in seen:
                continue
            seen.add(dist.canonical_name)
            out.append(dist)
    return out


def get_distribution(name, paths=None):
    c = canonicalize_name(name)
    for d in find_distributions(paths):
        if d.canonical_name == c:
            return d
    return None


def scheme(user=False, prefix=None, target=None, root=None):
    """Where an installation goes: sysconfig's scheme for this interpreter
    (a virtual environment's inside one), --user's, --prefix's, or every
    library path in one --target directory."""
    import sysconfig
    if target:
        t = os.path.abspath(target)
        return {"purelib": t, "platlib": t, "scripts": os.path.join(t, "bin"),
                "data": t, "headers": os.path.join(t, "include")}
    if user:
        name = "nt_user" if os.name == "nt" else "posix_user"
    else:
        name = sysconfig.get_default_scheme()
    vars = None
    if prefix:
        p = os.path.abspath(prefix)
        vars = {"base": p, "platbase": p}
    paths = sysconfig.get_paths(name, vars)
    out = {"purelib": paths["purelib"], "platlib": paths["platlib"], "scripts": paths["scripts"],
           "data": paths["data"], "headers": os.path.join(paths["include"], "site")}
    if root:
        r = os.path.abspath(root)
        for k in out:
            p = out[k]
            drive, rest = os.path.splitdrive(p)
            out[k] = os.path.join(r, rest.lstrip("/\\"))
    return out
