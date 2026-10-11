# nython: module    (import it by name: it runs in a module scope of its own)
# lib/zipfile.ny - Python's zipfile (round 79): read and write ZIP archives
# (PKWARE APPNOTE 6.3), interchangeable with CPython's and Info-ZIP's.
#
#     import zipfile
#     with zipfile.ZipFile("a.zip", "w", zipfile.ZIP_DEFLATED) as z:
#         z.writestr("hello.txt", "hi"); z.write("data.bin")
#     with zipfile.ZipFile("a.zip") as z: z.namelist(); z.read("hello.txt")
#
# ZipFile(file, mode="r"|"w"|"x"|"a", compression, allowZip64, compresslevel,
#   strict_timestamps, metadata_encoding): namelist, infolist, getinfo,
#   read, open (reading: a file object with read/read1/readline/peek/seek/
#   tell, the CRC-32 checked at the end: BadZipFile "Bad CRC-32 for file";
#   writing: open(name, "w", force_zip64=)), extract, extractall (names
#   made safe as CPython does), write, writestr, mkdir, testzip, printdir,
#   comment, close, with; "a" on a file that is not a zip appends an archive
#   to it (self-extracting style). ZIP64: sizes, offsets and member counts
#   past the classic limits (ZIP64_LIMIT, ZIP_FILECOUNT_LIMIT) are written
#   and read with the ZIP64 extra field and end records; LargeZipFile when
#   allowZip64 is false. UTF-8 names (flag 0x800), data descriptors (an
#   unseekable output), archive comments, extra fields kept.
# ZipInfo(filename, date_time), ZipInfo.from_file, is_dir, every field
#   (CRC, compress_size, file_size, external_attr, create_system, ...).
# ZIP_STORED, ZIP_DEFLATED (lib/zlib.ny's raw deflate); is_zipfile;
# Path (zipfile.Path: /, iterdir, open, read_text, read_bytes, is_dir,
# is_file, exists, name, suffix, stem, parent); BadZipFile (BadZipfile),
# LargeZipFile; the command line: nython -m zipfile -l|-t|-e|-c.
#
# Not here: ZIP_BZIP2 and ZIP_LZMA (the constants exist; using them raises
# RuntimeError as CPython does without its bz2/lzma modules), encrypted
# members (reading one raises "File ... is encrypted, password required for
# extraction"; there is no ZipCrypto decryption), multi-disk archives,
# PyZipFile.
import io
import os
import time
import zlib
import struct

__all__ = ["BadZipFile", "BadZipfile", "error", "ZIP_STORED", "ZIP_DEFLATED", "ZIP_BZIP2", "ZIP_LZMA",
           "is_zipfile", "ZipInfo", "ZipFile", "LargeZipFile", "Path"]


class BadZipFile(Exception):
    pass


class LargeZipFile(Exception):
    """Raised when writing a zipfile, the zipfile requires ZIP64 extensions
    and those extensions are disabled."""
    pass


error = BadZipFile
BadZipfile = BadZipFile

ZIP64_LIMIT = (1 << 31) - 1
ZIP_FILECOUNT_LIMIT = (1 << 16) - 1
ZIP_MAX_COMMENT = (1 << 16) - 1

ZIP_STORED = 0
ZIP_DEFLATED = 8
ZIP_BZIP2 = 12
ZIP_LZMA = 14

DEFAULT_VERSION = 20
ZIP64_VERSION = 45
BZIP2_VERSION = 46
LZMA_VERSION = 63
MAX_EXTRACT_VERSION = 63

_builtin_open = open

_EOCD_SIG = b"PK\x05\x06"
_EOCD64_SIG = b"PK\x06\x06"
_EOCD64_LOC_SIG = b"PK\x06\x07"
_CD_SIG = b"PK\x01\x02"
_LOCAL_SIG = b"PK\x03\x04"
_DD_SIG = b"PK\x07\x08"
_SIZE_ENDREC = 22
_SIZE_ENDREC64 = 56
_SIZE_ENDREC64_LOC = 20
_SIZE_CD = 46
_SIZE_LOCAL = 30


def _u16(v):
    return bytes([v & 255, (v >> 8) & 255])


def _u32(v):
    return bytes([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255])


def _u64(v):
    return _u32(v & 0xffffffff) + _u32((v >> 32) & 0xffffffff)


def _le(b, off, n):
    var v = 0
    var i = n - 1
    while i >= 0:
        v = (v << 8) | b[off + i]
        i = i - 1
    return v


def _check_compression(compression):
    if compression == ZIP_STORED or compression == ZIP_DEFLATED:
        return
    if compression == ZIP_BZIP2:
        raise RuntimeError("Compression requires the (missing) bz2 module")
    if compression == ZIP_LZMA:
        raise RuntimeError("Compression requires the (missing) lzma module")
    raise NotImplementedError("That compression method is not supported")


# (what Nython's os lacks: splitdrive, altsep, curdir, pardir)
_ALTSEP = getattr(os, "altsep", none)
_CURDIR = "."
_PARDIR = ".."


def _splitdrive(p):
    if os.name == "nt" and len(p) >= 2 and p[1] == ":":
        return p[:2], p[2:]
    return "", p


def _fspath(p):
    if isinstance(p, str):
        return p
    if isinstance(p, bytes):
        return p.decode("utf-8", "surrogateescape")
    if hasattr(p, "__fspath__"):
        return p.__fspath__()
    return none


