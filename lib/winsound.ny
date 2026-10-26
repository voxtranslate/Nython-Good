# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/winsound.ny - Python's winsound module (round 87): the Windows sound
# player and the speaker, over src/builtins/nywin.cpp (PlaySound from winmm,
# loaded at run time). Windows only: elsewhere `import winsound` raises
# ModuleNotFoundError, as CPython's.
#
#     import winsound
#     winsound.Beep(440, 200)                              # Hz, ms
#     winsound.PlaySound("SystemExit", winsound.SND_ALIAS)
#     winsound.PlaySound(wav_bytes, winsound.SND_MEMORY)   # a WAV file's bytes
#     winsound.MessageBeep(winsound.MB_ICONHAND)
#
# Beep, PlaySound (str, None, or bytes-like with SND_MEMORY - not with
# SND_ASYNC: RuntimeError), MessageBeep; the SND_* and MB_* constants.
# CPython's errors: ValueError for a frequency outside 37..32767,
# RuntimeError("Failed to play sound").

import sys

if sys.platform != "win32":
    raise ModuleNotFoundError("No module named 'winsound'", name="winsound")


def _load():
    g = globals()
    for name, value in _winsound_consts():
        g[name] = value


_load()


def Beep(frequency, duration):
    """A wrapper around the Windows Beep API."""
    if not isinstance(frequency, int) or not isinstance(duration, int):
        raise TypeError("'%s' object cannot be interpreted as an integer"
                        % type(duration if isinstance(frequency, int) else frequency).__name__)
    if frequency < 37 or frequency > 32767:
        raise ValueError("frequency must be in 37 thru 32767")
    _winsound_beep(frequency, duration)


def PlaySound(sound, flags):
    """A wrapper around the Windows PlaySound API."""
    if flags & SND_MEMORY:
        if flags & SND_ASYNC:
            # sound is likely to be destroyed before the sound is played
            raise RuntimeError("Cannot play asynchronously from memory")
        if isinstance(sound, str):
            raise TypeError("a bytes-like object is required, not 'str'")
        if sound is not None:
            sound = bytes(memoryview(sound))
    elif sound is not None and not isinstance(sound, str):
        raise TypeError("'sound' must be str or None, not '%s'" % type(sound).__name__)
    _winsound_play(sound, flags)


def MessageBeep(type=MB_OK):
    """Call Windows MessageBeep(x)."""
    _winsound_message_beep(type)
