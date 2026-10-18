# nython: module    (import it by name: it runs in a module scope of its own)
# lib/dis.ny - Python's dis module (round 83) over NYTHON'S VM: the
# instructions include/VirtualMachine.hpp's compiler makes for a function, a
# class or source text, shown in CPython 3.12's layout.
#
#     import dis
#     dis.dis(f)                       dis.dis("x = a + 1")
#     for ins in dis.get_instructions(f): ins.opname, ins.argval, ...
#     dis.Bytecode(f).dis()            dis.code_info(f)    dis.show_code(f)
#     dis.findlinestarts(code)         dis.findlabels(code)
#     dis.dis(f, adaptive=True)        (on the VM: the specialized forms)
#
# Provided: dis (functions, methods, lambdas, classmethod/staticmethod
# objects, classes and modules - every function in them -, generators and
# coroutines, source strings, compile() results, code objects, raw co_code
# bytes, depth=), disassemble/disco, distb, get_instructions, Instruction
# (opname, opcode, arg, argval, argrepr, offset, starts_line,
# is_jump_target, positions, and _disassemble), Positions, Bytecode
# (codeobj, first_line, current_offset, info(), dis(), from_traceback),
# code_info, show_code, pretty_flags, COMPILER_FLAG_NAMES, findlinestarts,
# findlabels, stack_effect and the names of lib/opcode.ny (opname, opmap,
# hasconst, hasname, hasjabs, ...), `python -m dis [file]`.
#
# What the instructions are: Nython's own bytecode, not CPython's
# (LOAD_NAME / CALL_METHOD / FOR_ITER ... with Nython's numbers - see
# lib/opcode.ny). An instruction's offset is its index in the code (CPython
# counts bytes, two per instruction): jump arguments are such indices and
# are shown "to N". Each instruction knows its line, not its columns
# (positions has lineno/end_lineno, col_offset/end_col_offset are None).
# On the interpreter a function's code is compiled for the purpose with the
# VM's compiler (it is what `nython --vm` runs); adaptive=True then shows
# that compiled form, as nothing has run it. On the VM it is the function's
# own running code, so adaptive=True shows the specialized instructions hot
# ones have rewritten themselves into (round 80's quickening: LOAD_NAME_FAST,
# BINARY_ADD_NUM, CALL_METHOD_PY, ...), as CPython 3.12's adaptive view.
#
# Code objects: what this module disassembles is a code object of its own
# (co_name, co_qualname, co_filename, co_firstlineno, co_argcount,
# co_posonlyargcount, co_kwonlyargcount, co_nlocals, co_varnames (the
# parameters, then the other names a function binds), co_names, co_consts
# (the constants, then the nested code objects), co_flags, co_stacksize (an
# estimate from the stack effects),
# co_lines(), co_positions(), co_code). co_code is bytes, two per
# instruction - the generic opcode and the low byte of its argument - so
# dis(co.co_code) shows the opcodes (an argument above 255 is cut there; the
# Instruction objects carry the full ones). f.__code__ (the prelude's
# summary of a function) and a frame's f_code are disassembled by compiling
# their file again and finding the function by name and first line; a code
# object that names no readable file raises TypeError. Not here: the
# exception table as bytes (co_exceptiontable is b''; disassemble() prints
# Nython's own table: each try statement's except clauses, else and
# finally), cache entries (show_caches has nothing to show), free and cell
# variables (Nython's closures capture environments, not cells).

import sys
import io
import collections
import types
import json as _json
import opcode as _opcode

__all__ = ["code_info", "dis", "disassemble", "distb", "disco",
           "findlinestarts", "findlabels", "show_code",
           "get_instructions", "Instruction", "Bytecode"] + list(_opcode.__all__)

cmp_op = _opcode.cmp_op
hasarg = _opcode.hasarg
hasconst = _opcode.hasconst
hasname = _opcode.hasname
hasjrel = _opcode.hasjrel
hasjabs = _opcode.hasjabs
haslocal = _opcode.haslocal
hascompare = _opcode.hascompare
hasfree = _opcode.hasfree
opname = _opcode.opname
opmap = _opcode.opmap
HAVE_ARGUMENT = _opcode.HAVE_ARGUMENT
EXTENDED_ARG = _opcode.EXTENDED_ARG
stack_effect = _opcode.stack_effect
_specializations = _opcode._specializations
_specialized_instructions = _opcode._specialized_instructions

