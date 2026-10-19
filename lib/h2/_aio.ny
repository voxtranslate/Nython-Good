# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/_aio.ny - what h2.client and h2.server share (round 86): an
# H2Connection driven over asyncio streams.
#
# One task reads: bytes -> H2Connection.receive_data -> events, dispatched to
# the streams; one task writes: it waits until a stream has data and the
# windows allow some, asks the scheduler which stream goes next (the server
# uses RFC 9218's PriorityScheduler, the client streams in order), sends at
# most one frame's worth (SETTINGS_MAX_FRAME_SIZE, both windows) per turn and
# drains the transport. A stream whose data waits for a WINDOW_UPDATE counts
# a "blocked" episode (Stream.blocked, Driver.blocked) - the tests watch flow
# control stop and resume with it. Consumed DATA is acknowledged as the
# application reads it, so a reader that does not read stops its peer.
import asyncio

import h2.connection
import h2.events
import h2.errors
import h2.exceptions
from h2.errors import ErrorCodes
from h2.priority import PriorityScheduler

HIGH_WATER = 65536       # a stream's unsent buffer above which write() waits


def code_name(code):
    try:
        return ErrorCodes(code).name
    except ValueError:
        return str(code)


class StreamResetError(ConnectionError):
    """The stream was reset (RST_STREAM): error_code says why; remote: by the peer."""
    def __init__(self, stream_id, error_code, remote=True):
        self.stream_id = stream_id
        self.error_code = error_code
        self.remote = remote
        ConnectionError.__init__(self, "stream %d reset%s: %s" % (stream_id, " by the peer" if remote else "", code_name(error_code)))


class ConnectionClosedError(ConnectionError):
    """The HTTP/2 connection is closed (GOAWAY, a protocol error, or EOF)."""
    def __init__(self, msg, error_code=None, last_stream_id=None):
        ConnectionError.__init__(self, msg)
        self.error_code = error_code
        self.last_stream_id = last_stream_id


def _str_headers(headers):
    out = []
    for h in headers:
        n = h[0]
        v = h[1]
        if isinstance(n, bytes):
            n = n.decode("utf-8", "replace")
        if isinstance(v, bytes):
            v = v.decode("utf-8", "replace")
        out.append((n, v))
    return out


def header(headers, name, default=None):
    name = name.lower()
    for h in headers:
        if h[0] == name:
            return h[1]
    return default


class Stream:
    """One stream seen from the application: its headers, a queue of
    received chunks, and an outbound buffer the writer task drains."""
    def __init__(self, driver, stream_id):
        self.driver = driver
        self.stream_id = stream_id
        self.headers = None
        self.trailers = None
        self.informational = []
        self.priority = (3, False)
        self._headers_ready = asyncio.Event()
        self._chunks = []
        self._readable = asyncio.Event()
        self.ended = False            # the peer's END_STREAM
        self.reset_code = None
        self.reset_remote = True
        self._out = bytearray()
        self._out_end = False
        self._out_trailers = None
        self._out_closed = False      # END_STREAM sent
        self._room = asyncio.Event()
        self._room.set()
        self._sent_all = asyncio.Event()
        self.blocked = 0
        self._was_blocked = False
        self.bytes_received = 0
        self.bytes_sent = 0

    # receiving
    def _push(self, data, flow_len):
        self._chunks.append((data, flow_len))
        self.bytes_received += len(data)
        self._readable.set()

    def _end(self):
        self.ended = True
        self._readable.set()
        self._headers_ready.set()

    def _reset(self, code, remote):
        self.reset_code = code
        self.reset_remote = remote
        self._readable.set()
        self._headers_ready.set()
        self._room.set()
        self._sent_all.set()

    def _check_reset(self):
        if self.reset_code is not None:
            raise StreamResetError(self.stream_id, self.reset_code, self.reset_remote)

    async def read_chunk(self):
        """The next chunk of the body (b"" at its end); StreamResetError if reset."""
        while not self._chunks:
            if self.reset_code is not None:
                self._check_reset()
            if self.ended:
                return b""
            if self.driver.closed_error is not None:
                raise self.driver.closed_error
            self._readable.clear()
            await self._readable.wait()
        data, n = self._chunks.pop(0)
        self.driver._consumed(self.stream_id, n)
        return data

    async def read(self):
        """The whole (rest of the) body."""
        parts = []
        while True:
            c = await self.read_chunk()
            if not c:
                return b"".join(parts)
            parts.append(c)

    def __aiter__(self):
        return self

    async def __anext__(self):
        c = await self.read_chunk()
        if not c:
            raise StopAsyncIteration
        return c

    # sending
    async def write(self, data):
        """Queue body data; waits while more than HIGH_WATER octets are unsent
        (the peer's flow control pushes back here)."""
        self._check_reset()
        if self._out_end:
            raise RuntimeError("write() after end()")
        if isinstance(data, str):
            data = data.encode("utf-8")
        self._out += data
        self._sent_all.clear()
        self.driver._wake()
        while len(self._out) > HIGH_WATER and self.reset_code is None:
            self._room.clear()
            await self._room.wait()
        self._check_reset()

    def end(self, trailers=None):
        """End the body (with trailers, a final field block)."""
        if self._out_end:
            return
        self._out_end = True
        self._out_trailers = trailers
        self._sent_all.clear()
        self.driver._wake()

    async def drained(self):
        """Wait until everything queued (and the end) has been sent."""
        while not self._sent_all.is_set():
            await self._sent_all.wait()
        self._check_reset()

    def reset(self, error_code=ErrorCodes.CANCEL):
        """Reset the stream (RST_STREAM)."""
        if self.reset_code is not None or self._out_closed and self.ended:
            return
        try:
            self.driver.conn.reset_stream(self.stream_id, error_code)
        except h2.exceptions.ProtocolError:
            pass
        self._reset(error_code, False)
        self.driver._flush()
        self.driver._forget(self.stream_id)

    def _pending(self):
        return len(self._out) > 0 or (self._out_end and not self._out_closed)