# ── ZipInfo ─────────────────────────────────────────────────────────────────
class ZipInfo:
    """Class with attributes describing each file in the ZIP archive."""

    def __init__(self, filename="NoName", date_time=(1980, 1, 1, 0, 0, 0)):
        self.orig_filename = filename
        var null_byte = filename.find(chr(0))
        if null_byte >= 0:
            filename = filename[0:null_byte]
        if os.sep != "/" and os.sep in filename:
            filename = filename.replace(os.sep, "/")
        self.filename = filename
        self.date_time = date_time
        if date_time[0] < 1980:
            raise ValueError("ZIP does not support timestamps before 1980")
        self.compress_type = ZIP_STORED
        self._compresslevel = none
        self.comment = b""
        self.extra = b""
        self.create_system = 0 if os.name == "nt" else 3
        self.create_version = DEFAULT_VERSION
        self.extract_version = DEFAULT_VERSION
        self.reserved = 0
        self.flag_bits = 0
        self.volume = 0
        self.internal_attr = 0
        self.external_attr = 0
        self.compress_size = 0
        self.file_size = 0
        self.header_offset = 0
        self.CRC = 0
        self._end_offset = none

    def __repr__(self):
        var result = ["<" + type(self).__name__ + " filename=" + repr(self.filename)]
        if self.compress_type != ZIP_STORED:
            var names = {0: "stored", 8: "deflated", 12: "bzip2", 14: "lzma"}
            result.append(" compress_type=" + names.get(self.compress_type, str(self.compress_type)))
        var hi = self.external_attr >> 16
        var lo = self.external_attr & 0xFFFF
        if hi:
            result.append(" filemode=" + repr(_filemode(hi)))
        if lo:
            result.append(" external_attr=" + hex(lo))
        var isdir = self.is_dir()
        if not isdir or self.file_size:
            result.append(" file_size=" + repr(self.file_size))
        if (not isdir or self.compress_size) and (self.compress_type != ZIP_STORED or self.file_size != self.compress_size):
            result.append(" compress_size=" + repr(self.compress_size))
        result.append(">")
        return "".join(result)

    def _encoded_name(self):
        try:
            return self.filename.encode("ascii"), self.flag_bits
        except UnicodeEncodeError:
            return self.filename.encode("utf-8"), self.flag_bits | 0x800

    def _dostime(self):
        var dt = self.date_time
        var dosdate = (dt[0] - 1980) << 9 | dt[1] << 5 | dt[2]
        var dostime = dt[3] << 11 | dt[4] << 5 | (dt[5] // 2)
        return dosdate, dostime

    def FileHeader(self, zip64=none):
        """Return the per-file header as a bytes object."""
        var dd = self._dostime()
        var CRC = self.CRC
        var compress_size = self.compress_size
        var file_size = self.file_size
        if self.flag_bits & 0x08:
            CRC = 0
            compress_size = 0
            file_size = 0
        var extra = self.extra
        var min_version = 0
        if zip64 is none:
            zip64 = file_size > ZIP64_LIMIT or compress_size > ZIP64_LIMIT
        if zip64:
            extra = extra + _u16(1) + _u16(16) + _u64(file_size) + _u64(compress_size)
        if zip64:
            if self.compress_type == ZIP_STORED or self.compress_type == ZIP_DEFLATED:
                file_size = 0xffffffff
                compress_size = 0xffffffff
            min_version = ZIP64_VERSION
        if self.compress_type == ZIP_BZIP2:
            min_version = max(BZIP2_VERSION, min_version)
        elif self.compress_type == ZIP_LZMA:
            min_version = max(LZMA_VERSION, min_version)
        self.extract_version = max(min_version, self.extract_version)
        self.create_version = max(min_version, self.create_version)
        var nf = self._encoded_name()
        var filename = nf[0]
        var flag_bits = nf[1]
        return (_LOCAL_SIG + _u16(self.extract_version) + _u16(self.reserved) + _u16(flag_bits)
                + _u16(self.compress_type) + _u16(dd[1]) + _u16(dd[0]) + _u32(CRC) + _u32(compress_size)
                + _u32(file_size) + _u16(len(filename)) + _u16(len(extra)) + filename + extra)

    def _decodeExtra(self):
        # the ZIP64 extra field: the 64-bit values of the fields set to -1
        var extra = self.extra
        var i = 0
        while i + 4 <= len(extra):
            var tp = _le(extra, i, 2)
            var ln = _le(extra, i + 2, 2)
            if ln + 4 > len(extra) - i:
                raise BadZipFile("Corrupt extra field " + "%04x" % tp + " (size=" + str(ln) + ")")
            if tp == 1:
                var data = extra[i + 4:i + 4 + ln]
                var pos = 0
                try:
                    if self.file_size == 0xFFFFFFFF:
                        self.file_size = _le(data, pos, 8)
                        pos = pos + 8
                    if self.compress_size == 0xFFFFFFFF:
                        self.compress_size = _le(data, pos, 8)
                        pos = pos + 8
                    if self.header_offset == 0xFFFFFFFF:
                        self.header_offset = _le(data, pos, 8)
                        pos = pos + 8
                except IndexError:
                    raise BadZipFile("Corrupt zip64 extra field. File size not found.") from None
            i = i + ln + 4

    @classmethod
    def from_file(cls, filename, arcname=none, strict_timestamps=true):
        filename = _fspath(filename)
        var st = os.stat(filename)
        var isdir = (st.st_mode & 0o170000) == 0o040000
        var mtime = time.localtime(st.st_mtime)
        var date_time = tuple(mtime)[0:6]
        if not strict_timestamps and date_time[0] < 1980:
            date_time = (1980, 1, 1, 0, 0, 0)
        elif not strict_timestamps and date_time[0] > 2107:
            date_time = (2107, 12, 31, 23, 59, 59)
        if arcname is none:
            arcname = filename
        arcname = os.path.normpath(_splitdrive(arcname)[1])
        while arcname[0:1] in (os.sep, "/"):
            arcname = arcname[1:]
        if isdir:
            arcname = arcname + "/"
        var zinfo = cls(arcname, date_time)
        zinfo.external_attr = (st.st_mode & 0xFFFF) << 16
        if isdir:
            zinfo.file_size = 0
            zinfo.external_attr = zinfo.external_attr | 0x10
        else:
            zinfo.file_size = st.st_size
        return zinfo

    def is_dir(self):
        """Return True if this archive member is a directory."""
        return self.filename[-1:] == "/"


def _filemode(mode):
    var perm = ""
    var kinds = [(0o140000, "s"), (0o120000, "l"), (0o100000, "-"), (0o060000, "b"), (0o040000, "d"),
                 (0o020000, "c"), (0o010000, "p")]
    var k = "?"
    for pair in kinds:
        if (mode & 0o170000) == pair[0]:
            k = pair[1]
            break
    var bits = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o40, "r"), (0o20, "w"), (0o10, "x"),
                (0o4, "r"), (0o2, "w"), (0o1, "x")]
    for b in bits:
        perm = perm + (b[1] if mode & b[0] else "-")
    return k + perm


# ── the end of central directory record ─────────────────────────────────────
def _EndRecData64(fpin, offset, endrec):
    try:
        fpin.seek(offset - _SIZE_ENDREC64_LOC, 2)
    except OSError:
        return endrec
    var data = fpin.read(_SIZE_ENDREC64_LOC)
    if len(data) != _SIZE_ENDREC64_LOC:
        return endrec
    if data[0:4] != _EOCD64_LOC_SIG:
        return endrec
    var diskno = _le(data, 4, 4)
    var reloff = _le(data, 8, 8)
    var disks = _le(data, 16, 4)
    if diskno != 0 or disks > 1:
        raise BadZipFile("zipfiles that span multiple disks are not supported")
    fpin.seek(offset - _SIZE_ENDREC64_LOC - _SIZE_ENDREC64, 2)
    data = fpin.read(_SIZE_ENDREC64)
    if len(data) != _SIZE_ENDREC64:
        return endrec
    if data[0:4] != _EOCD64_SIG:
        return endrec
    # (sig 4, record size 8, made by 2, needed 2, disk 4, directory's disk
    # 4, entries here 8, entries 8, directory size 8, directory offset 8)
    endrec[0] = _EOCD64_SIG
    endrec[1] = _le(data, 16, 4)
    endrec[2] = _le(data, 20, 4)
    endrec[3] = _le(data, 24, 8)
    endrec[4] = _le(data, 32, 8)
    endrec[5] = _le(data, 40, 8)
    endrec[6] = _le(data, 48, 8)
    return endrec


