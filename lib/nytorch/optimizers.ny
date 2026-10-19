# ─── nytorch optimizers, LR schedulers and training utilities ────────────────
# Optimizers work on Parameters (Tensors with requires_grad) and read p.grad
# after loss.backward(), like torch.optim:
#
#   var opt = Adam(model.parameters(), 0.001)
#   opt.zero_grad()
#   loss.backward()
#   opt.step()
#
# The update loops are native and IN PLACE (nt_sgd_step, nt_adam_step, ...):
# a parameter's data list is updated where it is, so the model keeps the same
# tensors and a training step allocates nothing for the update.
#
# The older list API — SGD(lr).step(params, grads) returning the updated
# list, with the caller computing grads by hand — still works: construct
# with a number where the parameter list would go.
#
# (Shared logic lives in base-class methods with FIXED arguments; defaults
# are only on the concrete classes' own methods — see module.ny's note.)

import "lib/nytorch/tensor.ny"
import "lib/nytorch/module.ny"

def _o_is_legacy(params):
    return _t_isnum(params)

def _o_list_params(params):
    if isinstance(params, Module):
        return params.parameters()
    var out = []
    var i = 0
    while i < len(params):
        out.append(params[i])
        i = i + 1
    return out

def _o_grad_list(p):
    var g = p.grad
    if type(g) != "list":
        return [g]
    return g

# a 0-d parameter (bare float data) is updated through a 1-element list
def _o_data_list(p):
    if type(p.data) == "list":
        return p.data
    return [p.data]

def _o_write_back(p, lst):
    if type(p.data) != "list":
        p.data = lst[0]

def _o_zeros_like(p):
    return nt_full([len(_o_data_list(p))], 0.0)

def _o_state(n, like):
    var out = []
    var i = 0
    while i < n:
        out.append(_o_zeros_like(like[i]))
        i = i + 1
    return out

def _o_grow(state, params):
    while len(state) < len(params):
        state.append(nt_full([len(params[len(state)])], 0.0))


class Optimizer:
    def zero_grad(self):
        var i = 0
        while i < len(self.params):
            self.params[i].grad = none
            i = i + 1
    def get_lr(self):
        return self.lr
    def set_lr(self, lr):
        self.lr = lr
    def get_last_lr(self):
        return [self.lr]


class SGD(Optimizer):
    # SGD(params, lr, momentum=0, dampening=0, weight_decay=0, nesterov=false)
    # older form: SGD(lr) with step(params, grads)
    def __init__(self, params, lr=0.01, momentum=0.0, dampening=0.0, weight_decay=0.0, nesterov=false):
        self.legacy = _o_is_legacy(params)
        self.params = []
        self.lr = lr
        if self.legacy:
            self.lr = params
        else:
            self.params = _o_list_params(params)
        self.momentum = momentum
        self.dampening = dampening
        self.weight_decay = weight_decay
        self.nesterov = nesterov
        self.bufs = _o_state(len(self.params), self.params)
        self.started = []
        var i = 0
        while i < len(self.params):
            self.started.append(false)
            i = i + 1

    def step(self, params=none, grads=none):
        if params != none:
            _o_grow(self.bufs, params)
            while len(self.started) < len(params):
                self.started.append(false)
            var j = 0
            while j < len(params):
                var d = tensor(params[j])
                nt_sgd_step(d, grads[j], self.bufs[j], self.lr, self.momentum, self.dampening, self.weight_decay, self.nesterov, not self.started[j])
                self.started[j] = true
                params[j] = d
                j = j + 1
            return params
        var i = 0
        while i < len(self.params):
            var p = self.params[i]
            if p.grad != none:
                var dl = _o_data_list(p)
                nt_sgd_step(dl, _o_grad_list(p), self.bufs[i], self.lr, self.momentum, self.dampening, self.weight_decay, self.nesterov, not self.started[i])
                _o_write_back(p, dl)
                self.started[i] = true
            i = i + 1
        return none


