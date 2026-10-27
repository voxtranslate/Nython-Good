# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/config.ny - H2Configuration (round 86), as the h2 package's.
#
# client_side            which end this connection is
# header_encoding        None: header names and values in events are bytes;
#                        a codec name ("utf-8"): str
# validate_outbound_headers / normalize_outbound_headers
#                        check what send_headers() is given (RFC 9113 8.2,
#                        8.3) / lowercase names first
# split_outbound_cookies cookie: a=1; b=2 sent as two crumbs (8.2.3: they
#                        compress better)
# validate_inbound_headers / normalize_inbound_headers
#                        a malformed field block resets the stream with
#                        PROTOCOL_ERROR (8.1.1) / cookie crumbs joined with
#                        "; " (8.2.3)
# logger                 an object with debug() and trace() (DummyLogger)
import sys


class DummyLogger:
    """A logger that does nothing (the default)."""
    def __init__(self, *vargs):
        pass

    def debug(self, *vargs, **kwargs):
        pass

    def trace(self, *vargs, **kwargs):
        pass


class OutputLogger:
    """A logger that prints to a file (sys.stderr by default)."""
    def __init__(self, file=None, trace_level=False):
        self.file = file or sys.stderr
        self.trace_level = trace_level

    def debug(self, fmtstr, *args):
        print("h2 (debug): " + (fmtstr % args), file=self.file)

    def trace(self, fmtstr, *args):
        if self.trace_level:
            print("h2 (trace): " + (fmtstr % args), file=self.file)


class H2Configuration:
    def __init__(self, client_side=True, header_encoding=None, validate_outbound_headers=True,
                 normalize_outbound_headers=True, split_outbound_cookies=False,
                 validate_inbound_headers=True, normalize_inbound_headers=True, logger=None):
        self.client_side = bool(client_side)
        self.header_encoding = header_encoding
        self.validate_outbound_headers = bool(validate_outbound_headers)
        self.normalize_outbound_headers = bool(normalize_outbound_headers)
        self.split_outbound_cookies = bool(split_outbound_cookies)
        self.validate_inbound_headers = bool(validate_inbound_headers)
        self.normalize_inbound_headers = bool(normalize_inbound_headers)
        self.logger = logger or DummyLogger(__name__)

    @property
    def header_encoding(self):
        return self._header_encoding

    @header_encoding.setter
    def header_encoding(self, value):
        if not isinstance(value, (bool, str, type(None))):
            raise ValueError("header_encoding must be bool, string, or None")
        if value is True:
            raise ValueError("header_encoding cannot be True")
        self._header_encoding = value

    def __repr__(self):
        return "H2Configuration(client_side=%r, header_encoding=%r)" % (self.client_side, self.header_encoding)
