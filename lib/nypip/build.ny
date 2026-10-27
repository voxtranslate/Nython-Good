# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/build.ny - building a wheel from source (round 87): the PEP 517
# frontend, with PEP 518's isolated build environment.
#
#     wheel_path = build_wheel(src, out_dir, install_requires=fn)
#     wheel_path = build_from_sdist(sdist_path, out_dir, install_requires=fn)
#
# The source tree's pyproject.toml names the backend ([build-system]
# build-backend, backend-path) and what it needs (requires; a tree with no
# pyproject.toml is setuptools' legacy one: requires setuptools). The
# requirements are installed into a fresh directory by `install_requires(reqs,
# target_dir)` (the installer's resolver), and each hook - the backend's
# get_requires_for_build_wheel, whose answer is installed too, then
# build_wheel - runs in a subprocess of this interpreter
# (nypip/_in_process.ny) with that directory on NYTHONPATH and the source
# tree as its working directory. A backend written in Python runs on Nython
# as it does on CPython; one needing a C compiler does not.
#
# Written in the subset CPython runs too.

import os
import sys
import json
import shutil
import tempfile
import subprocess


class BuildError(Exception):
    pass


def read_build_system(src):
    p = os.path.join(src, "pyproject.toml")
    if not os.path.isfile(p):
        return {"requires": ["setuptools>=40.8.0"], "build-backend": "setuptools.build_meta:__legacy__",
                "backend-path": []}
    try:
        import tomllib
    except ImportError:
        import tomli as tomllib
    with open(p, "rb") as f:
        pp = tomllib.load(f)
    bs = pp.get("build-system")
    if bs is None:
        return {"requires": ["setuptools>=40.8.0"], "build-backend": "setuptools.build_meta:__legacy__",
                "backend-path": []}
    if "requires" not in bs:
        raise BuildError("pyproject.toml's [build-system] has no requires")
    return {"requires": list(bs["requires"]),
            "build-backend": bs.get("build-backend", "setuptools.build_meta:__legacy__"),
            "backend-path": list(bs.get("backend-path", []))}


def _hook_runner():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "_in_process.ny")


