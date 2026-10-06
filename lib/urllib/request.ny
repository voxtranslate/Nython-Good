# nython: module    (import it by name: it runs in a module scope of its own)
# lib/urllib/request.ny - Python's urllib.request (round 77).
#
#     import urllib.request
#     with urllib.request.urlopen("https://example.org/") as r:
#         print(r.status, r.headers["Content-Type"], r.read()[:60])
#
# urlopen(url or Request, data, timeout, context=); Request; build_opener /
# install_opener / OpenerDirector with the handler chain Python has:
# ProxyHandler (the *_proxy environment variables and no_proxy; https goes
# through CONNECT), HTTPHandler, HTTPSHandler(context), HTTPRedirectHandler
# (301/302/303/307/308, loop and count limits, POST->GET as Python does),
# HTTPBasicAuthHandler / ProxyBasicAuthHandler with the password managers,
# HTTPCookieProcessor (http.cookiejar), HTTPDefaultErrorHandler (HTTPError),
# FileHandler (file://), DataHandler (data: URLs, RFC 2397), UnknownHandler.
# A handler subclass may define <scheme>_open, <scheme>_request,
# <scheme>_response or http_error_<code>, as in Python. urlretrieve,
# urlcleanup, getproxies, proxy_bypass, pathname2url, url2pathname.
#
# Inside an async task the waits suspend only that task (the runtime's I/O
# is colorless), so urlopen() needs no async twin.
import socket
import http
import http.client
import urllib.parse
import urllib.error
import base64

__version__ = "0.2"
_DEFAULT_UA = "Nython-urllib/" + __version__
URLError = urllib.error.URLError
HTTPError = urllib.error.HTTPError
ContentTooShortError = urllib.error.ContentTooShortError

_opener = none

def urlopen(url, data=none, timeout=none, cafile=none, capath=none, cadefault=false, context=none):
    global _opener
    var opener = none
    if context != none:
        opener = build_opener(HTTPSHandler(context=context))
    elif cafile != none or capath != none:
        import ssl
        opener = build_opener(HTTPSHandler(context=ssl.create_default_context(cafile=cafile, capath=capath)))
    else:
        if _opener == none:
            _opener = build_opener()
        opener = _opener
    return opener.open(url, data, timeout)

def install_opener(opener):
    global _opener
    _opener = opener

# ─── requests ───────────────────────────────────────────────────────────────

class Request:
    def __init__(self, url, data=none, headers=none, origin_req_host=none, unverifiable=false, method=none):
        self.headers = {}
        self.unredirected_hdrs = {}
        self._data = none
        self._tunnel_host = none
        self.fragment = none
        self.redirect_dict = none
        self.timeout = none
        self.type = none
        self.host = none
        self.selector = none
        self.full_url = url
        self.data = data
        if headers != none:
            for k in headers:
                self.add_header(k, headers[k])
        if origin_req_host == none:
            origin_req_host = self.host
        self.origin_req_host = origin_req_host
        self.unverifiable = unverifiable
        self.method = method

    @property
    def full_url(self):
        if self.fragment:
            return self._full_url + "#" + self.fragment
        return self._full_url

    @full_url.setter
    def full_url(self, url):
        url = _unwrap(url)
        var d = urllib.parse.urldefrag(url)
        self._full_url = d[0]
        self.fragment = d[1]
        self._parse()

    @property
    def data(self):
        return self._data

    @data.setter
    def data(self, data):
        if data != self._data:
            self._data = data
            if self.has_header("Content-length"):
                self.remove_header("Content-length")

    def _parse(self):
        var i = self._full_url.find(":")
        var scheme = none
        if i > 0:
            scheme = self._full_url[0:i]
            for ch in scheme:
                if not (ch.isalnum() or ch == "+" or ch == "-" or ch == "."):
                    scheme = none
                    break
        if scheme == none:
            raise ValueError("unknown url type: " + repr(self.full_url))
        self.type = scheme.lower()
        var rest = self._full_url[i + 1:]
        var hs = _splithost(rest)
        self.host = hs[0]
        self.selector = hs[1]
        if self.host:
            self.host = urllib.parse.unquote(self.host)

    def get_method(self):
        if self.method != none:
            return self.method
        if self.data != none:
            return "POST"
        return "GET"

    def get_full_url(self):
        return self.full_url

    def set_proxy(self, host, type):
        if self.type == "https" and not self._tunnel_host:
            self._tunnel_host = self.host
        else:
            self.type = type
            self.selector = self.full_url
        self.host = host

    def has_proxy(self):
        return self.selector == self.full_url

    def add_header(self, key, val):
        self.headers[key.capitalize()] = val

    def add_unredirected_header(self, key, val):
        self.unredirected_hdrs[key.capitalize()] = val

    def has_header(self, header_name):
        return header_name in self.headers or header_name in self.unredirected_hdrs

    def get_header(self, header_name, default=none):
        if header_name in self.headers:
            return self.headers[header_name]
        return self.unredirected_hdrs.get(header_name, default)

    def remove_header(self, header_name):
        if header_name in self.headers:
            del self.headers[header_name]
        if header_name in self.unredirected_hdrs:
            del self.unredirected_hdrs[header_name]

    def header_items(self):
        var hdrs = {}
        for k in self.unredirected_hdrs:
            hdrs[k] = self.unredirected_hdrs[k]
        for k in self.headers:
            hdrs[k] = self.headers[k]
        return list(hdrs.items())

    def __repr__(self):
        return "<urllib.request.Request object at " + hex(id(self)) + ">"

