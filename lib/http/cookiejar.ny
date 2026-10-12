# nython: module    (import it by name: it runs in a module scope of its own)
# lib/http/cookiejar.ny - cookies for HTTP clients (round 77), RFC 6265's
# rules: CookieJar, Cookie, DefaultCookiePolicy (the RFC 6265 subset Python's
# applies by default).
#
#     import http.cookiejar, urllib.request
#     jar = http.cookiejar.CookieJar()
#     opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
#
# Set-Cookie: name=value with Domain (host-only when absent; a domain must
# domain-match the request host), Path (default: the request path's
# directory), Expires/Max-Age (Max-Age wins; a past time deletes), Secure
# (sent over https only), HttpOnly (kept, does not matter to a client).
# Cookie headers list the more specific path first (RFC 6265 5.4).

class LoadError(OSError):
    pass

_MONTHS = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}

def _http_date(text):
    # RFC 6265 5.1.1's lenient date parser -> seconds since the epoch or none
    var tokens = []
    var cur = ""
    for ch in text:
        if ch.isalnum() or ch == ":":
            cur = cur + ch
        else:
            if cur != "":
                tokens.append(cur)
            cur = ""
    if cur != "":
        tokens.append(cur)
    var hms = none
    var day = none
    var month = none
    var year = none
    for tok in tokens:
        if hms == none and tok.count(":") == 2:
            var p = tok.split(":")
            if p[0].isdigit() and p[1].isdigit() and p[2].isdigit():
                hms = [int(p[0]), int(p[1]), int(p[2])]
                continue
        if day == none and tok.isdigit() and len(tok) <= 2:
            day = int(tok)
            continue
        if month == none and tok[0:3].lower() in _MONTHS:
            month = _MONTHS[tok[0:3].lower()]
            continue
        if year == none and tok.isdigit() and len(tok) >= 2 and len(tok) <= 4:
            year = int(tok)
            continue
    if hms == none or day == none or month == none or year == none:
        return none
    if year >= 70 and year <= 99:
        year = year + 1900
    elif year >= 0 and year <= 69:
        year = year + 2000
    if day < 1 or day > 31 or year < 1601 or hms[0] > 23 or hms[1] > 59 or hms[2] > 59:
        return none
    return time_timegm({"year": year, "month": month, "day": day, "hour": hms[0], "minute": hms[1], "second": hms[2]})

class Cookie:
    def __init__(self, version, name, value, port, port_specified, domain, domain_specified, domain_initial_dot, path, path_specified, secure, expires, discard, comment, comment_url, rest, rfc2109=false):
        self.version = version
        self.name = name
        self.value = value
        self.port = port
        self.port_specified = port_specified
        self.domain = domain.lower()
        self.domain_specified = domain_specified
        self.domain_initial_dot = domain_initial_dot
        self.path = path
        self.path_specified = path_specified
        self.secure = secure
        self.expires = expires
        self.discard = discard
        self.comment = comment
        self.comment_url = comment_url
        self.rfc2109 = rfc2109
        self._rest = rest
        if rest == none:
            self._rest = {}
        self.creation = time()

    def has_nonstandard_attr(self, name):
        return name in self._rest

    def get_nonstandard_attr(self, name, default=none):
        return self._rest.get(name, default)

    def set_nonstandard_attr(self, name, value):
        self._rest[name] = value

    def is_expired(self, now=none):
        if now == none:
            now = time()
        return self.expires != none and self.expires <= now

    def __str__(self):
        var p = ""
        if self.path != none:
            p = self.path
        var nv = self.name
        if self.value != none:
            nv = self.name + "=" + self.value
        return "<Cookie " + nv + " for " + self.domain + p + ">"

    def __repr__(self):
        return "Cookie(name=" + repr(self.name) + ", value=" + repr(self.value) + ", domain=" + repr(self.domain) + ", path=" + repr(self.path) + ")"

def _host_only(host):
    # "Example.org:8080" -> "example.org"; IPv6 literals keep their brackets off
    host = host.lower()
    if host.startswith("["):
        var e = host.find("]")
        if e > 0:
            return host[1:e]
    var i = host.rfind(":")
    if i >= 0 and host.find(":") == i:
        host = host[0:i]
    return host

