# nython: module    (part of the _tkinter package: lib/_tkinter/)
# lib/_tkinter/geom.ny - pack, grid and place with Tk's own algorithms
# (round 84).
#
# pack   tkPack.c: pass 1 sums the slaves' requested sizes (plus padding
#        and twice the internal padding) to the master's request, pass 2
#        carves each slave's parcel off the cavity (side top/bottom/left/
#        right), expands it by XExpansion/YExpansion (the smallest share any
#        expandable run allows), fills and anchors the slave in it
# grid   tkGrid.c: ResolveConstraints (single-span slaves set slot minimum
#        sizes, then uniform groups, then multi-span slaves by right edge,
#        the min/max offset passes and the weighted distribution of slack
#        inside spans), AdjustOffsets (grow or shrink by weight to the
#        master's size, slots never below -minsize), AdjustForSticky; the
#        master's -anchor when nothing has weight
# place  tkPlace.c: x + relx * master width (rounded at the edges, so relx
#        and relwidth do not accumulate rounding), -anchor, -bordermode
#        inside/outside/ignore, the slave's request when no size is given
#
# Integer arithmetic is C's (division truncates toward zero) as in Tk, so
# the pixel results are Tk's for the same requested sizes.

from _tkinter.tcl import TclError, tcl_str, split_list, join_list, get_int, get_double, get_boolean, match_prefix, or_list, quote_elem
from _tkinter.util import pixels, cdiv, cround

# ── pack ─────────────────────────────────────────────────────────────────────

class PackInfo:
    def __init__(self):
        self.side = "top"
        self.anchor = "center"
        self.fill = "none"
        self.expand = 0
        self.padl = 0
        self.padr = 0
        self.padt = 0
        self.padb = 0
        self.ipadx = 0
        self.ipady = 0
        self.padx_spec = 0
        self.pady_spec = 0


_PACK_OPTS = ["-after", "-anchor", "-before", "-expand", "-fill", "-in", "-ipadx", "-ipady",
              "-padx", "-pady", "-side"]


def parse_pad(v):
    # TkParsePadAmount: "n" or "left right" -> (left, total)
    parts = split_list(v) if not isinstance(v, (int, float)) else [v]
    if len(parts) == 0 or len(parts) > 2:
        raise TclError("wrong number of parts to pad specification")
    try:
        a = pixels(parts[0])
    except TclError:
        raise TclError("bad pad value \"" + tcl_str(parts[0]) + "\": must be positive screen distance")
    if a < 0:
        raise TclError("bad pad value \"" + tcl_str(parts[0]) + "\": must be positive screen distance")
    if len(parts) == 2:
        try:
            b = pixels(parts[1])
        except TclError:
            raise TclError("bad 2nd pad value \"" + tcl_str(parts[1]) + "\": must be positive screen distance")
        if b < 0:
            raise TclError("bad 2nd pad value \"" + tcl_str(parts[1]) + "\": must be positive screen distance")
        return a, a + b
    return a, 2 * a


def _ipad(v, which):
    try:
        a = pixels(v)
    except TclError:
        a = -1
    if a < 0:
        raise TclError("bad ipad" + which + " value \"" + tcl_str(v) + "\": must be positive screen distance")
    return a


def check_master(app, slave, master, mgr):
    if slave.IS_TOPLEVEL:
        raise TclError("can't manage \"" + slave.path + "\": it's a top-level window")
    if master is slave:
        raise TclError("can't pack " + slave.path + " inside itself" if mgr == "pack" else
                       "window can't be managed in itself")
    # the master must be the slave's parent or a descendant of it
    anc = slave.parent
    w = master
    while w is not None and w is not anc:
        if w.IS_TOPLEVEL:
            raise TclError("can't " + ("pack " if mgr == "pack" else "put ") + slave.path + " inside " + master.path)
        w = w.parent
    if w is None:
        raise TclError("can't " + ("pack " if mgr == "pack" else "put ") + slave.path + " inside " + master.path)
    p = master
    while p is not None:
        if p is slave:
            raise TclError("can't put " + slave.path + " inside " + master.path + ", would cause management loop")
        p = p.gmaster
    if master.content_manager not in ("", mgr):
        raise TclError("cannot use geometry manager " + mgr + " inside " + master.path +
                       " which already has slaves managed by " + master.content_manager)


def unmanage(app, slave, keep_grid=False):
    # remove `slave` from whatever geometry manager has it
    m = slave.gmaster
    mgr = slave.manager
    if mgr == "pack" and m is not None:
        if slave in m.pack_slaves:
            m.pack_slaves.remove(slave)
        if not m.pack_slaves:
            m.content_manager = ""
    elif mgr == "grid" and m is not None:
        if slave in m.grid_slaves:
            m.grid_slaves.remove(slave)
        if not m.grid_slaves and m.content_manager == "grid":
            m.content_manager = ""
    elif mgr == "place" and m is not None:
        if slave in m.place_slaves:
            m.place_slaves.remove(slave)
    elif mgr != "" and m is not None:
        hook = getattr(m, "forget_slave", None)
        if hook is not None:
            hook(slave)
    slave.manager = ""
    slave.gmaster = None
    if not keep_grid:
        slave.minfo = None
    app.set_mapped(slave, False)
    app.relayout()


