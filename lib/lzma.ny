# nython: module    (import it by name: it runs in a module scope of its own)
# lib/lzma.ny - Python's lzma module (round 83, CPython 3.12's code): the
# xz and legacy .lzma formats.
#
#     import lzma
#     data = lzma.compress(b"text", preset=6)                 # .xz, CRC64
#     lzma.decompress(data)
#     with lzma.open("file.xz", "rt") as f: f.read()
#     c = lzma.LZMACompressor(format=lzma.FORMAT_RAW,
#                             filters=[{"id": lzma.FILTER_DELTA, "dist": 4},
#                                      {"id": lzma.FILTER_LZMA2, "preset": 9}])
#
# liblzma (XZ Utils) is loaded when a program first needs it - dlopen /
# LoadLibrary, nothing at build or link time, as builtins/tls.cpp loads
# OpenSSL (NY_LIBLZMA names a library to try first): with it, everything of
# CPython's module - LZMACompressor/LZMADecompressor (FORMAT_AUTO, XZ,
# ALONE, RAW; every check; filter chains of LZMA1/LZMA2 with all their
# options, delta, the BCJ filters), LZMAFile, open, compress, decompress,
# is_check_supported, LZMAError, the constants,
# _encode_filter_properties/_decode_filter_properties (zipfile's LZMA).
#
# Without liblzma (innovation): a native LZMA/LZMA2 decoder
# (builtins/nylzma.cpp, after the LZMA SDK's specification) still reads
# .xz streams (LZMA2 with the delta filter, CRC32/CRC64/SHA-256 checks,
# concatenated streams and padding) and .lzma files, so LZMADecompressor,
# decompress(), LZMAFile and open() in read mode work everywhere; making a
# compressor then raises LZMAError naming the missing library.
#
# Not here: the fallback decoder does not run the BCJ filters (those streams
# need liblzma).

"""Interface to the liblzma compression library.

This module provides a class for reading and writing compressed files,
classes for incremental (de)compression, and convenience functions for
one-shot (de)compression.

These classes and functions support both the XZ and legacy LZMA
container formats, as well as raw compressed data streams.
"""

__all__ = [
    "CHECK_NONE", "CHECK_CRC32", "CHECK_CRC64", "CHECK_SHA256",
    "CHECK_ID_MAX", "CHECK_UNKNOWN",
    "FILTER_LZMA1", "FILTER_LZMA2", "FILTER_DELTA", "FILTER_X86", "FILTER_IA64",
    "FILTER_ARM", "FILTER_ARMTHUMB", "FILTER_POWERPC", "FILTER_SPARC",
    "FORMAT_AUTO", "FORMAT_XZ", "FORMAT_ALONE", "FORMAT_RAW",
    "MF_HC3", "MF_HC4", "MF_BT2", "MF_BT3", "MF_BT4",
    "MODE_FAST", "MODE_NORMAL", "PRESET_DEFAULT", "PRESET_EXTREME",

    "LZMACompressor", "LZMADecompressor", "LZMAFile", "LZMAError",
    "open", "compress", "decompress", "is_check_supported",
]

import builtins
import io
import os


# ── the codec (_lzma in CPython; builtins/nylzma.cpp here) ──────────────────
CHECK_NONE = 0
CHECK_CRC32 = 1
CHECK_CRC64 = 4
CHECK_SHA256 = 10
CHECK_ID_MAX = 15
CHECK_UNKNOWN = 16
FILTER_LZMA1 = 0x4000000000000001
FILTER_LZMA2 = 0x21
FILTER_DELTA = 0x03
FILTER_X86 = 0x04
FILTER_POWERPC = 0x05
FILTER_IA64 = 0x06
FILTER_ARM = 0x07
FILTER_ARMTHUMB = 0x08
FILTER_SPARC = 0x09
FORMAT_AUTO = 0
FORMAT_XZ = 1
FORMAT_ALONE = 2
FORMAT_RAW = 3
MF_HC3 = 0x03
MF_HC4 = 0x04
MF_BT2 = 0x12
MF_BT3 = 0x13
MF_BT4 = 0x14
MODE_FAST = 1
MODE_NORMAL = 2
PRESET_DEFAULT = 6
PRESET_EXTREME = 0x80000000

_BCJ = (FILTER_X86, FILTER_POWERPC, FILTER_IA64, FILTER_ARM, FILTER_ARMTHUMB, FILTER_SPARC)


