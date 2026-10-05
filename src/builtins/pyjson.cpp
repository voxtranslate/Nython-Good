// builtins/pyjson.cpp - the scanner and encoder behind lib/json.ny, written
// to give CPython's json module's results byte for byte (CPython's own C
// accelerator, Modules/_json.c, is the reference for every message and
// position). Both engines: the VM reaches these through the builtin bridge.
//
//   _json_scan(s, idx, strict, raw, doc) -> [true, value, end] | [false, msg, pos]
//       One JSON value starting at character index idx (scan_once /
//       raw_decode); doc=true is JSONDecoder.decode: whitespace allowed
//       around the value and anything after it is "Extra data".
//       Errors come back as JSONDecodeError's (msg, pos) -
//       positions are character indices, as Python's str indexes - and the
//       Nython side raises them. raw (bits) is for the hooks, which
//       lib/json applies: 1 (parse_float/int/constant) gives numbers as
//       ("i"|"f"|"c", text), 2 (object_pairs_hook) objects as
//       ("o", [k1, v1, k2, v2, ...]) with every pair, duplicates included.
//   _json_scanstring(s, end, strict) -> [true, str, end] | [false, msg, pos]
//       json.decoder.scanstring: end is the index after the opening quote.
//   _json_quote(s, ensure_ascii) -> str
//       encode_basestring / encode_basestring_ascii.
//   _json_encode(obj, indent, item_sep, key_sep, sort_keys, ensure_ascii,
//                allow_nan, skipkeys, check_circular) -> str | none
//       The whole document for dict/list/tuple/str/int/float/bool/None
//       trees. none means "a value here needs Python's rules for other
//       types (default=, a subclass...)": lib/json.ny then runs its own
//       encoder, which gives the same text for everything this one does.
//
// The legacy json_encode/json_decode (include/NyJson.hpp) keep their own
// contract: sorted keys, none for invalid input, "none" accepted.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyFormat.hpp"
#include "builtins/os.hpp"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

Value dispatch_pyjson(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> pyjson_builtin_names();

namespace {

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }

// CPython's recursion limit is what stops both its C scanner and encoder.
constexpr int kMaxDepth = 1000;

inline bool cont_byte(unsigned char c) { return (c & 0xC0) == 0x80; }

// Character index <-> byte offset in UTF-8 text.
size_t byte_of_char(const std::string& s, int64_t idx) {
    size_t b = 0;
    int64_t n = 0;
    while (b < s.size() && n < idx) {
        b++;
        while (b < s.size() && cont_byte((unsigned char)s[b])) b++;
        n++;
    }
    return b;
}
int64_t char_of_byte(const std::string& s, size_t from_b, int64_t from_c, int64_t b) {
    if (b < 0) return -1;
    int64_t n = from_c;
    for (size_t i = from_b; (int64_t)i < b && i < s.size(); i++)
        if (!cont_byte((unsigned char)s[i])) n++;
    return n;
}

// One code point as UTF-8; a lone surrogate gets the 3-byte form, which is
// how Nython's strings hold one (chr(0xD800)).
void put_utf8(std::string& o, uint32_t cp) {
    if (cp < 0x80) o += (char)cp;
    else if (cp < 0x800) { o += (char)(0xC0 | (cp >> 6)); o += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) {
        o += (char)(0xE0 | (cp >> 12)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F));
    } else {
        o += (char)(0xF0 | (cp >> 18)); o += (char)(0x80 | ((cp >> 12) & 0x3F));
        o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F));
    }
}

// Decodes the code point at s[i] and advances i (invalid bytes read as
// themselves, Latin-1 style, so nothing is lost).
uint32_t next_cp(const std::string& s, size_t& i) {
    unsigned char c = (unsigned char)s[i];
    auto cb = [&](size_t k) { return k < s.size() && cont_byte((unsigned char)s[k]); };
    if (c < 0x80) { i++; return c; }
    if ((c & 0xE0) == 0xC0 && cb(i + 1)) {
        uint32_t cp = ((c & 0x1Fu) << 6) | ((unsigned char)s[i + 1] & 0x3Fu);
        i += 2; return cp;
    }
    if ((c & 0xF0) == 0xE0 && cb(i + 1) && cb(i + 2)) {
        uint32_t cp = ((c & 0x0Fu) << 12) | (((unsigned char)s[i + 1] & 0x3Fu) << 6) | ((unsigned char)s[i + 2] & 0x3Fu);
        i += 3; return cp;
    }
    if ((c & 0xF8) == 0xF0 && cb(i + 1) && cb(i + 2) && cb(i + 3)) {
        uint32_t cp = ((c & 0x07u) << 18) | (((unsigned char)s[i + 1] & 0x3Fu) << 12)
                    | (((unsigned char)s[i + 2] & 0x3Fu) << 6) | ((unsigned char)s[i + 3] & 0x3Fu);
        i += 4; return cp;
    }
    i++;
    return c;
}

