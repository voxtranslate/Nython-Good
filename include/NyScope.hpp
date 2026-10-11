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
 *=============================================================================*/
#include <set>
#include <string>
#include "Node.hpp"

namespace nython::scope {

// Throws nython::exception::SyntaxError on the first violation.
void check(const nython::node::node_ptr& root);

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
