# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/importlib/util.ny - importlib.util (CPython 3.12's API) over the
# engines' module loader (round 80).
#
# find_spec(name, package=None)   the module's spec: sys.modules[name].__spec__
#               when it is loaded (ValueError "x.__spec__ is None" /
#               "x.__spec__ is not set"), else the meta-path finders a program
#               installed on sys.meta_path, then the builtin modules and the
#               files `import` would find (the parent package is imported
#               first, as CPython; ModuleNotFoundError "__path__ attribute
#               not found on 'x' while trying to find 'x.y'"); None when there
#               is nothing
# module_from_spec(spec)  a new module from the loader's create_module or a
#               fresh one, its __name__/__loader__/__package__/__spec__/
#               __path__/__file__ set from the spec (_init_module_attrs)
# spec_from_file_location(name, location, *, loader=None,
#               submodule_search_locations=...)  a SourceFileLoader spec
# spec_from_loader(name, loader, *, origin=None, is_package=None)
# resolve_name(name, package), decode_source(source_bytes),
# source_hash(source_bytes) (Nython's own hash of the bytes), MAGIC_NUMBER,
# cache_from_source / source_from_cache (NotImplementedError: no bytecode
# cache, sys.implementation.cache_tag is None - CPython's behaviour then),
# LazyLoader (the module is loaded at its first attribute access)
import sys as _sys
from importlib.machinery import ModuleSpec, SourceFileLoader, BuiltinImporter, PathFinder, _spec_for_path

MAGIC_NUMBER = b"NY\r\n"

_POPULATE = object()


def resolve_name(name, package):
    """Resolve a relative module name to an absolute one."""
    if not name.startswith("."):
        return name
    elif not package:
        raise ImportError("no package specified for " + repr(name) + " (required for relative module names)")
    level = 0
    for character in name:
        if character != ".":
            break
        level += 1
    bits = package.rsplit(".", level - 1)
    if len(bits) < level:
        raise ImportError("attempted relative import beyond top-level package")
    base = bits[0]
    rest = name[level:]
    return base + "." + rest if rest else base


def _find_spec_from_path(name, path=None):
    if name not in _sys.modules:
        return _find_spec(name, path)
    module = _sys.modules[name]
    if module is None:
        return None
    try:
        spec = module.__spec__
    except AttributeError:
        raise ValueError(name + ".__spec__ is not set")
    if spec is None:
        raise ValueError(name + ".__spec__ is None")
    return spec


def _find_spec(name, path, target=None):
    for finder in _sys.meta_path:
        find = getattr(finder, "find_spec", None)
        if find is None:
            continue
        spec = find(name, path, target)
        if spec is not None:
            return spec
    spec = BuiltinImporter.find_spec(name)
    if spec is not None:
        return spec
    return PathFinder.find_spec(name, path)


def find_spec(name, package=None):
    """Return the spec for the specified module."""
    fullname = resolve_name(name, package) if name.startswith(".") else name
    if fullname not in _sys.modules:
        parent_name = fullname.rpartition(".")[0]
        parent_path = None
        if parent_name:
            parent = __import__(parent_name, fromlist=["__path__"])
            try:
                parent_path = parent.__path__
            except AttributeError as e:
                raise ModuleNotFoundError("__path__ attribute not found on " + repr(parent_name) +
                                          " while trying to find " + repr(fullname))
        return _find_spec(fullname, parent_path)
    module = _sys.modules[fullname]
    if module is None:
        return None
    spec = getattr(module, "__spec__", None)
    if spec is None:
        # a module the engines loaded (they set no __spec__): its spec from
        # where it came from
        f = getattr(module, "__file__", None)
        if f is not None:
            kind = "package" if f.replace("\\", "/").endswith("/__init__.ny") else "file"
            return _spec_for_path(fullname, f, kind)
        if fullname in _sys.builtin_module_names:
            return BuiltinImporter.find_spec(fullname)
        raise ValueError(name + ".__spec__ is None")
    return spec


def spec_from_loader(name, loader, *, origin=None, is_package=None):
    """Return a module spec based on various loader methods."""
    if origin is None:
        origin = getattr(loader, "_ORIGIN", None)
    if not origin and hasattr(loader, "get_filename"):
        if is_package is None:
            return spec_from_file_location(name, loader=loader)
        search = [] if is_package else None
        return spec_from_file_location(name, loader=loader, submodule_search_locations=search)
    if is_package is None:
        if hasattr(loader, "is_package"):
            try:
                is_package = loader.is_package(name)
            except ImportError:
                is_package = None
        else:
            is_package = False
    return ModuleSpec(name, loader, origin=origin, is_package=is_package)