def _EndRecData(fpin):
    """[sig, disk, disk_cd, n_this, n_total, cd_size, cd_offset, comment_len,
    comment, offset_of_record] or None."""
    fpin.seek(0, 2)
    var filesize = fpin.tell()
    try:
        fpin.seek(-_SIZE_ENDREC, 2)
    except OSError:
        return none
    var data = fpin.read()
    if len(data) == _SIZE_ENDREC and data[0:4] == _EOCD_SIG and data[-2:] == b"\x00\x00":
        var endrec = _parse_eocd(data)
        endrec.append(b"")
        endrec.append(filesize - _SIZE_ENDREC)
        return _EndRecData64(fpin, -_SIZE_ENDREC, endrec)
    var maxCommentStart = max(filesize - (1 << 16) - _SIZE_ENDREC, 0)
    fpin.seek(maxCommentStart, 0)
    data = fpin.read()
    var start = data.rfind(_EOCD_SIG)
    if start >= 0:
        var recData = data[start:start + _SIZE_ENDREC]
        if len(recData) != _SIZE_ENDREC:
            return none
        var endrec = _parse_eocd(recData)
        var commentSize = endrec[7]
        var comment = data[start + _SIZE_ENDREC:start + _SIZE_ENDREC + commentSize]
        endrec.append(comment)
        endrec.append(maxCommentStart + start)
        return _EndRecData64(fpin, maxCommentStart + start - filesize, endrec)
    return none


def _parse_eocd(d):
    # [sig, disk, disk_cd, n_this, n_total, cd_size, cd_offset, comment_len]
    return [d[0:4], _le(d, 4, 2), _le(d, 6, 2), _le(d, 8, 2), _le(d, 10, 2), _le(d, 12, 4), _le(d, 16, 4),
            _le(d, 20, 2)]


# ── shared file handle ──────────────────────────────────────────────────────
class _SharedFile:
    def __init__(self, file, pos, close, writing):
        self._file = file
        self._pos = pos
        self._close = close
        self._writing = writing
        self.seekable = file.seekable if hasattr(file, "seekable") else none

    def tell(self):
        return self._pos

    def seek(self, offset, whence=0):
        if self._writing():
            raise ValueError("Can't reposition in the ZIP file while there is an open writing handle on it. "
                             + "Close the writing handle before trying to read.")
        self._file.seek(offset, whence)
        self._pos = self._file.tell()
        return self._pos

    def read(self, n=-1):
        if self._writing():
            raise ValueError("Can't read from the ZIP file while there is an open writing handle on it. "
                             + "Close the writing handle before trying to read.")
        self._file.seek(self._pos)
        var data = self._file.read(n)
        self._pos = self._file.tell()
        return data

    def close(self):
        if self._file is not none:
            var fileobj = self._file
            self._file = none
            self._close(fileobj)


# ── reading a member ────────────────────────────────────────────────────────
class ZipExtFile(io.BufferedIOBase):
    """File-like object for reading an archive member (ZipFile.open)."""

    MAX_N = 1 << 31 - 1
    MIN_READ_SIZE = 4096
    MAX_SEEK_READ = 1 << 24

    def __init__(self, fileobj, mode, zipinfo, pwd=none, close_fileobj=false):
        self._fileobj = fileobj
        self._close_fileobj = close_fileobj
        self._compress_type = zipinfo.compress_type
        self._compress_left = zipinfo.compress_size
        self._left = zipinfo.file_size
        self._decompressor = zlib.decompressobj(-15) if self._compress_type == ZIP_DEFLATED else none
        self._eof = false
        self._readbuffer = b""
        self._offset = 0
        self.newlines = none
        self.mode = mode
        self.name = zipinfo.filename
        self._expected_crc = zipinfo.CRC if hasattr(zipinfo, "CRC") else none
        self._running_crc = 0
        self._seekable = false
        self._closed = false
        try:
            if fileobj.seekable():
                self._orig_compress_start = fileobj.tell()
                self._orig_compress_size = zipinfo.compress_size
                self._orig_file_size = zipinfo.file_size
                self._orig_start_crc = self._running_crc
                self._seekable = true
        except AttributeError:
            pass

    def __repr__(self):
        var result = ["<" + self.__class__.__module__ + "." + self.__class__.__qualname__]
        if not self._closed:
            result.append(" name=" + repr(self.name) + " mode=" + repr(self.mode))
            if self._compress_type != ZIP_STORED:
                result.append(" compress_type=" + {8: "deflated"}.get(self._compress_type, str(self._compress_type)))
        else:
            result.append(" [closed]")
        result.append(">")
        return "".join(result)

    @property
    def closed(self):
        return self._closed

    def readable(self):
        if self._closed:
            raise ValueError("I/O operation on closed file.")
        return true

    def seekable(self):
        if self._closed:
            raise ValueError("I/O operation on closed file.")
        return self._seekable

    def writable(self):
        return false

    def _update_crc(self, newdata):
        if self._expected_crc is none:
            return
        self._running_crc = zlib.crc32(newdata, self._running_crc)
        if self._eof and self._running_crc != self._expected_crc:
            raise BadZipFile("Bad CRC-32 for file " + repr(self.name))

    def _read2(self, n):
        if self._compress_left <= 0:
            return b""
        n = max(n, self.MIN_READ_SIZE)
        n = min(n, self._compress_left)
        var data = self._fileobj.read(n)
        self._compress_left = self._compress_left - len(data)
        if not data:
            raise EOFError
        return data

    def _read1(self, n):
        if self._eof or n <= 0:
            return b""
        var data = b""
        if self._compress_type == ZIP_DEFLATED:
            data = self._decompressor.unconsumed_tail
            if n > len(data):
                data = data + self._read2(n - len(data))
        else:
            data = self._read2(n)
        if self._compress_type == ZIP_STORED:
            self._eof = self._compress_left <= 0
        elif self._compress_type == ZIP_DEFLATED:
            n = max(n, self.MIN_READ_SIZE)
            data = self._decompressor.decompress(data, n)
            self._eof = self._decompressor.eof or (self._compress_left <= 0 and not self._decompressor.unconsumed_tail)
            if self._eof:
                data = data + self._decompressor.flush()
        data = data[:self._left]
        self._left = self._left - len(data)
        if self._left <= 0:
            self._eof = true
        self._update_crc(data)
        return data

    def read(self, n=-1):
        if self._closed:
            raise ValueError("read from closed file.")
        if n is none or n < 0:
            var buf = self._readbuffer[self._offset:]
            self._readbuffer = b""
            self._offset = 0
            while not self._eof:
                buf = buf + self._read1(self.MAX_N)
            return buf
        var end = n + self._offset
        if end < len(self._readbuffer):
            var b0 = self._readbuffer[self._offset:end]
            self._offset = end
            return b0
        n = end - len(self._readbuffer)
        var buf = self._readbuffer[self._offset:]
        self._readbuffer = b""
        self._offset = 0
        while n > 0 and not self._eof:
            var data = self._read1(n)
            if n < len(data):
                self._readbuffer = data
                self._offset = n
                buf = buf + data[:n]
                break
            buf = buf + data
            n = n - len(data)
        return buf

    def read1(self, n=-1):
        if n is none or n < 0:
            var buf = self._readbuffer[self._offset:]
            self._readbuffer = b""
            self._offset = 0
            while not self._eof:
                var data = self._read1(self.MAX_N)
                if data:
                    buf = buf + data
                    break
            return buf
        var end = n + self._offset
        if end < len(self._readbuffer):
            var b0 = self._readbuffer[self._offset:end]
            self._offset = end
            return b0
        n = end - len(self._readbuffer)
        var buf = self._readbuffer[self._offset:]
        self._readbuffer = b""
        self._offset = 0
        if n > 0:
            while not self._eof:
                var data = self._read1(n)
                if n < len(data):
                    self._readbuffer = data
                    self._offset = n
                    buf = buf + data[:n]
                    break
                if data:
                    buf = buf + data
                    break
        return buf

    def peek(self, n=1):
        if n > len(self._readbuffer) - self._offset:
            var chunk = self.read(n)
            if len(chunk) > self._offset:
                self._readbuffer = chunk + self._readbuffer[self._offset:]
                self._offset = 0
            else:
                self._offset = self._offset - len(chunk)
        return self._readbuffer[self._offset:self._offset + 512]

    def readline(self, limit=-1):
        if limit is none:
            limit = -1
        if limit < 0:
            var i = self._readbuffer.find(b"\n", self._offset) + 1
            if i > 0:
                var line = self._readbuffer[self._offset:i]
                self._offset = i
                return line
        var out = b""
        while limit < 0 or len(out) < limit:
            var readahead = self.peek(2)
            if readahead == b"":
                break
            var nl = readahead.find(b"\n")
            var n = len(readahead) if nl < 0 else nl + 1
            if limit >= 0:
                n = min(n, limit - len(out))
            var piece = self.read(n)
            out = out + piece
            if out.endswith(b"\n"):
                break
        return out

    def readlines(self, hint=-1):
        var lines = []
        while true:
            var l = self.readline()
            if not l:
                break
            lines.append(l)
        return lines

    def __iter__(self):
        return self

    def __next__(self):
        var l = self.readline()
        if not l:
            raise StopIteration
        return l

    def readinto(self, b):
        var d = self.read(len(b))
        b[0:len(d)] = d
        return len(d)

    def tell(self):
        if self._closed:
            raise ValueError("tell on closed file.")
        if not self._seekable:
            raise io.UnsupportedOperation("underlying stream is not seekable")
        var filepos = self._orig_file_size - self._left - len(self._readbuffer) + self._offset
        return filepos

    def seek(self, offset, whence=0):
        if self._closed:
            raise ValueError("seek on closed file.")
        if not self._seekable:
            raise io.UnsupportedOperation("underlying stream is not seekable")
        var curr_pos = self.tell()
        var new_pos = 0
        if whence == 0:
            new_pos = offset
        elif whence == 1:
            new_pos = curr_pos + offset
        elif whence == 2:
            new_pos = self._orig_file_size + offset
        else:
            raise ValueError("whence must be os.SEEK_SET (0), os.SEEK_CUR (1), or os.SEEK_END (2)")
        if new_pos > self._orig_file_size:
            new_pos = self._orig_file_size
        if new_pos < 0:
            new_pos = 0
        var read_offset = new_pos - curr_pos
        var buff_offset = read_offset + self._offset
        if buff_offset >= 0 and buff_offset < len(self._readbuffer):
            self._offset = buff_offset
            read_offset = 0
        elif read_offset < 0:
            self._fileobj.seek(self._orig_compress_start)
            self._running_crc = self._orig_start_crc
            self._compress_left = self._orig_compress_size
            self._left = self._orig_file_size
            self._readbuffer = b""
            self._offset = 0
            self._decompressor = zlib.decompressobj(-15) if self._compress_type == ZIP_DEFLATED else none
            self._eof = false
            read_offset = new_pos
        while read_offset > 0:
            var read_len = min(self.MAX_SEEK_READ, read_offset)
            self.read(read_len)
            read_offset = read_offset - read_len
        return self.tell()

    def close(self):
        if self._closed:
            return
        self._closed = true
        if self._close_fileobj:
            self._fileobj.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
        return false


