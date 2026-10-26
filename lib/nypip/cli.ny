# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/cli.ny - the commands of nypip (`nython -m nypip`, `nython -m
# pip`; round 87).
#
#   install   [-r FILE] [-c FILE] [REQ | PATH ...] [-U] [--force-reinstall]
#             [--no-deps] [--pre] [-i URL] [--extra-index-url URL] [--no-index]
#             [-f DIR|URL] [-t DIR | --prefix DIR | --user] [--root DIR]
#             [--dry-run] [--require-hashes] [--cert FILE] [-q] [-v]
#   uninstall [-y] [-r FILE] NAME ...
#   list      [--format columns|freeze|json] [--path DIR]
#   show      [-f] NAME ...
#   freeze    [--all] [--path DIR]
#   download  [-d DIR] [--no-deps] [--platform P] REQ ...
#   wheel     [-w DIR] [--no-deps] REQ | PATH ...
#   lock      [-r FILE] [REQ ...] [-o nython.lock] [--platform P ...]
#   sync      [nython.lock] [--dry-run]
#   check
#
# Exit status 0, or 1 with an "ERROR:" line; a resolution that cannot
# succeed prints PubGrub's explanation of why.
# Written in the subset CPython runs too.

import os
import sys
import json
import shutil
import tempfile

from nypip import __version__
from nypip import pubgrub
from nypip import installed as _inst
from nypip import index as _index
from nypip import resolver as _res
from nypip import req as _req
from nypip import build as _build
from nypip import lock as _lock
from nypip.wheel import WheelFile, WheelError
from nypip._packaging.requirements import Requirement
from nypip._packaging.specifiers import SpecifierSet
from nypip._packaging.utils import canonicalize_name
from nypip._packaging.version import Version


class CommandError(Exception):
    pass


class Log:
    def __init__(self, verbosity=0):
        self.verbosity = verbosity

    def info(self, msg):
        if self.verbosity >= 0:
            print(msg)
            sys.stdout.flush()

    def debug(self, msg):
        if self.verbosity > 0:
            print(msg)

    def warn(self, msg):
        sys.stderr.write("WARNING: " + msg + "\n")


# ── options ─────────────────────────────────────────────────────────────────

