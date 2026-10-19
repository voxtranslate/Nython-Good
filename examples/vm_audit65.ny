# vm_audit65.ny - bytes and bytearray, both engines (round 77).
#
#   literals        b"..", rb"..", escapes (\x \ooo \n), adjacent literals
#   values          len/index (an int)/slices (bytes)/iteration (ints),
#                   repr, ==, ordering, hash and dict keys, in, + and *
#   bytearray       mutable: item and slice assignment, del, append,
#                   extend, insert, pop, remove, +=, *=, aliases see changes
#   methods         every bytes method (NyBytes.hpp, one implementation)
#   codecs          str.encode / bytes.decode: utf-8, ascii, latin-1,
#                   utf-16/32, errors= strict/ignore/replace/backslashreplace
#   type members    bytes.fromhex, int.from_bytes, (n).to_bytes, str.upper(s),
#                   dict.fromkeys, bytes.maketrans; int/float methods
#   errors          Python's TypeError/ValueError/UnicodeDecodeError texts
#
# Every expectation is Python 3's value (the file also runs under python3
# with true/false/none defined), compared by repr.
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit65.ny
#     ./build/nython-cli --vm examples/vm_audit65.ny

pass_n = 0
fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

def set0(t):
    t[0] = 1

def err(f):
    try:
        f()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

# ── literals ─────────────────────────────────────────────────────────────
check("literal", b"abc", b"abc")
check("hex escape", b"\x00\xff", bytes([0, 255]))
check("octal escape", b"\101\0", bytes([65, 0]))
check("named escapes", b"\n\t\r\\", bytes([10, 9, 13, 92]))
check("raw bytes", rb"\x41", bytes([92, 120, 52, 49]))
check("adjacent", b"ab" b"cd", b"abcd")
check("single quotes", b'q"q', bytes([113, 34, 113]))
check("empty", b"", bytes())

# ── values ───────────────────────────────────────────────────────────────
b = b"hello"
check("len", len(b), 5)
check("index", b[0], 104)
check("negative index", b[-1], 111)
check("slice", b[1:3], b"el")
check("step slice", b[::2], b"hlo")
check("reversed slice", b[::-1], b"olleh")
check("iterate", [x for x in b"AB"], [65, 66])
check("list", list(b"\x01\x02"), [1, 2])
check("repr", repr(b"a'b"), "b\"a'b\"")
check("repr quotes", repr(b"'\""), "b'\\'\"'")
check("repr bytes", repr(b"\x00\x7f\x80 ~"), "b'\\x00\\x7f\\x80 ~'")
check("str is repr", str(b"x"), "b'x'")
check("equal", b"ab" == b"ab", true)
check("not equal to str", b"ab" == "ab", false)
check("bytes == bytearray", b"ab" == bytearray(b"ab"), true)
check("less", b"ab" < b"b", true)
check("less by byte", b"\x80" > b"\x7f", true)
check("prefix less", b"ab" < b"abc", true)
check("in int", 101 in b, true)
check("in bytes", b"ll" in b, true)
check("not in", b"z" not in b, true)
check("concat", b"a" + b"b", b"ab")
check("repeat", b"ab" * 3, b"ababab")
check("repeat left", 2 * b"x", b"xx")
check("hash equal", hash(b"abc") == hash(b"abc"), true)
d = {b"k": 1, "k": 2}
check("dict key types", [d[b"k"], d["k"]], [1, 2])
check("dict keys", list(d.keys()), [b"k", "k"])
check("set of bytes", len(set([b"a", b"a", b"b"])), 2)
check("truthy", [bool(b""), bool(b"\x00")], [false, true])
check("isinstance", [isinstance(b, bytes), isinstance(b, str), isinstance(bytearray(), bytearray), isinstance(bytearray(), bytes)], [true, false, true, false])
check("bytes()", [bytes(3), bytes([1, 2]), bytes(b"x"), bytes("é", "utf-8")], [b"\x00\x00\x00", b"\x01\x02", b"x", b"\xc3\xa9"])
check("bytes(str, encoding=)", bytes("ab", encoding="ascii"), b"ab")
check("bytes of a generator", bytes(x + 1 for x in range(3)), b"\x01\x02\x03")
check("ord", ord(b"A"), 65)
check("int of bytes", int(b" 42 "), 42)
check("max", max(b"az"), 122)
check("sorted", sorted(b"cab"), [97, 98, 99])
check("sum", sum(b"\x01\x02"), 3)

