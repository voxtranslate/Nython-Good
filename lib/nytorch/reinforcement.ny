# import nytorch  # removed: already loaded via nytorch.ny

# ═══════════════════════════════════════════════════════════════════════════
# NyTorch v3.0 — Part 13: Advanced RL, Transformers, AutoML & Production
# Classes 202–230
# ═══════════════════════════════════════════════════════════════════════════

import "lib/nytorch/core.ny"

# ── shared helpers for the agents below ─────────────────────────────────────
def _rl_vec(x, dim, what):
    var t = _t_wrap(x)
    if t.numel() != dim:
        raise ValueError(what + " must have " + str(dim) + " values, got " + str(t.numel()))
    return t.reshape([dim])

def _rl_batch(rows, dim, what):
    var flat = []
    var i = 0
    while i < len(rows):
        var r = _t_flat(_t_wrap(rows[i]).data)
        if len(r) != dim:
            raise ValueError(what + " must have " + str(dim) + " values, got " + str(len(r)))
        var j = 0
        while j < dim:
            flat.append(r[j])
            j = j + 1
        i = i + 1
    return Tensor(flat, false, [len(rows), dim])

def _rl_mlp(sizes, out_act):
    var mods = []
    var i = 0
    while i < len(sizes) - 1:
        mods.append(Linear(sizes[i], sizes[i + 1]))
        if i < len(sizes) - 2:
            mods.append(ReLU())
        i = i + 1
    if out_act == "tanh":
        mods.append(Tanh())
    return Sequential(mods)

# sample an index from a probability vector (the seeded generator)
def _rl_sample(probs):
    var u = nt_rand(1)[0]
    var c = 0.0
    var i = 0
    while i < len(probs):
        c = c + probs[i]
        if u <= c:
            return i
        i = i + 1
    return len(probs) - 1

# target <- tau * source + (1 - tau) * target, in place
def _rl_soft_update(target, source, tau):
    var tp = target.parameters()
    var sp = source.parameters()
    var i = 0
    while i < len(tp):
        nt_scale_(tp[i].data, 1.0 - tau)
        nt_axpy(tp[i].data, tau, sp[i].data)
        i = i + 1

def _rl_copy(target, source):
    target.load_state_dict(source.state_dict())

def _rl_pick(q, actions, n_actions):
    # q (B, n_actions), actions: list of ints -> (B,) Q(s, a)
    return (q * _fn_one_hot(actions, n_actions)).sum(1)

def _rl_indices(n, k):
    return nt_randint(0, n, k)


# ── 202: SACAgent (Soft Actor-Critic, discrete actions) ────────────────────
# Christodoulou 2019: a categorical policy, twin Q networks with Polyak-
# averaged targets, and the entropy-regularised soft Bellman target
#   y = r + gamma (1 - done) sum_a' pi(a'|s') [min Q'(s', a') - alpha log pi(a'|s')]
class SACAgent:
    def __init__(self, state_dim, action_dim, lr, alpha, hidden=64, gamma=0.99, tau=0.005, batch_size=32):
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.lr = lr
        self.alpha = alpha
        self.gamma = gamma
        self.tau = tau
        self.batch_size = batch_size
        self.actor = _rl_mlp([state_dim, hidden, action_dim], "none")
        self.q1 = _rl_mlp([state_dim, hidden, action_dim], "none")
        self.q2 = _rl_mlp([state_dim, hidden, action_dim], "none")
        self.q1_target = _rl_mlp([state_dim, hidden, action_dim], "none")
        self.q2_target = _rl_mlp([state_dim, hidden, action_dim], "none")
        _rl_copy(self.q1_target, self.q1)
        _rl_copy(self.q2_target, self.q2)
        self.actor_opt = Adam(self.actor.parameters(), lr)
        self.critic_opt = Adam(self.q1.parameters() + self.q2.parameters(), lr)
        self.replay = []
        self.step_count = 0
        self.name = "SAC"

    def act(self, state):
        var out = 0
        with no_grad():
            var p = self.actor.forward(_rl_vec(state, self.state_dim, "state")).softmax(0)
            out = _rl_sample(p.data)
        return out

    def store(self, state, action, reward, next_state, done):
        self.replay.append([state, action, reward, next_state, done])
        if len(self.replay) > 10000:
            self.replay = self.replay[1:]

    def update(self):
        if len(self.replay) < self.batch_size:
            return 0.0
        self.step_count = self.step_count + 1
        var idx = _rl_indices(len(self.replay), self.batch_size)
        var s = []
        var a = []
        var r = []
        var s2 = []
        var nd = []
        var i = 0
        while i < len(idx):
            var t = self.replay[idx[i]]
            s.append(t[0])
            a.append(t[1])
            r.append(1.0 * t[2])
            s2.append(t[3])
            if t[4]:
                nd.append(0.0)
            else:
                nd.append(1.0)
            i = i + 1
        var S = _rl_batch(s, self.state_dim, "state")
        var S2 = _rl_batch(s2, self.state_dim, "next_state")
        var y = none
        with no_grad():
            var lp2 = self.actor.forward(S2).log_softmax(1)
            var p2 = lp2.exp()
            var qmin = self.q1_target.forward(S2).minimum(self.q2_target.forward(S2))
            var v2 = (p2 * (qmin - lp2 * self.alpha)).sum(1)
            y = Tensor(r) + v2 * Tensor(nd) * self.gamma
        var q1 = _rl_pick(self.q1.forward(S), a, self.action_dim)
        var q2 = _rl_pick(self.q2.forward(S), a, self.action_dim)
        var critic_loss = _fn_mse(q1, y, "mean") + _fn_mse(q2, y, "mean")
        self.critic_opt.zero_grad()
        critic_loss.backward()
        self.critic_opt.step()
        var lp = self.actor.forward(S).log_softmax(1)
        var qmin_s = self.q1.forward(S).minimum(self.q2.forward(S)).detach()
        var actor_loss = (lp.exp() * (lp * self.alpha - qmin_s)).sum(1).mean()
        self.actor_opt.zero_grad()
        actor_loss.backward()
        self.actor_opt.step()
        _rl_soft_update(self.q1_target, self.q1, self.tau)
        _rl_soft_update(self.q2_target, self.q2, self.tau)
        return critic_loss.item() + actor_loss.item()

    def get_stats(self):
        return {"steps": self.step_count, "buffer": len(self.replay), "alpha": self.alpha, "name": self.name}