def _parser():
    import argparse
    p = argparse.ArgumentParser(prog="nypip", description="nypip %s - Nython's package installer" % __version__)
    p.add_argument("-V", "--version", action="store_true", help="show the version and exit")
    sub = p.add_subparsers(dest="command")

    def common(sp):
        sp.add_argument("-q", "--quiet", action="count", default=0)
        sp.add_argument("-v", "--verbose", action="count", default=0)

    def index_opts(sp):
        sp.add_argument("-i", "--index-url", default=None)
        sp.add_argument("--extra-index-url", action="append", default=[])
        sp.add_argument("--no-index", action="store_true")
        sp.add_argument("-f", "--find-links", action="append", default=[])
        sp.add_argument("--pre", action="store_true")
        sp.add_argument("--cert", default=None)
        sp.add_argument("-r", "--requirement", action="append", default=[])
        sp.add_argument("-c", "--constraint", action="append", default=[])
        sp.add_argument("--no-deps", action="store_true")

    sp = sub.add_parser("install")
    common(sp)
    index_opts(sp)
    sp.add_argument("args", nargs="*")
    sp.add_argument("-U", "--upgrade", action="store_true")
    sp.add_argument("--force-reinstall", action="store_true")
    sp.add_argument("-t", "--target", default=None)
    sp.add_argument("--prefix", default=None)
    sp.add_argument("--user", action="store_true")
    sp.add_argument("--root", default=None)
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--require-hashes", action="store_true")

    sp = sub.add_parser("uninstall")
    common(sp)
    sp.add_argument("args", nargs="*")
    sp.add_argument("-y", "--yes", action="store_true")
    sp.add_argument("-r", "--requirement", action="append", default=[])
    sp.add_argument("--path", action="append", default=[])

    sp = sub.add_parser("list")
    common(sp)
    sp.add_argument("--format", default="columns", choices=["columns", "freeze", "json"])
    sp.add_argument("--path", action="append", default=[])

    sp = sub.add_parser("show")
    common(sp)
    sp.add_argument("args", nargs="+")
    sp.add_argument("-f", "--files", action="store_true")
    sp.add_argument("--path", action="append", default=[])

    sp = sub.add_parser("freeze")
    common(sp)
    sp.add_argument("--all", action="store_true")
    sp.add_argument("--path", action="append", default=[])

    sp = sub.add_parser("download")
    common(sp)
    index_opts(sp)
    sp.add_argument("args", nargs="*")
    sp.add_argument("-d", "--dest", default=".")
    sp.add_argument("--platform", default=None)

    sp = sub.add_parser("wheel")
    common(sp)
    index_opts(sp)
    sp.add_argument("args", nargs="*")
    sp.add_argument("-w", "--wheel-dir", default=".")

    sp = sub.add_parser("lock")
    common(sp)
    index_opts(sp)
    sp.add_argument("args", nargs="*")
    sp.add_argument("-o", "--output", default="nython.lock")
    sp.add_argument("--platform", action="append", default=[])
    sp.add_argument("--python-version", default=None)

    sp = sub.add_parser("sync")
    common(sp)
    sp.add_argument("lockfile", nargs="?", default="nython.lock")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--cert", default=None)
    sp.add_argument("-t", "--target", default=None)

    sp = sub.add_parser("check")
    common(sp)
    sp.add_argument("--path", action="append", default=[])
    return p


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    p = _parser()
    try:
        opts = p.parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 2
    if opts.version:
        print("nypip %s from %s (nython %s)" % (__version__, os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                                 "%d.%d" % sys.version_info[:2]))
        return 0
    if not opts.command:
        p.print_help()
        return 0
    log = Log(getattr(opts, "verbose", 0) - getattr(opts, "quiet", 0))
    fn = {"install": cmd_install, "uninstall": cmd_uninstall, "list": cmd_list, "show": cmd_show,
          "freeze": cmd_freeze, "download": cmd_download, "wheel": cmd_wheel, "lock": cmd_lock,
          "sync": cmd_sync, "check": cmd_check}[opts.command]
    try:
        return fn(opts, log) or 0
    except pubgrub.SolveFailure as e:
        sys.stderr.write("ERROR: Cannot install the requirements because they conflict:\n\n" + str(e) + "\n")
        return 1
    except (CommandError, _req.ReqError, _index.HashMismatch, _index.IndexError_, _build.BuildError, WheelError) as e:
        sys.stderr.write("ERROR: " + str(e) + "\n")
        return 1


# ── shared steps ────────────────────────────────────────────────────────────

def gather(opts, log):
    """(items, constraints, ReqFile) from the arguments and -r / -c files."""
    rf = _req.ReqFile()
    for f in getattr(opts, "requirement", []):
        rf.parse(f)
    for f in getattr(opts, "constraint", []):
        rf.parse(f, constraint=True)
    items = []
    for a in getattr(opts, "args", []):
        items.append(_req.parse_item(a, os.getcwd(), None, "command line"))
    items.extend(rf.requirements)
    return items, rf.constraints, rf


def make_finder(opts, rf, log):
    if opts.index_url:
        idx = [opts.index_url]
    elif rf is not None and rf.index_urls:
        idx = rf.index_urls
    else:
        idx = None
    if idx is None:
        idx = [os.environ.get("PIP_INDEX_URL") or "https://pypi.org/simple/"]
    idx = idx + list(opts.extra_index_url) + (rf.extra_index_urls if rf is not None else [])
    fl = list(opts.find_links) + (rf.find_links if rf is not None else [])
    no_index = opts.no_index or (rf is not None and rf.no_index)
    return _index.Finder(index_urls=idx, find_links=fl, no_index=no_index, cert=opts.cert, log=log.debug)


