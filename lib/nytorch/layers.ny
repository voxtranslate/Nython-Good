# ─── nytorch layers ──────────────────────────────────────────────────────────
# torch.nn layers on the Tensor autograd engine: every forward is
# differentiable and every parameter is a Parameter the Module/optimizer
# machinery finds. Weight layouts follow PyTorch (Linear.weight is
# [out_features, in_features], Conv2d.weight is [out, in/groups, kH, kW]) and
# default initialisation is PyTorch's (uniform in +-1/sqrt(fan_in)), drawn
# from the seeded generator (torch.manual_seed / manual_seed).

import "lib/nytorch/tensor.ny"
import "lib/nytorch/module.ny"
import "lib/nytorch/activations.ny"

def _l_uniform(shape, bound):
    return Parameter(Tensor(_t_fix(nt_uniform(shape, 0.0 - bound, bound), shape), false, shape))

def _l_const(shape, v):
    return Parameter(Tensor(_t_fix(nt_full(shape, v), shape), false, shape))

def _l_buffer(shape, v):
    return Tensor(_t_fix(nt_full(shape, v), shape), false, shape)

def _l_pair(v):
    if type(v) == "list":
        return v
    return [v, v]


class Linear(Module):
    # y = x W^T + b over the last dimension; x may have any leading dims.
    def __init__(self, in_features, out_features, bias=true):
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features
        var bound = 1.0 / sqrt(1.0 * in_features)
        self.weight = _l_uniform([out_features, in_features], bound)
        self.bias = none
        if bias:
            self.bias = _l_uniform([out_features], bound)
    def forward(self, x):
        return _fn_linear(x, self.weight, self.bias)
    def extra_repr(self):
        return "in_features=" + str(self.in_features) + ", out_features=" + str(self.out_features)


class Conv2d(Module):
    def __init__(self, in_channels, out_channels, kernel_size, stride=1, padding=0, dilation=1, groups=1, bias=true):
        super().__init__()
        var k = _l_pair(kernel_size)
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.kernel_size = k
        self.stride = _l_pair(stride)
        self.padding = _l_pair(padding)
        self.dilation = _l_pair(dilation)
        self.groups = groups
        if in_channels % groups != 0 or out_channels % groups != 0:
            raise ValueError("Conv2d: groups must divide in_channels and out_channels")
        var fan_in = (in_channels / groups) * k[0] * k[1]
        var bound = 1.0 / sqrt(1.0 * fan_in)
        self.weight = _l_uniform([out_channels, int(in_channels / groups), k[0], k[1]], bound)
        self.bias = none
        if bias:
            self.bias = _l_uniform([out_channels], bound)
    def forward(self, x):
        return _fn_conv2d(x, self.weight, self.bias, self.stride, self.padding, self.dilation, self.groups)
    def extra_repr(self):
        return str(self.in_channels) + ", " + str(self.out_channels) + ", kernel_size=" + str(self.kernel_size)


class Conv1d(Module):
    # input (N, C_in, L) or (C_in, L)
    def __init__(self, in_channels, out_channels, kernel_size, stride=1, padding=0, dilation=1, groups=1, bias=true):
        super().__init__()
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.kernel_size = kernel_size
        self.stride = stride
        self.padding = padding
        self.dilation = dilation
        self.groups = groups
        if in_channels % groups != 0 or out_channels % groups != 0:
            raise ValueError("Conv1d: groups must divide in_channels and out_channels")
        var fan_in = (in_channels / groups) * kernel_size
        var bound = 1.0 / sqrt(1.0 * fan_in)
        self.weight = _l_uniform([out_channels, int(in_channels / groups), kernel_size], bound)
        self.bias = none
        if bias:
            self.bias = _l_uniform([out_channels], bound)
    def forward(self, x):
        return _fn_conv1d(x, self.weight, self.bias, self.stride, self.padding, self.dilation, self.groups)
    def extra_repr(self):
        return str(self.in_channels) + ", " + str(self.out_channels) + ", kernel_size=" + str(self.kernel_size)

