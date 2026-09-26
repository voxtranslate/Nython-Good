# ─── nytorch nn core: Module, containers, functional ops ─────────────────────
# Everything here is differentiable through the Tensor autograd engine
# (lib/nytorch/tensor.ny) and runs its arithmetic in the shared native
# kernels, so a layer gives the same numbers on the interpreter and the VM.
#
# Module finds its parameters, sub-modules and buffers from its fields, by
# name, in sorted order (field order is not the same on the two engines;
# sorted order is, so parameters()/state_dict()/optimizer state line up):
#   * a Parameter (see tensor.ny)          -> a parameter
#   * a Module, or a list of Modules       -> child module(s)
#   * a tensor registered with register_buffer(name, t) -> a buffer
#
# LANGUAGE NOTE: on the interpreter an INHERITED method does not apply its
# default arguments or *args. So Module's own methods take fixed arguments
# (train() / eval() / train_mode(flag) instead of train(mode=true)), and
# Module.__call__(x) forwards exactly one argument; a module whose forward
# takes several inputs defines its own __call__ (see MultiheadAttention).

import "lib/nytorch/tensor.ny"

class Module:
    def __init__(self):
        self.training = true
        self._buffer_names = []

    def forward(self, x):
        raise NotImplementedError(self.class_name() + ".forward() is not implemented")

    def __call__(self, x):
        return self.forward(x)

    # ── discovery ───────────────────────────────────────────────────────────
    def _field_names(self):
        return sorted(self.fields())

    def named_children(self):
        var out = []
        var names = self._field_names()
        var i = 0
        while i < len(names):
            var nm = names[i]
            var v = getattr(self, nm)
            if isinstance(v, Module):
                out.append([nm, v])
            elif type(v) == "list":
                var j = 0
                while j < len(v):
                    if isinstance(v[j], Module):
                        out.append([nm + "." + str(j), v[j]])
                    j = j + 1
            i = i + 1
        return out

    def children(self):
        var out = []
        var ch = self.named_children()
        var i = 0
        while i < len(ch):
            out.append(ch[i][1])
            i = i + 1
        return out

    def _collect(self, prefix, out, seen, want_buffers):
        var names = self._field_names()
        var i = 0
        while i < len(names):
            var nm = names[i]
            var v = getattr(self, nm)
            if want_buffers:
                if (nm in self._buffer_names) and isinstance(v, Tensor):
                    out.append([prefix + nm, v])
            elif is_parameter(v):
                var key = id(v)
                if not seen.has_key(key):
                    seen[key] = true
                    out.append([prefix + nm, v])
            elif type(v) == "list":
                var j = 0
                while j < len(v):
                    if is_parameter(v[j]):
                        var k2 = id(v[j])
                        if not seen.has_key(k2):
                            seen[k2] = true
                            out.append([prefix + nm + "." + str(j), v[j]])
                    j = j + 1
            i = i + 1
        var ch = self.named_children()
        var c = 0
        while c < len(ch):
            ch[c][1]._collect(prefix + ch[c][0] + ".", out, seen, want_buffers)
            c = c + 1

    def named_parameters(self):
        var out = []
        self._collect("", out, {}, false)
        return out

    def parameters(self):
        var out = []
        var np = self.named_parameters()
        var i = 0
        while i < len(np):
            out.append(np[i][1])
            i = i + 1
        return out

    def named_buffers(self):
        var out = []
        self._collect("", out, {}, true)
        return out

    def register_buffer(self, name, t):
        if not (name in self._buffer_names):
            self._buffer_names.append(name)
        setattr(self, name, t)

    def num_parameters(self):
        var n = 0
        var ps = self.parameters()
        var i = 0
        while i < len(ps):
            n = n + ps[i].numel()
            i = i + 1
        return n

    # ── state ───────────────────────────────────────────────────────────────
    # name -> Tensor (parameters and buffers). The tensors are the live ones
    # (as in PyTorch); torch.save(model.state_dict(), path) writes them out.
    def state_dict(self):
        var sd = {}
        var np = self.named_parameters()
        var i = 0
        while i < len(np):
            sd[np[i][0]] = np[i][1]
            i = i + 1
        var nb = self.named_buffers()
        i = 0
        while i < len(nb):
            sd[nb[i][0]] = nb[i][1]
            i = i + 1
        return sd

    # Copies values into the existing tensors in place (so an optimizer that
    # already holds them keeps working). Strict: every key must match, with
    # the same shape.
    def load_state_dict(self, sd):
        var own = self.state_dict()
        var keys = sorted(own.keys())
        var i = 0
        while i < len(keys):
            var k = keys[i]
            if not sd.has_key(k):
                raise KeyError("load_state_dict: missing key '" + k + "'")
            var dst = own[k]
            var src = _t_wrap(sd[k])
            if src.shape != dst.shape:
                raise ValueError("load_state_dict: '" + k + "' has shape " + str(src.shape) + ", model expects " + str(dst.shape))
            if type(dst.data) == "list":
                nt_copy_(dst.data, src.data)
            else:
                dst.data = src.data
            i = i + 1
        var sk = sd.keys()
        i = 0
        while i < len(sk):
            if not own.has_key(sk[i]):
                raise KeyError("load_state_dict: unexpected key '" + sk[i] + "'")
            i = i + 1
        return true

    # ── modes ───────────────────────────────────────────────────────────────
    def train_mode(self, flag):
        self.training = flag
        var ch = self.children()
        var i = 0
        while i < len(ch):
            ch[i].train_mode(flag)
            i = i + 1
        return self

    def train(self):
        return self.train_mode(true)

    def eval(self):
        return self.train_mode(false)

    def zero_grad(self):
        var ps = self.parameters()
        var i = 0
        while i < len(ps):
            ps[i].grad = none
            i = i + 1

    def requires_grad_(self, flag):
        var ps = self.parameters()
        var i = 0
        while i < len(ps):
            ps[i].requires_grad = flag
            i = i + 1
        return self

    def extra_repr(self):
        return ""

    def __repr__(self):
        var head = self.class_name() + "(" + self.extra_repr()
        var ch = self.named_children()
        if len(ch) == 0:
            return head + ")"
        var s = head + "\n"
        var i = 0
        while i < len(ch):
            s = s + "  (" + ch[i][0] + "): " + str(ch[i][1]) + "\n"
            i = i + 1
        return s + ")"