# ── 203: TD3Agent (Twin Delayed DDPG, continuous actions in [-1, 1]) ───────
# Fujimoto 2018: clipped double-Q targets, target-policy smoothing noise,
# and a delayed actor update every `policy_delay` critic updates.
class TD3Agent:
    def __init__(self, state_dim, action_dim, lr, hidden=64, gamma=0.99, tau=0.005, batch_size=16):
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.lr = lr
        self.gamma = gamma
        self.tau = tau
        self.batch_size = batch_size
        self.actor = _rl_mlp([state_dim, hidden, action_dim], "tanh")
        self.actor_target = _rl_mlp([state_dim, hidden, action_dim], "tanh")
        self.q1 = _rl_mlp([state_dim + action_dim, hidden, 1], "none")
        self.q2 = _rl_mlp([state_dim + action_dim, hidden, 1], "none")
        self.q1_target = _rl_mlp([state_dim + action_dim, hidden, 1], "none")
        self.q2_target = _rl_mlp([state_dim + action_dim, hidden, 1], "none")
        _rl_copy(self.actor_target, self.actor)
        _rl_copy(self.q1_target, self.q1)
        _rl_copy(self.q2_target, self.q2)
        self.actor_opt = Adam(self.actor.parameters(), lr)
        self.critic_opt = Adam(self.q1.parameters() + self.q2.parameters(), lr)
        self.policy_delay = 2
        self.noise_clip = 0.5
        self.policy_noise = 0.2
        self.update_count = 0
        self.replay = []
        self.name = "TD3"

    def act(self, state, noise_scale):
        var out = none
        with no_grad():
            var a = self.actor.forward(_rl_vec(state, self.state_dim, "state"))
            if noise_scale > 0:
                a = a + Tensor(nt_normal(self.action_dim, 0.0, noise_scale))
            out = a.clamp(-1.0, 1.0).data
        return out

    def store(self, state, action, reward, next_state, done):
        self.replay.append([state, action, reward, next_state, done])
        if len(self.replay) > 100000:
            self.replay = self.replay[1:]

    def update(self):
        if len(self.replay) < self.batch_size:
            return {"critic": 0.0, "actor": 0.0, "updates": self.update_count}
        self.update_count = self.update_count + 1
        var idx = _rl_indices(len(self.replay), self.batch_size)
        var s = []
        var a = []
        var r = []
        var s2 = []
        var nd = []
        var i = 0
        while i < len(idx):
            var t = self.replay[idx[i]]
            s.append(t[0])
            a.append(t[1])
            r.append(1.0 * t[2])
            s2.append(t[3])
            if t[4]:
                nd.append(0.0)
            else:
                nd.append(1.0)
            i = i + 1
        var S = _rl_batch(s, self.state_dim, "state")
        var A = _rl_batch(a, self.action_dim, "action")
        var S2 = _rl_batch(s2, self.state_dim, "next_state")
        var y = none
        with no_grad():
            var n = self.batch_size * self.action_dim
            var noise = Tensor(nt_normal(n, 0.0, self.policy_noise), false, [self.batch_size, self.action_dim]).clamp(0.0 - self.noise_clip, self.noise_clip)
            var a2 = (self.actor_target.forward(S2) + noise).clamp(-1.0, 1.0)
            var sa2 = torch.cat([S2, a2], 1)
            var qt = self.q1_target.forward(sa2).minimum(self.q2_target.forward(sa2)).reshape([self.batch_size])
            y = Tensor(r) + qt * Tensor(nd) * self.gamma
        var sa = torch.cat([S, A], 1)
        var c1 = self.q1.forward(sa).reshape([self.batch_size])
        var c2 = self.q2.forward(sa).reshape([self.batch_size])
        var critic_loss = _fn_mse(c1, y, "mean") + _fn_mse(c2, y, "mean")
        self.critic_opt.zero_grad()
        critic_loss.backward()
        self.critic_opt.step()
        var a_loss = 0.0
        if self.update_count % self.policy_delay == 0:
            var actor_loss = self.q1.forward(torch.cat([S, self.actor.forward(S)], 1)).mean().neg()
            self.actor_opt.zero_grad()
            actor_loss.backward()
            self.actor_opt.step()
            a_loss = actor_loss.item()
            _rl_soft_update(self.actor_target, self.actor, self.tau)
            _rl_soft_update(self.q1_target, self.q1, self.tau)
            _rl_soft_update(self.q2_target, self.q2, self.tau)
        return {"critic": critic_loss.item(), "actor": a_loss, "updates": self.update_count}

    def get_name(self):
        return self.name


# ── 204: A2CAgent (Advantage Actor-Critic) ─────────────────────────────────
# One network with a policy head and a value head; the update minimises
#   -log pi(a|s) A  +  0.5 (R - V(s))^2  -  entropy_coef H(pi(.|s)),  A = R - V(s)
class A2CAgent:
    def __init__(self, state_dim, action_dim, lr, gamma, entropy_coef, hidden=64):
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.lr = lr
        self.gamma = gamma
        self.entropy_coef = entropy_coef
        self.body = _rl_mlp([state_dim, hidden], "none")
        self.policy_head = Linear(hidden, action_dim)
        self.value_head = Linear(hidden, 1)
        self.opt = Adam(self.body.parameters() + self.policy_head.parameters() + self.value_head.parameters(), lr)
        self.trajectory = []
        self.total_steps = 0
        self.name = "A2C"

    def _heads(self, S):
        var h = self.body.forward(S).relu()
        return [self.policy_head.forward(h), self.value_head.forward(h)]

    # returns [action, log_prob, value] (pass log_prob/value to store_step)
    def act(self, state):
        var out = none
        with no_grad():
            var hv = self._heads(_rl_vec(state, self.state_dim, "state").unsqueeze(0))
            var lp = hv[0].log_softmax(1).reshape([self.action_dim])
            var a = _rl_sample(lp.exp().data)
            out = [a, lp.data[a], hv[1].item()]
        return out

    def store_step(self, state, action, reward, value, log_prob):
        self.trajectory.append([state, action, reward, value, log_prob])

    def compute_returns(self):
        var returns = []
        var g = 0.0
        var i = len(self.trajectory) - 1
        while i >= 0:
            g = self.trajectory[i][2] + self.gamma * g
            returns = [g] + returns
            i = i - 1
        return returns

    def update(self):
        if len(self.trajectory) == 0:
            return 0.0
        var R = Tensor(self.compute_returns())
        var s = []
        var a = []
        var i = 0
        while i < len(self.trajectory):
            s.append(self.trajectory[i][0])
            a.append(self.trajectory[i][1])
            i = i + 1
        var hv = self._heads(_rl_batch(s, self.state_dim, "state"))
        var lp = hv[0].log_softmax(1)
        var v = hv[1].reshape([len(a)])
        var adv = (R - v).detach()
        var policy_loss = (_rl_pick(lp, a, self.action_dim) * adv).mean().neg()
        var value_loss = _fn_mse(v, R, "mean") * 0.5
        var entropy = (lp.exp() * lp).sum(1).mean().neg()
        var loss = policy_loss + value_loss - entropy * self.entropy_coef
        self.opt.zero_grad()
        loss.backward()
        self.opt.step()
        self.total_steps = self.total_steps + len(self.trajectory)
        self.trajectory = []
        return loss.item()

    def get_stats(self):
        return {"steps": self.total_steps, "gamma": self.gamma, "name": self.name}


