# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/ossaudiodev.ny - Python's ossaudiodev (round 87; CPython 3.11's
# Modules/ossaudiodev.c, deprecated there and removed in 3.13): the Open
# Sound System's audio and mixer devices, over os.open and fcntl.ioctl.
#
#     import ossaudiodev
#     dsp = ossaudiodev.open("w")          # $AUDIODEV or /dev/dsp
#     dsp.setparameters(ossaudiodev.AFMT_S16_LE, 2, 44100)
#     dsp.writeall(frames); dsp.close()
#     mixer = ossaudiodev.openmixer()      # $MIXERDEV or /dev/mixer
#
# open([device,] mode) -> oss_audio_device: read, write, writeall, close,
# fileno, nonblock, setfmt, getfmts, channels, speed, sync, reset, post,
# setparameters, bufsize, obufcount, obuffree, getptr, flush, closed / name /
# mode, the context manager; openmixer([device]) -> oss_mixer_device: close,
# fileno, controls, stereocontrols, reccontrols, get, set, get_recsrc,
# set_recsrc; OSSAudioError (error); control_labels, control_names, the
# AFMT_* / SNDCTL_* / SOUND_MIXER_* constants (Linux's soundcard.h values,
# as CPython 3.11 on Linux gives them).
#
# On a system without OSS (no /dev/dsp - most of today's Linux, which has
# ALSA) open() raises the OSError CPython raises there (FileNotFoundError
# naming the device). POSIX only: importing it on Windows raises
# ModuleNotFoundError, as CPython.
import os as _os
import sys as _sys
import struct as _struct
import warnings

if _sys.platform == "win32":
    raise ModuleNotFoundError("No module named 'ossaudiodev'", name="ossaudiodev")

warnings._deprecated(__name__, remove=(3, 13))


class OSSAudioError(Exception):
    __module__ = "ossaudiodev"


error = OSSAudioError