const char* kHex = "0123456789abcdef";

void put_u_escape(std::string& o, uint32_t c) {
    o += "\\u";
    o += kHex[(c >> 12) & 0xF]; o += kHex[(c >> 8) & 0xF]; o += kHex[(c >> 4) & 0xF]; o += kHex[c & 0xF];
}

// encode_basestring(_ascii), Modules/_json.c's escape_unicode /
// ascii_escape_unichar.
void quote_to(std::string& o, const std::string& s, bool ensure_ascii) {
    o += '"';
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        if (c >= ' ' && c <= '~' && c != '\\' && c != '"') { o += (char)c; i++; continue; }
        switch (c) {
            case '\\': o += "\\\\"; i++; continue;
            case '"':  o += "\\\""; i++; continue;
            case '\b': o += "\\b"; i++; continue;
            case '\f': o += "\\f"; i++; continue;
            case '\n': o += "\\n"; i++; continue;
            case '\r': o += "\\r"; i++; continue;
            case '\t': o += "\\t"; i++; continue;
            default: break;
        }
        if (c < ' ') { put_u_escape(o, c); i++; continue; }
        if (!ensure_ascii) { o += (char)c; i++; continue; }   // DEL and UTF-8 pass through
        uint32_t cp = next_cp(s, i);
        if (cp >= 0x10000) {
            uint32_t v = cp - 0x10000;
            put_u_escape(o, 0xD800 | (v >> 10));
            put_u_escape(o, 0xDC00 | (v & 0x3FF));
        } else {
            put_u_escape(o, cp);
        }
    }
    o += '"';
}

// ── the scanner (_json.c scan_once_unicode and friends) ──────────────────
struct Scanner {
    NythonExecutor& E;
    const std::string& s;
    bool strict;
    int raw;    // 1: numbers as ("i"|"f"|"c", text), 2: objects as ("o", pairs)
    std::string err;
    int64_t err_at = 0;   // byte offset of the error (-1: before the text)
    int depth = 0;

    Scanner(NythonExecutor& e, const std::string& text, bool st, int r) : E(e), s(text), strict(st), raw(r), err() {}