# ── 205: PPOAgent (Proximal Policy Optimization, clipped objective) ────────
class PPOAgent:
    def __init__(self, state_dim, action_dim, lr, clip_eps, n_epochs, hidden=64, gamma=0.99):
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.lr = lr
        self.clip_eps = clip_eps
        self.n_epochs = n_epochs
        self.gamma = gamma
        self.policy = _rl_mlp([state_dim, hidden, action_dim], "none")
        self.value = _rl_mlp([state_dim, hidden, 1], "none")
        self.opt = Adam(self.policy.parameters() + self.value.parameters(), lr)
        self.buffer = []
        self.episode_rewards = []
        self.total_updates = 0
        self.name = "PPO"

    # [action, log_prob] sampled from the current policy
    def act(self, state):
        var out = none
        with no_grad():
            var lp = self.policy.forward(_rl_vec(state, self.state_dim, "state")).log_softmax(0)
            var a = _rl_sample(lp.exp().data)
            out = [a, lp.data[a]]
        return out

    def store(self, state, action, reward, log_prob_old, value, done):
        self.buffer.append([state, action, reward, log_prob_old, value, done])

    def update(self):
        if len(self.buffer) < 8:
            return {"loss": 0.0, "clip_frac": 0.0, "updates": self.total_updates}
        var n = len(self.buffer)
        var returns = []
        var g = 0.0
        var i = n - 1
        while i >= 0:
            if self.buffer[i][5]:
                g = 0.0
            g = self.buffer[i][2] + self.gamma * g
            returns = [g] + returns
            i = i - 1
        var s = []
        var a = []
        var old = []
        i = 0
        while i < n:
            s.append(self.buffer[i][0])
            a.append(self.buffer[i][1])
            old.append(self.buffer[i][3])
            i = i + 1
        var S = _rl_batch(s, self.state_dim, "state")
        var R = Tensor(returns)
        var old_lp = Tensor(old)
        var total = 0.0
        var clipped = 0
        var e = 0
        while e < self.n_epochs:
            var lp = _rl_pick(self.policy.forward(S).log_softmax(1), a, self.action_dim)
            var v = self.value.forward(S).reshape([n])
            var adv = (R - v).detach()
            var ratio = (lp - old_lp).exp()
            var surr1 = ratio * adv
            var surr2 = ratio.clamp(1.0 - self.clip_eps, 1.0 + self.clip_eps) * adv
            var loss = surr1.minimum(surr2).mean().neg() + _fn_mse(v, R, "mean") * 0.5
            self.opt.zero_grad()
            loss.backward()
            self.opt.step()
            total = total + loss.item()
            var rd = ratio.data
            var k = 0
            while k < n:
                if rd[k] < 1.0 - self.clip_eps or rd[k] > 1.0 + self.clip_eps:
                    clipped = clipped + 1
                k = k + 1
            e = e + 1
        self.total_updates = self.total_updates + 1
        self.buffer = []
        var m = self.n_epochs * n
        return {"loss": total / self.n_epochs, "clip_frac": (1.0 * clipped) / m, "updates": self.total_updates}

    def get_name(self):
        return self.name


# ── 206: TransformerTokenizer ──────────────────────────────────────────────
class TransformerTokenizer:
    def __init__(self, vocab_size, max_len):
        self.vocab_size = vocab_size
        self.max_len = max_len
        self.word_to_id = {}
        self.id_to_word = {}
        self.special_tokens = {"[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3, "[MASK]": 4}
        self.next_id = 5
        for token in ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]"]:
            self.word_to_id[token] = self.special_tokens[token]
            self.id_to_word[str(self.special_tokens[token])] = token

    def add_word(self, word):
        if self.next_id >= self.vocab_size:
            return 1   # [UNK]
        self.word_to_id[word] = self.next_id
        self.id_to_word[str(self.next_id)] = word
        self.next_id = self.next_id + 1
        return self.next_id - 1

    def encode(self, text):
        var words = text.lower().split(" ")
        var ids = [2]   # [CLS]
        for word in words:
            if len(ids) >= self.max_len - 1:
                break
            if word in self.word_to_id:
                var ids = ids + [self.word_to_id[word]]
            else:
                ids = ids + [1]   # [UNK]
        ids = ids + [3]   # [SEP]
        while len(ids) < self.max_len:
            ids = ids + [0]   # [PAD]
        return ids

    def decode(self, ids):
        var words = []
        for i in ids:
            var sid = str(i)
            if sid in self.id_to_word:
                var w = self.id_to_word[sid]
                if w != "[PAD]" and w != "[CLS]" and w != "[SEP]":
                    var words = words + [w]
        return words.join(" ")

    def vocab_len(self):
        return self.next_id


# ── 207: TransformerEmbedding (token + learned position embeddings) ────────
class TransformerEmbedding(Module):
    def __init__(self, vocab_size, embed_dim, max_len):
        super().__init__()
        self.vocab_size = vocab_size
        self.embed_dim = embed_dim
        self.max_len = max_len
        self.token_embed = Embedding(vocab_size, embed_dim)
        self.pos_embed = Embedding(max_len, embed_dim)
        self.name = "TransformerEmbedding"

    def embed_token(self, token_id):
        if token_id < 0 or token_id >= self.vocab_size:
            raise IndexError("token id " + str(token_id) + " out of range for vocab " + str(self.vocab_size))
        return self.token_embed.forward(token_id)

    def embed_position(self, pos):
        if pos < 0 or pos >= self.max_len:
            raise IndexError("position " + str(pos) + " out of range for max_len " + str(self.max_len))
        return self.pos_embed.forward(pos)

    # token ids (L,) -> (L, embed_dim)
    def forward(self, token_ids):
        var L = len(token_ids)
        if L > self.max_len:
            raise ValueError("sequence of " + str(L) + " tokens exceeds max_len " + str(self.max_len))
        var pos = []
        var i = 0
        while i < L:
            pos.append(i)
            i = i + 1
        return self.token_embed.forward(token_ids) + self.pos_embed.forward(pos)

    def get_name(self):
        return self.name


# ── 208: ScaledDotProductAttention ────────────────────────────────────────
# softmax(Q K^T / sqrt(d_k)) V. Q (Lq, d_k), K (Lk, d_k), V (Lk, d_v), or
# single 1-d vectors (one query, one key: the weight is exactly 1).
class ScaledDotProductAttention:
    def __init__(self, d_k, dropout):
        self.d_k = d_k
        self.dropout = dropout
        self.scale = 1.0 / sqrt(float(d_k))
        self.name = "ScaledDotProductAttention"

    # mask: none/false, true (causal), or an attention mask
    def forward(self, Q, K, V, mask):
        var q = _t_wrap(Q)
        var k = _t_wrap(K)
        var v = _t_wrap(V)
        var vec = q.dim() == 1
        if vec:
            q = q.unsqueeze(0)
            k = k.unsqueeze(0)
            v = v.unsqueeze(0)
        var m = none
        var causal = false
        if mask == true:
            causal = true
        elif mask != false and mask != none:
            m = mask
        var r = scaled_dot_product_attention(q, k, v, m, 0.0, causal, false)
        var out = r[0]
        var w = r[1]
        if vec:
            out = out.squeeze(0)
            w = w.item()
        return {"output": out, "attn_weight": w}

    def get_scale(self):
        return self.scale

    def get_name(self):
        return self.name


# ── 209: MultiHeadSelfAttention ────────────────────────────────────────────
# Self-attention over a sequence given as (L, d_model) or a list of L vectors;
# returns (L, d_model). mask=true applies a causal mask.
class MultiHeadSelfAttention(Module):
    def __init__(self, d_model, n_heads, dropout):
        super().__init__()
        self.d_model = d_model
        self.n_heads = n_heads
        self.d_k = int(d_model / n_heads)
        self.mha = MultiheadAttention(d_model, n_heads, dropout)
        self.attn_weights = none
        self.name = "MultiHeadSelfAttention"

    def __call__(self, x, mask):
        return self.forward(x, mask)

    def forward(self, x, mask):
        var t = x
        if type(x) == "list" and len(x) > 0 and not _t_isnum(x[0]):
            t = _t_stack(x, 0)
        t = _t_wrap(t)
        var m = none
        if mask == true:
            m = causal_mask(t.size()[0])
        elif mask != false and mask != none:
            m = mask
        var r = self.mha.forward(t, t, t, m, none)
        self.attn_weights = r[1]
        return r[0]

    def get_n_heads(self):
        return self.n_heads

    def get_name(self):
        return self.name