class LZMAError(Exception):
    """Call to liblzma failed."""


LZMAError.__module__ = "_lzma"


def _lzerr(e):
    var m = str(e)
    if m.startswith("\x01lzma "):
        return LZMAError(m[6:])
    return e


def _int(v, what):
    if isinstance(v, bool) or not isinstance(v, int):
        raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")
    return v


def _spec(f):
    # parse_filter_spec: a dict -> the native's list
    if not hasattr(f, "keys") or not hasattr(f, "__getitem__"):
        raise TypeError("Filter specifier must be a dict or dict-like object")
    if "id" not in f:
        raise ValueError("Filter specifier must have an \"id\" entry")
    var fid = _int(f["id"], "id")
    if fid in (FILTER_LZMA1, FILTER_LZMA2):
        var names = ("preset", "dict_size", "lc", "lp", "pb", "mode", "nice_len", "mf", "depth")
        for k in f.keys():
            if k != "id" and k not in names:
                raise ValueError("Invalid filter specifier for LZMA filter")
        var out = [fid]
        for k in names:
            var v = f.get(k, None)
            out.append(-1 if v is None else _int(v, k))
        return out
    if fid == FILTER_DELTA:
        for k in f.keys():
            if k not in ("id", "dist"):
                raise ValueError("Invalid filter specifier for delta filter")
        return [fid, _int(f.get("dist", 1), "dist")]
    if fid in _BCJ:
        for k in f.keys():
            if k not in ("id", "start_offset"):
                raise ValueError("Invalid filter specifier for BCJ filter")
        return [fid, _int(f.get("start_offset", 0), "start_offset")]
    raise ValueError("Invalid filter ID: " + str(fid))


def _chain(filters):
    var specs = [_spec(f) for f in filters]
    if len(specs) > 4:
        raise ValueError("Too many filters - liblzma supports a maximum of 4")
    return specs


def _bytes_like(data):
    # any bytes-like object (round 84: memoryview, array, mmap ...)
    if isinstance(data, bytes):
        return data
    return bytes(_ny_bytes_like(data))


class LZMACompressor:
    """LZMACompressor(format=FORMAT_XZ, check=-1, preset=None, filters=None)

    Create a compressor object for compressing data incrementally."""

    def __init__(self, format=FORMAT_XZ, check=-1, preset=None, filters=None):
        if format != FORMAT_XZ and check != -1 and check != CHECK_NONE:
            raise ValueError("Integrity checks are only supported by FORMAT_XZ")
        if preset is not None and filters is not None:
            raise ValueError("Cannot specify both preset and filter chain")
        if format == FORMAT_RAW and filters is None:
            raise ValueError("Must specify filters for FORMAT_RAW")
        if format not in (FORMAT_XZ, FORMAT_ALONE, FORMAT_RAW):
            raise ValueError("Invalid container format: " + str(format))
        var specs = None if filters is None else _chain(filters)
        try:
            self._h = _lzma_cnew(format, check, PRESET_DEFAULT if preset is None else _int(preset, "preset"), specs)
        except ValueError as e:
            raise _lzerr(e) from None

    def compress(self, data, /):
        """Provide data to the compressor object."""
        try:
            return _lzma_compress(self._h, _bytes_like(data))
        except ValueError as e:
            raise _lzerr(e) from None

    def flush(self):
        """Finish the compression process."""
        try:
            return _lzma_flush(self._h)
        except ValueError as e:
            raise _lzerr(e) from None

    def __reduce__(self):
        raise TypeError("cannot pickle 'LZMACompressor' object")

    def __del__(self):
        try:
            _lzma_free(self._h)
        except Exception:
            pass


