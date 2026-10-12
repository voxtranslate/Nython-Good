# ═══════════════════════════════════════════════════════════════════════════
# NyTorch - Part 15: continuous-time, spiking, associative and cognitive models
# Classes 261-290
#
#   ODE solvers and a Neural ODE (backprop through the solver), liquid
#   networks, Kolmogorov-Arnold networks (B-spline edges), LIF spiking
#   neurons with STDP, classical and modern Hopfield memories, a neural
#   cellular automaton, a physics-informed network, a hypernetwork, a small
#   RSSM world model, self-supervised objectives (SimCLR, BYOL, masked
#   reconstruction, Barlow Twins), EWC continual learning, neuroevolution,
#   prototypical few-shot and zero-shot learners, a structural causal model,
#   program search and a global-workspace agent that wires them together.
#
# Networks are Modules on the Tensor autograd engine. Nothing returns random
# numbers in place of a computation: randomness appears only where the
# method is itself stochastic (sampling, augmentation, mutation, planning by
# random shooting), always from the seeded generator (torch.manual_seed).
# ═══════════════════════════════════════════════════════════════════════════

import "lib/nytorch/core.ny"

def _no_vec(x):
    return Tensor(_t_flat(_t_wrap(x).data))

def _no_cos(a, b):
    return _fn_cosine_similarity(_t_wrap(a), _t_wrap(b), none, 0.000000000001).item()

