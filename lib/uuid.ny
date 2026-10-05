# nython: module    (import it by name: it runs in a module scope of its own)
# lib/uuid.ny - Python's uuid (3.12): RFC 4122 UUIDs.
#
#     import uuid
#     uuid.uuid4()                                    # random
#     uuid.uuid5(uuid.NAMESPACE_DNS, "python.org")    # name-based (SHA-1)
#     u = uuid.UUID("{12345678-1234-5678-1234-567812345678}")
#     u.hex, u.int, u.bytes, u.bytes_le, u.fields, u.urn, u.version
#
# UUID from a hex string (with or without braces, hyphens, "urn:uuid:"),
# 16 bytes (big-endian or bytes_le), a 6-tuple of fields or a 128-bit int,
# optionally forcing a version; str/repr, hex, int, bytes, bytes_le,
# fields and each field (time_low, time_mid, time_hi_version,
# clock_seq_hi_variant, clock_seq_low, node, time, clock_seq), urn,
# variant, version, is_safe; comparisons and hashing by value; immutable.
# uuid1 (time-based), uuid3 (MD5), uuid4 (random, from the OS's random
# source), uuid5 (SHA-1) - uuid3/uuid5 give the same UUIDs as CPython;
# NAMESPACE_DNS/URL/OID/X500, the variant constants, SafeUUID, getnode.
#
# Differences: getnode() does not read the network interfaces' hardware
# address; like Python when that fails, it returns a random 48-bit number
# with the multicast bit set (once per process), so uuid1's node is that.
# SafeUUID is a small enum-like class (there is no enum module yet).
# UUIDs as dict keys are found by identity (sets use the hash).
import hashlib
import sys

__all__ = ["UUID", "uuid1", "uuid3", "uuid4", "uuid5", "getnode", "NAMESPACE_DNS",
           "NAMESPACE_URL", "NAMESPACE_OID", "NAMESPACE_X500", "RESERVED_NCS", "RFC_4122",
           "RESERVED_MICROSOFT", "RESERVED_FUTURE", "SafeUUID"]

RESERVED_NCS = "reserved for NCS compatibility"
RFC_4122 = "specified in RFC 4122"
RESERVED_MICROSOFT = "reserved for Microsoft compatibility"
RESERVED_FUTURE = "reserved for future definition"

# the builtins, under names UUID's keyword parameters do not shadow
_int_ = int
_bytes_ = bytes


class _SafeUUIDMember:
    def __init__(self, name, value):
        self.name = name
        self.value = value

    def __repr__(self):
        return "<SafeUUID." + self.name + ": " + repr(self.value) + ">"

    def __str__(self):
        return "SafeUUID." + self.name

    def __eq__(self, other):
        if isinstance(other, _SafeUUIDMember):
            return self.value == other.value and self.name == other.name
        return false

    def __hash__(self):
        return hash(self.name)


class SafeUUID:
    # whether a UUID was generated in a multiprocessing-safe way
    safe = _SafeUUIDMember("safe", 0)
    unsafe = _SafeUUIDMember("unsafe", -1)
    unknown = _SafeUUIDMember("unknown", None)


def _tn(x):
    var n = type(x).__name__
    if n == "string":
        return "str"
    if n == "map":
        return "dict"
    if n == "none":
        return "NoneType"
    return n


def _swap_le(b):
    # bytes <-> bytes_le: the first three fields reversed
    return b[3::-1] + b[5:3:-1] + b[7:5:-1] + b[8:]


