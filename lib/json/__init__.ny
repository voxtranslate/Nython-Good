# nython: module    (a package: json.decoder, json.encoder)
# lib/json - Python's json module (CPython 3.12's Lib/json).
#
#     import json
#     json.dumps({"a": [1, 2.5, None]}, indent=2, sort_keys=True)
#     json.loads('{"a": 1}'); json.load(fp); json.dump(obj, fp)
#
# dumps/dump    skipkeys, ensure_ascii (\uXXXX, surrogate pairs), check_circular
#               ("Circular reference detected"), allow_nan (NaN/Infinity or
#               ValueError), cls, indent (int or str), separators, default,
#               sort_keys; floats as repr() (1e+16, 1e-07, 3.0); tuples as
#               arrays; int/float/bool/None keys as strings
# loads/load    str, bytes or bytearray (utf-8/16/32 detected as Python does);
#               cls, object_hook, object_pairs_hook (every pair, duplicates
#               included), parse_float, parse_int, parse_constant, strict
# JSONDecodeError  a ValueError with msg, doc, pos, lineno, colno and Python's
#               message ("Expecting value: line 1 column 1 (char 0)")
# JSONEncoder / JSONDecoder  encode, iterencode, default / decode, raw_decode
#
# Speed: documents are scanned and written by natives (builtins/pyjson.cpp)
# that follow CPython's C accelerator (_json.c) character for character -
# its messages, error positions and number grammar. The encoder hands back to
# the Nython port of Lib/json/encoder.py's _make_iterencode only for values
# that need it (default=, sets, objects, mixed sort keys), so output is the
# same either way; a megabyte document takes a fraction of a second on either
# engine. With hooks the native scanner hands back a raw tree (pairs and
# number texts) and the hooks are applied here in Python's order.
#
# Differences from Python: a dict cannot remember that a key was True or 1.0
# (Nython stores 1, 1.0 and True as one key, as a dict does in Python too,
# but reads it back as 1), so {True: 1} encodes as {"1": 1}, not {"true": 1};
# dump() writes the document with one fp.write() rather than chunk by chunk;
# when a document is invalid, hooks have not run on its earlier parts.

from json.decoder import JSONDecoder, JSONDecodeError, scanstring
from json.encoder import JSONEncoder, encode_basestring, encode_basestring_ascii
import json.decoder
import json.encoder

__version__ = "2.0.9"
__all__ = ["dump", "dumps", "load", "loads", "JSONDecoder", "JSONDecodeError", "JSONEncoder"]

_default_encoder = JSONEncoder()
_default_decoder = JSONDecoder()


def dump(obj, fp, *, skipkeys=false, ensure_ascii=true, check_circular=true,
         allow_nan=true, cls=none, indent=none, separators=none,
         default=none, sort_keys=false, **kw):
    """Serialize ``obj`` as a JSON formatted stream to ``fp`` (a
    ``.write()``-supporting file-like object)."""
    fp.write(dumps(obj, skipkeys=skipkeys, ensure_ascii=ensure_ascii,
                   check_circular=check_circular, allow_nan=allow_nan, cls=cls,
                   indent=indent, separators=separators, default=default,
                   sort_keys=sort_keys, **kw))
    return none


def dumps(obj, *, skipkeys=false, ensure_ascii=true, check_circular=true,
          allow_nan=true, cls=none, indent=none, separators=none,
          default=none, sort_keys=false, **kw):
    """Serialize ``obj`` to a JSON formatted ``str``."""
    if (not skipkeys and ensure_ascii and check_circular and allow_nan and
            cls is none and indent is none and separators is none and
            default is none and not sort_keys and len(kw) == 0):
        return _default_encoder.encode(obj)
    if cls is none:
        cls = JSONEncoder
    return cls(skipkeys=skipkeys, ensure_ascii=ensure_ascii,
               check_circular=check_circular, allow_nan=allow_nan, indent=indent,
               separators=separators, default=default, sort_keys=sort_keys,
               **kw).encode(obj)


def detect_encoding(b):
    """The encoding of a JSON document given as bytes (RFC 4627 / 8259)."""
    if b.startswith(b"\x00\x00\xfe\xff") or b.startswith(b"\xff\xfe\x00\x00"):
        return "utf-32"
    if b.startswith(b"\xfe\xff") or b.startswith(b"\xff\xfe"):
        return "utf-16"
    if b.startswith(b"\xef\xbb\xbf"):
        return "utf-8-sig"
    if len(b) >= 4:
        if not b[0]:
            return "utf-16-be" if b[1] else "utf-32-be"
        if not b[1]:
            return "utf-16-le" if b[2] or b[3] else "utf-32-le"
    elif len(b) == 2:
        if not b[0]:
            return "utf-16-be"
        if not b[1]:
            return "utf-16-le"
    return "utf-8"


def _decode_bytes(b):
    var enc = detect_encoding(b)
    var data = bytes(b)
    if enc == "utf-8-sig":
        data = data[3:]
        enc = "utf-8"
    try:
        return data.decode(enc, "surrogatepass")
    except LookupError:
        # no surrogatepass handler: strict decoding
        return data.decode(enc)


def load(fp, *, cls=none, object_hook=none, parse_float=none,
         parse_int=none, parse_constant=none, object_pairs_hook=none, **kw):
    """Deserialize ``fp`` (a ``.read()``-supporting file-like object containing
    a JSON document) to a Python object."""
    return loads(fp.read(), cls=cls, object_hook=object_hook,
                 parse_float=parse_float, parse_int=parse_int,
                 parse_constant=parse_constant, object_pairs_hook=object_pairs_hook, **kw)


def loads(s, *, cls=none, object_hook=none, parse_float=none,
          parse_int=none, parse_constant=none, object_pairs_hook=none, **kw):
    """Deserialize ``s`` (a ``str``, ``bytes`` or ``bytearray`` instance
    containing a JSON document) to a Python object."""
    if isinstance(s, str):
        if s.startswith("﻿"):
            raise JSONDecodeError("Unexpected UTF-8 BOM (decode using utf-8-sig)", s, 0)
    else:
        if not (isinstance(s, bytes) or isinstance(s, bytearray)):
            raise TypeError("the JSON object must be str, bytes or bytearray, not " + type(s).__name__)
        s = _decode_bytes(s)
    if (cls is none and object_hook is none and
            parse_int is none and parse_float is none and
            parse_constant is none and object_pairs_hook is none and len(kw) == 0):
        return _default_decoder.decode(s)
    if cls is none:
        cls = JSONDecoder
    if object_hook is not none:
        kw["object_hook"] = object_hook
    if object_pairs_hook is not none:
        kw["object_pairs_hook"] = object_pairs_hook
    if parse_float is not none:
        kw["parse_float"] = parse_float
    if parse_int is not none:
        kw["parse_int"] = parse_int
    if parse_constant is not none:
        kw["parse_constant"] = parse_constant
    return cls(**kw).decode(s)
