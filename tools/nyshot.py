#!/usr/bin/env python3
"""nyshot.py - replay a headless SDL3-stub frame capture into a PNG.

The stub (thirdparty/sdl3-stub) records every primitive of the last
presented frame when NY_STUB_EVENTS or NY_STUB_SNAP_ON_EXIT is set, and a
`snap PATH` script command (or the snap-on-exit hook) writes it out as JSON
lines. This file turns that display list back into pixels with real fonts, so
the IDE can be *looked at* in an environment with no display at all.

    python3 tools/nyshot.py frame.dl out.png          # render
    python3 tools/nyshot.py frame.dl --texts          # list text runs

It is also imported by tools/ide_driver.py, which uses Frame.find() to locate
things on screen by their visible label instead of by hardcoded coordinates.

Rendering notes
  * Every primitive is alpha-blended (gui.cpp always sets SDL_BLENDMODE_BLEND).
  * Clip rectangles are honoured, which matters: the editor, tree and panels
    all rely on clipping to hide overflow.
  * The stub measures text as 0.6em per character. DejaVu Sans Mono's real
    advance is 0.602em, so code text lands where the IDE thinks it does;
    proportional UI text can be a few pixels off its measured box.
"""
import json
import os
import sys

FONT_DIRS = ["/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/TTF",
             "/usr/share/fonts/dejavu", "/Library/Fonts", "C:/Windows/Fonts"]


class Text:
    __slots__ = ("text", "x", "y", "w", "h", "color", "font", "size", "style")

    def __init__(self, d):
        self.text = d["text"]
        self.x, self.y, self.w, self.h = d["x"], d["y"], d["w"], d["h"]
        self.color = tuple(d["c"])
        self.font = d["font"]
        self.size = d["size"]
        self.style = d["style"]

    @property
    def cx(self):
        return self.x + self.w / 2.0

    @property
    def cy(self):
        return self.y + self.h / 2.0

    def __repr__(self):
        return "Text(%r @ %d,%d %dx%d)" % (self.text, self.x, self.y, self.w, self.h)


class Frame:
    """One presented frame: the ordered display list plus a text index."""

    def __init__(self, ops, w, h, n):
        self.ops = ops
        self.w, self.h, self.n = w, h, n
        self.texts = [Text(o) for o in ops if o["op"] == "text"]

    @classmethod
    def load(cls, path):
        ops = []
        w = h = n = 0
        with open(path, "rb") as f:
            for raw in f:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                o = json.loads(line)
                if o["op"] == "frame":
                    w, h, n = o["w"], o["h"], o["n"]
                else:
                    ops.append(o)
        return cls(ops, w, h, n)

    # ── querying ──────────────────────────────────────────────────────────
    def find(self, text, exact=True, region=None, font=None):
        """Text runs matching `text`, in draw order. region = (x, y, w, h)."""
        out = []
        for t in self.texts:
            ok = (t.text == text) if exact else (text in t.text)
            if not ok:
                continue
            if font is not None and font not in t.font:
                continue
            if region is not None:
                rx, ry, rw, rh = region
                if not (rx <= t.cx < rx + rw and ry <= t.cy < ry + rh):
                    continue
            out.append(t)
        return out

    def has(self, text, exact=False, region=None):
        return len(self.find(text, exact=exact, region=region)) > 0

    def all_text(self, region=None):
        return [t.text for t in self.texts
                if region is None or (region[0] <= t.cx < region[0] + region[2]
                                      and region[1] <= t.cy < region[1] + region[3])]

    def fills_at(self, x, y):
        """Colours of every fill covering (x, y), in paint order."""
        out = []
        for o in self.ops:
            if o["op"] == "fill":
                ax, ay, aw, ah = o["a"]
                if ax <= x < ax + aw and ay <= y < ay + ah:
                    out.append(tuple(o["c"]))
        return out

    # ── rendering ─────────────────────────────────────────────────────────
    def render(self, out_path, root=".", scale=1):
        from PIL import Image, ImageDraw
        img = Image.new("RGBA", (max(1, self.w), max(1, self.h)), (0, 0, 0, 255))
        fonts = _FontCache(root)
        clip = None
        for o in self.ops:
            op = o["op"]
            if op == "clip":
                clip = (o["x"], o["y"], o["x"] + o["w"], o["y"] + o["h"])
                continue
            if op == "unclip":
                clip = None
                continue
            if op == "text":
                _draw_text(img, o, fonts, clip)
                continue
            a = o["a"]
            col = tuple(o["c"])
            if op in ("fill", "clear"):
                box = (a[0], a[1], a[0] + a[2], a[1] + a[3])
                if op == "clear":
                    box = (0, 0, self.w, self.h)
                _fill(img, _isect(box, clip if op == "fill" else None), col)
            elif op == "rect":
                x0, y0, x1, y1 = a[0], a[1], a[0] + a[2] - 1, a[1] + a[3] - 1
                for seg in ((x0, y0, x1, y0), (x0, y1, x1, y1), (x0, y0, x0, y1), (x1, y0, x1, y1)):
                    _line(img, seg, col, clip)
            elif op == "line":
                _line(img, a, col, clip)
            elif op == "point":
                _fill(img, _isect((a[0], a[1], a[0] + 1, a[1] + 1), clip), col)
        img = img.convert("RGB")
        if scale != 1:
            img = img.resize((int(self.w * scale), int(self.h * scale)), Image.LANCZOS)
        img.save(out_path)
        return out_path