# a list of vectors, a flat list or a tensor -> (N, dim) rows
def _no_rows(data, dim):
    if type(data) == "list" and len(data) > 0 and not _t_isnum(data[0]):
        return _t_stack(data, 0)
    var t = _t_wrap(data)
    if t.numel() % dim != 0:
        raise ValueError("data of " + str(t.numel()) + " values is not a multiple of dim " + str(dim))
    return t.reshape([t.numel() // dim, dim])


# ── 261: ODESolver (Euler, midpoint, RK4) ──────────────────────────────────
# solve(y0, f) integrates dy/dt = f(y, t) over [0, t_span] in n_steps fixed
# steps. A list y0 is passed to f as a list (legacy flat-list dynamics); a
# Tensor stays a Tensor, so gradients flow through the whole solve.
class ODESolver:
    def __init__(self, method, dt, t_span):
        if method != "euler" and method != "rk4" and method != "midpoint":
            raise ValueError("ODESolver method must be euler, midpoint or rk4, got '" + str(method) + "'")
        if dt <= 0:
            raise ValueError("ODESolver dt must be positive")
        self.method = method
        self.dt = dt
        self.t_span = t_span
        self.trajectory = []
        self.times = []
        self.n_steps = int(t_span / dt + 0.5)
        self.as_list = false
        self.name = "ODESolver"

    def _f(self, f, y, t):
        if self.as_list:
            return _t_wrap(f(y.data, t))
        return _t_wrap(f(y, t))

    def euler_step(self, y, dy, dt):
        return _t_wrap(y) + _t_wrap(dy) * dt

    def midpoint_step(self, y, f, t, dt):
        var k1 = self._f(f, y, t)
        return y + self._f(f, y + k1 * (dt / 2.0), t + dt / 2.0) * dt

    def rk4_step(self, y, f, t, dt):
        var k1 = self._f(f, y, t)
        var k2 = self._f(f, y + k1 * (dt / 2.0), t + dt / 2.0)
        var k3 = self._f(f, y + k2 * (dt / 2.0), t + dt / 2.0)
        var k4 = self._f(f, y + k3 * dt, t + dt)
        return y + (k1 + k2 * 2.0 + k3 * 2.0 + k4) * (dt / 6.0)

    def _out(self, y):
        if self.as_list:
            return y.data
        return y

    def solve(self, y0, dynamics_fn):
        self.as_list = type(y0) == "list"
        var y = _t_wrap(y0)
        var t = 0.0
        self.trajectory = [self._out(y)]
        self.times = [0.0]
        var s = 0
        while s < self.n_steps:
            if self.method == "rk4":
                y = self.rk4_step(y, dynamics_fn, t, self.dt)
            elif self.method == "midpoint":
                y = self.midpoint_step(y, dynamics_fn, t, self.dt)
            else:
                y = self.euler_step(y, self._f(dynamics_fn, y, t), self.dt)
            t = t + self.dt
            self.trajectory.append(self._out(y))
            self.times.append(t)
            s = s + 1
        return self._out(y)

    def get_trajectory(self):
        return self.trajectory

    def get_name(self):
        return self.name


# ── 262: LiquidNeuron (leaky integrator, tanh read-out) ────────────────────
#   dV/dt = (-leak V + w_in . x + w_rec . r) / tau
class LiquidNeuron:
    def __init__(self, neuron_id, tau, leak, threshold):
        self.neuron_id = neuron_id
        self.tau = tau
        self.leak = leak
        self.threshold = threshold
        self.state = 0.0
        self.output = 0.0
        self.w_in = []
        self.w_rec = []
        self.history = []
        self.name = "LiquidNeuron"

    def update(self, inputs, recurrent, dt):
        var x = _t_flat(_t_wrap(inputs).data)
        var r = _t_flat(_t_wrap(recurrent).data)
        var i_in = 0.0
        var i = 0
        while i < min(len(x), len(self.w_in)):
            i_in = i_in + x[i] * self.w_in[i]
            i = i + 1
        var i_rec = 0.0
        i = 0
        while i < min(len(r), len(self.w_rec)):
            i_rec = i_rec + r[i] * self.w_rec[i]
            i = i + 1
        var dV = (0.0 - self.leak * self.state + i_in + i_rec) / self.tau
        self.state = self.state + dt * dV
        self.output = tanh(self.state)
        self.history.append(self.state)
        return self.output

    def reset(self):
        self.state = 0.0
        self.output = 0.0

    def get_name(self):
        return self.name


# ── 263: LiquidNeuralNetwork (a reservoir of liquid neurons + linear read-out)
class LiquidNeuralNetwork:
    def __init__(self, input_dim, n_neurons, output_dim, dt, sparsity):
        self.input_dim = input_dim
        self.n_neurons = n_neurons
        self.output_dim = output_dim
        self.dt = dt
        self.sparsity = sparsity
        var w_in = nt_normal(n_neurons * input_dim, 0.0, 1.0 / sqrt(1.0 * input_dim))
        var w_rec = nt_normal(n_neurons * n_neurons, 0.0, 1.0 / sqrt(1.0 * n_neurons))
        var keep = nt_rand(n_neurons * n_neurons)
        var i = 0
        while i < n_neurons * n_neurons:
            if keep[i] < sparsity:
                w_rec[i] = 0.0
            i = i + 1
        self.W_in = w_in
        self.W_rec = w_rec
        self.W_out = nt_normal(output_dim * n_neurons, 0.0, 1.0 / sqrt(1.0 * n_neurons))
        self.readout_b = nt_full([output_dim], 0.0)
        self.state = nt_full([n_neurons], 0.0)
        self.neurons = []
        i = 0
        while i < n_neurons:
            var neuron = LiquidNeuron(i, 1.0 + float(i % 5) * 0.5, 0.1, 1.0)
            neuron.w_in = w_in[i * input_dim:(i + 1) * input_dim]
            neuron.w_rec = w_rec[i * n_neurons:(i + 1) * n_neurons]
            self.neurons.append(neuron)
            i = i + 1
        self.name = "LiquidNeuralNetwork"

    # one time step: the neuron outputs (state) then y = W_out state + b
    def step(self, x):
        var prev = []
        var i = 0
        while i < self.n_neurons:
            prev.append(self.neurons[i].output)
            i = i + 1
        var new_state = []
        i = 0
        while i < self.n_neurons:
            new_state.append(self.neurons[i].update(x, prev, self.dt))
            i = i + 1
        self.state = new_state
        return nt_binary("add", nt_matmul(self.W_out, [self.output_dim, self.n_neurons], new_state, [self.n_neurons])[0], [self.output_dim], self.readout_b, [self.output_dim])[0]

    def run_sequence(self, xs):
        var outs = []
        var i = 0
        while i < len(xs):
            outs.append(self.step(xs[i]))
            i = i + 1
        return outs

    def reset(self):
        var i = 0
        while i < len(self.neurons):
            self.neurons[i].reset()
            i = i + 1
        self.state = nt_full([self.n_neurons], 0.0)

    def get_name(self):
        return self.name


# ── 264: NeuralODE (Chen et al. 2018) ──────────────────────────────────────
# dh/dt = f(h, t) = W2 tanh(W1 h + b1) + b2, integrated by the solver; the
# forward pass is differentiable end to end (backprop through the solver).
class NeuralODE(Module):
    def __init__(self, hidden_dim, solver_method, dt, t_end):
        super().__init__()
        self.hidden_dim = hidden_dim
        self.solver_method = solver_method
        self.dt = dt
        self.t_end = t_end
        self.f1 = Linear(hidden_dim, hidden_dim)
        self.f2 = Linear(hidden_dim, hidden_dim)
        self.solver = ODESolver(solver_method, dt, t_end)
        self.trajectories = []
        self.name = "NeuralODE"

    def dynamics(self, h, t):
        return self.f2.forward(self.f1.forward(_t_wrap(h)).tanh())

    def forward(self, h0):
        var model = self
        var fn = lambda h, t: model.dynamics(h, t)
        var hT = self.solver.solve(_t_wrap(h0), fn)
        self.trajectories = self.solver.get_trajectory()
        return hT

    def n_steps(self):
        return self.solver.n_steps

    def get_name(self):
        return self.name


# uniform knots on [-1, 1] with `order` extra knots each side
def _kan_knots(grid_size, order):
    var h = 2.0 / float(grid_size)
    var t = []
    var j = 0 - order
    while j <= grid_size + order:
        t.append(-1.0 + float(j) * h)
        j = j + 1
    return t

# Cox-de Boor: the grid_size + order B-spline basis values at scalar x
def _kan_basis_scalar(x, knots, order):
    var xc = max(-1.0, min(0.999999999, x))
    var B = []
    var i = 0
    while i < len(knots) - 1:
        if xc >= knots[i] and xc < knots[i + 1]:
            B.append(1.0)
        else:
            B.append(0.0)
        i = i + 1
    var p = 1
    while p <= order:
        var nb = []
        i = 0
        while i < len(B) - 1:
            var left = (xc - knots[i]) / (knots[i + p] - knots[i]) * B[i]
            var right = (knots[i + p + 1] - xc) / (knots[i + p + 1] - knots[i + 1]) * B[i + 1]
            nb.append(left + right)
            i = i + 1
        B = nb
        p = p + 1
    return B


# ── 265: KANBasisFunction: one learnable edge function
#   phi(x) = sum_k c_k B_k(x) + 0.1 x, B_k the order-`order` B-splines on a
#   uniform grid of grid_size intervals over [-1, 1] (x is clamped to it).
class KANBasisFunction:
    def __init__(self, grid_size, order):
        self.grid_size = grid_size
        self.order = order
        self.knots = _kan_knots(grid_size, order)
        self.grid = linspace(-1.0, 1.0, grid_size + 1)
        self.coefs = nt_normal(grid_size + order, 0.0, 0.1)
        self.name = "KANBasisFunction"

    def b_spline_basis(self, x, k):
        return _kan_basis_scalar(x, self.knots, self.order)[k]

    def forward(self, x):
        var B = _kan_basis_scalar(x, self.knots, self.order)
        var r = 0.0
        var k = 0
        while k < len(B):
            r = r + self.coefs[k] * B[k]
            k = k + 1
        return r + 0.1 * x

    def get_name(self):
        return self.name


# ── 266: KANLayer (Liu et al. 2024) ────────────────────────────────────────
# y_j = sum_i [ sum_k c_jik B_k(x_i) + w_ji silu(x_i) ]: a learnable spline
# on every edge plus a SiLU base branch. Differentiable in x and in c, w.
class KANLayer(Module):
    def __init__(self, in_dim, out_dim, grid_size, order):
        super().__init__()
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.grid_size = grid_size
        self.order = order
        self.n_basis = grid_size + order
        self.knots = _kan_knots(grid_size, order)
        var cs = [out_dim, in_dim * self.n_basis]
        self.coefs = Parameter(Tensor(nt_normal(cs, 0.0, 0.1), false, cs))
        self.base_w = _l_uniform([out_dim, in_dim], 1.0 / sqrt(1.0 * in_dim))
        self.name = "KANLayer"

    # (in_dim,) -> the (in_dim, n_basis) spline basis, by Cox-de Boor
    def basis(self, x):
        var X = x.clamp(-1.0, 0.999999999).unsqueeze(1)
        var nk = len(self.knots)
        # order 0: indicator of the knot interval (zero gradient)
        var ind = []
        var xs = _t_flat(X.data)
        var i = 0
        while i < self.in_dim:
            var j = 0
            while j < nk - 1:
                if xs[i] >= self.knots[j] and xs[i] < self.knots[j + 1]:
                    ind.append(1.0)
                else:
                    ind.append(0.0)
                j = j + 1
            i = i + 1
        var B = Tensor(ind, false, [self.in_dim, nk - 1])
        var h = 2.0 / float(self.grid_size)
        var p = 1
        while p <= self.order:
            var n = nk - 1 - p
            var tl = Tensor(self.knots[0:n], false, [1, n])
            var tr = Tensor(self.knots[p + 1:p + 1 + n], false, [1, n])
            var left = (X - tl) * (1.0 / (float(p) * h))
            var right = (tr - X) * (1.0 / (float(p) * h))
            B = left * B.slice(1, 0, n) + right * B.slice(1, 1, n + 1)
            p = p + 1
        return B

    def forward(self, x):
        var t = _t_wrap(x)
        if t.numel() != self.in_dim:
            raise ValueError("KANLayer expects " + str(self.in_dim) + " inputs, got " + str(t.numel()))
        t = t.reshape([self.in_dim])
        var B = self.basis(t).reshape([self.in_dim * self.n_basis])
        return self.coefs.mv(B) + self.base_w.mv(t.silu())

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 267: KolmogorovArnoldNetwork ───────────────────────────────────────────
class KolmogorovArnoldNetwork(Module):
    def __init__(self, layer_sizes, grid_size, order):
        super().__init__()
        self.layer_sizes = layer_sizes
        self.grid_size = grid_size
        self.order = order
        self.layers = []
        var i = 0
        while i < len(layer_sizes) - 1:
            self.layers.append(KANLayer(layer_sizes[i], layer_sizes[i + 1], grid_size, order))
            i = i + 1
        self.name = "KolmogorovArnoldNetwork"

    def forward(self, x):
        var h = _t_wrap(x)
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h)
            i = i + 1
        return h

    def total_params(self):
        return self.num_parameters()

    def symbolic_formula(self, layer_idx):
        var layer = self.layers[layer_idx % len(self.layers)]
        return "KAN layer " + str(layer_idx) + ": " + str(layer.in_dim) + " -> " + str(layer.out_dim) + ", order-" + str(layer.order) + " B-splines on " + str(layer.grid_size) + " intervals + SiLU base per edge"

    def get_name(self):
        return self.name


# ── 268: SpikingNeuron (leaky integrate-and-fire with a synaptic current) ──
class SpikingNeuron:
    def __init__(self, neuron_id, tau_m, tau_s, v_thresh, v_reset, v_rest):
        self.neuron_id = neuron_id
        self.tau_m = tau_m
        self.tau_s = tau_s
        self.v_thresh = v_thresh
        self.v_reset = v_reset
        self.v_rest = v_rest
        self.v = v_rest
        self.i_syn = 0.0
        self.last_spike_t = -1e9
        self.spike_times = []
        self.refractory_period = 2.0
        self.name = "SpikingNeuron"

    def update(self, i_ext, t, dt):
        if (t - self.last_spike_t) < self.refractory_period:
            self.v = self.v_reset
            self.i_syn = self.i_syn * exp(0.0 - dt / self.tau_s)
            return 0
        self.i_syn = self.i_syn * exp(0.0 - dt / self.tau_s) + i_ext
        self.v = self.v + dt * (self.v_rest - self.v + self.i_syn) / self.tau_m
        if self.v >= self.v_thresh:
            self.v = self.v_reset
            self.last_spike_t = t
            self.spike_times.append(t)
            return 1
        return 0

    # spikes per unit time over the last `window` before the last spike
    def firing_rate(self, window):
        var recent = 0
        var i = 0
        while i < len(self.spike_times):
            if self.spike_times[i] > self.last_spike_t - window:
                recent = recent + 1
            i = i + 1
        return float(recent) / window

    def reset(self):
        self.v = self.v_rest
        self.i_syn = 0.0
        self.last_spike_t = -1e9
        self.spike_times = []

    def get_name(self):
        return self.name


# ── 269: SpikingLayer (LIF neurons, recurrent weights trained by STDP) ─────
class SpikingLayer:
    def __init__(self, n_neurons, tau_m, v_thresh, dt):
        self.n_neurons = n_neurons
        self.tau_m = tau_m
        self.v_thresh = v_thresh
        self.dt = dt
        self.neurons = []
        var i = 0
        while i < n_neurons:
            self.neurons.append(SpikingNeuron(i, tau_m * (1.0 + float(i % 3) * 0.1), tau_m * 0.2, v_thresh, -65.0, -70.0))
            i = i + 1
        self.W = nt_normal(n_neurons * n_neurons, 0.0, 0.1)
        self.trace_pre = nt_full([n_neurons], 0.0)
        self.trace_post = nt_full([n_neurons], 0.0)
        self.tau_trace = 20.0
        self.name = "SpikingLayer"

    def forward(self, input_currents, t):
        var cur = _t_flat(_t_wrap(input_currents).data)
        var spikes = []
        var i = 0
        while i < self.n_neurons:
            var i_ext = 0.0
            if i < len(cur):
                i_ext = cur[i]
            spikes.append(float(self.neurons[i].update(i_ext, t, self.dt)))
            i = i + 1
        # exponentially decaying spike traces (pre = post: recurrent weights)
        var d = exp(0.0 - self.dt / self.tau_trace)
        i = 0
        while i < self.n_neurons:
            self.trace_pre[i] = self.trace_pre[i] * d + spikes[i]
            self.trace_post[i] = self.trace_post[i] * d + spikes[i]
            i = i + 1
        return spikes

    # pair-based STDP: dw_ij = lr+ post_i trace_pre_j - lr- pre_j trace_post_i
    def stdp_update(self, pre_spikes, post_spikes, lr_plus, lr_minus):
        var n = self.n_neurons
        var i = 0
        while i < n and i < len(post_spikes):
            var j = 0
            while j < n and j < len(pre_spikes):
                self.W[i * n + j] = self.W[i * n + j] + lr_plus * post_spikes[i] * self.trace_pre[j] - lr_minus * pre_spikes[j] * self.trace_post[i]
                j = j + 1
            i = i + 1

    def avg_firing_rate(self, window):
        var total = 0.0
        var i = 0
        while i < self.n_neurons:
            total = total + self.neurons[i].firing_rate(window)
            i = i + 1
        return total / float(self.n_neurons)

    def get_name(self):
        return self.name


# ── 270: SpikingNeuralNetwork ──────────────────────────────────────────────
# Rate coding (Bernoulli spikes with p = |x| max_rate dt / 1000, dt in ms,
# max_rate in Hz) into feed-forward LIF layers; layer l receives
# gain * W_l spikes_(l-1). The output is each output neuron's spike rate.
class SpikingNeuralNetwork:
    def __init__(self, layer_sizes, tau_m, v_thresh, dt, n_time_steps):
        self.layer_sizes = layer_sizes
        self.tau_m = tau_m
        self.v_thresh = v_thresh
        self.dt = dt
        self.n_time_steps = n_time_steps
        self.gain = 40.0
        self.layers = []
        self.weights = []
        var i = 0
        while i < len(layer_sizes):
            self.layers.append(SpikingLayer(layer_sizes[i], tau_m, v_thresh, dt))
            if i > 0:
                self.weights.append(nt_uniform(layer_sizes[i] * layer_sizes[i - 1], 0.0, 1.0))
            i = i + 1
        self.spike_counts = []
        self.name = "SpikingNeuralNetwork"

    def rate_encode(self, x, max_rate):
        var v = _t_flat(_t_wrap(x).data)
        var u = nt_rand(len(v))
        var out = []
        var i = 0
        while i < len(v):
            if u[i] < abs(v[i]) * max_rate * self.dt / 1000.0:
                out.append(1.0)
            else:
                out.append(0.0)
            i = i + 1
        return out

    def forward(self, x):
        var n_out = self.layer_sizes[len(self.layer_sizes) - 1]
        var counts = nt_full([n_out], 0.0)
        self.spike_counts = []
        var step = 0
        while step < self.n_time_steps:
            var t = float(step) * self.dt
            var spikes = self.layers[0].forward(nt_binary("mul", self.rate_encode(x, 100.0), [len(self.rate_encode(x, 0.0))], self.gain, [])[0], t)
            var l = 1
            while l < len(self.layers):
                var n_in = self.layer_sizes[l - 1]
                var cur = nt_matmul(self.weights[l - 1], [self.layer_sizes[l], n_in], spikes, [n_in])[0]
                spikes = self.layers[l].forward(nt_binary("mul", cur, [len(cur)], self.gain, [])[0], t)
                l = l + 1
            self.spike_counts.append(spikes)
            counts = nt_binary("add", counts, [n_out], spikes, [n_out])[0]
            step = step + 1
        return nt_binary("mul", counts, [n_out], 1.0 / float(self.n_time_steps), [])[0]

    # spikes emitted by the output layer per time step, times 1 pJ... as a
    # relative energy figure (spike count x 0.001)
    def energy_estimate(self):
        var total = 0.0
        var i = 0
        while i < len(self.spike_counts):
            var s = self.spike_counts[i]
            var j = 0
            while j < len(s):
                total = total + s[j]
                j = j + 1
            i = i + 1
        return total * 0.001

    def get_name(self):
        return self.name


# ── 271: HopfieldNetwork (Hopfield 1982, Hebbian storage) ──────────────────
class HopfieldNetwork:
    def __init__(self, n_units, learning_rule):
        if learning_rule != "hebbian":
            raise ValueError("HopfieldNetwork supports the 'hebbian' rule, got '" + str(learning_rule) + "'")
        self.n_units = n_units
        self.learning_rule = learning_rule
        self.W = nt_full([n_units * n_units], 0.0)
        self.stored_patterns = []
        self.energy_history = []
        self.name = "HopfieldNetwork"

    # W += p p^T / n with a zero diagonal (p in {-1, +1}^n)
    def store(self, pattern):
        var p = _t_flat(_t_wrap(pattern).data)
        var n = self.n_units
        if len(p) != n:
            raise ValueError("pattern must have " + str(n) + " units, got " + str(len(p)))
        self.stored_patterns.append(p)
        var i = 0
        while i < n:
            var j = 0
            while j < n:
                if i != j:
                    self.W[i * n + j] = self.W[i * n + j] + p[i] * p[j] / float(n)
                j = j + 1
            i = i + 1

    # E = -1/2 s^T W s
    def energy(self, state):
        var s = _t_flat(_t_wrap(state).data)
        var n = self.n_units
        var Ws = nt_matmul(self.W, [n, n], s, [n])[0]
        var e = 0.0
        var i = 0
        while i < n:
            e = e - 0.5 * s[i] * Ws[i]
            i = i + 1
        return e

    def update_unit(self, state, i):
        var n = self.n_units
        var h = 0.0
        var j = 0
        while j < n:
            h = h + self.W[i * n + j] * state[j]
            j = j + 1
        if h >= 0.0:
            return 1.0
        return -1.0

    # asynchronous updates in index order; each sweep lowers the energy
    def recall(self, probe, n_iters):
        var state = _t_flat(_t_wrap(probe).data)[:]
        var it = 0
        while it < n_iters:
            var i = 0
            while i < self.n_units:
                state[i] = self.update_unit(state, i)
                i = i + 1
            self.energy_history.append(self.energy(state))
            it = it + 1
        return state

    def capacity(self):
        return int(float(self.n_units) * 0.138)

    def get_name(self):
        return self.name


# ── 272: ModernHopfieldNetwork (Ramsauer et al. 2020) ──────────────────────
#   E(xi) = -1/beta log sum_i exp(beta x_i . xi) + 1/2 xi . xi
#   update: xi <- X^T softmax(beta X xi)   (one step retrieves, = attention)
class ModernHopfieldNetwork:
    def __init__(self, n_stored, pattern_dim, beta):
        self.n_stored = n_stored
        self.pattern_dim = pattern_dim
        self.beta = beta
        self.stored = []
        self.query_history = []
        self.name = "ModernHopfieldNetwork"

    def store(self, pattern):
        var p = _t_flat(_t_wrap(pattern).data)
        if len(p) != self.pattern_dim:
            raise ValueError("pattern must have " + str(self.pattern_dim) + " values, got " + str(len(p)))
        if len(self.stored) >= self.n_stored:
            raise ValueError("memory full (" + str(self.n_stored) + " patterns)")
        self.stored.append(p)

    def _X(self):
        return Tensor(self.stored)

    def energy(self, query):
        if len(self.stored) == 0:
            return 0.0
        var q = _no_vec(query)
        var lse = (self._X().mv(q) * self.beta).logsumexp().item()
        return 0.0 - lse / self.beta + 0.5 * q.dot(q).item()

    def retrieve(self, query, n_iters):
        var xi = _no_vec(query)
        if len(self.stored) == 0:
            return xi.data
        var X = self._X()
        var it = 0
        while it < n_iters:
            xi = X.t().mv((X.mv(xi) * self.beta).softmax(0))
            it = it + 1
        self.query_history.append(xi.data)
        return xi.data

    def capacity(self):
        # exponential in the dimension (Ramsauer et al.): ~ 2^(d/2) patterns
        return int(2.0 ** (float(self.pattern_dim) / 2.0))

    def get_name(self):
        return self.name


# ── 273: NeuralCellularAutomaton (Mordvintsev et al. 2020), on a 1-d grid ──
# Each cell perceives [state, gradient, laplacian] of its neighbourhood; a
# shared MLP proposes ds, applied with probability update_prob (stochastic
# update); cells whose neighbourhood has no live cell (channel 0 > 0.1) die.
class NeuralCellularAutomaton(Module):
    def __init__(self, grid_size, n_channels, update_prob):
        super().__init__()
        self.grid_size = grid_size
        self.n_channels = n_channels
        self.update_prob = update_prob
        self.grid = nt_full([grid_size * n_channels], 0.0)
        self.step_count = 0
        self.fc1 = Linear(3 * n_channels, 32)
        self.fc2 = Linear(32, n_channels)
        self.name = "NeuralCellularAutomaton"

    def seed(self, center_value):
        var c = self.grid_size // 2
        var k = 0
        while k < self.n_channels:
            self.grid[c * self.n_channels + k] = center_value
            k = k + 1

    def _cell(self, i):
        var C = self.n_channels
        if i < 0 or i >= self.grid_size:
            return nt_full([C], 0.0)
        return self.grid[i * C:(i + 1) * C]

    # [state, (right - left) / 2, left - 2 state + right]   (3 * n_channels)
    def perceive(self, cell_idx):
        var s = self._cell(cell_idx)
        var l = self._cell(cell_idx - 1)
        var r = self._cell(cell_idx + 1)
        var C = self.n_channels
        var g = []
        var lap = []
        var k = 0
        while k < C:
            g.append((r[k] - l[k]) * 0.5)
            lap.append(l[k] - 2.0 * s[k] + r[k])
            k = k + 1
        return s + g + lap

    def _delta(self, perception):
        return self.fc2.forward(self.fc1.forward(Tensor(perception)).relu()).data

    def _alive(self, i):
        var j = i - 1
        while j <= i + 1:
            if j >= 0 and j < self.grid_size and self.grid[j * self.n_channels] > 0.1:
                return true
            j = j + 1
        return false

    def update_cell(self, cell_idx, step):
        if nt_rand(1)[0] > self.update_prob:
            return false
        var ds = self._delta(self.perceive(cell_idx))
        var C = self.n_channels
        var k = 0
        while k < C:
            self.grid[cell_idx * C + k] = self.grid[cell_idx * C + k] + ds[k]
            k = k + 1
        return true

    # synchronous step: every cell perceives the same grid
    def step(self):
        var C = self.n_channels
        var perc = []
        var i = 0
        while i < self.grid_size:
            perc.append(self.perceive(i))
            i = i + 1
        var mask = nt_rand(self.grid_size)
        var nxt = self.grid[:]
        with no_grad():
            i = 0
            while i < self.grid_size:
                if mask[i] <= self.update_prob:
                    var ds = self._delta(perc[i])
                    var k = 0
                    while k < C:
                        nxt[i * C + k] = nxt[i * C + k] + ds[k]
                        k = k + 1
                i = i + 1
        var pre_alive = []
        i = 0
        while i < self.grid_size:
            pre_alive.append(self._alive(i))
            i = i + 1
        self.grid = nxt
        i = 0
        while i < self.grid_size:
            if not (pre_alive[i] and self._alive(i)):
                var k2 = 0
                while k2 < C:
                    self.grid[i * C + k2] = 0.0
                    k2 = k2 + 1
            i = i + 1
        self.step_count = self.step_count + 1

    def run(self, n_steps):
        var s = 0
        while s < n_steps:
            self.step()
            s = s + 1

    def get_alive_cells(self):
        var alive = 0
        var i = 0
        while i < self.grid_size:
            if abs(self.grid[i * self.n_channels]) > 0.1:
                alive = alive + 1
            i = i + 1
        return alive

    def get_name(self):
        return self.name


# ── 274: PhysicsInformedNN (Raissi et al. 2019) ────────────────────────────
# u(x, t) is a tanh MLP; the PDE residual uses central finite differences of
# the network (step 1e-3), which stay differentiable in the weights:
#   heat     u_t - alpha u_xx          wave  u_tt - c^2 u_xx
#   burgers  u_t + u u_x - nu u_xx
class PhysicsInformedNN(Module):
    def __init__(self, input_dim, hidden_dim, n_layers, pde_name, pde_coeffs):
        super().__init__()
        if pde_name != "heat" and pde_name != "wave" and pde_name != "burgers":
            raise ValueError("PhysicsInformedNN pde must be heat, wave or burgers, got '" + str(pde_name) + "'")
        if input_dim != 2:
            raise ValueError("PhysicsInformedNN takes (x, t): input_dim must be 2")
        self.input_dim = input_dim
        self.hidden_dim = hidden_dim
        self.n_layers = n_layers
        self.pde_name = pde_name
        self.pde_coeffs = pde_coeffs
        self.layers = []
        var d = input_dim
        var i = 0
        while i < n_layers:
            self.layers.append(Linear(d, hidden_dim))
            d = hidden_dim
            i = i + 1
        self.out = Linear(d, 1)
        self.collocation_points = []
        self.boundary_points = []
        self.data_loss_history = []
        self.pde_loss_history = []
        self.opt = none
        self.name = "PhysicsInformedNN"

    def _coef(self, key, default):
        if key in self.pde_coeffs:
            return self.pde_coeffs[key]
        return default

    def u(self, x, t):
        var h = Tensor([float(x), float(t)])
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h).tanh()
            i = i + 1
        return self.out.forward(h).sum()

    def network_forward(self, x):
        var p = _t_flat(_t_wrap(x).data)
        var v = 0.0
        with no_grad():
            v = self.u(p[0], p[1]).item()
        return v

    def residual_tensor(self, x, t):
        var e = 0.001
        var u0 = self.u(x, t)
        var uxx = (self.u(x + e, t) - u0 * 2.0 + self.u(x - e, t)) * (1.0 / (e * e))
        if self.pde_name == "heat":
            var ut = (self.u(x, t + e) - self.u(x, t - e)) * (0.5 / e)
            return ut - uxx * self._coef("alpha", 0.01)
        if self.pde_name == "wave":
            var utt = (self.u(x, t + e) - u0 * 2.0 + self.u(x, t - e)) * (1.0 / (e * e))
            var c = self._coef("c", 1.0)
            return utt - uxx * (c * c)
        var ut2 = (self.u(x, t + e) - self.u(x, t - e)) * (0.5 / e)
        var ux = (self.u(x + e, t) - self.u(x - e, t)) * (0.5 / e)
        return ut2 + u0 * ux - uxx * self._coef("nu", 0.01)

    def pde_residual(self, x, t):
        var r = 0.0
        with no_grad():
            r = self.residual_tensor(x, t).item()
        return r

    def add_collocation_point(self, x, t):
        self.collocation_points.append([x, t])

    def loss_tensors(self, data_pts, data_vals):
        var data_loss = none
        var i = 0
        while i < len(data_pts):
            var p = _t_flat(_t_wrap(data_pts[i]).data)
            var d = (self.u(p[0], p[1]) - data_vals[i]).square()
            if data_loss == none:
                data_loss = d
            else:
                data_loss = data_loss + d
            i = i + 1
        var pde_loss = none
        i = 0
        while i < len(self.collocation_points):
            var c = self.collocation_points[i]
            var r = self.residual_tensor(c[0], c[1]).square()
            if pde_loss == none:
                pde_loss = r
            else:
                pde_loss = pde_loss + r
            i = i + 1
        if data_loss == none:
            data_loss = Tensor(0.0)
        if pde_loss == none:
            pde_loss = Tensor(0.0)
        return [data_loss, pde_loss]

    def compute_loss(self, data_pts, data_vals):
        if len(data_pts) != len(data_vals):
            raise ValueError("data_pts and data_vals differ in length")
        var ls = none
        with no_grad():
            ls = self.loss_tensors(data_pts, data_vals)
        var d = ls[0].item()
        var p = ls[1].item()
        self.data_loss_history.append(d)
        self.pde_loss_history.append(p)
        return {"data": d, "pde": p, "total": d + p}

    # one Adam step on data loss + PDE residual loss
    def train_step(self, data_pts, data_vals, lr):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        self.opt.zero_grad()
        var ls = self.loss_tensors(data_pts, data_vals)
        var total = ls[0] + ls[1]
        total.backward()
        self.opt.step()
        return {"data": ls[0].item(), "pde": ls[1].item(), "total": total.item()}

    def get_name(self):
        return self.name


