# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/req.ny - requirement files (pip's format) and requirement
# arguments (round 87).
#
#     rf = ReqFile(); rf.parse("requirements.txt")
#     rf.requirements -> [Item]    (a PEP 508 requirement, or a local
#                                   path / URL of a distribution, with its
#                                   --hash options)
#     rf.constraints, rf.index_urls, rf.extra_index_urls, rf.find_links,
#     rf.no_index, rf.pre
#
# The lines: requirements ("name[extras] specifiers ; marker", "name @ url"),
# paths to wheels, sdists or source directories, -r / --requirement FILE and
# -c / --constraint FILE (relative to the file naming them), -i /
# --index-url, --extra-index-url, --no-index, -f / --find-links, --pre,
# per-requirement --hash=algo:hex; comments (# at a line's start or after
# white space), backslash continuations, ${VAR} from the environment.
# Editable installs (-e) are refused. Written in the subset CPython runs too.

import os
import re

from nypip._packaging.requirements import Requirement, InvalidRequirement


class ReqError(Exception):
    pass


class Item:
    """One requirement: `req` (a Requirement) or `path` (a local file or
    directory, or a URL), and the hashes it must match ({algo: [hex]})."""

    def __init__(self, req=None, path=None, hashes=None, source=""):
        self.req = req
        self.path = path
        self.hashes = hashes or {}
        self.source = source

    def __repr__(self):
        return "<Item %s>" % (self.req if self.req is not None else self.path)


_ENV_RE = re.compile(r"\$\{([A-Z0-9_]+)\}")


def _looks_like_path(s):
    if s.startswith(("file:", "http:", "https:")):
        return True
    if os.sep in s or (os.altsep and os.altsep in s) or s.startswith("."):
        return True
    return s.endswith((".whl", ".tar.gz", ".zip"))


def parse_item(text, base_dir=".", hashes=None, source=""):
    text = text.strip()
    if " @ " not in text and _looks_like_path(text) and not re.match(r"^[A-Za-z0-9._-]+\s*[\[<>=!~;]", text):
        p = text
        if not p.startswith(("file:", "http:", "https:")):
            p = os.path.normpath(os.path.join(base_dir, p))
        return Item(path=p, hashes=hashes, source=source)
    try:
        return Item(req=Requirement(text), hashes=hashes, source=source)
    except InvalidRequirement as e:
        raise ReqError("invalid requirement %r%s: %s" % (text, " (" + source + ")" if source else "", e)) from None


class ReqFile:
    def __init__(self):
        self.requirements = []
        self.constraints = []
        self.index_urls = []
        self.extra_index_urls = []
        self.find_links = []
        self.no_index = False
        self.pre = False
        self._seen = set()

    def parse(self, path, constraint=False):
        apath = os.path.abspath(path)
        if apath in self._seen:
            return self
        self._seen.add(apath)
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except OSError as e:
            raise ReqError("could not open requirements file: %s" % e) from None
        base = os.path.dirname(apath)
        lines = []
        cur = ""
        start = 0
        for n, raw in enumerate(text.splitlines(), 1):
            if not cur:
                start = n
            if raw.endswith("\\") and not raw.endswith("\\\\"):
                cur += raw[:-1]
                continue
            cur += raw
            lines.append((start, cur))
            cur = ""
        if cur:
            lines.append((start, cur))
        for n, line in lines:
            line = re.sub(r"(^|\s+)#.*$", "", line).strip()
            if not line:
                continue
            line = _ENV_RE.sub(lambda m: os.environ.get(m.group(1), m.group(0)), line)
            where = "%s:%d" % (os.path.basename(path), n)
            self._line(line, base, where, constraint)
        return self

    def _opt(self, parts, i, name):
        p = parts[i]
        if "=" in p and p.startswith("--"):
            return p.split("=", 1)[1], i + 1
        if p.startswith("-") and not p.startswith("--") and len(p) > 2:
            return p[2:], i + 1
        if i + 1 >= len(parts):
            raise ReqError("%s needs an argument" % name)
        return parts[i + 1], i + 2

    def _line(self, line, base, where, constraint):
        import shlex
        if line.startswith("-"):
            if os.name == "nt":
                # (a backslash is a path separator there, not an escape)
                parts = [p[1:-1] if len(p) > 1 and p[0] == p[-1] and p[0] in "\"'" else p
                         for p in shlex.split(line, posix=False)]
            else:
                parts = shlex.split(line, posix=True)
            i = 0
            while i < len(parts):
                p = parts[i]
                key = p.split("=", 1)[0] if p.startswith("--") else p[:2]
                if key in ("-r", "--requirement", "-c", "--constraint"):
                    v, i = self._opt(parts, i, key)
                    self.parse(os.path.join(base, v), constraint or key in ("-c", "--constraint"))
                elif key in ("-i", "--index-url"):
                    v, i = self._opt(parts, i, key)
                    self.index_urls = [v]
                elif key == "--extra-index-url":
                    v, i = self._opt(parts, i, key)
                    self.extra_index_urls.append(v)
                elif key in ("-f", "--find-links"):
                    v, i = self._opt(parts, i, key)
                    if "://" not in v and not os.path.isabs(v):
                        v = os.path.normpath(os.path.join(base, v))
                    self.find_links.append(v)
                elif key == "--no-index":
                    self.no_index = True
                    i += 1
                elif key == "--pre":
                    self.pre = True
                    i += 1
                elif key in ("-e", "--editable"):
                    raise ReqError("%s: editable installs (-e) are not supported" % where)
                else:
                    raise ReqError("%s: unknown option %s" % (where, p))
            return
        hashes = {}
        m = re.search(r"\s--hash[=\s]", " " + line)
        if m:
            idx = m.start()
            opts = line[idx:]
            line = line[:idx].strip()
            for h in re.findall(r"--hash[=\s]+([A-Za-z0-9]+):([0-9a-fA-F]+)", opts):
                hashes.setdefault(h[0].lower(), []).append(h[1].lower())
        item = parse_item(line, base, hashes, where)
        if constraint:
            if item.req is None:
                raise ReqError("%s: a constraint must be a requirement, not %s" % (where, item.path))
            self.constraints.append(item.req)
        else:
            self.requirements.append(item)
