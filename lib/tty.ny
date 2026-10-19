# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/tty.ny - Python's tty module (round 83, CPython 3.12's code): raw and
# cbreak terminal modes over termios. POSIX only (termios is).
#
#     import tty, termios, sys
#     old = tty.setraw(sys.stdin.fileno())     # returns the previous mode (3.12)
#     ...
#     termios.tcsetattr(fd, termios.TCSAFLUSH, old)
#
# cfmakeraw(mode), cfmakecbreak(mode)   change a tcgetattr() list in place
# setraw(fd, when=TCSAFLUSH), setcbreak(fd, when=TCSAFLUSH)
# IFLAG OFLAG CFLAG LFLAG ISPEED OSPEED CC   indexes into the mode list
# and everything termios exports (`from termios import *`, as CPython's).
#
# Not here: nothing.

from termios import *

__all__ = ["cfmakeraw", "cfmakecbreak", "setraw", "setcbreak"]

# Indices for termios list.
IFLAG = 0
OFLAG = 1
CFLAG = 2
LFLAG = 3
ISPEED = 4
OSPEED = 5
CC = 6


def cfmakeraw(mode):
    """Make termios mode raw."""
    # Clear all POSIX.1-2017 input mode flags.
    mode[IFLAG] &= ~(IGNBRK | BRKINT | IGNPAR | PARMRK | INPCK | ISTRIP |
                     INLCR | IGNCR | ICRNL | IXON | IXANY | IXOFF)
    # Do not post-process output.
    mode[OFLAG] &= ~OPOST
    # Disable parity generation and detection; clear character size mask;
    # let character size be 8 bits.
    mode[CFLAG] &= ~(PARENB | CSIZE)
    mode[CFLAG] |= CS8
    # Clear all POSIX.1-2017 local mode flags.
    mode[LFLAG] &= ~(ECHO | ECHOE | ECHOK | ECHONL | ICANON |
                     IEXTEN | ISIG | NOFLSH | TOSTOP)
    # POSIX.1-2017, 11.1.7 Non-Canonical Mode Input Processing,
    # Case B: MIN>0, TIME=0
    mode[CC] = list(mode[CC])
    mode[CC][VMIN] = 1
    mode[CC][VTIME] = 0


def cfmakecbreak(mode):
    """Make termios mode cbreak."""
    # Do not echo characters; disable canonical input.
    mode[LFLAG] &= ~(ECHO | ICANON)
    # POSIX.1-2017, 11.1.7 Non-Canonical Mode Input Processing,
    # Case B: MIN>0, TIME=0
    mode[CC] = list(mode[CC])
    mode[CC][VMIN] = 1
    mode[CC][VTIME] = 0


def setraw(fd, when=TCSAFLUSH):
    """Put terminal into raw mode."""
    var mode = tcgetattr(fd)
    var new = list(mode)
    cfmakeraw(new)
    tcsetattr(fd, when, new)
    return mode


def setcbreak(fd, when=TCSAFLUSH):
    """Put terminal into cbreak mode."""
    var mode = tcgetattr(fd)
    var new = list(mode)
    cfmakecbreak(new)
    tcsetattr(fd, when, new)
    return mode
