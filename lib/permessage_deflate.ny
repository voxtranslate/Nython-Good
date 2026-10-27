# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/permessage_deflate.ny - the WebSocket "permessage-deflate" extension
# (RFC 7692; round 86): negotiation and compression, as lib/websocket.ny and
# lib/websocket_asyncio.ny use it. The API follows the websockets package's
# (ClientPerMessageDeflateFactory / ServerPerMessageDeflateFactory /
# PerMessageDeflate).
#
#     f = ClientPerMessageDeflateFactory()
#     offer = build_extensions([(f.name, f.get_request_params())])
#             -> "permessage-deflate; client_max_window_bits"
#     ext = f.process_response_params(parse_extensions(response_header)[0][1], [])
#     rsv1, payload = ext.encode_frame(OP_TEXT, True, b"Hello")   per frame
#     data = ext.decode_frame(OP_TEXT, True, rsv1, payload, max_size)
#
# parse_extensions(header) / build_extensions(list): the
#     Sec-WebSocket-Extensions grammar (RFC 6455 9.1: tokens, quoted-string
#     values, several offers) <-> [(name, [(param, value or None)])]
# ClientPerMessageDeflateFactory(server_no_context_takeover=False,
#     client_no_context_takeover=False, server_max_window_bits=None,
#     client_max_window_bits=True, compress_settings=None): the offer, and the
#     checks on the server's answer (RFC 7692 7.1: an unknown or repeated
#     parameter, a server_max_window_bits larger than asked, a
#     client_max_window_bits that was not offered, a dropped
#     server_no_context_takeover - NegotiationError)
# ServerPerMessageDeflateFactory(server_no_context_takeover=False,
#     client_no_context_takeover=False, server_max_window_bits=None,
#     client_max_window_bits=None, compress_settings=None,
#     require_client_max_window_bits=False): accepts or declines an offer and
#     builds the answer
# PerMessageDeflate(remote_no_context_takeover, local_no_context_takeover,
#     remote_max_window_bits, local_max_window_bits, compress_settings):
#     encode_frame(opcode, fin, data) -> (rsv1, payload); decode_frame(opcode,
#     fin, rsv1, payload, max_size=None) -> data. Messages are compressed with
#     raw DEFLATE (zlib wbits = -N), flushed with Z_SYNC_FLUSH and the final
#     0x00 0x00 0xff 0xff removed (7.2.1); RSV1 marks the first frame of a
#     compressed message only (6.1): set on a continuation or a control frame
#     it is a ProtocolError; the LZ77 window carries over between messages
#     unless *_no_context_takeover was agreed (7.2.2); a final DEFLATE block
#     (BFINAL) from the peer starts a fresh decompressor; decompressed
#     messages over max_size raise PayloadTooBig before they are inflated
#     whole (a decompression bomb is stopped at max_size).
# min_size (Nython's, both factories): messages shorter than this are sent
#     uncompressed (RSV1 clear - allowed per message, 6.1): a few bytes of
#     text compress to more than they are.
#
# Window bits: 8 is valid in RFC 7692 but zlib cannot compress with a 256-byte
# raw window; asked for 8, the compressor uses 9 bits, whose matches never
# reach back more than 2^9 - 262 = 250 bytes (zlib's MAX_DIST), so the peer's
# 256-byte window holds them all (the websockets package refuses 8 instead).
#
# Written in the subset of the language CPython also runs (over CPython's zlib
# there, lib/zlib.ny - the native DEFLATE - in Nython).
import zlib

__all__ = ["PerMessageDeflate", "ClientPerMessageDeflateFactory", "ServerPerMessageDeflateFactory",
           "parse_extensions", "build_extensions", "NegotiationError", "ProtocolError", "PayloadTooBig",
           "EXTENSION_NAME"]

EXTENSION_NAME = "permessage-deflate"
_EMPTY_BLOCK = b"\x00\x00\xff\xff"
_OP_CONT = 0
_OP_TEXT = 1
_OP_BINARY = 2


class NegotiationError(ValueError):
    """The extension's parameters cannot be agreed (or the answer breaks RFC 7692)."""


class ProtocolError(ValueError):
    """A frame breaks RFC 7692 (RSV1 misuse, a corrupt DEFLATE stream): close with 1002."""


class PayloadTooBig(ValueError):
    """A message inflates past max_size: close with 1009."""


# ── the header grammar (RFC 6455 9.1, RFC 7230 3.2.6) ──────────────────────

_TCHARS = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


def _token(s, i):
    j = i
    while j < len(s) and s[j] in _TCHARS:
        j += 1
    if j == i:
        raise NegotiationError("expected a token at %d in %r" % (i, s))
    return s[i:j], j


