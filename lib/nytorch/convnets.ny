# ═══════════════════════════════════════════════════════════════════════════
# NyTorch - Part 14: vision, audio/speech, time series, MLOps
# Classes 231-260
#
# 1-d convolutional networks (ResNet, TCN, WaveNet), a YOLO detection head
# with real box decoding and NMS, a ViT, log-mel spectrograms and MFCCs,
# CTC decoding and a CTC-trained speech recogniser, ARIMA fitted by
# Hannan-Rissanen least squares, a time-series transformer, and MLOps tools
# (experiment tracking, metrics, alerts, checkpoints on disk, an LR range
# test that really trains, a GP-based Bayesian optimiser).
#
# Signals are channels x length: a (C, L) tensor, a batch (N, C, L), or a
# flat list of C * L values read as C rows.
# ═══════════════════════════════════════════════════════════════════════════

import "lib/nytorch/core.ny"
import "lib/nytorch/reinforcement.ny"

# (C, L) / (N, C, L) tensor, or a flat list of C * L values -> (C, L) or (N, C, L)
def _cv_seq(x, channels):
    var t = _t_wrap(x)
    if t.dim() >= 2:
        return t
    if t.numel() % channels != 0:
        raise ValueError("a signal of " + str(t.numel()) + " values is not " + str(channels) + " channels")
    return t.reshape([channels, t.numel() // channels])

# zeros on the left of the last (time) dimension
def _cv_left_pad(x, p):
    if p <= 0:
        return x
    var s = x.shape[:]
    s[len(s) - 1] = p
    return torch.cat([Tensor(nt_full(s, 0.0), false, s), x], len(s) - 1)

def _cv_act(h, name):
    if name == "relu":
        return h.relu()
    if name == "leaky_relu":
        return h.leaky_relu(0.01)
    if name == "silu":
        return h.silu()
    if name == "gelu":
        return h.gelu()
    if name == "none" or name == none:
        return h
    raise ValueError("unknown activation '" + str(name) + "'")

def _cv_batch(x):
    # (C, L) -> [(1, C, L), true]; (N, C, L) -> [x, false]
    if x.dim() == 2:
        return [x.unsqueeze(0), true]
    return [x, false]

def _cv_unbatch(y, was):
    if was:
        return y.squeeze(0)
    return y


# ── 231: ConvBlock: Conv1d ("same" padding) -> BatchNorm1d -> activation ────
class ConvBlock(Module):
    def __init__(self, in_ch, out_ch, kernel, stride, use_bn, activation):
        super().__init__()
        self.in_ch = in_ch
        self.out_ch = out_ch
        self.kernel = kernel
        self.stride = stride
        self.use_bn = use_bn
        self.activation = activation
        self.conv = Conv1d(in_ch, out_ch, kernel, stride, kernel // 2)
        self.bn = none
        if use_bn:
            self.bn = BatchNorm1d(out_ch)
        self.name = "ConvBlock"

    # x: (C, L), (N, C, L) or a flat list; training selects batch statistics
    def forward(self, x, training):
        self.train_mode(training)
        var b = _cv_batch(_cv_seq(x, self.in_ch))
        var h = self.conv.forward(b[0])
        if self.bn != none:
            h = self.bn.forward(h)
        return _cv_unbatch(_cv_act(h, self.activation), b[1])

    def get_n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 232: ResidualBlock (He et al. 2016, 1-d) ───────────────────────────────
#   relu(x + BN(conv(dropout(relu(BN(conv(x)))))))
class ResidualBlock(Module):
    def __init__(self, channels, kernel, dropout_rate):
        super().__init__()
        self.channels = channels
        self.kernel = kernel
        self.dropout_rate = dropout_rate
        self.conv1 = Conv1d(channels, channels, kernel, 1, kernel // 2, 1, 1, false)
        self.bn1 = BatchNorm1d(channels)
        self.conv2 = Conv1d(channels, channels, kernel, 1, kernel // 2, 1, 1, false)
        self.bn2 = BatchNorm1d(channels)
        self.drop = Dropout(dropout_rate)
        self.name = "ResidualBlock"

    def forward(self, x, training):
        self.train_mode(training)
        var b = _cv_batch(_cv_seq(x, self.channels))
        var h = self.drop.forward(self.bn1.forward(self.conv1.forward(b[0])).relu())
        h = self.bn2.forward(self.conv2.forward(h))
        return _cv_unbatch((h + b[0]).relu(), b[1])

    def get_name(self):
        return self.name


# ── 233: SimpleResNet: stem conv -> residual blocks -> global average pool
# -> linear classifier. forward returns logits (n_classes,) per signal.
class SimpleResNet(Module):
    def __init__(self, in_channels, n_blocks, hidden_channels, n_classes):
        super().__init__()
        self.in_channels = in_channels
        self.n_blocks = n_blocks
        self.hidden_channels = hidden_channels
        self.n_classes = n_classes
        self.stem = Conv1d(in_channels, hidden_channels, 7, 1, 3)
        self.stem_bn = BatchNorm1d(hidden_channels)
        self.blocks = []
        var i = 0
        while i < n_blocks:
            self.blocks.append(ResidualBlock(hidden_channels, 3, 0.1))
            i = i + 1
        self.head = Linear(hidden_channels, n_classes)
        self.name = "SimpleResNet"

    def forward(self, x, training):
        self.train_mode(training)
        var b = _cv_batch(_cv_seq(x, self.in_channels))
        var h = self.stem_bn.forward(self.stem.forward(b[0])).relu()
        var i = 0
        while i < len(self.blocks):
            h = self.blocks[i].forward(h, training)
            i = i + 1
        return _cv_unbatch(self.head.forward(h.mean(2)), b[1])

    # class probabilities as a list
    def classify(self, x):
        var p = none
        with no_grad():
            p = self.forward(x, false).softmax(-1)
        return p.data

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 234: YOLOHead (Redmon & Farhadi 2018) ──────────────────────────────────
# A 1x1 convolution over an (in_channels, S, S) feature map predicts, per
# cell and anchor, (tx, ty, tw, th, objectness, class logits). decode:
#   bx = (sigmoid(tx) + cx) stride,  bw = anchor_w exp(tw), ...
#   score = sigmoid(obj) * max_c sigmoid(class_c)
# then confidence filtering and per-class NMS. Boxes are [cx, cy, w, h].
class YOLOHead(Module):
    def __init__(self, n_classes, n_anchors, grid_size, in_channels=64, stride=32):
        super().__init__()
        self.n_classes = n_classes
        self.n_anchors = n_anchors
        self.grid_size = grid_size
        self.in_channels = in_channels
        self.stride = stride
        self.n_outputs = n_anchors * (5 + n_classes)
        self.conv = Linear(in_channels, self.n_outputs)
        var base = [[116.0, 90.0], [156.0, 198.0], [373.0, 326.0], [30.0, 61.0], [62.0, 45.0], [59.0, 119.0], [10.0, 13.0], [16.0, 30.0], [33.0, 23.0]]
        self.anchors = []
        var i = 0
        while i < n_anchors:
            self.anchors.append(base[i % len(base)])
            i = i + 1
        self.iou_threshold = 0.5
        self.conf_threshold = 0.25
        self.name = "YOLOHead"

    def decode_box(self, tx, ty, tw, th, anchor_w, anchor_h, grid_x, grid_y, stride):
        var bx = (sigmoid(tx) + float(grid_x)) * float(stride)
        var by = (sigmoid(ty) + float(grid_y)) * float(stride)
        return [bx, by, exp(tw) * anchor_w, exp(th) * anchor_h]

    def compute_iou(self, box1, box2):
        var x1 = max(box1[0] - box1[2] / 2.0, box2[0] - box2[2] / 2.0)
        var y1 = max(box1[1] - box1[3] / 2.0, box2[1] - box2[3] / 2.0)
        var x2 = min(box1[0] + box1[2] / 2.0, box2[0] + box2[2] / 2.0)
        var y2 = min(box1[1] + box1[3] / 2.0, box2[1] + box2[3] / 2.0)
        var inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
        var union_area = box1[2] * box1[3] + box2[2] * box2[3] - inter
        if union_area < 0.00000001:
            return 0.0
        return inter / union_area

    # greedy NMS: indices kept, highest score first
    def nms(self, boxes, scores):
        var order = tensor_topk(scores, len(scores))
        var keep = []
        var i = 0
        while i < len(order):
            var idx = order[i]["index"]
            var ok = true
            var j = 0
            while j < len(keep):
                if self.compute_iou(boxes[idx], boxes[keep[j]]) > self.iou_threshold:
                    ok = false
                j = j + 1
            if ok:
                keep.append(idx)
            i = i + 1
        return keep

    # raw predictions (S, S, n_anchors, 5 + n_classes) from (C, S, S) or a flat map
    def raw(self, feature_map):
        var t = _t_wrap(feature_map)
        var C = self.in_channels
        if t.dim() == 1:
            var cells = t.numel() // C
            var S = int(sqrt(float(cells)) + 0.5)
            if S * S * C != t.numel():
                raise ValueError("feature map of " + str(t.numel()) + " values is not " + str(C) + " x S x S")
            t = t.reshape([C, S, S])
        var S2 = t.size()[1]
        var cells2 = t.permute([1, 2, 0]).reshape([S2 * S2, C])
        return self.conv.forward(cells2).reshape([S2, S2, self.n_anchors, 5 + self.n_classes])

    # -> [{"conf", "class", "box"}] after thresholding and per-class NMS
    def forward(self, feature_map):
        var r = none
        with no_grad():
            r = self.raw(feature_map)
        var S = r.size()[0]
        var P = 5 + self.n_classes
        var d = _t_flat(r.data)
        var boxes = []
        var scores = []
        var classes = []
        var gy = 0
        while gy < S:
            var gx = 0
            while gx < S:
                var a = 0
                while a < self.n_anchors:
                    var o = ((gy * S + gx) * self.n_anchors + a) * P
                    var best_c = 0
                    var best_p = 0.0
                    var c = 0
                    while c < self.n_classes:
                        var pc = sigmoid(d[o + 5 + c])
                        if pc > best_p:
                            best_p = pc
                            best_c = c
                        c = c + 1
                    var conf = sigmoid(d[o + 4]) * best_p
                    if conf > self.conf_threshold:
                        boxes.append(self.decode_box(d[o], d[o + 1], d[o + 2], d[o + 3], self.anchors[a][0], self.anchors[a][1], gx, gy, self.stride))
                        scores.append(conf)
                        classes.append(best_c)
                    a = a + 1
                gx = gx + 1
            gy = gy + 1
        var out = []
        var cls_seen = sorted(classes)
        var k = 0
        while k < len(cls_seen):
            var cl = cls_seen[k]
            if k == 0 or cls_seen[k - 1] != cl:
                var bi = []
                var bb = []
                var bs = []
                var i = 0
                while i < len(classes):
                    if classes[i] == cl:
                        bi.append(i)
                        bb.append(boxes[i])
                        bs.append(scores[i])
                    i = i + 1
                var kept = self.nms(bb, bs)
                var j = 0
                while j < len(kept):
                    out.append({"conf": bs[kept[j]], "class": cl, "box": bb[kept[j]]})
                    j = j + 1
            k = k + 1
        return out

    def get_name(self):
        return self.name


# ── 235: SegmentationHead (1-d): nearest upsampling, 3-tap conv to class
# logits, per-position softmax; class_probs are the average over positions.
class SegmentationHead(Module):
    def __init__(self, in_channels, n_classes, upsample_factor):
        super().__init__()
        self.in_channels = in_channels
        self.n_classes = n_classes
        self.upsample_factor = upsample_factor
        self.conv = Conv1d(in_channels, n_classes, 3, 1, 1)
        self.name = "SegmentationHead"

    # (C, L) -> (C, L * factor), each position repeated
    def upsample(self, feature, factor):
        var t = _t_wrap(feature)
        var L = t.size()[t.dim() - 1]
        var idx = []
        var i = 0
        while i < L * factor:
            idx.append(i // factor)
            i = i + 1
        return t.index_select(t.dim() - 1, idx)

    def forward(self, features):
        var x = _cv_seq(features, self.in_channels)
        var logits = self.conv.forward(self.upsample(x, self.upsample_factor))
        var probs = logits.softmax(0)
        return {"pixel_probs": probs, "class_probs": probs.mean(1), "logits": logits}

    def get_name(self):
        return self.name


# ── 236: ImagePatchEmbedder (ViT patchify, Dosovitskiy et al. 2021) ─────────
# A single-channel img_size x img_size image (flat or 2-d) -> [CLS, patches]
# linearly embedded, plus learned positions: (n_patches + 1, embed_dim).
class ImagePatchEmbedder(Module):
    def __init__(self, img_size, patch_size, embed_dim):
        super().__init__()
        if img_size % patch_size != 0:
            raise ValueError("img_size must be a multiple of patch_size")
        self.img_size = img_size
        self.patch_size = patch_size
        self.embed_dim = embed_dim
        self.n_side = img_size // patch_size
        self.n_patches = self.n_side * self.n_side
        self.projection = Linear(patch_size * patch_size, embed_dim)
        self.cls_token = Parameter(Tensor(nt_normal(embed_dim, 0.0, 0.02)))
        var ps = [self.n_patches + 1, embed_dim]
        self.pos_embed = Parameter(Tensor(nt_normal(ps, 0.0, 0.02), false, ps))
        self.name = "ImagePatchEmbedder"

    def patches(self, image):
        var t = _t_wrap(image)
        if t.numel() != self.img_size * self.img_size:
            raise ValueError("expected " + str(self.img_size) + "x" + str(self.img_size) + " pixels, got " + str(t.numel()))
        var p = self.patch_size
        var n = self.n_side
        return t.reshape([n, p, n, p]).permute([0, 2, 1, 3]).reshape([n * n, p * p])

    def embed_patch(self, patch_data):
        return self.projection.forward(_t_wrap(patch_data))

    def forward(self, flat_image):
        var e = self.projection.forward(self.patches(flat_image))
        return torch.cat([self.cls_token.unsqueeze(0), e], 0) + self.pos_embed

    def get_n_patches(self):
        return self.n_patches

    def get_name(self):
        return self.name


# ── 237: VisionTransformer: patch embedding -> pre-norm encoder layers ->
# LayerNorm -> linear head on the CLS token.
class VisionTransformer(Module):
    def __init__(self, img_size, patch_size, embed_dim, n_heads, n_layers, n_classes, mlp_ratio):
        super().__init__()
        self.img_size = img_size
        self.patch_size = patch_size
        self.embed_dim = embed_dim
        self.n_heads = n_heads
        self.n_layers = n_layers
        self.n_classes = n_classes
        self.mlp_ratio = mlp_ratio
        self.patch_embed = ImagePatchEmbedder(img_size, patch_size, embed_dim)
        self.n_patches = self.patch_embed.get_n_patches()
        self.layers = []
        var i = 0
        while i < n_layers:
            self.layers.append(TransformerEncoderLayer(embed_dim, n_heads, int(embed_dim * mlp_ratio), 0.0, "gelu", false, true))
            i = i + 1
        self.norm = LayerNorm(embed_dim)
        self.head = Linear(embed_dim, n_classes)
        self.name = "VisionTransformer"

    def forward(self, flat_image):
        var h = self.patch_embed.forward(flat_image)
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h, none, none)
            i = i + 1
        return self.head.forward(self.norm.forward(h).select(0, 0))

    def classify(self, flat_image):
        var p = none
        with no_grad():
            p = self.forward(flat_image).softmax(0)
        return {"probs": p.data, "pred_class": p.argmax().item()}

    def n_params(self):
        return self.num_parameters()

    def get_name(self):
        return self.name


# ── 238: MelSpectrogram: power STFT (Hann window, centred frames) through a
# triangular mel filterbank on [f_min, f_max] -> (n_frames, n_mels).
class MelSpectrogram:
    def __init__(self, sample_rate, n_fft, hop_length, n_mels, f_min, f_max):
        self.sample_rate = sample_rate
        self.n_fft = n_fft
        self.hop_length = hop_length
        self.n_mels = n_mels
        self.f_min = f_min
        self.f_max = f_max
        var fb = nt_mel_filterbank(n_mels, n_fft, float(sample_rate), f_min, f_max)
        self.filterbank = Tensor(fb[0], false, fb[1])
        self.name = "MelSpectrogram"

    # magnitude STFT (n_fft/2 + 1, n_frames)
    def stft(self, waveform):
        var r = nt_stft(_t_flat(_t_wrap(waveform).data), self.n_fft, self.hop_length)
        return Tensor(r[0], false, r[1])

    def compute(self, waveform):
        var S = self.stft(waveform)
        return (self.filterbank.matmul(S * S)).t()

    def compute_db(self, waveform):
        return self.compute(waveform).clamp(0.0000000001, 1e300).log() * (10.0 / log(10.0))

    def get_n_mels(self):
        return self.n_mels

    def get_name(self):
        return self.name


# ── 239: MFCCExtractor: log mel energies -> orthonormal DCT-II, the first
# n_mfcc coefficients; returned as (n_mfcc, n_frames) like librosa.
class MFCCExtractor:
    def __init__(self, sample_rate, n_mfcc, n_mels, n_fft, hop_length):
        self.sample_rate = sample_rate
        self.n_mfcc = n_mfcc
        self.n_mels = n_mels
        self.n_fft = n_fft
        self.hop_length = hop_length
        self.mel_spec = MelSpectrogram(sample_rate, n_fft, hop_length, n_mels, 0.0, float(sample_rate) / 2.0)
        var d = nt_dct_matrix(n_mfcc, n_mels)
        self.dct = Tensor(d[0], false, d[1])
        self.name = "MFCCExtractor"

    def extract(self, waveform):
        var logmel = self.mel_spec.compute(waveform).clamp(0.0000000001, 1e300).log()
        return self.dct.matmul(logmel.t())

    # first differences along time, (n_mfcc, n_frames - 1)
    def extract_delta(self, waveform):
        var c = self.extract(waveform)
        var T = c.size()[1]
        var delta = c.slice(1, 1, T) - c.slice(1, 0, T - 1)
        return {"mfcc": c, "delta": delta, "n_coeffs": self.n_mfcc}

    def get_name(self):
        return self.name


# ── 240: WaveNetBlock (van den Oord et al. 2016) ───────────────────────────
# z = tanh(W_f *_d x) . sigmoid(W_g *_d x) with causal dilated convolutions;
# returns [x + W_res z, skip_accum + W_skip z] (1x1 convolutions).
class WaveNetBlock(Module):
    def __init__(self, channels, dilation, kernel):
        super().__init__()
        self.channels = channels
        self.dilation = dilation
        self.kernel = kernel
        self.filter_conv = Conv1d(channels, channels, kernel, 1, 0, dilation)
        self.gate_conv = Conv1d(channels, channels, kernel, 1, 0, dilation)
        self.res_conv = Conv1d(channels, channels, 1)
        self.skip_conv = Conv1d(channels, channels, 1)
        self.name = "WaveNetBlock"

    def dilated_conv(self, x, conv, dilation):
        return conv.forward(_cv_left_pad(x, (self.kernel - 1) * dilation))

    def forward(self, x, skip_accum):
        var h = _cv_seq(x, self.channels)
        var z = self.dilated_conv(h, self.filter_conv, self.dilation).tanh() * self.dilated_conv(h, self.gate_conv, self.dilation).sigmoid()
        var skip = self.skip_conv.forward(z)
        if not _t_isnum(skip_accum):
            skip = skip + skip_accum
        elif skip_accum != 0:
            skip = skip + skip_accum
        return [h + self.res_conv.forward(z), skip]

    def get_dilation(self):
        return self.dilation

    def get_name(self):
        return self.name


# ── 241: WaveNet: causal input conv, n_cycles x n_layers blocks with
# dilations 1, 2, 4, ..., relu(sum of skips) -> 1x1 -> relu -> 1x1 to
# n_classes (mu-law bins). logits(x) is (n_classes, L); forward(x) is the
# predicted distribution of the next sample, as a list.
class WaveNet(Module):
    def __init__(self, channels, n_layers, n_cycles, n_classes):
        super().__init__()
        self.channels = channels
        self.n_layers = n_layers
        self.n_cycles = n_cycles
        self.n_classes = n_classes
        self.input_conv = Conv1d(1, channels, 2)
        self.blocks = []
        var c = 0
        while c < n_cycles:
            var d = 1
            var l = 0
            while l < n_layers:
                self.blocks.append(WaveNetBlock(channels, d, 2))
                d = d * 2
                l = l + 1
            c = c + 1
        self.out1 = Conv1d(channels, channels, 1)
        self.out2 = Conv1d(channels, n_classes, 1)
        self.name = "WaveNet"

    def logits(self, x):
        var h = self.input_conv.forward(_cv_left_pad(_cv_seq(x, 1), 1))
        var skip = 0.0
        var i = 0
        while i < len(self.blocks):
            var r = self.blocks[i].forward(h, skip)
            h = r[0]
            skip = r[1]
            i = i + 1
        return self.out2.forward(self.out1.forward(skip.relu()).relu())

    def forward(self, x):
        var p = none
        with no_grad():
            var lg = self.logits(x)
            p = lg.select(1, lg.size()[1] - 1).softmax(0)
        return p.data

    def n_blocks(self):
        return self.n_layers * self.n_cycles

    def get_name(self):
        return self.name


# ── 242: CTCDecoder ────────────────────────────────────────────────────────
class CTCDecoder:
    def __init__(self, vocab, blank_id):
        self.vocab = vocab
        self.blank_id = blank_id
        self.vocab_size = len(vocab)
        self.name = "CTCDecoder"

    # best path: argmax per frame, merge repeats, drop blanks. A frame is a
    # score vector, or already a label id.
    def greedy_decode(self, log_probs_seq):
        var frames = log_probs_seq
        if isinstance(frames, Tensor):
            var rows = []
            var r = 0
            while r < frames.size()[0]:
                rows.append(frames.select(0, r).data)
                r = r + 1
            frames = rows
        var tokens = []
        var prev = self.blank_id
        var i = 0
        while i < len(frames):
            var f = frames[i]
            var best = 0
            if _t_isnum(f):
                best = int(f)
                if best < 0 or best >= self.vocab_size:
                    raise IndexError("label " + str(best) + " out of range for a vocabulary of " + str(self.vocab_size))
            else:
                best = Tensor(_t_flat(_t_wrap(f).data)).argmax().item()
            if best != self.blank_id and best != prev:
                tokens.append(best)
            prev = best
            i = i + 1
        return tokens

    def decode_to_string(self, token_ids):
        var s = ""
        var i = 0
        while i < len(token_ids):
            if token_ids[i] < len(self.vocab):
                s = s + self.vocab[token_ids[i]]
            i = i + 1
        return s

    # CTC negative log-likelihood of the target ids under per-frame
    # log-probabilities (T, V) (differentiable when log_probs is a Tensor)
    def compute_loss(self, log_probs, targets):
        if _t_isnum(log_probs):
            raise TypeError("compute_loss(log_probs (T, V), targets): the old compute_loss(input_len, target_len) returned a made-up number")
        var lp = log_probs
        if not isinstance(lp, Tensor):
            lp = Tensor(log_probs)
        return _fn_ctc_loss(lp, targets, self.blank_id).item()

    def get_name(self):
        return self.name


# ── 243: ASRPipeline: MFCC features -> two 1-d convolutions -> per-frame
# log-probabilities over the vocabulary -> greedy CTC decoding. train_step
# fits it to (waveform, transcript) pairs with the CTC loss.
class ASRPipeline(Module):
    def __init__(self, sample_rate, n_mfcc, vocab, model_channels):
        super().__init__()
        self.sample_rate = sample_rate
        self.n_mfcc = n_mfcc
        self.vocab = vocab
        self.model_channels = model_channels
        self.feature_extractor = MFCCExtractor(sample_rate, n_mfcc, 40, 512, 128)
        self.norm = BatchNorm1d(n_mfcc)
        self.enc = Conv1d(n_mfcc, model_channels, 3, 1, 1)
        self.dec = Conv1d(model_channels, len(vocab), 1)
        self.ctc_decoder = CTCDecoder(vocab, 0)
        self.opt = none
        self.name = "ASRPipeline"

    def features(self, waveform):
        return self.feature_extractor.extract(waveform)

    # (T, V) log-probabilities
    def log_probs(self, feats):
        var h = self.enc.forward(self.norm.forward(feats.unsqueeze(0))).relu()
        return self.dec.forward(h).squeeze(0).t().log_softmax(1)

    def transcribe(self, waveform):
        var lp = none
        var was = self.training
        self.eval()
        with no_grad():
            lp = self.log_probs(self.features(waveform))
        self.train_mode(was)
        var ids = self.ctc_decoder.greedy_decode(lp)
        return {"text": self.ctc_decoder.decode_to_string(ids), "n_frames": lp.size()[0], "n_tokens": len(ids)}

    def encode_text(self, text):
        var ids = []
        var i = 0
        while i < len(text):
            var k = 1
            var found = -1
            while k < len(self.vocab):
                if self.vocab[k] == text[i]:
                    found = k
                k = k + 1
            if found < 0:
                raise ValueError("character '" + text[i] + "' is not in the vocabulary")
            ids.append(found)
            i = i + 1
        return ids

    def train_step(self, waveform, transcript, lr):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        self.train()
        self.opt.zero_grad()
        var loss = _fn_ctc_loss(self.log_probs(self.features(waveform)), self.encode_text(transcript), 0)
        loss.backward()
        self.opt.step()
        return loss.item()

    def get_name(self):
        return self.name


# ── 244: TCNLayer (Bai et al. 2018): two causal dilated convolutions with
# ReLU and dropout, plus a residual (1x1 conv when the width changes).
class TCNLayer(Module):
    def __init__(self, in_channels, out_channels, kernel, dilation, dropout):
        super().__init__()
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.kernel = kernel
        self.dilation = dilation
        self.dropout = dropout
        self.conv1 = Conv1d(in_channels, out_channels, kernel, 1, 0, dilation)
        self.conv2 = Conv1d(out_channels, out_channels, kernel, 1, 0, dilation)
        self.drop = Dropout(dropout)
        self.downsample = none
        if in_channels != out_channels:
            self.downsample = Conv1d(in_channels, out_channels, 1)
        self.name = "TCNLayer"

    def causal_conv(self, x, conv):
        return conv.forward(_cv_left_pad(x, (self.kernel - 1) * self.dilation))

    def forward(self, x, training):
        self.train_mode(training)
        var h0 = _cv_seq(x, self.in_channels)
        var h = self.drop.forward(self.causal_conv(h0, self.conv1).relu())
        h = self.drop.forward(self.causal_conv(h, self.conv2).relu())
        var res = h0
        if self.downsample != none:
            res = self.downsample.forward(h0)
        return (h + res).relu()

    def get_name(self):
        return self.name


# ── 245: TemporalConvNet: TCN layers with dilations 1, 2, 4, ...
class TemporalConvNet(Module):
    def __init__(self, input_size, channel_sizes, kernel, dropout):
        super().__init__()
        self.input_size = input_size
        self.channel_sizes = channel_sizes
        self.kernel = kernel
        self.dropout = dropout
        self.layers = []
        var d = 1
        var i = 0
        while i < len(channel_sizes):
            var in_ch = input_size
            if i > 0:
                in_ch = channel_sizes[i - 1]
            self.layers.append(TCNLayer(in_ch, channel_sizes[i], kernel, d, dropout))
            d = d * 2
            i = i + 1
        self.name = "TemporalConvNet"

    def forward(self, x, training):
        var h = _cv_seq(x, self.input_size)
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h, training)
            i = i + 1
        return h

    def n_layers(self):
        return len(self.layers)

    def get_name(self):
        return self.name


# Solve A x = b (small, dense) by Gaussian elimination with partial pivoting.
def _cv_solve(A, b):
    var n = len(b)
    var M = []
    var i = 0
    while i < n:
        M.append(A[i][:] + [b[i]])
        i = i + 1
    var c = 0
    while c < n:
        var p = c
        var r = c + 1
        while r < n:
            if abs(M[r][c]) > abs(M[p][c]):
                p = r
            r = r + 1
        if abs(M[p][c]) < 0.000000000001:
            raise ValueError("singular system in least squares")
        var tmp = M[c]
        M[c] = M[p]
        M[p] = tmp
        r = c + 1
        while r < n:
            var f = M[r][c] / M[c][c]
            var k = c
            while k <= n:
                M[r][k] = M[r][k] - f * M[c][k]
                k = k + 1
            r = r + 1
        c = c + 1
    var x = nt_full([n], 0.0)
    i = n - 1
    while i >= 0:
        var s = M[i][n]
        var k2 = i + 1
        while k2 < n:
            s = s - M[i][k2] * x[k2]
            k2 = k2 + 1
        x[i] = s / M[i][i]
        i = i - 1
    return x

# least squares: rows of X (lists), targets y; ridge keeps it well posed
def _cv_lstsq(X, y, ridge):
    var k = len(X[0])
    var A = []
    var b = nt_full([k], 0.0)
    var i = 0
    while i < k:
        A.append(nt_full([k], 0.0))
        i = i + 1
    var r = 0
    while r < len(X):
        var row = X[r]
        i = 0
        while i < k:
            b[i] = b[i] + row[i] * y[r]
            var j = 0
            while j < k:
                A[i][j] = A[i][j] + row[i] * row[j]
                j = j + 1
            i = i + 1
        r = r + 1
    i = 0
    while i < k:
        A[i][i] = A[i][i] + ridge
        i = i + 1
    return _cv_solve(A, b)


# ── 246: ARIMAModel(p, d, q), fitted by Hannan-Rissanen:
#   1. difference d times;  2. a long AR by least squares gives residuals e;
#   3. regress y_t on [1, y_(t-1..t-p), e_(t-1..t-q)].
# forecast() recurses on the differenced series (future shocks 0) and
# integrates back to the original scale. aic/bic from the residual variance.
class ARIMAModel:
    def __init__(self, p, d, q):
        self.p = p
        self.d = d
        self.q = q
        self.ar_coefs = nt_full([p], 0.0)
        self.ma_coefs = nt_full([q], 0.0)
        self.intercept = 0.0
        self.residuals = []
        self.fitted_values = []
        self.series = []
        self.diff_series = []
        self.sigma2 = 0.0
        self.aic = 0.0
        self.bic = 0.0
        self.name = "ARIMAModel"

    def difference(self, series, order):
        var s = _t_flat(_t_wrap(series).data)
        var k = 0
        while k < order:
            var nd = []
            var i = 1
            while i < len(s):
                nd.append(s[i] - s[i - 1])
                i = i + 1
            s = nd
            k = k + 1
        return s

    def fit(self, series):
        self.series = _t_flat(_t_wrap(series).data)
        var y = self.difference(self.series, self.d)
        self.diff_series = y
        var n = len(y)
        var m = max(self.p, self.q) + 3
        if n < m + max(self.p, self.q) + 5:
            raise ValueError("series too short for ARIMA(" + str(self.p) + ", " + str(self.d) + ", " + str(self.q) + ")")
        # step 2: long AR(m) residuals
        var e = nt_full([n], 0.0)
        if self.q > 0:
            var X = []
            var Y = []
            var t = m
            while t < n:
                var row = [1.0]
                var j = 1
                while j <= m:
                    row.append(y[t - j])
                    j = j + 1
                X.append(row)
                Y.append(y[t])
                t = t + 1
            var phi = _cv_lstsq(X, Y, 0.000001)
            t = m
            while t < n:
                var pred = phi[0]
                var j2 = 1
                while j2 <= m:
                    pred = pred + phi[j2] * y[t - j2]
                    j2 = j2 + 1
                e[t] = y[t] - pred
                t = t + 1
        # step 3: ARMA regression
        var start = max(self.p, self.q)
        if self.q > 0:
            start = m + self.q
        var X2 = []
        var Y2 = []
        var t2 = start
        while t2 < n:
            var row2 = [1.0]
            var i = 1
            while i <= self.p:
                row2.append(y[t2 - i])
                i = i + 1
            i = 1
            while i <= self.q:
                row2.append(e[t2 - i])
                i = i + 1
            X2.append(row2)
            Y2.append(y[t2])
            t2 = t2 + 1
        var beta = _cv_lstsq(X2, Y2, 0.000001)
        self.intercept = beta[0]
        var k = 0
        while k < self.p:
            self.ar_coefs[k] = beta[1 + k]
            k = k + 1
        k = 0
        while k < self.q:
            self.ma_coefs[k] = beta[1 + self.p + k]
            k = k + 1
        # in-sample one-step predictions and residuals
        var res = nt_full([n], 0.0)
        var fitted = []
        var t3 = 0
        while t3 < n:
            var pr = self.intercept
            var i3 = 1
            while i3 <= self.p:
                if t3 - i3 >= 0:
                    pr = pr + self.ar_coefs[i3 - 1] * y[t3 - i3]
                i3 = i3 + 1
            i3 = 1
            while i3 <= self.q:
                if t3 - i3 >= 0:
                    pr = pr + self.ma_coefs[i3 - 1] * res[t3 - i3]
                i3 = i3 + 1
            fitted.append(pr)
            res[t3] = y[t3] - pr
            t3 = t3 + 1
        self.fitted_values = fitted
        self.residuals = res
        var ss = 0.0
        var cnt = 0
        t3 = start
        while t3 < n:
            ss = ss + res[t3] * res[t3]
            cnt = cnt + 1
            t3 = t3 + 1
        self.sigma2 = ss / float(max(1, cnt))
        var kpar = float(self.p + self.q + 1)
        var lv = log(max(self.sigma2, 0.000000000001))
        self.aic = float(cnt) * lv + 2.0 * kpar
        self.bic = float(cnt) * lv + kpar * log(float(max(2, cnt)))
        return self

    def forecast(self, n_steps):
        if len(self.series) == 0:
            raise ValueError("fit the model before forecasting")
        var y = self.diff_series[:]
        var e = self.residuals[:]
        var s = 0
        while s < n_steps:
            var t = len(y)
            var pr = self.intercept
            var i = 1
            while i <= self.p:
                pr = pr + self.ar_coefs[i - 1] * y[t - i]
                i = i + 1
            i = 1
            while i <= self.q:
                pr = pr + self.ma_coefs[i - 1] * e[t - i]
                i = i + 1
            y.append(pr)
            e.append(0.0)
            s = s + 1
        var out = y[len(self.diff_series):]
        # integrate back d times, starting from the last values of each level
        var lvl = self.d
        while lvl > 0:
            var base = self.difference(self.series, lvl - 1)
            var last = base[len(base) - 1]
            var integ = []
            var j = 0
            while j < len(out):
                last = last + out[j]
                integ.append(last)
                j = j + 1
            out = integ
            lvl = lvl - 1
        return out

    def get_info(self):
        return {"p": self.p, "d": self.d, "q": self.q, "aic": self.aic, "bic": self.bic, "ar": self.ar_coefs, "ma": self.ma_coefs, "sigma2": self.sigma2}

    def get_name(self):
        return self.name


# ── 247: TimeSeriesTransformer: per-step input projection + sinusoidal
# positions -> pre-norm encoder layers -> the last step's state -> linear
# head predicting pred_len future values.
class TimeSeriesTransformer(Module):
    def __init__(self, input_dim, d_model, n_heads, n_layers, pred_len, dropout):
        super().__init__()
        self.input_dim = input_dim
        self.d_model = d_model
        self.n_heads = n_heads
        self.n_layers = n_layers
        self.pred_len = pred_len
        self.dropout = dropout
        self.input_proj = Linear(input_dim, d_model)
        self.layers = []
        var i = 0
        while i < n_layers:
            self.layers.append(TransformerEncoderLayer(d_model, n_heads, 4 * d_model, dropout, "gelu", false, true))
            i = i + 1
        self.norm = LayerNorm(d_model)
        self.output_proj = Linear(d_model, pred_len)
        self.opt = none
        self.name = "TimeSeriesTransformer"

    def positions(self, L):
        var d = []
        var t = 0
        while t < L:
            var k = 0
            while k < self.d_model:
                var f = exp(0.0 - log(10000.0) * float(2 * (k // 2)) / float(self.d_model))
                if k % 2 == 0:
                    d.append(sin(float(t) * f))
                else:
                    d.append(cos(float(t) * f))
                k = k + 1
            t = t + 1
        return Tensor(d, false, [L, self.d_model])

    # history (L * input_dim values or (L, input_dim)) -> (L, d_model)
    def encode(self, x):
        var t = _t_wrap(x)
        if t.dim() == 1:
            t = t.reshape([t.numel() // self.input_dim, self.input_dim])
        var h = self.input_proj.forward(t) + self.positions(t.size()[0])
        var i = 0
        while i < len(self.layers):
            h = self.layers[i].forward(h, none, none)
            i = i + 1
        return self.norm.forward(h)

    def predict(self, history):
        var h = self.encode(history)
        return self.output_proj.forward(h.select(0, h.size()[0] - 1))

    def forecast(self, history):
        var p = none
        with no_grad():
            p = self.predict(history)
        return p

    def train_step(self, history, future, lr):
        if self.opt == none:
            self.opt = Adam(self.parameters(), lr)
        self.opt.zero_grad()
        var loss = _fn_mse(self.predict(history), _t_wrap(future), "mean")
        loss.backward()
        self.opt.step()
        return loss.item()

    def get_name(self):
        return self.name


# ── 248: ExperimentTracker ─────────────────────────────────────────────────
class ExperimentTracker:
    def __init__(self, experiment_name, tags):
        self.experiment_name = experiment_name
        self.tags = tags
        self.runs = {}
        self.run_order = []
        self.current_run = ""
        self.run_count = 0
        self.name = "ExperimentTracker"

    def start_run(self, run_name):
        self.current_run = run_name
        self.runs[run_name] = {"metrics": {}, "params": {}, "artifacts": [], "status": "running", "step": 0}
        self.run_order.append(run_name)
        self.run_count = self.run_count + 1
        return run_name

    def log_param(self, key, value):
        if self.current_run in self.runs:
            self.runs[self.current_run]["params"][key] = value

    def log_metric(self, key, value, step):
        if self.current_run in self.runs:
            var run = self.runs[self.current_run]
            if not (key in run["metrics"]):
                run["metrics"][key] = []
            run["metrics"][key].append({"step": step, "value": value})
            run["step"] = step

    def log_artifact(self, path):
        if self.current_run in self.runs:
            self.runs[self.current_run]["artifacts"].append(path)

    def end_run(self, status):
        if self.current_run in self.runs:
            self.runs[self.current_run]["status"] = status

    # the run whose last value of `metric` is best ("min" or "max")
    def get_best_run(self, metric, mode):
        var best_name = ""
        var best_val = 0.0
        var i = 0
        while i < len(self.run_order):
            var nm = self.run_order[i]
            var run = self.runs[nm]
            if metric in run["metrics"]:
                var h = run["metrics"][metric]
                if len(h) > 0:
                    var v = h[len(h) - 1]["value"]
                    if best_name == "" or (mode == "min" and v < best_val) or (mode == "max" and v > best_val):
                        best_name = nm
                        best_val = v
            i = i + 1
        return {"run": best_name, "value": best_val}

    def get_name(self):
        return self.name


# ── 249: MetricsCollector (sliding windows, counters, gauges) ──────────────
class MetricsCollector:
    def __init__(self, name, window_size):
        self.name = name
        self.window_size = window_size
        self.metrics = {}
        self.counters = {}
        self.gauges = {}
        self.total_updates = 0

    def record(self, metric_name, value):
        if not (metric_name in self.metrics):
            self.metrics[metric_name] = []
        self.metrics[metric_name].append(value)
        if len(self.metrics[metric_name]) > self.window_size:
            self.metrics[metric_name] = self.metrics[metric_name][1:]
        self.total_updates = self.total_updates + 1

    def increment(self, counter_name, amount):
        if not (counter_name in self.counters):
            self.counters[counter_name] = 0.0
        self.counters[counter_name] = self.counters[counter_name] + amount

    def set_gauge(self, gauge_name, value):
        self.gauges[gauge_name] = value

    def summary(self, metric_name):
        if not (metric_name in self.metrics) or len(self.metrics[metric_name]) == 0:
            return {"mean": 0.0, "min": 0.0, "max": 0.0, "std": 0.0, "count": 0}
        var v = self.metrics[metric_name]
        return {"mean": tensor_mean(v), "min": tensor_min(v), "max": tensor_max(v), "std": tensor_std(v), "count": len(v)}

    def all_summaries(self):
        var out = {}
        var keys = sorted(self.metrics.keys())
        var i = 0
        while i < len(keys):
            out[keys[i]] = self.summary(keys[i])
            i = i + 1
        return out

    def get_name(self):
        return self.name


# ── 250: AlertManager (threshold rules over a metrics snapshot) ────────────
class AlertManager:
    def __init__(self, name):
        self.name = name
        self.rules = []
        self.alerts = []
        self.silenced = []
        self.total_fired = 0

    def add_rule(self, rule_name, metric, op, threshold, severity):
        if op != ">" and op != "<" and op != ">=" and op != "<=" and op != "==":
            raise ValueError("unknown comparison '" + str(op) + "'")
        self.rules.append({"name": rule_name, "metric": metric, "op": op, "threshold": threshold, "severity": severity})

    def check(self, metrics_snapshot):
        var fired_now = []
        var i = 0
        while i < len(self.rules):
            var rule = self.rules[i]
            var m = rule["metric"]
            if m in metrics_snapshot:
                var v = metrics_snapshot[m]
                var th = rule["threshold"]
                var op = rule["op"]
                var fired = (op == ">" and v > th) or (op == "<" and v < th) or (op == ">=" and v >= th) or (op == "<=" and v <= th) or (op == "==" and v == th)
                if fired and not (rule["name"] in self.silenced):
                    var alert = {"rule": rule["name"], "metric": m, "value": v, "severity": rule["severity"]}
                    fired_now.append(alert)
                    self.alerts.append(alert)
                    self.total_fired = self.total_fired + 1
            i = i + 1
        return fired_now

    def silence(self, rule_name):
        self.silenced.append(rule_name)

    def active_alerts(self):
        return self.alerts[max(0, len(self.alerts) - 10):]

    def get_name(self):
        return self.name


# ── 251: ModelMonitor: error rate, latency and residual drift of a deployed model
class ModelMonitor:
    def __init__(self, model_name, baseline_metrics):
        self.model_name = model_name
        self.baseline_metrics = baseline_metrics
        self.drift_detector = DriftDetector(50, 0.1)
        self.alert_manager = AlertManager("model_alerts")
        self.prediction_count = 0
        self.error_count = 0
        self.latency_history = []
        self.error_tolerance = 0.5
        self.name = "ModelMonitor"
        self.alert_manager.add_rule("high_error_rate", "error_rate", ">", 0.1, "critical")
        self.alert_manager.add_rule("high_latency", "avg_latency_ms", ">", 100.0, "warning")
        self.alert_manager.add_rule("low_accuracy", "accuracy", "<", 0.8, "warning")

    def record_prediction(self, predicted, actual, latency_ms):
        self.prediction_count = self.prediction_count + 1
        if abs(predicted - actual) > self.error_tolerance:
            self.error_count = self.error_count + 1
        self.latency_history.append(latency_ms)
        if len(self.latency_history) > 1000:
            self.latency_history = self.latency_history[1:]
        self.drift_detector.update(predicted - actual)

    def get_snapshot(self):
        var err = 0.0
        if self.prediction_count > 0:
            err = float(self.error_count) / float(self.prediction_count)
        var lat = 0.0
        if len(self.latency_history) > 0:
            lat = tensor_mean(self.latency_history)
        return {"error_rate": err, "avg_latency_ms": lat, "accuracy": 1.0 - err, "predictions": self.prediction_count, "drift_detected": self.drift_detector.drift_detected}

    def check_health(self):
        var snap = self.get_snapshot()
        var alerts = self.alert_manager.check(snap)
        return {"snapshot": snap, "alerts": alerts, "n_alerts": len(alerts)}

    def get_name(self):
        return self.name


# ── 252: DatasetBuilder (records, label encoders, deterministic splits) ────
class DatasetBuilder:
    def __init__(self, name, schema):
        self.name = name
        self.schema = schema
        self.records = []
        self.splits = {}
        self.transforms = []
        self.label_encoders = {}
        self.total_added = 0

    def add_record(self, record):
        var r = record
        var i = 0
        while i < len(self.transforms):
            var tr = self.transforms[i]
            if tr["field"] in r:
                r[tr["field"]] = tr["fn"](r[tr["field"]])
            i = i + 1
        self.records.append(r)
        self.total_added = self.total_added + 1

    # applied to records added afterwards
    def add_transform(self, field, transform_fn):
        self.transforms.append({"field": field, "fn": transform_fn})

    # values in first-seen order -> 0, 1, 2, ...
    def fit_label_encoder(self, field):
        var enc = {}
        var n = 0
        var i = 0
        while i < len(self.records):
            if field in self.records[i]:
                var v = str(self.records[i][field])
                if not (v in enc):
                    enc[v] = n
                    n = n + 1
            i = i + 1
        self.label_encoders[field] = enc
        return enc

    # contiguous train / val / test slices (shuffle the records first if needed)
    def build(self, train_frac, val_frac, test_frac):
        if train_frac + val_frac + test_frac > 1.0000001:
            raise ValueError("split fractions add up to more than 1")
        var n = len(self.records)
        var n_train = int(float(n) * train_frac)
        var n_val = int(float(n) * val_frac)
        self.splits = {"train": self.records[:n_train], "val": self.records[n_train:n_train + n_val], "test": self.records[n_train + n_val:]}
        return self.splits

    def stats(self):
        return {"total": self.total_added, "splits": len(self.splits), "transforms": len(self.transforms)}

    def get_name(self):
        return self.name


# ── 253: DataSampler with its own seeded generator (Park-Miller) so a
# sampler's draws are reproducible and independent of the global seed.
#   random: uniform with replacement; weighted: by set_weights; stratified:
#   classes in turn (labels from compute_class_weights' last call).
class DataSampler:
    def __init__(self, strategy, seed):
        if strategy != "random" and strategy != "weighted" and strategy != "stratified" and strategy != "oversampling":
            raise ValueError("strategy must be random, weighted, stratified or oversampling")
        self.strategy = strategy
        self.seed = seed
        self.state = seed % 2147483646 + 1
        self.weights = []
        self.class_counts = {}
        self.labels = []
        self.total_sampled = 0
        self.name = "DataSampler"

    def _uniform(self):
        self.state = (self.state * 16807) % 2147483647
        return float(self.state) / 2147483647.0

    def set_weights(self, weights):
        self.weights = weights

    # inverse-frequency weight per example: n / (count(class) * n_classes)
    def compute_class_weights(self, labels):
        self.class_counts = {}
        self.labels = labels
        var i = 0
        while i < len(labels):
            var k = str(labels[i])
            if not (k in self.class_counts):
                self.class_counts[k] = 0
            self.class_counts[k] = self.class_counts[k] + 1
            i = i + 1
        var n = len(labels)
        var nc = len(self.class_counts)
        var w = []
        i = 0
        while i < n:
            w.append(float(n) / (float(self.class_counts[str(labels[i])]) * float(nc)))
            i = i + 1
        if self.strategy == "oversampling" or self.strategy == "weighted":
            if len(self.weights) == 0:
                self.weights = w
        return w

    def _index(self, m):
        if (self.strategy == "weighted" or self.strategy == "oversampling") and len(self.weights) == m:
            var total = 0.0
            var i = 0
            while i < m:
                total = total + self.weights[i]
                i = i + 1
            var r = self._uniform() * total
            var c = 0.0
            i = 0
            while i < m:
                c = c + self.weights[i]
                if r <= c:
                    return i
                i = i + 1
            return m - 1
        var j = int(self._uniform() * float(m))
        if j >= m:
            j = m - 1
        return j

    def sample(self, data, n):
        var m = len(data)
        if m == 0:
            return []
        var out = []
        var i = 0
        while i < n:
            out.append(data[self._index(m)])
            i = i + 1
        self.total_sampled = self.total_sampled + n
        return out

    def bootstrap_sample(self, data):
        return self.sample(data, len(data))

    def get_name(self):
        return self.name


# ── 254: DataAugmenter: each augmentation applies with probability
# prob * augmentation_prob (seeded global generator).
class DataAugmenter:
    def __init__(self, augmentation_prob):
        self.augmentation_prob = augmentation_prob
        self.augmentations = []
        self.applied_count = 0
        self.name = "DataAugmenter"

    def add_augmentation(self, name, aug_fn, prob):
        self.augmentations.append({"name": name, "fn": aug_fn, "prob": prob})

    def augment(self, x, step):
        var out = x
        var i = 0
        while i < len(self.augmentations):
            var aug = self.augmentations[i]
            if nt_rand(1)[0] < aug["prob"] * self.augmentation_prob:
                var f = aug["fn"]
                out = f(out)
                self.applied_count = self.applied_count + 1
            i = i + 1
        return out

    def augment_batch(self, batch, step):
        var out = []
        var i = 0
        while i < len(batch):
            out.append(self.augment(batch[i], step + i))
            i = i + 1
        return out

    def stats(self):
        return {"augmentations": len(self.augmentations), "applied": self.applied_count}

    def get_name(self):
        return self.name


# ── 255: TensorboardWriter: an in-memory scalar/histogram/text log;
# export(path) writes it as JSON (not TensorBoard's protobuf event format).
class TensorboardWriter:
    def __init__(self, log_dir, flush_secs):
        self.log_dir = log_dir
        self.flush_secs = flush_secs
        self.scalars = {}
        self.histograms = {}
        self.texts = []
        self.global_step = 0
        self.name = "TensorboardWriter"

    def add_scalar(self, tag, value, step):
        if not (tag in self.scalars):
            self.scalars[tag] = []
        self.scalars[tag].append({"step": step, "value": value})
        if step > self.global_step:
            self.global_step = step

    def add_scalars(self, main_tag, tag_scalar_dict, step):
        var keys = sorted(tag_scalar_dict.keys())
        var i = 0
        while i < len(keys):
            self.add_scalar(main_tag + "/" + keys[i], tag_scalar_dict[keys[i]], step)
            i = i + 1

    def add_histogram(self, tag, values, step):
        var v = _t_flat(_t_wrap(values).data)
        if not (tag in self.histograms):
            self.histograms[tag] = []
        self.histograms[tag].append({"step": step, "mean": tensor_mean(v), "std": tensor_std(v), "min": tensor_min(v), "max": tensor_max(v)})

    def add_text(self, tag, text, step):
        self.texts.append({"tag": tag, "text": text, "step": step})

    def get_scalar_history(self, tag):
        if tag in self.scalars:
            return self.scalars[tag]
        return []

    def flush(self):
        return {"scalars": len(self.scalars), "histograms": len(self.histograms), "step": self.global_step}

    def export(self, path):
        return write_file(path, json_encode({"scalars": self.scalars, "histograms": self.histograms, "texts": self.texts}))

    def get_name(self):
        return self.name


# ── 256: CheckpointManager: writes each checkpoint to save_dir, keeps the
# newest max_to_keep files (the best one is never deleted) and reloads the
# best. A Module or a {name: Tensor} state is saved with torch.save; any
# other state as JSON.
class CheckpointManager:
    def __init__(self, save_dir, max_to_keep, monitor_metric, mode):
        if mode != "min" and mode != "max":
            raise ValueError("mode must be 'min' or 'max'")
        self.save_dir = save_dir
        self.max_to_keep = max_to_keep
        self.monitor_metric = monitor_metric
        self.mode = mode
        self.checkpoints = []
        self.best_value = 0.0
        self.best_path = ""
        self.save_count = 0
        if mode == "min":
            self.best_value = 1e300
        else:
            self.best_value = 0.0 - 1e300
        self.name = "CheckpointManager"

    def _is_tensor_state(self, st):
        if isinstance(st, Module):
            return true
        if type(st) != "map":
            return false
        var ks = st.keys()
        var i = 0
        while i < len(ks):
            if not isinstance(st[ks[i]], Tensor):
                return false
            i = i + 1
        return len(ks) > 0

    def save(self, model_state, metric_value, step):
        if not os_isdir(self.save_dir):
            os_mkdir(self.save_dir)
            if not os_isdir(self.save_dir):
                raise OSError("cannot create checkpoint directory " + str(self.save_dir))
        var path = ""
        if self._is_tensor_state(model_state):
            path = self.save_dir + "/ckpt_step_" + str(step) + ".nyt"
            var st = model_state
            if isinstance(st, Module):
                st = st.state_dict()
            torch.save(st, path)
        else:
            path = self.save_dir + "/ckpt_step_" + str(step) + ".json"
            if not write_file(path, json_encode({"state": model_state, "step": step, "metric": metric_value})):
                raise OSError("cannot write " + path)
        var is_best = (self.mode == "min" and metric_value < self.best_value) or (self.mode == "max" and metric_value > self.best_value)
        if is_best:
            self.best_value = metric_value
            self.best_path = path
        self.checkpoints.append({"path": path, "value": metric_value, "step": step})
        self.save_count = self.save_count + 1
        while len(self.checkpoints) > self.max_to_keep:
            var drop = 0
            if self.checkpoints[0]["path"] == self.best_path:
                drop = 1
            if drop < len(self.checkpoints):
                var old = self.checkpoints[drop]["path"]
                if old != self.best_path and file_exists(old):
                    os_remove(old)
                self.checkpoints = self.checkpoints[:drop] + self.checkpoints[drop + 1:]
        return {"path": path, "is_best": is_best, "best_value": self.best_value}

    def _load(self, path):
        if len(path) > 4 and path[len(path) - 4:] == ".nyt":
            return torch.load(path)
        return json_decode(read_file(path))["state"]

    def load_best(self):
        if self.best_path == "":
            raise ValueError("no checkpoint saved yet")
        return {"path": self.best_path, "value": self.best_value, "state": self._load(self.best_path)}

    def list_checkpoints(self):
        return self.checkpoints

    def get_name(self):
        return self.name


# ── 257: LearningRateFinder (Smith 2017 LR range test): trains the model
# for n_steps with the learning rate rising geometrically from min_lr to
# max_lr, records the bias-corrected smoothed loss, stops when it diverges
# (4x the best), restores the weights, and suggests the rate of steepest
# descent. data_iterator: a list of [x, y] batches; loss_fn defaults to MSE.
class LearningRateFinder:
    def __init__(self, model, optimizer, min_lr, max_lr, n_steps, loss_fn=none):
        if not isinstance(model, Module):
            raise TypeError("LearningRateFinder needs a Module to train")
        self.model = model
        self.optimizer = optimizer
        self.min_lr = min_lr
        self.max_lr = max_lr
        self.n_steps = n_steps
        self.loss_fn = loss_fn
        self.lrs = []
        self.losses = []
        self.best_lr = min_lr
        self.name = "LearningRateFinder"

    def compute_lr(self, step):
        return self.min_lr * (self.max_lr / self.min_lr) ** (float(step) / float(max(1, self.n_steps - 1)))

    def _loss(self, pred, y):
        if self.loss_fn == none:
            return _fn_mse(pred, _t_wrap(y), "mean")
        var f = self.loss_fn
        return f(pred, y)

    def run(self, data_iterator):
        if len(data_iterator) == 0:
            raise ValueError("LearningRateFinder.run needs at least one [x, y] batch")
        var saved = self.model.state_dict()
        var snapshot = {}
        var ks = saved.keys()
        var i = 0
        while i < len(ks):
            snapshot[ks[i]] = saved[ks[i]].clone().detach()
            i = i + 1
        self.lrs = []
        self.losses = []
        var avg = 0.0
        var best = 1e300
        var beta = 0.98
        var step = 0
        while step < self.n_steps:
            var lr = self.compute_lr(step)
            self.optimizer.set_lr(lr)
            var batch = data_iterator[step % len(data_iterator)]
            self.optimizer.zero_grad()
            var loss = self._loss(self.model.forward(batch[0]), batch[1])
            loss.backward()
            self.optimizer.step()
            avg = beta * avg + (1.0 - beta) * loss.item()
            var smoothed = avg / (1.0 - beta ** float(step + 1))
            self.lrs.append(lr)
            self.losses.append(smoothed)
            if smoothed < best:
                best = smoothed
            if step > 0 and (smoothed > 4.0 * best or smoothed != smoothed):
                break
            step = step + 1
        self.model.load_state_dict(snapshot)
        # steepest descent of the smoothed loss (per unit log lr)
        var best_i = 0
        var best_slope = 1e300
        i = 1
        while i < len(self.losses):
            var slope = self.losses[i] - self.losses[i - 1]
            if slope < best_slope:
                best_slope = slope
                best_i = i
            i = i + 1
        self.best_lr = self.lrs[best_i]
        return {"best_lr": self.best_lr, "min_loss": best, "n_steps": len(self.lrs)}

    def plot_summary(self):
        if len(self.lrs) == 0:
            return "No data - run first"
        return "LR range: [" + str(self.lrs[0]) + ", " + str(self.lrs[len(self.lrs) - 1]) + "] best_lr=" + str(self.best_lr)

    def get_name(self):
        return self.name


# ── 258: GradientAnalyzer: per-layer gradient norms and statistics, with
# explosion / vanishing counts.
class GradientAnalyzer:
    def __init__(self, model_name, track_norms, track_histogram):
        self.model_name = model_name
        self.track_norms = track_norms
        self.track_histogram = track_histogram
        self.grad_norms = {}
        self.grad_stats = {}
        self.explosion_events = 0
        self.vanish_events = 0
        self.norm_threshold_high = 10.0
        self.norm_threshold_low = 0.0000001
        self.step = 0
        self.name = "GradientAnalyzer"

    def record_grads(self, layer_name, grad_tensor):
        var g = grad_tensor
        if isinstance(g, Tensor):
            if g.grad != none:
                g = g.grad
            else:
                g = g.data
        g = _t_flat(g)
        var norm = tensor_norm(g)
        if not (layer_name in self.grad_norms):
            self.grad_norms[layer_name] = []
        self.grad_norms[layer_name].append(norm)
        self.grad_stats[layer_name] = {"mean": tensor_mean(g), "std": tensor_std(g), "norm": norm, "min": tensor_min(g), "max": tensor_max(g)}
        if norm > self.norm_threshold_high:
            self.explosion_events = self.explosion_events + 1
        if norm < self.norm_threshold_low and norm > 0.0:
            self.vanish_events = self.vanish_events + 1
        self.step = self.step + 1

    # every parameter of a Module (after backward), by name
    def record_module(self, module):
        var np = module.named_parameters()
        var i = 0
        while i < len(np):
            if np[i][1].grad != none:
                self.record_grads(np[i][0], np[i][1].grad)
            i = i + 1

    def detect_problems(self):
        var problems = []
        if self.explosion_events > 0:
            problems.append("gradient_explosion: " + str(self.explosion_events) + " events")
        if self.vanish_events > 0:
            problems.append("gradient_vanishing: " + str(self.vanish_events) + " events")
        return problems

    def summary(self):
        var layer_norms = {}
        var keys = sorted(self.grad_norms.keys())
        var i = 0
        while i < len(keys):
            layer_norms[keys[i]] = tensor_mean(self.grad_norms[keys[i]])
            i = i + 1
        return {"layers_tracked": len(keys), "explosion_events": self.explosion_events, "vanish_events": self.vanish_events, "avg_norms_per_layer": layer_norms}

    def get_name(self):
        return self.name


# ── 259: ProfilerSession: wall-clock timing of named events (time_ms) ─────
class ProfilerSession:
    def __init__(self, name, enabled):
        self.name = name
        self.enabled = enabled
        self.events = []
        self.active_timers = {}
        self.total_time = {}
        self.call_count = {}
        self.memory_snapshots = []

    def start_event(self, event_name):
        if self.enabled:
            self.active_timers[event_name] = time_ms()

    def end_event(self, event_name):
        if not self.enabled:
            return
        if not (event_name in self.active_timers):
            raise ValueError("end_event('" + str(event_name) + "') without start_event")
        var elapsed = time_ms() - self.active_timers[event_name]
        if not (event_name in self.total_time):
            self.total_time[event_name] = 0.0
            self.call_count[event_name] = 0
        self.total_time[event_name] = self.total_time[event_name] + elapsed
        self.call_count[event_name] = self.call_count[event_name] + 1
        self.events.append({"name": event_name, "elapsed_ms": elapsed})

    def record_memory(self, label, bytes_used):
        self.memory_snapshots.append({"label": label, "bytes": bytes_used})

    def report(self):
        var hot = []
        var keys = sorted(self.total_time.keys())
        var i = 0
        while i < len(keys):
            hot.append({"name": keys[i], "total_ms": self.total_time[keys[i]], "calls": self.call_count[keys[i]]})
            i = i + 1
        return {"total_events": len(self.events), "hotspots": hot, "memory_snapshots": len(self.memory_snapshots)}

    def get_name(self):
        return self.name


# ── 260: HyperparameterBayesOpt: a Gaussian-process surrogate (RBF kernel,
# length scale 0.2 on the unit cube, noise 1e-6) over parameters scaled to
# [0, 1]; the first n_initial suggestions are uniform, later ones maximise
# the acquisition ("ei", "ucb" or "pi", for minimisation) over 200 uniform
# candidates. Minimises the observed value.
class HyperparameterBayesOpt:
    def __init__(self, param_bounds, n_initial, acquisition):
        if acquisition != "ei" and acquisition != "ucb" and acquisition != "pi":
            raise ValueError("acquisition must be ei, ucb or pi")
        self.param_bounds = param_bounds
        self.keys = sorted(param_bounds.keys())
        self.n_initial = n_initial
        self.acquisition = acquisition
        self.observations_x = []
        self.observations_u = []
        self.observations_y = []
        self.best_x = {}
        self.best_y = 1e300
        self.iteration = 0
        self.length_scale = 0.2
        self.noise = 0.000001
        self._mu = 0.0
        self._sd = 1.0
        self._O = none
        self._Kinv = none
        self._alpha = none
        self.name = "HyperparameterBayesOpt"

    def _to_params(self, u):
        var p = {}
        var i = 0
        while i < len(self.keys):
            var b = self.param_bounds[self.keys[i]]
            p[self.keys[i]] = b[0] + (b[1] - b[0]) * u[i]
            i = i + 1
        return p

    def _to_unit(self, x):
        var u = []
        var i = 0
        while i < len(self.keys):
            var b = self.param_bounds[self.keys[i]]
            u.append((x[self.keys[i]] - b[0]) / (b[1] - b[0]))
            i = i + 1
        return u

    def _random_sample(self):
        return nt_rand(len(self.keys))

    def _k(self, a, b):
        var d = 0.0
        var i = 0
        while i < len(a):
            d = d + (a[i] - b[i]) * (a[i] - b[i])
            i = i + 1
        return exp(0.0 - d / (2.0 * self.length_scale * self.length_scale))

    # RBF kernel matrix between rows of A (m, d) and B (n, d)
    def _kmat(self, A, B):
        var d2 = A.square().sum(1, true) + B.square().sum(1, true).t() - A.matmul(B.t()) * 2.0
        return (d2 * (-0.5 / (self.length_scale * self.length_scale))).exp()

    # fit the GP to the (standardised) observations: K^-1 and alpha = K^-1 y
    def _fit(self):
        var n = len(self.observations_u)
        var ys = self.observations_y
        self._mu = tensor_mean(ys)
        self._sd = tensor_std(ys)
        if self._sd < 0.000000001:
            self._sd = 1.0
        self._O = Tensor(self.observations_u)
        var K = self._kmat(self._O, self._O) + torch.eye(n) * self.noise
        var rows = []
        var i = 0
        while i < n:
            rows.append(K.select(0, i).data)
            i = i + 1
        var inv = []
        i = 0
        while i < n:
            var e = nt_full([n], 0.0)
            e[i] = 1.0
            inv.append(_cv_solve(rows, e))
            i = i + 1
        self._Kinv = Tensor(inv)
        var yz = []
        i = 0
        while i < n:
            yz.append((ys[i] - self._mu) / self._sd)
            i = i + 1
        self._alpha = self._Kinv.mv(Tensor(yz))

    # GP posterior means and stds at the rows of U (m, d) -> [means, stds]
    def _posterior_batch(self, U):
        var Kc = self._kmat(U, self._O)
        var m = Kc.mv(self._alpha) * self._sd + self._mu
        var v = (Kc.matmul(self._Kinv) * Kc).sum(1).rsub(1.0).clamp(0.000000000001, 1e300)
        return [m, v.sqrt() * self._sd]

    def _posterior(self, u):
        self._fit()
        var r = self._posterior_batch(Tensor([u]))
        return [r[0].data[0], r[1].data[0]]

    def _surrogate_mean(self, x):
        return self._posterior(self._to_unit(x))[0]

    def _norm_cdf(self, z):
        return 0.5 * (1.0 + tanh(0.7978845608028654 * (z + 0.044715 * z * z * z)))

    def _acq_from(self, m, s):
        if self.acquisition == "ucb":
            return 0.0 - (m - 2.0 * s)
        var z = (self.best_y - m) / s
        if self.acquisition == "pi":
            return self._norm_cdf(z)
        return (self.best_y - m) * self._norm_cdf(z) + s * exp(0.0 - 0.5 * z * z) / 2.5066282746310002

    # larger is better
    def _acq(self, u):
        var ps = self._posterior(u)
        return self._acq_from(ps[0], ps[1])

    def _acquisition_value(self, x):
        return self._acq(self._to_unit(x))

    def suggest(self):
        self.iteration = self.iteration + 1
        if len(self.observations_u) < self.n_initial:
            return self._to_params(self._random_sample())
        self._fit()
        var M = 200
        var d = len(self.keys)
        var U = Tensor(nt_rand(M * d), false, [M, d])
        var ps = self._posterior_batch(U)
        var md = ps[0].data
        var sd = ps[1].data
        var best = 0
        var best_a = 0.0
        var c = 0
        while c < M:
            var a = self._acq_from(md[c], sd[c])
            if c == 0 or a > best_a:
                best = c
                best_a = a
            c = c + 1
        return self._to_params(U.select(0, best).data)

    def observe(self, x, y):
        self.observations_x.append(x)
        self.observations_u.append(self._to_unit(x))
        self.observations_y.append(y)
        if y < self.best_y:
            self.best_y = y
            self.best_x = x

    def best(self):
        return {"params": self.best_x, "value": self.best_y, "n_observations": len(self.observations_y)}

    def get_name(self):
        return self.name
