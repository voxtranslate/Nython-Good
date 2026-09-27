# ─── nytorch tensor ──────────────────────────────────────────────────────────
# An N-dimensional tensor with reverse-mode automatic differentiation, on the
# native kernels in src/builtins/nytensor.cpp (the same compiled code on the
# interpreter and the VM, so results are bit-identical across engines).
#
#   var x = Tensor([[1.0, 2.0], [3.0, 4.0]], true)
#   var y = x.matmul(x.t()).sum()
#   y.backward()
#   x.grad            # flat, row-major, same layout as x.data
#
# REPRESENTATION. A tensor is `data` — a flat row-major list of floats (a bare
# float for a 0-d tensor) — plus `shape`, a list of ints. Considered instead:
# an opaque native handle (a C++ buffer the script only sees as an id). Two
# things decided it:
#   * Lists are what both engines already share, index, print and iterate,
#     and what ~15,000 lines of existing nytorch code pass around; a handle
#     would need a native call for every element access.
#   * The interpreter never frees containers (GC_NOTES.md) — but a handle
#     store would leak identically, since nothing tells the native side when
#     a handle dies. The VM frees lists by refcount, which a handle store
#     would lose. So the handle buys nothing on memory and costs everywhere.
# What keeps training loops affordable on the interpreter is doing less per
# op instead: fused kernels (linear, cross-entropy, conv, norms), views that
# share `data` (reshape/view/flatten/squeeze never copy), and optimizers that
# update parameter lists IN PLACE (nt_adam_step & co.) rather than building
# new lists every step.
#
# The data list of a view is shared: writing through one tensor's `data`
# changes the other, exactly like a PyTorch view.
#
# LANGUAGE NOTES (both are open interpreter bugs; the code below works
# around them rather than depending on a fix):
#   * A bare call inside a method resolves to a SAME-NAMED METHOD of the
#     class on the interpreter (max(a, b) inside any Tensor method would call
#     Tensor.max). Tensor methods therefore only call nt_* natives and _t_*
#     helpers, never a builtin that shares a name with a Tensor method.
#   * An inherited method's default arguments (and *args) are not applied on
#     the interpreter. Nothing subclasses Tensor: Parameter and Variable are
#     factory functions that return a Tensor.

# Gradient mode lives in a one-element list and is mutated in place: a
# method that rebinds a module-level name does not reach the global on the VM.
var _grad_state = [true]

# ── helpers (module level; names chosen not to collide with any method) ─────
def _t_numel(s):
    var n = 1
    var i = 0
    while i < len(s):
        n = n * s[i]
        i = i + 1
    return n

def _t_isnum(x):
    var k = type(x)
    return k == "int" or k == "float" or k == "bool"

# natives return flat lists; a 0-d tensor holds a bare float
def _t_fix(d, s):
    if len(s) == 0:
        return d[0]
    return d

def _t_floats(x):
    return tensor(x)

def _t_flat(d):
    if type(d) == "list":
        return d
    return [d]

def _t_wrap(x):
    if isinstance(x, Tensor):
        return x
    return Tensor(x)

def _t_new1(d, s, a):
    var t = Tensor(d, false, s)
    if _grad_state[0] and a.requires_grad:
        t.requires_grad = true
        t._prev = [a]
    return t

def _t_new2(d, s, a, b):
    var t = Tensor(d, false, s)
    if _grad_state[0] and (a.requires_grad or b.requires_grad):
        t.requires_grad = true
        t._prev = [a, b]
    return t

def _t_newn(d, s, parents):
    var t = Tensor(d, false, s)
    if _grad_state[0]:
        var i = 0
        while i < len(parents):
            if parents[i].requires_grad:
                t.requires_grad = true
            i = i + 1
        if t.requires_grad:
            t._prev = parents
    return t

# accumulate g (laid out with shape gs) into t, summing out broadcast dims
def _t_acc(t, g, gs):
    if not t.requires_grad:
        return
    var ts = t.shape
    if gs != ts:
        if _t_numel(gs) != _t_numel(ts) or len(gs) < len(ts):
            g = nt_sum_to(g, gs, ts)
        if len(ts) == 0 and type(g) == "list":
            g = g[0]
    elif len(ts) == 0 and type(g) == "list":
        g = g[0]
    if t.grad == none:
        t.grad = g
    elif type(g) == "list":
        t.grad = tensor_add(t.grad, g)
    else:
        t.grad = t.grad + g

def _t_dims(dim, nd):
    if dim == none:
        return none
    if type(dim) == "list":
        return dim
    return [dim]

def _t_sq_shape(s, dims):
    # shape after removing reduced dims (keepdim=false)
    var nd = len(s)
    var out = []
    var i = 0
    while i < nd:
        var keep = true
        if dims == none:
            keep = false
        else:
            var j = 0
            while j < len(dims):
                var d = dims[j]
                if d < 0:
                    d = d + nd
                if d == i:
                    keep = false
                j = j + 1
        if keep:
            out.append(s[i])
        i = i + 1
    return out

def _t_norm_dim(d, nd):
    if d < 0:
        return d + nd
    return d

