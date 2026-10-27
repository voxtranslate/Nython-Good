// builtins/nyunicode.cpp (round 84) - the native side of lib/unicodedata.ny,
// over the database of include/NyUniData.hpp (src/NyUniData.cpp):
//
//   _ny_ucd(op, arg, old)   old: true for unicodedata.ucd_3_2_0
//     "category" / "bidirectional" / "east_asian_width" / "decomposition"
//         (chr) -> str
//     "combining" / "mirrored" (chr) -> int
//     "decimal" / "digit" (chr) -> int, None when the character has none
//     "numeric" (chr) -> float, None when it has none
//     "name" (chr) -> str, "" when it has none
//     "lookup" (name) -> str (a character or a named sequence), None
//     "normalize" / "is_normalized" (form, str) -> str / bool
//     "stream_safe" (str) -> str (UAX #15's Stream-Safe Text Format)
//
// lib/unicodedata.ny checks the arguments (CPython's TypeErrors) and turns
// None into the default or the ValueError. Registered through the hashing
// bridge (hash_builtin_names), as the codecs' native is, so both engines
// have it.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyUniData.hpp"
#include "NyUniNames.hpp"
#include "builtins/os.hpp"
#include <string>
#include <vector>

using namespace nython;
using namespace nython::kernel;

std::vector<std::string> ucd_builtin_names() { return {"_ny_ucd", "_ny_mbc"}; }
Value dispatch_mbc(NythonExecutor& E, std::vector<Value>& args);   // builtins/nycjk.cpp

namespace {
std::vector<uint32_t> cps_of(const std::string& s) {
    std::vector<uint32_t> r;
    r.reserve(s.size());
    for (size_t i = 0; i < s.size();) r.push_back(nypy::u8_decode(s, i));
    return r;
}
std::string utf8_of(const std::vector<uint32_t>& cps) {
    std::string r;
    r.reserve(cps.size());
    for (uint32_t c : cps) nypy::u8_encode(c, r);
    return r;
}
}  // namespace

Value dispatch_ucd(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name == "_ny_mbc") return dispatch_mbc(E, args);   // the CJK codecs (builtins/nycjk.cpp)
    if (name != "_ny_ucd") return UNDEFINED_VALUE;
    auto S = [&](size_t i) -> std::string { return i < args.size() ? E.getStringValue(args[i]) : std::string(); };
    std::string op = S(0);
    if (op == "normalize" || op == "is_normalized") {
        bool old = args.size() > 3 && E.isTruthy(args[3]);
        std::string s = S(2);
        if (s.empty()) return op == "normalize" ? E.makeStringValue(s) : Value(true);   // (before the form, as CPython)
        nyucd::Form f;
        if (!nyucd::form_of(S(1), f)) nyos::raise("ValueError", "invalid normalization form");
        if (op == "normalize") return E.makeStringValue(nyucd::normalize_utf8(f, s, old));
        return Value(nyucd::is_normalized(f, cps_of(s), old));
    }
    bool old = args.size() > 2 && E.isTruthy(args[2]);
    if (op == "lookup") {
        std::vector<uint32_t> out;
        if (!nyuni::lookup_seq(S(1), out, old)) return NONE_VALUE;
        return E.makeStringValue(utf8_of(out));
    }
    if (op == "stream_safe") return E.makeStringValue(utf8_of(nyucd::stream_safe(cps_of(S(1)))));
    std::string ch = S(1);
    size_t i = 0;
    uint32_t c = ch.empty() ? 0 : nypy::u8_decode(ch, i);
    if (op == "category") return E.makeStringValue(old ? nyucd::category_3_2_0(c) : nyucd::category(c));
    if (op == "bidirectional") return E.makeStringValue(old ? nyucd::bidirectional_3_2_0(c) : nyucd::bidirectional(c));
    if (op == "east_asian_width") return E.makeStringValue(old ? nyucd::east_asian_width_3_2_0(c) : nyucd::east_asian_width(c));
    if (op == "decomposition") return E.makeStringValue(old ? nyucd::decomposition_3_2_0(c) : nyucd::decomposition(c));
    if (op == "combining") return nyos::make_int(old ? nyucd::combining_3_2_0(c) : nyucd::combining(c));
    if (op == "mirrored") return nyos::make_int(old ? nyucd::mirrored_3_2_0(c) : nyucd::mirrored(c));
    if (op == "decimal") {
        int v = old ? nyucd::decimal_3_2_0(c) : nyucd::to_decimal(c);
        return v < 0 ? NONE_VALUE : nyos::make_int(v);
    }
    if (op == "digit") {
        int v = nyucd::to_digit(c);   // (CPython's ucd_3_2_0.digit is the current one)
        return v < 0 ? NONE_VALUE : nyos::make_int(v);
    }
    if (op == "numeric") {
        double v = old ? nyucd::numeric_3_2_0(c) : nyucd::to_numeric(c);
        return v == -1.0 ? NONE_VALUE : Value(v);
    }
    if (op == "name") return E.makeStringValue(old ? nyuni::name_3_2_0(c) : nyuni::name(c));
    nyos::raise("ValueError", "_ny_ucd: unknown operation '" + op + "'");
}
