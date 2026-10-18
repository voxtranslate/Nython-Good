# nython: module    (import it by name: it runs in a module scope of its own)
# lib/_curses_panel.ny - CPython's _curses_panel (round 84): panel stacks
# over Nython's curses (lib/_curses.ny), with ncurses' panel library's
# algorithms (panel/p_*.c): the deck has stdscr as its bottom pseudo-panel;
# hide/bottom/move/replace touch what the panel covered (PANEL_UPDATE) so
# update_panels() redraws the panels and stdscr under it; update_panels()
# carries each panel's touched lines up to the panels above that overlap it
# and then noutrefreshes, bottom to top, every touched panel and the top
# one.
#
#     import curses, curses.panel
#     p = curses.panel.new_panel(win)
#     p.top(); p.move(3, 4); p.hide()
#     curses.panel.update_panels(); curses.doupdate()
#
# new_panel(win), bottom_panel(), top_panel(), update_panels(), version,
# error; panel objects: above(), below(), bottom(), top(), hide(), show(),
# hidden(), move(y, x), replace(win), window(), set_userptr(obj),
# userptr().
#
# Not here: nothing of CPython's module.

import _curses

version = b"2.1"
__version__ = version


class error(_curses.error):
    pass


error.__module__ = "_curses_panel"

_deck = []          # bottom to top, without the stdscr pseudo-panel
_TOKEN = object()


class panel:
    """A panel: a window in the deck."""

    def __init__(self, *args):
        if len(args) != 2 or args[0] is not _TOKEN:
            raise TypeError("cannot create '_curses_panel.panel' instances")
        self._win = args[1]
        self._user = _TOKEN
        self._linked = False

    def __repr__(self):
        return "<_curses_panel.panel object at 0x%x>" % id(self)

    def window(self):
        return self._win

    def above(self):
        if not self._linked:
            return None
        i = _deck.index(self)
        if i + 1 < len(_deck):
            return _deck[i + 1]
        return None

    def below(self):
        if not self._linked:
            return None
        i = _deck.index(self)
        if i > 0:
            return _deck[i - 1]
        return None

    def hidden(self):
        return not self._linked

    def hide(self):
        _hide(self)
        return None

    def show(self):
        _show(self)
        return None

    def top(self):
        _show(self)
        return None

    def bottom(self):
        if _deck and _deck[0] is self:
            return None
        _hide(self)
        _deck.insert(0, self)
        self._linked = True
        return None

    def move(self, y, x):
        if self._linked:
            self._win.touchwin()
            _panel_update(self)
        try:
            self._win.mvwin(y, x)
        except _curses.error:
            raise error("move_panel() returned ERR")
        return None

    def replace(self, win):
        if not isinstance(win, _curses.window):
            raise TypeError("replace() argument must be _curses.window, not %s" % type(win).__name__)
        if self._linked:
            self._win.touchwin()
            _panel_update(self)
        self._win = win
        return None

    def set_userptr(self, obj):
        self._user = obj
        return None

    def userptr(self):
        if self._user is _TOKEN:
            raise error("no userptr set")
        return self._user


def _box(w):
    by, bx = w.getbegyx()
    my, mx = w.getmaxyx()
    return (by, bx, by + my, bx + mx)


def _stack():
    s = _curses._stdscr
    out = []
    if s is not None:
        out.append(s)
    for p in _deck:
        out.append(p._win)
    return out


def _touch_overlap(src, dst):
    # the lines of dst under the touched lines of src
    a = _box(src)
    b = _box(dst)
    iy1 = max(a[0], b[0])
    iy2 = min(a[2], b[2])
    ix1 = max(a[1], b[1])
    ix2 = min(a[3], b[3])
    if iy1 >= iy2 or ix1 >= ix2:
        return
    for y in range(iy1, iy2):
        if src.is_linetouched(y - a[0]):
            _curses_touch(dst._id, "range", y - b[0], ix1 - b[1], ix2 - 1 - b[1])


def _panel_update(pan, start=0):
    # PANEL_UPDATE(pan, start): every other window in the deck from `start`
    w = pan._win if isinstance(pan, panel) else pan
    st = _stack()
    for other in st[start:]:
        if other is not w:
            _touch_overlap(w, other)


def _hide(pan):
    if pan._linked:
        pan._win.touchwin()
        _panel_update(pan)
        _deck.remove(pan)
        pan._linked = False


def _show(pan):
    if _deck and _deck[-1] is pan:
        return
    if pan._linked:
        pan._win.touchwin()
        _deck.remove(pan)
    _deck.append(pan)
    pan._linked = True


def new_panel(win):
    if not isinstance(win, _curses.window):
        raise TypeError("new_panel() argument must be _curses.window, not %s" % type(win).__name__)
    p = panel(_TOKEN, win)
    _show(p)
    return p


def bottom_panel():
    _curses._initialised()
    return _deck[0] if _deck else None


def top_panel():
    _curses._initialised()
    return _deck[-1] if _deck else None


def update_panels():
    _curses._initialised()
    st = _stack()
    for i in range(len(st) - 1):
        for other in st[i + 1:]:
            _touch_overlap(st[i], other)
    for i in range(len(st)):
        w = st[i]
        if w.is_wintouched() or i == len(st) - 1:
            w.noutrefresh()
    return None
