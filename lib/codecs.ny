# nython: module    (import it by name: it runs in a module scope of its own)
# lib/codecs.ny - Python's codecs module (round 80): the codec registry,
# its error handlers and the stream and incremental classes, after CPython
# 3.11's Lib/codecs.py and Modules/_codecsmodule.c.
#
#     import codecs
#     codecs.encode("é", "latin-1")                  # b'\xe9'
#     codecs.decode(b"68656c6c6f", "hex")            # b'hello'
#     codecs.lookup("UTF8").name                     # 'utf-8'
#     codecs.register_error("dots", lambda e: ("." * (e.end - e.start), e.end))
#     "naïve".encode("ascii", "dots")                # b'na.ve'
#     with codecs.open("f.txt", "w", "utf-16") as f: f.write("text")
#
# encode/decode (any codec: text, bytes-to-bytes, str-to-str), lookup and
# CodecInfo, register/unregister (search functions, consulted after the
# builtin codecs, as CPython's encodings), getencoder/getdecoder/
# getincrementalencoder/getincrementaldecoder/getreader/getwriter,
# iterencode/iterdecode, open, EncodedFile, Codec, IncrementalEncoder/
# Decoder, BufferedIncrementalEncoder/Decoder, StreamWriter/StreamReader/
# StreamReaderWriter/StreamRecoder, the BOM constants, register_error/
# lookup_error and the handler functions strict_errors, ignore_errors,
# replace_errors, backslashreplace_errors, xmlcharrefreplace_errors,
# namereplace_errors (and "surrogateescape"/"surrogatepass"); _codecs'
# utf_8_encode/decode, utf_16_*, utf_32_*, latin_1_*, ascii_*,
# unicode_escape_*, raw_unicode_escape_*, escape_encode/decode,
# charmap_encode/decode/build.
#
# Codecs: utf-8, utf-8-sig, utf-16, utf-16-le, utf-16-be, utf-32, utf-32-le,
# utf-32-be, latin-1, ascii, cp437, cp850, cp1252, mac-roman,
# unicode_escape, raw_unicode_escape (native: include/NyCodecs.hpp, the same
# table str.encode and bytes.decode use - with CPython's aliases, error
# positions, reasons and messages), idna and punycode, and the bytes-to-
# bytes hex, base64, zlib and quopri codecs and str-to-str rot13 (here).
# Every error handler works with every codec, in both directions where
# CPython has it: the builtin ones natively; one registered with
# register_error is called with the UnicodeEncodeError / UnicodeDecodeError
# and the codec resumes where it returns (str.encode and bytes.decode call
# it too, through the prelude's _ny_codec_encode/_ny_codec_decode).
#
# Not here: the other encodings package codecs (cp1251, shift_jis, the
# CJK codecs, utf-7, bz2_codec, uu_codec...); idna is "basic": nameprep is
# lower-casing (no Unicode normalization tables, no stringprep checks).

import sys

__all__ = ["register", "lookup", "open", "EncodedFile", "BOM", "BOM_BE",
           "BOM_LE", "BOM32_BE", "BOM32_LE", "BOM64_BE", "BOM64_LE",
           "BOM_UTF8", "BOM_UTF16", "BOM_UTF16_LE", "BOM_UTF16_BE",
           "BOM_UTF32", "BOM_UTF32_LE", "BOM_UTF32_BE",
           "CodecInfo", "Codec", "IncrementalEncoder", "IncrementalDecoder",
           "StreamReader", "StreamWriter",
           "StreamReaderWriter", "StreamRecoder",
           "getencoder", "getdecoder", "getincrementalencoder",
           "getincrementaldecoder", "getreader", "getwriter",
           "encode", "decode", "iterencode", "iterdecode",
           "strict_errors", "ignore_errors", "replace_errors",
           "xmlcharrefreplace_errors",
           "backslashreplace_errors", "namereplace_errors",
           "register_error", "lookup_error"]

_builtin_open = open

# ── constants ────────────────────────────────────────────────────────────────
BOM_UTF8 = b'\xef\xbb\xbf'
BOM_LE = BOM_UTF16_LE = b'\xff\xfe'
BOM_BE = BOM_UTF16_BE = b'\xfe\xff'
BOM_UTF32_LE = b'\xff\xfe\x00\x00'
BOM_UTF32_BE = b'\x00\x00\xfe\xff'
# every platform Nython runs on is little-endian
BOM = BOM_UTF16 = BOM_UTF16_LE
BOM_UTF32 = BOM_UTF32_LE
BOM32_LE = BOM_UTF16_LE
BOM32_BE = BOM_UTF16_BE
BOM64_LE = BOM_UTF32_LE
BOM64_BE = BOM_UTF32_BE


# ── codec base classes ───────────────────────────────────────────────────────
class CodecInfo(tuple):
    """Codec details when looking up the codec registry"""

    _is_text_encoding = True

    def __new__(cls, encode, decode, streamreader=None, streamwriter=None,
                incrementalencoder=None, incrementaldecoder=None, name=None,
                *, _is_text_encoding=None):
        var self = tuple.__new__(cls, (encode, decode, streamreader, streamwriter))
        self.name = name
        self.encode = encode
        self.decode = decode
        self.incrementalencoder = incrementalencoder
        self.incrementaldecoder = incrementaldecoder
        self.streamwriter = streamwriter
        self.streamreader = streamreader
        if _is_text_encoding is not None:
            self._is_text_encoding = _is_text_encoding
        return self

    def __repr__(self):
        return "<%s.%s object for encoding %s at %#x>" % (type(self).__module__, type(self).__qualname__,
                                                        self.name, id(self))


class Codec:
    """ Defines the interface for stateless encoders/decoders."""

    def encode(self, input, errors='strict'):
        raise NotImplementedError

    def decode(self, input, errors='strict'):
        raise NotImplementedError


class IncrementalEncoder(object):
    """An IncrementalEncoder encodes an input in multiple steps."""

    def __init__(self, errors='strict'):
        self.errors = errors
        self.buffer = ""

    def encode(self, input, final=False):
        raise NotImplementedError

    def reset(self):
        pass

    def getstate(self):
        return 0

    def setstate(self, state):
        pass


class BufferedIncrementalEncoder(IncrementalEncoder):
    """An IncrementalEncoder that keeps unencoded input in a buffer."""

    def __init__(self, errors='strict'):
        IncrementalEncoder.__init__(self, errors)
        self.buffer = ""

    def _buffer_encode(self, input, errors, final):
        raise NotImplementedError

    def encode(self, input, final=False):
        var data = self.buffer + input
        var r = self._buffer_encode(data, self.errors, final)
        self.buffer = data[r[1]:]
        return r[0]

    def reset(self):
        IncrementalEncoder.reset(self)
        self.buffer = ""

    def getstate(self):
        return self.buffer or 0

    def setstate(self, state):
        self.buffer = state or ""


