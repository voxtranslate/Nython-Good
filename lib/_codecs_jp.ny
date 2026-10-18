# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/_codecs_jp.ny - CPython's _codecs_jp (round 84): the codec objects of
# the Japanese: Shift_JIS, CP932, EUC-JP, Shift_JIS-2004, EUC-JIS-2004 and the
# JIS X 0213:2000 variants codecs, for lib/encodings/ (src/builtins/nycjk.cpp
# has the codecs).
#
#     import _codecs_jp
#     _codecs_jp.getcodec('shift_jis').encode(...)
#
# getcodec(name) -> the _multibytecodec.MultibyteCodec of `name`; LookupError
# "no such codec is supported." for a name this module does not have.
# Not here: the __map_* capsules (C API only).

import _multibytecodec as _mbc

_CODECS = ('shift_jis', 'cp932', 'euc_jp', 'shift_jis_2004', 'euc_jis_2004', 'euc_jisx0213', 'shift_jisx0213')


def getcodec(encoding):
    if not isinstance(encoding, str):
        raise TypeError("encoding name must be a string.")
    if encoding not in _CODECS:
        raise LookupError("no such codec is supported.")
    return _mbc._codec(encoding)
