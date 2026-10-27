# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/index.ny - where distributions are found (round 87): --find-links
# directories and pages, and package indexes speaking the simple repository
# API - PEP 503's HTML and PEP 691's JSON (asked for by content negotiation),
# with PEP 592's yanked files, PEP 658/714's separate core metadata, and the
# files' hashes.
#
#     f = Finder(index_urls=["https://pypi.org/simple/"], find_links=["./wheels"])
#     f.links("requests")          -> [Link] every file of the project
#     f.fetch(url) -> bytes        http(s) (urllib: HTTPS_PROXY / no_proxy, the
#                                  system CA bundle or --cert, never unverified),
#                                  file: URLs and local paths
#     f.download(link, dest_dir)   the file, its hash checked
#
# Written in the subset CPython runs too.

import os
import json
import hashlib
import posixpath

from nypip._packaging.utils import (canonicalize_name, parse_wheel_filename, parse_sdist_filename,
                                    InvalidWheelFilename, InvalidSdistFilename)
from nypip._packaging.version import InvalidVersion

USER_AGENT = "nypip/0.2.1"
ACCEPT = ("application/vnd.pypi.simple.v1+json, application/vnd.pypi.simple.v1+html;q=0.2, "
          "text/html;q=0.01")


class IndexError_(Exception):
    pass


class HashMismatch(Exception):
    pass


class Link:
    def __init__(self, url, filename=None, hashes=None, requires_python=None, yanked=None,
                 metadata=None, source=""):
        self.url = url
        if filename is None:
            filename = posixpath.basename(url.split("#")[0].split("?")[0])
        from urllib.parse import unquote
        self.filename = unquote(filename)
        self.hashes = dict(hashes or {})
        frag = url.split("#", 1)[1] if "#" in url else ""
        for part in frag.split("&"):
            if "=" in part:
                k, v = part.split("=", 1)
                if k in hashlib.algorithms_guaranteed:
                    self.hashes.setdefault(k, v)
        self.url_nofrag = url.split("#")[0]
        self.requires_python = requires_python or None
        self.yanked = yanked                      # None, or the reason ("" for none given)
        self.metadata = metadata                  # None, True, or {algo: hex}: PEP 658
        self.source = source
        self.project = None
        self.version = None
        self.tags = None
        self.kind = None
        fn = self.filename
        try:
            if fn.endswith(".whl"):
                n, v, b, t = parse_wheel_filename(fn)
                self.project, self.version, self.tags, self.kind = n, v, t, "wheel"
            elif fn.endswith(".tar.gz") or fn.endswith(".zip"):
                n, v = parse_sdist_filename(fn)
                self.project, self.version, self.kind = n, v, "sdist"
        except (InvalidWheelFilename, InvalidSdistFilename, InvalidVersion):
            self.kind = None

    @property
    def is_local(self):
        return self.url.startswith("file:") or "://" not in self.url

    def local_path(self):
        if "://" not in self.url:
            return self.url
        from urllib.request import url2pathname
        from urllib.parse import urlparse
        p = urlparse(self.url_nofrag)
        return url2pathname(p.path)

    def __repr__(self):
        return "<Link %s>" % self.filename


def path_to_url(path):
    from urllib.request import pathname2url
    p = os.path.abspath(path)
    u = pathname2url(p)
    if not u.startswith("/"):
        u = "/" + u
    return "file://" + u if not u.startswith("///") else "file:" + u


class _AnchorParser:
    # PEP 503's page: <a href=... data-requires-python=... data-yanked=...
    # data-core-metadata=...>filename</a>, and <base href>
    def __init__(self):
        from html.parser import HTMLParser
        outer = self

        class P(HTMLParser):
            def handle_starttag(self, tag, attrs):
                outer.start(tag, attrs)

            def handle_endtag(self, tag):
                outer.end(tag)

            def handle_data(self, data):
                outer.data(data)

        self.parser = P(convert_charrefs=True)
        self.anchors = []
        self.base = None
        self.cur = None

    def start(self, tag, attrs):
        d = {}
        for k, v in attrs:
            d[k] = v
        if tag == "base" and d.get("href") and self.base is None:
            self.base = d["href"]
        if tag == "a" and d.get("href"):
            self.cur = [d, ""]

    def end(self, tag):
        if tag == "a" and self.cur is not None:
            self.anchors.append(self.cur)
            self.cur = None

    def data(self, text):
        if self.cur is not None:
            self.cur[1] += text

    def feed(self, text):
        self.parser.feed(text)
        self.parser.close()
        return self.anchors


