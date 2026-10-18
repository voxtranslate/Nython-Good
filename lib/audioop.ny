# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/audioop.ny - Python's audioop (CPython 3.12's Modules/audioop.c,
# written in Nython; deprecated in 3.11 and removed in 3.13, so importing it
# warns as CPython's does).
#
#     import audioop
#     audioop.max(b"\x00\x10\x00\xf0", 2)            # 4096
#     audioop.lin2ulaw(b"\x00\x10", 2)               # b'\xce'
#     audioop.ratecv(frames, 2, 1, 8000, 16000, None)
#
# Every function of the C module, with its results byte for byte (samples
# are signed, of width 1, 2, 3 or 4 bytes, little-endian as on the machines
# Nython runs on): add, adpcm2lin, alaw2lin, avg, avgpp, bias, byteswap,
# cross, findfactor, findfit, findmax, getsample, lin2adpcm, lin2alaw,
# lin2lin, lin2ulaw, max, maxpp, minmax, mul, ratecv, reverse, rms,
# tomono, tostereo, ulaw2lin; audioop.error with the C module's messages.
# Fragments may be bytes, bytearray or anything bytes() takes.
#
# Not provided: big-endian hosts (the samples are always little-endian).

import struct as _struct
import math as _math
import warnings as _warnings

_warnings._deprecated(__name__, remove=(3, 13))


class error(Exception):
    __module__ = "audioop"


_MAXVALS = (0, 0x7F, 0x7FFF, 0x7FFFFF, 0x7FFFFFFF)
_MINVALS = (0, -0x80, -0x8000, -0x800000, -0x7FFFFFFF - 1)
_MASKS = (0, 0xFF, 0xFFFF, 0xFFFFFF, 0xFFFFFFFF)
_FMT = (None, "b", "h", None, "i")
_UFMT = (None, "B", "H", None, "I")

_INDEX_TABLE = (-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8)
_STEPSIZE_TABLE = (
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
)
_SEG_UEND = (0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF)
_SEG_AEND = (0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF)

