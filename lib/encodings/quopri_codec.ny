# nython: module    (import it by name: it runs in a module scope of its own)
# lib/encodings/quopri_codec.ny - the quopri codec (round 83): quoted-printable over lib/codecs.ny's.
import codecs

_info = codecs.lookup('quopri')
encode = _info.encode
decode = _info.decode
Codec = codecs.Codec
IncrementalEncoder = _info.incrementalencoder
IncrementalDecoder = _info.incrementaldecoder
StreamWriter = _info.streamwriter
StreamReader = _info.streamreader


def getregentry():
    return _info
