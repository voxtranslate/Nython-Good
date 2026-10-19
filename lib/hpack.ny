# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/hpack.ny - HPACK, header compression for HTTP/2 (RFC 7541; round 86).
# Not in CPython's standard library: the API is the `hpack` package's (the
# one python-hyper's h2 uses), the behaviour RFC 7541's.
#
#     import hpack
#     e = hpack.Encoder()
#     block = e.encode([(":method", "GET"), (":path", "/"), ("user-agent", "x")])
#     d = hpack.Decoder()
#     d.decode(block)          -> [(':method', 'GET'), (':path', '/'), ...]
#
# Encoder()                  .encode(headers, huffman=True) -> bytes; headers
#                            are (name, value) or (name, value, sensitive)
#                            tuples, HeaderTuple / NeverIndexedHeaderTuple, or
#                            a dict (pseudo-headers first); names and values
#                            str (UTF-8) or bytes. .header_table_size (setting
#                            it signals a dynamic table size update at the
#                            start of the next block: the smallest size since
#                            the last block, then the final one - RFC 7541
#                            4.2). .header_table (HeaderTable).
# Decoder(max_header_list_size=65536)
#                            .decode(data, raw=False) -> [HeaderTuple ...]
#                            (str unless raw; NeverIndexedHeaderTuple for a
#                            field sent never-indexed), .header_table_size,
#                            .max_allowed_table_size (what our SETTINGS
#                            allow: a larger size update is
#                            InvalidTableSizeError), .max_header_list_size
#                            (OversizedHeaderListError past it, counted as
#                            RFC 7541 4.1 counts entries)
# HeaderTable                the static table (Appendix A) + the dynamic FIFO
#                            table: add, get_by_index, search, maxsize,
#                            current_size, dynamic_entries (newest first)
# encode_integer(i, prefix_bits) -> bytearray, decode_integer(data, prefix_bits)
#                            -> (value, consumed) (5.1); huffman_encode(b),
#                            huffman_decode(b) (5.2, Appendix B's code: an
#                            EOS symbol in the data, padding over 7 bits or
#                            not all ones are HPACKDecodingError)
# HPACKError, HPACKDecodingError, InvalidTableIndexError (InvalidTableIndex),
# OversizedHeaderListError, InvalidTableSizeError
#
# Representations (6.1-6.3): indexed; literal with incremental indexing,
# without indexing, never indexed (new or indexed name); dynamic table size
# update - all decoded; the encoder uses indexed for an exact match (static
# table, then dynamic), else a literal with an indexed name (static first)
# or a new name, with incremental indexing - or never indexed for a
# sensitive field - exactly as the hpack package does, so its output is
# RFC 7541 Appendix C's byte for byte. huffman=True Huffman-codes a string
# unless that would make it longer (the hpack package codes every string).
#
# Beyond the hpack package (Nython's; opt-in, the default output is above):
# what to index. RFC 7541 keeps the dynamic table FIFO (an eviction policy
# cannot be changed without breaking interoperability), but the encoder alone
# decides what goes into it. Encoder(policy=SmartIndexing()) does not index
#   - credentials: authorization, proxy-authorization and short cookies are
#     sent never-indexed (RFC 7541 7.1.3; the cookie rule is nghttp2's: a
#     value under 20 bytes can be guessed by a CRIME-style probe);
#   - high-entropy values: tokens, nonces, hashes, request ids (a
#     character-entropy and character-class test on the value, 7.1.2 asks
#     encoders to weigh this) - indexing them only pushes reusable entries
#     out of the FIFO table;
#   - values whose name keeps missing: per header name the policy counts
#     how often an indexed value was later reused, and a name with several
#     insertions and no reuse (content-length, :path with queries, etag,
#     date in most responses ...) is sent without indexing from then on;
#   - fields larger than a quarter of the table (one would evict most of it).
# IndexAll() is the hpack package's choice (the default), IndexNone() never
# indexes. compression_report(blocks, policies) measures them on a header
# corpus: the HTTP/1.1 size of the header lists, each policy's encoded size
# and ratio, and the dynamic-table hit rate (vm_audit123 reports it).
#
# Written in the subset of the language CPython also runs: python3 can load
# this file with importlib (SourceFileLoader) - vm_audit123 runs RFC 7541's
# vectors under both.

