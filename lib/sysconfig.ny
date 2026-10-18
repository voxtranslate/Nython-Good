# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/sysconfig.ny - Python's sysconfig module (round 83): where Nython's
# installation keeps things, and how it was configured.
#
#     import sysconfig
#     sysconfig.get_paths()["stdlib"]          # <prefix>/lib
#     sysconfig.get_platform()                 # 'linux-x86_64', 'win-amd64', 'macosx-11.0-arm64'
#     sysconfig.get_config_var("EXE")          # '' or '.exe'
#
# get_paths(scheme, vars, expand), get_path(name, scheme, vars, expand),
# get_path_names(), get_scheme_names(), get_default_scheme(),
# get_preferred_scheme(key), get_config_vars(*args), get_config_var(name),
# get_platform(), get_python_version(), is_python_build(check_home=False),
# get_makefile_filename(), parse_config_h(fp, vars=None),
# get_config_h_filename(), _get_preferred_schemes - CPython's API and
# scheme table, with the values describing Nython honestly:
#   - a Nython installation is its source tree: sys.prefix is the directory
#     holding lib/ (the standard library, `stdlib` and `platstdlib`),
#     include/ (the engines' C++ headers), build/ (the nython binaries,
#     `scripts`); `purelib`/`platlib` (site-packages) are
#     <prefix>/lib/site-packages for the prefix schemes and
#     ~/.local/lib/nython<X.Y>/site-packages for the user scheme (Nython
#     imports .py modules too, but does not share CPython's site-packages);
#   - config vars: prefix, exec_prefix, base, platbase, installed_base,
#     projectbase, srcdir (<prefix>), py_version, py_version_short,
#     py_version_nodot, VERSION, EXE, EXT_SUFFIX/SO/SOABI ('': there are no
#     C extension modules), abiflags, LIBDIR, BINDIR, INCLUDEPY, CC/CXX
#     (the compiler the Makefile uses), Py_GIL_DISABLED (0), userbase,
#     platlibdir, MULTIARCH; the rest is None, as get_config_var gives for a
#     name it does not know.
#
# Not here: the build-time variables CPython reads from its Makefile and
# pyconfig.h (Nython's Makefile is read by get_makefile_filename's users,
# not parsed into config vars).
import os
import sys

__all__ = ["get_config_h_filename", "get_config_var", "get_config_vars", "get_makefile_filename",
           "get_path", "get_path_names", "get_paths", "get_platform", "get_python_version",
           "get_scheme_names", "parse_config_h"]

_PY_VERSION = "%d.%d.%d" % sys.version_info[:3]
_PY_VERSION_SHORT = "%d.%d" % sys.version_info[:2]
_PY_VERSION_SHORT_NO_DOT = "%d%d" % sys.version_info[:2]
_PREFIX = os.path.normpath(sys.prefix)
_BASE_PREFIX = os.path.normpath(sys.base_prefix)

_INSTALL_SCHEMES = {
    "posix_prefix": {
        "stdlib": "{installed_base}/lib",
        "platstdlib": "{platbase}/lib",
        "purelib": "{base}/lib/site-packages",
        "platlib": "{platbase}/lib/site-packages",
        "include": "{installed_base}/include",
        "platinclude": "{installed_platbase}/include",
        "scripts": "{base}/build",
        "data": "{base}",
    },
    "posix_home": {
        "stdlib": "{installed_base}/lib",
        "platstdlib": "{base}/lib",
        "purelib": "{base}/lib",
        "platlib": "{base}/lib",
        "include": "{installed_base}/include",
        "platinclude": "{installed_base}/include",
        "scripts": "{base}/bin",
        "data": "{base}",
    },
    "nt": {
        "stdlib": "{installed_base}/lib",
        "platstdlib": "{base}/lib",
        "purelib": "{base}/lib/site-packages",
        "platlib": "{base}/lib/site-packages",
        "include": "{installed_base}/include",
        "platinclude": "{installed_base}/include",
        "scripts": "{base}/build",
        "data": "{base}",
    },
    "venv": {
        "stdlib": "{installed_base}/lib",
        "platstdlib": "{platbase}/lib",
        "purelib": "{base}/lib/site-packages",
        "platlib": "{platbase}/lib/site-packages",
        "include": "{installed_base}/include",
        "platinclude": "{installed_platbase}/include",
        "scripts": "{base}/bin",
        "data": "{base}",
    },
    "nt_user": {
        "stdlib": "{userbase}/Nython{py_version_nodot_plat}",
        "platstdlib": "{userbase}/Nython{py_version_nodot_plat}",
        "purelib": "{userbase}/Nython{py_version_nodot_plat}/site-packages",
        "platlib": "{userbase}/Nython{py_version_nodot_plat}/site-packages",
        "include": "{userbase}/Nython{py_version_nodot_plat}/Include",
        "scripts": "{userbase}/Nython{py_version_nodot_plat}/Scripts",
        "data": "{userbase}",
    },
    "posix_user": {
        "stdlib": "{userbase}/{platlibdir}/nython{py_version_short}",
        "platstdlib": "{userbase}/{platlibdir}/nython{py_version_short}",
        "purelib": "{userbase}/lib/nython{py_version_short}/site-packages",
        "platlib": "{userbase}/lib/nython{py_version_short}/site-packages",
        "include": "{userbase}/include/nython{py_version_short}",
        "scripts": "{userbase}/bin",
        "data": "{userbase}",
    },
    "osx_framework_user": {
        "stdlib": "{userbase}/lib/nython",
        "platstdlib": "{userbase}/lib/nython",
        "purelib": "{userbase}/lib/nython/site-packages",
        "platlib": "{userbase}/lib/nython/site-packages",
        "include": "{userbase}/include/nython{py_version_short}",
        "scripts": "{userbase}/bin",
        "data": "{userbase}",
    },
}

