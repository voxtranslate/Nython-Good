# ---
# NyTorch - Part 16: sequence models and generative architectures
# Classes 291-320
#
#   RetNet (retention, parallel == recurrent), RWKV (time/channel mixing),
#   a selective state-space model (Mamba-1 style scan), DiT with adaLN,
#   DDPM/DDIM sampling, flow matching, an energy-based model with Langevin
#   sampling, mixture-of-depths routing, xLSTM (sLSTM and mLSTM cells),
#   cross-modal attention, RoPE, grouped-query attention with a KV cache,
#   sliding-window attention, a LLaMA-style decoder, VQ with EMA codebook
#   updates and an RLHF reward model.
#
# Everything is a Module on the Tensor autograd engine: parameters are
# discoverable, trainable and saveable. Recurrent state that the step APIs
# keep between calls (RWKV, SSM, xLSTM, RetNet) is detached between steps
# and exposed as flat lists (e.g. `tm.state_a`) for inspection.
# ---

import "lib/nytorch/core.ny"

# ── helpers ─────────────────────────────────────────────────────────────────

# a list of vectors, a single vector or an (L, d) tensor -> (L, d)
def _sq_rows(tokens):
    if type(tokens) == "list":
        if len(tokens) == 0:
            raise ValueError("empty token sequence")
        if _t_isnum(tokens[0]):
            return Tensor(tokens).unsqueeze(0)
        return _t_stack(tokens, 0)
    var t = _t_wrap(tokens)
    if t.dim() == 1:
        return t.unsqueeze(0)
    return t

# index drawn from a probability list with the seeded generator
def _sq_draw(probs):
    var u = nt_rand(1)[0]
    var c = 0.0
    var i = 0
    while i < len(probs):
        c = c + probs[i]
        if u <= c:
            return i
        i = i + 1
    return len(probs) - 1

# next token from a logits vector: argmax when `greedy` or temperature <= 0,
# else sampled from softmax(logits / T), restricted to the top_k logits
# when top_k > 0.
def _sq_pick(logits, temperature, top_k, greedy):
    var l = _t_flat(_t_wrap(logits).data)
    if greedy or temperature <= 0:
        return Tensor(l).argmax().item()
    var idx = []
    var vals = []
    if top_k > 0 and top_k < len(l):
        var top = tensor_topk(l, top_k)
        var i = 0
        while i < len(top):
            idx.append(top[i]["index"])
            vals.append(top[i]["value"])
            i = i + 1
    else:
        var j = 0
        while j < len(l):
            idx.append(j)
            vals.append(l[j])
            j = j + 1
    var p = nt_softmax(nt_binary("mul", vals, [len(vals)], 1.0 / temperature, [])[0], [len(vals)], 0, false)
    return idx[_sq_draw(p)]

def _sq_zeros(n):
    return nt_full([n], 0.0)

# additive band mask: query i (absolute position offset + i) sees key j
# when 0 <= (offset + i) - j < window (window <= 0: plain causal)
def _sq_band_mask(Lq, Lk, offset, window):
    var ninf = _a_neg_inf()
    var d = []
    var i = 0
    while i < Lq:
        var j = 0
        while j < Lk:
            var dist = offset + i - j
            if dist < 0 or (window > 0 and dist >= window):
                d.append(ninf)
            else:
                d.append(0.0)
            j = j + 1
        i = i + 1
    return Tensor(d, false, [Lq, Lk])


# ── 291: RetentionHead (Sun et al. 2023) ───────────────────────────────────
# Parallel form   O = (Q K^T * D) V,  D[n, m] = gamma^(n-m) for n >= m else 0
# Recurrent form  S_n = gamma S_(n-1) + k_n^T v_n,  o_n = q_n S_n
# The two are the same function; K is scaled by dim^-1/2.
class RetentionHead(Module):
    def __init__(self, dim, gamma, in_dim=none):
        super().__init__()
        var d_in = in_dim
        if d_in == none:
            d_in = dim
        self.dim = dim
        self.in_dim = d_in
        self.gamma = gamma
        self.W_Q = Linear(d_in, dim, false)
        self.W_K = Linear(d_in, dim, false)
        self.W_V = Linear(d_in, dim, false)
        self.recurrent_state = _sq_zeros(dim * dim)
        self.step = 0
        self.name = "RetentionHead"

    def project(self, x, W):
        return W.forward(_t_wrap(x))

    def causal_retention_score(self, n, m):
        if n >= m:
            return self.gamma ** float(n - m)
        return 0.0

    def decay_matrix(self, L):
        var d = []
        var n = 0
        while n < L:
            var m = 0
            while m < L:
                d.append(self.causal_retention_score(n, m))
                m = m + 1
            n = n + 1
        return Tensor(d, false, [L, L])

    # xs: a list of vectors or (L, in_dim) -> (L, dim)
    def forward_parallel(self, xs):
        var X = _sq_rows(xs)
        var L = X.size()[0]
        var Q = self.W_Q.forward(X)
        var K = self.W_K.forward(X) * (1.0 / sqrt(1.0 * self.dim))
        var V = self.W_V.forward(X)
        return (Q.matmul(K.t()) * self.decay_matrix(L)).matmul(V)

    def forward(self, xs):
        return self.forward_parallel(xs)

    # one token (in_dim,) -> (dim,), advancing the state
    def forward_recurrent(self, x):
        var xt = _t_wrap(x)
        var q = self.W_Q.forward(xt)
        var k = self.W_K.forward(xt) * (1.0 / sqrt(1.0 * self.dim))
        var v = self.W_V.forward(xt)
        var S = Tensor(self.recurrent_state, false, [self.dim, self.dim]) * self.gamma + k.outer(v)
        self.recurrent_state = S.detach().data
        self.step = self.step + 1
        return q.unsqueeze(0).matmul(S).squeeze(0)

    def reset_state(self):
        self.recurrent_state = _sq_zeros(self.dim * self.dim)
        self.step = 0

    def get_name(self):
        return self.name


# one RetNet layer: multi-scale retention (a gamma per head), swish gate,
# output projection, then a GELU feed-forward; pre-LayerNorm residuals.
class _RetNetLayer(Module):
    def __init__(self, d_model, n_heads, ffn_dim):
        super().__init__()
        self.d_model = d_model
        self.n_heads = n_heads
        var hd = d_model // n_heads
        self.heads = []
        var h = 0
        while h < n_heads:
            self.heads.append(RetentionHead(hd, 1.0 - 2.0 ** (0.0 - float(5 + h)), d_model))
            h = h + 1
        self.ln1 = LayerNorm(d_model)
        self.ln2 = LayerNorm(d_model)
        self.W_G = Linear(d_model, d_model, false)
        self.W_O = Linear(d_model, d_model, false)
        self.ffn1 = Linear(d_model, ffn_dim)
        self.ffn2 = Linear(ffn_dim, d_model)

    def _finish(self, x, xn, heads_out):
        var y = self.W_O.forward(self.W_G.forward(xn).silu() * heads_out)
        var h = x + y
        return h + self.ffn2.forward(self.ffn1.forward(self.ln2.forward(h)).gelu())

    def forward_parallel(self, X):
        var xn = self.ln1.forward(X)
        var outs = []
        var h = 0
        while h < len(self.heads):
            outs.append(self.heads[h].forward_parallel(xn))
            h = h + 1
        return self._finish(X, xn, torch.cat(outs, 1))

    def forward_recurrent(self, x):
        var xn = self.ln1.forward(x)
        var outs = []
        var h = 0
        while h < len(self.heads):
            outs.append(self.heads[h].forward_recurrent(xn))
            h = h + 1
        return self._finish(x, xn, torch.cat(outs, 0))

    def reset_state(self):
        var h = 0
        while h < len(self.heads):
            self.heads[h].reset_state()
            h = h + 1


# ── 292: RetNet (Retentive Network) ────────────────────────────────────────
class RetNet(Module):
    def __init__(self, d_model, n_layers, n_heads, ffn_dim, vocab_size):
        super().__init__()
        if d_model % n_heads != 0:
            raise ValueError("RetNet: d_model " + str(d_model) + " must be divisible by n_heads " + str(n_heads))
        self.d_model = d_model
        self.n_layers = n_layers
        self.n_heads = n_heads
        self.ffn_dim = ffn_dim
        self.vocab_size = vocab_size
        self.embed = Embedding(vocab_size, d_model)
        self.layers = []
        var i = 0
        while i < n_layers:
            self.layers.append(_RetNetLayer(d_model, n_heads, ffn_dim))
            i = i + 1
        self.ln_f = LayerNorm(d_model)
        self.lm_head = Linear(d_model, vocab_size, false)
        self.name = "RetNet"

    def embed_tokens(self, token_ids):
        return self.embed.forward(token_ids)

    # all positions at once: token ids -> (L, vocab_size) logits
    def forward_parallel(self, token_ids):
        var h = self.embed_tokens(token_ids)
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward_parallel(h)
            i = i + 1
        return self.lm_head.forward(self.ln_f.forward(h))

    def forward(self, token_ids):
        return self.forward_parallel(token_ids)

    def reset_state(self):
        var i = 0
        while i < len(self.layers):
            self.layers[i].reset_state()
            i = i + 1

    def step_token(self, token_id):
        var x = self.embed.forward(token_id)
        var i = 0
        while i < len(self.layers):
            x = self.layers[i].forward_recurrent(x)
            i = i + 1
        return self.lm_head.forward(self.ln_f.forward(x))

    # token by token in O(1) memory per step: a list of (vocab_size,) logits
    def forward_recurrent(self, token_ids):
        self.reset_state()
        var out = []
        var i = 0
        while i < len(token_ids):
            out.append(self.step_token(token_ids[i]))
            i = i + 1
        return out

    # greedy continuation, recurrent mode
    def generate(self, prompt_ids, max_new_tokens):
        var ids = []
        var logits = none
        with no_grad():
            self.reset_state()
            var i = 0
            while i < len(prompt_ids):
                ids.append(prompt_ids[i])
                logits = self.step_token(prompt_ids[i])
                i = i + 1
            var n = 0
            while n < max_new_tokens:
                var nxt = _sq_pick(logits, 1.0, 0, true)
                ids.append(nxt)
                logits = self.step_token(nxt)
                n = n + 1
        return ids

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 293: RWKVTimeMix (RWKV-4, Peng et al. 2023) ────────────────────────────
# Token shift, then the WKV recurrence with per-channel decay w = -exp(decay)
# and a bonus u for the current token, computed in the numerically stable
# form (running exponent pp):
#   wkv = (e^(pp-p) a + e^(u+k-p) v) / (e^(pp-p) b + e^(u+k-p)),  p = max(pp, u+k)
class RWKVTimeMix(Module):
    def __init__(self, dim, layer_id):
        super().__init__()
        self.dim = dim
        self.layer_id = layer_id
        var decay = []
        var first = []
        var i = 0
        while i < dim:
            var r = 0.0
            if dim > 1:
                r = float(i) / float(dim - 1)
            decay.append(-5.0 + 8.0 * (r ** 0.7))
            first.append(log(0.3) + 0.5 * float((i + 1) % 3 - 1))
            i = i + 1
        self.time_decay = Parameter(Tensor(decay))
        self.time_first = Parameter(Tensor(first))
        self.mix_k = Parameter(Tensor(nt_rand(dim)))
        self.mix_v = Parameter(Tensor(nt_rand(dim)))
        self.mix_r = Parameter(Tensor(nt_rand(dim)))
        self.W_K = Linear(dim, dim, false)
        self.W_V = Linear(dim, dim, false)
        self.W_R = Linear(dim, dim, false)
        self.W_O = Linear(dim, dim, false)
        self.reset()
        self.name = "RWKVTimeMix"

    # x * mix + prev_x * (1 - mix)
    def channel_mix_interpolate(self, x, prev_x, mix):
        var px = _t_wrap(prev_x)
        return px + (_t_wrap(x) - px) * mix

    def forward(self, x):
        var xt = _t_wrap(x)
        var px = Tensor(self.prev_x)
        var k = self.W_K.forward(self.channel_mix_interpolate(xt, px, self.mix_k))
        var v = self.W_V.forward(self.channel_mix_interpolate(xt, px, self.mix_v))
        var r = self.W_R.forward(self.channel_mix_interpolate(xt, px, self.mix_r)).sigmoid()
        var aa = Tensor(self.state_a)
        var bb = Tensor(self.state_b)
        var pp = Tensor(self.state_p)
        var ww = self.time_first + k
        var p = pp.maximum(ww)
        var e1 = (pp - p).exp()
        var e2 = (ww - p).exp()
        var wkv = (e1 * aa + e2 * v).div(e1 * bb + e2)
        var out = self.W_O.forward(r * wkv)
        # state update with decay
        var ww2 = pp + self.time_decay.exp().neg()
        var p2 = ww2.maximum(k)
        var f1 = (ww2 - p2).exp()
        var f2 = (k - p2).exp()
        self.state_a = (f1 * aa + f2 * v).detach().data
        self.state_b = (f1 * bb + f2).detach().data
        self.state_p = p2.detach().data
        self.prev_x = xt.detach().data
        return out

    def reset(self):
        self.prev_x = _sq_zeros(self.dim)
        self.state_a = _sq_zeros(self.dim)
        self.state_b = _sq_zeros(self.dim)
        self.state_p = nt_full([self.dim], 0.0 - 1e38)

    def get_name(self):
        return self.name


