#pragma once
// NyRe.hpp - Python's regular expressions (round 77): an engine-neutral
// parser, compiler and backtracking matcher with Python 3.12 `re` syntax and
// results. src/builtins/nyre.cpp holds the engine and its thin bindings
// (_re_* builtins, reached by the VM through the builtin bridge); lib/re.ny
// is the Python API over them.
//
// The engine knows nothing of either interpreter's values: a pattern is a
// sequence of code points (a bytes pattern: 0..255), a subject is an array of
// 8-bit or 32-bit code units, and positions are indexes into that array -
// CHARACTER indexes for a str, as Python's are.
//
// Syntax and errors follow CPython's Lib/re/_parser.py line by line (the
// same messages and positions). Execution:
//   * the pattern compiles to a small instruction program run by a
//     backtracking machine with an explicit stack - no C++ recursion while
//     matching, so a 1 MB subject or a deep nesting cannot overflow;
//     leftmost-first (Perl/Python) priority, with sre's rules for empty
//     iterations, lookaround, atomic groups and possessive repeats;
//   * selective memoization (Davis, Servant, Lee, IEEE S&P 2021) makes it
//     immune to catastrophic backtracking: the (instruction, position)
//     states that can be reached more than once - every SPLIT (alternation
//     and loop entries) and the run states of single-character loops - are
//     remembered when they FAIL, so a pattern without backreferences runs in
//     O(program x subject). See nyre.cpp, "Selective memoization", for the
//     exact rule and when it is switched off;
//   * fast paths: a literal prefix located with memchr/search, a first-
//     character set that skips impossible start positions, and patterns
//     anchored at \A or ^ tried once.

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace nyre {

// Python's flag values (re.RegexFlag).
enum : int {
    F_TEMPLATE = 1, F_IGNORECASE = 2, F_LOCALE = 4, F_MULTILINE = 8, F_DOTALL = 16,
    F_UNICODE = 32, F_VERBOSE = 64, F_DEBUG = 128, F_ASCII = 256
};

// re.error: the message without the position, and the position in the
// pattern (or template), -1 when there is none.
struct Error {
    std::string msg;
    int64_t pos;
};
// Any other Python exception the compiler raises (ValueError for
// incompatible flags, OverflowError for a too large repeat count,
// IndexError for an unknown group name in a template, RecursionError).
struct PyErr {
    std::string type, msg;
};

struct Program;   // a compiled pattern (opaque)

struct Compiled {
    std::shared_ptr<const Program> prog{};
    int groups = 0;                                   // capturing groups
    int flags = 0;                                    // inline flags and UNICODE included
    std::vector<std::pair<std::string, int>> groupindex{};   // name -> number (UTF-8)
    bool is_bytes = false;
};

// Throws Error / PyErr.
Compiled compile(const std::vector<uint32_t>& pattern, int flags, bool is_bytes);

enum Mode { SEARCH = 0, MATCH = 1, FULLMATCH = 2 };

struct Match {
    int64_t lastindex = -1;          // -1: None
    std::vector<int64_t> spans{};    // 2 * (groups + 1); -1 where a group did not take part
};

// Runs a compiled program over one subject: s[0..n) where n is the
// (clipped) endpos. One Scanner keeps its memo table across the successive
// searches of findall/finditer/sub/split (valid: see nyre.cpp).
class Scanner {
public:
    Scanner(const Compiled& c, const uint8_t* s, int64_t n);
    Scanner(const Compiled& c, const uint32_t* s, int64_t n);
    ~Scanner();
    Scanner(const Scanner&) = delete;
    Scanner& operator=(const Scanner&) = delete;
    // SEARCH: the leftmost match at pos or after (must_advance: not an
    // empty match at pos); MATCH: anchored at pos; FULLMATCH: anchored at
    // pos and ending at n.
    bool exec(int64_t pos, Mode mode, bool must_advance, Match& out);
    struct Impl;
private:
    std::unique_ptr<Impl> impl_;
};

// A parsed replacement template: literal text (UTF-8 for str, raw bytes for
// bytes) and group references. Throws Error (positions in the template) or
// PyErr IndexError ("unknown group name 'x'").
struct TemplateItem {
    int group;           // -1: literal
    std::string text;
};
std::vector<TemplateItem> parse_template(const Compiled& c, const std::vector<uint32_t>& repl, bool is_bytes);

// re.escape over code points.
std::vector<uint32_t> escape(const std::vector<uint32_t>& s);

} // namespace nyre
