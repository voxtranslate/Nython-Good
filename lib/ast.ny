# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/ast.ny - Python's ast (round 83): Python's abstract syntax trees, as
# CPython 3.12's module has them, built from Nython's own parser.
#
#     import ast
#     tree = ast.parse(source)          print(ast.dump(tree, indent=4))
#     ast.unparse(tree)                 ast.literal_eval("[1, (2, 'x')]")
#     compile(tree, "<ast>", "exec")    compile(src, f, "exec", ast.PyCF_ONLY_AST)
#
# parse(source, filename='<unknown>', mode='exec', *, type_comments=False,
#       feature_version=None)
#     mode 'exec' (Module), 'eval' (Expression), 'single' (Interactive),
#     'func_type' (FunctionType). The tree is the REAL parser's: the native
#     _ny_ast (src/builtins/text.cpp) parses with Parser::parseAst - the
#     parser that runs every Nython program, in an "ast mode" where it keeps
#     Python's shape at each place it would desugar (decorators, chained
#     comparisons, slices, f-strings, starred displays and unpacking
#     assignments, match, except clauses, imports, with items, async
#     constructs) - and maps it onto CPython's node classes; what Nython's
#     parser does to a program (private-name mangling, `except <expr>`
#     lowering, `-O` dropping asserts, __annotations__ stores) is not in
#     the tree, which is Python's for Python source. Every node has
#     CPython's lineno/col_offset/end_lineno/end_col_offset (columns are
#     UTF-8 byte offsets), the parentheses around an expression excluded and
#     a tuple's or generator's own included, as CPython 3.12 - inside an
#     f-string too: each literal run (a plain literal joined to it with its
#     quotes), field ({ to }), format spec (: to }) and the nodes of a
#     field's expression. A syntax error is a SyntaxError with lineno/
#     offset/text/end_lineno/end_offset: CPython's messages for brackets
#     ("'(' was never closed", "unmatched ')'", "closing parenthesis ']'
#     does not match opening parenthesis '('") and "invalid syntax" where
#     Nython's parser found an unexpected token (CPython's more specific
#     wordings - "expected ':'", "Perhaps you forgot a comma?" - are not
#     reproduced); its other messages are Nython's parser's.
# The node classes: AST, mod/stmt/expr/... and every concrete node of 3.12
#     (Module ... TypeVarTuple) with _fields, _attributes, __match_args__ and
#     the class-level None of the optional fields (dump leaves those out);
#     Load/Store/Del, the operator singletons; the deprecated Num/Str/Bytes/
#     NameConstant (constructors that give a Constant), Index, ExtSlice.
# dump(node, annotate_fields=True, include_attributes=False, *, indent=None)
# unparse(node)       CPython's _Unparser: precedence-correct, quotes chosen
#                     as CPython chooses them (parse(unparse(t)) dumps as t)
# literal_eval(node_or_string)   CPython's rules and messages ("malformed
#                     node or string on line 1: <ast.Name object at ...>")
# NodeVisitor, NodeTransformer, walk, iter_fields, iter_child_nodes,
# copy_location, fix_missing_locations, increment_lineno, get_docstring,
# get_source_segment, PyCF_ONLY_AST, PyCF_TYPE_COMMENTS,
# PyCF_ALLOW_TOP_LEVEL_AWAIT; `nython -m ast [-m mode] [-a] [-i n] file`.
# compile(tree, filename, mode) - on both engines, the builtin hands an AST
#     to _ny_compile here - compiles the tree's unparsed source, written
#     with each statement on its tree's line (blank lines put before it),
#     so tracebacks, line events and frame lines of the compiled code are
#     the tree's linenos (a statement spanning lines in the tree is one
#     line of code; nodes moved out of order keep the order they are in).
#     A node missing a lineno is CPython's TypeError ("required field
#     \"lineno\" missing from stmt"); a Module for 'eval' its TypeError.
#
# Nython-only syntax gives Nython node classes, documented here: NyRange
# (`a..b` / `a...b`: lower, upper, step, inclusive), the operators
# NyCoalesce (`a ?? b`, a BinOp), NyXor (`xor`/`^^`), NyStrictEq/
# NyStrictNotEq (`===`/`!==`) and NyInstanceOf (comparisons), NyUnaryOp
# (`x++`), NyNode (any other: kind); `var/let/const x = v` is an Assign, the
# `print x` statement a print() call, `unless c:` an If(not c), a C-style
# for/`repeat`/`loop` the while loop they mean, `true`/`false`/`none`
# Names (as Python reads them).
#
# Not here: type_comments (no TypeIgnore or type_comment is ever set: the
# tokens carry no comments) and feature_version (accepted, ignored); 3.12's
# `type X = ...` statement and generic `def f[T]` / `class C[T]` (Nython's
# parser does not read them; TypeAlias/TypeVar/ParamSpec/TypeVarTuple exist
# for trees built by hand, and unparse writes them); optimize= / the
# constant folding of 3.13's PyCF_OPTIMIZED_AST. The nodes of an f-string
# nested in another's field, of a raw f-string (rf'...') and of one whose
# escape sequence makes a brace are located at the whole string.
# The deprecated ast.Ellipsis alias is not provided (the name is Python's
# Ellipsis value in this module).

import sys
import re

__all__ = ["parse", "unparse", "literal_eval", "dump", "walk", "iter_fields", "iter_child_nodes",
           "copy_location", "fix_missing_locations", "increment_lineno", "get_docstring",
           "get_source_segment", "NodeVisitor", "NodeTransformer", "AST",
           "PyCF_ONLY_AST", "PyCF_TYPE_COMMENTS", "PyCF_ALLOW_TOP_LEVEL_AWAIT"]

PyCF_ONLY_AST = 1024
PyCF_TYPE_COMMENTS = 4096
PyCF_ALLOW_TOP_LEVEL_AWAIT = 8192


class AST:
    _fields = ()
    _attributes = ()
    __match_args__ = ()

    def __init__(self, *args, **kwargs):
        fields = type(self)._fields
        if len(args) > len(fields):
            n = len(fields)
            raise TypeError("%s constructor takes at most %d positional argument%s"
                            % (type(self).__name__, n, "" if n == 1 else "s"))
        i = 0
        for a in args:
            setattr(self, fields[i], a)
            i += 1
        for k in kwargs:
            if k in fields and fields.index(k) < len(args):
                raise TypeError("%s got multiple values for argument %r" % (type(self).__name__, k))
            setattr(self, k, kwargs[k])

    def __reduce__(self):
        return (type(self), (), dict(self.__dict__))


class operator(AST):
    _fields = ()
    _attributes = ()
    __match_args__ = ()

class Add(operator):
    _fields = ()
    __match_args__ = ()

class boolop(AST):
    _fields = ()
    _attributes = ()
    __match_args__ = ()

class And(boolop):
    _fields = ()
    __match_args__ = ()

