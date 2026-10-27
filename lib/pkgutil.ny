# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/pkgutil.ny - pkgutil, CPython 3.11's API over importlib (round 80).
#
# iter_modules(path=None, prefix="")   ModuleInfo(module_finder, name, ispkg)
#               for the modules and packages in the given directories (or on
#               sys.path), sorted per directory, the first of a name only;
#               a directory counts as a package when it holds __init__.ny
# walk_packages(path=None, prefix="", onerror=None)  the same, recursively:
#               each package is imported to read its __path__ (ImportErrors
#               go to onerror or are ignored, as CPython)
# get_importer(path_item)   sys.path_importer_cache, sys.path_hooks, else a
#               FileFinder for a directory (the import statement's own search)
# iter_importers(fullname="")  sys.meta_path's finders, then one per sys.path
#               entry (a dotted name: its package's __path__)
# get_loader(module_or_name), find_loader(fullname)  a loader through
#               importlib.util.find_spec
# get_data(package, resource)  a resource file of a package, as bytes
# resolve_name(name)  "pkg.mod:obj.attr" or "pkg.mod.obj" to the object
# extend_path(path, name)  a package's __path__ with the same-named
#               directories of sys.path (and *.pkg files) appended
# ModuleInfo, read_code (None: Nython has no bytecode files)
#
# Not here: ImpImporter / ImpLoader (the removed imp module's), zipimport
# (no zip imports).
import os
import sys
import importlib
import importlib.util
import importlib.machinery
from collections import namedtuple

__all__ = [
    "get_importer", "iter_importers", "get_loader", "find_loader",
    "walk_packages", "iter_modules", "get_data", "read_code", "extend_path",
    "ModuleInfo",
]


ModuleInfo = namedtuple("ModuleInfo", "module_finder name ispkg")
ModuleInfo.__doc__ = "A namedtuple with minimal info about a module."


def read_code(stream):
    # CPython reads a .pyc here; Nython has no bytecode files
    return None


def _module_name_of(filename):
    # inspect.getmodulename for the suffixes the engines import
    for suffix in importlib.machinery.all_suffixes():
        if filename.endswith(suffix) and len(filename) > len(suffix):
            return filename[:len(filename) - len(suffix)]
    return None


def _iter_file_finder_modules(importer, prefix=""):
    if importer.path is None or not os.path.isdir(importer.path):
        return
    yielded = {}
    try:
        filenames = os.listdir(importer.path)
    except OSError:
        filenames = []
    filenames.sort()   # packages before same-named modules
    for fn in filenames:
        modname = _module_name_of(fn)
        if modname == "__init__" or modname in yielded:
            continue
        path = os.path.join(importer.path, fn)
        ispkg = False
        if not modname and os.path.isdir(path) and "." not in fn:
            modname = fn
            try:
                dircontents = os.listdir(path)
            except OSError:
                dircontents = []
            for sub in dircontents:
                if _module_name_of(sub) == "__init__":
                    ispkg = True
                    break
            if not ispkg:
                continue   # not a package
        if modname and "." not in modname:
            yielded[modname] = 1
            yield prefix + modname, ispkg


def iter_importer_modules(importer, prefix=""):
    if isinstance(importer, importlib.machinery.FileFinder):
        return _iter_file_finder_modules(importer, prefix)
    if not hasattr(importer, "iter_modules"):
        return []
    return importer.iter_modules(prefix)


def iter_modules(path=None, prefix=""):
    """Yields ModuleInfo for all submodules on path,
    or, if path is None, all top-level modules on sys.path."""
    if path is None:
        importers = iter_importers()
    elif isinstance(path, str):
        raise ValueError("path must be None or list of paths to look for modules in")
    else:
        importers = map(get_importer, path)
    yielded = {}
    for i in importers:
        for name, ispkg in iter_importer_modules(i, prefix):
            if name not in yielded:
                yielded[name] = 1
                yield ModuleInfo(i, name, ispkg)


def walk_packages(path=None, prefix="", onerror=None):
    """Yields ModuleInfo for all modules recursively on path, or, if path is
    None, all accessible modules."""
    seen_paths = {}

    def seen(p):
        if p in seen_paths:
            return True
        seen_paths[p] = True
        return False

    for info in iter_modules(path, prefix):
        yield info
        if info.ispkg:
            try:
                __import__(info.name)
            except ImportError:
                if onerror is not None:
                    onerror(info.name)
            except Exception:
                if onerror is not None:
                    onerror(info.name)
                else:
                    raise
            else:
                sub_path = getattr(sys.modules[info.name], "__path__", None) or []
                sub_path = [p for p in sub_path if not seen(p)]
                yield from walk_packages(sub_path, info.name + ".", onerror)


def _fsdecode(p):
    # os.fsdecode
    if hasattr(p, "__fspath__") and not isinstance(p, (str, bytes)):
        p = p.__fspath__()
    if isinstance(p, bytes):
        try:
            return p.decode("utf-8", "surrogateescape")
        except LookupError:
            return p.decode("utf-8", "replace")
    return p