def pack_configure(app, slaves, args):
    if len(args) % 2 != 0:
        raise TclError("extra option \"" + tcl_str(args[-1]) + "\" (option with no value?)")
    opts = {}
    for i in range(0, len(args), 2):
        k = tcl_str(args[i])
        if not k.startswith("-"):
            raise TclError("bad option \"" + k + "\": must be " + or_list(_PACK_OPTS))
        k = match_prefix(k, _PACK_OPTS, "option")
        opts[k] = args[i + 1]
    position = None    # (master, index) for -before/-after
    for slave in slaves:
        info = slave.minfo if (slave.manager == "pack") else None
        if info is None:
            info = PackInfo()
        master = slave.gmaster if slave.manager == "pack" else None
        if "-in" in opts:
            master = app.window(opts["-in"])
        if "-before" in opts or "-after" in opts:
            key = "-before" if "-before" in opts else "-after"
            other = app.window(opts[key])
            if other.manager != "pack":
                raise TclError("window \"" + other.path + "\" isn't packed")
            master = other.gmaster
            if position is None:
                idx = master.pack_slaves.index(other)
                position = [master, idx if key == "-before" else idx + 1]
        if master is None:
            master = slave.parent
        for k in opts:
            v = opts[k]
            if k == "-side":
                info.side = match_prefix(tcl_str(v), ["top", "bottom", "left", "right"], "side")
            elif k == "-anchor":
                info.anchor = match_prefix(tcl_str(v), ["n", "ne", "e", "se", "s", "sw", "w", "nw", "center"], "anchor")
            elif k == "-fill":
                s = tcl_str(v)
                try:
                    info.fill = match_prefix(s, ["none", "x", "y", "both"], "fill style")
                except TclError:
                    raise TclError("bad fill style \"" + s + "\": must be none, x, y, or both")
            elif k == "-expand":
                info.expand = 1 if get_boolean(v) else 0
            elif k == "-padx":
                info.padl, tot = parse_pad(v)
                info.padr = tot - info.padl
                info.padx_spec = v
            elif k == "-pady":
                info.padt, tot = parse_pad(v)
                info.padb = tot - info.padt
                info.pady_spec = v
            elif k == "-ipadx":
                info.ipadx = _ipad(v, "x")
            elif k == "-ipady":
                info.ipady = _ipad(v, "y")
        check_master(app, slave, master, "pack")
        if slave.manager != "" and not (slave.manager == "pack" and slave.gmaster is master):
            unmanage(app, slave)
        slave.minfo = info
        if slave.manager == "pack" and slave.gmaster is master and position is None:
            pass
        else:
            if slave.manager == "pack" and slave in master.pack_slaves:
                master.pack_slaves.remove(slave)
                if position is not None and position[1] > len(master.pack_slaves):
                    position[1] = len(master.pack_slaves)
            if position is not None:
                master.pack_slaves.insert(position[1], slave)
                position[1] += 1
            else:
                master.pack_slaves.append(slave)
        slave.manager = "pack"
        slave.gmaster = master
        master.content_manager = "pack"
    app.relayout()
    return ""


def pack_info(app, slave):
    if slave.manager != "pack":
        raise TclError("window \"" + slave.path + "\" isn't packed")
    i = slave.minfo
    return ("-in", slave.gmaster.path, "-anchor", i.anchor, "-expand", i.expand, "-fill", i.fill,
            "-ipadx", i.ipadx, "-ipady", i.ipady, "-padx", _pad_out(i.padl, i.padr),
            "-pady", _pad_out(i.padt, i.padb), "-side", i.side)


def _pad_out(a, b):
    return a if a == b else (a, b)


def pack_request(m):
    # pass 1 of ArrangePacking: the master's requested size
    width = m.ib[0] + m.ib[2]
    maxw = width
    height = m.ib[1] + m.ib[3]
    maxh = height
    for s in m.pack_slaves:
        i = s.minfo
        if i.side == "top" or i.side == "bottom":
            tmp = s.reqw + i.padl + i.padr + 2 * i.ipadx + width
            if tmp > maxw:
                maxw = tmp
            height += s.reqh + i.padt + i.padb + 2 * i.ipady
        else:
            tmp = s.reqh + i.padt + i.padb + 2 * i.ipady + height
            if tmp > maxh:
                maxh = tmp
            width += s.reqw + i.padl + i.padr + 2 * i.ipadx
    if width > maxw:
        maxw = width
    if height > maxh:
        maxh = height
    if maxw < m.minreqw:
        maxw = m.minreqw
    if maxh < m.minreqh:
        maxh = m.minreqh
    return maxw, maxh


def _xexpansion(slaves, k, cavity_width):
    min_expand = cavity_width
    num = 0
    for j in range(k, len(slaves)):
        s = slaves[j]
        i = s.minfo
        child = s.reqw + i.padl + i.padr + 2 * i.ipadx
        if i.side == "top" or i.side == "bottom":
            if num:
                cur = cdiv(cavity_width - child, num)
                if cur < min_expand:
                    min_expand = cur
        else:
            cavity_width -= child
            if i.expand:
                num += 1
    if num:
        cur = cdiv(cavity_width, num)
        if cur < min_expand:
            min_expand = cur
    return 0 if min_expand < 0 else min_expand