_all_opname = list(opname)
_all_opmap = dict(opmap)
deoptmap = dict(_opcode._generic_of)

_have_code = (types.MethodType, types.FunctionType, classmethod, staticmethod, type)

# the generic instructions whose argument means something (shown even when 0)
_ARG_OPS = set(["LOAD_CONST", "LOAD_NAME", "STORE_NAME", "DEFINE_NAME", "DELETE_NAME",
                "LOAD_GLOBAL_NAME", "STORE_GLOBAL_NAME", "LOAD_ATTR", "STORE_ATTR", "DELETE_ATTR",
                "LOAD_ATTR_OPT", "CHECK_MEMBER", "IMPORT_NAME", "STORE_EXCEPT_AS",
                "LOAD_SELF_ATTR", "STORE_SELF_ATTR", "DEFINE_OUTER", "INPLACE_TRY",
                "BUILD_LIST", "BUILD_TUPLE", "BUILD_MAP", "CALL_FUNCTION", "CALL_METHOD",
                "CALL_KW", "CALL_EX", "UNPACK_SEQ", "MAKE_FUNCTION", "MAKE_CLASS",
                "FOR_ITER", "FOR_PREP", "FIN_JUMP", "RAISE_ERROR", "PRINT"])
_CONST_OPS = set(["LOAD_CONST", "LOAD_METHNAME"])
_NAME_OPS = set(["LOAD_NAME", "STORE_NAME", "DEFINE_NAME", "DELETE_NAME",
                 "LOAD_GLOBAL_NAME", "STORE_GLOBAL_NAME", "LOAD_ATTR", "STORE_ATTR",
                 "DELETE_ATTR", "LOAD_ATTR_OPT", "CHECK_MEMBER", "IMPORT_NAME",
                 "STORE_EXCEPT_AS", "LOAD_SELF_ATTR", "STORE_SELF_ATTR", "DEFINE_OUTER",
                 "INPLACE_TRY"])
_JUMP_OPS = set(["JUMP_FORWARD", "JUMP_ABSOLUTE", "JUMP_IF_TRUE", "JUMP_IF_FALSE",
                 "JUMP_IF_TRUE_OR_POP", "JUMP_IF_FALSE_OR_POP", "JUMP_IF_NONE_KEEP",
                 "JUMP_IF_MISSING_KEEP", "JUMP_IF_NOT_NONE_OR_POP", "FOR_ITER", "FIN_JUMP"])
_RAISE_KINDS = {0: "", 1: "reraise", 2: "from cause", 3: "reraise handled"}
_FOR_PREP_KINDS = {1: "range, 1 argument", 2: "range, 2 arguments", 3: "range, 3 arguments",
                   10: "keys", 11: "values", 12: "items"}

COMPILER_FLAG_NAMES = {
     1: "OPTIMIZED",
     2: "NEWLOCALS",
     4: "VARARGS",
     8: "VARKEYWORDS",
    16: "NESTED",
    32: "GENERATOR",
    64: "NOFREE",
   128: "COROUTINE",
   256: "ITERABLE_COROUTINE",
   512: "ASYNC_GENERATOR",
}


def pretty_flags(flags):
    """Return pretty representation of code flags."""
    out = []
    for i in range(32):
        flag = 1 << i
        if flags & flag:
            out.append(COMPILER_FLAG_NAMES.get(flag, hex(flag)))
            flags ^= flag
            if not flags:
                break
    else:
        out.append(hex(flags))
    return ", ".join(out)


class _Unknown:
    def __repr__(self):
        return "<unknown>"

# Sentinel to represent values that cannot be calculated
UNKNOWN = _Unknown()


def _pyrepr(v):
    # repr as CPython spells it (Nython's repr shows none, true, false)
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
    return repr(v)


class _DisConst:
    # a constant of the code with no Python value here (as the VM shows it)
    def __init__(self, text):
        self._text = text

    def __repr__(self):
        return self._text


def _const_value(c):
    t = c["type"]
    if t == "NoneType":
        return None
    if t == "bool":
        return c["value"]
    if t == "int":
        return int(c["int"])
    if t == "float":
        try:
            return float(c["float"])
        except ValueError:
            return _DisConst(c["repr"])
    if t == "str":
        return c["value"]
    return _DisConst(c["repr"])


