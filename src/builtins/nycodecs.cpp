// builtins/nycodecs.cpp (round 80) - the native side of lib/codecs.ny:
//
//   _ny_codec("lookup", encoding) -> the native codec's CodecInfo name, or
//       None when no native codec has that name (lib/codecs.ny then asks the
//       codecs registered in Nython: idna, hex, base64, zlib, quopri, rot13,
//       anything codecs.register adds)
//   _ny_codec("encode", encoding, str, errors, final, start)
//       -> (bytes, characters consumed, error, None)
//   _ny_codec("decode", encoding, bytes, errors, final, start)
//       -> (str, bytes consumed, error, "le" | "be" | None)
//
// errors is a builtin handler's name, or "__ny_stop__": the codec stops at
// the first error and returns it as (start, end, reason, codec name) -
// lib/codecs.ny calls a handler registered with codecs.register_error
// there and resumes where the handler says. final=False leaves an
// incomplete sequence at the end unconsumed (incremental decoders).
// Registered through the hashing bridge (hash_builtin_names), as zlib's
// natives are, so both engines have it.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyCodecs.hpp"
#include "builtins/os.hpp"
#include <string>
#include <vector>

using namespace nython;
using namespace nython::kernel;

std::vector<std::string> codec_builtin_names() { return {"_ny_codec"}; }