class Driver:
    """The read and write loops of one connection."""
    def __init__(self, conn, reader, writer, scheduler=None):
        self.conn = conn
        self.reader = reader
        self.writer = writer
        self.streams = {}
        self.scheduler = scheduler
        self.closed_error = None
        self.blocked = 0
        self.frame_log = None          # [(stream id, octets)] of DATA, when recording
        self.sent_log = None
        self.terminated = None         # the ConnectionTerminated event received
        self._wake_ev = asyncio.Event()
        self._closed = asyncio.Event()
        self._tasks = []
        self._ping_waiters = {}

    def start(self):
        self._tasks.append(asyncio.ensure_future(self._read_loop()))
        self._tasks.append(asyncio.ensure_future(self._write_loop()))

    def _flush(self):
        data = self.conn.data_to_send()
        if data and not self.writer.is_closing():
            self.writer.write(data)

    def _wake(self):
        self._wake_ev.set()

    def _consumed(self, stream_id, n):
        if n and self.closed_error is None:
            self.conn.acknowledge_received_data(n, stream_id)
            self._flush()

    def _forget(self, stream_id):
        self.streams.pop(stream_id, None)
        if self.scheduler is not None:
            self.scheduler.remove(stream_id)

    def _fail_all(self, err):
        if self.closed_error is None:
            self.closed_error = err
        for s in list(self.streams.values()):
            if s.reset_code is None and not (s.ended and s._out_closed):
                s._readable.set()
                s._headers_ready.set()
                s._room.set()
                s._sent_all.set()
        self._closed.set()
        self._wake()

    async def _read_loop(self):
        err = None
        try:
            while True:
                data = await self.reader.read(65536)
                if not data:
                    err = ConnectionClosedError("the connection was closed by the peer")
                    break
                try:
                    events = self.conn.receive_data(data)
                except h2.exceptions.ProtocolError as e:
                    self._flush()
                    err = ConnectionClosedError("protocol error: %s" % e, e.error_code)
                    break
                for ev in events:
                    self._event(ev)
                self._flush()
                self._wake()
        except (ConnectionError, OSError) as e:
            err = ConnectionClosedError("connection lost: %s" % e)
        except asyncio.CancelledError:
            err = ConnectionClosedError("the connection was closed")
        if self.terminated is not None and not isinstance(err, ConnectionClosedError):
            pass
        self._fail_all(err or ConnectionClosedError("the connection was closed"))
        try:
            await self.drain()
        except Exception:
            pass
        try:
            self.writer.close()
        except Exception:
            pass

    async def drain(self):
        if not self.writer.is_closing():
            await self.writer.drain()

    def _event(self, ev):
        s = self.streams.get(getattr(ev, "stream_id", None) or -1)
        if isinstance(ev, h2.events.DataReceived):
            if self.frame_log is not None:
                self.frame_log.append((ev.stream_id, len(ev.data)))
            if s is None:
                self.conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
            else:
                s._push(ev.data, ev.flow_controlled_length)
        elif isinstance(ev, h2.events.StreamEnded):
            if s is not None:
                s._end()
                self._maybe_done(s)
        elif isinstance(ev, h2.events.StreamReset):
            if s is not None:
                s._reset(ev.error_code, ev.remote_reset)
                self._forget(ev.stream_id)
                self.on_reset(s)
        elif isinstance(ev, (h2.events.WindowUpdated, h2.events.RemoteSettingsChanged)):
            self._wake()
        elif isinstance(ev, h2.events.PingAckReceived):
            w = self._ping_waiters.pop(ev.ping_data, None)
            if w is not None and not w.done():
                w.set_result(asyncio.get_running_loop().time())
        elif isinstance(ev, h2.events.ConnectionTerminated):
            self.terminated = ev
            self.on_goaway(ev)
        elif isinstance(ev, h2.events.PriorityUpdateReceived):
            if self.scheduler is not None and ev.stream_id in self.scheduler:
                self.scheduler.update(ev.stream_id, ev.urgency, ev.incremental)
            if s is not None:
                s.priority = (ev.urgency, ev.incremental)
        else:
            self.on_event(ev, s)

    # hooks for the two sides
    def on_event(self, ev, stream):
        pass

    def on_reset(self, stream):
        pass

    def on_goaway(self, ev):
        pass

    def _maybe_done(self, s):
        if s.ended and s._out_closed:
            self._forget(s.stream_id)

    def _ready_streams(self):
        ready = []
        window = self.conn.outbound_flow_control_window
        for sid in self.streams:
            s = self.streams[sid]
            if s.reset_code is not None or not s._pending():
                continue
            if not s._out:
                ready.append(sid)           # only the end (or trailers) to send
                continue
            try:
                w = self.conn.local_flow_control_window(sid)
            except h2.exceptions.ProtocolError:
                continue
            if w > 0:
                ready.append(sid)
            elif not s._was_blocked:
                s._was_blocked = True
                s.blocked += 1
                self.blocked += 1
        return ready

    def _send_one(self, sid):
        s = self.streams[sid]
        conn = self.conn
        if s._out:
            n = min(len(s._out), conn.local_flow_control_window(sid), conn.max_outbound_frame_size)
            if n <= 0:
                return False
            chunk = bytes(s._out[:n])
            del s._out[:n]
            end = s._out_end and not s._out and s._out_trailers is None
            conn.send_data(sid, chunk, end_stream=end)
            s.bytes_sent += n
            s._was_blocked = False
            if self.sent_log is not None:
                self.sent_log.append((sid, n))
            if end:
                s._out_closed = True
            if len(s._out) <= HIGH_WATER:
                s._room.set()
        elif s._out_end and not s._out_closed:
            if s._out_trailers is not None:
                conn.send_headers(sid, s._out_trailers, end_stream=True)
            else:
                conn.end_stream(sid)
            s._out_closed = True
        if not s._pending():
            s._sent_all.set()
            self._maybe_done(s)
        return True

    def _pick(self, ready):
        if self.scheduler is not None:
            return self.scheduler.next(ready)
        return min(ready)

    async def _write_loop(self):
        try:
            while self.closed_error is None:
                ready = self._ready_streams()
                if not ready:
                    self._flush()
                    await self.drain()
                    self._wake_ev.clear()
                    if self._ready_streams():
                        continue
                    await self._wake_ev.wait()
                    continue
                sid = self._pick(ready)
                try:
                    self._send_one(sid)
                except h2.exceptions.ProtocolError:
                    s = self.streams.get(sid)
                    if s is not None:
                        s._reset(ErrorCodes.STREAM_CLOSED, False)
                        self._forget(sid)
                self._flush()
                await self.drain()
        except (ConnectionError, OSError) as e:
            self._fail_all(ConnectionClosedError("connection lost: %s" % e))
        except asyncio.CancelledError:
            pass

    async def ping(self, data=None):
        """Round-trip time of a PING, in seconds."""
        import os
        if data is None:
            data = os.urandom(8)
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._ping_waiters[data] = fut
        t0 = loop.time()
        self.conn.ping(data)
        self._flush()
        t1 = await fut
        return t1 - t0

    async def aclose(self, error_code=0):
        if self.closed_error is None:
            try:
                self.conn.close_connection(error_code)
            except h2.exceptions.ProtocolError:
                pass
            self._flush()
            try:
                await self.drain()
            except (ConnectionError, OSError):
                pass
        self._fail_all(ConnectionClosedError("the connection was closed"))
        try:
            self.writer.close()
        except Exception:
            pass
        for t in self._tasks:
            if not t.done():
                t.cancel()
        for t in self._tasks:
            try:
                await t
            except BaseException:
                pass
