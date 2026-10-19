# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/frame.ny - HTTP/2 frames (RFC 9113 section 6; round 86), with the
# API of hyperframe (the frame layer python-hyper's h2 is built on).
#
#     f = DataFrame(1, b"hi", flags=["END_STREAM"])
#     wire = f.serialize()                     9-octet header + payload
#     g, length = Frame.parse_frame_header(memoryview(wire[:9]))
#     g.parse_body(memoryview(wire[9:9 + length]))
#
# DataFrame (0x0), HeadersFrame (0x1), PriorityFrame (0x2), RstStreamFrame
# (0x3), SettingsFrame (0x4), PushPromiseFrame (0x5), PingFrame (0x6),
# GoAwayFrame (0x7), WindowUpdateFrame (0x8), ContinuationFrame (0x9),
# AltSvcFrame (0xa, RFC 7838), PriorityUpdateFrame (0x10, RFC 9218 - not in
# hyperframe), ExtensionFrame (any other type: kept, never an error - RFC 9113
# 4.1 says unknown types are ignored). FRAMES maps type -> class.
# Padding (PADDED, pad_length) and RFC 7540 priority fields (PRIORITY,
# depends_on / stream_weight / exclusive). Flags is a set that only takes the
# frame type's defined flags.
#
# Errors: InvalidFrameError (a payload of the wrong size: FRAME_SIZE_ERROR at
# the connection), InvalidPaddingError (padding longer than the payload:
# PROTOCOL_ERROR), InvalidDataError (a stream identifier where the type
# forbids one, or none where it needs one), UnknownFrameError (strict
# parse_frame_header only). Unlike hyperframe, a WINDOW_UPDATE increment of
# 0 parses: whether it is a stream or a connection error (RFC 9113 6.9) is
# the connection's decision.

__all__ = ["Frame", "Flag", "Flags", "DataFrame", "HeadersFrame", "PriorityFrame", "RstStreamFrame",
           "SettingsFrame", "PushPromiseFrame", "PingFrame", "GoAwayFrame", "WindowUpdateFrame",
           "ContinuationFrame", "AltSvcFrame", "PriorityUpdateFrame", "ExtensionFrame", "FRAMES",
           "FRAME_MAX_LEN", "FRAME_MAX_ALLOWED_LEN", "HyperframeError", "UnknownFrameError",
           "InvalidFrameError", "InvalidPaddingError", "InvalidDataError"]

FRAME_MAX_LEN = (2 ** 14)               # the initial SETTINGS_MAX_FRAME_SIZE
FRAME_MAX_ALLOWED_LEN = (2 ** 24) - 1   # the largest a peer may allow
_STREAM_ASSOC_HAS_STREAM = "has-stream"
_STREAM_ASSOC_NO_STREAM = "no-stream"
_STREAM_ASSOC_EITHER = "either"


class HyperframeError(Exception):
    """The base class for all exceptions of the frame layer."""


class UnknownFrameError(HyperframeError):
    """A frame of an unknown type was found (strict parsing only)."""
    def __init__(self, frame_type, length):
        HyperframeError.__init__(self, frame_type, length)
        self.frame_type = frame_type
        self.length = length

    def __str__(self):
        return "UnknownFrameError: Unknown frame type 0x%X received, length %d bytes" % (self.frame_type, self.length)


class InvalidPaddingError(HyperframeError):
    """A frame with invalid padding was received."""


class InvalidFrameError(HyperframeError):
    """Parsing a frame failed because the data was not laid out appropriately."""


class InvalidDataError(HyperframeError):
    """Content or data of a frame is invalid or violates the specification."""


def _u32(data, i):
    return (data[i] << 24) | (data[i + 1] << 16) | (data[i + 2] << 8) | data[i + 3]