__all__ = ["Encoder", "Decoder", "HeaderTuple", "NeverIndexedHeaderTuple", "HeaderTable",
           "HPACKError", "HPACKDecodingError", "InvalidTableIndex", "InvalidTableIndexError",
           "OversizedHeaderListError", "InvalidTableSizeError", "encode_integer", "decode_integer",
           "huffman_encode", "huffman_decode", "IndexAll", "IndexNone", "SmartIndexing",
           "compression_report", "table_entry_size"]

__version__ = "4.2.0"

DEFAULT_MAX_HEADER_LIST_SIZE = 2 ** 16
DEFAULT_HEADER_TABLE_SIZE = 4096
_MAX_INT_OCTETS = 10          # continuation octets of one integer (2**70: plenty)


# ── errors ─────────────────────────────────────────────────────────────────

class HPACKError(Exception):
    """The base class for all hpack exceptions."""


class HPACKDecodingError(HPACKError):
    """An error has been encountered while performing HPACK decoding."""


class InvalidTableIndexError(HPACKDecodingError):
    """An invalid table index was received."""


class InvalidTableIndex(InvalidTableIndexError):
    """The old name of InvalidTableIndexError."""


class OversizedHeaderListError(HPACKDecodingError):
    """A header list larger than max_header_list_size was received."""


class InvalidTableSizeError(HPACKDecodingError):
    """A dynamic table size update over the allowed maximum, or a missing one."""


# ── header tuples ──────────────────────────────────────────────────────────

class HeaderTuple(tuple):
    """A (name, value) header field that may be added to the compression context."""
    indexable = True

    def __new__(cls, *args):
        return tuple.__new__(cls, args)


class NeverIndexedHeaderTuple(HeaderTuple):
    """A (name, value) header field that must never be indexed (RFC 7541 6.2.3)."""
    indexable = False

    def __new__(cls, *args):
        return tuple.__new__(cls, args)


# ── the static table (Appendix A) ──────────────────────────────────────────

STATIC_TABLE = (
    (b":authority", b""), (b":method", b"GET"), (b":method", b"POST"), (b":path", b"/"),
    (b":path", b"/index.html"), (b":scheme", b"http"), (b":scheme", b"https"), (b":status", b"200"),
    (b":status", b"204"), (b":status", b"206"), (b":status", b"304"), (b":status", b"400"),
    (b":status", b"404"), (b":status", b"500"), (b"accept-charset", b""),
    (b"accept-encoding", b"gzip, deflate"), (b"accept-language", b""), (b"accept-ranges", b""),
    (b"accept", b""), (b"access-control-allow-origin", b""), (b"age", b""), (b"allow", b""),
    (b"authorization", b""), (b"cache-control", b""), (b"content-disposition", b""),
    (b"content-encoding", b""), (b"content-language", b""), (b"content-length", b""),
    (b"content-location", b""), (b"content-range", b""), (b"content-type", b""), (b"cookie", b""),
    (b"date", b""), (b"etag", b""), (b"expect", b""), (b"expires", b""), (b"from", b""), (b"host", b""),
    (b"if-match", b""), (b"if-modified-since", b""), (b"if-none-match", b""), (b"if-range", b""),
    (b"if-unmodified-since", b""), (b"last-modified", b""), (b"link", b""), (b"location", b""),
    (b"max-forwards", b""), (b"proxy-authenticate", b""), (b"proxy-authorization", b""),
    (b"range", b""), (b"referer", b""), (b"refresh", b""), (b"retry-after", b""), (b"server", b""),
    (b"set-cookie", b""), (b"strict-transport-security", b""), (b"transfer-encoding", b""),
    (b"user-agent", b""), (b"vary", b""), (b"via", b""), (b"www-authenticate", b""))
STATIC_TABLE_LENGTH = len(STATIC_TABLE)


def _static_maps():
    full = {}
    names = {}
    i = 0
    while i < STATIC_TABLE_LENGTH:
        n = STATIC_TABLE[i][0]
        v = STATIC_TABLE[i][1]
        if (n, v) not in full:
            full[(n, v)] = i + 1
        if n not in names:
            names[n] = i + 1
        i += 1
    return full, names


_STATIC_FULL, _STATIC_NAMES = _static_maps()


def table_entry_size(name, value):
    """The size of an entry, RFC 7541 4.1: its name and value octets plus 32."""
    return 32 + len(name) + len(value)


