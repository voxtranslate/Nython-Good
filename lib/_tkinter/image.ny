# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/image.ny - Tk's images (round 84), after tkImage.c,
# tkImgPhoto.c, tkImgBmap.c and the format handlers tkImgPNG.c, tkImgGIF.c
# and tkImgPPM.c.
#
# image       create photo|bitmap ?name? ?options?, delete, height, width,
#             inuse, names, type, types (Tk's messages)
# photo       -data -format -file -gamma -height -width -palette; the
#             instance command: blank, cget, configure, copy (-from -to
#             -shrink -zoom -subsample -compositingrule, Tk's tiling and
#             mirroring), data (-format -from -background -grayscale), get,
#             put (colour lists or formatted data, -to with tiling), read
#             (-format -from -shrink -to), redither, transparency get/set,
#             write (-format -from -background -grayscale). Pixels are
#             32-bit RGBA with Tk's "overlay" alpha compositing.
# formats     png (every colour type and bit depth, tRNS, Adam7 interlace;
#             written as 8-bit RGB or RGBA), gif (87a/89a, transparency,
#             interlace, `-format {gif -index n}` for a frame; written with
#             the image's own colours, at most 256 - more are reduced to a
#             3-3-2 palette, which Tk would refuse), ppm/pgm (P5/P6, any
#             maxval; written as P6 with Tk's header), and the default
#             format (a list of rows of colours). -data takes binary data or
#             base64 text, as Tk does.
# bitmap      -data -file (XBM) -maskdata -maskfile -foreground -background
# builtin     error gray75 gray50 gray25 gray12 hourglass info questhead
# bitmaps     question warning, at Tk's sizes; the gray stipples, error, info
#             and warning are Tk's bits, hourglass/question/questhead are
#             redrawn (their bits were not available), and "@file" reads an
#             XBM file.
#
# Not provided: -gamma and -palette are kept but do not change the pixels
# shown (a true-colour display is assumed, as on every modern X server);
# `redither` does nothing for the same reason; no SVG (Tk 8.7's), no
# `-metadata`, no `photo get -withalpha` (8.7).
#
# Drawing: a photo is turned into a backend texture (written as a PNG and
# read with gui_load_image) only when it is drawn and has changed since;
# each frame also records {"op": "image", "name", "a": [x, y, w, h]} for
# the test harness (tkinter's Misc._ny_snapshot()).

import os
import zlib
import base64
from _tkinter.tcl import (TclError, tcl_str, tcl_float, split_list, join_list, quote_elem, get_int, get_double,
                          get_boolean, match_prefix, or_list)
from _tkinter.util import parse_color

_IMAGE_SUBS = ["create", "delete", "height", "inuse", "names", "type", "types", "width"]
_PHOTO_SUBS = ["blank", "cget", "configure", "copy", "data", "get", "put", "read", "redither", "transparency",
               "write"]
_PHOTO_OPTS = ["-data", "-format", "-file", "-gamma", "-height", "-palette", "-width"]
_BITMAP_OPTS = ["-background", "-data", "-file", "-foreground", "-maskdata", "-maskfile"]

_TMP_SEQ = [0]


def _blob(v):
    # a Tcl value as bytes (byte arrays stay binary, strings go as latin-1)
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    s = tcl_str(v)
    try:
        return s.encode("latin-1")
    except UnicodeError:
        return s.encode("utf-8")


# ── pixel blocks ──────────────────────────────────────────────────────────
class Block:
    # w x h pixels, 4 bytes each (r, g, b, a), rows top to bottom
    def __init__(self, w, h, pix=None):
        self.w = w
        self.h = h
        self.pix = pix if pix is not None else bytearray(w * h * 4)


def _region(block, x1, y1, x2, y2):
    out = bytearray()
    for y in range(y1, y2):
        base = (y * block.w) * 4
        out.extend(block.pix[base + x1 * 4: base + x2 * 4])
    return Block(x2 - x1, y2 - y1, out)


