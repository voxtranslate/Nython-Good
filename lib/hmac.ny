# nython: module    (import it by name: it runs in a module scope of its own)
# lib/hmac.ny - Python's hmac (RFC 2104, round 77) over lib/hashlib.ny.
#
#     import hmac
#     hmac.new(b"key", b"message", "sha256").hexdigest()
#     hmac.compare_digest(a, b)        constant time
import hashlib

def _algo(digestmod):
    if digestmod == none:
        raise TypeError("Missing required parameter 'digestmod'.")
    if isinstance(digestmod, "str"):
        return digestmod
    if callable(digestmod):
        return digestmod().name
    return digestmod.name

class HMAC:
    def __init__(self, key, msg=none, digestmod=none):
        self._algo = _algo(digestmod)
        var probe = hashlib._new(self._algo)
        self.digest_size = probe.digest_size
        self.block_size = probe.block_size
        self.name = "hmac-" + probe.name
        var k = bytes(key)
        if len(k) > self.block_size:
            k = hashlib._new(self._algo, k).digest()
        k = k + bytes(self.block_size - len(k))
        var ipad = bytearray(self.block_size)
        var opad = bytearray(self.block_size)
        for i in range(self.block_size):
            ipad[i] = k[i] ^ 0x36
            opad[i] = k[i] ^ 0x5C
        self._inner = hashlib._new(self._algo, bytes(ipad))
        self._outer = hashlib._new(self._algo, bytes(opad))
        if msg != none:
            self.update(msg)

    def update(self, msg):
        self._inner.update(msg)

    def copy(self):
        var c = HMAC(b"", none, self._algo)
        c._inner = self._inner.copy()
        c._outer = self._outer.copy()
        return c

    def digest(self):
        var o = self._outer.copy()
        o.update(self._inner.digest())
        return o.digest()

    def hexdigest(self):
        return self.digest().hex()

def new(key, msg=none, digestmod=none):
    return HMAC(key, msg, digestmod)

def digest(key, msg, digest):
    return _hash_hmac(_algo(digest), key, msg)

def compare_digest(a, b):
    return _hash_compare(a, b)
