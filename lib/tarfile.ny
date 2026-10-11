# nython: module    (import it by name: it runs in a module scope of its own)
# lib/tarfile.ny - Python's tarfile (round 79): read and write tar archives
# in the ustar, GNU and pax formats, plain or gzip-compressed, after
# CPython 3.11's Lib/tarfile.py (headers come out byte for byte the same).
#
#     import tarfile
#     with tarfile.open("a.tar.gz", "w:gz") as t: t.add("src")
#     with tarfile.open("a.tar.gz") as t: t.extractall("out", filter="data")
#
# open(name, mode, fileobj, bufsize, **kw): "r" / "r:*" (compression
#   detected), "r:", "r:gz", "w", "w:", "w:gz", "x", "x:gz", "a", "a:", and
#   the stream modes "r|*", "r|", "r|gz", "w|", "w|gz" (no seeking: a
#   pipe or socket works); compresslevel=, format=, encoding=, errors=,
#   pax_headers=, ignore_zeros=, dereference=, errorlevel=
# TarFile: getmember, getmembers, getnames, next, iteration, list,
#   extractfile (a file object: read/readline/seek/tell/...), extract,
#   extractall (PEP 706 filters: filter="data" | "tar" | "fully_trusted" or
#   a callable, and TarFile.extraction_filter), add (recursive, filter=),
#   addfile, gettarinfo, close, with
# TarInfo: name/path, size, mtime, mode, type, linkname/linkpath, uid, gid,
#   uname, gname, devmajor, devminor, offset, offset_data, pax_headers,
#   isfile/isreg/isdir/issym/islnk/ischr/isblk/isfifo/isdev/issparse,
#   frombuf, fromtarfile, tobuf(format), get_info, replace,
#   create_pax_global_header
# data_filter, tar_filter, fully_trusted_filter; is_tarfile; TarError and
#   its subclasses (ReadError, CompressionError, StreamError, ExtractError,
#   HeaderError..., FilterError, AbsolutePathError, OutsideDestinationError,
#   SpecialFileError, AbsoluteLinkError, LinkOutsideDestinationError) with
#   CPython's messages; USTAR_FORMAT, GNU_FORMAT, PAX_FORMAT,
#   DEFAULT_FORMAT, the type constants; nython -m tarfile -l|-c|-e|-t.
#
# Not here: bz2 and xz compression (CompressionError "bz2 module is not
# available", as CPython without it); GNU sparse members are read as their
# stored data; owner names come from the archive only (no pwd/grp: uname
# and gname are "" when adding files); chown is not done on extraction;
# device and FIFO members are not created (ExtractError, non-fatal by
# default); the extraction filter defaults to fully_trusted, as in 3.11.
import io
import os
import time
import copy
import re
import zlib

__all__ = ["TarFile", "TarInfo", "is_tarfile", "TarError", "ReadError", "CompressionError", "StreamError",
           "ExtractError", "HeaderError", "ENCODING", "USTAR_FORMAT", "GNU_FORMAT", "PAX_FORMAT",
           "DEFAULT_FORMAT", "open", "fully_trusted_filter", "data_filter", "tar_filter", "FilterError",
           "AbsoluteLinkError", "OutsideDestinationError", "SpecialFileError", "AbsolutePathError",
           "LinkOutsideDestinationError"]

_builtin_open = open

NUL = b"\x00"
BLOCKSIZE = 512
RECORDSIZE = BLOCKSIZE * 20
GNU_MAGIC = b"ustar  \x00"
POSIX_MAGIC = b"ustar\x0000"
LENGTH_NAME = 100
LENGTH_LINK = 100
LENGTH_PREFIX = 155

REGTYPE = b"0"
AREGTYPE = b"\x00"
LNKTYPE = b"1"
SYMTYPE = b"2"
CHRTYPE = b"3"
BLKTYPE = b"4"
DIRTYPE = b"5"
FIFOTYPE = b"6"
CONTTYPE = b"7"
GNUTYPE_LONGNAME = b"L"
GNUTYPE_LONGLINK = b"K"
GNUTYPE_SPARSE = b"S"
XHDTYPE = b"x"
XGLTYPE = b"g"
SOLARIS_XHDTYPE = b"X"

USTAR_FORMAT = 0
GNU_FORMAT = 1
PAX_FORMAT = 2
DEFAULT_FORMAT = PAX_FORMAT

SUPPORTED_TYPES = (REGTYPE, AREGTYPE, LNKTYPE, SYMTYPE, DIRTYPE, FIFOTYPE, CONTTYPE, CHRTYPE, BLKTYPE,
                   GNUTYPE_LONGNAME, GNUTYPE_LONGLINK, GNUTYPE_SPARSE)
REGULAR_TYPES = (REGTYPE, AREGTYPE, CONTTYPE, GNUTYPE_SPARSE)
GNU_TYPES = (GNUTYPE_LONGNAME, GNUTYPE_LONGLINK, GNUTYPE_SPARSE)
PAX_FIELDS = ("path", "linkpath", "size", "mtime", "uid", "gid", "uname", "gname")
PAX_NAME_FIELDS = ("path", "linkpath", "uname", "gname")
PAX_NUMBER_FIELDS = {"atime": float, "ctime": float, "mtime": float, "uid": int, "gid": int, "size": int}

ENCODING = "utf-8"

_header_length_prefix_re = re.compile(rb"([0-9]{1,20}) ")


# ── exceptions ──────────────────────────────────────────────────────────────
class TarError(Exception):
    """Base exception."""
    pass


class ExtractError(TarError):
    """General exception for extract errors."""
    pass


class ReadError(TarError):
    """Exception for unreadable tar archives."""
    pass


class CompressionError(TarError):
    """Exception for unavailable compression methods."""
    pass


class StreamError(TarError):
    """Exception for unsupported operations on stream-like TarFiles."""
    pass


class HeaderError(TarError):
    """Base exception for header errors."""
    pass


class EmptyHeaderError(HeaderError):
    pass


class TruncatedHeaderError(HeaderError):
    pass


class EOFHeaderError(HeaderError):
    pass


class InvalidHeaderError(HeaderError):
    pass


class SubsequentHeaderError(HeaderError):
    pass


class FilterError(TarError):
    pass


class AbsolutePathError(FilterError):
    def __init__(self, tarinfo):
        self.tarinfo = tarinfo
        super().__init__("member " + repr(tarinfo.name) + " has an absolute path")


class OutsideDestinationError(FilterError):
    def __init__(self, tarinfo, path):
        self.tarinfo = tarinfo
        self._path = path
        super().__init__(repr(tarinfo.name) + " would be extracted to " + repr(path)
                         + ", which is outside the destination")


class SpecialFileError(FilterError):
    def __init__(self, tarinfo):
        self.tarinfo = tarinfo
        super().__init__(repr(tarinfo.name) + " is a special file")


class AbsoluteLinkError(FilterError):
    def __init__(self, tarinfo):
        self.tarinfo = tarinfo
        super().__init__(repr(tarinfo.name) + " is a link to an absolute path")


class LinkOutsideDestinationError(FilterError):
    def __init__(self, tarinfo, path):
        self.tarinfo = tarinfo
        self._path = path
        super().__init__(repr(tarinfo.name) + " would link to " + repr(path) + ", which is outside the destination")


# ── number and string fields ────────────────────────────────────────────────
def stn(s, length, encoding, errors):
    """Convert a string to a null-terminated bytes object."""
    if s is none:
        raise ValueError("metadata cannot contain None")
    var b = s.encode(encoding, errors if errors != "surrogateescape" else "strict")
    return b[:length] + (length - len(b)) * NUL


def nts(s, encoding, errors):
    """Convert a null-terminated bytes object to a string."""
    var p = s.find(b"\x00")
    if p != -1:
        s = s[:p]
    return bytes(s).decode(encoding, errors if errors != "surrogateescape" else "replace")