# The older name. Conv1D used to ignore its channel counts (one flat 1-d
# correlation with the first kernel); it is now the real multi-channel layer.
def Conv1D(in_channels, out_channels, kernel_size):
    return Conv1d(in_channels, out_channels, kernel_size)


class MaxPool2d(Module):
    def __init__(self, kernel_size, stride=none, padding=0):
        super().__init__()
        self.kernel_size = kernel_size
        self.stride = stride
        self.padding = padding
    def forward(self, x):
        return _fn_max_pool2d(x, self.kernel_size, self.stride, self.padding)

class AvgPool2d(Module):
    def __init__(self, kernel_size, stride=none, padding=0):
        super().__init__()
        self.kernel_size = kernel_size
        self.stride = stride
        self.padding = padding
    def forward(self, x):
        return _fn_avg_pool2d(x, self.kernel_size, self.stride, self.padding)

class MaxPool1d(Module):
    def __init__(self, kernel_size, stride=none, padding=0):
        super().__init__()
        self.kernel_size = kernel_size
        self.stride = stride
        self.padding = padding
    def forward(self, x):
        var t = _t_wrap(x)
        if t.dim() == 1:
            return _fn_pool1d(t.unsqueeze(0), self.kernel_size, self.stride, self.padding, true).squeeze(0)
        return _fn_pool1d(t, self.kernel_size, self.stride, self.padding, true)

class AvgPool1d(Module):
    def __init__(self, kernel_size, stride=none, padding=0):
        super().__init__()
        self.kernel_size = kernel_size
        self.stride = stride
        self.padding = padding
    def forward(self, x):
        var t = _t_wrap(x)
        if t.dim() == 1:
            return _fn_pool1d(t.unsqueeze(0), self.kernel_size, self.stride, self.padding, false).squeeze(0)
        return _fn_pool1d(t, self.kernel_size, self.stride, self.padding, false)

def MaxPool1D(kernel_size):
    return MaxPool1d(kernel_size)
def AvgPool1D(kernel_size):
    return AvgPool1d(kernel_size)


class _BatchNormBase(Module):
    def __init__(self):
        super().__init__()
    def _setup(self, num_features, eps, momentum):
        self.num_features = num_features
        self.eps = eps
        self.momentum = momentum
        self.weight = _l_const([num_features], 1.0)
        self.bias = _l_const([num_features], 0.0)
        self.register_buffer("running_mean", _l_buffer([num_features], 0.0))
        self.register_buffer("running_var", _l_buffer([num_features], 1.0))
    def _bn(self, x):
        return _fn_batch_norm(x, self.running_mean, self.running_var, self.weight, self.bias, self.training, self.momentum, self.eps)
    def extra_repr(self):
        return str(self.num_features) + ", eps=" + str(self.eps) + ", momentum=" + str(self.momentum)

class BatchNorm1d(_BatchNormBase):
    # input (N, C) or (N, C, L); running statistics are updated in training
    def __init__(self, num_features, eps=0.00001, momentum=0.1):
        super().__init__()
        self._setup(num_features, eps, momentum)
    def forward(self, x):
        var t = _t_wrap(x)
        if t.dim() != 2 and t.dim() != 3:
            raise ValueError("BatchNorm1d expects (N, C) or (N, C, L) input, got " + str(t.shape))
        return self._bn(t)

class BatchNorm2d(_BatchNormBase):
    # input (N, C, H, W)
    def __init__(self, num_features, eps=0.00001, momentum=0.1):
        super().__init__()
        self._setup(num_features, eps, momentum)
    def forward(self, x):
        var t = _t_wrap(x)
        if t.dim() != 4:
            raise ValueError("BatchNorm2d expects (N, C, H, W) input, got " + str(t.shape))
        return self._bn(t)

