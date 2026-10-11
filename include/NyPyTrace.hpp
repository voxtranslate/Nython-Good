// NyPyTrace.hpp - sys.settrace / sys.setprofile, the state both engines
// test (round 79).
//
// A thread's trace and profile functions are held by its engine (the
// interpreter's NythonExecutor::pyhooks_, the VM's pyhooks_), keyed by
// thread; what the hot paths read is one byte per thread:
//
//   t_hooks   TRACE - a trace function is set, PROFILE - a profile function
//             is set, VMDEBUG - NY_VM_TRACE's instruction dump (the VM folds
//             its own per-instruction test into this byte). 0 on a thread
//             that set neither, and while one of the hooks itself runs
//             (Python runs a trace function with tracing off).
//   t_in_hook a hook is running on this thread: t_hooks stays 0 until it
//             returns, whatever it sets meanwhile.
//
// The interpreter tests t_hooks once per statement (beside the --trace
// test in noteStatement) and once per call (runFunctionBody); the VM once
// per instruction (where NY_VM_TRACE was tested) and once per frame
// (run_frame). With no hook set nothing else is done.
#pragma once
#include <cstdint>
#include <string>

namespace nytrace {

enum : uint8_t { TRACE = 1, PROFILE = 2, VMDEBUG = 4, ANY = TRACE | PROFILE };

inline thread_local uint8_t t_hooks = 0;
inline thread_local bool t_in_hook = false;

// A builtin that is a type in Python - calling it makes an object, no
// c_call event there (str(5), list(xs), zip(a, b)) - or Nython's own
// method behind a subscript (xs[1:] calls the list's slice): the profile
// function is not told.
inline bool no_c_call(const std::string& n) {
    static const char* const names[] = {"int", "float", "str", "bool", "list", "dict", "tuple", "set", "frozenset",
                                        "bytes", "bytearray", "complex", "object", "type", "slice", "range",
                                        "map", "enumerate", "zip", "filter", "reversed", "super", "property",
                                        "staticmethod", "classmethod", "memoryview"};
    for (const char* x : names) if (n == x) return true;
    return false;
}

}  // namespace nytrace
