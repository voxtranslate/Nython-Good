# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/xml/parsers/expat.ny - Python's xml.parsers.expat (pyexpat) interface
# over an XML 1.0 parser written in Nython (CPython wraps the C library
# expat; Nython has no C library for it, so this is a parser of its own that
# follows expat's behaviour: the same callbacks in the same order, the same
# error codes, messages and positions for the common errors).
#
#     from xml.parsers import expat
#     p = expat.ParserCreate()
#     p.StartElementHandler = lambda name, attrs: print("start", name, attrs)
#     p.CharacterDataHandler = lambda data: print("data", repr(data))
#     p.Parse("<a x='1'>hi &amp; bye</a>", True)
#
# ParserCreate(encoding=None, namespace_separator=None) -> xmlparser with
#   Parse(data, isfinal=False) - str or bytes, fed in any pieces (the
#     callbacks for what is complete run as each piece arrives) - ParseFile,
#   the handlers StartElementHandler, EndElementHandler,
#     CharacterDataHandler, ProcessingInstructionHandler, CommentHandler,
#     StartCdataSectionHandler, EndCdataSectionHandler,
#     StartNamespaceDeclHandler, EndNamespaceDeclHandler, XmlDeclHandler,
#     StartDoctypeDeclHandler, EndDoctypeDeclHandler, EntityDeclHandler,
#     AttlistDeclHandler, ElementDeclHandler, NotationDeclHandler,
#     UnparsedEntityDeclHandler, SkippedEntityHandler, DefaultHandler,
#     DefaultHandlerExpand (what no other handler takes: the XML and
#     DOCTYPE declarations' pieces, prolog whitespace, references to entities
#     a DTD may define elsewhere),
#   buffer_text, buffer_size, ordered_attributes, specified_attributes,
#   namespace_prefixes, ErrorCode / ErrorLineNumber / ErrorColumnNumber /
#   ErrorByteIndex, CurrentLineNumber / CurrentColumnNumber /
#   CurrentByteIndex, SetBase / GetBase;
# error / ExpatError (code, lineno, offset; "mismatched tag: line 1, column
# 8"), ErrorString(code), errors (messages, codes, XML_ERROR_* names),
# EXPAT_VERSION, version_info, native_encoding.
#
# The parser: elements, attributes (normalized, defaults from the DTD's
# ATTLIST declarations), character and entity references (the five
# predefined entities, the internal entities a DOCTYPE's internal subset
# declares - their text parsed as content, recursion and "billion laughs"
# expansion refused - and numeric references), CDATA sections, comments,
# processing instructions, the XML declaration (its encoding decodes bytes:
# UTF-8, UTF-16 with a BOM, ISO-8859-1, US-ASCII), DOCTYPE declarations with
# an internal subset, namespaces (with a separator: "uri}local" names,
# xmlns attributes consumed, the xml prefix bound, unbound prefixes refused),
# line ends normalized, and the well-formedness checks expat makes.
#
# Not here: DTD validation (expat does not validate either), external
# entities and parameter entities (a reference to an entity the DTD may
# declare externally goes to SkippedEntityHandler / the default handler, as
# with expat when it is told not to read external entities, its default),
# ExternalEntityParserCreate, UseForeignDTD, SetParamEntityParsing (accepted,
# no effect), encodings other than the four above, and positions as byte
# indexes counted in the source encoding (CurrentByteIndex counts characters).

import re as _re

EXPAT_VERSION = "expat_2.5.0"
version_info = (2, 5, 0)
native_encoding = "UTF-8"
features = [("sizeof(XML_Char)", 1), ("sizeof(XML_LChar)", 1), ("XML_DTD", 0), ("XML_CONTEXT_BYTES", 1024), ("XML_NS", 0)]

XML_PARAM_ENTITY_PARSING_NEVER = 0
XML_PARAM_ENTITY_PARSING_UNLESS_STANDALONE = 1
XML_PARAM_ENTITY_PARSING_ALWAYS = 2

_MESSAGES = [
    None,
    "out of memory",
    "syntax error",
    "no element found",
    "not well-formed (invalid token)",
    "unclosed token",
    "partial character",
    "mismatched tag",
    "duplicate attribute",
    "junk after document element",
    "illegal parameter entity reference",
    "undefined entity",
    "recursive entity reference",
    "asynchronous entity",
    "reference to invalid character number",
    "reference to binary entity",
    "reference to external entity in attribute",
    "XML or text declaration not at start of entity",
    "unknown encoding",
    "encoding specified in XML declaration is incorrect",
    "unclosed CDATA section",
    "error in processing external entity reference",
    "document is not standalone",
    "unexpected parser state - please send a bug report",
    "entity declared in parameter entity",
    "requested feature requires XML_DTD support in Expat",
    "cannot change setting once parsing has begun",
    "unbound prefix",
    "must not undeclare prefix",
    "incomplete markup in parameter entity",
    "XML declaration not well-formed",
    "text declaration not well-formed",
    "illegal character(s) in public id",
    "parser suspended",
    "parser not suspended",
    "parsing aborted",
    "parsing finished",
    "cannot suspend in external parameter entity",
    "reserved prefix (xml) must not be undeclared or bound to another namespace name",
    "reserved prefix (xmlns) must not be declared or undeclared",
    "prefix must not be bound to one of the reserved namespace names",
    "invalid argument",
    "a successful prior call to function XML_GetBuffer is required",
    "limit on input amplification factor (from DTD and entities) breached",
]