def domain_match(host, domain):
    # RFC 6265 5.1.3
    if host == domain:
        return true
    if not host.endswith(domain):
        return false
    var d = domain
    if not d.startswith("."):
        if not host.endswith("." + d):
            return false
    return not _is_ip(host)

def _is_ip(host):
    if host.find(":") >= 0:
        return true
    var parts = host.split(".")
    if len(parts) != 4:
        return false
    for p in parts:
        if not p.isdigit():
            return false
    return true

def _path_match(req_path, cookie_path):
    # RFC 6265 5.1.4
    if req_path == cookie_path:
        return true
    if req_path.startswith(cookie_path):
        if cookie_path.endswith("/"):
            return true
        if req_path[len(cookie_path):len(cookie_path) + 1] == "/":
            return true
    return false

def _default_path(path):
    if path == "" or not path.startswith("/"):
        return "/"
    var i = path.rfind("/")
    if i == 0:
        return "/"
    return path[0:i]

class DefaultCookiePolicy:
    # RFC 6265: a cookie for a domain the request host does not belong to,
    # or for a public suffix-like single label, is refused.
    def __init__(self, blocked_domains=none, allowed_domains=none, secure_protocols=["https", "wss"]):
        self._blocked = []
        if blocked_domains != none:
            self._blocked = list(blocked_domains)
        self._allowed = allowed_domains
        self.secure_protocols = secure_protocols

    def blocked_domains(self):
        return tuple(self._blocked)

    def set_blocked_domains(self, blocked_domains):
        self._blocked = list(blocked_domains)

    def is_blocked(self, domain):
        for b in self._blocked:
            if domain_match(domain, b.lstrip(".")) or domain == b:
                return true
        return false

    def set_ok(self, cookie, request):
        var host = _host_only(request.host)
        if self.is_blocked(cookie.domain.lstrip(".")):
            return false
        if self._allowed != none:
            var any = false
            for a in self._allowed:
                if domain_match(host, a.lstrip(".")):
                    any = true
            if not any:
                return false
        if cookie.domain_specified:
            var d = cookie.domain.lstrip(".")
            if d.find(".") < 0 and d != host:
                return false            # "com", "localhost" as a Domain
            if not domain_match(host, d):
                return false
        return true

    def return_ok(self, cookie, request):
        var scheme = request.type
        if cookie.secure and not (scheme in self.secure_protocols):
            return false
        return true