def _unwrap(url):
    # "<URL:http://x/>" -> "http://x/"
    url = str(url).strip()
    if url.startswith("<") and url.endswith(">"):
        url = url[1:-1].strip()
    if url.startswith("URL:"):
        url = url[4:].strip()
    return url

def _splithost(rest):
    # "//host:port/path" -> [host:port, "/path"]; anything else -> [none, rest]
    if not rest.startswith("//"):
        return [none, rest]
    var r = rest[2:]
    var cut = len(r)
    for ch in ["/", "?", "#"]:
        var j = r.find(ch)
        if j >= 0 and j < cut:
            cut = j
    var path = r[cut:]
    if path != "" and not path.startswith("/"):
        path = "/" + path
    return [r[0:cut], path]

def _splituser(host):
    var i = host.rfind("@")
    if i < 0:
        return [none, host]
    return [host[0:i], host[i + 1:]]

def _splitpasswd(user):
    var i = user.find(":")
    if i < 0:
        return [user, none]
    return [user[0:i], user[i + 1:]]

# ─── responses that are not HTTP's ─────────────────────────────────────────

class addinfourl:
    # A file-like response: read/readline/readlines/close plus info(),
    # geturl(), getcode() (file: and data: URLs).
    def __init__(self, fp, headers, url, code=none):
        self.fp = fp
        self.headers = headers
        self.url = url
        self.code = code
        self.status = code

    def read(self, n=-1):
        return self.fp.read(n)

    def readline(self, limit=-1):
        return self.fp.readline(limit)

    def readlines(self):
        var out = []
        var line = self.readline()
        while len(line) > 0:
            out.append(line)
            line = self.readline()
        return out

    def __iter__(self):
        return iter(self.readlines())

    def info(self):
        return self.headers

    def geturl(self):
        return self.url

    def getcode(self):
        return self.code

    def close(self):
        if self.fp != none:
            self.fp.close()

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

class _BytesIO:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, n=-1):
        if n == none or n < 0:
            n = len(self.data) - self.pos
        var out = self.data[self.pos:self.pos + n]
        self.pos = self.pos + len(out)
        return out

    def readline(self, limit=-1):
        var i = self.data.find(b"\n", self.pos)
        var end = len(self.data)
        if i >= 0:
            end = i + 1
        if limit >= 0 and end - self.pos > limit:
            end = self.pos + limit
        var out = self.data[self.pos:end]
        self.pos = end
        return out

    def close(self):
        pass

def _message(pairs):
    var m = http.client.HTTPMessage()
    for p in pairs:
        m.add(p[0], p[1])
    return m

# ─── handlers ───────────────────────────────────────────────────────────────

class BaseHandler:
    handler_order = 500

    def add_parent(self, parent):
        self.parent = parent

    def close(self):
        pass

    def __lt__(self, other):
        return self.handler_order < other.handler_order

