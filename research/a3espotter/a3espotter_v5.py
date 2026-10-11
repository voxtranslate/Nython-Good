"""
A3ESpotter V5 - multilingual scene-text spotting (detection + recognition + script-ID
+ legibility/text verification + reading-direction field), MLT-2019 + public CJK sets -> ICDAR-2015.

What the V4 run showed (209-epoch logs + test figures)
-----------------------------------------------------
  * Recognition is the bottleneck: IC15 test det H 0.764 vs E2E H 0.431, while the matched words have
    1-NED 0.83, i.e. most E2E misses are one- or two-character errors. Val CTC 1.86 vs train CTC 0.90 and
    teacher-forced word accuracy 0.38 on MLT val: the recogniser over-fits a small amount of clean data.
  * The vocabulary was capped at 1,500 symbols. Every MLT Chinese / Japanese / Korean word containing one
    character outside it was dropped from CTC, so CJK recognition was trained on a small, biased subset.
  * 7 Chinese, 1 Korean and 1 Japanese script predictions on the all-Latin IC15 test. In the t-SNE they sit
    inside the Latin cloud (script-head errors, not CJK-looking words) and the PMI prior then pushes those
    Latin words towards CJK characters.
  * "Rejected by the text verifier: 0": min_score=0.80 already removes everything the verifier would reject,
    and no threshold had ever been tuned on the test domain (model selection used MLT val only).
  * Early stopping fired one epoch after the resume (patience was already exhausted at the checkpoint).
  * gn=12.2 with grad_clip=10: almost every step is clipped (kept, but the clipped fraction is now logged).
  * Lines longer than max_seq_len were silently truncated and still trained CTC (label shorter than the text in
    the image); the word-crop stream masked out the right part of every word (mask built in canvas coordinates
    instead of RoI coordinates).
  * Figures: unreadable labels, ~half of every panel figure empty (fixed 22x5.5in canvas for 16:9 images), and
    no way to tell correct from wrong detections; the IC15 t-SNE is coloured by a script that is ~always Latin.

What changed in V5
------------------
Data
  * MergedSceneTextDataset: MLT-19 + IC15 + free public Chinese / Japanese / Korean scene-text sets with the same
    characteristics as MLT (natural images, multi-oriented quadrilateral / polygon text annotations with
    transcriptions and "###"/illegible don't-care regions): RCTW-17, ReCTS-19, LSVT-19 (fully annotated part),
    ArT-19, KAIST Scene Text (Korean) and the official ICDAR-2019-MLT synthetic set (SynthMLT: Chinese /
    Japanese / Korean). Every set is DOWNLOADED AUTOMATICALLY from its original host (resumable, size / MD5 /
    archive-verified, safely extracted, never twice); attached copies are found by file signature. IC15 comes from
    the RRC (MD5-verified); MLT-19 (RRC account needed) from the Kaggle copy. Format adapters, fingerprinted index
    cache, perceptual-hash leakage guard against the validation / test images, vertex-order repair, polygon-aware
    reading direction, reduced-resolution decoding of large images, numpy-backed (fork-shared) index.
  * Script-adaptive mixture sampling: per-group budgets + temperature sampling inside groups, modulated by
    per-script multipliers that follow the held-out per-script recognition error (error-feedback mixing).
  * Scene-word strip stream: rectified, scale-normalised word strips cut from the same training images and read by
    the same network (BatchNorm frozen) - many more recognition updates per step at little cost.
Recognition
  * 8,000-symbol vocabulary, extended index-preservingly from the checkpoint (no recognition weight is lost); new
    rows are initialised from characters that share Unicode components, else from same-script characters.
  * Unicode-compositional classifier: logit(c) = h.(W_c + sum_{p in comp(c)} E_p) + b_c, with Hangul jamo
    (L/V/T) and NFD base-letter / combining-mark components (e/é, か/が/ぱ). E starts at 0, so the V4 classifier is
    reproduced exactly at the start of fine-tuning; rare Hangul syllables share strength with frequent ones.
  * Two-length time axis: long lines (aspect > 12) are read with 128 CTC steps, words with 64.
  * Labels longer than max_seq_len, CTC-infeasible labels, words < 98% inside the crop and strongly curved
    polygons are excluded from CTC; box jitter is in units of text height (never cuts characters off long lines);
    right-to-left words use visual-order targets (simplified bidi) and are decoded back to logical order.
  * Light CTC confidence penalty (frame-entropy bonus); recogniser tower+LSTM only run on RoIs with a CTC target
    during training (the verification / script heads still see every RoI).
Inference
  * Consensus script posterior (script head x script implied by the CTC posteriors) + entropy-gated PMI prior.
  * Rectified-strip re-reading from the original-resolution pixels with confidence arbitration.
  * Operating point (input size, min_score, verifier threshold, read policy, E2E confidence threshold) calibrated on
    a held-out IC15 split (the test domain) by exact re-evaluation of cached raw instances.
Training / evaluation
  * Stages: a new stage warm-starts from the previous stage's best (EMA) checkpoint with a fresh schedule and early
    stopping counter; resuming inside a stage works as before; exhausted patience is detected before training.
  * Held-out IC15 split; model selection on 0.5 * MLT spot score + 0.5 * IC15 spot score; per-script metrics.
  * E2E evaluation applies the IC15 "words shorter than 3 characters are don't-care" rule to Latin words only
    (a 2-syllable Korean word or a 2-character Chinese word is a real word).
  * GT-aware figures (correct / wrong text / false positive / missed), aspect-correct layout, outcome t-SNE.

Components of this model and the closest prior work they build on (for honest positioning - nothing below is
claimed to be "first"):
  * SGDLA block: focused linear attention (FLatten Transformer, Han et al., ICCV'23) with dyadic keys/values,
    depth-wise rank restoration and a spectral branch (global filter, GFNet, Rao et al., NeurIPS'21) gated by
    spectral flatness / peakiness / anisotropy statistics.
  * Nested kernel factorisation of PSENet kernels (Wang et al., CVPR'19), rank-consistent as in CORN (Shi et al.).
  * Reading-direction field head (related to TextField, Xu et al., TIP'19).
  * Script-aware recogniser: top-2 routed script-family experts + shared expert (ScriptMoE, Ye et al., 2026;
    Multiplexed TextSpotter, CVPR'21; MRN, ICCV'23), CTC decoding, PMI script prior.
  * Error-feedback script mixing: temperature sampling for multilingual data (Arivazhagan et al., 2019; XLM-R,
    Conneau et al., ACL'20) with weights adapted from held-out per-domain error, a lightweight relative of DoReMi
    (Xie et al., NeurIPS'23) that needs no reference model.
  * Unicode-compositional classifier: compositional Hangul modelling (jamo-level recognition) and parameter
    sharing through decomposition, here as an additive factorised CTC output layer over Hangul jamo and NFD marks.
  * Strip re-reading: two-stage "detect then read rectified crops" spotters (e.g. Mask TextSpotter v3, ABCNet,
    Liao/Liu et al.) combined with the end-to-end feature-RoI reading, arbitrated by CTC confidence.
  * CTC confidence penalty (Pereyra et al., 2017; cf. EnCTC, Liu et al., NeurIPS'18).
  * Legibility verification with self-mined hard negatives (OHEM, Shrivastava et al., CVPR'16).
"""
import os
# ==========================================
# Keep native thread pools small (DataLoader workers + OpenCV stability on Kaggle)
# ==========================================
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")

import math
import random
import json
import csv
import copy
import time
import re
import shutil
import pickle
import hashlib
import ssl
import tarfile
import zipfile
import urllib.request
import urllib.parse
import urllib.error
import unicodedata
import multiprocessing as mp
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict, namedtuple

import cv2
cv2.setNumThreads(0)
cv2.ocl.setUseOpenCL(False)

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader, Sampler
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from tqdm import tqdm
import pyclipper
from shapely.geometry import Polygon
import warnings

warnings.simplefilter(action='ignore', category=FutureWarning)
warnings.simplefilter(action='ignore', category=UserWarning)

# ==========================================
# Optional / Environment-Safe Dependencies
# ==========================================
try:
    import shap
    HAS_SHAP = True
except Exception:
    shap = None
    HAS_SHAP = False

try:
    from sklearn.manifold import TSNE
    HAS_TSNE = True
except Exception:
    TSNE = None
    HAS_TSNE = False

try:
    import torchvision
    HAS_TORCHVISION = True
except Exception:
    torchvision = None
    HAS_TORCHVISION = False

try:
    from PIL import Image
    HAS_PIL = True
except Exception:
    Image = None
    HAS_PIL = False

try:
    from sklearn.model_selection import train_test_split
except Exception:
    def train_test_split(data, test_size=0.2, random_state=42):
        rng = random.Random(random_state)
        data_copy = list(data)
        rng.shuffle(data_copy)
        split_idx = int(len(data_copy) * (1 - test_size))
        return data_copy[:split_idx], data_copy[split_idx:]


# ==========================================
# 0. Reproducibility & Dataloader Safety
# ==========================================
def seed_everything(seed=42):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = False
    torch.backends.cudnn.benchmark = True


def seed_cuda(seed):
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def worker_init_fn(worker_id):
    # torch gives each worker a distinct base seed per epoch; derive numpy's and Python's RNGs from it.
    s = torch.initial_seed() % (2 ** 32)
    np.random.seed(s)
    random.seed(s)
    cv2.setNumThreads(0)
    cv2.ocl.setUseOpenCL(False)


IMG_EXTS = ('.jpg', '.jpeg', '.png', '.bmp', '.gif', '.JPG', '.JPEG', '.PNG', '.GIF', '.BMP')


def list_images(img_dir):
    if img_dir is None or not os.path.isdir(img_dir):
        return []
    out = []
    for f in os.listdir(img_dir):
        if f.endswith(IMG_EXTS):
            out.append(os.path.join(img_dir, f))
    return sorted(out)


def list_images_recursive(root):
    out = []
    if root is None or not os.path.isdir(root):
        return out
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if not d.startswith('.')]
        out += [os.path.join(dp, f) for f in fn if f.endswith(IMG_EXTS)]
    return sorted(out)


_REDUCED_FLAGS = {2: cv2.IMREAD_REDUCED_COLOR_2, 4: cv2.IMREAD_REDUCED_COLOR_4, 8: cv2.IMREAD_REDUCED_COLOR_8}


def load_image_rgb(path, reduce=1):
    """EXIF-safe loader. ICDAR/MLT polygons refer to the raw pixel grid, so EXIF rotation must be
    IGNORED (cv2's default applies it, which silently misaligns image and GT).
    `reduce` in {1, 2, 4, 8} decodes at 1/reduce resolution (DCT-domain scaling for JPEG: much faster for the
    large LSVT / ReCTS photos when the augmentation will downscale them anyway)."""
    flag = _REDUCED_FLAGS.get(int(reduce), cv2.IMREAD_COLOR) | cv2.IMREAD_IGNORE_ORIENTATION
    img = cv2.imread(path, flag)
    if img is None and HAS_PIL:
        try:
            with Image.open(path) as im:
                im = im.convert('RGB')
                if int(reduce) > 1 and hasattr(im, 'reduce'):
                    im = im.reduce(int(reduce))
                img = np.array(im)[:, :, ::-1].copy()
        except Exception:
            img = None
    if img is None:
        return None
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


def image_size(path):
    """(w, h) of the raw pixel grid from the file header only (no decoding); None if unknown."""
    if not HAS_PIL:
        return None
    try:
        with Image.open(path) as im:
            return int(im.size[0]), int(im.size[1])
    except Exception:
        return None


# ==========================================
# 1. Configuration
# ==========================================
CANONICAL_SCRIPTS = ['None', 'Latin', 'Chinese', 'Japanese', 'Korean', 'Arabic', 'Bangla', 'Hindi',
                     'Symbols', 'Mixed', 'Unknown']
VERTICAL_CAPABLE_SCRIPTS = {'chinese', 'japanese', 'korean'}
VERIFY_CLASSES = ['legible', 'illegible', 'background']
# Script families used to align the recogniser experts (Symbols / Mixed / None / Unknown have no family).
SCRIPT_FAMILIES = ['alphabet', 'cjk', 'arabic', 'indic']
SCRIPT_TO_FAMILY = {'latin': 0, 'chinese': 1, 'japanese': 1, 'korean': 1, 'arabic': 2, 'bangla': 3, 'hindi': 3}
TRACKED_SCRIPTS = ['Latin', 'Chinese', 'Japanese', 'Korean']


def _fold_char(ch):
    """Case-insensitive vocabulary (the E2E protocol is case-insensitive): É and é share a class. Characters whose
    lower case is not one code point (e.g. 'İ') are kept as they are."""
    lo = ch.lower()
    return lo if len(lo) == 1 else ch


# ---------------------------------------------------------------------------------------------------------
# Right-to-left scripts. Transcriptions are stored in LOGICAL order, but the RoI time axis runs left-to-right in
# the image (reading_direction points rightwards for horizontal words), so CTC targets of RTL words must be in
# VISUAL order and decoded RTL strings converted back. Simplified bidi for one line: maximal runs of LTR
# characters (digits, Latin) keep their order, everything else is reversed, and the runs are reversed. The
# mapping is its own inverse, so it converts logical <-> visual.
# ---------------------------------------------------------------------------------------------------------
_RTL_RANGES = ((0x0590, 0x08FF), (0xFB1D, 0xFDFF), (0xFE70, 0xFEFF))


def _is_rtl_char(c):
    o = ord(c)
    return any(a <= o <= b for a, b in _RTL_RANGES) and unicodedata.category(c) != 'Nd'


def has_rtl(t):
    return any(_is_rtl_char(c) for c in (t or ''))


def visual_order(t):
    if not has_rtl(t):
        return t
    runs, cur, cur_ltr = [], '', None
    for c in t:
        ltr = unicodedata.category(c) == 'Nd' or (c.isalnum() and not _is_rtl_char(c))
        if cur and ltr != cur_ltr:
            runs.append((cur, cur_ltr))
            cur = ''
        cur, cur_ltr = cur + c, ltr
    if cur:
        runs.append((cur, cur_ltr))
    merged = []                                       # 'ABC 2024': neutrals between two LTR runs stay LTR
    for r, ltr in runs:
        if ltr and len(merged) >= 2 and merged[-2][1] and not has_rtl(merged[-1][0]):
            mid, _ = merged.pop()
            prev, _ = merged.pop()
            merged.append((prev + mid + r, True))
        else:
            merged.append((r, ltr))
    return ''.join(r if ltr else r[::-1] for r, ltr in reversed(merged))


def normalize_transcript(t):
    return unicodedata.normalize('NFKC', t or '').strip()


def is_hangul_syllable(ch):
    return 0xAC00 <= ord(ch) <= 0xD7A3


def infer_script_from_text(text):
    """Used for datasets without a script column (e.g. ICDAR-2015, RCTW, LSVT)."""
    counts = Counter()
    for ch in text:
        o = ord(ch)
        if ch.isspace():
            continue
        if (0x41 <= o <= 0x5A) or (0x61 <= o <= 0x7A) or (0xC0 <= o <= 0x24F):
            counts['Latin'] += 1
        elif 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0xF900 <= o <= 0xFAFF:
            counts['Chinese'] += 1
        elif 0x3041 <= o <= 0x3096 or 0x30A1 <= o <= 0x30FA or o == 0x30FC or 0x31F0 <= o <= 0x31FF:
            counts['Japanese'] += 1
        elif 0xAC00 <= o <= 0xD7AF or 0x1100 <= o <= 0x11FF or 0x3130 <= o <= 0x318F:
            counts['Korean'] += 1
        elif 0x0600 <= o <= 0x06FF or 0x0750 <= o <= 0x077F:
            counts['Arabic'] += 1
        elif 0x0980 <= o <= 0x09FF:
            counts['Bangla'] += 1
        elif 0x0900 <= o <= 0x097F:
            counts['Hindi'] += 1
        else:
            counts['Symbols'] += 1
    if not counts:
        return 'None'
    letters = {k: v for k, v in counts.items() if k != 'Symbols'}
    if not letters:
        return 'Symbols'
    # kanji + kana = Japanese (a Japanese line is very often mostly kanji)
    if set(letters) == {'Chinese', 'Japanese'}:
        return 'Japanese'
    if len(letters) > 1:
        return 'Mixed'
    return next(iter(letters))


def resolve_script(text, language=None, hint=None):
    """Script label for an annotation: the dataset's own script column when present, otherwise inferred from
    the characters; a dataset-level hint disambiguates kanji-only Japanese lines (inferred as 'Chinese')."""
    if language:
        return language
    s = infer_script_from_text(text)
    if hint and s == 'Chinese' and hint.lower() == 'japanese':
        return 'Japanese'
    return s


_SCRIPT_NAMES_LOWER = {s.lower() for s in CANONICAL_SCRIPTS}


def parse_mlt_gt_line(line):
    """Robust parser for both ground-truth formats:
       MLT-2017/19 (and SynthMLT) : x1,y1,...,x4,y4,script,transcription
       ICDAR-2015 / MTWI          : x1,y1,...,x4,y4,transcription"""
    line = line.strip().lstrip('﻿')
    if not line:
        return None
    parts = line.split(',')
    if len(parts) < 9:
        return None
    try:
        coords = np.array(list(map(float, parts[:8])), dtype=np.float32).reshape(-1, 2)
    except ValueError:
        return None
    if parts[8].strip().lower() in _SCRIPT_NAMES_LOWER and len(parts) >= 10:
        language = parts[8].strip()
        transcript = ','.join(parts[9:])
    else:
        transcript = ','.join(parts[8:])
        language = None
    transcript = normalize_transcript(transcript)
    if language is None:
        language = 'None' if transcript in ('', '###') else infer_script_from_text(transcript)
    is_ignore = (transcript == '###') or (transcript == '') or (language.lower() == 'none')
    return {'poly': coords, 'language': language, 'transcript': transcript, 'ignore': is_ignore}


def find_gt_file(gt_dir, img_path):
    stem = os.path.splitext(os.path.basename(img_path))[0]
    for cand in (stem + '.txt', 'gt_' + stem + '.txt', 'res_' + stem + '.txt'):
        p = os.path.join(gt_dir, cand)
        if os.path.exists(p):
            return p
    return None


def read_gt_file(gt_path):
    insts = []
    if gt_path is None or not os.path.exists(gt_path):
        return insts
    with open(gt_path, 'r', encoding='utf-8-sig', errors='ignore') as f:
        for line in f:
            parsed = parse_mlt_gt_line(line)
            if parsed is not None:
                insts.append(parsed)
    return insts


def _first_existing(cands):
    for c in cands:
        if c and os.path.isdir(c):
            return c
    return None


# ---------------------------------------------------------------------------------------------------------
# Unicode components (used by the compositional classifier and by the initialisation of new vocabulary rows)
# ---------------------------------------------------------------------------------------------------------
def char_components(ch):
    """Visual components of a character that other characters share:
       Hangul syllable -> its jamo (initial L, medial V, optional final T), computed arithmetically;
       NFD-decomposable characters -> base letter + combining marks (é = e + U+0301, が = か + U+3099);
       anything else -> itself (kept only when it is the base of another vocabulary character)."""
    o = ord(ch)
    if 0xAC00 <= o <= 0xD7A3:
        s = o - 0xAC00
        comps = ['hL%d' % (s // 588), 'hV%d' % ((s % 588) // 28)]
        if s % 28:
            comps.append('hT%d' % (s % 28))
        return comps
    d = unicodedata.normalize('NFD', ch)
    if len(d) > 1:
        return ['b' + d[0]] + ['m%04X' % ord(m) for m in d[1:]]
    return ['b' + ch]


def build_component_table(chars, min_share=2):
    """Returns (component names, per-character component-id lists). A component is kept only if at least
    `min_share` vocabulary characters contain it (otherwise it would just duplicate that character's row)."""
    per_char = [char_components(c) for c in chars]
    cnt = Counter(p for comps in per_char for p in set(comps))
    names = sorted(p for p, n in cnt.items() if n >= min_share)
    pid = {p: i for i, p in enumerate(names)}
    rows = [[pid[p] for p in comps if p in pid] for comps in per_char]
    return names, rows


class Config:
    def __init__(self):
        # ---------------- data ----------------
        mlt_root = '/kaggle/input/datasets/zubairalibhutto/mlt-19-ocr-dataset'
        ic15_root = '/kaggle/input/datasets/justinbieberjr/idcar-2015-official'
        self.train_img_dir = os.path.join(mlt_root, 'TrainImages/TrainImages')
        self.train_gt_dir = os.path.join(mlt_root, 'TrainGT/TrainGT')
        self.test_img_dir = os.path.join(ic15_root, 'ch4_test_images')
        # Optional: IC15 training split (the test domain). Mixed into training when found.
        self.ic15_train_img_dir = _first_existing([os.path.join(ic15_root, d) for d in
                                                   ('ch4_training_images', 'train_images', 'ch4_train_images')])
        self.ic15_train_gt_dir = _first_existing([os.path.join(ic15_root, d) for d in
                                                  ('ch4_training_localization_transcription_gt',
                                                   'train_gts', 'ch4_train_gt')])
        self.ic15_repeat = 2                     # weight INSIDE the 'ic15' group (the group's share of every epoch
                                                 # is mixture_budget['ic15']; a lone source gets the whole budget)
        self.ic15_val_fraction = 0.1             # NEW: held-out IC15 train images = test-domain validation
        # Optional extra FULL-IMAGE training sets in ICDAR quad format (e.g. SynthMLT, ArT, RCTW converted):
        #   [{'img_dir': ..., 'gt_dir': ..., 'repeat': 1}, ...]
        self.extra_train_sets = []
        # Optional WORD-CROP recognition sources:
        #   {'type': 'lmdb', 'path': '/kaggle/input/.../train_lmdb'}            (standard STR LMDB layout)
        #   {'type': 'txt',  'path': 'labels.txt', 'root': 'images/'}           (lines: relpath<TAB>label)
        self.crop_rec_sources = []
        self.crop_batch_size = 48
        self.w_crop_rec = 0.5
        self.crop_vocab_scan = 200000            # max crop labels scanned when building the vocabulary
        self.crop_max_samples = None             # optional cap on crop samples used
        # Optional: IC15 test GT -> enables official-style metrics on the test set.
        self.test_gt_dir = _first_existing([os.path.join(ic15_root, d) for d in
                                            ('Challenge4_Test_Task1_GT', 'Challenge4_Test_Task4_GT',
                                             'ch4_test_gt', 'test_gts', 'ch4_test_localization_transcription_gt')])
        self.val_fraction = 0.1
        self.seed = 42

        # ---------------- NEW: public CJK completion (see PUBLIC_SOURCE_CATALOG) ----------------
        # 'auto' = discover the catalogued datasets under `source_search_roots` (e.g. attached Kaggle datasets);
        # or an explicit list of specs, e.g.
        #   {'name': 'rctw17', 'format': 'rctw', 'img_dir': '.../train_images', 'gt_dir': '.../train_gts'}
        #   {'name': 'lsvt', 'format': 'lsvt', 'img_dir': '.../train_full_images', 'label_file': '.../train_full_labels.json'}
        #   {'name': 'my_set', 'format': 'paddle', 'img_dir': '...', 'label_file': '.../Label.txt', 'group': 'ja'}
        self.cjk_sources = 'auto'
        self.source_search_roots = ['/kaggle/input', './data']
        # Automatic download from the ORIGINAL distribution points (see PUBLIC_SOURCE_CATALOG): resumable,
        # size / MD5 / archive-verified, extracted once and reused (a '.complete' marker per set). On Kaggle the
        # data goes to the large ephemeral disk; save that folder as a Kaggle dataset to skip it next session.
        self.auto_download_sources = True
        self.download_root = '/tmp/a3espotter_data' if os.path.isdir('/kaggle') else './data/public_sources'
        # priority order: if the disk reserve is reached, the sets at the end are the ones skipped
        self.download_names = ['lsvt', 'rects', 'kaist', 'art', 'synthmlt_ja', 'synthmlt_ko', 'synthmlt_zh', 'rctw17']
        self.custom_download_urls = {}           # e.g. {'rctw17': ['https://.../train_images.zip.001', ...]}
        self.download_retries = 4
        self.download_timeout = 60
        self.download_min_free_gb = 5.0          # never fill the disk below this reserve
        self.download_keep_archives = False      # delete archives after a verified extraction
        self.download_allow_legacy_tls = True    # CVC / CTU hosts: chain does not verify -> unverified HTTPS last
        self.download_use_mirror_fallback = True # SynthMLT: HF word-crop LMDB if the original host is unreachable
        self.mlt_kaggle_mirrors = ['zubairalibhutto/mlt-19-ocr-dataset']      # MLT-19 needs an RRC account
        self.ic15_kaggle_mirrors = ['justinbieberjr/idcar-2015-official']    # used only if the RRC download fails
        self.max_images_per_source = None        # e.g. 20000 to bound indexing / epoch composition
        self.index_workers = max(1, min(8, (os.cpu_count() or 2)))
        self.dedup_against_eval = True           # perceptual-hash guard: no val / test image inside training
        self.dedup_hamming = 5
        # sampling budget per group (renormalised over the groups that are present)
        self.mixture_budget = {'mlt': 0.40, 'ic15': 0.18, 'extra': 0.07, 'zh': 0.15, 'ja': 0.10, 'ko': 0.10}
        self.mixture_temperature = 2.0           # inside a group: p_source ~ (w * n)^(1/T); group shares are the
                                                 # budgets above, so `weight` / `synthetic_weight` only matter
                                                 # between sources of the same group
        self.synthetic_weight = 0.5              # synthetic sources start with half the weight of real ones
        self.samples_per_epoch = 11000           # fixed epoch length (V4: 11,000 images per epoch)
        self.adaptive_mixing = True              # error-feedback per-script multipliers
        self.mixing_eta = 1.0
        self.mixing_beta_range = (0.5, 2.5)
        self.mixing_min_support = 20             # min. validation words of a script before it is adapted

        # ---------------- NEW: scene-word strip stream ----------------
        self.use_scene_strips = True
        self.strips_per_image = 8
        self.strip_batch_images = 6              # images decoded per strip batch (-> <= 48 strips)
        self.w_strip_rec = 0.5
        self.strip_num_workers = 2

        # ---------------- model ----------------
        self.backbone = 'resnet18'               # resnet18 | resnet34 | resnet50 | scratch
        self.pretrained_backbone = True          # ImageNet weights if downloadable
        self.backbone_weights_path = None        # optional local .pth (offline Kaggle)
        self.embed_dim = 256                     # SGDLA context width
        self.sgdla_depth = 2
        self.sgdla_heads = 8
        self.fpn_dim = 128
        self.neck_dim = 128
        self.num_kernels = 6
        self.min_scale = 0.4                     # PSENet IC15 setting
        self.feature_stride = 4

        # ---------------- recognition ----------------
        self.roi_h = 8
        self.roi_w = 64                          # CTC time steps for words
        self.roi_w_long = 128                    # NEW: CTC time steps for long lines (CJK lines)
        self.long_aspect = 12.0                  # NEW: padded-RoI aspect above which the long time axis is used
        self.roi_pad_h = 0.15
        self.roi_pad_w = 0.15                    # x height
        self.max_seq_len = 48                    # V4: 32 (long CJK lines were truncated)
        self.max_vocab = 8000                    # V4: 1500 (CJK words fell out of CTC)
        self.min_char_count = 2
        self.synthetic_count_weight = 0.25       # synthetic text counts less when choosing the vocabulary
        self.use_compositional_classifier = True
        self.rec_hidden = 256
        self.num_experts = 4                     # one per script family
        self.moe_routing = 'decoupled'           # 'decoupled' (router + light family head) | 'script_driven' (V4.0)
        self.moe_top_k = 2
        self.router_jitter = 0.05
        self.use_shared_gate = True
        self.w_family = 0.1                      # light auxiliary signal (orients, does not dictate, routing)
        self.dropout = 0.15
        self.box_jitter_prob = 0.5
        self.max_text_rois_per_img = 24
        self.max_rec_rois_per_batch = 192        # NEW: bounds the (K, T, V) CTC tensors with V=8000
        self.max_script_consistency_rois = 64
        self.num_bg_rois_per_img = 6
        self.mined_neg_per_img = 6
        self.ctc_entropy_beta = 0.05             # NEW: frame-entropy (confidence) penalty on CTC

        # ---------------- training ----------------
        self.img_size = 512                      # training crop (also fixes spectral-filter shapes: keep 512)
        self.batch_size = 16
        self.epochs = 250                        # from scratch
        self.lr = 5e-4
        self.backbone_lr_mult = 0.2
        self.min_lr = 1e-6
        self.warmup_epochs = 2
        self.weight_decay = 0.01
        self.grad_clip = 10.0
        self.ema_decay = 0.9995
        self.use_amp = True
        self.num_workers = max(2, min(4, (os.cpu_count() or 2)))
        self.label_smoothing = 0.05
        self.ohem_ratio = 3.0
        self.min_text_px = 4                     # text thinner than this (crop px) -> ignore
        self.target_text_h = (8.0, 80.0)         # text-height range for scale-normalised crops

        # ---------------- NEW: stages ----------------
        self.stage_name = 'v5_cjk_merge'         # a different stage name in the checkpoint -> warm start
        self.init_checkpoint = None              # explicit warm-start checkpoint (else auto: best of previous stage)
        self.finetune_epochs = 60
        self.finetune_lr = 2e-4
        self.finetune_warmup_epochs = 1

        # loss weights
        self.w_text = 0.7
        self.w_kernel = 0.3
        self.w_dir = 0.2
        self.w_rec = 1.0
        self.w_script = 0.3
        self.w_verify = 0.5
        self.w_script_consistency = 0.2
        self.kl_weight = 1e-4
        self.use_uncertainty_weighting = True
        self.uncertainty_bound = 1.0             # |s_k| <= bound -> a task is never down-weighted > e^bound

        # ---------------- evaluation / selection ----------------
        self.eval_every = 2
        self.eval_max_images = 300
        self.early_stopping_patience = 12        # in evaluation rounds
        self.early_stopping_min_delta = 1e-4
        self.e2e_min_word_len = 3                # IC15: 1-2 char LATIN words are don't-care for E2E
        self.selection_weights = {'mlt': 0.5, 'ic15': 0.5}

        # ---------------- inference ----------------
        self.infer_short_side = 736              # PSENet IC15 test size (re-calibrated on IC15-val)
        self.infer_max_long_side = 2400
        self.test_scales = [1.0]
        self.tile_max_side = 1600                # larger resized images are tiled
        self.tile_size = 1024
        self.tile_overlap = 256
        self.text_thresh = 0.5
        self.kernel_thresh = 0.5
        self.min_score = 0.80                    # mean text prob inside an instance (re-calibrated)
        self.min_area = 16                       # image px (at the resized scale)
        self.pse_upsample = 2                    # PSE on a stride-2 grid
        self.verify_bg_thresh = 0.5              # re-calibrated
        self.script_prior_lambda = 0.5
        self.script_consensus_gamma = 1.0        # NEW: weight of the CTC-implied script in the consensus
        self.read_policy = 'max'                 # NEW: dense | strip | max | small (re-calibrated)
        self.rsr_small_px = 24.0                 # NEW: 'small' policy: strip re-reading below this canvas height
        self.e2e_min_rec_conf = 0.0              # NEW: E2E output keeps words with rec. confidence >= this
        self.use_best_checkpoint_for_inference = True
        self.drop_illegible_from_e2e = True
        self.use_tiling = True                   # kept for compatibility (tiling is automatic)
        # calibration on the held-out IC15 split (falls back to MLT val)
        self.calibrate_operating_point = True
        self.calib_max_images = 150
        self.calib_short_sides = [736, 960, 1152]
        self.calib_min_scores = [0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9]
        self.calib_bg_thresholds = [0.3, 0.4, 0.5, 0.6, 0.7, 1.01]
        self.calib_read_policies = ['dense', 'strip', 'max', 'small']
        self.calib_e2e_confs = [0.0, 0.3, 0.4, 0.5, 0.6, 0.7]

        # ---------------- vocabulary (filled at runtime) ----------------
        self.chars = []
        self.stoi = {}
        self.itos = {}
        self.vocab_size = 2
        self.char2script = None                  # (V, S) P(script | char)
        self.script_marginal = None              # (S,)   P(script) over training characters
        self.char_counts = {}

        self.CANONICAL_SCRIPTS = CANONICAL_SCRIPTS
        self.script2id = {name.lower(): i for i, name in enumerate(CANONICAL_SCRIPTS)}
        self.num_scripts = len(CANONICAL_SCRIPTS)
        self.num_verify = len(VERIFY_CLASSES)

        # ---------------- output dirs ----------------
        self.out_dir = './outputs'
        self.make_dirs()

    def make_dirs(self):
        self.chkp_dir = os.path.join(self.out_dir, 'models')
        self.vis_dir = os.path.join(self.out_dir, 'vizs')
        self.interp_dir = os.path.join(self.out_dir, 'interpret')
        self.diag_dir = os.path.join(self.out_dir, 'diagnostics')
        self.curves_dir = os.path.join(self.diag_dir, 'curves')
        self.logs_dir = os.path.join(self.diag_dir, 'logs')
        self.reports_dir = os.path.join(self.diag_dir, 'reports')
        self.panels_dir = os.path.join(self.diag_dir, 'panels')
        self.attn_dir = os.path.join(self.diag_dir, 'attention')
        self.submit_dir = os.path.join(self.out_dir, 'submission')
        self.cache_dir = os.path.join(self.out_dir, 'cache')
        for d in (self.out_dir, self.chkp_dir, self.vis_dir, self.interp_dir, self.diag_dir,
                  self.curves_dir, self.logs_dir, self.reports_dir, self.panels_dir,
                  self.attn_dir, self.submit_dir, self.cache_dir):
            os.makedirs(d, exist_ok=True)

    # ---------------- scripts ----------------
    def script_id_for(self, language):
        key = (language or '').strip().lower()
        return self.script2id.get(key, self.script2id['unknown'])

    # ---------------- vocabulary ----------------
    def set_vocab(self, chars, char2script=None, script_marginal=None):
        self.chars = list(chars)
        self.stoi = {c: i + 2 for i, c in enumerate(self.chars)}      # 0 = CTC blank, 1 = UNK
        self.itos = {i + 2: c for i, c in enumerate(self.chars)}
        self.vocab_size = 2 + len(self.chars)
        if char2script is not None and np.asarray(char2script).shape[0] == self.vocab_size:
            self.char2script = np.asarray(char2script, dtype=np.float32)
        else:
            self.char2script = np.full((self.vocab_size, self.num_scripts), 1.0 / self.num_scripts,
                                       dtype=np.float32)
        if script_marginal is not None:
            self.script_marginal = np.asarray(script_marginal, dtype=np.float32)
        else:
            self.script_marginal = np.full(self.num_scripts, 1.0 / self.num_scripts, dtype=np.float32)

    def family_target(self, transcript, script_id):
        """Soft target over SCRIPT_FAMILIES: 0.5 * one-hot(family of the annotated script) + 0.5 * the family
        distribution implied by the characters through P(script | char). Zeros when nothing is known."""
        nf = len(SCRIPT_FAMILIES)
        t = np.zeros(nf, dtype=np.float32)
        name = self.CANONICAL_SCRIPTS[script_id].lower() if 0 <= script_id < self.num_scripts else ''
        hard = SCRIPT_TO_FAMILY.get(name)
        soft = np.zeros(nf, dtype=np.float64)
        if self.char2script is not None:
            n = 0
            for ch in transcript or '':
                idx = self.stoi.get(_fold_char(ch))
                if idx is None:
                    continue
                row = self.char2script[idx]
                fam = np.zeros(nf)
                for sname, f in SCRIPT_TO_FAMILY.items():
                    fam[f] += row[self.script2id[sname]]
                if fam.sum() > 1e-6:
                    soft += fam / fam.sum()
                    n += 1
            if n:
                soft /= n
        if hard is not None and soft.sum() > 0:
            t = 0.5 * np.eye(nf, dtype=np.float32)[hard] + 0.5 * soft.astype(np.float32)
        elif hard is not None:
            t = np.eye(nf, dtype=np.float32)[hard]
        elif soft.sum() > 0:
            t = soft.astype(np.float32)
        return t

    def _finalise_vocab(self, counter, pair, base_chars=None):
        """Chooses the character set and estimates P(script | char).
        * base_chars (vocabulary of the checkpoint being warm-started) are kept first, in the same order, so their
          classifier rows keep their indices; new characters are appended by decreasing frequency.
        * Hangul syllables need a single occurrence when the compositional classifier is on (they share jamo)."""
        def eligible(c):
            if ord(c) < 128:
                return True
            if is_hangul_syllable(c) and self.use_compositional_classifier:
                return counter[c] > 0                     # shares jamo: one (even synthetic) occurrence is enough
            return counter[c] >= self.min_char_count
        cands = sorted((c for c in counter if eligible(c)), key=lambda c: (-counter[c], c))
        if base_chars:
            chars = list(base_chars)
            have = set(chars)
            for c in cands:
                if len(chars) >= self.max_vocab:
                    break
                if c not in have:
                    chars.append(c)
                    have.add(c)
        else:
            ascii_chars = sorted(c for c in cands if ord(c) < 128)
            extra = [c for c in cands if ord(c) >= 128][:max(0, self.max_vocab - len(ascii_chars))]
            chars = ascii_chars + sorted(extra)
        V, S = 2 + len(chars), self.num_scripts
        alpha = 0.1
        m = np.full((V, S), 1.0 / S, dtype=np.float32)
        for i, c in enumerate(chars):
            row = np.full(S, alpha, dtype=np.float64)
            for sid, n in pair[c].items():
                row[sid] += n
            m[i + 2] = (row / row.sum()).astype(np.float32)
        sm = np.ones(S, dtype=np.float64)
        for c in chars:
            for sid, n in pair[c].items():
                sm[sid] += n
        self.set_vocab(chars, m, (sm / sm.sum()).astype(np.float32))
        self.char_counts = {c: float(counter[c]) for c in chars}
        return counter

    def _count_text(self, text, sid, counter, pair, w=1.0):
        for ch in text:
            if ch.isspace():
                continue
            c = _fold_char(ch)
            counter[c] += w
            pair[c][sid] += w

    def build_vocab(self, items, extra_labels=None, base_chars=None):
        """items: list of (img_path, gt_path) in ICDAR/MLT format. Built on the TRAINING split only."""
        counter, pair = Counter(), defaultdict(Counter)
        for _, gt_path in items:
            for inst in read_gt_file(gt_path):
                if not inst['ignore']:
                    self._count_text(inst['transcript'], self.script_id_for(inst['language']), counter, pair)
        for text in (extra_labels or []):
            text = normalize_transcript(text)
            if text and text != '###':
                self._count_text(text, self.script_id_for(infer_script_from_text(text)), counter, pair)
        return self._finalise_vocab(counter, pair, base_chars)

    def build_vocab_from_index(self, index, extra_labels=None, base_chars=None):
        """Vocabulary + P(script|char) from a SourceIndex (all merged training sources)."""
        counter, pair = Counter(), defaultdict(Counter)
        for rec in index.records:
            spec = index.sources[rec.src]
            w = self.synthetic_count_weight if spec.get('kind') == 'synthetic' else 1.0
            for _, text, ign, lang in json.loads(rec.ann):
                if not ign:
                    self._count_text(text, self.script_id_for(lang), counter, pair, w)
        for text in (extra_labels or []):
            text = normalize_transcript(text)
            if text and text != '###':
                self._count_text(text, self.script_id_for(infer_script_from_text(text)), counter, pair)
        return self._finalise_vocab(counter, pair, base_chars)

    def text_fits(self, text):
        return 0 < len([c for c in (text or '') if not c.isspace()]) <= self.max_seq_len

    def encode_text(self, text):
        """Returns (padded ids, length, number of out-of-vocabulary characters). Text longer than max_seq_len is
        truncated here - callers must check `text_fits` before using it as a CTC target. Right-to-left words are
        encoded in visual (left-to-right image) order, the order of the RoI time axis."""
        seq, n_oov = [], 0
        for ch in visual_order(text):
            if ch.isspace():
                continue
            idx = self.stoi.get(_fold_char(ch))
            if idx is None:
                idx = 1
                n_oov += 1
            seq.append(idx)
        if len(seq) == 0:
            seq = [1]
            n_oov += 1
        seq = seq[:self.max_seq_len]
        padded = np.zeros(self.max_seq_len, dtype=np.int64)
        padded[:len(seq)] = seq
        return padded, len(seq), n_oov

    def decode_text(self, token_indices):
        res, prev = [], 0
        for p in token_indices:
            p = int(p)
            if p != prev and p > 1 and p in self.itos:
                res.append(self.itos[p])
            prev = p
        return visual_order("".join(res))

    def decode_with_confidence(self, probs_tv):
        """Greedy CTC decoding of a (T, V) probability matrix. Confidence = geometric mean of the
        max-probabilities of the emitted characters (0 for an empty string)."""
        idx = probs_tv.argmax(axis=-1)
        pmax = probs_tv.max(axis=-1)
        res, confs, prev = [], [], 0
        for t, p in enumerate(idx):
            p = int(p)
            if p != prev and p > 1 and p in self.itos:
                res.append(self.itos[p])
                confs.append(float(pmax[t]))
            prev = p
        if not confs:
            return '', 0.0
        return visual_order(''.join(res)), float(np.exp(np.mean(np.log(np.clip(confs, 1e-8, 1.0)))))

    def decode_indices_raw(self, indices):
        """Target ids -> text in logical order."""
        return visual_order("".join(self.itos.get(int(i), '') for i in indices if int(i) not in (0, 1)))

    ARCH_KEYS = ('backbone', 'embed_dim', 'sgdla_depth', 'sgdla_heads', 'fpn_dim', 'neck_dim', 'num_kernels',
                 'min_scale', 'rec_hidden', 'num_experts', 'img_size')
    INFER_KEYS = ('infer_short_side', 'min_score', 'verify_bg_thresh', 'read_policy', 'e2e_min_rec_conf')

    def snapshot(self):
        keys = ['backbone', 'embed_dim', 'sgdla_depth', 'sgdla_heads', 'fpn_dim', 'neck_dim',
                'num_kernels', 'min_scale', 'roi_h', 'roi_w', 'roi_w_long', 'long_aspect', 'rec_hidden',
                'num_experts', 'dropout', 'img_size', 'max_seq_len', 'moe_routing', 'moe_top_k', 'router_jitter',
                'use_shared_gate', 'use_compositional_classifier', 'stage_name'] + list(self.INFER_KEYS)
        d = {k: getattr(self, k) for k in keys}
        d['chars'] = list(self.chars)
        d['char2script'] = self.char2script.tolist() if self.char2script is not None else None
        d['script_marginal'] = self.script_marginal.tolist() if self.script_marginal is not None else None
        d['components'] = build_component_table(self.chars)[0] if self.use_compositional_classifier else []
        return d


# ==========================================
# 1b. Geometry helpers (reading-direction frames)
# ==========================================
def poly_signed_area(p):
    x, y = p[:, 0], p[:, 1]
    return 0.5 * float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


def canonical_quad(poly):
    """Make the quad clockwise in image coordinates (y down) while keeping p0 as the start."""
    p = np.asarray(poly, dtype=np.float32).reshape(-1, 2)
    if len(p) == 4 and poly_signed_area(p) < 0:
        p = p[[0, 3, 2, 1]]
    return p


def _unit(v, fallback=(1.0, 0.0)):
    n = float(np.hypot(v[0], v[1]))
    if n < 1e-6:
        return np.array(fallback, dtype=np.float32)
    return (np.asarray(v, dtype=np.float32) / n).astype(np.float32)


def _reading_pref(u):
    """Ordering used to pick the sign of an ambiguous reading direction: rightwards first, else downwards."""
    return (1 if u[0] > 0.35 else (-1 if u[0] < -0.35 else 0), float(u[1]))


def _quad_dir(q):
    return _unit((q[1] - q[0]) + (q[2] - q[3]))


def repair_quad_order(q, language='', transcript='', trusted=True):
    """ICDAR quads start at the top-left of the word and run clockwise, so p0->p1 is the reading direction.
    * trusted sources: only an obvious violation is repaired (multi-character horizontal-script word whose first
      edge is less than half the length of the second one -> the annotation starts one vertex early or late);
    * 'auto' sources (synthetic sets with an undocumented vertex order): p0 := the top-left-most vertex, the
      first edge is moved onto the long side for horizontal scripts, and its sign follows _reading_pref."""
    q = np.asarray(q, dtype=np.float32)
    n = len((transcript or '').replace(' ', ''))
    vertical = (language or '').lower() in VERTICAL_CAPABLE_SCRIPTS
    if not trusted:
        q = np.roll(q, -int(np.argmin(q[:, 0] + q[:, 1])), axis=0)
    if n < 2:
        return q
    l01 = float(np.hypot(*(q[1] - q[0])))
    l12 = float(np.hypot(*(q[2] - q[1])))
    if trusted:
        if vertical or n < 3 or l12 <= 2.0 * l01:
            return q
        cands = [np.roll(q, -1, axis=0), np.roll(q, -3, axis=0)]
        return max(cands, key=lambda c: _reading_pref(_quad_dir(c))).astype(np.float32)
    if vertical:
        return q
    if l12 > 1.15 * l01:
        cands = [np.roll(q, -1, axis=0), np.roll(q, -3, axis=0)]
    else:
        cands = [q, np.roll(q, -2, axis=0)]
    return max(cands, key=lambda c: _reading_pref(_quad_dir(c))).astype(np.float32)


def reading_direction_from_quad(quad, language='', transcript=''):
    """Reading direction u (unit vector, image coords) from an annotated quad.
    ICDAR/MLT quads start at the top-left of the word and go clockwise, so p0->p1 follows the
    reading direction. Tall boxes of CJK scripts are vertical lines: reading goes p0->p3."""
    q = canonical_quad(quad)
    if len(q) != 4:
        rect = cv2.minAreaRect(q.astype(np.float32))
        q = canonical_quad(cv2.boxPoints(rect))
    e_top, e_bot = q[1] - q[0], q[2] - q[3]
    e_l, e_r = q[3] - q[0], q[2] - q[1]
    u = _unit(e_top + e_bot, fallback=_unit(e_top))
    len_u = 0.5 * (np.hypot(*e_top) + np.hypot(*e_bot))
    len_v = 0.5 * (np.hypot(*e_l) + np.hypot(*e_r))
    if (language or '').lower() in VERTICAL_CAPABLE_SCRIPTS and len_v > 1.5 * len_u and \
            len((transcript or '').strip()) >= 2:
        u = _unit(e_l + e_r, fallback=_unit(e_l))
    return u


def polygon_reading_direction(poly, language='', transcript=''):
    """Reading direction and curvature flag of an N-point polygon (LSVT / ArT / Total-Text convention: N even,
    first half = top edge from the reading start, second half = bottom edge back). Returns (u, curved)."""
    pts = np.asarray(poly, dtype=np.float32).reshape(-1, 2)
    rect = cv2.minAreaRect(pts)
    bp = cv2.boxPoints(rect)
    e1, e2 = bp[1] - bp[0], bp[2] - bp[1]
    a_long = _unit(e1 if np.hypot(*e1) >= np.hypot(*e2) else e2)
    n = len(pts)
    chord = None
    if n >= 6 and n % 2 == 0:
        top, bot = pts[:n // 2], pts[n // 2:][::-1]
        chord = (top[-1] - top[0]) + (bot[-1] - bot[0])
    if chord is not None and np.hypot(*chord) > 1e-3:
        u = _unit(chord)
    else:
        u = a_long if _reading_pref(a_long) >= _reading_pref(-a_long) else -a_long
        if (language or '').lower() in VERTICAL_CAPABLE_SCRIPTS and len((transcript or '').strip()) >= 2 \
                and abs(a_long[1]) > 0.8:
            u = a_long if a_long[1] > 0 else -a_long          # vertical CJK line: read top -> bottom
    rect_area = max(float(rect[1][0] * rect[1][1]), 1e-6)
    curved = n > 4 and abs(poly_signed_area(pts)) / rect_area < 0.8
    return u.astype(np.float32), bool(curved)


def perp(u):
    """v = u rotated by +90deg in image coordinates (y down): 'down' in the reading frame."""
    return np.array([-u[1], u[0]], dtype=np.float32)


def rbox_from_points(points, u):
    """Oriented box (cx, cy, w, h, ux, uy) of `points` in the reading frame defined by u."""
    pts = np.asarray(points, dtype=np.float32).reshape(-1, 2)
    u = _unit(u)
    v = perp(u)
    pu, pv = pts @ u, pts @ v
    a0, a1, b0, b1 = pu.min(), pu.max(), pv.min(), pv.max()
    cu, cv = 0.5 * (a0 + a1), 0.5 * (b0 + b1)
    c = cu * u + cv * v
    return np.array([c[0], c[1], a1 - a0, b1 - b0, u[0], u[1]], dtype=np.float32)


def rbox_to_quad(rb):
    cx, cy, w, h, ux, uy = [float(t) for t in rb]
    u = np.array([ux, uy], dtype=np.float32)
    v = perp(u)
    c = np.array([cx, cy], dtype=np.float32)
    return np.stack([c - u * w / 2 - v * h / 2, c + u * w / 2 - v * h / 2,
                     c + u * w / 2 + v * h / 2, c - u * w / 2 + v * h / 2]).astype(np.float32)


def pad_rbox(rb, pad_h, pad_w):
    rb = np.array(rb, dtype=np.float32).copy()
    h = max(float(rb[3]), 1.0)
    rb[2] = max(float(rb[2]), 1.0) + pad_w * h
    rb[3] = h * (1.0 + pad_h)
    return rb


def roi_mask_from_polygon(poly, rb_padded, out_h, out_w, supersample=4):
    """Rasterise `poly` (image px) in the oriented RoI frame of `rb_padded` -> (out_h, out_w)."""
    cx, cy, w, h, ux, uy = [float(t) for t in rb_padded]
    u = np.array([ux, uy], dtype=np.float32)
    v = perp(u)
    rel = np.asarray(poly, dtype=np.float32).reshape(-1, 2) - np.array([cx, cy], dtype=np.float32)
    gx = (rel @ u) / max(w / 2.0, 1e-6)
    gy = (rel @ v) / max(h / 2.0, 1e-6)
    H, W = out_h * supersample, out_w * supersample
    px = np.stack([(gx + 1) / 2 * W, (gy + 1) / 2 * H], axis=1)
    canvas = np.zeros((H, W), dtype=np.uint8)
    try:
        cv2.fillPoly(canvas, [np.round(px).astype(np.int32)], 1)
    except cv2.error:
        return np.ones((out_h, out_w), dtype=np.float32)
    m = cv2.resize(canvas.astype(np.float32), (out_w, out_h), interpolation=cv2.INTER_AREA)
    if m.sum() < 1e-3:
        m = np.ones((out_h, out_w), dtype=np.float32)
    return m


def strip_affine(rb_padded, strip_h, strip_w_max):
    """2x3 affine mapping image pixels to a rectified strip in which the padded oriented box occupies
    [0, nw] x [0, strip_h] (reading direction -> +x). Returns (A, nw)."""
    cx, cy, w, h, ux, uy = [float(t) for t in rb_padded]
    w, h = max(w, 1.0), max(h, 1.0)
    nw = int(np.clip(round(w * strip_h / h), 8, strip_w_max))
    sx, sy = nw / w, strip_h / h
    vx, vy = -uy, ux
    A = np.array([[sx * ux, sx * uy, nw / 2.0 - sx * (cx * ux + cy * uy)],
                  [sy * vx, sy * vy, strip_h / 2.0 - sy * (cx * vx + cy * vy)]], dtype=np.float64)
    return A, nw


def rectify_strip(image, rb_padded, strip_h, strip_w_max, max_oversample=8):
    """Cuts the oriented, padded word box out of `image` into a (strip_h, strip_w_max, 3) canvas: text height =
    strip_h, aspect kept (capped at strip_w_max), right-padded with zeros. Downscaling is anti-aliased PER AXIS:
    the warp goes to a canvas oversampled by ceil(0.8 / scale) along each axis, then INTER_AREA brings it to the
    strip size (warpAffine alone aliases; one isotropic factor blurred long lines / missed rotated words).
    Returns (canvas, nw, A_image_to_strip)."""
    A, nw = strip_affine(rb_padded, strip_h, strip_w_max)
    sx, sy = float(np.hypot(A[0, 0], A[0, 1])), float(np.hypot(A[1, 0], A[1, 1]))
    fx = int(min(max_oversample, max(1, math.ceil(0.8 / max(sx, 1e-6)))))
    fy = int(min(max_oversample, max(1, math.ceil(0.8 / max(sy, 1e-6)))))
    if fx > 1 or fy > 1:
        A_big = A.copy()
        A_big[0] *= fx
        A_big[1] *= fy
        big = cv2.warpAffine(image, A_big, (strip_w_max * fx, strip_h * fy), flags=cv2.INTER_LINEAR,
                             borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
        canvas = cv2.resize(big, (strip_w_max, strip_h), interpolation=cv2.INTER_AREA)
    else:
        canvas = cv2.warpAffine(image, A, (strip_w_max, strip_h), flags=cv2.INTER_LINEAR,
                                borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
    canvas[:, nw:] = 0
    return canvas, nw, A


def safe_polygon(p):
    try:
        poly = Polygon(np.asarray(p, dtype=np.float64).reshape(-1, 2))
        if not poly.is_valid:
            poly = poly.buffer(0)
        return poly
    except Exception:
        return None


def polygon_iou(a, b):
    pa, pb = safe_polygon(a), safe_polygon(b)
    if pa is None or pb is None or pa.area <= 0 or pb.area <= 0:
        return 0.0
    try:
        inter = pa.intersection(pb).area
    except Exception:
        return 0.0
    union = pa.area + pb.area - inter
    return float(inter / union) if union > 0 else 0.0


def polygon_inter_over_first(a, b):
    pa, pb = safe_polygon(a), safe_polygon(b)
    if pa is None or pb is None or pa.area <= 0:
        return 0.0
    try:
        return float(pa.intersection(pb).area / pa.area)
    except Exception:
        return 0.0


def compute_box_iou(box1, box2):
    x1 = max(box1[0], box2[0]); y1 = max(box1[1], box2[1])
    x2 = min(box1[2], box2[2]); y2 = min(box1[3], box2[3])
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    area1 = max(0.0, box1[2] - box1[0]) * max(0.0, box1[3] - box1[1])
    area2 = max(0.0, box2[2] - box2[0]) * max(0.0, box2[3] - box2[1])
    union = area1 + area2 - inter
    return inter / max(union, 1e-6)


def prepare_instances(raw, W, H, config, vertex_order='icdar'):
    """Raw annotations [{'poly', 'transcript', 'ignore', 'language'}] -> training instances with a canonical
    polygon, a reading direction u, a curvature flag and the script id. Shared by every dataset class."""
    out = []
    for inst in raw:
        poly = np.asarray(inst['poly'], dtype=np.float32).reshape(-1, 2).copy()
        if len(poly) < 3:
            continue
        poly[:, 0] = np.clip(poly[:, 0], -W, 2 * W)        # guard against corrupt coordinates
        poly[:, 1] = np.clip(poly[:, 1], -H, 2 * H)
        if abs(poly_signed_area(poly)) < 1.0:
            continue
        lang, text = inst.get('language') or 'Unknown', inst.get('transcript', '')
        if len(poly) == 4:
            poly = repair_quad_order(canonical_quad(poly), lang, text, trusted=(vertex_order != 'auto'))
            u, curved = reading_direction_from_quad(poly, lang, text), False
        else:
            u, curved = polygon_reading_direction(poly, lang, text)
        if u[0] < -0.35 and has_rtl(text):
            u = -u                                         # RTL targets are visual-order: time axis runs rightwards
        out.append({'poly': poly, 'u': u, 'curved': curved, 'language': lang, 'transcript': text,
                    'ignore': bool(inst.get('ignore', False)), 'script_id': config.script_id_for(lang)})
    return out


# =====================================================================
# 2. Dataset
# =====================================================================
def shrink_polygon(polygon, ratio, scale=8):
    """PSENet kernel shrinking: offset d = A (1 - r^2) / P. Sub-pixel precision via integer scaling."""
    poly = np.asarray(polygon, dtype=np.float64).reshape(-1, 2)
    if ratio >= 0.999:
        return poly.astype(np.float32)
    sp = safe_polygon(poly)
    if sp is None or sp.area <= 0 or sp.length <= 0:
        return poly.astype(np.float32)
    d = sp.area * (1.0 - ratio ** 2) / sp.length
    try:
        pco = pyclipper.PyclipperOffset()
        pco.AddPath(np.round(poly * scale).astype(np.int64).tolist(), pyclipper.JT_ROUND,
                    pyclipper.ET_CLOSEDPOLYGON)
        out = pco.Execute(-d * scale)
    except pyclipper.ClipperException:
        return poly.astype(np.float32)
    if not out:
        return poly.astype(np.float32)     # PSENet convention: keep the original if it vanishes
    best = max(out, key=lambda q: abs(poly_signed_area(np.asarray(q, dtype=np.float64))))
    if len(best) < 3:
        return poly.astype(np.float32)
    return (np.asarray(best, dtype=np.float64) / scale).astype(np.float32)


def clip_poly_to_rect(poly, x0, y0, x1, y1, scale=8):
    subject = np.round(np.asarray(poly, dtype=np.float64).reshape(-1, 2) * scale).astype(np.int64).tolist()
    if len(subject) < 3:
        return None
    try:
        clipper = pyclipper.Pyclipper()
        rect = [[x0 * scale, y0 * scale], [x1 * scale, y0 * scale], [x1 * scale, y1 * scale], [x0 * scale, y1 * scale]]
        clipper.AddPath(rect, pyclipper.PT_CLIP, True)
        clipper.AddPath(subject, pyclipper.PT_SUBJECT, True)
        sol = clipper.Execute(pyclipper.CT_INTERSECTION, pyclipper.PFT_EVENODD, pyclipper.PFT_EVENODD)
    except pyclipper.ClipperException:
        return None
    if not sol:
        return None
    best = max(sol, key=lambda q: abs(poly_signed_area(np.asarray(q, dtype=np.float64))))
    out = np.asarray(best, dtype=np.float32) / scale
    if len(out) < 3 or abs(poly_signed_area(out)) < 1.0:
        return None
    return out


class ICDAR2019Dataset(Dataset):
    """Training / validation dataset for MLT-2019 (+ optional IC15) in ICDAR quad format.

    Train aug (in order): text-scale-normalised resize -> small / 90deg rotation with canvas expansion
    -> text-biased crop that avoids cutting words -> photometric (colour, blur, JPEG, noise).
    NO horizontal flip: mirroring text while keeping its transcript corrupts recognition labels.
    `MergedSceneTextDataset` subclasses it for the multi-source training set."""

    def __init__(self, items, config, is_train=True):
        self.config = config
        self.items = list(items)
        self.img_paths = [p for p, _ in self.items]        # kept for backwards compatibility
        self.is_train = is_train
        self.num_scales = config.num_kernels
        self.min_scale = config.min_scale

    def __len__(self):
        return len(self.items)

    # ------------------------------------------------------------------ loading
    def _load(self, idx):
        img_path, gt_path = self.items[idx]
        image = load_image_rgb(img_path)
        if image is None:
            image = np.zeros((self.config.img_size, self.config.img_size, 3), dtype=np.uint8)
            return image, []
        H, W = image.shape[:2]
        return image, prepare_instances(read_gt_file(gt_path), W, H, self.config, 'icdar')

    def _item_name(self, idx):
        return os.path.basename(self.items[idx][0])

    def _is_complete(self, idx):
        """False for sources whose annotation does not cover every text instance (no background sampling /
        hard-negative mining on those images: unannotated text would be taught as background)."""
        return True

    def _augmented(self, idx):
        image, insts = self._load(idx)
        if self.is_train:
            image, insts = self._geometric_augment(image, insts)
            image = self._photometric(image)
        else:
            image, insts = self._letterbox(image, insts)
        return image, insts

    shrink_polygon = staticmethod(shrink_polygon)
    clip_poly_to_rect = staticmethod(clip_poly_to_rect)

    # ------------------------------------------------------------------ augmentation
    def _sample_scale(self, h, w, insts):
        c = self.config.img_size
        hs = []
        for inst in insts:
            if inst['ignore']:
                continue
            rb = rbox_from_points(inst['poly'], inst['u'])
            if rb[3] > 1:
                hs.append(float(rb[3]))
        if hs and random.random() < 0.85:
            lo, hi = self.config.target_text_h
            target = math.exp(random.uniform(math.log(lo), math.log(hi)))
            s = target / float(np.median(hs))
        else:
            s = random.uniform(0.8, 2.5) * c / max(h, w)
        lo_s = max(0.05, 0.4 * c / max(h, w))
        hi_s = min(4.0, 3000.0 / max(h, w))
        return hi_s if lo_s > hi_s else float(np.clip(s, lo_s, hi_s))

    @staticmethod
    def _apply_affine(insts, A, b):
        for inst in insts:
            inst['poly'] = (inst['poly'] @ A.T + b).astype(np.float32)
            inst['u'] = _unit(A @ inst['u'])
        return insts

    def _choose_crop(self, insts, bounds):
        """Text-biased crop origin inside the (rotated/scaled) canvas `bounds`=(x0, y0, x1, y1), preferring
        windows that do not cut legible words."""
        c = self.config.img_size
        bx0, by0, bx1, by1 = bounds
        legible = [i for i in insts if not i['ignore']]
        boxes = [(i['poly'][:, 0].min(), i['poly'][:, 1].min(), i['poly'][:, 0].max(), i['poly'][:, 1].max())
                 for i in legible]

        def _full(lo_b, hi_b):
            return (lo_b, hi_b - c) if hi_b - lo_b >= c else (hi_b - c, lo_b)

        def _around(lo_e, hi_e, lo_b, hi_b):
            flo, fhi = _full(lo_b, hi_b)
            lo, hi = max(flo, hi_e - c), min(fhi, lo_e)
            if lo > hi:                                    # word larger than the crop: any window on it
                lo, hi = max(flo, min(lo_e, fhi)), max(flo, min(hi_e - c, fhi))
                lo, hi = min(lo, hi), max(lo, hi)
            return lo, hi

        text_biased = len(boxes) > 0 and random.random() < 0.625
        cands = []
        for _ in range(8):
            if text_biased:
                x0, y0, x1, y1 = boxes[random.randrange(len(boxes))]
                lx, hx = _around(x0, x1, bx0, bx1)
                ly, hy = _around(y0, y1, by0, by1)
            else:
                (lx, hx), (ly, hy) = _full(bx0, bx1), _full(by0, by1)
            tx, ty = random.uniform(lx, hx), random.uniform(ly, hy)
            cut = 0
            for (x0, y0, x1, y1) in boxes:
                inside = x0 >= tx and y0 >= ty and x1 <= tx + c and y1 <= ty + c
                outside = x1 <= tx or y1 <= ty or x0 >= tx + c or y0 >= ty + c
                cut += int(not inside and not outside)
            cands.append((cut, random.random(), tx, ty))
        cands.sort()
        return float(int(cands[0][2])), float(int(cands[0][3]))

    def _geometric_augment(self, image, insts, s=None):
        """Text-scale-normalised scaling + rotation (+/-15deg, occasionally 90deg) + text-biased crop, done
        as ONE affine warp evaluated only on the output crop (cost O(crop^2), independent of the scale).
        `s` lets the caller fix the scale (it may already have decoded the image at reduced resolution)."""
        c = self.config.img_size
        h, w = image.shape[:2]
        if s is None:
            s = self._sample_scale(h, w, insts)
        if s < 0.7:                                        # anti-aliased pre-downscale
            nh, nw = max(1, int(round(h * s))), max(1, int(round(w * s)))
            image = cv2.resize(image, (nw, nh), interpolation=cv2.INTER_AREA)
            sx, sy = nw / float(w), nh / float(h)
            insts = self._apply_affine(insts, np.array([[sx, 0], [0, sy]], dtype=np.float32), np.zeros(2, np.float32))
            h, w = nh, nw
            s = 1.0
        angle = 0.0
        if random.random() < 0.5:
            angle += random.uniform(-15, 15)
        if random.random() < 0.1:
            angle += random.choice([90.0, -90.0])
        M = cv2.getRotationMatrix2D((0.0, 0.0), angle, s)
        A = M[:, :2].astype(np.float32)
        corners = np.array([[0, 0], [w, 0], [w, h], [0, h]], dtype=np.float32) @ A.T
        bx0, by0 = corners.min(0)
        bx1, by1 = corners.max(0)
        insts = self._apply_affine(insts, A, np.zeros(2, np.float32))
        tx, ty = self._choose_crop(insts, (bx0, by0, bx1, by1))
        M[:, 2] = [-tx, -ty]
        out = cv2.warpAffine(image, M, (c, c), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
        insts = self._apply_affine(insts, np.eye(2, dtype=np.float32), np.array([-tx, -ty], dtype=np.float32))
        return out, insts

    @staticmethod
    def _photometric(image):
        img = image.astype(np.float32)
        if random.random() < 0.8:
            alpha = random.uniform(0.7, 1.3)
            beta = random.uniform(-25, 25)
            img = img * alpha + beta
        img = np.clip(img, 0, 255).astype(np.uint8)
        if random.random() < 0.5:
            hsv = cv2.cvtColor(img, cv2.COLOR_RGB2HSV).astype(np.float32)
            hsv[..., 1] = np.clip(hsv[..., 1] * random.uniform(0.7, 1.3), 0, 255)
            hsv[..., 0] = (hsv[..., 0] + random.uniform(-8, 8)) % 180
            img = cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2RGB)
        if random.random() < 0.15:
            k = random.choice([3, 5])
            img = cv2.GaussianBlur(img, (k, k), 0)
        if random.random() < 0.1:                              # incidental (IC15-like) motion blur
            k = random.choice([3, 5, 7, 9])
            ker = np.zeros((k, k), dtype=np.float32)
            ker[k // 2, :] = 1.0
            Mr = cv2.getRotationMatrix2D((k / 2 - 0.5, k / 2 - 0.5), random.uniform(0, 180), 1.0)
            ker = cv2.warpAffine(ker, Mr, (k, k))
            ker /= max(ker.sum(), 1e-6)
            img = cv2.filter2D(img, -1, ker)
        if random.random() < 0.2:
            q = random.randint(30, 90)
            ok, enc = cv2.imencode('.jpg', img[:, :, ::-1], [int(cv2.IMWRITE_JPEG_QUALITY), q])
            if ok:
                img = cv2.imdecode(enc, cv2.IMREAD_COLOR)[:, :, ::-1].copy()
        if random.random() < 0.15:
            noise = np.random.normal(0, random.uniform(3, 10), img.shape).astype(np.float32)
            img = np.clip(img.astype(np.float32) + noise, 0, 255).astype(np.uint8)
        if random.random() < 0.05:
            g = cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)
            img = np.stack([g, g, g], axis=-1)
        return img

    def _letterbox(self, image, insts):
        c = self.config.img_size
        h, w = image.shape[:2]
        s = c / float(max(h, w))
        nh, nw = max(1, int(round(h * s))), max(1, int(round(w * s)))
        image = cv2.resize(image, (nw, nh), interpolation=cv2.INTER_AREA if s < 1 else cv2.INTER_LINEAR)
        image = cv2.copyMakeBorder(image, 0, c - nh, 0, c - nw, cv2.BORDER_CONSTANT, value=(0, 0, 0))
        for inst in insts:
            inst['poly'] = (inst['poly'] * np.array([nw / w, nh / h], dtype=np.float32)).astype(np.float32)
        return image, insts

    # ------------------------------------------------------------------ targets
    def _jitter_rbox(self, rb):
        """Imperfect-box jitter in units of the text HEIGHT. V4 scaled the shift, width change and rotation with the
        line LENGTH, which cut whole characters off long CJK lines while their full CTC label was kept."""
        rb = rb.copy()
        w, h = float(rb[2]), float(rb[3])
        u = rb[4:6].copy()
        v = perp(u)
        shift = u * random.gauss(0, 0.06) * h + v * random.gauss(0, 0.06) * h
        rb[0] += shift[0]
        rb[1] += shift[1]
        rb[2] = w + h * random.uniform(-0.05, 0.3)
        rb[3] = h * random.uniform(0.95, 1.15)
        max_deg = min(2.0, math.degrees(math.atan2(0.1 * h, max(w / 2.0, 1e-3))))   # end corners move <~0.1 h
        a = math.radians(random.gauss(0, max_deg))
        ca, sa = math.cos(a), math.sin(a)
        rb[4], rb[5] = ca * u[0] - sa * u[1], sa * u[0] + ca * u[1]
        return rb

    def _sample_background_rois(self, gt_any_ds, legible_h, n, rng):
        c = self.config.img_size
        ds = self.config.feature_stride
        out = []
        for _ in range(n * 8):
            if len(out) >= n:
                break
            h = (rng.choice(legible_h) * rng.uniform(0.7, 1.4)) if legible_h else rng.uniform(8, 48)
            h = float(np.clip(h, 6, c * 0.5))
            w = float(min(h * rng.uniform(1.0, 6.0), c * 0.9))
            ang = math.radians(rng.uniform(-15, 15) + (90.0 if rng.random() < 0.1 else 0.0))
            u = np.array([math.cos(ang), math.sin(ang)], dtype=np.float32)
            cx = rng.uniform(w / 2, max(w / 2 + 1, c - w / 2))
            cy = rng.uniform(h / 2, max(h / 2 + 1, c - h / 2))
            rb = np.array([cx, cy, w, h, u[0], u[1]], dtype=np.float32)
            quad = rbox_to_quad(rb)
            tmp = np.zeros_like(gt_any_ds, dtype=np.uint8)
            cv2.fillPoly(tmp, [np.round(quad / ds).astype(np.int32)], 1)
            area = tmp.sum()
            if area == 0:
                continue
            if (tmp.astype(bool) & (gt_any_ds > 0)).sum() / float(area) > 0.05:
                continue
            out.append((rb, quad))
        return out

    def _build_targets(self, image, insts, rng, complete=True):
        cfg = self.config
        c, ds = cfg.img_size, cfg.feature_stride
        m = c // ds
        K = self.num_scales
        mw = cfg.roi_w_long
        k_full = np.zeros((K, c, c), dtype=np.uint8)
        tm_full = np.ones((c, c), dtype=np.uint8)
        dir_ds = np.zeros((2, m, m), dtype=np.float32)
        dirw_ds = np.zeros((m, m), dtype=np.float32)
        any_full = np.zeros((c, c), dtype=np.uint8)
        text_rois, ign_rois, legible_h = [], [], []
        for inst in insts:
            poly = inst['poly']
            full_area = abs(poly_signed_area(poly))
            if full_area < 1.0:
                continue
            clipped = clip_poly_to_rect(poly, 0, 0, c, c)
            if clipped is None:
                continue
            vis = abs(poly_signed_area(clipped)) / full_area
            rb = rbox_from_points(poly, inst['u'])
            ipoly = np.round(poly).astype(np.int32)
            cv2.fillPoly(any_full, [ipoly], 1)
            small = min(rb[2], rb[3]) < cfg.min_text_px
            if inst['ignore'] or small:
                cv2.fillPoly(tm_full, [ipoly], 0)
                if inst['ignore'] and not small and vis > 0.5:
                    ign_rois.append((rb, clipped))
                continue
            legible_h.append(float(rb[3]))
            for k in range(K):
                ratio = 1.0 - (1.0 - self.min_scale) * (K - 1 - k) / max(K - 1, 1)
                sp = shrink_polygon(poly, ratio)
                cv2.fillPoly(k_full[k], [np.round(sp).astype(np.int32)], 1)
            tmpm = np.zeros((m, m), dtype=np.uint8)
            cv2.fillPoly(tmpm, [np.round(poly / ds).astype(np.int32)], 1)
            msk = tmpm.astype(bool)
            if msk.any():
                dir_ds[0][msk] = inst['u'][0]
                dir_ds[1][msk] = inst['u'][1]
                dirw_ds[msk] = 1.0 / math.sqrt(float(msk.sum()))
            if vis < 0.5:                      # mostly outside the crop: supervise the masks only
                continue
            seq, tlen, n_oov = cfg.encode_text(inst['transcript'])
            # FIX (V5): labels longer than max_seq_len were truncated and still trained CTC; words partly outside
            # the crop (V4: up to 15% cut away) kept their full label; strongly curved polygons cannot be read from
            # one straight oriented RoI.
            rec_valid = (vis >= 0.98) and (n_oov == 0) and (tlen > 0) and cfg.text_fits(inst['transcript']) \
                and not inst.get('curved', False)
            text_rois.append(dict(rb=rb, poly=clipped, seq=seq, tlen=tlen, script=inst['script_id'],
                                  rec_valid=rec_valid, verify=0,
                                  fam=cfg.family_target(inst['transcript'], inst['script_id'])))

        kernels = np.stack([cv2.resize(k_full[k].astype(np.float32), (m, m), interpolation=cv2.INTER_AREA)
                            for k in range(K)])
        tm = (cv2.resize(tm_full.astype(np.float32), (m, m), interpolation=cv2.INTER_AREA) > 0.5).astype(np.float32)
        gt_any = (cv2.resize(any_full.astype(np.float32), (m, m), interpolation=cv2.INTER_AREA) > 0).astype(np.float32)

        # ---------------- RoIs: legible text / illegible text / background ----------------
        rng.shuffle(text_rois)
        text_rois = text_rois[:cfg.max_text_rois_per_img]
        rois = []
        for r in text_rois:
            rb = r['rb']
            if self.is_train and rng.random() < cfg.box_jitter_prob:
                rb = self._jitter_rbox(rb)
            rbp = pad_rbox(rb, cfg.roi_pad_h, cfg.roi_pad_w)
            rois.append(dict(rbox=rbp, roi_mask=roi_mask_from_polygon(r['poly'], rbp, cfg.roi_h, mw),
                             text_seq=r['seq'], text_len=r['tlen'] if r['rec_valid'] else 0,
                             script_id=r['script'], rec_valid=int(r['rec_valid']), verify=0,
                             family_target=r['fam']))
        rng.shuffle(ign_rois)
        for rb, poly in ign_rois[:4]:
            rbp = pad_rbox(rb, cfg.roi_pad_h, cfg.roi_pad_w)
            rois.append(dict(rbox=rbp, roi_mask=roi_mask_from_polygon(poly, rbp, cfg.roi_h, mw),
                             text_seq=np.zeros(cfg.max_seq_len, dtype=np.int64), text_len=0,
                             script_id=-100, rec_valid=0, verify=1, family_target=np.zeros(4, np.float32)))
        if complete:
            for rb, quad in self._sample_background_rois(gt_any, legible_h, cfg.num_bg_rois_per_img, rng):
                rbp = pad_rbox(rb, cfg.roi_pad_h, cfg.roi_pad_w)
                rois.append(dict(rbox=rbp, roi_mask=roi_mask_from_polygon(quad, rbp, cfg.roi_h, mw),
                                 text_seq=np.zeros(cfg.max_seq_len, dtype=np.int64), text_len=0,
                                 script_id=-100, rec_valid=0, verify=2, family_target=np.zeros(4, np.float32)))
        return kernels, tm, dir_ds, dirw_ds, gt_any, rois

    def __getitem__(self, idx):
        rng = random.Random() if self.is_train else random.Random(1000003 * (idx + 1))
        image, insts = self._augmented(idx)
        complete = self._is_complete(idx)
        kernels, tm, dir_ds, dirw_ds, gt_any, rois = self._build_targets(image, insts, rng, complete)
        image_t = torch.from_numpy(np.ascontiguousarray(image)).permute(2, 0, 1).float() / 255.0
        return {
            'image': image_t,
            'masks': torch.from_numpy(kernels),
            'training_mask': torch.from_numpy(tm),
            'direction': torch.from_numpy(dir_ds),
            'direction_weight': torch.from_numpy(dirw_ds),
            'gt_any': torch.from_numpy(gt_any),
            'complete': bool(complete),
            'instances': rois,
            'filename': self._item_name(idx),
        }


def make_collate_fn(config):
    def collate_fn(batch):
        out = {
            'image': torch.stack([b['image'] for b in batch]),
            'masks': torch.stack([b['masks'] for b in batch]),
            'training_mask': torch.stack([b['training_mask'] for b in batch]),
            'direction': torch.stack([b['direction'] for b in batch]),
            'direction_weight': torch.stack([b['direction_weight'] for b in batch]),
            'gt_any': torch.stack([b['gt_any'] for b in batch]),
            'complete': torch.tensor([bool(b.get('complete', True)) for b in batch], dtype=torch.bool),
            'filename': [b['filename'] for b in batch],
        }
        bi, rb, rm, ts, tl, sid, rv, vf, ft = [], [], [], [], [], [], [], [], []
        for i, b in enumerate(batch):
            for r in b['instances']:
                bi.append(i); rb.append(r['rbox']); rm.append(r['roi_mask']); ts.append(r['text_seq'])
                tl.append(r['text_len']); sid.append(r['script_id']); rv.append(r['rec_valid']); vf.append(r['verify'])
                ft.append(r['family_target'])
        if bi:
            out.update({
                'batch_idx': torch.tensor(bi, dtype=torch.long),
                'rboxes': torch.from_numpy(np.stack(rb).astype(np.float32)),
                'roi_masks': torch.from_numpy(np.stack(rm).astype(np.float32)),
                'text_seq': torch.from_numpy(np.stack(ts).astype(np.int64)),
                'text_len': torch.tensor(tl, dtype=torch.long),
                'script_id': torch.tensor(sid, dtype=torch.long),
                'rec_valid': torch.tensor(rv, dtype=torch.bool),
                'verify': torch.tensor(vf, dtype=torch.long),
                'family_target': torch.from_numpy(np.stack(ft).astype(np.float32)),
            })
        else:
            out.update({
                'batch_idx': torch.zeros(0, dtype=torch.long),
                'rboxes': torch.zeros((0, 6), dtype=torch.float32),
                'roi_masks': torch.zeros((0, config.roi_h, config.roi_w_long), dtype=torch.float32),
                'text_seq': torch.zeros((0, config.max_seq_len), dtype=torch.long),
                'text_len': torch.zeros(0, dtype=torch.long),
                'script_id': torch.zeros(0, dtype=torch.long),
                'rec_valid': torch.zeros(0, dtype=torch.bool),
                'verify': torch.zeros(0, dtype=torch.long),
                'family_target': torch.zeros((0, 4), dtype=torch.float32),
            })
        return out
    return collate_fn


class ICDAR2019TestDataset(Dataset):
    """Kept for API compatibility: yields full-resolution images + filenames (the SpottingEngine
    handles resizing / tiling itself)."""

    def __init__(self, img_dir, config):
        self.config = config
        self.img_paths = list_images(img_dir)

    def __len__(self):
        return len(self.img_paths)

    def __getitem__(self, idx):
        p = self.img_paths[idx]
        return load_image_rgb(p), os.path.basename(p)


# =====================================================================
# 2b. Optional word-crop recognition stream (LMDB or txt label file)
# =====================================================================
try:
    import lmdb
    HAS_LMDB = True
except Exception:
    lmdb = None
    HAS_LMDB = False


def _iter_crop_labels(src, limit=None):
    """Yields labels only (used for vocabulary building)."""
    n = 0
    if src.get('type') == 'lmdb':
        if not HAS_LMDB or not os.path.isdir(src['path']):
            return
        env = lmdb.open(src['path'], readonly=True, lock=False, readahead=False, meminit=False)
        with env.begin() as txn:
            total = int(txn.get(b'num-samples') or 0)
            for i in range(1, total + 1):
                lab = txn.get(f'label-{i:09d}'.encode())
                if lab is not None:
                    yield lab.decode('utf-8', 'ignore')
                    n += 1
                    if limit and n >= limit:
                        break
        env.close()
    elif src.get('type') == 'txt' and os.path.exists(src['path']):
        with open(src['path'], encoding='utf-8', errors='ignore') as f:
            for line in f:
                parts = line.rstrip('\n').split('\t', 1)
                if len(parts) == 2:
                    yield parts[1]
                    n += 1
                    if limit and n >= limit:
                        break


def _strip_item(cfg, canvas, nw, poly_in_strip, label, lang):
    """Common dict for one rectified word strip (external crop or scene strip)."""
    H = cfg.roi_h * cfg.feature_stride
    seq, tlen, n_oov = cfg.encode_text(label)
    sid = cfg.script_id_for(lang) if label else -100
    rec_valid = bool(label) and n_oov == 0 and tlen > 0 and cfg.text_fits(label)
    rb = np.array([nw / 2.0, H / 2.0, float(nw), float(H), 1.0, 0.0], np.float32)
    if poly_in_strip is None:
        # FIX (V5): the RoI covers exactly the word, so in RoI coordinates the whole RoI is text. V4 built the mask
        # in canvas coordinates and silently masked out the right part of every word narrower than the canvas.
        mask = np.ones((cfg.roi_h, cfg.roi_w_long), np.float32)
    else:
        mask = roi_mask_from_polygon(poly_in_strip, rb, cfg.roi_h, cfg.roi_w_long)
    return {'image': torch.from_numpy(np.ascontiguousarray(canvas)).permute(2, 0, 1).float() / 255.0,
            'nw': int(nw), 'rbox': rb, 'roi_mask': mask, 'text_seq': seq, 'text_len': tlen if rec_valid else 0,
            'script_id': sid, 'rec_valid': rec_valid,
            'family_target': cfg.family_target(label, sid) if label else np.zeros(4, np.float32)}


class CropRecognitionDataset(Dataset):
    """Word crops -> (roi_h*4) x (roi_w_long*4) canvas (aspect kept, right-padded). The whole canvas goes through
    the SAME dense network and recogniser as the spotting branch, with one RoI covering the word. Tall crops
    (vertical lines) are rotated 90deg CCW so that top-to-bottom reading becomes left-to-right (same
    convention as the reading-direction field). Only the recognition / script / family losses are applied."""

    def __init__(self, sources, config, max_samples=None):
        self.cfg = config
        self.H, self.W = config.roi_h * config.feature_stride, config.roi_w_long * config.feature_stride
        # LMDB entries live in two numpy arrays (no per-sample Python objects: forked workers would otherwise
        # copy a multi-million-entry list page by page); txt entries (small) stay in a list.
        self.sources = sources
        self._envs = {}
        lm_src, lm_key, self.txt = [], [], []
        for si, src in enumerate(sources):
            if src.get('type') == 'lmdb' and HAS_LMDB and os.path.isdir(src['path']):
                env = lmdb.open(src['path'], readonly=True, lock=False, readahead=False, meminit=False)
                with env.begin() as txn:
                    total = int(txn.get(b'num-samples') or 0)
                env.close()
                lm_src.append(np.full(total, si, dtype=np.int32))
                lm_key.append(np.arange(1, total + 1, dtype=np.int64))
            elif src.get('type') == 'txt' and os.path.exists(src['path']):
                with open(src['path'], encoding='utf-8', errors='ignore') as f:
                    for line in f:
                        parts = line.rstrip('\n').split('\t', 1)
                        if len(parts) == 2:
                            self.txt.append((si, (os.path.join(src.get('root', ''), parts[0]), parts[1])))
            else:
                print(f"[crop-rec] source skipped (missing path or lmdb not installed): {src}")
        self.lm_src = np.concatenate(lm_src) if lm_src else np.zeros(0, np.int32)
        self.lm_key = np.concatenate(lm_key) if lm_key else np.zeros(0, np.int64)
        n = len(self.lm_key) + len(self.txt)
        self.order = None
        if max_samples and n > max_samples:
            self.order = np.random.RandomState(0).permutation(n)[:max_samples]

    def __len__(self):
        return len(self.order) if self.order is not None else len(self.lm_key) + len(self.txt)

    def _entry(self, idx):
        idx = int(self.order[idx]) if self.order is not None else idx
        if idx < len(self.lm_key):
            return int(self.lm_src[idx]), int(self.lm_key[idx])
        return self.txt[idx - len(self.lm_key)]

    def _read(self, si, key):
        src = self.sources[si]
        if src['type'] == 'lmdb':
            env = self._envs.get(si)
            if env is None:                    # opened lazily inside each worker process
                env = lmdb.open(src['path'], readonly=True, lock=False, readahead=False, meminit=False)
                self._envs[si] = env
            with env.begin() as txn:
                buf = txn.get(f'image-{key:09d}'.encode())
                lab = txn.get(f'label-{key:09d}'.encode())
            if buf is None or lab is None:
                return None, ''
            img = cv2.imdecode(np.frombuffer(buf, dtype=np.uint8), cv2.IMREAD_COLOR)
            img = None if img is None else cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
            return img, lab.decode('utf-8', 'ignore')
        path, lab = key
        return load_image_rgb(path), lab

    def __getitem__(self, idx):
        si, key = self._entry(idx)
        img, label = self._read(si, key)
        label = normalize_transcript(label)
        if img is None or img.size == 0:
            img, label = np.zeros((self.H, self.W, 3), np.uint8), ''
        lang = resolve_script(label, None, self.sources[si].get('script_hint'))   # kanji-only Japanese crops
        h, w = img.shape[:2]
        if h > 1.5 * w and len(label) >= 2:          # tall multi-char crop: vertical line -> read left-to-right
            img = cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)
            h, w = img.shape[:2]
        img = ICDAR2019Dataset._photometric(img)
        nw = int(min(self.W, max(8, round(w * self.H / max(h, 1)))))
        canvas = np.zeros((self.H, self.W, 3), np.uint8)
        canvas[:, :nw] = cv2.resize(img, (nw, self.H), interpolation=cv2.INTER_AREA if h > self.H else cv2.INTER_LINEAR)
        return _strip_item(self.cfg, canvas, nw, None, label, lang)


def collate_crops(batch, max_items=None):
    """Collates word crops / scene strips (items may be dicts or lists of dicts). The canvas is trimmed to the
    widest strip of the batch (multiple of 32), so short words do not pay for the long-line canvas.
    Returns None when the batch holds no strip."""
    flat = []
    for b in batch:
        if isinstance(b, (list, tuple)):
            flat.extend(b)
        elif b is not None:
            flat.append(b)
    if max_items:
        flat = flat[:max_items]
    if not flat:
        return None
    wt = max(64, int(math.ceil(max(f['nw'] for f in flat) / 32.0) * 32))
    return {'image': torch.stack([f['image'][:, :, :wt] for f in flat]),
            'batch_idx': torch.arange(len(flat), dtype=torch.long),
            'rboxes': torch.from_numpy(np.stack([f['rbox'] for f in flat])),
            'roi_masks': torch.from_numpy(np.stack([f['roi_mask'] for f in flat])),
            'text_seq': torch.from_numpy(np.stack([f['text_seq'] for f in flat]).astype(np.int64)),
            'text_len': torch.tensor([f['text_len'] for f in flat], dtype=torch.long),
            'script_id': torch.tensor([f['script_id'] for f in flat], dtype=torch.long),
            'rec_valid': torch.tensor([f['rec_valid'] for f in flat], dtype=torch.bool),
            'family_target': torch.from_numpy(np.stack([f['family_target'] for f in flat]).astype(np.float32))}


class _CropCollate:
    """Picklable collate with a cap on the number of strips per batch."""

    def __init__(self, max_items=None):
        self.max_items = max_items

    def __call__(self, batch):
        return collate_crops(batch, self.max_items)


# =====================================================================
# 2c. Multi-source merge: public Chinese / Japanese / Korean scene-text sets
# =====================================================================
# Every set below has the characteristics of MLT-19 / IC15: photographs of natural scenes (synthetic text rendered
# onto natural backgrounds for SynthMLT), multi-oriented word- or line-level quadrilateral / polygon boxes,
# transcriptions, and "###" / illegible don't-care regions. All are free for research use; read each licence page.
# 'files' are the ORIGINAL distribution points (the organisers' own hosts), fetched automatically by
# `acquire_public_sources`; sizes / MD5s are used to verify complete downloads where they are known.
# 'fallback' entries are used only when every original location fails, and are labelled as third-party mirrors.
_SYNTH_BASE = 'http://ptak.felk.cvut.cz/public_datasets/SyntText/'
_HF_SYNTH = 'https://huggingface.co/datasets/Yesianrohn/SynthMLT/resolve/main/'
_BCE = 'https://dataset-bj.cdn.bcebos.com/'


def _f(url, size=None, md5=None, extract=None):
    """One downloadable file. extract: None (keep), 'here' (into the source folder) or 'stem' (into <folder>/<stem>)."""
    if extract is None and url.endswith(('.zip', '.tar', '.tar.gz', '.tgz')):
        extract = 'here'
    return {'url': url, 'size': size, 'md5': md5, 'extract': extract}


PUBLIC_SOURCE_CATALOG = {
    'lsvt': {'format': 'lsvt', 'group': 'zh', 'script_hint': 'Chinese', 'kind': 'real', 'complete': True,
             'files': [_f(_BCE + 'lsvt/train_full_images_0.tar.gz', 4367864124),
                       _f(_BCE + 'lsvt/train_full_images_1.tar.gz', 4383014034),
                       _f(_BCE + 'lsvt/train_full_labels.json', 192791636)],
             'label_file': 'train_full_labels.json',
             'homepage': 'https://rrc.cvc.uab.es/?ch=16',
             'note': 'LSVT-19 (Sun et al., ICCV 2019): 30,000 fully annotated street-view images, one JSON '
                     '{"gt_N": [{"points": [[x, y], ...], "transcription", "illegibility"}]}; hosted by Baidu, '
                     'the organiser'},
    'art': {'format': 'art', 'group': 'zh', 'script_hint': None, 'kind': 'real', 'complete': True,
            'files': [_f(_BCE + 'art/train_images.tar.gz', 1639636218),
                      _f(_BCE + 'art/train_labels.json', 42936328)],
            'label_file': 'train_labels.json',
            'homepage': 'https://rrc.cvc.uab.es/?ch=14',
            'note': 'ArT-19 (Chng et al., ICDAR 2019): 5,603 train images (Chinese + Latin, arbitrary shape; includes '
                    'Total-Text and SCUT-CTW1500), one JSON with polygons and a "language" field'},
    'rects': {'format': 'rects', 'group': 'zh', 'script_hint': 'Chinese', 'kind': 'real', 'complete': True,
              'files': [_f('https://datasets.cvc.uab.es/rrc/ReCTS.zip')],
              'homepage': 'https://rrc.cvc.uab.es/?ch=12',
              'note': 'ReCTS-19 (Liu et al., ICDAR 2019): 20,000 train images of Chinese signboards, per-image JSON '
                      '{"lines": [{"points": [8 values], "transcription", "ignore"}], "chars": [...]}'},
    'kaist': {'format': 'kaist', 'group': 'ko', 'script_hint': 'Korean', 'kind': 'real', 'complete': False,
              'files': [_f('http://www.iapr-tc11.org/dataset/KAIST_SceneText/KAIST_all.zip')],
              'homepage': 'http://www.iapr-tc11.org/mediawiki/index.php/KAIST_Scene_Text_Database',
              'note': 'KAIST Scene Text (Jung et al., 2011): ~3,000 Korean / English / mixed scene photos, XML word '
                      'boxes with per-character labels (nested zips). Not every word is annotated -> no background '
                      'mining.'},
    'rctw17': {'format': 'rctw', 'group': 'zh', 'script_hint': 'Chinese', 'kind': 'real', 'complete': True,
               'files': [],
               'homepage': 'https://rctw.vlrlab.net/dataset',
               'note': 'RCTW-17 (Shi et al., ICDAR 2017): 8,034 train images, line quads "x1,...,y4,difficult,\\"text\\"". '
                       'The organisers now distribute the training set only through Baidu Pan (the HUST mirror no '
                       'longer resolves), which cannot be scripted: put direct URLs in Config.custom_download_urls '
                       "['rctw17'] (e.g. your own copy of train_images.zip.001/.002 + train_gts.zip) or attach it."},
}
for _code, _lang in (('zh', 'Chinese'), ('ja', 'Japanese'), ('ko', 'Korean')):
    PUBLIC_SOURCE_CATALOG['synthmlt_' + _code] = {
        'format': 'mlt', 'group': _code, 'script_hint': _lang, 'kind': 'synthetic', 'complete': True,
        'vertex_order': 'auto',
        'files': [_f(_SYNTH_BASE + _lang + '.zip'), _f(_SYNTH_BASE + _lang + '_gt.zip')],
        'fallback': {'kind': 'lmdb_crops', 'urls': [_HF_SYNTH + _lang + '/data.mdb', _HF_SYNTH + _lang + '/lock.mdb'],
                     'note': 'third-party Hugging Face mirror of the SynthMLT ' + _lang + ' word crops (LMDB, '
                             'recognition only)'},
        'homepage': 'https://github.com/MichalBusta/E2E-MLT',
        'note': 'SynthMLT (Busta et al., ACCV 2018; the ICDAR-2019 MLT synthetic set), MLT GT format, original host '
                'is HTTP-only'}
# Base sets: IC15 from the RRC (MD5s as published by MMOCR's dataset zoo); MLT-19 needs an RRC account, so its
# automatic fallback is a Kaggle copy (Config.mlt_kaggle_mirrors).
IC15_RRC_FILES = [
    _f('https://rrc.cvc.uab.es/downloads/ch4_training_images.zip', md5='c51cbace155dcc4d98c8dd19d378f30d', extract='stem'),
    _f('https://rrc.cvc.uab.es/downloads/ch4_training_localization_transcription_gt.zip',
       md5='3bfaf1988960909014f7987d2343060b', extract='stem'),
    _f('https://rrc.cvc.uab.es/downloads/ch4_test_images.zip', md5='97e4c1ddcf074ffcc75feff2b63c35dd', extract='stem'),
    _f('https://rrc.cvc.uab.es/downloads/Challenge4_Test_Task4_GT.zip', md5='8bce173b06d164b98c357b0eb96ef430',
       extract='stem')]
# Hosts whose HTTPS certificate chain fails standard verification (incomplete chain / self-signed). Their files are
# tried over verified HTTPS, then plain HTTP, then (only if download_allow_legacy_tls) unverified HTTPS.
LEGACY_TLS_HOSTS = {'datasets.cvc.uab.es', 'rrc.cvc.uab.es', 'ptak.felk.cvut.cz'}
INDEX_VERSION = 'v5.2'
PER_IMAGE_FORMATS = {'mlt': '.txt', 'icdar': '.txt', 'rctw': '.txt', 'rects': '.json', 'kaist': '.xml'}

ImageRecord = namedtuple('ImageRecord', ['img', 'src', 'w', 'h', 'ann', 'scripts'])


# ------------------------------------------------------------------ annotation parsers -> [(pts, text, ign, lang)]
def _parse_icdar_file(path):
    return [(inst['poly'].reshape(-1).tolist(), inst['transcript'], inst['ignore'], inst['language'])
            for inst in read_gt_file(path)]


def _parse_rctw_file(path):
    out = []
    with open(path, encoding='utf-8-sig', errors='ignore') as f:
        for line in f:
            parts = line.rstrip('\r\n').split(',')
            if len(parts) < 10:
                continue
            try:
                pts = [float(v) for v in parts[:8]]
            except ValueError:
                continue
            text = ','.join(parts[9:]).strip()
            if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
                text = text[1:-1]
            out.append((pts, text, parts[8].strip() not in ('0', ''), None))
    return out


def _parse_rects_file(path):
    with open(path, encoding='utf-8-sig', errors='ignore') as f:
        d = json.load(f)
    out = []
    for ln in d.get('lines', []):
        pts = np.asarray(ln.get('points', []), dtype=np.float64).reshape(-1)
        if len(pts) >= 6:
            out.append((pts.tolist(), ln.get('transcription', ''), bool(ln.get('ignore', 0)), None))
    return out


def _read_xml_text(path):
    raw = open(path, 'rb').read()
    m = re.search(rb'encoding=["\']([A-Za-z0-9_\-]+)["\']', raw[:300])
    encs = ([m.group(1).decode('ascii', 'ignore')] if m else []) + ['utf-8', 'cp949', 'euc-kr', 'latin-1']
    txt = None
    for e in encs:
        try:
            txt = raw.decode(e)
            break
        except (LookupError, UnicodeDecodeError):
            continue
    return re.sub(r'^\s*<\?xml[^>]*\?>', '', txt or '')


def _kaist_words_regex(txt):
    """Tolerant fallback for KAIST files that are not well-formed XML (e.g. an unescaped '&' in a char attribute)."""
    out = []
    for m in re.finditer(r'<word\b([^>]*)>(.*?)</word>', txt, re.S):
        attrs = dict(re.findall(r'(\w+)\s*=\s*"([^"]*)"', m.group(1)))
        chars = re.findall(r'<character\b[^>]*?\bchar\s*=\s*"([^"]*)"', m.group(2))
        out.append((attrs, ''.join(chars)))
    return out


def _parse_kaist_file(path):
    """KAIST XML: <word x y width height><character ... char="X"/>...</word>; axis-aligned word boxes."""
    txt = _read_xml_text(path)
    try:
        words = [(w.attrib, ''.join(c.attrib.get('char', '') for c in w.iter('character')))
                 for w in ET.fromstring(txt).iter('word')]
    except ET.ParseError:
        words = _kaist_words_regex(txt)
    out = []
    for attrs, text in words:
        try:
            x, y = float(attrs['x']), float(attrs['y'])
            w, h = float(attrs['width']), float(attrs['height'])
        except (KeyError, ValueError):
            continue
        out.append(([x, y, x + w, y, x + w, y + h, x, y + h], text, text.strip() == '', None))
    return out


_PARSERS = {'mlt': _parse_icdar_file, 'icdar': _parse_icdar_file, 'rctw': _parse_rctw_file,
            'rects': _parse_rects_file, 'kaist': _parse_kaist_file}


def _load_json_labels(path):
    """LSVT / ArT single-file labels: {"gt_N": [{"points", "transcription", "illegibility", ["language"]}]}."""
    with open(path, encoding='utf-8-sig') as f:
        d = json.load(f)
    if isinstance(d, list):
        merged = {}
        for e in d:
            if isinstance(e, dict):
                merged.update(e)
        d = merged
    out = {}
    for key, anns in d.items():
        raw = []
        for a in anns or []:
            pts = np.asarray(a.get('points', []), dtype=np.float64).reshape(-1)
            if len(pts) < 6:
                continue
            lang = a.get('language')
            lang = lang if lang and lang.lower() in _SCRIPT_NAMES_LOWER else None
            raw.append((pts.tolist(), a.get('transcription', ''), bool(a.get('illegibility', False)), lang))
        out[key] = raw
    return out


def _load_paddle_labels(path, img_root):
    """PaddleOCR detection labels: one line per image 'relpath<TAB>[{"transcription", "points", "difficult"}]'."""
    out = {}
    with open(path, encoding='utf-8-sig', errors='ignore') as f:
        for line in f:
            parts = line.rstrip('\r\n').split('\t', 1)
            if len(parts) != 2:
                continue
            try:
                anns = json.loads(parts[1])
            except ValueError:
                continue
            cands = [os.path.join(img_root, parts[0]), os.path.join(img_root, os.path.basename(parts[0]))]
            img = next((c for c in cands if os.path.exists(c)), None)
            if img is None:
                continue
            raw = []
            for a in anns:
                pts = np.asarray(a.get('points', []), dtype=np.float64).reshape(-1)
                if len(pts) >= 6:
                    raw.append((pts.tolist(), a.get('transcription', ''), bool(a.get('difficult', False)), None))
            out[img] = raw
    return out


def _compact_annotations(raw, hint):
    """[(pts, text, ignore, language|None)] -> [[pts rounded], text, ignore 0/1, resolved language]."""
    out = []
    for pts, text, ign, lang in raw:
        pts = np.asarray(pts, dtype=np.float64).reshape(-1)
        if len(pts) < 6 or len(pts) % 2 or not np.all(np.isfinite(pts)):
            continue
        text = normalize_transcript(text)
        ign = bool(ign) or text in ('', '###')
        if ign:
            lang = 'None'
        else:
            lang = resolve_script(text, lang, hint)
            if lang.lower() == 'none':
                ign = True
        out.append([[round(float(v), 1) for v in pts], text, int(ign), lang])
    return out


def _script_counts(anns, script2id):
    c = Counter()
    for _, _, ign, lang in anns:
        if not ign:
            c[script2id.get((lang or '').lower(), script2id['unknown'])] += 1
    return tuple(sorted(c.items()))


def _index_task(task):
    """Pool worker: (fmt, img, gt_path | None, hint, pre-parsed raw | None) -> (img, w, h, ann_json, n_legible)."""
    fmt, img, gt, hint, raw = task
    try:
        if raw is None:
            raw = _PARSERS[fmt](gt)
        anns = _compact_annotations(raw, hint)
    except Exception:
        return None
    if img is None or not os.path.exists(img):
        return None
    sz = image_size(img) or (0, 0)
    return img, sz[0], sz[1], json.dumps(anns, ensure_ascii=False)


def _pool_map(fn, tasks, workers, desc):
    if workers <= 1 or len(tasks) < 64:
        return [fn(t) for t in tqdm(tasks, desc=desc, mininterval=5.0)]
    try:
        ctx = mp.get_context('fork')
    except ValueError:
        ctx = mp.get_context()
    with ctx.Pool(workers) as pool:
        return list(tqdm(pool.imap(fn, tasks, chunksize=32), total=len(tasks), desc=desc, mininterval=5.0))


def _strip_gt_prefix(stem):
    for p in ('gt_', 'res_'):
        if stem.startswith(p):
            return stem[len(p):]
    return stem


def _dir_affinity(img_path, gt_path):
    """Number of trailing directory names shared by an image and a GT file ('X_gt' counts as 'X')."""
    a = os.path.dirname(img_path).split(os.sep)[::-1]
    b = [d[:-3] if d.lower().endswith('_gt') else d for d in os.path.dirname(gt_path).split(os.sep)[::-1]]
    n = 0
    for x, y in zip(a, b):
        if x.lower() != y.lower():
            break
        n += 1
    return n


def _pair_images_with_gt(img_dir, gt_dir, ext):
    """Pairs images with GT files by stem ('gt_' / 'res_' prefixes ignored). When a stem occurs in several folders
    (synthetic sets numbered per sub-folder), the GT whose folder path matches the image's best wins; ties are
    dropped rather than guessed."""
    imgs = list_images_recursive(img_dir)
    raw, stripped = defaultdict(list), defaultdict(list)
    for dp, dn, fn in os.walk(gt_dir):
        dn.sort()
        for f in sorted(fn):
            if f.lower().endswith(ext):
                stem = os.path.splitext(f)[0]
                raw[stem].append(os.path.join(dp, f))
                if _strip_gt_prefix(stem) != stem:
                    stripped[_strip_gt_prefix(stem)].append(os.path.join(dp, f))
    pairs, ambiguous = [], 0
    for p in imgs:
        stem = os.path.splitext(os.path.basename(p))[0]
        cands = raw.get(stem) or stripped.get(stem)     # 'gt_N.jpg' + 'gt_N.txt' as well as 'img_N' + 'gt_img_N'

        if not cands:
            continue
        if len(cands) == 1:
            pairs.append((p, cands[0]))
            continue
        scored = sorted(((_dir_affinity(p, g), g) for g in cands), reverse=True)
        if scored[0][0] > scored[1][0]:
            pairs.append((p, scored[0][1]))
        else:
            ambiguous += 1
    if ambiguous:
        print(f"[sources] {ambiguous} images in {img_dir} have several equally plausible GT files - skipped")
    return pairs


class FrozenRecords:
    """Read-only ImageRecord sequence stored in a few numpy buffers (paths and annotation JSON as one UTF-8 blob
    each, plus offsets). Unlike a list of Python objects, whose reference counts are written whenever a forked
    DataLoader worker touches them (copying every page it reads), these buffers stay shared copy-on-write."""

    def __init__(self, records, num_scripts):
        n = len(records)
        self.src = np.fromiter((r.src for r in records), np.int32, n)
        self.w = np.fromiter((r.w or 0 for r in records), np.int32, n)
        self.h = np.fromiter((r.h or 0 for r in records), np.int32, n)
        self.scripts = np.zeros((n, num_scripts), np.uint16)
        for i, r in enumerate(records):
            for sid, c in r.scripts:
                self.scripts[i, sid] = min(int(c), 65535)
        self._paths, self._p_off = self._pack([r.img for r in records])
        self._anns, self._a_off = self._pack([r.ann for r in records])

    @staticmethod
    def _pack(strings):
        enc = [x.encode('utf-8') for x in strings]
        off = np.zeros(len(enc) + 1, np.int64)
        off[1:] = np.cumsum([len(e) for e in enc]) if enc else 0
        return np.frombuffer(b''.join(enc), np.uint8), off

    def __len__(self):
        return len(self.src)

    def __getitem__(self, i):
        if isinstance(i, slice):
            return [self[j] for j in range(*i.indices(len(self)))]
        i = int(i)
        img = self._paths[self._p_off[i]:self._p_off[i + 1]].tobytes().decode('utf-8')
        ann = self._anns[self._a_off[i]:self._a_off[i + 1]].tobytes().decode('utf-8')
        nz = np.nonzero(self.scripts[i])[0]
        return ImageRecord(img, int(self.src[i]), int(self.w[i]), int(self.h[i]), ann,
                           tuple((int(k), int(self.scripts[i, k])) for k in nz))

    def __iter__(self):
        for i in range(len(self)):
            yield self[i]


class SourceIndex:
    """All training images of all sources: compact per-image records (annotation as one JSON string per image).
    `freeze()` moves them into FrozenRecords before DataLoader workers are forked."""

    def __init__(self, sources=None, records=None):
        self.sources = list(sources or [])
        self.records = list(records or [])

    def __len__(self):
        return len(self.records)

    def add(self, spec, records):
        sid = len(self.sources)
        self.sources.append(spec)
        self.records += [r._replace(src=sid) for r in records]

    def filter(self, keep):
        return SourceIndex(self.sources, [r for r, k in zip(self.records, keep) if k])

    def freeze(self, num_scripts):
        if not isinstance(self.records, FrozenRecords):
            self.records = FrozenRecords(self.records, num_scripts)
        return self

    def src_array(self):
        return self.records.src if isinstance(self.records, FrozenRecords) else \
            np.array([r.src for r in self.records], np.int32)

    def script_mass(self, num_scripts):
        if isinstance(self.records, FrozenRecords):
            m = self.records.scripts.astype(np.float32)
        else:
            m = np.zeros((len(self.records), num_scripts), dtype=np.float32)
            for i, r in enumerate(self.records):
                for sid, n in r.scripts:
                    m[i, sid] += n
        m[m.sum(1) == 0, 0] = 1.0                   # no legible text: neutral ('None' multiplier is fixed at 1)
        return m / m.sum(1, keepdims=True).clip(min=1e-6)

    def summary(self, cfg, mixture=None):
        by_src = defaultdict(lambda: [0, Counter()])
        for r in self.records:
            by_src[r.src][0] += 1
            for sid, n in r.scripts:
                by_src[r.src][1][sid] += n
        L = ['=' * 96, 'TRAINING SOURCES (merged)', '=' * 96,
             f"{'source':<16}{'group':<7}{'kind':<10}{'images':>8}{'exp.share':>10}  legible instances by script"]
        for sid, (n, sc) in sorted(by_src.items()):
            spec = self.sources[sid]
            share = f"{100 * mixture.get(sid, 0):.1f}%" if mixture else '-'
            top = ', '.join(f"{cfg.CANONICAL_SCRIPTS[k]}:{v}" for k, v in sc.most_common(5))
            L.append(f"{spec.get('name', '?'):<16}{spec.get('group', '?'):<7}{spec.get('kind', 'real'):<10}{n:>8}"
                     f"{share:>10}  {top}")
        L.append('=' * 96)
        print('\n'.join(L))
        try:
            with open(os.path.join(cfg.reports_dir, 'training_sources.txt'), 'w', encoding='utf-8') as f:
                f.write('\n'.join(L))
        except Exception:
            pass


def _spec_with_defaults(spec, cfg):
    base = spec.get('catalog') or spec.get('name', '')
    meta = PUBLIC_SOURCE_CATALOG.get(base, {})
    out = {k: meta.get(k) for k in ('format', 'group', 'script_hint', 'kind', 'complete', 'vertex_order')}
    out = {k: v for k, v in out.items() if v is not None}
    out.update({k: v for k, v in spec.items() if v is not None})
    out.setdefault('group', 'extra')
    out.setdefault('kind', 'real')
    out.setdefault('complete', True)
    out.setdefault('vertex_order', 'icdar')
    out.setdefault('weight', cfg.synthetic_weight if out['kind'] == 'synthetic' else 1.0)
    return out


def _tree_fingerprint(paths):
    """(file count, newest mtime, total label size) of the source's folders / files: a changed or completed
    extraction invalidates the cached index."""
    n, newest = 0, 0.0
    for p in paths:
        if not p:
            continue
        if os.path.isfile(p):
            st = os.stat(p)
            n, newest = n + st.st_size, max(newest, st.st_mtime)
            continue
        for dp, dn, fn in os.walk(p):
            n += len(fn)
            try:
                newest = max(newest, os.stat(dp).st_mtime)
            except OSError:
                pass
    return [n, round(newest, 1)]


def _spec_dirs(spec):
    """[(img_dirs, gt_dir)] of a per-image-annotated spec."""
    if spec.get('pairs_dirs'):
        return [(list(a), b) for a, b in spec['pairs_dirs']]
    img_dirs = spec.get('img_dirs') or [spec['img_dir']]
    return [(img_dirs, spec.get('gt_dir') or img_dirs[0])]


def build_source_records(spec, cfg):
    """Parses one source into ImageRecords (cached under cfg.cache_dir; the key includes a fingerprint of the files,
    so an updated / completed extraction is re-indexed; empty results are never cached)."""
    fmt = spec['format']
    digest_src = {k: spec.get(k) for k in ('name', 'format', 'img_dir', 'img_dirs', 'gt_dir', 'pairs_dirs',
                                           'label_file', 'script_hint', 'max_images')}
    if spec.get('items') is not None:
        digest_src['items'] = hashlib.sha1('\n'.join(f'{a}|{b}' for a, b in spec['items']).encode()).hexdigest()
    else:
        roots = [spec.get('label_file')] + [d for a, b in (_spec_dirs(spec) if fmt in PER_IMAGE_FORMATS else
                                                          [(spec.get('img_dirs') or [spec.get('img_dir')], None)])
                                            for d in list(a) + [b]]
        digest_src['fingerprint'] = _tree_fingerprint(sorted({r for r in roots if r}))
    key = hashlib.sha1((json.dumps(digest_src, sort_keys=True, default=str) + INDEX_VERSION).encode()).hexdigest()[:12]
    cache = os.path.join(cfg.cache_dir, f"index_{re.sub(r'[^A-Za-z0-9_]+', '_', spec.get('name', fmt))}_{key}.pkl")
    if os.path.exists(cache):
        try:
            with open(cache, 'rb') as f:
                return [ImageRecord(*t) for t in pickle.load(f)]
        except Exception:
            pass
    hint = spec.get('script_hint')
    tasks = []
    if fmt in PER_IMAGE_FORMATS:
        if spec.get('items') is not None:
            pairs = list(spec['items'])
        else:
            pairs, seen = [], set()
            for img_dirs, gt_dir in _spec_dirs(spec):
                for d in img_dirs:
                    for img, gt in _pair_images_with_gt(d, gt_dir, PER_IMAGE_FORMATS[fmt]):
                        if img not in seen:
                            seen.add(img)
                            pairs.append((img, gt))
        tasks = [(fmt, img, gt, hint, None) for img, gt in pairs]
    elif fmt in ('lsvt', 'art'):
        labels = _load_json_labels(spec['label_file'])
        stems = {}
        for d in (spec.get('img_dirs') or [spec['img_dir']]):
            for p in list_images_recursive(d):
                stems.setdefault(os.path.splitext(os.path.basename(p))[0], p)
        tasks = [(fmt, stems.get(k), None, hint, raw) for k, raw in labels.items() if k in stems]
    elif fmt == 'paddle':
        labels = _load_paddle_labels(spec['label_file'], spec.get('img_dir') or os.path.dirname(spec['label_file']))
        tasks = [(fmt, img, None, hint, raw) for img, raw in labels.items()]
    else:
        print(f"[sources] unknown format {fmt!r} for {spec.get('name')} - skipped")
        return []
    if spec.get('max_images') and len(tasks) > spec['max_images']:
        random.Random(0).shuffle(tasks)
        tasks = tasks[:spec['max_images']]
    res = _pool_map(_index_task, tasks, cfg.index_workers, f"index {spec.get('name', fmt)}")
    recs = []
    for r in res:
        if r is None:
            continue
        img, w, h, ann = r
        recs.append(ImageRecord(img, 0, w, h, ann, _script_counts(json.loads(ann), cfg.script2id)))
    if not recs:
        return recs
    try:
        with open(cache, 'wb') as f:                       # plain tuples: loadable from any module context
            pickle.dump([tuple(r) for r in recs], f, protocol=pickle.HIGHEST_PROTOCOL)
    except Exception as e:
        print(f"[sources] could not cache index ({e})")
    return recs


# ------------------------------------------------------------------ discovery (attached Kaggle datasets etc.)
def _sniff(path, n=4096):
    try:
        with open(path, 'rb') as f:
            return f.read(n).decode('utf-8-sig', 'ignore')
    except Exception:
        return ''


def _find_image_dir_near(dp, prefix, levels=2):
    """Directory holding images named `prefix*` in dp, its children, or the children of its ancestors."""
    seen = set()
    base = dp
    for _ in range(levels + 1):
        for cand in [base] + [os.path.join(base, d) for d in sorted(os.listdir(base)) if os.path.isdir(os.path.join(base, d))]:
            rc = os.path.realpath(cand)
            if rc in seen:
                continue
            seen.add(rc)
            try:
                if any(f.startswith(prefix) and f.endswith(IMG_EXTS) for f in os.listdir(cand)):
                    return cand
            except OSError:
                continue
        parent = os.path.dirname(base)
        if parent == base:
            break
        base = parent
    return None


_SPLIT_TOKENS = ('test', 'val', 'eval')


def _image_dirs_for_keys(dp, keys, prefix, name_hint=None, up=1, down=4, floor=None):
    """Image folders that really hold the annotated images: every folder within `up` levels above / `down` levels
    below the annotation folder whose `prefix*` image stems overlap the annotation keys. Test / validation folders
    are dropped when a training folder exists (RCTW / ArT test images share the train file names), a folder-name
    hint separates sets with identical naming (LSVT vs ArT 'gt_N'), and every folder with a substantial share of
    the keys is kept (LSVT is split over train_full_images_0 / _1; extraction may nest folders)."""
    keys = set(keys)
    if not keys:
        return []
    scope = dp
    floor_real = os.path.realpath(floor) if floor else None
    for _ in range(up):                            # never above the search root (other datasets live there)
        parent = os.path.dirname(scope)
        if parent == scope or (floor_real and not os.path.realpath(parent).startswith(floor_real + os.sep)):
            break
        scope = parent
    base_depth = scope.rstrip(os.sep).count(os.sep)
    cands = []
    for cur, dn, fn in os.walk(scope):
        if cur.rstrip(os.sep).count(os.sep) - base_depth >= down:
            dn[:] = []
        dn[:] = sorted(d for d in dn if not d.startswith('.'))
        stems = {os.path.splitext(f)[0] for f in fn if f.startswith(prefix) and f.endswith(IMG_EXTS)}
        hit = len(stems & keys)
        if hit:
            cands.append((hit, cur))
    if not cands:
        return []
    is_split = lambda c: any(t in os.path.relpath(c, scope).lower() for t in _SPLIT_TOKENS)
    if any(not is_split(c) for _, c in cands):
        cands = [(h, c) for h, c in cands if not is_split(c)]
    if name_hint and any(name_hint in os.path.basename(c).lower() for _, c in cands):
        cands = [(h, c) for h, c in cands if name_hint in os.path.basename(c).lower()]
    top = max(h for h, _ in cands)
    return sorted(c for h, c in cands if h >= 0.25 * top)


def _json_label_keys(path):
    """All image keys of an LSVT / ArT label file (regex over the whole file: the keys are ordered, so a sample
    from the head would only ever match the first image folder)."""
    try:
        with open(path, 'rb') as f:
            return set(m.decode() for m in re.findall(rb'"(gt_\d+)"\s*:', f.read()))
    except Exception:
        return set()


def _sibling_image_dirs(img_dir, prefix):
    """LSVT ships its images as train_full_images_0 / _1: collect sibling folders with the same name stem."""
    parent, base = os.path.dirname(img_dir), os.path.basename(img_dir)
    stem = base.rstrip('0123456789').rstrip('_-')
    out = [img_dir]
    if not stem:
        return out
    for d in sorted(os.listdir(parent)):
        p = os.path.join(parent, d)
        if p != img_dir and os.path.isdir(p) and d.startswith(stem):
            try:
                if any(f.startswith(prefix) and f.endswith(IMG_EXTS) for f in os.listdir(p)):
                    out.append(p)
            except OSError:
                continue
    return out


def _ancestor_with(dp, token, levels=4):
    cur = dp
    for _ in range(levels):
        if token.lower() in os.path.basename(cur).lower():
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return None


def discover_public_sources(roots, exclude=(), max_depth=7, verbose=True):
    """Finds the catalogued datasets by their file signatures (dataset slugs on Kaggle differ, signatures don't).
    Image folders are chosen by overlap with the annotation keys (see _image_dirs_for_keys); several folders of the
    same per-image-annotated set are merged into one spec (one source = one sampling weight)."""
    per_image = defaultdict(list)                  # name -> [(img_dirs, gt_dir)]
    single = {}                                    # (name, label_file) -> spec   (LSVT / ArT)
    excl = {os.path.realpath(e) for e in exclude if e}
    synth_lang = {'chinese': 'synthmlt_zh', 'japanese': 'synthmlt_ja', 'korean': 'synthmlt_ko'}
    fmt_of = {'rects': 'rects', 'rctw17': 'rctw', 'kaist': 'kaist', 'synthmlt_zh': 'mlt', 'synthmlt_ja': 'mlt',
              'synthmlt_ko': 'mlt'}

    def add_dirs(name, img_dirs, gt_dir):
        if img_dirs and all((tuple(img_dirs), gt_dir) != (tuple(a), b) for a, b in per_image[name]):
            per_image[name].append((list(img_dirs), gt_dir))

    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        rdepth = os.path.realpath(root).rstrip(os.sep).count(os.sep)
        for dp, dn, fn in os.walk(root):
            rdp = os.path.realpath(dp)
            if rdp in excl:
                dn[:] = []
                continue
            if rdp.count(os.sep) - rdepth >= max_depth:
                dn[:] = []
            dn[:] = sorted(d for d in dn if not d.startswith('.'))
            try:
                fs = set(fn)
                for jf in ('train_full_labels.json', 'train_labels.json'):
                    if jf in fs:
                        lf = os.path.join(dp, jf)
                        head = _sniff(lf, 1 << 16)
                        if '"points"' not in head or '"gt_' not in head:
                            continue
                        name = 'art' if '"language"' in head else 'lsvt'
                        img_dirs = _image_dirs_for_keys(dp, _json_label_keys(lf), 'gt_', floor=root,
                                                        name_hint='full' if name == 'lsvt' else 'train_images')
                        if img_dirs:
                            single[(name, lf)] = {'name': name, 'catalog': name, 'format': name, 'img_dir': img_dirs[0],
                                                  'img_dirs': img_dirs, 'label_file': lf}
                rects = [f for f in fn if f.startswith('train_ReCTS_') and f.endswith('.json')]
                if rects and os.path.basename(dp) != 'gt_unicode':
                    add_dirs('rects', _image_dirs_for_keys(dp, [f[:-5] for f in rects], 'train_ReCTS_', floor=root), dp)
                txts = sorted(f for f in fn if re.match(r'image_\d+\.txt$', f))
                if txts and re.match(r'^\s*[\d.\-]+(,[\d.\-]+){7},[01],', _sniff(os.path.join(dp, txts[0]), 512)):
                    add_dirs('rctw17', _image_dirs_for_keys(dp, [f[:-4] for f in txts], 'image_', floor=root), dp)
                xmls = [f for f in fn if f.lower().endswith('.xml')]
                if xmls and '<words' in _sniff(os.path.join(dp, xmls[0])):
                    kroot = _ancestor_with(dp, 'kaist') or dp
                    add_dirs('kaist', [kroot], kroot)
                    if kroot != dp:
                        dn[:] = []
                if 'synth' in rdp.lower():
                    gtx = [f for f in fn if f.endswith('.txt')][:20]
                    langs = Counter()
                    for f in gtx:
                        for line in _sniff(os.path.join(dp, f), 2048).splitlines()[:3]:
                            parts = line.split(',')
                            if len(parts) >= 10 and parts[8].strip().lower() in synth_lang:
                                langs[parts[8].strip().lower()] += 1
                    if langs:
                        lang = langs.most_common(1)[0][0]
                        gt_root = _ancestor_with(dp, lang) or dp
                        sib = gt_root[:-3] if gt_root.lower().endswith('_gt') else gt_root
                        add_dirs(synth_lang[lang], [sib if os.path.isdir(sib) else gt_root], gt_root)
                        if gt_root != dp:
                            dn[:] = []
            except Exception as e:
                if verbose:
                    print(f"[discover] skipped {dp}: {type(e).__name__}: {e}")
    specs = []
    for name, entries in per_image.items():
        specs.append({'name': name, 'catalog': name, 'format': fmt_of[name], 'img_dir': entries[0][0][0],
                      'pairs_dirs': entries})
    seen = Counter()
    for (name, lf), spec in single.items():
        seen[name] += 1
        if seen[name] > 1:                         # a second, different copy of the labels
            spec['name'] = f'{name}#{seen[name]}'
        specs.append(spec)
    if verbose:
        if specs:
            for s in specs:
                where = s.get('img_dirs') or [d for e in s.get('pairs_dirs', []) for d in e[0]]
                print(f"[discover] {s['name']:<12} images={where} labels={s.get('label_file') or [e[1] for e in s.get('pairs_dirs', [])]}")
        else:
            print("[discover] no public CJK scene-text set found under " + ', '.join(str(r) for r in roots) +
                  " - attach one (see PUBLIC_SOURCE_CATALOG) or keep auto_download_sources=True.")
    return specs


# ------------------------------------------------------------------ automatic acquisition from the original sources
class DownloadError(Exception):
    pass


def _url_candidates(url, allow_legacy_tls):
    """(url, verify_tls) attempts for one published URL: as published, the other scheme, and - only for
    LEGACY_TLS_HOSTS and only if allowed - HTTPS without certificate verification (integrity then rests on the
    size / MD5 / archive checks that follow every download)."""
    scheme, rest = url.split('://', 1)
    out = [(url, True), (('http://' if scheme == 'https' else 'https://') + rest, True)]
    if allow_legacy_tls and urllib.parse.urlsplit(url).hostname in LEGACY_TLS_HOSTS:
        out.append(('https://' + rest, False))
    return out


def _is_cert_error(e):
    r = getattr(e, 'reason', e)
    return isinstance(r, ssl.SSLError) or 'CERTIFICATE_VERIFY_FAILED' in str(e) or 'WRONG_VERSION_NUMBER' in str(e)


def _http_download(url, path, expected_size=None, verify=True, timeout=60, min_free_bytes=0):
    """Resumable download to `path` (partial data kept in path + '.part'; an interrupted transfer continues with an
    HTTP Range request). Refuses HTML answers (login walls / error pages) and incomplete files."""
    ctx = ssl.create_default_context()
    if not verify:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))
    part = path + '.part'
    have = os.path.getsize(part) if os.path.exists(part) else 0
    if expected_size and have > expected_size:
        os.remove(part)
        have = 0
    if expected_size and have == expected_size:
        os.replace(part, path)
        return
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (compatible; a3espotter-fetch/5)'})
    if have:
        req.add_header('Range', 'bytes=%d-' % have)
    try:
        r = opener.open(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        if e.code == 416 and have and (not expected_size or have == expected_size):
            os.replace(part, path)
            return
        raise
    with r:
        if 'text/html' in (r.headers.get('Content-Type') or '').lower():
            raise DownloadError(f'{url} answered with an HTML page (login wall or error page), not the file')
        if have and getattr(r, 'status', r.getcode()) != 206:
            have = 0                                    # the server ignored the Range header: start over
        length = r.headers.get('Content-Length')
        total = have + int(length) if length else expected_size
        if total and min_free_bytes:
            free = shutil.disk_usage(os.path.dirname(path) or '.').free
            if free < (total - have) + min_free_bytes:
                raise DownloadError(f'not enough disk space for {os.path.basename(path)}: '
                                    f'{(total - have) / 2 ** 30:.1f} GB needed + reserve, {free / 2 ** 30:.1f} GB free')
        bar = tqdm(total=total or None, initial=have, unit='B', unit_scale=True, desc=os.path.basename(path),
                   mininterval=5.0)
        with open(part, 'ab' if have else 'wb') as f:
            while True:
                chunk = r.read(1 << 22)
                if not chunk:
                    break
                f.write(chunk)
                bar.update(len(chunk))
        bar.close()
    got = os.path.getsize(part)
    want = expected_size or total
    if want and got != want:
        raise DownloadError(f'{url}: incomplete transfer ({got} of {want} bytes; will resume)')
    os.replace(part, path)


def _md5(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 24), b''):
            h.update(chunk)
    return h.hexdigest()


def fetch_file(spec, dest_dir, cfg, extra_urls=()):
    """Downloads one catalogued file (with fallbacks: other scheme, legacy-TLS hosts, extra URLs). Returns its path."""
    name = os.path.basename(urllib.parse.urlsplit(spec['url']).path)
    path = os.path.join(dest_dir, name)
    if os.path.exists(path) and (not spec.get('size') or os.path.getsize(path) == spec['size']):
        return path
    reserve = int(cfg.download_min_free_gb * 2 ** 30)
    if spec.get('size') and spec.get('extract'):
        reserve += spec['size']                         # room to extract next to the archive
    errors, warned = [], False
    for base in [spec['url']] + list(extra_urls):
        for url, verify in _url_candidates(base, cfg.download_allow_legacy_tls):
            if not verify and not warned:
                print(f"[download] {urllib.parse.urlsplit(url).hostname}: certificate chain does not verify; using "
                      f"unverified TLS for this academic host (download_allow_legacy_tls=True); integrity is checked "
                      f"by size / MD5 / archive tests.")
                warned = True
            for attempt in range(cfg.download_retries):
                try:
                    _http_download(url, path, spec.get('size'), verify, cfg.download_timeout, reserve)
                    if spec.get('md5') and _md5(path) != spec['md5']:
                        os.remove(path)
                        raise DownloadError(f'{url}: MD5 mismatch (corrupted or different file)')
                    return path
                except DownloadError as e:
                    errors.append(str(e))
                    if 'incomplete transfer' in str(e):
                        time.sleep(2 ** attempt)
                        continue
                    break
                except urllib.error.HTTPError as e:
                    errors.append(f'{url}: HTTP {e.code}')
                    if e.code in (429, 500, 502, 503, 504):
                        time.sleep(2 ** (attempt + 1))
                        continue
                    break
                except Exception as e:                  # URLError, timeouts, resets, IncompleteRead, TLS
                    errors.append(f'{url}: {type(e).__name__}: {getattr(e, "reason", e)}')
                    if _is_cert_error(e):
                        break
                    time.sleep(2 ** (attempt + 1))
    raise DownloadError('; '.join(errors[-3:]) or f'{name}: no URL worked')


def _safe_extract(archive, dest):
    """Extracts only regular files / directories that stay inside `dest` (no path traversal, links or devices);
    returns the extracted file paths."""
    dest_real = os.path.realpath(dest)
    out = []

    def inside(name):
        target = os.path.realpath(os.path.join(dest, name))
        return target == dest_real or target.startswith(dest_real + os.sep)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as zf:
            bad = zf.testzip()
            if bad is not None:
                raise DownloadError(f'{os.path.basename(archive)}: corrupted member {bad}')
            for m in zf.infolist():
                if inside(m.filename) and (m.external_attr >> 16) & 0o170000 != 0o120000:   # no symlinks
                    out.append(zf.extract(m, dest))
    elif tarfile.is_tarfile(archive):
        with tarfile.open(archive) as tf:
            safe = [m for m in tf.getmembers() if (m.isfile() or m.isdir()) and inside(m.name)]
            try:
                tf.extractall(dest, members=safe, filter='data')
            except TypeError:                           # Python without tarfile extraction filters
                tf.extractall(dest, members=safe)
            out += [os.path.join(dest, m.name) for m in safe if m.isfile()]
    else:
        raise DownloadError(f'{os.path.basename(archive)} is not a zip / tar archive')
    return out


def _archive_stem(path):
    b = os.path.basename(path)
    for ext in ('.tar.gz', '.tgz', '.tar', '.zip'):
        if b.endswith(ext):
            return b[:-len(ext)]
    return os.path.splitext(b)[0]


def _extract_archive(path, dest, mode):
    target = dest if mode == 'here' else os.path.join(dest, _archive_stem(path))
    os.makedirs(target, exist_ok=True)
    extracted = _safe_extract(path, target)
    # nested archives (KAIST ships one zip per folder): extract each next to itself (only files from this archive)
    for inner in sorted(p for p in extracted if p.lower().endswith('.zip')):
        try:
            _safe_extract(inner, os.path.splitext(inner)[0])
            os.remove(inner)
        except Exception as e:
            print(f"[download] nested archive {inner} skipped: {e}")
    return target


def _join_split_archives(dest):
    """name.zip.001 + name.zip.002 + ... -> name.zip (RCTW-17 style split archives)."""
    parts = defaultdict(list)
    for f in os.listdir(dest):
        m = None if f.startswith('.') else re.match(r'(.+\.(?:zip|tar|tar\.gz))\.(\d{3})$', f)
        if m:
            parts[m.group(1)].append((int(m.group(2)), f))
    for whole, ps in parts.items():
        out = os.path.join(dest, whole)
        with open(out, 'wb') as fo:
            for _, f in sorted(ps):
                with open(os.path.join(dest, f), 'rb') as fi:
                    shutil.copyfileobj(fi, fo, 1 << 24)
        _extract_archive(out, dest, 'here')
        for _, f in ps:
            os.remove(os.path.join(dest, f))
        os.remove(out)


def _acquire_file(spec, dest, cfg, extra_urls=()):
    name = os.path.basename(urllib.parse.urlsplit(spec['url']).path)
    marker = os.path.join(dest, '.done_' + name)
    if os.path.exists(marker):
        return
    path = fetch_file(spec, dest, cfg, extra_urls)
    try:
        if spec.get('extract'):
            _extract_archive(path, dest, spec['extract'])
        elif path.endswith('.json'):
            with open(path, encoding='utf-8-sig') as f:
                json.load(f)                                 # a truncated / HTML label file must not pass
    except Exception as e:
        os.remove(path)                                      # re-downloaded next time instead of trusted
        raise DownloadError(f'{name}: unusable after download ({type(e).__name__}: {e})')
    if spec.get('extract') and not cfg.download_keep_archives:
        os.remove(path)
    open(marker, 'w').close()


def _find_file(root, name):
    for dp, dn, fn in os.walk(root):
        dn.sort()
        if name in fn:
            return os.path.join(dp, name)
    return None


def _downloaded_spec(name, meta, dest):
    spec = {'name': name, 'catalog': name, 'format': meta['format'], 'img_dir': dest, 'img_dirs': [dest]}
    if meta['format'] in ('lsvt', 'art'):
        spec['label_file'] = _find_file(dest, meta['label_file'])
        if spec['label_file'] is None:
            return None
    else:
        spec['gt_dir'] = dest
    return spec


def acquire_public_sources(cfg, names=None):
    """Downloads (once; resumable; verified) and extracts every requested catalogued set from its original
    distribution point. Returns (specs of the sets that are ready, extra word-crop LMDB sources from the declared
    fallbacks of sets that could not be obtained)."""
    root = cfg.download_root
    os.makedirs(root, exist_ok=True)
    specs, crop_sources = [], []
    for name in names or cfg.download_names:
        meta = PUBLIC_SOURCE_CATALOG.get(name)
        if meta is None:
            print(f"[download] unknown source {name!r} - skipped")
            continue
        dest = os.path.join(root, name)
        os.makedirs(dest, exist_ok=True)
        extra = list((cfg.custom_download_urls or {}).get(name, []))
        files = list(meta['files']) + [_f(u) for u in extra if not any(u.endswith(os.path.basename(x['url'])) for x in meta['files'])]
        ok = os.path.exists(os.path.join(dest, '.complete'))
        if not ok and files:
            try:
                print(f"[download] {name}: {meta['note']}")
                for fs in files:
                    _acquire_file(fs, dest, cfg)
                _join_split_archives(dest)
                open(os.path.join(dest, '.complete'), 'w').close()
                ok = True
            except DownloadError as e:
                print(f"[download] {name}: not available ({e})")
        elif not files:
            print(f"[download] {name}: {meta['note']}")
        spec = _downloaded_spec(name, meta, dest) if ok else None
        if spec is not None:
            specs.append(spec)
            continue
        fb = meta.get('fallback')
        if fb and cfg.download_use_mirror_fallback and fb['kind'] == 'lmdb_crops':
            fdir = os.path.join(dest, 'fallback_lmdb')
            os.makedirs(fdir, exist_ok=True)
            try:
                for u in fb['urls']:
                    _acquire_file(_f(u, extract=None), fdir, cfg)
                print(f"[download] {name}: using the {fb['note']}")
                crop_sources.append({'type': 'lmdb', 'path': fdir, 'name': name + '_crops',
                                     'script_hint': meta.get('script_hint')})
            except DownloadError as e:
                print(f"[download] {name}: fallback not available either ({e})")
    return specs, crop_sources


def _discover_icdar_dirs(roots, gt_regex, img_prefix, need_script_column, max_depth=7):
    """[(img_dir, gt_dir)] for folders holding ICDAR-style GT files `gt_regex` with matching images nearby."""
    out = []
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        rdepth = os.path.realpath(root).rstrip(os.sep).count(os.sep)
        for dp, dn, fn in os.walk(root):
            if os.path.realpath(dp).count(os.sep) - rdepth >= max_depth:
                dn[:] = []
            dn[:] = sorted(d for d in dn if not d.startswith('.'))
            gts = sorted(f for f in fn if re.match(gt_regex, f))
            if len(gts) < 5:
                continue
            line = _sniff(os.path.join(dp, gts[0]), 1024).lstrip('﻿').split('\n')[0]
            parts = line.split(',')
            has_script = len(parts) >= 10 and parts[8].strip().lower() in _SCRIPT_NAMES_LOWER
            if has_script != need_script_column:
                continue
            img_dir = _find_image_dir_near(dp, img_prefix)
            if img_dir:
                out.append((img_dir, dp))
    return out


def _kaggle_mirror(slugs):
    """Downloads a Kaggle dataset with kagglehub (pre-installed and authenticated inside Kaggle notebooks)."""
    try:
        import kagglehub
    except Exception:
        return None
    for slug in slugs or []:
        try:
            p = kagglehub.dataset_download(slug)
            print(f"[base-data] fetched Kaggle copy {slug} -> {p}")
            return p
        except Exception as e:
            print(f"[base-data] kagglehub {slug}: {type(e).__name__}: {e}")
    return None


def ensure_base_datasets(cfg):
    """Makes sure MLT-19 (train) and IC15 (train + test) exist: configured paths -> discovery under
    source_search_roots -> automatic download. IC15 comes from the RRC itself (MD5-verified, the MMOCR dataset-zoo
    URLs); MLT-19 downloads need an RRC account, so the automatic fallback is a Kaggle copy (cfg.mlt_kaggle_mirrors)."""
    roots = [r for r in cfg.source_search_roots if r]
    have_mlt = bool(cfg.train_img_dir and os.path.isdir(cfg.train_img_dir) and cfg.train_gt_dir and os.path.isdir(cfg.train_gt_dir))
    if not have_mlt:
        found = _discover_icdar_dirs(roots, r'(gt_)?tr_img_\d+\.txt$', 'tr_img_', True)
        if not found and cfg.auto_download_sources:
            p = _kaggle_mirror(cfg.mlt_kaggle_mirrors)
            found = _discover_icdar_dirs([p], r'(gt_)?tr_img_\d+\.txt$', 'tr_img_', True) if p else []
        if found:
            cfg.train_img_dir, cfg.train_gt_dir = found[0]
            print(f"[base-data] MLT-19 train: images {cfg.train_img_dir} | GT {cfg.train_gt_dir}")
        else:
            print("[base-data] MLT-19 not found. Its official downloads (rrc.cvc.uab.es/?ch=15) need a free RRC account: "
                  "attach it or set Config.train_img_dir / train_gt_dir.")
    need_ic15 = not (cfg.ic15_train_img_dir and os.path.isdir(cfg.ic15_train_img_dir) and cfg.test_img_dir
                     and os.path.isdir(cfg.test_img_dir))
    if not need_ic15:
        return
    found = _discover_icdar_dirs(roots, r'gt_img_\d+\.txt$', 'img_', False)
    if not found and cfg.auto_download_sources:
        dest = os.path.join(cfg.download_root, 'ic15')
        os.makedirs(dest, exist_ok=True)
        try:
            for fs in IC15_RRC_FILES:
                _acquire_file(fs, dest, cfg)
            found = _discover_icdar_dirs([dest], r'gt_img_\d+\.txt$', 'img_', False)
        except DownloadError as e:
            print(f"[base-data] IC15 from the RRC failed ({e}); trying a Kaggle copy.")
            p = _kaggle_mirror(cfg.ic15_kaggle_mirrors)
            found = _discover_icdar_dirs([p], r'gt_img_\d+\.txt$', 'img_', False) if p else []
    train = [f for f in found if 'test' not in f[0].lower()]
    test = [f for f in found if 'test' in f[0].lower()]
    if train and not (cfg.ic15_train_img_dir and os.path.isdir(cfg.ic15_train_img_dir)):
        cfg.ic15_train_img_dir, cfg.ic15_train_gt_dir = train[0]
    if test and not (cfg.test_img_dir and os.path.isdir(cfg.test_img_dir)):
        cfg.test_img_dir, cfg.test_gt_dir = test[0]
    print(f"[base-data] IC15 train: {cfg.ic15_train_img_dir} | IC15 test: {cfg.test_img_dir} (GT {cfg.test_gt_dir})")


# ------------------------------------------------------------------ leakage guard (perceptual hash)
def dhash64(path):
    img = cv2.imread(path, cv2.IMREAD_REDUCED_GRAYSCALE_4 | cv2.IMREAD_IGNORE_ORIENTATION)
    if img is None or img.size == 0:
        return None
    s = cv2.resize(img, (9, 8), interpolation=cv2.INTER_AREA).astype(np.int16)
    bits = (s[:, 1:] > s[:, :-1]).reshape(-1)
    return int(np.packbits(bits).view('>u8')[0])


def _hash_many(paths, cfg, tag):
    key = hashlib.sha1('\n'.join(paths).encode()).hexdigest()[:12]
    cache = os.path.join(cfg.cache_dir, f'dhash_{tag}_{key}.npy')
    if os.path.exists(cache):
        return np.load(cache)
    hs = _pool_map(dhash64, list(paths), cfg.index_workers, f'dhash {tag}')
    arr = np.array([h if h is not None else 0 for h in hs], dtype=np.uint64)
    valid = np.array([h is not None for h in hs])
    arr[~valid] = np.uint64(0)
    np.save(cache, arr)
    return arr


def _popcount64(x):
    return np.unpackbits(x.view(np.uint8).reshape(*x.shape, 8), axis=-1).sum(-1)


def apply_leakage_guard(index, eval_paths, cfg):
    """Removes images of the newly merged REAL sources that are (near-)duplicates of any validation / test image
    (MLT-val, IC15-val, IC15-test). Official MLT / IC15 training splits are not checked against their own splits."""
    cand = [i for i, r in enumerate(index.records)
            if index.sources[r.src].get('kind') == 'real' and index.sources[r.src].get('group') not in ('mlt', 'ic15')]
    if not cand or not eval_paths:
        return index
    ev = _hash_many(sorted(set(eval_paths)), cfg, 'eval')
    ev = ev[ev != 0]
    tr = _hash_many([index.records[i].img for i in cand], cfg, 'train')
    keep = np.ones(len(index.records), dtype=bool)
    n_drop = 0
    for s in range(0, len(cand), 512):
        block = tr[s:s + 512]
        d = _popcount64(np.bitwise_xor(block[:, None], ev[None, :]))
        dup = (d <= cfg.dedup_hamming).any(1) & (block != 0)
        for j in np.nonzero(dup)[0]:
            keep[cand[s + j]] = False
            n_drop += 1
    print(f"[leakage-guard] {n_drop} merged images are near-duplicates of validation/test images -> removed.")
    return index.filter(keep)


# ------------------------------------------------------------------ the merged dataset
class MergedSceneTextDataset(ICDAR2019Dataset):
    """MLT-19 + IC15 + public CJK scene-text sets behind one Dataset. Every source is parsed once into a cached
    SourceIndex; items go through exactly the same augmentation / target construction as V4 (so detection,
    recognition, script and verification targets are uniform across sources), plus:
      * polygon sources (LSVT, ArT) keep their polygons for the masks; strongly curved ones skip CTC;
      * vertex order is repaired for sources whose quads do not start at the reading start ('auto' sources);
      * kanji-only lines of Japanese sources are labelled Japanese (dataset-level script hint);
      * incompletely annotated sources (KAIST) get no background RoIs / hard-negative mining;
      * large photos are decoded at 1/2, 1/4 or 1/8 resolution when the sampled scale allows it."""

    def __init__(self, index, config, is_train=True):
        super().__init__([], config, is_train)
        self.items = self.img_paths = None                # paths come from the frozen index (copy-on-write safe)
        self.index = index
        self.records = index.records
        self.sources = index.sources

    def __len__(self):
        return len(self.records)

    def _item_name(self, idx):
        return os.path.basename(self.records[idx].img)

    def raw_instances(self, idx):
        return [{'poly': np.asarray(p, dtype=np.float32).reshape(-1, 2), 'transcript': t, 'ignore': bool(ig),
                 'language': lang} for p, t, ig, lang in json.loads(self.records[idx].ann)]

    def source(self, idx):
        return self.sources[self.records[idx].src]

    def _is_complete(self, idx):
        return bool(self.source(idx).get('complete', True))

    def _load(self, idx, reduce=1):
        rec = self.records[idx]
        image = load_image_rgb(rec.img, reduce)
        if image is None:
            return np.zeros((self.config.img_size, self.config.img_size, 3), dtype=np.uint8), []
        h, w = image.shape[:2]
        W0, H0 = (rec.w or w * reduce), (rec.h or h * reduce)
        raw = self.raw_instances(idx)
        for r in raw:
            r['poly'] = r['poly'] * np.array([w / float(W0), h / float(H0)], dtype=np.float32)
        return image, prepare_instances(raw, w, h, self.config, self.source(idx).get('vertex_order', 'icdar'))

    def _augmented(self, idx):
        if not self.is_train:
            return super()._augmented(idx)
        rec = self.records[idx]
        if rec.w and rec.h:
            insts = prepare_instances(self.raw_instances(idx), rec.w, rec.h, self.config,
                                      self.source(idx).get('vertex_order', 'icdar'))
            s = self._sample_scale(rec.h, rec.w, insts)
            r = next((c for c in (8, 4, 2) if c * s <= 0.8), 1)
            image = load_image_rgb(rec.img, r)
            if image is None:
                return np.zeros((self.config.img_size, self.config.img_size, 3), dtype=np.uint8), []
            h, w = image.shape[:2]
            fx, fy = w / float(rec.w), h / float(rec.h)
            insts = self._apply_affine(insts, np.array([[fx, 0], [0, fy]], dtype=np.float32), np.zeros(2, np.float32))
            image, insts = self._geometric_augment(image, insts, s=s / (0.5 * (fx + fy)))
        else:
            image, insts = self._load(idx)
            image, insts = self._geometric_augment(image, insts)
        return self._photometric(image), insts


def compute_mixture_weights(index, cfg):
    """Per-record base sampling weight: group budget x temperature-sampled source share inside the group / size."""
    src_arr = index.src_array()
    src_count = Counter(src_arr.tolist())
    groups = defaultdict(list)
    for sid in src_count:
        groups[index.sources[sid].get('group', 'extra')].append(sid)
    budget = {g: float(cfg.mixture_budget.get(g, 0.05)) for g in groups}
    tot = sum(budget.values()) or 1.0
    T = max(float(cfg.mixture_temperature), 1e-3)
    share = {}
    for g, sids in groups.items():
        z = {s: (max(float(index.sources[s].get('weight', 1.0)), 1e-6) * src_count[s]) ** (1.0 / T) for s in sids}
        zs = sum(z.values())
        for s in sids:
            share[s] = budget[g] / tot * z[s] / zs
    per_src = np.zeros(max(src_count) + 1 if src_count else 1, dtype=np.float64)
    for sid, c in src_count.items():
        per_src[sid] = share[sid] / c
    base = per_src[src_arr]
    return base, share


class ScriptAdaptiveMixtureSampler(Sampler):
    """Samples `num_samples` records per epoch with replacement, p_i ~ base_i * (m_i . beta), where m_i is the
    image's legible-script mass and beta the per-script multipliers set by the trainer from held-out error
    (error-feedback mixing). The sampler runs in the main process, so updates apply from the next epoch even
    with persistent DataLoader workers."""

    def __init__(self, base_weights, script_mass, num_samples, seed=0):
        self.base = np.asarray(base_weights, dtype=np.float64)
        self.mass = np.asarray(script_mass, dtype=np.float32)
        self.beta = np.ones(self.mass.shape[1], dtype=np.float64)
        self.num_samples = int(num_samples)
        self.seed = int(seed)
        self.epoch = 0

    def set_script_multipliers(self, beta):
        b = np.asarray(beta, dtype=np.float64).copy()
        b[0] = 1.0
        self.beta = b

    def probabilities(self):
        p = self.base * (self.mass.astype(np.float64) @ self.beta)
        p = np.clip(p, 0, None)
        return p / max(p.sum(), 1e-12)

    def __iter__(self):
        rng = np.random.default_rng(self.seed + 7919 * self.epoch)
        self.epoch += 1
        return iter(rng.choice(len(self.base), size=self.num_samples, replace=True, p=self.probabilities()).tolist())

    def __len__(self):
        return self.num_samples


class SceneWordStripDataset(Dataset):
    """Rectified word strips cut from the merged training images (no extra data needed): for one image, up to
    `strips_per_image` legible, fully annotated, in-vocabulary, not-curved words are warped along their reading
    direction into (roi_h*stride) x (<= roi_w_long*stride) strips with box jitter + photometric noise. They
    exercise exactly the path used for strip re-reading at inference."""

    def __init__(self, merged, config, strips_per_image=8):
        self.m = merged
        self.cfg = config
        self.k = strips_per_image
        self.H = config.roi_h * config.feature_stride
        self.W = config.roi_w_long * config.feature_stride

    def __len__(self):
        return len(self.m)

    def __getitem__(self, idx):
        cfg = self.cfg
        rec = self.m.records[idx]
        W0, H0 = rec.w or 100000, rec.h or 100000
        insts = prepare_instances(self.m.raw_instances(idx), W0, H0, cfg, self.m.source(idx).get('vertex_order', 'icdar'))
        elig = []
        for inst in insts:
            if inst['ignore'] or inst['curved'] or not cfg.text_fits(inst['transcript']):
                continue
            if cfg.encode_text(inst['transcript'])[2] > 0:
                continue
            rb = rbox_from_points(inst['poly'], inst['u'])
            if min(rb[2], rb[3]) >= 6:
                elig.append((inst, float(rb[3])))
        if not elig:
            return []
        random.shuffle(elig)
        elig = elig[:self.k]
        med_h = float(np.median([h for _, h in elig]))
        r = next((c for c in (8, 4, 2) if med_h / c >= 1.5 * self.H), 1) if rec.w else 1
        image = load_image_rgb(rec.img, r)
        if image is None:
            return []
        h, w = image.shape[:2]
        f = np.array([[w / float(rec.w or w), 0], [0, h / float(rec.h or h)]], dtype=np.float32)
        out = []
        for inst, _ in elig:
            poly = (inst['poly'] @ f.T).astype(np.float32)
            rb = rbox_from_points(poly, _unit(f @ inst['u']))
            if random.random() < cfg.box_jitter_prob:
                rb = self.m._jitter_rbox(rb)
            rbp = pad_rbox(rb, cfg.roi_pad_h, cfg.roi_pad_w)
            canvas, nw, A = rectify_strip(image, rbp, self.H, self.W)
            canvas[:, :nw] = ICDAR2019Dataset._photometric(np.ascontiguousarray(canvas[:, :nw]))
            poly_s = poly @ A[:, :2].T.astype(np.float32) + A[:, 2].astype(np.float32)
            out.append(_strip_item(cfg, canvas, nw, poly_s, inst['transcript'], inst['language']))
        return out


def resolve_cjk_specs(cfg, exclude_dirs=()):
    """Public CJK sources: downloaded from their original hosts (auto_download_sources), then attached copies found by
    signature (cjk_sources='auto') or explicit specs. One spec per catalogued name (downloaded copy first).
    Returns (specs, extra word-crop sources from declared fallbacks)."""
    specs, crop_sources = [], []
    if cfg.auto_download_sources:
        specs, crop_sources = acquire_public_sources(cfg)
    if cfg.cjk_sources == 'auto':
        roots = list(cfg.source_search_roots)
        if not cfg.auto_download_sources:
            roots.append(cfg.download_root)
        have = {s['name'] for s in specs}
        specs += [s for s in discover_public_sources(roots, exclude=exclude_dirs) if s['name'] not in have]
    else:
        specs += list(cfg.cjk_sources or [])
    out = []
    for s in specs:
        s = _spec_with_defaults(s, cfg)
        if cfg.max_images_per_source and not s.get('max_images'):
            s['max_images'] = cfg.max_images_per_source
        if s.get('format') not in PER_IMAGE_FORMATS and s.get('format') not in ('lsvt', 'art', 'paddle'):
            print(f"[sources] {s.get('name')}: unsupported format {s.get('format')!r} - skipped")
            continue
        out.append(s)
    return out, crop_sources


def build_training_index(cfg, mlt_items, ic15_items, eval_image_paths):
    """MLT-19 train + IC15 train + extra_train_sets + public CJK sources -> one SourceIndex (+ leakage guard)."""
    index = SourceIndex()
    base_specs = [{'name': 'mlt19', 'format': 'mlt', 'group': 'mlt', 'kind': 'real', 'items': mlt_items}]
    if ic15_items:
        base_specs.append({'name': 'ic15', 'format': 'icdar', 'group': 'ic15', 'kind': 'real',
                           'weight': float(cfg.ic15_repeat), 'items': ic15_items})
    for i, es in enumerate(cfg.extra_train_sets):
        base_specs.append({'name': es.get('name', f'extra{i}'), 'format': es.get('format', 'mlt'),
                           'group': es.get('group', 'extra'), 'img_dir': es.get('img_dir'),
                           'gt_dir': es.get('gt_dir'), 'label_file': es.get('label_file'),
                           'weight': float(es.get('repeat', es.get('weight', 1)))})
    exclude = [cfg.train_img_dir, cfg.train_gt_dir, cfg.test_img_dir, cfg.test_gt_dir,
               cfg.ic15_train_img_dir, cfg.ic15_train_gt_dir]
    cjk_specs, crop_sources = resolve_cjk_specs(cfg, exclude)
    known = {c.get('path') for c in cfg.crop_rec_sources}
    cfg.crop_rec_sources = list(cfg.crop_rec_sources) + [c for c in crop_sources if c['path'] not in known]
    specs = [_spec_with_defaults(s, cfg) for s in base_specs] + cjk_specs
    for spec in specs:
        dirs = [spec.get('img_dir')] + list(spec.get('img_dirs') or []) + \
            [d for e in spec.get('pairs_dirs') or [] for d in e[0]]
        if spec.get('items') is None and not any(d and os.path.isdir(d) for d in dirs) and \
                not (spec.get('label_file') and os.path.isfile(spec['label_file'])):
            print(f"[sources] {spec.get('name')}: no image folder / label file found - skipped")
            continue
        try:
            recs = build_source_records(spec, cfg)
        except Exception as e:                             # one broken source must not stop the run
            print(f"[sources] {spec.get('name')}: could not be indexed ({type(e).__name__}: {e}) - skipped")
            continue
        if recs:
            index.add({k: v for k, v in spec.items() if k != 'items'}, recs)
            print(f"[sources] {spec.get('name')}: {len(recs)} images")
    if cfg.dedup_against_eval:
        index = apply_leakage_guard(index, eval_image_paths, cfg)
    return index.freeze(cfg.num_scripts)


# =====================================================================
# 3. Dedicated Modules
# =====================================================================
class GatedInjectedFeatures(nn.Module):
    """GIF: a gate computed from a 2-D context map modulates a token/feature sequence
    (scale * gate + bias)."""

    def __init__(self, in_channels: int, feat_dim: int, out_dim: int, pool_size=(4, 4), num_groups=8):
        super().__init__()
        self.conv1x1 = nn.Conv2d(in_channels, in_channels, kernel_size=1, bias=False)
        ng = min(num_groups, in_channels)
        while in_channels % ng != 0:
            ng -= 1
        self.gn = nn.GroupNorm(num_groups=ng, num_channels=in_channels)
        self.swish = nn.SiLU()
        self.pool = nn.AdaptiveAvgPool2d(pool_size)
        self.linear_gate = nn.Linear(in_channels * pool_size[0] * pool_size[1], out_dim)
        self.linear_feat_scale = nn.Linear(feat_dim, out_dim)
        self.linear_feat_bias = nn.Linear(feat_dim, out_dim)

    def forward(self, x: torch.Tensor, feats: torch.Tensor) -> torch.Tensor:
        g = self.pool(self.swish(self.gn(self.conv1x1(x))))
        gate = torch.sigmoid(self.linear_gate(torch.flatten(g, start_dim=1)))
        if feats.dim() == 3:
            gate = gate.unsqueeze(1)
            scaled, biased = self.linear_feat_scale(feats), self.linear_feat_bias(feats)
        elif feats.dim() == 4:
            gate = gate.view(feats.size(0), -1, 1, 1)
            fp = feats.permute(0, 2, 3, 1)
            scaled = self.linear_feat_scale(fp).permute(0, 3, 1, 2)
            biased = self.linear_feat_bias(fp).permute(0, 3, 1, 2)
        else:
            scaled, biased = self.linear_feat_scale(feats), self.linear_feat_bias(feats)
        return (scaled * gate) + biased


class ContentScorer(nn.Module):
    def __init__(self, in_channels: int, out_dim: int = None, as_vector: bool = False):
        super().__init__()
        out_dim = in_channels if out_dim is None else out_dim
        self.as_vector = as_vector
        self.stem = nn.Sequential(nn.Conv2d(in_channels, in_channels, 1, bias=False),
                                  nn.BatchNorm2d(in_channels), nn.GELU())
        self.dw_local = nn.Conv2d(in_channels, in_channels, 3, padding=1, groups=in_channels, bias=False)
        self.dw_context = nn.Conv2d(in_channels, in_channels, 3, padding=2, dilation=2, groups=in_channels, bias=False)
        se_mid = min(in_channels, max(in_channels // 4, 8))
        self.se = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Conv2d(in_channels, se_mid, 1), nn.GELU(),
                                nn.Conv2d(se_mid, in_channels, 1), nn.Sigmoid())
        if as_vector:
            self.head = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Flatten(), nn.Linear(in_channels, out_dim))
        else:
            self.head = nn.Sequential(nn.Conv2d(in_channels, out_dim, 1), nn.BatchNorm2d(out_dim))

    def forward(self, x):
        res = self.stem(x)
        spatial = self.dw_local(res) + self.dw_context(res)
        return self.head(res + spatial * self.se(spatial))


class FrequencyScorer(nn.Module):
    """Global spectral filter (complex, identity-initialised, resolution-adaptive by interpolation)
    whose output channels are gated by three statistics of each channel's power spectrum:
      * spectral flatness  (broad-band strokes -> high, a single periodic pattern -> low)
      * normalised peak ratio (dominant single frequency, e.g. stripes / fences / tiles)
      * orientation anisotropy (horizontal vs vertical frequency energy)"""

    def __init__(self, in_channels: int, out_dim: int = None, spatial_size: tuple = (64, 64), as_vector: bool = False):
        super().__init__()
        out_dim = in_channels if out_dim is None else out_dim
        H, W = spatial_size
        self.as_vector = as_vector
        self.h, self.w_freq = H, W // 2 + 1
        self.filter_real = nn.Parameter(torch.ones(in_channels, self.h, self.w_freq)
                                        + 0.02 * torch.randn(in_channels, self.h, self.w_freq))
        self.filter_imag = nn.Parameter(0.02 * torch.randn(in_channels, self.h, self.w_freq))
        self.stat_mlp = nn.Sequential(nn.Linear(3, 16), nn.GELU(), nn.Linear(16, 1))
        nn.init.zeros_(self.stat_mlp[2].weight)
        nn.init.constant_(self.stat_mlp[2].bias, 2.0)
        self.channel_bias = nn.Parameter(torch.zeros(in_channels))
        self.edge_filter = nn.Conv2d(in_channels, in_channels, 3, padding=1, groups=in_channels, bias=False)
        self.edge_gate = nn.Sequential(nn.Conv2d(in_channels, in_channels, 1), nn.Sigmoid())
        if as_vector:
            self.head = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Flatten(), nn.Linear(in_channels, out_dim))
        else:
            self.head = nn.Sequential(nn.Conv2d(in_channels, out_dim, 1), nn.BatchNorm2d(out_dim))
        self.last_stats = None

    @staticmethod
    def spectral_statistics(P, H, W, eps=1e-8):
        B, C, Hf, Wf = P.shape
        fy = torch.fft.fftfreq(H, device=P.device).abs().view(Hf, 1)
        fx = torch.fft.rfftfreq(W, device=P.device).view(1, Wf)
        dc = torch.ones(Hf, Wf, device=P.device)
        dc[0, 0] = 0.0
        P = P * dc
        flat = P.reshape(B, C, -1)
        n = flat.shape[-1] - 1
        mean = flat.sum(-1) / max(n, 1) + eps
        gmean = torch.exp((torch.log(flat + eps) * dc.view(1, 1, -1)).sum(-1) / max(n, 1))
        sf = (gmean / mean).clamp(0, 1)
        peak = flat.max(-1).values / (flat.sum(-1) + eps)
        peak_n = torch.log1p(peak * n) / math.log(n + 1.0)
        horiz = (fx > fy).float()
        e_h = (P * horiz).reshape(B, C, -1).sum(-1)
        e_v = (P * (1 - horiz)).reshape(B, C, -1).sum(-1)
        aniso = (e_h - e_v) / (e_h + e_v + eps)
        return torch.stack([sf, peak_n, aniso], dim=-1)

    def forward(self, x):
        B, C, H, W = x.shape
        with torch.autocast(device_type=x.device.type, enabled=False):
            xf = x.float()
            X = torch.fft.rfft2(xf, norm='ortho')
            fr, fi = self.filter_real, self.filter_imag
            if X.shape[-2:] != fr.shape[-2:]:
                fr = F.interpolate(fr.unsqueeze(0), size=X.shape[-2:], mode='bilinear', align_corners=True).squeeze(0)
                fi = F.interpolate(fi.unsqueeze(0), size=X.shape[-2:], mode='bilinear', align_corners=True).squeeze(0)
            Xm = X * torch.complex(fr, fi).unsqueeze(0)
            P = X.real ** 2 + X.imag ** 2
            stats = self.spectral_statistics(P, H, W)
            g = torch.sigmoid(self.stat_mlp(stats).squeeze(-1) + self.channel_bias)
            x_spec = torch.fft.irfft2(Xm, s=(H, W), norm='ortho') * g[:, :, None, None]
        self.last_stats = stats.detach()
        x_spec = x_spec.to(x.dtype)
        x_edge = self.edge_filter(x)
        return self.head(x_spec + x_edge * self.edge_gate(x_spec))


class BlendedScorer(nn.Module):
    def __init__(self, channels: int, out_dim: int = None, spatial_size: tuple = (64, 64), as_vector: bool = False):
        super().__init__()
        out_dim = channels if out_dim is None else out_dim
        self.content_scorer = ContentScorer(channels, out_dim=out_dim, as_vector=as_vector)
        self.frequency_scorer = FrequencyScorer(channels, out_dim=out_dim, spatial_size=spatial_size, as_vector=as_vector)
        self.gate_blend = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Conv2d(channels, 1, 1), nn.Sigmoid())

    def forward(self, x, blend=None):
        c_feat = self.content_scorer(x)
        f_feat = self.frequency_scorer(x)
        alpha = torch.sigmoid(blend) if blend is not None else self.gate_blend(x)
        if alpha.dim() > 1:
            alpha = alpha.view(c_feat.size(0), *([1] * (c_feat.dim() - 1)))
        return alpha * c_feat + (1.0 - alpha) * f_feat


class SpectralGatedDyadicLinearAttention(nn.Module):
    """SGDLA: focused linear attention over a *dyadic* key/value set (full-resolution tokens plus
    2x-average-pooled tokens), depth-wise rank restoration on V, and a spectral gate (BlendedScorer ->
    GIF) that modulates the attention output. O(N) in the number of tokens."""

    def __init__(self, dim: int, num_heads: int = 8, focusing_factor: int = 3, spatial_size=(32, 32), kernel_size=5):
        super().__init__()
        assert dim % num_heads == 0
        self.dim, self.num_heads, self.head_dim = dim, num_heads, dim // num_heads
        self.focusing_factor = focusing_factor
        self.qkv = nn.Linear(dim, dim * 3)
        self.scale = nn.Parameter(torch.zeros(1, 1, dim))
        self.dwc = nn.Conv2d(self.head_dim, self.head_dim, kernel_size, padding=kernel_size // 2, groups=self.head_dim)
        self.scorer = BlendedScorer(dim, out_dim=dim, spatial_size=spatial_size, as_vector=False)
        self.gif = GatedInjectedFeatures(in_channels=dim, feat_dim=dim, out_dim=dim, pool_size=(4, 4))
        self.proj = nn.Linear(dim, dim)
        self.attention_map = None

    def _phi(self, t, scale):
        t = F.relu(t) + 1e-6
        t = t / scale
        n = t.norm(dim=-1, keepdim=True)
        t = t ** self.focusing_factor
        return t / (t.norm(dim=-1, keepdim=True) + 1e-6) * n

    def forward(self, x, spatial_shape):
        B, N, C = x.shape
        gh, gw = spatial_shape
        h, d = self.num_heads, self.head_dim
        with torch.autocast(device_type=x.device.type, enabled=False):
            xf = x.float()
            q, k, v = self.qkv(xf).chunk(3, dim=-1)
            if gh >= 2 and gw >= 2:
                def _pool(t):
                    t2 = t.transpose(1, 2).reshape(B, C, gh, gw)
                    return F.avg_pool2d(t2, 2, ceil_mode=True).flatten(2).transpose(1, 2)
                k_all, v_all = torch.cat([k, _pool(k)], 1), torch.cat([v, _pool(v)], 1)
            else:
                k_all, v_all = k, v
            scale = F.softplus(self.scale) + 1e-4
            qp, kp = self._phi(q, scale), self._phi(k_all, scale)
            M = kp.shape[1]
            qh = qp.reshape(B, N, h, d).transpose(1, 2)
            kh = kp.reshape(B, M, h, d).transpose(1, 2)
            vh = v_all.reshape(B, M, h, d).transpose(1, 2)
            kv = (kh.transpose(-2, -1) * (M ** -0.5)) @ (vh * (M ** -0.5))
            denom = qh @ kh.mean(dim=-2, keepdim=True).transpose(-2, -1) + 1e-6
            out = (qh @ kv) / denom
            v_img = v.reshape(B, gh, gw, h, d).permute(0, 3, 4, 1, 2).reshape(B * h, d, gh, gw)
            out = out + self.dwc(v_img).reshape(B, h, d, N).transpose(-2, -1)
            out = out.transpose(1, 2).reshape(B, N, C)
        with torch.no_grad():
            self.attention_map = denom.mean(1).reshape(B, gh, gw).detach()
        x2d = x.transpose(1, 2).reshape(B, C, gh, gw)
        blended = self.scorer(x2d)
        modulated = self.gif(blended, out.to(x.dtype))
        return self.proj(modulated)


class SGDLABlock(nn.Module):
    def __init__(self, dim, num_heads, spatial_size, mlp_ratio=2.0, drop=0.0):
        super().__init__()
        self.cpe = nn.Conv2d(dim, dim, 3, padding=1, groups=dim)          # conditional positional encoding
        self.norm1 = nn.LayerNorm(dim)
        self.attn = SpectralGatedDyadicLinearAttention(dim, num_heads=num_heads, spatial_size=spatial_size)
        self.norm2 = nn.LayerNorm(dim)
        hid = int(dim * mlp_ratio)
        self.mlp = nn.Sequential(nn.Linear(dim, hid), nn.GELU(), nn.Dropout(drop), nn.Linear(hid, dim))
        self.gamma1 = nn.Parameter(1e-2 * torch.ones(dim))                # LayerScale
        self.gamma2 = nn.Parameter(1e-2 * torch.ones(dim))

    def forward(self, x, hw):
        B, N, C = x.shape
        x = x + self.cpe(x.transpose(1, 2).reshape(B, C, *hw)).flatten(2).transpose(1, 2)
        x = x + self.gamma1 * self.attn(self.norm1(x), hw)
        x = x + self.gamma2 * self.mlp(self.norm2(x))
        return x


def oriented_roi_crop(features, batch_idx, rboxes, out_h, out_w, spatial_scale):
    """Samples an (out_h, out_w) patch per oriented box.
    rboxes: (K, 6) = (cx, cy, w, h, ux, uy) in image pixels; u = reading direction, the RoI x-axis."""
    K = rboxes.shape[0]
    B, C, H, W = features.shape
    if K == 0:
        return features.new_zeros((0, C, out_h, out_w))
    rb = rboxes.float()
    cx, cy, w, h, ux, uy = rb.unbind(1)
    vx, vy = -uy, ux
    s = float(spatial_scale)
    theta = rb.new_zeros((K, 2, 3))
    theta[:, 0, 0] = s * w * ux / W
    theta[:, 0, 1] = s * h * vx / W
    theta[:, 0, 2] = 2.0 * s * cx / W - 1.0
    theta[:, 1, 0] = s * w * uy / H
    theta[:, 1, 1] = s * h * vy / H
    theta[:, 1, 2] = 2.0 * s * cy / H - 1.0
    grid = F.affine_grid(theta, (K, C, out_h, out_w), align_corners=False)
    out = features.new_zeros((K, C, out_h, out_w))
    bidx = batch_idx.clamp(0, B - 1)
    for b in torch.unique(bidx).tolist():
        sel = (bidx == b).nonzero(as_tuple=True)[0]
        g = grid[sel].reshape(1, -1, out_w, 2).to(features.dtype)
        samp = F.grid_sample(features[b:b + 1], g, mode='bilinear', padding_mode='zeros', align_corners=False)
        out[sel] = samp.reshape(C, sel.numel(), out_h, out_w).permute(1, 0, 2, 3).to(out.dtype)
    return out


def stn_roi_crop(features, batch_idx, boxes_feat_px, out_h, out_w):
    """Legacy axis-aligned API (boxes in feature pixels) -> oriented crop with u = (1, 0)."""
    x1, y1, x2, y2 = boxes_feat_px.float().unbind(1)
    rb = torch.stack([(x1 + x2) / 2, (y1 + y2) / 2, (x2 - x1).clamp(min=1), (y2 - y1).clamp(min=1),
                      torch.ones_like(x1), torch.zeros_like(x1)], 1)
    return oriented_roi_crop(features, batch_idx, rb, out_h, out_w, 1.0)


def _conv_bn_relu(cin, cout, k=3):
    return nn.Sequential(nn.Conv2d(cin, cout, k, padding=k // 2, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True))


class CompositionalCharClassifier(nn.Module):
    """Unicode-compositional CTC output layer:  logit_c(h) = h . (W_c + sum_{p in comp(c)} E_p) + b_c.
    comp(c) = Hangul jamo (L/V/T) of a syllable, or the NFD base letter + combining marks (e/é/è, か/が, は/ば/ぱ);
    only components shared by >= 2 vocabulary characters exist. E starts at zero, so a checkpoint trained with
    a plain nn.Linear is reproduced exactly (same parameter names 'weight' / 'bias'). The component incidence is
    a non-persistent buffer rebuilt from the vocabulary, so it never conflicts with checkpoint shapes."""

    def __init__(self, in_features, vocab_size, chars=None, enabled=True):
        super().__init__()
        self.in_features, self.out_features = in_features, vocab_size
        self.weight = nn.Parameter(torch.empty(vocab_size, in_features))
        self.bias = nn.Parameter(torch.empty(vocab_size))
        nn.init.kaiming_uniform_(self.weight, a=math.sqrt(5))
        bound = 1.0 / math.sqrt(in_features)
        nn.init.uniform_(self.bias, -bound, bound)
        names, rows = ([], [])
        if enabled and chars is not None and len(chars) + 2 == vocab_size:
            names, rows = build_component_table(chars)
        self.component_names = list(names)
        P = max(len(names), 1)
        self.comp_embed = nn.Parameter(torch.zeros(P, in_features))
        A = torch.zeros(vocab_size, P)
        for i, r in enumerate(rows):
            for p in r:
                A[i + 2, p] = 1.0
        self.register_buffer('incidence', A, persistent=False)
        self.enabled = len(names) > 0

    def effective_weight(self):
        if not self.enabled:
            return self.weight
        return self.weight + self.incidence.to(self.comp_embed.dtype) @ self.comp_embed

    def forward(self, x):
        return F.linear(x, self.effective_weight(), self.bias)


class ScriptAwareInstanceRecognizer(nn.Module):
    """Oriented masked RoI -> conv tower -> (script head, legibility/verification head)
    -> GIF image-context injection -> BiLSTM -> script-aware mixture of conv experts -> CTC.

    V5 additions:
      * two time-axis lengths: RoIs with padded aspect > `long_aspect` are sampled with `roi_w_long` columns (CJK
        lines), the rest with `roi_w`; text logits are returned padded to the longest length with blank-only
        frames (equivalent to extra blank frames for CTC / greedy decoding) plus the true `time_lengths`;
      * `rec_mask`: tower+heads run for every RoI, the sequence model + classifier only for the masked RoIs
        (training: RoIs with a CTC target). Rows of `text_logits` / `time_lengths` are grouped by time-length
        bucket; `rec_index[j]` is the RoI of row j (script / verify / embed outputs stay in RoI order);
      * compositional classifier (see CompositionalCharClassifier).

    Expert routing (`moe_routing`):
      * 'decoupled' (default): a dedicated router on the pooled RoI features picks the top-k of
        `num_experts` family-aligned experts per instance (multiplicative router jitter in training). A
        light auxiliary family head shares the router INPUT but not its weights.
      * 'script_driven': V4's original dense mixture weighted by the 11-way script head (kept for ablation).
    A shared expert is always active and is balanced against the routed mixture by a learnable per-step
    gate a_t = sigmoid(w . h_t)."""

    PAD_LOGIT = -30.0

    def __init__(self, in_channels=128, roi_h=8, roi_w=64, hidden=256, vocab_size=100, num_scripts=11,
                 num_experts=4, dropout=0.15, num_verify=3, feature_stride=4, moe_routing='decoupled',
                 top_k=2, router_jitter=0.05, use_shared_gate=True, num_families=4, roi_w_long=None,
                 long_aspect=12.0, chars=None, compositional=True):
        super().__init__()
        self.roi_h, self.roi_w, self.feature_stride = roi_h, roi_w, feature_stride
        self.roi_w_long = max(int(roi_w_long or roi_w), roi_w)
        self.long_aspect = float(long_aspect)
        self.num_experts, self.num_scripts, self.num_families = num_experts, num_scripts, num_families
        self.moe_routing = moe_routing
        self.top_k = max(1, min(int(top_k), num_experts))
        self.router_jitter = router_jitter
        self.use_shared_gate = use_shared_gate
        self.mask_gate_bias = nn.Parameter(torch.tensor(0.1))
        self.tower = nn.Sequential(
            _conv_bn_relu(in_channels, 128), _conv_bn_relu(128, 128), nn.MaxPool2d((2, 1)),
            _conv_bn_relu(128, 192), _conv_bn_relu(192, 192), nn.MaxPool2d((2, 1)),
            _conv_bn_relu(192, 256))
        seq_dim = 256
        self.gif = GatedInjectedFeatures(in_channels=in_channels, feat_dim=seq_dim, out_dim=seq_dim, pool_size=(4, 4))
        self.script_head = nn.Sequential(nn.Linear(2 * seq_dim, 128), nn.GELU(), nn.Dropout(dropout),
                                         nn.Linear(128, num_scripts))
        self.verify_head = nn.Sequential(nn.Linear(2 * seq_dim + 2, 128), nn.GELU(), nn.Dropout(dropout),
                                         nn.Linear(128, num_verify))
        # routing
        self.script_to_expert = nn.Linear(num_scripts, num_experts)            # 'script_driven' mode
        self.router = nn.Linear(2 * seq_dim, num_experts)                       # 'decoupled' mode
        nn.init.normal_(self.router.weight, std=0.02)       # small random init: breaks top-k ties from step 0
        nn.init.zeros_(self.router.bias)
        self.family_head = nn.Linear(2 * seq_dim, num_families)                 # auxiliary, not used for routing
        self.input_dropout = nn.Dropout(dropout)
        self.lstm_stem = nn.LSTM(input_size=seq_dim, hidden_size=hidden, num_layers=2, bidirectional=True,
                                 batch_first=True, dropout=dropout)
        self.experts = nn.ModuleList([nn.Conv1d(hidden * 2, hidden * 2, 3, padding=1) for _ in range(num_experts)])
        self.shared_expert = nn.Conv1d(hidden * 2, hidden * 2, 3, padding=1)
        self.shared_gate = nn.Linear(hidden * 2, 1)
        self.expert_norm = nn.LayerNorm(hidden * 2)
        self.feature_dropout = nn.Dropout(dropout)
        self.classifier = CompositionalCharClassifier(hidden * 2, vocab_size, chars=chars, enabled=compositional)
        self.register_buffer('char2script', torch.full((vocab_size, num_scripts), 1.0 / num_scripts))
        self.register_buffer('script_marginal', torch.full((num_scripts,), 1.0 / num_scripts))

    def set_char_statistics(self, char2script, script_marginal=None):
        m = torch.as_tensor(np.asarray(char2script), dtype=torch.float32)
        if m.shape == self.char2script.shape:
            self.char2script.copy_(m)
        if script_marginal is not None:
            self.script_marginal.copy_(torch.as_tensor(np.asarray(script_marginal), dtype=torch.float32))

    def _empty(self, ref, K=0):
        z = ref.new_zeros
        return {'text_logits': z((0, self.roi_w, self.classifier.out_features)),
                'time_lengths': torch.zeros(0, dtype=torch.long, device=ref.device),
                'rec_index': torch.zeros(0, dtype=torch.long, device=ref.device),
                'script_logits': z((K, self.num_scripts)),
                'verify_logits': z((K, self.verify_head[-1].out_features)),
                'family_logits': z((K, self.num_families)),
                'embed': z((K, 512)),
                'expert_weights': z((K, self.num_experts)),
                'router_probs': z((K, self.num_experts))}

    def route(self, pooled, script_logits):
        if self.moe_routing == 'script_driven':
            probs = torch.softmax(self.script_to_expert(torch.softmax(script_logits.float(), -1)), -1)
        else:
            r_in = pooled.float()
            if self.training and self.router_jitter > 0:
                r_in = r_in * (1.0 + self.router_jitter * torch.randn_like(r_in))
            probs = torch.softmax(self.router(r_in), -1)
        if self.top_k < self.num_experts:
            top = torch.topk(probs, self.top_k, dim=-1).indices
            keep = torch.zeros_like(probs).scatter_(1, top, 1.0)
            w = probs * keep
            w = w / w.sum(-1, keepdim=True).clamp(min=1e-8)
        else:
            w = probs
        return w, probs

    def is_long(self, rboxes):
        if self.roi_w_long <= self.roi_w:
            return torch.zeros(rboxes.shape[0], dtype=torch.bool, device=rboxes.device)
        aspect = rboxes[:, 2].float() / rboxes[:, 3].float().clamp(min=1.0)
        return aspect > self.long_aspect

    def _sequence(self, seq, ctx, ew, Kb):
        """GIF -> BiLSTM -> routed + shared experts -> classifier for one time-length bucket."""
        seq = self.input_dropout(self.gif(ctx, seq))
        lstm_out, _ = self.lstm_stem(seq)
        x_t = lstm_out.transpose(1, 2)
        expert_stack = torch.stack([e(x_t).transpose(1, 2) for e in self.experts], dim=1)
        routed = (expert_stack * ew.view(Kb, self.num_experts, 1, 1).to(expert_stack.dtype)).sum(1)
        if self.use_shared_gate:
            shared = self.shared_expert(x_t).transpose(1, 2)
            a = torch.sigmoid(self.shared_gate(lstm_out))
            mixed = a * shared + (1.0 - a) * routed
        else:
            mixed = routed
        mixed = self.feature_dropout(self.expert_norm(lstm_out + mixed))
        return self.classifier(mixed)

    def forward(self, enhanced_feats, batch_idx, rboxes, roi_masks, spatial_scale=None, rec_mask=None):
        K = rboxes.shape[0]
        if K == 0:
            return self._empty(enhanced_feats)
        scale = (1.0 / self.feature_stride) if spatial_scale is None else spatial_scale
        long_flag = self.is_long(rboxes)
        masks = roi_masks.float()
        if masks.shape[-1] != self.roi_w_long or masks.shape[-2] != self.roi_h:
            masks = F.interpolate(masks.unsqueeze(1), size=(self.roi_h, self.roi_w_long), mode='bilinear',
                                  align_corners=False).squeeze(1)
        buckets = []                                                       # (roi indices, width, seq)
        pooled = None
        for flag, Wb in ((False, self.roi_w), (True, self.roi_w_long)):
            idx = (long_flag == flag).nonzero(as_tuple=True)[0]
            if idx.numel() == 0:
                continue
            roi = oriented_roi_crop(enhanced_feats, batch_idx[idx], rboxes[idx], self.roi_h, Wb, scale)
            m = masks[idx].unsqueeze(1)
            if Wb != self.roi_w_long:
                m = F.adaptive_avg_pool2d(m, (self.roi_h, Wb))
            m = m.to(roi.dtype)
            t = self.tower(roi * (m + self.mask_gate_bias))
            mh = F.adaptive_avg_pool2d(m, (t.shape[2], t.shape[3])) + 0.1
            seq = ((t * mh).sum(2) / mh.sum(2)).transpose(1, 2)            # (k, Wb, 256)
            pb = torch.cat([seq.mean(1), seq.amax(1)], dim=-1)
            if pooled is None:
                pooled = pb.new_zeros((K, pb.shape[1]))
            pooled = pooled.index_copy(0, idx, pb)
            buckets.append((idx, Wb, seq))
        script_logits = self.script_head(pooled)
        family_logits = self.family_head(pooled)
        aspect = torch.log(rboxes[:, 2].float() / rboxes[:, 3].float().clamp(min=1.0)).clamp(-3, 3) / 3.0
        mstats = torch.stack([roi_masks.float().mean((1, 2)), aspect], -1).to(pooled.dtype)
        verify_logits = self.verify_head(torch.cat([pooled, mstats], -1))
        expert_weights, router_probs = self.route(pooled, script_logits)

        rec_set = torch.ones(K, dtype=torch.bool, device=rboxes.device) if rec_mask is None else \
            rec_mask.to(rboxes.device).bool()
        V = self.classifier.out_features
        out = {'script_logits': script_logits, 'verify_logits': verify_logits, 'family_logits': family_logits,
               'embed': pooled, 'expert_weights': expert_weights, 'router_probs': router_probs}
        ctx_all = F.adaptive_avg_pool2d(enhanced_feats, (8, 8))
        parts, idx_parts, T_max = [], [], 0
        for idx, Wb, seq in buckets:
            sel = rec_set[idx].nonzero(as_tuple=True)[0]
            if sel.numel() == 0:
                continue
            ridx = idx[sel]
            ctx = ctx_all.index_select(0, batch_idx[ridx].clamp(0, enhanced_feats.shape[0] - 1))
            parts.append((Wb, self._sequence(seq[sel], ctx, expert_weights[ridx], sel.numel())))
            idx_parts.append(ridx)
            T_max = max(T_max, Wb)
        if not parts:
            out['text_logits'] = pooled.new_zeros((0, self.roi_w, V))
            out['time_lengths'] = torch.zeros(0, dtype=torch.long, device=rboxes.device)
            out['rec_index'] = torch.zeros(0, dtype=torch.long, device=rboxes.device)
            return out
        # rows are in bucket order (one concatenation, no scatter copies); rec_index maps row -> RoI
        out['rec_index'] = torch.cat(idx_parts)
        out['text_logits'] = torch.cat([lg if Wb == T_max else self._pad_blank(lg, T_max) for Wb, lg in parts], 0)
        out['time_lengths'] = torch.cat([torch.full((lg.shape[0],), Wb, dtype=torch.long, device=rboxes.device)
                                         for Wb, lg in parts])
        return out

    def _pad_blank(self, logits, T):
        k, Tb, V = logits.shape
        pad = logits.new_full((k, T - Tb, V), self.PAD_LOGIT)
        pad[:, :, 0] = 0.0
        return torch.cat([logits, pad], 1)

    def script_prior_bias(self, script_probs):
        """Pointwise-mutual-information prior: b_c = min(0, log sum_s pi_s P(s|c)/P(s)).
        Only penalises characters that are inconsistent with the predicted script; shared symbols
        (digits, punctuation) have P(s|c) ~ P(s) and are left untouched. Blank / UNK: 0."""
        ratio = script_probs.float() @ (self.char2script / self.script_marginal.clamp(min=1e-4)).t()
        bias = torch.log(ratio.clamp(min=1e-6)).clamp(max=0.0)
        bias[:, :2] = 0.0
        return bias

    def implied_script_distribution(self, text_logits):
        """q(s) proportional to sum_t sum_{c>=2} P_t(c) P(s|c): the script implied by the recognised characters.
        Blank-only padding frames contribute ~0 mass."""
        P = torch.softmax(text_logits.float(), dim=-1)
        mass = P[:, :, 2:].sum(1)                                            # (K, V-2)
        q = mass @ self.char2script[2:]
        return q / q.sum(-1, keepdim=True).clamp(min=1e-8), mass.sum(-1)


# ==========================================
# 4. Model Architecture
# ==========================================
class IlluminationBlurAdaptiveModulation(nn.Module):
    def __init__(self, channels):
        super().__init__()
        self.spatial_gate = nn.Sequential(nn.Conv2d(channels, channels, 3, padding=1, groups=channels, bias=False),
                                          nn.Sigmoid())
        self.gamma = nn.Parameter(torch.zeros(1))

    def forward(self, x):
        xf = x.float()
        mean = xf.mean(dim=[2, 3], keepdim=True)
        std = torch.sqrt(((xf - mean) ** 2).mean(dim=[2, 3], keepdim=True) + 1e-6)
        normalized = ((xf - mean) / std).to(x.dtype)
        return x + self.gamma * (normalized * self.spatial_gate(x))


class StandardVAEFeatureReconstructor(nn.Module):
    def __init__(self, channels):
        super().__init__()
        self.encoder = nn.Conv2d(channels, channels * 2, kernel_size=1)
        self.decoder = nn.Conv2d(channels, channels, kernel_size=1)
        nn.init.zeros_(self.decoder.weight)
        nn.init.zeros_(self.decoder.bias)
        self.last_kl = None

    def forward(self, x):
        mu, logvar = torch.chunk(self.encoder(x), 2, dim=1)
        logvar = torch.clamp(logvar.float(), -10.0, 10.0)
        if self.training:
            z = mu + torch.randn_like(mu) * torch.exp(0.5 * logvar).to(mu.dtype)
        else:
            z = mu
        self.last_kl = -0.5 * torch.mean(1 + logvar - mu.float().pow(2) - logvar.exp())
        return self.decoder(z)


def build_cnn_stem(name='resnet18', pretrained=True, weights_path=None):
    """Returns (stages[C2..C5], channels, loaded_pretrained)."""
    loaded = False
    if name.startswith('resnet') and HAS_TORCHVISION and hasattr(torchvision.models, name):
        ctor = getattr(torchvision.models, name)
        m = None
        if pretrained and weights_path is None:
            try:
                m = ctor(weights='IMAGENET1K_V1')
                loaded = True
            except Exception:
                try:
                    m = ctor(pretrained=True)
                    loaded = True
                except Exception as e:
                    print(f"[backbone] could not download ImageNet weights for {name} ({type(e).__name__}); "
                          f"training the CNN stem from scratch.")
                    m = None
        if m is None:
            try:
                m = ctor(weights=None)
            except TypeError:
                m = ctor(pretrained=False)
        if weights_path and os.path.exists(weights_path):
            sd = torch.load(weights_path, map_location='cpu', weights_only=False)
            sd = sd.get('state_dict', sd) if isinstance(sd, dict) else sd
            missing, unexpected = m.load_state_dict(sd, strict=False)
            loaded = True
            print(f"[backbone] loaded {weights_path} (missing={len(missing)}, unexpected={len(unexpected)})")
        stages = nn.ModuleList([nn.Sequential(m.conv1, m.bn1, m.relu, m.maxpool, m.layer1),
                                m.layer2, m.layer3, m.layer4])
        chans = [256, 512, 1024, 2048] if name in ('resnet50', 'resnet101', 'resnet152') else [64, 128, 256, 512]
        return stages, chans, loaded

    def stage(cin, cout, stride):
        return nn.Sequential(nn.Conv2d(cin, cout, 3, stride=stride, padding=1, bias=False), nn.BatchNorm2d(cout),
                             nn.ReLU(inplace=True), _conv_bn_relu(cout, cout))
    stages = nn.ModuleList([
        nn.Sequential(nn.Conv2d(3, 32, 3, 2, 1, bias=False), nn.BatchNorm2d(32), nn.ReLU(inplace=True),
                      nn.Conv2d(32, 64, 3, 2, 1, bias=False), nn.BatchNorm2d(64), nn.ReLU(inplace=True),
                      _conv_bn_relu(64, 64)),
        stage(64, 128, 2), stage(128, 256, 2), stage(256, 512, 2)])
    return stages, [64, 128, 256, 512], False


class SGDLA_Transformer_Backbone(nn.Module):
    """Hybrid backbone: CNN pyramid (C2..C5, optionally ImageNet-initialised) + SGDLA transformer
    context blocks at stride 16 injected back before C5 (zero-initialised residual) + FPN.
    Output: concat(P2..P5 upsampled to stride 4)."""

    def __init__(self, config, in_chans=3):
        super().__init__()
        self.stages, chans, self.pretrained_loaded = build_cnn_stem(
            config.backbone, config.pretrained_backbone, config.backbone_weights_path)
        c2, c3, c4, c5 = chans
        E = config.embed_dim
        s16 = max(config.img_size // 16, 2)
        self.ctx_in = nn.Sequential(nn.Conv2d(c4, E, 1, bias=False), nn.BatchNorm2d(E))
        self.blocks = nn.ModuleList([SGDLABlock(E, config.sgdla_heads, spatial_size=(s16, s16))
                                     for _ in range(config.sgdla_depth)])
        self.norm = nn.LayerNorm(E)
        self.vae_reg = StandardVAEFeatureReconstructor(E)
        self.ctx_out = nn.Conv2d(E, c4, 1)
        nn.init.zeros_(self.ctx_out.weight)
        nn.init.zeros_(self.ctx_out.bias)
        fd = config.fpn_dim
        self.lateral = nn.ModuleList([nn.Sequential(nn.Conv2d(c, fd, 1, bias=False), nn.BatchNorm2d(fd), nn.ReLU(inplace=True))
                                      for c in chans])
        self.smooth = nn.ModuleList([_conv_bn_relu(fd, fd) for _ in chans])
        self.out_channels = 4 * fd

    def forward(self, x):
        c2 = self.stages[0](x)
        c3 = self.stages[1](c2)
        c4 = self.stages[2](c3)
        B, _, H, W = c4.shape
        t = self.ctx_in(c4)
        tok = t.flatten(2).transpose(1, 2)
        for blk in self.blocks:
            tok = blk(tok, (H, W))
        t2 = self.norm(tok).transpose(1, 2).reshape(B, -1, H, W)
        t2 = t2 + self.vae_reg(t2)
        c4 = c4 + self.ctx_out(t2)
        c5 = self.stages[3](c4)
        p5 = self.lateral[3](c5)
        p4 = self.lateral[2](c4) + F.interpolate(p5, size=c4.shape[-2:], mode='nearest')
        p3 = self.lateral[1](c3) + F.interpolate(p4, size=c3.shape[-2:], mode='nearest')
        p2 = self.lateral[0](c2) + F.interpolate(p3, size=c2.shape[-2:], mode='nearest')
        ps = [self.smooth[i](p) for i, p in enumerate((p2, p3, p4, p5))]
        size = ps[0].shape[-2:]
        fused = torch.cat([ps[0]] + [F.interpolate(p, size=size, mode='bilinear', align_corners=False) for p in ps[1:]], 1)
        return fused, self.vae_reg.last_kl


class EntropyGuidedInformationPreservingMPM(nn.Module):
    """Multi-pooling module (square 16x16 / 8x8, strip H / strip W). The branch gate receives each branch's
    per-pixel channel entropy (normalised to [0, 1]) as evidence."""

    def __init__(self, in_channels, out_channels, spatial_size=(128, 128)):
        super().__init__()
        self.reduce_conv = _conv_bn_relu(in_channels, out_channels, k=1)
        self.pool_square_1 = nn.Sequential(nn.AdaptiveAvgPool2d((16, 16)), nn.Conv2d(out_channels, out_channels, 3, padding=1, bias=False))
        self.pool_square_2 = nn.Sequential(nn.AdaptiveAvgPool2d((8, 8)), nn.Conv2d(out_channels, out_channels, 3, padding=1, bias=False))
        # strip pooling: an H x 1 map is mixed along H with a (3, 1) kernel, a 1 x W map along W with (1, 3).
        # (V4 had the kernels swapped, so only their centre taps ever saw data; upgrade_legacy_state converts.)
        self.pool_h = nn.Sequential(nn.AdaptiveAvgPool2d((None, 1)), nn.Conv2d(out_channels, out_channels, (3, 1), padding=(1, 0), bias=False))
        self.pool_w = nn.Sequential(nn.AdaptiveAvgPool2d((1, None)), nn.Conv2d(out_channels, out_channels, (1, 3), padding=(0, 1), bias=False))
        self.entropy_gate = nn.Conv2d(out_channels * 4 + 4, 4, 1)
        self.fusion = _conv_bn_relu(out_channels * 4, out_channels)
        self.neck_blender = BlendedScorer(out_channels, out_dim=out_channels, spatial_size=spatial_size, as_vector=False)
        self.last_gates = None

    @staticmethod
    def _channel_entropy(t):
        p = torch.softmax(t.float(), dim=1)
        return (-(p * torch.log(p + 1e-8)).sum(1, keepdim=True) / math.log(t.shape[1])).to(t.dtype)

    def forward(self, x):
        _, _, h, w = x.shape
        x_red = self.reduce_conv(x)
        up = lambda t: F.interpolate(t, size=(h, w), mode='bilinear', align_corners=False)
        br = [up(self.pool_square_1(x_red)), up(self.pool_square_2(x_red)), up(self.pool_h(x_red)), up(self.pool_w(x_red))]
        ent = torch.cat([self._channel_entropy(b) for b in br], 1)
        gates = torch.softmax(self.entropy_gate(torch.cat(br + [ent], 1)), dim=1)
        self.last_gates = gates.detach()
        gated = torch.cat([b * gates[:, i:i + 1] for i, b in enumerate(br)], 1)
        return self.neck_blender(self.fusion(gated) + x_red)


class AlignedPatchReconstructionHead(nn.Module):
    """Outputs (i) nested-kernel logits z_0..z_{K-1} (z_{K-1} = text region, z_k<K-1 = conditional
    kernel logits) and (ii) the 2-channel reading-direction field."""

    def __init__(self, in_channels, out_masks=6, spatial_size=(128, 128)):
        super().__init__()
        self.reduce = _conv_bn_relu(in_channels, 128)
        self.grid_align_conv = _conv_bn_relu(128, 128)
        self.scorer = BlendedScorer(128, out_dim=128, spatial_size=spatial_size, as_vector=False)
        self.mask_out = nn.Conv2d(128, out_masks, kernel_size=1)
        with torch.no_grad():
            self.mask_out.bias.zero_()
            self.mask_out.bias[-1] = -2.0          # prior p(text) ~ 0.12 -> no early false-positive flood
        self.dir_out = nn.Sequential(_conv_bn_relu(128, 64), nn.Conv2d(64, 2, 1))

    def forward(self, x):
        feat = self.reduce(x)
        feat = feat + self.grid_align_conv(feat)
        feat = self.scorer(feat)
        return self.mask_out(feat), self.dir_out(feat)


def corn_marginals(kernel_logits):
    """Nested kernels by construction: S_{K-1} = sigmoid(z_{K-1}); S_k = S_{k+1} * sigmoid(z_k)."""
    ls = F.logsigmoid(kernel_logits.float())
    return torch.flip(torch.cumsum(torch.flip(ls, [1]), 1), [1]).exp()


class A3ESpotter_V5(nn.Module):
    def __init__(self, config, vocab_size=None, num_scripts=None):
        super().__init__()
        vocab_size = config.vocab_size if vocab_size is None else vocab_size
        num_scripts = config.num_scripts if num_scripts is None else num_scripts
        self.register_buffer('pixel_mean', torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer('pixel_std', torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))
        s4 = (config.img_size // 4, config.img_size // 4)
        self.ibam = IlluminationBlurAdaptiveModulation(3)
        self.backbone = SGDLA_Transformer_Backbone(config)
        self.egip_mpm = EntropyGuidedInformationPreservingMPM(self.backbone.out_channels, config.neck_dim, spatial_size=s4)
        self.detection_head = AlignedPatchReconstructionHead(config.neck_dim, out_masks=config.num_kernels, spatial_size=s4)
        self.recognizer = ScriptAwareInstanceRecognizer(
            in_channels=config.neck_dim, roi_h=config.roi_h, roi_w=config.roi_w, hidden=config.rec_hidden,
            vocab_size=vocab_size, num_scripts=num_scripts, num_experts=config.num_experts,
            dropout=config.dropout, num_verify=config.num_verify, feature_stride=config.feature_stride,
            moe_routing=config.moe_routing, top_k=config.moe_top_k, router_jitter=config.router_jitter,
            use_shared_gate=config.use_shared_gate, num_families=len(SCRIPT_FAMILIES),
            roi_w_long=getattr(config, 'roi_w_long', config.roi_w), long_aspect=getattr(config, 'long_aspect', 12.0),
            chars=config.chars if len(config.chars) + 2 == vocab_size else None,
            compositional=getattr(config, 'use_compositional_classifier', True))
        if config.char2script is not None and np.asarray(config.char2script).shape[0] == vocab_size:
            self.recognizer.set_char_statistics(config.char2script, getattr(config, 'script_marginal', None))
        self.feature_stride = config.feature_stride

    def forward_dense(self, x):
        xn = (x - self.pixel_mean) / self.pixel_std
        fused, kl = self.backbone(self.ibam(xn))
        enh = self.egip_mpm(fused)
        kernel_logits, direction = self.detection_head(enh)
        return {'mask_logits': kernel_logits, 'detection_masks': corn_marginals(kernel_logits),
                'direction': direction, 'enhanced_feats': enh, 'kl': kl}

    def forward_rois(self, enhanced_feats, batch_idx, rboxes, roi_masks, rec_mask=None):
        return self.recognizer(enhanced_feats, batch_idx, rboxes, roi_masks, rec_mask=rec_mask)

    def forward(self, x, batch_idx=None, rboxes=None, roi_masks=None):
        out = self.forward_dense(x)
        if rboxes is not None and rboxes.shape[0] > 0:
            rec = self.forward_rois(out['enhanced_feats'], batch_idx, rboxes, roi_masks)
        else:
            rec = self.recognizer._empty(out['enhanced_feats'])
        out['extracted_text_logits'] = rec['text_logits']
        out['script_logits'] = rec['script_logits']
        out['verify_logits'] = rec['verify_logits']
        out['family_logits'] = rec['family_logits']
        out['roi_embed'] = rec['embed']
        return out


A3ESpotter_V4 = A3ESpotter_V5      # backwards-compatible names (state dicts are compatible)
A3ESpotter_V3 = A3ESpotter_V5


def upgrade_legacy_state(state):
    """Converts V4 checkpoints to the V5 layout, exactly preserving their function: the EGIP-MPM strip-pool convs
    had swapped kernel shapes ((1,3) on an H x 1 map, (3,1) on a 1 x W map), so only their centre taps mattered;
    they become (3,1) / (1,3) kernels holding that centre tap and zeros elsewhere."""
    for k, want in (('egip_mpm.pool_h.1.weight', (3, 1)), ('egip_mpm.pool_w.1.weight', (1, 3))):
        w = state.get(k)
        if w is not None and w.dim() == 4 and tuple(w.shape[-2:]) == want[::-1]:
            new = torch.zeros(*w.shape[:2], *want, dtype=w.dtype)
            new[:, :, want[0] // 2, want[1] // 2] = w[:, :, w.shape[2] // 2, w.shape[3] // 2]
            state[k] = new
    return state


def remap_vocab_state(state, old_chars, new_chars, char2script_new, old_components=None, prefix='recognizer.'):
    """Index-preserving vocabulary expansion of a checkpoint state dict (in place):
       * rows of characters present in both vocabularies are copied (blank / UNK included);
       * a new character's row is the mean of the old rows of characters sharing a Unicode component with it
         (Hangul jamo, NFD base / mark), weighted by the number of shared components; else the mean of the old
         rows of its most likely script; else the global mean. Its bias is the matching mean minus 1 (new
         characters start slightly less likely than their neighbours);
       * compositional embeddings are mapped by component name; char2script / script_marginal are dropped from
         the state so the model keeps the statistics re-estimated on the merged data."""
    wk, bk, ek = prefix + 'classifier.weight', prefix + 'classifier.bias', prefix + 'classifier.comp_embed'
    for k in (prefix + 'char2script', prefix + 'script_marginal'):
        state.pop(k, None)
    if wk not in state or old_chars is None:
        return state
    W_old, b_old = state[wk].float(), state[bk].float()
    if W_old.shape[0] != len(old_chars) + 2:
        print("[vocab] checkpoint classifier does not match its own vocabulary - not remapped.")
        return state
    old_idx = {c: i + 2 for i, c in enumerate(old_chars)}
    Vn, D = len(new_chars) + 2, W_old.shape[1]
    W = torch.zeros(Vn, D)
    b = torch.zeros(Vn)
    W[:2], b[:2] = W_old[:2], b_old[:2]
    comp_rows = defaultdict(list)
    for c, i in old_idx.items():
        for p in char_components(c):
            comp_rows[p].append(i)
    c2s = np.asarray(char2script_new) if char2script_new is not None else None
    old_scripts = defaultdict(list)
    if c2s is not None and c2s.shape[0] == Vn:
        new_pos = {c: i + 2 for i, c in enumerate(new_chars)}
        for c, i in old_idx.items():
            if c in new_pos:
                old_scripts[int(np.argmax(c2s[new_pos[c]]))].append(i)
    gW, gb = W_old[2:].mean(0), b_old[2:].mean()
    n_copy = n_comp = n_script = n_glob = 0
    for j, c in enumerate(new_chars):
        i_new = j + 2
        if c in old_idx:
            W[i_new], b[i_new] = W_old[old_idx[c]], b_old[old_idx[c]]
            n_copy += 1
            continue
        votes = Counter()
        for p in char_components(c):
            for i in comp_rows.get(p, []):
                votes[i] += 1
        if votes:
            ids = torch.tensor(list(votes.keys()))
            w = torch.tensor(list(votes.values()), dtype=torch.float32)
            w = w / w.sum()
            W[i_new] = (W_old[ids] * w[:, None]).sum(0)
            b[i_new] = (b_old[ids] * w).sum() - 1.0
            n_comp += 1
            continue
        rows = old_scripts.get(int(np.argmax(c2s[i_new]))) if c2s is not None and c2s.shape[0] == Vn else None
        if rows:
            ids = torch.tensor(rows)
            W[i_new], b[i_new] = W_old[ids].mean(0), b_old[ids].mean() - 1.0
            n_script += 1
        else:
            W[i_new], b[i_new] = gW, gb - 1.0
            n_glob += 1
    is_new = torch.tensor([0, 0] + [0 if c in old_idx else 1 for c in new_chars], dtype=torch.float32)
    W += 0.01 * float(W_old[2:].std()) * torch.randn(Vn, D) * is_new[:, None]   # break ties between new rows
    state[wk], state[bk] = W.to(state[wk].dtype), b.to(state[bk].dtype)
    if ek in state:
        new_names = build_component_table(new_chars)[0]
        E_old = state[ek]
        if old_components and len(old_components) == E_old.shape[0]:
            pos = {n: i for i, n in enumerate(old_components)}
            E = torch.zeros(max(len(new_names), 1), E_old.shape[1], dtype=E_old.dtype)
            for i, n in enumerate(new_names):
                if n in pos:
                    E[i] = E_old[pos[n]]
            state[ek] = E
        else:
            state.pop(ek)
    print(f"[vocab] classifier remapped {len(old_chars)} -> {len(new_chars)} symbols: {n_copy} copied, "
          f"{n_comp} from shared components, {n_script} from same-script mean, {n_glob} from global mean.")
    return state


# =========================================================
# 5. PSE post-processing (correct semantics) & instance extraction
# =========================================================
try:
    from scipy import ndimage as _ndi
    HAS_SCIPY = True
except Exception:
    _ndi = None
    HAS_SCIPY = False

_CROSS = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3))


def progressive_scale_expansion(kernels_bin, min_kernel_area=1):
    """kernels_bin: (K, H, W) bool; index 0 = smallest kernel, K-1 = full text region. Kernels must
    already be restricted to the text region. Seeds = connected components of kernel 0; each seed grows
    inside kernel k until nothing more can be reached, then inside kernel k+1, etc.
    Implemented with iterative label dilation (fast, no Python BFS)."""
    kernels_bin = np.asarray(kernels_bin, dtype=bool)
    K = kernels_bin.shape[0]
    num, labels = cv2.connectedComponents(kernels_bin[0].astype(np.uint8), connectivity=4)
    if num <= 1:
        return labels.astype(np.int32), 1
    areas = np.bincount(labels.ravel(), minlength=num)
    small = np.where(areas < max(1, int(min_kernel_area)))[0]
    small = small[small > 0]
    if len(small):
        labels[np.isin(labels, small)] = 0
    lab = labels.astype(np.float32)
    for k in range(1, K):
        allowed = kernels_bin[k]
        while True:
            dil = cv2.dilate(lab, _CROSS)
            grow = (lab == 0) & allowed & (dil > 0)
            if not grow.any():
                break
            lab[grow] = dil[grow]
    return lab.astype(np.int32), num


def _label_slices(labels, num):
    if HAS_SCIPY:
        return _ndi.find_objects(labels, max_label=num - 1)
    out = []
    for lab in range(1, num):
        ys, xs = np.where(labels == lab)
        out.append(None if len(ys) == 0 else (slice(ys.min(), ys.max() + 1), slice(xs.min(), xs.max() + 1)))
    return out


def extract_instances(S, direction, grid_stride, cfg, min_score=None):
    """S: (K, H, W) nested kernel probabilities on the PSE grid; direction: (2, H, W).
    Returns a list of instances with oriented boxes in (resized) image pixels."""
    min_score = cfg.min_score if min_score is None else min_score
    text = S[-1]
    text_mask = text > cfg.text_thresh
    kb = (S > cfg.kernel_thresh) & text_mask[None]
    kb[-1] = text_mask
    min_area_grid = cfg.min_area / float(grid_stride ** 2)
    labels, num = progressive_scale_expansion(kb, min_kernel_area=max(1, int(round(min_area_grid * cfg.min_scale ** 2))))
    dn = direction / (np.linalg.norm(direction, axis=0, keepdims=True) + 1e-6)
    insts = []
    for lab_i, sl in enumerate(_label_slices(labels, num)):
        if sl is None:
            continue
        lab = lab_i + 1
        sub = labels[sl] == lab
        area = int(sub.sum())
        if area < max(min_area_grid, 1):
            continue
        score = float(text[sl][sub].mean())
        if score < min_score:
            continue
        y0, x0 = sl[0].start, sl[1].start
        cnts, _ = cv2.findContours(sub.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not cnts:
            continue
        cnt = max(cnts, key=cv2.contourArea).reshape(-1, 2).astype(np.float32) + np.array([x0, y0], dtype=np.float32)
        ys, xs = np.nonzero(sub)
        pts = np.stack([xs + x0, ys + y0], 1).astype(np.float32)
        rect = cv2.minAreaRect(pts if len(pts) >= 3 else np.concatenate([pts, pts + 0.5]))
        bp = cv2.boxPoints(rect)
        a1, a2 = _unit(bp[1] - bp[0]), _unit(bp[2] - bp[1])
        d = dn[:, ys + y0, xs + x0].mean(1)
        dconf = float(np.hypot(d[0], d[1]))
        if dconf > 0.25:
            u = a1 if abs(float(d @ a1)) >= abs(float(d @ a2)) else a2
            if float(d @ u) < 0:
                u = -u
        else:
            l1, l2 = np.hypot(*(bp[1] - bp[0])), np.hypot(*(bp[2] - bp[1]))
            u = a1 if l1 >= l2 else a2
            if u[0] < -1e-6 or (abs(u[0]) < 1e-6 and u[1] < 0):
                u = -u
        rb = rbox_from_points(pts + 0.5, u)
        rb[0] *= grid_stride
        rb[1] *= grid_stride
        rb[2] = (rb[2] + 1.0) * grid_stride
        rb[3] = (rb[3] + 1.0) * grid_stride
        insts.append({'rbox': rb, 'quad': rbox_to_quad(rb), 'score': score, 'area': area * grid_stride ** 2,
                      'dir_conf': dconf, 'contour': (cnt + 0.5) * grid_stride})
    return insts, labels


def roi_mask_from_labels(labels, box, out_h, out_w):
    """Legacy helper (axis-aligned). Kept for API compatibility."""
    x1, y1, x2, y2 = [int(v) for v in box]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = max(x1 + 1, x2), max(y1 + 1, y2)
    sub = labels[y1:y2, x1:x2]
    if sub.size == 0:
        return np.ones((out_h, out_w), dtype=np.float32)
    vals, counts = np.unique(sub[sub > 0], return_counts=True)
    m = np.ones_like(sub, dtype=np.float32) if len(vals) == 0 else (sub == vals[np.argmax(counts)]).astype(np.float32)
    return cv2.resize(m, (out_w, out_h), interpolation=cv2.INTER_LINEAR)


# ==========================================
# 6. Losses & Metrics
# ==========================================
def masked_dice_loss(pred, target, mask, eps=1e-6):
    pred = (pred * mask).reshape(pred.size(0), -1)
    target = (target * mask).reshape(target.size(0), -1)
    inter = (pred * target).sum(1)
    union = pred.sum(1) + target.sum(1)
    return (1 - (2. * inter + eps) / (union + eps)).mean()


def ohem_select(score, gt, tm, ratio=3.0):
    """PSENet OHEM: all positives + the ratio*|pos| highest-scoring negatives (all valid pixels if no positives)."""
    sel = torch.zeros_like(gt)
    for b in range(score.shape[0]):
        valid = tm[b, 0] > 0.5
        pos = (gt[b, 0] > 0.5) & valid
        neg = (gt[b, 0] <= 0.5) & valid
        n_pos, n_neg_av = int(pos.sum()), int(neg.sum())
        if n_pos == 0:
            sel[b, 0] = valid.float()
            continue
        n_neg = min(n_neg_av, int(n_pos * ratio))
        s = pos.clone()
        if n_neg > 0:
            thr = torch.topk(score[b, 0][neg], n_neg).values.min()
            s = s | (neg & (score[b, 0] >= thr))
        sel[b, 0] = s.float()
    return sel


class DetectionMaskLoss(nn.Module):
    """Text: OHEM Dice + OHEM BCE. Kernels: conditional (rank-consistent) terms - kernel k is supervised only
    inside GT kernel k+1 - plus PSENet-style Dice on the marginal kernels that PSE thresholds."""

    def __init__(self, ohem_ratio=3.0, w_text=0.7, w_kernel=0.3, bce_weight=1.0):
        super().__init__()
        self.ohem_ratio, self.w_text, self.w_kernel, self.bce_weight = ohem_ratio, w_text, w_kernel, bce_weight

    def forward(self, logits, target, training_mask):
        z = logits.float()
        g = target.float().clamp(0, 1)
        tm = training_mask.float().unsqueeze(1)
        K = z.shape[1]
        p_text, g_text = torch.sigmoid(z[:, -1:]), g[:, -1:]
        with torch.no_grad():
            sel = ohem_select(p_text, g_text, tm, self.ohem_ratio)
        bce_text = (F.binary_cross_entropy_with_logits(z[:, -1:], g_text, reduction='none') * sel).sum() / sel.sum().clamp(min=1.0)
        l_text = masked_dice_loss(p_text, g_text, sel) + self.bce_weight * bce_text
        l_cond = z.new_zeros(())
        for k in range(K - 1):
            region = (g[:, k + 1:k + 2] > 0.5).float() * tm
            l_cond = l_cond + masked_dice_loss(torch.sigmoid(z[:, k:k + 1]), g[:, k:k + 1], region) + \
                (F.binary_cross_entropy_with_logits(z[:, k:k + 1], g[:, k:k + 1], reduction='none') * region).sum() / region.sum().clamp(min=1.0)
        l_cond = l_cond / max(K - 1, 1)
        S = corn_marginals(z)
        region_t = (g_text > 0.5).float() * tm
        l_marg = z.new_zeros(())
        for k in range(K - 1):
            l_marg = l_marg + masked_dice_loss(S[:, k:k + 1], g[:, k:k + 1], region_t)
        l_marg = l_marg / max(K - 1, 1)
        l_kernel = l_cond + 0.5 * l_marg
        return self.w_text * l_text + self.w_kernel * l_kernel, {'text': l_text.detach(), 'kernel': l_kernel.detach()}


def direction_field_loss(pred, target, weight, training_mask):
    p = F.normalize(pred.float(), dim=1, eps=1e-6)
    cos = (p * target.float()).sum(1)
    w = weight.float() * training_mask.float()
    return ((1.0 - cos) * w).sum() / w.sum().clamp(min=1e-6)


def ctc_feasible(text_seq, text_len, T):
    """CTC needs L + (#adjacent repeats) frames; infeasible targets would give inf (zeroed -> silent dilution)."""
    S = text_seq.shape[1]
    if S < 2:
        return text_len <= T
    pos = torch.arange(S - 1, device=text_seq.device)[None]
    rep = ((text_seq[:, 1:] == text_seq[:, :-1]) & (pos < (text_len[:, None] - 1))).sum(1)
    return (text_len + rep) <= T


def ctc_loss_fp32(text_logits, text_seq, text_len, time_lengths=None, entropy_beta=0.0, return_parts=False):
    """Per-sample length-normalised CTC (= reduction 'mean'), computed per time-length bucket on the valid frames
    only, CTC-infeasible targets excluded. entropy_beta > 0 adds a frame-entropy (confidence) penalty."""
    K, T, _ = text_logits.shape
    if time_lengths is None:
        time_lengths = torch.full((K,), T, dtype=torch.long, device=text_logits.device)
    losses, ents = [], []
    for Tb in torch.unique(time_lengths).tolist():
        sel = (time_lengths == Tb).nonzero(as_tuple=True)[0]
        sel = sel[ctc_feasible(text_seq[sel], text_len[sel], int(Tb))]
        if sel.numel() == 0:
            continue
        lp = text_logits[sel, :int(Tb)].float().log_softmax(-1)
        L = F.ctc_loss(lp.permute(1, 0, 2), text_seq[sel],
                       torch.full((sel.numel(),), int(Tb), dtype=torch.long, device=lp.device),
                       text_len[sel], blank=0, reduction='none', zero_infinity=True)
        losses.append(L / text_len[sel].clamp(min=1).float())
        if entropy_beta > 0:                                # bounded subset: (K, T, V) temporaries are large
            le = lp[:64]
            ents.append(-(le.exp() * le).sum(-1).mean(-1))
    if not losses:
        z = text_logits.float().sum() * 0.0
        return (z, z.detach()) if return_parts else z
    ctc = torch.cat(losses).mean()
    total = ctc - entropy_beta * torch.cat(ents).mean() if (entropy_beta > 0 and ents) else ctc
    return (total, ctc.detach()) if return_parts else total


def focal_cross_entropy(logits, target, gamma=2.0, weight=None):
    logp = F.log_softmax(logits.float(), -1)
    ce = F.nll_loss(logp, target, weight=weight, reduction='none')
    pt = torch.exp(logp.gather(1, target.view(-1, 1)).squeeze(1))
    return ((1 - pt) ** gamma * ce).mean()


def family_aux_loss(rois, targets):
    """Soft cross-entropy of the auxiliary family head against char-statistics-derived soft targets."""
    fl = rois.get('family_logits') if rois is not None else None
    ft = targets.get('family_target')
    if fl is None or ft is None or fl.shape[0] == 0:
        return None
    w = ft.sum(-1)
    ok = w > 1e-6
    if not ok.any():
        return None
    t = ft[ok] / w[ok].unsqueeze(-1)
    return -(t * F.log_softmax(fl[ok].float(), -1)).sum(-1).mean()


def _rec_subset(rois, targets):
    """(text logits, time lengths, target rows) of the recognised RoIs that carry a valid CTC target."""
    tl = rois.get('text_logits')
    if tl is None or tl.shape[0] == 0:
        return None
    ridx = rois['rec_index']
    rv = targets['rec_valid'][ridx]
    if not bool(rv.any()):
        return None
    rows = ridx[rv]
    if bool(rv.all()):
        return tl, rois['time_lengths'], rows
    return tl[rv], rois['time_lengths'][rv], rows


def _script_consistency(recognizer, tl, sid, cfg, exclude, time_lengths=None):
    ok = sid >= 0
    for ex in exclude:
        ok = ok & (sid != ex)
    if not bool(ok.any()):
        return None
    sel = ok.nonzero(as_tuple=True)[0][:cfg.max_script_consistency_rois]
    if time_lengths is None:
        q, _ = recognizer.implied_script_distribution(tl[sel])
        return F.nll_loss(torch.log(q.clamp(min=1e-6)), sid[sel])
    losses = []
    for Tb in torch.unique(time_lengths[sel]).tolist():          # valid frames only (no padding softmax)
        sb = sel[time_lengths[sel] == Tb]
        q, _ = recognizer.implied_script_distribution(tl[sb, :int(Tb)])
        losses.append(F.nll_loss(torch.log(q.clamp(min=1e-6)), sid[sb], reduction='sum'))
    return torch.stack(losses).sum() / sel.numel()


def crop_recognition_loss(rois, targets, recognizer, cfg):
    """Loss for the word-crop / scene-strip stream: CTC (+ script consistency) + script CE + light family term."""
    total = rois['script_logits'].new_zeros((), dtype=torch.float32)
    logs = {}
    sub = _rec_subset(rois, targets)
    if sub is not None:
        tl, tls, rows = sub
        l, l_ctc = ctc_loss_fp32(tl, targets['text_seq'][rows], targets['text_len'][rows], tls,
                                 cfg.ctc_entropy_beta, return_parts=True)
        logs['crop_ctc'] = float(l_ctc)
        total = total + cfg.w_rec * l
        if cfg.w_script_consistency > 0:
            exclude = [cfg.script2id[n] for n in ('none', 'mixed', 'unknown')]
            l_sc = _script_consistency(recognizer, tl, targets['script_id'][rows], cfg, exclude, tls)
            if l_sc is not None:
                total = total + cfg.w_rec * cfg.w_script_consistency * l_sc
    sv = targets['script_id'] >= 0
    if sv.any():
        total = total + cfg.w_script * F.cross_entropy(rois['script_logits'][sv].float(), targets['script_id'][sv],
                                                       label_smoothing=cfg.label_smoothing)
    lf = family_aux_loss(rois, targets)
    if lf is not None:
        total = total + cfg.w_family * lf
    logs['crop_total'] = float(total.detach())
    return total, logs


class UnifiedSpotterLoss(nn.Module):
    """Five task groups: detection (text+kernels), direction field, recognition (CTC + script
    consistency), script-ID, verification. Bounded homoscedastic-uncertainty weighting: s_k = b*tanh(r_k),
    so no task can be down-weighted by more than e^b."""
    TASKS = ('det', 'dir', 'rec', 'script', 'verify')

    def __init__(self, config):
        super().__init__()
        self.cfg = config
        self.mask_loss_fn = DetectionMaskLoss(ohem_ratio=config.ohem_ratio, w_text=config.w_text, w_kernel=config.w_kernel)
        self.raw_log_vars = nn.Parameter(torch.zeros(len(self.TASKS)))
        self.base_w = {'det': 1.0, 'dir': config.w_dir, 'rec': config.w_rec, 'script': config.w_script,
                       'verify': config.w_verify}
        self.script_consistency_exclude = [config.script2id[k] for k in ('none', 'mixed', 'unknown')]

    def log_vars(self):
        return self.cfg.uncertainty_bound * torch.tanh(self.raw_log_vars)

    def forward(self, dense, rois, targets, recognizer=None):
        comps, logs = {}, {}
        det, parts = self.mask_loss_fn(dense['mask_logits'], targets['masks'], targets['training_mask'])
        comps['det'] = det
        logs['text'], logs['kernel'] = float(parts['text']), float(parts['kernel'])
        comps['dir'] = direction_field_loss(dense['direction'], targets['direction'], targets['direction_weight'],
                                            targets['training_mask'])
        if rois is not None and rois['script_logits'].shape[0] > 0:
            sub = _rec_subset(rois, targets)
            if sub is not None:
                tl, tls, rows = sub
                l_rec, l_ctc = ctc_loss_fp32(tl, targets['text_seq'][rows], targets['text_len'][rows], tls,
                                             self.cfg.ctc_entropy_beta, return_parts=True)
                logs['ctc'] = float(l_ctc)
                if recognizer is not None and self.cfg.w_script_consistency > 0:
                    l_sc = _script_consistency(recognizer, tl, targets['script_id'][rows], self.cfg,
                                               self.script_consistency_exclude, tls)
                    if l_sc is not None:
                        logs['script_consistency'] = float(l_sc.detach())
                        l_rec = l_rec + self.cfg.w_script_consistency * l_sc
                comps['rec'] = l_rec
            sv = targets['script_id'] >= 0
            if sv.any():
                comps['script'] = F.cross_entropy(rois['script_logits'][sv].float(), targets['script_id'][sv],
                                                  label_smoothing=self.cfg.label_smoothing)
            comps['verify'] = focal_cross_entropy(rois['verify_logits'], targets['verify'])
        l_family = family_aux_loss(rois, targets) if rois is not None else None
        s = self.log_vars()
        total = dense['mask_logits'].new_zeros((), dtype=torch.float32)
        for i, k in enumerate(self.TASKS):
            if k not in comps:
                continue
            L = comps[k].float()
            logs[k] = float(L.detach())
            if self.cfg.use_uncertainty_weighting:
                total = total + self.base_w[k] * (torch.exp(-s[i]) * L + s[i])
            else:
                total = total + self.base_w[k] * L
        if l_family is not None and self.cfg.w_family > 0:
            total = total + self.cfg.w_family * l_family       # light, fixed weight (outside the uncertainty terms)
            logs['family'] = float(l_family.detach())
        kl = dense.get('kl', None)
        if kl is not None:
            total = total + self.cfg.kl_weight * kl.float()
            logs['kl'] = float(kl.detach())
        logs['total'] = float(total.detach())
        return total, logs


def compute_metrics(pred_masks, target_masks, training_mask, threshold=0.5):
    """Pixel-level text-region metrics (kept only as a cheap diagnostic; NOT used for model selection)."""
    tm = (training_mask.float() > 0.5).float()
    pred = (pred_masks[:, -1].float() > threshold).float() * tm
    target = (target_masks[:, -1].float() > threshold).float() * tm
    inter = (pred * target).sum()
    return inter.item(), pred.sum().item(), target.sum().item()


def edit_distance(a, b):
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
        prev = cur
    return prev[-1]


def greedy_decode_batch(scores, time_lengths, config, normalized=True, chunk=32):
    """Greedy CTC decoding on the device: only (K, T) argmax / max-prob maps leave the GPU (V can be 8,000).
    `scores` are log-probabilities (normalized=True) or raw logits; processed in chunks to bound memory."""
    if scores.shape[0] == 0:
        return []
    pm, am = [], []
    for i in range(0, scores.shape[0], chunk):
        x = scores[i:i + chunk].detach().float()
        if not normalized:
            x = x.log_softmax(-1)
        p, a = x.max(-1)
        pm.append(p.exp().cpu())
        am.append(a.cpu())
    pmax, amax = torch.cat(pm).numpy(), torch.cat(am).numpy()
    tls = time_lengths.cpu().numpy() if time_lengths is not None else np.full(len(amax), amax.shape[1])
    out = []
    for k in range(len(amax)):
        res, confs, prev = [], [], 0
        for t in range(int(tls[k])):
            p = int(amax[k, t])
            if p != prev and p > 1 and p in config.itos:
                res.append(config.itos[p])
                confs.append(float(pmax[k, t]))
            prev = p
        conf = float(np.exp(np.mean(np.log(np.clip(confs, 1e-8, 1.0))))) if confs else 0.0
        out.append((visual_order(''.join(res)), conf))            # RTL readings back to logical order
    return out


def compute_recognition_metrics(rois, targets, config):
    """Teacher-forced (GT RoIs) recognition / script / verification statistics, also per script."""
    out = defaultdict(float)
    for k in ('rec_correct', 'rec_total', 'ned_sum', 'script_correct', 'script_total', 'verify_correct', 'verify_total'):
        out[k] = 0
    if rois is None or rois['script_logits'].shape[0] == 0:
        return out
    sub = _rec_subset(rois, targets)
    if sub is not None:
        tl, tls, rows = sub
        decoded = greedy_decode_batch(tl, tls, config, normalized=False)
        seqs = targets['text_seq'][rows].cpu().numpy()
        lens = targets['text_len'][rows].cpu().numpy()
        sids = targets['script_id'][rows].cpu().numpy()
        for i, (pr, _) in enumerate(decoded):
            gt = config.decode_indices_raw(seqs[i][:lens[i]].tolist())
            ned = edit_distance(pr, gt) / max(len(gt), len(pr), 1)
            out['rec_correct'] += int(pr == gt)
            out['rec_total'] += 1
            out['ned_sum'] += ned
            s = int(sids[i])
            out[f'ps_ned@{s}'] += ned
            out[f'ps_n@{s}'] += 1
            out[f'ps_correct@{s}'] += int(pr == gt)
    sv = targets['script_id'] >= 0
    if sv.any():
        out['script_correct'] += int((rois['script_logits'][sv].argmax(-1) == targets['script_id'][sv]).sum())
        out['script_total'] += int(sv.sum())
    out['verify_correct'] += int((rois['verify_logits'].argmax(-1) == targets['verify']).sum())
    out['verify_total'] += int(targets['verify'].numel())
    return out


# ---------------------------------------------------------------------------------------------
# ICDAR-style instance-level evaluation (IC15 protocol: IoU > 0.5, one-to-one, don't-care handling;
# E2E: case-insensitive exact match after stripping leading/trailing symbols; Latin words of 1-2 characters
# are don't care, as in IC15 - for CJK / Korean / Arabic ... words that rule would drop real words)
# ---------------------------------------------------------------------------------------------
def _edge_strippable(c):
    """Leading / trailing punctuation, symbols, separators and controls are ignored by the E2E match; letters,
    digits and combining marks (Indic vowel signs / virama, Arabic harakat) are kept - stripping a trailing vowel
    sign would make wrong Hindi / Bangla words match."""
    return unicodedata.category(c)[0] in 'PSZC'


def text_for_eval(t):
    t = unicodedata.normalize('NFKC', t or '').strip()
    i, j = 0, len(t)
    while i < j and _edge_strippable(t[i]):
        i += 1
    while j > i and _edge_strippable(t[j - 1]):
        j -= 1
    return t[i:j].casefold()


def e2e_cares(gt_text, min_len):
    t = text_for_eval(gt_text)
    if not t:
        return False
    if all(ord(c) < 0x250 for c in t):
        return len(t) >= min_len
    return True


def _greedy_match(iou, thr):
    """GT-major greedy one-to-one matching (the IC15 script's order). Returns [(gt, det)]."""
    n_g, n_d = iou.shape
    g_used, d_used = np.zeros(n_g, bool), np.zeros(n_d, bool)
    pairs = []
    for i in range(n_g):
        for j in range(n_d):
            if not d_used[j] and iou[i, j] > thr:
                g_used[i] = d_used[j] = True
                pairs.append((i, j))
                break
    return pairs


def evaluate_image(gts, dets, e2e_min_len=3, iou_thr=0.5):
    """gts: [{'poly', 'text', 'ignore', ['script']}]; dets: [{'poly', 'text', 'legible', ['e2e']}] (image coords).
    Also returns per-script recall counts ('det_tp@Latin', 'e2e_ngt@Korean', ...)."""
    r = defaultdict(float)

    def iou_mat(g_list, d_list):
        m = np.zeros((len(g_list), len(d_list)), dtype=np.float32)
        for i, g in enumerate(g_list):
            for j, d in enumerate(d_list):
                m[i, j] = polygon_iou(g['poly'], d['poly'])
        return m

    # ---- detection ----
    care = [g for g in gts if not g['ignore']]
    dc = [g for g in gts if g['ignore']]
    dets_ok = [d for d in dets if not any(polygon_inter_over_first(d['poly'], g['poly']) > 0.5 for g in dc)]
    pairs = _greedy_match(iou_mat(care, dets_ok), iou_thr) if care and dets_ok else []
    r['det_tp'] += len(pairs); r['det_ngt'] += len(care); r['det_ndet'] += len(dets_ok)
    matched = {i for i, _ in pairs}
    for i, g in enumerate(care):
        s = g.get('script', 'Unknown')
        r['det_ngt@' + s] += 1
        r['det_tp@' + s] += int(i in matched)
    # ---- end-to-end ----
    e_care = [g for g in gts if not g['ignore'] and e2e_cares(g['text'], e2e_min_len)]
    e_dc = [g for g in gts if g['ignore'] or not e2e_cares(g['text'], e2e_min_len)]
    e_dets = [d for d in dets if d.get('e2e', d.get('legible', True) and d.get('text', '') not in ('', '###'))]
    e_dets = [d for d in e_dets if not any(polygon_inter_over_first(d['poly'], g['poly']) > 0.5 for g in e_dc)]
    pairs = _greedy_match(iou_mat(e_care, e_dets), iou_thr) if e_care and e_dets else []
    tp = 0
    hit = set()
    for i, j in pairs:
        a, b = text_for_eval(e_care[i]['text']), text_for_eval(e_dets[j]['text'])
        if a == b:
            tp += 1
            hit.add(i)
        ned = edit_distance(a, b) / max(len(a), len(b), 1)
        r['ned_sum'] += ned
        r['ned_n'] += 1
        r['ned_all_sum'] += ned
        r['ned_all_n'] += 1
    r['e2e_tp'] += tp; r['e2e_ngt'] += len(e_care); r['e2e_ndet'] += len(e_dets)
    n_unmatched = (len(e_care) - len(pairs)) + (len(e_dets) - len(pairs))   # each counts NED = 1
    r['ned_all_sum'] += n_unmatched
    r['ned_all_n'] += n_unmatched
    for i, g in enumerate(e_care):
        s = g.get('script', 'Unknown')
        r['e2e_ngt@' + s] += 1
        r['e2e_tp@' + s] += int(i in hit)
    return r


def summarize_eval(acc):
    def prh(tp, nd, ng):
        p = tp / nd if nd > 0 else 0.0
        rc = tp / ng if ng > 0 else 0.0
        return p, rc, (2 * p * rc / (p + rc) if p + rc > 0 else 0.0)
    dp, dr, dh = prh(acc['det_tp'], acc['det_ndet'], acc['det_ngt'])
    ep, er, eh = prh(acc['e2e_tp'], acc['e2e_ndet'], acc['e2e_ngt'])
    ned = 1.0 - acc['ned_sum'] / acc['ned_n'] if acc['ned_n'] > 0 else 0.0
    ned_all = 1.0 - acc['ned_all_sum'] / acc['ned_all_n'] if acc['ned_all_n'] > 0 else 0.0
    # one_minus_ned: matched pairs only (V4 definition); one_minus_ned_all: misses / false alarms count NED = 1
    out = {'det_precision': dp, 'det_recall': dr, 'det_hmean': dh, 'e2e_precision': ep, 'e2e_recall': er,
           'e2e_hmean': eh, 'one_minus_ned': ned, 'one_minus_ned_all': ned_all, 'spot_score': 0.5 * (dh + eh)}
    for k in list(acc.keys()):
        if k.startswith('e2e_ngt@') or k.startswith('det_ngt@'):
            task, s = k.split('_ngt@')
            if acc[k] >= 1:
                out[f'{task}_recall@{s}'] = acc[f'{task}_tp@{s}'] / acc[k]
                out[f'{task}_n@{s}'] = acc[k]
    return out


def gt_records(gt_path):
    return [{'poly': canonical_quad(g['poly']), 'text': g['transcript'], 'ignore': g['ignore'],
             'script': g['language']} for g in read_gt_file(gt_path)]


# ==========================================
# 7. Spotting engine (whole-image, tile-stitched, multi-scale inference)
# ==========================================
def _np_corn_marginals(z):
    ls = -np.logaddexp(0.0, -z)                      # log sigmoid
    return np.exp(np.flip(np.cumsum(np.flip(ls, 0), 0), 0))


def _resize_chw(a, size_hw, interp=cv2.INTER_LINEAR):
    h, w = size_hw
    if a.shape[1] == h and a.shape[2] == w:
        return a
    out = [cv2.resize(a[i:i + 512].transpose(1, 2, 0), (w, h), interpolation=interp).reshape(h, w, -1).transpose(2, 0, 1)
           for i in range(0, a.shape[0], 512)]
    return np.concatenate(out, 0)


class SpottingEngine:
    """Image -> resized/padded canvas -> dense outputs (single pass or overlapping tiles with linear-ramp
    blending of LOGITS, direction and features) -> optional multi-scale fusion -> one global PSE ->
    oriented RoIs -> recognition + script + verification -> (V5) rectified-strip re-reading of the original
    pixels + read-policy arbitration -> filtered detections (original pixel coords)."""

    REC_CHUNK = 64

    def __init__(self, model, config, device=None):
        self.model = model
        self.cfg = config
        self.device = device or torch.device('cuda' if torch.cuda.is_available() else 'cpu')
        self.use_amp = (self.device.type == 'cuda') and config.use_amp
        self.model.to(self.device)

    # ---------------- resizing ----------------
    def _prepare(self, img, scale):
        cfg = self.cfg
        h, w = img.shape[:2]
        s = cfg.infer_short_side * scale / float(min(h, w))
        if max(h, w) * s > cfg.infer_max_long_side:
            s = cfg.infer_max_long_side / float(max(h, w))
        nh, nw = max(32, int(round(h * s))), max(32, int(round(w * s)))
        ph, pw = int(math.ceil(nh / 32.0) * 32), int(math.ceil(nw / 32.0) * 32)
        canvas = np.zeros((ph, pw, 3), dtype=np.uint8)
        canvas[:nh, :nw] = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA if s < 1 else cv2.INTER_LINEAR)
        return canvas, (nw / float(w), nh / float(h)), (nh, nw)

    def _to_tensor(self, arr):
        return torch.from_numpy(np.ascontiguousarray(arr)).permute(2, 0, 1).float().div(255.0).unsqueeze(0).to(self.device)

    @torch.no_grad()
    def _forward(self, x):
        with torch.autocast(device_type=self.device.type, enabled=self.use_amp):
            out = self.model.forward_dense(x)
        return out['mask_logits'].float(), out['direction'].float(), out['enhanced_feats']

    @staticmethod
    def _ramp(n, lo_side, hi_side, r):
        w = np.ones(n, dtype=np.float32)
        r = max(1, min(r, n // 2))
        ramp = np.linspace(0.02, 1.0, r, dtype=np.float32)
        if lo_side:
            w[:r] = np.minimum(w[:r], ramp)
        if hi_side:
            w[-r:] = np.minimum(w[-r:], ramp[::-1])
        return w

    @torch.no_grad()
    def dense(self, canvas):
        cfg = self.cfg
        H, W = canvas.shape[:2]
        st = cfg.feature_stride
        if max(H, W) <= cfg.tile_max_side:
            z, d, f = self._forward(self._to_tensor(canvas))
            return z[0].cpu().numpy(), d[0].cpu().numpy(), f.float().cpu()
        T = int(cfg.tile_size // 32 * 32)
        ov = int(cfg.tile_overlap)
        step = max(32, T - ov)
        Th, Tw = min(T, H), min(T, W)

        def starts(total, t):
            s = list(range(0, max(total - t, 0) + 1, step))
            if s[-1] != max(total - t, 0):
                s.append(max(total - t, 0))
            return s
        ys, xs = starts(H, Th), starts(W, Tw)
        h4, w4 = H // st, W // st
        z_acc = np.zeros((self.cfg.num_kernels, h4, w4), dtype=np.float32)
        d_acc = np.zeros((2, h4, w4), dtype=np.float32)
        f_acc = None
        w_acc = np.zeros((h4, w4), dtype=np.float32)
        r = max(1, ov // st)
        for yi, y0 in enumerate(ys):
            for xi, x0 in enumerate(xs):
                z, d, f = self._forward(self._to_tensor(canvas[y0:y0 + Th, x0:x0 + Tw]))
                th, tw = z.shape[-2:]
                wy = self._ramp(th, yi > 0, yi < len(ys) - 1, r)
                wx = self._ramp(tw, xi > 0, xi < len(xs) - 1, r)
                wt = wy[:, None] * wx[None, :]
                ys4, xs4 = y0 // st, x0 // st
                z_acc[:, ys4:ys4 + th, xs4:xs4 + tw] += z[0].cpu().numpy() * wt
                d_acc[:, ys4:ys4 + th, xs4:xs4 + tw] += d[0].cpu().numpy() * wt
                if f_acc is None:
                    f_acc = torch.zeros((1, f.shape[1], h4, w4), dtype=torch.float32)
                f_acc[:, :, ys4:ys4 + th, xs4:xs4 + tw] += f.float().cpu() * torch.from_numpy(wt)
                w_acc[ys4:ys4 + th, xs4:xs4 + tw] += wt
        w_acc = np.maximum(w_acc, 1e-6)
        return z_acc / w_acc, d_acc / w_acc, f_acc / torch.from_numpy(w_acc)

    # ---------------- decoding: consensus script posterior + entropy-gated PMI prior ----------------
    def _consensus(self, sp, q, mass):
        """pi ~ p_head(s) * q_ctc(s)^(gamma * w), w = min(1, expected emitted characters / 2): the script implied
        by what was actually read overrides a confident but wrong script head (the IC15 'Chinese' Latin words)."""
        w = (mass.float() / 2.0).clamp(0, 1).unsqueeze(-1) * float(self.cfg.script_consensus_gamma)
        return torch.softmax(torch.log(sp.float() + 1e-6) + w * torch.log(q.float() + 1e-3), -1)

    @torch.no_grad()
    def _decode(self, out):
        """Decoded readings in RoI order (text_logits rows are bucket-ordered; out['rec_index'] maps them back)."""
        cfg = self.cfg
        rec = self.model.recognizer
        tl = out['text_logits']
        if tl.shape[0] == 0:
            return []
        ridx = out['rec_index']
        sp = torch.softmax(out['script_logits'].float(), -1)[ridx]
        q, mass = rec.implied_script_distribution(tl)
        pi = self._consensus(sp, q, mass)
        lp = tl.float().log_softmax(-1)
        if cfg.script_prior_lambda > 0:
            S = pi.shape[1]
            ent = -(pi * torch.log(pi.clamp(min=1e-8))).sum(-1)
            gate = (1.0 - ent / math.log(S)).clamp(0, 1)
            lp = (lp + (cfg.script_prior_lambda * gate)[:, None, None] * rec.script_prior_bias(pi).unsqueeze(1)).log_softmax(-1)
        decoded = greedy_decode_batch(lp, out['time_lengths'], cfg)
        vp = torch.softmax(out['verify_logits'].float(), -1).cpu().numpy()
        pin, spn = pi.cpu().numpy(), sp.cpu().numpy()
        emb = out['embed'].float().cpu().numpy()
        res = [None] * out['script_logits'].shape[0]
        for j, ((text, conf), k) in enumerate(zip(decoded, ridx.tolist())):
            sid = int(pin[j].argmax())
            res[k] = {'text': text, 'rec_conf': conf, 'script': cfg.CANONICAL_SCRIPTS[sid],
                      'script_conf': float(pin[j, sid]), 'script_head': cfg.CANONICAL_SCRIPTS[int(spn[j].argmax())],
                      'verify': vp[k], 'embed': emb[k]}
        return res

    # ---------------- recognition on stitched features ----------------
    @torch.no_grad()
    def recognize(self, feats, rboxes, polys):
        cfg = self.cfg
        rec = self.model.recognizer
        if len(rboxes) == 0:
            return []
        rbp = [pad_rbox(rb, cfg.roi_pad_h, cfg.roi_pad_w) for rb in rboxes]
        masks = [roi_mask_from_polygon(p, rb, cfg.roi_h, cfg.roi_w_long) for p, rb in zip(polys, rbp)]
        feats_d = feats.to(self.device)
        if self.use_amp:
            feats_d = feats_d.half()
        results = []
        for i in range(0, len(rbp), self.REC_CHUNK):
            rb_t = torch.from_numpy(np.stack(rbp[i:i + self.REC_CHUNK])).float().to(self.device)
            m_t = torch.from_numpy(np.stack(masks[i:i + self.REC_CHUNK])).float().to(self.device)
            bidx = torch.zeros(rb_t.shape[0], dtype=torch.long, device=self.device)
            with torch.autocast(device_type=self.device.type, enabled=self.use_amp):
                out = rec(feats_d, bidx, rb_t, m_t)
            results += self._decode(out)
        return results

    @torch.no_grad()
    def read_strips(self, img, rboxes, polys):
        """Rectified-strip re-reading: each (unpadded) oriented box in ORIGINAL image pixels is padded, warped to a
        strip whose text height is roi_h * stride, and read by the same network (dense features of the strip +
        one RoI covering it) - the path trained by the scene-strip stream."""
        cfg = self.cfg
        if len(rboxes) == 0:
            return []
        H, Wm = cfg.roi_h * cfg.feature_stride, cfg.roi_w_long * cfg.feature_stride
        items = []
        for rb, poly in zip(rboxes, polys):
            rbp = pad_rbox(rb, cfg.roi_pad_h, cfg.roi_pad_w)
            canvas, nw, A = rectify_strip(img, rbp, H, Wm)
            poly_s = np.asarray(poly, dtype=np.float32) @ A[:, :2].T.astype(np.float32) + A[:, 2].astype(np.float32)
            rb_s = np.array([nw / 2.0, H / 2.0, float(nw), float(H), 1.0, 0.0], np.float32)
            items.append((canvas, nw, rb_s, roi_mask_from_polygon(poly_s, rb_s, cfg.roi_h, cfg.roi_w_long)))
        results = []
        for i in range(0, len(items), 32):
            chunk = items[i:i + 32]
            wt = max(64, int(math.ceil(max(c[1] for c in chunk) / 32.0) * 32))
            x = torch.from_numpy(np.stack([c[0][:, :wt] for c in chunk])).permute(0, 3, 1, 2).float().div(255.0).to(self.device)
            rb_t = torch.from_numpy(np.stack([c[2] for c in chunk])).to(self.device)
            m_t = torch.from_numpy(np.stack([c[3] for c in chunk])).to(self.device)
            with torch.autocast(device_type=self.device.type, enabled=self.use_amp):
                feats = self.model.forward_dense(x)['enhanced_feats']
                out = self.model.recognizer(feats, torch.arange(len(chunk), device=self.device), rb_t, m_t)
            results += self._decode(out)
        return results

    # ---------------- full image ----------------
    @torch.no_grad()
    def predict(self, img, collect=False):
        """collect=True (calibration): keeps every instance down to min(calib_min_scores) without verifier
        rejection and reads every instance both ways, so thresholds / read policy can be chosen offline."""
        cfg = self.cfg
        self.model.eval()
        scales = list(cfg.test_scales) if cfg.test_scales else [1.0]
        per_scale = []
        for sc in scales:
            canvas, (sx, sy), (nh, nw) = self._prepare(img, sc)
            z, d, f = self.dense(canvas)
            per_scale.append({'sx': sx, 'sy': sy, 'nh': nh, 'nw': nw, 'z': z, 'd': d, 'f': f})
        ref = per_scale[0]
        st = cfg.feature_stride
        hv, wv = int(math.ceil(ref['nh'] / st)), int(math.ceil(ref['nw'] / st))
        z = np.zeros((cfg.num_kernels, hv, wv), dtype=np.float32)
        d = np.zeros((2, hv, wv), dtype=np.float32)
        for ps in per_scale:
            h_s, w_s = int(math.ceil(ps['nh'] / st)), int(math.ceil(ps['nw'] / st))
            z += _resize_chw(ps['z'][:, :h_s, :w_s], (hv, wv))
            d += _resize_chw(ps['d'][:, :h_s, :w_s], (hv, wv))
        z /= len(per_scale)
        d /= len(per_scale)
        u = max(1, int(cfg.pse_upsample))
        z_up = _resize_chw(z, (hv * u, wv * u))
        d_up = _resize_chw(d, (hv * u, wv * u))
        S = _np_corn_marginals(z_up)
        grid_stride = st / float(u)
        floor = min(cfg.calib_min_scores) if collect else None
        insts, labels = extract_instances(S, d_up, grid_stride, cfg, min_score=floor)

        # scale-selective recognition: use the scale whose RoI height (in feature px) is closest to roi_h
        groups = defaultdict(list)
        for i, inst in enumerate(insts):
            best, best_err = 0, 1e9
            for si, ps in enumerate(per_scale):
                hh = inst['rbox'][3] * (ps['sy'] / ref['sy']) / st
                err = abs(math.log(max(hh, 1e-3) / cfg.roi_h))
                if err < best_err:
                    best, best_err = si, err
            groups[best].append(i)
        recs = [None] * len(insts)
        for si, idxs in groups.items():
            ps = per_scale[si]
            rx, ry = ps['sx'] / ref['sx'], ps['sy'] / ref['sy']
            rbs, polys = [], []
            for i in idxs:
                rb = insts[i]['rbox'].copy()
                rb[0] *= rx; rb[1] *= ry; rb[2] *= math.sqrt(rx * ry); rb[3] *= math.sqrt(rx * ry)
                rbs.append(rb)
                polys.append(insts[i]['contour'] * np.array([rx, ry], dtype=np.float32))
            for i, r in zip(idxs, self.recognize(ps['f'], rbs, polys)):
                recs[i] = r

        # strip re-reading from the original pixels
        policy = cfg.read_policy
        inv = np.array([1.0 / ref['sx'], 1.0 / ref['sy']], dtype=np.float32)
        s_bar = math.sqrt(ref['sx'] * ref['sy'])
        need = [i for i, inst in enumerate(insts) if collect or policy in ('strip', 'max') or
                (policy == 'small' and inst['rbox'][3] < cfg.rsr_small_px)]
        strip = {}
        if need:
            rbs, polys = [], []
            for i in need:
                rb = insts[i]['rbox'].copy()
                rb[0] *= inv[0]; rb[1] *= inv[1]; rb[2] /= s_bar; rb[3] /= s_bar
                rbs.append(rb)
                polys.append(insts[i]['contour'] * inv)
            for i, r in zip(need, self.read_strips(img, rbs, polys)):
                strip[i] = r

        dets, rejected = [], []
        for i, (inst, r) in enumerate(zip(insts, recs)):
            if r is None:
                continue
            rs = strip.get(i)
            h_c = float(inst['rbox'][3])
            use_strip = rs is not None and (policy == 'strip' or (policy == 'max' and rs['rec_conf'] > r['rec_conf'])
                                           or (policy == 'small' and h_c < cfg.rsr_small_px))
            rr = rs if use_strip else r
            p_leg, p_ill, p_bg = [float(t) for t in r['verify']]
            det = {'poly': inst['quad'] * inv, 'det_score': inst['score'], 'p_legible': p_leg, 'p_illegible': p_ill,
                   'p_background': p_bg, 'rec_conf': rr['rec_conf'], 'script': rr['script'],
                   'script_conf': rr['script_conf'], 'script_head': r['script_head'], 'dir_conf': inst['dir_conf'],
                   'embed': r['embed'], 'score': inst['score'] * (1.0 - p_bg), 'reading': 'strip' if use_strip else 'dense',
                   'text_dense': r['text'], 'conf_dense': r['rec_conf'], 'h_canvas': h_c,
                   'text_strip': rs['text'] if rs else None, 'conf_strip': rs['rec_conf'] if rs else -1.0}
            legible = p_leg >= p_ill
            if collect:
                det.update({'legible': legible, 'text': rr['text'] if legible else '###', 'e2e': False})
                dets.append(det)
                continue
            if p_bg >= cfg.verify_bg_thresh:
                det.update({'text': '', 'legible': False, 'e2e': False})
                rejected.append(det)
                continue
            det['legible'] = legible
            det['text'] = rr['text'] if legible else '###'
            det['e2e'] = bool(legible and rr['text'] and rr['rec_conf'] >= cfg.e2e_min_rec_conf)
            dets.append(det)
        maps = {'text': S[-1], 'kernel0': S[0], 'direction': d_up, 'labels': labels, 'grid_stride': grid_stride,
                'scale': (ref['sx'], ref['sy'])}
        return dets, rejected, maps


# ==========================================
# 7b. NEW - Operating-point calibration on held-out images (exact re-evaluation of cached raw instances)
# ==========================================
def _eval_cache_for_image(gts, dets, cfg):
    def iou(gl):
        m = np.zeros((len(gl), len(dets)), dtype=np.float32)
        for i, g in enumerate(gl):
            for j, d in enumerate(dets):
                m[i, j] = polygon_iou(g['poly'], d['poly'])
        return m

    def over(gl):
        return np.array([any(polygon_inter_over_first(d['poly'], g['poly']) > 0.5 for g in gl) for d in dets], dtype=bool)
    care = [g for g in gts if not g['ignore']]
    dc = [g for g in gts if g['ignore']]
    e_care = [g for g in gts if not g['ignore'] and e2e_cares(g['text'], cfg.e2e_min_word_len)]
    e_dc = [g for g in gts if g['ignore'] or not e2e_cares(g['text'], cfg.e2e_min_word_len)]
    a = lambda k, dt=np.float32: np.array([d[k] for d in dets], dtype=dt)
    return {'score': a('det_score'), 'p_bg': a('p_background'), 'h': a('h_canvas'),
            'legible': np.array([d['p_legible'] >= d['p_illegible'] for d in dets], dtype=bool),
            'td': [text_for_eval(d['text_dense']) for d in dets], 'cd': a('conf_dense'),
            'td_ne': np.array([bool(d['text_dense']) for d in dets], dtype=bool),
            'ts': [text_for_eval(d['text_strip'] or '') for d in dets], 'cs': a('conf_strip'),
            'ts_ne': np.array([bool(d['text_strip']) for d in dets], dtype=bool),
            'iou_care': iou(care), 'dc_over': over(dc), 'iou_e': iou(e_care), 'edc_over': over(e_dc),
            'e_txt': [text_for_eval(g['text']) for g in e_care], 'n_care': len(care), 'n_e': len(e_care)}


def _fast_eval(caches, min_score, bg, policy, conf_thr, small_px, thr=0.5):
    acc = defaultdict(float)
    for c in caches:
        D = len(c['score'])
        keep = (c['score'] >= min_score) & (c['p_bg'] < bg) if D else np.zeros(0, bool)
        idx = np.nonzero(keep & ~c['dc_over'])[0] if D else np.zeros(0, int)
        tp = len(_greedy_match(c['iou_care'][:, idx], thr)) if (c['n_care'] and len(idx)) else 0
        acc['det_tp'] += tp; acc['det_ngt'] += c['n_care']; acc['det_ndet'] += len(idx)
        if D:
            if policy == 'dense':
                us = np.zeros(D, bool)
            elif policy == 'strip':
                us = c['cs'] >= 0
            elif policy == 'max':
                us = (c['cs'] >= 0) & (c['cs'] > c['cd'])
            else:
                us = (c['cs'] >= 0) & (c['h'] < small_px)
            ne = np.where(us, c['ts_ne'], c['td_ne'])
            conf = np.where(us, c['cs'], c['cd'])
            e2e = keep & c['legible'] & ne & (conf >= conf_thr) & ~c['edc_over']
            idx = np.nonzero(e2e)[0]
        else:
            idx = np.zeros(0, int)
        tp = 0
        if c['n_e'] and len(idx):
            for i, jj in _greedy_match(c['iou_e'][:, idx], thr):
                j = idx[jj]
                tp += int(c['e_txt'][i] == (c['ts'][j] if us[j] else c['td'][j]))
        acc['e2e_tp'] += tp; acc['e2e_ngt'] += c['n_e']; acc['e2e_ndet'] += len(idx)
    return summarize_eval(acc)


def calibrate_operating_point(model, config, items, max_images=None, desc='calibration'):
    """Grid search over (input short side, min_score, verifier threshold, read policy, E2E confidence) on held-out
    images; predictions are made once per short side with permissive thresholds and both readings, then every
    grid point is evaluated exactly (same matching rules as evaluate_image). Sets the winner on `config`."""
    cfg = config
    items = items[:max_images or cfg.calib_max_images]
    if not items:
        return None
    engine = SpottingEngine(model, cfg)
    saved_ss = cfg.infer_short_side
    gts_all = [gt_records(g) for _, g in items]
    rows = []
    best = None
    for ss in cfg.calib_short_sides:
        cfg.infer_short_side = ss
        caches = []
        for (img_path, _), gts in zip(tqdm(items, desc=f'{desc} @{ss}', mininterval=2.0), gts_all):
            img = load_image_rgb(img_path)
            if img is None:
                continue
            dets, _, _ = engine.predict(img, collect=True)
            caches.append(_eval_cache_for_image(gts, dets, cfg))
        for ms in cfg.calib_min_scores:
            for bg in cfg.calib_bg_thresholds:
                for pol in cfg.calib_read_policies:
                    for ct in cfg.calib_e2e_confs:
                        m = _fast_eval(caches, ms, bg, pol, ct, cfg.rsr_small_px)
                        row = {'short_side': ss, 'min_score': ms, 'bg_thresh': bg, 'read_policy': pol,
                               'e2e_min_conf': ct, **{k: m[k] for k in ('det_hmean', 'e2e_hmean', 'spot_score')}}
                        rows.append(row)
                        if best is None or row['spot_score'] > best['spot_score'] + 1e-9:
                            best = row
    cfg.infer_short_side = saved_ss
    if best is None:
        return None
    default = next((r for r in rows if r['short_side'] == saved_ss and abs(r['min_score'] - 0.8) < 1e-9 and
                    abs(r['bg_thresh'] - 0.5) < 1e-9 and r['read_policy'] == 'dense' and r['e2e_min_conf'] == 0.0), None)
    cfg.infer_short_side = best['short_side']
    cfg.min_score = best['min_score']
    cfg.verify_bg_thresh = best['bg_thresh']
    cfg.read_policy = best['read_policy']
    cfg.e2e_min_rec_conf = best['e2e_min_conf']
    rows.sort(key=lambda r: -r['spot_score'])
    report = {'images': len(items), 'best': best, 'v4_default_operating_point': default, 'top10': rows[:10]}
    with open(os.path.join(cfg.reports_dir, 'calibration.json'), 'w') as f:
        json.dump(report, f, indent=2)
    msg = (f"[calibration] {len(items)} images -> short_side={best['short_side']} min_score={best['min_score']} "
           f"bg={best['bg_thresh']} read={best['read_policy']} e2e_conf>={best['e2e_min_conf']}: "
           f"det H {best['det_hmean']:.4f} E2E H {best['e2e_hmean']:.4f} spot {best['spot_score']:.4f}")
    if default:
        msg += f" (V4 operating point: det H {default['det_hmean']:.4f} E2E H {default['e2e_hmean']:.4f})"
    print(msg)
    return best


# ==========================================
# 8. Shared Inference Diagnostics
# ==========================================
class InferenceDiagnostics:
    def __init__(self, config, name='inference'):
        self.config = config
        self.name = name
        self.records = []
        self.all_rec_confs, self.all_det_scores, self.all_scripts, self.all_text_lens = [], [], [], []
        self.all_empty_boxes = 0
        self.all_boxes = 0
        self.all_rejected = 0
        self.all_illegible = 0
        self.strip_readings = 0
        self.e2e_words = 0
        self.script_overrides = 0

    def add_image(self, filename, detections, num_rejected=0):
        rec = {'filename': filename, 'num_detections': len(detections), 'num_rejected_by_verifier': num_rejected,
               'detections': []}
        for d in detections:
            text = d.get('text', '') or ''
            poly = np.asarray(d['poly'], dtype=np.float32).reshape(-1).tolist()
            rec['detections'].append({
                'poly': [round(float(v), 1) for v in poly], 'text': text, 'script': d.get('script', 'Unknown'),
                'det_score': float(d.get('det_score', 0)), 'rec_conf': float(d.get('rec_conf', 0)),
                'p_legible': float(d.get('p_legible', 0)), 'p_illegible': float(d.get('p_illegible', 0)),
                'p_background': float(d.get('p_background', 0)), 'final_score': float(d.get('score', 0)),
                'reading': d.get('reading', 'dense'), 'e2e': bool(d.get('e2e', False))})
            self.all_boxes += 1
            if text == '###':
                self.all_illegible += 1
                continue
            self.strip_readings += int(d.get('reading') == 'strip')
            self.e2e_words += int(bool(d.get('e2e', False)))
            self.script_overrides += int(d.get('script_head', d.get('script')) != d.get('script'))
            self.all_rec_confs.append(float(d.get('rec_conf', 0)))
            self.all_det_scores.append(float(d.get('det_score', 0)))
            self.all_scripts.append(d.get('script', 'Unknown'))
            self.all_text_lens.append(len(text))
            if not text:
                self.all_empty_boxes += 1
        self.all_rejected += num_rejected
        self.records.append(rec)

    def save(self, eval_metrics=None):
        cfg = self.config
        try:
            with open(os.path.join(cfg.logs_dir, f'{self.name}_detections.json'), 'w', encoding='utf-8') as f:
                json.dump(self.records, f, indent=1, ensure_ascii=False)
            with open(os.path.join(cfg.logs_dir, f'{self.name}_detections.csv'), 'w', newline='', encoding='utf-8') as f:
                w = csv.writer(f)
                w.writerow(['filename', 'x1', 'y1', 'x2', 'y2', 'x3', 'y3', 'x4', 'y4', 'text', 'script',
                            'det_score', 'rec_conf', 'p_legible', 'p_illegible', 'p_background', 'final_score',
                            'reading', 'e2e'])
                for rec in self.records:
                    for d in rec['detections']:
                        w.writerow([rec['filename']] + d['poly'][:8] + [d['text'], d['script'], d['det_score'],
                                   d['rec_conf'], d['p_legible'], d['p_illegible'], d['p_background'], d['final_score'],
                                   d['reading'], d['e2e']])
        except Exception as e:
            print(f"[diagnostics] could not write detections: {e}")
        try:
            for vals, title, fname, color in (
                    (self.all_rec_confs, 'Recognition confidence', 'rec_conf_hist.png', '#1f77b4'),
                    (self.all_det_scores, 'Detection (mean text prob.) score', 'det_score_hist.png', '#2ca02c')):
                if vals:
                    plt.figure(figsize=(8, 4.5))
                    plt.hist(vals, bins=30, color=color, edgecolor='black', alpha=0.8)
                    plt.title(f'{self.name} - {title}'); plt.grid(alpha=0.3); plt.tight_layout()
                    plt.savefig(os.path.join(cfg.curves_dir, f'{self.name}_{fname}'), dpi=110); plt.close()
            if self.all_scripts:
                labels, values = zip(*Counter(self.all_scripts).most_common())
                plt.figure(figsize=(8, 4.5))
                plt.bar(range(len(labels)), values, color='#2ca02c', edgecolor='black', alpha=0.85)
                plt.xticks(range(len(labels)), labels, rotation=30, ha='right')
                plt.title(f'{self.name} - predicted script distribution'); plt.tight_layout()
                plt.savefig(os.path.join(cfg.curves_dir, f'{self.name}_script_dist.png'), dpi=110); plt.close()
            if self.all_text_lens:
                plt.figure(figsize=(8, 4.5))
                plt.hist(self.all_text_lens, bins=range(0, max(self.all_text_lens) + 2), color='#ff7f0e', edgecolor='black')
                plt.title(f'{self.name} - decoded text length'); plt.tight_layout()
                plt.savefig(os.path.join(cfg.curves_dir, f'{self.name}_text_len_hist.png'), dpi=110); plt.close()
        except Exception as e:
            print(f"[diagnostics] could not build plots: {e}")
        try:
            n_leg = max(len(self.all_text_lens), 1)
            L = ['=' * 72, f'INFERENCE DIAGNOSTICS - {self.name}', '=' * 72,
                 f'Operating point                   : short side {cfg.infer_short_side}, min_score {cfg.min_score}, '
                 f'verifier bg {cfg.verify_bg_thresh}, read {cfg.read_policy}, E2E conf >= {cfg.e2e_min_rec_conf}',
                 f'Images processed                  : {len(self.records)}',
                 f'Kept detections                   : {self.all_boxes} ({self.all_boxes / max(len(self.records), 1):.2f}/image)',
                 f'  of which illegible ("###")      : {self.all_illegible}',
                 f'Rejected by the text verifier     : {self.all_rejected}',
                 f'Empty legible transcriptions      : {self.all_empty_boxes} ({100.0 * self.all_empty_boxes / n_leg:.1f}% of legible)',
                 f'Readings taken from strip re-read : {self.strip_readings} ({100.0 * self.strip_readings / n_leg:.1f}% of legible)',
                 f'Words written to the E2E output   : {self.e2e_words}',
                 f'Script head overridden by consensus: {self.script_overrides}']
            if self.all_rec_confs:
                L += [f'Recognition confidence mean/median: {np.mean(self.all_rec_confs):.4f} / {np.median(self.all_rec_confs):.4f}',
                      f'Detection score mean              : {np.mean(self.all_det_scores):.4f}',
                      f'Mean / max text length            : {np.mean(self.all_text_lens):.2f} / {int(np.max(self.all_text_lens))}']
            L += ['', 'Script distribution (legible detections):']
            for s, c in Counter(self.all_scripts).most_common():
                L.append(f'  {s:<12}: {c:>6} ({100.0 * c / n_leg:.1f}%)')
            if eval_metrics:
                L += ['', 'ICDAR-style evaluation (IoU>0.5, don\'t-care handled):']
                for k, v in eval_metrics.items():
                    L.append(f'  {k:<18}: {v:.4f}')
            L.append('=' * 72)
            with open(os.path.join(cfg.reports_dir, f'{self.name}_report.txt'), 'w') as f:
                f.write('\n'.join(L))
            print('\n'.join(L))
        except Exception as e:
            print(f"[diagnostics] could not write report: {e}")


# ==========================================
# 8a. Visualisation / explainability helpers
# ==========================================
STATUS_COLORS = {'correct': (0, 200, 0), 'wrong': (255, 215, 0), 'illegible': (255, 140, 0), 'fp': (230, 30, 30),
                 'dc': (150, 150, 150), 'rejected': (170, 60, 230), 'missed': (0, 140, 255), 'legible': (0, 200, 0)}


def match_detections(gts, dets, e2e_min_len=3, iou_thr=0.5):
    """Per-detection status for figures / t-SNE: correct | wrong (matched, wrong text) | illegible (matched, ###)
    | fp | dc (on a don't-care region); plus the missed care GTs."""
    care = [g for g in gts if not g['ignore']]
    dc = [g for g in gts if g['ignore']]
    status = ['fp'] * len(dets)
    for j, d in enumerate(dets):
        if any(polygon_inter_over_first(d['poly'], g['poly']) > 0.5 for g in dc):
            status[j] = 'dc'
    cand = [j for j in range(len(dets)) if status[j] != 'dc']
    iou = np.zeros((len(care), len(cand)), dtype=np.float32)
    for i, g in enumerate(care):
        for jj, j in enumerate(cand):
            iou[i, jj] = polygon_iou(g['poly'], dets[j]['poly'])
    pairs = _greedy_match(iou, iou_thr) if care and cand else []
    matched = set()
    for i, jj in pairs:
        j = cand[jj]
        matched.add(i)
        d = dets[j]
        if not d.get('legible', True) or d.get('text') in ('', '###'):
            status[j] = 'illegible'
        else:
            status[j] = 'correct' if text_for_eval(d['text']) == text_for_eval(care[i]['text']) else 'wrong'
    return status, [g for i, g in enumerate(care) if i not in matched]


def _ascii_label(t):
    return ''.join(c if 32 <= ord(c) < 127 else '?' for c in t)


def draw_detections(img, dets, rejected=None, gts=None):
    out = img.copy()
    h, w = out.shape[:2]
    fs = float(np.clip(w / 1600.0, 0.4, 1.4))
    th = max(1, int(round(fs * 2)))
    status = missed = None
    if gts is not None:
        status, missed = match_detections(gts, dets)
        for g in missed:
            cv2.polylines(out, [np.round(g['poly']).astype(np.int32)], True, STATUS_COLORS['missed'], th)
    for d in (rejected or []):
        cv2.polylines(out, [np.round(d['poly']).astype(np.int32)], True, STATUS_COLORS['rejected'], 1)
    for j, d in enumerate(dets):
        if status is not None:
            col = STATUS_COLORS[status[j]]
        else:
            col = STATUS_COLORS['legible'] if d.get('legible', True) else STATUS_COLORS['illegible']
        q = np.round(d['poly']).astype(np.int32)
        cv2.polylines(out, [q], True, col, th + 1)
        cv2.circle(out, tuple(int(v) for v in q[0]), th + 2, (255, 255, 0), -1)      # reading start (p0)
        label = _ascii_label(f"{d.get('text', '')}")
        if not label:
            continue
        (tw, tht), base = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, fs, th)
        x, y = int(q[:, 0].min()), int(q[:, 1].min()) - 4
        y = max(y, tht + 4)
        cv2.rectangle(out, (x, y - tht - 4), (x + tw + 4, y + base), (0, 0, 0), -1)
        cv2.putText(out, label, (x + 2, y - 2), cv2.FONT_HERSHEY_SIMPLEX, fs, col, th, cv2.LINE_AA)
    return out


def direction_to_rgb(direction, strength):
    ang = (np.arctan2(direction[1], direction[0]) + np.pi) / (2 * np.pi)
    hsv = np.stack([ang * 179, np.full_like(ang, 255), np.clip(strength, 0, 1) * 255], -1).astype(np.uint8)
    return cv2.cvtColor(hsv, cv2.COLOR_HSV2RGB)


def save_prediction_figure(img, dets, rejected, maps, path, title, gts=None):
    """Aspect-correct 4-panel figure (V4 used a fixed 22x5.5in canvas: ~half of every 16:9 figure was white).
    With GT: green = correct text, yellow = wrong text, orange = '###', red = false positive, grey = on a
    don't-care region, blue = missed GT, purple = rejected by the verifier."""
    h, w = img.shape[:2]
    pw = 5.5
    fig, axs = plt.subplots(1, 4, figsize=(4 * pw, pw * h / float(w) + 0.6))
    if gts is not None:
        legend = 'green=correct  yellow=wrong text  orange=###  red=FP  grey=dont-care  blue=missed  purple=rejected'
    else:
        legend = 'green=legible  orange=###  purple=rejected'
    axs[0].imshow(draw_detections(img, dets, rejected, gts)); axs[0].set_title(title, fontsize=10)
    axs[1].imshow(maps['text'], cmap='gray', vmin=0, vmax=1); axs[1].set_title('Text probability S_{K-1}', fontsize=10)
    axs[2].imshow(maps['kernel0'], cmap='magma', vmin=0, vmax=1); axs[2].set_title('Smallest kernel S_0', fontsize=10)
    axs[3].imshow(direction_to_rgb(maps['direction'], maps['text'])); axs[3].set_title('Reading direction (hue=angle)', fontsize=10)
    for ax in axs:
        ax.axis('off')
    fig.suptitle(legend, fontsize=9, y=0.02, va='bottom')
    plt.subplots_adjust(left=0.005, right=0.995, top=0.92, bottom=0.06, wspace=0.02)
    plt.savefig(path, dpi=100, bbox_inches='tight', pad_inches=0.05)
    plt.close()


def _shap_worker_fn(model, imgs, interp_dir):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt_local
        model = model.to('cpu').eval()

        class MaskScoreWrapper(nn.Module):
            def __init__(self, inner):
                super().__init__()
                self.inner = inner

            def forward(self, x):
                return self.inner.forward_dense(x)['detection_masks'][:, -1].flatten(1).mean(dim=1, keepdim=True)

        explainer = shap.GradientExplainer(MaskScoreWrapper(model), imgs[:1].float())
        sv = explainer.shap_values(imgs[1:2].float())
        sv = sv[0] if isinstance(sv, list) else sv
        sv = np.asarray(sv).reshape(1, 3, imgs.shape[2], imgs.shape[3]).transpose(0, 2, 3, 1)
        shap.image_plot([sv], imgs[1:2].cpu().numpy().transpose(0, 2, 3, 1), show=False)
        plt_local.savefig(os.path.join(interp_dir, 'shap_analysis_test.png'))
        plt_local.close()
    except Exception:
        pass


class Inferencer:
    """Runs the SpottingEngine over a folder, writes ICDAR submission files, figures, diagnostics and,
    when GT is available, ICDAR-style metrics. `TiledInferencer` is the same engine (tiling is automatic)."""
    diag_name = 'inference'

    def __init__(self, model, config, img_dir=None, gt_dir=None, max_figures=50, explain=True):
        self.model = model
        self.config = config
        self.img_dir = img_dir or config.test_img_dir
        self.gt_dir = gt_dir if gt_dir is not None else config.test_gt_dir
        self.engine = SpottingEngine(model, config)
        self.diag = InferenceDiagnostics(config, name=self.diag_name)
        self.max_figures = max_figures
        self.explain = explain

    def interpret_tsne(self, embeds, scripts, outcomes=None):
        """t-SNE of RoI embeddings coloured by consensus script and (with GT) by E2E outcome. On IC15 the script
        colouring is ~all Latin, so the outcome view is the informative one (where do the wrong reads live?)."""
        if not HAS_TSNE or len(embeds) < 5:
            return
        try:
            X = np.stack(embeds)[:2000]
            sc = scripts[:2000]
            res = TSNE(n_components=2, perplexity=min(30, max(2, len(X) // 4)), random_state=42).fit_transform(X)
            views = [('predicted script (consensus)', sc)]
            if outcomes:
                views.append(('E2E outcome vs GT', outcomes[:2000]))
            fig, axs = plt.subplots(1, len(views), figsize=(8 * len(views), 6.5))
            axs = np.atleast_1d(axs)
            for ax, (name, lab) in zip(axs, views):
                for s in sorted(set(lab)):
                    idx = [i for i, t in enumerate(lab) if t == s]
                    ax.scatter(res[idx, 0], res[idx, 1], s=6, alpha=0.7, label=f'{s} ({len(idx)})')
                ax.legend(markerscale=3, fontsize=8)
                ax.set_title(f't-SNE of RoI embeddings - {name}')
            plt.tight_layout()
            plt.savefig(os.path.join(self.config.interp_dir, f'tsne_roi_embeddings_{self.diag_name}.png'), dpi=110)
            plt.close()
        except Exception as e:
            print(f"[interpret] t-SNE failed: {e}")

    def interpret_attention(self, img, tag=''):
        try:
            blk = self.model.backbone.blocks[0].attn
            if blk.attention_map is None:
                return
            a = blk.attention_map[0].float().cpu().numpy()
            a = (a - a.min()) / (a.max() - a.min() + 1e-6)
            fig, axs = plt.subplots(1, 2, figsize=(12, 5))
            axs[0].imshow(img); axs[0].axis('off')
            axs[1].imshow(cv2.resize(a, (img.shape[1], img.shape[0])), cmap='viridis'); axs[1].axis('off')
            axs[1].set_title('SGDLA focus (q . mean k), block 0')
            plt.tight_layout()
            plt.savefig(os.path.join(self.config.attn_dir, f'attention_glimpse_{tag}.png'), dpi=90)
            plt.close()
        except Exception as e:
            print(f"[interpret] attention glimpse failed: {e}")

    def interpret_shap(self, img, timeout_s=60):
        if not HAS_SHAP:
            return
        try:
            c = 256
            x = cv2.resize(img, (c, c)).astype(np.float32) / 255.0
            t = torch.from_numpy(x).permute(2, 0, 1).unsqueeze(0)
            imgs = torch.cat([torch.zeros_like(t), t], 0)
            proc = mp.get_context('fork').Process(target=_shap_worker_fn,
                                                  args=(copy.deepcopy(self.model).cpu(), imgs, self.config.interp_dir),
                                                  daemon=True)
            proc.start()
            proc.join(timeout_s)
            if proc.is_alive():
                proc.terminate()
                print(f"[interpret_shap] did not finish within {timeout_s}s - skipped.")
        except Exception as e:
            print(f"[interpret_shap] skipped ({e})")

    def run(self):
        cfg = self.config
        paths = list_images(self.img_dir)
        if not paths:
            print(f"No test images found in {self.img_dir}.")
            return None
        acc = defaultdict(float)
        has_gt = self.gt_dir is not None and os.path.isdir(self.gt_dir)
        embeds, emb_scripts, emb_outcomes = [], [], []
        det_dir = os.path.join(cfg.submit_dir, self.diag_name, 'task1_localization')
        e2e_dir = os.path.join(cfg.submit_dir, self.diag_name, 'task4_end_to_end')
        os.makedirs(det_dir, exist_ok=True)
        os.makedirs(e2e_dir, exist_ok=True)
        for n, p in enumerate(tqdm(paths, desc=f"{self.diag_name}", mininterval=2.0)):
            img = load_image_rgb(p)
            if img is None:
                continue
            fname = os.path.basename(p)
            stem = os.path.splitext(fname)[0]
            dets, rejected, maps = self.engine.predict(img)
            self.diag.add_image(fname, dets, len(rejected))
            # ICDAR submission files: Task 4.1 = 8 clockwise coordinates; Task 4.4 = coordinates + transcription
            with open(os.path.join(det_dir, f'res_{stem}.txt'), 'w', encoding='utf-8') as fd, \
                    open(os.path.join(e2e_dir, f'res_{stem}.txt'), 'w', encoding='utf-8') as fe:
                for d in dets:
                    q = ','.join(str(v) for v in np.round(d['poly']).astype(int).reshape(-1)[:8])
                    fd.write(q + '\n')
                    if d.get('e2e'):
                        fe.write(q + ',' + d['text'] + '\n')
                    elif not cfg.drop_illegible_from_e2e and not d.get('legible'):
                        fe.write(q + ',###\n')
            gts = gt_records(find_gt_file(self.gt_dir, p)) if has_gt else None
            status = match_detections(gts, dets, cfg.e2e_min_word_len)[0] if gts is not None else None
            for j, d in enumerate(dets):
                if d.get('legible') and len(embeds) < 5000:
                    embeds.append(d['embed']); emb_scripts.append(d['script'])
                    if status is not None:
                        emb_outcomes.append(status[j])
            if gts is not None:
                for k, v in evaluate_image(gts, dets, cfg.e2e_min_word_len).items():
                    acc[k] += v
            if n < self.max_figures:
                save_prediction_figure(img, dets, rejected, maps, os.path.join(cfg.vis_dir, f'{self.diag_name}_{fname}.png'),
                                       fname, gts)
                if self.explain:
                    self.interpret_attention(img, tag=f'{n:04d}')
            if n == 0 and self.explain:
                self.interpret_shap(img)
        metrics = summarize_eval(acc) if has_gt else None
        if self.explain:
            self.interpret_tsne(embeds, emb_scripts, emb_outcomes if len(emb_outcomes) == len(embeds) else None)
        self.diag.save(metrics)
        if metrics:
            with open(os.path.join(cfg.reports_dir, f'{self.diag_name}_metrics.json'), 'w') as f:
                json.dump(metrics, f, indent=2)
        return metrics


class TiledInferencer(Inferencer):
    diag_name = 'tiled_inference'

    def __init__(self, model, config, **kw):
        super().__init__(model, config, **kw)


def evaluate_spotting(engine, items, config, max_images=None, desc='Eval'):
    """Instance-level evaluation on (img_path, gt_path) items. Returns summary metrics (+ per-script recall)."""
    acc = defaultdict(float)
    items = items[:max_images] if max_images else items
    n_det = 0
    for img_path, gt_path in tqdm(items, desc=desc, mininterval=2.0):
        img = load_image_rgb(img_path)
        if img is None:
            continue
        dets, _, _ = engine.predict(img)
        n_det += len(dets)
        for k, v in evaluate_image(gt_records(gt_path), dets, config.e2e_min_word_len).items():
            acc[k] += v
    m = summarize_eval(acc)
    m['dets_per_image'] = n_det / max(len(items), 1)
    return m


# ==========================================
# 9. Training Engine
# ==========================================
def _native_bf16():
    """True only for GPUs with native bf16 (Ampere+). T4 / P100 report emulated bf16 support in recent
    PyTorch versions, which is much slower than fp16 + GradScaler."""
    try:
        return bool(torch.cuda.is_bf16_supported(including_emulation=False))
    except TypeError:
        return torch.cuda.get_device_capability()[0] >= 8


class ModelEMA:
    """Exponential moving average of weights (used for validation, model selection and inference)."""

    def __init__(self, model, decay=0.9995):
        self.ema = copy.deepcopy(model).eval()
        for p in self.ema.parameters():
            p.requires_grad_(False)
        self.decay = decay
        self.updates = 0

    @torch.no_grad()
    def update(self, model):
        self.updates += 1
        d = min(self.decay, (1.0 + self.updates) / (10.0 + self.updates))
        msd = model.state_dict()
        for k, v in self.ema.state_dict().items():
            src = msd[k].detach()
            if v.dtype.is_floating_point:
                v.mul_(d).add_(src.to(v.dtype), alpha=1.0 - d)
            else:
                v.copy_(src)


def mine_hard_negatives(text_probs, gt_any, stride, n_per_img, min_area=3, max_overlap=0.2, allow=None):
    """Self-mined false positives: connected components of the *current* predicted text map that do
    not overlap any GT text / don't-care region. Returns [(batch_index, rbox, quad)].
    `allow[b] = False` skips images of incompletely annotated sources (their 'false positives' may be text)."""
    out = []
    if n_per_img <= 0:
        return out
    for b in range(text_probs.shape[0]):
        if allow is not None and not allow[b]:
            continue
        pb = text_probs[b]
        num, lab, stats, _ = cv2.connectedComponentsWithStats((pb > 0.5).astype(np.uint8), connectivity=4)
        cands = []
        for i in range(1, num):
            x, y, w, h, area = stats[i]
            if area < min_area:
                continue
            sub = lab[y:y + h, x:x + w] == i
            if gt_any[b][y:y + h, x:x + w][sub].mean() > max_overlap:
                continue
            ys, xs = np.nonzero(sub)
            pts = (np.stack([xs + x, ys + y], 1).astype(np.float32) + 0.5) * stride
            bp = cv2.boxPoints(cv2.minAreaRect(pts if len(pts) >= 3 else np.concatenate([pts, pts + 1])))
            e1, e2 = bp[1] - bp[0], bp[2] - bp[1]
            u = _unit(e1 if np.hypot(*e1) >= np.hypot(*e2) else e2)
            if u[0] < 0:
                u = -u
            rb = rbox_from_points(pts, u)
            rb[2] += stride
            rb[3] += stride
            cands.append((float(pb[y:y + h, x:x + w][sub].mean()) * area, rb))
        cands.sort(key=lambda t: -t[0])
        for _, rb in cands[:n_per_img]:
            out.append((b, rb, rbox_to_quad(rb)))
    return out


def _ckpt_stage(ck):
    if 'stage' in ck:
        return ck['stage']
    snap = ck.get('config_snapshot')
    if snap is None:
        return 'v3'
    return snap.get('stage_name', 'v4')


def find_warm_start_checkpoint(cfg):
    """Explicit init_checkpoint, else best/latest of a previous stage in chkp_dir, else a best_model.pth found in an
    attached Kaggle dataset (e.g. the outputs of the V4 notebook). Returns (path, config_snapshot, stage)."""
    cands = [cfg.init_checkpoint] if cfg.init_checkpoint else []
    cands += [os.path.join(cfg.chkp_dir, 'best_model.pth'), os.path.join(cfg.chkp_dir, 'latest_model.pth')]
    for root in cfg.source_search_roots:
        if root and root.startswith('/kaggle/input') and os.path.isdir(root):
            rdepth = root.rstrip(os.sep).count(os.sep)
            found = []
            for dp, dn, fn in os.walk(root):
                if dp.count(os.sep) - rdepth >= 5:
                    dn[:] = []
                for f in ('best_model.pth', 'latest_model.pth'):
                    if f in fn:
                        found.append(os.path.join(dp, f))
            cands += sorted(found, key=lambda p: (not p.endswith('best_model.pth'), p))
    for p in cands:
        if not p or not os.path.exists(p):
            continue
        try:
            ck = torch.load(p, map_location='cpu', weights_only=False)
        except Exception as e:
            print(f"[stage] cannot read {p}: {e}")
            continue
        snap, stage = ck.get('config_snapshot'), _ckpt_stage(ck)
        del ck
        if snap is not None and stage != cfg.stage_name:
            return p, snap, stage
    return None, None, None


def plan_stage(cfg):
    """'resume' (latest checkpoint belongs to this stage) | 'warm' (start this stage from a previous stage's
    weights) | 'scratch'."""
    latest = os.path.join(cfg.chkp_dir, 'latest_model.pth')
    if os.path.exists(latest):
        ck = torch.load(latest, map_location='cpu', weights_only=False)
        stage, snap = _ckpt_stage(ck), ck.get('config_snapshot')
        del ck
        if stage == cfg.stage_name and snap is not None:
            return {'mode': 'resume', 'path': latest, 'snapshot': snap}
    path, snap, stage = find_warm_start_checkpoint(cfg)
    if path:
        print(f"[stage] new stage '{cfg.stage_name}': warm start from {path} (stage '{stage}', "
              f"{len(snap.get('chars') or [])}-symbol vocabulary)")
        return {'mode': 'warm', 'path': path, 'snapshot': snap, 'old_chars': snap.get('chars'),
                'old_components': snap.get('components'), 'old_stage': stage}
    return {'mode': 'scratch'}


class Trainer:
    TRACK = [s.lower() for s in TRACKED_SCRIPTS]
    HIST_KEYS = ['train_total', 'train_det', 'train_text', 'train_kernel', 'train_dir', 'train_rec', 'train_ctc',
                 'train_script_consistency', 'train_script', 'train_verify', 'train_family', 'train_crop_ctc',
                 'val_total', 'val_det', 'val_text', 'val_kernel', 'val_dir', 'val_rec', 'val_ctc',
                 'val_script_consistency', 'val_script', 'val_verify', 'val_family', 'val_crop_ctc',
                 'pix_precision', 'pix_recall', 'pix_f', 'rec_acc', 'rec_1ned', 'script_acc', 'verify_acc',
                 'lr', 'grad_norm', 'clip_frac', 'mined_per_batch', 'w_det', 'w_dir', 'w_rec', 'w_script', 'w_verify',
                 'det_precision', 'det_recall', 'det_hmean', 'e2e_precision', 'e2e_recall', 'e2e_hmean',
                 'one_minus_ned', 'spot_score', 'dets_per_image', 'ic15_det_hmean', 'ic15_e2e_hmean',
                 'ic15_spot_score', 'sel_score'] + \
                ['rec_1ned_' + s for s in TRACK] + ['e2e_recall_' + s for s in TRACK] + ['mix_beta_' + s for s in TRACK]
    EVAL_KEYS = ['det_precision', 'det_recall', 'det_hmean', 'e2e_precision', 'e2e_recall', 'e2e_hmean',
                 'one_minus_ned', 'spot_score', 'dets_per_image']

    def __init__(self, model, train_loader, val_loader, config, train_loader_factory=None, val_items=None,
                 crop_loader=None, domain_val_items=None, crop_loaders=None, mixers=None, plan=None):
        self.model = model
        self.train_loader = train_loader
        self.val_loader = val_loader
        self.config = config
        self.train_loader_factory = train_loader_factory
        self.val_items = val_items or []
        self.domain_val_items = domain_val_items or []
        # auxiliary recognition streams, used round-robin: (loader, weight, name)
        self.crop_streams = []
        for item in (crop_loaders or []):
            if item is not None:
                self.crop_streams.append(item if isinstance(item, tuple) else (item, config.w_crop_rec, 'crop'))
        if crop_loader is not None:
            self.crop_streams.append((crop_loader, config.w_crop_rec, 'crop'))
        self._crop_iters = [None] * len(self.crop_streams)
        self._crop_turn = 0
        self.mixers = [m for m in (mixers or []) if m is not None]
        self.mixer_beta = np.ones(config.num_scripts, dtype=np.float64)
        self.device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
        self.model.to(self.device)
        self.criterion = UnifiedSpotterLoss(config).to(self.device)
        self.plan = plan or plan_stage(config)
        self.steps_per_epoch = max(len(train_loader), 1)
        self._set_schedule()

        backbone_ids = {id(p) for p in self.model.backbone.stages.parameters()}
        groups = {'bb_decay': [], 'bb_no_decay': [], 'decay': [], 'no_decay': []}
        for n, p in self.model.named_parameters():
            if not p.requires_grad:
                continue
            no_decay = p.ndim <= 1 or n.endswith('.bias') or 'filter_' in n or 'gamma' in n or 'comp_embed' in n
            key = ('bb_' if id(p) in backbone_ids else '') + ('no_decay' if no_decay else 'decay')
            groups[key].append(p)
        pretrained = self.model.backbone.pretrained_loaded or self.plan['mode'] != 'scratch'
        bb_lr = self.peak_lr * (config.backbone_lr_mult if pretrained else 1.0)
        pg = [{'params': groups['bb_decay'], 'weight_decay': config.weight_decay, 'base_lr': bb_lr},
              {'params': groups['bb_no_decay'], 'weight_decay': 0.0, 'base_lr': bb_lr},
              {'params': groups['decay'], 'weight_decay': config.weight_decay, 'base_lr': self.peak_lr},
              {'params': groups['no_decay'], 'weight_decay': 0.0, 'base_lr': self.peak_lr},
              {'params': list(self.criterion.parameters()), 'weight_decay': 0.0, 'base_lr': self.peak_lr}]
        pg = [g for g in pg if len(g['params']) > 0]
        for g in pg:
            g['lr'] = g['base_lr']
        self.optimizer = torch.optim.AdamW(pg, lr=self.peak_lr)

        cuda = self.device.type == 'cuda'
        self.use_amp = cuda and config.use_amp
        self.amp_dtype = torch.bfloat16 if (cuda and _native_bf16()) else torch.float16
        self.scaler = torch.amp.GradScaler('cuda', enabled=self.use_amp and self.amp_dtype == torch.float16)
        self.ema = ModelEMA(self.model, config.ema_decay)

        self.global_step = 0
        self.start_epoch = 0
        self.history = {k: [] for k in self.HIST_KEYS}
        self.best_score = -1e9
        self.best_epoch = 0
        self.evals_without_improvement = 0
        self._epoch_log_path = os.path.join(config.logs_dir, 'train_epoch_log.csv')
        self.load_checkpoint()

    # ------------------------------ schedule ------------------------------
    def _set_schedule(self, saved=None):
        cfg = self.config
        if saved:
            self.peak_lr, self.total_epochs, self.warmup_epochs = saved['peak_lr'], saved['total_epochs'], saved['warmup_epochs']
        elif self.plan['mode'] == 'scratch':
            self.peak_lr, self.total_epochs, self.warmup_epochs = cfg.lr, cfg.epochs, cfg.warmup_epochs
        else:
            self.peak_lr, self.total_epochs, self.warmup_epochs = cfg.finetune_lr, cfg.finetune_epochs, cfg.finetune_warmup_epochs

    def lr_factor(self, step):
        """Step-based linear warm-up + cosine decay to min_lr, a pure function of (step, schedule): resuming
        never distorts it."""
        total = max(self.total_epochs * self.steps_per_epoch, 1)
        warm = max(self.warmup_epochs * self.steps_per_epoch, 1)
        floor = self.config.min_lr / self.peak_lr
        if step < warm:
            return max((step + 1) / warm, floor)
        prog = min(max((step - warm) / max(total - warm, 1), 0.0), 1.0)
        return floor + (1 - floor) * 0.5 * (1 + math.cos(math.pi * prog))

    def _set_lr(self):
        f = self.lr_factor(self.global_step)
        for g in self.optimizer.param_groups:
            g['lr'] = g['base_lr'] * f
        return self.peak_lr * f

    # ------------------------------ helpers ------------------------------
    def _to_device(self, batch):
        return {k: (v.to(self.device, non_blocking=True) if torch.is_tensor(v) else v) for k, v in batch.items()}

    def _rec_mask(self, tgt, train=True):
        """RoIs that go through the sequence model. Training caps them (memory with an 8,000-class output);
        validation keeps all of them so the per-script metrics that drive the mixers are not a random subsample."""
        rv = tgt['rec_valid']
        cap = self.config.max_rec_rois_per_batch if train else 0
        if cap and int(rv.sum()) > cap:
            idx = rv.nonzero(as_tuple=True)[0]
            keep = idx[torch.randperm(idx.numel(), device=idx.device)[:cap]]
            rv = torch.zeros_like(rv)
            rv[keep] = True
        return rv

    def _roi_targets_with_mining(self, batch, dense, mine):
        cfg = self.config
        tgt = {k: batch[k] for k in ('masks', 'training_mask', 'direction', 'direction_weight', 'batch_idx',
                                     'rboxes', 'roi_masks', 'text_seq', 'text_len', 'script_id', 'rec_valid', 'verify',
                                     'family_target')}
        n_mined = 0
        if mine and cfg.mined_neg_per_img > 0:
            probs = dense['detection_masks'][:, -1].detach().float().cpu().numpy()
            allow = batch['complete'].cpu().numpy() if 'complete' in batch else None
            mined = mine_hard_negatives(probs, batch['gt_any'].cpu().numpy(), cfg.feature_stride, cfg.mined_neg_per_img,
                                        allow=allow)
            n_mined = len(mined)
            if mined:
                rbp = [pad_rbox(rb, cfg.roi_pad_h, cfg.roi_pad_w) for _, rb, _ in mined]
                dev = self.device
                tgt['batch_idx'] = torch.cat([tgt['batch_idx'], torch.tensor([b for b, _, _ in mined], device=dev)])
                tgt['rboxes'] = torch.cat([tgt['rboxes'], torch.from_numpy(np.stack(rbp)).float().to(dev)])
                tgt['roi_masks'] = torch.cat([tgt['roi_masks'], torch.from_numpy(np.stack(
                    [roi_mask_from_polygon(q, r, cfg.roi_h, cfg.roi_w_long) for (_, _, q), r in zip(mined, rbp)])).float().to(dev)])
                tgt['text_seq'] = torch.cat([tgt['text_seq'], torch.zeros((n_mined, cfg.max_seq_len), dtype=torch.long, device=dev)])
                tgt['text_len'] = torch.cat([tgt['text_len'], torch.zeros(n_mined, dtype=torch.long, device=dev)])
                tgt['script_id'] = torch.cat([tgt['script_id'], torch.full((n_mined,), -100, dtype=torch.long, device=dev)])
                tgt['rec_valid'] = torch.cat([tgt['rec_valid'], torch.zeros(n_mined, dtype=torch.bool, device=dev)])
                tgt['verify'] = torch.cat([tgt['verify'], torch.full((n_mined,), 2, dtype=torch.long, device=dev)])
                tgt['family_target'] = torch.cat([tgt['family_target'], torch.zeros((n_mined, 4), device=dev)])
        return tgt, n_mined

    def _next_crop_batch(self, i):
        loader = self.crop_streams[i][0]
        for _ in range(3):
            try:
                if self._crop_iters[i] is None:
                    self._crop_iters[i] = iter(loader)
                b = next(self._crop_iters[i])
            except StopIteration:
                self._crop_iters[i] = iter(loader)
                continue
            if b is not None:
                return b
        return None

    def _crop_step(self, model):
        if not self.crop_streams:
            return None, {}
        i = self._crop_turn % len(self.crop_streams)
        self._crop_turn += 1
        _, weight, name = self.crop_streams[i]
        raw = self._next_crop_batch(i)
        if raw is None or weight <= 0:
            return None, {}
        cb = self._to_device(raw)
        # Word strips are a different image domain (32-px-high strips): run them with BatchNorm in eval mode so
        # they neither use nor overwrite the full-image running statistics that detection / inference rely on.
        bns = [m for m in model.modules() if isinstance(m, nn.modules.batchnorm._BatchNorm) and m.training]
        for m in bns:
            m.eval()
        try:
            with torch.autocast(device_type=self.device.type, dtype=self.amp_dtype, enabled=self.use_amp):
                dense = model.forward_dense(cb['image'])
                rois = model.forward_rois(dense['enhanced_feats'], cb['batch_idx'], cb['rboxes'], cb['roi_masks'],
                                          rec_mask=self._rec_mask(cb))
                loss, logs = crop_recognition_loss(rois, cb, model.recognizer, self.config)
        finally:
            for m in bns:
                m.train()
        if name != 'crop':
            logs = {k.replace('crop_', name + '_'): v for k, v in logs.items()}
            logs['crop_ctc'] = logs.get(name + '_ctc', float('nan'))
        return weight * loss, logs

    def _step_forward(self, model, batch, mine):
        with torch.autocast(device_type=self.device.type, dtype=self.amp_dtype, enabled=self.use_amp):
            dense = model.forward_dense(batch['image'])
        tgt, n_mined = self._roi_targets_with_mining(batch, dense, mine)
        with torch.autocast(device_type=self.device.type, dtype=self.amp_dtype, enabled=self.use_amp):
            rois = None
            if tgt['rboxes'].shape[0] > 0:
                rois = model.forward_rois(dense['enhanced_feats'], tgt['batch_idx'], tgt['rboxes'], tgt['roi_masks'],
                                          rec_mask=self._rec_mask(tgt, train=mine))
            loss, logs = self.criterion(dense, rois, tgt, model.recognizer)
        return dense, rois, tgt, loss, logs, n_mined

    # ------------------------------ training loop ------------------------------
    def train_one_epoch(self, epoch):
        self.model.train()
        sums, cnts, n_batches, gn_sum, mined_sum, clipped = defaultdict(float), defaultdict(int), 0, 0.0, 0, 0
        loop = tqdm(self.train_loader, desc=f"Epoch {epoch + 1}/{self.total_epochs} [Train]", mininterval=2.0)
        for raw in loop:
            batch = self._to_device(raw)
            lr = self._set_lr()
            self.optimizer.zero_grad(set_to_none=True)
            _, _, _, loss, logs, n_mined = self._step_forward(self.model, batch, mine=True)
            c_loss, c_logs = self._crop_step(self.model)
            if c_loss is not None and torch.isfinite(c_loss):
                loss = loss + c_loss
                logs.update(c_logs)
            if not torch.isfinite(loss):
                self.optimizer.zero_grad(set_to_none=True)
                continue
            self.scaler.scale(loss).backward()
            self.scaler.unscale_(self.optimizer)
            gn = torch.nn.utils.clip_grad_norm_(list(self.model.parameters()) + list(self.criterion.parameters()),
                                                max_norm=self.config.grad_clip)
            self.scaler.step(self.optimizer)
            self.scaler.update()
            self.ema.update(self.model)
            self.global_step += 1
            for k, v in logs.items():
                if v == v:                                     # skip NaN placeholders
                    sums[k] += v
                    cnts[k] += 1
            gnf = float(gn) if torch.isfinite(gn) else 0.0
            gn_sum += gnf
            clipped += int(gnf > self.config.grad_clip)
            mined_sum += n_mined
            n_batches += 1
            loop.set_postfix(L=f"{logs['total']:.3f}", det=f"{logs.get('det', 0):.3f}", ctc=f"{logs.get('ctc', 0):.3f}",
                             strip=f"{logs.get('strip_ctc', 0):.3f}", ver=f"{logs.get('verify', 0):.3f}", lr=f"{lr:.2e}")
        n = max(n_batches, 1)
        return {k: v / max(cnts[k], 1) for k, v in sums.items()}, gn_sum / n, mined_sum / n, clipped / n

    @torch.no_grad()
    def validate(self, epoch):
        model = self.ema.ema
        model.eval()
        sums, n = defaultdict(float), 0
        pix = [0.0, 0.0, 0.0]
        rm = defaultdict(float)
        for raw in tqdm(self.val_loader, desc=f"Epoch {epoch + 1} [Valid]", mininterval=2.0):
            batch = self._to_device(raw)
            dense, rois, tgt, loss, logs, _ = self._step_forward(model, batch, mine=False)
            for k, v in logs.items():
                sums[k] += v
            n += 1
            i, p, g = compute_metrics(dense['detection_masks'], batch['masks'], batch['training_mask'])
            pix[0] += i; pix[1] += p; pix[2] += g
            if rois is not None:
                for k, v in compute_recognition_metrics(rois, tgt, self.config).items():
                    rm[k] += v
        n = max(n, 1)
        out = {k: v / n for k, v in sums.items()}
        pp = pix[0] / max(pix[1], 1e-6)
        pr = pix[0] / max(pix[2], 1e-6)
        out.update({'pix_precision': pp, 'pix_recall': pr, 'pix_f': 2 * pp * pr / max(pp + pr, 1e-6),
                    'rec_acc': rm['rec_correct'] / max(rm['rec_total'], 1),
                    'rec_1ned': 1.0 - rm['ned_sum'] / max(rm['rec_total'], 1),
                    'script_acc': rm['script_correct'] / max(rm['script_total'], 1),
                    'verify_acc': rm['verify_correct'] / max(rm['verify_total'], 1)})
        per_script = {}
        for sid, name in enumerate(self.config.CANONICAL_SCRIPTS):
            cnt = rm.get(f'ps_n@{sid}', 0)
            if cnt:
                per_script[name] = (1.0 - rm[f'ps_ned@{sid}'] / cnt, int(cnt), rm[f'ps_correct@{sid}'] / cnt)
        out['per_script'] = per_script
        return out

    def _update_mixers(self, per_script):
        cfg = self.config
        if not self.mixers or not cfg.adaptive_mixing:
            return
        errs = {}
        for name, (one_ned, cnt, _) in per_script.items():
            if cnt >= cfg.mixing_min_support and name not in ('None', 'Unknown', 'Mixed', 'Symbols'):
                errs[cfg.script2id[name.lower()]] = 1.0 - one_ned
        if len(errs) < 2:
            return
        mean_e = float(np.mean(list(errs.values())))
        lo, hi = cfg.mixing_beta_range
        b = self.mixer_beta
        for sid, e in errs.items():
            b[sid] = float(np.clip(b[sid] * math.exp(cfg.mixing_eta * (e - mean_e)), lo, hi))
        ids = list(errs.keys())
        b[ids] = np.clip(b[ids] / max(np.mean(b[ids]), 1e-6), lo, hi)
        for m in self.mixers:
            m.set_script_multipliers(b)

    def evaluate_instances(self):
        out = {}
        if self.val_items:
            engine = SpottingEngine(self.ema.ema, self.config, self.device)
            out['mlt'] = evaluate_spotting(engine, self.val_items, self.config, self.config.eval_max_images,
                                           desc='Val spotting eval (MLT)')
        if self.domain_val_items:
            engine = SpottingEngine(self.ema.ema, self.config, self.device)
            out['ic15'] = evaluate_spotting(engine, self.domain_val_items, self.config, None,
                                            desc='Val spotting eval (IC15)')
        if not out:
            return None
        w = self.config.selection_weights
        tot = sum(w.get(k, 0) for k in out) or 1.0
        out['sel_score'] = sum(w.get(k, 0) * m['spot_score'] for k, m in out.items()) / tot
        return out

    def run(self):
        cfg = self.config
        stopped_early, stopped_at = False, None
        epoch = self.start_epoch
        retries = 0
        if self.plan['mode'] == 'resume' and self.evals_without_improvement >= cfg.early_stopping_patience:
            # V4 resumed with exhausted patience and spent a full epoch before stopping.
            print(f"[Trainer] patience already exhausted in stage '{cfg.stage_name}' (best {self.best_score:.4f} "
                  f"@ epoch {self.best_epoch}); skipping training. Change `stage_name` to start a new stage.")
            epoch = self.total_epochs
            stopped_early, stopped_at = True, self.start_epoch
        while epoch < self.total_epochs:
            if len(self.train_loader) == 0:
                print("Skipping training loop; no data found.")
                break
            try:
                tr, gn, mined, clip_frac = self.train_one_epoch(epoch)
            except RuntimeError as e:
                msg = str(e)
                crashed = 'DataLoader worker' in msg and ('killed by signal' in msg or 'exited unexpectedly' in msg)
                if not crashed or self.train_loader_factory is None or retries >= 3:
                    raise
                retries += 1
                print(f"[Trainer] DataLoader worker crashed (retry {retries}/3); rebuilding the loader.")
                self.train_loader = self.train_loader_factory()
                continue
            retries = 0
            va = self.validate(epoch)
            self._update_mixers(va.get('per_script', {}))
            h = self.history
            for k in ('total', 'det', 'text', 'kernel', 'dir', 'rec', 'ctc', 'script_consistency', 'script', 'verify',
                      'family', 'crop_ctc'):
                h['train_' + k].append(tr.get(k, float('nan')))
                h['val_' + k].append(va.get(k, float('nan')))
            for k in ('pix_precision', 'pix_recall', 'pix_f', 'rec_acc', 'rec_1ned', 'script_acc', 'verify_acc'):
                h[k].append(va[k])
            h['lr'].append(self.peak_lr * self.lr_factor(self.global_step))
            h['grad_norm'].append(gn)
            h['clip_frac'].append(clip_frac)
            h['mined_per_batch'].append(mined)
            s = self.criterion.log_vars().detach().cpu().numpy()
            for i, k in enumerate(UnifiedSpotterLoss.TASKS):
                h['w_' + k].append(float(np.exp(-s[i])))
            ps = va.get('per_script', {})
            for name in TRACKED_SCRIPTS:
                h['rec_1ned_' + name.lower()].append(ps[name][0] if name in ps else float('nan'))
                h['mix_beta_' + name.lower()].append(float(self.mixer_beta[cfg.script2id[name.lower()]]))

            do_eval = (self.val_items or self.domain_val_items) and \
                ((epoch + 1) % cfg.eval_every == 0 or epoch + 1 == self.total_epochs)
            ev = self.evaluate_instances() if do_eval else None
            ev_m = ev.get('mlt') if ev else None
            ev_i = ev.get('ic15') if ev else None
            for k in self.EVAL_KEYS:
                h[k].append(ev_m[k] if ev_m else float('nan'))
            for k in ('det_hmean', 'e2e_hmean', 'spot_score'):
                h['ic15_' + k].append(ev_i[k] if ev_i else float('nan'))
            h['sel_score'].append(ev['sel_score'] if ev else float('nan'))
            for name in TRACKED_SCRIPTS:
                h['e2e_recall_' + name.lower()].append(ev_m.get('e2e_recall@' + name, float('nan')) if ev_m else float('nan'))

            improved = False
            if ev is not None:
                score = ev['sel_score']
                improved = score > self.best_score + cfg.early_stopping_min_delta
            elif not (self.val_items or self.domain_val_items):
                score = -va.get('total', 0.0)
                improved = score > self.best_score + cfg.early_stopping_min_delta
            if improved:
                self.best_score, self.best_epoch = score, epoch + 1
                self.evals_without_improvement = 0
            elif ev is not None or not (self.val_items or self.domain_val_items):
                self.evals_without_improvement += 1

            self.save_checkpoint(epoch, is_best=improved, metrics=ev)
            self.save_epoch_log(epoch)
            self.plot_curves()
            msg = (f"Epoch {epoch + 1}: train={tr.get('total', 0):.4f} val={va.get('total', 0):.4f} "
                   f"[det {va.get('det', 0):.3f} ctc {va.get('ctc', float('nan')):.3f} ver {va.get('verify', 0):.3f}] "
                   f"pixF={va['pix_f']:.3f} recAcc={va['rec_acc']:.3f} 1-NED={va['rec_1ned']:.3f} "
                   f"script={va['script_acc']:.3f} verify={va['verify_acc']:.3f} gn={gn:.2f} clip={clip_frac:.2f} "
                   f"mined/b={mined:.1f} strip_ctc={tr.get('strip_ctc', float('nan')):.3f}")
            if ps:
                msg += "\n          per-script 1-NED: " + ', '.join(
                    f"{k} {v[0]:.3f} (n={v[1]})" for k, v in sorted(ps.items(), key=lambda t: -t[1][1]))
            if ev_m:
                msg += (f"\n          VAL MLT : det P/R/H={ev_m['det_precision']:.3f}/{ev_m['det_recall']:.3f}/{ev_m['det_hmean']:.3f} "
                        f"E2E P/R/H={ev_m['e2e_precision']:.3f}/{ev_m['e2e_recall']:.3f}/{ev_m['e2e_hmean']:.3f} "
                        f"dets/img={ev_m['dets_per_image']:.1f}  E2E recall " +
                        ' '.join(f"{n[:3]}={ev_m.get('e2e_recall@' + n, float('nan')):.2f}" for n in TRACKED_SCRIPTS))
            if ev_i:
                msg += (f"\n          VAL IC15: det H={ev_i['det_hmean']:.3f} E2E H={ev_i['e2e_hmean']:.3f} "
                        f"spot={ev_i['spot_score']:.3f}")
            if ev:
                msg += f"\n          selection score {ev['sel_score']:.4f} (best {self.best_score:.4f} @ epoch {self.best_epoch})"
            print(msg)
            if self.evals_without_improvement >= cfg.early_stopping_patience:
                stopped_early, stopped_at = True, epoch + 1
                print(f"[Trainer] Early stopping at epoch {epoch + 1} (best {self.best_score:.4f} @ epoch {self.best_epoch}).")
                break
            epoch += 1
        self.plot_curves()
        self.save_history_json()
        self.save_training_report(stopped_early, stopped_at)

    # ------------------------------ checkpointing ------------------------------
    def _schedule(self):
        return {'peak_lr': self.peak_lr, 'total_epochs': self.total_epochs, 'warmup_epochs': self.warmup_epochs}

    def save_checkpoint(self, epoch, is_best=False, metrics=None):
        snap = self.config.snapshot()
        stage = self.config.stage_name
        torch.save({'epoch': epoch, 'global_step': self.global_step, 'model_state': self.model.state_dict(),
                    'ema_state': self.ema.ema.state_dict(), 'ema_updates': self.ema.updates,
                    'criterion_state': self.criterion.state_dict(), 'optimizer_state': self.optimizer.state_dict(),
                    'scaler_state': self.scaler.state_dict(), 'history': self.history, 'config_snapshot': snap,
                    'vocab_chars': self.config.chars, 'best_score': self.best_score, 'best_epoch': self.best_epoch,
                    'evals_without_improvement': self.evals_without_improvement, 'stage': stage,
                    'schedule': self._schedule(), 'mixer_beta': self.mixer_beta.tolist()},
                   os.path.join(self.config.chkp_dir, 'latest_model.pth'))
        if is_best:
            torch.save({'model_state': self.ema.ema.state_dict(), 'config_snapshot': snap, 'stage': stage,
                        'vocab_chars': self.config.chars, 'epoch': epoch, 'metrics': metrics},
                       os.path.join(self.config.chkp_dir, 'best_model.pth'))

    @staticmethod
    def _filtered_load(module, state):
        state = upgrade_legacy_state(dict(state))
        own = module.state_dict()
        ok = {k: v for k, v in state.items() if k in own and own[k].shape == v.shape}
        module.load_state_dict(ok, strict=False)
        return len(state) - len(ok), len([k for k in own if k not in ok])

    def _backup_old_log(self):
        if os.path.exists(self._epoch_log_path):
            os.replace(self._epoch_log_path, self._epoch_log_path.replace('.csv', f'_backup_{int(time.time())}.csv'))

    def _archive_previous_stage(self, old_stage):
        """Keeps the previous stage's checkpoints next to the new ones (latest -> moved, best -> copied)."""
        d = self.config.chkp_dir
        tag = re.sub(r'[^A-Za-z0-9_]+', '_', str(old_stage))
        for name, move in (('latest_model.pth', True), ('best_model.pth', False)):
            src = os.path.join(d, name)
            dst = os.path.join(d, name.replace('.pth', f'_{tag}.pth'))
            if os.path.exists(src) and not os.path.exists(dst):
                try:
                    ck_stage = _ckpt_stage(torch.load(src, map_location='cpu', weights_only=False))
                except Exception:
                    continue
                if ck_stage != self.config.stage_name:
                    (os.replace if move else shutil.copy2)(src, dst)
                    print(f"[stage] archived {name} of stage '{ck_stage}' as {os.path.basename(dst)}")

    def load_checkpoint(self):
        cfg = self.config
        mode = self.plan['mode']
        if mode == 'scratch':
            self._backup_old_log()
            return
        if mode == 'warm':
            src = self.plan['path']
            ck = torch.load(src, map_location='cpu', weights_only=False)
            self._archive_previous_stage(self.plan.get('old_stage', 'v4'))
            state = dict(ck.get('ema_state') or ck.get('model_state') or {})
            state = remap_vocab_state(state, self.plan.get('old_chars'), cfg.chars, cfg.char2script,
                                      self.plan.get('old_components'))
            dropped, fresh = self._filtered_load(self.model, state)
            print(f"[stage] warm start: {dropped} incompatible tensors dropped, {fresh} not taken from the checkpoint "
                  f"(compositional embeddings start at zero; P(script|char) re-estimated on the merged data).")
            if 'criterion_state' in ck:
                try:
                    self.criterion.load_state_dict(ck['criterion_state'], strict=False)
                except Exception:
                    pass
            del ck
            self.ema = ModelEMA(self.model, cfg.ema_decay)
            self._backup_old_log()
            return
        ckpt = torch.load(self.plan['path'], map_location=self.device, weights_only=False)
        dropped, fresh = self._filtered_load(self.model, ckpt.get('model_state', {}))
        if 'ema_state' in ckpt:
            self._filtered_load(self.ema.ema, ckpt['ema_state'])
            self.ema.updates = ckpt.get('ema_updates', 0)
        else:
            self.ema = ModelEMA(self.model, cfg.ema_decay)
        print(f"[checkpoint] resumed weights ({dropped} incompatible tensors dropped, {fresh} freshly initialised).")
        try:
            self.criterion.load_state_dict(ckpt.get('criterion_state', {}), strict=False)
        except Exception:
            pass
        if ckpt.get('schedule'):
            self._set_schedule(ckpt['schedule'])
        if dropped == 0 and fresh == 0:
            try:
                self.optimizer.load_state_dict(ckpt['optimizer_state'])
                for g in self.optimizer.param_groups:
                    g.setdefault('base_lr', self.peak_lr)
            except Exception as e:
                print(f"[checkpoint] optimizer state not restored ({e}).")
        try:
            self.scaler.load_state_dict(ckpt.get('scaler_state', {}))
        except Exception:
            pass
        self.start_epoch = ckpt.get('epoch', -1) + 1
        self.global_step = ckpt.get('global_step', self.start_epoch * self.steps_per_epoch)
        hist = ckpt.get('history', {})
        if all(k in hist for k in self.HIST_KEYS):
            self.history = hist
        self.best_score = ckpt.get('best_score', -1e9)
        self.best_epoch = ckpt.get('best_epoch', 0)
        self.evals_without_improvement = ckpt.get('evals_without_improvement', 0)
        if ckpt.get('mixer_beta') is not None and len(ckpt['mixer_beta']) == cfg.num_scripts:
            self.mixer_beta = np.asarray(ckpt['mixer_beta'], dtype=np.float64)
            for m in self.mixers:
                m.set_script_multipliers(self.mixer_beta)
        del ckpt
        print(f"Resumed stage '{cfg.stage_name}' at epoch {self.start_epoch}/{self.total_epochs} "
              f"(step {self.global_step}, best {self.best_score:.4f} @ {self.best_epoch}).")

    # ------------------------------ logging / plots / reports ------------------------------
    def save_epoch_log(self, epoch):
        try:
            new = not os.path.exists(self._epoch_log_path)
            with open(self._epoch_log_path, 'a', newline='') as f:
                w = csv.writer(f)
                if new:
                    w.writerow(['epoch'] + self.HIST_KEYS)
                w.writerow([epoch + 1] + [self.history[k][-1] if self.history[k] else '' for k in self.HIST_KEYS])
        except Exception as e:
            print(f"[diagnostics] could not append epoch log: {e}")

    def save_history_json(self):
        path = os.path.join(self.config.reports_dir, 'training_history.json')
        try:
            with open(path, 'w') as f:
                json.dump({'history': self.history, 'best_score': self.best_score, 'best_epoch': self.best_epoch,
                           'stage': self.config.stage_name, 'schedule': self._schedule(),
                           'config': {k: v for k, v in self.config.snapshot().items()
                                      if k not in ('chars', 'char2script', 'components')}},
                          f, indent=1, default=float)
        except Exception as e:
            print(f"[diagnostics] could not save history JSON: {e}")

    def plot_curves(self):
        h = self.history
        n = len(h['train_total'])
        if n == 0:
            return
        ep = np.arange(1, n + 1)
        fig, axs = plt.subplots(3, 4, figsize=(26, 14))
        axs = axs.flatten()

        def pair(ax, key, title):
            ax.plot(ep, h['train_' + key], label='train', lw=2)
            ax.plot(ep, h['val_' + key], '--', label='valid (EMA)', lw=2)
            ax.set_title(title); ax.grid(alpha=0.3); ax.legend(); ax.set_xlabel('epoch')

        def series(ax, keys, title, ylim=None, marker='o-'):
            for k in keys:
                y = np.array(h[k], dtype=float)
                m = ~np.isnan(y)
                if m.any():
                    ax.plot(ep[m], y[m], marker, label=k, ms=3)
            ax.set_title(title); ax.grid(alpha=0.3); ax.legend(fontsize=8)
            if ylim:
                ax.set_ylim(*ylim)
        pair(axs[0], 'total', 'Total (uncertainty-weighted) loss')
        pair(axs[1], 'det', 'Detection loss (text + nested kernels)')
        pair(axs[2], 'ctc', 'CTC loss (clean, fully visible, in-vocabulary words)')
        series(axs[3], ['train_crop_ctc'], 'Strip / crop stream CTC', marker='-')
        pair(axs[4], 'verify', 'Verification loss (legible / ### / background)')
        pair(axs[5], 'script', 'Script-ID loss')
        series(axs[6], ['det_hmean', 'e2e_hmean', 'ic15_det_hmean', 'ic15_e2e_hmean', 'sel_score'],
               'Instance-level val metrics (MLT + IC15 held-out)', (0, 1))
        series(axs[7], ['rec_acc', 'rec_1ned', 'script_acc', 'verify_acc', 'pix_f'], 'Teacher-forced accuracies & pixel F',
               (0, 1), marker='-')
        series(axs[8], ['rec_1ned_' + s for s in self.TRACK], 'Per-script teacher-forced 1-NED (MLT val)', (0, 1), marker='-')
        series(axs[9], ['e2e_recall_' + s for s in self.TRACK], 'Per-script E2E recall (MLT val)', (0, 1))
        series(axs[10], ['mix_beta_' + s for s in self.TRACK], 'Error-feedback script multipliers', marker='-')
        ax = axs[11]
        ax.plot(ep, h['lr'], 'k:', label='lr')
        ax.set_yscale('log'); ax.set_title('LR & task weights exp(-s_k)'); ax.grid(alpha=0.3)
        ax2 = ax.twinx()
        for k in UnifiedSpotterLoss.TASKS:
            ax2.plot(ep, h['w_' + k], label='w_' + k)
        ax2.legend(fontsize=8)
        plt.suptitle(f"A3ESpotter V5 training dashboard - stage '{self.config.stage_name}', epoch {n}")
        plt.tight_layout()
        plt.savefig(os.path.join(self.config.curves_dir, 'dashboard.png'), dpi=100)
        plt.savefig(os.path.join(self.config.out_dir, 'training_curves.png'), dpi=100)
        plt.close()
        plt.figure(figsize=(8, 4.5))
        plt.plot(ep, h['grad_norm'], color='#d62728', label='mean pre-clip norm')
        plt.axhline(self.config.grad_clip, color='k', ls=':', label='clip')
        plt.twinx().plot(ep, h['clip_frac'], color='#1f77b4', alpha=0.6)
        plt.title('Gradient norm (pre-clip) and fraction of clipped steps (blue)'); plt.grid(alpha=0.3)
        plt.tight_layout(); plt.savefig(os.path.join(self.config.curves_dir, 'gradient_norm.png'), dpi=100); plt.close()

    def save_training_report(self, stopped_early=False, stopped_at=None):
        h = self.history
        path = os.path.join(self.config.reports_dir, 'training_report.txt')
        try:
            def best(k, fn=np.nanmax):
                y = np.array(h[k], dtype=float)
                if y.size == 0 or np.all(np.isnan(y)):
                    return float('nan'), 0
                v = fn(y)
                return float(v), int(np.where(y == v)[0][0]) + 1
            L = ['=' * 72, 'TRAINING REPORT - A3ESpotter V5', '=' * 72,
                 f"Stage                   : {self.config.stage_name} ({self.plan['mode']}"
                 f"{', from ' + str(self.plan.get('path')) if self.plan['mode'] == 'warm' else ''})",
                 f'Epochs run              : {len(h["train_total"])} / {self.total_epochs}',
                 f'Stopped early           : {stopped_early} (at epoch {stopped_at})',
                 f'Model selection score   : {self.best_score:.4f} (epoch {self.best_epoch}; '
                 f'{self.config.selection_weights} x spot score of MLT-val / IC15-val)']
            for k in ('det_hmean', 'e2e_hmean', 'ic15_det_hmean', 'ic15_e2e_hmean', 'one_minus_ned', 'rec_acc',
                      'rec_1ned', 'script_acc', 'verify_acc') + tuple('rec_1ned_' + s for s in self.TRACK) + \
                    tuple('e2e_recall_' + s for s in self.TRACK):
                v, e = best(k)
                L.append(f'Best {k:<19}: {v:.4f} (epoch {e})')
            v, e = best('val_ctc', np.nanmin)
            L.append(f'Best val CTC            : {v:.4f} (epoch {e}; ln(V) = {math.log(max(self.config.vocab_size, 2)):.2f})')
            if h['train_total']:
                L.append(f'Final train / val total : {h["train_total"][-1]:.4f} / {h["val_total"][-1]:.4f}')
            L += [f'Vocabulary size         : {self.config.vocab_size}', f'Script classes          : {self.config.num_scripts}',
                  'Final script multipliers: ' + ', '.join(f"{s}={self.mixer_beta[self.config.script2id[s.lower()]]:.2f}"
                                                            for s in TRACKED_SCRIPTS),
                  '', 'Notes:', '  * best_model.pth holds the EMA weights of the best evaluation round of this stage.',
                  '  * CTC is only computed on fully visible, in-vocabulary, not-truncated, not-curved words; the rest',
                  '    still train the detection, script and verification heads.', '=' * 72]
            with open(path, 'w') as f:
                f.write('\n'.join(L))
            print('\n'.join(L))
        except Exception as e:
            print(f"[diagnostics] could not save training report: {e}")


# ==========================================
# 10. Main Execution Flow
# ==========================================
def build_items(img_dir, gt_dir):
    items = []
    if not img_dir or not gt_dir or not os.path.isdir(img_dir) or not os.path.isdir(gt_dir):
        return items
    for p in list_images(img_dir):
        g = find_gt_file(gt_dir, p)
        if g is not None:
            items.append((p, g))
    return items


def apply_config_snapshot(config, snap, keys=None):
    for k, v in snap.items():
        if k in ('chars', 'char2script', 'script_marginal', 'components'):
            continue
        if (keys is None or k in keys) and hasattr(config, k):
            setattr(config, k, v)
    if keys is None:
        config.set_vocab(snap['chars'], snap.get('char2script'), snap.get('script_marginal'))


def load_model_for_inference(path, config=None, device='cpu'):
    """Rebuild a model from best_model.pth / latest_model.pth (vocab, architecture and the calibrated operating
    point come from the checkpoint)."""
    config = config or Config()
    ckpt = torch.load(path, map_location='cpu', weights_only=False)
    if 'config_snapshot' in ckpt:
        apply_config_snapshot(config, ckpt['config_snapshot'])
    config.pretrained_backbone = False
    model = A3ESpotter_V5(config)
    state = ckpt.get('ema_state', ckpt.get('model_state', ckpt))
    missing, unexpected = model.load_state_dict(upgrade_legacy_state(dict(state)), strict=False)
    missing = [k for k in missing if not k.endswith('comp_embed')]
    if missing or unexpected:
        print(f"[inference] non-strict load: {len(missing)} missing, {len(unexpected)} unexpected tensors")
    return model.to(device).eval(), config


def _make_loader(ds, batch_size, collate, sampler=None, shuffle=False, drop_last=False, workers=2):
    kw = dict(num_workers=workers, pin_memory=torch.cuda.is_available(), worker_init_fn=worker_init_fn,
              persistent_workers=workers > 0)
    return DataLoader(ds, batch_size=batch_size, sampler=sampler, shuffle=shuffle if sampler is None else False,
                      drop_last=drop_last, collate_fn=collate, **kw)


def main(config=None):
    config = config or Config()
    seed_everything(config.seed)
    ensure_base_datasets(config)              # MLT-19 / IC15: configured -> attached -> downloaded

    # ---------------- evaluation splits (MLT-val, IC15-val = test domain) ----------------
    mlt_items = build_items(config.train_img_dir, config.train_gt_dir)
    rng = random.Random(config.seed)
    rng.shuffle(mlt_items)
    n_val = int(round(len(mlt_items) * config.val_fraction)) if len(mlt_items) > 1 else 0
    val_items, train_items = mlt_items[:n_val], mlt_items[n_val:]
    ic15_items = build_items(config.ic15_train_img_dir, config.ic15_train_gt_dir)
    random.Random(config.seed + 1).shuffle(ic15_items)
    n_iv = int(round(len(ic15_items) * config.ic15_val_fraction)) if len(ic15_items) > 10 else 0
    ic15_val, ic15_train = ic15_items[:n_iv], ic15_items[n_iv:]
    print(f"MLT train {len(train_items)} | MLT val {len(val_items)} | IC15 train {len(ic15_train)} | "
          f"IC15 held-out val {len(ic15_val)}")
    eval_paths = [p for p, _ in val_items] + [p for p, _ in ic15_val] + list_images(config.test_img_dir)

    # ---------------- merged training index (MLT + IC15 + extra + public CJK) ----------------
    index = build_training_index(config, train_items, ic15_train, eval_paths)

    # ---------------- stage plan + vocabulary ----------------
    plan = plan_stage(config)
    if plan['mode'] == 'resume':
        apply_config_snapshot(config, plan['snapshot'])
        print(f"Resuming stage '{config.stage_name}': {len(config.chars)}-symbol vocabulary from checkpoint.")
    else:
        base_chars = None
        if plan['mode'] == 'warm':
            apply_config_snapshot(config, plan['snapshot'], keys=Config.ARCH_KEYS)
            base_chars = plan.get('old_chars')
        crop_labels = []
        for src in config.crop_rec_sources:
            crop_labels += list(_iter_crop_labels(src, config.crop_vocab_scan))
        if crop_labels:
            print(f"Vocabulary also uses {len(crop_labels)} word-crop labels.")
        config.build_vocab_from_index(index, crop_labels, base_chars)
        if base_chars:
            print(f"Vocabulary extended {len(base_chars)} -> {len(config.chars)} symbols (old indices preserved).")
    by_script = Counter(int(np.argmax(config.char2script[i + 2])) for i in range(len(config.chars)))
    print(f"Vocabulary size: {config.vocab_size} ({len(config.chars)} symbols + blank + unk); by script: " +
          ', '.join(f"{config.CANONICAL_SCRIPTS[k]}={v}" for k, v in by_script.most_common()))

    # ---------------- datasets / loaders ----------------
    collate_fn = make_collate_fn(config)
    train_dataset = MergedSceneTextDataset(index, config, is_train=True)
    base_w, share = compute_mixture_weights(index, config)
    index.summary(config, share)
    mass = index.script_mass(config.num_scripts)
    sampler = ScriptAdaptiveMixtureSampler(base_w, mass, config.samples_per_epoch, seed=config.seed)
    val_dataset = ICDAR2019Dataset(val_items if val_items else train_items[:max(1, len(train_items) // 10)],
                                   config, is_train=False)
    nw = config.num_workers

    def build_train_loader():
        return _make_loader(train_dataset, config.batch_size, collate_fn, sampler=sampler, drop_last=True, workers=nw)

    train_loader = build_train_loader()
    val_loader = _make_loader(val_dataset, config.batch_size, collate_fn, workers=nw)

    streams, mixers = [], [sampler]
    if config.use_scene_strips and config.w_strip_rec > 0:
        strip_ds = SceneWordStripDataset(train_dataset, config, config.strips_per_image)
        strip_sampler = ScriptAdaptiveMixtureSampler(base_w, mass, config.samples_per_epoch, seed=config.seed + 11)
        strip_loader = _make_loader(strip_ds, config.strip_batch_images, _CropCollate(config.crop_batch_size),
                                    sampler=strip_sampler, drop_last=True, workers=config.strip_num_workers)
        streams.append((strip_loader, config.w_strip_rec, 'strip'))
        mixers.append(strip_sampler)
        print(f"Scene-word strip stream: {config.strip_batch_images} images x <= {config.strips_per_image} strips per step.")
    if config.crop_rec_sources:
        crop_ds = CropRecognitionDataset(config.crop_rec_sources, config, config.crop_max_samples)
        if len(crop_ds) > 0:
            print(f"Word-crop recognition stream: {len(crop_ds)} samples, batch {config.crop_batch_size}.")
            streams.append((_make_loader(crop_ds, config.crop_batch_size, _CropCollate(), shuffle=True, drop_last=True,
                                         workers=config.strip_num_workers), config.w_crop_rec, 'crop'))

    seed_cuda(config.seed)
    model = A3ESpotter_V5(config)
    n_params = sum(p.numel() for p in model.parameters()) / 1e6
    print(f"A3ESpotter V5: {n_params:.1f}M parameters | backbone={config.backbone} "
          f"(ImageNet init: {model.backbone.pretrained_loaded}) | compositional components: "
          f"{len(model.recognizer.classifier.component_names)}")

    trainer = Trainer(model, train_loader, val_loader, config, train_loader_factory=build_train_loader,
                      val_items=val_items, domain_val_items=ic15_val, crop_loaders=streams, mixers=mixers, plan=plan)
    trainer.run()

    model = trainer.ema.ema
    best_path = os.path.join(config.chkp_dir, 'best_model.pth')
    if config.use_best_checkpoint_for_inference and os.path.exists(best_path):
        best = torch.load(best_path, map_location='cpu', weights_only=False)
        if 'config_snapshot' in best and _ckpt_stage(best) == config.stage_name:
            Trainer._filtered_load(model, best['model_state'])
            print(f"[inference] loaded best_model.pth (epoch {best.get('epoch', -1) + 1}, metrics={best.get('metrics')})")
        else:
            print("[inference] best_model.pth belongs to another stage; using the final EMA weights.")
    if config.calibrate_operating_point:
        calib_items = ic15_val if ic15_val else val_items
        calibrate_operating_point(model, config, calib_items)
        try:                                   # store the calibrated operating point with the weights
            for name in ('best_model.pth',):
                p = os.path.join(config.chkp_dir, name)
                if os.path.exists(p):
                    ck = torch.load(p, map_location='cpu', weights_only=False)
                    if _ckpt_stage(ck) == config.stage_name:
                        ck['config_snapshot'] = config.snapshot()
                        torch.save(ck, p)
        except Exception as e:
            print(f"[calibration] could not store the operating point in the checkpoint: {e}")
    inferencer = TiledInferencer(model, config) if config.use_tiling else Inferencer(model, config)
    return inferencer.run()


if __name__ == "__main__":
    main()
