# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/opcode.ny - Python's opcode module (round 83) for NYTHON'S VM: the
# names and numbers of the instructions of Nython's bytecode virtual
# machine (include/VirtualMachine.hpp's Op), not CPython's.
#
#     import opcode
#     opcode.opname[opcode.opmap["LOAD_CONST"]] == "LOAD_CONST"
#
# opname (number -> name, every instruction including the specialized
# forms the VM rewrites hot ones into - round 80's quickening), opmap
# (name -> number), cmp_op, hasconst, hasname, hasjrel (empty: Nython's
# jumps are absolute), hasjabs, haslocal, hasfree, hascompare, hasarg,
# HAVE_ARGUMENT (0: any instruction may carry an argument), EXTENDED_ARG
# (none: an instruction's argument is a full int), _specializations
# (generic name -> its specialized forms), _specialized_instructions,
# stack_effect(opcode, oparg=None, *, jump=None).
#
# The numbers come from the running VM (_ny_vm_code(None)), so they are
# always the binary's own. A program written for CPython's opcode numbers
# does not run against these (CPython 3.12's LOAD_CONST is 100; Nython's is
# 0): use the names. stack_effect knows the generic instructions' effects
# (ValueError for the specialized forms and for those that depend on what
# runs, as CPython's for an unknown opcode).

import json as _json

__all__ = ["cmp_op", "hasarg", "hasconst", "hasname", "hasjrel", "hasjabs",
           "haslocal", "hascompare", "hasfree", "opname", "opmap",
           "HAVE_ARGUMENT", "EXTENDED_ARG", "stack_effect"]

_set = _json.loads(_ny_vm_code(None))
opname = list(_set["opname"])           # 256 entries, '<n>' for unused numbers
opmap = {}
for _i, _n in enumerate(opname):
    if not _n.startswith("<"):
        opmap[_n] = _i

cmp_op = ('<', '<=', '==', '!=', '>', '>=')

HAVE_ARGUMENT = 0
EXTENDED_ARG = None

# the specialized forms and the generic instruction each stands for, from
# the VM itself (base_op)
_specializations = {}
_generic_of = {}
for _i, _g in enumerate(_set["generic"]):
    if _g != opname[_i]:
        _generic_of[opname[_i]] = _g
        _specializations.setdefault(_g, []).append(opname[_i])
_specialized_instructions = [s for s in _generic_of]
del _set


def _generic(name):
    return _generic_of.get(name, name)


def _ops(names):
    return sorted(opmap[n] for n in names if n in opmap)


hasconst = _ops(["LOAD_CONST", "LOAD_METHNAME"])
hasname = _ops([n for n in opname
                if ("NAME" in _generic(n) and _generic(n) != "LOAD_METHNAME")
                or "ATTR" in _generic(n) or _generic(n) in ("CHECK_MEMBER", "DEFINE_OUTER",
                                                            "STORE_EXCEPT_AS", "INPLACE_TRY")])
hasjrel = []
hasjabs = _ops([n for n in opname if _generic(n).startswith("JUMP_")] +
               ["FOR_ITER", "FOR_ITER_RANGE", "FOR_ITER_LIST", "FOR_ITER_GEN", "FIN_JUMP"])
haslocal = _ops(["LOAD_LOCAL", "DELETE_LOCAL"])   # round 85: Python's rule (CPython's LOAD_FAST / DELETE_FAST)
hasfree = []
hascompare = _ops([n for n in opname if _generic(n).startswith("COMPARE_")])
_counted = ["BUILD_LIST", "BUILD_TUPLE", "BUILD_MAP", "CALL_FUNCTION", "CALL_METHOD", "CALL_KW",
            "CALL_EX", "UNPACK_SEQ", "MAKE_FUNCTION", "MAKE_CLASS", "PRINT", "FOR_PREP", "RAISE",
            "RAISE_ERROR", "LOAD_SUPER", "SETUP_EXCEPT"]
hasarg = sorted(set(hasconst + hasname + hasjabs +
                    _ops([n for n in opname if _generic(n) in _counted])))

# stack effects of the generic instructions (CPython's stack_effect):
# a number, or a function of the argument
def _effect_table():
    t = {
        "LOAD_CONST": 1, "LOAD_NAME": 1, "STORE_NAME": -1, "DEFINE_NAME": -1, "DELETE_NAME": 0,
        "LOAD_LOCAL": 1, "DELETE_LOCAL": 0,
        "LOAD_GLOBAL_NAME": 1, "STORE_GLOBAL_NAME": -1, "LOAD_ATTR": 0, "STORE_ATTR": -2,
        "DELETE_ATTR": -1, "LOAD_SUBSCR": -1, "STORE_SUBSCR": -3, "DELETE_SUBSCR": -2,
        "DUP_TOP": 1, "DUP_TOP_TWO": 2, "POP_TOP": -1, "ROT_TWO": 0, "ROT_THREE": 0,
        "UNARY_NEG": 0, "UNARY_NOT": 0, "UNARY_BITNOT": 0, "UNARY_POS": 0,
        "RETURN_VALUE": -1, "GET_ITER": 0, "NOP": 0, "LOAD_SELF": 1, "STORE_SELF": -1,
        "LOAD_ATTR_OPT": 0, "LOAD_SUBSCR_OPT": -1, "CHECK_MEMBER": 0, "IMPORT_NAME": 0,
        "YIELD_VALUE": 0, "LOAD_SELF_ATTR": 1, "STORE_SELF_ATTR": -1,
        "BUILD_LIST": lambda a: 1 - a, "BUILD_TUPLE": lambda a: 1 - a,
        "BUILD_MAP": lambda a: 1 - 2 * a, "CALL_FUNCTION": lambda a: -a,
        "UNPACK_SEQ": lambda a: (a & 0xFFFF) - 1,
    }
    for n in opname:
        g = _generic(n)
        if (g.startswith("BINARY_") or (g.startswith("COMPARE_") and g not in ("COMPARE_IS_TYPE", "COMPARE_IS_NOT_TYPE"))
                or g in ("IADD", "ISUB", "IMUL", "IDIV", "IMOD", "LOGICAL_XOR")):
            t[g] = -1
    return t

_effects = _effect_table()


def stack_effect(opcode, oparg=None, *, jump=None):
    """Compute the stack effect of the opcode (Nython's VM instruction)."""
    if not isinstance(opcode, int) or opcode < 0 or opcode >= len(opname):
        raise ValueError("invalid opcode or oparg")
    name = opname[opcode]
    e = _effects.get(name)
    if e is None or name in _generic_of:
        raise ValueError("invalid opcode or oparg")
    if callable(e):
        if oparg is None:
            raise ValueError("stack_effect: opcode requires oparg but oparg was not specified")
        return e(oparg)
    return e
