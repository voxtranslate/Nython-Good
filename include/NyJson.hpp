// NyJson.hpp - the one JSON codec both engines use (RFC 8259).
//
// Before this, each engine had its own: the interpreter's json_encode wrote
// strings without escaping anything (a quote or a newline produced invalid
// JSON) and its json_decode read only a flat object - nested objects, arrays
// and every escape sequence came back wrong or as `{}`; the VM escaped most
// things but decoded "é" as the letters "u00e9". Now both engines parse
// into the neutral tree below and convert it to their own values, and both
// quote strings and format numbers with the same two functions, so a value
// round-trips identically on either engine.
#pragma once

#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

namespace nyjson {

inline void quote_to(std::string& out, const std::string& s) {
    out += '"';
    for (unsigned char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", (unsigned)c);
                    out += buf;
                } else {
                    out += (char)c;   // UTF-8 passes through unchanged
                }
        }
    }
    out += '"';
}

inline std::string quote(const std::string& s) {
    std::string out;
    quote_to(out, s);
    return out;
}

// Shortest text that reads back as the same double; always carries a '.' or
// an exponent so it decodes as a float again, not an int. JSON has no NaN or
// infinity, so those become null.
inline std::string number(double d) {
    if (!std::isfinite(d)) return "null";
    char buf[64];
    auto r = std::to_chars(buf, buf + sizeof buf, d);
    std::string s(buf, r.ptr);
    if (s.find_first_of(".eE") == std::string::npos) s += ".0";
    return s;
}

struct Node {
    enum Kind { Null, Bool, Int, Float, Str, Arr, Obj } kind = Null;
    bool b = false;
    long long i = 0;
    double d = 0.0;
    std::string s;
    std::vector<Node> items;                            // Arr
    std::vector<std::pair<std::string, Node>> fields;   // Obj, in document order
};

class Parser {
public:
    explicit Parser(const std::string& text) : t_(text) {}

    // Whole-document parse. On failure returns false and `err` says where.
    bool parse(Node& out, std::string& err) {
        pos_ = 0;
        ws();
        if (!value(out, 0)) { err = err_; return false; }
        ws();
        if (pos_ != t_.size()) { err = "unexpected trailing data at offset " + std::to_string(pos_); return false; }
        return true;
    }

private:
    const std::string& t_;
    size_t pos_ = 0;
    std::string err_;
    static constexpr int kMaxDepth = 512;

    bool fail(const std::string& what) {
        if (err_.empty()) err_ = what + " at offset " + std::to_string(pos_);
        return false;
    }
    void ws() {
        while (pos_ < t_.size() && (t_[pos_] == ' ' || t_[pos_] == '\t' || t_[pos_] == '\n' || t_[pos_] == '\r')) pos_++;
    }
    bool lit(const char* word) {
        size_t n = 0;
        while (word[n]) n++;
        if (t_.compare(pos_, n, word) != 0) return false;
        pos_ += n;
        return true;
    }

    bool value(Node& out, int depth) {
        if (depth > kMaxDepth) return fail("nesting too deep");
        if (pos_ >= t_.size()) return fail("unexpected end of input");
        char c = t_[pos_];
        if (c == '{') return object(out, depth);
        if (c == '[') return array(out, depth);
        if (c == '"') { out.kind = Node::Str; return str(out.s); }
        if (c == 't') { if (!lit("true")) return fail("invalid literal"); out.kind = Node::Bool; out.b = true; return true; }
        if (c == 'f') { if (!lit("false")) return fail("invalid literal"); out.kind = Node::Bool; out.b = false; return true; }
        if (c == 'n') {
            // "none" is accepted as well: the old interpreter decoder did, and
            // Nython prints none that way.
            if (lit("null") || lit("none")) { out.kind = Node::Null; return true; }
            return fail("invalid literal");
        }
        if (c == '-' || (c >= '0' && c <= '9')) return num(out);
        return fail(std::string("unexpected character '") + c + "'");
    }

    bool object(Node& out, int depth) {
        out.kind = Node::Obj;
        pos_++;  // {
        ws();
        if (pos_ < t_.size() && t_[pos_] == '}') { pos_++; return true; }
        while (true) {
            ws();
            if (pos_ >= t_.size() || t_[pos_] != '"') return fail("expected a string key");
            std::string key;
            if (!str(key)) return false;
            ws();
            if (pos_ >= t_.size() || t_[pos_] != ':') return fail("expected ':'");
            pos_++;
            ws();
            Node v;
            if (!value(v, depth + 1)) return false;
            // Duplicate keys: the last one wins, as in JavaScript and Python.
            bool replaced = false;
            for (auto& f : out.fields) {
                if (f.first == key) { f.second = std::move(v); replaced = true; break; }
            }
            if (!replaced) out.fields.emplace_back(std::move(key), std::move(v));
            ws();
            if (pos_ < t_.size() && t_[pos_] == ',') { pos_++; continue; }
            if (pos_ < t_.size() && t_[pos_] == '}') { pos_++; return true; }
            return fail("expected ',' or '}'");
        }
    }