class IncrementalDecoder(object):
    """An IncrementalDecoder decodes an input in multiple steps."""

    def __init__(self, errors='strict'):
        self.errors = errors

    def decode(self, input, final=False):
        raise NotImplementedError

    def reset(self):
        pass

    def getstate(self):
        return (b"", 0)

    def setstate(self, state):
        pass


class BufferedIncrementalDecoder(IncrementalDecoder):
    """An IncrementalDecoder that keeps undecoded input in a buffer."""

    def __init__(self, errors='strict'):
        IncrementalDecoder.__init__(self, errors)
        self.buffer = b""

    def _buffer_decode(self, input, errors, final):
        raise NotImplementedError

    def decode(self, input, final=False):
        var data = self.buffer + input
        var r = self._buffer_decode(data, self.errors, final)
        self.buffer = data[r[1]:]
        return r[0]

    def reset(self):
        IncrementalDecoder.reset(self)
        self.buffer = b""

    def getstate(self):
        return (self.buffer, 0)

    def setstate(self, state):
        self.buffer = state[0]


class StreamWriter(Codec):

    def __init__(self, stream, errors='strict'):
        self.stream = stream
        self.errors = errors

    def write(self, object):
        var r = self.encode(object, self.errors)
        self.stream.write(r[0])

    def writelines(self, list):
        self.write(''.join(list))

    def reset(self):
        pass

    def seek(self, offset, whence=0):
        self.stream.seek(offset, whence)
        if whence == 0 and offset == 0:
            self.reset()

    def __getattr__(self, name):
        return getattr(self.stream, name)

    def __enter__(self):
        return self

    def __exit__(self, type, value, tb):
        self.stream.close()

    def __reduce_ex__(self, proto):
        raise TypeError("can't serialize %s" % type(self).__name__)


class StreamReader(Codec):

    charbuffertype = str

    def __init__(self, stream, errors='strict'):
        self.stream = stream
        self.errors = errors
        self.bytebuffer = b""
        self._empty_charbuffer = self.charbuffertype()
        self.charbuffer = self._empty_charbuffer
        self.linebuffer = None

    def decode(self, input, errors='strict'):
        raise NotImplementedError

    def read(self, size=-1, chars=-1, firstline=False):
        if self.linebuffer:
            self.charbuffer = self._empty_charbuffer.join(self.linebuffer)
            self.linebuffer = None
        if chars < 0:
            chars = size
        while True:
            if chars >= 0:
                if len(self.charbuffer) >= chars:
                    break
            var newdata = self.stream.read() if size < 0 else self.stream.read(size)
            var data = self.bytebuffer + newdata
            if not data:
                break
            var r = None
            try:
                r = self.decode(data, self.errors)
            except UnicodeDecodeError as exc:
                if firstline:
                    r = self.decode(data[:exc.start], self.errors)
                    var lines = r[0].splitlines(keepends=True)
                    if len(lines) <= 1:
                        raise
                else:
                    raise
            self.bytebuffer = data[r[1]:]
            self.charbuffer += r[0]
            if not newdata:
                break
        var result = None
        if chars < 0:
            result = self.charbuffer
            self.charbuffer = self._empty_charbuffer
        else:
            result = self.charbuffer[:chars]
            self.charbuffer = self.charbuffer[chars:]
        return result

    def readline(self, size=None, keepends=True):
        var line = None
        if self.linebuffer:
            line = self.linebuffer[0]
            del self.linebuffer[0]
            if len(self.linebuffer) == 1:
                self.charbuffer = self.linebuffer[0]
                self.linebuffer = None
            if not keepends:
                line = line.splitlines(keepends=False)[0]
            return line
        var readsize = size or 72
        line = self._empty_charbuffer
        while True:
            var data = self.read(readsize, firstline=True)
            if data:
                if data.endswith("\r"):
                    data += self.read(size=1, chars=1)
            line += data
            var lines = line.splitlines(keepends=True)
            if lines:
                if len(lines) > 1:
                    line = lines[0]
                    del lines[0]
                    if len(lines) > 1:
                        lines[-1] += self.charbuffer
                        self.linebuffer = lines
                        self.charbuffer = None
                    else:
                        self.charbuffer = lines[0] + self.charbuffer
                    if not keepends:
                        line = line.splitlines(keepends=False)[0]
                    break
                var line0withend = lines[0]
                var line0withoutend = lines[0].splitlines(keepends=False)[0]
                if line0withend != line0withoutend:
                    self.charbuffer = self._empty_charbuffer.join(lines[1:]) + self.charbuffer
                    if keepends:
                        line = line0withend
                    else:
                        line = line0withoutend
                    break
            if not data or size is not None:
                if line and not keepends:
                    line = line.splitlines(keepends=False)[0]
                break
            if readsize < 8000:
                readsize *= 2
        return line

    def readlines(self, sizehint=None, keepends=True):
        var data = self.read()
        return data.splitlines(keepends)

    def reset(self):
        self.bytebuffer = b""
        self.charbuffer = self._empty_charbuffer
        self.linebuffer = None

    def seek(self, offset, whence=0):
        self.stream.seek(offset, whence)
        self.reset()

    def __next__(self):
        var line = self.readline()
        if line:
            return line
        raise StopIteration

    def __iter__(self):
        return self

    def __getattr__(self, name):
        return getattr(self.stream, name)

    def __enter__(self):
        return self

    def __exit__(self, type, value, tb):
        self.stream.close()

    def __reduce_ex__(self, proto):
        raise TypeError("can't serialize %s" % type(self).__name__)


class StreamReaderWriter:

    encoding = 'unknown'

    def __init__(self, stream, Reader, Writer, errors='strict'):
        self.stream = stream
        self.reader = Reader(stream, errors)
        self.writer = Writer(stream, errors)
        self.errors = errors

    def read(self, size=-1):
        return self.reader.read(size)

    def readline(self, size=None):
        return self.reader.readline(size)

    def readlines(self, sizehint=None):
        return self.reader.readlines(sizehint)

    def __next__(self):
        return next(self.reader)

    def __iter__(self):
        return self

    def write(self, data):
        return self.writer.write(data)

    def writelines(self, list):
        return self.writer.writelines(list)

    def reset(self):
        self.reader.reset()
        self.writer.reset()

    def seek(self, offset, whence=0):
        self.stream.seek(offset, whence)
        self.reader.reset()
        if whence == 0 and offset == 0:
            self.writer.reset()

    def __getattr__(self, name):
        return getattr(self.stream, name)

    def __enter__(self):
        return self

    def __exit__(self, type, value, tb):
        self.stream.close()

    def __reduce_ex__(self, proto):
        raise TypeError("can't serialize %s" % type(self).__name__)