# ── scalar fast paths (0-d op 0-d): plain arithmetic, no native call ────────
def _t_bin_scalar(op, a, b):
    var x = a.data
    var y = b.data
    var v = 0.0
    if op == "add":
        v = x + y
    elif op == "sub":
        v = x - y
    elif op == "mul":
        v = x * y
    else:
        v = nt_binary(op, x, [], y, [])[0][0]
    var out = Tensor(v, false, [])
    if _grad_state[0] and (a.requires_grad or b.requires_grad):
        out.requires_grad = true
        out._prev = [a, b]
        def _bw(g):
            var ga = 0.0
            var gb = 0.0
            if op == "add":
                ga = g
                gb = g
            elif op == "sub":
                ga = g
                gb = 0.0 - g
            elif op == "mul":
                ga = g * b.data
                gb = g * a.data
            elif op == "div":
                ga = g / b.data
                gb = 0.0 - g * out.data / b.data
            else:
                _t_bin_generic_bw(op, a, b, out, g)
                return
            if a.requires_grad:
                if a.grad == none:
                    a.grad = ga
                else:
                    a.grad = a.grad + ga
            if b.requires_grad:
                if b.grad == none:
                    b.grad = gb
                else:
                    b.grad = b.grad + gb
        out._bw = _bw
    return out

def _t_bin_generic_bw(op, a, b, out, g):
    var sa = []
    var sb = []
    var so = []
    if op == "pow":
        if a.requires_grad:
            var p = nt_binary("pow", a.data, sa, b.data - 1.0, sb)[0][0]
            a._acc(g * b.data * p)
        if b.requires_grad:
            b._acc(g * out.data * nt_unary("log", a.data)[0])
    elif op == "max" or op == "min":
        var win = (op == "max" and a.data >= b.data) or (op == "min" and a.data <= b.data)
        if win:
            a._acc(g)
            b._acc(0.0)
        else:
            a._acc(0.0)
            b._acc(g)
    else:
        raise RuntimeError("no gradient for comparison op '" + op + "'")

var _t_scalar_un = {"exp": true, "log": true, "tanh": true, "sigmoid": true, "relu": true, "neg": true}

def _t_un_scalar(op, a):
    var x = a.data
    var y = 0.0
    if op == "exp":
        y = exp(x)
    elif op == "log":
        y = nt_unary("log", x)[0]
    elif op == "tanh":
        y = tanh_fn(x)
    elif op == "sigmoid":
        y = nt_unary("sigmoid", x)[0]
    elif op == "relu":
        if x > 0:
            y = x
    else:
        y = 0.0 - x
    var out = _t_new1(y, [], a)
    if out.requires_grad:
        def _bw(g):
            if op == "exp":
                a._acc(g * out.data)
            elif op == "log":
                a._acc(g / x)
            elif op == "tanh":
                a._acc(g * (1.0 - out.data * out.data))
            elif op == "sigmoid":
                a._acc(g * out.data * (1.0 - out.data))
            elif op == "relu":
                if x > 0:
                    a._acc(g)
                else:
                    a._acc(0.0)
            else:
                a._acc(0.0 - g)
        out._bw = _bw
    return out

# ── binary op with NumPy broadcasting ───────────────────────────────────────
# (helpers are inlined in the hot ops: a Nython function call is the
# dominant per-op cost on the interpreter)
def _t_bin(op, a, b):
    if not isinstance(b, Tensor):
        b = Tensor(b)
    if type(a.data) != "list" and type(b.data) != "list":
        return _t_bin_scalar(op, a, b)
    var sa = a.shape
    var sb = b.shape
    var r = nt_binary(op, a.data, sa, b.data, sb)
    var so = r[1]
    var d = r[0]
    if len(so) == 0:
        d = d[0]
    var out = Tensor(d, false, so)
    if _grad_state[0] and (a.requires_grad or b.requires_grad):
        out.requires_grad = true
        out._prev = [a, b]
        def _bw(g):
            if op == "add":
                _t_acc(a, g, so)
                _t_acc(b, g, so)
            elif op == "sub":
                _t_acc(a, g, so)
                if b.requires_grad:
                    _t_acc(b, nt_unary("neg", g), so)
            elif op == "mul":
                if a.requires_grad:
                    _t_acc(a, nt_binary("mul", g, so, b.data, sb)[0], so)
                if b.requires_grad:
                    _t_acc(b, nt_binary("mul", g, so, a.data, sa)[0], so)
            elif op == "div":
                if a.requires_grad:
                    _t_acc(a, nt_binary("div", g, so, b.data, sb)[0], so)
                if b.requires_grad:
                    # d(a/b)/db = -out / b
                    var q = nt_binary("div", out.data, so, b.data, sb)[0]
                    _t_acc(b, nt_unary("neg", nt_binary("mul", g, so, q, so)[0]), so)
            elif op == "pow":
                if a.requires_grad:
                    var bm1 = nt_binary("sub", b.data, sb, 1.0, [])[0]
                    var p = nt_binary("pow", a.data, sa, bm1, sb)[0]
                    var dd = nt_binary("mul", p, so, b.data, sb)[0]
                    _t_acc(a, nt_binary("mul", g, so, dd, so)[0], so)
                if b.requires_grad:
                    var la = nt_unary("log", a.data)
                    var d2 = nt_binary("mul", out.data, so, la, sa)[0]
                    _t_acc(b, nt_binary("mul", g, so, d2, so)[0], so)
            elif op == "max" or op == "min":
                # gradient to the operand that won (ties: a)
                var cmp = "ge"
                if op == "min":
                    cmp = "le"
                var ma = nt_binary(cmp, a.data, sa, b.data, sb)[0]
                if a.requires_grad:
                    _t_acc(a, nt_binary("mul", g, so, ma, so)[0], so)
                if b.requires_grad:
                    var mb = nt_binary("sub", 1.0, [], ma, so)[0]
                    _t_acc(b, nt_binary("mul", g, so, mb, so)[0], so)
            else:
                raise RuntimeError("no gradient for comparison op '" + op + "'")
        out._bw = _bw
    return out

