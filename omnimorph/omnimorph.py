"""
OmniMorph v4.1 - penta-task network on PASCAL VOC 2012 (single GPU)
===================================================================
Tasks: 4x super-resolution | semantic segmentation | multi-label classification |
       object-instance edges | object detection (DETR-style).

Usage
-----
    python omnimorph.py                 # full pipeline: train -> best ckpt -> test metrics -> visualisations
    python omnimorph.py --smoke-test    # one forward/backward on random tensors (shape / gradient sanity check)
    python omnimorph.py --unit-test     # dataset-pipeline sanity check on synthetic VOC-shaped files (no GPU,
                                         # no real dataset needed)
    python omnimorph.py --overfit-test  # tiny end-to-end training run through the real trainer (CPU, minutes)
                                         # that asserts every task learns -- incl. confident detections
(v3 documented `--smoke-test` / `--unit-test` but its `__main__` never parsed them; v4 wires all three, and uses
`parse_known_args` so running the file as a Kaggle/Jupyter cell -- which injects `-f kernel.json` -- still works.)

v4.1 -- what the first 14-epoch Kaggle run of v4 showed
------------------------------------------------------
Quality was moving the right way from v3 (val mIoU 67.3% vs v3's 19%, cls mAP 90.5% vs 37%, det mAP 20.5% vs 7%
and still rising ~2 points/epoch, PSNR 26.77 dB vs 25.4 dB), but the run itself was not viable:
  * 2.0 s/step at batch_size=5 -> ~14 min/epoch -> ~35 h for 150 epochs, over Kaggle's 30 h/week GPU quota. Measured
    per image (real config): ~350 forward GFLOPs and 2.6 GB of saved activations. The biggest single item was
    GLOBAL attention over all 16,384 tokens of the stride-1 encoder stage (~137 GFLOPs for two blocks); then a
    129-channel edge-fusion conv at 512x512.
    Batch 8 did not fit, hence batch 5, which left the mixed-supervision sampler with 4 fully-labelled + 1
    box/label-only image per batch: 9k of the 10.7k training images were barely used.
  * The log could not be read at face value: T-Loss (123 -> 56) summed ~13 detection outputs + denoising while
    V-Loss (15 -> 7) holds only the final outputs (an apparent 8x gap that is not a gap); the printed LR was the
    next epoch's; PSNR had no bicubic reference, so the SR gain (+0.8 dB) was invisible; the "duplicated copy"
    warning claimed counts would be inflated although only one copy is ever read.
  v4.1 changes (all exactness-tested in --unit-test / --smoke-test where they are meant to be pure speed-ups):
  shifted-window attention (Swin) on the two high-resolution stages, one fused grid_sample for the 9 deformable
  taps, activation checkpointing of the first three encoder stages, a narrow edge-fusion conv, FrozenBN in fp16, the perceptual term off by default (and at half resolution
  when on), one host transfer per Hungarian batch, fused EMA updates, train metrics on every 4th batch. Measured on
  CPU at the real config: forward FLOPs ~350 -> ~187 G/image, saved activations 2.6 -> ~1.3 GB/image (fp32), so
  batch 8 (4 + 4 images) fits again. Ablated on the overfit test: windowed attention matches global attention
  (PSNR/mIoU within run-to-run noise); removing the restoration stream's 512x512 conv did NOT (-0.5..0.9 dB), so
  it was kept. Plus: comparable train/val loss, true LR, PSNR
  gain vs bicubic, a step profiler with projected run time, a Kaggle session budget (training stops in time for
  the final evaluation + visualisations, the next session resumes), and a warm start that carries 99.9% of a v4
  checkpoint's weights into v4.1 instead of discarding the epochs already trained.

Why v4 exists -- what the v3 qualitative dumps show, and the root cause behind each
-----------------------------------------------------------------------------------
(1) Restoration: "Predicted HR" is visually the bicubic upsample of the LR canvas.
    a. The SR head decoded only from the shared, GroupNorm'd pixel-decoder tensor `ms[0]` that segmentation,
       edges, classification and detection all pull on. Every SR network since EDSR/RCAN keeps a dedicated,
       normalisation-free path from a shallow conv of the LR pixels to the output (a long skip) -- that is what
       carries the high frequencies. v3 had none.
    b. One global `clip_grad_norm_(model.parameters(), 1.0)`: the detection terms (Hungarian + denoising + aux
       layers) dominate the total gradient norm, so the shared clip factor shrinks the SR gradient towards zero
       on every step.
    c. Dropout2d on SR features, *raised* by ATHM whenever PSNR plateaued (channel dropout inside an SR body
       hurts reconstruction -- Kong et al., CVPR'22) -- and ATHM's health = sigmoid(slope) read a plateau
       (slope ~ 0 -> 0.5) as sickness, so the reconstruction loss weight was also halved exactly at convergence.
(2) Segmentation: silhouettes are roughly right but hair is labelled dog / cat -- recognition fails, not
    localisation. A from-scratch encoder sees a 128px bicubic-degraded image and 1,464 labelled examples; every
    competitive VOC segmenter starts from ImageNet features. Nothing tied the per-pixel classes to what the
    image-level head believes is present (v3 can say "person" globally and "dog" on the hair at the same time).
(3) Detection: boxes land near the right objects, but every score is 0.03-0.06.
    a. score = softmax-focal probability x sigmoid(IoU head): two separately under-confident numbers multiplied;
       the IoU head's target is 0 for 31 of the 32 queries of every image.
    b. v3's ICCD trained that IoU head on the denoising queries towards IoU(noised INPUT box, GT) -- the quality of
       what a query was handed, not of what it predicted -- which systematically under-rates refined boxes.
    c. Content-only queries without reference boxes or iterative refinement (DAB-DETR / Deformable DETR show these
       converge ~10x slower), no pretrained features, and only the 1,464 images that happen to have masks.
(4) Edges: the predicted map fires on every intensity edge (CPU case, faces, shirt print) while the target holds
    only annotated-object boundaries: nothing told the edge head which edges belong to objects.

What v4 changes (each item says what it is built on and what is new; per the request that novelty be a real,
working combination and not a renamed method)
------------------------------------------------------------------------------------------------------------
  * Restore-then-Recognise (RtR, section 3b) -- a dedicated RCAN-lite restoration stream (own long skip, no norm,
    no dropout), SFT-conditioned on the jointly-trained LR encoder, whose output (stop-gradient) is what an
    ImageNet-pretrained recognition stream (ResNet-50 by default) reads; its stride-4..32 features land exactly on
    the LR encoder's four grids and are fused into the pixel decoder. Information flows both ways, gradients only
    one way each. Built on RCAN, SFT-GAN and SR4IR (which, unlike RtR, backpropagates task loss INTO the SR net).
  * Stream-Isolated Gradient Clipping (SIGC, Trainer) -- one clip budget per stream (restoration / pretrained
    semantic / everything else) instead of one global norm, so detection's large gradients can no longer scale
    the restoration update to nothing. A single-backward-pass alternative to PCGrad/GradNorm-style surgery.
  * Anchor-refined decoder (section 4) -- DAB-DETR anchors + Deformable-DETR iterative refinement, per-class
    sigmoid scores; positional queries live in the same normalised sine space as the memory encoding; initial
    anchors are selected per image from scored multi-scale proposals (DINO's mixed query selection), so the
    decoder never starts from image-agnostic boxes.
  * Quality-Annealed IoU-aware Classification (QAIC, MultiTaskLoss._vfl) -- one score per box whose target is
    IoU(pred, GT)^beta (Varifocal loss); beta is annealed 0 -> 1, from hard labels (fast recognition while early
    IoUs are ~0) to full IoU calibration. Replaces the score x IoU-head product.
  * ICCD v2 (section 5) -- noised GT boxes now enter as reference anchors (where DN-DETR puts them), contrastive
    negatives teach duplicate rejection (DINO CDN), the IoU-consistency target is computed from each query's OWN
    output box, every decoder layer is supervised, and the noise curriculum is kept from v3.
  * Presence-Prior Segmentation Calibration (PPSC) -- adds g * log sigmoid(cls_c) to segmentation logit c (learned
    g >= 0): a Bayesian image-level prior that stops absent classes from winning pixel islands.
  * Label-Disagreement Boundary Coupling (LDBC) -- the edge head gets the closed-form probability that adjacent
    pixels carry different segmentation labels, 1 - sum_c p_c(x) p_c(x+d), so only object boundaries survive;
    the edge loss also sharpens segmentation boundaries through it at reduced gradient scale.
  * Mixed-Supervision Batch Sampler (MSBS, section 7) -- the ~10k ImageSets/Main train+val images that have boxes
    and labels but no mask (Segmentation-val excluded, so val/test never leak) join training with segmentation /
    edge targets set to `ignore`; every batch keeps a fixed quota of fully-labelled images so segmentation
    supervision never thins out. ~7x more data for detection / classification / SR.
  * ATHM v2 -- a dead-banded health score that only penalises a *declining* validation metric (a plateau is not
    overfitting), modulating dropout on the seg / edge / cls heads only.
  * Flip test-time self-ensemble for the final evaluation and the visualisations (dense outputs + classifier).
  * Fixes: all-ignore-mask cross-entropy returned NaN (silently skipped steps); the inferencer now upsamples
    segmentation *logits* to the original resolution before the argmax (instead of nearest-resizing labels).

Kept from v3 (unchanged): letterboxed preprocessing and exact un-letterboxing, PCSR (now fed the sigmoid scores),
CTCRM, the Laplacian-pyramid fidelity loss, deep supervision, EMA, atomic checkpointing, CPHE horizon extension.

Honest scope: there is no GPU or copy of VOC2012 in the environment this was written in, so nothing here has been
trained on VOC and no VOC number is claimed. What has been verified is that every path is shape-correct with
finite gradients (`--smoke-test`), that the data pipeline, the no-leak sampler, ICCD v2, LDBC and QAIC behave as
specified (`--unit-test`), and that a tiny instance trained through the real trainer makes every task learn,
including confident detections (`--overfit-test`). 4x SR from a bicubic-downsampled input is information-
theoretically lossy, so "identical to ground truth" cannot be guaranteed by any model; v4 removes the structural
reasons the reconstruction was capped near bicubic quality.
"""
import os
import sys
import math
import json
import copy
import random
import argparse
import tempfile
import time
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
from torchvision.ops.misc import FrozenBatchNorm2d
from torch.utils.checkpoint import checkpoint
from scipy import ndimage
from scipy.optimize import linear_sum_assignment
from PIL import Image
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as patches
from tqdm import tqdm

_PROCESS_START = time.time()          # session-budget reference (Kaggle's 12 h limit counts from session start)
_RESAMPLING = getattr(Image, "Resampling", Image)
BICUBIC, NEAREST, BILINEAR = _RESAMPLING.BICUBIC, _RESAMPLING.NEAREST, _RESAMPLING.BILINEAR
FLIP_LR = getattr(Image, "Transpose", Image).FLIP_LEFT_RIGHT


# ============================================================================
# 1. CONFIGURATION
# ============================================================================
@dataclass
class OmniMorphConfig:
    experiment_name: str = "omnimorph_voc2012_penta_task_singlegpu_v4"
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
    # ---- mixed-supervision training set (MSBS, section 7) -------------------------------------------------
    # Adds the ImageSets/Main train+val images (boxes + labels, no mask) minus Segmentation-val to TRAINING only;
    # every batch carries `full_label_per_batch` fully-labelled (mask + edge) images, the rest box/label-only.
    # 0 = automatic: round(batch_size * full_label_fraction), so lowering batch_size keeps the mix balanced
    # (v4 hard-coded 4, which at batch_size=5 left a single box/label-only image per batch).
    use_partial_label_images: bool = True
    full_label_per_batch: int = 0
    full_label_fraction: float = 0.5
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
    num_queries: int = 48                # VOC images hold up to ~40 objects; 32 left little slack for one-to-one
    use_query_selection: bool = True     # image-conditioned anchors (DINO mixed query selection), see QueryDecoder
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
    attn_window: int = 16                # v4.1: (shifted-)window attention on maps with more tokens than ...
    attn_global_max_tokens: int = 1024   # ... this; smaller maps (the 32x32 / 16x16 stages) stay global
    grad_checkpoint: bool = True         # activation checkpointing of the high-resolution encoder stages (their
    checkpoint_encoder_stages: int = 3   # LoRA gates/deformable taps were ~45% of activation memory; cheap to redo)
    checkpoint_restoration: bool = False  # also checkpoint the restoration groups (~40 GFLOPs/img recompute for
                                          # ~0.13 GB/img saved): only if batch_size still does not fit
    rope_base: float = 10000.0
    edge_hidden_channels: int = 32
    edge_branch_channels: int = 16       # width of each 512x512 input of the edge fusion conv
    # ---- Restore-then-Recognise (RtR, section 3b) -----------------------------------------------------------
    # restoration stream (RCAN-lite, SFT-conditioned on the LR encoder)
    rs_channels: int = 64
    rs_groups: int = 4
    rs_blocks_per_group: int = 4
    rs_ca_reduction: int = 16
    restoration_weight_decay: float = 0.0  # EDSR/RCAN train without weight decay; it only shrinks SR filters
    rs_hr_refine: bool = True            # 3x3 conv at full output resolution before the RGB tail: ~19 GFLOPs/img,
                                          # but removing it cost ~0.5-0.9 dB PSNR in the overfit ablation
    # semantic stream (ImageNet-pretrained; reads the restored canvas)
    backbone_name: str = "resnet50"      # resnet18 | resnet34 | resnet50 | convnext_tiny | none
    backbone_pretrained: bool = True     # torchvision download (needs Internet ON in a Kaggle notebook)
    backbone_weights_path: str = ""      # ...or a local torchvision checkpoint, e.g. attached as a Kaggle dataset
    backbone_freeze_stem: bool = True    # freeze stem + first stage (DETR practice)
    backbone_lr_mult: float = 0.1
    semantic_input: str = "restored"     # "restored" (SR output, stop-gradient) | "bicubic"
    # ---- segmentation / edge coupling -------------------------------------------------------------------------
    use_presence_prior: bool = True      # PPSC
    ldbc_grad_to_seg: float = 0.1        # LDBC: scale of the edge-loss gradient that reaches the seg logits
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
    lambda_perceptual: float = 0.0       # frozen-ImageNet-feature term (needs a pretrained stream). v4.1: off by
                                          # default -- two extra ResNet passes per step for a term that trades PSNR
                                          # for texture; set e.g. 0.05 for sharper-looking, lower-PSNR output
    perceptual_scale: float = 0.5        # the feature term is computed on 2x-downsampled images (4x cheaper)
    lambda_mid_sr: float = 0.3           # deep supervision at the intermediate 2x (256px) SR resolution
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
    lambda_aux_det: float = 1.0          # every decoder layer is supervised like the last (DETR practice)
    # Sigmoid-focal matching cost (Deformable DETR) + Quality-Annealed IoU-aware Classification (QAIC) loss
    focal_alpha: float = 0.25
    focal_gamma: float = 2.0
    vfl_alpha: float = 0.75              # Varifocal negative weight
    quality_anneal_epochs: int = 20      # QAIC: beta goes 0 (hard labels) -> 1 (IoU targets) over these epochs
    # ---- ICCD v2 (IoU-Consistent Curriculum Denoising) ------------------------------------------------------
    use_denoising: bool = True
    dn_max_gt_per_image: int = 24
    dn_use_negatives: bool = True        # contrastive negatives (DINO CDN)
    dn_box_noise_scale_start: float = 1.0
    dn_box_noise_scale_end: float = 0.4
    dn_label_noise_prob: float = 0.2
    lambda_dn_cls: float = 2.0
    lambda_dn_bbox: float = 5.0
    lambda_dn_giou: float = 2.0
    # ---- Adaptive Task-Health Modulation (ATHM v2) ------------------------------------------------------------
    use_athm: bool = True
    athm_start_epoch: int = 10
    athm_window: int = 6
    athm_health_floor: float = 0.35
    athm_deadband: float = 0.5           # normalised slope a metric may fall by before it counts as declining
    head_dropout_base: float = 0.05
    head_dropout_max_extra: float = 0.25
    # ---- regularisation ------------------------------------------------------------
    drop_path_rate: float = 0.15
    num_refine_rounds: int = 6          # number of decoder layers (cycling coarse -> fine pixel-decoder scales)
    # ---- optimisation ----------------------------------------------------------------
    batch_size: int = 8
    num_workers: int = 4
    epochs: int = 100                    # an epoch = len(fully-labelled) / full_label_per_batch steps (366 at the
                                          # defaults). v4.1: 150 -> 100 so the whole run fits Kaggle's 30 h/week GPU
                                          # quota; the step profiler prints the projected wall-clock at epoch 1.
    warmup_epochs: int = 5
    lr: float = 2e-4
    min_lr: float = 1e-6
    weight_decay: float = 0.05
    clip_grad_norm: float = 1.0          # applied PER STREAM (SIGC, see OmniMorphTrainer)
    use_amp: bool = True                 # only used when running on CUDA
    use_ema: bool = True
    ema_decay: float = 0.999
    early_stop_patience: int = 40        # epochs without improvement of the composite val score (0 = off)
    loss_early_stop_patience: int = 50   # epochs without improvement of the val TOTAL LOSS (0 = off); the
                                          # composite score alone was not enough to catch the v2 run's overfitting
                                          # (val loss visibly troughed ~epoch 90 and climbed for ~80 more epochs)
    # ---- long-horizon / multi-session resumability (Kaggle sessions get killed well before a long run finishes
    #      in one sitting -- see OmniMorphTrainer.save/resume/_lr_lambda) --------------------------------------
    auto_resume: bool = True             # resume from `latest_checkpoint.pth` (or a safety snapshot) if present
    checkpoint_every_n_epochs: int = 5   # rotating safety snapshot cadence, independent of "latest"/"best"
    checkpoint_keep_last_n: int = 2      # how many rotating safety snapshots to retain on disk
    session_time_budget_hours: float = 11.0  # Kaggle kills a session at 12 h: stop training early enough that the
                                          # final Val/Test evaluation and visualisations still run (0 = off); the
                                          # next session resumes from the last epoch automatically
    profile_steps: int = 20              # time data/forward/loss/backward for the first N steps of a session
    train_metric_every: int = 4          # full train-set metrics (SSIM, edges, AP, ...) on every Nth batch only
    device: str = "cuda" if torch.cuda.is_available() else "cpu"
    # ---- evaluation / inference ------------------------------------------------------
    test_flip_tta: bool = True           # flip self-ensemble for the final Val/Test evaluation + visualisations
    edge_tolerance: int = 1              # pixels of tolerance for the edge precision / recall
    edge_eval_thresholds: Tuple[float, ...] = (0.2, 0.35, 0.5, 0.65, 0.8)
    det_iou_thresh: float = 0.5
    det_score_thresh: float = 0.01
    det_max_per_image: int = 50
    max_infer_batches: int = 10          # -1 = whole test set (slow: 3 matplotlib figures per image)
    det_conf_threshold: float = 0.3      # boxes drawn as confident detections
    det_nms_iou_thresh: float = 0.5      # visualisation-only NMS (the AP metric itself stays NMS-free / raw)
    det_vis_topk: int = 12
    det_vis_min_score: float = 0.05      # fallback floor: best low-confidence guesses, drawn in a separate style


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


