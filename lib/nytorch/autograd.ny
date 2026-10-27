# ─── Autograd: the round-72 Variable API, on the Tensor engine ──────────────
# Variable(data, requires_grad) is now simply a Tensor (see tensor.ny): the
# same reverse-mode engine, ND shapes and native kernels, one world. A float
# is a 0-d tensor, a flat list a 1-d one, and the methods the round-72 code
# used (add/sub/mul/dot/pow/exp/log/sum/mean/relu/sigmoid/tanh/select/
# select_row/matmul/add_bias_row/backward/.grad) keep their meaning.
#
#   var x = Variable(tensor([1.0, 2.0]), true)
#   var y = Variable(tensor([3.0, 4.0]), true)
#   var z = x.mul(y).sum()
#   z.backward()
#   x.grad     # [3.0, 4.0]
#
# The small layers below (LinearVar, LinearLayerVar, MLPVar, LinearMatVar,
# MLPMatVar) and SGDVar/AdamVar predate nn.Module and torch.optim-style
# optimizers in layers.ny/optimizers.ny; they are kept, now implemented on
# the same tensors (their seeded initialisation is unchanged).

# Combines scalar tensors into one vector (the inverse of select(i)).
import "lib/nytorch/tensor.ny"
import "lib/nytorch/module.ny"

def stack_vars(vars_list):
    return _t_stack(vars_list, 0)

# -log softmax(logits)[target] for a 1-d logits vector, differentiable
# (the native fused cross-entropy kernel, log-sum-exp stabilised).
def softmax_cross_entropy(logits, target_idx):
    return _fn_cross_entropy(logits, [target_idx], none, -100, "mean", 0.0)

def _ag_lcg_weights(n, seed, scale):
    var w = []
    var i = 0
    var s = seed
    while i < n:
        s = (s * 1103515245 + 12345) % 2147483648
        w.append((s / 2147483648.0 - 0.5) * 2.0 * scale)
        i = i + 1
    return w

# Single-output linear unit: weight . x + bias.
class LinearVar:
    def __init__(self, n_in, seed):
        self.weight = Variable(tensor(_ag_lcg_weights(n_in, seed, 1.0 / sqrt(1.0 * n_in))), true)
        self.bias = Variable(0.0, true)
    def forward(self, x):
        return self.weight.dot(x).add(self.bias)
    def parameters(self):
        return [self.weight, self.bias]

class SGDVar:
    def __init__(self, params, lr):
        self.params = params
        self.lr = lr
    def step(self):
        var i = 0
        while i < len(self.params):
            var p = self.params[i]
            if p.grad != none:
                if type(p.data) == "list":
                    nt_axpy(p.data, 0.0 - self.lr, p.grad)
                else:
                    p.data = p.data - self.lr * p.grad
            i = i + 1
    def zero_grad(self):
        var i = 0
        while i < len(self.params):
            self.params[i].grad = none
            i = i + 1

# n_out independent LinearVar units stacked into one vector output.
class LinearLayerVar:
    def __init__(self, n_in, n_out, seed):
        self.units = []
        var i = 0
        while i < n_out:
            self.units.append(LinearVar(n_in, seed + i * 97 + 13))
            i = i + 1
    def forward(self, x):
        var outs = []
        var i = 0
        while i < len(self.units):
            outs.append(self.units[i].forward(x))
            i = i + 1
        return stack_vars(outs)
    def parameters(self):
        var out = []
        var i = 0
        while i < len(self.units):
            out = out + self.units[i].parameters()
            i = i + 1
        return out

class MLPVar:
    def __init__(self, sizes, seed):
        self.layers = []
        var i = 0
        while i < len(sizes) - 1:
            self.layers.append(LinearLayerVar(sizes[i], sizes[i + 1], seed + i * 733))
            i = i + 1
    def forward(self, x):
        var h = x
        var i = 0
        while i < len(self.layers) - 1:
            h = self.layers[i].forward(h).relu()
            i = i + 1
        return self.layers[len(self.layers) - 1].forward(h)
    def parameters(self):
        var out = []
        var i = 0
        while i < len(self.layers):
            out = out + self.layers[i].parameters()
            i = i + 1
        return out

# Bias-corrected Adam on Variable.grad (the native in-place update).
class AdamVar:
    def __init__(self, params, lr, beta1, beta2, eps):
        self.params = params
        self.lr = lr
        self.beta1 = beta1
        self.beta2 = beta2
        self.eps = eps
        self.t = 0
        self.m = []
        self.v = []
        var i = 0
        while i < len(params):
            self.m.append(nt_full([len(_t_flat(params[i].data))], 0.0))
            self.v.append(nt_full([len(_t_flat(params[i].data))], 0.0))
            i = i + 1
    def zero_grad(self):
        var i = 0
        while i < len(self.params):
            self.params[i].grad = none
            i = i + 1
    def step(self):
        self.t = self.t + 1
        var i = 0
        while i < len(self.params):
            var p = self.params[i]
            if p.grad != none:
                var d = _t_flat(p.data)
                nt_adam_step(d, _t_flat(p.grad), self.m[i], self.v[i], self.lr, self.beta1, self.beta2, self.eps, 0.0, self.t, false)
                if type(p.data) != "list":
                    p.data = d[0]
            i = i + 1

# A real matrix layer: x (batch x n_in) @ W (n_in x n_out) + b.
class LinearMatVar:
    def __init__(self, n_in, n_out, seed):
        var w = _ag_lcg_weights(n_in * n_out, seed, 1.0 / sqrt(1.0 * n_in))
        self.weight = Tensor(tensor(w), true, [n_in, n_out])
        self.weight.rows = n_in
        self.weight.cols = n_out
        self.bias = Variable(zeros(n_out), true)
    def forward(self, x):
        return x.matmul(self.weight).add_bias_row(self.bias)
    def parameters(self):
        return [self.weight, self.bias]

# A list of samples (each a list of n_in numbers) as one (batch x n_in) tensor.
def batch_var(samples, requires_grad):
    return Tensor(samples, requires_grad)

class MLPMatVar:
    def __init__(self, sizes, seed):
        self.layers = []
        var i = 0
        while i < len(sizes) - 1:
            self.layers.append(LinearMatVar(sizes[i], sizes[i + 1], seed + i * 733))
            i = i + 1
    def forward(self, x):
        var h = x
        var i = 0
        while i < len(self.layers) - 1:
            h = self.layers[i].forward(h).relu()
            i = i + 1
        return self.layers[len(self.layers) - 1].forward(h)
    def parameters(self):
        var out = []
        var i = 0
        while i < len(self.layers):
            out = out + self.layers[i].parameters()
            i = i + 1
        return out
