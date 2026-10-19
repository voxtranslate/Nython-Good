# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/connection.ny - the HTTP/2 connection state machine (RFC 9113;
# round 86), sans I/O, with the h2 package's API.
#
#     import h2.connection, h2.config, h2.events
#     conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True))
#     conn.initiate_connection()
#     sock.sendall(conn.data_to_send())
#     sid = conn.get_next_available_stream_id()
#     conn.send_headers(sid, [(":method", "GET"), (":path", "/"),
#                             (":scheme", "https"), (":authority", "example.org")], end_stream=True)
#     sock.sendall(conn.data_to_send())
#     for event in conn.receive_data(sock.recv(65535)):
#         if isinstance(event, h2.events.DataReceived):
#             conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
#
# Methods: initiate_connection, initiate_upgrade_connection,
# get_next_available_stream_id, send_headers (HEADERS + CONTINUATION, RFC 7540
# priority fields, trailers), send_data (padding), end_stream,
# increment_flow_control_window, push_stream (server), ping, reset_stream,
# close_connection (GOAWAY), update_settings, advertise_alternative_service,
# prioritize, local_flow_control_window / remote_flow_control_window,
# acknowledge_received_data (WINDOW_UPDATE once half a window has been
# consumed), data_to_send, clear_outbound_data_buffer, receive_data -> events;
# Nython's send_priority_update (RFC 9218, client) and stream_priority.
#
# What is enforced, as RFC 9113 says (connection errors raise from
# receive_data after queueing GOAWAY - ProtocolError and its subclasses carry
# the error code; stream errors queue RST_STREAM and report StreamReset with
# remote_reset False):
#   - the preface (the client's magic, then SETTINGS first from both sides);
#     frame sizes against SETTINGS_MAX_FRAME_SIZE (FRAME_SIZE_ERROR); field
#     blocks continued only by CONTINUATION on the same stream, bounded (the
#     2024 "CONTINUATION flood": ENHANCE_YOUR_CALM past 4x the header list
#     limit); HPACK errors are COMPRESSION_ERROR;
#   - stream states (5.1): identifiers odd from clients and even from servers,
#     increasing (a lower one is PROTOCOL_ERROR), frames on idle streams,
#     STREAM_CLOSED for DATA/HEADERS after END_STREAM, frames on streams we
#     reset ignored (DATA still counted against the connection window),
#     SETTINGS_MAX_CONCURRENT_STREAMS (REFUSED_STREAM);
#   - flow control (5.2, 6.9): both windows for DATA (padding included),
#     WINDOW_UPDATE overflow (FLOW_CONTROL_ERROR) and zero increments
#     (PROTOCOL_ERROR, stream or connection), SETTINGS_INITIAL_WINDOW_SIZE
#     changes applied to every open stream (windows may go negative);
#   - SETTINGS: values checked (6.5.2), ACKed automatically, ours applied
#     when the peer ACKs them (HEADER_TABLE_SIZE, MAX_HEADER_LIST_SIZE,
#     INITIAL_WINDOW_SIZE, MAX_FRAME_SIZE); a server's ENABLE_PUSH=1 is an
#     error;
#   - fields (8.2, 8.3; h2.utilities): a malformed request or response is a
#     stream error PROTOCOL_ERROR, and so is a body whose length differs from
#     content-length; trailers must end the stream; 1xx before the final
#     response;
#   - PUSH_PROMISE: the client announces SETTINGS_ENABLE_PUSH=0, so a push is
#     PROTOCOL_ERROR; if the application enabled push, the promised stream is
#     refused (RST_STREAM CANCEL) and reported (PushedStreamReceived);
#   - GOAWAY: no new streams after one either way; on receipt, the streams
#     we opened above last_stream_id were not processed and are reported as
#     StreamReset(REFUSED_STREAM) - safe to retry; after sending a graceful
#     one (NO_ERROR) the streams below it finish normally;
#   - PING is answered; PRIORITY frames are parsed and reported
#     (PriorityUpdated) but do not schedule anything (RFC 9113 5.3.2);
#     RFC 9218's PRIORITY_UPDATE (server side: buffered for a stream not yet
#     open, PROTOCOL_ERROR on a client) and the Priority request header give
#     RequestReceived.priority / stream_priority().
#
# Not here: the h2c upgrade's HTTP/1.1 side (initiate_upgrade_connection does
# the HTTP/2 part); RFC 7540 priority-based scheduling; inbound header
# validation cannot be turned into a connection error as the h2 package does
# for some cases (they are stream errors, as RFC 9113 8.1.1 says).
import base64
import enum

import hpack

from h2 import utilities
from h2.config import H2Configuration
from h2.errors import ErrorCodes, _error_code_from_int
from h2.events import (
    RequestReceived, ResponseReceived, TrailersReceived, InformationalResponseReceived,
    DataReceived, WindowUpdated, RemoteSettingsChanged, PingReceived, PingAckReceived,
    StreamEnded, StreamReset, PushedStreamReceived, SettingsAcknowledged, PriorityUpdated,
    PriorityUpdateReceived, ConnectionTerminated, AlternativeServiceAvailable, UnknownFrameReceived)
from h2.exceptions import (
    ProtocolError, FrameTooLargeError, FrameDataMissingError, TooManyStreamsError, FlowControlError,
    StreamIDTooLowError, NoAvailableStreamIDError, NoSuchStreamError, StreamClosedError,
    DenialOfServiceError, InvalidSettingsValueError)
from h2.frame import (
    Frame, DataFrame, HeadersFrame, PriorityFrame, RstStreamFrame, SettingsFrame, PushPromiseFrame,
    PingFrame, GoAwayFrame, WindowUpdateFrame, ContinuationFrame, AltSvcFrame, PriorityUpdateFrame,
    ExtensionFrame, InvalidFrameError, InvalidPaddingError, InvalidDataError)
from h2.settings import Settings, SettingCodes, _validate_setting
from h2.stream import H2Stream, StreamState, StreamClosedBy
from h2.priority import parse_priority, serialize_priority


class ConnectionState(enum.Enum):
    IDLE = 0
    CLIENT_OPEN = 1
    SERVER_OPEN = 2
    CLOSED = 3


