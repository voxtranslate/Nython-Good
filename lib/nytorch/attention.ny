# ─── nytorch attention, recurrent and transformer layers ─────────────────────
# All on the Tensor autograd engine. Sequence layout follows PyTorch:
# (L, N, E) by default, (N, L, E) with batch_first=true, and an unbatched
# (L, E) input is accepted everywhere. A bare 1-d vector (E,) is read as a
# one-token sequence and answered with a 1-d vector (the older API's shape).

import "lib/nytorch/tensor.ny"
import "lib/nytorch/module.ny"
import "lib/nytorch/layers.ny"

def _a_neg_inf():
    return nt_unary("log", [0.0])[0]

# float additive mask from a bool/0-1 mask (true/1 = not allowed, as in torch)
def _a_mask_to_add(mask):
    var m = _t_wrap(mask)
    var ninf = _a_neg_inf()
    var d = []
    var src = _t_flat(m.data)
    var i = 0
    while i < len(src):
        var v = src[i]
        if v == true or v == 1 or v == 1.0:
            d.append(ninf)
        elif v == false or v == 0 or v == 0.0:
            d.append(0.0)
        else:
            d.append(1.0 * v)
        i = i + 1
    return Tensor(_t_fix(d, m.shape), false, m.shape)

# Causal mask for a length-L sequence: position i may not attend to j > i.
def causal_mask(L):
    var ninf = _a_neg_inf()
    var d = []
    var i = 0
    while i < L:
        var j = 0
        while j < L:
            if j > i:
                d.append(ninf)
            else:
                d.append(0.0)
            j = j + 1
        i = i + 1
    return Tensor(d, false, [L, L])

# softmax(q k^T / sqrt(d) + mask) v over the last two dims; returns [out, weights]
def scaled_dot_product_attention(q, k, v, attn_mask=none, dropout_p=0.0, is_causal=false, training=false):
    var qs = q.size()
    var d = qs[len(qs) - 1]
    var scores = q.matmul(k.transpose(-2, -1)) * (1.0 / sqrt(1.0 * d))
    if is_causal:
        scores = scores + causal_mask(qs[len(qs) - 2])
    if attn_mask != none:
        scores = scores + _a_mask_to_add(attn_mask)
    var w = scores.softmax(-1)
    if dropout_p > 0 and training:
        w = _fn_dropout(w, dropout_p, true)
    return [w.matmul(v), w]


class MultiheadAttention(Module):
    # torch.nn.MultiheadAttention: packed in-projection [3E, E] + out_proj.
    # forward(query, key, value, attn_mask=none, key_padding_mask=none)
    #   -> [attn_output, attn_weights averaged over heads (N, L, S)]
    def __init__(self, embed_dim, num_heads, dropout=0.0, bias=true, batch_first=false):
        super().__init__()
        if embed_dim % num_heads != 0:
            raise ValueError("embed_dim " + str(embed_dim) + " must be divisible by num_heads " + str(num_heads))
        self.embed_dim = embed_dim
        self.num_heads = num_heads
        self.head_dim = int(embed_dim / num_heads)
        self.dropout = dropout
        self.batch_first = batch_first
        # xavier_uniform on the packed projection, zero biases (torch's init)
        var bound = sqrt(6.0 / (embed_dim + 3 * embed_dim))
        var s = [3 * embed_dim, embed_dim]
        self.in_proj_weight = Parameter(Tensor(nt_uniform(s, 0.0 - bound, bound), false, s))
        self.in_proj_bias = none
        if bias:
            self.in_proj_bias = Parameter(Tensor(nt_full([3 * embed_dim], 0.0), false, [3 * embed_dim]))
        self.out_proj = Linear(embed_dim, embed_dim, bias)
        if bias:
            nt_fill_(self.out_proj.bias.data, 0.0)

    def __call__(self, query, key, value, attn_mask=none, key_padding_mask=none):
        return self.forward(query, key, value, attn_mask, key_padding_mask)

    def _proj(self, x, i):
        var E = self.embed_dim
        var w = self.in_proj_weight.slice(0, i * E, (i + 1) * E)
        var b = none
        if self.in_proj_bias != none:
            b = self.in_proj_bias.slice(0, i * E, (i + 1) * E)
        return _fn_linear(x, w, b)

    def forward(self, query, key, value, attn_mask=none, key_padding_mask=none):
        var q = _t_wrap(query)
        var k = _t_wrap(key)
        var v = _t_wrap(value)
        var vec = q.dim() == 1
        if vec:
            q = q.unsqueeze(0)
            k = k.unsqueeze(0)
            v = v.unsqueeze(0)
        var unbatched = q.dim() == 2
        if unbatched:
            q = q.unsqueeze(0)
            k = k.unsqueeze(0)
            v = v.unsqueeze(0)
        elif not self.batch_first:
            q = q.transpose(0, 1)
            k = k.transpose(0, 1)
            v = v.transpose(0, 1)
        # now (N, L, E)
        var N = q.size()[0]
        var L = q.size()[1]
        var S = k.size()[1]
        var H = self.num_heads
        var D = self.head_dim
        var qh = self._proj(q, 0).reshape([N, L, H, D]).transpose(1, 2)
        var kh = self._proj(k, 1).reshape([N, S, H, D]).transpose(1, 2)
        var vh = self._proj(v, 2).reshape([N, S, H, D]).transpose(1, 2)
        var mask = none
        if attn_mask != none:
            mask = _a_mask_to_add(attn_mask)
        if key_padding_mask != none:
            var kp = _a_mask_to_add(key_padding_mask).reshape([N, 1, 1, S])
            if mask == none:
                mask = kp
            else:
                mask = mask + kp
        var r = scaled_dot_product_attention(qh, kh, vh, mask, self.dropout, false, self.training)
        var o = r[0].transpose(1, 2).reshape([N, L, self.embed_dim])
        var out = self.out_proj.forward(o)
        var w = r[1].mean(1)
        if unbatched:
            out = out.squeeze(0)
            w = w.squeeze(0)
        elif not self.batch_first:
            out = out.transpose(0, 1)
        if vec:
            out = out.squeeze(0)
        return [out, w]


