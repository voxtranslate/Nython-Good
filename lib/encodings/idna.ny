# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/encodings/idna.ny - the idna codec (round 83): IDNA (RFC 3490) over lib/codecs.ny's: ToASCII/ToUnicode per label, punycode, the ACE prefix; nameprep is RFC 3491's (round 84).
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
