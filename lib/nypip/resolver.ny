# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/resolver.ny - what to install: requirements resolved by PubGrub
# (nypip/pubgrub.ny) over what a Finder lists (round 87).
#
#     env = Target.current()                 # or Target.named("windows") ...
#     plan = resolve(["a>=1", "b[x]"], finder, env)     # {name: Pick}
#     except pubgrub.SolveFailure as e: print(e)        # why not, in English
#
# A package's candidates are the versions with a file usable on the target:
# a wheel whose tags it supports (pure-Python wheels: py3-none-any ...), else
# an sdist; not yanked (PEP 592) unless the requirement pins that version;
# pre-releases only when asked for (--pre, a requirement naming one, or a
# project with nothing else). A version's dependencies are its metadata's
# Requires-Dist with markers evaluated for the target (PEP 508), read from
# the index's separate metadata (PEP 658), the wheel, or an sdist's PKG-INFO
# (PEP 643), else from a wheel built from it. Requires-Python that the target
# does not meet forbids the version. An extra is a package of its own,
# "name[extra]", depending on name at the same version and on the extra's
# requirements (as uv models them).
#
# Written in the subset CPython runs too.

import os
import sys
import tempfile

from nypip import pubgrub
from nypip import metadata as _md
from nypip._packaging.requirements import Requirement
from nypip._packaging.specifiers import SpecifierSet
from nypip._packaging.version import Version
from nypip._packaging.utils import canonicalize_name
from nypip._packaging import markers as _markers
from nypip._packaging import tags as _tags


class ResolveError(Exception):
    pass


class Target:
    """An environment to resolve for: marker values, supported wheel tags,
    the Python version."""

    def __init__(self, name, env, tags, python_version):
        self.name = name
        self.env = env
        self.tags = tags                       # [Tag] best first
        self.tag_rank = {}
        for i, t in enumerate(tags):
            self.tag_rank.setdefault(t, i)
        self.python_version = Version(python_version)

    @classmethod
    def current(cls):
        env = _markers.default_environment()
        return cls("current", env, list(_tags.sys_tags()), env["python_full_version"])

    @classmethod
    def named(cls, name, python_version=None):
        """A platform the lock file is resolved for: linux, windows, macos
        (x86_64 / AMD64 / arm64), with this Python's version."""
        cur = _markers.default_environment()
        pv = python_version or cur["python_full_version"]
        short = ".".join(pv.split(".")[:2])
        base = {"implementation_name": cur["implementation_name"],
                "implementation_version": cur["implementation_version"],
                "platform_python_implementation": cur["platform_python_implementation"],
                "python_full_version": pv, "python_version": short,
                "platform_release": "", "platform_version": ""}
        if name == "linux":
            base.update(os_name="posix", sys_platform="linux", platform_system="Linux", platform_machine="x86_64")
            plats = ["manylinux_2_%d_x86_64" % m for m in range(39, 4, -1)] + \
                    ["manylinux2014_x86_64", "manylinux2010_x86_64", "manylinux1_x86_64", "linux_x86_64"]
        elif name == "windows":
            base.update(os_name="nt", sys_platform="win32", platform_system="Windows", platform_machine="AMD64")
            plats = ["win_amd64"]
        elif name == "macos":
            base.update(os_name="posix", sys_platform="darwin", platform_system="Darwin", platform_machine="arm64")
            plats = []
            for minor in range(15, 10, -1):
                plats += ["macosx_%d_0_arm64" % minor, "macosx_%d_0_universal2" % minor]
            plats += ["macosx_11_0_arm64", "macosx_11_0_universal2"]
        else:
            raise ValueError("unknown platform %r (linux, windows, macos)" % name)
        pyv = tuple(int(x) for x in short.split("."))
        tags = list(_tags.compatible_tags(pyv, None, plats))
        return cls(name, base, tags, pv)

    def marker_env(self, extra=""):
        e = dict(self.env)
        e["extra"] = extra
        return e


def evaluate(marker, target, extra=""):
    if marker is None:
        return True
    try:
        return marker.evaluate(target.marker_env(extra))
    except Exception:
        return False


class Pick:
    """A resolved distribution: its name, version and the file to install."""

    def __init__(self, name, version, link, metadata=None):
        self.name = name
        self.version = version
        self.link = link
        self.metadata = metadata
        self.requires = []           # canonical names it depends on (for ordering)

    def __repr__(self):
        return "<Pick %s %s %s>" % (self.name, self.version, self.link.filename if self.link else "")


