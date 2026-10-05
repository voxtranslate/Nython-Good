# vm_audit77.ny - Python's json, random, datetime, time and io modules
# (lib/json/, lib/random.ny, lib/datetime.ny, lib/time.ny, lib/io.ny).
#
# Written in the subset Nython and Python share, so the same file runs
# under python3 - every expected value below is what CPython computes (the
# random sequences were produced by CPython from the same seeds: the
# generator is bit-exact).
#
#   json      dumps/dump options, float repr, escapes, keys, circular and
#             NaN errors, default/cls, iterencode chunks, loads/load with
#             hooks, strict, bytes input, JSONDecodeError positions and
#             messages, raw_decode, a large document round trip
#   random    seeds (int, negative, big, str, bytes, float), random,
#             getrandbits, randrange, randint, choice, shuffle, sample (pool
#             and set paths, counts), choices (weights, cum_weights), the
#             distributions, gauss caching, randbytes, getstate/setstate,
#             subclassing, SystemRandom, errors
#   datetime  timedelta, date, time, datetime, timezone: construction and
#             errors, arithmetic, comparisons, reprs, isoformat/fromisoformat,
#             strftime/strptime, timestamps, astimezone, dict keys
#   time      struct_time, gmtime, strftime, strptime, mktime, asctime,
#             clocks, sleep
#   io        StringIO, BytesIO, TextIOWrapper, newline modes, seek/truncate,
#             print(file=), errors
#   engines   float literals that underflow/overflow, str.format with an
#             object's __format__, divmod with __divmod__, objects with
#             __hash__ as dict keys, import math as m
#
# Must pass on both engines (and python3):
#     ./build/nython-cli examples/vm_audit77.ny
#     ./build/nython-cli --vm examples/vm_audit77.ny
#     python3 examples/vm_audit77.ny
try:
    true
except NameError:
    true = True
    false = False
    none = None

import json
import random
import datetime
import time
import io
import sys
from datetime import date, timedelta, timezone
from io import StringIO, BytesIO

pass_n = 0
fail_n = 0
results = []


def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])


def err(f):
    try:
        f()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"


def errtype(f):
    try:
        f()
    except Exception as e:
        return type(e).__name__
    return "no error"


# ── json: dumps ──────────────────────────────────────────────────────────────
check("dumps basic", json.dumps({"a": [1, 2.5, None, True, False], "b": "x"}),
      '{"a": [1, 2.5, null, true, false], "b": "x"}')
check("dumps floats", json.dumps([1e16, 0.1, 1e-07, 3.0, -0.0, 1e300, 123456789.125, 1e22, 5e-324, 0.0001, 1e15]),
      '[1e+16, 0.1, 1e-07, 3.0, -0.0, 1e+300, 123456789.125, 1e+22, 5e-324, 0.0001, 1000000000000000.0]')
check("dumps tuple", json.dumps((1, (2, 3), [])), "[1, [2, 3], []]")
check("dumps scalars", [json.dumps(None), json.dumps(True), json.dumps("s"), json.dumps(-7), json.dumps(10 ** 30)],
      ["null", "true", '"s"', "-7", "1000000000000000000000000000000"])
check("dumps keys", json.dumps({1: "i", 2.5: "f", None: "n", "s": 1}), '{"1": "i", "2.5": "f", "null": "n", "s": 1}')
check("dumps key order", json.dumps({"z": 1, "a": 2, "m": 3}), '{"z": 1, "a": 2, "m": 3}')
check("dumps indent", json.dumps({"a": [1, {"b": 2}], "c": {}, "d": []}, indent=2),
      '{\n  "a": [\n    1,\n    {\n      "b": 2\n    }\n  ],\n  "c": {},\n  "d": []\n}')
check("dumps indent str", json.dumps([1, [2]], indent="\t"), "[\n\t1,\n\t[\n\t\t2\n\t]\n]")
check("dumps indent 0", json.dumps([1, 2], indent=0), "[\n1,\n2\n]")
check("dumps separators", json.dumps({"a": 1, "b": [1, 2]}, separators=(",", ":")), '{"a":1,"b":[1,2]}')
check("dumps sort_keys", json.dumps({"b": 1, "a": 2, "c": {"z": 1, "y": 2}}, sort_keys=True, indent=1),
      '{\n "a": 2,\n "b": 1,\n "c": {\n  "y": 2,\n  "z": 1\n }\n}')
check("dumps sort numeric keys", json.dumps({2: "a", 1: "b", 1.5: "c"}, sort_keys=True), '{"1": "b", "1.5": "c", "2": "a"}')
check("dumps sort mixed keys", errtype(lambda: json.dumps({1: 1, "a": 2}, sort_keys=True)), "TypeError")
check("dumps ensure_ascii", json.dumps("é\U0001F600\x7f"), '"\\u00e9\\ud83d\\ude00\\u007f"')
check("dumps ensure_ascii off", json.dumps("é\U0001F600\x7f", ensure_ascii=False), '"é\U0001F600\x7f"')
check("dumps escapes", json.dumps("a\"b\\c\n\r\t\b\f\x01\x1f/"), '"a\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f/"')
check("dumps lone surrogate", json.dumps("\ud800x"), '"\\ud800x"')
check("dumps nan", json.dumps([float("nan"), float("inf"), -float("inf")]), "[NaN, Infinity, -Infinity]")
check("dumps allow_nan", err(lambda: json.dumps([1, float("inf")], allow_nan=False)).startswith(
      "ValueError: Out of range float values are not JSON compliant"), true)
circ = [1]
circ.append(circ)
check("dumps circular", err(lambda: json.dumps(circ)), "ValueError: Circular reference detected")
circd = {"a": 1}
circd["self"] = circd
check("dumps circular dict", err(lambda: json.dumps(circd, indent=1)), "ValueError: Circular reference detected")
check("dumps shared ok", json.dumps([[1], [1]]), "[[1], [1]]")


class Pt:
    def __init__(self, x, y):
        self.x = x
        self.y = y


check("dumps default", json.dumps({"s": {3, 1, 2}}, default=sorted), '{"s": [1, 2, 3]}')
check("dumps default obj", json.dumps([Pt(1, 2)], default=lambda o: {"x": o.x, "y": o.y}), '[{"x": 1, "y": 2}]')
check("dumps not serializable", err(lambda: json.dumps([1, Pt(1, 2)])), "TypeError: Object of type Pt is not JSON serializable")
check("dumps skipkeys", json.dumps({(1, 2): 1, "a": 2}, skipkeys=True), '{"a": 2}')
check("dumps bad key", err(lambda: json.dumps({(1, 2): 1})), "TypeError: keys must be str, int, float, bool or None, not tuple")


class PtEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Pt):
            return [o.x, o.y]
        return json.JSONEncoder.default(self, o)


check("dumps cls", json.dumps({"p": Pt(3, 4), "n": 1}, cls=PtEncoder), '{"p": [3, 4], "n": 1}')
check("dumps cls error", err(lambda: json.dumps(Pt, cls=PtEncoder)).startswith("TypeError: Object of type"), true)
check("JSONEncoder.encode", json.JSONEncoder(sort_keys=True).encode({"b": [1], "a": "x"}), '{"a": "x", "b": [1]}')
check("iterencode", list(json.JSONEncoder().iterencode([1, {"a": 2}, "x", [], {}])),
      ["[1", ", ", "{", '"a"', ": ", "2", "}", ', "x"', ", ", "[]", ", ", "{}", "]"])
check("iterencode indent", list(json.JSONEncoder(indent=1).iterencode({"a": [1]})),
      ["{", "\n ", '"a"', ": ", "[\n  1", "\n ", "]", "\n", "}"])
