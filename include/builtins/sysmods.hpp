#pragma once
// builtins/sysmods.hpp - the round 83 natives behind Python's system and
// command-line modules: errno, fcntl, termios, pty, resource, syslog, locale
// (nysysmods.cpp), mmap (nymmap.cpp), bz2 (nybz2.cpp), lzma (nylzma.cpp),
// cmath (nycmath.cpp), faulthandler and tracemalloc (nyfault.cpp), readline
// (nyreadline.cpp). One entry point for the interpreter's callBuiltin chain
// and registerBuiltins(): dispatch_sysmods / sysmods_builtin_names; the VM
// reaches the same names through the builtin bridge.
#include "Value.hpp"
#include "Context.hpp"
#include <string>
#include <vector>

struct NythonExecutor;

Value dispatch_sysmods(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> sysmods_builtin_names();

Value dispatch_bz2(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> bz2_builtin_names();
Value dispatch_mmap(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> mmap_builtin_names();
Value dispatch_lzma(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> lzma_builtin_names();
Value dispatch_cmath(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> cmath_builtin_names();
Value dispatch_fault(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> fault_builtin_names();
Value dispatch_readline(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> readline_builtin_names();

// faulthandler and tracemalloc (nyfault.cpp) read the VM's frames through its
// concurrency engine (VMConc.cpp), which registers itself with the VM it
// serves; a program runs on the VM when the builtin bridge's executor has
// that VM as its runner.
namespace nyconc { struct Engine; }
void nyfault_set_vm_engine(nyconc::Engine* eng, const void* vm_runnable);
