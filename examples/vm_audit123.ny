# vm_audit123.ny - HTTP/2, HPACK and WebSocket compression (round 86).
#
#   hpack       RFC 7541: integers (C.1), the Huffman code (Appendix B, checked
#               against the RFC's table), every example of Appendix C byte for
#               byte - encoder output, decoded lists and the dynamic tables -,
#               dynamic table size updates, the decoder's errors; the indexing
#               policies on a header corpus (Nython's SmartIndexing, reported)
#   frames      the frame layer: each frame type encoded byte for byte as the
#               reference implementation (python-hyper's hyperframe) encodes
#               it, and parsed back; size, padding and stream-id errors
#   connection  two H2Connections talking in memory: the preface and SETTINGS,
#               requests and responses, trailers, 1xx, CONTINUATION, padding,
#               flow control (FlowControlError, WINDOW_UPDATE, the initial
#               window changed by SETTINGS), RST_STREAM, GOAWAY (refused
#               streams), PING, PUSH_PROMISE refused, malformed field blocks,
#               connection and stream errors, RFC 9218's PRIORITY_UPDATE
#   priority    RFC 9218's Priority field and the server scheduler's order
#   asyncio     h2.client / h2.server over a real localhost socket: streams
#               multiplexed, flow control blocking and resuming, RST_STREAM
#               both ways, a graceful GOAWAY, a protocol error's GOAWAY, the
#               scheduler's order on the wire, TLS with ALPN "h2" (a throwaway
#               CA made with the openssl command)
#   http.client http2=True / "prior_knowledge" and urllib.request (Nython-only)
#   deflate     RFC 7692: its examples, the parameter negotiation, context
#               takeover, window bits, RSV1 rules, a decompression bomb;
#               websocket.ny (Nython-only) and websocket_asyncio.ny round trips
#
# The shared part runs under python3 too (`python3 examples/vm_audit123.ny`):
# there lib/hpack.ny, lib/h2/, lib/permessage_deflate.ny and
# lib/websocket_asyncio.ny - written in the subset both run - are loaded with
# importlib, over CPython's asyncio, ssl and zlib. Nython-only: http.client /
# urllib with HTTP/2 and lib/websocket.ny (Nython's modules), and one RFC 7692
# example whose second message Nython's DEFLATE encodes in 4 octets where
# zlib takes 5 (both decode to the same; checked as such).
#
#     ./build/nython-cli examples/vm_audit123.ny
#     ./build/nython-cli --vm examples/vm_audit123.ny
#     python3 examples/vm_audit123.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import sys
import time
import asyncio
import shutil
import subprocess
import tempfile
import threading
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

if not nython:
    import importlib.machinery
    import importlib.util

    class _NyFinder:
        # lib/hpack.ny, lib/h2/*.ny ... for python3
        names = ("hpack", "h2", "permessage_deflate", "websocket_asyncio")

        @classmethod
        def find_spec(cls, name, path=None, target=None):
            if name.split(".")[0] not in cls.names:
                return None
            base = os.path.join(ROOT, "lib", *name.split("."))
            if os.path.isdir(base):
                fn = os.path.join(base, "__init__.ny")
                return importlib.util.spec_from_file_location(
                    name, fn, loader=importlib.machinery.SourceFileLoader(name, fn), submodule_search_locations=[base])
            fn = base + ".ny"
            if os.path.exists(fn):
                return importlib.util.spec_from_file_location(name, fn, loader=importlib.machinery.SourceFileLoader(name, fn))
            return None
    sys.meta_path.insert(0, _NyFinder)

import hpack
import h2.connection
import h2.config
import h2.events
import h2.errors
import h2.exceptions
import h2.frame
import h2.settings
import h2.priority
import h2.client
import h2.server
import permessage_deflate as pmd
import websocket_asyncio as wsa
from h2.errors import ErrorCodes
from h2.settings import SettingCodes

results = []
skipped = []


def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])


def raises(fn):
    try:
        fn()
    except Exception as e:
        return type(e).__name__
    return "no error"


TMP = tempfile.mkdtemp(prefix="ny_audit123_%d_" % os.getpid())


# ═══════════════════════════════════════════════════════════════════════════
# 1. HPACK
# ═══════════════════════════════════════════════════════════════════════════
RFC7541_C = [
    ('C.2.1.', '400a637573746f6d2d6b65790d637573746f6d2d686561646572', [('custom-key', 'custom-header')], [('custom-key', 'custom-header', 55)], 55),
    ('C.2.2.', '040c2f73616d706c652f70617468', [(':path', '/sample/path')], [], 0),
    ('C.2.3.', '100870617373776f726406736563726574', [('password', 'secret')], [], 0),
    ('C.2.4.', '82', [(':method', 'GET')], [], 0),
    ('C.3.1.', '828684410f7777772e6578616d706c652e636f6d', [(':method', 'GET'), (':scheme', 'http'), (':path', '/'), (':authority', 'www.example.com')], [(':authority', 'www.example.com', 57)], 57),
    ('C.3.2.', '828684be58086e6f2d6361636865', [(':method', 'GET'), (':scheme', 'http'), (':path', '/'), (':authority', 'www.example.com'), ('cache-control', 'no-cache')], [('cache-control', 'no-cache', 53), (':authority', 'www.example.com', 57)], 110),
    ('C.3.3.', '828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565', [(':method', 'GET'), (':scheme', 'https'), (':path', '/index.html'), (':authority', 'www.example.com'), ('custom-key', 'custom-value')], [('custom-key', 'custom-value', 54), ('cache-control', 'no-cache', 53), (':authority', 'www.example.com', 57)], 164),
    ('C.4.1.', '828684418cf1e3c2e5f23a6ba0ab90f4ff', [(':method', 'GET'), (':scheme', 'http'), (':path', '/'), (':authority', 'www.example.com')], [(':authority', 'www.example.com', 57)], 57),
    ('C.4.2.', '828684be5886a8eb10649cbf', [(':method', 'GET'), (':scheme', 'http'), (':path', '/'), (':authority', 'www.example.com'), ('cache-control', 'no-cache')], [('cache-control', 'no-cache', 53), (':authority', 'www.example.com', 57)], 110),
    ('C.4.3.', '828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf', [(':method', 'GET'), (':scheme', 'https'), (':path', '/index.html'), (':authority', 'www.example.com'), ('custom-key', 'custom-value')], [('custom-key', 'custom-value', 54), ('cache-control', 'no-cache', 53), (':authority', 'www.example.com', 57)], 164),
    ('C.5.1.', '4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d546e1768747470733a2f2f7777772e6578616d706c652e636f6d', [(':status', '302'), ('cache-control', 'private'), ('date', 'Mon, 21 Oct 2013 20:13:21 GMT'), ('location', 'https://www.example.com')], [('location', 'https://www.example.com', 63), ('date', 'Mon, 21 Oct 2013 20:13:21 GMT', 65), ('cache-control', 'private', 52), (':status', '302', 42)], 222),
    ('C.5.2.', '4803333037c1c0bf', [(':status', '307'), ('cache-control', 'private'), ('date', 'Mon, 21 Oct 2013 20:13:21 GMT'), ('location', 'https://www.example.com')], [(':status', '307', 42), ('location', 'https://www.example.com', 63), ('date', 'Mon, 21 Oct 2013 20:13:21 GMT', 65), ('cache-control', 'private', 52)], 222),
    ('C.5.3.', '88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d4153444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31', [(':status', '200'), ('cache-control', 'private'), ('date', 'Mon, 21 Oct 2013 20:13:22 GMT'), ('location', 'https://www.example.com'), ('content-encoding', 'gzip'), ('set-cookie', 'foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1')], [('set-cookie', 'foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1', 98), ('content-encoding', 'gzip', 52), ('date', 'Mon, 21 Oct 2013 20:13:22 GMT', 65)], 215),
    ('C.6.1.', '488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3', [(':status', '302'), ('cache-control', 'private'), ('date', 'Mon, 21 Oct 2013 20:13:21 GMT'), ('location', 'https://www.example.com')], [('location', 'https://www.example.com', 63), ('date', 'Mon, 21 Oct 2013 20:13:21 GMT', 65), ('cache-control', 'private', 52), (':status', '302', 42)], 222),
    ('C.6.2.', '4883640effc1c0bf', [(':status', '307'), ('cache-control', 'private'), ('date', 'Mon, 21 Oct 2013 20:13:21 GMT'), ('location', 'https://www.example.com')], [(':status', '307', 42), ('location', 'https://www.example.com', 63), ('date', 'Mon, 21 Oct 2013 20:13:21 GMT', 65), ('cache-control', 'private', 52)], 222),
    ('C.6.3.', '88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007', [(':status', '200'), ('cache-control', 'private'), ('date', 'Mon, 21 Oct 2013 20:13:22 GMT'), ('location', 'https://www.example.com'), ('content-encoding', 'gzip'), ('set-cookie', 'foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1')], [('set-cookie', 'foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1', 98), ('content-encoding', 'gzip', 52), ('date', 'Mon, 21 Oct 2013 20:13:22 GMT', 65)], 215),
]