# The older 1-d API normalised ONE vector across its own elements with a
# per-element scale and shift (that is layer normalisation of the vector,
# whatever the name); BatchNorm keeps that contract for 1-d input and is
# batch normalisation (BatchNorm1d) for batched input.
class BatchNorm(Module):
    def __init__(self, num_features):
        super().__init__()
        self.num_features = num_features
        self.eps = 0.00001
        self.gamma = _l_const([num_features], 1.0)
        self.beta = _l_const([num_features], 0.0)
        self.register_buffer("running_mean", _l_buffer([num_features], 0.0))
        self.register_buffer("running_var", _l_buffer([num_features], 1.0))
    def forward(self, x):
        var t = _t_wrap(x)
        if t.dim() == 1:
            return _fn_layer_norm(t, 1, self.gamma, self.beta, self.eps)
        return _fn_batch_norm(t, self.running_mean, self.running_var, self.gamma, self.beta, self.training, 0.1, self.eps)


class LayerNorm(Module):
    # normalises over the last len(normalized_shape) dims
    def __init__(self, normalized_shape, eps=0.00001, elementwise_affine=true):
        super().__init__()
        var s = normalized_shape
        if type(s) != "list":
            s = [s]
        self.normalized_shape = s
        self.eps = eps
        self.weight = none
        self.bias = none
        if elementwise_affine:
            self.weight = _l_const(s, 1.0)
            self.bias = _l_const(s, 0.0)
    def forward(self, x):
        return _fn_layer_norm(x, len(self.normalized_shape), self.weight, self.bias, self.eps)
    def extra_repr(self):
        return str(self.normalized_shape) + ", eps=" + str(self.eps)


class RMSNorm(Module):
    # x / sqrt(mean(x^2 over the last dim) + eps) * weight
    def __init__(self, dim, eps=0.000001):
        super().__init__()
        self.dim = dim
        self.eps = eps
        self.weight = _l_const([dim], 1.0)
    def forward(self, x):
        var t = _t_wrap(x)
        var ms = (t * t).mean(-1, true)
        return t * (ms + self.eps).rsqrt() * self.weight


class GroupNorm(Module):
    # input (N, C, *) or a single (C,) vector
    def __init__(self, num_groups, num_channels, eps=0.00001):
        super().__init__()
        if num_channels % num_groups != 0:
            raise ValueError("GroupNorm: num_groups must divide num_channels")
        self.num_groups = num_groups
        self.num_channels = num_channels
        self.eps = eps
        self.weight = _l_const([num_channels], 1.0)
        self.bias = _l_const([num_channels], 0.0)
    def forward(self, x):
        var t = _t_wrap(x)
        var single = t.dim() == 1
        if single:
            t = t.unsqueeze(0)
        var s = t.size()
        var n = s[0]
        var rest = int(t.numel() / (n * self.num_groups))
        var g = _fn_layer_norm(t.reshape([n, self.num_groups, rest]), 1, none, none, self.eps).reshape(s)
        var shp = [1, self.num_channels]
        var i = 2
        while i < len(s):
            shp.append(1)
            i = i + 1
        var y = g * self.weight.reshape(shp) + self.bias.reshape(shp)
        if single:
            return y.squeeze(0)
        return y


class InstanceNorm(Module):
    # a single vector normalised over its own elements, per-element affine
    def __init__(self, num_features):
        super().__init__()
        self.num_features = num_features
        self.eps = 0.00001
        self.gamma = _l_const([num_features], 1.0)
        self.beta = _l_const([num_features], 0.0)
    def forward(self, x):
        return _fn_layer_norm(x, 1, self.gamma, self.beta, self.eps)


class Dropout(Module):
    # inverted dropout; identity in eval mode
    def __init__(self, p=0.5):
        super().__init__()
        if p < 0 or p > 1:
            raise ValueError("dropout probability has to be between 0 and 1, got " + str(p))
        self.p = p
    def forward(self, x):
        return _fn_dropout(x, self.p, self.training)
    def extra_repr(self):
        return "p=" + str(self.p)