def _t_un(op, a):
    if type(a.data) != "list" and _t_scalar_un.has_key(op):
        return _t_un_scalar(op, a)
    var y = _t_fix(nt_unary(op, a.data), a.shape)
    var out = _t_new1(y, a.shape, a)
    if out.requires_grad:
        def _bw(g):
            _t_acc(a, _t_fix(nt_unary_bw(op, a.data, out.data, g), a.shape), a.shape)
        out._bw = _bw
    return out

def _t_uns(op, a, s):
    var y = _t_fix(nt_unary_s(op, a.data, s), a.shape)
    var out = _t_new1(y, a.shape, a)
    if out.requires_grad:
        def _bw(g):
            _t_acc(a, _t_fix(nt_unary_s_bw(op, a.data, out.data, s, g), a.shape), a.shape)
        out._bw = _bw
    return out

def _t_reduce(op, a, dim, keepdim, correction):
    var sa = a.shape
    var dims = _t_dims(dim, len(sa))
    var r = nt_reduce(op, a.data, sa, dims, keepdim, correction)
    var so = r[1]
    var out = _t_new1(_t_fix(r[0], so), so, a)
    if op == "argmax" or op == "argmin":
        out.requires_grad = false
        out._prev = none
        return out
    if out.requires_grad:
        def _bw(g):
            _t_acc(a, _t_fix(nt_reduce_bw(op, a.data, sa, dims, g, out.data, correction), sa), sa)
        out._bw = _bw
    return out

def _t_reshape(a, shape):
    var sa = a.shape
    var ns = nt_reshape_shape(_t_numel(sa), shape)
    var d = a.data
    if len(ns) == 0:
        d = _t_flat(d)[0]
    elif len(sa) == 0:
        d = [d]
    var out = _t_new1(d, ns, a)
    if out.requires_grad:
        def _bw(g):
            if len(sa) == 0:
                a._acc(_t_flat(g)[0])
            elif len(ns) == 0:
                a._acc([g])
            else:
                a._acc(g)
        out._bw = _bw
    return out

def _t_permute(a, dims):
    var sa = a.shape
    var r = nt_permute(a.data, sa, dims)
    var so = r[1]
    var out = _t_new1(_t_fix(r[0], so), so, a)
    if out.requires_grad:
        # inverse permutation
        var inv = []
        var i = 0
        while i < len(dims):
            inv.append(0)
            i = i + 1
        i = 0
        while i < len(dims):
            inv[_t_norm_dim(dims[i], len(dims))] = i
            i = i + 1
        def _bw(g):
            a._acc(nt_permute(g, so, inv)[0])
        out._bw = _bw
    return out

def _t_matmul(a, b):
    if not isinstance(b, Tensor):
        b = Tensor(b)
    var sa = a.shape
    if len(sa) == 1 and hasattr(a, "rows"):
        sa = a._mat_es()
    var sb = b.shape
    if len(sb) == 1 and hasattr(b, "rows"):
        sb = b._mat_es()
    var r = nt_matmul(a.data, sa, b.data, sb)
    var so = r[1]
    var d = r[0]
    if len(so) == 0:
        d = d[0]
    var out = Tensor(d, false, so)
    if len(so) == 2:
        out.rows = so[0]
        out.cols = so[1]
    if _grad_state[0] and (a.requires_grad or b.requires_grad):
        out.requires_grad = true
        out._prev = [a, b]
        def _bw(g):
            var gg = nt_matmul_bw(a.data, sa, b.data, sb, g)
            if a.requires_grad:
                var ga = gg[0]
                if len(sa) == 0:
                    ga = ga[0]
                a._acc(ga)
            if b.requires_grad:
                var gb = gg[1]
                if len(sb) == 0:
                    gb = gb[0]
                b._acc(gb)
        out._bw = _bw
    return out

def _t_cat(tensors, dim):
    var ds = []
    var ss = []
    var i = 0
    while i < len(tensors):
        var t = _t_wrap(tensors[i])
        tensors[i] = t
        ds.append(_t_flat(t.data))
        ss.append(t.shape)
        i = i + 1
    var nd = len(ss[0])
    var d = _t_norm_dim(dim, nd)
    var r = nt_cat(ds, ss, d)
    var out = _t_newn(r[0], r[1], tensors)
    if out.requires_grad:
        var sizes = []
        i = 0
        while i < len(ss):
            sizes.append(ss[i][d])
            i = i + 1
        var so = r[1]
        def _bw(g):
            var parts = nt_split(g, so, d, sizes)
            var k = 0
            while k < len(tensors):
                if tensors[k].requires_grad:
                    tensors[k]._acc(parts[k][0])
                k = k + 1
        out._bw = _bw
    return out

def _t_stack(tensors, dim):
    if dim == 0 and len(tensors) > 0:
        var all0 = true
        var i0 = 0
        while i0 < len(tensors):
            var t0 = tensors[i0]
            if not isinstance(t0, Tensor) or type(t0.data) == "list":
                all0 = false
                break
            i0 = i0 + 1
        if all0:
            return _t_stack_scalars(tensors)
    var us = []
    var i = 0
    while i < len(tensors):
        var t = _t_wrap(tensors[i])
        var nd = len(t.shape) + 1
        us.append(t.unsqueeze(_t_norm_dim(dim, nd)))
        i = i + 1
    return _t_cat(us, dim)

def _t_stack_scalars(ts):
    var d = []
    var rg = false
    var i = 0
    while i < len(ts):
        d.append(ts[i].data)
        if ts[i].requires_grad:
            rg = true
        i = i + 1
    var out = Tensor(d, false, [len(d)])
    if _grad_state[0] and rg:
        out.requires_grad = true
        out._prev = ts
        def _bw(g):
            var k = 0
            while k < len(ts):
                var t = ts[k]
                if t.requires_grad:
                    if t.grad == none:
                        t.grad = g[k]
                    else:
                        t.grad = t.grad + g[k]
                k = k + 1
        out._bw = _bw
    return out