check("encode_basestring", [json.encoder.encode_basestring('a"é'), json.encoder.encode_basestring_ascii('a"é')],
      ['"a\\"é"', '"a\\"\\u00e9"'])
out = StringIO()
json.dump({"k": [1, 2]}, out, indent=1)
check("dump to StringIO", out.getvalue(), '{\n "k": [\n  1,\n  2\n ]\n}')

# ── json: loads ──────────────────────────────────────────────────────────────
check("loads basic", json.loads('{"a": [1, 2.5, null, true, false], "b": "x"}'),
      {"a": [1, 2.5, None, True, False], "b": "x"})
check("loads numbers", json.loads("[1, 2.0, -0, -0.0, 1E2, 1e-2, 123456789012345678901234567890, 1e400]"),
      [1, 2.0, 0, -0.0, 100.0, 0.01, 123456789012345678901234567890, float("inf")])
check("loads escapes", json.loads('["\\u00e9\\ud83d\\ude00", "a\\nb\\t\\"\\/\\\\"]'), ["é\U0001F600", 'a\nb\t"/\\'])
check("loads lone surrogate", json.loads('"\\ud800"'), "\ud800")
check("loads duplicate keys", json.loads('{"a": 1, "b": 2, "a": 3}'), {"a": 3, "b": 2})
check("loads key order", list(json.loads('{"z": 1, "a": 2, "m": 3}').keys()), ["z", "a", "m"])
check("loads constants", repr(json.loads("[NaN, Infinity, -Infinity]")), "[nan, inf, -inf]")
check("loads whitespace", json.loads(" \n\t[ 1 , { \"a\" : 2 } ]\r\n "), [1, {"a": 2}])
check("loads empty containers", json.loads('[[], {}, [{}], ""]'), [[], {}, [{}], ""])
check("loads unicode text", json.loads('"été 中"'), "été 中")


def dec_err(text):
    try:
        json.loads(text)
    except json.JSONDecodeError as e:
        return [e.msg, e.pos, e.lineno, e.colno, str(e)]
    return "no error"


check("JSONDecodeError fields", dec_err('{"a":\n [1,\n 2 x]}'),
      ["Expecting ',' delimiter", 14, 3, 4, "Expecting ',' delimiter: line 3 column 4 (char 14)"])
check("error empty", dec_err(""), ["Expecting value", 0, 1, 1, "Expecting value: line 1 column 1 (char 0)"])
check("error spaces", dec_err("   ")[4], "Expecting value: line 1 column 4 (char 3)")
check("error extra data", dec_err("[1] 2")[4], "Extra data: line 1 column 5 (char 4)")
check("error leading zero", dec_err("01")[4], "Extra data: line 1 column 2 (char 1)")
check("error trailing comma", dec_err("[1,]")[4], "Expecting value: line 1 column 4 (char 3)")
check("error object comma", dec_err('{"a":1,}')[4], "Expecting property name enclosed in double quotes: line 1 column 8 (char 7)")
check("error colon", dec_err('{"a" 1}')[4], "Expecting ':' delimiter: line 1 column 6 (char 5)")
check("error unterminated", dec_err('"abc')[4], "Unterminated string starting at: line 1 column 1 (char 0)")
check("error control char", dec_err('"a\nb"')[4], "Invalid control character at: line 1 column 3 (char 2)")
check("error bad escape", dec_err('"\\x"')[4], "Invalid \\escape: line 1 column 2 (char 1)")
check("error bad uXXXX", dec_err('"\\u12"')[4], "Invalid \\uXXXX escape: line 1 column 3 (char 2)")
check("error none literal", dec_err("none")[0], "Expecting value")
check("error after unicode", dec_err('["éé"] x')[4], "Extra data: line 1 column 8 (char 7)")
check("error delimiter eof", dec_err("[1,2")[4], "Expecting ',' delimiter: line 1 column 5 (char 4)")
check("JSONDecodeError is ValueError", issubclass(json.JSONDecodeError, ValueError), true)
check("json.decoder.JSONDecodeError", json.decoder.JSONDecodeError == json.JSONDecodeError, true)
check("loads BOM", err(lambda: json.loads("﻿[1]")), "JSONDecodeError: Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)")
check("loads type", err(lambda: json.loads(5)), "TypeError: the JSON object must be str, bytes or bytearray, not int")
check("loads bytes", [json.loads(b'{"k": "\xc3\xa9"}'), json.loads("[1]".encode("utf-16")),
                      json.loads('"x"'.encode("utf-16-le")), json.loads(bytearray(b"[2]"))],
      [{"k": "é"}, [1], "x", [2]])
check("parse_float/int", json.loads("[1, 2.5, 7]", parse_float=lambda s: "F" + s, parse_int=lambda s: "I" + s), ["I1", "F2.5", "I7"])
check("object_hook", json.loads('{"a": {"b": 1}, "c": [{}]}', object_hook=lambda d: ("H", sorted(d.items()))),
      ("H", [("a", ("H", [("b", 1)])), ("c", [("H", [])])]))
check("object_pairs_hook", json.loads('{"a": 1, "a": 2, "b": {"x": []}}', object_pairs_hook=lambda p: ("P", p)),
      ("P", [("a", 1), ("a", 2), ("b", ("P", [("x", [])]))]))
check("parse_constant", json.loads("[NaN, -Infinity]", parse_constant=lambda s: "C" + s), ["CNaN", "C-Infinity"])
check("hooks together", json.loads('{"a": [1.5, {"b": 2}], "c": NaN}', object_hook=lambda d: sorted(d.items()),
                                   parse_float=lambda s: "F" + s, parse_constant=lambda s: s),
      [("a", ["F1.5", [("b", 2)]]), ("c", "NaN")])
check("object_hook replaces", json.loads('[{"x": {"y": 1}}, 2]', object_hook=lambda d: len(d)), [1, 2])
check("strict False", json.loads('"a\tb"', strict=False), "a\tb")
check("strict True", errtype(lambda: json.loads('"a\tb"')), "JSONDecodeError")
check("raw_decode", json.JSONDecoder().raw_decode("[1, 2] tail"), ([1, 2], 6))
check("raw_decode idx", json.JSONDecoder().raw_decode('xx {"a": 1}', 3), ({"a": 1}, 11))
check("scanstring", json.decoder.scanstring('"abc\\n" rest', 1), ("abc\n", 7))


class CountDecoder(json.JSONDecoder):
    def decode(self, s):
        return ["decoded", json.JSONDecoder.decode(self, s)]


check("loads cls", json.loads("[1]", cls=CountDecoder), ["decoded", [1]])
check("load from StringIO", json.load(StringIO('{"x": [true]}')), {"x": [True]})
nested = "[" * 50 + "]" * 50
check("loads nested", json.dumps(json.loads(nested)), nested.replace("][", "], ["))

# a large document: the native codec on both engines
big = []
for i in range(3000):
    big.append({"id": i, "name": "item-" + str(i), "tags": ["a", "bé", str(i * 7)],
                "score": i * 0.25 + 0.1, "ok": i % 3 == 0, "none": None})
big_text = json.dumps(big)
check("large dumps size", len(big_text) > 250000, true)
check("large roundtrip", json.loads(big_text) == big, true)
check("large indent roundtrip", json.loads(json.dumps(big, indent=2, sort_keys=True)) == big, true)
check("large first item", json.dumps(big[3]), '{"id": 3, "name": "item-3", "tags": ["a", "b\\u00e9", "21"], "score": 0.85, "ok": true, "none": null}')