# ── older attention API ─────────────────────────────────────────────────────
class SelfAttention(Module):
    # single-head self-attention over a sequence (L, dim); 1-d = one token
    def __init__(self, dim):
        super().__init__()
        self.dim = dim
        self.Wq = Linear(dim, dim)
        self.Wk = Linear(dim, dim)
        self.Wv = Linear(dim, dim)
    def forward(self, x):
        var t = _t_wrap(x)
        var vec = t.dim() == 1
        if vec:
            t = t.unsqueeze(0)
        var out = scaled_dot_product_attention(self.Wq.forward(t), self.Wk.forward(t), self.Wv.forward(t), none, 0.0, false, false)[0]
        if vec:
            return out.squeeze(0)
        return out

class CausalSelfAttention(Module):
    # masked self-attention: position i only sees positions <= i
    def __init__(self, dim):
        super().__init__()
        self.dim = dim
        self.Wq = Linear(dim, dim)
        self.Wk = Linear(dim, dim)
        self.Wv = Linear(dim, dim)
        self.Wo = Linear(dim, dim)
    def forward(self, x):
        var t = _t_wrap(x)
        var vec = t.dim() == 1
        if vec:
            t = t.unsqueeze(0)
        var a = scaled_dot_product_attention(self.Wq.forward(t), self.Wk.forward(t), self.Wv.forward(t), none, 0.0, true, false)[0]
        var out = self.Wo.forward(a)
        if vec:
            return out.squeeze(0)
        return out

class MultiHeadAttention(Module):
    # older name: forward(query, key, value) -> output only
    def __init__(self, d_model, num_heads):
        super().__init__()
        self.d_model = d_model
        self.num_heads = num_heads
        self.mha = MultiheadAttention(d_model, num_heads)
    def __call__(self, query, key, value):
        return self.forward(query, key, value)
    def forward(self, query, key, value):
        return self.mha.forward(query, key, value, none, none)[0]

class LinearAttention(Module):
    # O(L) attention with feature map phi(x) = elu(x) + 1 (Katharopoulos 2020):
    # out_i = phi(q_i) (sum_j phi(k_j)^T v_j) / (phi(q_i) . sum_j phi(k_j))
    def __init__(self, d_model):
        super().__init__()
        self.d_model = d_model
        self.Wq = Linear(d_model, d_model)
        self.Wk = Linear(d_model, d_model)
        self.Wv = Linear(d_model, d_model)
    def __call__(self, query, key, value):
        return self.forward(query, key, value)
    def forward(self, query, key, value):
        var q = _t_wrap(query)
        var vec = q.dim() == 1
        var k = _t_wrap(key)
        var v = _t_wrap(value)
        if vec:
            q = q.unsqueeze(0)
            k = k.unsqueeze(0)
            v = v.unsqueeze(0)
        var fq = self.Wq.forward(q).elu(1.0) + 1.0
        var fk = self.Wk.forward(k).elu(1.0) + 1.0
        var vv = self.Wv.forward(v)
        var kv = fk.transpose(-2, -1).matmul(vv)
        var z = fq.matmul(fk.sum(-2, true).transpose(-2, -1))
        var out = fq.matmul(kv).div(z)
        if vec:
            return out.squeeze(0)
        return out