# ── containers ──────────────────────────────────────────────────────────────
class Sequential(Module):
    # Sequential(m1, m2, ...) (up to 16) or Sequential([m1, m2, ...]).
    # (Fixed optional arguments rather than *mods: a constructor's *args
    # arrive empty on the interpreter.)
    def __init__(self, m0=none, m1=none, m2=none, m3=none, m4=none, m5=none, m6=none, m7=none, m8=none, m9=none, m10=none, m11=none, m12=none, m13=none, m14=none, m15=none):
        super().__init__()
        var ms = [m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15]
        if type(m0) == "list":
            ms = m0
        self.layers = []
        var i = 0
        while i < len(ms):
            if ms[i] != none:
                self.layers.append(ms[i])
            i = i + 1

    def forward(self, x):
        var out = x
        var i = 0
        while i < len(self.layers):
            out = self.layers[i](out)
            i = i + 1
        return out

    def append(self, m):
        self.layers.append(m)
        return self

    def add(self, m):
        self.layers.append(m)
        return self

    def __getitem__(self, i):
        return self.layers[i]

    def __len__(self):
        return len(self.layers)


class ModuleList(Module):
    def __init__(self, mods):
        super().__init__()
        self.items = []
        var i = 0
        while i < len(mods):
            self.items.append(mods[i])
            i = i + 1

    def append(self, m):
        self.items.append(m)
        return self

    def __getitem__(self, i):
        return self.items[i]

    def __len__(self):
        return len(self.items)

    def forward(self, x):
        raise NotImplementedError("ModuleList has no forward(); index it and call the modules")