class Session:
    """One command's working state: the finder, a cache directory, and the
    installer used for build requirements."""

    def __init__(self, finder, log, pre=False):
        self.finder = finder
        self.log = log
        self.pre = pre
        self.cache = tempfile.mkdtemp(prefix="nypip-")
        self.built = {}

    def close(self):
        shutil.rmtree(self.cache, ignore_errors=True)

    def install_build_requires(self, reqs, target_dir):
        self.log.info("Installing build dependencies: " + ", ".join(reqs))
        rs = [Requirement(r) for r in reqs]
        target = _res.Target.current()
        rs = [r for r in rs if _res.evaluate(r.marker, target)]
        prov = self.provider(target)
        picks, solver = _res.resolve(rs, prov)
        scheme = _inst.scheme(target=target_dir)
        for name, pick in picks.items():
            self.install_pick(pick, scheme, False)

    def build_link(self, link, path):
        if link.filename in self.built:
            return self.built[link.filename]
        self.log.info("Building wheel for %s (pyproject.toml)" % link.filename)
        w = _build.build_from_sdist(path, os.path.join(self.cache, "wheels"), self.install_build_requires,
                                    self.log.debug)
        self.built[link.filename] = w
        return w

    def provider(self, target, installed=None, upgrade=None, constraints=None, preferred=None):
        return _res.Provider(self.finder, target, pre=self.pre, constraints=constraints, installed=installed,
                             upgrade=upgrade, build_wheel=self.build_link, cache_dir=self.cache,
                             log=self.log.debug, preferred=preferred)

    def wheel_for(self, pick, hashes=None):
        path = self.finder.download(pick.link, self.cache, hashes or None)
        if pick.link.kind == "sdist":
            path = self.build_link(pick.link, path)
        return path

    def install_pick(self, pick, scheme, requested, hashes=None, direct_url=None):
        path = self.wheel_for(pick, hashes)
        old = _inst.get_distribution(pick.name, [scheme["purelib"]])
        if old is not None:
            self.log.info("  Attempting uninstall: %s" % old.name)
            self.log.info("    Found existing installation: %s %s" % (old.name, old.version))
            old.uninstall()
            self.log.info("    Successfully uninstalled %s-%s" % (old.name, old.version))
        with WheelFile(path) as w:
            w.install(scheme, requested=requested, direct_url=direct_url)


def local_link(path, session, log):
    """A Link for a local wheel / sdist / URL, or a source directory built
    into a wheel first."""
    if path.startswith(("http:", "https:", "file:")):
        l = _index.Link(path)
    elif os.path.isdir(path):
        log.info("Processing %s" % path)
        w = _build.build_wheel(path, os.path.join(session.cache, "wheels"), session.install_build_requires, log.debug)
        l = _index.Link(_index.path_to_url(w))
    elif os.path.isfile(path):
        l = _index.Link(_index.path_to_url(path))
    else:
        raise CommandError("%s is neither a file nor a directory" % path)
    if l.kind is None:
        raise CommandError("%s is not a wheel or an sdist" % path)
    return l


def requirements_for(items, session, target, log, keep_hashes=None):
    """[Requirement] for the resolver; local paths and URLs registered as
    direct links (name==version)."""
    reqs = []
    direct = {}
    for it in items:
        if it.path is not None:
            l = local_link(it.path, session, log)
            session.finder.add_direct(l)
            r = Requirement("%s==%s" % (l.project, l.version))
            direct[l.project] = l
        else:
            r = it.req
            if not _res.evaluate(r.marker, target):
                log.info("Ignoring %s: markers '%s' don't match your environment" % (r.name, r.marker))
                continue
            if r.url:
                l = _index.Link(r.url)
                if l.kind is None:
                    raise CommandError("%s is not a wheel or an sdist URL" % r.url)
                session.finder.add_direct(l)
                direct[l.project] = l
                r = Requirement(str(r.name) + ("[" + ",".join(sorted(r.extras)) + "]" if r.extras else ""))
        if keep_hashes is not None and it.hashes:
            keep_hashes[canonicalize_name(r.name)] = it.hashes
        reqs.append(r)
    return reqs, direct