def nti(s):
    """Convert a number field to a python number."""
    if s[0] in (0o200, 0o377):
        var n = 0
        for i in range(len(s) - 1):
            n = n << 8
            n = n + s[i + 1]
        if s[0] == 0o377:
            n = -(256 ** (len(s) - 1) - n)
        return n
    var t = ""
    try:
        t = nts(s, "ascii", "strict")
    except UnicodeDecodeError:
        raise InvalidHeaderError("invalid header") from None
    t = t.strip()
    if t == "":
        return 0
    for ch in t:
        if ch not in "01234567":
            raise InvalidHeaderError("invalid header")
    return int(t, 8)


def itn(n, digits=8, format=DEFAULT_FORMAT):
    """Convert a python number to a number field."""
    var original_n = n
    n = int(n)
    if 0 <= n < 8 ** (digits - 1):
        return ("%0*o" % (digits - 1, n)).encode("ascii") + NUL
    elif format == GNU_FORMAT and -256 ** (digits - 1) <= n < 256 ** (digits - 1):
        var s = bytearray()
        if n >= 0:
            s.append(0o200)
        else:
            s.append(0o377)
            n = 256 ** digits + n
        var tail = []
        for i in range(digits - 1):
            tail.append(n & 0o377)
            n = n >> 8
        tail.reverse()
        s.extend(bytes(tail))
        return bytes(s)
    raise ValueError("overflow in number field")


def calc_chksums(buf):
    """Calculate the checksum for a member's header by summing up all
    characters except for the chksum field which is treated as if it was
    filled with spaces."""
    var unsigned_chksum = 256
    var signed_chksum = 256
    for i in range(148):
        var c = buf[i]
        unsigned_chksum = unsigned_chksum + c
        signed_chksum = signed_chksum + (c - 256 if c > 127 else c)
    for i in range(156, 512):
        var c = buf[i]
        unsigned_chksum = unsigned_chksum + c
        signed_chksum = signed_chksum + (c - 256 if c > 127 else c)
    return unsigned_chksum, signed_chksum


def copyfileobj(src, dst, length=none, exception=OSError, bufsize=none):
    """Copy length bytes from fileobj src to fileobj dst. If length is None,
    copy the entire content."""
    bufsize = bufsize or 16 * 1024
    if length == 0:
        return
    if length is none:
        while true:
            var buf = src.read(bufsize)
            if not buf:
                break
            dst.write(buf)
        return
    var left = length
    while left > 0:
        var buf = src.read(min(bufsize, left))
        if len(buf) == 0:
            raise exception("unexpected end of data")
        dst.write(buf)
        left = left - len(buf)


def _filemode(mode):
    var kinds = [(0o140000, "s"), (0o120000, "l"), (0o100000, "-"), (0o060000, "b"), (0o040000, "d"),
                 (0o020000, "c"), (0o010000, "p")]
    var k = "-"
    for pair in kinds:
        if (mode & 0o170000) == pair[0]:
            k = pair[1]
            break
    var out = k
    var triples = [(0o400, "r"), (0o200, "w"), (0o100, "x", 0o4000, "s", "S"), (0o40, "r"), (0o20, "w"),
                   (0o10, "x", 0o2000, "s", "S"), (0o4, "r"), (0o2, "w"), (0o1, "x", 0o1000, "t", "T")]
    for t in triples:
        if len(t) == 2:
            out = out + (t[1] if mode & t[0] else "-")
        else:
            var x = mode & t[0]
            var special = mode & t[2]
            if special:
                out = out + (t[3] if x else t[4])
            else:
                out = out + ("x" if x else "-")
    return out


# ── the in-archive file object ──────────────────────────────────────────────
class ExFileObject(io.BufferedIOBase):
    """The data of a member (TarFile.extractfile): read, readline, seek."""

    def __init__(self, tarfile, tarinfo):
        self.fileobj = tarfile.fileobj
        self.offset = tarinfo.offset_data
        self.size = tarinfo.size
        self.name = tarinfo.name
        self.position = 0
        self._closed = false
        self.mode = "rb"

    @property
    def closed(self):
        return self._closed

    def readable(self):
        return true

    def writable(self):
        return false

    def seekable(self):
        return self.fileobj.seekable() if hasattr(self.fileobj, "seekable") else false

    def tell(self):
        if self._closed:
            raise ValueError("I/O operation on closed file")
        return self.position

    def seek(self, position, whence=io.SEEK_SET):
        if self._closed:
            raise ValueError("I/O operation on closed file")
        if whence == io.SEEK_SET:
            self.position = min(max(position, 0), self.size)
        elif whence == io.SEEK_CUR:
            if position < 0:
                self.position = max(self.position + position, 0)
            else:
                self.position = min(self.position + position, self.size)
        elif whence == io.SEEK_END:
            self.position = max(min(self.size + position, self.size), 0)
        else:
            raise ValueError("Invalid argument")
        return self.position

    def read(self, size=-1):
        if self._closed:
            raise ValueError("I/O operation on closed file")
        if size is none or size < 0:
            size = self.size - self.position
        else:
            size = min(size, self.size - self.position)
        if size <= 0:
            return b""
        self.fileobj.seek(self.offset + self.position)
        var b = self.fileobj.read(size)
        if len(b) != size:
            raise ReadError("unexpected end of data")
        self.position = self.position + len(b)
        return b

    def read1(self, size=-1):
        return self.read(size)

    def peek(self, size=1):
        var pos = self.position
        var b = self.read(max(size, 1))
        self.position = pos
        return b

    def readinto(self, b):
        var d = self.read(len(b))
        b[0:len(d)] = d
        return len(d)

    def readline(self, size=-1):
        var out = b""
        while size is none or size < 0 or len(out) < size:
            var want = 512 if (size is none or size < 0) else min(512, size - len(out))
            var pos = self.position
            var chunk = self.read(want)
            if not chunk:
                break
            var nl = chunk.find(b"\n")
            if nl >= 0:
                out = out + chunk[:nl + 1]
                self.position = pos + nl + 1
                break
            out = out + chunk
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

    def close(self):
        self._closed = true

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
        return false