# ── 211: TransformerEncoder ────────────────────────────────────────────────
# Two constructors:
#   TransformerEncoder(encoder_layer, num_layers)   torch.nn style: a stack of
#       num_layers layers with encoder_layer's hyperparameters (freshly
#       initialised each; torch deep-copies the given layer instead).
#       forward(src, mask) -> same shape as src.
#   TransformerEncoder(vocab_size, d_model, n_heads, n_layers, d_ff, max_len,
#       dropout)   BERT style: embeddings + a [CLS]-pooled encoder.
#       forward(token_ids, mask) -> the [CLS] (first token) state (d_model,),
#       encode(token_ids, mask) -> every token's state (L, d_model),
#       classify(token_ids, n_classes) -> class probabilities from a linear head.
class TransformerEncoder(Module):
    def __init__(self, first, num_layers, n_heads=none, n_layers=none, d_ff=none, max_len=none, dropout=0.1):
        super().__init__()
        self.name = "TransformerEncoder"
        self.layers = []
        self.embedding = none
        self.heads = {}
        if isinstance(first, TransformerEncoderLayer):
            var i = 0
            while i < num_layers:
                self.layers.append(TransformerEncoderLayer(first.d_model, first.nhead, first.dim_feedforward, first.dropout.p, first.activation, first.self_attn.batch_first, first.norm_first))
                i = i + 1
            self.d_model = first.d_model
            self.vocab_size = 0
        else:
            self.vocab_size = first
            self.d_model = num_layers
            self.max_len = max_len
            self.embedding = TransformerEmbedding(first, num_layers, max_len)
            var j = 0
            while j < n_layers:
                self.layers.append(TransformerEncoderLayer(num_layers, n_heads, d_ff, dropout))
                j = j + 1

    def __call__(self, x, mask=none):
        return self.forward(x, mask)

    def _run(self, h, mask):
        var m = mask
        if m == false or m == true:
            m = none
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h, m, none)
            i = i + 1
        return h

    def encode(self, token_ids, mask=none):
        return self._run(self.embedding.forward(token_ids), mask)

    def forward(self, x, mask=none):
        if self.embedding == none:
            return self._run(_t_wrap(x), mask)
        return self.encode(x, mask).select(0, 0)

    def classify(self, token_ids, n_classes):
        var key = str(n_classes)
        if not self.heads.has_key(key):
            self.heads[key] = Linear(self.d_model, n_classes)
        var head = self.heads[key]
        return head.forward(self.forward(token_ids, none)).softmax(0)

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 212: BayesianLinear (Bayes by Backprop, Blundell et al. 2015) ──────────
# Weights are distributions N(mu, softplus(rho)^2); every forward draws a
# sample by reparameterisation (so gradients reach mu and rho), and
# kl_loss() is the closed-form KL(q || N(0, prior_std^2)).
class BayesianLinear(Module):
    def __init__(self, in_dim, out_dim, prior_std):
        super().__init__()
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.prior_std = prior_std
        self.w_mu = _l_uniform([out_dim, in_dim], 1.0 / sqrt(1.0 * in_dim))
        self.w_rho = _l_const([out_dim, in_dim], -5.0)
        self.b_mu = _l_const([out_dim], 0.0)
        self.b_rho = _l_const([out_dim], -5.0)
        self.kl_weight = 1.0
        self.name = "BayesianLinear"

    def reparameterize(self, mu, rho):
        var eps = Tensor(nt_randn(mu.shape), false, mu.shape)
        return mu + rho.softplus() * eps

    def forward(self, x):
        var w = self.reparameterize(self.w_mu, self.w_rho)
        var b = self.reparameterize(self.b_mu, self.b_rho)
        return _fn_linear(x, w, b)

    def _kl(self, mu, rho):
        var sigma = rho.softplus()
        var p = self.prior_std
        # log(p / sigma) + (sigma^2 + mu^2) / (2 p^2) - 1/2, summed
        return (sigma.log().neg() + (sigma * sigma + mu * mu) * (0.5 / (p * p)) + (log(p) - 0.5)).sum()

    def kl_loss(self):
        return (self._kl(self.w_mu, self.w_rho) + self._kl(self.b_mu, self.b_rho)).item() * self.kl_weight

    def get_name(self):
        return self.name


# ── 213: MCDropoutModel (Gal & Ghahramani 2016) ────────────────────────────
# An MLP with dropout kept ACTIVE at prediction time; the spread of
# n_samples stochastic predictions estimates the model's uncertainty.
class MCDropoutModel(Module):
    def __init__(self, layer_sizes, dropout_rate, n_samples):
        super().__init__()
        self.layer_sizes = layer_sizes
        self.dropout_rate = dropout_rate
        self.n_samples = n_samples
        self.layers = []
        var i = 0
        while i < len(layer_sizes) - 1:
            self.layers.append(Linear(layer_sizes[i], layer_sizes[i + 1]))
            i = i + 1
        self.name = "MCDropoutModel"

    def single_forward(self, x):
        var h = _t_wrap(x)
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h)
            if i < len(self.layers) - 1:
                h = _fn_dropout(h.relu(), self.dropout_rate, true)
            i = i + 1
        return h

    def predict_with_uncertainty(self, x):
        var preds = []
        var s = 0
        with no_grad():
            while s < self.n_samples:
                preds.append(self.single_forward(x).mean().item())
                s = s + 1
        var t = Tensor(preds)
        var var_p = t.var(none, false, 0).item()
        return {"mean": t.mean().item(), "variance": var_p, "std": sqrt(var_p), "samples": self.n_samples}

    def get_name(self):
        return self.name


# ── 214: EnsembleModel ────────────────────────────────────────────────────
# n independently initialised MLPs; the prediction is the weighted mean of
# each model's (mean) output, and the spread across models is the variance.
class EnsembleModel(Module):
    def __init__(self, n_models, layer_sizes, lr):
        super().__init__()
        self.n_models = n_models
        self.layer_sizes = layer_sizes
        self.lr = lr
        self.models = []
        self.weights = []
        var i = 0
        while i < n_models:
            self.models.append(MLP(layer_sizes, "relu"))
            self.weights.append(1.0 / float(n_models))
            i = i + 1
        self.train_errors = []
        self.name = "EnsembleModel"

    def single_predict(self, model_idx, x):
        var out = 0.0
        with no_grad():
            out = self.models[model_idx].forward(_t_wrap(x)).mean().item()
        return out

    def predict(self, x):
        var total = 0.0
        var i = 0
        while i < self.n_models:
            total = total + self.single_predict(i, x) * self.weights[i]
            i = i + 1
        return total

    def predict_with_variance(self, x):
        var preds = []
        var i = 0
        while i < self.n_models:
            preds.append(self.single_predict(i, x))
            i = i + 1
        var t = Tensor(preds)
        return {"mean": t.mean().item(), "variance": t.var(none, false, 0).item(), "models": self.n_models}

    # inverse-error weighting from validation errors
    def update_weights(self, val_errors):
        var total = 0.0
        var i = 0
        while i < len(val_errors):
            total = total + 1.0 / (val_errors[i] + 0.00000001)
            i = i + 1
        i = 0
        while i < len(val_errors):
            self.weights[i] = (1.0 / (val_errors[i] + 0.00000001)) / total
            i = i + 1

    def get_name(self):
        return self.name


