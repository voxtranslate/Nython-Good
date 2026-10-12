#pragma once
// NyFormat.hpp - Python number printing and string formatting, shared by
// both engines: repr(float), the format-spec mini-language (format(),
// f"{x:spec}", str.format) and printf-style `%` formatting.
//
// The engines differ in how they store values, so everything here works on
// FmtVal, a small engine-neutral description of one value; each engine
// converts its own values (and applies !r/!s/!a conversions, which need its
// own repr/str) before calling in.
#include <charconv>
#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>
#include "NyBigInt.hpp"
#include "NyStr.hpp"

namespace nypy {

// ── repr(float) ─────────────────────────────────────────────────────────
// Shortest string that round-trips, laid out the way Python does: fixed
// notation for 1e-4 <= |x| < 1e16, otherwise d.ddde+XX; always a '.' or an
// exponent, so 2.0 prints as 2.0 and 0.1 + 0.2 as 0.30000000000000004.
inline std::string float_repr(double x) {
    if (std::isnan(x)) return "nan";
    if (std::isinf(x)) return x < 0 ? "-inf" : "inf";
    if (x == 0.0) return std::signbit(x) ? "-0.0" : "0.0";
    char buf[64];
    auto res = std::to_chars(buf, buf + sizeof buf, x, std::chars_format::scientific);
    std::string sci(buf, res.ptr);
    bool neg = sci[0] == '-';
    if (neg) sci.erase(0, 1);
    size_t e = sci.find('e');
    std::string mant = sci.substr(0, e);
    int exp10 = std::atoi(sci.c_str() + e + 1);
    std::string digits;
    for (char c : mant) if (c != '.') digits += c;
    int decpt = exp10 + 1;
    int nd = (int)digits.size();
    std::string out;
    if (decpt <= -4 || decpt > 16) {
        out = digits.substr(0, 1);
        if (nd > 1) { out += '.'; out += digits.substr(1); }
        char eb[16]; snprintf(eb, sizeof eb, "e%c%02d", exp10 < 0 ? '-' : '+', exp10 < 0 ? -exp10 : exp10);
        out += eb;
    } else if (decpt <= 0) {
        out = "0." + std::string((size_t)(-decpt), '0') + digits;
    } else if (decpt >= nd) {
        out = digits + std::string((size_t)(decpt - nd), '0') + ".0";
    } else {
        out = digits.substr(0, (size_t)decpt) + "." + digits.substr((size_t)decpt);
    }
    return neg ? "-" + out : out;
}

// ── values ──────────────────────────────────────────────────────────────
struct FmtVal {
    enum Kind { INT, FLOAT, STR, BOOL, NONE, OTHER } kind = STR;
    int64_t i = 0; bool is_big = false; BigInt big;
    double d = 0.0;
    bool b = false;
    std::string s;          // str() of the value for STR / NONE / OTHER
    std::string type_name;  // for error messages
    bool done = false;      // s is already the formatted text (an object's __format__)
    // An object with __format__: the engine's call of it, given the spec
    // (str.format's fields; format() and f-strings call it themselves).
    std::function<std::string(const std::string&)> custom;
    static FmtVal of_int(int64_t v) { FmtVal f; f.kind = INT; f.i = v; f.type_name = "int"; return f; }
    static FmtVal of_big(const BigInt& v) {
        int64_t t; if (v.to_i64(t)) return of_int(t);
        FmtVal f; f.kind = INT; f.is_big = true; f.big = v; f.type_name = "int"; return f;
    }
    static FmtVal of_float(double v) { FmtVal f; f.kind = FLOAT; f.d = v; f.type_name = "float"; return f; }
    static FmtVal of_str(std::string v) { FmtVal f; f.kind = STR; f.s = std::move(v); f.type_name = "str"; return f; }
    static FmtVal of_bool(bool v) { FmtVal f; f.kind = BOOL; f.b = v; f.s = v ? "true" : "false"; f.type_name = "bool"; return f; }
    static FmtVal of_none() { FmtVal f; f.kind = NONE; f.s = "none"; f.type_name = "NoneType"; return f; }
    static FmtVal of_other(std::string str, std::string tn) { FmtVal f; f.kind = OTHER; f.s = std::move(str); f.type_name = std::move(tn); return f; }
    BigInt as_big() const { return is_big ? big : BigInt(kind == BOOL ? (int64_t)b : i); }
    bool is_numeric() const { return kind == INT || kind == FLOAT || kind == BOOL; }
    double as_double() const { return kind == FLOAT ? d : kind == BOOL ? (b ? 1.0 : 0.0) : is_big ? big.to_double() : (double)i; }
};

// ── spec ────────────────────────────────────────────────────────────────
struct Spec {
    std::string fill = " ";
    char align = 0, sign = 0, grouping = 0, type = 0;
    bool fill_given = false, z = false, alt = false, zero = false;
    int64_t width = -1, prec = -1;
};
inline bool is_align(char c) { return c == '<' || c == '>' || c == '^' || c == '='; }
inline Spec parse_spec(const std::string& sp) {
    Spec s; size_t i = 0, n = sp.size();
    if (n) {
        size_t k = u8_at_len(sp, 0);
        if (k < n && is_align(sp[k])) { s.fill = sp.substr(0, k); s.fill_given = true; s.align = sp[k]; i = k + 1; }
        else if (is_align(sp[0])) { s.align = sp[0]; i = 1; }
    }
    if (i < n && (sp[i] == '+' || sp[i] == '-' || sp[i] == ' ')) s.sign = sp[i++];
    if (i < n && sp[i] == 'z') { s.z = true; i++; }
    if (i < n && sp[i] == '#') { s.alt = true; i++; }
    if (i < n && sp[i] == '0') { s.zero = true; i++; }
    if (i < n && sp[i] >= '0' && sp[i] <= '9') { s.width = 0; while (i < n && sp[i] >= '0' && sp[i] <= '9') s.width = s.width * 10 + (sp[i++] - '0'); }
    if (i < n && (sp[i] == ',' || sp[i] == '_')) s.grouping = sp[i++];
    if (i < n && sp[i] == '.') {
        i++;
        if (i >= n || sp[i] < '0' || sp[i] > '9') raise("ValueError", "Format specifier missing precision");
        s.prec = 0; while (i < n && sp[i] >= '0' && sp[i] <= '9') s.prec = s.prec * 10 + (sp[i++] - '0');
    }
    if (i < n) s.type = sp[i++];
    if (i < n) raise("ValueError", "Invalid format specifier '" + sp + "'");
    if (s.zero && !s.fill_given && !s.align) { s.fill = "0"; s.align = '='; }
    if (s.zero && !s.fill_given && s.align) { s.fill = "0"; }
    return s;
}

inline std::string group_digits(const std::string& d, char sep, int every) {
    if (!sep) return d;
    std::string r; int cnt = 0;
    for (size_t k = d.size(); k-- > 0;) { if (cnt && cnt % every == 0) r += sep; r += d[k]; cnt++; }
    return std::string(r.rbegin(), r.rend());
}
// Pads `prefix` (sign and base prefix) + `body` to spec.width.
inline std::string pad(const std::string& prefix, const std::string& body, const Spec& s, char default_align) {
    int64_t len = (int64_t)(str_width(prefix) + str_width(body));
    char al = s.align ? s.align : default_align;
    if (s.width <= len) return prefix + body;
    int64_t n = s.width - len;
    switch (al) {
        case '<': return prefix + body + repeat_str(s.fill, n);
        case '^': { int64_t l = n / 2; return repeat_str(s.fill, l) + prefix + body + repeat_str(s.fill, n - l); }
        case '=': return prefix + repeat_str(s.fill, n) + body;
        default:  return repeat_str(s.fill, n) + prefix + body;
    }
}
inline std::string sign_str(bool neg, char sign) {
    if (neg) return "-";
    if (sign == '+') return "+";
    if (sign == ' ') return " ";
    return "";
}
// Zero padding with a thousands separator pads the digits themselves
// (format(1234, '010,') == '00,001,234').
inline std::string zero_grouped(std::string digits, const std::string& prefix, const Spec& s, int every, const std::string& tail = "") {
    std::string g = group_digits(digits, s.grouping, every);
    while ((int64_t)(prefix.size() + g.size() + tail.size()) < s.width) {
        digits.insert(digits.begin(), '0');
        g = group_digits(digits, s.grouping, every);
    }
    return g;
}

inline std::string format_float(double x, Spec s);

inline std::string format_int(const FmtVal& v, Spec s) {
    char t = s.type;
    if (t == 'e' || t == 'E' || t == 'f' || t == 'F' || t == 'g' || t == 'G' || t == '%')
        return format_float(v.as_double(), s);
    if (t && t != 'b' && t != 'c' && t != 'd' && t != 'o' && t != 'x' && t != 'X' && t != 'n')
        raise("ValueError", std::string("Unknown format code '") + t + "' for object of type 'int'");
    if (s.grouping == ',' && t && t != 'd' && t != 'n') raise("ValueError", std::string("Cannot specify ',' with '") + t + "'.");
    BigInt b = v.as_big();
    if (t == 'c') {
        if (s.sign) raise("ValueError", "Sign not allowed with integer format specifier 'c'");
        int64_t cp; if (!b.to_i64(cp) || cp < 0 || cp > 0x10FFFF) raise("OverflowError", "%c arg not in range(0x110000)");
        return pad("", str_chr(cp), s, '>');
    }
    int base = t == 'b' ? 2 : t == 'o' ? 8 : (t == 'x' || t == 'X') ? 16 : 10;
    bool neg = b.neg;
    std::string digits;
    int64_t small;
    if (b.to_i64(small) && small != INT64_MIN) {
        uint64_t u = (uint64_t)(small < 0 ? -small : small);
        if (base == 10) digits = std::to_string(u);
        else { static const char* D = "0123456789abcdef"; if (!u) digits = "0"; while (u) { digits.insert(digits.begin(), D[u % (uint64_t)base]); u /= (uint64_t)base; } }
    } else {
        BigInt m = b; m.neg = false;
        digits = m.to_string(base);
    }
    if (t == 'X') for (auto& c : digits) c = (char)std::toupper((unsigned char)c);
    std::string prefix = sign_str(neg, s.sign);
    if (s.alt && base != 10) prefix += t == 'b' ? "0b" : t == 'o' ? "0o" : t == 'x' ? "0x" : "0X";
    int every = base == 10 ? 3 : 4;
    if (s.grouping && s.fill == "0" && s.align == '=' && s.width > 0)
        return prefix + zero_grouped(digits, prefix, s, every);
    return pad(prefix, group_digits(digits, s.grouping, every), s, '>');
}

// Digits and decimal exponent of |x| rounded to `sig` significant digits.
inline void sig_digits(double ax, int sig, std::string& digits, int& exp10) {
    char buf[512];
    snprintf(buf, sizeof buf, "%.*e", sig - 1, ax);
    std::string sci(buf);
    size_t e = sci.find('e');
    digits.clear();
    for (size_t k = 0; k < e; k++) if (sci[k] != '.') digits += sci[k];
    exp10 = std::atoi(sci.c_str() + e + 1);
}
inline std::string format_float(double x, Spec s) {
    char t = s.type;
    if (t && t != 'e' && t != 'E' && t != 'f' && t != 'F' && t != 'g' && t != 'G' && t != 'n' && t != '%')
        raise("ValueError", std::string("Unknown format code '") + t + "' for object of type 'float'");
    if (s.grouping == ',' && t == 'n') raise("ValueError", "Cannot specify ',' with 'n'.");
    bool neg = std::signbit(x);
    double ax = std::fabs(x);
    bool upper = (t == 'E' || t == 'F' || t == 'G');
    std::string body;
    if (std::isnan(x) || std::isinf(x)) {
        neg = std::signbit(x) && !std::isnan(x);
        body = std::isnan(x) ? "nan" : "inf";
        if (upper) body = std::isnan(x) ? "NAN" : "INF";
        if (t == '%') body += "%";
        return pad(sign_str(neg, s.sign), body, s, '>');
    }
    std::string tail;
    char buf[512];
    if (!t && s.prec < 0) {
        body = float_repr(ax);
    } else if (t == 'f' || t == 'F' || t == '%') {
        double v = t == '%' ? ax * 100.0 : ax;
        int p = s.prec < 0 ? 6 : (int)s.prec;
        snprintf(buf, sizeof buf, s.alt ? "%#.*f" : "%.*f", p, v);
        body = buf;
        if (t == '%') tail = "%";
    } else if (t == 'e' || t == 'E') {
        int p = s.prec < 0 ? 6 : (int)s.prec;
        snprintf(buf, sizeof buf, s.alt ? "%#.*e" : "%.*e", p, ax);
        body = buf;
    } else {
        // 'g', 'G', 'n', or no type with a precision.
        int p = s.prec < 0 ? 6 : (int)s.prec;
        if (p == 0) p = 1;
        bool add_dot0 = !t;
        std::string dg; int e10;
        sig_digits(ax, p, dg, e10);
        int decpt = e10 + 1;
        bool use_exp = decpt <= -4 || decpt > (add_dot0 ? p - 1 : p);
        if (!s.alt) { while (dg.size() > 1 && dg.back() == '0') dg.pop_back(); }
        if (use_exp) {
            body = dg.substr(0, 1);
            if (dg.size() > 1) body += "." + dg.substr(1);
            else if (s.alt) body += ".";
            char eb[16]; snprintf(eb, sizeof eb, "e%c%02d", e10 < 0 ? '-' : '+', e10 < 0 ? -e10 : e10);
            body += eb;
        } else {
            int nd = (int)dg.size();
            if (decpt <= 0) body = "0." + std::string((size_t)-decpt, '0') + dg;
            else if (decpt >= nd) { body = dg + std::string((size_t)(decpt - nd), '0'); if (s.alt) body += "."; }
            else body = dg.substr(0, (size_t)decpt) + "." + dg.substr((size_t)decpt);
            if (add_dot0 && body.find('.') == std::string::npos) body += ".0";
        }
    }
    if (upper) for (auto& c : body) c = (char)std::toupper((unsigned char)c);
    if (s.z && neg) {
        bool allzero = true;
        for (char c : body) if (c >= '1' && c <= '9') { allzero = false; break; }
        if (allzero) neg = false;
    }
    std::string prefix = sign_str(neg, s.sign);
    // Group the integer part only.
    if (s.grouping) {
        size_t ip = 0; while (ip < body.size() && body[ip] >= '0' && body[ip] <= '9') ip++;
        std::string intpart = body.substr(0, ip), rest = body.substr(ip) + tail;
        if (s.fill == "0" && s.align == '=' && s.width > 0)
            return prefix + zero_grouped(intpart, prefix, s, 3, rest) + rest;
        return pad(prefix, group_digits(intpart, s.grouping, 3) + rest, s, '>');
    }
    return pad(prefix, body + tail, s, '>');
}
inline std::string format_str(const std::string& str, const Spec& s) {
    if (s.type && s.type != 's') raise("ValueError", std::string("Unknown format code '") + s.type + "' for object of type 'str'");
    if (s.sign) raise("ValueError", "Sign not allowed in string format specifier");
    if (s.alt) raise("ValueError", "Alternate form (#) not allowed in string format specifier");
    if (s.grouping) raise("ValueError", std::string("Cannot specify '") + s.grouping + "' with 's'.");
    if (s.align == '=') raise("ValueError", "'=' alignment not allowed in string format specifier");
    std::string body = str;
    if (s.prec >= 0 && (int64_t)str_width(body) > s.prec) body = str_slice(body, true, 0, true, s.prec, 1);
    return pad("", body, s, '<');
}
// format(value, spec)
inline std::string format_value(const FmtVal& v, const std::string& spec) {
    if (v.done) return v.s;
    if (v.custom) return v.custom(spec);
    if (spec.empty()) {
        switch (v.kind) {
            case FmtVal::INT: return v.is_big ? v.big.to_string() : std::to_string(v.i);
            case FmtVal::FLOAT: return float_repr(v.d);
            default: return v.s;
        }
    }
    Spec s = parse_spec(spec);
    switch (v.kind) {
        case FmtVal::INT: return format_int(v, s);
        case FmtVal::FLOAT: return format_float(v.d, s);
        case FmtVal::BOOL:
            // bool.__format__ is int.__format__ once a spec is given.
            return format_int(FmtVal::of_int(v.b ? 1 : 0), s);
        case FmtVal::STR: return format_str(v.s, s);
        default:
            raise("TypeError", "unsupported format string passed to " + v.type_name + ".__format__");
    }
}

// ── str.format ──────────────────────────────────────────────────────────
struct FieldRef {
    bool numeric = false;
    int64_t index = 0;
    std::string name;
    std::vector<std::pair<char, std::string>> chain;   // ('.', attr) or ('[', key)
    std::string spec;   // the field's format spec, nested fields expanded (for __format__)
};
using FieldResolver = std::function<FmtVal(const FieldRef&, char conv)>;

inline std::string str_format_impl(const std::string& fmt, const FieldResolver& res, int64_t& auto_idx, int& mode, int depth) {
    if (depth > 2) raise("ValueError", "Max string recursion exceeded");
    std::string out;
    size_t i = 0, n = fmt.size();
    while (i < n) {
        char c = fmt[i];
        if (c == '{') {
            if (i + 1 < n && fmt[i+1] == '{') { out += '{'; i += 2; continue; }
            // Find the matching '}' (spec may contain nested {...}).
            size_t j = i + 1; int lvl = 1; bool in_brk = false;
            while (j < n) {
                char d = fmt[j];
                if (in_brk) { if (d == ']') in_brk = false; }
                else if (d == '[') in_brk = true;
                else if (d == '{') lvl++;
                else if (d == '}') { if (--lvl == 0) break; }
                j++;
            }
            if (j >= n) raise("ValueError", "expected '}' before end of string");
            std::string field = fmt.substr(i + 1, j - i - 1);
            i = j + 1;
            // field_name [!conv] [:spec]
            size_t k = 0; in_brk = false;
            while (k < field.size()) {
                char d = field[k];
                if (in_brk) { if (d == ']') in_brk = false; }
                else if (d == '[') in_brk = true;
                else if (d == '!' || d == ':') break;
                k++;
            }
            std::string name = field.substr(0, k);
            char conv = 0; std::string spec;
            if (k < field.size() && field[k] == '!') {
                if (k + 1 >= field.size()) raise("ValueError", "end of string while looking for conversion specifier");
                conv = field[k + 1];
                if (conv != 'r' && conv != 's' && conv != 'a') raise("ValueError", std::string("Unknown conversion specifier ") + conv);
                k += 2;
                if (k < field.size() && field[k] != ':') raise("ValueError", "expected ':' after conversion specifier");
            }
            if (k < field.size() && field[k] == ':') spec = field.substr(k + 1);
            // Parse the name: first part then .attr / [key] chain.
            FieldRef ref;
            size_t p = 0;
            while (p < name.size() && name[p] != '.' && name[p] != '[') p++;
            std::string first = name.substr(0, p);
            if (first.empty()) {
                if (mode == 2) raise("ValueError", "cannot switch from manual field specification to automatic field numbering");
                mode = 1; ref.numeric = true; ref.index = auto_idx++;
            } else if (std::all_of(first.begin(), first.end(), [](char ch) { return ch >= '0' && ch <= '9'; })) {
                if (mode == 1) raise("ValueError", "cannot switch from automatic field numbering to manual field specification");
                mode = 2; ref.numeric = true; ref.index = std::stoll(first);
            } else ref.name = first;
            while (p < name.size()) {
                if (name[p] == '.') {
                    size_t q = p + 1; while (q < name.size() && name[q] != '.' && name[q] != '[') q++;
                    ref.chain.push_back({'.', name.substr(p + 1, q - p - 1)}); p = q;
                } else if (name[p] == '[') {
                    size_t q = name.find(']', p);
                    if (q == std::string::npos) raise("ValueError", "Missing ']' in format string");
                    ref.chain.push_back({'[', name.substr(p + 1, q - p - 1)}); p = q + 1;
                } else raise("ValueError", "Only '.' or '[' may follow ']' in format field specifier");
            }
            if (spec.find('{') != std::string::npos) spec = str_format_impl(spec, res, auto_idx, mode, depth + 1);
            ref.spec = spec;
            out += format_value(res(ref, conv), spec);
        } else if (c == '}') {
            if (i + 1 < n && fmt[i+1] == '}') { out += '}'; i += 2; continue; }
            raise("ValueError", "Single '}' encountered in format string");
        } else { out += c; i++; }
    }
    return out;
}
inline std::string str_format(const std::string& fmt, const FieldResolver& res) {
    int64_t auto_idx = 0; int mode = 0;
    return str_format_impl(fmt, res, auto_idx, mode, 0);
}

// ── printf-style '%' ────────────────────────────────────────────────────
// get(index, key, conv): the argument at position `index` (key empty) or
// under `key`; conv is 's', 'r', 'a' (return its str/repr/ascii as STR) or 0
// (return the value itself as INT/FLOAT/BOOL/STR/...).
using PercentGetter = std::function<FmtVal(int64_t index, const std::string& key, char conv)>;
inline std::string percent_format(const std::string& fmt, int64_t nargs, bool is_mapping, const PercentGetter& get) {
    std::string out;
    int64_t ai = 0;
    bool used_key = false;
    size_t i = 0, n = fmt.size();
    auto next_arg = [&](char conv) -> FmtVal {
        if (ai >= nargs) raise("TypeError", "not enough arguments for format string");
        return get(ai++, "", conv);
    };
    while (i < n) {
        char c = fmt[i];
        if (c != '%') { out += c; i++; continue; }
        size_t start = i;
        i++;
        if (i >= n) raise("ValueError", "incomplete format");
        std::string key; bool has_key = false;
        if (fmt[i] == '(') {
            int lvl = 1; size_t j = i + 1;
            while (j < n && lvl) { if (fmt[j] == '(') lvl++; else if (fmt[j] == ')') lvl--; if (lvl) j++; }
            if (j >= n) raise("ValueError", "incomplete format key");
            key = fmt.substr(i + 1, j - i - 1); has_key = true; i = j + 1;
            if (!is_mapping) raise("TypeError", "format requires a mapping");
            used_key = true;
        }
        Spec s; bool left = false, zero = false;
        while (i < n && (fmt[i] == '-' || fmt[i] == '+' || fmt[i] == ' ' || fmt[i] == '#' || fmt[i] == '0')) {
            char f = fmt[i++];
            if (f == '-') left = true; else if (f == '+') s.sign = '+'; else if (f == ' ') { if (s.sign != '+') s.sign = ' '; }
            else if (f == '#') s.alt = true; else zero = true;
        }
        if (i < n && fmt[i] == '*') {
            FmtVal w = next_arg(0); i++;
            if (w.kind != FmtVal::INT) raise("TypeError", "* wants int");
            s.width = w.i; if (s.width < 0) { left = true; s.width = -s.width; }
        } else if (i < n && fmt[i] >= '0' && fmt[i] <= '9') {
            s.width = 0; while (i < n && fmt[i] >= '0' && fmt[i] <= '9') s.width = s.width * 10 + (fmt[i++] - '0');
        }
        if (i < n && fmt[i] == '.') {
            i++; s.prec = 0;
            if (i < n && fmt[i] == '*') { FmtVal p = next_arg(0); i++; if (p.kind != FmtVal::INT) raise("TypeError", "* wants int"); s.prec = p.i; }
            else while (i < n && fmt[i] >= '0' && fmt[i] <= '9') s.prec = s.prec * 10 + (fmt[i++] - '0');
        }
        while (i < n && (fmt[i] == 'h' || fmt[i] == 'l' || fmt[i] == 'L')) i++;
        if (i >= n) raise("ValueError", "incomplete format");
        char t = fmt[i++];
        if (t == '%') { out += '%'; continue; }
        if (left) s.align = '<';
        else if (zero && t != 's' && t != 'r' && t != 'a' && t != 'c') { s.fill = "0"; s.align = '='; }
        else s.align = '>';
        auto fetch = [&](char conv) { return has_key ? get(-1, key, conv) : next_arg(conv); };
        switch (t) {
            case 's': case 'r': case 'a': {
                FmtVal v = fetch(t);
                std::string body = v.s;
                if (s.prec >= 0 && (int64_t)str_width(body) > s.prec) body = str_slice(body, true, 0, true, s.prec, 1);
                out += pad("", body, s, '>');
                break;
            }
            case 'c': {
                FmtVal v = fetch(0);
                std::string ch;
                if (v.kind == FmtVal::INT) ch = str_chr(v.i);
                else if (v.kind == FmtVal::STR && u8_len(v.s) == 1) ch = v.s;
                else raise("TypeError", "%c requires int or char");
                out += pad("", ch, s, '>');
                break;
            }
            case 'd': case 'i': case 'u': case 'o': case 'x': case 'X': {
                FmtVal v = fetch(0);
                if (!v.is_numeric()) raise("TypeError", std::string("%") + t + " format: a real number is required, not " + v.type_name);
                FmtVal iv = v.kind == FmtVal::FLOAT ? FmtVal::of_big(BigInt::from_double(v.d)) : v.kind == FmtVal::BOOL ? FmtVal::of_int(v.b) : v;
                Spec s2 = s; s2.type = (t == 'i' || t == 'u') ? 'd' : t;
                if (s2.prec >= 0) {
                    // Precision on an integer is a minimum digit count.
                    Spec s3; s3.type = s2.type; s3.alt = false;
                    std::string digits = format_int(iv, s3);
                    bool ng = !digits.empty() && digits[0] == '-';
                    if (ng) digits.erase(0, 1);
                    while ((int64_t)digits.size() < s2.prec) digits.insert(digits.begin(), '0');
                    std::string prefix = sign_str(ng, s2.sign);
                    if (s2.alt && t != 'd' && t != 'i' && t != 'u') prefix += t == 'o' ? "0o" : t == 'x' ? "0x" : "0X";
                    out += pad(prefix, digits, s2, '>');
                } else out += format_int(iv, s2);
                break;
            }
            case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': {
                FmtVal v = fetch(0);
                if (!v.is_numeric()) raise("TypeError", std::string("must be real number, not ") + v.type_name);
                Spec s2 = s; s2.type = t;
                out += format_float(v.as_double(), s2);
                break;
            }
            default: {
                char hb[128]; snprintf(hb, sizeof hb, "unsupported format character '%c' (0x%x) at index %zu", t, (unsigned)(unsigned char)t, i - 1);
                (void)start;
                raise("ValueError", hb);
            }
        }
    }
    if (!is_mapping && ai < nargs) raise("TypeError", "not all arguments converted during string formatting");
    (void)used_key;
    return out;
}