AFMT_AC3 = 0x400
AFMT_A_LAW = 2
AFMT_IMA_ADPCM = 4
AFMT_MPEG = 0x200
AFMT_MU_LAW = 1
AFMT_QUERY = 0
AFMT_S16_BE = 32
AFMT_S16_LE = 16
AFMT_S16_NE = AFMT_S16_BE if _sys.byteorder == "big" else AFMT_S16_LE
AFMT_S8 = 64
AFMT_U16_BE = 0x100
AFMT_U16_LE = 128
AFMT_U8 = 8
SNDCTL_COPR_HALT = 0xc0144307
SNDCTL_COPR_LOAD = 0xcfb04301
SNDCTL_COPR_RCODE = 0xc0144303
SNDCTL_COPR_RCVMSG = 0x8fa44309
SNDCTL_COPR_RDATA = 0xc0144302
SNDCTL_COPR_RESET = 0x4300
SNDCTL_COPR_RUN = 0xc0144306
SNDCTL_COPR_SENDMSG = 0xcfa44308
SNDCTL_COPR_WCODE = 0x40144305
SNDCTL_COPR_WDATA = 0x40144304
SNDCTL_DSP_BIND_CHANNEL = 0xc0045041
SNDCTL_DSP_CHANNELS = 0xc0045006
SNDCTL_DSP_GETBLKSIZE = 0xc0045004
SNDCTL_DSP_GETCAPS = 0x8004500f
SNDCTL_DSP_GETCHANNELMASK = 0xc0045040
SNDCTL_DSP_GETFMTS = 0x8004500b
SNDCTL_DSP_GETIPTR = 0x800c5011
SNDCTL_DSP_GETISPACE = 0x8010500d
SNDCTL_DSP_GETODELAY = 0x80045017
SNDCTL_DSP_GETOPTR = 0x800c5012
SNDCTL_DSP_GETOSPACE = 0x8010500c
SNDCTL_DSP_GETSPDIF = 0x80045043
SNDCTL_DSP_GETTRIGGER = 0x80045010
SNDCTL_DSP_MAPINBUF = 0x80105013
SNDCTL_DSP_MAPOUTBUF = 0x80105014
SNDCTL_DSP_NONBLOCK = 0x500e
SNDCTL_DSP_POST = 0x5008
SNDCTL_DSP_PROFILE = 0x40045017
SNDCTL_DSP_RESET = 0x5000
SNDCTL_DSP_SAMPLESIZE = 0xc0045005
SNDCTL_DSP_SETDUPLEX = 0x5016
SNDCTL_DSP_SETFMT = 0xc0045005
SNDCTL_DSP_SETFRAGMENT = 0xc004500a
SNDCTL_DSP_SETSPDIF = 0x40045042
SNDCTL_DSP_SETSYNCRO = 0x5015
SNDCTL_DSP_SETTRIGGER = 0x40045010
SNDCTL_DSP_SPEED = 0xc0045002
SNDCTL_DSP_STEREO = 0xc0045003
SNDCTL_DSP_SUBDIVIDE = 0xc0045009
SNDCTL_DSP_SYNC = 0x5001
SNDCTL_FM_4OP_ENABLE = 0x4004510f
SNDCTL_FM_LOAD_INSTR = 0x40285107
SNDCTL_MIDI_INFO = 0xc074510c
SNDCTL_MIDI_MPUCMD = 0xc0216d02
SNDCTL_MIDI_MPUMODE = 0xc0046d01
SNDCTL_MIDI_PRETIME = 0xc0046d00
SNDCTL_SEQ_CTRLRATE = 0xc0045103
SNDCTL_SEQ_GETINCOUNT = 0x80045105
SNDCTL_SEQ_GETOUTCOUNT = 0x80045104
SNDCTL_SEQ_GETTIME = 0x80045113
SNDCTL_SEQ_NRMIDIS = 0x8004510b
SNDCTL_SEQ_NRSYNTHS = 0x8004510a
SNDCTL_SEQ_OUTOFBAND = 0x40085112
SNDCTL_SEQ_PANIC = 0x5111
SNDCTL_SEQ_PERCMODE = 0x40045106
SNDCTL_SEQ_RESET = 0x5100
SNDCTL_SEQ_RESETSAMPLES = 0x40045109
SNDCTL_SEQ_SYNC = 0x5101
SNDCTL_SEQ_TESTMIDI = 0x40045108
SNDCTL_SEQ_THRESHOLD = 0x4004510d
SNDCTL_SYNTH_CONTROL = 0xcfa45115
SNDCTL_SYNTH_ID = 0xc08c5114
SNDCTL_SYNTH_INFO = 0xc08c5102
SNDCTL_SYNTH_MEMAVL = 0xc004510e
SNDCTL_SYNTH_REMOVESAMPLE = 0xc00c5116
SNDCTL_TMR_CONTINUE = 0x5404
SNDCTL_TMR_METRONOME = 0x40045407
SNDCTL_TMR_SELECT = 0x40045408
SNDCTL_TMR_SOURCE = 0xc0045406
SNDCTL_TMR_START = 0x5402
SNDCTL_TMR_STOP = 0x5403
SNDCTL_TMR_TEMPO = 0xc0045405
SNDCTL_TMR_TIMEBASE = 0xc0045401
SOUND_MIXER_VOLUME = 0
SOUND_MIXER_BASS = 1
SOUND_MIXER_TREBLE = 2
SOUND_MIXER_SYNTH = 3
SOUND_MIXER_PCM = 4
SOUND_MIXER_SPEAKER = 5
SOUND_MIXER_LINE = 6
SOUND_MIXER_MIC = 7
SOUND_MIXER_CD = 8
SOUND_MIXER_IMIX = 9
SOUND_MIXER_ALTPCM = 10
SOUND_MIXER_RECLEV = 11
SOUND_MIXER_IGAIN = 12
SOUND_MIXER_OGAIN = 13
SOUND_MIXER_LINE1 = 14
SOUND_MIXER_LINE2 = 15
SOUND_MIXER_LINE3 = 16
SOUND_MIXER_DIGITAL1 = 17
SOUND_MIXER_DIGITAL2 = 18
SOUND_MIXER_DIGITAL3 = 19
SOUND_MIXER_PHONEIN = 20
SOUND_MIXER_PHONEOUT = 21
SOUND_MIXER_VIDEO = 22
SOUND_MIXER_RADIO = 23
SOUND_MIXER_MONITOR = 24
SOUND_MIXER_NRDEVICES = 25