class HeaderTable:
    """The static and dynamic tables of one side of a connection (RFC 7541 2.3).

    Indexes 1..61 are the static table, 62.. the dynamic table, newest
    first. Entries are evicted oldest first when the size would pass
    maxsize (4.4); an entry larger than maxsize empties the table.
    """
    def __init__(self):
        self._max = DEFAULT_HEADER_TABLE_SIZE
        self.current_size = 0
        self.resized = False
        self.dynamic_entries = []        # newest first: (name, value)
        # exact and name lookups by insertion number (the newest wins)
        self._seq = 0                    # insertion number of the newest entry
        self._seqs = []                  # parallel to dynamic_entries
        self._full = {}
        self._names = {}

    @property
    def maxsize(self):
        return self._max

    @maxsize.setter
    def maxsize(self, newmax):
        newmax = int(newmax)
        old = self._max
        self._max = newmax
        self.resized = newmax != old
        if newmax <= 0:
            self._clear()
        else:
            self._shrink()

    def _clear(self):
        self.dynamic_entries = []
        self._seqs = []
        self._full = {}
        self._names = {}
        self.current_size = 0

    def _evict_one(self):
        name, value = self.dynamic_entries.pop()
        s = self._seqs.pop()
        self.current_size -= table_entry_size(name, value)
        if self._full.get((name, value)) == s:
            del self._full[(name, value)]
        if self._names.get(name) == s:
            del self._names[name]

    def _shrink(self):
        while self.current_size > self._max and self.dynamic_entries:
            self._evict_one()

    def add(self, name, value):
        """Add an entry (4.4): evict until it fits; too large, the table empties."""
        size = table_entry_size(name, value)
        if size > self._max:
            self._clear()
            return
        while self.current_size + size > self._max:
            self._evict_one()
        self._seq += 1
        self.dynamic_entries.insert(0, (name, value))
        self._seqs.insert(0, self._seq)
        self.current_size += size
        self._full[(name, value)] = self._seq
        self._names[name] = self._seq

    def __len__(self):
        return STATIC_TABLE_LENGTH + len(self.dynamic_entries)

    def get_by_index(self, index):
        """The (name, value) at an index (2.3.3); InvalidTableIndexError when out of range."""
        if index >= 1 and index <= STATIC_TABLE_LENGTH:
            return STATIC_TABLE[index - 1]
        i = index - STATIC_TABLE_LENGTH - 1
        if index > STATIC_TABLE_LENGTH and i < len(self.dynamic_entries):
            return self.dynamic_entries[i]
        raise InvalidTableIndexError("Invalid table index %d" % index)

    def _index_of(self, seq):
        return STATIC_TABLE_LENGTH + 1 + (self._seq - seq)

    def search(self, name, value):
        """(index, name, value) for an exact match, (index, name, None) for a
        name match, None for none - the static table first, as the hpack
        package (and RFC 7541's examples) do."""
        i = _STATIC_FULL.get((name, value))
        if i is not None:
            return (i, name, value)
        s = self._full.get((name, value))
        if s is not None:
            return (self._index_of(s), name, value)
        i = _STATIC_NAMES.get(name)
        if i is not None:
            return (i, name, None)
        s = self._names.get(name)
        if s is not None:
            return (self._index_of(s), name, None)
        return None

    def __repr__(self):
        return "<HeaderTable maxsize=%d size=%d entries=%d>" % (self._max, self.current_size, len(self.dynamic_entries))


# ── integers (5.1) ─────────────────────────────────────────────────────────

def encode_integer(integer, prefix_bits):
    """An integer with an N-bit prefix (RFC 7541 5.1), as a bytearray whose
    first octet's high bits are 0 (the caller ORs the representation in)."""
    if integer < 0:
        raise ValueError("Can only encode positive integers, got %d" % integer)
    if prefix_bits < 1 or prefix_bits > 8:
        raise ValueError("Prefix bits must be between 1 and 8, got %d" % prefix_bits)
    max_number = (1 << prefix_bits) - 1
    if integer < max_number:
        return bytearray([integer])
    out = bytearray([max_number])
    integer -= max_number
    while integer >= 128:
        out.append((integer & 127) | 128)
        integer >>= 7
    out.append(integer)
    return out