def constraints_map(constraints, target):
    out = {}
    for c in constraints:
        if _res.evaluate(c.marker, target):
            out.setdefault(canonicalize_name(c.name), []).append(c.specifier)
    return out


def resolve_no_deps(reqs, prov):
    picks = {}
    for r in reqs:
        name = canonicalize_name(r.name)
        vs = prov.versions(name)
        if not vs:
            raise CommandError("no matching distribution found for %s" % r)
        ok = [v for v in vs if r.specifier.contains(v, prereleases=True)]
        if not ok:
            raise CommandError("no matching distribution found for %s" % r)
        pref = prov.preferred(name)
        v = pref if pref in ok else ok[-1]
        picks[name] = _res.Pick(prov.names.get(name, r.name), v, prov.best_link(name, v))
    return picks


# ── install ─────────────────────────────────────────────────────────────────

def cmd_install(opts, log):
    items, constraints, rf = gather(opts, log)
    if not items:
        raise CommandError("You must give at least one requirement to install (see \"nypip help install\")")
    finder = make_finder(opts, rf, log)
    session = Session(finder, log, pre=opts.pre or rf.pre)
    try:
        target = _res.Target.current()
        scheme = _inst.scheme(user=opts.user, prefix=opts.prefix, target=opts.target, root=opts.root)
        paths = [scheme["purelib"]] if (opts.target or opts.prefix or opts.root) else _inst.site_dirs()
        installed = {}
        for d in _inst.find_distributions(paths):
            installed[d.canonical_name] = d
        hashes = {}
        reqs, direct = requirements_for(items, session, target, log, hashes)
        requested = set(canonicalize_name(r.name) for r in reqs)
        hash_mode = opts.require_hashes or bool(hashes)
        if hash_mode:
            for r in reqs:
                n = canonicalize_name(r.name)
                pinned = [s for s in r.specifier if s.operator in ("==", "===") and not s.version.endswith(".*")]
                if n not in direct and (not pinned or n not in hashes):
                    raise CommandError("In --require-hashes mode, every requirement must be pinned with == and "
                                       "have a --hash: %s" % r)
        prov = session.provider(target, installed={k: v.version for k, v in installed.items()},
                                upgrade=(True if opts.upgrade else None),
                                constraints=constraints_map(constraints, target))
        for r in reqs:
            log.info("Collecting %s" % r)
        if opts.no_deps:
            picks = resolve_no_deps(reqs, prov)
        else:
            picks, solver = _res.resolve(reqs, prov)
        todo = []
        for name, pick in picks.items():
            if pick.link is None:
                raise CommandError("no file to install for %s %s" % (pick.name, pick.version))
            if hash_mode and name not in hashes and name not in direct:
                raise CommandError("Hashes are required in --require-hashes mode, but they are missing from "
                                   "some requirements: %s==%s" % (pick.name, pick.version))
            have = installed.get(name)
            if have is not None and not opts.force_reinstall:
                try:
                    same = Version(have.version) == pick.version
                except Exception:
                    same = False
                if same:
                    log.info("Requirement already satisfied: %s in %s (%s)" % (have.name, have.location, have.version))
                    continue
            todo.append(pick)
        if opts.dry_run:
            if todo:
                log.info("Would install " + " ".join("%s-%s" % (p.name, p.version) for p in todo))
            return 0
        done = []
        for pick in todo:
            name = canonicalize_name(pick.name)
            du = None
            if name in direct:
                du = {"url": direct[name].url_nofrag, "archive_info": {}}
            log.debug("Installing %s %s from %s" % (pick.name, pick.version, pick.link.filename))
            session.install_pick(pick, scheme, name in requested, hashes.get(name), du)
            done.append("%s-%s" % (pick.name, pick.version))
        if done:
            log.info("Successfully installed " + " ".join(done))
        return 0
    finally:
        session.close()