    bool error(const char* msg, int64_t at) { err = msg; err_at = at; return false; }
    bool ws(size_t i) const { char c = s[i]; return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
    void skip_ws(size_t& i) const { while (i < s.size() && ws(i)) i++; }

    static int hexval(char h) {
        if (h >= '0' && h <= '9') return h - '0';
        if (h >= 'a' && h <= 'f') return h - 'a' + 10;
        if (h >= 'A' && h <= 'F') return h - 'A' + 10;
        return -1;
    }

    // `next` is the byte offset after the opening quote, `begin` the quote's
    // (for "Unterminated string starting at"); on success `end` is the offset
    // after the closing quote.
    bool string(size_t next, int64_t begin, std::string& out, size_t& end) {
        size_t len = s.size();
        out.clear();
        while (true) {
            size_t start = next;
            unsigned char c = 0;
            for (; next < len; next++) {
                c = (unsigned char)s[next];
                if (c == '"' || c == '\\') break;
                if (c <= 0x1f && strict) return error("Invalid control character at", next);
            }
            if (next >= len) return error("Unterminated string starting at", begin);
            out.append(s, start, next - start);
            next++;
            if (c == '"') { end = next; return true; }
            if (next >= len) return error("Unterminated string starting at", begin);
            char e = s[next];
            if (e != 'u') {
                switch (e) {
                    case '"': out += '"'; break;
                    case '\\': out += '\\'; break;
                    case '/': out += '/'; break;
                    case 'b': out += '\b'; break;
                    case 'f': out += '\f'; break;
                    case 'n': out += '\n'; break;
                    case 'r': out += '\r'; break;
                    case 't': out += '\t'; break;
                    default: return error("Invalid \\escape", next - 1);
                }
                next++;
                continue;
            }
            // \uXXXX: the four digits must be followed by at least one more
            // character (_json.c's `end >= len` test).
            next++;
            if (next + 4 >= len) return error("Invalid \\uXXXX escape", next - 1);
            uint32_t cp = 0;
            for (int k = 0; k < 4; k++) {
                int h = hexval(s[next + k]);
                if (h < 0) return error("Invalid \\uXXXX escape", next - 1);
                cp = (cp << 4) | (uint32_t)h;
            }
            next += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF && next + 6 < len && s[next] == '\\' && s[next + 1] == 'u') {
                uint32_t c2 = 0;
                for (int k = 0; k < 4; k++) {
                    int h = hexval(s[next + 2 + k]);
                    if (h < 0) return error("Invalid \\uXXXX escape", next + 1);
                    c2 = (c2 << 4) | (uint32_t)h;
                }
                if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                    cp = 0x10000 + (((cp - 0xD800) << 10) | (c2 - 0xDC00));
                    next += 6;
                }
            }
            put_utf8(out, cp);
        }
    }

    Value tagged(const char* tag, Value v) {
        return E.makeListValue({E.makeStringValue(tag), v}, true);
    }

    // A number at s[i] (_match_number_unicode). false with err empty: no
    // number here ("Expecting value" at the caller's start).
    bool number(size_t i, Value& out, size_t& end) {
        size_t start = i, len = s.size();
        if (s[i] == '-') { i++; if (i >= len) return false; }
        if (s[i] >= '1' && s[i] <= '9') {
            i++;
            while (i < len && s[i] >= '0' && s[i] <= '9') i++;
        } else if (s[i] == '0') {
            i++;
        } else {
            return false;
        }
        bool is_float = false;
        if (i + 1 < len && s[i] == '.' && s[i + 1] >= '0' && s[i + 1] <= '9') {
            is_float = true;
            i += 2;
            while (i < len && s[i] >= '0' && s[i] <= '9') i++;
        }
        if (i + 1 < len && (s[i] == 'e' || s[i] == 'E')) {
            size_t e_start = i;
            i++;
            if (i + 1 < len && (s[i] == '-' || s[i] == '+')) i++;
            while (i < len && s[i] >= '0' && s[i] <= '9') i++;
            if (s[i - 1] >= '0' && s[i - 1] <= '9') is_float = true;
            else i = e_start;
        }
        std::string text = s.substr(start, i - start);
        end = i;
        if (raw & 1) { out = tagged(is_float ? "f" : "i", E.makeStringValue(text)); return true; }
        if (is_float) {
            out = Value(std::strtod(text.c_str(), nullptr));   // 1e400 -> inf, as float()
            return true;
        }
        if (text.size() <= 18) { out = intValue((int64_t)std::strtoll(text.c_str(), nullptr, 10)); return true; }
        nypy::BigInt big;
        nypy::BigInt::parse(text, 10, big);
        out = intValue(big);
        return true;
    }

    bool constant(const char* name, double v, Value& out) {
        out = (raw & 1) ? tagged("c", E.makeStringValue(name)) : Value(v);
        return true;
    }

    // scan_once: false with err empty is StopIteration (Expecting value at i).
    bool value(size_t i, Value& out, size_t& end) {
        size_t len = s.size();
        if (i >= len) return error("Expecting value", i);
        switch (s[i]) {
            case '"': {
                std::string str;
                if (!string(i + 1, (int64_t)i, str, end)) return false;
                out = E.makeStringValue(str);
                return true;
            }
            case '{':
                if (depth >= kMaxDepth) fail("RecursionError", "maximum recursion depth exceeded while decoding a JSON object from a unicode string");
                { depth++; bool ok = object(i + 1, out, end); depth--; return ok; }
            case '[':
                if (depth >= kMaxDepth) fail("RecursionError", "maximum recursion depth exceeded while decoding a JSON array from a unicode string");
                { depth++; bool ok = array(i + 1, out, end); depth--; return ok; }
            case 'n':
                if (i + 3 < len && s.compare(i, 4, "null") == 0) { out = NONE_VALUE; end = i + 4; return true; }
                break;
            case 't':
                if (i + 3 < len && s.compare(i, 4, "true") == 0) { out = Value(true); end = i + 4; return true; }
                break;
            case 'f':
                if (i + 4 < len && s.compare(i, 5, "false") == 0) { out = Value(false); end = i + 5; return true; }
                break;
            case 'N':
                if (i + 2 < len && s.compare(i, 3, "NaN") == 0) { end = i + 3; return constant("NaN", NAN, out); }
                break;
            case 'I':
                if (i + 7 < len && s.compare(i, 8, "Infinity") == 0) { end = i + 8; return constant("Infinity", INFINITY, out); }
                break;
            case '-':
                if (i + 8 < len && s.compare(i, 9, "-Infinity") == 0) { end = i + 9; return constant("-Infinity", -INFINITY, out); }
                break;
            default: break;
        }
        if (number(i, out, end)) return true;
        return error("Expecting value", i);
    }

    bool object(size_t i, Value& out, size_t& end) {
        size_t len = s.size();
        std::vector<Value> pairs;     // raw: k1, v1, k2, v2 ...
        Value dict;
        Container* c = nullptr;
        if (!(raw & 2)) { dict = E.makeDictValue(); c = E.contOf(dict); }
        skip_ws(i);
        if (i >= len || s[i] != '}') {
            while (true) {
                if (i >= len || s[i] != '"') return error("Expecting property name enclosed in double quotes", i);
                std::string key;
                size_t next;
                if (!string(i + 1, (int64_t)i, key, next)) return false;
                i = next;
                skip_ws(i);
                if (i >= len || s[i] != ':') return error("Expecting ':' delimiter", i);
                i++;
                skip_ws(i);
                Value v;
                if (!value(i, v, next)) return false;
                if (raw & 2) { pairs.push_back(E.makeStringValue(key)); pairs.push_back(v); }
                else (*c->container)[nypy::key_of_str(key)] = v;   // a repeated key keeps its first place, as dict(pairs)
                i = next;
                skip_ws(i);
                if (i < len && s[i] == '}') break;
                if (i >= len || s[i] != ',') return error("Expecting ',' delimiter", i);
                i++;
                skip_ws(i);
            }
        }
        end = i + 1;
        out = (raw & 2) ? tagged("o", E.makeListValue(pairs)) : dict;
        return true;
    }

    bool array(size_t i, Value& out, size_t& end) {
        size_t len = s.size();
        std::vector<Value> items;
        skip_ws(i);
        if (i >= len || s[i] != ']') {
            while (true) {
                Value v;
                size_t next;
                if (!value(i, v, next)) return false;
                items.push_back(v);
                i = next;
                skip_ws(i);
                if (i < len && s[i] == ']') break;
                if (i >= len || s[i] != ',') return error("Expecting ',' delimiter", i);
                i++;
                skip_ws(i);
            }
        }
        end = i + 1;
        out = E.makeListValue(items);
        return true;
    }
};