def decode_integer(data, prefix_bits, pos=0):
    """(value, octets consumed) of the integer starting at data[pos]."""
    if prefix_bits < 1 or prefix_bits > 8:
        raise ValueError("Prefix bits must be between 1 and 8, got %d" % prefix_bits)
    n = len(data)
    if pos >= n:
        raise HPACKDecodingError("Unable to decode HPACK integer representation from %r" % (bytes(data[pos:]),))
    max_number = (1 << prefix_bits) - 1
    number = data[pos] & max_number
    i = pos + 1
    if number == max_number:
        shift = 0
        while True:
            if i >= n:
                raise HPACKDecodingError("Unable to decode HPACK integer representation from %r" % (bytes(data[pos:]),))
            b = data[i]
            i += 1
            number += (b & 127) << shift
            if b < 128:
                break
            shift += 7
            if i - pos > _MAX_INT_OCTETS:
                raise HPACKDecodingError("Variable integer representation is too long: %r" % (bytes(data[pos:i]),))
    return number, i - pos


# ── the Huffman code (5.2, Appendix B) ─────────────────────────────────────
# Appendix B's code is canonical: each symbol's code follows from the code
# lengths alone (checked against the RFC's table by vm_audit123).

HUFFMAN_CODE_LENGTHS = (
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 30, 28, 28, 28,
    28, 28, 28, 28, 28, 28, 6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6, 5, 5, 5, 6, 6, 6, 6, 6,
    6, 6, 7, 8, 15, 6, 12, 10, 13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8,
    7, 8, 13, 19, 13, 14, 6, 15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5, 6, 7, 6, 5, 5, 6, 7, 7, 7, 7,
    7, 15, 11, 14, 13, 28, 20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23, 24, 24, 22, 23,
    24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24, 22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22,
    23, 23, 21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23, 26, 26, 20, 19, 22, 23, 22, 25,
    26, 26, 26, 27, 27, 26, 24, 25, 19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27, 20, 24,
    20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23, 26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27,
    27, 27, 27, 26, 30)
EOS = 256


def _canonical_codes(lengths):
    order = sorted(range(len(lengths)), key=lambda s: (lengths[s], s))
    codes = [0] * len(lengths)
    code = 0
    prev = lengths[order[0]]
    first = True
    for s in order:
        if not first:
            code = (code + 1) << (lengths[s] - prev)
        first = False
        prev = lengths[s]
        codes[s] = code
    return codes


HUFFMAN_CODES = tuple(_canonical_codes(HUFFMAN_CODE_LENGTHS))


def huffman_encoded_length(data):
    """The octets data takes Huffman-coded (the bits rounded up)."""
    bits = 0
    for b in data:
        bits += HUFFMAN_CODE_LENGTHS[b]
    return (bits + 7) >> 3


def huffman_encode(data):
    """data Huffman-coded, padded with the high bits of EOS (all ones)."""
    out = bytearray()
    acc = 0
    nbits = 0
    codes = HUFFMAN_CODES
    lens = HUFFMAN_CODE_LENGTHS
    for b in data:
        acc = (acc << lens[b]) | codes[b]
        nbits += lens[b]
        while nbits >= 8:
            nbits -= 8
            out.append((acc >> nbits) & 0xFF)
        acc &= (1 << nbits) - 1
    if nbits:
        pad = 8 - nbits
        out.append(((acc << pad) | ((1 << pad) - 1)) & 0xFF)
    return bytes(out)


# The decoder walks the code tree four bits at a time (nghttp2's approach):
# a table of (next node, symbol or -1, failed) for each internal node and
# nibble, built on first use. A node is "accepting" when the bits since the
# last symbol are fewer than 8 and all ones - a valid end of string (5.2).
_DECODE_TABLE = None
_ACCEPTING = None


def _build_decoder():
    global _DECODE_TABLE, _ACCEPTING
    left = [-1]
    right = [-1]
    sym = [-1]
    s = 0
    while s < 257:
        code = HUFFMAN_CODES[s]
        ln = HUFFMAN_CODE_LENGTHS[s]
        node = 0
        k = ln - 1
        while k >= 0:
            bit = (code >> k) & 1
            child = right[node] if bit else left[node]
            if child < 0:
                child = len(sym)
                left.append(-1)
                right.append(-1)
                sym.append(-1)
                if bit:
                    right[node] = child
                else:
                    left[node] = child
            node = child
            k -= 1
        sym[node] = s
        s += 1
    # internal nodes get dense ids: the root is 0
    ids = {}
    order = []
    for i in range(len(sym)):
        if sym[i] < 0:
            ids[i] = len(order)
            order.append(i)
    accepting = [False] * len(order)
    node = 0
    depth = 0
    while depth < 8 and node >= 0 and sym[node] < 0:
        accepting[ids[node]] = True
        node = right[node]
        depth += 1
    table = []
    for n in order:
        for nib in range(16):
            cur = n
            emitted = -1
            failed = False
            k = 3
            while k >= 0:
                bit = (nib >> k) & 1
                cur = right[cur] if bit else left[cur]
                if sym[cur] >= 0:
                    if sym[cur] == EOS:
                        failed = True
                        break
                    emitted = sym[cur]
                    cur = 0
                k -= 1
            if failed:
                table.append((0, -1, True))
            else:
                table.append((ids[cur], emitted, False))
    _DECODE_TABLE = table
    _ACCEPTING = accepting


