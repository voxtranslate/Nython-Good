# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/wheel.ny - wheels (PEP 427, the binary distribution format):
# reading, installing and writing them (round 87).
#
#     w = WheelFile("pkg-1.0-py3-none-any.whl")
#     w.name, w.version, w.tags, w.metadata (Metadata), w.entry_points()
#     files = w.install(scheme)        # scheme: purelib/platlib/scripts/data/headers
#     write_wheel(out_dir, "pkg", "1.0", {"pkg/__init__.py": b"..."},
#                 requires=["dep>=1"], entry_points={"console_scripts": [("pkg", "pkg:main")]})
#
# Installing follows the specification's steps: the WHEEL file's
# Wheel-Version (1.x) and Root-Is-Purelib, every file checked against its
# RECORD hash (a file RECORD does not list, or a hash that does not match, is
# an error: nothing of a corrupt wheel stays installed), the
# <name>-<version>.data/<key>/ directories to the scheme's paths, scripts'
# `#!python` lines rewritten to this interpreter, console and GUI scripts
# made from entry_points.txt (POSIX: an executable script whose first line
# runs this interpreter; Windows: a .cmd file beside a -script.py one), and
# the installed RECORD (every file with its sha256 and size, the generated
# ones too), INSTALLER, REQUESTED and direct_url.json (PEP 610) written into
# the .dist-info directory. Paths are checked to stay inside their target.
# Written in the subset CPython runs too.

import os
import re
import sys
import stat
import json
import zipfile

from nypip import metadata as _md
from nypip._packaging.utils import parse_wheel_filename, canonicalize_name
from nypip._packaging.version import Version


class WheelError(Exception):
    pass


def escape_name(name):
    return re.sub(r"[-_.]+", "_", name).lower()


def escape_version(version):
    return str(Version(str(version))).replace("-", "_")


def _safe_join(base, rel):
    rel = rel.replace("\\", "/")
    if rel.startswith("/") or (len(rel) > 1 and rel[1] == ":"):
        raise WheelError("absolute path in wheel: " + rel)
    parts = []
    for p in rel.split("/"):
        if p in ("", "."):
            continue
        if p == "..":
            raise WheelError("path leaves its directory: " + rel)
        parts.append(p)
    return os.path.join(base, *parts)


_EP_RE = re.compile(r"^(?P<module>[\w.]+)\s*(:\s*(?P<attrs>[\w.]+)\s*)?(\[(?P<extras>[^\]]*)\])?\s*$")


def parse_entry_point(value):
    """'pkg.mod:obj.attr [extra]' -> (module, attrs or None, extras)"""
    m = _EP_RE.match(value.strip())
    if m is None:
        raise WheelError("invalid entry point: " + value)
    ex = m.group("extras")
    return m.group("module"), m.group("attrs"), [e.strip() for e in ex.split(",") if e.strip()] if ex else []


_SCRIPT_BODY = """# -*- coding: utf-8 -*-
# nython: python
import re
import sys
from %(module)s import %(import_name)s
if __name__ == "__main__":
    sys.argv[0] = re.sub(r"(-script\\.pyw|\\.exe|\\.cmd)?$", "", sys.argv[0])
    sys.exit(%(func)s())
"""


def shebang(executable):
    """The first line(s) of a script run by `executable` - pip's form for a
    path the kernel's #! line cannot hold (spaces, over 127 bytes)."""
    if " " not in executable and len(executable) < 127:
        return "#!" + executable + "\n"
    return "#!/bin/sh\n'''exec' \"" + executable + "\" \"$0\" \"$@\"\n' '''\n"