_ULAW2LIN = (
    -32124, -31100, -30076, -29052, -28028, -27004, -25980, -24956,
    -23932, -22908, -21884, -20860, -19836, -18812, -17788, -16764,
    -15996, -15484, -14972, -14460, -13948, -13436, -12924, -12412,
    -11900, -11388, -10876, -10364, -9852, -9340, -8828, -8316,
    -7932, -7676, -7420, -7164, -6908, -6652, -6396, -6140,
    -5884, -5628, -5372, -5116, -4860, -4604, -4348, -4092,
    -3900, -3772, -3644, -3516, -3388, -3260, -3132, -3004,
    -2876, -2748, -2620, -2492, -2364, -2236, -2108, -1980,
    -1884, -1820, -1756, -1692, -1628, -1564, -1500, -1436,
    -1372, -1308, -1244, -1180, -1116, -1052, -988, -924,
    -876, -844, -812, -780, -748, -716, -684, -652,
    -620, -588, -556, -524, -492, -460, -428, -396,
    -372, -356, -340, -324, -308, -292, -276, -260,
    -244, -228, -212, -196, -180, -164, -148, -132,
    -120, -112, -104, -96, -88, -80, -72, -64,
    -56, -48, -40, -32, -24, -16, -8, 0,
    32124, 31100, 30076, 29052, 28028, 27004, 25980, 24956,
    23932, 22908, 21884, 20860, 19836, 18812, 17788, 16764,
    15996, 15484, 14972, 14460, 13948, 13436, 12924, 12412,
    11900, 11388, 10876, 10364, 9852, 9340, 8828, 8316,
    7932, 7676, 7420, 7164, 6908, 6652, 6396, 6140,
    5884, 5628, 5372, 5116, 4860, 4604, 4348, 4092,
    3900, 3772, 3644, 3516, 3388, 3260, 3132, 3004,
    2876, 2748, 2620, 2492, 2364, 2236, 2108, 1980,
    1884, 1820, 1756, 1692, 1628, 1564, 1500, 1436,
    1372, 1308, 1244, 1180, 1116, 1052, 988, 924,
    876, 844, 812, 780, 748, 716, 684, 652,
    620, 588, 556, 524, 492, 460, 428, 396,
    372, 356, 340, 324, 308, 292, 276, 260,
    244, 228, 212, 196, 180, 164, 148, 132,
    120, 112, 104, 96, 88, 80, 72, 64,
    56, 48, 40, 32, 24, 16, 8, 0,
)
_ALAW2LIN = (
    -5504, -5248, -6016, -5760, -4480, -4224, -4992, -4736,
    -7552, -7296, -8064, -7808, -6528, -6272, -7040, -6784,
    -2752, -2624, -3008, -2880, -2240, -2112, -2496, -2368,
    -3776, -3648, -4032, -3904, -3264, -3136, -3520, -3392,
    -22016, -20992, -24064, -23040, -17920, -16896, -19968, -18944,
    -30208, -29184, -32256, -31232, -26112, -25088, -28160, -27136,
    -11008, -10496, -12032, -11520, -8960, -8448, -9984, -9472,
    -15104, -14592, -16128, -15616, -13056, -12544, -14080, -13568,
    -344, -328, -376, -360, -280, -264, -312, -296,
    -472, -456, -504, -488, -408, -392, -440, -424,
    -88, -72, -120, -104, -24, -8, -56, -40,
    -216, -200, -248, -232, -152, -136, -184, -168,
    -1376, -1312, -1504, -1440, -1120, -1056, -1248, -1184,
    -1888, -1824, -2016, -1952, -1632, -1568, -1760, -1696,
    -688, -656, -752, -720, -560, -528, -624, -592,
    -944, -912, -1008, -976, -816, -784, -880, -848,
    5504, 5248, 6016, 5760, 4480, 4224, 4992, 4736,
    7552, 7296, 8064, 7808, 6528, 6272, 7040, 6784,
    2752, 2624, 3008, 2880, 2240, 2112, 2496, 2368,
    3776, 3648, 4032, 3904, 3264, 3136, 3520, 3392,
    22016, 20992, 24064, 23040, 17920, 16896, 19968, 18944,
    30208, 29184, 32256, 31232, 26112, 25088, 28160, 27136,
    11008, 10496, 12032, 11520, 8960, 8448, 9984, 9472,
    15104, 14592, 16128, 15616, 13056, 12544, 14080, 13568,
    344, 328, 376, 360, 280, 264, 312, 296,
    472, 456, 504, 488, 408, 392, 440, 424,
    88, 72, 120, 104, 24, 8, 56, 40,
    216, 200, 248, 232, 152, 136, 184, 168,
    1376, 1312, 1504, 1440, 1120, 1056, 1248, 1184,
    1888, 1824, 2016, 1952, 1632, 1568, 1760, 1696,
    688, 656, 752, 720, 560, 528, 624, 592,
    944, 912, 1008, 976, 816, 784, 880, 848,
)

def _buf(fragment):
    if isinstance(fragment, bytes):
        return fragment
    if isinstance(fragment, str):
        raise TypeError("a bytes-like object is required, not 'str'")
    return bytes(fragment)


def _check_size(size):
    if size < 1 or size > 4:
        raise error("Size should be 1, 2, 3 or 4")


def _check_parameters(length, size):
    _check_size(size)
    if length % size != 0:
        raise error("not a whole number of frames")


# The samples of a fragment as ints (signed), and back.
def _samples(cp, size):
    n = len(cp) // size
    if n == 0:
        return []
    if size == 3:
        out = []
        for i in range(0, n * 3, 3):
            v = cp[i] | (cp[i + 1] << 8) | (cp[i + 2] << 16)
            if v >= 0x800000:
                v = v - 0x1000000
            out.append(v)
        return out
    return list(_struct.unpack("<" + str(n) + _FMT[size], cp[:n * size]))


def _pack(vals, size):
    if not vals:
        return b""
    if size == 3:
        out = bytearray()
        for v in vals:
            v = v & 0xFFFFFF
            out.append(v & 0xFF)
            out.append((v >> 8) & 0xFF)
            out.append((v >> 16) & 0xFF)
        return bytes(out)
    return _struct.pack("<" + str(len(vals)) + _FMT[size], *vals)