class OpenerDirector:
    def __init__(self):
        self.addheaders = [("User-agent", _DEFAULT_UA)]
        self.handlers = []

    def add_handler(self, handler):
        handler.add_parent(self)
        self.handlers.append(handler)
        self.handlers = sorted(self.handlers, key=lambda h: h.handler_order)

    def close(self):
        pass

    def _chain(self, meth_name, *args):
        for h in self.handlers:
            if hasattr(h, meth_name):
                var result = getattr(h, meth_name)(*args)
                if result != none:
                    return result
        return none

    def open(self, fullurl, data=none, timeout=none):
        var req = fullurl
        if isinstance(fullurl, "str"):
            req = Request(fullurl, data)
        elif data != none:
            req.data = data
        req.timeout = timeout
        var protocol = req.type
        for h in self.handlers:
            var pre = protocol + "_request"
            if hasattr(h, pre):
                req = getattr(h, pre)(req)
        var response = self._open(req)
        for h in self.handlers:
            var post = protocol + "_response"
            if hasattr(h, post):
                response = getattr(h, post)(req, response)
        return response

    def _open(self, req):
        var result = self._chain("default_open", req)
        if result != none:
            return result
        result = self._chain(req.type + "_open", req)
        if result != none:
            return result
        return self._chain("unknown_open", req)

    def error(self, proto, req, fp, code, msg, hdrs):
        # http_error_<code> handlers, then http_error_default
        var result = self._chain("http_error_" + str(code), req, fp, code, msg, hdrs)
        if result != none:
            return result
        return self._chain("http_error_default", req, fp, code, msg, hdrs)

def build_opener(*handlers):
    var opener = OpenerDirector()
    var defaults = [ProxyHandler, UnknownHandler, HTTPHandler, HTTPDefaultErrorHandler, HTTPRedirectHandler, FileHandler, HTTPErrorProcessor, DataHandler, HTTPSHandler]
    var skip = {}
    for klass in defaults:
        for check in handlers:
            if isinstance(check, BaseHandler):
                if isinstance(check, klass):
                    skip[id(klass)] = true
            elif check is klass:
                skip[id(klass)] = true
    for klass in defaults:
        if not (id(klass) in skip):
            opener.add_handler(klass())
    for h in handlers:
        if isinstance(h, BaseHandler):
            opener.add_handler(h)
        else:
            opener.add_handler(h())
    return opener

class UnknownHandler(BaseHandler):
    handler_order = 900

    def unknown_open(self, req):
        raise URLError("unknown url type: " + str(req.type))

class HTTPDefaultErrorHandler(BaseHandler):
    def http_error_default(self, req, fp, code, msg, hdrs):
        raise HTTPError(req.full_url, code, msg, hdrs, fp)

class HTTPErrorProcessor(BaseHandler):
    handler_order = 1000

    def http_response(self, request, response):
        var code = response.code
        if code == none or (code >= 200 and code < 300):
            return response
        return self.parent.error("http", request, response, code, response.msg, response.info())

    def https_response(self, request, response):
        return self.http_response(request, response)

class AbstractHTTPHandler(BaseHandler):
    def __init__(self, debuglevel=none):
        self._debuglevel = 0
        if debuglevel != none:
            self._debuglevel = debuglevel

    def set_http_debuglevel(self, level):
        self._debuglevel = level

    def do_request_(self, request):
        if not request.host:
            raise URLError("no host given")
        if request.data != none:
            var data = request.data
            if isinstance(data, "str"):
                raise TypeError("POST data should be bytes, an iterable of bytes, or a file object. It cannot be of type str.")
            if not request.has_header("Content-type"):
                request.add_unredirected_header("Content-type", "application/x-www-form-urlencoded")
            if not request.has_header("Content-length") and not request.has_header("Transfer-encoding"):
                if isinstance(data, "bytes") or isinstance(data, "bytearray"):
                    request.add_unredirected_header("Content-length", str(len(data)))
                else:
                    request.add_unredirected_header("Transfer-encoding", "chunked")
        var sel_host = request.host
        if request.has_proxy():
            var parts = urllib.parse.urlsplit(request.selector)
            sel_host = parts.netloc
        if not request.has_header("Host"):
            request.add_unredirected_header("Host", sel_host)
        for pair in self.parent.addheaders:
            var name = pair[0].capitalize()
            if not request.has_header(name):
                request.add_unredirected_header(name, pair[1])
        return request

    def do_open(self, http_class, req, **http_conn_args):
        var host = req.host
        if not host:
            raise URLError("no host given")
        var h = http_class(host, timeout=req.timeout, **http_conn_args)
        h.set_debuglevel(self._debuglevel)
        var headers = {}
        for k in req.unredirected_hdrs:
            headers[k] = req.unredirected_hdrs[k]
        for k in req.headers:
            if not (k in headers):
                headers[k] = req.headers[k]
        headers["Connection"] = "close"
        var titled = {}
        for k in headers:
            titled[k.title()] = headers[k]
        if req._tunnel_host:
            var tunnel_headers = {}
            if "Proxy-Authorization" in titled:
                tunnel_headers["Proxy-Authorization"] = titled["Proxy-Authorization"]
                del titled["Proxy-Authorization"]
            h.set_tunnel(req._tunnel_host, none, tunnel_headers)
        var r = none
        try:
            try:
                h.request(req.get_method(), req.selector, req.data, titled, req.has_header("Transfer-encoding"))
            except OSError as err:
                raise URLError(err)
            r = h.getresponse()
        except BaseException:
            h.close()
            raise
        # The response owns the connection now: its socket closes when the
        # body has been read or the response is closed.
        r._on_done = _close_response_socket
        if r._done:
            _close_response_socket(r)
        h.sock = none
        r.url = req.get_full_url()
        r.msg = r.reason
        return r

