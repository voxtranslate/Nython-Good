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
#   - is_tracked() answers by kind as CPython 3.11 untracks (atoms, empty
#     tuples and dicts holding only atoms are not tracked; containers and
#     instances are), freeze() only counts, set_debug() only records flags;
#   - get_objects(generation) (round 85) lists the collector's own tracked
#     objects on the interpreter (src/NyGC.cpp: lists, dicts, sets, tuples,
#     modules, generators, instances, functions, bound methods - not the
#     engine's scopes); on the VM, which tracks containers by weak pointer,
#     the containers, instances, generators and functions the live tracked
#     containers and the globals hold (src/VMGC.cpp). Objects a native holds
#     only from C++ are not listed;
#   - get_referents (round 85) follows CPython's traversal order for the
#     builtin containers (a list's and a tuple's items last first, a dict's
#     values - and keys when one is not a str -, a set's items) and gives an
#     instance's attribute values then its class, a function's code,
#     globals, defaults and closure cells' contents; get_referrers scans
#     get_objects() and the modules' namespaces (CPython's module dicts).

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

def _atom(obj):
    return obj is None or isinstance(obj, (bool, int, float, complex, str, bytes))

def is_tracked(obj):
    # atoms hold no references, so no collector tracks them (CPython's rule
    # for its own atoms); CPython 3.11 also never tracks an empty tuple, and
    # tracks a dict only once it holds something that can be tracked
    if _atom(obj):
        return False
    if type(obj) is tuple and len(obj) == 0:
        return False
    if type(obj) is dict:
        for k in obj:
            if not _atom(k) or not _atom(obj[k]):
                return True
        return False
    return True

# ── round 85: get_objects, get_referents, get_referrers ──────────────────
def get_objects(generation=None):
    _ny_sys_audit("gc.get_objects", -1 if generation is None else generation)
    var g = -1
    if generation is not None:
        if isinstance(generation, bool) or not isinstance(generation, int):
            raise TypeError("argument should be integer or None, not '" + type(generation).__name__ + "'")
        if generation >= 3:
            raise ValueError("generation parameter must be less than the number of available generations (3)")
        if generation < -1:
            raise ValueError("generation parameter cannot be negative")
        g = generation
    return _objects(g)

def _objects(g):
    var out = list(_ny_gc_objects(g))
    if g == -1 or g == 2:
        # what the running frames and the modules hold directly, when the
        # collector's lists miss it (the VM tracks containers it reaches
        # from other containers; a frame's variables are no container)
        var seen = set()
        for o in out:
            seen.add(id(o))
        def take(v):
            if not _atom(v) and id(v) not in seen and type(v) is not _ModuleType:
                seen.add(id(v))
                out.append(v)
        var f = _sys._getframe(2)
        while f is not None:
            for v in list(f.f_locals.values()):
                take(v)
            f = f.f_back
        for m in list(_sys.modules.values()):
            try:
                for v in list(vars(m).values()):
                    take(v)
            except TypeError:
                pass
    return out

import sys as _sys
_ModuleType = type(_sys)

def _referents(o):
    # an object the engine cannot take apart has none
    try:
        return _referents1(o)
    except (AttributeError, TypeError, ValueError, RuntimeError):
        return []

def _referents1(o):
    if _atom(o):
        return []
    var t = type(o)
    if t is _ModuleType:
        # CPython's module_traverse: its dict
        try:
            return [vars(o)]
        except TypeError:
            return []
    if isinstance(o, (list, tuple)):
        var r = list(o)
        r.reverse()
        return r
    if isinstance(o, (set, frozenset)):
        return list(o)
    if isinstance(o, dict):
        var all_str = True
        for k in o:
            if type(k) is not str:
                all_str = False
                break
        if all_str:
            return list(o.values())
        var out = []
        for k in o:
            out.append(o[k])
            out.append(k)
        return out
    if t.__name__ == "function":
        var out = []
        for name in ("__code__", "__globals__", "__module__", "__defaults__", "__kwdefaults__", "__doc__", "__name__",
                     "__dict__", "__closure__", "__annotations__", "__qualname__"):
            var v = getattr(o, name, None)
            if v is not None:
                out.append(v)
        return out
    if isinstance(o, type):
        var out = []
        for name in ("__dict__", "__mro__", "__bases__"):
            var v = getattr(o, name, None)
            if v is not None:
                out.append(v)
        return out
    var d = getattr(o, "__dict__", None)
    if isinstance(d, dict) or hasattr(d, "values"):
        var out = list(d.values())
        out.append(t)
        return out
    return [t]

def get_referents(*objs):
    _ny_sys_audit("gc.get_referents", objs)
    var out = []
    for o in objs:
        out.extend(_referents(o))
    return out

def get_referrers(*objs):
    _ny_sys_audit("gc.get_referrers", objs)
    if not objs:
        return []
    var ids = set()
    for o in objs:
        ids.add(id(o))
    var out = []
    var seen = set()
    var cands = _objects(-1)
    import sys
    for m in list(sys.modules.values()):
        try:
            cands.append(vars(m))
        except TypeError:
            pass
    for o in cands:
        if id(o) in ids or id(o) in seen:
            continue
        for r in _referents(o):
            if id(r) in ids:
                seen.add(id(o))
                out.append(o)
                break
    return out

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