# ── TarInfo ─────────────────────────────────────────────────────────────────
class TarInfo:
    """Informational class which holds the details about an archive member
    given by a tar header block."""

    def __init__(self, name=""):
        self.name = name
        self.mode = 0o644
        self.uid = 0
        self.gid = 0
        self.size = 0
        self.mtime = 0
        self.chksum = 0
        self.type = REGTYPE
        self.linkname = ""
        self.uname = ""
        self.gname = ""
        self.devmajor = 0
        self.devminor = 0
        self.offset = 0
        self.offset_data = 0
        self.sparse = none
        self.pax_headers = {}
        self._link_target = none

    @property
    def path(self):
        """In pax headers, "name" is called "path"."""
        return self.name

    @path.setter
    def path(self, name):
        self.name = name

    @property
    def linkpath(self):
        """In pax headers, "linkname" is called "linkpath"."""
        return self.linkname

    @linkpath.setter
    def linkpath(self, linkname):
        self.linkname = linkname

    def __repr__(self):
        return "<" + self.__class__.__name__ + " " + repr(self.name) + " at " + hex(id(self)) + ">"

    def replace(self, name=none, mtime=none, mode=none, linkname=none, uid=none, gid=none, uname=none,
                gname=none, deep=true, **kw):
        """Return a deep copy of self with the given attributes replaced."""
        var result = copy.deepcopy(self) if deep else copy.copy(self)
        var given = {"name": name, "mtime": mtime, "mode": mode, "linkname": linkname, "uid": uid, "gid": gid,
                     "uname": uname, "gname": gname}
        for k in given:
            if given[k] is not none:
                setattr(result, k, given[k])
        for k in kw:
            setattr(result, k, kw[k])
        return result

    def _replace_none(self, attrs):
        # (the filters set fields to None: _KEEP above stands for "unchanged")
        var result = copy.copy(self)
        for k in attrs:
            setattr(result, k, attrs[k])
        return result

    def get_info(self):
        """Return the TarInfo's attributes as a dictionary."""
        var mode = none if self.mode is none else self.mode & 0o7777
        var info = {"name": self.name, "mode": mode, "uid": self.uid, "gid": self.gid, "size": self.size,
                    "mtime": self.mtime, "chksum": self.chksum, "type": self.type, "linkname": self.linkname,
                    "uname": self.uname, "gname": self.gname, "devmajor": self.devmajor, "devminor": self.devminor}
        if info["type"] == DIRTYPE and not info["name"].endswith("/"):
            info["name"] = info["name"] + "/"
        return info

    def tobuf(self, format=DEFAULT_FORMAT, encoding=ENCODING, errors="surrogateescape"):
        """Return a tar header as a string of 512 byte blocks."""
        var info = self.get_info()
        for name in info:
            if info[name] is none:
                raise ValueError(name + " may not be None")
        if format == USTAR_FORMAT:
            return self.create_ustar_header(info, encoding, errors)
        elif format == GNU_FORMAT:
            return self.create_gnu_header(info, encoding, errors)
        elif format == PAX_FORMAT:
            return self.create_pax_header(info, encoding)
        raise ValueError("invalid format")

    def create_ustar_header(self, info, encoding, errors):
        info["magic"] = POSIX_MAGIC
        if len(info["linkname"].encode(encoding)) > LENGTH_LINK:
            raise ValueError("linkname is too long")
        if len(info["name"].encode(encoding)) > LENGTH_NAME:
            var pn = self._posix_split_name(info["name"], encoding, errors)
            info["prefix"] = pn[0]
            info["name"] = pn[1]
        return TarInfo._create_header(info, USTAR_FORMAT, encoding, errors)

    def create_gnu_header(self, info, encoding, errors):
        info["magic"] = GNU_MAGIC
        var buf = b""
        if len(info["linkname"].encode(encoding)) > LENGTH_LINK:
            buf = buf + TarInfo._create_gnu_long_header(info["linkname"], GNUTYPE_LONGLINK, encoding, errors)
        if len(info["name"].encode(encoding)) > LENGTH_NAME:
            buf = buf + TarInfo._create_gnu_long_header(info["name"], GNUTYPE_LONGNAME, encoding, errors)
        return buf + TarInfo._create_header(info, GNU_FORMAT, encoding, errors)

    def create_pax_header(self, info, encoding):
        info["magic"] = POSIX_MAGIC
        var pax_headers = dict(self.pax_headers)
        for spec in (("name", "path", LENGTH_NAME), ("linkname", "linkpath", LENGTH_LINK),
                     ("uname", "uname", 32), ("gname", "gname", 32)):
            var name = spec[0]
            var hname = spec[1]
            var length = spec[2]
            if hname in pax_headers:
                continue
            try:
                info[name].encode("ascii", "strict")
            except UnicodeEncodeError:
                pax_headers[hname] = info[name]
                continue
            if len(info[name]) > length:
                pax_headers[hname] = info[name]
        for spec in (("uid", 8), ("gid", 8), ("size", 12), ("mtime", 12)):
            var name = spec[0]
            var digits = spec[1]
            var needs_pax = false
            var val = info[name]
            var val_is_float = isinstance(val, float)
            var val_int = round(val) if val_is_float else val
            if not 0 <= val_int < 8 ** (digits - 1):
                info[name] = 0
                needs_pax = true
            elif val_is_float:
                info[name] = val_int
                needs_pax = true
            if needs_pax and name not in pax_headers:
                pax_headers[name] = str(val)
        var buf = b""
        if pax_headers:
            buf = TarInfo._create_pax_generic_header(pax_headers, XHDTYPE, encoding)
        return buf + TarInfo._create_header(info, USTAR_FORMAT, "ascii", "replace")

    @classmethod
    def create_pax_global_header(cls, pax_headers):
        """Return the object as a pax global header block sequence."""
        return cls._create_pax_generic_header(pax_headers, XGLTYPE, "utf-8")

    def _posix_split_name(self, name, encoding, errors):
        var components = name.split("/")
        for i in range(1, len(components)):
            var prefix = "/".join(components[:i])
            var rest = "/".join(components[i:])
            if len(prefix.encode(encoding)) <= LENGTH_PREFIX and len(rest.encode(encoding)) <= LENGTH_NAME:
                return prefix, rest
        raise ValueError("name is too long")

    @staticmethod
    def _create_header(info, format, encoding, errors):
        var filetype = info.get("type", REGTYPE)
        if filetype is none:
            raise ValueError("TarInfo.type must not be None")
        var has_device_fields = info.get("type") in (CHRTYPE, BLKTYPE)
        var devmajor = none
        var devminor = none
        if has_device_fields:
            devmajor = itn(info.get("devmajor", 0), 8, format)
            devminor = itn(info.get("devminor", 0), 8, format)
        else:
            devmajor = stn("", 8, encoding, errors)
            devminor = stn("", 8, encoding, errors)
        var parts = [stn(info.get("name", ""), 100, encoding, errors), itn(info.get("mode", 0) & 0o7777, 8, format),
                     itn(info.get("uid", 0), 8, format), itn(info.get("gid", 0), 8, format),
                     itn(info.get("size", 0), 12, format), itn(info.get("mtime", 0), 12, format), b"        ",
                     filetype, stn(info.get("linkname", ""), 100, encoding, errors), info.get("magic", POSIX_MAGIC),
                     stn(info.get("uname", ""), 32, encoding, errors), stn(info.get("gname", ""), 32, encoding, errors),
                     devmajor, devminor, stn(info.get("prefix", ""), 155, encoding, errors)]
        var buf = b"".join(parts)
        buf = buf + NUL * (BLOCKSIZE - len(buf))
        var chksum = calc_chksums(buf)[0]
        return buf[:-364] + ("%06o" % chksum).encode("ascii") + NUL + buf[-357:]

    @staticmethod
    def _create_payload(payload):
        var remainder = len(payload) % BLOCKSIZE
        if remainder > 0:
            payload = payload + (BLOCKSIZE - remainder) * NUL
        return payload

    @classmethod
    def _create_gnu_long_header(cls, name, type, encoding, errors):
        var bname = name.encode(encoding) + NUL
        var info = {"name": "././@LongLink", "type": type, "size": len(bname), "magic": GNU_MAGIC}
        return cls._create_header(info, USTAR_FORMAT, encoding, errors) + cls._create_payload(bname)

    @classmethod
    def _create_pax_generic_header(cls, pax_headers, type, encoding):
        var records = b""
        for keyword in pax_headers:
            var kb = keyword.encode("utf-8")
            var vb = pax_headers[keyword].encode("utf-8")
            var l = len(kb) + len(vb) + 3
            var n = 0
            var p = 0
            while true:
                n = l + len(str(p))
                if n == p:
                    break
                p = n
            records = records + str(p).encode("ascii") + b" " + kb + b"=" + vb + b"\n"
        var info = {"name": "././@PaxHeader", "type": type, "size": len(records), "magic": POSIX_MAGIC}
        return cls._create_header(info, USTAR_FORMAT, "ascii", "replace") + cls._create_payload(records)

    @classmethod
    def frombuf(cls, buf, encoding, errors):
        """Construct a TarInfo object from a 512 byte bytes object."""
        if len(buf) == 0:
            raise EmptyHeaderError("empty header")
        if len(buf) != BLOCKSIZE:
            raise TruncatedHeaderError("truncated header")
        if buf.count(NUL) == BLOCKSIZE:
            raise EOFHeaderError("end of file header")
        var chksum = nti(buf[148:156])
        if chksum not in calc_chksums(buf):
            raise InvalidHeaderError("bad checksum")
        var obj = cls()
        obj.name = nts(buf[0:100], encoding, errors)
        obj.mode = nti(buf[100:108])
        obj.uid = nti(buf[108:116])
        obj.gid = nti(buf[116:124])
        obj.size = nti(buf[124:136])
        obj.mtime = nti(buf[136:148])
        obj.chksum = chksum
        obj.type = bytes(buf[156:157])
        obj.linkname = nts(buf[157:257], encoding, errors)
        obj.uname = nts(buf[265:297], encoding, errors)
        obj.gname = nts(buf[297:329], encoding, errors)
        obj.devmajor = nti(buf[329:337])
        obj.devminor = nti(buf[337:345])
        var prefix = nts(buf[345:500], encoding, errors)
        if obj.type == AREGTYPE and obj.name.endswith("/"):
            obj.type = DIRTYPE
        if obj.isdir():
            obj.name = obj.name.rstrip("/")
        if prefix and obj.type not in GNU_TYPES:
            obj.name = prefix + "/" + obj.name
        return obj

    @classmethod
    def fromtarfile(cls, tarfile):
        """Return the next TarInfo object from TarFile object tarfile."""
        var buf = tarfile.fileobj.read(BLOCKSIZE)
        var obj = cls.frombuf(buf, tarfile.encoding, tarfile.errors)
        obj.offset = tarfile.fileobj.tell() - BLOCKSIZE
        return obj._proc_member(tarfile)

    def _proc_member(self, tarfile):
        if self.type in (GNUTYPE_LONGNAME, GNUTYPE_LONGLINK):
            return self._proc_gnulong(tarfile)
        elif self.type in (XHDTYPE, XGLTYPE, SOLARIS_XHDTYPE):
            return self._proc_pax(tarfile)
        return self._proc_builtin(tarfile)

    def _proc_builtin(self, tarfile):
        self.offset_data = tarfile.fileobj.tell()
        var offset = self.offset_data
        if self.isreg() or self.type not in SUPPORTED_TYPES:
            offset = offset + self._block(self.size)
        tarfile.offset = offset
        self._apply_pax_info(tarfile.pax_headers, tarfile.encoding, tarfile.errors)
        if self.isdir():
            self.name = self.name.rstrip("/")
        return self

    def _proc_gnulong(self, tarfile):
        var buf = tarfile.fileobj.read(self._block(self.size))
        var nxt = none
        try:
            nxt = self.fromtarfile(tarfile)
        except HeaderError as e:
            raise SubsequentHeaderError(str(e)) from None
        nxt.offset = self.offset
        if self.type == GNUTYPE_LONGNAME:
            nxt.name = nts(buf, tarfile.encoding, tarfile.errors)
        elif self.type == GNUTYPE_LONGLINK:
            nxt.linkname = nts(buf, tarfile.encoding, tarfile.errors)
        if nxt.isdir() and nxt.name.endswith("/"):
            nxt.name = nxt.name[:-1]
        return nxt

    def _proc_pax(self, tarfile):
        var buf = tarfile.fileobj.read(self._block(self.size))
        var pax_headers = tarfile.pax_headers if self.type == XGLTYPE else dict(tarfile.pax_headers)
        var pos = 0
        var raw_headers = []
        while len(buf) > pos and buf[pos] != 0:
            var match = _header_length_prefix_re.match(buf, pos)
            if not match:
                raise InvalidHeaderError("invalid header")
            var length = 0
            try:
                length = int(match.group(1))
            except ValueError:
                raise InvalidHeaderError("invalid header") from None
            if length < 5 or pos + length > len(buf):
                raise InvalidHeaderError("invalid header")
            var end_off = match.start(1) + length - 1
            var kv = buf[match.end(1) + 1:end_off]
            var eq = kv.find(b"=")
            if eq <= 0 or buf[end_off] != 0x0A:
                raise InvalidHeaderError("invalid header")
            raw_headers.append((kv[:eq], kv[eq + 1:]))
            pos = pos + length
        for kvp in raw_headers:
            var keyword = bytes(kvp[0]).decode("utf-8", "replace")
            pax_headers[keyword] = bytes(kvp[1]).decode("utf-8", "replace")
        var nxt = none
        try:
            nxt = self.fromtarfile(tarfile)
        except HeaderError as e:
            raise SubsequentHeaderError(str(e)) from None
        if self.type == XHDTYPE or self.type == SOLARIS_XHDTYPE:
            nxt._apply_pax_info(pax_headers, tarfile.encoding, tarfile.errors)
            nxt.offset = self.offset
            if "size" in pax_headers:
                var offset = nxt.offset_data
                if nxt.isreg() or nxt.type not in SUPPORTED_TYPES:
                    offset = offset + nxt._block(nxt.size)
                tarfile.offset = offset
        return nxt

    def _apply_pax_info(self, pax_headers, encoding, errors):
        for keyword in pax_headers:
            var value = pax_headers[keyword]
            if keyword == "GNU.sparse.name":
                self.path = value
            elif keyword == "GNU.sparse.size" or keyword == "GNU.sparse.realsize":
                self.size = int(value)
            elif keyword in PAX_FIELDS:
                if keyword in PAX_NUMBER_FIELDS:
                    try:
                        value = PAX_NUMBER_FIELDS[keyword](value)
                    except ValueError:
                        value = 0
                if keyword == "path":
                    value = value.rstrip("/")
                setattr(self, keyword, value)
        self.pax_headers = dict(pax_headers)

    def _block(self, count):
        """Round up a byte count by BLOCKSIZE and return it."""
        var blocks = count // BLOCKSIZE
        var remainder = count % BLOCKSIZE
        if remainder:
            blocks = blocks + 1
        return blocks * BLOCKSIZE

    def isreg(self):
        """Return True if the Tarinfo object is a regular file."""
        return self.type in REGULAR_TYPES

    def isfile(self):
        """Return True if the Tarinfo object is a regular file."""
        return self.isreg()

    def isdir(self):
        return self.type == DIRTYPE

    def issym(self):
        return self.type == SYMTYPE

    def islnk(self):
        return self.type == LNKTYPE

    def ischr(self):
        return self.type == CHRTYPE

    def isblk(self):
        return self.type == BLKTYPE

    def isfifo(self):
        return self.type == FIFOTYPE

    def issparse(self):
        return self.sparse is not none

    def isdev(self):
        return self.type in (CHRTYPE, BLKTYPE, FIFOTYPE)


