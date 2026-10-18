# nython: module    (part of the tkinter package: lib/tkinter/)
# dialog.py -- Tkinter interface to the tk_dialog script.
#
# lib/tkinter/dialog.ny - CPython 3.12's Lib/tkinter/dialog.py over
# Nython's tk_dialog (lib/_tkinter/dialogs.ny). Round 84.

from tkinter import _cnfmerge, Widget, TclError, Button, Pack

__all__ = ["Dialog", "DIALOG_ICON"]

DIALOG_ICON = 'questhead'


class Dialog(Widget):
    def __init__(self, master=None, cnf={}, **kw):
        cnf = _cnfmerge((cnf, kw))
        self.widgetName = '__dialog__'
        self._setup(master, cnf)
        self.num = self.tk.getint(
                self.tk.call(
                      'tk_dialog', self._w,
                      cnf['title'], cnf['text'],
                      cnf['bitmap'], cnf['default'],
                      *cnf['strings']))
        try: Widget.destroy(self)
        except TclError: pass

    def destroy(self): pass