// ── the encoder (Lib/json/encoder.py's _make_iterencode, as one string) ──
struct Encoder {
    NythonExecutor& E;
    std::string out;
    bool has_indent = false;
    std::string indent, item_sep, key_sep;
    bool sort_keys = false, ensure_ascii = true, allow_nan = true, skipkeys = false, check_circular = true;
    std::vector<const void*> stack;
    int depth = 0;

    explicit Encoder(NythonExecutor& e) : E(e), out(), indent(), item_sep(), key_sep(), stack() {}

    void floatstr(double d) {
        const char* text = nullptr;
        if (d != d) text = "NaN";
        else if (std::isinf(d)) text = d > 0 ? "Infinity" : "-Infinity";
        else { out += nypy::float_repr(d); return; }
        if (!allow_nan) fail("ValueError", std::string("Out of range float values are not JSON compliant: ") + nypy::float_repr(d));
        out += text;
    }

    void newline(int level) {
        out += '\n';
        for (int k = 0; k < level; k++) out += indent;
    }

    void enter(const void* id) {
        if (check_circular) {
            for (const void* p : stack) if (p == id) fail("ValueError", "Circular reference detected");
            stack.push_back(id);
        }
        if (++depth > kMaxDepth) fail("RecursionError", "maximum recursion depth exceeded while encoding a JSON object");
    }
    void leave() {
        if (check_circular) stack.pop_back();
        depth--;
    }

    // A dict key as JSON text: 1 written, 0 skipped (skipkeys), -1 a key
    // of another type, whose TypeError the Nython encoder raises (it knows
    // the key's type on either engine).
    int key_text(const std::string& k, std::string& text) {
        switch (nypy::key_kind(k)) {
            case nypy::K_STR: text = nypy::key_payload(k); return 1;
            case nypy::K_INT: text = k.substr(2); return 1;
            case nypy::K_FLOAT: {
                double d = std::strtod(k.c_str() + 2, nullptr);
                if (d != d) text = "NaN";
                else if (std::isinf(d)) text = d > 0 ? "Infinity" : "-Infinity";
                else { text = nypy::float_repr(d); return 1; }
                if (!allow_nan) fail("ValueError", "Out of range float values are not JSON compliant: " + nypy::float_repr(d));
                return 1;
            }
            case nypy::K_NONE: text = "null"; return 1;
            default: break;
        }
        return skipkeys ? 0 : -1;
    }