def _ows(s, i):
    while i < len(s) and s[i] in " \t":
        i += 1
    return i


def parse_extensions(header):
    """[(name, [(param, value or None), ...]), ...] of a Sec-WebSocket-Extensions value."""
    if isinstance(header, (list, tuple)):
        out = []
        for h in header:
            out.extend(parse_extensions(h))
        return out
    s = header
    out = []
    i = _ows(s, 0)
    while i < len(s):
        if s[i] == ",":
            i = _ows(s, i + 1)
            continue
        name, i = _token(s, i)
        params = []
        i = _ows(s, i)
        while i < len(s) and s[i] == ";":
            i = _ows(s, i + 1)
            pname, i = _token(s, i)
            i = _ows(s, i)
            value = None
            if i < len(s) and s[i] == "=":
                i = _ows(s, i + 1)
                if i < len(s) and s[i] == '"':
                    j = i + 1
                    chars = []
                    while j < len(s) and s[j] != '"':
                        if s[j] == "\\" and j + 1 < len(s):
                            j += 1
                        chars.append(s[j])
                        j += 1
                    if j >= len(s):
                        raise NegotiationError("unterminated quoted string in %r" % (s,))
                    value = "".join(chars)
                    # RFC 6455 9.1: a quoted value must still be a token
                    for c in value:
                        if c not in _TCHARS:
                            raise NegotiationError("invalid quoted parameter value %r" % (value,))
                    i = j + 1
                else:
                    value, i = _token(s, i)
                i = _ows(s, i)
            params.append((pname, value))
        out.append((name, params))
        i = _ows(s, i)
        if i < len(s) and s[i] != ",":
            raise NegotiationError("expected a comma at %d in %r" % (i, s))
    return out


def build_extensions(extensions):
    """The header value for [(name, [(param, value or None)])]."""
    parts = []
    for name, params in extensions:
        items = [name]
        for p, v in params:
            items.append(p if v is None else "%s=%s" % (p, v))
        parts.append("; ".join(items))
    return ", ".join(parts)


# ── the extension ──────────────────────────────────────────────────────────

class PerMessageDeflate:
    name = EXTENSION_NAME

    def __init__(self, remote_no_context_takeover, local_no_context_takeover, remote_max_window_bits,
                 local_max_window_bits, compress_settings=None, min_size=0):
        self.remote_no_context_takeover = remote_no_context_takeover
        self.local_no_context_takeover = local_no_context_takeover
        self.remote_max_window_bits = remote_max_window_bits
        self.local_max_window_bits = local_max_window_bits
        self.compress_settings = dict(compress_settings or {})
        self.min_size = min_size
        self._encoder = None
        self._decoder = None
        self._decoding = False        # inside a compressed message
        self._encoding = None         # inside a message: True compressed, False not
        self.bytes_in = 0             # payload octets before compression (sent)
        self.bytes_out = 0            # ... after
        self.messages_compressed = 0

    def __repr__(self):
        return ("PerMessageDeflate(remote_no_context_takeover=%r, local_no_context_takeover=%r, "
                "remote_max_window_bits=%r, local_max_window_bits=%r)" % (
                    self.remote_no_context_takeover, self.local_no_context_takeover,
                    self.remote_max_window_bits, self.local_max_window_bits))

    def _new_encoder(self):
        level = self.compress_settings.get("level", zlib.Z_DEFAULT_COMPRESSION)
        mem = self.compress_settings.get("memLevel", 8)
        bits = max(9, self.local_max_window_bits)
        return zlib.compressobj(level, zlib.DEFLATED, -bits, mem)

    def _new_decoder(self):
        return zlib.decompressobj(-self.remote_max_window_bits)

    def decode_frame(self, opcode, fin, rsv1, payload, max_size=None):
        """The frame's data as the application sees it (decompressed when the
        message is); ProtocolError / PayloadTooBig."""
        if opcode >= 8:
            if rsv1:
                raise ProtocolError("RSV1 set on a control frame")
            return payload
        if opcode == _OP_CONT:
            if rsv1:
                raise ProtocolError("RSV1 bit set in continuation frame")
            if not self._decoding:
                return payload
        else:
            if not rsv1:
                self._decoding = False
                return payload
            self._decoding = True
            if self.remote_no_context_takeover or self._decoder is None:
                self._decoder = self._new_decoder()
        data = payload
        if fin:
            data = data + _EMPTY_BLOCK
        dec = self._decoder
        try:
            if max_size is None:
                out = dec.decompress(data)
            else:
                out = dec.decompress(data, max_size + 1)
                if len(out) > max_size or dec.unconsumed_tail:
                    raise PayloadTooBig("message over %d bytes once decompressed" % max_size)
        except zlib.error as e:
            raise ProtocolError("decompression failed: %s" % e)
        if dec.eof:
            # the peer ended its DEFLATE stream (a BFINAL block): what follows,
            # if anything, is a new stream
            rest = dec.unused_data
            self._decoder = self._new_decoder()
            if rest and rest != _EMPTY_BLOCK:
                try:
                    out += self._decoder.decompress(rest)
                except zlib.error as e:
                    raise ProtocolError("decompression failed: %s" % e)
        if fin:
            self._decoding = False
            if self.remote_no_context_takeover:
                self._decoder = None
        return out

    def encode_frame(self, opcode, fin, data, message_size=None):
        """(rsv1, payload) of one frame of a message. message_size: the
        whole message's size on its first frame (min_size decides on it)."""
        if opcode >= 8:
            return False, data
        if opcode != _OP_CONT:
            size = len(data) if message_size is None else message_size
            self._encoding = size >= self.min_size
            if self._encoding and (self.local_no_context_takeover or self._encoder is None):
                self._encoder = self._new_encoder()
        if not self._encoding:
            if fin:
                self._encoding = None
            return False, data
        enc = self._encoder
        out = enc.compress(data) + enc.flush(zlib.Z_SYNC_FLUSH)
        if fin:
            if out.endswith(_EMPTY_BLOCK):
                out = out[:-4]
            self.messages_compressed += 1
        self.bytes_in += len(data)
        self.bytes_out += len(out)
        rsv1 = opcode != _OP_CONT
        if fin:
            self._encoding = None
            if self.local_no_context_takeover:
                self._encoder = None
        return rsv1, out