# ── bytearray ────────────────────────────────────────────────────────────
ba = bytearray(b"abc")
alias = ba
ba[0] = 65
check("item assign", ba, bytearray(b"Abc"))
check("alias sees it", alias, bytearray(b"Abc"))
ba.append(100)
ba.extend(b"ef")
ba.extend([103])
check("append/extend", ba, bytearray(b"Abcdefg"))
ba.insert(0, 33)
check("insert", ba, bytearray(b"!Abcdefg"))
check("pop", ba.pop(), 103)
check("pop index", ba.pop(0), 33)
ba.remove(98)
check("remove", ba, bytearray(b"Acdef"))
del ba[0]
check("del", ba, bytearray(b"cdef"))
ba[1:3] = b"XYZ"
check("slice assign", ba, bytearray(b"cXYZf"))
del ba[1:4]
check("del slice", ba, bytearray(b"cf"))
ba += b"!!"
check("+= in place", alias, bytearray(b"cf!!"))
ba *= 2
check("*= in place", alias, bytearray(b"cf!!cf!!"))
ba.clear()
check("clear", ba, bytearray())
ba2 = bytearray(b"xyz")
ba2.reverse()
check("reverse", ba2, bytearray(b"zyx"))
check("copy", ba2.copy(), bytearray(b"zyx"))
check("bytearray(n)", bytearray(2), bytearray(b"\x00\x00"))
check("bytearray repr", repr(bytearray(b"a")), "bytearray(b'a')")
check("bytearray methods give bytearray", bytearray(b"ab").upper(), bytearray(b"AB"))
check("bytes of bytearray", bytes(bytearray(b"q")), b"q")
check("bytearray + bytes", bytearray(b"a") + b"b", bytearray(b"ab"))
check("bytes + bytearray", b"a" + bytearray(b"b"), b"ab")