    // Sorting needs every key comparable with the others: all str, or all
    // numbers. Anything else is Python's TypeError, which the Nython
    // encoder raises (false here).
    static bool sortable(const std::vector<std::string>& keys) {
        bool any_str = false, any_num = false;
        for (auto& k : keys) {
            auto kind = nypy::key_kind(k);
            if (kind == nypy::K_STR) any_str = true;
            else if (kind == nypy::K_INT || kind == nypy::K_FLOAT) any_num = true;
            else if (keys.size() > 1) return false;
        }
        return !(any_str && any_num);
    }
    static double num_of_key(const std::string& k) { return std::strtod(k.c_str() + 2, nullptr); }
    static bool key_less(const std::string& a, const std::string& b) {
        auto ka = nypy::key_kind(a), kb = nypy::key_kind(b);
        if (ka == nypy::K_STR && kb == nypy::K_STR) return nypy::key_payload(a) < nypy::key_payload(b);
        if (ka == nypy::K_INT && kb == nypy::K_INT) {
            nypy::BigInt x, y;
            nypy::BigInt::parse(a.substr(2), 10, x);
            nypy::BigInt::parse(b.substr(2), 10, y);
            return nypy::BigInt::cmp(x, y) < 0;
        }
        return num_of_key(a) < num_of_key(b);
    }

    // false: a value the Nython encoder must handle.
    bool value(const Value& v, int level) {
        switch (v.type) {
            case ValueType::NONE: out += "null"; return true;
            case ValueType::BOOLEAN: out += v.value.b ? "true" : "false"; return true;
            case ValueType::INTEGER: out += intToString(v.value.i); return true;
            case ValueType::DOUBLE: floatstr((double)v.value.d); return true;
            case ValueType::UNDEFINED: return false;
            default: break;
        }
        if (v.type == ValueType::USERDATA) {
            if (E.bytesOf(v) || E.isInstanceVal(v) || !E.isStringValue(v)) return false;
            quote_to(out, *static_cast<std::string*>(v.value.p), ensure_ascii);
            return true;
        }
        if (nygen::is_gen(v)) return false;
        Container* c = E.contOf(v);
        if (!c) return false;
        auto& m = *c->container;
        int64_t n = NythonExecutor::seqLen(c);
        if (n >= 0) {
            if (NythonExecutor::isSetCont(c) || NythonExecutor::isGenCont(c)) return false;
            if (n == 0) { out += "[]"; return true; }
            enter(c);
            out += '[';
            if (has_indent) newline(level + 1);
            for (int64_t i = 0; i < n; i++) {
                if (i > 0) { out += item_sep; if (has_indent) newline(level + 1); }
                auto it = m.find(std::to_string(i));
                if (it == m.end()) out += "null";
                else if (!value(it->second, level + 1)) return false;
            }
            if (has_indent) newline(level);
            out += ']';
            leave();
            return true;
        }
        // a dict; an instance that crossed the VM bridge is a map holding
        // "__class__", and internal markers start with "__"
        if (m.count("__class__") || m.count("__kwargs__")) return false;
        std::vector<std::string> keys;
        for (auto& kv : m) if (!NythonExecutor::isInternalKey(kv.first)) keys.push_back(kv.first);
        if (keys.empty()) { out += "{}"; return true; }
        if (sort_keys) {
            if (!sortable(keys)) return false;
            std::stable_sort(keys.begin(), keys.end(), key_less);
        }
        enter(c);
        out += '{';
        if (has_indent) newline(level + 1);
        bool first = true;
        std::string kt;
        for (auto& k : keys) {
            int kind = key_text(k, kt);
            if (kind < 0) return false;
            if (kind == 0) continue;
            if (!first) { out += item_sep; if (has_indent) newline(level + 1); }
            first = false;
            quote_to(out, kt, ensure_ascii);
            out += key_sep;
            if (!value(m.find(k)->second, level + 1)) return false;
        }
        if (has_indent) newline(level);
        out += '}';
        leave();
        return true;
    }
};

