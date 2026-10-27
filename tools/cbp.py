#!/usr/bin/env python3
"""tools/cbp.py - read nython.cbp the way Code::Blocks builds it.

The Windows build is defined by the Code::Blocks project, not by the
Makefile: its <Unit> list decides what is compiled and linked, its targets
decide the flags. Anything that builds or checks the Windows side from Linux
goes through this script, so it builds exactly what a Code::Blocks user
builds (a source file missing from the project fails here too - twice a
round added .cpp files the project never listed, and only a Windows user's
link step found out).

    python3 tools/cbp.py check                    # every src/**.cpp is a unit
    python3 tools/cbp.py units                    # .cpp units, one per line
    python3 tools/cbp.py cxxflags Release --sdl /opt/sdl3-mingw
    python3 tools/cbp.py ldflags  Release --sdl /opt/sdl3-mingw

Code::Blocks' default option policy is used: project options first, then the
target's. `C:\\SDL3` is replaced by --sdl (the SDL prefix of the cross build).
"""
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CBP = os.path.join(ROOT, "nython.cbp")


def load():
    # Code::Blocks' TinyXML accepts a bare "&" (as in a post-build "2>&1");
    # a strict parser does not, so escape any that are not entities.
    text = open(CBP, encoding="utf-8").read()
    text = re.sub(r"&(?!amp;|lt;|gt;|quot;|apos;|#)", "&amp;", text)
    return ET.fromstring(text.encode("utf-8")).find("Project")


def target(proj, name):
    for t in proj.find("Build").findall("Target"):
        if t.get("title") == name:
            return t
    sys.exit("cbp.py: no target %r in nython.cbp" % name)


def units(proj):
    out = []
    for u in proj.findall("Unit"):
        f = u.get("filename")
        if f.endswith((".cpp", ".c", ".cc")):
            out.append(f.replace("\\", "/"))
    return out


def fix_path(p, sdl):
    p = p.replace("\\", "/")
    if sdl and p.upper().startswith("C:/SDL3"):
        p = sdl + p[len("C:/SDL3"):]
    return p


def section(el, tag):
    s = el.find(tag)
    return [] if s is None else list(s)


def subsystem(proj, tname):
    """-mwindows for a GUI target (type 0), as Code::Blocks links it."""
    for o in target(proj, tname).findall("Option"):
        if o.get("type") is not None:
            return "-mwindows" if o.get("type") == "0" else "-mconsole"
    return "-mconsole"


def cxxflags(proj, tname, sdl):
    flags, seen = [], set()
    for el in section(proj, "Compiler") + section(target(proj, tname), "Compiler"):
        if el.tag != "Add":
            continue
        if el.get("option"):
            f = el.get("option")
        elif el.get("directory"):
            f = "-I" + fix_path(el.get("directory"), sdl)
        else:
            continue
        if f not in seen:           # the project and target repeat -std, -Wall, ...
            seen.add(f)
            flags.append(f)
    return flags


def ldflags(proj, tname, sdl):
    opts, dirs, libs = [], [], []
    # The target's libraries come first on the command line (link order
    # matters on MinGW: mingw32, then SDL, then system libraries).
    for el in section(target(proj, tname), "Linker") + section(proj, "Linker"):
        if el.tag != "Add":
            continue
        if el.get("option"):
            opts.append(el.get("option"))
        elif el.get("directory"):
            dirs.append("-L" + fix_path(el.get("directory"), sdl))
        elif el.get("library") and "-l" + el.get("library") not in libs:
            libs.append("-l" + el.get("library"))
    return [subsystem(proj, tname)] + opts + dirs + libs


def check(proj):
    have = set(units(proj))
    os.chdir(ROOT)
    srcs = sorted(set(glob.glob("src/**/*.cpp", recursive=True)))
    missing = sorted(set(srcs) - have)
    stale = sorted(u for u in have if not os.path.exists(os.path.join(ROOT, u)))
    for m in missing:
        print("nython.cbp: %s is not a unit (the Windows build will not link)" % m)
    for s in stale:
        print("nython.cbp: unit %s does not exist" % s)
    if missing or stale:
        return 1
    print("nython.cbp: all %d source files are units" % len(srcs))
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    sdl = None
    if "--sdl" in rest:
        i = rest.index("--sdl")
        sdl = rest[i + 1]
        del rest[i:i + 2]
    tname = rest[0] if rest else "Release"
    proj = load()
    if cmd == "check":
        return check(proj)
    if cmd == "units":
        print("\n".join(units(proj)))
    elif cmd == "cxxflags":
        print(" ".join(cxxflags(proj, tname, sdl)))
    elif cmd == "ldflags":
        print(" ".join(ldflags(proj, tname, sdl)))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
