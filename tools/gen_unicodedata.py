#!/usr/bin/env python3
"""Generates the Unicode character database of both engines (round 84) from
the running Python's own - CPython 3.11, Unicode 14.0.0 - so that
unicodedata, the str methods, int()/float(), the lexer's identifiers and re
agree with CPython code point for code point:

  include/NyUniDataTables.hpp   the tables (src/NyUniData.cpp includes it)
  include/NyUniDataShape.hpp    their shape: the trie shifts and element types
                                (include/NyUniData.hpp's inline lookups)

What is stored, per code point, is what CPython's two records hold
(Modules/unicodedata.c's _PyUnicode_DatabaseRecord, Objects/unicodectype.c's
_PyUnicode_TypeRecord), read back from Python rather than from the UCD
files: the category, bidirectional class, combining class, east asian width,
mirrored flag and the normalization quick-check bits (UAX #15, derived from
normalize()); the str predicates' flags (isalpha, isdecimal, isdigit,
isnumeric, islower, isupper, Lt, isspace, the line breaks splitlines()
splits at, isprintable, XID_Start/XID_Continue from isidentifier(), Cased,
Case_Ignorable - the latter derived from the final-sigma rule of
str.lower()); the full case mappings of lower/upper/title/casefold (with
SpecialCasing's multi-character ones in an extended array, as CPython);
decimal/digit values; numeric values (exact doubles); the decompositions;
the canonical composition pairs (from normalize("NFC")); the Unicode 3.2.0
delta CPython keeps for IDNA (unicodedata.ucd_3_2_0); the name aliases and
named sequences (tools/unicode/NameAliases-14.0.0.txt and
NamedSequences-14.0.0.txt, each one checked against unicodedata.lookup).

Layout (innovation over CPython's makeunicodedata.py): ONE index for both
records - a three-level trie (index1[cp >> (L+M)] -> a block of index2 ->
a block of the record numbers) over a table of merged (database, type)
records - where CPython has two two-level indexes (splitbins), one per
record table. `--stats` prints both sizes for the same data.

    python3 tools/gen_unicodedata.py            # writes the two headers
    python3 tools/gen_unicodedata.py --stats    # sizes, ours vs CPython's layout
"""
import os
import sys
import unicodedata as U

MAX = 0x110000
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