class TransformerBlock(Module):
    # post-norm encoder block: norm1(x + MHA(x)), norm2(h + FFN(h)), GELU FFN
    def __init__(self, d_model, num_heads, ff_dim):
        super().__init__()
        self.attn = MultiheadAttention(d_model, num_heads)
        self.ff1 = Linear(d_model, ff_dim)
        self.ff2 = Linear(ff_dim, d_model)
        self.norm1 = LayerNorm(d_model)
        self.norm2 = LayerNorm(d_model)
    def forward(self, x):
        var t = _t_wrap(x)
        var a = self.attn.forward(t, t, t, none, none)[0]
        var h = self.norm1.forward(t + a)
        return self.norm2.forward(h + self.ff2.forward(self.ff1.forward(h).gelu()))


# ── transformer encoder ─────────────────────────────────────────────────────
class TransformerEncoderLayer(Module):
    # torch.nn.TransformerEncoderLayer(d_model, nhead, dim_feedforward=2048,
    # dropout=0.1, activation="relu", batch_first=false, norm_first=false)
    def __init__(self, d_model, nhead, dim_feedforward=2048, dropout=0.1, activation="relu", batch_first=false, norm_first=false):
        super().__init__()
        self.d_model = d_model
        self.nhead = nhead
        self.dim_feedforward = dim_feedforward
        self.activation = activation
        self.norm_first = norm_first
        self.self_attn = MultiheadAttention(d_model, nhead, dropout, true, batch_first)
        self.linear1 = Linear(d_model, dim_feedforward)
        self.linear2 = Linear(dim_feedforward, d_model)
        self.norm1 = LayerNorm(d_model)
        self.norm2 = LayerNorm(d_model)
        self.dropout = Dropout(dropout)
        self.dropout1 = Dropout(dropout)
        self.dropout2 = Dropout(dropout)
        self.name = "TransformerEncoderLayer"

    def __call__(self, src, src_mask=none, src_key_padding_mask=none):
        return self.forward(src, src_mask, src_key_padding_mask)

    def _sa(self, x, mask, kpm):
        return self.dropout1.forward(self.self_attn.forward(x, x, x, mask, kpm)[0])

    def _ff(self, x):
        var h = self.linear1.forward(x)
        if self.activation == "gelu":
            h = h.gelu()
        else:
            h = h.relu()
        return self.dropout2.forward(self.linear2.forward(self.dropout.forward(h)))

    # src_mask: an attention mask, or false/none (the older API passed a bool)
    def forward(self, src, src_mask=none, src_key_padding_mask=none):
        var mask = src_mask
        if mask == false or mask == true:
            mask = none
        var x = _t_wrap(src)
        if self.norm_first:
            x = x + self._sa(self.norm1.forward(x), mask, src_key_padding_mask)
            return x + self._ff(self.norm2.forward(x))
        x = self.norm1.forward(x + self._sa(x, mask, src_key_padding_mask))
        return self.norm2.forward(x + self._ff(x))

    def get_name(self):
        return self.name


# ── recurrent layers ────────────────────────────────────────────────────────
# Cells take (N, input_size) or (input_size,) and a hidden state of the
# matching shape (zeros when none). Weights follow torch: weight_ih
# [gates*hidden, input], weight_hh [gates*hidden, hidden], both biases.
def _r_param(shape, bound):
    return Parameter(Tensor(_t_fix(nt_uniform(shape, 0.0 - bound, bound), shape), false, shape))

def _r_zeros_like_batch(x, hidden):
    var t = _t_wrap(x)
    if t.dim() == 1:
        return Tensor(nt_full([hidden], 0.0), false, [hidden])
    var n = t.size()[0]
    return Tensor(nt_full([n, hidden], 0.0), false, [n, hidden])