class StreamRecoder:

    data_encoding = 'unknown'
    file_encoding = 'unknown'

    def __init__(self, stream, encode, decode, Reader, Writer, errors='strict'):
        self.stream = stream
        self.encode = encode
        self.decode = decode
        self.reader = Reader(stream, errors)
        self.writer = Writer(stream, errors)
        self.errors = errors

    def read(self, size=-1):
        var data = self.reader.read(size)
        return self.encode(data, self.errors)[0]

    def readline(self, size=None):
        var data = self.reader.readline() if size is None else self.reader.readline(size)
        return self.encode(data, self.errors)[0]

    def readlines(self, sizehint=None):
        var data = self.reader.read()
        return self.encode(data, self.errors)[0].splitlines(keepends=True)

    def __next__(self):
        var data = next(self.reader)
        return self.encode(data, self.errors)[0]

    def __iter__(self):
        return self

    def write(self, data):
        return self.writer.write(self.decode(data, self.errors)[0])

    def writelines(self, list):
        return self.writer.write(self.decode(b''.join(list), self.errors)[0])

    def reset(self):
        self.reader.reset()
        self.writer.reset()

    def seek(self, offset, whence=0):
        self.reader.seek(offset, whence)
        self.writer.seek(offset, whence)

    def __getattr__(self, name):
        return getattr(self.stream, name)

    def __enter__(self):
        return self

    def __exit__(self, type, value, tb):
        self.stream.close()

    def __reduce_ex__(self, proto):
        raise TypeError("can't serialize %s" % type(self).__name__)


# ── error handlers ───────────────────────────────────────────────────────────
def _exc_kind(exc):
    if isinstance(exc, UnicodeEncodeError):
        return 1
    if isinstance(exc, UnicodeDecodeError):
        return 2
    if isinstance(exc, UnicodeTranslateError):
        return 3
    raise TypeError("don't know how to handle " + type(exc).__name__ + " in error callback")


def strict_errors(exc):
    """Implements the 'strict' error handling, which raises a UnicodeError on coding errors."""
    if isinstance(exc, BaseException):
        raise exc
    raise TypeError("codec must pass exception instance")


def ignore_errors(exc):
    """Implements the 'ignore' error handling, which ignores malformed data and continues."""
    _exc_kind(exc)
    return ("", exc.end)


def replace_errors(exc):
    """Implements the 'replace' error handling, which replaces malformed data with a replacement marker."""
    var k = _exc_kind(exc)
    if k == 1:
        return ("?" * (exc.end - exc.start), exc.end)
    if k == 2:
        return ("�", exc.end)
    return ("�" * (exc.end - exc.start), exc.end)


def _bs(cp):
    if cp < 0x100:
        return "\\x%02x" % cp
    if cp < 0x10000:
        return "\\u%04x" % cp
    return "\\U%08x" % cp


def backslashreplace_errors(exc):
    """Implements the 'backslashreplace' error handling, which replaces malformed data with a backslashed escape sequence."""
    var k = _exc_kind(exc)
    if k == 2:
        return ("".join(["\\x%02x" % b for b in exc.object[exc.start:exc.end]]), exc.end)
    return ("".join([_bs(ord(c)) for c in exc.object[exc.start:exc.end]]), exc.end)


def xmlcharrefreplace_errors(exc):
    """Implements the 'xmlcharrefreplace' error handling, which replaces an unencodable character with the appropriate XML character reference."""
    if _exc_kind(exc) != 1:
        raise TypeError("don't know how to handle " + type(exc).__name__ + " in error callback")
    return ("".join(["&#" + str(ord(c)) + ";" for c in exc.object[exc.start:exc.end]]), exc.end)


def namereplace_errors(exc):
    """Implements the 'namereplace' error handling, which replaces an unencodable character with a \\N{...} escape sequence."""
    if _exc_kind(exc) != 1:
        raise TypeError("don't know how to handle " + type(exc).__name__ + " in error callback")
    var out = []
    for c in exc.object[exc.start:exc.end]:
        var nm = _ny_unicode_name(ord(c))
        out.append("\\N{" + nm + "}" if nm else _bs(ord(c)))
    return ("".join(out), exc.end)


def _surrogateescape(exc):
    var k = _exc_kind(exc)
    if k == 2:
        # up to 4 bytes, stopping at an ASCII one (CPython's)
        var out = []
        var p = exc.start
        while p < exc.end and p - exc.start < 4 and exc.object[p] >= 128:
            out.append(chr(0xDC00 + exc.object[p]))
            p += 1
        if not out:
            raise exc
        return ("".join(out), p)
    if k == 1:
        var bs = []
        for c in exc.object[exc.start:exc.end]:
            var cp = ord(c)
            if not 0xDC80 <= cp <= 0xDCFF:
                raise exc
            bs.append(cp - 0xDC00)
        return (bytes(bs), exc.end)
    raise TypeError("don't know how to handle " + type(exc).__name__ + " in error callback")


def _surrogatepass(exc):
    var k = _exc_kind(exc)
    var enc = _normalize(exc.encoding)
    if k == 1:
        var out = b""
        for c in exc.object[exc.start:exc.end]:
            var cp = ord(c)
            if not 0xD800 <= cp <= 0xDFFF:
                raise exc
            if enc in ("utf_8", "utf8"):
                out += bytes([0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)])
            elif enc in ("utf_16_le", "utf_16"):
                out += bytes([cp & 0xFF, cp >> 8])
            elif enc == "utf_16_be":
                out += bytes([cp >> 8, cp & 0xFF])
            elif enc in ("utf_32_le", "utf_32"):
                out += bytes([cp & 0xFF, cp >> 8, 0, 0])
            elif enc == "utf_32_be":
                out += bytes([0, 0, cp >> 8, cp & 0xFF])
            else:
                raise exc
        return (out, exc.end)
    if k == 2:
        var p = exc.object[exc.start:]
        var cp = 0
        var w = 0
        if enc in ("utf_8", "utf8"):
            if len(p) >= 3 and (p[0] & 0xF0) == 0xE0 and (p[1] & 0xC0) == 0x80 and (p[2] & 0xC0) == 0x80:
                cp = ((p[0] & 0x0F) << 12) + ((p[1] & 0x3F) << 6) + (p[2] & 0x3F)
            w = 3
        elif enc in ("utf_16_le", "utf_16"):
            if len(p) >= 2:
                cp = p[1] << 8 | p[0]
            w = 2
        elif enc == "utf_16_be":
            if len(p) >= 2:
                cp = p[0] << 8 | p[1]
            w = 2
        elif enc in ("utf_32_le", "utf_32"):
            if len(p) >= 4:
                cp = p[3] << 24 | p[2] << 16 | p[1] << 8 | p[0]
            w = 4
        elif enc == "utf_32_be":
            if len(p) >= 4:
                cp = p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
            w = 4
        if not 0xD800 <= cp <= 0xDFFF:
            raise exc
        return (chr(cp), exc.start + w)
    raise TypeError("don't know how to handle " + type(exc).__name__ + " in error callback")


_BUILTIN_HANDLERS = ("strict", "ignore", "replace", "backslashreplace", "xmlcharrefreplace", "namereplace",
                     "surrogateescape", "surrogatepass")