# ── random: bit-exact with CPython ───────────────────────────────────────────
r = random.Random(42)
check("random seed 42", [r.random() for i in range(6)],
      [0.6394267984578837, 0.025010755222666936, 0.27502931836911926, 0.22321073814882275, 0.7364712141640124, 0.6766994874229113])
r = random.Random(0)
check("randint seed 0", [r.randint(1, 100) for i in range(12)], [50, 98, 54, 6, 34, 66, 63, 52, 39, 62, 46, 75])
r = random.Random(2 ** 100 + 7)
check("getrandbits big seed", [r.getrandbits(k) for k in [1, 5, 31, 32, 33, 64, 65, 100, 200]],
      [0, 2, 701722459, 2297707818, 2390882014, 13988688003495507304, 29079415961757512294,
       894917142830616879656965966328, 773478046121119674858819343981777585986350841062444553521026])
r = random.Random(-5)
check("negative seed", [r.random() for i in range(3)], [0.6229016948897019, 0.7417869892607294, 0.7951935655656966])
r = random.Random("hello")
check("str seed", [r.random() for i in range(3)], [0.3537754404730722, 0.6631985810268619, 0.5476053663383964])
r = random.Random(b"bytes!")
check("bytes seed", [r.random() for i in range(3)], [0.20190387430786427, 0.23959694953561217, 0.9539230618984316])
r = random.Random(3.5)
check("float seed", [r.random() for i in range(3)], [0.3039190124834461, 0.23014450764056538, 0.9120431245165537])
r = random.Random(1)
check("randrange", [r.randrange(10), r.randrange(5, 50), r.randrange(0, 100, 7), r.randrange(100, 0, -3), r.randrange(10 ** 30)],
      [2, 41, 91, 88, 989990361817605419587374691388])
r = random.Random(7)
xs = list(range(20))
r.shuffle(xs)
check("shuffle", xs, [17, 15, 11, 18, 7, 6, 19, 3, 14, 0, 9, 5, 16, 8, 13, 2, 1, 12, 4, 10])
check("choice", [r.choice("abcdefg") for i in range(8)], ["a", "e", "d", "a", "g", "e", "a", "b"])
check("sample pool", r.sample(range(10), 4), [9, 0, 6, 8])
check("sample set", r.sample(range(1000), 8), [999, 226, 47, 570, 879, 136, 296, 429])
check("sample counts", r.sample(["a", "b"], counts=[3, 2], k=4), ["a", "a", "a", "b"])
r = random.Random(11)
check("choices", r.choices("xyz", k=6), ["y", "y", "z", "y", "y", "y"])
check("choices weights", r.choices(["a", "b", "c"], weights=[1, 5, 10], k=6), ["b", "c", "c", "c", "b", "b"])
check("choices cum_weights", r.choices(["a", "b", "c"], cum_weights=[1, 6, 16], k=6), ["b", "c", "c", "a", "c", "c"])
r = random.Random(99)
check("uniform/triangular", [r.uniform(1, 2), r.triangular(), r.triangular(0, 10, 2)],
      [1.4039780749436663, 0.31628740456659465, 1.8910437360707038])
check("gauss (cached pair)", [r.gauss(), r.gauss(10, 2), r.gauss()], [0.016648480522780455, 13.3781263668788, -0.007107898848509352])
check("normal/lognormal", [r.normalvariate(), r.lognormvariate(0, 1)], [0.6853197896832774, 4.360164906099565])
check("expo/vonmises", [r.expovariate(2.0), r.vonmisesvariate(1.0, 4.0), r.vonmisesvariate(0, 0)],
      [0.27377877078496404, 1.6890990952601932, 2.349784279138409])
check("gamma", [r.gammavariate(0.5, 1.0), r.gammavariate(1.0, 2.0), r.gammavariate(3.0, 1.5)],
      [0.2111412025635657, 0.33040159628410015, 6.0608122438965655])
check("beta/pareto/weibull", [r.betavariate(2, 3), r.paretovariate(3), r.weibullvariate(1, 1.5)],
      [0.30092087724643285, 1.2349398512975218, 0.6426692370417627])
r = random.Random(5)
check("randbytes", r.randbytes(10), b"E|v\x9f9\xd8dA\xe5\xbd")
st = r.getstate()
seq_a = [r.random() for i in range(3)]
r.setstate(st)
seq_b = [r.random() for i in range(3)]
check("getstate/setstate", [seq_a == seq_b, st[0], len(st[1]), st[1][-1]], [True, 3, 625, 3])
check("state words", list(random.Random(12345).getstate()[1][:3]), [2147483648, 2105189241, 1699489545])
random.seed(2024)
check("module functions", [random.random(), random.randint(1, 6), random.choice([10, 20, 30])], [0.47009071843107064, 6, 30])
r = random.Random(8)
total = 0.0
for i in range(2000):
    total = total + r.random()
check("2000 draws", total, 987.6616994582716)
if hasattr(random, "binomialvariate"):
    r = random.Random(3)
    check("binomialvariate", [r.binomialvariate(1, 0.3), r.binomialvariate(10, 0.2), r.binomialvariate(100, 0.4),
                              r.binomialvariate(50, 0.9), r.binomialvariate(5, 0), r.binomialvariate(5, 1)], [1, 2, 42, 48, 0, 5])
r1 = random.Random(77)
r2 = random.Random(77)
check("same seed same stream", [r1.random() for i in range(4)] == [r2.random() for i in range(4)], true)
r1.seed(77)
check("reseed", r1.random(), random.Random(77).random())


class Fixed(random.Random):
    def random(self):
        return 0.5


fx = Fixed()
check("subclass random()", [fx.uniform(0, 10), fx.choice([1, 2, 3, 4]), fx.randrange(10)], [5.0, 1, 6])
check("SystemRandom", [0 <= random.SystemRandom().random() < 1, random.SystemRandom().getrandbits(0),
                       len(random.SystemRandom().randbytes(5)), 1 <= random.SystemRandom().randint(1, 3) <= 3],
      [True, 0, 5, True])
check("SystemRandom state", errtype(lambda: random.SystemRandom().getstate()), "NotImplementedError")
check("randrange empty", errtype(lambda: random.randrange(0)), "ValueError")
check("randrange empty 2", errtype(lambda: random.randrange(5, 5)), "ValueError")
check("randint empty", errtype(lambda: random.randint(5, 1)), "ValueError")
check("randrange zero step",err(lambda: random.randrange(0, 10, 0)), "ValueError: zero step for randrange()")
check("choice empty", err(lambda: random.choice([])), "IndexError: Cannot choose from an empty sequence")
check("sample too big", err(lambda: random.sample([1, 2], 3)), "ValueError: Sample larger than population or is negative")
check("sample set population", errtype(lambda: random.sample({1, 2}, 1)), "TypeError")
check("choices bad weights", err(lambda: random.choices([1, 2], [1], k=1)), "ValueError: The number of weights does not match the population")
check("getrandbits negative", err(lambda: random.getrandbits(-1)), "ValueError: number of bits must be non-negative")
check("gammavariate bad", err(lambda: random.gammavariate(0, 1)), "ValueError: gammavariate: alpha and beta must be > 0.0")
check("seed type", errtype(lambda: random.seed([1])), "TypeError")
check("setstate version", err(lambda: random.setstate((9, (), None))), "ValueError: state with version 9 passed to Random.setstate() of version 3")

# ── datetime: timedelta ──────────────────────────────────────────────────────
check("timedelta repr", [repr(timedelta(days=1, hours=1)), repr(timedelta()), repr(timedelta(microseconds=-1))],
      ["datetime.timedelta(days=1, seconds=3600)", "datetime.timedelta(0)", "datetime.timedelta(days=-1, seconds=86399, microseconds=999999)"])