class Embedding(Module):
    # indices of any shape -> shape + [embedding_dim]; weight ~ N(0, 1)
    def __init__(self, num_embeddings, embedding_dim, padding_idx=none):
        super().__init__()
        self.num_embeddings = num_embeddings
        self.embedding_dim = embedding_dim
        self.padding_idx = padding_idx
        var s = [num_embeddings, embedding_dim]
        self.weight = Parameter(Tensor(nt_randn(s), false, s))
        if padding_idx != none:
            var j = 0
            while j < embedding_dim:
                self.weight.data[padding_idx * embedding_dim + j] = 0.0
                j = j + 1
    def forward(self, idx):
        return _fn_embedding(idx, self.weight, self.padding_idx)
    def extra_repr(self):
        return str(self.num_embeddings) + ", " + str(self.embedding_dim)


class Flatten(Module):
    def __init__(self, start_dim=1, end_dim=none):
        if end_dim == none:
            end_dim = -1
        super().__init__()
        self.start_dim = start_dim
        self.end_dim = end_dim
    def forward(self, x):
        var t = _t_wrap(x)
        if t.dim() <= self.start_dim:
            return t
        return t.flatten(self.start_dim, self.end_dim)


class Unflatten(Module):
    def __init__(self, dim, sizes):
        super().__init__()
        self.dim = dim
        self.sizes = sizes
    def forward(self, x):
        var t = _t_wrap(x)
        var s = t.size()
        var d = _t_norm_dim(self.dim, len(s))
        var ns = []
        var i = 0
        while i < len(s):
            if i == d:
                var j = 0
                while j < len(self.sizes):
                    ns.append(self.sizes[j])
                    j = j + 1
            else:
                ns.append(s[i])
            i = i + 1
        return t.reshape(ns)


# ── composite blocks (older nytorch API, now real modules) ──────────────────
def _l_act(name):
    if name == "gelu":
        return GELU()
    if name == "silu":
        return SiLU()
    if name == "tanh":
        return Tanh()
    if name == "mish":
        return Mish()
    if name == "sigmoid":
        return Sigmoid()
    return ReLU()

class MLP(Module):
    # MLP([in, h1, ..., out], "relu"): Linear layers with the activation
    # between them (none after the last)
    def __init__(self, dims, activation="relu"):
        super().__init__()
        self.layers = []
        var i = 0
        while i < len(dims) - 1:
            self.layers.append(Linear(dims[i], dims[i + 1]))
            if i < len(dims) - 2:
                self.layers.append(_l_act(activation))
            i = i + 1
    def forward(self, x):
        var out = _t_wrap(x)
        var i = 0
        while i < len(self.layers):
            out = self.layers[i](out)
            i = i + 1
        return out

class ResBlock(Module):
    # LayerNorm(x + W2(act(W1 x)))
    def __init__(self, dim, activation="relu"):
        super().__init__()
        self.lin1 = Linear(dim, dim)
        self.lin2 = Linear(dim, dim)
        self.norm = LayerNorm(dim)
        self.act = _l_act(activation)
    def forward(self, x):
        var t = _t_wrap(x)
        var h = self.lin2.forward(self.act.forward(self.lin1.forward(t)))
        return self.norm.forward(t + h)

class GLU(Module):
    # first half * sigmoid(second half) over the last dim
    def __init__(self, in_dim):
        super().__init__()
        if in_dim % 2 != 0:
            raise ValueError("GLU needs an even input size, got " + str(in_dim))
        self.in_dim = in_dim
        self.half = int(in_dim / 2)
    def forward(self, x):
        var t = _t_wrap(x)
        var a = t.slice(-1, 0, self.half)
        var b = t.slice(-1, self.half, self.in_dim)
        return a * b.sigmoid()

class SwiGLU(Module):
    # W1(x) * SiLU(W2(x))  (LLaMA / PaLM feed-forward gate)
    def __init__(self, in_dim, out_dim):
        super().__init__()
        self.W1 = Linear(in_dim, out_dim)
        self.W2 = Linear(in_dim, out_dim)
    def forward(self, x):
        return self.W1.forward(x) * self.W2.forward(x).silu()
