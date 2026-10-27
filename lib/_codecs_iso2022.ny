# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/_codecs_iso2022.ny - CPython's _codecs_iso2022 (round 84): the codec
# objects of the ISO-2022: iso2022_jp (and _1, _2, _2004, _3, _ext) and
# iso2022_kr codecs, for lib/encodings/ (src/builtins/nycjk.cpp has the
# codecs).
#
#     import _codecs_iso2022
#     _codecs_iso2022.getcodec('iso2022_kr').encode(...)
#
# getcodec(name) -> the _multibytecodec.MultibyteCodec of `name`; LookupError
# "no such codec is supported." for a name this module does not have.
# Not here: the __map_* capsules (C API only).

import _multibytecodec as _mbc

_CODECS = ('iso2022_kr', 'iso2022_jp', 'iso2022_jp_1', 'iso2022_jp_2', 'iso2022_jp_2004', 'iso2022_jp_3', 'iso2022_jp_ext')


def getcodec(encoding):
    if not isinstance(encoding, str):
        raise TypeError("encoding name must be a string.")
    if encoding not in _CODECS:
        raise LookupError("no such codec is supported.")
    return _mbc._codec(encoding)
