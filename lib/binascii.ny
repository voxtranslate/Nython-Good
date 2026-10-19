# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/binascii.ny - Python's binascii (rounds 77, 79): conversions between
# binary data and ASCII encodings, with CPython's results and messages.
#
#     import binascii
#     binascii.hexlify(b"\xb9\x01\xef", "-", 2)     # b'b9-01ef'
#     binascii.crc32(b"hello"), binascii.crc_hqx(b"hello", 0)
#
# hexlify / b2a_hex (sep, bytes_per_sep: groups counted from the right, or
# from the left when negative), unhexlify / a2b_hex, b2a_base64 (newline=),
# a2b_base64 (strict_mode=), crc32 (zlib's), crc_hqx (CRC-CCITT, as binhex
# uses), b2a_qp / a2b_qp (quoted-printable, RFC 1521: quotetabs, istext,
# header), b2a_uu / a2b_uu (backtick=), Error (a ValueError), Incomplete.
# The a2b_* functions take ASCII str as well as bytes.
#
# Not here: nothing of the 3.11 module is missing (the binhex functions
# a2b_hqx/b2a_hqx/rlecode_hqx/rledecode_hqx were removed in Python 3.11).

class Error(ValueError):
    pass

class Incomplete(Exception):
    pass


def _bin(data):
    # any bytes-like object (round 84: memoryview, array, mmap ...)
    return _ny_bytes_like(data)


# a2b_* input: bytes, or a str of ASCII characters
def _ascii(data):
    if isinstance(data, str):
        for ch in data:
            if ord(ch) > 127:
                raise ValueError("string argument should contain only ASCII characters")
        return data.encode("ascii")
    if isinstance(data, bytes) or isinstance(data, bytearray):
        return data
    if _ny_is_exporter(data):
        return _ny_bytes_like(data)
    raise TypeError("argument should be bytes, buffer or ASCII string, not '" + type(data).__name__ + "'")


def hexlify(data, sep=None, bytes_per_sep=1):
    var h = bytes(_bin(data)).hex()
    if sep is None or len(h) == 0 or bytes_per_sep == 0:
        return h.encode("ascii")
    var s = sep
    if isinstance(s, str):
        if len(s) != 1:
            raise ValueError("sep must be length 1.")
        if ord(s) > 127:
            raise ValueError("sep must be ASCII.")
    elif isinstance(s, bytes) or isinstance(s, bytearray):
        if len(s) != 1:
            raise ValueError("sep must be length 1.")
        s = bytes(s).decode("latin-1")
    else:
        len(s)    # TypeError: object of type ... has no len()
        raise TypeError("sep must be str or bytes.")
    var n = bytes_per_sep if bytes_per_sep > 0 else -bytes_per_sep
    var nb = len(h) // 2
    var parts = []
    if bytes_per_sep > 0:
        # groups of n bytes counted from the right
        var first = nb % n
        if first:
            parts.append(h[0:2 * first])
        var i = first
        while i < nb:
            parts.append(h[2 * i:2 * (i + n)])
            i = i + n
    else:
        var i = 0
        while i < nb:
            parts.append(h[2 * i:2 * min(i + n, nb)])
            i = i + n
    return s.join(parts).encode("latin-1")


def b2a_hex(data, sep=None, bytes_per_sep=1):
    return hexlify(data, sep, bytes_per_sep)


def unhexlify(hexstr):
    var t = _ascii(hexstr)
    if len(t) % 2 != 0:
        raise Error("Odd-length string")
    try:
        return bytes.fromhex(bytes(t).decode("ascii"))
    except ValueError:
        raise Error("Non-hexadecimal digit found") from None


def a2b_hex(hexstr):
    return unhexlify(hexstr)


def b2a_base64(data, newline=True):
    var e = _hash_b64encode(bytes(_bin(data)))
    if newline:
        return e + b"\n"
    return e


_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
_B64_INDEX = {}
for _i in range(64):
    _B64_INDEX[ord(_B64[_i])] = _i


