// Unicode character names (round 77) - see include/NyUniNames.hpp.
#include "NyUniNames.hpp"
#include "NyUniNamesData.hpp"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace nyuni {
namespace {

// Hangul syllables: "HANGUL SYLLABLE " + the short names of their leading
// consonant, vowel and trailing consonant (The Unicode Standard, 3.12).
const char* const kJamoL[19] = {"G", "GG", "N", "D", "DD", "R", "M", "B", "BB", "S", "SS", "", "J", "JJ",
                                "C", "K", "T", "P", "H"};
const char* const kJamoV[21] = {"A", "AE", "YA", "YAE", "EO", "E", "YEO", "YE", "O", "WA", "WAE", "OE", "YO",
                                "U", "WEO", "WE", "WI", "YU", "EU", "YI", "I"};
const char* const kJamoT[28] = {"", "G", "GG", "GS", "N", "NJ", "NH", "D", "L", "LG", "LM", "LB", "LS", "LT",
                                "LP", "LH", "M", "B", "BS", "S", "SS", "NG", "J", "C", "K", "T", "P", "H"};
const uint32_t kHangulFirst = 0xAC00, kHangulCount = 11172;

std::string hangul(uint32_t cp) {
    uint32_t s = cp - kHangulFirst;
    return std::string("HANGUL SYLLABLE ") + kJamoL[s / 588] + kJamoV[(s % 588) / 28] + kJamoT[s % 28];
}

struct Table {
    std::vector<std::string> words;
    std::vector<std::pair<uint32_t, std::string>> names;   // in code point order
    std::unordered_map<std::string, uint32_t> by_name;
};

int b64(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

// Decoded on first use: only a program that names a character pays for it.
const Table& table() {
    static Table t;
    static std::once_flag once;
    std::call_once(once, [] {
        for (const char* w = nyuni_data::kWords; *w;) {
            const char* e = std::strchr(w, '\n');
            t.words.emplace_back(w, (size_t)(e - w));
            w = e + 1;
        }
        std::vector<uint8_t> bin;
        bin.reserve(std::strlen(nyuni_data::kNames) * 3 / 4);
        uint32_t acc = 0;
        int bits = 0;
        for (const char* p = nyuni_data::kNames; *p; ++p) {
            int v = b64(*p);
            if (v < 0) continue;
            acc = (acc << 6) | (uint32_t)v;
            bits += 6;
            if (bits >= 8) { bits -= 8; bin.push_back((uint8_t)((acc >> bits) & 0xFF)); }
        }
        t.names.reserve(nyuni_data::kNamed);
        t.by_name.reserve((size_t)nyuni_data::kNamed + kHangulCount);
        size_t i = 0;
        int64_t cp = -1;
        while (i < bin.size()) {
            uint64_t d = 0;
            int shift = 0;
            while (i < bin.size()) {
                uint8_t b = bin[i++];
                d |= (uint64_t)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            cp += (int64_t)d;
            if (i >= bin.size()) break;
            int n = bin[i++];
            std::string nm;
            for (int k = 0; k < n && i < bin.size(); k++) {
                uint32_t idx = bin[i++];
                if ((idx & 0x80) && i < bin.size()) idx = ((idx & 0x7F) << 8) | bin[i++];
                if (k) nm += ' ';
                if (idx < t.words.size()) nm += t.words[idx];
            }
            t.by_name.emplace(nm, (uint32_t)cp);
            t.names.emplace_back((uint32_t)cp, std::move(nm));
        }
        for (uint32_t s = 0; s < kHangulCount; s++) t.by_name.emplace(hangul(kHangulFirst + s), kHangulFirst + s);
    });
    return t;
}

}  // namespace

bool lookup(const std::string& name, uint32_t& cp) {
    std::string up(name);
    for (auto& c : up) if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    // CJK UNIFIED IDEOGRAPH-4E00 and the other names made from the code point
    for (const auto& d : nyuni_data::kDerived) {
        size_t pl = std::strlen(d.prefix);
        if (up.size() <= pl || up.compare(0, pl, d.prefix) != 0) continue;
        std::string hex = up.substr(pl);
        if (hex.size() < 4 || hex.size() > 6) continue;
        uint32_t v = 0;
        bool ok = true;
        for (char c : hex) {
            int h = (c >= '0' && c <= '9') ? c - '0' : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
            if (h < 0) { ok = false; break; }
            v = v * 16 + (uint32_t)h;
        }
        if (ok && v >= d.first && v <= d.last) { cp = v; return true; }
    }
    const Table& t = table();
    auto it = t.by_name.find(up);
    if (it == t.by_name.end()) return false;
    cp = it->second;
    return true;
}

std::string name(uint32_t cp) {
    for (const auto& d : nyuni_data::kDerived)
        if (cp >= d.first && cp <= d.last) {
            char buf[16];
            std::snprintf(buf, sizeof buf, "%04X", (unsigned)cp);
            return std::string(d.prefix) + buf;
        }
    if (cp >= kHangulFirst && cp < kHangulFirst + kHangulCount) return hangul(cp);
    const Table& t = table();
    auto it = std::lower_bound(t.names.begin(), t.names.end(), cp,
                               [](const std::pair<uint32_t, std::string>& e, uint32_t c) { return e.first < c; });
    if (it == t.names.end() || it->first != cp) return std::string();
    return it->second;
}

}  // namespace nyuni