# GETSAMPLE32 / SETSAMPLE32: a sample scaled to (and from) 32 bits
def _to32(v, size):
    return _wrap32(v << (32 - 8 * size))


def _from32(v, size):
    return v >> (32 - 8 * size)


def _wrap32(v):
    v = v & 0xFFFFFFFF
    if v >= 0x80000000:
        v = v - 0x100000000
    return v


def _fbound(val, minval, maxval):
    if val > maxval:
        val = maxval
    elif val < minval + 1.0:
        val = minval
    return int(_math.floor(val))


# C's double division: inf or nan instead of ZeroDivisionError
def _cdiv(a, b):
    if b == 0:
        if a == 0 or a != a:
            return float("nan")
        return float("inf") if a > 0 else float("-inf")
    return a / b


def _ctrunc(x):
    # (int) of a double: towards zero
    return int(x)


def getsample(fragment, width, index, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    if index < 0 or index >= len(cp) // width:
        raise error("Index out of range")
    return _samples(cp[index * width:(index + 1) * width], width)[0]


def max(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    m = 0
    for v in _samples(cp, width):
        a = -v if v < 0 else v
        if a > m:
            m = a
    return m


def minmax(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    lo = 0x7FFFFFFF
    hi = -0x7FFFFFFF - 1
    for v in _samples(cp, width):
        if v > hi:
            hi = v
        if v < lo:
            lo = v
    return (lo, hi)


def avg(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    n = len(cp) // width
    if n == 0:
        return 0
    s = 0.0
    for v in _samples(cp, width):
        s = s + v
    return int(_math.floor(s / float(n)))


def rms(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    n = len(cp) // width
    if n == 0:
        return 0
    s = 0.0
    for v in _samples(cp, width):
        s = s + float(v) * float(v)
    return int(_math.sqrt(s / float(n)))


def _sum2(a, ai, b, bi, n):
    s = 0.0
    for i in range(n):
        s = s + float(a[ai + i]) * float(b[bi + i])
    return s


def _shorts(cp):
    return _samples(cp, 2)


def findfit(fragment, reference, /):
    f = _buf(fragment)
    r = _buf(reference)
    if len(f) & 1 or len(r) & 1:
        raise error("Strings should be even-sized")
    cp1 = _shorts(f)
    cp2 = _shorts(r)
    len1 = len(cp1)
    len2 = len(cp2)
    if len1 < len2:
        raise error("First sample should be longer")
    sum_ri_2 = _sum2(cp2, 0, cp2, 0, len2)
    sum_aij_2 = _sum2(cp1, 0, cp1, 0, len2)
    sum_aij_ri = _sum2(cp1, 0, cp2, 0, len2)
    result = _cdiv(sum_ri_2 * sum_aij_2 - sum_aij_ri * sum_aij_ri, sum_aij_2)
    best_result = result
    best_j = 0
    for j in range(1, len1 - len2 + 1):
        aj_m1 = float(cp1[j - 1])
        aj_lm1 = float(cp1[j + len2 - 1])
        sum_aij_2 = sum_aij_2 + aj_lm1 * aj_lm1 - aj_m1 * aj_m1
        sum_aij_ri = _sum2(cp1, j, cp2, 0, len2)
        result = _cdiv(sum_ri_2 * sum_aij_2 - sum_aij_ri * sum_aij_ri, sum_aij_2)
        if result < best_result:
            best_result = result
            best_j = j
    factor = _cdiv(_sum2(cp1, best_j, cp2, 0, len2), sum_ri_2)
    return (best_j, factor)


def findfactor(fragment, reference, /):
    f = _buf(fragment)
    r = _buf(reference)
    if len(f) & 1 or len(r) & 1:
        raise error("Strings should be even-sized")
    if len(f) != len(r):
        raise error("Samples should be same size")
    a = _shorts(f)
    b = _shorts(r)
    n = len(a)
    return _cdiv(_sum2(a, 0, b, 0, n), _sum2(b, 0, b, 0, n))


def findmax(fragment, length, /):
    f = _buf(fragment)
    if len(f) & 1:
        raise error("Strings should be even-sized")
    cp1 = _shorts(f)
    len1 = len(cp1)
    if length < 0 or len1 < length:
        raise error("Input sample should be longer")
    result = _sum2(cp1, 0, cp1, 0, length)
    best_result = result
    best_j = 0
    for j in range(1, len1 - length + 1):
        aj_m1 = float(cp1[j - 1])
        aj_lm1 = float(cp1[j + length - 1])
        result = result + aj_lm1 * aj_lm1 - aj_m1 * aj_m1
        if result > best_result:
            best_result = result
            best_j = j
    return best_j


def _extremes(vals):
    # the differences between successive extreme values (avgpp / maxpp)
    out = []
    if len(vals) <= 1:
        return out
    prevval = vals[0]
    prevextreme = prevval
    prevextremevalid = False
    prevdiff = 17
    for i in range(1, len(vals)):
        val = vals[i]
        if val != prevval:
            diff = 1 if val < prevval else 0
            if prevdiff == (1 - diff):
                if prevextremevalid:
                    if prevval < prevextreme:
                        out.append(prevextreme - prevval)
                    else:
                        out.append(prevval - prevextreme)
                prevextremevalid = True
                prevextreme = prevval
            prevval = val
            prevdiff = diff
    return out


def avgpp(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    if len(cp) <= width:
        return 0
    ex = _extremes(_samples(cp, width))
    if not ex:
        return 0
    s = 0.0
    for d in ex:
        s = s + float(d)
    return int(s / float(len(ex)))


def maxpp(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    if len(cp) <= width:
        return 0
    m = 0
    for d in _extremes(_samples(cp, width)):
        if d > m:
            m = d
    return m


def cross(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    ncross = -1
    prevval = 17
    for v in _samples(cp, width):
        val = 1 if v < 0 else 0
        if val != prevval:
            ncross = ncross + 1
        prevval = val
    return ncross


def mul(fragment, width, factor, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    maxval = float(_MAXVALS[width])
    minval = float(_MINVALS[width])
    factor = float(factor)
    return _pack([_fbound(float(v) * factor, minval, maxval) for v in _samples(cp, width)], width)


def tomono(fragment, width, lfactor, rfactor, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    if ((len(cp) // width) & 1) != 0:
        raise error("not a whole number of frames")
    maxval = float(_MAXVALS[width])
    minval = float(_MINVALS[width])
    lfactor = float(lfactor)
    rfactor = float(rfactor)
    s = _samples(cp, width)
    out = []
    for i in range(0, len(s), 2):
        out.append(_fbound(float(s[i]) * lfactor + float(s[i + 1]) * rfactor, minval, maxval))
    return _pack(out, width)


def tostereo(fragment, width, lfactor, rfactor, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    maxval = float(_MAXVALS[width])
    minval = float(_MINVALS[width])
    lfactor = float(lfactor)
    rfactor = float(rfactor)
    out = []
    for v in _samples(cp, width):
        out.append(_fbound(float(v) * lfactor, minval, maxval))
        out.append(_fbound(float(v) * rfactor, minval, maxval))
    return _pack(out, width)


def add(fragment1, fragment2, width, /):
    a = _buf(fragment1)
    b = _buf(fragment2)
    _check_parameters(len(a), width)
    if len(a) != len(b):
        raise error("Lengths should be the same")
    maxval = _MAXVALS[width]
    minval = _MINVALS[width]
    sa = _samples(a, width)
    sb = _samples(b, width)
    out = []
    for i in range(len(sa)):
        if width < 4:
            nv = sa[i] + sb[i]
            if nv > maxval:
                nv = maxval
            elif nv < minval:
                nv = minval
        else:
            nv = _fbound(float(sa[i]) + float(sb[i]), float(minval), float(maxval))
        out.append(nv)
    return _pack(out, width)


def bias(fragment, width, bias, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    mask = _MASKS[width]
    b = bias & 0xFFFFFFFF
    out = []
    for v in _samples(cp, width):
        u = (v & mask) + b
        u = u & mask
        if u > _MAXVALS[width]:
            u = u - mask - 1
        out.append(u)
    return _pack(out, width)


def reverse(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    s = _samples(cp, width)
    s.reverse()
    return _pack(s, width)


def byteswap(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    out = bytearray(len(cp))
    for i in range(0, len(cp), width):
        for j in range(width):
            out[i + width - 1 - j] = cp[i + j]
    return bytes(out)


def lin2lin(fragment, width, newwidth, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    _check_size(newwidth)
    if width == newwidth:
        return bytes(cp)
    return _pack([_from32(_to32(v, width), newwidth) for v in _samples(cp, width)], newwidth)


def _gcd(a, b):
    while b > 0:
        tmp = a % b
        a = b
        b = tmp
    return a


def ratecv(fragment, width, nchannels, inrate, outrate, state, weightA=1, weightB=0, /):
    cp = _buf(fragment)
    _check_size(width)
    if nchannels < 1:
        raise error("# of channels should be >= 1")
    if width > 0x7FFFFFFF // nchannels:
        raise OverflowError("width * nchannels too big for a C int")
    bytes_per_frame = width * nchannels
    if weightA < 1 or weightB < 0:
        raise error("weightA should be >= 1, weightB should be >= 0")
    if len(cp) % bytes_per_frame != 0:
        raise error("not a whole number of frames")
    if inrate <= 0 or outrate <= 0:
        raise error("sampling rate not > 0")
    d = _gcd(inrate, outrate)
    inrate = inrate // d
    outrate = outrate // d
    d = _gcd(weightA, weightB)
    weightA = weightA // d
    weightB = weightB // d
    nframes = len(cp) // bytes_per_frame
    prev_i = [0] * nchannels
    cur_i = [0] * nchannels
    if state is None:
        d = -outrate
    else:
        if not isinstance(state, tuple):
            raise TypeError("state must be a tuple or None")
        if len(state) != 2 or not isinstance(state[1], tuple):
            raise TypeError("ratecv(): illegal state argument")
        d = state[0]
        samps = state[1]
        if len(samps) != nchannels:
            raise error("illegal state argument")
        for chan in range(nchannels):
            channel = samps[chan]
            if not isinstance(channel, tuple) or len(channel) != 2:
                raise TypeError("ratecv(): illegal state argument")
            prev_i[chan] = channel[0]
            cur_i[chan] = channel[1]
    vals = _samples(cp, width)
    pos = 0
    out = []
    wa = float(weightA)
    wb = float(weightB)
    while True:
        while d < 0:
            if nframes == 0:
                samps = tuple([(prev_i[c], cur_i[c]) for c in range(nchannels)])
                return (_pack(out, width), (d, samps))
            for chan in range(nchannels):
                prev_i[chan] = cur_i[chan]
                cur_i[chan] = _to32(vals[pos], width)
                pos = pos + 1
                cur_i[chan] = _ctrunc((wa * float(cur_i[chan]) + wb * float(prev_i[chan])) / (wa + wb))
            nframes = nframes - 1
            d = d + outrate
        while d >= 0:
            for chan in range(nchannels):
                cur_o = _ctrunc((float(prev_i[chan]) * float(d) + float(cur_i[chan]) * float(outrate - d)) / float(outrate))
                out.append(_from32(_wrap32(cur_o), width))
            d = d - inrate


def _search(val, table):
    for i in range(len(table)):
        if val <= table[i]:
            return i
    return len(table)


def _st_14linear2ulaw(pcm_val):
    # 2's complement, 14-bit range
    if pcm_val < 0:
        pcm_val = -pcm_val
        mask = 0x7F
    else:
        mask = 0xFF
    if pcm_val > 8159:
        pcm_val = 8159
    pcm_val = pcm_val + (0x84 >> 2)
    seg = _search(pcm_val, _SEG_UEND)
    if seg >= 8:
        return 0x7F ^ mask
    uval = (seg << 4) | ((pcm_val >> (seg + 1)) & 0xF)
    return uval ^ mask


def _st_linear2alaw(pcm_val):
    # 2's complement, 13-bit range
    if pcm_val >= 0:
        mask = 0xD5
    else:
        mask = 0x55
        pcm_val = -pcm_val - 1
    seg = _search(pcm_val, _SEG_AEND)
    if seg >= 8:
        return 0x7F ^ mask
    aval = seg << 4
    if seg < 2:
        aval = aval | ((pcm_val >> 1) & 0xF)
    else:
        aval = aval | ((pcm_val >> seg) & 0xF)
    return aval ^ mask


def lin2ulaw(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    return bytes([_st_14linear2ulaw(_to32(v, width) >> 18) for v in _samples(cp, width)])


def ulaw2lin(fragment, width, /):
    cp = _buf(fragment)
    _check_size(width)
    return _pack([_from32(_wrap32(_ULAW2LIN[c] << 16), width) for c in cp], width)


def lin2alaw(fragment, width, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    return bytes([_st_linear2alaw(_to32(v, width) >> 19) for v in _samples(cp, width)])


def alaw2lin(fragment, width, /):
    cp = _buf(fragment)
    _check_size(width)
    return _pack([_from32(_wrap32(_ALAW2LIN[c] << 16), width) for c in cp], width)


def _adpcm_state(state, who):
    if state is None:
        return 0, 0
    if not isinstance(state, tuple):
        raise TypeError("state must be a tuple or None")
    if len(state) != 2 or not isinstance(state[0], int) or not isinstance(state[1], int):
        raise TypeError(who + "(): illegal state argument")
    valpred = state[0]
    index = state[1]
    if valpred >= 0x8000 or valpred < -0x8000 or index < 0 or index >= len(_STEPSIZE_TABLE):
        raise ValueError("bad state")
    return valpred, index


def lin2adpcm(fragment, width, state, /):
    cp = _buf(fragment)
    _check_parameters(len(cp), width)
    valpred, index = _adpcm_state(state, "lin2adpcm")
    step = _STEPSIZE_TABLE[index]
    bufferstep = True
    outputbuffer = 0
    out = bytearray()
    for v in _samples(cp, width):
        val = _to32(v, width) >> 16
        if val < valpred:
            diff = valpred - val
            sign = 8
        else:
            diff = val - valpred
            sign = 0
        delta = 0
        vpdiff = step >> 3
        if diff >= step:
            delta = 4
            diff = diff - step
            vpdiff = vpdiff + step
        step = step >> 1
        if diff >= step:
            delta = delta | 2
            diff = diff - step
            vpdiff = vpdiff + step
        step = step >> 1
        if diff >= step:
            delta = delta | 1
            vpdiff = vpdiff + step
        if sign:
            valpred = valpred - vpdiff
        else:
            valpred = valpred + vpdiff
        if valpred > 32767:
            valpred = 32767
        elif valpred < -32768:
            valpred = -32768
        delta = delta | sign
        index = index + _INDEX_TABLE[delta]
        if index < 0:
            index = 0
        if index > 88:
            index = 88
        step = _STEPSIZE_TABLE[index]
        if bufferstep:
            outputbuffer = (delta << 4) & 0xF0
        else:
            out.append((delta & 0x0F) | outputbuffer)
        bufferstep = not bufferstep
    return (bytes(out), (valpred, index))


def adpcm2lin(fragment, width, state, /):
    cp = _buf(fragment)
    _check_size(width)
    valpred, index = _adpcm_state(state, "adpcm2lin")
    step = _STEPSIZE_TABLE[index]
    out = []
    for inputbuffer in cp:
        for half in (0, 1):
            if half:
                delta = inputbuffer & 0xF
            else:
                delta = (inputbuffer >> 4) & 0xF
            index = index + _INDEX_TABLE[delta]
            if index < 0:
                index = 0
            if index > 88:
                index = 88
            sign = delta & 8
            delta = delta & 7
            vpdiff = step >> 3
            if delta & 4:
                vpdiff = vpdiff + step
            if delta & 2:
                vpdiff = vpdiff + (step >> 1)
            if delta & 1:
                vpdiff = vpdiff + (step >> 2)
            if sign:
                valpred = valpred - vpdiff
            else:
                valpred = valpred + vpdiff
            if valpred > 32767:
                valpred = 32767
            elif valpred < -32768:
                valpred = -32768
            step = _STEPSIZE_TABLE[index]
            out.append(_from32(_wrap32(valpred << 16), width))
    return (_pack(out, width), (valpred, index))