class Photo:
    TYPE = "photo"

    def __init__(self, app, name):
        self.app = app
        self.name = name
        self.users = set()
        self.w = 0
        self.h = 0
        self.uw = 0
        self.uh = 0
        self.pix = bytearray()
        self.opts = {"-data": "", "-format": "", "-file": "", "-gamma": 1.0, "-height": 0, "-palette": "",
                     "-width": 0}
        self.version = 0
        self.tex = None
        self.tex_version = -1

    def width(self):
        return self.w

    def height(self):
        return self.h

    # ── storage ──
    def set_size(self, w, h):
        # ImgPhotoSetSize: a -width/-height given by the user wins
        if self.uw > 0:
            w = self.uw
        if self.uh > 0:
            h = self.uh
        if w == self.w and h == self.h:
            return
        new = bytearray(w * h * 4)
        cw = min(w, self.w)
        for y in range(min(h, self.h)):
            new[y * w * 4: y * w * 4 + cw * 4] = self.pix[y * self.w * 4: y * self.w * 4 + cw * 4]
        self.pix = new
        self.w = w
        self.h = h

    def changed(self):
        self.version += 1
        self.app.image_changed(self)

    def blank(self):
        self.pix = bytearray(self.w * self.h * 4)
        self.changed()

    def put_block(self, block, x, y, width, height, zx=1, zy=1, sx=1, sy=1, rule="overlay"):
        # Tk_PhotoPutZoomedBlock: the (subsampled, zoomed) block is tiled
        # over the region; the image grows unless the user fixed its size
        if width <= 0 or height <= 0 or block.w <= 0 or block.h <= 0:
            return
        if self.uw != 0 and x + width > self.uw:
            width = self.uw - x
        if self.uh != 0 and y + height > self.uh:
            height = self.uh - y
        if width <= 0 or height <= 0:
            return
        if x + width > self.w or y + height > self.h:
            self.set_size(max(x + width, self.w), max(y + height, self.h))
        if x + width > self.w:
            width = self.w - x
        if y + height > self.h:
            height = self.h - y
        if width <= 0 or height <= 0:
            return
        if sx > 0:
            bw = ((block.w + sx - 1) // sx) * zx
        else:
            bw = ((block.w - sx - 1) // -sx) * zx
        if sy > 0:
            bh = ((block.h + sy - 1) // sy) * zy
        else:
            bh = ((block.h - sy - 1) // -sy) * zy
        if bw <= 0 or bh <= 0:
            return
        x0 = 0 if sx > 0 else block.w - 1
        y0 = 0 if sy > 0 else block.h - 1
        # the source column for each destination column, once
        cols = []
        for i in range(width):
            t = i % bw
            cols.append(x0 + (t // zx) * sx)
        src = block.pix
        dst = self.pix
        sw = block.w
        simple = zx == 1 and sx == 1 and width <= bw and rule == "set"
        for j in range(height):
            t = j % bh
            sr = y0 + (t // zy) * sy
            drow = ((y + j) * self.w + x) * 4
            srow = sr * sw * 4
            if simple:
                dst[drow:drow + width * 4] = src[srow:srow + width * 4]
                continue
            for i in range(width):
                s = srow + cols[i] * 4
                d = drow + i * 4
                a = src[s + 3]
                if rule == "set" or a == 255 or dst[d + 3] == 0:
                    dst[d] = src[s]
                    dst[d + 1] = src[s + 1]
                    dst[d + 2] = src[s + 2]
                    dst[d + 3] = a
                elif a != 0:
                    da = dst[d + 3]
                    # PD_SRC_OVER (tkImgPhoto.c)
                    for k in range(3):
                        dst[d + k] = (src[s + k] * a) // 255 + (((da * (255 - a)) // 255) * dst[d + k]) // 255
                    dst[d + 3] = a + ((255 - a) * da) // 255

    def block(self, x1=0, y1=0, x2=None, y2=None):
        if x2 is None:
            x2 = self.w
        if y2 is None:
            y2 = self.h
        b = Block(self.w, self.h, self.pix)
        if x1 == 0 and y1 == 0 and x2 == self.w and y2 == self.h:
            return Block(self.w, self.h, bytearray(self.pix))
        return _region(b, x1, y1, x2, y2)

    # ── drawing ──
    def texture(self):
        if self.tex_version == self.version:
            return self.tex
        if self.tex is not None:
            try:
                gui_free_image(self.tex)
            except Exception:
                pass
            self.tex = None
        self.tex_version = self.version
        if self.w == 0 or self.h == 0:
            return None
        _TMP_SEQ[0] += 1
        tmpdir = os.environ.get("TMPDIR", "/tmp")
        if not os.path.isdir(tmpdir):
            tmpdir = "."
        path = os.path.join(tmpdir, "nytk_" + str(os.getpid()) + "_" + str(_TMP_SEQ[0]) + ".png")
        try:
            with open(path, "wb") as f:
                f.write(encode_png(self.block()))
            h = gui_load_image(path)
            self.tex = h
        except Exception:
            self.tex = None
        try:
            os.remove(path)
        except OSError:
            pass
        return self.tex

    def draw(self, h, x, y, w, hh):
        if self.w <= 0 or self.h <= 0:
            return
        self.app.frame_images.append({"op": "image", "name": self.name, "a": [x, y, self.w, self.h]})
        t = self.texture()
        if t is not None:
            gui_draw_image(h, t, x, y, self.w, self.h)

    # ── configuration ──
    def configure(self, args, creating=False):
        if len(args) % 2 == 1:
            o = match_prefix(tcl_str(args[-1]), _PHOTO_OPTS, "option")
            if len(args) == 1 and not creating:
                return self.config_entry(o)
            raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
        new = {}
        for i in range(0, len(args), 2):
            o = match_prefix(tcl_str(args[i]), _PHOTO_OPTS, "option")
            new[o] = args[i + 1]
        if "-gamma" in new:
            g = get_double(new["-gamma"])
            new["-gamma"] = g
        for o in ("-width", "-height"):
            if o in new:
                new[o] = get_int(new[o])
                if new[o] < 0:
                    raise TclError("negative value \"" + str(new[o]) + "\" for " + o[1:])
        if "-palette" in new:
            new["-palette"] = tcl_str(new["-palette"])
        if "-format" in new:
            new["-format"] = tcl_str(new["-format"]) if not isinstance(new["-format"], (tuple, list)) else join_list(new["-format"])
        if "-file" in new:
            new["-file"] = tcl_str(new["-file"])
        old_file = self.opts["-file"]
        old_data = self.opts["-data"]
        self.opts.update(new)
        if "-width" in new or "-height" in new:
            self.uw = self.opts["-width"]
            self.uh = self.opts["-height"]
            self.set_size(self.w, self.h)
        fmt = self.opts["-format"]
        if "-file" in new and self.opts["-file"] != "":
            blk = read_file(self.opts["-file"], fmt)
            self.pix = bytearray(self.w * self.h * 4)
            self.set_size(blk.w, blk.h)
            self.put_block(blk, 0, 0, blk.w, blk.h, rule="set")
            self.opts["-data"] = ""
        elif "-data" in new and _blob(self.opts["-data"]) != b"":
            blk = read_data(self.opts["-data"], fmt)
            self.pix = bytearray(self.w * self.h * 4)
            self.set_size(blk.w, blk.h)
            self.put_block(blk, 0, 0, blk.w, blk.h, rule="set")
        self.changed()
        return ""

    def config_value(self, o):
        v = self.opts[o]
        if o == "-gamma":
            return tcl_float(v)
        if o in ("-width", "-height"):
            return str(v)
        return v

    def config_entry(self, o):
        defaults = {"-data": "", "-format": "", "-file": "", "-gamma": "1", "-height": "0", "-palette": "",
                    "-width": "0"}
        return (o, "", "", defaults[o], self.config_value(o))

    # ── the instance command ──
    def command(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.name + " option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), _PHOTO_SUBS, "option")
        rest = args[1:]
        if sub == "blank":
            if rest:
                raise TclError("wrong # args: should be \"" + self.name + " blank\"")
            self.blank()
            return ""
        if sub == "cget":
            if len(rest) != 1:
                raise TclError("wrong # args: should be \"" + self.name + " cget option\"")
            o = match_prefix(tcl_str(rest[0]), _PHOTO_OPTS, "option")
            return self.config_value(o)
        if sub == "configure":
            if not rest:
                return tuple(self.config_entry(o) for o in _PHOTO_OPTS)
            return self.configure(rest)
        if sub == "copy":
            return self.cmd_copy(rest)
        if sub == "data":
            return self.cmd_data(rest)
        if sub == "get":
            if len(rest) != 2:
                raise TclError("wrong # args: should be \"" + self.name + " get x y\"")
            x = get_int(rest[0])
            y = get_int(rest[1])
            if x < 0 or x >= self.w or y < 0 or y >= self.h:
                raise TclError(self.name + " get: coordinates out of range")
            p = (y * self.w + x) * 4
            return (self.pix[p], self.pix[p + 1], self.pix[p + 2])
        if sub == "put":
            return self.cmd_put(rest)
        if sub == "read":
            return self.cmd_read(rest)
        if sub == "redither":
            return ""
        if sub == "transparency":
            return self.cmd_transparency(rest)
        if sub == "write":
            return self.cmd_write(rest)
        return ""

    def parse_opts(self, args, allowed, start=0):
        # ParseSubcommandOptions: -from/-to take 2 or 4 integers, -zoom and
        # -subsample 1 or 2, -format/-background one value
        res = {}
        i = start
        while i < len(args):
            a = tcl_str(args[i])
            if not a.startswith("-"):
                break
            opt = None
            for o in allowed:
                if o.startswith(a) and len(a) > 1:
                    if opt is not None and opt != o:
                        opt = "ambiguous"
                        break
                    opt = o
            if opt is None or opt == "ambiguous":
                raise TclError("unrecognized option \"" + a + "\": must be " + or_list(allowed))
            i += 1
            if opt in ("-from", "-to"):
                vals = []
                while i < len(args) and len(vals) < 4:
                    try:
                        vals.append(get_int(args[i]))
                    except TclError:
                        break
                    i += 1
                if len(vals) not in (2, 4) and not (opt == "-to" and len(vals) == 2):
                    if not vals:
                        raise TclError("the \"" + opt + "\" option requires one to four integer values")
                    raise TclError("wrong # arguments to \"" + opt + "\"")
                for v in vals:
                    if v < 0:
                        raise TclError("value(s) for the " + opt + " option must be non-negative")
                res[opt] = vals
            elif opt in ("-zoom", "-subsample"):
                vals = []
                while i < len(args) and len(vals) < 2:
                    try:
                        vals.append(get_int(args[i]))
                    except TclError:
                        break
                    i += 1
                if not vals:
                    raise TclError("the \"" + opt + "\" option requires one or two integer values")
                if len(vals) == 1:
                    vals.append(vals[0])
                if opt == "-zoom" and (vals[0] <= 0 or vals[1] <= 0):
                    raise TclError("value(s) for the -zoom option must be positive")
                res[opt] = vals
            elif opt in ("-shrink", "-grayscale"):
                res[opt] = True
            else:
                if i >= len(args):
                    raise TclError("the \"" + opt + "\" option requires a value")
                v = args[i]
                res[opt] = join_list(v) if isinstance(v, (tuple, list)) else tcl_str(v)
                i += 1
        return res, i

    def _from(self, src_w, src_h, vals):
        if not vals:
            return 0, 0, src_w, src_h
        x1, y1 = vals[0], vals[1]
        if len(vals) == 4:
            x2, y2 = vals[2], vals[3]
            if x2 < x1:
                x1, x2 = x2, x1
            if y2 < y1:
                y1, y2 = y2, y1
        else:
            x2, y2 = src_w, src_h
        return x1, y1, x2, y2

    def cmd_copy(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.name + " copy source-image ?-compositingrule rule? ?-from x1 y1 x2 y2? ?-to x1 y1 x2 y2? ?-zoom x y? ?-subsample x y?\"")
        sname = tcl_str(args[0])
        src = self.app.images.get(sname)
        if src is None or src.TYPE != "photo":
            raise TclError("image \"" + sname + "\" doesn't exist or is not a photo image")
        o, i = self.parse_opts(args, ["-compositingrule", "-from", "-shrink", "-subsample", "-to", "-zoom"], 1)
        if i < len(args):
            raise TclError("unrecognized option \"" + tcl_str(args[i]) + "\": must be -compositingrule, -from, -shrink, -subsample, -to, or -zoom")
        rule = o.get("-compositingrule", "overlay")
        rule = match_prefix(rule, ["overlay", "set"], "compositing rule")
        fx1, fy1, fx2, fy2 = self._from(src.w, src.h, o.get("-from"))
        if fx2 > src.w or fy2 > src.h:
            raise TclError("coordinates for -from option extend outside source image")
        zx, zy = o.get("-zoom", [1, 1])
        sx, sy = o.get("-subsample", [1, 1])
        if sx == 0 or sy == 0:
            return ""
        to = o.get("-to")
        tx = to[0] if to else 0
        ty = to[1] if to else 0
        if to and len(to) == 4:
            tx2, ty2 = to[2], to[3]
            if tx2 < tx:
                tx, tx2 = tx2, tx
            if ty2 < ty:
                ty, ty2 = ty2, ty
        else:
            w = fx2 - fx1
            h = fy2 - fy1
            w = (w + sx - 1) // sx if sx > 0 else (w - sx - 1) // -sx
            h = (h + sy - 1) // sy if sy > 0 else (h - sy - 1) // -sy
            tx2 = tx + w * zx
            ty2 = ty + h * zy
        blk = src.block(fx1, fy1, fx2, fy2)
        if o.get("-shrink"):
            uw, uh = self.uw, self.uh
            self.uw = self.uh = 0
            self.set_size(tx2, ty2)
            self.uw, self.uh = uw, uh
        self.put_block(blk, tx, ty, tx2 - tx, ty2 - ty, zx, zy, sx, sy, rule)
        self.changed()
        return ""

    def cmd_put(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.name + " put data ?-option value ...?\"")
        o, i = self.parse_opts(args, ["-format", "-to"], 1)
        if i < len(args):
            raise TclError("unrecognized option \"" + tcl_str(args[i]) + "\": must be -format, or -to")
        data = args[0]
        fmt = o.get("-format", "")
        # Tk tries the format handlers first, then a list of colours
        if fmt.lower().startswith("default"):
            blk = _try_color_list(data, True)
        elif fmt != "":
            blk = read_data(data, fmt)
        else:
            found = _sniff_data(data, None)
            if found is not None:
                blk = _decode(found[0], found[1], "")
            else:
                blk = _try_color_list(data, True)
        to = o.get("-to")
        tx = to[0] if to else 0
        ty = to[1] if to else 0
        if to and len(to) == 4:
            tx2, ty2 = to[2], to[3]
            if tx2 < tx:
                tx, tx2 = tx2, tx
            if ty2 < ty:
                ty, ty2 = ty2, ty
        else:
            tx2 = tx + blk.w
            ty2 = ty + blk.h
        self.put_block(blk, tx, ty, tx2 - tx, ty2 - ty, rule="set")
        self.changed()
        return ""

    def cmd_read(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.name + " read fileName ?-option value ...?\"")
        o, i = self.parse_opts(args, ["-format", "-from", "-shrink", "-to"], 1)
        if i < len(args):
            raise TclError("unrecognized option \"" + tcl_str(args[i]) + "\": must be -format, -from, -shrink, or -to")
        blk = read_file(tcl_str(args[0]), o.get("-format", ""))
        fx1, fy1, fx2, fy2 = self._from(blk.w, blk.h, o.get("-from"))
        if fx2 > blk.w or fy2 > blk.h:
            raise TclError("coordinates for -from option extend outside source image")
        if (fx1, fy1, fx2, fy2) != (0, 0, blk.w, blk.h):
            blk = _region(blk, fx1, fy1, fx2, fy2)
        to = o.get("-to")
        tx = to[0] if to else 0
        ty = to[1] if to else 0
        if o.get("-shrink"):
            self.set_size(tx + blk.w, ty + blk.h)
        self.put_block(blk, tx, ty, blk.w, blk.h, rule="set")
        self.changed()
        return ""

    def cmd_transparency(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.name + " transparency option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["get", "set"], "option")
        if sub == "get":
            if len(args) != 3:
                raise TclError("wrong # args: should be \"" + self.name + " transparency get x y\"")
            x = get_int(args[1])
            y = get_int(args[2])
            if x < 0 or x >= self.w or y < 0 or y >= self.h:
                raise TclError(self.name + " transparency get: coordinates out of range")
            return 1 if self.pix[(y * self.w + x) * 4 + 3] == 0 else 0
        if len(args) != 4:
            raise TclError("wrong # args: should be \"" + self.name + " transparency set x y boolean\"")
        x = get_int(args[1])
        y = get_int(args[2])
        t = get_boolean(args[3])
        if x < 0 or x >= self.w or y < 0 or y >= self.h:
            raise TclError(self.name + " transparency set: coordinates out of range")
        self.pix[(y * self.w + x) * 4 + 3] = 0 if t else 255
        self.changed()
        return ""

    def _out_block(self, o):
        fx1, fy1, fx2, fy2 = self._from(self.w, self.h, o.get("-from"))
        if fx2 > self.w or fy2 > self.h:
            raise TclError("coordinates for -from option extend outside image")
        blk = self.block(fx1, fy1, fx2, fy2)
        bg = o.get("-background")
        gray = o.get("-grayscale", False)
        if bg is not None or gray:
            bgc = parse_color(bg) if bg else None
            p = blk.pix
            for k in range(0, len(p), 4):
                if bgc is not None:
                    a = p[k + 3]
                    if a != 255:
                        for c in range(3):
                            b = (bgc >> (16 - 8 * c)) & 255
                            p[k + c] = (p[k + c] * a + b * (255 - a)) // 255
                        p[k + 3] = 255
                if gray:
                    g = (p[k] * 11 + p[k + 1] * 16 + p[k + 2] * 5) // 32
                    p[k] = p[k + 1] = p[k + 2] = g
        return blk

    def cmd_data(self, args):
        o, i = self.parse_opts(args, ["-background", "-format", "-from", "-grayscale"], 0)
        if i < len(args):
            raise TclError("unrecognized option \"" + tcl_str(args[i]) + "\": must be -background, -format, -from, or -grayscale")
        blk = self._out_block(o)
        fmt = o.get("-format", "")
        if fmt == "" or fmt.lower().startswith("default"):
            rows = []
            p = blk.pix
            for y in range(blk.h):
                row = []
                for x in range(blk.w):
                    k = (y * blk.w + x) * 4
                    row.append("#%02x%02x%02x" % (p[k], p[k + 1], p[k + 2]))
                rows.append(" ".join(row))
            return join_list(rows)
        name = _format_name(fmt, "data")
        if name == "png":
            return encode_png(blk)
        if name == "gif":
            return base64.b64encode(encode_gif(blk)).decode("ascii")
        return encode_ppm(blk)

    def cmd_write(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.name + " write fileName ?-option value ...?\"")
        o, i = self.parse_opts(args, ["-background", "-format", "-from", "-grayscale"], 1)
        if i < len(args):
            raise TclError("unrecognized option \"" + tcl_str(args[i]) + "\": must be -background, -format, -from, or -grayscale")
        blk = self._out_block(o)
        fmt = o.get("-format", "")
        name = _format_name(fmt, "file") if fmt else "ppm"
        if name == "png":
            data = encode_png(blk)
        elif name == "gif":
            data = encode_gif(blk)
        else:
            data = encode_ppm(blk)
        fn = tcl_str(args[0])
        try:
            with open(fn, "wb") as f:
                f.write(data)
        except OSError as e:
            raise TclError("couldn't open \"" + fn + "\": " + _os_reason(e))
        return ""

    def delete(self):
        if self.tex is not None:
            try:
                gui_free_image(self.tex)
            except Exception:
                pass
            self.tex = None


def _os_reason(e):
    s = getattr(e, "strerror", None) or str(e)
    return s.lower() if s else "error"


def _format_name(fmt, what):
    f = fmt.lower()
    for n in ("png", "gif", "ppm", "pgm"):
        if f.startswith(n):
            return "ppm" if n == "pgm" else n
    if what == "file":
        raise TclError("image file format \"" + fmt + "\" is not supported")
    raise TclError("image format \"" + fmt + "\" is not supported")


def _format_opts(fmt):
    words = split_list(fmt) if fmt else []
    res = {}
    i = 1
    while i + 1 < len(words):
        res[words[i]] = words[i + 1]
        i += 2
    return res


def _try_color_list(data, required):
    # the default format: a list of rows, each a list of colours
    if isinstance(data, (bytes, bytearray)):
        if required:
            raise TclError("couldn't recognize image data")
        return None
    try:
        rows = split_list(data) if not isinstance(data, (tuple, list)) else list(data)
    except TclError:
        if required:
            raise
        return None
    if not rows:
        return Block(0, 0)
    if len(rows) == 1 and not required:
        try:
            one = split_list(rows[0]) if not isinstance(rows[0], (tuple, list)) else rows[0]
        except TclError:
            return None
        if len(one) == 1:
            try:
                parse_color(tcl_str(one[0]))
            except TclError:
                return None
    parsed = []
    width = None
    for r in rows:
        try:
            cols = split_list(r) if not isinstance(r, (tuple, list)) else list(r)
        except TclError:
            if required:
                raise
            return None
        if width is None:
            width = len(cols)
        elif len(cols) != width:
            raise TclError("all elements of color list must have the same number of elements")
        parsed.append(cols)
    blk = Block(width, len(parsed))
    p = blk.pix
    k = 0
    cache = {}
    for cols in parsed:
        for c in cols:
            c = tcl_str(c)
            v = cache.get(c)
            if v is None:
                if c == "":
                    v = -1
                else:
                    try:
                        v = parse_color(c)
                    except TclError:
                        raise TclError("can't parse color \"" + c + "\"")
                cache[c] = v
            if v >= 0:
                p[k] = (v >> 16) & 255
                p[k + 1] = (v >> 8) & 255
                p[k + 2] = v & 255
                p[k + 3] = 255
            k += 4
    return blk


# ── reading formatted data ────────────────────────────────────────────────
def _sniff(b):
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if b[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if len(b) > 2 and b[0:1] == b"P" and b[1:2] in (b"5", b"6") and b[2:3] in (b" ", b"\n", b"\r", b"\t"):
        return "ppm"
    return None


def _decode(b, kind, fmt):
    opts = _format_opts(fmt)
    if kind == "png":
        return decode_png(b)
    if kind == "gif":
        return decode_gif(b, int(opts.get("-index", "0")))
    return decode_ppm(b)


def _sniff_data(data, want):
    # -> (bytes, kind) when the data is a recognised image (binary or
    # base64), else None
    if isinstance(data, (tuple, list)):
        return None
    b = _blob(data)
    kind = _sniff(b)
    if kind is not None and (want is None or kind == want):
        return b, kind
    try:
        t = "".join(b.decode("latin-1").split())
        d = base64.b64decode(t, validate=True) if t else b""
        k2 = _sniff(d)
        if k2 is not None and (want is None or k2 == want):
            return d, k2
    except Exception:
        pass
    return None


def read_data(data, fmt):
    b = _blob(data)
    want = _format_name(fmt, "data") if fmt else None
    kind = _sniff(b)
    if kind is None or (want is not None and kind != want):
        # Tk takes base64 for png and gif data too
        try:
            s = b.decode("latin-1")
            s = "".join(s.split())
            d = base64.b64decode(s, validate=True) if s else b""
            k2 = _sniff(d)
            if k2 is not None and (want is None or k2 == want):
                b = d
                kind = k2
        except Exception:
            pass
    if kind is None or (want is not None and kind != want):
        raise TclError("couldn't recognize image data")
    return _decode(b, kind, fmt)


def read_file(fn, fmt):
    try:
        with open(fn, "rb") as f:
            b = f.read()
    except OSError as e:
        raise TclError("couldn't open \"" + fn + "\": " + _os_reason(e))
    want = _format_name(fmt, "file") if fmt else None
    kind = _sniff(b)
    if kind is None or (want is not None and kind != want):
        raise TclError("couldn't recognize data in image file \"" + fn + "\"")
    return _decode(b, kind, fmt)


# ── PNG (RFC 2083 / ISO 15948) ────────────────────────────────────────────
def _be32(b, i):
    return (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]


def _paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(raw, pos, n, h, bpp):
    # -> (rows as one bytearray, next position)
    out = bytearray(n * h)
    prev = bytearray(n)
    for y in range(h):
        if pos >= len(raw):
            raise TclError("PNG image data is truncated")
        ft = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + n])
        pos += n
        if len(line) < n:
            raise TclError("PNG image data is truncated")
        if ft == 1:
            for i in range(bpp, n):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif ft == 2:
            for i in range(n):
                line[i] = (line[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(n):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(n):
                if i >= bpp:
                    a = line[i - bpp]
                    c = prev[i - bpp]
                else:
                    a = 0
                    c = 0
                line[i] = (line[i] + _paeth(a, prev[i], c)) & 255
        elif ft != 0:
            raise TclError("invalid filter type " + str(ft) + " in PNG image")
        out[y * n:(y + 1) * n] = line
        prev = line
    return out, pos


def decode_png(b):
    if b[:8] != b"\x89PNG\r\n\x1a\n":
        raise TclError("couldn't recognize image data")
    pos = 8
    ihdr = None
    plte = None
    trns = None
    idat = []
    while pos + 8 <= len(b):
        ln = _be32(b, pos)
        ctype = b[pos + 4:pos + 8]
        cdata = b[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if ctype == b"IHDR":
            ihdr = cdata
        elif ctype == b"PLTE":
            plte = cdata
        elif ctype == b"tRNS":
            trns = cdata
        elif ctype == b"IDAT":
            idat.append(cdata)
        elif ctype == b"IEND":
            break
    if ihdr is None or len(ihdr) < 13:
        raise TclError("PNG file has no IHDR chunk")
    w = _be32(ihdr, 0)
    h = _be32(ihdr, 4)
    depth = ihdr[8]
    ct = ihdr[9]
    interlace = ihdr[12]
    chans = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ct)
    if chans is None:
        raise TclError("unknown color type field " + str(ct))
    try:
        raw = zlib.decompress(b"".join(idat))
    except Exception:
        raise TclError("PNG image data is corrupt")
    bits = chans * depth
    bpp = max(1, bits // 8)
    blk = Block(w, h)
    if interlace:
        # Adam7: seven passes, each a small image of its own
        passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        rp = 0
        for (x0, y0, dx, dy) in passes:
            pw = (w - x0 + dx - 1) // dx if w > x0 else 0
            ph = (h - y0 + dy - 1) // dy if h > y0 else 0
            if pw == 0 or ph == 0:
                continue
            n = (pw * bits + 7) // 8
            rows, rp = _unfilter(raw, rp, n, ph, bpp)
            _png_pixels(rows, n, pw, ph, depth, ct, plte, trns, blk, x0, y0, dx, dy)
    else:
        n = (w * bits + 7) // 8
        rows, rp = _unfilter(raw, 0, n, h, bpp)
        _png_pixels(rows, n, w, h, depth, ct, plte, trns, blk, 0, 0, 1, 1)
    return blk


def _png_pixels(rows, n, pw, ph, depth, ct, plte, trns, blk, x0, y0, dx, dy):
    p = blk.pix
    W = blk.w
    if ct == 6 and depth == 8 and dx == 1 and dy == 1:
        p[0:len(rows)] = rows
        return
    tkey = None
    if trns is not None and ct == 0 and len(trns) >= 2:
        tkey = (trns[0] << 8) | trns[1]
    elif trns is not None and ct == 2 and len(trns) >= 6:
        tkey = ((trns[0] << 8) | trns[1], (trns[2] << 8) | trns[3], (trns[4] << 8) | trns[5])
    maxv = (1 << depth) - 1
    for y in range(ph):
        base = y * n
        drow = ((y0 + y * dy) * W + x0) * 4
        for x in range(pw):
            d = drow + x * dx * 4
            if depth < 8:
                bitpos = x * depth
                byte = rows[base + (bitpos >> 3)]
                v = (byte >> (8 - depth - (bitpos & 7))) & maxv
                if ct == 3:
                    k = v * 3
                    if plte is not None and k + 2 < len(plte):
                        p[d] = plte[k]
                        p[d + 1] = plte[k + 1]
                        p[d + 2] = plte[k + 2]
                    p[d + 3] = trns[v] if trns is not None and v < len(trns) else 255
                else:
                    g = (v * 255) // maxv
                    p[d] = p[d + 1] = p[d + 2] = g
                    p[d + 3] = 0 if tkey is not None and v == tkey else 255
                continue
            if depth == 8:
                s = base + x * {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
                if ct == 0:
                    g = rows[s]
                    p[d] = p[d + 1] = p[d + 2] = g
                    p[d + 3] = 0 if tkey is not None and g == tkey else 255
                elif ct == 2:
                    r, g, bb = rows[s], rows[s + 1], rows[s + 2]
                    p[d] = r
                    p[d + 1] = g
                    p[d + 2] = bb
                    p[d + 3] = 0 if tkey is not None and (r, g, bb) == tkey else 255
                elif ct == 3:
                    v = rows[s]
                    k = v * 3
                    if plte is not None and k + 2 < len(plte):
                        p[d] = plte[k]
                        p[d + 1] = plte[k + 1]
                        p[d + 2] = plte[k + 2]
                    p[d + 3] = trns[v] if trns is not None and v < len(trns) else 255
                elif ct == 4:
                    g = rows[s]
                    p[d] = p[d + 1] = p[d + 2] = g
                    p[d + 3] = rows[s + 1]
                else:
                    p[d] = rows[s]
                    p[d + 1] = rows[s + 1]
                    p[d + 2] = rows[s + 2]
                    p[d + 3] = rows[s + 3]
                continue
            # 16 bits per sample: the high bytes
            c = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
            s = base + x * c * 2
            vals = [(rows[s + 2 * i] << 8) | rows[s + 2 * i + 1] for i in range(c)]
            if ct == 0:
                p[d] = p[d + 1] = p[d + 2] = vals[0] >> 8
                p[d + 3] = 0 if tkey is not None and vals[0] == tkey else 255
            elif ct == 2:
                p[d] = vals[0] >> 8
                p[d + 1] = vals[1] >> 8
                p[d + 2] = vals[2] >> 8
                p[d + 3] = 0 if tkey is not None and tuple(vals) == tkey else 255
            elif ct == 4:
                p[d] = p[d + 1] = p[d + 2] = vals[0] >> 8
                p[d + 3] = vals[1] >> 8
            else:
                p[d] = vals[0] >> 8
                p[d + 1] = vals[1] >> 8
                p[d + 2] = vals[2] >> 8
                p[d + 3] = vals[3] >> 8


def _chunk(kind, data):
    return len(data).to_bytes(4, "big") + kind + data + (zlib.crc32(kind + data) & 0xffffffff).to_bytes(4, "big")


def encode_png(blk):
    # 8-bit RGB when every pixel is opaque, RGBA otherwise; filter 0
    p = blk.pix
    opaque = True
    for k in range(3, len(p), 4):
        if p[k] != 255:
            opaque = False
            break
    parts = []
    stride = blk.w * 4
    if opaque:
        for y in range(blk.h):
            row = bytearray(blk.w * 3 + 1)
            src = p[y * stride:(y + 1) * stride]
            j = 1
            for x in range(blk.w):
                row[j] = src[x * 4]
                row[j + 1] = src[x * 4 + 1]
                row[j + 2] = src[x * 4 + 2]
                j += 3
            parts.append(bytes(row))
        ct = 2
    else:
        for y in range(blk.h):
            parts.append(b"\x00" + bytes(p[y * stride:(y + 1) * stride]))
        ct = 6
    ihdr = blk.w.to_bytes(4, "big") + blk.h.to_bytes(4, "big") + bytes([8, ct, 0, 0, 0])
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", zlib.compress(b"".join(parts))) +
            _chunk(b"IEND", b""))


# ── GIF (GIF89a specification) ────────────────────────────────────────────
def _le16(b, i):
    return b[i] | (b[i + 1] << 8)


def _lzw_decode(data, min_size, npix):
    clear = 1 << min_size
    eoi = clear + 1
    size = min_size + 1
    table = [bytes([i]) for i in range(clear)] + [b"", b""]
    out = bytearray()
    prev = None
    acc = 0
    nbits = 0
    pos = 0
    n = len(data)
    while len(out) < npix:
        while nbits < size and pos < n:
            acc |= data[pos] << nbits
            nbits += 8
            pos += 1
        if nbits < size:
            break
        code = acc & ((1 << size) - 1)
        acc >>= size
        nbits -= size
        if code == clear:
            table = table[:clear + 2]
            size = min_size + 1
            prev = None
            continue
        if code == eoi:
            break
        if code < len(table):
            entry = table[code]
            if prev is not None:
                table.append(prev + entry[:1])
        elif prev is not None and code == len(table):
            entry = prev + prev[:1]
            table.append(entry)
        else:
            raise TclError("malformed GIF image data")
        out.extend(entry)
        prev = entry
        if len(table) == (1 << size) and size < 12:
            size += 1
    return out


def _sub_blocks(b, pos):
    parts = []
    while pos < len(b):
        n = b[pos]
        pos += 1
        if n == 0:
            break
        parts.append(b[pos:pos + n])
        pos += n
    return b"".join(parts), pos


def decode_gif(b, index=0):
    if b[:6] not in (b"GIF87a", b"GIF89a"):
        raise TclError("couldn't recognize image data")
    sw = _le16(b, 6)
    sh = _le16(b, 8)
    flags = b[10]
    pos = 13
    gct = None
    if flags & 0x80:
        n = 3 * (1 << ((flags & 7) + 1))
        gct = b[pos:pos + n]
        pos += n
    transp = -1
    frame = 0
    blk = Block(sw, sh)
    while pos < len(b):
        intro = b[pos]
        pos += 1
        if intro == 0x3B:
            break
        if intro == 0x21:
            label = b[pos]
            pos += 1
            data, pos = _sub_blocks(b, pos)
            if label == 0xF9 and len(data) >= 4:
                transp = data[3] if data[0] & 1 else -1
            continue
        if intro != 0x2C:
            raise TclError("malformed GIF image data")
        left = _le16(b, pos)
        top = _le16(b, pos + 2)
        iw = _le16(b, pos + 4)
        ih = _le16(b, pos + 6)
        f2 = b[pos + 8]
        pos += 9
        ct = gct
        if f2 & 0x80:
            n = 3 * (1 << ((f2 & 7) + 1))
            ct = b[pos:pos + n]
            pos += n
        min_size = b[pos]
        pos += 1
        data, pos = _sub_blocks(b, pos)
        if frame != index:
            frame += 1
            transp = -1
            continue
        idx = _lzw_decode(data, min_size, iw * ih)
        rows = list(range(ih))
        if f2 & 0x40:
            rows = list(range(0, ih, 8)) + list(range(4, ih, 8)) + list(range(2, ih, 4)) + list(range(1, ih, 2))
        p = blk.pix
        k = 0
        for r in rows:
            y = top + r
            for x in range(iw):
                if k >= len(idx):
                    break
                v = idx[k]
                k += 1
                xx = left + x
                if v == transp or xx >= sw or y >= sh or ct is None or v * 3 + 2 >= len(ct):
                    continue
                d = (y * sw + xx) * 4
                p[d] = ct[v * 3]
                p[d + 1] = ct[v * 3 + 1]
                p[d + 2] = ct[v * 3 + 2]
                p[d + 3] = 255
        return blk
    raise TclError("no image data for this index")


def encode_gif(blk):
    # the image's own colours (transparent pixels as one more); with more
    # than 256 a 3-3-2 palette (Nython: Tk refuses such images)
    p = blk.pix
    colors = {}
    has_t = False
    for k in range(0, len(p), 4):
        if p[k + 3] == 0:
            has_t = True
            continue
        c = (p[k] << 16) | (p[k + 1] << 8) | p[k + 2]
        if c not in colors:
            colors[c] = len(colors)
            if len(colors) > 256:
                break
    reduce = len(colors) + (1 if has_t else 0) > 256
    if reduce:
        colors = {}
        for r in range(8):
            for g in range(8):
                for bb in range(4):
                    colors[(r * 255 // 7 << 16) | (g * 255 // 7 << 8) | (bb * 255 // 3)] = len(colors)
        has_t = False
    tidx = len(colors) if has_t else -1
    ncol = len(colors) + (1 if has_t else 0)
    bits = 1
    while (1 << bits) < max(2, ncol):
        bits += 1
    pal = bytearray(3 * (1 << bits))
    for c, i in colors.items():
        pal[i * 3] = (c >> 16) & 255
        pal[i * 3 + 1] = (c >> 8) & 255
        pal[i * 3 + 2] = c & 255
    idx = bytearray(blk.w * blk.h)
    j = 0
    for k in range(0, len(p), 4):
        if p[k + 3] == 0 and tidx >= 0:
            idx[j] = tidx
        elif reduce:
            idx[j] = ((p[k] >> 5) << 5) | ((p[k + 1] >> 5) << 2) | (p[k + 2] >> 6)
        else:
            idx[j] = colors[(p[k] << 16) | (p[k + 1] << 8) | p[k + 2]]
        j += 1
    min_size = max(2, bits)
    out = bytearray(b"GIF89a")
    out.extend(blk.w.to_bytes(2, "little"))
    out.extend(blk.h.to_bytes(2, "little"))
    out.append(0x80 | ((bits - 1) << 4) | (bits - 1))
    out.append(0)
    out.append(0)
    out.extend(pal)
    if tidx >= 0:
        out.extend(bytes([0x21, 0xF9, 4, 1, 0, 0, tidx, 0]))
    out.append(0x2C)
    out.extend(bytes(4))
    out.extend(blk.w.to_bytes(2, "little"))
    out.extend(blk.h.to_bytes(2, "little"))
    out.append(0)
    out.append(min_size)
    data = _lzw_encode(idx, min_size)
    for i in range(0, len(data), 255):
        chunk = data[i:i + 255]
        out.append(len(chunk))
        out.extend(chunk)
    out.append(0)
    out.append(0x3B)
    return bytes(out)


def _lzw_encode(idx, min_size):
    clear = 1 << min_size
    eoi = clear + 1
    size = min_size + 1
    table = {}
    nxt = eoi + 1
    out = bytearray()
    acc = 0
    nbits = 0

    def emit(code, sz):
        nonlocal acc, nbits
        acc |= code << nbits
        nbits += sz
        while nbits >= 8:
            out.append(acc & 255)
            acc >>= 8
            nbits -= 8

    emit(clear, size)
    if len(idx) == 0:
        emit(eoi, size)
        if nbits:
            out.append(acc & 255)
        return bytes(out)
    cur = idx[0]
    for i in range(1, len(idx)):
        c = idx[i]
        key = (cur << 8) | c
        code = table.get(key)
        if code is not None:
            cur = code
            continue
        emit(cur, size)
        if nxt < 4096:
            table[key] = nxt
            nxt += 1
            if nxt > (1 << size) and size < 12:
                size += 1
        else:
            emit(clear, size)
            table = {}
            nxt = eoi + 1
            size = min_size + 1
        cur = c
    emit(cur, size)
    emit(eoi, size)
    if nbits:
        out.append(acc & 255)
    return bytes(out)


# ── PPM/PGM (netpbm) ──────────────────────────────────────────────────────
def decode_ppm(b):
    fields = []
    pos = 2
    while len(fields) < 3:
        while pos < len(b) and b[pos:pos + 1] in (b" ", b"\t", b"\n", b"\r"):
            pos += 1
        if b[pos:pos + 1] == b"#":
            while pos < len(b) and b[pos:pos + 1] != b"\n":
                pos += 1
            continue
        start = pos
        while pos < len(b) and b[pos:pos + 1] not in (b" ", b"\t", b"\n", b"\r"):
            pos += 1
        try:
            fields.append(int(b[start:pos]))
        except ValueError:
            raise TclError("couldn't recognize image data")
    pos += 1
    w, h, maxv = fields
    gray = b[1:2] == b"5"
    c = 1 if gray else 3
    two = maxv > 255
    blk = Block(w, h)
    p = blk.pix
    step = c * (2 if two else 1)
    need = w * h * step
    if len(b) - pos < need:
        raise TclError("error reading PPM image file")
    for i in range(w * h):
        s = pos + i * step
        d = i * 4
        if two:
            vals = [((b[s + 2 * k] << 8) | b[s + 2 * k + 1]) * 255 // maxv for k in range(c)]
        elif maxv != 255:
            vals = [b[s + k] * 255 // maxv for k in range(c)]
        else:
            vals = [b[s + k] for k in range(c)]
        if gray:
            p[d] = p[d + 1] = p[d + 2] = vals[0]
        else:
            p[d] = vals[0]
            p[d + 1] = vals[1]
            p[d + 2] = vals[2]
        p[d + 3] = 255
    return blk


def encode_ppm(blk):
    out = bytearray(("P6\n%d %d\n255\n" % (blk.w, blk.h)).encode("ascii"))
    p = blk.pix
    for k in range(0, len(p), 4):
        out.append(p[k])
        out.append(p[k + 1])
        out.append(p[k + 2])
    return bytes(out)


# ── bitmaps ───────────────────────────────────────────────────────────────
def parse_xbm(text):
    # -> (w, h, rows) with bit x of rows[y] = pixel (x, y), or raises
    if isinstance(text, (bytes, bytearray)):
        text = bytes(text).decode("latin-1")
    w = h = None
    import re as _re
    for m in _re.finditer(r"#define\s+\S*?(width|height)\s+(\d+)", text):
        if m.group(1) == "width":
            w = int(m.group(2))
        else:
            h = int(m.group(2))
    lb = text.find("{")
    rb = text.find("}", lb + 1)
    if w is None or h is None or lb < 0 or rb < 0:
        raise TclError("format error in bitmap data")
    vals = []
    for tok in text[lb + 1:rb].replace(",", " ").split():
        try:
            vals.append(int(tok, 0))
        except ValueError:
            raise TclError("format error in bitmap data")
    stride = (w + 7) // 8
    if len(vals) < stride * h:
        raise TclError("format error in bitmap data")
    rows = []
    for y in range(h):
        r = 0
        for k in range(stride):
            r |= (vals[y * stride + k] & 255) << (8 * k)
        rows.append(r)
    return (w, h, rows)


def _from_bytes(w, h, data):
    stride = (w + 7) // 8
    rows = []
    for y in range(h):
        r = 0
        for k in range(stride):
            r |= data[y * stride + k] << (8 * k)
        rows.append(r)
    return (w, h, rows)


def _from_art(art):
    lines = [ln for ln in art.strip("\n").split("\n")]
    w = max(len(ln) for ln in lines)
    rows = []
    for ln in lines:
        r = 0
        for x, ch in enumerate(ln):
            if ch == "#":
                r |= 1 << x
        rows.append(r)
    return (w, len(lines), rows)


_BUILTIN = {}
_BUILTIN_SRC = {
    "gray50": (16, 16, [0x55, 0x55, 0xaa, 0xaa] * 8),
    "gray75": (16, 16, [0x77, 0x77, 0xdd, 0xdd] * 8),
    "gray25": (16, 16, [0x88, 0x88, 0x22, 0x22] * 8),
    "gray12": (16, 16, [0x11, 0x11, 0x00, 0x00, 0x44, 0x44, 0x00, 0x00] * 4),
    "error": (17, 17, [0xf0, 0x0f, 0x00, 0x58, 0x15, 0x00, 0xac, 0x2a, 0x00, 0x56, 0x55, 0x00,
                       0x2b, 0xa8, 0x00, 0x15, 0x50, 0x01, 0x0b, 0xa0, 0x00, 0x05, 0x60, 0x01,
                       0x0b, 0xa0, 0x00, 0x05, 0x60, 0x01, 0x0b, 0xb0, 0x00, 0x15, 0x58, 0x01,
                       0x2a, 0xac, 0x00, 0x54, 0x55, 0x00, 0xa8, 0x2a, 0x00, 0xb0, 0x1a, 0x00,
                       0xe0, 0x07, 0x00]),
    "info": (8, 21, [0x3c, 0x2a, 0x16, 0x2a, 0x14, 0x00, 0x00, 0x3f, 0x15, 0x2e, 0x14, 0x2c,
                     0x14, 0x2c, 0x14, 0x2c, 0x14, 0x2c, 0xd7, 0xab, 0x55]),
    "warning": (6, 19, [0x0c, 0x16, 0x2b, 0x15, 0x2b, 0x15, 0x2b, 0x16, 0x0a, 0x16, 0x0a, 0x16,
                        0x0a, 0x00, 0x00, 0x1e, 0x0a, 0x16, 0x0a]),
}
_BUILTIN_ART = {
    "hourglass": """
###################
###################
 #...............#
 #...............#
  #.............#
   #...........#
    #.........#
     #.#.#.#.#
      #.#.#.#
       #.#.#
        #.#
       #.#.#
      #..#..#
     #...#...#
    #....#....#
   #....###....#
  #....#####....#
 #...#########...#
 #.#############.#
###################
###################
""",
    "questhead": """
     ######
   ##......##
  #..........#
 #..###..###..#
 #............#
#..............#
#.....####.....#
#....#....#....#
#.........#....#
#........#.....#
 #......#.....#
 #......#.....#
  #...........#
   ##...#...##
     #.....#
      #####
""",
    "question": """
      #####
    #########
   ###.....###
  ###.......###
  ##.........##
 ###.........###
 ###.........###
 ###.........###
  #..........###
  ...........###
  ..........###
  .........###
  ........###
  .......###
  ......###
  ......###
  ......###
  ......###
  ......###
  .........
  .........
  ......###
  .....#####
  .....#####
  .....#####
  ......###
  .........
""",
}
_XBM_FILES = {}


def builtin_bitmap(name):
    # -> (w, h, rows) for a builtin bitmap or "@file", or None
    name = tcl_str(name)
    if name == "":
        return None
    b = _BUILTIN.get(name)
    if b is not None:
        return b
    if name in _BUILTIN_SRC:
        w, h, data = _BUILTIN_SRC[name]
        b = _from_bytes(w, h, data)
    elif name in _BUILTIN_ART:
        b = _from_art(_BUILTIN_ART[name])
    elif name.startswith("@"):
        if name in _XBM_FILES:
            return _XBM_FILES[name]
        try:
            with open(name[1:]) as f:
                b = parse_xbm(f.read())
        except (OSError, TclError):
            return None
        _XBM_FILES[name] = b
        return b
    else:
        return None
    _BUILTIN[name] = b
    return b


BUILTIN_SIZES = {"error": (17, 17), "gray75": (16, 16), "gray50": (16, 16), "gray25": (16, 16),
                 "gray12": (16, 16), "hourglass": (19, 21), "info": (8, 21), "questhead": (16, 16),
                 "question": (17, 27), "warning": (6, 19)}


class BitmapImg:
    TYPE = "bitmap"

    def __init__(self, app, name):
        self.app = app
        self.name = name
        self.users = set()
        self.opts = {"-background": "", "-data": "", "-file": "", "-foreground": "#000000", "-maskdata": "",
                     "-maskfile": ""}
        self.bits = None
        self.mask = None

    def width(self):
        return self.bits[0] if self.bits else 0

    def height(self):
        return self.bits[1] if self.bits else 0

    def configure(self, args, creating=False):
        if len(args) % 2 == 1:
            o = match_prefix(tcl_str(args[-1]), _BITMAP_OPTS, "option")
            if len(args) == 1 and not creating:
                return self.config_entry(o)
            raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
        new = {}
        for i in range(0, len(args), 2):
            o = match_prefix(tcl_str(args[i]), _BITMAP_OPTS, "option")
            v = args[i + 1]
            new[o] = v if isinstance(v, (bytes, bytearray)) else tcl_str(v)
        for o in ("-foreground", "-background"):
            if o in new and new[o] != "":
                parse_color(new[o])
        self.opts.update(new)
        bits = None
        if self.opts["-file"] != "":
            fn = self.opts["-file"]
            try:
                with open(fn) as f:
                    bits = parse_xbm(f.read())
            except OSError as e:
                raise TclError("couldn't read bitmap file \"" + fn + "\": " + _os_reason(e))
        elif self.opts["-data"] != "":
            bits = parse_xbm(self.opts["-data"])
        mask = None
        if self.opts["-maskfile"] != "":
            fn = self.opts["-maskfile"]
            try:
                with open(fn) as f:
                    mask = parse_xbm(f.read())
            except OSError as e:
                raise TclError("couldn't read bitmap file \"" + fn + "\": " + _os_reason(e))
        elif self.opts["-maskdata"] != "":
            mask = parse_xbm(self.opts["-maskdata"])
        if mask is not None:
            if bits is None:
                raise TclError("can't have mask without bitmap")
            if mask[0] != bits[0] or mask[1] != bits[1]:
                raise TclError("bitmap and mask have different sizes")
        self.bits = bits
        self.mask = mask
        self.app.image_changed(self)
        return ""

    def config_entry(self, o):
        d = "#000000" if o == "-foreground" else ""
        return (o, "", "", d, self.opts[o])

    def command(self, args):
        if not args:
            raise TclError("wrong # args: should be \"" + self.name + " option ?arg ...?\"")
        sub = match_prefix(tcl_str(args[0]), ["cget", "configure"], "option")
        rest = args[1:]
        if sub == "cget":
            if len(rest) != 1:
                raise TclError("wrong # args: should be \"" + self.name + " cget option\"")
            return self.opts[match_prefix(tcl_str(rest[0]), _BITMAP_OPTS, "option")]
        if not rest:
            return tuple(self.config_entry(o) for o in _BITMAP_OPTS)
        return self.configure(rest)

    def draw(self, h, x, y, w, hh):
        if not self.bits:
            return
        from _tkinter.util import fill
        self.app.frame_images.append({"op": "image", "name": self.name, "a": [x, y, self.width(), self.height()]})
        bw, bh, rows = self.bits
        fg = parse_color(self.opts["-foreground"]) if self.opts["-foreground"] else None
        bg = parse_color(self.opts["-background"]) if self.opts["-background"] else None
        mrows = self.mask[2] if self.mask else None
        for yy in range(bh):
            row = rows[yy]
            m = mrows[yy] if mrows is not None else -1
            xx = 0
            while xx < bw:
                on = (row >> xx) & 1
                vis = on or (bg is not None and (m >> xx) & 1)
                if not vis:
                    xx += 1
                    continue
                x0 = xx
                while xx < bw and ((row >> xx) & 1) == on and (on or (m >> xx) & 1):
                    xx += 1
                c = fg if on else bg
                if c is not None:
                    fill(h, x + x0, y + yy, xx - x0, 1, c)

    def delete(self):
        pass


# ── the image command ─────────────────────────────────────────────────────
def image_command(app, args):
    if not args:
        raise TclError("wrong # args: should be \"image option ?args?\"")
    sub = match_prefix(tcl_str(args[0]), _IMAGE_SUBS, "option")
    rest = args[1:]
    if sub == "create":
        if not rest:
            raise TclError("wrong # args: should be \"image create type ?name? ?-option value ...?\"")
        kind = tcl_str(rest[0])
        if kind not in ("photo", "bitmap"):
            raise TclError("image type \"" + kind + "\" doesn't exist")
        opts = rest[1:]
        if opts and not tcl_str(opts[0]).startswith("-"):
            name = tcl_str(opts[0])
            opts = opts[1:]
        else:
            app.image_seq = getattr(app, "image_seq", 0) + 1
            name = "image" + str(app.image_seq)
            while name in app.images or name in app.interp.commands:
                app.image_seq += 1
                name = "image" + str(app.image_seq)
        if name == ".":
            raise TclError("images may not be named the same as the main window")
        old = app.images.get(name)
        im = Photo(app, name) if kind == "photo" else BitmapImg(app, name)
        if old is not None:
            im.users = old.users
            old.delete()
        im.configure(list(opts), True)
        app.images[name] = im
        app.interp.commands[name] = lambda it, words: im.command(words[1:])
        app.image_changed(im)
        return name
    if sub == "delete":
        for a in rest:
            n = tcl_str(a)
            im = app.images.get(n)
            if im is None:
                raise TclError("image \"" + n + "\" doesn't exist")
            del app.images[n]
            if app.interp.commands.get(n) is not None:
                del app.interp.commands[n]
            im.delete()
            app.image_changed(im)
        return ""
    if sub == "names":
        if rest:
            raise TclError("wrong # args: should be \"image names\"")
        return tuple(app.images.keys())
    if sub == "types":
        if rest:
            raise TclError("wrong # args: should be \"image types\"")
        return ("photo", "bitmap")
    if len(rest) != 1:
        raise TclError("wrong # args: should be \"image " + sub + " name\"")
    n = tcl_str(rest[0])
    im = app.images.get(n)
    if im is None:
        raise TclError("image \"" + n + "\" doesn't exist")
    if sub == "height":
        return im.height()
    if sub == "width":
        return im.width()
    if sub == "type":
        return im.TYPE
    if sub == "inuse":
        return 1 if any(not w.destroyed for w in im.users) else 0
    return ""