class RNNCell(Module):
    def __init__(self, input_size, hidden_size, bias=true, nonlinearity="tanh"):
        super().__init__()
        self.input_size = input_size
        self.hidden_size = hidden_size
        self.nonlinearity = nonlinearity
        var k = 1.0 / sqrt(1.0 * hidden_size)
        self.weight_ih = _r_param([hidden_size, input_size], k)
        self.weight_hh = _r_param([hidden_size, hidden_size], k)
        self.bias_ih = none
        self.bias_hh = none
        if bias:
            self.bias_ih = _r_param([hidden_size], k)
            self.bias_hh = _r_param([hidden_size], k)
    def __call__(self, x, h=none):
        return self.forward(x, h)
    def forward(self, x, h=none):
        var hx = h
        if hx == none:
            hx = _r_zeros_like_batch(x, self.hidden_size)
        var z = _fn_linear(x, self.weight_ih, self.bias_ih) + _fn_linear(hx, self.weight_hh, self.bias_hh)
        if self.nonlinearity == "relu":
            return z.relu()
        return z.tanh()
    def zero_hidden(self):
        return Tensor(nt_full([self.hidden_size], 0.0), false, [self.hidden_size])

class GRUCell(Module):
    def __init__(self, input_size, hidden_size, bias=true):
        super().__init__()
        self.input_size = input_size
        self.hidden_size = hidden_size
        var k = 1.0 / sqrt(1.0 * hidden_size)
        self.weight_ih = _r_param([3 * hidden_size, input_size], k)
        self.weight_hh = _r_param([3 * hidden_size, hidden_size], k)
        self.bias_ih = none
        self.bias_hh = none
        if bias:
            self.bias_ih = _r_param([3 * hidden_size], k)
            self.bias_hh = _r_param([3 * hidden_size], k)
    def __call__(self, x, h=none):
        return self.forward(x, h)
    def forward(self, x, h=none):
        var hx = h
        if hx == none:
            hx = _r_zeros_like_batch(x, self.hidden_size)
        var H = self.hidden_size
        var gi = _fn_linear(x, self.weight_ih, self.bias_ih)
        var gh = _fn_linear(hx, self.weight_hh, self.bias_hh)
        var r = (gi.slice(-1, 0, H) + gh.slice(-1, 0, H)).sigmoid()
        var z = (gi.slice(-1, H, 2 * H) + gh.slice(-1, H, 2 * H)).sigmoid()
        var n = (gi.slice(-1, 2 * H, 3 * H) + r * gh.slice(-1, 2 * H, 3 * H)).tanh()
        return z.rsub(1.0) * n + z * hx
    def zero_hidden(self):
        return Tensor(nt_full([self.hidden_size], 0.0), false, [self.hidden_size])

class LSTMCell(Module):
    # gates i, f, g, o; returns [h, c]
    def __init__(self, input_size, hidden_size, bias=true):
        super().__init__()
        self.input_size = input_size
        self.hidden_size = hidden_size
        var k = 1.0 / sqrt(1.0 * hidden_size)
        self.weight_ih = _r_param([4 * hidden_size, input_size], k)
        self.weight_hh = _r_param([4 * hidden_size, hidden_size], k)
        self.bias_ih = none
        self.bias_hh = none
        if bias:
            self.bias_ih = _r_param([4 * hidden_size], k)
            self.bias_hh = _r_param([4 * hidden_size], k)
    def __call__(self, x, state=none):
        return self.forward(x, state)
    def forward(self, x, state=none):
        var h = none
        var c = none
        if state == none:
            h = _r_zeros_like_batch(x, self.hidden_size)
            c = _r_zeros_like_batch(x, self.hidden_size)
        else:
            h = state[0]
            c = state[1]
        var H = self.hidden_size
        var g = _fn_linear(x, self.weight_ih, self.bias_ih) + _fn_linear(h, self.weight_hh, self.bias_hh)
        var i = g.slice(-1, 0, H).sigmoid()
        var f = g.slice(-1, H, 2 * H).sigmoid()
        var gg = g.slice(-1, 2 * H, 3 * H).tanh()
        var o = g.slice(-1, 3 * H, 4 * H).sigmoid()
        var c2 = f * c + i * gg
        var h2 = o * c2.tanh()
        return [h2, c2]
    def zero_state(self):
        var z = Tensor(nt_full([self.hidden_size], 0.0), false, [self.hidden_size])
        return [z, Tensor(nt_full([self.hidden_size], 0.0), false, [self.hidden_size])]