def _yexpansion(slaves, k, cavity_height):
    min_expand = cavity_height
    num = 0
    for j in range(k, len(slaves)):
        s = slaves[j]
        i = s.minfo
        child = s.reqh + i.padt + i.padb + 2 * i.ipady
        if i.side == "left" or i.side == "right":
            if num:
                cur = cdiv(cavity_height - child, num)
                if cur < min_expand:
                    min_expand = cur
        else:
            cavity_height -= child
            if i.expand:
                num += 1
    if num:
        cur = cdiv(cavity_height, num)
        if cur < min_expand:
            min_expand = cur
    return 0 if min_expand < 0 else min_expand


def pack_arrange(app, m):
    # pass 2 of ArrangePacking
    slaves = m.pack_slaves
    cx = m.ib[0]
    cy = m.ib[1]
    cw = m.width - m.ib[0] - m.ib[2]
    ch = m.height - m.ib[1] - m.ib[3]
    for k in range(len(slaves)):
        s = slaves[k]
        i = s.minfo
        if i.side == "top" or i.side == "bottom":
            fw = cw
            fh = s.reqh + i.padt + i.padb + 2 * i.ipady
            if i.expand:
                fh += _yexpansion(slaves, k, ch)
            ch -= fh
            if ch < 0:
                fh += ch
                ch = 0
            fx = cx
            if i.side == "top":
                fy = cy
                cy += fh
            else:
                fy = cy + ch
        else:
            fh = ch
            fw = s.reqw + i.padl + i.padr + 2 * i.ipadx
            if i.expand:
                fw += _xexpansion(slaves, k, cw)
            cw -= fw
            if cw < 0:
                fw += cw
                cw = 0
            fy = cy
            if i.side == "left":
                fx = cx
                cx += fw
            else:
                fx = cx + cw
        bx = i.padl + i.padr
        by = i.padt + i.padb
        bl = i.padl
        bt = i.padt
        w = s.reqw + 2 * i.ipadx
        if i.fill in ("x", "both") or w > fw - bx:
            w = fw - bx
        h = s.reqh + 2 * i.ipady
        if i.fill in ("y", "both") or h > fh - by:
            h = fh - by
        br = bx - bl
        bb = by - bt
        a = i.anchor
        if a == "n":
            x = fx + cdiv(bl + fw - w - br, 2)
            y = fy + bt
        elif a == "ne":
            x = fx + fw - w - br
            y = fy + bt
        elif a == "e":
            x = fx + fw - w - br
            y = fy + cdiv(bt + fh - h - bb, 2)
        elif a == "se":
            x = fx + fw - w - br
            y = fy + fh - h - bb
        elif a == "s":
            x = fx + cdiv(bl + fw - w - br, 2)
            y = fy + fh - h - bb
        elif a == "sw":
            x = fx + bl
            y = fy + fh - h - bb
        elif a == "w":
            x = fx + bl
            y = fy + cdiv(bt + fh - h - bb, 2)
        elif a == "nw":
            x = fx + bl
            y = fy + bt
        else:
            x = fx + cdiv(bl + fw - w - br, 2)
            y = fy + cdiv(bt + fh - h - bb, 2)
        app.place_slave(m, s, x, y, w, h)


# ── grid ─────────────────────────────────────────────────────────────────────

class GridInfo:
    def __init__(self):
        self.row = -1
        self.column = -1
        self.rowspan = 1
        self.columnspan = 1
        self.sticky = ""
        self.padl = 0
        self.padr = 0
        self.padt = 0
        self.padb = 0
        self.ipadx = 0
        self.ipady = 0
        self.size = 0


class Slot:
    def __init__(self):
        self.minsize = 0
        self.weight = 0
        self.uniform = ""
        self.pad = 0
        self.offset = 0
        self.temp = 0


class GridMaster:
    def __init__(self):
        self.cols = []
        self.rows = []
        self.anchor = "nw"
        self.startx = 0
        self.starty = 0
        self.colend = 0
        self.rowend = 0

    def slots(self, kind):
        return self.cols if kind == "column" else self.rows

    def ensure(self, kind, n):
        lst = self.slots(kind)
        while len(lst) < n:
            lst.append(Slot())
        return lst

    def constraint_count(self, kind):
        lst = self.slots(kind)
        n = len(lst)
        while n > 0:
            s = lst[n - 1]
            if s.minsize or s.weight or s.uniform or s.pad:
                break
            n -= 1
        return n


_GRID_OPTS = ["-column", "-columnspan", "-in", "-ipadx", "-ipady", "-padx", "-pady", "-row", "-rowspan", "-sticky"]


def grid_master(m):
    if m.grid is None:
        m.grid = GridMaster()
    return m.grid


def _sticky(v):
    s = tcl_str(v)
    out = ""
    for c in s:
        lc = c.lower()
        if lc in "nsew":
            if lc not in out:
                out += lc
        elif c in " ,\t":
            continue
        else:
            raise TclError("bad stickyness value \"" + s + "\": must be a string containing n, e, s, and/or w")
    # stored in Tk's canonical order
    res = ""
    for c in "nesw":
        if c in out:
            res += c
    return res


