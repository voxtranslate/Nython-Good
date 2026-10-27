# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/symtable.ny - Python's symtable (round 83): the compiler's symbol
# tables - which names each scope binds, uses, declares, and whether each is
# local, global, free or a cell - as CPython 3.12 computes them.
#
#     import symtable
#     top = symtable.symtable(source, "f.py", "exec")
#     f = top.lookup("f").get_namespace()       # a Function table
#     f.get_frees(), f.lookup("x").is_free()
#
# symtable(code, filename, compile_type)  'exec' / 'eval' / 'single'
# SymbolTable  get_type() ('module', 'function', 'class'), get_id(),
#              get_name() ('top' for the module), get_lineno(),
#              is_optimized(), is_nested(), has_children(),
#              get_identifiers(), lookup(name), get_symbols(), get_children()
# Function     get_parameters(), get_locals(), get_globals(),
#              get_nonlocals(), get_frees()
# Class        get_methods()
# Symbol       get_name(), is_referenced(), is_imported(), is_parameter(),
#              is_global(), is_nonlocal(), is_declared_global(), is_local(),
#              is_annotated(), is_free(), is_assigned(), is_namespace(),
#              get_namespaces(), get_namespace()
# the flag constants USE, DEF_GLOBAL, DEF_NONLOCAL, DEF_LOCAL, DEF_PARAM,
# DEF_IMPORT, DEF_BOUND, DEF_ANNOT, SCOPE_OFF, SCOPE_MASK, FREE, LOCAL,
# GLOBAL_IMPLICIT, GLOBAL_EXPLICIT, CELL (CPython's values).
#
# CPython builds these tables in C (Python/symtable.c) from the AST; here
# the same two passes run in Nython over lib/ast.ny's tree (so over
# Nython's own parser): the first records each name's flags per block, the
# second (analyze) gives each its scope - a name bound in a function and
# used by a nested one is a CELL there and FREE in the nested one (a class
# between them passes it through, and `super()`/`__class__` in a method is
# the class's implicit cell), a declared global is GLOBAL_EXPLICIT and an
# unbound use GLOBAL_IMPLICIT. 3.12's inlined comprehensions (PEP 709) are
# kept: a list/set/dict comprehension's names belong to the block it is in
# (DEF_COMP_ITER), a generator expression is a 'genexpr' function with its
# '.0' parameter. CPython's SyntaxErrors from this pass: nonlocal at module
# level, "no binding for nonlocal 'x' found", a name that is a parameter and
# global/nonlocal, `import *` in a function, a name both global and
# nonlocal.
#
# Not here: 3.12's annotation and type-parameter scopes (Nython's parser
# reads no `type X = ...` nor generic def/class: get_type() never gives
# 'annotation', 'TypeVar bound', 'type alias' or 'type parameter').

import ast as _ast

__all__ = ["symtable", "SymbolTable", "Class", "Function", "Symbol"]

DEF_GLOBAL = 1
DEF_LOCAL = 2
DEF_PARAM = 4
DEF_NONLOCAL = 8
USE = 16
DEF_FREE = 32
DEF_FREE_CLASS = 64
DEF_IMPORT = 128
DEF_ANNOT = 256
DEF_COMP_ITER = 512
DEF_TYPE_PARAM = 1024
DEF_COMP_CELL = 2048
DEF_BOUND = DEF_LOCAL | DEF_PARAM | DEF_IMPORT

SCOPE_OFF = 12
SCOPE_MASK = 15
LOCAL = 1
GLOBAL_EXPLICIT = 2
GLOBAL_IMPLICIT = 3
FREE = 4
CELL = 5

TYPE_FUNCTION = 0
TYPE_CLASS = 1
TYPE_MODULE = 2


class _Table:
    # what CPython's _symtable gives: one block
    def __init__(self, name, typ, lineno, nested):
        self.name = name
        self.type = typ
        self.lineno = lineno
        self.nested = nested
        self.children = []
        self.symbols = {}
        self.id = id(self)
        self.uses_super = False


