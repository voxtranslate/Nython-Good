#!/usr/bin/env python3
"""tools/api_diff.py - the names CPython's modules have and Nython's lack.

A living conformance measure (round 85), after the compatibility dashboards
PyPy and GraalPy keep for CPython's API: every module in lib/ that CPython
also has, plus the engines' own os, sys, time, gc, math and builtins, is
imported under the host python3 (3.11, and 3.12 when it is installed) and
under both Nython engines, and the public names CPython has that Nython
lacks are listed with their CPython kind (function, class, constant,
module). One table row per module with its coverage, then the totals.

    python3 tools/api_diff.py                       # every module, both engines
    python3 tools/api_diff.py -m os -m sys -v       # these, with the missing names
    python3 tools/api_diff.py --json out.json       # everything, as JSON
    python3 tools/api_diff.py --write-baseline tools/api_baseline.json
    python3 tools/api_diff.py --check tools/api_baseline.json

--check needs no CPython: it imports each module of the baseline under both
engines and fails when a name the baseline records as present is gone (the
regression guard tools/sweep.py runs). The baseline is per platform; a
--check against a binary of another platform is skipped.

Public names: what dir() gives without a leading underscore, less modules
the module merely imported (os.sys, os.abc) unless they are in __all__ or
are its submodules, and less names another module defined that are not in
__all__ when the module has one (os.Mapping, os.GenericAlias). Under Nython
a name counts as present when hasattr(module, name) is true (PEP 562
__getattr__ included). A module that does not import under CPython here
(no _tkinter, say) is listed as such and not counted.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(REPO, "lib")
ENGINE_MODULES = ["os", "sys", "time", "gc", "math", "builtins", "posix"]
# side effects on import (a browser opened), or not CPython's module at all
SKIP = {"antigravity", "this", "__main__", "__phello__", "idlelib", "test"}

# Run under each CPython: {module: {"kinds": {name: kind}} | {"error": msg}}
PY_PROBE = r'''
import sys, json, types, importlib, io, warnings
warnings.simplefilter("ignore")
out = {}
for mod in sys.argv[1:]:
    saved = sys.stdout
    sys.stdout = io.StringIO()
    try:
        m = importlib.import_module(mod)
    except BaseException as e:
        sys.stdout = saved
        out[mod] = {"error": type(e).__name__ + ": " + str(e)[:200]}
        continue
    sys.stdout = saved
    allnames = getattr(m, "__all__", None)
    if not isinstance(allnames, (list, tuple)):
        allnames = None
    kinds = {}
    for n in dir(m):
        if n.startswith("_"):
            continue
        try:
            v = getattr(m, n)
        except Exception:
            continue
        if isinstance(v, types.ModuleType):
            if (allnames is not None and n in allnames) or getattr(v, "__name__", "") == mod + "." + n:
                kinds[n] = "module"
            continue
        if allnames is not None and n not in allnames:
            vm = getattr(v, "__module__", None)
            if isinstance(vm, str) and not isinstance(v, (int, float, str, bytes)) and vm not in (mod, "builtins") \
                    and not vm.startswith(mod + ".") and not (vm.lstrip("_") == mod.lstrip("_")) \
                    and not (mod == "os" and vm in ("posix", "nt")):
                continue
        if isinstance(v, type):
            kinds[n] = "class"
        elif callable(v):
            kinds[n] = "function"
        else:
            kinds[n] = "constant"
    out[mod] = {"kinds": kinds}
print(json.dumps(out))
'''

# Run under a Nython engine: argv = [names file]; the file holds
# {module: [names]}; prints a line "@@API " + JSON {module: {"has": [...]} |
# {"error": msg}} and "@@PLATFORM <sys.platform>"
NY_PROBE = r'''
import sys
import json
import importlib
import io
var spec = json.loads(open(sys.argv[1]).read())
var out = {}
for mod in spec:
    var saved = sys.stdout
    try:
        sys.stdout = io.StringIO()
        var m = importlib.import_module(mod)
        sys.stdout = saved
        var has = []
        for n in spec[mod]:
            var ok = False
            try:
                ok = hasattr(m, n)
            except BaseException:
                ok = False
            if ok:
                has.append(n)
        out[mod] = {"has": has}
    except BaseException as e:
        sys.stdout = saved
        out[mod] = {"error": type(e).__name__ + ": " + str(e)[:200]}
print("@@PLATFORM " + sys.platform)
print("@@API " + json.dumps(out))
'''


def lib_modules(stdlib_names):
    """The modules of lib/ (and its packages' submodules) CPython also has."""
    mods = set()
    for entry in sorted(os.listdir(LIB)):
        path = os.path.join(LIB, entry)
        if entry.endswith(".ny"):
            name = entry[:-3]
            if name in stdlib_names:
                mods.add(name)
        elif os.path.isdir(path) and os.path.exists(os.path.join(path, "__init__.ny")):
            if entry not in stdlib_names:
                continue
            for root, dirs, fnames in os.walk(path):
                dirs.sort()
                rel = os.path.relpath(root, LIB).replace(os.sep, ".")
                if not os.path.exists(os.path.join(root, "__init__.ny")):
                    dirs[:] = []
                    continue
                mods.add(rel)
                for f in sorted(fnames):
                    if f.endswith(".ny") and f != "__init__.ny" and f != "__main__.ny":
                        mods.add(rel + "." + f[:-3])
    mods.update(ENGINE_MODULES)
    return sorted(m for m in mods if m.split(".")[0] not in SKIP)


def pythons():
    found = []
    for exe in ("python3.11", "python3.12"):
        p = shutil.which(exe)
        if p:
            found.append((exe[6:], p))
    if not found and shutil.which("python3"):
        found.append(("%d.%d" % sys.version_info[:2], shutil.which("python3")))
    return found


def stdlib_names(py):
    r = subprocess.run([py, "-I", "-c", "import sys, json; print(json.dumps(sorted(sys.stdlib_module_names)))"],
                       capture_output=True, text=True)
    return set(json.loads(r.stdout))


def probe_python(py, mods, jobs):
    """{module: {"kinds": {...}} | {"error": ...}} under one CPython."""
    def chunk(ms):
        try:
            r = subprocess.run([py, "-I", "-W", "ignore", "-c", PY_PROBE] + ms, capture_output=True, text=True,
                               timeout=300, stdin=subprocess.DEVNULL, cwd=tempfile.gettempdir())
            return json.loads(r.stdout.strip().splitlines()[-1])
        except Exception:
            if len(ms) == 1:
                return {ms[0]: {"error": "probe failed"}}
            res = {}
            for m in ms:
                res.update(chunk([m]))
            return res
    groups = [mods[i:i + 20] for i in range(0, len(mods), 20)]
    out = {}
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        for r in ex.map(chunk, groups):
            out.update(r)
    return out


def probe_nython(binary, vm, spec, jobs, timeout):
    """{module: {"has": [...]} | {"error": ...}}, and sys.platform."""
    tmp = tempfile.mkdtemp(prefix="nyapi%d_" % os.getpid())
    script = os.path.join(tmp, "probe.ny")
    with open(script, "w") as f:
        f.write(NY_PROBE)
    platform = [None]

    def one(i_mod):
        i, mod = i_mod
        names = os.path.join(tmp, "names%d.json" % i)
        with open(names, "w") as f:
            json.dump({mod: spec[mod]}, f)
        cmd = [binary] + (["--vm"] if vm else []) + [script, names]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout,
                               stdin=subprocess.DEVNULL, cwd=tmp, env=dict(os.environ, NY_STUB_AUTOQUIT="5"))
        except subprocess.TimeoutExpired:
            return {mod: {"error": "timeout"}}
        res = None
        for line in r.stdout.splitlines():
            if line.startswith("@@PLATFORM "):
                platform[0] = line[11:].strip()
            elif line.startswith("@@API "):
                try:
                    res = json.loads(line[6:])
                except ValueError:
                    res = None
        if res is None:
            tail = (r.stdout + r.stderr).strip().splitlines()[-1:] or ["no output"]
            return {mod: {"error": "exit %d: %s" % (r.returncode, tail[0][:200])}}
        return res
    out = {}
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        for r in ex.map(one, enumerate(sorted(spec))):
            out.update(r)
    shutil.rmtree(tmp, ignore_errors=True)
    return out, platform[0]


