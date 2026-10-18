# nython: module    (import it by name: it runs in a module scope of its own)
# lib/_multibytecodec.ny - CPython's _multibytecodec (round 84): the codec
# objects, incremental encoders/decoders and stream readers/writers of the
# CJK codecs, over the native codecs of src/builtins/nycjk.cpp (CPython's
# Modules/cjkcodecs ported; the _ny_mbc native on both engines).
#
#     import _codecs_jp
#     c = _codecs_jp.getcodec("shift_jis")
#     c.encode("日本")                     # (b'\x93\xfa\x96{', 2)
#     c.decode(b"\x82\xa0")               # ('あ', 2)
#
# MultibyteCodec (encode/decode, every error handler: the builtin ones in
# native code, a handler registered with codecs.register_error called with
# the UnicodeEncodeError/UnicodeDecodeError, its str replacement encoded by
# the codec in the codec's current state, as CPython's
# multibytecodec_encerror does), MultibyteIncrementalEncoder (pending input
# for JIS X 0213 / HKSCS pairs, getstate/setstate in CPython's format,
# reset), MultibyteIncrementalDecoder (up to 8 pending bytes,
# getstate/setstate, reset), MultibyteStreamReader (read/readline/readlines
# with CPython's one-more-byte retry), MultibyteStreamWriter (write/
# writelines/reset).
#
# Not here: __create_codec and the __map_* capsules (C API only).

import codecs

__all__ = ["MultibyteCodec", "MultibyteIncrementalEncoder", "MultibyteIncrementalDecoder",
           "MultibyteStreamReader", "MultibyteStreamWriter"]

_BUILTIN = ("strict", "ignore", "replace", "backslashreplace", "xmlcharrefreplace", "namereplace",
            "surrogateescape", "surrogatepass")
_FLUSH = 1
_RESET = 2
MAXENCPENDING = 2
MAXDECPENDING = 8


def _errors_arg(errors):
    if errors is None:
        return "strict"
    if not isinstance(errors, str):
        raise TypeError("errors must be a string, not " + type(errors).__name__)
    return errors


def _encode(name, text, errors, state, flags):
    # multibytecodec_encode: (bytes, characters consumed, state)
    if errors in _BUILTIN:
        var r = _ny_mbc("encode", name, text, errors, state, flags, 0)
        return (r[0], r[1], r[3])
    var parts = []
    var pos = 0
    var n = len(text)
    var exc = None
    while True:
        var r = _ny_mbc("encode", name, text, "__ny_stop__", state, flags, pos)
        parts.append(r[0])
        state = r[3]
        pos = r[1]
        if r[2] is None:
            break
        var e = r[2]
        if exc is None:
            exc = UnicodeEncodeError(name, text, e[0], e[1], e[2])
        else:
            exc.start = e[0]
            exc.end = e[1]
            exc.reason = e[2]
        var res = codecs.lookup_error(errors)(exc)
        if (not isinstance(res, tuple) or len(res) != 2 or not isinstance(res[0], (str, bytes))
                or not isinstance(res[1], int)):
            raise TypeError("encoding error handler must return (str, int) tuple")
        if isinstance(res[0], str):
            # (the replacement in the codec's current state, strict)
            var rr = _ny_mbc("encode", name, res[0], "strict", state, _FLUSH, 0)
            parts.append(rr[0])
            state = rr[3]
        else:
            parts.append(res[0])
        var newpos = res[1]
        if newpos < 0:
            newpos += n
        if newpos < 0 or newpos > n:
            raise IndexError("position %d from error handler out of bounds" % res[1])
        pos = newpos
    return (b"".join(parts), pos, state)


def _decode(name, data, errors, state, final):
    # multibytecodec decoding: (str, bytes consumed, state)
    if errors in _BUILTIN:
        var r = _ny_mbc("decode", name, data, errors, state, final, 0)
        return (r[0], r[1], r[3])
    var parts = []
    var pos = 0
    var n = len(data)
    var exc = None
    while True:
        var r = _ny_mbc("decode", name, data, "__ny_stop__", state, final, pos)
        parts.append(r[0])
        state = r[3]
        pos = r[1]
        if r[2] is None:
            break
        var e = r[2]
        if exc is None:
            exc = UnicodeDecodeError(name, data, e[0], e[1], e[2])
        else:
            exc.start = e[0]
            exc.end = e[1]
            exc.reason = e[2]
        var res = codecs.lookup_error(errors)(exc)
        if (not isinstance(res, tuple) or len(res) != 2 or not isinstance(res[0], str)
                or not isinstance(res[1], int)):
            raise TypeError("decoding error handler must return (str, int) tuple")
        parts.append(res[0])
        var newpos = res[1]
        if newpos < 0:
            newpos += n
        if newpos < 0 or newpos > n:
            raise IndexError("position %d from error handler out of bounds" % res[1])
        pos = newpos
    return ("".join(parts), pos, state)