check("timedelta str", [str(timedelta(hours=-1)), str(timedelta(days=-2, microseconds=5)), str(timedelta(days=1, seconds=61)), str(timedelta(0))],
      ["-1 day, 23:00:00", "-2 days, 0:00:00.000005", "1 day, 0:01:01", "0:00:00"])
check("timedelta normalise", [timedelta(seconds=1.5, microseconds=0.5), timedelta(0.1), timedelta(weeks=1, milliseconds=1)],
      [timedelta(seconds=1, microseconds=500000), timedelta(seconds=8640), timedelta(days=7, microseconds=1000)])
check("timedelta fields", [timedelta(hours=-1).days, timedelta(hours=-1).seconds, timedelta(minutes=90).total_seconds()], [-1, 82800, 5400.0])
check("timedelta arith", [timedelta(1) + timedelta(hours=1), timedelta(1) - timedelta(hours=1), -timedelta(1), abs(timedelta(-1)),
                          timedelta(1) * 2, 3 * timedelta(hours=1), timedelta(1) * 0.1, timedelta(1) / 3],
      [timedelta(days=1, seconds=3600), timedelta(seconds=82800), timedelta(-1), timedelta(1), timedelta(2),
       timedelta(seconds=10800), timedelta(seconds=8640), timedelta(seconds=28800)])
