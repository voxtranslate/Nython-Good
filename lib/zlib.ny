# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/zlib.ny - Python's zlib (round 79): DEFLATE (RFC 1951) with the zlib
# (RFC 1950) and gzip (RFC 1952) wrappers, over a native implementation
# written for Nython (src/builtins/nyzlib.cpp - no system zlib). Streams are
# interchangeable with CPython's: either side decompresses what the other
# compressed (the bytes themselves can differ from zlib's).
#
#     import zlib
#     z = zlib.compress(data, 9)            zlib.decompress(z) == data
#     c = zlib.compressobj(6, zlib.DEFLATED, -15)   raw deflate (zip's)
#     d = zlib.decompressobj(47)            zlib or gzip, detected
#     zlib.crc32(b"abc"), zlib.adler32(b"abc")
#
# compress(data, level=-1, wbits=15), decompress(data, wbits=15, bufsize=)
# compressobj(level, method, wbits, memLevel, strategy, zdict) -> Compress:
#     compress(data), flush(Z_NO_FLUSH | Z_PARTIAL_FLUSH | Z_SYNC_FLUSH |
#     Z_FULL_FLUSH | Z_BLOCK | Z_FINISH), copy()
# decompressobj(wbits, zdict) -> Decompress: decompress(data, max_length),
#     flush(length), copy(), unused_data, unconsumed_tail, eof
# crc32(data, value=0), adler32(data, value=1); the constants; zlib.error
# with zlib's messages ("Error -3 while decompressing data: invalid block
# type", "Error -5 ...: incomplete or truncated stream", ...).
# wbits: 9..15 zlib, -9..-15 raw, 25..31 gzip, 0 / 40..47 (decompression)
# the window the header names / zlib or gzip detected; preset dictionaries.
# Levels 0-9 trade hash-chain search and lazy matching as zlib's table does;
# dynamic Huffman codes are length-limited by package-merge (Larmore and
# Hirschberg 1990); each block is stored, fixed or dynamic, whichever is
# smallest.
#
# Nython-only (opt-in; compress() itself is never changed by it):
#     zlib.compress_optimal(data, iterations=15, wbits=15, block_splitting=True)
# an optimal parse after Zopfli (Alakuijala & Vandevenne, 2013): the LZ77
# choices are a shortest path under costs from the previous pass's symbol
# statistics, iterated, with blocks split where that pays. Standard DEFLATE
# out (CPython's zlib decompresses it), typically 3-8% smaller than level 9,
# at a much higher cost in time. compress(data, level, wbits,
# nython_optimal=True) is the same thing.
#
# Not here: the memLevel only sizes the hash table and the symbol buffer;
# Z_TREES behaves as Z_BLOCK; bufsize is a hint (the output grows as
# needed). Data is any bytes-like object (round 84: bytes, bytearray,
# memoryview, array.array, mmap ...).

__all__ = ["compress", "decompress", "compressobj", "decompressobj", "crc32", "adler32", "error",
           "compress_optimal"]

DEFLATED = 8
DEF_BUF_SIZE = 16384
DEF_MEM_LEVEL = 8
MAX_WBITS = 15
ZLIB_VERSION = "1.3"
ZLIB_RUNTIME_VERSION = "1.3"
Z_NO_COMPRESSION = 0
Z_BEST_SPEED = 1
Z_BEST_COMPRESSION = 9
Z_DEFAULT_COMPRESSION = -1
Z_DEFAULT_STRATEGY = 0
Z_FILTERED = 1
Z_HUFFMAN_ONLY = 2
Z_RLE = 3
Z_FIXED = 4
Z_NO_FLUSH = 0
Z_PARTIAL_FLUSH = 1
Z_SYNC_FLUSH = 2
Z_FULL_FLUSH = 3
Z_FINISH = 4
Z_BLOCK = 5
Z_TREES = 6


class error(Exception):
    pass


# The natives raise ValueError("[zlib] ...") for zlib.error.
def _reraise(e):
    var m = str(e)
    if m.startswith("[zlib] "):
        raise error(m[7:]) from None
    raise e