def inverse_sigmoid(x: torch.Tensor, eps: float = 1e-5) -> torch.Tensor:
    x = x.clamp(0.0, 1.0)
    return torch.log(x.clamp(min=eps) / (1.0 - x).clamp(min=eps))


def sine_embed(t: torch.Tensor, num_feats: int, temperature: float = 10000.0) -> torch.Tensor:
    """DETR-style sine/cosine embedding of normalised coordinates in [0, 1]: (...,) -> (..., num_feats). The memory
    positional encoding and the anchor-box positional queries (QueryDecoder) both use it, so query and key
    positions live in the same space."""
    dim_t = torch.arange(num_feats, device=t.device, dtype=torch.float32)
    dim_t = temperature ** (2.0 * torch.div(dim_t, 2, rounding_mode="floor") / num_feats)
    pos = t.float()[..., None] * (2.0 * math.pi) / dim_t
    return torch.stack((pos[..., 0::2].sin(), pos[..., 1::2].cos()), dim=-1).flatten(-2)


class _GradScale(torch.autograd.Function):
    @staticmethod
    def forward(ctx, x, scale):
        ctx.scale = scale
        return x.view_as(x)

    @staticmethod
    def backward(ctx, grad):
        return grad * ctx.scale, None


def grad_scale(x: torch.Tensor, scale: float) -> torch.Tensor:
    """Identity in the forward pass; multiplies the gradient by `scale` in the backward pass."""
    if scale == 1.0:
        return x
    if scale == 0.0:
        return x.detach()
    return _GradScale.apply(x, scale)


def label_disagreement_boundary(seg_logits: torch.Tensor) -> torch.Tensor:
    """LDBC (see OmniMorphNet.forward): probability that a pixel and at least its most-disagreeing 4-neighbour carry
    different labels under the per-pixel softmax, 1 - sum_c p_c(x) p_c(x + d), max over d. (B,C,H,W) -> (B,1,H,W)
    in [0, 1]; exactly 0 inside a confidently uniform region and -> 1 on a confident label change."""
    p = F.softmax(seg_logits.float(), dim=1)
    p_right = F.pad(p, (0, 1, 0, 0), mode="replicate")[..., :, 1:]
    p_down = F.pad(p, (0, 0, 0, 1), mode="replicate")[..., 1:, :]
    d_right = 1.0 - (p * p_right).sum(dim=1, keepdim=True)
    d_down = 1.0 - (p * p_down).sum(dim=1, keepdim=True)
    d_left = F.pad(d_right, (1, 0, 0, 0))[..., :, :-1]
    d_up = F.pad(d_down, (0, 0, 1, 0))[..., :-1, :]
    return torch.stack([d_right, d_left, d_down, d_up], dim=0).amax(dim=0).clamp(0.0, 1.0)


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
        print(f"[*] Found {len(matches)} VOC2012 directories (this Kaggle upload ships the dataset more than "
              f"once):")
        for m in matches:
            print(f"      {m}")
        print(f"    Using ONLY the shallowest one, {matches[0]}; the other copies are never read, so nothing is "
              f"double-counted (the split counts printed next are checked against the official numbers).")
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
          f"(official: {off['segmentation_train']}/{off['segmentation_val']}) <- the fully-labelled subset (mask + "
          f"edge + boxes + labels); Segmentation-val is split into val/test and never enters training.")
    print("    With `use_partial_label_images`, the ImageSets/Main train+val images that are NOT in "
          "Segmentation-val additionally join TRAINING as box/label-only samples (mask/edge = ignore).")
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
    def update(self, pred_boxes, pred_logits, gt_boxes, gt_labels, gt_difficult):
        # v4: per-class sigmoid logits trained IoU-aware (QAIC), so the score already encodes localisation
        # quality -- no separate IoU-head factor to multiply in (that product is what produced 0.03-0.06 scores).
        scores = torch.sigmoid(pred_logits.float()).cpu().numpy()
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
        # v4.1: all K*K taps are sampled by ONE grid_sample over a (K*K*H, W) grid instead of K*K separate calls
        # (identical maths -- verified in --unit-test against the per-tap loop -- but one kernel launch and one
        # fp32 autocast copy of `x` instead of nine, in the block that runs at full LR resolution).
        disp = torch.tensor([[float(kx), float(ky)] for ky in range(-self.pad, self.pad + 1)
                             for kx in range(-self.pad, self.pad + 1)], device=x.device)   # (K*K, 2) row-major
        grid = base_grid.unsqueeze(1) + (offsets.permute(0, 1, 3, 4, 2).float() + disp.view(1, K * K, 1, 1, 2)) * scale
        s = F.grid_sample(x.contiguous(), grid.reshape(B, K * K * H, W, 2).to(x.dtype), mode="bilinear",
                          padding_mode="zeros", align_corners=False).view(B, C, K * K, H, W)
        taps = modulation.unsqueeze(1) * self.tap_weights.view(1, C, K * K, 1, 1)          # (B, C, K*K, H, W)
        return self.proj((s * taps.to(s.dtype)).sum(dim=2))