# ── negotiation ────────────────────────────────────────────────────────────

def _bits(name, value, allow_none):
    if value is None:
        if allow_none:
            return None
        raise NegotiationError("%s needs a value" % name)
    if not value.isdigit() or (len(value) > 1 and value[0] == "0"):
        raise NegotiationError("invalid %s value %r" % (name, value))
    v = int(value)
    if not (8 <= v <= 15):
        raise NegotiationError("%s must be between 8 and 15, got %d" % (name, v))
    return v


def _extract(params, is_server):
    # the four parameters of an offer or an answer; unknown/duplicate -> error
    server_no = False
    client_no = False
    server_bits = None
    client_bits = None
    seen = set()
    for name, value in params:
        if name in seen:
            raise NegotiationError("duplicate parameter %s" % name)
        seen.add(name)
        if name == "server_no_context_takeover":
            if value is not None:
                raise NegotiationError("server_no_context_takeover takes no value")
            server_no = True
        elif name == "client_no_context_takeover":
            if value is not None:
                raise NegotiationError("client_no_context_takeover takes no value")
            client_no = True
        elif name == "server_max_window_bits":
            server_bits = _bits(name, value, False)
        elif name == "client_max_window_bits":
            # an offer may say it without a value: "I support it"
            client_bits = _bits(name, value, not is_server)
            if client_bits is None:
                client_bits = True
        else:
            raise NegotiationError("unknown parameter %s" % name)
    return server_no, client_no, server_bits, client_bits


class ClientPerMessageDeflateFactory:
    name = EXTENSION_NAME

    def __init__(self, server_no_context_takeover=False, client_no_context_takeover=False,
                 server_max_window_bits=None, client_max_window_bits=True, compress_settings=None, min_size=0):
        if server_max_window_bits is not None and not (8 <= server_max_window_bits <= 15):
            raise ValueError("server_max_window_bits must be between 8 and 15")
        if client_max_window_bits not in (None, True) and not (8 <= client_max_window_bits <= 15):
            raise ValueError("client_max_window_bits must be between 8 and 15")
        if compress_settings is not None and "wbits" in compress_settings:
            raise ValueError("compress_settings must not include wbits, set client_max_window_bits instead")
        self.server_no_context_takeover = server_no_context_takeover
        self.client_no_context_takeover = client_no_context_takeover
        self.server_max_window_bits = server_max_window_bits
        self.client_max_window_bits = client_max_window_bits
        self.compress_settings = compress_settings
        self.min_size = min_size

    def get_request_params(self):
        params = []
        if self.server_no_context_takeover:
            params.append(("server_no_context_takeover", None))
        if self.client_no_context_takeover:
            params.append(("client_no_context_takeover", None))
        if self.server_max_window_bits is not None:
            params.append(("server_max_window_bits", str(self.server_max_window_bits)))
        if self.client_max_window_bits is True:
            params.append(("client_max_window_bits", None))
        elif self.client_max_window_bits is not None:
            params.append(("client_max_window_bits", str(self.client_max_window_bits)))
        return params

    def offer(self):
        return build_extensions([(self.name, self.get_request_params())])

    def process_response_params(self, params, accepted_extensions):
        if any(getattr(e, "name", None) == self.name for e in accepted_extensions):
            raise NegotiationError("received duplicate " + self.name)
        server_no, client_no, server_bits, client_bits = _extract(params, True)
        # server_no_context_takeover: we asked -> it must be there
        if self.server_no_context_takeover and not server_no:
            raise NegotiationError("expected server_no_context_takeover")
        # server_max_window_bits: at most what we asked for
        if self.server_max_window_bits is not None:
            if server_bits is None:
                raise NegotiationError("expected server_max_window_bits")
            if server_bits > self.server_max_window_bits:
                raise NegotiationError("unsupported server_max_window_bits")
        # client_max_window_bits: only if offered, at most our value
        if client_bits is not None:
            if self.client_max_window_bits is None:
                raise NegotiationError("unexpected client_max_window_bits")
            if self.client_max_window_bits is not True and client_bits > self.client_max_window_bits:
                raise NegotiationError("unsupported client_max_window_bits")
        else:
            if self.client_max_window_bits not in (None, True):
                client_bits = self.client_max_window_bits
        return PerMessageDeflate(server_no, client_no or self.client_no_context_takeover,
                                 server_bits or 15, client_bits if isinstance(client_bits, int) and client_bits is not True else 15,
                                 self.compress_settings, self.min_size)