def grid_configure(app, items, args):
    if len(args) % 2 != 0:
        raise TclError("extra option or option with no value")
    opts = {}
    for i in range(0, len(args), 2):
        k = tcl_str(args[i])
        try:
            k = match_prefix(k, _GRID_OPTS, "option")
        except TclError:
            raise TclError("bad option \"" + k + "\": must be " + or_list(_GRID_OPTS))
        opts[k] = args[i + 1]
    # the relative-placement characters: x (skip a column), - (span), ^ (span the row above)
    col = None
    row = None
    if "-column" in opts:
        col = get_int(opts["-column"])
        if col < 0:
            raise TclError("bad column value \"" + tcl_str(opts["-column"]) + "\": must be a non-negative integer")
    if "-row" in opts:
        row = get_int(opts["-row"])
        if row < 0:
            raise TclError("bad row value \"" + tcl_str(opts["-row"]) + "\": must be a non-negative integer")
    master = app.window(opts["-in"]) if "-in" in opts else None
    # the master is that of the first real slave
    first = None
    for it in items:
        if it not in ("x", "-", "^"):
            first = app.window(it)
            break
    if first is None:
        raise TclError("can't determine master window")
    if master is None:
        if first.manager == "grid" and first.gmaster is not None and "-in" not in opts:
            master = first.gmaster
        else:
            master = first.parent
    gm = grid_master(master)
    if row is None:
        # a slave keeps its row; new ones go after the last row in use
        if first.manager == "grid" and first.gmaster is master and first.minfo is not None:
            row = first.minfo.row
        else:
            set_grid_size(master)
            row = gm.rowend
    defcol = col if col is not None else 0
    if col is None and first.manager == "grid" and first.gmaster is master and first.minfo is not None and "-column" not in opts:
        defcol = first.minfo.column
    k = 0
    last = None
    c = defcol
    while k < len(items):
        it = items[k]
        if it == "x":
            c += 1
            k += 1
            continue
        if it == "-":
            if last is None:
                raise TclError("must specify window before shortcut '-'")
            last.minfo.columnspan += 1
            c += 1
            k += 1
            continue
        if it == "^":
            # extend the rowspan of the slave in the row above at this column
            for s in master.grid_slaves:
                si = s.minfo
                if si.column <= c < si.column + si.columnspan and si.row + si.rowspan == row:
                    si.rowspan += 1
                    break
            c += 1
            k += 1
            continue
        slave = app.window(it)
        info = slave.minfo if slave.manager == "grid" else None
        # a slave `grid remove` took out keeps its slot (tkGrid.c leaves its row/column set)
        restored = info is None and getattr(slave, "grid_saved", None) is not None
        if info is None:
            info = slave.grid_saved if restored else GridInfo()
        slave.grid_saved = None
        for key in opts:
            v = opts[key]
            if key == "-columnspan":
                n = get_int(v)
                if n <= 0:
                    raise TclError("bad columnspan value \"" + tcl_str(v) + "\": must be a positive integer")
                info.columnspan = n
            elif key == "-rowspan":
                n = get_int(v)
                if n <= 0:
                    raise TclError("bad rowspan value \"" + tcl_str(v) + "\": must be a positive integer")
                info.rowspan = n
            elif key == "-sticky":
                info.sticky = _sticky(v)
            elif key == "-padx":
                info.padl, tot = parse_pad(v)
                info.padr = tot - info.padl
            elif key == "-pady":
                info.padt, tot = parse_pad(v)
                info.padb = tot - info.padt
            elif key == "-ipadx":
                info.ipadx = _ipad(v, "x")
            elif key == "-ipady":
                info.ipady = _ipad(v, "y")
        if "-column" in opts or info.column < 0 or ((k > 0 or slave.manager != "grid") and not restored):
            info.column = c
        if "-row" in opts or info.row < 0 or (slave.manager != "grid" and not restored):
            info.row = row
        c = info.column + info.columnspan
        check_master(app, slave, master, "grid")
        if slave.manager != "" and not (slave.manager == "grid" and slave.gmaster is master):
            unmanage(app, slave)
        slave.minfo = info
        if not (slave.manager == "grid" and slave.gmaster is master):
            master.grid_slaves.append(slave)
        slave.manager = "grid"
        slave.gmaster = master
        master.content_manager = "grid"
        last = slave
        k += 1
    app.relayout()
    return ""


def grid_info(app, slave):
    if slave.manager != "grid":
        return ()
    i = slave.minfo
    return ("-in", slave.gmaster.path, "-column", i.column, "-row", i.row, "-columnspan", i.columnspan,
            "-rowspan", i.rowspan, "-ipadx", i.ipadx, "-ipady", i.ipady, "-padx", _pad_out(i.padl, i.padr),
            "-pady", _pad_out(i.padt, i.padb), "-sticky", i.sticky)


def set_grid_size(m):
    gm = grid_master(m)
    mx = 0
    my = 0
    for s in m.grid_slaves:
        i = s.minfo
        mx = max(mx, i.column + i.columnspan)
        my = max(my, i.row + i.rowspan)
    gm.colend = mx
    gm.rowend = my
    gm.ensure("column", mx)
    gm.ensure("row", my)