def _p32(n):
    return bytes([(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF])


def _raw_data_repr(data):
    if not data:
        return "None"
    r = bytes(data).hex()
    if len(r) > 20:
        r = r[:20] + "..."
    return "<hex:" + r + ">"


class Flag(tuple):
    """(name, bit) of a frame flag."""
    def __new__(cls, name, bit):
        return tuple.__new__(cls, (name, bit))

    @property
    def name(self):
        return self[0]

    @property
    def bit(self):
        return self[1]


class Flags:
    """A set of flag names that only accepts the frame type's defined flags."""
    def __init__(self, defined_flags):
        self._valid_flags = set(f[0] for f in defined_flags)
        self._flags = set()

    def __repr__(self):
        return repr(sorted(self._flags))

    def __contains__(self, x):
        return x in self._flags

    def __iter__(self):
        return iter(self._flags)

    def __len__(self):
        return len(self._flags)

    def __eq__(self, other):
        if isinstance(other, Flags):
            return self._flags == other._flags
        return self._flags == set(other)

    __hash__ = None

    def discard(self, value):
        self._flags.discard(value)

    def add(self, value):
        if value not in self._valid_flags:
            raise ValueError("Unexpected flag: %s. Valid flags are: %s" % (value, sorted(self._valid_flags)))
        self._flags.add(value)


class Frame:
    """The base class for all HTTP/2 frames."""
    defined_flags = []
    type = None
    stream_association = None

    def __init__(self, stream_id, flags=()):
        self.stream_id = stream_id
        self.flags = Flags(self.defined_flags)
        self.body_len = 0
        for flag in flags:
            self.flags.add(flag)
        if not self.stream_id and self.stream_association == _STREAM_ASSOC_HAS_STREAM:
            raise InvalidDataError("Stream ID must be non-zero for %s" % self.__class__.__name__)
        if self.stream_id and self.stream_association == _STREAM_ASSOC_NO_STREAM:
            raise InvalidDataError("Stream ID must be zero for %s with stream_id=%d" % (self.__class__.__name__, self.stream_id))

    def __repr__(self):
        return "%s(stream_id=%s, flags=%r): %s" % (self.__class__.__name__, self.stream_id, self.flags, self._body_repr())

    def _body_repr(self):
        return _raw_data_repr(self.serialize_body())

    @staticmethod
    def explain(data):
        frame, length = Frame.parse_frame_header(data[:9])
        frame.parse_body(memoryview(bytes(data[9:9 + length])))
        print(frame)
        return frame, length

    @staticmethod
    def parse_frame_header(header, strict=False):
        """(frame without a body, payload length) from a 9-octet header."""
        if len(header) != 9:
            raise InvalidFrameError("Invalid frame header")
        length = (header[0] << 16) | (header[1] << 8) | header[2]
        typ = header[3]
        flags = header[4]
        stream_id = _u32(header, 5) & 0x7FFFFFFF
        cls = FRAMES.get(typ)
        if cls is None:
            if strict:
                raise UnknownFrameError(typ, length)
            frame = ExtensionFrame(type=typ, stream_id=stream_id)
        else:
            frame = cls(stream_id)
        frame.parse_flags(flags)
        return (frame, length)

    def parse_flags(self, flag_byte):
        for flag in self.defined_flags:
            if flag_byte & flag[1]:
                self.flags.add(flag[0])
        return self.flags

    def serialize(self):
        """The frame on the wire: header and payload."""
        body = self.serialize_body()
        self.body_len = len(body)
        flags = 0
        for flag in self.defined_flags:
            if flag[0] in self.flags:
                flags |= flag[1]
        n = self.body_len
        header = bytes([(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF, self.type, flags]) + _p32(self.stream_id & 0x7FFFFFFF)
        return header + body

    def serialize_body(self):
        raise NotImplementedError()

    def parse_body(self, data):
        raise NotImplementedError()


class Padding:
    """Mixin for frames that contain padding (PADDED, pad_length)."""
    def __init__(self, stream_id, pad_length=0, **kwargs):
        super().__init__(stream_id, **kwargs)
        self.pad_length = pad_length

    def serialize_padding_data(self):
        if "PADDED" in self.flags:
            return bytes([self.pad_length])
        return b""

    def parse_padding_data(self, data):
        if "PADDED" in self.flags:
            if len(data) < 1:
                raise InvalidFrameError("Invalid Padding data")
            self.pad_length = data[0]
            return 1
        return 0

    @property
    def total_padding(self):
        return self.pad_length


class Priority:
    """Mixin for frames with RFC 7540 priority data."""
    def __init__(self, stream_id, depends_on=0x0, stream_weight=0x0, exclusive=False, **kwargs):
        super().__init__(stream_id, **kwargs)
        self.depends_on = depends_on
        self.stream_weight = stream_weight
        self.exclusive = exclusive

    def serialize_priority_data(self):
        return _p32(self.depends_on + (0x80000000 if self.exclusive else 0)) + bytes([self.stream_weight])

    def parse_priority_data(self, data):
        if len(data) < 5:
            raise InvalidFrameError("Invalid Priority data")
        dep = _u32(data, 0)
        self.depends_on = dep & 0x7FFFFFFF
        self.stream_weight = data[4]
        self.exclusive = bool(dep >> 31)
        return 5


class DataFrame(Padding, Frame):
    """DATA (0x0): request or response content, flow-controlled."""
    defined_flags = [Flag("END_STREAM", 0x01), Flag("PADDED", 0x08)]
    type = 0x0
    stream_association = _STREAM_ASSOC_HAS_STREAM

    def __init__(self, stream_id, data=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        self.data = data

    def serialize_body(self):
        padding = b"\x00" * self.pad_length if "PADDED" in self.flags else b""
        return self.serialize_padding_data() + bytes(self.data) + padding

    def parse_body(self, data):
        n = self.parse_padding_data(data)
        rest = len(data) - n
        if self.pad_length and self.pad_length > rest:
            raise InvalidPaddingError("Padding is too long.")
        self.data = bytes(data[n:len(data) - self.pad_length])
        self.body_len = len(data)

    @property
    def flow_controlled_length(self):
        """The payload's whole length: data, the pad length octet and the padding."""
        padding_len = 0
        if "PADDED" in self.flags:
            padding_len = self.pad_length + 1
        return len(self.data) + padding_len


class PriorityFrame(Priority, Frame):
    """PRIORITY (0x2): RFC 7540's dependency tree (deprecated by RFC 9113)."""
    defined_flags = []
    type = 0x02
    stream_association = _STREAM_ASSOC_HAS_STREAM

    def _body_repr(self):
        return "exclusive=%s, depends_on=%s, stream_weight=%s" % (self.exclusive, self.depends_on, self.stream_weight)

    def serialize_body(self):
        return self.serialize_priority_data()

    def parse_body(self, data):
        if len(data) != 5:
            raise InvalidFrameError("PRIORITY must have 5 byte body: actual length %d." % len(data))
        self.parse_priority_data(data)
        self.body_len = 5


class RstStreamFrame(Frame):
    """RST_STREAM (0x3): ends a stream at once, with an error code."""
    defined_flags = []
    type = 0x03
    stream_association = _STREAM_ASSOC_HAS_STREAM

    def __init__(self, stream_id, error_code=0, **kwargs):
        super().__init__(stream_id, **kwargs)
        self.error_code = error_code

    def _body_repr(self):
        return "error_code=%s" % self.error_code

    def serialize_body(self):
        return _p32(self.error_code)

    def parse_body(self, data):
        if len(data) != 4:
            raise InvalidFrameError("RST_STREAM must have 4 byte body: actual length %d." % len(data))
        self.error_code = _u32(data, 0)
        self.body_len = 4


class SettingsFrame(Frame):
    """SETTINGS (0x4): configuration parameters, or (ACK) their acknowledgement."""
    defined_flags = [Flag("ACK", 0x01)]
    type = 0x04
    stream_association = _STREAM_ASSOC_NO_STREAM
    HEADER_TABLE_SIZE = 0x01
    ENABLE_PUSH = 0x02
    MAX_CONCURRENT_STREAMS = 0x03
    INITIAL_WINDOW_SIZE = 0x04
    MAX_FRAME_SIZE = 0x05
    MAX_HEADER_LIST_SIZE = 0x06
    ENABLE_CONNECT_PROTOCOL = 0x08
    NO_RFC7540_PRIORITIES = 0x09

    def __init__(self, stream_id=0, settings=None, **kwargs):
        super().__init__(stream_id, **kwargs)
        if settings and "ACK" in kwargs.get("flags", ()):
            raise InvalidDataError("Settings must be empty if ACK flag is set.")
        self.settings = dict(settings) if settings else {}

    def _body_repr(self):
        return "settings=%s" % (self.settings,)

    def serialize_body(self):
        out = bytearray()
        for setting in self.settings:
            value = self.settings[setting]
            out += bytes([(setting >> 8) & 0xFF, setting & 0xFF]) + _p32(value)
        return bytes(out)

    def parse_body(self, data):
        if "ACK" in self.flags and len(data) > 0:
            raise InvalidDataError("SETTINGS ack frame must not have payload: got %d bytes" % len(data))
        if len(data) % 6:
            raise InvalidFrameError("SETTINGS frame payload must be a multiple of 6: got %d bytes" % len(data))
        body_len = 0
        i = 0
        while i < len(data):
            name = (data[i] << 8) | data[i + 1]
            self.settings[name] = _u32(data, i + 2)
            body_len += 6
            i += 6
        self.body_len = body_len


class PushPromiseFrame(Padding, Frame):
    """PUSH_PROMISE (0x5): a server announces a stream it will push."""
    defined_flags = [Flag("END_HEADERS", 0x04), Flag("PADDED", 0x08)]
    type = 0x05
    stream_association = _STREAM_ASSOC_HAS_STREAM

    def __init__(self, stream_id, promised_stream_id=0, data=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        self.promised_stream_id = promised_stream_id
        self.data = data

    def _body_repr(self):
        return "promised_stream_id=%s, data=%s" % (self.promised_stream_id, _raw_data_repr(self.data))

    def serialize_body(self):
        padding = b"\x00" * self.pad_length if "PADDED" in self.flags else b""
        return self.serialize_padding_data() + _p32(self.promised_stream_id) + bytes(self.data) + padding

    def parse_body(self, data):
        n = self.parse_padding_data(data)
        if len(data) < n + 4:
            raise InvalidFrameError("Invalid PUSH_PROMISE body")
        self.promised_stream_id = _u32(data, n) & 0x7FFFFFFF
        rest = len(data) - n - 4
        if self.pad_length and self.pad_length > rest:
            raise InvalidPaddingError("Padding is too long.")
        self.data = bytes(data[n + 4:len(data) - self.pad_length])
        self.body_len = len(data)
        if self.promised_stream_id == 0 or self.promised_stream_id % 2 != 0:
            raise InvalidDataError("Invalid PUSH_PROMISE promised stream id: %d" % self.promised_stream_id)


class PingFrame(Frame):
    """PING (0x6): eight opaque octets, echoed back with ACK."""
    defined_flags = [Flag("ACK", 0x01)]
    type = 0x06
    stream_association = _STREAM_ASSOC_NO_STREAM

    def __init__(self, stream_id=0, opaque_data=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        self.opaque_data = opaque_data

    def _body_repr(self):
        return "opaque_data=%r" % (self.opaque_data,)

    def serialize_body(self):
        if len(self.opaque_data) > 8:
            raise InvalidFrameError("PING frame may not have more than 8 bytes of data, got %r" % (self.opaque_data,))
        return bytes(self.opaque_data) + b"\x00" * (8 - len(self.opaque_data))

    def parse_body(self, data):
        if len(data) != 8:
            raise InvalidFrameError("PING frame must have 8 byte length: got %d" % len(data))
        self.opaque_data = bytes(data)
        self.body_len = 8


class GoAwayFrame(Frame):
    """GOAWAY (0x7): the connection is shutting down; streams above
    last_stream_id were not processed."""
    defined_flags = []
    type = 0x07
    stream_association = _STREAM_ASSOC_NO_STREAM

    def __init__(self, stream_id=0, last_stream_id=0, error_code=0, additional_data=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        self.last_stream_id = last_stream_id
        self.error_code = error_code
        self.additional_data = additional_data

    def _body_repr(self):
        return "last_stream_id=%s, error_code=%s, additional_data=%r" % (self.last_stream_id, self.error_code, self.additional_data)

    def serialize_body(self):
        return _p32(self.last_stream_id & 0x7FFFFFFF) + _p32(self.error_code) + bytes(self.additional_data)

    def parse_body(self, data):
        if len(data) < 8:
            raise InvalidFrameError("Invalid GOAWAY body.")
        self.last_stream_id = _u32(data, 0) & 0x7FFFFFFF
        self.error_code = _u32(data, 4)
        self.body_len = len(data)
        self.additional_data = bytes(data[8:])


class WindowUpdateFrame(Frame):
    """WINDOW_UPDATE (0x8): widens a flow-control window (stream 0: the connection's)."""
    defined_flags = []
    type = 0x08
    stream_association = _STREAM_ASSOC_EITHER

    def __init__(self, stream_id, window_increment=0, **kwargs):
        super().__init__(stream_id, **kwargs)
        self.window_increment = window_increment

    def _body_repr(self):
        return "window_increment=%s" % self.window_increment

    def serialize_body(self):
        return _p32(self.window_increment & 0x7FFFFFFF)

    def parse_body(self, data):
        if len(data) != 4:
            raise InvalidFrameError("WINDOW_UPDATE frame must have 4 byte length: got %d" % len(data))
        self.window_increment = _u32(data, 0) & 0x7FFFFFFF
        self.body_len = 4


class HeadersFrame(Padding, Priority, Frame):
    """HEADERS (0x1): opens a stream and carries a field block fragment."""
    defined_flags = [Flag("END_STREAM", 0x01), Flag("END_HEADERS", 0x04), Flag("PADDED", 0x08), Flag("PRIORITY", 0x20)]
    type = 0x01
    stream_association = _STREAM_ASSOC_HAS_STREAM

    def __init__(self, stream_id, data=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        self.data = data

    def _body_repr(self):
        return "exclusive=%s, depends_on=%s, stream_weight=%s, data=%s" % (
            self.exclusive, self.depends_on, self.stream_weight, _raw_data_repr(self.data))

    def serialize_body(self):
        padding_data = self.serialize_padding_data()
        padding = b"\x00" * self.pad_length if "PADDED" in self.flags else b""
        priority_data = self.serialize_priority_data() if "PRIORITY" in self.flags else b""
        return padding_data + priority_data + bytes(self.data) + padding

    def parse_body(self, data):
        n = self.parse_padding_data(data)
        p = 0
        if "PRIORITY" in self.flags:
            p = self.parse_priority_data(data[n:])
        rest = len(data) - n - p
        if rest < 0:
            raise InvalidFrameError("Invalid HEADERS body")
        if self.pad_length and self.pad_length > rest:
            raise InvalidPaddingError("Padding is too long.")
        self.body_len = len(data)
        self.data = bytes(data[n + p:len(data) - self.pad_length])


class ContinuationFrame(Frame):
    """CONTINUATION (0x9): the rest of a field block (HEADERS / PUSH_PROMISE)."""
    defined_flags = [Flag("END_HEADERS", 0x04)]
    type = 0x09
    stream_association = _STREAM_ASSOC_HAS_STREAM

    def __init__(self, stream_id, data=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        self.data = data

    def _body_repr(self):
        return "data=%s" % _raw_data_repr(self.data)

    def serialize_body(self):
        return bytes(self.data)

    def parse_body(self, data):
        self.data = bytes(data)
        self.body_len = len(data)


class AltSvcFrame(Frame):
    """ALTSVC (0xa, RFC 7838): an alternative service for an origin."""
    defined_flags = []
    type = 0xA
    stream_association = _STREAM_ASSOC_EITHER

    def __init__(self, stream_id, origin=b"", field=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        if not isinstance(origin, bytes):
            raise InvalidDataError("AltSvc origin must be bytestring.")
        if not isinstance(field, bytes):
            raise InvalidDataError("AltSvc field must be a bytestring.")
        self.origin = origin
        self.field = field

    def _body_repr(self):
        return "origin=%r, field=%r" % (self.origin, self.field)

    def serialize_body(self):
        n = len(self.origin)
        return bytes([(n >> 8) & 0xFF, n & 0xFF]) + self.origin + self.field

    def parse_body(self, data):
        if len(data) < 2:
            raise InvalidFrameError("Invalid ALTSVC frame body.")
        n = (data[0] << 8) | data[1]
        if len(data) < 2 + n:
            raise InvalidFrameError("Invalid ALTSVC frame body.")
        self.origin = bytes(data[2:2 + n])
        self.field = bytes(data[2 + n:])
        self.body_len = len(data)


class PriorityUpdateFrame(Frame):
    """PRIORITY_UPDATE (0x10, RFC 9218 7.1): a client's new priority for a
    stream, the Priority header field's text. Not in hyperframe."""
    defined_flags = []
    type = 0x10
    stream_association = _STREAM_ASSOC_NO_STREAM

    def __init__(self, stream_id=0, prioritized_stream_id=0, priority_field_value=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        self.prioritized_stream_id = prioritized_stream_id
        self.priority_field_value = priority_field_value

    def _body_repr(self):
        return "prioritized_stream_id=%s, priority_field_value=%r" % (self.prioritized_stream_id, self.priority_field_value)

    def serialize_body(self):
        return _p32(self.prioritized_stream_id & 0x7FFFFFFF) + bytes(self.priority_field_value)

    def parse_body(self, data):
        if len(data) < 4:
            raise InvalidFrameError("PRIORITY_UPDATE frame must have at least 4 bytes: got %d" % len(data))
        self.prioritized_stream_id = _u32(data, 0) & 0x7FFFFFFF
        self.priority_field_value = bytes(data[4:])
        self.body_len = len(data)


class ExtensionFrame(Frame):
    """A frame of a type this module does not know: its flags and payload as
    they came."""
    stream_association = _STREAM_ASSOC_EITHER

    def __init__(self, type, stream_id, flag_byte=0x0, body=b"", **kwargs):
        super().__init__(stream_id, **kwargs)
        self.type = type
        self.flag_byte = flag_byte
        self.body = body

    def _body_repr(self):
        return "type=%s, flag_byte=%s, body=%s" % (self.type, self.flag_byte, _raw_data_repr(self.body))

    def parse_flags(self, flag_byte):
        self.flag_byte = flag_byte

    def parse_body(self, data):
        self.body = bytes(data)
        self.body_len = len(data)

    def serialize(self):
        n = len(self.body)
        flags = self.flag_byte
        header = bytes([(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF, self.type, flags]) + _p32(self.stream_id & 0x7FFFFFFF)
        return header + bytes(self.body)


_FRAME_CLASSES = [DataFrame, HeadersFrame, PriorityFrame, RstStreamFrame, SettingsFrame, PushPromiseFrame,
                  PingFrame, GoAwayFrame, WindowUpdateFrame, ContinuationFrame, AltSvcFrame, PriorityUpdateFrame]
FRAMES = {}
for _cls in _FRAME_CLASSES:
    FRAMES[_cls.type] = _cls
