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
#include "Node.hpp"

namespace nython::scope {

// Throws nython::exception::SyntaxError on the first violation.
void check(const nython::node::node_ptr& root);

} // namespace nython::scope
#endif
