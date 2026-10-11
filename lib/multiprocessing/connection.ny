# nython: module    (import it by name: it runs in a module scope of its own)
# lib/multiprocessing/connection.ny - Pipe() and its Connections, Listener
# and Client (round 80).
#
# Pipe(duplex=True) gives two Connection objects: send(obj) / recv() (any
# picklable object), send_bytes(buf, offset=0, size=None) / recv_bytes(
# maxlength=None) / recv_bytes_into(buf, offset=0), poll(timeout=0.0),
# close(), closed, readable, writable, fileno() (not a real descriptor
# here), the with statement; recv() raises EOFError once the other end is
# closed and nothing is left. Each direction is a mailbox on the creating
# process's object server (lib/multiprocessing/managers.ny), so either end
# can be passed to another process. duplex=False gives (reader, writer).
#
# Listener(address=None, family=None, backlog=1, authkey=None) / Client(
# address, family=None, authkey=None): connections over a socket of their
# own (AF_UNIX, or AF_INET on ('127.0.0.1', 0) and on Windows), CPython's
# 4-byte length framing, the HMAC challenge when authkey is given
# (AuthenticationError), accept(), close(), address, last_accepted.
# wait(object_list, timeout=None): the Connections that have data.

import os
import time
import pickle
import socket
from multiprocessing import managers as _mg

__all__ = ['Client', 'Listener', 'Pipe', 'wait', 'Connection', 'AuthenticationError']

AuthenticationError = _mg.AuthenticationError
BUFSIZE = 8192


class _PipeConnection(object):
    """A connection end of Pipe(): two mailboxes on an object server."""

    def __init__(self, rbox, wbox, readable=True, writable=True):
        self._rbox = rbox
        self._wbox = wbox
        self._readable = readable
        self._writable = writable
        self._closed = False

    def __reduce__(self):
        # the copy made from this pickle is one more writer of its mailbox
        # (so closing this end does not end the other's reading)
        self._check_closed()
        if self._writable and self._wbox is not None:
            self._wbox.ocall("add_writer")
        return (_rebuild_pipe, (self._rbox, self._wbox, self._readable, self._writable))

    @property
    def closed(self):
        return self._closed

    @property
    def readable(self):
        return self._readable

    @property
    def writable(self):
        return self._writable

    def _check_closed(self):
        if self._closed:
            raise OSError("handle is closed")

    def _check_readable(self):
        if not self._readable:
            raise OSError("connection is write-only")

    def _check_writable(self):
        if not self._writable:
            raise OSError("connection is read-only")

    def fileno(self):
        self._check_closed()
        return self._rbox.oid if self._rbox is not None else self._wbox.oid

    def close(self):
        if not self._closed:
            self._closed = True
            if self._writable and self._wbox is not None:
                try:
                    self._wbox.ocall("drop_writer")
                except Exception:
                    pass

    def send_bytes(self, buf, offset=0, size=None):
        self._check_closed()
        self._check_writable()
        var m = bytes(buf)
        var n = len(m)
        if offset < 0:
            raise ValueError("offset is negative")
        if n < offset:
            raise ValueError("buffer length < offset")
        if size is None:
            size = n - offset
        elif size < 0:
            raise ValueError("size is negative")
        elif offset + size > n:
            raise ValueError("buffer length < offset + size")
        self._wbox.ocall("put", b"B" + m[offset:offset + size], True, None)

    def send(self, obj):
        self._check_closed()
        self._check_writable()
        self._wbox.ocall("put", b"P" + pickle.dumps(obj, 5), True, None)

    def _recv(self):
        self._check_closed()
        self._check_readable()
        return self._rbox.ocall("recv")

    def recv_bytes(self, maxlength=None):
        if maxlength is not None and maxlength < 0:
            raise ValueError("negative maxlength")
        var m = self._recv()
        var data = m[1:]
        if maxlength is not None and len(data) > maxlength:
            raise OSError("bad message length")
        return data

    def recv_bytes_into(self, buf, offset=0):
        var data = self.recv_bytes()
        if offset < 0 or offset > len(buf):
            raise ValueError("offset out of bounds")
        if offset + len(data) > len(buf):
            raise BufferTooShort(data)
        buf[offset:offset + len(data)] = data
        return len(data)

    def recv(self):
        var m = self._recv()
        if m[:1] == b"P":
            return pickle.loads(m[1:])
        return pickle.loads(m[1:])

    def poll(self, timeout=0.0):
        self._check_closed()
        self._check_readable()
        return self._rbox.ocall("poll", timeout)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, exc_tb):
        self.close()

    def __repr__(self):
        return "<multiprocessing.connection.Connection object at " + hex(id(self)) + ">"


Connection = _PipeConnection


class BufferTooShort(Exception):
    pass


