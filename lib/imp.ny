# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/imp.ny - Python's imp (round 87; CPython 3.11's Lib/imp.py, deprecated
# there and removed in 3.12), over lib/importlib: find_module / load_module
# with the (file, pathname, (suffix, mode, type)) triples, load_source,
# load_package, new_module, reload, get_suffixes, get_magic / get_tag,
# cache_from_source / source_from_cache, NullImporter, the import lock
# (lock_held / acquire_lock / release_lock) and the type codes.
#
# (Nython: CPython's _imp C module and importlib._bootstrap internals are
# written here - the import lock is a re-entrant lock, nothing is frozen or
# built as an extension, and the builtin modules are the engines' own
# (sys.builtin_module_names). A source file is a .ny or a .py file and a
# package directory holds __init__.ny or __init__.py; load_compiled and
# load_dynamic raise ImportError - Nython has no bytecode files or
# extension modules.)
"""This module provides the components needed to build your own __import__
function.  Undocumented functions are obsolete.

In most cases it is preferred you consider using the importlib module's
functionality over this module.

"""
from importlib import machinery
from importlib import util
import importlib
import os
import sys
import tokenize
import types
import warnings
import threading as _threading

warnings.warn("the imp module is deprecated in favour of importlib and slated "
              "for removal in Python 3.12; "
              "see the module's documentation for alternative uses",
              DeprecationWarning, stacklevel=2)

# DEPRECATED
SEARCH_ERROR = 0
PY_SOURCE = 1
PY_COMPILED = 2
C_EXTENSION = 3
PY_RESOURCE = 4
PKG_DIRECTORY = 5
C_BUILTIN = 6
PY_FROZEN = 7
PY_CODERESOURCE = 8
IMP_HOOK = 9

_ERR_MSG = 'No module named {!r}'

# ── what CPython's _imp gives (Nython: written here) ─────────────────────────
_import_lock = _threading.RLock()
_lock_count = [0]


def lock_held():
    """Return True if the import lock is currently held, else False."""
    return _lock_count[0] > 0


def acquire_lock():
    """Acquires the interpreter's import lock for the current thread.

    This lock should be used by import hooks to ensure thread-safety when
    importing modules.
    """
    _import_lock.acquire()
    _lock_count[0] += 1


def release_lock():
    """Release the interpreter's import lock."""
    if _lock_count[0] <= 0:
        raise RuntimeError("not holding the import lock")
    _lock_count[0] -= 1
    try:
        _import_lock.release()
    except RuntimeError:
        _lock_count[0] += 1
        raise RuntimeError("not holding the import lock") from None


def is_builtin(name):
    """Returns True if the module name corresponds to a built-in module."""
    if name in ("sys", "builtins"):
        return -1   # built in, and cannot be initialized again (CPython's -1)
    return 1 if name in sys.builtin_module_names else 0


def is_frozen(name):
    """Returns True if the module name corresponds to a frozen module."""
    return False


def is_frozen_package(name):
    """Returns True if the module name is of a frozen package."""
    raise ImportError('No such frozen object named {!r}'.format(name), name=name)


def get_frozen_object(name, data=None):
    """Create a code object for a frozen module."""
    raise ImportError('No such frozen object named {!r}'.format(name), name=name)


def init_frozen(name):
    """Initializes a frozen module."""
    return None


def _fix_co_filename(code, path):
    """Changes code.co_filename to specify the passed-in file path."""
    return None


create_dynamic = None


def _builtin_from_name(name):
    if name not in sys.builtin_module_names:
        raise ImportError('no built-in module named ' + name)
    return importlib.import_module(name)


def _exec(spec, module):
    # importlib._bootstrap._exec: run the spec's loader over the module
    name = spec.name
    if sys.modules.get(name) is not module:
        raise ImportError('module {!r} not in sys.modules'.format(name), name=name)
    for attr, value in (("__spec__", spec), ("__loader__", spec.loader)):
        try:
            setattr(module, attr, value)
        except AttributeError:
            pass
    if spec.origin is not None and getattr(spec, "has_location", False):
        try:
            module.__file__ = spec.origin
        except AttributeError:
            pass
    spec.loader.exec_module(module)
    return sys.modules[name]


def _load(spec):
    # importlib._bootstrap._load: a new module made from the spec, entered in
    # sys.modules, then run (taken out again if it fails)
    module = util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(spec.name, None)
        raise
    return sys.modules[spec.name]


def new_module(name):
    """**DEPRECATED**

    Create a new module.

    The module is not entered into sys.modules.

    """
    return types.ModuleType(name)


def get_magic():
    """**DEPRECATED**

    Return the magic number for .pyc files.
    """
    return util.MAGIC_NUMBER


def get_tag():
    """Return the magic tag for .pyc files."""
    return sys.implementation.cache_tag


def cache_from_source(path, debug_override=None):
    """**DEPRECATED**

    Given the path to a .py file, return the path to its .pyc file.

    The .py file does not need to exist; this simply returns the path to the
    .pyc file calculated as if the .py file were imported.

    If debug_override is not None, then it must be a boolean and is used in
    place of sys.flags.optimize.

    If sys.implementation.cache_tag is None then NotImplementedError is raised.

    """
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        return util.cache_from_source(path, debug_override)


def source_from_cache(path):
    """**DEPRECATED**

    Given the path to a .pyc. file, return the path to its .py file.

    The .pyc file does not need to exist; this simply returns the path to
    the .py file calculated to correspond to the .pyc file.  If path does
    not conform to PEP 3147 format, ValueError will be raised. If
    sys.implementation.cache_tag is None then NotImplementedError is raised.

    """
    return util.source_from_cache(path)


# (Nython: .ny and .py source files; no bytecode or extension suffixes)
_SOURCE_SUFFIXES = [".ny", ".py"]