def resolve_constraints(m, kind, max_offset):
    gm = m.grid
    constraint_count = gm.constraint_count(kind)
    slot_count = gm.colend if kind == "column" else gm.rowend
    grid_count = max(constraint_count, slot_count)
    slots = gm.ensure(kind, grid_count)
    BIG = 1 << 40
    # layout[0] is the dummy slot left of the first; layout[k + 1] is slot k
    minsize = [0] * (grid_count + 1)
    weight = [0] * (grid_count + 1)
    uniform = [""] * (grid_count + 1)
    pad = [0] * (grid_count + 1)
    minoff = [0] * (grid_count + 1)
    maxoff = [BIG] * (grid_count + 1)
    maxoff[0] = 0
    bins = [None] * (grid_count + 1)
    for k in range(grid_count):
        s = slots[k]
        if k < constraint_count:
            minsize[k + 1] = s.minsize
            weight[k + 1] = s.weight
            uniform[k + 1] = s.uniform
            pad[k + 1] = s.pad
    # step 2: single-span slaves give slot minimum sizes; multi-span are binned
    for sl in m.grid_slaves:
        i = sl.minfo
        if kind == "column":
            right = i.column + i.columnspan - 1
            i.size = sl.reqw + i.padl + i.padr + 2 * i.ipadx
            span = i.columnspan
        else:
            right = i.row + i.rowspan - 1
            i.size = sl.reqh + i.padt + i.padb + 2 * i.ipady
            span = i.rowspan
        if span > 1:
            if bins[right + 1] is None:
                bins[right + 1] = []
            bins[right + 1].insert(0, sl)
        elif right >= 0:
            sz = i.size + pad[right + 1]
            if sz > minsize[right + 1]:
                minsize[right + 1] = sz
    # step 2b: uniform groups
    groups = {}
    for k in range(1, grid_count + 1):
        if uniform[k] != "":
            wgt = weight[k] if weight[k] > 0 else 1
            ms = cdiv(minsize[k] + wgt - 1, wgt)
            groups[uniform[k]] = max(groups.get(uniform[k], 0), ms)
    if groups:
        for k in range(1, grid_count + 1):
            if uniform[k] != "":
                wgt = weight[k] if weight[k] > 0 else 1
                minsize[k] = groups[uniform[k]] * wgt
    # step 3: minimum offsets left to right
    offset = 0
    for k in range(1, grid_count + 1):
        minoff[k] = minsize[k] + offset
        if bins[k] is not None:
            for sl in bins[k]:
                i = sl.minfo
                span = i.columnspan if kind == "column" else i.rowspan
                required = i.size + minoff[k - span]
                if required > minoff[k]:
                    minoff[k] = required
        offset = minoff[k]
    required_size = offset
    if max_offset > offset:
        offset = max_offset
    # step 4: maximum offsets right to left
    if grid_count > 0:
        maxoff[grid_count] = offset
    k = grid_count
    while k > 1:
        if bins[k] is not None:
            for sl in bins[k]:
                i = sl.minfo
                span = i.columnspan if kind == "column" else i.rowspan
                require = offset - i.size
                start = k - span
                if start >= 1 and require < maxoff[start]:
                    maxoff[start] = require
        offset -= minsize[k]
        k -= 1
        if maxoff[k] < offset:
            offset = maxoff[k]
        else:
            maxoff[k] = offset
    # step 5: distribute slack inside spans whose edges are not yet fixed
    start = 1
    guard = 0
    while start <= grid_count:
        guard += 1
        if guard > 10000:
            break
        if minoff[start] == maxoff[start]:
            start += 1
            continue
        end = start + 1
        while end <= grid_count:
            if minoff[end] == maxoff[end]:
                break
            end += 1
        if end > grid_count:
            end = grid_count
        total_weight = 0
        need = 0
        for k in range(start, end + 1):
            total_weight += weight[k]
            need += minsize[k]
        have = maxoff[end] - minoff[start - 1]
        no_weights = 0
        if total_weight == 0:
            no_weights = 1
            total_weight = end - start + 1
        wsum = 0
        for k in range(start, end):
            diff = maxoff[k] - minoff[k]
            wsum += 1 if no_weights else weight[k]
            if (no_weights or weight[k] > 0) and wsum > 0 and cdiv(diff * total_weight, wsum) < (have - need):
                have = cdiv(diff * total_weight, wsum) + need
        wsum = 0
        for k in range(start, end):
            wsum += 1 if no_weights else weight[k]
            minoff[k] += int((have - need) * wsum / total_weight + 0.5)
            minsize[k] = minoff[k] - minoff[k - 1]
        minsize[end] = minoff[end] - minoff[end - 1]
        k = end
        while k > start:
            maxoff[k - 1] = maxoff[k] - minsize[k]
            k -= 1
    for k in range(grid_count):
        slots[k].offset = minoff[k + 1]
    return required_size


