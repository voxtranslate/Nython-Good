# nython: module    (import it by name: it runs in a module scope of its own)
# lib/hashlib.ny - Python's hashlib (round 77): md5, sha1, sha224/256/384/512,
# sha3_224/256/384/512, shake_128/256, blake2b/blake2s, new(name),
# pbkdf2_hmac, file_digest. The digests are NyHash.hpp's, the same on every
# platform; incremental (update) and copyable (copy).
#
#     import hashlib
#     hashlib.sha256(b"abc").hexdigest()
#     h = hashlib.blake2b(digest_size=16, key=b"secret"); h.update(data)

algorithms_guaranteed = set(_hash_algorithms())
algorithms_available = set(_hash_algorithms())

class _Hash:
    def __init__(self, handle):
        self._h = handle
        var info = _hash_info(handle)
        self.name = info[0]
        self.digest_size = info[1]
        self.block_size = info[2]

    def update(self, data):
        _hash_update(self._h, data)

    def digest(self, length=none):
        if length != none:
            return _hash_digest(self._h, length)
        return _hash_digest(self._h)

    def hexdigest(self, length=none):
        return self.digest(length).hex()

    def copy(self):
        return _Hash(_hash_copy(self._h))

    def __del__(self):
        _hash_free(self._h)

    def __repr__(self):
        return "<" + self.name + " _hashlib.HASH object>"

def _new(name, data=b"", digest_size=0, key=b""):
    var h = _hash_new(name, data, digest_size, key)
    if h == none:
        raise ValueError("unsupported hash type " + str(name))
    return _Hash(h)

# (`new` is also Nython's construction keyword: this module calls _new)
def new(name, data=b"", **kwargs):
    return _new(name, data, kwargs.get("digest_size", 0), kwargs.get("key", b""))

def md5(data=b"", **kwargs):
    return _new("md5", data)

def sha1(data=b"", **kwargs):
    return _new("sha1", data)

def sha224(data=b"", **kwargs):
    return _new("sha224", data)

def sha256(data=b"", **kwargs):
    return _new("sha256", data)

def sha384(data=b"", **kwargs):
    return _new("sha384", data)

def sha512(data=b"", **kwargs):
    return _new("sha512", data)

def sha3_224(data=b"", **kwargs):
    return _new("sha3_224", data)

def sha3_256(data=b"", **kwargs):
    return _new("sha3_256", data)

def sha3_384(data=b"", **kwargs):
    return _new("sha3_384", data)

def sha3_512(data=b"", **kwargs):
    return _new("sha3_512", data)

def shake_128(data=b"", **kwargs):
    return _new("shake_128", data)

def shake_256(data=b"", **kwargs):
    return _new("shake_256", data)

def blake2b(data=b"", digest_size=64, key=b"", **kwargs):
    var h = _hash_new("blake2b", data, digest_size, key)
    return _Hash(h)

def blake2s(data=b"", digest_size=32, key=b"", **kwargs):
    var h = _hash_new("blake2s", data, digest_size, key)
    return _Hash(h)

def pbkdf2_hmac(hash_name, password, salt, iterations, dklen=none):
    return _hash_pbkdf2(hash_name, password, salt, iterations, dklen)

def file_digest(fileobj, digest):
    var h = digest
    if isinstance(digest, "str"):
        h = _new(digest)
    elif callable(digest):
        h = digest()
    var chunk = fileobj.read(65536)
    while len(chunk) > 0:
        if isinstance(chunk, "str"):
            chunk = chunk.encode()
        h.update(chunk)
        chunk = fileobj.read(65536)
    return h
