#pragma once
// builtins/nysqlite.hpp - SQLite loaded at run time for lib/_sqlite3.ny
// (src/builtins/nysqlite.cpp, round 83). The VM reaches it through the
// builtin bridge.
#include "Value.hpp"
#include "Context.hpp"
#include <string>
#include <vector>

struct NythonExecutor;

Value dispatch_sqlite(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> sqlite_builtin_names();