def _close_response_socket(resp):
    if resp.sock != none:
        try:
            resp.sock.close()
        except OSError:
            pass

class HTTPHandler(AbstractHTTPHandler):
    def http_open(self, req):
        return self.do_open(http.client.HTTPConnection, req)

    def http_request(self, req):
        return self.do_request_(req)

class HTTPSHandler(AbstractHTTPHandler):
    # The default context is made by the first https request, not here:
    # build_opener() installs this handler in every opener, and on a system
    # without OpenSSL that made every urlopen() fail, plain http included
    # (CPython leaves the handler out when there is no ssl module).
    def __init__(self, debuglevel=none, context=none, check_hostname=none):
        AbstractHTTPHandler.__init__(self, debuglevel)
        if context != none and check_hostname != none:
            context.check_hostname = check_hostname
        self._context = context
        self._check_hostname = check_hostname

    def https_open(self, req):
        if self._context == none:
            import ssl
            self._context = ssl.create_default_context()
            if self._check_hostname != none:
                self._context.check_hostname = self._check_hostname
        return self.do_open(http.client.HTTPSConnection, req, context=self._context)

    def https_request(self, req):
        return self.do_request_(req)

class HTTPRedirectHandler(BaseHandler):
    max_repeats = 4
    max_redirections = 10

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        var m = req.get_method()
        var ok = (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) and (m == "GET" or m == "HEAD")
        ok = ok or ((code == 301 or code == 302 or code == 303) and m == "POST")
        if not ok:
            raise HTTPError(req.full_url, code, msg, headers, fp)
        newurl = newurl.replace(" ", "%20")
        var newheaders = {}
        for k in req.headers:
            var kl = k.lower()
            if kl != "content-length" and kl != "content-type":
                newheaders[k] = req.headers[k]
        var method = "HEAD"
        if m != "HEAD":
            method = "GET"
        return Request(newurl, none, newheaders, req.origin_req_host, true, method)

    def http_error_302(self, req, fp, code, msg, headers):
        var newurl = headers.get("location")
        if newurl == none:
            newurl = headers.get("uri")
        if newurl == none:
            return none
        var parts = urllib.parse.urlparse(newurl)
        if not (parts.scheme in ["http", "https", "ftp", ""]):
            raise HTTPError(newurl, code, msg + " - Redirection to url '" + newurl + "' is not allowed", headers, fp)
        if parts.path == "" and parts.netloc != "":
            newurl = urllib.parse.urlunparse((parts.scheme, parts.netloc, "/", parts.params, parts.query, parts.fragment))
        newurl = urllib.parse.urljoin(req.full_url, newurl)
        var newreq = self.redirect_request(req, fp, code, msg, headers, newurl)
        if newreq == none:
            return none
        # loops: the same URL too often, or too many redirections in all
        var visited = req.redirect_dict
        if visited == none:
            visited = {}
        newreq.redirect_dict = visited
        if visited.get(newurl, 0) >= self.max_repeats or len(visited) >= self.max_redirections:
            raise HTTPError(req.full_url, code, "The HTTP server returned a redirect error that would lead to an infinite loop.\nThe last 30x error message was:\n" + msg, headers, fp)
        visited[newurl] = visited.get(newurl, 0) + 1
        fp.read()
        fp.close()
        return self.parent.open(newreq, none, req.timeout)

    def http_error_301(self, req, fp, code, msg, headers):
        return self.http_error_302(req, fp, code, msg, headers)

    def http_error_303(self, req, fp, code, msg, headers):
        return self.http_error_302(req, fp, code, msg, headers)

    def http_error_307(self, req, fp, code, msg, headers):
        return self.http_error_302(req, fp, code, msg, headers)

    def http_error_308(self, req, fp, code, msg, headers):
        return self.http_error_302(req, fp, code, msg, headers)