# ── 294: RWKVChannelMix ────────────────────────────────────────────────────
# r = sigmoid(W_R xr), k = relu(W_K xk)^2, out = r * W_V k (token-shifted inputs)
class RWKVChannelMix(Module):
    def __init__(self, dim, ffn_dim):
        super().__init__()
        self.dim = dim
        self.ffn_dim = ffn_dim
        self.mix_k = Parameter(Tensor(nt_rand(dim)))
        self.mix_r = Parameter(Tensor(nt_rand(dim)))
        self.W_K = Linear(dim, ffn_dim, false)
        self.W_V = Linear(ffn_dim, dim, false)
        self.W_R = Linear(dim, dim, false)
        self.prev_x = _sq_zeros(dim)
        self.name = "RWKVChannelMix"

    def forward(self, x):
        var xt = _t_wrap(x)
        var px = Tensor(self.prev_x)
        var xk = px + (xt - px) * self.mix_k
        var xr = px + (xt - px) * self.mix_r
        var r = self.W_R.forward(xr).sigmoid()
        var k = self.W_K.forward(xk).relu().square()
        self.prev_x = xt.detach().data
        return r * self.W_V.forward(k)

    def reset(self):
        self.prev_x = _sq_zeros(self.dim)

    def get_name(self):
        return self.name


# ── 295: RWKVBlock ─────────────────────────────────────────────────────────
class RWKVBlock(Module):
    def __init__(self, dim, ffn_dim, layer_id):
        super().__init__()
        self.dim = dim
        self.ffn_dim = ffn_dim
        self.layer_id = layer_id
        self.time_mix = RWKVTimeMix(dim, layer_id)
        self.channel_mix = RWKVChannelMix(dim, ffn_dim)
        self.ln1 = LayerNorm(dim)
        self.ln2 = LayerNorm(dim)
        self.name = "RWKVBlock"

    def forward(self, x):
        var h = _t_wrap(x)
        h = h + self.time_mix.forward(self.ln1.forward(h))
        return h + self.channel_mix.forward(self.ln2.forward(h))

    def reset(self):
        self.time_mix.reset()
        self.channel_mix.reset()

    def get_name(self):
        return self.name