_SCHEME_KEYS = ("stdlib", "platstdlib", "purelib", "platlib", "include", "scripts", "data")
_CONFIG_VARS = None


def _getuserbase():
    var env_base = os.environ.get("PYTHONUSERBASE", None)
    if env_base:
        return env_base

    def joinuser(*args):
        return os.path.expanduser(os.path.join(*args))

    if os.name == "nt":
        var base = os.environ.get("APPDATA") or "~"
        return joinuser(base, "Nython")
    return joinuser("~", ".local")


def _expand_vars(scheme, vars):
    var res = {}
    if vars is None:
        vars = {}
    var cv = get_config_vars()
    for key, value in _INSTALL_SCHEMES[scheme].items():
        if os.name in ("posix", "nt"):
            value = os.path.expanduser(value)
        res[key] = os.path.normpath(_subst_vars(value, vars, cv))
    return res


def _subst_vars(s, local_vars, cv):
    import re

    def repl(m):
        var name = m.group(1)
        if name in local_vars:
            return str(local_vars[name])
        if name in cv:
            return str(cv[name])
        if name in os.environ:
            return os.environ[name]
        raise AttributeError("{%s}" % name)

    try:
        return re.sub(r"\{([^{]*?)\}", repl, s)
    except AttributeError as e:
        raise ValueError(str(e)) from None


def _get_preferred_schemes():
    if os.name == "nt":
        return {"prefix": "nt", "home": "posix_home", "user": "nt_user"}
    if sys.platform == "darwin" and getattr(sys, "_framework", None):
        return {"prefix": "posix_prefix", "home": "posix_home", "user": "osx_framework_user"}
    return {"prefix": "posix_prefix", "home": "posix_home", "user": "posix_user"}


def get_preferred_scheme(key):
    if key == "prefix" and sys.prefix != sys.base_prefix:
        return "venv"
    var scheme = _get_preferred_schemes()[key]
    if scheme not in _INSTALL_SCHEMES:
        raise ValueError(repr(scheme) + " returned by sysconfig._get_preferred_schemes() is not a valid scheme name")
    return scheme


def get_default_scheme():
    return get_preferred_scheme("prefix")


def get_scheme_names():
    """Return a tuple containing the schemes names."""
    return tuple(sorted(_INSTALL_SCHEMES))


def get_path_names():
    """Return a tuple containing the paths names."""
    return _SCHEME_KEYS


def get_paths(scheme=None, vars=None, expand=True):
    """Return a mapping containing an install scheme."""
    if scheme is None:
        scheme = get_default_scheme()
    if expand:
        return _expand_vars(scheme, vars)
    return dict(_INSTALL_SCHEMES[scheme])


def get_path(name, scheme=None, vars=None, expand=True):
    """Return a path corresponding to the scheme."""
    return get_paths(scheme, vars, expand)[name]