# ─── proxies ────────────────────────────────────────────────────────────────

def getproxies():
    # {"http": url, "https": url, "no": "host,.domain"} from the environment;
    # the lowercase name wins, as in Python.
    var env = os_environ()
    var out = {}
    for name in env:
        var n = name.lower()
        if n.endswith("_proxy") and env[name] != "" and name != n:
            out[n[0:len(n) - 6]] = env[name]
    for name in env:
        var n2 = name.lower()
        if n2.endswith("_proxy") and env[name] != "" and name == n2:
            out[n2[0:len(n2) - 6]] = env[name]
    if "REQUEST_METHOD" in env and "http" in out:
        del out["http"]            # CGI: HTTP_PROXY is a request header
    return out

def proxy_bypass(host, proxies=none):
    if proxies == none:
        proxies = getproxies()
    var no = proxies.get("no", "")
    if no == "*":
        return true
    var h = host.lower()
    var hostonly = h
    if h.startswith("["):
        hostonly = h[1:h.find("]")]
    elif h.count(":") == 1:
        hostonly = h[0:h.find(":")]
    for name in no.replace(" ", "").split(","):
        if name == "":
            continue
        name = name.lstrip(".").lower()
        if hostonly == name or h == name or hostonly.endswith("." + name) or h.endswith("." + name):
            return true
    return false

def _parse_proxy(proxy):
    # -> [scheme or none, user, password, "host:port"]
    var scheme = none
    var rest = proxy
    var i = proxy.find("://")
    if i > 0:
        scheme = proxy[0:i]
        rest = proxy[i + 3:]
    var end = rest.find("/")
    if end >= 0:
        rest = rest[0:end]
    var up = _splituser(rest)
    var user = none
    var password = none
    if up[0] != none:
        var pw = _splitpasswd(up[0])
        user = urllib.parse.unquote(pw[0])
        if pw[1] != none:
            password = urllib.parse.unquote(pw[1])
    return [scheme, user, password, up[1]]

class ProxyHandler(BaseHandler):
    handler_order = 100

    def __init__(self, proxies=none):
        if proxies == none:
            proxies = getproxies()
        self.proxies = proxies

    def default_open(self, req):
        var t = req.type
        if req._tunnel_host or req.has_proxy():
            return none
        if not (t in self.proxies) or t == "no":
            return none
        var host = req.host
        if host != none and proxy_bypass(host, self.proxies):
            return none
        var p = _parse_proxy(self.proxies[t])
        var proxy_type = p[0]
        if proxy_type == none:
            proxy_type = t
        if p[1] != none and p[2] != none:
            var creds = base64.b64encode((p[1] + ":" + p[2]).encode()).decode("ascii")
            req.add_header("Proxy-authorization", "Basic " + creds)
        var hostport = urllib.parse.unquote(p[3])
        req.set_proxy(hostport, proxy_type)
        if t == proxy_type or t == "https":
            return none            # the scheme's own handler, now via the proxy
        return self.parent.open(req, none, req.timeout)

# ─── authentication ─────────────────────────────────────────────────────────