# ── 296: RWKV ──────────────────────────────────────────────────────────────
class RWKV(Module):
    def __init__(self, d_model, n_layers, ffn_mult, vocab_size):
        super().__init__()
        self.d_model = d_model
        self.n_layers = n_layers
        self.ffn_mult = ffn_mult
        self.vocab_size = vocab_size
        self.ffn_dim = int(d_model * ffn_mult)
        self.emb = Embedding(vocab_size, d_model)
        self.ln0 = LayerNorm(d_model)
        self.blocks = []
        var i = 0
        while i < n_layers:
            self.blocks.append(RWKVBlock(d_model, self.ffn_dim, i))
            i = i + 1
        self.ln_out = LayerNorm(d_model)
        self.head = Linear(d_model, vocab_size, false)
        self.name = "RWKV"

    def embed(self, token_id):
        if token_id < 0 or token_id >= self.vocab_size:
            raise IndexError("token id " + str(token_id) + " out of range for vocab " + str(self.vocab_size))
        return self.emb.forward(token_id)

    # one step of the recurrent model: token id -> (vocab_size,) logits
    def forward_token(self, token_id):
        var x = self.ln0.forward(self.embed(token_id))
        var i = 0
        while i < len(self.blocks):
            x = self.blocks[i].forward(x)
            i = i + 1
        return self.head.forward(self.ln_out.forward(x))

    # all tokens in order from a fresh state -> logits of the last one
    def forward(self, token_ids):
        self.reset_state()
        var logits = none
        var i = 0
        while i < len(token_ids):
            logits = self.forward_token(token_ids[i])
            i = i + 1
        return logits

    # temperature <= 0: greedy; otherwise sampled from softmax(logits / T)
    def generate(self, prompt_ids, max_new_tokens, temperature):
        var ids = []
        with no_grad():
            var logits = self.forward(prompt_ids)
            var i = 0
            while i < len(prompt_ids):
                ids.append(prompt_ids[i])
                i = i + 1
            var n = 0
            while n < max_new_tokens:
                var nxt = _sq_pick(logits, temperature, 0, false)
                ids.append(nxt)
                logits = self.forward_token(nxt)
                n = n + 1
        return ids

    def reset_state(self):
        var i = 0
        while i < len(self.blocks):
            self.blocks[i].reset()
            i = i + 1

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 297: SelectiveSSM (Mamba's selective scan, Gu & Dao 2023) ───────────────
# Per step, from the input x (dim,):
#   [dt_in, B, C] = x_proj(x);  dt = softplus(dt_proj(dt_in))       (dim,)
#   A = -exp(A_log) (dim, N);   h = exp(dt A) * h + (dt B) x;  y = h C + D x
class SelectiveSSM(Module):
    def __init__(self, dim, state_dim, dt_rank):
        super().__init__()
        self.dim = dim
        self.state_dim = state_dim
        self.dt_rank = dt_rank
        # S4D-real initialisation: A = -[1, 2, ..., N] for every channel
        var a = []
        var i = 0
        while i < dim:
            var n = 0
            while n < state_dim:
                a.append(log(float(n + 1)))
                n = n + 1
            i = i + 1
        self.A_log = Parameter(Tensor(a, false, [dim, state_dim]))
        self.D = _l_const([dim], 1.0)
        self.x_proj = Linear(dim, dt_rank + 2 * state_dim, false)
        self.dt_proj = Linear(dt_rank, dim)
        self.h = _sq_zeros(dim * state_dim)
        self.name = "SelectiveSSM"

    # zero-order hold for A: exp(dt * A), dt (dim,) and A (dim, N)
    def discretize(self, dt, A):
        return (_t_wrap(dt).unsqueeze(1) * _t_wrap(A)).exp()

    # one step from state h (dim, N): returns [y (dim,), new h]
    def _step(self, xt, h):
        var p = self.x_proj.forward(xt)
        var dt = self.dt_proj.forward(p.slice(0, 0, self.dt_rank)).softplus()
        var B = p.slice(0, self.dt_rank, self.dt_rank + self.state_dim)
        var C = p.slice(0, self.dt_rank + self.state_dim, self.dt_rank + 2 * self.state_dim)
        var A = self.A_log.exp().neg()
        var dA = self.discretize(dt, A)
        var dBx = (dt * xt).unsqueeze(1) * B.unsqueeze(0)
        var h2 = dA * h + dBx
        var y = h2.matmul(C.unsqueeze(1)).squeeze(1) + self.D * xt
        return [y, h2]

    def selective_scan_step(self, x):
        var r = self._step(_t_wrap(x), Tensor(self.h, false, [self.dim, self.state_dim]))
        self.h = r[1].detach().data
        return r[0]

    def forward(self, x):
        return self.selective_scan_step(x)

    # a whole sequence (L, dim) from a zero state, keeping the graph through
    # time (for training): -> (L, dim)
    def forward_sequence(self, xs):
        var X = _sq_rows(xs)
        var h = Tensor(_sq_zeros(self.dim * self.state_dim), false, [self.dim, self.state_dim])
        var ys = []
        var t = 0
        while t < X.size()[0]:
            var r = self._step(X.select(0, t), h)
            ys.append(r[0])
            h = r[1]
            t = t + 1
        return _t_stack(ys, 0)

    def reset(self):
        self.h = _sq_zeros(self.dim * self.state_dim)

    def get_name(self):
        return self.name


# ── 298: MambaBlock ────────────────────────────────────────────────────────
# RMSNorm -> in_proj to [x, z] -> causal depthwise conv over the last d_conv
# inputs -> SiLU -> selective SSM -> gate with SiLU(z) -> out_proj, residual.
class MambaBlock(Module):
    def __init__(self, dim, state_dim, dt_rank, d_conv, expand):
        super().__init__()
        self.dim = dim
        self.state_dim = state_dim
        self.dt_rank = dt_rank
        self.d_conv = d_conv
        self.expand = expand
        self.d_inner = int(dim * expand)
        self.norm = RMSNorm(dim)
        self.in_proj = Linear(dim, self.d_inner * 2, false)
        self.conv_w = _l_uniform([self.d_inner, d_conv], 1.0 / sqrt(1.0 * d_conv))
        self.conv_b = _l_const([self.d_inner], 0.0)
        self.ssm = SelectiveSSM(self.d_inner, state_dim, dt_rank)
        self.out_proj = Linear(self.d_inner, dim, false)
        self.conv_state = []
        self.name = "MambaBlock"

    def _conv_step(self, xi):
        # window of the last d_conv inputs (zeros before the start)
        var rows = []
        var pad = self.d_conv - 1 - len(self.conv_state)
        var i = 0
        while i < pad:
            rows.append(Tensor(_sq_zeros(self.d_inner)))
            i = i + 1
        i = 0
        while i < len(self.conv_state):
            rows.append(Tensor(self.conv_state[i]))
            i = i + 1
        rows.append(xi)
        var W = _t_stack(rows, 1)
        self.conv_state.append(xi.detach().data)
        if len(self.conv_state) > self.d_conv - 1:
            self.conv_state = self.conv_state[1:]
        return (W * self.conv_w).sum(1) + self.conv_b

    def forward(self, x):
        var xt = _t_wrap(x)
        var xz = self.in_proj.forward(self.norm.forward(xt))
        var xi = xz.slice(0, 0, self.d_inner)
        var z = xz.slice(0, self.d_inner, 2 * self.d_inner)
        var xc = self._conv_step(xi).silu()
        var y = self.ssm.forward(xc) * z.silu()
        return xt + self.out_proj.forward(y)

    def reset(self):
        self.ssm.reset()
        self.conv_state = []

    def get_name(self):
        return self.name


# ── 299: Mamba2 ────────────────────────────────────────────────────────────
# A Mamba language model: embedding, MambaBlocks, RMSNorm, LM head. (The
# blocks use Mamba-1's selective scan; Mamba-2's SSD chunked form is not
# implemented.)
class Mamba2(Module):
    def __init__(self, d_model, n_layers, state_dim, vocab_size):
        super().__init__()
        self.d_model = d_model
        self.n_layers = n_layers
        self.state_dim = state_dim
        self.vocab_size = vocab_size
        self.embed = Embedding(vocab_size, d_model)
        self.blocks = []
        var r = d_model // 16
        if r < 1:
            r = 1
        var i = 0
        while i < n_layers:
            self.blocks.append(MambaBlock(d_model, state_dim, r, 4, 2))
            i = i + 1
        self.norm_f = RMSNorm(d_model)
        self.lm_head = Linear(d_model, vocab_size, false)
        self.name = "Mamba2"

    def reset(self):
        var i = 0
        while i < len(self.blocks):
            self.blocks[i].reset()
            i = i + 1

    def step_token(self, token_id):
        var h = self.embed.forward(token_id)
        var i = 0
        while i < len(self.blocks):
            h = self.blocks[i].forward(h)
            i = i + 1
        return self.lm_head.forward(self.norm_f.forward(h))

    # token ids from a fresh state -> logits (vocab_size,) after the last one
    def forward(self, token_ids):
        self.reset()
        var logits = none
        var i = 0
        while i < len(token_ids):
            logits = self.step_token(token_ids[i])
            i = i + 1
        return logits

    def generate(self, prompt_ids, max_new_tokens, temperature):
        var ids = []
        with no_grad():
            var logits = self.forward(prompt_ids)
            var i = 0
            while i < len(prompt_ids):
                ids.append(prompt_ids[i])
                i = i + 1
            var n = 0
            while n < max_new_tokens:
                var nxt = _sq_pick(logits, temperature, 0, false)
                ids.append(nxt)
                logits = self.step_token(nxt)
                n = n + 1
        return ids

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 300: DiTBlock (Peebles & Xie 2023) ─────────────────────────────────────
# adaLN: the conditioning vector c yields shift/scale/gate for the attention
# and MLP branches:  x += gate_msa * Attn(LN(x) (1 + scale) + shift), same
# for the MLP. (The modulation starts small rather than exactly zero so an
# untrained block still responds to c.)
class DiTBlock(Module):
    def __init__(self, hidden_dim, n_heads, mlp_ratio, time_embed_dim):
        super().__init__()
        self.hidden_dim = hidden_dim
        self.n_heads = n_heads
        self.mlp_ratio = mlp_ratio
        self.time_embed_dim = time_embed_dim
        self.mlp_dim = int(hidden_dim * mlp_ratio)
        self.adaLN = Linear(time_embed_dim, 6 * hidden_dim)
        nt_scale_(self.adaLN.weight.data, 0.1)
        self.norm1 = LayerNorm(hidden_dim, 0.000001, false)
        self.norm2 = LayerNorm(hidden_dim, 0.000001, false)
        self.attn = MultiheadAttention(hidden_dim, n_heads)
        self.mlp1 = Linear(hidden_dim, self.mlp_dim)
        self.mlp2 = Linear(self.mlp_dim, hidden_dim)
        self.name = "DiTBlock"

    def adaln_modulate(self, x, shift, scale):
        return x * (scale + 1.0) + shift

    def self_attention(self, x):
        return self.attn.forward(x, x, x, none, none)[0]

    def mlp_forward(self, x):
        return self.mlp2.forward(self.mlp1.forward(x).gelu())

    # x: (N, hidden) tokens or one (hidden,) token; t_emb: (time_embed_dim,)
    def forward(self, x, t_emb):
        var X = _t_wrap(x)
        var single = X.dim() == 1
        if single:
            X = X.unsqueeze(0)
        var h = self.hidden_dim
        var mod = self.adaLN.forward(_t_wrap(t_emb).silu())
        var shift_msa = mod.slice(0, 0, h)
        var scale_msa = mod.slice(0, h, 2 * h)
        var gate_msa = mod.slice(0, 2 * h, 3 * h)
        var shift_mlp = mod.slice(0, 3 * h, 4 * h)
        var scale_mlp = mod.slice(0, 4 * h, 5 * h)
        var gate_mlp = mod.slice(0, 5 * h, 6 * h)
        X = X + gate_msa * self.self_attention(self.adaln_modulate(self.norm1.forward(X), shift_msa, scale_msa))
        X = X + gate_mlp * self.mlp_forward(self.adaln_modulate(self.norm2.forward(X), shift_mlp, scale_mlp))
        if single:
            return X.squeeze(0)
        return X

    def get_name(self):
        return self.name


# ── 301: DiffusionTransformer (DiT) ────────────────────────────────────────
# A 1-d signal of input_dim values is cut into input_dim / patch_size patches,
# embedded, conditioned on (timestep, class) through adaLN, and mapped back
# to a noise prediction of the same size. class_id < 0 is the null class
# used for classifier-free guidance.
class DiffusionTransformer(Module):
    def __init__(self, input_dim, patch_size, hidden_dim, n_heads, n_layers, n_classes, time_embed_dim):
        super().__init__()
        if input_dim % patch_size != 0:
            raise ValueError("DiT: input_dim " + str(input_dim) + " is not a multiple of patch_size " + str(patch_size))
        self.input_dim = input_dim
        self.patch_size = patch_size
        self.hidden_dim = hidden_dim
        self.n_heads = n_heads
        self.n_layers = n_layers
        self.n_classes = n_classes
        self.time_embed_dim = time_embed_dim
        self.n_patches = input_dim // patch_size
        self.patch_embed = Linear(patch_size, hidden_dim)
        var ps = [self.n_patches, hidden_dim]
        self.pos_embed = Parameter(Tensor(nt_normal(ps, 0.0, 0.02), false, ps))
        self.t_mlp1 = Linear(time_embed_dim, time_embed_dim)
        self.t_mlp2 = Linear(time_embed_dim, time_embed_dim)
        self.class_embed = Embedding(n_classes + 1, time_embed_dim)
        self.blocks = []
        var i = 0
        while i < n_layers:
            self.blocks.append(DiTBlock(hidden_dim, n_heads, 4.0, time_embed_dim))
            i = i + 1
        self.final_norm = LayerNorm(hidden_dim, 0.000001, false)
        self.final_adaLN = Linear(time_embed_dim, 2 * hidden_dim)
        nt_scale_(self.final_adaLN.weight.data, 0.1)
        self.final_linear = Linear(hidden_dim, patch_size)
        self.name = "DiffusionTransformer"

    # sinusoidal embedding of a (possibly fractional) timestep -> (dim,)
    def timestep_embedding(self, t, dim):
        var half = dim // 2
        var e = []
        var i = 0
        while i < half:
            var f = exp(0.0 - log(10000.0) * float(i) / float(half))
            e.append(cos(float(t) * f))
            i = i + 1
        i = 0
        while i < half:
            var f2 = exp(0.0 - log(10000.0) * float(i) / float(half))
            e.append(sin(float(t) * f2))
            i = i + 1
        if dim % 2 == 1:
            e.append(0.0)
        return Tensor(e)

    def class_conditioning(self, class_id):
        if class_id < 0 or class_id >= self.n_classes:
            return self.class_embed.forward(self.n_classes)
        return self.class_embed.forward(class_id)

    def condition(self, t, class_id):
        var te = self.t_mlp2.forward(self.t_mlp1.forward(self.timestep_embedding(t, self.time_embed_dim)).silu())
        return te + self.class_conditioning(class_id)

    # x_noisy (input_dim,) -> predicted noise (input_dim,)
    def forward(self, x_noisy, t, class_id):
        var x = _t_wrap(x_noisy)
        if x.numel() != self.input_dim:
            raise ValueError("DiT expects " + str(self.input_dim) + " values, got " + str(x.numel()))
        var c = self.condition(t, class_id)
        var tokens = self.patch_embed.forward(x.reshape([self.n_patches, self.patch_size])) + self.pos_embed
        var i = 0
        while i < len(self.blocks):
            tokens = self.blocks[i].forward(tokens, c)
            i = i + 1
        var m = self.final_adaLN.forward(c.silu())
        var shift = m.slice(0, 0, self.hidden_dim)
        var scale = m.slice(0, self.hidden_dim, 2 * self.hidden_dim)
        var out = self.final_linear.forward(self.final_norm.forward(tokens) * (scale + 1.0) + shift)
        return out.reshape([self.input_dim])

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 302: DDPMScheduler (Ho et al. 2020; cosine schedule: Nichol & Dhariwal 2021)
class DDPMScheduler:
    def __init__(self, n_timesteps, beta_start, beta_end, schedule="linear"):
        if schedule != "linear" and schedule != "cosine":
            raise ValueError("DDPMScheduler schedule must be 'linear' or 'cosine', got '" + str(schedule) + "'")
        self.n_timesteps = n_timesteps
        self.T = n_timesteps
        self.beta_start = beta_start
        self.beta_end = beta_end
        self.schedule = schedule
        self.betas = self._compute_betas()
        self.alphas = []
        self.alphas_cumprod = []
        var ab = 1.0
        var i = 0
        while i < n_timesteps:
            var a = 1.0 - self.betas[i]
            ab = ab * a
            self.alphas.append(a)
            self.alphas_cumprod.append(ab)
            i = i + 1
        self.alpha_bars = self.alphas_cumprod
        self.name = "DDPMScheduler"

    def _compute_betas(self):
        var T = self.n_timesteps
        var betas = []
        var i = 0
        if self.schedule == "cosine":
            var s = 0.008
            while i < T:
                var f0 = cos(((float(i) / float(T)) + s) / (1.0 + s) * 3.141592653589793 / 2.0)
                var f1 = cos(((float(i + 1) / float(T)) + s) / (1.0 + s) * 3.141592653589793 / 2.0)
                betas.append(min(1.0 - (f1 * f1) / (f0 * f0), 0.999))
                i = i + 1
            return betas
        while i < T:
            if T == 1:
                betas.append(self.beta_start)
            else:
                betas.append(self.beta_start + (self.beta_end - self.beta_start) * float(i) / float(T - 1))
            i = i + 1
        return betas

    def _check_t(self, t):
        if t < 0 or t >= self.n_timesteps:
            raise IndexError("timestep " + str(t) + " out of range for " + str(self.n_timesteps) + " steps")

    # q(x_t | x_0): sqrt(abar_t) x0 + sqrt(1 - abar_t) noise (noise drawn if none)
    def add_noise(self, x0, t, noise=none):
        self._check_t(t)
        var x = _t_wrap(x0).detach()
        var eps = noise
        if eps == none:
            eps = Tensor(nt_randn(x.shape), false, x.shape)
        eps = _t_wrap(eps)
        var ab = self.alphas_cumprod[t]
        return x * sqrt(ab) + eps * sqrt(1.0 - ab)

    def predict_x0(self, xt, noise_pred, t):
        self._check_t(t)
        var ab = self.alphas_cumprod[t]
        return (_t_wrap(xt) - _t_wrap(noise_pred) * sqrt(1.0 - ab)) * (1.0 / sqrt(ab))

    # one ancestral DDPM step t -> t-1:
    #   mean = (x_t - beta_t / sqrt(1 - abar_t) eps) / sqrt(alpha_t),
    #   plus sigma_t z with the posterior variance beta_t (1 - abar_(t-1)) / (1 - abar_t)
    def step(self, noise_pred, t, xt):
        self._check_t(t)
        var x = _t_wrap(xt)
        var beta = self.betas[t]
        var ab = self.alphas_cumprod[t]
        var mean = (x - _t_wrap(noise_pred) * (beta / sqrt(1.0 - ab))) * (1.0 / sqrt(self.alphas[t]))
        if t == 0:
            return mean
        var ab_prev = self.alphas_cumprod[t - 1]
        var sigma = sqrt(beta * (1.0 - ab_prev) / (1.0 - ab))
        return mean + Tensor(nt_randn(x.shape), false, x.shape) * sigma

    # the same step under the (x_t, eps, t) argument order
    def denoise_step(self, x_t, pred_noise, t):
        return self.step(pred_noise, t, x_t)

    # deterministic DDIM step (eta = 0) from t to t_prev (t_prev < 0: to x0)
    def ddim_step(self, noise_pred, t, t_prev, xt):
        var x0 = self.predict_x0(xt, noise_pred, t)
        if t_prev < 0:
            return x0
        var ab_prev = self.alphas_cumprod[t_prev]
        return x0 * sqrt(ab_prev) + _t_wrap(noise_pred) * sqrt(1.0 - ab_prev)

    def get_name(self):
        return self.name


# ── 303: DiffusionPipeline ─────────────────────────────────────────────────
# Sampling with n_inference_steps evenly spaced timesteps (DDIM updates,
# since the steps skip timesteps) and classifier-free guidance:
#   eps = eps_uncond + g (eps_cond - eps_uncond)
class DiffusionPipeline:
    def __init__(self, model, scheduler, n_inference_steps):
        self.model = model
        self.scheduler = scheduler
        self.n_inference_steps = n_inference_steps
        self.generated = []
        self.name = "DiffusionPipeline"

    def timesteps(self):
        var T = self.scheduler.n_timesteps
        var n = self.n_inference_steps
        if n > T:
            n = T
        var ts = []
        var i = 0
        while i < n:
            ts.append(T - 1 - (i * T) // n)
            i = i + 1
        return ts

    def generate(self, class_id, guidance_scale, latent_dim):
        var x = Tensor(nt_randn(latent_dim))
        var ts = self.timesteps()
        with no_grad():
            var i = 0
            while i < len(ts):
                var t = ts[i]
                var eps = self.model.forward(x, t, class_id)
                if guidance_scale != 1.0:
                    var eps_u = self.model.forward(x, t, -1)
                    eps = eps_u + (eps - eps_u) * guidance_scale
                var t_prev = -1
                if i + 1 < len(ts):
                    t_prev = ts[i + 1]
                x = self.scheduler.ddim_step(eps, t, t_prev, x)
                i = i + 1
        self.generated.append(x)
        return x

    def get_name(self):
        return self.name


# ── 304: FlowMatchingModel (Lipman et al. 2023) ────────────────────────────
# Optimal-transport probability path  x_t = (1 - (1 - s) t) x0 + t x1,
# target velocity u = x1 - (1 - s) x0 (s = sigma_min); a time-conditioned
# MLP v(x, t) regresses u, and sampling integrates dx/dt = v from noise.
class FlowMatchingModel(Module):
    def __init__(self, data_dim, hidden_dim, n_layers, sigma_min):
        super().__init__()
        self.data_dim = data_dim
        self.hidden_dim = hidden_dim
        self.n_layers = n_layers
        self.sigma_min = sigma_min
        self.layers = []
        var d_in = data_dim + 1
        var i = 0
        while i < n_layers:
            self.layers.append(Linear(d_in, hidden_dim))
            d_in = hidden_dim
            i = i + 1
        self.out = Linear(d_in, data_dim)
        self.loss_history = []
        self.opt = none
        self.name = "FlowMatchingModel"

    # v(x, t): x (data_dim,) or (B, data_dim)
    def velocity(self, x, t):
        var X = _t_wrap(x)
        var single = X.dim() == 1
        if single:
            X = X.unsqueeze(0)
        var B = X.size()[0]
        var tcol = Tensor(nt_full([B], float(t)), false, [B, 1])
        var h = torch.cat([X, tcol], 1)
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h).silu()
            i = i + 1
        var v = self.out.forward(h)
        if single:
            return v.squeeze(0)
        return v

    def conditional_flow(self, x1, x0, t):
        return _t_wrap(x0) * (1.0 - (1.0 - self.sigma_min) * t) + _t_wrap(x1) * t

    def target_velocity(self, x1, x0):
        return _t_wrap(x1) - _t_wrap(x0) * (1.0 - self.sigma_min)

    # differentiable loss for one data point (or batch) at time t
    def loss_tensor(self, x1, t, x0=none):
        var X1 = _t_wrap(x1)
        var noise = x0
        if noise == none:
            noise = Tensor(nt_randn(X1.shape), false, X1.shape)
        var xt = self.conditional_flow(X1, noise, t)
        var diff = self.velocity(xt, t) - self.target_velocity(X1, noise)
        return (diff * diff).mean()

    def flow_matching_loss(self, x1_batch, t):
        var l = self.loss_tensor(x1_batch, t, none).item()
        self.loss_history.append(l)
        return l

    # Adam on the flow-matching objective with t ~ U(0, 1); data: (N, data_dim)
    def fit(self, data, steps, lr):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        var D = _sq_rows(data)
        var n = D.size()[0]
        var last = 0.0
        var s = 0
        while s < steps:
            var t = nt_rand(1)[0]
            var idx = nt_randint(0, n, 1)[0]
            self.opt.zero_grad()
            var loss = self.loss_tensor(D.select(0, idx), t, none)
            loss.backward()
            self.opt.step()
            last = loss.item()
            self.loss_history.append(last)
            s = s + 1
        return last

    # Euler integration of dx/dt = v(x, t) from x0 ~ N(0, I)
    def sample(self, n_steps):
        var x = Tensor(nt_randn(self.data_dim))
        var dt = 1.0 / float(n_steps)
        with no_grad():
            var i = 0
            while i < n_steps:
                x = x + self.velocity(x, float(i) * dt) * dt
                i = i + 1
        return x

    def get_name(self):
        return self.name


# ── 305: EnergyBasedModel ──────────────────────────────────────────────────
# E(x) is an MLP; samples come from Langevin dynamics on grad_x E:
#   x <- x - step * grad_x E(x) + sqrt(2 step) z
class EnergyBasedModel(Module):
    def __init__(self, input_dim, hidden_dim, n_layers):
        super().__init__()
        self.input_dim = input_dim
        self.hidden_dim = hidden_dim
        self.n_layers = n_layers
        self.layers = []
        var d_in = input_dim
        var i = 0
        while i < n_layers:
            self.layers.append(Linear(d_in, hidden_dim))
            d_in = hidden_dim
            i = i + 1
        self.out = Linear(d_in, 1)
        self.mcmc_step_size = 0.01
        self.name = "EnergyBasedModel"

    def energy_tensor(self, x):
        var h = _t_wrap(x)
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h).silu()
            i = i + 1
        return self.out.forward(h).sum()

    def energy(self, x):
        var e = 0.0
        with no_grad():
            e = self.energy_tensor(x).item()
        return e

    # grad_x E(x) (parameters' gradients are left untouched)
    def energy_grad(self, x):
        var xt = Tensor(_t_flat(_t_wrap(x).data), true)
        var saved = []
        var ps = self.parameters()
        var i = 0
        while i < len(ps):
            saved.append(ps[i].grad)
            i = i + 1
        self.energy_tensor(xt).backward()
        i = 0
        while i < len(ps):
            ps[i].grad = saved[i]
            i = i + 1
        return Tensor(xt.grad)

    def langevin_step(self, x, step_size):
        var xt = _t_wrap(x).detach()
        var g = self.energy_grad(xt)
        var z = Tensor(nt_randn(xt.shape), false, xt.shape)
        return xt - g * step_size + z * sqrt(2.0 * step_size)

    def sample_mcmc(self, n_steps, init_x):
        var x = _t_wrap(init_x)
        var i = 0
        while i < n_steps:
            x = self.langevin_step(x, self.mcmc_step_size)
            i = i + 1
        return x

    # E(data) - E(negative sample from Langevin), the contrastive-divergence
    # objective (minimised by lowering data energy and raising samples')
    def cd_loss_tensor(self, x_data, n_mcmc_steps):
        var x_neg = self.sample_mcmc(n_mcmc_steps, Tensor(nt_randn(self.input_dim)))
        return self.energy_tensor(x_data) - self.energy_tensor(x_neg.detach())

    def contrastive_divergence_loss(self, x_data, n_mcmc_steps):
        return self.cd_loss_tensor(x_data, n_mcmc_steps).item()

    def get_name(self):
        return self.name