# ── methods ──────────────────────────────────────────────────────────────
check("split", b"a,b,,c".split(b","), [b"a", b"b", b"", b"c"])
check("split ws", b"  a  b ".split(), [b"a", b"b"])
check("split max", b"a b c".split(none, 1), [b"a", b"b c"])
check("rsplit", b"a.b.c".rsplit(b".", 1), [b"a.b", b"c"])
check("splitlines", b"a\nb\r\nc".splitlines(), [b"a", b"b", b"c"])
check("splitlines keep", b"a\nb".splitlines(true), [b"a\n", b"b"])
check("join", b"-".join([b"a", b"b", bytearray(b"c")]), b"a-b-c")
check("strip", b"  x ".strip(), b"x")
check("strip chars", b"xxaxx".strip(b"x"), b"a")
check("lstrip/rstrip", [b"  a ".lstrip(), b" a  ".rstrip()], [b"a ", b" a"])
check("upper/lower", [b"aB".upper(), b"aB".lower(), b"aB".swapcase()], [b"AB", b"ab", b"Ab"])
check("title/capitalize", [b"hello world".title(), b"hELLO".capitalize()], [b"Hello World", b"Hello"])
check("find", [b"hello".find(b"l"), b"hello".rfind(b"l"), b"hello".find(b"z"), b"hello".find(108)], [2, 3, -1, 2])
check("index", b"abc".index(b"c"), 2)
check("count", [b"aaa".count(b"a"), b"abab".count(b"ab"), b"abc".count(b"")], [3, 2, 4])
check("startswith", [b"abc".startswith(b"ab"), b"abc".endswith((b"x", b"c"))], [true, true])
check("replace", b"aXbXc".replace(b"X", b"--"), b"a--b--c")
check("replace count", b"aaa".replace(b"a", b"b", 2), b"bba")
check("partition", b"k=v=w".partition(b"="), (b"k", b"=", b"v=w"))
check("rpartition", b"k=v=w".rpartition(b"="), (b"k=v", b"=", b"w"))
check("partition missing", b"kv".partition(b"="), (b"kv", b"", b""))
check("center/ljust/rjust", [b"a".center(3), b"a".ljust(3, b"-"), b"a".rjust(3, b"0")], [b" a ", b"a--", b"00a"])
check("zfill", [b"42".zfill(5), b"-4".zfill(4)], [b"00042", b"-004"])
check("predicates", [b"123".isdigit(), b"ab".isalpha(), b"a1".isalnum(), b" \t".isspace(), b"AB".isupper(), b"ab".islower(), b"Ab Cd".istitle(), b"\x80".isascii()], [true, true, true, true, true, true, true, false])
check("removeprefix/suffix", [b"prefix-x".removeprefix(b"prefix-"), b"x.txt".removesuffix(b".txt")], [b"x", b"x"])
check("expandtabs", b"a\tb".expandtabs(4), b"a   b")
check("hex", [b"\x01\xab".hex(), b"\x01\x02\x03".hex(":"), b"\x01\x02\x03\x04".hex(" ", 2)], ["01ab", "01:02:03", "0102 0304"])
check("fromhex", bytes.fromhex("01 ab ff"), b"\x01\xab\xff")
check("bytearray.fromhex", bytearray.fromhex("6869"), bytearray(b"hi"))
check("translate", b"abc".translate(bytes.maketrans(b"ab", b"xy")), b"xyc")
check("translate delete", b"hello".translate(none, b"l"), b"heo")

# ── codecs ───────────────────────────────────────────────────────────────
check("utf-8 encode", "héllo".encode(), b"h\xc3\xa9llo")
check("utf-8 decode", b"h\xc3\xa9llo".decode(), "héllo")
check("latin-1", ["é".encode("latin-1"), b"\xe9".decode("latin-1")], [b"\xe9", "é"])
check("ascii", "abc".encode("ascii"), b"abc")
check("utf-16", "hi".encode("utf-16"), b"\xff\xfeh\x00i\x00")
check("utf-16-be", "hi".encode("utf-16-be"), b"\x00h\x00i")
check("utf-16 decode", b"\xff\xfeh\x00i\x00".decode("utf-16"), "hi")
check("utf-16 surrogate pair", "😀".encode("utf-16-le"), b"=\xd8\x00\xde")
check("utf-32", "a".encode("utf-32-le"), b"a\x00\x00\x00")
check("decode replace", b"a\xffb".decode("utf-8", "replace"), "a\ufffdb")
check("decode ignore", b"a\xffb".decode("utf-8", errors="ignore"), "ab")
check("decode backslashreplace", b"a\xffb".decode("utf-8", "backslashreplace"), "a\\xffb")
check("encode replace", "é".encode("ascii", "replace"), b"?")
check("encode xmlcharref", "é".encode("ascii", "xmlcharrefreplace"), b"&#233;")
check("str(b, enc)", str(b"\xc3\xa9", "utf-8"), "é")
check("utf-8 truncated", err(lambda: b"\xe2\x82".decode()), "UnicodeDecodeError: 'utf-8' codec can't decode bytes in position 0-1: unexpected end of data")
check("utf-8 bad start", err(lambda: b"a\xff".decode()), "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in position 1: invalid start byte")
check("utf-8 bad continuation", err(lambda: b"\xc3A".decode()), "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xc3 in position 0: invalid continuation byte")
check("utf-8 surrogate", err(lambda: b"\xed\xa0\x80".decode()), "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xed in position 0: invalid continuation byte")
check("ascii encode error", err(lambda: "aé".encode("ascii")), "UnicodeEncodeError: 'ascii' codec can't encode character '\\xe9' in position 1: ordinal not in range(128)")
check("unknown codec", err(lambda: "a".encode("nope")), "LookupError: unknown encoding: nope")
check("UnicodeError is a ValueError", issubclass(UnicodeDecodeError, ValueError), true)

