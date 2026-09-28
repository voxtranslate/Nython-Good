"""
SINA-Net v4 (Google Colab edition): Spectro-Information Neighborhood Attention U-Net for
Image Restoration, with degradation-aware Radial-Angular Spectral Conditioning.

================================================================================
COLAB EDITION: WHAT CHANGED (the network, losses and training recipe are v4)
================================================================================
Runtime
  * Runs in Google Colab on the G4 runtime (NVIDIA RTX PRO 6000 Blackwell Server
    Edition, 96 GB GDDR7, compute capability 12.0, native bf16; Colab release
    notes 2026-03-25). The GPU is detected at start-up and a performance profile
    is applied: bf16 AMP, no gradient checkpointing when VRAM >= 60 GB (the probe
    then fits Restormer's 64 x 128 px global batch without accumulation),
    torch.compile with a CRASH GUARD (Triton on sm_120 has an open segfault report,
    pytorch#176426: an unfinished compilation is remembered on Drive and the next
    run trains eagerly instead of crashing again). T4 / L4 / A100 / H100 are
    handled by the same rules.
  * Google Drive is mounted automatically. EVERYTHING persistent lives on Drive:
        /content/drive/MyDrive/Datasets/<GoPro|HIDE|DPDD|Rain13K|SIDD>/   datasets
        /content/drive/MyDrive/SINA-Net-v4/models/     latest.pth, best.pth, logs
        /content/drive/MyDrive/SINA-Net-v4/inferences/ restored images
        /content/drive/MyDrive/SINA-Net-v4/figures/    all figures (grids + singles)
        /content/drive/MyDrive/SINA-Net-v4/tables/     all tables (.md .tex .csv .png)
        /content/drive/MyDrive/SINA-Net-v4/ablation/   training-ablation runs
        /content/drive/MyDrive/SINA-Net-v4/REPORT.md   everything in one page
  * Sessions end (12 h, 24 h with Colab Pro+): training stops cleanly before the
    budget (measured from the VM's uptime), and re-running the cell resumes from
    Drive exactly on schedule. Checkpoints are written to the local SSD every
    10 min and latest.pth / best.pth are mirrored to Drive every 30 min and at
    every validation, stop, interrupt or crash. Only those two files live on
    Drive, because a file deleted on the Drive mount goes to the Drive Trash and
    keeps using quota for 30 days (rolling snapshots on Drive would fill it).
Datasets (downloaded ONCE, then reused from Drive in every session)
  * The FULL standard training/test sets, in the exact archives the Restormer
    authors distribute (verified byte-for-byte against their Hugging Face mirror,
    sha256-checked after download):
        GoPro   train 2,103 + test 1,111 pairs        HIDE  test 2,025 pairs
        DPDD    train 350 + val 74 + test 76 (16-bit; centre, left, right views)
        Rain13K train 13,711 + Rain100H/L, Test100/1200/2800
        SIDD    SIDD-Medium sRGB (all 320 pairs, not SIDD-small's 160) +
                the official validation blocks (ValidationNoisy/GtBlocksSrgb.mat)
    Sources, tried in order: Hugging Face mirror (fast, sha256), the authors'
    Google Drive IDs (gdown), a Drive-API copy (bypasses "quota exceeded"),
    and for SIDD the official York University server.
  * Drive stores the verified ARCHIVES under Datasets/<name>/ (a dozen large files
    upload quickly; ~50,000 loose PNGs would take hours to sync through the Drive
    mount and make every later read slow). Each session extracts them from Drive to
    the VM's local SSD, where training reads them at full speed. Extracted folders
    you place on Drive yourself are detected and used too.
Evaluation, analysis and reporting (new)
  * Per-image records (metrics, runtime, exact Parseval split of the error into 16
    radial frequency bands, error pooled by structure x degradation severity).
  * Paper-style figures (styles of Restormer, NAFNet, FFTformer, EVSSM, MambaIR):
    zoom-inset comparisons at the region where the model helps most, shared-scale
    error maps, local-gain maps, spectra, galleries of the best / hardest images,
    cross-benchmark "where it performs best" charts; grids AND single images.
  * "Confusion" matrices that are meaningful for restoration: (i) linear probes of
    the degradation signature / learned embedding (motion blur, defocus, rain,
    noise, clean) on held-out test images; (ii) quality-transition matrices
    (input PSNR bin -> restored PSNR bin); (iii) gain by pixel class.
  * Attention analysed five ways (peakedness atlas, temperature atlas, query
    footprints at true full-resolution positions, mean attention distance,
    homeostasis set point vs measured entropy + collapse rate), plus Wiener gains,
    coherence gates, degradation fingerprints, FiLM modulation and effective
    receptive fields.
  * Complexity: exact parameter counts, COMPLETE FLOPs (every executed ATen op,
    FFTs, softmax and element-wise included, nothing omitted, unknown ops listed by
    name), memory traffic, measured roofline and PURE eval-mode latency (batch 1,
    inference_mode, CUDA events) for the whole model, every main component and every
    operator type, in fp32 / TF32 / AMP / compiled.
  * SOTA tables 2021-2026 (numbers copied from each method's own paper, with
    caveats and third-party values flagged), PSNR-vs-cost bubble chart.
  * Real ablation study: paired test-time knock-outs with bootstrap CIs and Wilcoxon
    tests, optional training ablation (each component removed, retrained with an
    identical schedule, resumable across sessions), and a CLAIMS AUDIT table that
    marks every novelty claim SUPPORTED / NOT SUPPORTED / NOT TESTED from those
    measurements.

================================================================================
WHY v3 COULD NOT REMOVE BLUR (root causes found by auditing the v3 script)
================================================================================
The v3 architecture was not the main problem. The training recipe, the
evaluation protocol and a few numerical details were. In order of impact:

  R1. ~100-200x too little optimisation. v3 trained for `epochs=15`, and every
      "epoch" was 4 tasks x min(task sizes) samples. With SIDD-small (160
      pairs) as the smallest task that is ~620 samples / epoch, i.e. ~210
      steps at batch 3 -> ~3,100 optimiser steps in total. Restormer trains
      300K iterations (AdamW 3e-4 -> 1e-6, cosine, progressive patches
      128->384) and DiNAT-IR trains 600K iterations at 256x256, batch 16, then
      fine-tunes 200K more at 384x384. GoPro alone got ~2,400 training
      patches in v3's whole run. A deblurring network at 3K steps is still
      close to the identity mapping -> "the output still looks blurry".
  R2. The LR schedule was stepped once per EPOCH. `LinearLR(start_factor=1e-3)`
      therefore ran the whole first epoch at lr = 2e-7 (wasted), and cosine
      decay was quantised into 12 steps.
  R3. Evaluation was not the benchmark protocol. For every non-train split
      `_paired_transform` CENTER-CROPPED test images to `patch_size`
      (128x128). GoPro/HIDE/DPDD/Rain/SIDD numbers were computed on one tiny
      central crop per image, not on the full-resolution images the
      published tables use, and deraining PSNR/SSIM were not computed on the
      Y channel (the Restormer/MPRNet deraining protocol).
  R4. Train/test inconsistency of GLOBAL operations (Chu et al., "Improving
      Image Restoration by Revisiting Global Information Aggregation", ECCV
      2022, TLC). Their analysis shows image-level inference with global ops
      "fails to remove blurs completely". v3 had three global ops:
        * `nn.GroupNorm(1, C)` in every block normalises over C x H x W, so
          statistics come from a 64x64 patch in training but a 640x360 map
          at test time;
        * the degradation signature adaptive-avg-pooled the WHOLE input to
          64x64: a 128 patch is pooled 2x in training, a 1280x720 image
          20x/11x (anisotropically) at test time. That pooling is itself a
          low-pass filter that erases exactly the high-frequency evidence of
          blur, so the FiLM conditioning is out-of-distribution at test time;
        * the analytic signal used a full-row FFT (periodic wrap-around),
          whose border behaviour differs between patches and full images.
  R5. Silent pair misalignment risk. The generic loader sorted degraded and
      clean files independently and paired them BY INDEX after truncating to
      the shorter list; one extra/missing file shifts every later pair. A
      network trained on misaligned targets learns to average (= blur).
      DPDD/SIDD layouts were also only found if a directory was literally
      named "train"/"test" (DPDD uses train_c/test_c; SIDD-small has none).
  R6. Numerical conditioning of the novel blocks:
        * the Cohen-class unit fed |SPWVD|^2 (4th power of the features, no
          log compression) into a 1x1 conv, a dynamic range of many decades;
        * the coherence gate's LEARNABLE smoothing kernel could turn
          negative, breaking the Cauchy-Schwarz bound (coherence > 1, or a
          negative/zero denominator -> inf/NaN gradients);
        * KL-guided temperature was one-directional: T = 0.5^(KL/sigma) is in
          [0.25, 1], so an already-peaked attention row got SHARPER (positive
          feedback -> attention collapse onto the query pixel, which is
          again an identity-like, non-deblurring operator).
  R7. Loss mix tuned for perception, not fidelity: SSIM x0.5 (pyiqa's default
      SSIM is Y-channel) + LPIPS x0.1 outweighed the Charbonnier term,
      whereas the PSNR-table baselines are trained with L1 (Restormer) or a
      PSNR loss (NAFNet, DiNAT-IR).
  R8. Full-resolution inference was not feasible: `F.unfold` materialised
      C x 49 copies of K and V (about 4 GB per tensor at 1/2 resolution of a
      GoPro frame).

================================================================================
CHANGELOG v3 -> v4 (every novelty kept; each change fixes one of R1-R8)
================================================================================
Training / protocol
  * Iteration-based training (`total_iters`, default 300K = Restormer) with
    per-ITERATION warmup + cosine LR, Restormer-style progressive patch/batch
    schedule (milestones at 92K/156K/204K/240K/276K, scaled to total_iters),
    session time budget + exact resume (Colab sessions can be chained),
    optional gradient accumulation and gradient checkpointing.        [R1,R2]
  * Multi-GPU: DDP only (DataParallel + fp16 crashes with 'CUDA error: misaligned
    address'). From a notebook cell main() launches torchrun itself in fresh
    processes (forking fails once the notebook has queried CUDA). Restormer's
    GLOBAL batch schedule (64 @128 px ... 8 @384 px) is
    reached as micro-batch x GPUs x accumulation, with the per-GPU micro-batch
    auto-probed to the maximum that fits; several crops per decoded image keep
    the data loader ahead of the GPUs; a start-up plan prints the time estimate.
  * Speed: the attention and Wiener units are memory-bound (thousands of small
    fp32 element-wise kernels; convolutions are <1% of the time). The SINA and
    local blocks are torch.compile'd (static shapes, NCHW layout), verified
    against eager execution at start-up, with automatic eager fallback; the
    measured speed-up is folded into the start-up time estimate.
  * Infinite multi-task sampler (task-balanced by default) instead of
    min-size epochs; task presets for specialist training (the published
    per-task tables are all from SPECIALIST models).                     [R1]
  * Full-resolution evaluation with the standard protocols: RGB PSNR/SSIM on
    uint8 for GoPro/HIDE, Y-channel for deraining, float 16-bit for DPDD
    (+MAE), official SIDD validation blocks when the .mat files are given.
    Tiled inference fallback with the degradation signature computed ONCE on
    the full image and shared by all tiles (seam-free).                  [R3]
Architecture (novelties kept, made local / well-conditioned)
  * `LayerNorm2d` (per-pixel channel LN, as in Restormer/NAFNet) replaces
    GroupNorm(1, C).                                                     [R4]
  * `LocalAnalyticSignal`: FIR (Blackman-windowed) discrete Hilbert
    transformer. The analytic signal used by the Cohen-class Wiener unit and
    by the coherence gate becomes a LOCAL operator: identical behaviour on a
    patch, a tile or a full image, no wrap-around, no complex dtypes (AMP-safe).
                                                                         [R4,R6]
  * `CohenClassSpectralWienerUnit`: the smoothed pseudo Wigner-Ville
    distribution is now computed exactly as a REAL, signed quantity
    (Hermitian lag symmetry) and log-compressed with asinh before the PSD
    estimator. Same Wiener gain H = S/(S+N).                             [R6]
  * `KLDivergenceGuidedDiNA` -> entropy-HOMEOSTATIC neighbourhood attention:
    T = exp(g_h * (KL_n - tau_h)) with learnable per-head set point tau_h and
    gain g_h. Over-peaked rows are softened, over-flat rows sharpened
    (negative feedback, no collapse). Also: cosine-similarity logits with a
    learnable scale, a depthwise-conv on q/k/v, proper border masking
    (padded positions are excluded instead of attending to zeros), and a
    memory-efficient shifted-view implementation (no C x K^2 unfold).  [R6,R8]
  * `SpectralCoherenceGatedFusion`: smoothing kernel constrained to a convex
    combination (softmax-parametrised), so magnitude-squared coherence is
    provably in [0,1]; coherence computed on scale-free (LayerNormed) features.
                                                                         [R6]
  * `RadialAngularSpectralSignature` -> Welch-averaged, NATIVE-RESOLUTION
    signature: Hann-windowed 64x64 periodograms averaged over all windows of
    the image (no rescaling, so a frequency bin means the same cycles/pixel
    at train and test time), angular bins folded onto [0, pi) (spectra of real
    images are point-symmetric), inscribed-disc radial bins, plus three
    interpretable scalars: mean log-power, radial spectral SLOPE (natural
    images ~ -2; blur steepens it, noise flattens it) and angular ANISOTROPY
    (motion-blur direction, rain streak orientation).                    [R4]
  * `DegradationConditioner`: per-sample LayerNorm over heterogeneous
    signature entries replaced by a running standardiser (deterministic,
    train/test consistent); separate zero-initialised FiLM heads for encoder
    and decoder levels.                                                  [R4]
Loss
  * Default = fidelity recipe: Charbonnier + 0.05 Laplacian edge + FFT L1
    (orthonormal FFT -> weight no longer depends on patch size) + NEW
    `RadialSpectralProfileLoss` (log azimuthal-integral power spectrum,
    cf. Durall et al., CVPR 2020): a phase-free penalty on the radial
    high-frequency power deficit that IS residual blur. SSIM/LPIPS are
    optional (0 by default).                                             [R7]
Data
  * cv2-based reading (16-bit DPDD kept at 16-bit precision), key-based pairing
    only (relative path, then normalised stem, never by index), dedicated
    DPDD (train_c/test_c, inputC) and SIDD (NOISY_*/GT_* files) parsers,
    scene-level SIDD hold-out when no test split exists, a pair audit that
    prints the input PSNR of each task and flags misalignment, and a tile
    cache for very large images (SIDD 4-5K frames) so decoding does not starve
    the GPU. 8-way dihedral augmentation (Restormer).                    [R5]
Kept from v3: TLS-verified downloads, EMA (now with warm-up decay), bf16/fp16
AMP with fp32 islands, multi-scale supervision, self-ensemble TTA,
interpretability maps, thop-free MAC counter (counts FFT-free custom ops
analytically instead of silently ignoring them).

HOW TO RUN IN GOOGLE COLAB
  1. Runtime -> Change runtime type -> G4 GPU (any GPU works; G4 is the target).
  2. Paste this whole file into ONE cell and run it. It mounts Google Drive (approve
     the pop-up), installs what is missing, downloads the datasets to Drive the first
     time, trains, evaluates and writes figures / tables / REPORT.md to Drive.
     Edit the Config below (or pass --preset) to choose the task:
        all_in_one (default) | deblur | defocus | derain | denoise
  3. When the session ends, open a new one and run the same cell again: it resumes.
  Shell alternative:  !python sina_net_v4_colab.py --preset deblur
                      (mount Drive in a cell first: from google.colab import drive;
                       drive.mount('/content/drive'))
  Evaluation only:    !python sina_net_v4_colab.py --preset deblur --eval-only
  Sanity check:       python sina_net_v4_colab.py --selftest   (CPU, synthetic data, minutes)
"""

import os
import re
import sys
import csv
import glob
import shutil
import copy
import time
import math
import json
import random
import hashlib
import argparse
import tempfile
import contextlib
import subprocess
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, asdict
from typing import Sequence, Optional, List, Tuple, Dict, Callable

import numpy as np
import cv2
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader, ConcatDataset, Sampler
from torch.utils.checkpoint import checkpoint as grad_checkpoint
from tqdm.auto import tqdm

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import colors as mcolors
from matplotlib.patches import Rectangle

cv2.setNumThreads(0)  # cv2's own thread pool fights with DataLoader workers
SCRIPT_START = time.time()


# ==============================================================================
# 0. GOOGLE COLAB RUNTIME (Drive, folders, packages, GPU profile)
# ==============================================================================
def _detect_colab() -> bool:
    if "google.colab" in sys.modules:
        return True
    return bool(os.environ.get("COLAB_RELEASE_TAG") or os.environ.get("COLAB_GPU") is not None
                or os.environ.get("COLAB_BACKEND_VERSION"))


IN_COLAB = _detect_colab()
DRIVE_MOUNT = "/content/drive"
DRIVE_ROOT = os.environ.get("SINA_DRIVE_ROOT", os.path.join(DRIVE_MOUNT, "MyDrive") if IN_COLAB
                            else os.path.abspath("sina_drive"))
DATASETS_ROOT = os.path.join(DRIVE_ROOT, "Datasets")
PROJECT_ROOT = os.path.join(DRIVE_ROOT, "SINA-Net-v4")
LOCAL_ROOT = os.environ.get("SINA_LOCAL_ROOT", "/content/sina_local" if IN_COLAB
                            else os.path.join(tempfile.gettempdir(), "sina_local"))
ENV_INFO: Dict[str, str] = {}


def mount_drive(mount_point: str = DRIVE_MOUNT) -> bool:
    """Mounts Google Drive (interactive approval the first time). Works from a notebook cell;
    a `!python` subprocess cannot show the approval pop-up, so there the Drive must already be
    mounted by the notebook."""
    if os.path.isdir(os.path.join(mount_point, "MyDrive")):
        return True
    try:
        from google.colab import drive
        drive.mount(mount_point)
    except Exception as e:
        print(f"[colab] could not mount Google Drive from this process ({type(e).__name__}: {e}).\n"
              f"        Run this in a notebook cell first, then run the script again:\n"
              f"            from google.colab import drive; drive.mount('{mount_point}')")
    return os.path.isdir(os.path.join(mount_point, "MyDrive"))


def ensure_packages(packages: Sequence[str]) -> bool:
    """pip-installs missing packages (import name -> pip name). Returns True if all import."""
    pip_name = {"sklearn": "scikit-learn", "cv2": "opencv-python-headless", "huggingface_hub": "huggingface_hub"}
    missing = []
    for p in packages:
        try:
            __import__(p)
        except ImportError:
            missing.append(p)
    if missing:
        cmd = [sys.executable, "-m", "pip", "install", "-q"] + [pip_name.get(p, p) for p in missing]
        print(f"[setup] installing {', '.join(pip_name.get(p, p) for p in missing)} ...")
        try:
            subprocess.run(cmd, check=False, timeout=900)
        except Exception as e:
            print(f"[setup] pip failed: {e}")
    ok = True
    for p in missing:
        try:
            __import__(p)
        except ImportError:
            ok = False
    return ok


def _free_gb(path: str) -> float:
    try:
        p = path
        while not os.path.exists(p) and os.path.dirname(p) != p:
            p = os.path.dirname(p)
        return shutil.disk_usage(p).free / 2 ** 30
    except OSError:
        return float("nan")


def apply_gpu_profile(cfg: "Config") -> str:
    """Performance settings from the detected GPU (the training RECIPE is never changed).
    G4 = NVIDIA RTX PRO 6000 Blackwell Server Edition (96 GB, sm_120, native bf16/TF32/FP8)."""
    if cfg.gpu_profile == "none" or not (cfg.device.startswith("cuda") and torch.cuda.is_available()):
        return "none"
    props = torch.cuda.get_device_properties(0)
    name = props.name
    mem = props.total_memory / 2 ** 30
    cap = torch.cuda.get_device_capability(0)
    low = name.lower()
    label = ("G4 (RTX PRO 6000 Blackwell)" if ("rtx pro 6000" in low or "blackwell" in low) else
             "H100" if "h100" in low else "A100" if "a100" in low else "L4" if "l4" in low else
             "T4" if "t4" in low else name)
    cfg.prefer_bf16 = cap[0] >= 8
    cfg.use_checkpoint = mem < 60          # 80-96 GB cards fit the full batches without recomputation
    cfg.probe_memory_fraction = 0.85 if mem >= 30 else 0.80
    if cfg.num_workers < 0:
        cfg.num_workers = max(2, min(os.cpu_count() or 2, 32))
    if cap[0] < 7:                          # Triton/Inductor needs sm_70+
        cfg.compile_model = False
    print(f"[gpu] {name}: {mem:.0f} GB, compute capability {cap[0]}.{cap[1]} -> profile '{label}': "
          f"AMP {'bf16' if cfg.prefer_bf16 else 'fp16'}, gradient checkpointing {'on' if cfg.use_checkpoint else 'off'}, "
          f"probe fraction {cfg.probe_memory_fraction}, torch.compile {'on (crash-guarded)' if cfg.compile_model else 'off'}, "
          f"{cfg.num_workers} data workers")
    return label


def colab_setup(cfg: "Config"):
    """Mount Drive, create the folders, install missing packages, apply the GPU profile and
    record the environment for the report."""
    on_drive = os.path.abspath(cfg.project_root).startswith(os.path.abspath(DRIVE_MOUNT) + os.sep)
    if IN_COLAB and on_drive and not mount_drive():
        if os.environ.get("SINA_ALLOW_NO_DRIVE") != "1":
            raise RuntimeError("Google Drive is not mounted, so nothing would persist beyond this session. Mount it "
                               "(from google.colab import drive; drive.mount('/content/drive')) and run again, or set "
                               "the environment variable SINA_ALLOW_NO_DRIVE=1 to work on the local disk only.")
    for d in (cfg.project_root, cfg.checkpoint_dir, cfg.output_dir, cfg.figures_dir, cfg.tables_dir, cfg.ablation_dir,
              cfg.datasets_root, cfg.local_root):
        os.makedirs(d, exist_ok=True)
    ensure_packages(["scipy", "sklearn", "requests"])
    label = apply_gpu_profile(cfg)
    if cfg.device.startswith("cuda") and torch.cuda.is_available():
        torch.backends.cuda.matmul.allow_tf32 = cfg.allow_tf32
        torch.backends.cudnn.allow_tf32 = cfg.allow_tf32
    ENV_INFO.clear()
    ENV_INFO.update({
        "platform": "Google Colab" if IN_COLAB else sys.platform,
        "gpu": (f"{torch.cuda.get_device_name(0)} ({torch.cuda.get_device_properties(0).total_memory / 2 ** 30:.0f} GB, "
                f"sm_{''.join(map(str, torch.cuda.get_device_capability(0)))})") if torch.cuda.is_available() else "none (CPU)",
        "gpu profile": label, "torch": torch.__version__, "cuda": str(torch.version.cuda),
        "cpus": str(os.cpu_count()), "local free (GB)": f"{_free_gb(cfg.local_root):.0f}",
        "drive free (GB)": f"{_free_gb(cfg.project_root):.0f}", "project folder": cfg.project_root,
        "datasets folder": cfg.datasets_root,
    })
    print("[env] " + " | ".join(f"{k}: {v}" for k, v in ENV_INFO.items()))


# ==============================================================================
# 1. CONFIGURATION
# ==============================================================================
ALL_TASKS = ("GoPro", "DPDD", "Rain13K", "SIDD")
ALL_DATASETS = ("GoPro", "HIDE", "DPDD", "Rain13K", "SIDD")


@dataclass
class Config:
    # System
    device: str = "cuda" if torch.cuda.is_available() else "cpu"
    seed: int = 42
    use_amp: bool = True
    prefer_bf16: bool = True  # bf16 on Ampere+ / Blackwell (G4); fp16 + GradScaler on T4
    allow_tf32: bool = False  # the fp32 'islands' (SPWVD, coherence) are kept at true fp32
    gpu_profile: str = "auto"  # "auto" (detect: G4 / H100 / A100 / L4 / T4) | "none"

    # Which tasks to train on. Published GoPro/DPDD/Rain/SIDD tables are from
    # SPECIALIST models; use a preset ("deblur", "defocus", "derain",
    # "denoise") to reproduce that setting, "all_in_one" for the joint model.
    train_tasks: Tuple[str, ...] = ALL_TASKS
    task_sampling: str = "uniform"  # "uniform" | "sqrt" | "size"

    # Google Drive / Colab storage
    project_root: str = PROJECT_ROOT      # everything persistent (Drive)
    datasets_root: str = DATASETS_ROOT    # /content/drive/MyDrive/Datasets
    local_root: str = LOCAL_ROOT          # fast local SSD of the Colab VM (lost when the session ends)
    download_datasets: str = "all"        # "all" (all five, needed by the degradation probe) | "needed" | "none"
    stage_datasets_locally: bool = True   # extract / copy to the local SSD for fast training I/O
    verify_sha256: bool = True            # hash every downloaded archive against the published sha256
    drive_sync_minutes: float = 30.0      # latest.pth -> Drive at most this often (plus every validation / stop)

    # Dataset paths (set automatically after download; point them elsewhere to use your own copies)
    path_gopro: str = os.path.join(DATASETS_ROOT, "GoPro")
    path_hide: str = os.path.join(DATASETS_ROOT, "HIDE")
    path_dpdd: str = os.path.join(DATASETS_ROOT, "DPDD")
    path_rain13k: str = os.path.join(DATASETS_ROOT, "Rain13K")
    path_sidd: str = os.path.join(DATASETS_ROOT, "SIDD")
    # Folder containing ValidationNoisyBlocksSrgb.mat + ValidationGtBlocksSrgb.mat
    # (the official SIDD benchmark used by Restormer/DiNAT-IR). Downloaded automatically.
    path_sidd_val: str = os.path.join(DATASETS_ROOT, "SIDD")
    sidd_holdout_fraction: float = 0.1  # only used when the official validation blocks are missing
    # If a configured path is missing or holds no usable pairs, datasets are searched for here
    # (by folder name: gopro / hide / dpdd, dd_dp, defocus / rain13k, derain / sidd).
    search_roots: Tuple[str, ...] = (os.path.join(LOCAL_ROOT, "datasets"), DATASETS_ROOT)

    # Multi-GPU (DistributedDataParallel only). "auto": under torchrun use its processes; with >1
    # GPU and no torchrun (e.g. main() in a notebook cell), main() launches torchrun itself in fresh
    # processes and streams their log. "none" forces a single GPU. Colab has one GPU per VM.
    multi_gpu: str = "auto"
    notebook_ddp_procs: int = 0      # 0 = one per visible GPU
    # torch.compile of the SINA / local blocks: fuses their long chains of element-wise ops (the
    # attention and Wiener units are memory-bound, not FLOP-bound). Verified against eager execution
    # at start-up; falls back to eager on any failure, and after a native crash (crash guard).
    compile_model: bool = True
    compile_on_cpu: bool = False     # tests only

    # Data pipeline
    num_workers: int = -1            # -1 = auto: CPU cores of the Colab VM (capped at 32)
    crops_per_image: int = 4         # random crops taken from each decoded pair at 128 px (scaled by
                                     # (128/patch)^2): 4x fewer PNG decodes for large batches
    val_fraction: float = 0.03       # carved out of TRAIN per task (DPDD uses its official val split)
    val_crop: int = 256
    max_val_per_task: int = 40
    cache_dir: str = ""              # tile cache for very large images; "" = <local_root>/tile_cache
    large_image_side: int = 2500     # images larger than this are pre-tiled once per session
    cache_tile_size: int = 512
    cache_tiles_per_image: int = 24

    # Model architecture (index 0 = full resolution, 3 = bottleneck)
    in_channels: int = 3
    out_channels: int = 3
    dims: Sequence[int] = (48, 96, 192, 384)
    enc_blocks: Sequence[int] = (2, 3, 3)
    bottleneck_blocks: int = 4
    dec_blocks: Sequence[int] = (3, 3, 2)
    refinement_blocks: int = 2
    num_heads: int = 8
    dilation_cycle: Sequence[int] = (1, 2, 4)
    attn_kernel_size: int = 7
    global_block_min_level: int = 1
    wiener_lag: int = 2
    hilbert_taps: int = 31           # FIR Hilbert length: accurate for periods ~2-16 px per level
    kl_target_init: float = 0.35     # initial per-head attention-entropy set point
    use_checkpoint: bool = True      # gradient checkpointing of SINA blocks (auto: off on >= 60 GB GPUs)
    # Component switches for the TRAINING ablation (all True = SINA-Net v4, identical state_dict)
    use_wiener: bool = True
    use_homeostasis: bool = True
    use_coherence_fusion: bool = True
    use_degradation_conditioning: bool = True

    # Degradation-aware spectral conditioning
    sig_radial_bins: int = 8
    sig_angular_bins: int = 8
    sig_window: int = 64
    sig_max_windows: int = 1024
    sig_hidden_dim: int = 128

    # Multi-scale (deep) decoder supervision
    use_multiscale_supervision: bool = True
    aux_weight: float = 0.1

    # Training (ITERATION based)
    total_iters: int = 300_000
    lr: float = 3e-4
    min_lr: float = 1e-6
    warmup_iters: int = 2_000
    weight_decay: float = 1e-4
    betas: Tuple[float, float] = (0.9, 0.999)
    max_grad_norm: float = 1.0
    # (start_iter_fraction, patch_size, GLOBAL batch size) = Restormer's exact progressive
    # schedule: batch 64 at 128 px, milestones 92K/156K/204K/240K/276K of 300K. The global batch
    # is reached as micro-batch x GPUs x gradient accumulation; the per-GPU micro-batch is the
    # largest that fits (measured at start-up), so memory is used to the maximum.
    progressive_schedule: List[Tuple[float, int, int]] = field(default_factory=lambda: [
        (0.000, 128, 64), (0.307, 160, 40), (0.520, 192, 32),
        (0.680, 256, 16), (0.800, 320, 8), (0.920, 384, 8)])
    max_micro_batch: int = 0         # 0 = auto-probe per patch size on each GPU; >0 = fixed cap
    probe_memory_fraction: float = 0.85  # fraction of GPU memory the probe may plan to use
    max_session_hours: float = 11.5  # Colab: "at most 12 hours" (FAQ); 23.5 with Pro+ background execution
    log_every: int = 100
    val_every: int = 5_000           # validation + best.pth selection
    save_every: int = 1_000          # local checkpoint every N iterations ...
    save_every_minutes: float = 10.0  # ... or every N minutes, whichever comes first
    keep_last_checkpoints: int = 3   # rolling local iter_XXXXXXX.pth snapshots (only latest/best go to Drive)
    checkpoint_dir: str = ""         # "" = <project_root>/models (Drive)
    resume_training: bool = True     # auto-resume from the newest valid checkpoint found
    # File OR folder of a previous run (e.g. another Drive folder). The newest valid checkpoint
    # among it, checkpoint_dir and the local working folder is used.
    resume_from: Optional[str] = None
    evaluate_if_incomplete: bool = False  # skip the long test-set evaluation after a time-budget stop

    # EMA
    use_ema: bool = True
    ema_decay: float = 0.999

    # Loss weights (fidelity recipe by default)
    lambda_char: float = 1.0
    lambda_edge: float = 0.05
    lambda_freq: float = 1.0      # orthonormal-FFT L1 (== DeepRFT 0.01 x unnormalised FFT at ~128 px)
    lambda_radial: float = 0.001  # radial log-power-spectrum loss (new); grad ~0.4x Charbonnier on blurry
                                  # outputs, fading to ~0.1x near the ground truth (ablate 0 vs 0.001)
    lambda_ssim: float = 0.0
    lambda_lpips: float = 0.0     # needs `pip install pyiqa`; trades PSNR for perception
    charbonnier_eps: float = 1e-3

    # Evaluation / inference
    run_training: bool = True
    run_evaluation: bool = True
    run_benchmark: bool = True
    output_dir: str = ""           # "" = <project_root>/inferences
    figures_dir: str = ""          # "" = <project_root>/figures
    tables_dir: str = ""           # "" = <project_root>/tables
    ablation_dir: str = ""         # "" = <project_root>/ablation
    inference_tile: int = 0        # 0 = full image (auto-falls back to tiles on OOM)
    fallback_tile: int = 512
    tile_overlap: int = 128
    max_test_images: Optional[int] = None
    save_interpretability_maps: bool = True
    num_visualization_samples: int = 3  # 'typical' images (closest to the median gain) with full figure sets
    use_self_ensemble_tta: bool = False
    eval_lpips: bool = True         # LPIPS-Alex column (DPDD tables report it); needs `pip install lpips`

    # Analysis suite (figures), complexity profile, ablation study
    run_analysis: bool = True
    run_interpretability: bool = True
    run_erf: bool = True
    run_probe: bool = True
    probe_max_per_class: int = 60
    attn_crop: int = 256
    gallery_k: int = 6
    zoom_box: int = 0              # 0 = auto (1/5 of the short side, 32..160 px)
    zoom_boxes: int = 2
    save_pdf: bool = False
    run_complexity: bool = True
    complexity_sizes: Tuple[Tuple[int, int], ...] = ((256, 256), (720, 1280))
    speed_warmup: int = 20
    speed_iters: int = 100
    profile_compiled: bool = True
    run_knockout_ablation: bool = True
    ablation_sets: Tuple[str, ...] = ()  # () = the primary test set of every trained task
    ablation_max_images: int = 50
    ablation_tta: bool = True
    run_training_ablation: bool = False  # hours of GPU time: opt in (resumable across sessions)
    ablation_task: str = ""        # "" = first training task
    ablation_variants: Tuple[str, ...] = ("full", "no_wiener", "no_homeostasis", "no_coherence",
                                          "no_conditioning", "no_radial_loss")
    ablation_iters: int = 20_000
    ablation_patch: int = 128
    ablation_batch: int = 16
    ablation_eval_images: int = 100

    def __post_init__(self):
        self.checkpoint_dir = self.checkpoint_dir or os.path.join(self.project_root, "models")
        self.output_dir = self.output_dir or os.path.join(self.project_root, "inferences")
        self.figures_dir = self.figures_dir or os.path.join(self.project_root, "figures")
        self.tables_dir = self.tables_dir or os.path.join(self.project_root, "tables")
        self.ablation_dir = self.ablation_dir or os.path.join(self.project_root, "ablation")
        self.cache_dir = self.cache_dir or os.path.join(self.local_root, "tile_cache")
        assert len(self.dims) == 4 and len(self.enc_blocks) == 3 and len(self.dec_blocks) == 3
        for d in self.dims[self.global_block_min_level:]:
            assert d % self.num_heads == 0, f"dim {d} not divisible by num_heads {self.num_heads}."
        assert self.hilbert_taps % 2 == 1 and self.attn_kernel_size % 2 == 1
        assert 0 <= self.warmup_iters < self.total_iters
        assert self.progressive_schedule and self.progressive_schedule[0][0] == 0.0
        for _, p, b in self.progressive_schedule:
            assert p % 8 == 0 and p >= self.sig_window, "patch sizes must be multiples of 8 and >= sig_window"
            assert b >= 1
        assert 0.0 <= self.val_fraction < 1.0
        assert self.multi_gpu in ("auto", "ddp", "none"), "DataParallel ('dp') is not supported; use DDP"
        assert 0.3 <= self.probe_memory_fraction <= 0.95 and self.crops_per_image >= 1
        assert self.download_datasets in ("all", "needed", "none")
        for t in self.train_tasks:
            assert t in ALL_TASKS, f"unknown task {t}"
        for v in self.ablation_variants:
            assert v in ("full", "no_wiener", "no_homeostasis", "no_coherence", "no_conditioning", "no_radial_loss"), v


def apply_preset(cfg: Config, name: str) -> Config:
    """Specialist presets reproduce the per-task setting of the published tables."""
    name = (name or "all_in_one").lower()
    presets = {
        "all_in_one": ALL_TASKS,
        "deblur": ("GoPro",),
        "defocus": ("DPDD",),
        "derain": ("Rain13K",),
        "denoise": ("SIDD",),
    }
    if name not in presets:
        raise ValueError(f"unknown preset {name}; choose from {list(presets)}")
    cfg.train_tasks = presets[name]
    return cfg


# ==============================================================================
# 1b. MULTI-GPU RUNTIME (DDP: torchrun, or torchrun launched from a notebook)
# ==============================================================================
@dataclass
class DistInfo:
    mode: str = "none"      # "none" | "ddp"
    rank: int = 0
    local_rank: int = 0
    world: int = 1          # number of training PROCESSES (DDP ranks)
    gpus_per_proc: int = 1  # always 1 (one process per GPU)

    @property
    def is_main(self) -> bool:
        return self.rank == 0

    @property
    def ddp(self) -> bool:
        return self.mode == "ddp"

    @property
    def total_gpus(self) -> int:
        return self.world * self.gpus_per_proc


DIST = DistInfo()
_BUILTIN_PRINT = print


def setup_distributed(config: Config) -> DistInfo:
    """WORLD_SIZE/RANK/LOCAL_RANK (set by torchrun or by the notebook launcher)
    -> one process per GPU (DDP; NCCL on GPUs, gloo on CPU). Non-main ranks are silenced."""
    global DIST
    import builtins
    world = int(os.environ.get("WORLD_SIZE", "1"))
    if world > 1 and config.multi_gpu in ("auto", "ddp"):
        import torch.distributed as dist
        from datetime import timedelta
        if not dist.is_initialized():
            backend = "nccl" if torch.cuda.is_available() else "gloo"
            local0 = int(os.environ.get("LOCAL_RANK", "0"))
            try:  # naming the device silences the barrier / 'guessing device ID' warnings
                dist.init_process_group(backend, timeout=timedelta(minutes=60),
                                        **({"device_id": torch.device(f"cuda:{local0}")} if backend == "nccl" else {}))
            except TypeError:  # older PyTorch without device_id
                dist.init_process_group(backend, timeout=timedelta(minutes=60))
        rank = dist.get_rank()
        local = int(os.environ.get("LOCAL_RANK", rank))
        if torch.cuda.is_available():
            torch.cuda.set_device(local)
            config.device = f"cuda:{local}"
        DIST = DistInfo("ddp", rank, local, dist.get_world_size(), 1)
        builtins.print = _BUILTIN_PRINT if rank == 0 else (lambda *a, **k: None)
    else:
        DIST = DistInfo()
    if DIST.mode != "none":
        print(f"[multi-gpu] mode={DIST.mode} processes={DIST.world} GPUs={DIST.total_gpus}")
    return DIST


def _coll_device() -> torch.device:
    return torch.device(f"cuda:{DIST.local_rank}") if (DIST.ddp and torch.cuda.is_available()) else torch.device("cpu")


def dist_barrier():
    if DIST.ddp:
        import torch.distributed as dist
        dist.barrier()


def dist_all_reduce(values: List[float], op: str = "max") -> List[float]:
    """Keeps every rank's control flow identical (stop flags, micro-batch caps)."""
    if not DIST.ddp:
        return list(values)
    import torch.distributed as dist
    t = torch.tensor(values, dtype=torch.float64, device=_coll_device())
    dist.all_reduce(t, op=dist.ReduceOp.MAX if op == "max" else dist.ReduceOp.MIN)
    return t.tolist()


def dist_cleanup():
    if DIST.ddp:
        import torch.distributed as dist
        if dist.is_initialized():
            dist.destroy_process_group()


def _notebook_ddp_procs(config: Config) -> int:
    """How many DDP processes main() should launch (0 = train in this process)."""
    if config.multi_gpu == "none" or "WORLD_SIZE" in os.environ:
        return 0
    if not config.device.startswith("cuda"):
        return config.notebook_ddp_procs if config.notebook_ddp_procs > 1 else 0  # CPU test mode (gloo)
    if not torch.cuda.is_available():
        return 0
    n = min(config.notebook_ddp_procs or torch.cuda.device_count(), torch.cuda.device_count())
    return n if n > 1 else 0


def _script_for_launch(config: Config) -> Optional[str]:
    """Path of a runnable copy of THIS code. Works when it lives in a .py file and
    when it was pasted into a notebook cell: IPython keeps each cell's source in
    linecache under a virtual /tmp/ipykernel_*/<hash>.py name, which is written to a
    real file next to the checkpoints."""
    import inspect
    import linecache
    fname = inspect.getsourcefile(_script_for_launch) or ""
    in_cell = os.path.basename(os.path.dirname(fname)).startswith("ipykernel_") or not os.path.isfile(fname)
    if fname and not in_cell:
        return fname
    lines = linecache.getlines(fname) if fname else []
    if not lines:
        return None
    # notebook magics (!pip ..., %time ...) are transformed into statements that start with an
    # IPython call; they cannot run in a plain script, so they become `pass`
    magic = "get_" + "ipython()."
    src = "".join((ln[:len(ln) - len(ln.lstrip())] + "pass  # notebook magic removed\n")
                  if ln.lstrip().startswith(magic) else ln for ln in lines)
    try:
        compile(src, "sina_net_v4_ddp.py", "exec")
    except SyntaxError as e:
        print(f"[multi-gpu] the notebook cell is not a plain Python script ({e}).")
        return None
    out = os.path.join(config.local_root, "sina_net_v4_ddp.py")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write(src)
    return out


_TUPLE_FIELDS = ("train_tasks", "dims", "enc_blocks", "dec_blocks", "dilation_cycle", "betas", "search_roots",
                 "ablation_sets", "ablation_variants")


def _config_from_json(path: str) -> Config:
    with open(path) as f:
        d = json.load(f)
    d = {k: v for k, v in d.items() if k in Config.__dataclass_fields__}
    for k in _TUPLE_FIELDS:
        if isinstance(d.get(k), list):
            d[k] = tuple(d[k])
    if isinstance(d.get("complexity_sizes"), list):
        d["complexity_sizes"] = tuple(tuple(x) for x in d["complexity_sizes"])
    if "progressive_schedule" in d:
        d["progressive_schedule"] = [tuple(x) for x in d["progressive_schedule"]]
    return Config(**d)


def _launch_ddp_subprocess(config: Config, n: int) -> bool:
    """Runs `python -m torch.distributed.run --standalone --nproc_per_node=n <script>`
    in FRESH processes (exactly what `!torchrun` does), passing this Config as JSON
    and streaming the log into the notebook. Fresh processes are immune to CUDA
    state in the notebook process (forking fails once anything has queried CUDA).
    Interrupting the cell asks the training processes to save and stop."""
    import signal as _signal
    script = _script_for_launch(config)
    if script is None:
        print(f"[multi-gpu] could not locate this script's source; continuing on ONE GPU. For {n} GPUs run: "
              f"!torchrun --standalone --nproc_per_node={n} sina_net_v4_colab.py")
        return False
    out_dir = config.local_root
    os.makedirs(out_dir, exist_ok=True)
    cfg_path = os.path.join(out_dir, "sina_launch_config.json")
    with open(cfg_path, "w") as f:
        json.dump(asdict(config), f, indent=1, default=list)
    if config.device.startswith("cuda") and torch.cuda.is_initialized():
        held = sum(torch.cuda.memory_reserved(i) for i in range(torch.cuda.device_count()))
        if held > 0:
            print(f"[multi-gpu] WARNING: this notebook still holds {held / 2 ** 30:.1f} GB of GPU memory (e.g. from an "
                  f"earlier run), which the training processes cannot use. Restart the kernel to free it.")
    cmd = [sys.executable, "-m", "torch.distributed.run", "--standalone", f"--nproc_per_node={n}", script]
    env = dict(os.environ, SINA_CONFIG_JSON=cfg_path, SINA_LAUNCHED="1", PYTHONUNBUFFERED="1")
    env.setdefault("TORCH_CPP_LOG_LEVEL", "ERROR")  # hides c10d hostname notices; errors still raise
    print(f"[multi-gpu] launching {n} DDP training processes (one per GPU):\n  {' '.join(cmd)}")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True, bufsize=1)
    try:
        for line in proc.stdout:
            print(line, end="", flush=True)
        rc = proc.wait()
    except KeyboardInterrupt:
        print("\n[multi-gpu] interrupted: asking the training processes to save a checkpoint and stop...")
        proc.send_signal(_signal.SIGTERM)
        try:
            proc.wait(timeout=300)
        except subprocess.TimeoutExpired:
            proc.kill()
        raise
    if rc != 0:
        raise RuntimeError(f"The DDP training processes exited with code {rc} (see the log above). "
                           f"Checkpoints are in {config.checkpoint_dir}; running main() again resumes.")
    return True


def _tqdm_kw() -> dict:
    """Launched from a notebook, progress bars are streamed line by line: refresh rarely."""
    return {"mininterval": 60.0} if os.environ.get("SINA_LAUNCHED") else {}


# ==============================================================================
# 2. DATASET PIPELINE
# ==============================================================================
IMG_EXTS = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"}
_SPLIT_ALIASES = {
    "train": {"train", "training", "trainset"},
    "test": {"test", "testing", "testset"},
    "val": {"val", "valid", "validation", "valset"},
}
_DEGRADATION_TOKENS = r"(norain|rainy|rain|noisy|noise|blurred|blur|sharp|input|inputc|target|clean|gt|lq|hq|source|degraded)"


def read_image(path: str) -> np.ndarray:
    """RGB float32 HWC in [0,1]; keeps 16-bit precision (DPDD is 16-bit PNG)."""
    img = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise IOError(f"unreadable image: {path}")
    if img.ndim == 2:
        img = np.stack([img] * 3, axis=-1)
    elif img.shape[2] == 4:
        img = img[..., :3]
    img = img[..., ::-1]
    if img.dtype == np.uint16:
        img = img.astype(np.float32) / 65535.0
    elif img.dtype == np.uint8:
        img = img.astype(np.float32) / 255.0
    else:
        img = img.astype(np.float32)
    return np.ascontiguousarray(img)


def _image_size(path: str) -> Tuple[int, int]:
    try:
        from PIL import Image
        with Image.open(path) as im:
            return im.size  # (w, h), header only
    except Exception:
        img = cv2.imread(path, cv2.IMREAD_UNCHANGED)
        return (img.shape[1], img.shape[0]) if img is not None else (0, 0)


def _list_images(root: str) -> List[str]:
    out = []
    for dp, _, fs in os.walk(root, followlinks=True):
        for f in fs:
            if os.path.splitext(f)[1].lower() in IMG_EXTS:
                out.append(os.path.join(dp, f))
    return sorted(out)


def _norm_key(rel_no_ext: str) -> str:
    """Strip degradation tokens so rain-001 <-> norain-001, NOISY_SRGB_010 <-> GT_SRGB_010."""
    k = rel_no_ext.lower().replace("\\", "/")
    k = re.sub(rf"(^|(?<=[/_\-.])){_DEGRADATION_TOKENS}(?=$|[/_\-.])", "", k)
    k = re.sub(r"[_\-.]{2,}", "_", k)
    return re.sub(r"(^|/)[_\-.]+|[_\-.]+($|/)", r"\1\2", k)


def _pair_dirs(deg_dir: str, clean_dir: str) -> Tuple[List[Tuple[str, str]], int]:
    """Key-based pairing ONLY (relative path, then normalised key, then unique stem).
    Never pairs by sorted index (v3 bug R5)."""
    degs, cleans = _list_images(deg_dir), _list_images(clean_dir)

    def rel(p, base):
        return os.path.splitext(os.path.relpath(p, base))[0].replace("\\", "/")

    exact = {rel(c, clean_dir).lower(): c for c in cleans}
    normed: Dict[str, List[str]] = {}
    for c in cleans:
        normed.setdefault(_norm_key(rel(c, clean_dir)), []).append(c)
    stems: Dict[str, List[str]] = {}
    for c in cleans:
        stems.setdefault(os.path.splitext(os.path.basename(c))[0].lower(), []).append(c)

    pairs, unmatched = [], 0
    for d in degs:
        r = rel(d, deg_dir)
        c = exact.get(r.lower())
        if c is None:
            cand = normed.get(_norm_key(r), [])
            c = cand[0] if len(cand) == 1 else None
        if c is None:
            cand = stems.get(os.path.splitext(os.path.basename(d))[0].lower(), [])
            c = cand[0] if len(cand) == 1 else None
        if c is None:
            unmatched += 1
            continue
        pairs.append((d, c))
    return pairs, unmatched


def _split_match(parts: List[str], split: str) -> bool:
    aliases = _SPLIT_ALIASES.get(split, {split})
    return any(p.split("_")[0] in aliases for p in parts)


def discover_pairs(root: str, deg_names: Sequence[str], clean_names: Sequence[str],
                   split: Optional[str] = None, subset: Optional[str] = None,
                   exclude_part=None, verbose_name: str = "") -> List[Tuple[str, str]]:
    """Walk `root`; wherever a directory has a degraded-named AND a clean-named
    child, pair the files of those two children by key. Handles flat
    (train/blur, train/sharp) and nested (train/SEQ/blur, SEQ/sharp) layouts."""
    if not root or not os.path.isdir(root):
        return []
    pairs, total_unmatched = [], 0
    for dp, dirnames, _ in os.walk(root, followlinks=True):
        lower = {d.lower(): d for d in dirnames}
        deg = next((lower[n] for n in deg_names if n in lower), None)
        cln = next((lower[n] for n in clean_names if n in lower), None)
        if deg is None or cln is None:
            continue
        parts = [p.lower() for p in os.path.relpath(dp, root).split(os.sep) if p not in (".", "")]
        parts_with_root = [os.path.basename(os.path.normpath(root)).lower()] + parts
        if split and not _split_match(parts_with_root, split):
            continue
        if subset and subset.lower() not in parts_with_root:
            continue
        if exclude_part and any(exclude_part(p) for p in parts_with_root):
            continue
        p, un = _pair_dirs(os.path.join(dp, deg), os.path.join(dp, cln))
        pairs.extend(p)
        total_unmatched += un
        dirnames[:] = [d for d in dirnames if d not in (deg, cln)]
    if total_unmatched:
        print(f"  [{verbose_name}] {total_unmatched} degraded files had no clean counterpart and were skipped.")
    return sorted(set(pairs))


def _discover_sidd_files(root: str) -> List[Tuple[str, str]]:
    """SIDD-small/medium: [NNNN_]NOISY_SRGB_xxx.PNG and [NNNN_]GT_SRGB_xxx.PNG side by side."""
    pairs = []
    if not root or not os.path.isdir(root):
        return pairs
    for dp, _, fs in os.walk(root, followlinks=True):
        names = {f.lower(): f for f in fs if os.path.splitext(f)[1].lower() in IMG_EXTS}
        for low, f in names.items():
            if "noisy" in low:
                gt = names.get(low.replace("noisy", "gt"))
                if gt is not None:
                    pairs.append((os.path.join(dp, f), os.path.join(dp, gt)))
    return sorted(pairs)


def discover_task_pairs(task: str, root: str, split: str, subset: Optional[str] = None,
                        seed: int = 0, sidd_holdout: float = 0.1) -> Tuple[List[Tuple[str, str]], str]:
    """Returns (pairs, note). `note` flags non-standard protocol choices.
    SIDD: with sidd_holdout <= 0 (official validation blocks available) all pairs are TRAIN."""
    t = task.lower()
    note = ""
    if t == "gopro":
        pairs = discover_pairs(root, ("blur", "input", "degraded"), ("sharp", "target", "gt", "clean"),
                               split=split, verbose_name="GoPro")
    elif t == "hide":
        pairs = discover_pairs(root, ("blur", "input"), ("sharp", "gt", "target"), split="test", verbose_name="HIDE")
        if not pairs:
            pairs = discover_pairs(root, ("blur", "input"), ("sharp", "gt", "target"), verbose_name="HIDE")
        if not pairs and os.path.isdir(root):  # original HIDE: <dir>/test/** blurred, <dir>/GT/ sharp (same names)
            for dp, dirnames, _ in os.walk(root, followlinks=True):
                lower = {d.lower(): d for d in dirnames}
                if "gt" in lower and "test" in lower:
                    gts = {os.path.basename(g).lower(): g for g in _list_images(os.path.join(dp, lower["gt"]))}
                    pairs = [(b, gts[os.path.basename(b).lower()]) for b in _list_images(os.path.join(dp, lower["test"]))
                             if os.path.basename(b).lower() in gts]
                    break
    elif t == "dpdd":
        pairs = discover_pairs(root, ("inputc", "input_c", "source", "input", "blur", "blurred"),
                               ("target", "gt", "sharp", "groundtruth"), split=split,
                               exclude_part=lambda p: p.endswith("_l") or p.endswith("_r") or p in ("inputl", "inputr"),
                               verbose_name="DPDD")
    elif t in ("rain13k", "rain"):
        pairs = discover_pairs(root, ("input", "rain", "rainy", "inp"), ("target", "norain", "gt", "groundtruth", "clean"),
                               split=split, subset=subset, verbose_name=f"Rain13K/{subset or split}")
    elif t == "sidd":
        pairs = _discover_sidd_files(root)
        if not pairs:
            pairs = discover_pairs(root, ("noisy", "input", "input_crops"), ("gt", "clean", "target", "target_crops"),
                                   verbose_name="SIDD")
        has_split = any(_split_match([p.lower() for p in os.path.relpath(d, root).split(os.sep)], "test")
                        for d, _ in pairs)
        if has_split:
            want = split if split != "val" else "train"
            pairs = [(d, c) for d, c in pairs
                     if _split_match([p.lower() for p in os.path.relpath(d, root).split(os.sep)], want)]
        elif pairs and sidd_holdout <= 0:
            if split == "test":
                pairs = []
        elif pairs:
            scenes = sorted({os.path.dirname(d) for d, _ in pairs})
            rng = random.Random(seed)
            rng.shuffle(scenes)
            n_test = max(1, int(round(len(scenes) * sidd_holdout)))
            test_scenes = set(scenes[:n_test])
            if split == "test":
                pairs = [(d, c) for d, c in pairs if os.path.dirname(d) in test_scenes]
                note = f"UNOFFICIAL: scene-level hold-out of {len(test_scenes)} SIDD scenes (not the SIDD benchmark)"
            else:
                pairs = [(d, c) for d, c in pairs if os.path.dirname(d) not in test_scenes]
    else:
        pairs = discover_pairs(root, ("input", "degraded", "lq", "blur", "noisy", "rain", "source"),
                               ("target", "gt", "clean", "hq", "sharp", "norain"), split=split, subset=subset,
                               verbose_name=task)
    return pairs, note


def build_tile_cache(pairs: List[Tuple[str, str]], cfg: Config, task: str) -> List[Tuple[str, str]]:
    """Pre-crop images larger than `large_image_side` (SIDD 4-5K frames) into a
    bounded number of aligned tiles, once per session on the local SSD. Decoding a 5K
    PNG for every 128-px patch otherwise makes the data loader the bottleneck."""
    if not pairs:
        return pairs
    small, large = [], []
    for pair in pairs:
        w, h = _image_size(pair[0])
        (large if max(w, h) > cfg.large_image_side else small).append(pair)
    if not large:
        return pairs
    cdir = os.path.join(cfg.cache_dir, task)
    os.makedirs(cdir, exist_ok=True)
    manifest_path = os.path.join(cdir, "manifest.json")
    signature = {"sources": [list(p) for p in large], "tile": cfg.cache_tile_size, "n": cfg.cache_tiles_per_image}
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path) as f:
                m = json.load(f)
            if m.get("signature") == signature and all(os.path.exists(a) and os.path.exists(b) for a, b in m["tiles"]):
                print(f"  [{task}] reusing tile cache: {len(m['tiles'])} tiles from {len(large)} large images.")
                return small + [tuple(t) for t in m["tiles"]]
        except Exception:
            pass

    T = cfg.cache_tile_size

    def work(arg):
        idx, (dpath, cpath) = arg
        dimg = cv2.imread(dpath, cv2.IMREAD_UNCHANGED)
        cimg = cv2.imread(cpath, cv2.IMREAD_UNCHANGED)
        if dimg is None or cimg is None or dimg.shape[:2] != cimg.shape[:2]:
            return []
        H, W = dimg.shape[:2]
        rng = random.Random(cfg.seed * 1_000_003 + idx)
        out = []
        for k in range(cfg.cache_tiles_per_image):
            y, x = rng.randint(0, max(0, H - T)), rng.randint(0, max(0, W - T))
            dp_ = os.path.join(cdir, f"{idx:05d}_{k:03d}_deg.png")
            cp_ = os.path.join(cdir, f"{idx:05d}_{k:03d}_gt.png")
            cv2.imwrite(dp_, dimg[y:y + T, x:x + T], [cv2.IMWRITE_PNG_COMPRESSION, 1])
            cv2.imwrite(cp_, cimg[y:y + T, x:x + T], [cv2.IMWRITE_PNG_COMPRESSION, 1])
            out.append((dp_, cp_))
        return out

    print(f"  [{task}] building tile cache for {len(large)} large images in {cdir} (one-time per session)...")
    tiles = []
    with ThreadPoolExecutor(max_workers=max(1, min(16, os.cpu_count() or 1))) as ex:
        for res in tqdm(ex.map(work, list(enumerate(large))), total=len(large), desc=f"Tiling {task}"):
            tiles.extend(res)
    with open(manifest_path, "w") as f:
        json.dump({"signature": signature, "tiles": tiles}, f)
    return small + tiles


class ImageRestorationDataset(Dataset):
    """
    Paired restoration dataset.

    v4 fixes: cv2 reading (16-bit preserved), key-based pairing only, full-
    resolution test images (v3 centre-cropped test images to patch_size),
    8-way dihedral training augmentation, bounded retry on corrupt files for
    TRAINING only (a test set must never silently substitute an image).
    Returns (degraded, clean, task_id). Downloads are handled by section 2b.
    """

    def __init__(self, dataset_path: str = "", task: str = "", split: str = "train", subset: str = None,
                 patch_size: int = 128, pairs: Optional[List[Tuple[str, str]]] = None, task_id: int = 0,
                 val_crop: Optional[int] = None, seed: int = 0, sidd_holdout: float = 0.1,
                 arrays: Optional[Tuple[np.ndarray, np.ndarray]] = None):
        self.root_dir, self.task, self.split, self.subset = dataset_path, task, split, subset
        self.patch_size, self.task_id, self.val_crop = patch_size, task_id, val_crop
        self.crops = 1  # crops per decoded pair (training only), set by the trainer per stage
        self.arrays = arrays  # (N,H,W,3) uint8 pairs, used for SIDD .mat blocks
        self.protocol_note = ""
        if arrays is not None:
            self.pairs = [(str(i), str(i)) for i in range(len(arrays[0]))]
        elif pairs is not None:
            self.pairs = list(pairs)
        else:
            self.pairs, self.protocol_note = discover_task_pairs(task, dataset_path, split, subset, seed, sidd_holdout)
        tag = f"{task} [{subset or split}]"
        if self.pairs:
            print(f"Loaded {tag}: {len(self.pairs)} pairs." + (f"  ({self.protocol_note})" if self.protocol_note else ""))
        else:
            print(f"WARNING: no image pairs found for {tag} under '{dataset_path}'.")

    @property
    def degraded_paths(self):
        return [p[0] for p in self.pairs]

    @property
    def clean_paths(self):
        return [p[1] for p in self.pairs]

    def __len__(self):
        return len(self.pairs)

    def _load(self, idx):
        if self.arrays is not None:
            return (self.arrays[0][idx].astype(np.float32) / 255.0, self.arrays[1][idx].astype(np.float32) / 255.0)
        d, c = self.pairs[idx]
        a, b = read_image(d), read_image(c)
        if a.shape != b.shape:
            h, w = min(a.shape[0], b.shape[0]), min(a.shape[1], b.shape[1])
            if abs(a.shape[0] - b.shape[0]) > 8 or abs(a.shape[1] - b.shape[1]) > 8:
                raise IOError(f"size mismatch {a.shape} vs {b.shape}: {d}")
            a, b = a[:h, :w], b[:h, :w]
        return a, b

    @staticmethod
    def _pad_to(a: np.ndarray, size: int) -> np.ndarray:
        ph, pw = max(0, size - a.shape[0]), max(0, size - a.shape[1])
        if ph == 0 and pw == 0:
            return a
        mode = "reflect" if (a.shape[0] > ph and a.shape[1] > pw) else "edge"
        return np.pad(a, ((0, ph), (0, pw), (0, 0)), mode=mode)

    def _paired_transform(self, a: np.ndarray, b: np.ndarray):
        if self.split == "train":
            P = self.patch_size
            a, b = self._pad_to(a, P), self._pad_to(b, P)
            H, W = a.shape[:2]
            y, x = random.randint(0, H - P), random.randint(0, W - P)
            a, b = a[y:y + P, x:x + P], b[y:y + P, x:x + P]
            k = random.randint(0, 3)
            if k:
                a, b = np.rot90(a, k), np.rot90(b, k)
            if random.random() < 0.5:
                a, b = a[:, ::-1], b[:, ::-1]
        elif self.split == "val" and self.val_crop:
            P = self.val_crop
            a, b = self._pad_to(a, P), self._pad_to(b, P)
            H, W = a.shape[:2]
            y, x = (H - P) // 2, (W - P) // 2
            a, b = a[y:y + P, x:x + P], b[y:y + P, x:x + P]
        # test: full resolution, untouched
        to_t = lambda z: torch.from_numpy(np.ascontiguousarray(z.transpose(2, 0, 1)))
        return to_t(a), to_t(b)

    def __getitem__(self, idx):
        attempts = 5 if self.split == "train" else 1
        last = None
        for _ in range(attempts):
            try:
                a, b = self._load(idx)
                if self.split == "train" and self.crops > 1:
                    # several independent random crops (+ dihedral aug) from ONE decode;
                    # returned as (K,3,P,P) and flattened into the batch by train_collate
                    crops = [self._paired_transform(a, b) for _ in range(self.crops)]
                    return torch.stack([c[0] for c in crops]), torch.stack([c[1] for c in crops]), self.task_id
                da, db = self._paired_transform(a, b)
                return da, db, self.task_id
            except (OSError, IOError, cv2.error) as e:
                last = e
                if self.split != "train":
                    break
                print(f"WARNING [{self.task}]: failed to read pair {idx} ({e}); retrying another index.")
                idx = random.randrange(len(self.pairs))
        raise RuntimeError(f"Could not read a valid {self.task} pair: {last}")


_SIDD_MAT_CACHE: Dict[Tuple[str, str], Tuple[np.ndarray, np.ndarray]] = {}


def load_sidd_validation_blocks(root: str, search_roots: Sequence[str] = ()) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    """Official SIDD sRGB validation (1280 blocks of 256x256), as used by Restormer.
    Looks in `root`, then anywhere under `search_roots` (without entering image folders)."""
    noisy = gt = None
    for dp, _, fs, _d in _walk_limited(([root] if root else []) + list(search_roots)):
        for f in fs:
            if f.lower() == "validationnoisyblockssrgb.mat":
                noisy = os.path.join(dp, f)
            elif f.lower() == "validationgtblockssrgb.mat":
                gt = os.path.join(dp, f)
        if noisy and gt:
            break
    if not (noisy and gt):
        return None
    if (noisy, gt) in _SIDD_MAT_CACHE:
        return _SIDD_MAT_CACHE[(noisy, gt)]
    import scipy.io as sio
    n = sio.loadmat(noisy)["ValidationNoisyBlocksSrgb"]
    g = sio.loadmat(gt)["ValidationGtBlocksSrgb"]
    n = n.reshape(-1, *n.shape[-3:])
    g = g.reshape(-1, *g.shape[-3:])
    print(f"Loaded official SIDD validation blocks: {len(n)}")
    _SIDD_MAT_CACHE[(noisy, gt)] = (n, g)
    return n, g


def split_train_val(pairs: List[Tuple[str, str]], val_fraction: float, seed: int, max_val: int):
    """Deterministic per-task train/val split with a local RNG."""
    if not pairs:
        return [], []
    idx = list(range(len(pairs)))
    random.Random(seed).shuffle(idx)
    n_val = min(max_val, max(1, int(round(len(pairs) * val_fraction)))) if val_fraction > 0 else 0
    if len(pairs) - n_val < 1:
        n_val = 0
    val = [pairs[i] for i in sorted(idx[:n_val])]
    train = [pairs[i] for i in sorted(idx[n_val:])]
    return train, val


def audit_pairs(ds: ImageRestorationDataset, n: int = 12) -> Optional[float]:
    """Prints the median INPUT PSNR (degraded vs its clean target), i.e. the
    number the model has to beat, and checks alignment (v3 risk R5): the
    same statistic is computed for a deliberately SHIFTED pairing (degraded i
    vs clean i + N/2). Correct pairs must be clearly closer than wrong ones;
    if they are not, the pairing is broken."""
    if len(ds) == 0:
        return None

    def small(z):
        s = 256 / max(z.shape[:2])
        return cv2.resize(z, None, fx=s, fy=s, interpolation=cv2.INTER_AREA) if s < 1 else z

    def psnr(a, b):
        h, w = min(a.shape[0], b.shape[0]), min(a.shape[1], b.shape[1])
        return 10 * math.log10(1.0 / max(float(np.mean((a[:h, :w] - b[:h, :w]) ** 2)), 1e-12))

    idx = np.linspace(0, len(ds) - 1, num=min(n, len(ds))).astype(int).tolist()
    loaded = {}
    for i in idx:
        try:
            a, b = ds._load(int(i))
            loaded[i] = (small(a), small(b))
        except Exception as e:
            print(f"  audit: failed on pair {i}: {e}")
    if not loaded:
        return None
    keys = sorted(loaded)
    right = [psnr(*loaded[k]) for k in keys]
    med = float(np.median(right))
    msg = f"  audit {ds.task}: median input PSNR over {len(keys)} pairs = {med:.2f} dB"
    if len(keys) >= 4:
        shift = len(keys) // 2
        wrong = [psnr(loaded[keys[j]][0], loaded[keys[(j + shift) % len(keys)]][1]) for j in range(len(keys))]
        margin = med - float(np.median(wrong))
        msg += f" (vs {np.median(wrong):.2f} dB for shuffled pairs, margin {margin:+.2f} dB)"
        if margin < 1.0:
            msg += "  <-- SUSPICIOUS: pairs look MISALIGNED, check the dataset layout!"
    print(msg)
    return med


class _EmptyDataset(Dataset):
    def __len__(self):
        return 0

    def __getitem__(self, idx):
        raise IndexError


def concat_or_empty(datasets: List[Dataset]) -> Dataset:
    valid = [d for d in datasets if len(d) > 0]
    return ConcatDataset(valid) if valid else _EmptyDataset()


class MultiTaskInfiniteSampler(Sampler):
    """Infinite, task-balanced sampler over a ConcatDataset of FULL per-task
    datasets (replaces v3's epoch = 4 x min(task size) design, cause R1).
    Deterministic from (seed, start position) so resumes are reproducible."""

    def __init__(self, concat: ConcatDataset, mode: str = "uniform", seed: int = 0, start: int = 0):
        cum = list(concat.cumulative_sizes)
        self.starts = [0] + cum[:-1]
        self.sizes = [cum[i] - self.starts[i] for i in range(len(cum))]
        w = torch.tensor(self.sizes, dtype=torch.float64)
        if mode == "uniform":
            w = torch.ones_like(w)
        elif mode == "sqrt":
            w = w.sqrt()
        self.probs = (w / w.sum()).float()
        self.seed, self.start = seed, start

    def __iter__(self):
        g = torch.Generator()
        g.manual_seed(self.seed * 7919 + self.start + 104_729 * DIST.rank)  # independent stream per DDP rank
        sizes = torch.tensor(self.sizes)
        starts = torch.tensor(self.starts)
        while True:
            t = torch.multinomial(self.probs, 4096, replacement=True, generator=g)
            u = torch.rand(4096, generator=g)
            idx = starts[t] + (u * sizes[t]).long().clamp_max(sizes[t] - 1)
            yield from idx.tolist()

    def __len__(self):
        return 2 ** 31


def _worker_init(worker_id: int):
    s = (torch.initial_seed() + 1_000_003 * DIST.rank) % (2 ** 32)  # distinct crops on every DDP rank
    np.random.seed(s)
    random.seed(s)


def train_collate(batch):
    """Stacks samples; multi-crop samples (K,3,P,P) are concatenated so a loader
    batch of n pairs yields n*K training patches."""
    d, c, t = zip(*batch)
    if d[0].dim() == 4:
        k = d[0].shape[0]
        return torch.cat(d), torch.cat(c), torch.tensor(t).repeat_interleave(k)
    return torch.stack(d), torch.stack(c), torch.tensor(t)


# ==============================================================================
# 2b. AUTOMATIC DATASET DOWNLOAD: internet -> Google Drive (ONCE) -> local SSD (each session)
# ==============================================================================
# Archives are the ones the Restormer authors distribute (their download_data.py Google Drive
# IDs); the Hugging Face repository below mirrors them byte-for-byte (same size and sha256), and
# is tried first because it has no download quota. SIDD-Medium and the SIDD validation blocks
# can also come from the official York University server (different zip layout, still parsed).
# Extracted layouts (verified):
#   GoPro  train.zip -> train/{input,target}/            test.zip -> test/GoPro/{input,target}/
#   HIDE   test.zip  -> test/HIDE/{input,target}/
#   DPDD   {train,val,test}.zip -> {split}/{inputC,inputL,inputR,target}/  (+ indoor/outdoor labels)
#   Rain13K train.zip -> train/Rain13K/{input,target}/   test.zip -> test/<5 test sets>/{input,target}/
#   SIDD   train.zip -> train/<160 scenes>/NNNN_{GT,NOISY}_SRGB_01x.PNG  (= SIDD-Medium sRGB, 320 pairs)
#          test.zip  -> test/SIDD/Validation{Noisy,Gt}BlocksSrgb.mat
_HF = "https://huggingface.co/datasets/laoduanaaa/Image_Restoration_Datasets/resolve/main/"
_YORK = "http://130.63.97.225/share/"
DATASET_REGISTRY: Dict[str, List[dict]] = {
    "GoPro": [
        dict(file="GoPro_train.zip", size=4114478505, desc="GoPro train (2,103 pairs)",
             sha256="c7f7286cb0d36d00f56964ef4bf13f7115be9814ab26f89c8328d36615e3701c",
             sources=[("url", _HF + "Deblurring/Motion_Deblurring/train.zip"), ("gdrive", "1zgALzrLCC_tcXKu_iHQTHukKUVT1aodI")]),
        dict(file="GoPro_test.zip", size=2371837449, desc="GoPro test (1,111 pairs)",
             sha256="fb955bbd96b1521cff4686ae12624c47f5d9f9b24a0b49b575d2c03574accf73",
             sources=[("url", _HF + "Deblurring/Motion_Deblurring/test1.zip"), ("gdrive", "1k6DTSHu4saUgrGTYkkZXTptILyG9RRll")]),
    ],
    "HIDE": [
        dict(file="HIDE_test.zip", size=4231646359, desc="HIDE test (2,025 pairs)",
             sha256="a5fa86b7a18626530ad67271f27771bff9772818504317b1a177803df25df8b7",
             sources=[("url", _HF + "Deblurring/Motion_Deblurring/test2.zip"), ("gdrive", "1XRomKYJF1H92g1EuD06pCQe4o6HlwB7A")]),
    ],
    "DPDD": [
        dict(file="DPDD_train.zip", size=11825719078, desc="DPDD train (350 scenes, 16-bit, C/L/R views)",
             sha256="d4da9af423ce94a2502081fb3079dd609b65ee93e2f9446b870598eb75ef6257",
             sources=[("url", _HF + "Deblurring/Defocus_Deblurring/train.zip"), ("gdrive", "1bl5i1cDQNvkgVA_x37QdhvvFk1R80kfe")]),
        dict(file="DPDD_val.zip", size=2551225246, desc="DPDD val (74 scenes)",
             sha256="6708225bcf33acefcd5f5fb78eb25bc8938a400aaee7d1202d0947713e5c8473",
             sources=[("url", _HF + "Deblurring/Defocus_Deblurring/val.zip"), ("gdrive", "1KRAmBzluu-IG9-BOsuakB5rjY5_f-kiR")]),
        dict(file="DPDD_test.zip", size=2557794235, desc="DPDD test (76 scenes)",
             sha256="682fef5d911628688d1c458b30e8d24f71cb2840428a453839d817f413ba632a",
             sources=[("url", _HF + "Deblurring/Defocus_Deblurring/test.zip"), ("gdrive", "1dDWUQ_D93XGtcywoUcZE1HOXCV4EuLyw")]),
    ],
    "Rain13K": [
        dict(file="Rain13K_train.zip", size=1163440376, desc="Rain13K train (13,711 pairs)",
             sha256="b999f61e7d7df1c2333d8a63a80b89fea2f75197dd9350428a174bcb9e193a5d",
             sources=[("url", _HF + "Deraining/train.zip"), ("gdrive", "14BidJeG4nSNuFNFDf99K-7eErCq4i47t")]),
        dict(file="Rain13K_test.zip", size=1360310555, desc="Rain100H/L, Test100/1200/2800",
             sha256="5be86b39609c3fbd6b3f0cceb45aa98b06e38ad76d7fb85bcbe0eefc0a9d5311",
             sources=[("url", _HF + "Deraining/test.zip"), ("gdrive", "1P_-RAvltEoEhfT-9GrWRdpEi6NSswTs8")]),
    ],
    "SIDD": [
        dict(file="SIDD_Medium_Srgb_train.zip", size=13233785522, desc="SIDD-Medium sRGB (320 pairs, full)",
             sha256="aae8c8dd6643fc65454db60cc317d64accd8bea34187ea6c4aadcf772991446c",
             sources=[("url", _HF + "Denoising/Real/train.zip"), ("gdrive", "1UHjWZzLPGweA9ZczmV8lFSRcIxqiOVJw"),
                      ("url_alt", _YORK + "SIDD_Medium_Srgb.zip", 13234744070, "f95b4bc9ec1dd3fe4ebd61aeacad3991")]),
        dict(file="SIDD_validation_blocks.zip", size=461780640, desc="official SIDD validation blocks (1,280)",
             sha256="1139c32896697e960159ae845070751e58894ddf607ebfe8f6d83ef012e2fbff",
             sources=[("url", _HF + "Denoising/Real/test1.zip"), ("gdrive", "11vfqV-lqousZTuAit1Qkqghiv_taY0KZ"),
                      ("files", [(_YORK + "SIDD_Blocks/ValidationNoisyBlocksSrgb.mat", "test/SIDD/ValidationNoisyBlocksSrgb.mat", 229724517),
                                 (_YORK + "SIDD_Blocks/ValidationGtBlocksSrgb.mat", "test/SIDD/ValidationGtBlocksSrgb.mat", 232055617)])]),
    ],
}
_DATASET_TASK = {"GoPro": ("GoPro", "train"), "HIDE": ("HIDE", "test"), "DPDD": ("DPDD", "train"),
                 "Rain13K": ("Rain13K", "train"), "SIDD": ("SIDD", "train")}
_DATASET_ATTR = {"GoPro": "path_gopro", "HIDE": "path_hide", "DPDD": "path_dpdd", "Rain13K": "path_rain13k", "SIDD": "path_sidd"}


def _hash_file(path: str, algo: str = "sha256", chunk: int = 16 << 20) -> str:
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def _http_download(url: str, out: str, size: Optional[int], sha256: Optional[str] = None, md5: Optional[str] = None,
                   desc: str = "", retries: int = 6) -> bool:
    """Resumable streaming download (HTTP Range) with on-the-fly hashing and size/hash checks."""
    import requests
    part = out + ".part"
    for attempt in range(retries):
        try:
            pos = os.path.getsize(part) if os.path.exists(part) else 0
            if size and pos > size:
                os.remove(part); pos = 0
            hs = hashlib.sha256() if sha256 else None
            hm = hashlib.md5() if md5 else None
            if pos and (hs or hm):
                with open(part, "rb") as f:
                    while True:
                        b = f.read(16 << 20)
                        if not b:
                            break
                        hs and hs.update(b); hm and hm.update(b)
            headers = {"User-Agent": "Mozilla/5.0 (SINA-Net Colab)"}
            if pos:
                headers["Range"] = f"bytes={pos}-"
            with requests.get(url, headers=headers, stream=True, timeout=(30, 120), allow_redirects=True) as r:
                if pos and r.status_code != 206:  # server ignored the Range header: restart
                    pos = 0
                    hs = hashlib.sha256() if sha256 else None
                    hm = hashlib.md5() if md5 else None
                r.raise_for_status()
                total = size or (pos + int(r.headers.get("content-length", 0) or 0))
                with open(part, "ab" if pos else "wb") as f, tqdm(total=total, initial=pos, unit="B", unit_scale=True,
                                                                    unit_divisor=1024, desc=desc[:40], **_tqdm_kw()) as bar:
                    for b in r.iter_content(chunk_size=8 << 20):
                        if not b:
                            continue
                        f.write(b)
                        hs and hs.update(b); hm and hm.update(b)
                        bar.update(len(b))
            got = os.path.getsize(part)
            if size and got != size:
                print(f"    size mismatch ({got} != {size}); retrying")
                continue
            if hs and hs.hexdigest() != sha256:
                print("    sha256 mismatch: corrupt download, discarded"); os.remove(part); return False
            if hm and hm.hexdigest() != md5:
                print("    md5 mismatch: corrupt download, discarded"); os.remove(part); return False
            os.replace(part, out)
            return True
        except Exception as e:
            wait = min(60, 2 ** (attempt + 1))
            print(f"    download error ({type(e).__name__}: {str(e)[:120]}); retry {attempt + 1}/{retries} in {wait}s")
            time.sleep(wait)
    return False


def _gdrive_download(file_id: str, out: str, size: Optional[int]) -> bool:
    """gdown first; on 'quota exceeded' a server-side copy into YOUR Drive via the Drive API
    (Colab authentication), downloaded from there and deleted permanently afterwards."""
    part = out + ".gd"
    if ensure_packages(["gdown"]):
        try:
            import gdown
            gdown.download(id=file_id, output=part, quiet=False, resume=True)
            if os.path.exists(part) and (not size or os.path.getsize(part) == size):
                os.replace(part, out)
                return True
            print("    gdown did not return the complete file (Google Drive quota?)")
        except Exception as e:
            print(f"    gdown failed ({type(e).__name__}: {str(e)[:160]})")
    if not IN_COLAB:
        return False
    try:
        from google.colab import auth
        auth.authenticate_user()
        from googleapiclient.discovery import build
        from googleapiclient.http import MediaIoBaseDownload
        svc = build("drive", "v3", cache_discovery=False)
        cp = svc.files().copy(fileId=file_id, body={"name": f"_sina_tmp_{file_id}"}, supportsAllDrives=True).execute()
        try:
            req = svc.files().get_media(fileId=cp["id"])
            with open(part, "wb") as fh:
                dl = MediaIoBaseDownload(fh, req, chunksize=256 << 20)
                done = False
                with tqdm(total=size or 0, unit="B", unit_scale=True, desc="Drive API", **_tqdm_kw()) as bar:
                    while not done:
                        st, done = dl.next_chunk()
                        if st:
                            bar.n = st.resumable_progress; bar.refresh()
        finally:
            svc.files().delete(fileId=cp["id"], supportsAllDrives=True).execute()  # API delete skips the Trash
        if not size or os.path.getsize(part) == size:
            os.replace(part, out)
            return True
    except Exception as e:
        print(f"    Drive API copy failed ({type(e).__name__}: {str(e)[:160]})")
    return False


def _download_archive(spec: dict, out: str, verify: bool) -> Optional[str]:
    """Tries every source of one archive; returns a description of the source that worked."""
    for src in spec["sources"]:
        kind = src[0]
        print(f"  downloading {spec['desc']} <- {kind}: {str(src[1])[:90]}")
        ok = False
        if kind == "url":
            ok = _http_download(src[1], out, spec["size"], spec["sha256"] if verify else None, desc=spec["file"])
        elif kind == "url_alt":  # official server: different file (own size / md5)
            ok = _http_download(src[1], out, src[2], md5=src[3] if verify else None, desc=spec["file"])
        elif kind == "gdrive":
            ok = _gdrive_download(src[1], out, spec["size"])
            if ok and verify and _hash_file(out) != spec["sha256"]:
                print("    sha256 mismatch after Google Drive download: discarded")
                os.remove(out); ok = False
        elif kind == "files":  # loose official files -> packed into one (stored) zip
            tmp = out + "_files"
            os.makedirs(tmp, exist_ok=True)
            ok = all(os.path.exists(os.path.join(tmp, os.path.basename(rel))) or
                     _http_download(url, os.path.join(tmp, os.path.basename(rel)), sz, desc=os.path.basename(rel))
                     for url, rel, sz in src[1])
            if ok:
                import zipfile
                with zipfile.ZipFile(out + ".part", "w", compression=zipfile.ZIP_STORED, allowZip64=True) as z:
                    for url, rel, sz in src[1]:
                        z.write(os.path.join(tmp, os.path.basename(rel)), rel)
                os.replace(out + ".part", out)
                shutil.rmtree(tmp, ignore_errors=True)
        if ok:
            return f"{kind}:{src[1] if kind != 'files' else 'York SIDD server'}"
    return None


def _extract(archive: str, dest: str) -> bool:
    os.makedirs(dest, exist_ok=True)
    if shutil.which("unzip"):
        r = subprocess.run(["unzip", "-q", "-o", archive, "-d", dest])
        if r.returncode in (0, 1):  # 1 = warnings only
            return True
        print(f"    unzip failed with code {r.returncode}; trying Python's zipfile")
    try:
        import zipfile
        with zipfile.ZipFile(archive) as z:
            z.extractall(dest)
        return True
    except Exception as e:
        print(f"    extraction failed: {type(e).__name__}: {e}")
        return False


def _copy_tree_parallel(src: str, dst: str, threads: int = 32) -> int:
    """Parallel copy (Drive FUSE latency is per file, so threads multiply throughput)."""
    jobs = []
    for dp, _, fs in os.walk(src, followlinks=True):
        for f in fs:
            s = os.path.join(dp, f)
            d = os.path.join(dst, os.path.relpath(s, src))
            if not (os.path.exists(d) and os.path.getsize(d) == os.path.getsize(s)):
                jobs.append((s, d))

    def cp(job):
        os.makedirs(os.path.dirname(job[1]), exist_ok=True)
        shutil.copyfile(*job)

    with ThreadPoolExecutor(max_workers=threads) as ex:
        list(tqdm(ex.map(cp, jobs), total=len(jobs), desc=f"copy -> {os.path.basename(dst)}", **_tqdm_kw()))
    return len(jobs)


def _has_pairs(name: str, root: str) -> bool:
    task, split = _DATASET_TASK[name]
    try:
        return bool(discover_task_pairs(task, root, split, sidd_holdout=0.0)[0])
    except Exception:
        return False


def prepare_dataset(name: str, cfg: Config) -> Optional[str]:
    """Makes dataset `name` available and returns its folder:
       1. already extracted on the local SSD in this session -> that folder;
       2. archives already on Drive (Datasets/<name>/*.zip)  -> extract them locally;
       3. extracted images already on Drive (your own copy)  -> copy them locally (or use in place);
       4. otherwise download every archive (verified), save it to Drive, extract locally."""
    drive_dir = os.path.join(cfg.datasets_root, name)
    local_dir = os.path.join(cfg.local_root, "datasets", name)
    specs = DATASET_REGISTRY[name]
    lmark = os.path.join(local_dir, ".sina_extracted.json")
    try:
        with open(lmark) as f:
            done = set(json.load(f))
    except (OSError, ValueError):
        done = set()
    if all(s["file"] in done for s in specs):
        return local_dir
    os.makedirs(drive_dir, exist_ok=True)
    manifest_path = os.path.join(drive_dir, "manifest.json")
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except (OSError, ValueError):
        manifest = {}
    have_archives = any(os.path.isfile(os.path.join(drive_dir, s["file"])) for s in specs)
    if not have_archives and _has_pairs(name, drive_dir):
        if not cfg.stage_datasets_locally:
            print(f"[data] {name}: using your extracted copy on Drive in place ({drive_dir}).")
            return drive_dir
        print(f"[data] {name}: copying your extracted copy on Drive to the local SSD ...")
        _copy_tree_parallel(drive_dir, local_dir)
        return local_dir
    os.makedirs(local_dir, exist_ok=True)
    dl_dir = os.path.join(cfg.local_root, "downloads")
    os.makedirs(dl_dir, exist_ok=True)
    ok_all = True
    for s in specs:
        if s["file"] in done:
            continue
        on_drive = os.path.join(drive_dir, s["file"])
        entry = manifest.get(s["file"], {})
        if os.path.isfile(on_drive) and os.path.getsize(on_drive) == entry.get("size", s["size"]):
            print(f"[data] {name}: extracting {s['file']} from Drive ...")
            if _extract(on_drive, local_dir):
                done.add(s["file"])
                with open(lmark, "w") as f:
                    json.dump(sorted(done), f)
                continue
            print(f"[data] {name}: the copy on Drive is damaged; downloading it again.")
        need = s["size"] * 2.2 / 2 ** 30
        if _free_gb(dl_dir) < need:
            print(f"[data] WARNING: {_free_gb(dl_dir):.0f} GB free on the local disk, ~{need:.0f} GB needed for {s['file']}.")
        local_arch = os.path.join(dl_dir, s["file"])
        src = "local" if os.path.isfile(local_arch) and os.path.getsize(local_arch) == s["size"] else \
            _download_archive(s, local_arch, cfg.verify_sha256)
        if not src:
            print(f"[data] {name}: ALL sources failed for {s['file']}. Download it manually into {drive_dir} "
                  f"(sources: {[x[1] for x in s['sources'] if isinstance(x[1], str)]}).")
            ok_all = False
            continue
        if not _extract(local_arch, local_dir):
            ok_all = False
            continue
        try:  # save the verified archive ONCE on Drive (one large file: fast to sync and to read back)
            print(f"[data] {name}: saving {s['file']} ({os.path.getsize(local_arch) / 2 ** 30:.1f} GB) to {drive_dir} ...")
            _atomic_copy(local_arch, on_drive)
            manifest[s["file"]] = {"size": os.path.getsize(local_arch), "source": src,
                                   "sha256": s["sha256"] if src.startswith(("url:", "gdrive:", "local")) else None,
                                   "saved": time.strftime("%Y-%m-%d %H:%M:%S")}
            with open(manifest_path, "w") as f:
                json.dump(manifest, f, indent=1)
            os.remove(local_arch)
        except OSError as e:
            print(f"[data] WARNING: could not save {s['file']} to Drive ({e}); it stays in {dl_dir} for this session.")
        done.add(s["file"])
        with open(lmark, "w") as f:
            json.dump(sorted(done), f)
    return local_dir if (ok_all or _has_pairs(name, local_dir)) else None


def prepare_all_datasets(cfg: Config):
    """Download-once / extract-every-session for the configured datasets; points the Config paths at
    the fast local copies. Only rank 0 downloads; the other DDP ranks reuse its local folders."""
    if cfg.download_datasets == "none":
        return
    names = list(ALL_DATASETS) if cfg.download_datasets == "all" else \
        [n for n in ALL_DATASETS if n in cfg.train_tasks or (n == "HIDE" and "GoPro" in cfg.train_tasks)]
    print(f"\n[data] preparing datasets {names} (Drive: {cfg.datasets_root}, local: {os.path.join(cfg.local_root, 'datasets')})")
    t0 = time.time()
    for n in names:
        try:
            path = prepare_dataset(n, cfg)
        except Exception as e:
            print(f"[data] {n}: preparation failed ({type(e).__name__}: {e})")
            path = None
        if path:
            setattr(cfg, _DATASET_ATTR[n], path)
            if n == "SIDD":
                cfg.path_sidd_val = path
            print(f"[data] {n}: ready in {path}")
    print(f"[data] datasets ready in {(time.time() - t0) / 60:.1f} min")


# ==============================================================================
# 3. SHARED SIGNAL-PROCESSING PRIMITIVES
# ==============================================================================
_MAC_COUNTER = {"enabled": False, "macs": 0}


def _count_macs(n: float):
    if _MAC_COUNTER["enabled"]:
        _MAC_COUNTER["macs"] += int(n)


def _dev_type(x: torch.Tensor) -> str:
    return "cuda" if x.is_cuda else "cpu"


def native_bf16() -> bool:
    """True only for GPUs with NATIVE bf16 (Ampere+, incl. L4/H100/G4 Blackwell). Recent PyTorch
    reports bf16 as 'supported' on T4/P100 through slow emulation, so capability is checked directly."""
    return torch.cuda.is_available() and torch.cuda.get_device_capability()[0] >= 8


def safe_pad(x: torch.Tensor, pad: Tuple[int, ...], mode: str = "reflect") -> torch.Tensor:
    """Reflect padding with a replicate fallback when a map is too small."""
    if mode == "reflect":
        w_ok = x.shape[-1] > max(pad[0], pad[1])
        h_ok = len(pad) < 4 or x.shape[-2] > max(pad[2], pad[3])
        if not (w_ok and h_ok):
            mode = "replicate"
    return F.pad(x, pad, mode=mode)


def fir_hilbert_kernel(taps: int) -> torch.Tensor:
    """Blackman-windowed ideal discrete Hilbert transformer h[n] = 2/(pi n), n odd."""
    K = taps // 2
    n = torch.arange(-K, K + 1, dtype=torch.float64)
    h = torch.zeros_like(n)
    odd = (n.abs() % 2) == 1
    h[odd] = 2.0 / (math.pi * n[odd])
    return (h * torch.blackman_window(taps, periodic=False, dtype=torch.float64)).float()


class LocalAnalyticSignal(nn.Module):
    """
    Local (FIR) analytic-signal operator: returns the Hilbert transform of a
    real feature map along W or H, so z = x + i*H{x}. Replaces v3's full-row
    FFT Hilbert transform, whose response depends on image width (periodic
    wrap-around) and therefore differed between training patches and full
    test images (cause R4). Real arithmetic only -> no ComplexHalf under AMP.
    """

    def __init__(self, taps: int = 15):
        super().__init__()
        # conv2d is cross-correlation; flip so the op is a true convolution with h
        self.register_buffer("kernel", torch.flip(fir_hilbert_kernel(taps), dims=[0]), persistent=False)
        self.pad = taps // 2

    def along_w(self, x: torch.Tensor) -> torch.Tensor:
        C = x.shape[1]
        w = self.kernel.to(x.dtype).view(1, 1, 1, -1).expand(C, 1, 1, -1)
        _count_macs(x.numel() * self.kernel.numel())
        return F.conv2d(safe_pad(x, (self.pad, self.pad, 0, 0)), w, groups=C)

    def along_h(self, x: torch.Tensor) -> torch.Tensor:
        C = x.shape[1]
        w = self.kernel.to(x.dtype).view(1, 1, -1, 1).expand(C, 1, -1, 1)
        _count_macs(x.numel() * self.kernel.numel())
        return F.conv2d(safe_pad(x, (0, 0, self.pad, self.pad)), w, groups=C)


def hilbert_analytic_signal(x: torch.Tensor, taps: int = 15) -> Tuple[torch.Tensor, torch.Tensor]:
    """Functional form (kept for API compatibility with v3): (real, imag) along the last axis."""
    op = LocalAnalyticSignal(taps).to(x.device)
    return x, op.along_w(x)


class LayerNorm2d(nn.Module):
    """Per-pixel LayerNorm over channels (Restormer/NAFNet). Replaces v3's
    GroupNorm(1, C), which pooled statistics over the whole spatial extent
    (a global op -> train/test inconsistency, cause R4)."""

    def __init__(self, channels: int, eps: float = 1e-6, affine: bool = True):
        super().__init__()
        self.eps = eps
        self.weight = nn.Parameter(torch.ones(1, channels, 1, 1)) if affine else None
        self.bias = nn.Parameter(torch.zeros(1, channels, 1, 1)) if affine else None

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        with torch.autocast(_dev_type(x), enabled=False):
            xf = x.float()
            mu = xf.mean(1, keepdim=True)
            var = (xf - mu).pow(2).mean(1, keepdim=True)
            y = (xf - mu) * torch.rsqrt(var + self.eps)
            if self.weight is not None:
                y = y * self.weight.float() + self.bias.float()
        return y.to(x.dtype)


# ==============================================================================
# 4. SINA-NET CORE BLOCKS
# ==============================================================================
class CohenClassSpectralWienerUnit(nn.Module):
    """
    Cohen-class (smoothed pseudo Wigner-Ville) local spectral Wiener gate.

    For the local analytic signal z = x + iH{x} along each image axis, the
    lag-smoothed instantaneous autocorrelation R(t,tau) = z(t+tau) z*(t-tau)
    is Hermitian in tau, so its DFT over tau (the SPWVD) is REAL:
        W_k(t) = g0 R(t,0) + 2 sum_{tau>0} g_tau Re{R(t,tau) e^{-2pi i k tau / L}}.
    v4 computes that real, signed quantity exactly, with real arithmetic only
    (v3 took |FFT|^2, i.e. the 4th power of the features), log-compresses it
    with asinh, and lets a 1x1 PSD estimator split it into signal/noise power
    spectra -> Wiener gain H = S/(S+N) in [0,1), applied as a residual gate.

    Colab edition: `bypass` is a test-time knock-out switch used by the ablation
    study (the unit then returns its input unchanged); it is False in normal use.
    """

    def __init__(self, channels: int, lag: int = 2, smooth_sigma: float = 1.0, hilbert_taps: int = 15,
                 eps: float = 1e-6):
        super().__init__()
        self.lag, self.L, self.eps = lag, 2 * lag + 1, eps
        self.analytic = LocalAnalyticSignal(hilbert_taps)
        taus = torch.arange(0, lag + 1, dtype=torch.float32)
        g_full = torch.exp(-torch.arange(-lag, lag + 1).float() ** 2 / (2.0 * smooth_sigma ** 2))
        g = torch.exp(-taus ** 2 / (2.0 * smooth_sigma ** 2)) / g_full.sum()
        k = torch.arange(self.L, dtype=torch.float32).view(-1, 1)
        ang = 2 * math.pi * k * taus.view(1, -1) / self.L
        self.register_buffer("g", g, persistent=False)
        self.register_buffer("cos_t", torch.cos(ang), persistent=False)  # (L, lag+1)
        self.register_buffer("sin_t", torch.sin(ang), persistent=False)
        hidden = max(int(channels * 0.5), 4)
        self.psd_estimator = nn.Sequential(
            nn.Conv2d(channels * 2 * self.L, hidden, kernel_size=1),
            nn.LeakyReLU(0.1, inplace=True),
            nn.Conv2d(hidden, channels * 2, kernel_size=1),
        )
        self.residual_scale = nn.Parameter(torch.zeros(1, channels, 1, 1))
        self.capture = False
        self.bypass = False
        self.H_opt = None

    def _shift(self, t: torch.Tensor, s: int, axis: str) -> torch.Tensor:
        n = t.shape[-1] if axis == "w" else t.shape[-2]
        n -= 2 * self.lag
        o = self.lag + s
        return t[..., o:o + n] if axis == "w" else t[..., o:o + n, :]

    def _spwvd_axis(self, x: torch.Tensor, axis: str) -> torch.Tensor:
        B, C, H, W = x.shape
        hx = self.analytic.along_w(x) if axis == "w" else self.analytic.along_h(x)
        pad = (self.lag, self.lag, 0, 0) if axis == "w" else (0, 0, self.lag, self.lag)
        xr, xi = safe_pad(x, pad), safe_pad(hx, pad)
        R0 = x * x + hx * hx
        re, im = [], []
        for tau in range(1, self.lag + 1):
            ar, ai = self._shift(xr, tau, axis), self._shift(xi, tau, axis)
            br, bi = self._shift(xr, -tau, axis), self._shift(xi, -tau, axis)
            re.append(ar * br + ai * bi)
            im.append(ai * br - ar * bi)
        out = []
        for k in range(self.L):
            wk = self.g[0] * R0
            for j, tau in enumerate(range(1, self.lag + 1)):
                wk = wk + 2.0 * self.g[tau] * (re[j] * self.cos_t[k, tau] + im[j] * self.sin_t[k, tau])
            out.append(wk)
        _count_macs(x.numel() * (4 * self.lag + self.L * (2 * self.lag + 1)))
        return torch.stack(out, dim=2).reshape(B, C * self.L, H, W)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.bypass:
            return x
        with torch.autocast(_dev_type(x), enabled=False):
            xf = x.float()
            feats = torch.cat([torch.asinh(self._spwvd_axis(xf, "w")), torch.asinh(self._spwvd_axis(xf, "h"))], dim=1)
            s_signal, s_noise = torch.chunk(self.psd_estimator(feats), 2, dim=1)
            s_signal, s_noise = F.softplus(s_signal), F.softplus(s_noise)
            H_opt = s_signal / (s_signal + s_noise + self.eps)
            out = xf + xf * H_opt * self.residual_scale.float()
        if self.capture:
            self.H_opt = H_opt.detach()
        return out.to(x.dtype)


class KLDivergenceGuidedDiNA(nn.Module):
    """
    KL-guided dilated neighbourhood attention with ENTROPY HOMEOSTASIS.

    For each query, p = softmax(logits) over its k x k dilated neighbourhood
    (border positions masked out, not zero-padded), and
        KL_n = KL(p || Uniform(valid)) / log(#valid)  in [0,1].
    v3 used T = 0.5^(KL/sigma) in [0.25, 1]: sharpening only, so peaked rows
    got sharper (positive feedback -> collapse onto the query pixel = identity,
    which cannot deblur). v4 closes the loop with negative feedback:
        T = exp(g_h * (KL_n - tau_h)),  clamped to [temp_min, temp_max],
    where the per-head set point tau_h in (0,1) and gain g_h > 0 are learned.
    Rows more peaked than tau_h are softened, flatter rows sharpened, so each
    head keeps an operating entropy that it chooses itself.

    Logits are cosine similarities with a learnable per-head scale (stable
    under AMP), plus a relative position bias. Implementation: 49 shifted
    VIEWS of padded K/V (no unfold copies), so memory is O(B*C*H*W +
    B*heads*k^2*H*W) instead of O(B*C*k^2*H*W) -> full-resolution inference fits.

    Colab edition (analysis only, default behaviour unchanged):
      * `homeostasis=False` builds the TRAINING ablation (plain softmax, no set-point
        parameters, so DDP never sees unused parameters);
      * `force_unit_temperature` is the TEST-TIME knock-out (T = 1);
      * capture mode additionally records, per head, the attention footprint of
        chosen query pixels, the mean attention distance (in full-resolution pixels)
        and the per-row maximum weight (used to measure attention collapse).
    """

    def __init__(self, dim: int, num_heads: int, kernel_size: int, dilation: int,
                 kl_target: float = 0.35, temp_min: float = 0.25, temp_max: float = 4.0,
                 homeostasis: bool = True):
        super().__init__()
        self.dim, self.num_heads, self.head_dim = dim, num_heads, dim // num_heads
        self.kernel_size, self.k_sq, self.dilation = kernel_size, kernel_size ** 2, dilation
        self.temp_min, self.temp_max = temp_min, temp_max
        self.homeostasis = homeostasis
        self.qkv = nn.Conv2d(dim, dim * 3, kernel_size=1, bias=False)
        self.qkv_dw = nn.Conv2d(dim * 3, dim * 3, kernel_size=3, padding=1, groups=dim * 3, bias=False)
        self.proj = nn.Conv2d(dim, dim, kernel_size=1, bias=False)
        self.logit_scale = nn.Parameter(torch.full((num_heads,), math.log(10.0)))
        self.rpb = nn.Parameter(torch.zeros(num_heads, self.k_sq))
        nn.init.trunc_normal_(self.rpb, std=0.02)
        if homeostasis:
            self.kl_target_logit = nn.Parameter(torch.full((num_heads,), math.log(kl_target / (1 - kl_target))))
            self.kl_gain_raw = nn.Parameter(torch.full((num_heads,), math.log(math.e - 1.0)))  # softplus -> 1
        r = kernel_size // 2
        self.offsets = [((i - r) * dilation, (j - r) * dilation) for i in range(kernel_size) for j in range(kernel_size)]
        self.register_buffer("off_y", torch.tensor([o[0] for o in self.offsets]).view(-1, 1, 1), persistent=False)
        self.register_buffer("off_x", torch.tensor([o[1] for o in self.offsets]).view(-1, 1, 1), persistent=False)
        self.register_buffer("off_dist", torch.tensor([math.hypot(o[0], o[1]) for o in self.offsets],
                                                      dtype=torch.float32).view(1, 1, -1, 1, 1), persistent=False)
        self.capture = False
        self.force_unit_temperature = False
        self.capture_queries: List[Tuple[int, int]] = []
        self.capture_full_hw: Optional[Tuple[int, int]] = None
        self.clear_capture()

    def clear_capture(self):
        self.attn_kl = self.attn_temperature = self.attn_kl_after = None
        self.homeo_toward = self.homeo_dev_before = self.homeo_dev_after = None
        self.attn_query = None
        self.attn_distance = None
        self.attn_maxw = None
        self.level_scale = 1.0

    def set_point(self) -> Optional[torch.Tensor]:
        """Learned per-head entropy set point tau_h (None for the no-homeostasis ablation)."""
        return torch.sigmoid(self.kl_target_logit.detach().float()) if self.homeostasis else None

    def _mask(self, H: int, W: int, device) -> Tuple[torch.Tensor, torch.Tensor]:
        """Valid-neighbour mask (K2,H,W) and log(#valid). Recomputed on every call in
        one vectorised step (no cache): stateless, so compiled graphs and the
        checkpoint recomputation always see identical code paths."""
        ys = torch.arange(H, device=device).view(1, H, 1) + self.off_y
        xs = torch.arange(W, device=device).view(1, 1, W) + self.off_x
        m = (ys >= 0) & (ys < H) & (xs >= 0) & (xs < W)
        log_n = torch.log(m.float().sum(0).clamp_min(2.0))
        return m, log_n

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        B, C, H, W = x.shape
        h, d = self.num_heads, self.head_dim
        q, k, v = torch.chunk(self.qkv_dw(self.qkv(x)), 3, dim=1)
        pad = (self.kernel_size // 2) * self.dilation
        mask, log_n = self._mask(H, W, x.device)
        homeo = self.homeostasis and not self.force_unit_temperature
        kl_n = T = None
        with torch.autocast(_dev_type(x), enabled=False):
            scale = self.logit_scale.float().clamp(max=math.log(100.0)).exp().view(1, h, 1, 1, 1)
            qn = F.normalize(q.float().view(B, h, d, H, W), dim=2) * scale
            kn = F.normalize(k.float().view(B, h, d, H, W), dim=2).view(B, C, H, W)
            kp = F.pad(kn, (pad, pad, pad, pad)).view(B, h, d, H + 2 * pad, W + 2 * pad)
            vp = F.pad(v.float(), (pad, pad, pad, pad)).view(B, h, d, H + 2 * pad, W + 2 * pad)
            logits = torch.stack([(qn * kp[..., pad + dy:pad + dy + H, pad + dx:pad + dx + W]).sum(2)
                                  for dy, dx in self.offsets], dim=2)  # (B,h,K2,H,W)
            logits = logits + self.rpb.float().view(1, h, self.k_sq, 1, 1)
            logits = logits.masked_fill(~mask.view(1, 1, self.k_sq, H, W), -1e4)
            if homeo or self.capture:
                with torch.no_grad():
                    p0 = torch.softmax(logits, dim=2)
                    ent = -(p0 * torch.log(p0.clamp_min(1e-12))).sum(2)
                    kl_n = ((log_n - ent) / log_n).clamp(0.0, 1.0)  # (B,h,H,W)
            if homeo:
                tau = torch.sigmoid(self.kl_target_logit.float()).view(1, h, 1, 1)
                gain = F.softplus(self.kl_gain_raw.float()).view(1, h, 1, 1)
                T = torch.exp(gain * (kl_n - tau)).clamp(self.temp_min, self.temp_max)
                attn = torch.softmax(logits / T.unsqueeze(2), dim=2)
            else:
                attn = torch.softmax(logits, dim=2)
            out = None
            for j, (dy, dx) in enumerate(self.offsets):
                term = attn[:, :, j:j + 1] * vp[..., pad + dy:pad + dy + H, pad + dx:pad + dx + W]
                out = term if out is None else out + term
        _count_macs(2 * B * C * self.k_sq * H * W)
        if self.capture:
            self._capture_stats(attn, kl_n, T, mask, H, W)
        return self.proj(out.reshape(B, C, H, W).to(x.dtype))

    @torch.no_grad()
    def _capture_stats(self, attn, kl_n, T, mask, H: int, W: int):
        self.attn_kl = kl_n.detach()
        self.attn_temperature = (T if T is not None else torch.ones_like(kl_n)).detach()
        fh, fw = self.capture_full_hw or (H, W)
        sy, sx = fh / H, fw / W
        self.level_scale = 0.5 * (sy + sx)
        # entropy of the FINAL (temperature-scaled) attention: the homeostat acts on this distribution
        log_n = torch.log(mask.float().sum(0).clamp_min(2.0))
        ent_a = -(attn * torch.log(attn.clamp_min(1e-12))).sum(2)
        kl_after = ((log_n - ent_a) / log_n).clamp(0.0, 1.0)
        self.attn_kl_after = kl_after.detach()
        if self.homeostasis:
            tau = torch.sigmoid(self.kl_target_logit.detach().float()).view(1, -1, 1, 1)
            db, da = (kl_n - tau).abs(), (kl_after - tau).abs()
            self.homeo_toward = (da < db).float().mean((0, 2, 3)).cpu()   # fraction of rows moved toward tau_h
            self.homeo_dev_before = db.mean((0, 2, 3)).cpu()
            self.homeo_dev_after = da.mean((0, 2, 3)).cpu()
        a = attn * mask.view(1, 1, self.k_sq, H, W).float()
        # expected distance (full-resolution pixels) between a query and the keys it reads from
        self.attn_distance = ((a * self.off_dist).sum(2) * self.level_scale).mean((0, 2, 3)).cpu()
        self.attn_maxw = attn.max(2).values.detach()
        q = []
        for (y, xq) in self.capture_queries:
            yy = min(H - 1, max(0, int(y / sy)))
            xx = min(W - 1, max(0, int(xq / sx)))
            q.append((yy, xx, attn[:, :, :, yy, xx].detach().cpu()))  # (B,h,K2)
        self.attn_query = q


class DualGatedFeedForward(nn.Module):
    def __init__(self, dim: int):
        super().__init__()
        hidden = int(dim * 2.66)
        self.conv_in = nn.Conv2d(dim, hidden * 2, kernel_size=1, bias=False)
        self.depthwise = nn.Conv2d(hidden * 2, hidden * 2, kernel_size=3, padding=1, groups=hidden * 2, bias=False)
        self.conv_out = nn.Conv2d(hidden, dim, kernel_size=1, bias=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        gate, value = torch.chunk(self.depthwise(self.conv_in(x)), 2, dim=1)
        return self.conv_out(F.gelu(gate) * value)


class SINABlock(nn.Module):
    """Wiener spectral gate + homeostatic KL-guided neighbourhood attention + gated FFN.
    `use_wiener=False` / `homeostasis=False` build the TRAINING ablations (defaults = v4)."""

    def __init__(self, dim: int, num_heads: int, kernel_size: int, dilation: int, lag: int = 2,
                 hilbert_taps: int = 15, kl_target: float = 0.35, temp_min: float = 0.25,
                 use_wiener: bool = True, homeostasis: bool = True):
        super().__init__()
        self.norm1 = LayerNorm2d(dim)
        self.wiener = CohenClassSpectralWienerUnit(dim, lag=lag, hilbert_taps=hilbert_taps) if use_wiener else nn.Identity()
        self.attn = KLDivergenceGuidedDiNA(dim, num_heads, kernel_size, dilation, kl_target=kl_target,
                                           temp_min=temp_min, homeostasis=homeostasis)
        self.norm2 = LayerNorm2d(dim)
        self.ffn = DualGatedFeedForward(dim)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x + self.attn(self.wiener(self.norm1(x)))
        return x + self.ffn(self.norm2(x))


class LocalBlock(nn.Module):
    """Cheap full-resolution block: depthwise 3x3 + gated pointwise + gated FFN."""

    def __init__(self, dim: int):
        super().__init__()
        self.norm1 = LayerNorm2d(dim)
        self.dwconv = nn.Conv2d(dim, dim, kernel_size=3, padding=1, groups=dim, bias=False)
        self.pw_gate = nn.Conv2d(dim, dim * 2, kernel_size=1, bias=False)
        self.pw_out = nn.Conv2d(dim, dim, kernel_size=1, bias=False)
        self.norm2 = LayerNorm2d(dim)
        self.ffn = DualGatedFeedForward(dim)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        gate, value = torch.chunk(self.pw_gate(self.dwconv(self.norm1(x))), 2, dim=1)
        x = x + self.pw_out(F.gelu(gate) * value)
        return x + self.ffn(self.norm2(x))


# ==============================================================================
# 5A. SPECTRAL-COHERENCE-GATED SKIP FUSION
# ==============================================================================
class SpectralCoherenceGatedFusion(nn.Module):
    """
    fused = dec + sigmoid(gain*(MSC - 0.5) + bias) * proj(enc), where MSC is
    the local magnitude-squared coherence of the encoder/decoder analytic
    signals along both axes. v4: the smoothing kernel is a per-channel CONVEX
    combination (softmax-parametrised, Gaussian-initialised), which by
    Cauchy-Schwarz guarantees MSC in [0,1] (v3's free kernel could go negative
    -> MSC > 1 or division by ~0 -> NaN); coherence is computed on
    scale-free (per-pixel LayerNormed) features with the local FIR Hilbert
    operator, so it is resolution-consistent.

    Colab edition: `gate_mode` is a TEST-TIME knock-out switch for the ablation
    study: "learned" (normal), "mean" (each channel's gate replaced by its spatial
    mean: same average skip energy, no spatial selectivity), "open" (gate = 1,
    i.e. a plain additive skip).
    """

    def __init__(self, channels: int, smooth_kernel: int = 5, hilbert_taps: int = 15, eps: float = 1e-4):
        super().__init__()
        self.eps, self.k = eps, smooth_kernel
        self.proj_enc = nn.Conv2d(channels, channels, kernel_size=1, bias=False)
        self.norm = LayerNorm2d(channels, affine=False)
        self.analytic = LocalAnalyticSignal(hilbert_taps)
        ax = torch.arange(smooth_kernel).float() - smooth_kernel // 2
        g1d = torch.exp(-ax ** 2 / (2 * (smooth_kernel / 3.0) ** 2))
        g2d = torch.outer(g1d, g1d)
        self.smooth_logits = nn.Parameter(torch.log(g2d / g2d.sum()).flatten().repeat(channels, 1))
        self.gate_gain = nn.Parameter(torch.ones(1, channels, 1, 1) * 4.0)
        self.gate_bias = nn.Parameter(torch.zeros(1, channels, 1, 1))
        self.capture = False
        self.gate_mode = "learned"
        self.last_gate = None

    def _smooth(self, t: torch.Tensor) -> torch.Tensor:
        C = t.shape[1]
        w = torch.softmax(self.smooth_logits.float(), dim=1).view(C, 1, self.k, self.k)
        p = self.k // 2
        _count_macs(t.numel() * self.k * self.k)
        return F.conv2d(safe_pad(t, (p, p, p, p)), w, groups=C)

    def _axis_coherence(self, e: torch.Tensor, d: torch.Tensor, axis: str) -> torch.Tensor:
        hil = self.analytic.along_w if axis == "w" else self.analytic.along_h
        he, hd = hil(e), hil(d)
        cr = self._smooth(e * d + he * hd)
        ci = self._smooth(he * d - e * hd)
        pe = self._smooth(e * e + he * he)
        pd = self._smooth(d * d + hd * hd)
        return (cr * cr + ci * ci) / (pe * pd + self.eps)

    def forward(self, decoder_feat: torch.Tensor, encoder_feat: torch.Tensor) -> torch.Tensor:
        with torch.autocast(_dev_type(decoder_feat), enabled=False):
            e = self.norm(encoder_feat.float())
            d = self.norm(decoder_feat.float())
            coh = 0.5 * (self._axis_coherence(e, d, "w") + self._axis_coherence(e, d, "h"))
            gate = torch.sigmoid(self.gate_gain.float() * (coh - 0.5) + self.gate_bias.float())
            if self.gate_mode == "mean":
                gate = gate.mean((-2, -1), keepdim=True).expand_as(gate)
            elif self.gate_mode == "open":
                gate = torch.ones_like(gate)
            fused = decoder_feat.float() + gate * self.proj_enc(encoder_feat.float())
        if self.capture:
            self.last_gate = gate.detach()
        return fused.to(decoder_feat.dtype)


class PlainSkipFusion(nn.Module):
    """TRAINING-ablation baseline for the coherence gate: fused = dec + proj(enc)."""

    def __init__(self, channels: int):
        super().__init__()
        self.proj_enc = nn.Conv2d(channels, channels, kernel_size=1, bias=False)

    def forward(self, decoder_feat: torch.Tensor, encoder_feat: torch.Tensor) -> torch.Tensor:
        return decoder_feat + self.proj_enc(encoder_feat)


# ==============================================================================
# 5B. DEGRADATION-AWARE RADIAL-ANGULAR SPECTRAL CONDITIONING
# ==============================================================================
class RadialAngularSpectralSignature(nn.Module):
    """
    Welch-averaged, native-resolution radial-angular spectral signature.

    The luminance image is cut into 64x64 windows (50% overlap, all of them;
    evenly sub-sampled above `max_windows`), each window is de-meaned and
    Hann-tapered, and the periodograms are averaged (Welch). Nothing is
    rescaled, so a frequency bin means the same cycles/pixel for a 128-px
    training patch and a 1280x720 test frame. v3 average-pooled the whole
    input to 64x64 instead: a 2x low-pass in training but 20x at test time,
    which erased the very high-frequency evidence of blur (cause R4).

    Bins: radius over the inscribed disc (0, 0.5] cycles/px x orientation over
    [0, pi) (the spectrum of a real image is point-symmetric). Output:
      [ centred log-power bins (R*A),
        mean log-power,
        radial spectral slope d log P / d log f  (natural ~ -2, blur steeper, noise flatter),
        angular anisotropy of the outer half of the disc (motion direction, rain streaks) ]
    """

    def __init__(self, n_radial_bins: int = 8, n_angular_bins: int = 8, window: int = 64, max_windows: int = 1024):
        super().__init__()
        self.nr, self.na, self.S, self.max_windows = n_radial_bins, n_angular_bins, window, max_windows
        self.n_bins = n_radial_bins * n_angular_bins
        self.sig_dim = self.n_bins + 3
        S = window
        f = torch.fft.fftfreq(S)
        fy, fx = torch.meshgrid(f, f, indexing="ij")
        r = torch.sqrt(fx ** 2 + fy ** 2)
        theta = torch.remainder(torch.atan2(fy, fx), math.pi)
        valid = (r > 0) & (r <= 0.5)
        rb = torch.clamp((r / 0.5 * n_radial_bins).long(), max=n_radial_bins - 1)
        ab = torch.clamp((theta / math.pi * n_angular_bins).long(), max=n_angular_bins - 1)
        idx = torch.where(valid, rb * n_angular_bins + ab, torch.full_like(rb, self.n_bins)).view(-1)
        counts = torch.bincount(idx, minlength=self.n_bins + 1)[:self.n_bins].float().clamp_min(1.0)
        rc = (torch.arange(n_radial_bins).float() + 0.5) * 0.5 / n_radial_bins
        hann = torch.hann_window(S, periodic=False)
        hann2 = torch.outer(hann, hann)
        self.register_buffer("bin_index", idx, persistent=False)
        self.register_buffer("bin_counts", counts, persistent=False)
        self.register_buffer("log_rc", torch.log(rc), persistent=False)
        self.register_buffer("hann2", hann2.flatten(), persistent=False)
        self.register_buffer("hann_norm", (hann2 ** 2).sum(), persistent=False)

    @torch.no_grad()
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        with torch.autocast(_dev_type(x), enabled=False):
            x = x.float()
            B = x.shape[0]
            S = self.S
            gray = (0.299 * x[:, 0] + 0.587 * x[:, 1] + 0.114 * x[:, 2]).unsqueeze(1)
            if gray.shape[-2] < S or gray.shape[-1] < S:
                gray = safe_pad(gray, (0, max(0, S - gray.shape[-1]), 0, max(0, S - gray.shape[-2])))
            win = F.unfold(gray, kernel_size=S, stride=S // 2)  # (B, S*S, Nw)
            if win.shape[-1] > self.max_windows:
                sel = torch.linspace(0, win.shape[-1] - 1, self.max_windows, device=x.device).long()
                win = win[..., sel]
            win = (win - win.mean(1, keepdim=True)) * self.hann2.view(1, -1, 1)
            Nw = win.shape[-1]
            spec = torch.fft.fft2(win.transpose(1, 2).reshape(B, Nw, S, S))
            P = (spec.real ** 2 + spec.imag ** 2).mean(1) / self.hann_norm  # Welch average
            logP = torch.log(P.reshape(B, S * S) + 1e-10)
            binned = torch.zeros(B, self.n_bins + 1, device=x.device).scatter_add_(
                1, self.bin_index.unsqueeze(0).expand(B, -1), logP)[:, :self.n_bins] / self.bin_counts
            ra = binned.view(B, self.nr, self.na)
            radial = ra.mean(2)
            lr = self.log_rc - self.log_rc.mean()
            slope = ((radial - radial.mean(1, keepdim=True)) * lr).sum(1) / (lr ** 2).sum()
            aniso = ra[:, self.nr // 2:].std(2).mean(1)
            mean_lp = binned.mean(1)
            sig = torch.cat([binned - mean_lp[:, None], mean_lp[:, None], slope[:, None], aniso[:, None]], dim=1)
        return sig


class RunningStandardizer(nn.Module):
    """Standardises the signature with running moments (updated only in
    training, no gradient). Unlike v3's per-sample LayerNorm across
    heterogeneous entries, the mapping is identical at train and test time."""

    def __init__(self, dim: int, momentum: float = 0.01, eps: float = 1e-5):
        super().__init__()
        self.momentum, self.eps = momentum, eps
        self.register_buffer("mean", torch.zeros(dim))
        self.register_buffer("sq", torch.ones(dim))
        self.register_buffer("count", torch.zeros((), dtype=torch.long))

    def forward(self, s: torch.Tensor) -> torch.Tensor:
        s = s.float()
        if self.training:
            with torch.no_grad():
                m = max(self.momentum, 1.0 / float(self.count.item() + 1))
                self.mean.lerp_(s.mean(0), m)
                self.sq.lerp_((s * s).mean(0), m)
                self.count += 1
        var = (self.sq - self.mean ** 2).clamp_min(self.eps)
        return ((s - self.mean) / var.sqrt()).clamp(-10.0, 10.0)


class DegradationConditioner(nn.Module):
    """Signature -> zero-initialised per-level FiLM (Perez et al., AAAI 2018;
    AdaLN-zero, Peebles & Xie, ICCV 2023). v4: separate heads for encoder and
    decoder levels (their feature statistics differ).
    Colab edition: `enabled=False` is the TEST-TIME knock-out (identity FiLM);
    `embed()` exposes the learned degradation embedding for the probe study."""

    def __init__(self, sig_dim: int, dims: Sequence[int], hidden: int = 128):
        super().__init__()
        self.standardize = RunningStandardizer(sig_dim)
        self.mlp = nn.Sequential(nn.Linear(sig_dim, hidden), nn.GELU(), nn.Linear(hidden, hidden), nn.GELU())
        self.enc_heads = nn.ModuleList([nn.Linear(hidden, 2 * d) for d in dims])
        self.dec_heads = nn.ModuleList([nn.Linear(hidden, 2 * d) for d in dims[:3]])
        for head in list(self.enc_heads) + list(self.dec_heads):
            nn.init.zeros_(head.weight)
            nn.init.zeros_(head.bias)
        self.enabled = True
        self.capture = False
        self.last_hidden = None

    def embed(self, signature: torch.Tensor) -> torch.Tensor:
        return self.mlp(self.standardize(signature))

    def forward(self, signature: torch.Tensor):
        h = self.mlp(self.standardize(signature))
        if self.capture:
            self.last_hidden = h.detach()
        enc, dec = [hd(h) for hd in self.enc_heads], [hd(h) for hd in self.dec_heads]
        if not self.enabled:
            enc, dec = [torch.zeros_like(t) for t in enc], [torch.zeros_like(t) for t in dec]
        return enc, dec

    @staticmethod
    def apply_film(feat: torch.Tensor, gamma_beta: Optional[torch.Tensor]) -> torch.Tensor:
        if gamma_beta is None:
            return feat
        C = feat.shape[1]
        gb = gamma_beta.to(feat.dtype)
        return feat * (1.0 + gb[:, :C].view(-1, C, 1, 1)) + gb[:, C:].view(-1, C, 1, 1)


def v3_style_signature(x: torch.Tensor, sig: RadialAngularSpectralSignature) -> torch.Tensor:
    """Re-implementation of v3's conditioning front-end for the claims audit only:
    the whole image is adaptive-average-pooled to one 64x64 window before the same
    radial-angular binning. Used to MEASURE (not assume) the resolution consistency
    that the v4 Welch signature was introduced for (cause R4)."""
    with torch.no_grad():
        g = (0.299 * x[:, 0] + 0.587 * x[:, 1] + 0.114 * x[:, 2]).unsqueeze(1).float()
        g = F.adaptive_avg_pool2d(g, sig.S)
        # a 64x64 input yields exactly one Welch window -> the same binning code path
        return sig(g.expand(-1, 3, -1, -1))


# ==============================================================================
# 6. UP/DOWN SAMPLING
# ==============================================================================
class Downsample(nn.Module):
    def __init__(self, n_feat: int):
        super().__init__()
        self.body = nn.Sequential(nn.Conv2d(n_feat, n_feat // 2, 3, padding=1, bias=False), nn.PixelUnshuffle(2))

    def forward(self, x):
        return self.body(x)


class Upsample(nn.Module):
    def __init__(self, n_feat: int):
        super().__init__()
        self.body = nn.Sequential(nn.Conv2d(n_feat, n_feat * 2, 3, padding=1, bias=False), nn.PixelShuffle(2))

    def forward(self, x):
        return self.body(x)


# ==============================================================================
# 7. SINA-NET (v4)
# ==============================================================================
class _ContiguousGrad(torch.autograd.Function):
    """Identity whose backward makes the incoming gradient contiguous (a no-op when it
    already is). Compiled blocks bake the gradient layout into their backward graph;
    a channels-last gradient from the next layer would otherwise fail its stride check."""

    @staticmethod
    def forward(ctx, x):
        return x.view_as(x)

    @staticmethod
    def backward(ctx, g):
        return g.contiguous()


class SINANet(nn.Module):
    """4-level U-Net: LocalBlocks at full resolution, SINA blocks below,
    coherence-gated skips, degradation-aware FiLM on every level (encoder and
    decoder heads), multi-scale heads. Every operator except the signature is
    now spatially local, and the signature is resolution-consistent and can be
    passed in explicitly (tiled inference computes it once on the full image).

    With the default Config the parameters / state_dict are IDENTICAL to v4, so
    v4 checkpoints load unchanged. The use_* flags build the training ablations."""

    def __init__(self, config: Config):
        super().__init__()
        self.config = config
        dims = list(config.dims)
        self.use_checkpoint = config.use_checkpoint
        self.head = nn.Conv2d(config.in_channels, dims[0], 3, 1, 1)

        def make_level_blocks(level: int, dim: int, n: int) -> nn.ModuleList:
            if level < config.global_block_min_level:
                return nn.ModuleList([LocalBlock(dim) for _ in range(n)])
            return nn.ModuleList([
                SINABlock(dim, config.num_heads, config.attn_kernel_size,
                          config.dilation_cycle[i % len(config.dilation_cycle)], lag=config.wiener_lag,
                          hilbert_taps=config.hilbert_taps, kl_target=config.kl_target_init,
                          use_wiener=config.use_wiener, homeostasis=config.use_homeostasis)
                for i in range(n)])

        def make_fusion(dim: int) -> nn.Module:
            if config.use_coherence_fusion:
                return SpectralCoherenceGatedFusion(dim, hilbert_taps=config.hilbert_taps)
            return PlainSkipFusion(dim)

        self.enc0 = make_level_blocks(0, dims[0], config.enc_blocks[0]); self.down0 = Downsample(dims[0])
        self.enc1 = make_level_blocks(1, dims[1], config.enc_blocks[1]); self.down1 = Downsample(dims[1])
        self.enc2 = make_level_blocks(2, dims[2], config.enc_blocks[2]); self.down2 = Downsample(dims[2])
        self.bottleneck = make_level_blocks(3, dims[3], config.bottleneck_blocks)
        self.up2 = Upsample(dims[3]); self.fuse2 = make_fusion(dims[2])
        self.dec2 = make_level_blocks(2, dims[2], config.dec_blocks[0])
        self.up1 = Upsample(dims[2]); self.fuse1 = make_fusion(dims[1])
        self.dec1 = make_level_blocks(1, dims[1], config.dec_blocks[1])
        self.up0 = Upsample(dims[1]); self.fuse0 = make_fusion(dims[0])
        self.dec0 = make_level_blocks(0, dims[0], config.dec_blocks[2])
        self.refinement = nn.ModuleList([LocalBlock(dims[0]) for _ in range(config.refinement_blocks)])
        self.tail = nn.Conv2d(dims[0], config.out_channels, 3, 1, 1)

        self.degradation_signature = RadialAngularSpectralSignature(
            config.sig_radial_bins, config.sig_angular_bins, config.sig_window, config.sig_max_windows)
        self.degradation_conditioner = (DegradationConditioner(self.degradation_signature.sig_dim, dims,
                                                               hidden=config.sig_hidden_dim)
                                        if config.use_degradation_conditioning else None)
        self.last_degradation_signature = None
        if config.use_multiscale_supervision:
            self.aux_head2 = nn.Conv2d(dims[2], config.out_channels, 3, 1, 1)
            self.aux_head1 = nn.Conv2d(dims[1], config.out_channels, 3, 1, 1)
        else:
            self.aux_head2 = self.aux_head1 = None

    def set_capture(self, flag: bool, queries: Optional[List[Tuple[int, int]]] = None,
                    full_hw: Optional[Tuple[int, int]] = None):
        """Capture mode stores interpretability tensors in the modules. `queries` are
        (y, x) pixels in the coordinates of the image fed to forward()."""
        for m in self.modules():
            if hasattr(m, "capture"):
                m.capture = flag
            if isinstance(m, KLDivergenceGuidedDiNA):
                m.capture_queries = list(queries or []) if flag else []
                m.capture_full_hw = full_hw if flag else None

    def clear_capture(self):
        for m in self.modules():
            if isinstance(m, KLDivergenceGuidedDiNA):
                m.clear_capture()
            for a in ("H_opt", "last_gate", "last_hidden"):
                if hasattr(m, a):
                    setattr(m, a, None)

    def _run(self, blocks: nn.ModuleList, x: torch.Tensor) -> torch.Tensor:
        for blk in blocks:
            if self.use_checkpoint and self.training and torch.is_grad_enabled() and isinstance(blk, SINABlock):
                x = grad_checkpoint(blk, x, use_reentrant=False)
            else:
                x = blk(x)
            if x.requires_grad and getattr(blk, "_compiled_call_impl", None) is not None:
                x = _ContiguousGrad.apply(x)  # compiled backward graphs assume contiguous gradients
        return x

    def compute_signature(self, x: torch.Tensor) -> torch.Tensor:
        return self.degradation_signature(x)

    def forward(self, x: torch.Tensor, signature: Optional[torch.Tensor] = None, return_aux: bool = False):
        B, _, H, W = x.shape
        ph, pw = (-H) % 8, (-W) % 8
        xin = safe_pad(x, (0, pw, 0, ph)) if (ph or pw) else x
        if self.degradation_conditioner is not None:
            sig = self.degradation_signature(x) if signature is None else signature
            self.last_degradation_signature = sig.detach()
            enc_fp, dec_fp = self.degradation_conditioner(sig)
        else:
            enc_fp, dec_fp = [None] * 4, [None] * 3
        film = DegradationConditioner.apply_film

        e0 = self._run(self.enc0, film(self.head(xin), enc_fp[0]))
        e1 = self._run(self.enc1, film(self.down0(e0), enc_fp[1]))
        e2 = self._run(self.enc2, film(self.down1(e1), enc_fp[2]))
        b = self._run(self.bottleneck, film(self.down2(e2), enc_fp[3]))
        d2 = self._run(self.dec2, film(self.fuse2(self.up2(b), e2), dec_fp[2]))
        d1 = self._run(self.dec1, film(self.fuse1(self.up1(d2), e1), dec_fp[1]))
        d0 = self._run(self.dec0, film(self.fuse0(self.up0(d1), e0), dec_fp[0]))
        out = self.tail(self._run(self.refinement, d0)) + xin
        out = out[..., :H, :W]
        if return_aux:
            if self.aux_head2 is None or ph or pw:
                return out, []
            aux2 = self.aux_head2(d2) + F.interpolate(xin, size=d2.shape[-2:], mode="area")
            aux1 = self.aux_head1(d1) + F.interpolate(xin, size=d1.shape[-2:], mode="area")
            return out, [aux2, aux1]
        return out


# ==============================================================================
# 7b. COMPILATION OF THE MEMORY-BOUND BLOCKS
# ==============================================================================
# The SINA / local / coherence blocks are long chains of element-wise ops (the
# neighbourhood attention alone issues ~50 multiply-reduce pairs per block). In
# eager mode every link writes a full-size tensor to GPU memory; torch.compile
# fuses them into a few kernels. Blocks are compiled IN PLACE (nn.Module.compile),
# so state_dict keys, checkpoints and the EMA copy are unaffected.
# SpectralCoherenceGatedFusion is left eager: Inductor mis-lowers it with dynamic
# spatial shapes (stride-order TypeError), and it is only ~5% of the memory traffic.
#
# Colab G4 (RTX PRO 6000 Blackwell, sm_120): Triton has an open (unconfirmed) report of
# SEGFAULTS on sm_120 (pytorch#176426). A segfault cannot be caught by Python, so the
# attempt is recorded in a marker file first: if a run dies while compiling, the next
# run sees the unfinished marker and trains eagerly instead of crashing again.
_COMPILABLE = (SINABlock, LocalBlock)


def _compile_marker_path(config: "Config") -> str:
    return os.path.join(config.checkpoint_dir, "compile_state.json")


def _compile_key() -> str:
    gpu = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "cpu"
    return f"{gpu}|torch{torch.__version__}"


def compile_guard_allows(config: "Config") -> bool:
    """False if an earlier compilation attempt on this GPU + PyTorch never finished (crash)."""
    try:
        with open(_compile_marker_path(config)) as f:
            state = json.load(f).get(_compile_key())
    except (OSError, ValueError):
        return True
    if state == "attempting":
        print("  torch.compile: a previous compilation on this GPU/PyTorch never finished (the process "
              "crashed, e.g. a Triton segfault on sm_120) -> training EAGERLY. Delete "
              f"{_compile_marker_path(config)} to try compiling again.")
        return False
    return state != "failed"


def compile_guard_mark(config: "Config", state: str):
    if not DIST.is_main:
        return
    path = _compile_marker_path(config)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            with open(path) as f:
                d = json.load(f)
        except (OSError, ValueError):
            d = {}
        d[_compile_key()] = state
        with open(path, "w") as f:
            json.dump(d, f)
            f.flush()
            os.fsync(f.fileno())
    except OSError:
        pass


def compile_blocks(model: nn.Module) -> int:
    if not hasattr(nn.Module, "compile"):  # torch < 2.2
        return 0
    import torch._dynamo
    torch._dynamo.config.cache_size_limit = max(torch._dynamo.config.cache_size_limit, 64)
    import torch._inductor.config as inductor_config
    # keep NCHW: with channels-last chosen inside a compiled block, its backward expects
    # channels-last gradients and fails its stride assertion when the next layer is eager
    inductor_config.layout_optimization = False
    import logging
    logging.getLogger("torch._inductor.utils").setLevel(logging.ERROR)  # 'Not enough SMs for max_autotune'
    n = 0
    for m in model.modules():
        if isinstance(m, _COMPILABLE):
            m.compile(dynamic=False)  # static shapes: Inductor's dynamic-shape path mis-lowers these blocks
            n += 1
    return n


def uncompile_blocks(model: nn.Module):
    for m in model.modules():
        if isinstance(m, _COMPILABLE) and getattr(m, "_compiled_call_impl", None) is not None:
            m._compiled_call_impl = None


def is_compile_error(e: BaseException) -> bool:
    """Python-level compiler failures (recoverable by switching to eager). CUDA
    faults are NOT included: they corrupt the CUDA context and must propagate."""
    mod = type(e).__module__ or ""
    return (mod.startswith(("torch._dynamo", "torch._inductor")) or type(e).__name__ in
            ("InductorError", "BackendCompilerFailed", "Unsupported", "TorchRuntimeError", "CheckpointError"))


class eager_mode:
    """Context manager: temporarily run compiled blocks eagerly (for reference checks,
    interpretability capture, knock-out ablations and the complexity profiler)."""

    def __init__(self, model: nn.Module):
        self.mods = [m for m in model.modules() if isinstance(m, _COMPILABLE)]

    def __enter__(self):
        self.saved = [getattr(m, "_compiled_call_impl", None) for m in self.mods]
        for m in self.mods:
            m._compiled_call_impl = None

    def __exit__(self, *exc):
        for m, f in zip(self.mods, self.saved):
            m._compiled_call_impl = f
        return False


# ==============================================================================
# 8. COMPOSITE LOSS FUNCTION
# ==============================================================================
class CharbonnierLoss(nn.Module):
    def __init__(self, eps: float = 1e-3):
        super().__init__()
        self.eps2 = eps ** 2

    def forward(self, pred, target):
        d = pred - target
        return torch.sqrt(d * d + self.eps2).mean()


class LaplacianEdgeLoss(nn.Module):
    """MPRNet/DeepRFT edge loss (Charbonnier between Laplacians), replicate-padded."""

    def __init__(self, channels: int = 3, eps: float = 1e-3):
        super().__init__()
        self.eps2, self.channels = eps ** 2, channels
        k = torch.tensor([[0., 1., 0.], [1., -4., 1.], [0., 1., 0.]]).view(1, 1, 3, 3).repeat(channels, 1, 1, 1)
        self.register_buffer("kernel", k, persistent=False)

    def forward(self, pred, target):
        lp = F.conv2d(F.pad(pred, (1, 1, 1, 1), mode="replicate"), self.kernel, groups=self.channels)
        lt = F.conv2d(F.pad(target, (1, 1, 1, 1), mode="replicate"), self.kernel, groups=self.channels)
        d = lp - lt
        return torch.sqrt(d * d + self.eps2).mean()


class FFTFrequencyLoss(nn.Module):
    """DeepRFT/MIMO-UNet frequency loss, L1 on real+imag of rfft2, orthonormal
    (so the weight does not silently change with patch size as in v3)."""

    def forward(self, pred, target):
        pf, tf = torch.fft.rfft2(pred, norm="ortho"), torch.fft.rfft2(target, norm="ortho")
        return F.l1_loss(pf.real, tf.real) + F.l1_loss(pf.imag, tf.imag)


class RadialSpectralProfileLoss(nn.Module):
    """
    NEW: L1 between log azimuthally-integrated power spectra (cf. Durall et
    al., CVPR 2020) of Hann-windowed pred/target. Residual blur appears as a
    deficit of power in the outer radial bins. This penalty is phase-free, so
    it acts on that deficit directly and complements the pixel/FFT terms,
    which are dominated by low-frequency error. It reuses the radial geometry
    of the degradation signature, so the conditioning signal and the training
    signal speak the same spectral language.
    """

    def __init__(self, n_bins: int = 16, eps: float = 1e-6):
        super().__init__()
        self.n_bins, self.eps = n_bins, eps
        self._cache: Dict = {}

    def _geometry(self, H, W, device):
        key = (H, W, str(device))
        if key not in self._cache:
            fy = torch.fft.fftfreq(H, device=device).view(H, 1)
            fx = torch.fft.rfftfreq(W, device=device).view(1, -1)
            r = torch.sqrt(fy ** 2 + fx ** 2)
            valid = (r > 0) & (r <= 0.5)
            b = torch.clamp((r / 0.5 * self.n_bins).long(), max=self.n_bins - 1)
            idx = torch.where(valid, b, torch.full_like(b, self.n_bins)).view(-1)
            cnt = torch.bincount(idx, minlength=self.n_bins + 1)[:self.n_bins].float().clamp_min(1)
            win = torch.outer(torch.hann_window(H, periodic=False, device=device),
                              torch.hann_window(W, periodic=False, device=device))
            self._cache[key] = (idx, cnt, win)
        return self._cache[key]

    def _profile(self, x, idx, cnt, win):
        B, C, H, W = x.shape
        xw = (x - x.mean((-2, -1), keepdim=True)) * win
        s = torch.fft.rfft2(xw, norm="ortho")
        P = (s.real ** 2 + s.imag ** 2).reshape(B * C, -1)
        prof = torch.zeros(B * C, self.n_bins + 1, device=x.device).scatter_add_(
            1, idx.unsqueeze(0).expand(B * C, -1), P)[:, :self.n_bins] / cnt
        return torch.log(prof + self.eps)

    def forward(self, pred, target):
        idx, cnt, win = self._geometry(pred.shape[-2], pred.shape[-1], pred.device)
        return (self._profile(pred, idx, cnt, win) - self._profile(target, idx, cnt, win)).abs().mean()


def _gaussian_window(size: int = 11, sigma: float = 1.5, device=None) -> torch.Tensor:
    ax = torch.arange(size, dtype=torch.float64, device=device) - size // 2
    g = torch.exp(-ax ** 2 / (2 * sigma ** 2))
    g = g / g.sum()
    return torch.outer(g, g)


def ssim_torch(x: torch.Tensor, y: torch.Tensor, data_range: float = 1.0) -> torch.Tensor:
    """BasicSR/Wang-et-al. SSIM (11x11 Gaussian, sigma 1.5, 'valid' filtering),
    per image, averaged over channels. Differentiable. x,y: (B,C,H,W)."""
    C = x.shape[1]
    w = _gaussian_window(device=x.device).to(x.dtype).view(1, 1, 11, 11).repeat(C, 1, 1, 1)
    C1, C2 = (0.01 * data_range) ** 2, (0.03 * data_range) ** 2
    mu_x, mu_y = F.conv2d(x, w, groups=C), F.conv2d(y, w, groups=C)
    sxx = F.conv2d(x * x, w, groups=C) - mu_x ** 2
    syy = F.conv2d(y * y, w, groups=C) - mu_y ** 2
    sxy = F.conv2d(x * y, w, groups=C) - mu_x * mu_y
    m = ((2 * mu_x * mu_y + C1) * (2 * sxy + C2)) / ((mu_x ** 2 + mu_y ** 2 + C1) * (sxx + syy + C2))
    return m.mean(dim=(1, 2, 3))


def batch_psnr(pred: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    mse = ((pred.clamp(0, 1) - target.clamp(0, 1)) ** 2).mean(dim=(1, 2, 3)).clamp_min(1e-10)
    return 10 * torch.log10(1.0 / mse)


class RestorationLoss(nn.Module):
    """Charbonnier + edge + orthonormal FFT + radial-profile (+ optional SSIM /
    LPIPS) + multi-scale supervision. Always evaluated in fp32."""

    def __init__(self, config: Config):
        super().__init__()
        self.config = config
        self.charbonnier = CharbonnierLoss(config.charbonnier_eps)
        self.edge = LaplacianEdgeLoss(config.out_channels, config.charbonnier_eps)
        self.freq = FFTFrequencyLoss()
        self.radial = RadialSpectralProfileLoss()
        self.lpips_metric = None
        if config.lambda_lpips > 0:
            ensure_packages(["pyiqa"])
            import pyiqa  # optional dependency
            self.lpips_metric = pyiqa.create_metric("lpips", device=config.device, as_loss=True)

    def forward(self, pred, target, aux_preds: Optional[List[torch.Tensor]] = None):
        c = self.config
        with torch.autocast(_dev_type(pred), enabled=False):
            pred, target = pred.float(), target.float()
            terms = {"char": self.charbonnier(pred, target)}
            if c.lambda_edge > 0:
                terms["edge"] = self.edge(pred, target)
            if c.lambda_freq > 0:
                terms["freq"] = self.freq(pred, target)
            if c.lambda_radial > 0:
                terms["radial"] = self.radial(pred, target)
            if c.lambda_ssim > 0:
                terms["ssim"] = 1.0 - ssim_torch(pred.clamp(0, 1), target).mean()
            if self.lpips_metric is not None:
                terms["lpips"] = self.lpips_metric(pred.clamp(0, 1), target).mean()
            weights = {"char": c.lambda_char, "edge": c.lambda_edge, "freq": c.lambda_freq,
                       "radial": c.lambda_radial, "ssim": c.lambda_ssim, "lpips": c.lambda_lpips}
            total = sum(weights[k] * v for k, v in terms.items())
            if aux_preds:
                aux = sum(self.charbonnier(a.float(), F.interpolate(target, size=a.shape[-2:], mode="area"))
                          for a in aux_preds) / len(aux_preds)
                total = total + c.aux_weight * aux
                terms["aux"] = aux
        metrics = {k: float(v.detach()) for k, v in terms.items()}
        with torch.no_grad():
            metrics["psnr"] = float(batch_psnr(pred, target).mean())
        return total, metrics


# ==============================================================================
# 9. BENCHMARK-PROTOCOL METRICS
# ==============================================================================
class RestorationMetrics:
    """
    Standard protocols of the tables SINA-Net is compared against:
      * GoPro / HIDE: RGB PSNR/SSIM on uint8-quantised full images.
      * Deraining (Rain100H/L, Test100/1200/2800): Y channel of YCbCr (BT.601,
        MATLAB rgb2ycbcr), uint8 (MPRNet/Restormer protocol).
      * DPDD: RGB on float images (16-bit sources, no quantisation) + MAE.
      * SIDD validation blocks: RGB on uint8.
    SSIM follows BasicSR's calculate_ssim (small MATLAB-vs-Python differences
    of ~1e-3 are possible; state the implementation in the paper).
    """

    @staticmethod
    def _prep(x: torch.Tensor, quantize: bool, y_channel: bool):
        x = x.clamp(0, 1).double()
        if quantize:
            x = torch.round(x * 255.0)
            rng = 255.0
        else:
            rng = 1.0
        if y_channel:
            w = torch.tensor([65.481, 128.553, 24.966], dtype=x.dtype, device=x.device).view(1, 3, 1, 1)
            y = (x / rng * w).sum(1, keepdim=True) + 16.0  # MATLAB rgb2ycbcr, Y in [16, 235]
            x = torch.round(y) if quantize else y * (rng / 255.0)  # uint8 rgb2ycbcr output is rounded
        return x, rng

    @classmethod
    def compute(cls, pred: torch.Tensor, gt: torch.Tensor, quantize: bool = True, y_channel: bool = False) -> dict:
        p, rng = cls._prep(pred, quantize, y_channel)
        g, _ = cls._prep(gt, quantize, y_channel)
        mse = ((p - g) ** 2).mean().item()
        psnr = 10 * math.log10(rng ** 2 / max(mse, 1e-12))
        ssim = ssim_torch(p, g, data_range=rng).mean().item()
        mae = (pred.clamp(0, 1).double() - gt.clamp(0, 1).double()).abs().mean().item()
        return {"psnr": psnr, "ssim": ssim, "mae": mae}


class LPIPSMetric:
    """LPIPS-Alex (Zhang et al., CVPR 2018), the perceptual metric the DPDD tables report.
    Loaded lazily (`pip install lpips`); returns None when unavailable."""
    _net = None
    _tried = False

    @classmethod
    def compute(cls, pred: torch.Tensor, gt: torch.Tensor) -> Optional[float]:
        if not cls._tried:
            cls._tried = True
            try:
                if ensure_packages(["lpips"]):
                    import lpips
                    cls._net = lpips.LPIPS(net="alex", verbose=False).to(pred.device).eval()
            except Exception as e:
                print(f"  LPIPS unavailable ({type(e).__name__}: {e}); the LPIPS column is reported as n/a.")
                cls._net = None
        if cls._net is None:
            return None
        with torch.no_grad():
            v = cls._net(pred.float().clamp(0, 1) * 2 - 1, gt.float().clamp(0, 1) * 2 - 1)
        return float(v.mean())


EVAL_PROTOCOL = {
    "GoPro": dict(quantize=True, y_channel=False), "HIDE": dict(quantize=True, y_channel=False),
    "DPDD": dict(quantize=False, y_channel=False), "SIDD": dict(quantize=True, y_channel=False),
    "Rain100H": dict(quantize=True, y_channel=True), "Rain100L": dict(quantize=True, y_channel=True),
    "Test100": dict(quantize=True, y_channel=True), "Test1200": dict(quantize=True, y_channel=True),
    "Test2800": dict(quantize=True, y_channel=True),
}


# ==============================================================================
# 10. EMA
# ==============================================================================
class ModelEMA:
    """Polyak averaging with the standard warm-up decay min(decay, (1+n)/(10+n)),
    so the shadow model is not dominated by the random initialisation early on."""

    def __init__(self, model: nn.Module, decay: float = 0.999):
        self.ema = copy.deepcopy(model).eval()
        for p in self.ema.parameters():
            p.requires_grad_(False)
        self.decay, self.updates = decay, 0

    @torch.no_grad()
    def update(self, model: nn.Module):
        self.updates += 1
        d = min(self.decay, (1 + self.updates) / (10 + self.updates))
        msd = model.state_dict()
        for k, v in self.ema.state_dict().items():
            mv = msd[k].detach()
            if v.dtype.is_floating_point:
                v.mul_(d).add_(mv.to(v.dtype), alpha=1.0 - d)
            else:
                v.copy_(mv)

    def state_dict(self):
        return {"ema": self.ema.state_dict(), "updates": self.updates}

    def load_state_dict(self, sd):
        if "ema" in sd:
            self.ema.load_state_dict(sd["ema"])
            self.updates = sd.get("updates", 0)
        else:
            self.ema.load_state_dict(sd)


# ==============================================================================
# 11. MODEL TRAINER (iteration based)
# ==============================================================================
def _load_ckpt(path: str, device: str, mmap: bool = False):
    if mmap:
        try:  # memory-mapped: cheap to open several candidates just to read their iteration
            return torch.load(path, map_location=device, weights_only=False, mmap=True)
        except (TypeError, RuntimeError, ValueError, OSError):
            pass
    try:
        return torch.load(path, map_location=device, weights_only=False)
    except TypeError:
        return torch.load(path, map_location=device)


def _checkpoint_candidates(path: Optional[str]) -> List[str]:
    """latest.pth, best.pth-free list of resumable files in a folder (or the file itself)."""
    if not path:
        return []
    if os.path.isfile(path):
        return [path]
    if not os.path.isdir(path):
        return []
    out = [os.path.join(path, "latest.pth")] if os.path.isfile(os.path.join(path, "latest.pth")) else []
    return out + sorted(glob.glob(os.path.join(path, "iter_*.pth")), reverse=True)


def _is_drive_path(path: str) -> bool:
    return os.path.abspath(path).startswith(os.path.abspath(DRIVE_MOUNT) + os.sep)


def _atomic_torch_save(obj, path: str):
    """Write-then-rename in the SAME directory (os.replace across the local disk and the
    Drive mount fails with EXDEV). Files for Drive are serialised on the fast local SSD first."""
    if _is_drive_path(path):
        local = os.path.join(LOCAL_ROOT, "ckpt_tmp", os.path.basename(path))
        os.makedirs(os.path.dirname(local), exist_ok=True)
        torch.save(obj, local)
        _atomic_copy(local, path)
        os.remove(local)
        return
    tmp = path + ".tmp"
    torch.save(obj, tmp)
    os.replace(tmp, path)


def _atomic_copy(src: str, dst: str):
    tmp = dst + ".tmp"
    shutil.copyfile(src, tmp)
    os.replace(tmp, dst)


def _local_ckpt_dir(checkpoint_dir: str) -> str:
    """Fast local working directory for a (Drive) checkpoint folder; the folder itself
    when it is not on Drive."""
    if not _is_drive_path(checkpoint_dir):
        return checkpoint_dir
    tag = re.sub(r"[^A-Za-z0-9]+", "_", os.path.relpath(os.path.abspath(checkpoint_dir), DRIVE_MOUNT)).strip("_")
    return os.path.join(LOCAL_ROOT, "checkpoints", tag[-120:])


def resolve_eval_checkpoint(path: Optional[str]) -> Optional[str]:
    """For evaluation: best.pth (validation-selected) if present, else the newest resumable file."""
    if path and os.path.isdir(path) and os.path.isfile(os.path.join(path, "best.pth")):
        return os.path.join(path, "best.pth")
    c = _checkpoint_candidates(path)
    return c[0] if c else None


def session_hours() -> float:
    """Age of this Colab VM in hours (/proc/uptime: Colab gives every session a fresh VM, and the
    session limit counts from its start), else the time since this script was loaded."""
    if IN_COLAB:
        try:
            with open("/proc/uptime") as f:
                return float(f.read().split()[0]) / 3600.0
        except (OSError, ValueError):
            pass
    return (time.time() - SCRIPT_START) / 3600.0


class ModelTrainer:
    """
    Iteration-based trainer with multi-GPU support.

    Batch policy: each progressive stage defines a GLOBAL batch (Restormer: 64 at
    128 px ... 8 at 384 px). At start-up the trainer measures, for every patch
    size, the largest per-GPU micro-batch that fits in `probe_memory_fraction`
    of GPU memory (linear memory model from two probe steps, then verified),
    takes the minimum over all GPUs, and reaches the global batch as
        micro-batch x GPUs x gradient-accumulation steps.
    With DDP, accumulation steps run under `no_sync()` so gradients are
    all-reduced once per optimizer step. All control decisions (stop signal,
    time budget, micro-batch caps) are synchronised across ranks; only rank 0
    validates and writes checkpoints.

    Colab edition: checkpoints are written to a LOCAL working folder (rolling
    iter_*.pth snapshots every `save_every` iterations / `save_every_minutes`) and
    latest.pth / best.pth + logs are mirrored to Google Drive every
    `drive_sync_minutes` and at every validation / stop / crash. Only two files ever
    live on Drive, because files deleted on the Drive mount go to the Drive Trash
    and keep counting against the quota for 30 days.
    """

    def __init__(self, config: Config, model: nn.Module, train_sets: List[ImageRestorationDataset],
                 val_sets: List[ImageRestorationDataset], criterion: nn.Module, input_psnr: Dict[str, float] = None,
                 tag: str = "main"):
        self.config, self.model, self.criterion = config, model, criterion  # self.model: UNWRAPPED module
        self.tag = tag
        self.train_sets = [d for d in train_sets if len(d) > 0]
        self.val_sets = [d for d in val_sets if len(d) > 0]
        self.input_psnr = input_psnr or {}
        self.local_dir = _local_ckpt_dir(config.checkpoint_dir)
        self.mirror = os.path.abspath(self.local_dir) != os.path.abspath(config.checkpoint_dir)

        decay, no_decay = [], []
        for n, p in model.named_parameters():
            if not p.requires_grad:
                continue
            (no_decay if (p.ndim <= 1 or n.endswith(".bias") or "rpb" in n or "norm" in n
                          or "smooth_logits" in n or "gate_" in n or "residual_scale" in n) else decay).append(p)
        self.optimizer = torch.optim.AdamW([{"params": decay, "weight_decay": config.weight_decay},
                                            {"params": no_decay, "weight_decay": 0.0}],
                                           lr=config.lr, betas=config.betas)
        self.amp_device_type = "cuda" if config.device.startswith("cuda") else "cpu"
        self.use_amp = config.use_amp and config.device.startswith("cuda")
        self.amp_dtype = torch.float16
        if self.use_amp and config.prefer_bf16 and native_bf16():
            self.amp_dtype = torch.bfloat16
        self.scaler = torch.amp.GradScaler(self.amp_device_type, enabled=self.use_amp and self.amp_dtype == torch.float16)
        self.ema = ModelEMA(model, config.ema_decay) if config.use_ema else None
        self.iteration, self.best_psnr = 0, -1.0
        self._last_save_iter, self._last_save_time = 0, time.time()
        self._last_mirror_time = time.time()
        self._stop_signal = None
        self._compile_pending_ok = False
        self.stopped_by_budget = False
        os.makedirs(config.checkpoint_dir, exist_ok=True)
        os.makedirs(self.local_dir, exist_ok=True)
        self._restore_logs()
        if config.resume_training:
            self._resume_checkpoint()
        self.caps: Dict[int, int] = {}
        self.speeds: Dict[int, Optional[float]] = {}
        self.plan: List[dict] = []
        self.compiled = False
        if self.train_sets and self.iteration < config.total_iters:
            self._measure_caps()      # eager probe (conservative for memory), BEFORE DDP wrapping
            self.plan = self._build_plan()
            self.compiled = self._setup_compile()  # after the EMA copy (which stays eager)
            self._print_plan()
        self.net = self._wrap(model)
        self.broadcast_ema()

    # ------------------------------------------------------------ multi-GPU
    def _wrap(self, model: nn.Module) -> nn.Module:
        if DIST.ddp:
            from torch.nn.parallel import DistributedDataParallel as DDP
            kw = dict(device_ids=[DIST.local_rank], output_device=DIST.local_rank) if torch.cuda.is_available() else {}
            return DDP(model, find_unused_parameters=False, **kw)  # buffers synced from rank 0 (default)
        return model

    def broadcast_ema(self):
        """Keeps every rank's EMA identical to rank 0's (needed for sharded evaluation)."""
        if DIST.ddp and self.ema is not None:
            import torch.distributed as dist
            for v in self.ema.ema.state_dict().values():
                dist.broadcast(v, src=0)

    # ---------------------------------------------------------- compilation
    def _setup_compile(self) -> bool:
        """Compile the memory-bound blocks (static shapes), then verify forward AND
        backward against eager execution at the first stage's real shape and time
        both. Any exception or mismatch (on any rank) -> eager mode everywhere.
        The measured speed-up rescales the probe's (eager) throughput estimates."""
        c = self.config
        if not (c.compile_model and (c.device.startswith("cuda") or c.compile_on_cpu)) or not self.plan:
            return False
        allowed = dist_all_reduce([float(compile_guard_allows(c))], "min")[0]
        if not allowed:
            return False
        ok, why, speedup = 1.0, "", 1.0
        t0 = time.time()
        st = self.plan[self.stage_at(self.iteration)]
        compile_guard_mark(c, "attempting")
        try:
            if compile_blocks(self.model) == 0:
                ok, why = 0.0, "torch.compile needs PyTorch >= 2.2"
            else:
                print(f"  compiling the SINA / local blocks for {st['micro']}x{st['patch']}px and checking them "
                      f"against eager mode (one-time per stage, a few minutes)...")
                err, speedup = self._compile_check(st["patch"], st["micro"])
                if not err < 2e-2:
                    ok, why = 0.0, f"compiled output differs from eager by {err:.2e}"
        except Exception as e:  # Triton / Inductor / Dynamo failure on this platform, or OOM
            ok, why = 0.0, f"{type(e).__name__}: {str(e).splitlines()[0][:300] if str(e) else ''}"
        ok, speedup = dist_all_reduce([ok], "min")[0], dist_all_reduce([speedup], "min")[0]
        if not ok:
            compile_guard_mark(c, "failed")
            self._disable_compile(why or "failed on another rank")
            return False
        compile_guard_mark(c, "ok")
        for p in self.speeds:
            if self.speeds[p]:
                self.speeds[p] *= max(1.0, speedup)
        print(f"  torch.compile OK ({time.time() - t0:.0f} s incl. compilation): matches eager, "
              f"{speedup:.1f}x faster per training step.")
        return True

    def _disable_compile(self, why: str):
        uncompile_blocks(self.model)
        try:
            import torch._dynamo
            torch._dynamo.reset()
        except Exception:
            pass
        if self.config.device.startswith("cuda"):
            torch.cuda.empty_cache()
        self.compiled = False
        print(f"  torch.compile disabled ({why}); training in eager mode.")

    def _compile_check(self, patch: int, b: int) -> Tuple[float, float]:
        """(relative max difference compiled vs eager, eager_time / compiled_time)
        for one training step (train mode, forward + backward, identical weights
        and signature statistics)."""
        m = self.model
        stds = [x for x in m.modules() if isinstance(x, RunningStandardizer)]
        saved = [(x, (x.mean.clone(), x.sq.clone(), x.count.clone())) for x in stds]
        g = torch.Generator(device="cpu").manual_seed(0)
        x = torch.rand(b, 3, patch, patch, generator=g).to(self.config.device)
        m.train()
        sync = (lambda: torch.cuda.synchronize()) if self.config.device.startswith("cuda") else (lambda: None)

        def run():
            self._restore_standardizers(saved)
            sync()
            t = time.time()
            with torch.autocast(self.amp_device_type, dtype=self.amp_dtype, enabled=self.use_amp):
                out, aux = m(x, return_aux=True)
            out.float().square().mean().backward()
            sync()
            dt = time.time() - t
            gnorm = torch.sqrt(sum((p.grad.float() ** 2).sum() for p in m.parameters() if p.grad is not None))
            m.zero_grad(set_to_none=True)
            return out.detach().float(), float(gnorm), dt

        try:
            run()                       # compiles
            out_c, g_c, t_c = run()     # timed, compiled
            with eager_mode(m):
                run()                   # eager warm-up (cudnn autotune)
                out_e, g_e, t_e = run()
        finally:
            self._restore_standardizers(saved)
            m.zero_grad(set_to_none=True)
        if not (torch.isfinite(out_c).all() and math.isfinite(g_c)):
            return float("inf"), 1.0
        err = float((out_c - out_e).abs().max() / out_e.abs().max().clamp_min(1e-6))
        return max(err, abs(g_c - g_e) / max(abs(g_e), 1e-12)), t_e / max(t_c, 1e-9)

    # -------------------------------------------------- batch-size planning
    def _stage_global_batches(self) -> Dict[int, int]:
        out: Dict[int, int] = {}
        for _, p, gb in self.config.progressive_schedule:
            out[p] = max(out.get(p, 0), gb)
        return out

    def _cache_key(self, patch: int) -> str:
        c = self.config
        gpu = torch.cuda.get_device_name(torch.device(c.device)) if c.device.startswith("cuda") else "cpu"
        flags = f"w{int(c.use_wiener)}h{int(c.use_homeostasis)}c{int(c.use_coherence_fusion)}d{int(c.use_degradation_conditioning)}"
        return f"{gpu}|p{patch}|{tuple(c.dims)}|{tuple(c.enc_blocks)}|{c.bottleneck_blocks}|{tuple(c.dec_blocks)}|" \
               f"{self.amp_dtype}|ckpt{c.use_checkpoint}|f{c.probe_memory_fraction}|{flags}"

    def _read_json(self, name: str) -> dict:
        for d in (self.local_dir, self.config.checkpoint_dir):
            try:
                with open(os.path.join(d, name)) as f:
                    return json.load(f)
            except (OSError, ValueError):
                continue
        return {}

    def _write_json(self, name: str, data: dict):
        if not DIST.is_main:
            return
        for d in {self.local_dir, self.config.checkpoint_dir}:
            try:
                with open(os.path.join(d, name), "w") as f:
                    json.dump(data, f, indent=1)
            except OSError:
                pass

    @torch.no_grad()
    def _restore_standardizers(self, saved):
        for m, (a, b, n) in saved:
            m.mean.copy_(a); m.sq.copy_(b); m.count.copy_(n)

    def _probe(self, patch: int, need: int) -> Tuple[int, float]:
        """Largest per-GPU micro-batch for `patch` within probe_memory_fraction of
        GPU memory, plus measured training throughput (samples/s/GPU)."""
        c = self.config
        dev = torch.device(c.device)
        m, crit = self.model, self.criterion
        stds = [x for x in m.modules() if isinstance(x, RunningStandardizer)]
        saved = [(x, (x.mean.clone(), x.sq.clone(), x.count.clone())) for x in stds]
        total = torch.cuda.get_device_properties(dev).total_memory
        param_bytes = sum(p.numel() * p.element_size() for p in m.parameters())
        budget = c.probe_memory_fraction * total - 2 * param_bytes  # AdamW moments are allocated at step 1
        m.train()

        def trial(b: int) -> Tuple[int, float]:
            torch.cuda.synchronize(dev)
            torch.cuda.empty_cache()
            torch.cuda.reset_peak_memory_stats(dev)
            x = torch.rand(b, 3, patch, patch, device=dev)
            y = torch.rand_like(x)
            t0 = time.time()
            with torch.autocast("cuda", dtype=self.amp_dtype, enabled=self.use_amp):
                out, aux = m(x, return_aux=True)
            loss, _ = crit(out, y, aux)
            loss.backward()
            torch.cuda.synchronize(dev)
            dt = time.time() - t0
            peak = torch.cuda.max_memory_allocated(dev)
            m.zero_grad(set_to_none=True)
            return peak, dt

        try:
            p1, _ = trial(1)
            p2, _ = trial(2) if need > 1 else (p1, 0.0)
            per = max(p2 - p1, 1)
            b = int((budget - (p1 - per)) // per) if need > 1 else 1
            b = max(1, min(b, need))
            while True:
                try:
                    trial(b)
                    _, dt = trial(b)
                    break
                except torch.cuda.OutOfMemoryError:
                    m.zero_grad(set_to_none=True)
                    torch.cuda.empty_cache()
                    if b == 1:
                        raise RuntimeError(f"A single {patch}x{patch} sample does not fit on this GPU: remove that "
                                           f"stage from progressive_schedule or enable use_checkpoint.")
                    b = max(1, int(b * 0.8))
        finally:
            m.zero_grad(set_to_none=True)
            self._restore_standardizers(saved)
            torch.cuda.empty_cache()
        return b, b / max(dt, 1e-6)

    def _measure_caps(self):
        c = self.config
        needs = self._stage_global_batches()
        cache = self._read_json("probe_cache.json")
        hints = self._read_json("oom_caps.json")
        for p, gb in sorted(needs.items()):
            need = math.ceil(gb / DIST.total_gpus)
            if c.max_micro_batch > 0:
                cap, sps = min(c.max_micro_batch, need), None
            elif not c.device.startswith("cuda"):
                cap, sps = min(2, need), None
            else:
                key = self._cache_key(p)
                hit = cache.get(key)
                # reuse a cached probe only if it was memory-limited or probed for at least this need
                if hit and len(hit) == 3 and (hit[0] < hit[2] or hit[2] >= need):
                    cap, sps = min(int(hit[0]), need), hit[1]
                else:
                    print(f"  probing max micro-batch at {p}x{p} ...")
                    cap, sps = self._probe(p, need)
                    cache[key] = [cap, sps, need]
            if str(p) in hints:
                cap = min(cap, int(hints[str(p)]))
            self.caps[p], self.speeds[p] = cap, sps
        if DIST.ddp:  # every rank must use the same micro-batch (slowest / smallest GPU decides)
            ps = sorted(self.caps)
            mins = dist_all_reduce([float(self.caps[p]) for p in ps], "min")
            sp = dist_all_reduce([float(self.speeds[p] or 0.0) for p in ps], "min")
            for p, cp, s in zip(ps, mins, sp):
                self.caps[p], self.speeds[p] = int(cp), (s or None)
        self._write_json("probe_cache.json", cache)

    def _build_plan(self) -> List[dict]:
        c = self.config
        plan = []
        for frac, p, gb in c.progressive_schedule:
            cap_proc = self.caps[p] * DIST.gpus_per_proc          # samples per process per micro-step
            accum = max(1, math.ceil(gb / (cap_proc * DIST.world)))
            micro = max(1, math.ceil(gb / (accum * DIST.world)))  # <= cap_proc by construction
            k_target = max(1, int(round(c.crops_per_image * min(1.0, (128.0 / p) ** 2))))
            k = max(d for d in range(1, k_target + 1) if micro % d == 0)
            plan.append(dict(start=int(frac * c.total_iters), patch=p, global_batch=gb, micro=micro, accum=accum,
                             crops=k, effective=micro * accum * DIST.world))
        for i, st in enumerate(plan):
            st["end"] = plan[i + 1]["start"] if i + 1 < len(plan) else c.total_iters
        return plan

    def _print_plan(self):
        c = self.config
        eff = {"none": 1.0, "ddp": 0.9}[DIST.mode]
        print(f"\nBatch plan [{self.tag}] ({DIST.total_gpus} GPU(s), mode={DIST.mode}, compiled={self.compiled}; "
              f"micro-batch = largest that fits):")
        print("  stage | iters            | patch | global batch = micro/proc x procs x accum | crops/img | est. hours")
        total_h, known = 0.0, True
        for i, st in enumerate(self.plan):
            its = max(0, st["end"] - max(st["start"], self.iteration))
            sps = self.speeds.get(st["patch"])
            if sps:
                h = its * st["effective"] / (sps * DIST.total_gpus * eff) / 3600
                total_h += h
                hs = f"{h:8.1f}"
            else:
                known, hs = False, "     n/a"
            print(f"  {i:5d} | {st['start']:>7d}-{st['end']:<7d} | {st['patch']:5d} | {st['effective']:4d} = "
                  f"{st['micro']:3d} x {DIST.world} x {st['accum']:2d}{'':20s} | {st['crops']:9d} | {hs}")
        if known:
            left = max(0.1, c.max_session_hours - session_hours())
            print(f"  Estimated remaining training time: ~{total_h:.0f} h of GPU time "
                  f"(~{math.ceil(total_h / c.max_session_hours)} Colab session(s) of {c.max_session_hours} h; "
                  f"{left:.1f} h left in this one). Rough estimate from the probe; the progress bar shows the real ETA.")
            if total_h > 3 * c.max_session_hours:
                print(f"  NOTE: to fit a smaller budget, lower total_iters (milestones scale with it), "
                      f"e.g. total_iters={int(c.total_iters * 3 * c.max_session_hours / total_h):,} for ~3 sessions.")

    # ---------------------------------------------------------------- schedule
    def lr_at(self, it: int) -> float:
        c = self.config
        if it < c.warmup_iters:
            return c.lr * (it + 1) / c.warmup_iters
        t = (it - c.warmup_iters) / max(1, c.total_iters - c.warmup_iters)
        return c.min_lr + 0.5 * (c.lr - c.min_lr) * (1 + math.cos(math.pi * min(1.0, t)))

    def stage_at(self, it: int) -> int:
        idx = 0
        for i, st in enumerate(self.plan):
            if it >= st["start"]:
                idx = i
        return idx

    def _make_loader(self, si: int, start: int) -> DataLoader:
        st = self.plan[si]
        for d in self.train_sets:
            d.patch_size, d.crops = st["patch"], st["crops"]
        concat = ConcatDataset(self.train_sets)
        sampler = MultiTaskInfiniteSampler(concat, self.config.task_sampling, self.config.seed, start)
        nw = self.config.num_workers if self.config.num_workers >= 0 else max(1, (os.cpu_count() or 2) // DIST.world)
        return DataLoader(concat, batch_size=st["micro"] // st["crops"], sampler=sampler, num_workers=nw,
                          pin_memory=self.config.device.startswith("cuda"), drop_last=True,
                          persistent_workers=nw > 0, prefetch_factor=4 if nw > 0 else None,
                          worker_init_fn=_worker_init, collate_fn=train_collate)

    # -------------------------------------------------------------- logs
    def _restore_logs(self):
        """A new Colab session starts with an empty local disk: continue the CSV logs from Drive."""
        if not (self.mirror and DIST.is_main):
            return
        for name in ("train_log.csv", "val_log.csv"):
            src, dst = os.path.join(self.config.checkpoint_dir, name), os.path.join(self.local_dir, name)
            if os.path.isfile(src) and not os.path.isfile(dst):
                try:
                    shutil.copyfile(src, dst)
                except OSError:
                    pass

    def _append_csv(self, name: str, row: dict):
        if not DIST.is_main:
            return
        path = os.path.join(self.local_dir, name)
        new = not os.path.isfile(path)
        try:
            with open(path, "a", newline="") as f:
                w = csv.DictWriter(f, fieldnames=list(row.keys()), extrasaction="ignore")
                if new:
                    w.writeheader()
                w.writerow(row)
        except OSError:
            pass

    # -------------------------------------------------------------- checkpoint
    def _resume_checkpoint(self):
        """Resume from the NEWEST VALID checkpoint among the local working folder, the
        Drive checkpoint_dir and resume_from (file or folder): latest.pth and the rolling
        iter_*.pth snapshots are all considered, a truncated/corrupt file or one with
        non-finite weights is skipped with a warning, and the next newest is tried.
        The LR, progressive stage and sampler position are all derived from the
        restored iteration, so training continues exactly on schedule."""
        cands = (_checkpoint_candidates(self.local_dir) + _checkpoint_candidates(self.config.checkpoint_dir)
                 + _checkpoint_candidates(self.config.resume_from))
        seen, found = set(), []
        for p in cands:
            rp = os.path.realpath(p)
            if rp in seen:
                continue
            seen.add(rp)
            try:
                ck = _load_ckpt(p, "cpu", mmap=True)
                found.append((int(ck.get("iteration", -1)), p, ck))
            except Exception as e:
                print(f"  skipping unreadable checkpoint {p}: {type(e).__name__}: {str(e)[:120]}")
        for it, p, ck in sorted(found, key=lambda t: -t[0]):
            sd = ck.get("model", {})
            if not sd or not all(torch.isfinite(v).all() for v in sd.values() if torch.is_tensor(v) and v.is_floating_point()):
                print(f"  skipping {p}: missing or non-finite weights")
                continue
            try:
                self.model.load_state_dict(sd)
            except RuntimeError as e:
                print(f"  skipping {p}: not a checkpoint of this architecture ({str(e)[:160]})")
                continue
            if self.ema is not None and "ema" in ck:
                self.ema.load_state_dict(ck["ema"])
            try:
                self.optimizer.load_state_dict(ck["optimizer"])
            except (ValueError, KeyError) as e:
                print(f"  optimizer state not restored ({e}); continuing with fresh AdamW moments.")
            if "scaler" in ck:
                self.scaler.load_state_dict(ck["scaler"])
            self.iteration = it
            self.best_psnr = float(ck.get("best_psnr", -1.0))
            self._last_save_iter = it
            print(f"Resumed [{self.tag}] from {p} at iteration {it}/{self.config.total_iters} | "
                  f"best val PSNR {self.best_psnr:.2f} dB")
            return
        if found or cands:
            print("No valid checkpoint could be restored; starting from scratch.")

    def _save_checkpoint(self, is_best: bool = False, reason: str = "periodic") -> bool:
        """Atomic, verified save (rank 0 only) into the LOCAL working folder: a rolling
        snapshot iter_XXXXXXX.pth is written via a temporary file + os.replace (a crash
        mid-write can never corrupt an existing checkpoint), then copied atomically to
        latest.pth (and best.pth). Weights are checked to be finite first, so a diverged
        model can never overwrite a good checkpoint. latest.pth / best.pth / logs are then
        mirrored to Google Drive (see the class docstring for the cadence)."""
        if not DIST.is_main:
            return True
        c = self.config
        if not all(torch.isfinite(p).all() for p in self.model.parameters()):
            print(f"ERROR: non-finite weights at iteration {self.iteration}; checkpoint NOT written "
                  f"(the previous good checkpoints are kept).")
            return False
        state = {"iteration": self.iteration, "model": self.model.state_dict(),
                 "optimizer": self.optimizer.state_dict(), "scaler": self.scaler.state_dict(),
                 "best_psnr": self.best_psnr, "config": asdict(c), "saved_at": time.time(), "reason": reason}
        if self.ema is not None:
            state["ema"] = self.ema.state_dict()
        d = self.local_dir
        latest = os.path.join(d, "latest.pth")
        meta = {"iteration": self.iteration, "total_iters": c.total_iters, "best_psnr": self.best_psnr,
                "reason": reason, "time": time.strftime("%Y-%m-%d %H:%M:%S")}
        try:
            os.makedirs(d, exist_ok=True)
            if c.keep_last_checkpoints > 0:
                snap = os.path.join(d, f"iter_{self.iteration:07d}.pth")
                _atomic_torch_save(state, snap)
                _atomic_copy(snap, latest)
                snaps = sorted(glob.glob(os.path.join(d, "iter_*.pth")))
                for old in snaps[:-c.keep_last_checkpoints]:
                    os.remove(old)
            else:
                _atomic_torch_save(state, latest)
            if is_best:
                _atomic_copy(latest, os.path.join(d, "best.pth"))
            with open(os.path.join(d, "latest.json"), "w") as f:
                json.dump(meta, f)
        except OSError as e:
            print(f"WARNING: could not save checkpoint ({e}). Training continues; free disk space!")
            return False
        self._last_save_iter, self._last_save_time = self.iteration, time.time()
        if self.mirror and (reason != "periodic" or is_best
                            or time.time() - self._last_mirror_time > c.drive_sync_minutes * 60):
            self._mirror_to_drive(is_best, meta)
        return True

    def _mirror_to_drive(self, is_best: bool, meta: dict):
        c = self.config
        t0 = time.time()
        try:
            os.makedirs(c.checkpoint_dir, exist_ok=True)
            _atomic_copy(os.path.join(self.local_dir, "latest.pth"), os.path.join(c.checkpoint_dir, "latest.pth"))
            if is_best:
                _atomic_copy(os.path.join(self.local_dir, "best.pth"), os.path.join(c.checkpoint_dir, "best.pth"))
            for name in ("train_log.csv", "val_log.csv"):
                src = os.path.join(self.local_dir, name)
                if os.path.isfile(src):
                    _atomic_copy(src, os.path.join(c.checkpoint_dir, name))
            with open(os.path.join(c.checkpoint_dir, "latest.json"), "w") as f:
                json.dump(dict(meta, drive_mirror=True), f)
            self._last_mirror_time = time.time()
            tqdm.write(f"  [drive] checkpoint of iteration {self.iteration} mirrored to {c.checkpoint_dir} "
                       f"({time.time() - t0:.0f} s)")
        except OSError as e:
            print(f"WARNING: could not mirror the checkpoint to Google Drive ({e}); it is kept locally in "
                  f"{self.local_dir} and mirroring is retried at the next save.")

    def _record_oom(self, patch: int, micro_per_gpu: int):
        """Persist a halved micro-batch cap so the next (re)start never repeats the OOM."""
        hints = self._read_json("oom_caps.json")
        hints[str(patch)] = max(1, min(int(hints.get(str(patch), 10 ** 9)), micro_per_gpu // 2))
        for d in {self.local_dir, self.config.checkpoint_dir}:  # every rank may hit it; same value
            try:
                with open(os.path.join(d, "oom_caps.json"), "w") as f:
                    json.dump(hints, f)
            except OSError:
                pass
        return hints[str(patch)]

    def eval_model(self) -> nn.Module:
        return self.ema.ema if self.ema is not None else self.model

    # ------------------------------------------------------------------- train
    def train(self):
        """Runs the training loop with crash protection: SIGTERM (e.g. a platform
        shutting the session down) requests a clean save-and-stop at the next
        iteration, and any exception or Ctrl-C / notebook interrupt triggers an
        emergency checkpoint (rank 0, mirrored to Drive) before the error is re-raised.
        Re-running the script then resumes."""
        if not self.train_sets:
            print("\nNo training data found. Skipping training.")
            return
        self._stop_signal = None
        prev_handler = None
        try:
            import signal
            prev_handler = signal.signal(signal.SIGTERM, lambda signum, frame: setattr(self, "_stop_signal", signum))
        except (ValueError, OSError, AttributeError):  # not in the main thread / unsupported platform
            prev_handler = None
        try:
            self._train_loop()
        except BaseException as e:
            if DIST.is_main and self.iteration > self._last_save_iter:
                print(f"\nTraining interrupted ({type(e).__name__}) at iteration {self.iteration}; "
                      f"writing an emergency checkpoint...")
                try:
                    if self._save_checkpoint(reason=f"emergency:{type(e).__name__}"):
                        print("  emergency checkpoint written (and mirrored to Drive); re-run to resume.")
                except Exception as e2:
                    print(f"  emergency save failed ({type(e2).__name__}: {e2}); last periodic checkpoint "
                          f"is at iteration {self._last_save_iter}.")
            raise
        finally:
            if prev_handler is not None:
                import signal
                signal.signal(signal.SIGTERM, prev_handler)
        dist_barrier()  # rank 0 may still be writing the final checkpoint

    def _train_loop(self):
        import contextlib
        c = self.config
        t_start = time.time()
        stage_idx, loader_it = None, None
        skipped, consecutive_skips, window = 0, 0, []
        replan = False
        self.model.train()
        pbar = tqdm(total=c.total_iters, initial=self.iteration, desc=f"Train[{self.tag}]", dynamic_ncols=True,
                    disable=not DIST.is_main, **_tqdm_kw())
        while self.iteration < c.total_iters:
            si = self.stage_at(self.iteration)
            if si != stage_idx or replan:
                stage_idx, replan = si, False
                st = self.plan[si]
                print(f"\n[progressive] iter {self.iteration}: patch={st['patch']} | global batch {st['effective']} = "
                      f"{st['micro']}/GPU x {DIST.world} process(es) x {st['accum']} accumulation | "
                      f"{st['crops']} crops per decoded image"
                      + ("\n  (the first iterations of this stage include torch.compile for its new shape)"
                         if self.compiled else ""))
                if self.compiled:  # a new static shape compiles now: guard against a native crash
                    compile_guard_mark(c, "attempting")
                    self._compile_pending_ok = True
                loader_it = iter(self._make_loader(si, self.iteration))
            st = self.plan[stage_idx]
            accum = st["accum"]
            lr = self.lr_at(self.iteration)
            for g in self.optimizer.param_groups:
                g["lr"] = lr
            self.optimizer.zero_grad(set_to_none=True)
            logs, in_ps = {}, []
            try:
                for i in range(accum):
                    degraded, clean, _tid = next(loader_it)
                    degraded = degraded.to(c.device, non_blocking=True)
                    clean = clean.to(c.device, non_blocking=True)
                    sync = self.net.no_sync() if (DIST.ddp and i < accum - 1) else contextlib.nullcontext()
                    with sync:
                        with torch.autocast(self.amp_device_type, dtype=self.amp_dtype, enabled=self.use_amp):
                            pred, aux = self.net(degraded, return_aux=True)  # aux == [] when disabled
                        loss, logs = self.criterion(pred, clean, aux_preds=aux)
                        self.scaler.scale(loss / accum).backward()
                    with torch.no_grad():
                        in_ps.append(float(batch_psnr(degraded, clean).mean()))
                logs["in_psnr"] = float(np.mean(in_ps))
            except torch.cuda.OutOfMemoryError:
                pred = aux = loss = None
                self.optimizer.zero_grad(set_to_none=True)
                torch.cuda.empty_cache()
                per_gpu = max(1, st["micro"] // DIST.gpus_per_proc)
                new_cap = self._record_oom(st["patch"], per_gpu)
                if DIST.ddp:
                    raise RuntimeError(f"CUDA OOM under DDP at patch {st['patch']}: the micro-batch cap was lowered "
                                       f"to {new_cap} in oom_caps.json; re-run the same command to resume.")
                if per_gpu <= 1:
                    raise RuntimeError(f"CUDA OOM at micro-batch 1, patch {st['patch']}: lower that stage's patch size.")
                self.caps[st["patch"]] = new_cap
                self.plan = self._build_plan()
                replan = True
                print(f"CUDA OOM: micro-batch cap for {st['patch']} px lowered to {new_cap}/GPU "
                      f"(accumulation increased, global batch unchanged).")
                continue
            except Exception as e:
                if not (self.compiled and is_compile_error(e)):
                    raise
                pred = aux = loss = None
                self.optimizer.zero_grad(set_to_none=True)
                compile_guard_mark(c, "failed")
                self._compile_pending_ok = False
                self._disable_compile(f"{type(e).__name__} at patch {st['patch']}")
                continue  # identical on every rank (same shapes, same code) -> retried eagerly
            if self._compile_pending_ok:
                compile_guard_mark(c, "ok")
                self._compile_pending_ok = False
            self.scaler.unscale_(self.optimizer)
            gnorm = torch.nn.utils.clip_grad_norm_(self.model.parameters(), c.max_grad_norm)
            if not torch.isfinite(gnorm):  # identical on all ranks (gradients were all-reduced)
                skipped += 1
                consecutive_skips += 1
                if self.scaler.is_enabled():
                    self.scaler.step(self.optimizer)  # GradScaler skips the step and lowers the scale
                    self.scaler.update()
                else:
                    self.optimizer.zero_grad(set_to_none=True)
                if consecutive_skips > 50:
                    raise RuntimeError("50 consecutive non-finite gradient steps: check the data audit and the lr.")
                continue
            consecutive_skips = 0
            self.scaler.step(self.optimizer)
            self.scaler.update()
            if self.ema is not None:
                self.ema.update(self.model)
            self.iteration += 1
            pbar.update(1)
            window.append((logs["psnr"], logs["in_psnr"]))

            if self.iteration % c.log_every == 0:
                ps = np.mean([w[0] for w in window]); ip = np.mean([w[1] for w in window]); window.clear()
                el = time.time() - t_start
                pbar.set_postfix(loss=f"{loss.item():.4f}", psnr=f"{ps:.2f}", gain=f"{ps - ip:+.2f}dB",
                                 lr=f"{lr:.2e}", g=f"{float(gnorm):.2f}")
                parts = " ".join(f"{k}={v:.4f}" for k, v in logs.items() if k not in ("psnr", "in_psnr"))
                if DIST.is_main:
                    tqdm.write(f"it {self.iteration} | {parts} | train PSNR {ps:.2f} (input {ip:.2f}, gain {ps - ip:+.2f} dB)"
                               f" | lr {lr:.2e} | |g| {float(gnorm):.3f} | skipped {skipped} | {el / 3600:.2f} h")
                row = {"iteration": self.iteration, "hours": round(el / 3600, 4), "lr": lr, "loss": float(loss.item()),
                       "psnr": float(ps), "in_psnr": float(ip), "gain": float(ps - ip), "grad_norm": float(gnorm),
                       "patch": st["patch"], "batch": st["effective"], "skipped": skipped}
                for k in ("char", "edge", "freq", "radial", "ssim", "lpips", "aux"):
                    row[k] = float(logs[k]) if k in logs else ""
                self._append_csv("train_log.csv", row)
            if self.iteration % c.val_every == 0 or self.iteration == c.total_iters:
                if DIST.is_main:
                    val = self.validate()
                    is_best = val > self.best_psnr
                    self.best_psnr = max(self.best_psnr, val)
                    self._save_checkpoint(is_best, reason="validation")
                dist_barrier()
                self.model.train()
            elif (self.iteration % c.save_every == 0
                  or time.time() - self._last_save_time > c.save_every_minutes * 60):
                self._save_checkpoint()
            # stop decisions must be identical on every rank
            sig, budget = dist_all_reduce([float(self._stop_signal is not None),
                                           float(session_hours() > c.max_session_hours)], "max")
            if sig:
                self._save_checkpoint(reason="sigterm")
                print(f"\nTermination signal received: checkpoint saved at iteration {self.iteration}. Re-run to resume.")
                break
            if budget:
                self._save_checkpoint(reason="session_budget")
                self.stopped_by_budget = True
                print(f"\nColab session time budget ({c.max_session_hours} h) reached at iteration {self.iteration}/"
                      f"{c.total_iters}. Checkpoint saved and mirrored to {c.checkpoint_dir}.\n  To continue: open a "
                      f"new Colab session and run the same cell again: it resumes automatically from Google Drive.")
                break
        pbar.close()

    @torch.no_grad()
    def validate(self) -> float:
        """Per-task validation of the EMA model on fixed crops (rank 0); prints the
        gain over the INPUT PSNR (a gain near 0 dB = the network is ~identity)."""
        model = self.eval_model()
        model.eval()
        if not self.val_sets:
            return 0.0
        per_task = []
        print(f"\nValidation [{self.tag}] (EMA model):")
        for ds in self.val_sets:
            vals, ins = [], []
            for i in range(len(ds)):
                d, cl, _ = ds[i]
                d, cl = d.unsqueeze(0).to(self.config.device), cl.unsqueeze(0).to(self.config.device)
                with torch.autocast(self.amp_device_type, dtype=self.amp_dtype, enabled=self.use_amp):
                    p = model(d)
                vals.append(float(batch_psnr(p.float(), cl)))
                ins.append(float(batch_psnr(d, cl)))
            m, mi = float(np.mean(vals)), float(np.mean(ins))
            per_task.append(m)
            print(f"  {ds.task:8s}: PSNR {m:.2f} dB (input {mi:.2f}, gain {m - mi:+.2f} dB) on {len(ds)} crops")
            self._append_csv("val_log.csv", {"iteration": self.iteration, "task": ds.task, "psnr": m,
                                             "in_psnr": mi, "gain": m - mi, "n": len(ds)})
        avg = float(np.mean(per_task))
        print(f"  task-averaged val PSNR: {avg:.2f} dB")
        return avg


# ==============================================================================
# 12. EXPLAINABLE INFERENCER (full resolution, tiled fallback, TTA, per-image records)
# ==============================================================================
def _blend_window(h: int, w: int, device) -> torch.Tensor:
    wy = torch.hann_window(h + 2, periodic=False, device=device)[1:-1].clamp_min(1e-3)
    wx = torch.hann_window(w + 2, periodic=False, device=device)[1:-1].clamp_min(1e-3)
    return torch.outer(wy, wx).view(1, 1, h, w)


def _positions(n: int, tile: int, stride: int) -> List[int]:
    if n <= tile:
        return [0]
    pos = list(range(0, n - tile, stride))
    return pos + [n - tile]


N_ERROR_BANDS = 16
STRUCT_LABELS = ("flat", "texture", "edge")
SEVERITY_LABELS = ("mild", "moderate", "severe")


def _sobel_mag(y: torch.Tensor) -> torch.Tensor:
    """|grad| of a (1,1,H,W) map with replicate borders."""
    k = torch.tensor([[-1., 0., 1.], [-2., 0., 2.], [-1., 0., 1.]], dtype=y.dtype, device=y.device)
    yp = F.pad(y, (1, 1, 1, 1), mode="replicate")
    gx = F.conv2d(yp, k.view(1, 1, 3, 3))
    gy = F.conv2d(yp, k.t().contiguous().view(1, 1, 3, 3))
    return torch.sqrt(gx * gx + gy * gy)


def _terciles(v: torch.Tensor) -> torch.Tensor:
    """Per-image tercile class (0,1,2) of every element of v (quantiles on <= 2^20 samples)."""
    flat = v.flatten()
    samp = flat if flat.numel() <= (1 << 20) else flat[torch.randperm(flat.numel(), device=flat.device)[:1 << 20]]
    q = torch.quantile(samp.float(), torch.tensor([1 / 3, 2 / 3], device=flat.device)).to(v.dtype)
    return (v > q[0]).long() + (v > q[1]).long()


@torch.no_grad()
def per_image_stats(deg: torch.Tensor, pred: torch.Tensor, gt: torch.Tensor, n_bands: int = N_ERROR_BANDS) -> dict:
    """Per-image diagnostics used by the evaluation suite (all computed on the full image):

    * band_in / band_out: EXACT Parseval decomposition of the per-pixel MSE of the input and of
      the restoration into `n_bands` radial frequency bands (orthonormal FFT, no window: the
      bands sum exactly to the MSE, so 10*log10(sum in / sum out) is the image's PSNR gain and
      each band says which spatial frequencies carried that gain);
    * cells_*: squared errors pooled in a 3x3 grid of pixel classes, local STRUCTURE (terciles
      of the ground-truth gradient magnitude: flat / texture / edge) x local DEGRADATION
      SEVERITY (terciles of the 7x7-averaged input error: mild / moderate / severe);
    * frac_improved: fraction of pixels whose squared error decreased.
    """
    d, p, g = deg.double(), pred.double().clamp(0, 1), gt.double()
    ed, er = d - g, p - g
    H, W = g.shape[-2:]
    fy = torch.fft.fftfreq(H, device=g.device, dtype=torch.float64).view(H, 1)
    fx = torch.fft.fftfreq(W, device=g.device, dtype=torch.float64).view(1, W)
    band = torch.clamp((torch.sqrt(fy ** 2 + fx ** 2) / 0.5 * n_bands).long(), max=n_bands - 1).view(-1)
    n_el = float(ed.numel())

    def bands(e):
        P = (torch.fft.fft2(e[0], norm="ortho").abs() ** 2).sum(0).view(-1)  # sum over channels
        return (torch.bincount(band, weights=P, minlength=n_bands) / n_el).tolist()

    e_in = (ed ** 2).mean(1, keepdim=True)
    e_out = (er ** 2).mean(1, keepdim=True)
    yg = (0.299 * g[:, 0:1] + 0.587 * g[:, 1:2] + 0.114 * g[:, 2:3]).float()
    s_cls = _terciles(_sobel_mag(yg))
    sev = F.avg_pool2d(F.pad(e_in.float(), (3, 3, 3, 3), mode="replicate"), 7, stride=1)
    v_cls = _terciles(sev)
    cell = (s_cls * 3 + v_cls).view(-1)
    ei, eo = e_in.view(-1), e_out.view(-1)

    def pool(w):
        return torch.bincount(cell, weights=w, minlength=9).view(3, 3).tolist()

    return {"band_in": bands(ed), "band_out": bands(er),
            "cells_in": pool(ei), "cells_out": pool(eo), "cells_n": pool(torch.ones_like(ei)),
            "cells_improved": pool((eo < ei).double()),
            "frac_improved": float((eo < ei).double().mean())}


class ModelInferencer:
    def __init__(self, config: Config, model: nn.Module, compile_ok: bool = False):
        self.config, self.model = config, model
        self.compiled = bool(compile_ok) and compile_guard_allows(config) and compile_blocks(model) > 0
        self._compiled_shapes: set = set()
        self.max_compiled_shapes = 6  # datasets with many image sizes (Rain) run eagerly beyond this
        self.compile_events = 0       # compilations triggered so far (their time is excluded from speed stats)
        os.makedirs(config.output_dir, exist_ok=True)
        self.amp_device_type = "cuda" if config.device.startswith("cuda") else "cpu"
        self.use_amp = config.use_amp and config.device.startswith("cuda")
        self.amp_dtype = torch.bfloat16 if (self.use_amp and config.prefer_bf16 and native_bf16()) else torch.float16

    def _forward(self, x: torch.Tensor, signature: Optional[torch.Tensor]) -> torch.Tensor:
        import contextlib
        shape = tuple(x.shape)
        new_shape = False
        if self.compiled and shape not in self._compiled_shapes and len(self._compiled_shapes) < self.max_compiled_shapes:
            self._compiled_shapes.add(shape)
            new_shape = True
            self.compile_events += 1
        ctx = contextlib.nullcontext() if (self.compiled and shape in self._compiled_shapes) else eager_mode(self.model)
        try:
            if new_shape:
                compile_guard_mark(self.config, "attempting")
            with ctx, torch.autocast(self.amp_device_type, dtype=self.amp_dtype, enabled=self.use_amp):
                out = self.model(x, signature=signature).float()
            if new_shape:
                compile_guard_mark(self.config, "ok")
            return out
        except torch.cuda.OutOfMemoryError:
            raise
        except Exception as e:
            if not self.compiled or "out of memory" in str(e).lower():
                raise
            print(f"  compiled inference failed ({type(e).__name__}); switching to eager mode.")
            compile_guard_mark(self.config, "failed")
            uncompile_blocks(self.model)
            self.compiled = False
            with torch.autocast(self.amp_device_type, dtype=self.amp_dtype, enabled=self.use_amp):
                return self.model(x, signature=signature).float()

    def _tiled(self, x: torch.Tensor, signature: Optional[torch.Tensor], tile: int) -> torch.Tensor:
        """Overlapping Hann-blended tiles. signature=None -> every tile computes its OWN signature
        (only used by the ablation that measures why the shared signature matters)."""
        B, C, H, W = x.shape
        tile = max(64, tile - tile % 8)
        th, tw = min(tile, H), min(tile, W)
        stride = max(8, tile - self.config.tile_overlap)
        out = torch.zeros(B, self.config.out_channels, H, W, device=x.device)
        wsum = torch.zeros(1, 1, H, W, device=x.device)
        win = _blend_window(th, tw, x.device)
        for y in _positions(H, th, stride):
            for xx in _positions(W, tw, stride):
                o = self._forward(x[..., y:y + th, xx:xx + tw], signature)
                out[..., y:y + th, xx:xx + tw] += o * win
                wsum[..., y:y + th, xx:xx + tw] += win
        return out / wsum

    def _signature(self, x: torch.Tensor) -> Optional[torch.Tensor]:
        return self.model.compute_signature(x) if getattr(self.model, "degradation_conditioner", None) is not None else None

    @torch.no_grad()
    def predict(self, x: torch.Tensor, signature: Optional[torch.Tensor] = None) -> torch.Tensor:
        """Full-image inference with the signature computed once on the whole
        image; tiled fallback on OOM (tiles share that signature -> no seams)."""
        sig = self._signature(x) if signature is None else signature
        tile = self.config.inference_tile
        if tile and (x.shape[-1] > tile or x.shape[-2] > tile):
            return self._tiled(x, sig, tile)
        try:
            return self._forward(x, sig)
        except torch.cuda.OutOfMemoryError:
            torch.cuda.empty_cache()
            return self._tiled(x, sig, self.config.fallback_tile)
        except RuntimeError as e:
            if "out of memory" not in str(e).lower():
                raise
            if x.is_cuda:
                torch.cuda.empty_cache()
            return self._tiled(x, sig, self.config.fallback_tile)

    @torch.no_grad()
    def _self_ensemble_predict(self, x: torch.Tensor) -> torch.Tensor:
        outs = []
        for k in range(4):
            for flip in (False, True):
                t = torch.rot90(x, k, [-2, -1])
                t = torch.flip(t, [-1]) if flip else t
                o = self.predict(t)
                o = torch.flip(o, [-1]) if flip else o
                outs.append(torch.rot90(o, -k, [-2, -1]))
        return torch.stack(outs).mean(0)

    def _sync(self):
        if self.config.device.startswith("cuda"):
            torch.cuda.synchronize()

    @torch.no_grad()
    def inference(self, ds: Dataset, dataset_name: str, self_ensemble: bool = False) -> dict:
        """Full-resolution evaluation with the dataset's standard protocol. Returns the
        dataset means plus one record per image (metrics, runtime, error-band and
        structure x severity statistics) used by the evaluation suite. The first
        `num_visualization_samples` restored images are written as full-resolution PNGs
        (16-bit for DPDD); all figures are produced afterwards by EvaluationSuite."""
        if len(ds) == 0:
            print(f"WARNING: {dataset_name} is empty; skipped.")
            return {"psnr": float("nan"), "ssim": float("nan"), "mae": float("nan"), "n": 0, "records": []}
        self.model.eval()
        proto = EVAL_PROTOCOL.get(dataset_name, dict(quantize=True, y_channel=False))
        ds_dir = os.path.join(self.config.output_dir, dataset_name)
        os.makedirs(ds_dir, exist_ok=True)
        n = len(ds) if self.config.max_test_images is None else min(len(ds), self.config.max_test_images)
        # DDP: every rank evaluates every world-th image (images are independent), results are gathered
        mine = list(range(DIST.rank, n, DIST.world)) if DIST.ddp else list(range(n))
        nw = 2 if self.config.num_workers < 0 else min(2, self.config.num_workers)
        loader = DataLoader(torch.utils.data.Subset(ds, mine), batch_size=1, shuffle=False, num_workers=nw)
        records = []
        use_lpips = self.config.eval_lpips
        seen_shapes = set()
        for idx, (degraded, clean, _) in zip(mine, tqdm(loader, desc=f"Evaluating {dataset_name}",
                                                          disable=not DIST.is_main, **_tqdm_kw())):
            degraded, clean = degraded.to(self.config.device), clean.to(self.config.device)
            self._sync()
            c0 = self.compile_events
            t0 = time.perf_counter()
            pred = (self._self_ensemble_predict(degraded) if self_ensemble else self.predict(degraded)).clamp(0, 1)
            self._sync()
            ms = (time.perf_counter() - t0) * 1000
            # the first image of a new size pays torch.compile and/or cuDNN autotuning: not model speed
            warmup = self.compile_events > c0 or tuple(degraded.shape) not in seen_shapes
            seen_shapes.add(tuple(degraded.shape))
            m = RestorationMetrics.compute(pred, clean, **proto)
            mi = RestorationMetrics.compute(degraded, clean, **proto)
            rec = {"idx": int(idx), "psnr": m["psnr"], "ssim": m["ssim"], "mae": m["mae"],
                   "in_psnr": mi["psnr"], "in_ssim": mi["ssim"], "in_mae": mi["mae"],
                   "gain": m["psnr"] - mi["psnr"], "ms": ms, "warmup": bool(warmup),
                   "H": int(clean.shape[-2]), "W": int(clean.shape[-1])}
            if use_lpips:
                lp = LPIPSMetric.compute(pred, clean)
                if lp is None:
                    use_lpips = False
                else:
                    rec["lpips"] = lp
                    rec["in_lpips"] = LPIPSMetric.compute(degraded, clean)
            rec.update(per_image_stats(degraded, pred, clean))
            records.append(rec)
            if idx < self.config.num_visualization_samples:
                arr = pred[0].permute(1, 2, 0).cpu().numpy()[..., ::-1]
                if dataset_name == "DPDD":
                    cv2.imwrite(os.path.join(ds_dir, f"restored_{idx:03d}.png"), (arr * 65535.0).round().astype(np.uint16))
                else:
                    cv2.imwrite(os.path.join(ds_dir, f"restored_{idx:03d}.png"), (arr * 255.0).round().astype(np.uint8))
        if DIST.ddp:
            import torch.distributed as dist
            parts = [None] * DIST.world
            dist.all_gather_object(parts, records)
            records = sorted([r for part in parts for r in part], key=lambda r: r["idx"])
        res = {k: float(np.mean([r[k] for r in records])) for k in ("psnr", "ssim", "mae", "in_psnr", "in_ssim", "gain")}
        steady = [r["ms"] for r in records if not r.get("warmup")]
        timed = steady or [r["ms"] for r in records]
        res["ms"] = float(np.median(timed))              # median steady-state time per image (end-to-end predict)
        res["ms_mean_incl_warmup"] = float(np.mean([r["ms"] for r in records]))
        res["ms_warmup_images"] = len(records) - len(steady)
        if records and "lpips" in records[0]:
            res["lpips"] = float(np.mean([r["lpips"] for r in records]))
            res["in_lpips"] = float(np.mean([r["in_lpips"] for r in records]))
        res["n"] = n
        res["protocol"] = proto
        res["records"] = records
        print(f"  {dataset_name}: PSNR {res['psnr']:.2f} dB (input {res['in_psnr']:.2f}) | SSIM {res['ssim']:.4f} | "
              f"MAE {res['mae']:.4f}" + (f" | LPIPS {res['lpips']:.4f}" if "lpips" in res else "") +
              f" | {res['ms']:.0f} ms/img (median, {res['ms_warmup_images']} warm-up img excluded) | n={n} | protocol {proto}")
        return res


# ==============================================================================
# 13. PUBLICATION FIGURES (styles follow the papers SINA-Net is compared with)
# ==============================================================================
# * zoom-inset comparisons: full image with coloured boxes + enlarged crops with per-crop
#   PSNR (Restormer CVPR'22 Fig. 4-7, NAFNet ECCV'22, FFTformer CVPR'23, EVSSM CVPR'25);
# * error maps with a SHARED colour scale for input and output (MPRNet CVPR'21 style);
# * 2-D log spectra + radial power profiles (DeepRFT / FFTformer frequency analyses);
# * effective receptive fields (Luo et al., NeurIPS'16; used by MambaIR ECCV'24 / MambaIRv2 CVPR'25);
# * PSNR-vs-MACs bubble charts (Restormer / NAFNet Fig. 1).
# Every figure is saved as a GRID (the multi-panel figure) and its panels as SINGLE images;
# restored images are also written pixel-exact (cv2, not re-rendered by matplotlib).
PALETTE = dict(ours="#C0392B", input="#7F8C8D", gt="#138D75", accent="#1F3A5F", good="#2E86AB", bad="#E4572E",
               grid="#E6E6E6", neutral="#95A5A6")
BOX_COLORS = ["#E63946", "#FFB703", "#06D6A0", "#118AB2"]
DEG_CLASS_COLORS = {"Motion blur": "#E76F51", "Defocus blur": "#2A9D8F", "Rain": "#457B9D", "Real noise": "#8D5A97",
                    "Clean (GT)": "#6C757D"}
TASK_OF_TEST = {"GoPro": "Motion blur", "HIDE": "Motion blur", "DPDD": "Defocus blur", "SIDD": "Real noise",
                "Rain100H": "Rain", "Rain100L": "Rain", "Test100": "Rain", "Test1200": "Rain", "Test2800": "Rain"}


def set_paper_style():
    plt.rcParams.update({
        "figure.dpi": 100, "savefig.dpi": 200, "savefig.bbox": "tight", "savefig.pad_inches": 0.06,
        "font.family": "DejaVu Sans", "font.size": 9, "axes.titlesize": 10, "axes.titleweight": "bold",
        "axes.labelsize": 9, "axes.spines.top": False, "axes.spines.right": False, "axes.grid": False,
        "legend.frameon": False, "legend.fontsize": 8, "xtick.labelsize": 8, "ytick.labelsize": 8,
        "figure.titlesize": 12, "figure.titleweight": "bold",
    })


def _mkdir(*parts) -> str:
    p = os.path.join(*parts)
    os.makedirs(p, exist_ok=True)
    return p


def _tight(fig):
    """tight_layout that leaves room for a figure title (suptitle)."""
    top = 0.94 if getattr(fig, "_suptitle", None) is not None else 1.0
    try:
        fig.tight_layout(rect=(0, 0, 1, top))
    except Exception:
        pass


def save_fig(fig, path: str, pdf: bool = False):
    fig.savefig(path)
    if pdf:
        fig.savefig(os.path.splitext(path)[0] + ".pdf")
    plt.close(fig)


def to_hwc(t: torch.Tensor) -> np.ndarray:
    t = t.detach().float().cpu().clamp(0, 1)
    if t.dim() == 4:
        t = t[0]
    return t.permute(1, 2, 0).numpy()


def save_png_exact(path: str, img: np.ndarray, bit16: bool = False):
    arr = np.clip(img, 0, 1)[..., ::-1]
    cv2.imwrite(path, (arr * 65535.0).round().astype(np.uint16) if bit16 else (arr * 255.0).round().astype(np.uint8))


def _luma(img: np.ndarray) -> np.ndarray:
    return 0.299 * img[..., 0] + 0.587 * img[..., 1] + 0.114 * img[..., 2]


def _crop(img: np.ndarray, box) -> np.ndarray:
    y, x, h, w = box
    return img[y:y + h, x:x + w]


def _psnr_np(a: np.ndarray, b: np.ndarray) -> float:
    return 10 * math.log10(1.0 / max(float(np.mean((np.clip(a, 0, 1) - b) ** 2)), 1e-12))


def draw_boxes(img: np.ndarray, boxes, colors, thickness: int) -> np.ndarray:
    out = np.ascontiguousarray((np.clip(img, 0, 1) * 255).round().astype(np.uint8))
    for (y, x, h, w), c in zip(boxes, colors):
        rgb = tuple(int(c.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
        cv2.rectangle(out, (x, y), (x + w - 1, y + h - 1), rgb, thickness)
    return out.astype(np.float32) / 255.0


def _enlarge(img: np.ndarray, target: int = 384) -> np.ndarray:
    f = max(1, int(round(target / max(img.shape[:2]))))
    return cv2.resize(img, None, fx=f, fy=f, interpolation=cv2.INTER_NEAREST)


def _strip_axes(ax):
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_visible(False)


def _color_spines(ax, color: str, lw: float = 3.0):
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_visible(True); s.set_edgecolor(color); s.set_linewidth(lw)


def bootstrap_ci(v: Sequence[float], n: int = 2000, alpha: float = 0.05, seed: int = 0) -> Tuple[float, float, float]:
    v = np.asarray(v, dtype=np.float64)
    if v.size == 0:
        return float("nan"), float("nan"), float("nan")
    if v.size == 1:
        return float(v[0]), float(v[0]), float(v[0])
    rng = np.random.default_rng(seed)
    means = v[rng.integers(0, v.size, size=(n, v.size))].mean(1)
    return float(v.mean()), float(np.quantile(means, alpha / 2)), float(np.quantile(means, 1 - alpha / 2))


def wilcoxon_p(diff: Sequence[float]) -> float:
    d = np.asarray(diff, dtype=np.float64)
    d = d[np.abs(d) > 1e-12]
    if d.size < 6:
        return float("nan")
    try:
        from scipy.stats import wilcoxon
        return float(wilcoxon(d).pvalue)
    except Exception:
        return float("nan")


PRACTICAL_DB = 0.01  # |effect| below this (dB) is treated as "no effect" even if statistically significant


def effect_verdict(mean: float, lo: float, hi: float, practical: float = PRACTICAL_DB) -> int:
    """-1 = significant and relevant DROP, +1 = significant and relevant GAIN, 0 = no effect."""
    if hi < 0 and mean < -practical:
        return -1
    if lo > 0 and mean > practical:
        return 1
    return 0


def plot_matrix(ax, M: np.ndarray, row_labels, col_labels, cell_text=None, cmap="Blues", vmin=None, vmax=None,
                center: Optional[float] = None, xlabel: str = "", ylabel: str = "", title: str = "",
                cbar_label: str = "", diag: bool = False):
    """Annotated heat-map used for every 'confusion-style' matrix (text colour adapts to the cell)."""
    M = np.asarray(M, dtype=np.float64)
    finite = M[np.isfinite(M)]
    vmin = float(finite.min()) if vmin is None and finite.size else (vmin if vmin is not None else 0.0)
    vmax = float(finite.max()) if vmax is None and finite.size else (vmax if vmax is not None else 1.0)
    if vmax <= vmin:
        vmax = vmin + 1e-6
    if center is not None:
        span = max(abs(vmin - center), abs(vmax - center), 1e-6)
        norm = mcolors.TwoSlopeNorm(vmin=center - span, vcenter=center, vmax=center + span)
    else:
        norm = mcolors.Normalize(vmin=vmin, vmax=vmax)
    cm = plt.get_cmap(cmap)
    im = ax.imshow(np.nan_to_num(M, nan=vmin), cmap=cm, norm=norm, aspect="auto")
    ax.set_xticks(range(len(col_labels))); ax.set_xticklabels(col_labels, rotation=30, ha="right")
    ax.set_yticks(range(len(row_labels))); ax.set_yticklabels(row_labels)
    ax.set_xlabel(xlabel); ax.set_ylabel(ylabel)
    if title:
        ax.set_title(title)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.set_xticks(np.arange(-.5, len(col_labels), 1), minor=True)
    ax.set_yticks(np.arange(-.5, len(row_labels), 1), minor=True)
    ax.grid(which="minor", color="white", linewidth=1.5)
    ax.tick_params(which="minor", length=0)
    for i in range(M.shape[0]):
        for j in range(M.shape[1]):
            txt = cell_text[i][j] if cell_text is not None else ("" if not np.isfinite(M[i, j]) else f"{M[i, j]:.2f}")
            if not txt:
                continue
            r, g, b, _ = cm(norm(M[i, j]) if np.isfinite(M[i, j]) else 0.0)
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            ax.text(j, i, txt, ha="center", va="center", fontsize=8, color="white" if lum < 0.5 else "#1a1a1a",
                    fontweight="bold" if (diag and i == j) else "normal")
    if diag:
        for i in range(min(M.shape)):
            ax.add_patch(Rectangle((i - .5, i - .5), 1, 1, fill=False, edgecolor="#111111", lw=1.6))
    cb = plt.colorbar(im, ax=ax, fraction=0.046, pad=0.03)
    if cbar_label:
        cb.set_label(cbar_label)
    cb.outline.set_visible(False)
    return im


# ------------------------------------------------------------------ zoom boxes
def local_mse_maps(deg: np.ndarray, pred: np.ndarray, gt: np.ndarray, k: int) -> Tuple[np.ndarray, np.ndarray]:
    ein = ((deg - gt) ** 2).mean(-1).astype(np.float32)
    eout = ((np.clip(pred, 0, 1) - gt) ** 2).mean(-1).astype(np.float32)
    f = lambda a: cv2.boxFilter(a, -1, (k, k), normalize=True, borderType=cv2.BORDER_REFLECT)
    return f(ein), f(eout)


def pick_boxes(score: np.ndarray, box: int, n: int) -> List[Tuple[int, int, int, int]]:
    """Greedy non-overlapping boxes centred on the maxima of `score` (fully inside the image)."""
    H, W = score.shape
    box = min(box, H, W)
    half = box // 2
    s = np.full_like(score, -np.inf, dtype=np.float64)
    s[half:H - box + half + 1, half:W - box + half + 1] = score[half:H - box + half + 1, half:W - box + half + 1]
    out = []
    for _ in range(n):
        i = int(np.argmax(s))
        if not np.isfinite(s.flat[i]):
            break
        cy, cx = divmod(i, W)
        out.append((cy - half, cx - half, box, box))
        s[max(0, cy - box):cy + box, max(0, cx - box):cx + box] = -np.inf
    return out


def auto_box_size(H: int, W: int, cfg: Config) -> int:
    b = cfg.zoom_box if cfg.zoom_box > 0 else int(np.clip(min(H, W) // 5, 32, 160))
    return max(16, b - b % 2)


# ------------------------------------------------------------------ per-image figures
def fig_zoom_comparison(deg, pred, gt, boxes, title: str, grid_path: str, single_dir: str, stem: str,
                        m_in: dict, m_out: dict, pdf: bool = False):
    """Paper-style comparison: the restored image with coloured boxes on the left, and for every
    box the enlarged Degraded / SINA-Net / Ground-truth crops with their local PSNR."""
    H, W = gt.shape[:2]
    nb = max(1, len(boxes))
    left_w = (W / H) * nb
    unit = 1.9
    fig = plt.figure(figsize=(unit * (left_w + 3) + 0.4, unit * nb + 0.9))
    gs = fig.add_gridspec(nb, 4, width_ratios=[left_w, 1, 1, 1], wspace=0.05, hspace=0.16)
    ax0 = fig.add_subplot(gs[:, 0])
    ax0.imshow(np.clip(pred, 0, 1), interpolation="antialiased")
    for (y, x, h, w), c in zip(boxes, BOX_COLORS):
        ax0.add_patch(Rectangle((x - .5, y - .5), w, h, fill=False, edgecolor=c, lw=2.2))
    _strip_axes(ax0)
    ax0.set_title(f"SINA-Net v4: {m_out['psnr']:.2f} dB / {m_out['ssim']:.4f}\n"
                  f"input: {m_in['psnr']:.2f} dB / {m_in['ssim']:.4f}", fontsize=9)
    cols = [("Degraded", deg), ("SINA-Net v4 (ours)", np.clip(pred, 0, 1)), ("Ground truth", gt)]
    for r, (box, c) in enumerate(zip(boxes, BOX_COLORS)):
        gcrop = _crop(gt, box)
        for j, (label, img) in enumerate(cols):
            ax = fig.add_subplot(gs[r, j + 1])
            crop = _crop(img, box)
            ax.imshow(crop, interpolation="nearest")
            _color_spines(ax, c, 2.6)
            if r == 0:
                ax.set_title(label, fontsize=9, color=PALETTE["ours"] if j == 1 else "#222222")
            ax.set_xlabel("reference" if j == 2 else f"{_psnr_np(crop, gcrop):.2f} dB", fontsize=8,
                          fontweight="bold" if j == 1 else "normal")
    fig.suptitle(title, y=1.0)
    save_fig(fig, grid_path, pdf)
    # singles: pixel-exact full images, boxed versions and enlarged crops
    th = max(2, int(round(max(H, W) / 320)))
    for label, img in (("degraded", deg), ("restored", pred), ("gt", gt)):
        save_png_exact(os.path.join(single_dir, f"{stem}_{label}.png"), img)
        save_png_exact(os.path.join(single_dir, f"{stem}_{label}_boxed.png"), draw_boxes(img, boxes, BOX_COLORS, th))
        for k, box in enumerate(boxes):
            save_png_exact(os.path.join(single_dir, f"{stem}_{label}_box{k}.png"), _enlarge(_crop(img, box)))


def fig_error_analysis(deg, pred, gt, k: int, title: str, path: str, single_dir: str, stem: str, rec: dict):
    """Where does the network help or hurt? |input error|, |output error| (shared scale),
    local PSNR gain map with the best (solid) and worst (dashed) boxes, error histograms / CDFs
    and the structure x severity gain matrix of this image."""
    err_in, err_out = np.abs(deg - gt).mean(-1), np.abs(np.clip(pred, 0, 1) - gt).mean(-1)
    lin, lout = local_mse_maps(deg, pred, gt, k)
    gain = 10 * np.log10((lin + 1e-8) / (lout + 1e-8))
    best = pick_boxes(lin - lout, k, 1)
    worst = pick_boxes(lout - lin, k, 1)
    vmax = max(1e-3, float(np.percentile(err_in, 99.5)))
    gl = float(np.clip(np.percentile(np.abs(gain), 99), 1.0, 15.0))
    fig, axes = plt.subplots(2, 3, figsize=(15, 8.6))
    panels = []
    im = axes[0, 0].imshow(err_in, cmap="inferno", vmin=0, vmax=vmax)
    axes[0, 0].set_title(f"|Degraded - GT|  (mean {err_in.mean():.4f})"); panels.append(("err_in", im))
    im = axes[0, 1].imshow(err_out, cmap="inferno", vmin=0, vmax=vmax)
    axes[0, 1].set_title(f"|Restored - GT|  (mean {err_out.mean():.4f})"); panels.append(("err_out", im))
    im = axes[0, 2].imshow(gain, cmap="RdBu", norm=mcolors.TwoSlopeNorm(vmin=-gl, vcenter=0.0, vmax=gl))
    axes[0, 2].set_title(f"Local PSNR gain ({k}x{k} window, dB)"); panels.append(("gain", im))
    for (y, x, h, w) in best:
        axes[0, 2].add_patch(Rectangle((x, y), w, h, fill=False, edgecolor="#0B6E4F", lw=2.2))
    for (y, x, h, w) in worst:
        axes[0, 2].add_patch(Rectangle((x, y), w, h, fill=False, edgecolor="#B00020", lw=2.2, ls="--"))
    for ax, (_, im) in zip(axes[0], panels):
        _strip_axes(ax)
        cb = plt.colorbar(im, ax=ax, fraction=0.035, pad=0.02); cb.outline.set_visible(False)
    bins = np.linspace(0, max(vmax * 1.5, 1e-3), 80)
    axes[1, 0].hist(err_in.ravel(), bins=bins, alpha=0.65, color=PALETTE["input"], label="Degraded")
    axes[1, 0].hist(err_out.ravel(), bins=bins, alpha=0.65, color=PALETTE["ours"], label="SINA-Net v4")
    axes[1, 0].set_yscale("log"); axes[1, 0].set_xlabel("per-pixel |error|"); axes[1, 0].set_ylabel("pixels")
    axes[1, 0].set_title("Error distribution"); axes[1, 0].legend()
    for e, c, lab in ((err_in, PALETTE["input"], "Degraded"), (err_out, PALETTE["ours"], "SINA-Net v4")):
        s = np.sort(e.ravel())
        idx = np.linspace(0, s.size - 1, min(2000, s.size)).astype(int)
        axes[1, 1].plot(s[idx], (idx + 1) / s.size, color=c, lw=2, label=lab)
    axes[1, 1].set_xscale("symlog", linthresh=1e-3); axes[1, 1].set_ylim(0, 1.01)
    axes[1, 1].set_xlabel("per-pixel |error|"); axes[1, 1].set_ylabel("fraction of pixels <= error")
    axes[1, 1].set_title(f"Error CDF  ({100 * rec.get('frac_improved', float('nan')):.1f}% of pixels improved)")
    axes[1, 1].legend(loc="lower right"); axes[1, 1].grid(alpha=0.3)
    cin, cout = np.asarray(rec["cells_in"]), np.asarray(rec["cells_out"])
    G = 10 * np.log10((cin + 1e-12) / (cout + 1e-12))
    plot_matrix(axes[1, 2], G, STRUCT_LABELS, SEVERITY_LABELS,
                cell_text=[[f"{G[i, j]:+.2f} dB" for j in range(3)] for i in range(3)], cmap="RdBu", center=0.0,
                xlabel="input degradation severity (tercile)", ylabel="local structure of GT (tercile)",
                title="PSNR gain by pixel class", cbar_label="dB")
    fig.suptitle(title)
    _tight(fig)
    save_fig(fig, path)
    for name, arr, cmap, norm in (("error_in", err_in, "inferno", mcolors.Normalize(0, vmax)),
                                  ("error_out", err_out, "inferno", mcolors.Normalize(0, vmax)),
                                  ("gain_map", gain, "RdBu", mcolors.TwoSlopeNorm(vmin=-gl, vcenter=0.0, vmax=gl))):
        rgba = plt.get_cmap(cmap)(norm(arr))[..., :3]
        save_png_exact(os.path.join(single_dir, f"{stem}_{name}.png"), rgba.astype(np.float32))
    return best, worst


def _log_spectrum(img: np.ndarray) -> np.ndarray:
    y = _luma(img).astype(np.float64)
    y = (y - y.mean()) * np.outer(np.hanning(y.shape[0]), np.hanning(y.shape[1]))
    return np.log10(np.abs(np.fft.fftshift(np.fft.fft2(y))) ** 2 + 1e-10)


def _radial_profile_np(img: np.ndarray, nb: int = 48) -> Tuple[np.ndarray, np.ndarray]:
    y = _luma(img).astype(np.float64)
    H, W = y.shape
    y = (y - y.mean()) * np.outer(np.hanning(H), np.hanning(W))
    P = np.abs(np.fft.fft2(y)) ** 2 / (H * W)
    fy, fx = np.meshgrid(np.fft.fftfreq(H), np.fft.fftfreq(W), indexing="ij")
    r = np.sqrt(fx ** 2 + fy ** 2)
    b = np.clip((r / 0.5 * nb).astype(int), 0, nb)
    s = np.bincount(b.ravel(), weights=P.ravel(), minlength=nb + 1)[:nb]
    c = np.bincount(b.ravel(), minlength=nb + 1)[:nb]
    return (np.arange(nb) + 0.5) * 0.5 / nb, s / np.maximum(c, 1)


def _band_centers(n: int = N_ERROR_BANDS) -> np.ndarray:
    return (np.arange(n) + 0.5) * 0.5 / n


def fig_spectrum(deg, pred, gt, rec: dict, title: str, path: str, single_dir: str, stem: str):
    """2-D log power spectra (shared scale), radial power profiles and the exact Parseval
    band decomposition of the error of this image (which frequencies the network restored)."""
    specs = [_log_spectrum(a) for a in (deg, np.clip(pred, 0, 1), gt)]
    lo, hi = np.percentile(specs[2], 1), np.percentile(specs[2], 99.8)
    fig = plt.figure(figsize=(15, 8.4))
    gs = fig.add_gridspec(2, 3, hspace=0.32, wspace=0.25)
    for j, (lab, s) in enumerate(zip(("Degraded", "SINA-Net v4", "Ground truth"), specs)):
        ax = fig.add_subplot(gs[0, j])
        im = ax.imshow(s, cmap="magma", vmin=lo, vmax=hi)
        _strip_axes(ax); ax.set_title(f"{lab}: log10 |FFT|^2")
        cb = plt.colorbar(im, ax=ax, fraction=0.035, pad=0.02); cb.outline.set_visible(False)
        rgba = plt.get_cmap("magma")(mcolors.Normalize(lo, hi)(s))[..., :3]
        save_png_exact(os.path.join(single_dir, f"{stem}_spectrum_{lab.split()[0].lower()}.png"), rgba.astype(np.float32))
    ax = fig.add_subplot(gs[1, 0])
    for img, c, lab in ((deg, PALETTE["input"], "Degraded"), (pred, PALETTE["ours"], "SINA-Net v4"), (gt, PALETTE["gt"], "Ground truth")):
        f, p = _radial_profile_np(np.clip(img, 0, 1))
        ax.loglog(f[1:], p[1:], color=c, lw=2, label=lab)
    ax.set_xlabel("spatial frequency (cycles / pixel)"); ax.set_ylabel("radially averaged power")
    ax.set_title("Radial power spectrum"); ax.legend(); ax.grid(alpha=0.3, which="both")
    fc = _band_centers()
    bi, bo = np.asarray(rec["band_in"]), np.asarray(rec["band_out"])
    ax = fig.add_subplot(gs[1, 1])
    wdt = 0.5 / N_ERROR_BANDS * 0.42
    ax.bar(fc - wdt / 2, bi, width=wdt, color=PALETTE["input"], label="input error")
    ax.bar(fc + wdt / 2, bo, width=wdt, color=PALETTE["ours"], label="output error")
    ax.set_yscale("log"); ax.set_xlabel("band centre (cycles / pixel; last band includes the corners)")
    ax.set_ylabel("MSE contribution"); ax.set_title("Error energy per band (exact, sums to MSE)"); ax.legend()
    ax = fig.add_subplot(gs[1, 2])
    g = 10 * np.log10((bi + 1e-14) / (bo + 1e-14))
    ax.bar(fc, g, width=0.5 / N_ERROR_BANDS * 0.8, color=[PALETTE["good"] if v >= 0 else PALETTE["bad"] for v in g])
    ax.axhline(0, color="#333333", lw=0.8)
    ax.axhline(10 * np.log10(bi.sum() / max(bo.sum(), 1e-14)), color=PALETTE["ours"], ls="--", lw=1.2, label="whole image")
    ax.set_xlabel("band centre (cycles / pixel)"); ax.set_ylabel("error reduction (dB)")
    ax.set_title("Frequency-resolved error reduction (FRER)"); ax.legend()
    fig.suptitle(title)
    save_fig(fig, path)


# ------------------------------------------------------------------ dataset-level figures
def _records_arrays(recs):
    return (np.array([r["in_psnr"] for r in recs]), np.array([r["psnr"] for r in recs]),
            np.array([r["gain"] for r in recs]))


def fig_dataset_dashboard(name: str, recs: List[dict], out_dir: str) -> dict:
    """Per-test-set dashboard (grid + singles): input vs output PSNR scatter, gain histogram with
    bootstrap CI, quality-transition 'confusion' matrix, structure x severity gain matrix and the
    dataset-level frequency-resolved error reduction. Returns the aggregate statistics."""
    pin, pout, gain = _records_arrays(recs)
    mean, lo, hi = bootstrap_ci(gain)
    improved = float(np.mean(gain > 0))
    # quality transition matrix (rows: input PSNR bin, cols: output PSNR bin, row-normalised)
    lo_e = math.floor(min(pin.min(), pout.min()))
    hi_e = math.ceil(max(pin.max(), pout.max()))
    nbin = int(np.clip(round((hi_e - lo_e) / 2.0), 3, 8))
    edges = np.linspace(lo_e, hi_e + 1e-9, nbin + 1)
    bi = np.clip(np.digitize(pin, edges) - 1, 0, nbin - 1)
    bo = np.clip(np.digitize(pout, edges) - 1, 0, nbin - 1)
    T = np.zeros((nbin, nbin))
    for a, b in zip(bi, bo):
        T[a, b] += 1
    rows = T.sum(1, keepdims=True)
    Tn = np.divide(T, rows, out=np.full_like(T, np.nan), where=rows > 0)
    labels = [f"{edges[i]:.0f}-{edges[i + 1]:.0f}" for i in range(nbin)]
    Ttxt = [[(f"{100 * Tn[i, j]:.0f}%\n({int(T[i, j])})" if T[i, j] > 0 else "") for j in range(nbin)] for i in range(nbin)]
    cin = np.sum([r["cells_in"] for r in recs], 0)
    cout = np.sum([r["cells_out"] for r in recs], 0)
    cn = np.sum([r["cells_n"] for r in recs], 0)
    cimp = np.sum([r["cells_improved"] for r in recs], 0)
    G = 10 * np.log10((cin + 1e-14) / (cout + 1e-14))
    Gtxt = [[f"{G[i, j]:+.2f} dB\n{100 * cimp[i, j] / max(cn[i, j], 1):.0f}% px better" for j in range(3)] for i in range(3)]
    band_in = np.sum([r["band_in"] for r in recs], 0)
    band_out = np.sum([r["band_out"] for r in recs], 0)
    frer = 10 * np.log10((band_in + 1e-14) / (band_out + 1e-14))

    def scatter(ax):
        lim = (min(pin.min(), pout.min()) - 1, max(pin.max(), pout.max()) + 1)
        gl = max(1e-3, float(np.percentile(np.abs(gain), 98)))
        sc = ax.scatter(pin, pout, c=gain, cmap="RdBu", norm=mcolors.TwoSlopeNorm(vmin=-gl, vcenter=0, vmax=gl),
                        s=26, alpha=0.85, edgecolor="white", linewidths=0.3)
        ax.plot(lim, lim, color="#444444", ls="--", lw=1, label="no change (y = x)")
        ax.plot(lim, (lim[0] + mean, lim[1] + mean), color=PALETTE["ours"], lw=1.2, label=f"mean gain {mean:+.2f} dB")
        ax.set_xlim(lim); ax.set_ylim(lim); ax.set_aspect("equal")
        ax.set_xlabel("input PSNR (dB)"); ax.set_ylabel("restored PSNR (dB)")
        ax.set_title(f"Per-image PSNR ({100 * improved:.0f}% of {len(recs)} images improved)")
        ax.legend(loc="upper left"); ax.grid(alpha=0.25)
        cb = plt.colorbar(sc, ax=ax, fraction=0.046); cb.set_label("gain (dB)"); cb.outline.set_visible(False)

    def hist(ax):
        ax.hist(gain, bins=min(40, max(8, len(gain) // 3)), color=PALETTE["good"], alpha=0.8, edgecolor="white")
        ax.axvspan(lo, hi, color=PALETTE["ours"], alpha=0.18, label=f"95% CI of mean [{lo:+.2f}, {hi:+.2f}]")
        ax.axvline(mean, color=PALETTE["ours"], lw=2, label=f"mean {mean:+.2f} dB")
        ax.axvline(float(np.median(gain)), color="#222222", ls=":", lw=1.5, label=f"median {np.median(gain):+.2f} dB")
        ax.axvline(0, color="#777777", lw=0.8)
        ax.set_xlabel("PSNR gain over the input (dB)"); ax.set_ylabel("images"); ax.set_title("Gain distribution")
        ax.legend()

    def trans(ax):
        plot_matrix(ax, Tn, labels, labels, Ttxt, cmap="Purples", vmin=0, vmax=1, diag=True,
                    xlabel="restored PSNR bin (dB)", ylabel="input PSNR bin (dB)",
                    title="Quality transition matrix (row-normalised)", cbar_label="fraction of row")

    def cells(ax):
        plot_matrix(ax, G, STRUCT_LABELS, SEVERITY_LABELS, Gtxt, cmap="RdBu", center=0.0,
                    xlabel="input degradation severity (tercile)", ylabel="local structure of GT (tercile)",
                    title="Where does it help? PSNR gain by pixel class", cbar_label="dB")

    def bands(ax):
        fc = _band_centers()
        ax.bar(fc, frer, width=0.5 / N_ERROR_BANDS * 0.8, color=[PALETTE["good"] if v >= 0 else PALETTE["bad"] for v in frer])
        ax2 = ax.twinx()
        share = band_in / max(band_in.sum(), 1e-14)
        ax2.plot(fc, 100 * share, color=PALETTE["input"], marker="o", ms=3, lw=1.2, label="share of input MSE")
        ax2.set_ylabel("share of input MSE (%)", color=PALETTE["input"]); ax2.spines["right"].set_visible(True)
        ax.axhline(0, color="#333333", lw=0.8)
        ax.set_xlabel("band centre (cycles / pixel)"); ax.set_ylabel("error reduction (dB)")
        ax.set_title("Frequency-resolved error reduction (FRER)")
        ax2.legend(loc="upper right")

    def text(ax):
        ax.axis("off")
        lines = [f"{name}: {len(recs)} images", "",
                 f"input PSNR     {pin.mean():7.2f} dB", f"restored PSNR  {pout.mean():7.2f} dB",
                 f"mean gain      {mean:+7.2f} dB  [{lo:+.2f}, {hi:+.2f}]",
                 f"median gain    {np.median(gain):+7.2f} dB", f"images improved {100 * improved:6.1f} %",
                 f"best image     #{recs[int(np.argmax(gain))]['idx']}  ({gain.max():+.2f} dB)",
                 f"worst image    #{recs[int(np.argmin(gain))]['idx']}  ({gain.min():+.2f} dB)",
                 f"low-freq FRER  {frer[:N_ERROR_BANDS // 4].mean():+6.2f} dB",
                 f"high-freq FRER {frer[N_ERROR_BANDS // 2:].mean():+6.2f} dB",
                 f"runtime        {np.median([r['ms'] for r in recs if not r.get('warmup')] or [r['ms'] for r in recs]):7.1f} ms / image (median)"]
        ax.text(0.02, 0.98, "\n".join(lines), va="top", ha="left", family="monospace", fontsize=10)

    painters = [("scatter", scatter, (6, 5.2)), ("gain_hist", hist, (6, 4.4)), ("transition_matrix", trans, (6.4, 5.4)),
                ("pixel_class_matrix", cells, (6.2, 4.8)), ("frer", bands, (6.4, 4.4)), ("summary", text, (6, 4.4))]
    fig, axes = plt.subplots(2, 3, figsize=(20, 12))
    for ax, (_, fn, _) in zip(axes.flat, painters):
        fn(ax)
    fig.suptitle(f"{name}: where and how much SINA-Net v4 restores")
    _tight(fig)
    save_fig(fig, os.path.join(out_dir, f"{name}_dashboard.png"))
    for key, fn, size in painters:
        f, a = plt.subplots(figsize=size)
        fn(a)
        _tight(f)
        save_fig(f, os.path.join(out_dir, f"{name}_{key}.png"))
    return {"n": len(recs), "mean_gain": mean, "gain_ci": (lo, hi), "median_gain": float(np.median(gain)),
            "frac_images_improved": improved, "frer": frer.tolist(), "cell_gain_db": G.tolist(),
            "transition": T.tolist(), "transition_edges": edges.tolist()}


def fig_gallery(items: List[Tuple[np.ndarray, np.ndarray, np.ndarray, str]], title: str, path: str):
    if not items:
        return
    n = len(items)
    fig, axes = plt.subplots(n, 3, figsize=(8.4, 2.8 * n + 0.6), squeeze=False)
    for i, (d, p, g, cap) in enumerate(items):
        for j, (img, lab) in enumerate(((d, "Degraded"), (p, "SINA-Net v4"), (g, "Ground truth"))):
            ax = axes[i, j]
            ax.imshow(np.clip(img, 0, 1), interpolation="antialiased")
            _strip_axes(ax)
            if i == 0:
                ax.set_title(lab, color=PALETTE["ours"] if j == 1 else "#222222")
            if j == 0:
                ax.set_ylabel(cap, fontsize=8, rotation=0, ha="right", va="center", labelpad=6)
                ax.yaxis.label.set_visible(True)
            if j == 1:
                ax.set_xlabel(f"{_psnr_np(p, g):.2f} dB (crop)", fontsize=8)
            if j == 0:
                ax.set_xlabel(f"{_psnr_np(d, g):.2f} dB (crop)", fontsize=8)
    fig.suptitle(title)
    _tight(fig)
    save_fig(fig, path)


def fig_cross_dataset(summary: Dict[str, dict], results: Dict[str, dict], out_dir: str):
    """Dumbbell (input -> restored PSNR) and mean gain with 95% bootstrap CI for every test set."""
    names = [n for n in summary if results.get(n, {}).get("records")]
    if not names:
        return
    names.sort(key=lambda n: summary[n]["mean_gain"])
    pin = [results[n]["in_psnr"] for n in names]
    pout = [results[n]["psnr"] for n in names]

    def dumbbell(ax):
        y = np.arange(len(names))
        for i in range(len(names)):
            ax.plot([pin[i], pout[i]], [y[i], y[i]], color="#BBBBBB", lw=3, zorder=1)
        ax.scatter(pin, y, color=PALETTE["input"], s=60, zorder=2, label="input")
        ax.scatter(pout, y, color=PALETTE["ours"], s=70, zorder=3, label="SINA-Net v4")
        ax.set_yticks(y); ax.set_yticklabels(names); ax.set_xlabel("PSNR (dB, benchmark protocol)")
        ax.set_title("Input -> restored PSNR per benchmark"); ax.legend(loc="lower right"); ax.grid(axis="x", alpha=0.3)

    def gains(ax):
        y = np.arange(len(names))
        m = [summary[n]["mean_gain"] for n in names]
        lo = [summary[n]["mean_gain"] - summary[n]["gain_ci"][0] for n in names]
        hi = [summary[n]["gain_ci"][1] - summary[n]["mean_gain"] for n in names]
        cols = [DEG_CLASS_COLORS.get(TASK_OF_TEST.get(n, ""), PALETTE["accent"]) for n in names]
        ax.barh(y, m, xerr=[lo, hi], color=cols, alpha=0.9, capsize=3)
        for i, n in enumerate(names):
            ax.text(m[i], y[i], f"  {m[i]:+.2f} dB | {100 * summary[n]['frac_images_improved']:.0f}% img",
                    va="center", fontsize=8)
        ax.axvline(0, color="#333333", lw=0.8)
        ax.set_yticks(y); ax.set_yticklabels(names); ax.set_xlabel("mean PSNR gain (dB), 95% bootstrap CI")
        ax.set_title("Where SINA-Net v4 performs best")

    fig, axes = plt.subplots(1, 2, figsize=(15, 0.55 * len(names) + 2.4))
    dumbbell(axes[0]); gains(axes[1])
    _tight(fig)
    save_fig(fig, os.path.join(out_dir, "cross_dataset_overview.png"))
    for key, fn in (("dumbbell", dumbbell), ("gain_ranking", gains)):
        f, a = plt.subplots(figsize=(7.5, 0.55 * len(names) + 2.2))
        fn(a)
        _tight(f)
        save_fig(f, os.path.join(out_dir, f"cross_dataset_{key}.png"))


def fig_training_curves(ckpt_dirs: Sequence[str], out_path: str) -> bool:
    """Loss terms, train PSNR / gain, LR and validation PSNR from the CSV logs."""
    tr = va = None
    for d in ckpt_dirs:
        if tr is None and os.path.isfile(os.path.join(d, "train_log.csv")):
            tr = os.path.join(d, "train_log.csv")
        if va is None and os.path.isfile(os.path.join(d, "val_log.csv")):
            va = os.path.join(d, "val_log.csv")
    if tr is None:
        return False

    def read(path):
        with open(path) as f:
            return list(csv.DictReader(f))

    rows = read(tr)
    if len(rows) < 2:
        return False
    it = np.array([float(r["iteration"]) for r in rows])

    def col(k):
        return np.array([float(r[k]) if r.get(k) not in (None, "") else np.nan for r in rows])

    def smooth(v, k=9):
        if len(v) < k:
            return v
        ker = np.ones(k) / k
        return np.convolve(np.nan_to_num(v, nan=np.nanmean(v)), ker, mode="same")

    fig, axes = plt.subplots(2, 2, figsize=(14, 8.5))
    ax = axes[0, 0]
    ax.plot(it, col("loss"), color="#CCCCCC", lw=0.8)
    ax.plot(it, smooth(col("loss")), color=PALETTE["accent"], lw=1.8, label="total")
    for k, c in (("char", "#E76F51"), ("freq", "#2A9D8F"), ("edge", "#8D5A97"), ("aux", "#E9C46A")):
        v = col(k)
        if np.isfinite(v).any():
            ax.plot(it, smooth(v), lw=1.2, color=c, label=k)
    ax.set_yscale("log"); ax.set_title("Training loss"); ax.set_xlabel("iteration"); ax.legend(); ax.grid(alpha=0.3)
    ax = axes[0, 1]
    ax.plot(it, smooth(col("psnr")), color=PALETTE["ours"], lw=1.8, label="restored (train patches)")
    ax.plot(it, smooth(col("in_psnr")), color=PALETTE["input"], lw=1.2, label="input")
    ax2 = ax.twinx(); ax2.spines["right"].set_visible(True)
    ax2.plot(it, smooth(col("gain")), color=PALETTE["good"], lw=1.2, ls="--", label="gain")
    ax2.set_ylabel("gain (dB)", color=PALETTE["good"])
    ax.set_title("Training PSNR"); ax.set_xlabel("iteration"); ax.set_ylabel("PSNR (dB)"); ax.legend(loc="lower right")
    ax.grid(alpha=0.3)
    ax = axes[1, 0]
    ax.plot(it, col("lr"), color=PALETTE["accent"], lw=1.6)
    patch = col("patch")
    ch = np.where(np.diff(patch) != 0)[0]
    for i in ch:
        ax.axvline(it[i + 1], color="#999999", ls=":", lw=1)
        ax.text(it[i + 1], np.nanmax(col("lr")), f" {int(patch[i + 1])}px",
                fontsize=7, va="top", color="#666666")
    ax.set_yscale("log"); ax.set_title("Learning rate (dotted: progressive patch size)"); ax.set_xlabel("iteration")
    ax.grid(alpha=0.3)
    ax = axes[1, 1]
    if va:
        vr = read(va)
        tasks = sorted({r["task"] for r in vr})
        for t in tasks:
            pts = [(float(r["iteration"]), float(r["psnr"])) for r in vr if r["task"] == t]
            if pts:
                x, y = zip(*pts)
                ax.plot(x, y, marker="o", ms=3, lw=1.5, color=DEG_CLASS_COLORS.get(TASK_OF_TEST.get(t, t), None), label=t)
                k = int(np.argmax(y))
                ax.scatter([x[k]], [y[k]], s=80, facecolor="none", edgecolor="#111111")
        ax.legend()
    ax.set_title("Validation PSNR (EMA, 256 px crops; circle = best)"); ax.set_xlabel("iteration"); ax.grid(alpha=0.3)
    fig.suptitle("SINA-Net v4 training curves")
    _tight(fig)
    save_fig(fig, out_path)
    return True


# ==============================================================================
# 13b. INTERPRETABILITY: attention (5 kinds), Wiener gains, coherence gates, ERF
# ==============================================================================
class InterpretabilityAnalyzer:
    """Runs the model in capture mode on a crop (signature taken from the FULL image, exactly as
    in inference) and renders:
      1. attention-peakedness atlas KL_n (layers x heads) and 2. temperature atlas T;
      3. attention FOOTPRINTS of three query pixels (best-gain, strongest edge, flattest) drawn
         at their true full-resolution sampling positions (dilation x level stride);
      4. mean attention DISTANCE per head (px) and 5. HOMEOSTASIS evidence: measured mean KL_n
         vs learned set point tau_h per head, and the attention-COLLAPSE rate (rows whose max
         weight > 0.9) with the learned temperature vs the T = 1 knock-out;
      6. Wiener gain maps H = S/(S+N) per SINA layer; 7. coherence skip-gate maps;
      8. effective receptive field of the RESIDUAL branch for the full model and knock-outs.
    Returns numeric statistics that feed the claims audit."""

    def __init__(self, config: Config, model: nn.Module, inferencer: "ModelInferencer"):
        self.cfg, self.model, self.inf = config, model, inferencer

    # ---------------------------------------------------------------- capture
    def _attn_layers(self):
        out = []
        for name, m in self.model.named_modules():
            if isinstance(m, KLDivergenceGuidedDiNA) and m.attn_kl is not None:
                tau = m.set_point()
                out.append(dict(name=name.replace(".attn", ""), kl=m.attn_kl[0].cpu().numpy(),
                                kl_after=m.attn_kl_after[0].cpu().numpy(),
                                toward=None if m.homeo_toward is None else m.homeo_toward.numpy(),
                                dev_b=None if m.homeo_dev_before is None else m.homeo_dev_before.numpy(),
                                dev_a=None if m.homeo_dev_after is None else m.homeo_dev_after.numpy(),
                                T=m.attn_temperature[0].cpu().numpy(), dist=m.attn_distance.numpy(),
                                maxw=m.attn_maxw[0].cpu().numpy(), q=m.attn_query, scale=m.level_scale,
                                dil=m.dilation, ks=m.kernel_size, offsets=m.offsets,
                                tau=None if tau is None else tau.cpu().numpy()))
        return out

    def _wiener_layers(self):
        return [(n.replace(".wiener", ""), m.H_opt[0].mean(0).cpu().numpy(), m.H_opt[0].cpu().numpy().ravel())
                for n, m in self.model.named_modules() if isinstance(m, CohenClassSpectralWienerUnit) and m.H_opt is not None]

    def _gates(self):
        return [(n, m.last_gate[0].mean(0).cpu().numpy(), float(m.last_gate[0].std(dim=(-2, -1)).mean()))
                for n, m in self.model.named_modules() if isinstance(m, SpectralCoherenceGatedFusion) and m.last_gate is not None]

    @torch.no_grad()
    def _forward_capture(self, crop: torch.Tensor, sig, queries, s: int):
        self.model.set_capture(True, queries=queries, full_hw=(s, s))
        try:
            with eager_mode(self.model):
                pred = self.model(crop, signature=sig).float()
            return pred, self._attn_layers(), self._wiener_layers(), self._gates()
        finally:
            self.model.set_capture(False)

    # ---------------------------------------------------------------- analysis
    def analyze(self, deg_full: torch.Tensor, gt_full: torch.Tensor, center: Tuple[int, int], out_dir: str,
                tag: str) -> dict:
        cfg = self.cfg
        H, W = deg_full.shape[-2:]
        s = int(min(cfg.attn_crop, H - H % 8, W - W % 8))
        if s < 64:
            return {}
        cy = int(np.clip(center[0] - s // 2, 0, H - s))
        cx = int(np.clip(center[1] - s // 2, 0, W - s))
        crop = deg_full[..., cy:cy + s, cx:cx + s]
        gcrop = gt_full[..., cy:cy + s, cx:cx + s]
        sig = self.inf._signature(deg_full)
        with torch.no_grad(), eager_mode(self.model):
            pred0 = self.model(crop, signature=sig).float()
        d_np, p_np, g_np = to_hwc(crop), to_hwc(pred0), to_hwc(gcrop)
        lin, lout = local_mse_maps(d_np, p_np, g_np, 9)
        m = 16
        inner = np.zeros_like(lin, dtype=bool); inner[m:s - m, m:s - m] = True
        gm = _sobel_mag(torch.from_numpy(_luma(g_np)).float().view(1, 1, s, s))[0, 0].numpy()
        gm_s = cv2.boxFilter(gm, -1, (9, 9))
        q_best = np.unravel_index(np.argmax(np.where(inner, lin - lout, -np.inf)), lin.shape)
        q_edge = np.unravel_index(np.argmax(np.where(inner, gm, -np.inf)), gm.shape)
        q_flat = np.unravel_index(np.argmin(np.where(inner, gm_s, np.inf)), gm.shape)
        queries = [tuple(int(v) for v in q) for q in (q_best, q_edge, q_flat)]
        qnames = ["best-gain pixel", "strongest edge", "flattest region"]
        _, layers, wl, gates = self._forward_capture(crop, sig, queries, s)
        # homeostasis knock-out: same crop, T = 1
        layers_off = []
        if layers and any(L["tau"] is not None for L in layers):
            with knockout(self.model, "no_homeostasis"):
                _, layers_off, _, _ = self._forward_capture(crop, sig, queries, s)
        stats = {"tag": tag}
        adir = _mkdir(out_dir, "attention")
        if layers:
            self._fig_atlas(layers, "kl", d_np, os.path.join(adir, f"{tag}_atlas_peakedness.png"), adir, tag)
            self._fig_atlas(layers, "T", d_np, os.path.join(adir, f"{tag}_atlas_temperature.png"), adir, tag)
            self._fig_footprints(layers, queries, qnames, d_np, os.path.join(adir, f"{tag}_footprints.png"), adir, tag)
            stats["attn_distance"] = self._fig_distance(layers, os.path.join(adir, f"{tag}_attention_distance.png"))
            stats.update(self._fig_homeostasis(layers, layers_off, os.path.join(adir, f"{tag}_homeostasis.png")))
        if wl:
            stats["wiener_mean_gain"] = self._fig_wiener(wl, d_np, os.path.join(_mkdir(out_dir, "wiener"), f"{tag}_wiener_gain.png"))
        if gates:
            stats["gate_spatial_std"] = self._fig_gates(gates, d_np, os.path.join(_mkdir(out_dir, "coherence"), f"{tag}_skip_gates.png"))
        if cfg.run_erf:
            stats["erf"] = self._erf(crop, sig, d_np, os.path.join(_mkdir(out_dir, "erf"), f"{tag}_erf.png"))
        save_png_exact(os.path.join(adir, f"{tag}_crop_degraded.png"), d_np)
        save_png_exact(os.path.join(adir, f"{tag}_crop_restored.png"), p_np)
        self.model.clear_capture()
        return stats

    # ---------------------------------------------------------------- figures
    def _fig_atlas(self, layers, key: str, img, path: str, single_dir: str, tag: str):
        heads = layers[0][key].shape[0]
        n = len(layers)
        fig, axes = plt.subplots(n, heads, figsize=(1.25 * heads + 1.6, 1.25 * n + 0.8), squeeze=False)
        if key == "kl":
            cmap, norm, lab = "viridis", mcolors.Normalize(0, 1), "KL_n (0 = uniform, 1 = one-hot)"
        else:
            cmap = "coolwarm"
            norm = mcolors.TwoSlopeNorm(vmin=0.25, vcenter=1.0, vmax=4.0)
            lab = "temperature T (<1 sharpens, >1 softens)"
        im = None
        for i, L in enumerate(layers):
            for h in range(heads):
                ax = axes[i, h]
                im = ax.imshow(L[key][h], cmap=cmap, norm=norm, interpolation="nearest")
                _strip_axes(ax)
                if i == 0:
                    ax.set_title(f"head {h}", fontsize=8)
                if h == 0:
                    ax.set_ylabel(f"{L['name']}\nd={L['dil']} x{L['scale']:.0f}", fontsize=7, rotation=0, ha="right",
                                  va="center", labelpad=4)
                    ax.yaxis.label.set_visible(True)
        cb = fig.colorbar(im, ax=axes.ravel().tolist(), fraction=0.02, pad=0.01)
        cb.set_label(lab); cb.outline.set_visible(False)
        fig.suptitle(("Attention peakedness KL_n" if key == "kl" else "Homeostatic temperature T") +
                     " per layer (rows) and head (columns)")
        save_fig(fig, path)
        sd = _mkdir(single_dir, f"{tag}_{key}_per_layer")
        for L in layers:
            f, ax = plt.subplots(1, heads + 1, figsize=(1.9 * (heads + 1), 2.1))
            ax[0].imshow(img); _strip_axes(ax[0]); ax[0].set_title("input crop", fontsize=8)
            for h in range(heads):
                ax[h + 1].imshow(L[key][h], cmap=cmap, norm=norm); _strip_axes(ax[h + 1])
                ax[h + 1].set_title(f"h{h}" + (f" tau={L['tau'][h]:.2f}" if (key == "kl" and L["tau"] is not None) else ""),
                                    fontsize=7)
            f.suptitle(f"{L['name']} ({'KL_n' if key == 'kl' else 'T'})", fontsize=9)
            save_fig(f, os.path.join(sd, f"{L['name'].replace('.', '_')}.png"))

    def _fig_footprints(self, layers, queries, qnames, img, path, single_dir, tag):
        # one representative layer per (level scale, dilation)
        seen, sel = set(), []
        for L in layers:
            k = (round(L["scale"]), L["dil"])
            if k not in seen:
                seen.add(k); sel.append(L)
        sel = sel[:6]
        gray = np.repeat(_luma(img)[..., None], 3, -1) * 0.75
        fig, axes = plt.subplots(len(queries), len(sel), figsize=(2.9 * len(sel), 3.0 * len(queries)), squeeze=False)
        for r, (q, qn) in enumerate(zip(queries, qnames)):
            for c, L in enumerate(sel):
                ax = axes[r, c]
                w = L["q"][r][2][0].float().mean(0).numpy()  # (K2,) mean over heads
                self._draw_footprint(fig, ax, gray, L, q, w)
                if r == 0:
                    ax.set_title(f"{L['name']}\nkernel {L['ks']}x{L['ks']}, step {L['dil'] * L['scale']:.0f}px", fontsize=8)
                if c == 0:
                    ax.set_ylabel(qn, fontsize=9)
                    ax.yaxis.label.set_visible(True)
        fig.suptitle("Attention footprints: where each query reads from (zoomed on its neighbourhood; "
                     "dot area / colour = weight, mean over heads)")
        _tight(fig)
        save_fig(fig, path)
        # per-head singles for the best-gain query at every selected layer
        sd = _mkdir(single_dir, f"{tag}_footprints_per_head")
        for L in sel:
            heads = L["q"][0][2].shape[1]
            f, ax = plt.subplots(1, heads, figsize=(2.2 * heads, 2.4), squeeze=False)
            for h in range(heads):
                a = ax[0, h]
                self._draw_footprint(f, a, gray, L, queries[0], L["q"][0][2][0, h].float().numpy())
                a.set_title(f"head {h}", fontsize=8)
            f.suptitle(f"{L['name']}: per-head footprint of the best-gain pixel", fontsize=9)
            save_fig(f, os.path.join(sd, f"{L['name'].replace('.', '_')}.png"))

    @staticmethod
    def _draw_footprint(fig, ax, gray, L, q, w):
        """Zoomed on the query's k x k dilated neighbourhood; marker AREA ~ attention weight and the
        largest marker spans 90% of the sampling step, so neighbouring samples never overlap."""
        step = L["dil"] * L["scale"]
        half = (L["ks"] // 2 + 1.5) * step
        oy = np.array([o[0] for o in L["offsets"]]) * L["scale"]
        ox = np.array([o[1] for o in L["offsets"]]) * L["scale"]
        ys, xs = q[0] + oy, q[1] + ox
        ok = (ys >= 0) & (ys < gray.shape[0]) & (xs >= 0) & (xs < gray.shape[1])
        ax.imshow(gray, interpolation="nearest")
        ax.set_xlim(q[1] - half, q[1] + half); ax.set_ylim(q[0] + half, q[0] - half)
        ax_pt = ax.get_position().width * fig.get_figwidth() * 72
        dmax = 0.9 * step * ax_pt / (2 * half)
        wn = w / max(float(w.max()), 1e-9)
        ax.scatter(xs[ok], ys[ok], s=(dmax * np.sqrt(np.clip(wn[ok], 0.02, 1))) ** 2, c=w[ok], cmap="magma",
                   vmin=0, vmax=max(float(w.max()), 1e-9), edgecolor="white", linewidth=0.4, alpha=0.95)
        ax.scatter([q[1]], [q[0]], marker="*", s=min(160, 0.6 * dmax ** 2 + 40), c="#00E5FF", edgecolor="black", linewidth=0.6)
        _strip_axes(ax)

    def _fig_distance(self, layers, path) -> dict:
        D = np.stack([L["dist"] for L in layers])  # (layers, heads) px
        fig, ax = plt.subplots(figsize=(1.0 * D.shape[1] + 3.2, 0.42 * D.shape[0] + 1.8))
        plot_matrix(ax, D, [f"{L['name']} (d={L['dil']}, x{L['scale']:.0f})" for L in layers],
                    [f"h{h}" for h in range(D.shape[1])],
                    [[f"{v:.1f}" for v in row] for row in D], cmap="YlGnBu",
                    xlabel="head", ylabel="SINA layer", title="Mean attention distance (full-resolution pixels)",
                    cbar_label="px")
        _tight(fig)
        save_fig(fig, path)
        return {L["name"]: float(L["dist"].mean()) for L in layers}

    def _fig_homeostasis(self, layers, layers_off, path) -> dict:
        have_tau = [L for L in layers if L["tau"] is not None]
        stats = {}
        fig, axes = plt.subplots(1, 3, figsize=(17, 4.8))
        ax = axes[0]
        if have_tau:
            taus = np.concatenate([L["tau"] for L in have_tau])
            before = np.concatenate([L["kl"].reshape(L["kl"].shape[0], -1).mean(1) for L in have_tau])
            after = np.concatenate([L["kl_after"].reshape(L["kl_after"].shape[0], -1).mean(1) for L in have_tau])
            lev = np.concatenate([[L["scale"]] * len(L["tau"]) for L in have_tau])
            for t, b, a in zip(taus, before, after):
                ax.annotate("", xy=(t, a), xytext=(t, b), arrowprops=dict(arrowstyle="->", color="#888888", lw=0.8))
            ax.scatter(taus, before, facecolor="none", edgecolor="#555555", s=30, label="before T (plain softmax)")
            sc = ax.scatter(taus, after, c=np.log2(lev), cmap="viridis", s=38, edgecolor="white", label="after T (model)")
            ax.plot((0, 1), (0, 1), ls="--", color="#555555", lw=1, label="entropy = set point")
            ax.set_xlim(0, 1); ax.set_ylim(0, 1)
            ax.set_xlabel("learned set point tau_h"); ax.set_ylabel("mean KL_n of the head")
            toward = float(np.mean(np.concatenate([L["toward"] for L in have_tau])))
            dev_b = float(np.mean(np.concatenate([L["dev_b"] for L in have_tau])))
            dev_a = float(np.mean(np.concatenate([L["dev_a"] for L in have_tau])))
            ax.set_title(f"T moves {100 * toward:.0f}% of rows toward tau\n|KL_n - tau|: {dev_b:.3f} -> {dev_a:.3f}")
            cb = plt.colorbar(sc, ax=ax, fraction=0.046); cb.set_label("log2(level stride)")
            ax.legend(loc="upper left", fontsize=7)
            stats.update(homeo_toward=toward, homeo_dev_before=dev_b, homeo_dev_after=dev_a,
                         homeo_median_abs_dev=float(np.median(np.abs(after - taus))))
        else:
            ax.text(0.5, 0.5, "no homeostasis parameters\n(ablation model)", ha="center", va="center"); ax.axis("off")
        ax = axes[1]
        data = [L["kl_after"].ravel() for L in layers]
        bp = ax.boxplot(data, showfliers=False, patch_artist=True, widths=0.6)
        for b in bp["boxes"]:
            b.set_facecolor("#A8DADC"); b.set_edgecolor("#1D3557")
        for i, L in enumerate(layers):
            if L["tau"] is not None:
                ax.scatter(np.full(len(L["tau"]), i + 1) + np.linspace(-0.2, 0.2, len(L["tau"])), L["tau"],
                           marker="_", s=90, color=PALETTE["ours"], zorder=3)
        ax.set_xticks(range(1, len(layers) + 1)); ax.set_xticklabels([L["name"] for L in layers], rotation=60, ha="right", fontsize=7)
        ax.set_ylabel("KL_n after T"); ax.set_ylim(0, 1); ax.set_title("Operating entropy per layer (red ticks: set points)")
        ax = axes[2]
        on = [float((L["maxw"] > 0.9).mean()) for L in layers]
        x = np.arange(len(layers))
        ax.bar(x - 0.2, [100 * v for v in on], width=0.4, color=PALETTE["good"], label="learned T (model)")
        stats["collapse_rate_on"] = float(np.mean(on))
        top = max(on)
        if layers_off:
            off = [float((L["maxw"] > 0.9).mean()) for L in layers_off]
            ax.bar(x + 0.2, [100 * v for v in off], width=0.4, color=PALETTE["bad"], label="knock-out T = 1")
            stats["collapse_rate_off"] = float(np.mean(off))
            top = max(top, max(off))
        ax.set_ylim(0, max(1.0, 125 * top))
        ax.set_xticks(x); ax.set_xticklabels([L["name"] for L in layers], rotation=60, ha="right", fontsize=7)
        ax.set_ylabel("% rows with max weight > 0.9"); ax.set_title("Attention collapse rate"); ax.legend()
        fig.suptitle("Entropy homeostasis: set points, operating entropy and collapse")
        _tight(fig)
        save_fig(fig, path)
        return stats

    def _fig_wiener(self, wl, img, path) -> dict:
        n = len(wl)
        cols = min(6, n)
        rows = math.ceil(n / cols)
        fig = plt.figure(figsize=(2.6 * cols, 2.6 * rows + 3.2))
        gs = fig.add_gridspec(rows + 1, cols, height_ratios=[1] * rows + [1.15], hspace=0.35)
        s = img.shape[0]
        for i, (name, Hm, _) in enumerate(wl):
            ax = fig.add_subplot(gs[i // cols, i % cols])
            ax.imshow(_luma(img), cmap="gray")
            ax.imshow(cv2.resize(Hm, (s, s), interpolation=cv2.INTER_NEAREST), cmap="hot", vmin=0, vmax=1, alpha=0.65)
            _strip_axes(ax); ax.set_title(f"{name}  mean {Hm.mean():.2f}", fontsize=8)
        ax = fig.add_subplot(gs[rows, :])
        samples = [v[np.linspace(0, v.size - 1, min(v.size, 20000)).astype(int)] for _, _, v in wl]
        vp = ax.violinplot(samples, showmedians=True, widths=0.8)
        for b in vp["bodies"]:
            b.set_facecolor("#F4A261"); b.set_alpha(0.7)
        ax.set_xticks(range(1, n + 1)); ax.set_xticklabels([w[0] for w in wl], rotation=45, ha="right", fontsize=7)
        ax.set_ylabel("H = S / (S + N)"); ax.set_ylim(0, 1); ax.set_title("Wiener gain distribution per SINA layer")
        fig.suptitle("Cohen-class spectral Wiener gains (overlay on the input crop)")
        save_fig(fig, path)
        return {name: float(Hm.mean()) for name, Hm, _ in wl}

    def _fig_gates(self, gates, img, path) -> dict:
        n = len(gates)
        fig, axes = plt.subplots(2, n, figsize=(4.2 * n, 7.6), squeeze=False)
        s = img.shape[0]
        for j, (name, G, std) in enumerate(gates):
            ax = axes[0, j]
            ax.imshow(_luma(img), cmap="gray")
            im = ax.imshow(cv2.resize(G, (s, s), interpolation=cv2.INTER_LINEAR), cmap="plasma", vmin=0, vmax=1, alpha=0.7)
            _strip_axes(ax); ax.set_title(f"{name} (stride {s // G.shape[0]}): spatial std {std:.3f}", fontsize=9)
            axes[1, j].hist(G.ravel(), bins=50, range=(0, 1), color="#7B2CBF", alpha=0.85)
            axes[1, j].set_xlabel("gate value"); axes[1, j].set_title("distribution", fontsize=9)
        cb = fig.colorbar(im, ax=axes[0].tolist(), fraction=0.02); cb.outline.set_visible(False)
        fig.suptitle("Spectral-coherence skip gates: which encoder details are passed to the decoder")
        save_fig(fig, path)
        return {name: std for name, _, std in gates}

    def _erf(self, crop: torch.Tensor, sig, img, path) -> dict:
        """Effective receptive field (Luo et al., 2016) of the RESIDUAL branch (output - input):
        |d (out - x)[centre] / d x|, i.e. without the trivial identity path of the global skip."""
        variants = [("full model", None)]
        if any(isinstance(m, KLDivergenceGuidedDiNA) and m.homeostasis for m in self.model.modules()):
            variants.append(("T = 1 knock-out", "no_homeostasis"))
        if any(isinstance(m, CohenClassSpectralWienerUnit) for m in self.model.modules()):
            variants.append(("no-Wiener knock-out", "no_wiener"))
        s = crop.shape[-1]
        c = s // 2
        maps, radii = {}, {}
        for lab, ko in variants:
            x = crop.detach().clone().float().requires_grad_(True)
            with torch.enable_grad(), eager_mode(self.model), knockout(self.model, ko):
                out = self.model(x, signature=sig)
                obj = (out - x)[:, :, c, c].sum()
                g, = torch.autograd.grad(obj, x)
            m = g.abs().sum(1)[0].cpu().numpy()
            maps[lab] = m
            yy, xx = np.mgrid[:s, :s]
            r = np.sqrt((yy - c) ** 2 + (xx - c) ** 2).ravel()
            order = np.argsort(r)
            cm = np.cumsum(m.ravel()[order]) / max(m.sum(), 1e-12)
            radii[lab] = (float(r[order][np.searchsorted(cm, 0.5)]), float(r[order][min(np.searchsorted(cm, 0.9), r.size - 1)]),
                          r[order], cm)
        fig, axes = plt.subplots(1, len(variants) + 1, figsize=(4.4 * (len(variants) + 1), 4.3))
        for ax, (lab, m) in zip(axes, maps.items()):
            v = np.log10(m / max(m.max(), 1e-12) + 1e-6)
            ax.imshow(v, cmap="inferno", vmin=-4, vmax=0)
            r50, r90 = radii[lab][:2]
            for rr, ls in ((r50, "-"), (r90, "--")):
                ax.add_patch(plt.Circle((c, c), rr, fill=False, color="#00E5FF", lw=1.2, ls=ls))
            _strip_axes(ax); ax.set_title(f"{lab}\nr50 = {r50:.0f}px, r90 = {r90:.0f}px", fontsize=9)
        ax = axes[-1]
        for lab, col in zip(maps, (PALETTE["ours"], PALETTE["good"], PALETTE["bad"])):
            ax.plot(radii[lab][2], radii[lab][3], color=col, lw=2, label=lab)
        ax.axhline(0.5, color="#999999", lw=0.7); ax.axhline(0.9, color="#999999", lw=0.7, ls="--")
        ax.set_xlabel("distance from the output pixel (px)"); ax.set_ylabel("cumulative |gradient| mass")
        ax.set_title("ERF mass vs radius"); ax.legend(loc="lower right"); ax.grid(alpha=0.3)
        fig.suptitle("Effective receptive field of the restoration residual (log10 |grad|)")
        _tight(fig)
        save_fig(fig, path)
        return {lab: {"r50": v[0], "r90": v[1]} for lab, v in radii.items()}


# ==============================================================================
# 13c. DEGRADATION-SIGNATURE PROBE (the 'confusion matrices' of SINA-Net)
# ==============================================================================
# Does the conditioning pathway really know WHICH degradation it is looking at? Two linear
# probes (multinomial logistic regression) are fitted on TRAIN-split images and scored on
# held-out TEST-split images of every dataset present on Drive:
#   (a) on the analytic Welch signature (no learning involved), and
#   (b) on the learned 128-d conditioner embedding of the trained model.
# Classes: motion blur (GoPro/HIDE), defocus blur (DPDD), rain (Rain13K), real noise (SIDD) and
# clean ground-truth images. Confusion matrices are row-normalised with raw counts.
PROBE_CLASSES = [
    ("Motion blur", [("GoPro", "train")], [("GoPro", "test"), ("HIDE", "test")]),
    ("Defocus blur", [("DPDD", "train")], [("DPDD", "test")]),
    ("Rain", [("Rain13K", "train")], [("Rain13K", "test")]),
    ("Real noise", [("SIDD", "train")], [("SIDD", "test")]),
]
_TASK_PATH_ATTR = {"GoPro": "path_gopro", "HIDE": "path_hide", "DPDD": "path_dpdd", "Rain13K": "path_rain13k",
                   "SIDD": "path_sidd"}


def _probe_pairs(cfg: Config, task: str, split: str) -> Tuple[List, Optional[Tuple[np.ndarray, np.ndarray]]]:
    if task == "SIDD" and split == "test":
        blocks = load_sidd_validation_blocks(cfg.path_sidd_val, cfg.search_roots)
        if blocks is not None:
            return [], blocks
    root = getattr(cfg, _TASK_PATH_ATTR[task])
    hold = 0.0 if (task == "SIDD" and load_sidd_validation_blocks(cfg.path_sidd_val, ()) is not None) else cfg.sidd_holdout_fraction
    try:
        pairs, _ = discover_task_pairs(task, root, split, seed=cfg.seed, sidd_holdout=hold)
    except Exception:
        pairs = []
    return pairs, None


def _even(n_total: int, k: int) -> List[int]:
    if n_total <= 0:
        return []
    return sorted(set(np.linspace(0, n_total - 1, num=min(k, n_total)).astype(int).tolist()))


class DegradationProbe:
    def __init__(self, config: Config, model: nn.Module):
        self.cfg, self.model = config, model
        self.dev = torch.device(config.device)

    @torch.no_grad()
    def _features(self, img: np.ndarray) -> Tuple[np.ndarray, Optional[np.ndarray], Optional[np.ndarray]]:
        x = torch.from_numpy(np.ascontiguousarray(img.transpose(2, 0, 1))).unsqueeze(0).to(self.dev)
        sig = self.model.compute_signature(x)
        cond = getattr(self.model, "degradation_conditioner", None)
        if cond is None:
            return sig[0].cpu().numpy(), None, None
        h = cond.embed(sig)
        enc = [hd(h)[0] for hd in cond.enc_heads]
        dec = [hd(h)[0] for hd in cond.dec_heads]
        film = []
        for gb in enc + dec:
            C = gb.numel() // 2
            film += [float(gb[:C].abs().mean()), float(gb[C:].abs().mean())]
        return sig[0].cpu().numpy(), h[0].cpu().numpy(), np.array(film)

    def _collect(self, specs, k: int, use_gt: bool = False):
        feats = []
        for task, split in specs:
            pairs, arrays = _probe_pairs(self.cfg, task, split)
            if arrays is not None:
                for i in _even(len(arrays[0]), k):
                    img = (arrays[1] if use_gt else arrays[0])[i].astype(np.float32) / 255.0
                    feats.append(self._features(img))
            elif pairs:
                for i in _even(len(pairs), k):
                    try:
                        img = read_image(pairs[i][1] if use_gt else pairs[i][0])
                    except Exception:
                        continue
                    feats.append(self._features(img))
        return feats

    def run(self, out_dir: str) -> dict:
        cfg = self.cfg
        k = cfg.probe_max_per_class
        train, test, labels = [], [], []
        gt_train, gt_test = [], []
        for name, tr_specs, te_specs in PROBE_CLASSES:
            tr = self._collect(tr_specs, k)
            te = self._collect(te_specs, k)
            if len(tr) >= 3 and len(te) >= 2:
                labels.append(name)
                train.append(tr); test.append(te)
                gt_train += self._collect(tr_specs, max(2, k // len(PROBE_CLASSES)), use_gt=True)
                gt_test += self._collect(te_specs, max(2, k // len(PROBE_CLASSES)), use_gt=True)
        if len(labels) >= 1 and len(gt_train) >= 3 and len(gt_test) >= 2:
            labels.append("Clean (GT)")
            train.append(gt_train); test.append(gt_test)
        if len(labels) < 2:
            print("  degradation probe skipped: fewer than two degradation types are available on Drive.")
            return {}
        res = {"classes": labels, "n_train": [len(t) for t in train], "n_test": [len(t) for t in test]}
        pdir = _mkdir(out_dir, "degradation_probe")
        kinds = [("signature", 0, "analytic Welch signature (no learning)")]
        if train[0][0][1] is not None:
            kinds.append(("embedding", 1, "learned conditioner embedding"))
        panels = []
        for key, j, desc in kinds:
            Xtr = np.stack([f[j] for cls in train for f in cls]); ytr = np.concatenate([[i] * len(c) for i, c in enumerate(train)])
            Xte = np.stack([f[j] for cls in test for f in cls]); yte = np.concatenate([[i] * len(c) for i, c in enumerate(test)])
            pred = self._fit_predict(Xtr, ytr, Xte)
            cm = np.zeros((len(labels), len(labels)), dtype=int)
            for a, b in zip(yte, pred):
                cm[a, b] += 1
            acc = float((pred == yte).mean())
            recall = cm.diagonal() / np.maximum(cm.sum(1), 1)
            prec = cm.diagonal() / np.maximum(cm.sum(0), 1)
            f1 = np.where(prec + recall > 0, 2 * prec * recall / np.maximum(prec + recall, 1e-12), 0.0)
            res[key] = {"accuracy": acc, "balanced_accuracy": float(recall.mean()), "macro_f1": float(f1.mean()),
                        "confusion": cm.tolist(), "chance": 1.0 / len(labels)}
            panels.append((key, desc, cm, res[key]))
            if key == "embedding":
                self._fig_scatter(Xte, yte, labels, os.path.join(pdir, "embedding_pca.png"))
        self._fig_confusions(panels, labels, pdir)
        self._fig_roses(train, labels, os.path.join(pdir, "signature_fingerprints.png"))
        if train[0][0][2] is not None:
            self._fig_film(train, labels, os.path.join(pdir, "film_modulation.png"))
        with open(os.path.join(pdir, "probe_results.json"), "w") as f:
            json.dump(res, f, indent=1)
        return res

    @staticmethod
    def _fit_predict(Xtr, ytr, Xte) -> np.ndarray:
        mu, sd = Xtr.mean(0), Xtr.std(0) + 1e-6
        A, B = (Xtr - mu) / sd, (Xte - mu) / sd
        try:
            from sklearn.linear_model import LogisticRegression
            clf = LogisticRegression(max_iter=5000, C=1.0, class_weight="balanced")
            clf.fit(A, ytr)
            return clf.predict(B)
        except Exception:  # nearest class centroid fallback
            cents = np.stack([A[ytr == c].mean(0) for c in np.unique(ytr)])
            return np.unique(ytr)[np.argmin(((B[:, None, :] - cents[None]) ** 2).sum(-1), 1)]

    def _fig_confusions(self, panels, labels, pdir):
        def draw(ax, key, desc, cm, r):
            rows = cm.sum(1, keepdims=True)
            cmn = np.divide(cm, rows, out=np.zeros_like(cm, dtype=float), where=rows > 0)
            txt = [[f"{100 * cmn[i, j]:.0f}%\n({cm[i, j]})" if cm[i, j] else "" for j in range(len(labels))]
                   for i in range(len(labels))]
            plot_matrix(ax, cmn, labels, labels, txt, cmap="Blues", vmin=0, vmax=1, diag=True,
                        xlabel="predicted degradation", ylabel="true degradation",
                        title=f"{desc}\nacc {100 * r['accuracy']:.1f}% | bal. acc {100 * r['balanced_accuracy']:.1f}% | "
                              f"macro-F1 {r['macro_f1']:.3f} | chance {100 * r['chance']:.0f}%",
                        cbar_label="fraction of true class")
        fig, axes = plt.subplots(1, len(panels), figsize=(7.2 * len(panels), 6.2), squeeze=False)
        for ax, p in zip(axes[0], panels):
            draw(ax, *p)
        fig.suptitle("Linear probes on held-out test images: does SINA-Net recognise the degradation?")
        _tight(fig)
        save_fig(fig, os.path.join(pdir, "confusion_matrices.png"))
        for p in panels:
            f, a = plt.subplots(figsize=(7.2, 6.2))
            draw(a, *p)
            _tight(f)
            save_fig(f, os.path.join(pdir, f"confusion_{p[0]}.png"))

    def _fig_scatter(self, X, y, labels, path):
        Xc = X - X.mean(0)
        U, S, Vt = np.linalg.svd(Xc, full_matrices=False)
        Z = Xc @ Vt[:2].T
        ev = (S ** 2) / max((S ** 2).sum(), 1e-12)
        fig, ax = plt.subplots(figsize=(6.8, 5.6))
        for i, lab in enumerate(labels):
            m = y == i
            ax.scatter(Z[m, 0], Z[m, 1], s=22, alpha=0.8, color=DEG_CLASS_COLORS.get(lab, None), label=lab, edgecolor="white", lw=0.3)
            if m.any():
                ax.scatter(Z[m, 0].mean(), Z[m, 1].mean(), s=220, marker="X", color=DEG_CLASS_COLORS.get(lab, None), edgecolor="black")
        ax.set_xlabel(f"PC1 ({100 * ev[0]:.0f}% var.)"); ax.set_ylabel(f"PC2 ({100 * ev[1]:.0f}% var.)")
        ax.set_title("Learned degradation embedding of test images (PCA; X = class mean)")
        ax.legend(loc="best"); ax.grid(alpha=0.25)
        _tight(fig)
        save_fig(fig, path)

    def _fig_roses(self, train, labels, path):
        nr, na = self.cfg.sig_radial_bins, self.cfg.sig_angular_bins
        n = len(labels)
        fig = plt.figure(figsize=(3.6 * n, 7.4))
        means = [np.stack([f[0] for f in cls]).mean(0) for cls in train]
        allv = np.concatenate([m[:nr * na] for m in means])
        vmin, vmax = np.percentile(allv, 2), np.percentile(allv, 98)
        th = np.linspace(0, 2 * np.pi, 2 * na + 1)
        rr = np.linspace(0, 0.5, nr + 1)
        for i, (lab, m) in enumerate(zip(labels, means)):
            ax = fig.add_subplot(2, n, i + 1, projection="polar")
            C = m[:nr * na].reshape(nr, na)
            pm = ax.pcolormesh(th, rr, np.concatenate([C, C], 1), cmap="cividis", vmin=vmin, vmax=vmax, shading="flat")
            ax.set_yticklabels([]); ax.set_xticklabels([]); ax.grid(color="white", alpha=0.25, lw=0.6)
            if i == n - 1:
                cb = fig.colorbar(pm, ax=ax, fraction=0.046, pad=0.08); cb.set_label("centred log-power"); cb.outline.set_visible(False)
            ax.set_title(f"{lab}\nslope {m[-2]:.2f} | aniso {m[-1]:.3f}", fontsize=9, color=DEG_CLASS_COLORS.get(lab, "#222"))
        ax = fig.add_subplot(2, 1, 2)
        fc = (np.arange(nr) + 0.5) * 0.5 / nr
        for lab, m in zip(labels, means):
            ax.plot(fc, m[:nr * na].reshape(nr, na).mean(1), marker="o", lw=2, color=DEG_CLASS_COLORS.get(lab, None), label=lab)
        ax.set_xlabel("radial frequency (cycles / pixel)"); ax.set_ylabel("centred log-power")
        ax.set_title("Radial profile of the degradation signature (steeper = more blur, flatter = more noise)")
        ax.legend(ncol=min(5, n)); ax.grid(alpha=0.3)
        fig.suptitle("Degradation fingerprints: mean radial x angular Welch signature per class")
        _tight(fig)
        save_fig(fig, path)

    def _fig_film(self, train, labels, path):
        M = np.stack([np.stack([f[2] for f in cls]).mean(0) for cls in train])  # (classes, 2*levels)
        gam, bet = M[:, 0::2], M[:, 1::2]
        lev = ["enc0", "enc1", "enc2", "enc3", "dec0", "dec1", "dec2"][:gam.shape[1]]
        fig, axes = plt.subplots(1, 2, figsize=(14, 0.55 * len(labels) + 2.6))
        plot_matrix(axes[0], gam, labels, lev, [[f"{v:.3f}" for v in r] for r in gam], cmap="Oranges",
                    title="mean |gamma| (feature scaling)", xlabel="U-Net level", cbar_label="|gamma|")
        plot_matrix(axes[1], bet, labels, lev, [[f"{v:.3f}" for v in r] for r in bet], cmap="Greens",
                    title="mean |beta| (feature shift)", xlabel="U-Net level", cbar_label="|beta|")
        fig.suptitle("How strongly each degradation modulates each level (FiLM from the signature)")
        _tight(fig)
        save_fig(fig, path)


# ==============================================================================
# 13d. EVALUATION SUITE (orchestrates the figures above, rank 0 only)
# ==============================================================================
class EvaluationSuite:
    def __init__(self, config: Config, model: nn.Module, inferencer: ModelInferencer):
        self.cfg, self.model, self.inf = config, model, inferencer
        self.fig_root = _mkdir(config.figures_dir)
        self.interp = InterpretabilityAnalyzer(config, model, inferencer)

    def _select(self, recs: List[dict]) -> Dict[str, List[int]]:
        gains = np.array([r["gain"] for r in recs])
        order = np.argsort(gains)
        k = min(self.cfg.gallery_k, len(recs))
        med = np.argsort(np.abs(gains - np.median(gains)))[:min(self.cfg.num_visualization_samples, len(recs))]
        return {"typical": [recs[i]["idx"] for i in med], "best": [recs[i]["idx"] for i in order[::-1][:k]],
                "worst": [recs[i]["idx"] for i in order[:k]]}

    @torch.no_grad()
    def _predict_np(self, ds, idx: int):
        d, c, _ = ds[idx]
        d, c = d.unsqueeze(0).to(self.cfg.device), c.unsqueeze(0).to(self.cfg.device)
        p = self.inf.predict(d).clamp(0, 1)
        return d, c, p

    def run(self, tests: Dict[str, Dataset], results: Dict[str, dict]) -> dict:
        set_paper_style()
        out = {"datasets": {}, "interpretability": {}}
        for name, ds in tests.items():
            res = results.get(name) or {}
            recs = res.get("records") or []
            if not recs:
                continue
            print(f"  figures for {name} ...")
            root = _mkdir(self.fig_root, name)
            sdir = _mkdir(root, "singles")
            try:
                out["datasets"][name] = fig_dataset_dashboard(name, recs, _mkdir(root, "summary"))
            except Exception as e:
                print(f"    dashboard failed: {type(e).__name__}: {e}")
            sel = self._select(recs)
            by_idx = {r["idx"]: r for r in recs}
            gal = {"best": [], "worst": []}
            todo = list(dict.fromkeys(sel["typical"] + sel["best"] + sel["worst"]))
            for idx in todo:
                try:
                    d, c, p = self._predict_np(ds, idx)
                    dn, cn, pn = to_hwc(d), to_hwc(c), to_hwc(p)
                    rec = by_idx[idx]
                    H, W = cn.shape[:2]
                    b = auto_box_size(H, W, self.cfg)
                    lin, lout = local_mse_maps(dn, pn, cn, b)
                    boxes = pick_boxes(lin - lout, b, self.cfg.zoom_boxes)
                    role = "best" if idx in sel["best"] else ("worst" if idx in sel["worst"] else "typical")
                    stem = f"{name}_{idx:04d}"
                    ttl = f"{name} #{idx} ({role}): {rec['in_psnr']:.2f} -> {rec['psnr']:.2f} dB ({rec['gain']:+.2f} dB)"
                    if role != "worst" or idx == sel["worst"][0]:
                        fig_zoom_comparison(dn, pn, cn, boxes, ttl, os.path.join(_mkdir(root, "comparisons"), f"{stem}_{role}.png"),
                                            sdir, stem, {"psnr": rec["in_psnr"], "ssim": rec["in_ssim"]},
                                            {"psnr": rec["psnr"], "ssim": rec["ssim"]}, pdf=self.cfg.save_pdf)
                    if idx in (sel["best"][:1] + sel["worst"][:1] + sel["typical"][:1]):
                        fig_error_analysis(dn, pn, cn, max(9, b // 4 * 2 + 1), ttl,
                                           os.path.join(_mkdir(root, "errors"), f"{stem}_{role}_errors.png"), sdir, stem, rec)
                        fig_spectrum(dn, pn, cn, rec, ttl, os.path.join(_mkdir(root, "spectra"), f"{stem}_{role}_spectrum.png"),
                                     sdir, stem)
                    if role in gal and boxes:
                        y, x, h, w = boxes[0]
                        cy, cx = y + h // 2, x + w // 2
                        z = min(2 * b, H, W)
                        y0, x0 = int(np.clip(cy - z // 2, 0, H - z)), int(np.clip(cx - z // 2, 0, W - z))
                        box = (y0, x0, z, z)
                        gal[role].append((_crop(dn, box), _crop(pn, box), _crop(cn, box),
                                          f"#{idx}\n{rec['gain']:+.2f} dB"))
                    if self.cfg.run_interpretability and idx in (sel["best"][:1] + sel["typical"][:1]):
                        center = (boxes[0][0] + boxes[0][2] // 2, boxes[0][1] + boxes[0][3] // 2) if boxes else (H // 2, W // 2)
                        st = self.interp.analyze(d, c, center, root, f"{stem}_{role}")
                        if st:
                            out["interpretability"][f"{name}/{idx}"] = st
                    del d, c, p
                except Exception as e:
                    print(f"    figure for {name} #{idx} failed: {type(e).__name__}: {e}")
            gdir = _mkdir(root, "galleries")
            fig_gallery(gal["best"], f"{name}: {len(gal['best'])} images where SINA-Net v4 gains the most (zoom on best region)",
                        os.path.join(gdir, f"{name}_best.png"))
            fig_gallery(gal["worst"], f"{name}: {len(gal['worst'])} hardest images (smallest gain)",
                        os.path.join(gdir, f"{name}_worst.png"))
        try:
            fig_cross_dataset(out["datasets"], results, _mkdir(self.fig_root, "overview"))
        except Exception as e:
            print(f"  cross-dataset figure failed: {type(e).__name__}: {e}")
        if self.cfg.run_probe:
            try:
                print("  degradation-signature probes ...")
                out["probe"] = DegradationProbe(self.cfg, self.model).run(self.fig_root)
            except Exception as e:
                print(f"  probe failed: {type(e).__name__}: {e}")
        return out


# ==============================================================================
# 14. COMPLEXITY PROFILER: parameters, COMPLETE FLOPs, memory traffic, pure latency
# ==============================================================================
# Paper tables usually quote "MACs" from thop/fvcore/ptflops, which only see nn.Conv2d /
# nn.Linear (and silently return 0 for everything else). SINA-Net spends most of its work in
# element-wise chains (SPWVD, neighbourhood attention, coherence), so that convention hides
# most of the model. Here EVERY ATen operator that executes is intercepted at the dispatcher
# level (TorchDispatchMode) and costed:
#   conv / matmul: 2 x MACs (+ bias)     FFT: 5 N log2 N (complex), 2.5 N log2 N (real)
#   softmax: 5 / element                 reductions: 1 / input element (var/std: 3)
#   norms: 5 / element                   point-wise: 1 / output element (lerp, addcmul: 2)
#   views / copies / padding / indexing: 0 FLOPs, but their bytes count as memory traffic.
# Any operator without a rule is costed as point-wise AND listed by name in the report, so
# nothing is dropped silently. FLOPs are attributed to modules through a module stack, which
# gives exact per-component numbers (they add up to the total). Latency is measured in
# eval() + inference_mode, batch 1, input already on the GPU, CUDA events, after warm-up:
# nothing but the network itself is timed.
from collections import defaultdict

try:
    from torch.utils._python_dispatch import TorchDispatchMode
except Exception:  # pragma: no cover
    TorchDispatchMode = object

_VIEW_OPS = {"view", "_unsafe_view", "expand", "permute", "transpose", "t", "slice", "select", "as_strided", "alias",
             "unsqueeze", "squeeze", "detach", "lift_fresh", "_reshape_alias", "reshape", "split", "split_with_sizes",
             "chunk", "unbind", "narrow", "view_as_real", "view_as_complex", "_conj", "conj", "real", "imag",
             "diagonal", "expand_as", "view_as", "unfold", "movedim", "_neg_view", "resolve_conj", "resolve_neg",
             "_to_dense", "sym_size", "sym_stride", "is_contiguous", "_local_scalar_dense", "empty", "empty_like",
             "empty_strided", "set_", "_has_compatible_shallow_copy_type", "dim", "size", "stride", "prim"}
_COPY_OPS = {"cat", "stack", "clone", "copy_", "_to_copy", "contiguous", "constant_pad_nd", "reflection_pad1d",
             "reflection_pad2d", "replication_pad1d", "replication_pad2d", "pixel_shuffle", "pixel_unshuffle", "index",
             "index_select", "gather", "flip", "roll", "repeat", "zeros_like", "ones_like", "full_like", "zeros", "ones",
             "full", "arange", "fill_", "zero_", "new_zeros", "new_empty", "new_full", "new_ones", "scalar_tensor",
             "linspace", "im2col", "col2im", "rot90", "_unsafe_index", "index_put_", "index_put", "masked_select",
             "nonzero", "meshgrid", "bernoulli_", "randperm", "rand", "randn", "normal_", "uniform_", "_pad_enum",
             "pad", "unfold_backward", "fill", "masked_scatter", "tril", "triu", "_index_put_impl_", "expand_copy",
             "view_copy", "permute_copy", "slice_copy", "lift_fresh_copy", "alias_copy", "clamp_min_", "detach_"}
_POINTWISE = {"add": 1, "sub": 1, "mul": 1, "div": 1, "rsub": 1, "neg": 1, "abs": 1, "pow": 1, "exp": 1, "exp2": 1,
              "expm1": 1, "log": 1, "log2": 1, "log10": 1, "log1p": 1, "sqrt": 1, "rsqrt": 1, "reciprocal": 1,
              "sigmoid": 1, "tanh": 1, "gelu": 1, "leaky_relu": 1, "relu": 1, "softplus": 1, "asinh": 1, "sin": 1,
              "cos": 1, "atan2": 1, "atan": 1, "remainder": 1, "fmod": 1, "floor": 1, "ceil": 1, "round": 1,
              "trunc": 1, "clamp": 1, "clamp_min": 1, "clamp_max": 1, "maximum": 1, "minimum": 1, "where": 1,
              "masked_fill": 1, "lerp": 2, "addcmul": 2, "addcdiv": 2, "square": 1, "erf": 1, "sign": 1, "sgn": 1,
              "eq": 1, "ne": 1, "lt": 1, "le": 1, "gt": 1, "ge": 1, "logical_and": 1, "logical_or": 1,
              "logical_not": 1, "bitwise_not": 1, "bitwise_and": 1, "bitwise_or": 1, "hypot": 1, "isfinite": 1,
              "isnan": 1, "nan_to_num": 1, "silu": 1, "hardtanh": 1, "elu": 1, "floor_divide": 1, "true_divide": 1,
              "sigmoid_backward": 1, "threshold": 1, "copysign": 1, "frac": 1, "angle": 1, "_softmax_backward_data": 1}
_REDUCE = {"sum": 1, "mean": 1, "amax": 1, "amin": 1, "max": 1, "min": 1, "prod": 1, "norm": 2, "linalg_vector_norm": 2,
           "var": 3, "std": 3, "var_mean": 3, "std_mean": 3, "logsumexp": 3, "argmax": 1, "argmin": 1, "all": 1,
           "any": 1, "cumsum": 1, "bincount": 1, "count_nonzero": 1, "_cdist_forward": 3, "nansum": 1}
_NORM = {"native_layer_norm": 5, "native_group_norm": 5, "native_batch_norm": 5,
         "_native_batch_norm_legit_no_training": 5, "_native_batch_norm_legit": 5}


def _flat_tensors(obj):
    if torch.is_tensor(obj):
        yield obj
    elif isinstance(obj, (list, tuple)):
        for o in obj:
            yield from _flat_tensors(o)
    elif isinstance(obj, dict):
        for o in obj.values():
            yield from _flat_tensors(o)


def _nbytes(t: torch.Tensor) -> int:
    try:
        return t.numel() * t.element_size()
    except Exception:
        return 0


def _op_cost(name: str, args, kwargs, out) -> Tuple[float, float, str]:
    """(FLOPs, dense MACs, category) of one ATen call."""
    base = name[:-1] if name.endswith("_") and name[:-1] in _POINTWISE else name
    outs = list(_flat_tensors(out))
    on = float(sum(t.numel() for t in outs))
    if name in ("convolution", "_convolution", "cudnn_convolution", "convolution_overrideable", "mkldnn_convolution",
                "_slow_conv2d_forward", "thnn_conv2d", "conv2d"):
        w = args[1]
        k = float(w.shape[1] * int(np.prod(w.shape[2:])))
        macs = on * k
        bias = args[2] if len(args) > 2 else None
        return 2 * macs + (on if torch.is_tensor(bias) else 0.0), macs, "conv"
    if name in ("mm", "addmm", "bmm", "baddbmm", "linear", "matmul", "addbmm", "_addmm_activation"):
        if name in ("mm",):
            a, b = args[0], args[1]; macs = float(a.shape[0] * a.shape[1] * b.shape[1])
        elif name in ("addmm", "_addmm_activation"):
            a, b = args[1], args[2]; macs = float(a.shape[0] * a.shape[1] * b.shape[1])
        elif name in ("bmm",):
            a, b = args[0], args[1]; macs = float(a.shape[0] * a.shape[1] * a.shape[2] * b.shape[2])
        elif name in ("baddbmm", "addbmm"):
            a, b = args[1], args[2]; macs = float(a.shape[0] * a.shape[1] * a.shape[2] * b.shape[2])
        elif name == "linear":
            x, w = args[0], args[1]; macs = float(x.numel() / x.shape[-1] * w.shape[0] * w.shape[1])
        else:
            macs = on * float(args[0].shape[-1])
        extra = on if name in ("addmm", "baddbmm", "addbmm", "_addmm_activation") or (name == "linear" and len(args) > 2 and torch.is_tensor(args[2])) else 0.0
        return 2 * macs + extra, macs, "matmul"
    if name in ("_fft_r2c", "_fft_c2c", "_fft_c2r"):
        dims = list(args[1]) if len(args) > 1 else [-1]
        src = args[0] if name != "_fft_c2r" else outs[0]
        N = float(np.prod([src.shape[d] for d in dims])) if dims else 1.0
        batch = src.numel() / max(N, 1.0)
        c = 5.0 if name == "_fft_c2c" else 2.5
        return c * N * math.log2(max(N, 2.0)) * batch, 0.0, "fft"
    if name in ("_softmax", "_log_softmax", "softmax", "log_softmax"):
        return 5.0 * on, 0.0, "softmax"
    if name in _NORM:
        return float(_NORM[name]) * float(args[0].numel()), 0.0, "norm"
    if name in _REDUCE:
        src = args[0] if args and torch.is_tensor(args[0]) else (outs[0] if outs else None)
        return float(_REDUCE[name]) * float(src.numel() if src is not None else 0), 0.0, "reduction"
    if name in ("scatter_add", "scatter_add_", "index_add", "index_add_", "scatter_reduce", "scatter_reduce_"):
        src = args[3] if len(args) > 3 and torch.is_tensor(args[3]) else (args[-1] if torch.is_tensor(args[-1]) else None)
        return float(src.numel() if src is not None else on), 0.0, "reduction"
    if name in ("_adaptive_avg_pool2d", "adaptive_avg_pool2d", "avg_pool2d", "upsample_bilinear2d", "upsample_nearest2d",
                "_upsample_bilinear2d_aa", "max_pool2d_with_indices"):
        return float(args[0].numel()) + on, 0.0, "pooling"
    if base in _POINTWISE:
        return float(_POINTWISE[base]) * on, 0.0, "pointwise"
    if name in _VIEW_OPS or name in _COPY_OPS:
        return 0.0, 0.0, "data movement"
    return on, 0.0, "unclassified"


class FullOpCounter(TorchDispatchMode):
    """Counts every ATen call (FLOPs, dense MACs, bytes read+written) with module attribution."""

    def __init__(self, model: nn.Module):
        super().__init__()
        self.stack: List[str] = [""]
        self.flops = defaultdict(float)
        self.macs = defaultdict(float)
        self.bytes = defaultdict(float)
        self.by_cat = defaultdict(float)
        self.by_op: Dict[str, List[float]] = defaultdict(lambda: [0, 0.0, 0.0])
        self.unclassified: Dict[str, int] = defaultdict(int)
        self.handles = []
        for name, m in model.named_modules():
            if name:
                self.handles.append(m.register_forward_pre_hook(self._push(name)))
                self.handles.append(m.register_forward_hook(self._pop(name)))

    def _push(self, name):
        def f(mod, inp):
            self.stack.append(name)
        return f

    def _pop(self, name):
        def f(mod, inp, out):
            while len(self.stack) > 1:
                if self.stack.pop() == name:
                    break
        return f

    def remove(self):
        for h in self.handles:
            h.remove()
        self.handles = []

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        kwargs = kwargs or {}
        out = func(*args, **kwargs)
        pkt = getattr(func, "overloadpacket", None)
        name = getattr(pkt, "__name__", str(func)).split(".")[-1]
        try:
            fl, mc, cat = _op_cost(name, args, kwargs, out)
        except Exception:
            fl, mc, cat = float(sum(t.numel() for t in _flat_tensors(out))), 0.0, "unclassified"
        by = 0.0 if name in _VIEW_OPS else float(sum(_nbytes(t) for t in _flat_tensors(args)) +
                                                 sum(_nbytes(t) for t in _flat_tensors(out)))
        if cat == "unclassified":
            self.unclassified[name] += 1
        self.by_cat[cat] += fl
        rec = self.by_op[name]
        rec[0] += 1; rec[1] += fl; rec[2] += by
        for s in set(self.stack):
            self.flops[s] += fl
            self.macs[s] += mc
            self.bytes[s] += by
        return out


def time_callable(fn: Callable, device: str, warmup: int, iters: int, budget_s: float = 20.0) -> dict:
    """Median/mean/std/p90 latency in ms of fn() (CUDA events on GPU, perf_counter on CPU)."""
    cuda = device.startswith("cuda")
    for _ in range(warmup):
        fn()
    if cuda:
        torch.cuda.synchronize()
    times = []
    t_start = time.perf_counter()
    for _ in range(iters):
        if cuda:
            s, e = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
            s.record(); fn(); e.record(); e.synchronize()
            times.append(s.elapsed_time(e))
        else:
            t0 = time.perf_counter(); fn(); times.append((time.perf_counter() - t0) * 1000)
        if time.perf_counter() - t_start > budget_s and len(times) >= 5:
            break
    a = np.asarray(times)
    return {"mean": float(a.mean()), "median": float(np.median(a)), "std": float(a.std()),
            "p90": float(np.percentile(a, 90)), "min": float(a.min()), "n": int(a.size)}


@contextlib.contextmanager
def _tf32(enabled: bool):
    if not torch.cuda.is_available():
        yield
        return
    a, b = torch.backends.cuda.matmul.allow_tf32, torch.backends.cudnn.allow_tf32
    torch.backends.cuda.matmul.allow_tf32 = torch.backends.cudnn.allow_tf32 = enabled
    try:
        yield
    finally:
        torch.backends.cuda.matmul.allow_tf32, torch.backends.cudnn.allow_tf32 = a, b


def measure_roofline(device: str) -> dict:
    """MEASURED (not datasheet) memory bandwidth and fp32 / bf16 matmul throughput of this GPU."""
    if not device.startswith("cuda"):
        return {}
    out = {}
    try:
        x = torch.empty(256 * 2 ** 20, dtype=torch.float32, device=device)  # 1 GiB
        t = time_callable(lambda _x=x: _x.clone(), device, 3, 10)
        out["bandwidth_GBs"] = 2 * x.numel() * 4 / (t["median"] / 1000) / 1e9
        del x
        for dt, key in ((torch.float32, "fp32_TFLOPs"), (torch.bfloat16 if native_bf16() else torch.float16, "half_TFLOPs")):
            a = torch.randn(8192, 8192, device=device, dtype=dt)
            with _tf32(False):
                t = time_callable(lambda _a=a: _a @ _a, device, 2, 5)
            out[key] = 2 * 8192 ** 3 / (t["median"] / 1000) / 1e12
            del a
        torch.cuda.empty_cache()
    except Exception as e:
        out["error"] = f"{type(e).__name__}: {e}"
    return out


class ComplexityProfiler:
    """Parameters, complete FLOPs, memory traffic and pure eval-mode latency of the whole model,
    of every main component (a partition of the network) and of every operator type."""

    def __init__(self, config: Config, model: nn.Module):
        self.cfg = config
        self.model = model
        self.dev = config.device

    # ---------------------------------------------------------------- structure
    def main_components(self) -> List[Tuple[str, List[str]]]:
        m = self.model
        comps = [("Degradation signature (Welch)", ["degradation_signature"])]
        if getattr(m, "degradation_conditioner", None) is not None:
            comps.append(("Degradation conditioner (FiLM MLP)", ["degradation_conditioner"]))
        names = [("Head conv 3x3", ["head"])]
        for lvl, lab in (("enc0", "Encoder L0"), ("down0", "Down 0->1"), ("enc1", "Encoder L1"), ("down1", "Down 1->2"),
                         ("enc2", "Encoder L2"), ("down2", "Down 2->3"), ("bottleneck", "Bottleneck L3"),
                         ("up2", "Up 3->2"), ("fuse2", "Skip fusion L2"), ("dec2", "Decoder L2"),
                         ("up1", "Up 2->1"), ("fuse1", "Skip fusion L1"), ("dec1", "Decoder L1"),
                         ("up0", "Up 1->0"), ("fuse0", "Skip fusion L0"), ("dec0", "Decoder L0"),
                         ("refinement", "Refinement"), ("tail", "Tail conv 3x3")):
            mod = getattr(m, lvl)
            if isinstance(mod, nn.ModuleList):
                kind = type(mod[0]).__name__ if len(mod) else ""
                names.append((f"{lab} ({len(mod)}x {kind})", [f"{lvl}.{i}" for i in range(len(mod))]))
            else:
                names.append((lab, [lvl]))
        if getattr(m, "aux_head2", None) is not None:
            names.append(("Aux heads (training-only deep supervision)", ["aux_head2", "aux_head1"]))
        return comps + names

    def operator_types(self) -> Dict[str, List[str]]:
        """Partition of the network into operator types (module names per type)."""
        types: Dict[str, List[str]] = defaultdict(list)
        for name, mod in self.model.named_modules():
            parent = name.rsplit(".", 1)[0] if "." in name else ""
            pmod = self.model.get_submodule(parent) if parent else self.model
            if isinstance(mod, CohenClassSpectralWienerUnit):
                types["Cohen-class spectral Wiener unit"].append(name)
            elif isinstance(mod, KLDivergenceGuidedDiNA):
                types["Homeostatic KL-guided DiNA"].append(name)
            elif isinstance(mod, DualGatedFeedForward):
                types["Dual-gated FFN"].append(name)
            elif isinstance(mod, LayerNorm2d) and isinstance(pmod, (SINABlock, LocalBlock)):
                types["LayerNorm2d (block norms)"].append(name)
            elif isinstance(mod, (SpectralCoherenceGatedFusion, PlainSkipFusion)):
                types["Skip fusion (coherence gate)"].append(name)
            elif isinstance(mod, (Downsample, Upsample)):
                types["Down/Up-sampling (conv + pixel-shuffle)"].append(name)
            elif name in ("head", "tail"):
                types["Head / tail conv"].append(name)
            elif isinstance(mod, RadialAngularSpectralSignature):
                types["Degradation signature"].append(name)
            elif isinstance(mod, DegradationConditioner):
                types["Degradation conditioner"].append(name)
            elif isinstance(mod, (nn.Conv2d,)) and isinstance(pmod, LocalBlock):
                types["LocalBlock mixer (dw3x3 + gated 1x1)"].append(name)
            elif name in ("aux_head1", "aux_head2"):
                types["Aux heads (training only)"].append(name)
        return dict(types)

    def _params(self, names: List[str]) -> int:
        seen, n = set(), 0
        for nm in names:
            for p in self.model.get_submodule(nm).parameters():
                if id(p) not in seen:
                    seen.add(id(p)); n += p.numel()
        return n

    # ---------------------------------------------------------------- counting
    def count(self, H: int, W: int) -> FullOpCounter:
        x = torch.rand(1, 3, H, W, device=self.dev)
        self.model.eval()
        counter = FullOpCounter(self.model)
        try:
            with torch.inference_mode(), eager_mode(self.model), counter:
                self.model(x)
        finally:
            counter.remove()
        return counter

    def paper_macs(self, H: int, W: int) -> float:
        """The original v4 convention: exact Conv2d/Linear MACs + analytic MACs of custom ops."""
        macs = {"layers": 0}

        def hook(m, inp, out):
            if isinstance(m, nn.Conv2d):
                macs["layers"] += out.numel() * (m.in_channels // m.groups) * m.kernel_size[0] * m.kernel_size[1]
            elif isinstance(m, nn.Linear):
                macs["layers"] += out.numel() * m.in_features

        hs = [m.register_forward_hook(hook) for m in self.model.modules() if isinstance(m, (nn.Conv2d, nn.Linear))]
        _MAC_COUNTER.update(enabled=True, macs=0)
        try:
            with torch.inference_mode(), eager_mode(self.model):
                self.model(torch.rand(1, 3, H, W, device=self.dev))
        finally:
            _MAC_COUNTER["enabled"] = False
            for h in hs:
                h.remove()
        return float(macs["layers"] + _MAC_COUNTER["macs"])

    def flopcounter_mode_total(self, H: int, W: int) -> Optional[float]:
        """torch.utils.flop_counter (the fvcore-like convention: conv/matmul only) for reference."""
        try:
            from torch.utils.flop_counter import FlopCounterMode
            fc = FlopCounterMode(display=False)
            with torch.inference_mode(), eager_mode(self.model), fc:
                self.model(torch.rand(1, 3, H, W, device=self.dev))
            return float(fc.get_total_flops())
        except Exception:
            return None

    # ---------------------------------------------------------------- latency
    def _capture_inputs(self, H: int, W: int, names: List[str]) -> Dict[str, tuple]:
        store: Dict[str, tuple] = {}
        hs = []
        for nm in names:
            mod = self.model.get_submodule(nm)

            def pre(m, args, _nm=nm):
                if _nm not in store:
                    store[_nm] = tuple(a.detach().clone() if torch.is_tensor(a) else a for a in args)
            hs.append(mod.register_forward_pre_hook(pre))
        try:
            with torch.inference_mode(), eager_mode(self.model):
                self.model(torch.rand(1, 3, H, W, device=self.dev))
        finally:
            for h in hs:
                h.remove()
        return store

    def _time_modules(self, H: int, W: int, groups: List[Tuple[str, List[str]]], mixer: bool = False) -> Dict[str, dict]:
        """Standalone latency of each group (sum over its modules, each run on its captured input)."""
        c = self.cfg
        cpu = not self.dev.startswith("cuda")
        warm, iters = (1, 3) if cpu else (c.speed_warmup, c.speed_iters)
        all_names = sorted({n for _, ns in groups for n in ns})
        if mixer:  # the LocalBlock mixer is timed from the input of its depthwise conv
            all_names = sorted(set(all_names) | {n.rsplit(".", 1)[0] + ".dwconv" for _, ns in groups for n in ns if n.endswith(".dwconv")})
        inputs = self._capture_inputs(H, W, all_names)
        out = {}
        with torch.inference_mode(), eager_mode(self.model):
            for label, ns in groups:
                tot, ok = 0.0, True
                for nm in ns:
                    if nm not in inputs or (mixer and label.startswith("LocalBlock mixer") and not nm.endswith(".dwconv")):
                        continue
                    mod = self.model.get_submodule(nm)
                    if mixer and nm.endswith(".dwconv"):
                        blk = self.model.get_submodule(nm.rsplit(".", 1)[0])

                        def fn(_b=blk, _x=inputs[nm][0]):
                            gate, value = torch.chunk(_b.pw_gate(_b.dwconv(_x)), 2, dim=1)
                            return _b.pw_out(F.gelu(gate) * value)
                    else:
                        def fn(_m=mod, _a=inputs[nm]):
                            return _m(*_a)
                    try:
                        tot += time_callable(fn, self.dev, warm, iters, budget_s=4.0)["median"]
                    except torch.cuda.OutOfMemoryError:
                        ok = False
                        torch.cuda.empty_cache()
                out[label] = {"ms": tot if ok else float("nan")}
        del inputs
        if self.dev.startswith("cuda"):
            torch.cuda.empty_cache()
        return out

    def _time_model(self, model: nn.Module, H: int, W: int, mode: str) -> dict:
        c = self.cfg
        cpu = not self.dev.startswith("cuda")
        warm, iters = (1, 3) if cpu else (c.speed_warmup, c.speed_iters)
        x = torch.rand(1, 3, H, W, device=self.dev)
        amp = mode.startswith("amp")
        dt = torch.bfloat16 if native_bf16() else torch.float16

        def fn():
            with torch.autocast("cuda" if not cpu else "cpu", dtype=dt, enabled=amp and not cpu):
                return model(x)

        ctx = contextlib.nullcontext() if mode == "amp+compile" else eager_mode(model)
        try:
            if not cpu:
                torch.cuda.empty_cache(); torch.cuda.reset_peak_memory_stats()
                base = torch.cuda.memory_allocated()
            with torch.inference_mode(), ctx, _tf32(mode != "fp32"):
                t = time_callable(fn, self.dev, warm, iters, budget_s=30.0)
            if not cpu:
                t["peak_mem_GB"] = (torch.cuda.max_memory_allocated() - base) / 2 ** 30
            t["fps"] = 1000.0 / t["median"]
            t["mpix_s"] = H * W / 1e6 / (t["median"] / 1000)
            return t
        except torch.cuda.OutOfMemoryError:
            torch.cuda.empty_cache()
            return {"oom": True}

    # ---------------------------------------------------------------- main entry
    def run(self, out_tables: str, out_figs: str) -> dict:
        c = self.cfg
        set_paper_style()
        self.model.eval()
        total_params = sum(p.numel() for p in self.model.parameters())
        trainable = sum(p.numel() for p in self.model.parameters() if p.requires_grad) or total_params
        buffers = sum(b.numel() for b in self.model.buffers())
        res = {"params": total_params, "buffers": buffers, "sizes": {}, "roofline": measure_roofline(self.dev)}
        comps = self.main_components()
        types = self.operator_types()
        cuda = self.dev.startswith("cuda")
        modes = ["fp32"] + (["fp32+tf32"] if cuda and torch.cuda.get_device_capability()[0] >= 8 else []) + \
                (["amp"] if cuda else [])
        compiled_model = None
        if cuda and c.profile_compiled and c.compile_model and compile_guard_allows(c):
            try:
                with eager_mode(self.model):  # never deep-copy compiled call wrappers
                    compiled_model = copy.deepcopy(self.model).eval()
                compile_blocks(compiled_model)
                modes.append("amp+compile")
            except Exception as e:
                print(f"  profiler: compiled timing skipped ({type(e).__name__})")
                compiled_model = None
        for si, (H, W) in enumerate(c.complexity_sizes):
            key = f"{H}x{W}"
            print(f"  profiling at {W}x{H} ...")
            try:
                counter = self.count(H, W)
            except torch.cuda.OutOfMemoryError:
                torch.cuda.empty_cache()
                res["sizes"][key] = {"oom": True}
                continue
            total_flops = counter.flops[""]
            r = {"flops": total_flops, "macs_dense": counter.macs[""], "bytes": counter.bytes[""],
                 "paper_macs": self.paper_macs(H, W), "flopcounter_mode": self.flopcounter_mode_total(H, W),
                 "by_cat": dict(counter.by_cat), "unclassified": dict(counter.unclassified),
                 "top_ops": sorted(((k, v[0], v[1], v[2]) for k, v in counter.by_op.items()), key=lambda t: -t[2])[:25],
                 "latency": {}}
            for mode in modes:
                mdl = compiled_model if mode == "amp+compile" else self.model
                if mode == "amp+compile":
                    compile_guard_mark(c, "attempting")
                try:
                    r["latency"][mode] = self._time_model(mdl, H, W, mode)
                    if mode == "amp+compile":
                        compile_guard_mark(c, "ok")
                except Exception as e:
                    if mode == "amp+compile":
                        compile_guard_mark(c, "failed")
                    r["latency"][mode] = {"error": f"{type(e).__name__}"}
            # main components (partition of the network)
            comp_rows = []
            groups = [(lab, ns) for lab, ns in comps]
            lat = self._time_modules(H, W, groups)
            for lab, ns in comps:
                f = sum(counter.flops.get(n, 0.0) for n in ns)
                comp_rows.append({"component": lab, "params": self._params(ns), "flops": f,
                                  "macs": sum(counter.macs.get(n, 0.0) for n in ns),
                                  "bytes": sum(counter.bytes.get(n, 0.0) for n in ns), "ms": lat[lab]["ms"]})
            glue_f = total_flops - sum(rw["flops"] for rw in comp_rows)
            glue_b = counter.bytes[""] - sum(rw["bytes"] for rw in comp_rows)
            full_ms = r["latency"]["fp32"].get("median", float("nan"))
            sum_ms = sum(rw["ms"] for rw in comp_rows if np.isfinite(rw["ms"]))
            comp_rows.append({"component": "FiLM, padding, global residual (glue)",
                              "params": res["params"] - sum(rw["params"] for rw in comp_rows), "flops": glue_f,
                              "macs": counter.macs[""] - sum(rw["macs"] for rw in comp_rows), "bytes": glue_b,
                              "ms": (full_ms - sum_ms) if full_ms > sum_ms else float("nan")})
            r["full_ms"], r["sum_ms"] = full_ms, sum_ms
            r["components"] = comp_rows
            # operator types (first size only: timing every instance at large sizes is slow)
            if si == 0:
                type_rows = []
                lat_t = self._time_modules(H, W, [(k, v) for k, v in types.items()],
                                           mixer=True)
                for k, ns in types.items():
                    if k == "LocalBlock mixer (dw3x3 + gated 1x1)":
                        blocks = sorted({n.rsplit(".", 1)[0] for n in ns})
                        f = sum(counter.flops.get(b, 0.0) - sum(counter.flops.get(f"{b}.{ch}", 0.0) for ch in ("norm1", "norm2", "ffn"))
                                for b in blocks)
                        by = sum(counter.bytes.get(b, 0.0) - sum(counter.bytes.get(f"{b}.{ch}", 0.0) for ch in ("norm1", "norm2", "ffn"))
                                 for b in blocks)
                        p = sum(self._params([f"{b}.dwconv", f"{b}.pw_gate", f"{b}.pw_out"]) for b in blocks)
                        n_inst = len(blocks)
                        ms = lat_t[k]["ms"]
                    else:
                        f = sum(counter.flops.get(n, 0.0) for n in ns)
                        by = sum(counter.bytes.get(n, 0.0) for n in ns)
                        p = self._params(ns)
                        n_inst = len(ns)
                        ms = lat_t[k]["ms"]
                    type_rows.append({"type": k, "instances": n_inst, "params": p, "flops": f, "bytes": by, "ms": ms})
                rest_f = total_flops - sum(t["flops"] for t in type_rows)
                type_rows.append({"type": "Residual adds, FiLM, padding (glue)", "instances": "-", "params":
                                  total_params - sum(t["params"] for t in type_rows), "flops": rest_f,
                                  "bytes": counter.bytes[""] - sum(t["bytes"] for t in type_rows),
                                  "ms": float("nan")})
                r["types"] = type_rows
            res["sizes"][key] = r
        del compiled_model
        res["trainable"] = trainable
        self._tables(res, out_tables)
        self._figures(res, out_figs)
        return res

    # ---------------------------------------------------------------- output
    def _tables(self, res: dict, out_dir: str):
        gpu = torch.cuda.get_device_name(0) if self.dev.startswith("cuda") else "CPU"
        rows = []
        for key, r in res["sizes"].items():
            if r.get("oom"):
                rows.append([key, "OOM"] + [None] * 9)
                continue
            for mode, t in r["latency"].items():
                if "median" not in t:
                    rows.append([key, mode, None, None, None, None, "OOM" if t.get("oom") else t.get("error"), None, None, None, None])
                    continue
                rows.append([key, mode, res["params"] / 1e6, r["flops"] / 1e9, r["paper_macs"] / 1e9,
                             (r["flopcounter_mode"] or float("nan")) / 1e9,
                             f"{t['median']:.2f} ({t['mean']:.2f}+-{t['std']:.2f})", t["p90"], t["fps"], t["mpix_s"],
                             t.get("peak_mem_GB")])
        ResultTable("Whole-model complexity and PURE inference speed (eval mode, batch 1, "
                    f"inference_mode, CUDA events) on {gpu}",
                    ["Input (HxW)", "Precision", "Params (M)", "FLOPs complete (G)", "MACs paper conv. (G)",
                     "FlopCounterMode conv/matmul (G)", "Latency median (mean+-std) ms", "p90 ms", "FPS", "MPix/s",
                     "Peak mem (GB)"], rows,
                    notes=["FLOPs complete = every executed ATen op (conv/matmul 2xMAC, FFT 5NlogN, softmax 5/elt, "
                           "point-wise 1/elt); MACs paper conv. = Conv2d/Linear MACs + analytic MACs of the custom "
                           "operators (the convention of the v4 script); FlopCounterMode = PyTorch's built-in counter, "
                           "which (like thop/fvcore) only sees convolutions and matmuls.",
                           "fp32 = TF32 disabled (strict); amp = bf16 on Ampere+/Blackwell, fp16 otherwise; "
                           "amp+compile = torch.compile'd blocks (Inductor)."],
                    fmt={"Params (M)": "{:.3f}", "FLOPs complete (G)": "{:.2f}", "MACs paper conv. (G)": "{:.2f}",
                         "FlopCounterMode conv/matmul (G)": "{:.2f}", "p90 ms": "{:.2f}", "FPS": "{:.2f}",
                         "MPix/s": "{:.2f}", "Peak mem (GB)": "{:.2f}"}).save(os.path.join(out_dir, "complexity_whole_model"))
        for key, r in res["sizes"].items():
            if r.get("oom"):
                continue
            tot = r["flops"]
            sum_ms = r.get("sum_ms") or sum(x["ms"] for x in r["components"] if np.isfinite(x["ms"]))
            rows = []
            for x in r["components"]:
                rows.append([x["component"], x["params"] / 1e6, 100 * x["params"] / max(res["params"], 1), x["flops"] / 1e9,
                             100 * x["flops"] / max(tot, 1), x["macs"] / 1e9, x["bytes"] / 1e9,
                             x["flops"] / max(x["bytes"], 1), x["ms"], 100 * x["ms"] / max(sum_ms, 1e-9)])
            rows.append(["Sum of components (standalone timings)", None, None, None, None, None, None, None, sum_ms, 100.0])
            rows.append(["TOTAL: whole model, end-to-end", res["params"] / 1e6, 100.0, tot / 1e9, 100.0, r["macs_dense"] / 1e9,
                         r["bytes"] / 1e9, tot / max(r["bytes"], 1), r.get("full_ms"), None])
            ResultTable(f"Per-component complexity at {key} (fp32, eval mode; latency = each component run alone on its real input)",
                        ["Component", "Params (M)", "Params %", "FLOPs (G)", "FLOPs %", "Dense MACs (G)",
                         "Memory traffic (GB)", "FLOP/byte", "Latency (ms)", "Latency %"], rows,
                        notes=["Components partition the network: their FLOPs, parameters and traffic add up exactly "
                               "to the total; the glue row is everything executed outside them (its latency is shown only "
                               "when the end-to-end time exceeds the sum of the standalone component times).",
                               "Latency % = share of the sum of standalone component times (each module timed alone on its "
                               "real captured input; launch overhead makes that sum a little larger than end-to-end).",
                               "Memory traffic = bytes read + written by every non-view op (an upper bound: kernel fusion "
                               "can remove some of it). FLOP/byte << 10 = memory-bound on any current GPU."],
                        fmt={"Params (M)": "{:.3f}", "Params %": "{:.1f}", "FLOPs (G)": "{:.3f}", "FLOPs %": "{:.1f}",
                             "Dense MACs (G)": "{:.3f}", "Memory traffic (GB)": "{:.3f}", "FLOP/byte": "{:.2f}",
                             "Latency (ms)": "{:.3f}", "Latency %": "{:.1f}"},
                        highlight_rows=[len(rows) - 1]).save(os.path.join(out_dir, f"complexity_components_{key}"))
            if "types" in r:
                ttot = sum(x["ms"] for x in r["types"] if np.isfinite(x["ms"]))
                rows = [[x["type"], x["instances"], x["params"] / 1e6, x["flops"] / 1e9, 100 * x["flops"] / max(tot, 1),
                         x["bytes"] / 1e9, x["flops"] / max(x["bytes"], 1), x["ms"], 100 * x["ms"] / max(ttot, 1e-9)]
                        for x in r["types"]]
                ResultTable(f"Per-operator-type complexity at {key} (fp32, eval mode)",
                            ["Operator type", "Instances", "Params (M)", "FLOPs (G)", "FLOPs %", "Memory traffic (GB)",
                             "FLOP/byte", "Latency (ms)", "Latency %"], rows,
                            fmt={"Params (M)": "{:.3f}", "FLOPs (G)": "{:.3f}", "FLOPs %": "{:.1f}",
                                 "Memory traffic (GB)": "{:.3f}", "FLOP/byte": "{:.2f}", "Latency (ms)": "{:.3f}",
                                 "Latency %": "{:.1f}"}).save(os.path.join(out_dir, f"complexity_operator_types_{key}"))
            rows = [[k, int(n), fl / 1e9, 100 * fl / max(tot, 1), by / 1e9] for k, n, fl, by in r["top_ops"]]
            notes = ["FLOPs by category: " + ", ".join(f"{k} {v / 1e9:.2f} G" for k, v in sorted(r['by_cat'].items(), key=lambda t: -t[1]))]
            if r["unclassified"]:
                notes.append("Ops without a specific rule (costed as 1 FLOP per output element): " +
                             ", ".join(f"{k} x{v}" for k, v in r["unclassified"].items()))
            else:
                notes.append("Every executed ATen op matched a costing rule (no unclassified ops).")
            ResultTable(f"Top ATen operators by FLOPs at {key}", ["ATen op", "Calls", "FLOPs (G)", "Share %", "Bytes (GB)"],
                        rows, notes=notes, fmt={"FLOPs (G)": "{:.3f}", "Share %": "{:.1f}", "Bytes (GB)": "{:.3f}"}
                        ).save(os.path.join(out_dir, f"complexity_aten_ops_{key}"))
        pr = [[k, v] for k, v in (("Parameters (trainable)", f"{res['trainable']:,}"), ("Parameters (total)", f"{res['params']:,}"),
                                  ("Buffers (non-trainable)", f"{res['buffers']:,}"),
                                  ("fp32 weight size (MB)", f"{res['params'] * 4 / 2 ** 20:.1f}"))]
        for k, v in res.get("roofline", {}).items():
            pr.append([f"measured {k}", f"{v:.1f}" if isinstance(v, float) else v])
        ResultTable("Model size and measured GPU capability", ["Quantity", "Value"], pr).save(os.path.join(out_dir, "complexity_summary"))

    def _figures(self, res: dict, out_dir: str):
        for key, r in res["sizes"].items():
            if r.get("oom") or "components" not in r:
                continue
            comps = [x for x in r["components"]]
            labels = [x["component"] for x in comps]
            cmap = plt.get_cmap("tab20")
            cols = [cmap(i % 20) for i in range(len(comps))]
            metrics = [("Parameters", [x["params"] for x in comps]), ("FLOPs (complete)", [x["flops"] for x in comps]),
                       ("Memory traffic", [x["bytes"] for x in comps]),
                       ("Latency (fp32)", [x["ms"] if np.isfinite(x["ms"]) else 0 for x in comps])]
            fig, ax = plt.subplots(figsize=(14, 4.2))
            for i, (mname, vals) in enumerate(metrics):
                tot = max(sum(vals), 1e-12)
                left = 0.0
                for j, v in enumerate(vals):
                    w = 100 * v / tot
                    ax.barh(i, w, left=left, color=cols[j], edgecolor="white", lw=0.5, label=labels[j] if i == 0 else None)
                    if w > 6:
                        ax.text(left + w / 2, i, f"{w:.0f}%", ha="center", va="center", fontsize=7, color="white")
                    left += w
            ax.set_yticks(range(len(metrics))); ax.set_yticklabels([m[0] for m in metrics]); ax.set_xlim(0, 100)
            ax.set_xlabel("share of the whole model (%)")
            ax.set_title(f"Where the cost goes, per component ({key})")
            ax.legend(ncol=4, fontsize=7, bbox_to_anchor=(0.5, -0.22), loc="upper center")
            _tight(fig)
            save_fig(fig, os.path.join(out_dir, f"complexity_shares_{key}.png"))
            if "types" in r:
                rf = res.get("roofline", {})
                fig, ax = plt.subplots(figsize=(8.2, 5.6))
                for i, t in enumerate(r["types"]):
                    if not (np.isfinite(t["ms"]) and t["ms"] > 0 and t["bytes"] > 0 and t["flops"] > 0):
                        continue
                    ai = t["flops"] / t["bytes"]
                    perf = t["flops"] / (t["ms"] / 1000) / 1e9
                    ax.scatter(ai, perf, s=60 + 400 * t["ms"] / max(sum(x["ms"] for x in r["types"] if np.isfinite(x["ms"])), 1e-9),
                               color=cmap(i % 20), edgecolor="black", lw=0.5, zorder=3)
                    ax.annotate(t["type"], (ai, perf), fontsize=7, xytext=(4, 3), textcoords="offset points")
                if "bandwidth_GBs" in rf and "fp32_TFLOPs" in rf:
                    xs = np.logspace(-2, 3, 200)
                    ax.plot(xs, np.minimum(xs * rf["bandwidth_GBs"], rf["fp32_TFLOPs"] * 1e3), color="#444444", lw=1.5,
                            label=f"measured roofline: {rf['bandwidth_GBs']:.0f} GB/s, {rf['fp32_TFLOPs']:.1f} TFLOP/s fp32")
                    ax.legend(loc="lower right")
                ax.set_xscale("log"); ax.set_yscale("log")
                ax.set_xlabel("arithmetic intensity (FLOP / byte of unfused traffic)"); ax.set_ylabel("achieved GFLOP/s (fp32)")
                ax.set_title(f"Operator types on the roofline ({key}; bubble = latency share)")
                ax.grid(alpha=0.3, which="both")
                _tight(fig)
                save_fig(fig, os.path.join(out_dir, f"complexity_roofline_{key}.png"))


@torch.no_grad()
def benchmark_model(model: nn.Module, device: str, input_size: tuple = (1, 3, 256, 256)):
    """Quick start-up benchmark (kept from v4): parameters, MACs in the v4 convention (exact
    Conv2d/Linear MACs + analytic MACs of the custom operators) and eager latency. The full,
    per-component profile is produced by ComplexityProfiler after evaluation."""
    model.eval()
    params = sum(p.numel() for p in model.parameters())
    macs = {"layers": 0}

    def hook(m, inp, out):
        if isinstance(m, nn.Conv2d):
            macs["layers"] += out.numel() * (m.in_channels // m.groups) * m.kernel_size[0] * m.kernel_size[1]
        elif isinstance(m, nn.Linear):
            macs["layers"] += out.numel() * m.in_features

    hs = [m.register_forward_hook(hook) for m in model.modules() if isinstance(m, (nn.Conv2d, nn.Linear))]
    x = torch.rand(*input_size, device=device)
    _MAC_COUNTER.update(enabled=True, macs=0)
    try:
        with eager_mode(model):
            model(x)
    finally:
        _MAC_COUNTER["enabled"] = False
        for h in hs:
            h.remove()
    total_macs = macs["layers"] + _MAC_COUNTER["macs"]
    n_warm, n_iter = (10, 50) if device.startswith("cuda") else (1, 3)
    with eager_mode(model):
        t = time_callable(lambda: model(x), device, n_warm, n_iter)
    print("\n" + "=" * 60 + "\nMODEL BENCHMARK (quick; full profile after evaluation)\n" + "=" * 60)
    print(f"Parameters:        {params / 1e6:.2f} M")
    print(f"MACs @ {input_size[-2]}x{input_size[-1]}:   {total_macs / 1e9:.2f} G "
          f"(conv/linear {macs['layers'] / 1e9:.2f} G + custom ops {_MAC_COUNTER['macs'] / 1e9:.2f} G)")
    print(f"Latency:           {t['median']:.1f} ms/image (fp32, eager) on {device}")
    print("=" * 60 + "\n")
    model.train()
    return params / 1e6, total_macs / 1e9


# ==============================================================================
# 15. TABLES (console + Markdown + LaTeX + CSV + PNG, best = bold red, second = blue)
# ==============================================================================
REPORT_ITEMS: List[dict] = []


def _latex_escape(s: str) -> str:
    for a, b in (("\\", r"\textbackslash{}"), ("&", r"\&"), ("%", r"\%"), ("_", r"\_"), ("#", r"\#"), ("$", r"\$"),
                 ("{", r"\{"), ("}", r"\}"), ("~", r"\textasciitilde{}"), ("^", r"\textasciicircum{}")):
        s = s.replace(a, b)
    return s


class ResultTable:
    """One table, many renderings. `best` = {column: "max" | "min"}: the best value of that
    column is bold (red in the PNG) and the second best underlined (blue in the PNG), as in the
    tables of Restormer / NAFNet / MambaIR. `highlight_rows` marks our own row(s)."""

    def __init__(self, title: str, columns: List[str], rows: List[list], notes: Sequence[str] = (),
                 fmt: Optional[Dict[str, str]] = None, best: Optional[Dict[str, str]] = None,
                 highlight_rows: Sequence[int] = ()):
        self.title, self.columns, self.rows = title, list(columns), [list(r) for r in rows]
        self.notes, self.fmt, self.best = list(notes), dict(fmt or {}), dict(best or {})
        self.highlight = set(highlight_rows)
        self._rank = self._ranks()

    def _num(self, v):
        if isinstance(v, bool) or v is None:
            return None
        if isinstance(v, (int, float, np.floating, np.integer)) and np.isfinite(v):
            return float(v)
        return None

    def _ranks(self) -> Dict[Tuple[int, int], int]:
        out = {}
        for col, mode in self.best.items():
            if col not in self.columns:
                continue
            j = self.columns.index(col)
            vals = sorted({self._num(r[j]) for r in self.rows if self._num(r[j]) is not None}, reverse=(mode == "max"))
            for i, r in enumerate(self.rows):
                v = self._num(r[j])
                if v is not None and vals:
                    if v == vals[0]:
                        out[(i, j)] = 1
                    elif len(vals) > 1 and v == vals[1]:
                        out[(i, j)] = 2
        return out

    def cell(self, i: int, j: int) -> str:
        v = self.rows[i][j]
        if v is None or (isinstance(v, float) and not np.isfinite(v)):
            return "-"
        f = self.fmt.get(self.columns[j])
        if f and self._num(v) is not None:
            return f.format(v)
        if isinstance(v, float):
            return f"{v:.4g}"
        return str(v)

    def to_console(self) -> str:
        cells = [[self.cell(i, j) for j in range(len(self.columns))] for i in range(len(self.rows))]
        w = [max(len(self.columns[j]), *(len(c[j]) for c in cells)) if cells else len(self.columns[j])
             for j in range(len(self.columns))]
        line = lambda l, m, r: l + m.join("─" * (x + 2) for x in w) + r
        out = [self.title, line("┌", "┬", "┐"),
               "│" + "│".join(f" {self.columns[j]:<{w[j]}} " for j in range(len(w))) + "│", line("├", "┼", "┤")]
        for i, c in enumerate(cells):
            mark = [("*" if self._rank.get((i, j)) == 1 else "") for j in range(len(w))]
            row = "│".join(f" {(c[j] + mark[j]):<{w[j]}} " if j == 0 else f" {(c[j] + mark[j]):>{w[j]}} "
                           for j in range(len(w)))
            out.append(("│" + row + "│") + ("  <== ours" if i in self.highlight else ""))
        out.append(line("└", "┴", "┘"))
        out += [f"  {n}" for n in self.notes]
        return "\n".join(out)

    def to_markdown(self) -> str:
        out = [f"**{self.title}**", "", "| " + " | ".join(self.columns) + " |",
               "|" + "|".join(":---" if j == 0 else "---:" for j in range(len(self.columns))) + "|"]
        for i in range(len(self.rows)):
            cs = []
            for j in range(len(self.columns)):
                c = self.cell(i, j)
                r = self._rank.get((i, j))
                c = f"**{c}**" if r == 1 else (f"<u>{c}</u>" if r == 2 else c)
                if j == 0 and i in self.highlight:
                    c = f"**{c}**"
                cs.append(c.replace("|", "\\|"))
            out.append("| " + " | ".join(cs) + " |")
        if self.notes:
            out += [""] + [f"> {n}" for n in self.notes]
        return "\n".join(out)

    def to_latex(self) -> str:
        spec = "l" + "c" * (len(self.columns) - 1)
        out = [r"\begin{table}[t]", r"\centering", r"\small", rf"\caption{{{_latex_escape(self.title)}}}",
               rf"\begin{{tabular}}{{{spec}}}", r"\toprule", " & ".join(_latex_escape(c) for c in self.columns) + r" \\",
               r"\midrule"]
        for i in range(len(self.rows)):
            cs = []
            for j in range(len(self.columns)):
                c = _latex_escape(self.cell(i, j))
                r = self._rank.get((i, j))
                c = rf"\textbf{{\color{{red}}{c}}}" if r == 1 else (rf"\underline{{\color{{blue}}{c}}}" if r == 2 else c)
                cs.append(c)
            row = " & ".join(cs) + r" \\"
            out.append((r"\rowcolor{gray!12} " + row) if i in self.highlight else row)
        out += [r"\bottomrule", r"\end{tabular}"]
        for n in self.notes:
            out.append(rf"\\[2pt]\footnotesize{{{_latex_escape(n)}}}")
        out.append(r"\end{table}")
        return "\n".join(out)

    def to_csv(self, path: str):
        with open(path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(self.columns)
            for r in self.rows:
                w.writerow(["" if v is None else v for v in r])

    def to_png(self, path: str):
        import textwrap
        cells = [[self.cell(i, j) for j in range(len(self.columns))] for i in range(len(self.rows))]
        head = [textwrap.wrap(c, 16) or [""] for c in self.columns]
        cw = 0.078
        widths = [max(0.7, max(max(len(h) for h in head[j]), *(len(c[j]) for c in cells)) * cw + 0.28 if cells
                      else max(len(h) for h in head[j]) * cw + 0.28) for j in range(len(self.columns))]
        W = sum(widths)
        nh = max(len(h) for h in head)
        rh, hh = 0.30, 0.22 * nh + 0.16
        note_lines = [l for n in self.notes for l in textwrap.wrap(n, max(40, int(W / 0.068)))]
        title_lines = textwrap.wrap(self.title, max(40, int(W / 0.085)))
        th = 0.24 * len(title_lines) + 0.12
        Ht = th + hh + rh * len(cells) + 0.2 * len(note_lines) + 0.15
        fig = plt.figure(figsize=(W, Ht))
        ax = fig.add_axes([0, 0, 1, 1])
        ax.set_xlim(0, W); ax.set_ylim(Ht, 0); ax.axis("off")
        for k, tl in enumerate(title_lines):
            ax.text(0.05, 0.2 + 0.24 * k, tl, fontsize=10, fontweight="bold", va="center", color="#1F3A5F")
        y = th
        ax.add_patch(Rectangle((0, y), W, hh, color="#1F3A5F"))
        x = 0
        for j, h in enumerate(head):
            ax.text(x + widths[j] / 2, y + hh / 2, "\n".join(h), ha="center", va="center", fontsize=8.2,
                    color="white", fontweight="bold")
            x += widths[j]
        y += hh
        for i, c in enumerate(cells):
            bg = "#FDECEA" if i in self.highlight else ("#F4F6FA" if i % 2 else "white")
            ax.add_patch(Rectangle((0, y), W, rh, color=bg))
            x = 0
            for j, s in enumerate(c):
                r = self._rank.get((i, j))
                color = "#C0392B" if r == 1 else ("#1F63B5" if r == 2 else "#1A1A1A")
                weight = "bold" if (r in (1, 2) or (j == 0 and i in self.highlight)) else "normal"
                if j == 0:
                    ax.text(x + 0.08, y + rh / 2, s, ha="left", va="center", fontsize=8.2, color=color, fontweight=weight)
                else:
                    ax.text(x + widths[j] / 2, y + rh / 2, s, ha="center", va="center", fontsize=8.2, color=color,
                            fontweight=weight)
                x += widths[j]
            y += rh
        ax.plot([0, W], [y, y], color="#1F3A5F", lw=1.2)
        for k, n in enumerate(note_lines):
            ax.text(0.05, y + 0.18 + 0.2 * k, n, fontsize=7, style="italic", color="#444444", va="center")
        fig.savefig(path, dpi=200)
        plt.close(fig)

    def save(self, stem: str, echo: bool = True):
        os.makedirs(os.path.dirname(stem), exist_ok=True)
        with open(stem + ".md", "w") as f:
            f.write(self.to_markdown() + "\n")
        with open(stem + ".tex", "w") as f:
            f.write(self.to_latex() + "\n")
        self.to_csv(stem + ".csv")
        try:
            self.to_png(stem + ".png")
        except Exception as e:
            print(f"  (png rendering of '{self.title[:40]}' failed: {type(e).__name__})")
        if echo:
            print("\n" + self.to_console())
        REPORT_ITEMS.append({"kind": "table", "title": self.title, "md": self.to_markdown(), "stem": stem})
        return self


# ==============================================================================
# 16. STATE OF THE ART 2022-2026 (numbers copied from each method's OWN paper table)
# ==============================================================================
# src: "own" = copied from the method's own table; "3rd" = only available in another paper's
# table; "avg*" = average computed here from the method's per-dataset numbers. Rows marked with a
# protocol caveat (generative models, extra data, per-image optimisation, questionable test
# protocol) are listed for completeness but are NOT like-for-like. "cost" is whatever the paper
# reports (MACs or FLOPs, G) at the stated input size; "n/s" = size not stated.
SOTA_DEBLUR = [  # GoPro-trained, GoPro + HIDE test (RGB)
    dict(m="Restormer", v="CVPR 2022", y=2022, GoPro=(32.92, 0.961), HIDE=(31.22, 0.942), params=26.12, cost=141, cost_in="256²",
         url="https://openaccess.thecvf.com/content/CVPR2022/papers/Zamir_Restormer_Efficient_Transformer_for_High-Resolution_Image_Restoration_CVPR_2022_paper.pdf"),
    dict(m="NAFNet (w64)", v="ECCV 2022", y=2022, GoPro=(33.69, 0.967), HIDE=(31.31, 0.943), params=67.9, cost=65, cost_in="256²",
         note="HIDE and params from FFTformer's table (3rd)", url="https://arxiv.org/abs/2204.04676"),
    dict(m="GRL-B", v="CVPR 2023", y=2023, GoPro=(33.93, 0.968), HIDE=(31.65, 0.947), params=None, cost=None, cost_in="",
         url="https://openaccess.thecvf.com/content/CVPR2023/papers/Li_Efficient_and_Explicit_Modelling_of_Image_Hierarchies_for_Image_Restoration_CVPR_2023_paper.pdf"),
    dict(m="FFTformer", v="CVPR 2023", y=2023, GoPro=(34.21, 0.969), HIDE=(31.62, 0.946), params=16.6, cost=131, cost_in="256²",
         note="FLOPs from EVSSM's table (3rd)",
         url="https://openaccess.thecvf.com/content/CVPR2023/papers/Kong_Efficient_Frequency_Domain-Based_Transformers_for_High-Quality_Image_Deblurring_CVPR_2023_paper.pdf"),
    dict(m="SFHformer", v="ECCV 2024", y=2024, GoPro=(34.01, 0.969), HIDE=(31.66, 0.948), params=None, cost=None, cost_in="",
         url="https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/06190.pdf"),
    dict(m="MISC Filter", v="CVPR 2024", y=2024, GoPro=(34.10, 0.969), HIDE=(31.66, 0.946), params=16.0, cost=None, cost_in="",
         url="https://openaccess.thecvf.com/content/CVPR2024/papers/Liu_Motion-adaptive_Separable_Collaborative_Filters_for_Blind_Motion_Deblurring_CVPR_2024_paper.pdf"),
    dict(m="LoFormer-L", v="ACM MM 2024", y=2024, GoPro=(34.09, 0.969), HIDE=(31.86, 0.949), params=49.0, cost=126, cost_in="256²",
         url="https://arxiv.org/abs/2407.16993"),
    dict(m="AdaRevD-L", v="CVPR 2024", y=2024, GoPro=(34.60, 0.972), HIDE=(32.35, 0.953), params=210.8, cost=460, cost_in="256²",
         url="https://arxiv.org/abs/2406.09135"),
    dict(m="EVSSM", v="CVPR 2025", y=2025, GoPro=(34.51, 0.971), HIDE=(31.99, 0.950), params=17.1, cost=126, cost_in="256²",
         url="https://arxiv.org/abs/2405.14343"),
    dict(m="MaIR", v="CVPR 2025", y=2025, GoPro=(33.69, None), HIDE=(31.57, None), params=26.29, cost=49.29, cost_in="128²",
         url="https://arxiv.org/abs/2412.20066"),
    dict(m="ACL", v="CVPR 2025", y=2025, GoPro=(33.25, 0.964), HIDE=(None, None), params=4.6, cost=55, cost_in="n/s",
         url="https://openaccess.thecvf.com/content/CVPR2025/papers/Gu_ACL_Activating_Capability_of_Linear_Attention_for_Image_Restoration_CVPR_2025_paper.pdf"),
    dict(m="XYScanNet", v="CVPRW 2025", y=2025, GoPro=(33.91, 0.968), HIDE=(31.74, 0.947), params=None, cost=None, cost_in="",
         url="https://arxiv.org/abs/2412.10338"),
    dict(m="EAMamba", v="ICCV 2025", y=2025, GoPro=(33.58, 0.966), HIDE=(31.42, 0.944), params=25.3, cost=137, cost_in="256²",
         url="https://arxiv.org/abs/2506.22246"),
    dict(m="Concertormer", v="ICCV 2025", y=2025, GoPro=(34.42, 0.971), HIDE=(32.12, 0.951), params=None, cost=None, cost_in="",
         note="best of TLC / plain inference",
         url="https://openaccess.thecvf.com/content/ICCV2025/papers/Kuo_Efficient_Concertormer_for_Image_Deblurring_and_Beyond_ICCV_2025_paper.pdf"),
    dict(m="MB-TaylorFormer-XL V2", v="TPAMI 2025", y=2025, GoPro=(33.24, 0.963), HIDE=(31.66, 0.946), params=16.26, cost=141.9,
         cost_in="n/s", url="https://arxiv.org/abs/2501.04486"),
    dict(m="DiNAT-IR", v="arXiv 2025", y=2025, GoPro=(33.80, 0.967), HIDE=(31.57, 0.945), params=25.90, cost=45.62, cost_in="n/s",
         url="https://arxiv.org/abs/2507.17892"),
    dict(m="SFAFNet-B", v="arXiv 2025", y=2025, GoPro=(34.25, 0.971), HIDE=(31.92, 0.949), params=None, cost=None, cost_in="",
         url="https://arxiv.org/abs/2502.14209"),
    dict(m="DHNet-B", v="arXiv 2025", y=2025, GoPro=(34.75, 0.973), HIDE=(32.37, 0.953), params=None, cost=111, cost_in="n/s",
         url="https://arxiv.org/abs/2502.19677"),
    dict(m="AIBNet-L", v="arXiv 2025", y=2025, GoPro=(34.95, 0.974), HIDE=(32.41, 0.953), params=None, cost=456, cost_in="n/s",
         url="https://arxiv.org/abs/2502.20880"),
]
SOTA_DEFOCUS = [  # DPDD, single-image (centre view) input, combined 76 scenes
    dict(m="Restormer (S)", v="CVPR 2022", y=2022, psnr=25.98, ssim=0.811, mae=0.038, lpips=0.178, params=26.13,
         url="https://openaccess.thecvf.com/content/CVPR2022/papers/Zamir_Restormer_Efficient_Transformer_for_High-Resolution_Image_Restoration_CVPR_2022_paper.pdf"),
    dict(m="DRBNet", v="CVPR 2022", y=2022, psnr=25.725, ssim=0.791, mae=None, lpips=0.183, params=11.69,
         caveat="LFDOF pre-training", url="https://openaccess.thecvf.com/content/CVPR2022/papers/Ruan_Learning_to_Deblur_Using_Light_Field_Generated_and_Real_Defocus_CVPR_2022_paper.pdf"),
    dict(m="NRKNet", v="CVPR 2023", y=2023, psnr=26.109, ssim=0.810, mae=None, lpips=0.210, params=6.1,
         url="https://openaccess.thecvf.com/content/CVPR2023/papers/Quan_Neumann_Network_With_Recursive_Kernels_for_Single_Image_Defocus_Deblurring_CVPR_2023_paper.pdf"),
    dict(m="GRL-B (S)", v="CVPR 2023", y=2023, psnr=26.18, ssim=0.822, mae=0.037, lpips=0.168, params=None,
         url="https://openaccess.thecvf.com/content/CVPR2023/papers/Li_Efficient_and_Explicit_Modelling_of_Image_Hierarchies_for_Image_Restoration_CVPR_2023_paper.pdf"),
    dict(m="LaKDNet", v="arXiv 2023", y=2023, psnr=26.15, ssim=0.810, mae=None, lpips=0.155, params=17.7, url="https://arxiv.org/abs/2302.02234"),
    dict(m="Swintormer-S", v="arXiv 2024", y=2024, psnr=26.18, ssim=0.823, mae=0.034, lpips=0.176, params=None,
         url="https://arxiv.org/abs/2401.05907"),
    dict(m="SFHformer", v="ECCV 2024", y=2024, psnr=26.12, ssim=0.807, mae=0.037, lpips=0.222, params=None,
         url="https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/06190-supp.pdf"),
    dict(m="PPTformer", v="AAAI 2025", y=2025, psnr=26.13, ssim=0.807, mae=0.037, lpips=0.193, params=20.48,
         url="https://arxiv.org/abs/2503.14037"),
    dict(m="RDDM", v="AAAI 2025", y=2025, psnr=25.97, ssim=0.811, mae=0.037, lpips=0.166, params=None,
         caveat="diffusion model (2 steps)", url="https://ojs.aaai.org/index.php/AAAI/article/view/32303"),
    dict(m="ResFlow", v="CVPR 2025", y=2025, psnr=26.96, ssim=0.842, mae=0.034, lpips=0.131, params=None,
         caveat="generative flow model (4 steps)",
         url="https://openaccess.thecvf.com/content/CVPR2025/papers/Qin_Reversing_Flow_for_Image_Restoration_CVPR_2025_paper.pdf"),
    dict(m="TEAFormer", v="ICCV 2025", y=2025, psnr=26.45, ssim=0.828, mae=0.037, lpips=0.181, params=15.4,
         url="https://openaccess.thecvf.com/content/ICCV2025/papers/Hu_Enhancing_Image_Restoration_Transformer_via_Adaptive_Translation_Equivariance_ICCV_2025_paper.pdf"),
    dict(m="Blob-SIDD (Zhang et al.)", v="ICCV 2025", y=2025, psnr=26.651, ssim=0.835, mae=None, lpips=0.168, params=None,
         caveat="depth prior + 600 optimisation steps per image",
         url="https://openaccess.thecvf.com/content/ICCV2025/papers/Zhang_Performing_Defocus_Deblurring_by_Modeling_its_Formation_Process_ICCV_2025_paper.pdf"),
    dict(m="DiNAT-IR", v="arXiv 2025", y=2025, psnr=26.14, ssim=0.814, mae=0.037, lpips=None, params=None,
         url="https://arxiv.org/abs/2507.17892"),
    dict(m="FDIKP", v="arXiv 2025", y=2025, psnr=26.42, ssim=0.813, mae=0.0366, lpips=0.185, params=None,
         url="https://arxiv.org/abs/2508.12736"),
    dict(m="ErA", v="arXiv 2026", y=2026, psnr=26.687, ssim=0.815, mae=None, lpips=0.219, params=None,
         url="https://arxiv.org/abs/2606.06540"),
]
RAIN_SETS = ("Test100", "Rain100H", "Rain100L", "Test2800", "Test1200")
SOTA_DERAIN = [  # trained on Rain13K, the 5 standard test sets, Y channel
    dict(m="MPRNet", v="CVPR 2021", y=2021, r=[(30.27, .897), (30.41, .890), (36.40, .965), (33.64, .938), (32.91, .916)],
         avg=(32.73, .921), url="https://arxiv.org/abs/2102.02808"),
    dict(m="Restormer", v="CVPR 2022", y=2022, r=[(32.00, .923), (31.46, .904), (38.99, .978), (34.18, .944), (33.19, .926)],
         avg=(33.96, .935), url="https://arxiv.org/abs/2111.09881"),
    dict(m="X-Restormer", v="ECCV 2024", y=2024, r=[(32.21, .927), (32.09, .914), (39.10, .978), (33.93, .945), (32.31, .919)],
         avg=(33.93, .937), avg_src="avg*", url="https://arxiv.org/abs/2310.11881"),
    dict(m="MambaIR", v="ECCV 2024", y=2024, r=[(32.11, .924), (32.03, .905), (38.46, .976), (34.15, .945), (33.53, .930)],
         avg=(34.06, .936), src="3rd", note="retrained by the MDDA-former authors (3rd)", url="https://arxiv.org/abs/2411.07893"),
    dict(m="MB-TaylorFormer-L V2", v="TPAMI 2025", y=2025, r=[(31.88, .923), (31.57, .909), (39.03, .980), (34.20, .946), (33.31, .919)],
         avg=(34.00, .935), url="https://arxiv.org/abs/2501.04486"),
    dict(m="MDDA-former", v="CVIU 2025", y=2025, r=[(31.54, .923), (31.49, .905), (38.51, .978), (34.23, .945), (33.61, .932)],
         avg=(33.88, .937), url="https://arxiv.org/abs/2411.07893"),
    dict(m="DiNAT-IR", v="arXiv 2025", y=2025, r=[(31.22, .920), (31.26, .903), (38.93, .977), (33.91, .943), (32.31, .923)],
         avg=(33.53, .933), avg_src="avg*", url="https://arxiv.org/abs/2507.17892"),
    dict(m="PRISM", v="arXiv 2025", y=2025, r=[(30.29, .900), (30.06, .889), (36.88, .966), (33.73, .939), (32.56, .913)],
         avg=(32.70, .921), url="https://arxiv.org/abs/2509.26413"),
    dict(m="ENS-Deraining", v="arXiv 2026", y=2026, r=[(32.03, .923), (31.86, .912), (39.37, .979), (34.13, .944), (32.85, .923)],
         avg=(34.05, .936), url="https://arxiv.org/abs/2605.02794"),
]
SOTA_DENOISE = [  # SIDD sRGB validation blocks (1280 x 256^2), RGB
    dict(m="MPRNet", v="CVPR 2021", y=2021, psnr=39.71, ssim=0.958, params=15.7, url="https://arxiv.org/abs/2102.02808"),
    dict(m="Restormer", v="CVPR 2022", y=2022, psnr=40.02, ssim=0.960, params=26.1, url="https://arxiv.org/abs/2111.09881"),
    dict(m="NAFNet", v="ECCV 2022", y=2022, psnr=40.30, ssim=0.962, params=None, url="https://arxiv.org/abs/2204.04676"),
    dict(m="KBNet", v="arXiv 2023", y=2023, psnr=40.35, ssim=0.972, params=None, url="https://arxiv.org/abs/2303.02881"),
    dict(m="Xformer", v="ICLR 2024", y=2024, psnr=39.98, ssim=0.960, params=25.23, url="https://arxiv.org/abs/2303.06440"),
    dict(m="CGNet", v="TMLR 2024", y=2024, psnr=40.39, ssim=0.964, params=None, url="https://arxiv.org/abs/2401.15235"),
    dict(m="MambaIR", v="ECCV 2024", y=2024, psnr=39.89, ssim=0.960, params=None, url="https://arxiv.org/abs/2402.15648"),
    dict(m="SFHformer", v="ECCV 2024", y=2024, psnr=40.19, ssim=0.961, params=None,
         url="https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/06190-supp.pdf"),
    dict(m="MaIR", v="CVPR 2025", y=2025, psnr=39.92, ssim=0.960, params=26.29, url="https://arxiv.org/abs/2412.20066"),
    dict(m="EAMamba", v="ICCV 2025", y=2025, psnr=39.87, ssim=0.960, params=25.3, url="https://arxiv.org/abs/2506.22246"),
    dict(m="MB-TaylorFormer-L V2", v="TPAMI 2025", y=2025, psnr=40.11, ssim=0.960, params=7.29, url="https://arxiv.org/abs/2501.04486"),
    dict(m="MDDA-former", v="CVIU 2025", y=2025, psnr=39.96, ssim=0.960, params=25.92, url="https://arxiv.org/abs/2411.07893"),
    dict(m="MatIR", v="arXiv 2025", y=2025, psnr=40.08, ssim=0.963, params=None, url="https://arxiv.org/abs/2501.18401"),
    dict(m="DiNAT-IR", v="arXiv 2025", y=2025, psnr=39.89, ssim=0.960, params=None, url="https://arxiv.org/abs/2507.17892"),
    dict(m="ENS-Denoising", v="arXiv 2026", y=2026, psnr=40.04, ssim=0.961, params=None, url="https://arxiv.org/abs/2605.02794"),
    dict(m="TCD-Net", v="arXiv 2026", y=2026, psnr=40.48, ssim=0.965, params=None,
         caveat="fine-tunes a DF2K model on SIDD; protocol questioned", url="https://arxiv.org/abs/2603.01140"),
]
OURS = "SINA-Net v4 (ours)"


def _name(e: dict) -> str:
    tag = ""
    if e.get("src") == "3rd" or "3rd" in e.get("note", ""):
        tag += "†"
    if e.get("caveat"):
        tag += "‡"
    return e["m"] + tag


def build_sota_tables(results: Dict[str, dict], complexity: dict, config: Config, out_dir: str) -> List[ResultTable]:
    """Our measured numbers inserted into the literature tables (chronological, ours last)."""
    tabs = []
    tta = " + x8 self-ensemble" if config.use_self_ensemble_tta else ""
    mode = "all-in-one model" if len(config.train_tasks) > 1 else f"specialist ({config.train_tasks[0]})"
    params = complexity.get("params", float("nan")) / 1e6 if complexity else float("nan")
    s256 = (complexity or {}).get("sizes", {}).get("256x256", {})
    pm = s256.get("paper_macs", float("nan")) / 1e9 if s256 else float("nan")
    fl = s256.get("flops", float("nan")) / 1e9 if s256 else float("nan")
    common = [f"SINA-Net v4: {mode}{tta}; our numbers are MEASURED by this script with the same protocol "
              f"(full-resolution images); literature numbers are copied from each method's own paper table.",
              "† value only available in another paper's table (3rd-party); ‡ not like-for-like (see caveat); "
              "avg* = mean computed here from the per-set numbers. Cost = MACs or FLOPs as reported (G) at the "
              "stated input; n/s = input size not stated."]
    if "GoPro" in results:
        g, h = results.get("GoPro", {}), results.get("HIDE", {})
        rows = [[_name(e), e["v"], e["GoPro"][0], e["GoPro"][1], e["HIDE"][0], e["HIDE"][1], e["params"], e["cost"], e["cost_in"]]
                for e in sorted(SOTA_DEBLUR, key=lambda e: (e["y"], e["GoPro"][0]))]
        rows.append([OURS, "2026", g.get("psnr"), g.get("ssim"), h.get("psnr"), h.get("ssim"), params, pm, "256² (paper conv.)"])
        notes = common + [(f"SINA-Net complete FLOPs (every op) at 256²: {fl:.1f} G. " if np.isfinite(fl) else "") + "Caveats: " +
                          "; ".join(f"{e['m']}: {e['note']}" for e in SOTA_DEBLUR if e.get("note"))]
        tabs.append(ResultTable("Motion deblurring: trained on GoPro, tested on GoPro and HIDE (RGB PSNR / SSIM)",
                                ["Method", "Venue", "GoPro PSNR", "GoPro SSIM", "HIDE PSNR", "HIDE SSIM", "Params (M)",
                                 "Cost (G)", "Cost input"], rows, notes,
                                fmt={"GoPro PSNR": "{:.2f}", "GoPro SSIM": "{:.3f}", "HIDE PSNR": "{:.2f}", "HIDE SSIM": "{:.3f}",
                                     "Params (M)": "{:.2f}", "Cost (G)": "{:.1f}"},
                                best={"GoPro PSNR": "max", "GoPro SSIM": "max", "HIDE PSNR": "max", "HIDE SSIM": "max"},
                                highlight_rows=[len(rows) - 1]).save(os.path.join(out_dir, "sota_motion_deblurring")))
    if "DPDD" in results:
        d = results["DPDD"]
        rows = [[_name(e), e["v"], e["psnr"], e["ssim"], e["mae"], e["lpips"], e["params"], e.get("caveat", "")]
                for e in sorted(SOTA_DEFOCUS, key=lambda e: (e["y"], e["psnr"]))]
        rows.append([OURS, "2026", d.get("psnr"), d.get("ssim"), d.get("mae"), d.get("lpips"), params, "centre view only"])
        tabs.append(ResultTable("Single-image defocus deblurring on DPDD (combined 76 scenes, input = centre view)",
                                ["Method", "Venue", "PSNR", "SSIM", "MAE", "LPIPS", "Params (M)", "Caveat"], rows, common,
                                fmt={"PSNR": "{:.2f}", "SSIM": "{:.3f}", "MAE": "{:.4f}", "LPIPS": "{:.3f}", "Params (M)": "{:.2f}"},
                                best={"PSNR": "max", "SSIM": "max", "MAE": "min", "LPIPS": "min"},
                                highlight_rows=[len(rows) - 1]).save(os.path.join(out_dir, "sota_defocus_dpdd")))
    if any(s in results for s in RAIN_SETS):
        rows = []
        for e in sorted(SOTA_DERAIN, key=lambda e: (e["y"], e["avg"][0])):
            r = [_name(e) + ("*" if e.get("avg_src") else ""), e["v"]]
            for p, s in e["r"]:
                r += [p, s]
            rows.append(r + [e["avg"][0], e["avg"][1]])
        ours = [OURS, "2026"]
        ps, ss = [], []
        for sname in RAIN_SETS:
            rr = results.get(sname, {})
            ours += [rr.get("psnr"), rr.get("ssim")]
            if rr.get("psnr") is not None and np.isfinite(rr.get("psnr", np.nan)):
                ps.append(rr["psnr"]); ss.append(rr["ssim"])
        ours += [float(np.mean(ps)) if len(ps) == 5 else None, float(np.mean(ss)) if len(ss) == 5 else None]
        rows.append(ours)
        cols = ["Method", "Venue"] + [f"{s} {k}" for s in RAIN_SETS for k in ("PSNR", "SSIM")] + ["Avg PSNR", "Avg SSIM"]
        fmt = {c: ("{:.2f}" if "PSNR" in c else "{:.3f}") for c in cols[2:]}
        tabs.append(ResultTable("Image deraining: trained on Rain13K, Y-channel PSNR / SSIM on the five standard test sets",
                                cols, rows, common + ["Only methods reporting all five sets under the single-model "
                                                      "Rain13K protocol are listed (per-dataset models are excluded)."],
                                fmt=fmt, best={c: "max" for c in cols[2:]}, highlight_rows=[len(rows) - 1]
                                ).save(os.path.join(out_dir, "sota_deraining")))
    if "SIDD" in results:
        s = results["SIDD"]
        rows = [[_name(e), e["v"], e["psnr"], e["ssim"], e["params"], e.get("caveat", "")]
                for e in sorted(SOTA_DENOISE, key=lambda e: (e["y"], e["psnr"]))]
        rows.append([OURS, "2026", s.get("psnr"), s.get("ssim"), params, s.get("protocol_note", "")])
        tabs.append(ResultTable("Real image denoising on SIDD (sRGB validation blocks, RGB PSNR / SSIM)",
                                ["Method", "Venue", "PSNR", "SSIM", "Params (M)", "Caveat"], rows, common,
                                fmt={"PSNR": "{:.2f}", "SSIM": "{:.3f}", "Params (M)": "{:.2f}"},
                                best={"PSNR": "max", "SSIM": "max"}, highlight_rows=[len(rows) - 1]
                                ).save(os.path.join(out_dir, "sota_denoising_sidd")))
    return tabs


def fig_efficiency(results: Dict[str, dict], complexity: dict, out_path: str):
    """PSNR vs cost bubble chart (Restormer / NAFNet Fig. 1 style), GoPro, entries with a cost
    reported at 256^2 only (so the x axis is comparable)."""
    g = results.get("GoPro", {})
    s256 = (complexity or {}).get("sizes", {}).get("256x256", {})
    pts = [(e["m"], e["cost"], e["GoPro"][0], e["params"]) for e in SOTA_DEBLUR
           if e.get("cost") and e.get("cost_in") == "256²" and e.get("params")]
    if not pts or not g or not s256:
        return
    set_paper_style()
    fig, ax = plt.subplots(figsize=(7.4, 5.2))
    for n, c, p, pa in pts:
        ax.scatter(c, p, s=25 + 6 * pa, alpha=0.55, color="#5B8DB8", edgecolor="#1F3A5F")
        ax.annotate(n, (c, p), fontsize=7, xytext=(5, 3), textcoords="offset points")
    ours_c = s256["paper_macs"] / 1e9
    ax.scatter(ours_c, g["psnr"], s=25 + 6 * complexity["params"] / 1e6, marker="*", color=PALETTE["ours"],
               edgecolor="black", zorder=5)
    ax.annotate(f"{OURS}\n(complete FLOPs {s256['flops'] / 1e9:.0f} G)", (ours_c, g["psnr"]), fontsize=8,
                xytext=(6, -14), textcoords="offset points", color=PALETTE["ours"], fontweight="bold")
    ax.set_xscale("log"); ax.set_xlabel("reported cost at 256x256 (G, log scale)"); ax.set_ylabel("GoPro PSNR (dB)")
    ax.set_title("Accuracy vs cost on GoPro (bubble area ~ parameters)"); ax.grid(alpha=0.3, which="both")
    _tight(fig)
    save_fig(fig, out_path)


# ==============================================================================
# 17. ABLATION STUDY: test-time knock-outs (paired, with statistics) + training ablations
# ==============================================================================
KNOCKOUTS = {
    "no_wiener": "Cohen-class Wiener gate bypassed (identity)",
    "no_homeostasis": "attention temperature fixed to T = 1 (no homeostasis)",
    "gate_mean": "coherence gate replaced by its spatial mean (no selectivity)",
    "gate_open": "coherence gate forced to 1 (plain additive skip)",
    "no_film": "degradation FiLM disabled (identity modulation)",
}


@contextlib.contextmanager
def knockout(model: nn.Module, name: Optional[str]):
    """Test-time knock-out of one component (restored on exit). name=None is a no-op."""
    saved = []

    def put(m, a, v):
        saved.append((m, a, getattr(m, a)))
        setattr(m, a, v)

    try:
        if name:
            for m in model.modules():
                if name == "no_wiener" and isinstance(m, CohenClassSpectralWienerUnit):
                    put(m, "bypass", True)
                elif name == "no_homeostasis" and isinstance(m, KLDivergenceGuidedDiNA) and m.homeostasis:
                    put(m, "force_unit_temperature", True)
                elif name == "gate_mean" and isinstance(m, SpectralCoherenceGatedFusion):
                    put(m, "gate_mode", "mean")
                elif name == "gate_open" and isinstance(m, SpectralCoherenceGatedFusion):
                    put(m, "gate_mode", "open")
                elif name == "no_film" and isinstance(m, DegradationConditioner):
                    put(m, "enabled", False)
        yield len(saved)
    finally:
        for m, a, v in reversed(saved):
            setattr(m, a, v)


PRIMARY_TEST_SET = {"GoPro": "GoPro", "DPDD": "DPDD", "SIDD": "SIDD", "Rain13K": "Rain100H"}


class KnockoutAblation:
    """Every variant is evaluated on the SAME images as the full model, in the same numeric mode
    (eager, same AMP dtype), so differences are paired. Reported: mean dPSNR with a 95% bootstrap
    CI, the fraction of images that got worse and a Wilcoxon signed-rank p-value. A knock-out
    measures how much the TRAINED network relies on a component (the training ablation measures
    whether training with it helps); both are reported, and neither is extrapolated."""

    def __init__(self, config: Config, model: nn.Module, inferencer: ModelInferencer):
        self.cfg, self.model, self.inf = config, model, inferencer

    def _variants(self, foreign: Optional[torch.Tensor]) -> List[Tuple[str, str]]:
        v = [("full", "complete model (reference)")]
        has = lambda cls, pred=lambda m: True: any(isinstance(m, cls) and pred(m) for m in self.model.modules())
        if has(CohenClassSpectralWienerUnit):
            v.append(("no_wiener", KNOCKOUTS["no_wiener"]))
        if has(KLDivergenceGuidedDiNA, lambda m: m.homeostasis):
            v.append(("no_homeostasis", KNOCKOUTS["no_homeostasis"]))
        if has(SpectralCoherenceGatedFusion):
            v += [("gate_mean", KNOCKOUTS["gate_mean"]), ("gate_open", KNOCKOUTS["gate_open"])]
        if has(DegradationConditioner):
            v += [("no_film", KNOCKOUTS["no_film"]),
                  ("mean_signature", "signature of the 'average' training degradation (standardised 0)")]
            v.append(("foreign_signature", "signature of a DIFFERENT degradation type" if foreign is not None
                      else "signature of another image of the same test set"))
            v.append(("tiled_per_tile_sig", "256-px tiles, each with its OWN signature (v3-style)"))
        v.append(("tiled_shared_sig", "256-px tiles sharing the full-image signature (v4 inference)"))
        if self.cfg.ablation_tta:
            v.append(("tta_x8", "x8 dihedral self-ensemble"))
        return v

    def _foreign_signature(self, tests: Dict[str, Dataset], name: str) -> Optional[torch.Tensor]:
        mine = TASK_OF_TEST.get(name)
        for other, ds in tests.items():
            if TASK_OF_TEST.get(other) != mine and len(ds) > 0:
                with torch.no_grad():
                    d, _, _ = ds[0]
                    return self.model.compute_signature(d.unsqueeze(0).to(self.cfg.device))
        return None

    @torch.no_grad()
    def _predict(self, variant: str, x: torch.Tensor, foreign: Optional[torch.Tensor], other: torch.Tensor) -> torch.Tensor:
        inf = self.inf
        tile = 256 if min(x.shape[-2:]) > 256 else max(64, (min(x.shape[-2:]) // 2) // 8 * 8)
        if variant in KNOCKOUTS:
            with knockout(self.model, variant):
                return inf.predict(x)
        if variant == "mean_signature":
            std = self.model.degradation_conditioner.standardize
            return inf.predict(x, signature=std.mean.view(1, -1).clone())
        if variant == "foreign_signature":
            return inf.predict(x, signature=foreign if foreign is not None else self.model.compute_signature(other))
        if variant == "tiled_shared_sig":
            return inf._tiled(x, inf._signature(x), tile)
        if variant == "tiled_per_tile_sig":
            return inf._tiled(x, None, tile)
        if variant == "tta_x8":
            return inf._self_ensemble_predict(x)
        return inf.predict(x)

    def run(self, tests: Dict[str, Dataset], out_tables: str, out_figs: str) -> dict:
        cfg = self.cfg
        sets = list(cfg.ablation_sets) or [PRIMARY_TEST_SET[t] for t in cfg.train_tasks if PRIMARY_TEST_SET.get(t) in tests]
        out = {}
        was_compiled = self.inf.compiled
        self.inf.compiled = False  # knock-outs flip Python flags: compare everything eagerly
        try:
            for name in sets:
                ds = tests.get(name)
                if ds is None or len(ds) == 0:
                    continue
                proto = EVAL_PROTOCOL.get(name, dict(quantize=True, y_channel=False))
                idxs = _even(len(ds), cfg.ablation_max_images)
                foreign = self._foreign_signature(tests, name)
                variants = self._variants(foreign)
                metr = {v: {"psnr": [], "ssim": [], "ms": []} for v, _ in variants}
                for k, i in enumerate(tqdm(idxs, desc=f"Ablation {name}", **_tqdm_kw())):
                    d, c, _ = ds[i]
                    d, c = d.unsqueeze(0).to(cfg.device), c.unsqueeze(0).to(cfg.device)
                    o, _, _ = ds[idxs[(k + len(idxs) // 2) % len(idxs)]]
                    other = o.unsqueeze(0).to(cfg.device)
                    with eager_mode(self.model):
                        for v, _ in variants:
                            self.inf._sync()
                            t0 = time.perf_counter()
                            p = self._predict(v, d, foreign, other).clamp(0, 1)
                            self.inf._sync()
                            m = RestorationMetrics.compute(p, c, **proto)
                            metr[v]["psnr"].append(m["psnr"]); metr[v]["ssim"].append(m["ssim"])
                            metr[v]["ms"].append((time.perf_counter() - t0) * 1000)
                full = np.array(metr["full"]["psnr"])
                rows, stats = [], {}
                for v, desc in variants:
                    ps = np.array(metr[v]["psnr"])
                    diff = ps - full
                    mean, lo, hi = bootstrap_ci(diff)
                    p = wilcoxon_p(diff) if v != "full" else float("nan")
                    if v == "full":
                        verdict = "reference"
                    elif v.startswith("tiled_shared"):
                        verdict = "consistent with full-image inference" if abs(mean) < 0.05 else "tiling changes the output"
                    elif v == "tta_x8":
                        verdict = "TTA helps" if effect_verdict(mean, lo, hi) > 0 else "no significant TTA gain"
                    elif effect_verdict(mean, lo, hi) < 0:
                        verdict = "network RELIES on it (significant drop)"
                    elif effect_verdict(mean, lo, hi) > 0:
                        verdict = "removing it HELPS here"
                    else:
                        verdict = "no significant effect"
                    stats[v] = {"psnr": float(ps.mean()), "ssim": float(np.mean(metr[v]["ssim"])), "delta": mean,
                                "ci": (lo, hi), "worse_frac": float(np.mean(diff < 0)) if v != "full" else 0.0,
                                "p": p, "ms": float(np.mean(metr[v]["ms"])), "verdict": verdict, "desc": desc}
                    rows.append([v, desc, stats[v]["psnr"], stats[v]["ssim"],
                                 None if v == "full" else f"{mean:+.3f} [{lo:+.3f}, {hi:+.3f}]",
                                 None if v == "full" else 100 * stats[v]["worse_frac"], p, stats[v]["ms"], verdict])
                ResultTable(f"Test-time knock-out ablation on {name} ({len(idxs)} images, evenly spaced; paired, eager)",
                            ["Variant", "What changes", "PSNR", "SSIM", "dPSNR vs full [95% CI]", "Worse on % img",
                             "Wilcoxon p", "ms / img", "Verdict"], rows,
                            notes=["Knock-outs are applied to the TRAINED network without retraining: they measure "
                                   "reliance on a component, not the benefit of training with it (see the training "
                                   "ablation table for that).", f"Protocol: {proto}."],
                            fmt={"PSNR": "{:.3f}", "SSIM": "{:.4f}", "Worse on % img": "{:.0f}", "Wilcoxon p": "{:.2g}",
                                 "ms / img": "{:.1f}"}, highlight_rows=[0]
                            ).save(os.path.join(out_tables, f"ablation_knockout_{name}"))
                self._forest(name, stats, os.path.join(out_figs, f"ablation_knockout_{name}.png"))
                out[name] = stats
        finally:
            self.inf.compiled = was_compiled
        return out

    @staticmethod
    def _forest(name: str, stats: dict, path: str):
        items = [(k, v) for k, v in stats.items() if k != "full"]
        if not items:
            return
        set_paper_style()
        fig, ax = plt.subplots(figsize=(8.4, 0.5 * len(items) + 1.6))
        for i, (k, v) in enumerate(items):
            lo, hi = v["ci"]
            ev = effect_verdict(v["delta"], lo, hi)
            col = PALETTE["bad"] if ev < 0 else (PALETTE["good"] if ev > 0 else PALETTE["neutral"])
            ax.errorbar(v["delta"], i, xerr=[[v["delta"] - lo], [hi - v["delta"]]], fmt="o", color=col, capsize=4, ms=7)
            ax.text(max(hi, v["delta"]) + 0.01, i, f"  {v['delta']:+.3f} dB", va="center", fontsize=8)
        ax.axvline(0, color="#333333", lw=1)
        ax.set_yticks(range(len(items))); ax.set_yticklabels([f"{k}\n({v['desc'][:44]})" for k, v in items], fontsize=7)
        ax.invert_yaxis()
        ax.set_xlabel("dPSNR vs full model (dB), mean with 95% bootstrap CI")
        ax.set_title(f"Knock-out ablation on {name}: red = significant drop, grey = no effect")
        _tight(fig)
        save_fig(fig, path)


TRAIN_ABLATIONS = {
    "full": ({}, "SINA-Net v4 (all components)"),
    "no_wiener": ({"use_wiener": False}, "without the Cohen-class Wiener gate"),
    "no_homeostasis": ({"use_homeostasis": False}, "plain softmax neighbourhood attention"),
    "no_coherence": ({"use_coherence_fusion": False}, "additive skips instead of coherence gates"),
    "no_conditioning": ({"use_degradation_conditioning": False}, "no degradation signature / FiLM"),
    "no_radial_loss": ({"lambda_radial": 0.0}, "without the radial spectral loss"),
}


def run_training_ablation(config: Config, train_sets: List[ImageRestorationDataset], val_sets: List[ImageRestorationDataset],
                          tests: Dict[str, Dataset]) -> dict:
    """Retrains every variant from scratch with an IDENTICAL short schedule (same seed, data order,
    patch size, batch, iterations) and evaluates each on the same test images. Resumable across
    Colab sessions: finished variants are stored in <ablation_dir>/results.json on Drive."""
    task = config.ablation_task or config.train_tasks[0]
    tr = [d for d in train_sets if d.task == task and len(d) > 0]
    va = [d for d in val_sets if d.task == task and len(d) > 0]
    test_name = PRIMARY_TEST_SET.get(task)
    if not tr or test_name not in tests:
        print(f"  training ablation skipped: no training data or test set for {task}.")
        return {}
    os.makedirs(config.ablation_dir, exist_ok=True)
    res_path = os.path.join(config.ablation_dir, "results.json")
    try:
        with open(res_path) as f:
            done = json.load(f)
    except (OSError, ValueError):
        done = {}
    for variant in config.ablation_variants:
        if variant in done and done[variant].get("complete"):
            continue
        overrides, desc = TRAIN_ABLATIONS[variant]
        vc = copy.deepcopy(config)
        for k, v in overrides.items():
            setattr(vc, k, v)
        vc.total_iters = config.ablation_iters
        vc.warmup_iters = min(config.warmup_iters, max(1, config.ablation_iters // 20))
        vc.progressive_schedule = [(0.0, config.ablation_patch, config.ablation_batch)]
        vc.val_every = config.ablation_iters
        vc.save_every = max(100, config.ablation_iters // 10)
        vc.checkpoint_dir = os.path.join(config.ablation_dir, variant)
        vc.resume_from = None
        vc.lambda_lpips = 0.0
        print(f"\n[ablation] training variant '{variant}' ({desc}) for {vc.total_iters} iterations on {task}")
        seed_everything(config.seed)
        model = SINANet(vc).to(vc.device)
        trainer = ModelTrainer(vc, model, tr, va, RestorationLoss(vc).to(vc.device), tag=f"ablation:{variant}")
        trainer.train()
        complete = trainer.iteration >= vc.total_iters
        entry = {"desc": desc, "iterations": trainer.iteration, "complete": complete,
                 "params": sum(p.numel() for p in model.parameters())}
        if complete and DIST.is_main:
            ev = trainer.eval_model()
            inf = ModelInferencer(vc, ev, compile_ok=False)
            sub = torch.utils.data.Subset(tests[test_name], _even(len(tests[test_name]), config.ablation_eval_images))
            prev = vc.num_visualization_samples
            vc.num_visualization_samples = 0
            r = inf.inference(sub, test_name)
            vc.num_visualization_samples = prev
            frer = 10 * np.log10(np.sum([x["band_in"] for x in r["records"]], 0) /
                                 np.maximum(np.sum([x["band_out"] for x in r["records"]], 0), 1e-14))
            entry.update(psnr=r["psnr"], ssim=r["ssim"], in_psnr=r["in_psnr"], per_image=[x["psnr"] for x in r["records"]],
                         frer_high=float(frer[N_ERROR_BANDS // 2:].mean()), frer_low=float(frer[:N_ERROR_BANDS // 4].mean()),
                         paper_macs=ComplexityProfiler(vc, ev).paper_macs(256, 256) / 1e9)
        done[variant] = entry
        if DIST.is_main:
            with open(res_path, "w") as f:
                json.dump(done, f, indent=1)
        del trainer, model
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        if not complete:
            print("[ablation] session budget reached: re-run to continue the training ablation where it stopped.")
            break
    return done


def training_ablation_table(done: dict, config: Config, out_tables: str, out_figs: str):
    if not done:
        return
    full = done.get("full", {})
    rows, labels, deltas = [], [], []
    for v in config.ablation_variants:
        e = done.get(v)
        if not e:
            continue
        ci = None
        if e.get("per_image") and full.get("per_image") and len(e["per_image"]) == len(full["per_image"]) and v != "full":
            diff = np.array(e["per_image"]) - np.array(full["per_image"])
            m, lo, hi = bootstrap_ci(diff)
            ci = f"{m:+.3f} [{lo:+.3f}, {hi:+.3f}]"
            labels.append(v); deltas.append((m, lo, hi))
        rows.append([v, e.get("desc"), e.get("params", 0) / 1e6, e.get("paper_macs"), e.get("psnr"), e.get("ssim"), ci,
                     e.get("frer_high"), e.get("frer_low"), e.get("iterations"), "done" if e.get("complete") else "PARTIAL"])
    task = config.ablation_task or config.train_tasks[0]
    ResultTable(f"Training ablation on {task} (each variant retrained from scratch, identical schedule: "
                f"{config.ablation_iters} it, {config.ablation_patch}px, batch {config.ablation_batch})",
                ["Variant", "Description", "Params (M)", "MACs@256 (G)", "PSNR", "SSIM", "dPSNR vs full [95% CI]",
                 "FRER high-freq (dB)", "FRER low-freq (dB)", "Iterations", "Status"], rows,
                notes=["Short schedule: absolute PSNR is below the full 300K-iteration model; differences between rows "
                       "are the quantity of interest (paired over the same test images).",
                       "FRER = frequency-resolved error reduction (exact Parseval split of the MSE): high = upper half of "
                       "the frequency band, low = lowest quarter."],
                fmt={"Params (M)": "{:.3f}", "MACs@256 (G)": "{:.2f}", "PSNR": "{:.3f}", "SSIM": "{:.4f}",
                     "FRER high-freq (dB)": "{:+.2f}", "FRER low-freq (dB)": "{:+.2f}"},
                best={"PSNR": "max", "SSIM": "max"}, highlight_rows=[0]).save(os.path.join(out_tables, "ablation_training"))
    if deltas:
        KnockoutAblation._forest(f"{task} (training ablation)",
                                 {k: {"delta": m, "ci": (lo, hi), "desc": TRAIN_ABLATIONS[k][1]} for k, (m, lo, hi) in zip(labels, deltas)},
                                 os.path.join(out_figs, "ablation_training.png"))


# ==============================================================================
# 18. CLAIMS AUDIT: every novelty claim paired with the measurement that tests it
# ==============================================================================
@torch.no_grad()
def signature_consistency(config: Config, model: nn.Module, tests: Dict[str, Dataset], n: int = 12) -> dict:
    """Cosine similarity between the signature of a 128-px centre crop and of the full image of the
    same test image: native-resolution Welch (v4) vs whole-image pooling to 64x64 (v3). A resolution-
    consistent signature must describe a patch and its full image alike (cause R4)."""
    sig = model.degradation_signature
    k = sig.n_bins
    v4, v3 = [], []
    for name, ds in tests.items():
        for i in _even(len(ds), n):
            d, _, _ = ds[i]
            x = d.unsqueeze(0).to(config.device)
            H, W = x.shape[-2:]
            if min(H, W) < 256:
                continue
            c = x[..., (H - 128) // 2:(H - 128) // 2 + 128, (W - 128) // 2:(W - 128) // 2 + 128]
            cos = lambda a, b: float(F.cosine_similarity(a[:, :k], b[:, :k]).mean())
            v4.append(cos(sig(x), sig(c)))
            v3.append(cos(v3_style_signature(x, sig), v3_style_signature(c, sig)))
    if not v4:
        return {}
    m4, m3 = bootstrap_ci(v4), bootstrap_ci(v3)
    return {"v4": m4, "v3": m3, "n": len(v4), "diff": bootstrap_ci(np.array(v4) - np.array(v3))}


def claims_audit(bundle: dict, config: Config, out_tables: str) -> List[list]:
    rows = []

    def add(claim, evidence, status):
        rows.append([claim, evidence, status])

    ko = bundle.get("knockout", {})
    first = next(iter(ko.values()), {}) if ko else {}
    interp = list(bundle.get("suite", {}).get("interpretability", {}).values())
    tr = bundle.get("training_ablation", {})
    res = bundle.get("results", {})

    def ko_claim(key, claim):
        if key in first:
            s = first[key]
            lo, hi = s["ci"]
            ev = effect_verdict(s["delta"], lo, hi)
            st = "SUPPORTED" if ev < 0 else ("CONTRADICTED" if ev > 0 else "NOT SUPPORTED (no significant effect)")
            add(claim, f"knock-out {key}: dPSNR {s['delta']:+.3f} dB [{lo:+.3f}, {hi:+.3f}], worse on "
                       f"{100 * s['worse_frac']:.0f}% of images, p = {s['p']:.2g}", st)
        else:
            add(claim, "knock-out not run", "NOT TESTED")

    gains = [(n, r) for n, r in res.items() if r.get("records")]
    if gains:
        g = np.concatenate([[x["gain"] for x in r["records"]] for _, r in gains])
        m, lo, hi = bootstrap_ci(g)
        add("The network restores (it is not an identity map, v3 failure R1/R4)",
            f"mean gain over the input on {len(g)} test images: {m:+.2f} dB [{lo:+.2f}, {hi:+.2f}]",
            "SUPPORTED" if effect_verdict(m, lo, hi) > 0 else "NOT SUPPORTED")
    ko_claim("no_wiener", "The Cohen-class Wiener gate is used by the trained network")
    ko_claim("no_homeostasis", "Entropy homeostasis matters for the trained attention")
    homeo = [s for s in interp if "homeo_toward" in s]
    if homeo:
        tw = float(np.mean([s["homeo_toward"] for s in homeo]))
        db = float(np.mean([s["homeo_dev_before"] for s in homeo])); da = float(np.mean([s["homeo_dev_after"] for s in homeo]))
        add("The homeostatic temperature is NEGATIVE feedback: it moves each row's entropy toward the head's set point",
            f"{100 * tw:.1f}% of attention rows moved toward tau_h; mean |KL_n - tau_h| {db:.3f} before T -> {da:.3f} after T",
            "SUPPORTED" if (tw > 0.5 and da < db) else "NOT SUPPORTED")
    col = [s for s in interp if "collapse_rate_off" in s]
    if col:
        on = float(np.mean([s["collapse_rate_on"] for s in col])); off = float(np.mean([s["collapse_rate_off"] for s in col]))
        st = ("INCONCLUSIVE (no collapse with or without homeostasis)" if max(on, off) < 1e-3 else
              "SUPPORTED" if on < 0.8 * off else "NOT SUPPORTED")
        add("Homeostasis prevents attention collapse (v3 failure R6)",
            f"rows with max weight > 0.9: {100 * on:.2f}% with learned T vs {100 * off:.2f}% with T = 1", st)
    gstd = [np.mean(list(s["gate_spatial_std"].values())) for s in interp if s.get("gate_spatial_std")]
    if gstd:
        add("Coherence gates are spatially selective (not a constant skip weight)",
            f"mean spatial std of the gates = {np.mean(gstd):.3f} (0 = constant)",
            "SUPPORTED" if np.mean(gstd) > 0.02 else "NOT SUPPORTED")
    ko_claim("gate_mean", "The spatial pattern of the coherence gate carries information")
    ko_claim("no_film", "Degradation-aware FiLM conditioning is used")
    ko_claim("foreign_signature", "The conditioning is degradation-SPECIFIC (a wrong signature hurts)")
    pr = bundle.get("suite", {}).get("probe", {})
    for key, lab in (("signature", "analytic signature"), ("embedding", "learned embedding")):
        if key in pr:
            r = pr[key]
            ok = r["balanced_accuracy"] >= max(0.6, 2 * r["chance"])
            add(f"The {lab} identifies the degradation type",
                f"held-out balanced accuracy {100 * r['balanced_accuracy']:.1f}% over {len(pr['classes'])} classes "
                f"(chance {100 * r['chance']:.0f}%)", "SUPPORTED" if ok else "NOT SUPPORTED")
    sc = bundle.get("signature_consistency", {})
    if sc:
        d = sc["diff"]
        add("The Welch signature is resolution-consistent (v3 failure R4)",
            f"cos(crop, full image): v4 {sc['v4'][0]:.3f} vs v3-style pooled {sc['v3'][0]:.3f}; difference "
            f"{d[0]:+.3f} [{d[1]:+.3f}, {d[2]:+.3f}] over {sc['n']} images", "SUPPORTED" if d[1] > 0 else "NOT SUPPORTED")
    if "tiled_shared_sig" in first:
        s = first["tiled_shared_sig"]
        t = first.get("tiled_per_tile_sig")
        ev = f"tiled (shared signature) vs full image: {s['delta']:+.3f} dB"
        if t:
            ev += f"; per-tile signatures: {t['delta']:+.3f} dB"
        ok = abs(s["delta"]) < 0.05 and (t is None or abs(s["delta"]) <= abs(t["delta"]) + 1e-9)
        add("Tiled inference with one shared signature is consistent (seam-free)", ev, "SUPPORTED" if ok else "NOT SUPPORTED")
    for key, claim in (("no_wiener", "Training WITH the Wiener gate improves accuracy"),
                       ("no_homeostasis", "Training WITH entropy homeostasis improves accuracy"),
                       ("no_coherence", "Training WITH coherence-gated skips improves accuracy"),
                       ("no_conditioning", "Training WITH degradation conditioning improves accuracy"),
                       ("no_radial_loss", "The radial spectral loss improves high-frequency recovery")):
        full, e = tr.get("full", {}), tr.get(key, {})
        if full.get("per_image") and e.get("per_image") and len(full["per_image"]) == len(e["per_image"]):
            m, lo, hi = bootstrap_ci(np.array(full["per_image"]) - np.array(e["per_image"]))
            ev = f"full - ablated = {m:+.3f} dB [{lo:+.3f}, {hi:+.3f}]"
            if key == "no_radial_loss" and full.get("frer_high") is not None:
                ev += f"; high-freq FRER {full['frer_high']:+.2f} vs {e['frer_high']:+.2f} dB"
            v = effect_verdict(m, lo, hi)
            add(claim, ev, "SUPPORTED" if v > 0 else ("CONTRADICTED" if v < 0 else "NOT SUPPORTED (no significant effect)"))
        elif tr:
            add(claim, f"variant '{key}' not trained yet (add it to ablation_variants / let the ablation finish)", "NOT TESTED")
        else:
            add(claim, "training ablation not run (set run_training_ablation=True)", "NOT TESTED")
    ResultTable("Claims audit: each novelty claim and the measurement that tests it", ["Claim", "Evidence (measured)", "Status"],
                rows, notes=[f"SUPPORTED = the 95% CI excludes 'no effect' in the claimed direction AND |effect| > "
                             f"{PRACTICAL_DB} dB; NOT SUPPORTED = "
                             "no significant effect; CONTRADICTED = significant effect in the opposite direction; "
                             "NOT TESTED = the experiment was not run in this session."]
                ).save(os.path.join(out_tables, "claims_audit"))
    return rows


# ==============================================================================
# 19. REPORT
# ==============================================================================
def write_report(config: Config, bundle: dict):
    """REPORT.md on Drive: environment, all tables (in order of creation) and an index of figures."""
    lines = ["# SINA-Net v4 (Colab edition): results report", "",
             f"Generated {time.strftime('%Y-%m-%d %H:%M:%S')} | tasks {config.train_tasks} | device {config.device}", ""]
    env = bundle.get("env", {})
    if env:
        lines += ["## Environment", ""] + [f"- **{k}**: {v}" for k, v in env.items()] + [""]
    lines += ["## Tables", ""]
    for it in REPORT_ITEMS:
        if it["kind"] == "table":
            lines += [it["md"], "", f"_files: `{os.path.relpath(it['stem'], config.project_root)}.(md|tex|csv|png)`_", ""]
    lines += ["## Figures", ""]
    for dp, _, fs in os.walk(config.figures_dir):
        pngs = sorted(f for f in fs if f.endswith(".png"))
        if pngs and "singles" not in dp and "per_layer" not in dp and "per_head" not in dp:
            rel = os.path.relpath(dp, config.project_root)
            lines.append(f"- `{rel}/`: " + ", ".join(pngs[:12]) + (" ..." if len(pngs) > 12 else ""))
    path = os.path.join(config.project_root, "REPORT.md")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"\nReport written to {path}")
    return path


def show_in_notebook(paths: Sequence[str], width: int = 1100):
    """Displays key figures inline when running inside a notebook kernel (Colab)."""
    try:
        from IPython import get_ipython
        from IPython.display import Image as _Img, display
        if get_ipython() is None:
            return
        for p in paths:
            if p and os.path.isfile(p):
                display(_Img(filename=p, width=width))
    except Exception:
        pass


# ==============================================================================
# 20. DATASET CONSTRUCTION
# ==============================================================================
TASK_PATHS = {"GoPro": "path_gopro", "DPDD": "path_dpdd", "Rain13K": "path_rain13k", "SIDD": "path_sidd"}
_TASK_KEYWORDS = {
    "GoPro": ("gopro",), "HIDE": ("hide",), "SIDD": ("sidd",),
    "DPDD": ("dpdd", "dd_dp", "defocus", "dual_pixel", "dual-pixel", "dualpixel"),
    "Rain13K": ("rain13k", "derain", "rain100", "rain1400"),
}
_LEAF_DIRS = {"input", "target", "blur", "sharp", "source", "gt", "groundtruth", "noisy", "clean", "rain",
              "norain", "inputc", "inputl", "inputr", "blur_gamma", "data"}
_ROOT_CACHE: Dict[Tuple[str, str], str] = {}


def _walk_limited(roots: Sequence[str], max_depth: int = 7):
    """os.walk over the search roots without descending into image folders."""
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        base = os.path.abspath(root).rstrip(os.sep).count(os.sep)
        for dp, dirnames, filenames in os.walk(root, followlinks=True):
            depth = os.path.abspath(dp).count(os.sep) - base
            yield dp, dirnames, filenames, depth
            if depth >= max_depth or len(filenames) > 200:
                dirnames[:] = []
            else:
                dirnames[:] = sorted(d for d in dirnames if d.lower() not in _LEAF_DIRS)


def _input_listing(roots: Sequence[str], depth: int = 4, limit: int = 60) -> str:
    out = []
    for dp, _, _, d in _walk_limited(roots, max_depth=depth):
        if 0 < d <= depth:
            out.append("    " + dp)
        if len(out) >= limit:
            out.append("    ...")
            break
    return "\n".join(out) if out else "    (nothing found)"


def resolve_task_root(task: str, configured: str, split: str, config: Config) -> str:
    """Returns a folder that really contains `task` pairs for `split`: the configured one
    if it works, otherwise the best match found under Config.search_roots by folder name
    (the one with the most pairs). Prints what it did, or the input listing if nothing fits."""
    key = (task, configured or "")
    if key in _ROOT_CACHE:
        return _ROOT_CACHE[key]
    kw = dict(seed=config.seed, sidd_holdout=config.sidd_holdout_fraction)
    if configured and os.path.isdir(configured) and discover_task_pairs(task, configured, split, **kw)[0]:
        _ROOT_CACHE[key] = configured
        return configured
    why = "does not exist" if not (configured and os.path.isdir(configured)) else "contains no usable pairs"
    best, best_n = None, 0
    for dp, dirnames, _, depth in _walk_limited(config.search_roots):
        if depth > 0 and any(k in os.path.basename(dp).lower() for k in _TASK_KEYWORDS.get(task, ())):
            dirnames[:] = []  # discovery walks the whole match
            n = len(discover_task_pairs(task, dp, split, **kw)[0])
            if n > best_n:
                best, best_n = dp, n
    if best:
        print(f"  [{task}] configured path '{configured}' {why}; auto-detected '{best}' "
              f"({best_n} {split} pairs).")
    else:
        print(f"  [{task}] NOT FOUND: '{configured}' {why}, and no '{task}' folder with image pairs was found under "
              f"{list(config.search_roots)}. Enable download_datasets or set Config."
              f"{TASK_PATHS.get(task, 'path_' + task.lower())}. Folders currently available:\n"
              f"{_input_listing(config.search_roots)}")
    _ROOT_CACHE[key] = best or configured
    return _ROOT_CACHE[key]


def _sidd_official_available(config: Config) -> bool:
    return load_sidd_validation_blocks(config.path_sidd_val, config.search_roots) is not None


def build_datasets(config: Config):
    """Per-task train/val datasets from the FULL training splits (no truncation),
    plus a pair audit that prints the input PSNR each task starts from. DPDD validates on its
    official val split; SIDD trains on all 320 SIDD-Medium pairs when the official validation
    blocks (its test set) are available."""
    train_sets, val_sets, input_psnr = [], [], {}
    for tid, task in enumerate(config.train_tasks):
        root = resolve_task_root(task, getattr(config, TASK_PATHS[task]), "train", config)
        setattr(config, TASK_PATHS[task], root)
        hold = 0.0 if (task == "SIDD" and _sidd_official_available(config)) else config.sidd_holdout_fraction
        pairs, _ = discover_task_pairs(task, root, "train", seed=config.seed, sidd_holdout=hold)
        official_val = discover_task_pairs(task, root, "val", seed=config.seed)[0] if task == "DPDD" else []
        if official_val:
            tr, va = pairs, [official_val[i] for i in _even(len(official_val), config.max_val_per_task)]
        else:
            tr, va = split_train_val(pairs, config.val_fraction, config.seed, config.max_val_per_task)
        tr = build_tile_cache(tr, config, task)
        ds_tr = ImageRestorationDataset(root, task, "train", patch_size=128, pairs=tr, task_id=tid)
        ds_va = ImageRestorationDataset(root, task, "val", pairs=va, task_id=tid, val_crop=config.val_crop)
        ip = audit_pairs(ds_tr)
        if ip is not None:
            input_psnr[task] = ip
        train_sets.append(ds_tr)
        val_sets.append(ds_va)
    found = [f"{d.task} ({len(d)})" for d in train_sets if len(d)]
    missing = [d.task for d in train_sets if not len(d)]
    print(f"\nTraining tasks: {', '.join(found) or 'NONE'}" +
          (f"  |  MISSING (training continues without them): {', '.join(missing)}" if missing else ""))
    return train_sets, val_sets, input_psnr


def build_test_datasets(config: Config) -> Dict[str, ImageRestorationDataset]:
    tests = {}
    for task, attr, split in (("GoPro", "path_gopro", "test"), ("HIDE", "path_hide", "test"),
                              ("DPDD", "path_dpdd", "test"), ("SIDD", "path_sidd", "test"),
                              ("Rain13K", "path_rain13k", "test")):
        if (task if task != "HIDE" else "GoPro") in config.train_tasks:
            if task == "SIDD" and _sidd_official_available(config):
                continue
            setattr(config, attr, resolve_task_root(task, getattr(config, attr), split, config))
    if "GoPro" in config.train_tasks:
        tests["GoPro"] = ImageRestorationDataset(config.path_gopro, "GoPro", "test")
        tests["HIDE"] = ImageRestorationDataset(config.path_hide, "HIDE", "test")
    if "DPDD" in config.train_tasks:
        tests["DPDD"] = ImageRestorationDataset(config.path_dpdd, "DPDD", "test")
    if "SIDD" in config.train_tasks:
        blocks = load_sidd_validation_blocks(config.path_sidd_val, config.search_roots)
        if blocks is not None:
            tests["SIDD"] = ImageRestorationDataset(task="SIDD", split="test", arrays=blocks)
        else:
            tests["SIDD"] = ImageRestorationDataset(config.path_sidd, "SIDD", "test", seed=config.seed,
                                                    sidd_holdout=config.sidd_holdout_fraction)
    if "Rain13K" in config.train_tasks:
        for sub in ("Rain100H", "Rain100L", "Test100", "Test1200", "Test2800"):
            tests[sub] = ImageRestorationDataset(config.path_rain13k, "Rain13K", "test", subset=sub)
    return tests


# ==============================================================================
# 21. MAIN
# ==============================================================================
def print_paper_tables(results: dict, params: float, gmacs: float, config: Config, notes: dict):
    """Kept for API compatibility with v4: the literature tables are now built by build_sota_tables."""
    for k, v in notes.items():
        if k in results:
            results[k]["protocol_note"] = v
    return build_sota_tables(results, {"params": params * 1e6, "sizes": {}}, config, config.tables_dir)


def seed_everything(seed: int):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def main(config: Optional[Config] = None):
    """Single entry point: Colab set-up (Drive, packages, GPU profile), then 1 GPU, DDP under
    torchrun, or (several GPUs without torchrun) torchrun launched automatically."""
    config = config or Config()
    if os.environ.get("SINA_CONFIG_JSON") and "WORLD_SIZE" in os.environ:  # a process started by the launcher
        config = _config_from_json(os.environ["SINA_CONFIG_JSON"])
    colab_setup(config)
    if config.compile_model:  # compiled kernels on the local SSD (writing thousands of cache files to Drive is slow)
        os.environ.setdefault("TORCHINDUCTOR_CACHE_DIR", os.path.join(config.local_root, "inductor_cache"))
    n = _notebook_ddp_procs(config)
    if n > 1 and _launch_ddp_subprocess(config, n):
        return
    setup_distributed(config)
    try:
        return _main(config)
    finally:
        dist_cleanup()


def _main(config: Config):
    seed_everything(config.seed)  # same seed on every rank -> identical initial weights and EMA
    if config.device.startswith("cuda"):
        torch.backends.cudnn.benchmark = True
    set_paper_style()
    print(f"SINA-Net v4 (Colab) | tasks={config.train_tasks} | total_iters={config.total_iters} | device={config.device}"
          f" | project folder {config.project_root}")

    if config.run_training or config.run_evaluation:
        if DIST.is_main:  # rank 0 downloads / extracts; the others then find the local copies
            prepare_all_datasets(config)
            dist_barrier()
        else:
            dist_barrier()
            prepare_all_datasets(config)

    model = SINANet(config).to(config.device)
    params = sum(p.numel() for p in model.parameters()) / 1e6
    gmacs = float("nan")
    if config.run_benchmark and DIST.is_main:
        params, gmacs = benchmark_model(model, config.device)
    criterion = RestorationLoss(config).to(config.device)

    trainer = None
    train_sets, val_sets = [], []
    if config.run_training:
        print("\nBuilding training data...")
        if DIST.is_main:  # rank 0 builds the tile cache first; the other ranks then reuse it
            train_sets, val_sets, input_psnr = build_datasets(config)
            dist_barrier()
        else:
            dist_barrier()
            train_sets, val_sets, input_psnr = build_datasets(config)
        trainer = ModelTrainer(config, model, train_sets, val_sets, criterion, input_psnr)
        trainer.train()
        trainer.broadcast_ema()
        if DIST.is_main:
            fig_training_curves([trainer.local_dir, config.checkpoint_dir], os.path.join(config.figures_dir, "training_curves.png"))
    else:
        path = resolve_eval_checkpoint(config.resume_from) or resolve_eval_checkpoint(config.checkpoint_dir)
        if path:
            ck = _load_ckpt(path, config.device)
            model.load_state_dict(ck["ema"]["ema"] if "ema" in ck else ck["model"])
            print(f"Evaluating weights from {path} (iteration {ck.get('iteration', '?')}, EMA={'ema' in ck})")
        else:
            print("WARNING: no checkpoint found; evaluating an UNTRAINED model.")
        if DIST.is_main:
            fig_training_curves([_local_ckpt_dir(config.checkpoint_dir), config.checkpoint_dir],
                                os.path.join(config.figures_dir, "training_curves.png"))

    if not config.run_evaluation:
        return
    if trainer is not None and trainer.iteration < config.total_iters:
        if not config.evaluate_if_incomplete:
            print(f"\nTraining is at {trainer.iteration}/{config.total_iters} iterations: skipping the full test-set "
                  f"evaluation so this session ends safely (set evaluate_if_incomplete=True, ideally with "
                  f"max_test_images, to monitor anyway). It runs automatically once training completes.")
            return
        print(f"\nTraining is at {trainer.iteration}/{config.total_iters} iterations; these numbers are for "
              f"monitoring only.")
    eval_model = trainer.eval_model() if trainer is not None else model
    eval_model.eval()
    can_compile = config.compile_model and (config.device.startswith("cuda") or config.compile_on_cpu)
    inferencer = ModelInferencer(config, eval_model,
                                 compile_ok=(trainer.compiled if trainer is not None else can_compile))
    print("\nFull-resolution evaluation on the standard test sets...")
    tests = build_test_datasets(config)
    results, notes = {}, {}
    for name, ds in tests.items():
        results[name] = inferencer.inference(ds, name, self_ensemble=config.use_self_ensemble_tta)
        if getattr(ds, "protocol_note", ""):
            notes[name] = ds.protocol_note
            results[name]["protocol_note"] = ds.protocol_note
    bundle = {"results": results, "env": dict(ENV_INFO)}
    if DIST.is_main:
        tabdir, figdir = config.tables_dir, config.figures_dir
        rows = []
        for name, r in results.items():
            if r.get("n"):
                m, lo, hi = bootstrap_ci([x["gain"] for x in r["records"]])
                rows.append([name, r["n"], r["in_psnr"], r["psnr"], r["ssim"], r["mae"], r.get("lpips"),
                             f"{m:+.2f} [{lo:+.2f}, {hi:+.2f}]", 100 * float(np.mean([x["gain"] > 0 for x in r["records"]])),
                             r["ms"], str(r["protocol"]) + (f"; {r['protocol_note']}" if r.get("protocol_note") else "")])
        ResultTable(f"SINA-Net v4 on the standard test sets (full resolution, EMA weights"
                    f"{', x8 self-ensemble' if config.use_self_ensemble_tta else ''})",
                    ["Test set", "Images", "Input PSNR", "PSNR", "SSIM", "MAE", "LPIPS", "Gain dB [95% CI]",
                     "% images improved", "ms / image", "Protocol"], rows,
                    notes=["ms / image = median end-to-end predict() time per image (signature + network, AMP, compiled "
                           "when enabled), EXCLUDING the first image of every new size, which pays the one-off "
                           "torch.compile / cuDNN autotuning cost. Pure network latency: see complexity_whole_model."],
                    fmt={"Input PSNR": "{:.2f}", "PSNR": "{:.2f}", "SSIM": "{:.4f}", "MAE": "{:.4f}", "LPIPS": "{:.4f}",
                         "% images improved": "{:.1f}", "ms / image": "{:.1f}"}
                    ).save(os.path.join(tabdir, "results_main"))
        steps = [
            ("analysis figures", config.run_analysis,
             lambda: bundle.__setitem__("suite", EvaluationSuite(config, eval_model, inferencer).run(tests, results))),
            ("complexity profile", config.run_complexity,
             lambda: bundle.__setitem__("complexity", ComplexityProfiler(config, eval_model).run(tabdir, _mkdir(figdir, "complexity")))),
            ("knock-out ablation", config.run_knockout_ablation,
             lambda: bundle.__setitem__("knockout", KnockoutAblation(config, eval_model, inferencer).run(
                 tests, tabdir, _mkdir(figdir, "ablation")))),
            ("signature consistency", True,
             lambda: bundle.__setitem__("signature_consistency", signature_consistency(config, eval_model, tests))),
        ]
        for label, enabled, fn in steps:
            if not enabled:
                continue
            print(f"\n=== {label} ===")
            t0 = time.time()
            try:
                fn()
            except Exception as e:
                import traceback
                traceback.print_exc()
                print(f"  {label} failed ({type(e).__name__}: {e}); continuing.")
            print(f"  ({label}: {time.time() - t0:.0f} s)")
        build_sota_tables(results, bundle.get("complexity", {}), config, tabdir)
        fig_efficiency(results, bundle.get("complexity", {}), os.path.join(figdir, "overview", "efficiency_gopro.png"))
    dist_barrier()
    if config.run_training_ablation:
        print("\n=== training ablation (each variant retrained from scratch) ===")
        if not train_sets:
            train_sets, val_sets, _ = build_datasets(config)
        bundle["training_ablation"] = run_training_ablation(config, train_sets, val_sets, tests)
        if DIST.is_main:
            training_ablation_table(bundle["training_ablation"], config, config.tables_dir, _mkdir(config.figures_dir, "ablation"))
    else:
        try:
            with open(os.path.join(config.ablation_dir, "results.json")) as f:
                bundle["training_ablation"] = json.load(f)
            if DIST.is_main:
                training_ablation_table(bundle["training_ablation"], config, config.tables_dir, _mkdir(config.figures_dir, "ablation"))
        except (OSError, ValueError):
            pass
    if DIST.is_main:
        claims_audit(bundle, config, config.tables_dir)
        with open(os.path.join(config.output_dir, "results.json"), "w") as f:
            json.dump({"results": results, "notes": notes, "params_M": params, "GMACs_256": gmacs,
                       "complexity": {k: v for k, v in bundle.get("complexity", {}).items() if k != "sizes"},
                       "knockout": bundle.get("knockout"), "probe": bundle.get("suite", {}).get("probe"),
                       "signature_consistency": bundle.get("signature_consistency"),
                       "training_ablation": bundle.get("training_ablation"), "env": ENV_INFO,
                       "config": asdict(config)}, f, indent=1, default=str)
        write_report(config, bundle)
        key = [os.path.join(config.figures_dir, n, "summary", f"{n}_dashboard.png") for n in results][:2]
        key += [os.path.join(config.figures_dir, "overview", "cross_dataset_overview.png"),
                os.path.join(config.figures_dir, "degradation_probe", "confusion_matrices.png"),
                os.path.join(config.tables_dir, "claims_audit.png")]
        show_in_notebook(key)
    return bundle


# ==============================================================================
# 22. SELF-TEST (synthetic data, CPU friendly)
# ==============================================================================
def _synthetic_scene(rng, size: int) -> np.ndarray:
    img = np.zeros((size, size, 3), np.float32)
    for _ in range(12):
        c = rng.random(3).astype(np.float32)
        x0, y0 = rng.integers(0, size, 2)
        w, h = rng.integers(8, 60, 2)
        img[y0:y0 + h, x0:x0 + w] = c
    img += 0.15 * rng.random((size, size, 3)).astype(np.float32)
    return np.clip(cv2.GaussianBlur(img, (0, 0), 0.7), 0, 1)


def _synthetic_pair_dataset(root: str, n: int = 24, size: int = 160, seed: int = 0):
    """Writes n blurred/sharp pairs in GoPro layout (train/blur, train/sharp)."""
    rng = np.random.default_rng(seed)
    for split in ("train", "test"):
        for sub in ("blur", "sharp"):
            os.makedirs(os.path.join(root, split, sub), exist_ok=True)
    for i in range(n):
        img = _synthetic_scene(rng, size)
        L = int(rng.integers(7, 15))
        k = np.zeros((L, L), np.float32)
        k[L // 2, :] = 1.0
        M = cv2.getRotationMatrix2D((L / 2 - 0.5, L / 2 - 0.5), float(rng.uniform(0, 180)), 1.0)
        k = cv2.warpAffine(k, M, (L, L))
        k /= k.sum()
        blur = np.clip(cv2.filter2D(img, -1, k, borderType=cv2.BORDER_REFLECT), 0, 1)
        split = "test" if i >= n - 3 else "train"
        name = f"{i:04d}.png"
        cv2.imwrite(os.path.join(root, split, "sharp", name), (img[..., ::-1] * 255).astype(np.uint8))
        cv2.imwrite(os.path.join(root, split, "blur", name), (blur[..., ::-1] * 255).astype(np.uint8))


def _synthetic_noise_dataset(root: str, n_scenes: int = 12, size: int = 160, seed: int = 1):
    """SIDD-Medium layout: <scene>/NNNN_{NOISY,GT}_SRGB_010.PNG with signal-dependent noise."""
    rng = np.random.default_rng(seed)
    for i in range(n_scenes):
        d = os.path.join(root, "train", f"{i:04d}_001_S6_00100_00060_3200_L")
        os.makedirs(d, exist_ok=True)
        img = _synthetic_scene(rng, size)
        noisy = np.clip(img + rng.normal(0, 1, img.shape).astype(np.float32) * (0.02 + 0.06 * np.sqrt(img)), 0, 1)
        cv2.imwrite(os.path.join(d, f"{i:04d}_GT_SRGB_010.PNG"), (img[..., ::-1] * 255).astype(np.uint8))
        cv2.imwrite(os.path.join(d, f"{i:04d}_NOISY_SRGB_010.PNG"), (noisy[..., ::-1] * 255).astype(np.uint8))


def selftest(iters: int = 60):
    tmp = tempfile.mkdtemp(prefix="sina_selftest_")
    ds_root = os.path.join(tmp, "Datasets")
    _synthetic_pair_dataset(os.path.join(ds_root, "GoPro"))
    _synthetic_noise_dataset(os.path.join(ds_root, "SIDD"))
    cfg = Config(device="cpu", gpu_profile="none", train_tasks=("GoPro",), project_root=os.path.join(tmp, "project"),
                 datasets_root=ds_root, local_root=os.path.join(tmp, "local"), download_datasets="none",
                 path_gopro=os.path.join(ds_root, "GoPro"), path_hide=os.path.join(tmp, "none"),
                 path_sidd=os.path.join(ds_root, "SIDD"), path_sidd_val=os.path.join(tmp, "none"),
                 path_dpdd=os.path.join(tmp, "none"), path_rain13k=os.path.join(tmp, "none"),
                 search_roots=(), sidd_holdout_fraction=0.3,
                 dims=(16, 32, 64, 128), enc_blocks=(1, 1, 1), bottleneck_blocks=1, dec_blocks=(1, 1, 1),
                 refinement_blocks=1, num_heads=4, num_workers=0, total_iters=iters, warmup_iters=10, lr=1e-3,
                 val_fraction=0.1, progressive_schedule=[(0.0, 64, 4)], max_micro_batch=4, crops_per_image=1,
                 val_every=iters, save_every=10 ** 9, log_every=20, max_val_per_task=4, use_checkpoint=True,
                 num_visualization_samples=1, gallery_k=2, eval_lpips=False, attn_crop=128, probe_max_per_class=6,
                 complexity_sizes=((64, 64), (96, 128)), ablation_max_images=3, run_training_ablation=True,
                 ablation_variants=("full", "no_wiener"), ablation_iters=16, ablation_patch=64, ablation_batch=2,
                 ablation_eval_images=3)
    main(cfg)
    print(f"selftest artefacts in {tmp}")
    return tmp


def parse_cli(argv=None) -> Tuple[Optional[Config], bool]:
    ap = argparse.ArgumentParser(description="SINA-Net v4 (Google Colab edition)")
    ap.add_argument("--preset", default=None, help="all_in_one | deblur | defocus | derain | denoise")
    ap.add_argument("--total-iters", type=int, default=None)
    ap.add_argument("--resume-from", default=None)
    ap.add_argument("--eval-only", action="store_true")
    ap.add_argument("--max-test-images", type=int, default=None)
    ap.add_argument("--max-micro-batch", type=int, default=None, help="fixed per-GPU micro-batch cap (0 = auto-probe)")
    ap.add_argument("--max-session-hours", type=float, default=None, help="11.5 (default) or 23.5 with Colab Pro+")
    ap.add_argument("--download", default=None, help="all | needed | none")
    ap.add_argument("--training-ablation", action="store_true", help="also retrain every ablation variant")
    ap.add_argument("--project-root", default=None, help="default /content/drive/MyDrive/SINA-Net-v4")
    ap.add_argument("--selftest", action="store_true")
    args, _ = ap.parse_known_args(argv)  # tolerate Jupyter's -f argument
    if args.selftest:
        return None, True
    cfg = Config(project_root=args.project_root) if args.project_root else Config()
    if args.preset:
        apply_preset(cfg, args.preset)
    if args.total_iters:
        cfg.total_iters = args.total_iters
    if args.resume_from:
        cfg.resume_from = args.resume_from
    if args.eval_only:
        cfg.run_training = False
    if args.max_test_images:
        cfg.max_test_images = args.max_test_images
    if args.max_micro_batch is not None:
        cfg.max_micro_batch = args.max_micro_batch
    if args.max_session_hours:
        cfg.max_session_hours = args.max_session_hours
    if args.download:
        cfg.download_datasets = args.download
    if args.training_ablation:
        cfg.run_training_ablation = True
    return cfg, False


if __name__ == "__main__":
    _cfg, _selftest = parse_cli()
    if _selftest:
        selftest()
    else:
        main(_cfg)