# ── 306: MoDLayer (Mixture-of-Depths, Raposo et al. 2024) ──────────────────
# A router scores every token; only the top capacity_fraction of tokens go
# through layer_fn, and their output is x + sigmoid(score) * layer_fn(x) —
# the rest pass through unchanged, saving the layer's compute. layer_fn
# receives each token as given (list or Tensor) and may return either.
class MoDLayer(Module):
    def __init__(self, dim, capacity_fraction, layer_fn):
        super().__init__()
        self.dim = dim
        self.capacity_fraction = capacity_fraction
        self.layer_fn = layer_fn
        self.router = Linear(dim, 1, false)
        self.processed_count = 0
        self.skipped_count = 0
        self.name = "MoDLayer"

    def route(self, tokens):
        return self.router.forward(_sq_rows(tokens)).reshape([len(tokens)])

    def capacity(self, n):
        var c = int(float(n) * self.capacity_fraction)
        if c < 1:
            c = 1
        if c > n:
            c = n
        return c

    # indices of the top-capacity scores, in sequence order
    def selected(self, scores, n):
        var top = tensor_topk(_t_flat(scores.data), self.capacity(n))
        var idx = []
        var i = 0
        while i < len(top):
            idx.append(top[i]["index"])
            i = i + 1
        return sorted(idx)

    def forward(self, tokens):
        var n = len(tokens)
        var scores = self.route(tokens)
        var sel = self.selected(scores, n)
        var out = []
        var i = 0
        while i < n:
            out.append(_t_wrap(tokens[i]))
            i = i + 1
        var k = 0
        while k < len(sel):
            var j = sel[k]
            # layer_fn gets the token in the form it was passed in
            var y = _t_wrap(self.layer_fn(tokens[j]))
            out[j] = out[j] + y * scores.select(0, j).sigmoid()
            k = k + 1
        self.processed_count = self.processed_count + len(sel)
        self.skipped_count = self.skipped_count + n - len(sel)
        return out

    def efficiency_ratio(self):
        var total = self.processed_count + self.skipped_count
        if total == 0:
            return 0.0
        return float(self.skipped_count) / float(total)

    def get_name(self):
        return self.name