def _host_compiler():
    try:
        with open(os.path.join(_PREFIX, "Makefile")) as f:
            for line in f:
                if line.startswith("CXX ") or line.startswith("CXX=") or line.startswith("CXX?="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return "g++"


def get_config_vars(*args):
    """With no arguments, return a dictionary of all configuration
    variables relevant for the current platform."""
    global _CONFIG_VARS
    if _CONFIG_VARS is None:
        var cv = {}
        cv["prefix"] = _PREFIX
        cv["exec_prefix"] = os.path.normpath(sys.exec_prefix)
        cv["py_version"] = _PY_VERSION
        cv["py_version_short"] = _PY_VERSION_SHORT
        cv["py_version_nodot"] = _PY_VERSION_SHORT_NO_DOT
        cv["py_version_nodot_plat"] = _PY_VERSION_SHORT_NO_DOT if os.name == "nt" else ""
        cv["installed_base"] = _BASE_PREFIX
        cv["base"] = _PREFIX
        cv["installed_platbase"] = _BASE_PREFIX
        cv["platbase"] = _PREFIX
        cv["projectbase"] = _PREFIX
        cv["srcdir"] = _PREFIX
        cv["platlibdir"] = getattr(sys, "platlibdir", "lib")
        cv["abiflags"] = ""
        cv["VERSION"] = _PY_VERSION_SHORT
        cv["EXE"] = ".exe" if os.name == "nt" else ""
        cv["EXT_SUFFIX"] = ""
        cv["SO"] = ""
        cv["SOABI"] = ""
        cv["LIBDIR"] = os.path.join(_PREFIX, "lib")
        cv["BINDIR"] = os.path.dirname(sys.executable) if sys.executable else os.path.join(_PREFIX, "build")
        cv["INCLUDEPY"] = os.path.join(_PREFIX, "include")
        cv["LIBDEST"] = os.path.join(_PREFIX, "lib")
        cv["BINLIBDEST"] = os.path.join(_PREFIX, "lib")
        cv["CC"] = _host_compiler()
        cv["CXX"] = cv["CC"]
        cv["Py_GIL_DISABLED"] = 0
        cv["Py_ENABLE_SHARED"] = 0
        cv["MULTIARCH"] = sys.implementation._multiarch if hasattr(sys.implementation, "_multiarch") else ""
        cv["userbase"] = _getuserbase()
        cv["implementation"] = "Nython"
        cv["implementation_lower"] = "nython"
        if os.name == "nt":
            cv["BINDIR"] = os.path.dirname(sys.executable) if sys.executable else _PREFIX
        _CONFIG_VARS = cv
    if args:
        return [_CONFIG_VARS.get(name) for name in args]
    return _CONFIG_VARS


def get_config_var(name):
    """Return the value of a single variable using the dictionary returned by
    'get_config_vars()'."""
    return get_config_vars().get(name)


def get_platform():
    """Return a string that identifies the current platform."""
    if os.name == "nt":
        import platform
        var m = platform.machine().lower()
        if "amd64" in m or "x86_64" in m:
            return "win-amd64"
        if "arm64" in m or "aarch64" in m:
            return "win-arm64"
        return "win32"
    var u = os.uname()
    var osname = u.sysname.lower().replace("/", "")
    var machine = u.machine.replace(" ", "_").replace("/", "_")
    if osname == "linux":
        return osname + "-" + machine
    if osname == "darwin":
        import platform
        var rel = platform.mac_ver()[0] or "11.0"
        var parts = rel.split(".")
        if int(parts[0]) >= 11:
            rel = parts[0] + ".0"
        else:
            rel = ".".join(parts[:2])
        return "macosx-" + rel + "-" + machine
    return osname + "-" + u.release + "-" + machine


def get_python_version():
    return _PY_VERSION_SHORT


def is_python_build(check_home=None):
    """True when the running interpreter is the one built in its source tree
    (a Nython installation always is: build/nython-cli beside lib/)."""
    return os.path.isfile(os.path.join(_PREFIX, "Makefile"))


def get_makefile_filename():
    """Return the path of the Makefile."""
    return os.path.join(_PREFIX, "Makefile")


def get_config_h_filename():
    """Return the path of pyconfig.h (Nython has none: its platform header)."""
    return os.path.join(_PREFIX, "include", "platform_compat.hpp")


def parse_config_h(fp, vars=None):
    """Parse a config.h-style file."""
    import re
    if vars is None:
        vars = {}
    var define_rx = re.compile("#define ([A-Z][A-Za-z0-9_]+) (.*)\n")
    var undef_rx = re.compile("/[*] #undef ([A-Z][A-Za-z0-9_]+) [*]/\n")
    while True:
        var line = fp.readline()
        if not line:
            break
        var m = define_rx.match(line)
        if m:
            var n = m.group(1)
            var v = m.group(2)
            try:
                if n in ("_LARGEFILE_SOURCE",):
                    v = 1
                else:
                    v = int(v)
            except ValueError:
                pass
            vars[n] = v
        else:
            m = undef_rx.match(line)
            if m:
                vars[m.group(1)] = 0
    return vars


def _main():
    """Display all information sysconfig detains."""
    print('Platform: "%s"' % get_platform())
    print('Python version: "%s"' % get_python_version())
    print('Current installation scheme: "%s"' % get_default_scheme())
    print()
    print("Paths: ")
    for key, value in sorted(get_paths().items()):
        print('\t%s = "%s"' % (key, value))
    print()
    print("Variables: ")
    for key, value in sorted(get_config_vars().items()):
        print('\t%s = "%s"' % (key, value))


if __name__ == "__main__":
    _main()