class LZMADecompressor:
    """LZMADecompressor(format=FORMAT_AUTO, memlimit=None, filters=None)

    Create a decompressor object for decompressing data incrementally."""

    def __init__(self, format=FORMAT_AUTO, memlimit=None, filters=None):
        if memlimit is not None and format == FORMAT_RAW:
            raise ValueError("Cannot specify memory limit with FORMAT_RAW")
        if format == FORMAT_RAW and filters is None:
            raise ValueError("Must specify filters for FORMAT_RAW")
        if format != FORMAT_RAW and filters is not None:
            raise ValueError("Cannot specify filters except with FORMAT_RAW")
        if format not in (FORMAT_AUTO, FORMAT_XZ, FORMAT_ALONE, FORMAT_RAW):
            raise ValueError("Invalid container format: " + str(format))
        var specs = None if filters is None else _chain(filters)
        try:
            self._h = _lzma_dnew(format, memlimit, specs)
        except ValueError as e:
            raise _lzerr(e) from None
        self._check = CHECK_NONE if format in (FORMAT_ALONE, FORMAT_RAW) else CHECK_UNKNOWN
        self._eof = False
        self._unused = b""
        self._needs_input = True

    def decompress(self, data, max_length=-1):
        """Decompress *data*, returning uncompressed data as bytes."""
        var r = None
        try:
            r = _lzma_decompress(self._h, _bytes_like(data), max_length)
        except ValueError as e:
            raise _lzerr(e) from None
        self._eof = r[1]
        self._unused = r[2]
        self._needs_input = r[3]
        self._check = r[4]
        return r[0]

    @property
    def check(self):
        """ID of the integrity check used by the input stream."""
        return self._check

    @property
    def eof(self):
        """True if the end-of-stream marker has been reached."""
        return self._eof

    @property
    def unused_data(self):
        """Data found after the end of the compressed stream."""
        return self._unused

    @property
    def needs_input(self):
        """True if more input is needed before more decompressed data can be produced."""
        return self._needs_input

    def __reduce__(self):
        raise TypeError("cannot pickle 'LZMADecompressor' object")

    def __del__(self):
        try:
            _lzma_free(self._h)
        except Exception:
            pass


LZMACompressor.__module__ = "_lzma"
LZMADecompressor.__module__ = "_lzma"


def is_check_supported(check_id, /):
    """Test whether the given integrity check is supported."""
    return _lzma_check_supported(_int(check_id, "check_id"))


def _encode_filter_properties(filter, /):
    """Return a bytes object encoding the options (properties) of the filter specified by *filter* (a dict)."""
    try:
        return _lzma_encode_props(_spec(filter))
    except ValueError as e:
        raise _lzerr(e) from None


def _decode_filter_properties(filter_id, encoded_props, /):
    """Return a bytes object encoding the options (properties) of the filter specified by *filter* (a dict)."""
    var r = None
    try:
        r = _lzma_decode_props(_int(filter_id, "filter_id"), _bytes_like(encoded_props))
    except ValueError as e:
        raise _lzerr(e) from None
    var d = {"id": r[0]}
    if r[0] == FILTER_LZMA1:
        d["lc"] = r[1]
        d["lp"] = r[2]
        d["pb"] = r[3]
        d["dict_size"] = r[4]
    elif r[0] == FILTER_LZMA2:
        d["dict_size"] = r[1]
    elif r[0] == FILTER_DELTA:
        d["dist"] = r[1]
    elif len(r) > 1:
        d["start_offset"] = r[1]
    return d

import _compression


_MODE_CLOSED   = 0
_MODE_READ     = 1
# Value 2 no longer used
_MODE_WRITE    = 3


