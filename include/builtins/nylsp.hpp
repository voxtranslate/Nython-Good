#pragma once
// builtins/nylsp.hpp (round 86)
// The native half of lib/nylsp (the Language Server): documents kept as
// piece tables, their analysis (the real parser's tree, the binding
// analysis, the lexer's tokens) and the queries the server answers from
// it. One builtin, `_ny_lsp(op, args...)`, reached through dispatch_text
// (src/builtins/text.cpp), which passes the arguments as text (an int as
// its digits, a bool as "1"/"0", None as "") and returns the text this
// gives back (JSON for anything structured). Kept free of the engines'
// headers, so it builds on its own.

#include <string>
#include <vector>

namespace nylsp {
// args[0] names the operation (see src/builtins/nylsp.cpp). Throws
// std::runtime_error for a call it cannot serve (raised as ValueError).
std::string call(const std::vector<std::string>& args);
}