# ── 215: HyperparamSearch ─────────────────────────────────────────────────
class HyperparamSearch:
    def __init__(self, param_space, n_trials, strategy):
        self.param_space = param_space
        self.n_trials = n_trials
        self.strategy = strategy   # "random", "grid", "bayesian"
        self.trials = []
        self.best_params = {}
        self.best_score = 1e9
        self.current_trial = 0
        self.name = "HyperparamSearch"

    def sample_random(self):
        var params = {}
        for key in self.param_space:
            var space = self.param_space[key]
            if type(space) == "list":
                var idx = self.current_trial % len(space)
                params[key] = space[idx]
            else:
                params[key] = space
        return params

    def suggest(self):
        self.current_trial = self.current_trial + 1
        if self.strategy == "random":
            return self.sample_random()
        return self.sample_random()

    def report(self, params, score):
        self.trials = self.trials + [{"params": params, "score": score, "trial": self.current_trial}]
        if score < self.best_score:
            self.best_score = score
            self.best_params = params

    def best_result(self):
        return {"params": self.best_params, "score": self.best_score, "n_trials": len(self.trials)}

    def get_name(self):
        return self.name


# ── 216: NASCell (Neural Architecture Search) ─────────────────────────────
class NASCell(Module):
    # DARTS (Liu et al. 2019) cell: node i applies the softmax(alpha_i)-weighted
    # mixture of the candidate ops; alpha (arch_params) is a Parameter, so
    # loss.backward() through forward() gives it a gradient and
    # update_arch(lr) takes a real architecture step. discretize() keeps the
    # strongest op per node.
    def __init__(self, n_nodes, ops):
        super().__init__()
        var known = ["relu", "identity", "zero", "tanh", "sigmoid"]
        var i = 0
        while i < len(ops):
            if not ops[i] in known:
                raise ValueError("NASCell: unknown op '" + str(ops[i]) + "' (known: relu, identity, zero, tanh, sigmoid)")
            i = i + 1
        self.n_nodes = n_nodes
        self.ops = ops
        self.connections = []
        self.arch_params = _l_const([n_nodes, len(ops)], 0.0)
        self.name = "NASCell"

    def discretize(self):
        var selected = []
        var i = 0
        while i < self.n_nodes:
            var row = self.arch_params.select(0, i)
            selected.append(self.ops[row.argmax().item()])
            i = i + 1
        return selected

    def _op(self, name, h):
        if name == "relu":
            return h.relu()
        if name == "tanh":
            return h.tanh()
        if name == "sigmoid":
            return h.sigmoid()
        if name == "zero":
            return h * 0.0
        return h

    def forward(self, x):
        var h = _t_wrap(x)
        var i = 0
        while i < self.n_nodes:
            var w = self.arch_params.select(0, i).softmax(0)
            var mix = none
            var j = 0
            while j < len(self.ops):
                var term = self._op(self.ops[j], h) * w.select(0, j)
                if mix == none:
                    mix = term
                else:
                    mix = mix + term
                j = j + 1
            h = mix
            i = i + 1
        return h

    # one gradient step on the architecture parameters
    def update_arch(self, lr):
        if self.arch_params.grad == none:
            raise ValueError("NASCell.update_arch: no gradient; call backward() on a loss computed through forward() first")
        nt_axpy(self.arch_params.data, 0.0 - lr, self.arch_params.grad)
        self.arch_params.grad = none

    def get_name(self):
        return self.name


# ── 217: ModelRegistry ────────────────────────────────────────────────────
# Run a served model: a Module (forward on a tensor of the inputs) or any
# callable. There is no stand-in: a string is not a model.
def _rl_run_model(model, inputs):
    if isinstance(model, Module):
        var out = none
        with no_grad():
            out = model.forward(_t_wrap(inputs))
        return out.data
    var ty = type(model)
    if ty == "string" or ty == "int" or ty == "float" or ty == "bool" or ty == "list" or model == none:
        raise TypeError("model must be a Module or a callable, got " + str(ty))
    return model(inputs)

class ModelRegistry:
    def __init__(self, name):
        self.name = name
        self.models = {}
        self.versions = {}
        self.metrics = {}
        self.tags = {}
        self.default_model = ""
        self.total_registered = 0

    def register(self, model_name, model_version, model_obj, tags):
        var key = model_name + ":" + str(model_version)
        self.models[key] = model_obj
        self.versions[model_name] = model_version
        self.tags[key] = tags
        self.total_registered = self.total_registered + 1
        if self.default_model == "":
            self.default_model = key
        return key

    def get(self, model_name, version):
        var key = model_name + ":" + str(version)
        if key in self.models:
            return self.models[key]
        return none

    def get_latest(self, model_name):
        if model_name in self.versions:
            var v = self.versions[model_name]
            return self.get(model_name, v)
        return none

    def record_metrics(self, model_name, version, metrics):
        var key = model_name + ":" + str(version)
        self.metrics[key] = metrics

    def get_metrics(self, model_name, version):
        var key = model_name + ":" + str(version)
        if key in self.metrics:
            return self.metrics[key]
        return {}

    def list_models(self):
        var names = []
        for k in self.versions:
            var names = names + [k]
        return names

    def total(self):
        return self.total_registered


# ── 218: ModelServer ──────────────────────────────────────────────────────
class ModelServer:
    def __init__(self, host, port, model_name):
        self.host = host
        self.port = port
        self.model_name = model_name
        self.model = none
        self.request_count = 0
        self.error_count = 0
        self.total_latency = 0.0
        self.is_running = false
        self.batch_size = 32
        self.name = "ModelServer"

    def load_model(self, model):
        self.model = model
        return true

    def predict(self, inputs):
        if self.model == none:
            self.error_count = self.error_count + 1
            return {"error": "no model loaded"}
        self.request_count = self.request_count + 1
        var t0 = time_ms()
        var result = _rl_run_model(self.model, inputs)
        var latency_ms = time_ms() - t0
        self.total_latency = self.total_latency + latency_ms / 1000.0
        return {"predictions": result, "latency_ms": latency_ms, "request_id": self.request_count}

    def batch_predict(self, batch):
        var results = []
        for inp in batch:
            var results = results + [self.predict(inp)]
        return results

    def health(self):
        var avg_lat = 0.0
        if self.request_count > 0:
            var avg_lat = self.total_latency / float(self.request_count)
        return {
            "status": "healthy",
            "model": self.model_name,
            "requests": self.request_count,
            "errors": self.error_count,
            "avg_latency_ms": avg_lat * 1000.0,
            "running": self.is_running
        }

    def get_name(self):
        return self.name