    bool array(Node& out, int depth) {
        out.kind = Node::Arr;
        pos_++;  // [
        ws();
        if (pos_ < t_.size() && t_[pos_] == ']') { pos_++; return true; }
        while (true) {
            ws();
            Node v;
            if (!value(v, depth + 1)) return false;
            out.items.push_back(std::move(v));
            ws();
            if (pos_ < t_.size() && t_[pos_] == ',') { pos_++; continue; }
            if (pos_ < t_.size() && t_[pos_] == ']') { pos_++; return true; }
            return fail("expected ',' or ']'");
        }
    }

    static void utf8(std::string& o, uint32_t cp) {
        if (cp < 0x80) o += (char)cp;
        else if (cp < 0x800) { o += (char)(0xC0 | (cp >> 6)); o += (char)(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) {
            o += (char)(0xE0 | (cp >> 12)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F));
        } else {
            o += (char)(0xF0 | (cp >> 18)); o += (char)(0x80 | ((cp >> 12) & 0x3F));
            o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F));
        }
    }

    bool hex4(uint32_t& v) {
        if (pos_ + 4 > t_.size()) return fail("truncated \\u escape");
        v = 0;
        for (int k = 0; k < 4; k++) {
            char h = t_[pos_++];
            v <<= 4;
            if (h >= '0' && h <= '9') v |= (uint32_t)(h - '0');
            else if (h >= 'a' && h <= 'f') v |= (uint32_t)(h - 'a' + 10);
            else if (h >= 'A' && h <= 'F') v |= (uint32_t)(h - 'A' + 10);
            else return fail("bad hex digit in \\u escape");
        }
        return true;
    }

    bool str(std::string& o) {
        pos_++;  // opening quote
        while (pos_ < t_.size()) {
            char c = t_[pos_++];
            if (c == '"') return true;
            if (c != '\\') { o += c; continue; }
            if (pos_ >= t_.size()) break;
            char e = t_[pos_++];
            switch (e) {
                case '"': o += '"'; break;
                case '\\': o += '\\'; break;
                case '/': o += '/'; break;
                case 'b': o += '\b'; break;
                case 'f': o += '\f'; break;
                case 'n': o += '\n'; break;
                case 'r': o += '\r'; break;
                case 't': o += '\t'; break;
                case 'u': {
                    uint32_t cp;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        // A high surrogate must pair with a following low one.
                        uint32_t lo = 0;
                        size_t save = pos_;
                        if (pos_ + 6 <= t_.size() && t_[pos_] == '\\' && t_[pos_ + 1] == 'u') {
                            pos_ += 2;
                            if (!hex4(lo)) return false;
                        }
                        if (lo >= 0xDC00 && lo <= 0xDFFF) cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        else { pos_ = save; cp = 0xFFFD; }
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        cp = 0xFFFD;
                    }
                    utf8(o, cp);
                    break;
                }
                default:
                    return fail(std::string("invalid escape '\\") + e + "'");
            }
        }
        return fail("unterminated string");
    }

    bool num(Node& out) {
        size_t start = pos_;
        if (t_[pos_] == '-') pos_++;
        if (pos_ >= t_.size() || !(t_[pos_] >= '0' && t_[pos_] <= '9')) return fail("invalid number");
        while (pos_ < t_.size() && t_[pos_] >= '0' && t_[pos_] <= '9') pos_++;
        bool is_float = false;
        if (pos_ < t_.size() && t_[pos_] == '.') {
            is_float = true;
            pos_++;
            if (pos_ >= t_.size() || !(t_[pos_] >= '0' && t_[pos_] <= '9')) return fail("invalid number");
            while (pos_ < t_.size() && t_[pos_] >= '0' && t_[pos_] <= '9') pos_++;
        }
        if (pos_ < t_.size() && (t_[pos_] == 'e' || t_[pos_] == 'E')) {
            is_float = true;
            pos_++;
            if (pos_ < t_.size() && (t_[pos_] == '+' || t_[pos_] == '-')) pos_++;
            if (pos_ >= t_.size() || !(t_[pos_] >= '0' && t_[pos_] <= '9')) return fail("invalid number");
            while (pos_ < t_.size() && t_[pos_] >= '0' && t_[pos_] <= '9') pos_++;
        }
        const char* b = t_.data() + start;
        const char* e = t_.data() + pos_;
        if (!is_float) {
            long long v = 0;
            auto r = std::from_chars(b, e, v);
            if (r.ec == std::errc() && r.ptr == e) { out.kind = Node::Int; out.i = v; return true; }
            // Too large for 64 bits: keep the magnitude as a float.
        }
        double d = 0.0;
        auto r = std::from_chars(b, e, d);
        if (r.ec != std::errc() && r.ec != std::errc::result_out_of_range) return fail("invalid number");
        out.kind = Node::Float;
        out.d = d;
        return true;
    }
};

inline bool parse(const std::string& text, Node& out, std::string& err) {
    Parser p(text);
    return p.parse(out, err);
}

}  // namespace nyjson
