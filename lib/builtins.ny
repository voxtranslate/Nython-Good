# nython: module    (import it by name: it runs in a module scope of its own)
# lib/builtins.ny - the builtins module (round 80): every builtin function,
# type, exception and constant by name, as CPython's
#
#     import builtins
#     builtins.len is len; builtins.open; builtins.ValueError
#     builtins.print = my_print      # does not change the builtin (see below)
#
# The values are the runtime's own (the same objects the names give
# everywhere: f_builtins, sys._getframe().f_builtins). Not here: assigning
# to builtins.name does not rebind the builtin seen by other modules
# (Nython's builtins are not looked up through this module).
# (the registry itself, not sys.modules: sys's own setup imports this module
# for sys.modules["builtins"] before it has the attribute - round 84)
_ny_me = _ny_modules()[__name__]
for _ny_k, _ny_v in _ny_builtins_dict().items():
    if _ny_k not in ("__name__", "__file__", "__doc__", "__package__", "__path__"):
        setattr(_ny_me, _ny_k, _ny_v)
setattr(_ny_me, "__import__", __import__)
setattr(_ny_me, "__debug__", __debug__)
del _ny_me, _ny_k, _ny_v