def measure(binary, mods, jobs, timeout, engines):
    pys = pythons()
    if not pys:
        print("api_diff: no python3 found", file=sys.stderr)
        return None
    std = set()
    for _, p in pys:
        std |= stdlib_names(p)
    if mods is None:
        mods = lib_modules(std)
    # CPython's names: the union over the versions, each name tagged with the
    # versions that have it
    cp = {}
    unavailable = {}
    for ver, p in pys:
        for mod, r in probe_python(p, mods, jobs).items():
            if "error" in r:
                unavailable.setdefault(mod, {})[ver] = r["error"]
                continue
            d = cp.setdefault(mod, {})
            for n, k in r["kinds"].items():
                e = d.setdefault(n, {"kind": k, "versions": []})
                e["versions"].append(ver)
    spec = {m: sorted(cp[m]) for m in cp}
    ny = {}
    platform = None
    for eng in engines:
        ny[eng], platform = probe_nython(binary, eng == "vm", spec, jobs, timeout)
    # a dotted name CPython has no module for is one of Nython's own
    # submodules (lib/_tkinter/*), not a gap
    unav = {m: v for m, v in unavailable.items() if m not in cp
            and not ("." in m and all(e.startswith("ModuleNotFoundError") for e in v.values()))}
    return {"pythons": [v for v, _ in pys], "platform": platform, "cpython": cp, "unavailable": unav, "nython": ny}