# ── uninstall / list / show / freeze / check ───────────────────────────────

def _paths(opts):
    return opts.path if getattr(opts, "path", None) else _inst.site_dirs()


def cmd_uninstall(opts, log):
    names = list(opts.args)
    rf = _req.ReqFile()
    for f in opts.requirement:
        rf.parse(f)
    for it in rf.requirements:
        if it.req is not None:
            names.append(it.req.name)
    if not names:
        raise CommandError("You must give at least one requirement to uninstall")
    for n in names:
        d = _inst.get_distribution(n, _paths(opts))
        if d is None:
            log.warn("Skipping %s as it is not installed." % n)
            continue
        log.info("Found existing installation: %s %s" % (d.name, d.version))
        log.info("Uninstalling %s-%s:" % (d.name, d.version))
        if not opts.yes:
            log.info("  Would remove:")
            for f in sorted(set(os.path.dirname(f) if "/__init__." in f.replace(os.sep, "/") else f for f in d.files())):
                log.info("    " + f)
            sys.stdout.write("Proceed (Y/n)? ")
            sys.stdout.flush()
            ans = sys.stdin.readline().strip().lower()
            if ans not in ("", "y", "yes"):
                continue
        d.uninstall()
        log.info("  Successfully uninstalled %s-%s" % (d.name, d.version))
    return 0


def _sort_key(d):
    return d.name.lower()


def cmd_list(opts, log):
    dists = sorted(_inst.find_distributions(_paths(opts)), key=_sort_key)
    if opts.format == "freeze":
        for d in dists:
            print("%s==%s" % (d.name, d.version))
        return 0
    if opts.format == "json":
        print(json.dumps([{"name": d.name, "version": d.version} for d in dists]))
        return 0
    rows = [("Package", "Version")] + [(d.name, d.version) for d in dists]
    w0 = max(len(r[0]) for r in rows)
    w1 = max(len(r[1]) for r in rows)
    print("Package".ljust(w0) + " " + "Version".ljust(w1))
    print("-" * w0 + " " + "-" * w1)
    for r in rows[1:]:
        print(r[0].ljust(w0) + " " + r[1].ljust(w1))
    return 0


def _req_names(d):
    out = []
    for r in d.requires():
        try:
            req = Requirement(r)
        except Exception:
            continue
        if req.marker is not None and "extra" in str(req.marker):
            continue
        out.append(req.name)
    return out


def cmd_show(opts, log):
    paths = _paths(opts)
    all_dists = _inst.find_distributions(paths)
    status = 0
    first = True
    for n in opts.args:
        d = _inst.get_distribution(n, paths)
        if d is None:
            log.warn("Package(s) not found: %s" % n)
            status = 1
            continue
        if not first:
            print("---")
        first = False
        req_by = sorted(x.name for x in all_dists if canonicalize_name(d.name) in
                        [canonicalize_name(r) for r in _req_names(x)])
        md = d.metadata
        home = md.get("Home-page", "")
        if not home:
            for u in md.get_all("Project-URL"):
                if u.lower().startswith("homepage"):
                    home = u.split(",", 1)[1].strip()
        print("Name: " + d.name)
        print("Version: " + d.version)
        print("Summary: " + md.get("Summary", ""))
        print("Home-page: " + home)
        print("Author: " + md.get("Author", ""))
        print("Author-email: " + md.get("Author-email", ""))
        print("License: " + (md.get("License") or md.get("License-Expression") or ""))
        print("Location: " + d.location)
        print("Requires: " + ", ".join(sorted(set(_req_names(d)), key=str.lower)))
        print("Required-by: " + ", ".join(req_by))
        if opts.files:
            print("Files:")
            for p, h, s in d.record():
                print("  " + p)
    return status


