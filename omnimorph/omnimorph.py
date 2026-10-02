"""
OmniMorph v3 - penta-task network on PASCAL VOC 2012 (single GPU)
=================================================================
Tasks: 4x super-resolution | semantic segmentation | multi-label classification |
       object-instance edges | object detection (DETR-style).

Usage
-----
    python omnimorph_v3.py                # full pipeline: train -> best ckpt -> test metrics -> visualisations
    python omnimorph_v3.py --smoke-test    # one forward/backward on random tensors (shape / gradient sanity check)
    python omnimorph_v3.py --unit-test     # dataset-pipeline sanity check on synthetic VOC-shaped files (no GPU,
                                            # no real dataset needed) -- exercises letterboxing, augmentation,
                                            # denoising-query targets and cross-task region mixing end to end.

Why v3 exists
-------------
v2 fixed the numerical/metric bugs in v1 (degenerate per-batch metrics, dead modules, broken inits, blurry SR,
leaky void handling, etc.) and trained cleanly, but the six-panel training curves and the qualitative dumps it
produced exposed a *second* layer of problems that are architectural/statistical rather than "typos":

  1. Every task overfits hard and at a different epoch (train/val mIoU 73/19, ClsMAP 95/37, DetMAP 46/7) while the
     checkpoint/early-stopping logic only watched a composite of (mIoU, EdgeF1, DetMAP, ClsMAP) -- it never looked
     at reconstruction fidelity (PSNR/SSIM) *or* at the total validation loss, which visibly bottoms out around
     epoch ~90-100 and then climbs for another ~80 epochs while training kept going.
  2. The DETR-style detector is essentially uncalibrated (scores of 0.01-0.21 everywhere, duplicated un-suppressed
     boxes, whole objects missed) -- a well known symptom of training bipartite-matching decoders from scratch on
     a dataset as small as VOC's ~2,900 boxed images.
  3. Segmentation masks show isolated wrong-class islands and holes inside otherwise-correct silhouettes: the
     dense conv segmentation head is purely local and never sees the object-centric queries the network already
     computes (in v2 those queries feed only classification and detection).
  4. SR quality plateaus at ~25.4 dB on val: nothing beyond plain L1+SSIM pushes the network to recover
     high-frequency detail, and the shared trunk is being pulled by four other losses at once (classic multi-task
     negative transfer) with no mechanism protecting the reconstruction path.
  5. Every image is *squashed* to a square (`img.resize((S, S))`), destroying the true aspect ratio of every
     non-square VOC photo, for masks, edges, boxes and the final visualisations alike -- so the pictures the
     inferencer produces are warped, undersized (256x256) crops of what the photo actually looks like.

v3 fixes the correctness issues directly and adds five original, deliberately-scoped components (each section
below states plainly what published idea it is inspired by and what specifically is different -- per the request
that novelty here be a real, working combination, not a rename of an existing method):

  * Letterboxed (aspect-ratio preserving) preprocessing everywhere, with the transform recorded per-sample so the
    inferencer can put every prediction back onto the *original* photo at its *original* resolution.
  * Prototype-Conditioned Segmentation Refinement (PCSR): the existing object queries' own classification
    probabilities are used to marginalise a query-to-pixel affinity map, which is added *on top of* (not instead
    of) the dense conv head. Inspired by Mask2Former's per-query dot-product mask logits, but class-marginalised
    through the detector's own softmax instead of a 1:1 Hungarian query<->mask assignment, fused additively with a
    zero-initialised gain so it starts as a strict no-op.
  * IoU-Consistent Curriculum Denoising (ICCD) for the detector: noised copies of the ground-truth boxes are fed
    in as extra, attention-isolated decoder queries and supervised to reconstruct their box/label (inspired by
    DN-DETR), *and* to predict their own exact IoU against the clean box through the existing IoU branch (not
    present in DN-DETR, which only reconstructs box/label) -- turning the IoU head's calibration into a dense,
    self-supervised curriculum whose noise magnitude anneals coarse-to-fine over training.
  * Adaptive Task-Health Modulation (ATHM): each task's *validation-metric slope* (not its loss magnitude) is
    turned into a bounded "health" score every epoch, which both down-weights that task's loss term and turns up
    that task's own head-only dropout -- a single-backward-pass alternative to gradient-surgery methods
    (PCGrad/GradNorm), which would need one backward pass per task and are unaffordable on the single-GPU budget
    this project is built around.
  * Cross-Task Consistent Region Mixing (CTCRM): a ClassMix/CutMix-style region is pasted between two training
    images, but consistently across *all five* targets at once (image, mask, edge map, multi-label vector and
    detection boxes) -- ClassMix is segmentation-only and CutMix is classification/detection-only; keeping every
    task's target consistent under one shared pasted region for a joint SR+seg+edge+cls+det network is the new
    part here.

None of this is presented as beating a paper's numbers -- there is no GPU or copy of VOC2012 in the environment
this was written in, so nothing below has been trained to convergence. What has been verified in this environment
is that every new code path is shape-correct, produces finite gradients, and round-trips coordinates correctly
(see `--smoke-test` and `--unit-test`). Also, 4x SR from a real bicubic-downsampled input is information-theoretically
lossy, so "identical to ground truth" cannot be literally guaranteed by any model; what v3 does is remove the
structural reasons the reconstruction was capped well below its achievable fidelity (blind checkpoint selection,
undersupervised high-frequency content, uncontrolled task interference) so the *achievable* fidelity is higher and
is what gets kept.
"""
import os
import sys
import math
import json
import copy
import random
import argparse
import tempfile
import xml.etree.ElementTree as ET
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from typing import Dict, Tuple, List, Optional, Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader
import torchvision.transforms as T
import torchvision.transforms.functional as TF
from torchvision.ops import generalized_box_iou
from scipy import ndimage
from scipy.optimize import linear_sum_assignment
from PIL import Image
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as patches
from tqdm import tqdm

_RESAMPLING = getattr(Image, "Resampling", Image)
BICUBIC, NEAREST, BILINEAR = _RESAMPLING.BICUBIC, _RESAMPLING.NEAREST, _RESAMPLING.BILINEAR
FLIP_LR = getattr(Image, "Transpose", Image).FLIP_LEFT_RIGHT


# ============================================================================
# 1. CONFIGURATION
# ============================================================================
@dataclass
class OmniMorphConfig:
    experiment_name: str = "omnimorph_voc2012_penta_task_singlegpu_v3"
    checkpoint_dir: str = "./models"
    visualization_dir: str = "./visualizations"
    # Kaggle mounts a notebook's attached dataset at /kaggle/input/<URL-SLUG>/... -- for
    # https://www.kaggle.com/datasets/huanghanchina/pascal-voc-2012 that slug is "pascal-voc-2012", never the
    # "/datasets/<owner>/<slug>/" path segment from the browser URL (that string is not a real path inside the
    # kernel filesystem at all). `resolve_voc2012_root` below then searches under this for the actual folder
    # that holds JPEGImages/Annotations/ImageSets, however deep this particular re-upload nests it.
    dataset_root: str = "/kaggle/input/datasets/huanghanchina/pascal-voc-2012"
    seed: int = 42
    lr_image_size: int = 128
    hr_image_size: int = 512
    in_channels: int = 3
    num_classes: int = 20
    num_mask_classes: int = 21
    ignore_index: int = 255
    voc_classes: List[str] = field(default_factory=lambda: [
        'aeroplane', 'bicycle', 'bird', 'boat', 'bottle', 'bus', 'car', 'cat', 'chair', 'cow',
        'diningtable', 'dog', 'horse', 'motorbike', 'person', 'pottedplant', 'sheep', 'sofa', 'train', 'tvmonitor'
    ])
    # ---- data ----------------------------------------------------------------
    # VOC2012 has no public test annotations: the official 1449-image val split is divided into val / test.
    separate_test_split: bool = True
    val_fraction: float = 0.5
    augment: bool = True
    aug_crop_prob: float = 0.7
    aug_crop_min_scale: float = 0.4
    aug_flip_prob: float = 0.5
    aug_color_jitter: float = 0.25
    aug_min_box_visibility: float = 0.4
    # letterboxing: every canvas is built by a *uniform* resize-to-fit + centred pad, never a squash-resize, so
    # object/person/animal proportions are preserved for every task and the padded border is excluded from every
    # pixel-domain loss/metric via an explicit valid-pixel mask (segmentation/edge use ignore_index instead).
    letterbox_fill: float = 0.5
    # ---- cross-task consistent region mixing (CTCRM, see module docstring near the dataset) ------------------
    use_ctcrm: bool = True
    ctcrm_prob: float = 0.3
    ctcrm_classmix_prob: float = 0.6
    ctcrm_min_region_frac: float = 0.02
    ctcrm_max_region_frac: float = 0.9
    ctcrm_box_visibility: float = 0.3
    # ---- architecture ----------------------------------------------------------
    embed_dims: List[int] = field(default_factory=lambda: [64, 128, 256, 384])
    depths: List[int] = field(default_factory=lambda: [2, 2, 4, 2])
    num_heads: List[int] = field(default_factory=lambda: [2, 4, 8, 12])
    lora_rank_ratio: float = 0.25
    lora_min_rank: int = 4
    ffn_ratio: int = 3
    num_queries: int = 32
    pixel_dec_dim: int = 128
    num_prompts: int = 8
    prompt_dim: int = 64
    conv_kernel: int = 3
    conv_padding: int = 1
    conv_stride_down: int = 2
    conv_stride_normal: int = 1
    norm_groups: int = 1
    pixel_shuffle_factor: int = 2
    deform_kernel: int = 3
    deform_padding: int = 1
    deform_max_offset: float = 4.0      # pixels
    align_max_offset: float = 1.0       # pixels (pixel-decoder alignment)
    curvature_scale: float = 0.1
    attn_logit_scale_init: float = 10.0  # cosine attention needs a large scale over N=4096 tokens
    attn_logit_scale_max: float = 100.0
    rope_base: float = 10000.0
    sr_channels_1: int = 128
    sr_channels_2: int = 64
    sr_up_factor: int = 4               # channel multiplier of the PixelShuffle convs (= pixel_shuffle_factor ** 2)
    edge_hidden_channels: int = 32
    # ---- losses ------------------------------------------------------------------
    ssim_kernel: int = 11
    ssim_sigma: float = 1.5
    ssim_c1: float = 0.0001
    ssim_c2: float = 0.0009
    dice_smooth: float = 1e-5
    eps: float = 1e-7
    psnr_eps: float = 1e-8
    charbonnier_eps: float = 1e-3
    lambda_rec: float = 1.0
    lambda_ssim: float = 0.5
    lambda_pyramid: float = 0.5          # Laplacian-pyramid fidelity loss (see MultiTaskLoss)
    pyramid_levels: int = 3
    lambda_mid_sr: float = 0.3           # deep supervision at the intermediate 2x (128px) SR resolution
    lambda_mask_ce: float = 1.5
    lambda_mask_dice: float = 1.0
    lambda_aux_seg: float = 0.4
    seg_bg_weight: float = 0.5
    label_smoothing_seg: float = 0.05
    label_smoothing_cls: float = 0.05
    lambda_cls: float = 0.8
    lambda_edge: float = 1.0
    lambda_edge_dice: float = 1.0
    edge_pos_weight: float = 10.0
    lambda_det_ce: float = 2.0
    lambda_bbox: float = 5.0
    lambda_giou: float = 2.0
    lambda_iou_branch: float = 0.5
    lambda_aux_det: float = 0.5
    bg_class_weight: float = 0.1
    # Focal weighting (Lin et al., ICCV'17) on the query classification head, the way Deformable DETR / DINO-DETR
    # apply it (Zhu et al., ICLR'21; Zhang et al., CVPR'22): with only a handful of real objects among
    # `num_queries` slots per VOC image, plain weighted CE lets the many easy correctly-classified "no-object"
    # queries dominate the gradient -- see MultiTaskLoss._focal_ce.
    use_focal_det_cls: bool = True
    focal_gamma: float = 2.0
    # ---- IoU-Consistent Curriculum Denoising (ICCD) -----------------------------------------------------------
    use_denoising: bool = True
    dn_max_gt_per_image: int = 24
    dn_box_noise_scale_start: float = 0.4
    dn_box_noise_scale_end: float = 0.1
    dn_label_noise_prob: float = 0.2
    lambda_dn_cls: float = 1.0
    lambda_dn_bbox: float = 5.0
    lambda_dn_giou: float = 2.0
    lambda_dn_iou_consistency: float = 1.0
    # ---- Adaptive Task-Health Modulation (ATHM) --------------------------------------------------------------
    use_athm: bool = True
    athm_start_epoch: int = 10
    athm_window: int = 6
    athm_health_floor: float = 0.35
    head_dropout_base: float = 0.05
    head_dropout_max_extra: float = 0.25
    # ---- regularisation ------------------------------------------------------------
    drop_path_rate: float = 0.15
    num_refine_rounds: int = 3          # number of decoder layers
    # ---- optimisation ----------------------------------------------------------------
    batch_size: int = 8
    num_workers: int = 4
    epochs: int = 500                    # v3.1: was 120 -- a DETR-style detection head on ~1.5k training images
                                          # is documented (DN-DETR, Deformable DETR) to need far more than 120
                                          # epochs to leave the near-zero-mAP warm-up regime; see OmniMorphTrainer.
    warmup_epochs: int = 5
    lr: float = 3e-4
    min_lr: float = 1e-6
    weight_decay: float = 0.05
    clip_grad_norm: float = 1.0
    use_amp: bool = True                 # only used when running on CUDA
    use_ema: bool = True
    ema_decay: float = 0.999
    early_stop_patience: int = 80        # epochs without improvement of the composite val score (0 = off);
                                          # scaled up together with `epochs` -- 25/120 patience would fire well
                                          # before a 500-epoch cosine schedule has even annealed halfway down.
    loss_early_stop_patience: int = 60   # epochs without improvement of the val TOTAL LOSS (0 = off); the
                                          # composite score alone was not enough to catch the v2 run's overfitting
                                          # (val loss visibly troughed ~epoch 90 and climbed for ~80 more epochs)
    # ---- long-horizon / multi-session resumability (Kaggle sessions get killed well before 500 epochs finish
    #      in one sitting -- see OmniMorphTrainer.save/resume/_lr_lambda) --------------------------------------
    auto_resume: bool = True             # resume from `latest_checkpoint.pth` (or a safety snapshot) if present
    checkpoint_every_n_epochs: int = 5   # rotating safety snapshot cadence, independent of "latest"/"best"
    checkpoint_keep_last_n: int = 2      # how many rotating safety snapshots to retain on disk
    device: str = "cuda" if torch.cuda.is_available() else "cpu"
    # ---- evaluation / inference ------------------------------------------------------
    edge_tolerance: int = 1              # pixels of tolerance for the edge precision / recall
    edge_eval_thresholds: Tuple[float, ...] = (0.2, 0.35, 0.5, 0.65, 0.8)
    det_iou_thresh: float = 0.5
    det_score_thresh: float = 0.01
    det_max_per_image: int = 50
    max_infer_batches: int = 10          # -1 = whole test set (slow: 3 matplotlib figures per image)
    det_conf_threshold: float = 0.3
    det_nms_iou_thresh: float = 0.5      # visualisation-only NMS (the AP metric itself stays NMS-free / raw)
    det_vis_topk: int = 12
    det_vis_min_score: float = 0.03      # a floor so a confidently-empty image still shows *something*


# ============================================================================
# 2. UTILITIES
# ============================================================================
def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def make_base_grid(H: int, W: int, device, dtype=torch.float32) -> torch.Tensor:
    """Pixel-centre grid for grid_sample(align_corners=False), shape (1,H,W,2), (x,y) order."""
    ys = (torch.arange(H, device=device, dtype=dtype) + 0.5) * (2.0 / H) - 1.0
    xs = (torch.arange(W, device=device, dtype=dtype) + 0.5) * (2.0 / W) - 1.0
    gy, gx = torch.meshgrid(ys, xs, indexing="ij")
    return torch.stack([gx, gy], dim=-1).unsqueeze(0)


def px_to_norm(H: int, W: int, device, dtype=torch.float32) -> torch.Tensor:
    """Multiply a pixel displacement (dx, dy) by this to obtain a normalised grid displacement."""
    return torch.tensor([2.0 / W, 2.0 / H], device=device, dtype=dtype)


class DropPath(nn.Module):
    """Standard stochastic depth (per-sample)."""
    def __init__(self, p: float = 0.0):
        super().__init__()
        self.p = float(p)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.p <= 0.0 or not self.training:
            return x
        keep = 1.0 - self.p
        mask = x.new_empty((x.shape[0],) + (1,) * (x.dim() - 1)).bernoulli_(keep)
        return x * mask / keep


def small_init_(module: nn.Linear, std: float = 0.02) -> nn.Linear:
    """Small init for modulation layers; flagged so that OmniMorphNet._init_weights does not overwrite it."""
    nn.init.normal_(module.weight, std=std)
    if module.bias is not None:
        nn.init.zeros_(module.bias)
    module._custom_init = True
    return module


def paired_box_giou(a: torch.Tensor, b: torch.Tensor, eps: float = 1e-7) -> Tuple[torch.Tensor, torch.Tensor]:
    """Element-wise GIoU / IoU of two (N,4) xyxy box sets."""
    area_a = (a[:, 2] - a[:, 0]).clamp(min=0) * (a[:, 3] - a[:, 1]).clamp(min=0)
    area_b = (b[:, 2] - b[:, 0]).clamp(min=0) * (b[:, 3] - b[:, 1]).clamp(min=0)
    lt = torch.max(a[:, :2], b[:, :2])
    rb = torch.min(a[:, 2:], b[:, 2:])
    wh = (rb - lt).clamp(min=0)
    inter = wh[:, 0] * wh[:, 1]
    union = area_a + area_b - inter
    iou = inter / (union + eps)
    lt_c = torch.min(a[:, :2], b[:, :2])
    rb_c = torch.max(a[:, 2:], b[:, 2:])
    wh_c = (rb_c - lt_c).clamp(min=0)
    area_c = wh_c[:, 0] * wh_c[:, 1]
    giou = iou - (area_c - union) / (area_c + eps)
    return giou, iou


def voc_colormap(n: int = 256) -> np.ndarray:
    cmap = np.zeros((n, 3), dtype=np.uint8)
    for i in range(n):
        r = g = b = 0
        c = i
        for j in range(8):
            r |= ((c >> 0) & 1) << (7 - j)
            g |= ((c >> 1) & 1) << (7 - j)
            b |= ((c >> 2) & 1) << (7 - j)
            c >>= 3
        cmap[i] = (r, g, b)
    return cmap


def voc_ap(rec: np.ndarray, prec: np.ndarray) -> float:
    """VOC2010+ all-point interpolated AP."""
    mrec = np.concatenate(([0.0], rec, [1.0]))
    mpre = np.concatenate(([0.0], prec, [0.0]))
    for i in range(len(mpre) - 2, -1, -1):
        mpre[i] = max(mpre[i], mpre[i + 1])
    idx = np.nonzero(mrec[1:] != mrec[:-1])[0]
    return float(np.sum((mrec[idx + 1] - mrec[idx]) * mpre[idx + 1]))


def multilabel_map(scores: np.ndarray, labels: np.ndarray) -> float:
    """Mean over classes of the average precision of a multi-label classifier (in %)."""
    aps = []
    for c in range(scores.shape[1]):
        y = labels[:, c] > 0.5
        npos = int(y.sum())
        if npos == 0:
            continue
        order = np.argsort(-scores[:, c], kind="stable")
        y = y[order]
        tp = np.cumsum(y)
        prec = tp / np.arange(1, len(y) + 1)
        aps.append(float((prec * y).sum() / npos))
    return float(np.mean(aps)) * 100.0 if aps else 0.0


def greedy_nms(boxes: np.ndarray, scores: np.ndarray, iou_thresh: float) -> List[int]:
    """Plain greedy NMS (standard, visualisation-only -- the AP metric stays raw/NMS-free)."""
    if len(boxes) == 0:
        return []
    order = np.argsort(-scores)
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(int(i))
        if order.size == 1:
            break
        rest = order[1:]
        ious = DetectionEvaluator._iou(boxes[i], boxes[rest])
        order = rest[ious <= iou_thresh]
    return keep


# ---- letterbox (aspect-ratio preserving resize + pad) helpers, shared by the dataset and the inferencer -------
def compute_letterbox_params(orig_w: int, orig_h: int, size: int) -> Dict[str, Any]:
    orig_w, orig_h = max(1, int(orig_w)), max(1, int(orig_h))
    scale = min(size / orig_w, size / orig_h)
    new_w = max(1, min(size, int(round(orig_w * scale))))
    new_h = max(1, min(size, int(round(orig_h * scale))))
    pad_left = (size - new_w) // 2
    pad_top = (size - new_h) // 2
    return {"scale": float(scale), "new_w": new_w, "new_h": new_h, "pad_left": pad_left, "pad_top": pad_top,
            "orig_w": orig_w, "orig_h": orig_h, "size": size}


def letterbox_boxes(boxes_xyxy_norm: np.ndarray, ref_w: float, ref_h: float, lb: Dict[str, Any]) -> np.ndarray:
    """Boxes normalised to a (ref_w, ref_h) canvas -> boxes normalised to the letterboxed `lb['size']` canvas."""
    if boxes_xyxy_norm is None or len(boxes_xyxy_norm) == 0:
        return np.zeros((0, 4), dtype=np.float32)
    px = boxes_xyxy_norm.astype(np.float32) * np.array([ref_w, ref_h, ref_w, ref_h], dtype=np.float32)
    px = px * lb["scale"]
    px[:, [0, 2]] += lb["pad_left"]
    px[:, [1, 3]] += lb["pad_top"]
    out = px / float(lb["size"])
    return np.clip(out, 0.0, 1.0).astype(np.float32)


