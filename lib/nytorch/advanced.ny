# ─── nytorch: parameter-efficient layers, mixture of experts, state space
# models, value/policy-gradient agents and graph convolution ───────────────
# All Modules on the Tensor autograd engine. (GraphSAGE, GATLayer and
# DDPMScheduler live in reinforcement.ny / sequence.ny.)

import "lib/nytorch/core.ny"

class UniformDist:
    def init(self, low, high):
        if high <= low:
            raise ValueError("UniformDist needs low < high")
        self.low = low
        self.high = high
    def sample(self, n):
        return Tensor(nt_uniform(n, self.low, self.high))
    def log_prob(self, x):
        if x < self.low or x > self.high:
            return nt_unary("log", [0.0])[0]
        return 0.0 - log(self.high - self.low)


# ---------------------------------------------
# SECTION 15: PARAMETER-EFFICIENT METHODS
# ---------------------------------------------

# LoRA (Hu et al. 2021): y = base(x) + (alpha / r) x A^T B^T with the base
# weights frozen; A (r, in) starts random, B (out, r) at zero, so training
# starts from the base model exactly.
class LoRALayer(Module):
    def __init__(self, in_dim, out_dim, rank, alpha):
        super().__init__()
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.rank = rank
        self.scale = float(alpha) / float(rank)
        self.base = Linear(in_dim, out_dim)
        self.base.requires_grad_(false)
        self.A = _l_uniform([rank, in_dim], 1.0 / sqrt(1.0 * in_dim))
        self.B = _l_const([out_dim, rank], 0.0)
    def forward(self, x):
        var t = _t_wrap(x)
        return self.base.forward(t) + _fn_linear(_fn_linear(t, self.A, none), self.B, none) * self.scale
    def lora_params(self):
        return [self.A, self.B]
    # the equivalent single weight W + (alpha / r) B A
    def merged_weight(self):
        return self.base.weight.detach() + self.B.detach().matmul(self.A.detach()) * self.scale

# Uniform affine fake quantisation of the weights to 2^bits levels, with a
# straight-through estimator so gradients reach the float weights.
class QuantizedLinear(Module):
    def __init__(self, in_dim, out_dim, bits):
        super().__init__()
        if bits < 1 or bits > 16:
            raise ValueError("QuantizedLinear bits must be in 1..16, got " + str(bits))
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.bits = bits
        self.n_levels = float(2 ** bits - 1)
        self.base = Linear(in_dim, out_dim)
        self.w_min = 0.0
        self.w_max = 0.0
        self.calibrated = false
    def calibrate(self):
        var w = self.base.weight
        self.w_min = w.min().item()
        self.w_max = w.max().item()
        self.calibrated = true
    def quantized_weight(self):
        if not self.calibrated:
            self.calibrate()
        var scale = (self.w_max - self.w_min) / self.n_levels
        if scale < 0.000000001:
            scale = 0.000000001
        var w = self.base.weight
        var q = ((w.detach() - self.w_min) * (1.0 / scale)).round().clamp(0.0, self.n_levels) * scale + self.w_min
        return w + (q - w.detach())
    def forward(self, x):
        return _fn_linear(_t_wrap(x), self.quantized_weight(), self.base.bias)

# Spectral normalisation (Miyato et al. 2018): W / sigma_max(W), sigma from
# power iteration with persistent vectors u, v.
class SpectralNorm(Module):
    def __init__(self, linear_layer, n_iter):
        super().__init__()
        self.layer = linear_layer
        self.n_iter = n_iter
        var u = Tensor(nt_randn(linear_layer.weight.shape[0]))
        var v = Tensor(nt_randn(linear_layer.weight.shape[1]))
        self.u = u.div(u.norm()).data
        self.v = v.div(v.norm()).data
    def sigma(self):
        var W = self.layer.weight.detach()
        var u = Tensor(self.u)
        var v = Tensor(self.v)
        var i = 0
        while i < self.n_iter:
            v = W.t().mv(u)
            v = v.div(v.norm())
            u = W.mv(v)
            u = u.div(u.norm())
            i = i + 1
        self.u = u.data
        self.v = v.data
        return u.dot(W.mv(v)).item()
    def forward(self, x):
        var sig = self.sigma()
        if sig < 0.000000001:
            sig = 0.000000001
        return _fn_linear(_t_wrap(x), self.layer.weight * (1.0 / sig), self.layer.bias)