# ── functional ops (all differentiable) ─────────────────────────────────────
def _fn_linear(x, w, b):
    x = _t_wrap(x)
    var xs = x.shape
    var ws = w.shape
    var bd = none
    if b != none:
        bd = b.data
    var r = nt_linear(x.data, xs, w.data, ws, bd)
    var so = r[1]
    var parents = [x, w]
    if b != none:
        parents = [x, w, b]
    var out = _t_newn(r[0], so, parents)
    if out.requires_grad:
        def _bw(g):
            var gg = nt_linear_bw(x.data, xs, w.data, ws, g, b != none)
            if x.requires_grad:
                x._acc(_t_fix(gg[0], xs))
            if w.requires_grad:
                w._acc(gg[1])
            if b != none and b.requires_grad:
                b._acc(gg[2])
        out._bw = _bw
    return out

def _fn_pair(v):
    if type(v) == "list":
        return v
    return [v, v]

def _fn_conv2d(x, w, b, stride, padding, dilation, groups):
    x = _t_wrap(x)
    var xs = x.shape
    var ws = w.shape
    var bd = none
    if b != none:
        bd = b.data
    var st = _fn_pair(stride)
    var pd = _fn_pair(padding)
    var dl = _fn_pair(dilation)
    var r = nt_conv2d(x.data, xs, w.data, ws, bd, st, pd, dl, groups)
    var so = r[1]
    var parents = [x, w]
    if b != none:
        parents = [x, w, b]
    var out = _t_newn(r[0], so, parents)
    if out.requires_grad:
        def _bw(g):
            var gg = nt_conv2d_bw(x.data, xs, w.data, ws, g, st, pd, dl, groups, b != none)
            if x.requires_grad:
                x._acc(gg[0])
            if w.requires_grad:
                w._acc(gg[1])
            if b != none and b.requires_grad:
                b._acc(gg[2])
        out._bw = _bw
    return out

# conv1d as a conv2d over a height-1 image: (N, C, L) -> (N, C, 1, L)
def _fn_conv1d(x, w, b, stride, padding, dilation, groups):
    x = _t_wrap(x)
    var xs = x.shape
    var ws = w.shape
    var x4 = none
    if len(xs) == 3:
        x4 = x.reshape([xs[0], xs[1], 1, xs[2]])
    elif len(xs) == 2:
        x4 = x.reshape([xs[0], 1, xs[1]])
    else:
        raise ValueError("conv1d input must be (N, C, L) or (C, L), got " + str(xs))
    if len(ws) != 3:
        raise ValueError("conv1d weight must be (out_channels, in_channels/groups, kernel), got " + str(ws))
    var w4 = w.reshape([ws[0], ws[1], 1, ws[2]])
    var y = _fn_conv2d(x4, w4, b, [1, stride], [0, padding], [1, dilation], groups)
    var ys = y.shape
    if len(ys) == 4:
        return y.reshape([ys[0], ys[1], ys[3]])
    return y.reshape([ys[0], ys[2]])

def _fn_max_pool2d(x, kernel, stride, padding):
    x = _t_wrap(x)
    var xs = x.shape
    var r = nt_maxpool2d(x.data, xs, kernel, stride, padding)
    var idx = r[2]
    var out = _t_new1(r[0], r[1], x)
    if out.requires_grad:
        var n = _t_numel(xs)
        def _bw(g):
            x._acc(nt_maxpool2d_bw(g, idx, n))
        out._bw = _bw
    return out

def _fn_avg_pool2d(x, kernel, stride, padding):
    x = _t_wrap(x)
    var xs = x.shape
    var r = nt_avgpool2d(x.data, xs, kernel, stride, padding)
    var out = _t_new1(r[0], r[1], x)
    if out.requires_grad:
        def _bw(g):
            x._acc(nt_avgpool2d_bw(g, xs, kernel, stride, padding, 0))
        out._bw = _bw
    return out