class HTTPPasswordMgr:
    def __init__(self):
        self.passwd = {}

    def add_password(self, realm, uri, user, passwd):
        if isinstance(uri, "str"):
            uri = [uri]
        if not (realm in self.passwd):
            self.passwd[realm] = []
        for u in uri:
            self.passwd[realm].append([self._reduce(u), user, passwd])

    def find_user_password(self, realm, authuri):
        var target = self._reduce(authuri)
        for entry in self.passwd.get(realm, []):
            if self._is_suburi(entry[0], target):
                return [entry[1], entry[2]]
        return [none, none]

    def _reduce(self, uri):
        var parts = urllib.parse.urlsplit(uri)
        if parts.netloc != "":
            var port = parts.port
            var host = parts.hostname
            if port == none:
                if parts.scheme == "https":
                    port = 443
                else:
                    port = 80
            var path = parts.path
            if path == "":
                path = "/"
            return [host + ":" + str(port), path]
        return [uri, "/"]

    def _is_suburi(self, base, test):
        if base[0] != test[0]:
            return false
        var prefix = base[1]
        if not prefix.endswith("/"):
            prefix = prefix + "/"
        return test[1] == base[1] or test[1].startswith(prefix)

class HTTPPasswordMgrWithDefaultRealm(HTTPPasswordMgr):
    def find_user_password(self, realm, authuri):
        var r = HTTPPasswordMgr.find_user_password(self, realm, authuri)
        if r[0] != none:
            return r
        return HTTPPasswordMgr.find_user_password(self, none, authuri)

class HTTPPasswordMgrWithPriorAuth(HTTPPasswordMgrWithDefaultRealm):
    def __init__(self):
        HTTPPasswordMgrWithDefaultRealm.__init__(self)
        self.authenticated = {}

    def add_password(self, realm, uri, user, passwd, is_authenticated=false):
        HTTPPasswordMgrWithDefaultRealm.add_password(self, realm, uri, user, passwd)
        self.update_authenticated(uri, is_authenticated)

    def update_authenticated(self, uri, is_authenticated=false):
        if isinstance(uri, "str"):
            uri = [uri]
        for u in uri:
            self.authenticated[str(self._reduce(u))] = is_authenticated

    def is_authenticated(self, authuri):
        var t = self._reduce(authuri)
        for k in self.authenticated:
            if self.authenticated[k] and k == str(t):
                return true
        return false

def _basic_realm(header):
    # The realm of a "Basic" challenge in a WWW-Authenticate value, "" when
    # the challenge has none, none when there is no Basic challenge.
    var low = header.lower()
    var i = low.find("basic")
    if i < 0:
        return none
    var r = low.find("realm=", i)
    if r < 0:
        return ""
    var v = header[r + 6:].strip()
    if v.startswith("\""):
        var e = v.find("\"", 1)
        if e > 0:
            return v[1:e]
        return v[1:]
    var c = v.find(",")
    if c >= 0:
        v = v[0:c]
    return v.strip()

class AbstractBasicAuthHandler:
    def __init__(self, password_mgr=none):
        if password_mgr == none:
            password_mgr = HTTPPasswordMgr()
        self.passwd = password_mgr
        self.add_password = self.passwd.add_password

    def _auth_value(self, user, pw):
        return "Basic " + base64.b64encode((user + ":" + pw).encode()).decode("ascii")

    def http_error_auth_reqed(self, authreq, host, req, headers):
        var values = headers.get_all(authreq, [])
        for v in values:
            var realm = _basic_realm(v)
            if realm != none:
                return self.retry_http_basic_auth(host, req, realm)
        return none

    def retry_http_basic_auth(self, host, req, realm):
        var up = self.passwd.find_user_password(realm, host)
        if up[1] == none:
            return none
        var auth = self._auth_value(up[0], up[1])
        if req.get_header(self.auth_header, none) == auth:
            return none            # it was refused already
        req.add_unredirected_header(self.auth_header, auth)
        return self.parent.open(req, none, req.timeout)

    def http_request(self, req):
        if hasattr(self.passwd, "is_authenticated") and self.passwd.is_authenticated(req.full_url):
            var up = self.passwd.find_user_password(none, req.full_url)
            if up[0] != none and not req.has_header("Authorization"):
                req.add_unredirected_header("Authorization", self._auth_value(up[0], up[1]))
        return req

    def https_request(self, req):
        return self.http_request(req)

class HTTPBasicAuthHandler(AbstractBasicAuthHandler, BaseHandler):
    auth_header = "Authorization"

    def http_error_401(self, req, fp, code, msg, headers):
        fp.read()
        fp.close()
        return self.http_error_auth_reqed("www-authenticate", req.full_url, req, headers)

