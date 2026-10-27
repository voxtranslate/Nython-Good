#!/usr/bin/env python3
"""Generates src/builtins/nycjk_tables.inc - the mapping tables of the CJK
codecs (src/builtins/nycjk.cpp, round 84) - from the running Python's own
codecs, so that big5, gbk, shift_jis, iso2022_jp ... are byte-identical to
CPython 3.11's.

nycjk.cpp is CPython's Modules/cjkcodecs (_codecs_cn/hk/iso2022/jp/kr/tw.c)
ported to C++: the same decoders and encoders over the same internal
tables (gb2312, gbkext, gbcommon, gb18030ext, ksx1001, cp949, cp949ext,
big5, cp950ext, big5hkscs, jisx0208, jisx0212, jisxcommon, jisx0213_*,
cp932ext). Those tables are not visible from Python, so each one is read
back from the codec that consults it first, without the special cases in
front of it, and the "extension" tables are what a codec decodes or encodes
beyond the tables it consults before them (see derive_* below; the
reasoning for each is beside it). tools/check_cjk_codecs.py then compares
every codec with python3's over every one- to four-byte input and every code
point.

Compression: the encoding maps are not stored where they are the inverse of
a decoding map - nycjk.cpp builds them on first use by inverting the
decoding maps (in a fixed order) and applying the stored differences, and
the whole table blob is DEFLATE-compressed (inflated once by the native
zlib, src/builtins/nyzlib.cpp). `--stats` prints the sizes.

    python3 tools/gen_cjk_codecs.py            # writes src/builtins/nycjk_tables.inc
    python3 tools/gen_cjk_codecs.py --stats
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def log(*a):
    print(*a, file=sys.stderr)


def dec(codec, b):
    """the str bytes b decode to under codec, None on any error"""
    try:
        return b.decode(codec)
    except UnicodeDecodeError:
        return None


def enc(codec, u):
    try:
        return u.encode(codec)
    except UnicodeEncodeError:
        return None


R94 = range(0x21, 0x7F)


def one(s):
    return s is not None and len(s) == 1


# ── CN ──────────────────────────────────────────────────────────────────────
def derive_cn():
    t = {}
    # gb2312: the gb2312 decoder consults nothing else
    gb2312 = {}
    for c1 in R94:
        for c2 in R94:
            s = dec("gb2312", bytes([c1 | 0x80, c2 | 0x80]))
            if one(s):
                gb2312[(c1, c2)] = ord(s)
    t["gb2312"] = gb2312
    # gbkext: what gbk decodes past its three special cases and gb2312
    specials = {(0xA1, 0xAA), (0xA8, 0x44), (0xA1, 0xA4)}
    gbkext = {}
    for c1 in range(0x81, 0xFF):
        for c2 in range(0x40, 0xFF):
            if (c1, c2) in specials:
                continue
            if c1 >= 0xA1 and c2 >= 0xA1 and (c1 ^ 0x80, c2 ^ 0x80) in gb2312:
                continue
            s = dec("gbk", bytes([c1, c2]))
            if one(s):
                gbkext[(c1, c2)] = ord(s)
    t["gbkext"] = gbkext
    # gb18030ext (decoding): what gb18030 decodes past GBK's decoding
    gb18030ext_d = {}
    for c1 in range(0x81, 0xFF):
        for c2 in range(0x40, 0xFF):
            if dec("gbk", bytes([c1, c2])) is not None:
                continue
            s = dec("gb18030", bytes([c1, c2]))
            if one(s):
                gb18030ext_d[(c1, c2)] = ord(s)
    t["gb18030ext_d"] = gb18030ext_d
    # gbcommon (encoding): gb2312's entries (MSB clear) where gb2312 encodes,
    # else GBK's (MSB set) past GBK_ENCODE's special cases
    gbcommon = {}
    gb18030ext_e = {}
    for u in range(0x80, 0x10000):
        if 0xD800 <= u < 0xE000:
            continue
        ch = chr(u)
        b = enc("gb2312", ch)
        if b is not None:
            assert len(b) == 2
            gbcommon[u] = ((b[0] ^ 0x80) << 8) | (b[1] ^ 0x80)
        elif u not in (0x2014, 0x2015, 0x00B7, 0x30FB):
            b = enc("gbk", ch)
            if b is not None:
                assert len(b) == 2 and b[0] >= 0x81
                gbcommon[u] = (b[0] << 8) | b[1]
        # gb18030ext (encoding): gb18030's two-byte codes past GBK_ENCODE
        gbk_ok = u in (0x2014, 0x2015, 0x00B7) or (u != 0x30FB and enc("gbk", ch) is not None)
        if not gbk_ok:
            b = enc("gb18030", ch)
            if b is not None and len(b) == 2:
                gb18030ext_e[u] = (b[0] << 8) | b[1]
    t["gbcommon"] = gbcommon
    t["gb18030ext_e"] = gb18030ext_e
    # gb18030's four-byte BMP ranges: decode every linear sequence number
    lseq_cp = []
    for lseq in range(39420):
        c1, r = divmod(lseq, 12600)
        c2, r = divmod(r, 1260)
        c3, c4 = divmod(r, 10)
        s = dec("gb18030", bytes([c1 + 0x81, c2 + 0x30, c3 + 0x81, c4 + 0x30]))
        assert one(s), lseq
        lseq_cp.append(ord(s))
    ranges = []
    for lseq, cp in enumerate(lseq_cp):
        if ranges and cp - lseq == ranges[-1][0] - ranges[-1][2] and cp == ranges[-1][1] + 1:
            ranges[-1][1] = cp
        else:
            ranges.append([cp, cp, lseq])
    t["gb18030_ranges"] = ranges
    return t


# ── KR ──────────────────────────────────────────────────────────────────────
def derive_kr():
    t = {}
    # ksx1001: as iso2022_kr's KS X 1001 designation decodes it (no special
    # cases there)
    ksx1001 = {}
    for c1 in R94:
        for c2 in R94:
            s = dec("iso2022_kr", b"\x1b$)C\x0e" + bytes([c1, c2]) + b"\x0f")
            if one(s):
                ksx1001[(c1, c2)] = ord(s)
    t["ksx1001"] = ksx1001
    cp949ext = {}
    for c1 in range(0x81, 0xFF):
        for c2 in range(0x41, 0xFF):
            if c1 >= 0xA1 and c2 >= 0xA1 and (c1 ^ 0x80, c2 ^ 0x80) in ksx1001:
                continue
            s = dec("cp949", bytes([c1, c2]))
            if one(s):
                cp949ext[(c1, c2)] = ord(s)
    t["cp949ext"] = cp949ext
    # cp949 (encoding): KS X 1001 codes (MSB clear) where euc_kr writes two
    # bytes, CP949's (MSB set) where it writes the make-up sequence
    cp949 = {}
    for u in range(0x80, 0x10000):
        if 0xD800 <= u < 0xE000:
            continue
        ch = chr(u)
        b = enc("euc_kr", ch)
        if b is not None and len(b) == 2:
            cp949[u] = ((b[0] ^ 0x80) << 8) | (b[1] ^ 0x80)
            continue
        b = enc("cp949", ch)
        if b is not None:
            assert len(b) == 2
            cp949[u] = (b[0] << 8) | b[1]
            assert cp949[u] & 0x8000
    t["cp949"] = cp949
    return t


# ── TW / HK ─────────────────────────────────────────────────────────────────
def derive_tw():
    t = {}
    big5_d, big5_e = {}, {}
    for c1 in range(0x81, 0xFF):
        for c2 in range(0x40, 0xFF):
            s = dec("big5", bytes([c1, c2]))
            if one(s):
                big5_d[(c1, c2)] = ord(s)
    for u in range(0x80, 0x10000):
        if 0xD800 <= u < 0xE000:
            continue
        b = enc("big5", chr(u))
        if b is not None:
            big5_e[u] = (b[0] << 8) | b[1]
    t["big5_d"], t["big5_e"] = big5_d, big5_e
    # cp950ext: cp950 consults it before big5
    ext_d, ext_e = {}, {}
    for c1 in range(0x81, 0xFF):
        for c2 in range(0x40, 0xFF):
            s = dec("cp950", bytes([c1, c2]))
            if one(s) and big5_d.get((c1, c2)) != ord(s):
                ext_d[(c1, c2)] = ord(s)
    for u in range(0x80, 0x10000):
        if 0xD800 <= u < 0xE000:
            continue
        b = enc("cp950", chr(u))
        if b is not None and big5_e.get(u) != ((b[0] << 8) | b[1]):
            ext_e[u] = (b[0] << 8) | b[1]
    t["cp950ext_d"], t["cp950ext_e"] = ext_d, ext_e
    # big5hkscs: its decoding beyond the big5 it consults first (stored with
    # the plane bit: CPython's phint bitmaps are folded into the values)
    hk_d = {}
    for c1 in range(0x87, 0xFF):
        for c2 in range(0x40, 0xFF):
            bpath = not (0xC6 <= c1 <= 0xC8) or (c1 < 0xC7 and c2 < 0xA1)
            if bpath and (c1, c2) in big5_d:
                continue
            s = dec("big5hkscs", bytes([c1, c2]))
            if one(s):
                hk_d[(c1, c2)] = ord(s)
    t["big5hkscs_d"] = hk_d
    hk_bmp, hk_nonbmp = {}, {}
    for u in range(0x80, 0x10000):
        if 0xD800 <= u < 0xE000 or u in (0xCA, 0xEA):
            continue
        b = enc("big5hkscs", chr(u))
        if b is not None and big5_e.get(u) != ((b[0] << 8) | b[1]):
            hk_bmp[u] = (b[0] << 8) | b[1]
    for u in range(0x20000, 0x30000):
        b = enc("big5hkscs", chr(u))
        if b is not None:
            hk_nonbmp[u & 0xFFFF] = (b[0] << 8) | b[1]
    # U+00CA and U+00EA start the four HKSCS pairs (MULTIC: the encoder looks
    # at the next character)
    hk_bmp[0xCA] = hk_bmp[0xEA] = "M"
    t["big5hkscs_bmp"], t["big5hkscs_nonbmp"] = hk_bmp, hk_nonbmp
    return t


# ── JP ──────────────────────────────────────────────────────────────────────
def sjis_bytes(c1, c2):
    # JIS row/cell (0x21..0x7E) -> Shift_JIS bytes (CPython's shift_jis encoder)
    t2 = ((0x5E if (c1 - 0x21) & 1 else 0) + (c2 - 0x21))
    t1 = (c1 - 0x21) >> 1
    return bytes([t1 + 0x81 if t1 < 0x1F else t1 + 0xC1, t2 + 0x40 if t2 < 0x3F else t2 + 0x41])


def sjis2004_jis(c, c2):
    # CPython's shift_jis_2004 decoder: the (plane, row, cell) two bytes
    # name, None when they name none
    if not (0x81 <= c <= 0x9F or 0xE0 <= c <= 0xFC):
        return None
    if c2 < 0x40 or 0x7E < c2 < 0x80 or c2 > 0xFC:
        return None
    c1 = c - 0x81 if c < 0xE0 else c - 0xC1
    c2 = c2 - 0x40 if c2 < 0x80 else c2 - 0x41
    c1 = 2 * c1 + (0 if c2 < 0x5E else 1)
    c2 = (c2 if c2 < 0x5E else c2 - 0x5E) + 0x21
    if c1 < 0x5E:
        return (1, c1 + 0x21, c2)
    if c1 >= 0x67:
        c1 += 0x07
    elif c1 >= 0x63 or c1 == 0x5F:
        c1 -= 0x37
    else:
        c1 -= 0x3D
    return (2, c1, c2)


def derive_jp():
    t = {}
    # jisx0208: as iso2022_jp's JIS X 0208 designation decodes it; its one
    # special case (0x2140, F/W REVERSE SOLIDUS) hides the table there, read
    # through shift_jis_2004 (which has no special case) below
    jisx0208 = {}
    for c1 in R94:
        for c2 in R94:
            if (c1, c2) == (0x21, 0x40):
                continue
            s = dec("iso2022_jp", b"\x1b$B" + bytes([c1, c2]) + b"\x1b(B")
            if one(s):
                jisx0208[(c1, c2)] = ord(s)
    # JIS X 0213 plane 1 as shift_jis_2004 sees it: jisx0208, then
    # jisx0213_1_bmp, _1_emp, the pairs
    plane1, plane2 = {}, {}
    for c in range(0x81, 0xFD):
        for c2 in range(0x40, 0xFD):
            p = sjis2004_jis(c, c2)
            if p is None:
                continue
            s = dec("shift_jis_2004", bytes([c, c2]))
            if s is not None:
                (plane1 if p[0] == 1 else plane2)[(p[1], p[2])] = s
    if (0x21, 0x40) in plane1 and len(plane1[(0x21, 0x40)]) == 1 and ord(plane1[(0x21, 0x40)]) < 0x10000:
        jisx0208[(0x21, 0x40)] = ord(plane1[(0x21, 0x40)])
    t["jisx0208"] = jisx0208
    j1bmp, j1emp, jpair, j2bmp, j2emp = {}, {}, {}, {}, {}
    for k, s in plane1.items():
        if k in jisx0208:
            assert one(s) and ord(s) == jisx0208[k], k
            continue
        if len(s) == 2:
            jpair[k] = (ord(s[0]) << 16) | ord(s[1])
        elif ord(s) >= 0x20000:
            j1emp[k] = ord(s) & 0xFFFF
        else:
            j1bmp[k] = ord(s)
    for k, s in plane2.items():
        assert len(s) == 1
        if ord(s) >= 0x20000:
            j2emp[k] = ord(s) & 0xFFFF
        else:
            j2bmp[k] = ord(s)
    t["jisx0213_1_bmp"], t["jisx0213_1_emp"], t["jisx0213_pair_d"] = j1bmp, j1emp, jpair
    t["jisx0213_2_bmp"], t["jisx0213_2_emp"] = j2bmp, j2emp
    # jisx0212: iso2022_jp_1's JIS X 0212 designation (no special case)
    jisx0212 = {}
    for c1 in R94:
        for c2 in R94:
            s = dec("iso2022_jp_1", b"\x1b$(D" + bytes([c1, c2]) + b"\x1b(B")
            if one(s):
                jisx0212[(c1, c2)] = ord(s)
    t["jisx0212"] = jisx0212
    # jisxcommon (encoding): euc_jp consults it first; two bytes are a JIS X
    # 0208 code, 0x8F and two a JIS X 0212 one (MSB set). Half-width katakana
    # (0x8E ..), YEN SIGN and OVERLINE (one byte) and FF3C come after it.
    jisxcommon = {}
    for u in range(0x80, 0x10000):
        if 0xD800 <= u < 0xE000 or u == 0xFF3C:
            continue
        b = enc("euc_jp", chr(u))
        if b is None or len(b) == 1 or b[0] == 0x8E:
            continue
        if len(b) == 2:
            jisxcommon[u] = ((b[0] ^ 0x80) << 8) | (b[1] ^ 0x80)
        else:
            assert b[0] == 0x8F
            jisxcommon[u] = (b[1] << 8) | (b[2] ^ 0x80)
    # below 0x80 only shift_jis_2004 asks it (its JIS X 0201 Roman leaves out
    # REVERSE SOLIDUS and TILDE): JIS X 0208's 0x2140 and 0x2232
    for u in range(0x80):
        b = enc("shift_jis_2004", chr(u))
        if b is not None and len(b) == 2:
            p = sjis2004_jis(b[0], b[1])
            assert p is not None and p[0] == 1
            jisxcommon[u] = (p[1] << 8) | p[2]
    t["jisxcommon"] = jisxcommon
    # cp932ext: what cp932 decodes / encodes otherwise than its JIS X 0208
    # path and its algorithmic ranges would
    ext_d, ext_e = {}, {}
    for c in list(range(0x81, 0xA0)) + list(range(0xE0, 0xFD)):
        for c2 in range(0x40, 0xFD):
            s = dec("cp932", bytes([c, c2]))
            if not one(s):
                continue
            want = None
            if (0x81 <= c <= 0x9F or 0xE0 <= c <= 0xEA) and not (c2 < 0x40 or 0x7E < c2 < 0x80 or c2 > 0xFC):
                a = c - 0x81 if c < 0xE0 else c - 0xC1
                b2 = c2 - 0x40 if c2 < 0x80 else c2 - 0x41
                j1 = 2 * a + (0 if b2 < 0x5E else 1) + 0x21
                j2 = (b2 if b2 < 0x5E else b2 - 0x5E) + 0x21
                want = jisx0208.get((j1, j2))
            elif 0xF0 <= c <= 0xF9 and (0x40 <= c2 <= 0x7E or 0x80 <= c2 <= 0xFC):
                want = 0xE000 + 188 * (c - 0xF0) + (c2 - 0x40 if c2 < 0x80 else c2 - 0x41)
            if want != ord(s):
                ext_d[(c, c2)] = ord(s)
    for u in range(0x81, 0x10000):
        if 0xD800 <= u < 0xE000 or 0xFF61 <= u <= 0xFF9F or 0xF8F0 <= u <= 0xF8F3:
            continue
        b = enc("cp932", chr(u))
        if b is None or len(b) != 2:
            continue
        want = None
        code = jisxcommon.get(u)
        if code is not None and not code & 0x8000:
            want = sjis_bytes(code >> 8, code & 0xFF)
        elif 0xE000 <= u < 0xE758:
            c1, c2 = divmod(u - 0xE000, 188)
            want = bytes([c1 + 0xF0, c2 + 0x40 if c2 < 0x3F else c2 + 0x41])
        if want != b:
            ext_e[u] = (b[0] << 8) | b[1]
    t["cp932ext_d"], t["cp932ext_e"] = ext_d, ext_e
    # JIS X 0213 (encoding), from euc_jis_2004: jisx0213_bmp where it gives
    # another code than jisxcommon's - or the same plane-2 code that
    # shift_jis_2004 (which drops jisxcommon's JIS X 0212 codes) still writes
    pairs = {}
    for k, v in jpair.items():
        pairs[(v >> 16, v & 0xFFFF)] = (k[0] << 8) | k[1]
    multic = set(a for a, b in pairs)
    j213 = {}
    for u in range(0x80, 0x10000):
        if 0xD800 <= u < 0xE000 or u in multic:
            continue
        b = enc("euc_jis_2004", chr(u))
        if b is None or len(b) == 1 or b[0] == 0x8E:
            continue
        if len(b) == 2:
            code = ((b[0] ^ 0x80) << 8) | (b[1] ^ 0x80)
        else:
            code = 0x8000 | ((b[1] ^ 0x80) << 8) | (b[2] ^ 0x80)
        if u in (0xFF3C, 0xFF5E) and jisxcommon.get(u) is None and code in (0x2140, 0x2232):
            continue      # euc_jis_2004's special cases after both tables
        if jisxcommon.get(u) != code or (code & 0x8000 and enc("shift_jis_2004", chr(u)) is not None):
            j213[u] = code
    for u in multic:
        j213[u] = "M"
    single = {}
    for u in multic:
        b = enc("euc_jis_2004", chr(u))
        if b is not None:
            assert len(b) == 2
            single[u] = ((b[0] ^ 0x80) << 8) | (b[1] ^ 0x80)
    t["jisx0213_bmp"], t["jisx0213_pairs"], t["jisx0213_single"] = j213, pairs, single
    jemp = {}
    for u in range(0x20000, 0x30000):
        b = enc("euc_jis_2004", chr(u))
        if b is None:
            continue
        if len(b) == 2:
            jemp[u & 0xFFFF] = ((b[0] ^ 0x80) << 8) | (b[1] ^ 0x80)
        else:
            jemp[u & 0xFFFF] = 0x8000 | ((b[1] ^ 0x80) << 8) | (b[2] ^ 0x80)
    t["jisx0213_emp"] = jemp
    return t


# ── emitting ────────────────────────────────────────────────────────────────
class Blob:
    """the tables as one byte string (deflated into the .inc): each table a
    header (kind, row count) and its rows"""

    def __init__(self):
        self.out = bytearray()
        self.names = []

    def u8(self, v):
        self.out.append(v)

    def u16(self, v):
        self.out += struct.pack("<H", v)

    def u32(self, v):
        self.out += struct.pack("<I", v)

    def decmap(self, name, d, wide=False):
        # per first byte: bottom, top, then top-bottom+1 values (UNIINV for none)
        self.names.append(name)
        rows = {}
        for (a, b), v in d.items():
            rows.setdefault(a, {})[b] = v
        self.u8(1 if wide else 0)
        self.u16(len(rows))
        for a in sorted(rows):
            r = rows[a]
            lo, hi = min(r), max(r)
            self.u8(a)
            self.u8(lo)
            self.u8(hi)
            prev = 0
            for b in range(lo, hi + 1):
                v = r.get(b, 0xFFFE)
                if wide:
                    self.u32(v)
                else:
                    # values delta-coded against the previous one: runs of
                    # consecutive code points deflate to almost nothing
                    self.u16((v - prev) & 0xFFFF)
                    prev = v

    def encdiff(self, name, e, inv):
        # an encoding map stored as its differences from `inv`, the inverse
        # of decoding maps nycjk.cpp computes itself (inverse() below, the
        # same order): (code point delta, value) pairs, NOCHAR to remove one
        self.names.append(name + " (diff)")
        diff = []
        for u in sorted(set(e) | set(inv)):
            v = e.get(u)
            v = 0xFFFE if v == "M" else v
            if v != inv.get(u):
                diff.append((u, 0xFFFF if v is None else v))
        self.u8(3)
        self.u32(len(diff))
        prev = 0
        for u, v in diff:
            self.u32(u - prev)
            prev = u
            self.u16(v)
        return len(diff)

    def encmap(self, name, e):
        # per high byte of the code point: bottom, top, values (NOCHAR for none)
        self.names.append(name)
        rows = {}
        for u, v in e.items():
            rows.setdefault(u >> 8, {})[u & 0xFF] = 0xFFFE if v == "M" else v
        self.u8(2)
        self.u16(len(rows))
        for a in sorted(rows):
            r = rows[a]
            lo, hi = min(r), max(r)
            self.u8(a)
            self.u8(lo)
            self.u8(hi)
            prev = 0
            for b in range(lo, hi + 1):
                v = r.get(b, 0xFFFF)
                self.u16((v - prev) & 0xFFFF)
                prev = v


def inverse(*sources):
    # the inverse of decoding maps, the first one to give a code point
    # winning: each source (decoding map, flag ORed into the code, keep):
    # rows and cells in ascending order (nycjk.cpp's build_inverse)
    inv = {}
    for d, flag, keep in sources:
        for (a, b) in sorted(d):
            v = d[(a, b)]
            if not keep(v):
                continue
            u = v & 0xFFFF if v >= 0x10000 else v
            if u not in inv:
                inv[u] = flag | (a << 8) | b
    return inv


ALL = lambda v: True


def main():
    stats = "--stats" in sys.argv
    t = {}
    for f in (derive_cn, derive_kr, derive_tw, derive_jp):
        t.update(f())
    b = Blob()
    # the decoding maps, then the encoding maps as differences from their
    # decoding maps' inverses (the order nycjk.cpp reads them in)
    for name in ("gb2312", "gbkext", "gb18030ext_d", "ksx1001", "cp949ext", "big5_d", "cp950ext_d"):
        b.decmap(name, t[name])
    b.decmap("big5hkscs_d", t["big5hkscs_d"], wide=True)
    for name in ("jisx0208", "jisx0212", "jisx0213_1_bmp", "jisx0213_2_bmp", "jisx0213_1_emp", "jisx0213_2_emp"):
        b.decmap(name, t[name])
    b.decmap("jisx0213_pair_d", t["jisx0213_pair_d"], wide=True)
    b.decmap("cp932ext_d", t["cp932ext_d"])
    nd = {}
    nd["gbcommon"] = b.encdiff("gbcommon", t["gbcommon"], inverse((t["gb2312"], 0, ALL), (t["gbkext"], 0, ALL)))
    nd["gb18030ext_e"] = b.encdiff("gb18030ext_e", t["gb18030ext_e"], inverse((t["gb18030ext_d"], 0, ALL)))
    nd["cp949"] = b.encdiff("cp949", t["cp949"], inverse((t["ksx1001"], 0, ALL), (t["cp949ext"], 0, ALL)))
    nd["big5_e"] = b.encdiff("big5_e", t["big5_e"], inverse((t["big5_d"], 0, ALL)))
    nd["cp950ext_e"] = b.encdiff("cp950ext_e", t["cp950ext_e"], {})
    nd["big5hkscs_bmp"] = b.encdiff("big5hkscs_bmp", t["big5hkscs_bmp"],
                                    inverse((t["big5hkscs_d"], 0, lambda v: v < 0x10000)))
    nd["big5hkscs_nonbmp"] = b.encdiff("big5hkscs_nonbmp", t["big5hkscs_nonbmp"],
                                       inverse((t["big5hkscs_d"], 0, lambda v: v >= 0x20000)))
    nd["jisxcommon"] = b.encdiff("jisxcommon", t["jisxcommon"],
                                 inverse((t["jisx0208"], 0, ALL), (t["jisx0212"], 0x8000, ALL)))
    nd["jisx0213_bmp"] = b.encdiff("jisx0213_bmp", t["jisx0213_bmp"],
                                   inverse((t["jisx0213_1_bmp"], 0, ALL), (t["jisx0213_2_bmp"], 0x8000, ALL)))
    nd["jisx0213_emp"] = b.encdiff("jisx0213_emp", t["jisx0213_emp"],
                                   inverse((t["jisx0213_1_emp"], 0, ALL), (t["jisx0213_2_emp"], 0x8000, ALL)))
    nd["cp932ext_e"] = b.encdiff("cp932ext_e", t["cp932ext_e"], {})
    if stats:
        log("encoding maps stored as differences: " + ", ".join("%s %d" % kv for kv in nd.items()))
    raw = bytes(b.out)
    packed = zlib.compress(raw, 9)
    if stats:
        for k, v in t.items():
            log("%-20s %6d" % (k, len(v)))
        log("blob: %d bytes raw, %d deflated" % (len(raw), len(packed)))
    o = []
    o.append("// src/builtins/nycjk_tables.inc - GENERATED by tools/gen_cjk_codecs.py from Python %s's"
             % sys.version.split()[0])
    o.append("// codecs. Do not edit by hand; included by src/builtins/nycjk.cpp only.")
    o.append("// The tables, in this order (each: kind 0 decode / 1 wide decode / 2 encode,")
    o.append("// a row count, rows of first byte, bottom, top and delta-coded values):")
    for i in range(0, len(b.names), 6):
        o.append("//   " + ", ".join(b.names[i:i + 6]))
    o.append("// %d bytes inflated." % len(raw))
    o.append("static const size_t kCjkRawSize = %d;" % len(raw))
    o.append("static const unsigned char kCjkBlob[%d] = {" % len(packed))
    for i in range(0, len(packed), 24):
        o.append("    " + ",".join(str(x) for x in packed[i:i + 24]) + ",")
    o.append("};")
    o.append("// gb18030's four-byte BMP ranges (first, last, linear base), CPython's")
    o.append("// gb18030_to_unibmp_ranges")
    rng = t["gb18030_ranges"]
    o.append("static const uint32_t kGb18030Ranges[%d][3] = {" % (len(rng) + 1))
    for a, z, base in rng:
        o.append("    {0x%X, 0x%X, %d}," % (a, z, base))
    o.append("    {0, 0, 39420},")
    o.append("};")
    o.append("// JIS X 0213 pairs: (first << 16 | second, code), sorted; a lone first")
    o.append("// character's own code with second 0 (CPython's jisx0213_pair_encmap)")
    pe = sorted([((a << 16) | b2, c) for (a, b2), c in t["jisx0213_pairs"].items()] +
                [((a << 16), c) for a, c in t["jisx0213_single"].items()])
    o.append("static const uint32_t kJisx0213PairEnc[%d][2] = {" % len(pe))
    for i in range(0, len(pe), 6):
        o.append("    " + " ".join("{0x%X,0x%X}," % p for p in pe[i:i + 6]))
    o.append("};")
    with open(os.path.join(ROOT, "src", "builtins", "nycjk_tables.inc"), "w") as f:
        f.write("\n".join(o) + "\n")
    # CPython's encodings.aliases for these codecs
    from encodings.aliases import aliases
    cjk = set(CODECS)
    rows = sorted((k, v) for k, v in aliases.items() if v in cjk)
    a = ["// src/builtins/nycjk_aliases.inc - GENERATED by tools/gen_cjk_codecs.py: CPython's",
         "// encodings.aliases entries for the CJK codecs (normalized names).",
         "const Alias kCjkAliases[] = {"]
    for k, v in rows:
        a.append('    {"%s", "%s"},' % (k, v))
    a.append("};")
    with open(os.path.join(ROOT, "src", "builtins", "nycjk_aliases.inc"), "w") as f:
        f.write("\n".join(a) + "\n")


CODECS = ["gb2312", "gbk", "gb18030", "hz", "euc_kr", "cp949", "johab", "big5", "cp950", "big5hkscs",
          "shift_jis", "cp932", "euc_jp", "shift_jis_2004", "euc_jis_2004", "euc_jisx0213", "shift_jisx0213",
          "iso2022_kr", "iso2022_jp", "iso2022_jp_1", "iso2022_jp_2", "iso2022_jp_2004", "iso2022_jp_3",
          "iso2022_jp_ext"]


if __name__ == "__main__":
    main()