def _fn_pool1d(x, kernel, stride, padding, is_max):
    x = _t_wrap(x)
    var xs = x.shape
    var x4 = none
    if len(xs) == 3:
        x4 = x.reshape([xs[0], xs[1], 1, xs[2]])
    elif len(xs) == 2:
        x4 = x.reshape([xs[0], 1, xs[1]])
    else:
        raise ValueError("pool1d input must be (N, C, L) or (C, L), got " + str(xs))
    var st = stride
    if st == none:
        st = kernel
    var y = none
    if is_max:
        y = _fn_max_pool2d(x4, [1, kernel], [1, st], [0, padding])
    else:
        y = _fn_avg_pool2d(x4, [1, kernel], [1, st], [0, padding])
    var ys = y.shape
    if len(ys) == 4:
        return y.reshape([ys[0], ys[1], ys[3]])
    return y.reshape([ys[0], ys[2]])

# running_mean / running_var are updated in place when training
def _fn_batch_norm(x, running_mean, running_var, weight, bias, training, momentum, eps):
    x = _t_wrap(x)
    var xs = x.shape
    var gd = none
    var bd = none
    if weight != none:
        gd = weight.data
    if bias != none:
        bd = bias.data
    var rm = none
    var rv = none
    if running_mean != none:
        rm = running_mean.data
    if running_var != none:
        rv = running_var.data
    var use_batch = training or rm == none
    var r = nt_batchnorm(x.data, xs, gd, bd, rm, rv, use_batch, momentum, eps)
    var mean = r[1]
    var inv = r[2]
    var parents = [x]
    if weight != none:
        parents.append(weight)
    if bias != none:
        parents.append(bias)
    var out = _t_newn(r[0], xs, parents)
    if out.requires_grad:
        def _bw(g):
            var gg = nt_batchnorm_bw(x.data, xs, gd, mean, inv, g, use_batch)
            if x.requires_grad:
                x._acc(gg[0])
            if weight != none and weight.requires_grad:
                weight._acc(gg[1])
            if bias != none and bias.requires_grad:
                bias._acc(gg[2])
        out._bw = _bw
    return out

def _fn_layer_norm(x, n_last, weight, bias, eps):
    x = _t_wrap(x)
    var xs = x.shape
    var gd = none
    var bd = none
    if weight != none:
        gd = weight.data
    if bias != none:
        bd = bias.data
    var r = nt_layernorm(x.data, xs, n_last, gd, bd, eps)
    var mean = r[1]
    var rstd = r[2]
    var parents = [x]
    if weight != none:
        parents.append(weight)
    if bias != none:
        parents.append(bias)
    var out = _t_newn(_t_fix(r[0], xs), xs, parents)
    if out.requires_grad:
        def _bw(g):
            var gg = nt_layernorm_bw(x.data, xs, n_last, gd, mean, rstd, g)
            if x.requires_grad:
                x._acc(gg[0])
            if weight != none and weight.requires_grad:
                weight._acc(gg[1])
            if bias != none and bias.requires_grad:
                bias._acc(gg[2])
        out._bw = _bw
    return out

def _fn_embedding(idx, weight, padding_idx):
    var it = _t_wrap(idx)
    var is_ = it.shape
    var ws = weight.shape
    var flat = _t_flat(it.data)
    var r = nt_embedding(weight.data, ws, flat, is_)
    var out = _t_new1(r[0], r[1], weight)
    if out.requires_grad:
        def _bw(g):
            weight._acc(nt_embedding_bw(g, flat, ws, padding_idx))
        out._bw = _bw
    return out

def _fn_dropout(x, p, training):
    x = _t_wrap(x)
    if not training or p == 0:
        return x
    var xs = x.shape
    var mask = nt_dropout_mask(_t_numel(xs), p)
    var r = nt_binary("mul", x.data, xs, mask, xs)
    var out = _t_new1(_t_fix(r[0], xs), xs, x)
    if out.requires_grad:
        def _bw(g):
            x._acc(_t_fix(nt_binary("mul", g, xs, mask, xs)[0], xs))
        out._bw = _bw
    return out

def _fn_target_flat(target):
    if isinstance(target, Tensor):
        return _t_flat(target.data)
    if type(target) == "list":
        return target
    return [target]

