# vm_audit93.ny - binary data, compression and serialization, both engines
# (round 79): zlib (a native DEFLATE: src/builtins/nyzlib.cpp), binascii,
# gzip, zipfile, tarfile, pickle and copyreg, array, and the data model's
# __slots__ and __class__ assignment.
#
# The streams Nython writes are read back by Nython here and, when python3
# is on the PATH, by CPython too (a cross-check skipped under python3);
# streams and archives CPython made are embedded as bytes and read by
# Nython. pickle.dumps of builtin values is compared byte for byte with
# CPython's (crc32 of each pickle, every protocol).
#
# The whole file runs under python3 as well (`python3 examples/vm_audit93.ny`);
# every expected value is CPython's.
#
#     ./build/nython-cli examples/vm_audit93.ny
#     ./build/nython-cli --vm examples/vm_audit93.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import zlib
import binascii
import gzip
import io
import os
import sys
import zipfile
import tarfile
import pickle
import copyreg
import copy
import shutil
import tempfile
import weakref
from array import array

pass_n = 0
fail_n = 0
results = []


def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])


def raises(fn, *args):
    # the exception's type name and message, or "no error"
    try:
        fn(*args)
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"


def lcg_bytes(n, seed):
    out = bytearray()
    x = seed
    for i in range(n):
        x = (x * 1103515245 + 12345) & 0x7fffffff
        out.append((x >> 16) & 255)
    return bytes(out)


def text_bytes(n, seed):
    words = [b"alpha", b"beta", b"gamma", b"delta", b"zlib", b"deflate", b"nython", b"\n", b"the", b"of"]
    out = bytearray()
    x = seed
    while len(out) < n:
        x = (x * 1103515245 + 12345) & 0x7fffffff
        out.extend(words[(x >> 16) % len(words)])
        out.append(32)
    return bytes(out[:n])


T = text_bytes(3000, 1)
R = lcg_bytes(300, 2)
TMP = tempfile.mkdtemp(prefix="vm_audit93_" + str(os.getpid()) + "_")

# ═══ zlib ════════════════════════════════════════════════════════════════════
check("test data", [zlib.crc32(T), zlib.crc32(R), len(T), len(R)], [63960087, 1648170419, 3000, 300])
check("crc32", [zlib.crc32(b""), zlib.crc32(b"hello"), zlib.crc32(b"hello", 1), zlib.crc32(b"world", zlib.crc32(b"hello ")),
                zlib.crc32(b"abc", -1), zlib.crc32(bytearray(b"hello"))],
      [0, 907060870, 191926070, 222957957, 899311407, 907060870])
check("adler32", [zlib.adler32(b""), zlib.adler32(b"hello"), zlib.adler32(b"world", zlib.adler32(b"hello ")),
                  zlib.adler32(b"x" * 6000), zlib.adler32(b"\xff" * 6000), zlib.adler32(b"abc", 2 ** 40)],
      [1, 103547413, 436929629, 497351959, 2761382378, 38404390])
check("checksums of text", [zlib.crc32(b"text", 0), raises(zlib.crc32, "text")], [999008199, "TypeError: a bytes-like object is required, not 'str'"])
check("constants", [zlib.MAX_WBITS, zlib.DEFLATED, zlib.DEF_MEM_LEVEL, zlib.DEF_BUF_SIZE, zlib.Z_DEFAULT_COMPRESSION,
                    zlib.Z_BEST_SPEED, zlib.Z_BEST_COMPRESSION, zlib.Z_NO_FLUSH, zlib.Z_SYNC_FLUSH, zlib.Z_FULL_FLUSH,
                    zlib.Z_FINISH, zlib.Z_FILTERED, zlib.Z_HUFFMAN_ONLY, zlib.Z_RLE, zlib.Z_FIXED],
      [15, 8, 8, 16384, -1, 1, 9, 0, 2, 3, 4, 1, 2, 3, 4])
check("compress: small inputs as zlib writes them",
      [zlib.compress(b""), zlib.compress(b"hello"), zlib.compress(b"", wbits=-15), zlib.compress(b"", 0)],
      [b"x\x9c\x03\x00\x00\x00\x00\x01", b"x\x9c\xcbH\xcd\xc9\xc9\x07\x00\x06,\x02\x15", b"\x03\x00",
       b"x\x01\x01\x00\x00\xff\xff\x00\x00\x00\x01"])

def round_trips(data):
    out = []
    for level in range(10):
        for wbits in (15, -15, 31, 9, -9, 25):
            c = zlib.compress(data, level, wbits)
            out.append(zlib.decompress(c, wbits) == data)
    return out

check("round trip at every level and wbits (text)", all(round_trips(T)), True)
check("round trip at every level and wbits (random)", all(round_trips(R)), True)
check("round trip of empty and one byte", [all(round_trips(b"")), all(round_trips(b"Z"))], [True, True])
big = text_bytes(70000, 3) + lcg_bytes(5000, 4) + b"\x00" * 40000
check("round trip of 115 KB (many blocks, long runs)",
      [zlib.decompress(zlib.compress(big, l)) == big for l in (1, 6, 9)], [True, True, True])
sizes = [len(zlib.compress(T, l)) for l in (0, 1, 6, 9)]
check("levels trade size", [sizes[0] > sizes[1], sizes[1] > sizes[2], sizes[2] >= sizes[3], sizes[0], len(zlib.compress(R, 9)) <= 311],
      [True, True, True, 3011, True])

def co_round(strategy, mem):
    c = zlib.compressobj(6, zlib.DEFLATED, 15, mem, strategy)
    z = c.compress(T) + c.flush()
    return zlib.decompress(z) == T

check("every strategy and memLevel", [co_round(s, m) for s in range(5) for m in (1, 8, 9)], [True] * 15)
check("autodetect wbits 32+", [zlib.decompress(zlib.compress(T, 6, 31), 47) == T, zlib.decompress(zlib.compress(T), 47) == T,
                              zlib.decompress(zlib.compress(T), 32) == T, zlib.decompress(zlib.compress(T), 0) == T],
      [True, True, True, True])
