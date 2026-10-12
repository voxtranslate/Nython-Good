# nython: module    (import it by name: it runs in a module scope of its own)
# lib/platform.ny - Python's platform: identify the underlying platform.
#
#     system(), node(), release(), version(), machine(), processor(),
#     uname() -> uname_result(system, node, release, version, machine) with
#     .processor, platform(aliased=False, terse=False), architecture(),
#     libc_ver(), win32_ver(), win32_edition(), mac_ver(), freedesktop_os_release(),
#     python_implementation(), python_version(), python_version_tuple(),
#     python_build(), python_compiler(), python_branch(), python_revision(),
#     system_alias(), uname_result
#
# The values come from the native layer (os_uname: uname(2) on POSIX; on
# Windows the host name, with release/version from `ver` and the machine
# from PROCESSOR_ARCHITECTURE) and are cached as CPython caches them.
# platform() builds the same string as CPython ("Linux-6.8.0-x86_64-with-
# glibc2.39"); libc_ver() asks getconf GNU_LIBC_VERSION (CPython asks
# confstr, the same source).
#
# The interpreter is Nython, not CPython: python_implementation() returns
# "Nython", python_version() Nython's own version ("0.2.1", sys.version),
# python_compiler() "C++20" and python_build() ("nython", "").
# Code that tests python_version() against CPython releases should test
# python_implementation() first.

import os
import sys
import collections as _collections_mod

__all__ = ["architecture", "freedesktop_os_release", "libc_ver", "mac_ver", "machine",
           "node", "platform", "processor", "python_branch", "python_build",
           "python_compiler", "python_implementation", "python_revision",
           "python_version", "python_version_tuple", "release", "system",
           "system_alias", "uname", "uname_result", "version", "win32_edition",
           "win32_ver"]

_WINDOWS = os_platform() == "windows"
_NYTHON_VERSION = "0.2.1"
_uname_cache = none
_platform_cache = {}
_libc_cache = none
_os_release_cache = none


class uname_result:
    """
    A uname_result that's largely compatible with a
    simple namedtuple except that 'processor' is
    resolved late and cached to avoid calling "uname"
    except when needed.
    """
    _fields = ("system", "node", "release", "version", "machine")

    def __init__(self, system, node, release, version, machine):
        self.system = system
        self.node = node
        self.release = release
        self.version = version
        self.machine = machine
        self._processor = none

    @property
    def processor(self):
        if self._processor is none:
            self._processor = _unknown_as_blank(_processor_get())
        return self._processor

    def _items(self):
        return [self.system, self.node, self.release, self.version, self.machine, self.processor]

    def __iter__(self):
        return iter(self._items())

    def __len__(self):
        return 6

    def __getitem__(self, key):
        return tuple(self._items())[key]

    def __eq__(self, other):
        if isinstance(other, uname_result):
            return self._items() == other._items()
        if isinstance(other, tuple):
            return tuple(self._items()) == other
        return false

    def __hash__(self):
        return hash(tuple(self._items()))

    def __repr__(self):
        return ("uname_result(system=" + repr(self.system) + ", node=" + repr(self.node) +
                ", release=" + repr(self.release) + ", version=" + repr(self.version) +
                ", machine=" + repr(self.machine) + ")")

    def _replace(self, **kw):
        var d = {"system": self.system, "node": self.node, "release": self.release,
                 "version": self.version, "machine": self.machine}
        for k in kw:
            d[k] = kw[k]
        return uname_result(d["system"], d["node"], d["release"], d["version"], d["machine"])


def _unknown_as_blank(val):
    return "" if val == "unknown" else val


def _run_text(cmd):
    try:
        var r = os_run(cmd)
        if r["code"] != 0:
            return none
        return r["stdout"].strip()
    except Exception:
        return none


def _processor_get():
    if _WINDOWS:
        var p = os_getenv("PROCESSOR_IDENTIFIER")
        if p:
            return p
        return ""
    var out = _run_text(["uname", "-p"])
    if out is none:
        return ""
    return out


def _windows_ver():
    # "Microsoft Windows [Version 10.0.19045.3803]" -> ["10", "10.0.19045"]
    var out = _run_text("ver")
    if not out:
        return ["", ""]
    var i = out.find("[Version ")
    if i < 0:
        return ["", ""]
    var v = out[i + 9:]
    var j = v.find("]")
    if j >= 0:
        v = v[:j]
    var parts = v.split(".")
    var release = parts[0]
    var version = ".".join(parts[:3])
    if release == "6":
        var minor = parts[1] if len(parts) > 1 else ""
        release = {"0": "Vista", "1": "7", "2": "8", "3": "8.1"}.get(minor, release)
    elif release == "10" and len(parts) > 2:
        try:
            if int(parts[2]) >= 22000:
                release = "11"
        except Exception:
            pass
    return [release, version]


