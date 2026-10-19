# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/base64.ny - Python's base64 (RFC 4648, round 77).
import binascii

def _bytes(s):
    if isinstance(s, "str"):
        return s.encode("ascii")
    if isinstance(s, bytes) or isinstance(s, bytearray):
        return bytes(s)
    return bytes(_ny_bytes_like(s))      # round 84: any buffer (memoryview ...)

def b64encode(s, altchars=None):
    return _hash_b64encode(_bytes(s), altchars)

def b64decode(s, altchars=None, validate=False):
    try:
        return _hash_b64decode(_bytes(s), altchars, validate)
    except ValueError as e:
        raise binascii.Error(str(e))

def standard_b64encode(s):
    return b64encode(s)

def standard_b64decode(s):
    return b64decode(s)

def urlsafe_b64encode(s):
    return b64encode(s, b"-_")

def urlsafe_b64decode(s):
    return b64decode(s, b"-_")

def b32encode(s):
    return _hash_b32encode(_bytes(s))

def b32decode(s, casefold=False):
    try:
        return _hash_b32decode(_bytes(s))
    except ValueError as e:
        raise binascii.Error(str(e))

def b16encode(s):
    return _bytes(s).hex().upper().encode("ascii")

def b16decode(s, casefold=False):
    var t = _bytes(s).decode("ascii")
    try:
        return bytes.fromhex(t)
    except ValueError as e:
        raise binascii.Error(str(e))

def encodebytes(s):
    var e = b64encode(s)
    var out = b""
    var i = 0
    while i < len(e):
        out = out + e[i:i + 76] + b"\n"
        i = i + 76
    return out

def decodebytes(s):
    return b64decode(s)
