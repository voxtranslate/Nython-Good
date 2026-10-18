# nython: module    (import it by name: it runs in a module scope of its own)
# lib/encodings/idna.ny - the idna codec (round 83): IDNA (RFC 3490) over lib/codecs.ny's: ToASCII/ToUnicode per label, punycode, the ACE prefix; nameprep is lower-casing.
import codecs

_info = codecs.lookup('idna')
encode = _info.encode
decode = _info.decode
Codec = codecs.Codec
IncrementalEncoder = _info.incrementalencoder
IncrementalDecoder = _info.incrementaldecoder
StreamWriter = _info.streamwriter
StreamReader = _info.streamreader


def getregentry():
    return _info
