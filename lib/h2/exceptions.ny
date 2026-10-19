# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/exceptions.ny - the h2 package's exceptions (round 86). Each
# ProtocolError carries the HTTP/2 error code its condition is sent as.
from h2.errors import ErrorCodes


class H2Error(Exception):
    """The base class for all exceptions for the HTTP/2 module."""


class ProtocolError(H2Error):
    """An action was attempted in violation of the HTTP/2 protocol."""
    error_code = ErrorCodes.PROTOCOL_ERROR


class FrameTooLargeError(ProtocolError):
    """The frame that we tried to send or that we received was too large."""
    error_code = ErrorCodes.FRAME_SIZE_ERROR


class FrameDataMissingError(ProtocolError):
    """The frame that we received is missing some data."""
    error_code = ErrorCodes.FRAME_SIZE_ERROR


class TooManyStreamsError(ProtocolError):
    """An attempt was made to open a stream that would lead to too many
    concurrent streams."""


class FlowControlError(ProtocolError):
    """An attempted action violates flow control constraints."""
    error_code = ErrorCodes.FLOW_CONTROL_ERROR


class StreamIDTooLowError(ProtocolError):
    """An attempt was made to open a stream that had an ID that is lower than
    the highest ID we have seen on this connection."""
    def __init__(self, stream_id, max_stream_id):
        self.stream_id = stream_id
        self.max_stream_id = max_stream_id
        ProtocolError.__init__(self, stream_id, max_stream_id)

    def __str__(self):
        return "StreamIDTooLowError: %d is lower than %d" % (self.stream_id, self.max_stream_id)


class NoAvailableStreamIDError(ProtocolError):
    """There are no available stream IDs left to the connection. All stream
    IDs have been exhausted."""


class NoSuchStreamError(ProtocolError):
    """A stream-specific action referenced a stream that does not exist."""
    def __init__(self, stream_id):
        self.stream_id = stream_id
        ProtocolError.__init__(self, stream_id)


class StreamClosedError(NoSuchStreamError):
    """A more specific form of NoSuchStreamError: the stream has been closed,
    and so no further action is possible on it."""
    error_code = ErrorCodes.STREAM_CLOSED

    def __init__(self, stream_id):
        NoSuchStreamError.__init__(self, stream_id)
        self._events = []


class InvalidSettingsValueError(ProtocolError, ValueError):
    """An attempt was made to set an invalid Settings value."""
    def __init__(self, msg, error_code):
        ProtocolError.__init__(self, msg)
        self.error_code = error_code


class InvalidBodyLengthError(ProtocolError):
    """The remote peer sent more or less data than the Content-Length header
    indicated."""
    def __init__(self, expected, actual):
        self.expected_length = expected
        self.actual_length = actual
        ProtocolError.__init__(self, expected, actual)

    def __str__(self):
        return "InvalidBodyLengthError: Expected %d bytes, received %d" % (self.expected_length, self.actual_length)


class UnsupportedFrameError(ProtocolError):
    """The remote peer sent a frame that is unsupported in this context."""


class RFC1122Error(H2Error):
    """Emitted when users attempt to do something that is literally allowed
    by the relevant RFC, but is sufficiently ill-defined that it's
    unwise to allow users to actually do it."""


class DenialOfServiceError(ProtocolError):
    """Emitted when the remote peer exhibits a behaviour that is likely to be
    an attempt to perform a Denial of Service attack on the implementation."""
    error_code = ErrorCodes.ENHANCE_YOUR_CALM