# ── 275: HyperNetwork (Ha et al. 2016) ─────────────────────────────────────
# A context vector (embed_dim) generates the target layer's weights:
#   W = reshape(L2 relu(L1 context)) (target_out x target_in);  y = W x
class HyperNetwork(Module):
    def __init__(self, hyper_dim, target_in, target_out, embed_dim):
        super().__init__()
        self.hyper_dim = hyper_dim
        self.target_in = target_in
        self.target_out = target_out
        self.embed_dim = embed_dim
        self.l1 = Linear(embed_dim, hyper_dim)
        self.l2 = Linear(hyper_dim, target_in * target_out)
        self.opt = none
        self.name = "HyperNetwork"

    def generate_weights(self, context):
        return self.l2.forward(self.l1.forward(_no_vec(context)).relu())

    def forward_target(self, x, context):
        var W = self.generate_weights(context).reshape([self.target_out, self.target_in])
        return W.mv(_no_vec(x))

    # one Adam step on mean((mean(y_i) - target_i)^2) over the examples
    def adapt(self, contexts, xs, ys, lr):
        var n = min(len(contexts), len(xs))
        if n == 0 or len(ys) < n:
            raise ValueError("adapt needs matching contexts, xs and ys")
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        self.opt.set_lr(lr)
        self.opt.zero_grad()
        var total = none
        var i = 0
        while i < n:
            var l = (self.forward_target(xs[i], contexts[i]).mean() - ys[i]).square()
            if total == none:
                total = l
            else:
                total = total + l
            i = i + 1
        var loss = total * (1.0 / float(n))
        loss.backward()
        self.opt.step()
        return loss.item()

    def get_name(self):
        return self.name