def get_suffixes():
    """**DEPRECATED**"""
    extensions = [(s, 'rb', C_EXTENSION) for s in machinery.EXTENSION_SUFFIXES]
    source = [(s, 'r', PY_SOURCE) for s in _SOURCE_SUFFIXES]
    bytecode = [(s, 'rb', PY_COMPILED) for s in machinery.BYTECODE_SUFFIXES]

    return extensions + source + bytecode


class NullImporter:

    """**DEPRECATED**

    Null import object.

    """

    def __init__(self, path):
        if path == '':
            raise ImportError('empty pathname', path='')
        elif os.path.isdir(path):
            raise ImportError('existing directory', path=path)

    def find_module(self, fullname):
        """Always returns None."""
        return None


class _LoadSourceCompatibility(machinery.SourceFileLoader):

    """Compatibility support for implementing load_source() (Nython: the
    engines read the file themselves; the open file given is closed)."""

    def __init__(self, fullname, path, file=None):
        super().__init__(fullname, path)
        self.file = file


def load_source(name, pathname, file=None):
    loader = _LoadSourceCompatibility(name, pathname, file)
    spec = util.spec_from_file_location(name, pathname, loader=loader)
    if name in sys.modules:
        module = _exec(spec, sys.modules[name])
    else:
        module = _load(spec)
    # To allow reloading to potentially work, use a non-hacked loader which
    # won't rely on a now-closed file object.
    module.__loader__ = machinery.SourceFileLoader(name, pathname)
    module.__spec__.loader = module.__loader__
    return module


def load_compiled(name, pathname, file=None):
    """**DEPRECATED** (Nython: there are no compiled module files)"""
    raise ImportError("bad magic number in {!r}: compiled modules are not "
                      "supported on Nython".format(name), name=name, path=pathname)


def load_package(name, path):
    """**DEPRECATED**"""
    if os.path.isdir(path):
        extensions = (_SOURCE_SUFFIXES[:] +
                      machinery.BYTECODE_SUFFIXES[:])
        for extension in extensions:
            init_path = os.path.join(path, '__init__' + extension)
            if os.path.exists(init_path):
                path = init_path
                break
        else:
            raise ValueError('{!r} is not a package'.format(path))
    spec = util.spec_from_file_location(name, path,
                                        submodule_search_locations=[])
    if name in sys.modules:
        return _exec(spec, sys.modules[name])
    else:
        return _load(spec)


def load_module(name, file, filename, details):
    """**DEPRECATED**

    Load a module, given information returned by find_module().

    The module name must include the full package name, if any.

    """
    suffix, mode, type_ = details
    if mode and (not mode.startswith('r') or '+' in mode):
        raise ValueError('invalid file open mode {!r}'.format(mode))
    elif file is None and type_ in {PY_SOURCE, PY_COMPILED}:
        msg = 'file object required for import (type code {})'.format(type_)
        raise ValueError(msg)
    elif type_ == PY_SOURCE:
        return load_source(name, filename, file)
    elif type_ == PY_COMPILED:
        return load_compiled(name, filename, file)
    elif type_ == C_EXTENSION and load_dynamic is not None:
        if file is None:
            with open(filename, 'rb') as opened_file:
                return load_dynamic(name, filename, opened_file)
        else:
            return load_dynamic(name, filename, file)
    elif type_ == PKG_DIRECTORY:
        return load_package(name, filename)
    elif type_ == C_BUILTIN:
        return init_builtin(name)
    elif type_ == PY_FROZEN:
        return init_frozen(name)
    else:
        msg =  "Don't know how to import {} (type code {})".format(name, type_)
        raise ImportError(msg, name=name)


def find_module(name, path=None):
    """**DEPRECATED**

    Search for a module.

    If path is omitted or None, search for a built-in, frozen or special
    module and continue search in sys.path. The module name cannot
    contain '.'; to search for a submodule of a package, pass the
    submodule name and the package's __path__.

    """
    if not isinstance(name, str):
        raise TypeError("'name' must be a str, not {}".format(type(name)))
    elif not isinstance(path, (type(None), list)):
        # Backwards-compatibility
        raise RuntimeError("'path' must be None or a list, "
                           "not {}".format(type(path)))

    if path is None:
        if is_builtin(name):
            return None, None, ('', '', C_BUILTIN)
        elif is_frozen(name):
            return None, None, ('', '', PY_FROZEN)
        else:
            path = sys.path

    for entry in path:
        package_directory = os.path.join(entry, name)
        for suffix in _SOURCE_SUFFIXES:
            package_file_name = '__init__' + suffix
            file_path = os.path.join(package_directory, package_file_name)
            if os.path.isfile(file_path):
                return None, package_directory, ('', '', PKG_DIRECTORY)
        for suffix, mode, type_ in get_suffixes():
            file_name = name + suffix
            file_path = os.path.join(entry, file_name)
            if os.path.isfile(file_path):
                break
        else:
            continue
        break  # Break out of outer loop when breaking out of inner loop.
    else:
        raise ImportError(_ERR_MSG.format(name), name=name)

    encoding = None
    if 'b' not in mode:
        with open(file_path, 'rb') as file:
            encoding = tokenize.detect_encoding(file.readline)[0]
    file = open(file_path, mode, encoding=encoding)
    return file, file_path, (suffix, mode, type_)


def reload(module):
    """**DEPRECATED**

    Reload the module and return it.

    The module must have been successfully imported before.

    """
    return importlib.reload(module)


def init_builtin(name):
    """**DEPRECATED**

    Load and return a built-in module by name, or None is such module doesn't
    exist
    """
    try:
        return _builtin_from_name(name)
    except ImportError:
        return None


load_dynamic = None
