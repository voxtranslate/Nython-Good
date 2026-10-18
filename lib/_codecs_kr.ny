# nython: module    (import it by name: it runs in a module scope of its own)
# lib/_codecs_kr.ny - CPython's _codecs_kr (round 84): the codec objects of
# the Korean: EUC-KR (with KS X 1001:1998 Annex 3 make-up sequences), CP949
# and Johab codecs, for lib/encodings/ (src/builtins/nycjk.cpp has the
# codecs).
#
#     import _codecs_kr
#     _codecs_kr.getcodec('euc_kr').encode(...)
#
# getcodec(name) -> the _multibytecodec.MultibyteCodec of `name`; LookupError
# "no such codec is supported." for a name this module does not have.
# Not here: the __map_* capsules (C API only).

import _multibytecodec as _mbc

_CODECS = ('euc_kr', 'cp949', 'johab')


def getcodec(encoding):
    if not isinstance(encoding, str):
        raise TypeError("encoding name must be a string.")
    if encoding not in _CODECS:
        raise LookupError("no such codec is supported.")
    return _mbc._codec(encoding)