# ── extraction filters (PEP 706) ────────────────────────────────────────────
def _realpath(p):
    return os.path.realpath(p)


def _commonpath(a, b):
    return os.path.commonpath([a, b])


def _get_filtered_attrs(member, dest_path, for_data=true):
    var new_attrs = {}
    var name = member.name
    dest_path = _realpath(dest_path)
    if name.startswith("/") or name.startswith(os.sep):
        name = member.path.lstrip("/" + os.sep)
        new_attrs["name"] = name
    if os.path.isabs(name):
        raise AbsolutePathError(member)
    var target_path = _realpath(os.path.join(dest_path, name))
    if _commonpath(target_path, dest_path) != dest_path:
        raise OutsideDestinationError(member, target_path)
    var mode = member.mode
    if mode is not none:
        mode = mode & 0o755
        if for_data:
            if member.isreg() or member.islnk():
                if not mode & 0o100:
                    mode = mode & ~0o111
                mode = mode | 0o600
            elif member.isdir() or member.issym():
                mode = none
            else:
                raise SpecialFileError(member)
        if mode != member.mode:
            new_attrs["mode"] = mode
    if for_data:
        if member.uid is not none:
            new_attrs["uid"] = none
        if member.gid is not none:
            new_attrs["gid"] = none
        if member.uname is not none:
            new_attrs["uname"] = none
        if member.gname is not none:
            new_attrs["gname"] = none
        if member.islnk() or member.issym():
            if os.path.isabs(member.linkname):
                raise AbsoluteLinkError(member)
            if member.issym():
                target_path = os.path.join(dest_path, os.path.dirname(name), member.linkname)
            else:
                target_path = os.path.join(dest_path, member.linkname)
            target_path = _realpath(target_path)
            if _commonpath(target_path, dest_path) != dest_path:
                raise LinkOutsideDestinationError(member, target_path)
    return new_attrs


def fully_trusted_filter(member, dest_path):
    return member


def tar_filter(member, dest_path):
    var new_attrs = _get_filtered_attrs(member, dest_path, false)
    if new_attrs:
        return member._replace_none(new_attrs)
    return member