check("timedelta division", [timedelta(1) // timedelta(hours=5), timedelta(1) % timedelta(hours=5),
                             timedelta(1) / timedelta(hours=6), timedelta(hours=1) // 7],
      [4, timedelta(seconds=14400), 4.0, timedelta(seconds=514, microseconds=285714)])
check("timedelta divmod", divmod(timedelta(1), timedelta(hours=5)), (4, timedelta(seconds=14400)))
check("timedelta compare", [timedelta(1) > timedelta(hours=23), timedelta(1) == timedelta(hours=24), timedelta(1) != 1,
                            bool(timedelta(0)), bool(timedelta(microseconds=1))], [True, True, True, False, True])
check("timedelta min/max", [repr(timedelta.min), repr(timedelta.max), repr(timedelta.resolution)],
      ["datetime.timedelta(days=-999999999)", "datetime.timedelta(days=999999999, seconds=86399, microseconds=999999)",
       "datetime.timedelta(microseconds=1)"])
check("timedelta overflow", err(lambda: timedelta(days=1000000000)), "OverflowError: days=1000000000; must have magnitude <= 999999999")
check("timedelta + int", err(lambda: timedelta(1) + 1), "TypeError: unsupported operand type(s) for +: 'datetime.timedelta' and 'int'")
check("timedelta < int", err(lambda: timedelta(1) < 1), "TypeError: '<' not supported between instances of 'datetime.timedelta' and 'int'")
check("timedelta / 0", errtype(lambda: timedelta(1) / 0), "ZeroDivisionError")
check("timedelta sorted", sorted([timedelta(3), timedelta(-1), timedelta(hours=5)]), [timedelta(-1), timedelta(hours=5), timedelta(3)])

# ── datetime: date ───────────────────────────────────────────────────────────
d = date(2024, 1, 2)
check("date repr/str", [repr(d), str(d), d.isoformat(), d.ctime()], ["datetime.date(2024, 1, 2)", "2024-01-02", "2024-01-02", "Tue Jan  2 00:00:00 2024"])
check("date fields", [d.year, d.month, d.day, d.weekday(), d.isoweekday(), d.toordinal()], [2024, 1, 2, 1, 2, 738887])
check("date isocalendar", [tuple(d.isocalendar()), d.isocalendar().week, repr(date(2021, 1, 1).isocalendar())],
      [(2024, 1, 2), 1, "datetime.IsoCalendarDate(year=2020, week=53, weekday=5)"])
check("date arithmetic", [d + timedelta(days=30), timedelta(days=-2) + d, d - timedelta(days=2), d - date(2023, 1, 1)],
      [date(2024, 2, 1), date(2023, 12, 31), date(2023, 12, 31), timedelta(366)])
check("date compare", [date(2024, 1, 1) < d, d == date(2024, 1, 2), d != date(2024, 1, 3), max(d, date(2020, 5, 5))],
      [True, True, True, d])
check("date fromordinal", [date.fromordinal(1), date.fromordinal(738887), date.fromordinal(3652059)],
      [date(1, 1, 1), d, date(9999, 12, 31)])
check("date fromisoformat", [date.fromisoformat("2024-03-04"), date.fromisoformat("20240304"), date.fromisoformat("2024-W10-1"), date.fromisoformat("2024W101")],
      [date(2024, 3, 4), date(2024, 3, 4), date(2024, 3, 4), date(2024, 3, 4)])
check("date fromisocalendar", [date.fromisocalendar(2020, 53, 5), date.fromisocalendar(2024, 1, 1)], [date(2021, 1, 1), date(2024, 1, 1)])
check("date replace", [d.replace(day=31), d.replace(year=2000, month=2)], [date(2024, 1, 31), date(2000, 2, 2)])
check("date strftime", d.strftime("%Y/%m/%d %a %A %b %B %j %U %W %w %y %%"), "2024/01/02 Tue Tuesday Jan January 002 00 01 2 24 %")
check("date format", [format(d, "%d.%m.%Y"), "{:%Y-%m}".format(d), "{0:%d} {1}".format(d, 5), f"{d:%b %d}", format(d, "")],
      ["02.01.2024", "2024-01", "02 5", "Jan 02", "2024-01-02"])
check("date timetuple", repr(d.timetuple()), "time.struct_time(tm_year=2024, tm_mon=1, tm_mday=2, tm_hour=0, tm_min=0, tm_sec=0, tm_wday=1, tm_yday=2, tm_isdst=-1)")
check("date min/max", [repr(date.min), repr(date.max), repr(date.resolution)], ["datetime.date(1, 1, 1)", "datetime.date(9999, 12, 31)", "datetime.timedelta(days=1)"])
check("date errors", [err(lambda: date(2024, 13, 1)), err(lambda: date(2024, 2, 30)), err(lambda: date(0, 1, 1)),
                      errtype(lambda: date(2024, 1.5, 1)), err(lambda: date.fromordinal(0))],
      ["ValueError: month must be in 1..12", "ValueError: day is out of range for month", "ValueError: year 0 is out of range",
       "TypeError", "ValueError: ordinal must be >= 1"])
check("date fromisoformat errors", [err(lambda: date.fromisoformat("2024-1-01")), err(lambda: date.fromisoformat("2024-02-30")),
                                    err(lambda: date.fromisocalendar(2024, 54, 1)), err(lambda: date.fromisocalendar(2024, 1, 8))],
      ["ValueError: Invalid isoformat string: '2024-1-01'", "ValueError: day is out of range for month",
       "ValueError: Invalid week: 54", "ValueError: Invalid day: 8 (range is [1, 7])"])
check("date overflow", err(lambda: date(9999, 12, 31) + timedelta(1)), "OverflowError: date value out of range")
check("date + date", err(lambda: date(2024, 1, 1) + date(2024, 1, 1)), "TypeError: unsupported operand type(s) for +: 'datetime.date' and 'datetime.date'")
check("date - int", err(lambda: date(2024, 1, 1) - 1), "TypeError: unsupported operand type(s) for -: 'datetime.date' and 'int'")
check("date today type", [isinstance(date.today(), date), date.today().year >= 2024], [True, True])
check("date leap", [date(2024, 2, 29) + timedelta(365), date(2023, 3, 1) - date(2023, 2, 28), date(2000, 2, 29).toordinal()],
      [date(2025, 2, 28), timedelta(1), 730179])

# ── datetime: time ───────────────────────────────────────────────────────────
t = datetime.time(1, 2, 3, 4)
check("time repr/str", [repr(t), str(t), repr(datetime.time()), repr(datetime.time(5, 6, 7)), repr(datetime.time(1, 2, tzinfo=timezone.utc, fold=1))],
      ["datetime.time(1, 2, 3, 4)", "01:02:03.000004", "datetime.time(0, 0)", "datetime.time(5, 6, 7)", "datetime.time(1, 2, tzinfo=datetime.timezone.utc, fold=1)"])
check("time isoformat", [t.isoformat("hours"), t.isoformat("minutes"), t.isoformat("seconds"), t.isoformat("milliseconds"), t.isoformat("microseconds")],
      ["01", "01:02", "01:02:03", "01:02:03.000", "01:02:03.000004"])
check("time fromisoformat", [datetime.time.fromisoformat("T03:04"), datetime.time.fromisoformat("10:00:00.5+01:00"), datetime.time.fromisoformat("235959")],
      [datetime.time(3, 4), datetime.time(10, 0, 0, 500000, tzinfo=timezone(timedelta(hours=1))), datetime.time(23, 59, 59)])
check("time compare", [datetime.time(1) < datetime.time(2), datetime.time(1) == datetime.time(1, tzinfo=timezone.utc),
                       datetime.time(12, tzinfo=timezone(timedelta(hours=2))) == datetime.time(10, tzinfo=timezone.utc)], [True, False, True])
check("time naive vs aware", err(lambda: datetime.time(1) < datetime.time(1, tzinfo=timezone.utc)), "TypeError: can't compare offset-naive and offset-aware times")
check("time strftime", datetime.time(13, 5, 9, 7).strftime("%H|%I|%M|%S|%f|%p|%Y"), "13|01|05|09|000007|PM|1900")
check("time utcoffset", [datetime.time(1, tzinfo=timezone(timedelta(hours=-3))).utcoffset(), datetime.time(1).utcoffset(), datetime.time(1, tzinfo=timezone.utc).tzname()],
      [timedelta(hours=-3), None, "UTC"])
check("time replace", t.replace(hour=23, microsecond=0), datetime.time(23, 2, 3))
check("time errors", [err(lambda: datetime.time(24)), err(lambda: datetime.time(0, 60)), err(lambda: datetime.time(0, 0, 0, 1000000)),
                      err(lambda: datetime.time(1, fold=2))],
      ["ValueError: hour must be in 0..23", "ValueError: minute must be in 0..59", "ValueError: microsecond must be in 0..999999",
       "ValueError: fold must be either 0 or 1"])
check("time min/max", [repr(datetime.time.min), repr(datetime.time.max)], ["datetime.time(0, 0)", "datetime.time(23, 59, 59, 999999)"])

# ── datetime: datetime ───────────────────────────────────────────────────────
DT = datetime.datetime
dt = DT(2024, 1, 2, 3, 4, 5)
check("datetime repr/str", [repr(dt), str(dt), repr(DT(2024, 1, 2)), repr(DT(2024, 1, 2, 3, 4, 5, 6, fold=1)), str(DT(2024, 1, 2, 3, 4, 5, 60))],
      ["datetime.datetime(2024, 1, 2, 3, 4, 5)", "2024-01-02 03:04:05", "datetime.datetime(2024, 1, 2, 0, 0)",
       "datetime.datetime(2024, 1, 2, 3, 4, 5, 6, fold=1)", "2024-01-02 03:04:05.000060"])
check("datetime isoformat", [dt.isoformat(), dt.isoformat(" "), DT(2024, 1, 1, 13, 5, 9, 1234).isoformat(" ", "milliseconds"),
                             dt.isoformat(timespec="hours"), DT(2024, 1, 1, 13, 5, 9, tzinfo=timezone(timedelta(hours=-5, seconds=-7))).isoformat()],
      ["2024-01-02T03:04:05", "2024-01-02 03:04:05", "2024-01-01 13:05:09.001", "2024-01-02T03", "2024-01-01T13:05:09-05:00:07"])
check("datetime timespec error", err(lambda: dt.isoformat(timespec="x")), "ValueError: Unknown timespec value")
check("datetime ctime", DT(2024, 1, 1, 13, 5, 9).ctime(), "Mon Jan  1 13:05:09 2024")
check("datetime arithmetic", [dt + timedelta(hours=25), dt - timedelta(days=3), DT(2024, 3, 4, 5) - DT(2023, 3, 4, 6, 30),
                              timedelta(minutes=1) + dt, dt + timedelta(microseconds=-1)],
      [DT(2024, 1, 3, 4, 4, 5), DT(2023, 12, 30, 3, 4, 5), timedelta(days=365, seconds=81000), DT(2024, 1, 2, 3, 5, 5),
       DT(2024, 1, 2, 3, 4, 4, 999999)])
check("datetime compare", [dt < DT(2024, 1, 2, 3, 4, 6), dt == DT(2024, 1, 2, 3, 4, 5), dt == date(2024, 1, 2),
                           DT(2024, 1, 1, 12, tzinfo=timezone.utc) == DT(2024, 1, 1, 14, tzinfo=timezone(timedelta(hours=2))),
                           DT(2024, 1, 1) == DT(2024, 1, 1, tzinfo=timezone.utc)], [True, True, False, True, False])
check("datetime naive vs aware", [err(lambda: DT(2024, 1, 1) < DT(2024, 1, 1, tzinfo=timezone.utc)),
                                  err(lambda: DT(2024, 1, 1) - DT(2024, 1, 1, tzinfo=timezone.utc))],
      ["TypeError: can't compare offset-naive and offset-aware datetimes", "TypeError: can't subtract offset-naive and offset-aware datetimes"])
check("datetime vs date", err(lambda: date(2024, 1, 1) < DT(2024, 1, 1)), "TypeError: can't compare datetime.datetime to datetime.date")
check("datetime parts", [dt.date(), dt.time(), dt.timetz(), DT(2024, 1, 2, 3, tzinfo=timezone.utc).timetz()],
      [date(2024, 1, 2), datetime.time(3, 4, 5), datetime.time(3, 4, 5), datetime.time(3, tzinfo=timezone.utc)])
check("datetime isinstance", [isinstance(dt, date), isinstance(dt, DT), isinstance(d, DT)], [True, True, False])
check("datetime combine", [DT.combine(date(2024, 5, 6), datetime.time(7, 8)), DT.combine(date(2024, 5, 6), datetime.time(7, tzinfo=timezone.utc)).tzinfo == timezone.utc],
      [DT(2024, 5, 6, 7, 8), True])
check("datetime replace", [dt.replace(year=2000), dt.replace(tzinfo=timezone.utc).utcoffset(), dt.replace(tzinfo=timezone.utc).replace(tzinfo=None).tzinfo],
      [DT(2000, 1, 2, 3, 4, 5), timedelta(0), None])
check("datetime fromisoformat", [DT.fromisoformat("2024-01-02T03:04:05.123+05:30"), DT.fromisoformat("20240102T030405Z"),
                                 DT.fromisoformat("2024-W01-2T03"), DT.fromisoformat("2024-01-01 10:00:00.1234567"),
                                 DT.fromisoformat("2024-01-01T10:00:00+0530"), DT.fromisoformat("2024-01-01T10:00:00-00:00"),
                                 DT.fromisoformat("2024-01-01"), DT.fromisoformat("2024-01-01T10:00:00,5")],
      [DT(2024, 1, 2, 3, 4, 5, 123000, tzinfo=timezone(timedelta(hours=5, minutes=30))), DT(2024, 1, 2, 3, 4, 5, tzinfo=timezone.utc),
       DT(2024, 1, 2, 3), DT(2024, 1, 1, 10, 0, 0, 123456), DT(2024, 1, 1, 10, tzinfo=timezone(timedelta(hours=5, minutes=30))),
       DT(2024, 1, 1, 10, tzinfo=timezone.utc), DT(2024, 1, 1), DT(2024, 1, 1, 10, 0, 0, 500000)])
check("datetime fromisoformat repr", repr(DT.fromisoformat("2024-01-02T03:04:05.123+05:30")),
      "datetime.datetime(2024, 1, 2, 3, 4, 5, 123000, tzinfo=datetime.timezone(datetime.timedelta(seconds=19800)))")
check("datetime fromisoformat errors", [err(lambda: DT.fromisoformat("2024-01-01T10:0")), err(lambda: DT.fromisoformat("2024-01-01T25:00")),
                                        err(lambda: DT.fromisoformat("x"))],
      ["ValueError: Invalid isoformat string: '2024-01-01T10:0'", "ValueError: hour must be in 0..23", "ValueError: Invalid isoformat string: 'x'"])
check("datetime isoformat roundtrip", DT.fromisoformat(DT(2024, 2, 29, 23, 59, 59, 999999, tzinfo=timezone(-timedelta(hours=3, minutes=30))).isoformat()),
      DT(2024, 2, 29, 23, 59, 59, 999999, tzinfo=timezone(-timedelta(hours=3, minutes=30))))
utc_dt = DT(2024, 3, 4, 5, tzinfo=timezone.utc)
check("datetime timestamp", [utc_dt.timestamp(), DT(1970, 1, 1, tzinfo=timezone.utc).timestamp(), DT(1969, 12, 31, 23, 59, 59, 500000, tzinfo=timezone.utc).timestamp()],
      [1709528400.0, 0.0, -0.5])
check("datetime fromtimestamp utc", [DT.fromtimestamp(86400 * 365.25, timezone.utc), DT.fromtimestamp(1.9999996, timezone.utc), DT.fromtimestamp(-1.5, timezone.utc)],
      [DT(1971, 1, 1, 6, 0, tzinfo=timezone.utc), DT(1970, 1, 1, 0, 0, 2, tzinfo=timezone.utc), DT(1969, 12, 31, 23, 59, 58, 500000, tzinfo=timezone.utc)])
check("datetime utcfromtimestamp", DT.utcfromtimestamp(1709528400), DT(2024, 3, 4, 5))
check("datetime local roundtrip", [DT.fromtimestamp(1709528400.25).timestamp(), DT.fromtimestamp(0).timestamp()], [1709528400.25, 0.0])
check("datetime astimezone", [utc_dt.astimezone(timezone(timedelta(hours=9))), utc_dt.astimezone(timezone(timedelta(hours=9))).hour,
                              DT(2024, 3, 4, 14, tzinfo=timezone(timedelta(hours=9))).astimezone(timezone.utc) == utc_dt],
      [DT(2024, 3, 4, 14, 0, tzinfo=timezone(timedelta(hours=9))), 14, True])
check("datetime astimezone local", utc_dt.astimezone().timestamp(), 1709528400.0)
check("datetime now", [isinstance(DT.now(), DT), DT.now(timezone.utc).tzinfo == timezone.utc, DT.utcnow().tzinfo, DT.today().year >= 2024], [True, True, None, True])
check("datetime timetuple", [tuple(dt.timetuple()), tuple(DT(2024, 1, 2, 3, tzinfo=timezone(timedelta(hours=1))).utctimetuple())],
      [(2024, 1, 2, 3, 4, 5, 1, 2, -1), (2024, 1, 2, 2, 0, 0, 1, 2, 0)])
check("datetime strftime", [DT(2024, 1, 1, 13, 5, 9, tzinfo=timezone(timedelta(hours=1))).strftime("%z|%Z|%H:%M:%S.%f"),
                            dt.strftime("%Y-%m-%dT%H:%M:%S %I%p %%f %d"), DT(1, 1, 1).strftime("%Y-%m-%d")],
      ["+0100|UTC+01:00|13:05:09.000000", "2024-01-02T03:04:05 03AM %f 02", "1-01-01"])
check("datetime format", ["{:%Y-%m-%d %H}".format(DT(2024, 3, 4, 5)), f"{dt:%H:%M}", "{}".format(dt)], ["2024-03-04 05", "03:04", "2024-01-02 03:04:05"])
check("datetime min/max", [repr(DT.min), repr(DT.max)], ["datetime.datetime(1, 1, 1, 0, 0)", "datetime.datetime(9999, 12, 31, 23, 59, 59, 999999)"])
check("datetime errors", [err(lambda: DT(2024, 1, 1, 0, 60)), err(lambda: DT(2024, 1, 1, tzinfo=5)), err(lambda: DT(9999, 12, 31) + timedelta(1)),
                          err(lambda: dt.replace(month=13))],
      ["ValueError: minute must be in 0..59", "TypeError: tzinfo argument must be None or of a tzinfo subclass, not type 'int'",
       "OverflowError: date value out of range", "ValueError: month must be in 1..12"])
check("strptime", [DT.strptime("2024-03-04 05:06:07.89 +0100", "%Y-%m-%d %H:%M:%S.%f %z"), DT.strptime("Mon Mar  4 05:06:07 2024", "%a %b %d %H:%M:%S %Y"),
                   DT.strptime("03/04/24 11PM", "%m/%d/%y %I%p"), DT.strptime("2024 064", "%Y %j"), DT.strptime("March 4 2024 UTC", "%B %d %Y %Z"),
                   DT.strptime("100%", "%j%%"), DT.strptime("20240304", "%Y%m%d"), DT.strptime("12:30 am", "%I:%M %p")],
      [DT(2024, 3, 4, 5, 6, 7, 890000, tzinfo=timezone(timedelta(hours=1))), DT(2024, 3, 4, 5, 6, 7), DT(2024, 3, 4, 23, 0),
       DT(2024, 3, 4), DT(2024, 3, 4), DT(1900, 4, 10), DT(2024, 3, 4), DT(1900, 1, 1, 0, 30)])
check("strptime z forms", [DT.strptime("+05:30", "%z").utcoffset(), DT.strptime("-0100", "%z").utcoffset(), DT.strptime("Z", "%z").tzinfo == timezone.utc,
                           DT.strptime("+01:02:03.5", "%z").utcoffset()],
      [timedelta(hours=5, minutes=30), timedelta(hours=-1), True, timedelta(seconds=3723, microseconds=500000)])
check("strptime errors", [err(lambda: DT.strptime("2024", "%Y-%m")), err(lambda: DT.strptime("2024-01-01x", "%Y-%m-%d")),
                          err(lambda: DT.strptime("2024", "%Q")), err(lambda: DT.strptime("2023-02-30", "%Y-%m-%d"))],
      ["ValueError: time data '2024' does not match format '%Y-%m'", "ValueError: unconverted data remains: x",
       "ValueError: 'Q' is a bad directive in format '%Q'", "ValueError: day is out of range for month"])
check("strptime week", [DT.strptime("2024 1 1", "%Y %W %w"), DT.strptime("2024 0 0", "%Y %U %w"), DT.strptime("2024-W01-1", "%G-W%V-%u")],
      [DT(2024, 1, 1), DT(2023, 12, 31), DT(2024, 1, 1)])

# ── datetime: timezone, tzinfo, keys ─────────────────────────────────────────
check("timezone repr", [repr(timezone.utc), repr(timezone(timedelta(hours=5, minutes=30))), repr(timezone(timedelta(hours=-3), "X")),
                        repr(timezone(timedelta(0)))],
      ["datetime.timezone.utc", "datetime.timezone(datetime.timedelta(seconds=19800))",
       "datetime.timezone(datetime.timedelta(days=-1, seconds=75600), 'X')", "datetime.timezone.utc"])
check("timezone str", [str(timezone(timedelta(hours=5, minutes=30))), str(timezone.utc), str(timezone(timedelta(seconds=-1))),
                       timezone(timedelta(hours=-3), "X").tzname(None), str(timezone(timedelta(hours=1, microseconds=1)))],
      ["UTC+05:30", "UTC", "UTC-00:00:01", "X", "UTC+01:00:00.000001"])
check("timezone min/max", [repr(timezone.min), repr(timezone.max)],
      ["datetime.timezone(datetime.timedelta(days=-1, seconds=60))", "datetime.timezone(datetime.timedelta(seconds=86340))"])
check("timezone eq", [timezone(timedelta(hours=1)) == timezone(timedelta(hours=1), "A"), datetime.UTC == timezone.utc], [True, True])
check("timezone errors", [err(lambda: timezone(5)), err(lambda: timezone(timedelta(0), 5)), err(lambda: timezone(timedelta(hours=24)))],
      ["TypeError: timezone() argument 1 must be datetime.timedelta, not int", "TypeError: timezone() argument 2 must be str, not int",
       "ValueError: offset must be a timedelta strictly between -timedelta(hours=24) and timedelta(hours=24), not datetime.timedelta(days=1)."])


class Fixed5(datetime.tzinfo):
    def utcoffset(self, dt):
        return timedelta(hours=5)

    def dst(self, dt):
        return timedelta(0)

    def tzname(self, dt):
        return "F5"


f5 = Fixed5()
check("tzinfo subclass", [DT(2024, 1, 1, 12, tzinfo=f5).utcoffset(), DT(2024, 1, 1, 12, tzinfo=f5).tzname(),
                          DT(2024, 1, 1, 12, tzinfo=f5).astimezone(timezone.utc), utc_dt.astimezone(f5).hour,
                          DT(2024, 1, 1, 12, tzinfo=f5).strftime("%Z %z")],
      [timedelta(hours=5), "F5", DT(2024, 1, 1, 7, tzinfo=timezone.utc), 10, "F5 +0500"])
check("tzinfo abstract", errtype(lambda: DT(2024, 1, 1, tzinfo=datetime.tzinfo()).utcoffset()), "NotImplementedError")
check("constants", [datetime.MINYEAR, datetime.MAXYEAR], [1, 9999])
days = {}
days[date(2024, 1, 1)] = "new year"
days[date(2024, 1, 1)] = "again"
days[DT(2024, 1, 1)] = "midnight"
check("dates as dict keys", [len(days), days[date(2024, 1, 1)], days.get(DT(2024, 1, 1)), date(2024, 1, 1) in days], [2, "again", "midnight", True])
check("dates in sets", len({date(2024, 1, 1), date(2024, 1, 1), date(2024, 1, 2)}), 2)
check("timedelta keys", {timedelta(hours=24): 1}[timedelta(days=1)], 1)
check("aware keys", {DT(2024, 1, 1, 12, tzinfo=timezone.utc): 1}.get(DT(2024, 1, 1, 14, tzinfo=timezone(timedelta(hours=2)))), 1)


class MyDate(date):
    def tomorrow(self):
        return self + timedelta(1)


md = MyDate(2024, 2, 28)
check("date subclass", [str(md.tomorrow()), type(md.tomorrow()).__name__, md.replace(day=1).tomorrow() == date(2024, 2, 2),
                        repr(md), isinstance(md, date)],
      ["2024-02-29", "MyDate", True, "MyDate(2024, 2, 28)", True])

# ── time ─────────────────────────────────────────────────────────────────────
g = time.gmtime(0)
check("gmtime", [repr(g), g.tm_year, g[0], g[-1], len(g), list(g[:3]), g.tm_zone, g.tm_gmtoff],
      ["time.struct_time(tm_year=1970, tm_mon=1, tm_mday=1, tm_hour=0, tm_min=0, tm_sec=0, tm_wday=3, tm_yday=1, tm_isdst=0)",
       1970, 1970, 0, 9, [1970, 1, 1], "GMT", 0])
check("gmtime unpack", tuple(time.gmtime(1709528400.9)), (2024, 3, 4, 5, 0, 0, 0, 64, 0))
check("struct_time eq tuple", time.gmtime(0) == (1970, 1, 1, 0, 0, 0, 3, 1, 0), True)
check("struct_time make", repr(time.struct_time((2024, 1, 2, 3, 4, 5, 1, 2, 0))),
      "time.struct_time(tm_year=2024, tm_mon=1, tm_mday=2, tm_hour=3, tm_min=4, tm_sec=5, tm_wday=1, tm_yday=2, tm_isdst=0)")
check("strftime", [time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(1709528400)), time.strftime("%a %A %b %B %j %p %y %%", (2024, 3, 4, 15, 0, 0, 0, 64, 0)),
                   time.strftime("%c|%x|%X", (2024, 1, 5, 3, 4, 5, 4, 5, 0))],
      ["2024-03-04 05:00:00", "Mon Monday Mar March 064 PM 24 %", "Fri Jan  5 03:04:05 2024|01/05/24|03:04:05"])