class ProxyBasicAuthHandler(AbstractBasicAuthHandler, BaseHandler):
    auth_header = "Proxy-authorization"

    def http_error_407(self, req, fp, code, msg, headers):
        fp.read()
        fp.close()
        return self.http_error_auth_reqed("proxy-authenticate", req.host, req, headers)

class HTTPCookieProcessor(BaseHandler):
    def __init__(self, cookiejar=none):
        import http.cookiejar
        if cookiejar == none:
            cookiejar = http.cookiejar.CookieJar()
        self.cookiejar = cookiejar

    def http_request(self, request):
        self.cookiejar.add_cookie_header(request)
        return request

    def http_response(self, request, response):
        self.cookiejar.extract_cookies(response, request)
        return response

    def https_request(self, request):
        return self.http_request(request)

    def https_response(self, request, response):
        return self.http_response(request, response)

# ─── file: and data: ────────────────────────────────────────────────────────

class FileHandler(BaseHandler):
    def file_open(self, req):
        var host = req.host
        if host and host != "localhost" and host != "127.0.0.1" and host != socket.gethostname():
            raise URLError("file not on local host")
        var localfile = url2pathname(req.selector)
        try:
            var size = os_path_getsize(localfile)
            var mtime = file_mtime(localfile) / 1000
            import http.server
            var mtype = http.server.guess_type(localfile)
            if mtype == "application/octet-stream":
                mtype = "text/plain"
            var headers = _message([("Content-type", mtype), ("Content-length", str(size)), ("Last-modified", http.server.formatdate(mtime))])
            var origurl = "file://" + urllib.parse.quote(localfile)
            if host:
                origurl = "file://" + host + urllib.parse.quote(localfile)
            return addinfourl(open(localfile, "rb"), headers, origurl)
        except OSError as e:
            raise URLError(e, localfile)

class DataHandler(BaseHandler):
    def data_open(self, req):
        var url = req.full_url
        var colon = url.find(":")
        var rest = url[colon + 1:]
        var comma = rest.find(",")
        if comma < 0:
            raise ValueError("data URL has no comma")
        var mediatype = rest[0:comma]
        var data = rest[comma + 1:]
        var raw = none
        if mediatype.endswith(";base64"):
            raw = base64.b64decode(urllib.parse.unquote(data).encode("ascii"))
            mediatype = mediatype[0:len(mediatype) - 7]
        else:
            raw = urllib.parse.unquote_to_bytes(data)
        if mediatype == "":
            mediatype = "text/plain;charset=US-ASCII"
        var headers = _message([("Content-type", mediatype), ("Content-length", str(len(raw)))])
        return addinfourl(_BytesIO(raw), headers, url)

# ─── helpers ────────────────────────────────────────────────────────────────

def pathname2url(pathname):
    return urllib.parse.quote(pathname)

def url2pathname(pathname):
    return urllib.parse.unquote(pathname)

_url_tempfiles = []

def urlretrieve(url, filename=none, reporthook=none, data=none):
    # Copies the URL to a file (a temporary one when no name is given):
    # (filename, headers). reporthook(blocks, block_size, total_size).
    var fp = urlopen(url, data)
    try:
        var headers = fp.info()
        var result = none
        var tfp = none
        if filename != none:
            tfp = open(filename, "wb")
        else:
            var tmp = os_mkstemp()
            filename = tmp[1] if isinstance(tmp, "list") or isinstance(tmp, "tuple") else tmp
            _url_tempfiles.append(filename)
            tfp = open(filename, "wb")
        try:
            result = (filename, headers)
            var bs = 8192
            var size = -1
            var read = 0
            var blocknum = 0
            if "content-length" in headers:
                size = int(headers["Content-Length"])
            if reporthook != none:
                reporthook(blocknum, bs, size)
            while true:
                var block = fp.read(bs)
                if len(block) == 0:
                    break
                read = read + len(block)
                tfp.write(block)
                blocknum = blocknum + 1
                if reporthook != none:
                    reporthook(blocknum, bs, size)
        finally:
            tfp.close()
    finally:
        fp.close()
    if size >= 0 and read < size:
        raise ContentTooShortError("retrieval incomplete: got only " + str(read) + " out of " + str(size) + " bytes", result)
    return result

def urlcleanup():
    global _opener
    for f in _url_tempfiles:
        try:
            os_remove(f)
        except OSError:
            pass
    _url_tempfiles.clear()
    _opener = none