def cmd_freeze(opts, log):
    skip = set() if opts.all else {"nypip", "pip", "setuptools", "wheel", "distribute"}
    for d in sorted(_inst.find_distributions(_paths(opts)), key=_sort_key):
        if d.canonical_name in skip:
            continue
        print("%s==%s" % (d.name, d.version))
    return 0


def cmd_check(opts, log):
    dists = _inst.find_distributions(_paths(opts))
    have = {d.canonical_name: d for d in dists}
    target = _res.Target.current()
    problems = 0
    for d in sorted(dists, key=_sort_key):
        for r in d.requires():
            try:
                req = Requirement(r)
            except Exception:
                continue
            if not _res.evaluate(req.marker, target):
                continue
            x = have.get(canonicalize_name(req.name))
            if x is None:
                print("%s %s requires %s, which is not installed." % (d.name, d.version, req.name))
                problems += 1
            elif not req.specifier.contains(x.version, prereleases=True):
                print("%s %s has requirement %s, but you have %s %s." % (d.name, d.version, r.split(";")[0].strip(),
                                                                          x.name, x.version))
                problems += 1
    if not problems:
        print("No broken requirements found.")
    return 1 if problems else 0


# ── download / wheel ────────────────────────────────────────────────────────

def cmd_download(opts, log):
    items, constraints, rf = gather(opts, log)
    finder = make_finder(opts, rf, log)
    session = Session(finder, log, pre=opts.pre or rf.pre)
    try:
        target = _res.Target.named(opts.platform) if opts.platform else _res.Target.current()
        reqs, direct = requirements_for(items, session, target, log)
        prov = session.provider(target, constraints=constraints_map(constraints, target))
        if opts.no_deps:
            picks = resolve_no_deps(reqs, prov)
        else:
            picks, solver = _res.resolve(reqs, prov)
        os.makedirs(opts.dest, exist_ok=True)
        saved = []
        for name, pick in picks.items():
            src = finder.download(pick.link, session.cache)
            dst = os.path.join(opts.dest, pick.link.filename)
            if os.path.abspath(src) != os.path.abspath(dst):
                shutil.copyfile(src, dst)
            log.info("Saved " + dst)
            saved.append(pick.name)
        if saved:
            log.info("Successfully downloaded " + " ".join(saved))
        return 0
    finally:
        session.close()


def cmd_wheel(opts, log):
    items, constraints, rf = gather(opts, log)
    finder = make_finder(opts, rf, log)
    session = Session(finder, log, pre=opts.pre or rf.pre)
    try:
        os.makedirs(opts.wheel_dir, exist_ok=True)
        made = []
        rest = []
        for it in items:
            if it.path is not None and os.path.isdir(it.path):
                log.info("Building wheel for %s" % it.path)
                w = _build.build_wheel(it.path, opts.wheel_dir, session.install_build_requires, log.debug)
                log.info("  Created wheel " + os.path.basename(w))
                made.append(os.path.basename(w))
                if not opts.no_deps:
                    with WheelFile(w) as wf:
                        for r in wf.metadata.requires_dist:
                            rest.append(_req.Item(req=Requirement(r)))
            else:
                rest.append(it)
        if rest:
            target = _res.Target.current()
            reqs, direct = requirements_for(rest, session, target, log)
            prov = session.provider(target, constraints=constraints_map(constraints, target))
            picks = resolve_no_deps(reqs, prov) if opts.no_deps else _res.resolve(reqs, prov)[0]
            for name, pick in picks.items():
                w = session.wheel_for(pick)
                dst = os.path.join(opts.wheel_dir, os.path.basename(w))
                if os.path.abspath(w) != os.path.abspath(dst):
                    shutil.copyfile(w, dst)
                made.append(os.path.basename(w))
        if made:
            log.info("Successfully built " + " ".join(made))
        return 0
    finally:
        session.close()