def split_extra(pkg):
    if pkg.endswith("]") and "[" in pkg:
        i = pkg.index("[")
        return pkg[:i], pkg[i + 1:-1]
    return pkg, ""


class Provider:
    def __init__(self, finder, target, pre=False, constraints=None, installed=None, upgrade=None,
                 build_wheel=None, cache_dir=None, log=None, preferred=None):
        self.finder = finder
        self.target = target
        self.pre = pre
        self.pre_names = set()
        self.pinned = {}                       # name -> set of versions pinned with ==
        self.constraints = constraints or {}   # name -> [SpecifierSet]
        self.installed = installed or {}       # name -> version string
        self.upgrade = upgrade                 # None: nothing; True: everything; set of names
        self.prefer = preferred or {}          # name -> Version (a lock's)
        self.build_wheel = build_wheel         # fn(link) -> wheel path (sdists)
        self.cache_dir = cache_dir or tempfile.mkdtemp(prefix="nypip-cache-")
        self.log = log
        self._versions = {}                    # name -> {Version: [Link]}
        self._meta = {}                        # (name, Version) -> Metadata
        self._deps = {}
        self.names = {}                        # canonical -> name as the metadata spells it

    # ── candidates ────────────────────────────────────────────────────────
    def _files(self, name):
        got = self._versions.get(name)
        if got is not None:
            return got
        links = self.finder.links(name)
        if links is None:
            self._versions[name] = None
            return None
        by = {}
        for l in links:
            if l.kind is None or l.version is None:
                continue
            if l.kind == "wheel":
                if not any(t in self.target.tag_rank for t in l.tags):
                    continue
            if l.requires_python:
                try:
                    if not SpecifierSet(l.requires_python).contains(self.target.python_version, prereleases=True):
                        continue
                except Exception:
                    pass
            if l.yanked is not None and l.version not in self.pinned.get(name, ()):
                continue
            by.setdefault(l.version, []).append(l)
        self._versions[name] = by
        return by

    def best_link(self, name, version):
        files = (self._files(name) or {}).get(version) or []
        best = None
        best_rank = None
        for l in files:
            if l.kind == "wheel":
                r = min(self.target.tag_rank.get(t, 1 << 30) for t in l.tags)
            else:
                r = 1 << 29
            if best is None or r < best_rank:
                best, best_rank = l, r
        return best

    def versions(self, pkg):
        name, extra = split_extra(pkg)
        files = self._files(name)
        if files is None:
            return None
        vs = sorted(files)
        allow_pre = self.pre or name in self.pre_names
        if not allow_pre:
            finals = [v for v in vs if not v.is_prerelease]
            if finals:
                vs = finals
        for spec in self.constraints.get(name, []):
            vs = [v for v in vs if spec.contains(v, prereleases=True)]
        return vs

    def format_version(self, pkg, v):
        return "==" + str(v)

    def display_name(self, pkg):
        name, extra = split_extra(pkg)
        n = self.names.get(name, name)
        return n + ("[" + extra + "]" if extra else "")

    def preferred(self, pkg):
        name, extra = split_extra(pkg)
        if name in self.prefer:
            return self.prefer[name]
        if self.upgrade is True or (self.upgrade and name in self.upgrade):
            return None
        v = self.installed.get(name)
        if v is not None:
            try:
                return Version(v)
            except Exception:
                return None
        return None

    # ── metadata ──────────────────────────────────────────────────────────
    def metadata(self, name, version, cheap=False):
        key = (name, version)
        if key in self._meta:
            return self._meta[key]
        link = self.best_link(name, version)
        if link is None:
            raise pubgrub.Unavailable("no file")
        md = None
        if cheap and not link.is_local:
            # (a download is not cheap: only what is known already)
            return None
        if link.kind == "wheel":
            if link.is_local:
                from nypip.wheel import WheelFile
                with WheelFile(link.local_path()) as w:
                    md = w.metadata
            else:
                data = self.finder.fetch_metadata(link)
                if data is not None:
                    md = _md.Metadata.parse(data)
                else:
                    path = self.finder.download(link, self.cache_dir)
                    from nypip.wheel import WheelFile
                    with WheelFile(path) as w:
                        md = w.metadata
        else:
            if cheap and not link.is_local:
                return None
            from nypip import build as _build
            path = self.finder.download(link, self.cache_dir)
            md = _build.sdist_metadata(path)
            if md is None:
                if cheap:
                    return None
                if self.build_wheel is None:
                    raise pubgrub.Unavailable("its sdist needs building")
                wpath = self.build_wheel(link, path)
                from nypip.wheel import WheelFile
                with WheelFile(wpath) as w:
                    md = w.metadata
        if md.name and canonicalize_name(md.name) != name:
            raise pubgrub.Unavailable("its metadata names %s" % md.name)
        if md.name:
            self.names.setdefault(name, md.name)
        self._meta[key] = md
        return md

    def _requirements(self, name, version, md, extra):
        out = []
        rp = md.requires_python
        if rp:
            try:
                ok = SpecifierSet(rp).contains(self.target.python_version, prereleases=True)
            except Exception:
                ok = True
            if not ok:
                out.append(pubgrub.Forbidden("Python" + str(SpecifierSet(rp)),
                                             "the Python version is %s" % self.target.python_version))
        if extra:
            out.append(pubgrub.Dependency(name, _eq(version), "==" + str(version)))
        for r in md.requires_dist:
            try:
                req = Requirement(r)
            except Exception:
                continue
            if extra:
                if not (evaluate(req.marker, self.target, extra) and not evaluate(req.marker, self.target, "")):
                    continue
            elif not evaluate(req.marker, self.target, ""):
                continue
            out.extend(dependencies_of(req))
        return out

    def dependencies(self, pkg, version):
        name, extra = split_extra(pkg)
        key = (pkg, version)
        if key in self._deps:
            return self._deps[key]
        try:
            md = self.metadata(name, version)
        except pubgrub.Unavailable:
            raise
        except Exception as e:
            raise pubgrub.Unavailable(str(e))
        deps = self._requirements(name, version, md, extra)
        self._deps[key] = deps
        return deps

    def cheap_dependencies(self, pkg, version):
        name, extra = split_extra(pkg)
        key = (pkg, version)
        if key in self._deps:
            return self._deps[key]
        try:
            md = self.metadata(name, version, cheap=True)
        except Exception:
            return None
        if md is None:
            return None
        deps = self._requirements(name, version, md, extra)
        self._deps[key] = deps
        return deps