std::string text_arg(NythonExecutor& E, const std::vector<Value>& args, size_t i, const char* fn) {
    if (i >= args.size() || !E.isStringValue(args[i]) || E.bytesOf(args[i]) || E.isInstanceVal(args[i]))
        fail("TypeError", std::string(fn) + "() argument must be str");
    return *static_cast<std::string*>(args[i].value.p);
}
bool truthy(const std::vector<Value>& args, size_t i, bool dflt) {
    if (i >= args.size()) return dflt;
    const Value& v = args[i];
    if (v.type == ValueType::BOOLEAN) return v.value.b;
    if (v.type == ValueType::NONE) return false;
    if (v.type == ValueType::INTEGER) return !(bigint_to_i64(v.value.i) == 0);
    return true;
}
int64_t int_arg(const std::vector<Value>& args, size_t i, int64_t dflt) {
    if (i >= args.size() || args[i].type != ValueType::INTEGER) return dflt;
    return bigint_to_i64(args[i].value.i);
}

Value result_ok(NythonExecutor& E, Value v, int64_t end) {
    return E.makeListValue({Value(true), v, intValue(end)});
}
Value result_err(NythonExecutor& E, const std::string& s, const Scanner& sc, size_t from_b, int64_t from_c) {
    return E.makeListValue({Value(false), E.makeStringValue(sc.err), intValue(char_of_byte(s, from_b, from_c, sc.err_at))});
}

} // namespace

std::vector<std::string> pyjson_builtin_names() {
    return {"_json_scan", "_json_scanstring", "_json_quote", "_json_encode"};
}

Value dispatch_pyjson(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name.compare(0, 6, "_json_") != 0) return UNDEFINED_VALUE;

    if (name == "_json_scan" || name == "_json_scanstring") {
        bool whole = name == "_json_scan";
        std::string s = text_arg(E, args, 0, name.c_str());
        int64_t idx = int_arg(args, 1, 0);
        if (idx < 0) fail("ValueError", "idx cannot be negative");
        bool strict = truthy(args, 2, true);
        int raw = whole ? (int)int_arg(args, 3, truthy(args, 3, false) ? 3 : 0) : 0;
        bool doc = whole && truthy(args, 4, false);
        size_t b = byte_of_char(s, idx);
        Scanner sc(E, s, strict, raw);
        Value out;
        size_t end = 0;
        bool ok;
        if (doc) {
            // JSONDecoder.decode: whitespace around one value, then "Extra data"
            sc.skip_ws(b);
            ok = sc.value(b, out, end);
            if (ok) {
                sc.skip_ws(end);
                if (end != s.size()) ok = sc.error("Extra data", (int64_t)end);
            }
            if (!ok) return result_err(E, s, sc, 0, 0);
            return result_ok(E, out, char_of_byte(s, 0, 0, (int64_t)end));
        }
        if (whole) {
            ok = sc.value(b, out, end);
        } else {
            // scanstring(s, end): end is the index after the opening quote
            if (char_of_byte(s, 0, 0, (int64_t)s.size()) < idx) fail("ValueError", "end is out of bounds");
            std::string str;
            ok = sc.string(b, (int64_t)b - 1, str, end);
            if (ok) out = E.makeStringValue(str);
        }
        if (!ok) return result_err(E, s, sc, 0, 0);
        return result_ok(E, out, char_of_byte(s, b, idx, (int64_t)end));
    }
    if (name == "_json_quote") {
        std::string s = text_arg(E, args, 0, "encode_basestring");
        std::string o;
        o.reserve(s.size() + 2);
        quote_to(o, s, truthy(args, 1, true));
        return E.makeStringValue(o);
    }
    if (name == "_json_encode") {
        if (args.empty()) fail("TypeError", "_json_encode() needs an object");
        Encoder en(E);
        if (args.size() > 1 && args[1].type != ValueType::NONE) {
            en.has_indent = true;
            en.indent = text_arg(E, args, 1, "indent");
        }
        en.item_sep = args.size() > 2 ? text_arg(E, args, 2, "separators") : std::string(", ");
        en.key_sep = args.size() > 3 ? text_arg(E, args, 3, "separators") : std::string(": ");
        en.sort_keys = truthy(args, 4, false);
        en.ensure_ascii = truthy(args, 5, true);
        en.allow_nan = truthy(args, 6, true);
        en.skipkeys = truthy(args, 7, false);
        en.check_circular = truthy(args, 8, true);
        if (!en.value(args[0], 0)) return NONE_VALUE;
        return E.makeStringValue(en.out);
    }
    return UNDEFINED_VALUE;
}