def parse_html(text, page_url, source=""):
    from urllib.parse import urljoin
    p = _AnchorParser()
    anchors = p.feed(text)
    base = urljoin(page_url, p.base) if p.base else page_url
    out = []
    for attrs, label in anchors:
        url = urljoin(base, attrs["href"])
        meta = attrs.get("data-core-metadata", attrs.get("data-dist-info-metadata"))
        mh = None
        if meta is not None:
            mh = True
            if "=" in meta:
                a, h = meta.split("=", 1)
                mh = {a: h}
        y = attrs.get("data-yanked")
        if "data-yanked" in attrs and y is None:
            y = ""
        fn = label.strip() or None
        if fn is not None and "/" in fn:
            fn = None
        out.append(Link(url, fn, None, attrs.get("data-requires-python"), y, mh, source))
    return out


def parse_json(data, page_url, source=""):
    from urllib.parse import urljoin
    doc = json.loads(data)
    out = []
    for f in doc.get("files", []):
        url = urljoin(page_url, f["url"])
        y = f.get("yanked", False)
        if y is True:
            y = ""
        elif y is False:
            y = None
        meta = f.get("core-metadata", f.get("dist-info-metadata"))
        if meta is False:
            meta = None
        elif meta is True:
            meta = True
        out.append(Link(url, f.get("filename"), f.get("hashes"), f.get("requires-python"), y, meta, source))
    return out