PREAMBLE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
_MAX_WINDOW = 2 ** 31 - 1
_MAX_STREAM_ID = 2 ** 31 - 1


class _Terminate(Exception):
    # a connection error found while handling a frame (internal)
    def __init__(self, exc):
        Exception.__init__(self, str(exc))
        self.exc = exc


class H2Connection:
    """One HTTP/2 connection, either side (see the module header)."""
    DEFAULT_MAX_OUTBOUND_FRAME_SIZE = 65535
    DEFAULT_MAX_INBOUND_FRAME_SIZE = 2 ** 24
    DEFAULT_MAX_HEADER_LIST_SIZE = 2 ** 16
    MAX_CLOSED_STREAMS = 2 ** 16

    def __init__(self, config=None):
        if config is None:
            config = H2Configuration(client_side=True)
        self.config = config
        client = config.client_side
        self.encoder = hpack.Encoder()
        self.decoder = hpack.Decoder()
        self.decoder.max_header_list_size = self.DEFAULT_MAX_HEADER_LIST_SIZE
        initial = {SettingCodes.MAX_CONCURRENT_STREAMS: 100,
                   SettingCodes.MAX_HEADER_LIST_SIZE: self.DEFAULT_MAX_HEADER_LIST_SIZE}
        if client:
            initial[SettingCodes.ENABLE_PUSH] = 0      # the client refuses push
        self.local_settings = Settings(client=client, initial_values=initial)
        self.remote_settings = Settings(client=not client)
        self.state_machine = ConnectionState.IDLE
        self.streams = {}
        self._closed_streams = {}
        self.highest_inbound_stream_id = 0
        self.highest_outbound_stream_id = 0
        self.outbound_flow_control_window = self.remote_settings.initial_window_size
        self._inbound_window = 65535
        self._inbound_max = 65535
        self._inbound_processed = 0
        self._data_to_send = bytearray()
        self.incoming_buffer = bytearray()
        self._preamble_seen = client
        self._first_frame = True
        self._header_block = None        # [frame type, stream id, end_stream, fragments, size, frame]
        self._goaway_sent = None         # last stream id we told the peer
        self._goaway_received = None
        self._terminated = None          # the connection error, once one happened
        self._pending_priority = {}      # RFC 9218 updates for streams not yet open
        self._dead_inbound = set()       # inbound streams refused after our GOAWAY

    # ── properties ─────────────────────────────────────────────────────────

    @property
    def open_outbound_streams(self):
        return self._open_count(True)

    @property
    def open_inbound_streams(self):
        return self._open_count(False)

    def _open_count(self, outbound):
        n = 0
        for s in self.streams.values():
            if s.locally_initiated == outbound and s.open:
                n += 1
        return n

    @property
    def inbound_flow_control_window(self):
        return self._inbound_window

    @property
    def max_outbound_frame_size(self):
        return self.remote_settings.max_frame_size

    @property
    def max_inbound_frame_size(self):
        return self.local_settings.max_frame_size

    @property
    def header_encoding(self):
        return self.config.header_encoding

    # ── setting up ─────────────────────────────────────────────────────────

    def _check_alive(self):
        if self._terminated is not None or self.state_machine == ConnectionState.CLOSED:
            raise ProtocolError("Invalid input in state ConnectionState.CLOSED: the connection is closed")

    def _open_state(self):
        if self.state_machine == ConnectionState.IDLE:
            self.state_machine = ConnectionState.CLIENT_OPEN if self.config.client_side else ConnectionState.SERVER_OPEN

    def initiate_connection(self):
        """Queue the connection preface: the client magic (client side) and
        a SETTINGS frame with every local setting."""
        self._check_alive()
        self._open_state()
        f = SettingsFrame(0)
        for setting, value in self.local_settings.items():
            f.settings[setting] = value
        if self.config.client_side:
            self._data_to_send += PREAMBLE
        self._data_to_send += f.serialize()

    def initiate_upgrade_connection(self, settings_header=None):
        """The HTTP/2 side of an h2c upgrade (RFC 7540 3.2): on a client, returns
        the HTTP2-Settings header value and makes stream 1 half-closed (local);
        on a server, applies the client's settings_header and makes stream 1
        half-closed (remote)."""
        frame_data = None
        self._open_state()
        if self.config.client_side:
            f = SettingsFrame(0)
            for setting, value in self.local_settings.items():
                f.settings[setting] = value
            frame_data = f.serialize_body()
            frame_data = base64.urlsafe_b64encode(frame_data)
            self._data_to_send += PREAMBLE + f.serialize()
            s = self._new_stream(1, True)
            s.state = StreamState.HALF_CLOSED_LOCAL
            self.highest_outbound_stream_id = 1
        else:
            if settings_header:
                data = base64.urlsafe_b64decode(settings_header + b"=" * (-len(settings_header) % 4))
                f = SettingsFrame(0)
                f.parse_body(memoryview(data))
                self._apply_remote_settings(f.settings)
            self.initiate_connection()
            s = self._new_stream(1, False)
            s.state = StreamState.HALF_CLOSED_REMOTE
            self.highest_inbound_stream_id = 1
        return frame_data

    def _new_stream(self, stream_id, local):
        s = H2Stream(stream_id, self.remote_settings.initial_window_size, self.local_settings.initial_window_size)
        s.locally_initiated = local
        self.streams[stream_id] = s
        return s

    def get_next_available_stream_id(self):
        """The next stream id this side can open (odd on a client, even on a
        server); NoAvailableStreamIDError once they are exhausted."""
        if self.highest_outbound_stream_id == 0:
            nxt = 1 if self.config.client_side else 2
        else:
            nxt = self.highest_outbound_stream_id + 2
        if nxt > _MAX_STREAM_ID:
            raise NoAvailableStreamIDError("Exhausted allowed stream IDs")
        return nxt

    # ── sending ────────────────────────────────────────────────────────────

    def _encode_headers(self, headers, kind, stream):
        enc = self.config.header_encoding or "utf-8"
        if self.config.normalize_outbound_headers:
            out = utilities.normalize_outbound(headers, self.config.split_outbound_cookies)
        else:
            out = []
            for h in headers:
                n = utilities.to_bytes(h[0], enc)
                v = utilities.to_bytes(h[1], enc)
                if isinstance(h, hpack.NeverIndexedHeaderTuple) or (not isinstance(h, hpack.HeaderTuple) and len(h) > 2 and h[2]):
                    out.append(hpack.NeverIndexedHeaderTuple(n, v))
                else:
                    out.append((n, v))
        if self.config.validate_outbound_headers:
            utilities.validate_headers(out, kind, self.remote_settings.enable_connect_protocol == 1)
        return out

    def _queue_field_block(self, first_frame, block):
        # first_frame: a HeadersFrame or PushPromiseFrame without its data;
        # the block is split by the peer's SETTINGS_MAX_FRAME_SIZE
        limit = self.max_outbound_frame_size
        overhead = 0
        if isinstance(first_frame, PushPromiseFrame):
            overhead = 4
        elif "PRIORITY" in first_frame.flags:
            overhead = 5
        first_len = max(0, limit - overhead)
        first_frame.data = block[:first_len]
        rest = block[first_len:]
        if not rest:
            first_frame.flags.add("END_HEADERS")
            self._data_to_send += first_frame.serialize()
            return
        self._data_to_send += first_frame.serialize()
        while rest:
            chunk = rest[:limit]
            rest = rest[limit:]
            c = ContinuationFrame(first_frame.stream_id, chunk)
            if not rest:
                c.flags.add("END_HEADERS")
            self._data_to_send += c.serialize()

    def send_headers(self, stream_id, headers, end_stream=False, priority_weight=None,
                     priority_depends_on=None, priority_exclusive=None):
        """Send a field block on a stream: a request (client; opens the
        stream), a response or a 1xx (server), or trailers (end_stream=True)."""
        self._check_alive()
        self._open_state()
        stream = self.streams.get(stream_id)
        if stream is None:
            if stream_id in self._closed_streams:
                raise StreamClosedError(stream_id)
            if not self.config.client_side:
                raise ProtocolError("A server can only open streams with push_stream()")
            if stream_id % 2 == 0:
                raise ProtocolError("Clients must use odd stream ids, got %d" % stream_id)
            if stream_id <= self.highest_outbound_stream_id:
                raise StreamIDTooLowError(stream_id, self.highest_outbound_stream_id)
            if self._goaway_received is not None:
                raise ProtocolError("Cannot open a new stream: the peer sent GOAWAY")
            if self.open_outbound_streams + 1 > self.remote_settings.max_concurrent_streams:
                raise TooManyStreamsError("Max outbound streams is %d, %d open" % (
                    self.remote_settings.max_concurrent_streams, self.open_outbound_streams))
            kind = "request"
        elif stream.state == StreamState.RESERVED_LOCAL:
            kind = "response"
        else:
            if not stream.can_send():
                raise StreamClosedError(stream_id)
            if stream.headers_sent or (self.config.client_side and stream.locally_initiated):
                kind = "trailers"
                if not end_stream:
                    raise ProtocolError("Trailers must have END_STREAM set")
            else:
                kind = "response"
        if kind == "response":
            st = None
            for h in headers:
                if utilities.to_bytes(h[0]) == b":status":
                    st = utilities.to_bytes(h[1])
            if st is not None and st[:1] == b"1":
                kind = "informational"
                if end_stream:
                    raise ProtocolError("A 1xx response cannot end the stream")
        fields = self._encode_headers(headers, kind, stream)
        if stream is None:
            # opened only once its field block is known to be valid
            stream = self._new_stream(stream_id, True)
            self.highest_outbound_stream_id = stream_id
        if kind == "request":
            stream.request_method = utilities.header_value(fields, b":method")
        block = self.encoder.encode(fields)
        f = HeadersFrame(stream_id)
        if end_stream:
            f.flags.add("END_STREAM")
        if priority_weight is not None or priority_depends_on is not None or priority_exclusive is not None:
            w = 16 if priority_weight is None else priority_weight
            if not (1 <= w <= 256):
                raise ValueError("Weight must be between 1 and 256, not %d" % w)
            dep = 0 if priority_depends_on is None else priority_depends_on
            if dep == stream_id:
                raise ProtocolError("Stream %d must not depend on itself." % stream_id)
            f.flags.add("PRIORITY")
            f.stream_weight = w - 1
            f.depends_on = dep
            f.exclusive = bool(priority_exclusive)
        self._queue_field_block(f, block)
        if stream.state == StreamState.IDLE:
            stream.state = StreamState.OPEN
        elif stream.state == StreamState.RESERVED_LOCAL:
            stream.state = StreamState.HALF_CLOSED_REMOTE
        if kind in ("response", "request"):
            stream.headers_sent = True
        if end_stream:
            self._sent_end_stream(stream)

    def _sent_end_stream(self, stream):
        stream.sent_end_stream()
        if stream.state == StreamState.CLOSED:
            self._forget(stream, StreamClosedBy.SEND_END_STREAM)

    def _forget(self, stream, closed_by):
        stream.state = StreamState.CLOSED
        stream.closed_by = closed_by
        self.streams.pop(stream.stream_id, None)
        self._closed_streams[stream.stream_id] = closed_by
        if len(self._closed_streams) > self.MAX_CLOSED_STREAMS:
            for k in list(self._closed_streams)[:len(self._closed_streams) // 2]:
                del self._closed_streams[k]

    def _stream_for_send(self, stream_id):
        stream = self.streams.get(stream_id)
        if stream is None:
            if stream_id in self._closed_streams:
                raise StreamClosedError(stream_id)
            raise NoSuchStreamError(stream_id)
        return stream

    def send_data(self, stream_id, data, end_stream=False, pad_length=None):
        """Send DATA: it must fit both flow-control windows
        (local_flow_control_window) and the peer's frame size."""
        self._check_alive()
        stream = self._stream_for_send(stream_id)
        if not stream.can_send():
            raise StreamClosedError(stream_id)
        if not stream.headers_sent:
            raise ProtocolError("Cannot send DATA before the field block on stream %d" % stream_id)
        frame_size = len(data)
        if pad_length is not None:
            if not isinstance(pad_length, int):
                raise TypeError("pad_length must be an int")
            if pad_length < 0 or pad_length > 255:
                raise ValueError("pad_length %d must be between 0 and 255" % pad_length)
            frame_size += pad_length + 1
        window = self.local_flow_control_window(stream_id)
        if frame_size > window:
            raise FlowControlError("Cannot send %d bytes, flow control window is %d." % (frame_size, window))
        if frame_size > self.max_outbound_frame_size:
            raise FrameTooLargeError("Cannot send frame size %d, max frame size is %d" % (frame_size, self.max_outbound_frame_size))
        f = DataFrame(stream_id, bytes(data))
        if pad_length is not None:
            f.flags.add("PADDED")
            f.pad_length = pad_length
        if end_stream:
            f.flags.add("END_STREAM")
        self._data_to_send += f.serialize()
        self.outbound_flow_control_window -= frame_size
        stream.outbound_flow_control_window -= frame_size
        if end_stream:
            self._sent_end_stream(stream)

    def end_stream(self, stream_id):
        """Half-close a stream with an empty DATA frame carrying END_STREAM."""
        self._check_alive()
        stream = self._stream_for_send(stream_id)
        if not stream.can_send():
            raise StreamClosedError(stream_id)
        f = DataFrame(stream_id, b"", flags=["END_STREAM"])
        self._data_to_send += f.serialize()
        self._sent_end_stream(stream)

    def increment_flow_control_window(self, increment, stream_id=None):
        """Widen one of our receive windows by increment (WINDOW_UPDATE)."""
        self._check_alive()
        if not (1 <= increment <= _MAX_WINDOW):
            raise ValueError("Flow control increment must be between 1 and %d" % _MAX_WINDOW)
        if stream_id is None or stream_id == 0:
            if self._inbound_window + increment > _MAX_WINDOW:
                raise FlowControlError("Flow control window too large")
            self._inbound_window += increment
            self._inbound_max = max(self._inbound_max, self._inbound_window)
            self._data_to_send += WindowUpdateFrame(0, increment).serialize()
        else:
            stream = self._stream_for_send(stream_id)
            if stream.inbound_window + increment > _MAX_WINDOW:
                raise FlowControlError("Flow control window too large")
            stream.inbound_window += increment
            stream.inbound_max = max(stream.inbound_max, stream.inbound_window)
            self._data_to_send += WindowUpdateFrame(stream_id, increment).serialize()

    def push_stream(self, stream_id, promised_stream_id, request_headers):
        """(server) Promise a pushed response on stream_id's behalf."""
        self._check_alive()
        if self.config.client_side:
            raise ProtocolError("Clients cannot push streams")
        if not self.remote_settings.enable_push:
            raise ProtocolError("Remote peer has disabled stream push")
        parent = self._stream_for_send(stream_id)
        if not parent.can_send():
            raise StreamClosedError(stream_id)
        if promised_stream_id % 2 or promised_stream_id <= self.highest_outbound_stream_id:
            raise ProtocolError("Invalid promised stream id %d" % promised_stream_id)
        fields = self._encode_headers(request_headers, "push", None)
        block = self.encoder.encode(fields)
        s = self._new_stream(promised_stream_id, True)
        s.state = StreamState.RESERVED_LOCAL
        s.request_method = utilities.header_value(fields, b":method")
        self.highest_outbound_stream_id = promised_stream_id
        f = PushPromiseFrame(stream_id, promised_stream_id)
        self._queue_field_block(f, block)

    def ping(self, opaque_data):
        """Send a PING with 8 octets of opaque data."""
        self._check_alive()
        if not isinstance(opaque_data, bytes) or len(opaque_data) != 8:
            raise ValueError("Invalid value for ping data: %r" % (opaque_data,))
        self._data_to_send += PingFrame(0, opaque_data).serialize()

    def reset_stream(self, stream_id, error_code=0):
        """Reset a stream (RST_STREAM)."""
        self._check_alive()
        stream = self._stream_for_send(stream_id)
        self._data_to_send += RstStreamFrame(stream_id, int(error_code)).serialize()
        self._forget(stream, StreamClosedBy.SEND_RST_STREAM)

    def close_connection(self, error_code=0, additional_data=None, last_stream_id=None):
        """Send GOAWAY. With NO_ERROR the streams up to last_stream_id (by
        default the highest the peer opened) may still finish; with an error
        the connection is over."""
        self._open_state()
        if last_stream_id is None:
            last_stream_id = self.highest_inbound_stream_id
        f = GoAwayFrame(0, last_stream_id=last_stream_id, error_code=int(error_code), additional_data=additional_data or b"")
        self._data_to_send += f.serialize()
        if self._goaway_sent is None or last_stream_id < self._goaway_sent:
            self._goaway_sent = last_stream_id
        if int(error_code) != 0:
            self.state_machine = ConnectionState.CLOSED

    def update_settings(self, new_settings):
        """Send new local settings; they apply when the peer acknowledges them."""
        self._check_alive()
        self._open_state()
        for k in new_settings:
            self.local_settings[k] = new_settings[k]
        f = SettingsFrame(0)
        for k in new_settings:
            f.settings[k] = new_settings[k]
        self._data_to_send += f.serialize()

    def advertise_alternative_service(self, field_value, origin=None, stream_id=None):
        """(server) Send an ALTSVC frame (RFC 7838)."""
        self._check_alive()
        if isinstance(field_value, str):
            field_value = field_value.encode("ascii")
        if (origin is None) == (stream_id is None):
            raise ValueError("Must provide exactly one of origin and stream_id")
        if self.config.client_side:
            raise ProtocolError("Clients cannot advertise alternative services")
        if origin is not None:
            if isinstance(origin, str):
                origin = origin.encode("ascii")
            f = AltSvcFrame(0, origin=origin, field=field_value)
        else:
            f = AltSvcFrame(stream_id, origin=b"", field=field_value)
        self._data_to_send += f.serialize()

    def prioritize(self, stream_id, weight=None, depends_on=None, exclusive=None):
        """Send an RFC 7540 PRIORITY frame (deprecated by RFC 9113, still valid)."""
        self._check_alive()
        w = 16 if weight is None else weight
        if not (1 <= w <= 256):
            raise ValueError("Weight must be between 1 and 256, not %d" % w)
        dep = 0 if depends_on is None else depends_on
        if dep == stream_id:
            raise ProtocolError("Stream %d must not depend on itself." % stream_id)
        f = PriorityFrame(stream_id, depends_on=dep, stream_weight=w - 1, exclusive=bool(exclusive))
        self._data_to_send += f.serialize()

    def send_priority_update(self, stream_id, urgency=3, incremental=False):
        """(Nython; client) Send an RFC 9218 PRIORITY_UPDATE for a stream."""
        self._check_alive()
        if not self.config.client_side:
            raise ProtocolError("Servers MUST NOT send PRIORITY_UPDATE frames")
        if not (0 <= urgency <= 7):
            raise ValueError("urgency must be between 0 and 7")
        value = serialize_priority(urgency, incremental).encode("ascii")
        self._data_to_send += PriorityUpdateFrame(0, stream_id, value).serialize()

    def stream_priority(self, stream_id):
        """(Nython) The RFC 9218 (urgency, incremental) of a stream."""
        s = self.streams.get(stream_id)
        if s is not None:
            return s.priority
        return self._pending_priority.get(stream_id, (3, False))

    def local_flow_control_window(self, stream_id):
        """How many octets we may send on stream_id now."""
        stream = self._stream_for_send(stream_id)
        return min(self.outbound_flow_control_window, stream.outbound_flow_control_window)

    def remote_flow_control_window(self, stream_id):
        """How many octets the peer may send us on stream_id now."""
        stream = self._stream_for_send(stream_id)
        return min(self._inbound_window, stream.inbound_window)

    def acknowledge_received_data(self, acknowledged_size, stream_id):
        """The application consumed acknowledged_size octets of DATA (the
        events' flow_controlled_length): WINDOW_UPDATEs follow once half of a
        window (or all of an exhausted one) has been consumed."""
        if acknowledged_size < 0:
            raise ValueError("Cannot acknowledge negative data")
        if self._terminated is not None:
            return
        self._inbound_processed += acknowledged_size
        inc = self._window_increment(self._inbound_window, self._inbound_max, self._inbound_processed)
        if inc:
            self._inbound_window += inc
            self._inbound_processed = 0
            self._data_to_send += WindowUpdateFrame(0, inc).serialize()
        stream = self.streams.get(stream_id)
        if stream is not None and stream.can_receive():
            stream.inbound_processed += acknowledged_size
            inc = self._window_increment(stream.inbound_window, stream.inbound_max, stream.inbound_processed)
            if inc:
                stream.inbound_window += inc
                stream.inbound_processed = 0
                self._data_to_send += WindowUpdateFrame(stream_id, inc).serialize()

    @staticmethod
    def _window_increment(window, max_window, processed):
        if processed <= 0:
            return 0
        room = max_window - window
        if room <= 0:
            return 0
        if (window <= 0 and processed > min(1024, max_window // 4)) or processed >= max_window // 2:
            return min(processed, room)
        return 0

    def data_to_send(self, amount=None):
        """What is queued for the peer (all of it, or up to amount octets)."""
        if amount is None:
            data = bytes(self._data_to_send)
            self._data_to_send = bytearray()
            return data
        data = bytes(self._data_to_send[:amount])
        self._data_to_send = self._data_to_send[amount:]
        return data

    def clear_outbound_data_buffer(self):
        self._data_to_send = bytearray()

    # ── receiving ──────────────────────────────────────────────────────────

    def receive_data(self, data):
        """Feed bytes from the peer; the events they make."""
        events = []
        if self._terminated is not None:
            return events
        self.incoming_buffer += data
        buf = self.incoming_buffer
        try:
            if not self._preamble_seen:
                n = len(PREAMBLE)
                if len(buf) < n:
                    if not PREAMBLE.startswith(bytes(buf)):
                        raise ProtocolError("Invalid HTTP/2 preamble.")
                    return events
                if bytes(buf[:n]) != PREAMBLE:
                    raise ProtocolError("Invalid HTTP/2 preamble.")
                del buf[:n]
                self._preamble_seen = True
            while len(buf) >= 9:
                length = (buf[0] << 16) | (buf[1] << 8) | buf[2]
                if length > self.max_inbound_frame_size:
                    raise FrameTooLargeError("Received overlong frame: length %d, max %d" % (length, self.max_inbound_frame_size))
                if len(buf) < 9 + length:
                    break
                header = bytes(buf[:9])
                body = bytes(buf[9:9 + length])
                del buf[:9 + length]
                if header[3] == 0x4 and (header[4] & 1) and length:
                    raise FrameDataMissingError("SETTINGS ack frame must not have payload")
                if header[3] == 0x2 and length != 5 and not self._first_frame and self._header_block is None:
                    # a PRIORITY of the wrong size is a stream error (RFC 9113 6.3)
                    sid = ((header[5] & 0x7F) << 24) | (header[6] << 16) | (header[7] << 8) | header[8]
                    if sid:
                        events.extend(self._stream_error(sid, ErrorCodes.FRAME_SIZE_ERROR))
                        continue
                try:
                    frame = Frame.parse_frame_header(header)[0]
                    frame.parse_body(memoryview(body))
                except InvalidPaddingError:
                    raise ProtocolError("Received frame with invalid padding.")
                except InvalidFrameError as e:
                    raise FrameDataMissingError("Frame data missing or invalid: %s" % e)
                except InvalidDataError as e:
                    raise ProtocolError("Received frame with invalid data: %s" % e)
                events.extend(self._receive_frame(frame))
        except ProtocolError as e:
            self._terminate_connection(e.error_code)
            self._terminated = e
            raise
        return events

    def _terminate_connection(self, error_code):
        f = GoAwayFrame(0, last_stream_id=self.highest_inbound_stream_id, error_code=int(error_code))
        self._data_to_send += f.serialize()
        self.state_machine = ConnectionState.CLOSED

    def _receive_frame(self, frame):
        if self._first_frame:
            if not isinstance(frame, SettingsFrame) or "ACK" in frame.flags:
                raise ProtocolError("The first frame must be SETTINGS, got %s" % frame.__class__.__name__)
            self._first_frame = False
        if self._header_block is not None:
            if not isinstance(frame, ContinuationFrame) or frame.stream_id != self._header_block[1]:
                raise ProtocolError("Expected CONTINUATION on stream %d, got %s" % (self._header_block[1], frame.__class__.__name__))
            return self._receive_continuation(frame)
        if isinstance(frame, DataFrame):
            return self._receive_data_frame(frame)
        if isinstance(frame, HeadersFrame):
            return self._begin_block(frame, frame.data)
        if isinstance(frame, SettingsFrame):
            return self._receive_settings(frame)
        if isinstance(frame, WindowUpdateFrame):
            return self._receive_window_update(frame)
        if isinstance(frame, RstStreamFrame):
            return self._receive_rst_stream(frame)
        if isinstance(frame, PingFrame):
            return self._receive_ping(frame)
        if isinstance(frame, GoAwayFrame):
            return self._receive_goaway(frame)
        if isinstance(frame, PriorityFrame):
            return self._receive_priority(frame)
        if isinstance(frame, PushPromiseFrame):
            if not self.config.client_side:
                raise ProtocolError("Received PUSH_PROMISE as a server: clients cannot push")
            if not self.local_settings.enable_push:
                raise ProtocolError("Received PUSH_PROMISE with push disabled (SETTINGS_ENABLE_PUSH=0)")
            return self._begin_block(frame, frame.data)
        if isinstance(frame, ContinuationFrame):
            raise ProtocolError("Received CONTINUATION frame without a field block in progress")
        if isinstance(frame, AltSvcFrame):
            if self.config.client_side:
                ev = AlternativeServiceAvailable()
                ev.origin = frame.origin
                ev.field_value = frame.field
                return [ev]
            return []
        if isinstance(frame, PriorityUpdateFrame):
            return self._receive_priority_update(frame)
        ev = UnknownFrameReceived()
        ev.frame = frame
        return [ev]

    # field blocks: HEADERS / PUSH_PROMISE + CONTINUATION
    def _block_limit(self):
        n = self.local_settings.max_header_list_size or self.DEFAULT_MAX_HEADER_LIST_SIZE
        return max(4 * n, 65536)

    def _begin_block(self, frame, data):
        self._header_block = [frame, frame.stream_id, [bytes(data)], len(data)]
        if "END_HEADERS" in frame.flags:
            return self._end_block()
        if len(data) > self._block_limit():
            raise DenialOfServiceError("Field block too large")
        return []

    def _receive_continuation(self, frame):
        hb = self._header_block
        hb[2].append(bytes(frame.data))
        hb[3] += len(frame.data)
        if hb[3] > self._block_limit():
            raise DenialOfServiceError("Field block too large (CONTINUATION flood)")
        if "END_HEADERS" in frame.flags:
            return self._end_block()
        return []

    def _decode_block(self, block):
        try:
            return self.decoder.decode(block, raw=True)
        except hpack.OversizedHeaderListError as e:
            raise DenialOfServiceError("Oversized header block: %s" % e)
        except (hpack.HPACKError, IndexError, TypeError, UnicodeDecodeError) as e:
            err = ProtocolError("Error decoding header block: %s" % e)
            err.error_code = ErrorCodes.COMPRESSION_ERROR
            raise err

    def _end_block(self):
        frame = self._header_block[0]
        block = b"".join(self._header_block[2])
        self._header_block = None
        headers = self._decode_block(block)
        if isinstance(frame, PushPromiseFrame):
            return self._receive_push_promise(frame, headers)
        return self._receive_headers(frame, headers)

    def _event_headers(self, headers):
        if self.config.normalize_inbound_headers:
            headers = utilities.join_cookies(headers)
        enc = self.config.header_encoding
        if enc:
            return [h.__class__(h[0].decode(enc), h[1].decode(enc)) for h in headers]
        return headers

    def _stream_error(self, stream_id, code, events=None):
        # reset a stream because of what the peer sent; report it
        self._data_to_send += RstStreamFrame(stream_id, int(code)).serialize()
        s = self.streams.get(stream_id)
        if s is not None:
            self._forget(s, StreamClosedBy.SEND_RST_STREAM)
        else:
            self._closed_streams[stream_id] = StreamClosedBy.SEND_RST_STREAM
        ev = StreamReset()
        ev.stream_id = stream_id
        ev.error_code = _error_code_from_int(code)
        ev.remote_reset = False
        out = list(events or [])
        out.append(ev)
        return out

    def _is_idle(self, stream_id):
        # a stream id the peer (or we) never used, above the highest seen
        mine = (stream_id % 2 == 1) == self.config.client_side
        if mine:
            return stream_id > self.highest_outbound_stream_id
        return stream_id > self.highest_inbound_stream_id

    def _receive_headers(self, frame, headers):
        sid = frame.stream_id
        end_stream = "END_STREAM" in frame.flags
        events = []
        stream = self.streams.get(sid)
        if stream is None:
            closed = self._closed_streams.get(sid)
            if closed is not None or sid in self._dead_inbound:
                if closed == StreamClosedBy.SEND_RST_STREAM or sid in self._dead_inbound:
                    return []
                return self._stream_error(sid, ErrorCodes.STREAM_CLOSED)
            if self.config.client_side:
                raise ProtocolError("Received HEADERS on stream %d the server cannot open" % sid)
            if sid % 2 == 0:
                raise ProtocolError("Received HEADERS on even stream %d from a client" % sid)
            if sid <= self.highest_inbound_stream_id:
                raise StreamIDTooLowError(sid, self.highest_inbound_stream_id)
            self.highest_inbound_stream_id = sid
            if self._goaway_sent is not None and sid > self._goaway_sent:
                self._dead_inbound.add(sid)       # refused by our GOAWAY: ignored
                return []
            if self.open_inbound_streams + 1 > self.local_settings.max_concurrent_streams:
                return self._stream_error(sid, ErrorCodes.REFUSED_STREAM)
            stream = self._new_stream(sid, False)
            stream.state = StreamState.OPEN
            kind = "request"
        else:
            if not stream.can_receive():
                return self._stream_error(sid, ErrorCodes.STREAM_CLOSED)
            if stream.headers_received:
                kind = "trailers"
            elif self.config.client_side:
                kind = "informational" if utilities.is_informational(headers) else "response"
            else:
                kind = "trailers" if stream.request_method is not None else "request"
        if self.config.validate_inbound_headers:
            try:
                utilities.validate_headers(headers, kind, self.local_settings.enable_connect_protocol == 1)
                if kind == "trailers" and not end_stream:
                    raise ProtocolError("Trailers must end the stream")
                if kind == "informational" and end_stream:
                    raise ProtocolError("A 1xx response cannot end the stream")
                cl = utilities.content_length(headers) if kind in ("request", "response") else None
            except ProtocolError:
                return self._stream_error(sid, ErrorCodes.PROTOCOL_ERROR)
        else:
            cl = None
        if kind == "request":
            stream.request_method = utilities.header_value(headers, b":method")
            stream.headers_received = True
            prio = self._pending_priority.pop(sid, None)
            if prio is None:
                pv = utilities.header_value(headers, b"priority")
                prio = (3, False)
                if pv is not None:
                    try:
                        prio = parse_priority(pv)
                    except ValueError:
                        prio = (3, False)
            stream.priority = prio
            ev = RequestReceived()
            ev.priority = prio
        elif kind == "response":
            stream.headers_received = True
            stream.response_status = utilities.header_value(headers, b":status")
            ev = ResponseReceived()
        elif kind == "informational":
            ev = InformationalResponseReceived()
        else:
            stream.trailers_received = True
            ev = TrailersReceived()
        if kind == "request":
            stream.expected_length = cl
        elif kind == "response":
            if stream.request_method == b"HEAD" or stream.response_status in (b"204", b"304"):
                stream.expected_length = -1          # no content, whatever content-length says
            else:
                stream.expected_length = cl
        ev.stream_id = sid
        ev.headers = self._event_headers(headers)
        events.append(ev)
        if end_stream:
            err = self._check_length(stream, True)
            if err:
                return self._stream_error(sid, ErrorCodes.PROTOCOL_ERROR, events[:-1])
            se = StreamEnded()
            se.stream_id = sid
            ev.stream_ended = se
            events.append(se)
            stream.received_end_stream()
            if stream.state == StreamState.CLOSED:
                self._forget(stream, StreamClosedBy.RECV_END_STREAM)
        if "PRIORITY" in frame.flags:
            if frame.depends_on == sid:
                return self._stream_error(sid, ErrorCodes.PROTOCOL_ERROR, events)
            pu = PriorityUpdated()
            pu.stream_id = sid
            pu.weight = frame.stream_weight + 1
            pu.depends_on = frame.depends_on
            pu.exclusive = frame.exclusive
            ev.priority_updated = pu
            events.append(pu)
        return events

    def _check_length(self, stream, at_end):
        exp = stream.expected_length
        if exp is None:
            return False
        if exp == -1:
            return stream.received_length > 0
        if stream.received_length > exp:
            return True
        return at_end and stream.received_length != exp

    def _receive_push_promise(self, frame, headers):
        sid = frame.stream_id
        pid = frame.promised_stream_id
        parent = self.streams.get(sid)
        if parent is None or not parent.can_receive():
            if sid in self._closed_streams:
                # pushed on a stream we already closed: refuse the promise
                self._data_to_send += RstStreamFrame(pid, int(ErrorCodes.CANCEL)).serialize()
                self._closed_streams[pid] = StreamClosedBy.SEND_RST_STREAM
                return []
            raise ProtocolError("Received PUSH_PROMISE on an idle stream %d" % sid)
        if pid <= self.highest_inbound_stream_id:
            raise StreamIDTooLowError(pid, self.highest_inbound_stream_id)
        self.highest_inbound_stream_id = pid
        ev = PushedStreamReceived()
        ev.pushed_stream_id = pid
        ev.parent_stream_id = sid
        ev.headers = self._event_headers(headers)
        # the client refuses pushed streams
        self._data_to_send += RstStreamFrame(pid, int(ErrorCodes.CANCEL)).serialize()
        self._closed_streams[pid] = StreamClosedBy.SEND_RST_STREAM
        return [ev]

    def _ack_closed_data(self, n):
        # DATA we will never deliver still used the connection window
        if n:
            self.acknowledge_received_data(n, 0)

    def _receive_data_frame(self, frame):
        sid = frame.stream_id
        n = frame.flow_controlled_length
        if n > self._inbound_window:
            raise FlowControlError("Cannot receive %d bytes, flow control window is %d." % (n, self._inbound_window))
        self._inbound_window -= n
        stream = self.streams.get(sid)
        if stream is None or not stream.can_receive():
            self._ack_closed_data(n)
            if stream is None:
                closed = self._closed_streams.get(sid)
                if closed is None and sid not in self._dead_inbound:
                    if self._is_idle(sid):
                        raise ProtocolError("Received DATA on idle stream %d" % sid)
                    return self._stream_error(sid, ErrorCodes.STREAM_CLOSED)
                if closed == StreamClosedBy.SEND_RST_STREAM or sid in self._dead_inbound:
                    return []
            return self._stream_error(sid, ErrorCodes.STREAM_CLOSED)
        if n > stream.inbound_window:
            self._ack_closed_data(n)
            return self._stream_error(sid, ErrorCodes.FLOW_CONTROL_ERROR)
        stream.inbound_window -= n
        stream.received_length += len(frame.data)
        end_stream = "END_STREAM" in frame.flags
        if self._check_length(stream, end_stream):
            self._ack_closed_data(n)
            return self._stream_error(sid, ErrorCodes.PROTOCOL_ERROR)
        ev = DataReceived()
        ev.stream_id = sid
        ev.data = frame.data
        ev.flow_controlled_length = n
        events = [ev]
        if end_stream:
            se = StreamEnded()
            se.stream_id = sid
            ev.stream_ended = se
            events.append(se)
            stream.received_end_stream()
            if stream.state == StreamState.CLOSED:
                self._forget(stream, StreamClosedBy.RECV_END_STREAM)
        return events

    def _apply_remote_settings(self, settings):
        old = {}
        for k in settings:
            v = settings[k]
            code = _validate_setting(k, v)
            if code:
                err = InvalidSettingsValueError("Setting %d has invalid value %d" % (k, v), error_code=code)
                raise err
            if k == SettingCodes.ENABLE_PUSH and v == 1 and self.config.client_side:
                raise ProtocolError("A server MUST NOT set SETTINGS_ENABLE_PUSH to 1")
            old[k] = self.remote_settings.get(k)
            self.remote_settings[k] = v
        changed = self.remote_settings.acknowledge()
        for k in changed:
            c = changed[k]
            if k == SettingCodes.INITIAL_WINDOW_SIZE:
                delta = c.new_value - (c.original_value if c.original_value is not None else 65535)
                for s in self.streams.values():
                    s.outbound_flow_control_window += delta
                    if s.outbound_flow_control_window > _MAX_WINDOW:
                        raise FlowControlError("Flow control window too large after SETTINGS_INITIAL_WINDOW_SIZE")
            elif k == SettingCodes.HEADER_TABLE_SIZE:
                self.encoder.header_table_size = c.new_value
        return RemoteSettingsChanged.from_settings(old, settings)

    def _receive_settings(self, frame):
        if "ACK" in frame.flags:
            changed = self.local_settings.acknowledge()
            for k in changed:
                c = changed[k]
                if k == SettingCodes.INITIAL_WINDOW_SIZE:
                    delta = c.new_value - c.original_value
                    for s in self.streams.values():
                        s.inbound_window += delta
                        s.inbound_max = c.new_value
                elif k == SettingCodes.HEADER_TABLE_SIZE:
                    self.decoder.max_allowed_table_size = c.new_value
                elif k == SettingCodes.MAX_HEADER_LIST_SIZE:
                    self.decoder.max_header_list_size = c.new_value
            ev = SettingsAcknowledged()
            ev.changed_settings = changed
            return [ev]
        ev = self._apply_remote_settings(frame.settings)
        self._data_to_send += SettingsFrame(0, flags=["ACK"]).serialize()
        return [ev]

    def _receive_window_update(self, frame):
        sid = frame.stream_id
        inc = frame.window_increment
        if sid == 0:
            if inc == 0:
                raise ProtocolError("WINDOW_UPDATE with a zero increment on the connection")
            self.outbound_flow_control_window += inc
            if self.outbound_flow_control_window > _MAX_WINDOW:
                raise FlowControlError("Flow control window too large: %d" % self.outbound_flow_control_window)
        else:
            stream = self.streams.get(sid)
            if stream is None:
                if sid not in self._closed_streams and sid not in self._dead_inbound and self._is_idle(sid):
                    raise ProtocolError("Received WINDOW_UPDATE on idle stream %d" % sid)
                return []
            if inc == 0:
                return self._stream_error(sid, ErrorCodes.PROTOCOL_ERROR)
            stream.outbound_flow_control_window += inc
            if stream.outbound_flow_control_window > _MAX_WINDOW:
                return self._stream_error(sid, ErrorCodes.FLOW_CONTROL_ERROR)
        ev = WindowUpdated()
        ev.stream_id = sid
        ev.delta = inc
        return [ev]

    def _receive_rst_stream(self, frame):
        sid = frame.stream_id
        stream = self.streams.get(sid)
        if stream is None:
            if sid not in self._closed_streams and sid not in self._dead_inbound and self._is_idle(sid):
                raise ProtocolError("Received RST_STREAM on idle stream %d" % sid)
            return []
        self._forget(stream, StreamClosedBy.RECV_RST_STREAM)
        ev = StreamReset()
        ev.stream_id = sid
        ev.error_code = _error_code_from_int(frame.error_code)
        ev.remote_reset = True
        return [ev]

    def _receive_ping(self, frame):
        if "ACK" in frame.flags:
            ev = PingAckReceived()
            ev.ping_data = frame.opaque_data
            return [ev]
        self._data_to_send += PingFrame(0, frame.opaque_data, flags=["ACK"]).serialize()
        ev = PingReceived()
        ev.ping_data = frame.opaque_data
        return [ev]

    def _receive_goaway(self, frame):
        last = frame.last_stream_id
        if self._goaway_received is None or last < self._goaway_received:
            self._goaway_received = last
        ev = ConnectionTerminated()
        ev.error_code = _error_code_from_int(frame.error_code)
        ev.last_stream_id = last
        ev.additional_data = frame.additional_data if frame.additional_data else None
        events = [ev]
        # our streams the peer did not process: refused, safe to retry
        for sid in sorted(self.streams):
            s = self.streams[sid]
            if s.locally_initiated and sid > last:
                self._forget(s, StreamClosedBy.RECV_RST_STREAM)
                r = StreamReset()
                r.stream_id = sid
                r.error_code = ErrorCodes.REFUSED_STREAM
                r.remote_reset = True
                events.append(r)
        if frame.error_code != 0:
            self.state_machine = ConnectionState.CLOSED
        return events

    def _receive_priority(self, frame):
        sid = frame.stream_id
        if frame.depends_on == sid:
            return self._stream_error(sid, ErrorCodes.PROTOCOL_ERROR)
        ev = PriorityUpdated()
        ev.stream_id = sid
        ev.weight = frame.stream_weight + 1
        ev.depends_on = frame.depends_on
        ev.exclusive = frame.exclusive
        return [ev]

    def _receive_priority_update(self, frame):
        if self.config.client_side:
            raise ProtocolError("Received PRIORITY_UPDATE as a client")
        sid = frame.prioritized_stream_id
        if sid == 0:
            raise ProtocolError("PRIORITY_UPDATE for stream 0")
        try:
            prio = parse_priority(frame.priority_field_value)
        except ValueError:
            raise ProtocolError("Invalid PRIORITY_UPDATE field value %r" % (frame.priority_field_value,))
        stream = self.streams.get(sid)
        if stream is not None:
            stream.priority = prio
        elif sid in self._closed_streams or not self._is_idle(sid):
            return []
        else:
            if sid % 2 == 0:
                raise ProtocolError("PRIORITY_UPDATE for an idle push stream %d" % sid)
            self._pending_priority[sid] = prio
            if len(self._pending_priority) + self.open_inbound_streams > self.local_settings.max_concurrent_streams:
                raise ProtocolError("Too many PRIORITY_UPDATE frames for idle streams")
        ev = PriorityUpdateReceived()
        ev.stream_id = sid
        ev.urgency = prio[0]
        ev.incremental = prio[1]
        ev.field_value = frame.priority_field_value
        return [ev]