# the ends this process got from another one: closed when it exits, as a
# process's descriptors are (the reader then sees EOFError)
_received = []


def _rebuild_pipe(rbox, wbox, readable, writable):
    var c = _PipeConnection(rbox, wbox, readable, writable)
    _received.append(c)
    return c


def _close_received():
    for c in _received:
        try:
            c.close()
        except Exception:
            pass


import atexit as _atexit_mod
_atexit_mod.register(_close_received)


def Pipe(duplex=True):
    """Returns pair of connection objects at either end of a pipe"""
    var a = _mg._create("Queue", 0)
    if duplex:
        var b = _mg._create("Queue", 0)
        return _PipeConnection(a, b), _PipeConnection(b, a)
    return _PipeConnection(a, None, True, False), _PipeConnection(None, a, False, True)


# ── Listener / Client over a socket of their own ─────────────────────────────
class _SocketConnection(object):

    def __init__(self, sock):
        self._sock = sock
        self._closed = False
        self.readable = True
        self.writable = True

    @property
    def closed(self):
        return self._closed

    def fileno(self):
        return self._sock.fileno()

    def close(self):
        if not self._closed:
            self._closed = True
            self._sock.close()

    def send_bytes(self, buf, offset=0, size=None):
        var m = bytes(buf)
        if size is None:
            size = len(m) - offset
        _mg._send_msg(self._sock, m[offset:offset + size])

    def send(self, obj):
        _mg._send_msg(self._sock, pickle.dumps(obj, 5))

    def recv_bytes(self, maxlength=None):
        var data = _mg._recv_msg(self._sock)
        if maxlength is not None and len(data) > maxlength:
            raise OSError("bad message length")
        return data

    def recv(self):
        return pickle.loads(_mg._recv_msg(self._sock))

    def poll(self, timeout=0.0):
        return self._sock.wait_readable(timeout)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def _deliver_challenge(c, authkey):
    var msg = os.urandom(32)
    c.send_bytes(_mg._CHALLENGE + msg)
    var response = c.recv_bytes(256)
    if response == _mg._digest(authkey, msg):
        c.send_bytes(_mg._WELCOME)
    else:
        c.send_bytes(_mg._FAILURE)
        raise AuthenticationError('digest received was wrong')


def _answer_challenge(c, authkey):
    var message = c.recv_bytes(256)
    if not message.startswith(_mg._CHALLENGE):
        raise AuthenticationError('Protocol error, expected challenge: ' + repr(message))
    c.send_bytes(_mg._digest(authkey, message[len(_mg._CHALLENGE):]))
    var response = c.recv_bytes(256)
    if response != _mg._WELCOME:
        raise AuthenticationError('digest sent was rejected')


class Listener(object):

    def __init__(self, address=None, family=None, backlog=1, authkey=None):
        var s = None
        if family is None:
            family = "AF_UNIX" if isinstance(address, str) or (address is None and _mg._UNIX) else "AF_INET"
        if family == "AF_UNIX":
            if address is None:
                address = os.path.join(_mg._get_temp_dir(), "listener-" + os.urandom(6).hex())
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.bind(address)
        else:
            if address is None:
                address = ("127.0.0.1", 0)
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(tuple(address))
            address = s.getsockname()
        s.listen(max(backlog, 1))
        self._sock = s
        self._address = address
        self._family = family
        self._authkey = authkey
        self._last_accepted = None

    def accept(self):
        if self._sock is None:
            raise OSError('listener is closed')
        var pair = self._sock.accept()
        self._last_accepted = pair[1]
        var c = _SocketConnection(pair[0])
        if self._authkey is not None:
            _deliver_challenge(c, self._authkey)
            _answer_challenge(c, self._authkey)
        return c

    def close(self):
        if self._sock is not None:
            self._sock.close()
            self._sock = None
            if self._family == "AF_UNIX":
                try:
                    os.unlink(self._address)
                except OSError:
                    pass

    @property
    def address(self):
        return self._address

    @property
    def last_accepted(self):
        return self._last_accepted

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def Client(address, family=None, authkey=None):
    var s = _mg._connect(address)
    var c = _SocketConnection(s)
    if authkey is not None:
        _answer_challenge(c, authkey)
        _deliver_challenge(c, authkey)
    return c


def wait(object_list, timeout=None):
    """Wait till an object in object_list is ready/readable."""
    var deadline = None if timeout is None else time.monotonic() + timeout
    while True:
        var ready = []
        for o in object_list:
            if hasattr(o, "poll"):
                if o.poll(0):
                    ready.append(o)
            elif hasattr(o, "is_alive"):
                if not o.is_alive():
                    ready.append(o)
        if ready:
            return ready
        if deadline is not None and time.monotonic() >= deadline:
            return []
        time.sleep(0.005)
