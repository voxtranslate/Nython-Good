# nython: module
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# ctypes.util - find_library (round 83), CPython's strategies: on Linux the
# dynamic linker's cache (`ldconfig -p`), then LD_LIBRARY_PATH and the usual
# library directories (CPython also asks gcc/ld; reading the directories
# gives the same answer without a compiler); on macOS the dyld search paths
# and frameworks; on Windows the DLL search path (PATH). Returns a name
# CDLL accepts (the soname on Linux) or None.

import os, sys, re, subprocess

def _arch_tag():
    var m = os.uname().machine if hasattr(os, "uname") else ""
    if m in ("x86_64", "amd64"):
        return "x86-64"
    if m in ("aarch64", "arm64"):
        return "AArch64"
    if m.startswith("i") and m.endswith("86"):
        return "i386"
    return m

def _findSoname_ldconfig(name):
    try:
        var out = subprocess.run(["/sbin/ldconfig", "-p"], capture_output=True, text=True,
                                 env=dict(os.environ, LC_ALL="C", LANG="C")).stdout
    except (OSError, FileNotFoundError):
        try:
            out = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True,
                                 env=dict(os.environ, LC_ALL="C", LANG="C")).stdout
        except (OSError, FileNotFoundError):
            return None
    var tag = _arch_tag()
    var want = "lib" + name + ".so"
    var fallback = None
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith(want):
            continue
        var soname = line.split(" ", 1)[0]
        if soname != want and not soname.startswith(want + "."):
            continue
        if "(" in line:
            var info = line[line.index("(") + 1:line.index(")")]
            if tag and tag != "x86-64" and tag not in info:
                continue
            if tag == "x86-64" and "x86-64" not in info:
                continue
        return soname
    return fallback

def _findLib_dirs(name):
    var dirs = []
    for var_ in ("LD_LIBRARY_PATH",):
        var v = os.environ.get(var_, "")
        if v:
            dirs.extend(v.split(":"))
    dirs.extend(["/lib64", "/usr/lib64", "/lib", "/usr/lib", "/usr/local/lib",
                 "/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu",
                 "/lib/aarch64-linux-gnu", "/usr/lib/aarch64-linux-gnu"])
    var pat = re.compile("^lib" + re.escape(name) + r"\.so(\.[0-9]+)*$")
    var best = None
    for d in dirs:
        try:
            var entries = os.listdir(d)
        except OSError:
            continue
        for e in sorted(entries):
            if pat.match(e):
                if best is None or len(e) > len(best):
                    best = e
        if best:
            return best
    return None

def find_library(name):
    if sys.platform == "win32":
        return _find_windows(name)
    if sys.platform == "darwin":
        return _find_darwin(name)
    return _findSoname_ldconfig(name) or _findLib_dirs(name)

def _find_darwin(name):
    var possible = ["lib" + name + ".dylib", name + ".dylib", name + ".framework/" + name]
    var dirs = ["/usr/local/lib", "/opt/homebrew/lib", "/usr/lib", "/System/Library/Frameworks"]
    for n in possible:
        for d in dirs:
            var p = os.path.join(d, n)
            if os.path.exists(p):
                return p
    # system libraries live in the dyld shared cache, not on disk
    for n in possible:
        try:
            _ffi_dlclose(_ffi_dlopen("/usr/lib/" + n, 0))
            return "/usr/lib/" + n
        except OSError:
            pass
    return None

def find_msvcrt():
    return None

def _find_windows(name):
    if name in ("c", "m"):
        return find_msvcrt()
    for d in os.environ.get("PATH", "").split(os.pathsep):
        var fname = os.path.join(d, name)
        if os.path.isfile(fname):
            return fname
        if fname.lower().endswith(".dll"):
            continue
        fname = fname + ".dll"
        if os.path.isfile(fname):
            return fname
    return None