# ── 307: xLSTMCell (Beck et al. 2024) ──────────────────────────────────────
# sLSTM: exponential input/forget gates with the stabiliser m and normaliser n
#   m = max(f~ + m_prev, i~),  i = exp(i~ - m),  f = exp(f~ + m_prev - m)
#   c = f c + i z,  n = f n + i,  h = o * c / n
# mLSTM: a matrix memory C = f C + i v k^T, n = f n + i k,
#   h = o * (C q) / max(|n . q|, 1), with scalar exponential gates.
class xLSTMCell(Module):
    def __init__(self, input_dim, hidden_dim, use_sLSTM):
        super().__init__()
        self.input_dim = input_dim
        self.hidden_dim = hidden_dim
        self.use_sLSTM = use_sLSTM
        if use_sLSTM:
            self.gates = Linear(input_dim + hidden_dim, 4 * hidden_dim)
        else:
            self.W_q = Linear(input_dim, hidden_dim)
            self.W_k = Linear(input_dim, hidden_dim)
            self.W_v = Linear(input_dim, hidden_dim)
            self.W_o = Linear(input_dim, hidden_dim)
            self.w_i = Linear(input_dim, 1)
            self.w_f = Linear(input_dim, 1)
        self.name = "xLSTMCell"
        self.reset()

    def _in(self, x):
        var xt = _t_wrap(x)
        if xt.numel() != self.input_dim:
            raise ValueError("xLSTMCell expects " + str(self.input_dim) + " inputs, got " + str(xt.numel()))
        return xt.reshape([self.input_dim])

    def forward_sLSTM(self, x):
        var H = self.hidden_dim
        var g = self.gates.forward(torch.cat([self._in(x), Tensor(self.h)], 0))
        var it = g.slice(0, 0, H)
        var ft = g.slice(0, H, 2 * H)
        var z = g.slice(0, 2 * H, 3 * H).tanh()
        var o = g.slice(0, 3 * H, 4 * H).sigmoid()
        var m_prev = Tensor(self.m)
        var m = (ft + m_prev).maximum(it)
        var i_s = (it - m).exp()
        var f_s = (ft + m_prev - m).exp()
        var c = f_s * Tensor(self.c) + i_s * z
        var n = f_s * Tensor(self.n) + i_s
        var h = o * c.div(n)
        self.c = c.detach().data
        self.n = n.detach().data
        self.m = m.detach().data
        self.h = h.detach().data
        return h

    def forward_mLSTM(self, x):
        var H = self.hidden_dim
        var xt = self._in(x)
        var q = self.W_q.forward(xt)
        var k = self.W_k.forward(xt) * (1.0 / sqrt(1.0 * H))
        var v = self.W_v.forward(xt)
        var o = self.W_o.forward(xt).sigmoid()
        var it = self.w_i.forward(xt)
        var ft = self.w_f.forward(xt)
        var m_prev = Tensor([self.m[0]])
        var m = (ft + m_prev).maximum(it)
        var i_s = (it - m).exp()
        var f_s = (ft + m_prev - m).exp()
        var C = Tensor(self.m_state, false, [H, H]) * f_s + v.outer(k) * i_s
        var n = Tensor(self.n) * f_s + k * i_s
        var denom = n.dot(q).abs().maximum(Tensor(1.0))
        var h = o * C.matmul(q.unsqueeze(1)).squeeze(1).div(denom)
        self.m_state = C.detach().data
        self.n = n.detach().data
        self.m = nt_full([H], m.data[0])
        self.h = h.detach().data
        return h

    def forward(self, x):
        if self.use_sLSTM:
            return self.forward_sLSTM(x)
        return self.forward_mLSTM(x)

    def reset(self):
        var H = self.hidden_dim
        self.h = _sq_zeros(H)
        self.c = _sq_zeros(H)
        self.n = _sq_zeros(H)
        self.m = _sq_zeros(H)
        self.m_state = _sq_zeros(H * H)

    def get_name(self):
        return self.name


# ── 308: xLSTM ─────────────────────────────────────────────────────────────
# A stack of xLSTM cells (the first s_ratio of them sLSTM, the rest mLSTM);
# every block after the first is residual around a LayerNorm.
class xLSTM(Module):
    def __init__(self, input_dim, hidden_dim, n_blocks, s_ratio):
        super().__init__()
        self.input_dim = input_dim
        self.hidden_dim = hidden_dim
        self.n_blocks = n_blocks
        self.s_ratio = s_ratio
        self.blocks = []
        self.norms = []
        var i = 0
        while i < n_blocks:
            var d_in = hidden_dim
            if i == 0:
                d_in = input_dim
            self.blocks.append(xLSTMCell(d_in, hidden_dim, float(i) / float(n_blocks) < s_ratio))
            self.norms.append(LayerNorm(d_in))
            i = i + 1
        self.name = "xLSTM"

    def step(self, x):
        var h = self.blocks[0].forward(self.norms[0].forward(_t_wrap(x)))
        var b = 1
        while b < len(self.blocks):
            h = h + self.blocks[b].forward(self.norms[b].forward(h))
            b = b + 1
        return h

    # a sequence of input vectors -> the list of top-block outputs
    def forward(self, x_seq):
        var out = []
        var i = 0
        while i < len(x_seq):
            out.append(self.step(x_seq[i]))
            i = i + 1
        return out

    def reset(self):
        var i = 0
        while i < len(self.blocks):
            self.blocks[i].reset()
            i = i + 1

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# multi-head attention over projected q (Lq, H*hd), k/v (Lk, H*hd) with an
# additive mask; returns [(Lq, H*hd), weights averaged over heads (Lq, Lk)]
def _sq_mha(q, k, v, n_heads, mask):
    var Lq = q.size()[0]
    var Lk = k.size()[0]
    var hd = q.size()[1] // n_heads
    var Q = q.reshape([Lq, n_heads, hd]).transpose(0, 1)
    var K = k.reshape([Lk, n_heads, hd]).transpose(0, 1)
    var V = v.reshape([Lk, n_heads, hd]).transpose(0, 1)
    var r = scaled_dot_product_attention(Q, K, V, mask, 0.0, false, false)
    return [r[0].transpose(0, 1).reshape([Lq, n_heads * hd]), r[1].mean(0)]


# ── 309: CrossModalAttention ───────────────────────────────────────────────
# Queries from one modality attend over keys/values from another.
class CrossModalAttention(Module):
    def __init__(self, q_dim, kv_dim, out_dim, n_heads):
        super().__init__()
        if out_dim % n_heads != 0:
            raise ValueError("CrossModalAttention: out_dim " + str(out_dim) + " must be divisible by n_heads " + str(n_heads))
        self.q_dim = q_dim
        self.kv_dim = kv_dim
        self.out_dim = out_dim
        self.n_heads = n_heads
        self.head_dim = out_dim // n_heads
        self.W_Q = Linear(q_dim, out_dim)
        self.W_K = Linear(kv_dim, out_dim)
        self.W_V = Linear(kv_dim, out_dim)
        self.W_O = Linear(out_dim, out_dim)
        self.scale = 1.0 / sqrt(float(self.head_dim))
        self.attn_weights = []
        self.name = "CrossModalAttention"

    # (Lq, q_dim) queries, (Lk, kv_dim) keys/values -> (Lq, out_dim);
    # attn_weights: (Lq, Lk), averaged over heads
    def forward(self, query_tokens, key_value_tokens):
        var Qx = _sq_rows(query_tokens)
        var KVx = _sq_rows(key_value_tokens)
        var r = _sq_mha(self.W_Q.forward(Qx), self.W_K.forward(KVx), self.W_V.forward(KVx), self.n_heads, none)
        self.attn_weights = r[1]
        return self.W_O.forward(r[0])

    def get_name(self):
        return self.name