# ── 219: BatchInferencer ──────────────────────────────────────────────────
class BatchInferencer:
    def __init__(self, model, batch_size, n_workers):
        self.model = model
        self.batch_size = batch_size
        self.n_workers = n_workers
        self.queue = []
        self.results = {}
        self.processed = 0
        self.name = "BatchInferencer"

    def submit(self, request_id, data):
        self.queue = self.queue + [{"id": request_id, "data": data}]

    def process_batch(self):
        var n = min(self.batch_size, len(self.queue))
        var batch = self.queue[:n]
        self.queue = self.queue[n:]
        var i = 0
        while i < len(batch):
            self.results[batch[i]["id"]] = _rl_run_model(self.model, batch[i]["data"])
            self.processed = self.processed + 1
            i = i + 1
        return n

    def get_result(self, request_id):
        if request_id in self.results:
            return self.results[request_id]
        return none

    def drain(self):
        var total = 0
        while len(self.queue) > 0:
            var total = total + self.process_batch()
        return total

    def stats(self):
        return {"processed": self.processed, "queued": len(self.queue), "workers": self.n_workers}

    def get_name(self):
        return self.name


# ── 220: ABTestFramework ──────────────────────────────────────────────────
class ABTestFramework:
    def __init__(self, name, traffic_split):
        self.name = name
        self.traffic_split = traffic_split   # e.g. 0.5 = 50% to variant B
        self.model_a = none
        self.model_b = none
        self.metrics_a = {"requests": 0, "total_score": 0.0, "wins": 0}
        self.metrics_b = {"requests": 0, "total_score": 0.0, "wins": 0}
        self.total_requests = 0

    def set_models(self, model_a, model_b):
        self.model_a = model_a
        self.model_b = model_b

    def route(self, request_id):
        var r = float(request_id % 100) / 100.0
        if r >= self.traffic_split:
            return "A"
        return "B"

    # Routes the request to model A or B and returns its real output. Scores
    # come from outcomes you observe: record_outcome(variant, score).
    def predict(self, request_id, data):
        self.total_requests = self.total_requests + 1
        var variant = self.route(request_id)
        var model = self.model_a
        if variant == "B":
            model = self.model_b
        var pred = _rl_run_model(model, data)
        if variant == "A":
            self.metrics_a["requests"] = self.metrics_a["requests"] + 1
        else:
            self.metrics_b["requests"] = self.metrics_b["requests"] + 1
        return {"variant": variant, "prediction": pred}

    def record_outcome(self, variant, score):
        if variant == "A":
            self.metrics_a["total_score"] = self.metrics_a["total_score"] + score
            self.metrics_a["wins"] = self.metrics_a["wins"] + 1
        else:
            self.metrics_b["total_score"] = self.metrics_b["total_score"] + score
            self.metrics_b["wins"] = self.metrics_b["wins"] + 1

    def report(self):
        var avg_a = 0.0
        var avg_b = 0.0
        if self.metrics_a["requests"] > 0:
            var avg_a = self.metrics_a["total_score"] / float(self.metrics_a["requests"])
        if self.metrics_b["requests"] > 0:
            var avg_b = self.metrics_b["total_score"] / float(self.metrics_b["requests"])
        var winner = "A"
        if avg_b > avg_a:
            var winner = "B"
        return {
            "winner": winner,
            "avg_score_a": avg_a,
            "avg_score_b": avg_b,
            "requests_a": self.metrics_a["requests"],
            "requests_b": self.metrics_b["requests"],
            "total": self.total_requests
        }

    def get_name(self):
        return "ABTestFramework"


# ── 221: OnlineRegressor ────────────────────────────────────────────────────
class OnlineRegressor:
    def __init__(self, dim, lr, decay):
        self.dim = dim
        self.lr = lr
        self.decay = decay
        self.w = tensor_zeros([dim])
        self.t = 0       # timestep
        self.loss_history = []
        self.name = "OnlineRegressor"

    def predict(self, x):
        return tensor_dot_product(self.w, x)

    def update(self, x, y_true):
        var y_pred = self.predict(x)
        var err = y_pred - y_true
        var grad = tensor_mul(x, tensor([err]))
        if len(grad) < len(self.w):
            var grad = tensor_add(grad, tensor_zeros([len(self.w) - len(grad)]))
        var eff_lr = self.lr / (1.0 + self.decay * float(self.t))
        self.w = tensor_sub(self.w, tensor_mul(grad, tensor([eff_lr])))
        self.t = self.t + 1
        var loss = err * err
        self.loss_history = self.loss_history + [loss]
        return loss

    def recent_loss(self, n):
        var start = max(0, len(self.loss_history) - n)
        var recent = self.loss_history[start:]
        var total = 0.0
        for l in recent:
            var total = total + l
        if len(recent) == 0:
            return 0.0
        return total / float(len(recent))

    def get_name(self):
        return self.name


# ── 222: DriftDetector ────────────────────────────────────────────────────
class DriftDetector:
    def __init__(self, window_size, threshold):
        self.window_size = window_size
        self.threshold = threshold
        self.reference_window = []
        self.current_window = []
        self.drift_detected = false
        self.drift_count = 0
        self.name = "DriftDetector"

    def set_reference(self, data):
        self.reference_window = data
        self.drift_detected = false

    def update(self, value):
        self.current_window = self.current_window + [value]
        if len(self.current_window) > self.window_size:
            self.current_window = self.current_window[1:]
        if len(self.current_window) >= self.window_size and len(self.reference_window) >= self.window_size:
            return self._check_drift()
        return false

    def _check_drift(self):
        var ref_mean = 0.0
        for v in self.reference_window:
            var ref_mean = ref_mean + v
        ref_mean = ref_mean / float(len(self.reference_window))
        var cur_mean = 0.0
        for v in self.current_window:
            var cur_mean = cur_mean + v
        cur_mean = cur_mean / float(len(self.current_window))
        var diff = abs(cur_mean - ref_mean)
        if diff > self.threshold:
            self.drift_detected = true
            self.drift_count = self.drift_count + 1
            return true
        self.drift_detected = false
        return false

    def reset(self):
        self.reference_window = self.current_window[:]
        self.current_window = []
        self.drift_detected = false

    def get_name(self):
        return self.name


# ── 223: FeaturePipeline ──────────────────────────────────────────────────
class FeaturePipeline:
    def __init__(self, name):
        self.name = name
        self.steps = []
        self.step_names = []
        self.fit_data = {}
        self.is_fitted = false

    def add_step(self, step_name, transform_fn):
        self.steps = self.steps + [transform_fn]
        self.step_names = self.step_names + [step_name]
        return self

    def fit(self, data):
        var current = data
        for i in range(0, len(self.steps)):
            var fn = self.steps[i]
            self.fit_data[self.step_names[i]] = tensor_mean(current)
            var current = tensor_apply(current, lambda x: x)
        self.is_fitted = true
        return self

    def transform(self, data):
        var current = data
        for fn in self.steps:
            var current = tensor_apply(current, lambda x: x)
        return current

    def fit_transform(self, data):
        self.fit(data)
        return self.transform(data)

    def get_steps(self):
        return self.step_names

    def get_name(self):
        return self.name