# ── 276: WorldModel (a small RSSM, after Hafner et al. 2019) ───────────────
#   encoder  obs -> q(z) = N(mu, sigma)      (sampled in train mode, mu in eval)
#   dynamics h' = tanh(W [z, a] + U h),  z' = prior(h')
#   heads    decoder(z) -> obs, reward(h), continue(h) = sigmoid(.)
class WorldModel(Module):
    def __init__(self, obs_dim, action_dim, latent_dim, hidden_dim):
        super().__init__()
        self.obs_dim = obs_dim
        self.action_dim = action_dim
        self.latent_dim = latent_dim
        self.hidden_dim = hidden_dim
        self.enc = Linear(obs_dim, 2 * latent_dim)
        self.rssm_in = Linear(latent_dim + action_dim, hidden_dim)
        self.rssm_rec = Linear(hidden_dim, hidden_dim, false)
        self.prior = Linear(hidden_dim, latent_dim)
        self.dec = Linear(latent_dim, obs_dim)
        self.reward_head = Linear(hidden_dim, 1)
        self.continue_head = Linear(hidden_dim, 1)
        self.latent_state = nt_full([latent_dim], 0.0)
        self.hidden_state = nt_full([hidden_dim], 0.0)
        self.imagined_trajectories = []
        self.opt = none
        self.name = "WorldModel"

    def reset(self):
        self.latent_state = nt_full([self.latent_dim], 0.0)
        self.hidden_state = nt_full([self.hidden_dim], 0.0)

    def posterior(self, obs):
        var p = self.enc.forward(_no_vec(obs))
        return [p.slice(0, 0, self.latent_dim), p.slice(0, self.latent_dim, 2 * self.latent_dim).clamp(-5.0, 2.0)]

    def encode(self, obs):
        var ms = self.posterior(obs)
        if not self.training:
            return ms[0]
        return ms[0] + ms[1].exp() * Tensor(nt_randn(self.latent_dim))

    def _dyn(self, latent, action, h):
        return (self.rssm_in.forward(torch.cat([_no_vec(latent), _no_vec(action)], 0)) + self.rssm_rec.forward(h)).tanh()

    def rssm_step(self, latent, action):
        var h = self._dyn(latent, action, Tensor(self.hidden_state))
        var z = self.prior.forward(h)
        self.hidden_state = h.detach().data
        self.latent_state = z.detach().data
        return z

    def decode(self, latent):
        return self.dec.forward(_no_vec(latent))

    def predict_reward(self):
        var r = 0.0
        with no_grad():
            r = self.reward_head.forward(Tensor(self.hidden_state)).item()
        return r

    def predict_continue(self):
        var c = 0.0
        with no_grad():
            c = self.continue_head.forward(Tensor(self.hidden_state)).sigmoid().item()
        return c

    def imagine(self, initial_obs, policy_fn, horizon):
        var traj = []
        with no_grad():
            self.reset()
            var z = self.encode(initial_obs)
            var s = 0
            while s < horizon:
                var a = policy_fn(z)
                z = self.rssm_step(z, a)
                traj.append({"latent": z, "reward": self.predict_reward(), "continue": self.predict_continue()})
                s = s + 1
        self.imagined_trajectories = traj
        return traj

    # reconstruction + next-observation prediction + reward + KL(q || N(0, 1))
    def loss_tensor(self, obs, action, next_obs, reward, done):
        var ms = self.posterior(obs)
        var z = ms[0] + ms[1].exp() * Tensor(nt_randn(self.latent_dim))
        var recon = _fn_mse(self.dec.forward(z), _no_vec(obs), "mean")
        var h = self._dyn(z, action, Tensor(nt_full([self.hidden_dim], 0.0)))
        var pred = _fn_mse(self.dec.forward(self.prior.forward(h)), _no_vec(next_obs), "mean")
        var rew = (self.reward_head.forward(h).sum() - reward).square()
        var target_c = 1.0
        if done:
            target_c = 0.0
        var cont = _fn_bce_logits(self.continue_head.forward(h), Tensor([target_c]), none, "mean")
        var kl = ((ms[1] * 2.0).exp() + ms[0].square() - 1.0 - ms[1] * 2.0).sum() * 0.5
        return recon + pred + rew + cont + kl * 0.1

    def train_step(self, obs, action, next_obs, reward, done, lr):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        self.opt.zero_grad()
        var l = self.loss_tensor(obs, action, next_obs, reward, done)
        l.backward()
        self.opt.step()
        return l.item()

    def get_name(self):
        return self.name