def _as_text(obj, what):
    if isinstance(obj, str):
        return obj
    var s = str(obj)
    if not isinstance(s, str):
        raise TypeError("couldn't convert the object to " + what + ".")
    return s


def _as_data(obj):
    if isinstance(obj, bytes):
        return obj
    if isinstance(obj, (bytearray, memoryview)):
        return bytes(obj)
    raise TypeError("a bytes-like object is required, not '" + type(obj).__name__ + "'")


class MultibyteCodec:
    """A CJK codec (CPython's _multibytecodec.MultibyteCodec)."""

    def __init__(self, *args, **kwargs):
        raise TypeError("cannot create '_multibytecodec.MultibyteCodec' instances")

    def encode(self, input, errors=None):
        """Return an encoded string version of `input'."""
        var text = _as_text(input, "unicode")
        return (_encode(self._name, text, _errors_arg(errors), None, _FLUSH | _RESET)[0], len(text))

    def decode(self, input, errors=None):
        """Decodes 'input'."""
        var data = _as_data(input)
        var errs = _errors_arg(errors)
        if len(data) == 0:
            return ("", 0)
        return (_decode(self._name, data, errs, None, True)[0], len(data))

    def __repr__(self):
        return "<_multibytecodec.MultibyteCodec object at %#x>" % id(self)


MultibyteCodec.__module__ = "_multibytecodec"

_codecs_made = {}


def _codec(name):
    # the codec object _codecs_cn.getcodec(name) ... returns (one per name)
    var c = _codecs_made.get(name)
    if c is None:
        c = object.__new__(MultibyteCodec)
        c._name = name
        _codecs_made[name] = c
    return c


def _codec_of(cls):
    var c = getattr(cls, "codec", None)
    if not isinstance(c, MultibyteCodec):
        raise TypeError("codec is unexpected type")
    return c._name


class _MbErrors:
    # the errors attribute of CPython's stateful codec contexts
    def _get_errors(self):
        return self._errors

    def _set_errors(self, value):
        if value is None:
            raise AttributeError("cannot delete attribute")
        if not isinstance(value, str):
            raise TypeError("errors must be a string")
        self._errors = value

    errors = property(_get_errors, _set_errors)


class MultibyteIncrementalEncoder(_MbErrors):
    def __init__(self, errors="strict"):
        self._name = _codec_of(type(self))
        self._errors = _errors_arg(errors)
        self._state = _ny_mbc("encinit", self._name)
        self._pending = ""

    def encode(self, input, final=False):
        var text = self._pending + _as_text(input, "str")
        var r = _encode(self._name, text, self._errors, self._state, (_FLUSH | _RESET) if final else 0)
        self._state = r[2]
        var rest = text[r[1]:]
        if len(rest) > MAXENCPENDING:
            raise UnicodeError("pending buffer overflow")
        self._pending = rest
        return r[0]

    def getstate(self):
        var pend = self._pending.encode("utf-8")
        if len(pend) > MAXENCPENDING * 4:
            raise UnicodeError("pending buffer too large")
        var b = bytes([len(pend)]) + pend + self._state.to_bytes(8, "little")
        return int.from_bytes(b, "little")

    def setstate(self, state):
        if not isinstance(state, int):
            raise TypeError("setstate() argument must be int, not " + type(state).__name__)
        var b = state.to_bytes(1 + MAXENCPENDING * 4 + 8, "little")
        if b[0] > MAXENCPENDING * 4:
            raise UnicodeError("pending buffer too large")
        self._pending = b[1:1 + b[0]].decode("utf-8")
        self._state = int.from_bytes(b[1 + b[0]:1 + b[0] + 8], "little")

    def reset(self):
        # (CPython 3.11 runs the codec's reset and drops what it writes)
        self._state = _ny_mbc("encreset", self._name, self._state)[1]
        self._pending = ""


