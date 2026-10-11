# nython: module    (a package: importlib.util, importlib.machinery, importlib.abc, importlib.resources)
# lib/importlib - Python's importlib (CPython 3.12's API) over the engines'
# own module loader (round 80).
#
#     import importlib
#     m = importlib.import_module("json")            # sys.modules["json"]
#     m = importlib.import_module(".decoder", "json") # relative to a package
#     importlib.reload(m)                            # re-runs the file in m
#     importlib.invalidate_caches()
#
# import_module(name, package=None)  CPython's rules and messages: a leading
#               "." needs `package` ("the 'package' argument is required to
#               perform a relative import for '.x'"), "attempted relative
#               import beyond top-level package", ModuleNotFoundError
#               "No module named 'x'"; the module comes from sys.modules
#               when it is there, else it is loaded and registered there
# reload(module)  the module's file run again in the same module object (its
#               old names stay unless rebound, as CPython); TypeError for a
#               non-module, ImportError "module x not in sys.modules";
#               a module with no file (sys, math, os) is returned as it is
# invalidate_caches()  calls invalidate_caches() of the finders on
#               sys.meta_path that have one (the engines keep no caches)
# __import__    the builtin
#
# How it sits on the engines: sys.modules is the engines' own registry - a
# real dict; `import` consults it first (an entry deleted there is loaded
# again, an object assigned there is what `import` binds) and registers what
# it loads. Modules are found where `import name` finds them: beside the
# importing file, sys.path's entries (sys.path.insert(0, d) is searched), the
# main script's directory, the working directory and its lib/, NYTHONPATH,
# the standard library (.ny files; a directory with __init__.ny is a package,
# one with .ny files and no __init__.ny a namespace package).
#
# Not here (honestly): sys.meta_path / sys.path_hooks finders are not
# consulted by the engines' import statement (importlib.util.find_spec does
# ask the meta-path finders a program installs); no bytecode cache
# (sys.implementation.cache_tag is None, so cache_from_source raises
# NotImplementedError as CPython does then); no frozen or extension modules;
# zipimport; importlib.metadata.
import sys as _sys

__all__ = ["__import__", "import_module", "invalidate_caches", "reload"]

__import__ = __import__


def _resolve_name(name, package, level):
    bits = package.rsplit(".", level - 1)
    if len(bits) < level:
        raise ImportError("attempted relative import beyond top-level package")
    base = bits[0]
    return base + "." + name if name else base


def _sanity_check(name, package, level):
    if not isinstance(name, str):
        raise TypeError("module name must be str, not " + type(name).__name__)
    if level < 0:
        raise ValueError("level must be >= 0")
    if level > 0:
        if not isinstance(package, str):
            raise TypeError("__package__ not set to a string")
        elif not package:
            raise ImportError("attempted relative import with no known parent package")
    if not name and level == 0:
        raise ValueError("Empty module name")


def _gcd_import(name, package=None, level=0):
    _sanity_check(name, package, level)
    if level > 0:
        name = _resolve_name(name, package, level)
    return _ny_import_module(name)


def import_module(name, package=None):
    """Import a module.

    The 'package' argument is required when performing a relative import. It
    specifies the package to use as the anchor point from which to resolve the
    relative import to an absolute import.

    """
    level = 0
    if name.startswith("."):
        if not package:
            raise TypeError("the 'package' argument is required to perform a relative "
                            "import for " + repr(name))
        for character in name:
            if character != ".":
                break
            level += 1
    return _gcd_import(name[level:], package, level)


def invalidate_caches():
    """Call the invalidate_caches() method on all meta path finders stored in
    sys.meta_path (where implemented)."""
    for finder in _sys.meta_path:
        if hasattr(finder, "invalidate_caches"):
            finder.invalidate_caches()


def reload(module):
    """Reload the module and return it.

    The module must have been successfully imported before.

    """
    try:
        name = module.__spec__.name
    except AttributeError:
        try:
            name = module.__name__
        except AttributeError:
            raise TypeError("reload() argument must be a module")
    if type(module).__name__ != "module":
        raise TypeError("reload() argument must be a module")
    if _sys.modules.get(name) is not module:
        raise ImportError("module " + name + " not in sys.modules", name=name)
    parent_name = name.rpartition(".")[0]
    if parent_name:
        if parent_name not in _sys.modules:
            raise ImportError("parent " + repr(parent_name) + " not in sys.modules", name=parent_name)
    path = getattr(module, "__file__", None)
    if path is None:
        return module           # a module with no file (sys, math, os)
    _ny_module_exec(module, path, name)
    return _sys.modules[name]
