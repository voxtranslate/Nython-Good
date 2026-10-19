# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/priority.ny - RFC 9218 Extensible Prioritization for HTTP/2 (round
# 86; Nython's - the h2 package has none of it).
#
# parse_priority(value) -> (urgency, incremental): the Priority header field /
#     PRIORITY_UPDATE value, a Structured Fields Dictionary (RFC 8941 3.2);
#     u is an Integer 0..7 (default 3), i a Boolean (default false); unknown
#     keys, out-of-range values and values of the wrong type are ignored
#     (RFC 9218 4); a value that is not a valid Dictionary raises ValueError.
# serialize_priority(urgency, incremental) -> "u=5, i" (defaults left out)
# PriorityScheduler - which stream a server sends to next (RFC 9218 10):
#     add(stream_id, urgency=3, incremental=False), update(...), remove(id),
#     next(ready) -> the stream to give the next frame's worth of bandwidth,
#     among the stream ids in `ready` (those with data and window).
#
# The scheduling rule: lower urgency first, strictly. Within one urgency,
# non-incremental responses one at a time in stream-id order (the order the
# client asked for them), incremental responses sharing the bandwidth round
# robin. RFC 9218 10 leaves open what to do when both kinds share an
# urgency, warning that strict request order starves a small incremental
# response behind a large non-incremental one (and the reverse); here the
# non-incremental queue takes part in the round robin as ONE member: it gets
# one turn in every round, its head stream all of that turn - so neither
# kind can starve the other, and non-incremental responses still complete
# one by one, in order.


def _skip_ows(s, i):
    while i < len(s) and s[i] in " \t":
        i += 1
    return i


def _parse_key(s, i):
    if i >= len(s) or not (s[i].islower() and s[i].isascii() or s[i] == "*"):
        raise ValueError("invalid dictionary key at %d" % i)
    j = i
    while j < len(s) and (s[j].isascii() and (s[j].islower() or s[j].isdigit()) or s[j] in "_-.*"):
        j += 1
    return s[i:j], j


def _parse_bare_item(s, i):
    # RFC 8941 4.2.3.1: integer/decimal, string, token, byte sequence, boolean
    if i >= len(s):
        raise ValueError("missing item")
    c = s[i]
    if c == "-" or c.isdigit():
        j = i + 1
        while j < len(s) and (s[j].isdigit() or s[j] == "."):
            j += 1
        text = s[i:j]
        if "." in text:
            return ("decimal", float(text)), j
        if len(text.lstrip("-")) > 15 or text == "-":
            raise ValueError("invalid integer")
        return ("integer", int(text)), j
    if c == '"':
        j = i + 1
        out = []
        while j < len(s):
            if s[j] == "\\":
                if j + 1 >= len(s) or s[j + 1] not in '"\\':
                    raise ValueError("invalid string escape")
                out.append(s[j + 1])
                j += 2
                continue
            if s[j] == '"':
                return ("string", "".join(out)), j + 1
            if ord(s[j]) < 0x20 or ord(s[j]) > 0x7e:
                raise ValueError("invalid string character")
            out.append(s[j])
            j += 1
        raise ValueError("unterminated string")
    if c == "?":
        if i + 1 < len(s) and s[i + 1] in "01":
            return ("boolean", s[i + 1] == "1"), i + 2
        raise ValueError("invalid boolean")
    if c == ":":
        j = s.find(":", i + 1)
        if j < 0:
            raise ValueError("unterminated byte sequence")
        return ("bytes", s[i + 1:j]), j + 1
    if c.isalpha() or c == "*":
        j = i + 1
        while j < len(s) and (s[j].isalnum() or s[j] in "!#$%&'*+-.^_`|~:/"):
            j += 1
        return ("token", s[i:j]), j
    raise ValueError("invalid item")


def _parse_params(s, i):
    while i < len(s) and s[i] == ";":
        i = _skip_ows(s, i + 1)
        key, i = _parse_key(s, i)
        if i < len(s) and s[i] == "=":
            item, i = _parse_bare_item(s, i + 1)
    return i