# older name: MomentumSGD(lr, momentum), v = m*v + lr*g; p -= v
class MomentumSGD:
    def __init__(self, lr, momentum):
        self.lr = lr
        self.momentum = momentum
        self.velocity = []
    def step(self, params, grads):
        _o_grow(self.velocity, params)
        var i = 0
        while i < len(params):
            self.velocity[i] = tensor_add(tensor_scale(self.velocity[i], self.momentum), tensor_scale(grads[i], self.lr))
            params[i] = tensor_sub(params[i], self.velocity[i])
            i = i + 1
        return params


class _AdamBase(Optimizer):
    def _init_adam(self, params, lr, betas, eps, weight_decay, decoupled, legacy_b2, legacy_wd):
        self.decoupled = decoupled
        self.legacy = _o_is_legacy(params)
        self.params = []
        if self.legacy:
            # older positional form: (lr, beta1, beta2, eps[, weight_decay])
            self.lr = params
            self.beta1 = lr
            self.beta2 = legacy_b2
            self.eps = eps
            self.weight_decay = legacy_wd
        else:
            self.params = _o_list_params(params)
            self.lr = lr
            self.beta1 = 0.9
            self.beta2 = 0.999
            if betas != none:
                self.beta1 = betas[0]
                self.beta2 = betas[1]
            self.eps = eps
            self.weight_decay = weight_decay
        self.t = 0
        self.m = _o_state(len(self.params), self.params)
        self.v = _o_state(len(self.params), self.params)

    def _adam_step(self, params, grads):
        self.t = self.t + 1
        if params != none:
            _o_grow(self.m, params)
            _o_grow(self.v, params)
            var j = 0
            while j < len(params):
                var d = tensor(params[j])
                nt_adam_step(d, grads[j], self.m[j], self.v[j], self.lr, self.beta1, self.beta2, self.eps, self.weight_decay, self.t, self.decoupled)
                params[j] = d
                j = j + 1
            return params
        var i = 0
        while i < len(self.params):
            var p = self.params[i]
            if p.grad != none:
                var dl = _o_data_list(p)
                nt_adam_step(dl, _o_grad_list(p), self.m[i], self.v[i], self.lr, self.beta1, self.beta2, self.eps, self.weight_decay, self.t, self.decoupled)
                _o_write_back(p, dl)
            i = i + 1
        return none

class Adam(_AdamBase):
    # Adam(params, lr=0.001, betas=[0.9, 0.999], eps=1e-8, weight_decay=0)
    # (L2 penalty added to the gradient, as torch.optim.Adam does)
    def __init__(self, params, lr=0.001, betas=none, eps=0.00000001, weight_decay=0.0):
        var lb2 = betas
        self._init_adam(params, lr, betas, eps, weight_decay, false, lb2, 0.0)
    def step(self, params=none, grads=none):
        return self._adam_step(params, grads)

class AdamW(_AdamBase):
    # decoupled weight decay (Loshchilov & Hutter 2019)
    # older positional form: AdamW(lr, beta1, beta2, eps, weight_decay)
    def __init__(self, params, lr=0.001, betas=none, eps=0.00000001, weight_decay=0.01):
        self._init_adam(params, lr, betas, eps, weight_decay, true, betas, weight_decay)
    def step(self, params=none, grads=none):
        return self._adam_step(params, grads)


