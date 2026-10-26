# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/ensurepip/__init__.ny - Python's ensurepip (round 87): bootstraps the
# installer into an installation or a virtual environment.
#
#     nython -m ensurepip [--root DIR] [--upgrade] [--user] [--altinstall]
#                         [--default-pip] [-v]
#     import ensurepip; ensurepip.bootstrap(upgrade=True, default_pip=True)
#
# Nython's installer is nypip (lib/nypip, with lib/pip as its alias), so
# what is installed is nypip itself: a wheel made from the standard
# library's own nypip/ and pip/ packages (CPython bundles pip's wheel
# instead), installed by nypip's wheel installer into site-packages - its
# dist-info, RECORD and commands: nypip, pip3, pip3.12, and pip with
# --default-pip (as CPython's, --altinstall only pip3.12). venv runs it in a
# new environment unless --without-pip. version(), bootstrap(),
# _bootstrap(), _main(), _uninstall_helper() - CPython's API.
import os
import sys
import tempfile
import shutil

__all__ = ["version", "bootstrap"]

_PACKAGES = ("nypip", "pip")


def _lib_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def version():
    """Returns a string specifying the bundled version of pip (nypip's)."""
    from nypip import __version__
    return __version__


def _wheel_files():
    files = {}
    lib = _lib_dir()
    for pkg in _PACKAGES:
        top = os.path.join(lib, pkg)
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
            for fn in sorted(filenames):
                if fn.endswith(".ny"):
                    full = os.path.join(dirpath, fn)
                    arc = os.path.relpath(full, lib).replace(os.sep, "/")
                    with open(full, "rb") as f:
                        files[arc] = f.read()
    return files


def _make_wheel(out_dir, scripts):
    from nypip.wheel import write_wheel
    eps = {"console_scripts": [(s, "nypip.cli:main") for s in scripts]}
    return write_wheel(out_dir, "nypip", version(), _wheel_files(), requires_python=">=3.8",
                       summary="Nython's package installer (pip)", entry_points=eps)


def bootstrap(*, root=None, upgrade=False, user=False,
              altinstall=False, default_pip=False,
              verbosity=0):
    """
    Bootstrap pip into the current Python installation (or the given root
    directory).

    Note that calling this function will alter both sys.path and os.environ.
    """
    # Discard the return value
    _bootstrap(root=root, upgrade=upgrade, user=user,
               altinstall=altinstall, default_pip=default_pip,
               verbosity=verbosity)


def _bootstrap(*, root=None, upgrade=False, user=False,
               altinstall=False, default_pip=False,
               verbosity=0):
    """
    Bootstrap pip into the current Python installation (or the given root
    directory). Returns pip command status code.
    """
    if altinstall and default_pip:
        raise ValueError("Cannot use altinstall and default_pip together")
    sys.audit("ensurepip.bootstrap", root)
    from nypip import installed as _inst
    from nypip.wheel import WheelFile
    scripts = ["nypip", "pip%d.%d" % sys.version_info[:2]]
    if not altinstall:
        scripts.append("pip%d" % sys.version_info[0])
        if default_pip:
            scripts.append("pip")
    scheme = _inst.scheme(user=user, root=root)
    old = _inst.get_distribution("nypip", [scheme["purelib"]])
    if old is not None:
        if not upgrade and old.version == version():
            if verbosity >= 0:
                print("Requirement already satisfied: nypip in %s (%s)" % (old.location, old.version))
            return 0
        old.uninstall()
    tmp = tempfile.mkdtemp(prefix="ensurepip-")
    try:
        path = _make_wheel(tmp, scripts)
        with WheelFile(path) as w:
            w.install(scheme, requested=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if verbosity >= 0:
        print("Successfully installed nypip-%s" % version())
    return 0


def _uninstall_helper(*, verbosity=0):
    """Helper to support a clean default uninstall process on Windows

    Note that calling this function may alter os.environ.
    """
    from nypip import installed as _inst
    d = _inst.get_distribution("nypip")
    if d is None:
        return
    if d.version != version():
        print("ensurepip will only uninstall a matching version "
              "({!r} installed, {!r} available)".format(d.version, version()), file=sys.stderr)
        return
    d.uninstall()
    return 0


def _main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(prog="python -m ensurepip")
    parser.add_argument(
        "--version",
        action="version",
        version="pip {}".format(version()),
        help="Show the version of pip that is bundled with this Python.",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="count",
        default=0,
        dest="verbosity",
        help=("Give more output. Option is additive, and can be used up to 3 "
              "times."),
    )
    parser.add_argument(
        "-U", "--upgrade",
        action="store_true",
        default=False,
        help="Upgrade pip and dependencies, even if already installed.",
    )
    parser.add_argument(
        "--user",
        action="store_true",
        default=False,
        help="Install using the user scheme.",
    )
    parser.add_argument(
        "--root",
        default=None,
        help="Install everything relative to this alternate root directory.",
    )
    parser.add_argument(
        "--altinstall",
        action="store_true",
        default=False,
        help=("Make an alternate install, installing only the X.Y versioned "
              "scripts (Default: pipX, pipX.Y)."),
    )
    parser.add_argument(
        "--default-pip",
        action="store_true",
        default=False,
        help=("Make a default pip install, installing the unqualified pip "
              "in addition to the versioned scripts."),
    )

    args = parser.parse_args(argv)

    return _bootstrap(
        root=args.root,
        upgrade=args.upgrade,
        user=args.user,
        verbosity=args.verbosity,
        altinstall=args.altinstall,
        default_pip=args.default_pip,
    )