class _Builder(_ast.NodeVisitor):
    def __init__(self, filename):
        self.filename = filename
        self.stack = []
        self.top = None

    def error(self, msg, node):
        e = SyntaxError(msg, (self.filename, getattr(node, "lineno", 0), getattr(node, "col_offset", 0) + 1, None))
        raise e

    @property
    def cur(self):
        return self.stack[-1]

    def add(self, name, flag, table=None):
        t = table if table is not None else self.cur
        t.symbols[name] = t.symbols.get(name, 0) | flag

    def enter(self, name, typ, lineno):
        prev = self.stack[-1] if self.stack else None
        nested = prev is not None and (prev.nested or prev.type == TYPE_FUNCTION)
        t = _Table(name, typ, lineno, nested)
        if prev is not None:
            prev.children.append(t)
        self.stack.append(t)
        return t

    def leave(self):
        self.stack.pop()

    # ── blocks ──
    def run(self, tree):
        self.top = self.enter("top", TYPE_MODULE, 0)
        if isinstance(tree, _ast.Expression):
            self.visit(tree.body)
        else:
            for s in tree.body:
                self.visit(s)
        return self.top

    def visit_seq(self, seq):
        for x in seq:
            if x is not None:
                self.visit(x)

    def _annotations(self, args, returns):
        for a in args.posonlyargs + args.args + args.kwonlyargs:
            if a.annotation is not None:
                self.visit(a.annotation)
        for a in (args.vararg, args.kwarg):
            if a is not None and a.annotation is not None:
                self.visit(a.annotation)
        if returns is not None:
            self.visit(returns)

    def _params(self, args):
        for a in args.posonlyargs + args.args:
            self._param(a)
        if args.vararg is not None:
            self._param(args.vararg)
        for a in args.kwonlyargs:
            self._param(a)
        if args.kwarg is not None:
            self._param(args.kwarg)

    def _param(self, a):
        if self.cur.symbols.get(a.arg, 0) & DEF_PARAM:
            self.error("duplicate argument '%s' in function definition" % a.arg, a)
        self.add(a.arg, DEF_PARAM)

    def _function(self, node, name):
        self.visit_seq(node.args.defaults)
        self.visit_seq(node.args.kw_defaults)
        self.visit_seq(getattr(node, "decorator_list", []))
        if not isinstance(node, _ast.Lambda):
            self._annotations(node.args, node.returns)
        self.enter(name, TYPE_FUNCTION, node.lineno)
        self._params(node.args)
        if isinstance(node, _ast.Lambda):
            self.visit(node.body)
        else:
            for s in node.body:
                self.visit(s)
        self.leave()

    def visit_FunctionDef(self, node):
        self.add(node.name, DEF_LOCAL)
        self._function(node, node.name)

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_Lambda(self, node):
        self._function(node, "lambda")

    def visit_ClassDef(self, node):
        self.add(node.name, DEF_LOCAL)
        self.visit_seq(node.bases)
        self.visit_seq(node.keywords)
        self.visit_seq(node.decorator_list)
        self.enter(node.name, TYPE_CLASS, node.lineno)
        for s in node.body:
            self.visit(s)
        self.leave()

    # ── statements ──
    def visit_Global(self, node):
        for n in node.names:
            flags = self.cur.symbols.get(n, 0)
            if flags & DEF_PARAM:
                self.error("name '%s' is parameter and global" % n, node)
            if flags & DEF_NONLOCAL:
                self.error("name '%s' is nonlocal and global" % n, node)
            if flags & (USE | DEF_LOCAL):
                self.error("name '%s' is %s prior to global declaration"
                           % (n, "used" if flags & USE else "assigned to"), node)
            self.add(n, DEF_GLOBAL)
            self.add(n, DEF_GLOBAL, self.top)

    def visit_Nonlocal(self, node):
        if self.cur.type == TYPE_MODULE:
            self.error("nonlocal declaration not allowed at module level", node)
        for n in node.names:
            flags = self.cur.symbols.get(n, 0)
            if flags & DEF_PARAM:
                self.error("name '%s' is parameter and nonlocal" % n, node)
            if flags & DEF_GLOBAL:
                self.error("name '%s' is nonlocal and global" % n, node)
            if flags & (USE | DEF_LOCAL):
                self.error("name '%s' is %s prior to nonlocal declaration"
                           % (n, "used" if flags & USE else "assigned to"), node)
            self.add(n, DEF_NONLOCAL)

    def _alias(self, a, node):
        if a.name == "*":
            if self.cur.type != TYPE_MODULE:
                self.error("import * only allowed at module level", node)
            return
        name = a.asname if a.asname else a.name.split(".")[0]
        self.add(name, DEF_IMPORT)

    def visit_Import(self, node):
        for a in node.names:
            self._alias(a, node)

    visit_ImportFrom = visit_Import

    def visit_Assign(self, node):
        self.visit_seq(node.targets)
        self.visit(node.value)

    def visit_AnnAssign(self, node):
        t = node.target
        if isinstance(t, _ast.Name):
            flags = self.cur.symbols.get(t.id, 0)
            if flags & (DEF_GLOBAL | DEF_NONLOCAL) and self.cur.type != TYPE_MODULE:
                self.error("annotated name '%s' can't be %s" % (t.id, "global" if flags & DEF_GLOBAL else "nonlocal"), node)
            if node.simple:
                self.add(t.id, DEF_ANNOT | (DEF_LOCAL if node.value is not None else 0))
            elif node.value is not None:
                self.add(t.id, DEF_LOCAL)
        else:
            self.visit(t)
        self.visit(node.annotation)
        if node.value is not None:
            self.visit(node.value)

    def visit_AugAssign(self, node):
        self.visit(node.target)
        self.visit(node.value)

    def visit_ExceptHandler(self, node):
        if node.type is not None:
            self.visit(node.type)
        if node.name:
            self.add(node.name, DEF_LOCAL)
        for s in node.body:
            self.visit(s)

    def visit_MatchAs(self, node):
        if node.pattern is not None:
            self.visit(node.pattern)
        if node.name:
            self.add(node.name, DEF_LOCAL)

    def visit_MatchStar(self, node):
        if node.name:
            self.add(node.name, DEF_LOCAL)

    def visit_MatchMapping(self, node):
        self.visit_seq(node.keys)
        self.visit_seq(node.patterns)
        if node.rest:
            self.add(node.rest, DEF_LOCAL)

    # ── expressions ──
    def visit_Name(self, node):
        if isinstance(node.ctx, _ast.Load):
            self.add(node.id, USE)
            if node.id == "super" and self.cur.type == TYPE_FUNCTION:
                self.cur.uses_super = True
        else:
            self.add(node.id, DEF_LOCAL)

    def visit_NamedExpr(self, node):
        self.visit(node.value)
        t = node.target
        # the nearest block that is not a generator expression's
        i = len(self.stack) - 1
        while i > 0 and self.stack[i].name == "genexpr":
            i -= 1
        self.add(t.id, DEF_LOCAL, self.stack[i])
        if i != len(self.stack) - 1:
            self.add(t.id, DEF_NONLOCAL)

    def _comp(self, node, elts, inline):
        gens = node.generators
        self.visit(gens[0].iter)
        if not inline:
            self.enter("genexpr", TYPE_FUNCTION, node.lineno)
            self.add(".0", DEF_PARAM)
        for k, g in enumerate(gens):
            self._comp_target(g.target)
            if k > 0:
                self.visit(g.iter)
            self.visit_seq(g.ifs)
        for e in elts:
            self.visit(e)
        if not inline:
            self.leave()

    def _comp_target(self, t):
        if isinstance(t, _ast.Name):
            self.add(t.id, DEF_LOCAL | DEF_COMP_ITER)
        elif isinstance(t, (_ast.Tuple, _ast.List)):
            for e in t.elts:
                self._comp_target(e)
        elif isinstance(t, _ast.Starred):
            self._comp_target(t.value)
        else:
            self.visit(t)

    def visit_ListComp(self, node):
        self._comp(node, [node.elt], True)

    def visit_SetComp(self, node):
        self._comp(node, [node.elt], True)

    def visit_DictComp(self, node):
        self._comp(node, [node.value, node.key], True)

    def visit_GeneratorExp(self, node):
        self._comp(node, [node.elt], False)