check("strftime errors", [err(lambda: time.strftime("%Y", (2024, 13, 1, 0, 0, 0, 0, 1, 0))), errtype(lambda: time.strftime("%Y", (1, 2)))],
      ["ValueError: month out of range", "TypeError"])
check("asctime", [time.asctime(time.gmtime(0)), time.asctime((2024, 1, 5, 3, 4, 5, 4, 5, 0))], ["Thu Jan  1 00:00:00 1970", "Fri Jan  5 03:04:05 2024"])
check("strptime", repr(time.strptime("2024-02-03", "%Y-%m-%d")),
      "time.struct_time(tm_year=2024, tm_mon=2, tm_mday=3, tm_hour=0, tm_min=0, tm_sec=0, tm_wday=5, tm_yday=34, tm_isdst=-1)")
check("strptime default format", tuple(time.strptime("Fri Jan  5 03:04:05 2024"))[:6], (2024, 1, 5, 3, 4, 5))
check("mktime/localtime", [time.mktime(time.localtime(1000000)), time.mktime(time.localtime(1709528400))], [1000000.0, 1709528400.0])
check("localtime fields", [time.localtime(0).tm_year in (1969, 1970), isinstance(time.localtime().tm_gmtoff, int)], [True, True])
check("zone values", [isinstance(time.timezone, int), isinstance(time.altzone, int), time.daylight in (0, 1), len(time.tzname)], [True, True, True, 2])
t0 = time.monotonic()
p0 = time.perf_counter()
time.sleep(0.02)
check("sleep/monotonic", [time.monotonic() - t0 >= 0.015, time.perf_counter() - p0 >= 0.015], [True, True])
check("clocks", [time.time() > 1.6e9, time.time_ns() > 1600000000000000000, isinstance(time.time_ns(), int),
                 time.monotonic_ns() > 0, time.process_time() >= 0, isinstance(time.perf_counter_ns(), int)], [True, True, True, True, True, True])