# ── 277: SelfSupervisedLearner ─────────────────────────────────────────────
# Two augmented views of x through an online projector, then:
#   simclr        NT-Xent over a batch (>= 2 examples)
#   byol          2 - 2 cos(predictor(z1), sg(target(x2))), target = EMA
#   mae           reconstruct randomly masked input features
#   barlow_twins  (1 - C_ii)^2 + 0.005 C_ij^2 on the batch cross-correlation
# x is (encoder_dim,) or a batch (B, encoder_dim).
class SelfSupervisedLearner(Module):
    def __init__(self, encoder_dim, projection_dim, method, temperature):
        super().__init__()
        if method != "simclr" and method != "byol" and method != "mae" and method != "barlow_twins":
            raise ValueError("SSL method must be simclr, byol, mae or barlow_twins, got '" + str(method) + "'")
        self.encoder_dim = encoder_dim
        self.projection_dim = projection_dim
        self.method = method
        self.temperature = temperature
        self.online = Linear(encoder_dim, projection_dim)
        self.target = Linear(encoder_dim, projection_dim)
        self.target.load_state_dict(self.online.state_dict())
        self.target.requires_grad_(false)
        self.predictor = Linear(projection_dim, projection_dim)
        self.decoder = Linear(projection_dim, encoder_dim)
        self.momentum = 0.996
        self.step = 0
        self.loss_history = []
        self.opt = none
        self.name = "SelfSupervisedLearner"

    def project(self, z, W):
        return W.forward(_t_wrap(z))

    # a random but seeded augmentation: noise, scaling, reversal or identity
    def augment(self, x, seed):
        var t = _t_wrap(x)
        var k = seed % 4
        if k == 0:
            return t + Tensor(nt_normal(t.shape, 0.0, 0.05), false, t.shape)
        if k == 1:
            return t * (0.9 + float(seed % 10) * 0.01)
        if k == 2:
            var n = t.size()[t.dim() - 1]
            var idx = []
            var i = n - 1
            while i >= 0:
                idx.append(i)
                i = i - 1
            return t.index_select(t.dim() - 1, idx)
        return t

    def contrastive_loss(self, z1, z2):
        var a = _t_wrap(z1)
        var b = _t_wrap(z2)
        if a.dim() == 1 or a.size()[0] < 2:
            raise ValueError("simclr needs a batch of at least 2 examples (the other examples are the negatives)")
        var B = a.size()[0]
        var z = _fn_normalize(torch.cat([a, b], 0), 1, 0.000000001)
        var sim = z.matmul(z.t()) * (1.0 / self.temperature)
        # remove self-similarity, positives are i <-> i + B
        var mask = []
        var tgt = []
        var i = 0
        while i < 2 * B:
            var j = 0
            while j < 2 * B:
                if i == j:
                    mask.append(nt_unary("log", [0.0])[0])
                else:
                    mask.append(0.0)
                j = j + 1
            tgt.append((i + B) % (2 * B))
            i = i + 1
        return _fn_cross_entropy(sim + Tensor(mask, false, [2 * B, 2 * B]), tgt, none, -100, "mean", 0.0)

    def loss_tensor(self, x):
        var X = _t_wrap(x)
        var x1 = self.augment(X, self.step)
        var x2 = self.augment(X, self.step + 101)
        var z1 = self.online.forward(x1)
        var z2 = self.online.forward(x2)
        var loss = none
        if self.method == "simclr":
            loss = self.contrastive_loss(z1, z2)
        elif self.method == "byol":
            var p1 = self.predictor.forward(z1)
            var t2 = self.target.forward(x2).detach()
            loss = _fn_cosine_similarity(p1, t2, -1, 0.000000001).mean().rsub(1.0) * 2.0
        elif self.method == "mae":
            var keep = Tensor(nt_binary("lt", nt_rand(X.shape), X.shape, 0.5, [])[0], false, X.shape)
            var hidden = keep.rsub(1.0)
            var rec = self.decoder.forward(self.online.forward(X * keep))
            var err = (rec - X).square() * hidden
            loss = err.sum().div(hidden.sum() + 0.000000001)
        else:
            if z1.dim() == 1 or z1.size()[0] < 2:
                raise ValueError("barlow_twins needs a batch of at least 2 examples")
            var B = z1.size()[0]
            var a = (z1 - z1.mean(0, true)).div(z1.std(0, true, 0) + 0.000001)
            var b = (z2 - z2.mean(0, true)).div(z2.std(0, true, 0) + 0.000001)
            var C = a.t().matmul(b) * (1.0 / float(B))
            var D = self.projection_dim
            var eye = torch.eye(D)
            var on = ((C * eye).sum(1) - 1.0).square().sum()
            var off = (C * eye.rsub(1.0)).square().sum()
            loss = on + off * 0.005
        return [loss, z1, z2]

    def forward(self, x):
        var r = none
        with no_grad():
            r = self.loss_tensor(x)
        var l = r[0].item()
        self.loss_history.append(l)
        self.step = self.step + 1
        return {"loss": l, "z1": r[1], "z2": r[2]}

    # one Adam step on the objective, then the EMA target update
    def train_step(self, x, lr):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        self.opt.zero_grad()
        var r = self.loss_tensor(x)
        r[0].backward()
        self.opt.step()
        var tp = self.target.parameters()
        var op = self.online.parameters()
        var i = 0
        while i < len(tp):
            nt_scale_(tp[i].data, self.momentum)
            nt_axpy(tp[i].data, 1.0 - self.momentum, op[i].data)
            i = i + 1
        var l = r[0].item()
        self.loss_history.append(l)
        self.step = self.step + 1
        return l

    def get_name(self):
        return self.name


# ── 278: ReasoningChain ────────────────────────────────────────────────────
# n_steps of learned residual refinement  s <- s + tanh(W_k s + b_k); the
# scratchpad records each step's mean activation, confidence = |mean(s)|.
class ReasoningChain(Module):
    def __init__(self, n_steps, hidden_dim, use_scratchpad):
        super().__init__()
        self.n_steps = n_steps
        self.hidden_dim = hidden_dim
        self.use_scratchpad = use_scratchpad
        self.steps = []
        var i = 0
        while i < n_steps:
            self.steps.append(Linear(hidden_dim, hidden_dim))
            i = i + 1
        self.scratchpad = []
        self.thought_chain = []
        self.confidence_scores = []
        self.name = "ReasoningChain"

    def think_step(self, state, step_idx):
        var s = _no_vec(state)
        var ns = s + self.steps[step_idx % len(self.steps)].forward(s).tanh()
        if self.use_scratchpad:
            self.scratchpad.append(ns.mean().item())
        return ns

    def reason(self, query_embedding):
        var state = _no_vec(query_embedding)
        self.thought_chain = [state]
        self.scratchpad = []
        self.confidence_scores = []
        var k = 0
        while k < self.n_steps:
            state = self.think_step(state, k)
            self.confidence_scores.append(abs(state.mean().item()))
            self.thought_chain.append(state)
            k = k + 1
        return state

    # mean cosine similarity of the conclusion to the facts
    def verify(self, conclusion, facts):
        var total = 0.0
        var i = 0
        while i < len(facts):
            total = total + _no_cos(conclusion, facts[i])
            i = i + 1
        if len(facts) > 0:
            total = total / float(len(facts))
        return {"consistent": total > 0.0, "score": total}

    def chain_of_thought_summary(self):
        var avg = 0.0
        var i = 0
        while i < len(self.confidence_scores):
            avg = avg + self.confidence_scores[i]
            i = i + 1
        if len(self.confidence_scores) > 0:
            avg = avg / float(len(self.confidence_scores))
        return {"n_steps": self.n_steps, "scratchpad_entries": len(self.scratchpad), "avg_confidence": avg}

    def get_name(self):
        return self.name


# ── 279: SymbolicReasoner (forward chaining over Horn rules) ───────────────
class SymbolicReasoner:
    def __init__(self, n_concepts, n_rules):
        self.n_concepts = n_concepts
        self.n_rules = n_rules
        self.concept_embeddings = {}
        self.rules = []
        self.knowledge_graph = {}
        self.inference_cache = {}
        self.name = "SymbolicReasoner"

    def add_concept(self, name, embedding):
        self.concept_embeddings[name] = embedding

    def add_rule(self, antecedents, consequent, weight):
        self.rules.append({"if": antecedents, "then": consequent, "weight": weight})

    def add_relation(self, concept1, relation, concept2, weight):
        if not (concept1 in self.knowledge_graph):
            self.knowledge_graph[concept1] = []
        self.knowledge_graph[concept1].append([concept2, relation, weight])

    # apply every rule whose antecedents all hold until nothing changes
    def forward_chain(self, known_concepts):
        var derived = known_concepts[:]
        var changed = true
        while changed:
            changed = false
            var r = 0
            while r < len(self.rules):
                var rule = self.rules[r]
                var all_true = true
                var a = 0
                while a < len(rule["if"]):
                    if not (rule["if"][a] in derived):
                        all_true = false
                    a = a + 1
                if all_true and not (rule["then"] in derived):
                    derived.append(rule["then"])
                    changed = true
                r = r + 1
        return derived

    def semantic_similarity(self, c1, c2):
        if (c1 in self.concept_embeddings) and (c2 in self.concept_embeddings):
            return _no_cos(self.concept_embeddings[c1], self.concept_embeddings[c2])
        return 0.0

    # the top_k concepts most similar to question_concept, best first
    def query(self, question_concept, top_k):
        var names = sorted(self.concept_embeddings.keys())
        var scored = []
        var i = 0
        while i < len(names):
            scored.append({"concept": names[i], "score": self.semantic_similarity(question_concept, names[i])})
            i = i + 1
        var out = []
        while len(out) < top_k and len(scored) > 0:
            var best = 0
            var j = 1
            while j < len(scored):
                if scored[j]["score"] > scored[best]["score"]:
                    best = j
                j = j + 1
            out.append(scored[best])
            scored = scored[:best] + scored[best + 1:]
        return out

    def get_name(self):
        return self.name


# ── 280: NeuralSymbolicSystem ──────────────────────────────────────────────
# A neural perception layer scores concepts (sigmoid(W obs + b)); concepts
# above the threshold are handed to the symbolic reasoner.
class NeuralSymbolicSystem(Module):
    def __init__(self, encoder_dim, n_concepts, n_rules):
        super().__init__()
        self.encoder_dim = encoder_dim
        self.n_concepts = n_concepts
        self.n_rules = n_rules
        self.encoder = Linear(encoder_dim, n_concepts)
        self.symbolic_reasoner = SymbolicReasoner(n_concepts, n_rules)
        self.concept_threshold = 0.5
        self.perception_history = []
        self.reasoning_history = []
        self.opt = none
        self.name = "NeuralSymbolicSystem"

    def concept_scores(self, obs):
        return self.encoder.forward(_no_vec(obs)).sigmoid()

    def perceive(self, obs):
        var s = none
        with no_grad():
            s = self.concept_scores(obs).data
        var out = []
        var i = 0
        while i < self.n_concepts:
            if s[i] > self.concept_threshold:
                out.append("concept_" + str(i))
            i = i + 1
        return out

    def reason(self, activated_concepts):
        return self.symbolic_reasoner.forward_chain(activated_concepts)

    def ground(self, concept_name):
        if concept_name in self.symbolic_reasoner.concept_embeddings:
            return self.symbolic_reasoner.concept_embeddings[concept_name]
        raise KeyError("no embedding for concept '" + str(concept_name) + "'")

    # one Adam step of binary cross-entropy towards the given active concepts
    def train_perception(self, obs, active_concepts, lr):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        var y = nt_full([self.n_concepts], 0.0)
        var i = 0
        while i < len(active_concepts):
            y[int(string_replace(active_concepts[i], "concept_", ""))] = 1.0
            i = i + 1
        self.opt.zero_grad()
        var l = _fn_bce_logits(self.encoder.forward(_no_vec(obs)), Tensor(y), none, "mean")
        l.backward()
        self.opt.step()
        return l.item()

    def forward(self, obs):
        var activated = self.perceive(obs)
        self.perception_history.append(activated)
        var derived = self.reason(activated)
        self.reasoning_history.append(derived)
        return {"activated": activated, "derived": derived, "n_concepts": len(derived)}

    def get_name(self):
        return self.name