# ---------------------------------------------
# SECTION 16: MIXTURE OF EXPERTS
# ---------------------------------------------

class Expert(Module):
    def __init__(self, in_dim, hidden_dim, out_dim):
        super().__init__()
        self.l1 = Linear(in_dim, hidden_dim)
        self.l2 = Linear(hidden_dim, out_dim)
    def forward(self, x):
        return self.l2.forward(self.l1.forward(x).gelu())

# Sparse top-k mixture (Shazeer et al. 2017): gate probabilities p, the k
# largest renormalised, output sum_k p_k / sum p * expert_k(x). Only the
# chosen experts run. last_gate holds the gate probabilities.
class MixtureOfExperts(Module):
    def __init__(self, num_experts, in_dim, hidden_dim, out_dim, top_k):
        super().__init__()
        if top_k < 1 or top_k > num_experts:
            raise ValueError("top_k must be in 1.." + str(num_experts))
        self.num_experts = num_experts
        self.top_k = top_k
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.gate = Linear(in_dim, num_experts)
        self.experts = []
        var i = 0
        while i < num_experts:
            self.experts.append(Expert(in_dim, hidden_dim, out_dim))
            i = i + 1
        self.last_gate = none
        self.expert_counts = nt_full([num_experts], 0.0)
    def _one(self, x):
        var probs = self.gate.forward(x).softmax(0)
        self.last_gate = probs.detach()
        var top = tensor_topk(_t_flat(probs.data), self.top_k)
        var idx = []
        var i = 0
        while i < len(top):
            idx.append(top[i]["index"])
            i = i + 1
        var w = probs.index_select(0, idx)
        w = w.div(w.sum())
        var out = none
        i = 0
        while i < len(idx):
            var y = self.experts[idx[i]].forward(x) * w.select(0, i)
            self.expert_counts[idx[i]] = self.expert_counts[idx[i]] + 1.0
            if out == none:
                out = y
            else:
                out = out + y
            i = i + 1
        return out
    # x (in_dim,) or (B, in_dim)
    def forward(self, x):
        var t = _t_wrap(x)
        if t.dim() == 1:
            return self._one(t)
        var rows = []
        var b = 0
        while b < t.size()[0]:
            rows.append(self._one(t.select(0, b)))
            b = b + 1
        return _t_stack(rows, 0)


# ---------------------------------------------
# SECTION 17: STATE SPACE MODELS
# ---------------------------------------------

# Diagonal state space layer (S4D, Gu et al. 2022), zero-order hold:
#   A_bar = exp(dt A),  B_bar = (A_bar - 1) / A * B,
#   h_t = A_bar h_(t-1) + B_bar x_t,  y_t = C h_t + D x_t
class S4Layer(Module):
    def __init__(self, d_model, state_dim):
        super().__init__()
        self.d_model = d_model
        self.state_dim = state_dim
        var a = []
        var n = 0
        while n < state_dim:
            a.append(log(0.5 + float(n)))
            n = n + 1
        self.A_log = Parameter(Tensor(a))
        self.B = _l_uniform([state_dim, d_model], 1.0 / sqrt(1.0 * d_model))
        self.C = _l_uniform([d_model, state_dim], 1.0 / sqrt(1.0 * state_dim))
        self.D = _l_const([d_model], 1.0)
        self.log_dt = _l_const([1], log(0.01))
    # a list of (d_model,) vectors or (L, d_model) -> list of (d_model,) outputs
    def forward(self, sequence):
        var A = self.A_log.exp().neg()
        var dA = (A * self.log_dt.exp()).exp()
        var dB = (dA - 1.0).div(A).unsqueeze(1) * self.B
        var h = Tensor(nt_full([self.state_dim], 0.0))
        var outputs = []
        var L = len(sequence)
        var i = 0
        while i < L:
            var x = _t_wrap(sequence[i])
            h = dA * h + dB.mv(x)
            outputs.append(self.C.mv(h) + self.D * x)
            i = i + 1
        return outputs