def _data(d):
    # any bytes-like object (round 84: memoryview, array, mmap ...)
    return _ny_bytes_like(d)


def _int(v, what):
    if isinstance(v, bool) or isinstance(v, int):
        return int(v)
    if hasattr(v, "__index__"):
        return v.__index__()
    raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")


def crc32(data, value=0):
    return _zlib_crc32(_data(data), _int(value, "value") & 0xffffffff)


def adler32(data, value=1):
    return _zlib_adler32(_data(data), _int(value, "value") & 0xffffffff)


def compress(data, level=-1, wbits=MAX_WBITS, nython_optimal=False):
    var d = _data(data)
    if nython_optimal:
        return compress_optimal(d, 15, wbits)
    try:
        return _zlib_compress(d, _int(level, "level"), _int(wbits, "wbits"))
    except ValueError as e:
        _reraise(e)


def compress_optimal(data, iterations=15, wbits=MAX_WBITS, block_splitting=True):
    var d = _data(data)
    try:
        return _zlib_optimal(d, _int(iterations, "iterations"), _int(wbits, "wbits"), bool(block_splitting))
    except ValueError as e:
        _reraise(e)


def decompress(data, wbits=MAX_WBITS, bufsize=DEF_BUF_SIZE):
    var d = _data(data)
    try:
        return _zlib_decompress(d, _int(wbits, "wbits"), _int(bufsize, "bufsize"))
    except ValueError as e:
        _reraise(e)


class Compress:
    def __init__(self, handle):
        self._h = handle

    def compress(self, data):
        var d = _data(data)
        try:
            return _zlib_ccompress(self._h, d)
        except ValueError as e:
            _reraise(e)

    def flush(self, mode=Z_FINISH):
        try:
            return _zlib_cflush(self._h, _int(mode, "mode"))
        except ValueError as e:
            _reraise(e)

    def copy(self):
        return Compress(_zlib_copy(self._h))

    def __copy__(self):
        return self.copy()

    def __deepcopy__(self, memo):
        return self.copy()

    def __del__(self):
        _zlib_free(self._h)

    def __repr__(self):
        return "<zlib.Compress object>"


class Decompress:
    def __init__(self, handle):
        self._h = handle
        self.unused_data = b""
        self.unconsumed_tail = b""
        self.eof = False

    def _take(self, r):
        self.unconsumed_tail = r[1]
        if r[3]:
            self.eof = True
        if len(r[2]):
            self.unused_data = self.unused_data + r[2]
        return r[0]

    def decompress(self, data, max_length=0):
        var d = _data(data)
        try:
            return self._take(_zlib_ddecompress(self._h, d, _int(max_length, "max_length")))
        except ValueError as e:
            _reraise(e)

    def flush(self, length=DEF_BUF_SIZE):
        try:
            return self._take(_zlib_dflush(self._h, self.unconsumed_tail, _int(length, "length")))
        except ValueError as e:
            _reraise(e)

    def copy(self):
        var c = Decompress(_zlib_copy(self._h))
        c.unused_data = self.unused_data
        c.unconsumed_tail = self.unconsumed_tail
        c.eof = self.eof
        return c

    def __copy__(self):
        return self.copy()

    def __deepcopy__(self, memo):
        return self.copy()

    def __del__(self):
        _zlib_free(self._h)

    def __repr__(self):
        return "<zlib.Decompress object>"


def compressobj(level=Z_DEFAULT_COMPRESSION, method=DEFLATED, wbits=MAX_WBITS, memLevel=DEF_MEM_LEVEL,
                strategy=Z_DEFAULT_STRATEGY, zdict=None):
    if zdict is not None:
        zdict = _data(zdict)
    return Compress(_zlib_cnew(_int(level, "level"), _int(method, "method"), _int(wbits, "wbits"),
                               _int(memLevel, "memLevel"), _int(strategy, "strategy"), zdict))


def decompressobj(wbits=MAX_WBITS, zdict=b""):
    var zd = None
    if zdict is not None and len(zdict):
        zd = _data(zdict)
    return Decompress(_zlib_dnew(_int(wbits, "wbits"), zd))