def data_filter(member, dest_path):
    var new_attrs = _get_filtered_attrs(member, dest_path, true)
    if new_attrs:
        return member._replace_none(new_attrs)
    return member


_NAMED_FILTERS = {"fully_trusted": fully_trusted_filter, "tar": tar_filter, "data": data_filter}


# ── the stream modes ("r|", "w|gz") ────────────────────────────────────────
class _Stream:
    """A file object that reads or writes a tar stream block by block,
    through gzip when asked; it can only move forward."""

    def __init__(self, name, mode, comptype, fileobj, bufsize, compresslevel):
        self._extfileobj = true
        if fileobj is none:
            fileobj = _builtin_open(name, mode + "b")
            self._extfileobj = false
        if comptype == "*":
            # detect: the first bytes tell
            var head = fileobj.read(2) if hasattr(fileobj, "read") else b""
            self._pending = head
            comptype = "gz" if head == b"\x1f\x8b" else "tar"
        else:
            self._pending = b""
        self.name = name or ""
        self.mode = mode
        self.comptype = comptype
        self.fileobj = fileobj
        self.bufsize = bufsize
        self.buf = b""
        self.pos = 0
        self.closed = false
        self.compresslevel = compresslevel
        if comptype == "bz2" or comptype == "xz":
            raise CompressionError(("bz2" if comptype == "bz2" else "lzma") + " module is not available")
        if comptype not in ("tar", "gz"):
            raise CompressionError("unknown compression type " + repr(comptype))
        if comptype == "gz":
            self.crc = 0
            if mode == "r":
                self._dec = none
                self._init_read_gz()
            else:
                self.cmp = zlib.compressobj(compresslevel, zlib.DEFLATED, -zlib.MAX_WBITS, zlib.DEF_MEM_LEVEL, 0)
                self._init_write_gz()

    def _raw_read(self, n):
        if self._pending:
            var take = self._pending[:n]
            self._pending = self._pending[n:]
            if len(take) < n:
                take = take + self.fileobj.read(n - len(take))
            return take
        return self.fileobj.read(n)

    def _init_write_gz(self):
        var ts = int(time.time())
        var header = b"\x1f\x8b\x08\x08" + bytes([ts & 255, (ts >> 8) & 255, (ts >> 16) & 255, (ts >> 24) & 255]) + b"\x02\xff"
        var nm = os.path.basename(self.name)
        if nm.endswith(".gz"):
            nm = nm[:-3]
        self.fileobj.write(header + nm.encode("iso-8859-1", "replace") + NUL)

    def write(self, s):
        if self.comptype == "gz":
            self.crc = zlib.crc32(s, self.crc)
        self.pos = self.pos + len(s)
        if self.comptype != "tar":
            s = self.cmp.compress(s)
        self.fileobj.write(s)

    def close(self):
        if self.closed:
            return
        self.closed = true
        try:
            if self.mode == "w" and self.comptype != "tar":
                self.fileobj.write(self.cmp.flush())
                var c = self.crc & 0xffffffff
                var p = self.pos & 0xffffffff
                self.fileobj.write(bytes([c & 255, (c >> 8) & 255, (c >> 16) & 255, (c >> 24) & 255,
                                          p & 255, (p >> 8) & 255, (p >> 16) & 255, (p >> 24) & 255]))
        finally:
            if not self._extfileobj:
                self.fileobj.close()

    def _init_read_gz(self):
        self._dec = zlib.decompressobj(-zlib.MAX_WBITS)
        if self._raw_read(2) != b"\x1f\x8b":
            raise ReadError("not a gzip file")
        if self._raw_read(1) != b"\x08":
            raise CompressionError("unsupported compression method")
        var flag = self._raw_read(1)[0]
        self._raw_read(6)
        if flag & 4:
            var xl = self._raw_read(2)
            self._raw_read(xl[0] + 256 * xl[1])
        if flag & 8:
            while true:
                var s = self._raw_read(1)
                if not s or s == NUL:
                    break
        if flag & 16:
            while true:
                var s = self._raw_read(1)
                if not s or s == NUL:
                    break
        if flag & 2:
            self._raw_read(2)

    def tell(self):
        return self.pos

    def seekable(self):
        return false

    def seek(self, pos=0):
        if pos - self.pos >= 0:
            var blocks = (pos - self.pos) // self.bufsize
            for i in range(blocks):
                self.read(self.bufsize)
            self.read((pos - self.pos) % self.bufsize)
        else:
            raise StreamError("seeking backwards is not allowed")
        return self.pos

    def _read_some(self):
        var raw = self._raw_read(self.bufsize)
        if self.comptype == "tar":
            return raw
        if not raw:
            return b""
        try:
            return self._dec.decompress(raw)
        except zlib.error as e:
            raise ReadError("invalid compressed data") from e

    def read(self, size):
        var out = self.buf
        while len(out) < size:
            var more = self._read_some()
            if not more:
                if self.comptype == "gz" and self._dec is not none and not self._dec.eof:
                    pass
                break
            out = out + more
        self.buf = out[size:]
        var t = out[:size]
        self.pos = self.pos + len(t)
        return t


