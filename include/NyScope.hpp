#ifndef NYTHON_NYSCOPE_HPP
#define NYTHON_NYSCOPE_HPP
/*=============================================================================
 * Nython — NyScope.hpp — static scope checks, shared by both engines
 *
 * Run once on every parsed program (Parser::parse), after the whole tree
 * exists, so it sees each function's declarations wherever they are. It
 *
 *   - rejects `nonlocal x` when no enclosing function binds x, and at module
 *     level (SyntaxError, as in Python);
 *   - enforces `const`: assigning, augmenting, deleting or re-declaring a
 *     name whose binding is a `const` declaration is a SyntaxError. A
 *     `const` statement that runs again (in a loop, or a function called
 *     twice) re-initialises the same declaration and is fine;
 *   - marks the binding forms the parser cannot see a `global` for - a
 *     walrus, `except ... as`, `with ... as` - so both engines bind the
 *     module's name (WalrusNode::global_ref, ExceptNode::var_global,
 *     WithNode::alias_global).
 *
 * Name resolution follows the round-75 ruling: a plain assignment rebinds
 * the nearest binding (this function, then the enclosing functions, then
 * the module) and otherwise makes a local; var/let/const, parameters, loop
 * targets, `except/with ... as` and walrus bind a local; `global` and
 * `nonlocal` redirect. Class bodies are not part of the closure chain.
 * A static check cannot see bindings made at run time (exec of code
 * strings, setattr on a module); those are not checked.
 *
 * Python's rule (round 85). Python-language source - a .py file, a file
 * whose leading comment block says `# nython: python`, code that compile()
 * / exec() / eval() compile when called from such a file, and code
 * compiled from an ast tree - binds names as CPython does: a name a
 * function binds anywhere in its body (an assignment, an augmented
 * assignment, a for / with / except-as target, `del`, `import`, a def or
 * class statement, a walrus - one in a comprehension binds in the function
 * around it -, a match capture) is a local of the whole function unless
 * the function declares it global or nonlocal, and reading it while it is
 * unbound is UnboundLocalError. Decided here, statically, as CPython's
 * symtable pass decides it: each read, assignment and `del` of such a name
 * is marked (VariableNode::py_bind = 1), and both engines read, bind and
 * delete a marked name in the function's own scope only - neither has a
 * rule of its own. A Nython function in a Nython file opts in with the
 * comment `# nython: python` on its def line (its nested functions too).
 *=============================================================================*/
#include <ostream>
#include <set>
#include <string>
#include "Node.hpp"

namespace nython::scope {

// Throws nython::exception::SyntaxError on the first violation.
void check(const nython::node::node_ptr& root);
// The same, for the source `code` of `file` (Parser::parse): Python's rule
// when that is Python-language source (python_source) or the rule this
// thread's RuleScope sets says so (round 85).
void check(const nython::node::node_ptr& root, const std::string& file, const std::string& code);

// Whether `file` / `code` is Python-language source: a .py file, or one
// whose leading comment block says `# nython: python` (round 85).
bool python_source(const std::string& file, const std::string& code);
// Whether a file parsed so far in this process was Python-language source -
// how exec / eval / compile tell their caller's rule (round 85).
bool python_file(const std::string& file);
// The rule of code compile() / exec() / eval() are given: code named after
// a source file (`compile(src, "prog.ny", "exec")`, as runpy, pdb and
// cProfile run a program) is that file's language; any other (<string>,
// <doctest x>...) has its caller's (round 85).
bool code_rule(const std::string& name, const std::string& code, bool caller_python);

// The rule of the code this thread parses while a RuleScope lives (round
// 85): exec / eval / compile give a snippet its caller's rule, and
// `top_locals` makes a snippet exec'd without namespaces in a
// Python-language function bind what its top level binds in its own scope
// (CPython: exec cannot change a function's locals) - VariableNode::py_bind 2.
struct RuleScope {
    RuleScope(bool python, bool top_locals);
    ~RuleScope();
    int saved_python;
    bool saved_top;
};

// Diagnostics for Nython-language code (round 85). Each place where the two
// rules disagree - a function assigning (or augmenting, or deleting) a name
// that an enclosing function or the module binds, with no global/nonlocal/
// var for it: Nython rebinds the outer variable, Python would make a local.
// warn_filter(): "" off; "1" every Nython-language file outside the
// standard library's directories; "all" every one; anything else, the files
// whose path contains it (NY_SCOPE_WARN, `-W nython-scope[:filter]`).
// Each case is printed to stderr as a warning when the file is parsed.
std::string& warn_filter();
// --scope-report (tools/ny_scopecheck.py): every such case of the files
// parsed while it is set, Nython-language or not, one tab-separated line
// each (see NyScope.cpp, report_line).
std::ostream*& report_sink();

// The names a module's top level binds: defs, classes, interfaces, enums,
// namespaces, var/let/const and plain assignments (unpacking targets too),
// including those inside top-level if/try blocks - what `import m` puts in
// m's namespace (round 77; both engines read only defs, classes and var
// declarations before, so `X = 5` in a module was missing from it).
void module_names(const nython::node::node_ptr& root, std::set<std::string>& out);

// A module imported by name (round 77) has a scope of its own, but both
// engines identify a class by its name, so two modules' classes of one name
// (asyncio's Queue, lib/thread.ny's Queue) would replace each other. Each
// class the module's top level defines is renamed "module.Class" and bound
// as "Class" (ClassNode::bind_name); its bases that name another of these
// classes are renamed too. `except Name` finds the class through the scope
// at run time, so the module's own clauses need no rewriting.
void qualify_module_classes(const nython::node::node_ptr& root, const std::string& module);

} // namespace nython::scope
#endif