def huffman_decode(data):
    """Huffman-coded data decoded; HPACKDecodingError on an invalid string."""
    if _DECODE_TABLE is None:
        _build_decoder()
    table = _DECODE_TABLE
    out = bytearray()
    state = 0
    for b in data:
        t = table[(state << 4) | (b >> 4)]
        if t[2]:
            raise HPACKDecodingError("Invalid Huffman string: EOS symbol in the data")
        if t[1] >= 0:
            out.append(t[1])
        t = table[(t[0] << 4) | (b & 15)]
        if t[2]:
            raise HPACKDecodingError("Invalid Huffman string: EOS symbol in the data")
        if t[1] >= 0:
            out.append(t[1])
        state = t[0]
    if not _ACCEPTING[state]:
        raise HPACKDecodingError("Invalid Huffman string: bad padding")
    return bytes(out)


# ── indexing policies (Nython's; see the header) ───────────────────────────

class IndexAll:
    """The hpack package's choice: index every field not marked sensitive."""
    name = "index-all"

    def decide(self, name, value, table):
        return "index"

    def observe(self, name, value, hit):
        pass


class IndexNone:
    """Never touch the dynamic table: every literal without indexing."""
    name = "index-none"

    def decide(self, name, value, table):
        return "literal"

    def observe(self, name, value, hit):
        pass


_SECRET_NAMES = (b"authorization", b"proxy-authorization")
_TOKEN_CHARS = b"0123456789abcdefABCDEF-_=+/."


def _looks_random(value):
    # A token, nonce, hash or id: long enough to matter, made of one
    # "alphabet" (hex, base64, uuid-like) with high per-character entropy.
    n = len(value)
    if n < 16:
        return False
    counts = {}
    letters = 0
    digits = 0
    other = 0
    for c in value:
        counts[c] = counts.get(c, 0) + 1
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
            letters += 1
        elif c >= 48 and c <= 57:
            digits += 1
        elif c not in b"-_=+/.:":
            other += 1
    if other * 10 > n:          # spaces, commas, semicolons: prose or lists
        return False
    if digits == 0 or letters + digits < n * 3 // 4:
        return False
    # entropy in bits per character, without logarithms: the collision
    # probability (Renyi order-2) estimate, -log2(sum p^2), against a
    # threshold - random base64/hex sits near 4-6 bits, words near 3.
    total = 0
    for c in counts:
        total += counts[c] * counts[c]
    # sum p^2 = total / n^2 < 2^-3.3  <=>  total * 10 < n * n
    return total * 10 < n * n


class SmartIndexing:
    """Do not index what will not be reused or must not be guessable.

    min_inserts: insertions of a name with no reuse before the name is no
    longer indexed; max_fraction: the largest share of the table one entry
    may take."""
    name = "smart"

    def __init__(self, min_inserts=3, max_fraction=0.25, cookie_crumb=20):
        self.min_inserts = min_inserts
        self.max_fraction = max_fraction
        self.cookie_crumb = cookie_crumb
        self.inserted = {}
        self.reused = {}

    def decide(self, name, value, table):
        if name in _SECRET_NAMES:
            return "never"
        if name == b"cookie" and len(value) < self.cookie_crumb:
            return "never"
        if table_entry_size(name, value) > table.maxsize * self.max_fraction:
            return "literal"
        if _looks_random(value):
            return "literal"
        ins = self.inserted.get(name, 0)
        if ins >= self.min_inserts and self.reused.get(name, 0) == 0:
            return "literal"
        return "index"

    def observe(self, name, value, hit):
        # hit: an exact match was found in the dynamic table (a reuse)
        if hit:
            self.reused[name] = self.reused.get(name, 0) + 1
        else:
            self.inserted[name] = self.inserted.get(name, 0) + 1


