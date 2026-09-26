#!/usr/bin/env python3
"""ide_driver.py - drive the real IDE headlessly, the way a person would.

Launches `build/nython --ide` against the headless SDL3 stub with a live
NY_STUB_EVENTS channel, then sends it pointer/keyboard input and reads back
what it actually drew. Every earlier round could only construct the IDE and
quit it; nothing that happens on a click or a keystroke had ever been
exercised end to end.

    from ide_driver import IDE
    with IDE() as ide:
        f = ide.snap()                      # what is on screen now
        ide.click_text("File")              # click by visible label
        ide.click_text("Save All")
        ide.key("ctrl+shift+p")
        ide.type("toggle theme\\n")
        ide.screenshot("after.png")

Locating things by their label (Frame.find) rather than by coordinates means a
test keeps working when the layout moves, and fails when the label vanishes -
which is exactly when a person could no longer find it either.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nyshot import Frame  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class DriverError(RuntimeError):
    pass


class IDE:
    def __init__(self, binary=None, args=None, cwd=None, env=None, script=None, boot_frames=12):
        self.binary = binary or os.path.join(REPO, "build", "nython")
        self.args = args if args is not None else ["--ide"]
        self.cwd = cwd or REPO
        self.extra_env = env or {}
        self.script = script
        self.boot_frames = boot_frames
        self.tmp = None
        self.proc = None
        self.last = None
        self._snap_n = 0

    # ── lifecycle ─────────────────────────────────────────────────────────
    def start(self):
        self.tmp = tempfile.mkdtemp(prefix="nyide_")
        self.events = os.path.join(self.tmp, "events.txt")
        open(self.events, "w").close()
        env = dict(os.environ)
        env.pop("NY_STUB_AUTOQUIT", None)
        env["NY_STUB_EVENTS"] = self.events
        self.state_path = os.path.join(self.tmp, "state.json")
        self.hitmap_path = os.path.join(self.tmp, "hitmap.tsv")
        env["NY_IDE_STATE"] = self.state_path
        env["NY_IDE_DUMP"] = self.hitmap_path
        env.update(self.extra_env)
        self.log_path = os.path.join(self.tmp, "ide.log")
        self._log = open(self.log_path, "w")
        cmd = [self.binary] + list(self.args)
        if self.script:
            cmd.append(self.script)
        self.proc = subprocess.Popen(cmd, cwd=self.cwd, env=env, stdin=subprocess.DEVNULL,
                                     stdout=self._log, stderr=subprocess.STDOUT)
        self.wait(self.boot_frames)
        self.snap(timeout=60)
        return self

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.close()
        return False

    def close(self, timeout=20):
        if self.proc is None:
            return None
        if self.proc.poll() is None:
            try:
                self.send("quit")
                self.proc.wait(timeout=timeout)
            except Exception:
                self.proc.kill()
                self.proc.wait()
        code = self.proc.returncode
        self._log.close()
        self.proc = None
        return code

    def log(self):
        with open(self.log_path, errors="replace") as f:
            return f.read()

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def cleanup(self):
        if self.tmp and os.path.isdir(self.tmp):
            shutil.rmtree(self.tmp, ignore_errors=True)

    # ── raw input ─────────────────────────────────────────────────────────
    def send(self, *lines):
        if self.proc is not None and self.proc.poll() is not None:
            raise DriverError("IDE exited (code %s). Log tail:\n%s"
                              % (self.proc.returncode, self.log()[-3000:]))
        with open(self.events, "a") as f:
            for ln in lines:
                f.write(ln + "\n")
            f.flush()

    def wait(self, frames=1):
        self.send("wait %d" % frames)

    def move(self, x, y):
        self.send("move %d %d" % (x, y))

    def click(self, x, y, button=1, mods=""):
        self.send(("click %d %d %d %s" % (x, y, button, mods)).strip())

    def dblclick(self, x, y):
        self.send("dblclick %d %d" % (x, y))

    def right_click(self, x, y):
        self.click(x, y, button=3)

    def drag(self, x1, y1, x2, y2):
        self.send("drag %d %d %d %d" % (x1, y1, x2, y2))

    def wheel(self, x, y, dy, mods=""):
        self.send(("wheel %d %d %d %s" % (x, y, dy, mods)).rstrip())

    def key(self, combo):
        self.send("key " + combo)

    def type(self, text):
        # One line per chunk: the stub reads line-oriented commands, and
        # newlines inside the text are escaped as \n.
        esc = text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
        self.send("type " + esc)

    def resize(self, w, h):
        self.send("resize %d %d" % (w, h))

    # ── observation ───────────────────────────────────────────────────────
    def snap(self, timeout=30, settle=3):
        """Let `settle` frames pass, then capture the last presented frame."""
        self._snap_n += 1
        path = os.path.join(self.tmp, "snap_%04d.dl" % self._snap_n)
        if settle:
            self.wait(settle)
        self.send("snap " + path)
        t0 = time.time()
        while not os.path.exists(path):
            if self.proc.poll() is not None:
                raise DriverError("IDE exited (code %s) before snapshot. Log tail:\n%s"
                                  % (self.proc.returncode, self.log()[-3000:]))
            if time.time() - t0 > timeout:
                raise DriverError("timed out waiting for snapshot %s. Log tail:\n%s"
                                  % (path, self.log()[-3000:]))
            time.sleep(0.02)
        self.last = Frame.load(path)
        return self.last

    def screenshot(self, out_png, fresh=True):
        fr = self.snap() if fresh or self.last is None else self.last
        fr.render(out_png, root=self.cwd)
        return out_png

    def _await_file(self, path, timeout):
        t0 = time.time()
        while not os.path.exists(path):
            if self.proc.poll() is not None:
                raise DriverError("IDE exited (code %s). Log tail:\n%s"
                                  % (self.proc.returncode, self.log()[-3000:]))
            if time.time() - t0 > timeout:
                raise DriverError("timed out waiting for %s. Log tail:\n%s" % (path, self.log()[-3000:]))
            time.sleep(0.02)

    def state(self, timeout=30):
        """What the IDE believes (developer.dumpState, Ctrl+Shift+Alt+J)."""
        if os.path.exists(self.state_path):
            os.remove(self.state_path)
        self.wait(2)
        self.key("ctrl+shift+alt+j")
        self._await_file(self.state_path, timeout)
        with open(self.state_path, errors="replace") as f:
            return json.load(f)

    def hitmap(self, timeout=30):
        """Every clickable region of the last frame: [(x, y, w, h, cmd, arg, tip)]."""
        if os.path.exists(self.hitmap_path):
            os.remove(self.hitmap_path)
        self.wait(2)
        self.key("ctrl+shift+alt+d")
        self._await_file(self.hitmap_path, timeout)
        time.sleep(0.05)
        out = []
        with open(self.hitmap_path, errors="replace") as f:
            for ln in f:
                p = ln.rstrip("\n").split("\t")
                if len(p) >= 5 and p[0].lstrip("-").isdigit():
                    out.append((int(p[0]), int(p[1]), int(p[2]), int(p[3]), p[4],
                                p[5] if len(p) > 5 else "", p[6] if len(p) > 6 else ""))
        return out

    # ── by-label interaction ──────────────────────────────────────────────
    def find(self, text, exact=True, region=None, nth=0, fresh=True, font=None):
        fr = self.snap() if fresh or self.last is None else self.last
        hits = fr.find(text, exact=exact, region=region, font=font)
        if len(hits) <= nth:
            raise DriverError("no on-screen text %r (exact=%s, region=%s); visible: %s"
                              % (text, exact, region, sorted(set(fr.all_text()))[:200]))
        return hits[nth]

    def click_text(self, text, exact=True, region=None, nth=0, button=1, mods="", fresh=True):
        t = self.find(text, exact=exact, region=region, nth=nth, fresh=fresh)
        self.click(int(t.cx), int(t.cy), button=button, mods=mods)
        return t

    def sees(self, text, exact=False, region=None):
        return self.snap().has(text, exact=exact, region=region)


def _demo():
    out = sys.argv[1] if len(sys.argv) > 1 else "ide.png"
    with IDE() as ide:
        ide.screenshot(out)
        print(out)


if __name__ == "__main__":
    _demo()