class LZMAFile(_compression.BaseStream):

    """A file object providing transparent LZMA (de)compression.

    An LZMAFile can act as a wrapper for an existing file object, or
    refer directly to a named file on disk.

    Note that LZMAFile provides a *binary* file interface - data read
    is returned as bytes, and data to be written must be given as bytes.
    """

    def __init__(self, filename=None, mode="r", *,
                 format=None, check=-1, preset=None, filters=None):
        """Open an LZMA-compressed file in binary mode.

        filename can be either an actual file name (given as a str,
        bytes, or PathLike object), in which case the named file is
        opened, or it can be an existing file object to read from or
        write to.

        mode can be "r" for reading (default), "w" for (over)writing,
        "x" for creating exclusively, or "a" for appending. These can
        equivalently be given as "rb", "wb", "xb" and "ab" respectively.

        format specifies the container format to use for the file.
        If mode is "r", this defaults to FORMAT_AUTO. Otherwise, the
        default is FORMAT_XZ.

        check specifies the integrity check to use. This argument can
        only be used when opening a file for writing. For FORMAT_XZ,
        the default is CHECK_CRC64. FORMAT_ALONE and FORMAT_RAW do not
        support integrity checks - for these formats, check must be
        omitted, or be CHECK_NONE.

        When opening a file for reading, the *preset* argument is not
        meaningful, and should be omitted. The *filters* argument should
        also be omitted, except when format is FORMAT_RAW (in which case
        it is required).

        When opening a file for writing, the settings used by the
        compressor can be specified either as a preset compression
        level (with the *preset* argument), or in detail as a custom
        filter chain (with the *filters* argument). For FORMAT_XZ and
        FORMAT_ALONE, the default is to use the PRESET_DEFAULT preset
        level. For FORMAT_RAW, the caller must always specify a filter
        chain; the raw compressor does not support preset compression
        levels.

        preset (if provided) should be an integer in the range 0-9,
        optionally OR-ed with the constant PRESET_EXTREME.

        filters (if provided) should be a sequence of dicts. Each dict
        should have an entry for "id" indicating ID of the filter, plus
        additional entries for options to the filter.
        """
        self._fp = None
        self._closefp = False
        self._mode = _MODE_CLOSED

        if mode in ("r", "rb"):
            if check != -1:
                raise ValueError("Cannot specify an integrity check "
                                 "when opening a file for reading")
            if preset is not None:
                raise ValueError("Cannot specify a preset compression "
                                 "level when opening a file for reading")
            if format is None:
                format = FORMAT_AUTO
            mode_code = _MODE_READ
        elif mode in ("w", "wb", "a", "ab", "x", "xb"):
            if format is None:
                format = FORMAT_XZ
            mode_code = _MODE_WRITE
            self._compressor = LZMACompressor(format=format, check=check,
                                              preset=preset, filters=filters)
            self._pos = 0
        else:
            raise ValueError("Invalid mode: {!r}".format(mode))

        if isinstance(filename, (str, bytes, os.PathLike)):
            if "b" not in mode:
                mode += "b"
            self._fp = builtins.open(filename, mode)
            self._closefp = True
            self._mode = mode_code
        elif hasattr(filename, "read") or hasattr(filename, "write"):
            self._fp = filename
            self._mode = mode_code
        else:
            raise TypeError("filename must be a str, bytes, file or PathLike object")

        if self._mode == _MODE_READ:
            raw = _compression.DecompressReader(self._fp, LZMADecompressor,
                trailing_error=LZMAError, format=format, filters=filters)
            self._buffer = _compression._BufferedReader(raw)

    def close(self):
        """Flush and close the file.

        May be called more than once without error. Once the file is
        closed, any other operation on it will raise a ValueError.
        """
        if self._mode == _MODE_CLOSED:
            return
        try:
            if self._mode == _MODE_READ:
                self._buffer.close()
                self._buffer = None
            elif self._mode == _MODE_WRITE:
                self._fp.write(self._compressor.flush())
                self._compressor = None
        finally:
            try:
                if self._closefp:
                    self._fp.close()
            finally:
                self._fp = None
                self._closefp = False
                self._mode = _MODE_CLOSED

    @property
    def closed(self):
        """True if this file is closed."""
        return self._mode == _MODE_CLOSED

    def fileno(self):
        """Return the file descriptor for the underlying file."""
        self._check_not_closed()
        return self._fp.fileno()

    def seekable(self):
        """Return whether the file supports seeking."""
        return self.readable() and self._buffer.seekable()

    def readable(self):
        """Return whether the file was opened for reading."""
        self._check_not_closed()
        return self._mode == _MODE_READ

    def writable(self):
        """Return whether the file was opened for writing."""
        self._check_not_closed()
        return self._mode == _MODE_WRITE

    def peek(self, size=-1):
        """Return buffered data without advancing the file position.

        Always returns at least one byte of data, unless at EOF.
        The exact number of bytes returned is unspecified.
        """
        self._check_can_read()
        # Relies on the undocumented fact that BufferedReader.peek() always
        # returns at least one byte (except at EOF)
        return self._buffer.peek(size)

    def read(self, size=-1):
        """Read up to size uncompressed bytes from the file.

        If size is negative or omitted, read until EOF is reached.
        Returns b"" if the file is already at EOF.
        """
        self._check_can_read()
        return self._buffer.read(size)

    def read1(self, size=-1):
        """Read up to size uncompressed bytes, while trying to avoid
        making multiple reads from the underlying stream. Reads up to a
        buffer's worth of data if size is negative.

        Returns b"" if the file is at EOF.
        """
        self._check_can_read()
        if size < 0:
            size = io.DEFAULT_BUFFER_SIZE
        return self._buffer.read1(size)

    def readline(self, size=-1):
        """Read a line of uncompressed bytes from the file.

        The terminating newline (if present) is retained. If size is
        non-negative, no more than size bytes will be read (in which
        case the line may be incomplete). Returns b'' if already at EOF.
        """
        self._check_can_read()
        return self._buffer.readline(size)

    def write(self, data):
        """Write a bytes object to the file.

        Returns the number of uncompressed bytes written, which is
        always the length of data in bytes. Note that due to buffering,
        the file on disk may not reflect the data written until close()
        is called.
        """
        self._check_can_write()
        if isinstance(data, (bytes, bytearray)):
            length = len(data)
        else:
            # accept any data that supports the buffer protocol
            data = memoryview(data)
            length = data.nbytes

        compressed = self._compressor.compress(data)
        self._fp.write(compressed)
        self._pos += length
        return length

    def seek(self, offset, whence=io.SEEK_SET):
        """Change the file position.

        The new position is specified by offset, relative to the
        position indicated by whence. Possible values for whence are:

            0: start of stream (default): offset must not be negative
            1: current stream position
            2: end of stream; offset must not be positive

        Returns the new file position.

        Note that seeking is emulated, so depending on the parameters,
        this operation may be extremely slow.
        """
        self._check_can_seek()
        return self._buffer.seek(offset, whence)

    def tell(self):
        """Return the current file position."""
        self._check_not_closed()
        if self._mode == _MODE_READ:
            return self._buffer.tell()
        return self._pos