def unletterbox_boxes_to_pixels(boxes_xyxy_norm_canvas: np.ndarray, lb: Dict[str, Any]) -> np.ndarray:
    """Boxes normalised to the letterboxed canvas -> pixel coordinates on the ORIGINAL image."""
    if boxes_xyxy_norm_canvas is None or len(boxes_xyxy_norm_canvas) == 0:
        return np.zeros((0, 4), dtype=np.float32)
    px = boxes_xyxy_norm_canvas.astype(np.float32) * float(lb["size"])
    px[:, [0, 2]] -= lb["pad_left"]
    px[:, [1, 3]] -= lb["pad_top"]
    px = px / max(lb["scale"], 1e-8)
    px[:, [0, 2]] = np.clip(px[:, [0, 2]], 0, lb["orig_w"])
    px[:, [1, 3]] = np.clip(px[:, [1, 3]], 0, lb["orig_h"])
    return px


# ---- PASCAL VOC 2012 root resolution / accounting -------------------------------------------------------------
# The official trainval devkit (VOCtrainval_11-May-2012.tar, which is what every "PASCAL VOC 2012" Kaggle re-
# upload -- including huanghanchina/pascal-voc-2012 -- repackages) contains 17,125 images in JPEGImages with a
# matching XML in Annotations for every one of them: that is the "17.1k images" figure. Those 17,125 images are
# shared across several DIFFERENT official task splits that are each a subset of that total:
#   - ImageSets/Main/{train,val}.txt (classification + detection):  5,717 / 5,823 images
#   - ImageSets/Segmentation/{train,val}.txt (pixel-level masks):   1,464 / 1,449 images
# Only the 2,913 images in the Segmentation split have a SegmentationClass/SegmentationObject PNG at all -- and
# this network needs a mask, an edge map, boxes AND labels for every single training sample, so restricting to
# that 2,913-image subset (as this dataset class does, and as reference multi-task VOC2012 implementations using
# the same protocol also do) is correct, not a bug: training on all 17,125 would mean ~83% of samples have no
# segmentation/edge target to supervise against. What IS a bug -- and what produces exactly the symptom of a
# reported image count that makes no sense against the 17.1k total -- is `dataset_root` resolving to the wrong
# directory on disk (wrong nesting from a Kaggle re-upload, or a duplicated/mirrored copy), which can make
# `_read_ids` read a stray file, an unrelated `ImageSets/Main` list, or several concatenated copies instead of
# the real 1,464/1,449-image Segmentation split. `resolve_voc2012_root` and `describe_voc2012_root` below exist
# to catch that at load time instead of silently training on the wrong data.
VOC2012_OFFICIAL_COUNTS = {
    "total_images": 17125,                                  # JPEGImages / Annotations, full trainval package
    "main_train": 5717, "main_val": 5823,                    # ImageSets/Main/{train,val}.txt
    "segmentation_train": 1464, "segmentation_val": 1449,    # ImageSets/Segmentation/{train,val}.txt
}


def _is_voc2012_root(path: str) -> bool:
    return (os.path.isdir(os.path.join(path, "JPEGImages"))
            and os.path.isfile(os.path.join(path, "ImageSets", "Segmentation", "train.txt"))
            and os.path.isfile(os.path.join(path, "ImageSets", "Segmentation", "val.txt")))


def resolve_voc2012_root(candidate_root: str, max_search_depth: int = 4) -> str:
    """Finds the real VOCdevkit-style directory (the one directly containing JPEGImages/, Annotations/ and
    ImageSets/Segmentation/{train,val}.txt) starting from `candidate_root`. Kaggle re-uploads of VOC2012 are not
    consistent about nesting -- some extract straight into the dataset root, some wrap it in one extra
    'VOC2012/' folder, a few double-wrap it -- and silently guessing wrong here is exactly what turns into wildly
    wrong sample counts downstream instead of a clear error. If `candidate_root` itself is not the answer, this
    searches under it, and -- since Kaggle always mounts an attached dataset at /kaggle/input/<slug>/ -- also
    tries every sibling of `candidate_root` under /kaggle/input whose name contains "voc" or "pascal", in case
    the configured slug is slightly off. Raises FileNotFoundError with an actionable message if nothing is found.
    If more than one matching directory turns up, the shallowest is used and every match is printed, since more
    than one match is itself a sign of a duplicated/mirrored copy in the download."""
    def search(root: str) -> List[str]:
        if not os.path.isdir(root):
            return []
        if _is_voc2012_root(root):
            return [root]
        found = []
        base_depth = root.rstrip(os.sep).count(os.sep)
        for dirpath, dirnames, _filenames in os.walk(root):
            depth = dirpath.rstrip(os.sep).count(os.sep) - base_depth
            if depth > max_search_depth:
                dirnames[:] = []
                continue
            if _is_voc2012_root(dirpath):
                found.append(dirpath)
                dirnames[:] = []          # do not also look for nested duplicates below a match
        return found

    matches = search(candidate_root)
    searched = [candidate_root]
    if not matches:
        kaggle_input = "/kaggle/input"
        if os.path.isdir(kaggle_input):
            for name in sorted(os.listdir(kaggle_input)):
                low = name.lower()
                sibling = os.path.join(kaggle_input, name)
                if sibling == candidate_root or not os.path.isdir(sibling):
                    continue
                if "voc" in low or "pascal" in low:
                    searched.append(sibling)
                    matches.extend(search(sibling))
    if not matches:
        raise FileNotFoundError(
            f"Could not find a PASCAL VOC2012 directory (JPEGImages/ + ImageSets/Segmentation/{{train,val}}.txt) "
            f"under any of: {searched}. Set `dataset_root` to wherever this notebook/session actually mounts "
            f"the Kaggle dataset -- inside a Kaggle Notebook with huanghanchina/pascal-voc-2012 attached, list "
            f"`/kaggle/input` to see the real mount folder name (it is the dataset's URL slug, e.g. "
            f"'pascal-voc-2012', never a path containing '/datasets/<owner>/').")
    matches = sorted(set(matches), key=lambda p: p.count(os.sep))
    if len(matches) > 1:
        print(f"[!] Found {len(matches)} candidate VOC2012 directories -- this usually means the download "
              f"contains a duplicated/mirrored copy, which would silently inflate every split's image count:")
        for m in matches:
            print(f"      {m}")
        print(f"    Using the shallowest one: {matches[0]}")
    return matches[0]


def describe_voc2012_root(root: str) -> Dict[str, int]:
    """Prints (and returns) a full accounting of what is actually on disk at `root` next to the official VOC2012
    trainval numbers, so a wrong mount path or a duplicated download shows up immediately as a loud warning
    instead of silently inflating or shrinking every split."""
    def count_files(path: str) -> int:
        try:
            return len([f for f in os.listdir(path) if os.path.isfile(os.path.join(path, f))])
        except OSError:
            return -1

    def count_lines(path: str) -> int:
        try:
            with open(path) as f:
                return len({ln.strip().split()[0] for ln in f if ln.strip()})
        except OSError:
            return -1

    counts = {
        "jpeg_images": count_files(os.path.join(root, "JPEGImages")),
        "annotations": count_files(os.path.join(root, "Annotations")),
        "segmentation_class_masks": count_files(os.path.join(root, "SegmentationClass")),
        "main_train": count_lines(os.path.join(root, "ImageSets", "Main", "train.txt")),
        "main_val": count_lines(os.path.join(root, "ImageSets", "Main", "val.txt")),
        "segmentation_train": count_lines(os.path.join(root, "ImageSets", "Segmentation", "train.txt")),
        "segmentation_val": count_lines(os.path.join(root, "ImageSets", "Segmentation", "val.txt")),
    }
    off = VOC2012_OFFICIAL_COUNTS
    print(f"[*] VOC2012 root resolved to: {root}")
    print(f"    JPEGImages: {counts['jpeg_images']} files  (official full trainval package: {off['total_images']})")
    print(f"    Annotations: {counts['annotations']} files, SegmentationClass masks: {counts['segmentation_class_masks']}")
    print(f"    ImageSets/Main train/val: {counts['main_train']}/{counts['main_val']} "
          f"(official: {off['main_train']}/{off['main_val']})")
    print(f"    ImageSets/Segmentation train/val: {counts['segmentation_train']}/{counts['segmentation_val']} "
          f"(official: {off['segmentation_train']}/{off['segmentation_val']}) <- this is the subset actually used "
          f"below: every task here needs a pixel mask per image, and only these have one.")
    for key in ("segmentation_train", "segmentation_val"):
        n, expected = counts[key], off[key]
        if n >= 0 and abs(n - expected) > max(30, int(expected * 0.05)):
            print(f"    [!] WARNING: {key} has {n} entries on disk; the official split has {expected}. "
                  f"`dataset_root` is likely mis-resolved (wrong nesting, stale cache, or a duplicated copy).")
    return counts


class DetectionEvaluator:
    """Accumulates detections over a WHOLE epoch and computes VOC-style mAP@IoU. 'difficult' GT are ignored."""
    def __init__(self, num_classes: int, iou_thresh: float = 0.5, score_thresh: float = 0.01,
                 max_dets_per_image: int = 50):
        self.num_classes = num_classes
        self.iou_thresh = iou_thresh
        self.score_thresh = score_thresh
        self.max_dets = max_dets_per_image
        self.dets = [[] for _ in range(num_classes)]
        self.gts = {}
        self.npos = np.zeros(num_classes, dtype=np.int64)
        self.n_images = 0

    @torch.no_grad()
    def update(self, pred_boxes, pred_logits, pred_iou, gt_boxes, gt_labels, gt_difficult):
        probs = pred_logits.float().softmax(dim=-1)[..., :-1]
        scores = (probs * torch.sigmoid(pred_iou.float()).unsqueeze(-1)).cpu().numpy()
        boxes = pred_boxes.float().cpu().numpy()
        for b in range(scores.shape[0]):
            img = self.n_images
            self.n_images += 1
            gtb = gt_boxes[b].detach().cpu().numpy()
            gtl = gt_labels[b].detach().cpu().numpy()
            gtd = gt_difficult[b].detach().cpu().numpy().astype(bool)
            for c in np.unique(gtl):
                m = gtl == c
                self.gts[(img, int(c))] = (gtb[m], gtd[m])
                self.npos[int(c)] += int((~gtd[m]).sum())
            s = scores[b]
            qs, cs = np.nonzero(s > self.score_thresh)
            if len(qs) > self.max_dets:
                top = np.argsort(-s[qs, cs])[: self.max_dets]
                qs, cs = qs[top], cs[top]
            for q, c in zip(qs, cs):
                self.dets[int(c)].append((float(s[q, c]), img, boxes[b, q]))

    @staticmethod
    def _iou(box: np.ndarray, gts: np.ndarray) -> np.ndarray:
        ix1 = np.maximum(box[0], gts[:, 0])
        iy1 = np.maximum(box[1], gts[:, 1])
        ix2 = np.minimum(box[2], gts[:, 2])
        iy2 = np.minimum(box[3], gts[:, 3])
        inter = np.clip(ix2 - ix1, 0, None) * np.clip(iy2 - iy1, 0, None)
        union = ((box[2] - box[0]) * (box[3] - box[1])
                 + (gts[:, 2] - gts[:, 0]) * (gts[:, 3] - gts[:, 1]) - inter)
        return inter / np.maximum(union, 1e-9)

    def compute(self) -> float:
        aps = []
        for c in range(self.num_classes):
            if self.npos[c] == 0:
                continue
            dets = sorted(self.dets[c], key=lambda d: -d[0])
            tp = np.zeros(len(dets))
            fp = np.zeros(len(dets))
            used: Dict[Tuple[int, int], np.ndarray] = {}
            for k, (_, img, box) in enumerate(dets):
                gt = self.gts.get((img, c))
                if gt is None:
                    fp[k] = 1
                    continue
                gtb, gtd = gt
                ious = self._iou(box, gtb)
                j = int(np.argmax(ious))
                if ious[j] >= self.iou_thresh:
                    if gtd[j]:
                        continue                      # matched a 'difficult' object: neither TP nor FP
                    flags = used.setdefault((img, c), np.zeros(len(gtb), dtype=bool))
                    if not flags[j]:
                        tp[k] = 1
                        flags[j] = True
                    else:
                        fp[k] = 1
                else:
                    fp[k] = 1
            tp, fp = np.cumsum(tp), np.cumsum(fp)
            rec = tp / self.npos[c]
            prec = tp / np.maximum(tp + fp, 1e-9)
            aps.append(voc_ap(rec, prec))
        return float(np.mean(aps)) * 100.0 if aps else 0.0