control_labels = ['Vol  ', 'Bass ', 'Trebl', 'Synth', 'Pcm  ', 'Spkr ', 'Line ', 'Mic  ', 'CD   ',
                  'Mix  ', 'Pcm2 ', 'Rec  ', 'IGain', 'OGain', 'Line1', 'Line2', 'Line3',
                  'Digital1', 'Digital2', 'Digital3', 'PhoneIn', 'PhoneOut', 'Video', 'Radio',
                  'Monitor']
control_names = ['vol', 'bass', 'treble', 'synth', 'pcm', 'speaker', 'line', 'mic', 'cd', 'mix',
                 'pcm2', 'rec', 'igain', 'ogain', 'line1', 'line2', 'line3', 'dig1', 'dig2', 'dig3',
                 'phin', 'phout', 'video', 'radio', 'monitor']

# soundcard.h's mixer requests (_IOR / _IOWR on 'M')
_MIXER_READ_BASE = 0x80044d00
_MIXER_WRITE_BASE = 0xc0044d00
_MIXER_READ_RECSRC = 0x80044dff
_MIXER_READ_DEVMASK = 0x80044dfe
_MIXER_READ_RECMASK = 0x80044dfd
_MIXER_READ_STEREODEVS = 0x80044dfb
_MIXER_WRITE_RECSRC = 0xc0044dff


def _ioctl(fd, request, value=0):
    # an ioctl on an int, as the C module's: the value the driver leaves
    # (OSError from errno, as PyErr_SetFromErrno)
    import fcntl
    buf = bytearray(_struct.pack("i", value))
    fcntl.ioctl(fd, request, buf, True)
    return _struct.unpack("i", bytes(buf))[0]


def _ioctl_buf(fd, request, size):
    import fcntl
    buf = bytearray(size)
    fcntl.ioctl(fd, request, buf, True)
    return bytes(buf)