class stmt(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ()
    end_lineno = None
    end_col_offset = None

class AnnAssign(stmt):
    _fields = ('target', 'annotation', 'value', 'simple')
    __match_args__ = ('target', 'annotation', 'value', 'simple')
    value = None

class Assert(stmt):
    _fields = ('test', 'msg')
    __match_args__ = ('test', 'msg')
    msg = None

class Assign(stmt):
    _fields = ('targets', 'value', 'type_comment')
    __match_args__ = ('targets', 'value', 'type_comment')
    type_comment = None

class AsyncFor(stmt):
    _fields = ('target', 'iter', 'body', 'orelse', 'type_comment')
    __match_args__ = ('target', 'iter', 'body', 'orelse', 'type_comment')
    type_comment = None

class AsyncFunctionDef(stmt):
    _fields = ('name', 'args', 'body', 'decorator_list', 'returns', 'type_comment', 'type_params')
    __match_args__ = ('name', 'args', 'body', 'decorator_list', 'returns', 'type_comment', 'type_params')
    returns = None
    type_comment = None

class AsyncWith(stmt):
    _fields = ('items', 'body', 'type_comment')
    __match_args__ = ('items', 'body', 'type_comment')
    type_comment = None

class expr(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ()
    end_lineno = None
    end_col_offset = None

class Attribute(expr):
    _fields = ('value', 'attr', 'ctx')
    __match_args__ = ('value', 'attr', 'ctx')

class AugAssign(stmt):
    _fields = ('target', 'op', 'value')
    __match_args__ = ('target', 'op', 'value')

class Await(expr):
    _fields = ('value',)
    __match_args__ = ('value',)

class BinOp(expr):
    _fields = ('left', 'op', 'right')
    __match_args__ = ('left', 'op', 'right')

class BitAnd(operator):
    _fields = ()
    __match_args__ = ()

class BitOr(operator):
    _fields = ()
    __match_args__ = ()

class BitXor(operator):
    _fields = ()
    __match_args__ = ()

class BoolOp(expr):
    _fields = ('op', 'values')
    __match_args__ = ('op', 'values')

class Break(stmt):
    _fields = ()
    __match_args__ = ()

class Call(expr):
    _fields = ('func', 'args', 'keywords')
    __match_args__ = ('func', 'args', 'keywords')

class ClassDef(stmt):
    _fields = ('name', 'bases', 'keywords', 'body', 'decorator_list', 'type_params')
    __match_args__ = ('name', 'bases', 'keywords', 'body', 'decorator_list', 'type_params')

class Compare(expr):
    _fields = ('left', 'ops', 'comparators')
    __match_args__ = ('left', 'ops', 'comparators')

class Constant(expr):
    _fields = ('value', 'kind')
    __match_args__ = ('value', 'kind')
    kind = None

class Continue(stmt):
    _fields = ()
    __match_args__ = ()

class expr_context(AST):
    _fields = ()
    _attributes = ()
    __match_args__ = ()

class Del(expr_context):
    _fields = ()
    __match_args__ = ()

class Delete(stmt):
    _fields = ('targets',)
    __match_args__ = ('targets',)

class Dict(expr):
    _fields = ('keys', 'values')
    __match_args__ = ('keys', 'values')

class DictComp(expr):
    _fields = ('key', 'value', 'generators')
    __match_args__ = ('key', 'value', 'generators')

class Div(operator):
    _fields = ()
    __match_args__ = ()

class cmpop(AST):
    _fields = ()
    _attributes = ()
    __match_args__ = ()

class Eq(cmpop):
    _fields = ()
    __match_args__ = ()

class excepthandler(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ()
    end_lineno = None
    end_col_offset = None

class ExceptHandler(excepthandler):
    _fields = ('type', 'name', 'body')
    __match_args__ = ('type', 'name', 'body')
    type = None
    name = None

class Expr(stmt):
    _fields = ('value',)
    __match_args__ = ('value',)

class mod(AST):
    _fields = ()
    _attributes = ()
    __match_args__ = ()

class Expression(mod):
    _fields = ('body',)
    __match_args__ = ('body',)

class FloorDiv(operator):
    _fields = ()
    __match_args__ = ()

class For(stmt):
    _fields = ('target', 'iter', 'body', 'orelse', 'type_comment')
    __match_args__ = ('target', 'iter', 'body', 'orelse', 'type_comment')
    type_comment = None

class FormattedValue(expr):
    _fields = ('value', 'conversion', 'format_spec')
    __match_args__ = ('value', 'conversion', 'format_spec')
    format_spec = None

class FunctionDef(stmt):
    _fields = ('name', 'args', 'body', 'decorator_list', 'returns', 'type_comment', 'type_params')
    __match_args__ = ('name', 'args', 'body', 'decorator_list', 'returns', 'type_comment', 'type_params')
    returns = None
    type_comment = None

class FunctionType(mod):
    _fields = ('argtypes', 'returns')
    __match_args__ = ('argtypes', 'returns')

class GeneratorExp(expr):
    _fields = ('elt', 'generators')
    __match_args__ = ('elt', 'generators')

class Global(stmt):
    _fields = ('names',)
    __match_args__ = ('names',)

class Gt(cmpop):
    _fields = ()
    __match_args__ = ()

class GtE(cmpop):
    _fields = ()
    __match_args__ = ()

class If(stmt):
    _fields = ('test', 'body', 'orelse')
    __match_args__ = ('test', 'body', 'orelse')

class IfExp(expr):
    _fields = ('test', 'body', 'orelse')
    __match_args__ = ('test', 'body', 'orelse')

class Import(stmt):
    _fields = ('names',)
    __match_args__ = ('names',)

class ImportFrom(stmt):
    _fields = ('module', 'names', 'level')
    __match_args__ = ('module', 'names', 'level')
    module = None
    level = None

class In(cmpop):
    _fields = ()
    __match_args__ = ()

class Interactive(mod):
    _fields = ('body',)
    __match_args__ = ('body',)

class unaryop(AST):
    _fields = ()
    _attributes = ()
    __match_args__ = ()

class Invert(unaryop):
    _fields = ()
    __match_args__ = ()

class Is(cmpop):
    _fields = ()
    __match_args__ = ()

class IsNot(cmpop):
    _fields = ()
    __match_args__ = ()

class JoinedStr(expr):
    _fields = ('values',)
    __match_args__ = ('values',)

class LShift(operator):
    _fields = ()
    __match_args__ = ()

class Lambda(expr):
    _fields = ('args', 'body')
    __match_args__ = ('args', 'body')

class List(expr):
    _fields = ('elts', 'ctx')
    __match_args__ = ('elts', 'ctx')

class ListComp(expr):
    _fields = ('elt', 'generators')
    __match_args__ = ('elt', 'generators')

class Load(expr_context):
    _fields = ()
    __match_args__ = ()

class Lt(cmpop):
    _fields = ()
    __match_args__ = ()

class LtE(cmpop):
    _fields = ()
    __match_args__ = ()

class MatMult(operator):
    _fields = ()
    __match_args__ = ()

class Match(stmt):
    _fields = ('subject', 'cases')
    __match_args__ = ('subject', 'cases')

class pattern(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ()

class MatchAs(pattern):
    _fields = ('pattern', 'name')
    __match_args__ = ('pattern', 'name')
    pattern = None
    name = None

class MatchClass(pattern):
    _fields = ('cls', 'patterns', 'kwd_attrs', 'kwd_patterns')
    __match_args__ = ('cls', 'patterns', 'kwd_attrs', 'kwd_patterns')

class MatchMapping(pattern):
    _fields = ('keys', 'patterns', 'rest')
    __match_args__ = ('keys', 'patterns', 'rest')
    rest = None

class MatchOr(pattern):
    _fields = ('patterns',)
    __match_args__ = ('patterns',)

class MatchSequence(pattern):
    _fields = ('patterns',)
    __match_args__ = ('patterns',)

class MatchSingleton(pattern):
    _fields = ('value',)
    __match_args__ = ('value',)

class MatchStar(pattern):
    _fields = ('name',)
    __match_args__ = ('name',)
    name = None

class MatchValue(pattern):
    _fields = ('value',)
    __match_args__ = ('value',)

class Mod(operator):
    _fields = ()
    __match_args__ = ()

class Module(mod):
    _fields = ('body', 'type_ignores')
    __match_args__ = ('body', 'type_ignores')

class Mult(operator):
    _fields = ()
    __match_args__ = ()

class Name(expr):
    _fields = ('id', 'ctx')
    __match_args__ = ('id', 'ctx')

class NamedExpr(expr):
    _fields = ('target', 'value')
    __match_args__ = ('target', 'value')

class Nonlocal(stmt):
    _fields = ('names',)
    __match_args__ = ('names',)

class Not(unaryop):
    _fields = ()
    __match_args__ = ()

class NotEq(cmpop):
    _fields = ()
    __match_args__ = ()

class NotIn(cmpop):
    _fields = ()
    __match_args__ = ()

class Or(boolop):
    _fields = ()
    __match_args__ = ()

class type_param(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ()

class ParamSpec(type_param):
    _fields = ('name',)
    __match_args__ = ('name',)

class Pass(stmt):
    _fields = ()
    __match_args__ = ()

class Pow(operator):
    _fields = ()
    __match_args__ = ()

class RShift(operator):
    _fields = ()
    __match_args__ = ()

class Raise(stmt):
    _fields = ('exc', 'cause')
    __match_args__ = ('exc', 'cause')
    exc = None
    cause = None

class Return(stmt):
    _fields = ('value',)
    __match_args__ = ('value',)
    value = None

class Set(expr):
    _fields = ('elts',)
    __match_args__ = ('elts',)

class SetComp(expr):
    _fields = ('elt', 'generators')
    __match_args__ = ('elt', 'generators')

class Slice(expr):
    _fields = ('lower', 'upper', 'step')
    __match_args__ = ('lower', 'upper', 'step')
    lower = None
    upper = None
    step = None

class Starred(expr):
    _fields = ('value', 'ctx')
    __match_args__ = ('value', 'ctx')

class Store(expr_context):
    _fields = ()
    __match_args__ = ()

class Sub(operator):
    _fields = ()
    __match_args__ = ()

class Subscript(expr):
    _fields = ('value', 'slice', 'ctx')
    __match_args__ = ('value', 'slice', 'ctx')

class Try(stmt):
    _fields = ('body', 'handlers', 'orelse', 'finalbody')
    __match_args__ = ('body', 'handlers', 'orelse', 'finalbody')

class TryStar(stmt):
    _fields = ('body', 'handlers', 'orelse', 'finalbody')
    __match_args__ = ('body', 'handlers', 'orelse', 'finalbody')

class Tuple(expr):
    _fields = ('elts', 'ctx')
    __match_args__ = ('elts', 'ctx')

class TypeAlias(stmt):
    _fields = ('name', 'type_params', 'value')
    __match_args__ = ('name', 'type_params', 'value')

class type_ignore(AST):
    _fields = ()
    _attributes = ()
    __match_args__ = ()

class TypeIgnore(type_ignore):
    _fields = ('lineno', 'tag')
    __match_args__ = ('lineno', 'tag')

class TypeVar(type_param):
    _fields = ('name', 'bound')
    __match_args__ = ('name', 'bound')
    bound = None

class TypeVarTuple(type_param):
    _fields = ('name',)
    __match_args__ = ('name',)

class UAdd(unaryop):
    _fields = ()
    __match_args__ = ()

class USub(unaryop):
    _fields = ()
    __match_args__ = ()

class UnaryOp(expr):
    _fields = ('op', 'operand')
    __match_args__ = ('op', 'operand')

class While(stmt):
    _fields = ('test', 'body', 'orelse')
    __match_args__ = ('test', 'body', 'orelse')

class With(stmt):
    _fields = ('items', 'body', 'type_comment')
    __match_args__ = ('items', 'body', 'type_comment')
    type_comment = None

class Yield(expr):
    _fields = ('value',)
    __match_args__ = ('value',)
    value = None

class YieldFrom(expr):
    _fields = ('value',)
    __match_args__ = ('value',)

class alias(AST):
    _fields = ('name', 'asname')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ('name', 'asname')
    asname = None
    end_lineno = None
    end_col_offset = None

class arg(AST):
    _fields = ('arg', 'annotation', 'type_comment')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ('arg', 'annotation', 'type_comment')
    annotation = None
    type_comment = None
    end_lineno = None
    end_col_offset = None

class arguments(AST):
    _fields = ('posonlyargs', 'args', 'vararg', 'kwonlyargs', 'kw_defaults', 'kwarg', 'defaults')
    _attributes = ()
    __match_args__ = ('posonlyargs', 'args', 'vararg', 'kwonlyargs', 'kw_defaults', 'kwarg', 'defaults')
    vararg = None
    kwarg = None

class comprehension(AST):
    _fields = ('target', 'iter', 'ifs', 'is_async')
    _attributes = ()
    __match_args__ = ('target', 'iter', 'ifs', 'is_async')

class keyword(AST):
    _fields = ('arg', 'value')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ('arg', 'value')
    arg = None
    end_lineno = None
    end_col_offset = None

class match_case(AST):
    _fields = ('pattern', 'guard', 'body')
    _attributes = ()
    __match_args__ = ('pattern', 'guard', 'body')
    guard = None

class withitem(AST):
    _fields = ('context_expr', 'optional_vars')
    _attributes = ()
    __match_args__ = ('context_expr', 'optional_vars')
    optional_vars = None


# ── Nython's own nodes (Nython-only syntax) ─────────────────────────────────

class NyRange(expr):
    # a..b (inclusive=0), a...b (inclusive=1), a..b..step
    _fields = ('lower', 'upper', 'step', 'inclusive')
    __match_args__ = ('lower', 'upper', 'step', 'inclusive')
    step = None

class NyNode(AST):
    # anything else Nython's parser reads that Python has no node for
    _fields = ('kind',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    __match_args__ = ('kind',)
    end_lineno = None
    end_col_offset = None

class NyUnaryOp(expr):
    # x++ / x-- (op is the operator's text)
    _fields = ('op', 'operand')
    __match_args__ = ('op', 'operand')

class NyCoalesce(operator):
    _fields = ()

class NyXor(operator):
    _fields = ()

class NyStrictEq(cmpop):
    _fields = ()

class NyStrictNotEq(cmpop):
    _fields = ()

class NyInstanceOf(cmpop):
    _fields = ()


# ── deprecated classes (CPython 3.12 keeps them, warning) ──────────────────

class _ABC(type):
    def __instancecheck__(cls, inst):
        if not isinstance(inst, Constant):
            return False
        want = _const_types.get(cls)
        if want is None:
            return type.__instancecheck__(cls, inst)
        v = getattr(inst, "value", None)
        if cls is Num and isinstance(v, bool):
            return False
        return isinstance(v, want)


def _deprecated_const(name, args, kwargs):
    import warnings
    warnings.warn("ast.%s is deprecated and will be removed in Python 3.14; use ast.Constant instead" % name,
                  DeprecationWarning, 3)
    if name in ("Num", "Str", "Bytes") and args:
        return Constant(args[0], **kwargs)
    for k in ("n", "s"):
        if k in kwargs:
            v = kwargs.pop(k)
            return Constant(v, **kwargs)
    return Constant(*args, **kwargs)


class Num(Constant, metaclass=_ABC):
    _fields = ('n',)
    def __new__(cls, *args, **kwargs):
        return _deprecated_const("Num", args, kwargs)

class Str(Constant, metaclass=_ABC):
    _fields = ('s',)
    def __new__(cls, *args, **kwargs):
        return _deprecated_const("Str", args, kwargs)

class Bytes(Constant, metaclass=_ABC):
    _fields = ('s',)
    def __new__(cls, *args, **kwargs):
        return _deprecated_const("Bytes", args, kwargs)

class NameConstant(Constant, metaclass=_ABC):
    def __new__(cls, *args, **kwargs):
        return _deprecated_const("NameConstant", args, kwargs)

_const_types = {Num: (int, float, complex), Str: (str,), Bytes: (bytes,), NameConstant: (type(None), bool)}

class slice(AST):
    """Deprecated AST node class."""

class Index(slice):
    """Deprecated AST node class. Use the index value directly instead."""
    def __new__(cls, value, **kwargs):
        return value

class ExtSlice(slice):
    """Deprecated AST node class. Use ast.Tuple instead."""
    def __new__(cls, dims=(), **kwargs):
        return Tuple(list(dims), Load(), **kwargs)

class Suite(mod):
    """Deprecated AST node class.  Unused in Python 3."""

class AugLoad(expr_context):
    """Deprecated AST node class.  Unused in Python 3."""

class AugStore(expr_context):
    """Deprecated AST node class.  Unused in Python 3."""

class Param(expr_context):
    """Deprecated AST node class.  Unused in Python 3."""


def _pyrepr(v):
    # repr as CPython spells it (None, True, False - Nython's repr shows
    # none, true, false), into containers: what dump and unparse write
    if v is None:
        return "None"
    if v is True:
        return "True"
    if v is False:
        return "False"
    if isinstance(v, tuple):
        if len(v) == 1:
            return "(" + _pyrepr(v[0]) + ",)"
        return "(" + ", ".join([_pyrepr(x) for x in v]) + ")"
    if isinstance(v, list):
        return "[" + ", ".join([_pyrepr(x) for x in v]) + "]"
    if isinstance(v, frozenset):
        if not v:
            return "frozenset()"
        return "frozenset({" + ", ".join([_pyrepr(x) for x in v]) + "})"
    if isinstance(v, dict):
        return "{" + ", ".join([_pyrepr(k) + ": " + _pyrepr(v[k]) for k in v]) + "}"
    return repr(v)


# ── from the native tree to node objects ─────────────────────────────────────

_CLASSES = {}
for _c in [Add, And, AnnAssign, Assert, Assign, AsyncFor, AsyncFunctionDef, AsyncWith, Attribute,
           AugAssign, Await, BinOp, BitAnd, BitOr, BitXor, BoolOp, Break, Call, ClassDef, Compare,
           Constant, Continue, Del, Delete, Dict, DictComp, Div, Eq, ExceptHandler, Expr, Expression,
           FloorDiv, For, FormattedValue, FunctionDef, FunctionType, GeneratorExp, Global, Gt, GtE,
           If, IfExp, Import, ImportFrom, In, Interactive, Invert, Is, IsNot, JoinedStr, LShift,
           Lambda, List, ListComp, Load, Lt, LtE, MatMult, Match, MatchAs, MatchClass, MatchMapping,
           MatchOr, MatchSequence, MatchSingleton, MatchStar, MatchValue, Mod, Module, Mult, Name,
           NamedExpr, Nonlocal, Not, NotEq, NotIn, Or, ParamSpec, Pass, Pow, RShift, Raise, Return,
           Set, SetComp, Slice, Starred, Store, Sub, Subscript, Try, TryStar, Tuple, TypeAlias,
           TypeIgnore, TypeVar, TypeVarTuple, UAdd, USub, UnaryOp, While, With, Yield, YieldFrom,
           alias, arg, arguments, comprehension, keyword, match_case, withitem,
           NyRange, NyNode, NyUnaryOp, NyCoalesce, NyXor, NyStrictEq, NyStrictNotEq, NyInstanceOf]:
    _CLASSES[_c.__name__] = _c

# the operator and context singletons a parsed tree shares (as CPython's)
_SINGLE = {}

def _single(name):
    v = _SINGLE.get(name)
    if v is None:
        cls = _CLASSES.get(name)
        if cls is None:
            return name
        v = cls()
        _SINGLE[name] = v
    return v

_POS = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
_missing_pos = [False]

def _mk(d):
    t = d["_t"]
    cls = _CLASSES.get(t)
    if cls is None:
        cls = NyNode
    node = cls()
    for f in cls._fields:
        if f in d:
            v = d[f]
            if f == "op" or f == "ctx":
                if type(v) is str:
                    v = _single(v)
            elif f == "ops":
                v = [_single(o) for o in v]
            elif type(v) is dict:
                v = _mk(v)
            elif type(v) is list:
                v = [(_mk(x) if type(x) is dict else x) for x in v]
            setattr(node, f, v)
        else:
            setattr(node, f, None)
    if t == "Constant" and "value" not in d:
        if "_int" in d:
            node.value = int(d["_int"], 0)
        elif "_bytes" in d:
            node.value = d["_bytes"].encode("latin-1")
        elif "_complex" in d:
            txt = d["_complex"].replace("_", "")
            node.value = complex(0, float(txt[:-1]))
        elif "_ellipsis" in d:
            node.value = Ellipsis
    if cls._attributes:
        if "lineno" in d:
            node.lineno = d["lineno"]
            node.col_offset = d["col_offset"]
            node.end_lineno = d["end_lineno"]
            node.end_col_offset = d["end_col_offset"]
        else:
            _missing_pos[0] = True
    return node


_OPENERS = {")": "(", "]": "[", "}": "{"}


def _bracket_problem(source):
    # What CPython's tokenizer reports before its parser can: a closing
    # bracket with no opener or the wrong one, or an opener still open at
    # the end - as (kind, msg, line, col1, text, end_line, end_col1), or
    # None. Strings and comments are skipped.
    stack = []
    lines = source.split("\n")
    row = 0
    in_str = None        # the quote that ends the string being skipped
    for row in range(len(lines)):
        ln = lines[row]
        i = 0
        n = len(ln)
        while i < n:
            c = ln[i]
            if in_str is not None:
                if c == "\\":
                    i += 2
                    continue
                if ln.startswith(in_str, i):
                    i += len(in_str)
                    in_str = None
                    continue
                i += 1
                continue
            if c == "#":
                break
            if c == "'" or c == '"':
                q = ln[i:i + 3] if ln[i:i + 3] in ("'''", '"""') else c
                in_str = q
                i += len(q)
                continue
            if c in "([{":
                stack.append((c, row + 1, i))
            elif c in ")]}":
                if not stack:
                    return ("close", "unmatched '%s'" % c, row + 1, i + 1, ln, row + 1, i + 1)
                o = stack.pop()
                if o[0] != _OPENERS[c]:
                    if o[1] != row + 1:
                        m = "closing parenthesis '%s' does not match opening parenthesis '%s' on line %d" % (c, o[0], o[1])
                    else:
                        m = "closing parenthesis '%s' does not match opening parenthesis '%s'" % (c, o[0])
                    return ("close", m, row + 1, i + 1, ln, row + 1, i + 1)
            i += 1
        if in_str is not None and len(in_str) == 1:
            in_str = None    # an unterminated one-line string: the parser says so
    if stack:
        o = stack[-1]
        return ("open", "'%s' was never closed" % o[0], o[1], o[2] + 1, lines[o[1] - 1], o[1], 0)
    return None


def _syntax_error(err, filename, source=""):
    # The native parser's error, as CPython reports it where the two can
    # agree: its bracket messages (they come from CPython's tokenizer, ahead
    # of the parser), and "invalid syntax" for an unexpected token
    msg, line, col, text = err[0], err[1], err[2], err[3]
    nlines = len(source.split("\n"))
    at_end = line > nlines or (line == nlines and not text) or "End" in msg
    b = _bracket_problem(source)
    if b is not None and (b[0] == "open" and at_end or
                          b[0] == "close" and (b[2], b[3]) <= (line, col)):
        raise SyntaxError(b[1], (filename, b[2], b[3], b[4], b[5], b[6]))
    if msg.startswith("Unexpected token") or msg.startswith("Expected "):
        msg = "invalid syntax"
        if at_end:
            # at the end of the source: CPython points just past its last token
            src_lines = source.rstrip("\n").split("\n")
            line = len(src_lines)
            text = src_lines[-1]
            col = len(text.rstrip()) + 1
        raise SyntaxError(msg, (filename, line, col, text, line, col + 1))
    raise SyntaxError(msg, (filename, line, col, text, line, col))


def parse(source, filename='<unknown>', mode='exec', *,
          type_comments=False, feature_version=None):
    """
    Parse the source into an AST node.
    Equivalent to compile(source, filename, mode, PyCF_ONLY_AST).
    Pass type_comments=True to get back type comments where the syntax allows.
    """
    if isinstance(source, AST):
        return source
    if isinstance(feature_version, tuple):
        major, minor = feature_version
        if major != 3:
            raise ValueError(f"Unsupported major version: {major}")
    if isinstance(source, (bytes, bytearray)):
        data = bytes(source)
        if data.startswith(b'\xef\xbb\xbf'):
            data = data[3:]
        source = data.decode("utf-8")
    elif not isinstance(source, str):
        raise TypeError("compile() arg 1 must be a string, bytes or AST object")
    if mode not in ("exec", "eval", "single", "func_type"):
        raise ValueError("compile() mode must be 'exec', 'eval', 'single' or 'func_type'")
    if "\x00" in source:
        raise SyntaxError("source code string cannot contain null bytes")
    if mode == "eval":
        source = source.lstrip(" \t")
    tree = _ny_ast(source, mode, str(filename))
    if "_error" in tree:
        _syntax_error(tree["_error"], str(filename), source)
    _missing_pos[0] = False
    node = _mk(tree)
    if _missing_pos[0]:
        fix_missing_locations(node)
    if mode == "func_type":
        # CPython's grammar keeps the types of `*args` and `**kw`, not stars
        node.argtypes = [a.value if isinstance(a, Starred) else a for a in node.argtypes]
    return node


def literal_eval(node_or_string):
    """
    Evaluate an expression node or a string containing only a Python
    expression.  The string or node provided may only consist of the following
    Python literal structures: strings, bytes, numbers, tuples, lists, dicts,
    sets, booleans, and None.

    Caution: A complex expression can overflow the C stack and cause a crash.
    """
    if isinstance(node_or_string, str):
        node_or_string = parse(node_or_string.lstrip(" \t"), mode='eval')
    if isinstance(node_or_string, Expression):
        node_or_string = node_or_string.body
    def _raise_malformed_node(node):
        msg = "malformed node or string"
        lno = getattr(node, 'lineno', None)
        if lno:
            msg += f' on line {lno}'
        raise ValueError(msg + f': {node!r}')
    def _convert_num(node):
        if not isinstance(node, Constant) or type(node.value) not in (int, float, complex):
            _raise_malformed_node(node)
        return node.value
    def _convert_signed_num(node):
        if isinstance(node, UnaryOp) and isinstance(node.op, (UAdd, USub)):
            operand = _convert_num(node.operand)
            if isinstance(node.op, UAdd):
                return + operand
            else:
                return - operand
        return _convert_num(node)
    def _convert(node):
        if isinstance(node, Constant):
            return node.value
        elif isinstance(node, Tuple):
            return tuple(map(_convert, node.elts))
        elif isinstance(node, List):
            return list(map(_convert, node.elts))
        elif isinstance(node, Set):
            return set(map(_convert, node.elts))
        elif (isinstance(node, Call) and isinstance(node.func, Name) and
              node.func.id == 'set' and node.args == node.keywords == []):
            return set()
        elif isinstance(node, Dict):
            if len(node.keys) != len(node.values):
                _raise_malformed_node(node)
            return dict(zip(map(_convert, node.keys),
                            map(_convert, node.values)))
        elif isinstance(node, BinOp) and isinstance(node.op, (Add, Sub)):
            left = _convert_signed_num(node.left)
            right = _convert_num(node.right)
            if isinstance(left, (int, float)) and isinstance(right, complex):
                if isinstance(node.op, Add):
                    return left + right
                else:
                    return left - right
        return _convert_signed_num(node)
    return _convert(node_or_string)


def dump(node, annotate_fields=True, include_attributes=False, *, indent=None):
    """
    Return a formatted dump of the tree in node.  This is mainly useful for
    debugging purposes.  If annotate_fields is true (by default),
    the returned string will show the names and the values for fields.
    If annotate_fields is false, the result string will be more compact by
    omitting unambiguous field names.  Attributes such as line
    numbers and column offsets are not dumped by default.  If this is wanted,
    include_attributes can be set to true.  If indent is a non-negative
    integer or string, then the tree will be pretty-printed with that indent
    level. None (the default) selects the single line representation.
    """
    def _format(node, level=0):
        if indent is not None:
            level += 1
            prefix = '\n' + indent * level
            sep = ',\n' + indent * level
        else:
            prefix = ''
            sep = ', '
        if isinstance(node, AST):
            cls = type(node)
            args = []
            allsimple = True
            keywords = annotate_fields
            for name in node._fields:
                try:
                    value = getattr(node, name)
                except AttributeError:
                    keywords = True
                    continue
                if value is None and getattr(cls, name, ...) is None:
                    keywords = True
                    continue
                value, simple = _format(value, level)
                allsimple = allsimple and simple
                if keywords:
                    args.append('%s=%s' % (name, value))
                else:
                    args.append(value)
            if include_attributes and node._attributes:
                for name in node._attributes:
                    try:
                        value = getattr(node, name)
                    except AttributeError:
                        continue
                    if value is None and getattr(cls, name, ...) is None:
                        continue
                    value, simple = _format(value, level)
                    allsimple = allsimple and simple
                    args.append('%s=%s' % (name, value))
            if allsimple and len(args) <= 3:
                return '%s(%s)' % (node.__class__.__name__, ', '.join(args)), not args
            return '%s(%s%s)' % (node.__class__.__name__, prefix, sep.join(args)), False
        elif isinstance(node, list):
            if not node:
                return '[]', True
            return '[%s%s]' % (prefix, sep.join([_format(x, level)[0] for x in node])), False
        return _pyrepr(node), True

    if not isinstance(node, AST):
        raise TypeError('expected AST, got %r' % node.__class__.__name__)
    if indent is not None and not isinstance(indent, str):
        indent = ' ' * indent
    return _format(node)[0]


def copy_location(new_node, old_node):
    """
    Copy source location (`lineno`, `col_offset`, `end_lineno`, and `end_col_offset`
    attributes) from *old_node* to *new_node* if possible, and return *new_node*.
    """
    for attr in 'lineno', 'col_offset', 'end_lineno', 'end_col_offset':
        if attr in old_node._attributes and attr in new_node._attributes:
            value = getattr(old_node, attr, None)
            # end_lineno and end_col_offset are optional attributes, and they
            # should be copied whether the value is None or not.
            if value is not None or (
                hasattr(old_node, attr) and attr.startswith("end_")
            ):
                setattr(new_node, attr, value)
    return new_node


def fix_missing_locations(node):
    """
    When you compile a node tree with compile(), the compiler expects lineno and
    col_offset attributes for every node that supports them.  This is rather
    tedious to fill in for generated nodes, so this helper adds these attributes
    recursively where not already set, by setting them to the values of the
    parent node.  It works recursively starting at *node*.
    """
    def _fix(node, lineno, col_offset, end_lineno, end_col_offset):
        if 'lineno' in node._attributes:
            if not hasattr(node, 'lineno'):
                node.lineno = lineno
            else:
                lineno = node.lineno
        if 'end_lineno' in node._attributes:
            if getattr(node, 'end_lineno', None) is None:
                node.end_lineno = end_lineno
            else:
                end_lineno = node.end_lineno
        if 'col_offset' in node._attributes:
            if not hasattr(node, 'col_offset'):
                node.col_offset = col_offset
            else:
                col_offset = node.col_offset
        if 'end_col_offset' in node._attributes:
            if getattr(node, 'end_col_offset', None) is None:
                node.end_col_offset = end_col_offset
            else:
                end_col_offset = node.end_col_offset
        for child in iter_child_nodes(node):
            _fix(child, lineno, col_offset, end_lineno, end_col_offset)
    _fix(node, 1, 0, 1, 0)
    return node


def increment_lineno(node, n=1):
    """
    Increment the line number and end line number of each node in the tree
    starting at *node* by *n*. This is useful to "move code" to a different
    location in a file.
    """
    for child in walk(node):
        # TypeIgnore is a special case where lineno is not an attribute
        # but rather a field of the node itself.
        if isinstance(child, TypeIgnore):
            child.lineno = getattr(child, 'lineno', 0) + n
            continue

        if 'lineno' in child._attributes:
            child.lineno = getattr(child, 'lineno', 0) + n
        if "end_lineno" in child._attributes:
            end_lineno = getattr(child, "end_lineno", 0)
            if end_lineno is not None:
                child.end_lineno = end_lineno + n
    return node


def iter_fields(node):
    """
    Yield a tuple of ``(fieldname, value)`` for each field in ``node._fields``
    that is present on *node*.
    """
    for field in node._fields:
        try:
            yield field, getattr(node, field)
        except AttributeError:
            pass


def iter_child_nodes(node):
    """
    Yield all direct child nodes of *node*, that is, all fields that are nodes
    and all items of fields that are lists of nodes.
    """
    for name, field in iter_fields(node):
        if isinstance(field, AST):
            yield field
        elif isinstance(field, list):
            for item in field:
                if isinstance(item, AST):
                    yield item


def get_docstring(node, clean=True):
    """
    Return the docstring for the given node or None if no docstring can
    be found.  If the node provided does not have docstrings a TypeError
    will be raised.

    If *clean* is `True`, all tabs are expanded to spaces and any whitespace
    that can be uniformly removed from the second line onwards is removed.
    """
    if not isinstance(node, (AsyncFunctionDef, FunctionDef, ClassDef, Module)):
        raise TypeError("%r can't have docstrings" % node.__class__.__name__)
    if not(node.body and isinstance(node.body[0], Expr)):
        return None
    node = node.body[0].value
    if isinstance(node, Constant) and isinstance(node.value, str):
        text = node.value
    else:
        return None
    if clean:
        import inspect
        text = inspect.cleandoc(text)
    return text


def _splitlines_no_ff(source, maxlines=None):
    """Split a string into lines ignoring form feed and other chars.

    This mimics how the Python parser splits source code.
    """
    lines = []
    i = 0
    n = len(source)
    while i <= n:
        if maxlines is not None and len(lines) >= maxlines:
            break
        j = i
        while j < n and source[j] != '\n' and source[j] != '\r':
            j += 1
        if j < n:
            if source[j] == '\r' and j + 1 < n and source[j + 1] == '\n':
                j += 2
            else:
                j += 1
        lines.append(source[i:j])
        if j >= n:
            break
        i = j
    return lines


def _pad_whitespace(source):
    r"""Replace all chars except '\f\t' in a line with spaces."""
    result = ''
    for c in source:
        if c in '\f\t':
            result += c
        else:
            result += ' '
    return result


def get_source_segment(source, node, *, padded=False):
    """Get source code segment of the *source* that generated *node*.

    If some location information (`lineno`, `end_lineno`, `col_offset`,
    or `end_col_offset`) is missing, return None.

    If *padded* is `True`, the first line of a multi-line statement will
    be padded with spaces to match its original position.
    """
    try:
        if node.end_lineno is None or node.end_col_offset is None:
            return None
        lineno = node.lineno - 1
        end_lineno = node.end_lineno - 1
        col_offset = node.col_offset
        end_col_offset = node.end_col_offset
    except AttributeError:
        return None

    lines = _splitlines_no_ff(source, maxlines=end_lineno+1)
    if end_lineno == lineno:
        return lines[lineno].encode()[col_offset:end_col_offset].decode()

    if padded:
        padding = _pad_whitespace(lines[lineno].encode()[:col_offset].decode())
    else:
        padding = ''

    first = padding + lines[lineno].encode()[col_offset:].decode()
    last = lines[end_lineno].encode()[:end_col_offset].decode()
    lines = lines[lineno+1:end_lineno]

    lines.insert(0, first)
    lines.append(last)
    return ''.join(lines)


def walk(node):
    """
    Recursively yield all descendant nodes in the tree starting at *node*
    (including *node* itself), in no specified order.  This is useful if you
    only want to modify nodes in place and don't care about the context.
    """
    from collections import deque
    todo = deque([node])
    while todo:
        node = todo.popleft()
        todo.extend(iter_child_nodes(node))
        yield node


class NodeVisitor(object):
    """
    A node visitor base class that walks the abstract syntax tree and calls a
    visitor function for every node found.  This function may return a value
    which is forwarded by the `visit` method.

    This class is meant to be subclassed, with the subclass adding visitor
    methods.

    Per default the visitor functions for the nodes are ``'visit_'`` +
    class name of the node.  So a `TryFinally` node visit function would
    be `visit_TryFinally`.  This behavior can be changed by overriding
    the `visit` method.  If no visitor function exists for a node
    (return value `None`) the `generic_visit` visitor is used instead.

    Don't use the `NodeVisitor` if you want to apply changes to nodes during
    traversing.  For this a special visitor exists (`NodeTransformer`) that
    allows modifications.
    """

    def visit(self, node):
        """Visit a node."""
        method = 'visit_' + node.__class__.__name__
        visitor = getattr(self, method, self.generic_visit)
        return visitor(node)

    def generic_visit(self, node):
        """Called if no explicit visitor function exists for a node."""
        for field, value in iter_fields(node):
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, AST):
                        self.visit(item)
            elif isinstance(value, AST):
                self.visit(value)

    def visit_Constant(self, node):
        value = node.value
        type_name = None
        if isinstance(value, bool) or value is None:
            type_name = 'NameConstant'
        elif isinstance(value, (int, float, complex)):
            type_name = 'Num'
        elif isinstance(value, str):
            type_name = 'Str'
        elif isinstance(value, bytes):
            type_name = 'Bytes'
        elif value is Ellipsis:
            type_name = 'Ellipsis'
        if type_name is not None:
            method = 'visit_' + type_name
            visitor = getattr(self, method, None)
            if visitor is not None:
                import warnings
                warnings.warn(f"{method} is deprecated; add visit_Constant",
                              DeprecationWarning, 2)
                return visitor(node)
        return self.generic_visit(node)


class NodeTransformer(NodeVisitor):
    """
    A :class:`NodeVisitor` subclass that walks the abstract syntax tree and
    allows modification of nodes.

    The `NodeTransformer` will walk the AST and use the return value of the
    visitor methods to replace or remove the old node.  If the return value of
    the visitor method is ``None``, the node will be removed from its location,
    otherwise it is replaced with the return value.  The return value may be the
    original node in which case no replacement takes place.

    For nodes that were part of a collection of statements (that applies to all
    statement nodes), the visitor may also return a list of nodes rather than
    just a single node.

    Usually you use the transformer like this::

       node = YourTransformer().visit(node)
    """

    def generic_visit(self, node):
        for field, old_value in iter_fields(node):
            if isinstance(old_value, list):
                new_values = []
                for value in old_value:
                    if isinstance(value, AST):
                        value = self.visit(value)
                        if value is None:
                            continue
                        elif not isinstance(value, AST):
                            new_values.extend(value)
                            continue
                    new_values.append(value)
                old_value[:] = new_values
            elif isinstance(old_value, AST):
                new_node = self.visit(old_value)
                if new_node is None:
                    delattr(node, field)
                else:
                    setattr(node, field, new_node)
        return node


# ── unparse (CPython's _Unparser) ────────────────────────────────────────────

# Large float and imaginary literals get turned into infinities in the AST.
# We unparse those infinities to INFSTR.
_INFSTR = "1e309"

class _Precedence:
    """Precedence table that originated from python grammar."""
    NAMED_EXPR = 1      # <target> := <expr1>
    TUPLE = 2           # <expr1>, <expr2>
    YIELD = 3           # 'yield', 'yield from'
    TEST = 4            # 'if'-'else', 'lambda'
    OR = 5              # 'or'
    AND = 6             # 'and'
    NOT = 7             # 'not'
    CMP = 8             # '<', '>', '==', '>=', '<=', '!=', 'in', 'not in', 'is', 'is not'
    EXPR = 9
    BOR = 9             # '|'
    BXOR = 10           # '^'
    BAND = 11           # '&'
    SHIFT = 12          # '<<', '>>'
    ARITH = 13          # '+', '-'
    TERM = 14           # '*', '@', '/', '%', '//'
    FACTOR = 15         # unary '+', '-', '~'
    POWER = 16          # '**'
    AWAIT = 17          # 'await'
    ATOM = 18

def _pnext(p):
    return p + 1 if p < 18 else p

_SINGLE_QUOTES = ("'", '"')
_MULTI_QUOTES = ('"""', "'''")
_ALL_QUOTES = ("'", '"', '"""', "'''")


class _Delimit:
    def __init__(self, u, start, end):
        self.u = u
        self.start = start
        self.end = end
    def __enter__(self):
        self.u.write(self.start)
        return self
    def __exit__(self, *exc):
        self.u.write(self.end)
        return False


class _NoDelimit:
    def __enter__(self):
        return self
    def __exit__(self, *exc):
        return False

_no_delimit = _NoDelimit()


class _Block:
    def __init__(self, u, extra):
        self.u = u
        self.extra = extra
    def __enter__(self):
        self.u.write(":")
        if self.extra:
            self.u.write(self.extra)
        self.u._indent += 1
        return self
    def __exit__(self, *exc):
        self.u._indent -= 1
        return False


class _Buffered:
    def __init__(self, u):
        self.u = u
        self.buffer = []
    def __enter__(self):
        self.saved = self.u._source
        self.u._source = self.buffer
        return self.buffer
    def __exit__(self, *exc):
        self.u._source = self.saved
        return False


class _Unparser(NodeVisitor):
    """Methods in this class recursively traverse an AST and
    output source code for the abstract syntax; original formatting
    is disregarded."""

    def __init__(self, *, _avoid_backslashes=False):
        self._source = []
        self._precedences = {}
        self._type_ignores = {}
        self._indent = 0
        self._avoid_backslashes = _avoid_backslashes
        self._in_try_star = False

    def interleave(self, inter, f, seq):
        """Call f on each item in seq, calling inter() in between."""
        first = True
        for x in seq:
            if first:
                first = False
            else:
                inter()
            f(x)

    def items_view(self, traverser, items):
        """Traverse and separate the given *items* with a comma and append it to
        the buffer. If *items* is a single item sequence, a trailing comma
        will be added."""
        if len(items) == 1:
            traverser(items[0])
            self.write(",")
        else:
            self.interleave(lambda: self.write(", "), traverser, items)

    def maybe_newline(self):
        """Adds a newline if it isn't the start of generated source"""
        if self._source:
            self.write("\n")

    def fill(self, text=""):
        """Indent a piece of text and append it, according to the current
        indentation level"""
        self.maybe_newline()
        self.write("    " * self._indent + text)

    def write(self, *text):
        """Add new source parts"""
        self._source.extend(text)

    def buffered(self, buffer=None):
        return _Buffered(self)

    def block(self, *, extra=None):
        """A context manager for preparing the source for blocks. It adds
        the character':', increases the indentation on enter and decreases
        the indentation on exit. If *extra* is given, it will be directly
        appended after the colon character.
        """
        return _Block(self, extra)

    def delimit(self, start, end):
        """A context manager for preparing the source for expressions. It adds
        *start* to the buffer and enters, after exit it adds *end*."""
        return _Delimit(self, start, end)

    def delimit_if(self, start, end, condition):
        if condition:
            return self.delimit(start, end)
        else:
            return _no_delimit

    def require_parens(self, precedence, node):
        """Shortcut to adding precedence related parens"""
        return self.delimit_if("(", ")", self.get_precedence(node) > precedence)

    def get_precedence(self, node):
        return self._precedences.get(id(node), _Precedence.TEST)

    def set_precedence(self, precedence, *nodes):
        for node in nodes:
            self._precedences[id(node)] = precedence

    def get_raw_docstring(self, node):
        """If a docstring node is found in the body of the *node* parameter,
        return that docstring node, None otherwise.

        Logic mirrored from ``_PyAST_GetDocString``."""
        if not isinstance(
            node, (AsyncFunctionDef, FunctionDef, ClassDef, Module)
        ) or len(node.body) < 1:
            return None
        node = node.body[0]
        if not isinstance(node, Expr):
            return None
        node = node.value
        if isinstance(node, Constant) and isinstance(node.value, str):
            return node

    def get_type_comment(self, node):
        comment = self._type_ignores.get(node.lineno) if hasattr(node, "lineno") else None
        if comment is None:
            comment = getattr(node, "type_comment", None)
        if comment is not None:
            return f" # type: {comment}"

    def traverse(self, node):
        if isinstance(node, list):
            for item in node:
                self.traverse(item)
        else:
            method = getattr(self, 'visit_' + node.__class__.__name__, None)
            if method is None:
                raise ValueError("cannot unparse a %s node" % node.__class__.__name__)
            method(node)

    # Note: as visit() resets the output text, do NOT rely on
    # NodeVisitor.generic_visit to handle any nodes (as it calls back in to
    # the subclass visit() method, which resets self._source to an empty list)
    def visit(self, node):
        """Outputs a source code string that, if converted back to an ast
        (using ast.parse) will generate an AST equivalent to *node*"""
        self._source = []
        self.traverse(node)
        return "".join(self._source)

    def _write_docstring_and_traverse_body(self, node):
        docstring = self.get_raw_docstring(node)
        if docstring:
            self._write_docstring(docstring)
            self.traverse(node.body[1:])
        else:
            self.traverse(node.body)

    def visit_Module(self, node):
        self._type_ignores = {}
        for ignore in node.type_ignores:
            self._type_ignores[ignore.lineno] = f"ignore{ignore.tag}"
        self._write_docstring_and_traverse_body(node)
        self._type_ignores.clear()

    def visit_Interactive(self, node):
        self.traverse(node.body)

    def visit_Expression(self, node):
        self.traverse(node.body)

    def visit_FunctionType(self, node):
        with self.delimit("(", ")"):
            self.interleave(
                lambda: self.write(", "), self.traverse, node.argtypes
            )

        self.write(" -> ")
        self.traverse(node.returns)

    def visit_Expr(self, node):
        self.fill()
        self.set_precedence(_Precedence.YIELD, node.value)
        self.traverse(node.value)

    def visit_NamedExpr(self, node):
        with self.require_parens(_Precedence.NAMED_EXPR, node):
            self.set_precedence(_Precedence.ATOM, node.target, node.value)
            self.traverse(node.target)
            self.write(" := ")
            self.traverse(node.value)

    def visit_Import(self, node):
        self.fill("import ")
        self.interleave(lambda: self.write(", "), self.traverse, node.names)

    def visit_ImportFrom(self, node):
        self.fill("from ")
        self.write("." * (node.level or 0))
        if node.module:
            self.write(node.module)
        self.write(" import ")
        self.interleave(lambda: self.write(", "), self.traverse, node.names)

    def visit_Assign(self, node):
        self.fill()
        for target in node.targets:
            self.set_precedence(_Precedence.TUPLE, target)
            self.traverse(target)
            self.write(" = ")
        self.traverse(node.value)
        type_comment = self.get_type_comment(node)
        if type_comment:
            self.write(type_comment)

    def visit_AugAssign(self, node):
        self.fill()
        self.traverse(node.target)
        self.write(" " + self.binop[node.op.__class__.__name__] + "= ")
        self.traverse(node.value)

    def visit_AnnAssign(self, node):
        self.fill()
        with self.delimit_if("(", ")", not node.simple and isinstance(node.target, Name)):
            self.traverse(node.target)
        self.write(": ")
        self.traverse(node.annotation)
        if node.value:
            self.write(" = ")
            self.traverse(node.value)

    def visit_Return(self, node):
        self.fill("return")
        if node.value:
            self.write(" ")
            self.traverse(node.value)

    def visit_Pass(self, node):
        self.fill("pass")

    def visit_Break(self, node):
        self.fill("break")

    def visit_Continue(self, node):
        self.fill("continue")

    def visit_Delete(self, node):
        self.fill("del ")
        self.interleave(lambda: self.write(", "), self.traverse, node.targets)

    def visit_Assert(self, node):
        self.fill("assert ")
        self.traverse(node.test)
        if node.msg:
            self.write(", ")
            self.traverse(node.msg)

    def visit_Global(self, node):
        self.fill("global ")
        self.interleave(lambda: self.write(", "), self.write, node.names)

    def visit_Nonlocal(self, node):
        self.fill("nonlocal ")
        self.interleave(lambda: self.write(", "), self.write, node.names)

    def visit_Await(self, node):
        with self.require_parens(_Precedence.AWAIT, node):
            self.write("await")
            if node.value:
                self.write(" ")
                self.set_precedence(_Precedence.ATOM, node.value)
                self.traverse(node.value)

    def visit_Yield(self, node):
        with self.require_parens(_Precedence.YIELD, node):
            self.write("yield")
            if node.value:
                self.write(" ")
                self.set_precedence(_Precedence.ATOM, node.value)
                self.traverse(node.value)

    def visit_YieldFrom(self, node):
        with self.require_parens(_Precedence.YIELD, node):
            self.write("yield from ")
            if not node.value:
                raise ValueError("Node can't be used without a value attribute.")
            self.set_precedence(_Precedence.ATOM, node.value)
            self.traverse(node.value)

    def visit_Raise(self, node):
        self.fill("raise")
        if not node.exc:
            if node.cause:
                raise ValueError(f"Node can't use cause without an exception.")
            return
        self.write(" ")
        self.traverse(node.exc)
        if node.cause:
            self.write(" from ")
            self.traverse(node.cause)

    def do_visit_try(self, node):
        self.fill("try")
        with self.block():
            self.traverse(node.body)
        for ex in node.handlers:
            self.traverse(ex)
        if node.orelse:
            self.fill("else")
            with self.block():
                self.traverse(node.orelse)
        if node.finalbody:
            self.fill("finally")
            with self.block():
                self.traverse(node.finalbody)

    def visit_Try(self, node):
        prev_in_try_star = self._in_try_star
        try:
            self._in_try_star = False
            self.do_visit_try(node)
        finally:
            self._in_try_star = prev_in_try_star

    def visit_TryStar(self, node):
        prev_in_try_star = self._in_try_star
        try:
            self._in_try_star = True
            self.do_visit_try(node)
        finally:
            self._in_try_star = prev_in_try_star

    def visit_ExceptHandler(self, node):
        self.fill("except*" if self._in_try_star else "except")
        if node.type:
            self.write(" ")
            self.traverse(node.type)
        if node.name:
            self.write(" as ")
            self.write(node.name)
        with self.block():
            self.traverse(node.body)

    def visit_ClassDef(self, node):
        self.maybe_newline()
        for deco in node.decorator_list:
            self.fill("@")
            self.traverse(deco)
        self.fill("class " + node.name)
        if hasattr(node, "type_params"):
            self._type_params_helper(node.type_params)
        with self.delimit_if("(", ")", node.bases or node.keywords):
            comma = False
            for e in node.bases:
                if comma:
                    self.write(", ")
                else:
                    comma = True
                self.traverse(e)
            for e in node.keywords:
                if comma:
                    self.write(", ")
                else:
                    comma = True
                self.traverse(e)

        with self.block():
            self._write_docstring_and_traverse_body(node)

    def visit_FunctionDef(self, node):
        self._function_helper(node, "def")

    def visit_AsyncFunctionDef(self, node):
        self._function_helper(node, "async def")

    def _function_helper(self, node, fill_suffix):
        self.maybe_newline()
        for deco in node.decorator_list:
            self.fill("@")
            self.traverse(deco)
        def_str = fill_suffix + " " + node.name
        self.fill(def_str)
        if hasattr(node, "type_params"):
            self._type_params_helper(node.type_params)
        with self.delimit("(", ")"):
            self.traverse(node.args)
        if node.returns:
            self.write(" -> ")
            self.traverse(node.returns)
        with self.block(extra=self.get_type_comment(node)):
            self._write_docstring_and_traverse_body(node)

    def _type_params_helper(self, type_params):
        if type_params is not None and len(type_params) > 0:
            with self.delimit("[", "]"):
                self.interleave(lambda: self.write(", "), self.traverse, type_params)

    def visit_TypeVar(self, node):
        self.write(node.name)
        if node.bound:
            self.write(": ")
            self.traverse(node.bound)

    def visit_TypeVarTuple(self, node):
        self.write("*" + node.name)

    def visit_ParamSpec(self, node):
        self.write("**" + node.name)

    def visit_TypeAlias(self, node):
        self.fill("type ")
        self.traverse(node.name)
        self._type_params_helper(node.type_params)
        self.write(" = ")
        self.traverse(node.value)

    def visit_For(self, node):
        self._for_helper("for ", node)

    def visit_AsyncFor(self, node):
        self._for_helper("async for ", node)

    def _for_helper(self, fill, node):
        self.fill(fill)
        self.set_precedence(_Precedence.TUPLE, node.target)
        self.traverse(node.target)
        self.write(" in ")
        self.traverse(node.iter)
        with self.block(extra=self.get_type_comment(node)):
            self.traverse(node.body)
        if node.orelse:
            self.fill("else")
            with self.block():
                self.traverse(node.orelse)

    def visit_If(self, node):
        self.fill("if ")
        self.traverse(node.test)
        with self.block():
            self.traverse(node.body)
        # collapse nested ifs into equivalent elifs.
        while node.orelse and len(node.orelse) == 1 and isinstance(node.orelse[0], If):
            node = node.orelse[0]
            self.fill("elif ")
            self.traverse(node.test)
            with self.block():
                self.traverse(node.body)
        # final else
        if node.orelse:
            self.fill("else")
            with self.block():
                self.traverse(node.orelse)

    def visit_While(self, node):
        self.fill("while ")
        self.traverse(node.test)
        with self.block():
            self.traverse(node.body)
        if node.orelse:
            self.fill("else")
            with self.block():
                self.traverse(node.orelse)

    def visit_With(self, node):
        self.fill("with ")
        self.interleave(lambda: self.write(", "), self.traverse, node.items)
        with self.block(extra=self.get_type_comment(node)):
            self.traverse(node.body)

    def visit_AsyncWith(self, node):
        self.fill("async with ")
        self.interleave(lambda: self.write(", "), self.traverse, node.items)
        with self.block(extra=self.get_type_comment(node)):
            self.traverse(node.body)

    def _str_literal_helper(
        self, string, *, quote_types=_ALL_QUOTES, escape_special_whitespace=False
    ):
        """Helper for writing string literals, minimizing escapes.
        Returns the tuple (string literal to write, possible quote types).
        """
        def escape_char(c):
            # \n and \t are non-printable, but we only escape them if
            # escape_special_whitespace is True
            if not escape_special_whitespace and c in "\n\t":
                return c
            # Always escape backslashes and other non-printable characters
            if c == "\\" or not c.isprintable():
                return c.encode("unicode_escape").decode("ascii")
            return c

        escaped_string = "".join(map(escape_char, string))
        possible_quotes = quote_types
        if "\n" in escaped_string:
            possible_quotes = [q for q in possible_quotes if q in _MULTI_QUOTES]
        possible_quotes = [q for q in possible_quotes if q not in escaped_string]
        if not possible_quotes:
            # If there aren't any possible_quotes, fallback to using repr
            # on the original string. Try to use a quote from quote_types,
            # e.g., so that we use triple quotes for docstrings.
            string = repr(string)
            quote = string[0]
            for q in quote_types:
                if string[0] in q:
                    quote = q
                    break
            return string[1:-1], [quote]
        if escaped_string:
            # Sort so that we prefer '''"''' over """\""""
            possible_quotes.sort(key=lambda q: q[0] == escaped_string[-1])
            # If we're using triple quotes and we'd need to escape a final
            # quote, escape it
            if possible_quotes[0][0] == escaped_string[-1]:
                escaped_string = escaped_string[:-1] + "\\" + escaped_string[-1]
        return escaped_string, possible_quotes

    def _write_str_avoiding_backslashes(self, string, *, quote_types=_ALL_QUOTES):
        """Write string literal value with a best effort attempt to avoid backslashes."""
        string, quote_types = self._str_literal_helper(string, quote_types=quote_types)
        quote_type = quote_types[0]
        self.write(f"{quote_type}{string}{quote_type}")

    def visit_JoinedStr(self, node):
        self.write("f")

        fstring_parts = []
        for value in node.values:
            with self.buffered() as buffer:
                self._write_fstring_inner(value)
            fstring_parts.append(
                ("".join(buffer), isinstance(value, Constant))
            )

        new_fstring_parts = []
        quote_types = list(_ALL_QUOTES)
        fallback_to_repr = False
        for value, is_constant in fstring_parts:
            if is_constant:
                value, new_quote_types = self._str_literal_helper(
                    value,
                    quote_types=quote_types,
                    escape_special_whitespace=True,
                )
                if set(new_quote_types).isdisjoint(quote_types):
                    fallback_to_repr = True
                    break
                quote_types = new_quote_types
            elif "\n" in value:
                quote_types = [q for q in quote_types if q in _MULTI_QUOTES]
            new_fstring_parts.append(value)

        if fallback_to_repr:
            # If we weren't able to find a quote type that works for all parts
            # of the JoinedStr, fallback to using repr and triple single quotes.
            quote_types = ["'''"]
            new_fstring_parts.clear()
            for value, is_constant in fstring_parts:
                if is_constant:
                    value = repr('"' + value)  # force repr to use single quotes
                    expected_prefix = "'\""
                    value = value[len(expected_prefix):-1]
                new_fstring_parts.append(value)

        value = "".join(new_fstring_parts)
        quote_type = quote_types[0]
        self.write(f"{quote_type}{value}{quote_type}")

    def _write_fstring_inner(self, node, is_format_spec=False):
        if isinstance(node, JoinedStr):
            # for both the f-string itself, and format_spec
            for value in node.values:
                self._write_fstring_inner(value, is_format_spec=is_format_spec)
        elif isinstance(node, Constant) and isinstance(node.value, str):
            value = node.value.replace("{", "{{").replace("}", "}}")

            if is_format_spec:
                value = value.replace("\\", "\\\\")
                value = value.replace("'", "\\'")
                value = value.replace('"', '\\"')
                value = value.replace("\n", "\\n")
            self.write(value)
        elif isinstance(node, FormattedValue):
            self.visit_FormattedValue(node)
        else:
            raise ValueError(f"Unexpected node inside JoinedStr, {node!r}")

    def visit_FormattedValue(self, node):
        def unparse_inner(inner):
            unparser = type(self)()
            unparser.set_precedence(_pnext(_Precedence.TEST), inner)
            return unparser.visit(inner)

        with self.delimit("{", "}"):
            inner_src = unparse_inner(node.value)
            if inner_src.startswith("{"):
                # Separate pair of opening brackets as "{ {"
                self.write(" ")
            self.write(inner_src)
            if node.conversion != -1:
                self.write(f"!{chr(node.conversion)}")
            if node.format_spec:
                self.write(":")
                self._write_fstring_inner(node.format_spec, is_format_spec=True)

    def visit_Name(self, node):
        self.write(node.id)

    def _write_docstring(self, node):
        self.fill()
        if node.kind == "u":
            self.write("u")
        self._write_str_avoiding_backslashes(node.value, quote_types=_MULTI_QUOTES)

    def _write_constant(self, value):
        if isinstance(value, (float, complex)):
            # Substitute overflowing decimal literal for AST infinities,
            # and inf - inf for NaNs.
            self.write(
                repr(value)
                .replace("inf", _INFSTR)
                .replace("nan", f"({_INFSTR}-{_INFSTR})")
            )
        elif self._avoid_backslashes and isinstance(value, str):
            self._write_str_avoiding_backslashes(value)
        else:
            self.write(_pyrepr(value))

    def visit_Constant(self, node):
        value = node.value
        if isinstance(value, tuple):
            with self.delimit("(", ")"):
                self.items_view(self._write_constant, value)
        elif value is ...:
            self.write("...")
        else:
            if node.kind == "u":
                self.write("u")
            self._write_constant(node.value)

    def visit_List(self, node):
        with self.delimit("[", "]"):
            self.interleave(lambda: self.write(", "), self.traverse, node.elts)

    def visit_ListComp(self, node):
        with self.delimit("[", "]"):
            self.traverse(node.elt)
            for gen in node.generators:
                self.traverse(gen)

    def visit_GeneratorExp(self, node):
        with self.delimit("(", ")"):
            self.traverse(node.elt)
            for gen in node.generators:
                self.traverse(gen)

    def visit_SetComp(self, node):
        with self.delimit("{", "}"):
            self.traverse(node.elt)
            for gen in node.generators:
                self.traverse(gen)

    def visit_DictComp(self, node):
        with self.delimit("{", "}"):
            self.traverse(node.key)
            self.write(": ")
            self.traverse(node.value)
            for gen in node.generators:
                self.traverse(gen)

    def visit_comprehension(self, node):
        if node.is_async:
            self.write(" async for ")
        else:
            self.write(" for ")
        self.set_precedence(_Precedence.TUPLE, node.target)
        self.traverse(node.target)
        self.write(" in ")
        self.set_precedence(_pnext(_Precedence.TEST), node.iter, *node.ifs)
        self.traverse(node.iter)
        for if_clause in node.ifs:
            self.write(" if ")
            self.traverse(if_clause)

    def visit_IfExp(self, node):
        with self.require_parens(_Precedence.TEST, node):
            self.set_precedence(_pnext(_Precedence.TEST), node.body, node.test)
            self.traverse(node.body)
            self.write(" if ")
            self.traverse(node.test)
            self.write(" else ")
            self.set_precedence(_Precedence.TEST, node.orelse)
            self.traverse(node.orelse)

    def visit_Set(self, node):
        if node.elts:
            with self.delimit("{", "}"):
                self.interleave(lambda: self.write(", "), self.traverse, node.elts)
        else:
            # `{}` would be interpreted as a dictionary literal, and
            # `set` might be shadowed. Thus:
            self.write('{*()}')

    def visit_Dict(self, node):
        def write_key_value_pair(k, v):
            self.traverse(k)
            self.write(": ")
            self.traverse(v)

        def write_item(item):
            k, v = item
            if k is None:
                # for dictionary unpacking operator in dicts {**{'y': 2}}
                # see PEP 448 for details
                self.write("**")
                self.set_precedence(_Precedence.EXPR, v)
                self.traverse(v)
            else:
                write_key_value_pair(k, v)

        with self.delimit("{", "}"):
            self.interleave(
                lambda: self.write(", "), write_item, list(zip(node.keys, node.values))
            )

    def visit_Tuple(self, node):
        with self.delimit_if(
            "(",
            ")",
            len(node.elts) == 0 or self.get_precedence(node) > _Precedence.TUPLE
        ):
            self.items_view(self.traverse, node.elts)

    unop = {"Invert": "~", "Not": "not", "UAdd": "+", "USub": "-"}
    unop_precedence = {
        "not": _Precedence.NOT,
        "~": _Precedence.FACTOR,
        "+": _Precedence.FACTOR,
        "-": _Precedence.FACTOR,
    }

    def visit_UnaryOp(self, node):
        op_text = self.unop[node.op.__class__.__name__]
        operator_precedence = self.unop_precedence[op_text]
        with self.require_parens(operator_precedence, node):
            self.write(op_text)
            # factor prefixes (+, -, ~) shouldn't be separated
            # from the value they belong, (e.g: +1 instead of + 1)
            if operator_precedence != _Precedence.FACTOR:
                self.write(" ")
            self.set_precedence(operator_precedence, node.operand)
            self.traverse(node.operand)

    def visit_NyUnaryOp(self, node):
        self.set_precedence(_Precedence.ATOM, node.operand)
        self.traverse(node.operand)
        self.write(node.op)

    binop = {
        "Add": "+",
        "Sub": "-",
        "Mult": "*",
        "MatMult": "@",
        "Div": "/",
        "Mod": "%",
        "LShift": "<<",
        "RShift": ">>",
        "BitOr": "|",
        "BitXor": "^",
        "BitAnd": "&",
        "FloorDiv": "//",
        "Pow": "**",
        "NyCoalesce": "??",
        "NyXor": "xor",
    }

    binop_precedence = {
        "+": _Precedence.ARITH,
        "-": _Precedence.ARITH,
        "*": _Precedence.TERM,
        "@": _Precedence.TERM,
        "/": _Precedence.TERM,
        "%": _Precedence.TERM,
        "<<": _Precedence.SHIFT,
        ">>": _Precedence.SHIFT,
        "|": _Precedence.BOR,
        "^": _Precedence.BXOR,
        "&": _Precedence.BAND,
        "//": _Precedence.TERM,
        "**": _Precedence.POWER,
        "??": _Precedence.TEST,
        "xor": _Precedence.OR,
    }

    binop_rassoc = frozenset(("**", "??"))
    def visit_BinOp(self, node):
        op_text = self.binop[node.op.__class__.__name__]
        operator_precedence = self.binop_precedence[op_text]
        with self.require_parens(operator_precedence, node):
            if op_text in self.binop_rassoc:
                left_precedence = _pnext(operator_precedence)
                right_precedence = operator_precedence
            else:
                left_precedence = operator_precedence
                right_precedence = _pnext(operator_precedence)

            self.set_precedence(left_precedence, node.left)
            self.traverse(node.left)
            self.write(f" {op_text} ")
            self.set_precedence(right_precedence, node.right)
            self.traverse(node.right)

    cmpops = {
        "Eq": "==",
        "NotEq": "!=",
        "Lt": "<",
        "LtE": "<=",
        "Gt": ">",
        "GtE": ">=",
        "Is": "is",
        "IsNot": "is not",
        "In": "in",
        "NotIn": "not in",
        "NyStrictEq": "===",
        "NyStrictNotEq": "!==",
        "NyInstanceOf": "instanceof",
    }

    def visit_Compare(self, node):
        with self.require_parens(_Precedence.CMP, node):
            self.set_precedence(_pnext(_Precedence.CMP), node.left, *node.comparators)
            self.traverse(node.left)
            for o, e in zip(node.ops, node.comparators):
                self.write(" " + self.cmpops[o.__class__.__name__] + " ")
                self.traverse(e)

    boolops = {"And": "and", "Or": "or"}
    boolop_precedence = {"and": _Precedence.AND, "or": _Precedence.OR}

    def visit_BoolOp(self, node):
        op_text = self.boolops[node.op.__class__.__name__]
        level = [self.boolop_precedence[op_text]]

        def increasing_level_traverse(node):
            level[0] = _pnext(level[0])
            self.set_precedence(level[0], node)
            self.traverse(node)

        with self.require_parens(level[0], node):
            s = f" {op_text} "
            self.interleave(lambda: self.write(s), increasing_level_traverse, node.values)

    def visit_Attribute(self, node):
        self.set_precedence(_Precedence.ATOM, node.value)
        self.traverse(node.value)
        # Special case: 3.__abs__() is a syntax error, so if node.value
        # is an integer literal then we need to either parenthesize
        # it or add an extra space to get 3 .__abs__().
        if isinstance(node.value, Constant) and isinstance(node.value.value, int) and not isinstance(node.value.value, bool):
            self.write(" ")
        self.write(".")
        self.write(node.attr)

    def visit_Call(self, node):
        self.set_precedence(_Precedence.ATOM, node.func)
        self.traverse(node.func)
        with self.delimit("(", ")"):
            comma = False
            for e in node.args:
                if comma:
                    self.write(", ")
                else:
                    comma = True
                self.traverse(e)
            for e in node.keywords:
                if comma:
                    self.write(", ")
                else:
                    comma = True
                self.traverse(e)

    def visit_Subscript(self, node):
        def is_non_empty_tuple(slice_value):
            return (
                isinstance(slice_value, Tuple)
                and slice_value.elts
            )

        self.set_precedence(_Precedence.ATOM, node.value)
        self.traverse(node.value)
        with self.delimit("[", "]"):
            if is_non_empty_tuple(node.slice):
                # parentheses can be omitted if the tuple isn't empty
                self.items_view(self.traverse, node.slice.elts)
            else:
                self.traverse(node.slice)

    def visit_Starred(self, node):
        self.write("*")
        self.set_precedence(_Precedence.EXPR, node.value)
        self.traverse(node.value)

    def visit_Ellipsis(self, node):
        self.write("...")

    def visit_Slice(self, node):
        if node.lower:
            self.traverse(node.lower)
        self.write(":")
        if node.upper:
            self.traverse(node.upper)
        if node.step:
            self.write(":")
            self.traverse(node.step)

    def visit_NyRange(self, node):
        self.set_precedence(_Precedence.EXPR, node.lower, node.upper)
        self.traverse(node.lower)
        self.write("..." if node.inclusive else "..")
        self.traverse(node.upper)
        if node.step:
            self.write("..")
            self.traverse(node.step)

    def visit_NyNode(self, node):
        raise ValueError("cannot unparse Nython's %s construct" % node.kind)

    def visit_Match(self, node):
        self.fill("match ")
        self.traverse(node.subject)
        with self.block():
            for case in node.cases:
                self.traverse(case)

    def visit_arg(self, node):
        self.write(node.arg)
        if node.annotation:
            self.write(": ")
            self.traverse(node.annotation)

    def visit_arguments(self, node):
        first = True
        # normal arguments
        all_args = node.posonlyargs + node.args
        defaults = [None] * (len(all_args) - len(node.defaults)) + node.defaults
        index = 0
        for a, d in zip(all_args, defaults):
            index += 1
            if first:
                first = False
            else:
                self.write(", ")
            self.traverse(a)
            if d:
                self.write("=")
                self.traverse(d)
            if index == len(node.posonlyargs):
                self.write(", /")

        # varargs, or bare '*' if no varargs but keyword-only arguments present
        if node.vararg or node.kwonlyargs:
            if first:
                first = False
            else:
                self.write(", ")
            self.write("*")
            if node.vararg:
                self.write(node.vararg.arg)
                if node.vararg.annotation:
                    self.write(": ")
                    self.traverse(node.vararg.annotation)

        # keyword-only arguments
        if node.kwonlyargs:
            for a, d in zip(node.kwonlyargs, node.kw_defaults):
                self.write(", ")
                self.traverse(a)
                if d:
                    self.write("=")
                    self.traverse(d)

        # kwargs
        if node.kwarg:
            if first:
                first = False
            else:
                self.write(", ")
            self.write("**" + node.kwarg.arg)
            if node.kwarg.annotation:
                self.write(": ")
                self.traverse(node.kwarg.annotation)

    def visit_keyword(self, node):
        if node.arg is None:
            self.write("**")
        else:
            self.write(node.arg)
            self.write("=")
        self.traverse(node.value)

    def visit_Lambda(self, node):
        with self.require_parens(_Precedence.TEST, node):
            self.write("lambda")
            with self.buffered() as buffer:
                self.traverse(node.args)
            if buffer:
                self.write(" ", *buffer)
            self.write(": ")
            self.set_precedence(_Precedence.TEST, node.body)
            self.traverse(node.body)

    def visit_alias(self, node):
        self.write(node.name)
        if node.asname:
            self.write(" as " + node.asname)

    def visit_withitem(self, node):
        self.traverse(node.context_expr)
        if node.optional_vars:
            self.write(" as ")
            self.traverse(node.optional_vars)

    def visit_match_case(self, node):
        self.fill("case ")
        self.traverse(node.pattern)
        if node.guard:
            self.write(" if ")
            self.traverse(node.guard)
        with self.block():
            self.traverse(node.body)

    def visit_MatchValue(self, node):
        self.traverse(node.value)

    def visit_MatchSingleton(self, node):
        self._write_constant(node.value)

    def visit_MatchSequence(self, node):
        with self.delimit("[", "]"):
            self.interleave(
                lambda: self.write(", "), self.traverse, node.patterns
            )

    def visit_MatchStar(self, node):
        name = node.name
        if name is None:
            name = "_"
        self.write(f"*{name}")

    def visit_MatchMapping(self, node):
        def write_key_pattern_pair(pair):
            k, p = pair
            self.traverse(k)
            self.write(": ")
            self.traverse(p)

        with self.delimit("{", "}"):
            keys = node.keys
            self.interleave(
                lambda: self.write(", "),
                write_key_pattern_pair,
                list(zip(keys, node.patterns)),
            )
            rest = node.rest
            if rest is not None:
                if keys:
                    self.write(", ")
                self.write(f"**{rest}")

    def visit_MatchClass(self, node):
        self.set_precedence(_Precedence.ATOM, node.cls)
        self.traverse(node.cls)
        with self.delimit("(", ")"):
            patterns = node.patterns
            self.interleave(
                lambda: self.write(", "), self.traverse, patterns
            )
            attrs = node.kwd_attrs
            if attrs:
                def write_attr_pattern(pair):
                    attr, pat = pair
                    self.write(f"{attr}=")
                    self.traverse(pat)

                if patterns:
                    self.write(", ")
                self.interleave(
                    lambda: self.write(", "),
                    write_attr_pattern,
                    list(zip(attrs, node.kwd_patterns)),
                )

    def visit_MatchAs(self, node):
        name = node.name
        pat = node.pattern
        if name is None:
            self.write("_")
        elif pat is None:
            self.write(node.name)
        else:
            with self.require_parens(_Precedence.TEST, node):
                self.set_precedence(_Precedence.BOR, node.pattern)
                self.traverse(node.pattern)
                self.write(f" as {node.name}")

    def visit_MatchOr(self, node):
        with self.require_parens(_Precedence.BOR, node):
            self.set_precedence(_pnext(_Precedence.BOR), *node.patterns)
            self.interleave(lambda: self.write(" | "), self.traverse, node.patterns)


def unparse(ast_obj):
    unparser = _Unparser()
    return unparser.visit(ast_obj)


# ── compile(tree, ...) (round 83: both engines' compile() calls _ny_compile) ─

class _LineUnparser(_Unparser):
    # Nython's addition: unparse with each statement on its tree's line -
    # blank lines are written before a statement whose lineno is further
    # down than the line the output has reached - so the code compile()
    # makes from a tree reports the tree's lines.
    def __init__(self):
        _Unparser.__init__(self)
        self._line = 1
        self._want = 0
        self._main = None

    def visit(self, node):
        self._source = []
        self._main = self._source
        self._line = 1
        self.traverse(node)
        return "".join(self._source)

    def write(self, *text):
        if self._source is self._main:
            for t in text:
                self._line += t.count("\n")
        self._source.extend(text)

    def maybe_newline(self):
        if self._want:
            return            # fill() puts the statement on its line
        if self._source:
            self.write("\n")

    def traverse(self, node):
        if isinstance(node, (stmt, ExceptHandler)) and self._source is self._main:
            ln = getattr(node, "lineno", None)
            if isinstance(node, (FunctionDef, AsyncFunctionDef, ClassDef)):
                for d in node.decorator_list:
                    dl = getattr(d, "lineno", None)
                    if dl is not None and (ln is None or dl < ln):
                        ln = dl
            if ln is not None and ln > self._line:
                self._want = ln
        _Unparser.traverse(self, node)

    def fill(self, text=""):
        want = self._want
        self._want = 0
        if self._source:
            self.write("\n")
        while want and self._line < want:
            self.write("\n")
        self.write("    " * self._indent + text)


def _check_positions(tree):
    for node in walk(tree):
        if isinstance(node, (stmt, expr, excepthandler, pattern, arg, keyword, alias)):
            for a in ("lineno", "col_offset"):
                if not hasattr(node, a):
                    base = "stmt" if isinstance(node, stmt) else "expr" if isinstance(node, expr) \
                        else type(node).__mro__[1].__name__ if isinstance(node, (excepthandler, pattern)) \
                        else type(node).__name__
                    raise TypeError('required field "%s" missing from %s' % (a, base))


def _ny_compile(source, filename, mode, flags=0):
    if isinstance(source, AST):
        if flags & PyCF_ONLY_AST:
            return source
        want = {"exec": Module, "eval": Expression, "single": Interactive, "func_type": FunctionType}.get(mode)
        if want is None:
            raise ValueError("compile() mode must be 'exec', 'eval' or 'single'")
        if not isinstance(source, want):
            raise TypeError("expected %s node, got %s" % (want.__name__, type(source).__name__))
        if mode == "func_type":
            raise ValueError("compile() of a FunctionType is not supported here")
        _check_positions(source)
        if mode == "eval":
            text = unparse(source.body)
        else:
            text = _LineUnparser().visit(source)
        return compile(text, filename, "exec" if mode == "single" else mode)
    if not isinstance(source, (str, bytes, bytearray)):
        raise TypeError("compile() arg 1 must be a string, bytes or AST object")
    return parse(source, filename, mode, type_comments=bool(flags & PyCF_TYPE_COMMENTS))


def main():
    import argparse

    parser = argparse.ArgumentParser(prog='python -m ast')
    parser.add_argument('infile', nargs='?', default='-',
                        help='the file to parse; defaults to stdin')
    parser.add_argument('-m', '--mode', default='exec',
                        choices=('exec', 'single', 'eval', 'func_type'),
                        help='specify what kind of code must be parsed')
    parser.add_argument('--no-type-comments', default=True, action='store_false',
                        help="don't add information about type comments")
    parser.add_argument('-a', '--include-attributes', action='store_true',
                        help='include attributes such as line numbers and '
                             'column offsets')
    parser.add_argument('-i', '--indent', type=int, default=3,
                        help='indentation of nodes (number of spaces)')
    args = parser.parse_args()

    if args.infile == '-':
        name = '<stdin>'
        source = sys.stdin.read()
    else:
        name = args.infile
        with open(args.infile, 'rb') as infile:
            source = infile.read()
    tree = parse(source, name, args.mode, type_comments=args.no_type_comments)
    print(dump(tree, include_attributes=args.include_attributes, indent=args.indent))

if __name__ == '__main__':
    main()