# ── writing a member ────────────────────────────────────────────────────────
class _ZipWriteFile(io.BufferedIOBase):
    def __init__(self, zf, zinfo, zip64):
        self._zinfo = zinfo
        self._zip64 = zip64
        self._zipfile = zf
        self._compressor = none
        if zinfo.compress_type == ZIP_DEFLATED:
            var lvl = zinfo._compresslevel
            self._compressor = zlib.compressobj(lvl if lvl is not none else -1, zlib.DEFLATED, -15)
        self._file_size = 0
        self._compress_size = 0
        self._crc = 0
        self._closed = false

    @property
    def _fileobj(self):
        return self._zipfile.fp

    @property
    def closed(self):
        return self._closed

    def writable(self):
        return true

    def readable(self):
        return false

    def write(self, data):
        if self._closed:
            raise ValueError("I/O operation on closed file.")
        if isinstance(data, str):
            raise TypeError("a bytes-like object is required, not 'str'")
        data = zlib._data(data)
        var nbytes = len(data)
        self._file_size = self._file_size + nbytes
        self._crc = zlib.crc32(data, self._crc)
        if self._compressor is not none:
            data = self._compressor.compress(data)
        self._compress_size = self._compress_size + len(data)
        self._fileobj.write(data)
        return nbytes

    def close(self):
        if self._closed:
            return
        try:
            if self._compressor is not none:
                var buf = self._compressor.flush()
                self._compress_size = self._compress_size + len(buf)
                self._fileobj.write(buf)
                self._zinfo.compress_size = self._compress_size
            else:
                self._zinfo.compress_size = self._file_size
            self._zinfo.CRC = self._crc
            self._zinfo.file_size = self._file_size
            if not self._zip64:
                if self._file_size > ZIP64_LIMIT:
                    raise RuntimeError("File size too large, try using force_zip64")
                if self._compress_size > ZIP64_LIMIT:
                    raise RuntimeError("Compressed size too large, try using force_zip64")
            if self._zinfo.flag_bits & 0x08:
                var fmt = _DD_SIG + _u32(self._zinfo.CRC)
                if self._zip64:
                    fmt = fmt + _u64(self._zinfo.compress_size) + _u64(self._zinfo.file_size)
                else:
                    fmt = fmt + _u32(self._zinfo.compress_size) + _u32(self._zinfo.file_size)
                self._fileobj.write(fmt)
                self._zipfile.start_dir = self._fileobj.tell()
            else:
                self._zipfile.start_dir = self._fileobj.tell()
                self._fileobj.seek(self._zinfo.header_offset)
                self._fileobj.write(self._zinfo.FileHeader(self._zip64))
                self._fileobj.seek(self._zipfile.start_dir)
            self._zipfile.filelist.append(self._zinfo)
            self._zipfile.NameToInfo[self._zinfo.filename] = self._zinfo
        finally:
            self._closed = true
            self._zipfile._writing = false

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
        return false