def adjust_offsets(size, nslots, slots):
    if nslots <= 0:
        return 0
    diff = size - slots[nslots - 1].offset
    if diff == 0:
        return size
    total = 0
    for k in range(nslots):
        total += slots[k].weight
    if total == 0:
        return slots[nslots - 1].offset
    if diff > 0:
        wsum = 0
        for k in range(nslots):
            wsum += slots[k].weight
            slots[k].offset += cdiv(diff * wsum, total)
        return size
    minsize = 0
    for k in range(nslots):
        if slots[k].weight > 0:
            slots[k].temp = slots[k].minsize
        elif k > 0:
            slots[k].temp = slots[k].offset - slots[k - 1].offset
        else:
            slots[k].temp = slots[k].offset
        minsize += slots[k].temp
    if size <= minsize:
        offset = 0
        for k in range(nslots):
            offset += slots[k].temp
            slots[k].offset = offset
        return minsize
    guard = 0
    while diff < 0:
        guard += 1
        if guard > 1000:
            break
        total = 0
        for k in range(nslots):
            cur = slots[k].offset if k == 0 else slots[k].offset - slots[k - 1].offset
            if cur > slots[k].minsize:
                total += slots[k].weight
                slots[k].temp = slots[k].weight
            else:
                slots[k].temp = 0
        if total == 0:
            break
        new_diff = diff
        for k in range(nslots):
            if slots[k].temp == 0:
                continue
            cur = slots[k].offset if k == 0 else slots[k].offset - slots[k - 1].offset
            max_diff = cdiv(total * (slots[k].minsize - cur), slots[k].temp)
            if max_diff > new_diff:
                new_diff = max_diff
        wsum = 0
        for k in range(nslots):
            wsum += slots[k].temp
            slots[k].offset += cdiv(new_diff * wsum, total)
        diff -= new_diff
    return size


def grid_request(m):
    set_grid_size(m)
    w = resolve_constraints(m, "column", 0)
    h = resolve_constraints(m, "row", 0)
    w += m.ib[0] + m.ib[2]
    h += m.ib[1] + m.ib[3]
    if w < m.minreqw:
        w = m.minreqw
    if h < m.minreqh:
        h = m.minreqh
    return w, h


def grid_layout(m):
    # the slot offsets for the master's actual size (and startx/starty)
    gm = grid_master(m)
    set_grid_size(m)
    resolve_constraints(m, "column", 0)
    resolve_constraints(m, "row", 0)
    rw = m.width - m.ib[0] - m.ib[2]
    rh = m.height - m.ib[1] - m.ib[3]
    nc = max(gm.colend, gm.constraint_count("column"))
    nr = max(gm.rowend, gm.constraint_count("row"))
    usedx = adjust_offsets(rw, nc, gm.cols)
    usedy = adjust_offsets(rh, nr, gm.rows)
    a = gm.anchor
    # TkComputeAnchor(anchor, master, 0, 0, usedX, usedY)
    if a in ("nw", "w", "sw"):
        sx = m.ib[0]
    elif a in ("ne", "e", "se"):
        sx = m.width - m.ib[2] - usedx
    else:
        sx = m.ib[0] + cdiv(m.width - m.ib[0] - m.ib[2] - usedx, 2)
    if a in ("nw", "n", "ne"):
        sy = m.ib[1]
    elif a in ("sw", "s", "se"):
        sy = m.height - m.ib[3] - usedy
    else:
        sy = m.ib[1] + cdiv(m.height - m.ib[1] - m.ib[3] - usedy, 2)
    gm.startx = sx
    gm.starty = sy


def grid_arrange(app, m):
    gm = grid_master(m)
    grid_layout(m)
    for s in m.grid_slaves:
        i = s.minfo
        col = i.column
        row = i.row
        x = gm.cols[col - 1].offset if col > 0 else 0
        y = gm.rows[row - 1].offset if row > 0 else 0
        w = gm.cols[i.columnspan + col - 1].offset - x
        h = gm.rows[i.rowspan + row - 1].offset - y
        x += gm.startx
        y += gm.starty
        # AdjustForSticky
        x += i.padl
        w -= i.padl + i.padr
        y += i.padt
        h -= i.padt + i.padb
        diffx = 0
        diffy = 0
        if w > s.reqw + 2 * i.ipadx:
            diffx = w - (s.reqw + 2 * i.ipadx)
            w = s.reqw + 2 * i.ipadx
        if h > s.reqh + 2 * i.ipady:
            diffy = h - (s.reqh + 2 * i.ipady)
            h = s.reqh + 2 * i.ipady
        st = i.sticky
        if "e" in st and "w" in st:
            w += diffx
        if "n" in st and "s" in st:
            h += diffy
        if "w" not in st:
            x += diffx if "e" in st else cdiv(diffx, 2)
        if "n" not in st:
            y += diffy if "s" in st else cdiv(diffy, 2)
        app.place_slave(m, s, x, y, w, h)