def _analyze(table, bound, global_names, parent_type):
    """Give every name of `table` its scope (CPython's analyze_block). `bound`:
    names bound in the enclosing function blocks (visible as free variables);
    returns the names this block uses free (for its parent to make cells)."""
    local = set()
    for name, flags in table.symbols.items():
        if flags & DEF_BOUND and not flags & (DEF_GLOBAL | DEF_NONLOCAL):
            local.add(name)
    glob = set(global_names)
    free = set()
    scopes = {}
    for name, flags in table.symbols.items():
        if flags & DEF_GLOBAL:
            scopes[name] = GLOBAL_EXPLICIT
            glob.add(name)
        elif flags & DEF_NONLOCAL:
            if name not in bound:
                raise SyntaxError("no binding for nonlocal '%s' found" % name)
            scopes[name] = FREE
            free.add(name)
        elif flags & DEF_BOUND:
            scopes[name] = LOCAL
            if name in glob:
                glob.discard(name)
        elif name in bound and table.type != TYPE_MODULE:
            scopes[name] = FREE
            free.add(name)
        else:
            scopes[name] = GLOBAL_IMPLICIT
    # what the children see as enclosing bindings
    if table.type == TYPE_FUNCTION:
        child_bound = set(bound) | local
        for n in scopes:
            if scopes[n] == FREE:
                child_bound.add(n)
    elif table.type == TYPE_CLASS:
        child_bound = set(bound)
        child_bound.add("__class__")
    else:
        child_bound = set()
    child_free = set()
    for child in table.children:
        child_free |= _analyze(child, child_bound, glob, table.type)
    # a name a child uses free that this function binds is a cell here
    for n in child_free:
        if table.type == TYPE_FUNCTION and n in local:
            scopes[n] = CELL
        elif table.type == TYPE_CLASS and n == "__class__":
            pass
        elif table.type == TYPE_CLASS and n in local:
            # bound in the class and free in a method: the method's comes
            # from the enclosing function (DEF_FREE_CLASS)
            table.symbols[n] = table.symbols[n] | DEF_FREE_CLASS
            free.add(n)
        elif n not in scopes:
            if table.type == TYPE_MODULE:
                continue
            table.symbols[n] = DEF_FREE
            scopes[n] = FREE
            free.add(n)
        elif scopes[n] == FREE:
            free.add(n)
    for name in scopes:
        table.symbols[name] = (table.symbols[name] & ~(SCOPE_MASK << SCOPE_OFF)) | (scopes[name] << SCOPE_OFF)
    return free