# Multi-step, multi-layer recurrent layers. forward(input, h0):
#   input (L, N, H_in) [or (N, L, H_in) with batch_first] or unbatched (L, H_in)
#   RNN/GRU -> [output (L, N, H), h_n (num_layers, N, H)]
#   LSTM    -> [output, [h_n, c_n]]
# The older API passed a LIST of 1-d tensors; that still works and returns
# [list_of_outputs, h] (LSTM: [list_of_outputs, h, c]).
class _RecurrentBase(Module):
    def __init__(self):
        super().__init__()
    def _setup(self, kind, input_size, hidden_size, num_layers, batch_first):
        self.kind = kind
        self.input_size = input_size
        self.hidden_size = hidden_size
        self.num_layers = num_layers
        self.batch_first = batch_first
        self.cells = []
        var l = 0
        while l < num_layers:
            var isz = input_size
            if l > 0:
                isz = hidden_size
            if kind == "lstm":
                self.cells.append(LSTMCell(isz, hidden_size))
            elif kind == "gru":
                self.cells.append(GRUCell(isz, hidden_size))
            else:
                self.cells.append(RNNCell(isz, hidden_size))
            l = l + 1

    def _run(self, x, h0):
        if type(x) == "list":
            return self._run_list(x)
        var t = _t_wrap(x)
        var unbatched = t.dim() == 2
        if unbatched:
            t = t.unsqueeze(1)
        elif self.batch_first:
            t = t.transpose(0, 1)
        var L = t.size()[0]
        var layer_in = []
        var s = 0
        while s < L:
            layer_in.append(t.select(0, s))
            s = s + 1
        var hs = []
        var cs = []
        var l = 0
        while l < self.num_layers:
            var cell = self.cells[l]
            var h = none
            var c = none
            if h0 != none:
                if self.kind == "lstm":
                    h = h0[0].select(0, l)
                    c = h0[1].select(0, l)
                else:
                    h = h0.select(0, l)
                if unbatched:
                    h = h.unsqueeze(0)
                    if c != none:
                        c = c.unsqueeze(0)
            var outs = []
            s = 0
            while s < L:
                if self.kind == "lstm":
                    var st = none
                    if h != none:
                        st = [h, c]
                    var hc = cell.forward(layer_in[s], st)
                    h = hc[0]
                    c = hc[1]
                else:
                    h = cell.forward(layer_in[s], h)
                outs.append(h)
                s = s + 1
            hs.append(h)
            if c != none:
                cs.append(c)
            layer_in = outs
            l = l + 1
        var out = _t_stack(layer_in, 0)
        var hn = _t_stack(hs, 0)
        var cn = none
        if self.kind == "lstm":
            cn = _t_stack(cs, 0)
        if unbatched:
            out = out.squeeze(1)
            hn = hn.squeeze(1)
            if cn != none:
                cn = cn.squeeze(1)
        elif self.batch_first:
            out = out.transpose(0, 1)
        if self.kind == "lstm":
            return [out, [hn, cn]]
        return [out, hn]

    def _run_list(self, seq):
        var cell = self.cells[0]
        var h = none
        var c = none
        var outs = []
        var i = 0
        while i < len(seq):
            if self.kind == "lstm":
                var st = none
                if h != none:
                    st = [h, c]
                var hc = cell.forward(seq[i], st)
                h = hc[0]
                c = hc[1]
            else:
                h = cell.forward(seq[i], h)
            outs.append(h)
            i = i + 1
        if self.kind == "lstm":
            return [outs, h, c]
        return [outs, h]

class RNN(_RecurrentBase):
    def __init__(self, input_size, hidden_size, num_layers=1, batch_first=false):
        super().__init__()
        self._setup("rnn", input_size, hidden_size, num_layers, batch_first)
    def __call__(self, x, h0=none):
        return self._run(x, h0)
    def forward(self, x, h0=none):
        return self._run(x, h0)

class GRU(_RecurrentBase):
    def __init__(self, input_size, hidden_size, num_layers=1, batch_first=false):
        super().__init__()
        self._setup("gru", input_size, hidden_size, num_layers, batch_first)
    def __call__(self, x, h0=none):
        return self._run(x, h0)
    def forward(self, x, h0=none):
        return self._run(x, h0)

class LSTM(_RecurrentBase):
    def __init__(self, input_size, hidden_size, num_layers=1, batch_first=false):
        super().__init__()
        self._setup("lstm", input_size, hidden_size, num_layers, batch_first)
    def __call__(self, x, state=none):
        return self._run(x, state)
    def forward(self, x, state=none):
        return self._run(x, state)