class ServerPerMessageDeflateFactory:
    name = EXTENSION_NAME

    def __init__(self, server_no_context_takeover=False, client_no_context_takeover=False,
                 server_max_window_bits=None, client_max_window_bits=None, compress_settings=None,
                 require_client_max_window_bits=False, min_size=0):
        if server_max_window_bits is not None and not (8 <= server_max_window_bits <= 15):
            raise ValueError("server_max_window_bits must be between 8 and 15")
        if client_max_window_bits is not None and not (8 <= client_max_window_bits <= 15):
            raise ValueError("client_max_window_bits must be between 8 and 15")
        if compress_settings is not None and "wbits" in compress_settings:
            raise ValueError("compress_settings must not include wbits, set server_max_window_bits instead")
        if client_max_window_bits is None and require_client_max_window_bits:
            raise ValueError("require_client_max_window_bits is enabled, but client_max_window_bits isn't configured")
        self.server_no_context_takeover = server_no_context_takeover
        self.client_no_context_takeover = client_no_context_takeover
        self.server_max_window_bits = server_max_window_bits
        self.client_max_window_bits = client_max_window_bits
        self.compress_settings = compress_settings
        self.require_client_max_window_bits = require_client_max_window_bits
        self.min_size = min_size

    def process_request_params(self, params, accepted_extensions):
        """(answer params, PerMessageDeflate) for one offer; NegotiationError
        when it cannot be accepted (the server then tries the next offer)."""
        if any(getattr(e, "name", None) == self.name for e in accepted_extensions):
            raise NegotiationError("skipped duplicate " + self.name)
        server_no, client_no, server_bits, client_bits = _extract(params, False)
        # server_no_context_takeover: the client may ask for it; we may add it
        if self.server_no_context_takeover:
            server_no = True
        # client_no_context_takeover: our choice, the client must accept it
        if self.client_no_context_takeover:
            client_no = True
        # server_max_window_bits
        if self.server_max_window_bits is not None:
            if server_bits is None or self.server_max_window_bits < server_bits:
                server_bits = self.server_max_window_bits
        # client_max_window_bits: only if the client offered it
        if self.client_max_window_bits is not None:
            if client_bits is None:
                if self.require_client_max_window_bits:
                    raise NegotiationError("required client_max_window_bits")
            elif client_bits is True or self.client_max_window_bits < client_bits:
                client_bits = self.client_max_window_bits
        elif client_bits is True:
            client_bits = None
        answer = []
        if server_no:
            answer.append(("server_no_context_takeover", None))
        if client_no:
            answer.append(("client_no_context_takeover", None))
        if server_bits is not None:
            answer.append(("server_max_window_bits", str(server_bits)))
        if client_bits is not None:
            answer.append(("client_max_window_bits", str(client_bits)))
        ext = PerMessageDeflate(client_no, server_no, client_bits or 15, server_bits or 15,
                                self.compress_settings, self.min_size)
        return answer, ext

    def negotiate(self, header):
        """(answer header value, PerMessageDeflate) for a request's offers, or
        (None, None) when no permessage-deflate offer is acceptable."""
        try:
            offers = parse_extensions(header)
        except NegotiationError:
            return None, None
        for name, params in offers:
            if name != self.name:
                continue
            try:
                answer, ext = self.process_request_params(params, [])
            except NegotiationError:
                continue
            return build_extensions([(self.name, answer)]), ext
        return None, None