def _t_index_select(a, dim, idx):
    var sa = a.shape
    var d = _t_norm_dim(dim, len(sa))
    var ix = idx
    if isinstance(idx, Tensor):
        ix = _t_flat(idx.data)
    var r = nt_index_select(a.data, sa, d, ix)
    var out = _t_new1(r[0], r[1], a)
    if out.requires_grad:
        def _bw(g):
            a._acc(_t_fix(nt_index_select_bw(g, sa, d, ix), sa))
        out._bw = _bw
    return out

def _t_slice(a, dim, start, stop, step):
    var sa = a.shape
    var d = _t_norm_dim(dim, len(sa))
    var r = nt_slice(a.data, sa, d, start, stop, step)
    var out = _t_new1(r[0], r[1], a)
    if out.requires_grad:
        def _bw(g):
            a._acc(_t_fix(nt_slice_bw(g, sa, d, start, stop, step, _t_numel(sa)), sa))
        out._bw = _bw
    return out

def _t_softmax(a, dim, logv):
    var sa = a.shape
    var y = _t_fix(nt_softmax(a.data, sa, dim, logv), sa)
    var out = _t_new1(y, sa, a)
    if out.requires_grad:
        def _bw(g):
            a._acc(_t_fix(nt_softmax_bw(out.data, g, sa, dim, logv), sa))
        out._bw = _bw
    return out

def _t_expand(a, shape):
    var sa = a.shape
    var d = nt_expand(a.data, sa, shape)
    var out = _t_new1(_t_fix(d, shape), shape, a)
    if out.requires_grad:
        def _bw(g):
            _t_acc(a, g, shape)
        out._bw = _bw
    return out

def _t_where(cond, a, b):
    a = _t_wrap(a)
    b = _t_wrap(b)
    var c = _t_wrap(cond)
    var sc = c.shape
    var sa = a.shape
    var sb = b.shape
    var r = nt_where(c.data, sc, a.data, sa, b.data, sb)
    var so = r[1]
    var out = _t_new2(_t_fix(r[0], so), so, a, b)
    if out.requires_grad:
        def _bw(g):
            var m = nt_expand(c.data, sc, so)
            var mz = nt_binary("ne", m, so, 0.0, [])[0]
            if a.requires_grad:
                _t_acc(a, nt_binary("mul", g, so, mz, so)[0], so)
            if b.requires_grad:
                var inv = nt_binary("sub", 1.0, [], mz, so)[0]
                _t_acc(b, nt_binary("mul", g, so, inv, so)[0], so)
        out._bw = _bw
    return out

def _t_clamp(a, lo, hi):
    var y = _t_fix(nt_clamp(a.data, lo, hi), a.shape)
    var out = _t_new1(y, a.shape, a)
    if out.requires_grad:
        def _bw(g):
            a._acc(_t_fix(nt_clamp_bw(a.data, lo, hi, g), a.shape))
        out._bw = _bw
    return out

def _t_fmt_num(v):
    var s = str(v)
    return s

def _t_repr_rec(d, s, dim, off):
    if dim == len(s):
        return [_t_fmt_num(d[off]), off + 1]
    var parts = []
    var i = 0
    var o = off
    while i < s[dim]:
        var r = _t_repr_rec(d, s, dim + 1, o)
        parts.append(r[0])
        o = r[1]
        i = i + 1
    var sep = ", "
    if dim < len(s) - 1:
        sep = ",\n" + (" " * (8 + dim))
    return ["[" + sep.join(parts) + "]", o]


