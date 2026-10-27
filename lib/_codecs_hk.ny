# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/_codecs_hk.ny - CPython's _codecs_hk (round 84): the codec objects of
# the Hong Kong: Big5-HKSCS (HKSCS-2004, with its combining pairs) codecs, for
# lib/encodings/ (src/builtins/nycjk.cpp has the codecs).
#
#     import _codecs_hk
#     _codecs_hk.getcodec('big5hkscs').encode(...)
#
# getcodec(name) -> the _multibytecodec.MultibyteCodec of `name`; LookupError
# "no such codec is supported." for a name this module does not have.
# Not here: the __map_* capsules (C API only).

import _multibytecodec as _mbc

_CODECS = ('big5hkscs',)


def getcodec(encoding):
    if not isinstance(encoding, str):
        raise TypeError("encoding name must be a string.")
    if encoding not in _CODECS:
        raise LookupError("no such codec is supported.")
    return _mbc._codec(encoding)