def open(filename, mode="rb", *,
         format=None, check=-1, preset=None, filters=None,
         encoding=None, errors=None, newline=None):
    """Open an LZMA-compressed file in binary or text mode.

    filename can be either an actual file name (given as a str, bytes,
    or PathLike object), in which case the named file is opened, or it
    can be an existing file object to read from or write to.

    The mode argument can be "r", "rb" (default), "w", "wb", "x", "xb",
    "a", or "ab" for binary mode, or "rt", "wt", "xt", or "at" for text
    mode.

    The format, check, preset and filters arguments specify the
    compression settings, as for LZMACompressor, LZMADecompressor and
    LZMAFile.

    For binary mode, this function is equivalent to the LZMAFile
    constructor: LZMAFile(filename, mode, ...). In this case, the
    encoding, errors and newline arguments must not be provided.

    For text mode, an LZMAFile object is created, and wrapped in an
    io.TextIOWrapper instance with the specified encoding, error
    handling behavior, and line ending(s).

    """
    if "t" in mode:
        if "b" in mode:
            raise ValueError("Invalid mode: %r" % (mode,))
    else:
        if encoding is not None:
            raise ValueError("Argument 'encoding' not supported in binary mode")
        if errors is not None:
            raise ValueError("Argument 'errors' not supported in binary mode")
        if newline is not None:
            raise ValueError("Argument 'newline' not supported in binary mode")

    lz_mode = mode.replace("t", "")
    binary_file = LZMAFile(filename, lz_mode, format=format, check=check,
                           preset=preset, filters=filters)

    if "t" in mode:
        encoding = io.text_encoding(encoding)
        return io.TextIOWrapper(binary_file, encoding, errors, newline)
    else:
        return binary_file


def compress(data, format=FORMAT_XZ, check=-1, preset=None, filters=None):
    """Compress a block of data.

    Refer to LZMACompressor's docstring for a description of the
    optional arguments *format*, *check*, *preset* and *filters*.

    For incremental compression, use an LZMACompressor instead.
    """
    comp = LZMACompressor(format, check, preset, filters)
    return comp.compress(data) + comp.flush()


def decompress(data, format=FORMAT_AUTO, memlimit=None, filters=None):
    """Decompress a block of data.

    Refer to LZMADecompressor's docstring for a description of the
    optional arguments *format*, *check* and *filters*.

    For incremental decompression, use an LZMADecompressor instead.
    """
    results = []
    while True:
        decomp = LZMADecompressor(format, memlimit, filters)
        try:
            res = decomp.decompress(data)
        except LZMAError:
            if results:
                break  # Leftover data is not a valid LZMA/XZ stream; ignore it.
            else:
                raise  # Error on the first iteration; bail out.
        results.append(res)
        if not decomp.eof:
            raise LZMAError("Compressed data ended before the "
                            "end-of-stream marker was reached")
        data = decomp.unused_data
        if not data:
            break
    return b"".join(results)