class PromptGuidedSDTA(nn.Module):
    """Prompt-guided spatial self-attention with 2-D RoPE and cosine attention.

    v4.1: on maps with more than `attn_global_max_tokens` tokens (the 128x128 and 64x64 stages at the default
    128px LR input) attention is computed inside non-overlapping `attn_window` x `attn_window` windows, shifted by
    half a window on every other block (Swin, Liu et al. ICCV'21; SwinIR for restoration). v3/v4 ran GLOBAL
    attention over all 16,384 tokens of the stride-1 stage: ~137 GFLOPs per image for two blocks -- more than
    the whole rest of the network -- and the main reason training ran at ~2 s/step. Global context is still
    provided by the global-attention stages 3-4 and by the pretrained semantic stream. The projections, prompts,
    cosine logits and RoPE are unchanged (RoPE encodes relative offsets, so it is exact inside a window), and so
    are all parameter shapes: checkpoints from v4 load as they are."""
    def __init__(self, dim: int, num_heads: int, config: OmniMorphConfig, shift: bool = False):
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
        self.shift = shift
        self._rope_cache: Dict[tuple, Tuple[torch.Tensor, torch.Tensor]] = {}
        self._mask_cache: Dict[tuple, torch.Tensor] = {}

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

    def _shift_mask(self, H: int, W: int, win: int, sh: int, device) -> torch.Tensor:
        """Swin attention mask for cyclically-shifted windows: (n_windows, L, L), True = may attend (tokens that
        were only brought together by the cyclic roll must not attend to each other)."""
        key = (H, W, win, sh, str(device))
        if key not in self._mask_cache:
            region = torch.zeros(H, W, device=device)
            cnt = 0
            for hs in (slice(0, -win), slice(-win, -sh), slice(-sh, None)):
                for ws in (slice(0, -win), slice(-win, -sh), slice(-sh, None)):
                    region[hs, ws] = cnt
                    cnt += 1
            ids = region.view(H // win, win, W // win, win).permute(0, 2, 1, 3).reshape(-1, win * win)
            self._mask_cache[key] = ids.unsqueeze(2) == ids.unsqueeze(1)
        return self._mask_cache[key]

    def _windowed(self, q: torch.Tensor, k: torch.Tensor, v: torch.Tensor, H: int, W: int, win: int) -> torch.Tensor:
        B, h, N, d = q.shape
        sh = win // 2 if self.shift else 0
        nh, nw = H // win, W // win

        def part(t):
            t = t.reshape(B, h, H, W, d)
            if sh:
                t = torch.roll(t, shifts=(-sh, -sh), dims=(2, 3))
            t = t.reshape(B, h, nh, win, nw, win, d).permute(0, 2, 4, 1, 3, 5, 6)
            return t.reshape(B * nh * nw, h, win * win, d)

        mask = None
        if sh:
            m = self._shift_mask(H, W, win, sh, q.device)                                # (nh*nw, L, L)
            mask = m.unsqueeze(0).expand(B, -1, -1, -1).reshape(B * nh * nw, 1, win * win, win * win)
        out = F.scaled_dot_product_attention(part(q), part(k), part(v), attn_mask=mask)
        out = out.reshape(B, nh, nw, h, win, win, d).permute(0, 3, 1, 4, 2, 5, 6).reshape(B, h, H, W, d)
        if sh:
            out = torch.roll(out, shifts=(sh, sh), dims=(2, 3))
        return out.reshape(B, h, N, d)

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
        win = self.cfg.attn_window
        if win > 0 and N > self.cfg.attn_global_max_tokens and H % win == 0 and W % win == 0:
            out = self._windowed(q, k, v, H, W, win)                         # (B,h,N,d)
        else:
            out = F.scaled_dot_product_attention(q, k, v)                   # (B,h,N,d)
        out = out.transpose(1, 2).reshape(B, N, C)
        out = out * (1.0 + torch.tanh(self.val_gate(p_pool)).unsqueeze(1))
        return self.proj(out, prompt).transpose(1, 2).reshape(B, C, H, W)


class HybridEncoderBlock(nn.Module):
    def __init__(self, dim: int, num_heads: int, config: OmniMorphConfig, drop_path: float = 0.0,
                 shift: bool = False):
        super().__init__()
        self.cfg = config
        self.norm1 = nn.GroupNorm(config.norm_groups, dim)
        self.spatial_deform = PromptGuidedDeformableConv(dim, config)
        self.norm2 = nn.GroupNorm(config.norm_groups, dim)
        self.sdta = PromptGuidedSDTA(dim, num_heads, config, shift=shift)
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
    """FPN-style top-down decoder with learned deformable alignment (unchanged from v3), extended in v4 with a
    second lateral per scale for the pretrained semantic stream (section 3b). The two laterals are summed *before*
    the shared GroupNorm/GELU, so LR-encoder and ImageNet features are fused at every scale with one 1x1
    projection each and no extra smoothing cost."""
    def __init__(self, in_dims: List[int], config: OmniMorphConfig, sem_dims: Optional[List[int]] = None):
        super().__init__()
        self.cfg = config
        pd = config.pixel_dec_dim
        self.laterals = nn.ModuleList([nn.Conv2d(d, pd, 1) for d in in_dims])
        self.sem_laterals = nn.ModuleList([nn.Conv2d(d, pd, 1) for d in sem_dims]) if sem_dims else None
        if self.sem_laterals is not None:
            assert len(sem_dims) == len(in_dims), "the semantic stream must provide one feature map per encoder stage"
        self.lateral_post = nn.ModuleList([
            nn.Sequential(nn.GroupNorm(config.norm_groups, pd), nn.GELU()) for _ in in_dims
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

    def forward(self, features: List[torch.Tensor],
                sem_features: Optional[List[torch.Tensor]] = None) -> List[torch.Tensor]:
        results, prev = [], None
        for i in reversed(range(len(features))):
            lateral = self.laterals[i](features[i])
            if self.sem_laterals is not None and sem_features is not None:
                s = self.sem_laterals[i](sem_features[i])
                if s.shape[-2:] != lateral.shape[-2:]:
                    s = F.interpolate(s, size=lateral.shape[-2:], mode="bilinear", align_corners=False)
                lateral = lateral + s.to(lateral.dtype)
            lateral = self.lateral_post[i](lateral)
            if prev is not None:
                lateral = lateral + self._deformable_align(prev, lateral, self.align_offsets[i])
            smoothed = self.smooth[i](lateral)
            results.insert(0, smoothed)
            prev = smoothed
        return results


# ============================================================================
# 3b. RESTORE-THEN-RECOGNISE (RtR): a dedicated restoration stream + a pretrained semantic stream
# ============================================================================
# Why: in v3 every task decoded from the same shared pixel-decoder tensor. The SR head therefore had no
# normalisation-free path from the LR pixels to the output (the long skip that carries high-frequency detail in
# every SR network since EDSR/RCAN), and the recognition heads had to learn ImageNet-level semantics from 1,464
# bicubic-degraded 128px images -- the "Predicted HR = blurred bicubic" and "hair labelled dog/cat" panels.
#
# RtR splits the network into two streams with *one-way* gradient flow in each direction:
#   restoration stream   LR --(RCAN-lite body, SFT-conditioned on the LR encoder)--> HR prediction
#   semantic stream      HR prediction (stop-gradient) --(ImageNet-pretrained CNN)--> multi-scale features
# The recognition stream sees the *restored* image, so better SR directly means better recognition input, while
# the stop-gradient keeps the four recognition losses from bending the reconstruction away from fidelity.
# Semantics still reach the restoration stream, but only through SFT modulation by the jointly-trained LR
# encoder (whose features the recognition losses do shape) -- information flows both ways, gradients do not.
#
# Lineage: RCAN (Zhang et al., ECCV'18) residual channel-attention blocks; SFT (Wang et al., CVPR'18) per-pixel
# affine conditioning, there driven by a separately trained segmentation network rather than a jointly-trained
# multi-task encoder; SR4IR (Kim et al., CVPR'24) feeds SR output to a recogniser but deliberately *backpropagates*
# the task loss into the SR network (task-driven perceptual loss). RtR inverts that coupling (stop-gradient into
# SR, SFT conditioning out of the shared encoder) because here PSNR/SSIM fidelity is itself one of the targets.
def _icnr_(conv: nn.Conv2d, upscale: int) -> None:
    """ICNR init (Aitken et al., 2017) for a conv feeding PixelShuffle: all r*r sub-pixels of an output channel
    start from the same kernel, so the shuffled output starts as a nearest-neighbour upsample of one conv --
    no checkerboard pattern at initialisation."""
    out_c, in_c, kh, kw = conv.weight.shape
    sub = torch.empty(out_c // (upscale ** 2), in_c, kh, kw)
    nn.init.kaiming_normal_(sub, mode="fan_in", nonlinearity="relu")
    with torch.no_grad():
        conv.weight.copy_(sub.repeat_interleave(upscale ** 2, dim=0))
        if conv.bias is not None:
            conv.bias.zero_()
    conv._custom_init = True


class ChannelAttention(nn.Module):
    def __init__(self, channels: int, reduction: int):
        super().__init__()
        hidden = max(4, channels // reduction)
        self.body = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Conv2d(channels, hidden, 1), nn.ReLU(inplace=True),
                                  nn.Conv2d(hidden, channels, 1), nn.Sigmoid())

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x * self.body(x)


class RCAB(nn.Module):
    """Residual channel-attention block (RCAN): conv-ReLU-conv-CA with an identity skip and NO normalisation
    (EDSR showed batch/group norm discards the range information SR needs)."""
    def __init__(self, channels: int, reduction: int):
        super().__init__()
        self.body = nn.Sequential(nn.Conv2d(channels, channels, 3, padding=1), nn.ReLU(inplace=True),
                                  nn.Conv2d(channels, channels, 3, padding=1), ChannelAttention(channels, reduction))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x + self.body(x)


class SFTLayer(nn.Module):
    """Spatial Feature Transform: per-pixel scale/shift of restoration features from a conditioning map.
    Zero-initialised output convs make it an exact identity at init."""
    def __init__(self, channels: int, cond_channels: int):
        super().__init__()
        self.shared = nn.Sequential(nn.Conv2d(cond_channels, channels, 1), nn.LeakyReLU(0.1, inplace=True))
        self.gamma = nn.Conv2d(channels, channels, 1)
        self.beta = nn.Conv2d(channels, channels, 1)
        for conv in (self.gamma, self.beta):
            nn.init.zeros_(conv.weight)
            nn.init.zeros_(conv.bias)
            conv._custom_init = True

    def forward(self, x: torch.Tensor, cond: torch.Tensor) -> torch.Tensor:
        h = self.shared(cond)
        return x * (1.0 + self.gamma(h)) + self.beta(h)


class RestorationStream(nn.Module):
    """RCAN-lite x4 super-resolution stream: shallow conv -> G residual groups (each SFT-conditioned on the LR
    encoder's first-stage features) -> long skip -> PixelShuffle x2 (mid-resolution deep supervision) ->
    PixelShuffle x2 -> residual on top of the bicubic upsample. No dropout, no normalisation, its own weight-decay
    group and its own gradient-clipping budget (see OmniMorphTrainer: Stream-Isolated Gradient Clipping)."""
    def __init__(self, config: OmniMorphConfig):
        super().__init__()
        C, r = config.rs_channels, config.pixel_shuffle_factor
        self.head = nn.Conv2d(config.in_channels, C, 3, padding=1)
        self.cond_proj = nn.Sequential(nn.Conv2d(config.embed_dims[0], C, 1), nn.LeakyReLU(0.1, inplace=True))
        self.groups = nn.ModuleList([
            nn.Sequential(*[RCAB(C, config.rs_ca_reduction) for _ in range(config.rs_blocks_per_group)],
                          nn.Conv2d(C, C, 3, padding=1))
            for _ in range(config.rs_groups)
        ])
        self.sfts = nn.ModuleList([SFTLayer(C, C) for _ in range(config.rs_groups)])
        self.body_tail = nn.Conv2d(C, C, 3, padding=1)
        self.up1 = nn.Sequential(nn.Conv2d(C, C * r * r, 3, padding=1), nn.PixelShuffle(r), nn.LeakyReLU(0.1, inplace=True))
        self.mid_head = nn.Conv2d(C, config.in_channels, 3, padding=1)
        self.up2 = nn.Sequential(nn.Conv2d(C, C * r * r, 3, padding=1), nn.PixelShuffle(r), nn.LeakyReLU(0.1, inplace=True))
        # C->C 3x3 refinement conv at the full output resolution (19 GFLOPs and ~130 MiB of saved activations per
        # image). EDSR/RCAN tails go straight to RGB, but dropping it here measurably cost PSNR (0.5-0.9 dB in the
        # overfit ablation), so it stays on by default -- see `rs_hr_refine`
        self.hr_conv = (nn.Sequential(nn.Conv2d(C, C, 3, padding=1), nn.LeakyReLU(0.1, inplace=True))
                        if config.rs_hr_refine else None)
        self.tail = nn.Conv2d(C, config.in_channels, 3, padding=1)
        self.grad_checkpoint = config.grad_checkpoint and config.checkpoint_restoration
        _icnr_(self.up1[0], r)
        _icnr_(self.up2[0], r)
        for conv in (self.mid_head, self.tail):            # start exactly at the bicubic upsample
            nn.init.zeros_(conv.weight)
            nn.init.zeros_(conv.bias)
            conv._custom_init = True
        for m in self.modules():
            if isinstance(m, nn.Conv2d) and not getattr(m, "_custom_init", False):
                nn.init.kaiming_normal_(m.weight, mode="fan_in", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
                m._custom_init = True
        with torch.no_grad():                                 # ESRGAN-style residual scaling at init
            for g in self.groups:
                for blk in g:
                    if isinstance(blk, RCAB):
                        blk.body[2].weight.mul_(0.1)

    def _group(self, gi: int, h: torch.Tensor, c: torch.Tensor) -> torch.Tensor:
        return self.groups[gi](self.sfts[gi](h, c))

    def forward(self, x_lr: torch.Tensor, cond: torch.Tensor, out_size: Tuple[int, int]):
        f0 = self.head(x_lr - 0.5)
        c = self.cond_proj(cond)
        if c.shape[-2:] != f0.shape[-2:]:
            c = F.interpolate(c, size=f0.shape[-2:], mode="bilinear", align_corners=False)
        h = f0
        for gi in range(len(self.groups)):
            if self.grad_checkpoint and self.training and torch.is_grad_enabled():
                h = h + checkpoint(self._group, gi, h, c, use_reentrant=False)
            else:
                h = h + self._group(gi, h, c)
        h = f0 + self.body_tail(h)                           # long skip
        mid_size = (out_size[0] // 2, out_size[1] // 2)
        f_mid = self.up1(h)
        if f_mid.shape[-2:] != mid_size:
            f_mid = F.interpolate(f_mid, size=mid_size, mode="bilinear", align_corners=False)
        mid_base = F.interpolate(x_lr, size=mid_size, mode="bicubic", align_corners=False).clamp(0.0, 1.0)
        pred_mid = mid_base + self.mid_head(f_mid)
        f_hr = self.up2(f_mid)
        if f_hr.shape[-2:] != tuple(out_size):
            f_hr = F.interpolate(f_hr, size=out_size, mode="bilinear", align_corners=False)
        if self.hr_conv is not None:
            f_hr = self.hr_conv(f_hr)
        base = F.interpolate(x_lr, size=out_size, mode="bicubic", align_corners=False).clamp(0.0, 1.0)
        return base + self.tail(f_hr), pred_mid, f_hr


class FrozenBatchNorm2dAct(FrozenBatchNorm2d):
    """torchvision's FrozenBatchNorm2d multiplies fp16 activations by fp32 statistics, which silently promotes
    every ResNet activation under AMP back to fp32 (double the memory of the whole semantic stream). Same frozen
    affine transform, evaluated in the activation's own dtype; identical state_dict."""
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        scale = self.weight * (self.running_var + self.eps).rsqrt()
        bias = self.bias - self.running_mean * scale
        return x * scale.view(1, -1, 1, 1).to(x.dtype) + bias.view(1, -1, 1, 1).to(x.dtype)


class SemanticBackbone(nn.Module):
    """ImageNet-pretrained recognition stream of RtR. Reads the restored HR canvas (stop-gradient), so with the
    default 4x setting its stride-4/8/16/32 features land exactly on the LR encoder's 1/1, 1/2, 1/4, 1/8 grids.
    Pretrained ResNets use FrozenBatchNorm2d (batch 8 is far too small for live BN statistics; this is the
    standard DETR / Deformable DETR / DINO practice) and keep stem+layer1 frozen; the whole stream trains at
    `backbone_lr_mult` x the base LR. If no ImageNet weights can be obtained (offline session, no
    `backbone_weights_path`), it falls back -- loudly -- to a randomly initialised GroupNorm variant, because a
    frozen-BN ResNet without pretrained statistics has no normalisation at all and diverges."""
    _TV_WEIGHTS = {"resnet18": "ResNet18_Weights", "resnet34": "ResNet34_Weights",
                   "resnet50": "ResNet50_Weights", "convnext_tiny": "ConvNeXt_Tiny_Weights"}

    def __init__(self, config: OmniMorphConfig):
        super().__init__()
        import torchvision.models as tvm
        name = config.backbone_name.lower()
        if name not in self._TV_WEIGHTS:
            raise ValueError(f"unsupported backbone_name '{config.backbone_name}' "
                             f"(choose one of {sorted(self._TV_WEIGHTS)} or 'none')")
        self.name = name
        self.pretrained_loaded = False
        net = None
        path = config.backbone_weights_path
        if path and os.path.isfile(path):
            try:
                net = self._build(tvm, name, pretrained=True)
                sd = torch.load(path, map_location="cpu", weights_only=True)
                if isinstance(sd, dict) and "state_dict" in sd:
                    sd = sd["state_dict"]
                missing, _unexpected = net.load_state_dict(sd, strict=False)
                missing = [k for k in missing if not k.endswith("num_batches_tracked")]
                if len(missing) > 0.1 * len(net.state_dict()):
                    raise RuntimeError(f"{len(missing)} parameters missing from '{path}' (e.g. {missing[:3]})")
                self.pretrained_loaded = True
                print(f"[*] Semantic stream: {name} ImageNet weights loaded from {path}")
            except Exception as e:
                print(f"[!] Semantic stream: could not load '{path}' ({type(e).__name__}: {e}).")
                net = None
        if net is None and config.backbone_pretrained:
            try:
                weights = getattr(tvm, self._TV_WEIGHTS[name]).DEFAULT
                net = self._build(tvm, name, pretrained=True, weights=weights)
                self.pretrained_loaded = True
                print(f"[*] Semantic stream: {name} ImageNet weights ({weights}) loaded.")
            except Exception as e:
                print(f"[!] Semantic stream: ImageNet weights for {name} unavailable ({type(e).__name__}: {e}). "
                      f"On Kaggle, enable Internet for the notebook or attach the torchvision checkpoint and set "
                      f"`backbone_weights_path`.")
                net = None
        if net is None:
            net = self._build(tvm, name, pretrained=False)
            print(f"[!] Semantic stream: {name} is RANDOMLY initialised -- segmentation/detection/classification "
                  f"quality will be far below what this architecture is designed for.")
        if name.startswith("resnet"):
            self.stem = nn.Sequential(net.conv1, net.bn1, net.relu, net.maxpool)
            self.stages = nn.ModuleList([net.layer1, net.layer2, net.layer3, net.layer4])
            mult = 4 if name == "resnet50" else 1
            self.out_dims = [64 * mult, 128 * mult, 256 * mult, 512 * mult]
            frozen = [self.stem, self.stages[0]]
        else:
            f = net.features
            self.stem = nn.Identity()
            self.stages = nn.ModuleList([nn.Sequential(f[0], f[1]), nn.Sequential(f[2], f[3]),
                                         nn.Sequential(f[4], f[5]), nn.Sequential(f[6], f[7])])
            self.out_dims = [96, 192, 384, 768]
            frozen = [self.stages[0]]
        if self.pretrained_loaded:
            for m in self.modules():
                m._custom_init = True                         # OmniMorphNet._init_weights must not touch these
            if config.backbone_freeze_stem:
                for mod in frozen:
                    for p in mod.parameters():
                        p.requires_grad_(False)
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1), persistent=False)
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1), persistent=False)

    @staticmethod
    def _build(tvm, name: str, pretrained: bool, weights=None) -> nn.Module:
        ctor = getattr(tvm, name)
        if name.startswith("resnet"):
            norm = FrozenBatchNorm2dAct if pretrained else (lambda c: nn.GroupNorm(32, c))
            return ctor(weights=weights, norm_layer=norm)
        return ctor(weights=weights, stochastic_depth_prob=0.1)

    def normalise(self, x: torch.Tensor) -> torch.Tensor:
        return (x - self.mean.to(x.dtype)) / self.std.to(x.dtype)

    def forward(self, x01: torch.Tensor) -> List[torch.Tensor]:
        x = self.stem(self.normalise(x01))
        feats = []
        for stage in self.stages:
            x = stage(x)
            feats.append(x)
        return feats


class PerceptualExtractor(nn.Module):
    """Frozen copy (taken at construction time, i.e. of the ImageNet weights, before any fine-tuning drift) of the
    semantic stream's first two stages, used for a small LPIPS-style feature-matching term on the SR output.
    Pixel losses alone regress towards the conditional mean (blur) under 4x ambiguity; a light feature term
    restores texture contrast at a small PSNR cost, which is why its weight is kept low by default."""
    def __init__(self, backbone: SemanticBackbone):
        super().__init__()
        self.stem = copy.deepcopy(backbone.stem)
        self.stage1 = copy.deepcopy(backbone.stages[0])
        self.stage2 = copy.deepcopy(backbone.stages[1])
        self.register_buffer("mean", backbone.mean.clone(), persistent=False)
        self.register_buffer("std", backbone.std.clone(), persistent=False)
        for p in self.parameters():
            p.requires_grad_(False)
        self.eval()

    def train(self, mode: bool = True):
        return super().train(False)                           # always frozen, including stochastic depth

    def forward(self, x01: torch.Tensor) -> List[torch.Tensor]:
        x = self.stem((x01 - self.mean.to(x01.dtype)) / self.std.to(x01.dtype))
        f1 = self.stage1(x)
        return [f1, self.stage2(f1)]


def build_perceptual_extractor(model: nn.Module, cfg: OmniMorphConfig) -> Optional[PerceptualExtractor]:
    sb = getattr(model, "semantic_backbone", None)
    if cfg.lambda_perceptual <= 0 or sb is None or not sb.pretrained_loaded:
        return None
    return PerceptualExtractor(sb)


# ============================================================================
# 4. ANCHOR-REFINED QUERY DECODER (+ ICCD v2 denoising)  AND  COMPLETE 5-TASK ARCHITECTURE
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
    Denoising queries (positives AND their contrastive negatives, v4) may attend to the matching queries and to
    each other; a deliberate simplification versus DN-DETR's multiple, mutually-isolated noise groups, since ICCD
    uses a single group per image."""
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
    """Content half of an ICCD denoising query: an embedding of its (possibly label-flipped) class. In v4 the
    noised box is no longer squeezed into this content vector -- it becomes the query's *reference anchor*,
    exactly where a matching query keeps its own learned anchor, so both kinds of query are refined by the same
    per-layer box-delta heads (DN-DETR's original design; v3's content-only box MLP left the decoder without the
    positional prior it is supposed to learn to refine)."""
    def __init__(self, dim: int, num_classes: int):
        super().__init__()
        self.label_embed = nn.Embedding(num_classes + 1, dim)   # index `num_classes` = padding / no label
        self.fuse = nn.Sequential(nn.Linear(dim, dim), nn.GELU(), nn.LayerNorm(dim))

    def forward(self, labels: torch.Tensor, valid: torch.Tensor) -> torch.Tensor:
        out = self.fuse(self.label_embed(labels.clamp(min=0)))
        return out * valid.unsqueeze(-1).to(out.dtype)


class MLP(nn.Module):
    def __init__(self, in_dim: int, hidden_dim: int, out_dim: int, num_layers: int):
        super().__init__()
        dims = [in_dim] + [hidden_dim] * (num_layers - 1) + [out_dim]
        self.layers = nn.ModuleList([nn.Linear(a, b) for a, b in zip(dims[:-1], dims[1:])])

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        for i, layer in enumerate(self.layers):
            x = layer(x)
            if i < len(self.layers) - 1:
                x = F.relu(x)
        return x


class QueryDecoder(nn.Module):
    """Object-query decoder with anchor boxes and layer-wise iterative box refinement.

    v3's queries were pure learned content vectors with a learned positional token, re-predicting every box from
    scratch at every layer. DAB-DETR (Liu et al., ICLR'22) and Deformable DETR (Zhu et al., ICLR'21) show that this
    is the main reason DETR-style decoders converge an order of magnitude slower than anchor-based detectors:
    cross-attention has no explicit notion of *where* a query is looking. Here every query carries a 4-D anchor
    (cx, cy, w, h); its positional query is an MLP of the anchor's sine embedding (in the same normalised-coordinate
    sine space as the memory's positional encoding, so query/key positions are directly comparable), and every
    layer predicts a delta in inverse-sigmoid space that refines the anchor for the next layer (detached between
    layers, as in Deformable DETR). Each layer cross-attends one pixel-decoder scale, cycling coarse -> fine.
    Classification is per-class sigmoid (IoU-aware, see MultiTaskLoss._vfl) with focal-prior bias init.
    ICCD's denoising queries ride along in the same pass with their noised GT boxes as anchors.

    Image-conditioned anchors (`use_query_selection`): learned anchors are the same for every image, so early in
    training the decoder emits image-agnostic boxes -- the false positives in empty regions of the qualitative
    dumps. Following Deformable DETR's two-stage proposals and DINO's "mixed query selection" (Zhang et al.,
    ICLR'23), every memory token of every scale predicts a class score and a box relative to a grid anchor sized
    by its scale; the top-`num_queries` tokens' boxes (detached) become this image's initial anchors, while the
    content queries stay learned. All proposals are supervised as one more Hungarian-matched output."""
    def __init__(self, config: OmniMorphConfig):
        super().__init__()
        self.cfg = config
        self.dim = config.pixel_dec_dim
        assert self.dim % 4 == 0
        self.heads = config.num_heads[1]
        L = config.num_refine_rounds
        self.layers = nn.ModuleList([DecoderLayer(self.dim, self.heads) for _ in range(L)])
        self.query_feat = nn.Embedding(config.num_queries, self.dim)
        self.use_query_selection = config.use_query_selection
        if not self.use_query_selection:                     # static learned anchors (DAB-DETR)
            anchors = torch.empty(config.num_queries, 4)
            anchors[:, :2].uniform_(0.05, 0.95)
            anchors[:, 2:].uniform_(0.1, 0.6)
            self.query_anchor = nn.Parameter(inverse_sigmoid(anchors))
        self.ref_point_head = MLP(2 * self.dim, self.dim, self.dim, 2)
        self.box_heads = nn.ModuleList([MLP(self.dim, self.dim, 4, 3) for _ in range(L)])
        self.cls_heads = nn.ModuleList([nn.Linear(self.dim, config.num_classes) for _ in range(L)])
        self.out_norm = nn.LayerNorm(self.dim)
        if self.use_query_selection:
            self.enc_proj = nn.Sequential(nn.Linear(self.dim, self.dim), nn.LayerNorm(self.dim))
            self.enc_cls_head = nn.Linear(self.dim, config.num_classes)
            self.enc_box_head = MLP(self.dim, self.dim, 4, 3)
        self._pe_cache: Dict[tuple, torch.Tensor] = {}
        self._anchor_cache: Dict[tuple, torch.Tensor] = {}

    def init_heads(self) -> None:
        """Called by OmniMorphNet._special_inits AFTER the generic init pass: focal prior p=0.01 on the class
        logits (Lin et al.), and zero box deltas so every layer starts by returning its anchor unchanged."""
        bias = -math.log((1.0 - 0.01) / 0.01)
        for head in self.cls_heads:
            nn.init.constant_(head.bias, bias)
        for head in self.box_heads:
            nn.init.zeros_(head.layers[-1].weight)
            nn.init.zeros_(head.layers[-1].bias)
        if self.use_query_selection:
            nn.init.constant_(self.enc_cls_head.bias, bias)
            nn.init.zeros_(self.enc_box_head.layers[-1].weight)
            nn.init.zeros_(self.enc_box_head.layers[-1].bias)

    def _pos_enc_2d(self, H: int, W: int, device) -> torch.Tensor:
        key = (H, W, str(device))
        if key not in self._pe_cache:
            ys = (torch.arange(H, device=device, dtype=torch.float32) + 0.5) / H
            xs = (torch.arange(W, device=device, dtype=torch.float32) + 0.5) / W
            yy, xx = torch.meshgrid(ys, xs, indexing="ij")
            pe = torch.cat([sine_embed(yy.reshape(-1), self.dim // 2), sine_embed(xx.reshape(-1), self.dim // 2)], dim=-1)
            self._pe_cache[key] = pe.unsqueeze(0)                                   # (1, HW, dim)
        return self._pe_cache[key]

    def _grid_anchors(self, shapes: List[Tuple[int, int]], device) -> torch.Tensor:
        """(N, 4) cxcywh grid anchors for the concatenated memory levels; `shapes` is ordered coarse -> fine and
        anchor size halves with every finer level (0.2, 0.1, 0.05 of the canvas), as in Deformable DETR."""
        key = (tuple(shapes), str(device))
        if key not in self._anchor_cache:
            anchors = []
            for lvl, (H, W) in enumerate(shapes):
                ys = (torch.arange(H, device=device, dtype=torch.float32) + 0.5) / H
                xs = (torch.arange(W, device=device, dtype=torch.float32) + 0.5) / W
                yy, xx = torch.meshgrid(ys, xs, indexing="ij")
                wh = torch.full_like(xx, 0.2 / (2.0 ** lvl))
                anchors.append(torch.stack([xx, yy, wh, wh], dim=-1).reshape(-1, 4))
            self._anchor_cache[key] = torch.cat(anchors, dim=0)
        return self._anchor_cache[key]

    def _select_queries(self, memory_levels: List[torch.Tensor]):
        """Returns (initial anchors (B, Q, 4) cxcywh, detached; dict of ALL proposals for the loss)."""
        mem = torch.cat([f.flatten(2).transpose(1, 2) for f in memory_levels], dim=1)        # (B, N, dim)
        anchors = self._grid_anchors([tuple(f.shape[-2:]) for f in memory_levels], mem.device)
        h = self.enc_proj(mem)
        logits = self.enc_cls_head(h)                                                         # (B, N, C)
        ref = torch.sigmoid(inverse_sigmoid(anchors).unsqueeze(0) + self.enc_box_head(h).float())
        top = logits.float().amax(dim=-1).topk(self.cfg.num_queries, dim=1).indices          # (B, Q)
        init_ref = torch.gather(ref, 1, top.unsqueeze(-1).expand(-1, -1, 4)).detach()
        return init_ref, {"boxes": _cxcywh_to_boxes(ref), "logits": logits}

    def _anchor_pos(self, ref: torch.Tensor) -> torch.Tensor:
        d = self.dim // 2
        emb = torch.cat([sine_embed(ref[..., 1], d), sine_embed(ref[..., 0], d),
                         sine_embed(ref[..., 2], d), sine_embed(ref[..., 3], d)], dim=-1)   # (y, x, w, h)
        return self.ref_point_head(emb)

    def forward(self, memory_levels: List[torch.Tensor], dn_content: Optional[torch.Tensor] = None,
                dn_ref: Optional[torch.Tensor] = None, dn_valid: Optional[torch.Tensor] = None
                ) -> Tuple[List[Dict[str, torch.Tensor]], Optional[Dict[str, torch.Tensor]]]:
        B = memory_levels[0].shape[0]
        Q = self.cfg.num_queries
        q = self.query_feat.weight.unsqueeze(0).expand(B, -1, -1)
        enc_out = None
        if self.use_query_selection:
            n_tokens = sum(f.shape[-2] * f.shape[-1] for f in memory_levels)
            assert n_tokens >= Q, f"query selection needs >= num_queries ({Q}) memory tokens, got {n_tokens}"
            ref, enc_out = self._select_queries(memory_levels)
        else:
            ref = torch.sigmoid(self.query_anchor.float()).unsqueeze(0).expand(B, -1, -1)
        attn_mask = None
        if dn_content is not None:
            n_dn = dn_content.shape[1]
            q = torch.cat([q, dn_content.to(q.dtype)], dim=1)
            ref = torch.cat([ref, dn_ref.float().clamp(1e-4, 1.0 - 1e-4)], dim=1)
            attn_mask = build_denoising_attn_mask(B, Q, n_dn, dn_valid, self.heads, q.device)
        outs = []
        for li, layer in enumerate(self.layers):
            feat = memory_levels[li % len(memory_levels)]
            _, _, H, W = feat.shape
            mem = feat.flatten(2).transpose(1, 2)
            mem_pos = self._pos_enc_2d(H, W, feat.device).to(mem.dtype)
            q_pos = self._anchor_pos(ref)
            q = layer(q, q_pos, mem, mem_pos, self_attn_mask=attn_mask)
            h = self.out_norm(q)
            new_ref = torch.sigmoid(inverse_sigmoid(ref) + self.box_heads[li](h).float())
            outs.append({"queries": h, "boxes": _cxcywh_to_boxes(new_ref), "logits": self.cls_heads[li](h)})
            ref = new_ref.detach()
        return outs, enc_out


class QueryPixelAffinityRefiner(nn.Module):
    """Prototype-Conditioned Segmentation Refinement (PCSR).

    The object-query decoder already runs on every forward pass to support detection and classification, but in
    v2 the dense segmentation head never saw it -- it is a purely local conv classifier, which is exactly the kind
    of thing that produces the wrong-class islands and holes seen inside otherwise-correct silhouettes in the v2
    qualitative dumps (no object-level consistency term anywhere in the segmentation path).

    Each matching query already has a class distribution over the 20 VOC classes + "no object" (v4: the
    detector's per-class sigmoid scores plus an explicit no-object probability 1 - max_c p_c, no new classifier).
    We project each query to a key vector and dot it against the pixel-decoder feature map to get a per-query
    spatial affinity map, then marginalise those affinity maps over classes using the SAME class probabilities
    (no-object -> segmentation background, class c -> segmentation class c+1). The result is added, with a
    zero-initialised learned gain, on top of the dense head's own logits -- so PCSR starts as an exact no-op and
    can only help once training shows it does.

    Lineage: inspired by Mask2Former's per-query dot-product mask logits, but marginalised over classes through
    the detector's own class scores rather than a 1:1 Hungarian query<->mask assignment, and fused additively with
    a parallel dense head instead of replacing it.
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
        r = config.pixel_shuffle_factor
        assert config.hr_image_size == config.lr_image_size * r * r, \
            "the restoration stream is a fixed x(pixel_shuffle_factor**2) upsampler: hr_image_size must equal it"
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
            for j in range(config.depths[i]):
                blocks.append(HybridEncoderBlock(config.embed_dims[i], config.num_heads[i], config, drop_path=dpr[b],
                                                 shift=(j % 2 == 1)))
                b += 1
            self.stages.append(nn.ModuleList(blocks))
            if i < len(config.embed_dims) - 1:
                self.downsamplers.append(nn.Sequential(
                    nn.Conv2d(config.embed_dims[i], config.embed_dims[i + 1], kernel_size=config.conv_kernel,
                              stride=config.conv_stride_down, padding=config.conv_padding),
                    nn.GroupNorm(config.norm_groups, config.embed_dims[i + 1]), nn.GELU(),
                ))
        pd = config.pixel_dec_dim
        # ---- Restore-then-Recognise (section 3b) ----
        self.restoration = RestorationStream(config)
        self.semantic_backbone = SemanticBackbone(config) if config.backbone_name.lower() != "none" else None
        sem_dims = self.semantic_backbone.out_dims if self.semantic_backbone is not None else None
        self.pixel_decoder = MultiScalePixelDecoder(config.embed_dims, config, sem_dims=sem_dims)
        self.query_decoder = QueryDecoder(config)
        self.dn_encoder = DenoisingQueryEncoder(pd, config.num_classes) if config.use_denoising else None
        self.global_fuse = nn.Sequential(nn.Linear(2 * pd, pd), nn.GELU())
        # ---- semantic segmentation (dense head + PCSR + PPSC, + deep supervision at 1/2 resolution) ----
        self.seg_dropout = nn.Dropout2d(config.head_dropout_base)     # p mutated at runtime by ATHM (section 8)
        self.seg_head = nn.Sequential(
            nn.Conv2d(pd, pd, kernel_size=config.conv_kernel, padding=config.conv_padding),
            nn.GroupNorm(config.norm_groups, pd), nn.GELU(),
            nn.Conv2d(pd, config.num_mask_classes, kernel_size=1),
        )
        self.seg_refiner = QueryPixelAffinityRefiner(pd, config.num_mask_classes, config.num_classes)
        self.aux_seg_head = nn.Conv2d(pd, config.num_mask_classes, kernel_size=1)
        # PPSC gain, passed through softplus -> always >= 0; softplus(-2) ~= 0.13 at init (see forward)
        self.seg_presence_gain = nn.Parameter(torch.tensor(-2.0))
        # ---- multi-label classification from pooled top-level features + queries ----
        self.cls_dropout = nn.Dropout(config.head_dropout_base)       # p mutated at runtime by ATHM
        self.cls_pre = nn.Linear(pd, pd)
        self.cls_act = nn.GELU()
        self.cls_out = nn.Linear(pd, config.num_classes)
        # ---- edges predicted at HR resolution (+ LDBC semantic boundary channel, see forward) ----
        # v4.1: both 512x512 inputs of the fusion conv are narrowed to `edge_branch_channels` first (v4 fed it
        # 2x64+1 channels at full resolution: 19.5 GFLOPs and ~225 MiB of activations per image for one edge map)
        eh, ec = config.edge_hidden_channels, config.edge_branch_channels
        self.edge_dropout = nn.Dropout2d(config.head_dropout_base)    # p mutated at runtime by ATHM
        self.edge_coarse = nn.Sequential(
            nn.Conv2d(pd, ec, kernel_size=config.conv_kernel, padding=config.conv_padding),
            nn.GroupNorm(config.norm_groups, ec), nn.GELU(),
        )
        self.edge_sr_proj = nn.Conv2d(config.rs_channels, ec, kernel_size=1)
        self.edge_fuse = nn.Sequential(
            nn.Conv2d(ec * 2 + 1, eh, kernel_size=config.conv_kernel, padding=config.conv_padding),
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
        for conv in (self.seg_head[-1], self.aux_seg_head):
            nn.init.normal_(conv.weight, std=0.01)
            nn.init.zeros_(conv.bias)
        nn.init.normal_(self.edge_fuse[-1].weight, std=0.01)
        nn.init.constant_(self.edge_fuse[-1].bias, -3.0)       # edges are sparse: start with a low edge prior
        self.query_decoder.init_heads()

    def set_task_health(self, health: Dict[str, float]) -> None:
        """Adaptive Task-Health Modulation (ATHM), model side: turns up head-only dropout for whichever task's
        validation metric is declining (see MultiTaskLoss.set_task_health for the loss-weight side and
        OmniMorphTrainer._update_athm for how `health` is computed). v4: only the segmentation / edge /
        classification heads are modulated. The restoration stream has no dropout at all (channel dropout inside
        an SR body hurts reconstruction -- Kong et al., CVPR'22) and dropout on decoder queries perturbs the very
        one-to-one assignment Hungarian matching relies on, so neither is touched."""
        cfg = self.config

        def p_for(h):
            return float(min(0.6, cfg.head_dropout_base + (1.0 - h) * cfg.head_dropout_max_extra))

        self.seg_dropout.p = p_for(health.get("seg", 1.0))
        self.edge_dropout.p = p_for(health.get("edge", 1.0))
        self.cls_dropout.p = p_for(health.get("cls", 1.0))

    def _stage_prompts(self, i: int, x: torch.Tensor) -> torch.Tensor:
        B = x.shape[0]
        delta = self.prompt_gens[i](x.mean(dim=(2, 3))).view(B, self.config.num_prompts, self.config.prompt_dim)
        return self.global_prompts + delta

    def forward(self, x_lr: torch.Tensor, dn_ref: Optional[torch.Tensor] = None,
                dn_labels: Optional[torch.Tensor] = None, dn_valid: Optional[torch.Tensor] = None
                ) -> Dict[str, Any]:
        cfg = self.config
        size = (cfg.hr_image_size, cfg.hr_image_size)
        x = self.stem((x_lr - 0.5) / 0.5)
        features = []
        for i in range(len(self.stages)):
            prompts = self._stage_prompts(i, x)
            ckpt = (cfg.grad_checkpoint and i < cfg.checkpoint_encoder_stages and self.training
                    and torch.is_grad_enabled())
            for block in self.stages[i]:
                # activation checkpointing on the high-resolution stages: their deformable taps, LoRA gates and
                # attention intermediates were ~45% of all saved activations; recomputing them in the backward
                # pass is cheap now that their attention is windowed
                x = checkpoint(block, x, prompts, use_reentrant=False) if ckpt else block(x, prompts)
            features.append(x)
            if i < len(self.downsamplers):
                x = self.downsamplers[i](x)

        # ---- (1) restoration stream: own normalisation-free LR->HR path, SFT-conditioned on the LR encoder ----
        pred_hr, pred_hr_mid, sr_feat_hr = self.restoration(x_lr, features[0], size)

        # ---- (2) semantic stream reads the RESTORED canvas (stop-gradient: recognition never bends SR) ----
        sem_feats = None
        if self.semantic_backbone is not None:
            if cfg.semantic_input == "restored":
                sem_src = pred_hr.detach().float().clamp(0.0, 1.0)
            else:
                sem_src = F.interpolate(x_lr, size=size, mode="bicubic", align_corners=False).clamp(0.0, 1.0)
            sem_feats = self.semantic_backbone(sem_src)
        ms = self.pixel_decoder(features, sem_feats)
        high_res_feat = ms[0]

        # ---- (3) anchor-refined query decoder (+ ICCD denoising queries during training) ----
        dn_content = None
        use_dn = dn_ref is not None and self.dn_encoder is not None
        if use_dn:
            dn_content = self.dn_encoder(dn_labels, dn_valid)
        dec, enc_out = self.query_decoder(list(reversed(ms[1:])), dn_content=dn_content,
                                          dn_ref=dn_ref if use_dn else None, dn_valid=dn_valid)
        Q = cfg.num_queries
        queries = dec[-1]["queries"][:, :Q]
        boxes, logits = dec[-1]["boxes"][:, :Q], dec[-1]["logits"][:, :Q]
        global_vec = self.global_fuse(torch.cat([ms[-1].mean(dim=(2, 3)), queries.mean(dim=1)], dim=-1))

        # ---- classification (computed before segmentation, which uses it as a presence prior) ----
        cls_feat = self.cls_dropout(global_vec)
        pred_cls = self.cls_out(self.cls_act(self.cls_pre(cls_feat)))

        # ---- segmentation: dense head + PCSR + Presence-Prior Segmentation Calibration (PPSC) ----
        dense_logits = self.seg_head(self.seg_dropout(high_res_feat))
        det_probs = torch.sigmoid(logits.float()).detach()     # detached: segmentation must not reshape the
        # detector's own score calibration (an explicit interference-control choice, as in v3)
        query_probs = torch.cat([det_probs, 1.0 - det_probs.amax(dim=-1, keepdim=True)], dim=-1)
        seg_logits = dense_logits.float() + self.seg_refiner(high_res_feat, queries, query_probs)
        if cfg.use_presence_prior:
            # PPSC: p(class c at pixel | image) ∝ p(pixel looks like c) * p(c present in image)  ->  add
            # g * log sigmoid(cls_logit_c) to the c-th segmentation logit (background untouched), g = softplus(.)
            # >= 0 learned. A class the image-level head is confident is ABSENT can no longer win an island of
            # pixels (the v3 "hair -> dog/cat" failure), while a present class is unaffected (log sigma -> 0).
            # Not detached on purpose: segmentation evidence also sharpens the image-level head.
            # Lineage: EncNet's SE-loss (Zhang et al., CVPR'18) uses image-level presence to re-weight feature
            # channels; here it enters as an explicit, gain-controlled Bayesian log-prior on the logits instead.
            prior = F.softplus(self.seg_presence_gain) * F.logsigmoid(pred_cls.float())
            prior = torch.cat([torch.zeros_like(prior[:, :1]), prior], dim=1)
            seg_logits = seg_logits + prior[:, :, None, None]
        pred_masks = F.interpolate(seg_logits, size=size, mode="bilinear", align_corners=False)

        # ---- edges: Label-Disagreement Boundary Coupling (LDBC) ----
        # The v3 edge head fired on every intensity edge (CPU case, faces, shirt print) because nothing told it
        # which edges belong to annotated objects. LDBC feeds it one extra channel: the exact probability that a
        # pixel and its 4-neighbour carry DIFFERENT segmentation labels, 1 - sum_c p_c(x) p_c(x+d), maxed over
        # neighbours -- a closed-form, differentiable semantic boundary computed from the network's own
        # segmentation posterior. The edge loss flows back into segmentation through it at a reduced scale
        # (`ldbc_grad_to_seg`), sharpening segmentation boundaries without letting the edge loss dominate.
        # Lineage: Gated-SCNN (Takikawa et al., ICCV'19) couples a shape stream to segmentation through learned
        # gates plus a dual-task regulariser; LDBC replaces both with this analytic boundary probability.
        boundary = label_disagreement_boundary(grad_scale(seg_logits, cfg.ldbc_grad_to_seg))
        boundary = F.interpolate(boundary, size=size, mode="bilinear", align_corners=False)
        edge_coarse = F.interpolate(self.edge_coarse(self.edge_dropout(high_res_feat)), size=size,
                                    mode="bilinear", align_corners=False)
        edge_sr = self.edge_sr_proj(sr_feat_hr.detach())
        pred_edges = self.edge_fuse(torch.cat([edge_coarse, edge_sr.to(edge_coarse.dtype),
                                               (2.0 * boundary - 1.0).to(edge_coarse.dtype)], dim=1))

        out = {
            "pred_hr": pred_hr, "pred_hr_mid": pred_hr_mid, "pred_masks": pred_masks, "pred_cls": pred_cls,
            "pred_edges": pred_edges, "pred_det_boxes": boxes, "pred_det_logits": logits, "queries": queries,
        }
        if use_dn:
            out["dn_layers"] = [{"boxes": d["boxes"][:, Q:], "logits": d["logits"][:, Q:]} for d in dec]
        if self.training:
            out["pred_masks_aux"] = F.interpolate(self.aux_seg_head(ms[1]), size=size, mode="bilinear",
                                                  align_corners=False)
            out["aux_det"] = [{"boxes": d["boxes"][:, :Q], "logits": d["logits"][:, :Q]} for d in dec[:-1]]
            if enc_out is not None:
                out["aux_det"].append(enc_out)               # all query-selection proposals, Hungarian-matched
        return out

    @torch.no_grad()
    def forward_tta(self, x_lr: torch.Tensor) -> Dict[str, Any]:
        """Horizontal-flip test-time self-ensemble (as EDSR+/RCAN+ do for SR) for the dense outputs and the
        image-level classifier. Detection keeps the un-flipped pass: merging two sets of one-to-one DETR
        predictions would need its own box-fusion step and is deliberately not attempted here."""
        out = self.forward(x_lr)
        out_f = self.forward(torch.flip(x_lr, dims=[-1]))
        for k in ("pred_hr", "pred_hr_mid", "pred_masks", "pred_edges"):
            out[k] = 0.5 * (out[k] + torch.flip(out_f[k], dims=[-1]))
        out["pred_cls"] = 0.5 * (out["pred_cls"] + out_f["pred_cls"])
        return out


# ============================================================================
# 5. ICCD v2 -- IoU-CONSISTENT CURRICULUM DENOISING: ground-truth noising utility
# ============================================================================
def build_dn_batch(gt_boxes: List[torch.Tensor], gt_labels: List[torch.Tensor], cfg: OmniMorphConfig,
                    noise_scale: float, device) -> Optional[Dict[str, torch.Tensor]]:
    """Builds one padded batch of noised decoder queries (+ their clean reconstruction targets) from the ragged
    per-image ground truth. Slots [0, M) are positives; with `dn_use_negatives`, slots [M, 2M) are contrastive
    negatives of the same objects (DINO's CDN, Zhang et al. ICLR'23: corner noise strictly larger than any
    positive's, supervised as "no object"), which teaches the decoder to *reject* near-duplicates -- the
    duplicated, un-suppressed boxes of the v2/v3 dumps. Noise is DINO-style per-corner jitter proportional to the
    box's half-extent, scaled by `noise_scale`, which the Trainer anneals coarse -> fine (the curriculum half of
    ICCD). What is NOT built here any more is v3's `target_iou` = IoU(noised input, GT): that measured the quality
    of what a query was *handed*, not of what it *predicted*, and trained the score head to under-estimate refined
    boxes. ICCD v2 computes the IoU-consistency target from the decoder's own output box inside the loss
    (MultiTaskLoss.get_dn_loss) instead."""
    B = len(gt_boxes)
    M = cfg.dn_max_gt_per_image
    groups = 2 if cfg.dn_use_negatives else 1
    N = groups * M
    dn_ref = torch.zeros(B, N, 4, device=device)
    dn_labels = torch.full((B, N), cfg.num_classes, dtype=torch.long, device=device)
    valid = torch.zeros(B, N, dtype=torch.bool, device=device)
    is_pos = torch.zeros(B, N, dtype=torch.bool, device=device)
    target_boxes_xyxy = torch.zeros(B, N, 4, device=device)
    target_labels = torch.full((B, N), cfg.num_classes, dtype=torch.long, device=device)
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
        b = boxes[idx].to(device).float()     # xyxy, normalised
        l = labels[idx].to(device)
        half = (b[:, 2:] - b[:, :2]).clamp(min=1e-4).repeat(1, 2) / 2.0
        for g in range(groups):
            sign = torch.randint(0, 2, (n, 4), device=device).float() * 2.0 - 1.0
            part = torch.rand(n, 4, device=device)
            if g == 1:
                part = part + 1.0                 # negatives: strictly larger perturbation than any positive
            noisy = (b + sign * part * half * noise_scale).clamp(0.0, 1.0)
            x1, x2 = torch.min(noisy[:, 0], noisy[:, 2]), torch.max(noisy[:, 0], noisy[:, 2])
            y1, y2 = torch.min(noisy[:, 1], noisy[:, 3]), torch.max(noisy[:, 1], noisy[:, 3])
            ref = torch.stack([(x1 + x2) / 2, (y1 + y2) / 2, (x2 - x1).clamp(min=1e-3), (y2 - y1).clamp(min=1e-3)], -1)
            noisy_l = l.clone()
            flip_mask = torch.rand(n, device=device) < cfg.dn_label_noise_prob
            if flip_mask.any() and cfg.num_classes > 1:
                rand_l = torch.randint(0, cfg.num_classes, (n,), device=device)
                noisy_l = torch.where(flip_mask, rand_l, noisy_l)
            sl = slice(g * M, g * M + n)
            dn_ref[i, sl] = ref.clamp(1e-4, 1.0)
            dn_labels[i, sl] = noisy_l
            valid[i, sl] = True
            is_pos[i, sl] = (g == 0)
            target_boxes_xyxy[i, sl] = b
            target_labels[i, sl] = l
    if not any_valid:
        return None
    return {"dn_ref": dn_ref, "dn_labels": dn_labels, "valid": valid, "is_pos": is_pos,
            "target_boxes_xyxy": target_boxes_xyxy, "target_labels": target_labels}


# ============================================================================
# 6. LOSS FUNCTIONS
# ============================================================================
class MultiTaskLoss(nn.Module):
    def __init__(self, config: OmniMorphConfig, perceptual: Optional[PerceptualExtractor] = None):
        super().__init__()
        self.cfg = config
        seg_w = torch.ones(config.num_mask_classes)
        seg_w[0] = config.seg_bg_weight
        self.register_buffer("seg_class_weights", seg_w, persistent=False)
        self.register_buffer("edge_pos_weight", torch.tensor([config.edge_pos_weight]), persistent=False)
        self.register_buffer("ssim_window", self._gaussian_window(config.ssim_kernel, config.ssim_sigma,
                                                                  config.in_channels), persistent=False)
        self.register_buffer("pyramid_kernel", self._gaussian_pyramid_kernel(config.in_channels), persistent=False)
        self.bce_loss = nn.BCEWithLogitsLoss()
        self.perceptual = perceptual
        self.task_health: Dict[str, float] = {}     # updated once per epoch by the Trainer (ATHM, section 8)
        self.quality_exponent = 0.0                 # QAIC beta, annealed 0 -> 1 by the Trainer (see _vfl)

    # ---- Adaptive Task-Health Modulation (loss-weight side; see OmniMorphNet.set_task_health for the other) ----
    def set_task_health(self, health: Dict[str, float]) -> None:
        self.task_health = dict(health)

    def _eff_lambda(self, task: str, base: float) -> float:
        return base * self.task_health.get(task, 1.0)

    def set_quality_exponent(self, beta: float) -> None:
        self.quality_exponent = float(min(max(beta, 0.0), 1.0))

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

    def perceptual_loss(self, pred: torch.Tensor, target: torch.Tensor, valid_mask: torch.Tensor) -> torch.Tensor:
        """LPIPS-style distance (Zhang et al., CVPR'18, without the learned per-channel weights): squared L2
        between channel-unit-normalised frozen ImageNet features, masked to the letterbox's valid region."""
        sc = self.cfg.perceptual_scale
        if sc != 1.0:
            size = (max(8, int(pred.shape[-2] * sc)), max(8, int(pred.shape[-1] * sc)))
            pred = F.interpolate(pred, size=size, mode="bilinear", align_corners=False, antialias=True)
            target = F.interpolate(target, size=size, mode="bilinear", align_corners=False, antialias=True)
            valid_mask = F.interpolate(valid_mask, size=size, mode="nearest")
        use_amp = pred.is_cuda
        with torch.autocast(device_type=pred.device.type, dtype=torch.float16 if use_amp else torch.bfloat16,
                            enabled=use_amp):
            feats_p = self.perceptual(pred)
            with torch.no_grad():
                feats_t = self.perceptual(target)
        total = pred.new_zeros(())
        for fp, ft in zip(feats_p, feats_t):
            fp = F.normalize(fp.float(), dim=1, eps=1e-6)
            ft = F.normalize(ft.float(), dim=1, eps=1e-6)
            vm = F.interpolate(valid_mask, size=fp.shape[-2:], mode="nearest")
            total = total + ((fp - ft).pow(2).sum(dim=1, keepdim=True) * vm).sum() / vm.sum().clamp(min=1.0)
        return total / max(len(feats_p), 1)

    # ---- segmentation ----
    def seg_ce(self, logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
        """Weighted, label-smoothed, ignore-aware CE. Guarded for batches whose masks are entirely `ignore` (v4's
        box/label-only training images, a fully-padded crop): F.cross_entropy returns 0/0 = NaN there, which the
        trainer's non-finite check would have silently turned into a skipped optimisation step."""
        if not bool((target != self.cfg.ignore_index).any()):
            return logits.sum() * 0.0
        return F.cross_entropy(logits, target, weight=self.seg_class_weights, ignore_index=self.cfg.ignore_index,
                               label_smoothing=self.cfg.label_smoothing_seg)

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
        """Hungarian matching with the sigmoid-focal classification cost of Deformable DETR (the cost the
        classification loss below is actually consistent with), plus L1 and GIoU box costs."""
        cfg = self.cfg
        a, g = cfg.focal_alpha, cfg.focal_gamma
        B = pred_boxes.shape[0]
        empty = torch.empty(0, dtype=torch.int64, device=pred_boxes.device)
        costs: List[Optional[torch.Tensor]] = []
        for i in range(B):
            if len(gt_boxes[i]) == 0:
                costs.append(None)
                continue
            prob = pred_logits[i].float().sigmoid()
            out_bbox = pred_boxes[i]
            tgt_bbox, tgt_ids = gt_boxes[i], gt_labels[i]
            neg_cost = (1 - a) * prob.pow(g) * -(1 - prob + 1e-8).log()
            pos_cost = a * (1 - prob).pow(g) * -(prob + 1e-8).log()
            cost_class = pos_cost[:, tgt_ids] - neg_cost[:, tgt_ids]
            cost_bbox = torch.cdist(out_bbox, tgt_bbox, p=1)
            cost_giou = -generalized_box_iou(out_bbox, tgt_bbox)
            C = cfg.lambda_bbox * cost_bbox + cfg.lambda_giou * cost_giou + cfg.lambda_det_ce * cost_class
            costs.append(torch.nan_to_num(C, nan=1e6, posinf=1e6, neginf=-1e6))
        # ONE device->host transfer for the whole batch (v4 synchronised once per image per decoder output, i.e.
        # ~56 GPU stalls per step at batch 8 with 6 layers + the proposal output)
        present = [c for c in costs if c is not None]
        flat = torch.cat([c.reshape(-1) for c in present]).cpu().numpy() if present else None
        indices, offset = [], 0
        for c in costs:
            if c is None:
                indices.append((empty, empty))
                continue
            n = c.numel()
            src_ind, tgt_ind = linear_sum_assignment(flat[offset:offset + n].reshape(c.shape))
            offset += n
            indices.append((torch.as_tensor(src_ind, dtype=torch.int64, device=pred_boxes.device),
                            torch.as_tensor(tgt_ind, dtype=torch.int64, device=pred_boxes.device)))
        return indices

    def _vfl(self, logits: torch.Tensor, pos_mask: torch.Tensor, quality: torch.Tensor) -> torch.Tensor:
        """Quality-Annealed IoU-aware Classification (QAIC) -- the fix for the 0.03-0.06 scores.

        v3 scored a box as softmax-focal-probability x sigmoid(IoU head): two separately under-confident numbers
        multiplied together. v4 has ONE per-class sigmoid score whose training target for a matched query is the
        localisation quality of its own box, q = IoU(pred, GT)^beta (Varifocal loss, Zhang et al. CVPR'21: BCE
        towards q, positives weighted by q, negatives by alpha*p^gamma), so a confident score *means* a
        well-localised box and no product is needed. The new part is beta: Varifocal / Stable-DINO (Liu et al.,
        ICCV'23) / Align-DETR use a fixed target, but early in DETR training matched IoUs are near zero, which
        would make every positive target ~0 and stall class learning. beta is annealed 0 -> 1 over
        `quality_anneal_epochs` (Trainer), so training starts with hard 1/0 labels (fast recognition) and ends
        fully IoU-calibrated; the matching branch and ICCD's denoising queries share the same schedule.
        Returns the SUM (caller normalises by the number of GT boxes)."""
        cfg = self.cfg
        p = torch.sigmoid(logits)
        target = torch.where(pos_mask, quality, torch.zeros_like(quality))
        weight = torch.where(pos_mask, quality, cfg.vfl_alpha * p.detach().pow(cfg.focal_gamma))
        bce = F.binary_cross_entropy_with_logits(logits, target, reduction="none")
        return (bce * weight).sum()

    def get_det_loss(self, pred_boxes, pred_logits, gt_boxes, gt_labels, num_boxes):
        beta = self.quality_exponent
        indices = self.match(pred_boxes, pred_logits, gt_boxes, gt_labels)
        B, Q, C = pred_logits.shape
        pos_mask = torch.zeros(B, Q, C, dtype=torch.bool, device=pred_logits.device)
        quality = torch.zeros(B, Q, C, device=pred_logits.device)
        src_boxes, tgt_boxes = [], []
        for i, (src, tgt) in enumerate(indices):
            if len(src) == 0:
                continue
            sb, tb = pred_boxes[i, src], gt_boxes[i][tgt]
            _, iou = paired_box_giou(sb.detach(), tb)
            lbl = gt_labels[i][tgt]
            pos_mask[i, src, lbl] = True
            quality[i, src, lbl] = iou.clamp(min=1e-2).pow(beta)
            src_boxes.append(sb)
            tgt_boxes.append(tb)
        loss_ce = self._vfl(pred_logits.reshape(-1, C), pos_mask.reshape(-1, C), quality.reshape(-1, C)) / num_boxes
        loss_bbox = pred_boxes.sum() * 0.0
        loss_giou = pred_boxes.sum() * 0.0
        if src_boxes:
            sb, tb = torch.cat(src_boxes), torch.cat(tgt_boxes)
            giou, _ = paired_box_giou(sb, tb)
            loss_bbox = F.l1_loss(sb, tb, reduction="sum") / num_boxes
            loss_giou = (1.0 - giou).sum() / num_boxes
        return loss_ce, loss_bbox, loss_giou

    def _weighted_det(self, parts):
        ce, bbox, giou = parts
        c = self.cfg
        return c.lambda_det_ce * ce + c.lambda_bbox * bbox + c.lambda_giou * giou

    # ---- ICCD v2: denoising queries, supervised directly at EVERY decoder layer (no Hungarian matching --
    #      correspondence is by construction). Positives reconstruct box + label, with the QAIC quality target
    #      computed from the query's OWN refined output box (the IoU-consistency term, now measuring the right
    #      thing); contrastive negatives are pushed to "no object" ----
    def get_dn_loss(self, dn_layers: List[Dict[str, torch.Tensor]], dn_batch: Dict[str, torch.Tensor]):
        cfg = self.cfg
        beta = self.quality_exponent
        valid = dn_batch["valid"]
        pos = valid & dn_batch["is_pos"]
        n_pos = float(max(int(pos.sum()), 1))
        tgt_boxes, tgt_labels = dn_batch["target_boxes_xyxy"], dn_batch["target_labels"]
        rows = valid.reshape(-1)
        total = None
        last = None
        for li, layer in enumerate(dn_layers):
            boxes, logits = layer["boxes"].float(), layer["logits"].float()
            C = logits.shape[-1]
            pos_mask = torch.zeros_like(logits, dtype=torch.bool)
            quality = torch.zeros_like(logits)
            loss_bbox = boxes.sum() * 0.0
            loss_giou = boxes.sum() * 0.0
            if bool(pos.any()):
                pb, tb = boxes[pos], tgt_boxes[pos]
                giou, _ = paired_box_giou(pb, tb)
                _, iou = paired_box_giou(pb.detach(), tb)
                b_idx, s_idx = pos.nonzero(as_tuple=True)
                lbl = tgt_labels[pos]
                pos_mask[b_idx, s_idx, lbl] = True
                quality[b_idx, s_idx, lbl] = iou.clamp(min=1e-2).pow(beta)
                loss_bbox = F.l1_loss(pb, tb, reduction="sum") / n_pos
                loss_giou = (1.0 - giou).sum() / n_pos
            loss_cls = self._vfl(logits.reshape(-1, C)[rows], pos_mask.reshape(-1, C)[rows],
                                 quality.reshape(-1, C)[rows]) / n_pos
            layer_loss = cfg.lambda_dn_cls * loss_cls + cfg.lambda_dn_bbox * loss_bbox + cfg.lambda_dn_giou * loss_giou
            w = 1.0 if li == len(dn_layers) - 1 else cfg.lambda_aux_det
            total = w * layer_loss if total is None else total + w * layer_loss
            last = (loss_cls, loss_bbox, loss_giou)
        return total, last[0], last[1], last[2]

    def forward(self, predictions: Dict[str, Any], targets: Dict[str, Any],
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
        loss_perc = pred_hr.sum() * 0.0
        if self.perceptual is not None and cfg.lambda_perceptual > 0:
            loss_perc = self.perceptual_loss(pred_hr, targets["hr_image"], valid_mask)
            loss_rec = loss_rec + cfg.lambda_perceptual * loss_perc
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
        loss_mask_ce = self.seg_ce(pred_masks, target_mask)
        loss_mask_dice = self.dice_loss(pred_masks, target_mask)
        loss_seg = loss_mask_ce * cfg.lambda_mask_ce + loss_mask_dice * cfg.lambda_mask_dice
        loss_seg_main = loss_seg
        if "pred_masks_aux" in predictions:
            aux_ce = self.seg_ce(predictions["pred_masks_aux"].float(), target_mask)
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

        # ---- detection (+ deep supervision of every intermediate decoder layer) ----
        gt_boxes, gt_labels = targets["boxes"], targets["box_labels"]
        num_boxes = float(max(sum(len(b) for b in gt_boxes), 1))
        main_parts = self.get_det_loss(predictions["pred_det_boxes"].float(), predictions["pred_det_logits"].float(),
                                       gt_boxes, gt_labels, num_boxes)
        loss_det = self._weighted_det(main_parts)
        loss_det_main = loss_det
        for aux in predictions.get("aux_det", []):
            parts = self.get_det_loss(aux["boxes"].float(), aux["logits"].float(), gt_boxes, gt_labels, num_boxes)
            loss_det = loss_det + cfg.lambda_aux_det * self._weighted_det(parts)
        loss_det_ce, loss_bbox, loss_giou = main_parts

        # ---- ICCD v2 denoising (training-only auxiliary; NOT health-modulated) ----
        loss_dn = pred_hr.sum() * 0.0
        loss_dn_cls = loss_dn_bbox = loss_dn_giou = pred_hr.sum() * 0.0
        if dn_batch is not None and "dn_layers" in predictions:
            loss_dn, loss_dn_cls, loss_dn_bbox, loss_dn_giou = self.get_dn_loss(predictions["dn_layers"], dn_batch)

        # ATHM: down-weight (never below `athm_health_floor`) whichever task's own validation metric is declining;
        # ICCD's denoising loss is deliberately excluded -- it exists specifically to fix detection's collapse, so
        # damping it exactly when detection looks unhealthy would be self-defeating.
        total_loss = (self._eff_lambda("rec", cfg.lambda_rec) * loss_rec
                      + self._eff_lambda("seg", 1.0) * loss_seg
                      + self._eff_lambda("cls", 1.0) * loss_cls
                      + self._eff_lambda("edge", 1.0) * loss_edge
                      + self._eff_lambda("det", 1.0) * loss_det
                      + loss_dn)
        # `loss_main`: the same terms the validation pass computes (final outputs only -- no denoising queries,
        # no intermediate decoder layers, no query-selection proposals, no auxiliary segmentation head). Training
        # minimises `loss_total`, but only `loss_main` is comparable between the train and val columns of the log:
        # v4 printed `loss_total` as T-Loss, which at ~13 detection outputs per step looked like an 8x train/val gap.
        loss_main = (self._eff_lambda("rec", cfg.lambda_rec) * loss_rec
                     + self._eff_lambda("seg", 1.0) * loss_seg_main
                     + self._eff_lambda("cls", 1.0) * loss_cls
                     + self._eff_lambda("edge", 1.0) * loss_edge
                     + self._eff_lambda("det", 1.0) * loss_det_main)

        d = lambda t: t.detach()
        return total_loss, {
            "loss_total": d(total_loss), "loss_main": d(loss_main), "loss_rec": d(loss_rec), "loss_l1": d(l1_val), "loss_ssim": d(ssim_loss_val),
            "loss_pyramid": d(pyramid_val), "loss_perceptual": d(loss_perc), "loss_mid_sr": d(loss_mid),
            "loss_seg_ce": d(loss_mask_ce), "loss_seg_dice": d(loss_mask_dice), "loss_cls": d(loss_cls),
            "loss_edge": d(loss_edge), "loss_det": d(loss_det), "loss_det_ce": d(loss_det_ce),
            "loss_bbox": d(loss_bbox), "loss_giou": d(loss_giou),
            "loss_dn": d(loss_dn), "loss_dn_cls": d(loss_dn_cls), "loss_dn_bbox": d(loss_dn_bbox),
            "loss_dn_giou": d(loss_dn_giou),
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

    Which images this trains on: the official VOC2012 trainval package has 17,125 images (JPEGImages /
    Annotations); only the 1,464 + 1,449 = 2,913 listed in ImageSets/Segmentation/{train,val}.txt have a
    SegmentationClass/SegmentationObject mask. val/test are always carved out of Segmentation-val. v3 trained on
    Segmentation-train alone, i.e. its detector and classifier saw 1,464 images. v4 ("mixed supervision") also
    trains on every ImageSets/Main train+val image that is NOT in Segmentation-val (~10k extra images with
    complete box/label annotations): their mask and edge targets are all `ignore`, so they supervise SR,
    classification and detection only. `full_label_indices` / `partial_label_indices` expose the two groups to
    MixedSupervisionBatchSampler, which keeps a fixed per-batch quota of fully-labelled images. See
    `VOC2012_OFFICIAL_COUNTS`, `resolve_voc2012_root` and `describe_voc2012_root` (section 2) for how `root` is
    located and cross-checked against the official numbers.
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
        self.image_ids: List[str] = []
        self.full_label_indices: List[int] = []
        self.partial_label_indices: List[int] = []
        extra_ids: List[str] = []
        try:
            if split == "train":
                seg_ids = self._read_ids("train.txt")
                self._warn_if_off_official(len(seg_ids), off["segmentation_train"], "train")
                if config.use_partial_label_images:
                    extra_ids = self._read_partial_label_ids(set(seg_ids))
            elif not config.separate_test_split:
                seg_ids = self._read_ids("val.txt")     # legacy behaviour: test == val (leaky)
                self._warn_if_off_official(len(seg_ids), off["segmentation_val"], "val")
            else:
                all_val = self._read_ids("val.txt")
                self._warn_if_off_official(len(all_val), off["segmentation_val"], "val (pre train/test split)")
                shuffled = all_val[:]
                random.Random(config.seed).shuffle(shuffled)
                n_val = int(round(len(shuffled) * config.val_fraction))
                seg_ids = sorted(shuffled[:n_val]) if split == "val" else sorted(shuffled[n_val:])
        except (FileNotFoundError, OSError) as e:
            print(f"[*] Dataset split not found: {e}. Ensure VOC2012 is extracted correctly.")
            return
        seg_ids = self._drop_missing(seg_ids, split)
        extra_ids = self._drop_missing(extra_ids, f"{split} (box/label-only)")
        self.image_ids = seg_ids + extra_ids
        self.full_label_indices = list(range(len(seg_ids)))
        self.partial_label_indices = list(range(len(seg_ids), len(self.image_ids)))

    def _drop_missing(self, ids: List[str], label: str) -> List[str]:
        # a listed id with no matching JPEGImages file (partial/corrupted download) is dropped here, with a
        # count printed, rather than crashing deep inside a DataLoader worker at some later, random epoch.
        missing = {i for i in ids if not os.path.isfile(os.path.join(self.img_dir, f"{i}.jpg"))}
        if missing:
            print(f"[!] {len(missing)} image id(s) in the '{label}' split have no matching JPEGImages/*.jpg "
                  f"file and were dropped (e.g. {sorted(missing)[:3]}).")
            ids = [i for i in ids if i not in missing]
        return ids

    def _read_partial_label_ids(self, seg_train_ids: set) -> List[str]:
        """ImageSets/Main train+val ids (complete box/label annotations, no mask) that are neither already in the
        fully-labelled training set nor in Segmentation-val -- excluding Segmentation-val is what keeps the
        reported val/test numbers leak-free."""
        main_dir = os.path.join(self.root, "ImageSets", "Main")
        ids = set()
        for name in ("train.txt", "val.txt"):
            if os.path.isfile(os.path.join(main_dir, name)):
                ids |= set(self._read_ids(name, main_dir))
        if not ids:
            print("[!] ImageSets/Main/{train,val}.txt not found -- training on the fully-labelled split only.")
            return []
        seg_val = set(self._read_ids("val.txt"))
        return sorted(i for i in ids - seg_train_ids - seg_val
                      if os.path.isfile(os.path.join(self.ann_dir, f"{i}.xml")))

    @staticmethod
    def _warn_if_off_official(n: int, expected: int, label: str) -> None:
        if expected > 0 and abs(n - expected) > max(30, int(expected * 0.05)):
            print(f"[!] WARNING: '{label}' split resolved to {n} images; the official VOC2012 Segmentation "
                  f"'{label}' split has {expected}. This dataset's images-used total should never approach the "
                  f"full ~17.1k-image trainval package -- if it does, `dataset_root` is pointing at the wrong "
                  f"directory (see describe_voc2012_root()).")

    def _read_ids(self, name: str, split_dir: Optional[str] = None) -> List[str]:
        with open(os.path.join(split_dir or self.split_dir, name), "r") as f:
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
            # v4: the pasted partner is always a fully-labelled image, so a mix never dilutes segmentation /
            # edge supervision -- and pasting its labelled objects into a box/label-only image gives that image
            # some pixel-level supervision it would otherwise never get.
            pool = self.full_label_indices or list(range(len(self.image_ids)))
            j = random.choice(pool)
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


class MixedSupervisionBatchSampler(torch.utils.data.Sampler):
    """Mixed-Supervision Batch Sampler (MSBS). Every batch holds exactly `full_per_batch` fully-labelled images
    (mask + edges + boxes + labels; each seen once per epoch, reshuffled every epoch) and fills the remaining slots
    from the box/label-only pool, which is cycled through in its own reshuffled order ACROSS epochs, so the whole
    ~10k-image pool is covered over the run while an epoch stays len(full) / full_per_batch steps long.

    A plain shuffle over the union would put ~13% fully-labelled images in a batch (often zero in a batch of 8),
    making the segmentation / edge gradient vanish on most steps -- and an all-ignore batch used to turn the
    segmentation CE into NaN. Fixing the quota per batch is the standard trick of semi-/partially-supervised
    segmentation (labelled + unlabelled halves per batch, e.g. Mean Teacher / FixMatch-style pipelines), applied
    here to *partially-labelled* multi-task data."""
    def __init__(self, full_indices: List[int], partial_indices: List[int], batch_size: int, full_per_batch: int,
                 seed: int = 0):
        self.full = list(full_indices)
        self.partial = list(partial_indices)
        self.batch_size = int(batch_size)
        self.full_per_batch = self.batch_size if not self.partial else max(1, min(int(full_per_batch), self.batch_size))
        self.rng = random.Random(seed)
        self._partial_queue: List[int] = []

    def _next_partial(self) -> int:
        if not self._partial_queue:
            self._partial_queue = self.partial[:]
            self.rng.shuffle(self._partial_queue)
        return self._partial_queue.pop()

    def __len__(self) -> int:
        return len(self.full) // self.full_per_batch

    def __iter__(self):
        full = self.full[:]
        self.rng.shuffle(full)
        fpb = self.full_per_batch
        for b in range(len(self)):
            yield full[b * fpb:(b + 1) * fpb] + [self._next_partial() for _ in range(self.batch_size - fpb)]


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
        self.psnr_bicubic_sum = torch.zeros((), device=device)
        self.ssim_sum = torch.zeros((), device=device)
        self.n_images = 0
        C = cfg.num_mask_classes
        self.conf = torch.zeros(C * C, dtype=torch.long, device=device)
        self.edge_counts = torch.zeros(len(cfg.edge_eval_thresholds), 4, dtype=torch.float64, device=device)
        self.cls_scores, self.cls_labels = [], []
        self.det = DetectionEvaluator(cfg.num_classes, cfg.det_iou_thresh, cfg.det_score_thresh, cfg.det_max_per_image)

    @torch.no_grad()
    def update(self, preds: Dict, batch: Dict, loss_dict: Dict[str, torch.Tensor], metrics: bool = True):
        """Losses are accumulated on every call; the (comparatively expensive) quality metrics only when
        `metrics` is True -- the trainer passes False on most training batches (`train_metric_every`)."""
        cfg = self.cfg
        for k, v in loss_dict.items():
            self.loss_sums[k] += v
        self.n_batches += 1
        if not metrics:
            return
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
        # reference: plain bicubic upsampling of the same LR input, on the same valid pixels -- the number the
        # restoration stream has to beat (v4 logs showed PSNR without it, so the SR gain was invisible)
        bic = F.interpolate(batch["lr_image"].float(), size=hr.shape[-2:], mode="bicubic",
                            align_corners=False).clamp(0.0, 1.0)
        mse_b = (((bic - hr) ** 2) * valid_mask).sum(dim=(1, 2, 3)) / (n_valid_px * C)
        self.psnr_bicubic_sum += (10.0 * torch.log10(1.0 / (mse_b + cfg.psnr_eps))).sum()
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
        self.det.update(preds["pred_det_boxes"], preds["pred_det_logits"],
                        batch["boxes"], batch["box_labels"], batch["box_difficult"])

    def compute(self) -> Dict[str, float]:
        cfg = self.cfg
        out = {k: float(v / max(self.n_batches, 1)) for k, v in self.loss_sums.items()}
        out["loss"] = out.get("loss_total", 0.0)
        out["psnr"] = float(self.psnr_sum / max(self.n_images, 1))
        out["psnr_bicubic"] = float(self.psnr_bicubic_sum / max(self.n_images, 1))
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
        out["cls_map"] = (multilabel_map(torch.cat(self.cls_scores).numpy(), torch.cat(self.cls_labels).numpy())
                          if self.cls_scores else 0.0)
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
        if not hasattr(self, "_float_pairs"):
            # state_dict() tensors share storage with the live modules and load_state_dict() copies in place, so
            # these references stay valid; built once instead of two state_dict() walks per step
            msd, esd = model.state_dict(), self.module.state_dict()
            self._float_pairs = ([v for k, v in esd.items() if v.dtype.is_floating_point],
                                 [msd[k] for k, v in esd.items() if v.dtype.is_floating_point])
            self._other_pairs = [(v, msd[k]) for k, v in esd.items() if not v.dtype.is_floating_point]
        ema_t, model_t = self._float_pairs
        torch._foreach_mul_(ema_t, d)                          # fused multi-tensor ops: a handful of kernels
        torch._foreach_add_(ema_t, model_t, alpha=1.0 - d)     # instead of ~800 per step
        for e, m in self._other_pairs:
            e.copy_(m)


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
        # Parameter groups: no weight decay on biases / norms / prompts / queries / scales; the restoration stream
        # gets its own (default zero) weight decay; the pretrained semantic stream trains at backbone_lr_mult x lr.
        groups: Dict[str, List[nn.Parameter]] = defaultdict(list)
        for name, p in model.named_parameters():
            if not p.requires_grad:
                continue
            no_wd = (p.ndim <= 1 or name.endswith(".bias") or "global_prompts" in name or "query_" in name
                     or "tap_weights" in name or "logit_scale" in name or "presence_gain" in name)
            if name.startswith("semantic_backbone."):
                groups["backbone_no_decay" if no_wd else "backbone_decay"].append(p)
            elif name.startswith("restoration."):
                groups["restoration"].append(p)
            else:
                groups["no_decay" if no_wd else "decay"].append(p)
        sb = getattr(model, "semantic_backbone", None)
        # the reduced fine-tuning LR only makes sense for ImageNet weights; a random-init fallback trains at full LR
        bb_lr = config.lr * (config.backbone_lr_mult if sb is not None and sb.pretrained_loaded else 1.0)
        param_groups = [
            {"params": groups["decay"], "weight_decay": config.weight_decay, "lr": config.lr},
            {"params": groups["no_decay"], "weight_decay": 0.0, "lr": config.lr},
            {"params": groups["restoration"], "weight_decay": config.restoration_weight_decay, "lr": config.lr},
            {"params": groups["backbone_decay"], "weight_decay": config.weight_decay, "lr": bb_lr},
            {"params": groups["backbone_no_decay"], "weight_decay": 0.0, "lr": bb_lr},
        ]
        self.optimizer = torch.optim.AdamW([g for g in param_groups if g["params"]], lr=config.lr, betas=(0.9, 0.999))
        # Stream-Isolated Gradient Clipping (SIGC): one clip budget per stream instead of one global norm. With a
        # global norm the largest gradient source (detection: Hungarian + denoising + every aux layer) sets a
        # common shrink factor that also scales the restoration stream's update towards zero -- one of the three
        # reasons v3's SR output stayed at bicubic quality. Per-stream clipping keeps each stream's step size
        # governed by its own gradients, at zero extra backward passes.
        self.clip_streams = [s_ for s_ in (
            groups["restoration"],
            groups["backbone_decay"] + groups["backbone_no_decay"],
            groups["decay"] + groups["no_decay"],
        ) if s_]
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
        self._profile_left = config.profile_steps

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

    def _quality_exponent(self, epoch: int) -> float:
        """QAIC beta (see MultiTaskLoss._vfl): 0 -> 1 linearly over `quality_anneal_epochs`, a pure function of the
        epoch so it resumes exactly."""
        return min(1.0, max(0.0, (epoch - 1) / max(1, self.cfg.quality_anneal_epochs)))

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
            # v4: v3 used h = sigmoid(slope / scale), which reads a *plateau* (slope ~ 0) as health 0.5 -- so every
            # converged task had its loss halved and its dropout raised, exactly when it should be left alone.
            # Now only a metric that is genuinely declining (beyond a dead-band absorbing epoch-to-epoch noise)
            # loses health; improving or flat metrics keep h = 1.
            z = slope / scale + cfg.athm_deadband
            h = 1.0 if z >= 0.0 else math.exp(z)
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
            # Warm start: transfer every tensor whose name and shape still match (the v4 -> v4.1 changes keep the
            # encoder, semantic stream, pixel/query decoders and almost every head intact), keep fresh init for
            # the rest, and restart optimiser + schedule + epoch counter -- their state cannot be mapped onto
            # changed parameters. Below 50% overlap (e.g. a v3 checkpoint) it is cleaner to start from scratch.
            matched = {k: v for k, v in saved.items() if k in current and v.shape == current[k].shape}
            n_cur = sum(t.numel() for t in current.values())
            n_hit = sum(t.numel() for t in matched.values())
            if saved and n_hit >= 0.5 * n_cur:
                self.model.load_state_dict(matched, strict=False)
                if self.ema is not None:
                    self.ema.module.load_state_dict(self.model.state_dict())
                print(f"[*] Warm start from a checkpoint of an earlier version of this architecture (epoch "
                      f"{ckpt.get('epoch', '?')}): {len(matched)}/{len(current)} tensors = {100.0 * n_hit / n_cur:.1f}% "
                      f"of the weights transferred, the rest freshly initialised. Optimiser, LR schedule (incl. "
                      f"warmup) and epoch counter restart from 1.")
            else:
                print(f"[!] Checkpoint architecture differs from the current model and only "
                      f"{100.0 * n_hit / max(n_cur, 1):.0f}% of the weights match -> starting from scratch.")
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
    def run_epoch(self, epoch: int, loader: DataLoader, is_train: bool, tag: Optional[str] = None,
                  use_tta: bool = False) -> Dict[str, float]:
        model = self.model if is_train else self.eval_model
        model.train(is_train)
        tracker = MetricTracker(self.cfg, self.device, self.criterion)
        desc = tag or f"{'Train' if is_train else 'Val'} Ep {epoch}"
        # notebooks/log files are not TTYs: refresh the bar every 30 s instead of every few batches (the empty
        # blocks between epochs in Kaggle logs are erased progress-bar lines)
        pbar = tqdm(loader, desc=desc, leave=False, mininterval=0.1 if sys.stderr.isatty() else 30.0)
        skipped = 0
        sync = torch.cuda.synchronize if self.device.type == "cuda" else (lambda: None)
        prof: Dict[str, float] = defaultdict(float)
        n_prof, warm = 0, 3                      # skip the first steps (cuDNN autotuning, allocator warm-up)
        t_prev = time.perf_counter()
        for it, batch in enumerate(pbar):
            profiling = is_train and self._profile_left > 0 and it >= warm
            batch = move_batch(batch, self.device)
            if profiling:
                sync()
                t0 = time.perf_counter()
                prof["data"] += t0 - t_prev
            dn_batch = None
            if is_train and self.cfg.use_denoising:
                dn_batch = build_dn_batch(batch["boxes"], batch["box_labels"], self.cfg,
                                          self.current_dn_noise_scale, self.device)
            if is_train:
                self.optimizer.zero_grad(set_to_none=True)
                with self._autocast():
                    if dn_batch is not None:
                        preds = model(batch["lr_image"], dn_ref=dn_batch["dn_ref"],
                                      dn_labels=dn_batch["dn_labels"], dn_valid=dn_batch["valid"])
                    else:
                        preds = model(batch["lr_image"])
                if profiling:
                    sync()
                    t1 = time.perf_counter()
                    prof["forward"] += t1 - t0
                loss, loss_dict = self.criterion(preds, batch, dn_batch=dn_batch)
                if profiling:
                    sync()
                    t2 = time.perf_counter()
                    prof["loss (incl. Hungarian)"] += t2 - t1
                if not torch.isfinite(loss):
                    skipped += 1
                    t_prev = time.perf_counter()
                    continue
                self.scaler.scale(loss).backward()
                self.scaler.unscale_(self.optimizer)
                for stream_params in self.clip_streams:
                    nn.utils.clip_grad_norm_(stream_params, self.cfg.clip_grad_norm)
                self.scaler.step(self.optimizer)
                self.scaler.update()
                if self.ema is not None:
                    self.ema.update(self.model)
                if profiling:
                    sync()
                    t3 = time.perf_counter()
                    prof["backward + step + EMA"] += t3 - t2
            else:
                with torch.no_grad():
                    with self._autocast():
                        preds = model.forward_tta(batch["lr_image"]) if use_tta else model(batch["lr_image"])
                    loss, loss_dict = self.criterion(preds, batch)
            with_metrics = (not is_train) or it % max(1, self.cfg.train_metric_every) == 0
            if profiling:
                t4 = time.perf_counter()
            tracker.update(preds, batch, loss_dict, metrics=with_metrics)
            if profiling:
                sync()
                prof["metrics"] += time.perf_counter() - t4
                n_prof += 1
                self._profile_left -= 1
                if self._profile_left == 0:
                    self._report_profile(prof, n_prof, len(loader), epoch)
            if it % 10 == 0:
                pbar.set_postfix(loss=f"{loss.item():.3f}")
            t_prev = time.perf_counter()
        if skipped:
            print(f"[!] {skipped} non-finite batches skipped in epoch {epoch}.")
        return tracker.compute()

    def _report_profile(self, prof: Dict[str, float], n: int, steps_per_epoch: int, epoch: int) -> None:
        per = {k: v / max(n, 1) for k, v in prof.items()}
        step = sum(per.values())
        ep_min = step * steps_per_epoch / 60.0
        left = max(0, self.cfg.epochs - epoch + 1)
        parts = " | ".join(f"{k} {v:.2f}s" for k, v in per.items())
        print(f"[profile] {n} steps at batch_size={self.cfg.batch_size}: {parts} -> {step:.2f} s/step, "
              f"~{ep_min:.1f} min per training epoch (+ validation), ~{left * ep_min * 1.15 / 60.0:.1f} h for the "
              f"{left} remaining epochs (Kaggle: 12 h per session, 30 h per week).")
        if per.get("data", 0.0) > 0.25 * step:
            print(f"[profile] data loading is {100 * per['data'] / step:.0f}% of the step: the GPU waits for the "
                  f"{effective_workers(self.cfg)} loader workers (os.cpu_count()={os.cpu_count()}).")

    def evaluate(self, loader: DataLoader, name: str = "Test", use_tta: Optional[bool] = None) -> Dict[str, float]:
        use_tta = self.cfg.test_flip_tta if use_tta is None else use_tta
        m = self.run_epoch(0, loader, False, tag=f"{name} eval{' (flip-TTA)' if use_tta else ''}", use_tta=use_tta)
        print(f"[{name}] loss {m['loss']:.3f} | PSNR {m['psnr']:.2f}dB ({m['psnr'] - m['psnr_bicubic']:+.2f} vs "
              f"bicubic {m['psnr_bicubic']:.2f}) | SSIM {m['ssim']:.3f} | mIoU {m['miou']:.1f}% "
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
        epoch_secs: List[float] = []
        for epoch in range(self.start_epoch, cfg.epochs + 1):
            t_epoch = time.time()
            epoch_frac = self._dn_noise_progress(epoch)
            self.current_dn_noise_scale = (cfg.dn_box_noise_scale_start
                                            + (cfg.dn_box_noise_scale_end - cfg.dn_box_noise_scale_start) * epoch_frac)
            self.criterion.set_quality_exponent(self._quality_exponent(epoch))
            t = self.run_epoch(epoch, self.train_loader, True)
            t_val = time.time()
            v = self.run_epoch(epoch, self.val_loader, False)
            val_secs = time.time() - t_val
            lr = self.optimizer.param_groups[0]["lr"]          # the LR this epoch actually trained with
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
            health_str = " ".join(f"{k}:{v_:.2f}" for k, v_ in self.task_health.items()) or "n/a"
            epoch_secs.append(time.time() - t_epoch)
            print(f"Ep {epoch:03d} | lr {lr:.2e} | T-Loss {t['loss_main']:.3f} (optimised total {t['loss']:.1f}) | "
                  f"V-Loss {v['loss_main']:.3f} | V-PSNR {v['psnr']:.2f}dB ({v['psnr'] - v['psnr_bicubic']:+.2f} vs "
                  f"bicubic) | V-SSIM {v['ssim']:.3f} | V-mIoU {v['miou']:.1f}% | "
                  f"V-EdgeF1 {v['edge_f1']:.1f}% | V-mAP {v['det_map']:.1f}% | V-ClsmAP {v['cls_map']:.1f}% | "
                  f"score {score:.2f}{' *' if is_best else ''} | health[{health_str}]")
            print(f"      val components: rec {v['loss_rec']:.3f} | seg_ce {v['loss_seg_ce']:.3f} | "
                  f"seg_dice {v['loss_seg_dice']:.3f} | cls {v['loss_cls']:.3f} | edge {v['loss_edge']:.3f} | "
                  f"det {v['loss_det']:.3f} | train dn {t['loss_dn']:.3f} | QAIC beta "
                  f"{self.criterion.quality_exponent:.2f} | DN noise {self.current_dn_noise_scale:.2f} | "
                  f"{epoch_secs[-1] / 60.0:.1f} min")
            stop_composite = cfg.early_stop_patience > 0 and self.bad_epochs >= cfg.early_stop_patience
            stop_loss = cfg.loss_early_stop_patience > 0 and self.loss_bad_epochs >= cfg.loss_early_stop_patience
            if stop_composite or stop_loss:
                reason = "composite score" if stop_composite else "validation loss"
                print(f"[*] Early stopping: no improvement of the {reason} for "
                      f"{self.bad_epochs if stop_composite else self.loss_bad_epochs} epochs.")
                break
            budget = cfg.session_time_budget_hours * 3600.0
            if budget > 0 and epoch < cfg.epochs:
                recent = epoch_secs[-3:]
                reserve = 4.0 * val_secs + 600.0     # final Val + Test with flip-TTA, visualisations, slack
                if (time.time() - _PROCESS_START) + sum(recent) / len(recent) + reserve > budget:
                    print(f"[*] Session time budget ({cfg.session_time_budget_hours:.1f} h): stopping after epoch "
                          f"{epoch} so the final evaluation and visualisations finish before the session limit. "
                          f"Run the notebook again to resume from epoch {epoch + 1} (auto_resume).")
                    break
        plot_history(self.history, os.path.join(self.ckpt_dir, "training_curves.png"))


def plot_history(history, path: str):
    panels = [("loss_main", "Loss (val-comparable terms)"), ("psnr", "PSNR (dB)"), ("miou", "mIoU (%)"),
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
    round-tripped copy of the (downsampled-then-upsampled) canvas tensor. v4: predictions use the flip
    self-ensemble (`test_flip_tta`), segmentation LOGITS are resized to the original resolution before the argmax
    (v3 nearest-resized the label map, which blocks every boundary), and detections are the calibrated QAIC scores
    -- boxes at or above `det_conf_threshold` are drawn as detections; only if none qualify are the best
    low-confidence guesses drawn, in a visibly different (dotted orange) style."""
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
    def _unletterbox_logits_argmax(logits_chw: torch.Tensor, lb: Dict[str, Any]) -> np.ndarray:
        inner = logits_chw[:, lb["pad_top"]:lb["pad_top"] + lb["new_h"], lb["pad_left"]:lb["pad_left"] + lb["new_w"]]
        up = F.interpolate(inner[None].float(), size=(lb["orig_h"], lb["orig_w"]), mode="bilinear", align_corners=False)
        return up[0].argmax(dim=0).cpu().numpy().astype(np.uint8)

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
            if cfg.test_flip_tta and hasattr(self.model, "forward_tta"):
                preds = self.model.forward_tta(batch["lr_image"])
            else:
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

                pred_mask_full = self._unletterbox_logits_argmax(preds["pred_masks"][i], lb)
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
                ax.set_title(f"Detections (green: score >= {cfg.det_conf_threshold:.2f}) vs ground truth (red) -- "
                             f"original resolution", fontsize=9)
                probs = torch.sigmoid(preds["pred_det_logits"][i].float())          # (Q, C) QAIC scores
                scores_t, cls_t = probs.max(dim=-1)
                scores_all = scores_t.cpu().numpy()
                cls_idx_all = cls_t.cpu().numpy()
                boxes_px = unletterbox_boxes_to_pixels(preds["pred_det_boxes"][i].float().cpu().numpy(), lb)
                confident = scores_all >= cfg.det_conf_threshold
                keep_mask = confident.copy()
                if not keep_mask.any():
                    # nothing is confident: show the best guesses instead of an empty plot, drawn in a distinct
                    # dotted style so they cannot be mistaken for real detections (honest diagnostic picture)
                    top = np.argsort(-scores_all)[:3]
                    keep_mask[top] = scores_all[top] >= cfg.det_vis_min_score
                sel = np.nonzero(keep_mask)[0]
                if len(sel) > 0:
                    nms_keep = greedy_nms(boxes_px[sel], scores_all[sel], cfg.det_nms_iou_thresh)
                    sel = sel[nms_keep]
                    order = np.argsort(-scores_all[sel])[: cfg.det_vis_topk]
                    sel = sel[order]
                for q_idx in sel:
                    x0, y0, x1, y1 = boxes_px[q_idx]
                    color, style = ("lime", "-") if confident[q_idx] else ("orange", ":")
                    cls_name = cfg.voc_classes[int(cls_idx_all[q_idx])]
                    ax.add_patch(patches.Rectangle((x0, y0), x1 - x0, y1 - y0, linewidth=2,
                                                   edgecolor=color, facecolor="none", linestyle=style))
                    ax.text(x0, max(y0 - 5, 0), f"{cls_name} {scores_all[q_idx]:.2f}",
                            color="black", fontsize=10, backgroundcolor=color)
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
# 10. MAIN EXECUTION / SMOKE TEST / DATASET UNIT TEST / OVERFIT (LEARNABILITY) TEST
# ============================================================================
def build_loader(ds, cfg: OmniMorphConfig, shuffle: bool, drop_last: bool) -> DataLoader:
    nw = effective_workers(cfg)
    kwargs = dict(batch_size=cfg.batch_size, shuffle=shuffle, num_workers=nw, drop_last=drop_last,
                  collate_fn=omnimorph_collate_fn, pin_memory=torch.cuda.is_available())
    if nw > 0:
        kwargs["persistent_workers"] = True
    return DataLoader(ds, **kwargs)


def full_per_batch(cfg: OmniMorphConfig) -> int:
    if cfg.full_label_per_batch > 0:
        return min(cfg.full_label_per_batch, cfg.batch_size)
    return max(1, min(cfg.batch_size, int(round(cfg.batch_size * cfg.full_label_fraction))))


def effective_workers(cfg: OmniMorphConfig) -> int:
    """Never more loader workers than CPU cores minus one: Kaggle GPU sessions have 4 vCPUs, and the training
    process itself needs a core to launch kernels and run Hungarian matching."""
    return max(0, min(cfg.num_workers, (os.cpu_count() or 2) - 1))


def build_train_loader(ds: "PascalVOC2012MultiTaskDataset", cfg: OmniMorphConfig) -> DataLoader:
    sampler = MixedSupervisionBatchSampler(ds.full_label_indices, ds.partial_label_indices, cfg.batch_size,
                                           full_per_batch(cfg), cfg.seed)
    nw = effective_workers(cfg)
    kwargs = dict(batch_sampler=sampler, num_workers=nw, collate_fn=omnimorph_collate_fn,
                  pin_memory=torch.cuda.is_available())
    if nw > 0:
        kwargs["persistent_workers"] = True
        kwargs["prefetch_factor"] = 4
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
    print(f"[*] Discovered Data - Train: {len(train_ds)} ({len(train_ds.full_label_indices)} fully labelled + "
          f"{len(train_ds.partial_label_indices)} box/label-only), Val: {len(val_ds)}, Test: {len(test_ds)} "
          f"(val/test are both carved out of Segmentation-val, which never enters training)"
          f"{'  (WARNING: test == val)' if not config.separate_test_split else ''}")
    if len(train_ds.full_label_indices) == 0:
        print("[!] No training data found. Please ensure VOC2012 is extracted correctly.")
        return
    train_loader = build_train_loader(train_ds, config)
    val_loader = build_loader(val_ds, config, shuffle=False, drop_last=False)
    test_loader = build_loader(test_ds, config, shuffle=False, drop_last=False)
    fpb = full_per_batch(config) if train_ds.partial_label_indices else config.batch_size
    print(f"[*] {len(train_loader)} optimisation steps per epoch ({fpb} fully-labelled + "
          f"{config.batch_size - fpb} box/label-only images per batch, batch_size={config.batch_size}, "
          f"{effective_workers(config)} loader workers)")
    print("[*] Initializing OmniMorphNet...")
    model = OmniMorphNet(config).to(config.device)
    n_params = sum(p.numel() for p in model.parameters())
    n_train = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"[*] Single-GPU execution on {config.device} | parameters: {n_params / 1e6:.2f}M "
          f"({n_train / 1e6:.2f}M trainable)")
    criterion = MultiTaskLoss(config, perceptual=build_perceptual_extractor(model, config)).to(config.device)
    trainer = OmniMorphTrainer(model, train_loader, val_loader, criterion, config)
    trainer.fit()
    trainer.load_best()
    trainer.evaluate(val_loader, "Val")
    trainer.evaluate(test_loader, "Test")
    OmniMorphInferencer(trainer.eval_model, config, dataset=test_ds).run_inference_on_dataset(test_loader)
    print("[*] Full penta-task single-GPU pipeline completed successfully.")


def smoke_test(config: Optional[OmniMorphConfig] = None, batch_size: int = 2):
    """One forward / backward / metric pass on random tensors: checks shapes, finite grads and the metric code,
    including the ICCD v2 denoising path (positives + contrastive negatives, with a synthetic ragged set of GT
    boxes), the letterbox-aware valid-pixel mask plumbing, ATHM and the flip-TTA evaluation path."""
    cfg = config or OmniMorphConfig()
    cfg.use_amp = False
    dev = torch.device(cfg.device)
    set_seed(cfg.seed)
    model = OmniMorphNet(cfg).to(dev)
    criterion = MultiTaskLoss(cfg, perceptual=build_perceptual_extractor(model, cfg)).to(dev)
    n_params = sum(p.numel() for p in model.parameters())
    n_train = sum(p.numel() for p in model.parameters() if p.requires_grad)
    sb = model.semantic_backbone
    print(f"[smoke] parameters: {n_params / 1e6:.2f}M ({n_train / 1e6:.2f}M trainable) | semantic stream: "
          f"{'none' if sb is None else sb.name + (' (ImageNet)' if sb.pretrained_loaded else ' (random init)')}")
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
    criterion.set_quality_exponent(0.5)

    model.train()
    if dn_batch is not None:
        preds = model(batch["lr_image"], dn_ref=dn_batch["dn_ref"], dn_labels=dn_batch["dn_labels"],
                      dn_valid=dn_batch["valid"])
    else:
        preds = model(batch["lr_image"])
    for k, v in preds.items():
        if torch.is_tensor(v):
            print(f"[smoke]   {k:<16s} {tuple(v.shape)}")
        elif isinstance(v, list):
            print(f"[smoke]   {k:<16s} {len(v)} decoder layers")
    loss, ld = criterion(preds, batch, dn_batch=dn_batch)
    loss.backward()
    bad = [n for n, p in model.named_parameters() if p.grad is not None and not torch.isfinite(p.grad).all()]
    no_grad = [n for n, p in model.named_parameters() if p.requires_grad and p.grad is None]
    print(f"[smoke] loss {loss.item():.4f} | non-finite grads: {len(bad)} | params without grad: {len(no_grad)}")
    if no_grad:
        print("[smoke]   e.g.", no_grad[:5])
    print("[smoke]   components:", {k: round(float(v), 4) for k, v in ld.items()})
    assert torch.isfinite(loss) and not bad, "non-finite loss or gradients"

    # activation checkpointing must be a pure memory/compute trade: same loss, same gradients (both passes start
    # from the same RNG state, so DropPath / dropout draw identical masks; checkpoint() replays them on recompute)
    if cfg.grad_checkpoint and dn_batch is not None:
        def run(ckpt_on: bool):
            cfg.grad_checkpoint = ckpt_on
            model.restoration.grad_checkpoint = ckpt_on
            model.zero_grad(set_to_none=True)
            set_seed(1234)
            p_ = model(batch["lr_image"], dn_ref=dn_batch["dn_ref"], dn_labels=dn_batch["dn_labels"],
                       dn_valid=dn_batch["valid"])
            l_, _ = criterion(p_, batch, dn_batch=dn_batch)
            l_.backward()
            return float(l_), {n: q.grad.clone() for n, q in model.named_parameters() if q.grad is not None}
        loss_c, g_c = run(True)
        loss_n, g_n = run(False)
        cfg.grad_checkpoint = True
        model.restoration.grad_checkpoint = cfg.checkpoint_restoration
        worst = max(float((g_n[n] - g).abs().max() / (g.abs().max() + 1e-8)) for n, g in g_c.items())
        print(f"[smoke] gradient checkpointing: loss {loss_c:.5f} vs {loss_n:.5f} without, "
              f"max relative grad difference {worst:.1e}")
        assert abs(loss_c - loss_n) < 1e-4 * max(1.0, abs(loss_n)) and worst < 1e-3, "checkpointing changed the maths"

    # ATHM plumbing sanity check (loss-weight + head-dropout mutation)
    if hasattr(model, "set_task_health"):
        health = {"rec": 0.4, "seg": 0.6, "edge": 1.0, "cls": 1.0, "det": 0.35}
        model.set_task_health(health)
        criterion.set_task_health(health)
        assert abs(model.seg_dropout.p - (cfg.head_dropout_base + 0.4 * cfg.head_dropout_max_extra)) < 1e-6
        print(f"[smoke] ATHM dropout mutation OK (seg_dropout.p={model.seg_dropout.p:.3f})")

    model.eval()
    with torch.no_grad():
        preds = model.forward_tta(batch["lr_image"])
        _, ld = criterion(preds, batch)
        tracker = MetricTracker(cfg, dev, criterion)
        tracker.update(preds, batch, ld)
        print("[smoke] metrics:", {k: round(v, 3) for k, v in tracker.compute().items()})
    print("[smoke] OK")


def _write_fake_voc_sample(root: str, image_id: str, W: int, H: int, cfg: OmniMorphConfig, rng: random.Random,
                           with_seg: bool = True):
    """Writes one synthetic-but-structurally-valid VOC2012 sample (JPEG + class mask + instance mask + XML
    annotation) so the dataset pipeline (letterboxing, augmentation, CTCRM, denoising targets) can be exercised
    end to end without downloading the real ~2GB dataset. `with_seg=False` writes a box/label-only sample, like
    the ImageSets/Main images that have no SegmentationClass/SegmentationObject PNG."""
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
    if with_seg:
        Image.fromarray(cls_mask).save(os.path.join(root, "SegmentationClass", f"{image_id}.png"))
        Image.fromarray(obj_mask).save(os.path.join(root, "SegmentationObject", f"{image_id}.png"))

    objs_xml = "".join(
        f"<object><name>{name}</name><difficult>0</difficult>"
        f"<bndbox><xmin>{x0}</xmin><ymin>{y0}</ymin><xmax>{x1}</xmax><ymax>{y1}</ymax></bndbox></object>"
        for name, x0, y0, x1, y1 in boxes_xml)
    xml = f"<annotation><size><width>{W}</width><height>{H}</height></size>{objs_xml}</annotation>"
    with open(os.path.join(root, "Annotations", f"{image_id}.xml"), "w") as f:
        f.write(xml)


def _write_split(root: str, task: str, name: str, ids: List[str]) -> None:
    os.makedirs(os.path.join(root, "ImageSets", task), exist_ok=True)
    with open(os.path.join(root, "ImageSets", task, name), "w") as f:
        f.write("\n".join(ids) + "\n")


def unit_test(cfg: Optional[OmniMorphConfig] = None):
    """Dataset-pipeline sanity check: builds a tiny synthetic VOC2012-shaped tree covering a wide, a tall, and a
    square image (plus box/label-only ImageSets/Main images), then exercises letterboxing, train-time augmentation
    (crop/flip/color-jitter/CTCRM), the val-time (unaugmented) path, the mixed-supervision sampler and its
    no-leak guarantee, batch collation, `move_batch`, the ICCD v2 denoising-target builder, the LDBC boundary and
    the QAIC loss -- all the code paths that `--smoke-test`'s random tensors never touch."""
    cfg = cfg or OmniMorphConfig()
    cfg.batch_size = 3
    cfg.full_label_per_batch = 2
    cfg.num_workers = 0
    rng = random.Random(cfg.seed)
    with tempfile.TemporaryDirectory() as root:
        sizes = [(500, 333), (333, 500), (256, 256), (640, 200), (200, 640), (480, 360)]
        ids = [f"synth_{i:03d}" for i in range(len(sizes))]
        for image_id, (W, H) in zip(ids, sizes):
            _write_fake_voc_sample(root, image_id, W, H, cfg, rng)
        extra_sizes = [(400, 300), (300, 400), (512, 384)]
        extra_ids = [f"synth_main_{i:03d}" for i in range(len(extra_sizes))]
        for image_id, (W, H) in zip(extra_ids, extra_sizes):
            _write_fake_voc_sample(root, image_id, W, H, cfg, rng, with_seg=False)
        _write_split(root, "Segmentation", "train.txt", ids[:4])
        _write_split(root, "Segmentation", "val.txt", ids[4:])
        _write_split(root, "Main", "train.txt", ids[:4] + extra_ids[:2])
        _write_split(root, "Main", "val.txt", ids[4:] + extra_ids[2:])

        cfg.separate_test_split = False
        train_ds = PascalVOC2012MultiTaskDataset(root, "train", cfg, augment=True)
        val_ds = PascalVOC2012MultiTaskDataset(root, "val", cfg, augment=False)
        assert len(train_ds.full_label_indices) == 4 and len(train_ds.partial_label_indices) == 3, \
            "mixed-supervision split sizes do not match the synthetic tree"
        assert len(val_ds) == 2, "val split size does not match the synthetic tree"
        assert not set(train_ds.image_ids) & set(ids[4:]), "a Segmentation-val image leaked into training"
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
        plain = PascalVOC2012MultiTaskDataset(root, "train", cfg, augment=False)
        s = plain[plain.partial_label_indices[0]]
        assert bool((s["mask"] == cfg.ignore_index).all()) and bool((s["edge_mask"] == cfg.ignore_index).all()), \
            "a box/label-only image must contribute no segmentation / edge supervision"
        assert s["boxes"].shape[0] > 0 and float(s["label"].sum()) > 0, "box/label-only image lost its boxes/labels"
        print("[unit-test] per-sample shape/range checks OK (incl. box/label-only samples)")

        # ---- mixed-supervision batch sampler ----
        sampler = MixedSupervisionBatchSampler(train_ds.full_label_indices, train_ds.partial_label_indices,
                                               cfg.batch_size, cfg.full_label_per_batch, cfg.seed)
        batches = list(iter(sampler))
        full_set = set(train_ds.full_label_indices)
        assert len(batches) == len(sampler) == 2
        for bt in batches:
            assert len(bt) == cfg.batch_size and sum(i in full_set for i in bt) == cfg.full_label_per_batch
        print("[unit-test] mixed-supervision batch sampler OK")

        # ---- letterbox round-trip: original-space boxes -> canvas -> back to original-space pixels ----
        lb = compute_letterbox_params(640, 200, S)
        orig_boxes = np.array([[10, 20, 300, 150], [0, 0, 640, 200]], dtype=np.float32)
        norm_boxes = orig_boxes / np.array([640, 200, 640, 200], dtype=np.float32)
        canvas_boxes = letterbox_boxes(norm_boxes, 640, 200, lb)
        recovered_px = unletterbox_boxes_to_pixels(canvas_boxes, lb)
        assert np.allclose(recovered_px, orig_boxes, atol=1.5), f"letterbox round-trip drifted: {recovered_px} vs {orig_boxes}"
        print("[unit-test] letterbox box round-trip OK")

        # ---- collate + move_batch (meta/image_id must survive un-mangled; this is the bug v2's move_batch had) ----
        loader = build_train_loader(train_ds, cfg)
        batch = next(iter(loader))
        batch = move_batch(batch, torch.device("cpu"))
        assert isinstance(batch["image_id"], list) and isinstance(batch["image_id"][0], str)
        assert isinstance(batch["meta"], list) and "lb" in batch["meta"][0]
        assert batch["hr_image"].shape[0] == len(batch["image_id"])
        print("[unit-test] collate_fn / move_batch OK")

        # ---- ICCD v2 denoising target builder on a real ragged batch ----
        dn = build_dn_batch(batch["boxes"], batch["box_labels"], cfg, cfg.dn_box_noise_scale_start, torch.device("cpu"))
        if dn is not None:
            groups = 2 if cfg.dn_use_negatives else 1
            assert dn["dn_ref"].shape == (len(batch["boxes"]), groups * cfg.dn_max_gt_per_image, 4)
            assert bool(dn["valid"].any()), "no valid denoising slots were produced despite having GT boxes"
            assert int((dn["valid"] & dn["is_pos"]).sum()) * groups == int(dn["valid"].sum())
            r = dn["dn_ref"][dn["valid"]]
            assert float(r.min()) > 0.0 and float(r.max()) <= 1.0
        print(f"[unit-test] ICCD v2 denoising batch builder OK (produced={'yes' if dn is not None else 'no'})")

    # ---- LDBC: two flat regions -> boundary probability 1 exactly on the seam, 0 elsewhere ----
    lg = torch.full((1, cfg.num_mask_classes, 8, 8), -10.0)
    lg[:, 0, :, :4] = 10.0
    lg[:, 15, :, 4:] = 10.0
    bd = label_disagreement_boundary(lg)[0, 0]
    assert float(bd[:, 3:5].min()) > 0.99 and float(bd[:, :3].max()) < 1e-3 and float(bd[:, 5:].max()) < 1e-3
    print("[unit-test] LDBC label-disagreement boundary OK")

    # ---- QAIC: hard target at beta=0 equals plain BCE on the positive; a negative is weighted by alpha*p^gamma ----
    crit = MultiTaskLoss(cfg)
    logit = torch.tensor([[0.3, -1.0]])
    pos = torch.tensor([[True, False]])
    q = torch.tensor([[1.0, 0.0]])
    p_neg = torch.sigmoid(torch.tensor(-1.0))
    expected = (F.binary_cross_entropy_with_logits(torch.tensor(0.3), torch.tensor(1.0))
                + cfg.vfl_alpha * p_neg ** cfg.focal_gamma * F.binary_cross_entropy_with_logits(torch.tensor(-1.0), torch.tensor(0.0)))
    assert abs(float(crit._vfl(logit, pos, q)) - float(expected)) < 1e-5
    print("[unit-test] QAIC / varifocal loss OK")

    # ---- v4.1 speed rewrites must be exact: fused deformable sampling == the original per-tap loop ----
    torch.manual_seed(0)
    small = OmniMorphConfig(prompt_dim=8)
    dcn = PromptGuidedDeformableConv(6, small)
    nn.init.normal_(dcn.offset_mod_conv.weight, std=0.3)              # non-trivial offsets / modulation
    x, prompt = torch.randn(2, 6, 9, 11), torch.randn(2, 3, 8)
    K, pad = dcn.K, dcn.pad
    params = dcn.offset_mod_conv(x + dcn.prompt_proj(prompt.mean(dim=1)).view(2, 6, 1, 1))
    res = params[:, 2:2 + 2 * K * K].reshape(2, K * K, 2, 9, 11)
    cur = torch.tanh(params[:, 2 + 2 * K * K: 2 + 3 * K * K]).unsqueeze(2) * small.curvature_scale
    offs = params[:, :2].unsqueeze(1) + res * (1.0 + cur)
    offs = torch.tanh(offs / dcn.max_offset) * dcn.max_offset
    mod = 2.0 * torch.sigmoid(params[:, 2 + 3 * K * K:])
    ref, idx = torch.zeros_like(x), 0
    for ky in range(-pad, pad + 1):
        for kx in range(-pad, pad + 1):
            grid = make_base_grid(9, 11, x.device) + (offs[:, idx].permute(0, 2, 3, 1) + torch.tensor([kx, ky]).float()) \
                * px_to_norm(9, 11, x.device)
            ref = ref + F.grid_sample(x, grid, mode="bilinear", padding_mode="zeros", align_corners=False) \
                * mod[:, idx:idx + 1] * dcn.tap_weights[:, idx].view(1, 6, 1, 1)
            idx += 1
    assert torch.allclose(dcn(x, prompt), dcn.proj(ref), atol=1e-5), "fused deformable sampling diverged"
    print("[unit-test] fused deformable sampling == per-tap loop OK")

    # ---- windowed attention with one window covering the map == global attention ----
    torch.manual_seed(0)
    wcfg = OmniMorphConfig(prompt_dim=8, attn_window=8, attn_global_max_tokens=0)
    gcfg = OmniMorphConfig(prompt_dim=8, attn_window=0)
    att_w, att_g = PromptGuidedSDTA(16, 2, wcfg), PromptGuidedSDTA(16, 2, gcfg)
    att_g.load_state_dict(att_w.state_dict())
    xa, pa = torch.randn(2, 16, 8, 8), torch.randn(2, 3, 8)
    assert torch.allclose(att_w(xa, pa), att_g(xa, pa), atol=1e-5), "single-window attention != global attention"
    att_s = PromptGuidedSDTA(16, 2, OmniMorphConfig(prompt_dim=8, attn_window=4, attn_global_max_tokens=0), shift=True)
    out_s = att_s(xa, pa)
    assert out_s.shape == xa.shape and bool(torch.isfinite(out_s).all())
    print("[unit-test] windowed / shifted-window attention OK")
    print("[unit-test] ALL CHECKS PASSED")


def overfit_test(out_dir: Optional[str] = None, epochs: int = 120,
                 overrides: Optional[Dict[str, Any]] = None, strict: bool = True) -> Dict[str, float]:
    """End-to-end learning check that runs on a CPU in a few minutes: a tiny OmniMorph is trained through the REAL
    OmniMorphTrainer (mixed-supervision sampler, ICCD v2, QAIC annealing, stream-isolated clipping, checkpointing,
    resume with horizon extension, flip-TTA evaluation, the inferencer) on a synthetic VOC-shaped tree, then
    evaluated on its own training images. It asserts the property the v3 dumps show was missing: every task
    actually learns -- the restored image beats bicubic, segmentation / edges / classification are well above
    chance, and detection produces CONFIDENT boxes on the right objects instead of v3's 0.03-0.06 scores. This is
    a plumbing-and-learnability test, not a benchmark: it says nothing about VOC2012 accuracy."""
    cfg = OmniMorphConfig(
        experiment_name="overfit_test", lr_image_size=32, hr_image_size=128,
        embed_dims=[16, 32, 32, 48], depths=[1, 1, 1, 1], num_heads=[1, 2, 2, 4], num_prompts=4, prompt_dim=16,
        pixel_dec_dim=32, num_queries=8, num_refine_rounds=3, rs_channels=16, rs_groups=2, rs_blocks_per_group=2,
        rs_ca_reduction=4, edge_hidden_channels=8, edge_branch_channels=8, backbone_name="resnet18",
        dn_max_gt_per_image=4, attn_window=8, attn_global_max_tokens=256, lambda_perceptual=0.05,
        batch_size=4, full_label_per_batch=3, num_workers=0, epochs=epochs, warmup_epochs=3, lr=1e-3,
        use_amp=False, use_ema=False, augment=False, use_ctcrm=False, drop_path_rate=0.0, head_dropout_base=0.0,
        early_stop_patience=0, loss_early_stop_patience=0, athm_start_epoch=10 ** 6, quality_anneal_epochs=epochs // 3,
        checkpoint_every_n_epochs=0, separate_test_split=False, max_infer_batches=1, device="cpu")
    for k, v in (overrides or {}).items():
        setattr(cfg, k, v)
    set_seed(cfg.seed)
    rng = random.Random(cfg.seed)
    with tempfile.TemporaryDirectory() as tmp:
        work = out_dir or tmp
        root = os.path.join(work, "voc")
        cfg.checkpoint_dir = os.path.join(work, "models")
        cfg.visualization_dir = os.path.join(work, "visualizations")
        sizes = [(160, 120), (120, 160), (128, 128), (200, 100), (100, 200), (150, 150)]
        ids = [f"fit_{i:03d}" for i in range(len(sizes))]
        for image_id, (W, H) in zip(ids, sizes):
            _write_fake_voc_sample(root, image_id, W, H, cfg, rng)
        extra = [f"fit_main_{i:03d}" for i in range(3)]
        for image_id in extra:
            _write_fake_voc_sample(root, image_id, 140, 110, cfg, rng, with_seg=False)
        _write_split(root, "Segmentation", "train.txt", ids)
        _write_split(root, "Segmentation", "val.txt", ids)          # evaluate on the training images: overfit test
        _write_split(root, "Main", "train.txt", ids + extra)
        _write_split(root, "Main", "val.txt", [])
        train_ds = PascalVOC2012MultiTaskDataset(root, "train", cfg, augment=False)
        val_ds = PascalVOC2012MultiTaskDataset(root, "val", cfg, augment=False)
        train_loader = build_train_loader(train_ds, cfg)
        val_loader = build_loader(val_ds, cfg, shuffle=False, drop_last=False)

        model = OmniMorphNet(cfg)
        criterion = MultiTaskLoss(cfg, perceptual=build_perceptual_extractor(model, cfg))
        trainer = OmniMorphTrainer(model, train_loader, val_loader, criterion, cfg)
        trainer.fit(auto_resume=False)

        # resume + horizon extension from the checkpoint just written (exercises CPHE and the new param groups)
        cfg2 = copy.deepcopy(cfg)
        cfg2.epochs = cfg.epochs + 2
        model2 = OmniMorphNet(cfg2)
        trainer2 = OmniMorphTrainer(model2, train_loader, val_loader,
                                    MultiTaskLoss(cfg2, perceptual=build_perceptual_extractor(model2, cfg2)), cfg2)
        trainer2.fit(auto_resume=True)
        assert trainer2.start_epoch == cfg.epochs + 1, "resume did not pick up the saved checkpoint"
        # warm start: a checkpoint of a slightly different architecture (here: a wider edge branch) must transfer
        # every matching tensor and restart the schedule, instead of being discarded
        cfg3 = copy.deepcopy(cfg2)
        cfg3.edge_branch_channels = cfg2.edge_branch_channels * 2
        model3 = OmniMorphNet(cfg3)
        trainer3 = OmniMorphTrainer(model3, train_loader, val_loader, MultiTaskLoss(cfg3), cfg3)
        trainer3.resume()
        assert trainer3.start_epoch == 1, "warm start must restart the epoch counter"
        assert torch.equal(model3.restoration.tail.weight, trainer2.model.restoration.tail.weight), \
            "warm start did not transfer the matching weights"

        trainer2.criterion.set_quality_exponent(1.0)
        m = trainer2.evaluate(val_loader, "Overfit")

        # bicubic reference PSNR on exactly the same canvases / valid pixels
        psnr_sum, n = 0.0, 0
        for batch in val_loader:
            base = F.interpolate(batch["lr_image"], size=batch["hr_image"].shape[-2:], mode="bicubic",
                                 align_corners=False).clamp(0, 1)
            vm = batch["valid_mask"]
            mse = (((base - batch["hr_image"]) ** 2) * vm).sum(dim=(1, 2, 3)) / (vm.sum(dim=(1, 2, 3)) * 3)
            psnr_sum += float((10 * torch.log10(1.0 / (mse + cfg.psnr_eps))).sum())
            n += batch["hr_image"].shape[0]
        m["bicubic_psnr"] = psnr_sum / max(n, 1)

        # detection confidence on the training images: the best score per GT object
        conf = []
        eval_model = trainer2.eval_model.eval()
        with torch.no_grad():
            for batch in val_loader:
                preds = eval_model(batch["lr_image"])
                probs = torch.sigmoid(preds["pred_det_logits"].float())
                for i in range(probs.shape[0]):
                    for gb, gl in zip(batch["boxes"][i], batch["box_labels"][i]):
                        _, iou = paired_box_giou(preds["pred_det_boxes"][i].float(), gb.expand_as(preds["pred_det_boxes"][i]))
                        good = iou >= 0.5
                        conf.append(float(probs[i, :, gl][good].max()) if bool(good.any()) else 0.0)
        m["det_median_gt_conf"] = float(np.median(conf)) if conf else 0.0

        OmniMorphInferencer(eval_model, cfg2, dataset=val_ds).run_inference_on_dataset(val_loader)
        n_vis = sum(len(os.listdir(d)) for d in [os.path.join(cfg2.visualization_dir, x)
                                                for x in ("restoration", "segmentation", "detection")])

        print(f"[overfit] PSNR {m['psnr']:.2f} dB vs bicubic {m['bicubic_psnr']:.2f} dB | mIoU {m['miou']:.1f}% | "
              f"PixAcc {m['pix_acc']:.1f}% | EdgeF1 {m['edge_f1']:.1f}% | ClsmAP {m['cls_map']:.1f}% | "
              f"DetmAP {m['det_map']:.1f}% | median GT-matched det score {m['det_median_gt_conf']:.2f} | "
              f"{n_vis} visualisations")
        if not strict:
            return m
        assert m["psnr"] > m["bicubic_psnr"] + 1.0, "restoration stream did not beat bicubic"
        assert m["pix_acc"] > 85.0 and m["miou"] > 50.0, "segmentation did not learn"
        assert m["cls_map"] > 80.0, "classification did not learn"
        assert m["edge_f1"] > 30.0, "edges did not learn"
        assert m["det_map"] > 50.0 and m["det_median_gt_conf"] > 0.5, "detection is not confident / not localised"
        assert n_vis == 3 * min(len(val_ds), cfg.batch_size), "inferencer did not write every visualisation"
    print("[overfit] ALL TASKS LEARN")
    return m


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OmniMorph v4.1 -- penta-task PASCAL VOC 2012 network")
    parser.add_argument("--smoke-test", action="store_true", help="one forward/backward on random tensors")
    parser.add_argument("--unit-test", action="store_true", help="dataset-pipeline checks on synthetic VOC files")
    parser.add_argument("--overfit-test", action="store_true", help="tiny end-to-end learning check (CPU-friendly)")
    # parse_known_args: Jupyter / Kaggle kernels append their own argv (e.g. `-f kernel.json`) when this file is
    # run as a notebook cell -- that must not crash the script or be mistaken for a flag.
    args, _unknown = parser.parse_known_args()
    cfg = OmniMorphConfig()
    if args.smoke_test:
        smoke_test(cfg)
    elif args.unit_test:
        unit_test(cfg)
    elif args.overfit_test:
        overfit_test()
    else:
        main(cfg)