class RMSprop(Optimizer):
    # RMSprop(params, lr=0.01, alpha=0.99, eps=1e-8, weight_decay=0, momentum=0)
    # older form (RMSProp): RMSprop(lr, decay, eps)
    def __init__(self, params, lr=0.01, alpha=0.99, eps=0.00000001, weight_decay=0.0, momentum=0.0):
        self.legacy = _o_is_legacy(params)
        self.params = []
        if self.legacy:
            self.lr = params
            self.alpha = lr
            self.eps = alpha
        else:
            self.params = _o_list_params(params)
            self.lr = lr
            self.alpha = alpha
            self.eps = eps
        self.weight_decay = weight_decay
        self.momentum = momentum
        self.sq = _o_state(len(self.params), self.params)
        self.bufs = _o_state(len(self.params), self.params)

    def step(self, params=none, grads=none):
        if params != none:
            _o_grow(self.sq, params)
            _o_grow(self.bufs, params)
            var j = 0
            while j < len(params):
                var d = tensor(params[j])
                nt_rmsprop_step(d, grads[j], self.sq[j], self.lr, self.alpha, self.eps, self.weight_decay, self.momentum, self.bufs[j])
                params[j] = d
                j = j + 1
            return params
        var i = 0
        while i < len(self.params):
            var p = self.params[i]
            if p.grad != none:
                var dl = _o_data_list(p)
                nt_rmsprop_step(dl, _o_grad_list(p), self.sq[i], self.lr, self.alpha, self.eps, self.weight_decay, self.momentum, self.bufs[i])
                _o_write_back(p, dl)
            i = i + 1
        return none

def RMSProp(lr, decay, eps):
    return RMSprop(lr, decay, eps)


class Adagrad(Optimizer):
    # Adagrad(params, lr=0.01, eps=1e-10, weight_decay=0); older AdaGrad(lr, eps)
    def __init__(self, params, lr=0.01, eps=0.0000000001, weight_decay=0.0):
        self.legacy = _o_is_legacy(params)
        self.params = []
        if self.legacy:
            self.lr = params
            self.eps = lr
        else:
            self.params = _o_list_params(params)
            self.lr = lr
            self.eps = eps
        self.weight_decay = weight_decay
        self.sums = _o_state(len(self.params), self.params)

    def step(self, params=none, grads=none):
        if params != none:
            _o_grow(self.sums, params)
            var j = 0
            while j < len(params):
                var d = tensor(params[j])
                nt_adagrad_step(d, grads[j], self.sums[j], self.lr, self.eps, self.weight_decay)
                params[j] = d
                j = j + 1
            return params
        var i = 0
        while i < len(self.params):
            var p = self.params[i]
            if p.grad != none:
                var dl = _o_data_list(p)
                nt_adagrad_step(dl, _o_grad_list(p), self.sums[i], self.lr, self.eps, self.weight_decay)
                _o_write_back(p, dl)
            i = i + 1
        return none

def AdaGrad(lr, eps):
    return Adagrad(lr, eps)


# NAdam and Lion: list-based update rules (older API), step(params, grads)
class NAdam:
    def __init__(self, lr, beta1, beta2, eps):
        self.lr = lr
        self.beta1 = beta1
        self.beta2 = beta2
        self.eps = eps
        self.t = 0
        self.m = []
        self.v = []
    def step(self, params, grads):
        _o_grow(self.m, params)
        _o_grow(self.v, params)
        self.t = self.t + 1
        var b1 = self.beta1
        var b2 = self.beta2
        var i = 0
        while i < len(params):
            self.m[i] = tensor_add(tensor_scale(self.m[i], b1), tensor_scale(grads[i], 1.0 - b1))
            self.v[i] = tensor_add(tensor_scale(self.v[i], b2), tensor_scale(tensor_pow(grads[i], 2.0), 1.0 - b2))
            var v_hat = tensor_scale(self.v[i], 1.0 / (1.0 - b2 ** self.t))
            var m_nest = tensor_add(tensor_scale(grads[i], (1.0 - b1) / (1.0 - b1 ** self.t)), tensor_scale(self.m[i], b1 / (1.0 - b1 ** (self.t + 1))))
            var denom = tensor_add(tensor_sqrt(v_hat), tensor_scale(ones(len(v_hat)), self.eps))
            params[i] = tensor_sub(params[i], tensor_scale(tensor_mul(m_nest, tensor_pow(denom, -1.0)), self.lr))
            i = i + 1
        return params