def report(res, verbose, engines):
    cp, ny = res["cpython"], res["nython"]
    rows = []
    tot_cp = 0
    tot_has = {e: 0 for e in engines}
    tot_miss = 0
    for mod in sorted(cp):
        names = cp[mod]
        has = {}
        err = {}
        for e in engines:
            r = ny[e].get(mod, {"error": "not run"})
            has[e] = set(r.get("has", []))
            if "error" in r:
                err[e] = r["error"]
        both = set.intersection(*[has[e] for e in engines]) if engines else set()
        missing = sorted(n for n in names if n not in both)
        rows.append((mod, len(names), {e: len(has[e]) for e in engines}, missing, err))
        tot_cp += len(names)
        for e in engines:
            tot_has[e] += len(has[e])
        tot_miss += len(missing)
    head = "%-34s %6s " % ("module", "CPython") + " ".join("%7s" % e for e in engines) + " %7s %6s" % ("missing", "cover")
    print(head)
    print("-" * len(head))
    for mod, n, h, missing, err in rows:
        cover = 100.0 * (n - len(missing)) / n if n else 100.0
        print("%-34s %6d " % (mod, n) + " ".join("%7d" % h[e] for e in engines) + " %7d %5.1f%%" % (len(missing), cover)
              + ("  [%s]" % "; ".join("%s: %s" % kv for kv in err.items()) if err else ""))
        if verbose and missing:
            by = {}
            for m in missing:
                by.setdefault(cp[mod][m]["kind"], []).append(m + ("" if len(cp[mod][m]["versions"]) == len(res["pythons"])
                                                                   else "(" + ",".join(cp[mod][m]["versions"]) + ")"))
            for k in sorted(by):
                print("      %-9s %s" % (k, " ".join(by[k])))
    print("-" * len(head))
    cover = 100.0 * (tot_cp - tot_miss) / tot_cp if tot_cp else 100.0
    print("%-34s %6d " % ("TOTAL (%d modules)" % len(rows), tot_cp) + " ".join("%7d" % tot_has[e] for e in engines)
          + " %7d %5.1f%%" % (tot_miss, cover))
    if res.get("unavailable"):
        print("not importable under CPython here (not counted): " + " ".join(sorted(res["unavailable"])))
    print("CPython %s, Nython platform %s" % (" + ".join(res["pythons"]), res["platform"]))
    return tot_cp, tot_miss


