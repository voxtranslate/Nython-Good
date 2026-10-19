# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/stream.ny - one HTTP/2 stream's state (RFC 9113 5.1; round 86).
#
# StreamState: IDLE, RESERVED_REMOTE, RESERVED_LOCAL, OPEN, HALF_CLOSED_REMOTE,
# HALF_CLOSED_LOCAL, CLOSED (the h2 package's names); StreamClosedBy: how a
# closed stream was closed (it decides how a late frame is answered). H2Stream
# holds the state, both flow-control windows and what the field blocks said;
# H2Connection drives it.
import enum


class StreamState(enum.IntEnum):
    IDLE = 0
    RESERVED_REMOTE = 1
    RESERVED_LOCAL = 2
    OPEN = 3
    HALF_CLOSED_REMOTE = 4
    HALF_CLOSED_LOCAL = 5
    CLOSED = 6


class StreamClosedBy(enum.Enum):
    SEND_END_STREAM = 0
    RECV_END_STREAM = 1
    SEND_RST_STREAM = 2
    RECV_RST_STREAM = 3


class H2Stream:
    def __init__(self, stream_id, outbound_window, inbound_window):
        self.stream_id = stream_id
        self.state = StreamState.IDLE
        self.outbound_flow_control_window = outbound_window
        self.inbound_window = inbound_window
        self.inbound_max = inbound_window
        self.inbound_processed = 0
        self.closed_by = None
        self.request_method = None       # the request's :method (both sides)
        self.headers_sent = False        # a final (non-1xx) field block was sent
        self.headers_received = False    # a final field block was received
        self.trailers_received = False
        self.expected_length = None      # the peer's content-length
        self.received_length = 0
        self.response_status = None
        self.priority = (3, False)       # RFC 9218 (urgency, incremental)
        self.locally_initiated = False

    @property
    def open(self):
        return self.state in (StreamState.OPEN, StreamState.HALF_CLOSED_LOCAL, StreamState.HALF_CLOSED_REMOTE)

    @property
    def closed(self):
        return self.state == StreamState.CLOSED

    @property
    def inbound_flow_control_window(self):
        return self.inbound_window

    def sent_end_stream(self):
        if self.state in (StreamState.OPEN, StreamState.RESERVED_LOCAL):
            self.state = StreamState.HALF_CLOSED_LOCAL
        elif self.state == StreamState.HALF_CLOSED_REMOTE:
            self.state = StreamState.CLOSED
            self.closed_by = StreamClosedBy.SEND_END_STREAM

    def received_end_stream(self):
        if self.state in (StreamState.OPEN, StreamState.RESERVED_REMOTE):
            self.state = StreamState.HALF_CLOSED_REMOTE
        elif self.state == StreamState.HALF_CLOSED_LOCAL:
            self.state = StreamState.CLOSED
            self.closed_by = StreamClosedBy.RECV_END_STREAM

    def can_send(self):
        return self.state in (StreamState.OPEN, StreamState.HALF_CLOSED_REMOTE)

    def can_receive(self):
        return self.state in (StreamState.OPEN, StreamState.HALF_CLOSED_LOCAL)

    def __repr__(self):
        return "<H2Stream id=%d state=%s>" % (self.stream_id, self.state.name)
