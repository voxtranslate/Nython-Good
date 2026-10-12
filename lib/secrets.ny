# nython: module    (import it by name: it runs in a module scope of its own)
# lib/secrets.ny - Python's secrets (round 77) over the OS's random source
# (os_urandom: /dev/urandom, RtlGenRandom on Windows).
import base64

DEFAULT_ENTROPY = 32

def token_bytes(nbytes=none):
    if nbytes == none:
        nbytes = DEFAULT_ENTROPY
    return os_urandom(nbytes)

def token_hex(nbytes=none):
    return token_bytes(nbytes).hex()

def token_urlsafe(nbytes=none):
    var t = base64.urlsafe_b64encode(token_bytes(nbytes))
    return t.rstrip(b"=").decode("ascii")

def randbits(k):
    if k <= 0:
        return 0
    var n = (k + 7) // 8
    return int.from_bytes(os_urandom(n), "big") >> (n * 8 - k)

def randbelow(n):
    if n <= 0:
        raise ValueError("Upper bound must be positive.")
    var k = n.bit_length()
    var r = randbits(k)
    while r >= n:
        r = randbits(k)
    return r

def choice(seq):
    if len(seq) == 0:
        raise IndexError("Cannot choose from an empty sequence")
    return seq[randbelow(len(seq))]

def compare_digest(a, b):
    return _hash_compare(a, b)

class SystemRandom:
    def random(self):
        return randbits(53) / 9007199254740992.0
    def randint(self, a, b):
        return a + randbelow(b - a + 1)
    def choice(self, seq):
        return choice(seq)
    def randbytes(self, n):
        return os_urandom(n)