def _internal_name(nm):
    # a name the VM's compiler makes for itself: a comprehension's result
    # and loop variables (__comp0__, __c0_i), an except clause's hidden name
    if nm.startswith(".") or nm.startswith("__comp") or nm.startswith("__exc"):
        return True
    return nm.startswith("__c") and len(nm) > 3 and nm[3].isdigit()


def _split_params(params, selfname):
    # Nython's parameter list -> CPython's (positional, keyword-only,
    # *args/**kwargs names, flags)
    pos = []
    kwonly = []
    star = []
    fl = 0
    after_star = False
    for p in params:
        if p.startswith("**"):
            star.append(p[2:])
            fl |= 8
        elif p.startswith("*"):
            after_star = True
            if p != "*":
                star.insert(0, p[1:])
                fl |= 4
        elif after_star:
            kwonly.append(p)
        else:
            pos.append(p)
    if selfname:
        pos.insert(0, selfname)
    return pos, kwonly, star, fl


class _NyVMCode:
    """A code object of Nython's VM (see the top of lib/dis.ny)."""

    def __init__(self, info):
        self._ny_info = info
        self._ny_code = info["code"]
        self._ny_exc = info["exc_table"]
        self.co_name = info["name"]
        self.co_qualname = info["qualname"]
        self.co_filename = info["filename"]
        self.co_firstlineno = info["firstlineno"]
        var fl = info["flags"]
        var selfname = info.get("self")
        pos, kwonly, star, pflags = _split_params(info["params"], selfname)
        var posonly = info["posonly"]
        if posonly and selfname:
            posonly = posonly + 1
        self.co_argcount = len(pos)
        self.co_posonlyargcount = posonly
        self.co_kwonlyargcount = len(kwonly)
        self.co_varnames = tuple(pos + kwonly + star)
        self.co_nlocals = len(self.co_varnames)
        self.co_names = tuple(info["names"])
        var subs = [_NyVMCode(s) for s in info["subs"] if s is not None]
        self._ny_subs = subs
        self.co_consts = tuple([_const_value(c) for c in info["consts"]] + subs)
        var cf = 0
        if not fl["module"] and not fl["class"] and self.co_name != "<module>":
            cf = 3 | pflags
            if "<locals>" in self.co_qualname:
                cf |= 16
            if fl["generator"]:
                cf |= 32
            if fl["async"]:
                cf |= 128
            if fl["async_gen"]:
                cf |= 512
        self.co_flags = cf
        if cf:
            # a function's locals: its parameters, then the names its code
            # binds (CPython's co_varnames), not the compiler's own temporaries
            var seen = set(self.co_varnames)
            var extra = []
            for ins in self._ny_code:
                if ins[5] in ("STORE_NAME", "DEFINE_NAME") and 0 <= ins[2] < len(self.co_names):
                    var nm = self.co_names[ins[2]]
                    if nm not in seen and not _internal_name(nm):
                        seen.add(nm)
                        extra.append(nm)
            self.co_varnames = self.co_varnames + tuple(extra)
            self.co_nlocals = len(self.co_varnames)
        self.co_freevars = ()
        self.co_cellvars = ()
        self.co_exceptiontable = b""
        self.co_stacksize = _estimate_stacksize(self._ny_code)
        if info.get("doc") is not None:
            self._ny_doc = info["doc"]
        else:
            self._ny_doc = None

    @property
    def co_code(self):
        return _code_bytes(self._ny_code, False)

    @property
    def _co_code_adaptive(self):
        return _code_bytes(self._ny_code, True)

    def co_lines(self):
        # (start, end, line) for each run of instructions on one line
        var out = []
        var start = 0
        var cur = None
        var i = 0
        for ins in self._ny_code:
            ln = ins[3] if ins[3] > 0 else None
            if i == 0:
                cur = ln
            elif ln != cur:
                out.append((start, i, cur))
                start = i
                cur = ln
            i += 1
        if i > 0:
            out.append((start, i, cur))
        return iter(out)

    def co_positions(self):
        return iter([(ins[3] or None, ins[3] or None, None, None) for ins in self._ny_code])

    def replace(self, **changes):
        c = _NyVMCode(self._ny_info)
        for k, v in changes.items():
            if not hasattr(c, k) or not k.startswith("co_"):
                raise TypeError("replace() got an unexpected keyword argument '%s'" % k)
            setattr(c, k, v)
        return c

    def __repr__(self):
        return '<code object %s at 0x%x, file "%s", line %d>' % (
            self.co_name, id(self), self.co_filename, self.co_firstlineno)