class oss_audio_device:
    """An open OSS audio device (ossaudiodev.open())."""

    def __init__(self, fd, devicename, mode, afmts):
        self._fd = fd
        self._name = devicename
        self._mode = mode
        self._afmts = afmts
        self._icount = 0
        self._ocount = 0

    def __repr__(self):
        return "<ossaudiodev.oss_audio_device object at " + hex(id(self)) + ">"

    def _check(self):
        if self._fd < 0:
            raise ValueError("Operation on closed OSS device.")

    @property
    def closed(self):
        return self._fd == -1

    @property
    def name(self):
        return self._name

    @property
    def mode(self):
        return {_os.O_RDONLY: "r", _os.O_WRONLY: "w", _os.O_RDWR: "rw"}.get(self._mode, "rw")

    def fileno(self):
        self._check()
        return self._fd

    def close(self):
        if self._fd >= 0:
            _os.close(self._fd)
        self._fd = -1

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, *args):
        self.close()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def nonblock(self):
        self._check()
        import fcntl
        fcntl.ioctl(self._fd, SNDCTL_DSP_NONBLOCK, 0)

    def setfmt(self, fmt):
        self._check()
        return _ioctl(self._fd, SNDCTL_DSP_SETFMT, fmt)

    def getfmts(self):
        self._check()
        return _ioctl(self._fd, SNDCTL_DSP_GETFMTS, 0)

    def channels(self, nchannels):
        self._check()
        return _ioctl(self._fd, SNDCTL_DSP_CHANNELS, nchannels)

    def speed(self, rate):
        self._check()
        return _ioctl(self._fd, SNDCTL_DSP_SPEED, rate)

    def _cmd(self, request):
        self._check()
        import fcntl
        fcntl.ioctl(self._fd, request, 0)

    def sync(self):
        self._cmd(SNDCTL_DSP_SYNC)

    def reset(self):
        self._cmd(SNDCTL_DSP_RESET)

    def post(self):
        self._cmd(SNDCTL_DSP_POST)

    flush = sync

    def read(self, size):
        self._check()
        data = _os.read(self._fd, size)
        self._icount += len(data)
        return data

    def write(self, data):
        self._check()
        n = _os.write(self._fd, data)
        self._ocount += n
        return n

    def writeall(self, data):
        self._check()
        import select
        view = memoryview(data).cast("B")
        while len(view):
            select.select([], [self._fd], [])
            n = _os.write(self._fd, view)
            self._ocount += n
            view = view[n:]
        return None

    def setparameters(self, fmt, channels, rate, strict=False):
        self._check()
        got = _ioctl(self._fd, SNDCTL_DSP_SETFMT, fmt)
        if strict and got != fmt:
            raise OSSAudioError(0, "unable to set requested format (wanted %d, got %d)" % (fmt, got))
        gotc = _ioctl(self._fd, SNDCTL_DSP_CHANNELS, channels)
        if strict and gotc != channels:
            raise OSSAudioError(0, "unable to set requested channels (wanted %d, got %d)" % (channels, gotc))
        gotr = _ioctl(self._fd, SNDCTL_DSP_SPEED, rate)
        if strict and gotr != rate:
            raise OSSAudioError(0, "unable to set requested rate (wanted %d, got %d)" % (rate, gotr))
        return (got, gotc, gotr)

    def _ssize(self):
        fmt = _ioctl(self._fd, SNDCTL_DSP_SETFMT, AFMT_QUERY)
        nchannels = _ioctl(self._fd, SNDCTL_DSP_CHANNELS, 0)
        if fmt in (AFMT_U8, AFMT_S8):
            size = 1
        elif fmt in (AFMT_U16_LE, AFMT_U16_BE, AFMT_S16_LE, AFMT_S16_BE):
            size = 2
        else:
            size = 0
        return nchannels, size

    def _space(self, request):
        b = _ioctl_buf(self._fd, request, 16)
        return _struct.unpack("iiii", b)   # fragments, fragstotal, fragsize, bytes

    def bufsize(self):
        self._check()
        nchannels, ssize = self._ssize()
        fragments, fragstotal, fragsize, nbytes = self._space(SNDCTL_DSP_GETOSPACE)
        return (fragstotal * fragsize) // (nchannels * ssize) if nchannels and ssize else 0

    def obufcount(self):
        self._check()
        nchannels, ssize = self._ssize()
        fragments, fragstotal, fragsize, nbytes = self._space(SNDCTL_DSP_GETOSPACE)
        return (fragstotal * fragsize - nbytes) // (nchannels * ssize) if nchannels and ssize else 0

    def obuffree(self):
        self._check()
        nchannels, ssize = self._ssize()
        fragments, fragstotal, fragsize, nbytes = self._space(SNDCTL_DSP_GETOSPACE)
        return nbytes // (nchannels * ssize) if nchannels and ssize else 0

    def getptr(self):
        self._check()
        req = SNDCTL_DSP_GETIPTR if self._mode == _os.O_RDONLY else SNDCTL_DSP_GETOPTR
        return _struct.unpack("iii", _ioctl_buf(self._fd, req, 12))