_error_registry = {"strict": strict_errors, "ignore": ignore_errors, "replace": replace_errors,
                   "backslashreplace": backslashreplace_errors, "xmlcharrefreplace": xmlcharrefreplace_errors,
                   "namereplace": namereplace_errors, "surrogateescape": _surrogateescape,
                   "surrogatepass": _surrogatepass}


def register_error(name, error_handler):
    """Register the specified error handler under the name errors."""
    if not isinstance(name, str):
        raise TypeError("register_error() argument 1 must be str, not " + type(name).__name__)
    if not callable(error_handler):
        raise TypeError("handler must be callable")
    _error_registry[name] = error_handler


def lookup_error(name):
    """lookup_error(errors) -> handler"""
    if not isinstance(name, str):
        raise TypeError("lookup_error() argument must be str, not " + type(name).__name__)
    if name not in _error_registry:
        raise LookupError("unknown error handler name '" + name + "'")
    return _error_registry[name]


# ── the native codecs (include/NyCodecs.hpp) ─────────────────────────────────
def _native(encoding):
    return _ny_codec("lookup", encoding)


def _normalize(encoding):
    # encodings.normalize_encoding, lower-cased
    var out = []
    var pend = False
    for c in encoding:
        if c.isalnum() or c == ".":
            if pend and out:
                out.append("_")
            out.append(c.lower() if c.isascii() else c)
            pend = False
        else:
            pend = True
    return "".join(out)


def _handler(errors):
    if errors is None:
        return None
    if not isinstance(errors, str):
        raise TypeError("encode() argument 'errors' must be str, not " + type(errors).__name__)
    if errors in _BUILTIN_HANDLERS:
        return None
    return lookup_error(errors)


def _check_str(input, what):
    if not isinstance(input, str):
        raise TypeError(what + "() argument 1 must be str, not " + type(input).__name__)


def _as_bytes(input, what):
    if isinstance(input, bytearray):
        return bytes(input)
    if isinstance(input, bytes):
        return input
    if isinstance(input, str):
        raise TypeError("a bytes-like object is required, not 'str'")
    raise TypeError("a bytes-like object is required, not '" + type(input).__name__ + "'")


def _plain_name(name):
    # the codec that encodes a replacement / continues without a BOM
    if name == "utf-16":
        return "utf-16-le"
    if name == "utf-32":
        return "utf-32-le"
    if name == "utf-8-sig":
        return "utf-8"
    return name


def _encode_native(name, input, errors):
    # (bytes, characters consumed); a registered handler runs here, looked
    # up only when an error needs it (as CPython)
    if errors is None:
        errors = "strict"
    if not isinstance(errors, str):
        raise TypeError("encode() argument 'errors' must be str, not " + type(errors).__name__)
    var h = None
    if errors in _BUILTIN_HANDLERS:
        var r = _ny_codec("encode", name, input, errors, True, 0)
        return (r[0], len(input))
    var parts = []
    var pos = 0
    var n = len(input)
    var cname = name
    while True:
        var r = _ny_codec("encode", cname, input, "__ny_stop__", True, pos)
        parts.append(r[0])
        if r[2] is None:
            break
        var e = r[2]
        var exc = UnicodeEncodeError(e[3], input, e[0], e[1], e[2])
        if h is None:
            h = lookup_error(errors)
        var res = h(exc)
        if not isinstance(res, tuple) or len(res) != 2:
            raise TypeError("encoding error handler must return (str/bytes, int) tuple")
        var rep = res[0]
        var newpos = res[1]
        if isinstance(rep, str):
            try:
                parts.append(_ny_codec("encode", _plain_name(name), rep, "strict", True, 0)[0])
            except UnicodeEncodeError:
                raise UnicodeEncodeError(e[3], input, e[0], e[1], e[2])
        elif isinstance(rep, (bytes, bytearray)):
            parts.append(bytes(rep))
        else:
            raise TypeError("encoding error handler must return (str/bytes, int) tuple")
        if newpos < 0:
            newpos += n
        if not 0 <= newpos <= n:
            raise IndexError("position " + str(res[1]) + " from error handler out of bounds")
        pos = newpos
        if pos >= n:
            break
    return (b"".join(parts), n)


def _decode_native(name, input, errors, final=True):
    # (str, bytes consumed); a registered handler runs here
    if errors is None:
        errors = "strict"
    if not isinstance(errors, str):
        raise TypeError("decode() argument 'errors' must be str, not " + type(errors).__name__)
    input = _as_bytes(input, "decode")
    var h = None
    if errors in _BUILTIN_HANDLERS:
        var r = _ny_codec("decode", name, input, errors, final, 0)
        return (r[0], r[1])
    var parts = []
    var pos = 0
    var n = len(input)
    var cname = name
    var consumed = 0
    while True:
        var r = _ny_codec("decode", cname, input, "__ny_stop__", final, pos)
        parts.append(r[0])
        if r[3] is not None and cname in ("utf-16", "utf-32"):
            # the byte order its BOM (or the default) chose
            cname = cname + "-" + r[3]
        if r[2] is None:
            consumed = r[1]
            break
        var e = r[2]
        var exc = UnicodeDecodeError(e[3], input, e[0], e[1], e[2])
        if h is None:
            h = lookup_error(errors)
        var res = h(exc)
        if not isinstance(res, tuple) or len(res) != 2 or not isinstance(res[0], str):
            raise TypeError("decoding error handler must return (str, int) tuple")
        parts.append(res[0])
        var newpos = res[1]
        if newpos < 0:
            newpos += n
        if not 0 <= newpos <= n:
            raise IndexError("position " + str(res[1]) + " from error handler out of bounds")
        pos = newpos
        if name == "utf-8-sig":
            cname = "utf-8"
        if pos >= n:
            consumed = n
            break
    return ("".join(parts), consumed)