def make_script(name, value, scripts_dir, executable=None):
    """Write the command `name` for entry point `value`; the paths written."""
    module, attrs, _ = parse_entry_point(value)
    if not attrs:
        raise WheelError("entry point %s = %s names no object" % (name, value))
    import_name = attrs.split(".")[0]
    body = _SCRIPT_BODY % {"module": module, "import_name": import_name, "func": attrs}
    exe = executable or sys.executable
    os.makedirs(scripts_dir, exist_ok=True)
    out = []
    if os.name == "nt":
        script = os.path.join(scripts_dir, name + "-script.py")
        with open(script, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        cmd = os.path.join(scripts_dir, name + ".cmd")
        with open(cmd, "w", encoding="utf-8", newline="") as f:
            f.write("@\"%s\" \"%%~dp0%s-script.py\" %%*\r\n" % (exe, name))
        out = [script, cmd]
    else:
        path = os.path.join(scripts_dir, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(shebang(exe) + body)
        os.chmod(path, 0o755)
        out = [path]
    return out


class WheelFile:
    def __init__(self, path):
        self.path = path
        self.filename = os.path.basename(path)
        try:
            name, version, build, tags = parse_wheel_filename(self.filename)
        except Exception as e:
            raise WheelError(str(e)) from None
        self.project = name                     # canonical
        self.version = version
        self.build = build
        self.tags = tags
        try:
            self.zf = zipfile.ZipFile(path)
        except zipfile.BadZipFile as e:
            raise WheelError("%s is not a zip file: %s" % (self.filename, e)) from None
        self.dist_info = self._find_dist_info()
        self.metadata = _md.Metadata.parse(self.read(self.dist_info + "/METADATA"))
        try:
            self.wheel_meta = _md.Metadata.parse(self.read(self.dist_info + "/WHEEL"))
        except KeyError:
            raise WheelError(self.filename + " has no WHEEL file") from None
        self.name = self.metadata.name or name

    def _find_dist_info(self):
        cands = set()
        for n in self.zf.namelist():
            top = n.split("/")[0]
            if top.endswith(".dist-info"):
                cands.add(top)
        if not cands:
            raise WheelError(self.filename + " has no .dist-info directory")
        if len(cands) == 1:
            return cands.pop()
        for c in sorted(cands):
            if canonicalize_name(c[:-10].rsplit("-", 1)[0]) == self.project:
                return c
        raise WheelError(self.filename + " has several .dist-info directories")

    @property
    def data_dir(self):
        return self.dist_info[:-10] + ".data"

    def read(self, name):
        return self.zf.read(name)

    def close(self):
        self.zf.close()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    def entry_points(self):
        try:
            return _md.parse_entry_points(self.read(self.dist_info + "/entry_points.txt"))
        except KeyError:
            return {}

    def record(self):
        try:
            rows = _md.parse_record(self.read(self.dist_info + "/RECORD"))
        except KeyError:
            raise WheelError(self.filename + " has no RECORD") from None
        return {r[0]: r for r in rows}

    def check_version(self):
        wv = self.wheel_meta.get("Wheel-Version", "")
        try:
            major = int(wv.split(".")[0])
        except ValueError:
            raise WheelError(self.filename + " has an invalid Wheel-Version: " + repr(wv)) from None
        if major != 1:
            raise WheelError(self.filename + " is Wheel-Version " + wv + " (this installer reads 1.x)")

    def verify(self):
        """Every file against RECORD (WheelError on a mismatch)."""
        rec = self.record()
        for info in self.zf.infolist():
            n = info.filename
            if n.endswith("/"):
                continue
            if n in (self.dist_info + "/RECORD", self.dist_info + "/RECORD.jws", self.dist_info + "/RECORD.p7s"):
                continue
            r = rec.get(n)
            if r is None:
                raise WheelError("%s: %s is not listed in RECORD" % (self.filename, n))
            if r[1]:
                algo = r[1].split("=", 1)[0]
                if algo in ("md5", "sha1"):
                    raise WheelError("%s: RECORD uses the weak hash %s" % (self.filename, algo))
                data = self.zf.read(n)
                if _md.record_hash(data, algo) != r[1]:
                    raise WheelError("%s: the hash of %s does not match RECORD" % (self.filename, n))

    def install(self, scheme, installer="nypip", requested=False, direct_url=None, executable=None):
        """Unpack into `scheme` (a dict of purelib, platlib, scripts, data,
        headers); returns the paths written."""
        self.check_version()
        self.verify()
        purelib = self.wheel_meta.get("Root-Is-Purelib", "true").strip().lower() == "true"
        root = scheme["purelib"] if purelib else scheme["platlib"]
        os.makedirs(root, exist_ok=True)
        exe = executable or sys.executable
        written = []
        rows = []

        def rel(p):
            return os.path.relpath(p, root).replace(os.sep, "/")

        data_prefix = self.data_dir + "/"
        for info in self.zf.infolist():
            n = info.filename
            if n.endswith("/"):
                continue
            if n == self.dist_info + "/RECORD":
                continue
            data = self.zf.read(n)
            is_script = False
            if n.startswith(data_prefix):
                rest = n[len(data_prefix):]
                key, _, sub = rest.partition("/")
                if key not in ("purelib", "platlib", "scripts", "data", "headers"):
                    raise WheelError("%s: unknown .data directory %s" % (self.filename, key))
                if key == "headers":
                    base = scheme.get("headers") or os.path.join(scheme["data"], "include", self.project)
                else:
                    base = scheme[key]
                dest = _safe_join(base, sub)
                is_script = key == "scripts"
            else:
                dest = _safe_join(root, n)
            if is_script and (data.startswith(b"#!python") or data.startswith(b"#!pythonw")):
                nl = data.find(b"\n")
                data = shebang(exe).encode("utf-8") + (data[nl + 1:] if nl >= 0 else b"")
            d = os.path.dirname(dest)
            if d:
                os.makedirs(d, exist_ok=True)
            if os.path.lexists(dest) and not os.path.isdir(dest):
                os.remove(dest)
            with open(dest, "wb") as f:
                f.write(data)
            mode = (info.external_attr >> 16) & 0o777
            if is_script or (mode & 0o111):
                os.chmod(dest, 0o755)
            written.append(dest)
            rows.append((rel(dest), _md.record_hash(data), str(len(data))))
        # console and GUI scripts
        eps = self.entry_points()
        for group in ("console_scripts", "gui_scripts"):
            for name, value in eps.get(group, []):
                for p in make_script(name, value, scheme["scripts"], exe):
                    with open(p, "rb") as f:
                        b = f.read()
                    written.append(p)
                    rows.append((rel(p), _md.record_hash(b), str(len(b))))
        di = os.path.join(root, self.dist_info)

        def put(name, text):
            p = os.path.join(di, name)
            b = text.encode("utf-8")
            with open(p, "wb") as f:
                f.write(b)
            written.append(p)
            rows.append((rel(p), _md.record_hash(b), str(len(b))))

        put("INSTALLER", installer + "\n")
        if requested:
            put("REQUESTED", "")
        if direct_url is not None:
            put("direct_url.json", json.dumps(direct_url, sort_keys=True))
        rp = os.path.join(di, "RECORD")
        rows.append((rel(rp), "", ""))
        with open(rp, "w", encoding="utf-8", newline="") as f:
            f.write(_md.format_record(rows))
        written.append(rp)
        return written


def write_wheel(out_dir, name, version, files, tag="py3-none-any", requires=(), requires_python=None,
                entry_points=None, data_files=None, summary=None, extras=(), extra_metadata=(),
                description="", build=None, root_is_purelib=True, wheel_version="1.0", bad_hash=None,
                metadata_text=None):
    """Write <name>-<version>-<tag>.whl into out_dir from {archive path:
    bytes}; data_files {"scripts/x": bytes, "data/share/f": bytes, ...} go
    under the .data directory. Returns the wheel's path. (`bad_hash`, a
    path, records a wrong hash for it: a test's corrupt wheel.)"""
    import io
    dist = escape_name(name) + "-" + escape_version(version)
    fname = dist + ("-" + str(build) if build else "") + "-" + tag + ".whl"
    entries = []
    for p in sorted(files):
        b = files[p]
        if isinstance(b, str):
            b = b.encode("utf-8")
        entries.append((p, b))
    for p in sorted(data_files or {}):
        b = data_files[p]
        if isinstance(b, str):
            b = b.encode("utf-8")
        entries.append((dist + ".data/" + p, b))
    di = dist + ".dist-info/"
    meta = metadata_text or _md.make_metadata(name, str(version), requires, requires_python, summary, extras,
                                              extra_metadata, description)
    entries.append((di + "METADATA", meta.encode("utf-8")))
    wheel = "Wheel-Version: %s\nGenerator: nypip (0.2.1)\nRoot-Is-Purelib: %s\n" % (wheel_version, "true" if root_is_purelib else "false")
    for t in tag.split("-")[0].split("."):
        for a in tag.split("-")[1].split("."):
            for pl in tag.split("-")[2].split("."):
                wheel += "Tag: %s-%s-%s\n" % (t, a, pl)
    entries.append((di + "WHEEL", wheel.encode("utf-8")))
    if entry_points:
        entries.append((di + "entry_points.txt", _md.format_entry_points(entry_points).encode("utf-8")))
    rows = []
    for p, b in entries:
        h = _md.record_hash(b)
        if p == bad_hash:
            h = _md.record_hash(b + b"x")
        rows.append((p, h, str(len(b))))
    rows.append((di + "RECORD", "", ""))
    entries.append((di + "RECORD", _md.format_record(rows).encode("utf-8")))
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, fname)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for p, b in entries:
            zi = zipfile.ZipInfo(p, (1980, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (0o755 if p.startswith(dist + ".data/scripts/") else 0o644) << 16
            zf.writestr(zi, b)
    return path
