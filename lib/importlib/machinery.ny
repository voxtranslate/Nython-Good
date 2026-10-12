# nython: module    (import it by name: it runs in a module scope of its own)
# lib/importlib/machinery.ny - importlib.machinery (CPython 3.12's API) over
# the engines' module loader (round 80).
#
# ModuleSpec        name, loader, origin, loader_state,
#                   submodule_search_locations, cached, parent, has_location;
#                   CPython's repr and ==
# SourceFileLoader  (fullname, path): get_filename, get_data, get_source,
#                   path_stats, is_package, create_module (None: the default
#                   module), exec_module(module) - the file run in the
#                   module's namespace by the engine, as `import` runs it -
#                   get_code (compile() of the source: a code object exec()
#                   runs) and the deprecated load_module
# PathFinder        find_spec(fullname, path=None) through the directories
#                   `import` searches (sys.path's included), or the given ones
# FileFinder        (path): the finder of one directory - find_spec,
#                   invalidate_caches, FileFinder.path_hook(); what pkgutil's
#                   get_importer gives for a directory (the import statement
#                   searches directories itself and does not consult
#                   sys.path_hooks)
# BuiltinImporter   find_spec for the modules the engines make themselves
#                   (sys.builtin_module_names: builtins, math, os, sys)
# NamespaceLoader   the loader of a namespace package (a directory of .ny
#                   files without __init__.ny)
# SOURCE_SUFFIXES [".ny"], BYTECODE_SUFFIXES / EXTENSION_SUFFIXES [] (no
# bytecode cache, no extension modules), all_suffixes()
#
# Not here: FrozenImporter, ExtensionFileLoader,
# SourcelessFileLoader, WindowsRegistryFinder (nothing they would load).
import sys as _sys

SOURCE_SUFFIXES = [".ny"]
DEBUG_BYTECODE_SUFFIXES = []
OPTIMIZED_BYTECODE_SUFFIXES = []
BYTECODE_SUFFIXES = []
EXTENSION_SUFFIXES = []


def all_suffixes():
    """Returns a list of all recognized module suffixes for this process"""
    return SOURCE_SUFFIXES + BYTECODE_SUFFIXES + EXTENSION_SUFFIXES


class ModuleSpec:
    """The specification for a module, used for loading."""

    def __init__(self, name, loader, *, origin=None, loader_state=None, is_package=None):
        self.name = name
        self.loader = loader
        self.origin = origin
        self.loader_state = loader_state
        self.submodule_search_locations = [] if is_package else None
        self._uninitialized_submodules = []
        self._set_fileattr = False
        self._cached = None

    def __repr__(self):
        args = ["name=" + repr(self.name), "loader=" + repr(self.loader)]
        if self.origin is not None:
            args.append("origin=" + repr(self.origin))
        if self.submodule_search_locations is not None:
            args.append("submodule_search_locations=" + repr(self.submodule_search_locations))
        return type(self).__name__ + "(" + ", ".join(args) + ")"

    def __eq__(self, other):
        smsl = self.submodule_search_locations
        try:
            return (self.name == other.name and
                    self.loader == other.loader and
                    self.origin == other.origin and
                    smsl == other.submodule_search_locations and
                    self.cached == other.cached and
                    self.has_location == other.has_location)
        except AttributeError:
            return NotImplemented

    __hash__ = None

    @property
    def cached(self):
        return self._cached

    @cached.setter
    def cached(self, cached):
        self._cached = cached

    @property
    def parent(self):
        """The name of the module's parent."""
        if self.submodule_search_locations is None:
            return self.name.rpartition(".")[0]
        return self.name

    @property
    def has_location(self):
        return self._set_fileattr

    @has_location.setter
    def has_location(self, value):
        self._set_fileattr = bool(value)


def _read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