def grid_bbox(m, args):
    gm = grid_master(m)
    grid_layout(m)
    nc = max(gm.colend, gm.constraint_count("column"))
    nr = max(gm.rowend, gm.constraint_count("row"))
    if nc == 0 or nr == 0:
        return (0, 0, 0, 0)
    if len(args) == 0:
        c0, r0, c1, r1 = 0, 0, nc - 1, nr - 1
    elif len(args) == 2:
        c0 = c1 = get_int(args[0])
        r0 = r1 = get_int(args[1])
    elif len(args) == 4:
        c0, r0, c1, r1 = get_int(args[0]), get_int(args[1]), get_int(args[2]), get_int(args[3])
    else:
        raise TclError("wrong # args: should be \"grid bbox master ?column row ?column row??\"")
    if c0 > c1:
        c0, c1 = c1, c0
    if r0 > r1:
        r0, r1 = r1, r0

    def edge(slots, n, k):
        if k < 0:
            return 0
        if k >= n:
            return slots[n - 1].offset
        return slots[k].offset

    x = edge(gm.cols, nc, c0 - 1) if c0 > 0 else 0
    y = edge(gm.rows, nr, r0 - 1) if r0 > 0 else 0
    if c0 >= nc:
        w = 0
        x = gm.cols[nc - 1].offset
    else:
        w = edge(gm.cols, nc, c1) - x
    if r0 >= nr:
        h = 0
        y = gm.rows[nr - 1].offset
    else:
        h = edge(gm.rows, nr, r1) - y
    return (x + gm.startx, y + gm.starty, w, h)


def grid_location(m, x, y):
    gm = grid_master(m)
    grid_layout(m)
    nc = max(gm.colend, gm.constraint_count("column"))
    nr = max(gm.rowend, gm.constraint_count("row"))
    x -= gm.startx
    y -= gm.starty
    col = -1
    if x >= 0 and nc > 0:
        col = 0
        while col < nc and gm.cols[col].offset <= x:
            col += 1
    row = -1
    if y >= 0 and nr > 0:
        row = 0
        while row < nr and gm.rows[row].offset <= y:
            row += 1
    return (col, row)


def grid_rowcol_configure(app, m, kind, index, args):
    gm = grid_master(m)
    idxs = []
    for it in split_list(index) if not isinstance(index, int) else [index]:
        if it == "all":
            for s in m.grid_slaves:
                i = s.minfo
                a = i.column if kind == "column" else i.row
                n = i.columnspan if kind == "column" else i.rowspan
                for k in range(a, a + n):
                    if k not in idxs:
                        idxs.append(k)
            continue
        try:
            k = get_int(it)
        except TclError:
            if it.startswith("."):
                s = app.window(it)
                if s.manager != "grid" or s.gmaster is not m:
                    raise TclError("the window \"" + it + "\" is not managed by \"" + m.path + "\"")
                i = s.minfo
                a = i.column if kind == "column" else i.row
                n = i.columnspan if kind == "column" else i.rowspan
                for k in range(a, a + n):
                    idxs.append(k)
                continue
            raise TclError("expected integer but got \"" + it + "\" (when retrieving options only integer indices are allowed)")
        if k < 0:
            raise TclError(kind + " index must be non-negative" if False else "bad " + kind + " index \"" + it + "\"")
        idxs.append(k)
    names = ["-minsize", "-pad", "-uniform", "-weight"]
    if len(args) == 0:
        if len(idxs) != 1:
            raise TclError("must specify a single element on retrieval")
        lst = gm.ensure(kind, idxs[0] + 1)
        s = lst[idxs[0]]
        return ("-minsize", s.minsize, "-pad", s.pad, "-uniform", s.uniform if s.uniform != "" else "", "-weight", s.weight)
    if len(args) == 1:
        if len(idxs) != 1:
            raise TclError("must specify a single element on retrieval")
        lst = gm.ensure(kind, idxs[0] + 1)
        s = lst[idxs[0]]
        k = match_prefix(tcl_str(args[0]), names, "option")
        if k == "-minsize":
            return s.minsize
        if k == "-pad":
            return s.pad
        if k == "-uniform":
            return s.uniform
        return s.weight
    if len(args) % 2 != 0:
        raise TclError("wrong # args")
    for idx in idxs:
        lst = gm.ensure(kind, idx + 1)
        s = lst[idx]
        for j in range(0, len(args), 2):
            k = match_prefix(tcl_str(args[j]), names, "option")
            v = args[j + 1]
            if k == "-minsize":
                n = pixels(v)
                if n < 0:
                    raise TclError("invalid arg \"-minsize\": should be non-negative")
                s.minsize = n
            elif k == "-pad":
                n = pixels(v)
                if n < 0:
                    raise TclError("invalid arg \"-pad\": should be non-negative")
                s.pad = n
            elif k == "-uniform":
                s.uniform = tcl_str(v)
            else:
                n = get_int(v)
                if n < 0:
                    raise TclError("invalid arg \"-weight\": should be non-negative")
                s.weight = n
    app.relayout()
    return ""


def grid_size(m):
    gm = grid_master(m)
    set_grid_size(m)
    return (max(gm.colend, gm.constraint_count("column")), max(gm.rowend, gm.constraint_count("row")))


# ── place ────────────────────────────────────────────────────────────────────

class PlaceInfo:
    def __init__(self):
        self.x = 0
        self.y = 0
        self.relx = 0.0
        self.rely = 0.0
        self.width = None
        self.height = None
        self.relwidth = None
        self.relheight = None
        self.anchor = "nw"
        self.bordermode = "inside"
        self.xs = 0
        self.ys = 0


_PLACE_OPTS = ["-anchor", "-bordermode", "-height", "-in", "-relheight", "-relwidth", "-relx", "-rely",
               "-width", "-x", "-y"]