# ── ZipFile ─────────────────────────────────────────────────────────────────
class ZipFile:
    """Class with methods to open, read, write, close, list zip files."""

    fp = none
    _windows_illegal_name_trans_table = none

    def __init__(self, file, mode="r", compression=ZIP_STORED, allowZip64=true, compresslevel=none,
                 strict_timestamps=true, metadata_encoding=none):
        if mode not in ("r", "w", "x", "a"):
            raise ValueError("ZipFile requires mode 'r', 'w', 'x', or 'a'")
        _check_compression(compression)
        self._allowZip64 = allowZip64
        self._didModify = false
        self.debug = 0
        self.NameToInfo = {}
        self.filelist = []
        self.compression = compression
        self.compresslevel = compresslevel
        self.mode = mode
        self.pwd = none
        self._comment = b""
        self._strict_timestamps = strict_timestamps
        self.metadata_encoding = metadata_encoding
        if metadata_encoding is not none and mode != "r":
            raise ValueError("metadata_encoding is only supported for reading files")
        self._writing = false
        self._seekable = true
        self._fileRefCnt = 1
        self.start_dir = 0
        var path = _fspath(file)
        if path is not none:
            self._filePassed = 0
            self.filename = path
            var modeDict = {"r": "rb", "w": "w+b", "x": "x+b", "a": "r+b"}
            var filemode = modeDict[mode]
            while true:
                try:
                    self.fp = _builtin_open(path, filemode)
                except OSError:
                    if filemode in modeDict and filemode == "r+b":
                        filemode = "w+b"
                        modeDict = {}
                        continue
                    raise
                break
        else:
            self._filePassed = 1
            self.fp = file
            self.filename = getattr(file, "name", none)
        try:
            if mode == "r":
                self._RealGetContents()
            elif mode == "w" or mode == "x":
                self._didModify = true
                try:
                    self.start_dir = self.fp.tell()
                except (AttributeError, OSError):
                    self._seekable = false
                if self._seekable:
                    try:
                        self.fp.seek(self.start_dir)
                    except (AttributeError, OSError):
                        self._seekable = false
            else:
                try:
                    self._RealGetContents()
                    self.fp.seek(self.start_dir)
                except BadZipFile:
                    # not a zip: append an archive to the end of the file
                    self.fp.seek(0, 2)
                    self._didModify = true
                    self.start_dir = self.fp.tell()
        except Exception:
            var fp = self.fp
            self.fp = none
            self._fpclose(fp)
            raise

    def __enter__(self):
        return self

    def __exit__(self, t, v, tb):
        self.close()
        return false

    def __repr__(self):
        var result = ["<" + self.__class__.__module__ + "." + self.__class__.__qualname__]
        if self.fp is not none:
            if self._filePassed:
                result.append(" file=" + repr(self.fp))
            elif self.filename is not none:
                result.append(" filename=" + repr(self.filename))
            result.append(" mode=" + repr(self.mode))
        else:
            result.append(" [closed]")
        result.append(">")
        return "".join(result)

    def _RealGetContents(self):
        var fp = self.fp
        var endrec = none
        try:
            endrec = _EndRecData(fp)
        except OSError:
            raise BadZipFile("File is not a zip file") from None
        if not endrec:
            raise BadZipFile("File is not a zip file")
        var size_cd = endrec[5]
        var offset_cd = endrec[6]
        self._comment = endrec[8]
        # "concat" is zero unless the zip was appended to another file
        var concat = endrec[9] - size_cd - offset_cd
        if endrec[0] == _EOCD64_SIG:
            concat = concat - (_SIZE_ENDREC64 + _SIZE_ENDREC64_LOC)
        self.start_dir = offset_cd + concat
        if self.start_dir < 0:
            raise BadZipFile("Bad offset for central directory")
        fp.seek(self.start_dir, 0)
        var data = fp.read(size_cd)
        var pos = 0
        var total = 0
        while total < size_cd:
            var centdir = data[pos:pos + _SIZE_CD]
            pos = pos + _SIZE_CD
            if len(centdir) != _SIZE_CD:
                raise BadZipFile("Truncated central directory")
            if centdir[0:4] != _CD_SIG:
                raise BadZipFile("Bad magic number for central directory")
            var create_version = centdir[4]
            var create_system = centdir[5]
            var extract_version = centdir[6]
            var reserved = centdir[7]
            var flags = _le(centdir, 8, 2)
            var compress_type = _le(centdir, 10, 2)
            var t = _le(centdir, 12, 2)
            var d = _le(centdir, 14, 2)
            var crc = _le(centdir, 16, 4)
            var csize = _le(centdir, 20, 4)
            var usize = _le(centdir, 24, 4)
            var nlen = _le(centdir, 28, 2)
            var elen = _le(centdir, 30, 2)
            var clen = _le(centdir, 32, 2)
            var filename = data[pos:pos + nlen]
            pos = pos + nlen
            var orig_filename_crc = crc
            if flags & 0x800:
                filename = filename.decode("utf-8")
            else:
                filename = filename.decode(self.metadata_encoding or "cp437")
            var x = ZipInfo(filename)
            x.extra = data[pos:pos + elen]
            pos = pos + elen
            x.comment = data[pos:pos + clen]
            pos = pos + clen
            x.header_offset = _le(centdir, 42, 4)
            x.create_version = create_version
            x.create_system = create_system
            x.extract_version = extract_version
            x.reserved = reserved
            x.flag_bits = flags
            x.compress_type = compress_type
            x.CRC = crc
            x.compress_size = csize
            x.file_size = usize
            x.volume = _le(centdir, 34, 2)
            x.internal_attr = _le(centdir, 36, 2)
            x.external_attr = _le(centdir, 38, 4)
            if x.extract_version > MAX_EXTRACT_VERSION:
                raise NotImplementedError("zip file version %.1f" % (x.extract_version / 10))
            x._raw_time = t
            x.date_time = ((d >> 9) + 1980, (d >> 5) & 0xF, d & 0x1F, t >> 11, (t >> 5) & 0x3F, (t & 0x1F) * 2)
            x._decodeExtra()
            x.header_offset = x.header_offset + concat
            self.filelist.append(x)
            self.NameToInfo[x.filename] = x
            total = total + _SIZE_CD + nlen + elen + clen
        var end_offset = self.start_dir
        var ordered = sorted(self.filelist, key=lambda zi: zi.header_offset, reverse=true)
        for zinfo in ordered:
            zinfo._end_offset = end_offset
            end_offset = zinfo.header_offset

    def namelist(self):
        """Return a list of file names in the archive."""
        return [data.filename for data in self.filelist]

    def infolist(self):
        """Return a list of class ZipInfo instances for files in the archive."""
        return self.filelist

    def printdir(self, file=none):
        """Print a table of contents for the zip file."""
        print("%-46s %19s %12s" % ("File Name", "Modified    ", "Size"), file=file)
        for zinfo in self.filelist:
            var date = "%d-%02d-%02d %02d:%02d:%02d" % zinfo.date_time[:6]
            print("%-46s %s %12d" % (zinfo.filename, date, zinfo.file_size), file=file)

    def testzip(self):
        """Read all the files and check the CRC. Return None if all files
        could be read successfully, or the name of the offending file
        otherwise."""
        var chunk_size = 2 ** 20
        for zinfo in self.filelist:
            try:
                with self.open(zinfo.filename, "r") as f:
                    while f.read(chunk_size):
                        pass
            except BadZipFile:
                return zinfo.filename
        return none

    def getinfo(self, name):
        """Return the instance of ZipInfo given 'name'."""
        var info = self.NameToInfo.get(name)
        if info is none:
            raise KeyError("There is no item named " + repr(name) + " in the archive")
        return info

    def setpassword(self, pwd):
        """Set default password for encrypted files."""
        if pwd and not isinstance(pwd, bytes):
            raise TypeError("pwd: expected bytes, got " + type(pwd).__name__)
        self.pwd = pwd if pwd else none

    @property
    def comment(self):
        """The comment text associated with the ZIP file."""
        return self._comment

    @comment.setter
    def comment(self, comment):
        if not isinstance(comment, bytes):
            raise TypeError("comment: expected bytes, got " + type(comment).__name__)
        if len(comment) > ZIP_MAX_COMMENT:
            import warnings
            warnings.warn("Archive comment is too long; truncating to " + str(ZIP_MAX_COMMENT) + " bytes", stacklevel=2)
            comment = comment[:ZIP_MAX_COMMENT]
        self._comment = comment
        self._didModify = true

    def read(self, name, pwd=none):
        """Return file bytes for name."""
        with self.open(name, "r", pwd) as fp:
            return fp.read()

    def open(self, name, mode="r", pwd=none, force_zip64=false):
        """Return file-like object for 'name'."""
        if mode not in ("r", "w"):
            raise ValueError('open() requires mode "r" or "w"')
        if pwd and mode == "w":
            raise ValueError("pwd is only supported for reading files")
        if not self.fp:
            raise ValueError("Attempt to use ZIP archive that was already closed")
        var zinfo = none
        if isinstance(name, ZipInfo):
            zinfo = name
        elif mode == "w":
            zinfo = ZipInfo(name)
            zinfo.compress_type = self.compression
            zinfo._compresslevel = self.compresslevel
        else:
            zinfo = self.getinfo(name)
        if mode == "w":
            return self._open_to_write(zinfo, force_zip64)
        if self._writing:
            raise ValueError("Can't read from the ZIP file while there is an open writing handle on it. "
                             + "Close the writing handle before trying to read.")
        self._fileRefCnt = self._fileRefCnt + 1
        var zef_file = _SharedFile(self.fp, zinfo.header_offset, self._fpclose, lambda: self._writing)
        try:
            var fheader = zef_file.read(_SIZE_LOCAL)
            if len(fheader) != _SIZE_LOCAL:
                raise BadZipFile("Truncated file header")
            if fheader[0:4] != _LOCAL_SIG:
                raise BadZipFile("Bad magic number for file header")
            var nlen = _le(fheader, 26, 2)
            var elen = _le(fheader, 28, 2)
            var fname = zef_file.read(nlen)
            if elen:
                zef_file.read(elen)
            if zinfo.flag_bits & 0x20:
                raise NotImplementedError("compressed patched data (flag bit 5)")
            if zinfo.flag_bits & 0x40:
                raise NotImplementedError("strong encryption (flag bit 6)")
            var fname_str = none
            if _le(fheader, 6, 2) & 0x800:
                fname_str = fname.decode("utf-8")
            else:
                fname_str = fname.decode(self.metadata_encoding or "cp437")
            if fname_str != zinfo.orig_filename:
                raise BadZipFile("File name in directory " + repr(zinfo.orig_filename) + " and header "
                                 + repr(fname) + " differ.")
            if zinfo.flag_bits & 0x1:
                raise RuntimeError("File " + repr(name if isinstance(name, str) else zinfo.filename)
                                   + " is encrypted, password required for extraction")
            _check_compression(zinfo.compress_type)
            return ZipExtFile(zef_file, mode, zinfo, pwd, true)
        except Exception:
            zef_file.close()
            raise

    def _open_to_write(self, zinfo, force_zip64=false):
        if force_zip64 and not self._allowZip64:
            raise ValueError("force_zip64 is True, but allowZip64 was False when opening the ZIP file.")
        if self._writing:
            raise ValueError("Can't write to the ZIP file while there is another write handle open on it. "
                             + "Close the first handle before opening another.")
        zinfo.compress_size = 0
        zinfo.CRC = 0
        zinfo.flag_bits = 0x00
        if zinfo.compress_type == ZIP_LZMA:
            zinfo.flag_bits = zinfo.flag_bits | 0x02
        if not self._seekable:
            zinfo.flag_bits = zinfo.flag_bits | 0x08
        if not zinfo.external_attr:
            zinfo.external_attr = 0o600 << 16
        var zip64 = self._allowZip64 and (force_zip64 or zinfo.file_size * 1.05 > ZIP64_LIMIT)
        if self._seekable:
            self.fp.seek(self.start_dir)
        zinfo.header_offset = self.fp.tell()
        self._writecheck(zinfo)
        self._didModify = true
        self.fp.write(zinfo.FileHeader(zip64))
        self._writing = true
        return _ZipWriteFile(self, zinfo, zip64)

    def extract(self, member, path=none, pwd=none):
        """Extract a member from the archive to the current working
        directory, using its full name."""
        if path is none:
            path = os.getcwd()
        else:
            path = _fspath(path)
        return self._extract_member(member, path, pwd)

    def extractall(self, path=none, members=none, pwd=none):
        """Extract all members from the archive to the current working
        directory."""
        if members is none:
            members = self.namelist()
        if path is none:
            path = os.getcwd()
        else:
            path = _fspath(path)
        for zipinfo in members:
            self._extract_member(zipinfo, path, pwd)

    def _extract_member(self, member, targetpath, pwd):
        if not isinstance(member, ZipInfo):
            member = self.getinfo(member)
        var arcname = member.filename.replace("/", os.sep)
        if _ALTSEP:
            arcname = arcname.replace(_ALTSEP, os.sep)
        arcname = _splitdrive(arcname)[1]
        var invalid = ("", _CURDIR, _PARDIR)
        arcname = os.sep.join([x for x in arcname.split(os.sep) if x not in invalid])
        if os.sep == "\\":
            arcname = self._sanitize_windows_name(arcname, os.sep)
        targetpath = os.path.join(targetpath, arcname)
        targetpath = os.path.normpath(targetpath)
        var upperdirs = os.path.dirname(targetpath)
        if upperdirs and not os.path.exists(upperdirs):
            os.makedirs(upperdirs)
        if member.is_dir():
            if not os.path.isdir(targetpath):
                os.mkdir(targetpath)
            return targetpath
        with self.open(member, pwd=pwd) as source:
            with _builtin_open(targetpath, "wb") as target:
                while true:
                    var chunk = source.read(1 << 20)
                    if not chunk:
                        break
                    target.write(chunk)
        return targetpath

    @classmethod
    def _sanitize_windows_name(cls, arcname, pathsep):
        var illegal = ':<>|"?*'
        var out = []
        for x in arcname.split(pathsep):
            var y = ""
            for ch in x:
                y = y + ("_" if ch in illegal else ch)
            y = y.rstrip(".")
            if y:
                out.append(y)
        return pathsep.join(out)

    def _writecheck(self, zinfo):
        if zinfo.filename in self.NameToInfo:
            import warnings
            warnings.warn("Duplicate name: " + repr(zinfo.filename), stacklevel=3)
        if self.mode not in ("w", "x", "a"):
            raise ValueError("write() requires mode 'w', 'x', or 'a'")
        if not self.fp:
            raise ValueError("Attempt to write ZIP archive that was already closed")
        _check_compression(zinfo.compress_type)
        if not self._allowZip64:
            var requires_zip64 = none
            if len(self.filelist) >= ZIP_FILECOUNT_LIMIT:
                requires_zip64 = "Files count"
            elif zinfo.file_size > ZIP64_LIMIT:
                requires_zip64 = "Filesize"
            elif zinfo.header_offset > ZIP64_LIMIT:
                requires_zip64 = "Zipfile size"
            if requires_zip64:
                raise LargeZipFile(requires_zip64 + " would require ZIP64 extensions")

    def write(self, filename, arcname=none, compress_type=none, compresslevel=none):
        """Put the bytes from filename into the archive under the name
        arcname."""
        if not self.fp:
            raise ValueError("Attempt to write to ZIP archive that was already closed")
        if self._writing:
            raise ValueError("Can't write to ZIP archive while an open writing handle exists")
        var zinfo = ZipInfo.from_file(filename, arcname, self._strict_timestamps)
        if zinfo.is_dir():
            zinfo.compress_size = 0
            zinfo.CRC = 0
            self.mkdir(zinfo)
            return
        zinfo.compress_type = compress_type if compress_type is not none else self.compression
        zinfo._compresslevel = compresslevel if compresslevel is not none else self.compresslevel
        with _builtin_open(_fspath(filename), "rb") as src:
            with self.open(zinfo, "w") as dest:
                while true:
                    var chunk = src.read(1024 * 8)
                    if not chunk:
                        break
                    dest.write(chunk)

    def writestr(self, zinfo_or_arcname, data, compress_type=none, compresslevel=none):
        """Write a file into the archive. The contents is 'data', which may
        be either a 'str' or a 'bytes' instance."""
        if isinstance(data, str):
            data = data.encode("utf-8")
        var zinfo = none
        if not isinstance(zinfo_or_arcname, ZipInfo):
            zinfo = ZipInfo(zinfo_or_arcname, tuple(time.localtime(time.time()))[0:6])
            zinfo.compress_type = self.compression
            zinfo._compresslevel = self.compresslevel
            if zinfo.filename[-1:] == "/":
                zinfo.external_attr = 0o40775 << 16
                zinfo.external_attr = zinfo.external_attr | 0x10
            else:
                zinfo.external_attr = 0o600 << 16
        else:
            zinfo = zinfo_or_arcname
        if not self.fp:
            raise ValueError("Attempt to write to ZIP archive that was already closed")
        if self._writing:
            raise ValueError("Can't write to ZIP archive while an open writing handle exists.")
        if compress_type is not none:
            zinfo.compress_type = compress_type
        if compresslevel is not none:
            zinfo._compresslevel = compresslevel
        zinfo.file_size = len(data)
        with self.open(zinfo, "w") as dest:
            dest.write(data)

    def mkdir(self, zinfo_or_directory_name, mode=511):
        """Creates a directory inside the zip archive."""
        var zinfo = none
        if isinstance(zinfo_or_directory_name, ZipInfo):
            zinfo = zinfo_or_directory_name
            if not zinfo.is_dir():
                raise ValueError("The given ZipInfo does not describe a directory")
        elif isinstance(zinfo_or_directory_name, str):
            var directory_name = zinfo_or_directory_name
            if not directory_name.endswith("/"):
                directory_name = directory_name + "/"
            zinfo = ZipInfo(directory_name, tuple(time.localtime(time.time()))[0:6])
            zinfo.compress_size = 0
            zinfo.CRC = 0
            zinfo.external_attr = ((0o40000 | mode) & 0xFFFF) << 16
            zinfo.file_size = 0
            zinfo.external_attr = zinfo.external_attr | 0x10
        else:
            raise TypeError("Expected type str or ZipInfo")
        if self._writing:
            raise ValueError("Can't write to ZIP archive while an open writing handle exists.")
        if self._seekable:
            self.fp.seek(self.start_dir)
        zinfo.header_offset = self.fp.tell()
        if zinfo.compress_type == ZIP_LZMA:
            zinfo.flag_bits = zinfo.flag_bits | 0x02
        self._writecheck(zinfo)
        self._didModify = true
        self.filelist.append(zinfo)
        self.NameToInfo[zinfo.filename] = zinfo
        self.fp.write(zinfo.FileHeader(false))
        self.start_dir = self.fp.tell()

    def __del__(self):
        """Call the "close()" method in case the user forgot."""
        try:
            self.close()
        except Exception:
            pass

    def close(self):
        """Close the file, and for mode 'w', 'x' and 'a' write the ending
        records."""
        if self.fp is none:
            return
        if self._writing:
            raise ValueError("Can't close the ZIP file while there is an open writing handle on it. "
                             + "Close the writing handle before closing the zip.")
        try:
            if (self.mode == "w" or self.mode == "x" or self.mode == "a") and self._didModify:
                if self._seekable:
                    self.fp.seek(self.start_dir)
                self._write_end_record()
        finally:
            var fp = self.fp
            self.fp = none
            self._fpclose(fp)

    def _write_end_record(self):
        for zinfo in self.filelist:
            var dd = zinfo._dostime()
            var extra = []
            var file_size = zinfo.file_size
            var compress_size = zinfo.compress_size
            var header_offset = zinfo.header_offset
            if file_size > ZIP64_LIMIT or compress_size > ZIP64_LIMIT:
                extra.append(file_size)
                extra.append(compress_size)
                file_size = 0xffffffff
                compress_size = 0xffffffff
            if header_offset > ZIP64_LIMIT:
                extra.append(header_offset)
                header_offset = 0xffffffff
            var extra_data = zinfo.extra
            var min_version = 0
            if extra:
                extra_data = _strip_zip64(extra_data)
                var packed = b""
                for v in extra:
                    packed = packed + _u64(v)
                extra_data = _u16(1) + _u16(8 * len(extra)) + packed + extra_data
                min_version = ZIP64_VERSION
            if zinfo.compress_type == ZIP_BZIP2:
                min_version = max(BZIP2_VERSION, min_version)
            elif zinfo.compress_type == ZIP_LZMA:
                min_version = max(LZMA_VERSION, min_version)
            var extract_version = max(min_version, zinfo.extract_version)
            var create_version = max(min_version, zinfo.create_version)
            var nf = zinfo._encoded_name()
            var filename = nf[0]
            var flag_bits = nf[1]
            var centdir = (_CD_SIG + bytes([create_version, zinfo.create_system, extract_version, zinfo.reserved])
                           + _u16(flag_bits) + _u16(zinfo.compress_type) + _u16(dd[1]) + _u16(dd[0])
                           + _u32(zinfo.CRC) + _u32(compress_size) + _u32(file_size) + _u16(len(filename))
                           + _u16(len(extra_data)) + _u16(len(zinfo.comment)) + _u16(0)
                           + _u16(zinfo.internal_attr) + _u32(zinfo.external_attr) + _u32(header_offset))
            self.fp.write(centdir)
            self.fp.write(filename)
            self.fp.write(extra_data)
            self.fp.write(zinfo.comment)
        var pos2 = self.fp.tell()
        var centDirCount = len(self.filelist)
        var centDirSize = pos2 - self.start_dir
        var centDirOffset = self.start_dir
        var requires_zip64 = none
        if centDirCount > ZIP_FILECOUNT_LIMIT:
            requires_zip64 = "Files count"
        elif centDirOffset > ZIP64_LIMIT:
            requires_zip64 = "Central directory offset"
        elif centDirSize > ZIP64_LIMIT:
            requires_zip64 = "Central directory size"
        if requires_zip64:
            if not self._allowZip64:
                raise LargeZipFile(requires_zip64 + " would require ZIP64 extensions")
            var zip64endrec = (_EOCD64_SIG + _u64(44) + _u16(45) + _u16(45) + _u32(0) + _u32(0)
                               + _u64(centDirCount) + _u64(centDirCount) + _u64(centDirSize)
                               + _u64(centDirOffset))
            self.fp.write(zip64endrec)
            var zip64locrec = _EOCD64_LOC_SIG + _u32(0) + _u64(pos2) + _u32(1)
            self.fp.write(zip64locrec)
            centDirCount = min(centDirCount, 0xFFFF)
            centDirSize = min(centDirSize, 0xFFFFFFFF)
            centDirOffset = min(centDirOffset, 0xFFFFFFFF)
        var endrec = (_EOCD_SIG + _u16(0) + _u16(0) + _u16(centDirCount) + _u16(centDirCount)
                      + _u32(centDirSize) + _u32(centDirOffset) + _u16(len(self._comment)))
        self.fp.write(endrec)
        self.fp.write(self._comment)
        if self.mode == "a":
            try:
                self.fp.truncate()
            except Exception:
                pass
        self.fp.flush()

    def _fpclose(self, fp):
        if self._fileRefCnt > 0:
            self._fileRefCnt = self._fileRefCnt - 1
        if not self._fileRefCnt and not self._filePassed:
            fp.close()