class oss_mixer_device:
    """An open OSS mixer device (ossaudiodev.openmixer())."""

    def __init__(self, fd):
        self._fd = fd

    def __repr__(self):
        return "<ossaudiodev.oss_mixer_device object at " + hex(id(self)) + ">"

    def _check(self):
        if self._fd < 0:
            raise ValueError("Operation on closed OSS device.")

    def fileno(self):
        self._check()
        return self._fd

    def close(self):
        if self._fd >= 0:
            _os.close(self._fd)
        self._fd = -1

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, *args):
        self.close()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def controls(self):
        self._check()
        return _ioctl(self._fd, _MIXER_READ_DEVMASK, 0)

    def stereocontrols(self):
        self._check()
        return _ioctl(self._fd, _MIXER_READ_STEREODEVS, 0)

    def reccontrols(self):
        self._check()
        return _ioctl(self._fd, _MIXER_READ_RECMASK, 0)

    def get(self, channel):
        self._check()
        if channel < 0 or channel > SOUND_MIXER_NRDEVICES:
            raise OSSAudioError(0, "Invalid mixer channel specified.")
        volume = _ioctl(self._fd, _MIXER_READ_BASE | channel, 0)
        return (volume & 0xff, (volume & 0xff00) >> 8)

    def set(self, channel, levels):
        self._check()
        left, right = levels
        if channel < 0 or channel > SOUND_MIXER_NRDEVICES:
            raise OSSAudioError(0, "Invalid mixer channel specified.")
        if left < 0 or left > 100 or right < 0 or right > 100:
            raise OSSAudioError(0, "Volumes must be between 0 and 100.")
        volume = (right << 8) | left
        volume = _ioctl(self._fd, _MIXER_WRITE_BASE | channel, volume)
        return (volume & 0xff, (volume & 0xff00) >> 8)

    def get_recsrc(self):
        self._check()
        return _ioctl(self._fd, _MIXER_READ_RECSRC, 0)

    def set_recsrc(self, bitmask):
        self._check()
        return _ioctl(self._fd, _MIXER_WRITE_RECSRC, bitmask)


def open(*args):
    """open([device,] mode) -> an OSS audio device ($AUDIODEV or /dev/dsp)."""
    if len(args) == 1:
        basedev, mode = None, args[0]
    elif len(args) == 2:
        basedev, mode = args
    else:
        raise TypeError("open expected at most 2 arguments, got %d" % len(args) if args else
                        "open expected at least 1 argument, got 0")
    if not isinstance(mode, str) or (basedev is not None and not isinstance(basedev, str)):
        raise TypeError("open() argument must be str")
    if mode == "r":
        imode = _os.O_RDONLY
    elif mode == "w":
        imode = _os.O_WRONLY
    elif mode == "rw":
        imode = _os.O_RDWR
    else:
        raise OSSAudioError("mode must be 'r', 'w', or 'rw'")
    if basedev is None:
        basedev = _os.environ.get("AUDIODEV") or "/dev/dsp"
    # Open with O_NONBLOCK to avoid hanging on devices that only allow one
    # open at a time, then put it back in blocking mode (the C module's way)
    fd = _os.open(basedev, imode | getattr(_os, "O_NONBLOCK", 0))
    try:
        import fcntl
        try:
            fcntl.fcntl(fd, fcntl.F_SETFL, 0)
            afmts = _ioctl(fd, SNDCTL_DSP_GETFMTS, 0)
        except OSError as e:
            raise OSError(e.errno, e.strerror, basedev) from None
    except BaseException:
        _os.close(fd)
        raise
    return oss_audio_device(fd, basedev, imode, afmts)


def openmixer(device=None):
    """openmixer([device]) -> an OSS mixer device ($MIXERDEV or /dev/mixer)."""
    if device is None:
        device = _os.environ.get("MIXERDEV") or "/dev/mixer"
    fd = _os.open(device, _os.O_RDWR)
    return oss_mixer_device(fd)