def place_configure(app, slave, args):
    if len(args) % 2 != 0:
        raise TclError("value for \"" + tcl_str(args[-1]) + "\" missing")
    if slave.IS_TOPLEVEL:
        raise TclError("can't use placer on top-level window \"" + slave.path + "\"; use wm command instead")
    info = slave.minfo if slave.manager == "place" else PlaceInfo()
    master = slave.gmaster if slave.manager == "place" else None
    for i in range(0, len(args), 2):
        k = match_prefix(tcl_str(args[i]), _PLACE_OPTS, "option")
        v = args[i + 1]
        if k == "-x":
            info.x = pixels(v)
            info.xs = v
        elif k == "-y":
            info.y = pixels(v)
            info.ys = v
        elif k == "-relx":
            info.relx = get_double(v)
        elif k == "-rely":
            info.rely = get_double(v)
        elif k == "-width":
            info.width = None if tcl_str(v) == "" else pixels(v)
        elif k == "-height":
            info.height = None if tcl_str(v) == "" else pixels(v)
        elif k == "-relwidth":
            info.relwidth = None if tcl_str(v) == "" else get_double(v)
        elif k == "-relheight":
            info.relheight = None if tcl_str(v) == "" else get_double(v)
        elif k == "-anchor":
            info.anchor = match_prefix(tcl_str(v), ["n", "ne", "e", "se", "s", "sw", "w", "nw", "center"], "anchor")
        elif k == "-bordermode":
            info.bordermode = match_prefix(tcl_str(v), ["ignore", "inside", "outside"], "bordermode")
        elif k == "-in":
            master = app.window(v)
    if master is None:
        master = slave.parent
    if master is not slave.parent:
        anc = slave.parent
        w = master
        while w is not None and w is not anc:
            if w.IS_TOPLEVEL:
                raise TclError("can't place " + slave.path + " relative to " + master.path)
            w = w.parent
        if w is None:
            raise TclError("can't place " + slave.path + " relative to " + master.path)
    if master is slave:
        raise TclError("can't place " + slave.path + " relative to itself")
    if slave.manager != "" and not (slave.manager == "place" and slave.gmaster is master):
        unmanage(app, slave)
    slave.minfo = info
    if not (slave.manager == "place" and slave.gmaster is master):
        master.place_slaves.append(slave)
    slave.manager = "place"
    slave.gmaster = master
    app.relayout()
    return ""


def place_info(app, slave):
    # PlaceInfoCommand builds a string (Tcl_AppendPrintfToObj, "%.4g" for
    # the relative values), so tkinter's place_info() gives strings
    if slave.manager != "place":
        return ""
    i = slave.minfo
    out = "-in " + quote_elem(slave.gmaster.path) + " "
    out += "-x %d -relx %.4g -y %d -rely %.4g" % (i.x, i.relx, i.y, i.rely)
    out += (" -width %d" % i.width) if i.width is not None else " -width {}"
    out += (" -relwidth %.4g" % i.relwidth) if i.relwidth is not None else " -relwidth {}"
    out += (" -height %d" % i.height) if i.height is not None else " -height {}"
    out += (" -relheight %.4g" % i.relheight) if i.relheight is not None else " -relheight {}"
    return out + " -anchor " + i.anchor + " -bordermode " + i.bordermode


def place_arrange(app, m):
    for s in m.place_slaves:
        i = s.minfo
        mx = 0
        my = 0
        mw = m.width
        mh = m.height
        if i.bordermode == "inside":
            mx = m.ib[0]
            my = m.ib[1]
            mw -= mx + m.ib[2]
            mh -= my + m.ib[3]
        elif i.bordermode == "outside":
            mx = 0
            my = 0
        x1 = i.x + mx + i.relx * mw
        x = int(x1 + 0.5) if x1 > 0 else int(x1 - 0.5)
        y1 = i.y + my + i.rely * mh
        y = int(y1 + 0.5) if y1 > 0 else int(y1 - 0.5)
        if i.width is not None or i.relwidth is not None:
            w = 0
            if i.width is not None:
                w += i.width
            if i.relwidth is not None:
                x2 = x1 + i.relwidth * mw
                t = int(x2 + 0.5) if x2 > 0 else int(x2 - 0.5)
                w += t - x
        else:
            w = s.reqw
        if i.height is not None or i.relheight is not None:
            h = 0
            if i.height is not None:
                h += i.height
            if i.relheight is not None:
                y2 = y1 + i.relheight * mh
                t = int(y2 + 0.5) if y2 > 0 else int(y2 - 0.5)
                h += t - y
        else:
            h = s.reqh
        a = i.anchor
        if a == "n":
            x -= cdiv(w, 2)
        elif a == "ne":
            x -= w
        elif a == "e":
            x -= w
            y -= cdiv(h, 2)
        elif a == "se":
            x -= w
            y -= h
        elif a == "s":
            x -= cdiv(w, 2)
            y -= h
        elif a == "sw":
            y -= h
        elif a == "w":
            y -= cdiv(h, 2)
        elif a == "center":
            x -= cdiv(w, 2)
            y -= cdiv(h, 2)
        if w <= 0:
            w = 1
        if h <= 0:
            h = 1
        app.place_slave(m, s, x, y, w, h, True)