class Tensor:
    # Tensor(data)                  number -> 0-d, flat list -> 1-d,
    #                               nested lists -> N-d (must be rectangular)
    # Tensor(data, requires_grad)
    # Tensor(flat, rg, shape)       internal fast path: flat data + shape
    def __init__(self, data, requires_grad=false, shape=none):
        self.data = data
        self.shape = shape
        self.requires_grad = requires_grad
        self.grad = none
        self._prev = none
        self._bw = none
        if shape == none:
            self._init_from(data)

    def _init_from(self, data):
        if _t_isnum(data):
            self.data = float(data)
            self.shape = []
        elif isinstance(data, Tensor):
            self.data = data.data
            self.shape = data.shape
        elif type(data) == "list":
            if len(data) > 0 and type(data[0]) == "list":
                var r = nt_from_nested(data)
                self.data = r[0]
                self.shape = r[1]
            else:
                if len(data) > 0 and not _t_isnum(data[0]):
                    raise TypeError("Tensor(): list elements must be numbers or lists (use torch.stack for a list of tensors)")
                self.data = tensor(data)
                self.shape = [len(data)]
        elif data == none:
            self.data = []
            self.shape = [0]
        else:
            raise TypeError("Tensor(): data must be a number, a (nested) list or a Tensor, got " + type(data))

    # The shape, healed when `t.data = ...` was assigned directly with a flat
    # list of a different length (read as 1-d). Ops read .shape directly (a
    # method call is the dominant per-op cost on the interpreter); the
    # native kernels still verify every data/shape pair and raise ValueError
    # on a mismatch, so a stale shape can fail loudly but never silently.
    def _es(self):
        var d = self.data
        var s = self.shape
        if type(d) == "list":
            if len(s) == 1:
                if s[0] != len(d):
                    self.shape = [len(d)]
            elif _t_numel(s) != len(d):
                self.shape = [len(d)]
        elif len(s) != 0:
            self.shape = []
        return self.shape

    # Shape for the 2-d ops. Legacy code marks a flat 1-d Variable as a
    # matrix by setting .rows/.cols on it; that view is adopted here.
    def _mat_es(self):
        var s = self.shape
        if len(s) == 1:
            var r = self?.rows ?? 0
            var c = self?.cols ?? 0
            if r > 0 and c > 0 and r * c == s[0]:
                self.shape = [r, c]
        return self.shape

    def _acc(self, g):
        if not self.requires_grad:
            return
        if self.grad == none:
            self.grad = g
        elif type(g) == "list":
            self.grad = tensor_add(self.grad, g)
        else:
            self.grad = self.grad + g

    # ── autograd ────────────────────────────────────────────────────────────
    # Reverse-mode sweep over the graph that produced this tensor. The
    # topological order is built with an explicit stack (no recursion), so
    # graphs of any depth work — the old recursive walk hung the interpreter
    # past ~900 nodes. A non-scalar output is seeded with ones unless a
    # gradient is given (PyTorch requires the gradient for non-scalars; the
    # older Variable API seeded ones, and code relies on that).
    def backward(self, gradient=none):
        if not self.requires_grad:
            raise RuntimeError("backward(): tensor does not require grad and has no grad_fn")
        var s = self.shape
        if gradient == none:
            if len(s) == 0:
                self.grad = 1.0
            else:
                self.grad = nt_full(s, 1.0)
        elif isinstance(gradient, Tensor):
            self.grad = gradient.data
        else:
            self.grad = gradient
        var topo = []
        var seen = {}
        var stack = [self]
        var state = [0]
        while len(stack) > 0:
            var top = len(stack) - 1
            var node = stack[top]
            if state[top] == 0:
                var key = id(node)
                if seen.has_key(key):
                    stack.pop()
                    state.pop()
                else:
                    seen[key] = true
                    state[top] = 1
                    var ps = node._prev
                    if ps != none:
                        var j = 0
                        while j < len(ps):
                            if ps[j].requires_grad and not seen.has_key(id(ps[j])):
                                stack.append(ps[j])
                                state.append(0)
                            j = j + 1
            else:
                stack.pop()
                state.pop()
                topo.append(node)
        var i = len(topo) - 1
        while i >= 0:
            var v = topo[i]
            if v._bw != none and v.grad != none:
                v._bw(v.grad)
            i = i - 1

    def zero_grad(self):
        self.grad = none

    def detach(self):
        return Tensor(self.data, false, self.shape)

    def requires_grad_(self, flag):
        self.requires_grad = flag
        return self

    def retain_grad(self):
        return self

    # ── info ────────────────────────────────────────────────────────────────
    def size(self):
        return self.shape

    def dim(self):
        return len(self.shape)

    def ndim(self):
        return len(self.shape)

    def numel(self):
        return _t_numel(self.shape)

    def item(self):
        if type(self.data) == "list":
            if len(self.data) != 1:
                raise ValueError("item(): only one-element tensors can be converted to a number, this one has " + str(len(self.data)))
            return self.data[0]
        return self.data

    def tolist(self):
        var s = self.shape
        if len(s) == 0:
            return self.data
        return nt_to_nested(self.data, s)

    def is_vector(self):
        return type(self.data) == "list"

    def is_matrix(self):
        return len(self._mat_es()) == 2

    # same shape and |a - b| <= atol + rtol |b| everywhere (torch.allclose)
    def allclose(self, other, rtol=0.00001, atol=0.00000001):
        var o = _t_wrap(other)
        if o.shape != self.shape:
            return false
        return nt_allclose(_t_flat(self.data), _t_flat(o.data), rtol, atol)

    def equal(self, other):
        var o = _t_wrap(other)
        return o.shape == self.shape and _t_flat(o.data) == _t_flat(self.data)

    def clone(self):
        var d = self.data
        if type(d) == "list":
            d = nt_binary("mul", d, [len(d)], 1.0, [])[0]
        var out = _t_new1(d, self.shape, self)
        if out.requires_grad:
            var a = self
            def _bw(g):
                a._acc(g)
            out._bw = _bw
        return out

    def __len__(self):
        var s = self.shape
        if len(s) == 0:
            raise TypeError("len() of a 0-d tensor")
        return s[0]

    def __repr__(self):
        var s = self.shape
        var head = "tensor("
        var body = ""
        if len(s) == 0:
            body = _t_fmt_num(self.data)
        else:
            body = _t_repr_rec(self.data, s, 0, 0)[0]
        var tail = ")"
        if self.requires_grad:
            tail = ", requires_grad=true)"
        return head + body + tail

    def __str__(self):
        return self.__repr__()

    def to_string(self):
        return self.__repr__()

    # ── arithmetic (Tensor or number on the right; broadcasting) ───────────
    def add(self, other):
        return _t_bin("add", self, other)
    def sub(self, other):
        return _t_bin("sub", self, other)
    def mul(self, other):
        return _t_bin("mul", self, other)
    def div(self, other):
        return _t_bin("div", self, other)
    def pow(self, other):
        if _t_isnum(other):
            return _t_uns("pow", self, other)
        return _t_bin("pow", self, other)
    def maximum(self, other):
        return _t_bin("max", self, other)
    def minimum(self, other):
        return _t_bin("min", self, other)
    def rsub(self, other):
        return _t_bin("sub", _t_wrap(other), self)
    def rdiv(self, other):
        return _t_bin("div", _t_wrap(other), self)
    def eq(self, other):
        return _t_bin("eq", self, other)
    def ne(self, other):
        return _t_bin("ne", self, other)
    def lt(self, other):
        return _t_bin("lt", self, other)
    def le(self, other):
        return _t_bin("le", self, other)
    def gt(self, other):
        return _t_bin("gt", self, other)
    def ge(self, other):
        return _t_bin("ge", self, other)
    def neg(self):
        return _t_un("neg", self)
    def scale(self, k):
        return _t_bin("mul", self, k)
    def __add__(self, other):
        return _t_bin("add", self, other)
    def __radd__(self, other):
        return _t_bin("add", _t_wrap(other), self)
    def __sub__(self, other):
        return _t_bin("sub", self, other)
    def __rsub__(self, other):
        return _t_bin("sub", _t_wrap(other), self)
    def __mul__(self, other):
        return _t_bin("mul", self, other)
    def __rmul__(self, other):
        return _t_bin("mul", _t_wrap(other), self)
    def __div__(self, other):
        return _t_bin("div", self, other)
    def __truediv__(self, other):
        return _t_bin("div", self, other)
    def __neg__(self):
        return _t_un("neg", self)
    def __pow__(self, other):
        return self.pow(other)
    # `@` is not a Nython operator; __matmul__ is here for completeness and
    # for code that calls it explicitly.
    def __matmul__(self, other):
        return _t_matmul(self, other)

    # ── elementwise functions ───────────────────────────────────────────────
    def exp(self):
        return _t_un("exp", self)
    def log(self):
        return _t_un("log", self)
    def log1p(self):
        return _t_un("log1p", self)
    def sqrt(self):
        return _t_un("sqrt", self)
    def rsqrt(self):
        return _t_un("rsqrt", self)
    def abs(self):
        return _t_un("abs", self)
    def sign(self):
        return _t_un("sign", self)
    def sin(self):
        return _t_un("sin", self)
    def cos(self):
        return _t_un("cos", self)
    def tanh(self):
        return _t_un("tanh", self)
    def sigmoid(self):
        return _t_un("sigmoid", self)
    def relu(self):
        return _t_un("relu", self)
    def gelu(self):
        return _t_un("gelu", self)
    def silu(self):
        return _t_un("silu", self)
    def swish(self):
        return _t_un("silu", self)
    def softplus(self):
        return _t_un("softplus", self)
    def mish(self):
        return _t_un("mish", self)
    def hardsigmoid(self):
        return _t_un("hardsigmoid", self)
    def hardswish(self):
        return _t_un("hardswish", self)
    def softsign(self):
        return _t_un("softsign", self)
    def square(self):
        return _t_un("square", self)
    def reciprocal(self):
        return _t_un("reciprocal", self)
    def floor(self):
        return _t_un("floor", self)
    def ceil(self):
        return _t_un("ceil", self)
    def round(self):
        return _t_un("round", self)
    def leaky_relu(self, slope):
        return _t_uns("leaky_relu", self, slope)
    def elu(self, alpha=1.0):
        return _t_uns("elu", self, alpha)
    def clamp(self, lo, hi):
        return _t_clamp(self, lo, hi)
    def clip(self, lo, hi):
        return _t_clamp(self, lo, hi)

    # ── reductions (dim: none = all, an int, or a list of ints) ─────────────
    def sum(self, dim=none, keepdim=false):
        return _t_reduce("sum", self, dim, keepdim, 1.0)
    def mean(self, dim=none, keepdim=false):
        return _t_reduce("mean", self, dim, keepdim, 1.0)
    def prod(self, dim=none, keepdim=false):
        return _t_reduce("prod", self, dim, keepdim, 1.0)
    def max(self, dim=none, keepdim=false):
        return _t_reduce("max", self, dim, keepdim, 1.0)
    def min(self, dim=none, keepdim=false):
        return _t_reduce("min", self, dim, keepdim, 1.0)
    def amax(self, dim=none, keepdim=false):
        return _t_reduce("max", self, dim, keepdim, 1.0)
    def amin(self, dim=none, keepdim=false):
        return _t_reduce("min", self, dim, keepdim, 1.0)
    def argmax(self, dim=none, keepdim=false):
        return _t_reduce("argmax", self, dim, keepdim, 1.0)
    def argmin(self, dim=none, keepdim=false):
        return _t_reduce("argmin", self, dim, keepdim, 1.0)
    # unbiased (correction=1) by default, like torch.var
    def var(self, dim=none, keepdim=false, correction=1):
        return _t_reduce("var", self, dim, keepdim, correction)
    def std(self, dim=none, keepdim=false, correction=1):
        return _t_reduce("std", self, dim, keepdim, correction)
    def logsumexp(self, dim=none, keepdim=false):
        return _t_reduce("logsumexp", self, dim, keepdim, 1.0)
    def norm(self, dim=none, keepdim=false):
        return _t_reduce("norm", self, dim, keepdim, 1.0)
    def softmax(self, dim=none):
        if dim == none:
            dim = -1
        return _t_softmax(self, dim, false)
    def log_softmax(self, dim=none):
        if dim == none:
            dim = -1
        return _t_softmax(self, dim, true)

    # ── linear algebra ──────────────────────────────────────────────────────
    def matmul(self, other):
        return _t_matmul(self, other)
    def mm(self, other):
        return _t_matmul(self, other)
    def bmm(self, other):
        return _t_matmul(self, other)
    def dot(self, other):
        return _t_matmul(self, other)
    def mv(self, other):
        return _t_matmul(self, other)
    def outer(self, other):
        return _t_matmul(self.reshape([-1, 1]), _t_wrap(other).reshape([1, -1]))

    # ── shape ───────────────────────────────────────────────────────────────
    def reshape(self, shape):
        return _t_reshape(self, shape)
    def view(self, shape):
        return _t_reshape(self, shape)
    def flatten(self, start_dim=0, end_dim=none):
        if end_dim == none:
            end_dim = -1
        var s = self.shape
        if len(s) == 0:
            return _t_reshape(self, [1])
        var a = _t_norm_dim(start_dim, len(s))
        var b = _t_norm_dim(end_dim, len(s))
        var ns = []
        var i = 0
        var mid = 1
        while i < len(s):
            if i < a or i > b:
                ns.append(s[i])
            else:
                mid = mid * s[i]
                if i == b:
                    ns.append(mid)
            i = i + 1
        return _t_reshape(self, ns)
    def squeeze(self, dim=none):
        var s = self.shape
        var ns = []
        var i = 0
        while i < len(s):
            var drop = false
            if s[i] == 1:
                if dim == none:
                    drop = true
                elif _t_norm_dim(dim, len(s)) == i:
                    drop = true
            if not drop:
                ns.append(s[i])
            i = i + 1
        return _t_reshape(self, ns)
    def unsqueeze(self, dim):
        var s = self.shape
        var d = _t_norm_dim(dim, len(s) + 1)
        var ns = []
        var i = 0
        while i <= len(s):
            if i == d:
                ns.append(1)
            if i < len(s):
                ns.append(s[i])
            i = i + 1
        return _t_reshape(self, ns)
    def permute(self, dims):
        return _t_permute(self, dims)
    def transpose(self, d0, d1):
        var s = self.shape
        var dims = []
        var i = 0
        while i < len(s):
            dims.append(i)
            i = i + 1
        var a = _t_norm_dim(d0, len(s))
        var b = _t_norm_dim(d1, len(s))
        dims[a] = b
        dims[b] = a
        return _t_permute(self, dims)
    def t(self):
        var s = self.shape
        if len(s) < 2:
            return self
        return self.transpose(0, 1)
    def expand(self, shape):
        return _t_expand(self, shape)
    def broadcast_to(self, shape):
        return _t_expand(self, shape)
    def contiguous(self):
        return self

    # ── indexing ────────────────────────────────────────────────────────────
    def index_select(self, dim, index):
        return _t_index_select(self, dim, index)
    def narrow(self, dim, start, length):
        return _t_slice(self, dim, start, start + length, 1)
    def slice(self, dim, start, stop, step=1):
        return _t_slice(self, dim, start, stop, step)
    def select(self, dim_or_index, index=none):
        # select(i) (legacy: element i of a 1-d tensor) or select(dim, i)
        var dim = 0
        var i = dim_or_index
        if index != none:
            dim = dim_or_index
            i = index
        var s = self.shape
        var r = _t_index_select(self, dim, [i])
        return r.squeeze(dim)
    def select_row(self, i):
        self._mat_es()
        return self.select(0, i)
    # t[i] selects along dim 0; t[[i, j, ...]] gathers rows
    def __getitem__(self, idx):
        if type(idx) == "list":
            return _t_index_select(self, 0, idx)
        if isinstance(idx, Tensor):
            return _t_index_select(self, 0, idx)
        return self.select(0, idx)
    # t[i] = value (no autograd; for filling a leaf tensor)
    def __setitem__(self, idx, value):
        var s = self.shape
        if len(s) == 0:
            raise IndexError("cannot index a 0-d tensor")
        var inner = _t_numel(s) / s[0]
        inner = int(inner)
        var i = idx
        if i < 0:
            i = i + s[0]
        if i < 0 or i >= s[0]:
            raise IndexError("index " + str(idx) + " out of range for dimension of size " + str(s[0]))
        var vals = value
        if isinstance(value, Tensor):
            vals = _t_flat(value.data)
        elif _t_isnum(value):
            vals = nt_full([inner], value)
        if len(vals) != inner:
            raise ValueError("cannot assign " + str(len(vals)) + " values to a slice of " + str(inner))
        var k = 0
        while k < inner:
            self.data[i * inner + k] = 1.0 * vals[k]
            k = k + 1

    # ── legacy Variable API (older nytorch code; kept working) ──────────────
    def add_bias_row(self, bias):
        self._mat_es()
        return _t_bin("add", self, bias)
    def _accum(self, g):
        self._acc(g)