def _native_info(name):
    def enc(input, errors='strict'):
        _check_str(input, "encode")
        return _encode_native(name, input, errors)

    def dec(input, errors='strict'):
        return _decode_native(name, input, errors, True)

    enc.__name__ = "encode"
    dec.__name__ = "decode"

    class IncEnc(IncrementalEncoder):
        def __init__(self, errors='strict'):
            IncrementalEncoder.__init__(self, errors)
            self.first = True

        def encode(self, input, final=False):
            var cname = name if self.first else _plain_name(name)
            self.first = False
            return _encode_native(cname, input, self.errors)[0]

        def reset(self):
            self.first = True

        def getstate(self):
            return 2 if self.first else 0

        def setstate(self, state):
            self.first = bool(state)

    class IncDec(BufferedIncrementalDecoder):
        def __init__(self, errors='strict'):
            BufferedIncrementalDecoder.__init__(self, errors)
            self.cname = name

        def _buffer_decode(self, input, errors, final):
            if self.cname == "utf-8-sig":
                if len(input) < 3 and BOM_UTF8.startswith(input) and not final:
                    return ("", 0)
                self.cname = "utf-8"
                if input[:3] == BOM_UTF8:
                    var r = _decode_native("utf-8", input[3:], errors, final)
                    return (r[0], r[1] + 3)
            if self.cname == "utf-16" or self.cname == "utf-32":
                var w = 2 if self.cname == "utf-16" else 4
                if len(input) < w and not final:
                    return ("", 0)
                var head = input[:w]
                var skip = w
                if head == (BOM_UTF16_LE if w == 2 else BOM_UTF32_LE):
                    self.cname = self.cname + "-le"
                elif head == (BOM_UTF16_BE if w == 2 else BOM_UTF32_BE):
                    self.cname = self.cname + "-be"
                else:
                    self.cname = self.cname + "-le"
                    skip = 0
                var r2 = _decode_native(self.cname, input[skip:], errors, final)
                return (r2[0], r2[1] + skip)
            return _decode_native(self.cname, input, errors, final)

        def reset(self):
            BufferedIncrementalDecoder.reset(self)
            self.cname = name

    class Writer(StreamWriter):
        def __init__(self, stream, errors='strict'):
            StreamWriter.__init__(self, stream, errors)
            self.first = True

        def encode(self, input, errors='strict'):
            var cname = name if self.first else _plain_name(name)
            self.first = False
            return _encode_native(cname, input, errors)

        def reset(self):
            self.first = True

    class Reader(StreamReader):
        def __init__(self, stream, errors='strict'):
            StreamReader.__init__(self, stream, errors)
            self.dec = IncDec(errors)

        def decode(self, input, errors='strict'):
            # (str, bytes consumed): an incomplete sequence at the end stays
            # in the reader's bytebuffer
            return self.dec._buffer_decode(input, errors, False)

        def reset(self):
            StreamReader.reset(self)
            self.dec.reset()

    IncEnc.__name__ = "IncrementalEncoder"
    IncDec.__name__ = "IncrementalDecoder"
    Writer.__name__ = "StreamWriter"
    Reader.__name__ = "StreamReader"
    return CodecInfo(enc, dec, Reader, Writer, IncEnc, IncDec, name)


# ── codecs written here ──────────────────────────────────────────────────────
def _stateless_info(name, encodef, decodef, text=False):
    # a codec without state: the incremental and stream forms call encodef
    # / decodef on each piece (as CPython's hex_codec, base64_codec ...)
    class IncEnc(IncrementalEncoder):
        def encode(self, input, final=False):
            return encodef(input, self.errors)[0]

    class IncDec(IncrementalDecoder):
        def decode(self, input, final=False):
            return decodef(input, self.errors)[0]

    class Writer(StreamWriter):
        def encode(self, input, errors='strict'):
            return encodef(input, errors)

    class Reader(StreamReader):
        charbuffertype = str if text else bytes

        def decode(self, input, errors='strict'):
            return decodef(input, errors)

    IncEnc.__name__ = "IncrementalEncoder"
    IncDec.__name__ = "IncrementalDecoder"
    Writer.__name__ = "StreamWriter"
    Reader.__name__ = "StreamReader"
    return CodecInfo(encodef, decodef, Reader, Writer, IncEnc, IncDec, name, _is_text_encoding=text)


def _strict_only(errors):
    if errors != 'strict':
        raise ValueError("Unsupported error handling mode: '" + str(errors) + "' - must be 'strict'")


def _hex_encode(input, errors='strict'):
    _strict_only(errors)
    import binascii
    return (binascii.b2a_hex(_as_bytes(input, "hex")), len(input))


def _hex_decode(input, errors='strict'):
    _strict_only(errors)
    import binascii
    return (binascii.a2b_hex(input), len(input))


def _base64_encode(input, errors='strict'):
    _strict_only(errors)
    import base64
    return (base64.encodebytes(_as_bytes(input, "base64")), len(input))


def _base64_decode(input, errors='strict'):
    _strict_only(errors)
    import base64
    return (base64.decodebytes(input), len(input))


def _zlib_encode(input, errors='strict'):
    _strict_only(errors)
    import zlib
    return (zlib.compress(_as_bytes(input, "zlib")), len(input))


def _zlib_decode(input, errors='strict'):
    _strict_only(errors)
    import zlib
    return (zlib.decompress(input), len(input))


def _quopri_encode(input, errors='strict'):
    _strict_only(errors)
    import binascii
    return (binascii.b2a_qp(_as_bytes(input, "quopri"), quotetabs=True), len(input))


def _quopri_decode(input, errors='strict'):
    _strict_only(errors)
    import binascii
    return (binascii.a2b_qp(_as_bytes(input, "quopri")), len(input))


def _rot13(input, errors='strict'):
    var out = []
    for c in input:
        var o = ord(c)
        if 65 <= o <= 90:
            out.append(chr((o - 65 + 13) % 26 + 65))
        elif 97 <= o <= 122:
            out.append(chr((o - 97 + 13) % 26 + 97))
        else:
            out.append(c)
    return ("".join(out), len(input))


# ── punycode (RFC 3492; CPython's encodings/punycode.py) ─────────────────────
def _segregate(s):
    var base = bytearray()
    var extended = set()
    for c in s:
        if ord(c) < 128:
            base.append(ord(c))
        else:
            extended.add(c)
    return bytes(base), sorted(extended)


def _selective_len(s, maxc):
    var res = 0
    for c in s:
        if ord(c) < maxc:
            res += 1
    return res


def _selective_find(s, ch, index, pos):
    var l = len(s)
    while 1:
        pos += 1
        if pos == l:
            return (-1, -1)
        var c = s[pos]
        if c == ch:
            return index + 1, pos
        elif c < ch:
            index += 1


def _insertion_unsort(s, extended):
    var oldchar = 0x80
    var result = []
    var oldindex = -1
    for c in extended:
        var index = -1
        var pos = -1
        var ch = ord(c)
        var curlen = _selective_len(s, ch)
        var delta = (curlen + 1) * (ch - oldchar)
        while 1:
            var ip = _selective_find(s, c, index, pos)
            index = ip[0]
            pos = ip[1]
            if index == -1:
                break
            delta += index - oldindex
            result.append(delta - 1)
            oldindex = index
            delta = 0
        oldchar = ch
    return result


def _T(j, bias):
    var res = 36 * (j + 1) - bias
    if res < 1:
        return 1
    if res > 26:
        return 26
    return res


_digits = b"abcdefghijklmnopqrstuvwxyz0123456789"


def _generate_generalized_integer(N, bias):
    var result = bytearray()
    var j = 0
    while 1:
        var t = _T(j, bias)
        if N < t:
            result.append(_digits[N])
            return bytes(result)
        result.append(_digits[t + ((N - t) % (36 - t))])
        N = (N - t) // (36 - t)
        j += 1