# ── 310: MultimodalFusion ──────────────────────────────────────────────────
# Each modality is projected to fusion_dim, then fused:
#   concat    : Linear over the concatenation
#   attention : the first modality (sorted by name) attends over the others
#   bilinear  : low-rank bilinear (Hadamard) product of the first two
#   product   : elementwise product of all
class MultimodalFusion(Module):
    def __init__(self, modalities, fusion_dim, n_heads, fusion_type):
        super().__init__()
        if fusion_type != "concat" and fusion_type != "attention" and fusion_type != "bilinear" and fusion_type != "product":
            raise ValueError("fusion_type must be concat, attention, bilinear or product, got '" + str(fusion_type) + "'")
        self.modalities = modalities
        self.fusion_dim = fusion_dim
        self.n_heads = n_heads
        self.fusion_type = fusion_type
        self.modality_names = sorted(modalities.keys())
        self.projs = []
        var i = 0
        while i < len(self.modality_names):
            self.projs.append(Linear(modalities[self.modality_names[i]], fusion_dim))
            i = i + 1
        self.cross_attn = CrossModalAttention(fusion_dim, fusion_dim, fusion_dim, n_heads)
        self.concat_proj = Linear(fusion_dim * len(self.modality_names), fusion_dim)
        self.output = Linear(fusion_dim, fusion_dim)
        self.name = "MultimodalFusion"

    def project(self, x, mod_name):
        var i = 0
        while i < len(self.modality_names):
            if self.modality_names[i] == mod_name:
                return self.projs[i].forward(_t_wrap(x))
            i = i + 1
        raise KeyError("unknown modality '" + str(mod_name) + "'")

    def fuse(self, feats):
        if len(feats) == 0:
            raise ValueError("MultimodalFusion: no modality present in the input")
        if self.fusion_type == "concat":
            if len(feats) != len(self.modality_names):
                raise ValueError("concat fusion needs every modality")
            return self.concat_proj.forward(torch.cat(feats, 0))
        if self.fusion_type == "attention":
            if len(feats) == 1:
                return feats[0]
            return self.cross_attn.forward([feats[0]], feats[1:]).squeeze(0)
        if self.fusion_type == "bilinear":
            if len(feats) == 1:
                return feats[0]
            return feats[0] * feats[1]
        var p = feats[0]
        var i = 1
        while i < len(feats):
            p = p * feats[i]
            i = i + 1
        return p

    # {modality name: vector} -> (fusion_dim,)
    def forward(self, modal_inputs):
        var feats = []
        var i = 0
        while i < len(self.modality_names):
            var nm = self.modality_names[i]
            if nm in modal_inputs:
                feats.append(self.projs[i].forward(_t_wrap(modal_inputs[nm])))
            i = i + 1
        return self.output.forward(self.fuse(feats))

    def get_name(self):
        return self.name


# ── 311: FoundationTokenizer ───────────────────────────────────────────────
# Byte-level tokenizer with special tokens: every byte maps to one id after
# the specials (ids wrap when vocab_size leaves fewer than 256 byte slots, so
# decoding is exact only when vocab_size >= specials + 256). Whole tokens can
# be added with add_token. There are no learned BPE merges.
class FoundationTokenizer:
    def __init__(self, vocab_size, special_tokens):
        if vocab_size <= len(special_tokens):
            raise ValueError("vocab_size must exceed the number of special tokens")
        self.vocab_size = vocab_size
        self.special_tokens = special_tokens
        self.vocab = {}
        self.reverse_vocab = {}
        self.n_special = len(special_tokens)
        self.name = "FoundationTokenizer"
        var i = 0
        while i < len(special_tokens):
            self.vocab[special_tokens[i]] = i
            self.reverse_vocab[str(i)] = special_tokens[i]
            i = i + 1

    def add_token(self, token, token_id):
        self.vocab[token] = token_id
        self.reverse_vocab[str(token_id)] = token

    def byte_id(self, ch):
        return self.n_special + ord(ch) % (self.vocab_size - self.n_special)

    def bpe_tokenize(self, text):
        var ids = []
        var i = 0
        while i < len(text):
            var ch = text[i]
            if ch in self.vocab:
                ids.append(self.vocab[ch])
            else:
                ids.append(self.byte_id(ch))
            i = i + 1
        return ids

    def encode(self, text, max_length, add_special):
        var ids = []
        if add_special and "<BOS>" in self.vocab:
            ids.append(self.vocab["<BOS>"])
        ids = ids + self.bpe_tokenize(text)
        if add_special and "<EOS>" in self.vocab:
            ids.append(self.vocab["<EOS>"])
        if max_length > 0 and len(ids) > max_length:
            ids = ids[:max_length]
        return ids

    # ids -> list of token strings (specials by name, bytes as characters)
    def decode(self, token_ids):
        var out = []
        var i = 0
        while i < len(token_ids):
            var tid = token_ids[i]
            var key = str(tid)
            if key in self.reverse_vocab:
                out.append(self.reverse_vocab[key])
            elif tid >= self.n_special and tid < self.vocab_size:
                out.append(chr(tid - self.n_special))
            else:
                out.append("<UNK>")
            i = i + 1
        return out

    def get_vocab_size(self):
        return len(self.vocab)

    def get_name(self):
        return self.name


# ── 312: RotaryPositionalEncoding (Su et al. 2021) ─────────────────────────
# Rotates each pair (x_i, x_(i + d/2)) by angle pos * theta_i,
# theta_i = base^(-2i/d), so q(m) . k(n) depends only on m - n.
class RotaryPositionalEncoding:
    def __init__(self, dim, base, max_seq_len):
        if dim % 2 != 0:
            raise ValueError("RoPE needs an even dimension, got " + str(dim))
        self.dim = dim
        self.base = base
        self.max_seq_len = max_seq_len
        self.half_dim = dim // 2
        self.freqs = self._compute_freqs()
        self.name = "RotaryPositionalEncoding"

    def _compute_freqs(self):
        var f = []
        var i = 0
        while i < self.half_dim:
            f.append(1.0 / (float(self.base) ** (float(2 * i) / float(self.dim))))
            i = i + 1
        return f

    # [cos, sin] tables (L, dim) for positions start .. start + L - 1
    def tables(self, start, L):
        var c = []
        var s = []
        var p = 0
        while p < L:
            var rep = 0
            while rep < 2:
                var i = 0
                while i < self.half_dim:
                    var a = float(start + p) * self.freqs[i]
                    c.append(cos(a))
                    s.append(sin(a))
                    i = i + 1
                rep = rep + 1
            p = p + 1
        return [Tensor(c, false, [L, self.dim]), Tensor(s, false, [L, self.dim])]

    def rotate_half(self, x):
        var t = _t_wrap(x)
        var x1 = t.slice(-1, 0, self.half_dim)
        var x2 = t.slice(-1, self.half_dim, self.dim)
        return torch.cat([x2.neg(), x1], t.dim() - 1)

    # x (dim,) at `position`, or (L, dim) / (..., L, dim) starting there
    def apply_rotary(self, x, position):
        var t = _t_wrap(x)
        if t.size()[t.dim() - 1] != self.dim:
            raise ValueError("RoPE dimension " + str(self.dim) + " does not match input " + str(t.shape))
        if t.dim() == 1:
            var cs = self.tables(position, 1)
            return (t * cs[0].squeeze(0)) + self.rotate_half(t) * cs[1].squeeze(0)
        var L = t.size()[t.dim() - 2]
        var tb = self.tables(position, L)
        return t * tb[0] + self.rotate_half(t) * tb[1]

    # token embeddings (a list of L vectors or (L, dim)) -> (L, dim)
    def forward(self, token_embeds):
        return self.apply_rotary(_sq_rows(token_embeds), 0)

    def get_name(self):
        return self.name