def parse_dictionary(value):
    """An RFC 8941 Dictionary as {key: (type, value)} (inner lists are kept
    as ("list", None)); ValueError when it does not parse."""
    if isinstance(value, (bytes, bytearray)):
        value = bytes(value).decode("ascii")
    s = value
    out = {}
    i = _skip_ows(s, 0)
    if i >= len(s):
        return out
    while True:
        key, i = _parse_key(s, i)
        if i < len(s) and s[i] == "=":
            i += 1
            if i < len(s) and s[i] == "(":
                j = s.find(")", i)
                if j < 0:
                    raise ValueError("unterminated inner list")
                item = ("list", None)
                i = j + 1
            else:
                item, i = _parse_bare_item(s, i)
        else:
            item = ("boolean", True)
        i = _parse_params(s, i)
        out[key] = item
        i = _skip_ows(s, i)
        if i >= len(s):
            return out
        if s[i] != ",":
            raise ValueError("expected a comma at %d" % i)
        i = _skip_ows(s, i + 1)
        if i >= len(s):
            raise ValueError("trailing comma")


def parse_priority(value, default=(3, False)):
    """(urgency, incremental) of a Priority field value (RFC 9218 4-5)."""
    d = parse_dictionary(value)
    urgency = default[0]
    incremental = default[1]
    u = d.get("u")
    if u is not None and u[0] == "integer" and 0 <= u[1] <= 7:
        urgency = u[1]
    inc = d.get("i")
    if inc is not None and inc[0] == "boolean":
        incremental = inc[1]
    return (urgency, incremental)


def serialize_priority(urgency=3, incremental=False):
    parts = []
    if urgency != 3:
        parts.append("u=%d" % urgency)
    if incremental:
        parts.append("i")
    return ", ".join(parts)


class PriorityScheduler:
    """Picks the stream to serve next (see the module header)."""
    def __init__(self):
        self._prio = {}          # stream id -> (urgency, incremental)
        self._rr = {}            # urgency -> round-robin order: stream ids and "N" (the non-incremental queue)

    def __contains__(self, stream_id):
        return stream_id in self._prio

    def __len__(self):
        return len(self._prio)

    def priority(self, stream_id):
        return self._prio.get(stream_id, (3, False))

    def add(self, stream_id, urgency=3, incremental=False):
        if stream_id in self._prio:
            self.remove(stream_id)
        urgency = max(0, min(7, int(urgency)))
        self._prio[stream_id] = (urgency, bool(incremental))
        rr = self._rr.setdefault(urgency, [])
        member = stream_id if incremental else "N"
        if member not in rr:
            rr.append(member)

    def update(self, stream_id, urgency=3, incremental=False):
        self.add(stream_id, urgency, incremental)

    def remove(self, stream_id):
        p = self._prio.pop(stream_id, None)
        if p is None:
            return
        rr = self._rr.get(p[0])
        if rr is None:
            return
        if p[1]:
            if stream_id in rr:
                rr.remove(stream_id)
        else:
            others = [s for s in self._prio if self._prio[s][0] == p[0] and not self._prio[s][1]]
            if not others and "N" in rr:
                rr.remove("N")
        if not rr:
            del self._rr[p[0]]

    def next(self, ready):
        """The stream among `ready` to send to now (None: none of them is
        known); the round robin advances past it."""
        ready = set(ready)
        for urgency in sorted(self._rr):
            rr = self._rr[urgency]
            n = len(rr)
            k = 0
            while k < n:
                member = rr[k]
                if member == "N":
                    cands = sorted(s for s in self._prio if self._prio[s] == (urgency, False) and s in ready)
                    pick = cands[0] if cands else None
                else:
                    pick = member if member in ready else None
                if pick is not None:
                    # rotate: the member that was served goes to the back
                    rr.pop(k)
                    rr.append(member)
                    return pick
                k += 1
        # streams the scheduler was never told about: oldest first
        rest = sorted(s for s in ready if s not in self._prio)
        if rest:
            return rest[0]
        return None
