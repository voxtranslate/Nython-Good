#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/os_time.cpp
// Time: clocks, sleeping, formatting and parsing (Python's time + the
// datetime basics). One implementation for both engines: the VM reaches it
// through the builtin bridge. The VM used to carry its own copies, and
// `import time` / `import nytorch` swapped them in at runtime - time_ms()
// then returned SECONDS, time_now() whole seconds, and sleep(0.5) did not
// sleep at all.
//
//   time() / time_now() / time_timestamp()   float seconds since the epoch
//   time_ms()                                float milliseconds since the epoch
//   time_ns()                                int nanoseconds since the epoch
//   time_monotonic() / monotonic()           float seconds, never goes back
//   time_perf_counter() / perf_counter()     float seconds, highest resolution
//   time_process() / process_time()          float CPU seconds of this process
//   time_clock() / clock()                   float seconds since the epoch (legacy)
//   time_elapsed()                           float seconds since the program started
//   sleep(s) / time_sleep(s) / sleep_ms(ms)  (sleep lives in threading.cpp)
//   time_format(fmt="%Y-%m-%d %H:%M:%S", ts=now, utc=false)   also time_strftime,
//                                            time_date; "%f" is microseconds
//   time_localtime(ts=now) / time_gmtime(ts=now) -> {year, month, day, hour,
//                                            minute, second, weekday (Mon=0),
//                                            yearday (1..366), isdst, timestamp}
//   time_mktime(map) (local) / time_timegm(map) (UTC) -> float seconds
//   time_strptime(text, fmt) -> map as above; ValueError when it does not match
//   time_iso(ts=now, utc=true) -> "2026-09-26T13:31:05.123Z" / "...+02:00"
//   time_parse_iso(text) -> float seconds
//   uuid() / gen_uuid() -> RFC 4122 version-4 UUID string
// ─────────────────────────────────────────────────────────────────────────────

#include "platform_compat.hpp"

#include <chrono>
#include <thread>
#include <ctime>
#include <cstring>
#include <cmath>
#include <random>
#include <sstream>
#include <iomanip>
#include <string>
#include <vector>

#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include "NyRuntime.hpp"

using namespace std;
using namespace nython;
using namespace nython::kernel;

