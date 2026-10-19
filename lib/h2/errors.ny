# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/errors.ny - HTTP/2 error codes (RFC 9113 section 7; round 86), as
# the h2 package's h2.errors.
import enum

__all__ = ["ErrorCodes"]


class ErrorCodes(enum.IntEnum):
    """All known HTTP/2 error codes."""
    NO_ERROR = 0x0
    PROTOCOL_ERROR = 0x1
    INTERNAL_ERROR = 0x2
    FLOW_CONTROL_ERROR = 0x3
    SETTINGS_TIMEOUT = 0x4
    STREAM_CLOSED = 0x5
    FRAME_SIZE_ERROR = 0x6
    REFUSED_STREAM = 0x7
    CANCEL = 0x8
    COMPRESSION_ERROR = 0x9
    CONNECT_ERROR = 0xa
    ENHANCE_YOUR_CALM = 0xb
    INADEQUATE_SECURITY = 0xc
    HTTP_1_1_REQUIRED = 0xd


def _error_code_from_int(code):
    """The ErrorCodes member for code, or code itself when it is unknown (RFC
    9113 7: unknown codes MUST NOT trigger special behaviour)."""
    try:
        return ErrorCodes(code)
    except ValueError:
        return code
