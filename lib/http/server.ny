# nython: module    (import it by name: it runs in a module scope of its own)
# lib/http/server.ny - Python's http.server (round 77): HTTPServer,
# ThreadingHTTPServer, BaseHTTPRequestHandler, SimpleHTTPRequestHandler.
#
#     import http.server
#     class Hello(http.server.BaseHTTPRequestHandler):
#         protocol_version = "HTTP/1.1"          # keep connections alive
#         def do_GET(self):
#             var body = b"hello"
#             self.send_response(200)
#             self.send_header("Content-Length", str(len(body)))
#             self.end_headers()
#             self.wfile.write(body)
#     http.server.ThreadingHTTPServer(("127.0.0.1", 8000), Hello).serve_forever()
#
# HTTP/1.1 keep-alive, "Expect: 100-continue", HEAD, request-line and header
# limits (414/431), error pages; SimpleHTTPRequestHandler serves a directory
# (index.html, listings, If-Modified-Since, Range is not supported, as in
# Python's). `nython -m http.server [port]` is not wired up; run
# http.server.test() for the same.
import socket
import socketserver
import http
import http.client
import urllib.parse

DEFAULT_ERROR_MESSAGE = "<!DOCTYPE HTML>\n<html lang=\"en\">\n    <head>\n        <meta charset=\"utf-8\">\n        <title>Error response</title>\n    </head>\n    <body>\n        <h1>Error response</h1>\n        <p>Error code: %(code)d</p>\n        <p>Message: %(message)s.</p>\n        <p>Error code explanation: %(code)s - %(explain)s.</p>\n    </body>\n</html>\n"
DEFAULT_ERROR_CONTENT_TYPE = "text/html;charset=utf-8"

_WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

def _two(n):
    if n < 10:
        return "0" + str(n)
    return str(n)

def formatdate(timestamp=none):
    # RFC 9110 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT"
    if timestamp == none:
        timestamp = time()
    var t = time_gmtime(timestamp)
    return _WEEKDAYS[t["weekday"]] + ", " + _two(t["day"]) + " " + _MONTHS[t["month"] - 1] + " " + str(t["year"]) + " " + _two(t["hour"]) + ":" + _two(t["minute"]) + ":" + _two(t["second"]) + " GMT"

def parsedate(text):
    # The three HTTP date forms (IMF-fixdate, RFC 850, asctime) -> seconds
    # since the epoch, or none.
    var s = text.strip()
    for fmt in ["%a, %d %b %Y %H:%M:%S GMT", "%A, %d-%b-%y %H:%M:%S GMT", "%a %b %d %H:%M:%S %Y"]:
        try:
            return time_timegm(time_strptime(s, fmt))
        except ValueError:
            pass
    return none

def html_escape(s, quote=true):
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    if quote:
        s = s.replace("\"", "&quot;").replace("'", "&#x27;")
    return s

_DESCRIPTIONS = {
    100: 'Request received, please continue',
    101: 'Switching to new protocol; obey Upgrade header',
    200: 'Request fulfilled, document follows',
    201: 'Document created, URL follows',
    202: 'Request accepted, processing continues off-line',
    203: 'Request fulfilled from cache',
    204: 'Request fulfilled, nothing follows',
    205: 'Clear input form for further input',
    206: 'Partial content follows',
    300: 'Object has several resources -- see URI list',
    301: 'Object moved permanently -- see URI list',
    302: 'Object moved temporarily -- see URI list',
    303: 'Object moved -- see Method and URL list',
    304: 'Document has not changed since given time',
    305: 'You must use proxy specified in Location to access this resource',
    307: 'Object moved temporarily -- see URI list',
    308: 'Object moved permanently -- see URI list',
    400: 'Bad request syntax or unsupported method',
    401: 'No permission -- see authorization schemes',
    402: 'No payment -- see charging schemes',
    403: 'Request forbidden -- authorization will not help',
    404: 'Nothing matches the given URI',
    405: 'Specified method is invalid for this resource',
    406: 'URI not available in preferred format',
    407: 'You must authenticate with this proxy before proceeding',
    408: 'Request timed out; try again later',
    409: 'Request conflict',
    410: 'URI no longer exists and has been permanently removed',
    411: 'Client must specify Content-Length',
    412: 'Precondition in headers is false',
    413: 'Entity is too large',
    414: 'URI is too long',
    415: 'Entity body in unsupported format',
    416: 'Cannot satisfy request range',
    417: 'Expect condition could not be satisfied',
    418: 'Server refuses to brew coffee because it is a teapot.',
    421: 'Server is not able to produce a response',
    428: 'The origin server requires the request to be conditional',
    429: 'The user has sent too many requests in a given amount of time ("rate limiting")',
    431: 'The server is unwilling to process the request because its header fields are too large',
    451: 'The server is denying access to the resource as a consequence of a legal demand',
    500: 'Server got itself in trouble',
    501: 'Server does not support this operation',
    502: 'Invalid responses from another server/proxy',
    503: 'The server cannot process the request due to a high load',
    504: 'The gateway server did not receive a timely response',
    505: 'Cannot fulfill request',
    511: 'The client needs to authenticate to gain network access',
}