# A simplified Mamba block (Gu & Dao 2023) over one token: RMSNorm, in_proj
# to [x, z], the S4 layer on x, SiLU(z) gating, out_proj, residual. (The
# selective, input-dependent scan is MambaBlock in sequence.ny.)
class SimpleMambaBlock(Module):
    def __init__(self, d_model, state_dim, expand):
        super().__init__()
        self.d_model = d_model
        self.d_inner = int(float(d_model) * float(expand))
        self.in_proj = Linear(d_model, self.d_inner * 2)
        self.out_proj = Linear(self.d_inner, d_model)
        self.ssm = S4Layer(self.d_inner, state_dim)
        self.norm = RMSNorm(d_model)
    def forward(self, x):
        var t = _t_wrap(x)
        var proj = self.in_proj.forward(self.norm.forward(t))
        var h_in = proj.slice(0, 0, self.d_inner)
        var z = proj.slice(0, self.d_inner, 2 * self.d_inner)
        var h_out = self.ssm.forward([h_in])[0]
        return t + self.out_proj.forward(z.silu() * h_out)


# ---------------------------------------------
# SECTION 18: REINFORCEMENT LEARNING
# ---------------------------------------------

class RingReplayBuffer:
    def init(self, capacity):
        self.capacity = capacity
        self.buffer = []
        self.pos = 0
    def push(self, state, action, reward, next_state, done):
        if len(self.buffer) < self.capacity:
            self.buffer.append([state, action, reward, next_state, done])
        else:
            self.buffer[self.pos] = [state, action, reward, next_state, done]
        self.pos = (self.pos + 1) % self.capacity
    # batch_size transitions drawn uniformly with replacement
    def sample(self, batch_size):
        if len(self.buffer) == 0:
            raise ValueError("cannot sample from an empty replay buffer")
        var idx = nt_randint(0, len(self.buffer), batch_size)
        var batch = []
        var i = 0
        while i < batch_size:
            batch.append(self.buffer[idx[i]])
            i = i + 1
        return batch
    def __len__(self):
        return len(self.buffer)

# DQN (Mnih et al. 2015): epsilon-greedy acting, experience replay, and a
# periodically synchronised target network:
#   loss = mean (Q(s, a) - (r + gamma (1 - done) max_a' Q_target(s', a')))^2
class MLPDQNAgent:
    def init(self, state_dim, action_dim, hidden_dim, gamma, epsilon):
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.gamma = gamma
        self.epsilon = epsilon
        self.q_net = MLP([state_dim, hidden_dim, hidden_dim, action_dim], "relu")
        self.target_net = MLP([state_dim, hidden_dim, hidden_dim, action_dim], "relu")
        self.sync_target()
        self.buffer = RingReplayBuffer(10000)
        self.optimizer = Adam(self.q_net.parameters(), 0.001)
        self.steps = 0
        self.target_every = 100
    def sync_target(self):
        self.target_net.load_state_dict(self.q_net.state_dict())
    def q_values(self, state):
        var q = none
        with no_grad():
            q = self.q_net.forward(Tensor(state))
        return q.data
    def act(self, state):
        if nt_rand(1)[0] < self.epsilon:
            return nt_randint(0, self.action_dim, 1)[0]
        return Tensor(self.q_values(state)).argmax().item()
    def remember(self, state, action, reward, next_state, done):
        self.buffer.push(state, action, reward, next_state, done)
    # one gradient step on a replayed batch; returns the TD loss
    def update(self, batch_size):
        if len(self.buffer.buffer) < batch_size:
            return 0.0
        var batch = self.buffer.sample(batch_size)
        var s = []
        var a = []
        var y = []
        var i = 0
        while i < batch_size:
            var tr = batch[i]
            s.append(tr[0])
            a.append(tr[1])
            var target = 1.0 * tr[2]
            if not tr[4]:
                var qn = none
                with no_grad():
                    qn = self.target_net.forward(Tensor(tr[3]))
                target = target + self.gamma * qn.max().item()
            y.append(target)
            i = i + 1
        var q = self.q_net.forward(Tensor(s))
        var q_sa = (q * _fn_one_hot(a, self.action_dim)).sum(1)
        var loss = _fn_mse(q_sa, Tensor(y), "mean")
        self.optimizer.zero_grad()
        loss.backward()
        self.optimizer.step()
        self.steps = self.steps + 1
        if self.steps % self.target_every == 0:
            self.sync_target()
        return loss.item()
    def decay_epsilon(self, decay, min_eps):
        self.epsilon = self.epsilon * decay
        if self.epsilon < min_eps:
            self.epsilon = min_eps