class Lion:
    # Evolved Sign Momentum (Chen et al. 2023)
    def __init__(self, lr, beta1, beta2, weight_decay):
        self.lr = lr
        self.beta1 = beta1
        self.beta2 = beta2
        self.weight_decay = weight_decay
        self.m = []
    def step(self, params, grads):
        _o_grow(self.m, params)
        var b1 = self.beta1
        var b2 = self.beta2
        var i = 0
        while i < len(params):
            var interp = tensor_add(tensor_scale(self.m[i], b1), tensor_scale(grads[i], 1.0 - b1))
            var sign_up = tensor_sign(interp)
            params[i] = tensor_sub(tensor_scale(params[i], 1.0 - self.lr * self.weight_decay), tensor_scale(sign_up, self.lr))
            self.m[i] = tensor_add(tensor_scale(self.m[i], b2), tensor_scale(grads[i], 1.0 - b2))
            i = i + 1
        return params


# ── LR schedulers: they read and write optimizer.lr ─────────────────────────
class StepLR:
    # lr *= gamma every step_size calls to step()
    def __init__(self, optimizer, step_size, gamma=0.1):
        self.optimizer = optimizer
        self.step_size = step_size
        self.gamma = gamma
        self.epoch = 0
    def step(self):
        self.epoch = self.epoch + 1
        if self.epoch % self.step_size == 0:
            self.optimizer.lr = self.optimizer.lr * self.gamma
        return self.optimizer.lr
    def get_last_lr(self):
        return [self.optimizer.lr]

def LRScheduler(optimizer, step_size, gamma):
    return StepLR(optimizer, step_size, gamma)
def _LRScheduler(optimizer, step_size, gamma):
    return StepLR(optimizer, step_size, gamma)

class MultiStepLR:
    def __init__(self, optimizer, milestones, gamma=0.1):
        self.optimizer = optimizer
        self.milestones = milestones
        self.gamma = gamma
        self.epoch = 0
    def step(self):
        self.epoch = self.epoch + 1
        if self.epoch in self.milestones:
            self.optimizer.lr = self.optimizer.lr * self.gamma
        return self.optimizer.lr
    def get_last_lr(self):
        return [self.optimizer.lr]

class ExponentialLR:
    def __init__(self, optimizer, gamma):
        self.optimizer = optimizer
        self.gamma = gamma
        self.epoch = 0
    def step(self):
        self.epoch = self.epoch + 1
        self.optimizer.lr = self.optimizer.lr * self.gamma
        return self.optimizer.lr
    def get_last_lr(self):
        return [self.optimizer.lr]

class ConstantLR:
    # lr * factor for the first total_iters steps, then the base lr
    def __init__(self, optimizer, factor=0.3333333333333333, total_iters=5):
        self.optimizer = optimizer
        self.factor = factor
        self.total_iters = total_iters
        self.base_lr = optimizer.lr
        self.epoch = 0
        self.optimizer.lr = self.base_lr * factor
    def step(self):
        self.epoch = self.epoch + 1
        if self.epoch >= self.total_iters:
            self.optimizer.lr = self.base_lr
        return self.optimizer.lr
    def get_last_lr(self):
        return [self.optimizer.lr]

class LinearLR:
    # linear ramp of the factor from start_factor to end_factor over total_iters
    def __init__(self, optimizer, start_factor=0.3333333333333333, end_factor=1.0, total_iters=5):
        self.optimizer = optimizer
        self.start_factor = start_factor
        self.end_factor = end_factor
        self.total_iters = total_iters
        self.base_lr = optimizer.lr
        self.epoch = 0
        self.optimizer.lr = self.base_lr * start_factor
    def step(self):
        self.epoch = self.epoch + 1
        var e = self.epoch
        if e > self.total_iters:
            e = self.total_iters
        var f = self.start_factor + (self.end_factor - self.start_factor) * e / (1.0 * self.total_iters)
        self.optimizer.lr = self.base_lr * f
        return self.optimizer.lr
    def get_last_lr(self):
        return [self.optimizer.lr]

