# ─── nytorch losses ──────────────────────────────────────────────────────────
# Loss modules (torch.nn names); every one returns a differentiable Tensor
# (0-d for reduction "mean"/"sum"), so loss.backward() reaches the model.
#
# CrossEntropyLoss / NLLLoss follow PyTorch exactly: input is LOGITS (resp.
# log-probabilities) shaped (N, C), (C,) or (N, C, d1, ...); target is class
# indices (N,) — or class probabilities with the input's shape — with
# weight, ignore_index and label_smoothing. The older CrossEntropyLoss
# computed -sum(target * log(pred)) on whatever it was given, so logits
# [2, 1, 0] with target class 0 came out as -0.693 instead of 0.4076, and
# NLLLoss was the same function under another name.

import "lib/nytorch/tensor.ny"
import "lib/nytorch/module.ny"

class _Loss(Module):
    # (every intermediate class defines __init__: a two-level super() chain
    # through a class without one does not run on the interpreter)
    def __init__(self):
        super().__init__()
    def __call__(self, input, target):
        return self.forward(input, target)

class MSELoss(_Loss):
    def __init__(self, reduction="mean"):
        super().__init__()
        self.reduction = reduction
    def forward(self, input, target):
        return _fn_mse(input, target, self.reduction)

class L1Loss(_Loss):
    def __init__(self, reduction="mean"):
        super().__init__()
        self.reduction = reduction
    def forward(self, input, target):
        return _fn_l1(input, target, self.reduction)

class CrossEntropyLoss(_Loss):
    def __init__(self, weight=none, ignore_index=none, reduction="mean", label_smoothing=0.0):
        if ignore_index == none:
            ignore_index = -100
        super().__init__()
        self.weight = weight
        self.ignore_index = ignore_index
        self.reduction = reduction
        self.label_smoothing = label_smoothing
    def forward(self, input, target):
        return _fn_cross_entropy(input, target, self.weight, self.ignore_index, self.reduction, self.label_smoothing)

class NLLLoss(_Loss):
    def __init__(self, weight=none, ignore_index=none, reduction="mean"):
        if ignore_index == none:
            ignore_index = -100
        super().__init__()
        self.weight = weight
        self.ignore_index = ignore_index
        self.reduction = reduction
    def forward(self, input, target):
        return _fn_nll_loss(input, target, self.weight, self.ignore_index, self.reduction)

class BCELoss(_Loss):
    # input: probabilities
    def __init__(self, reduction="mean"):
        super().__init__()
        self.reduction = reduction
    def forward(self, input, target):
        return _fn_bce(input, target, self.reduction)

class BCEWithLogitsLoss(_Loss):
    def __init__(self, pos_weight=none, reduction="mean"):
        super().__init__()
        self.pos_weight = pos_weight
        self.reduction = reduction
    def forward(self, input, target):
        return _fn_bce_logits(input, target, self.pos_weight, self.reduction)

class SmoothL1Loss(_Loss):
    def __init__(self, reduction="mean", beta=1.0):
        super().__init__()
        self.reduction = reduction
        self.beta = beta
    def forward(self, input, target):
        return _fn_smooth_l1(input, target, self.reduction, self.beta)

class HuberLoss(_Loss):
    # HuberLoss(delta) — the older positional form — or HuberLoss(delta, reduction)
    def __init__(self, delta=1.0, reduction="mean"):
        super().__init__()
        self.delta = delta
        self.reduction = reduction
    def forward(self, input, target):
        return _fn_huber(input, target, self.reduction, self.delta)

class KLDivLoss(_Loss):
    # input: log-probabilities, target: probabilities
    def __init__(self, reduction="mean"):
        super().__init__()
        self.reduction = reduction
    def forward(self, input, target):
        return _fn_kl_div(input, target, self.reduction)

# older names
def MAELoss():
    return L1Loss("mean")
def L2Loss():
    return MSELoss("mean")