CATEGORY_NAMES = ["Cn", "Lu", "Ll", "Lt", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Zs", "Zl", "Zp", "Cc", "Cf",
                  "Cs", "Co", "Cn", "Lm", "Lo", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So"]
BIDI_NAMES = ["", "L", "LRE", "LRO", "R", "AL", "RLE", "RLO", "PDF", "EN", "ES", "ET", "AN", "CS", "NSM", "BN",
              "B", "S", "WS", "ON", "LRI", "RLI", "FSI", "PDI"]
EAW_NAMES = ["F", "H", "W", "Na", "A", "N"]

ALPHA, DECIMAL, DIGIT, LOWER, LINEBREAK, SPACE, TITLE, UPPER = 1, 2, 4, 8, 16, 32, 64, 128
XID_START, XID_CONTINUE, PRINTABLE, NUMERIC = 256, 512, 1024, 2048
CASE_IGNORABLE, CASED, EXTENDED_CASE = 4096, 8192, 16384

SBASE, SCOUNT = 0xAC00, 11172


def log(*a):
    print(*a, file=sys.stderr)


# ── reading the database back from Python ───────────────────────────────────
def derive():
    db = [None] * MAX          # (category, combining, bidi, mirrored, eaw, quick check)
    ty = [None] * MAX          # (upper, lower, title, decimal, digit, flags)
    decomp = [""] * MAX
    numeric = {}
    extended = []
    ext_cache = {}

    def ext(seq):
        # the index of seq in the extended case array (shared when repeated)
        key = tuple(seq)
        i = ext_cache.get(key)
        if i is None:
            i = len(extended)
            ext_cache[key] = i
            extended.extend(seq)
        return i

    # canonical composition pairs: (first, second) -> composite
    comp = {}
    for cp in range(MAX):
        d = U.decomposition(chr(cp))
        decomp[cp] = d
        if d and not d.startswith("<"):
            parts = [int(x, 16) for x in d.split()]
            if len(parts) == 2 and U.combining(chr(parts[0])) == 0:
                if U.normalize("NFC", chr(parts[0]) + chr(parts[1])) == chr(cp):
                    comp[(parts[0], parts[1])] = cp
    comp_last = set(b for a, b in comp)

    for cp in range(MAX):
        c = chr(cp)
        cat = U.category(c)
        assigned = cat != "Cn"
        qc = 0
        if assigned:
            nfd, nfkd = U.normalize("NFD", c), U.normalize("NFKD", c)
            nfc, nfkc = U.normalize("NFC", c), U.normalize("NFKC", c)
            maybe = cp in comp_last or 0x1161 <= cp <= 0x1175 or 0x11A8 <= cp <= 0x11C2
            if nfd != c:
                qc |= 2 << 0
            if nfkd != c:
                qc |= 2 << 2
            if nfc != c:
                qc |= 2 << 4
            elif maybe:
                qc |= 1 << 4
            if nfkc != c:
                qc |= 2 << 6
            elif maybe:
                qc |= 1 << 6
        db[cp] = (CATEGORY_NAMES.index(cat), U.combining(c), BIDI_NAMES.index(U.bidirectional(c)),
                  U.mirrored(c), EAW_NAMES.index(U.east_asian_width(c)), qc)

        flags = 0
        if c.isalpha():
            flags |= ALPHA
        if c.isdecimal():
            flags |= DECIMAL
        if c.isdigit():
            flags |= DIGIT
        if c.isnumeric():
            flags |= NUMERIC
        if c.islower():
            flags |= LOWER
        if c.isupper():
            flags |= UPPER
        if cat == "Lt":
            flags |= TITLE
        if c.isspace():
            flags |= SPACE
        if len(("a" + c + "b").splitlines()) == 2:
            flags |= LINEBREAK
        if c.isprintable():
            flags |= PRINTABLE
        if c != "_" and c.isidentifier():
            flags |= XID_START
        if ("a" + c).isidentifier():
            flags |= XID_CONTINUE
        cased = c.islower() or c.isupper() or cat == "Lt"
        if cased:
            flags |= CASED
        # Case_Ignorable, from str.lower()'s final-sigma rule: a capital sigma
        # after "A" + c is final when c is case-ignorable or cased; after c
        # alone when c is cased and not case-ignorable
        after_a = ("A" + c + "Σ").lower()[-1] == "ς"
        alone = (c + "Σ").lower()[-1] == "ς"
        ignorable = (not alone) if cased else after_a
        if ignorable:
            flags |= CASE_IGNORABLE

        lo, up, ti, fo = c.lower(), c.upper(), c.title(), c.casefold()
        if len(lo) == 1 and len(up) == 1 and len(ti) == 1 and fo == lo:
            upper, lower, title = ord(up) - cp, ord(lo) - cp, ord(ti) - cp
        else:
            flags |= EXTENDED_CASE
            lower = ext(list(map(ord, lo)) + (list(map(ord, fo)) if fo != lo else []))
            assert lower < 0x10000 and len(lo) < 8 and len(fo) < 8
            lower |= len(lo) << 24
            if fo != lo:
                lower |= len(fo) << 20
            upper = ext(list(map(ord, up))) | (len(up) << 24)
            title = upper if ti == up else ext(list(map(ord, ti))) | (len(ti) << 24)
        decimal = U.decimal(c, 0) if flags & DECIMAL else 0
        digit = U.digit(c, 0) if flags & DIGIT else 0
        if flags & NUMERIC:
            numeric[cp] = U.numeric(c)
        assert (flags & DECIMAL) == (DECIMAL if U.decimal(c, None) is not None else 0)
        assert (flags & DIGIT) == (DIGIT if U.digit(c, None) is not None else 0)
        assert (flags & NUMERIC) == (NUMERIC if U.numeric(c, None) is not None else 0)
        ty[cp] = (upper, lower, title, decimal, digit, flags)
    return db, ty, decomp, numeric, extended, comp


def derive_3_2_0(db):
    # CPython's change records (makeunicodedata.py's merge_old_version), read
    # back from unicodedata.ucd_3_2_0: 0xFF is "no change", category 0 is
    # "unassigned in 3.2.0"; numeric() reads the decimal change (as CPython's)
    old = U.ucd_3_2_0
    changes = [None] * MAX
    norm = []
    for cp in range(MAX):
        c = chr(cp)
        rec = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF]   # bidir, category, decimal, mirrored, east asian width
        if U.category(c) != "Cn":
            if old.category(c) == "Cn":
                rec[1] = 0
            else:
                if old.bidirectional(c) != U.bidirectional(c):
                    rec[0] = BIDI_NAMES.index(old.bidirectional(c))
                if old.category(c) != U.category(c):
                    rec[1] = CATEGORY_NAMES.index(old.category(c))
                if old.decimal(c, None) != U.decimal(c, None):
                    assert old.decimal(c, None) is not None
                    rec[2] = old.decimal(c)
                if old.mirrored(c) != U.mirrored(c):
                    rec[3] = old.mirrored(c)
                if old.east_asian_width(c) != U.east_asian_width(c):
                    rec[4] = EAW_NAMES.index(old.east_asian_width(c))
                if old.normalize("NFD", c) != U.normalize("NFD", c) and not (SBASE <= cp < SBASE + SCOUNT):
                    v = old.normalize("NFD", c)
                    assert len(v) == 1 and U.normalize("NFD", v) == v, hex(cp)
                    norm.append((cp, ord(v)))
        changes[cp] = tuple(rec)
    return changes, norm


