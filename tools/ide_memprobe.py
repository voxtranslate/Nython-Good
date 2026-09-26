#!/usr/bin/env python3
"""ide_memprobe.py - how much memory the IDE keeps per frame and per action.

The interpreter never reclaims containers (GC_NOTES.md), so anything the IDE
allocates while repainting, polling or handling a key is memory it keeps for
the rest of the session. This drives the real IDE headlessly and reports the
resident-set growth for:

    idle     frames with nothing happening (repaint + watcher + timers)
    hover    the pointer moving over the workbench (hover, tooltips)
    typing   characters typed into an editor
    scroll   wheel scrolling through a long file

    python3 tools/ide_memprobe.py            # report
    python3 tools/ide_memprobe.py --check    # exit 1 above the ceilings

Ceilings are what the current IDE is held to; lowering one is progress.
"""
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ide_driver import IDE  # noqa: E402

# KB of resident memory kept, per unit. Measured when these were set:
# idle 0.0, hover 0.0, typing ~40, scroll ~7 (before this round's fixes:
# 3.45, 40, 787 and 161).
CEILINGS = {"idle": 0.5, "hover": 2.0, "typing": 50.0, "scroll": 12.0, "split": 2.0}


def rss_kb(pid):
    with open("/proc/%d/status" % pid) as f:
        for ln in f:
            if ln.startswith("VmRSS:"):
                return int(ln.split()[1])
    return 0


def settle(ide, frames=30):
    ide.snap(settle=frames)


def measure(ide, action, units, warm):
    """Run action(n) for `warm` units first (caches fill), then `units`."""
    action(warm)
    settle(ide)
    before = rss_kb(ide.proc.pid)
    action(units)
    settle(ide)
    after = rss_kb(ide.proc.pid)
    return (after - before) / float(units), before, after


def main(argv):
    check = "--check" in argv
    root = tempfile.mkdtemp(prefix="nymem_")
    ws = os.path.join(root, "proj")
    os.makedirs(ws)
    with open(os.path.join(ws, "app.ny"), "w") as f:
        f.write('def greet(name):\n    return "hi " + name\n\nprint(greet("bob"))\n')
    with open(os.path.join(ws, "long.ny"), "w") as f:
        for i in range(600):
            f.write("def f%d(x):\n    return x * %d + len(\"%d\")\n\n" % (i, i, i))
    ide = IDE(cwd=ws, env={"HOME": root})
    ide.start()
    results = {}
    try:
        t = ide.find("app.ny")
        ide.dblclick(int(t.cx), int(t.cy))
        settle(ide)

        def idle(n):
            ide.wait(n)
        results["idle"] = measure(ide, idle, 600, 120)

        def hover(n):
            for i in range(n):
                ide.move(100 + (i * 37) % 1400, 40 + (i * 53) % 880)
                ide.wait(1)
        results["hover"] = measure(ide, hover, 150, 60)

        def typing(n):
            ide.key("ctrl+end")
            for i in range(n):
                ide.type("x" if i % 8 else "\n")
        results["typing"] = measure(ide, typing, 150, 40)

        t = ide.find("long.ny")
        ide.dblclick(int(t.cx), int(t.cy))
        settle(ide)

        def scroll(n):
            for i in range(n):
                ide.wheel(900, 400, -3 if (i // 40) % 2 == 0 else 3)
                ide.wait(1)
        results["scroll"] = measure(ide, scroll, 160, 80)

        # Two editor groups repaint on every hover: swapping the other
        # group's view in to paint it must not allocate either.
        # Measured against plain hover at the same point in the process's
        # life (once the allocator's slack is used up, every input event's
        # map shows in RSS - see GC_NOTES), so the number is what painting
        # the second group adds.
        t = ide.find("app.ny")
        ide.dblclick(int(t.cx), int(t.cy))
        settle(ide)
        base = measure(ide, hover, 150, 60)
        ide.key("ctrl+\\")
        settle(ide)
        sp = measure(ide, hover, 150, 60)
        results["split"] = (sp[0] - base[0], sp[1], sp[2])
    finally:
        ide.close()
        ide.cleanup()
        shutil.rmtree(root, ignore_errors=True)
    bad = []
    for k in ["idle", "hover", "typing", "scroll", "split"]:
        per, b, a = results[k]
        unit = "frame" if k == "idle" else ("event" if k != "typing" else "key")
        flag = ""
        if per > CEILINGS[k]:
            flag = "  ABOVE CEILING %.1f" % CEILINGS[k]
            bad.append(k)
        print("%-7s %7.2f KB/%-5s  (rss %d -> %d KB)%s" % (k, per, unit, b, a, flag))
    if check and bad:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