def _strip_zip64(extra):
    var out = b""
    var i = 0
    while i + 4 <= len(extra):
        var tp = _le(extra, i, 2)
        var ln = _le(extra, i + 2, 2)
        if tp != 1:
            out = out + extra[i:i + 4 + ln]
        i = i + 4 + ln
    return out + extra[i:]


def _check_zipfile(fp):
    try:
        if _EndRecData(fp):
            return true
    except OSError:
        pass
    return false


def is_zipfile(filename):
    """Quickly see if a file is a ZIP file by checking the magic number."""
    var result = false
    try:
        if hasattr(filename, "read"):
            result = _check_zipfile(filename)
        else:
            with _builtin_open(_fspath(filename), "rb") as fp:
                result = _check_zipfile(fp)
    except OSError:
        pass
    return result


# ── zipfile.Path ────────────────────────────────────────────────────────────
class Path:
    """A pathlib-compatible interface for zip files."""



    def __init__(self, root, at=""):
        if not isinstance(root, ZipFile):
            root = ZipFile(root)
        self.root = root
        self.at = at

    def _names(self):
        # the archive's names and the directories they imply
        var names = list(self.root.namelist())
        var seen = set(names)
        for n in list(names):
            var parts = n.rstrip("/").split("/")
            var k = 1
            while k < len(parts):
                var d = "/".join(parts[:k]) + "/"
                if d not in seen:
                    seen.add(d)
                    names.append(d)
                k = k + 1
        return names

    def open(self, mode="r", *args, pwd=none, **kwargs):
        if self.is_dir():
            raise IsADirectoryError(self.at)
        var zip_mode = mode[0]
        if not self.exists() and zip_mode == "r":
            raise FileNotFoundError(self.at)
        var stream = self.root.open(self.at, zip_mode, pwd=pwd)
        if "b" in mode:
            if args or kwargs:
                raise ValueError("encoding args invalid for binary operation")
            return stream
        return io.TextIOWrapper(stream, *args, **kwargs)

    @property
    def name(self):
        return self.at.rstrip("/").rpartition("/")[2] if self.at else os.path.basename(self.filename)

    @property
    def suffix(self):
        var n = self.name
        var i = n.rfind(".")
        return n[i:] if 0 < i < len(n) - 1 else ""

    @property
    def suffixes(self):
        var n = self.name
        if n.endswith("."):
            return []
        n = n.lstrip(".")
        return ["." + s for s in n.split(".")[1:]]

    @property
    def stem(self):
        var n = self.name
        var i = n.rfind(".")
        return n[:i] if 0 < i < len(n) - 1 else n

    @property
    def filename(self):
        return os.path.join(self.root.filename, self.at) if self.at else self.root.filename

    def read_text(self, *args, **kwargs):
        with self.open("r", *args, **kwargs) as strm:
            return strm.read()

    def read_bytes(self):
        with self.open("rb") as strm:
            return strm.read()

    def _is_child(self, path):
        return path.at.rstrip("/").rpartition("/")[0] == self.at.rstrip("/")

    def _next(self, at):
        return Path(self.root, at)

    def is_dir(self):
        return not self.at or self.at.endswith("/")

    def is_file(self):
        return self.exists() and not self.is_dir()

    def exists(self):
        return self.at == "" or self.at in self._names()

    def iterdir(self):
        if not self.is_dir():
            raise ValueError("Can't listdir a file")
        var subs = [self._next(n) for n in self._names()]
        return iter([p for p in subs if self._is_child(p)])

    def __str__(self):
        return os.path.join(self.root.filename, self.at) if self.at else self.root.filename

    def __repr__(self):
        return "Path(" + repr(self.root.filename) + ", " + repr(self.at) + ")"

    def joinpath(self, *other):
        var at = self.at
        for o in other:
            at = (at.rstrip("/") + "/" + o) if at else o
        var names = self._names()
        if at not in names and (at + "/") in names:
            at = at + "/"
        return self._next(at)

    def __truediv__(self, other):
        return self.joinpath(other)

    @property
    def parent(self):
        if not self.at:
            return self._next("")
        var parent_at = self.at.rstrip("/").rpartition("/")[0]
        if parent_at:
            parent_at = parent_at + "/"
        return self._next(parent_at)