# REINFORCE (Williams 1992) with normalised returns:
#   loss = -sum_t log pi(a_t | s_t) (G_t - mean G) / std G
class PolicyGradientAgent:
    def init(self, state_dim, action_dim, hidden_dim, lr, gamma):
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.gamma = gamma
        self.policy = MLP([state_dim, hidden_dim, action_dim], "relu")
        self.optimizer = Adam(self.policy.parameters(), lr)
        self.rewards = []
        self.log_probs = []
    def act(self, state):
        var lp = self.policy.forward(Tensor(state)).log_softmax(0)
        var p = lp.exp().data
        var u = nt_rand(1)[0]
        var cum = 0.0
        var a = self.action_dim - 1
        var i = 0
        while i < self.action_dim:
            cum = cum + p[i]
            if u <= cum:
                a = i
                break
            i = i + 1
        self.log_probs.append(lp.select(0, a))
        return a
    def remember_reward(self, r):
        self.rewards.append(r)
    def returns(self):
        var n = len(self.rewards)
        var G = nt_full([n], 0.0)
        var cum = 0.0
        var i = n - 1
        while i >= 0:
            cum = self.rewards[i] + self.gamma * cum
            G[i] = cum
            i = i - 1
        return G
    # one policy-gradient step on the finished episode; returns the loss
    def update(self):
        var n = len(self.log_probs)
        if n == 0 or n != len(self.rewards):
            raise ValueError("update needs one reward per action taken")
        var G = Tensor(self.returns())
        if n > 1:
            G = (G - G.mean()).div(G.std(none, false, 0) + 0.00000001)
        var lp = _t_stack(self.log_probs, 0)
        var loss = (lp * G).sum().neg()
        self.optimizer.zero_grad()
        loss.backward()
        self.optimizer.step()
        self.reset_episode()
        return loss.item()
    def reset_episode(self):
        self.rewards = []
        self.log_probs = []


# ---------------------------------------------
# SECTION 19: GRAPH NEURAL NETWORKS
# ---------------------------------------------

# h_v' = W ((h_v + mean_{u in N(v)} h_u) / 2); an isolated node keeps h_v.
# node_features: a list of N vectors or (N, in_dim); adjacency: neighbour lists
class GraphConv(Module):
    def __init__(self, in_dim, out_dim):
        super().__init__()
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.W = Linear(in_dim, out_dim)
    def forward(self, node_features, adjacency):
        var H = node_features
        if type(H) == "list":
            H = _t_stack(H, 0)
        H = _t_wrap(H)
        var n = H.size()[0]
        var rows = []
        var v = 0
        while v < n:
            var nb = adjacency[v]
            if len(nb) == 0:
                rows.append(H.select(0, v))
            else:
                rows.append((H.select(0, v) + H.index_select(0, nb).mean(0)) * 0.5)
            v = v + 1
        return self.W.forward(_t_stack(rows, 0))