# the per-element loss gradient times the upstream gradient, broadcast over
# the class dimension (dim 1, or none for an unbatched input)
def _fn_class_bw(x, xs, grad, lshape, g):
    if len(lshape) == 0:
        return nt_binary("mul", grad, xs, g, [])[0]
    var gs = [lshape[0], 1]
    var i = 1
    while i < len(lshape):
        gs.append(lshape[i])
        i = i + 1
    return nt_binary("mul", grad, xs, g, gs)[0]

def _fn_cross_entropy(x, target, weight, ignore_index, reduction, label_smoothing):
    x = _t_wrap(x)
    var xs = x.shape
    var wd = none
    if weight != none:
        wd = _t_flat(_t_wrap(weight).data)
    var r = nt_cross_entropy(x.data, xs, _fn_target_flat(target), reduction, ignore_index, label_smoothing, wd)
    var ls = r[1]
    var grad = r[2]
    var out = _t_new1(r[0], ls, x)
    if out.requires_grad:
        def _bw(g):
            x._acc(_fn_class_bw(x, xs, grad, ls, g))
        out._bw = _bw
    return out

def _fn_nll_loss(x, target, weight, ignore_index, reduction):
    x = _t_wrap(x)
    var xs = x.shape
    var wd = none
    if weight != none:
        wd = _t_flat(_t_wrap(weight).data)
    var r = nt_nll_loss(x.data, xs, _fn_target_flat(target), reduction, ignore_index, wd)
    var ls = r[1]
    var grad = r[2]
    var out = _t_new1(r[0], ls, x)
    if out.requires_grad:
        def _bw(g):
            x._acc(_fn_class_bw(x, xs, grad, ls, g))
        out._bw = _bw
    return out

def _fn_bce_logits(x, target, pos_weight, reduction):
    x = _t_wrap(x)
    var t = _t_wrap(target)
    var xs = x.shape
    if t.shape != xs:
        raise ValueError("target shape " + str(t.shape) + " does not match input shape " + str(xs))
    var r = nt_bce_logits(_t_flat(x.data), _t_flat(t.data), pos_weight, reduction)
    var ls = []
    var d = r[0]
    if reduction == "none":
        ls = xs
        d = _t_fix(d, xs)
    var grad = r[2]
    var out = _t_new1(d, ls, x)
    if out.requires_grad:
        def _bw(g):
            x._acc(_t_fix(nt_binary("mul", grad, [len(grad)], _t_flat(g), [len(_t_flat(g))])[0], xs))
        out._bw = _bw
    return out

def _fn_reduce(l, reduction):
    if reduction == "mean":
        return l.mean()
    if reduction == "sum":
        return l.sum()
    if reduction == "none":
        return l
    raise ValueError("reduction must be 'mean', 'sum' or 'none', got '" + str(reduction) + "'")

def _fn_check_same(a, b, what):
    if a.shape != b.shape:
        raise ValueError(what + ": input shape " + str(a.shape) + " and target shape " + str(b.shape) + " differ")

def _fn_mse(pred, target, reduction):
    var p = _t_wrap(pred)
    var t = _t_wrap(target)
    _fn_check_same(p, t, "mse_loss")
    var d = p - t
    return _fn_reduce(d * d, reduction)

def _fn_l1(pred, target, reduction):
    var p = _t_wrap(pred)
    var t = _t_wrap(target)
    _fn_check_same(p, t, "l1_loss")
    return _fn_reduce((p - t).abs(), reduction)

def _fn_smooth_l1(pred, target, reduction, beta):
    var p = _t_wrap(pred)
    var t = _t_wrap(target)
    _fn_check_same(p, t, "smooth_l1_loss")
    var d = (p - t).abs()
    var quad = d * d * (0.5 / beta)
    var lin = d - 0.5 * beta
    return _fn_reduce(_t_where(d.lt(beta).detach(), quad, lin), reduction)

def _fn_huber(pred, target, reduction, delta):
    var p = _t_wrap(pred)
    var t = _t_wrap(target)
    _fn_check_same(p, t, "huber_loss")
    var d = (p - t).abs()
    var quad = d * d * 0.5
    var lin = (d - 0.5 * delta) * delta
    return _fn_reduce(_t_where(d.le(delta).detach(), quad, lin), reduction)

