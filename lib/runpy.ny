# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/runpy.ny - runpy, CPython 3.11's API (round 80).
#
# run_module(mod_name, init_globals=None, run_name=None, alter_sys=False)
#               a module's (a package's __main__'s) code run without importing
#               it, in a fresh globals dict - __name__ (run_name or the
#               module's name), __file__, __package__, __spec__, __loader__,
#               __cached__, __doc__ set as CPython - which it returns; with
#               alter_sys, sys.argv[0] is the file and sys.modules[run_name]
#               a module reading those globals while it runs
# run_path(path_name, init_globals=None, run_name=None)  a script file, or a
#               directory holding __main__.ny (put first on sys.path while it
#               runs); __name__ is "<run_path>" unless run_name is given
#
# CPython's messages: "No module named x", "Relative module names not
# supported", "...; 'p' is a package and cannot be directly executed",
# "Cannot use package as __main__ module", "can't find '__main__' module in
# 'dir'". Not here: zip files (no zipimport). Nython: the globals of the
# alter_sys module are the dict run_module returns (CPython's are the
# module's __dict__, copied when it ends - the same values).
import os
import sys
import importlib
import importlib.util
import importlib.machinery
from types import ModuleType

__all__ = ["run_module", "run_path"]


class _NyRunModule(ModuleType):
    # the module sys.modules holds while code runs with alter_sys: its
    # attributes are the run's globals
    def __init__(self, name, run_globals):
        self._ny_run_globals = run_globals
        ModuleType.__init__(self, name)

    def __getattr__(self, name):
        g = self._ny_run_globals
        if name in g:
            return g[name]
        raise AttributeError("module '" + str(g.get("__name__", "?")) + "' has no attribute '" + name + "'")


class _TempModule:
    """Temporarily replace a module in sys.modules with an empty namespace"""

    def __init__(self, mod_name):
        self.mod_name = mod_name
        self.globals = {}
        self.module = _NyRunModule(mod_name, self.globals)
        self._saved_module = []

    def __enter__(self):
        mod_name = self.mod_name
        if mod_name in sys.modules:
            self._saved_module.append(sys.modules[mod_name])
        sys.modules[mod_name] = self.module
        return self

    def __exit__(self, *args):
        if self._saved_module:
            sys.modules[self.mod_name] = self._saved_module[0]
        else:
            del sys.modules[self.mod_name]
        self._saved_module = []


class _ModifiedArgv0:
    def __init__(self, value):
        self.value = value
        self._sentinel = object()
        self._saved_value = self._sentinel

    def __enter__(self):
        if self._saved_value is not self._sentinel:
            raise RuntimeError("Already preserving saved value")
        self._saved_value = sys.argv[0] if len(sys.argv) > 0 else ""
        if len(sys.argv) > 0:
            sys.argv[0] = self.value
        else:
            sys.argv.append(self.value)

    def __exit__(self, *args):
        self.value = self._sentinel
        sys.argv[0] = self._saved_value


def _run_code(code, run_globals, init_globals=None, mod_name=None, mod_spec=None, pkg_name=None, script_name=None):
    """Helper to run code in nominated namespace"""
    if init_globals is not None:
        run_globals.update(init_globals)
    if mod_spec is None:
        loader = None
        fname = script_name
        cached = None
    else:
        loader = mod_spec.loader
        fname = mod_spec.origin
        cached = mod_spec.cached
        if pkg_name is None:
            pkg_name = mod_spec.parent
    run_globals["__name__"] = mod_name
    run_globals["__file__"] = fname
    run_globals["__cached__"] = cached
    run_globals["__doc__"] = None
    run_globals["__loader__"] = loader
    run_globals["__package__"] = pkg_name
    run_globals["__spec__"] = mod_spec
    exec(code, run_globals)
    return run_globals


def _run_module_code(code, init_globals=None, mod_name=None, mod_spec=None, pkg_name=None, script_name=None):
    """Helper to run code in new namespace with sys modified"""
    fname = script_name if mod_spec is None else mod_spec.origin
    with _TempModule(mod_name) as temp_module, _ModifiedArgv0(fname):
        mod_globals = temp_module.globals
        _run_code(code, mod_globals, init_globals, mod_name, mod_spec, pkg_name, script_name)
    return mod_globals.copy()