class CookieJar:
    def __init__(self, policy=none):
        if policy == none:
            policy = DefaultCookiePolicy()
        self._policy = policy
        self._cookies = {}            # domain -> {path -> {name -> Cookie}}

    def set_policy(self, policy):
        self._policy = policy

    def __iter__(self):
        return iter(self._all())

    def __len__(self):
        return len(self._all())

    def __repr__(self):
        return "<CookieJar[" + ", ".join([str(c) for c in self._all()]) + "]>"

    def _all(self):
        var out = []
        for d in self._cookies:
            for p in self._cookies[d]:
                for n in self._cookies[d][p]:
                    out.append(self._cookies[d][p][n])
        return out

    def set_cookie(self, cookie):
        if not (cookie.domain in self._cookies):
            self._cookies[cookie.domain] = {}
        var byp = self._cookies[cookie.domain]
        if not (cookie.path in byp):
            byp[cookie.path] = {}
        byp[cookie.path][cookie.name] = cookie

    def set_cookie_if_ok(self, cookie, request):
        if self._policy.set_ok(cookie, request):
            self.set_cookie(cookie)

    def clear(self, domain=none, path=none, name=none):
        if domain == none:
            self._cookies = {}
            return
        if path == none:
            del self._cookies[domain]
            return
        if name == none:
            del self._cookies[domain][path]
            return
        del self._cookies[domain][path][name]

    def clear_session_cookies(self):
        for c in self._all():
            if c.discard:
                self.clear(c.domain, c.path, c.name)

    def clear_expired_cookies(self):
        var now = time()
        for c in self._all():
            if c.is_expired(now):
                self.clear(c.domain, c.path, c.name)

    def _cookies_for_request(self, request):
        var host = _host_only(request.host)
        var path = urllib_path(request.selector)
        var now = time()
        var out = []
        for c in self._all():
            if c.is_expired(now):
                continue
            if c.domain_specified:
                if not domain_match(host, c.domain.lstrip(".")):
                    continue
            elif host != c.domain:
                continue
            if not _path_match(path, c.path):
                continue
            if not self._policy.return_ok(c, request):
                continue
            out.append(c)
        # longer paths first, then earlier creation (RFC 6265 5.4)
        out = sorted(out, key=lambda c: (-len(c.path), c.creation))
        return out

    def add_cookie_header(self, request):
        var cs = self._cookies_for_request(request)
        if len(cs) == 0:
            return
        var parts = []
        for c in cs:
            if c.value == none:
                parts.append(c.name)
            else:
                parts.append(c.name + "=" + c.value)
        request.add_unredirected_header("Cookie", "; ".join(parts))
        self.clear_expired_cookies()

    def make_cookies(self, response, request):
        var headers = response.info()
        var lines = headers.get_all("Set-Cookie", [])
        var out = []
        var host = _host_only(request.host)
        var req_path = urllib_path(request.selector)
        for line in lines:
            var c = _parse_set_cookie(line, host, req_path)
            if c != none:
                out.append(c)
        return out

    def extract_cookies(self, response, request):
        for c in self.make_cookies(response, request):
            if c.expires != none and c.expires <= time():
                # an expiry in the past deletes the cookie
                try:
                    self.clear(c.domain, c.path, c.name)
                except KeyError:
                    pass
                continue
            self.set_cookie_if_ok(c, request)

def urllib_path(selector):
    # The path of a request selector ("/a/b?q" -> "/a/b"); a proxied
    # request's selector is the whole URL.
    var s = selector
    if s.find("://") >= 0:
        s = s[s.find("://") + 3:]
        var i = s.find("/")
        if i < 0:
            return "/"
        s = s[i:]
    var q = s.find("?")
    if q >= 0:
        s = s[0:q]
    var h = s.find("#")
    if h >= 0:
        s = s[0:h]
    if s == "":
        return "/"
    return s

def _parse_set_cookie(line, host, req_path):
    var parts = line.split(";")
    var first = parts[0]
    var eq = first.find("=")
    if eq < 0:
        return none
    var name = first[0:eq].strip()
    var value = first[eq + 1:].strip()
    if name == "":
        return none
    var domain = host
    var domain_specified = false
    var path = _default_path(req_path)
    var path_specified = false
    var secure = false
    var expires = none
    var max_age = none
    var rest = {}
    for attr in parts[1:]:
        var a = attr.strip()
        var k = a
        var v = ""
        var i = a.find("=")
        if i >= 0:
            k = a[0:i].strip()
            v = a[i + 1:].strip()
        var kl = k.lower()
        if kl == "domain":
            if v != "":
                domain = v.lower().lstrip(".")
                domain_specified = true
        elif kl == "path":
            if v.startswith("/"):
                path = v
                path_specified = true
        elif kl == "secure":
            secure = true
        elif kl == "expires":
            var t = _http_date(v)
            if t != none:
                expires = t
        elif kl == "max-age":
            var neg = v.startswith("-")
            var digits = v.lstrip("-")
            if digits.isdigit():
                var n = int(digits)
                if neg:
                    n = -n
                max_age = n
        elif kl == "httponly":
            rest["HttpOnly"] = none
        elif kl == "samesite":
            rest["SameSite"] = v
    if max_age != none:
        if max_age <= 0:
            expires = 0
        else:
            expires = time() + max_age
    var stored = domain
    if domain_specified:
        stored = "." + domain
    return Cookie(0, name, value, none, false, stored, domain_specified, domain_specified, path, path_specified, secure, expires, expires == none, none, none, rest)
