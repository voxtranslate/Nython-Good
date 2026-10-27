# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/importlib/abc.ny - importlib.abc (CPython 3.12's API, round 80): the
# abstract base classes of finders and loaders, for programs that write
# their own (put on sys.meta_path, a MetaPathFinder is asked by
# importlib.util.find_spec - the engines' import statement does not ask it).
#
# Loader (create_module -> None, load_module, module_repr), MetaPathFinder
# (find_spec -> None, invalidate_caches), PathEntryFinder, ResourceLoader
# (get_data), InspectLoader (is_package, get_code -> None here: no code
# objects, get_source, source_to_code -> compile()), ExecutionLoader
# (get_filename), FileLoader, SourceLoader, Traversable /
# TraversableResources (importlib.resources.abc's names).
import abc as _abc
from importlib.machinery import SourceFileLoader as _SourceFileLoader


class Loader(metaclass=_abc.ABCMeta):
    """Abstract base class for import loaders."""

    def create_module(self, spec):
        """Return a module to initialize and into which to load (None: the
        default module creation semantics)."""
        return None

    def load_module(self, fullname):
        """Return the loaded module (deprecated)."""
        if not hasattr(self, "exec_module"):
            raise ImportError
        import sys
        module = sys.modules.get(fullname)
        if module is None:
            module = _ny_module_new(fullname)
            sys.modules[fullname] = module
        self.exec_module(module)
        return module

    def module_repr(self, module):
        raise NotImplementedError


class Finder(metaclass=_abc.ABCMeta):
    """Legacy abstract base class for import finders."""
    pass


class MetaPathFinder(metaclass=_abc.ABCMeta):
    """Abstract base class for import finders on sys.meta_path."""

    def find_spec(self, fullname, path, target=None):
        return None

    def invalidate_caches(self):
        """An optional method for clearing the finder's cache, if any."""
        pass


class PathEntryFinder(metaclass=_abc.ABCMeta):
    """Abstract base class for path entry finders used by PathFinder."""

    def find_spec(self, fullname, target=None):
        return None

    def invalidate_caches(self):
        pass


class ResourceLoader(Loader):
    """Abstract base class for loaders which can return data from their
    back-end storage."""

    @_abc.abstractmethod
    def get_data(self, path):
        """Abstract method which when implemented should return the bytes for
        the specified path."""
        raise OSError


class InspectLoader(Loader):
    """Abstract base class for loaders which support inspection about the
    modules they can load."""

    def is_package(self, fullname):
        raise ImportError

    def get_code(self, fullname):
        source = self.get_source(fullname)
        if source is None:
            return None
        return self.source_to_code(source)

    @_abc.abstractmethod
    def get_source(self, fullname):
        raise ImportError

    @staticmethod
    def source_to_code(data, path="<string>"):
        """Compile 'data' into a code object."""
        if isinstance(data, (bytes, bytearray)):
            data = bytes(data).decode("utf-8")
        return compile(data, path, "exec")

    def exec_module(self, module):
        code = self.get_code(module.__name__)
        if code is None:
            raise ImportError("cannot load module " + repr(module.__name__) + " when get_code() returns None")
        exec(code, vars(module))


class ExecutionLoader(InspectLoader):
    """Abstract base class for loaders that wish to support the execution of
    modules as scripts."""

    @_abc.abstractmethod
    def get_filename(self, fullname):
        raise ImportError

    def get_code(self, fullname):
        source = self.get_source(fullname)
        if source is None:
            return None
        try:
            path = self.get_filename(fullname)
        except ImportError:
            return self.source_to_code(source)
        return self.source_to_code(source, path)


class FileLoader(_SourceFileLoader, ResourceLoader, ExecutionLoader):
    """Abstract base class partially implementing the ResourceLoader and
    ExecutionLoader ABCs."""
    pass


class SourceLoader(_SourceFileLoader, ResourceLoader, ExecutionLoader):
    """Abstract base class for loading source code."""
    pass


class Traversable(metaclass=_abc.ABCMeta):
    """An object with a subset of pathlib.Path methods suitable for
    traversing directories and opening files."""

    @_abc.abstractmethod
    def iterdir(self):
        pass

    def read_bytes(self):
        with self.open("rb") as strm:
            return strm.read()

    def read_text(self, encoding=None):
        with self.open(encoding=encoding) as strm:
            return strm.read()

    @_abc.abstractmethod
    def is_dir(self):
        pass

    @_abc.abstractmethod
    def is_file(self):
        pass

    def joinpath(self, *descendants):
        raise NotImplementedError

    def __truediv__(self, child):
        return self.joinpath(child)

    @_abc.abstractmethod
    def open(self, mode="r", *args, **kwargs):
        pass

    @property
    @_abc.abstractmethod
    def name(self):
        pass


class TraversableResources(ResourceLoader):
    """The required interface for providing traversable resources."""

    @_abc.abstractmethod
    def files(self):
        pass

    def open_resource(self, resource):
        return self.files().joinpath(resource).open("rb")

    def resource_path(self, resource):
        raise FileNotFoundError(resource)

    def is_resource(self, path):
        return self.files().joinpath(path).is_file()

    def contents(self):
        return (item.name for item in self.files().iterdir())

    def get_data(self, path):
        with open(path, "rb") as f:
            return f.read()
