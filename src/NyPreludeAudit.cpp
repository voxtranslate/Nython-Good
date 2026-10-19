// NyPreludeAudit.cpp - the audit events' part of the prelude (round 86).
//
// What only a program with an audit hook (PEP 578: sys.addaudithook) needs:
// the arguments CPython's events carry where Nython's values differ from
// them (compile's source as bytes, exec's code object, open's flags, an os
// function's dir_fd and uid_t ids, POSIX's encoded environment and
// commands), the excepthook/unraisablehook events with CPython's handling
// of a hook that raises, and code.replace / types.FunctionType(code, ...),
// which raise code.__new__ / function.__new__.
//
// Loaded as the mirror chunk "audit" (builtin_mirror_chunk) by the first
// sys.addaudithook - before the hook is in the list, so every caller that
// tests `_ny_audit_hooks` (or nyrt::audit_on() in the engines) finds these
// defined - and by the stubs in the startup prelude (code.replace,
// _ny_function_new). Parsing them at every start cost 3.75% of `-c pass`.
// It is a unit of its own so that editing it rebuilds one file, not every
// file that includes NyPrelude.hpp. Prelude rule: locals are declared with
// var.
#include <string>

namespace nyrt {

const char* prelude_audit_source() {
    return R"NYAUDITPRELUDE(
# compile() and exec()/eval() of a source give the source as bytes (CPython
# 3.11+ audits the encoded text) and its file name - an ast tree with None -,
# then exec gets the code object run (a source is compiled to one first, as
# CPython does); called by the engines (auditHelper / audit_helper)
def _ny_audit_compile(source, filename):
    if isinstance(source, str):
        source = source.encode("utf-8", "surrogatepass")
    elif isinstance(source, bytearray) or isinstance(source, memoryview):
        source = bytes(source)
    elif not isinstance(source, bytes):
        filename = None
    _ny_audit_fire("compile", (source, filename))

def _ny_audit_exec(code, mode):
    if isinstance(code, str) or isinstance(code, bytes) or isinstance(code, bytearray):
        _ny_audit_compile(code, "<string>")
        var src = code if isinstance(code, str) else bytes(code).decode("utf-8", "replace")
        code = _NyCode(src, "<string>", mode)
    _ny_audit_fire("exec", (code,))

# the "open" event of open() (the prelude's, and the VM's native one): the
# mode without b/t, the flags CPython computes
def _ny_audit_open(path, mode):
    _ny_audit_fire("open", (path, mode.replace("b", "").replace("t", ""), _ny_open_flags(mode)))

# an os function's dir_fd as its event gives it: -1 for none (CPython's
# DEFAULT_DIR_FD)
def _ny_audit_dirfd(fd):
    return -1 if fd is None else fd

# a uid/gid as os.chown's event gives it: CPython's uid_t, so -1
# (unchanged) is 4294967295
def _ny_audit_id(v):
    return v & 4294967295 if isinstance(v, int) and v < 0 else v

# an environment key/value or a command as CPython's POSIX events give
# them: encoded (os.fsencode)
def _ny_audit_fsenc(s):
    if os_name != "nt" and isinstance(s, str):
        return s.encode("utf-8", "surrogateescape")
    return s

# sys.excepthook's event before an uncaught exception is reported, as
# CPython's _PyErr_Display: True when a hook's RuntimeError suppresses the
# report; another error is reported and the excepthook still runs
def _ny_audit_excepthook(hook, e):
    try:
        _ny_audit_fire("sys.excepthook", (hook, type(e), e, getattr(e, "__traceback__", None)))
    except RuntimeError:
        return True
    except BaseException as ae:
        _ny_stderr.write("Exception ignored in audit hook:\n" + _ny_format_exc(ae, True, [], {}))
    return False

# sys.unraisablehook's event (the hook and its argument), as CPython's
# _PyErr_WriteUnraisableMsg: True when a hook raised - that is reported
# instead, and the unraisable hook is not called
def _ny_audit_unraisable(h, exc, err_msg, obj):
    try:
        _ny_audit_fire("sys.unraisablehook", (h, _NyUnraisableHookArgs((type(exc), exc, getattr(exc, "__traceback__", None), err_msg, obj))))
    except BaseException as ae:
        _ny_unraisablehook(_NyUnraisableHookArgs((type(ae), ae, getattr(ae, "__traceback__", None),
                                                  "Exception ignored in audit hook", None)))
        return True
    return False

# code.replace(**changes) on either kind of code object: a copy with those
# attributes changed, audited as CPython's (code.__new__ with the new code's
# co_code, file, name, argument counts, nlocals, stacksize and flags).
# Nython's code objects describe the code; a replaced one runs as the
# original (a compile() result keeps its source).
_ny_code_fields = ("co_argcount", "co_posonlyargcount", "co_kwonlyargcount", "co_nlocals", "co_stacksize",
                   "co_flags", "co_firstlineno", "co_code", "co_consts", "co_names", "co_varnames",
                   "co_freevars", "co_cellvars", "co_filename", "co_name", "co_qualname", "co_linetable",
                   "co_exceptiontable")
def _ny_code_replace(self, **changes):
    for k in changes:
        if k not in _ny_code_fields:
            raise TypeError("replace() got an unexpected keyword argument '" + k + "'")
    def now(k, d):
        return changes[k] if k in changes else getattr(self, k, d)
    _ny_sys_audit("code.__new__", now("co_code", b""), now("co_filename", "<unknown>"), now("co_name", "<module>"),
                  now("co_argcount", 0), now("co_posonlyargcount", 0), now("co_kwonlyargcount", 0),
                  now("co_nlocals", 0), now("co_stacksize", 0), now("co_flags", 0))
    var c = object.__new__(type(self))
    var d = vars(self)
    for k in list(d.keys()):
        setattr(c, k, d[k])
    for k in changes:
        setattr(c, k, changes[k])
    return c

# types.FunctionType(code, globals, name=None, argdefs=None, closure=None):
# CPython 3.12's func_new - its argument clinic's checks and messages, in
# their order (the count, the required ones, then keywords left over), the
# converters', func_new_impl's -, audited (function.__new__) once they pass.
# Nython makes one from a code object compile() gave: calling it runs the
# code in globals (an "eval" code returns its value); a function's own
# __code__ cannot make another function here.
_ny_fn_params = ("code", "globals", "name", "argdefs", "closure")
def _ny_function_new(*args, **kw):
    var n = len(args) + len(kw)
    if n > 5:
        raise TypeError("function() takes at most 5 " + ("" if args else "keyword ") + "arguments (" + str(n) + " given)")
    var v = list(args) + [None] * (5 - len(args))
    var left = len(kw)
    for i in range(len(args), 5):
        var p = _ny_fn_params[i]
        if p in kw:
            v[i] = kw[p]
            left -= 1
        elif i < 2:
            raise TypeError("function() missing required argument '" + p + "' (pos " + str(i + 1) + ")")
    if left:
        for k in kw:
            if k in _ny_fn_params[:len(args)]:
                raise TypeError("argument for function() given by name ('" + k + "') and position ("
                                + str(_ny_fn_params.index(k) + 1) + ")")
            if k not in _ny_fn_params:
                raise TypeError("'" + k + "' is an invalid keyword argument for function()")
    var code = v[0]
    var name = v[2]
    if type(code) is not _NyCode and type(code) is not _NyFuncCode:
        raise TypeError("function() argument 'code' must be code, not " + type(code).__name__)
    if not isinstance(v[1], dict):
        raise TypeError("function() argument 'globals' must be dict, not " + type(v[1]).__name__)
    if name is not None and not isinstance(name, str):
        raise TypeError("arg 3 (name) must be None or string")
    if v[3] is not None and not isinstance(v[3], tuple):
        raise TypeError("arg 4 (defaults) must be None or tuple")
    if v[4] is not None and not isinstance(v[4], tuple):
        raise TypeError("arg 5 (closure) must be None or tuple")
    _ny_sys_audit("function.__new__", code)
    if type(code) is not _NyCode:
        raise TypeError("Nython cannot make a function from another function's code object (only from compile()'s)")
    var c = code
    var g = v[1]
    def _ny_made():
        if c.mode == "eval":
            return eval(c, g)
        exec(c, g)
    _ny_made.__name__ = name if name is not None else c.co_name
    _ny_made.__qualname__ = _ny_made.__name__
    return _ny_made
)NYAUDITPRELUDE";
}

} // namespace nyrt
