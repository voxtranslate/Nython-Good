#pragma once
// builtins/text.hpp
// Native text services for editors: completion words, a symbol outline, syntax
// checking through the real parser, line diff, workspace listing and search,
// folding ranges, line statistics, TODO scanning and a conservative formatter.
// Part of the Nython builtin module system: dispatch_text returns
// UNDEFINED_VALUE when `name` is not one of its builtins.

#include "Value.hpp"
#include "Context.hpp"
#include <string>
#include <vector>

struct NythonExecutor;

Value dispatch_text(NythonExecutor& E,
                    const std::string& name,
                    std::vector<Value>& args,
                    Context* ctx);