class FocalLoss(_Loss):
    # binary focal loss on probabilities (Lin et al. 2017), mean over elements
    def __init__(self, alpha=0.25, gamma=2.0):
        super().__init__()
        self.alpha = alpha
        self.gamma = gamma
    def forward(self, input, target):
        var p = _t_wrap(input).clamp(0.0000001, 1.0 - 0.0000001)
        var t = _t_wrap(target)
        var a = self.alpha
        var pos = p.rsub(1.0).pow(self.gamma) * p.log() * t * (0.0 - a)
        var neg = p.pow(self.gamma) * p.rsub(1.0).log() * t.rsub(1.0) * (0.0 - (1.0 - a))
        return (pos + neg).mean()

class LabelSmoothingLoss(_Loss):
    # cross-entropy of LOG-probabilities against a smoothed one-hot target
    def __init__(self, num_classes, smoothing):
        super().__init__()
        self.num_classes = num_classes
        self.smoothing = smoothing
    def forward(self, input, target):
        var lp = _t_wrap(input)
        var t = _t_wrap(target)
        var st = t * (1.0 - self.smoothing) + self.smoothing / (1.0 * self.num_classes)
        return (st * lp).sum().neg()

class DiceLoss(_Loss):
    def __init__(self):
        super().__init__()
        self.eps = 0.000001
    def forward(self, input, target):
        var p = _t_wrap(input)
        var t = _t_wrap(target)
        var inter = (p * t).sum()
        var denom = p.sum() + t.sum() + self.eps
        return (inter * 2.0 + self.eps).div(denom).rsub(1.0)

class TripletLoss(Module):
    # max(0, d(a, p) - d(a, n) + margin), d = mean squared difference
    def __init__(self, margin):
        super().__init__()
        self.margin = margin
    def __call__(self, anchor, positive, negative):
        return self.forward(anchor, positive, negative)
    def forward(self, anchor, positive, negative):
        var a = _t_wrap(anchor)
        var dp = (a - positive).pow(2.0).mean()
        var dn = (a - negative).pow(2.0).mean()
        return (dp - dn + self.margin).relu()

class TripletMarginLoss(Module):
    # torch.nn.TripletMarginLoss: max(0, ||a-p||_2 - ||a-n||_2 + margin), mean over the batch
    def __init__(self, margin=1.0):
        super().__init__()
        self.margin = margin
    def __call__(self, anchor, positive, negative):
        return self.forward(anchor, positive, negative)
    def forward(self, anchor, positive, negative):
        var a = _t_wrap(anchor)
        var dp = (a - positive).norm(-1)
        var dn = (a - negative).norm(-1)
        return (dp - dn + self.margin).relu().mean()

class CosineEmbeddingLoss(Module):
    # label 1: 1 - cos(x1, x2); label -1 (or 0): max(0, cos - margin)
    def __init__(self, margin=0.0):
        super().__init__()
        self.margin = margin
    def __call__(self, x1, x2, label):
        return self.forward(x1, x2, label)
    def forward(self, x1, x2, label):
        var sim = _fn_cosine_similarity(x1, x2, -1, 0.00000001)
        if label == 1 or label == 1.0:
            return sim.rsub(1.0).mean()
        return (sim - self.margin).relu().mean()

class ContrastiveLoss(Module):
    # label 1 (similar): d^2; label 0: max(0, margin - d)^2, d = ||x1 - x2||
    def __init__(self, margin=1.0):
        super().__init__()
        self.margin = margin
    def __call__(self, x1, x2, label):
        return self.forward(x1, x2, label)
    def forward(self, x1, x2, label):
        var d = (_t_wrap(x1) - x2).norm()
        if label == 1 or label == 1.0:
            return d * d
        var h = d.rsub(self.margin).relu()
        return h * h


# CTC for one sequence: forward(log_probs (T, C), targets label ids)
class CTCLoss(_Loss):
    def __init__(self, blank=0):
        super().__init__()
        self.blank = blank
    def forward(self, log_probs, targets):
        return _fn_ctc_loss(log_probs, targets, self.blank)