def spec_from_file_location(name, location=None, *, loader=None, submodule_search_locations=_POPULATE):
    """Return a module spec based on a file location."""
    if location is None:
        location = "<unknown>"
        if hasattr(loader, "get_filename"):
            try:
                location = loader.get_filename(name)
            except ImportError:
                pass
    else:
        location = _ny_fspath(location)
    if loader is None:
        loader = SourceFileLoader(name, location)
    spec = ModuleSpec(name, loader, origin=location)
    spec._set_fileattr = True
    if submodule_search_locations is _POPULATE:
        if hasattr(loader, "is_package"):
            try:
                is_package = loader.is_package(name)
            except ImportError:
                pass
            else:
                if is_package:
                    spec.submodule_search_locations = []
    else:
        spec.submodule_search_locations = submodule_search_locations
    if spec.submodule_search_locations == []:
        if location:
            dirname = location.replace("\\", "/").rpartition("/")[0]
            spec.submodule_search_locations.append(dirname)
    return spec


def _ny_fspath(p):
    if isinstance(p, str):
        return p
    if isinstance(p, bytes):
        return p.decode("utf-8", "surrogateescape")
    f = getattr(p, "__fspath__", None)
    if f is None:
        raise TypeError("expected str, bytes or os.PathLike object, not " + type(p).__name__)
    return f()


def _init_module_attrs(spec, module):
    try:
        module.__name__ = spec.name
    except AttributeError:
        pass
    loader = spec.loader
    try:
        module.__loader__ = loader
    except AttributeError:
        pass
    try:
        module.__package__ = spec.parent
    except AttributeError:
        pass
    try:
        module.__spec__ = spec
    except AttributeError:
        pass
    if spec.submodule_search_locations is not None:
        try:
            module.__path__ = spec.submodule_search_locations
        except AttributeError:
            pass
    if spec.has_location:
        try:
            module.__file__ = spec.origin
        except AttributeError:
            pass
        if spec.cached is not None:
            try:
                module.__cached__ = spec.cached
            except AttributeError:
                pass
    return module


def module_from_spec(spec):
    """Create a module based on the provided spec."""
    module = None
    if hasattr(spec.loader, "create_module"):
        module = spec.loader.create_module(spec)
    elif hasattr(spec.loader, "exec_module"):
        raise ImportError("loaders that define exec_module() must also define create_module()")
    if module is None:
        module = _ny_module_new(spec.name)
    _init_module_attrs(spec, module)
    return module


def decode_source(source_bytes):
    """Decode bytes representing source code and return the string."""
    text = source_bytes.decode("utf-8")
    return text.replace("\r\n", "\n").replace("\r", "\n")


def source_hash(source_bytes):
    """Return the hash of *source_bytes* as used in hash-based pyc files
    (Nython has none: its own 64-bit hash of the bytes, as 8 bytes)."""
    return (hash(bytes(source_bytes)) & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "little")


def cache_from_source(path, debug_override=None, *, optimization=None):
    raise NotImplementedError("sys.implementation.cache_tag is None")


def source_from_cache(path):
    raise NotImplementedError("sys.implementation.cache_tag is None")


_LAZY_OWN = ("__name__", "__loader__", "__package__", "__spec__", "__path__", "__file__", "__cached__")


class _LazyModule:
    """A module whose loading happens at its first attribute access."""

    def __init__(self, spec):
        object.__setattr__(self, "_ny_spec", spec)
        object.__setattr__(self, "_ny_module", None)
        object.__setattr__(self, "__name__", spec.name)
        object.__setattr__(self, "__spec__", spec)

    def _ny_load(self):
        m = object.__getattribute__(self, "_ny_module")
        if m is None:
            spec = object.__getattribute__(self, "_ny_spec")
            m = _ny_module_new(spec.name)
            _init_module_attrs(spec, m)
            spec.loader.exec_module(m)
            object.__setattr__(self, "_ny_module", m)
        return m

    def __getattr__(self, attr):
        return getattr(self._ny_load(), attr)

    def __setattr__(self, attr, value):
        if object.__getattribute__(self, "_ny_module") is None and attr in _LAZY_OWN:
            object.__setattr__(self, attr, value)    # module_from_spec's attributes
            return
        setattr(self._ny_load(), attr, value)

    def __delattr__(self, attr):
        delattr(self._ny_load(), attr)


class LazyLoader:
    """A loader that creates a module which defers loading until attribute
    access."""

    @staticmethod
    def __check_eager_loader(loader):
        if not hasattr(loader, "exec_module"):
            raise TypeError("loader must define exec_module()")

    @classmethod
    def factory(cls, loader):
        """Construct a callable which returns the eager loader made lazy."""
        cls.__check_eager_loader(loader)
        return lambda *args, **kwargs: cls(loader(*args, **kwargs))

    def __init__(self, loader):
        self.__check_eager_loader(loader)
        self.loader = loader

    def create_module(self, spec):
        return _LazyModule(spec)

    def exec_module(self, module):
        """Make the module load lazily."""
        module.__spec__.loader = self.loader