def _code_bytes(code, adaptive):
    out = bytearray()
    for ins in code:
        op = ins[1] if adaptive else _all_opmap.get(ins[5], ins[1])
        out.append(op & 255)
        out.append(ins[2] & 255)
    return bytes(out)


def _effect_of(g, arg):
    if g == "CALL_METHOD":
        return -(arg + 1)
    if g == "CALL_KW":
        return arg + 1 if arg < 0 else -arg
    if g in ("JUMP_IF_TRUE", "JUMP_IF_FALSE"):
        return -1
    if g == "MAKE_FUNCTION":
        return 1 - ((arg >> 16) & 255)
    try:
        return stack_effect(_all_opmap[g], arg)
    except (ValueError, KeyError):
        return 0


def _estimate_stacksize(code):
    depth = 0
    top = 0
    for ins in code:
        depth = depth + _effect_of(ins[5], ins[2])
        if depth < 0:
            depth = 0
        if depth > top:
            top = depth
    return top


def _load_json(text):
    if text is None:
        return None
    return _json.loads(text)


def _code_of_function(f):
    info = _load_json(_ny_vm_code(f, True))
    if info is None:
        raise TypeError("don't know how to disassemble %s objects" % type(f).__name__)
    return _NyVMCode(info)


def _compile_source(source, name):
    # CPython's _try_compile: as an expression, else as statements
    try:
        c = compile(source, name, "eval")
    except SyntaxError:
        c = compile(source, name, "exec")
    info = _load_json(_ny_vm_code(c))
    if info is None:
        raise TypeError("don't know how to disassemble str objects")
    co = _NyVMCode(info)
    co.co_filename = name
    return co


def _find_code(co, name, line):
    for sub in co._ny_subs:
        if sub.co_name == name and sub.co_firstlineno == line:
            return sub
        r = _find_code(sub, name, line)
        if r is not None:
            return r
    return None


def _code_of_summary(x):
    # f.__code__ / a frame's f_code / compile()'s result: compiled again from
    # its source (its file, found by name and first line)
    if hasattr(x, "source") and hasattr(x, "mode"):
        info = _load_json(_ny_vm_code(x))
        if info is not None:
            co = _NyVMCode(info)
            co.co_filename = x.co_filename
            return co
    fname = getattr(x, "co_filename", None)
    name = getattr(x, "co_name", None)
    if not fname or name is None:
        return None
    try:
        import linecache
        src = "".join(linecache.getlines(fname))
    except Exception:
        src = ""
    if not src:
        return None
    info = _load_json(_ny_vm_code(compile(src, fname, "exec")))
    if info is None:
        return None
    top_code = _NyVMCode(info)
    top_code.co_filename = fname
    if name == "<module>":
        return top_code
    return _find_code(top_code, name, getattr(x, "co_firstlineno", 0))


def _get_code_object(x):
    """Helper to handle methods, compiled or raw code objects, and strings."""
    if isinstance(x, _NyVMCode):
        return x
    if hasattr(x, "__func__"):
        x = x.__func__
    if isinstance(x, types.FunctionType):
        return _code_of_function(x)
    if isinstance(x, str):
        return _compile_source(x, "<disassembly>")
    for a in ("gi_code", "ag_code", "cr_code"):
        if not isinstance(x, type) and hasattr(x, a):
            x = getattr(x, a)
            break
    if isinstance(x, _NyVMCode):
        return x
    if hasattr(x, "co_name") and not isinstance(x, type):
        co = _code_of_summary(x)
        if co is not None:
            return co
    raise TypeError("don't know how to disassemble %s objects" % type(x).__name__)


def _deoptop(op):
    oname = _all_opname[op]
    return _all_opmap[deoptmap[oname]] if oname in deoptmap else op


def code_info(x):
    """Formatted details of methods, functions, or code."""
    return _format_code_info(_get_code_object(x))