def uname():
    """ Fairly portable uname interface. Returns a tuple
        of strings (system, node, release, version, machine, processor)
        identifying the underlying platform.

        Entries which cannot be determined are set to ''.
    """
    global _uname_cache
    if _uname_cache is not none:
        return _uname_cache
    var u = os_uname()
    var system = u["sysname"]
    var node = u["nodename"]
    var release = u["release"]
    var version = u["version"]
    var machine = u["machine"]
    if _WINDOWS:
        var rv = _windows_ver()
        release = rv[0]
        version = rv[1]
        machine = os_getenv("PROCESSOR_ARCHITEW6432") or os_getenv("PROCESSOR_ARCHITECTURE") or ""
    if system == "Microsoft" and release == "Windows":
        system = "Windows"
        release = "Vista"
    _uname_cache = uname_result(_unknown_as_blank(system), _unknown_as_blank(node),
                                _unknown_as_blank(release), _unknown_as_blank(version),
                                _unknown_as_blank(machine))
    return _uname_cache


def system():
    """ Returns the system/OS name, e.g. 'Linux', 'Windows' or 'Java'.

        An empty string is returned if the value cannot be determined.
    """
    return uname().system


def node():
    """ Returns the computer's network name (which may not be fully
        qualified)

        An empty string is returned if the value cannot be determined.
    """
    return uname().node


def release():
    """ Returns the system's release, e.g. '2.2.0' or 'NT'

        An empty string is returned if the value cannot be determined.
    """
    return uname().release


def version():
    """ Returns the system's release version, e.g. '#3 on degas'

        An empty string is returned if the value cannot be determined.
    """
    return uname().version


def machine():
    """ Returns the machine type, e.g. 'i386'

        An empty string is returned if the value cannot be determined.
    """
    return uname().machine


def processor():
    """ Returns the (true) processor name, e.g. 'amdk6'

        An empty string is returned if the value cannot be
        determined. Note that many platforms do not provide this
        information or simply return the same value as for machine(),
        e.g.  NetBSD does this.
    """
    return uname().processor


def system_alias(system, release, version):
    """ Returns (system, release, version) aliased to common
        marketing names used for some systems.
    """
    if system == "SunOS":
        # Sun's OS
        if release < "5":
            # These releases use the old name SunOS
            return (system, release, version)
        # Modify release (marketing release = SunOS release - 3)
        var l = release.split(".")
        if l:
            try:
                var major = int(l[0])
                major = major - 3
                l[0] = str(major)
                release = ".".join(l)
            except ValueError:
                pass
        if release < "6":
            system = "Solaris"
        else:
            # XXX Whatever the new SunOS marketing name is...
            system = "Solaris"
    elif system in ["win32", "win16"]:
        # Windows platforms
        system = "Windows"
    return (system, release, version)


def libc_ver(executable=none, lib="", version="", chunksize=16384):
    """ Tries to determine the libc version that the file executable
        (which defaults to the Python interpreter) is linked against.

        Returns a tuple of strings (lib,version) which default to the
        given parameters in case the lookup fails.
    """
    global _libc_cache
    if _WINDOWS:
        return (lib, version)
    if _libc_cache is none:
        var out = _run_text(["getconf", "GNU_LIBC_VERSION"])
        _libc_cache = ["", ""]
        if out:
            var parts = out.split()
            if len(parts) == 2:
                _libc_cache = [parts[0], parts[1]]
    if _libc_cache[0]:
        return (_libc_cache[0], _libc_cache[1])
    return (lib, version)


def architecture(executable=none, bits="", linkage=""):
    """ Queries the given executable (defaults to the Python interpreter
        binary) for various architecture information.

        Returns a tuple (bits, linkage) which contains information about
        the bit architecture and the linkage format used for the
        executable. Both values are returned as strings.
    """
    if not bits:
        var m = machine().lower()
        if m in ["i386", "i486", "i586", "i686", "x86", "armv7l", "armv6l", "arm"]:
            bits = "32bit"
        else:
            bits = "64bit"
    if not linkage:
        var s = system()
        if s == "Windows":
            linkage = "WindowsPE"
        elif s in ["Linux", "FreeBSD", "OpenBSD", "NetBSD", "SunOS"]:
            linkage = "ELF"
    return (bits, linkage)