# on probabilities, log clamped at -100 like PyTorch
def _fn_bce(pred, target, reduction):
    var p = _t_wrap(pred)
    var t = _t_wrap(target)
    _fn_check_same(p, t, "binary_cross_entropy")
    var lp = _t_uns("clamp_min", p.log(), -100.0)
    var lq = _t_uns("clamp_min", p.rsub(1.0).log(), -100.0)
    var l = (t * lp + t.rsub(1.0) * lq).neg()
    return _fn_reduce(l, reduction)

def _fn_kl_div(input_logp, target_p, reduction):
    var x = _t_wrap(input_logp)
    var t = _t_wrap(target_p)
    var tlog = _t_where(t.gt(0.0).detach(), t.clamp(0.000000000001, 1.0).log(), 0.0)
    var l = t * (tlog - x)
    if reduction == "batchmean":
        var n = x.shape[0]
        return l.sum() * (1.0 / n)
    return _fn_reduce(l, reduction)

def _fn_one_hot(idx, num_classes):
    var flat = _fn_target_flat(idx)
    var it = _t_wrap(idx)
    var s = it.shape
    var out = nt_full([len(flat) * num_classes], 0.0)
    var i = 0
    while i < len(flat):
        var c = int(flat[i])
        if c < 0 or c >= num_classes:
            raise IndexError("one_hot: class " + str(c) + " out of range for " + str(num_classes) + " classes")
        out[i * num_classes + c] = 1.0
        i = i + 1
    var ns = []
    i = 0
    while i < len(s):
        ns.append(s[i])
        i = i + 1
    ns.append(num_classes)
    return Tensor(out, false, ns)

def _fn_cosine_similarity(a, b, dim, eps):
    var x = _t_wrap(a)
    var y = _t_wrap(b)
    var num = (x * y).sum(dim)
    var den = (x.norm(dim) * y.norm(dim)).clamp(eps, 1e300)
    return num.div(den)

def _fn_normalize(x, dim, eps):
    var t = _t_wrap(x)
    var n = t.norm(dim, true).clamp(eps, 1e300)
    return t.div(n)

# PyTorch-named module-level functions (no clash with the flat-list natives)
def cross_entropy(input, target, weight=none, ignore_index=-100, reduction="mean", label_smoothing=0.0):
    return _fn_cross_entropy(input, target, weight, ignore_index, reduction, label_smoothing)

def nll_loss(input, target, weight=none, ignore_index=-100, reduction="mean"):
    return _fn_nll_loss(input, target, weight, ignore_index, reduction)

def l1_loss(input, target, reduction="mean"):
    return _fn_l1(input, target, reduction)

def smooth_l1_loss(input, target, reduction="mean", beta=1.0):
    return _fn_smooth_l1(input, target, reduction, beta)

def binary_cross_entropy_with_logits(input, target, pos_weight=none, reduction="mean"):
    return _fn_bce_logits(input, target, pos_weight, reduction)

# mse_loss(pred, target): differentiable mean-squared error for Tensors (and
# the round-72 Variable API, which is the same Tensor). Plain lists of numbers
# still get the flat native (nt_mse_loss), so older code calling
# mse_loss(list, list) keeps working — before, this name was redefined for
# Variables only and every list caller got none back.
def mse_loss(pred, target, reduction="mean"):
    if isinstance(pred, Tensor) or isinstance(target, Tensor):
        return _fn_mse(pred, target, reduction)
    return nt_mse_loss(pred, target)