class LambdaLR:
    # lr = base_lr * fn(epoch)
    def __init__(self, optimizer, lr_lambda):
        self.optimizer = optimizer
        self.fn = lr_lambda
        self.base_lr = optimizer.lr
        self.epoch = 0
        self.optimizer.lr = self.base_lr * self.fn(0)
    def step(self):
        self.epoch = self.epoch + 1
        self.optimizer.lr = self.base_lr * self.fn(self.epoch)
        return self.optimizer.lr
    def get_last_lr(self):
        return [self.optimizer.lr]

class CosineAnnealingLR:
    # eta_min + (base - eta_min) * (1 + cos(pi * t / T_max)) / 2
    def __init__(self, optimizer, T_max, eta_min=0.0):
        self.optimizer = optimizer
        self.T_max = T_max
        self.lr_min = eta_min
        self.lr_max = optimizer.lr
        self.t = 0
    def step(self):
        self.t = self.t + 1
        var c = cos((3.14159265358979 * float(self.t)) / float(self.T_max))
        self.optimizer.lr = self.lr_min + 0.5 * (self.lr_max - self.lr_min) * (1.0 + c)
        return self.optimizer.lr
    def get_last_lr(self):
        return [self.optimizer.lr]

class ReduceLROnPlateau:
    # older positional form (optimizer, factor, patience, min_lr); lr *= factor
    # after `patience` non-improving step(metric) calls
    def __init__(self, optimizer, factor=0.1, patience=10, min_lr=0.0):
        self.optimizer = optimizer
        self.factor = factor
        self.patience = patience
        self.min_lr = min_lr
        self.best = 1e300
        self.counter = 0
    def step(self, metric):
        if metric < self.best:
            self.best = metric
            self.counter = 0
        else:
            self.counter = self.counter + 1
            if self.counter >= self.patience:
                var new_lr = self.optimizer.lr * self.factor
                if new_lr < self.min_lr:
                    new_lr = self.min_lr
                self.optimizer.lr = new_lr
                self.counter = 0
        return self.optimizer.lr

class WarmupCosineScheduler:
    def __init__(self, optimizer, warmup_steps, total_steps, lr_min):
        self.optimizer = optimizer
        self.warmup_steps = warmup_steps
        self.total_steps = total_steps
        self.lr_min = lr_min
        self.base_lr = optimizer.lr
        self.t = 0
    def step(self):
        self.t = self.t + 1
        if self.t <= self.warmup_steps:
            self.optimizer.lr = self.base_lr * float(self.t) / float(self.warmup_steps)
        else:
            var prog = float(self.t - self.warmup_steps) / float(self.total_steps - self.warmup_steps)
            self.optimizer.lr = self.lr_min + 0.5 * (self.base_lr - self.lr_min) * (1.0 + cos(3.14159265358979 * prog))
        return self.optimizer.lr

class CyclicLR:
    # triangular policy
    def __init__(self, optimizer, base_lr, max_lr, step_size):
        self.optimizer = optimizer
        self.base_lr = base_lr
        self.max_lr = max_lr
        self.step_size = step_size
        self.t = 0
    def step(self):
        self.t = self.t + 1
        var cycle = int(1.0 + float(self.t) / float(2 * self.step_size))
        var x = abs(float(self.t) / float(self.step_size) - 2.0 * float(cycle) + 1.0)
        var sc = 1.0 - x
        if sc < 0.0:
            sc = 0.0
        self.optimizer.lr = self.base_lr + (self.max_lr - self.base_lr) * sc
        return self.optimizer.lr


# ── gradient utilities ──────────────────────────────────────────────────────
# Scale the grads of `params` in place so their global L2 norm is at most
# max_norm; returns the norm before clipping (torch.nn.utils.clip_grad_norm_).
def clip_grad_norm_(params, max_norm):
    var ps = _o_list_params(params)
    var total = 0.0
    var i = 0
    while i < len(ps):
        if ps[i].grad != none:
            total = total + nt_sqnorm(_o_grad_list(ps[i]))
        i = i + 1
    var norm = sqrt(total)
    if norm > max_norm:
        var sc = max_norm / (norm + 0.000001)
        i = 0
        while i < len(ps):
            var g = ps[i].grad
            if g != none:
                if type(g) == "list":
                    nt_scale_(g, sc)
                else:
                    ps[i].grad = g * sc
            i = i + 1
    return norm