# ── 281: PlanningModule (model-predictive control by random shooting) ──────
# n_candidates action sequences ~ N(0, 1) are rolled out in the world model
# from the current observation; the first action of the best is executed.
class PlanningModule:
    def __init__(self, state_dim, action_dim, horizon, n_candidates, world_model):
        if n_candidates < 1:
            raise ValueError("PlanningModule needs at least one candidate")
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.horizon = horizon
        self.n_candidates = n_candidates
        self.world_model = world_model
        self.gamma = 0.99
        self.plan_cache = []
        self.total_plans = 0
        self.name = "PlanningModule"

    def sample_action_sequence(self, seed):
        var seq = []
        var h = 0
        while h < self.horizon:
            seq.append(Tensor(nt_randn(self.action_dim)))
            h = h + 1
        return seq

    # discounted predicted reward, weighted by the predicted continuation
    def evaluate_sequence(self, state, action_seq):
        var wm = self.world_model
        var total = 0.0
        var alive = 1.0
        var disc = 1.0
        with no_grad():
            wm.reset()
            var z = wm.posterior(state)[0]
            var i = 0
            while i < len(action_seq):
                z = wm.rssm_step(z, action_seq[i])
                total = total + disc * alive * wm.predict_reward()
                alive = alive * wm.predict_continue()
                disc = disc * self.gamma
                i = i + 1
        return total

    def plan(self, state):
        var best_seq = none
        var best = 0.0
        var k = 0
        while k < self.n_candidates:
            var seq = self.sample_action_sequence(k)
            var ret = self.evaluate_sequence(state, seq)
            if best_seq == none or ret > best:
                best = ret
                best_seq = seq
            k = k + 1
        self.plan_cache.append(best)
        self.total_plans = self.total_plans + 1
        return {"action_seq": best_seq, "expected_return": best}

    # the first action of the best plan, as a list
    def mpc_step(self, state):
        return self.plan(state)["action_seq"][0].data

    def get_name(self):
        return self.name


# ── 282: ContinualLearner (EWC, Kirkpatrick et al. 2017) ───────────────────
# A one-layer ReLU model f(x) = relu(W x + b). A task's data is a batch of
# inputs (a list of vectors, or a flat list read as rows of model_dim) with
# the objective of reconstructing them, or a list of [x, y] pairs (MSE).
# After a task, its parameters and diagonal empirical Fisher are kept; later
# training adds  lambda/2 sum_k F_k (theta - theta*_k)^2.
class ContinualLearner(Module):
    def __init__(self, model_dim, ewc_lambda, n_tasks):
        super().__init__()
        self.model_dim = model_dim
        self.ewc_lambda = ewc_lambda
        self.n_tasks = n_tasks
        self.layer = Linear(model_dim, model_dim)
        self.task_params = []
        self.fisher_matrices = []
        self.current_task = 0
        self.task_losses = {}
        self.name = "ContinualLearner"

    def forward(self, x):
        return self.layer.forward(_t_wrap(x)).relu()

    def _pairs(self, data):
        if type(data) == "list" and len(data) > 0 and type(data[0]) == "list" and len(data[0]) == 2 and not _t_isnum(data[0][0]):
            return data
        var X = _no_rows(data, self.model_dim)
        var out = []
        var i = 0
        while i < X.size()[0]:
            out.append([X.select(0, i), X.select(0, i)])
            i = i + 1
        return out

    def _flat_params(self):
        var ps = self.parameters()
        var out = []
        var i = 0
        while i < len(ps):
            out = out + _t_flat(ps[i].data)
            i = i + 1
        return out

    # diagonal empirical Fisher: mean over examples of squared gradients
    def compute_fisher(self, data_batch):
        var pairs = self._pairs(data_batch)
        var n = len(self._flat_params())
        var F = nt_full([n], 0.0)
        var i = 0
        while i < len(pairs):
            self.zero_grad()
            _fn_mse(self.forward(pairs[i][0]), _t_wrap(pairs[i][1]), "sum").backward()
            var g = []
            var ps = self.parameters()
            var k = 0
            while k < len(ps):
                g = g + _t_flat(ps[k].grad)
                k = k + 1
            var j = 0
            while j < n:
                F[j] = F[j] + g[j] * g[j] / float(len(pairs))
                j = j + 1
            i = i + 1
        self.zero_grad()
        return F

    def consolidate_task(self, data_batch):
        self.task_params.append(self._flat_params())
        self.fisher_matrices.append(self.compute_fisher(data_batch))
        self.current_task = self.current_task + 1

    def _penalty_tensor(self):
        var total = none
        var ps = self.parameters()
        var t = 0
        while t < len(self.task_params):
            var off = 0
            var k = 0
            while k < len(ps):
                var n = ps[k].numel()
                var star = Tensor(self.task_params[t][off:off + n], false, ps[k].shape)
                var F = Tensor(self.fisher_matrices[t][off:off + n], false, ps[k].shape)
                var term = ((ps[k] - star).square() * F).sum()
                if total == none:
                    total = term
                else:
                    total = total + term
                off = off + n
                k = k + 1
            t = t + 1
        if total == none:
            return Tensor(0.0)
        return total * (self.ewc_lambda / 2.0)

    def ewc_penalty(self):
        var p = 0.0
        with no_grad():
            p = self._penalty_tensor().item()
        return p

    # n_epochs of SGD on task loss + EWC penalty; returns the loss per epoch
    def train_task(self, task_id, data, n_epochs, lr):
        var pairs = self._pairs(data)
        var opt = SGD(self.parameters(), lr)
        var losses = []
        var e = 0
        while e < n_epochs:
            opt.zero_grad()
            var task = none
            var i = 0
            while i < len(pairs):
                var l = _fn_mse(self.forward(pairs[i][0]), _t_wrap(pairs[i][1]), "mean")
                if task == none:
                    task = l
                else:
                    task = task + l
                i = i + 1
            var loss = task * (1.0 / float(len(pairs))) + self._penalty_tensor()
            loss.backward()
            opt.step()
            losses.append(loss.item())
            e = e + 1
        self.task_losses[str(task_id)] = losses
        return losses

    def get_name(self):
        return self.name


# ── 283: NeuroEvolution (genetic algorithm over real-valued genomes) ───────
# Elitism, fitness-proportional (roulette) selection on shifted fitness,
# one-point crossover with probability crossover_rate, Gaussian mutation.
class NeuroEvolution:
    def __init__(self, pop_size, genome_dim, mutation_rate, crossover_rate, elite_frac):
        self.pop_size = pop_size
        self.genome_dim = genome_dim
        self.mutation_rate = mutation_rate
        self.crossover_rate = crossover_rate
        self.elite_frac = elite_frac
        self.population = []
        self.fitness_scores = []
        self.generation = 0
        self.best_genome = none
        self.best_fitness = 0.0 - 1e9
        self.fitness_history = []
        var i = 0
        while i < pop_size:
            self.population.append(nt_randn(genome_dim))
            i = i + 1
        self.name = "NeuroEvolution"

    def mutate(self, genome, seed):
        return nt_binary("add", genome, [len(genome)], nt_normal(len(genome), 0.0, self.mutation_rate), [len(genome)])[0]

    def crossover(self, g1, g2, seed):
        if nt_rand(1)[0] >= self.crossover_rate:
            return g1[:]
        var cut = nt_randint(1, len(g1), 1)[0]
        return g1[:cut] + g2[cut:]

    def select_parent(self, scores):
        var lo = scores[0]
        var i = 1
        while i < len(scores):
            if scores[i] < lo:
                lo = scores[i]
            i = i + 1
        var total = 0.0
        i = 0
        while i < len(scores):
            total = total + (scores[i] - lo) + 0.000000001
            i = i + 1
        var r = nt_rand(1)[0] * total
        var cum = 0.0
        i = 0
        while i < len(scores):
            cum = cum + (scores[i] - lo) + 0.000000001
            if cum >= r:
                return i
            i = i + 1
        return len(scores) - 1

    def evolve(self, fitness_fn):
        self.fitness_scores = []
        var i = 0
        while i < len(self.population):
            self.fitness_scores.append(fitness_fn(self.population[i]))
            i = i + 1
        var best_idx = Tensor(self.fitness_scores).argmax().item()
        if self.fitness_scores[best_idx] > self.best_fitness:
            self.best_fitness = self.fitness_scores[best_idx]
            self.best_genome = self.population[best_idx]
        self.fitness_history.append(self.best_fitness)
        var n_elite = max(1, int(float(self.pop_size) * self.elite_frac))
        var new_pop = []
        var top = tensor_topk(self.fitness_scores, n_elite)
        i = 0
        while i < len(top):
            new_pop.append(self.population[top[i]["index"]])
            i = i + 1
        while len(new_pop) < self.pop_size:
            var p1 = self.population[self.select_parent(self.fitness_scores)]
            var p2 = self.population[self.select_parent(self.fitness_scores)]
            new_pop.append(self.mutate(self.crossover(p1, p2, self.generation), self.generation))
        self.population = new_pop
        self.generation = self.generation + 1
        return {"best_fitness": self.best_fitness, "generation": self.generation, "pop_size": self.pop_size}

    def get_name(self):
        return self.name