# ── the `F` namespace (torch.nn.functional) ─────────────────────────────────
class _Functional:
    def linear(self, x, weight, bias=none):
        return _fn_linear(x, weight, bias)
    def relu(self, x):
        return _t_wrap(x).relu()
    def gelu(self, x):
        return _t_wrap(x).gelu()
    def silu(self, x):
        return _t_wrap(x).silu()
    def tanh(self, x):
        return _t_wrap(x).tanh()
    def sigmoid(self, x):
        return _t_wrap(x).sigmoid()
    def softplus(self, x):
        return _t_wrap(x).softplus()
    def mish(self, x):
        return _t_wrap(x).mish()
    def leaky_relu(self, x, negative_slope=0.01):
        return _t_wrap(x).leaky_relu(negative_slope)
    def elu(self, x, alpha=1.0):
        return _t_wrap(x).elu(alpha)
    def softmax(self, x, dim=none):
        if dim == none:
            dim = -1
        return _t_softmax(_t_wrap(x), dim, false)
    def log_softmax(self, x, dim=none):
        if dim == none:
            dim = -1
        return _t_softmax(_t_wrap(x), dim, true)
    def dropout(self, x, p=0.5, training=true):
        return _fn_dropout(x, p, training)
    def conv1d(self, x, weight, bias=none, stride=1, padding=0, dilation=1, groups=1):
        return _fn_conv1d(x, weight, bias, stride, padding, dilation, groups)
    def conv2d(self, x, weight, bias=none, stride=1, padding=0, dilation=1, groups=1):
        return _fn_conv2d(x, weight, bias, stride, padding, dilation, groups)
    def max_pool2d(self, x, kernel_size, stride=none, padding=0):
        return _fn_max_pool2d(x, kernel_size, stride, padding)
    def avg_pool2d(self, x, kernel_size, stride=none, padding=0):
        return _fn_avg_pool2d(x, kernel_size, stride, padding)
    def max_pool1d(self, x, kernel_size, stride=none, padding=0):
        return _fn_pool1d(x, kernel_size, stride, padding, true)
    def avg_pool1d(self, x, kernel_size, stride=none, padding=0):
        return _fn_pool1d(x, kernel_size, stride, padding, false)
    def batch_norm(self, x, running_mean, running_var, weight=none, bias=none, training=false, momentum=0.1, eps=0.00001):
        return _fn_batch_norm(x, running_mean, running_var, weight, bias, training, momentum, eps)
    def layer_norm(self, x, normalized_shape, weight=none, bias=none, eps=0.00001):
        var k = 1
        if type(normalized_shape) == "list":
            k = len(normalized_shape)
        return _fn_layer_norm(x, k, weight, bias, eps)
    def embedding(self, idx, weight, padding_idx=none):
        return _fn_embedding(idx, weight, padding_idx)
    def one_hot(self, idx, num_classes):
        return _fn_one_hot(idx, num_classes)
    def cross_entropy(self, x, target, weight=none, ignore_index=none, reduction="mean", label_smoothing=0.0):
        if ignore_index == none:
            ignore_index = -100
        return _fn_cross_entropy(x, target, weight, ignore_index, reduction, label_smoothing)
    def nll_loss(self, x, target, weight=none, ignore_index=none, reduction="mean"):
        if ignore_index == none:
            ignore_index = -100
        return _fn_nll_loss(x, target, weight, ignore_index, reduction)
    def mse_loss(self, x, target, reduction="mean"):
        return _fn_mse(x, target, reduction)
    def l1_loss(self, x, target, reduction="mean"):
        return _fn_l1(x, target, reduction)
    def smooth_l1_loss(self, x, target, reduction="mean", beta=1.0):
        return _fn_smooth_l1(x, target, reduction, beta)
    def huber_loss(self, x, target, reduction="mean", delta=1.0):
        return _fn_huber(x, target, reduction, delta)
    def binary_cross_entropy(self, x, target, reduction="mean"):
        return _fn_bce(x, target, reduction)
    def binary_cross_entropy_with_logits(self, x, target, pos_weight=none, reduction="mean"):
        return _fn_bce_logits(x, target, pos_weight, reduction)
    def kl_div(self, input_logp, target_p, reduction="mean"):
        return _fn_kl_div(input_logp, target_p, reduction)
    def cosine_similarity(self, a, b, dim=none, eps=0.00000001):
        if dim == none:
            dim = -1
        return _fn_cosine_similarity(a, b, dim, eps)
    def normalize(self, x, dim=none, eps=0.000000000001):
        if dim == none:
            dim = -1
        return _fn_normalize(x, dim, eps)

var F = _Functional()