def write_baseline(res, path, engines):
    base = {"comment": "tools/api_diff.py --write-baseline: per module, the CPython names each Nython engine has",
            "platform": res["platform"], "pythons": res["pythons"], "modules": {}}
    for mod in sorted(res["cpython"]):
        ent = {}
        sets = {e: set(res["nython"][e].get(mod, {}).get("has", [])) for e in engines}
        both = set.intersection(*sets.values()) if sets else set()
        ent["both"] = " ".join(sorted(both))
        for e in engines:
            only = sorted(sets[e] - both)
            if only:
                ent[e + "_only"] = " ".join(only)
        ent["cpython"] = len(res["cpython"][mod])
        base["modules"][mod] = ent
    with open(path, "w") as f:
        json.dump(base, f, indent=1, sort_keys=True)
        f.write("\n")


def check(path, binary, jobs, timeout, engines):
    base = json.load(open(path))
    lost = []
    for eng in engines:
        spec = {}
        for mod, ent in base["modules"].items():
            names = set(ent.get("both", "").split()) | set(ent.get(eng + "_only", "").split())
            if names:
                spec[mod] = sorted(names)
        got, platform = probe_nython(binary, eng == "vm", spec, jobs, timeout)
        if platform is not None and platform != base.get("platform"):
            print("api_diff --check: skipped (baseline is for %s, this binary is %s)" % (base.get("platform"), platform))
            return 0
        for mod in sorted(spec):
            r = got.get(mod, {})
            if "error" in r:
                lost.append((eng, mod, "import failed: " + r["error"]))
                continue
            gone = sorted(set(spec[mod]) - set(r.get("has", [])))
            if gone:
                lost.append((eng, mod, " ".join(gone)))
    total = sum(len(set(e.get("both", "").split())) for e in base["modules"].values())
    if lost:
        print("api_diff --check: %d module(s) lost names the baseline has:" % len(lost))
        for eng, mod, what in lost:
            print("  FAIL [%s] %s: %s" % (eng, mod, what))
        return 1
    print("api_diff --check: ok (%d modules, %d names on both engines)" % (len(base["modules"]), total))
    return 0


def main(argv):
    binary = os.path.join(REPO, "build", "nython-cli")
    mods = None
    verbose = False
    jobs = 3
    timeout = 120
    out_json = None
    baseline = None
    check_file = None
    engines = ["interp", "vm"]
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--bin":
            binary = argv[i + 1]; i += 1
        elif a in ("-m", "--module"):
            mods = (mods or []) + argv[i + 1].split(","); i += 1
        elif a == "-v":
            verbose = True
        elif a == "-j":
            jobs = int(argv[i + 1]); i += 1
        elif a == "--timeout":
            timeout = int(argv[i + 1]); i += 1
        elif a == "--json":
            out_json = argv[i + 1]; i += 1
        elif a == "--write-baseline":
            baseline = argv[i + 1]; i += 1
        elif a == "--check":
            check_file = argv[i + 1]; i += 1
        elif a == "--engine":
            engines = argv[i + 1].split(","); i += 1
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print("api_diff: unknown argument " + a, file=sys.stderr)
            return 2
        i += 1
    binary = os.path.abspath(binary)
    if check_file:
        return check(check_file, binary, jobs, timeout, engines)
    res = measure(binary, mods, jobs, timeout, engines)
    if res is None:
        return 0
    report(res, verbose, engines)
    if out_json:
        with open(out_json, "w") as f:
            json.dump(res, f, indent=1, sort_keys=True)
    if baseline:
        write_baseline(res, baseline, engines)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