def _server_responses():
    var out = {}
    for code in http.responses:
        out[code] = [http.responses[code], _DESCRIPTIONS.get(code, http.responses[code])]
    return out

class HTTPServer(socketserver.TCPServer):
    allow_reuse_address = true

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        var a = self.server_address
        self.server_name = a[0]
        try:
            self.server_name = socket.getfqdn(a[0])
        except Exception:
            pass
        self.server_port = a[1]

class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = true

class BaseHTTPRequestHandler(socketserver.StreamRequestHandler):
    sys_version = "Nython/0.2.1"
    server_version = "BaseHTTP/0.6"
    error_message_format = DEFAULT_ERROR_MESSAGE
    error_content_type = DEFAULT_ERROR_CONTENT_TYPE
    default_request_version = "HTTP/0.9"
    protocol_version = "HTTP/1.0"
    responses = _server_responses()
    max_request_line = 65536
    max_headers = 100

    def setup(self):
        socketserver.StreamRequestHandler.setup(self)
        self.close_connection = true
        self.command = none
        self.path = none
        self.request_version = self.default_request_version
        self.requestline = ""
        self.raw_requestline = b""
        self.headers = none
        self._headers_buffer = []

    def parse_request(self):
        self.command = none
        self.request_version = self.default_request_version
        var version = self.default_request_version
        self.close_connection = true
        var requestline = self.raw_requestline.decode("iso-8859-1").rstrip("\r\n")
        self.requestline = requestline
        var words = requestline.split()
        if len(words) == 0:
            return false
        if len(words) >= 3:
            version = words[-1]
            var ok = version.startswith("HTTP/")
            var nums = []
            if ok:
                nums = version[5:].split(".")
                ok = len(nums) == 2 and nums[0].isdigit() and nums[1].isdigit() and len(nums[0]) <= 10 and len(nums[1]) <= 10
            if not ok:
                self.send_error(http.HTTPStatus.BAD_REQUEST, "Bad request version (" + repr(version) + ")")
                return false
            var vn = [int(nums[0]), int(nums[1])]
            if (vn[0] > 1 or (vn[0] == 1 and vn[1] >= 1)) and self.protocol_version >= "HTTP/1.1":
                self.close_connection = false
            if vn[0] >= 2:
                self.send_error(http.HTTPStatus.HTTP_VERSION_NOT_SUPPORTED, "Invalid HTTP version (" + version[5:] + ")")
                return false
            self.request_version = version
        if not (len(words) >= 2 and len(words) <= 3):
            self.send_error(http.HTTPStatus.BAD_REQUEST, "Bad request syntax (" + repr(requestline) + ")")
            return false
        var command = words[0]
        var path = words[1]
        if len(words) == 2:
            self.close_connection = true
            if command != "GET":
                self.send_error(http.HTTPStatus.BAD_REQUEST, "Bad HTTP/0.9 request type (" + repr(command) + ")")
                return false
        self.command = command
        self.path = path
        # "//path" is a network path to a URL parser: keep it a path.
        if self.path.startswith("//"):
            self.path = "/" + self.path.lstrip("/")
        try:
            self.headers = http.client.parse_headers(self.rfile)
        except http.client.LineTooLong as e:
            self.send_error(http.HTTPStatus.REQUEST_HEADER_FIELDS_TOO_LARGE, "Line too long", str(e))
            return false
        except http.client.HTTPException as e:
            self.send_error(http.HTTPStatus.REQUEST_HEADER_FIELDS_TOO_LARGE, "Too many headers", str(e))
            return false
        var conntype = self.headers.get("Connection", "")
        if conntype.lower() == "close":
            self.close_connection = true
        elif conntype.lower() == "keep-alive" and self.protocol_version >= "HTTP/1.1":
            self.close_connection = false
        var expect = self.headers.get("Expect", "")
        if expect.lower() == "100-continue" and self.protocol_version >= "HTTP/1.1" and self.request_version >= "HTTP/1.1":
            if not self.handle_expect_100():
                return false
        return true

    def handle_expect_100(self):
        self.send_response_only(http.HTTPStatus.CONTINUE)
        self.end_headers()
        return true

    def handle_one_request(self):
        try:
            self.raw_requestline = self.rfile.readline(self.max_request_line + 1)
            if len(self.raw_requestline) > self.max_request_line:
                self.requestline = ""
                self.request_version = ""
                self.command = ""
                self.send_error(http.HTTPStatus.REQUEST_URI_TOO_LONG)
                return
            if len(self.raw_requestline) == 0:
                self.close_connection = true
                return
            if not self.parse_request():
                return
            var mname = "do_" + self.command
            if not hasattr(self, mname):
                self.send_error(http.HTTPStatus.NOT_IMPLEMENTED, "Unsupported method (" + repr(self.command) + ")")
                return
            getattr(self, mname)()
            self.wfile.flush()
        except TimeoutError as e:
            self.log_error("Request timed out: " + repr(e))
            self.close_connection = true

    def handle(self):
        self.close_connection = true
        self.handle_one_request()
        while not self.close_connection:
            self.handle_one_request()

    def send_error(self, code, message=none, explain=none):
        code = int(code)
        var pair = self.responses.get(code, ["???", "???"])
        if message == none:
            message = pair[0]
        if explain == none:
            explain = pair[1]
        self.log_error("code " + str(code) + ", message " + str(message))
        self.send_response(code, message)
        self.send_header("Connection", "close")
        var body = none
        if code >= 200 and code != 204 and code != 205 and code != 304:
            var content = self.error_message_format % {"code": code, "message": html_escape(str(message), false), "explain": html_escape(str(explain), false)}
            body = content.encode("utf-8", "replace")
            self.send_header("Content-Type", self.error_content_type)
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body != none:
            self.wfile.write(body)

    def send_response(self, code, message=none):
        self.log_request(code)
        self.send_response_only(code, message)
        self.send_header("Server", self.version_string())
        self.send_header("Date", self.date_time_string())

    def send_response_only(self, code, message=none):
        code = int(code)
        if self.request_version != "HTTP/0.9":
            if message == none:
                var pair = self.responses.get(code)
                message = ""
                if pair != none:
                    message = pair[0]
            self._headers_buffer.append((self.protocol_version + " " + str(code) + " " + str(message) + "\r\n").encode("iso-8859-1", "strict"))

    def send_header(self, keyword, value):
        if self.request_version != "HTTP/0.9":
            self._headers_buffer.append((str(keyword) + ": " + str(value) + "\r\n").encode("iso-8859-1", "strict"))
        if str(keyword).lower() == "connection":
            if str(value).lower() == "close":
                self.close_connection = true
            elif str(value).lower() == "keep-alive":
                self.close_connection = false

    def end_headers(self):
        if self.request_version != "HTTP/0.9":
            self._headers_buffer.append(b"\r\n")
            self.flush_headers()

    def flush_headers(self):
        if len(self._headers_buffer) > 0:
            self.wfile.write(b"".join(self._headers_buffer))
            self._headers_buffer = []

    def log_request(self, code="-", size="-"):
        self.log_message("\"%s\" %s %s", self.requestline, str(code), str(size))

    def log_error(self, format, *args):
        self.log_message(format, *args)

    def log_message(self, format, *args):
        var text = format
        if len(args) > 0:
            text = format % tuple(args)
        eprint(self.address_string() + " - - [" + self.log_date_time_string() + "] " + text)

    def version_string(self):
        return self.server_version + " " + self.sys_version

    def date_time_string(self, timestamp=none):
        return formatdate(timestamp)

    def log_date_time_string(self):
        var t = time_localtime(time())
        return _two(t["day"]) + "/" + _MONTHS[t["month"] - 1] + "/" + str(t["year"]) + " " + _two(t["hour"]) + ":" + _two(t["minute"]) + ":" + _two(t["second"])

    def address_string(self):
        return str(self.client_address[0])

