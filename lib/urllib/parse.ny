# nython: module    (import it by name: it runs in a module scope of its own)
# lib/urllib/parse.ny - Python's urllib.parse (RFC 3986, round 77):
# urlparse/urlsplit/urlunparse/urlunsplit/urljoin/urldefrag, quote/unquote
# (UTF-8), quote_plus/unquote_plus, urlencode, parse_qs/parse_qsl.

uses_netloc = ["", "ftp", "http", "gopher", "nntp", "telnet", "imap", "wais", "file", "mms", "https",
               "shttp", "snews", "prospero", "rtsp", "rtspu", "rsync", "svn", "svn+ssh", "sftp", "nfs",
               "git", "git+ssh", "ws", "wss"]
_ALWAYS_SAFE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~"
_HEX = "0123456789ABCDEF"

class _Result:
    # A tuple of the URL's parts with names (urlparse's ParseResult,
    # urlsplit's SplitResult).
    def __init__(self, names, values):
        self._names = names
        self._values = values
        for i in range(len(names)):
            setattr(self, names[i], values[i])

    def __getitem__(self, i):
        return self._values[i]

    def __len__(self):
        return len(self._values)

    def __iter__(self):
        return iter(self._values)

    def __eq__(self, other):
        return list(self._values) == list(other)

    def __hash__(self):
        # hashable as the tuple it stands for (a class defining __eq__ alone
        # is unhashable - round 77)
        return hash(tuple(self._values))

    def _hostinfo(self):
        var netloc = self.netloc
        var at = netloc.rfind("@")
        if at >= 0:
            netloc = netloc[at + 1:]
        if netloc.startswith("["):
            var close = netloc.find("]")
            var host = netloc[1:close]
            var rest = netloc[close + 1:]
            if rest.startswith(":"):
                return [host, rest[1:]]
            return [host, none]
        var colon = netloc.rfind(":")
        if colon >= 0:
            return [netloc[0:colon], netloc[colon + 1:]]
        return [netloc, none]

    @property
    def hostname(self):
        var h = self._hostinfo()[0]
        if h == "":
            return none
        return h.lower()

    @property
    def port(self):
        var p = self._hostinfo()[1]
        if p == none or p == "":
            return none
        if not p.isdigit():
            raise ValueError("Port could not be cast to integer value as " + repr(p))
        var n = int(p)
        if n > 65535:
            raise ValueError("Port out of range 0-65535")
        return n

    @property
    def username(self):
        var at = self.netloc.rfind("@")
        if at < 0:
            return none
        var info = self.netloc[0:at]
        var c = info.find(":")
        if c >= 0:
            return info[0:c]
        return info

    @property
    def password(self):
        var at = self.netloc.rfind("@")
        if at < 0:
            return none
        var info = self.netloc[0:at]
        var c = info.find(":")
        if c >= 0:
            return info[c + 1:]
        return none

    def geturl(self):
        if len(self._names) == 6:
            return urlunparse(self._values)
        return urlunsplit(self._values)

    def _replace(self, **kw):
        var vals = list(self._values)
        for i in range(len(self._names)):
            if self._names[i] in kw:
                vals[i] = kw[self._names[i]]
        return _Result(self._names, tuple(vals))

    def __repr__(self):
        var kind = "SplitResult"
        if len(self._names) == 6:
            kind = "ParseResult"
        elif len(self._names) == 2:
            kind = "DefragResult"
        var parts = []
        for i in range(len(self._names)):
            parts.append(self._names[i] + "=" + repr(self._values[i]))
        return kind + "(" + ", ".join(parts) + ")"

def _scheme_ok(s):
    if len(s) == 0 or not s[0].isalpha():
        return false
    for c in s:
        if not (c.isalnum() or c in "+-."):
            return false
    return true

def urlsplit(url, scheme="", allow_fragments=true):
    var rest = url.strip()
    var sch = scheme
    var c = rest.find(":")
    if c > 0 and _scheme_ok(rest[0:c]):
        sch = rest[0:c].lower()
        rest = rest[c + 1:]
    var netloc = ""
    if rest.startswith("//"):
        var end = len(rest)
        for d in "/?#":
            var k = rest.find(d, 2)
            if k >= 0 and k < end:
                end = k
        netloc = rest[2:end]
        rest = rest[end:]
    var fragment = ""
    if allow_fragments:
        var h = rest.find("#")
        if h >= 0:
            fragment = rest[h + 1:]
            rest = rest[0:h]
    var query = ""
    var q = rest.find("?")
    if q >= 0:
        query = rest[q + 1:]
        rest = rest[0:q]
    return _Result(["scheme", "netloc", "path", "query", "fragment"], (sch, netloc, rest, query, fragment))

def urlparse(url, scheme="", allow_fragments=true):
    var s = urlsplit(url, scheme, allow_fragments)
    var path = s.path
    var params = ""
    var semi = path.rfind(";")
    var slash = path.rfind("/")
    if semi >= 0 and semi > slash:
        params = path[semi + 1:]
        path = path[0:semi]
    return _Result(["scheme", "netloc", "path", "params", "query", "fragment"], (s.scheme, s.netloc, path, params, s.query, s.fragment))

def urlunsplit(parts):
    var scheme = parts[0]
    var netloc = parts[1]
    var url = parts[2]
    var query = parts[3]
    var fragment = parts[4]
    if netloc or (scheme in uses_netloc and url.startswith("//")):
        if url and not url.startswith("/"):
            url = "/" + url
        url = "//" + netloc + url
    elif scheme in uses_netloc and scheme != "" and netloc == "" and url.startswith("/") and scheme == "file":
        url = "//" + url
    if scheme:
        url = scheme + ":" + url
    if query:
        url = url + "?" + query
    if fragment:
        url = url + "#" + fragment
    return url

