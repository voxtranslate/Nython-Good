#!/usr/bin/env python3
"""Compares Nython's CJK codecs (src/builtins/nycjk.cpp) with python3's over
every input that can tell them apart (round 84):

  decode  every byte after every lead byte (two-byte codecs: L t for all L,
          t; the 0x8E/0x8F three-byte sets of the EUC codecs; gb18030's
          1.6 million four-byte sequences; each ISO-2022 designation's 94x94
          set), with errors="backslashreplace" so that every error's extent
          shows, then strict, replace and ignore over the same bytes
  encode  every code point (U+0000..U+10FFFF but the surrogates), with
          "backslashreplace", "xmlcharrefreplace" and "replace", and the
          combining pairs of JIS X 0213 and HKSCS
  incremental  the same text fed one character / one byte at a time

Run under python3 it prints the reference digests; under Nython (the same
script) its own; with no argument it runs both and reports the codecs
that differ:

    python3 tools/check_cjk_codecs.py                 # ./build/nython-cli, both engines
    python3 tools/check_cjk_codecs.py --bin build/nython-cli --codec gbk
"""
import hashlib
import os
import subprocess
import sys

CODECS = ["gb2312", "gbk", "gb18030", "hz", "euc_kr", "cp949", "johab", "big5", "cp950", "big5hkscs",
          "shift_jis", "cp932", "euc_jp", "shift_jis_2004", "euc_jis_2004", "euc_jisx0213", "shift_jisx0213",
          "iso2022_kr", "iso2022_jp", "iso2022_jp_1", "iso2022_jp_2", "iso2022_jp_2004", "iso2022_jp_3",
          "iso2022_jp_ext"]


def md5(x):
    if isinstance(x, str):
        x = x.encode("utf-8", "surrogatepass")
    return hashlib.md5(x).hexdigest()


def dec(b, codec, errors):
    try:
        return b.decode(codec, errors)
    except UnicodeDecodeError as e:
        return "<%s %d %d %s>" % (type(e).__name__, e.start, e.end, e.reason)


def enc(s, codec, errors):
    try:
        return s.encode(codec, errors)
    except UnicodeEncodeError as e:
        return ("<%s %d %d %s>" % (type(e).__name__, e.start, e.end, e.reason)).encode("ascii")


def inputs(codec):
    # byte strings that exercise the decoder
    out = []
    if codec.startswith("iso2022"):
        escs = [b"\x1b$B", b"\x1b$@", b"\x1b(J", b"\x1b(I", b"\x1b$(D", b"\x1b$A", b"\x1b$(C", b"\x1b$(O",
                b"\x1b$(Q", b"\x1b$(P", b"\x1b&@\x1b$B", b"\x1b.A\x1bN", b"\x1b.F\x1bN"]
        if codec == "iso2022_kr":
            escs = [b"\x1b$)C\x0e"]
        for e in escs:
            body = bytearray()
            for c1 in range(0x21, 0x7F):
                for c2 in range(0x21, 0x7F):
                    body += bytes([c1, c2])
                body += b"\n"
            out.append(e + bytes(body))
        for e in escs:
            out.append(e + bytes(range(0x20, 0x80)) + bytes(range(0x80, 0x100)))
        out.append(b"\x1b(B\x1b$\x1b(\x1b$(Z\x1b\x1b[0m\x0e\x0f\x1bN\x1b$")
        return out
    if codec == "hz":
        body = bytearray(b"~{")
        for c1 in range(0x21, 0x7F):
            for c2 in range(0x21, 0x80):
                body += bytes([c1, c2])
        body += b"~}~~~\n~x~{~}a\x80~"
        return [bytes(body), bytes(range(256))]
    for lead in range(0x80, 0x100):
        b = bytearray()
        for t in range(256):
            b += bytes([lead, t, 0x41])
        out.append(bytes(b))
    if codec in ("euc_jp", "euc_jis_2004", "euc_jisx0213"):
        for c2 in range(0xA1, 0xFF):
            b = bytearray()
            for t in range(256):
                b += bytes([0x8F, c2, t, 0x41])
            out.append(bytes(b))
    if codec == "euc_kr":
        b = bytearray()
        for c in range(0xA1, 0xFF):
            for d in (0xBF, 0xC5, 0xD3, 0xA1):
                b += bytes([0xA4, 0xD4, 0xA4, c, 0xA4, d, 0xA4, 0xD4])
        out.append(bytes(b))
    if codec == "gb18030":
        b = bytearray()
        for c1 in range(0x81, 0xFF):
            for c2 in range(0x30, 0x3A):
                for c3 in range(0x81, 0xFF):
                    for c4 in range(0x30, 0x3A):
                        b += bytes([c1, c2, c3, c4])
        out.append(bytes(b))
        out.append(b"\x81\x30\x81\x2f\x80\x30\xff\x30\x81\x30")
    out.append(bytes(range(256)))
    return out