_TYPES = {
    ".html": "text/html", ".htm": "text/html", ".css": "text/css", ".js": "text/javascript",
    ".mjs": "text/javascript", ".json": "application/json", ".txt": "text/plain", ".md": "text/markdown",
    ".csv": "text/csv", ".xml": "text/xml", ".svg": "image/svg+xml", ".png": "image/png",
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp",
    ".ico": "image/vnd.microsoft.icon", ".bmp": "image/bmp", ".wasm": "application/wasm",
    ".pdf": "application/pdf", ".zip": "application/zip", ".gz": "application/gzip",
    ".tar": "application/x-tar", ".mp3": "audio/mpeg", ".wav": "audio/x-wav", ".ogg": "audio/ogg",
    ".mp4": "video/mp4", ".webm": "video/webm", ".ttf": "font/ttf", ".otf": "font/otf",
    ".woff": "font/woff", ".woff2": "font/woff2", ".ny": "text/plain", ".py": "text/x-python",
    ".c": "text/plain", ".h": "text/plain", ".cpp": "text/plain", ".hpp": "text/plain",
}

def guess_type(path):
    var dot = path.rfind(".")
    if dot < 0 or dot < path.rfind("/"):
        return "application/octet-stream"
    return _TYPES.get(path[dot:].lower(), "application/octet-stream")