def urlunparse(parts):
    var path = parts[2]
    if parts[3]:
        path = path + ";" + parts[3]
    return urlunsplit((parts[0], parts[1], path, parts[4], parts[5]))

def _remove_dots(path):
    # RFC 3986 5.2.4
    var out = []
    var segs = path.split("/")
    for i in range(len(segs)):
        var s = segs[i]
        if s == ".":
            if i == len(segs) - 1:
                out.append("")
            continue
        if s == "..":
            if len(out) > 1:
                out.pop()
            if i == len(segs) - 1:
                out.append("")
            continue
        out.append(s)
    var r = "/".join(out)
    if path.startswith("/") and not r.startswith("/"):
        r = "/" + r
    return r

def urljoin(base, url, allow_fragments=true):
    if base == "":
        return url
    if url == "":
        return base
    var b = urlsplit(base, "", allow_fragments)
    var r = urlsplit(url, b.scheme, allow_fragments)
    if r.scheme != b.scheme or not (r.scheme in uses_netloc):
        return url
    if r.netloc:
        return urlunsplit((r.scheme, r.netloc, _remove_dots(r.path), r.query, r.fragment))
    if r.path == "":
        var q = r.query
        if q == "":
            q = b.query
        return urlunsplit((b.scheme, b.netloc, b.path, q, r.fragment))
    var path = r.path
    if not path.startswith("/"):
        var cut = b.path.rfind("/")
        var dirpath = ""
        if cut >= 0:
            dirpath = b.path[0:cut + 1]
        elif b.netloc:
            dirpath = "/"
        path = dirpath + path
    return urlunsplit((b.scheme, b.netloc, _remove_dots(path), r.query, r.fragment))

def urldefrag(url):
    var h = url.find("#")
    if h < 0:
        return _Result(["url", "fragment"], (url, ""))
    return _Result(["url", "fragment"], (url[0:h], url[h + 1:]))

def quote(string, safe="/", encoding="utf-8", errors="strict"):
    var data = string
    if isinstance(string, "str"):
        data = string.encode(encoding, errors)
    var out = []
    for b in data:
        var ch = chr(b)
        if b < 128 and (ch in _ALWAYS_SAFE or ch in safe):
            out.append(ch)
        else:
            out.append("%" + _HEX[b >> 4] + _HEX[b & 15])
    return "".join(out)

def quote_plus(string, safe="", encoding="utf-8", errors="strict"):
    if isinstance(string, "str") and not (" " in string):
        return quote(string, safe, encoding, errors)
    return quote(string, safe + " ", encoding, errors).replace(" ", "+")

def quote_from_bytes(bs, safe="/"):
    return quote(bs, safe)

def unquote_to_bytes(string):
    var data = string
    if isinstance(string, "str"):
        data = string.encode("utf-8")
    var out = bytearray()
    var i = 0
    var n = len(data)
    while i < n:
        var b = data[i]
        if b == 37 and i + 2 < n + 0 and i + 2 <= n - 1:
            var h = chr(data[i + 1]) + chr(data[i + 2])
            var ok = true
            for c in h:
                if not (c in "0123456789abcdefABCDEF"):
                    ok = false
            if ok:
                out.append(int(h, 16))
                i = i + 3
                continue
        out.append(b)
        i = i + 1
    return bytes(out)

def unquote(string, encoding="utf-8", errors="replace"):
    if not ("%" in string):
        return string
    return unquote_to_bytes(string).decode(encoding, errors)

def unquote_plus(string, encoding="utf-8", errors="replace"):
    return unquote(string.replace("+", " "), encoding, errors)

def urlencode(query, doseq=false, safe="", encoding="utf-8", errors="strict", quote_via=none):
    if quote_via == none:
        quote_via = quote_plus
    var pairs = query
    if isinstance(query, "dict"):
        pairs = query.items()
    var out = []
    for kv in pairs:
        var k = kv[0]
        var v = kv[1]
        if not isinstance(k, "str") and not isinstance(k, "bytes"):
            k = str(k)
        var ks = quote_via(k, safe)
        if doseq and (isinstance(v, "list") or isinstance(v, "tuple")):
            for x in v:
                if not isinstance(x, "str") and not isinstance(x, "bytes"):
                    x = str(x)
                out.append(ks + "=" + quote_via(x, safe))
        else:
            if not isinstance(v, "str") and not isinstance(v, "bytes"):
                v = str(v)
            out.append(ks + "=" + quote_via(v, safe))
    return "&".join(out)

def parse_qsl(qs, keep_blank_values=false, strict_parsing=false, encoding="utf-8", errors="replace", max_num_fields=none, separator="&"):
    var out = []
    if qs == "" or qs == none:
        return out
    for part in qs.split(separator):
        if part == "":
            continue
        var eq = part.find("=")
        var k = part
        var v = ""
        if eq >= 0:
            k = part[0:eq]
            v = part[eq + 1:]
        elif strict_parsing:
            raise ValueError("bad query field: " + repr(part))
        if len(v) > 0 or keep_blank_values:
            out.append((unquote_plus(k, encoding, errors), unquote_plus(v, encoding, errors)))
    return out

def parse_qs(qs, keep_blank_values=false, strict_parsing=false, encoding="utf-8", errors="replace", max_num_fields=none, separator="&"):
    var d = {}
    for kv in parse_qsl(qs, keep_blank_values, strict_parsing, encoding, errors, max_num_fields, separator):
        if kv[0] in d:
            d[kv[0]].append(kv[1])
        else:
            d[kv[0]] = [kv[1]]
    return d
