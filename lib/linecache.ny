# nython: module    (import it by name: it runs in a module scope of its own)
# lib/linecache.ny - Python's linecache: lines of source files, cached, for
# tracebacks (lib/traceback.ny) and warnings (lib/warnings.ny).
#
#     import linecache
#     linecache.getline("prog.ny", 3)     # the line with its "\n", or ""
#
# getline(filename, lineno, module_globals=None)   one line ("" when there
#                           is none: no such file or line)
# getlines(filename, module_globals=None)   every line of the file, each
#                           ending in "\n" (a last line without one gets it)
# updatecache(filename, module_globals=None)   (re)reads the file
# checkcache(filename=None) drops entries whose file changed (size or
#                           modification time) or went away
# clearcache()              empties the cache
# lazycache(filename, module_globals)   False: there are no lazily loaded
#                           sources (module loaders) here
# cache                     {filename: (size, mtime, lines, fullname)}
#
# Not here: the search of sys.path for a relative name and loading source
# through a module's __loader__ (the runtime has neither); a name like
# "<string>" has no lines (as in Python). Files are read as UTF-8 text.

import os

__all__ = ["getline", "clearcache", "checkcache", "lazycache"]

cache = {}


def clearcache():
    """Clear the cache entirely."""
    cache.clear()


def getline(filename, lineno, module_globals=None):
    """Get a line for a Python source file from the cache.
    Update the cache if it doesn't contain an entry for this file already."""
    var lines = getlines(filename, module_globals)
    if 1 <= lineno and lineno <= len(lines):
        return lines[lineno - 1]
    return ""


def getlines(filename, module_globals=None):
    """Get the lines for a Python source file from the cache.
    Update the cache if it doesn't contain an entry for this file already."""
    if filename in cache:
        var entry = cache[filename]
        if len(entry) != 1:
            return entry[2]
    try:
        return updatecache(filename, module_globals)
    except MemoryError:
        clearcache()
        return []


def _stat(fullname):
    # (size, mtime) of a file, or None
    try:
        var st = os.stat(fullname)
        if isinstance(st, dict):
            if not st.get("exists", True) or st.get("is_dir", False):
                return None
            return (st["size"], st["mtime"])
        return (st.st_size, st.st_mtime)
    except Exception:
        return None


def checkcache(filename=None):
    """Discard cache entries that are out of date.
    (This is not checked upon each call!)"""
    var filenames = []
    if filename is None:
        filenames = list(cache.keys())
    elif filename in cache:
        filenames = [filename]
    else:
        return
    for name in filenames:
        var entry = cache[name]
        if len(entry) == 1:
            # lazy cache entry, leave it lazy.
            continue
        var size = entry[0]
        var mtime = entry[1]
        if mtime is None:
            continue   # no-op for files loaded via a __loader__
        var st = _stat(entry[3])
        if st is None or size != st[0] or mtime != st[1]:
            cache.pop(name, None)


def updatecache(filename, module_globals=None):
    """Update a cache entry and return its list of lines.
    If something's wrong, print a message, discard the cache entry,
    and return an empty list."""
    if filename in cache:
        if len(cache[filename]) != 1:
            cache.pop(filename, None)
    if not filename or (filename.startswith("<") and filename.endswith(">")):
        return []
    var fullname = filename
    var st = _stat(fullname)
    if st is None:
        return []
    var lines = []
    try:
        var f = open(fullname, "r", encoding="utf-8")
        var text = f.read()
        f.close()
        lines = text.splitlines(True)
    except Exception:
        return []
    if len(lines) > 0 and not lines[-1].endswith("\n"):
        lines[-1] = lines[-1] + "\n"
    cache[filename] = (st[0], st[1], lines, fullname)
    return lines


def lazycache(filename, module_globals):
    """Seed the cache for filename with module_globals.
    There are no lazily loaded sources here: False."""
    if filename in cache:
        if len(cache[filename]) == 1:
            return True
        return False
    return False
