# nython: module    (import it by name: it runs in a module scope of its own)
# lib/encodings/euc_jis_2004.ny - CPython 3.11's encodings/euc_jis_2004.py (round 84), unchanged:
# the euc_jis_2004 codec over _codecs_jp / _multibytecodec (src/builtins/nycjk.cpp).
#
# euc_jis_2004.py: Python Unicode Codec for EUC_JIS_2004
#
# Written by Hye-Shik Chang <perky@FreeBSD.org>
#

import _codecs_jp, codecs
import _multibytecodec as mbc

codec = _codecs_jp.getcodec('euc_jis_2004')

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
        name='euc_jis_2004',
        encode=Codec().encode,
        decode=Codec().decode,
        incrementalencoder=IncrementalEncoder,
        incrementaldecoder=IncrementalDecoder,
        streamreader=StreamReader,
        streamwriter=StreamWriter,
    )