class SourceFileLoader:
    """Loader for Nython source files (.ny)."""

    def __init__(self, fullname, path):
        self.name = fullname
        self.path = path

    def __eq__(self, other):
        return self.__class__ == other.__class__ and self.name == other.name and self.path == other.path

    def __hash__(self):
        return hash(self.name) ^ hash(self.path)

    def __repr__(self):
        return "<" + type(self).__module__ + "." + type(self).__qualname__ + " object at " + hex(id(self)) + ">"

    def get_filename(self, name=None):
        """Return the path to the source file as found by the finder."""
        if name is not None and name != self.name:
            raise ImportError("loader for " + self.name + " cannot handle " + name, name=name)
        return self.path

    def get_data(self, path):
        """Return the data from path as raw bytes."""
        return _read_bytes(path)

    def get_source(self, fullname):
        return _read_text(self.get_filename(fullname))

    def get_code(self, fullname):
        """The module's code object (compiled from its source)."""
        path = self.get_filename(fullname)
        return compile(_read_text(path), path, "exec")

    def path_stats(self, path):
        import os
        st = os.stat(path)
        return {"mtime": st.st_mtime, "size": st.st_size}

    def is_package(self, fullname):
        filename = self.get_filename(fullname).replace("\\", "/").rpartition("/")[2]
        filename_base = filename.rsplit(".", 1)[0]
        tail_name = fullname.rpartition(".")[2]
        return filename_base == "__init__" and tail_name != "__init__"

    def create_module(self, spec):
        """Use default semantics for module creation."""
        return None

    def exec_module(self, module):
        """Execute the module."""
        name = getattr(module, "__name__", self.name)
        _ny_module_exec(module, self.path, name)

    def load_module(self, fullname=None):
        """Load the module (deprecated in CPython; kept for old loaders)."""
        if fullname is None:
            fullname = self.name
        module = _sys.modules.get(fullname)
        if module is None:
            module = _ny_module_new(fullname)
            _sys.modules[fullname] = module
        self.exec_module(module)
        return module


SourceLoader = SourceFileLoader


class NamespaceLoader:
    """The loader of a namespace package."""

    def __init__(self, name, path, path_finder=None):
        self._name = name
        self._path = path

    def is_package(self, fullname):
        return True

    def get_source(self, fullname):
        return ""

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        pass


class BuiltinImporter:
    """Meta path import for the modules the engines make themselves."""

    _ORIGIN = "built-in"

    @classmethod
    def find_spec(cls, fullname, path=None, target=None):
        if fullname in _sys.builtin_module_names:
            return ModuleSpec(fullname, cls, origin=cls._ORIGIN)
        return None

    @staticmethod
    def create_module(spec):
        return _ny_import_module(spec.name)

    @staticmethod
    def exec_module(module):
        pass

    @classmethod
    def is_package(cls, fullname):
        return False


def _spec_for_path(fullname, path, kind):
    if kind == "namespace":
        spec = ModuleSpec(fullname, NamespaceLoader(fullname, [path]), is_package=True)
        spec.submodule_search_locations = [path]
        return spec
    loader = SourceFileLoader(fullname, path)
    spec = ModuleSpec(fullname, loader, origin=path, is_package=(kind == "package"))
    if kind == "package":
        import os
        spec.submodule_search_locations = [os.path.dirname(path)]   # native separators, as the engines' __path__
    spec.has_location = True
    return spec


class PathFinder:
    """Meta path finder for sys.path and package __path__ attributes."""

    @staticmethod
    def invalidate_caches():
        pass

    @classmethod
    def find_spec(cls, fullname, path=None, target=None):
        if path is None:
            found = _ny_find_module(fullname)
            if not found[0]:
                return None
            return _spec_for_path(fullname, found[0], found[1])
        import os
        tail = fullname.rpartition(".")[2]
        sep = os.sep   # native separators, as the engines' __path__ (round 80)
        for entry in path:
            if not isinstance(entry, str):
                continue
            base = entry.rstrip("/\\")
            for kind, candidate in (("package", base + sep + tail + sep + "__init__.ny"),
                                    ("file", base + sep + tail + ".ny")):
                if _ny_path_isfile(candidate):
                    return _spec_for_path(fullname, candidate, kind)
            d = base + sep + tail
            if _ny_path_isdir(d):
                return _spec_for_path(fullname, d, "namespace")
        return None

    @classmethod
    def find_module(cls, fullname, path=None):
        spec = cls.find_spec(fullname, path)
        return None if spec is None else spec.loader


class FileFinder:
    """File-based finder: the modules and packages of one directory."""

    def __init__(self, path, *loader_details):
        import os
        if not path or path == ".":
            self.path = os.getcwd()
        elif not os.path.isabs(path):
            self.path = os.path.join(os.getcwd(), path)
        else:
            self.path = path
        self._loader_details = loader_details

    def invalidate_caches(self):
        pass

    def find_spec(self, fullname, target=None):
        return PathFinder.find_spec(fullname, [self.path], target)

    def find_module(self, fullname):
        spec = self.find_spec(fullname)
        return None if spec is None else spec.loader

    @classmethod
    def path_hook(cls, *loader_details):
        def path_hook_for_FileFinder(path):
            if not _ny_path_isdir(path):
                raise ImportError("only directories are supported", path=path)
            return cls(path, *loader_details)
        return path_hook_for_FileFinder

    def __repr__(self):
        return "FileFinder(" + repr(self.path) + ")"


def _ny_path_isfile(p):
    return os_isfile(p)


def _ny_path_isdir(p):
    return os_isdir(p)