# ── Parameter / Variable (factories, not subclasses: see LANGUAGE NOTES) ────
def Parameter(data, requires_grad=true):
    var t = _t_wrap(data)
    var p = Tensor(t.data, requires_grad, t.shape)
    p._param = true
    return p

def is_parameter(x):
    if not isinstance(x, Tensor):
        return false
    return hasattr(x, "_param")

# Variable(data, requires_grad): the round-72 autograd API, now the same
# Tensor. A float is a 0-d tensor, a flat list a 1-d one.
def Variable(data, requires_grad=false):
    return Tensor(data, requires_grad)


# ── gradient mode ───────────────────────────────────────────────────────────
class _GradMode:
    def __init__(self, enabled):
        self.enabled = enabled
        self.prev = true
    def __enter__(self):
        self.prev = _grad_state[0]
        _grad_state[0] = self.enabled
        return self
    def __exit__(self, a, b, c):
        _grad_state[0] = self.prev
        return false

# with no_grad(): ...   — ops inside record no graph
def no_grad():
    return _GradMode(false)

def enable_grad():
    return _GradMode(true)

def set_grad_enabled(flag):
    _grad_state[0] = flag

def is_grad_enabled():
    return _grad_state[0]


# ── save / load (versioned float64 file with shapes: nt_save/nt_load) ───────
# save_tensors({"name": Tensor, ...}, path) / load_tensors(path) -> map
def save_tensors(named, path):
    var entries = []
    var keys = sorted(named.keys())
    var i = 0
    while i < len(keys):
        var t = _t_wrap(named[keys[i]])
        entries.append([keys[i], _t_flat(t.data), t.shape])
        i = i + 1
    return nt_save(path, entries)

