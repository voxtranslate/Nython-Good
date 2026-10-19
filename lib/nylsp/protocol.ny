# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/nylsp/protocol.ny - JSON-RPC 2.0 over the Language Server Protocol's
# base protocol (round 86).
#
#     t = StdioTransport()            # or SocketTransport(conn)
#     msg = t.read_message()          # a dict, None at the end of input
#     t.write_message({"jsonrpc": "2.0", "id": 1, "result": None})
#     t.pending()                     # input is waiting (never blocks)
#
# The base protocol (LSP 3.17, "Base Protocol"): a header part of
# "Name: value\r\n" fields ended by an empty line, then the content - a
# JSON-RPC message encoded as UTF-8, exactly Content-Length bytes.
# Content-Type is read and ignored (utf-8 is the only charset; "utf8" is
# accepted as LSP says, for backwards compatibility). A header part without
# Content-Length, or content that is not JSON, is answered with a JSON-RPC
# ParseError (-32700) when it can be told apart from the next message.
#
# Not here: batches (JSON-RPC arrays are not used by LSP).

import os
import select

__all__ = ["StdioTransport", "SocketTransport", "ProtocolError", "encode_message",
           "ParseError", "InvalidRequest", "MethodNotFound", "InvalidParams", "InternalError",
           "ServerNotInitialized", "UnknownErrorCode", "RequestFailed", "ServerCancelled",
           "ContentModified", "RequestCancelled", "response", "error_response", "notification", "request"]

# JSON-RPC's codes and LSP's own
ParseError = -32700
InvalidRequest = -32600
MethodNotFound = -32601
InvalidParams = -32602
InternalError = -32603
ServerNotInitialized = -32002
UnknownErrorCode = -32001
RequestFailed = -32803
ServerCancelled = -32802
ContentModified = -32801
RequestCancelled = -32800


class ProtocolError(Exception):
    """A message that cannot be read (the header part, or its content)."""
    def __init__(self, message, code=ParseError):
        Exception.__init__(self, message)
        self.code = code


def encode_message(msg):
    """One message as bytes: the header part and the UTF-8 JSON content."""
    body = json_encode(msg).encode("utf-8")
    return ("Content-Length: " + str(len(body)) + "\r\n\r\n").encode("ascii") + body


def encode_raw(text):
    """The same for content already encoded as JSON text."""
    body = text.encode("utf-8")
    return ("Content-Length: " + str(len(body)) + "\r\n\r\n").encode("ascii") + body


def response(id, result):
    return {"jsonrpc": "2.0", "id": id, "result": result}


def error_response(id, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": id, "error": err}


def notification(method, params):
    return {"jsonrpc": "2.0", "method": method, "params": params}


def request(id, method, params):
    return {"jsonrpc": "2.0", "id": id, "method": method, "params": params}


class _Framer:
    """Splits a byte stream into messages (the header part, then
    Content-Length bytes of content)."""
    def __init__(self):
        self.buf = b""

    def feed(self, data):
        self.buf = self.buf + data

    def next_message(self):
        """A decoded message, None when a whole one has not arrived yet.
        Raises ProtocolError for a bad header part (skipped) or content
        that is not JSON (consumed)."""
        end = self.buf.find(b"\r\n\r\n")
        if end < 0:
            if len(self.buf) > 65536 and self.buf.find(b"\r\n") < 0:
                self.buf = b""
                raise ProtocolError("a header part without an end")
            return None
        head = self.buf[:end].decode("ascii", "replace")
        length = -1
        for line in head.split("\r\n"):
            colon = line.find(":")
            if colon < 0:
                continue
            name = line[:colon].strip().lower()
            if name == "content-length":
                try:
                    length = int(line[colon + 1:].strip())
                except ValueError:
                    length = -1
        if length < 0:
            self.buf = self.buf[end + 4:]
            raise ProtocolError("a header part without a valid Content-Length")
        if len(self.buf) < end + 4 + length:
            return None
        body = self.buf[end + 4:end + 4 + length]
        self.buf = self.buf[end + 4 + length:]
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            raise ProtocolError("content that is not UTF-8")
        try:
            msg = json_decode(text)
        except Exception as e:
            raise ProtocolError("content that is not JSON: " + str(e))
        if not isinstance(msg, dict):
            raise ProtocolError("a message that is not a JSON object", InvalidRequest)
        return msg


class _Transport:
    def __init__(self):
        self.framer = _Framer()
        self.closed = False
        self.bytes_in = 0
        self.bytes_out = 0

    def _read_some(self, timeout):
        """Bytes that arrived within `timeout` seconds (None: block), b""
        at the end of input, None when nothing came in time."""
        raise NotImplementedError

    def _write_all(self, data):
        raise NotImplementedError

    def read_message(self, timeout=None):
        """The next message (a dict); None at the end of input, or when
        `timeout` passed first (then .closed tells which)."""
        while True:
            msg = self.framer.next_message()
            if msg is not None:
                return msg
            if self.closed:
                return None
            data = self._read_some(timeout)
            if data is None:
                return None
            if len(data) == 0:
                self.closed = True
                return None
            self.bytes_in += len(data)
            self.framer.feed(data)

    def pending(self):
        """Whether a whole message is waiting (reads what has arrived, never
        blocks)."""
        if self.framer.buf.find(b"\r\n\r\n") >= 0 and self._whole():
            return True
        if self.closed:
            return False
        while True:
            data = self._read_some(0)
            if data is None:
                break
            if len(data) == 0:
                self.closed = True
                break
            self.bytes_in += len(data)
            self.framer.feed(data)
        return self._whole()

    def _whole(self):
        b = self.framer.buf
        end = b.find(b"\r\n\r\n")
        if end < 0:
            return False
        head = b[:end].decode("ascii", "replace").lower()
        i = head.find("content-length:")
        if i < 0:
            return True      # a bad header part: next_message reports it
        j = head.find("\r\n", i)
        try:
            n = int(head[i + 15:j if j >= 0 else len(head)].strip())
        except ValueError:
            return True
        return len(b) >= end + 4 + n

    def write_message(self, msg):
        self.write_bytes(encode_message(msg))

    def write_raw(self, text):
        self.write_bytes(encode_raw(text))

    def write_bytes(self, data):
        self._write_all(data)
        self.bytes_out += len(data)


class StdioTransport(_Transport):
    """The server's standard input and output (file descriptors 0 and 1)."""
    def __init__(self, rfd=0, wfd=1):
        _Transport.__init__(self)
        self.rfd = rfd
        self.wfd = wfd

    def _read_some(self, timeout):
        if timeout is not None:
            r = select.select([self.rfd], [], [], timeout)[0]
            if not r:
                return None
        try:
            return os.read(self.rfd, 65536)
        except OSError:
            return b""

    def _write_all(self, data):
        n = 0
        while n < len(data):
            try:
                n += os.write(self.wfd, data[n:])
            except BrokenPipeError:
                self.closed = True
                return
            except OSError:
                self.closed = True
                return


class SocketTransport(_Transport):
    """A connected socket (`--tcp PORT`)."""
    def __init__(self, sock):
        _Transport.__init__(self)
        self.sock = sock

    def _read_some(self, timeout):
        if timeout is not None:
            r = select.select([self.sock], [], [], timeout)[0]
            if not r:
                return None
        try:
            return self.sock.recv(65536)
        except OSError:
            return b""

    def _write_all(self, data):
        try:
            self.sock.sendall(data)
        except OSError:
            self.closed = True