class MultibyteIncrementalDecoder(_MbErrors):
    def __init__(self, errors="strict"):
        self._name = _codec_of(type(self))
        self._errors = _errors_arg(errors)
        self._state = _ny_mbc("decinit", self._name)
        self._pending = b""

    def decode(self, input, final=False):
        var data = self._pending + _as_data(input)
        var r = _decode(self._name, data, self._errors, self._state, bool(final))
        self._state = r[2]
        var rest = data[r[1]:]
        if len(rest) > MAXDECPENDING:
            raise UnicodeError("pending buffer overflow")
        self._pending = rest
        return r[0]

    def getstate(self):
        return (self._pending, self._state)

    def setstate(self, state):
        if not isinstance(state, tuple) or len(state) != 2 or not isinstance(state[0], bytes) or not isinstance(state[1], int):
            raise TypeError("setstate(): illegal state argument")
        var st = state[1].to_bytes(8, "little")
        if len(state[0]) > MAXDECPENDING:
            raise UnicodeError("pending buffer too large")
        self._pending = state[0]
        self._state = int.from_bytes(st, "little")

    def reset(self):
        self._state = _ny_mbc("decreset", self._name, self._state)
        self._pending = b""


class MultibyteStreamReader(_MbErrors):
    def __init__(self, stream, errors="strict"):
        self._name = _codec_of(type(self))
        self.stream = stream
        self._errors = _errors_arg(errors)
        self._state = _ny_mbc("decinit", self._name)
        self._pending = b""

    def _iread(self, method, sizehint):
        if sizehint == 0:
            return ""
        var out = []
        var got = 0
        while True:
            var data = getattr(self.stream, method)() if sizehint < 0 else getattr(self.stream, method)(sizehint)
            if not isinstance(data, bytes):
                raise TypeError("stream function returned a non-bytes object (" + type(data).__name__ + ")")
            var endoffile = len(data) == 0
            if self._pending:
                data = self._pending + data
                self._pending = b""
            var rsize = len(data)
            if rsize > 0:
                var r = _decode(self._name, data, self._errors, self._state, endoffile or sizehint < 0)
                self._state = r[2]
                out.append(r[0])
                got += len(r[0])
                var rest = data[r[1]:]
                if len(rest) > MAXDECPENDING:
                    raise UnicodeError("pending buffer overflow")
                self._pending = rest
            if sizehint < 0 or got != 0 or rsize == 0:
                break
            sizehint = 1   # read 1 more byte and retry
        return "".join(out)

    def read(self, sizeobj=None):
        if sizeobj is None:
            sizeobj = -1
        elif not isinstance(sizeobj, int):
            raise TypeError("arg 1 must be an integer")
        return self._iread("read", sizeobj)

    def readline(self, sizeobj=None):
        if sizeobj is None:
            sizeobj = -1
        elif not isinstance(sizeobj, int):
            raise TypeError("arg 1 must be an integer")
        return self._iread("readline", sizeobj)

    def readlines(self, sizehintobj=None):
        if sizehintobj is None:
            sizehintobj = -1
        elif not isinstance(sizehintobj, int):
            raise TypeError("arg 1 must be an integer")
        return self._iread("read", sizehintobj).splitlines(True)

    def reset(self):
        self._state = _ny_mbc("decreset", self._name, self._state)
        self._pending = b""


class MultibyteStreamWriter(_MbErrors):
    def __init__(self, stream, errors="strict"):
        self._name = _codec_of(type(self))
        self.stream = stream
        self._errors = _errors_arg(errors)
        self._state = _ny_mbc("encinit", self._name)
        self._pending = ""

    def write(self, strobj):
        var text = self._pending + _as_text(strobj, "str")
        var r = _encode(self._name, text, self._errors, self._state, 0)
        self._state = r[2]
        var rest = text[r[1]:]
        if len(rest) > MAXENCPENDING:
            raise UnicodeError("pending buffer overflow")
        self._pending = rest
        self.stream.write(r[0])

    def writelines(self, lines):
        if isinstance(lines, (str, bytes)) or not hasattr(lines, "__getitem__"):
            raise TypeError("arg must be a sequence object")
        for s in lines:
            self.write(s)

    def reset(self):
        # (CPython's: only a pending tail is flushed, with the codec's reset)
        if not self._pending:
            return None
        var text = self._pending
        self._pending = ""
        var r = _encode(self._name, text, self._errors, self._state, _FLUSH | _RESET)
        self._state = r[2]
        if len(r[0]) > 0:
            self.stream.write(r[0])
        return None


for _c in (MultibyteIncrementalEncoder, MultibyteIncrementalDecoder, MultibyteStreamReader,
           MultibyteStreamWriter):
    _c.__module__ = "_multibytecodec"
