# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/encodings/big5hkscs.ny - CPython 3.11's encodings/big5hkscs.py (round 84), unchanged:
# the big5hkscs codec over _codecs_hk / _multibytecodec (src/builtins/nycjk.cpp).
#
# big5hkscs.py: Python Unicode Codec for BIG5HKSCS
#
# Written by Hye-Shik Chang <perky@FreeBSD.org>
#

import _codecs_hk, codecs
import _multibytecodec as mbc

codec = _codecs_hk.getcodec('big5hkscs')

class Codec(codecs.Codec):
    encode = codec.encode
    decode = codec.decode

class IncrementalEncoder(mbc.MultibyteIncrementalEncoder,
                         codecs.IncrementalEncoder):
    codec = codec

class IncrementalDecoder(mbc.MultibyteIncrementalDecoder,
                         codecs.IncrementalDecoder):
    codec = codec

class StreamReader(Codec, mbc.MultibyteStreamReader, codecs.StreamReader):
    codec = codec

class StreamWriter(Codec, mbc.MultibyteStreamWriter, codecs.StreamWriter):
    codec = codec

def getregentry():
    return codecs.CodecInfo(
        name='big5hkscs',
        encode=Codec().encode,
        decode=Codec().decode,
        incrementalencoder=IncrementalEncoder,
        incrementaldecoder=IncrementalDecoder,
        streamreader=StreamReader,
        streamwriter=StreamWriter,
    )