# ── the encoder ────────────────────────────────────────────────────────────

def _to_bytes(value):
    t = type(value)
    if t is bytes:
        return value
    if t is bytearray or t is memoryview:
        return bytes(value)
    if t is not str:
        value = str(value)
    return value.encode("utf-8")


def _dict_to_iterable(header_dict):
    keys = sorted(header_dict.keys(), key=lambda k: not _to_bytes(k).startswith(b":"))
    return [(k, header_dict[k]) for k in keys]


class Encoder:
    """An HPACK encoder: header lists in, header blocks out (one per HEADERS
    frame sequence, in the order the peer will decode them)."""
    def __init__(self, policy=None):
        self.header_table = HeaderTable()
        self.table_size_changes = []
        self.policy = policy
        self.dynamic_hits = 0
        self.static_hits = 0

    @property
    def header_table_size(self):
        return self.header_table.maxsize

    @header_table_size.setter
    def header_table_size(self, value):
        self.header_table.maxsize = value
        if self.header_table.resized:
            self.table_size_changes.append(int(value))

    def encode(self, headers, huffman=True):
        """The header block for headers (see the module header)."""
        block = []
        if self.table_size_changes:
            block.append(self._encode_table_size_change())
        self.header_table.resized = False
        if isinstance(headers, dict):
            headers = _dict_to_iterable(headers)
        for header in headers:
            sensitive = False
            if isinstance(header, HeaderTuple):
                sensitive = not header.indexable
            elif len(header) > 2:
                sensitive = bool(header[2])
            block.append(self.add((_to_bytes(header[0]), _to_bytes(header[1])), sensitive, huffman))
        return b"".join(block)

    def add(self, to_add, sensitive, huffman=False):
        """The representation of one (name, value) field."""
        name, value = to_add
        match = self.header_table.search(name, value)
        if match is not None and match[2] is not None and not sensitive:
            if match[0] > STATIC_TABLE_LENGTH:
                self.dynamic_hits += 1
                if self.policy is not None:
                    self.policy.observe(name, value, True)
            else:
                self.static_hits += 1
            return self._encode_indexed(match[0])
        mode = "index"
        if sensitive:
            mode = "never"
        elif self.policy is not None:
            mode = self.policy.decide(name, value, self.header_table)
        if mode == "index":
            prefix = 0x40
            bits = 6
        elif mode == "never":
            prefix = 0x10
            bits = 4
        else:
            prefix = 0x00
            bits = 4
        if match is None:
            head = bytes([prefix])
            out = head + self._encode_string(name, huffman) + self._encode_string(value, huffman)
        else:
            idx = encode_integer(match[0], bits)
            idx[0] |= prefix
            out = bytes(idx) + self._encode_string(value, huffman)
        if mode == "index":
            self.header_table.add(name, value)
            if self.policy is not None:
                self.policy.observe(name, value, False)
        return out

    def _encode_indexed(self, index):
        field = encode_integer(index, 7)
        field[0] |= 0x80
        return bytes(field)

    def _encode_string(self, s, huffman):
        if huffman and len(s) and huffman_encoded_length(s) <= len(s):
            h = huffman_encode(s)
            n = encode_integer(len(h), 7)
            n[0] |= 0x80
            return bytes(n) + h
        return bytes(encode_integer(len(s), 7)) + s

    def _encode_table_size_change(self):
        # RFC 7541 4.2: the smallest size since the last block, then the final one
        changes = self.table_size_changes
        self.table_size_changes = []
        smallest = min(changes)
        final = changes[-1]
        sizes = [final] if smallest == final else [smallest, final]
        out = b""
        for size in sizes:
            b = encode_integer(size, 5)
            b[0] |= 0x20
            out += bytes(b)
        return out


# ── the decoder ────────────────────────────────────────────────────────────