def text():
    cps = [c for c in range(0x110000) if not 0xD800 <= c < 0xE000]
    return "".join(map(chr, cps))


PAIRS = "Ê̄Ê̌ê̄ê̌Êêxæ̀ɔ̀ɔ́" \
        "ʌ̀ə̀ɚ̀˩˥˥˩か゚カ゚ㇷ゚" \
        "æかセ゚ツ゚ト゚˩"


def digests(codec, full):
    lines = []
    for i, b in enumerate(inputs(codec)):
        for e in ("backslashreplace", "strict", "replace", "ignore"):
            lines.append("%s decode %d %s %s" % (codec, i, e, md5(dec(b, codec, e))))
    if full:
        t = text()
        for e in ("backslashreplace", "xmlcharrefreplace", "replace"):
            lines.append("%s encode %s %s" % (codec, e, md5(enc(t, codec, e))))
    sample = "aé日本語한국어中文繁體あアｱ¥‾—―·・＼～~\\" + PAIRS
    lines.append("%s encode-sample %s" % (codec, md5(enc(sample, codec, "backslashreplace"))))
    lines.append("%s encode-strict %s" % (codec, md5(enc(sample, codec, "strict"))))
    import codecs as C
    ie = C.getincrementalencoder(codec)("backslashreplace")
    parts = [ie.encode(ch) for ch in sample] + [ie.encode("", True)]
    lines.append("%s incremental-encode %s" % (codec, md5(b"".join(parts))))
    whole = enc(sample, codec, "backslashreplace")
    idd = C.getincrementaldecoder(codec)("backslashreplace")
    got = "".join(idd.decode(whole[k:k + 1]) for k in range(len(whole))) + idd.decode(b"", True)
    lines.append("%s incremental-decode %s" % (codec, md5(got)))
    return lines


def main():
    args = sys.argv[1:]
    if "--child" in args:
        full = "--quick" not in args
        names = [a for a in args if a in CODECS] or CODECS
        for c in names:
            for line in digests(c, full):
                print(line)
            sys.stdout.flush()
        return
    binary = "build/nython-cli"
    if "--bin" in args:
        binary = args[args.index("--bin") + 1]
    names = [args[args.index("--codec") + 1]] if "--codec" in args else CODECS
    extra = ["--quick"] if "--quick" in args else []
    me = os.path.abspath(__file__)
    want = subprocess.run([sys.executable, me, "--child"] + extra + names, capture_output=True, text=True).stdout.splitlines()
    bad = 0
    for eng in ([], ["--vm"]):
        got = subprocess.run([binary] + eng + [me, "--child"] + extra + names, capture_output=True, text=True)
        g = got.stdout.splitlines()
        diff = [w for w, x in zip(want, g) if w != x]
        if len(g) != len(want):
            diff.append("(%d lines, python3 %d)\n%s" % (len(g), len(want), got.stderr[-2000:]))
        print("%s: %d checks, %d differ" % ("vm" if eng else "interpreter", len(want), len(diff)))
        for d in diff[:20]:
            print("   ", d)
        bad += len(diff)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