namespace {

using nyos::raise;
using nyos::make_int;

// Program start, for time_elapsed(). Initialised at load time, not on the
// first call (which made the first call always return 0).
const auto g_start = std::chrono::steady_clock::now();

double now_seconds() {
    auto us = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    return (double)us / 1e6;
}

bool to_tm(double ts, bool utc, std::tm& out) {
    std::time_t t = (std::time_t)std::floor(ts);
#ifdef _WIN32
    return (utc ? gmtime_s(&out, &t) : localtime_s(&out, &t)) == 0;
#else
    return (utc ? gmtime_r(&t, &out) : localtime_r(&t, &out)) != nullptr;
#endif
}

std::time_t timegm_portable(std::tm* tm) {
#ifdef _WIN32
    return _mkgmtime(tm);
#else
    return ::timegm(tm);
#endif
}

// strftime with a growing buffer (it used a fixed 64-byte buffer and ignored
// the return value, so a long result came back as garbage bytes) and "%f"
// for microseconds.
std::string format_time(const std::string& fmt_in, double ts, bool utc) {
    std::tm tm{};
    if (!to_tm(ts, utc, tm)) raise("OverflowError", "timestamp out of range for platform time_t");
    std::string fmt;
    long us = (long)std::llround((ts - std::floor(ts)) * 1e6);
    if (us >= 1000000) us = 999999;
    for (size_t i = 0; i < fmt_in.size(); i++) {
        if (fmt_in[i] == '%' && i + 1 < fmt_in.size()) {
            if (fmt_in[i + 1] == 'f') {
                char b[32]; std::snprintf(b, sizeof b, "%06ld", us);
                fmt += b; i++; continue;
            }
            fmt += fmt_in[i]; fmt += fmt_in[i + 1]; i++; continue;
        }
        fmt += fmt_in[i];
    }
    if (fmt.empty()) return "";
    // strftime returns 0 both for "does not fit" and for an empty result;
    // a trailing sentinel tells the two apart.
    std::string f2 = fmt + "\x01";
    std::vector<char> buf(std::max<size_t>(64, f2.size() * 4));
    for (int tries = 0; tries < 8; tries++) {
        size_t n = std::strftime(buf.data(), buf.size(), f2.c_str(), &tm);
        if (n > 0) return std::string(buf.data(), n - 1);
        buf.resize(buf.size() * 4);
    }
    return "";
}

Value tm_map(NythonExecutor& E, const std::tm& tm, double ts) {
    return nyos::make_map(E, {
        {"year",    Value(tm.tm_year + 1900)},
        {"month",   Value(tm.tm_mon + 1)},
        {"day",     Value(tm.tm_mday)},
        {"hour",    Value(tm.tm_hour)},
        {"minute",  Value(tm.tm_min)},
        {"second",  Value(tm.tm_sec)},
        {"weekday", Value((tm.tm_wday + 6) % 7)},    // Monday == 0, as in Python
        {"yearday", Value(tm.tm_yday + 1)},
        {"isdst",   Value(tm.tm_isdst > 0 ? 1 : (tm.tm_isdst == 0 ? 0 : -1))},
        {"timestamp", Value(ts)},
    });
}

std::tm map_tm(NythonExecutor& E, const Value& m) {
    std::tm tm{};
    tm.tm_isdst = -1;
    tm.tm_mday = 1;
    for (auto& kv : nyos::map_items(m)) {
        long long v = nyos::to_int(kv.second, 0);
        if (kv.first == "year") tm.tm_year = (int)v - 1900;
        else if (kv.first == "month") tm.tm_mon = (int)v - 1;
        else if (kv.first == "day") tm.tm_mday = (int)v;
        else if (kv.first == "hour") tm.tm_hour = (int)v;
        else if (kv.first == "minute") tm.tm_min = (int)v;
        else if (kv.first == "second") tm.tm_sec = (int)v;
        else if (kv.first == "isdst") tm.tm_isdst = (int)v;
    }
    (void)E;
    return tm;
}

// strptime for the common directives, identical on every platform (glibc's
// strptime is not available on Windows, and std::get_time is locale-bound).
bool parse_num(const std::string& s, size_t& i, int maxw, int& out) {
    size_t st = i;
    int v = 0;
    while (i < s.size() && (int)(i - st) < maxw && std::isdigit((unsigned char)s[i])) v = v * 10 + (s[i++] - '0');
    if (i == st) return false;
    out = v;
    return true;
}
bool strptime_portable(const std::string& s, const std::string& fmt, std::tm& tm, double& frac) {
    static const char* mon[] = {"jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"};
    static const char* wd[]  = {"sun","mon","tue","wed","thu","fri","sat"};
    size_t i = 0;
    int pm = -1;
    for (size_t f = 0; f < fmt.size(); f++) {
        char c = fmt[f];
        if (c != '%') {
            if (std::isspace((unsigned char)c)) { while (i < s.size() && std::isspace((unsigned char)s[i])) i++; continue; }
            if (i >= s.size() || s[i] != c) return false;
            i++; continue;
        }
        if (++f >= fmt.size()) return false;
        int v = 0;
        switch (fmt[f]) {
            case 'Y': if (!parse_num(s, i, 4, v)) return false; tm.tm_year = v - 1900; break;
            case 'y': if (!parse_num(s, i, 2, v)) return false; tm.tm_year = v < 69 ? v + 100 : v; break;
            case 'm': if (!parse_num(s, i, 2, v) || v < 1 || v > 12) return false; tm.tm_mon = v - 1; break;
            case 'd': if (!parse_num(s, i, 2, v) || v < 1 || v > 31) return false; tm.tm_mday = v; break;
            case 'H': if (!parse_num(s, i, 2, v) || v > 23) return false; tm.tm_hour = v; break;
            case 'I': if (!parse_num(s, i, 2, v) || v < 1 || v > 12) return false; tm.tm_hour = v % 12; break;
            case 'M': if (!parse_num(s, i, 2, v) || v > 59) return false; tm.tm_min = v; break;
            case 'S': if (!parse_num(s, i, 2, v) || v > 61) return false; tm.tm_sec = v; break;
            case 'j': if (!parse_num(s, i, 3, v) || v < 1 || v > 366) return false; tm.tm_yday = v - 1; break;
            case 'f': {
                size_t st = i;
                int n = 0;
                if (!parse_num(s, i, 6, n)) return false;
                int digits = (int)(i - st);
                frac = n / std::pow(10.0, digits);
                break;
            }
            case 'p': {
                if (i + 2 > s.size()) return false;
                std::string ap = s.substr(i, 2);
                for (auto& ch : ap) ch = (char)std::tolower((unsigned char)ch);
                if (ap == "am") pm = 0; else if (ap == "pm") pm = 1; else return false;
                i += 2; break;
            }
            case 'b': case 'B': case 'h': {
                bool ok = false;
                for (int k = 0; k < 12 && !ok; k++) {
                    if (i + 3 <= s.size()) {
                        std::string t = s.substr(i, 3);
                        for (auto& ch : t) ch = (char)std::tolower((unsigned char)ch);
                        if (t == mon[k]) {
                            tm.tm_mon = k; i += 3; ok = true;
                            while (i < s.size() && std::isalpha((unsigned char)s[i])) i++;   // full name
                        }
                    }
                }
                if (!ok) return false;
                break;
            }
            case 'a': case 'A': {
                bool ok = false;
                for (int k = 0; k < 7 && !ok; k++) {
                    if (i + 3 <= s.size()) {
                        std::string t = s.substr(i, 3);
                        for (auto& ch : t) ch = (char)std::tolower((unsigned char)ch);
                        if (t == wd[k]) {
                            tm.tm_wday = k; i += 3; ok = true;
                            while (i < s.size() && std::isalpha((unsigned char)s[i])) i++;
                        }
                    }
                }
                if (!ok) return false;
                break;
            }
            case 'z': {
                // +HHMM / -HH:MM / Z - accepted and applied by the caller
                if (i < s.size() && (s[i] == 'Z' || s[i] == 'z')) { i++; break; }
                if (i >= s.size() || (s[i] != '+' && s[i] != '-')) return false;
                i++;
                int hh = 0, mm = 0;
                if (!parse_num(s, i, 2, hh)) return false;
                if (i < s.size() && s[i] == ':') i++;
                parse_num(s, i, 2, mm);
                break;
            }
            case '%': if (i >= s.size() || s[i] != '%') return false; i++; break;
            default: return false;
        }
    }
    if (pm == 1) tm.tm_hour += 12;
    return i == s.size();
}

// ISO-8601: YYYY-MM-DD[THH:MM[:SS[.ffffff]]][Z|+HH:MM|-HH:MM]. Without an
// offset the time is local, as a naive datetime's timestamp() is in Python.
bool parse_iso(const std::string& s, double& out) {
    std::tm tm{};
    tm.tm_isdst = -1;
    size_t i = 0;
    int v = 0;
    if (!parse_num(s, i, 4, v) || i >= s.size() || s[i] != '-') return false;
    tm.tm_year = v - 1900; i++;
    if (!parse_num(s, i, 2, v) || i >= s.size() || s[i] != '-') return false;
    tm.tm_mon = v - 1; i++;
    if (!parse_num(s, i, 2, v)) return false;
    tm.tm_mday = v;
    double frac = 0;
    bool has_offset = false;
    long offset = 0;
    if (i < s.size() && (s[i] == 'T' || s[i] == 't' || s[i] == ' ')) {
        i++;
        if (!parse_num(s, i, 2, v)) return false;
        tm.tm_hour = v;
        if (i < s.size() && s[i] == ':') {
            i++;
            if (!parse_num(s, i, 2, v)) return false;
            tm.tm_min = v;
            if (i < s.size() && s[i] == ':') {
                i++;
                if (!parse_num(s, i, 2, v)) return false;
                tm.tm_sec = v;
                if (i < s.size() && (s[i] == '.' || s[i] == ',')) {
                    i++;
                    size_t st = i;
                    long long n = 0;
                    while (i < s.size() && std::isdigit((unsigned char)s[i])) { if (i - st < 9) n = n * 10 + (s[i] - '0'); i++; }
                    int digits = (int)std::min<size_t>(i - st, 9);
                    if (digits == 0) return false;
                    frac = n / std::pow(10.0, digits);
                }
            }
        }
        if (i < s.size()) {
            if (s[i] == 'Z' || s[i] == 'z') { has_offset = true; i++; }
            else if (s[i] == '+' || s[i] == '-') {
                int sign = s[i] == '-' ? -1 : 1;
                i++;
                int hh = 0, mm = 0;
                if (!parse_num(s, i, 2, hh)) return false;
                if (i < s.size() && s[i] == ':') i++;
                parse_num(s, i, 2, mm);
                has_offset = true;
                offset = sign * (hh * 3600L + mm * 60L);
            }
        }
    }
    if (i != s.size()) return false;
    double base;
    if (has_offset) base = (double)timegm_portable(&tm) - (double)offset;
    else base = (double)std::mktime(&tm);
    out = base + frac;
    return true;
}

std::string iso_format(double ts, bool utc) {
    std::string s = format_time("%Y-%m-%dT%H:%M:%S", ts, utc);
    long ms = (long)std::floor((ts - std::floor(ts)) * 1000.0 + 1e-6);
    char b[32]; std::snprintf(b, sizeof b, ".%03ld", ms);
    s += b;
    if (utc) return s + "Z";
    std::tm lt{}, gt{};
    to_tm(ts, false, lt);
    to_tm(ts, true, gt);
    lt.tm_isdst = -1;
    long off = (long)(timegm_portable(&lt) - timegm_portable(&gt));
    char z[48];
    std::snprintf(z, sizeof z, "%c%02ld:%02ld", off < 0 ? '-' : '+', std::labs(off) / 3600, (std::labs(off) % 3600) / 60);
    return s + z;
}

std::string uuid4() {
    static std::mt19937_64 rng(std::random_device{}() ^ (uint64_t)std::chrono::high_resolution_clock::now().time_since_epoch().count());
    unsigned char b[16];
    for (int i = 0; i < 16; i += 8) {
        uint64_t r = rng();
        for (int k = 0; k < 8; k++) b[i + k] = (unsigned char)(r >> (8 * k));
    }
    b[6] = (unsigned char)((b[6] & 0x0F) | 0x40);   // version 4
    b[8] = (unsigned char)((b[8] & 0x3F) | 0x80);   // variant 10
    static const char* hex = "0123456789abcdef";
    std::string s;
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) s += '-';
        s += hex[b[i] >> 4];
        s += hex[b[i] & 15];
    }
    return s;
}

} // namespace

