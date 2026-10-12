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