def _implicit_class(table, in_class):
    # super() / __class__ in a method: the class's implicit __class__ cell
    for child in table.children:
        if table.type == TYPE_CLASS and child.type == TYPE_FUNCTION and child.uses_super:
            child.symbols["__class__"] = child.symbols.get("__class__", 0) | USE
        _implicit_class(child, table.type == TYPE_CLASS)


def _build(code, filename, compile_type):
    if isinstance(code, _ast.AST):
        tree = code
    else:
        if compile_type not in ("exec", "eval", "single"):
            raise ValueError("symtable() arg 3 must be 'exec' or 'eval' or 'single'")
        tree = _ast.parse(code, filename, compile_type)
    b = _Builder(filename)
    top = b.run(tree)
    _implicit_class(top, False)
    _analyze(top, set(), set(), None)
    return top


def symtable(code, filename, compile_type):
    """ Return the toplevel *SymbolTable* for the source code.

    *filename* is the name of the file with the code
    and *compile_type* is the *compile()* mode argument.
    """
    top = _build(code, filename, compile_type)
    return _newSymbolTable(top, filename)


class SymbolTableFactory:
    def __init__(self):
        self.__memo = {}

    def new(self, table, filename):
        if table.type == TYPE_FUNCTION:
            return Function(table, filename)
        if table.type == TYPE_CLASS:
            return Class(table, filename)
        return SymbolTable(table, filename)

    def __call__(self, table, filename):
        key = (id(table), filename)
        obj = self.__memo.get(key, None)
        if obj is None or obj._table is not table:
            obj = self.__memo[key] = self.new(table, filename)
        return obj

