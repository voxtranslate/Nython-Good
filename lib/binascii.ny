# nython: module    (import it by name: it runs in a module scope of its own)
# lib/binascii.ny - Python's binascii (round 77): hexlify/unhexlify,
# b2a_base64/a2b_base64, crc32, crc_hqx-less subset, Error.
class Error(ValueError):
    pass

class Incomplete(Exception):
    pass

def hexlify(data, sep=none):
    var h = bytes(data).hex()
    if sep != none:
        var s = sep
        if not isinstance(s, "str"):
            s = s.decode()
        var parts = []
        var i = 0
        while i < len(h):
            parts.append(h[i:i + 2])
            i = i + 2
        h = s.join(parts)
    return h.encode("ascii")

def b2a_hex(data, sep=none):
    return hexlify(data, sep)

def unhexlify(hexstr):
    var t = hexstr
    if not isinstance(t, "str"):
        t = t.decode("ascii")
    if len(t) % 2 != 0:
        raise Error("Odd-length string")
    try:
        return bytes.fromhex(t)
    except ValueError:
        raise Error("Non-hexadecimal digit found")

def a2b_hex(hexstr):
    return unhexlify(hexstr)

def b2a_base64(data, newline=true):
    var e = _hash_b64encode(bytes(data))
    if newline:
        return e + b"\n"
    return e

def a2b_base64(data, strict_mode=false):
    try:
        return _hash_b64decode(data, none, strict_mode)
    except ValueError as e:
        raise Error(str(e))

def crc32(data, value=0):
    return _hash_crc32(bytes(data), value)

def adler32(data, value=1):
    return _hash_adler32(bytes(data), value)