def load_tensors(path):
    var out = {}
    var es = nt_load(path)
    var i = 0
    while i < len(es):
        var e = es[i]
        out[e[0]] = Tensor(_t_fix(e[1], e[2]), false, e[2])
        i = i + 1
    return out


# ── the `torch` namespace ───────────────────────────────────────────────────
# torch.zeros([2, 3]), torch.cat([a, b], 0), torch.manual_seed(0), ...
# (`zeros`, `ones`, `tensor`, `softmax` ... as bare globals are the older flat-
# list natives, which a great deal of code depends on.)
class _Torch:
    def tensor(self, data, requires_grad=false):
        return Tensor(data, requires_grad)
    def as_tensor(self, data):
        return _t_wrap(data)
    def from_flat(self, flat, shape, requires_grad=false):
        var ns = nt_reshape_shape(len(flat), shape)
        return Tensor(_t_fix(_t_floats(flat), ns), requires_grad, ns)
    def zeros(self, shape, requires_grad=false):
        return Tensor(_t_fix(nt_full(shape, 0.0), shape), requires_grad, shape)
    def ones(self, shape, requires_grad=false):
        return Tensor(_t_fix(nt_full(shape, 1.0), shape), requires_grad, shape)
    def full(self, shape, value, requires_grad=false):
        return Tensor(_t_fix(nt_full(shape, value), shape), requires_grad, shape)
    def zeros_like(self, t):
        var s = t.shape
        return Tensor(_t_fix(nt_full(s, 0.0), s), false, s)
    def ones_like(self, t):
        var s = t.shape
        return Tensor(_t_fix(nt_full(s, 1.0), s), false, s)
    def arange(self, start, stop=none, step=1):
        var a = start
        var b = stop
        if stop == none:
            a = 0
            b = start
        var d = nt_arange(a, b, step)
        return Tensor(d, false, [len(d)])
    def linspace(self, start, stop, steps):
        return Tensor(nt_linspace(start, stop, steps), false, [steps])
    def eye(self, n, m=none):
        var r = nt_eye(n, m)
        return Tensor(r[0], false, r[1])
    def rand(self, shape, requires_grad=false):
        return Tensor(_t_fix(nt_rand(shape), shape), requires_grad, shape)
    def randn(self, shape, requires_grad=false):
        return Tensor(_t_fix(nt_randn(shape), shape), requires_grad, shape)
    def randint(self, low, high, shape):
        return Tensor(_t_fix(nt_randint(low, high, shape), shape), false, shape)
    def randperm(self, n):
        return Tensor(nt_randperm(n), false, [n])
    def manual_seed(self, seed):
        return nt_manual_seed(seed)
    def cat(self, tensors, dim=0):
        return _t_cat(tensors, dim)
    def stack(self, tensors, dim=0):
        return _t_stack(tensors, dim)
    def matmul(self, a, b):
        return _t_matmul(_t_wrap(a), b)
    def where(self, cond, a, b):
        return _t_where(cond, a, b)
    def einsum(self, eq, operands):
        var ds = []
        var ss = []
        var i = 0
        while i < len(operands):
            var t = _t_wrap(operands[i])
            ds.append(_t_flat(t.data))
            ss.append(t.shape)
            i = i + 1
        var r = nt_einsum(eq, ds, ss)
        return Tensor(_t_fix(r[0], r[1]), false, r[1])
    def no_grad(self):
        return _GradMode(false)
    def enable_grad(self):
        return _GradMode(true)
    def is_grad_enabled(self):
        return _grad_state[0]
    def allclose(self, a, b, rtol=0.00001, atol=0.00000001):
        return nt_allclose(_t_flat(_t_wrap(a).data), _t_flat(_t_wrap(b).data), rtol, atol)
    def save(self, obj, path):
        # obj: a Tensor, or a map of name -> Tensor (e.g. model.state_dict())
        if isinstance(obj, Tensor):
            return save_tensors({"tensor": obj}, path)
        return save_tensors(obj, path)
    def load(self, path):
        var m = load_tensors(path)
        var keys = m.keys()
        if len(keys) == 1 and keys[0] == "tensor":
            return m["tensor"]
        return m
    def numel(self, t):
        return t.numel()
    def exp(self, t):
        return _t_un("exp", _t_wrap(t))
    def log(self, t):
        return _t_un("log", _t_wrap(t))
    def sqrt(self, t):
        return _t_un("sqrt", _t_wrap(t))
    def tanh(self, t):
        return _t_un("tanh", _t_wrap(t))
    def sigmoid(self, t):
        return _t_un("sigmoid", _t_wrap(t))
    def relu(self, t):
        return _t_un("relu", _t_wrap(t))
    def abs(self, t):
        return _t_un("abs", _t_wrap(t))
    def softmax(self, t, dim):
        return _t_softmax(_t_wrap(t), dim, false)
    def log_softmax(self, t, dim):
        return _t_softmax(_t_wrap(t), dim, true)
    def sum(self, t, dim=none, keepdim=false):
        return _t_reduce("sum", _t_wrap(t), dim, keepdim, 1.0)
    def mean(self, t, dim=none, keepdim=false):
        return _t_reduce("mean", _t_wrap(t), dim, keepdim, 1.0)
    def max(self, t, dim=none, keepdim=false):
        return _t_reduce("max", _t_wrap(t), dim, keepdim, 1.0)
    def argmax(self, t, dim=none, keepdim=false):
        return _t_reduce("argmax", _t_wrap(t), dim, keepdim, 1.0)
    def clamp(self, t, lo, hi):
        return _t_clamp(_t_wrap(t), lo, hi)
    def maximum(self, a, b):
        return _t_bin("max", _t_wrap(a), b)
    def minimum(self, a, b):
        return _t_bin("min", _t_wrap(a), b)

var torch = _Torch()
