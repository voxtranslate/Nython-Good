# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/zipimport.ny - Python's zipimport module (round 83): import modules
# from zip archives on sys.path.
#
#     import sys, zipimport
#     sys.path.insert(0, "mods.zip")
#     import mymod                       # mods.zip/mymod.py (or .ny), packages too
#     zipimport.zipimporter("mods.zip").get_source("mymod")
#     # and:  nython app.pyz   runs the archive's __main__ (zipapp's)
#
# zipimporter(archivepath) - the path may go on inside the archive
# ("lib.zip/pkg") - with find_spec, create_module/exec_module, get_code,
# get_source, get_data, get_filename, is_package, get_resource_reader,
# invalidate_caches, load_module (deprecated, as CPython's), archive,
# prefix; ZipImportError (an ImportError) and error. Importing the module
# puts zipimporter on sys.path_hooks, as CPython's startup does, so the
# import statement (which honours sys.path_hooks since round 81) finds what
# a zip on sys.path holds: modules (name.ny before name.py, as in a
# directory), packages (__init__), subpackages and relative imports inside
# them. `nython app.pyz` and `nython dir` run __main__ through _run_main
# (src/main.cpp), as CPython runs zip applications and directories.
#
# Built over lib/zipfile.ny (stored and deflated members), not CPython's own
# zip reader; sources are compiled from text - there is no bytecode here, so
# .pyc members are not used (CPython's prefers them when they are fresh).
#
# Not here: zip64 archives beyond what zipfile reads; .pyc members.
import sys
import os
import zipfile
import importlib.machinery as _machinery

__all__ = ["ZipImportError", "zipimporter"]


class ZipImportError(ImportError):
    pass


error = ZipImportError
ZipImportError.__module__ = "zipimport"

_zip_directory_cache = {}
_SUFFIXES = (".ny", ".py")


def _split_archive(path):
    # the archive file and what follows it inside ("a.zip/pkg/sub")
    var prefix = []
    var p = path
    while True:
        if os.path.isfile(p):
            break
        var head = os.path.dirname(p)
        var tail = os.path.basename(p)
        if not tail or head == p:
            raise ZipImportError("not a Zip file", path=path)
        prefix.insert(0, tail)
        p = head
    return p, "/".join(prefix)


def _read_directory(archive):
    try:
        with zipfile.ZipFile(archive) as z:
            var names = set()
            for info in z.infolist():
                names.add(info.filename)
            return names
    except (zipfile.BadZipFile, OSError) as e:
        raise ZipImportError("can't read Zip file: " + repr(archive), path=archive) from None