def get_importer(path_item):
    """Retrieve a finder for the given path item."""
    path_item = _fsdecode(path_item)
    cache = getattr(sys, "path_importer_cache", None)
    if cache is not None and path_item in cache:
        return cache[path_item]
    importer = None
    for path_hook in getattr(sys, "path_hooks", []):
        try:
            importer = path_hook(path_item)
            break
        except ImportError:
            importer = None
    if importer is None and os.path.isdir(path_item or "."):
        # the import statement's own search of a directory
        importer = importlib.machinery.FileFinder(path_item)
    if importer is not None and cache is not None:
        cache.setdefault(path_item, importer)
    return importer


def iter_importers(fullname=""):
    """Yield finders for the given module name."""
    if fullname.startswith("."):
        raise ImportError("Relative module name " + repr(fullname) + " not supported")
    if "." in fullname:
        pkg_name = fullname.rpartition(".")[0]
        pkg = importlib.import_module(pkg_name)
        path = getattr(pkg, "__path__", None)
        if path is None:
            return
    else:
        yield from getattr(sys, "meta_path", [])
        path = sys.path
    for item in path:
        yield get_importer(item)


def find_loader(fullname):
    """Find a "loader" object for fullname."""
    if fullname.startswith("."):
        raise ImportError("Relative module name " + repr(fullname) + " not supported")
    try:
        spec = importlib.util.find_spec(fullname)
    except (ImportError, AttributeError, TypeError, ValueError) as ex:
        raise ImportError("Error while finding loader for " + repr(fullname) + " (" + str(type(ex)) + ": " + str(ex) + ")") from ex
    return spec.loader if spec is not None else None


def get_loader(module_or_name):
    """Get a "loader" object for module_or_name (None if it cannot be found)."""
    if isinstance(module_or_name, str) and module_or_name in sys.modules:
        module_or_name = sys.modules[module_or_name]
        if module_or_name is None:
            return None
    if not isinstance(module_or_name, str):
        module = module_or_name
        loader = getattr(module, "__loader__", None)
        if loader is not None:
            return loader
        fullname = getattr(module, "__name__", None)
        if fullname is None:
            return None
    else:
        fullname = module_or_name
    return find_loader(fullname)


def extend_path(path, name):
    """Extend a package's path with the same-named directories of sys.path."""
    if not isinstance(path, list):
        return path
    sname_pkg = name + ".pkg"
    path = path[:]
    parent_package, _, final_name = name.rpartition(".")
    if parent_package:
        try:
            search_path = sys.modules[parent_package].__path__
        except (KeyError, AttributeError):
            return path
    else:
        search_path = sys.path
    for dir in search_path:
        if not isinstance(dir, str):
            continue
        finder = get_importer(dir)
        if finder is not None and hasattr(finder, "find_spec"):
            spec = finder.find_spec(final_name)
            portions = []
            if spec is not None:
                portions = spec.submodule_search_locations or []
            for portion in portions:
                if portion not in path:
                    path.append(portion)
        pkgfile = os.path.join(dir, sname_pkg)
        if os.path.isfile(pkgfile):
            try:
                f = open(pkgfile)
            except OSError as msg:
                sys.stderr.write("Can't open %s: %s\n" % (pkgfile, msg))
            else:
                with f:
                    for line in f:
                        line = line.rstrip("\n")
                        if not line or line.startswith("#"):
                            continue
                        path.append(line)   # not checked for existence, as CPython
    return path


def get_data(package, resource):
    """Get a resource from a package, as bytes (None when it cannot be loaded)."""
    spec = importlib.util.find_spec(package)
    if spec is None:
        return None
    loader = spec.loader
    if loader is None or not hasattr(loader, "get_data"):
        return None
    mod = sys.modules.get(package) or importlib.import_module(package)
    if mod is None or not hasattr(mod, "__file__"):
        return None
    parts = resource.split("/")
    parts.insert(0, os.path.dirname(mod.__file__))
    return loader.get_data(os.path.join(*parts))


_NAME_PATTERN = None


def resolve_name(name):
    """Resolve a name ("pkg.mod:obj.attr" or "pkg.mod.obj") to an object."""
    global _NAME_PATTERN
    if _NAME_PATTERN is None:
        import re
        dotted_words = r"(?!\d)(\w+)(\.(?!\d)(\w+))*"
        _NAME_PATTERN = re.compile("^(?P<pkg>" + dotted_words + ")(?P<cln>:(?P<obj>" + dotted_words + ")?)?$", re.UNICODE)
    m = _NAME_PATTERN.match(name)
    if not m:
        raise ValueError("invalid format: " + repr(name))
    gd = m.groupdict()
    if gd.get("cln"):
        mod = importlib.import_module(gd["pkg"])
        parts = gd.get("obj")
        parts = parts.split(".") if parts else []
    else:
        parts = name.split(".")
        modname = parts.pop(0)
        mod = importlib.import_module(modname)
        while parts:
            p = parts[0]
            s = modname + "." + p
            try:
                mod = importlib.import_module(s)
                parts.pop(0)
                modname = s
            except ImportError:
                break
    result = mod
    for p in parts:
        result = getattr(result, p)
    return result