check("sleep negative", err(lambda: time.sleep(-1)), "ValueError: sleep length must be non-negative")
check("get_clock_info", time.get_clock_info("monotonic").monotonic, True)

# ── io ───────────────────────────────────────────────────────────────────────
s = StringIO("hello\nworld\n")
check("StringIO read", [s.readline(), s.read(3), s.tell(), s.read(), s.read()], ["hello\n", "wor", 9, "ld\n", ""])
s.seek(0)
check("StringIO readlines", [s.readlines(), s.seek(0), list(s), s.seek(0), s.readlines(7)], [["hello\n", "world\n"], 0, ["hello\n", "world\n"], 0, ["hello\n", "world\n"]])
w = StringIO()
print("a", 1, file=w)
print("b", end="", file=w)
w.write("xyz")
w.writelines(["1", "2"])
check("StringIO write", [w.getvalue(), w.tell()], ["a 1\nbxyz12", 10])
w.seek(1)
check("StringIO overwrite", [w.write("QQ"), w.getvalue(), w.tell()], [2, "aQQ\nbxyz12", 3])
check("StringIO truncate", [w.truncate(), w.getvalue(), w.truncate(1), w.getvalue(), w.tell()], [3, "aQQ", 1, "a", 3])
w.write("!")
check("StringIO write past end", w.getvalue(), "a\x00\x00!")
check("StringIO seek end", [w.seek(0, 2), w.seek(0, 1), w.seek(2)], [4, 4, 2])
check("StringIO seek errors", [err(lambda: w.seek(-1)), err(lambda: w.seek(1, 1)), err(lambda: w.seek(0, 3))],
      ["ValueError: Negative seek position -1", "OSError: Can't do nonzero cur-relative seeks", "ValueError: Invalid whence (3, should be 0, 1 or 2)"])
