# nython: module    (import it by name: it runs in a module scope of its own)
# lib/urllib/error.ny - Python's urllib.error (round 77).
#
#   URLError(reason)                    an OSError: the request did not get an
#                                       answer (refused, no such host, TLS...)
#   HTTPError(url, code, msg, hdrs, fp) the server answered with an error
#                                       status; also a response (read(),
#                                       headers, status, geturl())
#   ContentTooShortError(message, content)

class URLError(OSError):
    def __init__(self, reason, filename=none):
        OSError.__init__(self, reason)
        self.reason = reason
        self.filename = filename

    def __str__(self):
        return "<urlopen error " + str(self.reason) + ">"

class HTTPError(URLError):
    def __init__(self, url, code, msg, hdrs, fp):
        URLError.__init__(self, msg)
        self.url = url
        self.code = code
        self.msg = msg
        self.hdrs = hdrs
        self.fp = fp
        self.filename = url

    @property
    def status(self):
        return self.code

    @property
    def headers(self):
        return self.hdrs

    def info(self):
        return self.hdrs

    def geturl(self):
        return self.url

    def getcode(self):
        return self.code

    def read(self, amt=none):
        if self.fp == none:
            return b""
        if amt == none:
            return self.fp.read()
        return self.fp.read(amt)

    def close(self):
        if self.fp != none:
            self.fp.close()

    def __enter__(self):
        return self

    def __exit__(self, a, b, c):
        self.close()
        return false

    def __str__(self):
        return "HTTP Error " + str(self.code) + ": " + str(self.msg)

    def __repr__(self):
        return "<HTTPError " + str(self.code) + ": " + repr(self.msg) + ">"

class ContentTooShortError(URLError):
    def __init__(self, message, content):
        URLError.__init__(self, message)
        self.content = content
