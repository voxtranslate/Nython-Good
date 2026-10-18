# nython: module
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# gc - Python's interface to the garbage collector, over the engines' own
# (round 82). Both engines free objects by reference counting and collect
# cycles with a generational collector (round 75, GC_NOTES.md); the native
# builtins gc_collect/gc_enable/gc_disable/gc_is_enabled/gc_get_threshold/
# gc_set_threshold/gc_stats are what this module is made of.
#
# Provided: enable, disable, isenabled, collect(generation=2) (with the
# `callbacks` called "start"/"stop" around it, as CPython), get_count,
# get_threshold, set_threshold, get_stats, garbage (always empty: the
# collectors free uncollectable cycles with __del__ too, PEP 442), callbacks,
# is_tracked, is_finalized, freeze/unfreeze/get_freeze_count, get_debug/
# set_debug and the DEBUG_* constants.
#
# Differences from CPython, honestly:
#   - collect(generation) always runs a full collection (the engines'
#     gc_collect); its result is the number of objects the collection freed;
#   - get_count() gives the objects tracked in each generation, not the
#     allocations since the last collection;
#   - get_stats() reports collections per generation; "collected" and
#     "uncollectable" totals are attributed to the oldest generation;
#   - is_tracked() answers by kind (atoms are not tracked, containers and
#     instances are), freeze() only counts, set_debug() only records flags;
#   - get_objects, get_referrers and get_referents are not provided (the
#     collectors do not expose their object lists).

DEBUG_STATS = 1
DEBUG_COLLECTABLE = 2
DEBUG_UNCOLLECTABLE = 4
DEBUG_SAVEALL = 32
DEBUG_LEAK = DEBUG_COLLECTABLE | DEBUG_UNCOLLECTABLE | DEBUG_SAVEALL

garbage = []
callbacks = []

_debug = 0
_frozen = 0

def enable():
    gc_enable()

def disable():
    gc_disable()

def isenabled():
    return gc_is_enabled()

def collect(generation=2):
    if not isinstance(generation, int) or isinstance(generation, bool):
        raise TypeError("'" + type(generation).__name__ + "' object cannot be interpreted as an integer")
    if generation < 0 or generation > 2:
        raise ValueError("invalid generation")
    _run_callbacks("start", {"generation": generation, "collected": 0, "uncollectable": 0})
    var n = gc_collect()
    if not isinstance(n, int):
        n = 0
    _run_callbacks("stop", {"generation": generation, "collected": n, "uncollectable": 0})
    return n

def _run_callbacks(phase, info):
    for cb in list(callbacks):
        cb(phase, info)

def get_count():
    var s = gc_stats()
    return (s.get("gen0", 0), s.get("gen1", 0), s.get("gen2", 0))

def get_threshold():
    return tuple(gc_get_threshold())

def set_threshold(threshold0, threshold1=None, threshold2=None):
    if threshold1 is None and threshold2 is None:
        var cur = gc_get_threshold()
        gc_set_threshold(threshold0, cur[1], cur[2])
    elif threshold2 is None:
        gc_set_threshold(threshold0, threshold1, gc_get_threshold()[2])
    else:
        gc_set_threshold(threshold0, threshold1, threshold2)

def get_stats():
    var s = gc_stats()
    var per = s.get("collections_per_gen", [0, 0, 0])
    var out = []
    var i = 0
    while i < 3:
        var d = {"collections": per[i] if i < len(per) else 0, "collected": 0, "uncollectable": 0}
        if i == 2:
            d["collected"] = s.get("collected", 0)
            d["uncollectable"] = s.get("uncollectable", 0)
        out.append(d)
        i = i + 1
    return out

def is_tracked(obj):
    # atoms hold no references, so no collector tracks them (CPython's rule
    # for its own atoms; empty dicts/tuples untracked lazily is not modelled)
    if obj is None or isinstance(obj, (bool, int, float, complex, str, bytes)):
        return False
    return True

def is_finalized(obj):
    return False

def freeze():
    global _frozen
    _frozen = _frozen + gc_stats().get("tracked", 0)

def unfreeze():
    global _frozen
    _frozen = 0

def get_freeze_count():
    return _frozen

def get_debug():
    return _debug

def set_debug(flags):
    global _debug
    if not isinstance(flags, int):
        raise TypeError("'" + type(flags).__name__ + "' object cannot be interpreted as an integer")
    _debug = flags