class SimpleHTTPRequestHandler(BaseHTTPRequestHandler):
    # GET/HEAD for the files under `directory` (the working directory by
    # default): index.html for a folder, else a listing; 304 for an unchanged
    # file (If-Modified-Since).
    server_version = "SimpleHTTP/0.6"
    index_pages = ["index.html", "index.htm"]
    extensions_map = _TYPES

    def __init__(self, request, client_address, server, directory=none):
        if directory == none:
            directory = os_getcwd()
        self.directory = directory
        BaseHTTPRequestHandler.__init__(self, request, client_address, server)

    def do_GET(self):
        var f = self.send_head()
        if f != none:
            try:
                self.copyfile(f, self.wfile)
            finally:
                f.close()

    def do_HEAD(self):
        var f = self.send_head()
        if f != none:
            f.close()

    def send_head(self):
        var path = self.translate_path(self.path)
        if os_isdir(path):
            var parts = urllib.parse.urlsplit(self.path)
            if not parts.path.endswith("/"):
                self.send_response(http.HTTPStatus.MOVED_PERMANENTLY)
                var new_url = urllib.parse.urlunsplit((parts[0], parts[1], parts[2] + "/", parts[3], parts[4]))
                self.send_header("Location", new_url)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return none
            var found = false
            for index in self.index_pages:
                var ip = os_path_join(path, index)
                if os_isfile(ip):
                    path = ip
                    found = true
                    break
            if not found:
                return self.list_directory(path)
        if path.endswith("/") or not os_isfile(path):
            self.send_error(http.HTTPStatus.NOT_FOUND, "File not found")
            return none
        var f = none
        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(http.HTTPStatus.NOT_FOUND, "File not found")
            return none
        try:
            var mtime = int(file_mtime(path) / 1000)
            var ims = self.headers.get("If-Modified-Since")
            if ims != none and self.headers.get("If-None-Match") == none:
                var since = parsedate(ims)
                if since != none and mtime <= since:
                    self.send_response(http.HTTPStatus.NOT_MODIFIED)
                    self.end_headers()
                    f.close()
                    return none
            self.send_response(http.HTTPStatus.OK)
            self.send_header("Content-type", self.guess_type(path))
            self.send_header("Content-Length", str(os_path_getsize(path)))
            self.send_header("Last-Modified", self.date_time_string(mtime))
            self.end_headers()
            return f
        except BaseException:
            f.close()
            raise

    def list_directory(self, path):
        var names = none
        try:
            names = os_listdir(path)
        except OSError:
            self.send_error(http.HTTPStatus.NOT_FOUND, "No permission to list directory")
            return none
        names = sorted(names, key=lambda a: a.lower())
        var displaypath = urllib.parse.unquote(self.path)
        displaypath = html_escape(displaypath, false)
        var title = "Directory listing for " + displaypath
        var r = ["<!DOCTYPE HTML>", "<html lang=\"en\">", "<head>", "<meta charset=\"utf-8\">",
                 "<title>" + title + "</title>", "</head>", "<body>", "<h1>" + title + "</h1>", "<hr>", "<ul>"]
        for name in names:
            var fullname = os_path_join(path, name)
            var shown = name
            var link = name
            if os_isdir(fullname):
                shown = name + "/"
                link = name + "/"
            r.append("<li><a href=\"" + urllib.parse.quote(link) + "\">" + html_escape(shown, false) + "</a></li>")
        r.append("</ul>")
        r.append("<hr>")
        r.append("</body>")
        r.append("</html>\n")
        var encoded = "\n".join(r).encode("utf-8")
        self.send_response(http.HTTPStatus.OK)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        return _BytesFile(encoded)

    def translate_path(self, path):
        # The URL path as a file under self.directory; ".." and "." are
        # dropped, so a request never leaves the directory.
        path = path.split("?", 1)[0]
        path = path.split("#", 1)[0]
        var trailing = path.rstrip().endswith("/")
        path = urllib.parse.unquote(path)
        var words = [w for w in path.split("/") if w != ""]
        var out = self.directory
        for word in words:
            if word == "." or word == ".." or word.find("\\") >= 0 or (len(word) >= 2 and word[1] == ":"):
                continue
            out = os_path_join(out, word)
        if trailing:
            out = out + "/"
        return out

    def copyfile(self, source, outputfile):
        var chunk = source.read(65536)
        while len(chunk) > 0:
            outputfile.write(chunk)
            chunk = source.read(65536)

    def guess_type(self, path):
        return guess_type(path)