# ── TarFile ─────────────────────────────────────────────────────────────────
class TarFile:
    """The TarFile Class provides an interface to tar archives."""

    debug = 0
    dereference = false
    ignore_zeros = false
    errorlevel = 1
    format = DEFAULT_FORMAT
    encoding = ENCODING
    errors = none
    tarinfo = TarInfo
    fileobject = ExFileObject
    extraction_filter = none

    def __init__(self, name=none, mode="r", fileobj=none, format=none, tarinfo=none, dereference=none,
                 ignore_zeros=none, encoding=none, errors="surrogateescape", pax_headers=none, debug=none,
                 errorlevel=none, copybufsize=none, stream=false):
        var modes = {"r": "rb", "a": "r+b", "w": "wb", "x": "xb"}
        if mode not in modes:
            raise ValueError("mode must be 'r', 'a', 'w' or 'x'")
        self.mode = mode
        self._mode = modes[mode]
        if not fileobj:
            if self.mode == "a" and not os.path.exists(name):
                self.mode = "w"
                self._mode = "wb"
            fileobj = _builtin_open(name, self._mode)
            self._extfileobj = false
        else:
            if name is none and hasattr(fileobj, "name") and (isinstance(fileobj.name, str) or isinstance(fileobj.name, bytes)):
                name = fileobj.name
            self._extfileobj = true
        self.name = os.path.abspath(name) if name else none
        self.fileobj = fileobj
        self.stream = stream
        if format is not none:
            self.format = format
        if tarinfo is not none:
            self.tarinfo = tarinfo
        if dereference is not none:
            self.dereference = dereference
        if ignore_zeros is not none:
            self.ignore_zeros = ignore_zeros
        if encoding is not none:
            self.encoding = encoding
        self.errors = errors
        if pax_headers is not none and self.format == PAX_FORMAT:
            self.pax_headers = pax_headers
        else:
            self.pax_headers = {}
        if debug is not none:
            self.debug = debug
        if errorlevel is not none:
            self.errorlevel = errorlevel
        self.copybufsize = copybufsize
        self.closed = false
        self.members = []
        self._loaded = false
        self.offset = self.fileobj.tell()
        self.inodes = {}
        self.firstmember = none
        try:
            if self.mode == "r":
                self.firstmember = none
                self.firstmember = self.next()
            if self.mode == "a":
                while true:
                    self.fileobj.seek(self.offset)
                    try:
                        var ti = self.tarinfo.fromtarfile(self)
                        self.members.append(ti)
                    except EOFHeaderError:
                        self.fileobj.seek(self.offset)
                        break
                    except HeaderError as e:
                        raise ReadError(str(e)) from None
            if self.mode in ("a", "w", "x"):
                self._loaded = true
                if self.pax_headers:
                    var buf = self.tarinfo.create_pax_global_header(dict(self.pax_headers))
                    self.fileobj.write(buf)
                    self.offset = self.offset + len(buf)
        except Exception:
            if not self._extfileobj:
                self.fileobj.close()
            self.closed = true
            raise

    # ── constructors ────────────────────────────────────────────────────
    OPEN_METH = {"tar": "taropen", "gz": "gzopen", "bz2": "bz2open", "xz": "xzopen"}

    @classmethod
    def open(cls, name=none, mode="r", fileobj=none, bufsize=RECORDSIZE, **kwargs):
        """Open a tar archive for reading, writing or appending."""
        if not name and not fileobj:
            raise ValueError("nothing to open")
        if mode in ("r", "r:*"):
            var error_msgs = []
            for comptype in ["gz", "bz2", "xz", "tar"]:
                var saved_pos = none
                if fileobj is not none:
                    saved_pos = fileobj.tell()
                try:
                    return cls._open_meth(comptype, name, "r", fileobj, kwargs)
                except (ReadError, CompressionError) as e:
                    error_msgs.append("- method " + comptype + ": " + repr(e))
                    if fileobj is not none:
                        fileobj.seek(saved_pos)
                    continue
            raise ReadError("file could not be opened successfully:\n" + "\n".join(error_msgs))
        elif ":" in mode:
            var parts = mode.split(":", 1)
            var filemode = parts[0] or "r"
            var comptype = parts[1] or "tar"
            if comptype not in cls.OPEN_METH:
                raise CompressionError("unknown compression type " + repr(comptype))
            return cls._open_meth(comptype, name, filemode, fileobj, kwargs)
        elif "|" in mode:
            var parts = mode.split("|", 1)
            var filemode = parts[0] or "r"
            var comptype = parts[1] or "tar"
            if filemode not in ("r", "w"):
                raise ValueError("mode must be 'r' or 'w'")
            var compresslevel = kwargs.pop("compresslevel", 9)
            var stream = _Stream(name, filemode, comptype, fileobj, bufsize, compresslevel)
            var t = none
            try:
                t = cls(name, filemode, stream, **kwargs)
            except Exception:
                stream.close()
                raise
            t._extfileobj = false
            return t
        elif mode in ("a", "w", "x"):
            return cls.taropen(name, mode, fileobj, **kwargs)
        raise ValueError("undiscernible mode")

    @classmethod
    def _open_meth(cls, comptype, name, mode, fileobj, kwargs):
        if comptype == "tar":
            return cls.taropen(name, mode, fileobj, **kwargs)
        if comptype == "gz":
            return cls.gzopen(name, mode, fileobj, **kwargs)
        if comptype == "bz2":
            raise CompressionError("bz2 module is not available")
        raise CompressionError("lzma module is not available")

    @classmethod
    def taropen(cls, name, mode="r", fileobj=none, **kwargs):
        """Open uncompressed tar archive name for reading or writing."""
        if mode not in ("r", "a", "w", "x"):
            raise ValueError("mode must be 'r', 'a', 'w' or 'x'")
        return cls(name, mode, fileobj, **kwargs)

    @classmethod
    def gzopen(cls, name, mode="r", fileobj=none, compresslevel=9, **kwargs):
        """Open gzip compressed tar archive name for reading or writing."""
        if mode not in ("r", "w", "x"):
            raise ValueError("mode must be 'r', 'w' or 'x'")
        import gzip
        var gz = none
        try:
            gz = gzip.GzipFile(name, mode + "b", compresslevel, fileobj)
        except OSError as e:
            if fileobj is not none and mode == "r":
                raise ReadError("not a gzip file") from e
            raise
        var t = none
        try:
            if mode == "r":
                # a gzip member must start here
                var head = gz.peek(1)
            t = cls.taropen(name, mode, gz, **kwargs)
        except (OSError, EOFError, zlib.error) as e:
            gz.close()
            if mode == "r":
                raise ReadError("not a gzip file") from e
            raise
        except Exception:
            gz.close()
            raise
        t._extfileobj = false
        return t

    @classmethod
    def bz2open(cls, name, mode="r", fileobj=none, compresslevel=9, **kwargs):
        raise CompressionError("bz2 module is not available")

    @classmethod
    def xzopen(cls, name, mode="r", fileobj=none, preset=none, **kwargs):
        raise CompressionError("lzma module is not available")

    # ── the members ─────────────────────────────────────────────────────
    def close(self):
        """Close the TarFile. In write-mode, two finishing zero blocks are
        appended to the archive."""
        if self.closed:
            return
        self.closed = true
        try:
            if self.mode in ("a", "w", "x"):
                self.fileobj.write(NUL * (BLOCKSIZE * 2))
                self.offset = self.offset + BLOCKSIZE * 2
                var remainder = self.offset % RECORDSIZE
                if remainder > 0:
                    self.fileobj.write(NUL * (RECORDSIZE - remainder))
        finally:
            if not self._extfileobj:
                self.fileobj.close()

    def getmember(self, name):
        """Return a TarInfo object for member 'name'."""
        var tarinfo = self._getmember(name.rstrip("/"))
        if tarinfo is none:
            raise KeyError("filename " + repr(name) + " not found")
        return tarinfo

    def getmembers(self):
        """Return the members of the archive as a list of TarInfo objects."""
        self._check()
        if not self._loaded:
            self._load()
        return self.members

    def getnames(self):
        """Return the members of the archive as a list of their names."""
        return [ti.name for ti in self.getmembers()]

    def gettarinfo(self, name=none, arcname=none, fileobj=none):
        """Create a TarInfo object from the result of os.stat or equivalent
        on an existing file."""
        self._check("awx")
        if fileobj is not none:
            name = fileobj.name
        if arcname is none:
            arcname = name
        arcname = arcname.replace(os.sep, "/")
        arcname = arcname.lstrip("/")
        var tarinfo = self.tarinfo()
        tarinfo.tarfile = self
        var statres = none
        if fileobj is none:
            statres = os.stat(name) if self.dereference else os.lstat(name)
        else:
            statres = os.stat(name)
        var linkname = ""
        var stmd = statres.st_mode
        var kind = stmd & 0o170000
        var type = none
        if kind == 0o100000:
            var inode = (statres.st_ino, statres.st_dev)
            if not self.dereference and statres.st_nlink > 1 and inode in self.inodes and arcname != self.inodes[inode]:
                type = LNKTYPE
                linkname = self.inodes[inode]
            else:
                type = REGTYPE
                if inode[0]:
                    self.inodes[inode] = arcname
        elif kind == 0o040000:
            type = DIRTYPE
        elif kind == 0o010000:
            type = FIFOTYPE
        elif kind == 0o120000:
            type = SYMTYPE
            linkname = os.readlink(name)
        elif kind == 0o020000:
            type = CHRTYPE
        elif kind == 0o060000:
            type = BLKTYPE
        else:
            return none
        tarinfo.name = arcname
        tarinfo.mode = stmd
        tarinfo.uid = statres.st_uid
        tarinfo.gid = statres.st_gid
        tarinfo.size = statres.st_size if type == REGTYPE else 0
        tarinfo.mtime = statres.st_mtime
        tarinfo.type = type
        tarinfo.linkname = linkname
        return tarinfo

    def list(self, verbose=true, members=none):
        """Print a table of contents to sys.stdout."""
        self._check()
        if members is none:
            members = self
        for tarinfo in members:
            if verbose:
                if tarinfo.mode is none:
                    print("??????????", end=" ")
                else:
                    print(_filemode(tarinfo.mode), end=" ")
                print((tarinfo.uname or str(tarinfo.uid)) + "/" + (tarinfo.gname or str(tarinfo.gid)), end=" ")
                if tarinfo.ischr() or tarinfo.isblk():
                    print("%10s" % ("%d,%d" % (tarinfo.devmajor, tarinfo.devminor)), end=" ")
                else:
                    print("%10d" % tarinfo.size, end=" ")
                if tarinfo.mtime is none:
                    print("????-??-?? ??:??:??", end=" ")
                else:
                    print("%d-%02d-%02d %02d:%02d:%02d" % tuple(time.localtime(tarinfo.mtime))[:6], end=" ")
            print(tarinfo.name + ("/" if tarinfo.isdir() else ""), end="")
            if verbose:
                if tarinfo.issym():
                    print(" -> " + tarinfo.linkname, end="")
                if tarinfo.islnk():
                    print(" link to " + tarinfo.linkname, end="")
            print()

    def add(self, name, arcname=none, recursive=true, filter=none):
        """Add the file `name' to the archive."""
        self._check("awx")
        if arcname is none:
            arcname = name
        if self.name is not none and os.path.abspath(name) == self.name:
            return
        var tarinfo = self.gettarinfo(name, arcname)
        if tarinfo is none:
            return
        if filter is not none:
            tarinfo = filter(tarinfo)
            if tarinfo is none:
                return
        if tarinfo.isreg():
            with _builtin_open(name, "rb") as f:
                self.addfile(tarinfo, f)
        elif tarinfo.isdir():
            self.addfile(tarinfo)
            if recursive:
                for f in sorted(os.listdir(name)):
                    self.add(os.path.join(name, f), os.path.join(arcname, f), recursive, filter=filter)
        else:
            self.addfile(tarinfo)

    def addfile(self, tarinfo, fileobj=none):
        """Add the TarInfo object `tarinfo' to the archive. If `fileobj' is
        given, tarinfo.size bytes are read from it and added."""
        self._check("awx")
        tarinfo = copy.copy(tarinfo)
        var buf = tarinfo.tobuf(self.format, self.encoding, self.errors)
        self.fileobj.write(buf)
        self.offset = self.offset + len(buf)
        if fileobj is not none:
            copyfileobj(fileobj, self.fileobj, tarinfo.size, OSError, self.copybufsize)
            var blocks = tarinfo.size // BLOCKSIZE
            var remainder = tarinfo.size % BLOCKSIZE
            if remainder > 0:
                self.fileobj.write(NUL * (BLOCKSIZE - remainder))
                blocks = blocks + 1
            self.offset = self.offset + blocks * BLOCKSIZE
        self.members.append(tarinfo)

    # ── extraction ──────────────────────────────────────────────────────
    def _get_filter_function(self, filter):
        if filter is none:
            filter = self.extraction_filter
            if filter is none:
                return fully_trusted_filter
            if isinstance(filter, str):
                raise TypeError("String names are not supported for TarFile.extraction_filter. "
                                + "Use a function such as tarfile.data_filter directly.")
            return filter
        if callable(filter):
            return filter
        if filter in _NAMED_FILTERS:
            return _NAMED_FILTERS[filter]
        raise ValueError("filter " + repr(filter) + " not found")

    def extractall(self, path=".", members=none, numeric_owner=false, filter=none):
        """Extract all members from the archive to the current working
        directory and set owner, modification time and permissions on
        directories afterwards."""
        var directories = []
        var filter_function = self._get_filter_function(filter)
        if members is none:
            members = self
        for member in members:
            var tarinfo = self._get_extract_tarinfo(member, filter_function, path)
            if tarinfo is none:
                continue
            if tarinfo.isdir():
                directories.append(tarinfo)
            self._extract_one(tarinfo, path, not tarinfo.isdir(), numeric_owner)
        directories.sort(key=lambda a: a.name, reverse=true)
        for tarinfo in directories:
            var dirpath = os.path.join(path, tarinfo.name)
            try:
                self.utime(tarinfo, dirpath)
                self.chmod(tarinfo, dirpath)
            except ExtractError as e:
                self._handle_nonfatal_error(e)

    def extract(self, member, path="", set_attrs=true, numeric_owner=false, filter=none):
        """Extract a member from the archive to the current working
        directory, using its full name."""
        var filter_function = self._get_filter_function(filter)
        var tarinfo = self._get_extract_tarinfo(member, filter_function, path)
        if tarinfo is not none:
            self._extract_one(tarinfo, path, set_attrs, numeric_owner)

    def _get_extract_tarinfo(self, member, filter_function, path):
        var unfiltered = self.getmember(member) if isinstance(member, str) else member
        var filtered = none
        try:
            filtered = filter_function(unfiltered, path)
        except (OSError, FilterError) as e:
            self._handle_fatal_error(e)
        except ExtractError as e:
            self._handle_nonfatal_error(e)
        if filtered is none:
            return none
        if filtered.islnk():
            filtered = copy.copy(filtered)
            filtered._link_target = os.path.join(path, filtered.linkname)
        return filtered

    def _extract_one(self, tarinfo, path, set_attrs, numeric_owner):
        self._check("r")
        try:
            self._extract_member(tarinfo, os.path.join(path, tarinfo.name), set_attrs, numeric_owner)
        except OSError as e:
            self._handle_fatal_error(e)
        except ExtractError as e:
            self._handle_nonfatal_error(e)

    def _handle_nonfatal_error(self, e):
        if self.errorlevel > 1:
            raise e
        self._dbg(1, "tarfile: " + str(e))

    def _handle_fatal_error(self, e):
        if self.errorlevel > 0:
            raise e
        self._dbg(1, "tarfile: " + type(e).__name__ + " " + str(e))

    def extractfile(self, member):
        """Extract a member from the archive as a file object."""
        self._check("r")
        var tarinfo = self.getmember(member) if isinstance(member, str) else member
        if tarinfo.isreg() or tarinfo.type not in SUPPORTED_TYPES:
            return self.fileobject(self, tarinfo)
        elif tarinfo.islnk() or tarinfo.issym():
            if isinstance(self.fileobj, _Stream):
                raise StreamError("cannot extract (sym)link as file object")
            return self.extractfile(self._find_link_target(tarinfo))
        return none

    def _extract_member(self, tarinfo, targetpath, set_attrs=true, numeric_owner=false):
        targetpath = targetpath.rstrip("/")
        targetpath = targetpath.replace("/", os.sep)
        var upperdirs = os.path.dirname(targetpath)
        if upperdirs and not os.path.exists(upperdirs):
            os.makedirs(upperdirs)
        if tarinfo.islnk() or tarinfo.issym():
            self._dbg(1, tarinfo.name + " -> " + tarinfo.linkname)
        else:
            self._dbg(1, tarinfo.name)
        if tarinfo.isreg():
            self.makefile(tarinfo, targetpath)
        elif tarinfo.isdir():
            self.makedir(tarinfo, targetpath)
        elif tarinfo.isfifo():
            self.makefifo(tarinfo, targetpath)
        elif tarinfo.ischr() or tarinfo.isblk():
            self.makedev(tarinfo, targetpath)
        elif tarinfo.islnk() or tarinfo.issym():
            self.makelink(tarinfo, targetpath)
        elif tarinfo.type not in SUPPORTED_TYPES:
            self.makeunknown(tarinfo, targetpath)
        else:
            self.makefile(tarinfo, targetpath)
        if set_attrs:
            if not tarinfo.issym():
                self.chmod(tarinfo, targetpath)
                self.utime(tarinfo, targetpath)

    def makedir(self, tarinfo, targetpath):
        try:
            if tarinfo.mode is none:
                os.mkdir(targetpath)
            else:
                os.mkdir(targetpath, 0o700)
        except FileExistsError:
            if not os.path.isdir(targetpath):
                raise

    def makefile(self, tarinfo, targetpath):
        var source = self.fileobj
        source.seek(tarinfo.offset_data)
        with _builtin_open(targetpath, "wb") as target:
            copyfileobj(source, target, tarinfo.size, ReadError, self.copybufsize)

    def makeunknown(self, tarinfo, targetpath):
        self.makefile(tarinfo, targetpath)
        self._dbg(1, "tarfile: Unknown file type " + repr(tarinfo.type) + ", extracted as regular file.")

    def makefifo(self, tarinfo, targetpath):
        raise ExtractError("fifo not supported by system")

    def makedev(self, tarinfo, targetpath):
        raise ExtractError("special devices not supported by system")

    def makelink(self, tarinfo, targetpath):
        try:
            if tarinfo.issym():
                if os.path.islink(targetpath) or os.path.exists(targetpath):
                    os.unlink(targetpath)
                os.symlink(tarinfo.linkname, targetpath)
            else:
                if os.path.exists(tarinfo._link_target):
                    os.link(tarinfo._link_target, targetpath)
                else:
                    self._extract_member(self._find_link_target(tarinfo), targetpath)
        except OSError:
            try:
                self._extract_member(self._find_link_target(tarinfo), targetpath)
            except KeyError:
                raise ExtractError("unable to resolve link inside archive") from None

    def chown(self, tarinfo, targetpath, numeric_owner):
        pass

    def chmod(self, tarinfo, targetpath):
        if tarinfo.mode is none:
            return
        try:
            os.chmod(targetpath, tarinfo.mode)
        except OSError as e:
            raise ExtractError("could not change mode") from e

    def utime(self, tarinfo, targetpath):
        var mtime = tarinfo.mtime
        if mtime is none:
            return
        try:
            os.utime(targetpath, (mtime, mtime))
        except OSError as e:
            raise ExtractError("could not change modification time") from e

    # ── reading the archive ─────────────────────────────────────────────
    def next(self):
        """Return the next member of the archive as a TarInfo object, when
        TarFile is opened for reading. Return None if there is no more
        available."""
        self._check("ra")
        if self.firstmember is not none:
            var m = self.firstmember
            self.firstmember = none
            return m
        if self.offset != self.fileobj.tell():
            if self.offset == 0:
                return none
            self.fileobj.seek(self.offset - 1)
            if not self.fileobj.read(1):
                raise ReadError("unexpected end of data")
        var tarinfo = none
        while true:
            try:
                tarinfo = self.tarinfo.fromtarfile(self)
            except EOFHeaderError as e:
                if self.ignore_zeros:
                    self.offset = self.offset + BLOCKSIZE
                    continue
            except InvalidHeaderError as e:
                if self.ignore_zeros:
                    self.offset = self.offset + BLOCKSIZE
                    continue
                elif self.offset == 0:
                    raise ReadError(str(e)) from None
            except EmptyHeaderError:
                if self.offset == 0:
                    raise ReadError("empty file") from None
            except TruncatedHeaderError as e:
                if self.offset == 0:
                    raise ReadError(str(e)) from None
            except SubsequentHeaderError as e:
                raise ReadError(str(e)) from None
            except zlib.error as e:
                raise ReadError("zlib error: " + str(e)) from None
            break
        if tarinfo is not none:
            self.members.append(tarinfo)
        else:
            self._loaded = true
        return tarinfo

    def _getmember(self, name, tarinfo=none, normalize=false):
        var members = self.getmembers()
        var skipping = false
        if tarinfo is not none:
            try:
                var index = members.index(tarinfo)
            except ValueError:
                skipping = false
            else:
                skipping = true
                members = members[:index]
        if normalize:
            name = os.path.normpath(name)
        var i = len(members) - 1
        while i >= 0:
            var member = members[i]
            var member_name = os.path.normpath(member.name) if normalize else member.name
            if name == member_name:
                return member
            i = i - 1
        if skipping:
            raise ValueError(tarinfo)
        return none

    def _load(self):
        if not self.stream:
            while self.next() is not none:
                pass
        self._loaded = true

    def _check(self, mode=none):
        if self.closed:
            raise OSError(type(self).__name__ + " is closed")
        if mode is not none and self.mode not in mode:
            raise OSError("bad operation for mode " + repr(self.mode))

    def _find_link_target(self, tarinfo):
        var linkname = none
        var limit = none
        if tarinfo.issym():
            linkname = "/".join([p for p in [os.path.dirname(tarinfo.name), tarinfo.linkname] if p])
            limit = none
        else:
            linkname = tarinfo.linkname
            limit = tarinfo
        var member = self._getmember(linkname, limit, true)
        if member is none:
            raise KeyError("linkname " + repr(linkname) + " not found")
        return member

    def __iter__(self):
        if self._loaded:
            return iter(list(self.members))
        return _TarIter(self)

    def _dbg(self, level, msg):
        if level <= self.debug:
            import sys
            print(msg, file=sys.stderr)

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, type, value, traceback):
        if type is none:
            self.close()
        else:
            if not self._extfileobj:
                self.fileobj.close()
            self.closed = true
        return false