# CPython's binascii_a2b_base64_impl, step for step (its messages, its
# handling of padding in the middle and of characters outside the alphabet)
def _a2b_base64_exact(d, strict_mode):
    var n = len(d)
    if strict_mode and n > 0 and d[0] == 61:
        raise Error("Leading padding not allowed")
    var out = bytearray()
    var quad_pos = 0
    var leftchar = 0
    var pads = 0
    var padding_started = False
    var i = 0
    while i < n:
        var ch = d[i]
        if ch == 61:
            padding_started = True
            if strict_mode and quad_pos == 0:
                raise Error("Excess padding not allowed")
            if quad_pos >= 2:
                pads = pads + 1
                if quad_pos + pads >= 4:
                    if strict_mode and i + 1 < n:
                        raise Error("Excess data after padding")
                    return bytes(out)
            i = i + 1
            continue
        var v = _B64_INDEX.get(ch, 64)
        if v >= 64:
            if strict_mode:
                raise Error("Only base64 data is allowed")
            i = i + 1
            continue
        if strict_mode and padding_started:
            raise Error("Discontinuous padding not allowed")
        pads = 0
        if quad_pos == 0:
            quad_pos = 1
            leftchar = v
        elif quad_pos == 1:
            quad_pos = 2
            out.append(((leftchar << 2) | (v >> 4)) & 255)
            leftchar = v & 15
        elif quad_pos == 2:
            quad_pos = 3
            out.append(((leftchar << 4) | (v >> 2)) & 255)
            leftchar = v & 3
        else:
            quad_pos = 0
            out.append(((leftchar << 6) | v) & 255)
            leftchar = 0
        i = i + 1
    if quad_pos != 0:
        if quad_pos == 1:
            raise Error("Invalid base64-encoded string: number of data characters ("
                        + str(len(out) // 3 * 4 + 1) + ") cannot be 1 more than a multiple of 4")
        raise Error("Incorrect padding")
    return bytes(out)


def a2b_base64(data, strict_mode=False):
    var d = bytes(_ascii(data))
    if not strict_mode:
        # the native decoder for well-formed input; anything it refuses is
        # decided (result or message) by the exact one
        try:
            return _hash_b64decode(d, None, False)
        except ValueError:
            pass
    return _a2b_base64_exact(d, strict_mode)


def crc32(data, value=0):
    return _zlib_crc32(bytes(_bin(data)), value & 0xffffffff)


def crc_hqx(data, value):
    return _zlib_crc_hqx(bytes(_bin(data)), value & 0xffff)


# ── quoted-printable (CPython's binascii.c, line for line) ──────────────────
_HEXU = "0123456789ABCDEF"
_MAXLINESIZE = 76


def _qp_hex(c):
    return [61, ord(_HEXU[c >> 4]), ord(_HEXU[c & 15])]


def b2a_qp(data, quotetabs=False, istext=True, header=False):
    var d = bytes(_bin(data))
    var n = len(d)
    var crlf = False
    var p = d.find(b"\n")
    if p > 0 and d[p - 1] == 13:
        crlf = True
    var out = bytearray()
    var i = 0
    var linelen = 0
    while i < n:
        var c = d[i]
        var nxt = d[i + 1] if i + 1 < n else -1
        if (c > 126 or c == 61 or (header and c == 95)
                or (c == 46 and linelen == 0 and (i + 1 == n or nxt == 10 or nxt == 13 or nxt == 0))
                or (not istext and (c == 13 or c == 10))
                or ((c == 9 or c == 32) and i + 1 == n)
                or (c < 33 and c != 13 and c != 10 and (quotetabs or (c != 9 and c != 32)))):
            if linelen + 3 >= _MAXLINESIZE:
                out.append(61)
                if crlf:
                    out.append(13)
                out.append(10)
                linelen = 0
            out.extend(_qp_hex(c))
            i = i + 1
            linelen = linelen + 3
        elif istext and (c == 10 or (i + 1 < n and c == 13 and nxt == 10)):
            linelen = 0
            # whitespace before a line end is protected
            if len(out) and (out[-1] == 32 or out[-1] == 9):
                var ch = out[-1]
                out[-1] = 61
                out.append(ord(_HEXU[ch >> 4]))
                out.append(ord(_HEXU[ch & 15]))
            if crlf:
                out.append(13)
            out.append(10)
            i = i + (2 if c == 13 else 1)
        else:
            if i + 1 != n and nxt != 10 and linelen + 1 >= _MAXLINESIZE:
                out.append(61)
                if crlf:
                    out.append(13)
                out.append(10)
                linelen = 0
            linelen = linelen + 1
            if header and c == 32:
                out.append(95)
            else:
                out.append(c)
            i = i + 1
    return bytes(out)


def _hexval(c):
    if 48 <= c <= 57:
        return c - 48
    if 65 <= c <= 70:
        return c - 55
    if 97 <= c <= 102:
        return c - 87
    return -1


def a2b_qp(data, header=False):
    var d = bytes(_ascii(data))
    var n = len(d)
    var out = bytearray()
    var i = 0
    while i < n:
        var c = d[i]
        if c == 61:
            i = i + 1
            if i >= n:
                break
            # soft line break
            if d[i] == 10 or d[i] == 13:
                if d[i] != 10:
                    while i < n and d[i] != 10:
                        i = i + 1
                if i < n:
                    i = i + 1
            elif d[i] == 61:
                out.append(61)
                i = i + 1
            elif i + 1 < n and _hexval(d[i]) >= 0 and _hexval(d[i + 1]) >= 0:
                out.append(_hexval(d[i]) * 16 + _hexval(d[i + 1]))
                i = i + 2
            else:
                out.append(61)
        elif header and c == 95:
            out.append(32)
            i = i + 1
        else:
            out.append(c)
            i = i + 1
    return bytes(out)


# ── uuencode ────────────────────────────────────────────────────────────────
def b2a_uu(data, backtick=False):
    var d = bytes(_bin(data))
    var n = len(d)
    if n > 45:
        raise Error("At most 45 bytes at once")
    var out = bytearray()
    if backtick and n == 0:
        out.append(96)
    else:
        out.append(32 + n)
    var leftchar = 0
    var leftbits = 0
    var i = 0
    var left = n
    while left > 0 or leftbits != 0:
        if left > 0:
            leftchar = ((leftchar << 8) | d[i]) & 0xffffff
        else:
            leftchar = (leftchar << 8) & 0xffffff
        leftbits = leftbits + 8
        while leftbits >= 6:
            var ch = (leftchar >> (leftbits - 6)) & 0x3f
            leftbits = leftbits - 6
            if backtick and ch == 0:
                out.append(96)
            else:
                out.append(ch + 32)
        left = left - 1
        i = i + 1
    out.append(10)
    return bytes(out)


def a2b_uu(data):
    var d = bytes(_ascii(data))
    var n = len(d)
    var pos = 0
    var first = d[0] if n > 0 else 0
    var bin_len = (first - 32) & 0o77
    pos = 1
    var alen = n - 1
    var out = bytearray()
    var leftchar = 0
    var leftbits = 0
    while bin_len > 0:
        var ch = d[pos] if alen > 0 else 0
        if ch == 10 or ch == 13 or alen <= 0:
            ch = 0
        else:
            if ch < 32 or ch > 96:
                raise Error("Illegal char")
            ch = (ch - 32) & 0o77
        leftchar = (leftchar << 6) | ch
        leftbits = leftbits + 6
        if leftbits >= 8:
            leftbits = leftbits - 8
            out.append((leftchar >> leftbits) & 0xff)
            leftchar = leftchar & ((1 << leftbits) - 1)
            bin_len = bin_len - 1
        alen = alen - 1
        pos = pos + 1
    while alen > 0:
        var ch = d[pos]
        if ch != 32 and ch != 96 and ch != 10 and ch != 13:
            raise Error("Trailing garbage")
        pos = pos + 1
        alen = alen - 1
    return bytes(out)


def adler32(data, value=1):
    # (not CPython's binascii - kept for older Nython code)
    return _zlib_adler32(bytes(_bin(data)), value & 0xffffffff)