// ── round() ─────────────────────────────────────────────────────────────
// round(x, ndigits) for floats: correctly rounded decimal, ties to even on
// the exact binary value (Python's round(2.675, 2) == 2.67).
inline double round_ndigits(double x, int64_t nd) {
    if (std::isnan(x) || std::isinf(x) || x == 0.0) return x;
    if (nd > 330) return x;
    if (nd >= 0) {
        char buf[512];
        snprintf(buf, sizeof buf, "%.*f", (int)nd, x);
        double r = std::strtod(buf, nullptr);
        if (r == 0.0) r = std::copysign(0.0, x);
        return r;
    }
    if (nd < -330) return std::copysign(0.0, x);
    double p = std::pow(10.0, (double)-nd);
    double y = x / p;
    double z = std::nearbyint(y);
    if (std::fabs(y - std::trunc(y)) == 0.5) z = 2.0 * std::nearbyint(y / 2.0);
    double r = z * p;
    if (r == 0.0) r = std::copysign(0.0, x);
    return r;
}

// ── int() / float() parsing ─────────────────────────────────────────────
// Python int(str, base): surrounding whitespace, sign, optional 0x/0o/0b
// prefix (base 0 or matching base), single underscores between digits.
inline bool parse_int_str(const std::string& in, int base, BigInt& out) {
    size_t a = 0, b = in.size();
    size_t n;
    while (a < b && ws_at(in, a, n)) a += n;
    while (b > a) {
        size_t k = b - 1; while (k > a && ((unsigned char)in[k] & 0xC0) == 0x80) k--;
        if (ws_at(in, k, n) && k + n == b) b = k; else break;
    }
    std::string s = in.substr(a, b - a);
    if (s.empty()) return false;
    bool neg = false; size_t i = 0;
    if (s[0] == '+' || s[0] == '-') { neg = s[0] == '-'; i = 1; }
    auto has_prefix = [&](char p) { return i + 1 < s.size() && s[i] == '0' && (s[i+1] == p || s[i+1] == (char)std::toupper((unsigned char)p)); };
    if (base == 0) {
        if (has_prefix('x')) { base = 16; i += 2; }
        else if (has_prefix('o')) { base = 8; i += 2; }
        else if (has_prefix('b')) { base = 2; i += 2; }
        else {
            base = 10;
            // Base 0 forbids leading zeros on a non-zero decimal.
            std::string rest = s.substr(i);
            bool allz = true; for (char ch : rest) if (ch != '0' && ch != '_') { allz = false; break; }
            if (rest.size() > 1 && rest[0] == '0' && !allz) return false;
        }
        if (i < s.size() && s[i] == '_') i++;
    } else if ((base == 16 && has_prefix('x')) || (base == 8 && has_prefix('o')) || (base == 2 && has_prefix('b'))) {
        i += 2;
        if (i < s.size() && s[i] == '_') i++;
    }
    if (base < 2 || base > 36) return false;
    std::string digits;
    bool prev_us = true;
    for (; i < s.size(); i++) {
        char ch = s[i];
        if (ch == '_') { if (prev_us) return false; prev_us = true; continue; }
        prev_us = false;
        digits += ch;
    }
    if (digits.empty() || prev_us) return false;
    if (!BigInt::parse(digits, base, out)) return false;
    if (neg) out = -out;
    return true;
}
// int(s) with no base: decimal, as in Python, and also a 0x/0o/0b prefixed
// number - Nython's int("0xFF") == 255, which Python spells int(s, 0).
inline bool parse_int_default(const std::string& s, BigInt& out) {
    if (parse_int_str(s, 10, out)) return true;
    size_t i = s.find_first_not_of(" \t\n\r\f\v");
    if (i != std::string::npos && (s[i] == '+' || s[i] == '-')) i++;
    if (i == std::string::npos || i + 1 >= s.size() || s[i] != '0') return false;
    char p = (char)std::tolower((unsigned char)s[i + 1]);
    if (p != 'x' && p != 'o' && p != 'b') return false;
    return parse_int_str(s, 0, out);
}
// An integer literal's text (decimal, 0x/0o/0b, underscores, leading zeros
// allowed as the lexer passes them) to its exact value; 0 if malformed.
inline BigInt parse_int_literal(const std::string& v) {
    BigInt out;
    int base = 10;
    std::string digits = v;
    if (v.size() > 2 && v[0] == '0') {
        char p = (char)std::tolower((unsigned char)v[1]);
        if (p == 'x') base = 16; else if (p == 'o') base = 8; else if (p == 'b') base = 2;
        if (base != 10) digits = v.substr(2);
    }
    std::string clean;
    for (char c : digits) if (c != '_') clean += c;
    if (!BigInt::parse(clean, base, out)) return BigInt();
    return out;
}
inline bool parse_float_str(const std::string& in, double& out) {
    size_t a = 0, b = in.size(), n;
    while (a < b && ws_at(in, a, n)) a += n;
    while (b > a && ws_at(in, b - 1, n)) b--;
    std::string s = in.substr(a, b - a);
    if (s.empty()) return false;
    std::string low = str_lower(s);
    size_t i = 0; bool neg = false;
    if (low[0] == '+' || low[0] == '-') { neg = low[0] == '-'; i = 1; }
    std::string body = low.substr(i);
    if (body == "inf" || body == "infinity") { out = neg ? -INFINITY : INFINITY; return true; }
    if (body == "nan") { out = NAN; return true; }
    // Digits, one '.', exponent; underscores only between digits.
    std::string clean;
    bool prev_digit = false, seen_digit = false;
    for (size_t k = 0; k < s.size(); k++) {
        char ch = s[k];
        if (ch == '_') {
            if (!prev_digit || k + 1 >= s.size() || !std::isdigit((unsigned char)s[k+1])) return false;
            continue;
        }
        prev_digit = std::isdigit((unsigned char)ch) != 0;
        if (prev_digit) seen_digit = true;
        if (!(prev_digit || ch == '.' || ch == 'e' || ch == 'E' || ch == '+' || ch == '-')) return false;
        clean += ch;
    }
    if (!seen_digit) return false;
    char* end = nullptr;
    out = std::strtod(clean.c_str(), &end);
    return end && *end == 0;
}

} // namespace nypy