def _adapt(delta, first, numchars):
    if first:
        delta //= 700
    else:
        delta //= 2
    delta += delta // numchars
    var divisions = 0
    while delta > 455:
        delta = delta // 35
        divisions += 36
    return divisions + (36 * delta // (delta + 38))


def _generate_integers(baselen, deltas):
    var result = bytearray()
    var bias = 72
    var i = 0
    for delta in deltas:
        var s = _generate_generalized_integer(delta, bias)
        result.extend(s)
        bias = _adapt(delta, i == 0, baselen + i + 1)
        i += 1
    return bytes(result)


def _punycode_encode(text):
    var bx = _segregate(text)
    var deltas = _insertion_unsort(text, bx[1])
    var extended = _generate_integers(len(bx[0]), deltas)
    if bx[0]:
        return bx[0] + b"-" + extended
    return extended


def _decode_generalized_number(extended, extpos, bias, errors):
    var result = 0
    var w = 1
    var j = 0
    while 1:
        var char = 0
        try:
            char = ord(extended[extpos:extpos + 1])
        except (TypeError, IndexError):
            if errors == "strict":
                raise UnicodeError("incomplete punicode string")
            return extpos + 1, None
        extpos += 1
        var digit = 0
        if 0x41 <= char <= 0x5A:
            digit = char - 0x41
        elif 0x30 <= char <= 0x39:
            digit = char - 22
        elif errors == "strict":
            raise UnicodeError("Invalid extended code point '%s'" % extended[extpos - 1])
        else:
            return extpos, None
        var t = _T(j, bias)
        result += digit * w
        if digit < t:
            return extpos, result
        w = w * (36 - t)
        j += 1


def _insertion_sort(base, extended, errors):
    var char = 0x80
    var pos = -1
    var bias = 72
    var extpos = 0
    while extpos < len(extended):
        var nd = _decode_generalized_number(extended, extpos, bias, errors)
        var newpos = nd[0]
        var delta = nd[1]
        if delta is None:
            return base
        pos += delta + 1
        char += pos // (len(base) + 1)
        if char > 0x10FFFF:
            if errors == "strict":
                raise UnicodeError("Invalid character U+%x" % char)
            char = ord('?')
        pos = pos % (len(base) + 1)
        base = base[:pos] + chr(char) + base[pos:]
        bias = _adapt(delta, (extpos == 0), len(base))
        extpos = newpos
    return base


def _punycode_decode(text, errors):
    if isinstance(text, str):
        text = text.encode("ascii")
    if isinstance(text, bytearray):
        text = bytes(text)
    var pos = text.rfind(b"-")
    var base = None
    var extended = None
    if pos == -1:
        base = ""
        extended = str(text, "ascii").upper()
    else:
        base = str(text[:pos], "ascii", errors)
        extended = str(text[pos + 1:], "ascii").upper()
    return _insertion_sort(base, extended, errors)


def _punycode_codec_encode(input, errors='strict'):
    return (_punycode_encode(input), len(input))


def _punycode_codec_decode(input, errors='strict'):
    if errors not in ('strict', 'replace', 'ignore'):
        raise UnicodeError("Unsupported error handling " + errors)
    return (_punycode_decode(input, errors), len(input))


# ── idna (RFC 3490, basic: nameprep is lower-casing) ─────────────────────────
_ace_prefix = b"xn--"
_sace_prefix = "xn--"
_dots = (".", "。", "．", "｡")


def _idna_split(s):
    var labels = [""]
    for c in s:
        if c in _dots:
            labels.append("")
        else:
            labels[-1] = labels[-1] + c
    return labels


def _ToASCII(label):
    try:
        var b = label.encode("ascii")
        if 0 < len(b) < 64:
            return b
        raise UnicodeError("label empty or too long")
    except UnicodeEncodeError:
        pass
    label = label.lower()
    try:
        var b2 = label.encode("ascii")
        if 0 < len(b2) < 64:
            return b2
        raise UnicodeError("label empty or too long")
    except UnicodeEncodeError:
        pass
    if label.startswith(_sace_prefix):
        raise UnicodeError("Label starts with ACE prefix")
    var r = _ace_prefix + _punycode_encode(label)
    if 0 < len(r) < 64:
        return r
    raise UnicodeError("label empty or too long")


def _ToUnicode(label):
    if len(label) > 1024:
        raise UnicodeError("label way too long")
    var pure_ascii = False
    if isinstance(label, bytes):
        pure_ascii = True
    else:
        try:
            label = label.encode("ascii")
            pure_ascii = True
        except UnicodeError:
            pure_ascii = False
    if not pure_ascii:
        label = label.lower().encode("ascii")
    if not label[:4].lower() == _ace_prefix:
        return str(label, "ascii")
    var label1 = label[len(_ace_prefix):]
    var result = _punycode_decode(label1, "strict")
    var label2 = _ToASCII(result)
    if str(label, "ascii").lower() != str(label2, "ascii"):
        raise UnicodeError("IDNA does not round-trip", label, label2)
    return result


def _idna_encode(input, errors='strict'):
    if errors != 'strict':
        raise UnicodeError("unsupported error handling " + errors)
    if not input:
        return b'', 0
    try:
        var result = input.encode('ascii')
        var labels = result.split(b'.')
        for label in labels[:-1]:
            if not (0 < len(label) < 64):
                raise UnicodeError("label empty or too long")
        if len(labels[-1]) >= 64:
            raise UnicodeError("label too long")
        return result, len(input)
    except UnicodeEncodeError:
        pass
    var result = bytearray()
    var labels = _idna_split(input)
    var trailing_dot = b''
    if labels and not labels[-1]:
        trailing_dot = b'.'
        del labels[-1]
    elif not labels:
        trailing_dot = b''
    for label in labels:
        if result:
            result.extend(b'.')
        result.extend(_ToASCII(label))
    return bytes(result + trailing_dot), len(input)


def _idna_decode(input, errors='strict'):
    if errors != 'strict':
        raise UnicodeError("Unsupported error handling " + errors)
    if not input:
        return "", 0
    var labels = None
    if not isinstance(input, bytes):
        input = bytes(input)
    if _ace_prefix not in input.lower():
        try:
            return input.decode('ascii'), len(input)
        except UnicodeDecodeError:
            pass
    labels = input.split(b".")
    var trailing_dot = ''
    if labels and len(labels[-1]) == 0:
        trailing_dot = '.'
        del labels[-1]
    var result = []
    for label in labels:
        result.append(_ToUnicode(label))
    return ".".join(result) + trailing_dot, len(input)


# ── the registry ─────────────────────────────────────────────────────────────
_PY_CODECS = {"hex_codec": ("hex", _hex_encode, _hex_decode, False),
              "hex": ("hex", _hex_encode, _hex_decode, False),
              "base64_codec": ("base64", _base64_encode, _base64_decode, False),
              "base64": ("base64", _base64_encode, _base64_decode, False),
              "base_64": ("base64", _base64_encode, _base64_decode, False),
              "zlib_codec": ("zlib", _zlib_encode, _zlib_decode, False),
              "zlib": ("zlib", _zlib_encode, _zlib_decode, False),
              "zip": ("zlib", _zlib_encode, _zlib_decode, False),
              "quopri_codec": ("quopri", _quopri_encode, _quopri_decode, False),
              "quopri": ("quopri", _quopri_encode, _quopri_decode, False),
              "quoted_printable": ("quopri", _quopri_encode, _quopri_decode, False),
              "quotedprintable": ("quopri", _quopri_encode, _quopri_decode, False),
              "rot_13": ("rot-13", _rot13, _rot13, False),
              "rot13": ("rot-13", _rot13, _rot13, False),
              "punycode": ("punycode", _punycode_codec_encode, _punycode_codec_decode, True),
              "idna": ("idna", _idna_encode, _idna_decode, True)}

_search_functions = []
_cache = {}


def register(search_function):
    """Register a codec search function."""
    if not callable(search_function):
        raise TypeError("argument must be callable")
    _search_functions.append(search_function)


def unregister(search_function):
    """Unregister a codec search function and clear the registry's cache."""
    if search_function in _search_functions:
        _search_functions.remove(search_function)
    _cache.clear()


def lookup(encoding):
    """Looks up a codec tuple in the Python codec registry and returns a CodecInfo object."""
    if not isinstance(encoding, str):
        raise TypeError("lookup() argument must be str, not " + type(encoding).__name__)
    var key = encoding.lower().replace(" ", "-")
    var info = _cache.get(key)
    if info is not None:
        return info
    var native = _native(encoding)
    if native is not None:
        info = _native_info(native)
    else:
        var n = _normalize(encoding)
        var py = _PY_CODECS.get(n)
        if py is not None:
            info = _stateless_info(py[0], py[1], py[2], py[3])
        else:
            for f in _search_functions:
                var r = f(key)
                if r is not None:
                    if not isinstance(r, CodecInfo):
                        if not isinstance(r, tuple) or len(r) != 4:
                            raise TypeError("codec search functions must return 4-tuples")
                        r = CodecInfo(*r)
                    info = r
                    break
    if info is None:
        raise LookupError("unknown encoding: " + encoding)
    _cache[key] = info
    return info


_WRAPPED = (TypeError, ValueError, LookupError, AttributeError, IndexError, KeyError, OverflowError,
            RuntimeError, ZeroDivisionError)


def _wrap(e, what, encoding):
    # CPython's _PyErr_TrySetFromCause: the same type, the codec named
    if isinstance(e, UnicodeError) or type(e) not in _WRAPPED or "codec failed (" in str(e):
        return e
    var w = type(e)(what + " with " + repr(encoding) + " codec failed (" + type(e).__name__ + ": " + str(e) + ")")
    w.__cause__ = e
    return w


def encode(obj, encoding='utf-8', errors='strict'):
    """Encodes obj using the codec registered for encoding."""
    if not isinstance(encoding, str):
        raise TypeError("encode() argument 'encoding' must be str, not " + type(encoding).__name__)
    var info = lookup(encoding)
    var r = None
    try:
        r = info.encode(obj, errors)
    except Exception as e:
        var w = _wrap(e, "encoding", encoding)
        if w is e:
            raise
        raise w from e
    if not isinstance(r, tuple) or len(r) != 2:
        raise TypeError("encoder must return a tuple (object, integer)")
    return r[0]


def decode(obj, encoding='utf-8', errors='strict'):
    """Decodes obj using the codec registered for encoding."""
    if not isinstance(encoding, str):
        raise TypeError("decode() argument 'encoding' must be str, not " + type(encoding).__name__)
    var info = lookup(encoding)
    var r = None
    try:
        r = info.decode(obj, errors)
    except Exception as e:
        var w = _wrap(e, "decoding", encoding)
        if w is e:
            raise
        raise w from e
    if not isinstance(r, tuple) or len(r) != 2:
        raise TypeError("decoder must return a tuple (object, integer)")
    return r[0]


_FAST = ("utf8", "utf_8", "utf16", "utf_16", "utf32", "utf_32", "ascii", "us_ascii", "latin1", "latin_1",
         "iso_8859_1", "iso8859_1")


# str.encode / bytes.decode / str(b, encoding, errors) for what only the
# registry has (the prelude's _ny_codec_encode / _ny_codec_decode)
def _ny_text_encode(s, encoding, errors):
    var info = lookup(encoding)
    if not info._is_text_encoding:
        raise LookupError(repr(encoding) + " is not a text encoding; use codecs.encode() to handle arbitrary codecs")
    var r = None
    try:
        r = info.encode(s, errors)
    except Exception as e:
        if _normalize(encoding) in _FAST:
            raise
        var w = _wrap(e, "encoding", encoding)
        if w is e:
            raise
        raise w from e
    if not isinstance(r[0], bytes):
        raise TypeError("'" + encoding + "' encoder returned '" + type(r[0]).__name__
                        + "' instead of 'bytes'; use codecs.encode() to encode to arbitrary types")
    return r[0]


def _ny_text_decode(b, encoding, errors):
    var info = lookup(encoding)
    if not info._is_text_encoding:
        raise LookupError(repr(encoding) + " is not a text encoding; use codecs.decode() to handle arbitrary codecs")
    var r = None
    try:
        r = info.decode(bytes(b), errors)
    except Exception as e:
        if _normalize(encoding) in _FAST:
            raise
        var w = _wrap(e, "decoding", encoding)
        if w is e:
            raise
        raise w from e
    if not isinstance(r[0], str):
        raise TypeError("'" + encoding + "' decoder returned '" + type(r[0]).__name__
                        + "' instead of 'str'; use codecs.decode() to decode to str")
    return r[0]


def getencoder(encoding):
    return lookup(encoding).encode


def getdecoder(encoding):
    return lookup(encoding).decode


def getincrementalencoder(encoding):
    var encoder = lookup(encoding).incrementalencoder
    if encoder is None:
        raise LookupError(encoding)
    return encoder


def getincrementaldecoder(encoding):
    var decoder = lookup(encoding).incrementaldecoder
    if decoder is None:
        raise LookupError(encoding)
    return decoder


def getreader(encoding):
    return lookup(encoding).streamreader


def getwriter(encoding):
    return lookup(encoding).streamwriter


def iterencode(iterator, encoding, errors='strict', **kwargs):
    var encoder = getincrementalencoder(encoding)(errors, **kwargs)
    for input in iterator:
        var output = encoder.encode(input)
        if output:
            yield output
    var output = encoder.encode("", True)
    if output:
        yield output


def iterdecode(iterator, encoding, errors='strict', **kwargs):
    var decoder = getincrementaldecoder(encoding)(errors, **kwargs)
    for input in iterator:
        var output = decoder.decode(input)
        if output:
            yield output
    var output = decoder.decode(b"", True)
    if output:
        yield output


def open(filename, mode='r', encoding=None, errors='strict', buffering=-1):
    """Open an encoded file using the given mode and return a wrapped version providing transparent encoding/decoding."""
    if encoding is not None and 'b' not in mode:
        mode = mode + 'b'
    var file = _builtin_open(filename, mode, buffering)
    if encoding is None:
        return file
    try:
        var info = lookup(encoding)
        var srw = StreamReaderWriter(file, info.streamreader, info.streamwriter, errors)
        srw.encoding = encoding
        return srw
    except:
        file.close()
        raise


def EncodedFile(file, data_encoding, file_encoding=None, errors='strict'):
    """Return a wrapped version of file which provides transparent encoding translation."""
    if file_encoding is None:
        file_encoding = data_encoding
    var data_info = lookup(data_encoding)
    var file_info = lookup(file_encoding)
    var sr = StreamRecoder(file, data_info.encode, data_info.decode,
                           file_info.streamreader, file_info.streamwriter, errors)
    sr.data_encoding = data_encoding
    sr.file_encoding = file_encoding
    return sr


# ── _codecs' functions ───────────────────────────────────────────────────────
def _enc_fn(name):
    def f(str, errors=None):
        _check_str(str, name.replace("-", "_") + "_encode")
        return _encode_native(name, str, errors)
    return f


def _dec_fn(name):
    def f(data, errors=None, final=False):
        return _decode_native(name, data, errors, final)
    return f


utf_8_encode = _enc_fn("utf-8")
utf_8_decode = _dec_fn("utf-8")
utf_16_le_encode = _enc_fn("utf-16-le")
utf_16_le_decode = _dec_fn("utf-16-le")
utf_16_be_encode = _enc_fn("utf-16-be")
utf_16_be_decode = _dec_fn("utf-16-be")
utf_32_le_encode = _enc_fn("utf-32-le")
utf_32_le_decode = _dec_fn("utf-32-le")
utf_32_be_encode = _enc_fn("utf-32-be")
utf_32_be_decode = _dec_fn("utf-32-be")
latin_1_encode = _enc_fn("latin-1")
ascii_encode = _enc_fn("ascii")
unicode_escape_encode = _enc_fn("unicode-escape")
raw_unicode_escape_encode = _enc_fn("raw-unicode-escape")


def latin_1_decode(data, errors=None):
    return _decode_native("latin-1", data, errors, True)


def ascii_decode(data, errors=None):
    return _decode_native("ascii", data, errors, True)


def unicode_escape_decode(data, errors=None, final=True):
    if isinstance(data, str):
        data = data.encode("latin-1")
    return _decode_native("unicode-escape", data, errors, final)


def raw_unicode_escape_decode(data, errors=None, final=True):
    if isinstance(data, str):
        data = data.encode("latin-1")
    return _decode_native("raw-unicode-escape", data, errors, final)


def utf_16_encode(str, errors=None, byteorder=0):
    _check_str(str, "utf_16_encode")
    return _encode_native("utf-16" if byteorder == 0 else "utf-16-le" if byteorder < 0 else "utf-16-be", str, errors)


def utf_16_decode(data, errors=None, final=False):
    return _decode_native("utf-16", data, errors, final)


def utf_16_ex_decode(data, errors=None, byteorder=0, final=False):
    data = _as_bytes(data, "utf_16_ex_decode")
    var name = "utf-16" if byteorder == 0 else "utf-16-le" if byteorder < 0 else "utf-16-be"
    var order = 0
    if byteorder == 0 and len(data) >= 2:
        if data[:2] == BOM_UTF16_LE:
            order = -1
        elif data[:2] == BOM_UTF16_BE:
            order = 1
    var r = _decode_native(name, data, errors, final)
    return (r[0], r[1], order if byteorder == 0 else byteorder)


def utf_32_encode(str, errors=None, byteorder=0):
    _check_str(str, "utf_32_encode")
    return _encode_native("utf-32" if byteorder == 0 else "utf-32-le" if byteorder < 0 else "utf-32-be", str, errors)


def utf_32_decode(data, errors=None, final=False):
    return _decode_native("utf-32", data, errors, final)


def escape_encode(data, errors=None):
    # bytes -> bytes with Python's bytes-literal escapes (repr without b'')
    data = _as_bytes(data, "escape_encode")
    var r = repr(data)
    var body = r[2:-1]
    if r[1] == '"':
        body = body.replace("'", "\\'")
    return (body.encode("latin-1"), len(data))


def escape_decode(data, errors=None):
    # bytes escapes -> bytes (\\x.., \\n, octal ...; no \\u)
    if isinstance(data, str):
        data = data.encode("latin-1")
    data = _as_bytes(data, "escape_decode")
    var s = _decode_native("unicode-escape", data.replace(b"\\u", b"\\\\u").replace(b"\\U", b"\\\\U").replace(b"\\N", b"\\\\N"),
                           errors, True)[0]
    return (s.encode("latin-1"), len(data))


def charmap_build(map):
    var d = {}
    var i = 0
    for c in map:
        d[ord(c)] = i
        i += 1
    return d


def charmap_encode(str, errors=None, mapping=None):
    if mapping is None:
        return latin_1_encode(str, errors)
    var out = bytearray()
    var h = None
    var i = 0
    var n = len(str)
    while i < n:
        var c = str[i]
        var v = mapping.get(ord(c), None) if isinstance(mapping, dict) else None
        if v is None and not isinstance(mapping, dict):
            try:
                v = mapping[ord(c)]
            except (LookupError, TypeError):
                v = None
        if v is None:
            var j = i + 1
            while j < n and (mapping.get(ord(str[j])) if isinstance(mapping, dict) else None) is None:
                j += 1
            var exc = UnicodeEncodeError("charmap", str, i, j, "character maps to <undefined>")
            if h is None:
                h = lookup_error(errors or "strict")
            var res = h(exc)
            var rep = res[0]
            if isinstance(rep, str):
                rep = charmap_encode(rep, "strict", mapping)[0]
            out.extend(rep)
            i = res[1] if res[1] >= 0 else n + res[1]
            continue
        if isinstance(v, int):
            out.append(v)
        else:
            out.extend(v)
        i += 1
    return (bytes(out), n)


def charmap_decode(data, errors=None, mapping=None):
    if mapping is None:
        return latin_1_decode(data, errors)
    data = _as_bytes(data, "charmap_decode")
    var out = []
    var h = None
    var i = 0
    var n = len(data)
    while i < n:
        var b = data[i]
        var v = None
        try:
            v = mapping[b]
        except (LookupError, TypeError):
            v = None
        if isinstance(v, int):
            v = chr(v)
        if v is None or v == "￾":
            var exc = UnicodeDecodeError("charmap", data, i, i + 1, "character maps to <undefined>")
            if h is None:
                h = lookup_error(errors or "strict")
            var res = h(exc)
            out.append(res[0])
            i = res[1] if res[1] >= 0 else n + res[1]
            continue
        out.append(v)
        i += 1
    return ("".join(out), n)


def make_identity_dict(rng):
    return {i: i for i in rng}


def make_encoding_map(decoding_map):
    var m = {}
    for k in decoding_map:
        var v = decoding_map[k]
        if not v in m:
            m[v] = k
        else:
            m[v] = None
    return m


# the error handlers by name, as codecs exposes them
strict_errors.__name__ = "strict_errors"