Value dispatch_os_time(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx) {
    (void)ctx;
    using namespace nyos;
    auto Str = [&](const std::string& s) { return E.makeStringValue(s); };

    if (name == "time" || name == "time_now" || name == "time_timestamp") return Value(now_seconds());
    if (name == "time_ms") return Value(std::floor(now_seconds() * 1000.0 * 1000.0) / 1000.0);
    if (name == "time_ns") {
        auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        return make_int((long long)ns);
    }
    if (name == "time_monotonic" || name == "monotonic" || name == "time_perf_counter" || name == "perf_counter") {
        auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        return Value((double)ns / 1e9);
    }
    if (name == "time_process" || name == "process_time") {
#if defined(CLOCK_PROCESS_CPUTIME_ID) && !defined(_WIN32)
        struct timespec ts;
        if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0) return Value((double)ts.tv_sec + ts.tv_nsec / 1e9);
#endif
        return Value((double)std::clock() / CLOCKS_PER_SEC);
    }
    if (name == "time_clock" || name == "clock") {
        auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        return Value((double)ns / 1e9);
    }
    if (name == "time_elapsed") {
        return Value(std::chrono::duration<double>(std::chrono::steady_clock::now() - g_start).count());
    }
    if (name == "time_sleep" || name == "sleep_ms") {
        // The concurrency runtime's sleep (src/NyConc.cpp): releases the GIL,
        // is cancellable and suspends only the current async task.
        return E.callBuiltin(name == "sleep_ms" ? "thread_sleep" : "sleep", args, ctx);
    }
    if (name == "time_format" || name == "time_date" || name == "time_strftime") {
        // time_format(fmt="%Y-%m-%d %H:%M:%S", ts=now, utc=false). The
        // timestamp argument used to be ignored.
        Args A(E, args, {"fmt", "ts", "utc"});
        std::string fmt = A.str(0, "fmt", "%Y-%m-%d %H:%M:%S");
        double ts = A.has(1, "ts") ? A.num(1, "ts", now_seconds()) : now_seconds();
        return Str(format_time(fmt, ts, A.flag(2, "utc", false)));
    }
    if (name == "time_localtime" || name == "time_gmtime") {
        double ts = (!args.empty() && args[0].type != ValueType::NONE) ? to_num(args[0], now_seconds()) : now_seconds();
        std::tm tm{};
        if (!to_tm(ts, name == "time_gmtime", tm)) raise("OverflowError", "timestamp out of range for platform time_t");
        return tm_map(E, tm, ts);
    }
    if (name == "time_mktime" || name == "time_timegm") {
        if (args.empty() || !is_map(args[0])) raise("TypeError", name + "() expects a map like time_localtime() returns");
        std::tm tm = map_tm(E, args[0]);
        std::time_t t = name == "time_mktime" ? std::mktime(&tm) : timegm_portable(&tm);
        return Value((double)t);
    }
    if (name == "time_strptime") {
        std::string text = args.size() > 0 ? E.getStringValue(args[0]) : "";
        std::string fmt = args.size() > 1 ? E.getStringValue(args[1]) : "%a %b %d %H:%M:%S %Y";
        std::tm tm{};
        tm.tm_mday = 1;
        tm.tm_year = 70;
        tm.tm_isdst = -1;
        double frac = 0;
        if (!strptime_portable(text, fmt, tm, frac))
            raise("ValueError", "time data '" + text + "' does not match format '" + fmt + "'");
        std::tm norm = tm;
        double ts = (double)timegm_portable(&norm) + frac;   // fills weekday/yearday
        tm.tm_wday = norm.tm_wday;
        tm.tm_yday = norm.tm_yday;
        tm.tm_isdst = -1;
        return tm_map(E, tm, ts);
    }
    if (name == "time_iso") {
        Args A(E, args, {"ts", "utc"});
        double ts = A.has(0, "ts") ? A.num(0, "ts", now_seconds()) : now_seconds();
        return Str(iso_format(ts, A.flag(1, "utc", true)));
    }
    if (name == "time_parse_iso") {
        std::string s = args.empty() ? "" : E.getStringValue(args[0]);
        double ts = 0;
        if (!parse_iso(s, ts)) raise("ValueError", "invalid ISO-8601 time: '" + s + "'");
        return Value(ts);
    }
    if (name == "uuid" || name == "gen_uuid" || name == "time_uuid") return Str(uuid4());

    return UNDEFINED_VALUE;
}

#pragma GCC diagnostic pop