# ── 284: AttentionMemoryBank (key-value memory read by softmax attention) ──
class AttentionMemoryBank:
    def __init__(self, memory_size, key_dim, value_dim, n_heads):
        self.memory_size = memory_size
        self.key_dim = key_dim
        self.value_dim = value_dim
        self.n_heads = n_heads
        self.keys = nt_full([memory_size * key_dim], 0.0)
        self.values = nt_full([memory_size * value_dim], 0.0)
        self.usage = nt_full([memory_size], 0.0)
        self.n_reads = 0
        self.n_writes = 0
        self.name = "AttentionMemoryBank"

    def write(self, key, value, slot):
        var k = _t_flat(_t_wrap(key).data)
        var v = _t_flat(_t_wrap(value).data)
        if len(k) != self.key_dim or len(v) != self.value_dim:
            raise ValueError("key/value sizes must be " + str(self.key_dim) + "/" + str(self.value_dim))
        var s = slot % self.memory_size
        var i = 0
        while i < self.key_dim:
            self.keys[s * self.key_dim + i] = k[i]
            i = i + 1
        i = 0
        while i < self.value_dim:
            self.values[s * self.value_dim + i] = v[i]
            i = i + 1
        self.usage[s] = self.usage[s] + 1.0
        self.n_writes = self.n_writes + 1

    # value = softmax(K q / sqrt(d)) . V
    def read(self, query):
        var q = _t_flat(_t_wrap(query).data)
        var K = Tensor(self.keys, false, [self.memory_size, self.key_dim])
        var V = Tensor(self.values, false, [self.memory_size, self.value_dim])
        var attn = (K.mv(Tensor(q)) * (1.0 / sqrt(float(self.key_dim)))).softmax(0)
        self.n_reads = self.n_reads + 1
        return {"value": V.t().mv(attn).data, "attention": attn.data}

    def forget_least_used(self, n_to_forget):
        var cleared = 0
        while cleared < n_to_forget:
            var lo = 0
            var i = 1
            while i < self.memory_size:
                if self.usage[i] < self.usage[lo]:
                    lo = i
                i = i + 1
            var j = 0
            while j < self.key_dim:
                self.keys[lo * self.key_dim + j] = 0.0
                j = j + 1
            j = 0
            while j < self.value_dim:
                self.values[lo * self.value_dim + j] = 0.0
                j = j + 1
            self.usage[lo] = 1e30
            cleared = cleared + 1
        var i2 = 0
        while i2 < self.memory_size:
            if self.usage[i2] >= 1e30:
                self.usage[i2] = 0.0
            i2 = i2 + 1

    def stats(self):
        return {"reads": self.n_reads, "writes": self.n_writes, "capacity": self.memory_size}

    def get_name(self):
        return self.name


# ── 285: FewShotLearner (prototypical networks, Snell et al. 2017) ─────────
# Embeddings relu(W x + b); prototypes are the class means; a query takes the
# label of the nearest prototype. train_episode is one meta-learning step.
class FewShotLearner(Module):
    def __init__(self, encoder_dim, metric):
        super().__init__()
        if metric != "euclidean" and metric != "cosine" and metric != "manhattan":
            raise ValueError("metric must be euclidean, cosine or manhattan, got '" + str(metric) + "'")
        self.encoder_dim = encoder_dim
        self.metric = metric
        self.encoder = Linear(encoder_dim, encoder_dim)
        self.prototypes = {}
        self.proto_labels = []
        self.episode_count = 0
        self.opt = none
        self.name = "FewShotLearner"

    def encode(self, x):
        return self.encoder.forward(_no_vec(x)).relu()

    def compute_prototype(self, support_embeddings):
        return _t_stack(support_embeddings, 0).mean(0)

    def distance_tensor(self, q, p):
        if self.metric == "cosine":
            return _fn_cosine_similarity(q, p, none, 0.000000001).rsub(1.0)
        if self.metric == "manhattan":
            return (q - p).abs().mean()
        return (q - p).square().sum()

    def distance(self, q, p):
        return self.distance_tensor(_t_wrap(q), _t_wrap(p)).item()

    def _prototypes(self, support_x, support_y):
        var groups = {}
        var labels = []
        var i = 0
        while i < len(support_x):
            var lab = str(support_y[i])
            if not (lab in groups):
                groups[lab] = []
                labels.append(lab)
            groups[lab].append(self.encode(support_x[i]))
            i = i + 1
        var protos = {}
        i = 0
        while i < len(labels):
            protos[labels[i]] = self.compute_prototype(groups[labels[i]])
            i = i + 1
        return [labels, protos]

    def fit_episode(self, support_x, support_y):
        var r = none
        with no_grad():
            r = self._prototypes(support_x, support_y)
        self.proto_labels = r[0]
        self.prototypes = r[1]
        self.episode_count = self.episode_count + 1

    def predict(self, query_x):
        var best = ""
        var best_d = 0.0
        with no_grad():
            var q = self.encode(query_x)
            var i = 0
            while i < len(self.proto_labels):
                var lab = self.proto_labels[i]
                var d = self.distance_tensor(q, self.prototypes[lab]).item()
                if best == "" or d < best_d:
                    best = lab
                    best_d = d
                i = i + 1
        return {"label": best, "distance": best_d, "n_classes": len(self.proto_labels)}

    # one Adam step of the prototypical loss: softmax over -distance
    def train_episode(self, support_x, support_y, query_x, query_y, lr):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        self.opt.zero_grad()
        var r = self._prototypes(support_x, support_y)
        var labels = r[0]
        var total = none
        var i = 0
        while i < len(query_x):
            var q = self.encode(query_x[i])
            var ds = []
            var tgt = -1
            var j = 0
            while j < len(labels):
                ds.append(self.distance_tensor(q, r[1][labels[j]]).neg())
                if labels[j] == str(query_y[i]):
                    tgt = j
                j = j + 1
            if tgt < 0:
                raise ValueError("query label " + str(query_y[i]) + " is not in the support set")
            var l = _fn_cross_entropy(_t_stack(ds, 0).unsqueeze(0), [tgt], none, -100, "mean", 0.0)
            if total == none:
                total = l
            else:
                total = total + l
            i = i + 1
        var loss = total * (1.0 / float(len(query_x)))
        loss.backward()
        self.opt.step()
        return loss.item()

    def get_name(self):
        return self.name


# ── 286: CausalModel (linear-Gaussian structural causal model) ─────────────
#   x_j = sum_{i -> j} w_ij x_i + e_j,  e_j ~ N(0, noise_std_j^2)
# intervene(v, value) samples from do(x_v = value): v's equation is cut and
# the fixed value propagates to its descendants.
class CausalModel:
    def __init__(self, n_variables, hidden_dim):
        self.n_variables = n_variables
        self.hidden_dim = hidden_dim
        self.dag = []
        var i = 0
        while i < n_variables:
            self.dag.append(nt_full([n_variables], 0.0))
            i = i + 1
        self.eq_weights = []
        i = 0
        while i < n_variables:
            self.eq_weights.append(nt_randn(n_variables))
            i = i + 1
        self.noise_std = nt_full([n_variables], 1.0)
        self.name = "CausalModel"

    def add_edge(self, cause, effect):
        if cause < 0 or cause >= self.n_variables or effect < 0 or effect >= self.n_variables:
            raise IndexError("variable out of range")
        self.dag[cause][effect] = 1.0
        if len(self.topological_order()) < self.n_variables:
            self.dag[cause][effect] = 0.0
            raise ValueError("edge " + str(cause) + " -> " + str(effect) + " would create a cycle")

    # Kahn's algorithm (lowest index first among ready variables)
    def topological_order(self):
        var n = self.n_variables
        var indeg = []
        var i = 0
        while i < n:
            var d = 0
            var j = 0
            while j < n:
                if self.dag[j][i] > 0:
                    d = d + 1
                j = j + 1
            indeg.append(d)
            i = i + 1
        var order = []
        var done = nt_full([n], 0.0)
        var progress = true
        while progress:
            progress = false
            i = 0
            while i < n:
                if done[i] == 0.0 and indeg[i] == 0:
                    order.append(i)
                    done[i] = 1.0
                    var j2 = 0
                    while j2 < n:
                        if self.dag[i][j2] > 0:
                            indeg[j2] = indeg[j2] - 1
                        j2 = j2 + 1
                    progress = true
                    break
                i = i + 1
        return order

    def _sample(self, n_samples, fixed_var, fixed_value):
        var order = self.topological_order()
        var out = {}
        var i = 0
        while i < self.n_variables:
            out[str(i)] = []
            i = i + 1
        var s = 0
        while s < n_samples:
            var vals = nt_full([self.n_variables], 0.0)
            var k = 0
            while k < len(order):
                var v = order[k]
                if v == fixed_var:
                    vals[v] = fixed_value
                else:
                    var x = nt_randn(1)[0] * self.noise_std[v]
                    var j = 0
                    while j < self.n_variables:
                        if self.dag[j][v] > 0:
                            x = x + self.eq_weights[v][j] * vals[j]
                        j = j + 1
                    vals[v] = x
                out[str(v)].append(vals[v])
                k = k + 1
            s = s + 1
        return out

    def sample(self, n_samples):
        return self._sample(n_samples, -1, 0.0)

    def intervene(self, variable, value, n_samples):
        return self._sample(n_samples, variable, value)

    def get_name(self):
        return self.name


# ── 287: ZeroShotLearner (attribute-based, e.g. DeViSE) ────────────────────
# Visual features are projected into the semantic space; the class is the
# prototype with the highest cosine similarity, so classes never seen in
# training can be recognised from their semantic embedding alone.
class ZeroShotLearner(Module):
    def __init__(self, visual_dim, semantic_dim, n_seen_classes):
        super().__init__()
        self.visual_dim = visual_dim
        self.semantic_dim = semantic_dim
        self.n_seen_classes = n_seen_classes
        self.proj = Linear(visual_dim, semantic_dim)
        self.class_prototypes = {}
        self.compatibility_scores = []
        self.opt = none
        self.name = "ZeroShotLearner"

    def project_visual(self, x):
        return self.proj.forward(_no_vec(x))

    def add_class(self, class_name, semantic_embedding):
        self.class_prototypes[class_name] = _t_flat(_t_wrap(semantic_embedding).data)

    def _scores(self, x):
        var v = self.project_visual(x)
        var names = sorted(self.class_prototypes.keys())
        var s = []
        var i = 0
        while i < len(names):
            s.append(_fn_cosine_similarity(v, Tensor(self.class_prototypes[names[i]]), none, 0.000000001))
            i = i + 1
        return [names, s]

    def predict(self, x):
        if len(self.class_prototypes) == 0:
            raise ValueError("no classes added")
        var r = none
        with no_grad():
            r = self._scores(x)
        var best = 0
        var i = 1
        while i < len(r[0]):
            if r[1][i].item() > r[1][best].item():
                best = i
            i = i + 1
        var sc = r[1][best].item()
        self.compatibility_scores.append(sc)
        return {"class": r[0][best], "score": sc}

    # Adam on cross-entropy over cosine scores / 0.1 for labelled (seen) data
    def fit(self, xs, labels, lr, epochs):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        var last = 0.0
        var e = 0
        while e < epochs:
            self.opt.zero_grad()
            var total = none
            var i = 0
            while i < len(xs):
                var r = self._scores(xs[i])
                var tgt = -1
                var j = 0
                while j < len(r[0]):
                    if r[0][j] == labels[i]:
                        tgt = j
                    j = j + 1
                var l = _fn_cross_entropy((_t_stack(r[1], 0) * 10.0).unsqueeze(0), [tgt], none, -100, "mean", 0.0)
                if total == none:
                    total = l
                else:
                    total = total + l
                i = i + 1
            var loss = total * (1.0 / float(len(xs)))
            loss.backward()
            self.opt.step()
            last = loss.item()
            e = e + 1
        return last

    def calibrate(self, calibration_data, calibration_labels):
        var correct = 0
        var i = 0
        while i < len(calibration_data):
            if i < len(calibration_labels) and self.predict(calibration_data[i])["class"] == calibration_labels[i]:
                correct = correct + 1
            i = i + 1
        return float(correct) / float(max(1, len(calibration_data)))

    def get_name(self):
        return self.name