check("StringIO write type", err(lambda: w.write(5)), "TypeError: string argument expected, got 'int'")
check("StringIO readline limit", [StringIO("abc\ndef").readline(2), StringIO("abc").read(None), StringIO("").read()], ["ab", "abc", ""])
check("StringIO newline None", [StringIO("a\r\nb\rc\n", newline=None).getvalue(), StringIO("a\r\nb\rc\n", newline=None).readlines()],
      ["a\nb\nc\n", ["a\n", "b\n", "c\n"]])
check("StringIO newline empty", StringIO("a\r\nb\rc\n", newline="").readlines(), ["a\r\n", "b\r", "c\n"])
check("StringIO newline crlf", [StringIO("a\nb", newline="\r\n").getvalue(), StringIO("a\nb\n", newline="\r\n").readlines()], ["a\r\nb", ["a\r\n", "b\r\n"]])
check("StringIO default newline", StringIO("a\r\nb\rc\n").readlines(), ["a\r\n", "b\rc\n"])
check("StringIO bad newline", err(lambda: StringIO(newline="x")), "ValueError: illegal newline value: 'x'")
check("StringIO initial type", err(lambda: StringIO(5)), "TypeError: initial_value must be str or None, not int")
with StringIO("q") as cm:
    inside = [cm.read(), cm.closed]
check("StringIO with", [inside, cm.closed], [["q", False], True])
check("StringIO closed", [err(lambda: cm.read()), err(lambda: cm.getvalue())], ["ValueError: I/O operation on closed file", "ValueError: I/O operation on closed file"])
check("StringIO modes", [StringIO().readable(), StringIO().writable(), StringIO().seekable(), StringIO().isatty()], [True, True, True, False])
check("StringIO fileno", errtype(lambda: StringIO().fileno()), "UnsupportedOperation")
check("UnsupportedOperation bases", [issubclass(io.UnsupportedOperation, OSError), issubclass(io.UnsupportedOperation, ValueError)], [True, True])
many = StringIO()
for i in range(5000):
    many.write(str(i % 10))
check("StringIO many writes", [len(many.getvalue()), many.getvalue()[:12]], [5000, "012345678901"])
b = BytesIO(b"abc\ndef")
check("BytesIO read", [b.readline(), b.read(2), b.read(), b.tell(), b.read()], [b"abc\n", b"de", b"f", 7, b""])
b.seek(10)
b.write(b"x")
check("BytesIO write past end", b.getvalue(), b"abc\ndef\x00\x00\x00x")
b2 = BytesIO()
check("BytesIO write", [b2.write(b"hello"), b2.write(bytearray(b"!")), b2.getvalue(), b2.seek(1), b2.write(b"EL"), b2.getvalue()],
      [5, 1, b"hello!", 1, 2, b"hELlo!"])
check("BytesIO seek", [b2.seek(-2, 2), b2.read(), b2.seek(-100, 1), b2.tell()], [4, b"o!", 0, 0])
check("BytesIO errors", [err(lambda: BytesIO().write("x")), err(lambda: BytesIO(b"a").seek(-1)), err(lambda: BytesIO("x"))],
      ["TypeError: a bytes-like object is required, not 'str'", "ValueError: negative seek value -1", "TypeError: a bytes-like object is required, not 'str'"])
check("BytesIO lines", [BytesIO(b"ab\ncd").readlines(), list(BytesIO(b"x\ny")), BytesIO(b"ab").read1()], [[b"ab\n", b"cd"], [b"x\n", b"y"], b"ab"])
check("BytesIO truncate", [b2.truncate(3), b2.getvalue()], [3, b"hEL"])
ba = bytearray(3)
check("BytesIO readinto", [BytesIO(b"xyz!").readinto(ba), ba], [3, bytearray(b"xyz")])
tw = io.TextIOWrapper(BytesIO("héllo\nx".encode("utf-8")), encoding="utf-8")
check("TextIOWrapper", [tw.readline(), tw.read()], ["héllo\n", "x"])
raw = BytesIO()
tw2 = io.TextIOWrapper(raw, encoding="utf-8")
tw2.write("é\n")
tw2.flush()
check("TextIOWrapper write", raw.getvalue(), b"\xc3\xa9\n")
check("io constants", [io.SEEK_SET, io.SEEK_CUR, io.SEEK_END, io.DEFAULT_BUFFER_SIZE], [0, 1, 2, 8192])
check("io.open is open", io.open == open, True)


class Upper(io.TextIOBase):
    def __init__(self):
        self.parts = []

    def write(self, s):
        self.parts.append(s.upper())
        return len(s)


up = Upper()
print("shout", file=up)
check("TextIOBase subclass", ["".join(up.parts), up.writable(), errtype(lambda: up.read())], ["SHOUT\n", False, "UnsupportedOperation"])

# ── engine fixes ─────────────────────────────────────────────────────────────
check("float literal underflow", [5e-324, 2.5e-320 > 0, 1e400, -1e400], [5e-324, True, float("inf"), float("-inf")])


class Fmt:
    def __format__(self, spec):
        return "<" + spec + ">"


check("str.format calls __format__", ["{:abc}".format(Fmt()), "{0:x} {0}".format(Fmt()), "{:{w}}".format(Fmt(), w="7")], ["<abc>", "<x> <>", "<7>"])


class DM:
    def __divmod__(self, o):
        return ("dm", o)

    def __rdivmod__(self, o):
        return ("rdm", o)


check("divmod dunders", [divmod(DM(), 3), divmod(4, DM())], [("dm", 3), ("rdm", 4)])


class Key:
    def __init__(self, k):
        self.k = k

    def __eq__(self, o):
        return isinstance(o, Key) and self.k == o.k

    def __hash__(self):
        return hash(self.k)


kd = {Key(1): "one"}
kd[Key(1)] = "uno"
check("__hash__ dict keys", [len(kd), kd[Key(1)], Key(2) in kd, kd.get(Key(1))], [1, "uno", False, "uno"])


def uses_math_alias():
    import math as m
    return m.floor(2.5)


check("import math as m", uses_math_alias(), 2)

for res in results:
    if res[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + res[0] + ": got " + repr(res[2]) + " want " + repr(res[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT77 PASSED ===")