class zipimporter:
    """zipimporter(archivepath) -> zipimporter object

    Create a new zipimporter instance. 'archivepath' must be a path to
    a zipfile, or to a specific path inside a zipfile."""

    def __init__(self, path):
        if not isinstance(path, str):
            path = os.fsdecode(path)
        if not path:
            raise ZipImportError("archive path is empty", path=path)
        if os.altsep:
            path = path.replace(os.altsep, os.sep)
        var split = _split_archive(path)
        var archive = split[0]
        if not zipfile.is_zipfile(archive):
            raise ZipImportError("not a Zip file", path=archive)
        var files = _zip_directory_cache.get(archive)
        if files is None:
            files = _read_directory(archive)
            _zip_directory_cache[archive] = files
        self._files = files
        self.archive = archive
        self.prefix = split[1] + "/" if split[1] else ""

    def __repr__(self):
        return '<zipimporter object "' + self.archive + os.sep + self.prefix + '">'

    # ── where a module is ──────────────────────────────────────────────────
    def _subname(self, fullname):
        return fullname.rpartition(".")[2]

    def _lookup(self, fullname):
        # (member path, is_package) or None
        var base = self.prefix + self._subname(fullname)
        for suf in _SUFFIXES:
            if base + "/__init__" + suf in self._files:
                return (base + "/__init__" + suf, True)
        for suf in _SUFFIXES:
            if base + suf in self._files:
                return (base + suf, False)
        return None

    def _is_dir(self, fullname):
        var base = self.prefix + self._subname(fullname) + "/"
        for n in self._files:
            if n.startswith(base):
                return True
        return False

    def _full(self, member):
        return self.archive + os.sep + member.replace("/", os.sep)

    def find_spec(self, fullname, target=None):
        """Create a ModuleSpec for the specified module.

        Returns None if the module cannot be found."""
        var found = self._lookup(fullname)
        if found is not None:
            var spec = _machinery.ModuleSpec(fullname, self, origin=self._full(found[0]), is_package=found[1])
            spec.has_location = True
            if found[1]:
                spec.submodule_search_locations = [self._full(self.prefix + self._subname(fullname))]
            return spec
        if self._is_dir(fullname):
            # a namespace package portion
            var ns = _machinery.ModuleSpec(fullname, None, is_package=True)
            ns.submodule_search_locations = [self._full(self.prefix + self._subname(fullname))]
            return ns
        return None

    def _need(self, fullname):
        var found = self._lookup(fullname)
        if found is None:
            raise ZipImportError("can't find module " + repr(fullname), name=fullname)
        return found

    def _read(self, member):
        with zipfile.ZipFile(self.archive) as z:
            return z.read(member)

    def get_source(self, fullname):
        """Return the source code for the specified module."""
        var found = self._need(fullname)
        return self._read(found[0]).decode("utf-8")

    def get_code(self, fullname):
        """Return the code object for the specified module."""
        var found = self._need(fullname)
        return compile(self._read(found[0]).decode("utf-8"), self._full(found[0]), "exec")

    def get_filename(self, fullname):
        """Return the filename for the specified module or raise ZipImportError."""
        return self._full(self._need(fullname)[0])

    def is_package(self, fullname):
        """Return True if the module specified by fullname is a package."""
        return self._need(fullname)[1]

    def get_data(self, pathname):
        """Return the data associated with 'pathname'."""
        if os.altsep:
            pathname = pathname.replace(os.altsep, os.sep)
        var key = pathname
        if pathname.startswith(self.archive + os.sep):
            key = pathname[len(self.archive + os.sep):]
        key = key.replace(os.sep, "/")
        if key not in self._files:
            raise OSError(0, "", key)
        return self._read(key)

    def create_module(self, spec):
        """Use default semantics for module creation."""
        # a types.ModuleType: its __dict__ is live, so the module's code
        # binds into it (the import statement's default module is not one
        # exec() can fill through vars())
        import types
        return types.ModuleType(spec.name)

    def exec_module(self, module):
        """Execute the module."""
        var name = module.__name__
        var found = self._need(name)
        var path = self._full(found[0])
        module.__file__ = path
        if found[1]:
            module.__path__ = [self._full(self.prefix + self._subname(name))]
        var code = compile(self._read(found[0]).decode("utf-8"), path, "exec")
        exec(code, module.__dict__)

    def load_module(self, fullname):
        """Load the module specified by 'fullname' (deprecated: use exec_module)."""
        import warnings
        warnings.warn("zipimport.zipimporter.load_module() is deprecated and slated for removal in Python 3.12; "
                      "use exec_module() instead", DeprecationWarning)
        var spec = self.find_spec(fullname)
        if spec is None:
            raise ZipImportError("can't find module " + repr(fullname), name=fullname)
        import types
        var mod = sys.modules.get(fullname)
        if mod is None:
            mod = types.ModuleType(fullname)
            sys.modules[fullname] = mod
        mod.__loader__ = self
        mod.__spec__ = spec
        try:
            self.exec_module(mod)
        except BaseException:
            sys.modules.pop(fullname, None)
            raise
        return sys.modules[fullname]

    def get_resource_reader(self, fullname):
        """Return the ResourceReader for a package in a zip file."""
        try:
            if not self.is_package(fullname):
                return None
        except ZipImportError:
            return None
        return _ZipReader(self, fullname)

    def invalidate_caches(self):
        """Reload the file data of the archive path."""
        try:
            self._files = _read_directory(self.archive)
            _zip_directory_cache[self.archive] = self._files
        except ZipImportError:
            _zip_directory_cache.pop(self.archive, None)
            self._files = set()


class _ZipReader:
    def __init__(self, importer, fullname):
        self._importer = importer
        self._base = importer.prefix + fullname.rpartition(".")[2] + "/"

    def open_resource(self, resource):
        import io
        return io.BytesIO(self._importer._read(self._base + resource))

    def resource_path(self, resource):
        raise FileNotFoundError(resource)

    def is_resource(self, name):
        return (self._base + name) in self._importer._files

    def contents(self):
        var out = []
        for n in self._importer._files:
            if n.startswith(self._base):
                var rest = n[len(self._base):]
                var first = rest.split("/", 1)[0]
                if first and first not in out:
                    out.append(first)
        return iter(out)


def _hook(path):
    # sys.path_hooks entry: an archive (or a path inside one) gets a
    # zipimporter; anything else is someone else's (ImportError)
    if not isinstance(path, str) or not path:
        raise ZipImportError("not a Zip file")
    return zipimporter(path)


if zipimporter not in sys.path_hooks:
    sys.path_hooks.insert(0, zipimporter)


def _run_main(path):
    # `nython app.pyz` / `nython dir` (src/main.cpp): the archive (or the
    # directory) first on sys.path, its __main__ run as the main module
    if sys.path and sys.path[0] in ("", os.path.dirname(os.path.abspath(path)), os.path.dirname(path)):
        sys.path[0] = path
    else:
        sys.path.insert(0, path)
    var main = sys.modules.get("__main__")
    var g = main.__dict__ if main is not None else globals()
    var src = None
    var fname = None
    if os.path.isdir(path):
        for suf in _SUFFIXES:
            var cand = os.path.join(path, "__main__" + suf)
            if os.path.isfile(cand):
                with open(cand, encoding="utf-8") as f:
                    src = f.read()
                fname = cand
                break
    else:
        var zi = zipimporter(path)
        for suf in _SUFFIXES:
            if "__main__" + suf in zi._files:
                src = zi._read("__main__" + suf).decode("utf-8")
                fname = path + os.sep + "__main__" + suf
                g["__loader__"] = zi
                break
    if src is None:
        raise SystemExit("can't find '__main__' module in " + repr(path))
    g["__file__"] = fname
    exec(compile(src, fname, "exec"), g)