#ifdef _WIN32
// ── Windows code pages (round 84): mbcs (CP_ACP), oem (CP_OEMCP) and
// codecs.code_page_encode/decode, CPython's encode_code_page /
// decode_code_page_stateful (Objects/unicodeobject.c) over
// WideCharToMultiByte / MultiByteToWideChar: the whole input at once in
// strict mode, then character by character with the error handler. A
// handler registered with codecs.register_error is lib/codecs.ny's: with
// errors "__ny_stop__" the codec stops at the error (CxErr) and returns it.
namespace {
std::string cp_name(unsigned cp) {
    if (cp == CP_ACP) return "mbcs";
    if (cp == CP_UTF7) return "CP_UTF7";
    if (cp == CP_UTF8) return "CP_UTF8";
    return "cp" + std::to_string(cp);
}
std::wstring wide_of(const std::vector<uint32_t>& cps, size_t a, size_t b) {
    std::wstring w;
    for (size_t i = a; i < b; i++) {
        uint32_t c = cps[i];
        if (c >= 0x10000) { c -= 0x10000; w += (wchar_t)(0xD800 + (c >> 10)); w += (wchar_t)(0xDC00 + (c & 0x3FF)); }
        else w += (wchar_t)c;
    }
    return w;
}
std::string utf8_of_wide(const wchar_t* w, size_t n) {
    std::string r;
    for (size_t i = 0; i < n; i++) {
        uint32_t c = (uint16_t)w[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n && (uint16_t)w[i + 1] >= 0xDC00 && (uint16_t)w[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + ((uint16_t)w[i + 1] - 0xDC00);
            i++;
        }
        nypy::u8_encode(c, r);
    }
    return r;
}
// (str, consumed); err filled for the "stop" handler
std::string cp_decode(unsigned cp, const std::string& in, size_t start, const std::string& errors, bool final,
                      size_t& consumed, nypy::CxErr& err) {
    const char* reason = "No mapping for the Unicode character exists in the target code page.";
    std::string name = cp_name(cp);
    std::string out;
    consumed = start;
    if (start >= in.size()) return out;
    const char* p = in.data() + start;
    int size = (int)(in.size() - start);
    DWORD flags = cp == CP_UTF7 ? 0 : MB_ERR_INVALID_CHARS;
    // strict, the whole input
    int n = MultiByteToWideChar(cp, flags, p, size, nullptr, 0);
    if (n <= 0 && flags && GetLastError() == ERROR_INVALID_FLAGS) { flags = 0; n = MultiByteToWideChar(cp, flags, p, size, nullptr, 0); }
    if (n > 0) {
        std::wstring w((size_t)n, L'\0');
        MultiByteToWideChar(cp, flags, p, size, &w[0], n);
        consumed = in.size();
        return utf8_of_wide(w.data(), w.size());
    }
    if (GetLastError() != ERROR_NO_UNICODE_TRANSLATION) nyos::raise("OSError", "[WinError " + std::to_string(GetLastError()) + "] MultiByteToWideChar failed");
    if ((errors.empty() || errors == "strict") && final) nypy::cx_raise_decode(name.c_str(), in, 0, 0, reason);
    size_t i = start;
    while (i < in.size()) {
        wchar_t buf[2];
        int got = 0;
        size_t k = 1;
        do {
            got = MultiByteToWideChar(cp, flags, in.data() + i, (int)k, buf, 2);
            if (got > 0) break;
            DWORD e = GetLastError();
            if (e == ERROR_INVALID_FLAGS && flags) { flags = 0; continue; }
            if (e != ERROR_NO_UNICODE_TRANSLATION && e != ERROR_INSUFFICIENT_BUFFER)
                nyos::raise("OSError", "[WinError " + std::to_string(e) + "] MultiByteToWideChar failed");
            k++;
        } while (k <= 4 && i + k <= in.size());
        if (got > 0) { out += utf8_of_wide(buf, (size_t)got); i += k; continue; }
        if (i + k >= in.size() && !final) break;   // the last character, partial
        static const char* hx = "0123456789abcdef";
        if (errors == "ignore") { i++; continue; }
        if (errors == "replace") { out += "\xEF\xBF\xBD"; i++; continue; }
        if (errors == "backslashreplace") {
            unsigned char x = (unsigned char)in[i];
            out += "\\x"; out += hx[x >> 4]; out += hx[x & 15];
            i++;
            continue;
        }
        if (errors == "surrogateescape" && (unsigned char)in[i] >= 0x80) { nypy::u8_encode(0xDC00u + (unsigned char)in[i], out); i++; continue; }
        if (errors == "__ny_stop__") { err.hit = true; err.start = (int64_t)i; err.end = (int64_t)i + 1; err.reason = reason; err.codec = name; break; }
        if (errors == "xmlcharrefreplace" || errors == "namereplace")
            nyos::raise("TypeError", "don't know how to handle UnicodeDecodeError in error callback");
        nypy::cx_raise_decode(name.c_str(), in, (int64_t)i, (int64_t)i + 1, reason);
    }
    consumed = i;
    return out;
}
std::string cp_encode(unsigned cp, const std::string& s, size_t start, const std::string& errors, size_t& consumed,
                      nypy::CxErr& err) {
    const char* reason = "invalid character";
    std::string name = cp_name(cp);
    std::vector<uint32_t> cps = nypy::cx_codepoints(s);
    std::string out;
    consumed = start;
    if (start >= cps.size()) { consumed = cps.size(); return out; }
    BOOL used = FALSE;
    BOOL* pused = (cp != CP_UTF8 && cp != CP_UTF7) ? &used : nullptr;
    DWORD sflags = cp == CP_UTF8 ? 0x80 /* WC_ERR_INVALID_CHARS */ : cp == CP_UTF7 ? 0 : WC_NO_BEST_FIT_CHARS;
    std::wstring w = wide_of(cps, start, cps.size());
    int n = WideCharToMultiByte(cp, sflags, w.data(), (int)w.size(), nullptr, 0, nullptr, pused);
    if (n > 0 && !(pused && *pused)) {
        out.resize((size_t)n);
        WideCharToMultiByte(cp, sflags, w.data(), (int)w.size(), &out[0], n, nullptr, pused);
        if (!(pused && *pused)) { consumed = cps.size(); return out; }
        out.clear();
    }
    else if (n <= 0 && GetLastError() != ERROR_NO_UNICODE_TRANSLATION)
        nyos::raise("OSError", "[WinError " + std::to_string(GetLastError()) + "] WideCharToMultiByte failed");
    if (errors.empty() || errors == "strict") nypy::cx_raise_encode(name.c_str(), s, cps, 0, 0, reason);
    DWORD flags = cp == CP_UTF8 ? 0x80 : cp == CP_UTF7 ? 0 : (errors == "replace" ? 0 : WC_NO_BEST_FIT_CHARS);
    size_t pos = start;
    while (pos < cps.size()) {
        std::wstring one = wide_of(cps, pos, pos + 1);
        char buf[8];
        used = FALSE;
        int got = WideCharToMultiByte(cp, flags, one.data(), (int)one.size(), buf, (int)sizeof buf, nullptr, pused);
        if (got > 0 && !(pused && *pused)) { out.append(buf, (size_t)got); pos++; continue; }
        if (got <= 0 && GetLastError() != ERROR_NO_UNICODE_TRANSLATION)
            nyos::raise("OSError", "[WinError " + std::to_string(GetLastError()) + "] WideCharToMultiByte failed");
        std::string rep;
        bool bytes_rep = false;
        uint32_t ch = cps[pos];
        if (errors == "ignore") rep = "";
        else if (errors == "replace") rep = "?";
        else if (errors == "backslashreplace") rep = nypy::cx_charrepr(ch);
        else if (errors == "xmlcharrefreplace") rep = "&#" + std::to_string(ch) + ";";
        else if (errors == "namereplace") { std::string nm = nyuni::name(ch); rep = nm.empty() ? nypy::cx_charrepr(ch) : "\\N{" + nm + "}"; }
        else if (errors == "surrogateescape" && ch >= 0xDC80 && ch <= 0xDCFF) { rep = std::string(1, (char)(ch - 0xDC00)); bytes_rep = true; }
        else if (errors == "__ny_stop__") { err.hit = true; err.start = (int64_t)pos; err.end = (int64_t)pos + 1; err.reason = reason; err.codec = name; break; }
        else nypy::cx_raise_encode(name.c_str(), s, cps, (int64_t)pos, (int64_t)pos + 1, reason);
        if (!bytes_rep)
            for (unsigned char c : rep)
                if (c > 127) nypy::cx_raise_encode(name.c_str(), s, cps, (int64_t)pos, (int64_t)pos + 1, "unable to encode error handler result to ASCII");
        out += rep;
        pos++;
    }
    consumed = pos;
    return out;
}
}  // namespace
#endif

Value dispatch_codec(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name != "_ny_codec") return UNDEFINED_VALUE;
    auto S = [&](size_t i) -> std::string { return i < args.size() ? E.getStringValue(args[i]) : std::string(); };
    auto tuple = [&](const std::vector<Value>& items) {
        Value t = nyos::make_list(E, items);
        if (auto* o = dynamic_cast<Object*>((Collectable*)t.value.p)) o->set("__tuple__", Value(1));
        return t;
    };
    std::string op = S(0);
    // round 84: Windows' code pages - ("cp_encode" | "cp_decode", code page,
    // input, errors, final, start) -> (output, consumed, error); ("acp")
    // -> GetACP(); elsewhere they are not there, as CPython's
    if (op == "acp" || op == "cp_encode" || op == "cp_decode") {
#ifdef _WIN32
        if (op == "acp") return nyos::make_int((long long)GetACP());
        long long cpn = args.size() > 1 ? nyos::to_int(args[1], 0) : 0;
        if (cpn < 0) nyos::raise("ValueError", "invalid code page number");
        std::string errors = args.size() > 3 && args[3].type != ValueType::NONE ? S(3) : std::string("strict");
        bool final = args.size() <= 4 || E.isTruthy(args[4]);
        long long start = args.size() > 5 ? nyos::to_int(args[5], 0) : 0;
        if (start < 0) start = 0;
        nypy::CxErr err;
        size_t used = 0;
        Value out;
        if (op == "cp_encode") {
            std::string s = args.size() > 2 ? E.getStringValue(args[2]) : std::string();
            out = E.makeBytesValue(E.nyCall([&] { return cp_encode((unsigned)cpn, s, (size_t)start, errors, used, err); }));
        } else {
            auto* bo = args.size() > 2 ? E.bytesOf(args[2]) : nullptr;
            if (!bo) nyos::raise("TypeError", "a bytes-like object is required, not '" + (args.size() > 2 ? E.typeNameOf(args[2]) : std::string("NoneType")) + "'");
            std::string data = bo->s;
            out = E.makeStringValue(E.nyCall([&] { return cp_decode((unsigned)cpn, data, (size_t)start, errors, final, used, err); }));
        }
        Value ev = NONE_VALUE;
        if (err.hit) ev = tuple({nyos::make_int(err.start), nyos::make_int(err.end), E.makeStringValue(err.reason), E.makeStringValue(err.codec)});
        return tuple({out, nyos::make_int((long long)used), ev});
#else
        nyos::raise("AttributeError", "module 'codecs' has no attribute 'code_page_encode'");
#endif
    }
    std::string encoding = S(1);
    nypy::Cx c;
    bool found = nypy::codec_find(encoding, c);
    if (op == "lookup") return found ? E.makeStringValue(nypy::cx_name(c)) : NONE_VALUE;
    if (!found) nyos::raise("LookupError", "unknown encoding: " + encoding);
    std::string errors = args.size() > 3 && args[3].type != ValueType::NONE ? S(3) : std::string("strict");
    nypy::EH eh;
    if (!nypy::eh_find(errors, eh)) nyos::raise("LookupError", "unknown error handler name '" + errors + "'");
    bool final = args.size() <= 4 || E.isTruthy(args[4]);
    long long start = args.size() > 5 ? nyos::to_int(args[5], 0) : 0;
    if (start < 0) start = 0;
    nypy::CxErr err;
    size_t used = 0;
    Value out;
    Value extra = NONE_VALUE;
    if (op == "encode") {
        std::string s = args.size() > 2 ? E.getStringValue(args[2]) : std::string();
        std::string r = E.nyCall([&] { return nypy::codec_encode(c, s, eh, (size_t)start, used, err); });
        out = E.makeBytesValue(r);
    } else if (op == "decode") {
        auto* bo = args.size() > 2 ? E.bytesOf(args[2]) : nullptr;
        if (!bo) nyos::raise("TypeError", "a bytes-like object is required, not '" + (args.size() > 2 ? E.typeNameOf(args[2]) : std::string("NoneType")) + "'");
        bool little = true;
        std::string data = bo->s;
        if ((size_t)start > data.size()) start = (long long)data.size();
        std::string r = E.nyCall([&] { return nypy::codec_decode(c, data, eh, final, (size_t)start, used, err, &little); });
        out = E.makeStringValue(r);
        if (nypy::cx_is_utf16(c) || nypy::cx_is_utf32(c)) extra = E.makeStringValue(little ? "le" : "be");
    } else {
        nyos::raise("ValueError", "_ny_codec: unknown operation '" + op + "'");
    }
    Value ev = NONE_VALUE;
    if (err.hit)
        ev = tuple({nyos::make_int(err.start), nyos::make_int(err.end), E.makeStringValue(err.reason), E.makeStringValue(err.codec)});
    return tuple({out, nyos::make_int((long long)used), ev, extra});
}