class _BytesFile:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, n=-1):
        if n < 0:
            n = len(self.data) - self.pos
        var out = self.data[self.pos:self.pos + n]
        self.pos = self.pos + len(out)
        return out

    def close(self):
        pass

def test(HandlerClass=SimpleHTTPRequestHandler, ServerClass=ThreadingHTTPServer, protocol="HTTP/1.0", port=8000, bind="127.0.0.1"):
    HandlerClass.protocol_version = protocol
    var httpd = ServerClass((bind, port), HandlerClass)
    var sa = httpd.socket.getsockname()
    print("Serving HTTP on " + str(sa[0]) + " port " + str(sa[1]) + " (http://" + str(sa[0]) + ":" + str(sa[1]) + "/) ...")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nKeyboard interrupt received, exiting.")
    finally:
        httpd.server_close()

# nython -m http.server [port] [--bind ADDR] [--directory DIR] [--protocol P]
if __name__ == "__main__":
    import sys
    import argparse
    var ap = argparse.ArgumentParser(prog="nython -m http.server", description="Serve a directory over HTTP.")
    ap.add_argument("port", nargs="?", type=int, default=8000, help="the port to listen on (default: 8000)")
    ap.add_argument("-b", "--bind", default="127.0.0.1", metavar="ADDRESS", help="the address to bind (default: 127.0.0.1)")
    ap.add_argument("-d", "--directory", default=os_getcwd(), help="the directory to serve (default: the working directory)")
    ap.add_argument("-p", "--protocol", default="HTTP/1.0", help="HTTP/1.0 or HTTP/1.1 (default: HTTP/1.0)")
    var opts = ap.parse_args()
    class _DirHandler(SimpleHTTPRequestHandler):
        def __init__(self, *a):
            SimpleHTTPRequestHandler.__init__(self, *a, directory=opts.directory)
    test(_DirHandler, ThreadingHTTPServer, opts.protocol, opts.port, opts.bind)