_newSymbolTable = SymbolTableFactory()


class SymbolTable:

    def __init__(self, raw_table, filename):
        self._table = raw_table
        self._filename = filename
        self._symbols = {}

    def __repr__(self):
        if self.__class__ == SymbolTable:
            kind = ""
        else:
            kind = "%s " % self.__class__.__name__

        if self._table.name == "top":
            return "<{0}SymbolTable for module {1}>".format(kind, self._filename)
        else:
            return "<{0}SymbolTable for {1} in {2}>".format(kind,
                                                            self._table.name,
                                                            self._filename)

    def get_type(self):
        """Return the type of the symbol table.

        The values returned are 'class', 'module', 'function',
        'annotation', 'TypeVar bound', 'type alias', and 'type parameter'.
        """
        if self._table.type == TYPE_MODULE:
            return "module"
        if self._table.type == TYPE_FUNCTION:
            return "function"
        if self._table.type == TYPE_CLASS:
            return "class"
        raise AssertionError(f"unexpected type: {self._table.type}")

    def get_id(self):
        """Return an identifier for the table.
        """
        return self._table.id

    def get_name(self):
        """Return the table's name.

        This corresponds to the name of the class, function
        or 'top' if the table is for a class, function or
        global respectively.
        """
        return self._table.name

    def get_lineno(self):
        """Return the number of the first line in the
        block for the table.
        """
        return self._table.lineno

    def is_optimized(self):
        """Return *True* if the locals in the table
        are optimizable.
        """
        return bool(self._table.type == TYPE_FUNCTION)

    def is_nested(self):
        """Return *True* if the block is a nested class
        or function."""
        return bool(self._table.nested)

    def has_children(self):
        """Return *True* if the block has nested namespaces.
        """
        return bool(self._table.children)

    def get_identifiers(self):
        """Return a view object containing the names of symbols in the table.
        """
        return self._table.symbols.keys()

    def lookup(self, name):
        """Lookup a *name* in the table.

        Returns a *Symbol* instance.
        """
        sym = self._symbols.get(name)
        if sym is None:
            flags = self._table.symbols[name]
            namespaces = self.__check_children(name)
            module_scope = (self._table.name == "top")
            sym = self._symbols[name] = Symbol(name, flags, namespaces,
                                               module_scope=module_scope)
        return sym

    def get_symbols(self):
        """Return a list of *Symbol* instances for
        names in the table.
        """
        return [self.lookup(ident) for ident in self.get_identifiers()]

    def __check_children(self, name):
        return [_newSymbolTable(st, self._filename)
                for st in self._table.children
                if st.name == name]

    def get_children(self):
        """Return a list of the nested symbol tables.
        """
        return [_newSymbolTable(st, self._filename)
                for st in self._table.children]


class Function(SymbolTable):

    # Default values for instance variables
    __params = None
    __locals = None
    __frees = None
    __globals = None
    __nonlocals = None

    def __idents_matching(self, test_func):
        return tuple(ident for ident in self.get_identifiers()
                     if test_func(self._table.symbols[ident]))

    def get_parameters(self):
        """Return a tuple of parameters to the function.
        """
        if self.__params is None:
            self.__params = self.__idents_matching(lambda x:x & DEF_PARAM)
        return self.__params

    def get_locals(self):
        """Return a tuple of locals in the function.
        """
        if self.__locals is None:
            locs = (LOCAL, CELL)
            test = lambda x: ((x >> SCOPE_OFF) & SCOPE_MASK) in locs
            self.__locals = self.__idents_matching(test)
        return self.__locals

    def get_globals(self):
        """Return a tuple of globals in the function.
        """
        if self.__globals is None:
            glob = (GLOBAL_IMPLICIT, GLOBAL_EXPLICIT)
            test = lambda x:((x >> SCOPE_OFF) & SCOPE_MASK) in glob
            self.__globals = self.__idents_matching(test)
        return self.__globals

    def get_nonlocals(self):
        """Return a tuple of nonlocals in the function.
        """
        if self.__nonlocals is None:
            self.__nonlocals = self.__idents_matching(lambda x:x & DEF_NONLOCAL)
        return self.__nonlocals

    def get_frees(self):
        """Return a tuple of free variables in the function.
        """
        if self.__frees is None:
            is_free = lambda x:((x >> SCOPE_OFF) & SCOPE_MASK) == FREE
            self.__frees = self.__idents_matching(is_free)
        return self.__frees