# ── 313: GroupedQueryAttention (Ainslie et al. 2023) ───────────────────────
# n_q_heads query heads share n_kv_heads key/value heads (n_q / n_kv per
# group). forward(x, use_cache): x is one token (dim,) or a sequence
# (L, dim) attended causally; with use_cache, keys/values are appended to
# the cache and every query also sees the cached prefix (incremental
# decoding). Optional RoPE (head_dim) on queries and keys.
class GroupedQueryAttention(Module):
    def __init__(self, dim, n_q_heads, n_kv_heads, head_dim):
        super().__init__()
        if n_q_heads % n_kv_heads != 0:
            raise ValueError("GQA: n_q_heads " + str(n_q_heads) + " must be a multiple of n_kv_heads " + str(n_kv_heads))
        self.dim = dim
        self.n_q_heads = n_q_heads
        self.n_kv_heads = n_kv_heads
        self.head_dim = head_dim
        self.n_groups = n_q_heads // n_kv_heads
        self.W_Q = Linear(dim, n_q_heads * head_dim, false)
        self.W_K = Linear(dim, n_kv_heads * head_dim, false)
        self.W_V = Linear(dim, n_kv_heads * head_dim, false)
        self.W_O = Linear(n_q_heads * head_dim, dim, false)
        self.scale = 1.0 / sqrt(float(head_dim))
        self.rope = none
        self.kv_cache_k = []
        self.kv_cache_v = []
        self.name = "GroupedQueryAttention"

    def set_rope(self, rope):
        self.rope = rope

    def _heads(self, t, n, L):
        # (L, n * hd) -> (n, L, hd)
        return t.reshape([L, n, self.head_dim]).transpose(0, 1)

    def forward(self, x, use_cache, window=0):
        var X = _t_wrap(x)
        var single = X.dim() == 1
        if single:
            X = X.unsqueeze(0)
        var L = X.size()[0]
        var P = 0
        if use_cache:
            P = len(self.kv_cache_k)
        var Q = self._heads(self.W_Q.forward(X), self.n_q_heads, L)
        var K = self._heads(self.W_K.forward(X), self.n_kv_heads, L)
        var V = self._heads(self.W_V.forward(X), self.n_kv_heads, L)
        if self.rope != none:
            Q = self.rope.apply_rotary(Q, P)
            K = self.rope.apply_rotary(K, P)
        if use_cache:
            var i = 0
            while i < L:
                self.kv_cache_k.append(K.select(1, i).detach())
                self.kv_cache_v.append(V.select(1, i).detach())
                i = i + 1
            if P > 0:
                K = torch.cat([_t_stack(self.kv_cache_k[:P], 1), K], 1)
                V = torch.cat([_t_stack(self.kv_cache_v[:P], 1), V], 1)
        # share each kv head across its group of query heads
        var rep = []
        var h = 0
        while h < self.n_q_heads:
            rep.append(h // self.n_groups)
            h = h + 1
        K = K.index_select(0, rep)
        V = V.index_select(0, rep)
        var mask = _sq_band_mask(L, P + L, P, window)
        var r = scaled_dot_product_attention(Q, K, V, mask, 0.0, false, false)
        var out = self.W_O.forward(r[0].transpose(0, 1).reshape([L, self.n_q_heads * self.head_dim]))
        if single:
            return out.squeeze(0)
        return out

    def clear_cache(self):
        self.kv_cache_k = []
        self.kv_cache_v = []

    def get_name(self):
        return self.name


# ── 314: SlidingWindowAttention (Beltagy et al. 2020; Mistral) ─────────────
# Causal multi-head attention where token i sees only tokens i-W+1 .. i.
class SlidingWindowAttention(Module):
    def __init__(self, dim, n_heads, window_size, head_dim):
        super().__init__()
        self.dim = dim
        self.n_heads = n_heads
        self.window_size = window_size
        self.head_dim = head_dim
        self.W_Q = Linear(dim, n_heads * head_dim, false)
        self.W_K = Linear(dim, n_heads * head_dim, false)
        self.W_V = Linear(dim, n_heads * head_dim, false)
        self.W_O = Linear(n_heads * head_dim, dim, false)
        self.scale = 1.0 / sqrt(float(head_dim))
        self.name = "SlidingWindowAttention"

    # tokens (a list of L vectors or (L, dim)) -> (L, dim)
    def forward(self, tokens):
        var X = _sq_rows(tokens)
        var L = X.size()[0]
        var r = _sq_mha(self.W_Q.forward(X), self.W_K.forward(X), self.W_V.forward(X), self.n_heads, _sq_band_mask(L, L, 0, self.window_size))
        return self.W_O.forward(r[0])

    def get_name(self):
        return self.name


# one pre-norm decoder layer: RMSNorm -> GQA (+RoPE) -> residual,
# RMSNorm -> SwiGLU feed-forward W2(SiLU(W1 x) * W3 x) -> residual
class _DecoderLayer(Module):
    def __init__(self, d_model, n_heads, n_kv_heads, ffn_dim, rope):
        super().__init__()
        self.attn = GroupedQueryAttention(d_model, n_heads, n_kv_heads, d_model // n_heads)
        self.attn.set_rope(rope)
        self.ln1 = RMSNorm(d_model)
        self.ln2 = RMSNorm(d_model)
        self.w1 = Linear(d_model, ffn_dim, false)
        self.w2 = Linear(ffn_dim, d_model, false)
        self.w3 = Linear(d_model, ffn_dim, false)

    def ffn(self, x):
        return self.w2.forward(self.w1.forward(x).silu() * self.w3.forward(x))

    def forward(self, x, use_cache):
        var h = x + self.attn.forward(self.ln1.forward(x), use_cache)
        return h + self.ffn(self.ln2.forward(h))


# ── 315: LLMDecoder (LLaMA-style decoder) ──────────────────────────────────
# Embedding -> n_layers x (RMSNorm, GQA with RoPE, SwiGLU) -> RMSNorm -> LM
# head. forward(token_ids, start_pos) returns the logits of the last token;
# with start_pos > 0 and a KV cache holding exactly start_pos tokens, only
# token_ids[start_pos:] are computed (incremental decoding).
class LLMDecoder(Module):
    def __init__(self, vocab_size, d_model, n_layers, n_heads, n_kv_heads, ffn_dim, max_seq_len):
        super().__init__()
        if d_model % n_heads != 0:
            raise ValueError("LLMDecoder: d_model " + str(d_model) + " must be divisible by n_heads " + str(n_heads))
        self.vocab_size = vocab_size
        self.d_model = d_model
        self.n_layers = n_layers
        self.n_heads = n_heads
        self.n_kv_heads = n_kv_heads
        self.ffn_dim = ffn_dim
        self.max_seq_len = max_seq_len
        self.embed = Embedding(vocab_size, d_model)
        self.rope = RotaryPositionalEncoding(d_model // n_heads, 10000, max_seq_len)
        self.layers = []
        var i = 0
        while i < n_layers:
            self.layers.append(_DecoderLayer(d_model, n_heads, n_kv_heads, ffn_dim, self.rope))
            i = i + 1
        self.norm = RMSNorm(d_model)
        self.lm_head = Linear(d_model, vocab_size, false)
        self.name = "LLMDecoder"

    def clear_cache(self):
        var i = 0
        while i < len(self.layers):
            self.layers[i].attn.clear_cache()
            i = i + 1

    def cache_len(self):
        if len(self.layers) == 0:
            return 0
        return len(self.layers[0].attn.kv_cache_k)

    # every position: token ids -> (L, vocab_size) logits (no cache)
    def forward_all(self, token_ids):
        self.clear_cache()
        var h = self.embed.forward(token_ids)
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h, false)
            i = i + 1
        return self.lm_head.forward(self.norm.forward(h))

    def forward(self, token_ids, start_pos):
        if len(token_ids) > self.max_seq_len:
            raise ValueError("sequence of " + str(len(token_ids)) + " tokens exceeds max_seq_len " + str(self.max_seq_len))
        var s = start_pos
        if s <= 0 or s != self.cache_len() or s >= len(token_ids):
            self.clear_cache()
            s = 0
        var h = self.embed.forward(token_ids[s:])
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h, true)
            i = i + 1
        var last = h.select(0, h.size()[0] - 1)
        return self.lm_head.forward(self.norm.forward(last))

    # top_k > 0: sample from the top_k logits at `temperature`; top_k <= 0: greedy
    def generate(self, prompt_ids, max_new_tokens, temperature, top_k):
        var ids = prompt_ids[:]
        with no_grad():
            var logits = self.forward(ids, 0)
            var n = 0
            while n < max_new_tokens:
                var nxt = _sq_pick(logits, temperature, top_k, top_k <= 0)
                ids.append(nxt)
                n = n + 1
                if n < max_new_tokens:
                    logits = self.forward(ids, len(ids) - 1)
        return ids

    def rms_norm(self, x, scale):
        var t = _t_wrap(x)
        return t * ((t * t).mean(-1, true) + 0.00000001).rsqrt() * _t_wrap(scale)

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 316: VectorQuantizer2 (VQ-VAE with EMA codebook, van den Oord et al. 2017)
# quantize(z): nearest codeword e_k; z_q = z + sg(e_k - z) (straight-through);
# commitment loss = beta ||z - sg(e_k)||^2, codebook loss = ||sg(z) - e_k||^2.
# In training mode the codebook follows EMA cluster statistics.
class VectorQuantizer2(Module):
    def __init__(self, n_embeddings, embedding_dim, commitment_cost, ema_decay):
        super().__init__()
        self.n_embeddings = n_embeddings
        self.embedding_dim = embedding_dim
        self.commitment_cost = commitment_cost
        self.ema_decay = ema_decay
        var s = [n_embeddings, embedding_dim]
        self.register_buffer("codebook", Tensor(nt_randn(s), false, s))
        self.ema_cluster_size = nt_full([n_embeddings], 1.0)
        self.ema_embed_avg = nt_binary("mul", self.codebook.data, s, 1.0, [])[0]
        self.usage_count = nt_full([n_embeddings], 0.0)
        self.perplexity_history = []
        self.name = "VectorQuantizer2"

    def get_embedding(self, idx):
        return self.codebook.select(0, idx)

    def nearest(self, z):
        var d = ((self.codebook - z.unsqueeze(0)).square()).sum(1)
        return d.argmin().item()

    def _ema_update(self, k, z):
        var D = self.embedding_dim
        var g = self.ema_decay
        var i = 0
        while i < self.n_embeddings:
            var hit = 0.0
            if i == k:
                hit = 1.0
            self.ema_cluster_size[i] = g * self.ema_cluster_size[i] + (1.0 - g) * hit
            var j = 0
            while j < D:
                var zj = 0.0
                if i == k:
                    zj = z.data[j]
                self.ema_embed_avg[i * D + j] = g * self.ema_embed_avg[i * D + j] + (1.0 - g) * zj
                j = j + 1
            i = i + 1
        # Laplace-smoothed cluster sizes, then e_i = avg_i / size_i
        var n = 0.0
        i = 0
        while i < self.n_embeddings:
            n = n + self.ema_cluster_size[i]
            i = i + 1
        var eps = 0.00001
        i = 0
        while i < self.n_embeddings:
            var size = (self.ema_cluster_size[i] + eps) / (n + self.n_embeddings * eps) * n
            var j2 = 0
            while j2 < D:
                self.codebook.data[i * D + j2] = self.ema_embed_avg[i * D + j2] / size
                j2 = j2 + 1
            i = i + 1

    def quantize(self, z):
        var zt = _t_wrap(z)
        if zt.numel() != self.embedding_dim:
            raise ValueError("VectorQuantizer2 expects vectors of " + str(self.embedding_dim) + ", got " + str(zt.numel()))
        zt = zt.reshape([self.embedding_dim])
        var k = self.nearest(zt.detach())
        var e = self.get_embedding(k).detach()
        var diff = zt.detach() - e
        var dist = (diff * diff).sum().item()
        self.usage_count[k] = self.usage_count[k] + 1.0
        var z_q = zt + (e - zt).detach()
        if self.training:
            self._ema_update(k, zt.detach())
        return {"z_q": z_q, "index": k, "commit_loss": self.commitment_cost * dist, "codebook_loss": dist}

    def quantize_batch(self, z_batch):
        var out = []
        var i = 0
        while i < len(z_batch):
            out.append(self.quantize(z_batch[i]))
            i = i + 1
        return out

    # exp(entropy of codeword usage): 1 = one code used, n_embeddings = uniform
    def codebook_perplexity(self):
        var total = 0.0
        var i = 0
        while i < self.n_embeddings:
            total = total + self.usage_count[i]
            i = i + 1
        if total <= 0.0:
            return 1.0
        var h = 0.0
        i = 0
        while i < self.n_embeddings:
            var p = self.usage_count[i] / total
            if p > 0.0:
                h = h - p * log(p)
            i = i + 1
        var px = exp(h)
        self.perplexity_history.append(px)
        return px

    def get_name(self):
        return self.name


# ── 317: FoundationModelBlock ──────────────────────────────────────────────
# Pre-norm (or post-norm) transformer block with GQA and a SwiGLU FFN over a
# causal token sequence. With use_mod, a router picks the top mod_capacity
# fraction of tokens; only they run through the block (attending among
# themselves, in order) and get x + sigmoid(score) * (block(x) - x).
class FoundationModelBlock(Module):
    def __init__(self, d_model, n_heads, n_kv_heads, ffn_dim, prenorm, use_mod, mod_capacity):
        super().__init__()
        self.d_model = d_model
        self.n_heads = n_heads
        self.n_kv_heads = n_kv_heads
        self.ffn_dim = ffn_dim
        self.prenorm = prenorm
        self.use_mod = use_mod
        self.mod_capacity = mod_capacity
        self.attn = GroupedQueryAttention(d_model, n_heads, n_kv_heads, d_model // n_heads)
        self.ln1 = RMSNorm(d_model)
        self.ln2 = RMSNorm(d_model)
        self.w1 = Linear(d_model, ffn_dim, false)
        self.w2 = Linear(ffn_dim, d_model, false)
        self.w3 = Linear(d_model, ffn_dim, false)
        self.router = none
        if use_mod:
            self.router = Linear(d_model, 1, false)
        self.processed_count = 0
        self.skipped_count = 0
        self.name = "FoundationModelBlock"

    def set_rope(self, rope):
        self.attn.set_rope(rope)

    def ffn(self, x):
        return self.w2.forward(self.w1.forward(x).silu() * self.w3.forward(x))

    def block(self, X):
        if self.prenorm:
            var h = X + self.attn.forward(self.ln1.forward(X), false)
            return h + self.ffn(self.ln2.forward(h))
        var h2 = self.ln1.forward(X + self.attn.forward(X, false))
        return self.ln2.forward(h2 + self.ffn(h2))

    # tokens (a list of L vectors or (L, d_model)) -> (L, d_model)
    def forward(self, tokens):
        var X = _sq_rows(tokens)
        if not self.use_mod:
            return self.block(X)
        var L = X.size()[0]
        var scores = self.router.forward(X).reshape([L])
        var cap = int(float(L) * self.mod_capacity)
        if cap < 1:
            cap = 1
        if cap > L:
            cap = L
        var top = tensor_topk(_t_flat(scores.data), cap)
        var sel = []
        var i = 0
        while i < len(top):
            sel.append(top[i]["index"])
            i = i + 1
        sel = sorted(sel)
        var Xs = X.index_select(0, sel)
        var delta = (self.block(Xs) - Xs) * scores.index_select(0, sel).sigmoid().unsqueeze(1)
        # scatter the updated rows back into place
        var rows = []
        var pos = {}
        i = 0
        while i < len(sel):
            pos[str(sel[i])] = i
            i = i + 1
        i = 0
        while i < L:
            var key = str(i)
            if key in pos:
                rows.append(X.select(0, i) + delta.select(0, pos[key]))
            else:
                rows.append(X.select(0, i))
            i = i + 1
        self.processed_count = self.processed_count + len(sel)
        self.skipped_count = self.skipped_count + L - len(sel)
        return _t_stack(rows, 0)

    def norm(self, x, scale):
        var t = _t_wrap(x)
        return t * ((t * t).mean(-1, true) + 0.00000001).rsqrt() * _t_wrap(scale)

    def get_name(self):
        return self.name


# ── 318: FoundationModel ───────────────────────────────────────────────────
# Decoder-only LM (RoPE, GQA, SwiGLU, RMSNorm); with use_mod every other
# block routes half of the tokens (mixture-of-depths). The context is the
# last max_ctx tokens.
class FoundationModel(Module):
    def __init__(self, vocab_size, d_model, n_layers, n_heads, n_kv_heads, ffn_mult, max_ctx, use_mod):
        super().__init__()
        if d_model % n_heads != 0:
            raise ValueError("FoundationModel: d_model " + str(d_model) + " must be divisible by n_heads " + str(n_heads))
        self.vocab_size = vocab_size
        self.d_model = d_model
        self.n_layers = n_layers
        self.n_heads = n_heads
        self.n_kv_heads = n_kv_heads
        self.ffn_dim = int(d_model * ffn_mult)
        self.max_ctx = max_ctx
        self.use_mod = use_mod
        self.embed = Embedding(vocab_size, d_model)
        self.rope = RotaryPositionalEncoding(d_model // n_heads, 10000, max_ctx)
        self.blocks = []
        var i = 0
        while i < n_layers:
            var routed = use_mod and i % 2 == 0
            var b = FoundationModelBlock(d_model, n_heads, n_kv_heads, self.ffn_dim, true, routed, 0.5)
            b.set_rope(self.rope)
            self.blocks.append(b)
            i = i + 1
        self.norm = RMSNorm(d_model)
        self.lm_head = Linear(d_model, vocab_size, false)
        self.n_tokens_generated = 0
        self.name = "FoundationModel"

    def embed_tokens(self, token_ids):
        var ids = token_ids
        if len(ids) > self.max_ctx:
            ids = ids[len(ids) - self.max_ctx:]
        return self.embed.forward(ids)

    # final hidden states (L, d_model)
    def hidden_states(self, token_ids):
        var h = self.embed_tokens(token_ids)
        var i = 0
        while i < len(self.blocks):
            h = self.blocks[i].forward(h)
            i = i + 1
        return self.norm.forward(h)

    # token ids -> logits (vocab_size,) for the next token
    def forward(self, token_ids):
        var h = self.hidden_states(token_ids)
        return self.lm_head.forward(h.select(0, h.size()[0] - 1))

    # top_k > 0: sample from the top_k logits at `temperature`; else greedy
    def generate(self, prompt_ids, max_new, temperature, top_k):
        var ids = prompt_ids[:]
        with no_grad():
            var n = 0
            while n < max_new:
                ids.append(_sq_pick(self.forward(ids), temperature, top_k, top_k <= 0))
                self.n_tokens_generated = self.n_tokens_generated + 1
                n = n + 1
        return ids

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 319: RewardModel (Bradley-Terry reward model for RLHF) ─────────────────
# r(e) = w2 . relu(W1 e + b1) + b2 over a sequence embedding;
# pairwise loss -log sigmoid(r(chosen) - r(rejected)).
class RewardModel(Module):
    def __init__(self, base_model_dim, hidden_dim):
        super().__init__()
        self.base_model_dim = base_model_dim
        self.hidden_dim = hidden_dim
        self.proj = Linear(base_model_dim, hidden_dim)
        self.score_head = Linear(hidden_dim, 1)
        self.preference_data = []
        self.reward_history = []
        self.opt = none
        self.name = "RewardModel"

    def score_tensor(self, sequence_embedding):
        return self.score_head.forward(self.proj.forward(_t_wrap(sequence_embedding)).relu()).sum()

    def score(self, sequence_embedding):
        var s = 0.0
        with no_grad():
            s = self.score_tensor(sequence_embedding).item()
        return s

    def _pair_loss(self, chosen_emb, rejected_emb):
        # -log sigmoid(d) = softplus(-d)
        return (self.score_tensor(chosen_emb) - self.score_tensor(rejected_emb)).neg().softplus()

    def pairwise_loss(self, chosen_emb, rejected_emb):
        var l = 0.0
        with no_grad():
            l = self._pair_loss(chosen_emb, rejected_emb).item()
        self.preference_data.append({"chosen": chosen_emb, "rejected": rejected_emb})
        return l

    # one Adam step on the mean pairwise loss of the batch; returns that loss
    def train_step(self, chosen_batch, rejected_batch, lr):
        if len(chosen_batch) != len(rejected_batch) or len(chosen_batch) == 0:
            raise ValueError("train_step needs equally long, non-empty chosen and rejected batches")
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        self.opt.set_lr(lr)
        self.opt.zero_grad()
        var total = self._pair_loss(chosen_batch[0], rejected_batch[0])
        self.preference_data.append({"chosen": chosen_batch[0], "rejected": rejected_batch[0]})
        var i = 1
        while i < len(chosen_batch):
            total = total + self._pair_loss(chosen_batch[i], rejected_batch[i])
            self.preference_data.append({"chosen": chosen_batch[i], "rejected": rejected_batch[i]})
            i = i + 1
        var loss = total * (1.0 / float(len(chosen_batch)))
        loss.backward()
        self.opt.step()
        var l = loss.item()
        self.reward_history.append(l)
        return l

    # fraction of recorded preference pairs the current model ranks correctly
    def evaluate_win_rate(self):
        if len(self.preference_data) == 0:
            return 0.5
        var wins = 0
        var i = 0
        while i < len(self.preference_data):
            var p = self.preference_data[i]
            if self.score(p["chosen"]) > self.score(p["rejected"]):
                wins = wins + 1
            i = i + 1
        return float(wins) / float(len(self.preference_data))

    def get_name(self):
        return self.name


# ── 320: GenerativeAIPipeline ──────────────────────────────────────────────
# tokenize -> FoundationModel.generate -> decode; score() runs the reward
# model on the mean final hidden state of the text.
class GenerativeAIPipeline:
    def __init__(self, config):
        self.config = config
        var vocab_size = 512
        if "vocab_size" in config:
            vocab_size = config["vocab_size"]
        var d_model = 64
        if "d_model" in config:
            d_model = config["d_model"]
        var n_layers = 4
        if "n_layers" in config:
            n_layers = config["n_layers"]
        var n_heads = 4
        if "n_heads" in config:
            n_heads = config["n_heads"]
        var max_ctx = 256
        if "max_ctx" in config:
            max_ctx = config["max_ctx"]
        var use_mod = false
        if "use_mod" in config:
            use_mod = config["use_mod"]
        var n_kv = n_heads // 2
        if n_kv < 1:
            n_kv = 1
        self.tokenizer = FoundationTokenizer(vocab_size, ["<PAD>", "<BOS>", "<EOS>", "<UNK>"])
        self.model = FoundationModel(vocab_size, d_model, n_layers, n_heads, n_kv, 4.0, max_ctx, use_mod)
        var rh = d_model // 2
        if rh < 1:
            rh = 1
        self.reward_model = RewardModel(d_model, rh)
        self.vq = VectorQuantizer2(64, d_model, 0.25, 0.99)
        self.temperature = 1.0
        if "temperature" in config:
            self.temperature = config["temperature"]
        self.top_k = 50
        if "top_k" in config:
            self.top_k = config["top_k"]
        self.max_new_tokens = 64
        if "max_new_tokens" in config:
            self.max_new_tokens = config["max_new_tokens"]
        self.generation_count = 0
        self.total_tokens = 0
        self.name = "GenerativeAIPipeline"

    def generate(self, prompt_text):
        var ids = self.tokenizer.encode(prompt_text, 0, true)
        if len(ids) == 0:
            ids = [1]
        var out = self.model.generate(ids, self.max_new_tokens, self.temperature, self.top_k)
        var new_ids = out[len(ids):]
        self.generation_count = self.generation_count + 1
        self.total_tokens = self.total_tokens + len(out)
        return {"tokens": self.tokenizer.decode(new_ids), "ids": new_ids, "n_new": len(new_ids), "total_len": len(out)}

    def embed_text(self, text):
        var ids = self.tokenizer.encode(text, 0, true)
        var e = none
        with no_grad():
            e = self.model.hidden_states(ids).mean(0)
        return e

    def score(self, text):
        return self.reward_model.score(self.embed_text(text))

    def quantize_latent(self, latent):
        return self.vq.quantize(latent)

    def get_model_info(self):
        return {
            "n_params": self.model.n_params(),
            "vocab_size": self.tokenizer.get_vocab_size(),
            "d_model": self.model.d_model,
            "n_layers": self.model.n_layers,
            "generations": self.generation_count,
            "total_tokens": self.total_tokens,
            "name": self.name
        }

    def get_name(self):
        return self.name
