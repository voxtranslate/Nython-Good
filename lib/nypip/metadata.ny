# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/metadata.ny - core metadata (METADATA, PKG-INFO) and the small
# text formats of a distribution (round 87).
#
#     m = Metadata.parse(text)
#     m.name, m.version, m.requires_dist, m.requires_python, m.provides_extra
#     m.get("Summary"), m.get_all("Classifier"), m.body (the description)
#     parse_entry_points(text) -> {group: [(name, value)]}    entry_points.txt
#     parse_record(text) -> [(path, hash, size)]               RECORD (CSV)
#     record_hash(data) -> "sha256=<urlsafe base64, unpadded>"
#
# The header format is RFC 822's as the core metadata specification uses it
# (continuation lines start with white space; the Description may be the
# body after an empty line). Written in the subset CPython runs too.

import base64
import hashlib


class Metadata:
    def __init__(self, headers, body=""):
        self.headers = headers          # [(name, value)] in file order
        self.body = body

    @classmethod
    def parse(cls, text):
        if isinstance(text, bytes):
            text = text.decode("utf-8", "replace")
        headers = []
        lines = text.replace("\r\n", "\n").split("\n")
        i = 0
        n = len(lines)
        while i < n:
            line = lines[i]
            if line == "":
                i += 1
                break
            if line[0] in " \t" and headers:
                k, v = headers[-1]
                headers[-1] = (k, v + "\n" + line)
            else:
                c = line.find(":")
                if c > 0:
                    headers.append((line[:c].strip(), line[c + 1:].strip()))
            i += 1
        body = "\n".join(lines[i:])
        return cls(headers, body)

    def get(self, name, default=None):
        k = name.lower()
        for h, v in self.headers:
            if h.lower() == k:
                return v
        return default

    def get_all(self, name):
        k = name.lower()
        return [v for h, v in self.headers if h.lower() == k]

    @property
    def name(self):
        return self.get("Name", "")

    @property
    def version(self):
        return self.get("Version", "")

    @property
    def requires_dist(self):
        return self.get_all("Requires-Dist")

    @property
    def requires_python(self):
        return self.get("Requires-Python")

    @property
    def provides_extra(self):
        return self.get_all("Provides-Extra")

    @property
    def summary(self):
        return self.get("Summary", "")

    def as_text(self):
        out = []
        for k, v in self.headers:
            out.append(k + ": " + v)
        text = "\n".join(out) + "\n"
        if self.body:
            text += "\n" + self.body
        return text


def make_metadata(name, version, requires=(), requires_python=None, summary=None, extras=(), extra_headers=(), description=""):
    """METADATA text (Metadata-Version 2.1) for the given fields."""
    h = [("Metadata-Version", "2.1"), ("Name", name), ("Version", version)]
    if summary:
        h.append(("Summary", summary))
    if requires_python:
        h.append(("Requires-Python", requires_python))
    for e in extras:
        h.append(("Provides-Extra", e))
    for r in requires:
        h.append(("Requires-Dist", r))
    for k, v in extra_headers:
        h.append((k, v))
    return Metadata(h, description).as_text()


def parse_entry_points(text):
    """entry_points.txt: {group: [(name, value)]} (an ini file whose values
    are object references, `module:attr [extras]`)."""
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    groups = {}
    cur = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1].strip()
            groups.setdefault(cur, [])
            continue
        if cur is None:
            continue
        eq = line.find("=")
        if eq < 0:
            continue
        groups[cur].append((line[:eq].strip(), line[eq + 1:].strip()))
    return groups


def format_entry_points(groups):
    out = []
    for g in groups:
        out.append("[" + g + "]")
        for name, value in groups[g]:
            out.append(name + " = " + value)
        out.append("")
    return "\n".join(out)


def parse_record(text):
    """RECORD: [(path, hash, size)] - a CSV file (paths may be quoted)."""
    import csv
    import io
    if isinstance(text, bytes):
        text = text.decode("utf-8")
    rows = []
    for row in csv.reader(io.StringIO(text)):
        if not row:
            continue
        while len(row) < 3:
            row.append("")
        rows.append((row[0], row[1], row[2]))
    return rows


def format_record(rows):
    import csv
    import io
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    for r in rows:
        w.writerow([r[0], r[1], r[2]])
    return buf.getvalue()


def record_hash(data, algo="sha256"):
    d = hashlib.new(algo, data).digest()
    return algo + "=" + base64.urlsafe_b64encode(d).rstrip(b"=").decode("ascii")


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 16)
            if not b:
                break
            h.update(b)
    return h.hexdigest()