def call_hook(src, bs, hook, kwargs, env_dirs, log=None):
    control = tempfile.mkdtemp(prefix="nypip-hook-")
    try:
        bp = []
        for p in bs["backend-path"]:
            full = os.path.normpath(os.path.join(os.path.abspath(src), p))
            if not (full == os.path.abspath(src) or full.startswith(os.path.abspath(src) + os.sep)):
                raise BuildError("backend-path %r leaves the source tree" % p)
            bp.append(full)
        with open(os.path.join(control, "input.json"), "w", encoding="utf-8") as f:
            json.dump({"backend": bs["build-backend"], "backend_path": bp, "kwargs": kwargs}, f)
        env = dict(os.environ)
        paths = [d for d in env_dirs if d]
        if paths:
            env["NYTHONPATH"] = os.pathsep.join(paths)
            env["PYTHONPATH"] = os.pathsep.join(paths)
        else:
            env.pop("NYTHONPATH", None)
            env.pop("PYTHONPATH", None)
        exe = [sys.executable]
        if getattr(sys, "implementation", None) is not None and sys.implementation.name == "nython":
            if "--vm" in getattr(sys, "orig_argv", []):
                exe.append("--vm")
            # isolated: no site-packages (the environment's packages are not
            # the build's), the build requirements through NYTHONPATH
            exe.append("-S")
        if log:
            log("running the backend's %s (%s)" % (hook, bs["build-backend"]))
        r = subprocess.run(exe + [_hook_runner(), hook, control], cwd=src, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        outp = os.path.join(control, "output.json")
        if not os.path.isfile(outp):
            raise BuildError("the build backend's %s hook did not run (status %d):\n%s"
                             % (hook, r.returncode, r.stdout.decode("utf-8", "replace")))
        with open(outp, encoding="utf-8") as f:
            res = json.load(f)
        if "error" in res:
            raise BuildError("the build backend's %s hook failed: %s\n%s%s"
                             % (hook, res["error"], res.get("traceback", ""), r.stdout.decode("utf-8", "replace")))
        return res
    finally:
        shutil.rmtree(control, ignore_errors=True)


def build_wheel(src, out_dir, install_requires=None, log=None, keep_env=False):
    """Build a wheel of the source tree `src` into out_dir; its path."""
    src = os.path.abspath(src)
    bs = read_build_system(src)
    env_dir = tempfile.mkdtemp(prefix="nypip-build-env-")
    try:
        if bs["requires"]:
            if install_requires is None:
                raise BuildError("the build needs %s, and no installer was given" % ", ".join(bs["requires"]))
            install_requires(bs["requires"], env_dir)
        res = call_hook(src, bs, "get_requires_for_build_wheel", {"config_settings": None}, [env_dir], log)
        more = res.get("return_val") or []
        if more:
            if install_requires is None:
                raise BuildError("the build needs %s, and no installer was given" % ", ".join(more))
            install_requires(list(more), env_dir)
        os.makedirs(out_dir, exist_ok=True)
        res = call_hook(src, bs, "build_wheel", {"wheel_directory": os.path.abspath(out_dir),
                                                 "config_settings": None, "metadata_directory": None},
                        [env_dir], log)
        name = res.get("return_val")
        if not name or not os.path.isfile(os.path.join(out_dir, name)):
            raise BuildError("the build backend's build_wheel made no wheel")
        return os.path.join(out_dir, name)
    finally:
        if not keep_env:
            shutil.rmtree(env_dir, ignore_errors=True)


def unpack_sdist(path, dest):
    """The source tree an sdist (.tar.gz / .zip) holds, unpacked in dest."""
    if path.endswith(".zip"):
        import zipfile
        with zipfile.ZipFile(path) as zf:
            for n in zf.namelist():
                if n.startswith("/") or ".." in n.replace("\\", "/").split("/"):
                    raise BuildError("unsafe path in " + os.path.basename(path) + ": " + n)
            zf.extractall(dest)
    else:
        import tarfile
        with tarfile.open(path) as tf:
            for m in tf.getmembers():
                n = m.name
                if n.startswith("/") or ".." in n.split("/") or m.issym() or m.islnk() or m.isdev():
                    raise BuildError("unsafe member in " + os.path.basename(path) + ": " + n)
            tf.extractall(dest)
    entries = [e for e in os.listdir(dest) if not e.startswith(".")]
    if len(entries) == 1 and os.path.isdir(os.path.join(dest, entries[0])):
        return os.path.join(dest, entries[0])
    return dest


def build_from_sdist(path, out_dir, install_requires=None, log=None):
    tmp = tempfile.mkdtemp(prefix="nypip-sdist-")
    try:
        src = unpack_sdist(path, tmp)
        return build_wheel(src, out_dir, install_requires, log)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def sdist_metadata(path):
    """An sdist's PKG-INFO when it may stand for the built wheel's metadata
    (PEP 643: Metadata-Version 2.2 or later, Requires-Dist and
    Requires-Python not Dynamic); else None."""
    from nypip import metadata as _md
    data = None
    try:
        if path.endswith(".zip"):
            import zipfile
            with zipfile.ZipFile(path) as zf:
                for n in zf.namelist():
                    if n.count("/") == 1 and n.endswith("/PKG-INFO"):
                        data = zf.read(n)
                        break
        else:
            import tarfile
            with tarfile.open(path) as tf:
                for m in tf.getmembers():
                    if m.name.count("/") == 1 and m.name.endswith("/PKG-INFO"):
                        data = tf.extractfile(m).read()
                        break
    except Exception:
        return None
    if data is None:
        return None
    md = _md.Metadata.parse(data)
    try:
        ver = tuple(int(x) for x in (md.get("Metadata-Version") or "1.0").split("."))
    except ValueError:
        return None
    if ver < (2, 2):
        return None
    dyn = [d.lower() for d in md.get_all("Dynamic")]
    if "requires-dist" in dyn or "requires-python" in dyn:
        return None
    return md