def win32_ver(release="", version="", csd="", ptype=""):
    if not _WINDOWS:
        return (release, version, csd, ptype)
    var u = uname()
    return (u.release, u.version, csd or "SP0", ptype or "Multiprocessor Free")


def win32_edition():
    return none


def win32_is_iot():
    return false


def mac_ver(release="", versioninfo=("", "", ""), machine=""):
    if system() != "Darwin":
        return (release, versioninfo, machine)
    var out = _run_text(["sw_vers", "-productVersion"])
    if out:
        release = out
    return (release, versioninfo, uname().machine)


def freedesktop_os_release():
    """Return operating system identification from freedesktop.org os-release
    """
    global _os_release_cache
    if _os_release_cache is none:
        var found = none
        for candidate in ["/etc/os-release", "/usr/lib/os-release"]:
            if os_isfile(candidate):
                found = candidate
                break
        if found is none:
            raise OSError("[Errno 2] Unable to read files /etc/os-release, /usr/lib/os-release")
        var info = {"NAME": "Linux", "ID": "linux", "PRETTY_NAME": "Linux"}
        var f = open(found)
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            var k = line[:line.find("=")]
            var v = line[line.find("=") + 1:]
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            info[k] = v
        f.close()
        _os_release_cache = info
    return dict(_os_release_cache)


def _platform(*args):
    """ Helper to format the platform string in a filename
        compatible format e.g. "system-version-machine".
    """
    var keep = []
    for x in args:
        if len(x):
            keep.append(x.strip())
    var platform = "-".join(keep)
    for ch in [" "]:
        platform = platform.replace(ch, "_")
    for ch in ["/", "\\", ":", ";", "\"", "(", ")"]:
        platform = platform.replace(ch, "-")
    # No need to report 'unknown' information...
    platform = platform.replace("unknown", "")
    # Fold '--'s and remove trailing '-'
    while true:
        var cleaned = platform.replace("--", "-")
        if cleaned == platform:
            break
        platform = cleaned
    while platform and platform[-1] == "-":
        platform = platform[:-1]
    return platform


def platform(aliased=false, terse=false):
    """ Returns a single string identifying the underlying platform
        with as much useful information as possible (but no more :).

        The output is intended to be human readable rather than
        machine parseable. It may look different on different
        platforms and this is intended.

        If "aliased" is true, the function will use aliases for
        various platforms that report system names which differ from
        their common names, e.g. SunOS will be reported as
        Solaris. The system_alias() function is used to implement
        this.

        Setting terse to true causes the function to return only the
        absolute minimum information needed to identify the platform.
    """
    var key = str(bool(aliased)) + str(bool(terse))
    var cached = _platform_cache.get(key)
    if cached is not none:
        return cached
    var u = uname()
    var system = u.system
    var release = u.release
    var version = u.version
    var machine = u.machine
    var processor = u.processor
    if machine == processor:
        processor = ""
    if aliased:
        var a = system_alias(system, release, version)
        system = a[0]
        release = a[1]
        version = a[2]
    if system == "Darwin":
        var macos_release = mac_ver()[0]
        if macos_release:
            system = "macOS"
            release = macos_release
    var result = ""
    if system == "Windows":
        var w = win32_ver(version)
        if terse:
            result = _platform(system, release)
        else:
            result = _platform(system, release, version, w[2])
    elif system == "Linux":
        var lc = libc_ver()
        result = _platform(system, release, machine, processor, "with", lc[0] + lc[1])
    else:
        if terse:
            result = _platform(system, release)
        else:
            var ar = architecture()
            result = _platform(system, release, machine, processor, ar[0], ar[1])
    _platform_cache[key] = result
    return result


def python_implementation():
    """ Returns a string identifying the Python implementation: here
        'Nython'.
    """
    return "Nython"


def python_version():
    """ Returns the interpreter's version as string 'major.minor.patchlevel'
        - Nython's own version (sys.version), not a CPython release.
    """
    var v = sys.version if hasattr(sys, "version") else _NYTHON_VERSION
    if not isinstance(v, str):
        v = _NYTHON_VERSION
    return v.split()[0]


def python_version_tuple():
    """ Returns the Python version as tuple (major, minor, patchlevel)
        of strings.
    """
    var parts = python_version().split(".")
    while len(parts) < 3:
        parts.append("0")
    return (parts[0], parts[1], parts[2])


def python_branch():
    return ""


def python_revision():
    return ""


def python_build():
    """ Returns a tuple (buildno, builddate) stating the Python
        build number and date as strings.
    """
    return ("nython", "")


def python_compiler():
    """ Returns a string identifying the compiler used for compiling
        the interpreter.
    """
    return "C++20"
