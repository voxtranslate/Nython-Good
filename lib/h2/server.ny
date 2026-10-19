# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/server.ny - an asyncio HTTP/2 server over h2.connection (round 86).
#
#     import asyncio, h2.server
#     async def handler(req):
#         body = await req.read()
#         return h2.server.Response(200, [("content-type", "text/plain")], b"hi " + body)
#     async def main():
#         async with await h2.server.serve(handler, "127.0.0.1", 8443, ssl=ctx) as srv:
#             await srv.serve_forever()
#
# serve(handler, host=None, port=0, ssl=None, settings=None, record=False,
#       max_concurrent_streams=100) -> Server (listening). With ssl, the
#       context is given ALPN ["h2"] and a connection that negotiates
#       anything else is closed; without, connections speak h2c with prior
#       knowledge. Each request stream runs handler(request) as a task of its
#       own, so streams are served concurrently; the handler returns a
#       Response (body: bytes, str or an async iterator of chunks) or None
#       after answering itself:
# Request: method, path, scheme, authority, protocol, headers (list of (str,
#       str)), stream_id, priority ((urgency, incremental), RFC 9218 - the
#       Priority header or PRIORITY_UPDATE), read() / read_chunk() / async
#       for, trailers; send_response(status, headers=(), end_stream=False),
#       write(data) (waits under the client's flow control), end(trailers=None),
#       reset(error_code); the client resetting the stream cancels the task.
# A handler that raises gets a 500 if it had not answered yet, else its
#       stream is reset with INTERNAL_ERROR.
# Server: port, sockets, connections, close() - graceful (RFC 9113 6.8: a
#       GOAWAY with 2^31-1 and a PING, then once the PING returns the real
#       last stream id; the streams below it finish) - wait_closed(),
#       serve_forever(), async with.
# Scheduling: the bytes of competing responses are sent in RFC 9218 order
#       by h2.priority.PriorityScheduler (urgency first; non-incremental in
#       request order, incremental round robin; see h2.priority). The server
#       announces SETTINGS_NO_RFC7540_PRIORITIES. record=True keeps each
#       connection's DATA frames as sent (Connection.sent_log: (stream id,
#       octets)) to watch it.
import asyncio
import os

import h2.config
import h2.connection
import h2.events
from h2.errors import ErrorCodes
from h2.settings import SettingCodes
from h2.priority import PriorityScheduler
from h2 import _aio
from h2._aio import StreamResetError, ConnectionClosedError, header

__all__ = ["serve", "Server", "Request", "Response", "StreamResetError", "ConnectionClosedError"]


class Response:
    def __init__(self, status=200, headers=(), body=b"", trailers=None):
        self.status = status
        self.headers = list(headers)
        self.body = body
        self.trailers = trailers


class Request(_aio.Stream):
    """A request stream as a handler sees it."""
    def __init__(self, driver, stream_id):
        _aio.Stream.__init__(self, driver, stream_id)
        self.method = None
        self.path = None
        self.scheme = None
        self.authority = None
        self.protocol = None
        self.responded = False
        self.task = None

    def _set_headers(self, headers):
        self.headers = [h for h in headers if not h[0].startswith(":")]
        self.raw_headers = headers
        self.method = header(headers, ":method")
        self.path = header(headers, ":path")
        self.scheme = header(headers, ":scheme")
        self.authority = header(headers, ":authority")
        self.protocol = header(headers, ":protocol")

    def header(self, name, default=None):
        return header(self.headers, name, default)

    async def send_response(self, status, headers=(), end_stream=False):
        """Send the response's field block (a 1xx may come first)."""
        self._check_reset()
        fields = [(":status", str(status))]
        for h in headers:
            fields.append((h[0].lower(), str(h[1])))
        st = int(status)
        self.driver.conn.send_headers(self.stream_id, fields, end_stream=end_stream)
        if st >= 200:
            self.responded = True
        if end_stream:
            self._out_end = True
            self._out_closed = True
            self._sent_all.set()
            self.driver._maybe_done(self)
        self.driver._flush()