class _TarIter:
    def __init__(self, tf):
        self._tf = tf
        self._i = 0

    def __iter__(self):
        return self

    def __next__(self):
        var tf = self._tf
        var tarinfo = none
        if self._i == 0 and tf.firstmember is not none:
            tarinfo = tf.next()
        elif self._i < len(tf.members):
            tarinfo = tf.members[self._i]
        elif not tf._loaded:
            tarinfo = tf.next()
            if not tarinfo:
                tf._loaded = true
                raise StopIteration
        else:
            raise StopIteration
        self._i = self._i + 1
        return tarinfo


def is_tarfile(name):
    """Return True if name points to a tar archive that we are able to
    handle, else return False."""
    try:
        var t = none
        if hasattr(name, "read"):
            var pos = name.tell()
            t = open(fileobj=name)
            name.seek(pos)
        else:
            t = open(name)
        t.close()
        return true
    except TarError:
        return false


open = TarFile.open


# ── the command line ────────────────────────────────────────────────────────
def main(args=none):
    import sys
    import argparse
    var description = "A simple command-line interface for tarfile module."
    var parser = argparse.ArgumentParser(description=description)
    parser.add_argument("-v", "--verbose", action="store_true", default=false, help="Verbose output")
    parser.add_argument("--filter", metavar="<filtername>", choices=["fully_trusted", "tar", "data"],
                        help="Filter for extraction")
    var group = parser.add_mutually_exclusive_group(required=true)
    group.add_argument("-l", "--list", metavar="<tarfile>", help="Show listing of a tarfile")
    group.add_argument("-e", "--extract", nargs="+", metavar=("<tarfile>", "<output_dir>"),
                       help="Extract tarfile into target dir")
    group.add_argument("-c", "--create", nargs="+", metavar=("<name>", "<file>"),
                       help="Create tarfile from sources")
    group.add_argument("-t", "--test", metavar="<tarfile>", help="Test if a tarfile is valid")
    var a = parser.parse_args(args)
    if a.filter and a.extract is none:
        parser.exit(1, "--filter is only valid for extraction\n")
    if a.test is not none:
        var src = a.test
        if is_tarfile(src):
            with open(src, "r") as tar:
                tar.getmembers()
                print(tar.getmembers(), file=sys.stderr)
            if a.verbose:
                print(repr(src) + " is a tar archive.")
        else:
            parser.exit(1, repr(src) + " is not a tar archive.\n")
    elif a.list is not none:
        var src = a.list
        if is_tarfile(src):
            with TarFile.open(src, "r:*") as tf:
                tf.list(verbose=a.verbose)
        else:
            parser.exit(1, repr(src) + " is not a tar archive.\n")
    elif a.extract is not none:
        var src = a.extract[0]
        var curdir = "."
        if len(a.extract) == 2:
            curdir = a.extract[1]
        elif len(a.extract) != 1:
            parser.exit(1, parser.format_help())
        if is_tarfile(src):
            with TarFile.open(src, "r:*") as tf:
                tf.extractall(path=curdir, filter=a.filter)
            if a.verbose:
                var msg = repr(src) + " file is extracted" if curdir == "." else repr(src) + " file is extracted into " + repr(curdir) + " directory."
                print(msg)
        else:
            parser.exit(1, repr(src) + " is not a tar archive.\n")
    elif a.create is not none:
        var tar_name = a.create.pop(0)
        var ext = os.path.splitext(tar_name)[1]
        var compressions = {".gz": "gz", ".tgz": "gz"}
        var tar_mode = "w:" + compressions[ext] if ext in compressions else "w"
        var tar_files = a.create
        with TarFile.open(tar_name, tar_mode) as tf:
            for file_name in tar_files:
                tf.add(file_name)
        if a.verbose:
            print(repr(tar_name) + " file created.")


if __name__ == "__main__":
    main()
