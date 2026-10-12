#!/usr/bin/env python3
"""ide_memprobe.py - how much memory the IDE keeps per frame and per action.

Since round 75 the interpreter reclaims garbage (GC_NOTES.md), so what this
measures is memory the IDE really keeps - a cache that grows, a history, a
leak through a native table - rather than the garbage it makes. It drives
the real IDE headlessly and reports the resident-set growth for:

    idle     frames with nothing happening (repaint + watcher + timers)
    hover    the pointer moving over the workbench (hover, tooltips)
    typing   characters typed into an editor
    scroll   wheel scrolling through a long file
    split    hover with two editor groups (beyond plain hover)
    live     hover while a live debug session is paused: the Variables
             tree, stack and toolbar repainted (beyond plain hover; round 81)
    profile  hover over the PROFILE panel: table and flame graph (round 81)
    agent    hover while the AGENT view shows an answer (beyond plain hover;
             round 82)
    agentkey typing once the agent's completion model re-ranks the list
             (round 82)

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
CEILINGS = {"idle": 0.5, "hover": 2.0, "typing": 50.0, "scroll": 12.0, "split": 2.0, "live": 2.0, "profile": 2.0,
            "agent": 2.0, "agentkey": 50.0}


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
    with open(os.path.join(ws, "live.ny"), "w") as f:
        f.write("def fib(n):\n    if n < 2:\n        return n\n    return fib(n - 1) + fib(n - 2)\n\n"
                "data = [1, 2, 3]\nfor k in range(3):\n    print(fib(8 + k), data)\n")
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
        ide.key("ctrl+\\")
        settle(ide)

        def wait_state(pred, timeout=40):
            t0 = time.time()
            st = ide.state()
            while not pred(st) and time.time() - t0 < timeout:
                ide.wait(4)
                st = ide.state()
            return st

        # live debugging, paused at a breakpoint (round 81)
        ide.key("ctrl+p")
        ide.type("live.ny")
        ide.key("enter")
        settle(ide)
        base = measure(ide, hover, 150, 60)
        ide.key("ctrl+g")
        ide.type("8\n")
        ide.key("f9")
        ide.key("alt+f5")
        wait_state(lambda st: st.get("live_state") == "paused" and len(st.get("live_vars", [])) > 2)
        lv = measure(ide, hover, 150, 60)
        results["live"] = (lv[0] - base[0], lv[1], lv[2])
        ide.key("shift+f5")
        wait_state(lambda st: not st.get("live_active"))
        ide.key("f9")
        # the Profile view
        ide.key("ctrl+shift+p")
        ide.type("Profile with cProfile")
        ide.key("enter")
        wait_state(lambda st: st.get("prof_n", 0) > 0 and st.get("panel") == "profile")
        settle(ide)
        results["profile"] = measure(ide, hover, 150, 60)
        # the AGENT view with an answer (round 82)
        t = ide.find("app.ny")
        ide.dblclick(int(t.cx), int(t.cy))
        settle(ide)
        base = measure(ide, hover, 150, 60)
        ide.key("ctrl+shift+p")
        ide.type("Agent: Ask")
        ide.key("enter")
        ide.type("where is greet\n")
        wait_state(lambda st: st.get("agent_count", 0) >= 1 and st.get("view") == "ai", 120)
        settle(ide)
        ag = measure(ide, hover, 150, 60)
        results["agent"] = (ag[0] - base[0], ag[1], ag[2])
        # typing with the completion list re-ranked by the agent's model
        t = ide.find("app.ny", region=(0, 0, 400, 900))
        ide.dblclick(int(t.cx), int(t.cy))
        settle(ide)

        def typing2(n):
            ide.key("ctrl+end")
            for i in range(n):
                ide.type("g" if i % 8 else "\n")
        results["agentkey"] = measure(ide, typing2, 150, 40)
    finally:
        ide.close()
        ide.cleanup()
        shutil.rmtree(root, ignore_errors=True)
    bad = []
    for k in ["idle", "hover", "typing", "scroll", "split", "live", "profile", "agent", "agentkey"]:
        per, b, a = results[k]
        unit = "frame" if k == "idle" else ("event" if k not in ("typing", "agentkey") else "key")
        flag = ""
        if per > CEILINGS[k]:
            flag = "  ABOVE CEILING %.1f" % CEILINGS[k]
            bad.append(k)
        print("%-8s %7.2f KB/%-5s  (rss %d -> %d KB)%s" % (k, per, unit, b, a, flag))
    if check and bad:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