def _eq(version):
    return lambda v: v == version


def _spec_contains(spec):
    return lambda v: spec.contains(v, prereleases=True)


def dependencies_of(req):
    """The pubgrub dependencies a Requirement stands for: the project, and
    one virtual package per extra."""
    name = canonicalize_name(req.name)
    label = str(req.specifier)
    out = [pubgrub.Dependency(name, _spec_contains(req.specifier), label)]
    for e in sorted(req.extras):
        out.append(pubgrub.Dependency(name + "[" + canonicalize_name(e) + "]", _spec_contains(req.specifier), label))
    return out


def resolve(requirements, provider):
    """requirements: [Requirement] (markers already applied by the caller).
    Returns {canonical name: Pick} in dependency order (a package after what
    it depends on)."""
    root = []
    for req in requirements:
        name = canonicalize_name(req.name)
        if req.specifier.prereleases:
            provider.pre_names.add(name)
        for s in req.specifier:
            if s.operator in ("==", "===") and not s.version.endswith(".*"):
                try:
                    provider.pinned.setdefault(name, set()).add(Version(s.version))
                except Exception:
                    pass
        provider.names.setdefault(name, req.name)
        root.extend(dependencies_of(req))
    solver = pubgrub.Solver(provider, root)
    solution = solver.solve()
    picks = {}
    for pkg, v in solution.items():
        name, extra = split_extra(pkg)
        if extra:
            continue
        link = provider.best_link(name, v)
        md = provider._meta.get((name, v))
        p = Pick(provider.names.get(name, name), v, link, md)
        deps = provider._deps.get((pkg, v)) or []
        p.requires = sorted(set(split_extra(d.name)[0] for d in deps if isinstance(d, pubgrub.Dependency)))
        for (pk, ver), ds in provider._deps.items():
            n2, e2 = split_extra(pk)
            if n2 == name and e2 and ver == v:
                for d in ds:
                    if isinstance(d, pubgrub.Dependency) and split_extra(d.name)[0] != name:
                        p.requires.append(split_extra(d.name)[0])
        picks[name] = p
    # dependency order, ties by name
    order = []
    done = set()

    def visit(n, stack):
        if n in done or n not in picks:
            return
        if n in stack:
            return
        stack.add(n)
        for d in sorted(set(picks[n].requires)):
            visit(d, stack)
        stack.discard(n)
        done.add(n)
        order.append(n)

    for n in sorted(picks):
        visit(n, set())
    return {n: picks[n] for n in order}, solver