def test_hpack():
    # C.1: integers
    check("C.1.1 10 with a 5-bit prefix", bytes(hpack.encode_integer(10, 5)).hex(), "0a")
    check("C.1.2 1337 with a 5-bit prefix", bytes(hpack.encode_integer(1337, 5)).hex(), "1f9a0a")
    check("C.1.3 42 at an octet boundary", bytes(hpack.encode_integer(42, 8)).hex(), "2a")
    check("integers decode", [hpack.decode_integer(bytes.fromhex("0a"), 5), hpack.decode_integer(bytes.fromhex("1f9a0a"), 5),
                              hpack.decode_integer(bytes.fromhex("ff00"), 8), hpack.decode_integer(bytes.fromhex("7f8001"), 7)],
          [(10, 1), (1337, 3), (255, 2), (255, 3)])
    check("integer round trips", [hpack.decode_integer(bytes(hpack.encode_integer(n, p)), p)[0] == n
                                  for n in (0, 30, 31, 32, 127, 128, 2 ** 14, 2 ** 31 - 1, 2 ** 40) for p in (4, 5, 6, 7, 8)],
          [True] * 45)
    check("integer errors", [raises(lambda: hpack.decode_integer(b"\x1f\x9a", 5)), raises(lambda: hpack.encode_integer(-1, 5)),
                             raises(lambda: hpack.encode_integer(1, 9)), raises(lambda: hpack.decode_integer(b"\x1f" + b"\xff" * 12 + b"\x01", 5))],
          ["HPACKDecodingError", "ValueError", "ValueError", "HPACKDecodingError"])
    # Appendix B
    codes = hpack.HUFFMAN_CODES
    lens = hpack.HUFFMAN_CODE_LENGTHS
    acc = 0
    for i in range(257):
        acc = (acc * 1000003 + codes[i] * 31 + lens[i]) % (2 ** 61 - 1)
    check("Appendix B: all 257 codes (checksum of the RFC's table)", acc, 466510242789313091)
    check("Appendix B: some codes", [(hex(codes[s]), lens[s]) for s in (0, 10, 32, 47, 48, 97, 126, 255, 256)],
          [("0x1ff8", 13), ("0x3ffffffc", 30), ("0x14", 6), ("0x18", 6), ("0x0", 5), ("0x3", 5), ("0x1ffd", 13),
           ("0x3ffffee", 26), ("0x3fffffff", 30)])
    check("Huffman: www.example.com (C.4.1)", hpack.huffman_encode(b"www.example.com").hex(), "f1e3c2e5f23a6ba0ab90f4ff")
    allbytes = bytes(range(256))
    check("Huffman round trips", [hpack.huffman_decode(hpack.huffman_encode(x)) == x for x in
                                  (b"", b"a", b"no-cache", allbytes, allbytes * 3, b"\x00\xff" * 50)], [True] * 6)
    check("Huffman decoding errors", [raises(lambda: hpack.huffman_decode(b"\xff\xff\xff\xff")),     # EOS inside
                                      raises(lambda: hpack.huffman_decode(b"\x1f\xff")),             # 0 + 11 ones of padding
                                      raises(lambda: hpack.huffman_decode(b"\x00")),                 # padding of zeros
                                      raises(lambda: hpack.huffman_decode(b"\xfe")),                # an 8-bit prefix of a longer code
                                      hpack.huffman_decode(b"\x1f")],                               # 'a' (00011) + 3 bits of padding
          ["HPACKDecodingError", "HPACKDecodingError", "HPACKDecodingError", "HPACKDecodingError", b"a"])
    # Appendix C, encoder and decoder each through every example
    enc = none
    dec = none
    for sec, hx, hdrs, table, size in RFC7541_C:
        if sec.endswith(".1.") or sec.startswith("C.2"):
            enc = hpack.Encoder()
            dec = hpack.Decoder()
            if sec.startswith("C.5") or sec.startswith("C.6"):
                enc.header_table.maxsize = 256      # the examples' SETTINGS, already agreed
                dec.header_table_size = 256
        huff = sec.startswith("C.4") or sec.startswith("C.6")
        if sec == "C.2.2.":
            out = hpack.Encoder(policy=hpack.IndexNone()).encode(hdrs, huffman=false)     # literal without indexing
        elif sec == "C.2.3.":
            out = enc.encode([(hdrs[0][0], hdrs[0][1], true)], huffman=false)           # sensitive: never indexed
        else:
            out = enc.encode(hdrs, huffman=huff)
        got = dec.decode(bytes.fromhex(hx))
        dt = [(n.decode(), v.decode(), 32 + len(n) + len(v)) for n, v in dec.header_table.dynamic_entries]
        check("RFC 7541 " + sec + " encoded", out.hex(), hx)
        check("RFC 7541 " + sec + " decoded", [tuple(g) for g in got], hdrs)
        check("RFC 7541 " + sec + " dynamic table", [dt, dec.header_table.current_size], [table, size])
        if sec != "C.2.2." and sec != "C.2.3.":
            et = [(n.decode(), v.decode(), 32 + len(n) + len(v)) for n, v in enc.header_table.dynamic_entries]
            check("RFC 7541 " + sec + " encoder's table", et, table)
    d = hpack.Decoder()
    got = d.decode(bytes.fromhex("100870617373776f726406736563726574"))
    check("never-indexed fields decode as NeverIndexedHeaderTuple",
          [type(got[0]).__name__, got[0].indexable, type(d.decode(b"\x82")[0]).__name__], ["NeverIndexedHeaderTuple", false, "HeaderTuple"])
    check("raw=True gives bytes", [tuple(x) for x in hpack.Decoder().decode(bytes.fromhex("828684"), raw=true)],
          [(b":method", b"GET"), (b":scheme", b"http"), (b":path", b"/")])
    e = hpack.Encoder()
    check("a dict puts pseudo-headers first", hpack.Decoder().decode(e.encode({"x-a": "1", ":method": "GET", ":path": "/"})),
          [(":method", "GET"), (":path", "/"), ("x-a", "1")])
    check("NeverIndexedHeaderTuple is never indexed",
          [hpack.Encoder().encode([hpack.NeverIndexedHeaderTuple("authorization", "s3cr3t")], huffman=false).hex()],
          ["1f0806" + b"s3cr3t".hex()])
    # size updates (4.2): the smallest since the last block, then the final
    e = hpack.Encoder()
    e.header_table_size = 100
    e.header_table_size = 0
    e.header_table_size = 2000
    blk = e.encode([(":method", "GET")])
    check("size updates: smallest then final", blk.hex(), "203fb10f82")
    e.header_table_size = 3000
    check("one size update", e.encode([(":method", "GET")]).hex(), "3f991782")
    d = hpack.Decoder()
    d.decode(blk)
    check("decoder applies size updates", d.header_table_size, 2000)
    d = hpack.Decoder()
    d.max_allowed_table_size = 1024
    check("decoder errors", [raises(lambda: hpack.Decoder().decode(b"\xbe")),                          # index 62, empty table
                             raises(lambda: hpack.Decoder().decode(b"\x80")),                          # index 0
                             raises(lambda: d.decode(b"\x3f\xe1\x0f")),                                 # 2048 > 1024
                             raises(lambda: hpack.Decoder().decode(b"\x82\x20")),                      # update after a field
                             raises(lambda: hpack.Decoder().decode(b"\x40\x0a" + b"custom")),           # truncated string
                             raises(lambda: hpack.Decoder(max_header_list_size=50).decode(bytes.fromhex(RFC7541_C[0][1]))),
                             raises(lambda: hpack.Decoder().decode(b"\x40\x81\xff\x00"))],              # bad Huffman name
          ["InvalidTableIndexError", "InvalidTableIndexError", "InvalidTableSizeError", "HPACKDecodingError",
           "HPACKDecodingError", "OversizedHeaderListError", "HPACKDecodingError"])
    check("error classes", [issubclass(hpack.InvalidTableIndex, hpack.InvalidTableIndexError),
                            issubclass(hpack.OversizedHeaderListError, hpack.HPACKDecodingError),
                            issubclass(hpack.HPACKDecodingError, hpack.HPACKError)], [true, true, true])
    t = hpack.HeaderTable()
    t.maxsize = 100
    t.add(b"a", b"x" * 30)
    t.add(b"b", b"y" * 30)
    check("eviction is FIFO (4.4)", [[n for n, v in t.dynamic_entries], t.current_size], [[b"b"], 63])
    t.add(b"big", b"z" * 200)
    check("an entry larger than the table empties it", [len(t.dynamic_entries), t.current_size], [0, 0])
    t = hpack.HeaderTable()
    t.add(b"x-k", b"v1")
    t.add(b"x-k", b"v2")
    check("search: static first, newest dynamic match", [t.search(b":method", b"GET"), t.search(b"x-k", b"v1"),
                                                          t.search(b"x-k", b"zz"), t.search(b"cookie", b"zz"), t.search(b"no", b"no")],
          [(2, b":method", b"GET"), (63, b"x-k", b"v1"), (62, b"x-k", None), (32, b"cookie", None), None])
    # huffman=True leaves a string literal when Huffman would be longer
    e = hpack.Encoder()
    raw = e.encode([("x-bin", "\x00\x01\x02")], huffman=true)
    check("Huffman only when shorter (the name coded, the value not)", raw.hex(), "4084f2b466ab03000102")
    check("the hpack package's API", [hpack.__version__, hasattr(hpack.Encoder(), "header_table_size"),
                                      hasattr(hpack.Decoder(), "max_header_list_size")], ["4.2.0", true, true])


# ── the indexing policies on a header corpus (Nython's) ─────────────────────
class LCG:
    def __init__(self, seed):
        self.x = seed

    def next(self):
        self.x = (self.x * 6364136223846793005 + 1442695040888963407) % (2 ** 64)
        return self.x >> 33

    def hex(self, n):
        out = ""
        while len(out) < n:
            out += "%08x" % self.next()
        return out[:n]

    def b64(self, n):
        alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        return "".join([alpha[self.next() % 64] for i in range(n)])