class Connection(_aio.Driver):
    def __init__(self, server, conn, reader, writer):
        _aio.Driver.__init__(self, conn, reader, writer, PriorityScheduler())
        self.server = server
        self.handler_tasks = set()
        self.peer = writer.get_extra_info("peername")
        self.alpn = None
        if server.record:
            self.sent_log = []

    def on_event(self, ev, s):
        if isinstance(ev, h2.events.RequestReceived):
            req = Request(self, ev.stream_id)
            req._set_headers(_aio._str_headers(ev.headers))
            req.priority = ev.priority
            self.streams[ev.stream_id] = req
            self.scheduler.add(ev.stream_id, ev.priority[0], ev.priority[1])
            if ev.stream_ended is not None:
                req._end()
            t = asyncio.ensure_future(self._run(req))
            req.task = t
            self.handler_tasks.add(t)
            t.add_done_callback(self.handler_tasks.discard)
        elif isinstance(ev, h2.events.TrailersReceived):
            if s is not None:
                s.trailers = _aio._str_headers(ev.headers)

    def on_reset(self, s):
        t = getattr(s, "task", None)
        if t is not None and not t.done():
            t.cancel()

    async def _run(self, req):
        server = self.server
        server.requests += 1
        try:
            result = await server.handler(req)
            if result is not None and req.reset_code is None:
                await self._send_result(req, result)
            elif not req.responded and req.reset_code is None:
                await req.send_response(204, (), end_stream=True)
            elif req.reset_code is None and not req._out_end:
                req.end()
            if req.reset_code is None:
                await req.drained()
        except asyncio.CancelledError:
            pass
        except StreamResetError:
            pass
        except ConnectionClosedError:
            pass
        except Exception as e:
            server.errors.append(e)
            if req.reset_code is None and self.closed_error is None:
                try:
                    if not req.responded:
                        body = b"Internal Server Error\n"
                        await req.send_response(500, [("content-type", "text/plain"), ("content-length", str(len(body)))])
                        await req.write(body)
                        req.end()
                    else:
                        req.reset(ErrorCodes.INTERNAL_ERROR)
                except Exception:
                    pass

    async def _send_result(self, req, r):
        body = r.body
        if isinstance(body, str):
            body = body.encode("utf-8")
        headers = list(r.headers)
        if isinstance(body, (bytes, bytearray)):
            if not any(h[0].lower() == "content-length" for h in headers) and r.status not in (204, 304):
                headers.append(("content-length", str(len(body))))
            if not body and r.trailers is None:
                await req.send_response(r.status, headers, end_stream=True)
                return
            await req.send_response(r.status, headers)
            if body:
                await req.write(bytes(body))
        else:
            await req.send_response(r.status, headers)
            async for chunk in body:
                await req.write(chunk)
        req.end(r.trailers)

    def _maybe_done(self, s):
        _aio.Driver._maybe_done(self, s)
        if self.server._closing and not self.streams:
            self._wake()


class Server:
    def __init__(self, handler, ssl=None, settings=None, record=False, max_concurrent_streams=100):
        self.handler = handler
        self.ssl = ssl
        self.settings = settings or {}
        self.record = record
        self.max_concurrent_streams = max_concurrent_streams
        self.connections = []
        self.requests = 0
        self.errors = []
        self._server = None
        self._closing = False
        self._closed = asyncio.Event()

    async def _start(self, host, port):
        if self.ssl is not None:
            self.ssl.set_alpn_protocols(["h2"])
            self._server = await asyncio.start_server(self._client, host, port, ssl=self.ssl)
        else:
            self._server = await asyncio.start_server(self._client, host, port)
        return self

    @property
    def sockets(self):
        return self._server.sockets

    @property
    def port(self):
        return self._server.sockets[0].getsockname()[1]

    async def _client(self, reader, writer):
        alpn = None
        if self.ssl is not None:
            so = writer.get_extra_info("ssl_object")
            alpn = so.selected_alpn_protocol() if so is not None else None
            if alpn is not None and alpn != "h2":
                writer.close()
                return
        if self._closing:
            writer.close()
            return
        conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=False, header_encoding="utf-8"))
        conn.local_settings[SettingCodes.MAX_CONCURRENT_STREAMS] = self.max_concurrent_streams
        conn.local_settings[SettingCodes.NO_RFC7540_PRIORITIES] = 1
        for k in self.settings:
            conn.local_settings[k] = self.settings[k]
        conn.local_settings.acknowledge()
        conn.initiate_connection()
        c = Connection(self, conn, reader, writer)
        c.alpn = alpn
        self.connections.append(c)
        c._flush()
        c.start()
        try:
            await c._closed.wait()
        finally:
            for t in list(c.handler_tasks):
                t.cancel()
            if c in self.connections:
                self.connections.remove(c)
            try:
                writer.close()
            except Exception:
                pass

    async def _graceful(self, c, timeout):
        # RFC 9113 6.8: GOAWAY(2^31-1) + PING, then the real GOAWAY after a round trip
        if c.closed_error is not None:
            return
        try:
            c.conn.close_connection(0, last_stream_id=2 ** 31 - 1)
            c._flush()
            try:
                await asyncio.wait_for(c.ping(), timeout)
            except (asyncio.TimeoutError, ConnectionError, OSError):
                pass
            c.conn.close_connection(0)
            c._flush()
            loop = asyncio.get_running_loop()
            deadline = loop.time() + timeout
            while c.streams and c.closed_error is None and loop.time() < deadline:
                c._wake_ev.clear()
                try:
                    await asyncio.wait_for(c._closed.wait(), 0.05)
                except asyncio.TimeoutError:
                    pass
        except Exception:
            pass
        await c.aclose(0)

    async def close(self, timeout=5.0):
        """Stop accepting; GOAWAY every connection and let their streams finish."""
        self._closing = True
        if self._server is not None:
            self._server.close()
        await asyncio.gather(*[self._graceful(c, timeout) for c in list(self.connections)])
        self._closed.set()

    async def wait_closed(self):
        await self._closed.wait()
        if self._server is not None:
            try:
                await self._server.wait_closed()
            except Exception:
                pass

    async def serve_forever(self):
        await self._closed.wait()

    async def __aenter__(self):
        return self

    async def __aexit__(self, a, b, c):
        await self.close()
        await self.wait_closed()
        return False


async def serve(handler, host=None, port=0, ssl=None, settings=None, record=False, max_concurrent_streams=100):
    """A Server listening on host:port (see the module header)."""
    srv = Server(handler, ssl=ssl, settings=settings, record=record, max_concurrent_streams=max_concurrent_streams)
    return await srv._start(host or "127.0.0.1", port)