# ── the command line ────────────────────────────────────────────────────────
def main(args=none):
    import sys
    import argparse
    var description = "A simple command-line interface for zipfile module."
    var parser = argparse.ArgumentParser(description=description)
    var group = parser.add_mutually_exclusive_group(required=true)
    group.add_argument("-l", "--list", metavar="<zipfile>", help="Show listing of a zipfile")
    group.add_argument("-e", "--extract", nargs=2, metavar=("<zipfile>", "<output_dir>"),
                       help="Extract zipfile into target dir")
    group.add_argument("-c", "--create", nargs="+", metavar=("<name>", "<file>"),
                       help="Create zipfile from sources")
    group.add_argument("-t", "--test", metavar="<zipfile>", help="Test if a zipfile is valid")
    parser.add_argument("--metadata-encoding", metavar="<encoding>",
                        help="Specify encoding of member names for -l, -e and -t")
    var a = parser.parse_args(args)
    var encoding = a.metadata_encoding
    if a.test is not none:
        var src = a.test
        with ZipFile(src, "r", metadata_encoding=encoding) as zf:
            var badfile = zf.testzip()
        if badfile:
            print("The following enclosed file is corrupted: " + repr(badfile))
        print("Done testing")
    elif a.list is not none:
        with ZipFile(a.list, "r", metadata_encoding=encoding) as zf:
            zf.printdir()
    elif a.extract is not none:
        with ZipFile(a.extract[0], "r", metadata_encoding=encoding) as zf:
            zf.extractall(a.extract[1])
    elif a.create is not none:
        if encoding:
            print("Non-conforming encodings not supported with -c.", file=sys.stderr)
            sys.exit(1)
        var zip_name = a.create.pop(0)
        var files = a.create

        def addToZip(zf, path, zippath):
            if os.path.isfile(path):
                zf.write(path, zippath, ZIP_DEFLATED)
            elif os.path.isdir(path):
                if zippath:
                    zf.write(path, zippath)
                for nm in sorted(os.listdir(path)):
                    addToZip(zf, os.path.join(path, nm), os.path.join(zippath, nm))

        with ZipFile(zip_name, "w") as zf:
            for path in files:
                var zippath = os.path.basename(path)
                if not zippath:
                    zippath = os.path.basename(os.path.dirname(path))
                if zippath in ("", _CURDIR, _PARDIR):
                    zippath = ""
                addToZip(zf, path, zippath)


if __name__ == "__main__":
    main()