# ── type members and number methods ──────────────────────────────────────
check("int.from_bytes", [int.from_bytes(b"\x01\x00", "big"), int.from_bytes(b"\x01\x00", "little")], [256, 1])
check("int.from_bytes signed", int.from_bytes(b"\xff\xfe", "big", signed=true), -2)
check("int.from_bytes big", int.from_bytes(b"\x01" + bytes(9), "big"), 4722366482869645213696)
check("to_bytes", [(1024).to_bytes(2, "big"), (1).to_bytes(2, "little"), (-2).to_bytes(2, "big", signed=true)], [b"\x04\x00", b"\x01\x00", b"\xff\xfe"])
check("to_bytes keywords", (258).to_bytes(length=2, byteorder="big"), b"\x01\x02")
check("to_bytes overflow", err(lambda: (256).to_bytes(1, "big")), "OverflowError: int too big to convert")
check("to_bytes negative", err(lambda: (-1).to_bytes(1, "big")), "OverflowError: can't convert negative int to unsigned")
check("bit_length", [(0).bit_length(), (255).bit_length(), (-256).bit_length(), (2 ** 100).bit_length()], [0, 8, 9, 101])
check("bit_count", [(7).bit_count(), (-7).bit_count()], [3, 3])
check("float methods", [(3.0).is_integer(), (3.5).is_integer(), (0.5).as_integer_ratio(), (1.5).hex(), (-0.25).hex()], [true, false, (1, 2), "0x1.8000000000000p+0", "-0x1.0000000000000p-2"])
check("as_integer_ratio 0.1", (0.1).as_integer_ratio(), (3602879701896397, 36028797018963968))
check("str.upper(s)", str.upper("abc"), "ABC")
check("str.join through the type", str.join(",", ["a", "b"]), "a,b")
check("bytes.decode through the type", bytes.decode(b"hi"), "hi")
check("dict.fromkeys", dict.fromkeys(["a", "b"], 0), {"a": 0, "b": 0})
check("list.append through the type", err(lambda: list.append("x", 1)), "TypeError: descriptor 'append' for 'list' objects doesn't apply to a 'str' object")

# ── errors ───────────────────────────────────────────────────────────────
check("bytes + str", err(lambda: b"a" + "b"), "TypeError: can't concat str to bytes")
check("str + bytes", err(lambda: "a" + b"b"), "TypeError: can only concatenate str (not \"bytes\") to str")
check("bytes item assign", err(lambda: set0(b"ab")), "TypeError: 'bytes' object does not support item assignment")
check("bytes index range", err(lambda: b"ab"[5]), "IndexError: index out of range")
check("bytearray index range", err(lambda: bytearray(b"ab")[5]), "IndexError: bytearray index out of range")
check("byte range", err(lambda: bytearray(b"a").append(256)), "ValueError: byte must be in range(0, 256)")
check("bytes(str) needs encoding", err(lambda: bytes("x")), "TypeError: string argument without an encoding")
check("bytes(-1)", err(lambda: bytes(-1)), "ValueError: negative count")
check("unhashable bytearray", err(lambda: {bytearray(b"a"): 1}), "TypeError: unhashable type: 'bytearray'")
check("bytes < str", err(lambda: b"a" < "a"), "TypeError: '<' not supported between instances of 'bytes' and 'str'")
check("fromhex error", err(lambda: bytes.fromhex("0g")), "ValueError: non-hexadecimal number found in fromhex() arg at position 1")
check("split empty sep", err(lambda: b"a".split(b"")), "ValueError: empty separator")
check("join non-bytes", err(lambda: b"".join([b"a", "b"])), "TypeError: sequence item 1: expected a bytes-like object, str found")

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT65 PASSED ===")