def header_corpus():
    # A browsing session on one connection: 80 requests (a page, its CSS,
    # scripts, images, fonts, API calls with a bearer token) and their
    # responses, as each side's encoder sees them.
    r = LCG(86)
    ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    session = r.hex(32)
    token = r.b64(43)
    ga = "GA1.2.%d.%d" % (r.next() % 10 ** 9, 1700000000 + r.next() % 10 ** 6)
    reqs = []
    resps = []
    clock = 1700000000
    kinds = ["html", "css", "js", "js", "img", "img", "img", "api", "api", "font"]
    for i in range(80):
        kind = kinds[r.next() % len(kinds)] if i else "html"
        if kind == "html":
            path, accept = "/", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        elif kind == "css":
            path, accept = "/static/css/main.%s.css" % r.hex(8), "text/css,*/*;q=0.1"
        elif kind == "js":
            path, accept = "/static/js/chunk-%d.%s.js" % (r.next() % 40, r.hex(8)), "*/*"
        elif kind == "img":
            path, accept = "/media/photos/%d.webp" % (r.next() % 500), "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
        elif kind == "font":
            path, accept = "/static/fonts/inter-%d.woff2" % (r.next() % 4), "*/*"
        else:
            path, accept = "/api/v2/items?page=%d&_=%d" % (r.next() % 9, clock * 1000 + r.next() % 1000), "application/json"
        h = [(":method", "GET"), (":scheme", "https"), (":authority", "www.example.com"), (":path", path),
             ("user-agent", ua), ("accept", accept), ("accept-encoding", "gzip, deflate, br"),
             ("accept-language", "en-US,en;q=0.9"), ("referer", "https://www.example.com/"),
             ("cookie", "session=" + session), ("cookie", "_ga=" + ga)]
        if kind == "api":
            h.append(("authorization", "Bearer " + token))
        h.append(("x-request-id", "%s-%s-%s" % (r.hex(8), r.hex(4), r.hex(12))))
        reqs.append(h)
        clock += r.next() % 2
        status = "304" if kind in ("css", "js") and r.next() % 3 == 0 else "200"
        ctype = {"html": "text/html; charset=utf-8", "css": "text/css", "js": "application/javascript",
                 "img": "image/webp", "font": "font/woff2", "api": "application/json"}[kind]
        rh = [(":status", status), ("date", "Tue, 14 Nov 2023 22:%02d:%02d GMT" % ((clock // 60) % 60, clock % 60)),
              ("server", "nython-h2"), ("content-type", ctype)]
        if status == "200":
            rh.append(("content-length", str(200 + r.next() % 90000)))
        rh.append(("etag", '"%s"' % r.hex(16)))
        rh.append(("cache-control", "public, max-age=31536000, immutable" if kind in ("css", "js", "font") else "no-cache"))
        rh.append(("vary", "accept-encoding"))
        rh.append(("strict-transport-security", "max-age=63072000; includeSubDomains; preload"))
        rh.append(("x-request-id", reqs[-1][-1][1]))
        if kind == "api" and r.next() % 4 == 0:
            rh.append(("set-cookie", "csrf=%s; Path=/; Secure; HttpOnly; SameSite=Strict" % r.b64(24)))
        resps.append(rh)
    return reqs, resps


REPORT = []


def test_policies():
    reqs, resps = header_corpus()
    rows = {}
    for label, blocks in (("requests", reqs), ("responses", resps)):
        for ts in (4096, 1024):
            rep = hpack.compression_report(blocks, table_size=ts)
            rows[(label, ts)] = rep
            REPORT.append("  %-9s table %4d: raw %5d  index-all %5d (%.2fx)  smart %5d (%.2fx)  index-none %5d (%.2fx)" % (
                label, ts, rep["raw"], rep["index-all"]["bytes"], rep["index-all"]["ratio"],
                rep["smart"]["bytes"], rep["smart"]["ratio"], rep["index-none"]["bytes"], rep["index-none"]["ratio"]))
    check("corpus sizes", [rows[("requests", 4096)]["raw"], rows[("responses", 4096)]["raw"]], [39327, 26262])
    check("index-all is the hpack package's output (requests, 4 KiB)", rows[("requests", 4096)]["index-all"]["bytes"], 5223)
    check("smart: requests, 4 KiB and 1 KiB tables",
          [rows[("requests", 4096)]["smart"]["bytes"], rows[("requests", 1024)]["smart"]["bytes"]], [5039, 5542])
    check("smart: responses, 4 KiB and 1 KiB tables",
          [rows[("responses", 4096)]["smart"]["bytes"], rows[("responses", 1024)]["smart"]["bytes"]], [6324, 7337])
    check("smart beats index-all where the table is under pressure",
          [rows[("requests", 1024)]["smart"]["bytes"] < rows[("requests", 1024)]["index-all"]["bytes"],
           rows[("responses", 1024)]["smart"]["bytes"] < rows[("responses", 1024)]["index-all"]["bytes"],
           rows[("requests", 4096)]["smart"]["bytes"] < rows[("requests", 4096)]["index-all"]["bytes"]], [true, true, true])
    # what SmartIndexing decides, field by field
    p = hpack.SmartIndexing()
    t = hpack.HeaderTable()
    check("smart: decisions", [p.decide(b"cookie", b"sid=12345", t), p.decide(b"authorization", b"Basic YTpi", t),
                               p.decide(b"x-request-id", b"9f2c1e7a-41d2-8a0b-77c3e9d1f0a2", t),
                               p.decide(b"x-request-id", b"9f2c1e7a-41d2-8a0b-77c3e9d1f0a2", t),
                               p.decide(b"accept", b"text/html", t), p.decide(b"x-big", b"q" * 2000, t)],
          ["never", "never", "literal", "index", "index", "literal"])
    e = hpack.Encoder(policy=hpack.SmartIndexing())
    d = hpack.Decoder()
    for i in range(40):
        d.decode(e.encode([("content-length", str(1000 + i * 7))]))
    check("smart: RFC 7541 7.1.2's penalty for a name with many values",
          [e.policy.lookup(b"content-length"), len(e.header_table.dynamic_entries) < 10], [false, true])


# ═══════════════════════════════════════════════════════════════════════════
# 2. frames (byte for byte with hyperframe)
# ═══════════════════════════════════════════════════════════════════════════
FRAME_VECTORS = [
    ("DataFrame", (1,), {"data": b"hello", "flags": ["END_STREAM"]}, "00000500010000000168656c6c6f"),
    ("DataFrame", (3,), {"data": b"padded", "flags": ["PADDED"], "pad_length": 4}, "00000b0008000000030470616464656400000000"),
    ("HeadersFrame", (1,), {"data": b"\x82\x86\x84", "flags": ["END_HEADERS", "END_STREAM"]}, "000003010500000001828684"),
    ("HeadersFrame", (5,), {"data": b"\x88", "flags": ["END_HEADERS", "PRIORITY", "PADDED"], "pad_length": 2, "depends_on": 3,
                            "stream_weight": 200, "exclusive": true}, "000009012c000000050280000003c8880000"),
    ("PriorityFrame", (7,), {"depends_on": 1, "stream_weight": 15, "exclusive": false}, "000005020000000007000000010f"),
    ("RstStreamFrame", (9,), {"error_code": 8}, "00000403000000000900000008"),
    ("SettingsFrame", (0,), {"settings": {1: 4096, 2: 0, 3: 100, 4: 65535, 5: 16384, 6: 65536}},
     "00002404000000000000010000100000020000000000030000006400040000ffff000500004000000600010000"),
    ("SettingsFrame", (0,), {"flags": ["ACK"]}, "000000040100000000"),
    ("PushPromiseFrame", (1,), {"promised_stream_id": 2, "data": b"\x82\x87", "flags": ["END_HEADERS"]}, "000006050400000001000000028287"),
    ("PingFrame", (0,), {"opaque_data": b"12345678"}, "0000080600000000003132333435363738"),
    ("PingFrame", (0,), {"opaque_data": b"abc", "flags": ["ACK"]}, "0000080601000000006162630000000000"),
    ("GoAwayFrame", (0,), {"last_stream_id": 7, "error_code": 1, "additional_data": b"bye"}, "00000b0700000000000000000700000001627965"),
    ("WindowUpdateFrame", (0,), {"window_increment": 2 ** 31 - 1}, "0000040800000000007fffffff"),
    ("WindowUpdateFrame", (5,), {"window_increment": 1}, "00000408000000000500000001"),
    ("ContinuationFrame", (1,), {"data": b"\x41\x0fwww.example.com", "flags": ["END_HEADERS"]},
     "000011090400000001410f7777772e6578616d706c652e636f6d"),
    ("AltSvcFrame", (0,), {"origin": b"example.com", "field": b'h2=":8000"; ma=60'},
     "00001e0a0000000000000b6578616d706c652e636f6d68323d223a38303030223b206d613d3630"),
    ("PriorityUpdateFrame", (0,), {"prioritized_stream_id": 1, "priority_field_value": b"u=1, i"}, "00000a10000000000000000001753d312c2069"),
]


def parse_wire(wire):
    f, n = h2.frame.Frame.parse_frame_header(memoryview(wire[:9]))
    f.parse_body(memoryview(wire[9:9 + n]))
    return f


def test_frames():
    F = h2.frame
    for name, args, kw, hx in FRAME_VECTORS:
        f = getattr(F, name)(*args, **kw)
        wire = f.serialize()
        check("frame " + name + " " + repr(sorted(kw.get("flags", []))) + " serialized", wire.hex(), hx)
        g = parse_wire(bytes.fromhex(hx))
        check("frame " + name + " parsed back", [type(g).__name__, g.stream_id, sorted(g.flags), g.serialize().hex()],
              [name, args[0] if args else 0, sorted(kw.get("flags", [])), hx])
    g = parse_wire(bytes.fromhex("000009012c000000050280000003c8880000"))
    check("HEADERS priority fields", [g.depends_on, g.stream_weight, g.exclusive, g.pad_length, g.data], [3, 200, true, 2, b"\x88"])
    g = parse_wire(bytes.fromhex("00000b0008000000030470616464656400000000"))
    check("DATA padding and flow-controlled length", [g.data, g.pad_length, g.flow_controlled_length], [b"padded", 4, 11])
    g = parse_wire(bytes.fromhex("00002404000000000000010000100000020000000000030000006400040000ffff000500004000000600010000"))
    check("SETTINGS parsed", g.settings, {1: 4096, 2: 0, 3: 100, 4: 65535, 5: 16384, 6: 65536})
    e = F.ExtensionFrame(type=0xFA, stream_id=3, flag_byte=5, body=b"ext")
    check("an extension frame keeps its type, flags and payload",
          [e.serialize().hex(), type(parse_wire(e.serialize())).__name__, parse_wire(e.serialize()).body], ["000003fa0500000003657874", "ExtensionFrame", b"ext"])
    check("strict parsing refuses unknown types", raises(lambda: F.Frame.parse_frame_header(memoryview(bytes.fromhex("000000fa0000000000")), true)),
          "UnknownFrameError")
    check("repr", repr(F.RstStreamFrame(3, 8)), "RstStreamFrame(stream_id=3, flags=[]): error_code=8")
    check("frame errors", [raises(lambda: parse_wire(bytes.fromhex("000004020000000001" + "00000000"))),       # PRIORITY of 4
                           raises(lambda: parse_wire(bytes.fromhex("000003030000000001" + "000000"))),         # RST_STREAM of 3
                           raises(lambda: parse_wire(bytes.fromhex("000005040000000000" + "0001000010"))),     # SETTINGS of 5
                           raises(lambda: parse_wire(bytes.fromhex("000007060000000000" + "00" * 7))),         # PING of 7
                           raises(lambda: parse_wire(bytes.fromhex("000003000800000001" + "056869"))),         # pad 5 > 2
                           raises(lambda: parse_wire(bytes.fromhex("000002000000000000" + "6869"))),           # DATA on stream 0
                           raises(lambda: parse_wire(bytes.fromhex("000008070000000001" + "00" * 8))),         # GOAWAY on stream 1
                           raises(lambda: F.PingFrame(0, b"123456789").serialize()),
                           raises(lambda: F.DataFrame(1, flags=["ACK"]))],
          ["InvalidFrameError", "InvalidFrameError", "InvalidFrameError", "InvalidFrameError", "InvalidPaddingError",
           "InvalidDataError", "InvalidDataError", "InvalidFrameError", "ValueError"])
    check("flags: a set of the defined names", [sorted(F.HeadersFrame(1, flags=["END_STREAM", "PRIORITY"]).flags),
                                                "END_HEADERS" in F.HeadersFrame(1).flags, len(F.DataFrame(1, flags=["PADDED"]).flags)],
          [["END_STREAM", "PRIORITY"], false, 1])
    check("FRAMES", sorted(F.FRAMES.keys()), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 16])


# ═══════════════════════════════════════════════════════════════════════════
# 3. the connection state machine, in memory
# ═══════════════════════════════════════════════════════════════════════════
def pair(client_settings=none, server_settings=none, enc="utf-8"):
    c = h2.connection.H2Connection(h2.config.H2Configuration(client_side=true, header_encoding=enc))
    s = h2.connection.H2Connection(h2.config.H2Configuration(client_side=false, header_encoding=enc))
    for conn, st in ((c, client_settings), (s, server_settings)):
        if st:
            for k in st:
                conn.local_settings[k] = st[k]
            conn.local_settings.acknowledge()
        conn.initiate_connection()
    pump(c, s)
    return c, s


def pump(a, b):
    # move bytes both ways until both are quiet; the events, (side, event)
    evs = []
    while true:
        d1 = a.data_to_send()
        d2 = b.data_to_send()
        if not d1 and not d2:
            return evs
        if d1:
            evs += [("s", e) for e in b.receive_data(d1)]
        if d2:
            evs += [("c", e) for e in a.receive_data(d2)]


def names(evs):
    return [side + ":" + type(e).__name__ for side, e in evs]


REQ = [(":method", "GET"), (":scheme", "https"), (":authority", "example.org"), (":path", "/")]


def frames_of(data):
    out = []
    i = 0
    while i + 9 <= len(data):
        n = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]
        out.append(parse_wire(data[i:i + 9 + n]))
        i += 9 + n
    return out


def test_connection():
    c = h2.connection.H2Connection(h2.config.H2Configuration(client_side=true))
    c.initiate_connection()
    pre = c.data_to_send()
    check("the client preface: magic, then SETTINGS with every local setting",
          [pre[:24], [type(f).__name__ for f in frames_of(pre[24:])], frames_of(pre[24:])[0].settings],
          [b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", ["SettingsFrame"], {1: 4096, 2: 0, 4: 65535, 5: 16384, 8: 0, 3: 100, 6: 65536}])
    s = h2.connection.H2Connection(h2.config.H2Configuration(client_side=false))
    s.initiate_connection()
    evs = s.receive_data(pre)
    check("the server ACKs and reports the client's settings",
          [names([("s", e) for e in evs]), [type(f).__name__ for f in frames_of(s.data_to_send())]],
          [["s:RemoteSettingsChanged"], ["SettingsFrame", "SettingsFrame"]])
    c, s = pair()
    check("both sides open", [c.state_machine.name, s.state_machine.name, c.remote_settings.max_concurrent_streams], ["CLIENT_OPEN", "SERVER_OPEN", 100])
    sid = c.get_next_available_stream_id()
    c.send_headers(sid, REQ + [("user-agent", "t"), ("cookie", "a=1"), ("cookie", "b=2")], end_stream=true)
    evs = pump(c, s)
    check("a request: RequestReceived + StreamEnded, cookies joined", [names(evs), evs[0][1].headers[-1], evs[0][1].stream_ended is not none],
          [["s:RequestReceived", "s:StreamEnded"], ("cookie", "a=1; b=2"), true])
    s.send_headers(sid, [(":status", "103"), ("link", "</s.css>; rel=preload")])
    s.send_headers(sid, [(":status", "200"), ("content-length", "5")])
    s.send_data(sid, b"hel")
    s.send_data(sid, b"lo", end_stream=true, pad_length=10)
    evs = pump(c, s)
    check("1xx, response, padded DATA", [names(evs), [e.flow_controlled_length for side, e in evs if isinstance(e, h2.events.DataReceived)]],
          [["c:InformationalResponseReceived", "c:ResponseReceived", "c:DataReceived", "c:DataReceived", "c:StreamEnded"], [3, 13]])
    check("the stream is gone on both sides", [sid in c.streams, sid in s.streams], [false, false])
    # trailers
    sid = c.get_next_available_stream_id()
    c.send_headers(sid, [(":method", "POST")] + REQ[1:])
    c.send_data(sid, b"body")
    c.send_headers(sid, [("x-trailer", "t")], end_stream=true)
    evs = pump(c, s)
    check("request trailers", [names(evs), evs[-2][1].headers], [["s:RequestReceived", "s:DataReceived", "s:TrailersReceived", "s:StreamEnded"], [("x-trailer", "t")]])
    check("trailers must end the stream", raises(lambda: s.send_headers(sid, [("x", "y")])), "ProtocolError")
    s.send_headers(sid, [(":status", "200")])
    s.send_headers(sid, [("grpc-status", "0")], end_stream=true)
    evs = pump(c, s)
    check("response trailers", names(evs), ["c:ResponseReceived", "c:TrailersReceived", "c:StreamEnded"])
    # CONTINUATION: a field block over the peer's frame size
    sid = c.get_next_available_stream_id()
    big = [("x-big-%d" % i, "v" * 900) for i in range(40)]
    c.send_headers(sid, REQ + big, end_stream=true)
    wire = c.data_to_send()
    kinds = [type(f).__name__ for f in frames_of(wire)]
    evs = [("s", e) for e in s.receive_data(wire)]
    check("CONTINUATION frames carry a large field block", [kinds[0], kinds.count("ContinuationFrame") >= 1, len(evs[0][1].headers)],
          ["HeadersFrame", true, 44])
    s.reset_stream(sid, ErrorCodes.CANCEL)
    pump(c, s)
    # flow control
    sid = c.get_next_available_stream_id()
    c.send_headers(sid, [(":method", "POST")] + REQ[1:])
    sent = 0
    while c.local_flow_control_window(sid) > 0:
        n = min(16384, c.local_flow_control_window(sid))
        c.send_data(sid, b"x" * n)
        sent += n
    check("the connection window (65535, 4 octets already used), then FlowControlError",
          [sent, raises(lambda: c.send_data(sid, b"x")), c.outbound_flow_control_window], [65531, "FlowControlError", 0])
    evs = pump(c, s)
    for side, e in evs:
        if isinstance(e, h2.events.DataReceived):
            s.acknowledge_received_data(e.flow_controlled_length, e.stream_id)
    evs = pump(c, s)
    check("acknowledged data reopens the windows (WINDOW_UPDATE)",
          [[(e.stream_id, e.delta) for side, e in evs], c.local_flow_control_window(sid)],
          [[(0, 16384), (sid, 32768), (0, 32768)], 32772])
    s.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 1000})
    evs = pump(c, s)
    check("SETTINGS_INITIAL_WINDOW_SIZE moves every stream's window", [names(evs), c.streams[sid].outbound_flow_control_window],
          [["c:RemoteSettingsChanged", "s:SettingsAcknowledged"], 32772 - 65535 + 1000])
    s.increment_flow_control_window(70000, sid)
    s.increment_flow_control_window(70000)
    evs = pump(c, s)
    check("explicit WINDOW_UPDATEs", [(e.stream_id, e.delta) for side, e in evs], [(sid, 70000), (0, 70000)])
    c.reset_stream(sid, ErrorCodes.CANCEL)
    evs = pump(c, s)
    check("RST_STREAM", [names(evs), evs[0][1].error_code, evs[0][1].remote_reset], [["s:StreamReset"], ErrorCodes.CANCEL, true])
    check("a reset stream refuses more", [raises(lambda: c.send_data(sid, b"x")), raises(lambda: c.reset_stream(sid))],
          ["StreamClosedError", "StreamClosedError"])
    # PING
    c.ping(b"12345678")
    evs = pump(c, s)
    check("PING and its ACK", [names(evs), evs[1][1].ping_data], [["s:PingReceived", "c:PingAckReceived"], b"12345678"])
    check("PING data must be 8 octets", raises(lambda: c.ping(b"short")), "ValueError")
    # malformed requests are stream errors (RFC 9113 8.1.1)
    bad = [REQ + [("Upper", "x")], REQ + [("connection", "keep-alive")], REQ[:3], [REQ[1]] + [REQ[0]] + REQ[2:] + [("a", "b"), (":x", "y")],
           REQ + [("te", "gzip")], REQ + [("x", " padded")], [(":method", "CONNECT"), (":authority", "a:1"), (":path", "/")]]
    out = []
    for hdrs in bad:
        sid = c.get_next_available_stream_id()
        c.config.validate_outbound_headers = false
        c.config.normalize_outbound_headers = false
        c.send_headers(sid, hdrs, end_stream=true)
        evs = pump(c, s)
        out.append([names(evs), evs[0][1].error_code if evs else none])
    c.config.validate_outbound_headers = true
    c.config.normalize_outbound_headers = true
    check("malformed field blocks reset with PROTOCOL_ERROR", out,
          [[["s:StreamReset", "c:StreamReset"], ErrorCodes.PROTOCOL_ERROR]] * len(bad))
    check("our own field blocks are checked", [raises(lambda: c.send_headers(c.get_next_available_stream_id(), REQ + [("connection", "x")])),
                                               raises(lambda: c.send_headers(c.get_next_available_stream_id(), REQ[:2]))],
          ["ProtocolError", "ProtocolError"])
    # content-length must match the body
    sid = c.get_next_available_stream_id()
    c.send_headers(sid, [(":method", "POST")] + REQ[1:] + [("content-length", "10")])
    c.send_data(sid, b"short", end_stream=true)
    evs = pump(c, s)
    check("content-length mismatch: PROTOCOL_ERROR", names(evs), ["s:RequestReceived", "s:StreamReset", "c:StreamReset"])
    # RFC 9218
    sid = c.get_next_available_stream_id()
    c.send_priority_update(sid + 2, 6, false)        # before the stream exists
    c.send_headers(sid, REQ + [("priority", "u=2, i")], end_stream=true)
    c.send_headers(sid + 2, REQ + [("priority", "u=0")], end_stream=true)
    evs = pump(c, s)
    rr = [e for side, e in evs if isinstance(e, h2.events.RequestReceived)]
    check("RFC 9218: the Priority header, and a PRIORITY_UPDATE received before its stream",
          [names(evs)[0], [r.priority for r in rr], s.stream_priority(sid)],
          ["s:PriorityUpdateReceived", [(2, true), (6, false)], (2, true)])
    c.send_priority_update(sid, 7, true)
    evs = pump(c, s)
    check("PRIORITY_UPDATE on an open stream", [names(evs), s.stream_priority(sid)], [["s:PriorityUpdateReceived"], (7, true)])
    check("servers must not send PRIORITY_UPDATE", raises(lambda: s.send_priority_update(1)), "ProtocolError")
    check("a bare H2Connection does not announce SETTINGS_NO_RFC7540_PRIORITIES (h2.server does)", s.local_settings.no_rfc7540_priorities, 0)
    # GOAWAY: our streams above last_stream_id were not processed
    c, s = pair()
    a = c.get_next_available_stream_id()
    c.send_headers(a, REQ, end_stream=true)
    pump(c, s)
    b = c.get_next_available_stream_id()
    c.send_headers(b, REQ, end_stream=true)
    s.close_connection(0, last_stream_id=a)
    evs = pump(c, s)
    check("GOAWAY: ConnectionTerminated, and the unprocessed stream refused",
          [names(evs), evs[0][1].last_stream_id, evs[1][1].stream_id, evs[1][1].error_code],
          [["c:ConnectionTerminated", "c:StreamReset"], a, b, ErrorCodes.REFUSED_STREAM])
    check("no new streams after GOAWAY", raises(lambda: c.send_headers(c.get_next_available_stream_id(), REQ)), "ProtocolError")
    s.send_headers(a, [(":status", "200")], end_stream=true)
    evs = pump(c, s)
    check("streams below last_stream_id still finish", names(evs), ["c:ResponseReceived", "c:StreamEnded"])
    # connection errors raise from receive_data after queueing GOAWAY
    out = []
    for wire in ["000002000000000000" + "6869",             # DATA on stream 0
                 "000000010400000002",                       # HEADERS on an even stream from a client
                 "000004080000000000" + "00000000",          # a zero connection WINDOW_UPDATE
                 "000004080000000000" + "7fffffff",          # window over 2^31-1
                 "000005040000000000" + "0001000010",        # SETTINGS not a multiple of 6
                 "000006040000000000" + "000400000000",      # valid: INITIAL_WINDOW_SIZE 0
                 "000006040000000000" + "000580000000",      # MAX_FRAME_SIZE too large
                 "000006040000000000" + "000200000002",      # ENABLE_PUSH 2
                 "000001040100000000" + "00",                # SETTINGS ACK with a payload
                 "000000090400000001",                       # CONTINUATION without HEADERS
                 "000004030000000009" + "00000008",          # RST_STREAM on an idle stream
                 "000003000000000009" + "616263",            # DATA on an idle stream
                 "000001010400000001" + "be"]:               # HPACK: index 62 of an empty table
        c, s = pair()
        try:
            s.receive_data(bytes.fromhex(wire))
            out.append("ok")
        except h2.exceptions.ProtocolError as e:
            goaway = frames_of(s.data_to_send())[-1]
            out.append([type(e).__name__, int(e.error_code), type(goaway).__name__, goaway.error_code])
    check("connection errors and their codes", out,
          [["ProtocolError", 1, "GoAwayFrame", 1], ["ProtocolError", 1, "GoAwayFrame", 1], ["ProtocolError", 1, "GoAwayFrame", 1],
           ["FlowControlError", 3, "GoAwayFrame", 3], ["FrameDataMissingError", 6, "GoAwayFrame", 6], "ok",
           ["InvalidSettingsValueError", 1, "GoAwayFrame", 1], ["InvalidSettingsValueError", 1, "GoAwayFrame", 1],
           ["FrameDataMissingError", 6, "GoAwayFrame", 6], ["ProtocolError", 1, "GoAwayFrame", 1],
           ["ProtocolError", 1, "GoAwayFrame", 1], ["ProtocolError", 1, "GoAwayFrame", 1], ["ProtocolError", 9, "GoAwayFrame", 9]])
    c, s = pair()
    check("a frame over our SETTINGS_MAX_FRAME_SIZE", raises(lambda: s.receive_data(bytes.fromhex("004001000000000001") + b"x" * 16385)),
          "FrameTooLargeError")
    s = h2.connection.H2Connection(h2.config.H2Configuration(client_side=false))
    s.initiate_connection()
    check("a bad preface", raises(lambda: s.receive_data(b"GET / HTTP/1.1\r\n\r\n" + b"x" * 20)), "ProtocolError")
    s = h2.connection.H2Connection(h2.config.H2Configuration(client_side=false))
    s.initiate_connection()
    check("the first frame must be SETTINGS", raises(lambda: s.receive_data(h2.connection.PREAMBLE + bytes.fromhex("0000080600000000003132333435363738"))),
          "ProtocolError")
    # stream errors: zero stream WINDOW_UPDATE, window overflow, too many streams
    c, s = pair(server_settings={SettingCodes.MAX_CONCURRENT_STREAMS: 1})
    sid = c.get_next_available_stream_id()
    c.send_headers(sid, REQ)
    pump(c, s)
    evs = [("s", e) for e in s.receive_data(bytes.fromhex("000004080000000001" + "00000000"))]
    check("a zero WINDOW_UPDATE on a stream: RST_STREAM PROTOCOL_ERROR", [names(evs), evs[0][1].error_code],
          [["s:StreamReset"], ErrorCodes.PROTOCOL_ERROR])
    check("TooManyStreamsError when the peer allows one", raises(lambda: [c.send_headers(3, REQ), c.send_headers(5, REQ)]), "TooManyStreamsError")
    c2, s2 = pair(server_settings={SettingCodes.MAX_CONCURRENT_STREAMS: 1})
    c2.send_headers(1, REQ)
    c2.remote_settings._settings[SettingCodes.MAX_CONCURRENT_STREAMS] = [10]     # a client that ignores the limit
    c2.send_headers(3, REQ)
    evs = pump(c2, s2)
    check("a stream over SETTINGS_MAX_CONCURRENT_STREAMS is refused", [names(evs), evs[-1][1].error_code],
          [["s:RequestReceived", "s:StreamReset", "c:StreamReset"], ErrorCodes.REFUSED_STREAM])
    c3, s3 = pair()
    check("a lower stream id than one already used is a connection error",
          raises(lambda: s3.receive_data(bytes.fromhex("000000010500000005" + "000000010500000003"))), "StreamIDTooLowError")
    c3, s3 = pair()
    sid = c3.get_next_available_stream_id()
    c3.send_headers(sid, REQ)
    pump(c3, s3)
    s3.send_headers(sid, [(":status", "200")])
    check("a DATA frame over the peer's SETTINGS_MAX_FRAME_SIZE", raises(lambda: s3.send_data(sid, b"x" * 20000)), "FrameTooLargeError")
    # PUSH_PROMISE: the client announced ENABLE_PUSH=0
    c, s = pair()
    c.send_headers(1, REQ, end_stream=true)
    pump(c, s)
    check("push_stream: the client disabled push", raises(lambda: s.push_stream(1, 2, REQ)), "ProtocolError")
    s.remote_settings._settings[SettingCodes.ENABLE_PUSH] = [1]                 # a server that pushes anyway
    s.push_stream(1, 2, [(":method", "GET"), (":scheme", "https"), (":authority", "example.org"), (":path", "/style.css")])
    try:
        pump(c, s)
        out = "accepted"
    except h2.exceptions.ProtocolError as e:
        out = [type(e).__name__, int(e.error_code)]
    check("a PUSH_PROMISE to a client that refused push: PROTOCOL_ERROR", out, ["ProtocolError", 1])
    c, s = pair(client_settings={SettingCodes.ENABLE_PUSH: 1})
    c.send_headers(1, REQ, end_stream=true)
    pump(c, s)
    s.push_stream(1, 2, [(":method", "GET"), (":scheme", "https"), (":authority", "example.org"), (":path", "/a.js")])
    evs = pump(c, s)
    check("push enabled: the client refuses the pushed stream (CANCEL)",
          [names(evs), evs[0][1].pushed_stream_id, evs[0][1].headers[-1], evs[1][1].error_code],
          [["c:PushedStreamReceived", "s:StreamReset"], 2, (":path", "/a.js"), ErrorCodes.CANCEL])
    # h2c upgrade (the HTTP/2 half)
    c = h2.connection.H2Connection(h2.config.H2Configuration(client_side=true))
    hdr = c.initiate_upgrade_connection()
    s = h2.connection.H2Connection(h2.config.H2Configuration(client_side=false))
    s.initiate_upgrade_connection(hdr)
    check("h2c upgrade: HTTP2-Settings, stream 1 half-closed on both sides",
          [hdr[:4], c.streams[1].state.name, s.streams[1].state.name, s.remote_settings.enable_push], [b"AAEA", "HALF_CLOSED_LOCAL", "HALF_CLOSED_REMOTE", 0])
    check("the h2 package's names", [h2.__version__, ErrorCodes(0xd).name, SettingCodes.ENABLE_CONNECT_PROTOCOL.value,
                                     issubclass(h2.exceptions.StreamClosedError, h2.exceptions.NoSuchStreamError),
                                     h2.exceptions.FlowControlError.error_code, repr(h2.events.StreamEnded())],
          ["4.4.1", "HTTP_1_1_REQUIRED", 8, true, ErrorCodes.FLOW_CONTROL_ERROR, "<StreamEnded stream_id:None>"])
    st = h2.settings.Settings(client=true)
    st[SettingCodes.INITIAL_WINDOW_SIZE] = 100
    check("Settings: pending until acknowledged", [st.initial_window_size, list(st.acknowledge().values())[0].new_value, st.initial_window_size],
          [65535, 100, 100])
    check("Settings: invalid values", [raises(lambda: st.__setitem__(SettingCodes.MAX_FRAME_SIZE, 100)),
                                       raises(lambda: st.__setitem__(SettingCodes.INITIAL_WINDOW_SIZE, 2 ** 31))],
          ["InvalidSettingsValueError", "InvalidSettingsValueError"])


# ═══════════════════════════════════════════════════════════════════════════
# 4. RFC 9218 priorities
# ═══════════════════════════════════════════════════════════════════════════
def test_priority():
    P = h2.priority
    check("Priority field values", [P.parse_priority("u=5, i"), P.parse_priority("u=0"), P.parse_priority(""), P.parse_priority("i=?0, u=7"),
                                    P.parse_priority("u=9, i=3, x=1"), P.parse_priority(b"u=1;a=b, i;c"), P.parse_priority("i, u=\"5\"")],
          [(5, true), (0, false), (3, false), (7, false), (3, false), (1, true), (3, true)])
    check("an invalid Dictionary", [raises(lambda: P.parse_priority("u=")), raises(lambda: P.parse_priority("U=1")),
                                    raises(lambda: P.parse_priority("u=1,"))], ["ValueError", "ValueError", "ValueError"])
    check("serialize", [P.serialize_priority(5, true), P.serialize_priority(3, false), P.serialize_priority(0, false)], ["u=5, i", "", "u=0"])
    s = P.PriorityScheduler()
    s.add(1, 5, false)
    s.add(3, 1, false)
    s.add(5, 3, true)
    s.add(7, 3, true)
    s.add(9, 3, false)
    s.add(11, 3, false)
    order = [s.next({1, 3, 5, 7, 9, 11}) for i in range(4)]
    check("urgency first", order, [3, 3, 3, 3])
    s.remove(3)
    order = [s.next({1, 5, 7, 9, 11}) for i in range(9)]
    check("one urgency: non-incremental in id order as one round-robin member, incremental shared", order,
          [5, 7, 9, 5, 7, 9, 5, 7, 9])
    s.remove(9)
    check("then the next non-incremental", [s.next({1, 5, 7, 11}) for i in range(3)], [5, 7, 11])
    check("a stream not ready is skipped", [s.next({1, 7}), s.next({1}), s.next(set()), s.next({42})], [7, 1, None, 42])


# ═══════════════════════════════════════════════════════════════════════════
# 5. asyncio client and server over localhost
# ═══════════════════════════════════════════════════════════════════════════
TLS = none


def make_certs():
    if shutil.which("openssl") is None:
        return none
    d = os.path.join(TMP, "tls")
    os.makedirs(d, exist_ok=true)
    ext = os.path.join(d, "ext.cnf")
    with open(ext, "w") as f:
        f.write("subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
    steps = [["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/ca.key", "-out", d + "/ca.pem", "-days", "2", "-subj", "/CN=audit123 CA"],
             ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/server.key", "-out", d + "/server.csr", "-subj", "/CN=localhost"],
             ["openssl", "x509", "-req", "-in", d + "/server.csr", "-CA", d + "/ca.pem", "-CAkey", d + "/ca.key", "-CAcreateserial",
              "-out", d + "/server.pem", "-days", "2", "-extfile", ext]]
    for s in steps:
        try:
            r = subprocess.run(s, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            if r.returncode != 0:
                return none
        except Exception:
            return none
    return d


def server_ctx():
    import ssl
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain(TLS + "/server.pem", TLS + "/server.key")
    return c


def client_ctx():
    import ssl
    return ssl.create_default_context(cafile=TLS + "/ca.pem")


SERVER_LOG = []


async def handler(req):
    if req.path == "/echo":
        body = await req.read()
        return h2.server.Response(200, [("content-type", "text/plain"), ("x-stream", str(req.stream_id))], b"echo:" + body)
    if req.path.startswith("/size/"):
        return h2.server.Response(200, [], b"z" * int(req.path[6:]))
    if req.path == "/slow":
        await asyncio.sleep(0.3)
        return h2.server.Response(200, [], b"slow done")
    if req.path == "/forever":
        await req.send_response(200)
        try:
            while true:
                await req.write(b"y" * 1000)
                await asyncio.sleep(0.002)
        except BaseException as e:
            SERVER_LOG.append("forever ended: " + type(e).__name__)
            raise
    if req.path == "/refuse":
        req.reset(ErrorCodes.REFUSED_STREAM)
        return none
    if req.path == "/boom":
        raise ValueError("boom")
    if req.path == "/trailers":
        await req.send_response(200, [("content-type", "text/plain")])
        await req.write(b"part1-")
        await req.write(b"part2")
        req.end([("x-checksum", "c0ffee")])
        return none
    if req.path == "/prio":
        return h2.server.Response(200, [], b"p" * 40000)
    if req.path == "/info":
        return h2.server.Response(200, [], ("%s %s %s u=%d i=%d" % (req.method, req.scheme, req.authority, req.priority[0], int(req.priority[1]))).encode())
    return h2.server.Response(404, [], b"not found")


async def h2_main():
    srv = await h2.server.serve(handler, "127.0.0.1", 0)
    port = srv.port
    c = await h2.client.connect("127.0.0.1", port)
    r = await c.request("GET", "/info", priority=(1, true))
    check("asyncio: a request over h2c (prior knowledge)", [r.status, r.body, c.alpn], [200, b"GET http 127.0.0.1:%d u=1 i=1" % port, None])
    rs = await asyncio.gather(*[c.request("POST", "/echo", body=b"%d" % i * (i + 1)) for i in range(6)])
    check("asyncio: six streams multiplexed on one connection",
          [[x.status for x in rs], [x.body for x in rs][:3], sorted(set([x.stream_id for x in rs])) == [x.stream_id for x in rs],
           len(srv.connections)],
          [[200] * 6, [b"echo:0", b"echo:11", b"echo:222"], true, 1])
    r = await c.request("POST", "/echo", body=b"q" * 300000)
    check("asyncio: a 300 KB upload waits for the server's WINDOW_UPDATEs", [r.status, len(r.body), c.blocked > 0], [200, 300005, true])
    r = await c.request("GET", "/trailers")
    check("asyncio: streamed response with trailers", [r.body, r.trailers], [b"part1-part2", [("x-checksum", "c0ffee")]])
    r = await c.request("GET", "/nowhere")
    check("asyncio: 404", [r.status, r.body], [404, b"not found"])
    rtt = await c.ping()
    check("asyncio: PING round trip", rtt >= 0, true)
    await c.close()
    # flow control: a client with 4 KiB windows that reads slowly
    c = await h2.client.connect("127.0.0.1", port, settings={SettingCodes.INITIAL_WINDOW_SIZE: 4096})
    s = await c.open_stream("GET", "/size/200000", end_stream=true)
    await s.response_headers()
    got = 0
    while true:
        ch = await s.read_chunk()
        if not ch:
            break
        got += len(ch)
        await asyncio.sleep(0)
    blocked = sum([x.blocked for x in srv.connections])
    check("asyncio: the server stops at the client's 4 KiB window and resumes", [got, blocked > 10], [200000, true])
    # RST_STREAM both ways
    s = await c.open_stream("GET", "/forever", end_stream=true)
    await s.response_headers()
    await s.read_chunk()
    s.reset()
    for i in range(50):
        if SERVER_LOG:
            break
        await asyncio.sleep(0.01)
    check("asyncio: the client resets a stream: the handler is cancelled", SERVER_LOG, ["forever ended: CancelledError"])
    try:
        await c.request("GET", "/refuse")
        out = "answered"
    except h2.client.StreamResetError as e:
        out = [e.error_code, e.remote]
    check("asyncio: the server resets a stream (REFUSED_STREAM)", out, [ErrorCodes.REFUSED_STREAM, true])
    r = await c.request("GET", "/boom")
    check("asyncio: a handler that raises gets a 500", [r.status, r.body, type(srv.errors[-1]).__name__], [500, b"Internal Server Error\n", "ValueError"])
    # graceful GOAWAY: the stream in flight finishes, new ones are refused
    slow = asyncio.ensure_future(c.request("GET", "/slow"))
    await asyncio.sleep(0.1)
    closing = asyncio.ensure_future(srv.close())
    await asyncio.sleep(0.1)
    try:
        await c.request("GET", "/echo")
        out = "answered"
    except (h2.client.ConnectionClosedError, h2.client.StreamResetError) as e:
        out = type(e).__name__
    check("asyncio: no new stream after the server's GOAWAY", out, "ConnectionClosedError")
    r = await slow
    await closing
    check("asyncio: the stream in flight finished", [r.status, r.body], [200, b"slow done"])
    check("asyncio: GOAWAY NO_ERROR with the real last stream id (after the 2^31-1 one)",
          [c.terminated.error_code, c.terminated.last_stream_id], [ErrorCodes.NO_ERROR, r.stream_id])
    await c.close()


async def h2_scheduler_main():
    # every response waits on the client's windows (INITIAL_WINDOW_SIZE 0);
    # opened all at once, the server's scheduler decides the order on the wire
    srv = await h2.server.serve(handler, "127.0.0.1", 0)
    c = await h2.client.connect("127.0.0.1", srv.port, settings={SettingCodes.INITIAL_WINDOW_SIZE: 0})
    c.frame_log = []
    prios = [(5, false), (1, false), (3, true), (3, true), (3, false), (3, false)]
    streams = []
    for p in prios:
        streams.append(await c.open_stream("GET", "/prio", end_stream=true, priority=p))
    for s in streams:
        await s.response_headers()
    await asyncio.sleep(0.1)
    for s in streams:
        c.conn.increment_flow_control_window(1000000, s.stream_id)
    c.conn.increment_flow_control_window(1000000)
    c._flush()
    bodies = await asyncio.gather(*[s.read() for s in streams])
    ids = [s.stream_id for s in streams]
    order = []
    for sid, n in c.frame_log:
        order.append("ABCDEF"[ids.index(sid)])
    runs = []
    for x in order:
        if not runs or runs[-1] != x:
            runs.append(x)
    check("scheduler: every body whole", [len(b) for b in bodies], [40000] * 6)
    check("scheduler: RFC 9218 order on the wire (B u=1; then u=3 - E,F one at a time, C,D shared; then A u=5)",
          "".join(runs), "BCDECDECDEFA")
    await c.close()
    await srv.close()


async def h2_tls_main():
    srv = await h2.server.serve(handler, "127.0.0.1", 0, ssl=server_ctx())
    c = await h2.client.connect("localhost", srv.port, ssl=client_ctx())
    r = await c.request("POST", "/echo", body=b"over TLS")
    check("TLS: ALPN selected h2", [c.alpn, r.status, r.body, srv.connections[0].alpn], ["h2", 200, b"echo:over TLS", "h2"])
    rs = await asyncio.gather(*[c.request("GET", "/size/%d" % (i * 50000)) for i in range(1, 4)])
    check("TLS: multiplexed bodies", [len(x.body) for x in rs], [50000, 100000, 150000])
    await c.close()
    r = await h2.client.request("GET", "https://localhost:%d/info" % srv.port, ssl=client_ctx())
    check("TLS: h2.client.request(url)", [r.status, r.body], [200, b"GET https localhost:%d u=3 i=0" % srv.port])
    # a client that does not offer h2: the server will not speak HTTP/2 to it
    import ssl
    cc = client_ctx()
    cc.set_alpn_protocols(["http/1.1"])
    try:
        reader, writer = await asyncio.open_connection("localhost", srv.port, ssl=cc)
        data = await asyncio.wait_for(reader.read(100), 5)
        writer.close()
    except (ssl.SSLError, ConnectionError, OSError):
        data = b""             # (a TLS stack may refuse the handshake instead)
    check("TLS: no h2 in ALPN, no HTTP/2", data, b"")
    await srv.close()

    # a TLS server without ALPN: the client will not speak HTTP/2 to it
    async def noop(reader, writer):
        await asyncio.sleep(0.5)
        writer.close()
    plain = await asyncio.start_server(noop, "127.0.0.1", 0, ssl=server_ctx())
    try:
        await h2.client.connect("localhost", plain.sockets[0].getsockname()[1], ssl=client_ctx())
        out = "connected"
    except h2.client.NegotiationError:
        out = "NegotiationError"
    check("TLS: a server that does not select h2 is refused by the client", out, "NegotiationError")
    plain.close()


async def h2_goaway_error_main():
    srv = await h2.server.serve(handler, "127.0.0.1", 0)
    reader, writer = await asyncio.open_connection("127.0.0.1", srv.port)
    writer.write(h2.connection.PREAMBLE + h2.frame.SettingsFrame(0).serialize() + bytes.fromhex("000002000000000000" + "6869"))
    await writer.drain()
    data = b""
    while true:
        chunk = await asyncio.wait_for(reader.read(65536), 5)
        if not chunk:
            break
        data += chunk
    writer.close()
    fs = frames_of(data)
    ga = [f for f in fs if isinstance(f, h2.frame.GoAwayFrame)]
    check("asyncio: a protocol error gets GOAWAY PROTOCOL_ERROR, then the connection closes",
          [type(fs[0]).__name__, len(ga), ga[0].error_code if ga else none], ["SettingsFrame", 1, 1])
    await srv.close()


def test_asyncio():
    asyncio.run(h2_main())
    asyncio.run(h2_scheduler_main())
    asyncio.run(h2_goaway_error_main())
    if TLS is not none:
        asyncio.run(h2_tls_main())
    else:
        skipped.append("TLS (no openssl)")


# ═══════════════════════════════════════════════════════════════════════════
# 6. http.client and urllib over HTTP/2 (Nython-only)
# ═══════════════════════════════════════════════════════════════════════════
def test_http_client():
    import http.client
    import urllib.request
    state = {}
    ready = threading.Event()

    def run():
        async def main():
            srv = none
            if TLS is not none:
                srv = await h2.server.serve(handler, "127.0.0.1", 0, ssl=server_ctx())
                state["tls"] = srv.port
            plain = await h2.server.serve(handler, "127.0.0.1", 0)
            state["plain"] = plain.port
            state["stop"] = asyncio.Event()
            state["loop"] = asyncio.get_running_loop()
            ready.set()
            await state["stop"].wait()
            if srv is not none:
                await srv.close()
            await plain.close()
        asyncio.run(main())
    t = threading.Thread(target=run, daemon=true)
    t.start()
    ready.wait(10)
    c = http.client.HTTPConnection("127.0.0.1", state["plain"], http2="prior_knowledge")
    c.request("POST", "/echo", body=b"via http.client")
    r = c.getresponse()
    check("http.client: h2c prior knowledge", [c.http_version, r.version, r.status, r.reason, r.getheader("content-type"), r.read()],
          ["HTTP/2", 20, 200, "OK", "text/plain", b"echo:via http.client"])
    c.request("GET", "/trailers")
    r = c.getresponse()
    check("http.client: the connection is reused; trailers", [r.read(), r.trailers.get("x-checksum"), r.stream_id], [b"part1-part2", "c0ffee", 3])
    c.request("GET", "/size/70000")
    r = c.getresponse()
    parts = [r.read(1000), r.read1(), r.read()]
    check("http.client: read(amt), read1, read", [len(parts[0]), len(parts[0]) + len(parts[1]) + len(parts[2]), r.isclosed()], [1000, 70000, true])
    c.close()
    r = urllib.request.urlopen("http://127.0.0.1:%d/info" % state["plain"], http2="prior_knowledge")
    check("urllib: h2c", [r.version, r.status, r.read()], [20, 200, b"GET http 127.0.0.1:%d u=3 i=0" % state["plain"]])
    if TLS is not none:
        c = http.client.HTTPSConnection("localhost", state["tls"], context=client_ctx(), http2=true)
        c.request("PUT", "/echo", body="text body", headers={"X-Test": "1"})
        r = c.getresponse()
        check("http.client: https with ALPN h2", [c.http_version, r.status, r.read()], ["HTTP/2", 200, b"echo:text body"])
        c.close()
        r = urllib.request.urlopen("https://localhost:%d/echo" % state["tls"], data=b"posted", context=client_ctx(), http2=true)
        check("urllib: https over HTTP/2", [r.version, r.status, r.read(), r.geturl()],
              [20, 200, b"echo:posted", "https://localhost:%d/echo" % state["tls"]])
    state["loop"].call_soon_threadsafe(state["stop"].set)
    t.join(10)


# ═══════════════════════════════════════════════════════════════════════════
# 7. permessage-deflate (RFC 7692)
# ═══════════════════════════════════════════════════════════════════════════
def test_deflate():
    ext = pmd.PerMessageDeflate(false, false, 15, 15)
    rsv1, payload = ext.encode_frame(1, true, b"Hello")
    check("RFC 7692 7.2.3.1: Hello in one compressed block", [rsv1, payload.hex()], [true, "f248cdc9c90700"])
    rsv1, payload2 = ext.encode_frame(1, true, b"Hello")
    d = pmd.PerMessageDeflate(false, false, 15, 15)
    back = [d.decode_frame(1, true, true, payload), d.decode_frame(1, true, true, payload2)]
    check("RFC 7692 7.2.3.2: the second Hello uses the window (zlib: f200110000)",
          [back, len(payload2) <= 5, payload2.hex() == "f200110000" or not nython], [[b"Hello", b"Hello"], true, true])
    nct = pmd.PerMessageDeflate(false, true, 15, 15)
    check("no context takeover: the same bytes again", [nct.encode_frame(1, true, b"Hello")[1].hex(), nct.encode_frame(1, true, b"Hello")[1].hex()],
          ["f248cdc9c90700", "f248cdc9c90700"])
    d = pmd.PerMessageDeflate(false, false, 15, 15)
    check("RFC 7692 7.2.3.1: the fragmented form", [d.decode_frame(1, false, true, bytes.fromhex("f248cd")), d.decode_frame(0, true, false, bytes.fromhex("c9c90700"))],
          [b"He", b"llo"])
    vectors = [("7.2.3.3 a stored block", "000500faff48656c6c6f00"), ("7.2.3.4 BFINAL set", "f348cdc9c9070000"),
               ("7.2.3.5 two blocks", "f248050000" + "00ffffcac9c90700"), ("7.2.3.6 an empty fragment", "00")]
    out = []
    for name, hx in vectors:
        d = pmd.PerMessageDeflate(false, false, 15, 15)
        out.append(d.decode_frame(1, true, true, bytes.fromhex(hx)))
    check("RFC 7692 7.2.3.3-6 decoded", out, [b"Hello", b"Hello", b"Hello", b""])
    d = pmd.PerMessageDeflate(false, false, 15, 15)
    check("after a BFINAL block a fresh window", [d.decode_frame(1, true, true, bytes.fromhex("f348cdc9c9070000")),
                                                  d.decode_frame(1, true, true, bytes.fromhex("f248cdc9c90700"))], [b"Hello", b"Hello"])
    # round trips with every parameter
    msgs = [b"Hello", b"", "été " .encode() * 500, bytes(range(256)) * 40, b"abc" * 20000]
    ok = []
    for sn, cn, sb, cb in ((false, false, 15, 15), (true, true, 9, 9), (false, true, 8, 12), (true, false, 15, 8)):
        enc = pmd.PerMessageDeflate(sn, cn, sb, cb)
        dec = pmd.PerMessageDeflate(cn, sn, cb, sb)
        good = true
        for m in msgs * 2:
            r1, p = enc.encode_frame(2, true, m)
            good = good and dec.decode_frame(2, true, r1, p) == m
        # fragmented
        r1, p1 = enc.encode_frame(2, false, msgs[3][:5000], len(msgs[3]))
        r2, p2 = enc.encode_frame(0, true, msgs[3][5000:])
        good = good and r1 and not r2 and dec.decode_frame(2, false, r1, p1) + dec.decode_frame(0, true, r2, p2) == msgs[3]
        ok.append(good)
    check("round trips: takeover on/off, window bits 8-15, fragments", ok, [true, true, true, true])
    big = pmd.PerMessageDeflate(false, false, 15, 15)
    comp = big.encode_frame(2, true, b"\x00" * 1000000)[1]
    d = pmd.PerMessageDeflate(false, false, 15, 15)
    check("a decompression bomb stops at max_size", [len(comp) < 2000, raises(lambda: d.decode_frame(2, true, true, comp, 100000))],
          [true, "PayloadTooBig"])
    d = pmd.PerMessageDeflate(false, false, 15, 15)
    check("RSV1 rules", [raises(lambda: d.decode_frame(0, true, true, b"x")), raises(lambda: d.decode_frame(9, true, true, b"")),
                         d.decode_frame(1, true, false, b"plain"), raises(lambda: d.decode_frame(1, true, true, b"\xff\xff"))],
          ["ProtocolError", "ProtocolError", b"plain", "ProtocolError"])
    small = pmd.PerMessageDeflate(false, false, 15, 15, min_size=32)
    check("min_size: short messages go uncompressed", [small.encode_frame(1, true, b"hi"), small.encode_frame(1, true, b"x" * 64)[0]],
          [(false, b"hi"), true])
    # negotiation (RFC 7692 5, 7.1)
    check("parse Sec-WebSocket-Extensions", pmd.parse_extensions('permessage-deflate; client_max_window_bits; server_max_window_bits="10", foo, permessage-deflate'),
          [("permessage-deflate", [("client_max_window_bits", None), ("server_max_window_bits", "10")]), ("foo", []), ("permessage-deflate", [])])
    cf = pmd.ClientPerMessageDeflateFactory()
    check("the default offer", cf.offer(), "permessage-deflate; client_max_window_bits")
    sf = pmd.ServerPerMessageDeflateFactory()
    check("a server answers the default offer", sf.negotiate("permessage-deflate; client_max_window_bits")[0], "permessage-deflate")
    sf = pmd.ServerPerMessageDeflateFactory(server_no_context_takeover=true, client_max_window_bits=10)
    ans, e = sf.negotiate("permessage-deflate; server_max_window_bits=12; client_max_window_bits=12, permessage-deflate")
    check("a server with its own limits", [ans, e.remote_max_window_bits, e.local_max_window_bits, e.local_no_context_takeover],
          ["permessage-deflate; server_no_context_takeover; server_max_window_bits=12; client_max_window_bits=10", 10, 12, true])
    check("a bad first offer, an acceptable second", pmd.ServerPerMessageDeflateFactory().negotiate("permessage-deflate; bogus, permessage-deflate; client_no_context_takeover")[0],
          "permessage-deflate; client_no_context_takeover")
    check("nothing acceptable", pmd.ServerPerMessageDeflateFactory().negotiate("x-webkit-deflate-frame"), (None, None))
    cf = pmd.ClientPerMessageDeflateFactory(server_no_context_takeover=true, server_max_window_bits=10, client_max_window_bits=None)
    out = []
    for answer in ([("server_no_context_takeover", None), ("server_max_window_bits", "10")], [("server_max_window_bits", "10")],
                   [("server_no_context_takeover", None), ("server_max_window_bits", "12")],
                   [("server_no_context_takeover", None), ("server_max_window_bits", "9"), ("client_max_window_bits", "9")],
                   [("server_no_context_takeover", None), ("server_no_context_takeover", None), ("server_max_window_bits", "9")],
                   [("server_no_context_takeover", None), ("server_max_window_bits", "09")]):
        try:
            e = cf.process_response_params(answer, [])
            out.append([e.remote_no_context_takeover, e.remote_max_window_bits])
        except pmd.NegotiationError:
            out.append("NegotiationError")
    check("the client checks the answer", out, [[true, 10], "NegotiationError", "NegotiationError", "NegotiationError", "NegotiationError", "NegotiationError"])


async def wsa_main():
    async def echo(conn):
        async for m in conn:
            await conn.send(m)
    async with wsa.serve(echo, "127.0.0.1", 0) as server:
        url = "ws://127.0.0.1:%d/" % server.port
        async with wsa.connect(url) as c:
            got = []
            for m in ["Hello", "Hello", "x" * 50000, b"\x00\x01" * 3000]:
                await c.send(m)
                got.append(await c.recv() == m)
            await c.send(["frag-", "ment", "ed"])
            got.append(await c.recv())
            rtt = await (await c.ping())
            check("websocket_asyncio: permessage-deflate negotiated, messages round trip",
                  [c.response.headers.get("Sec-WebSocket-Extensions"), got, rtt >= 0, c.extension.bytes_out < c.extension.bytes_in / 10],
                  ["permessage-deflate", [true, true, true, true, "frag-mented"], true, true])
        check("websocket_asyncio: the closing handshake", [c.state, c.close_code], [wsa.CLOSED, 1000])
        c = await wsa.connect(url, compression=none)
        await c.send("plain")
        check("websocket_asyncio: compression=None", [c.extension, await c.recv()], [None, "plain"])
        await c.close()
        f = pmd.ClientPerMessageDeflateFactory(client_no_context_takeover=true, server_max_window_bits=9)
        c = await wsa.connect(url, extensions=[f])
        await c.send("abc" * 1000)
        check("websocket_asyncio: parameters agreed", [c.response.headers.get("Sec-WebSocket-Extensions"), len(await c.recv())],
              ["permessage-deflate; client_no_context_takeover; server_max_window_bits=9", 3000])
        await c.close()
        try:
            await c.recv()
            out = "message"
        except wsa.ConnectionClosedOK as e:
            out = e.code
        check("websocket_asyncio: recv after close", out, 1000)


def test_websocket():
    asyncio.run(wsa_main())
    if not nython:
        return
    import websocket
    import socket

    def echo(ws):
        for m in ws:
            ws.send(m)
    srv = websocket.serve(echo, "127.0.0.1", 0)
    th = threading.Thread(target=srv.serve_forever, daemon=true)
    th.start()
    url = "ws://127.0.0.1:%d/" % srv.port
    ws = websocket.connect(url)
    got = []
    for m in ["Hello", "x" * 70000, b"\x01" * 500]:
        ws.send(m)
        got.append(ws.recv() == m)
    check("websocket: permessage-deflate by default", [ws.response.headers.get("Sec-WebSocket-Extensions"), got, ws.extension.messages_compressed],
          ["permessage-deflate", [true, true, true], 3])
    ws.close()
    ws = websocket.connect(url, compression=none)
    ws.send("plain")
    check("websocket: compression=None", [ws.extension, ws.recv()], [None, "plain"])
    ws.close()
    # a raw client: RFC 7692's frames on the wire
    s = socket.create_connection(("127.0.0.1", srv.port))
    s.sendall(("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + websocket.generate_key() +
               "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover; server_no_context_takeover\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(1)
    key = b"\x37\xfa\x21\x3d"
    payload = bytes.fromhex("f248cdc9c90700")
    s.sendall(bytes([0xC1, 0x80 | len(payload)]) + key + bytes([payload[i] ^ key[i % 4] for i in range(len(payload))]))
    reply = b""
    while len(reply) < 9:
        reply += s.recv(64)
    check("websocket: the server echoes RFC 7692's frame byte for byte (no context takeover)",
          [b"server_no_context_takeover" in head, reply[:9].hex()], [true, "c107f248cdc9c90700"])
    s.close()
    srv.shutdown()


# ═══════════════════════════════════════════════════════════════════════════
t0 = time.time()
TLS = make_certs()
test_hpack()
test_policies()
test_frames()
test_connection()
test_priority()
test_asyncio()
if nython:
    test_http_client()
test_deflate()
test_websocket()
shutil.rmtree(TMP, ignore_errors=true)

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("HPACK indexing policies on the corpus (octets; ratio = HTTP/1.1 size / encoded):")
for line in REPORT:
    print(line)
if skipped:
    print("skipped: " + ", ".join(skipped))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT123 PASSED ===")