def clip_grad_value_(params, clip_value):
    var ps = _o_list_params(params)
    var i = 0
    while i < len(ps):
        var g = ps[i].grad
        if g != none:
            if type(g) == "list":
                ps[i].grad = nt_clamp(g, 0.0 - clip_value, clip_value)
            else:
                ps[i].grad = nt_clamp([g], 0.0 - clip_value, clip_value)[0]
        i = i + 1

class EarlyStopping:
    def __init__(self, patience, min_delta):
        self.patience = patience
        self.min_delta = min_delta
        self.best = 1e300
        self.counter = 0
        self.stop = false
    def step(self, loss):
        if loss < self.best - self.min_delta:
            self.best = loss
            self.counter = 0
        else:
            self.counter = self.counter + 1
            if self.counter >= self.patience:
                self.stop = true
        return self.stop

# older list API: clip(list_of_grad_lists) -> clipped copies
class GradientClipper:
    def __init__(self, max_norm):
        self.max_norm = max_norm
    def clip(self, grads):
        var total = 0.0
        var i = 0
        while i < len(grads):
            total = total + nt_sqnorm(grads[i])
            i = i + 1
        var gn = sqrt(total)
        if gn <= self.max_norm:
            return grads
        var sc = self.max_norm / gn
        var out = []
        i = 0
        while i < len(grads):
            out.append(tensor_scale(grads[i], sc))
            i = i + 1
        return out

class GradientAccumulator:
    def __init__(self, steps):
        self.steps = steps
        self.accum = []
        self.count = 0
    def accumulate(self, grads):
        _o_grow(self.accum, grads)
        self.count = self.count + 1
        var i = 0
        while i < len(grads):
            self.accum[i] = tensor_add(self.accum[i], grads[i])
            i = i + 1
        return self.count >= self.steps
    def get_and_reset(self):
        var sc = 1.0 / float(self.steps)
        var result = []
        var i = 0
        while i < len(self.accum):
            result.append(tensor_scale(self.accum[i], sc))
            self.accum[i] = nt_full([len(self.accum[i])], 0.0)
            i = i + 1
        self.count = 0
        return result

class EMA:
    # exponential moving average of parameter lists
    def __init__(self, decay):
        self.decay = decay
        self.shadow = []
        self.initialized = false
    def update(self, params):
        if not self.initialized:
            var i = 0
            while i < len(params):
                self.shadow.append(tensor(_t_flat(_t_wrap(params[i]).data)))
                i = i + 1
            self.initialized = true
            return self.shadow
        var j = 0
        while j < len(params):
            var d = _t_flat(_t_wrap(params[j]).data)
            self.shadow[j] = tensor_add(tensor_scale(self.shadow[j], self.decay), tensor_scale(d, 1.0 - self.decay))
            j = j + 1
        return self.shadow
    def get(self):
        return self.shadow

class ModelCheckpoint:
    # keeps a copy of the best parameters seen ("min" or "max" mode)
    def __init__(self, mode):
        self.mode = mode
        self.best_score = 1e300
        if mode == "max":
            self.best_score = -1e300
        self.best_params = []
        self.saved = false
    def update(self, score, params):
        var improved = false
        if self.mode == "min" and score < self.best_score:
            improved = true
        elif self.mode == "max" and score > self.best_score:
            improved = true
        if improved:
            self.best_score = score
            self.best_params = []
            var i = 0
            while i < len(params):
                self.best_params.append(tensor(_t_flat(_t_wrap(params[i]).data)))
                i = i + 1
            self.saved = true
        return improved
    def restore(self):
        return self.best_params