# ── 224: CrossValidator ───────────────────────────────────────────────────
class CrossValidator:
    def __init__(self, n_folds, metric_fn, shuffle):
        self.n_folds = n_folds
        self.metric_fn = metric_fn
        self.shuffle = shuffle
        self.fold_scores = []
        self.name = "CrossValidator"

    def split(self, data, labels):
        var fold_size = len(data) // self.n_folds
        var folds = []
        for i in range(0, self.n_folds):
            var start = i * fold_size
            var end = start + fold_size
            var folds = folds + [[start, end]]
        return folds

    def score(self, model_fn, data, labels):
        self.fold_scores = []
        var n = len(data)
        for fold in range(0, self.n_folds):
            var val_score = self.metric_fn(fold, n)
            self.fold_scores = self.fold_scores + [val_score]
        var total = 0.0
        for s in self.fold_scores:
            var total = total + s
        var mean_score = total / float(self.n_folds)
        var variance = 0.0
        for s in self.fold_scores:
            var variance = variance + (s - mean_score) * (s - mean_score)
        variance = variance / float(self.n_folds)
        return {"mean": mean_score, "std": sqrt(variance), "folds": self.fold_scores}

    def get_name(self):
        return self.name


# ── graph helpers ───────────────────────────────────────────────────────────
# node features: a list of N vectors or an (N, F) tensor; adjacency: a list
# of neighbour-index lists.
def _g_features(node_features):
    if type(node_features) == "list":
        return _t_stack(node_features, 0)
    return _t_wrap(node_features)

# dense (N, N) 0/1 matrix, optionally with self loops
def _g_adj_matrix(adjacency, n, self_loops):
    var d = nt_full([n * n], 0.0)
    var i = 0
    while i < n:
        if self_loops:
            d[i * n + i] = 1.0
        var nb = adjacency[i]
        var k = 0
        while k < len(nb):
            var j = nb[k]
            if j < 0 or j >= n:
                raise IndexError("neighbour index " + str(j) + " out of range for " + str(n) + " nodes")
            d[i * n + j] = 1.0
            k = k + 1
        i = i + 1
    return Tensor(d, false, [n, n])


# ── 225: GCNLayer (Kipf & Welling 2017) ────────────────────────────────────
# H' = act(D^-1/2 (A + I) D^-1/2 H W^T + b)
class GCNLayer(Module):
    def __init__(self, in_dim, out_dim, activation):
        super().__init__()
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.activation = activation
        self.linear = Linear(in_dim, out_dim)
        self.name = "GCNLayer"

    def __call__(self, node_features, adjacency):
        return self.forward(node_features, adjacency)

    def normalized_adjacency(self, adjacency, n):
        var A = _g_adj_matrix(adjacency, n, true)
        var deg = A.sum(1)
        var dinv = deg.rsqrt()
        return A * dinv.reshape([n, 1]) * dinv.reshape([1, n])

    def forward(self, node_features, adjacency):
        var H = _g_features(node_features)
        var n = H.size()[0]
        var out = self.normalized_adjacency(adjacency, n).matmul(self.linear.forward(H))
        if self.activation == "relu":
            return out.relu()
        if self.activation == "tanh":
            return out.tanh()
        return out

    def get_name(self):
        return self.name


# ── 226: GATLayer (Velickovic et al. 2018) ─────────────────────────────────
# Per head: e_ij = LeakyReLU(a_src . W h_i + a_dst . W h_j) over j in N(i) + {i},
# alpha = softmax_j(e_ij), h_i' = sum_j alpha_ij W h_j. Heads are averaged.
class GATLayer(Module):
    def __init__(self, in_dim, out_dim, n_heads, dropout):
        super().__init__()
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.n_heads = n_heads
        self.dropout = dropout
        self.W = Linear(in_dim, out_dim * n_heads, false)
        var bound = 1.0 / sqrt(1.0 * out_dim)
        self.a_src = _l_uniform([n_heads, out_dim], bound)
        self.a_dst = _l_uniform([n_heads, out_dim], bound)
        self.name = "GATLayer"

    def __call__(self, node_features, adjacency):
        return self.forward(node_features, adjacency)

    def forward(self, node_features, adjacency):
        var H = _g_features(node_features)
        var n = H.size()[0]
        var Wh = self.W.forward(H).reshape([n, self.n_heads, self.out_dim]).transpose(0, 1)
        var es = Wh.matmul(self.a_src.unsqueeze(2))
        var ed = Wh.matmul(self.a_dst.unsqueeze(2)).transpose(1, 2)
        var e = (es + ed).leaky_relu(0.2)
        var mask = _g_adj_matrix(adjacency, n, true)
        var neg = _t_where(mask, 0.0, _a_neg_inf())
        var alpha = (e + neg).softmax(-1)
        if self.training and self.dropout > 0:
            alpha = _fn_dropout(alpha, self.dropout, true)
        return alpha.matmul(Wh).mean(0)

    def get_name(self):
        return self.name


# ── 227: GraphSAGE (Hamilton et al. 2017) ──────────────────────────────────
# h_i' = act(W [h_i || AGG_{j in N(i)} h_j]), AGG = mean or max; no
# activation after the last layer.
class GraphSAGE(Module):
    def __init__(self, in_dim, hidden_dim, out_dim, n_layers, aggregator):
        super().__init__()
        if aggregator != "mean" and aggregator != "max":
            raise ValueError("GraphSAGE aggregator must be 'mean' or 'max', got '" + str(aggregator) + "'")
        self.in_dim = in_dim
        self.hidden_dim = hidden_dim
        self.out_dim = out_dim
        self.n_layers = n_layers
        self.aggregator = aggregator
        self.layers = []
        var i = 0
        while i < n_layers:
            var din = hidden_dim
            if i == 0:
                din = in_dim
            var dout = hidden_dim
            if i == n_layers - 1:
                dout = out_dim
            self.layers.append(Linear(2 * din, dout))
            i = i + 1
        self.name = "GraphSAGE"

    def __call__(self, node_features, adjacency):
        return self.forward(node_features, adjacency)

    def aggregate(self, H, adjacency):
        var n = H.size()[0]
        if self.aggregator == "mean":
            var A = _g_adj_matrix(adjacency, n, false)
            var deg = A.sum(1, true).clamp(1.0, 1e300)
            return A.div(deg).matmul(H)
        var rows = []
        var i = 0
        while i < n:
            var nb = adjacency[i]
            if len(nb) == 0:
                rows.append(H.select(0, i) * 0.0)
            else:
                rows.append(H.index_select(0, nb).max(0))
            i = i + 1
        return _t_stack(rows, 0)

    def forward(self, node_features, adjacency):
        var h = _g_features(node_features)
        var i = 0
        while i < len(self.layers):
            var z = self.layers[i].forward(torch.cat([h, self.aggregate(h, adjacency)], 1))
            if i < len(self.layers) - 1:
                z = z.relu()
            h = z
            i = i + 1
        return h

    def get_name(self):
        return self.name


