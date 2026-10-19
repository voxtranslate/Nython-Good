# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/events.ny - what H2Connection.receive_data() reports (round 86), as
# the h2 package's h2.events, with the same attributes and reprs.
#
# Nython's additions: RequestReceived.priority - the RFC 9218 (urgency,
# incremental) of the request (its Priority header field, or a
# PRIORITY_UPDATE received before it); PriorityUpdateReceived - an RFC 9218
# PRIORITY_UPDATE frame (server side).
import binascii

from h2.settings import ChangedSetting, _setting_code_from_int


class Event:
    """Base class for h2 events."""


class RequestReceived(Event):
    """A request's headers arrived (the server side). stream_ended: the
    StreamEnded event when the request has no body; priority_updated: the
    PriorityUpdated event when HEADERS carried RFC 7540 priority data."""
    def __init__(self):
        self.stream_id = None
        self.headers = None
        self.stream_ended = None
        self.priority_updated = None
        self.priority = (3, False)

    def __repr__(self):
        return "<RequestReceived stream_id:%s, headers:%s>" % (self.stream_id, self.headers)


class ResponseReceived(Event):
    """A response's final headers arrived (the client side)."""
    def __init__(self):
        self.stream_id = None
        self.headers = None
        self.stream_ended = None
        self.priority_updated = None

    def __repr__(self):
        return "<ResponseReceived stream_id:%s, headers:%s>" % (self.stream_id, self.headers)


class TrailersReceived(Event):
    """A trailer field block arrived (it always ends the stream)."""
    def __init__(self):
        self.stream_id = None
        self.headers = None
        self.stream_ended = None
        self.priority_updated = None

    def __repr__(self):
        return "<TrailersReceived stream_id:%s, headers:%s>" % (self.stream_id, self.headers)


class _HeadersSent(Event):
    pass


class _ResponseSent(_HeadersSent):
    pass


class _RequestSent(_HeadersSent):
    pass


class _TrailersSent(_HeadersSent):
    pass


class _PushedRequestSent(_HeadersSent):
    pass


class InformationalResponseReceived(Event):
    """A 1xx response arrived before the final one."""
    def __init__(self):
        self.stream_id = None
        self.headers = None
        self.priority_updated = None

    def __repr__(self):
        return "<InformationalResponseReceived stream_id:%s, headers:%s>" % (self.stream_id, self.headers)


class DataReceived(Event):
    """DATA arrived. flow_controlled_length counts the padding too: pass it
    to acknowledge_received_data() once the data has been consumed."""
    def __init__(self):
        self.stream_id = None
        self.data = None
        self.flow_controlled_length = None
        self.stream_ended = None

    def __repr__(self):
        return "<DataReceived stream_id:%s, flow_controlled_length:%s, data:%s>" % (
            self.stream_id, self.flow_controlled_length,
            _bytes_representation(self.data[:20]) if self.data else "")


class WindowUpdated(Event):
    """The peer widened a flow-control window (stream_id 0: the connection's)."""
    def __init__(self):
        self.stream_id = None
        self.delta = None

    def __repr__(self):
        return "<WindowUpdated stream_id:%s, delta:%s>" % (self.stream_id, self.delta)


class RemoteSettingsChanged(Event):
    """The peer's SETTINGS frame was applied (and acknowledged)."""
    def __init__(self):
        self.changed_settings = {}

    @classmethod
    def from_settings(cls, old_settings, new_settings):
        e = cls()
        for setting in new_settings:
            new_value = new_settings[setting]
            s = _setting_code_from_int(setting)
            original_value = old_settings.get(s)
            e.changed_settings[s] = ChangedSetting(s, original_value, new_value)
        return e

    def __repr__(self):
        return "<RemoteSettingsChanged changed_settings:{%s}>" % ", ".join(repr(cs) for cs in self.changed_settings.values())


class PingReceived(Event):
    """A PING arrived (its ACK has been queued already)."""
    def __init__(self):
        self.ping_data = None

    def __repr__(self):
        return "<PingReceived ping_data:%s>" % _bytes_representation(self.ping_data)