# ============================================================================
# 3. PROMPT-GUIDED COMPONENTS  (unchanged from v2: already fixed the real bugs -- identity-only square layers,
#    the ~150M-parameter constant-vector hyper-network, the point-wise "deformable" conv, the attention block
#    that degenerated to a global average, and every zero-init that _init_weights used to silently overwrite)
# ============================================================================
class PromptGuidedLoRaLin(nn.Module):
    """Linear layer = full-rank base weight + prompt-modulated low-rank (LoRA) update, gated by global statistics."""
    def __init__(self, in_features: int, out_features: int, config: OmniMorphConfig):
        super().__init__()
        self.cfg = config
        rank = max(config.lora_min_rank, int(min(in_features, out_features) * config.lora_rank_ratio))
        self.rank = rank
        pd = config.prompt_dim
        self.base = nn.Linear(in_features, out_features)
        self.down = nn.Linear(in_features, rank, bias=False)
        self.act = nn.GELU()
        self.up = nn.Linear(rank, out_features, bias=True)
        self.rank_gate = small_init_(nn.Linear(pd, rank))
        self.spec_gamma = small_init_(nn.Linear(pd, out_features))
        self.spec_beta = small_init_(nn.Linear(pd, out_features))
        hidden = max(16, in_features // 4)
        self.prompt_proj = nn.Linear(pd, in_features)
        self.temp_proj = nn.Linear(in_features * 3, 1)
        self.attn_mlp = nn.Sequential(nn.Linear(in_features * 3, hidden), nn.GELU(), nn.Linear(hidden, out_features))

    def forward(self, x: torch.Tensor, prompt: torch.Tensor) -> torch.Tensor:
        # x: (B, N, C_in), prompt: (B, P, D)
        p_pool = prompt.mean(dim=1)
        base = self.base(x)
        mid = self.act(self.down(x)) * (1.0 + torch.tanh(self.rank_gate(p_pool))).unsqueeze(1)
        lora = self.up(mid)
        gamma = torch.tanh(self.spec_gamma(p_pool)).unsqueeze(1)
        beta = torch.tanh(self.spec_beta(p_pool)).unsqueeze(1)
        lora = lora * (1.0 + gamma) + 0.1 * beta
        gap = x.mean(dim=1, keepdim=True)
        gmp = x.amax(dim=1, keepdim=True)
        p_mean = self.prompt_proj(p_pool).unsqueeze(1)
        stats = torch.cat([gap, gmp, p_mean], dim=-1)
        temp = 1.0 + 4.0 * torch.sigmoid(self.temp_proj(stats))
        weights = torch.sigmoid(self.attn_mlp(stats) / temp)
        return base + lora * weights


class PromptGuidedDeformableConv(nn.Module):
    """Depth-wise 3x3 deformable conv (DCNv2-like) with prompt-conditioned offsets / modulation."""
    def __init__(self, channels: int, config: OmniMorphConfig):
        super().__init__()
        self.cfg = config
        K = config.deform_kernel
        assert K % 2 == 1 and config.deform_padding == K // 2, "deform_padding must equal deform_kernel // 2"
        self.K = K
        self.pad = config.deform_padding
        self.max_offset = float(config.deform_max_offset)
        self.prompt_proj = nn.Linear(config.prompt_dim, channels)
        out_params = 2 + 2 * K * K + K * K + K * K
        self.offset_mod_conv = nn.Conv2d(channels, out_params, kernel_size=config.conv_kernel, padding=config.conv_padding)
        nn.init.zeros_(self.offset_mod_conv.weight)
        nn.init.zeros_(self.offset_mod_conv.bias)
        self.offset_mod_conv._custom_init = True
        tap = torch.full((channels, K * K), 0.5 / (K * K - 1))
        tap[:, (K * K) // 2] = 0.5
        self.tap_weights = nn.Parameter(tap)
        self.proj = nn.Conv2d(channels, channels, kernel_size=1)

    def forward(self, x: torch.Tensor, prompt: torch.Tensor) -> torch.Tensor:
        B, C, H, W = x.shape
        K = self.K
        x_cond = x + self.prompt_proj(prompt.mean(dim=1)).view(B, C, 1, 1)
        params = self.offset_mod_conv(x_cond)
        shared = params[:, :2]
        residual = params[:, 2:2 + 2 * K * K]
        curvature = torch.tanh(params[:, 2 + 2 * K * K: 2 + 3 * K * K])
        modulation = 2.0 * torch.sigmoid(params[:, 2 + 3 * K * K:])          # == 1 at init
        residual = residual.reshape(B, K * K, 2, H, W)
        cur = curvature.unsqueeze(2) * self.cfg.curvature_scale
        offsets = shared.unsqueeze(1) + residual * (1.0 + cur)                # (B, K*K, 2, H, W) in pixels
        offsets = torch.tanh(offsets / self.max_offset) * self.max_offset
        base_grid = make_base_grid(H, W, x.device)
        scale = px_to_norm(H, W, x.device)
        x = x.contiguous()
        out = torch.zeros_like(x)
        idx = 0
        for ky in range(-self.pad, self.pad + 1):
            for kx in range(-self.pad, self.pad + 1):
                disp = torch.tensor([float(kx), float(ky)], device=x.device)
                off = offsets[:, idx].permute(0, 2, 3, 1).float()             # (B,H,W,2)
                grid = base_grid + (off + disp) * scale
                s = F.grid_sample(x, grid.to(x.dtype), mode="bilinear", padding_mode="zeros", align_corners=False)
                w_k = self.tap_weights[:, idx].view(1, C, 1, 1)
                out = out + s * modulation[:, idx:idx + 1] * w_k
                idx += 1
        return self.proj(out)


class PromptGuidedSDTA(nn.Module):
    """Prompt-guided spatial self-attention with 2-D RoPE and cosine attention."""
    def __init__(self, dim: int, num_heads: int, config: OmniMorphConfig):
        super().__init__()
        assert dim % num_heads == 0
        self.num_heads = num_heads
        self.head_dim = dim // num_heads
        self.cfg = config
        self.logit_scale = nn.Parameter(torch.full((num_heads, 1, 1), math.log(config.attn_logit_scale_init)))
        self.max_log_scale = math.log(config.attn_logit_scale_max)
        self.to_q = PromptGuidedLoRaLin(dim, dim, config)
        self.to_k = PromptGuidedLoRaLin(dim, dim, config)
        self.to_v = PromptGuidedLoRaLin(dim, dim, config)
        self.proj = PromptGuidedLoRaLin(dim, dim, config)
        self.temp_head = small_init_(nn.Linear(config.prompt_dim, num_heads))
        self.val_gate = small_init_(nn.Linear(config.prompt_dim, dim))
        self._rope_cache: Dict[tuple, Tuple[torch.Tensor, torch.Tensor]] = {}

    def _get_rope(self, H: int, W: int, device) -> Tuple[torch.Tensor, torch.Tensor]:
        key = (H, W, str(device))
        if key not in self._rope_cache:
            half = self.head_dim // 2
            quarter_y = half // 2
            quarter_x = half - quarter_y
            base = self.cfg.rope_base
            inv_freq_y = 1.0 / (base ** (torch.arange(quarter_y, device=device, dtype=torch.float32) / max(quarter_y, 1)))
            inv_freq_x = 1.0 / (base ** (torch.arange(quarter_x, device=device, dtype=torch.float32) / max(quarter_x, 1)))
            ys = torch.arange(H, device=device, dtype=torch.float32)
            xs = torch.arange(W, device=device, dtype=torch.float32)
            yy, xx = torch.meshgrid(ys, xs, indexing="ij")
            freqs_y = yy.reshape(-1, 1) * inv_freq_y.unsqueeze(0)
            freqs_x = xx.reshape(-1, 1) * inv_freq_x.unsqueeze(0)
            cos = torch.cat([freqs_y.cos(), freqs_x.cos()], dim=-1)[None, None]
            sin = torch.cat([freqs_y.sin(), freqs_x.sin()], dim=-1)[None, None]
            self._rope_cache[key] = (cos, sin)
        return self._rope_cache[key]

    @staticmethod
    def _apply_rope(t: torch.Tensor, cos: torch.Tensor, sin: torch.Tensor) -> torch.Tensor:
        half = t.shape[-1] // 2
        t1, t2 = t[..., :half], t[..., half:]
        cos_full, sin_full = torch.cat([cos, cos], dim=-1), torch.cat([sin, sin], dim=-1)
        rot = torch.cat([-t2, t1], dim=-1)
        return t * cos_full + rot * sin_full

    def forward(self, x: torch.Tensor, prompt: torch.Tensor) -> torch.Tensor:
        B, C, H, W = x.shape
        N, h, d = H * W, self.num_heads, self.head_dim
        x_flat = x.flatten(2).transpose(1, 2)
        q = self.to_q(x_flat, prompt).reshape(B, N, h, d).transpose(1, 2).float()
        k = self.to_k(x_flat, prompt).reshape(B, N, h, d).transpose(1, 2).float()
        v = self.to_v(x_flat, prompt).reshape(B, N, h, d).transpose(1, 2)
        if d % 2 == 0:
            cos, sin = self._get_rope(H, W, x.device)
            q, k = self._apply_rope(q, cos, sin), self._apply_rope(k, cos, sin)
        q = F.normalize(q, dim=-1, eps=1e-6)
        k = F.normalize(k, dim=-1, eps=1e-6)
        p_pool = prompt.mean(dim=1)
        log_scale = self.logit_scale + self.temp_head(p_pool).float().view(B, h, 1, 1)
        scale = torch.exp(torch.clamp(log_scale, max=self.max_log_scale))
        # SDPA divides by sqrt(d): pre-multiply so that the logits are exactly  scale * cos(q, k)
        q = (q * (scale * math.sqrt(d))).to(v.dtype)
        k = k.to(v.dtype)
        out = F.scaled_dot_product_attention(q, k, v)                       # (B,h,N,d)
        out = out.transpose(1, 2).reshape(B, N, C)
        out = out * (1.0 + torch.tanh(self.val_gate(p_pool)).unsqueeze(1))
        return self.proj(out, prompt).transpose(1, 2).reshape(B, C, H, W)


class HybridEncoderBlock(nn.Module):
    def __init__(self, dim: int, num_heads: int, config: OmniMorphConfig, drop_path: float = 0.0):
        super().__init__()
        self.cfg = config
        self.norm1 = nn.GroupNorm(config.norm_groups, dim)
        self.spatial_deform = PromptGuidedDeformableConv(dim, config)
        self.norm2 = nn.GroupNorm(config.norm_groups, dim)
        self.sdta = PromptGuidedSDTA(dim, num_heads, config)
        self.norm3 = nn.GroupNorm(config.norm_groups, dim)
        self.ffn_down = PromptGuidedLoRaLin(dim, dim * config.ffn_ratio, config)
        self.act = nn.GELU()
        self.ffn_up = PromptGuidedLoRaLin(dim * config.ffn_ratio, dim, config)
        self.drop_path = DropPath(drop_path)

    def forward(self, x: torch.Tensor, prompt: torch.Tensor) -> torch.Tensor:
        x = x + self.drop_path(self.spatial_deform(self.norm1(x), prompt))
        x = x + self.drop_path(self.sdta(self.norm2(x), prompt))
        ffn_in = self.norm3(x).flatten(2).transpose(1, 2)
        ffn_out = self.ffn_up(self.act(self.ffn_down(ffn_in, prompt)), prompt)
        ffn_out = ffn_out.transpose(1, 2).reshape(x.shape)
        return x + self.drop_path(ffn_out)


class MultiScalePixelDecoder(nn.Module):
    def __init__(self, in_dims: List[int], config: OmniMorphConfig):
        super().__init__()
        self.cfg = config
        pd = config.pixel_dec_dim
        self.laterals = nn.ModuleList([
            nn.Sequential(nn.Conv2d(d, pd, 1), nn.GroupNorm(config.norm_groups, pd), nn.GELU()) for d in in_dims
        ])
        self.smooth = nn.ModuleList([
            nn.Sequential(nn.Conv2d(pd, pd, config.conv_kernel, padding=config.conv_padding),
                          nn.GroupNorm(config.norm_groups, pd), nn.GELU())
            for _ in in_dims
        ])
        self.align_offsets = nn.ModuleList()
        for _ in range(len(in_dims) - 1):
            conv = nn.Conv2d(pd * 2, 2, kernel_size=config.conv_kernel, padding=config.conv_padding)
            nn.init.zeros_(conv.weight)             # start as an identity alignment (survives _init_weights)
            nn.init.zeros_(conv.bias)
            conv._custom_init = True
            self.align_offsets.append(conv)

    def _deformable_align(self, prev, target, offset_conv):
        B, C, H, W = target.shape
        prev_up = F.interpolate(prev, size=(H, W), mode="bilinear", align_corners=False)
        off = torch.tanh(offset_conv(torch.cat([prev_up, target], dim=1))) * self.cfg.align_max_offset   # pixels
        grid = make_base_grid(H, W, target.device) + off.permute(0, 2, 3, 1).float() * px_to_norm(H, W, target.device)
        return F.grid_sample(prev_up, grid.to(prev_up.dtype), mode="bilinear",
                             padding_mode="border", align_corners=False)

    def forward(self, features: List[torch.Tensor]) -> List[torch.Tensor]:
        results, prev = [], None
        for i in reversed(range(len(features))):
            lateral = self.laterals[i](features[i])
            if prev is not None:
                lateral = lateral + self._deformable_align(prev, lateral, self.align_offsets[i])
            smoothed = self.smooth[i](lateral)
            results.insert(0, smoothed)
            prev = smoothed
        return results


class StyleModulatedConv(nn.Module):
    """Conv + norm + FiLM (scale/shift) from a style vector."""
    def __init__(self, in_channels: int, out_channels: int, style_dim: int, config: OmniMorphConfig):
        super().__init__()
        self.conv = nn.Conv2d(in_channels, out_channels, kernel_size=config.conv_kernel, padding=config.conv_padding)
        self.norm = nn.GroupNorm(config.norm_groups, out_channels)
        self.style_gamma = small_init_(nn.Linear(style_dim, out_channels))
        self.style_beta = small_init_(nn.Linear(style_dim, out_channels))

    def forward(self, x: torch.Tensor, style_vector: torch.Tensor) -> torch.Tensor:
        out = self.norm(self.conv(x))
        gamma = torch.tanh(self.style_gamma(style_vector)).unsqueeze(-1).unsqueeze(-1)
        beta = torch.tanh(self.style_beta(style_vector)).unsqueeze(-1).unsqueeze(-1)
        return F.gelu(out * (1.0 + gamma) + beta)


# ============================================================================
# 4. QUERY DECODER (+ IoU-Consistent Curriculum Denoising)  AND  COMPLETE 5-TASK ARCHITECTURE
# ============================================================================
def _cxcywh_to_boxes(cxcywh: torch.Tensor) -> torch.Tensor:
    cx, cy, w, h = cxcywh.unbind(-1)
    x1 = (cx - w / 2).clamp(0.0, 1.0)
    y1 = (cy - h / 2).clamp(0.0, 1.0)
    x2 = (cx + w / 2).clamp(0.0, 1.0)
    y2 = (cy + h / 2).clamp(0.0, 1.0)
    return torch.stack([x1, y1, x2, y2], dim=-1)


class DecoderLayer(nn.Module):
    """Pre-norm DETR / Mask2Former-style layer: cross-attention -> self-attention -> FFN (own weights per layer).
    `self_attn_mask`, when given, lets the matching queries and the denoising queries (see `QueryDecoder`) share
    one decoder stack for free while remaining information-isolated from each other."""
    def __init__(self, dim: int, heads: int):
        super().__init__()
        self.heads = heads
        self.norm_ca = nn.LayerNorm(dim)
        self.cross_attn = nn.MultiheadAttention(dim, heads, batch_first=True)
        self.norm_sa = nn.LayerNorm(dim)
        self.self_attn = nn.MultiheadAttention(dim, heads, batch_first=True)
        self.norm_ff = nn.LayerNorm(dim)
        self.ffn = nn.Sequential(nn.Linear(dim, dim * 4), nn.GELU(), nn.Linear(dim * 4, dim))

    def forward(self, q, q_pos, mem, mem_pos, self_attn_mask: Optional[torch.Tensor] = None):
        h = self.norm_ca(q)
        q = q + self.cross_attn(h + q_pos, mem + mem_pos, mem, need_weights=False)[0]
        h = self.norm_sa(q)
        q = q + self.self_attn(h + q_pos, h + q_pos, h, need_weights=False, attn_mask=self_attn_mask)[0]
        return q + self.ffn(self.norm_ff(q))


def build_denoising_attn_mask(B: int, n_match: int, n_dn: int, dn_valid: torch.Tensor,
                               num_heads: int, device) -> torch.Tensor:
    """Boolean self-attention mask (True = blocked) for one shared decoder stack that carries both the normal
    'matching' object queries and the denoising queries of ICCD (section 5).  Matching queries must never see the
    denoising queries (they are built directly from noised ground truth -- letting the matching branch attend to
    them would leak GT into the very predictions bipartite matching is supposed to discover on its own).
    Denoising queries may attend to the matching queries and to each other; a deliberate simplification versus
    DN-DETR's multiple, mutually-isolated noise groups, since ICCD uses a single group per image."""
    N = n_match + n_dn
    mask = torch.zeros(B, N, N, dtype=torch.bool, device=device)
    mask[:, :n_match, n_match:] = True                              # matching -> denoising: blocked
    invalid_cols = ~dn_valid                                        # (B, n_dn) padding slots
    mask[:, :, n_match:] |= invalid_cols.unsqueeze(1)                # nobody attends to a padding slot
    idx = torch.arange(N, device=device)
    mask[:, idx, idx] = False                                       # always allow self-attendance (avoids
                                                                      # softmax over an all-blocked row -> NaN)
    return mask.unsqueeze(1).expand(B, num_heads, N, N).reshape(B * num_heads, N, N)


class DenoisingQueryEncoder(nn.Module):
    """Turns a noised (box, label) pair into a decoder query embedding. A dedicated, small, from-scratch module
    (not shared with the learned matching-query embeddings) so its content is entirely determined by the noised
    box/label rather than by a learned per-slot identity."""
    def __init__(self, dim: int, num_classes: int):
        super().__init__()
        self.box_mlp = nn.Sequential(nn.Linear(4, dim), nn.GELU(), nn.Linear(dim, dim))
        self.label_embed = nn.Embedding(num_classes + 1, dim)   # index `num_classes` = padding / no label
        self.fuse = nn.Sequential(nn.Linear(2 * dim, dim), nn.GELU(), nn.LayerNorm(dim))

    def forward(self, boxes_cxcywh: torch.Tensor, labels: torch.Tensor, valid: torch.Tensor) -> torch.Tensor:
        b = self.box_mlp(boxes_cxcywh)
        l = self.label_embed(labels.clamp(min=0))
        out = self.fuse(torch.cat([b, l], dim=-1))
        return out * valid.unsqueeze(-1).to(out.dtype)


class QueryDecoder(nn.Module):
    """Object-query decoder. Each layer attends to a different pixel-decoder scale (coarse -> fine) and returns
    its queries so that every layer can be deeply supervised. Optionally carries ICCD's denoising queries
    alongside the normal learned matching queries in the same forward pass (see `build_denoising_attn_mask`)."""
    def __init__(self, config: OmniMorphConfig):
        super().__init__()
        self.cfg = config
        self.dim = config.pixel_dec_dim
        assert self.dim % 4 == 0
        self.heads = config.num_heads[1]
        self.layers = nn.ModuleList([DecoderLayer(self.dim, self.heads) for _ in range(config.num_refine_rounds)])
        self.query_feat = nn.Embedding(config.num_queries, self.dim)
        self.query_pos = nn.Embedding(config.num_queries, self.dim)
        self.dn_pos_embed = nn.Parameter(torch.zeros(1, 1, self.dim))   # one shared positional token for all
                                                                          # denoising queries: their identity comes
                                                                          # from their noised box/label content,
                                                                          # not from a fixed learned slot
        self.out_norm = nn.LayerNorm(self.dim)
        self._pe_cache: Dict[tuple, torch.Tensor] = {}

    def _pos_enc_2d(self, H: int, W: int, device) -> torch.Tensor:
        key = (H, W, str(device))
        if key not in self._pe_cache:
            d4 = self.dim // 4
            omega = 1.0 / (self.cfg.rope_base ** (torch.arange(d4, device=device, dtype=torch.float32) / d4))
            ys = torch.arange(H, device=device, dtype=torch.float32)
            xs = torch.arange(W, device=device, dtype=torch.float32)
            out_y = ys.unsqueeze(-1) * omega.unsqueeze(0)
            out_x = xs.unsqueeze(-1) * omega.unsqueeze(0)
            pe_y = torch.cat([out_y.sin(), out_y.cos()], dim=-1)          # (H, dim/2)
            pe_x = torch.cat([out_x.sin(), out_x.cos()], dim=-1)          # (W, dim/2)
            pe = torch.cat([pe_y[:, None, :].expand(H, W, -1), pe_x[None, :, :].expand(H, W, -1)], dim=-1)
            self._pe_cache[key] = pe.reshape(1, H * W, self.dim)
        return self._pe_cache[key]

    def forward(self, memory_levels: List[torch.Tensor], dn_embed: Optional[torch.Tensor] = None,
                dn_valid: Optional[torch.Tensor] = None) -> List[torch.Tensor]:
        B = memory_levels[0].shape[0]
        q_match = self.query_feat.weight.unsqueeze(0).expand(B, -1, -1)
        q_pos_match = self.query_pos.weight.unsqueeze(0).expand(B, -1, -1)
        attn_mask = None
        if dn_embed is not None:
            n_dn = dn_embed.shape[1]
            q = torch.cat([q_match, dn_embed], dim=1)
            q_pos = torch.cat([q_pos_match, self.dn_pos_embed.expand(B, n_dn, -1)], dim=1)
            attn_mask = build_denoising_attn_mask(B, self.cfg.num_queries, n_dn, dn_valid, self.heads, q.device)
        else:
            q, q_pos = q_match, q_pos_match
        outs = []
        for r, layer in enumerate(self.layers):
            feat = memory_levels[r % len(memory_levels)]
            _, _, H, W = feat.shape
            mem = feat.flatten(2).transpose(1, 2)
            mem_pos = self._pos_enc_2d(H, W, feat.device).to(mem.dtype)
            q = layer(q, q_pos, mem, mem_pos, self_attn_mask=attn_mask)
            outs.append(self.out_norm(q))
        return outs


class QueryPixelAffinityRefiner(nn.Module):
    """Prototype-Conditioned Segmentation Refinement (PCSR).

    The object-query decoder already runs on every forward pass to support detection and classification, but in
    v2 the dense segmentation head never saw it -- it is a purely local conv classifier, which is exactly the kind
    of thing that produces the wrong-class islands and holes seen inside otherwise-correct silhouettes in the v2
    qualitative dumps (no object-level consistency term anywhere in the segmentation path).

    Each matching query already has a class distribution over the 20 VOC classes + "no object" (reused directly
    from `bbox_cls_head`, no new classifier). We project each query to a key vector and dot it against the
    pixel-decoder feature map to get a per-query spatial affinity map, then marginalise those affinity maps over
    classes using the SAME class probabilities (no-object -> segmentation background, class c -> segmentation
    class c+1). The result is added, with a zero-initialised learned gain, on top of the dense head's own logits
    -- so PCSR starts as an exact no-op and can only help once training shows it does.

    Lineage: inspired by Mask2Former's per-query dot-product mask logits, but marginalised over classes through
    the detector's own softmax rather than a 1:1 Hungarian query<->mask assignment, and fused additively with a
    parallel dense head instead of replacing it.
    """
    def __init__(self, pd: int, num_seg_classes: int, num_det_classes: int):
        super().__init__()
        self.num_seg_classes = num_seg_classes
        self.num_det_classes = num_det_classes
        self.key_proj = nn.Linear(pd, pd)
        self.query_proj = nn.Linear(pd, pd)
        self.scale = pd ** -0.5
        self.out_gain = nn.Parameter(torch.zeros(1))   # starts at 0 -> pure dense head at init

    def forward(self, pixel_feat: torch.Tensor, queries: torch.Tensor,
                query_class_probs: torch.Tensor) -> torch.Tensor:
        B, C, H, W = pixel_feat.shape
        k = self.key_proj(pixel_feat.flatten(2).transpose(1, 2).float())      # (B,HW,pd)
        q = self.query_proj(queries.float())                                   # (B,Q,pd)
        affinity = torch.einsum("bqc,bnc->bqn", q, k) * self.scale             # (B,Q,HW)
        probs_bg = query_class_probs[..., -1:]                                 # (B,Q,1)   no-object -> background
        probs_fg = query_class_probs[..., :-1]                                 # (B,Q,20)
        probs_seg = torch.cat([probs_bg, probs_fg], dim=-1)                    # (B,Q,21)
        refine = torch.einsum("bqn,bqs->bsn", affinity, probs_seg)             # (B,21,HW)
        refine = refine.reshape(B, self.num_seg_classes, H, W)
        return refine * self.out_gain


class OmniMorphNet(nn.Module):
    def __init__(self, config: OmniMorphConfig):
        super().__init__()
        assert config.sr_up_factor == config.pixel_shuffle_factor ** 2
        self.config = config
        P, D = config.num_prompts, config.prompt_dim
        # Learned task prompts + an image-conditioned residual computed at the start of every stage.
        self.global_prompts = nn.Parameter(torch.randn(1, P, D) * 0.02)
        self.prompt_gens = nn.ModuleList([small_init_(nn.Linear(d, P * D), std=0.02) for d in config.embed_dims])
        self.stem = nn.Sequential(
            nn.Conv2d(config.in_channels, config.embed_dims[0], kernel_size=config.conv_kernel,
                      stride=config.conv_stride_normal, padding=config.conv_padding),
            nn.GroupNorm(config.norm_groups, config.embed_dims[0]), nn.GELU(),
        )
        dpr = torch.linspace(0, config.drop_path_rate, sum(config.depths)).tolist()
        self.stages, self.downsamplers = nn.ModuleList(), nn.ModuleList()
        b = 0
        for i in range(len(config.embed_dims)):
            blocks = []
            for _ in range(config.depths[i]):
                blocks.append(HybridEncoderBlock(config.embed_dims[i], config.num_heads[i], config, drop_path=dpr[b]))
                b += 1
            self.stages.append(nn.ModuleList(blocks))
            if i < len(config.embed_dims) - 1:
                self.downsamplers.append(nn.Sequential(
                    nn.Conv2d(config.embed_dims[i], config.embed_dims[i + 1], kernel_size=config.conv_kernel,
                              stride=config.conv_stride_down, padding=config.conv_padding),
                    nn.GroupNorm(config.norm_groups, config.embed_dims[i + 1]), nn.GELU(),
                ))
        pd = config.pixel_dec_dim
        self.pixel_decoder = MultiScalePixelDecoder(config.embed_dims, config)
        self.query_decoder = QueryDecoder(config)
        self.dn_encoder = DenoisingQueryEncoder(pd, config.num_classes) if config.use_denoising else None
        self.global_fuse = nn.Sequential(nn.Linear(2 * pd, pd), nn.GELU())
        # ---- semantic segmentation (dense head + PCSR refinement, + deep supervision at 1/2 resolution) ----
        self.seg_dropout = nn.Dropout2d(config.head_dropout_base)     # p mutated at runtime by ATHM (section 7)
        self.seg_head = nn.Sequential(
            nn.Conv2d(pd, pd, kernel_size=config.conv_kernel, padding=config.conv_padding),
            nn.GroupNorm(config.norm_groups, pd), nn.GELU(),
            nn.Conv2d(pd, config.num_mask_classes, kernel_size=1),
        )
        self.seg_refiner = QueryPixelAffinityRefiner(pd, config.num_mask_classes, config.num_classes)
        self.aux_seg_head = nn.Conv2d(pd, config.num_mask_classes, kernel_size=1)
        # ---- multi-label classification from pooled top-level features + queries ----
        self.cls_dropout = nn.Dropout(config.head_dropout_base)       # p mutated at runtime by ATHM
        self.cls_pre = nn.Linear(pd, pd)
        self.cls_act = nn.GELU()
        self.cls_out = nn.Linear(pd, config.num_classes)
        # ---- detection heads (shared across decoder layers AND the denoising queries, DETR-style) ----
        self.det_dropout = nn.Dropout(config.head_dropout_base)       # applied to matching queries only
        self.bbox_coord_head = nn.Sequential(nn.Linear(pd, pd), nn.ReLU(), nn.Linear(pd, 4))
        self.bbox_cls_head = nn.Linear(pd, config.num_classes + 1)
        self.bbox_iou_head = nn.Sequential(nn.Linear(pd, pd // 2), nn.GELU(), nn.Linear(pd // 2, 1))
        # ---- super-resolution: bicubic base + learned residual (+ mid-resolution deep supervision) ----
        self.sr_dropout = nn.Dropout2d(config.head_dropout_base)      # p mutated at runtime by ATHM
        self.sr_block1 = StyleModulatedConv(pd, config.sr_channels_1, style_dim=pd, config=config)
        self.sr_up1 = nn.Sequential(
            nn.Conv2d(config.sr_channels_1, config.sr_channels_1 * config.sr_up_factor,
                      kernel_size=config.conv_kernel, padding=config.conv_padding),
            nn.PixelShuffle(config.pixel_shuffle_factor), nn.GELU(),
        )
        self.sr_block2 = StyleModulatedConv(config.sr_channels_1, config.sr_channels_2, style_dim=pd, config=config)
        self.sr_mid_head = nn.Conv2d(config.sr_channels_2, config.in_channels, kernel_size=config.conv_kernel,
                                     padding=config.conv_padding)
        self.sr_up2 = nn.Sequential(
            nn.Conv2d(config.sr_channels_2, config.sr_channels_2 * config.sr_up_factor,
                      kernel_size=config.conv_kernel, padding=config.conv_padding),
            nn.PixelShuffle(config.pixel_shuffle_factor), nn.GELU(),
        )
        self.sr_head = nn.Conv2d(config.sr_channels_2, config.in_channels, kernel_size=config.conv_kernel,
                                 padding=config.conv_padding)
        # ---- edges predicted at HR resolution ----
        eh = config.edge_hidden_channels
        self.edge_dropout = nn.Dropout2d(config.head_dropout_base)    # p mutated at runtime by ATHM
        self.edge_coarse = nn.Sequential(
            nn.Conv2d(pd, config.sr_channels_2, kernel_size=config.conv_kernel, padding=config.conv_padding),
            nn.GroupNorm(config.norm_groups, config.sr_channels_2), nn.GELU(),
        )
        self.edge_fuse = nn.Sequential(
            nn.Conv2d(config.sr_channels_2 * 2, eh, kernel_size=config.conv_kernel, padding=config.conv_padding),
            nn.GroupNorm(config.norm_groups, eh), nn.GELU(),
            nn.Conv2d(eh, 1, kernel_size=1),
        )
        self.apply(self._init_weights)
        self._special_inits()

    def _init_weights(self, m):
        if getattr(m, "_custom_init", False):
            return
        if isinstance(m, nn.Linear):
            nn.init.xavier_uniform_(m.weight)
            if m.bias is not None:
                nn.init.zeros_(m.bias)
        elif isinstance(m, nn.Conv2d):
            nn.init.kaiming_normal_(m.weight, mode="fan_out", nonlinearity="relu")
            if m.bias is not None:
                nn.init.zeros_(m.bias)
        elif isinstance(m, (nn.GroupNorm, nn.LayerNorm)):
            nn.init.zeros_(m.bias)
            nn.init.ones_(m.weight)
        elif isinstance(m, nn.Embedding):
            nn.init.normal_(m.weight, std=0.02)

    def _special_inits(self):
        nn.init.zeros_(self.sr_head.weight)                    # SR starts exactly at the bicubic upsampling
        nn.init.zeros_(self.sr_head.bias)
        nn.init.zeros_(self.sr_mid_head.weight)                 # mid-resolution SR also starts at bicubic
        nn.init.zeros_(self.sr_mid_head.bias)
        for conv in (self.seg_head[-1], self.aux_seg_head):
            nn.init.normal_(conv.weight, std=0.01)
            nn.init.zeros_(conv.bias)
        nn.init.normal_(self.edge_fuse[-1].weight, std=0.01)
        nn.init.constant_(self.edge_fuse[-1].bias, -3.0)       # edges are sparse: start with a low edge prior
        nn.init.normal_(self.bbox_coord_head[-1].weight, std=0.01)
        nn.init.zeros_(self.bbox_coord_head[-1].bias)

    def set_task_health(self, health: Dict[str, float]) -> None:
        """Adaptive Task-Health Modulation (ATHM), model side: turns up head-only dropout for whichever task's
        validation metric has stopped improving (see MultiTaskLoss.set_task_health for the loss-weight side and
        OmniMorphTrainer._update_athm for how `health` is computed). The shared trunk's own DropPath is left
        untouched so tasks that are still improving keep full gradient signal through it."""
        cfg = self.config

        def p_for(h):
            return float(min(0.6, cfg.head_dropout_base + (1.0 - h) * cfg.head_dropout_max_extra))

        self.seg_dropout.p = p_for(health.get("seg", 1.0))
        self.edge_dropout.p = p_for(health.get("edge", 1.0))
        self.cls_dropout.p = p_for(health.get("cls", 1.0))
        self.det_dropout.p = p_for(health.get("det", 1.0))
        self.sr_dropout.p = p_for(health.get("rec", 1.0))

    def _decode_boxes(self, raw: torch.Tensor) -> torch.Tensor:
        raw = raw.float()
        cx = torch.sigmoid(raw[..., 0])
        cy = torch.sigmoid(raw[..., 1])
        w = torch.sigmoid(raw[..., 2]) * 0.98 + 0.02           # full-image boxes remain reachable
        h = torch.sigmoid(raw[..., 3]) * 0.98 + 0.02
        return _cxcywh_to_boxes(torch.stack([cx, cy, w, h], dim=-1))

    def _det_heads(self, q: torch.Tensor):
        return self._decode_boxes(self.bbox_coord_head(q)), self.bbox_cls_head(q), self.bbox_iou_head(q).squeeze(-1)

    def _stage_prompts(self, i: int, x: torch.Tensor) -> torch.Tensor:
        B = x.shape[0]
        delta = self.prompt_gens[i](x.mean(dim=(2, 3))).view(B, self.config.num_prompts, self.config.prompt_dim)
        return self.global_prompts + delta

    def forward(self, x_lr: torch.Tensor, dn_boxes: Optional[torch.Tensor] = None,
                dn_labels: Optional[torch.Tensor] = None, dn_valid: Optional[torch.Tensor] = None
                ) -> Dict[str, torch.Tensor]:
        cfg = self.config
        size = (cfg.hr_image_size, cfg.hr_image_size)
        x = self.stem((x_lr - 0.5) / 0.5)
        features = []
        for i in range(len(self.stages)):
            prompts = self._stage_prompts(i, x)
            for block in self.stages[i]:
                x = block(x, prompts)
            features.append(x)
            if i < len(self.downsamplers):
                x = self.downsamplers[i](x)
        ms = self.pixel_decoder(features)
        high_res_feat = ms[0]

        dn_embed = None
        use_dn = dn_boxes is not None and self.dn_encoder is not None
        if use_dn:
            dn_embed = self.dn_encoder(dn_boxes, dn_labels, dn_valid)
        q_layers = self.query_decoder(list(reversed(ms[1:])), dn_embed=dn_embed, dn_valid=dn_valid)
        queries_all = q_layers[-1]
        Q = cfg.num_queries
        queries = queries_all[:, :Q]
        global_vec = self.global_fuse(torch.cat([ms[-1].mean(dim=(2, 3)), queries.mean(dim=1)], dim=-1))

        # ---- segmentation: dense head + PCSR additive refinement ----
        seg_feat = self.seg_dropout(high_res_feat)
        dense_logits = self.seg_head(seg_feat)
        query_probs = F.softmax(self.bbox_cls_head(queries).float(), dim=-1).detach()   # detached: keep the
        # segmentation loss from reshaping the detector's own classification calibration (an explicit
        # interference-control choice, in the same spirit as ATHM below).
        seg_refine = self.seg_refiner(high_res_feat, queries, query_probs)
        pred_masks = F.interpolate(dense_logits + seg_refine, size=size, mode="bilinear", align_corners=False)

        # ---- classification ----
        cls_feat = self.cls_dropout(global_vec)
        pred_cls = self.cls_out(self.cls_act(self.cls_pre(cls_feat)))

        # ---- super-resolution: bicubic(LR) + learned residual, with a mid-resolution auxiliary output ----
        sr = self.sr_block1(high_res_feat, global_vec)
        sr = self.sr_up1(sr)
        sr = self.sr_block2(sr, global_vec)
        sr = self.sr_dropout(sr)
        mid_size = (size[0] // 2, size[1] // 2)
        mid_base = F.interpolate(x_lr, size=mid_size, mode="bicubic", align_corners=False).clamp(0.0, 1.0)
        pred_hr_mid = mid_base + self.sr_mid_head(sr)
        sr_hr = self.sr_up2(sr)
        base = F.interpolate(x_lr, size=size, mode="bicubic", align_corners=False).clamp(0.0, 1.0)
        pred_hr = base + self.sr_head(sr_hr)

        # ---- edges ----
        edge_feat = self.edge_dropout(high_res_feat)
        edge_coarse = F.interpolate(self.edge_coarse(edge_feat), size=size, mode="bilinear", align_corners=False)
        pred_edges = self.edge_fuse(torch.cat([edge_coarse, sr_hr.to(edge_coarse.dtype)], dim=1))

        # ---- detection (matching branch) ----
        queries_det = self.det_dropout(queries)
        boxes, logits, iou = self._det_heads(queries_det)

        out = {
            "pred_hr": pred_hr, "pred_hr_mid": pred_hr_mid, "pred_masks": pred_masks, "pred_cls": pred_cls,
            "pred_edges": pred_edges, "pred_det_boxes": boxes, "pred_det_logits": logits, "pred_det_iou": iou,
            "queries": queries,
        }
        if use_dn:
            n_match = Q
            dn_queries = queries_all[:, n_match:]
            dn_boxes_pred, dn_logits_pred, dn_iou_pred = self._det_heads(dn_queries)
            out["dn_pred_boxes"] = dn_boxes_pred
            out["dn_pred_logits"] = dn_logits_pred
            out["dn_pred_iou"] = dn_iou_pred
        if self.training:
            out["pred_masks_aux"] = F.interpolate(self.aux_seg_head(ms[1]), size=size, mode="bilinear",
                                                  align_corners=False)
            aux = []
            for q in q_layers[:-1]:
                b_, l_, i_ = self._det_heads(q[:, :Q])
                aux.append({"boxes": b_, "logits": l_, "iou": i_})
            out["aux_det"] = aux
        return out


# ============================================================================
# 5. IoU-CONSISTENT CURRICULUM DENOISING (ICCD) -- ground-truth noising utility
# ============================================================================
def build_dn_batch(gt_boxes: List[torch.Tensor], gt_labels: List[torch.Tensor], cfg: OmniMorphConfig,
                    noise_scale: float, device) -> Optional[Dict[str, torch.Tensor]]:
    """Builds one padded batch of noised decoder queries (+ their clean reconstruction targets) from the ragged
    per-image ground truth. `noise_scale` is annealed coarse -> fine over training by the caller (Trainer), which
    is the "curriculum" half of ICCD; the IoU-consistency target (`target_iou`, the true IoU between each noised
    box and its clean source box) is the half that is not present in DN-DETR, which only reconstructs box/label."""
    B = len(gt_boxes)
    M = cfg.dn_max_gt_per_image
    noised_boxes = torch.zeros(B, M, 4, device=device)
    noised_labels = torch.full((B, M), cfg.num_classes, dtype=torch.long, device=device)
    valid = torch.zeros(B, M, dtype=torch.bool, device=device)
    target_boxes_xyxy = torch.zeros(B, M, 4, device=device)
    target_labels = torch.full((B, M), cfg.num_classes, dtype=torch.long, device=device)
    target_iou = torch.zeros(B, M, device=device)
    any_valid = False
    for i in range(B):
        boxes = gt_boxes[i]
        labels = gt_labels[i]
        n_total = int(boxes.shape[0])
        if n_total == 0:
            continue
        n = min(n_total, M)
        any_valid = True
        if n_total > M:
            idx = torch.randperm(n_total, device=device)[:n]
        else:
            idx = torch.arange(n_total, device=device)
        b = boxes[idx].to(device)             # xyxy, normalised
        l = labels[idx].to(device)
        cx = (b[:, 0] + b[:, 2]) / 2
        cy = (b[:, 1] + b[:, 3]) / 2
        w = (b[:, 2] - b[:, 0]).clamp(min=1e-4)
        h = (b[:, 3] - b[:, 1]).clamp(min=1e-4)
        cxcywh = torch.stack([cx, cy, w, h], dim=-1)
        shift = (torch.rand(n, 2, device=device) * 2 - 1) * noise_scale * torch.stack([w, h], dim=-1)
        scale_jit = 1.0 + (torch.rand(n, 2, device=device) * 2 - 1) * noise_scale
        noisy_cxcywh = cxcywh.clone()
        noisy_cxcywh[:, :2] = (cxcywh[:, :2] + shift).clamp(0.0, 1.0)
        noisy_cxcywh[:, 2:] = (cxcywh[:, 2:] * scale_jit).clamp(0.01, 1.0)
        noisy_xyxy = _cxcywh_to_boxes(noisy_cxcywh)
        noisy_l = l.clone()
        flip_mask = torch.rand(n, device=device) < cfg.dn_label_noise_prob
        if flip_mask.any() and cfg.num_classes > 1:
            rand_l = torch.randint(0, cfg.num_classes, (n,), device=device)
            noisy_l = torch.where(flip_mask, rand_l, noisy_l)
        _, iou_ni = paired_box_giou(noisy_xyxy, b)
        noised_boxes[i, :n] = noisy_cxcywh
        noised_labels[i, :n] = noisy_l
        valid[i, :n] = True
        target_boxes_xyxy[i, :n] = b
        target_labels[i, :n] = l
        target_iou[i, :n] = iou_ni.clamp(0.0, 1.0)
    if not any_valid:
        return None
    return {"noised_boxes": noised_boxes, "noised_labels": noised_labels, "valid": valid,
            "target_boxes_xyxy": target_boxes_xyxy, "target_labels": target_labels, "target_iou": target_iou}


# ============================================================================
# 6. LOSS FUNCTIONS
# ============================================================================
class MultiTaskLoss(nn.Module):
    def __init__(self, config: OmniMorphConfig):
        super().__init__()
        self.cfg = config
        seg_w = torch.ones(config.num_mask_classes)
        seg_w[0] = config.seg_bg_weight
        det_w = torch.ones(config.num_classes + 1)
        det_w[-1] = config.bg_class_weight
        self.register_buffer("seg_class_weights", seg_w, persistent=False)
        self.register_buffer("det_class_weights", det_w, persistent=False)
        self.register_buffer("edge_pos_weight", torch.tensor([config.edge_pos_weight]), persistent=False)
        self.register_buffer("ssim_window", self._gaussian_window(config.ssim_kernel, config.ssim_sigma,
                                                                  config.in_channels), persistent=False)
        self.register_buffer("pyramid_kernel", self._gaussian_pyramid_kernel(config.in_channels), persistent=False)
        self.bce_loss = nn.BCEWithLogitsLoss()
        self.task_health: Dict[str, float] = {}     # updated once per epoch by the Trainer (ATHM, section 7)

    # ---- Adaptive Task-Health Modulation (loss-weight side; see OmniMorphNet.set_task_health for the other) ----
    def set_task_health(self, health: Dict[str, float]) -> None:
        self.task_health = dict(health)

    def _eff_lambda(self, task: str, base: float) -> float:
        return base * self.task_health.get(task, 1.0)

    # ---- image reconstruction ----
    @staticmethod
    def _gaussian_window(k: int, sigma: float, channels: int) -> torch.Tensor:
        coords = torch.arange(k, dtype=torch.float32) - (k - 1) / 2.0
        g = torch.exp(-(coords ** 2) / (2 * sigma ** 2))
        g = g / g.sum()
        return (g[:, None] * g[None, :]).expand(channels, 1, k, k).contiguous()

    @staticmethod
    def _gaussian_pyramid_kernel(channels: int) -> torch.Tensor:
        """Classic 5-tap binomial [1,4,6,4,1]/16 Gaussian kernel (Burt & Adelson). Chosen over a wavelet transform
        so the Laplacian-pyramid fidelity loss below needs zero extra dependencies."""
        k1d = torch.tensor([1.0, 4.0, 6.0, 4.0, 1.0])
        k1d = k1d / k1d.sum()
        k2d = k1d[:, None] * k1d[None, :]
        return k2d.expand(channels, 1, 5, 5).contiguous()

    def ssim_map(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        """Per-pixel SSIM map with a Gaussian window and reflect padding (unreduced, so it can be masked)."""
        k, ch = self.cfg.ssim_kernel, x.shape[1]
        pad = k // 2
        w = self.ssim_window.to(dtype=x.dtype, device=x.device)

        def filt(t):
            return F.conv2d(F.pad(t, (pad, pad, pad, pad), mode="reflect"), w, groups=ch)

        mu_x, mu_y = filt(x), filt(y)
        sxx = filt(x * x) - mu_x ** 2
        syy = filt(y * y) - mu_y ** 2
        sxy = filt(x * y) - mu_x * mu_y
        return ((2 * mu_x * mu_y + self.cfg.ssim_c1) * (2 * sxy + self.cfg.ssim_c2)) / (
            (mu_x ** 2 + mu_y ** 2 + self.cfg.ssim_c1) * (sxx + syy + self.cfg.ssim_c2) + self.cfg.eps)

    def masked_ssim(self, x: torch.Tensor, y: torch.Tensor, valid_mask: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        smap = self.ssim_map(x, y)
        vm = valid_mask.expand_as(smap)
        denom = vm.sum().clamp(min=1.0)
        ssim_val = (smap * vm).sum() / denom
        return 1.0 - ssim_val, ssim_val

    def masked_charbonnier(self, pred: torch.Tensor, target: torch.Tensor, valid_mask: torch.Tensor) -> torch.Tensor:
        """Charbonnier (smooth-L1-like, more robust than plain L1) pixel loss, masked to the letterbox's valid
        (non-padded) region so the network is never rewarded/penalised for repainting the grey padding border."""
        eps2 = self.cfg.charbonnier_eps ** 2
        loss_map = torch.sqrt((pred - target) ** 2 + eps2)
        vm = valid_mask.expand_as(loss_map)
        return (loss_map * vm).sum() / vm.sum().clamp(min=1.0)

    def _gauss_blur_down(self, x: torch.Tensor) -> torch.Tensor:
        C = x.shape[1]
        kernel = self.pyramid_kernel.to(dtype=x.dtype, device=x.device)
        xp = F.pad(x, (2, 2, 2, 2), mode="reflect")
        blurred = F.conv2d(xp, kernel, groups=C)
        return blurred[:, :, ::2, ::2]

    def laplacian_pyramid_loss(self, pred: torch.Tensor, target: torch.Tensor, valid_mask: torch.Tensor,
                                levels: int) -> torch.Tensor:
        """Laplacian-pyramid fidelity loss: an auxiliary loss (not an architecture, unlike LapSRN) that compares
        pred/target at each pyramid octave's *residual* (band-pass) detail, weighted towards the finer octaves.
        Lineage: inspired by wavelet/frequency-domain SR losses (subband-weighted fidelity terms), reimplemented
        with a plain Gaussian/Laplacian pyramid (Burt & Adelson) so it needs no extra dependency (no `pywt`) and
        stays cheap enough for a single GPU."""
        p, t, vm = pred, target, valid_mask
        total, weight_sum = pred.new_zeros(()), 0.0
        for lvl in range(levels):
            p_down = self._gauss_blur_down(p)
            t_down = self._gauss_blur_down(t)
            p_up = F.interpolate(p_down, size=p.shape[-2:], mode="bilinear", align_corners=False)
            t_up = F.interpolate(t_down, size=t.shape[-2:], mode="bilinear", align_corners=False)
            lap_diff = (p - p_up) - (t - t_up)
            w = float(levels - lvl)                      # finer (earlier) octaves weighted more heavily
            vm_here = vm.expand(-1, lap_diff.shape[1], -1, -1)
            loss_l = (lap_diff.abs() * vm_here).sum() / vm_here.sum().clamp(min=1.0)
            total = total + w * loss_l
            weight_sum += w
            if p_down.shape[-1] < 6 or p_down.shape[-2] < 6:
                break
            p, t = p_down, t_down
            vm = F.interpolate(vm, size=p_down.shape[-2:], mode="nearest")
        return total / max(weight_sum, 1e-8)

    # ---- segmentation ----
    def dice_loss(self, logits: torch.Tensor, target_mask: torch.Tensor) -> torch.Tensor:
        """Batch-level soft dice averaged over the classes PRESENT in the batch (absent classes are excluded so
        they cannot push every pixel towards background)."""
        C = self.cfg.num_mask_classes
        probs = F.softmax(logits, dim=1)
        valid = (target_mask != self.cfg.ignore_index)
        tgt = torch.clamp(target_mask, 0, C - 1)
        one_hot = F.one_hot(tgt, num_classes=C).permute(0, 3, 1, 2).float()
        valid_f = valid.unsqueeze(1).float()
        probs, one_hot = probs * valid_f, one_hot * valid_f
        inter = (probs * one_hot).sum(dim=(0, 2, 3))
        card = probs.sum(dim=(0, 2, 3)) + one_hot.sum(dim=(0, 2, 3))
        dice = (2.0 * inter + self.cfg.dice_smooth) / (card + self.cfg.dice_smooth)
        present = one_hot.sum(dim=(0, 2, 3)) > 0
        if not present.any():
            return logits.sum() * 0.0
        return (1.0 - dice[present]).mean()

    # ---- edges ----
    def edge_dice_loss(self, pred_logits: torch.Tensor, target: torch.Tensor, valid: torch.Tensor) -> torch.Tensor:
        prob = torch.sigmoid(pred_logits) * valid
        tgt = target * valid
        inter = (prob * tgt).sum()
        card = prob.sum() + tgt.sum()
        return 1.0 - (2.0 * inter + self.cfg.dice_smooth) / (card + self.cfg.dice_smooth)

    # ---- detection (bipartite matching branch) ----
    @torch.no_grad()
    def match(self, pred_boxes, pred_logits, gt_boxes, gt_labels):
        B = pred_boxes.shape[0]
        empty = torch.empty(0, dtype=torch.int64, device=pred_boxes.device)
        indices = []
        for i in range(B):
            if len(gt_boxes[i]) == 0:
                indices.append((empty, empty))
                continue
            out_prob = pred_logits[i].softmax(-1)
            out_bbox = pred_boxes[i]
            tgt_bbox, tgt_ids = gt_boxes[i], gt_labels[i]
            cost_class = -out_prob[:, tgt_ids]
            cost_bbox = torch.cdist(out_bbox, tgt_bbox, p=1)
            cost_giou = -generalized_box_iou(out_bbox, tgt_bbox)
            C = self.cfg.lambda_bbox * cost_bbox + self.cfg.lambda_giou * cost_giou + cost_class
            C = torch.nan_to_num(C, nan=1e6, posinf=1e6, neginf=-1e6)
            src_ind, tgt_ind = linear_sum_assignment(C.cpu().numpy())
            indices.append((torch.as_tensor(src_ind, dtype=torch.int64, device=pred_boxes.device),
                            torch.as_tensor(tgt_ind, dtype=torch.int64, device=pred_boxes.device)))
        return indices

    @staticmethod
    def _focal_ce(logits: torch.Tensor, targets: torch.Tensor, weight: Optional[torch.Tensor],
                   gamma: float) -> torch.Tensor:
        """Focal cross-entropy (Lin et al., ICCV'17), adopted for the DETR-style query classification head the
        way Deformable DETR / DINO-DETR use it (Zhu et al., ICLR'21; Zhang et al., CVPR'22): with only a handful
        of real objects among `num_queries` slots per VOC image, plain weighted CE lets the many easy,
        correctly-classified "no-object" queries dominate the gradient -- consistent with the near-zero
        prediction confidences (0.04-0.13) visible on every predicted box across the qualitative detection
        panels. The (1-p_t)^gamma term down-weights those easy queries so gradient mass concentrates on the few
        still-uncertain ones, without needing `bg_class_weight` re-tuned against the query count to get the same
        effect. `weight` still applies its per-class (mainly background-vs-object) scale on top, exactly as the
        plain-CE path did, so this is a strict refinement, not a different weighting philosophy."""
        nll = F.cross_entropy(logits, targets, reduction="none")
        p_t = torch.exp(-nll.clamp(max=20.0))
        w = weight[targets] if weight is not None else torch.ones_like(nll)
        focal = w * (1.0 - p_t).pow(gamma) * nll
        return focal.sum() / w.sum().clamp(min=1e-6)

    def get_det_loss(self, pred_boxes, pred_logits, pred_iou, gt_boxes, gt_labels, num_boxes):
        cfg = self.cfg
        indices = self.match(pred_boxes, pred_logits, gt_boxes, gt_labels)
        B, Q, C = pred_logits.shape
        target_classes = torch.full((B, Q), cfg.num_classes, dtype=torch.long, device=pred_logits.device)
        b_idx, s_idx, src_boxes, tgt_boxes = [], [], [], []
        for i, (src, tgt) in enumerate(indices):
            if len(src) == 0:
                continue
            target_classes[i, src] = gt_labels[i][tgt]
            b_idx.append(torch.full_like(src, i))
            s_idx.append(src)
            src_boxes.append(pred_boxes[i, src])
            tgt_boxes.append(gt_boxes[i][tgt])
        if cfg.use_focal_det_cls:
            loss_ce = self._focal_ce(pred_logits.reshape(-1, C), target_classes.reshape(-1),
                                      self.det_class_weights, cfg.focal_gamma)
        else:
            loss_ce = F.cross_entropy(pred_logits.transpose(1, 2), target_classes, weight=self.det_class_weights)
        iou_target = torch.zeros_like(pred_iou)
        loss_bbox = pred_boxes.sum() * 0.0
        loss_giou = pred_boxes.sum() * 0.0
        if src_boxes:
            sb, tb = torch.cat(src_boxes), torch.cat(tgt_boxes)
            giou, iou = paired_box_giou(sb, tb)
            loss_bbox = F.l1_loss(sb, tb, reduction="sum") / num_boxes
            loss_giou = (1.0 - giou).sum() / num_boxes
            iou_target[torch.cat(b_idx), torch.cat(s_idx)] = iou.detach()
        loss_iou = F.binary_cross_entropy_with_logits(pred_iou, iou_target) * cfg.lambda_iou_branch
        return loss_ce, loss_bbox, loss_giou, loss_iou

    def _weighted_det(self, parts):
        ce, bbox, giou, iou = parts
        c = self.cfg
        return c.lambda_det_ce * ce + c.lambda_bbox * bbox + c.lambda_giou * giou + iou

    # ---- ICCD: denoising queries, supervised directly (no Hungarian matching -- correspondence is by
    #      construction) with box/label reconstruction AND an IoU-consistency term against the exact IoU
    #      between each noised box and its clean source box ----
    def get_dn_loss(self, dn_pred_boxes, dn_pred_logits, dn_pred_iou, dn_batch):
        cfg = self.cfg
        valid = dn_batch["valid"]
        valid_f = valid.float()
        n_valid = valid_f.sum().clamp(min=1.0)
        logits_flat = dn_pred_logits.reshape(-1, dn_pred_logits.shape[-1])
        labels_flat = dn_batch["target_labels"].reshape(-1)
        flat_valid = valid.reshape(-1)
        if cfg.use_focal_det_cls:
            loss_cls = (self._focal_ce(logits_flat[flat_valid], labels_flat[flat_valid], self.det_class_weights,
                                        cfg.focal_gamma) if flat_valid.any() else logits_flat.sum() * 0.0)
        else:
            ce_per = F.cross_entropy(logits_flat, labels_flat, weight=self.det_class_weights, reduction="none")
            loss_cls = (ce_per.view_as(valid_f) * valid_f).sum() / n_valid
        pred_boxes_flat = dn_pred_boxes.reshape(-1, 4)[flat_valid]
        tgt_boxes_flat = dn_batch["target_boxes_xyxy"].reshape(-1, 4)[flat_valid]
        if pred_boxes_flat.numel() > 0:
            giou, iou = paired_box_giou(pred_boxes_flat, tgt_boxes_flat)
            loss_bbox = F.l1_loss(pred_boxes_flat, tgt_boxes_flat, reduction="sum") / n_valid
            loss_giou = (1.0 - giou).sum() / n_valid
        else:
            loss_bbox = dn_pred_boxes.sum() * 0.0
            loss_giou = dn_pred_boxes.sum() * 0.0
        iou_target_flat = dn_batch["target_iou"].reshape(-1)[flat_valid]
        iou_pred_flat = dn_pred_iou.reshape(-1)[flat_valid]
        if iou_pred_flat.numel() > 0:
            loss_iou_consistency = F.binary_cross_entropy_with_logits(iou_pred_flat, iou_target_flat.clamp(0, 1))
        else:
            loss_iou_consistency = dn_pred_iou.sum() * 0.0
        loss_dn = (cfg.lambda_dn_cls * loss_cls + cfg.lambda_dn_bbox * loss_bbox
                   + cfg.lambda_dn_giou * loss_giou + cfg.lambda_dn_iou_consistency * loss_iou_consistency)
        return loss_dn, loss_cls, loss_bbox, loss_giou, loss_iou_consistency

    def forward(self, predictions: Dict[str, torch.Tensor], targets: Dict[str, torch.Tensor],
                dn_batch: Optional[Dict[str, torch.Tensor]] = None):
        cfg = self.cfg
        valid_mask = targets.get("valid_mask")
        if valid_mask is None:
            valid_mask = torch.ones_like(predictions["pred_hr"][:, :1])

        # ---- super-resolution (masked to the letterbox's real, non-padded pixels) ----
        pred_hr = predictions["pred_hr"].float()
        l1_val = self.masked_charbonnier(pred_hr, targets["hr_image"], valid_mask)
        ssim_loss_val, ssim_val = self.masked_ssim(pred_hr, targets["hr_image"], valid_mask)
        pyramid_val = self.laplacian_pyramid_loss(pred_hr, targets["hr_image"], valid_mask, cfg.pyramid_levels)
        loss_rec = l1_val + cfg.lambda_ssim * ssim_loss_val + cfg.lambda_pyramid * pyramid_val
        loss_mid = pred_hr.sum() * 0.0
        if "pred_hr_mid" in predictions:
            pred_mid = predictions["pred_hr_mid"].float()
            target_mid = F.interpolate(targets["hr_image"], size=pred_mid.shape[-2:], mode="bicubic",
                                       align_corners=False, antialias=True).clamp(0.0, 1.0)
            valid_mid = F.interpolate(valid_mask, size=pred_mid.shape[-2:], mode="nearest")
            loss_mid = self.masked_charbonnier(pred_mid, target_mid, valid_mid)
            loss_rec = loss_rec + cfg.lambda_mid_sr * loss_mid

        # ---- segmentation ----
        pred_masks = predictions["pred_masks"].float()
        target_mask = targets["mask"].squeeze(1).long()
        loss_mask_ce = F.cross_entropy(pred_masks, target_mask, weight=self.seg_class_weights,
                                       ignore_index=cfg.ignore_index, label_smoothing=cfg.label_smoothing_seg)
        loss_mask_dice = self.dice_loss(pred_masks, target_mask)
        loss_seg = loss_mask_ce * cfg.lambda_mask_ce + loss_mask_dice * cfg.lambda_mask_dice
        if "pred_masks_aux" in predictions:
            aux_ce = F.cross_entropy(predictions["pred_masks_aux"].float(), target_mask,
                                     weight=self.seg_class_weights, ignore_index=cfg.ignore_index,
                                     label_smoothing=cfg.label_smoothing_seg)
            loss_seg = loss_seg + cfg.lambda_aux_seg * cfg.lambda_mask_ce * aux_ce

        # ---- classification (label-smoothed multi-label BCE) ----
        eps_c = cfg.label_smoothing_cls
        smoothed_label = targets["label"].float() * (1.0 - eps_c) + 0.5 * eps_c
        loss_cls = self.bce_loss(predictions["pred_cls"].float(), smoothed_label) * cfg.lambda_cls

        # ---- edges (ignore-aware) ----
        pred_edges = predictions["pred_edges"].float()
        target_edges = targets["edge_mask"]
        valid_e = (target_edges != cfg.ignore_index).float()
        target_bin = (target_edges > 0.5).float() * valid_e
        bce_raw = F.binary_cross_entropy_with_logits(pred_edges, target_bin, reduction="none",
                                                     pos_weight=self.edge_pos_weight)
        loss_edge_bce = (bce_raw * valid_e).sum() / valid_e.sum().clamp(min=1.0)
        loss_edge_dice = self.edge_dice_loss(pred_edges, target_bin, valid_e)
        loss_edge = (loss_edge_bce + cfg.lambda_edge_dice * loss_edge_dice) * cfg.lambda_edge

        # ---- detection (+ deep supervision of intermediate decoder layers) ----
        gt_boxes, gt_labels = targets["boxes"], targets["box_labels"]
        num_boxes = float(max(sum(len(b) for b in gt_boxes), 1))
        main_parts = self.get_det_loss(predictions["pred_det_boxes"].float(), predictions["pred_det_logits"].float(),
                                       predictions["pred_det_iou"].float(), gt_boxes, gt_labels, num_boxes)
        loss_det = self._weighted_det(main_parts)
        for aux in predictions.get("aux_det", []):
            parts = self.get_det_loss(aux["boxes"].float(), aux["logits"].float(), aux["iou"].float(),
                                      gt_boxes, gt_labels, num_boxes)
            loss_det = loss_det + cfg.lambda_aux_det * self._weighted_det(parts)
        loss_det_ce, loss_bbox, loss_giou, loss_iou = main_parts

        # ---- ICCD denoising (training-only auxiliary; NOT health-modulated -- see forward's docstring note) ----
        loss_dn = pred_hr.sum() * 0.0
        loss_dn_cls = loss_dn_bbox = loss_dn_giou = loss_dn_iouc = pred_hr.sum() * 0.0
        if dn_batch is not None and "dn_pred_boxes" in predictions:
            loss_dn, loss_dn_cls, loss_dn_bbox, loss_dn_giou, loss_dn_iouc = self.get_dn_loss(
                predictions["dn_pred_boxes"].float(), predictions["dn_pred_logits"].float(),
                predictions["dn_pred_iou"].float(), dn_batch)

        # ATHM: down-weight (never below `athm_health_floor`) whichever task's own validation metric has stopped
        # improving; ICCD's denoising loss is deliberately excluded -- it exists specifically to fix detection's
        # collapse, so damping it exactly when detection looks unhealthy would be self-defeating.
        total_loss = (self._eff_lambda("rec", cfg.lambda_rec) * loss_rec
                      + self._eff_lambda("seg", 1.0) * loss_seg
                      + loss_cls
                      + self._eff_lambda("edge", 1.0) * loss_edge
                      + self._eff_lambda("det", 1.0) * loss_det
                      + loss_dn)

        d = lambda t: t.detach()
        return total_loss, {
            "loss_total": d(total_loss), "loss_rec": d(loss_rec), "loss_l1": d(l1_val), "loss_ssim": d(ssim_loss_val),
            "loss_pyramid": d(pyramid_val), "loss_mid_sr": d(loss_mid),
            "loss_seg_ce": d(loss_mask_ce), "loss_seg_dice": d(loss_mask_dice), "loss_cls": d(loss_cls),
            "loss_edge": d(loss_edge), "loss_det": d(loss_det), "loss_det_ce": d(loss_det_ce),
            "loss_bbox": d(loss_bbox), "loss_giou": d(loss_giou), "loss_iou_branch": d(loss_iou),
            "loss_dn": d(loss_dn), "loss_dn_cls": d(loss_dn_cls), "loss_dn_bbox": d(loss_dn_bbox),
            "loss_dn_giou": d(loss_dn_giou), "loss_dn_iou_consistency": d(loss_dn_iouc),
        }


# ============================================================================
# 7. PASCAL VOC 2012 DATASET
# ============================================================================
class PascalVOC2012MultiTaskDataset(Dataset):
    """Every sample is built through one shared letterbox canvas (aspect-ratio preserving resize + centred pad,
    see `compute_letterbox_params`/`letterbox_boxes` in section 2) instead of v1/v2's squash-resize, so object
    proportions are never distorted and every prediction can be mapped back onto the original photo exactly
    (`meta['lb']`, consumed by the inferencer in section 9). Cross-Task Consistent Region Mixing (CTCRM, see
    `_apply_ctcrm`) is applied after that canonical per-sample loading step, train-only.

    Which images this actually trains on: the official VOC2012 trainval package has 17,125 images total
    (JPEGImages/Annotations), but only the 1,464 + 1,449 = 2,913 of them listed in
    ImageSets/Segmentation/{train,val}.txt have a pixel-level SegmentationClass/SegmentationObject mask -- and
    every task here needs one, so `root` is read strictly from that split, never from the larger
    ImageSets/Main split or from JPEGImages directly (see `VOC2012_OFFICIAL_COUNTS`, `resolve_voc2012_root` and
    `describe_voc2012_root` in section 2 for how `root` is located and cross-checked against those numbers).
    """
    def __init__(self, root: str, split: str, config: OmniMorphConfig, augment: bool = False,
                 _resolved: bool = False):
        if split not in ("train", "val", "test"):
            raise ValueError(f"unknown split '{split}'")
        self.cfg = config
        self.split, self.augment = split, augment
        # `_resolved=True` (used by main(), which resolves once and shares the result across train/val/test so
        # the search and the on-disk accounting print only once) skips re-running the search; constructing this
        # class directly still self-corrects `root`, so nothing upstream can silently train on the wrong folder.
        self.root = root if _resolved else resolve_voc2012_root(root)
        if self.root != root:
            print(f"[*] dataset_root '{root}' -> resolved VOC2012 directory '{self.root}'")
        root = self.root
        self.img_dir = os.path.join(root, "JPEGImages")
        self.mask_dir = os.path.join(root, "SegmentationClass")
        self.obj_dir = os.path.join(root, "SegmentationObject")
        self.ann_dir = os.path.join(root, "Annotations")
        self.split_dir = os.path.join(root, "ImageSets", "Segmentation")
        self.class_to_idx = {cls_name: i for i, cls_name in enumerate(config.voc_classes)}
        self.color_jitter = T.ColorJitter(brightness=config.aug_color_jitter, contrast=config.aug_color_jitter,
                                          saturation=config.aug_color_jitter, hue=0.0)
        fv = int(round(255 * config.letterbox_fill))
        self.fill_rgb = (fv, fv, fv)
        off = VOC2012_OFFICIAL_COUNTS
        try:
            if split == "train":
                self.image_ids = self._read_ids("train.txt")
                self._warn_if_off_official(len(self.image_ids), off["segmentation_train"], "train")
            elif not config.separate_test_split:
                self.image_ids = self._read_ids("val.txt")     # legacy behaviour: test == val (leaky)
                self._warn_if_off_official(len(self.image_ids), off["segmentation_val"], "val")
            else:
                all_val = self._read_ids("val.txt")
                self._warn_if_off_official(len(all_val), off["segmentation_val"], "val (pre train/test split)")
                shuffled = all_val[:]
                random.Random(config.seed).shuffle(shuffled)
                n_val = int(round(len(shuffled) * config.val_fraction))
                self.image_ids = sorted(shuffled[:n_val]) if split == "val" else sorted(shuffled[n_val:])
        except (FileNotFoundError, OSError) as e:
            print(f"[*] Dataset split not found: {e}. Ensure VOC2012 is extracted correctly.")
            self.image_ids = []
            return
        # a listed id with no matching JPEGImages file (partial/corrupted download) is dropped here, with a
        # count printed, rather than crashing deep inside a DataLoader worker at some later, random epoch.
        missing = [i for i in self.image_ids if not os.path.isfile(os.path.join(self.img_dir, f"{i}.jpg"))]
        if missing:
            print(f"[!] {len(missing)} image id(s) in the '{split}' split have no matching JPEGImages/*.jpg "
                  f"file and were dropped (e.g. {missing[:3]}).")
            self.image_ids = [i for i in self.image_ids if i not in set(missing)]

    @staticmethod
    def _warn_if_off_official(n: int, expected: int, label: str) -> None:
        if expected > 0 and abs(n - expected) > max(30, int(expected * 0.05)):
            print(f"[!] WARNING: '{label}' split resolved to {n} images; the official VOC2012 Segmentation "
                  f"'{label}' split has {expected}. This dataset's images-used total should never approach the "
                  f"full ~17.1k-image trainval package -- if it does, `dataset_root` is pointing at the wrong "
                  f"directory (see describe_voc2012_root()).")

    def _read_ids(self, name: str) -> List[str]:
        with open(os.path.join(self.split_dir, name), "r") as f:
            return sorted({line.strip().split()[0] for line in f if line.strip()})

    def __len__(self) -> int:
        return len(self.image_ids)

    # ---- edge target -----------------------------------------------------------------------------------
    @staticmethod
    def _compute_edge_map(obj_np: np.ndarray, ignore_index: int) -> np.ndarray:
        """Instance-boundary map from SegmentationObject. VOC marks the boundary band between an object and its
        surroundings with the 'void' label (255): void pixels are first filled with the nearest labelled pixel;
        an edge is then a pixel whose 4-neighbourhood contains a different (filled) instance id."""
        obj = obj_np.astype(np.int32)
        void = obj == ignore_index
        if void.all():
            return np.full(obj.shape, float(ignore_index), dtype=np.float32)
        if void.any():
            idx = ndimage.distance_transform_edt(void, return_distances=False, return_indices=True)
            obj = obj[idx[0], idx[1]]
        p = np.pad(obj, 1, mode="edge")
        c = p[1:-1, 1:-1]
        edge = (c != p[:-2, 1:-1]) | (c != p[2:, 1:-1]) | (c != p[1:-1, :-2]) | (c != p[1:-1, 2:])
        return edge.astype(np.float32)

    # ---- annotations -------------------------------------------------------------------------------------
    def _parse_annotation(self, xml_path: str, W: int, H: int):
        boxes, labels, diffs = [], [], []
        if os.path.exists(xml_path):
            root = ET.parse(xml_path).getroot()
            for obj in root.findall("object"):
                name = obj.find("name").text.lower().strip()
                if name not in self.class_to_idx:
                    continue
                bb = obj.find("bndbox")
                # VOC boxes are 1-based inclusive pixel indices -> [xmin-1, xmax) in continuous coordinates
                x1 = float(np.clip((float(bb.find("xmin").text) - 1.0) / W, 0.0, 1.0))
                y1 = float(np.clip((float(bb.find("ymin").text) - 1.0) / H, 0.0, 1.0))
                x2 = float(np.clip(float(bb.find("xmax").text) / W, 0.0, 1.0))
                y2 = float(np.clip(float(bb.find("ymax").text) / H, 0.0, 1.0))
                if x2 - x1 <= 1e-4 or y2 - y1 <= 1e-4:
                    continue
                d = obj.find("difficult")
                boxes.append([x1, y1, x2, y2])
                labels.append(self.class_to_idx[name])
                diffs.append(bool(int(d.text)) if d is not None and d.text is not None else False)
        return (np.asarray(boxes, dtype=np.float32).reshape(-1, 4),
                np.asarray(labels, dtype=np.int64), np.asarray(diffs, dtype=bool))

    # ---- augmentation --------------------------------------------------------------------------------------
    def _sample_crop(self, W: int, H: int) -> Tuple[int, int, int, int]:
        cfg = self.cfg
        if random.random() < cfg.aug_crop_prob:
            for _ in range(10):
                area = W * H * random.uniform(cfg.aug_crop_min_scale, 1.0)
                ar = math.exp(random.uniform(math.log(3.0 / 4.0), math.log(4.0 / 3.0)))
                w = int(round(math.sqrt(area * ar)))
                h = int(round(math.sqrt(area / ar)))
                if 0 < w <= W and 0 < h <= H:
                    left = random.randint(0, W - w)
                    top = random.randint(0, H - h)
                    return left, top, left + w, top + h
        return 0, 0, W, H

    def _crop_annotations(self, boxes, labels, diffs, crop, W, H):
        left, top, right, bottom = crop
        cw, ch = float(right - left), float(bottom - top)
        if len(boxes) == 0:
            return boxes, labels, diffs
        px = boxes * np.array([W, H, W, H], dtype=np.float32)
        orig_area = (px[:, 2] - px[:, 0]) * (px[:, 3] - px[:, 1])
        nb = px.copy()
        nb[:, [0, 2]] = np.clip(nb[:, [0, 2]] - left, 0.0, cw)
        nb[:, [1, 3]] = np.clip(nb[:, [1, 3]] - top, 0.0, ch)
        new_w, new_h = nb[:, 2] - nb[:, 0], nb[:, 3] - nb[:, 1]
        keep = (new_w * new_h >= self.cfg.aug_min_box_visibility * np.maximum(orig_area, 1e-6)) \
            & (new_w >= 2.0) & (new_h >= 2.0)
        nb = (nb / np.array([cw, ch, cw, ch], dtype=np.float32)).astype(np.float32)
        return nb[keep], labels[keep], diffs[keep]

    # ---- letterboxed canvas builders (image / mask / edge / valid-pixel-mask) --------------------------------
    def _build_letterboxed_image(self, img_crop_pil: Image.Image, lb: Dict[str, Any]) -> Image.Image:
        S = lb["size"]
        resized = img_crop_pil.resize((lb["new_w"], lb["new_h"]), BICUBIC)
        canvas = Image.new("RGB", (S, S), self.fill_rgb)
        canvas.paste(resized, (lb["pad_left"], lb["pad_top"]))
        return canvas

    def _build_letterboxed_mask(self, mask_crop_arr: np.ndarray, lb: Dict[str, Any]) -> np.ndarray:
        S = lb["size"]
        # NOTE: no mode= kwarg -- Pillow's fromarray() already infers "L" from a 2D uint8 array on its own, and
        # passing mode= explicitly is deprecated (removed in Pillow 13, 2026-10-15) since it let the caller assert
        # a mode inconsistent with the array's own dtype/shape; letting it infer is both future-proof and exact.
        m_img = Image.fromarray(mask_crop_arr.astype(np.uint8))
        m_resized = np.array(m_img.resize((lb["new_w"], lb["new_h"]), NEAREST), dtype=np.int64)
        canvas = np.full((S, S), self.cfg.ignore_index, dtype=np.int64)
        canvas[lb["pad_top"]:lb["pad_top"] + lb["new_h"], lb["pad_left"]:lb["pad_left"] + lb["new_w"]] = m_resized
        return canvas

    def _build_letterboxed_edge(self, obj_crop_arr: np.ndarray, lb: Dict[str, Any]) -> np.ndarray:
        """Edges are computed on the native-resolution crop FIRST (so thin 1px boundaries are not lost to a
        downstream nearest-neighbour resize) and only the finished edge map is letterboxed. The valid region is
        additionally eroded by 1px so no artificial 'edge' can appear exactly at the letterbox seam between real
        content and the padded border."""
        S = lb["size"]
        edge_native = self._compute_edge_map(obj_crop_arr, self.cfg.ignore_index)
        # edge_native is always a 2D float32 array (see _compute_edge_map) -> fromarray() infers "F" on its own.
        e_img = Image.fromarray(edge_native)
        e_resized = np.array(e_img.resize((lb["new_w"], lb["new_h"]), NEAREST), dtype=np.float32)
        canvas = np.full((S, S), float(self.cfg.ignore_index), dtype=np.float32)
        canvas[lb["pad_top"]:lb["pad_top"] + lb["new_h"], lb["pad_left"]:lb["pad_left"] + lb["new_w"]] = e_resized
        pad_mask = np.ones((S, S), dtype=bool)
        pad_mask[lb["pad_top"]:lb["pad_top"] + lb["new_h"], lb["pad_left"]:lb["pad_left"] + lb["new_w"]] = False
        valid = ~pad_mask
        valid_eroded = ndimage.binary_erosion(valid, iterations=1, border_value=False)
        canvas = np.where(valid_eroded, canvas, float(self.cfg.ignore_index)).astype(np.float32)
        return canvas

    @staticmethod
    def _build_valid_mask(lb: Dict[str, Any]) -> np.ndarray:
        S = lb["size"]
        m = np.zeros((S, S), dtype=np.float32)
        m[lb["pad_top"]:lb["pad_top"] + lb["new_h"], lb["pad_left"]:lb["pad_left"] + lb["new_w"]] = 1.0
        return m

    # ---- one fully-preprocessed sample (crop -> letterbox -> flip), reused both as the primary sample and as
    #      CTCRM's second, mixed-in sample ----------------------------------------------------------------------
    def _load_one(self, idx: int) -> Dict[str, Any]:
        cfg = self.cfg
        S = cfg.hr_image_size
        img_id = self.image_ids[idx]
        img_path = os.path.join(self.img_dir, f"{img_id}.jpg")
        mask_path = os.path.join(self.mask_dir, f"{img_id}.png")
        obj_path = os.path.join(self.obj_dir, f"{img_id}.png")
        xml_path = os.path.join(self.ann_dir, f"{img_id}.xml")

        pil_img = Image.open(img_path).convert("RGB")
        W0, H0 = pil_img.size
        mask_pil = Image.open(mask_path) if os.path.exists(mask_path) else None
        obj_pil = Image.open(obj_path) if os.path.exists(obj_path) else None
        boxes, box_labels, difficult = self._parse_annotation(xml_path, W0, H0)

        crop = (0, 0, W0, H0)
        if self.augment:
            crop = self._sample_crop(W0, H0)
        left, top, right, bottom = crop
        cw, ch = right - left, bottom - top

        img_crop = pil_img.crop(crop)
        mask_crop = (np.array(mask_pil.crop(crop)) if mask_pil is not None
                     else np.full((ch, cw), cfg.ignore_index, dtype=np.uint8))
        obj_crop = (np.array(obj_pil.crop(crop)) if obj_pil is not None
                    else np.full((ch, cw), cfg.ignore_index, dtype=np.uint8))

        if self.augment:
            img_crop = self.color_jitter(img_crop)
            boxes, box_labels, difficult = self._crop_annotations(boxes, box_labels, difficult, crop, W0, H0)

        lb = compute_letterbox_params(cw, ch, S)
        hr_canvas = self._build_letterboxed_image(img_crop, lb)
        mask_canvas = self._build_letterboxed_mask(mask_crop, lb)
        edge_canvas = self._build_letterboxed_edge(obj_crop, lb)
        valid_canvas = self._build_valid_mask(lb)
        boxes_canvas = letterbox_boxes(boxes, cw, ch, lb) if len(boxes) else np.zeros((0, 4), dtype=np.float32)

        flip = self.augment and random.random() < cfg.aug_flip_prob
        if flip:
            hr_canvas = hr_canvas.transpose(FLIP_LR)
            mask_canvas = np.ascontiguousarray(mask_canvas[:, ::-1])
            edge_canvas = np.ascontiguousarray(edge_canvas[:, ::-1])
            valid_canvas = np.ascontiguousarray(valid_canvas[:, ::-1])
            if len(boxes_canvas):
                boxes_canvas = boxes_canvas.copy()
                boxes_canvas[:, [0, 2]] = 1.0 - boxes_canvas[:, [2, 0]]

        return {
            "hr_pil": hr_canvas, "mask": mask_canvas.astype(np.int64), "edge": edge_canvas.astype(np.float32),
            "valid": valid_canvas.astype(np.float32), "boxes": boxes_canvas.astype(np.float32),
            "labels": box_labels.astype(np.int64), "diff": difficult.astype(bool), "image_id": img_id,
            "meta": {"orig_w": W0, "orig_h": H0, "crop": crop, "lb": lb},
        }

    # ---- Cross-Task Consistent Region Mixing (CTCRM) ------------------------------------------------------
    @staticmethod
    def _filter_boxes_by_mask(boxes: np.ndarray, labels: np.ndarray, diff: np.ndarray, paste_mask: np.ndarray,
                               keep_outside: bool, S: int, visibility: float):
        """Approximate (bounding-box-level, not polygon-clipped) visibility filtering against an arbitrary binary
        paste region, using an integral image for O(1)-per-box coverage. `keep_outside=True` drops boxes that are
        mostly covered by the pasted region; `keep_outside=False` keeps boxes that mostly fall inside it."""
        if len(boxes) == 0:
            return boxes, labels, diff
        integral = np.pad(paste_mask.astype(np.float32).cumsum(0).cumsum(1), ((1, 0), (1, 0)))
        px = boxes * np.array([S, S, S, S], dtype=np.float32)
        keep = np.zeros(len(boxes), dtype=bool)
        for i in range(len(boxes)):
            x0i = max(0, min(S, int(np.floor(px[i, 0]))))
            y0i = max(0, min(S, int(np.floor(px[i, 1]))))
            x1i = max(0, min(S, int(np.ceil(px[i, 2]))))
            y1i = max(0, min(S, int(np.ceil(px[i, 3]))))
            area = max(1.0, (x1i - x0i) * (y1i - y0i))
            covered = integral[y1i, x1i] - integral[y0i, x1i] - integral[y1i, x0i] + integral[y0i, x0i]
            frac = covered / area
            keep[i] = (frac < (1.0 - visibility)) if keep_outside else (frac > visibility)
        return boxes[keep], labels[keep], diff[keep]

    def _apply_ctcrm(self, A: Dict[str, Any], B: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        cfg = self.cfg
        S = cfg.hr_image_size
        if random.random() < cfg.ctcrm_classmix_prob:
            classes_in_b = [int(c) for c in np.unique(B["mask"]) if c not in (0, cfg.ignore_index)]
            if not classes_in_b:
                return None
            k = max(1, len(classes_in_b) // 2)
            chosen = set(random.sample(classes_in_b, k))
            paste_mask = np.isin(B["mask"], list(chosen))
        else:
            area_frac = random.uniform(cfg.ctcrm_min_region_frac, cfg.ctcrm_max_region_frac)
            side = max(1, int(round(S * math.sqrt(area_frac))))
            rx = random.randint(0, max(0, S - side))
            ry = random.randint(0, max(0, S - side))
            paste_mask = np.zeros((S, S), dtype=bool)
            paste_mask[ry:ry + side, rx:rx + side] = True
        frac = float(paste_mask.mean())
        if frac < cfg.ctcrm_min_region_frac or frac > cfg.ctcrm_max_region_frac:
            return None

        img_a = np.array(A["hr_pil"], dtype=np.float32)
        img_b = np.array(B["hr_pil"], dtype=np.float32)
        m3 = paste_mask[..., None]
        mixed_img = np.where(m3, img_b, img_a).astype(np.uint8)
        mixed_mask = np.where(paste_mask, B["mask"], A["mask"]).astype(np.int64)
        valid_edge = (A["edge"] != cfg.ignore_index) & (B["edge"] != cfg.ignore_index)
        mixed_edge = np.where(paste_mask, B["edge"], A["edge"])
        mixed_edge = np.where(valid_edge, mixed_edge, float(cfg.ignore_index)).astype(np.float32)
        mixed_valid = np.where(paste_mask, B["valid"], A["valid"]).astype(np.float32)

        a_boxes, a_labels, a_diff = self._filter_boxes_by_mask(
            A["boxes"], A["labels"], A["diff"], paste_mask, keep_outside=True, S=S, visibility=cfg.ctcrm_box_visibility)
        b_boxes, b_labels, b_diff = self._filter_boxes_by_mask(
            B["boxes"], B["labels"], B["diff"], paste_mask, keep_outside=False, S=S, visibility=cfg.ctcrm_box_visibility)
        boxes = np.concatenate([a_boxes, b_boxes], axis=0) if (len(a_boxes) or len(b_boxes)) else np.zeros((0, 4), np.float32)
        labels = np.concatenate([a_labels, b_labels], axis=0) if (len(a_labels) or len(b_labels)) else np.zeros((0,), np.int64)
        diff = np.concatenate([a_diff, b_diff], axis=0) if (len(a_diff) or len(b_diff)) else np.zeros((0,), bool)

        return {
            "hr_pil": Image.fromarray(mixed_img), "mask": mixed_mask, "edge": mixed_edge, "valid": mixed_valid,
            "boxes": boxes.astype(np.float32), "labels": labels.astype(np.int64), "diff": diff.astype(bool),
            "image_id": A["image_id"], "meta": A["meta"],   # meta is unused for train-only CTCRM samples
        }

    def __getitem__(self, idx: int) -> Dict[str, torch.Tensor]:
        cfg = self.cfg
        A = self._load_one(idx)
        if self.augment and cfg.use_ctcrm and len(self.image_ids) > 1 and random.random() < cfg.ctcrm_prob:
            j = random.randrange(len(self.image_ids))
            if j != idx:
                mixed = self._apply_ctcrm(A, self._load_one(j))
                if mixed is not None:
                    A = mixed

        hr_pil = A["hr_pil"]
        hr_image = TF.to_tensor(hr_pil)
        lr_image = TF.to_tensor(hr_pil.resize((cfg.lr_image_size, cfg.lr_image_size), BICUBIC))
        mask_tensor = torch.from_numpy(np.ascontiguousarray(A["mask"])).unsqueeze(0)
        edge_tensor = torch.from_numpy(np.ascontiguousarray(A["edge"])).unsqueeze(0)
        valid_tensor = torch.from_numpy(np.ascontiguousarray(A["valid"])).unsqueeze(0)
        label_tensor = torch.zeros(cfg.num_classes, dtype=torch.float32)
        if len(A["labels"]) > 0:
            label_tensor[torch.from_numpy(A["labels"])] = 1.0
        return {
            "lr_image": lr_image, "hr_image": hr_image, "mask": mask_tensor, "edge_mask": edge_tensor,
            "valid_mask": valid_tensor, "label": label_tensor,
            "boxes": torch.from_numpy(np.ascontiguousarray(A["boxes"], dtype=np.float32).reshape(-1, 4)),
            "box_labels": torch.from_numpy(np.ascontiguousarray(A["labels"], dtype=np.int64)),
            "box_difficult": torch.from_numpy(np.ascontiguousarray(A["diff"], dtype=bool)),
            "image_id": A["image_id"], "meta": A["meta"],
        }


def omnimorph_collate_fn(batch):
    return {
        "lr_image": torch.stack([b["lr_image"] for b in batch], dim=0),
        "hr_image": torch.stack([b["hr_image"] for b in batch], dim=0),
        "mask": torch.stack([b["mask"] for b in batch], dim=0),
        "edge_mask": torch.stack([b["edge_mask"] for b in batch], dim=0),
        "valid_mask": torch.stack([b["valid_mask"] for b in batch], dim=0),
        "label": torch.stack([b["label"] for b in batch], dim=0),
        "boxes": [b["boxes"] for b in batch],
        "box_labels": [b["box_labels"] for b in batch],
        "box_difficult": [b["box_difficult"] for b in batch],
        "image_id": [b["image_id"] for b in batch],
        "meta": [b["meta"] for b in batch],
    }


def move_batch(batch: Dict, device) -> Dict:
    """v2's version called `.to(device)` on every list element unconditionally, which only ever worked because
    every list-valued batch entry happened to be a list of tensors; `meta` (a list of plain dicts) and `image_id`
    (a list of strings) would have crashed it -- guarded here to move tensors and pass everything else through."""
    out = {}
    for k, v in batch.items():
        if torch.is_tensor(v):
            out[k] = v.to(device, non_blocking=True)
        elif isinstance(v, list) and len(v) > 0 and torch.is_tensor(v[0]):
            out[k] = [t.to(device, non_blocking=True) for t in v]
        else:
            out[k] = v
    return out


# ============================================================================
# 8. METRICS + TRAINER
# ============================================================================
class MetricTracker:
    """Epoch-level metrics, accumulated over the WHOLE split (not averaged per-batch, which is biased/noisy for
    mAP-like metrics)."""
    def __init__(self, cfg: OmniMorphConfig, device, criterion: MultiTaskLoss):
        self.cfg, self.device, self.criterion = cfg, device, criterion
        self.loss_sums = defaultdict(lambda: torch.zeros((), device=device))
        self.n_batches = 0
        self.psnr_sum = torch.zeros((), device=device)
        self.ssim_sum = torch.zeros((), device=device)
        self.n_images = 0
        C = cfg.num_mask_classes
        self.conf = torch.zeros(C * C, dtype=torch.long, device=device)
        self.edge_counts = torch.zeros(len(cfg.edge_eval_thresholds), 4, dtype=torch.float64, device=device)
        self.cls_scores, self.cls_labels = [], []
        self.det = DetectionEvaluator(cfg.num_classes, cfg.det_iou_thresh, cfg.det_score_thresh, cfg.det_max_per_image)

    @torch.no_grad()
    def update(self, preds: Dict, batch: Dict, loss_dict: Dict[str, torch.Tensor]):
        cfg = self.cfg
        for k, v in loss_dict.items():
            self.loss_sums[k] += v
        self.n_batches += 1
        # --- SR: PSNR/SSIM restricted to the letterbox's real (non-padded) pixels ---
        pred_hr = preds["pred_hr"].float().clamp(0.0, 1.0)
        hr = batch["hr_image"]
        valid_mask = batch.get("valid_mask")
        if valid_mask is None:
            valid_mask = torch.ones_like(hr[:, :1])
        B, C = hr.shape[0], hr.shape[1]
        n_valid_px = valid_mask.sum(dim=(1, 2, 3)).clamp(min=1.0)
        sq_err_sum = (((pred_hr - hr) ** 2) * valid_mask).sum(dim=(1, 2, 3))
        mse = sq_err_sum / (n_valid_px * C)
        self.psnr_sum += (10.0 * torch.log10(1.0 / (mse + cfg.psnr_eps))).sum()
        _, ssim_val = self.criterion.masked_ssim(pred_hr, hr, valid_mask)
        self.ssim_sum += ssim_val * B
        self.n_images += B
        # --- segmentation: global confusion matrix ---
        C21 = cfg.num_mask_classes
        pred_cls_map = preds["pred_masks"].float().argmax(dim=1)
        target = batch["mask"].squeeze(1)
        valid = (target != cfg.ignore_index) & (target < C21)
        self.conf += torch.bincount(target[valid] * C21 + pred_cls_map[valid], minlength=C21 * C21)
        # --- edges: precision/recall with a small spatial tolerance, several thresholds ---
        prob = torch.sigmoid(preds["pred_edges"].float())
        tgt = batch["edge_mask"]
        valid_e = tgt != cfg.ignore_index
        gt = (tgt > 0.5) & valid_e
        r = cfg.edge_tolerance
        k = 2 * r + 1
        gt_dil = F.max_pool2d(gt.float(), k, 1, r) > 0
        for ti, th in enumerate(cfg.edge_eval_thresholds):
            pr = (prob > th) & valid_e
            pr_dil = F.max_pool2d(pr.float(), k, 1, r) > 0
            self.edge_counts[ti, 0] += (pr & gt_dil).sum()
            self.edge_counts[ti, 1] += pr.sum()
            self.edge_counts[ti, 2] += (gt & pr_dil).sum()
            self.edge_counts[ti, 3] += gt.sum()
        # --- multi-label classification ---
        self.cls_scores.append(torch.sigmoid(preds["pred_cls"].float()).cpu())
        self.cls_labels.append(batch["label"].cpu())
        # --- detection ---
        self.det.update(preds["pred_det_boxes"], preds["pred_det_logits"], preds["pred_det_iou"],
                        batch["boxes"], batch["box_labels"], batch["box_difficult"])

    def compute(self) -> Dict[str, float]:
        cfg = self.cfg
        out = {k: float(v / max(self.n_batches, 1)) for k, v in self.loss_sums.items()}
        out["loss"] = out.get("loss_total", 0.0)
        out["psnr"] = float(self.psnr_sum / max(self.n_images, 1))
        out["ssim"] = float(self.ssim_sum / max(self.n_images, 1))
        C = cfg.num_mask_classes
        conf = self.conf.view(C, C).double()
        diag = conf.diag()
        union = conf.sum(0) + conf.sum(1) - diag
        present = union > 0
        out["miou"] = float((diag[present] / union[present]).mean() * 100.0) if present.any() else 0.0
        out["pix_acc"] = float(diag.sum() / conf.sum().clamp(min=1.0) * 100.0)
        cnt = self.edge_counts.cpu().numpy()
        prec = cnt[:, 0] / np.maximum(cnt[:, 1], 1.0)
        rec = cnt[:, 2] / np.maximum(cnt[:, 3], 1.0)
        f1 = 2 * prec * rec / np.maximum(prec + rec, 1e-8)
        best = int(np.argmax(f1))
        out["edge_f1"], out["edge_prec"], out["edge_rec"] = float(f1[best] * 100), float(prec[best] * 100), float(rec[best] * 100)
        out["edge_thr"] = float(cfg.edge_eval_thresholds[best])
        out["cls_map"] = multilabel_map(torch.cat(self.cls_scores).numpy(), torch.cat(self.cls_labels).numpy())
        out["det_map"] = self.det.compute()
        return out


class ModelEMA:
    def __init__(self, model: nn.Module, decay: float):
        self.module = copy.deepcopy(model).eval()
        for p in self.module.parameters():
            p.requires_grad_(False)
        self.decay = decay
        self.updates = 0

    @torch.no_grad()
    def update(self, model: nn.Module):
        self.updates += 1
        d = min(self.decay, (1.0 + self.updates) / (10.0 + self.updates))
        msd = model.state_dict()
        for k, v in self.module.state_dict().items():
            if v.dtype.is_floating_point:
                v.mul_(d).add_(msd[k].detach(), alpha=1.0 - d)
            else:
                v.copy_(msd[k])


class OmniMorphTrainer:
    def __init__(self, model, train_loader, val_loader, criterion, config):
        self.model = model
        self.train_loader = train_loader
        self.val_loader = val_loader
        self.criterion = criterion
        self.cfg = config
        self.device = torch.device(config.device)
        self.use_amp = bool(config.use_amp and self.device.type == "cuda")
        self.ckpt_dir = os.path.join(config.checkpoint_dir, config.experiment_name)
        os.makedirs(self.ckpt_dir, exist_ok=True)
        # no weight decay on biases / norms / prompts / queries / scales
        decay, no_decay = [], []
        for name, p in model.named_parameters():
            if not p.requires_grad:
                continue
            if (p.ndim <= 1 or name.endswith(".bias") or "global_prompts" in name or "query_" in name
                    or "tap_weights" in name or "logit_scale" in name or "dn_pos_embed" in name):
                no_decay.append(p)
            else:
                decay.append(p)
        self.optimizer = torch.optim.AdamW(
            [{"params": decay, "weight_decay": config.weight_decay}, {"params": no_decay, "weight_decay": 0.0}],
            lr=config.lr, betas=(0.9, 0.999))
        # ---- Continuity-Preserving Horizon Extension (CPHE) state -- see _lr_lambda()/resume(). `schedule_horizon`
        # is the total-epoch horizon the cosine LR (and the ICCD noise-scale anneal) is currently annealing over;
        # `restart_anchor_epoch` is the elapsed-epoch point the *current* cosine leg began at (0 for an
        # unextended run). Both are persisted in the checkpoint and only change when a resume finds the live
        # `cfg.epochs` no longer matches the horizon recorded at the last save -- i.e. the user deliberately
        # extended (or shortened) the training target between sessions. Must be set BEFORE the LambdaLR below:
        # its constructor evaluates `_lr_lambda` immediately, which reads both.
        self.schedule_horizon = config.epochs
        self.restart_anchor_epoch = 0
        self.scheduler = torch.optim.lr_scheduler.LambdaLR(self.optimizer, lr_lambda=lambda e: self._lr_lambda(e))
        try:
            self.scaler = torch.amp.GradScaler("cuda", enabled=self.use_amp)
        except (AttributeError, TypeError):
            self.scaler = torch.cuda.amp.GradScaler(enabled=self.use_amp)
        self.ema = ModelEMA(model, config.ema_decay) if config.use_ema else None
        self.start_epoch, self.best_score, self.bad_epochs = 1, -float("inf"), 0
        self.best_val_loss, self.loss_bad_epochs = float("inf"), 0
        self.history = defaultdict(list)
        self.metric_history: Dict[str, List[float]] = defaultdict(list)     # for ATHM (section 6)
        self.task_health: Dict[str, float] = {}
        self.current_dn_noise_scale = config.dn_box_noise_scale_start

    @property
    def eval_model(self) -> nn.Module:
        return self.ema.module if self.ema is not None else self.model

    def _autocast(self):
        return torch.autocast(device_type=self.device.type,
                              dtype=torch.float16 if self.device.type == "cuda" else torch.bfloat16,
                              enabled=self.use_amp)

    def _lr_lambda(self, epoch: int) -> float:
        """Warmup + cosine decay, re-anchored at `self.restart_anchor_epoch` whenever the training horizon
        (`self.schedule_horizon`) has been deliberately extended (see resume()). For an ordinary resume -- the
        overwhelming majority of calls, since the anchor only ever moves on a genuine epoch-budget change -- this
        reduces exactly to the original single-cycle formula: a pure function of `epoch`, so restoring the
        scheduler's `last_epoch` via load_state_dict() reproduces the exact pre-interruption LR trajectory with no
        discontinuity. Only a horizon change triggers a fresh, short warmup + cosine leg over the remaining span,
        deliberately (an SGDR-style warm restart, Loshchilov & Hutter ICLR'17) rather than the old behaviour of
        silently re-stretching the *whole* curve over the new total, which is what produced a raw LR jump and the
        loss-spike / metric-collapse pattern visible in training_curves.png right where the horizon was extended."""
        cfg = self.cfg
        anchor = self.restart_anchor_epoch
        horizon = max(self.schedule_horizon, anchor + 1)
        e = epoch - anchor
        warmup = max(1, cfg.warmup_epochs) if anchor == 0 else max(1, min(cfg.warmup_epochs, (horizon - anchor) // 4))
        if e < warmup:
            return float(e + 1) / float(warmup)
        progress = min(max((e - warmup) / max(1, horizon - anchor - warmup), 0.0), 1.0)
        cosine = 0.5 * (1.0 + math.cos(math.pi * progress))
        min_ratio = cfg.min_lr / cfg.lr
        return min_ratio + (1.0 - min_ratio) * cosine

    def _dn_noise_progress(self, epoch: int) -> float:
        """0->1 anneal fraction for the ICCD box-noise scale (ties to the same `schedule_horizon`/
        `restart_anchor_epoch` state as _lr_lambda, for the same reason: it was previously computed directly from
        `cfg.epochs` and so suffered the identical discontinuity on a horizon change)."""
        anchor = self.restart_anchor_epoch
        horizon = max(self.schedule_horizon, anchor + 1)
        return min(max((epoch - 1 - anchor) / max(1, horizon - anchor - 1), 0.0), 1.0)

    @staticmethod
    def composite_score(m: Dict[str, float]) -> float:
        """Model-selection score: mean of the four 'quality' metrics (all already 0-100) PLUS an SR-fidelity term
        built from PSNR/SSIM. v2's composite score never looked at reconstruction quality at all, so the 'best'
        checkpoint could -- and did -- get selected without regard to how clean the super-resolved image was."""
        psnr_term = min(100.0, max(0.0, (m["psnr"] - 20.0) * 5.0))     # ~20dB -> 0, ~40dB -> 100
        sr_term = 0.5 * psnr_term + 0.5 * (m["ssim"] * 100.0)
        return float(np.mean([m["miou"], m["edge_f1"], m["det_map"], m["cls_map"], sr_term]))

    # ---- Adaptive Task-Health Modulation (ATHM): computed once per epoch from each task's OWN validation
    #      metric trend, then pushed into the loss (lambda scaling) and the model (head dropout) ----------------
    def _update_athm(self, val_metrics: Dict[str, float], epoch: int) -> None:
        cfg = self.cfg
        task_metric_keys = {"rec": "psnr", "seg": "miou", "edge": "edge_f1", "cls": "cls_map", "det": "det_map"}
        health = {}
        for task, key in task_metric_keys.items():
            self.metric_history[task].append(val_metrics[key])
            vals = self.metric_history[task][-cfg.athm_window:]
            if not cfg.use_athm or epoch < cfg.athm_start_epoch or len(vals) < 3:
                health[task] = 1.0
                continue
            x = np.arange(len(vals), dtype=np.float64)
            y = np.asarray(vals, dtype=np.float64)
            slope = float(np.polyfit(x, y, 1)[0])
            scale = max(float(np.std(y)), 1e-3)
            h = 1.0 / (1.0 + math.exp(-slope / scale))
            health[task] = float(max(cfg.athm_health_floor, min(1.0, h)))
        self.task_health = health
        self.criterion.set_task_health(health)
        if hasattr(self.model, "set_task_health"):
            self.model.set_task_health(health)

    # ---- checkpointing -------------------------------------------------------------------------------------
    def _ckpt_path(self, name: str) -> str:
        return os.path.join(self.ckpt_dir, name)

    def _safety_paths(self) -> List[str]:
        return [self._ckpt_path(f"safety_checkpoint_{i}.pth") for i in range(max(1, self.cfg.checkpoint_keep_last_n))]

    @staticmethod
    def _atomic_torch_save(obj, path: str) -> None:
        """Writes to a temp file in the same directory, then os.replace()s it into place. A process killed
        mid-write -- a Kaggle session/GPU-quota limit, an OOM-kill, a disconnect, all routine on a free-tier
        notebook -- can then never leave a half-written, unreadable checkpoint behind: a reader sees either the
        complete old file or the complete new one, never a truncated one. This is the standard atomic-file-write
        pattern used to make checkpointing durable under unreliable compute (the same principle behind
        large-scale fault-tolerant training checkpoint designs, e.g. Meta's Check-N-Run and Gemini), applied here
        to the much simpler single-GPU-notebook case where the 'unreliable compute' is just a kernel that can be
        killed at any moment."""
        tmp_path = f"{path}.tmp.{os.getpid()}"
        torch.save(obj, tmp_path)
        os.replace(tmp_path, path)

    def _load_checkpoint_with_fallback(self) -> Optional[Dict[str, Any]]:
        """Tries `latest_checkpoint.pth` first, then each rotating safety snapshot, oldest failure mode first:
        a corrupt/truncated primary (the classic symptom of a killed-mid-write process, which used to raise
        straight out of resume() and crash the entire script before a single epoch could run) no longer stops
        training -- it just falls back to the newest snapshot that still loads cleanly."""
        candidates = [self._ckpt_path("latest_checkpoint.pth")] + self._safety_paths()
        if not any(os.path.exists(p) for p in candidates):
            return None
        for i, path in enumerate(candidates):
            if not os.path.exists(path):
                continue
            try:
                ckpt = torch.load(path, map_location=self.device, weights_only=False)
            except Exception as e:
                print(f"[!] Checkpoint '{os.path.basename(path)}' failed to load ({type(e).__name__}: {e}) -- "
                      f"typically a file truncated by a killed process mid-write. Trying the next snapshot "
                      f"instead of crashing the run.")
                continue
            if i > 0:
                print(f"[*] Recovered training state from safety snapshot '{os.path.basename(path)}' "
                      f"(epoch {ckpt.get('epoch', '?')}) after the primary checkpoint was unavailable.")
            return ckpt
        print("[!] Every checkpoint file (primary + all safety snapshots) failed to load -- starting from "
              "scratch; the model/optimizer/schedule state before this point could not be recovered.")
        return None

    def resume(self):
        ckpt = self._load_checkpoint_with_fallback()
        if ckpt is None:
            return
        saved, current = ckpt.get("model_state", {}), self.model.state_dict()
        compatible = (set(saved.keys()) == set(current.keys())
                      and all(saved[k].shape == current[k].shape for k in saved))
        if not compatible:
            print("[!] Checkpoint architecture differs from the current model (expected when resuming a v2 run "
                  "into v3's new modules) -> starting from scratch (model left untouched).")
            return
        self.model.load_state_dict(saved)
        if self.ema is not None and ckpt.get("ema_state") is not None:
            self.ema.module.load_state_dict(ckpt["ema_state"])
            self.ema.updates = ckpt.get("ema_updates", 0)
        self.optimizer.load_state_dict(ckpt["optimizer_state"])
        self.scheduler.load_state_dict(ckpt["scheduler_state"])
        if ckpt.get("scaler_state") is not None and self.use_amp:
            self.scaler.load_state_dict(ckpt["scaler_state"])
        self.start_epoch = ckpt["epoch"] + 1
        self.best_score = ckpt.get("best_score", -float("inf"))
        self.bad_epochs = ckpt.get("bad_epochs", 0)
        self.best_val_loss = ckpt.get("best_val_loss", float("inf"))
        self.loss_bad_epochs = ckpt.get("loss_bad_epochs", 0)
        self.history = defaultdict(list, ckpt.get("history", {}))
        self.metric_history = defaultdict(list, ckpt.get("metric_history", {}))
        self.current_dn_noise_scale = ckpt.get("current_dn_noise_scale", self.current_dn_noise_scale)

        # ---- Continuity-Preserving Horizon Extension: see _lr_lambda() -------------------------------------
        saved_horizon = ckpt.get("schedule_horizon")
        if saved_horizon is None:      # checkpoint predates this field (e.g. the 120-epoch run already in hand)
            saved_horizon = ckpt.get("config", {}).get("epochs", self.cfg.epochs)
        self.restart_anchor_epoch = ckpt.get("restart_anchor_epoch", 0)
        if self.cfg.epochs != saved_horizon:
            direction = "extended" if self.cfg.epochs > saved_horizon else "shortened"
            print(f"[*] Training horizon {direction}: {saved_horizon} -> {self.cfg.epochs} epochs. Re-anchoring "
                  f"the cosine LR schedule at epoch {self.scheduler.last_epoch} with a fresh SGDR-style warm "
                  f"restart instead of re-stretching the original curve over the new total -- the latter is what "
                  f"silently discontinuity-jumps the LR on a horizon change (and, symmetrically, would have frozen "
                  f"every added epoch at ~min_lr had the horizon only been *shrunk* back down at save time).")
            self.restart_anchor_epoch = self.scheduler.last_epoch
            self.schedule_horizon = self.cfg.epochs
        else:
            self.schedule_horizon = saved_horizon
        print(f"[*] Resumed from epoch {self.start_epoch}.")

    def save(self, epoch: int, is_best: bool):
        base = {"epoch": epoch, "model_state": self.model.state_dict(),
                "ema_state": self.ema.module.state_dict() if self.ema is not None else None,
                "config": asdict(self.cfg)}
        ckpt = dict(base)
        ckpt.update({
            "ema_updates": self.ema.updates if self.ema is not None else 0,
            "optimizer_state": self.optimizer.state_dict(), "scheduler_state": self.scheduler.state_dict(),
            "scaler_state": self.scaler.state_dict() if self.use_amp else None,
            "best_score": self.best_score, "bad_epochs": self.bad_epochs,
            "best_val_loss": self.best_val_loss, "loss_bad_epochs": self.loss_bad_epochs,
            "history": dict(self.history), "metric_history": dict(self.metric_history),
            "current_dn_noise_scale": self.current_dn_noise_scale,
            "schedule_horizon": self.schedule_horizon, "restart_anchor_epoch": self.restart_anchor_epoch,
        })
        self._atomic_torch_save(ckpt, self._ckpt_path("latest_checkpoint.pth"))
        every = self.cfg.checkpoint_every_n_epochs
        if every > 0 and epoch % every == 0:
            slot = (epoch // every) % max(1, self.cfg.checkpoint_keep_last_n)
            self._atomic_torch_save(ckpt, self._safety_paths()[slot])
        if is_best:
            self._atomic_torch_save(base, self._ckpt_path("best_model.pth"))

    def load_best(self):
        path = self._ckpt_path("best_model.pth")
        if not os.path.exists(path):
            print("[!] No best checkpoint found; keeping the current weights.")
            return
        try:
            ckpt = torch.load(path, map_location=self.device, weights_only=False)
        except Exception as e:
            print(f"[!] 'best_model.pth' failed to load ({type(e).__name__}: {e}); keeping the current weights "
                  f"(typically the in-memory model from the end of fit(), which is usually close to as good).")
            return
        self.model.load_state_dict(ckpt["model_state"])
        if self.ema is not None and ckpt.get("ema_state") is not None:
            self.ema.module.load_state_dict(ckpt["ema_state"])
        print(f"[*] Loaded best checkpoint (epoch {ckpt['epoch']}).")

    # ---- one epoch -------------------------------------------------------------------------------------------
    def run_epoch(self, epoch: int, loader: DataLoader, is_train: bool, tag: Optional[str] = None) -> Dict[str, float]:
        model = self.model if is_train else self.eval_model
        model.train(is_train)
        tracker = MetricTracker(self.cfg, self.device, self.criterion)
        desc = tag or f"{'Train' if is_train else 'Val'} Ep {epoch}"
        pbar = tqdm(loader, desc=desc, leave=False)
        skipped = 0
        for it, batch in enumerate(pbar):
            batch = move_batch(batch, self.device)
            dn_batch = None
            if is_train and self.cfg.use_denoising:
                dn_batch = build_dn_batch(batch["boxes"], batch["box_labels"], self.cfg,
                                          self.current_dn_noise_scale, self.device)
            if is_train:
                self.optimizer.zero_grad(set_to_none=True)
                with self._autocast():
                    if dn_batch is not None:
                        preds = model(batch["lr_image"], dn_boxes=dn_batch["noised_boxes"],
                                     dn_labels=dn_batch["noised_labels"], dn_valid=dn_batch["valid"])
                    else:
                        preds = model(batch["lr_image"])
                loss, loss_dict = self.criterion(preds, batch, dn_batch=dn_batch)
                if not torch.isfinite(loss):
                    skipped += 1
                    continue
                self.scaler.scale(loss).backward()
                self.scaler.unscale_(self.optimizer)
                nn.utils.clip_grad_norm_(model.parameters(), self.cfg.clip_grad_norm)
                self.scaler.step(self.optimizer)
                self.scaler.update()
                if self.ema is not None:
                    self.ema.update(self.model)
            else:
                with torch.no_grad():
                    with self._autocast():
                        preds = model(batch["lr_image"])
                    loss, loss_dict = self.criterion(preds, batch)
            tracker.update(preds, batch, loss_dict)
            if it % 10 == 0:
                pbar.set_postfix(loss=f"{loss.item():.3f}")
        if skipped:
            print(f"[!] {skipped} non-finite batches skipped in epoch {epoch}.")
        return tracker.compute()

    def evaluate(self, loader: DataLoader, name: str = "Test") -> Dict[str, float]:
        m = self.run_epoch(0, loader, False, tag=f"{name} eval")
        print(f"[{name}] loss {m['loss']:.3f} | PSNR {m['psnr']:.2f}dB | SSIM {m['ssim']:.3f} | mIoU {m['miou']:.1f}% "
              f"| PixAcc {m['pix_acc']:.1f}% | EdgeF1 {m['edge_f1']:.1f}% (P {m['edge_prec']:.1f} / R {m['edge_rec']:.1f}, "
              f"thr {m['edge_thr']:.2f}) | Det mAP@{self.cfg.det_iou_thresh:.1f} {m['det_map']:.1f}% | Cls mAP {m['cls_map']:.1f}%")
        with open(os.path.join(self.ckpt_dir, f"{name.lower()}_metrics.json"), "w") as f:
            json.dump(m, f, indent=2)
        return m

    def fit(self, auto_resume: Optional[bool] = None):
        if auto_resume if auto_resume is not None else self.cfg.auto_resume:
            self.resume()
        cfg = self.cfg
        if self.start_epoch > cfg.epochs:
            print(f"[*] Checkpoint is already at epoch {self.start_epoch - 1}, at or beyond the configured "
                  f"target of {cfg.epochs} epochs -- nothing to train. Raise `epochs` in the config to continue "
                  f"further (this is exactly the 'training silently stops at the old target' situation; see "
                  f"resume()'s Continuity-Preserving Horizon Extension for what happens to the LR schedule when "
                  f"you do raise it).")
        for epoch in range(self.start_epoch, cfg.epochs + 1):
            epoch_frac = self._dn_noise_progress(epoch)
            self.current_dn_noise_scale = (cfg.dn_box_noise_scale_start
                                            + (cfg.dn_box_noise_scale_end - cfg.dn_box_noise_scale_start) * epoch_frac)
            t = self.run_epoch(epoch, self.train_loader, True)
            v = self.run_epoch(epoch, self.val_loader, False)
            self.scheduler.step()
            for prefix, m in (("train", t), ("val", v)):
                for k, val in m.items():
                    self.history[f"{prefix}_{k}"].append(val)
            self._update_athm(v, epoch)
            score = self.composite_score(v)
            is_best = score > self.best_score
            if is_best:
                self.best_score, self.bad_epochs = score, 0
            else:
                self.bad_epochs += 1
            if v["loss"] < self.best_val_loss - 1e-4:
                self.best_val_loss, self.loss_bad_epochs = v["loss"], 0
            else:
                self.loss_bad_epochs += 1
            self.save(epoch, is_best)
            lr = self.optimizer.param_groups[0]["lr"]
            health_str = " ".join(f"{k}:{v_:.2f}" for k, v_ in self.task_health.items()) or "n/a"
            print(f"Ep {epoch:03d} | lr {lr:.2e} | T-Loss {t['loss']:.3f} | V-Loss {v['loss']:.3f} | "
                  f"V-PSNR {v['psnr']:.2f}dB | V-SSIM {v['ssim']:.3f} | V-mIoU {v['miou']:.1f}% | "
                  f"V-EdgeF1 {v['edge_f1']:.1f}% | V-mAP {v['det_map']:.1f}% | V-ClsmAP {v['cls_map']:.1f}% | "
                  f"score {score:.2f}{' *' if is_best else ''} | health[{health_str}]")
            print(f"      val components: rec {v['loss_rec']:.3f} | seg_ce {v['loss_seg_ce']:.3f} | "
                  f"seg_dice {v['loss_seg_dice']:.3f} | cls {v['loss_cls']:.3f} | edge {v['loss_edge']:.3f} | "
                  f"det {v['loss_det']:.3f} | dn {v['loss_dn']:.3f}")
            stop_composite = cfg.early_stop_patience > 0 and self.bad_epochs >= cfg.early_stop_patience
            stop_loss = cfg.loss_early_stop_patience > 0 and self.loss_bad_epochs >= cfg.loss_early_stop_patience
            if stop_composite or stop_loss:
                reason = "composite score" if stop_composite else "validation loss"
                print(f"[*] Early stopping: no improvement of the {reason} for "
                      f"{self.bad_epochs if stop_composite else self.loss_bad_epochs} epochs.")
                break
        plot_history(self.history, os.path.join(self.ckpt_dir, "training_curves.png"))


def plot_history(history, path: str):
    panels = [("loss", "Total loss"), ("psnr", "PSNR (dB)"), ("miou", "mIoU (%)"),
              ("edge_f1", "Edge F1 (%)"), ("det_map", "Detection mAP (%)"), ("cls_map", "Classification mAP (%)")]
    fig, axes = plt.subplots(2, 3, figsize=(16, 8))
    for ax, (key, title) in zip(axes.ravel(), panels):
        for prefix in ("train", "val"):
            series = history.get(f"{prefix}_{key}", [])
            if len(series):
                ax.plot(range(1, len(series) + 1), series, label=prefix)
        ax.set_title(title)
        ax.set_xlabel("epoch")
        ax.grid(alpha=0.3)
        ax.legend()
    plt.tight_layout()
    plt.savefig(path, dpi=100)
    plt.close(fig)


# ============================================================================
# 9. INFERENCER
# ============================================================================
class OmniMorphInferencer:
    """v2 always plotted the fixed 256x256 square canvas the network operates on -- for any non-square VOC photo
    that canvas is a warped, undersized crop of the real picture. v3 keeps the network's fixed-size canvas only
    as far as the forward pass; every plotted panel is unletterboxed back onto the image's OWN original
    resolution and aspect ratio using the per-sample transform recorded by the dataset (`meta['lb']`), and ground
    truth panels are re-read from the original files on disk for pixel-perfect reference quality rather than a
    round-tripped copy of the (downsampled-then-upsampled) canvas tensor."""
    def __init__(self, model: nn.Module, config: OmniMorphConfig, dataset: Optional[PascalVOC2012MultiTaskDataset] = None):
        self.model, self.cfg = model, config
        self.model.eval()
        self.device = next(model.parameters()).device
        self.cmap = voc_colormap()
        self.dataset = dataset
        self.dirs = [os.path.join(config.visualization_dir, d) for d in ["restoration", "segmentation", "detection"]]
        for d in self.dirs:
            os.makedirs(d, exist_ok=True)

    # ---- letterbox-aware restitution helpers --------------------------------------------------------------
    @staticmethod
    def _raw_rgb(tensor_chw: torch.Tensor) -> Image.Image:
        """Plain tensor -> PIL, no letterbox restitution -- used for the LR-input panel, which is shown exactly
        as the network consumed it (its own, still-square, low-resolution canvas); the recorded `lb` transform
        is defined in HR-canvas pixel units and would crop the wrong region if applied at LR resolution."""
        arr = tensor_chw.detach().float().cpu().clamp(0, 1).permute(1, 2, 0).numpy()
        return Image.fromarray((arr * 255.0).round().astype(np.uint8))

    @staticmethod
    def _unletterbox_rgb(tensor_chw: torch.Tensor, lb: Dict[str, Any], resample) -> Image.Image:
        arr = tensor_chw.detach().float().cpu().clamp(0, 1).permute(1, 2, 0).numpy()
        pil = Image.fromarray((arr * 255.0).round().astype(np.uint8))
        inner = pil.crop((lb["pad_left"], lb["pad_top"], lb["pad_left"] + lb["new_w"], lb["pad_top"] + lb["new_h"]))
        return inner.resize((lb["orig_w"], lb["orig_h"]), resample)

    @staticmethod
    def _unletterbox_label_map(arr_hw: np.ndarray, lb: Dict[str, Any]) -> np.ndarray:
        pil = Image.fromarray(np.clip(arr_hw, 0, 255).astype(np.uint8))
        inner = pil.crop((lb["pad_left"], lb["pad_top"], lb["pad_left"] + lb["new_w"], lb["pad_top"] + lb["new_h"]))
        return np.array(inner.resize((lb["orig_w"], lb["orig_h"]), NEAREST))

    @staticmethod
    def _unletterbox_prob_map(arr_hw: np.ndarray, lb: Dict[str, Any]) -> np.ndarray:
        pil = Image.fromarray(arr_hw.astype(np.float32))
        inner = pil.crop((lb["pad_left"], lb["pad_top"], lb["pad_left"] + lb["new_w"], lb["pad_top"] + lb["new_h"]))
        return np.array(inner.resize((lb["orig_w"], lb["orig_h"]), BILINEAR))

    def _load_original(self, image_id: str) -> Optional[Image.Image]:
        if self.dataset is None:
            return None
        path = os.path.join(self.dataset.img_dir, f"{image_id}.jpg")
        return Image.open(path).convert("RGB") if os.path.exists(path) else None

    def _load_original_gt_mask(self, image_id: str, orig_size) -> Optional[np.ndarray]:
        if self.dataset is None:
            return None
        path = os.path.join(self.dataset.mask_dir, f"{image_id}.png")
        if not os.path.exists(path):
            return None
        return np.array(Image.open(path))

    def _load_original_gt_edge(self, image_id: str) -> Optional[np.ndarray]:
        if self.dataset is None:
            return None
        path = os.path.join(self.dataset.obj_dir, f"{image_id}.png")
        if not os.path.exists(path):
            return None
        obj = np.array(Image.open(path))
        edge = PascalVOC2012MultiTaskDataset._compute_edge_map(obj, self.cfg.ignore_index)
        return np.where(edge == self.cfg.ignore_index, 0.0, edge)

    def _load_original_gt_boxes(self, image_id: str, W0: int, H0: int):
        if self.dataset is None:
            return np.zeros((0, 4), np.float32), np.zeros((0,), np.int64)
        xml_path = os.path.join(self.dataset.ann_dir, f"{image_id}.xml")
        boxes, labels, _ = self.dataset._parse_annotation(xml_path, W0, H0)
        return boxes * np.array([W0, H0, W0, H0], dtype=np.float32), labels

    @torch.no_grad()
    def run_inference_on_dataset(self, dataloader: DataLoader):
        print(f"[*] Starting inference. Output directory: {self.cfg.visualization_dir}")
        if self.dataset is None and hasattr(dataloader, "dataset"):
            self.dataset = dataloader.dataset
        cfg = self.cfg
        for batch_idx, batch in enumerate(tqdm(dataloader, desc="Inferencing Dataset")):
            if 0 < cfg.max_infer_batches <= batch_idx:
                break
            batch = move_batch(batch, self.device)
            preds = self.model(batch["lr_image"])
            for i in range(batch["lr_image"].shape[0]):
                image_id = batch["image_id"][i]
                lb = batch["meta"][i]["lb"]
                W0, H0 = lb["orig_w"], lb["orig_h"]
                sid = f"{image_id}"

                original = self._load_original(image_id)
                if original is None:
                    original = self._unletterbox_rgb(batch["hr_image"][i], lb, BICUBIC)
                pred_hr_full = self._unletterbox_rgb(preds["pred_hr"][i], lb, BICUBIC)

                edge_gt_full = self._load_original_gt_edge(image_id)
                if edge_gt_full is None:
                    edge_gt_full = self._unletterbox_prob_map(
                        np.where(batch["edge_mask"][i, 0].cpu().numpy() == cfg.ignore_index, 0.0,
                                 batch["edge_mask"][i, 0].cpu().numpy()), lb)
                pred_edge_full = self._unletterbox_prob_map(
                    preds["pred_edges"][i, 0].float().sigmoid().cpu().numpy(), lb)

                fig, ax = plt.subplots(1, 5, figsize=(25, 5))
                ax[0].imshow(self._raw_rgb(batch["lr_image"][i])); ax[0].set_title("LR Input (network's own canvas)")
                ax[1].imshow(pred_hr_full); ax[1].set_title(f"Predicted HR ({W0}x{H0})")
                ax[2].imshow(original); ax[2].set_title("Target HR (original resolution)")
                ax[3].imshow(pred_edge_full, cmap="magma", vmin=0, vmax=1); ax[3].set_title("Predicted Edges")
                ax[4].imshow(edge_gt_full, cmap="magma", vmin=0, vmax=1); ax[4].set_title("Target Edges")
                for a in ax:
                    a.axis("off")
                plt.savefig(os.path.join(self.dirs[0], f"{sid}_sr.png"), bbox_inches="tight")
                plt.close(fig)

                pred_mask_canvas = preds["pred_masks"][i].float().argmax(dim=0).cpu().numpy()
                pred_mask_full = self._unletterbox_label_map(pred_mask_canvas, lb)
                tgt_mask_full = self._load_original_gt_mask(image_id, (W0, H0))
                if tgt_mask_full is None:
                    tgt_mask_full = self._unletterbox_label_map(batch["mask"][i, 0].cpu().numpy(), lb)
                fig, ax = plt.subplots(1, 3, figsize=(18, 5))
                ax[0].imshow(original); ax[0].set_title("Target HR (original resolution)")
                ax[1].imshow(self.cmap[np.clip(pred_mask_full, 0, 255)]); ax[1].set_title("Predicted Mask")
                ax[2].imshow(self.cmap[np.clip(tgt_mask_full, 0, 255)]); ax[2].set_title("Target Mask")
                for a in ax:
                    a.axis("off")
                plt.savefig(os.path.join(self.dirs[1], f"{sid}_seg.png"), bbox_inches="tight")
                plt.close(fig)

                fig, ax = plt.subplots(1, 1, figsize=(8, 8 * H0 / max(W0, 1)))
                ax.imshow(original)
                ax.set_title("Predicted (green) vs ground-truth (red) boxes -- original resolution")
                probs = torch.softmax(preds["pred_det_logits"][i].float(), dim=-1)
                iou_scores = torch.sigmoid(preds["pred_det_iou"][i].float())
                cls_idx_all = torch.argmax(probs[:, :-1], dim=-1)
                scores_all = (probs[torch.arange(probs.shape[0]), cls_idx_all] * iou_scores).cpu().numpy()
                boxes_canvas_norm = preds["pred_det_boxes"][i].float().cpu().numpy()
                is_obj = (cls_idx_all.cpu().numpy() < cfg.num_classes) & (
                    torch.argmax(probs, dim=-1).cpu().numpy() != cfg.num_classes)
                boxes_px = unletterbox_boxes_to_pixels(boxes_canvas_norm, lb)
                keep_mask = is_obj & (scores_all >= cfg.det_vis_min_score)
                if not keep_mask.any() and is_obj.any():
                    # nothing cleared the floor: still show the network's best guesses rather than an empty plot,
                    # clearly labelled with their (low) confidence so this stays an honest diagnostic picture
                    top = np.argsort(-scores_all * is_obj)[:3]
                    keep_mask = np.zeros_like(is_obj)
                    keep_mask[top] = True & is_obj[top]
                sel = np.nonzero(keep_mask)[0]
                if len(sel) > 0:
                    nms_keep = greedy_nms(boxes_px[sel], scores_all[sel], cfg.det_nms_iou_thresh)
                    sel = sel[nms_keep]
                    order = np.argsort(-scores_all[sel])[: cfg.det_vis_topk]
                    sel = sel[order]
                for q_idx in sel:
                    x0, y0, x1, y1 = boxes_px[q_idx]
                    cls_name = cfg.voc_classes[int(cls_idx_all[q_idx].item())]
                    ax.add_patch(patches.Rectangle((x0, y0), x1 - x0, y1 - y0, linewidth=2,
                                                   edgecolor="lime", facecolor="none"))
                    ax.text(x0, max(y0 - 5, 0), f"{cls_name} {scores_all[q_idx]:.2f}",
                            color="black", fontsize=10, backgroundcolor="lime")
                gt_boxes_px, gt_labels = self._load_original_gt_boxes(image_id, W0, H0)
                if len(gt_boxes_px) == 0:
                    gt_boxes_px = unletterbox_boxes_to_pixels(batch["boxes"][i].cpu().numpy(), lb)
                    gt_labels = batch["box_labels"][i].cpu().numpy()
                for gb, gl in zip(gt_boxes_px, gt_labels):
                    x0, y0, x1, y1 = gb
                    ax.add_patch(patches.Rectangle((x0, y0), x1 - x0, y1 - y0, linewidth=1.5,
                                                   edgecolor="red", facecolor="none", linestyle="--"))
                    ax.text(x1, y1, cfg.voc_classes[int(gl)], color="white", fontsize=8, backgroundcolor="red")
                plt.axis("off")
                plt.savefig(os.path.join(self.dirs[2], f"{sid}_det.png"), bbox_inches="tight")
                plt.close(fig)


# ============================================================================
# 10. MAIN EXECUTION / SMOKE TEST / DATASET UNIT TEST
# ============================================================================
def build_loader(ds, cfg: OmniMorphConfig, shuffle: bool, drop_last: bool) -> DataLoader:
    kwargs = dict(batch_size=cfg.batch_size, shuffle=shuffle, num_workers=cfg.num_workers, drop_last=drop_last,
                  collate_fn=omnimorph_collate_fn, pin_memory=torch.cuda.is_available())
    if cfg.num_workers > 0:
        kwargs["persistent_workers"] = True
    return DataLoader(ds, **kwargs)


def main(config: Optional[OmniMorphConfig] = None):
    config = config or OmniMorphConfig()
    set_seed(config.seed)
    torch.backends.cudnn.benchmark = True
    print("[*] Loading PASCAL VOC 2012 splits...")
    try:
        voc_root = resolve_voc2012_root(config.dataset_root)
    except FileNotFoundError as e:
        print(f"[!] {e}")
        print("[!] No training data found. Please ensure VOC2012 is extracted correctly.")
        return
    describe_voc2012_root(voc_root)
    train_ds = PascalVOC2012MultiTaskDataset(voc_root, "train", config, augment=config.augment, _resolved=True)
    val_ds = PascalVOC2012MultiTaskDataset(voc_root, "val", config, augment=False, _resolved=True)
    test_ds = PascalVOC2012MultiTaskDataset(voc_root, "test", config, augment=False, _resolved=True)
    print(f"[*] Discovered Data - Train: {len(train_ds)}, Val: {len(val_ds)}, Test: {len(test_ds)} "
          f"(sum={len(train_ds) + len(val_ds) + len(test_ds)}, well under the {VOC2012_OFFICIAL_COUNTS['total_images']}"
          f"-image full VOC2012 package by design -- see the class docstring)"
          f"{'  (WARNING: test == val)' if not config.separate_test_split else ''}")
    if len(train_ds) == 0:
        print("[!] No training data found. Please ensure VOC2012 is extracted correctly.")
        return
    train_loader = build_loader(train_ds, config, shuffle=True, drop_last=True)
    val_loader = build_loader(val_ds, config, shuffle=False, drop_last=False)
    test_loader = build_loader(test_ds, config, shuffle=False, drop_last=False)
    print("[*] Initializing OmniMorphNet...")
    model = OmniMorphNet(config).to(config.device)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"[*] Single-GPU execution on {config.device} | parameters: {n_params / 1e6:.2f}M")
    criterion = MultiTaskLoss(config).to(config.device)
    trainer = OmniMorphTrainer(model, train_loader, val_loader, criterion, config)
    trainer.fit()
    trainer.load_best()
    trainer.evaluate(val_loader, "Val")
    trainer.evaluate(test_loader, "Test")
    OmniMorphInferencer(trainer.eval_model, config, dataset=test_ds).run_inference_on_dataset(test_loader)
    print("[*] Full penta-task single-GPU pipeline completed successfully.")


def smoke_test(config: Optional[OmniMorphConfig] = None, batch_size: int = 2):
    """One forward / backward / metric pass on random tensors: checks shapes, finite grads and the metric code,
    including the new ICCD denoising path (with a synthetic ragged set of GT boxes) and the letterbox-aware
    valid-pixel mask plumbing."""
    cfg = config or OmniMorphConfig()
    cfg.use_amp = False
    dev = torch.device(cfg.device)
    set_seed(cfg.seed)
    model = OmniMorphNet(cfg).to(dev)
    criterion = MultiTaskLoss(cfg).to(dev)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"[smoke] parameters: {n_params / 1e6:.2f}M")
    S, L, B = cfg.hr_image_size, cfg.lr_image_size, batch_size
    mask = torch.randint(0, cfg.num_mask_classes, (B, 1, S, S), device=dev)
    mask[:, :, :8] = cfg.ignore_index
    edge = (torch.rand(B, 1, S, S, device=dev) > 0.97).float()
    edge[:, :, :8] = float(cfg.ignore_index)
    valid_mask = torch.ones(B, 1, S, S, device=dev)
    valid_mask[:, :, :, -16:] = 0.0    # simulate a letterbox pad strip on the right edge
    boxes = [torch.tensor([[0.10, 0.10, 0.60, 0.70], [0.30, 0.20, 1.00, 0.95]], device=dev)] + \
            [torch.zeros(0, 4, device=dev) for _ in range(B - 1)]
    labels = [torch.tensor([3, 14], device=dev)] + [torch.zeros(0, dtype=torch.long, device=dev) for _ in range(B - 1)]
    diff = [torch.tensor([False, False], device=dev)] + [torch.zeros(0, dtype=torch.bool, device=dev) for _ in range(B - 1)]
    batch = {"lr_image": torch.rand(B, 3, L, L, device=dev), "hr_image": torch.rand(B, 3, S, S, device=dev),
             "mask": mask, "edge_mask": edge, "valid_mask": valid_mask,
             "label": (torch.rand(B, cfg.num_classes, device=dev) > 0.9).float(),
             "boxes": boxes, "box_labels": labels, "box_difficult": diff}

    dn_batch = build_dn_batch(boxes, labels, cfg, cfg.dn_box_noise_scale_start, dev) if cfg.use_denoising else None
    print(f"[smoke] denoising batch built: {'yes' if dn_batch is not None else 'no (no GT boxes in this synthetic batch)'}")

    model.train()
    if dn_batch is not None:
        preds = model(batch["lr_image"], dn_boxes=dn_batch["noised_boxes"], dn_labels=dn_batch["noised_labels"],
                     dn_valid=dn_batch["valid"])
    else:
        preds = model(batch["lr_image"])
    for k, v in preds.items():
        if torch.is_tensor(v):
            print(f"[smoke]   {k:<16s} {tuple(v.shape)}")
    loss, ld = criterion(preds, batch, dn_batch=dn_batch)
    loss.backward()
    bad = [n for n, p in model.named_parameters() if p.grad is not None and not torch.isfinite(p.grad).all()]
    no_grad = [n for n, p in model.named_parameters() if p.requires_grad and p.grad is None]
    print(f"[smoke] loss {loss.item():.4f} | non-finite grads: {len(bad)} | params without grad: {len(no_grad)}")
    if no_grad:
        print("[smoke]   e.g.", no_grad[:5])
    print("[smoke]   components:", {k: round(float(v), 4) for k, v in ld.items()})

    # ATHM plumbing sanity check (loss-weight + head-dropout mutation)
    if hasattr(model, "set_task_health"):
        model.set_task_health({"rec": 0.4, "seg": 1.0, "edge": 0.6, "cls": 1.0, "det": 0.35})
        criterion.set_task_health({"rec": 0.4, "seg": 1.0, "edge": 0.6, "cls": 1.0, "det": 0.35})
        assert abs(model.sr_dropout.p - (cfg.head_dropout_base + 0.6 * cfg.head_dropout_max_extra)) < 1e-6
        print(f"[smoke] ATHM dropout mutation OK (sr_dropout.p={model.sr_dropout.p:.3f})")

    model.eval()
    with torch.no_grad():
        preds = model(batch["lr_image"])
        _, ld = criterion(preds, batch)
        tracker = MetricTracker(cfg, dev, criterion)
        tracker.update(preds, batch, ld)
        print("[smoke] metrics:", {k: round(v, 3) for k, v in tracker.compute().items()})
    print("[smoke] OK")


def _write_fake_voc_sample(root: str, image_id: str, W: int, H: int, cfg: OmniMorphConfig, rng: random.Random):
    """Writes one synthetic-but-structurally-valid VOC2012 sample (JPEG + class mask + instance mask + XML
    annotation) so the dataset pipeline (letterboxing, augmentation, CTCRM, denoising targets) can be exercised
    end to end without downloading the real ~2GB dataset."""
    os.makedirs(os.path.join(root, "JPEGImages"), exist_ok=True)
    os.makedirs(os.path.join(root, "SegmentationClass"), exist_ok=True)
    os.makedirs(os.path.join(root, "SegmentationObject"), exist_ok=True)
    os.makedirs(os.path.join(root, "Annotations"), exist_ok=True)

    img = np.zeros((H, W, 3), dtype=np.uint8)
    img[..., 0] = rng.randint(40, 200)
    img[..., 1] = rng.randint(40, 200)
    img[..., 2] = rng.randint(40, 200)
    cls_mask = np.zeros((H, W), dtype=np.uint8)
    obj_mask = np.zeros((H, W), dtype=np.uint8)
    n_obj = rng.randint(1, 3)
    boxes_xml = []
    for k in range(n_obj):
        cls_id = rng.randint(1, cfg.num_classes)   # 1..20 (0 reserved for background)
        bw, bh = rng.randint(W // 6, max(W // 3, W // 6 + 1)), rng.randint(H // 6, max(H // 3, H // 6 + 1))
        x0 = rng.randint(0, max(1, W - bw))
        y0 = rng.randint(0, max(1, H - bh))
        x1, y1 = min(W, x0 + bw), min(H, y0 + bh)
        cls_mask[y0:y1, x0:x1] = cls_id
        obj_mask[y0:y1, x0:x1] = k + 1
        img[y0:y1, x0:x1, :] = np.array([(cls_id * 37) % 255, (cls_id * 91) % 255, (cls_id * 53) % 255], dtype=np.uint8)
        boxes_xml.append((cfg.voc_classes[cls_id - 1], x0 + 1, y0 + 1, x1, y1))   # VOC boxes are 1-based

    Image.fromarray(img).save(os.path.join(root, "JPEGImages", f"{image_id}.jpg"), quality=95)
    Image.fromarray(cls_mask).save(os.path.join(root, "SegmentationClass", f"{image_id}.png"))
    Image.fromarray(obj_mask).save(os.path.join(root, "SegmentationObject", f"{image_id}.png"))

    objs_xml = "".join(
        f"<object><name>{name}</name><difficult>0</difficult>"
        f"<bndbox><xmin>{x0}</xmin><ymin>{y0}</ymin><xmax>{x1}</xmax><ymax>{y1}</ymax></bndbox></object>"
        for name, x0, y0, x1, y1 in boxes_xml)
    xml = f"<annotation><size><width>{W}</width><height>{H}</height></size>{objs_xml}</annotation>"
    with open(os.path.join(root, "Annotations", f"{image_id}.xml"), "w") as f:
        f.write(xml)


def unit_test(cfg: Optional[OmniMorphConfig] = None):
    """Dataset-pipeline sanity check: builds a tiny synthetic VOC2012-shaped tree covering a wide, a tall, and a
    square image, then exercises letterboxing, train-time augmentation (crop/flip/color-jitter/CTCRM), the
    val-time (unaugmented) path, batch collation, `move_batch`, and the ICCD denoising-target builder -- all the
    new code paths that `--smoke-test`'s random tensors never touch."""
    cfg = cfg or OmniMorphConfig()
    cfg.batch_size = 3
    cfg.num_workers = 0
    rng = random.Random(cfg.seed)
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "ImageSets", "Segmentation"), exist_ok=True)
        sizes = [(500, 333), (333, 500), (256, 256), (640, 200), (200, 640), (480, 360)]
        ids = [f"synth_{i:03d}" for i in range(len(sizes))]
        for image_id, (W, H) in zip(ids, sizes):
            _write_fake_voc_sample(root, image_id, W, H, cfg, rng)
        with open(os.path.join(root, "ImageSets", "Segmentation", "train.txt"), "w") as f:
            f.write("\n".join(ids[:4]) + "\n")
        with open(os.path.join(root, "ImageSets", "Segmentation", "val.txt"), "w") as f:
            f.write("\n".join(ids[4:]) + "\n")

        cfg.separate_test_split = False
        train_ds = PascalVOC2012MultiTaskDataset(root, "train", cfg, augment=True)
        val_ds = PascalVOC2012MultiTaskDataset(root, "val", cfg, augment=False)
        assert len(train_ds) == 4 and len(val_ds) == 2, "split sizes do not match the synthetic tree"
        S = cfg.hr_image_size

        # ---- per-sample shape / range checks, including several CTCRM-triggering draws ----
        for _ in range(8):
            s = train_ds[rng.randrange(len(train_ds))]
            assert s["hr_image"].shape == (3, S, S)
            assert s["lr_image"].shape == (3, cfg.lr_image_size, cfg.lr_image_size)
            assert s["mask"].shape == (1, S, S)
            assert s["edge_mask"].shape == (1, S, S)
            assert s["valid_mask"].shape == (1, S, S)
            assert float(s["valid_mask"].min()) >= 0.0 and float(s["valid_mask"].max()) <= 1.0
            assert float(s["valid_mask"].sum()) > 0.0, "letterbox produced an all-padding canvas"
            if s["boxes"].numel() > 0:
                assert float(s["boxes"].min()) >= -1e-4 and float(s["boxes"].max()) <= 1.0 + 1e-4
                assert torch.all(s["boxes"][:, 2] >= s["boxes"][:, 0]) and torch.all(s["boxes"][:, 3] >= s["boxes"][:, 1])
        for i in range(len(val_ds)):
            s = val_ds[i]
            assert s["hr_image"].shape == (3, S, S)
            assert float(s["valid_mask"].sum()) > 0.0
        print("[unit-test] per-sample shape/range checks OK")

        # ---- letterbox round-trip: original-space boxes -> canvas -> back to original-space pixels ----
        lb = compute_letterbox_params(640, 200, S)
        orig_boxes = np.array([[10, 20, 300, 150], [0, 0, 640, 200]], dtype=np.float32)
        norm_boxes = orig_boxes / np.array([640, 200, 640, 200], dtype=np.float32)
        canvas_boxes = letterbox_boxes(norm_boxes, 640, 200, lb)
        recovered_px = unletterbox_boxes_to_pixels(canvas_boxes, lb)
        assert np.allclose(recovered_px, orig_boxes, atol=1.5), f"letterbox round-trip drifted: {recovered_px} vs {orig_boxes}"
        print("[unit-test] letterbox box round-trip OK")

        # ---- collate + move_batch (meta/image_id must survive un-mangled; this is the bug v2's move_batch had) ----
        loader = build_loader(train_ds, cfg, shuffle=False, drop_last=False)
        batch = next(iter(loader))
        batch = move_batch(batch, torch.device("cpu"))
        assert isinstance(batch["image_id"], list) and isinstance(batch["image_id"][0], str)
        assert isinstance(batch["meta"], list) and "lb" in batch["meta"][0]
        assert batch["hr_image"].shape[0] == len(batch["image_id"])
        print("[unit-test] collate_fn / move_batch OK")

        # ---- ICCD denoising target builder on a real ragged batch ----
        dn = build_dn_batch(batch["boxes"], batch["box_labels"], cfg, cfg.dn_box_noise_scale_start, torch.device("cpu"))
        if dn is not None:
            assert dn["noised_boxes"].shape == (len(batch["boxes"]), cfg.dn_max_gt_per_image, 4)
            assert bool(dn["valid"].any()), "no valid denoising slots were produced despite having GT boxes"
            assert float(dn["target_iou"][dn["valid"]].min()) >= 0.0 and float(dn["target_iou"][dn["valid"]].max()) <= 1.0
        print(f"[unit-test] ICCD denoising batch builder OK (produced={'yes' if dn is not None else 'no'})")

    print("[unit-test] ALL CHECKS PASSED")


if __name__ == "__main__":
    cfg = OmniMorphConfig()
    main(cfg)