class Decoder:
    """An HPACK decoder: header blocks in, header lists out.

    max_header_list_size bounds the decoded list (entries counted as
    32 + name + value octets): a protection against a small block that
    expands into an enormous header list."""
    def __init__(self, max_header_list_size=DEFAULT_MAX_HEADER_LIST_SIZE):
        self.header_table = HeaderTable()
        self.max_header_list_size = max_header_list_size
        self.max_allowed_table_size = self.header_table.maxsize

    @property
    def header_table_size(self):
        return self.header_table.maxsize

    @header_table_size.setter
    def header_table_size(self, value):
        self.header_table.maxsize = value

    def _string(self, data, pos):
        if pos >= len(data):
            raise HPACKDecodingError("Truncated header block: a string is missing")
        huff = data[pos] & 0x80
        length, used = decode_integer(data, 7, pos)
        pos += used
        if pos + length > len(data):
            raise HPACKDecodingError("Truncated header block: the string is longer than the block")
        s = bytes(data[pos:pos + length])
        if huff:
            s = huffman_decode(s)
        return s, pos + length

    def decode(self, data, raw=False):
        """The header list of one header block (raw: bytes, else str)."""
        data = bytes(data)
        headers = []
        size = 0
        pos = 0
        n = len(data)
        table = self.header_table
        updates_allowed = True
        while pos < n:
            b = data[pos]
            if b & 0x80:
                index, used = decode_integer(data, 7, pos)
                pos += used
                if index == 0:
                    raise InvalidTableIndexError("Invalid table index 0")
                name, value = table.get_by_index(index)
                header = HeaderTuple(name, value)
                updates_allowed = False
            elif b & 0x20 and not (b & 0x40):
                # dynamic table size update (6.3): only before the first field
                if not updates_allowed:
                    raise HPACKDecodingError("Table size update not at the start of the block")
                new_size, used = decode_integer(data, 5, pos)
                pos += used
                if new_size > self.max_allowed_table_size:
                    raise InvalidTableSizeError("Encoder exceeded max allowable table size")
                table.maxsize = new_size
                continue
            else:
                if b & 0x40:
                    bits = 6
                    indexing = True
                    never = False
                else:
                    bits = 4
                    indexing = False
                    never = (b & 0x10) != 0
                index, used = decode_integer(data, bits, pos)
                pos += used
                if index:
                    name = table.get_by_index(index)[0]
                else:
                    name, pos = self._string(data, pos)
                value, pos = self._string(data, pos)
                if indexing:
                    table.add(name, value)
                if never:
                    header = NeverIndexedHeaderTuple(name, value)
                else:
                    header = HeaderTuple(name, value)
                updates_allowed = False
            headers.append(header)
            size += table_entry_size(header[0], header[1])
            if size > self.max_header_list_size:
                raise OversizedHeaderListError("A header list larger than %d has been received" % self.max_header_list_size)
        if table.maxsize > self.max_allowed_table_size:
            raise InvalidTableSizeError("Encoder did not shrink table size to within the max")
        if raw:
            return headers
        out = []
        try:
            for h in headers:
                out.append(h.__class__(h[0].decode("utf-8"), h[1].decode("utf-8")))
        except UnicodeDecodeError:
            raise HPACKDecodingError("Unable to decode headers as UTF-8")
        return out


# ── measuring a policy (Nython's) ──────────────────────────────────────────

def compression_report(blocks, policies=None, table_size=DEFAULT_HEADER_TABLE_SIZE, huffman=True):
    """For a corpus - a list of header lists, as one connection sends them -
    each policy's encoded size: {"raw": HTTP/1.1 octets ("name: value\\r\\n"
    per field), policy name: {"bytes", "ratio" (raw / bytes), "dynamic_hits",
    "table_entries"}}. Every block is decoded again and checked."""
    if policies is None:
        policies = [IndexAll(), SmartIndexing(), IndexNone()]
    raw = 0
    for blk in blocks:
        for h in blk:
            raw += len(_to_bytes(h[0])) + len(_to_bytes(h[1])) + 4
    report = {"raw": raw}
    for pol in policies:
        enc = Encoder(policy=pol)
        dec = Decoder()
        if table_size != DEFAULT_HEADER_TABLE_SIZE:
            enc.header_table_size = table_size
            dec.max_allowed_table_size = table_size
        total = 0
        for blk in blocks:
            out = enc.encode(blk, huffman)
            total += len(out)
            got = dec.decode(out, raw=True)
            want = [(_to_bytes(h[0]), _to_bytes(h[1])) for h in blk]
            if [tuple(g) for g in got] != want:
                raise HPACKError("round trip failed under policy " + pol.name)
        report[pol.name] = {"bytes": total, "ratio": round(raw / total, 3) if total else 0.0,
                            "dynamic_hits": enc.dynamic_hits,
                            "table_entries": len(enc.header_table.dynamic_entries)}
    return report