class UUID:
    def __init__(self, hex=None, bytes=None, bytes_le=None, fields=None, int=None, version=None, *,
                 is_safe=SafeUUID.unknown):
        var given = 0
        for a in [hex, bytes, bytes_le, fields, int]:
            if a is not None:
                given = given + 1
        if given != 1:
            raise TypeError("one of the hex, bytes, bytes_le, fields, or int arguments must be given")
        var value = int
        if hex is not None:
            var h = hex.replace("urn:", "").replace("uuid:", "")
            h = h.strip("{}").replace("-", "")
            if len(h) != 32:
                raise ValueError("badly formed hexadecimal UUID string")
            value = _int_(h, 16)
        if bytes_le is not None:
            if len(bytes_le) != 16:
                raise ValueError("bytes_le is not a 16-char string")
            bytes = _swap_le(_bytes_(bytes_le))
        if bytes is not None:
            if len(bytes) != 16:
                raise ValueError("bytes is not a 16-char string")
            value = _int_.from_bytes(_bytes_(bytes), "big")
        if fields is not None:
            if len(fields) != 6:
                raise ValueError("fields is not a 6-tuple")
            var time_low = fields[0]
            var time_mid = fields[1]
            var time_hi_version = fields[2]
            var clock_seq_hi_variant = fields[3]
            var clock_seq_low = fields[4]
            var node = fields[5]
            if not (0 <= time_low and time_low < (1 << 32)):
                raise ValueError("field 1 out of range (need a 32-bit value)")
            if not (0 <= time_mid and time_mid < (1 << 16)):
                raise ValueError("field 2 out of range (need a 16-bit value)")
            if not (0 <= time_hi_version and time_hi_version < (1 << 16)):
                raise ValueError("field 3 out of range (need a 16-bit value)")
            if not (0 <= clock_seq_hi_variant and clock_seq_hi_variant < (1 << 8)):
                raise ValueError("field 4 out of range (need an 8-bit value)")
            if not (0 <= clock_seq_low and clock_seq_low < (1 << 8)):
                raise ValueError("field 5 out of range (need an 8-bit value)")
            if not (0 <= node and node < (1 << 48)):
                raise ValueError("field 6 out of range (need a 48-bit value)")
            var clock_seq = (clock_seq_hi_variant << 8) | clock_seq_low
            value = ((time_low << 96) | (time_mid << 80) | (time_hi_version << 64) |
                     (clock_seq << 48) | node)
        if value is not None:
            if not (0 <= value and value < (1 << 128)):
                raise ValueError("int is out of range (need a 128-bit value)")
        if version is not None:
            if not (1 <= version and version <= 5):
                raise ValueError("illegal version number")
            # the variant: RFC 4122; the version number
            value = value & ~(0xc000 << 48)
            value = value | (0x8000 << 48)
            value = value & ~(0xf000 << 64)
            value = value | (version << 76)
        object.__setattr__(self, "int", value)
        object.__setattr__(self, "is_safe", is_safe)

    def __setattr__(self, name, value):
        raise TypeError("UUID objects are immutable")

    def __eq__(self, other):
        if isinstance(other, UUID):
            return self.int == other.int
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def _other_int(self, other, op):
        if isinstance(other, UUID):
            return other.int
        raise TypeError("'" + op + "' not supported between instances of 'UUID' and '" + _tn(other) + "'")

    def __lt__(self, other):
        return self.int < self._other_int(other, "<")

    def __gt__(self, other):
        return self.int > self._other_int(other, ">")

    def __le__(self, other):
        return self.int <= self._other_int(other, "<=")

    def __ge__(self, other):
        return self.int >= self._other_int(other, ">=")

    def __hash__(self):
        return hash(self.int)

    def __int__(self):
        return self.int

    def __repr__(self):
        return self.__class__.__name__ + "(" + repr(str(self)) + ")"

    def __str__(self):
        var h = format(self.int, "032x")
        return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]

    @property
    def bytes(self):
        return self.int.to_bytes(16, "big")

    @property
    def bytes_le(self):
        return _swap_le(self.int.to_bytes(16, "big"))

    @property
    def fields(self):
        return (self.time_low, self.time_mid, self.time_hi_version, self.clock_seq_hi_variant,
                self.clock_seq_low, self.node)

    @property
    def time_low(self):
        return self.int >> 96

    @property
    def time_mid(self):
        return (self.int >> 80) & 0xffff

    @property
    def time_hi_version(self):
        return (self.int >> 64) & 0xffff

    @property
    def clock_seq_hi_variant(self):
        return (self.int >> 56) & 0xff

    @property
    def clock_seq_low(self):
        return (self.int >> 48) & 0xff

    @property
    def time(self):
        return ((self.time_hi_version & 0x0fff) << 48) | (self.time_mid << 32) | self.time_low

    @property
    def clock_seq(self):
        return ((self.clock_seq_hi_variant & 0x3f) << 8) | self.clock_seq_low

    @property
    def node(self):
        return self.int & 0xffffffffffff

    @property
    def hex(self):
        return format(self.int, "032x")

    @property
    def urn(self):
        return "urn:uuid:" + str(self)

    @property
    def variant(self):
        if not (self.int & (0x8000 << 48)):
            return RESERVED_NCS
        if not (self.int & (0x4000 << 48)):
            return RFC_4122
        if not (self.int & (0x2000 << 48)):
            return RESERVED_MICROSOFT
        return RESERVED_FUTURE

    @property
    def version(self):
        if self.variant == RFC_4122:
            return (self.int >> 76) & 0xf
        return None


_node = [None]


def getnode():
    # this machine's 48-bit node id: a random number with the multicast
    # bit set (RFC 4122 4.5), the same for the whole process
    if _node[0] is None:
        _node[0] = _int_.from_bytes(os_urandom(6), "big") | (1 << 40)
    return _node[0]


_last_timestamp = [None]


def uuid1(node=None, clock_seq=None):
    # a UUID from the time (100 ns since 1582-10-15), a clock sequence and
    # the node
    var nanoseconds = time_ns()
    var timestamp = nanoseconds // 100 + 0x01b21dd213814000
    if _last_timestamp[0] is not None and timestamp <= _last_timestamp[0]:
        timestamp = _last_timestamp[0] + 1
    _last_timestamp[0] = timestamp
    if clock_seq is None:
        clock_seq = _int_.from_bytes(os_urandom(2), "big") >> 2
    var time_low = timestamp & 0xffffffff
    var time_mid = (timestamp >> 32) & 0xffff
    var time_hi_version = (timestamp >> 48) & 0x0fff
    var clock_seq_low = clock_seq & 0xff
    var clock_seq_hi_variant = (clock_seq >> 8) & 0x3f
    if node is None:
        node = getnode()
    return UUID(fields=(time_low, time_mid, time_hi_version, clock_seq_hi_variant, clock_seq_low, node), version=1)


def _name_bytes(name):
    if isinstance(name, str):
        return name.encode("utf-8")
    return _bytes_(name)


def uuid3(namespace, name):
    var digest = hashlib.md5(namespace.bytes + _name_bytes(name)).digest()
    return UUID(bytes=digest[:16], version=3)


def uuid4():
    return UUID(bytes=os_urandom(16), version=4)


def uuid5(namespace, name):
    var digest = hashlib.sha1(namespace.bytes + _name_bytes(name)).digest()
    return UUID(bytes=digest[:16], version=5)


NAMESPACE_DNS = UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
NAMESPACE_URL = UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")
NAMESPACE_OID = UUID("6ba7b812-9dad-11d1-80b4-00c04fd430c8")
NAMESPACE_X500 = UUID("6ba7b814-9dad-11d1-80b4-00c04fd430c8")