_NAMES = ["XML_ERROR_NONE", "XML_ERROR_NO_MEMORY", "XML_ERROR_SYNTAX", "XML_ERROR_NO_ELEMENTS",
          "XML_ERROR_INVALID_TOKEN", "XML_ERROR_UNCLOSED_TOKEN", "XML_ERROR_PARTIAL_CHAR",
          "XML_ERROR_TAG_MISMATCH", "XML_ERROR_DUPLICATE_ATTRIBUTE", "XML_ERROR_JUNK_AFTER_DOC_ELEMENT",
          "XML_ERROR_PARAM_ENTITY_REF", "XML_ERROR_UNDEFINED_ENTITY", "XML_ERROR_RECURSIVE_ENTITY_REF",
          "XML_ERROR_ASYNC_ENTITY", "XML_ERROR_BAD_CHAR_REF", "XML_ERROR_BINARY_ENTITY_REF",
          "XML_ERROR_ATTRIBUTE_EXTERNAL_ENTITY_REF", "XML_ERROR_MISPLACED_XML_PI", "XML_ERROR_UNKNOWN_ENCODING",
          "XML_ERROR_INCORRECT_ENCODING", "XML_ERROR_UNCLOSED_CDATA_SECTION", "XML_ERROR_EXTERNAL_ENTITY_HANDLING",
          "XML_ERROR_NOT_STANDALONE", "XML_ERROR_UNEXPECTED_STATE", "XML_ERROR_ENTITY_DECLARED_IN_PE",
          "XML_ERROR_FEATURE_REQUIRES_XML_DTD", "XML_ERROR_CANT_CHANGE_FEATURE_ONCE_PARSING",
          "XML_ERROR_UNBOUND_PREFIX", "XML_ERROR_UNDECLARING_PREFIX", "XML_ERROR_INCOMPLETE_PE",
          "XML_ERROR_XML_DECL", "XML_ERROR_TEXT_DECL", "XML_ERROR_PUBLICID", "XML_ERROR_SUSPENDED",
          "XML_ERROR_NOT_SUSPENDED", "XML_ERROR_ABORTED", "XML_ERROR_FINISHED", "XML_ERROR_SUSPEND_PE",
          "XML_ERROR_RESERVED_PREFIX_XML", "XML_ERROR_RESERVED_PREFIX_XMLNS", "XML_ERROR_RESERVED_NAMESPACE_URI",
          "XML_ERROR_INVALID_ARGUMENT", "XML_ERROR_NO_BUFFER", "XML_ERROR_AMPLIFICATION_LIMIT_BREACH"]


class errors:
    # xml.parsers.expat.errors: the XML_ERROR_* names hold the messages (as
    # in pyexpat); messages maps a code to its message, codes the reverse
    messages = {}
    codes = {}


class model:
    # xml.parsers.expat.model: content-model constants
    XML_CTYPE_EMPTY = 1
    XML_CTYPE_ANY = 2
    XML_CTYPE_MIXED = 3
    XML_CTYPE_NAME = 4
    XML_CTYPE_CHOICE = 5
    XML_CTYPE_SEQ = 6
    XML_CQUANT_NONE = 0
    XML_CQUANT_OPT = 1
    XML_CQUANT_REP = 2
    XML_CQUANT_PLUS = 3


for _i in range(1, len(_MESSAGES)):
    setattr(errors, _NAMES[_i], _MESSAGES[_i])
    errors.messages[_i] = _MESSAGES[_i]
    errors.codes[_MESSAGES[_i]] = _i


def ErrorString(code):
    if 0 < code < len(_MESSAGES):
        return _MESSAGES[code]
    return None


class ExpatError(Exception):
    pass


error = ExpatError

XMLParserType = None    # set below

# ── the parser ───────────────────────────────────────────────────────────────

_NS_XML = "http://www.w3.org/XML/1998/namespace"
_NS_XMLNS = "http://www.w3.org/2000/xmlns/"

_NSTART = "A-Za-z_:\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02FF\u0370-\u037D\u037F-\u1FFF\u200C-\u200D\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD\U00010000-\U000EFFFF"
_NCHAR = _NSTART + "\\-.0-9\u00B7\u0300-\u036F\u203F-\u2040"
_NAME_RE = _re.compile("[" + _NSTART + "][" + _NCHAR + "]*")
_NAMECHAR_RE = _re.compile("[" + _NCHAR + "]")
_WS_RE = _re.compile("[ \t\n]*")
_BAD_CHAR_RE = _re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]")
_CDATA_STOP_RE = _re.compile("[<&\\]]")
_XMLDECL_RE = _re.compile(
    "<\\?xml[ \t\n]+version[ \t\n]*=[ \t\n]*(\"[^\"]*\"|'[^']*')"
    "(?:[ \t\n]+encoding[ \t\n]*=[ \t\n]*(\"[A-Za-z][A-Za-z0-9._\\-]*\"|'[A-Za-z][A-Za-z0-9._\\-]*'))?"
    "(?:[ \t\n]+standalone[ \t\n]*=[ \t\n]*(\"(?:yes|no)\"|'(?:yes|no)'))?[ \t\n]*\\?>")
_PREDEF = {"lt": "<", "gt": ">", "amp": "&", "apos": "'", "quot": '"'}
_MAX_EXPANSIONS = 100000


class _Stop(Exception):
    # more data is needed to go on
    pass