def read_aliases():
    out = []
    with open(os.path.join(HERE, "unicode", "NameAliases-14.0.0.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            code, name, _kind = line.split(";")
            cp = int(code, 16)
            assert U.lookup(name) == chr(cp), name
            out.append((name, cp))
    return out


def read_named_sequences():
    out = []
    with open(os.path.join(HERE, "unicode", "NamedSequences-14.0.0.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            name, codes = line.split(";")
            seq = [int(x, 16) for x in codes.split()]
            assert U.lookup(name) == "".join(map(chr, seq)), name
            out.append((name, seq))
    return out


# ── tables ───────────────────────────────────────────────────────────────────
def width(data):
    m = max(data) if data else 0
    return 1 if m < 256 else 2 if m < 65536 else 4


def splitbins(t):
    # CPython's makeunicodedata.splitbins: the best two-level split of t,
    # t[i] == t2[(t1[i >> shift] << shift) + (i & mask)]
    t = tuple(t)
    best = None
    n, maxshift = len(t) - 1, 0
    while n >> 1:
        n >>= 1
        maxshift += 1
    for shift in range(maxshift + 1):
        t1, t2, cache, size = [], [], {}, 1 << shift
        for i in range(0, len(t), size):
            b = t[i:i + size]
            k = cache.get(b)
            if k is None:
                k = len(t2)
                cache[b] = k
                t2.extend(b)
            t1.append(k >> shift)
        cost = len(t1) * width(t1) + len(t2) * width(t2)
        if best is None or cost < best[0]:
            best = (cost, t1, t2, shift)
    return best


def split3(t):
    # the best three-level split: t[i] == t3[(t2[(t1[i >> (lo + mid)] << mid)
    # + ((i >> lo) & mmask)] << lo) + (i & lmask)] - blocks of t deduplicated,
    # then the block-number table split again (splitbins over it)
    t = tuple(t)
    best = None
    for lo in range(2, 10):
        size = 1 << lo
        t3, blocks, cache = [], [], {}
        for i in range(0, len(t), size):
            b = t[i:i + size]
            k = cache.get(b)
            if k is None:
                k = len(t3) >> lo
                cache[b] = k
                t3.extend(b)
            blocks.append(k)
        for mid in range(2, 9):
            msize = 1 << mid
            if len(blocks) % msize:
                continue
            t1, t2, c2 = [], [], {}
            for i in range(0, len(blocks), msize):
                b = tuple(blocks[i:i + msize])
                k = c2.get(b)
                if k is None:
                    k = len(t2) >> mid
                    c2[b] = k
                    t2.extend(b)
                t1.append(k)
            cost = len(t1) * width(t1) + len(t2) * width(t2) + len(t3) * width(t3)
            if best is None or cost < best[0]:
                best = (cost, t1, t2, t3, lo, mid)
    cost, t1, t2, t3, lo, mid = best
    for i in range(0, len(t), 997):
        assert t[i] == t3[(t2[(t1[i >> (lo + mid)] << mid) + ((i >> lo) & ((1 << mid) - 1))] << lo) + (i & ((1 << lo) - 1))]
    return best


def ctype(w):
    return {1: "uint8_t", 2: "uint16_t", 4: "uint32_t"}[w]


def emit_array(out, name, typ, data, per=20):
    out.append("const %s %s[%d] = {" % (typ, name, len(data)))
    for i in range(0, len(data), per):
        out.append("    " + ",".join(str(x) for x in data[i:i + per]) + ",")
    out.append("};")


def cstr(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def build(stats=False):
    db, ty, decomp, numeric, extended, comp = derive()
    changes, norm32 = derive_3_2_0(db)
    aliases = read_aliases()
    seqs = read_named_sequences()

    # merged records: (database record, type record) -> one number
    recs, rec_index = [], {}
    index = [0] * MAX
    for cp in range(MAX):
        key = db[cp] + ty[cp]
        k = rec_index.get(key)
        if k is None:
            k = len(recs)
            rec_index[key] = k
            recs.append(key)
        index[cp] = k

    # decompositions: CPython's decomp_data ([prefix | count << 8, codes...])
    prefixes = [""]
    ddata = [0]
    dpos = [0] * MAX
    dcache = {}
    for cp in range(MAX):
        d = decomp[cp]
        if not d:
            continue
        parts = d.split()
        prefix = parts.pop(0) if parts[0].startswith("<") else ""
        if prefix not in prefixes:
            prefixes.append(prefix)
        entry = (prefixes.index(prefix) + (len(parts) << 8),) + tuple(int(x, 16) for x in parts)
        k = dcache.get(entry)
        if k is None:
            k = len(ddata)
            dcache[entry] = k
            ddata.extend(entry)
        dpos[cp] = k

    # the 3.2.0 change records
    crecs, cidx = [(0xFF,) * 5], {(0xFF,) * 5: 0}
    cindex = [0] * MAX
    for cp in range(MAX):
        k = cidx.get(changes[cp])
        if k is None:
            k = len(crecs)
            cidx[changes[cp]] = k
            crecs.append(changes[cp])
        cindex[cp] = k

    tri = split3(index)
    dtri = split3(dpos)
    ctri = split3(cindex)

    if stats:
        # CPython's layout for the same data: two record tables, each with its
        # own two-level index, and a two-level decomposition index
        dbr, dbi, tyr, tyi = [], {}, [], {}
        dbx, tyx = [0] * MAX, [0] * MAX
        for cp in range(MAX):
            k = dbi.setdefault(db[cp], len(dbi))
            if k == len(dbr):
                dbr.append(db[cp])
            dbx[cp] = k
            k = tyi.setdefault(ty[cp], len(tyi))
            if k == len(tyr):
                tyr.append(ty[cp])
            tyx[cp] = k
        a = splitbins(dbx)[0]
        b = splitbins(tyx)[0]
        dd = splitbins(dpos)[0]
        cp_size = a + b + dd + len(dbr) * 6 + len(tyr) * 16
        our = tri[0] + dtri[0] + len(recs) * 20
        log("records: %d database + %d type (CPython), %d merged (ours)" % (len(dbr), len(tyr), len(recs)))
        log("CPython layout: database index %d + type index %d + decomposition index %d + records %d = %d bytes"
            % (a, b, dd, len(dbr) * 6 + len(tyr) * 16, cp_size))
        log("ours: merged index %d (3-level, shifts %d/%d) + decomposition index %d + records %d = %d bytes"
            % (tri[0], tri[4], tri[5], dtri[0], len(recs) * 20, our))
        log("3.2.0 delta: %d change records, index %d bytes; %d normalization changes"
            % (len(crecs), ctri[0], len(norm32)))
        log("decomposition data %d entries, extended case %d, numeric %d, composition pairs %d, aliases %d, named sequences %d"
            % (len(ddata), len(extended), len(numeric), len(comp), len(aliases), len(seqs)))

    # ── the tables header ────────────────────────────────────────────────────
    o = []
    o.append("// include/NyUniDataTables.hpp - GENERATED by tools/gen_unicodedata.py from Python %s"
             % sys.version.split()[0])
    o.append("// (Unicode %s). Do not edit by hand; included by src/NyUniData.cpp only." % U.unidata_version)
    o.append("#pragma once")
    o.append("#include <cstdint>")
    o.append('#include "NyUniDataShape.hpp"')
    o.append("namespace nyucd {")
    o.append("namespace data {")
    o.append("")
    o.append("// the merged records: category, combining, bidirectional, mirrored, east")
    o.append("// asian width, quick check | upper, lower, title (deltas, or extended")
    o.append("// case indexes), decimal, digit, flags - CPython's two records in one")
    o.append("const Rec kRecs[%d] = {" % len(recs))
    for r in recs:
        cat, ccc, bidi, mirrored, eaw, qc, upper, lower, title, decimal, digit, flags = r
        o.append("    {%d,%d,%d,%d,%d,%d,%d,%d,%d,%d}," % (cat, ccc, bidi, mirrored | (eaw << 1), qc, decimal | (digit << 4),
                                                       flags, upper, lower, title))
    o.append("};")
    t1, t2, t3 = tri[1], tri[2], tri[3]
    emit_array(o, "kIdx1", "Idx1T", t1)
    emit_array(o, "kIdx2", "Idx2T", t2)
    emit_array(o, "kIdx3", "Idx3T", t3)
    o.append("")
    emit_array(o, "kExtCase", "uint32_t", extended, 12)
    o.append("")
    o.append("// decompositions")
    o.append("const char* const kDecompPrefix[%d] = {%s};" % (len(prefixes), ", ".join(cstr(p) for p in prefixes)))
    emit_array(o, "kDecompData", "uint32_t", ddata, 12)
    emit_array(o, "kDecIdx1", ctype(width(dtri[1])), dtri[1])
    emit_array(o, "kDecIdx2", ctype(width(dtri[2])), dtri[2])
    emit_array(o, "kDecIdx3", ctype(width(dtri[3])), dtri[3])
    o.append("const int kDecLo = %d, kDecMid = %d;" % (dtri[4], dtri[5]))
    o.append("")
    o.append("// canonical composition pairs, sorted: first << 42 | second << 21 | composite")
    keys = sorted((a << 42) | (b << 21) | x for (a, b), x in comp.items())
    o.append("const uint64_t kComp[%d] = {" % len(keys))
    for i in range(0, len(keys), 6):
        o.append("    " + ",".join("0x%XULL" % k for k in keys[i:i + 6]) + ",")
    o.append("};")
    o.append("")
    o.append("// numeric values (exact doubles): the code points, sorted, and the")
    o.append("// number of each one's value")
    nums = sorted(numeric.items())
    vals = sorted(set(v for cp, v in nums))
    assert len(vals) < 256
    emit_array(o, "kNumCp", "uint32_t", [cp for cp, v in nums], 12)
    emit_array(o, "kNumIdx", "uint8_t", [vals.index(v) for cp, v in nums])
    o.append("const double kNumVal[%d] = {" % len(vals))
    for i in range(0, len(vals), 6):
        o.append("    " + ",".join(v.hex() for v in vals[i:i + 6]) + ",")
    o.append("};")
    o.append("")
    o.append("// unicodedata.ucd_3_2_0: CPython's change records (bidirectional,")
    o.append("// category, decimal, mirrored, east asian width; 0xFF no change,")
    o.append("// category 0 unassigned in 3.2.0) and its normalization changes")
    o.append("const uint8_t kOld[%d][5] = {" % len(crecs))
    for r in crecs:
        o.append("    {%d,%d,%d,%d,%d}," % r)
    o.append("};")
    emit_array(o, "kOldIdx1", ctype(width(ctri[1])), ctri[1])
    emit_array(o, "kOldIdx2", ctype(width(ctri[2])), ctri[2])
    emit_array(o, "kOldIdx3", ctype(width(ctri[3])), ctri[3])
    o.append("const int kOldLo = %d, kOldMid = %d;" % (ctri[4], ctri[5]))
    o.append("const uint32_t kOldNorm[%d][2] = {%s};" % (len(norm32), ", ".join("{0x%X,0x%X}" % p for p in norm32)))
    o.append("")
    o.append("// name aliases (NameAliases.txt) and named sequences (NamedSequences.txt)")
    o.append("struct Alias { const char* name; uint32_t cp; };")
    o.append("const Alias kAliases[%d] = {" % len(aliases))
    for n, cp in aliases:
        o.append("    {%s, 0x%X}," % (cstr(n), cp))
    o.append("};")
    o.append("struct NamedSeq { const char* name; uint32_t seq[4]; int len; };")
    o.append("const NamedSeq kNamedSeqs[%d] = {" % len(seqs))
    for n, s in seqs:
        assert len(s) <= 4
        o.append("    {%s, {%s}, %d}," % (cstr(n), ",".join("0x%X" % x for x in s), len(s)))
    o.append("};")
    o.append("")
    o.append("}  // namespace data")
    o.append("}  // namespace nyucd")

    # ── the shape header ─────────────────────────────────────────────────────
    s = []
    s.append("// include/NyUniDataShape.hpp - GENERATED by tools/gen_unicodedata.py (Unicode %s)."
             % U.unidata_version)
    s.append("// The shape of the character index (include/NyUniData.hpp's inline lookups).")
    s.append("#pragma once")
    s.append("#include <cstdint>")
    s.append("namespace nyucd {")
    s.append("// a record: category, combining class, bidirectional class, mirrored | east")
    s.append("// asian width << 1, quick check bits (NFD, NFKD, NFC, NFKC: 2 each), decimal |")
    s.append("// digit << 4, the str flags, and the upper/lower/title mappings (deltas, or")
    s.append("// CPython's extended case indexes when flags has EXTENDED_CASE)")
    s.append("struct Rec { uint8_t cat, ccc, bidi, eawm, qc, decdig; uint16_t flags; int32_t upper, lower, title; };")
    s.append("typedef %s Idx1T;" % ctype(width(t1)))
    s.append("typedef %s Idx2T;" % ctype(width(t2)))
    s.append("typedef %s Idx3T;" % ctype(width(t3)))
    s.append("const int kIdxLo = %d, kIdxMid = %d;" % (tri[4], tri[5]))
    s.append("const int kRecCount = %d;" % len(recs))
    s.append("namespace data {")
    s.append("extern const Rec kRecs[%d];" % len(recs))
    s.append("extern const Idx1T kIdx1[%d];" % len(t1))
    s.append("extern const Idx2T kIdx2[%d];" % len(t2))
    s.append("extern const Idx3T kIdx3[%d];" % len(t3))
    s.append("extern const uint32_t kExtCase[%d];" % len(extended))
    s.append("}  // namespace data")
    s.append("}  // namespace nyucd")
    return "\n".join(o) + "\n", "\n".join(s) + "\n"


def main():
    stats = "--stats" in sys.argv
    tables, shape = build(stats)
    if stats:
        log("tables header: %d bytes of source" % len(tables))
    with open(os.path.join(ROOT, "include", "NyUniDataTables.hpp"), "w", encoding="utf-8") as f:
        f.write(tables)
    with open(os.path.join(ROOT, "include", "NyUniDataShape.hpp"), "w", encoding="utf-8") as f:
        f.write(shape)


if __name__ == "__main__":
    main()