def _format_code_info(co):
    out = []
    out.append("Name:              %s" % co.co_name)
    out.append("Filename:          %s" % co.co_filename)
    out.append("Argument count:    %s" % co.co_argcount)
    out.append("Positional-only arguments: %s" % co.co_posonlyargcount)
    out.append("Kw-only arguments: %s" % co.co_kwonlyargcount)
    out.append("Number of locals:  %s" % co.co_nlocals)
    out.append("Stack size:        %s" % co.co_stacksize)
    out.append("Flags:             %s" % pretty_flags(co.co_flags))
    if co.co_consts:
        out.append("Constants:")
        for i, c in enumerate(co.co_consts):
            out.append("%4d: %s" % (i, _pyrepr(c)))
    if co.co_names:
        out.append("Names:")
        for i, n in enumerate(co.co_names):
            out.append("%4d: %s" % (i, n))
    if co.co_varnames:
        out.append("Variable names:")
        for i, n in enumerate(co.co_varnames):
            out.append("%4d: %s" % (i, n))
    if co.co_freevars:
        out.append("Free variables:")
        for i, n in enumerate(co.co_freevars):
            out.append("%4d: %s" % (i, n))
    if co.co_cellvars:
        out.append("Cell variables:")
        for i, n in enumerate(co.co_cellvars):
            out.append("%4d: %s" % (i, n))
    return "\n".join(out)


def show_code(co, *, file=None):
    """Print details of methods, functions, or code to *file*.

    If *file* is not provided, the output is printed on stdout.
    """
    print(code_info(co), file=file)


Positions = collections.namedtuple(
    'Positions',
    [
        'lineno',
        'end_lineno',
        'col_offset',
        'end_col_offset',
    ],
    defaults=[None] * 4
)

_Instruction = collections.namedtuple(
    "_Instruction",
    [
        'opname',
        'opcode',
        'arg',
        'argval',
        'argrepr',
        'offset',
        'starts_line',
        'is_jump_target',
        'positions'
    ],
    defaults=[None]
)

_ExceptionTableEntry = collections.namedtuple("_ExceptionTableEntry",
    "start end target depth lasti")

_OPNAME_WIDTH = 20
_OPARG_WIDTH = 5


class Instruction(_Instruction):
    """Details for a bytecode operation

       Defined fields:
         opname - human readable name for operation
         opcode - numeric code for operation
         arg - numeric argument to operation (if any), otherwise None
         argval - resolved arg value (if known), otherwise same as arg
         argrepr - human readable description of operation argument
         offset - start index of operation within bytecode sequence
         starts_line - line started by this opcode (if any), otherwise None
         is_jump_target - True if other code jumps to here, otherwise False
         positions - Optional dis.Positions object holding the span of source code
                     covered by this instruction
    """

    def _disassemble(self, lineno_width=3, mark_as_current=False, offset_width=4):
        """Format instruction details for inclusion in disassembly output"""
        fields = []
        if lineno_width:
            if self.starts_line is not None:
                fields.append(("%" + str(lineno_width) + "d") % self.starts_line)
            else:
                fields.append(' ' * lineno_width)
        if mark_as_current:
            fields.append('-->')
        else:
            fields.append('   ')
        if self.is_jump_target:
            fields.append('>>')
        else:
            fields.append('  ')
        fields.append(repr(self.offset).rjust(offset_width))
        fields.append(self.opname.ljust(_OPNAME_WIDTH))
        if self.arg is not None:
            fields.append(repr(self.arg).rjust(_OPARG_WIDTH))
            if self.argrepr:
                fields.append('(' + self.argrepr + ')')
        return ' '.join(fields).rstrip()


def _labels(co):
    out = []
    for ins in co._ny_code:
        if ins[5] in _JUMP_OPS and ins[2] not in out:
            out.append(ins[2])
    return out


def _handler_targets(co):
    out = []
    for e in co._ny_exc:
        for h in e["handlers"]:
            out.append(h["target"])
        if e["else"] >= 0:
            out.append(e["else"])
        if e["finally"] >= 0:
            out.append(e["finally"])
    return out