# ── lock / sync ─────────────────────────────────────────────────────────────

def cmd_lock(opts, log):
    items, constraints, rf = gather(opts, log)
    if not items:
        raise CommandError("nothing to lock: give requirements or -r FILE")
    finder = make_finder(opts, rf, log)
    session = Session(finder, log, pre=opts.pre or rf.pre)
    try:
        platforms = opts.platform or ["linux", "windows", "macos"]
        results = {}
        texts = []
        for it in items:
            if it.req is not None:
                texts.append(str(it.req))
            else:
                texts.append(it.path)
        pv = None
        for plat in platforms:
            target = _res.Target.named(plat, opts.python_version)
            pv = target.python_version
            reqs, direct = requirements_for(items, session, target, log)
            prov = session.provider(target, constraints=constraints_map(constraints, target))
            try:
                picks, solver = _res.resolve(reqs, prov)
            except pubgrub.SolveFailure as e:
                raise CommandError("the requirements cannot be resolved for %s:\n\n%s" % (plat, e))
            results[plat] = picks
            log.info("Resolved %d packages for %s" % (len(picks), plat))
        text = _lock.write_lock(results, texts, platforms, pv, finder, session.cache)
        with open(opts.output, "w", encoding="utf-8") as f:
            f.write(text)
        log.info("Wrote " + opts.output)
        return 0
    finally:
        session.close()


def cmd_sync(opts, log):
    from nypip._packaging import markers as _markers
    from nypip._packaging import tags as _tags
    lock = _lock.read_lock(opts.lockfile)
    env = _markers.default_environment()
    wanted = _lock.select(lock, env, list(_tags.sys_tags()))
    finder = _index.Finder(index_urls=[], cert=opts.cert, log=log.debug)
    session = Session(finder, log)
    try:
        scheme = _inst.scheme(target=opts.target)
        paths = [scheme["purelib"]] if opts.target else _inst.site_dirs()
        have = {d.canonical_name: d for d in _inst.find_distributions(paths)}
        keep = {"nypip", "pip"}
        removed = []
        gone = set()
        installed = []
        purelib = os.path.normcase(os.path.abspath(scheme["purelib"]))
        for name in sorted(have):
            d = have[name]
            if name in keep:
                continue
            w = wanted.get(name)
            if w is None or Version(d.version) != Version(w[0]["version"]):
                # only what this environment's site-packages holds
                if os.path.normcase(os.path.abspath(d.location)) != purelib:
                    continue
                if not opts.dry_run:
                    d.uninstall()
                removed.append("%s-%s" % (d.name, d.version))
                gone.add(name)
        for name in sorted(wanted):
            pkg, f = wanted[name]
            d = have.get(name)
            if d is not None and name not in gone and Version(d.version) == Version(pkg["version"]):
                continue
            if not opts.dry_run:
                link = _index.Link(f["url"], f.get("name"))
                sha = (f.get("hashes") or {}).get("sha256")
                if not sha:
                    raise CommandError("the lock has no sha256 for %s" % f.get("name"))
                path = finder.download(link, session.cache, {"sha256": [sha]})
                if link.kind == "sdist":
                    path = session.build_link(link, path)
                with WheelFile(path) as w:
                    w.install(scheme, requested=True)
            installed.append("%s-%s" % (pkg["name"], pkg["version"]))
        if removed:
            log.info(("Would uninstall " if opts.dry_run else "Uninstalled ") + " ".join(removed))
        if installed:
            log.info(("Would install " if opts.dry_run else "Installed ") + " ".join(installed))
        if not removed and not installed:
            log.info("Everything is in sync with " + opts.lockfile)
        return 0
    finally:
        session.close()