class Class(SymbolTable):

    __methods = None

    def get_methods(self):
        """Return a tuple of methods declared in the class.
        """
        if self.__methods is None:
            d = {}
            for st in self._table.children:
                d[st.name] = 1
            self.__methods = tuple(d)
        return self.__methods


class Symbol:

    def __init__(self, name, flags, namespaces=None, *, module_scope=False):
        self.__name = name
        self.__flags = flags
        self.__scope = (flags >> SCOPE_OFF) & SCOPE_MASK # like PyST_GetScope()
        self.__namespaces = namespaces or ()
        self.__module_scope = module_scope

    def __repr__(self):
        return "<symbol {0!r}>".format(self.__name)

    def get_name(self):
        """Return a name of a symbol.
        """
        return self.__name

    def is_referenced(self):
        """Return *True* if the symbol is used in
        its block.
        """
        return bool(self.__flags & USE)

    def is_parameter(self):
        """Return *True* if the symbol is a parameter.
        """
        return bool(self.__flags & DEF_PARAM)

    def is_global(self):
        """Return *True* if the symbol is global.
        """
        return bool(self.__scope in (GLOBAL_IMPLICIT, GLOBAL_EXPLICIT)
                    or (self.__module_scope and self.__flags & DEF_BOUND))

    def is_nonlocal(self):
        """Return *True* if the symbol is nonlocal."""
        return bool(self.__flags & DEF_NONLOCAL)

    def is_declared_global(self):
        """Return *True* if the symbol is declared global
        with a global statement."""
        return bool(self.__scope == GLOBAL_EXPLICIT)

    def is_local(self):
        """Return *True* if the symbol is local.
        """
        return bool(self.__scope in (LOCAL, CELL)
                    or (self.__module_scope and self.__flags & DEF_BOUND))

    def is_annotated(self):
        """Return *True* if the symbol is annotated.
        """
        return bool(self.__flags & DEF_ANNOT)

    def is_free(self):
        """Return *True* if a referenced symbol is
        not assigned to.
        """
        return bool(self.__scope == FREE)

    def is_imported(self):
        """Return *True* if the symbol is created from
        an import statement.
        """
        return bool(self.__flags & DEF_IMPORT)

    def is_assigned(self):
        """Return *True* if a symbol is assigned to."""
        return bool(self.__flags & DEF_LOCAL)

    def is_namespace(self):
        """Returns *True* if name binding introduces new namespace.

        If the name is used as the target of a function or class
        statement, this will be true.

        Note that a single name can be bound to multiple objects.  If
        is_namespace() is true, the name may also be bound to other
        objects, like an int or list, that does not introduce a new
        namespace.
        """
        return bool(self.__namespaces)

    def get_namespaces(self):
        """Return a list of namespaces bound to this name"""
        return self.__namespaces

    def get_namespace(self):
        """Return the single namespace bound to this name.

        Raises ValueError if the name is bound to multiple namespaces
        or no namespace.
        """
        if len(self.__namespaces) == 0:
            raise ValueError("name is not bound to any namespaces")
        elif len(self.__namespaces) > 1:
            raise ValueError("name is bound to multiple namespaces")
        else:
            return self.__namespaces[0]

if __name__ == "__main__":
    import os, sys
    with open(sys.argv[0]) as f:
        src = f.read()
    mod = symtable(src, os.path.split(sys.argv[0])[1], "exec")
    for ident in mod.get_identifiers():
        info = mod.lookup(ident)
        print(info, info.is_local(), info.is_namespace())