def _arg_info(co, g, arg, offset):
    # (argval, argrepr) of an instruction's argument
    if g in _CONST_OPS:
        if 0 <= arg < len(co.co_consts):
            v = co.co_consts[arg]
            return v, _pyrepr(v)
        return UNKNOWN, ""
    if g in _NAME_OPS:
        if 0 <= arg < len(co.co_names):
            return co.co_names[arg], co.co_names[arg]
        return UNKNOWN, ""
    if g in _JUMP_OPS:
        return arg, "to " + repr(arg)
    if g == "MAKE_FUNCTION":
        idx = arg & 0xFFFF
        nd = (arg >> 16) & 0xFF
        if idx < len(co._ny_subs):
            sub = co._ny_subs[idx]
            text = "code object " + sub.co_name
            if nd:
                text += ", %d default%s" % (nd, "" if nd == 1 else "s")
            return sub, text
        return arg, ""
    if g == "MAKE_CLASS":
        idx = arg & 0xFFFFFF
        if idx < len(co._ny_subs):
            sub = co._ny_subs[idx]
            text = "class " + sub.co_name
            if (arg >> 24) & 1:
                text += ", bases and keywords"
            return sub, text
        return arg, ""
    if g in ("CALL_KW", "CALL_EX"):
        if arg < 0:
            return arg, "method call"
        return arg, ""
    if g == "UNPACK_SEQ":
        n = arg & 0xFFFF
        if arg & (1 << 16):
            return arg, "%d, strict" % n
        return arg, ""
    if g == "RAISE_ERROR":
        return arg, _RAISE_KINDS.get(arg, "")
    if g == "FOR_PREP":
        return arg, _FOR_PREP_KINDS.get(arg, "")
    if g == "PRINT":
        if arg & (1 << 20):
            n = arg & 0xFFFF
            text = "%d value%s" % (n, "" if n == 1 else "s")
            pf = (arg >> 16) & 3
            if pf & 1:
                text += ", sep"
            if pf & 2:
                text += ", end"
            return arg, text
        return arg, ""
    return arg, ""


def _get_instructions_code(co, adaptive=False, line_offset=0):
    """The Instruction objects of a code object (a list)."""
    labels = set(_labels(co))
    for t in _handler_targets(co):
        labels.add(t)
    out = []
    lastline = None
    var offset = 0
    for ins in co._ny_code:
        g = ins[5]
        if adaptive:
            oname = ins[0]
            op = ins[1]
        else:
            oname = g
            op = _all_opmap.get(g, ins[1])
        ln = ins[3]
        starts_line = None
        if ln > 0 and ln != lastline:
            lastline = ln
            starts_line = ln + line_offset
        raw = ins[2]
        if g in _ARG_OPS or raw != 0:
            arg = raw
            argval, argrepr = _arg_info(co, g, raw, offset)
        else:
            arg = None
            argval = None
            argrepr = ""
        positions = Positions(ln or None, ln or None, None, None)
        out.append(Instruction(oname, op, arg, argval, argrepr, offset, starts_line,
                               offset in labels, positions))
        offset += 1
    return out


def get_instructions(x, *, first_line=None, show_caches=False, adaptive=False):
    """Iterator for the opcodes in methods, functions or code

    Generates a series of Instruction named tuples giving the details of
    each operations in the supplied code.

    If *first_line* is not None, it indicates the line number that should
    be reported for the first source line in the disassembled code.
    Otherwise, the source line information (if any) is taken directly from
    the disassembled code object.
    """
    co = _get_code_object(x)
    if first_line is not None:
        line_offset = first_line - co.co_firstlineno
    else:
        line_offset = 0
    return iter(_get_instructions_code(co, adaptive, line_offset))