class PingAckReceived(Event):
    """The ACK of one of our PINGs arrived."""
    def __init__(self):
        self.ping_data = None

    def __repr__(self):
        return "<PingAckReceived ping_data:%s>" % _bytes_representation(self.ping_data)


class StreamEnded(Event):
    """The peer half-closed a stream (END_STREAM)."""
    def __init__(self):
        self.stream_id = None

    def __repr__(self):
        return "<StreamEnded stream_id:%s>" % self.stream_id


class StreamReset(Event):
    """A stream was reset: by the peer (remote_reset) or by us after a stream
    error in what the peer sent."""
    def __init__(self):
        self.stream_id = None
        self.error_code = None
        self.remote_reset = True

    def __repr__(self):
        return "<StreamReset stream_id:%s, error_code:%s, remote_reset:%s>" % (
            self.stream_id, str(self.error_code), self.remote_reset)


class PushedStreamReceived(Event):
    """A PUSH_PROMISE arrived while push was enabled (the client refused the
    stream: it is reset with CANCEL)."""
    def __init__(self):
        self.pushed_stream_id = None
        self.parent_stream_id = None
        self.headers = None

    def __repr__(self):
        return "<PushedStreamReceived pushed_stream_id:%s, parent_stream_id:%s, headers:%s>" % (
            self.pushed_stream_id, self.parent_stream_id, self.headers)


class SettingsAcknowledged(Event):
    """The peer acknowledged our SETTINGS: these local settings now apply."""
    def __init__(self):
        self.changed_settings = {}

    def __repr__(self):
        return "<SettingsAcknowledged changed_settings:{%s}>" % ", ".join(repr(cs) for cs in self.changed_settings.values())


class PriorityUpdated(Event):
    """RFC 7540 priority data arrived (a PRIORITY frame, or HEADERS with it)."""
    def __init__(self):
        self.stream_id = None
        self.weight = None
        self.depends_on = None
        self.exclusive = None

    def __repr__(self):
        return "<PriorityUpdated stream_id:%s, weight:%s, depends_on:%s, exclusive:%s>" % (
            self.stream_id, self.weight, self.depends_on, self.exclusive)


class PriorityUpdateReceived(Event):
    """(Nython) an RFC 9218 PRIORITY_UPDATE frame: the client's new
    (urgency, incremental) for a stream; field_value is the frame's text."""
    def __init__(self):
        self.stream_id = None
        self.urgency = 3
        self.incremental = False
        self.field_value = None

    def __repr__(self):
        return "<PriorityUpdateReceived stream_id:%s, urgency:%s, incremental:%s>" % (
            self.stream_id, self.urgency, self.incremental)


class ConnectionTerminated(Event):
    """The peer sent GOAWAY. Streams above last_stream_id were not processed."""
    def __init__(self):
        self.error_code = None
        self.last_stream_id = None
        self.additional_data = None

    def __repr__(self):
        return "<ConnectionTerminated error_code:%s, last_stream_id:%s, additional_data:%s>" % (
            str(self.error_code), self.last_stream_id,
            _bytes_representation(self.additional_data[:20] if self.additional_data else None))


class AlternativeServiceAvailable(Event):
    """An ALTSVC frame (RFC 7838) arrived."""
    def __init__(self):
        self.origin = None
        self.field_value = None

    def __repr__(self):
        return "<AlternativeServiceAvailable origin:%s, field_value:%s>" % (
            (self.origin or b"").decode("utf-8", "ignore"), (self.field_value or b"").decode("utf-8", "ignore"))


class UnknownFrameReceived(Event):
    """A frame of a type this implementation does not know (it is ignored)."""
    def __init__(self):
        self.frame = None

    def __repr__(self):
        return "<UnknownFrameReceived>"


def _bytes_representation(data):
    if data is None:
        return None
    return binascii.hexlify(data).decode("ascii")