# ── 228: KnowledgeDistillation ────────────────────────────────────────────
class KnowledgeDistillation:
    def __init__(self, teacher, student, temperature, alpha):
        self.teacher = teacher
        self.student = student
        self.temperature = temperature   # softmax temperature
        self.alpha = alpha               # weight: alpha * kd_loss + (1-alpha) * task_loss
        self.kd_losses = []
        self.task_losses = []
        self.name = "KnowledgeDistillation"

    def soft_labels(self, logits, temp):
        var scaled = tensor_mul(logits, tensor([1.0 / temp]))
        return softmax(scaled)

    def kl_divergence(self, p, q):
        var kl = 0.0
        for i in range(0, min(len(p), len(q))):
            var pi = p[i]
            var qi = q[i]
            if pi > 1e-10 and qi > 1e-10:
                var kl = kl + pi * log(pi / qi)
        return kl

    # Hinton et al. 2015: alpha * T^2 * KL(softmax(t/T) || softmax(s/T))
    #                   + (1 - alpha) * cross-entropy(softmax(s), true_labels)
    # true_labels: a class index or a probability vector.
    def compute_loss(self, student_logits, teacher_logits, true_labels):
        var soft_teacher = self.soft_labels(teacher_logits, self.temperature)
        var soft_student = self.soft_labels(student_logits, self.temperature)
        var kd_loss = self.kl_divergence(soft_teacher, soft_student) * (self.temperature * self.temperature)
        var target = true_labels
        if _t_isnum(true_labels):
            target = [true_labels]
        var task_loss = _fn_cross_entropy(Tensor(student_logits), Tensor(target), none, -100, "mean", 0.0).item()
        if not _t_isnum(true_labels) and len(true_labels) != len(student_logits):
            raise ValueError("true_labels must be a class index or a probability vector over the logits")
        var total = self.alpha * kd_loss + (1.0 - self.alpha) * task_loss
        self.kd_losses = self.kd_losses + [kd_loss]
        self.task_losses = self.task_losses + [task_loss]
        return {"total": total, "kd": kd_loss, "task": task_loss}

    def avg_kd_loss(self):
        if len(self.kd_losses) == 0:
            return 0.0
        var s = 0.0
        for l in self.kd_losses:
            var s = s + l
        return s / float(len(self.kd_losses))

    def get_name(self):
        return self.name


# ── 229: PromptTemplate ───────────────────────────────────────────────────
class PromptTemplate:
    def __init__(self, template, input_vars):
        self.template = template
        self.input_vars = input_vars
        self.examples = []
        self.system_prompt = ""
        self.max_tokens = 512
        self.name = "PromptTemplate"

    def set_system(self, system):
        self.system_prompt = system
        return self

    def add_example(self, inp, out):
        self.examples = self.examples + [{"input": inp, "output": out}]
        return self

    def format(self, variables):
        var result = self.template
        for key in variables:
            var placeholder = "{" + key + "}"
            var result = result.replace(placeholder, str(variables[key]))
        return result

    def build_prompt(self, variables):
        var prompt = ""
        if self.system_prompt != "":
            var prompt = "System: " + self.system_prompt + "\n\n"
        for ex in self.examples:
            prompt = prompt + "Input: " + ex["input"] + "\nOutput: " + ex["output"] + "\n\n"
        prompt = prompt + "Input: " + self.format(variables) + "\nOutput:"
        return prompt

    def get_name(self):
        return self.name


# ── 230: LLMPipeline ──────────────────────────────────────────────────────
# A small decoder-only (causal) transformer language model over token ids.
class TinyCausalLM(Module):
    def __init__(self, vocab_size, d_model, n_heads, n_layers, max_len):
        super().__init__()
        self.vocab_size = vocab_size
        self.max_len = max_len
        self.embed = TransformerEmbedding(vocab_size, d_model, max_len)
        self.blocks = []
        var i = 0
        while i < n_layers:
            self.blocks.append(TransformerEncoderLayer(d_model, n_heads, 4 * d_model, 0.0, "gelu", false, true))
            i = i + 1
        self.norm = LayerNorm(d_model)
        self.lm_head = Linear(d_model, vocab_size)
    def hidden(self, ids):
        var h = self.embed.forward(ids)
        var mask = causal_mask(len(ids))
        var i = 0
        while i < len(self.blocks):
            h = self.blocks[i].forward(h, mask, none)
            i = i + 1
        return self.norm.forward(h)

    # token ids (L,) -> next-token logits for every position (L, vocab)
    def forward(self, ids):
        return self.lm_head.forward(self.hidden(ids))

    # logits (vocab,) after the last token only (what generation needs)
    def next_logits(self, ids):
        var h = self.hidden(ids)
        return self.lm_head.forward(h.select(0, h.size()[0] - 1))

# Tokenise -> run a causal language model -> sample -> detokenise. `model`
# is any Module mapping token ids (L,) to logits (L, vocab); by default a
# small TinyCausalLM (untrained: its text is only as good as its training).
class LLMPipeline:
    def __init__(self, model_name, tokenizer, max_tokens, temperature, model=none):
        self.model_name = model_name
        self.model = model
        if model == none:
            self.model = TinyCausalLM(tokenizer.vocab_size, 32, 2, 1, tokenizer.max_len * 4)
        self.tokenizer = tokenizer
        self.max_tokens = max_tokens
        self.temperature = temperature
        self.history = []
        self.total_tokens = 0
        self.cache = {}
        self.plugins = []
        self.name = "LLMPipeline"

    def add_plugin(self, plugin_name, plugin_fn):
        self.plugins = self.plugins + [{"name": plugin_name, "fn": plugin_fn}]
        return self

    def preprocess(self, text):
        var cleaned = text.strip()
        var i = 0
        while i < len(self.plugins):
            var fn = self.plugins[i]["fn"]
            cleaned = fn(cleaned)
            i = i + 1
        return cleaned

    def generate(self, prompt, stop_tokens):
        var input_text = self.preprocess(prompt)
        var cache_key = input_text[:32]
        if cache_key in self.cache:
            return self.cache[cache_key]
        var ids = self.tokenizer.encode(input_text)
        # drop the [PAD] tail: generation continues after the prompt's [SEP]
        var seq = []
        var i = 0
        while i < len(ids) and ids[i] != 0:
            seq.append(ids[i])
            i = i + 1
        var n_input = len(seq)
        var output_ids = []
        var n_new = min(self.max_tokens, self.model.max_len - n_input)
        var k = 0
        with no_grad():
            while k < n_new:
                var logits = none
                if hasattr(self.model, "next_logits"):
                    logits = self.model.next_logits(seq)
                else:
                    logits = self.model.forward(seq).select(0, len(seq) - 1)
                var probs = (logits * (1.0 / max(self.temperature, 0.01))).softmax(0)
                var nxt = _rl_sample(probs.data)
                if nxt == 0 or nxt == 3:
                    break
                seq.append(nxt)
                output_ids.append(nxt)
                k = k + 1
        var output_text = self.tokenizer.decode(output_ids)
        var j = 0
        while j < len(stop_tokens):
            var at = output_text.find(stop_tokens[j])
            if at >= 0:
                output_text = output_text[:at]
            j = j + 1
        self.total_tokens = self.total_tokens + n_input + len(output_ids)
        var result = {
            "text": output_text,
            "tokens_used": n_input + len(output_ids),
            "input_tokens": n_input,
            "output_tokens": len(output_ids)
        }
        self.cache[cache_key] = result
        self.history = self.history + [{"prompt": input_text[:50], "tokens": n_input}]
        return result

    def chat(self, user_message):
        var history_ctx = ""
        for turn in self.history:
            var history_ctx = history_ctx + "User: " + turn["prompt"] + "\n"
        var full_prompt = history_ctx + "User: " + user_message + "\nAssistant:"
        return self.generate(full_prompt, ["\nUser:"])

    def total_tokens_used(self):
        return self.total_tokens

    def get_name(self):
        return self.name