def _get_module_details(mod_name, error=ImportError):
    if mod_name.startswith("."):
        raise error("Relative module names not supported")
    pkg_name, _, _ = mod_name.rpartition(".")
    if pkg_name:
        # import the parent first (its initialisation errors are not hidden)
        try:
            __import__(pkg_name)
        except ImportError as e:
            if e.name is None or (e.name != pkg_name and not pkg_name.startswith(e.name + ".")):
                raise
        existing = sys.modules.get(mod_name)
        if existing is not None and not hasattr(existing, "__path__"):
            from warnings import warn
            warn(RuntimeWarning(repr(mod_name) + " found in sys.modules after import of package " + repr(pkg_name) +
                                ", but prior to execution of " + repr(mod_name) + "; this may result in unpredictable behaviour"))
    try:
        spec = importlib.util.find_spec(mod_name)
    except (ImportError, AttributeError, TypeError, ValueError) as ex:
        msg = "Error while finding module specification for " + repr(mod_name) + " (" + type(ex).__name__ + ": " + str(ex) + ")"
        for suffix in (".py", ".ny"):
            if mod_name.endswith(suffix):
                msg += ". Try using '" + mod_name[:-3] + "' instead of '" + mod_name + "' as the module name."
        raise error(msg) from ex
    if spec is None:
        raise error("No module named " + mod_name)
    if spec.submodule_search_locations is not None:
        if mod_name == "__main__" or mod_name.endswith(".__main__"):
            raise error("Cannot use package as __main__ module")
        try:
            pkg_main_name = mod_name + ".__main__"
            return _get_module_details(pkg_main_name, error)
        except error as e:
            if mod_name not in sys.modules:
                raise   # no module loaded: being a package is irrelevant
            raise error(str(e) + "; " + repr(mod_name) + " is a package and cannot be directly executed")
    loader = spec.loader
    if loader is None:
        raise error(repr(mod_name) + " is a namespace package and cannot be executed")
    try:
        code = loader.get_code(mod_name)
    except ImportError as e:
        raise error(format(e)) from e
    if code is None:
        raise error("No code object available for " + mod_name)
    return mod_name, spec, code


def run_module(mod_name, init_globals=None, run_name=None, alter_sys=False):
    """Execute a module's code without importing it; returns its globals."""
    mod_name, mod_spec, code = _get_module_details(mod_name)
    if run_name is None:
        run_name = mod_name
    if alter_sys:
        return _run_module_code(code, init_globals, run_name, mod_spec)
    return _run_code(code, {}, init_globals, run_name, mod_spec)


def _get_main_module_details(error=ImportError):
    main_name = "__main__"
    saved_main = sys.modules.get(main_name)
    if main_name in sys.modules:
        del sys.modules[main_name]
    try:
        return _get_module_details(main_name)
    except ImportError as exc:
        if main_name in str(exc):
            raise error("can't find " + repr(main_name) + " module in " + repr(sys.path[0])) from exc
        raise
    finally:
        if saved_main is not None:
            sys.modules[main_name] = saved_main


def _get_code_from_file(run_name, fname):
    decoded_path = os.path.abspath(fname)
    with open(decoded_path, "r", encoding="utf-8") as f:
        code = compile(f.read(), fname, "exec")
    return code, fname


def run_path(path_name, init_globals=None, run_name=None):
    """Execute the code at a filesystem location (a script, or a directory
    holding __main__); returns its globals."""
    if run_name is None:
        run_name = "<run_path>"
    pkg_name = run_name.rpartition(".")[0]
    from pkgutil import get_importer
    importer = get_importer(path_name)
    if importer is None:
        # not a sys.path entry: the file's code is run directly
        code, fname = _get_code_from_file(run_name, path_name)
        return _run_module_code(code, init_globals, run_name, pkg_name=pkg_name, script_name=fname)
    sys.path.insert(0, path_name)
    try:
        mod_name, mod_spec, code = _get_main_module_details()
        with _TempModule(run_name) as temp_module, _ModifiedArgv0(path_name):
            mod_globals = temp_module.globals
            return _run_code(code, mod_globals, init_globals, run_name, mod_spec, pkg_name).copy()
    finally:
        try:
            sys.path.remove(path_name)
        except ValueError:
            pass