class Finder:
    def __init__(self, index_urls=None, find_links=None, no_index=False, cert=None, timeout=60, log=None):
        if index_urls is None:
            index_urls = [os.environ.get("PIP_INDEX_URL") or "https://pypi.org/simple/"]
        self.index_urls = [] if no_index else [u if u.endswith("/") else u + "/" for u in index_urls]
        self.find_links = list(find_links or [])
        self.cert = cert or os.environ.get("PIP_CERT") or None
        self.timeout = timeout
        self.log = log
        self._links = {}
        self._fl = None
        self.direct = {}             # canonical name -> [Link] (name @ url, local files)
        self._ctx = None

    # ── fetching ──────────────────────────────────────────────────────────
    def _ssl_context(self):
        if self._ctx is None:
            import ssl
            # verified always: the system's CA bundle (SSL_CERT_FILE /
            # SSL_CERT_DIR), or --cert / PIP_CERT
            self._ctx = ssl.create_default_context(cafile=self.cert)
        return self._ctx

    def fetch(self, url, accept=None):
        """(bytes, content type, final url)"""
        if "://" not in url:
            with open(url, "rb") as f:
                return f.read(), "", url
        if url.startswith("file:"):
            p = Link(url).local_path()
            if os.path.isdir(p):
                return None, "directory", url
            with open(p, "rb") as f:
                return f.read(), "", url
        import urllib.request
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept or "*/*"})
        kw = {"timeout": self.timeout}
        if url.startswith("https:"):
            kw["context"] = self._ssl_context()
        if self.log:
            self.log("GET " + url)
        with urllib.request.urlopen(req, **kw) as r:
            data = r.read()
            ctype = r.headers.get("Content-Type", "") or ""
            return data, ctype, r.geturl() if hasattr(r, "geturl") else url

    def _find_links_links(self):
        if self._fl is None:
            self._fl = []
            for loc in self.find_links:
                if "://" not in loc and os.path.isdir(loc):
                    for fn in sorted(os.listdir(loc)):
                        p = os.path.join(os.path.abspath(loc), fn)
                        if os.path.isfile(p):
                            self._fl.append(Link(path_to_url(p), fn, source="find-links"))
                    continue
                if loc.startswith("file:"):
                    lp = Link(loc).local_path()
                    if os.path.isdir(lp):
                        for fn in sorted(os.listdir(lp)):
                            p = os.path.join(lp, fn)
                            if os.path.isfile(p):
                                self._fl.append(Link(path_to_url(p), fn, source="find-links"))
                        continue
                try:
                    data, ctype, final = self.fetch(loc, "text/html")
                except OSError as e:
                    if self.log:
                        self.log("could not read --find-links %s: %s" % (loc, e))
                    continue
                if data is not None:
                    self._fl.extend(parse_html(data.decode("utf-8", "replace"), final, "find-links"))
        return self._fl

    def _index_links(self, name, index):
        url = index + name + "/"
        try:
            data, ctype, final = self.fetch(url, ACCEPT)
        except OSError as e:
            code = getattr(e, "code", None)
            if code == 404:
                return None
            if self.log:
                self.log("could not read %s: %s" % (url, e))
            raise IndexError_("could not read %s: %s" % (url, e))
        if data is None:
            return []
        ct = ctype.split(";")[0].strip().lower()
        if ct == "application/vnd.pypi.simple.v1+json":
            return parse_json(data.decode("utf-8"), final, index)
        return parse_html(data.decode("utf-8", "replace"), final, index)

    def links(self, name):
        """Every file of project `name` (canonicalized) the sources list."""
        c = canonicalize_name(name)
        got = self._links.get(c)
        if got is not None:
            return got
        out = list(self.direct.get(c, []))
        if not out:
            for l in self._find_links_links():
                if l.project == c:
                    out.append(l)
            found_any = bool(out)
            for idx in self.index_urls:
                ls = self._index_links(c, idx)
                if ls is None:
                    continue
                found_any = True
                for l in ls:
                    if l.project == c:
                        out.append(l)
            if not found_any and not out:
                out = None
        self._links[c] = out
        return out

    def add_direct(self, link):
        if link.project:
            self.direct.setdefault(link.project, []).append(link)
            self._links.pop(link.project, None)

    def download(self, link, dest_dir, extra_hashes=None):
        """The file in dest_dir (a local file is used where it is); its hash
        checked against the link's and `extra_hashes` ({algo: [hex]})."""
        if link.is_local:
            path = link.local_path()
            with open(path, "rb") as f:
                data = f.read()
        else:
            data, ctype, final = self.fetch(link.url_nofrag)
            os.makedirs(dest_dir, exist_ok=True)
            path = os.path.join(dest_dir, link.filename)
            with open(path, "wb") as f:
                f.write(data)
        check_hashes(link, data, extra_hashes)
        return path

    def fetch_metadata(self, link):
        """PEP 658: the wheel's METADATA from <url>.metadata, its hash
        checked; None when the index offers none."""
        if not link.metadata or link.is_local:
            return None
        data, ctype, final = self.fetch(link.url_nofrag + ".metadata")
        if isinstance(link.metadata, dict):
            for algo, want in link.metadata.items():
                if algo in hashlib.algorithms_guaranteed and hashlib.new(algo, data).hexdigest() != want:
                    raise HashMismatch("the metadata of %s does not match its hash" % link.filename)
        return data


def check_hashes(link, data, extra=None):
    for algo, want in link.hashes.items():
        if algo in hashlib.algorithms_guaranteed:
            got = hashlib.new(algo, data).hexdigest()
            if got != want:
                raise HashMismatch("%s: %s %s, expected %s" % (link.filename, algo, got, want))
    if extra:
        ok = False
        for algo, wants in extra.items():
            if algo in hashlib.algorithms_guaranteed and hashlib.new(algo, data).hexdigest() in wants:
                ok = True
        if not ok:
            raise HashMismatch("%s does not match any of the required hashes (got sha256 %s)"
                               % (link.filename, hashlib.sha256(data).hexdigest()))