def _isect(box, clip):
    x0, y0, x1, y1 = box
    if clip is not None:
        x0, y0 = max(x0, clip[0]), max(y0, clip[1])
        x1, y1 = min(x1, clip[2]), min(y1, clip[3])
    if x1 <= x0 or y1 <= y0:
        return None
    return (int(round(x0)), int(round(y0)), int(round(x1)), int(round(y1)))


def _fill(img, box, col):
    if box is None:
        return
    from PIL import Image
    x0, y0, x1, y1 = box
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(img.width, x1), min(img.height, y1)
    if x1 <= x0 or y1 <= y0:
        return
    if col[3] >= 255:
        img.paste(col, (x0, y0, x1, y1))
        return
    if col[3] <= 0:
        return
    patch = img.crop((x0, y0, x1, y1))
    layer = Image.new("RGBA", patch.size, col)
    img.paste(Image.alpha_composite(patch, layer), (x0, y0))


def _line(img, seg, col, clip):
    from PIL import Image, ImageDraw
    x1, y1, x2, y2 = seg
    # Axis-aligned lines (the vast majority: gradients, circle/rounded-rect
    # scanlines) are exact 1px rectangles.
    if y1 == y2:
        _fill(img, _isect((min(x1, x2), y1, max(x1, x2) + 1, y1 + 1), clip), col)
        return
    if x1 == x2:
        _fill(img, _isect((x1, min(y1, y2), x1 + 1, max(y1, y2) + 1), clip), col)
        return
    box = _isect((min(x1, x2), min(y1, y2), max(x1, x2) + 1, max(y1, y2) + 1), clip)
    if box is None:
        return
    bx0, by0, bx1, by1 = box
    layer = Image.new("RGBA", (bx1 - bx0, by1 - by0), (0, 0, 0, 0))
    ImageDraw.Draw(layer).line((x1 - bx0, y1 - by0, x2 - bx0, y2 - by0), fill=col, width=1)
    region = img.crop(box)
    img.paste(Image.alpha_composite(region, layer), (bx0, by0))


class _FontCache:
    def __init__(self, root):
        self.root = root
        self.cache = {}

    def _find(self, name):
        for d in FONT_DIRS:
            p = os.path.join(d, name)
            if os.path.exists(p):
                return p
        return None

    def get(self, family, size, style):
        from PIL import ImageFont
        key = (family, size, style)
        if key in self.cache:
            return self.cache[key]
        bold = bool(style & 1)
        path = None
        low = family.lower()
        if low.endswith((".ttf", ".otf", ".ttc")):
            cand = family if os.path.isabs(family) else os.path.join(self.root, family)
            if os.path.exists(cand):
                path = cand
        if path is None:
            if low in ("monospace", "mono", "consolas") or "mono" in low:
                path = self._find("DejaVuSansMono-Bold.ttf" if bold else "DejaVuSansMono.ttf")
            else:
                path = self._find("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf")
        try:
            font = ImageFont.truetype(path, max(1, int(round(size)))) if path else ImageFont.load_default()
        except Exception:
            font = ImageFont.load_default()
        self.cache[key] = font
        return font


def _draw_text(img, o, fonts, clip):
    from PIL import Image, ImageDraw
    col = tuple(o["c"])
    if col[3] <= 0:
        return
    font = fonts.get(o["font"], o["size"], o["style"])
    x, y = o["x"], o["y"]
    try:
        l, t, r, b = font.getbbox(o["text"])
    except Exception:
        return
    w = max(int(o["w"]), r) + 4
    h = max(int(o["h"]), b) + 4
    box = _isect((x, y, x + w, y + h), clip)
    if box is None:
        return
    bx0, by0, bx1, by1 = box
    bx0, by0 = max(0, bx0), max(0, by0)
    bx1, by1 = min(img.width, bx1), min(img.height, by1)
    if bx1 <= bx0 or by1 <= by0:
        return
    layer = Image.new("RGBA", (bx1 - bx0, by1 - by0), (0, 0, 0, 0))
    ImageDraw.Draw(layer).text((x - bx0, y - by0), o["text"], font=font, fill=col)
    region = img.crop((bx0, by0, bx1, by1))
    img.paste(Image.alpha_composite(region, layer), (bx0, by0))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    fr = Frame.load(argv[1])
    if "--texts" in argv:
        for t in fr.texts:
            print("%5d %5d %4d %3d  %-10s %s" % (t.x, t.y, t.w, t.h, os.path.basename(t.font)[:10], t.text))
        return 0
    out = argv[2] if len(argv) > 2 else os.path.splitext(argv[1])[0] + ".png"
    root = "."
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    fr.render(out, root=root)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