def _get_instructions_bytes(code, varname_from_oparg=None, names=None, co_consts=None,
                            linestarts=None, line_offset=0, exception_entries=(),
                            co_positions=None, show_caches=False):
    # raw co_code bytes: two per instruction (opcode, argument's low byte)
    out = []
    for i in range(0, len(code) - 1, 2):
        op = code[i]
        a = code[i + 1]
        oname = _all_opname[op] if op < len(_all_opname) else "<%d>" % op
        g = deoptmap.get(oname, oname)
        starts_line = None
        if linestarts is not None:
            starts_line = linestarts.get(i // 2)
            if starts_line is not None:
                starts_line += line_offset
        if g in _ARG_OPS or a != 0:
            argval = a
            argrepr = ""
            if g in _CONST_OPS and co_consts is not None and a < len(co_consts):
                argval = co_consts[a]
                argrepr = _pyrepr(argval)
            elif g in _NAME_OPS and names is not None and a < len(names):
                argval = names[a]
                argrepr = argval
            elif g in _JUMP_OPS:
                argrepr = "to " + repr(a)
            out.append(Instruction(oname, op, a, argval, argrepr, i // 2, starts_line, False,
                                   Positions()))
        else:
            out.append(Instruction(oname, op, None, None, "", i // 2, starts_line, False,
                                   Positions()))
    return out


def findlabels(code):
    """Detect all offsets in a code object which are jump targets.

    Return the list of offsets.
    """
    if isinstance(code, (bytes, bytearray)):
        out = []
        for i in range(0, len(code) - 1, 2):
            oname = _all_opname[code[i]]
            if deoptmap.get(oname, oname) in _JUMP_OPS and code[i + 1] not in out:
                out.append(code[i + 1])
        return out
    return _labels(_get_code_object(code))


def findlinestarts(code):
    """Find the offsets in the code which are start of lines in the source.

    Generate pairs (offset, lineno)
    """
    co = _get_code_object(code)
    lastline = None
    for start, end, line in co.co_lines():
        if line is not None and line != lastline:
            lastline = line
            yield start, line
    return


def _print_exception_table(co, file):
    if not co._ny_exc:
        return
    print("ExceptionTable:", file=file)
    for e in co._ny_exc:
        span = "  %d to %d" % (e["start"], e["end"] - 1)
        for h in e["handlers"]:
            what = "except " + ", ".join(h["types"]) if h["types"] else "except"
            if h["name"]:
                what += " as " + h["name"]
            print("%s -> %d [%s]" % (span, h["target"], what), file=file)
        if e["else"] >= 0:
            print("%s -> %d [else]" % (span, e["else"]), file=file)
        if e["finally"] >= 0:
            print("%s -> %d [finally]" % (span, e["finally"]), file=file)


def _print_instructions(instrs, lasti, file, exc_co=None):
    show_lineno = False
    maxlineno = 0
    for ins in instrs:
        if ins.starts_line is not None:
            show_lineno = True
            if ins.starts_line > maxlineno:
                maxlineno = ins.starts_line
    if show_lineno:
        lineno_width = len(str(maxlineno)) if maxlineno >= 1000 else 3
    else:
        lineno_width = 0
    maxoffset = len(instrs) - 1
    offset_width = len(str(maxoffset)) if maxoffset >= 10000 else 4
    for ins in instrs:
        if show_lineno and ins.starts_line is not None and ins.offset > 0:
            print(file=file)
        print(ins._disassemble(lineno_width, ins.offset == lasti, offset_width), file=file)
    if exc_co is not None:
        _print_exception_table(exc_co, file)


def disassemble(co, lasti=-1, *, file=None, show_caches=False, adaptive=False):
    """Disassemble a code object."""
    co = _get_code_object(co)
    _print_instructions(_get_instructions_code(co, adaptive), lasti, file, co)


disco = disassemble                     # XXX For backwards compatibility


def _disassemble_recursive(co, *, file=None, depth=None, show_caches=False, adaptive=False):
    disassemble(co, file=file, show_caches=show_caches, adaptive=adaptive)
    if depth is None or depth > 0:
        if depth is not None:
            depth = depth - 1
        for x in co.co_consts:
            if isinstance(x, _NyVMCode):
                print(file=file)
                print("Disassembly of %r:" % (x,), file=file)
                _disassemble_recursive(x, file=file, depth=depth, show_caches=show_caches,
                                       adaptive=adaptive)


def _disassemble_bytes(code, lasti=-1, varname_from_oparg=None, names=None, co_consts=None,
                       linestarts=None, *, file=None, line_offset=0, exception_entries=(),
                       co_positions=None, show_caches=False):
    instrs = _get_instructions_bytes(code, varname_from_oparg, names, co_consts, linestarts,
                                     line_offset)
    labels = set(findlabels(code))
    marked = []
    for ins in instrs:
        marked.append(ins._replace(is_jump_target=ins.offset in labels))
    _print_instructions(marked, lasti, file)


def _disassemble_str(source, **kwargs):
    """Compile the source string, then disassemble the code object."""
    _disassemble_recursive(_compile_source(source, '<dis>'), **kwargs)


def _is_class_or_module(x):
    return isinstance(x, type) or isinstance(x, types.ModuleType)


def dis(x=None, *, file=None, depth=None, show_caches=False, adaptive=False):
    """Disassemble classes, methods, functions, and other compiled objects.

    With no argument, disassemble the last traceback.

    Compiled objects currently include generator objects, async generator
    objects, and coroutine objects, all of which store their code object
    in a special attribute.
    """
    if x is None:
        distb(file=file, show_caches=show_caches, adaptive=adaptive)
        return
    if hasattr(x, '__func__'):
        x = x.__func__
    if isinstance(x, (bytes, bytearray)):
        _disassemble_bytes(x, file=file, show_caches=show_caches)
        return
    if isinstance(x, str):
        _disassemble_str(x, file=file, depth=depth, show_caches=show_caches, adaptive=adaptive)
        return
    if _is_class_or_module(x):
        items = sorted(vars(x).items())
        for name, x1 in items:
            if isinstance(x1, _have_code):
                print("Disassembly of %s:" % name, file=file)
                try:
                    dis(x1, file=file, depth=depth, show_caches=show_caches, adaptive=adaptive)
                except TypeError as msg:
                    print("Sorry:", msg, file=file)
                print(file=file)
        return
    _disassemble_recursive(_get_code_object(x), file=file, depth=depth,
                           show_caches=show_caches, adaptive=adaptive)


def _last_traceback():
    tb = None
    if hasattr(sys, 'last_exc'):
        tb = sys.last_exc.__traceback__
    elif hasattr(sys, 'last_traceback'):
        tb = sys.last_traceback
    if tb is None:
        raise RuntimeError("no last traceback to disassemble")
    while tb.tb_next:
        tb = tb.tb_next
    return tb


def distb(tb=None, *, file=None, show_caches=False, adaptive=False):
    """Disassemble a traceback (default: last traceback)."""
    if tb is None:
        tb = _last_traceback()
    else:
        while tb.tb_next:
            tb = tb.tb_next
    disassemble(tb.tb_frame.f_code, tb.tb_lasti, file=file, show_caches=show_caches,
                adaptive=adaptive)


def _find_imports(co):
    """Find import statements in the code

    Generate pairs (name, None, None): Nython's IMPORT_NAME carries the
    module's name only.
    """
    co = _get_code_object(co)
    for ins in co._ny_code:
        if ins[5] == "IMPORT_NAME":
            yield (co.co_names[ins[2]], None, None)


def _find_store_names(co):
    """Find names of variables which are written in the code

    Generate sequence of strings
    """
    co = _get_code_object(co)
    for ins in co._ny_code:
        if ins[5] in ("STORE_NAME", "DEFINE_NAME", "STORE_GLOBAL_NAME"):
            yield co.co_names[ins[2]]


class Bytecode:
    """The bytecode operations of a piece of code

    Instantiate this with a function, method, other compiled object, string of
    code, or a code object (as returned by compile()).

    Iterating over this yields the bytecode operations as Instruction instances.
    """
    def __init__(self, x, *, first_line=None, current_offset=None, show_caches=False, adaptive=False):
        self.codeobj = co = _get_code_object(x)
        if first_line is None:
            self.first_line = co.co_firstlineno
            self._line_offset = 0
        else:
            self.first_line = first_line
            self._line_offset = first_line - co.co_firstlineno
        self._linestarts = dict(findlinestarts(co))
        self._original_object = x
        self.current_offset = current_offset
        self.exception_entries = []
        self.show_caches = show_caches
        self.adaptive = adaptive

    def __iter__(self):
        return iter(_get_instructions_code(self.codeobj, self.adaptive, self._line_offset))

    def __repr__(self):
        return "{}({!r})".format(self.__class__.__name__, self._original_object)

    @classmethod
    def from_traceback(cls, tb, *, show_caches=False, adaptive=False):
        """ Construct a Bytecode from the given traceback """
        while tb.tb_next:
            tb = tb.tb_next
        return cls(tb.tb_frame.f_code, current_offset=tb.tb_lasti, show_caches=show_caches,
                   adaptive=adaptive)

    def info(self):
        """Return formatted information about the code object."""
        return _format_code_info(self.codeobj)

    def dis(self):
        """Return a formatted view of the bytecode operations."""
        offset = self.current_offset if self.current_offset is not None else -1
        output = io.StringIO()
        _print_instructions(_get_instructions_code(self.codeobj, self.adaptive, self._line_offset),
                            offset, output, self.codeobj)
        return output.getvalue()


def main():
    args = sys.argv[1:]
    path = args[0] if args else "-"
    if path == "-":
        source = sys.stdin.read()
        name = "<stdin>"
    else:
        with open(path, "rb") as infile:
            source = infile.read()
        name = path
    if isinstance(source, bytes):
        source = source.decode("utf-8")
    code = compile(source, name, "exec")
    dis(code)

if __name__ == "__main__":
    main()