class xmlparser:
    def __init__(self, encoding=None, namespace_separator=None):
        self._encoding = encoding
        self._sep = namespace_separator
        self.StartElementHandler = None
        self.EndElementHandler = None
        self.ProcessingInstructionHandler = None
        self.CharacterDataHandler = None
        self.UnparsedEntityDeclHandler = None
        self.EntityDeclHandler = None
        self.NotationDeclHandler = None
        self.StartNamespaceDeclHandler = None
        self.EndNamespaceDeclHandler = None
        self.CommentHandler = None
        self.StartCdataSectionHandler = None
        self.EndCdataSectionHandler = None
        self.DefaultHandler = None
        self.DefaultHandlerExpand = None
        self.NotStandaloneHandler = None
        self.ExternalEntityRefHandler = None
        self.StartDoctypeDeclHandler = None
        self.EndDoctypeDeclHandler = None
        self.ElementDeclHandler = None
        self.AttlistDeclHandler = None
        self.XmlDeclHandler = None
        self.SkippedEntityHandler = None
        self.buffer_text = False
        self.buffer_size = 8192
        self.ordered_attributes = False
        self.specified_attributes = False
        self.namespace_prefixes = False
        self.intern = {}
        self.ErrorCode = 0
        self.ErrorLineNumber = 1
        self.ErrorColumnNumber = 0
        self.ErrorByteIndex = -1
        self._base = None
        # input
        self._bytes = b""            # undecoded bytes (a partial character)
        self._decoder_enc = None
        self._buf = ""               # decoded, line ends normalized, not consumed yet
        self._cr = False             # the last piece ended with \r
        self._started = False
        self._finished = False
        # position of _buf[0] in the document
        self._line = 1
        self._col = 0
        self._index = 0
        # document state
        self._state = 0              # 0 prolog, 1 content, 2 epilog
        self._stack = []             # open elements: [raw name, ns prefixes declared, start index]
        self._ns = [{"xml": _NS_XML}]
        self._entities = {}          # internal general entities: name -> text
        self._ext_entities = set()   # declared external (or unparsed) entities
        self._attdefaults = {}       # element -> [(attr, default)]
        self._dtd_external = False   # a DOCTYPE with an external subset or PE references
        self._standalone = -1
        self._expansions = 0
        self._text = []              # buffered character data
        self._seen_decl_pos = False

    # ── public API ──────────────────────────────────────────────────────────
    def Parse(self, data, isfinal=False):
        if self._finished:
            self._fail(36, self._line, self._col)
        if isinstance(data, (bytes, bytearray)):
            self._feed_bytes(bytes(data), isfinal)
        elif isinstance(data, str):
            if not self._started and self._encoding is None:
                self._decoder_enc = "utf-8"     # a str: the encoding declaration is not used
            self._feed_text(data)
        else:
            raise TypeError("a bytes-like object is required, not '" + type(data).__name__ + "'")
        self._started = True
        self._run(isfinal)
        if isfinal:
            self._finished = True
        return 1

    def ParseFile(self, file):
        while True:
            var chunk = file.read(65536)
            if not chunk:
                break
            self.Parse(chunk, False)
        return self.Parse(b"" if not isinstance(chunk, str) else "", True)

    def SetBase(self, base):
        self._base = base

    def GetBase(self):
        return self._base

    def GetInputContext(self):
        return None

    def SetParamEntityParsing(self, flag):
        return 1

    def UseForeignDTD(self, flag=True):
        pass

    def ExternalEntityParserCreate(self, context, encoding=None):
        raise NotImplementedError("external entities are not supported (Nython's expat)")

    def GetReparseDeferralEnabled(self):
        return False

    def SetReparseDeferralEnabled(self, enabled):
        pass

    @property
    def CurrentLineNumber(self):
        return self._line

    @property
    def CurrentColumnNumber(self):
        return self._col

    @property
    def CurrentByteIndex(self):
        return self._index

    @property
    def buffer_used(self):
        var n = 0
        for t in self._text:
            n += len(t)
        return n

    # ── input ───────────────────────────────────────────────────────────────
    def _feed_bytes(self, data, isfinal):
        var b = self._bytes + data
        if self._decoder_enc is None:
            if not isfinal and len(b) < 4:
                self._bytes = b
                return
            self._decoder_enc = self._detect(b)
        var enc = self._decoder_enc
        var text = None
        var keep = 0
        while keep <= 4:
            try:
                text = b[:len(b) - keep].decode(enc)
                break
            except UnicodeDecodeError:
                if isfinal:
                    keep = 99
                    break
                keep += 1
        if text is None:
            self._fail(4, self._line, self._col)
        self._bytes = b[len(b) - keep:] if keep else b""
        self._feed_text(text)

    def _detect(self, b):
        if self._encoding is not None:
            return self._norm_enc(self._encoding)
        if b[:3] == b"\xef\xbb\xbf":
            return "utf-8-sig"
        if b[:2] == b"\xff\xfe" or b[:2] == b"\xfe\xff":
            return "utf-16"
        var m = _re.match(b"<\\?xml[^>]*encoding[ \t\r\n]*=[ \t\r\n]*[\"']([A-Za-z][A-Za-z0-9._\\-]*)[\"']", b)
        if m:
            return self._norm_enc(m.group(1).decode("ascii"))
        return "utf-8"

    def _norm_enc(self, name):
        var n = name.lower().replace("_", "-")
        if n in ("utf-8", "utf8"):
            return "utf-8"
        if n in ("iso-8859-1", "latin-1", "latin1", "iso8859-1", "l1"):
            return "latin-1"
        if n in ("us-ascii", "ascii"):
            return "ascii"
        if n in ("utf-16", "utf16", "utf-16le", "utf-16be"):
            return n
        self._fail(18, 1, 0)

    def _feed_text(self, text):
        if self._cr:
            text = "\r" + text
            self._cr = False
        if text.endswith("\r"):
            text = text[:-1]
            self._cr = True
        if "\r" in text:
            text = text.replace("\r\n", "\n").replace("\r", "\n")
        self._buf += text

    # ── positions and errors ────────────────────────────────────────────────
    def _advance(self, n):
        # consume n characters of the buffer, updating the position
        var s = self._buf[:n]
        var nl = s.count("\n")
        if nl:
            self._line += nl
            self._col = n - s.rfind("\n") - 1
        else:
            self._col += n
        self._index += n
        self._buf = self._buf[n:]

    def _pos_at(self, k):
        # the (line, column) of buffer index k
        var s = self._buf[:k]
        var nl = s.count("\n")
        if nl:
            return self._line + nl, k - s.rfind("\n") - 1
        return self._line, self._col + k

    def _fail(self, code, line, col):
        self._flush()
        self.ErrorCode = code
        self.ErrorLineNumber = line
        self.ErrorColumnNumber = col
        self.ErrorByteIndex = self._index
        var e = ExpatError("%s: line %d, column %d" % (_MESSAGES[code], line, col))
        e.code = code
        e.lineno = line
        e.offset = col
        raise e

    def _fail_at(self, code, k):
        var lc = self._pos_at(k)
        self._fail(code, lc[0], lc[1])

    # ── output helpers ──────────────────────────────────────────────────────
    def _flush(self):
        if self._text:
            var t = "".join(self._text)
            self._text = []
            var h = self.CharacterDataHandler
            if h is not None:
                h(t)
            else:
                self._default(t)

    def _chardata(self, t):
        if not t:
            return
        if self.CharacterDataHandler is None:
            self._flush()
            self._default(t)
        elif self.buffer_text:
            self._text.append(t)
            if self.buffer_used >= self.buffer_size:
                self._flush()
        else:
            self.CharacterDataHandler(t)

    def _default(self, t):
        var h = self.DefaultHandlerExpand
        if h is None:
            h = self.DefaultHandler
        if h is not None and t:
            h(t)

    # ── the tokenizer ───────────────────────────────────────────────────────
    def _run(self, final):
        try:
            while self._buf:
                if self._state == 1:
                    self._content(final)
                else:
                    self._misc(final)
        except _Stop:
            pass
        self._flush()
        if final:
            if self._buf:
                self._fail(5, self._line, self._col)
            if self._state != 2:
                self._fail(3, self._line, self._col)

    def _need(self, final, code, k=0):
        # the token at the start of the buffer is incomplete
        if final:
            self._fail_at(code, k)
        raise _Stop()

    def _misc(self, final):
        # prolog (state 0) or epilog (state 2): whitespace, comments, PIs,
        # the XML declaration, the DOCTYPE, the root element
        var buf = self._buf
        var m = _WS_RE.match(buf)
        var n = m.end()
        if n:
            if n == len(buf) and not final:
                # whitespace may continue
                pass
            self._flush()
            self._default(buf[:n])
            self._advance(n)
            return
        var c = buf[0]
        if c != "<":
            if self._state == 2:
                self._fail_at(9, 0)
            self._fail_at(2, 0)
        if len(buf) < 2:
            self._need(final, 5)
        var c2 = buf[1]
        if c2 == "?":
            self._pi(final)
        elif c2 == "!":
            if buf.startswith("<!--"):
                self._comment(final)
            elif buf.startswith("<!DOCTYPE"):
                if self._state != 0 or self._seen_doctype():
                    self._fail_at(2, 0)
                self._doctype(final)
            elif len(buf) < 9 and ("<!DOCTYPE".startswith(buf) or "<!--".startswith(buf)):
                self._need(final, 5)
            else:
                self._fail_at(2 if self._state == 0 else 9, 0)
        elif c2 == "/":
            self._fail_at(2 if self._state == 0 else 9, 0)
        else:
            if self._state == 2:
                self._fail_at(9, 0)
            self._start_tag(final)

    def _seen_doctype(self):
        return getattr(self, "_had_doctype", False)

    def _content(self, final):
        var buf = self._buf
        var c = buf[0]
        if c == "<":
            if len(buf) < 2:
                self._need(final, 5)
            var c2 = buf[1]
            if c2 == "/":
                self._end_tag(final)
            elif c2 == "?":
                self._pi(final)
            elif c2 == "!":
                if buf.startswith("<!--"):
                    self._comment(final)
                elif buf.startswith("<![CDATA["):
                    self._cdata(final)
                elif len(buf) < 9 and ("<![CDATA[".startswith(buf) or "<!--".startswith(buf)):
                    self._need(final, 5)
                else:
                    self._fail_at(4, 1 if len(buf) > 2 and buf[2] not in "-[" else 2)
            else:
                self._start_tag(final)
        elif c == "&":
            self._reference(final)
        else:
            var m = _CDATA_STOP_RE.search(buf)
            var stop = len(buf)
            while m is not None:
                if buf[m.start()] != "]":
                    stop = m.start()
                    break
                # "]]>" may not appear in character data
                var k = m.start()
                if buf.startswith("]]>", k):
                    self._chardata(buf[:k])
                    self._advance(k)
                    self._fail_at(4, 2)
                if k + 2 >= len(buf) and not final and buf[k:] in ("]", "]]"):
                    stop = k
                    break
                m = _CDATA_STOP_RE.search(buf, k + 1)
            if stop == 0:
                raise _Stop()
            var t = buf[:stop]
            var bad = _BAD_CHAR_RE.search(t)
            if bad is not None:
                self._chardata(t[:bad.start()])
                self._advance(bad.start())
                self._fail_at(4, 0)
            self._chardata(t)
            self._advance(stop)

    # comments, PIs, CDATA ─────────────────────────────────────────────────
    def _comment(self, final):
        var buf = self._buf
        var end = buf.find("--", 4)
        while True:
            if end < 0:
                self._need(final, 5)
            if buf.startswith("-->", end):
                break
            if end + 2 >= len(buf):
                self._need(final, 5)
            self._fail_at(4, end + 2)
        var text = buf[4:end]
        var bad = _BAD_CHAR_RE.search(text)
        if bad is not None:
            self._fail_at(4, 4 + bad.start())
        self._flush()
        if self.CommentHandler is not None:
            self.CommentHandler(text)
        else:
            self._default(buf[:end + 3])
        self._advance(end + 3)

    def _pi(self, final):
        var buf = self._buf
        var end = buf.find("?>", 2)
        if end < 0:
            self._need(final, 5)
        var m = _NAME_RE.match(buf, 2)
        if m is None:
            self._fail_at(4, 2)
        var target = m.group()
        var rest = buf[m.end():end]
        if target.lower() == "xml":
            if target == "xml" and self._index == 0 and self._state == 0 and not self._seen_decl_pos:
                self._xmldecl(buf[:end + 2])
                self._advance(end + 2)
                self._seen_decl_pos = True
                return
            self._fail_at(17, 0)
        if rest and rest[0] not in " \t\n":
            self._fail_at(4, m.end())
        var data = rest.lstrip(" \t\n")
        self._flush()
        if self.ProcessingInstructionHandler is not None:
            self.ProcessingInstructionHandler(target, data)
        else:
            self._default(buf[:end + 2])
        self._advance(end + 2)

    def _xmldecl(self, text):
        var m = _XMLDECL_RE.fullmatch(text)
        if m is None:
            self._fail_at(30, 0)
        var version = m.group(1)[1:-1]
        var enc = m.group(2)
        if enc is not None:
            enc = enc[1:-1]
        var sa = m.group(3)
        var standalone = -1
        if sa is not None:
            standalone = 1 if sa[1:-1] == "yes" else 0
        self._standalone = standalone
        if self.XmlDeclHandler is not None:
            self.XmlDeclHandler(version, enc, standalone)
        else:
            self._default(text)

    def _cdata(self, final):
        var buf = self._buf
        var end = buf.find("]]>", 9)
        if end < 0:
            if final:
                self._fail(20, *self._pos_at(len(buf)))
            raise _Stop()
        var text = buf[9:end]
        var bad = _BAD_CHAR_RE.search(text)
        if bad is not None:
            self._fail_at(4, 9 + bad.start())
        self._flush()
        if self.StartCdataSectionHandler is not None:
            self.StartCdataSectionHandler()
        if text:
            if self.CharacterDataHandler is not None:
                self.CharacterDataHandler(text)
            else:
                self._default(text)
        if self.EndCdataSectionHandler is not None:
            self.EndCdataSectionHandler()
        self._advance(end + 3)

    # references ───────────────────────────────────────────────────────────
    def _charref(self, body, k):
        # body: "#123" or "#x1F"; k: the buffer index of its '&'
        var num = -1
        try:
            if body[1:2] == "x":
                if _re.fullmatch("[0-9a-fA-F]+", body[2:]):
                    num = int(body[2:], 16)
            elif _re.fullmatch("[0-9]+", body[1:]):
                num = int(body[1:])
        except ValueError:
            num = -1
        if num < 0:
            self._fail_at(4, k + len(body) + 1)
        if num == 0 or num > 0x10FFFF or (0xD800 <= num <= 0xDFFF) or num in (0xFFFE, 0xFFFF) \
                or (num < 0x20 and num not in (9, 10, 13)):
            self._fail_at(14, k)
        return chr(num)

    def _ref_end(self, buf, k, final):
        # the ';' that ends the reference at buf[k] == '&'
        if k + 1 >= len(buf):
            if final:
                self._fail_at(5, k)
            return -1
        var j = k + 1
        if buf[j] == "#":
            var m = _re.compile("#(x[0-9a-fA-F]*|[0-9]*)").match(buf, j)
            j = m.end()
        else:
            var m = _NAME_RE.match(buf, j)
            if m is None:
                self._fail_at(4, j)
            j = m.end()
        if j >= len(buf):
            if final:
                self._fail_at(5, k)
            return -1
        if buf[j] != ";":
            self._fail_at(4, j)
        return j

    def _reference(self, final):
        var buf = self._buf
        var j = self._ref_end(buf, 0, final)
        if j < 0:
            raise _Stop()
        var body = buf[1:j]
        if body[0] == "#":
            self._chardata(self._charref(body, 0))
            self._advance(j + 1)
            return
        var t = _PREDEF.get(body)
        if t is not None:
            self._chardata(t)
            self._advance(j + 1)
            return
        var val = self._entities.get(body)
        if val is None:
            if body in self._ext_entities or (self._dtd_external and self._standalone != 1):
                self._flush()
                if self.SkippedEntityHandler is not None:
                    self.SkippedEntityHandler(body, 0)
                else:
                    self._default("&" + body + ";")
                self._advance(j + 1)
                return
            self._fail_at(11, 0)
        self._expansions += 1
        if self._expansions > _MAX_EXPANSIONS:
            self._fail_at(43, 0)
        if "<" not in val and "&" not in val:
            self._chardata(val)
            self._advance(j + 1)
            return
        # replacement text with markup or references: parsed as content
        # in place (the entity's depth guards against recursion)
        var depth = getattr(self, "_edepth", {})
        if depth.get(body, 0) > 0:
            self._fail_at(12, 0)
        self._advance(j + 1)
        var rest = self._buf
        var saved = (self._line, self._col, self._index)
        self._buf = val
        depth[body] = depth.get(body, 0) + 1
        self._edepth = depth
        var level = len(self._stack)
        try:
            while self._buf:
                self._content(True)
        except _Stop:
            self._fail(13, saved[0], saved[1])
        finally:
            depth[body] -= 1
        if len(self._stack) != level:
            self._fail(13, saved[0], saved[1])
        self._buf = rest
        self._line = saved[0]
        self._col = saved[1]
        self._index = saved[2]

    # attribute values ─────────────────────────────────────────────────────
    def _attvalue(self, raw, k, depth=0):
        # normalize an attribute value; k is the buffer index of raw[0]
        if "<" in raw:
            self._fail_at(4, k + raw.find("<"))
        var bad = _BAD_CHAR_RE.search(raw)
        if bad is not None:
            self._fail_at(4, k + bad.start())
        if "&" not in raw:
            return raw.replace("\t", " ").replace("\n", " ")
        var out = []
        var i = 0
        while i < len(raw):
            var a = raw.find("&", i)
            if a < 0:
                out.append(raw[i:].replace("\t", " ").replace("\n", " "))
                break
            out.append(raw[i:a].replace("\t", " ").replace("\n", " "))
            var e = raw.find(";", a)
            if e < 0:
                self._fail_at(4, k + len(raw))
            var body = raw[a + 1:e]
            if body[:1] == "#":
                out.append(self._charref(body, k + a))
            elif body in _PREDEF:
                out.append(_PREDEF[body])
            elif body in self._entities:
                if depth > 20:
                    self._fail_at(12, k + a)
                self._expansions += 1
                if self._expansions > _MAX_EXPANSIONS:
                    self._fail_at(43, k + a)
                out.append(self._attvalue(self._entities[body], k + a, depth + 1))
            elif body in self._ext_entities:
                self._fail_at(16, k + a)
            elif _NAME_RE.fullmatch(body) is None:
                self._fail_at(4, k + a + 1)
            else:
                self._fail_at(11, k + a)
            i = e + 1
        return "".join(out)

    # tags ─────────────────────────────────────────────────────────────────
    def _start_tag(self, final):
        var buf = self._buf
        var m = _NAME_RE.match(buf, 1)
        if m is None:
            if len(buf) < 2:
                self._need(final, 5)
            self._fail_at(4, 1)
        var name = m.group()
        var i = m.end()
        var attrs = []          # (name, value, buffer index)
        var n = len(buf)
        while True:
            var ws = _WS_RE.match(buf, i).end()
            if ws >= n:
                self._need(final, 5)
            var ch = buf[ws]
            if ch == ">" or ch == "/":
                if ch == "/":
                    if ws + 1 >= n:
                        self._need(final, 5)
                    if buf[ws + 1] != ">":
                        self._fail_at(4, ws + 1)
                    self._element(name, attrs, True, ws + 2)
                else:
                    self._element(name, attrs, False, ws + 1)
                return
            if ws == i:
                self._fail_at(4, i)
            var am = _NAME_RE.match(buf, ws)
            if am is None:
                self._fail_at(4, ws)
            var an = am.group()
            var j = _WS_RE.match(buf, am.end()).end()
            if j >= n:
                self._need(final, 5)
            if buf[j] != "=":
                self._fail_at(4, j)
            j = _WS_RE.match(buf, j + 1).end()
            if j >= n:
                self._need(final, 5)
            var q = buf[j]
            if q != '"' and q != "'":
                self._fail_at(4, j)
            var e = buf.find(q, j + 1)
            if e < 0:
                if not final:
                    raise _Stop()
                var lt = buf.find("<", j + 1)
                if lt >= 0:
                    self._fail_at(4, lt)
                self._fail_at(5, 0)
            for a in attrs:
                if a[0] == an:
                    self._fail_at(8, ws)
            attrs.append((an, buf[j + 1:e], j + 1, ws))
            i = e + 1

    def _qname(self, raw, k, is_attr):
        # the expanded name of raw (namespace processing), or raise
        var colon = raw.find(":")
        var prefix = None
        var local = raw
        if colon >= 0:
            prefix = raw[:colon]
            local = raw[colon + 1:]
            if not prefix or not local or ":" in local:
                return raw
        var uri = None
        if prefix is None:
            if is_attr:
                return raw
            uri = self._ns[-1].get("")
            if not uri:
                return raw
        else:
            uri = self._ns[-1].get(prefix)
            if uri is None:
                self._fail_at(27, 0)
        var out = uri + self._sep + local
        if self.namespace_prefixes and prefix is not None:
            out = out + self._sep + prefix
        return out

    def _element(self, name, attrs, empty, length):
        var buf = self._buf
        # defaults from the DTD
        var defs = self._attdefaults.get(name)
        if defs:
            var have = set(a[0] for a in attrs)
            var extra = []
            for d in defs:
                if d[0] not in have:
                    extra.append((d[0], d[1], -1, -1))
            if extra and not self.specified_attributes:
                attrs = attrs + extra
        var declared = []
        if self._sep is not None:
            var scope = None
            var plain = []
            for a in attrs:
                var an = a[0]
                if an == "xmlns" or an.startswith("xmlns:"):
                    var pfx = an[6:] if an != "xmlns" else ""
                    var uri = self._attvalue(a[1], a[2]) if a[2] >= 0 else a[1]
                    if pfx == "xmlns":
                        self._fail_at(39, a[3])
                    if pfx == "xml" and uri != _NS_XML:
                        self._fail_at(38, a[3])
                    if pfx != "xml" and uri in (_NS_XML, _NS_XMLNS):
                        self._fail_at(40, a[3])
                    if pfx and not uri:
                        self._fail_at(28, a[3])
                    if scope is None:
                        scope = dict(self._ns[-1])
                    scope[pfx] = uri
                    declared.append((pfx, uri))
                else:
                    plain.append(a)
            if scope is not None:
                self._ns.append(scope)
            else:
                self._ns.append(self._ns[-1])
            attrs = plain
        self._flush()
        for d in declared:
            if self.StartNamespaceDeclHandler is not None:
                self.StartNamespaceDeclHandler(d[0] if d[0] else None, d[1] if d[1] else None)
        var ename = name
        var names = []
        var values = []
        if self._sep is not None:
            ename = self._qname(name, 1, False)
            var seen = set()
            for a in attrs:
                var qn = self._qname(a[0], a[3], True) if a[3] >= 0 else a[0]
                if qn in seen:
                    self._fail_at(8, a[3])
                seen.add(qn)
                names.append(qn)
        else:
            for a in attrs:
                names.append(a[0])
        for a in attrs:
            values.append(self._attvalue(a[1], a[2]) if a[2] >= 0 else a[1])
        if self._state == 0:
            self._state = 1
        self._stack.append((name, [d[0] for d in declared], self._index))
        var h = self.StartElementHandler
        if h is not None:
            if self.ordered_attributes:
                var lst = []
                for q in range(len(names)):
                    lst.append(names[q])
                    lst.append(values[q])
                h(ename, lst)
            else:
                var d = {}
                for q in range(len(names)):
                    d[names[q]] = values[q]
                h(ename, d)
        else:
            self._default(buf[:length])
        self._advance(length)
        if empty:
            self._close(ename)

    def _close(self, ename):
        var top = self._stack.pop()
        self._flush()
        if self.EndElementHandler is not None:
            self.EndElementHandler(ename)
        if self._sep is not None:
            self._ns.pop()
            var pfxs = top[1]
            for q in range(len(pfxs) - 1, -1, -1):
                if self.EndNamespaceDeclHandler is not None:
                    self.EndNamespaceDeclHandler(pfxs[q] if pfxs[q] else None)
        if not self._stack:
            self._state = 2

    def _end_tag(self, final):
        var buf = self._buf
        var m = _NAME_RE.match(buf, 2)
        if m is None:
            if len(buf) < 3:
                self._need(final, 5)
            self._fail_at(4, 2)
        var name = m.group()
        var j = _WS_RE.match(buf, m.end()).end()
        if j >= len(buf):
            self._need(final, 5)
        if buf[j] != ">":
            self._fail_at(4, j)
        if not self._stack or self._stack[-1][0] != name:
            self._fail_at(7, 2)
        var ename = name
        if self._sep is not None:
            ename = self._qname(name, 2, False)
        if self.EndElementHandler is None:
            self._default(buf[:j + 1])
        self._advance(j + 1)
        self._close(ename)

    # the DOCTYPE ──────────────────────────────────────────────────────────
    def _doctype(self, final):
        var buf = self._buf
        # find the end: '>' outside quotes and outside the [internal subset]
        var i = 9
        var n = len(buf)
        var depth = 0
        var end = -1
        while i < n:
            var c = buf[i]
            if c == '"' or c == "'":
                var e = buf.find(c, i + 1)
                if e < 0:
                    break
                i = e + 1
                continue
            if c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
            elif c == "<" and buf.startswith("<!--", i):
                var e = buf.find("-->", i + 4)
                if e < 0:
                    break
                i = e + 3
                continue
            elif c == ">" and depth <= 0:
                end = i
                break
            i += 1
        if end < 0:
            self._need(final, 5)
        self._had_doctype = True
        var text = buf[:end + 1]
        var pos = 9
        var ws = _WS_RE.match(text, pos).end()
        if ws == pos:
            self._fail_at(2, pos)
        var m = _NAME_RE.match(text, ws)
        if m is None:
            self._fail_at(2, ws)
        var name = m.group()
        var pieces = ["<!DOCTYPE", text[pos:ws], name]
        pos = m.end()
        var sysid = None
        var pubid = None
        var p2 = _WS_RE.match(text, pos).end()
        if text.startswith("SYSTEM", p2) or text.startswith("PUBLIC", p2):
            var kw = text[p2:p2 + 6]
            pieces.append(text[pos:p2])
            pieces.append(kw)
            pos = p2 + 6
            var lits = []
            var count = 1 if kw == "SYSTEM" else 2
            for q in range(count):
                var w = _WS_RE.match(text, pos).end()
                if w == pos or w >= len(text) or text[w] not in "\"'":
                    self._fail_at(2, w)
                var e = text.find(text[w], w + 1)
                pieces.append(text[pos:w])
                pieces.append(text[w:e + 1])
                lits.append(text[w + 1:e])
                pos = e + 1
            if kw == "SYSTEM":
                sysid = lits[0]
            else:
                pubid = lits[0]
                sysid = lits[1]
            self._dtd_external = True
        var w = _WS_RE.match(text, pos).end()
        var has_internal = w < len(text) and text[w] == "["
        if self.StartDoctypeDeclHandler is not None:
            self._flush()
            self.StartDoctypeDeclHandler(name, sysid, pubid, 1 if has_internal else 0)
        else:
            for p in pieces:
                if p:
                    self._default(p)
        if has_internal:
            var close = text.rfind("]")
            if text[w:w + 1] == "[" and self.StartDoctypeDeclHandler is None:
                self._default("[")
            self._subset(text[w + 1:close], w + 1)
            if self.StartDoctypeDeclHandler is None:
                self._default("]")
        if self.EndDoctypeDeclHandler is not None:
            self.EndDoctypeDeclHandler()
        elif self.StartDoctypeDeclHandler is None:
            self._default(">")
        self._advance(end + 1)

    def _literal(self, s, i):
        # a quoted literal at s[i]: (value, index after it)
        if i >= len(s) or s[i] not in "\"'":
            return None, i
        var e = s.find(s[i], i + 1)
        if e < 0:
            return None, i
        return s[i + 1:e], e + 1

    def _subset(self, s, base):
        var i = 0
        var n = len(s)
        while i < n:
            var w = _WS_RE.match(s, i).end()
            if w >= n:
                break
            i = w
            if s.startswith("<!--", i):
                var e = s.find("-->", i + 4)
                if self.CommentHandler is not None:
                    self.CommentHandler(s[i + 4:e])
                i = e + 3
                continue
            if s.startswith("<?", i):
                var e = s.find("?>", i + 2)
                var m = _NAME_RE.match(s, i + 2)
                if m is not None and self.ProcessingInstructionHandler is not None:
                    self.ProcessingInstructionHandler(m.group(), s[m.end():e].lstrip(" \t\n"))
                i = e + 2
                continue
            if s[i] == "%":
                var e = s.find(";", i)
                self._dtd_external = True
                i = e + 1 if e > 0 else n
                continue
            # a declaration: up to its '>' outside quotes
            var j = i + 2
            while j < n and s[j] != ">":
                if s[j] in "\"'":
                    var e = s.find(s[j], j + 1)
                    j = e + 1 if e > 0 else n
                else:
                    j += 1
            var decl = s[i:j + 1]
            if decl.startswith("<!ENTITY"):
                self._entity_decl(decl)
            elif decl.startswith("<!ATTLIST"):
                self._attlist_decl(decl)
            elif decl.startswith("<!ELEMENT"):
                if self.ElementDeclHandler is not None:
                    var parts = decl[9:-1].split(None, 1)
                    if len(parts) == 2:
                        self.ElementDeclHandler(parts[0], parts[1].strip())
            elif decl.startswith("<!NOTATION"):
                if self.NotationDeclHandler is not None:
                    var parts = decl[10:-1].split()
                    if parts:
                        var lit = _re.findall("\"([^\"]*)\"|'([^']*)'", decl)
                        var vals = [a or b for a, b in lit]
                        if "PUBLIC" in parts:
                            self.NotationDeclHandler(parts[0], self._base, vals[1] if len(vals) > 1 else None, vals[0] if vals else None)
                        else:
                            self.NotationDeclHandler(parts[0], self._base, vals[0] if vals else None, None)
            else:
                self._fail_at(2, base + i)
            i = j + 1

    def _entity_decl(self, decl):
        var s = decl[8:-1]
        var i = _WS_RE.match(s, 0).end()
        var is_pe = False
        if s[i:i + 1] == "%":
            is_pe = True
            i = _WS_RE.match(s, i + 1).end()
        var m = _NAME_RE.match(s, i)
        if m is None:
            return
        var name = m.group()
        i = _WS_RE.match(s, m.end()).end()
        if s[i:i + 1] in ("\"", "'"):
            var lit = self._literal(s, i)
            var value = lit[0]
            # character references are replaced when the entity is declared
            value = _re.sub("&#(x[0-9a-fA-F]+|[0-9]+);",
                            lambda mm: chr(int(mm.group(1)[1:], 16)) if mm.group(1)[0] == "x" else chr(int(mm.group(1))),
                            value)
            if not is_pe and name not in self._entities:
                self._entities[name] = value
            if self.EntityDeclHandler is not None:
                self.EntityDeclHandler(name, 1 if is_pe else 0, value, self._base, None, None, None)
            return
        # an external entity
        var sysid = None
        var pubid = None
        var notation = None
        if s.startswith("SYSTEM", i):
            var lit = self._literal(s, _WS_RE.match(s, i + 6).end())
            sysid = lit[0]
            i = lit[1]
        elif s.startswith("PUBLIC", i):
            var lit = self._literal(s, _WS_RE.match(s, i + 6).end())
            pubid = lit[0]
            var lit2 = self._literal(s, _WS_RE.match(s, lit[1]).end())
            sysid = lit2[0]
            i = lit2[1]
        var w = _WS_RE.match(s, i).end()
        if s.startswith("NDATA", w):
            var mm = _NAME_RE.match(s, _WS_RE.match(s, w + 5).end())
            if mm is not None:
                notation = mm.group()
        if not is_pe:
            self._ext_entities.add(name)
        if notation is not None and self.UnparsedEntityDeclHandler is not None:
            self.UnparsedEntityDeclHandler(name, self._base, sysid, pubid, notation)
        elif self.EntityDeclHandler is not None:
            self.EntityDeclHandler(name, 1 if is_pe else 0, None, self._base, sysid, pubid, notation)

    def _attlist_decl(self, decl):
        var s = decl[9:-1]
        var toks = _re.findall("\"[^\"]*\"|'[^']*'|\\([^)]*\\)|[^ \t\n]+", s)
        if not toks:
            return
        var elname = toks[0]
        var k = 1
        while k + 2 <= len(toks):
            var attname = toks[k]
            var atype = toks[k + 1]
            k += 2
            var default = None
            var required = 0
            if k < len(toks) and toks[k] in ("#REQUIRED", "#IMPLIED"):
                required = 1 if toks[k] == "#REQUIRED" else 0
                k += 1
            elif k < len(toks) and toks[k] == "#FIXED":
                default = toks[k + 1][1:-1]
                required = 1
                k += 2
            elif k < len(toks) and toks[k][:1] in ("\"", "'"):
                default = toks[k][1:-1]
                k += 1
            if default is not None:
                var lst = self._attdefaults.setdefault(elname, [])
                var have = False
                for d in lst:
                    if d[0] == attname:
                        have = True
                if not have:
                    lst.append((attname, self._attvalue(default, 0)))
            if self.AttlistDeclHandler is not None:
                self.AttlistDeclHandler(elname, attname, atype, default, required)


XMLParserType = xmlparser


def ParserCreate(encoding=None, namespace_separator=None, intern=None):
    if encoding is not None and not isinstance(encoding, str):
        raise TypeError("ParserCreate() argument 'encoding' must be str or None, not " + type(encoding).__name__)
    if namespace_separator is not None:
        if not isinstance(namespace_separator, str):
            raise TypeError("ParserCreate() argument 'namespace_separator' must be str or None, not " + type(namespace_separator).__name__)
        if len(namespace_separator) > 1:
            raise ValueError("namespace_separator must be at most one character, omitted, or None")
    return xmlparser(encoding, namespace_separator)
