# ─── nytorch activations ─────────────────────────────────────────────────────
# Activation modules (torch.nn names) over the Tensor autograd engine. The
# `Tensor` class that used to live here is now lib/nytorch/tensor.ny (an ND
# tensor with autograd); its elementwise methods (t.relu(), t.mish(), ...)
# return Tensors.
#
# The older *Layer names are kept as factories returning the same modules.
# Before, Tensor.mish()/.softsign()/.hardsigmoid()/.hardswish() were wrong on
# the interpreter (a bare log()/abs()/max()/min() inside a Tensor method
# resolved to Tensor.log/abs/max/min); these now run in native kernels.

import "lib/nytorch/tensor.ny"
import "lib/nytorch/module.ny"

class ReLU(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).relu()

class Sigmoid(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).sigmoid()

class Tanh(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).tanh()

class GELU(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).gelu()

class SiLU(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).silu()

class Mish(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).mish()

class Hardsigmoid(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).hardsigmoid()

class Hardswish(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).hardswish()

class Softsign(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return _t_wrap(x).softsign()

class Identity(Module):
    def __init__(self):
        super().__init__()
    def forward(self, x):
        return x

class LeakyReLU(Module):
    def __init__(self, negative_slope=0.01):
        super().__init__()
        self.negative_slope = negative_slope
    def forward(self, x):
        return _t_uns("leaky_relu", _t_wrap(x), self.negative_slope)

class ELU(Module):
    def __init__(self, alpha=1.0):
        super().__init__()
        self.alpha = alpha
    def forward(self, x):
        return _t_uns("elu", _t_wrap(x), self.alpha)

class CELU(Module):
    def __init__(self, alpha=1.0):
        super().__init__()
        self.alpha = alpha
    def forward(self, x):
        return _t_uns("celu", _t_wrap(x), self.alpha)

class Softplus(Module):
    # (1/beta) * log(1 + exp(beta * x))
    def __init__(self, beta=1.0):
        super().__init__()
        self.beta = beta
    def forward(self, x):
        var t = _t_wrap(x)
        if self.beta == 1.0:
            return t.softplus()
        return (t * self.beta).softplus() * (1.0 / self.beta)

class Hardshrink(Module):
    def __init__(self, lambd=0.5):
        super().__init__()
        self.lambd = lambd
    def forward(self, x):
        return _t_uns("hardshrink", _t_wrap(x), self.lambd)

class Softshrink(Module):
    def __init__(self, lambd=0.5):
        super().__init__()
        self.lambd = lambd
    def forward(self, x):
        return _t_uns("softshrink", _t_wrap(x), self.lambd)

class Threshold(Module):
    # y = x if x > threshold else value
    def __init__(self, threshold, value):
        super().__init__()
        self.threshold = threshold
        self.value = value
    def forward(self, x):
        var t = _t_wrap(x)
        return _t_where(t.gt(self.threshold).detach(), t, self.value)

class PReLU(Module):
    # learnable negative slope: max(0, x) + a * min(0, x)
    def __init__(self, num_parameters=1, init_value=0.25):
        super().__init__()
        self.weight = Parameter(Tensor(nt_full([num_parameters], init_value), false, [num_parameters]))
    def forward(self, x):
        var t = _t_wrap(x)
        var a = self.weight
        if self.weight.numel() > 1 and t.dim() >= 2:
            var s = [1, self.weight.numel()]
            var i = 2
            while i < t.dim():
                s.append(1)
                i = i + 1
            a = self.weight.reshape(s)
        return t.relu() - a * t.neg().relu()

class Softmax(Module):
    def __init__(self, dim=none):
        if dim == none:
            dim = -1
        super().__init__()
        self.dim = dim
    def forward(self, x):
        return _t_softmax(_t_wrap(x), self.dim, false)

class LogSoftmax(Module):
    def __init__(self, dim=none):
        if dim == none:
            dim = -1
        super().__init__()
        self.dim = dim
    def forward(self, x):
        return _t_softmax(_t_wrap(x), self.dim, true)


# ── older names ─────────────────────────────────────────────────────────────
def ReLULayer():
    return ReLU()
def SigmoidLayer():
    return Sigmoid()
def TanhLayer():
    return Tanh()
def SoftmaxLayer():
    return Softmax(-1)
def GeLULayer():
    return GELU()
def SiLULayer():
    return SiLU()
def MishLayer():
    return Mish()
def HardswishLayer():
    return Hardswish()
def SoftsignLayer():
    return Softsign()
def ELULayer(alpha):
    return ELU(alpha)
def LeakyReLULayer(alpha):
    return LeakyReLU(alpha)
def SoftplusLayer(beta):
    return Softplus(beta)
def HardshrinkLayer(lambd):
    return Hardshrink(lambd)
def SoftshrinkLayer(lambd):
    return Softshrink(lambd)
def CELULayer(alpha):
    return CELU(alpha)
def ThresholdLayer(threshold, value):
    return Threshold(threshold, value)
# PReLULayer(a) is a FIXED-slope leaky ReLU in the older API (no learnable
# parameter); PReLU above is the learnable torch.nn.PReLU.
def PReLULayer(init_val):
    return LeakyReLU(init_val)
