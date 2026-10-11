// NyFuzzy.hpp - fuzzy matching for Quick Open, the command palette and
// autocomplete, shared by both engines (fuzzy_score / fuzzy_positions /
// fuzzy_rank).
//
// The Nython-level matcher (lib/gui_motion.ny's Fuzzy) is greedy: it takes
// the first occurrence of each query character, so "sal" against "File: Save
// All" scores the 'a' and 'l' inside "Save" and misses the word start of
// "All". It also allocated a result list, a positions list and a string per
// character examined, per candidate, per keystroke - memory the interpreter
// never gives back.
//
// This one finds the best alignment instead of the first, by dynamic
// programming over (query index, text index), in the spirit of fzf's v2
// algorithm and Smith-Waterman local alignment, with the Nython matcher's
// scoring kept so results stay familiar:
//   +1 per matched character
//   +10 when the match is the text's first character
//   +12 at a word start (after space _ - . / \ : or a lower->Upper hump)
//   +8 when it directly follows the previous match
//   -1 per text character passed over before the last match
//   -len(text)/4, so shorter candidates win ties ("Run" over "Run Task...")
// Matching is case-insensitive for ASCII; other characters compare exactly.
// All positions are character (code point) indices, like string_slice.
#pragma once

#include <algorithm>
#include <climits>
#include <cstdint>
#include <string>
#include <vector>

namespace nyfuzzy {

inline std::vector<uint32_t> codepoints(const std::string& s) {
    std::vector<uint32_t> out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        uint32_t cp = c;
        int extra = 0;
        if (c >= 0xF0) { cp = c & 0x07; extra = 3; }
        else if (c >= 0xE0) { cp = c & 0x0F; extra = 2; }
        else if (c >= 0xC0) { cp = c & 0x1F; extra = 1; }
        i++;
        for (int k = 0; k < extra && i < s.size(); k++, i++) cp = (cp << 6) | ((unsigned char)s[i] & 0x3F);
        out.push_back(cp);
    }
    return out;
}

inline uint32_t fold(uint32_t c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

inline bool is_sep(uint32_t c) {
    return c == ' ' || c == '_' || c == '-' || c == '.' || c == '/' || c == '\\' || c == ':';
}

// Bonus for matching at text position j (first character, word start).
inline int position_bonus(const std::vector<uint32_t>& t, size_t j) {
    int b = 0;
    if (j == 0) return 10 + 12;
    uint32_t p = t[j - 1], c = t[j];
    if (is_sep(p)) b += 12;
    else if (p >= 'a' && p <= 'z' && c >= 'A' && c <= 'Z') b += 12;
    return b;
}

// Score of the best alignment of q within t; returns false when q is not a
// subsequence of t. With `pos`, also the matched character indices.
inline bool score(const std::vector<uint32_t>& q, const std::vector<uint32_t>& t, int& out,
                  std::vector<int>* pos = nullptr) {
    const size_t n = q.size(), m = t.size();
    if (n == 0) { out = 0; if (pos) pos->clear(); return true; }
    if (n > m) return false;
    // Quick reject: q must be a subsequence of t at all.
    {
        size_t i = 0;
        for (size_t j = 0; j < m && i < n; j++) if (fold(q[i]) == fold(t[j])) i++;
        if (i < n) return false;
    }
    const int NEG = INT_MIN / 4;
    // best[i*m + j]: best gain sum with q[i] matched at t[j]. from[] records
    // the previous match's column for the backtrack (-1: none).
    std::vector<int> best(n * m, NEG);
    std::vector<int> from;
    if (pos) from.assign(n * m, -1);
    for (size_t j = 0; j < m; j++)
        if (fold(q[0]) == fold(t[j])) best[j] = 1 + position_bonus(t, j);
    for (size_t i = 1; i < n; i++) {
        int run_max = NEG, run_arg = -1;   // max over best[i-1][k], k < j-1
        for (size_t j = i; j < m; j++) {
            if (j >= 2) {
                int cand = best[(i - 1) * m + (j - 2)];
                if (cand > run_max) { run_max = cand; run_arg = (int)j - 2; }
            }
            if (fold(q[i]) != fold(t[j])) continue;
            int gain = 1 + position_bonus(t, j);
            int via_prev = best[(i - 1) * m + (j - 1)];
            int b = NEG, arg = -1;
            if (via_prev > NEG) { b = via_prev + 8; arg = (int)j - 1; }
            if (run_max > NEG && run_max > b) { b = run_max; arg = run_arg; }
            if (b > NEG) {
                best[i * m + j] = b + gain;
                if (pos) from[i * m + j] = arg;
            }
        }
    }
    int top = NEG, top_j = -1;
    for (size_t j = n - 1; j < m; j++) {
        int v = best[(n - 1) * m + j];
        if (v <= NEG) continue;
        v -= (int)(j + 1 - n);              // characters passed over
        if (v > top) { top = v; top_j = (int)j; }
    }
    if (top_j < 0) return false;
    out = top - (int)(m / 4);
    if (pos) {
        pos->assign(n, 0);
        int j = top_j;
        for (int i = (int)n - 1; i >= 0; i--) {
            (*pos)[i] = j;
            if (i > 0) j = from[i * m + j];
        }
    }
    return true;
}

inline bool score(const std::string& q, const std::string& t, int& out, std::vector<int>* pos = nullptr) {
    // Very long candidates are matched on their first 1024 characters.
    auto tq = codepoints(q), tt = codepoints(t);
    if (tt.size() > 1024) tt.resize(1024);
    if (tq.size() > 64) tq.resize(64);
    return score(tq, tt, out, pos);
}

// Indices of the texts that match, best first (ties keep their order).
// `bonus`, when given, is added to 10 * score per item - frecency, say.
inline std::vector<int> rank(const std::string& q, const std::vector<std::string>& texts,
                             const std::vector<long long>* bonus, size_t limit) {
    auto tq = codepoints(q);
    if (tq.size() > 64) tq.resize(64);
    std::vector<std::pair<long long, int>> hits;
    for (size_t i = 0; i < texts.size(); i++) {
        int sc = 0;
        if (tq.empty()) { hits.push_back({0, (int)i}); continue; }
        auto tt = codepoints(texts[i]);
        if (tt.size() > 1024) tt.resize(1024);
        if (!score(tq, tt, sc)) continue;
        long long key = (long long)sc * 10 + (bonus && i < bonus->size() ? (*bonus)[i] : 0);
        hits.push_back({key, (int)i});
    }
    if (!tq.empty())
        std::stable_sort(hits.begin(), hits.end(), [](auto& a, auto& b) { return a.first > b.first; });
    std::vector<int> out;
    for (auto& h : hits) {
        if (limit && out.size() >= limit) break;
        out.push_back(h.second);
    }
    return out;
}

}  // namespace nyfuzzy