# ── 288: NeuralProgramSynthesizer (search over straight-line programs) ─────
# A program is n_steps unary steps applied to the input x: relu, negate,
# softmax, and add / mul with the original input (h + x, h * x). synthesize
# scores each candidate by -MSE against the examples; with n_candidates at
# least ops^n_steps every program is tried, otherwise candidates are sampled
# from the selector's softmax(W h / temp) (random search guided by W).
class NeuralProgramSynthesizer(Module):
    def __init__(self, ops, input_dim, n_steps):
        super().__init__()
        var i = 0
        while i < len(ops):
            var o = ops[i]
            if o != "add" and o != "mul" and o != "relu" and o != "negate" and o != "softmax":
                raise ValueError("unknown op '" + str(o) + "' (add, mul, relu, negate, softmax)")
            i = i + 1
        self.ops = ops
        self.input_dim = input_dim
        self.n_steps = n_steps
        self.selector = Linear(input_dim, len(ops))
        self.programs = []
        self.name = "NeuralProgramSynthesizer"

    def select_op(self, state, temp):
        var logits = none
        with no_grad():
            logits = self.selector.forward(_no_vec(state))
        if temp <= 0:
            return logits.argmax().item()
        var p = (logits * (1.0 / temp)).softmax(0).data
        var u = nt_rand(1)[0]
        var c = 0.0
        var i = 0
        while i < len(p):
            c = c + p[i]
            if u <= c:
                return i
            i = i + 1
        return len(p) - 1

    # one step: args = [h] or [h, x0]
    def execute_op(self, op_name, args):
        var h = _no_vec(args[0])
        var x0 = h
        if len(args) > 1:
            x0 = _no_vec(args[1])
        if op_name == "add":
            return h + x0
        if op_name == "mul":
            return h * x0
        if op_name == "relu":
            return h.relu()
        if op_name == "negate":
            return h.neg()
        if op_name == "softmax":
            return h.softmax(0)
        raise ValueError("unknown op '" + str(op_name) + "'")

    def run(self, program, x):
        var x0 = _no_vec(x)
        var h = x0
        var i = 0
        while i < len(program):
            h = self.execute_op(program[i], [h, x0])
            i = i + 1
        return h

    def score(self, program, examples_in, examples_out):
        var s = 0.0
        var i = 0
        while i < len(examples_in):
            var d = self.run(program, examples_in[i]) - _no_vec(examples_out[i])
            s = s - (d * d).mean().item()
            i = i + 1
        return s / float(max(1, len(examples_in)))

    def _nth_program(self, k):
        var prog = []
        var r = k
        var s = 0
        while s < self.n_steps:
            prog.append(self.ops[r % len(self.ops)])
            r = r // len(self.ops)
            s = s + 1
        return prog

    def synthesize(self, examples_in, examples_out, n_candidates):
        if len(examples_in) == 0 or len(examples_in) != len(examples_out):
            raise ValueError("synthesize needs equally many input and output examples")
        var total = len(self.ops) ** self.n_steps
        var exhaustive = n_candidates >= total
        var n = n_candidates
        if exhaustive:
            n = total
        var best = none
        var best_score = 0.0
        with no_grad():
            var c = 0
            while c < n:
                var prog = []
                if exhaustive:
                    prog = self._nth_program(c)
                else:
                    var h = _no_vec(examples_in[0])
                    var s = 0
                    while s < self.n_steps:
                        var op = self.ops[self.select_op(h, 1.0)]
                        prog.append(op)
                        h = self.execute_op(op, [h, examples_in[0]])
                        s = s + 1
                var sc = self.score(prog, examples_in, examples_out)
                if best == none or sc > best_score:
                    best = prog
                    best_score = sc
                c = c + 1
        self.programs.append(best)
        return {"program": best, "score": best_score}

    def get_name(self):
        return self.name


# ── 289: ConsciousnessModule (global workspace, after Baars) ───────────────
# Specialists (tanh(W_i x + b_i)) compete for the workspace; salience is the
# output's RMS scaled by its agreement with the current workspace. The winner
# is broadcast (workspace <- 0.8 workspace + 0.2 winner) when its salience
# exceeds the threshold, or on the first step.
class ConsciousnessModule(Module):
    def __init__(self, workspace_dim, n_specialists, broadcast_threshold):
        super().__init__()
        self.workspace_dim = workspace_dim
        self.n_specialists = n_specialists
        self.broadcast_threshold = broadcast_threshold
        self.workspace = nt_full([workspace_dim], 0.0)
        self.specialists = []
        var i = 0
        while i < n_specialists:
            self.specialists.append(Linear(workspace_dim, workspace_dim))
            i = i + 1
        self.broadcast_history = []
        self.coalitions = []
        self.name = "ConsciousnessModule"

    def compute_relevance(self, specialist_output, workspace):
        var o = _no_vec(specialist_output)
        var rms = (o.square().mean()).sqrt().item()
        var w = _no_vec(workspace)
        if w.norm().item() < 0.000000001:
            return rms
        return rms * (1.0 + _no_cos(o, w)) / 2.0

    def compete_for_access(self, specialist_outputs):
        var best = 0
        var best_r = 0.0
        var i = 0
        while i < len(specialist_outputs):
            var r = self.compute_relevance(specialist_outputs[i], self.workspace)
            if i == 0 or r > best_r:
                best = i
                best_r = r
            i = i + 1
        if best_r > self.broadcast_threshold or len(self.broadcast_history) == 0:
            return best
        return -1

    def broadcast(self, winner_idx, specialist_outputs):
        if winner_idx < 0 or winner_idx >= len(specialist_outputs):
            return false
        var c = _t_flat(_t_wrap(specialist_outputs[winner_idx]).data)
        var i = 0
        while i < self.workspace_dim:
            self.workspace[i] = 0.8 * self.workspace[i] + 0.2 * c[i]
            i = i + 1
        self.broadcast_history.append(winner_idx)
        return true

    # inputs: one vector for every specialist, or a list (specialist i gets
    # inputs[i % len(inputs)])
    def process(self, inputs):
        var many = type(inputs) == "list" and len(inputs) > 0 and not _t_isnum(inputs[0])
        var outs = []
        with no_grad():
            var i = 0
            while i < self.n_specialists:
                var x = inputs
                if many:
                    x = inputs[i % len(inputs)]
                outs.append(self.specialists[i].forward(_no_vec(x)).tanh())
                i = i + 1
        var winner = self.compete_for_access(outs)
        var b = self.broadcast(winner, outs)
        return {"workspace": self.workspace, "winner": winner, "broadcast": b, "n_broadcasts": len(self.broadcast_history)}

    def get_name(self):
        return self.name


# ── 290: AgentMind ─────────────────────────────────────────────────────────
# Perception (liquid network) -> episodic memory -> reasoning -> global
# workspace -> planning in the world model -> action; learning is
# self-supervised (BYOL) on observations.
class AgentMind:
    def __init__(self, obs_dim, action_dim, memory_size, latent_dim):
        self.obs_dim = obs_dim
        self.action_dim = action_dim
        self.memory_size = memory_size
        self.latent_dim = latent_dim
        self.perception = LiquidNeuralNetwork(obs_dim, 16, latent_dim, 0.01, 0.5)
        self.memory = AttentionMemoryBank(memory_size, latent_dim, latent_dim, 4)
        self.world_model = WorldModel(obs_dim, action_dim, latent_dim, 32)
        self.reasoning = ReasoningChain(3, latent_dim, true)
        self.planner = PlanningModule(obs_dim, action_dim, 5, 8, self.world_model)
        self.consciousness = ConsciousnessModule(latent_dim, 4, 0.3)
        self.learner = ContinualLearner(latent_dim, 0.1, 10)
        var p = obs_dim // 2
        if p < 1:
            p = 1
        self.ssl = SelfSupervisedLearner(obs_dim, p, "byol", 0.07)
        self.step_count = 0
        self.reward_history = []
        self.consciousness_log = []
        self.name = "AgentMind"

    def perceive(self, obs):
        return self.perception.step(obs)

    def remember(self, z, slot):
        self.memory.write(z, z, slot)
        return self.memory.read(z)["value"]

    def think(self, z):
        var t = none
        with no_grad():
            t = self.reasoning.reason(z)
        return t.data

    def plan_action(self, obs):
        return self.planner.mpc_step(obs)

    def integrate(self, obs, z, memory, thought):
        var state = self.consciousness.process([z, memory, thought])
        self.consciousness_log.append(state["winner"])
        return state["workspace"]

    def learn_from_experience(self, obs, reward):
        self.reward_history.append(reward)
        return self.ssl.train_step(obs, 0.001)

    def act(self, obs):
        self.step_count = self.step_count + 1
        var z = self.perceive(obs)
        var memory = self.remember(z, self.step_count)
        var thought = self.think(z)
        self.integrate(obs, z, memory, thought)
        return self.plan_action(obs)

    def introspect(self):
        var avg = 0.0
        var i = 0
        while i < len(self.reward_history):
            avg = avg + self.reward_history[i]
            i = i + 1
        if len(self.reward_history) > 0:
            avg = avg / float(len(self.reward_history))
        var ssl_loss = 0.0
        if len(self.ssl.loss_history) > 0:
            ssl_loss = self.ssl.loss_history[len(self.ssl.loss_history) - 1]
        return {
            "steps": self.step_count,
            "avg_reward": avg,
            "memory_reads": self.memory.n_reads,
            "memory_writes": self.memory.n_writes,
            "reasoning_steps": len(self.reasoning.thought_chain),
            "plans_made": self.planner.total_plans,
            "broadcasts": len(self.consciousness_log),
            "ssl_loss": ssl_loss,
            "name": self.name
        }

    def get_name(self):
        return self.name
