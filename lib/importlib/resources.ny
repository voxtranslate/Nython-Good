# nython: module    (import it by name: it runs in a module scope of its own)
# lib/importlib/resources.ny - importlib.resources (CPython 3.12's API,
# round 80): data files that live beside a package's modules.
#
# files(anchor)  a pathlib.Path (a Traversable) of the package's directory -
#               anchor a module object or a module name ("pkg", "pkg.sub");
#               a plain module's is the directory it sits in (3.12's rule);
#               TypeError for a namespace package spread over several
#               directories (only the first is used here), ModuleNotFoundError
#               for a name that imports nothing
# as_file(traversable)  a context manager giving a real file system path
#               (the path itself: package data here is always on disk)
# read_text / read_binary / open_text / open_binary / is_resource /
# contents / path - the functional API (3.11's spelling, deprecated in
# CPython but kept: (package, resource) arguments)
#
# Not here: resources inside zip files (no zipimport), custom loaders'
# get_resource_reader (files() looks only at where the package's files are).
import pathlib as _pathlib
import contextlib as _contextlib

__all__ = ["Package", "as_file", "contents", "files", "is_resource", "open_binary",
           "open_text", "path", "read_binary", "read_text"]

Package = str


def _resolve(cand):
    if isinstance(cand, str):
        import importlib
        return importlib.import_module(cand)
    return cand


def files(anchor=None):
    """Get a Traversable resource for an anchor."""
    if anchor is None:
        import sys
        anchor = sys._getframe(1).f_globals.get("__name__", "__main__")
    module = _resolve(anchor)
    paths = getattr(module, "__path__", None)
    if paths:
        return _pathlib.Path(list(paths)[0])
    f = getattr(module, "__file__", None)
    if f is None:
        raise TypeError(repr(getattr(module, "__name__", module)) + " is not a package")
    return _pathlib.Path(f).parent


@_contextlib.contextmanager
def as_file(path):
    """Given a Traversable object, return that object as a path on the local
    file system in a context manager."""
    yield _pathlib.Path(path)


def _check_resource(resource):
    if not isinstance(resource, str):
        resource = str(resource)
    if "/" in resource or "\\" in resource:
        raise ValueError(repr(resource) + " must be only a file name")
    return resource


def open_binary(package, resource):
    """Open for binary reading the *resource* within *package*."""
    return (files(package) / _check_resource(resource)).open("rb")


def read_binary(package, resource):
    """Read and return contents of *resource* within *package* as bytes."""
    return (files(package) / _check_resource(resource)).read_bytes()


def open_text(package, resource, encoding="utf-8", errors="strict"):
    """Open for text reading the *resource* within *package*."""
    return (files(package) / _check_resource(resource)).open("r", encoding=encoding, errors=errors)


def read_text(package, resource, encoding="utf-8", errors="strict"):
    """Read and return contents of *resource* within *package* as str."""
    with open_text(package, resource, encoding, errors) as fp:
        return fp.read()


def contents(package):
    """Return an iterable of entries in *package*."""
    return [p.name for p in files(package).iterdir()]


def is_resource(package, name):
    """True if `name` is a resource inside `package`."""
    return (files(package) / name).is_file()


@_contextlib.contextmanager
def path(package, resource):
    """A context manager providing a file path object to the resource."""
    yield files(package) / _check_resource(resource)