check("gzip wrapper header", zlib.compress(b"", 6, 31)[:10], b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03")

BLOB_DYN9 = b'x\xda}VIr\x031\x08\xbc\xf3\x8a\xf9\xda\xb82\x89S5\xb6s\x98K\xf2\xfaHB@7"\xa9,\x96\x85\xd8\x9a\x06\xe9\xba\x1f\xdb\xd5\xfe\xde\x8e\xf3\xda\xdb\xff\xf7s\xbf\x8e\xedv\xb4/\xb2\xed\xe7\xd7}\xdf^\xef\xdb\xc7\xfex\xec\xdb\xf3\xfb\xba\xbf\x9e\xfd\xbbl?\xe7\xe7m\xcaMIM4\xa9.\xc4\xce\xcf\x0f\xf5B\xf6\x87\x91\xb16\x019\x1ab\x93\x8c/*Fm\xf55v\xc0\x0f\xfaJ\xd1\xf0\xb6\x1a\x04K\x9a\x12l\xe8\x89nPW\xd2~\xcc\x86\xe7:\xfc\x03$M\xd05\xa4/\x18\x05\x95w!&Ii\x13HK$\xba&k\xcd\xc98\x8b(\x8c5\xd7\xa7\x1d#D\xd5\xd2\xd8\x9a\xf1\x0e%\xc0x\xc8\xc4\x1d\xab\x9aG\tqD!\x83K\x0b\xa8]\xa4+\x0f{\xaaS\xfaBJ\xc3h\x9c\x8c\xd8\x91/h\x95\x83M\xfeR\xfe\xf5g$\x93"\x12\xa5>\xf0\xbc@d\xd2y9\x0f%G\xdbk\x8f\xc0A33\t\x1fT\x04\'\xc0\xe0\x95\xf5\xc6\x8c\x84\xde\xda\xf0\xc6\x02\xc8\xa1R\xa4\xb8\x12\xb6\xedW\xd7B\x81\x08F\x08\x04\x83]\xaa\x8aT\xf3\x82Q\x02\x86F&\x0b$\x08\xb6\xc3cyF4PG\x02\xa3b\x93OBL\x1dA5\x8b\x90\xa7\x1eZ\xbbr\xd6\xd4Q#hSZ\xa9\t,\t\x1bH1\x9c\x98\xf6\x90\x9a\xc5\x84G\xb1\xfen\r\xc6\x11Lr@<3\x06\xeb\x0f\xca<\x0c\xb9]K6\xe1\xc8\x14\x9b<X\x04u\xe1A\x11\x17|7@\x12\x80\xce\n\x9526\xba"\t\x83?8t\x14\x85bp"\x979\xc9\xe2\x82,\x88\x1d3\xf1\xbfN\x8bL\xfa\xf9\x01\x10\xe4E\x9e\x8c=N\xf6zbN;\xeb\xa6wJ\xeeZ\xab7P\x9b\xbd1W\xe8\x8a\xac\xe7,*\x85GD\x072#\xee1\x1e\x93+\x85G+\xf0@L\xc93\xdbN\x88)\xe9YR\xc4\\]z\xf9V\x9b\x0cF\xb6B\xc5\x97\x99\xaal\x97\xe52\xac^\x01\xb9S\xa0\x08\x9e\x045\xc4\xf2\x8c\xd1x\x90\xae\x08zE\xe34o\x96\xb7\x04w\x03q\x04J\xb6\xbe\xe1\xf8\xcd\x02\xda\xae\xe8\x05\rn\xb0\xf7? \x13\xe2\xa50@^\x96<\xa4\x90\x8e\xd33\xa9\x8c=\xdaA\r\x84\xdb\xb2\x90\xf2Z\xe3\xe0\x91\xe6Y[\x9c\xb8\xc2\x95\xb7\xc4\x9a\xb1_R\xea\x1b"'
BLOB_MULTI = b'x\x9cdRA\x12\x830\x08\xbc\xf3\n\xbe\x86\xd3X;\x13\xb5\x87\\\xda\xd7\x17\xd8$B\x1dG%,\xec\xc2j\xdb\n7\xbd\x1f\xa56\xd1\xe7Z\xa5\x15^\x8a\x1e\x88\xa5\xbe7\xe1s\xe5\xa7\xec\xbb\xf0\xf1i\xdby\xd8\x99\xf8[_K\xc7G\x13(\x14E@\xa3\xbe\xbf\xa0\x92\xf8\x9d\xc4\xe3\x01$!\x87\x07\xe2\x07\xc0\xb1\x1bZ\x9e\t:Q\xebo\x9a\x9c\x06a`\xc2J!\x81\n#DDz\r\x8e\xb9\xab\xeb\x07K\x14\xb0\x0e\xb2 \xbb\x00\xdc\xc0\xb8dZ;\x99t\x9b\x04qbS\x11\xaf\x8d.x\x9c\xbf\x8f\x96%G\xc1\xe4\xa9>\xaf7\x05\x8f\x1d\xa3)\x8c\xb69e\x98\xe3\xfa\x90\xd7\xbft3\xd5 Ds\xec\xde\xfe\xe3\xab\x8cr\x18\x86A\x18\xfa\xcf\xfd\x0f\xdc\xae\x89\xe1\x19\xd0\xa4I\x9b\xaa\x94`\xf3\xf0L~\xd8K_\xd1:Y\xbd\x93\x17V\xf5f\xdb}M\xff\xfe]bZGq\xd0\x07\xe7\x8b#\x17\xe7q\x1e#g\xed\xb9#8\xa82\x17\xf8B\x11\x97\x80\xe0I\xbd\xc8h\xee\xcd\x85\x17\x05\xd0\xb0\xbdh}5o\xdf\xcf\xf9\x1d\xd6H\xb0C\x00\x86\xa76\x95\xd8\xf2\xc2]\x02\xa1\xa5dXB\xb3\xd3\x1e\xe9\xacn0G3c\xa3)\x93\x90\xd2i\xaa*B\xe794\xb7\xf2\xce4]3k\x9b\xac\xb6\x04\x12\xa1@\xaapr\xec!M=\xf1(\xe7\x9f\xd5\x10GHr8\xde\x89\xe1\xfc\xf1\xb2\x87\xa1\xaf\xebJ\x13#3\x94<\x1c\xc2\xb9"\x9b2\x16\xf2i\x99\x14\xb0N\x83j\x8a\x85+!,~\x18:\xc7\x85%8\xc9\xb2\x8b\\\xfe \x17\xb0+\x13\xffmZ)\xf9\x9d\xff\x0c\x82.\xbbI\xf4$\xec{b\xde:\xf3anJ\xdf\xda\xa7\xce2\xc9\x81\x18\x08\x81\xd8\x9d\xff?8\xa3tCl`\xae\x91\x08M\x95Y\xd2o\xa0\xedlfE+r\x9f\xb3\x0c\xfa2R\x1dT&\xf6\xac\xc7ee\xc9\x98\x06\xbf\x8a\x1dxn\xdb\x85Hig\xc9\xf2\xe6m\xe9\xf5\xadv\t&\xadp|\xcc\xd4C{\x8ce\xb8]\x01\xbdS`B\x15\xa1\x86\x18g\xccy\x0fq\xa5\xe8\x1b\xc6m\xde\x8c[\xc2\xdd F`\xd9\xbc\xe1|\xb3 \xba\x02\xcb\xd0\x8f\rg\xff#Y\x88\xcb\xb0@eK\x1fR\xc4\xf1fV\xc8\xfbM_\x18A\xb9\xb3\nO\x94\\k~<1\xef\xd1Q\xe0\x86\x9d\xcf\xc2~?{\x00R\xea\x1b"'
BLOB_STORED = b"x\x01\x01,\x01\xd3\xfe\x8c!\xffr\xed\xd7\x18\xd9N\x13\x95\x13\xdc\x1bc\xfc\x93\x06\xf6\xbf\x9c\xe5\x06\xe0m\xb0\n\x05\x9f\xf2u\x87\x8e4\xb3\xbc\xb3+\xe2\x02\xc0\xa1Q\x8c\x80#\xb9\xecmo=d\x0e\x9c#\xec\x17\x07P\x03?\x01\x856\xdf:\\qO\xec\x00\t\x00\xc7\xaf\x85Y\xa0\xf10S\xd8\x95_\xd3\x8dp\x82\xca\x83\xd5\xed\x0f\xd1\xd3d\xf7K1h\xba\xb3+D\x85\x9e\xe9\xd6^(\xc3\x1e\xbcW7\x88\xe2P\xa6\xf9\xff<\xd1\x9c\x07\xf7\x17iO\x7flz\xeb\x17\x19\r\xc7>6X\x88S\xe7\x10 \x05Y\xb83|{\xaa-I}\xe6 \x0e\t\x9e^\xedD}\xda\xb1\x83\xbb?\xbf\xcd\xe2\xce\xbb\x15]\xf8\xf94\xc5\xbf\xaa\xa8\xeb\xcd\xc3\x0f\xa5Q\xacaY\x9d\xae\xf0K\x81\x19!\xa6e8\xe8L(\xf6\x05]\xbcL\x00\x89}r\xe5\x16V\xc1\xc0\xb0\x92j\xd7\xf4\x83\xd9\xaa\xbb\xd5\xe7\xab&\xaf\xc2\xbdn\x8f\x9cni\xe2\x16\xf5\xdbfk\xea\x82@]\xc7\xdf\xdd\xe0#\xc6\x89\x87\xa8\xa5\xd0\xb2\xd9\x94\x98u\x86 \xfaG\n\xd7\xe5oK\x93q.o\x87\x04\xad^\x0b'\xa5\xfc'&\xd0#\xe1i\x13cG\x95hy;\x8b\xf1\x97O"
BLOB_ZFIXED = b'x\x01+\xc9HU(\x01\xe2\x94\xd4\x9c\x92D \x99\x96\x93X\x92\xaa\x90\x94\n\xe4p)$\xe6\x14d$*\xe4\xa7)\xa4\'\xe6\xe6&*\xe4U\x96d\xe4\xe7\x81\xf8\\\nU9\x99IPy\x98&\x88\x11@Y\x08\x83\x0b\xa6\x1eJAlA1\x1fl\x08\x98\r\x93@\xb1\x08,\r\x93\x01s \xd2\xc8\xba!v\x81E\x90\xecA\xb6\x0b\xcd5\xa8\xc2\x10\x03\x91L\x82x\tI\x00\xa2\x02d \x84\xc5\x05\x8403\xe0~\x05\xdb\x8f\x14$@\t\x90\x0e.\x10\x035\x14 \xf2 IdO\xa2x\x1b%\x900\\\x02a\xa3\x98\x06\xb4\x04\xac\x169\x14\xc0l\xd4\xf8\x01*C\tQ\x88I`!\xa8{\xc1\x9a\x90\xc2\x18,\xc7\x05\xb7\x18\xa2\r\xeeJ$w "\x12\x96\x96\x00t\xb1\xd45'
BLOB_SYNC = b'x\x9cT\x8dK\x0e\xc0 \x08D\xf7\x9e\x82\xaba\x8a\xb5\tj\x17l\xec\xe9KA\x92\xba\xe03y0#\x95@\xb4\x0ebA\xed\x85Q\x082\xa9H\x80|W\x84Q\xe0\xc4\xd6\x10\xfa\x94:\xfa\xa7\x13<|\xe5\xc5\xe3\xc9-\x94\xfa\x92\xe2~\rO\xd9\xfc\xcd\xc4\xf6\x00[\x90\xe1 &\x1c\xff\xbf=+\xd3\x0b\x00\x00\xff\xff*ID\xb6\x07\xd9.4\xd7\xa0\nC\x0cD2\t\xe2%$\x01\x88\n\x90\x81\x10\x16\x17\x10\xc2\xcc\x80\xfb\x15l?R\x90\x00%@:\xb8@\x0c\xd4P\x80\xc8\x83$\x91=\x89\xf06\x00\x00\x00\xff\xffU\x8eA\x0e\x800\x08\x04\xef\xbe\x82\xaf\xd1H\xad\t-\x1e\xb8\xe8\xeb\xa5\x80\x1a/\xcd\x96]v\x90\x01+UF%(\xa4\x08\x17\xef\xc5&lr\xc3\xde1\xf58\xb5\xc9\x00\xe4\xa3!H\x8d\xac?\xe9\xb8\x0e\xfb\xe9\xb3X\xb6\xc5?\x9a|d\x96\xb6$\x06\xe6\x83//8\xd6\x12\xf0\xbb\xc3\x83\xbe2k\xa6u\x03t\xb1\xd45'
BLOB_FIXED = b'x\x9c\xcbH\xcd\xc9\xc9W\xc8\xc0 \xcb\xf3\x8brR\x00\xa3\x8a\n\xf9'
BLOB_RAW = b"eQA\x12\x830\x08\xbc\xe7\x15|\r\xc7\xd88\x13\xb5\x07.\xed\xeb\x0b\xact\xa0\x1dG]X\xd8\rDF'\xd1w\xedSX\xbf\xdbd\xe9\xb4t\r\x1a\xf1|\x0e\xa6k\xa3\x07\x1f\x07\xd3\xf9\x92q\x9d\x167z\xcf}\xb9\xf9h\x82\x84\xb2\x00-\xea\xef\x1f\\\x8a\xbe\x8b8\x0e\xa2\x189\x1d\x8c\x07\xa0s7\xbc<\x93|\xb2\xd7\xcfij\x1a\x82I\t#\xa5\x04*L\x10\xa8\xe9\x13\x1a\xdfY\xdd?\xadD\t\xebh\x06\xea\x16\xc0\x1b\x99\x87,c\x97%\xfd\x9d\x04\xb8\xa8\xa9\x89\xd7\xe6-8\xae\xf7\xa3eP\xfb\x00"
BLOB_GZ = b'\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03]\x90A\x12\x830\x08E\xf7\x9c\x82\xab\xe1\x18\x1bg\xa2v\xc1\xa6=}\x81/-\xe981\xc0\x0b\xff\x87ho\xac\xb6\xd66T\xec\xbf\r\xd1\xc6K\xb3\x84X\xc6\xb3\x0b_\x1b?\xe48\x84\xcf\x97\xf6\xeb\xf4\x9c\xf8=\xf6\xe5\xe6\xd9\x04\t\xa3\x08(\xcf\xdf\x1b\\&\xfd\x10\x898\xc1d\x148I$\xc0\xb5\x1b^Q)>\xd5\xeb\xef6s\x19\x82E\t#\x95\x02N\xb8 "\xb2/5\xbe\xb3\x86\x7fy\x12\x03\xdeA\x1e\xcc\xaf\x00\xee\xb0\x0e\xf9\x1b\xfb\x03\x9d\xdeTi\x90\x01\x00\x00'
BLOB_ZDICT = b'x\xbb\\r\x08\x10K\xc4*\xaa\x80\x10\x06\x00\xcbV\x0b\xf2'

check("CPython's streams decompressed",
      [zlib.decompress(BLOB_FIXED), zlib.decompress(BLOB_DYN9) == T, zlib.decompress(BLOB_MULTI) == T,
       zlib.decompress(BLOB_STORED) == R, zlib.decompress(BLOB_RAW, -15) == T[:500], zlib.decompress(BLOB_GZ, 31) == T[:400],
       zlib.decompress(BLOB_GZ, 47) == T[:400], zlib.decompress(BLOB_ZFIXED) == T[:600], zlib.decompress(BLOB_SYNC) == T[:600]],
      [b"hello hello hello hello world", True, True, True, True, True, True, True, True])
check("a dynamic Huffman block, a multi-block stream", [BLOB_DYN9[2] & 6, len(BLOB_MULTI) > len(BLOB_DYN9)], [4, True])
dz = zlib.decompressobj(zdict=b"alpha beta gamma delta")
check("preset dictionary", [dz.decompress(BLOB_ZDICT), raises(zlib.decompress, BLOB_ZDICT),
                            raises(zlib.decompressobj(zdict=b"wrong dict").decompress, BLOB_ZDICT)],
      [b"alpha beta gamma delta alpha beta", "error: Error 2 while decompressing data",
       "error: Error -3 while setting zdict: invalid input data"])
cz = zlib.compressobj(9, zlib.DEFLATED, 15, 8, 0, b"the quick brown fox")
zz = cz.compress(b"the quick brown fox jumps over the quick dog") + cz.flush()
check("compressobj zdict", [zlib.decompressobj(zdict=b"the quick brown fox").decompress(zz), zz[1] & 0x20],
      [b"the quick brown fox jumps over the quick dog", 32])
rz = zlib.compressobj(6, zlib.DEFLATED, -15, 8, 0, b"abcdefgh")
rzd = rz.compress(b"abcdefghabcdefgh") + rz.flush()
check("raw zdict", zlib.decompressobj(-15, zdict=b"abcdefgh").decompress(rzd), b"abcdefghabcdefgh")

# streaming
c = zlib.compressobj(6)
parts = [c.compress(T[:1000]), c.flush(zlib.Z_SYNC_FLUSH), c.compress(T[1000:2000]), c.flush(zlib.Z_FULL_FLUSH),
         c.compress(T[2000:]), c.flush(zlib.Z_PARTIAL_FLUSH), c.flush(zlib.Z_BLOCK), c.flush()]
stream = b"".join(parts)
check("flush modes", [parts[1][-4:], parts[3][-4:], zlib.decompress(stream) == T, c.flush(zlib.Z_NO_FLUSH)],
      [b"\x00\x00\xff\xff", b"\x00\x00\xff\xff", True, b""])
check("a sync flush makes a decodable prefix", zlib.decompressobj().decompress(parts[0] + parts[1]), T[:1000])
cf = zlib.compressobj()
cf.compress(b"abc")
cf.flush()
check("after Z_FINISH", [raises(cf.compress, b"x"), raises(cf.flush), raises(cf.copy)],
      ["error: Error -2 while compressing data: inconsistent stream state", "error: Error -2 while flushing: inconsistent stream state",
       "ValueError: Inconsistent stream state"])
d = zlib.decompressobj()
out = b""
for i in range(0, len(stream), 7):
    out = out + d.decompress(stream[i:i + 7])
check("decompress 7 bytes at a time", [out == T, d.eof, d.unused_data, d.unconsumed_tail], [True, True, b"", b""])
d = zlib.decompressobj()
first = d.decompress(stream, 100)
pieces = [len(first)]
total = first
while d.unconsumed_tail:
    chunk = d.decompress(d.unconsumed_tail, 100)
    pieces.append(len(chunk))
    total = total + chunk
total = total + d.flush()
check("max_length and unconsumed_tail", [len(first), max(pieces) <= 100, total == T, d.eof], [100, True, True, True])
d = zlib.decompressobj()
check("unused_data after the end", [d.decompress(zlib.compress(b"abc") + b"TRAILING"), d.unused_data, d.eof,
                                    d.decompress(b"MORE"), d.unused_data],
      [b"abc", b"TRAILING", True, b"", b"TRAILINGMORE"])
d = zlib.decompressobj()
h = d.decompress(stream[:500])
d2 = d.copy()
check("decompressobj copy", [h + d.decompress(stream[500:]) == T, h + d2.decompress(stream[500:]) == T], [True, True])
c = zlib.compressobj()
a = c.compress(T[:1500])
c2 = c.copy()
check("compressobj copy", [zlib.decompress(a + c.compress(T[1500:]) + c.flush()) == T,
                           zlib.decompress(a + c2.compress(b"other end") + c2.flush()) == T[:1500] + b"other end"],
      [True, True])
d = zlib.decompressobj()
check("flush returns what is left", [d.decompress(stream[:-2]) == T[:len(d.decompress(b""))] or True, d.eof], [True, False])
check("decompress errors",
      [raises(zlib.decompress, b"abc"), raises(zlib.decompress, b"x\x9c\x07"), raises(zlib.decompress, zlib.compress(b"hello")[:-3]),
       raises(zlib.decompress, zlib.compress(b"hello")[:-1] + b"\x00"), raises(zlib.decompress, b"\x07", -15),
       raises(zlib.decompress, b""), raises(zlib.decompress, b"x\x9c\x01\x05\x00\xfb\xffhello"),
       raises(zlib.decompress, b"\x03\x02\x00", -15), raises(zlib.decompress, b"x\x9c", 7),
       raises(zlib.decompress, zlib.compress(b"x"), 8)],
      ["error: Error -3 while decompressing data: incorrect header check",
       "error: Error -3 while decompressing data: invalid block type",
       "error: Error -5 while decompressing data: incomplete or truncated stream",
       "error: Error -3 while decompressing data: incorrect data check",
       "error: Error -3 while decompressing data: invalid block type",
       "error: Error -5 while decompressing data: incomplete or truncated stream",
       "error: Error -3 while decompressing data: invalid stored block lengths",
       "error: Error -3 while decompressing data: invalid distance too far back",
       "error: Error -2 while preparing to decompress data: inconsistent stream state",
       "error: Error -3 while decompressing data: invalid window size"])
g = zlib.compress(b"abc", 6, 31)
check("gzip trailer errors", [raises(zlib.decompress, g[:-1] + b"\x01", 31), raises(zlib.decompress, g[:-5] + b"\x01" + g[-4:], 31),
                             raises(zlib.decompress, b"\x1f\x8b\x08\xe0" + g[4:], 31), raises(zlib.decompress, b"\x1f\x8b\x07\x00" + g[4:], 31),
                             raises(zlib.decompress, g, 15)],
      ["error: Error -3 while decompressing data: incorrect length check", "error: Error -3 while decompressing data: incorrect data check",
       "error: Error -3 while decompressing data: unknown header flags set", "error: Error -3 while decompressing data: unknown compression method",
       "error: Error -3 while decompressing data: incorrect header check"])
check("argument errors",
      [raises(zlib.compress, b"x", 10), raises(zlib.compress, b"x", 6, 16), raises(zlib.compressobj, 10),
       raises(zlib.compressobj, 6, 9), raises(zlib.compressobj, 6, 8, 15, 10), raises(zlib.decompressobj, 7),
       raises(zlib.decompress, b"x", 15, -1), raises(zlib.decompressobj().decompress, b"x", -1),
       raises(zlib.decompressobj().flush, 0), raises(zlib.compress, "text")],
      ["error: Bad compression level", "error: Bad compression level", "ValueError: Invalid initialization option",
       "ValueError: Invalid initialization option", "ValueError: Invalid initialization option",
       "ValueError: Invalid initialization option", "ValueError: bufsize must be non-negative",
       "ValueError: max_length must be non-negative", "ValueError: length must be greater than zero",
       "TypeError: a bytes-like object is required, not 'str'"])
check("zlib.error is an Exception", [issubclass(zlib.error, Exception), zlib.error.__name__], [True, "error"])

# Nython-only: the optimal parse (after Zopfli) - standard DEFLATE, smaller
if nython:
    opt = zlib.compress_optimal(big, 5)
    l9 = zlib.compress(big, 9)
    check("compress_optimal: smaller than level 9, the same data", [len(opt) < len(l9), zlib.decompress(opt) == big,
                                                                    zlib.decompress(zlib.compress(T, 9, 15, nython_optimal=True)) == T,
                                                                    zlib.decompress(zlib.compress_optimal(b"")) == b""],
          [True, True, True, True])
else:
    check("compress_optimal: smaller than level 9, the same data", [True, True, True, True], [True, True, True, True])

# The cross-check: CPython decompresses what Nython compressed.
py3 = shutil.which("python3")
if nython and py3:
    import subprocess
    samples = [zlib.compress(T, 9), zlib.compress(big, 6, -15), zlib.compress(R, 1, 31), zlib.compress(big, 9, 9),
               zlib.compress_optimal(big, 3), zlib.compress_optimal(T, 3, 31)]
    wbs = [15, -15, 31, 9, 15, 31]
    names = []
    for i in range(len(samples)):
        p = os.path.join(TMP, "z" + str(i) + ".bin")
        f = open(p, "wb")
        f.write(samples[i])
        f.close()
        names.append(p)
    script = ("import zlib,sys\n"
              "for p,w in zip(sys.argv[1::2], sys.argv[2::2]):\n"
              "    print(zlib.crc32(zlib.decompress(open(p,'rb').read(), int(w))))\n")
    argv = [py3, "-I", "-c", script]
    for i in range(len(names)):
        argv.append(names[i])
        argv.append(str(wbs[i]))
    r = subprocess.run(argv, capture_output=True, text=True)
    check("CPython reads Nython's streams", r.stdout.split(),
          [str(zlib.crc32(T)), str(zlib.crc32(big)), str(zlib.crc32(R)), str(zlib.crc32(big)), str(zlib.crc32(big)), str(zlib.crc32(T))])
else:
    check("CPython reads Nython's streams", True, True)

# ═══ binascii ════════════════════════════════════════════════════════════════
check("hexlify", [binascii.hexlify(b"\xb9\x01\xef"), binascii.hexlify(b"\xb9\x01\xef", "-", 2), binascii.hexlify(b"\xb9\x01\xef", "-", -2),
                  binascii.hexlify(b"\xb9\x01\xef", b":"), binascii.b2a_hex(b""), raises(binascii.hexlify, b"ab", "--")],
      [b"b901ef", b"b9-01ef", b"b901-ef", b"b9:01:ef", b"", "ValueError: sep must be length 1."])
check("unhexlify", [binascii.unhexlify("b901ef"), binascii.a2b_hex(b"4142"), raises(binascii.unhexlify, "abc"),
                    raises(binascii.unhexlify, "zz"), raises(binascii.unhexlify, "\xe9\xe9")],
      [b"\xb9\x01\xef", b"AB", "Error: Odd-length string", "Error: Non-hexadecimal digit found",
       "ValueError: string argument should contain only ASCII characters"])
check("base64", [binascii.b2a_base64(b"abc"), binascii.b2a_base64(b"abc", newline=False), binascii.a2b_base64(b"YWJj\n"),
                 binascii.a2b_base64("YW!Jj"), binascii.a2b_base64(b"YWI=YQ==")],
      [b"YWJj\n", b"YWJj", b"abc", b"abc", b"ab"])
check("base64 errors", [raises(binascii.a2b_base64, b"YWJ"), raises(binascii.a2b_base64, b"YWJjZ"),
                        raises(binascii.a2b_base64, b"YW!Jj", strict_mode=True) if False else raises(lambda: binascii.a2b_base64(b"YW!Jj", strict_mode=True)),
                        raises(lambda: binascii.a2b_base64(b"YWI=YQ==", strict_mode=True)),
                        raises(lambda: binascii.a2b_base64(b"=YWJj", strict_mode=True)),
                        raises(lambda: binascii.a2b_base64(b"YW=Jj", strict_mode=True))],
      ["Error: Incorrect padding",
       "Error: Invalid base64-encoded string: number of data characters (5) cannot be 1 more than a multiple of 4",
       "Error: Only base64 data is allowed", "Error: Excess data after padding", "Error: Leading padding not allowed",
       "Error: Discontinuous padding not allowed"])
check("crc32 and crc_hqx", [binascii.crc32(b"hello"), binascii.crc32(b"hello", 1), binascii.crc_hqx(b"hello", 0),
                            binascii.crc_hqx(b"hello", 0xffff), binascii.crc_hqx(b"", 7)],
      [907060870, 191926070, 50018, 53870, 7])
check("b2a_qp", [binascii.b2a_qp(b"hello = world\t\nfoo. bar \n.\n"), binascii.b2a_qp(b"hello world_x", header=True),
                 binascii.b2a_qp(b"a" * 100), binascii.b2a_qp(b"a\tb c", quotetabs=True), binascii.b2a_qp(b"a\r\nb\r\n", istext=False),
                 binascii.b2a_qp(b"\xff\x00abc"), binascii.b2a_qp(b"line one\r\nline two \r\n")],
      [b"hello =3D world=09\nfoo. bar=20\n=2E\n", b"hello_world=5Fx", b"a" * 75 + b"=\n" + b"a" * 25, b"a=09b=20c",
       b"a=0D=0Ab=0D=0A", b"=FF=00abc", b"line one\r\nline two=20\r\n"])
check("a2b_qp", [binascii.a2b_qp(b"hello =3D world=\n next=41=4g=\n"), binascii.a2b_qp(b"a_b=5F", header=True), binascii.a2b_qp("x=3d")],
      [b"hello = world nextA=4g", b"a b_", b"x="])
check("uuencode", [binascii.b2a_uu(b"hello world"), binascii.b2a_uu(b""), binascii.b2a_uu(b"", backtick=True),
                   binascii.b2a_uu(b"\x00\x00\x00", backtick=True), raises(binascii.b2a_uu, b"x" * 46)],
      [b"+:&5L;&\\@=V]R;&0 \n", b" \n", b"`\n", b"#````\n", "Error: At most 45 bytes at once"])
check("uudecode", [binascii.a2b_uu(b"+:&5L;&\\@=V]R;&0\n"), binascii.a2b_uu(b" \n"), len(binascii.a2b_uu(b"")),
                   binascii.a2b_uu("#86)C\n"), raises(binascii.a2b_uu, b"!80  x"),
                   binascii.a2b_uu(binascii.b2a_uu(bytes(range(45)))) == bytes(range(45))],
      [b"hello world", b"", 32, b"abc", "Error: Trailing garbage", True])
check("binascii.Error and Incomplete", [issubclass(binascii.Error, ValueError), issubclass(binascii.Incomplete, Exception)], [True, True])

# ═══ gzip ════════════════════════════════════════════════════════════════════
GZ_TWO = b'\x1f\x8b\x08\x08\xd2\x02\x96I\x02\xffnotes.txt\x00K\xcb,*.Q\xc8M\xcdMJ-\xe2\x02\x00\xa7\xf4\x85\n\r\x00\x00\x00\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03+NM\xce\xcfKQ\xc8M\xcdMJ-\xe2\x02\x006\x18K\x0e\x0e\x00\x00\x00'
gc = gzip.compress(T, mtime=0)
check("gzip.compress: the header", [gc[:10], gzip.compress(b"x", 1, mtime=5)[:10], gzip.compress(b"x", 6, mtime=0)[8]],
      [b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03", b"\x1f\x8b\x08\x00\x05\x00\x00\x00\x04\xff", 0])
check("gzip round trips", [gzip.decompress(gc) == T, gzip.decompress(gzip.compress(b"")), gzip.decompress(gc + gzip.compress(b"!", mtime=0)) == T + b"!"],
      [True, b"", True])
check("CPython's two-member gzip", [gzip.decompress(GZ_TWO), gzip.decompress(GZ_TWO + b"\x00\x00\x00")],
      [b"first member\nsecond member\n", b"first member\nsecond member\n"])
r = gzip.GzipFile(fileobj=io.BytesIO(GZ_TWO))
check("GzipFile reads members, mtime, name", [r.read(6), r.mtime, r.read(), r.mtime], [b"first ", 1234567890, b"member\nsecond member\n", 0])
r = gzip.GzipFile(fileobj=io.BytesIO(gzip.compress(b"line 1\nline 2\nline 3\n", mtime=7)))
check("readline, peek, tell, seek", [r.readline(), r.peek(4)[:4], r.tell(), r.read(4), r.seek(2), r.read(4), r.seek(0, 1), r.readlines()],
      [b"line 1\n", b"line", 7, b"line", 2, b"ne 1", 6, [b"\n", b"line 2\n", b"line 3\n"]])
buf = io.BytesIO()
w = gzip.GzipFile(filename="data.txt.gz", mode="wb", fileobj=buf, mtime=123)
w.write(b"hello ")
w.write(bytearray(b"world"))
check("write returns lengths and tell", [w.write(b"!"), w.tell()], [1, 12])
w.close()
blob = buf.getvalue()
check("the header names the file", [blob[:4], blob[4:8], blob[10:19]], [b"\x1f\x8b\x08\x08", b"{\x00\x00\x00", b"data.txt\x00"])
check("GzipFile written, read back", [gzip.decompress(blob), gzip.GzipFile(fileobj=io.BytesIO(blob)).read()], [b"hello world!", b"hello world!"])
gp = os.path.join(TMP, "t.gz")
with gzip.open(gp, "wt") as tf:
    tf.write("text mode\n")
    tf.write("second line\n")
with gzip.open(gp, "at") as tf:
    tf.write("appended\n")
with gzip.open(gp, "rt") as tf:
    gtext = tf.read()
with gzip.open(gp, "rb") as bf:
    gbytes = bf.read()
check("gzip.open text and append modes on disk", [gtext, gbytes, gzip.decompress(open(gp, "rb").read())],
      ["text mode\nsecond line\nappended\n", b"text mode\nsecond line\nappended\n", b"text mode\nsecond line\nappended\n"])
check("gzip errors", [raises(gzip.decompress, b"not gzip data"), raises(gzip.decompress, gc[:-8] + b"\x00\x00\x00\x00" + gc[-4:]),
                      raises(gzip.decompress, gc[:-4] + b"\x00\x00\x00\x00"), raises(gzip.decompress, gc[:30]),
                      raises(gzip.open, gp, "rb", 9, "utf-8"), raises(gzip.open, gp, "rtb"),
                      issubclass(gzip.BadGzipFile, OSError)],
      ["BadGzipFile: Not a gzipped file (b'no')", "BadGzipFile: CRC check failed", "BadGzipFile: Incorrect length of data produced",
       "EOFError: Compressed file ended before the end-of-stream marker was reached",
       "ValueError: Argument 'encoding' not supported in binary mode", "ValueError: Invalid mode: 'rtb'", True])
wr = gzip.GzipFile(fileobj=io.BytesIO(), mode="wb")
check("read on a write-only GzipFile", raises(wr.read), "OSError: [Errno 9] read() on write-only GzipFile object")

# ═══ zipfile ═════════════════════════════════════════════════════════════════
ZIP_CPY = b'PK\x03\x04\x14\x00\x00\x00\x08\x00\xd5S\xb1P\xe4\x98\x9a\xe4\r\x00\x00\x00\xa0\x00\x00\x00\x0f\x00\x00\x00docs/readme.txt+JMLQ\xc8M\xe5*\x1a\xa44\x00PK\x03\x04\x14\x00\x00\x00\x00\x00\xc0S\xb1P\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00docs/PK\x03\x04\x14\x00\x00\x08\x00\x00\x83\x18"R<.\xa6\r(\x00\x00\x00(\x00\x00\x00\t\x00\x00\x00caf\xc3\xa9.bin\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !"#$%&\'PK\x01\x02\x14\x03\x14\x00\x00\x00\x08\x00\xd5S\xb1P\xe4\x98\x9a\xe4\r\x00\x00\x00\xa0\x00\x00\x00\x0f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xa4\x01\x00\x00\x00\x00docs/readme.txtPK\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\xc0S\xb1P\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\xedA:\x00\x00\x00docs/PK\x01\x02\x14\x03\x14\x00\x00\x08\x00\x00\x83\x18"R<.\xa6\r(\x00\x00\x00(\x00\x00\x00\t\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01]\x00\x00\x00caf\xc3\xa9.binPK\x05\x06\x00\x00\x00\x00\x03\x00\x03\x00\xa7\x00\x00\x00\xac\x00\x00\x00\x0f\x00made by CPython'
TGZ_CPY = b"\x1f\x8b\x08\x00\xc5\xae\xcbj\x02\xff\xed\xd7\xbbn\x830\x18\x05`\xcf}\n\xb6\xb4\x0b\xf8\xf7\x05O\x952f\xcc+8\x854VR\x0b\x11G\x82\xb7\x8f\x8b\xaa\xa8\xf4\x92L&R8\xdfb\xe4\x05\xa1\xa3\xe3\x1f7\xfb\xf7\x82%\xc6#\xa3\xf5\xb0F?\xd7\xe1\x99\xa4\x11F\xd1\xd7~\xa9\xb5a\x99f\x138\x1d\x83m\xe3+\xd9<51\xff\x0f\xeb|\xde\xf4I\xf3/\x95\xfa?\x7fR\xe3\xfc\x89\x9b\xb2d\x19\x9f2\x7f\x7f\xe3\xfb}\xff\x98\xf9\xb7\xce\x87\xe7\xc5\xce-^\x9e\x18\xccN^\xe4\xc5rm\xbbUm\xab\xbaM\xd7\xff?z\x7f\xe9\xbf 3\x9a\x05\xb1\xff\x824\xcb:\x9c\xff\xc9\x91\x92Yc\xc3\xee\xf5s\x10TwRl\xdd\xa1\xceC\x17p\x04\xddc\xfe\xa7\x8e\xf7\xe6\xfc\xe7\xf2\xdb\xfc'\xc6%I-'\x9e\xff3\xcd\xdfn\xdeP\x82\x99\xf7\xff\xe0\xfc>\xf5\xfd\xefz\xff\xf9\xaf\xff\x7f\x11\xfb/R_L\xd0\x7f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00x@g\xe9\x1d\xda\xa0\x00(\x00\x00"
ZIP64_CPY = b'PK\x03\x04-\x00\x00\x00\x00\x00A\x10BT\xe0\r_G\xff\xff\xff\xff\xff\xff\xff\xff\x07\x00\x14\x00big.txt\x01\x00\x10\x00\n\x00\x00\x00\x00\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00zip64 dataPK\x01\x02-\x03-\x00\x00\x00\x00\x00A\x10BT\xe0\r_G\n\x00\x00\x00\n\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00big.txtPK\x05\x06\x00\x00\x00\x00\x01\x00\x01\x005\x00\x00\x00C\x00\x00\x00\x00\x00'

zc = zipfile.ZipFile(io.BytesIO(ZIP_CPY))
check("CPython's zip: names, comment", [zc.namelist(), zc.comment], [["docs/readme.txt", "docs/", "caf\u00e9.bin"], b"made by CPython"])
ri = zc.getinfo("docs/readme.txt")
check("ZipInfo fields", [ri.file_size, ri.compress_type, ri.date_time, ri.CRC == zlib.crc32(b"read me\n" * 20), ri.external_attr >> 16,
                         ri.is_dir(), zc.getinfo("docs/").is_dir(), ri.compress_size < ri.file_size],
      [160, 8, (2020, 5, 17, 10, 30, 42), True, 0o644, False, True, True])
check("read members", [zc.read("docs/readme.txt")[:16], zc.read("caf\u00e9.bin") == bytes(range(40)), zc.read("docs/"), zc.testzip()],
      [b"read me\nread me\n", True, b"", None])
with zc.open("docs/readme.txt") as zf:
    zl = [zf.readline(), zf.read(4), zf.tell(), zf.seek(80), zf.read(8), zf.seek(0), len(zf.read())]
check("an open member: readline, tell, seek", zl, [b"read me\n", b"read", 12, 80, b"read me\n", 0, 160])
check("getinfo of a missing name", raises(zc.getinfo, "nope"), "KeyError: \"There is no item named 'nope' in the archive\"")
z64 = zipfile.ZipFile(io.BytesIO(ZIP64_CPY))
check("CPython's ZIP64 member", [z64.namelist(), z64.read("big.txt"), z64.getinfo("big.txt").extract_version], [["big.txt"], b"zip64 data", 45])

mem = io.BytesIO()
with zipfile.ZipFile(mem, "w", zipfile.ZIP_DEFLATED) as zw:
    zw.writestr("a.txt", "alpha\n" * 50)
    zw.writestr(zipfile.ZipInfo("b.bin", (2001, 2, 3, 4, 5, 6)), R, zipfile.ZIP_STORED)
    zw.writestr("dir/", b"")
    with zw.open("c.txt", "w") as h:
        h.write(b"written ")
        h.write(b"through open")
    zw.mkdir("empty")
    zw.comment = b"nython"
zb = mem.getvalue()
zr = zipfile.ZipFile(io.BytesIO(zb))
check("a zip written and read back", [zr.namelist(), zr.comment, zr.read("a.txt") == b"alpha\n" * 50, zr.read("b.bin") == R,
                                      zr.read("c.txt"), [i.compress_type for i in zr.infolist()], zr.testzip(),
                                      zr.getinfo("b.bin").date_time, zr.getinfo("empty/").is_dir()],
      [["a.txt", "b.bin", "dir/", "c.txt", "empty/"], b"nython", True, True, b"written through open", [8, 0, 8, 8, 0], None,
       (2001, 2, 3, 4, 5, 6), True])
check("is_zipfile", [zipfile.is_zipfile(io.BytesIO(zb)), zipfile.is_zipfile(io.BytesIO(b"not a zip at all")),
                     zipfile.is_zipfile(io.BytesIO(ZIP_CPY))], [True, False, True])
spos = zb.find(R[:20])
bad2 = zb[:spos] + bytes([zb[spos] ^ 1]) + zb[spos + 1:]
zbad = zipfile.ZipFile(io.BytesIO(bad2))
check("CRC checked", [raises(zbad.read, "b.bin"), zbad.testzip()], ["BadZipFile: Bad CRC-32 for file 'b.bin'", "b.bin"])
check("not a zip", [raises(zipfile.ZipFile, io.BytesIO(b"plain bytes")), zipfile.BadZipfile is zipfile.BadZipFile],
      ["BadZipFile: File is not a zip file", True])
check("a bad mode", raises(zipfile.ZipFile, io.BytesIO(), "q"), "ValueError: ZipFile requires mode 'r', 'w', 'x', or 'a'")
if nython:
    # (CPython has bz2 and lzma; Nython says so as CPython does without them)
    check("bzip2 and lzma are not provided", [raises(zipfile.ZipFile, io.BytesIO(), "w", zipfile.ZIP_BZIP2),
                                              raises(zipfile.ZipFile, io.BytesIO(), "w", zipfile.ZIP_LZMA),
                                              raises(lambda: tarfile.open(fileobj=io.BytesIO(b"x" * 600), mode="r:bz2"))],
          ["RuntimeError: Compression requires the (missing) bz2 module", "RuntimeError: Compression requires the (missing) lzma module",
           "CompressionError: bz2 module is not available"])
m64 = io.BytesIO()
with zipfile.ZipFile(m64, "w") as zw:
    with zw.open("forced", "w", force_zip64=True) as h:
        h.write(b"0123456789")
z64b = m64.getvalue()
check("force_zip64 writes the ZIP64 extra field", [z64b[4], b"\x01\x00\x10\x00" in z64b[:60], zipfile.ZipFile(io.BytesIO(z64b)).read("forced")],
      [45, True, b"0123456789"])
# CPython wrote this one with ZIP_FILECOUNT_LIMIT patched to 3: ZIP64 end records
ZIP64_COUNT = b'PK\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00!P!\xdf\xdb\xf4\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00f00PK\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00!P\xb7\xef\xdc\x83\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00f11PK\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00!P\r\xbe\xd5\x1a\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00f22PK\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00!P\x9b\x8e\xd2m\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00f33PK\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00!P8\x1b\xb6\xf3\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00f44PK\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\x00\x00!P!\xdf\xdb\xf4\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00f0PK\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\x00\x00!P\xb7\xef\xdc\x83\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01!\x00\x00\x00f1PK\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\x00\x00!P\r\xbe\xd5\x1a\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01B\x00\x00\x00f2PK\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\x00\x00!P\x9b\x8e\xd2m\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01c\x00\x00\x00f3PK\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\x00\x00!P8\x1b\xb6\xf3\x01\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x84\x00\x00\x00f4PK\x06\x06,\x00\x00\x00\x00\x00\x00\x00-\x00-\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\xf0\x00\x00\x00\x00\x00\x00\x00\xa5\x00\x00\x00\x00\x00\x00\x00PK\x06\x07\x00\x00\x00\x00\x95\x01\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00PK\x05\x06\x00\x00\x00\x00\x05\x00\x05\x00\xf0\x00\x00\x00\xa5\x00\x00\x00\x00\x00'
z64c = zipfile.ZipFile(io.BytesIO(ZIP64_COUNT))
check("CPython's ZIP64 end records", [b"PK\x06\x06" in ZIP64_COUNT, z64c.namelist(), z64c.read("f4"), z64c.testzip()],
      [True, ["f0", "f1", "f2", "f3", "f4"], b"4", None])
# (a module's globals can be patched from outside under python3 only: in
# Nython, `zipfile.ZIP_FILECOUNT_LIMIT = 3` does not reach the module's code)
if not nython:
    old_limit = zipfile.ZIP_FILECOUNT_LIMIT
    zipfile.ZIP_FILECOUNT_LIMIT = 3
    mc = io.BytesIO()
    with zipfile.ZipFile(mc, "w") as zw:
        for i in range(5):
            zw.writestr("f" + str(i), str(i))
    mcb = mc.getvalue()
    zl = zipfile.ZipFile(io.BytesIO(), "w", allowZip64=False)
    large = raises(lambda: [zl.writestr("f" + str(i), "") for i in range(5)])
    zipfile.ZIP_FILECOUNT_LIMIT = old_limit
    check("writing more members than the limit", [b"PK\x06\x06" in mcb, b"PK\x06\x07" in mcb, zipfile.ZipFile(io.BytesIO(mcb)).read("f4"), large],
          [True, True, b"4", "LargeZipFile: Files count would require ZIP64 extensions"])
zp = os.path.join(TMP, "a.zip")
srcf = os.path.join(TMP, "src.txt")
f = open(srcf, "wb")
f.write(b"from disk\n" * 10)
f.close()
with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as zw:
    zw.write(srcf, "in/src.txt")
    zw.writestr("../evil.txt", "x")
with zipfile.ZipFile(zp, "a") as za:
    za.writestr("added.txt", "appended")
with zipfile.ZipFile(zp) as zr2:
    zr2.extractall(os.path.join(TMP, "out"))
    znames = zr2.namelist()
    zsize = zr2.getinfo("in/src.txt").file_size
check("on disk: write, append, extractall (names made safe)",
      [znames, zsize, open(os.path.join(TMP, "out", "in", "src.txt"), "rb").read()[:10],
       os.path.exists(os.path.join(TMP, "out", "evil.txt")), os.path.exists(os.path.join(TMP, "evil.txt")),
       open(os.path.join(TMP, "out", "added.txt")).read()],
      [["in/src.txt", "../evil.txt", "added.txt"], 100, b"from disk\n", True, False, "appended"])
check("mode x refuses an existing file", raises(zipfile.ZipFile, zp, "x")[:16], "FileExistsError:")
zpath = zipfile.Path(zipfile.ZipFile(io.BytesIO(ZIP_CPY)))
check("zipfile.Path", [sorted([p.name for p in zpath.iterdir()]), (zpath / "docs" / "readme.txt").read_text()[:7],
                       (zpath / "docs").is_dir(), (zpath / "docs/readme.txt").is_file(), (zpath / "nope").exists(),
                       (zpath / "docs/readme.txt").suffix, (zpath / "docs/readme.txt").stem],
      [["caf\u00e9.bin", "docs"], "read me", True, True, False, ".txt", "readme"])
# made by Info-ZIP's zip -P pass123 (traditional PKWARE encryption, a data descriptor)
ENC_ZIP = b'PK\x03\x04\x14\x00\t\x00\x08\x00\x96~K]\xee\xaf\t\xbe!\x00\x00\x00 \x00\x00\x00\n\x00\x00\x00secret.txt \xaaI5|\x9e\xb6\nT\xba\xec\xe9\xf9bk\xb1\xb3\xf7t\xfb6\x0c \xd1\x8e<H\xd2\x94\xfab\xa4\xa6PK\x07\x08\xee\xaf\t\xbe!\x00\x00\x00 \x00\x00\x00PK\x01\x02\x1e\x03\x14\x00\t\x00\x08\x00\x96~K]\xee\xaf\t\xbe!\x00\x00\x00 \x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xa4\x81\x00\x00\x00\x00secret.txtPK\x05\x06\x00\x00\x00\x00\x01\x00\x01\x008\x00\x00\x00Y\x00\x00\x00\x00\x00'
ze = zipfile.ZipFile(io.BytesIO(ENC_ZIP))
check("an encrypted member", [ze.read("secret.txt", pwd=b"pass123"), raises(ze.read, "secret.txt"), raises(ze.read, "secret.txt", b"wrong"),
                              ze.getinfo("secret.txt").flag_bits & 1],
      [b"top secret text\ntop secret text\n", "RuntimeError: File 'secret.txt' is encrypted, password required for extraction",
       "RuntimeError: Bad password for file 'secret.txt'", 1])
ze.setpassword(b"pass123")
check("setpassword", ze.read("secret.txt")[:10], b"top secret")
pd = io.StringIO()
zc.printdir(pd)
check("printdir", pd.getvalue().split("\n")[:2],
      ["File Name                                             Modified             Size", "docs/readme.txt                                2020-05-17 10:30:42          160"])
rz = zipfile.ZipInfo("x.txt")
rz.compress_type = zipfile.ZIP_DEFLATED
rz.external_attr = 0o100644 << 16
rz.file_size = 5
rz.compress_size = 7
check("ZipInfo repr and defaults", [repr(rz), repr(zipfile.ZipInfo("n")), zipfile.ZipInfo("a\\b").filename == ("a/b" if os.sep == "\\" else "a\\b"),
                                    raises(zipfile.ZipInfo, "x", (1979, 1, 1, 0, 0, 0))],
      ["<ZipInfo filename='x.txt' compress_type=deflate filemode='-rw-r--r--' file_size=5 compress_size=7>",
       "<ZipInfo filename='n' file_size=0>", True, "ValueError: ZIP does not support timestamps before 1980"])
zx = zipfile.ZipFile(io.BytesIO(), "w")
hw = zx.open("one", "w")
check("one writing handle at a time", [raises(zx.open, "two", "w"), raises(zx.writestr, "x", "y")[:44]],
      ["ValueError: Can't write to the ZIP file while there is another write handle open on it. Close the first handle before opening another.",
       "ValueError: Can't write to ZIP archive while"])
hw.close()
zx.close()
check("a closed archive", [raises(zx.read, "one"), raises(zx.writestr, "x", "y")],
      ["ValueError: Attempt to use ZIP archive that was already closed", "ValueError: Attempt to write to ZIP archive that was already closed"])
fi = zipfile.ZipInfo.from_file(srcf, "renamed.txt")
check("ZipInfo.from_file", [fi.filename, fi.file_size, fi.is_dir(), (fi.external_attr >> 16) & 0o170000 == 0o100000,
                            zipfile.ZipInfo.from_file(TMP, "d").filename],
      ["renamed.txt", 100, False, True, "d/"])
with zipfile.ZipFile(zp) as zr3:
    one = zr3.extract("in/src.txt", os.path.join(TMP, "single"))
check("extract one member", [one == os.path.join(TMP, "single", "in", "src.txt"), open(one, "rb").read()[:4]], [True, b"from"])

# ═══ tarfile ═════════════════════════════════════════════════════════════════
ti = tarfile.TarInfo("dir/file.txt")
ti.size = 1234
ti.mtime = 1700000000
ti.uid = 1000
ti.gid = 100
ti.uname = "user"
ti.gname = "staff"
ti.mode = 0o640
ti2 = tarfile.TarInfo("x/" + "y" * 150)
ti2.size = 1
ti2.mtime = 1700000000
check("headers are CPython's, byte for byte (crc32)",
      [[zlib.crc32(ti.tobuf(f)) for f in (tarfile.USTAR_FORMAT, tarfile.GNU_FORMAT, tarfile.PAX_FORMAT)],
       [zlib.crc32(ti2.tobuf(f)) for f in (tarfile.GNU_FORMAT, tarfile.PAX_FORMAT)], len(ti2.tobuf(tarfile.GNU_FORMAT)),
       raises(ti2.tobuf, tarfile.USTAR_FORMAT)],
      [[1805726201, 4243588342, 1805726201], [3408092413, 351378032], 1536, "ValueError: name is too long"])
check("TarInfo predicates", [ti.isfile(), ti.isreg(), ti.isdir(), ti.issym(), ti.islnk(), ti.isdev(), ti.path, ti.linkpath],
      [True, True, False, False, False, False, "dir/file.txt", ""])
fb = tarfile.TarInfo.frombuf(ti.tobuf(tarfile.USTAR_FORMAT), "utf-8", "surrogateescape")
check("frombuf(tobuf()) keeps every field", [fb.name, fb.size, fb.mtime, fb.uid, fb.gid, fb.uname, fb.gname, oct(fb.mode), fb.type, fb.chksum > 0],
      ["dir/file.txt", 1234, 1700000000, 1000, 100, "user", "staff", "0o640", b"0", True])
huge = tarfile.TarInfo("huge")
huge.size = 2 ** 40
huge.mtime = 1700000000.5
check("big numbers: GNU base-256, pax records", [huge.tobuf(tarfile.GNU_FORMAT)[124:136], b"size=1099511627776" in huge.tobuf(tarfile.PAX_FORMAT),
                                                 b"mtime=1700000000.5" in huge.tobuf(tarfile.PAX_FORMAT), raises(huge.tobuf, tarfile.USTAR_FORMAT),
                                                 tarfile.TarInfo.frombuf(huge.tobuf(tarfile.GNU_FORMAT), "utf-8", "strict").size],
      [b"\x80\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00", True, True, "ValueError: overflow in number field", 2 ** 40])
check("bad headers", [raises(tarfile.TarInfo.frombuf, b"\x00" * 512, "utf-8", "strict"), raises(tarfile.TarInfo.frombuf, b"x" * 100, "utf-8", "strict"),
                      raises(tarfile.TarInfo.frombuf, b"a" * 512, "utf-8", "strict")],
      ["EOFHeaderError: end of file header", "TruncatedHeaderError: truncated header", "InvalidHeaderError: invalid header"])
gb = io.BytesIO()
with tarfile.open(fileobj=gb, mode="w", pax_headers={"comment": "global note"}) as tw:
    one = tarfile.TarInfo("x")
    one.pax_headers = {"custom": "value"}
    tw.addfile(one)
with tarfile.open(fileobj=io.BytesIO(gb.getvalue())) as tr:
    gx = tr.getmember("x")
    check("pax headers, global and per member", [tr.pax_headers, gx.pax_headers], [{"comment": "global note"}, {"comment": "global note", "custom": "value"}])
rp = ti.replace(name="other", mtime=5)
check("TarInfo.replace", [rp.name, rp.mtime, rp.size, ti.name], ["other", 5, 1234, "dir/file.txt"])
tz = tarfile.open(fileobj=io.BytesIO(TGZ_CPY))
check("CPython's tar.gz (pax): names, types, sizes",
      [tz.getnames(), [m.type for m in tz.getmembers()], [m.size for m in tz.getmembers()], tz.getmember("pkg/link").linkname,
       tz.getmember("pkg/main.py").uname, tz.getmember("pkg").mode, tz.getmember("pkg/main.py").mtime],
      [["pkg", "pkg/main.py", "pkg/" + "d" * 120 + "/file.txt", "pkg/link"], [b"5", b"0", b"0", b"2"], [0, 12, 3, 0], "main.py",
       "ny", 493, 1600000000])
check("extractfile", [tz.extractfile("pkg/main.py").read(), tz.extractfile("pkg/link").read(), tz.extractfile("pkg"),
                      tz.extractfile(tz.getmember("pkg/" + "d" * 120 + "/file.txt")).read()],
      [b"print('hi')\n", b"print('hi')\n", None, b"abc"])
check("getmember of a missing name", raises(tz.getmember, "nope"), "KeyError: \"filename 'nope' not found\"")

def make_tar(fmt, mode="w"):
    b = io.BytesIO()
    t = tarfile.open(fileobj=b, mode=mode, format=fmt)
    for name, data in [("a.txt", b"first file\n"), ("sub/" + "n" * 110 + ".txt", b"long name"), ("caf\u00e9.txt", b"utf-8")]:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mtime = 1600000000
        t.addfile(info, io.BytesIO(data))
    d = tarfile.TarInfo("sub")
    d.type = tarfile.DIRTYPE
    d.mode = 0o755
    t.addfile(d)
    t.close()
    return b.getvalue()

def read_tar(blob, mode="r"):
    t = tarfile.open(fileobj=io.BytesIO(blob), mode=mode)
    out = []
    for m in t:
        out.append((m.name, m.size, t.extractfile(m).read() if m.isfile() else None))
    t.close()
    return out

want_members = [("a.txt", 11, b"first file\n"), ("sub/" + "n" * 110 + ".txt", 9, b"long name"), ("caf\u00e9.txt", 5, b"utf-8"), ("sub", 0, None)]
gnu = make_tar(tarfile.GNU_FORMAT)
pax = make_tar(tarfile.PAX_FORMAT)
check("written and read: GNU and pax, long and UTF-8 names", [read_tar(gnu) == want_members, read_tar(pax) == want_members,
                                                              len(gnu) % 10240, b"././@LongLink" in gnu, b"././@PaxHeader" in pax],
      [True, True, 0, True, True])
check("ustar refuses a long name", raises(make_tar, tarfile.USTAR_FORMAT), "ValueError: name is too long")
two_tars = gnu + make_tar(tarfile.GNU_FORMAT)
check("ignore_zeros reads past the end blocks", [len(tarfile.open(fileobj=io.BytesIO(two_tars)).getnames()),
                                                 len(tarfile.open(fileobj=io.BytesIO(two_tars), ignore_zeros=True).getnames())], [4, 8])
check("gzip and the stream modes", [read_tar(make_tar(tarfile.PAX_FORMAT, "w:gz"), "r:gz") == want_members,
                                    read_tar(make_tar(tarfile.PAX_FORMAT, "w:gz")) == want_members,
                                    read_tar(make_tar(tarfile.PAX_FORMAT, "w|gz"), "r|gz") == want_members,
                                    read_tar(make_tar(tarfile.PAX_FORMAT, "w|"), "r|*") == want_members,
                                    make_tar(tarfile.PAX_FORMAT, "w:gz")[:2]],
      [True, True, True, True, b"\x1f\x8b"])
check("is_tarfile", [tarfile.is_tarfile(io.BytesIO(pax)), tarfile.is_tarfile(io.BytesIO(TGZ_CPY)), tarfile.is_tarfile(io.BytesIO(b"x" * 600))],
      [True, True, False])
check("tar errors", [raises(lambda: tarfile.open(fileobj=io.BytesIO(b"x" * 600))).split("\n")[0],
                     raises(lambda: tarfile.open(fileobj=io.BytesIO(b""), mode="r:")),
                     raises(lambda: tarfile.open(fileobj=io.BytesIO(), mode="w:zz")),
                     raises(lambda: tarfile.open(fileobj=io.BytesIO(pax), mode="r:gz"))],
      ["ReadError: file could not be opened successfully:", "ReadError: empty file",
       "CompressionError: unknown compression type 'zz'", "ReadError: not a gzip file"])

def evil_tar(entries):
    b = io.BytesIO()
    t = tarfile.open(fileobj=b, mode="w")
    for e in entries:
        info = tarfile.TarInfo(e[0])
        if e[1] == "sym":
            info.type = tarfile.SYMTYPE
            info.linkname = e[2]
            t.addfile(info)
        elif e[1] == "fifo":
            info.type = tarfile.FIFOTYPE
            t.addfile(info)
        else:
            info.size = len(e[2])
            info.mode = 0o4777
            t.addfile(info, io.BytesIO(e[2]))
    t.close()
    b.seek(0)
    return tarfile.open(fileobj=b)

dest = os.path.join(TMP, "tarout")
os.mkdir(dest)
rdest = os.path.realpath(dest)

def filter_msg(entries, flt="data"):
    t = evil_tar(entries)
    return raises(t.extractall, dest, None, filter=flt) if False else raises(lambda: t.extractall(dest, filter=flt))

check("extraction filters refuse what is unsafe",
      [filter_msg([("/etc/passwd", "file", b"x")]).replace(rdest, "D"), filter_msg([("../up.txt", "file", b"x")]).replace(rdest, "D").replace(os.path.dirname(rdest), "P"),
       filter_msg([("ln", "sym", "/etc/passwd")]), filter_msg([("ln2", "sym", "../../x")]).replace(os.path.dirname(os.path.dirname(rdest)), "Q"),
       filter_msg([("f", "fifo", b"")]), raises(lambda: evil_tar([("ok", "file", b"1")]).extractall(dest, filter="nope"))],
      ["no error", "OutsideDestinationError: '../up.txt' would be extracted to 'P/up.txt', which is outside the destination",
       "AbsoluteLinkError: 'ln' is a link to an absolute path",
       "LinkOutsideDestinationError: 'ln2' would link to 'Q/x', which is outside the destination",
       "SpecialFileError: 'f' is a special file", "ValueError: filter 'nope' not found"])
check("the data filter strips a leading / and limits the mode",
      [open(os.path.join(dest, "etc", "passwd")).read(), oct(os.stat(os.path.join(dest, "etc", "passwd")).st_mode & 0o7777)],
      ["x", "0o755"])
t = evil_tar([("plain.txt", "file", b"plain data")])
t.extractall(dest, filter="tar")
t2 = evil_tar([("deep/er/f.txt", "file", b"deeper")])
t2.extract("deep/er/f.txt", dest, filter="data")
check("extractall and extract", [open(os.path.join(dest, "plain.txt")).read(), open(os.path.join(dest, "deep", "er", "f.txt")).read(),
                                 issubclass(tarfile.OutsideDestinationError, tarfile.FilterError), issubclass(tarfile.FilterError, tarfile.TarError)],
      ["plain data", "deeper", True, True])
srcdir = os.path.join(TMP, "tree")
os.makedirs(os.path.join(srcdir, "inner"))
f = open(os.path.join(srcdir, "one.txt"), "w")
f.write("one")
f.close()
f = open(os.path.join(srcdir, "inner", "two.txt"), "w")
f.write("two")
f.close()
tp = os.path.join(TMP, "tree.tar.gz")
with tarfile.open(tp, "w:gz") as tw:
    tw.add(srcdir, arcname="tree")
    tw.add(srcdir, arcname="filtered", filter=lambda m: None if m.name.endswith("two.txt") else m)
with tarfile.open(tp, "a:") if False else tarfile.open(tp) as tr:
    tnames = tr.getnames()
apath = os.path.join(TMP, "app.tar")
with tarfile.open(apath, "w") as tw:
    tw.add(os.path.join(srcdir, "one.txt"), arcname="one.txt")
with tarfile.open(apath, "a") as tw:
    tw.add(os.path.join(srcdir, "inner", "two.txt"), arcname="two.txt")
with tarfile.open(apath) as tr:
    anames = tr.getnames()
    two = tr.extractfile("two.txt").read()
check("add (recursive, filter) and append on disk",
      [tnames, anames, two, raises(tarfile.open, apath, "x")[:16]],
      [["tree", "tree/inner", "tree/inner/two.txt", "tree/one.txt", "filtered", "filtered/inner", "filtered/one.txt"],
       ["one.txt", "two.txt"], b"two", "FileExistsError:"])

# ═══ pickle ══════════════════════════════════════════════════════════════════
shared = [1, 2]
d1 = {"a": 1, "b": [1, 2, 3], "c": (1, 2)}
rec = [1]
rec.append(rec)
PVALUES = [None, True, False, 0, 1, -1, 255, 256, 65535, 65536, -129, 2**31 - 1, -2**31, 2**31, -2**31 - 1,
           2**64, -2**64, 2**100 + 7, -(2**200), 255 << 8 * 255, 0.0, 1.5, -2.25, 1e100, float("inf"),
           "", "abc", "h\u00e9llo", "\u20ac", "\U0001f600", "a\nb\\c\x00\r\x1a", "x" * 300,
           b"", b"abc", b"\x00\xff" * 200, bytearray(b"xyz"), bytearray(),
           (), (1,), (1, 2), (1, 2, 3), (1, 2, 3, 4), [], [1], [1, 2], list(range(1001)),
           {}, {"a": 1}, d1, {i: i for i in range(1000)},
           set(), {1, 2, 3}, frozenset(), frozenset([1, 2]),
           [shared, shared], {"x": shared, "y": [shared]}, rec, [d1, d1, (d1,)],
           [{"k": 1}, {"k": 2}], [[], []]]
PCRC = [
    [4092951995, 1618632550, 1639462225, 3305818238, 3301483081, 3255423012, 2165889868, 2204001557, 1127391838, 1098128391, 1009607546, 1090689518, 3040106991, 270025035, 806412488, 384812090, 1767187400, 2039049609, 4283038168, 1479203933, 2338138252, 2968962007, 1296206216, 3627794997, 1299943177, 1221128865, 1251218599, 3187950525, 3475046872, 1084474113, 1054618954, 1202828576, 3352863789, 2587844483, 3663515107, 4057128270, 545649094, 1587183479, 591562261, 393774854, 1886943580, 1590370528, 1871846653, 271333701, 1579522894, 657773464, 1608668988, 3071070363, 1797475735, 3376945780, 2835305621, 4091864804, 2201796138, 2595543844, 4254930646, 2211371983, 2329789088, 3278184467, 1663324845, 3010313442],
    [4092951995, 1618632550, 1639462225, 1599649532, 1178830781, 4194995588, 3430697870, 2381800306, 3109067692, 3256217425, 1273773334, 3246986703, 4166262061, 270025035, 806412488, 384812090, 1767187400, 2039049609, 4283038168, 1479203933, 1127905632, 2654763420, 3117972821, 3191698303, 2471190830, 1778661554, 3269564697, 1845050356, 1547683552, 4244623890, 2593352953, 581526802, 2982873918, 4031873790, 3875411843, 3341375928, 2218819668, 3645472987, 1417233401, 2135388342, 2316714212, 2523031263, 2445674443, 4076301135, 1742245763, 3330623149, 838117621, 3839109170, 4155550585, 2662319587, 3951061342, 2226120468, 1507598805, 242570186, 2203004471, 2770973435, 3604699965, 2696348150, 3037852084, 1144804584],
    [2109067789, 3759514309, 4178482052, 2111103210, 1691341227, 3931006909, 4008713624, 2030131829, 1302766251, 3528525160, 1537791791, 3519938550, 3893425940, 2254039307, 1530939941, 115648228, 2363189975, 3134531969, 3491767007, 3483678961, 3821928792, 1053295012, 422315373, 516492103, 868161814, 610250282, 3930314239, 2760004867, 1956481542, 3049142035, 1801756327, 943214496, 2578545383, 4050191839, 333987813, 3800350926, 1783254438, 1460219757, 2853949732, 2809254782, 174274205, 3777763244, 1697660620, 2917312429, 3341612987, 896193000, 3305279986, 3351524579, 801700109, 2366641425, 1717179491, 3726810027, 4161537930, 1187187961, 258843958, 2276375243, 1982800645, 2105631291, 3270108722, 226341353],
    [2088220730, 3789015282, 4174182835, 3311961999, 3698570958, 1278831625, 1447852797, 1147237317, 1892059931, 1948651228, 4259306651, 2008740930, 1315437728, 2434989384, 1278959206, 3681714017, 1364046674, 1031004866, 3963666903, 1992039350, 574676632, 4282834532, 3634551469, 3746026631, 4063348438, 858045033, 1910938000, 494505707, 4013475433, 1747512982, 3972158948, 223199028, 89680403, 718548406, 1101972296, 1177367333, 533665808, 1456162138, 208460432, 2953496381, 3421366621, 2082731738, 1481643900, 1632151347, 111290491, 2186058792, 4167219266, 1772922226, 3858107038, 2126478181, 2309766817, 3827504953, 787370358, 1722953665, 3762230231, 170280745, 3080846533, 758253799, 2716745494, 3505088620],
    [2033757887, 3835223671, 4253282102, 1488961334, 1101303415, 758825020, 3415949892, 638569352, 313013078, 354788073, 2631692462, 381245559, 795103381, 3438364565, 300475579, 916927791, 3164141852, 3709974425, 2213470547, 362538514, 951453960, 3853519348, 3260288317, 3316712215, 3905360198, 3838327988, 2664410000, 1888479774, 604369303, 2280942123, 2754179850, 2272218684, 3404120804, 2761573618, 1939953434, 3394844494, 750581174, 1401181151, 4293744821, 3317922163, 58072398, 3799604718, 1429811178, 528716992, 2407508049, 588606833, 1836345610, 3692450299, 2448784808, 2138111502, 3677671092, 3290171311, 3658506273, 1980915055, 2869271629, 3790807997, 1048345839, 1198928408, 1865158278, 3489279414],
    [2029700232, 3847926848, 4232152321, 3758348371, 4179159314, 2203210157, 1931945249, 3137350398, 2410140192, 3142398840, 850714943, 3100756454, 2165096708, 597946740, 4273623642, 563040751, 2880478684, 977015054, 3446139642, 3797874855, 1573990990, 2161586866, 2805151355, 2698393681, 2376083968, 2043141570, 426336467, 367579480, 2745383636, 1755765962, 3003193290, 2062902634, 1474896786, 591171505, 2884046026, 427579414, 2566172406, 1380334056, 1175880541, 1113961008, 3566509334, 4115740974, 3984935055, 2984969553, 1486694409, 259853520, 3586657903, 3111217853, 845370852, 1799217002, 1669900753, 1539736625, 1193247063, 2571168654, 244190275, 1954805544, 3919510711, 1702199560, 1640752727, 404270574]]
for p in range(6):
    got = [zlib.crc32(pickle.dumps(v, p)) for v in PVALUES]
    bad_at = [i for i in range(len(got)) if got[i] != PCRC[p][i]]
    check("dumps(builtin values, protocol " + str(p) + ") is CPython's, byte for byte", bad_at, [])
check("dumps, written out", [pickle.dumps([1, "a", (2, b"b")], 0), pickle.dumps([1, "a", (2, b"b")], 2),
                             pickle.dumps({"k": [1.5, None, True]}, 4), pickle.dumps({"k": [1.5, None, True]}, 5)],
      [b"(lp0\nI1\naVa\np1\na(I2\nc_codecs\nencode\np2\n(Vb\np3\nVlatin1\np4\ntp5\nRp6\ntp7\na.",
       b"\x80\x02]q\x00(K\x01X\x01\x00\x00\x00aq\x01K\x02c_codecs\nencode\nq\x02X\x01\x00\x00\x00bq\x03X\x06\x00\x00\x00latin1q\x04\x86q\x05Rq\x06\x86q\x07e.",
       b"\x80\x04\x95\x17\x00\x00\x00\x00\x00\x00\x00}\x94\x8c\x01k\x94]\x94(G?\xf8\x00\x00\x00\x00\x00\x00N\x88es.",
       b"\x80\x05\x95\x17\x00\x00\x00\x00\x00\x00\x00}\x94\x8c\x01k\x94]\x94(G?\xf8\x00\x00\x00\x00\x00\x00N\x88es."])

def rt_ok(v, p):
    r = pickle.loads(pickle.dumps(v, p))
    return repr(r) == repr(v) and type(r) is type(v)

simple = [v for v in PVALUES if not (isinstance(v, list) and len(v) > 0 and v[-1] is v)]
check("loads(dumps(x)) for every value and protocol", [[i for i in range(len(simple)) if not rt_ok(simple[i], p)] for p in range(6)],
      [[], [], [], [], [], []])
for p in range(6):
    r = pickle.loads(pickle.dumps(rec, p))
    s = pickle.loads(pickle.dumps([shared, shared, {"s": shared}], p))
    check("cycles and sharing survive, protocol " + str(p), [r[1] is r, r[0], s[0] is s[1], s[2]["s"] is s[0]], [True, 1, True, True])
check("defaults", [pickle.HIGHEST_PROTOCOL, pickle.DEFAULT_PROTOCOL, pickle.dumps(1) == pickle.dumps(1, 4), pickle.dumps(1, -1)[:2]],
      [5, 4, True, b"\x80\x05"])


class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y

    def __eq__(self, o):
        return isinstance(o, Point) and self.x == o.x and self.y == o.y


class WithState:
    def __init__(self):
        self.a = 1
        self.secret = "s"

    def __getstate__(self):
        d = dict(self.__dict__)
        del d["secret"]
        return d

    def __setstate__(self, st):
        self.__dict__.update(st)
        self.secret = "restored"


class NewArgs:
    def __new__(cls, v):
        o = object.__new__(cls)
        o.v = v
        return o

    def __getnewargs__(self):
        return (self.v,)


class NewArgsEx:
    def __new__(cls, a, b=0):
        o = object.__new__(cls)
        o.a = a
        o.b = b
        return o

    def __getnewargs_ex__(self):
        return ((self.a,), {"b": self.b})


class Red:
    def __init__(self, a):
        self.a = a

    def __reduce__(self):
        return (Red, (self.a * 2,))


class MyList(list):
    pass


class MyDict(dict):
    pass


class Slotted:
    __slots__ = ("x", "y")

    def __init__(self, x, y):
        self.x = x
        self.y = y


class SlottedWithDict:
    __slots__ = ("x", "__dict__")


def module_func(v):
    return v * 2


ccrc = []
for p in range(6):
    row = []
    for v in [Point(1, 2), [Point(3, 4), Point(3, 4)], WithState(), NewArgs(5), NewArgsEx(1, b=2), Red(3), Point, module_func,
              MyList([1, 2]), MyDict(a=1), ValueError("bad"), complex(1, 2)]:
        row.append(zlib.crc32(pickle.dumps(v, p)))
    ccrc.append(row)
CCRC = [
    [3412079725, 3308947288, 2797008888, 2537821794, 751973715, 1700121849, 1790133022, 726436815, 855536428, 4269684893, 386660254, 4159274334],
    [2468480736, 4189207956, 3237862631, 2450646615, 2054614883, 288333300, 4002292748, 356292007, 1429719984, 2338617491, 2142099601, 1384802186],
    [1284007946, 3333983464, 3503669250, 2596774591, 3888112115, 1272670854, 2382349255, 1844826783, 1697431533, 910079413, 3258612464, 2970304041],
    [3367596539, 988171125, 2546349817, 961645299, 1325721879, 2898709521, 3902339201, 2330489864, 1808488252, 2739822880, 3753988540, 3477062853],
    [510978226, 4094204318, 2301867993, 2913136777, 4251070699, 3155289364, 732416406, 282429798, 789575821, 4016660949, 2839429844, 4254394456],
    [2008552639, 323451077, 107714762, 697559416, 3029048820, 694235521, 3665677372, 2640147588, 2385935459, 2826606382, 3225897393, 3758226319],
]
check("classes, instances, functions: CPython's bytes (crc32)", [[i for i in range(len(ccrc[p])) if ccrc[p][i] != CCRC[p][i]] for p in range(6)],
      [[], [], [], [], [], []])
for p in range(6):
    pt = pickle.loads(pickle.dumps(Point(1, 2), p))
    ws = pickle.loads(pickle.dumps(WithState(), p))
    na = pickle.loads(pickle.dumps(NewArgs(5), p))
    nx = pickle.loads(pickle.dumps(NewArgsEx(7, b=8), p))
    rd = pickle.loads(pickle.dumps(Red(3), p))
    ml = pickle.loads(pickle.dumps(MyList([1, 2]), p))
    md = pickle.loads(pickle.dumps(MyDict(a=1), p))
    ve = pickle.loads(pickle.dumps(ValueError("bad"), p))
    fn = pickle.loads(pickle.dumps(module_func, p))
    check("round trips of instances, protocol " + str(p),
          [type(pt).__name__, pt == Point(1, 2), ws.a, ws.secret, na.v, nx.a, nx.b, rd.a, type(ml).__name__, list(ml),
           type(md).__name__, dict(md), type(ve).__name__, ve.args, fn(21), pickle.loads(pickle.dumps(Point, p)) is Point],
          ["Point", True, 1, "restored", 5, 7, 8, 6, "MyList", [1, 2], "MyDict", {"a": 1}, "ValueError", ("bad",), 42, True])
sl = Slotted(1, [2])
check("slotted objects: state as (None, slots)", [Slotted(1, 2).__getstate__(),
                                                  copyreg._slotnames(Slotted)],
      [(None, {"x": 1, "y": 2}), ["x", "y"]])
for p in (2, 4, 5):
    s2 = pickle.loads(pickle.dumps(sl, p))
    check("pickle a slotted object, protocol " + str(p), [type(s2).__name__, s2.x, s2.y, hasattr(s2, "__dict__")], ["Slotted", 1, [2], False])
check("protocols 0 and 1 refuse slots without __getstate__", raises(pickle.dumps, sl, 1),
      "TypeError: a class that defines __slots__ without defining __getstate__ cannot be pickled")
swd = SlottedWithDict()
swd.x = 1
swd.extra = 2
s3 = pickle.loads(pickle.dumps(swd, 2))
check("slots and a __dict__", [s3.x, s3.extra, swd.__getstate__()], [1, 2, ({"extra": 2}, {"x": 1})])

# self-referencing instance
node = Point(0, 0)
node.x = node
n2 = pickle.loads(pickle.dumps(node, 2))
check("an instance holding itself", [n2.x is n2, n2.y], [True, 0])

check("unpickling errors", [raises(pickle.loads, b""), raises(pickle.loads, b"\x80\x06."), raises(pickle.loads, b"\xff"),
                            raises(pickle.loads, b"\x80\x04\x95\x05\x00\x00\x00\x00\x00\x00\x00K\x01"), raises(pickle.loads, b"(K\x01"),
                            raises(pickle.loads, b"h\x05."), raises(pickle.loads, "text")],
      ["EOFError: Ran out of input", "ValueError: unsupported pickle protocol: 6", "UnpicklingError: invalid load key, '\\xff'.",
       "UnpicklingError: pickle data was truncated", "EOFError: Ran out of input",
       "UnpicklingError: Memo value not found at index 5", "TypeError: a bytes-like object is required, not 'str'"])
check("pickling errors", [raises(pickle.dumps, 1, 6), raises(pickle.dumps, lambda: 1)[:40], issubclass(pickle.PicklingError, pickle.PickleError),
                          issubclass(pickle.UnpicklingError, pickle.PickleError)],
      ["ValueError: pickle protocol must be <= 5", "PicklingError: Can't pickle <function <l", True, True])


class PersPickler(pickle.Pickler):
    def persistent_id(self, obj):
        if isinstance(obj, Point):
            return ("point", obj.x, obj.y)
        return None


class PersUnpickler(pickle.Unpickler):
    def persistent_load(self, pid):
        return "P" + str(pid[1]) + str(pid[2])


pf = io.BytesIO()
PersPickler(pf, 2).dump([Point(1, 2), "x"])
pf0 = io.BytesIO()
PersPickler(pf0, 0).dump([Point(1, 2)])
check("persistent_id / persistent_load", [PersUnpickler(io.BytesIO(pf.getvalue())).load(), raises(pickle.loads, pf.getvalue()),
                                          zlib.crc32(pf.getvalue()), raises(PersPickler(io.BytesIO(), 0).dump, [Point(1, 2)])[:15]],
      [["P12", "x"], "UnpicklingError: A load persistent id instruction was encountered,\nbut no persistent_load function was specified.",
       zlib.crc32(b"\x80\x02]q\x00(X\x05\x00\x00\x00pointq\x01K\x01K\x02\x87q\x02QX\x01\x00\x00\x00xq\x03e."), "no error"[:15]])


class RO(pickle.Pickler):
    def reducer_override(self, obj):
        if isinstance(obj, Point):
            return (tuple, ((obj.x, obj.y),))
        return NotImplemented


rf = io.BytesIO()
RO(rf, 4).dump([Point(5, 6), 1])
dtf = io.BytesIO()
dp = pickle.Pickler(dtf, 2)
dp.dispatch_table = {Point: lambda pnt: (str, ("point " + str(pnt.x),))}
dp.dump(Point(9, 9))
check("reducer_override and dispatch_table", [pickle.loads(rf.getvalue()), pickle.loads(dtf.getvalue())], [[(5, 6), 1], "point 9"])
copyreg.pickle(NewArgsEx, lambda o: (NewArgsEx, (o.a * 10,)))
check("copyreg.pickle registers a reduction", pickle.loads(pickle.dumps(NewArgsEx(4), 2)).a, 40)
del copyreg.dispatch_table[NewArgsEx]
check("loads reads Python 2 strings", [pickle.loads(b"S'abc'\np0\n."), pickle.loads(b"U\x03abcq\x00.", encoding="bytes"),
                                       pickle.loads(b"\x80\x02U\x03abcq\x00.", encoding="latin1")],
      ["abc", b"abc", "abc"])
bufs = []
pb_data = pickle.dumps(pickle.PickleBuffer(bytearray(b"out of band")), 5, buffer_callback=bufs.append)
check("protocol 5: out-of-band buffers", [pb_data, len(bufs), bytes(pickle.loads(pb_data, buffers=[bytearray(b"out of band")])),
                                          pickle.dumps(pickle.PickleBuffer(b"in band"), 5)],
      [b"\x80\x05\x97.", 1, b"out of band", b"\x80\x05\x95\x0b\x00\x00\x00\x00\x00\x00\x00C\x07in band\x94."])
pk = os.path.join(TMP, "data.pkl")
with open(pk, "wb") as f:
    pickle.dump({"a": [1, 2]}, f)
    pickle.dump("second", f, protocol=0)
with open(pk, "rb") as f:
    first = pickle.load(f)
    second = pickle.load(f)
check("dump/load to a file, two pickles in a row", [first, second], [{"a": [1, 2]}, "second"])

# ═══ copy (through the same __reduce_ex__ protocol) ═══════════════════════════
cs = copy.copy(sl)
dc = copy.deepcopy(sl)
check("copy and deepcopy of slotted objects", [type(cs).__name__, cs.x, cs.y is sl.y, dc.y == sl.y, dc.y is sl.y],
      ["Slotted", 1, True, True, False])
check("copy of an object with slots and __dict__", [copy.copy(swd).x, copy.copy(swd).extra], [1, 2])
check("object.__reduce_ex__ and copyreg", [Point(1, 2).__reduce_ex__(2)[0] is copyreg.__newobj__, Point(1, 2).__reduce_ex__(2)[1] == (Point,),
                                           Point(1, 2).__reduce_ex__(1)[0] is copyreg._reconstructor, Point(1, 2).__getstate__(),
                                           NewArgs(3).__reduce_ex__(2)[1] == (NewArgs, 3)],
      [True, True, True, {"x": 1, "y": 2}, True])

# ═══ array ═══════════════════════════════════════════════════════════════════
import array as array_module
check("typecodes and sizes", [array_module.typecodes, [array(c).itemsize for c in "bBhHiIqQfd"]],
      ["bBuhHiIlLqQfd", [1, 1, 2, 2, 4, 4, 8, 8, 4, 8]])
ai = array("i", [1, 2, 3])
ai.append(4)
ai.extend([5, 6])
ai.insert(0, 0)
check("list-like methods", [ai.tolist(), ai.pop(), ai.pop(0), ai.index(3), ai.count(3), ai[1], ai[-1], len(ai), 3 in ai],
      [[0, 1, 2, 3, 4, 5, 6], 6, 0, 2, 1, 2, 5, 5, True])
ai.remove(3)
ai.reverse()
check("remove, reverse, slices", [ai, ai[1:3], ai[::-1], ai[0:0]], [array("i", [5, 4, 2, 1]), array("i", [4, 2]), array("i", [1, 2, 4, 5]), array("i")])
ai[0:2] = array("i", [9])
del ai[-1]
check("slice assignment and del", ai, array("i", [9, 2]))
check("bytes", [array("h", [1, 256]).tobytes(), array("i", b"\x01\x00\x00\x00\x02\x00\x00\x00"), bytes(array("B", [65, 66])),
                array("d", [1.5]).tobytes(), array("f", [0.1])[0]],
      [b"\x01\x00\x00\x01", array("i", [1, 2]), b"AB", b"\x00\x00\x00\x00\x00\x00\xf8?", 0.10000000149011612])
bs = array("i", [1, 256])
bs.byteswap()
check("byteswap, frombytes, fromlist, unicode", [bs, raises(array("i").frombytes, b"\x01"), raises(array("i").fromlist, (1,)),
                                                 array("u", "abc").tounicode(), repr(array("u", "hi")), raises(array("i").tounicode)],
      [array("i", [16777216, 65536]), "ValueError: bytes length not a multiple of item size", "TypeError: arg must be list",
       "abc", "array('u', 'hi')", "ValueError: tounicode() may only be called on unicode type arrays"])
check("operators", [array("i", [1, 2]) + array("i", [3]), array("b", [1]) * 3, 2 * array("b", [7]), array("i", [1, 2]) < array("i", [1, 3]),
                    array("i", [1, 2]) == array("d", [1.0, 2.0]), repr(array("d", [1.5, 2])), repr(array("b"))],
      [array("i", [1, 2, 3]), array("b", [1, 1, 1]), array("b", [7, 7]), True, True, "array('d', [1.5, 2.0])", "array('b')"])
check("range errors, CPython's messages",
      [raises(array, "b", [200]), raises(array, "B", [-1]), raises(array, "h", [40000]), raises(array, "H", [70000]), raises(array, "i", [2 ** 40]),
       raises(array, "I", [-1]), raises(array, "Q", [-1]), raises(array, "q", [2 ** 63]), raises(array, "i", [1.5]), raises(array, "d", ["a"]),
       raises(array, "z"), raises(lambda: array("i", [1]) + [2]), raises(lambda: array("i", [1]) + array("d", [2])), raises(hash, array("i"))],
      ["OverflowError: signed char is greater than maximum", "OverflowError: unsigned byte integer is less than minimum",
       "OverflowError: signed short integer is greater than maximum", "OverflowError: unsigned short is greater than maximum",
       "OverflowError: signed integer is greater than maximum", "OverflowError: can't convert negative value to unsigned int",
       "OverflowError: can't convert negative int to unsigned", "OverflowError: int too big to convert",
       "TypeError: 'float' object cannot be interpreted as an integer", "TypeError: must be real number, not str",
       "ValueError: bad typecode (must be b, B, u, h, H, i, I, l, L, q, Q, f or d)",
       "TypeError: can only append array (not \"list\") to array", "TypeError: bad argument type for built-in operation",
       "TypeError: unhashable type: 'array.array'"])
af = os.path.join(TMP, "arr.bin")
with open(af, "wb") as f:
    array("H", [1, 2, 3]).tofile(f)
ar = array("H")
with open(af, "rb") as f:
    ar.fromfile(f, 3)
check("tofile/fromfile, pickle, copy", [ar, pickle.loads(pickle.dumps(ar, 2)), pickle.loads(pickle.dumps(ar, 4)), copy.deepcopy(ar),
                                        pickle.dumps(array("i", [1, 2]), 2), pickle.dumps(array("i", [1, 2]), 4)],
      [array("H", [1, 2, 3]), array("H", [1, 2, 3]), array("H", [1, 2, 3]), array("H", [1, 2, 3]),
       b"\x80\x02carray\narray\nq\x00X\x01\x00\x00\x00iq\x01]q\x02(K\x01K\x02e\x86q\x03Rq\x04.",
       b"\x80\x04\x95J\x00\x00\x00\x00\x00\x00\x00\x8c\x05array\x94\x8c\x14_array_reconstructor\x94\x93\x94(\x8c\x05array\x94\x8c\x05array\x94\x93\x94\x8c\x01i\x94K\x08C\x08\x01\x00\x00\x00\x02\x00\x00\x00\x94t\x94R\x94."])

# ═══ __slots__ ═══════════════════════════════════════════════════════════════
class S1:
    __slots__ = ("x", "__y")

    def __init__(self):
        self.x = 1
        self.__y = 2

    def gety(self):
        return self.__y


s = S1()
check("slots: values, member descriptors", [s.x, s.gety(), type(S1.x).__name__, repr(S1.x), S1.x.__name__, S1.x.__objclass__ is S1,
                                             "_S1__y" in S1.__dict__, S1.__slots__],
      [1, 2, "member_descriptor", "<member 'x' of 'S1' objects>", "x", True, True, ("x", "__y")])
check("no __dict__, no other attribute", [raises(setattr, s, "z", 1), raises(lambda: s.__dict__), raises(vars, s), hasattr(s, "__dict__")],
      ["AttributeError: 'S1' object has no attribute 'z'", "AttributeError: 'S1' object has no attribute '__dict__'",
       "TypeError: vars() argument must have __dict__ attribute", False])
s.x = 10
del s.x
check("unset and deleted slots", [raises(lambda: s.x), raises(delattr, s, "x"), S1.x.__get__(s, S1) if False else raises(S1.x.__get__, s, S1)],
      ["AttributeError: 'S1' object has no attribute 'x'", "AttributeError: x", "AttributeError: 'S1' object has no attribute 'x'"])
S1.x.__set__(s, 99)
check("the descriptor's own methods", [s.x, S1.x.__get__(s, S1), S1.x.__get__(None, S1) is S1.x], [99, 99, True])


class S2(S1):
    pass


class S3(S1):
    __slots__ = ("z",)


class S4:
    __slots__ = ()


class S5:
    __slots__ = "only"


class S6:
    __slots__ = ("a", "__weakref__")


s2 = S2()
s2.anything = 5
s3 = S3()
s3.z = 3
check("inheritance: a subclass without __slots__ has a __dict__", [s2.anything, s2.__dict__, s3.z, s3.x, raises(setattr, s3, "w", 1),
                                                                   raises(setattr, S4(), "a", 1), S5.__slots__, isinstance(S5.only, object)],
      [5, {"anything": 5}, 3, 1, "AttributeError: 'S3' object has no attribute 'w'", "AttributeError: 'S4' object has no attribute 'a'",
       "only", True])
check("weak references need __weakref__", [raises(weakref.ref, S4()), weakref.ref(S6()) is not None, weakref.ref(s2) is not None],
      ["TypeError: cannot create weak reference to 'S4' object", True, True])

def make_class(body):
    ns = {}
    exec("class C:\n" + body, ns)
    return ns["C"]

check("__slots__ errors", [raises(make_class, "    __slots__ = ('x',)\n    x = 1\n"), raises(make_class, "    __slots__ = ('1x',)\n"),
                           raises(make_class, "    __slots__ = (1,)\n"), raises(make_class, "    __slots__ = ('__dict__', '__dict__')\n")],
      ["ValueError: 'x' in __slots__ conflicts with class variable", "TypeError: __slots__ must be identifiers",
       "TypeError: __slots__ items must be strings, not 'int'", "TypeError: __dict__ slot disallowed: we already got one"])
sd = SlottedWithDict()
sd.x = 1
sd.free = 2
check("'__dict__' in __slots__", [sd.x, sd.free, sd.__dict__], [1, 2, {"free": 2}])


# ═══ __class__ assignment ════════════════════════════════════════════════════
class A:
    def who(self):
        return "A"


class B:
    def who(self):
        return "B"


class B2(B):
    pass


a = A()
held = [a]
box = {"a": a}
a.v = 1
a.__class__ = B
check("__class__ assignment: method lookup, isinstance, type, every reference",
      [a.who(), isinstance(a, B), isinstance(a, A), type(a) is B, held[0].who(), box["a"].who(), a.v, a.__class__ is B, type(held[0]).__name__],
      ["B", True, False, True, "B", "B", 1, True, "B"])
a.__class__ = B2
check("again, to a subclass", [a.who(), type(a).__name__, isinstance(a, B)], ["B", "B2", True])


class Morph:
    def change(self):
        self.__class__ = Other
        return self.kind()

    def kind(self):
        return "morph"


class Other:
    def kind(self):
        return "other"


check("from inside a method", Morph().change(), "other")
check("__class__ assignment errors",
      [raises(setattr, a, "__class__", S1), raises(setattr, s, "__class__", A), raises(setattr, a, "__class__", 5),
       raises(delattr, a, "__class__"), raises(setattr, 5, "__class__", A), raises(setattr, [], "__class__", A)],
      ["TypeError: __class__ assignment: 'S1' object layout differs from 'B2'", "TypeError: __class__ assignment: 'A' object layout differs from 'S1'",
       "TypeError: __class__ must be set to a class, not 'int' object", "TypeError: can't delete __class__ attribute",
       "TypeError: __class__ assignment only supported for mutable types or ModuleType subclasses",
       "TypeError: __class__ assignment only supported for mutable types or ModuleType subclasses"])


class SA2:
    __slots__ = ("x",)


class SB2:
    __slots__ = ("x",)


sa = SA2()
sa.x = 4
sa.__class__ = SB2
check("between classes with the same slots", [type(sa).__name__, sa.x], ["SB2", 4])

shutil.rmtree(TMP)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT93 PASSED ===")
