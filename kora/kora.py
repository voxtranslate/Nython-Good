# =============================================================================================
#  KORA v2 — Route-Agreement Pseudo-Labelling for Tri-Modal (speech · text · image) Translation,
#            Transcription and Speech Synthesis in Low-Resource African Languages
#            (Hausa · Yorùbá · Lingála  <->  English, many-to-many)
# ---------------------------------------------------------------------------------------------
#  Single-file, Kaggle-ready PyTorch implementation (2×T4 / P100, 16 GB). A CUDA GPU is required
#  for the real run (set KORA_ALLOW_CPU=1 only for smoke tests with tiny models).
#
#  WHAT CHANGED IN v2 (root causes found in the v1 logs, and their fixes)
#   * v1 decoder collapse: every ST output was the same English sentence and every AED transcript the
#     same fluent sentence per language, while the CTC head was fine (FLEURS CER 11-30 %). The speech
#     memory produced by a randomly initialised 2-layer bridge never became readable by the frozen
#     NLLB decoder, which fell back on its language-model prior.
#       -> NEW Subword-Anchored Bridge (SAB): the model's own CTC cuts the speech into one segment per
#          NLLB *subword* of its hypothesis (or of the force-aligned transcript, batched CTC-Viterbi).
#          Each segment becomes one vector at the input of the (LoRA-adapted) NLLB encoder:
#          e_k = E[subword_k] + R(attention-pooled frames_k, E[subword_k], CTC confidence_k), with the
#          acoustic residual R zero-initialised — the bridge starts as an exact cascade (it cannot
#          collapse), token identity comes from the tokenizer (unseen words generalise) and training
#          learns where the acoustics must overrule the hypothesis. Because speech and text sequences
#          are token-synchronous, NLLB-encoder outputs are matched position by position wherever the
#          subwords agree, and the decoder is distilled (top-k) from the model's own text route.
#          (A first acoustic-only variant — pooled frames regressed onto subword embeddings — did not
#          generalise to unseen subwords in a check with the real NLLB; it is kept as an ablation.)
#       -> CTC warm-up curriculum before any sequence loss on speech, dev-time collapse detectors
#          (output diversity, source-sensitivity index) and best-checkpoint selection.
#   * "joint" decoding was AED-only (CTC only re-ranked the collapsed AED n-best) -> real two-route
#     joint decoding: CTC prefix beam search ∪ AED n-best, rescored by λ·CTC + (1-λ)·AED, λ tuned on dev.
#   * route-MBR was a no-op (the 4 near-identical direct hypotheses always out-voted the single cascade
#     hypothesis; KORA-mbr == KORA-direct to 10 decimals) -> ROUTE-BALANCED MBR: a hypothesis is scored
#     by its agreement with the OTHER routes, each route carrying the same total weight.
#   * the cascade used collapsed AED transcripts -> cascades are built on the dev-selected ASR output.
#   * TTS produced a time-invariant "mean spectrum": inference conditioned on a domain/gender embedding
#     that was never trained (domain 'bible' with gender 'NA', while only FLEURS had been seen, since
#     the collapsed pseudo-labels never passed the 0.6 score threshold). -> TTS is trained on real
#     studio BibleTTS speech with its gold text (adaptation split only — never the test verses, and the
#     ASR/ST branches never see that gold), inference refuses unseen conditions, random-segment
#     flow-matching crops (Matcha-TTS style) and a longer schedule.
#   * the RTF table was empty (timings were a side-effect of blocks skipped on resume) -> dedicated,
#     cached RTF benchmark with warm-up and CUDA synchronisation.
#   * CER was computed with spaces removed (hiding word-boundary errors, e.g. Bible ln WER 71 / CER 2.6)
#     -> standard CER (spaces count) + a space-free diagnostic + an orthography-normalised WER (the
#     Hausa Bible marks short vowels with a breve: 'yă', 'tă').
#   * significance tests used the collapsed 'joint' system -> the dev-selected decoding mode.
#   * real data only by default: the synthetic MMS-TTS "Spoken-HaVG" is replaced by YFACC (REAL spoken
#     Yorùbá captions of REAL Flickr8k images, Olaleye et al., SLT 2023), official BibleTTS splits are
#     used (dev/test are held-out books; the tiny test set is topped up with whole held-out chapters),
#     verse-aligned eBible text gives Bible-domain English references and text-only target-domain data.
#
#  Pipeline (main()):
#    1. installs missing packages, imports the state of a previous Kaggle session (attached output)
#    2. builds every corpus from its canonical source (attached copies under /kaggle/input first):
#         - FLEURS ha/yo/ln (+ en text)                         google/fleurs (HF)
#         - BibleTTS ha/yo/ln (official dev/test + streamed train)  OpenSLR SLR129
#         - eBible verse-aligned text (Biblica open ha/yo/ln, World English Bible)  BibleNLP/ebible
#         - Hausa Visual Genome with images                     HausaNLP/HausaVG (HF parquet)
#         - YFACC real Yorùbá speech + Flickr8k images/captions  kamperh/yfacc, jxie/flickr8k
#    3. Stage-1: CTC warm-up -> supervised multi-task (ASR, ST, MT, MMT, speech+image MT) through SAB
#       + Masked Posterior Distillation (MPD) on unlabeled target-domain audio
#    4. R rounds of Route-Agreement Pseudo-Labelling (RAPL, route-balanced) with agreement-masked
#       token-level pseudo-labels (AMT-PL)
#    5. CTC self-alignment -> durations -> flow-matching TTS (Vocos vocoder)
#    6. training ablations from the same Stage-1 warm start
#    7. evaluation vs real external baselines, dev-selected decoding, paired bootstrap significance,
#       PL-quality analyses, collapse diagnostics, visual-awareness tests, domain gap, RTF, figures,
#       LaTeX/Markdown/CSV tables.
#  Every phase is idempotent and resumable; everything stops cleanly before Kaggle's 12 h limit.
# =============================================================================================
from __future__ import annotations

import os

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

import sys
import subprocess
import importlib


def _ensure_packages():
    """Install the packages that are not always present on Kaggle images. Installation errors are fatal."""
    req = {
        "sacrebleu": "sacrebleu>=2.3",
        "soundfile": "soundfile",
        "vocos": "vocos",
        "kagglehub": "kagglehub",
        "pyarrow": "pyarrow",
        "sentencepiece": "sentencepiece",
        "sklearn": "scikit-learn",
        "rapidfuzz": "rapidfuzz",
        "yaml": "pyyaml",
        "scipy": "scipy",
        "PIL": "pillow",
        "packaging": "packaging",
    }
    missing = []
    for mod, pipname in req.items():
        try:
            importlib.import_module(mod)
        except ImportError:
            missing.append(pipname)
    if missing:
        print(f"[setup] installing: {missing}")
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", *missing], check=True)
        importlib.invalidate_caches()


if os.environ.get("KORA_SKIP_INSTALL") != "1":
    _ensure_packages()

import io
import re
import gc
import json
import math
import time
import copy
import glob
import zlib
import shutil
import random
import zipfile
import tarfile
import hashlib
import difflib
import logging
import datetime
import platform
import warnings
import contextlib
import unicodedata
import http.client
import urllib.request
from dataclasses import dataclass, field, asdict
from collections import defaultdict, Counter
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import numpy as np
import pandas as pd
import soundfile as sf
import torch
import torch.nn as nn
import torch.nn.functional as F
import torchaudio
from torch.utils.data import Dataset, DataLoader, Sampler

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

import sacrebleu
from rapidfuzz.distance import Levenshtein as RFLevenshtein
from packaging import version as pkg_version

import transformers
from transformers import AutoConfig, AutoTokenizer, AutoFeatureExtractor, AutoModelForSeq2SeqLM
from transformers.modeling_outputs import BaseModelOutput

warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=FutureWarning)
transformers.logging.set_verbosity_error()

PROGRAM_T0 = time.time()
IS_KAGGLE = os.path.isdir("/kaggle") or "KAGGLE_KERNEL_RUN_TYPE" in os.environ
LANG_NAMES = {"ha": "Hausa", "yo": "Yorùbá", "ln": "Lingála", "en": "English"}
_TF_VERSION = pkg_version.parse(transformers.__version__)


# =============================================================================================
#                                           CONFIG
# =============================================================================================
def _default_work_root() -> str:
    return "/kaggle/working" if IS_KAGGLE else os.path.abspath("./kora_runs")


def _default_cache_dir() -> str:
    """Large local scratch space that does not count against the 20 GB /kaggle/working quota."""
    if not IS_KAGGLE:
        return os.path.abspath("./kora_cache")
    for c in ("/kaggle/temp/kora_cache", "/tmp/kora_cache"):
        try:
            os.makedirs(c, exist_ok=True)
            return c
        except OSError:
            continue
    raise RuntimeError("no writable scratch directory (/kaggle/temp or /tmp) is available")


@dataclass
class PathConfig:
    work_root: str = field(default_factory=_default_work_root)
    cache_dir: str = field(default_factory=_default_cache_dir)
    run_name: str = "kora_v2"

    @property
    def work_dir(self):
        return os.path.join(os.path.abspath(self.work_root), self.run_name)

    @property
    def ckpt_dir(self):
        return os.path.join(self.work_dir, "models")

    @property
    def results_dir(self):
        return os.path.join(self.work_dir, "results")

    @property
    def fig_dir(self):
        return os.path.join(self.results_dir, "figures")

    @property
    def table_dir(self):
        return os.path.join(self.results_dir, "tables")

    @property
    def pred_dir(self):
        return os.path.join(self.results_dir, "predictions")

    @property
    def audio_dir(self):
        return os.path.join(self.results_dir, "audio_samples")

    @property
    def log_dir(self):
        return os.path.join(self.work_dir, "logs")

    @property
    def pl_dir(self):
        return os.path.join(self.work_dir, "pseudo_labels")

    @property
    def tts_dir(self):
        return os.path.join(self.work_dir, "tts_data")

    @property
    def state_path(self):
        return os.path.join(self.work_dir, "pipeline_state.json")

    @property
    def vocab_path(self):
        return os.path.join(self.work_dir, "char_vocab.json")

    @property
    def manifest_dir(self):
        return os.path.join(self.cache_dir, "manifests")

    def make(self):
        for d in [self.work_dir, self.cache_dir, self.ckpt_dir, self.results_dir, self.fig_dir, self.table_dir,
                  self.pred_dir, self.audio_dir, self.log_dir, self.pl_dir, self.tts_dir, self.manifest_dir]:
            os.makedirs(d, exist_ok=True)


@dataclass
class DataConfig:
    african_langs: List[str] = field(default_factory=lambda: ["ha", "yo", "ln"])
    fleurs_codes: Dict[str, str] = field(default_factory=lambda: {
        "ha": "ha_ng", "yo": "yo_ng", "ln": "ln_cd", "en": "en_us"})
    nllb_codes: Dict[str, str] = field(default_factory=lambda: {
        "ha": "hau_Latn", "yo": "yor_Latn", "ln": "lin_Latn", "en": "eng_Latn"})
    whisper_codes: Dict[str, str] = field(default_factory=lambda: {
        "ha": "hausa", "yo": "yoruba", "ln": "lingala", "en": "english"})
    mms_codes: Dict[str, str] = field(default_factory=lambda: {"ha": "hau", "yo": "yor", "ln": "lin"})
    bibletts_names: Dict[str, str] = field(default_factory=lambda: {
        "ha": "hausa", "yo": "yoruba", "ln": "lingala"})
    # ---- sources (verified) ----------------------------------------------------------------
    fleurs_repo: str = "google/fleurs"                      # data/<code>/{split}.tsv + audio/{split}.tar.gz
    havg_repo: str = "HausaNLP/HausaVG"                     # parquet export: default/<split>/NNNN.parquet
    havg_revision: str = "refs/convert/parquet"
    bibletts_mirrors: List[str] = field(default_factory=lambda: [   # official SLR129 mirrors
        "https://openslr.trmal.net/resources/129",
        "https://openslr.elda.org/resources/129",
        "https://openslr.magicdatatech.com/resources/129",
    ])
    # BibleTTS archives are ordered dev -> test -> train. dev/test are whole held-out books (tiny: e.g.
    # Yorùbá 63/40 verses); the test set is topped up with WHOLE held-out train chapters.
    bibletts_max_train_utts_per_lang: int = 5000
    bibletts_max_train_hours_per_lang: float = 14.0
    bibletts_max_dev_utts: int = 300
    bibletts_min_test_utts: int = 500
    # eBible: verse-aligned text; the Biblica open translations are the texts read in BibleTTS
    ebible_base: str = "https://raw.githubusercontent.com/BibleNLP/ebible/main"
    ebible_ids: Dict[str, str] = field(default_factory=lambda: {
        "en": "eng-engwebp", "ha": "hau-hausa", "yo": "yor-yor", "ln": "lin-lin"})
    use_ebible_mt: bool = True             # target-domain text (verses of every used BibleTTS clip excluded)
    ebible_max_verses: int = 16000
    # YFACC: 6k REAL spoken Yorùbá captions (single speaker) of REAL Flickr8k images, CC BY-SA 4.0
    use_yfacc: bool = True
    yfacc_urls: List[str] = field(default_factory=lambda: [
        "https://www.dropbox.com/s/wbpyd08t29airsg/yfacc_v6.tar.gz?dl=1"])
    flickr8k_repo: str = "jxie/flickr8k"   # parquet with the original file names in image.path
    flickr8k_text_url: str = "https://github.com/jbrownlee/Datasets/releases/download/Flickr8k/Flickr8k_text.zip"
    # synthetic speech is OFF by default (real speech only); kept as an optional ablation
    use_synthetic_spoken_havg: bool = False
    spoken_havg_train: int = 5000
    spoken_havg_eval: int = 1000
    # optional Kaggle datasets {logical_name: "owner/slug"} mounted with kagglehub and searched too
    kaggle_slugs: Dict[str, str] = field(default_factory=dict)
    # ---- sizes / filters ------------------------------------------------------------------
    min_dur: float = 0.6
    max_dur: float = 20.0                  # longest utterance used for TRAINING / pseudo-labelling
    eval_max_dur: float = 30.0             # longest utterance kept at all (Whisper's 30 s window)
    max_fleurs_train_per_lang: Optional[int] = None
    havg_max_train: Optional[int] = None
    vis_grid: int = 4                      # SigLIP patch grid pooled to vis_grid x vis_grid
    delete_archives: bool = True


@dataclass
class ModelConfig:
    # w2v-BERT 2.0 (SeamlessM4T-v2 speech encoder, 4.5 M h / 143+ languages of self-supervised pre-training)
    # is much stronger than MMS-300m for low-resource ASR; any wav2vec2-family checkpoint also works.
    speech_model: str = "facebook/w2v-bert-2.0"
    text_model: str = "facebook/nllb-200-distilled-600M"
    vision_model: str = "google/siglip-base-patch16-224"
    vocoder_model: str = "charactr/vocos-mel-24khz"
    speech_trainable_top_layers: int = 12
    speech_layerdrop: float = 0.05
    speech_mask_time_prob: float = 0.05
    grad_checkpointing: bool = True
    # --- Subword-Anchored Bridge ---
    sab_hidden: int = 1024
    sab_dropout: float = 0.1
    sab_max_tokens: int = 160
    lora_r: int = 16
    lora_alpha: int = 32
    lora_dropout: float = 0.05
    lora_targets_decoder: Tuple[str, ...] = ("q_proj", "k_proj", "v_proj", "out_proj", "fc1", "fc2")
    lora_targets_encoder: Tuple[str, ...] = ("q_proj", "k_proj", "v_proj", "out_proj", "fc1", "fc2")
    vis_dim: int = 768
    gate_hidden: int = 256
    # --- TTS (flow matching); the mel front-end is the one of the Vocos checkpoint -------------
    tts_dim: int = 256
    tts_enc_layers: int = 4
    tts_dec_blocks: int = 6
    tts_heads: int = 4
    n_mels: int = 100          # checked against the Vocos config at start-up
    tts_sr: int = 24000        # checked against the Vocos config at start-up
    tts_hop: int = 256         # checked against the Vocos config at start-up
    fm_sigma_min: float = 1e-4
    fm_steps: int = 32
    tts_crop_frames: int = 256  # flow-matching decoder trained on random crops (~2.7 s)
    # --- Masked Posterior Distillation ---
    mpd_mask_prob: float = 0.45
    mpd_mask_len: int = 10
    mpd_top_k_layers: int = 8
    mpd_conf_thr: float = 0.55
    mpd_blank_weight: float = 0.1
    mpd_lambda_latent: float = 0.5
    ema_decay: float = 0.999   # reached after the (1+n)/(10+n) EMA warm-up


@dataclass
class PLConfig:
    rounds: int = 2
    retention_schedule: List[float] = field(default_factory=lambda: [0.55, 0.75])
    beams: int = 4
    nbest: int = 4
    ctc_beam: int = 8
    w_ctc_aed: float = 1.0
    w_route: float = 1.0
    w_conf: float = 0.5
    w_len: float = 0.5
    token_weight_min: float = 0.2
    ctc_agree_thr: float = 0.85
    rep_ngram: int = 3
    rep_max: int = 3
    pl_batch: int = 8
    text_pl_retention: float = 0.7
    text_pl_max_per_lang: int = 6000
    tts_pl_retention: float = 0.5  # only when TTS is trained on pseudo-labels (tts_use_bible_gold=False)
    kde_keep: float = 0.9          # Gheini et al. (2023) Ratio-KDE baseline
    xsim_keep: float = 0.9         # Gheini et al. (2023) LASER-style filter, computed with SONAR
    mbr_within_route: float = 0.1  # route-balanced MBR: utilities within 0.1 chrF are tied; same-route support breaks ties


@dataclass
class TrainConfig:
    seed: int = 1234
    stage1_steps: int = 16000
    round_steps: List[int] = field(default_factory=lambda: [4000, 4000])
    tts_steps: int = 40000
    ctc_warmup_steps: int = 2000   # speech tasks train CTC only (the bridge needs a usable CTC alignment)
    mpd_warmup_steps: int = 3000   # Stage-1 steps before MPD starts (the EMA teacher's CTC head is untrained)
    max_batch_seconds: float = 150.0
    max_batch_utts: int = 16
    text_batch: int = 24
    tts_batch: int = 16
    grad_accum: int = 2
    lr_speech: float = 5e-5
    lr_lora: float = 3e-4
    lr_new: float = 5e-4
    lr_tts: float = 5e-4
    warmup: int = 1000
    weight_decay: float = 0.01
    clip: float = 1.0
    fp16: bool = True
    label_smoothing: float = 0.1
    num_workers: int = 2
    log_every: int = 25
    eval_every: int = 1000
    save_every: int = 500
    keep_last: int = 1             # one resumable step checkpoint per phase (20 GB /kaggle/working quota)
    keep_best: bool = True         # dev-selected snapshot per recognition phase
    prune_intermediate: bool = True
    max_session_hours: float = 11.25
    dev_eval_utts: int = 90
    stage1_task_weights: Dict[str, float] = field(default_factory=lambda: {
        "asr": 0.20, "st": 0.20, "mt": 0.08, "mt_bible": 0.06, "mmt": 0.12, "smmt": 0.08, "mpd": 0.16})
    round_task_weights: Dict[str, float] = field(default_factory=lambda: {
        "asr": 0.15, "st": 0.14, "mt": 0.06, "mt_bible": 0.06, "mmt": 0.10, "smmt": 0.06, "mpd": 0.10,
        "pl": 0.23})
    lambda_ctc: float = 0.5
    lambda_encmatch: float = 1.0
    lambda_kd: float = 0.5
    kd_topk: int = 32
    sab_greedy_prob: float = 0.8   # share of speech batches segmented by the CTC hypothesis (= test condition)
    lambda_gate: float = 0.2
    lambda_aware: float = 0.1
    aware_margin: float = 0.05
    image_drop: float = 0.2
    tts_use_bible_gold: bool = True  # TTS on BibleTTS gold of the ADAPTATION split (never test verses)
    ablations: List[str] = field(default_factory=lambda: [
        "no_pl", "vanilla_pl", "kde_pl", "rapl_no_tokenmask", "rapl_no_mpd", "no_gate_supervision",
        "no_sab_anchor"])
    ablation_steps: int = 2000


@dataclass
class EvalConfig:
    max_eval_utts: Optional[int] = 400
    beams: int = 5
    max_new_tokens: int = 200
    n_bootstrap: int = 1000
    whisper_model: str = "openai/whisper-medium"
    mms_asr_model: str = "facebook/mms-1b-all"
    mms_tts_prefix: str = "facebook/mms-tts-"
    mms_tts_langs: List[str] = field(default_factory=lambda: ["ha", "yo"])  # MMS-TTS has no Lingala model
    sonar_model: str = "cointegrated/SONAR_200_text_encoder"
    utmos_repo: str = "tarepan/SpeechMOS:v1.2.0"
    utmos_model: str = "utmos22_strong"
    joint_lambdas: List[float] = field(default_factory=lambda: [0.3, 0.5, 0.7])
    dev_select_utts: int = 120
    tts_eval_utts: int = 100
    s2st_eval_utts: int = 60
    rtf_utts: int = 24
    n_audio_samples: int = 12
    n_tsne_points: int = 600


@dataclass
class KoraConfig:
    run_name: str = "kora_v2"
    paths: PathConfig = field(default_factory=PathConfig)
    data: DataConfig = field(default_factory=DataConfig)
    model: ModelConfig = field(default_factory=ModelConfig)
    pl: PLConfig = field(default_factory=PLConfig)
    train: TrainConfig = field(default_factory=TrainConfig)
    eval: EvalConfig = field(default_factory=EvalConfig)

    def __post_init__(self):
        self.paths.run_name = self.run_name
        if len(self.pl.retention_schedule) < self.pl.rounds or len(self.train.round_steps) < self.pl.rounds:
            raise ValueError("retention_schedule and round_steps need one entry per RAPL round")

    def to_dict(self):
        return asdict(self)

    def save(self, path):
        with open(path, "w") as f:
            json.dump(self.to_dict(), f, indent=2, default=str)

    @property
    def all_langs(self):
        return self.data.african_langs + ["en"]


# =============================================================================================
#                                          UTILITIES
# =============================================================================================
def setup_logger(log_dir: str, name="kora") -> logging.Logger:
    os.makedirs(log_dir, exist_ok=True)
    logger = logging.getLogger(name)
    logger.setLevel(logging.INFO)
    if not logger.handlers:
        fmt = logging.Formatter("%(asctime)s | %(levelname)s | %(message)s", "%H:%M:%S")
        sh = logging.StreamHandler(sys.stdout)
        sh.setFormatter(fmt)
        fh = logging.FileHandler(os.path.join(log_dir, "run.log"))
        fh.setFormatter(fmt)
        logger.addHandler(sh)
        logger.addHandler(fh)
    return logger


LOG = logging.getLogger("kora")


def seed_everything(seed: int):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def stable_hash(s: str) -> int:
    return int(hashlib.md5(s.encode("utf-8")).hexdigest()[:8], 16)


def amp_ctx(device) -> contextlib.AbstractContextManager:
    """fp16 autocast on CUDA; a no-op elsewhere (CPU smoke tests)."""
    dev = torch.device(device) if not isinstance(device, torch.device) else device
    if dev.type == "cuda":
        return torch.autocast(device_type="cuda", dtype=torch.float16)
    return contextlib.nullcontext()


def cuda_sync(device=None):
    if torch.cuda.is_available():
        torch.cuda.synchronize(device)


def read_jsonl(path: str, allow_truncated_tail: bool = False) -> List[dict]:
    """Reads a JSONL file. With allow_truncated_tail=True a final line cut by an interrupted append is
    dropped (append-only logs written by resumable phases); any other malformed line is an error."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    rows = []
    for k, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            if allow_truncated_tail and not any(x.strip() for x in lines[k + 1:]):
                LOG.warning(f"{path}: dropping the truncated final record of an interrupted write")
                break
            raise
    return rows


def write_jsonl(path: str, rows: Iterable[dict]):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


class JsonlLog:
    """Append-only JSONL log for resumable phases. On open, a record truncated by a killed session is
    dropped and the file rewritten so that new records never land on a corrupted line."""

    def __init__(self, path: str):
        self.path = path
        self.rows = read_jsonl(path, allow_truncated_tail=True)
        write_jsonl(path, self.rows)
        self._fh = open(path, "a", encoding="utf-8")

    def append(self, row: dict):
        self._fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        self.rows.append(row)

    def flush(self):
        self._fh.flush()

    def close(self):
        if not self._fh.closed:
            self._fh.close()


def save_json(path: str, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False, default=float)
    os.replace(tmp, path)


def load_json(path: str, default=None):
    if not os.path.exists(path):
        return default
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def free_memory():
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()


def count_params(module: nn.Module, trainable_only=False) -> int:
    return sum(p.numel() for p in module.parameters() if (p.requires_grad or not trainable_only))


class SessionTimeout(Exception):
    """Raised before Kaggle's hard session limit; everything done so far is on disk."""


class Timer:
    """Wall-clock budget measured from program start (data preparation counts towards Kaggle's 12 h)."""

    def __init__(self, max_hours: float):
        self.t0 = PROGRAM_T0
        self.max_hours = max_hours

    def elapsed_h(self) -> float:
        return (time.time() - self.t0) / 3600.0

    def check(self):
        if self.elapsed_h() > self.max_hours:
            raise SessionTimeout()


# ------------------------------------------------------------------- audio helpers ----------
def resample(wav: np.ndarray, sr: int, target_sr: int) -> np.ndarray:
    wav = np.ascontiguousarray(wav, dtype=np.float32)
    if sr == target_sr:
        return wav
    return torchaudio.functional.resample(torch.from_numpy(wav), sr, target_sr).numpy()


def load_audio(path: str, target_sr: int = 16000) -> np.ndarray:
    wav, sr = sf.read(path, dtype="float32", always_2d=True)
    return resample(wav.mean(axis=1), sr, target_sr)


def save_wav(path: str, wav: np.ndarray, sr: int):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sf.write(path, np.clip(wav, -1.0, 1.0), sr, subtype="PCM_16")


def trim_silence(wav: np.ndarray, sr: int, top_db: float = 40.0, margin_s: float = 0.15) -> np.ndarray:
    """Energy-based trimming of leading/trailing silence (frames 25 ms / hop 10 ms, threshold relative to
    the loudest frame). Used for fixed-length padded recordings (YFACC clips are all exactly 8 s)."""
    n, hop = int(0.025 * sr), int(0.010 * sr)
    if len(wav) < 2 * n:
        return wav
    frames = np.lib.stride_tricks.sliding_window_view(wav, n)[::hop]
    db = 10 * np.log10(np.mean(frames ** 2, axis=1) + 1e-10)
    keep = np.nonzero(db > db.max() - top_db)[0]
    if len(keep) == 0:
        return wav
    s = max(0, keep[0] * hop - int(margin_s * sr))
    e = min(len(wav), keep[-1] * hop + n + int(margin_s * sr))
    return wav[s:e]


# ------------------------------------------------------------------- text helpers -----------
TONE_MARKS = {"̀", "́", "̂", "̄", "̌", "̋", "̏"}  # not the dot-below
ORTHO_MARKS = {"̆", "̄"}  # breve / macron: the Hausa Bible marks vowel length ('yă', 'sāke'); FLEURS Hausa
# does not. (For Yorùbá the macron is the optional mid-tone mark; an unmarked vowel already reads as mid.)


def normalize_text(s: str, strip_tones: bool = False, strip_ortho: bool = False) -> str:
    """Language-aware normaliser for WER/CER, CTC targets and ASR targets.
    Keeps letters (incl. Hausa hooked letters ɓ ɗ ƙ ƴ), digits, apostrophes and combining marks
    (Yorùbá tones / dot-below), which a naive \\w regex would silently delete. strip_tones=True removes
    only tone diacritics (the dot-below of ẹ ọ ṣ is phonemic and kept); strip_ortho=True removes
    orthographic-convention marks (the Hausa breve) for the orthography-normalised WER."""
    s = unicodedata.normalize("NFD", s.lower())
    out = []
    for ch in s:
        cat = unicodedata.category(ch)
        if strip_tones and ch in TONE_MARKS:
            continue
        if strip_ortho and ch in ORTHO_MARKS:
            continue
        if cat[0] in ("L", "N", "M") or ch in "'’ʼ":
            out.append("'" if ch in "’ʼ" else ch)
        else:
            out.append(" ")
    s = unicodedata.normalize("NFC", "".join(out))
    # U+2019 is both the apostrophe and the closing quotation mark: an apostrophe that ends a word or stands
    # alone ('Ku zo.’ -> "zo '") is a quote, not part of the word. Word-initial / -internal ones ('ya'yan,
    # sa'ad) are kept.
    s = re.sub(r"'+(?=\s|$)", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def ctc_text(s: str) -> str:
    """Canonical character string used by the CTC head, the SAB segmentation and the ASR targets."""
    return normalize_text(s)


def tts_text(s: str) -> str:
    """TTS / alignment text: canonical characters without orthography-only marks."""
    return normalize_text(s, strip_ortho=True)


def near_duplicate_mask(queries: List[str], refs: List[str], ratio: float = 90.0, cover: float = 0.4) -> np.ndarray:
    """True for every query that is a near-duplicate of some ref (rapidfuzz ratio >= `ratio`), or that contains
    or is contained in one (>= `cover` of either text's word 4-grams shared; texts of >= 6 words). Both sides
    are compared after normalize_text. Used to keep repeated Bible passages (GEN/1CH genealogies, 1KI 12 ~
    2CH 10, 2CH 36:22 = EZR 1:1, ...) from crossing the held-out boundary."""
    from rapidfuzz import fuzz
    from rapidfuzz.process import cdist
    out = np.zeros(len(queries), dtype=bool)
    if not queries or not refs:
        return out
    q, r = [normalize_text(x) for x in queries], [normalize_text(x) for x in refs]
    for s in range(0, len(q), 2000):
        out[s:s + 2000] = cdist(q[s:s + 2000], r, scorer=fuzz.ratio, dtype=np.uint8, workers=-1).max(1) >= ratio

    def grams(t: str) -> set:
        w = t.split()
        return {tuple(w[i:i + 4]) for i in range(len(w) - 3)} if len(w) >= 6 else set()

    index: Dict[tuple, List[int]] = defaultdict(list)
    n_ref = []
    for ci, t in enumerate(r):
        g = grams(t)
        n_ref.append(len(g))
        for x in g:
            index[x].append(ci)
    for i, t in enumerate(q):
        g = grams(t)
        if out[i] or not g:
            continue
        hits = Counter(ci for x in g for ci in index.get(x, ()))
        out[i] = any(c >= cover * n_ref[ci] or c >= cover * len(g) for ci, c in hits.items())
    return out


def detok_caption(s: str) -> str:
    """Flickr8k captions are PTB-tokenised ('a man 's hat , outside .'). YFACC translation targets would
    otherwise teach the decoder a spacing that no other English source (FLEURS, WEB, HaVG) uses and that
    no reference outside Flickr8k contains. Idempotent."""
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r" (n't|'s|'re|'ve|'ll|'m|'d)\b", r"\1", s)
    s = re.sub(r" ([.,;:!?)\]])", r"\1", s)
    s = re.sub(r"([(\[]) ", r"\1", s)
    parts = s.split('"')
    if len(parts) % 2 == 1:  # balanced quotes: glue each quoted span to its content
        s = "".join(p if k % 2 == 0 else '"' + p.strip() + '"' for k, p in enumerate(parts))
    s = re.sub(r"\s+", " ", s).strip()
    return s[:1].upper() + s[1:]


def detect_repetition(text: str, n: int = 3, max_rep: int = 3) -> bool:
    """Looping detector (Gheini et al. 2023 observe n-gram loops on OOD pseudo-labels)."""
    toks = text.split()
    if len(toks) < n * max_rep:
        return False
    cnt = Counter(tuple(toks[i:i + n]) for i in range(len(toks) - n + 1))
    return max(cnt.values()) >= max_rep


# =============================================================================================
#                                           METRICS
# =============================================================================================
def error_stats(refs: List[str], hyps: List[str], unit: str = "word", strip_tones=False, strip_ortho=False):
    """Per-utterance (errors, ref_len) arrays so that corpus WER, bootstrap CIs and significance agree.
    unit: 'word' | 'char' (standard CER: spaces are characters) | 'char_nospace' (diagnostic only)."""
    errs, lens = [], []
    for r, h in zip(refs, hyps):
        r, h = normalize_text(r, strip_tones, strip_ortho), normalize_text(h, strip_tones, strip_ortho)
        if unit == "word":
            rs, hs = r.split(), h.split()
        elif unit == "char":
            rs, hs = list(r), list(h)
        elif unit == "char_nospace":
            rs, hs = list(r.replace(" ", "")), list(h.replace(" ", ""))
        else:
            raise ValueError(unit)
        errs.append(RFLevenshtein.distance(rs, hs))
        lens.append(max(1, len(rs)))
    return np.asarray(errs, dtype=np.float64), np.asarray(lens, dtype=np.float64)


def wer(refs, hyps, strip_tones=False, strip_ortho=False):
    e, n = error_stats(refs, hyps, "word", strip_tones, strip_ortho)
    return 100.0 * e.sum() / max(1.0, n.sum())


def cer(refs, hyps, strip_tones=False, nospace=False):
    e, n = error_stats(refs, hyps, "char_nospace" if nospace else "char", strip_tones)
    return 100.0 * e.sum() / max(1.0, n.sum())


def bleu(refs, hyps):
    return float(sacrebleu.corpus_bleu(hyps, [refs]).score)


def chrf(refs, hyps, word_order=2):
    return float(sacrebleu.corpus_chrf(hyps, [refs], word_order=word_order).score)


def sent_chrf(ref: str, hyp: str) -> float:
    if not ref.strip() or not hyp.strip():
        return 0.0
    return float(sacrebleu.sentence_chrf(hyp, [ref]).score)


def distinct_ratio(hyps: List[str]) -> float:
    """Share of distinct outputs — a collapsed decoder produces the same string for every input."""
    return len({normalize_text(h) for h in hyps}) / max(1, len(hyps))


def source_sensitivity(refs: List[str], hyps: List[str], n_perm: int = 5, seed: int = 0) -> float:
    """Source-Sensitivity Index: chrF++ against the true references minus chrF++ against references of
    OTHER inputs (random cyclic shifts, no fixed point). ≈0 means the outputs carry no information
    about their inputs (e.g. the v1 X->Y matrix, whose scores depended on the target column only)."""
    n = len(refs)
    if n < 2:
        return float("nan")
    base = chrf(refs, hyps)
    rng = np.random.default_rng(seed)
    sh = []
    for _ in range(n_perm):
        k = int(rng.integers(1, n))
        sh.append(chrf([refs[(i + k) % n] for i in range(n)], hyps))
    return base - float(np.mean(sh))


def bootstrap_ci(metric_fn, refs, hyps, n=1000, seed=0, alpha=0.05):
    rng = np.random.default_rng(seed)
    k = len(refs)
    vals = []
    for _ in range(n):
        idx = rng.integers(0, k, k)
        vals.append(metric_fn([refs[i] for i in idx], [hyps[i] for i in idx]))
    lo, hi = np.percentile(vals, [100 * alpha / 2, 100 * (1 - alpha / 2)])
    return float(lo), float(hi)


def error_rate_bootstrap(errs, lens, n=1000, seed=0, alpha=0.05):
    rng = np.random.default_rng(seed)
    k = len(errs)
    vals = []
    for _ in range(n):
        idx = rng.integers(0, k, k)
        vals.append(100.0 * errs[idx].sum() / max(1.0, lens[idx].sum()))
    lo, hi = np.percentile(vals, [100 * alpha / 2, 100 * (1 - alpha / 2)])
    return float(lo), float(hi)


def paired_bootstrap(metric_fn, refs, hyps_a, hyps_b, n=1000, seed=0, higher_is_better=True):
    """Koehn (2004) paired bootstrap: p-value that system B is NOT better than system A."""
    rng = np.random.default_rng(seed)
    k = len(refs)
    wins = 0
    for _ in range(n):
        idx = rng.integers(0, k, k)
        r = [refs[i] for i in idx]
        a = metric_fn(r, [hyps_a[i] for i in idx])
        b = metric_fn(r, [hyps_b[i] for i in idx])
        wins += int((b > a) if higher_is_better else (b < a))
    return 1.0 - wins / n


def paired_bootstrap_errors(err_a: np.ndarray, err_b: np.ndarray, n=1000, seed=0) -> float:
    """Paired bootstrap for error rates (WER/CER) on precomputed per-utterance edit counts. Both systems
    share the reference lengths, so comparing resampled error sums is comparing error rates."""
    rng = np.random.default_rng(seed)
    k = len(err_a)
    wins = 0
    for _ in range(n):
        idx = rng.integers(0, k, k)
        wins += int(err_b[idx].sum() < err_a[idx].sum())
    return 1.0 - wins / n


def dtw_path_cost(C: np.ndarray) -> Tuple[float, int]:
    """Anti-diagonal (wavefront) vectorised DTW. Returns (accumulated cost, length of the optimal path)."""
    n, m = C.shape
    D = np.full((n + 1, m + 1), np.inf)
    D[0, 0] = 0.0
    L = np.zeros((n + 1, m + 1), dtype=np.int64)
    for k in range(2, n + m + 1):
        i = np.arange(max(1, k - m), min(n, k - 1) + 1)
        j = k - i
        cand = np.stack([D[i - 1, j - 1], D[i - 1, j], D[i, j - 1]])  # diagonal, from above, from left
        arg = cand.argmin(0)
        D[i, j] = C[i - 1, j - 1] + cand[arg, np.arange(len(i))]
        pi = np.where(arg == 2, i, i - 1)
        pj = np.where(arg == 1, j, j - 1)
        L[i, j] = L[pi, pj] + 1
    return float(D[n, m]), int(L[n, m])


_MFCC_CACHE = {}


def mcd_dtw(ref: np.ndarray, hyp: np.ndarray, sr: int = 16000) -> float:
    """Mel-cepstral distortion (dB) with DTW alignment, c0 excluded, averaged over the DTW path.
    MFCCs of the natural-log mel POWER spectrum are halved to obtain log-AMPLITUDE cepstra, as in the
    classic definition MCD = (10/ln10)·sqrt(2·Σ_d (c_d - c'_d)^2)."""
    if sr not in _MFCC_CACHE:
        _MFCC_CACHE[sr] = torchaudio.transforms.MFCC(
            sample_rate=sr, n_mfcc=14, log_mels=True, melkwargs=dict(n_fft=1024, hop_length=256, n_mels=80))
    mf = _MFCC_CACHE[sr]
    a = 0.5 * mf(torch.from_numpy(ref).float()).T.numpy()[:, 1:]
    b = 0.5 * mf(torch.from_numpy(hyp).float()).T.numpy()[:, 1:]
    C = (10.0 / np.log(10.0)) * np.sqrt(2.0 * ((a[:, None, :] - b[None, :, :]) ** 2).sum(-1))
    cost, path_len = dtw_path_cost(C)
    return float(cost / path_len)


# =============================================================================================
#                          DATA HUB — download, mount, build manifests
# =============================================================================================
def _hf_token() -> Optional[str]:
    """HF token from the environment or the Kaggle secret 'HF_TOKEN' (optional: all sources are public)."""
    tok = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if tok or not IS_KAGGLE:
        return tok
    try:
        from kaggle_secrets import UserSecretsClient
        return UserSecretsClient().get_secret("HF_TOKEN")
    except Exception as e:  # the secret simply is not defined for this notebook
        LOG.info(f"no HF_TOKEN Kaggle secret ({type(e).__name__}); using anonymous Hugging Face access")
        return None


def hf_file(repo: str, filename: str, local_dir: str, repo_type: str = "dataset",
            revision: Optional[str] = None) -> str:
    from huggingface_hub import hf_hub_download
    return hf_hub_download(repo_id=repo, filename=filename, repo_type=repo_type, revision=revision,
                           local_dir=local_dir, token=_hf_token())


def hf_files(repo: str, revision: Optional[str] = None) -> List[str]:
    from huggingface_hub import list_repo_files
    return sorted(list_repo_files(repo, repo_type="dataset", revision=revision, token=_hf_token()))


_STREAM_ERRORS = (OSError, EOFError, zlib.error, tarfile.TarError, http.client.HTTPException)


def download_file(url: str, dst: str, retries: int = 4, timeout: int = 120) -> str:
    """Plain HTTPS download with retries (exponential back-off) and an atomic rename."""
    if os.path.exists(dst):
        return dst
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "kora/2.0"})
            with urllib.request.urlopen(req, timeout=timeout) as r, open(dst + ".part", "wb") as fo:
                shutil.copyfileobj(r, fo, length=1 << 20)
            os.replace(dst + ".part", dst)
            return dst
        except _STREAM_ERRORS as e:
            last = e
            LOG.warning(f"download failed ({attempt + 1}/{retries}) {url}: {e}")
            time.sleep(2 ** (attempt + 1))
    raise RuntimeError(f"could not download {url}: {last}")


def save_flac(path: str, wav: np.ndarray, sr: int):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sf.write(path + ".part.flac", np.clip(wav, -1.0, 1.0), sr, format="FLAC", subtype="PCM_16")
    os.replace(path + ".part.flac", path)


class DataHub:
    """Builds every manifest used by KORA. All steps are cached and idempotent; a source that cannot be
    obtained raises an error instead of silently shrinking the experiment. Manifests store file paths
    RELATIVE to the cache root, so a processed cache attached under /kaggle/input (any directory that
    contains manifests/fleurs.jsonl) is reused as-is by later sessions instead of re-downloading."""

    def __init__(self, cfg: KoraConfig):
        self.cfg = cfg
        self.d = cfg.data
        self.root = cfg.paths.cache_dir
        self.mdir = cfg.paths.manifest_dir
        os.makedirs(self.mdir, exist_ok=True)
        self.search_roots = ["/kaggle/input"] if os.path.isdir("/kaggle/input") else []
        if self.d.kaggle_slugs:
            import kagglehub
            for name, slug in self.d.kaggle_slugs.items():
                path = kagglehub.dataset_download(slug)
                LOG.info(f"kagglehub mounted {name} ({slug}) -> {path}")
                self.search_roots.append(path)
        self.cache_roots = [self.root] + self._attached_caches()
        if len(self.cache_roots) > 1:
            LOG.info(f"attached processed caches: {self.cache_roots[1:]}")

    # ----------------------------------------------------------------------- paths -----------
    def _attached_caches(self) -> List[str]:
        roots = []
        for base in self.search_roots:
            for depth in range(0, 4):
                pattern = os.path.join(base, *(["*"] * depth), "manifests", "fleurs.jsonl")
                roots += [os.path.dirname(os.path.dirname(h)) for h in glob.glob(pattern)]
        me = os.path.abspath(self.root)
        return [r for r in dict.fromkeys(os.path.abspath(r) for r in roots) if r != me]

    def rel(self, p: str) -> str:
        ap = os.path.abspath(p)
        for r in self.cache_roots:
            r = os.path.abspath(r)
            if ap.startswith(r + os.sep):
                return os.path.relpath(ap, r)
        return ap

    def resolve(self, p: str) -> str:
        if os.path.isabs(p):
            return p
        for r in self.cache_roots:
            q = os.path.join(r, p)
            if os.path.exists(q):
                return q
        return os.path.join(self.root, p)

    def save_manifest(self, name: str, rows: List[dict], file_keys: Sequence[str]):
        out = []
        for r in rows:
            r2 = dict(r)
            for k in file_keys:
                if r2.get(k):
                    r2[k] = self.rel(r2[k])
            out.append(r2)
        write_jsonl(os.path.join(self.mdir, name), out)

    def _manifest_path(self, name: str) -> str:
        path = os.path.join(self.mdir, name)
        if not os.path.exists(path):
            for r in self.cache_roots[1:]:
                q = os.path.join(r, "manifests", name)
                if os.path.exists(q):
                    shutil.copy2(q, path)
                    break
        return path

    def _cached(self, name: str, file_keys: Sequence[str]) -> Optional[List[dict]]:
        """A cached manifest is reused only if every file it references still exists (the scratch disk
        is wiped between Kaggle sessions unless a processed cache is attached)."""
        rows = read_jsonl(self._manifest_path(name))
        if not rows:
            return None
        for r in rows:
            for k in file_keys:
                if r.get(k):
                    p = self.resolve(r[k])
                    if not os.path.exists(p):
                        LOG.info(f"{name}: {r[k]} missing -> rebuilding")
                        return None
                    r[k] = p
        return rows

    def _cached_json(self, name: str):
        return load_json(self._manifest_path(name))

    def find(self, rel_pattern: str) -> List[str]:
        """Search attached / mounted datasets for `rel_pattern` (may contain directories)."""
        hits = []
        for root in self.search_roots:
            hits += glob.glob(os.path.join(root, "**", rel_pattern), recursive=True)
        return sorted(set(hits))

    def _open_stream(self, kind: str, src: str):
        if kind == "file":
            return open(src, "rb")
        req = urllib.request.Request(src, headers={"User-Agent": "kora/2.0"})
        return urllib.request.urlopen(req, timeout=120)

    # --------------------------------------------------------------------------- FLEURS ----
    def _fleurs_tsv(self, code: str, split: str) -> str:
        hits = self.find(os.path.join(code, f"{split}.tsv"))
        if hits:
            return hits[0]
        return hf_file(self.d.fleurs_repo, f"data/{code}/{split}.tsv", os.path.join(self.root, "fleurs_raw"))

    def _fleurs_audio(self, code: str, split: str, needed: set) -> Dict[str, str]:
        """file name -> wav path for every needed FLEURS utterance."""
        out_dir = os.path.join(self.root, "fleurs", code, split)
        os.makedirs(out_dir, exist_ok=True)
        index = {f: os.path.join(out_dir, f) for f in os.listdir(out_dir) if f.endswith(".wav")}
        if needed <= index.keys():
            return index
        # 1) already-extracted wavs in an attached dataset (the tarball extracts into <split>/)
        for hit in self.find(os.path.join(code, "audio", split)):
            if not os.path.isdir(hit):
                continue
            idx = {}
            for dp, _, files in os.walk(hit):
                for f in files:
                    if f.endswith(".wav"):
                        idx.setdefault(f, os.path.join(dp, f))
            if needed <= idx.keys():
                return idx
        # 2) the official tarball (attached copy first, otherwise the Hugging Face repo)
        tars = self.find(os.path.join(code, "audio", f"{split}.tar.gz"))
        tar_path = tars[0] if tars else hf_file(self.d.fleurs_repo, f"data/{code}/audio/{split}.tar.gz",
                                                os.path.join(self.root, "fleurs_raw"))
        LOG.info(f"extracting {tar_path}")
        with tarfile.open(tar_path, "r|gz") as tf:
            for m in tf:
                base = os.path.basename(m.name)
                if m.isfile() and base in needed and base not in index:
                    dst = os.path.join(out_dir, base)
                    with tf.extractfile(m) as src, open(dst + ".part", "wb") as fo:
                        shutil.copyfileobj(src, fo)
                    os.replace(dst + ".part", dst)
                    index[base] = dst
        if self.d.delete_archives and not tars:
            os.remove(tar_path)
        return index

    def build_fleurs(self) -> Tuple[List[dict], Dict[str, Dict[str, str]]]:
        cached = self._cached("fleurs.jsonl", ["audio"])
        par = self._cached_json("fleurs_parallel.json")
        if cached is not None and par is not None:
            return cached, par
        parallel: Dict[str, Dict[str, str]] = defaultdict(dict)
        split_of_sid: Dict[str, set] = defaultdict(set)
        rows_by: Dict[Tuple[str, str], List[dict]] = {}
        for lang in self.cfg.all_langs:
            code = self.d.fleurs_codes[lang]
            for split in ["train", "dev", "test"]:
                tsv = self._fleurs_tsv(code, split)
                rows = []
                with open(tsv, encoding="utf-8") as f:
                    for line in f:
                        if not line.strip():
                            continue
                        v = line.rstrip("\n").split("\t")
                        if len(v) < 7:
                            raise ValueError(f"malformed FLEURS row in {tsv}: {line[:120]!r}")
                        sid, fname, raw = v[0], v[1], v[2].strip()
                        rows.append(dict(sid=sid, fname=fname, raw=raw, nsamp=int(v[5]), gender=v[6].strip()))
                        parallel[sid].setdefault(lang, raw)
                        split_of_sid[sid].add(split)
                if not rows:
                    raise RuntimeError(f"FLEURS {code}/{split} is empty ({tsv})")
                rows_by[(lang, split)] = rows
        heldout = {sid for sid, s in split_of_sid.items() if ("dev" in s or "test" in s)}
        manifest = []
        for (lang, split), rows in rows_by.items():
            if lang == "en":
                continue  # English is used as text (translation targets) only
            if split == "train":
                rows = [r for r in rows if r["sid"] not in heldout]  # no sentence leakage across splits
                if self.d.max_fleurs_train_per_lang:
                    rows = rows[: self.d.max_fleurs_train_per_lang]
            code = self.d.fleurs_codes[lang]
            index = self._fleurs_audio(code, split, {r["fname"] for r in rows})
            missing = [r["fname"] for r in rows if r["fname"] not in index]
            if len(missing) > 0.01 * len(rows):
                raise RuntimeError(f"FLEURS {code}/{split}: {len(missing)}/{len(rows)} audio files missing")
            if missing:
                LOG.warning(f"FLEURS {code}/{split}: {len(missing)} TSV rows have no audio file")
            kept = 0
            for i, r in enumerate(rows):
                if r["fname"] not in index:
                    continue
                dur = r["nsamp"] / 16000.0
                if not (self.d.min_dur <= dur <= self.d.eval_max_dur):
                    continue
                manifest.append(dict(uid=f"fleurs_{lang}_{split}_{i}", lang=lang, split=split, audio=index[r["fname"]],
                                     dur=round(dur, 3), text=r["raw"], sid=r["sid"], gender=r["gender"],
                                     domain="fleurs"))
                kept += 1
            if kept == 0:
                raise RuntimeError(f"FLEURS {code}/{split}: no usable utterance")
        self.save_manifest("fleurs.jsonl", manifest, ["audio"])
        save_json(os.path.join(self.mdir, "fleurs_parallel.json"), parallel)
        LOG.info(f"FLEURS: {len(manifest)} utterances, {len(parallel)} parallel sentence ids")
        return manifest, dict(parallel)

    # --------------------------------------------------------------------------- eBible ----
    def build_ebible(self) -> Tuple[Dict[str, Dict[str, str]], Dict[str, Dict[str, List[str]]]]:
        """Verse-aligned eBible corpus (one line per verse, aligned with metadata/vref.txt). Returns
        ({lang: {vref: verse}}, {lang: {head vref: [vrefs merged into that line]}}): a '<range>' line means
        that verse is merged into the previous non-empty line, so a line may span several verses."""
        cached, ranges = self._cached_json("ebible.json"), self._cached_json("ebible_ranges.json")
        if cached and ranges is not None:
            return cached, ranges
        d = self.d
        edir = os.path.join(self.root, "ebible")

        def get(rel_path: str) -> str:
            hits = self.find(rel_path) or self.find(os.path.basename(rel_path))
            if hits:
                return hits[0]
            return download_file(f"{d.ebible_base}/{rel_path}", os.path.join(edir, os.path.basename(rel_path)))

        with open(get("metadata/vref.txt"), encoding="utf-8") as f:
            vrefs = [l.strip() for l in f.read().split("\n")]
        out, ranges = {}, {}
        for lang, tid in d.ebible_ids.items():
            with open(get(f"corpus/{tid}.txt"), encoding="utf-8") as f:
                lines = f.read().split("\n")
            if abs(len(lines) - len(vrefs)) > 1:
                raise RuntimeError(f"eBible {tid}: {len(lines)} lines but vref.txt has {len(vrefs)}")
            texts, rg, head = {}, {}, None
            for v, t in zip(vrefs, lines):
                t = t.strip()
                if not v or not t:
                    continue
                if t == "<range>":
                    if head is not None:
                        rg.setdefault(head, [head]).append(v)
                    continue
                texts[v], head = t, v
            if len(texts) < 5000:
                raise RuntimeError(f"eBible {tid}: only {len(texts)} verses")
            out[lang], ranges[lang] = texts, rg
        save_json(os.path.join(self.mdir, "ebible.json"), out)
        save_json(os.path.join(self.mdir, "ebible_ranges.json"), ranges)
        LOG.info("eBible verses: " + ", ".join(f"{l}={len(v)}" for l, v in out.items()))
        return out, ranges

    @staticmethod
    def _parse_vref(v: str) -> Tuple[str, int, int]:
        book, cv = v.split(" ")
        c, vv = cv.split(":")
        return book, int(c), int(vv)

    WEB_RENUMBERED = {"MAT 23:13", "MAT 23:14"}  # WEB (Majority Text) has these two verses in the other order

    @classmethod
    def _versification_suspects(cls, ebible: Dict[str, Dict[str, str]], lang: str,
                                lang_ranges: Dict[str, List[str]]) -> set:
        """Verse ids whose English (WEB) text may not translate the `lang` verse of the same number: the known
        WEB renumberings, and both neighbours of an isolated verse that the `lang` edition omits (a text-
        critical omission such as MAT 23:14 is where editions renumber). Merged-range members are not gaps."""
        out = set(cls.WEB_RENUMBERED)
        L = ebible.get(lang, {})
        merged = {x for members in lang_ranges.values() for x in members}
        for v in ebible.get("en", {}):
            if v in L or v in merged:
                continue
            b, c, n = cls._parse_vref(v)
            prev, nxt = f"{b} {c}:{n - 1}", f"{b} {c}:{n + 1}"
            if prev in L and nxt in L:
                out.update([prev, nxt])
        return out

    def _match_verses(self, lang: str, recs: List[dict], ebible: Dict[str, Dict[str, str]],
                      ranges: Dict[str, Dict[str, List[str]]], min_score: float = 80.0):
        """BibleTTS file names are NOT reliable verse ids (e.g. Yorùbá COL_001_Verse_010 holds the text of
        COL 1:9, Hausa EZR_001_Verse_002 the text of EZR 1:3). Every clip is therefore matched by TEXT
        against the same (Biblica open) translation in eBible, within its book and ±1 chapter; the English
        reference is the World English Bible text of every verse that line covers."""
        from rapidfuzz import fuzz
        by_ch = defaultdict(list)
        for v, t in ebible.get(lang, {}).items():
            b, c, _ = self._parse_vref(v)
            by_ch[(b, c)].append((v, normalize_text(t)))
        en, rg = ebible.get("en", {}), ranges.get(lang, {})
        suspects = self._versification_suspects(ebible, lang, rg)
        for r in recs:
            r["vref_file"], r["vref"], r["vref_score"], r["en"] = r.get("vref"), None, 0.0, None
            m = self._VREF_RE.match(r["stem"].split("__")[-1])
            q = normalize_text(r["text"])
            if not m or not q:
                continue
            b, c = m.group(1), int(m.group(2))
            cands = by_ch.get((b, c - 1), []) + by_ch.get((b, c), []) + by_ch.get((b, c + 1), [])
            if not cands:
                continue
            best_v, best_s = max(((v, fuzz.ratio(q, t)) for v, t in cands), key=lambda x: x[1])
            best_t = next(t for v, t in cands if v == best_v)
            # ratio >= 80 alone also accepts ~70 % of a long verse, or a verse plus part of the next one
            if best_s >= min_score and 0.9 <= len(q) / max(1, len(best_t)) <= 1.1:
                # the clip is the whole verse (line): its English reference is exact
                members = rg.get(best_v, [best_v])
                ref = "" if any(x in suspects for x in members) else " ".join(en[x] for x in members if x in en).strip()
                r["vref"], r["vref_score"], r["en"] = best_v, float(best_s), ref or None
                r["vrefs_covered"] = members
            elif len(q) >= 20:
                # sub-verse segment (frequent in Hausa: long verses are split into several clips). The verse
                # is identified (for leakage exclusion) but a whole-verse English text would not be a
                # translation of the clip, so the clip gets NO English reference.
                pv, ps = max(((v, fuzz.partial_ratio(q, t)) for v, t in cands), key=lambda x: x[1])
                if ps >= 95:
                    r["vref"], r["vref_score"], r["vrefs_covered"], r["partial"] = pv, float(ps), [pv], True
        # a verse read by more than one clip is split across them: none of them is the whole verse
        n_clips = Counter(v for r in recs for v in r.get("vrefs_covered", []))
        for r in recs:
            if not r.get("partial") and r["vref"] and any(n_clips[v] > 1 for v in r.get("vrefs_covered", [])):
                r["partial"], r["en"] = True, None

    # ------------------------------------------------------------------------- BibleTTS ----
    _VREF_RE = re.compile(r"^([0-9A-Z]{3})_(\d+)_Verse_(\d+)$")

    @classmethod
    def _vref(cls, basename: str) -> Optional[str]:
        m = cls._VREF_RE.match(basename)
        if not m or int(m.group(3)) == 0:  # Verse_000 = psalm superscription
            return None
        return f"{m.group(1)} {int(m.group(2))}:{int(m.group(3))}"

    def _read_bibletts(self, kind: str, src: str, out_dir: str) -> List[dict]:
        """Streams one BibleTTS archive (<lang>/<split>/<BOOK>/<BOOK>_<ccc>_Verse_<vvv>.flac + .txt, 48 kHz)
        in its native order (dev -> test -> train): the whole official dev/test books and the first train
        verses up to the utterance/hour cap. The multi-GB tarball is never stored. Every kept clip is saved
        as 16 kHz FLAC (recognition) and 24 kHz FLAC (TTS targets, reference spectrograms, MCD)."""
        d = self.d
        caps = {"dev": d.bibletts_max_dev_utts, "test": 10 ** 6, "train": d.bibletts_max_train_utts_per_lang}
        hours_cap = d.bibletts_max_train_hours_per_lang * 3600.0
        audio: Dict[str, dict] = {}
        texts: Dict[str, str] = {}
        n_split = Counter()
        train_secs, after_full = 0.0, 0
        with self._open_stream(kind, src) as fobj, tarfile.open(fileobj=fobj, mode="r|gz") as tf:
            for m in tf:
                if not m.isfile():
                    continue
                key, ext = os.path.splitext(os.path.normpath(m.name))
                ext = ext.lower()
                if ext not in (".flac", ".txt"):
                    continue
                parts = key.strip("/").split("/")
                split = parts[1] if len(parts) >= 4 and parts[1] in caps else "train"
                train_full = n_split["train"] >= caps["train"] or train_secs >= hours_cap
                if ext == ".txt":  # kept whatever the member order (a transcript may precede its audio)
                    texts[key] = tf.extractfile(m).read().decode("utf-8").strip()
                    if train_full and all(k in texts for k in audio):
                        break
                    continue
                if split == "train" and train_full:
                    after_full += 1
                    if after_full > 200:  # a transcript that never comes must not stream the whole archive
                        break
                    continue
                if n_split[split] >= caps[split]:
                    continue
                wav, sr = sf.read(io.BytesIO(tf.extractfile(m).read()), dtype="float32", always_2d=True)
                wav = wav.mean(1)
                dur = len(wav) / sr
                if not (d.min_dur <= dur <= d.eval_max_dur):
                    continue
                stem = key.strip("/").replace("/", "__")
                p16 = os.path.join(out_dir, "16k", f"{stem}.flac")
                p24 = os.path.join(out_dir, "24k", f"{stem}.flac")
                save_flac(p16, resample(wav, sr, 16000), 16000)
                save_flac(p24, resample(wav, sr, 24000), 24000)
                audio[key] = dict(stem=stem, audio=p16, audio24=p24, dur=round(dur, 3), orig_split=split,
                                  vref=self._vref(parts[-1]), book=parts[-1].split("_")[0],
                                  chapter="_".join(parts[-1].split("_")[:2]))
                n_split[split] += 1
                if split == "train":
                    train_secs += dur
        return [dict(a, text=texts.get(k, "")) for k, a in audio.items()]

    def _stream_bibletts(self, lang: str, out_dir: str) -> List[dict]:
        name = self.d.bibletts_names[lang]
        sources = [("file", p) for p in self.find(f"{name}.tgz")] + \
                  [("url", f"{m}/{name}.tgz") for m in self.d.bibletts_mirrors]
        failures = []
        for kind, src in sources:
            LOG.info(f"BibleTTS[{lang}] streaming from {src}")
            try:
                recs = self._read_bibletts(kind, src, out_dir)
            except _STREAM_ERRORS as e:  # network/archive error on this mirror: the same file on the next one
                failures.append(f"{src}: {type(e).__name__}: {e}")
                LOG.warning(f"BibleTTS source failed {src}: {e}")
                continue
            if not recs:
                raise RuntimeError(f"BibleTTS[{lang}]: archive {src} contained no usable verse")
            return recs
        raise RuntimeError(f"BibleTTS[{lang}] unavailable from every source:\n" + "\n".join(failures))

    def build_bibletts(self, ebible: Dict[str, Dict[str, str]], ranges: Dict[str, Dict[str, List[str]]]) -> List[dict]:
        cached = self._cached("bibletts.jsonl", ["audio", "audio24"])
        if cached is not None:
            return cached
        d = self.d
        manifest = []
        for lang in d.african_langs:
            recs = self._stream_bibletts(lang, os.path.join(self.root, "bibletts", lang))
            self._match_verses(lang, recs, ebible, ranges)
            dev = [r for r in recs if r["orig_split"] == "dev" and r["text"]]
            test = [r for r in recs if r["orig_split"] == "test" and r["text"]]
            train = [r for r in recs if r["orig_split"] == "train"]
            if len(test) < d.bibletts_min_test_utts:  # top up with WHOLE held-out chapters (no adjacent verses)
                by_ch = defaultdict(list)
                for r in train:
                    by_ch[r["chapter"]].append(r)
                for ch in sorted(by_ch, key=lambda c: stable_hash(f"{lang}|{c}")):
                    if len(test) >= d.bibletts_min_test_utts:
                        break
                    test += [r for r in by_ch.pop(ch) if r["text"]]
                train = [r for rows in by_ch.values() for r in rows]
            if not dev or not test:
                raise RuntimeError(f"BibleTTS[{lang}]: empty dev ({len(dev)}) or test ({len(test)}) split")
            # repeated passages (1KI 12 ~ 2CH 10, GEN ~ 1CH genealogies, ...): an adaptation clip that repeats a
            # held-out one would train the TTS voice (gold text) and the UDA branches on a test sentence
            twin = near_duplicate_mask([r["text"] for r in train], [r["text"] for r in dev + test if r["text"]])
            if twin.any():
                LOG.info(f"BibleTTS[{lang}]: {int(twin.sum())} adaptation clips repeat a held-out verse, dropped")
                train = [r for r, t in zip(train, twin) if not t]
            for split, rows in [("target_dev", dev), ("target_test", test), ("target_adapt", train)]:
                for r in rows:
                    manifest.append(dict(uid=f"bible_{lang}_{r['stem']}", lang=lang, split=split, audio=r["audio"],
                                         audio24=r["audio24"], dur=r["dur"], text=r["text"], vref=r["vref"],
                                         vref_file=r["vref_file"], vref_score=r["vref_score"],
                                         vrefs_covered=r.get("vrefs_covered", []), chapter=r["chapter"],
                                         partial_verse=bool(r.get("partial")),
                                         en=r["en"], domain="bible", orig_split=r["orig_split"],
                                         gold_hidden=(split == "target_adapt")))
            n_match = sum(1 for r in recs if r["vref"] and not r.get("partial"))
            n_part = sum(1 for r in recs if r.get("partial"))
            n_shift = sum(1 for r in recs if r["vref"] and r["vref"] != r["vref_file"])
            LOG.info(f"BibleTTS[{lang}]: dev {len(dev)} | test {len(test)} | adapt {len(train)} "
                     f"({sum(r['dur'] for r in train) / 3600:.1f} h) | whole-verse match {n_match}/{len(recs)}, "
                     f"sub-verse segments {n_part}, file-name verse id wrong for {n_shift}")
        self.save_manifest("bibletts.jsonl", manifest, ["audio", "audio24"])
        return manifest

    def bible_text_pairs(self, ebible: Dict[str, Dict[str, str]], ranges: Dict[str, Dict[str, List[str]]],
                         bible: List[dict]) -> List[dict]:
        """Verse-aligned Bible text for target-domain MT (text-only domain adaptation). Every CHAPTER that
        has audio anywhere in this experiment (adapt/dev/test, any language; by file name AND by text
        match) is excluded, so no transcript or translation of a used clip can reach the model through text.
        The Bible also repeats itself across chapters (Genesis genealogies in 1 Chronicles, 2 Chr 36:22 =
        Ezra 1:1, Nehemiah 7 ~ Ezra 2): a verse whose text in ANY language — English included — is a
        near-duplicate of a clip's transcript or English reference, contains one or is contained in one
        (near_duplicate_mask; e.g. GEN 10:18 ⊃ 1CH 1:16), is excluded as well.
        Verses merged into multi-verse lines in any language are skipped (no 1:1 alignment)."""
        used_ch = set()
        for b in bible:
            used_ch.add(b.get("chapter", ""))
            for v in [b.get("vref"), b.get("vref_file")] + list(b.get("vrefs_covered", [])):
                if v:
                    bk, c, _ = self._parse_vref(v)
                    used_ch.add(f"{bk}_{c:03d}")
        merged = {v for rg in ranges.values() for members in rg.values() for v in members}
        merged |= set().union(*[self._versification_suspects(ebible, l, ranges.get(l, {}))
                                for l in self.cfg.all_langs if l != "en"])  # not 1:1 with WEB either
        langs = self.cfg.all_langs
        pool = []
        for v in ebible.get("en", {}):
            bk, c, _ = self._parse_vref(v)
            if f"{bk}_{c:03d}" not in used_ch and v not in merged:
                pool.append(v)
        pool = sorted(pool, key=lambda v: stable_hash("ebible|" + v))
        used_txt = defaultdict(set)
        for b in bible:
            if b.get("text"):
                used_txt[b["lang"]].add(normalize_text(b["text"]))
            if b.get("en"):
                used_txt["en"].add(normalize_text(b["en"]))
        used_txt = {l: sorted(t) for l, t in used_txt.items()}
        out, n_dup = [], 0
        for s in range(0, len(pool), 2000):
            rows = [{l: ebible[l][v] for l in langs if v in ebible.get(l, {})} for v in pool[s:s + 2000]]
            dup = np.zeros(len(rows), dtype=bool)
            for l, choices in used_txt.items():
                idx = [i for i, r in enumerate(rows) if l in r]
                if idx:
                    dup[np.asarray(idx)] |= near_duplicate_mask([rows[i][l] for i in idx], choices)
            n_dup += int(dup.sum())
            out += [dict(vref=v, **r) for v, r, d in zip(pool[s:s + 2000], rows, dup) if not d and len(r) >= 2]
            if len(out) >= self.d.ebible_max_verses:
                break
        LOG.info(f"eBible MT: {min(len(out), self.d.ebible_max_verses)} verses; {n_dup} near-duplicates of used "
                 f"clips (parallel passages) excluded")
        return out[: self.d.ebible_max_verses]

    # ---------------------------------------------------------------- Hausa Visual Genome ----
    HAVG_TXT = {"train": "hausa-visual-genome-train.txt", "dev": "hausa-visual-genome-dev.txt",
                "test": "hausa-visual-genome-test.txt", "challenge": "hausa-visual-genome-challenge-test-set.txt"}
    HAVG_PARQUET = {"train": "train", "validation": "dev", "test": "test", "challenge_test": "challenge"}

    def build_havg(self) -> List[dict]:
        cached = self._cached("havg.jsonl", ["image"])
        if cached is not None:
            return cached
        found = {s: self.find(f) for s, f in self.HAVG_TXT.items()}
        if all(found.values()):
            manifest = self._havg_from_lindat_txt({s: h[0] for s, h in found.items()})
        else:
            manifest = self._havg_from_parquet(os.path.join(self.root, "havg", "images"))
        for s in ["train", "test", "challenge"]:
            if not any(m["split"] == s for m in manifest):
                raise RuntimeError(f"Hausa Visual Genome split '{s}' is empty")
        if self.d.havg_max_train:
            tr = [m for m in manifest if m["split"] == "train"][: self.d.havg_max_train]
            manifest = tr + [m for m in manifest if m["split"] != "train"]
        self.save_manifest("havg.jsonl", manifest, ["image"])
        LOG.info(f"HaVG: {len(manifest)} image-caption pairs {dict(Counter(m['split'] for m in manifest))}")
        return manifest

    @staticmethod
    def _havg_row(uid, split, image, x, y, w, h, en, ha) -> dict:
        return dict(uid=uid, split=split, image=image, box=[int(float(x)), int(float(y)), int(float(w)), int(float(h))],
                    en=str(en).strip(), ha=str(ha).strip())

    def _havg_from_lindat_txt(self, files: Dict[str, str]) -> List[dict]:
        """Official LINDAT layout: hausa-visual-genome-<split>.txt next to hausa-visual-genome-<split>.images/,
        tab-separated: image id, X, Y, Width, Height, English, Hausa."""
        out = []
        for split, txt in files.items():
            img_dir = os.path.splitext(txt)[0] + ".images"
            with open(txt, encoding="utf-8") as f:
                for i, line in enumerate(f):
                    if not line.strip():
                        continue
                    v = line.rstrip("\n").split("\t")
                    if len(v) != 7:
                        raise ValueError(f"malformed HaVG row {txt}:{i + 1}")
                    ip = os.path.join(img_dir, f"{v[0]}.jpg")
                    if not os.path.exists(ip):
                        raise FileNotFoundError(f"HaVG image missing: {ip}")
                    out.append(self._havg_row(f"havg_{split}_{i}", split, ip, *v[1:5], v[5], v[6]))
        return out

    def _havg_from_parquet(self, img_dir: str) -> List[dict]:
        """HausaNLP/HausaVG parquet export (columns: image, X, Y, Width, Height, en_text, ha_text)."""
        import pyarrow.parquet as pq
        os.makedirs(img_dir, exist_ok=True)
        files = [f for f in hf_files(self.d.havg_repo, self.d.havg_revision) if f.endswith(".parquet")]
        out = []
        for f in files:
            split = self.HAVG_PARQUET.get(f.split("/")[-2])
            if split is None:
                continue
            lp = hf_file(self.d.havg_repo, f, os.path.join(self.root, "havg", "parquet"), revision=self.d.havg_revision)
            for batch in pq.ParquetFile(lp).iter_batches(batch_size=256):
                d = batch.to_pydict()
                for j in range(len(d["en_text"])):
                    b = d["image"][j]["bytes"]
                    ip = os.path.join(img_dir, f"{hashlib.md5(b).hexdigest()}.jpg")
                    if not os.path.exists(ip):
                        with open(ip + ".part", "wb") as fo:
                            fo.write(b)
                        os.replace(ip + ".part", ip)
                    out.append(self._havg_row(f"havg_{split}_{len(out)}", split, ip, d["X"][j], d["Y"][j],
                                              d["Width"][j], d["Height"][j], d["en_text"][j], d["ha_text"][j]))
            if self.d.delete_archives:
                os.remove(lp)
        if not out:
            raise RuntimeError(f"no HaVG rows read from {self.d.havg_repo}@{self.d.havg_revision}")
        return out

    # ---------------------------------------------------------- YFACC + Flickr8k (REAL) ----
    def _flickr8k(self, needed: set) -> Tuple[Dict[str, str], Dict[str, str]]:
        """Flickr8k images (only those in `needed`) and English captions {'<img>.jpg#k': caption}.
        Captions come from the official Flickr8k.token.txt; the HF parquet captions are the fallback."""
        img_dir = os.path.join(self.root, "flickr8k", "images")
        os.makedirs(img_dir, exist_ok=True)
        have = {}
        for root in self.cache_roots:
            dd = os.path.join(root, "flickr8k", "images")
            if os.path.isdir(dd):
                for f in os.listdir(dd):
                    have.setdefault(f, os.path.join(dd, f))
        caps = self._cached_json("flickr8k_captions.json") or {}
        if not (needed <= have.keys() and caps):
            import pyarrow.parquet as pq
            for f in [f for f in hf_files(self.d.flickr8k_repo) if f.endswith(".parquet")]:
                lp = hf_file(self.d.flickr8k_repo, f, os.path.join(self.root, "flickr8k", "parquet"))
                for batch in pq.ParquetFile(lp).iter_batches(batch_size=64):
                    d = batch.to_pydict()
                    for j, im in enumerate(d["image"]):
                        name = os.path.basename(im.get("path") or "")
                        if not name:
                            raise RuntimeError(f"{self.d.flickr8k_repo}: image without a file name")
                        for k in range(5):
                            c = d.get(f"caption_{k}")
                            if c is not None and c[j]:
                                caps.setdefault(f"{name}#{k}", c[j].strip())
                        if name in needed and name not in have:
                            ip = os.path.join(img_dir, name)
                            with open(ip + ".part", "wb") as fo:
                                fo.write(im["bytes"])
                            os.replace(ip + ".part", ip)
                            have[name] = ip
                if self.d.delete_archives:
                    os.remove(lp)
            # the official token file wins over the parquet captions when it is reachable
            try:
                hits = self.find("Flickr8k.token.txt")
                if hits:
                    with open(hits[0], encoding="utf-8") as fo:
                        data = fo.read()
                else:
                    zp = download_file(self.d.flickr8k_text_url, os.path.join(self.root, "flickr8k", "Flickr8k_text.zip"))
                    with zipfile.ZipFile(zp) as z:
                        name = next(n for n in z.namelist() if n.endswith("Flickr8k.token.txt"))
                        data = z.read(name).decode("utf-8")
                for line in data.splitlines():
                    if "\t" in line:
                        k_, c_ = line.split("\t", 1)
                        caps[k_.strip()] = c_.strip()
            except (RuntimeError, StopIteration, zipfile.BadZipFile) as e:
                LOG.warning(f"official Flickr8k captions unavailable ({e}); using the parquet captions")
            save_json(os.path.join(self.mdir, "flickr8k_captions.json"), caps)
        missing = needed - have.keys()
        if len(missing) > 0.02 * max(1, len(needed)):
            raise RuntimeError(f"Flickr8k: {len(missing)}/{len(needed)} YFACC images not found")
        return have, caps

    def build_yfacc(self) -> List[dict]:
        """YFACC (Olaleye, Oneață & Kamper, SLT 2023): 6k REAL spoken Yorùbá translations of Flickr8k
        captions (one speaker, 48 kHz, padded to 8 s -> silence-trimmed, 16 kHz). Layout of yfacc_v6.tar.gz:
        flickr_audio_yoruba_{train,dev,test}/S001_<img>_<k>.wav and
        Flickr8k_text/Flickr8k.token.{train,dev,test}_yoruba.txt ('<img>.jpg#<k>\\t<Yorùbá caption>')."""
        cached = self._cached("yfacc.jsonl", ["audio", "image"])
        if cached is not None:
            return [dict(r, en=detok_caption(r["en"])) for r in cached]  # manifests written before detok
        out_dir = os.path.join(self.root, "yfacc")
        sources = [("file", p) for p in self.find("yfacc_v6.tar.gz")] + [("url", u) for u in self.d.yfacc_urls]
        audio: Dict[str, dict] = {}
        texts: Dict[str, str] = {}
        failures = []
        for kind, src in sources:
            LOG.info(f"YFACC streaming from {src}")
            try:
                with self._open_stream(kind, src) as fobj, tarfile.open(fileobj=fobj, mode="r|gz") as tf:
                    for m in tf:
                        if not m.isfile():
                            continue
                        base = os.path.basename(m.name)
                        if base.endswith(".wav") and "flickr_audio_yoruba_" in m.name:
                            split = m.name.split("flickr_audio_yoruba_")[1].split("/")[0]
                            stem = base[:-4]
                            if stem.count("_") < 2:
                                continue
                            spk, rest = stem.split("_", 1)
                            img, k = rest.rsplit("_", 1)
                            p = os.path.join(out_dir, "16k", split, stem + ".flac")
                            if not os.path.exists(p):
                                wav, sr = sf.read(io.BytesIO(tf.extractfile(m).read()), dtype="float32", always_2d=True)
                                save_flac(p, resample(trim_silence(wav.mean(1), sr), sr, 16000), 16000)
                            audio[f"{img}.jpg#{k}"] = dict(split=split, audio=p, dur=round(sf.info(p).duration, 3),
                                                            speaker=spk, stem=stem)
                        elif base.startswith("Flickr8k.token.") and base.endswith("_yoruba.txt"):
                            for line in tf.extractfile(m).read().decode("utf-8").splitlines():
                                if "\t" in line:
                                    k_, t_ = line.split("\t", 1)
                                    if t_.strip():
                                        texts[k_.strip()] = t_.strip()
                break
            except _STREAM_ERRORS as e:
                failures.append(f"{src}: {type(e).__name__}: {e}")
                LOG.warning(f"YFACC source failed {src}: {e}")
                audio, texts = {}, {}
        if not audio or not texts:
            raise RuntimeError("YFACC unavailable from every source:\n" + "\n".join(failures))
        images, caps = self._flickr8k({k.split("#")[0] for k in audio if k in texts})
        rows = []
        for key, a in sorted(audio.items()):
            img = key.split("#")[0]
            if key not in texts or img not in images or key not in caps:
                continue
            if not (self.d.min_dur <= a["dur"] <= self.d.eval_max_dur):
                continue
            rows.append(dict(uid=f"yfacc_{a['split']}_{a['stem']}", split=a["split"], audio=a["audio"], dur=a["dur"],
                             lang="yo", yo=texts[key], en=detok_caption(caps[key]), image=images[img], box=None,
                             domain="yfacc", speaker=a["speaker"], flickr_key=key))
        for s in ["train", "dev", "test"]:
            if not any(r["split"] == s for r in rows):
                raise RuntimeError(f"YFACC split '{s}' is empty")
        self.save_manifest("yfacc.jsonl", rows, ["audio", "image"])
        LOG.info(f"YFACC (real speech + real images): {dict(Counter(r['split'] for r in rows))}")
        return rows

    # ---------------------------------------------------------------- visual feature cache ----
    @torch.no_grad()
    def build_visual_cache(self, rows: List[dict], device) -> Tuple[str, Dict[str, int]]:
        """SigLIP features per (image, region): [global, region, grid^2 patch tokens] x 768, fp16 memmap.
        Rows without a box (Flickr8k) use the whole image as the region."""
        idx_name = "vis_index.json"
        rel_arr = os.path.join("vis", "vis_feats.f16")
        index = {r["uid"]: i for i, r in enumerate(rows)}
        old = self._cached_json(idx_name)
        arr_p = self.resolve(rel_arr)
        if old == index and os.path.exists(arr_p):
            return arr_p, index
        arr_p = os.path.join(self.root, rel_arr)
        from PIL import Image
        from transformers import SiglipVisionModel
        vis = SiglipVisionModel.from_pretrained(self.cfg.model.vision_model).to(device).eval()
        if torch.device(device).type == "cuda":
            vis = vis.half()
        size = int(vis.config.image_size)
        dim = self.cfg.model.vis_dim
        if vis.config.hidden_size != dim:
            raise ValueError(f"vis_dim={dim} but {self.cfg.model.vision_model} has hidden size {vis.config.hidden_size}")
        n_tok = 2 + self.d.vis_grid ** 2

        def proc(images):
            # SigLIP preprocessing: bicubic resize to image_size, [0,1] rescale, mean = std = 0.5
            arr = [np.asarray(im.resize((size, size), Image.BICUBIC), dtype=np.float32) / 255.0 for im in images]
            x = torch.from_numpy(np.stack(arr)).permute(0, 3, 1, 2)
            return (x - 0.5) / 0.5

        os.makedirs(os.path.dirname(arr_p), exist_ok=True)
        mm = np.memmap(arr_p + ".tmp", dtype=np.float16, mode="w+", shape=(max(1, len(rows)), n_tok, dim))
        bs = 32
        dt = next(vis.parameters()).dtype
        for s in range(0, len(rows), bs):
            chunk = rows[s:s + bs]
            fulls, crops = [], []
            for r in chunk:
                with Image.open(r["image"]) as src:
                    im = src.convert("RGB")
                W, H = im.size
                if r.get("box"):
                    x, y, w, h = r["box"]
                    x0, y0 = max(0, min(x, W - 16)), max(0, min(y, H - 16))
                    x1, y1 = min(W, max(x0 + 16, x + w)), min(H, max(y0 + 16, y + h))
                    crops.append(im.crop((x0, y0, x1, y1)))
                else:
                    crops.append(im)
                fulls.append(im)
            o = vis(pixel_values=proc(fulls + crops).to(device, dt))
            pooled = o.pooler_output.float()
            tokens = o.last_hidden_state.float()
            n = len(chunk)
            g = int(round(math.sqrt(tokens.shape[1])))
            grid = tokens[:n].transpose(1, 2).reshape(n, dim, g, g)
            grid = F.adaptive_avg_pool2d(grid, self.d.vis_grid).flatten(2).transpose(1, 2)
            feats = torch.cat([pooled[:n, None], pooled[n:, None], grid], dim=1)
            mm[s:s + n] = feats.cpu().numpy().astype(np.float16)
        mm.flush()
        del mm, vis
        os.replace(arr_p + ".tmp", arr_p)
        save_json(os.path.join(self.mdir, idx_name), index)
        free_memory()
        return arr_p, index

    # ------------------------------------------------- Spoken-HaVG (SYNTHETIC, optional) ----
    @torch.no_grad()
    def build_spoken_havg(self, havg: List[dict], device) -> List[dict]:
        """OPTIONAL (off by default): real HaVG Hausa captions voiced with MMS-TTS (VITS). The speech is
        SYNTHETIC and is reported as such; the default speech+image task uses YFACC's real speech."""
        cached = self._cached("spoken_havg.jsonl", ["audio"])
        if cached is not None:
            return cached
        from transformers import VitsModel
        name = self.cfg.eval.mms_tts_prefix + self.d.mms_codes["ha"]
        tok = AutoTokenizer.from_pretrained(name)
        tts = VitsModel.from_pretrained(name).to(device).eval()
        rng = random.Random(0)
        sel = []
        for split, n in [("train", self.d.spoken_havg_train), ("test", self.d.spoken_havg_eval),
                         ("challenge", self.d.spoken_havg_eval)]:
            pool = [r for r in havg if r["split"] == split]
            rng.shuffle(pool)
            sel += pool[:n]
        out = []
        odir = os.path.join(self.root, "spoken_havg")
        for r in sel:
            p = os.path.join(odir, f"{r['uid']}.wav")
            if not os.path.exists(p):
                inp = tok(r["ha"], return_tensors="pt").to(device)
                if inp["input_ids"].shape[1] < 2:
                    raise ValueError(f"MMS-TTS tokenizer produced no symbols for HaVG caption {r['uid']!r}")
                torch.manual_seed(stable_hash(r["uid"]))
                wav = tts(**inp).waveform[0].float().cpu().numpy()
                save_wav(p, resample(wav, tts.config.sampling_rate, 16000), 16000)
            dur = sf.info(p).duration
            if not (self.d.min_dur <= dur <= self.d.max_dur):
                continue
            out.append(dict(uid="s" + r["uid"], havg_uid=r["uid"], split=r["split"], audio=p, dur=round(dur, 3),
                            lang="ha", text=r["ha"], en=r["en"], domain="spoken_havg", synthetic=True))
        del tts
        free_memory()
        self.save_manifest("spoken_havg.jsonl", out, ["audio"])
        LOG.info(f"Spoken-HaVG (SYNTHETIC speech, optional): {len(out)} utterances")
        return out

    def build_all(self, device):
        fleurs, parallel = self.build_fleurs()
        ebible, ranges = self.build_ebible()
        bible = self.build_bibletts(ebible, ranges)
        bible_text = self.bible_text_pairs(ebible, ranges, bible) if self.d.use_ebible_mt else []
        havg = self.build_havg()
        yfacc = self.build_yfacc() if self.d.use_yfacc else []
        vis_path, vis_index = self.build_visual_cache(havg + yfacc, device)
        spoken = self.build_spoken_havg(havg, device) if self.d.use_synthetic_spoken_havg else []
        L = self.d.african_langs
        stats = {
            "fleurs": {l: {s: sum(1 for m in fleurs if m["lang"] == l and m["split"] == s)
                           for s in ["train", "dev", "test"]} for l in L},
            "fleurs_hours": {l: round(sum(m["dur"] for m in fleurs if m["lang"] == l) / 3600, 2) for l in L},
            "bibletts": {l: {s: sum(1 for m in bible if m["lang"] == l and m["split"] == s)
                             for s in ["target_dev", "target_test", "target_adapt"]} for l in L},
            "bibletts_hours": {l: round(sum(m["dur"] for m in bible if m["lang"] == l) / 3600, 2) for l in L},
            "bible_test_with_english_ref": {l: sum(1 for m in bible if m["lang"] == l and m["split"] == "target_test"
                                                   and m["en"]) for l in L},
            "ebible_mt_verses": len(bible_text),
            "havg": dict(Counter(m["split"] for m in havg)),
            "yfacc_real_speech": dict(Counter(m["split"] for m in yfacc)),
            "yfacc_hours": round(sum(m["dur"] for m in yfacc) / 3600, 2),
            "spoken_havg_synthetic": dict(Counter(m["split"] for m in spoken)),
        }
        save_json(os.path.join(self.cfg.paths.results_dir, "dataset_statistics.json"), stats)
        LOG.info(f"dataset statistics: {json.dumps(stats)}")
        return dict(fleurs=fleurs, parallel=parallel, bible=bible, bible_text=bible_text, havg=havg, yfacc=yfacc,
                    vis_path=vis_path, vis_index=vis_index, spoken=spoken, stats=stats)


# =============================================================================================
#                          TOKENISERS / VOCABULARIES / SPEECH FEATURES / MEL
# =============================================================================================
class TextTok:
    """Thin wrapper around an NLLB-200 SentencePiece (fast) tokenizer with explicit, version-independent
    construction of source / target sequences:  src = [lang] w1..wn </s>,  tgt = [lang] w1..wn </s>."""

    def __init__(self, name_or_tok, nllb_codes: Dict[str, str], decoder_start_id: Optional[int], max_len: int = 200):
        self.tok = AutoTokenizer.from_pretrained(name_or_tok) if isinstance(name_or_tok, str) else name_or_tok
        if not self.tok.is_fast:
            raise RuntimeError("a fast tokenizer (offset mapping) is required")
        self.pad_id = self.tok.pad_token_id
        self.eos_id = self.tok.eos_token_id
        self.decoder_start_id = decoder_start_id
        self.lang_ids = {}
        for l, c in nllb_codes.items():
            i = self.tok.convert_tokens_to_ids(c)
            if i is None or i == self.tok.unk_token_id:
                raise ValueError(f"language code {c} is not in the vocabulary")
            self.lang_ids[l] = i
        self.max_len = max_len
        self.special = set(self.tok.all_special_ids) | set(self.lang_ids.values())

    def encode(self, text: str) -> List[int]:
        return self.tok(text, add_special_tokens=False)["input_ids"][: self.max_len]

    def encode_with_offsets(self, text: str) -> Tuple[List[int], List[Tuple[int, int]]]:
        enc = self.tok(text, add_special_tokens=False, return_offsets_mapping=True)
        return enc["input_ids"][: self.max_len], [tuple(o) for o in enc["offset_mapping"][: self.max_len]]

    def src(self, text: str, lang: str) -> List[int]:
        return [self.lang_ids[lang]] + self.encode(text) + [self.eos_id]

    def tgt(self, text: str, lang: str) -> List[int]:
        return [self.lang_ids[lang]] + self.encode(text) + [self.eos_id]

    def decode(self, ids: Sequence[int]) -> str:
        ids = [int(i) for i in ids if int(i) not in self.special and int(i) >= 0]
        return self.tok.decode(ids, skip_special_tokens=True).strip()

    def __len__(self):
        return len(self.tok)


class CharVocab:
    """Character inventory shared by the CTC head (ASR), the SAB segmentation and the TTS front-end.
    encode() is 1:1 with the characters of ctc_text(text), so character index == CTC label index."""
    BLANK, UNK, SPACE = "<blank>", "<unk>", "|"

    def __init__(self, itos: List[str]):
        self.itos = list(itos)
        self.stoi = {c: i for i, c in enumerate(self.itos)}

    @classmethod
    def build(cls, texts: Iterable[str], min_count: int = 2):
        cnt = Counter()
        for t in texts:
            cnt.update(ctc_text(t))
        chars = sorted(c for c, n in cnt.items() if n >= min_count and c not in (" ", cls.SPACE))
        return cls([cls.BLANK, cls.UNK, cls.SPACE] + chars)

    @classmethod
    def load(cls, path):
        return cls(load_json(path))

    def save(self, path):
        save_json(path, self.itos)

    def encode(self, text: str, already_normalized: bool = False) -> List[int]:
        s = text if already_normalized else ctc_text(text)
        return [self.stoi.get(self.SPACE if c == " " else c, 1) for c in s]

    def ids_to_text(self, ids: Sequence[int]) -> str:
        s = "".join(" " if self.itos[int(i)] == self.SPACE else self.itos[int(i)] for i in ids if int(i) not in (0, 1))
        return normalize_text(s)

    def greedy_segments(self, frame_ids: Sequence[int]) -> Tuple[str, List[Tuple[int, int]]]:
        """Greedy CTC path -> (text, per-character frame span). A character owns the frames from its
        emission to the next emission (the following blanks); the first character also owns the leading
        blanks. Repeated / leading / trailing spaces are merged into their neighbours so that
        span[k] belongs to text[k] exactly (the text is NOT re-normalised: indices must stay aligned)."""
        T = len(frame_ids)
        em, prev = [], -1
        for t, i in enumerate(frame_ids):
            i = int(i)
            if i != prev and i not in (0, 1):
                em.append((self.itos[i], t))
            prev = i
        items = []
        for k, (c, s) in enumerate(em):
            e = em[k + 1][1] if k + 1 < len(em) else T
            items.append([" " if c == self.SPACE else c, 0 if k == 0 else s, e])
        merged, carry = [], None
        for c, s, e in items:
            if c == " " and (not merged or merged[-1][0] == " "):
                if merged:
                    merged[-1][2] = e
                elif carry is None:
                    carry = s
                continue
            if carry is not None:
                s, carry = carry, None
            merged.append([c, s, e])
        if merged and merged[-1][0] == " ":
            last = merged.pop()
            if merged:
                merged[-1][2] = last[2]
        return "".join(c for c, _, _ in merged), [(s, e) for _, s, e in merged]

    def decode_ctc(self, frame_ids: Sequence[int]) -> str:
        return normalize_text(self.greedy_segments(frame_ids)[0])

    def __len__(self):
        return len(self.itos)


class SpeechFeaturizer:
    """CPU-side speech front-end (runs inside DataLoader workers): log-mel fbank stacks for w2v-BERT 2.0
    (SeamlessM4T feature extractor, 20 ms frames) or normalised waveforms for wav2vec2-family models."""

    def __init__(self, speech_model: str, kind: Optional[str] = None, feature_extractor=None):
        if kind is None:
            kind = "w2v-bert" if AutoConfig.from_pretrained(speech_model).model_type == "wav2vec2-bert" else "wav2vec2"
        self.kind = kind
        self.fe = feature_extractor
        if self.kind == "w2v-bert" and self.fe is None:
            self.fe = AutoFeatureExtractor.from_pretrained(speech_model)

    def __call__(self, wavs: List[np.ndarray]) -> Tuple[torch.Tensor, torch.Tensor]:
        if self.kind == "w2v-bert":
            out = self.fe([np.asarray(w, dtype=np.float32) for w in wavs], sampling_rate=16000, return_tensors="pt",
                          padding=True, return_attention_mask=True)
            return out["input_features"].float(), out["attention_mask"].long()
        ws = [(w - w.mean()) / (w.std() + 1e-6) for w in wavs]
        L = max(len(w) for w in ws)
        x = torch.zeros(len(ws), L)
        am = torch.zeros(len(ws), L, dtype=torch.long)
        for i, w in enumerate(ws):
            x[i, :len(w)] = torch.from_numpy(np.asarray(w, dtype=np.float32))
            am[i, :len(w)] = 1
        return x, am


def vocos_mel_extractor(repo: str, mc: ModelConfig):
    """The exact log-mel front-end of the Vocos checkpoint (instantiated from its config.yaml), so that TTS
    targets and vocoder inputs cannot drift apart. Frame rate and bins are checked against ModelConfig."""
    import yaml
    from huggingface_hub import hf_hub_download
    from vocos.feature_extractors import MelSpectrogramFeatures
    with open(hf_hub_download(repo_id=repo, filename="config.yaml", token=_hf_token())) as f:
        conf = yaml.safe_load(f)["feature_extractor"]
    if not conf["class_path"].endswith("MelSpectrogramFeatures"):
        raise ValueError(f"{repo}: unsupported feature extractor {conf['class_path']}")
    a = conf["init_args"]
    if (a["sample_rate"], a["hop_length"], a["n_mels"]) != (mc.tts_sr, mc.tts_hop, mc.n_mels):
        raise ValueError(f"ModelConfig (sr={mc.tts_sr}, hop={mc.tts_hop}, mels={mc.n_mels}) does not match {repo}: {a}")
    fe = MelSpectrogramFeatures(**a).eval()

    @torch.no_grad()
    def extract(wav24: np.ndarray) -> np.ndarray:
        return fe(torch.from_numpy(np.ascontiguousarray(wav24, dtype=np.float32))[None])[0].numpy()

    return extract


# =============================================================================================
#                 CTC ALGORITHMS: batched Viterbi, prefix beam search, subword segmentation
# =============================================================================================
@torch.no_grad()
def ctc_viterbi_batch(logp: torch.Tensor, lengths: torch.Tensor, targets: List[List[int]],
                      blank: int = 0) -> List[Optional[List[int]]]:
    """Batched CTC forced alignment (Viterbi) on the GPU. logp (B,T,C) log-probabilities, lengths (B,)
    valid frames, targets: label ids per item. Returns, per item, the number of frames assigned to each
    label (blank frames go to the preceding label, leading blanks to the first one), or None when the
    label sequence cannot be aligned (empty, or too long for the utterance)."""
    B, T, _ = logp.shape
    dev = logp.device
    Ls = torch.tensor([len(t) for t in targets], device=dev, dtype=torch.long)
    Lm = max(1, int(Ls.max()) if B else 1)
    S = 2 * Lm + 1
    tgt = torch.full((B, Lm), blank, dtype=torch.long, device=dev)
    for b, t in enumerate(targets):
        if t:
            tgt[b, :len(t)] = torch.tensor(t, dtype=torch.long, device=dev)
    ext = torch.full((B, S), blank, dtype=torch.long, device=dev)
    ext[:, 1::2] = tgt
    lp = logp.float().gather(2, ext[:, None, :].expand(B, T, S))
    s_idx = torch.arange(S, device=dev)[None, :]
    valid_s = s_idx < (2 * Ls[:, None] + 1)
    prev2 = torch.cat([torch.full((B, 2), -1, dtype=torch.long, device=dev), ext[:, :-2]], 1)
    skip_ok = (ext != blank) & (ext != prev2) & (s_idx >= 2)
    NEG = -1e30
    alpha = torch.full((B, S), NEG, device=dev)
    alpha[:, 0] = lp[:, 0, 0]
    alpha[:, 1] = torch.where(Ls > 0, lp[:, 0, 1], torch.full_like(lp[:, 0, 1], NEG))
    alpha = alpha.masked_fill(~valid_s, NEG)
    bp = torch.zeros((B, T, S), dtype=torch.int8, device=dev)
    negcol = torch.full((B, 1), NEG, device=dev)
    lengths = lengths.to(dev).long()
    for t in range(1, T):
        a1 = torch.cat([negcol, alpha[:, :-1]], 1)
        a2 = torch.cat([negcol, negcol, alpha[:, :-2]], 1).masked_fill(~skip_ok, NEG)
        best, arg = torch.stack([alpha, a1, a2], 0).max(0)
        new = (best + lp[:, t]).masked_fill(~valid_s, NEG)
        act = (t < lengths)[:, None]
        alpha = torch.where(act, new, alpha)
        bp[:, t] = torch.where(act, arg, torch.zeros_like(arg)).to(torch.int8)
    last = 2 * Ls
    a_last = alpha.gather(1, last[:, None]).squeeze(1)
    a_prev = alpha.gather(1, (last - 1).clamp(min=0)[:, None]).squeeze(1)
    s = torch.where(a_last >= a_prev, last, last - 1)
    ok = (torch.maximum(a_last, a_prev) > NEG / 2) & (Ls > 0) & (lengths > 0)
    states = torch.full((B, T), -1, dtype=torch.long, device=dev)
    ar = torch.arange(B, device=dev)
    for t in range(T - 1, -1, -1):
        act = t < lengths
        states[:, t] = torch.where(act, s, torch.full_like(s, -1))
        step = bp[ar, t, s.clamp(min=0)].long()
        s = torch.where(act, s - step, s)
    is_lab = (states >= 0) & (states % 2 == 1)
    lab = torch.where(is_lab, (states - 1) // 2, torch.full_like(states, -1))
    lab_ff = torch.cummax(lab, dim=1).values.clamp(min=0)
    frame_ok = states >= 0
    counts = torch.zeros((B, Lm), dtype=torch.long, device=dev).scatter_add_(1, lab_ff, frame_ok.long())
    counts = counts.cpu().tolist()
    ok = ok.cpu().tolist()
    return [counts[b][: len(targets[b])] if ok[b] else None for b in range(B)]


def ctc_prefix_beam_search(logp: np.ndarray, beam: int = 8, blank: int = 0, skip: Sequence[int] = (1,),
                           prune_logp: float = -10.0, max_cands: int = 12) -> List[Tuple[Tuple[int, ...], float]]:
    """CTC prefix beam search (Hannun et al., 2014) on one utterance. logp (T,C). Returns (prefix label ids,
    log-probability of the prefix summed over all its alignments) sorted best first."""
    T = logp.shape[0]
    NEG = -np.inf
    lae = np.logaddexp
    skip = set(int(s) for s in skip)
    beams: Dict[Tuple[int, ...], Tuple[float, float]] = {(): (0.0, NEG)}
    fast = math.log(0.999)
    for t in range(T):
        row = logp[t]
        nxt: Dict[Tuple[int, ...], Tuple[float, float]] = {}

        def add(prefix, pb, pnb):
            if pb == NEG and pnb == NEG:  # impossible prefix (e.g. a repeat without a separating blank)
                return
            if prefix in nxt:
                ob, onb = nxt[prefix]
                nxt[prefix] = (lae(ob, pb), lae(onb, pnb))
            else:
                nxt[prefix] = (pb, pnb)

        if row[blank] > fast:  # (almost) certain blank frame: no new label can start here
            for prefix, (pb, pnb) in beams.items():
                add(prefix, lae(pb, pnb) + row[blank], (pnb + row[prefix[-1]]) if prefix else NEG)
        else:
            order = np.argpartition(-row, min(max_cands, len(row) - 1))[:max_cands]
            cands = [int(c) for c in order if int(c) != blank and int(c) not in skip and row[c] > prune_logp]
            for prefix, (pb, pnb) in beams.items():
                tot = lae(pb, pnb)
                last = prefix[-1] if prefix else None
                add(prefix, tot + row[blank], (pnb + row[last]) if last is not None else NEG)
                for c in cands:
                    if c == last:
                        add(prefix + (c,), NEG, pb + row[c])
                    else:
                        add(prefix + (c,), NEG, tot + row[c])
        beams = dict(sorted(nxt.items(), key=lambda kv: -lae(*kv[1]))[:beam])
    return sorted(((p, float(lae(*v))) for p, v in beams.items()), key=lambda x: -x[1])


def uniform_char_spans(n_chars: int, T: int) -> List[Tuple[int, int]]:
    """Fallback segmentation: characters spread uniformly over the utterance."""
    if n_chars <= 0:
        return []
    out = []
    for k in range(n_chars):
        s = min(T - 1, (k * T) // n_chars)
        e = max(s + 1, min(T, ((k + 1) * T) // n_chars))
        out.append((s, e))
    return out


def counts_to_spans(counts: List[int]) -> List[Tuple[int, int]]:
    spans, s = [], 0
    for c in counts:
        spans.append((s, s + c))
        s += c
    return spans


def token_spans(tok: TextTok, text: str, char_spans: List[Tuple[int, int]], max_tokens: int
                ) -> Tuple[List[int], List[Tuple[int, int]]]:
    """NLLB subwords of `text` and the frame span of each one: the union of the frame spans of its
    (non-space) characters, located with the fast tokenizer's character offsets. This is what makes the
    speech sequence token-synchronous with the text sequence."""
    if not text:
        return [], []
    if len(char_spans) != len(text):
        raise ValueError(f"{len(char_spans)} character spans for a {len(text)}-character text")
    ids, offs = tok.encode_with_offsets(text)
    ids, offs = ids[:max_tokens], offs[:max_tokens]
    L = len(text)
    spans = []
    for a, b in offs:
        a = min(max(int(a), 0), L - 1)
        b = min(max(int(b), a + 1), L)
        idx = [k for k in range(a, b) if not text[k].isspace()] or [a]
        s = min(char_spans[k][0] for k in idx)
        e = max(char_spans[k][1] for k in idx)
        spans.append((s, max(e, s + 1)))
    return ids, spans


def spans_to_mask(spans_list: List[List[Tuple[int, int]]], lengths: Sequence[int], T: int) -> torch.Tensor:
    """(B, N, T) boolean membership of every frame in every token segment (built on CPU)."""
    B = len(spans_list)
    N = max(1, max((len(s) for s in spans_list), default=1))
    m = torch.zeros(B, N, T, dtype=torch.bool)
    for b, spans in enumerate(spans_list):
        Lb = max(1, min(int(lengths[b]), T))
        for n, (s, e) in enumerate(spans):
            s = min(max(0, int(s)), Lb - 1)
            e = min(max(int(e), s + 1), Lb)
            m[b, n, s:e] = True
    return m


@dataclass
class Segmentation:
    """One subword segmentation per utterance: token ids (None for pseudo-tokens), frame masks, provenance."""
    tok_ids: List[Optional[List[int]]]
    mask: torch.Tensor          # (B, N, T) bool
    n_tok: torch.Tensor         # (B,)
    source: List[str]           # 'viterbi' | 'greedy' | 'uniform' | 'pseudo' (logged as a training diagnostic)
    conf: Optional[torch.Tensor] = None  # (B, N) mean max CTC posterior inside each segment


# =============================================================================================
#                                 DATASETS / SAMPLERS / COLLATORS
# =============================================================================================
class SpeechSeqDataset(Dataset):
    """Speech -> text entries for ASR, ST (many-to-many via FLEURS n-way parallelism and YFACC yo->en),
    speech+image -> text (YFACC) and pseudo-labelled target-domain audio.
    entry: {audio, lang, targets:{lang: text}, seg_text, ctc_text, vis_row, weight, tok_w:{lang:[..]}, domain}
    The source-language target is the normalised transcript (the output space shared with the CTC head)."""

    def __init__(self, entries: List[dict], mode: str, en_prob: float = 0.5):
        if mode not in ("asr", "st", "pl", "smmt"):
            raise ValueError(mode)
        self.e = entries
        self.mode = mode
        self.en_prob = en_prob

    def __len__(self):
        return len(self.e)

    def durations(self):
        return [x["dur"] for x in self.e]

    def __getitem__(self, i):
        x = self.e[i]
        tg = x["targets"]
        if self.mode == "asr":
            tl = x["lang"]
        elif self.mode in ("st", "pl"):
            opts = sorted(tg.keys())
            if self.mode == "st":
                opts = [l for l in opts if l != x["lang"]]
            tl = "en" if ("en" in opts and random.random() < self.en_prob) else random.choice(opts)
        else:  # smmt: spoken caption + image -> English
            tl = "en"
        return dict(wav=load_audio(x["audio"], 16000), lang=x["lang"], tgt_lang=tl, tgt_text=tg[tl],
                    seg_text=x.get("seg_text") or "", ctc_text=x.get("ctc_text"),
                    tok_w=(x.get("tok_w") or {}).get(tl), weight=x.get("weight", 1.0),
                    vis_row=x.get("vis_row", -1))


class TextPairDataset(Dataset):
    """entry: {src, src_lang, tgt, tgt_lang, [vis_row], [weight]}"""

    def __init__(self, entries: List[dict]):
        self.e = entries

    def __len__(self):
        return len(self.e)

    def __getitem__(self, i):
        return dict(self.e[i])


class UnlabeledAudioDataset(Dataset):
    def __init__(self, entries: List[dict]):
        self.e = entries

    def __len__(self):
        return len(self.e)

    def durations(self):
        return [x["dur"] for x in self.e]

    def __getitem__(self, i):
        x = self.e[i]
        return dict(wav=load_audio(x["audio"], 16000))


class TTSDataset(Dataset):
    """entry: {chars:[ids], dur:[mel frames per char], mel: path.npy, lang, domain, gender, weight}"""

    def __init__(self, entries: List[dict]):
        self.e = entries

    def __len__(self):
        return len(self.e)

    def __getitem__(self, i):
        x = self.e[i]
        mel = np.load(x["mel"]).astype(np.float32)
        dur = np.asarray(x["dur"], dtype=np.int64)
        if int(dur.sum()) != mel.shape[1]:
            raise ValueError(f"{x['uid']}: durations sum to {int(dur.sum())} but mel has {mel.shape[1]} frames")
        return dict(chars=np.asarray(x["chars"], dtype=np.int64), dur=dur, mel=mel, lang=x["lang"],
                    domain=x["domain"], gender=x["gender"], weight=x["weight"])


class DurationBatchSampler(Sampler):
    """Bucketed dynamic batching under a padded-seconds budget (T4-friendly)."""

    def __init__(self, durations, max_seconds, max_utts, seed=0, shuffle=True):
        self.d = durations
        self.max_s = max_seconds
        self.max_n = max_utts
        self.seed = seed
        self.shuffle = shuffle
        self.epoch = 0

    def _batches(self):
        rng = random.Random(self.seed + self.epoch)
        idx = list(range(len(self.d)))
        if self.shuffle:
            rng.shuffle(idx)
        batches = []
        chunk = 100 * self.max_n
        for s in range(0, len(idx), chunk):
            part = sorted(idx[s:s + chunk], key=lambda i: self.d[i])
            cur, mx = [], 0.0
            for i in part:
                nm = max(mx, self.d[i])
                if cur and (nm * (len(cur) + 1) > self.max_s or len(cur) >= self.max_n):
                    batches.append(cur)
                    cur, nm = [], self.d[i]
                cur.append(i)
                mx = nm
            if cur:
                batches.append(cur)
        if self.shuffle:
            rng.shuffle(batches)
        return batches

    def __iter__(self):
        b = self._batches()
        self.epoch += 1
        return iter(b)

    def __len__(self):
        return len(self._batches())


class VisStore:
    """Lazily opened memmap of cached SigLIP features (safe with forked DataLoader workers)."""

    def __init__(self, path: str, n: int, n_tok: int, dim: int):
        if not os.path.exists(path):
            raise FileNotFoundError(path)
        self.path, self.shape = path, (max(1, n), n_tok, dim)
        self._mm = None

    def get(self, rows: List[int]) -> Tuple[torch.Tensor, torch.Tensor]:
        """rows < 0 mark 'no image for this item' (text-only entries mixed in a batch)."""
        if self._mm is None:
            self._mm = np.memmap(self.path, dtype=np.float16, mode="r", shape=self.shape)
        out = torch.zeros(len(rows), self.shape[1], self.shape[2])
        has = torch.zeros(len(rows), dtype=torch.bool)
        for i, r in enumerate(rows):
            if r is not None and r >= 0:
                out[i] = torch.from_numpy(np.asarray(self._mm[r], dtype=np.float32))
                has[i] = True
        return out, has


def _pad_labels(seqs: List[List[int]], pad: int) -> torch.Tensor:
    L = max(1, max((len(s) for s in seqs), default=1))
    out = torch.full((len(seqs), L), pad, dtype=torch.long)
    for i, s in enumerate(seqs):
        out[i, :len(s)] = torch.tensor(s, dtype=torch.long)
    return out


def decoder_inputs(labels: torch.Tensor, start_id: int, pad_id: int) -> torch.Tensor:
    """Teacher-forcing inputs [</s>, lang, w1..wn] for labels [lang, w1..wn, </s>] (-100 = padding)."""
    dec_in = torch.full_like(labels, pad_id)
    dec_in[:, 0] = start_id
    dec_in[:, 1:] = torch.where(labels[:, :-1] == -100, torch.full_like(labels[:, :-1], pad_id), labels[:, :-1])
    return dec_in


class Collator:
    def __init__(self, tok: TextTok, chars: CharVocab, vis: Optional[VisStore], featurizer: SpeechFeaturizer,
                 image_drop: float = 0.0):
        self.tok, self.chars, self.vis, self.feat, self.image_drop = tok, chars, vis, featurizer, image_drop

    def _targets(self, texts, langs, tok_ws):
        labels, weights = [], []
        for t, l, w in zip(texts, langs, tok_ws):
            ids = self.tok.tgt(t, l)
            if w is None:
                w = [1.0] * len(ids)
            elif len(w) != len(ids):
                raise ValueError(f"token weights ({len(w)}) do not match the label length ({len(ids)}) for {t!r}")
            labels.append(ids)
            weights.append(w)
        lab = _pad_labels(labels, -100)
        tw = torch.zeros(lab.shape, dtype=torch.float)
        for i, w in enumerate(weights):
            tw[i, :len(w)] = torch.tensor(w, dtype=torch.float)
        return lab, decoder_inputs(lab, self.tok.decoder_start_id, self.tok.pad_id), tw

    def _vis(self, rows, allow_drop):
        v, has = self.vis.get(rows)
        if allow_drop and self.image_drop > 0:
            has = has & ~(torch.rand(len(rows)) < self.image_drop)
        return v, has

    def speech(self, batch: List[dict]) -> dict:
        x, am = self.feat([b["wav"] for b in batch])
        out = dict(x=x, am=am)
        if "tgt_text" in batch[0]:
            lab, dec_in, tw = self._targets([b["tgt_text"] for b in batch], [b["tgt_lang"] for b in batch],
                                            [b["tok_w"] for b in batch])
            out.update(labels=lab, decoder_input_ids=dec_in, tok_weights=tw,
                       tgt_lang=[b["tgt_lang"] for b in batch], src_lang=[b["lang"] for b in batch],
                       sample_weight=torch.tensor([float(b["weight"]) for b in batch]))
            ctc = [self.chars.encode(b["ctc_text"]) if b["ctc_text"] else [] for b in batch]
            out["ctc_targets"] = _pad_labels([c or [0] for c in ctc], 0)
            out["ctc_lengths"] = torch.tensor([len(c) for c in ctc], dtype=torch.long)
            out["seg_text"] = [ctc_text(b["seg_text"]) if b["seg_text"] else "" for b in batch]
            rows = [b["vis_row"] for b in batch]
            if self.vis is not None and any(r is not None and r >= 0 for r in rows):
                out["vis"], out["has_vis"] = self._vis(rows, allow_drop=False)
        return out

    def text(self, batch: List[dict]) -> dict:
        src = [self.tok.src(b["src"], b["src_lang"]) for b in batch]
        ids = _pad_labels(src, self.tok.pad_id)
        am = torch.zeros_like(ids)
        for i, s in enumerate(src):
            am[i, :len(s)] = 1
        lab, dec_in, tw = self._targets([b["tgt"] for b in batch], [b["tgt_lang"] for b in batch],
                                        [None] * len(batch))
        out = dict(input_ids=ids, attention_mask=am, labels=lab, decoder_input_ids=dec_in, tok_weights=tw,
                   tgt_lang=[b["tgt_lang"] for b in batch], src_lang=[b["src_lang"] for b in batch],
                   sample_weight=torch.tensor([float(b.get("weight", 1.0)) for b in batch]))
        rows = [b.get("vis_row", -1) for b in batch]
        if self.vis is not None and any(r is not None and r >= 0 for r in rows):
            out["vis"], out["has_vis"] = self._vis(rows, allow_drop=True)
        return out

    def tts(self, batch: List[dict]) -> dict:
        B = len(batch)
        Lc = max(len(b["chars"]) for b in batch)
        Tm = max(b["mel"].shape[1] for b in batch)
        chars = torch.zeros(B, Lc, dtype=torch.long)
        dur = torch.zeros(B, Lc, dtype=torch.long)
        mel = torch.zeros(B, batch[0]["mel"].shape[0], Tm)
        cm = torch.zeros(B, Lc, dtype=torch.bool)
        mm = torch.zeros(B, Tm, dtype=torch.bool)
        for i, b in enumerate(batch):
            n, t = len(b["chars"]), b["mel"].shape[1]
            chars[i, :n] = torch.from_numpy(b["chars"])
            dur[i, :n] = torch.from_numpy(b["dur"])
            mel[i, :, :t] = torch.from_numpy(b["mel"])
            cm[i, :n] = True
            mm[i, :t] = True
        return dict(chars=chars, dur=dur, mel=mel, char_mask=cm, mel_mask=mm,
                    lang=[b["lang"] for b in batch], domain=[b["domain"] for b in batch],
                    gender=[b["gender"] for b in batch],
                    sample_weight=torch.tensor([float(b["weight"]) for b in batch]))


def infinite_loader(ds: Dataset, collate, batch_size=None, batch_sampler=None, num_workers=2, seed=0):
    """Endless iterator over a DataLoader (re-shuffled every pass)."""
    if len(ds) == 0:
        raise ValueError("empty dataset")
    epoch = 0
    pin = torch.cuda.is_available()
    while True:
        if batch_sampler is not None:
            batch_sampler.epoch = epoch
            dl = DataLoader(ds, batch_sampler=batch_sampler, collate_fn=collate, num_workers=num_workers,
                            pin_memory=pin)
        else:
            g = torch.Generator()
            g.manual_seed(seed + epoch)
            dl = DataLoader(ds, batch_size=batch_size, shuffle=True, collate_fn=collate, num_workers=num_workers,
                            generator=g, drop_last=len(ds) > batch_size, pin_memory=pin)
        for b in dl:
            yield b
        epoch += 1


# =============================================================================================
#                                          MODEL
# =============================================================================================
def _from_pretrained(cls, name, dtype=torch.float32, **kw):
    """Loads with an explicit dtype. transformers >= 4.56 names the argument `dtype` (older releases would
    silently forward an unknown `dtype=` into the config, so the name is chosen by version, not by try)."""
    key = "dtype" if _TF_VERSION >= pkg_version.parse("4.56.0") else "torch_dtype"
    return cls.from_pretrained(name, **{key: dtype}, **kw)


def _enable_gc(model):
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})


class LoRALinear(nn.Module):
    """Low-rank adapter around a frozen nn.Linear (Hu et al., 2021)."""

    def __init__(self, base: nn.Linear, r: int, alpha: int, dropout: float):
        super().__init__()
        self.base = base
        for p in self.base.parameters():
            p.requires_grad = False
        self.lora_A = nn.Parameter(torch.empty(r, base.in_features))
        self.lora_B = nn.Parameter(torch.zeros(base.out_features, r))
        nn.init.kaiming_uniform_(self.lora_A, a=math.sqrt(5))
        self.scale = alpha / r
        self.drop = nn.Dropout(dropout)

    @property
    def weight(self):
        return self.base.weight

    @property
    def bias(self):
        return self.base.bias

    @property
    def in_features(self):
        return self.base.in_features

    @property
    def out_features(self):
        return self.base.out_features

    def forward(self, x):
        return self.base(x) + (self.drop(x) @ self.lora_A.t().to(x.dtype) @ self.lora_B.t().to(x.dtype)) * self.scale


def inject_lora(module: nn.Module, targets: Sequence[str], r: int, alpha: int, dropout: float) -> int:
    n = 0
    for _, mod in list(module.named_modules()):
        if isinstance(mod, LoRALinear):
            continue
        for cname, child in list(mod.named_children()):
            if cname in targets and isinstance(child, nn.Linear):
                setattr(mod, cname, LoRALinear(child, r, alpha, dropout))
                n += 1
    return n


def lengths_to_mask(lengths: torch.Tensor, T: int) -> torch.Tensor:
    return torch.arange(T, device=lengths.device)[None, :] < lengths[:, None]


def span_mask(fmask: torch.Tensor, prob: float, span: int) -> torch.Tensor:
    """wav2vec2/data2vec-style span masking restricted to valid frames."""
    B, T = fmask.shape
    out = torch.zeros(B, T, dtype=torch.bool, device=fmask.device)
    for b, L in enumerate(fmask.sum(1).tolist()):
        L = int(L)
        if L <= span:
            continue
        n = max(2, int(prob * L / span + random.random()))
        starts = np.random.choice(L - span, size=min(n, L - span), replace=False)
        for s in starts:
            out[b, s:s + span] = True
    return out


def masked_instance_norm(h: torch.Tensor, fmask: torch.Tensor, eps: float = 1e-5) -> torch.Tensor:
    """Per-utterance, per-channel normalisation over VALID frames only (data2vec target normalisation)."""
    m = fmask.unsqueeze(-1).to(h.dtype)
    n = m.sum(1, keepdim=True).clamp(min=1)
    mu = (h * m).sum(1, keepdim=True) / n
    var = (((h - mu) ** 2) * m).sum(1, keepdim=True) / n
    return (h - mu) / torch.sqrt(var + eps)


def nllb_token_embeds(nllb_encoder: nn.Module, ids: torch.Tensor) -> torch.Tensor:
    """Exactly what the NLLB encoder feeds its first layer for `ids` (embedding x sqrt(d_model)).
    transformers >= 4.37 scales inside M2M100ScaledWordEmbedding, older releases in the encoder."""
    emb = nllb_encoder.embed_tokens(ids)
    if not hasattr(nllb_encoder.embed_tokens, "embed_scale"):
        emb = emb * getattr(nllb_encoder, "embed_scale", 1.0)
    return emb


class SpeechEncoder(nn.Module):
    """w2v-BERT 2.0 (default) or any wav2vec2-family encoder + CTC head + data2vec latent head."""

    def __init__(self, mc: ModelConfig, n_chars: int, backbone: Optional[nn.Module] = None):
        super().__init__()
        if backbone is None:
            cfg = AutoConfig.from_pretrained(mc.speech_model)
            self._configure(cfg, mc)
            if cfg.model_type == "wav2vec2-bert":
                from transformers import Wav2Vec2BertModel as _Cls
            else:
                from transformers import Wav2Vec2Model as _Cls
            backbone = _from_pretrained(_Cls, mc.speech_model, config=cfg)
        else:
            self._configure(backbone.config, mc)
        self.w2v = backbone
        cfg = self.w2v.config
        if getattr(self.w2v, "masked_spec_embed", None) is None:
            # HF only creates the mask embedding when SpecAugment is enabled at construction time; MPD's
            # explicit mask_time_indices need it whatever speech_mask_time_prob is
            self.w2v.masked_spec_embed = nn.Parameter(torch.empty(cfg.hidden_size).uniform_())
        self.kind = "w2v-bert" if cfg.model_type == "wav2vec2-bert" else "wav2vec2"
        if self.kind == "wav2vec2":
            self.w2v.freeze_feature_encoder()
        n_layers = len(self.w2v.encoder.layers)
        for i, layer in enumerate(self.w2v.encoder.layers):
            if i < n_layers - mc.speech_trainable_top_layers:
                for p in layer.parameters():
                    p.requires_grad = False
        for p in self.w2v.feature_projection.parameters():
            p.requires_grad = False
        if mc.grad_checkpointing:
            _enable_gc(self.w2v)
        H = cfg.hidden_size
        self.hidden = H
        self.ctc_head = nn.Sequential(nn.Dropout(0.1), nn.Linear(H, n_chars))
        self.latent_head = nn.Linear(H, H)
        self.fps = 16000.0 / (160 * 2) if self.kind == "w2v-bert" else 16000.0 / float(np.prod(cfg.conv_stride))

    @staticmethod
    def _configure(cfg, mc: ModelConfig):
        cfg.layerdrop = mc.speech_layerdrop
        cfg.mask_time_prob = mc.speech_mask_time_prob
        cfg.mask_time_length = 10
        cfg.apply_spec_augment = True  # w2v-BERT ships with False, which would also disable MPD's masking
        if cfg.model_type == "wav2vec2-bert":
            cfg.add_adapter = False

    def lengths(self, am: torch.Tensor) -> torch.Tensor:
        if self.kind == "w2v-bert":
            return am.sum(-1).long()
        return self.w2v._get_feat_extract_output_lengths(am.sum(-1)).long()

    def forward(self, x, am, mask_time_indices=None):
        kw = dict(attention_mask=am, mask_time_indices=mask_time_indices)
        o = self.w2v(input_features=x, **kw) if self.kind == "w2v-bert" else self.w2v(input_values=x, **kw)
        h = o.last_hidden_state
        return h, lengths_to_mask(self.lengths(am).to(h.device), h.shape[1])


class SubwordAnchoredBridge(nn.Module):
    """SAB: one vector per NLLB subword of the CTC hypothesis (or of the force-aligned transcript).
    Anchored mode (default): e_k = E[token_k] + R(pooled frames_k, E[token_k], CTC confidence_k), where
    E[token_k] is NLLB's own input embedding of the subword the model's CTC spelled out and R is a
    ZERO-INITIALISED acoustic residual. At initialisation the bridge is therefore an exact cascade (it
    cannot collapse), token identity comes from the tokenizer (unseen words generalise), and end-to-end
    training learns where the acoustics should overrule an uncertain hypothesis.
    Acoustic mode (ablation 'no_sab_anchor'): e_k predicted from the pooled frames alone — a learned
    spelling->embedding map, which the learnability check showed does not generalise to unseen subwords."""

    def __init__(self, H: int, D: int, hidden: int, dropout: float, emb_rms: float):
        super().__init__()
        self.pre = nn.Sequential(nn.LayerNorm(H), nn.Linear(H, hidden), nn.GELU(), nn.Dropout(dropout))
        self.score = nn.Linear(hidden, 1)
        self.res = nn.Sequential(nn.Linear(2 * hidden + D + 1, hidden), nn.GELU(), nn.Dropout(dropout),
                                 nn.Linear(hidden, D))
        nn.init.zeros_(self.res[-1].weight)
        nn.init.zeros_(self.res[-1].bias)
        self.out = nn.Sequential(nn.Linear(2 * hidden, hidden), nn.GELU(), nn.Dropout(dropout), nn.Linear(hidden, D))
        self.norm = nn.LayerNorm(D)
        self.register_buffer("emb_rms", torch.tensor(float(emb_rms)))

    def pool(self, h: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
        z = self.pre(h)                                                        # (B,T,hd)
        s = self.score(z).squeeze(-1).float()                                  # (B,T)
        logits = s[:, None, :].expand(-1, mask.shape[1], -1).masked_fill(~mask, float("-inf"))
        w = torch.nan_to_num(torch.softmax(logits, -1), nan=0.0).to(z.dtype)   # empty rows -> 0
        att = torch.bmm(w, z)
        m = mask.to(z.dtype)
        mean = torch.bmm(m, z) / m.sum(-1, keepdim=True).clamp(min=1)
        return torch.cat([att, mean], -1)

    def forward(self, h: torch.Tensor, mask: torch.Tensor, base: Optional[torch.Tensor] = None,
                conf: Optional[torch.Tensor] = None) -> torch.Tensor:
        p = self.pool(h, mask)
        if base is None:
            return self.norm(self.out(p)) * self.emb_rms
        x = torch.cat([p, (base / self.emb_rms).to(p.dtype), conf.to(p.dtype)[..., None]], -1)
        return base.float() + self.res(x).float() * self.emb_rms  # fp32: exact cascade at init under autocast


class VisualUtilityGate(nn.Module):
    """CS-VUG: region-grounded visual cross-attention whose contribution is scaled by a per-sample
    utility gate g in [0,1]. The gate is supervised counterfactually (see Trainer._gate_losses)."""

    def __init__(self, vis_dim: int, d: int, hidden: int, n_tok: int):
        super().__init__()
        self.proj = nn.Sequential(nn.Linear(vis_dim, d), nn.GELU(), nn.Linear(d, d))
        self.type_emb = nn.Parameter(torch.zeros(1, n_tok, d))
        nn.init.normal_(self.type_emb, std=0.02)
        self.ln_v = nn.LayerNorm(d)
        self.ln_q = nn.LayerNorm(d)
        self.xattn = nn.MultiheadAttention(d, 16, dropout=0.1, batch_first=True)
        self.out = nn.Linear(d, d)
        self.alpha = nn.Parameter(torch.tensor(0.1))
        self.util = nn.Sequential(nn.Linear(3 * d, hidden), nn.GELU(), nn.Dropout(0.1), nn.Linear(hidden, 1))

    def forward(self, mem, mem_mask, vis, has_vis, force_gate: Optional[float] = None):
        v = self.ln_v(self.proj(vis.to(mem.dtype)) + self.type_emb.to(mem.dtype))
        ctx, _ = self.xattn(self.ln_q(mem), v, v, need_weights=False)
        mm = mem_mask.unsqueeze(-1).to(mem.dtype)
        pm = (mem * mm).sum(1) / mm.sum(1).clamp(min=1)
        pv = v.mean(1)
        logit = self.util(torch.cat([pm, pv, pm * pv], -1)).squeeze(-1).float()
        g = torch.sigmoid(logit) if force_gate is None else torch.full_like(logit, float(force_gate))
        g = g * has_vis.float()
        fused = mem + (g[:, None, None].to(mem.dtype) * torch.tanh(self.alpha).to(mem.dtype) * self.out(ctx))
        return fused, g, logit


# ------------------------------------------------------------------------------ TTS ---------
def sinusoid(t: torch.Tensor, dim: int) -> torch.Tensor:
    half = dim // 2
    f = torch.exp(-math.log(10000) * torch.arange(half, device=t.device).float() / half)
    a = t.float()[..., None] * f
    return torch.cat([a.sin(), a.cos()], -1)


class ConvTransformerBlock(nn.Module):
    """Pre-LN self-attention + depthwise-conv GLU + FFN, all FiLM-modulated by a conditioning vector."""

    def __init__(self, d: int, heads: int):
        super().__init__()
        self.ln1, self.ln2, self.ln3 = nn.LayerNorm(d), nn.LayerNorm(d), nn.LayerNorm(d)
        self.attn = nn.MultiheadAttention(d, heads, dropout=0.1, batch_first=True)
        self.pw = nn.Linear(d, 2 * d)
        self.dw = nn.Conv1d(d, d, 5, padding=2, groups=d)
        self.ff = nn.Sequential(nn.Linear(d, 4 * d), nn.GELU(), nn.Dropout(0.1), nn.Linear(4 * d, d))
        self.film = nn.Linear(d, 6 * d)
        nn.init.zeros_(self.film.weight)
        nn.init.zeros_(self.film.bias)

    def forward(self, x, mask, c):
        s1, b1, s2, b2, s3, b3 = self.film(c).unsqueeze(1).chunk(6, -1)
        h = self.ln1(x) * (1 + s1) + b1
        h, _ = self.attn(h, h, h, key_padding_mask=~mask, need_weights=False)
        x = x + h
        h = self.ln2(x) * (1 + s2) + b2
        a, g = self.pw(h).chunk(2, -1)
        h = (a * torch.sigmoid(g)) * mask.unsqueeze(-1)
        x = x + self.dw(h.transpose(1, 2)).transpose(1, 2)
        h = self.ln3(x) * (1 + s3) + b3
        x = x + self.ff(h)
        return x * mask.unsqueeze(-1)


TTS_DOMAINS = {"fleurs": 0, "bible": 1}
TTS_GENDERS = {"MALE": 0, "FEMALE": 1}  # everything else (OTHER, NA = unknown) -> 2


class FlowTTS(nn.Module):
    """Pseudo-label-trainable TTS: char encoder -> CTC-derived durations -> OT-CFM mel decoder.
    Durations come from the ASR branch's own CTC forced alignment (no external aligner). The decoder is
    trained on random crops (Matcha-TTS) and only conditions it has been trained on can be synthesised."""

    def __init__(self, n_chars: int, n_langs: int, mc: ModelConfig):
        super().__init__()
        d = mc.tts_dim
        self.mc = mc
        self.emb = nn.Embedding(n_chars, d)
        self.lang = nn.Embedding(n_langs, d)
        self.dom = nn.Embedding(len(TTS_DOMAINS), d)
        self.gender = nn.Embedding(len(TTS_GENDERS) + 1, d)
        self.enc = nn.ModuleList([ConvTransformerBlock(d, mc.tts_heads) for _ in range(mc.tts_enc_layers)])
        self.dur = nn.Sequential(nn.Conv1d(d, d, 3, padding=1), nn.ReLU(), nn.Conv1d(d, d, 3, padding=1), nn.ReLU(),
                                 nn.Conv1d(d, 1, 1))
        self.mu_proj = nn.Linear(d, mc.n_mels)
        self.t_mlp = nn.Sequential(nn.Linear(d, d), nn.SiLU(), nn.Linear(d, d))
        self.dec_in = nn.Linear(2 * mc.n_mels + d, d)
        self.dec = nn.ModuleList([ConvTransformerBlock(d, mc.tts_heads) for _ in range(mc.tts_dec_blocks)])
        self.dec_out = nn.Linear(d, mc.n_mels)
        nn.init.zeros_(self.dec_out.weight)
        nn.init.zeros_(self.dec_out.bias)
        # log-mel normalisation statistics (set from the training alignments, see Trainer.set_mel_stats)
        self.register_buffer("mel_mean", torch.zeros(mc.n_mels))
        self.register_buffer("mel_std", torch.ones(mc.n_mels))
        self.seen_conds: List[Tuple[int, int, int]] = []  # (lang, domain, gender) indices seen in training

    def set_mel_stats(self, mean: Sequence[float], std: Sequence[float]):
        self.mel_mean.copy_(torch.tensor(mean, dtype=torch.float))
        self.mel_std.copy_(torch.tensor(std, dtype=torch.float))

    def cond(self, lang, dom, gender):
        return self.lang(lang) + self.dom(dom) + self.gender(gender)

    def encode(self, chars, cmask, cond):
        x = self.emb(chars) + sinusoid(torch.arange(chars.shape[1], device=chars.device), self.emb.embedding_dim)[None]
        for blk in self.enc:
            x = blk(x, cmask, cond)
        logd = self.dur(x.detach().transpose(1, 2)).squeeze(1)  # as Glow-TTS/Matcha: no duration grads into x
        return x, logd

    @staticmethod
    def regulate(h, dur, T=None):
        B = h.shape[0]
        seqs = [torch.repeat_interleave(h[b], dur[b].clamp(min=0), dim=0) for b in range(B)]
        T = T or max(1, max(s.shape[0] for s in seqs))
        out = h.new_zeros(B, T, h.shape[-1])
        m = torch.zeros(B, T, dtype=torch.bool, device=h.device)
        for b, s in enumerate(seqs):
            n = min(T, s.shape[0])
            out[b, :n] = s[:n]
            m[b, :n] = True
        return out, m

    def velocity(self, xt, t, hu, mu, mask, cond):
        c = cond + self.t_mlp(sinusoid(t * 1000.0, hu.shape[-1]))
        x = self.dec_in(torch.cat([xt, mu, hu], -1))
        for blk in self.dec:
            x = blk(x, mask, c)
        return self.dec_out(x)

    def loss(self, chars, cmask, dur, mel, mmask, cond, sample_w):
        mc = self.mc
        h, logd = self.encode(chars, cmask, cond)
        cm = cmask.float()
        l_dur = (((logd.float() - torch.log1p(dur.float())) ** 2) * cm).sum(1) / cm.sum(1).clamp(min=1)
        hu, m2 = self.regulate(h, dur, mel.shape[-1])
        mask = mmask & m2
        x1 = (mel.transpose(1, 2) - self.mel_mean) / self.mel_std
        mu = self.mu_proj(hu)
        mf = mask.float().unsqueeze(-1)
        denom = mf.sum((1, 2)).clamp(min=1) * mel.shape[1]
        l_prior = (((mu.float() - x1) ** 2) * mf).sum((1, 2)) / denom
        # flow matching on random crops (the prior and the durations always see the whole utterance)
        B, T = mask.shape
        C = mc.tts_crop_frames
        if C and T > C:
            lens = mask.sum(1)
            starts = (torch.rand(B, device=x1.device) * (lens - C + 1).clamp(min=1).float()).long()
            idx = (starts[:, None] + torch.arange(C, device=x1.device)[None]).clamp(max=T - 1)
            pick = lambda t: t.gather(1, idx[..., None].expand(-1, -1, t.shape[-1]))
            x1c, muc, huc, maskc = pick(x1), pick(mu), pick(hu), mask.gather(1, idx)
        else:
            x1c, muc, huc, maskc = x1, mu, hu, mask
        x0 = torch.randn_like(x1c)
        t = torch.rand(B, device=x1.device)
        tt = t[:, None, None]
        xt = (1 - (1 - mc.fm_sigma_min) * tt) * x0 + tt * x1c
        u = x1c - (1 - mc.fm_sigma_min) * x0
        v = self.velocity(xt, t, huc, muc, maskc, cond)
        mfc = maskc.float().unsqueeze(-1)
        l_fm = (((v.float() - u) ** 2) * mfc).sum((1, 2)) / (mfc.sum((1, 2)).clamp(min=1) * mel.shape[1])
        w = sample_w / sample_w.sum().clamp(min=1e-6)
        return dict(tts_fm=(l_fm * w).sum(), tts_prior=(l_prior * w).sum(), tts_dur=(l_dur * w).sum())

    @torch.no_grad()
    def synthesize(self, chars, cmask, cond, steps=32, temperature=0.667, length_scale=1.0,
                   generator: Optional[torch.Generator] = None):
        h, logd = self.encode(chars, cmask, cond)
        dur = torch.clamp(torch.round((torch.exp(logd.float()) - 1) * length_scale), min=1).long() * cmask.long()
        hu, mask = self.regulate(h, dur)
        mu = self.mu_proj(hu)
        x = torch.randn(mu.shape, generator=generator, device=mu.device, dtype=mu.dtype) * temperature
        dt = 1.0 / steps
        for k in range(steps):
            t = torch.full((x.shape[0],), k * dt, device=x.device)
            x = x + dt * self.velocity(x, t, hu, mu, mask, cond)
        mel = x.float() * self.mel_std + self.mel_mean
        return mel.transpose(1, 2), mask, dur


class Vocoder:
    """Vocos (24 kHz) neural vocoder on log-mel features of its own front-end."""

    def __init__(self, name: str, device):
        from vocos import Vocos
        self.device = device
        self.v = Vocos.from_pretrained(name).to(device).eval()

    @torch.no_grad()
    def __call__(self, logmel: torch.Tensor) -> np.ndarray:
        if logmel.dim() == 2:
            logmel = logmel[None]
        return self.v.decode(logmel.to(self.device).float())[0].cpu().numpy()


class KORA(nn.Module):
    """Shared tri-modal encoder-decoder:
         speech -> w2v-BERT -> CTC head ─┬─ CTC hypothesis / self-alignment -> subword segments
                                         └─ SAB: E[subword] + acoustic residual ─┐
         text   -> NLLB token embeddings ───────────────────────────────┴─> NLLB encoder (LoRA)
                 -> CS-VUG (image, cached SigLIP global/region/grid tokens) -> NLLB decoder (LoRA)
         chars  -> FlowTTS (durations from CTC self-alignment) -> Vocos"""

    def __init__(self, cfg: KoraConfig, chars: CharVocab, tok: TextTok, nllb: Optional[nn.Module] = None,
                 speech_backbone: Optional[nn.Module] = None):
        super().__init__()
        mc = cfg.model
        self.tok = tok
        self.chars = chars
        self.max_tok = mc.sab_max_tokens
        self.nllb = nllb if nllb is not None else _from_pretrained(AutoModelForSeq2SeqLM, mc.text_model)
        for p in self.nllb.parameters():
            p.requires_grad = False
        n_dec = inject_lora(self.nllb.model.decoder, mc.lora_targets_decoder, mc.lora_r, mc.lora_alpha, mc.lora_dropout)
        n_enc = inject_lora(self.nllb.model.encoder, mc.lora_targets_encoder, mc.lora_r, mc.lora_alpha, mc.lora_dropout)
        for n, p in self.nllb.model.named_parameters():
            if "layer_norm" in n and (n.startswith("decoder.") or n.startswith("encoder.")):
                p.requires_grad = True
        if mc.grad_checkpointing:
            _enable_gc(self.nllb)
        LOG.info(f"LoRA injected: decoder {n_dec}, encoder {n_enc} linear layers")
        d = self.nllb.config.d_model
        self.speech = SpeechEncoder(mc, len(chars), speech_backbone)
        with torch.no_grad():
            V = self.nllb.config.vocab_size
            ids = torch.from_numpy(np.random.default_rng(0).integers(4, V, size=min(V - 4, 20000)))
            rms = float(nllb_token_embeds(self.nllb.model.encoder, ids).float().pow(2).mean().sqrt())
        self.sab = SubwordAnchoredBridge(self.speech.hidden, d, mc.sab_hidden, mc.sab_dropout, rms)
        self.sab_mode = "anchored"  # 'acoustic' only for the no_sab_anchor ablation (saved with checkpoints)
        self.vgate = VisualUtilityGate(mc.vis_dim, d, mc.gate_hidden, 2 + cfg.data.vis_grid ** 2)
        self.langs = list(cfg.data.african_langs)
        self.tts = FlowTTS(len(chars), len(self.langs), mc)

    # ------------------------------------------------------------------ speech -------------
    def encode_speech(self, x, am, mask_time_indices=None):
        h, fm = self.speech(x, am, mask_time_indices)
        return dict(h=h, fmask=fm, ctc_logits=self.speech.ctc_head(h))

    @torch.no_grad()
    def segment(self, enc: dict, texts: Optional[List[str]] = None, mode: str = "greedy") -> Segmentation:
        """Subword segmentation of every utterance. 'viterbi': the given transcripts are force-aligned to
        the CTC posteriors (batched Viterbi); 'greedy': the CTC hypothesis segments itself. Empty
        hypotheses fall back to uniform 0.3 s pseudo-tokens (no token ids)."""
        logits = enc["ctc_logits"].float()
        lens = enc["fmask"].sum(1)
        B, T = enc["fmask"].shape
        lens_l = [int(v) for v in lens.tolist()]
        tok_ids: List[Optional[List[int]]] = [None] * B
        spans: List[List[Tuple[int, int]]] = [[] for _ in range(B)]
        source = [""] * B
        todo_greedy = list(range(B))
        if mode == "viterbi":
            if texts is None or len(texts) != B:
                raise ValueError("viterbi segmentation needs one transcript per utterance")
            tn = [ctc_text(t) if t else "" for t in texts]
            vi = [b for b in range(B) if tn[b]]
            if vi:
                counts = ctc_viterbi_batch(logits[vi].log_softmax(-1), lens[vi],
                                           [self.chars.encode(tn[b], already_normalized=True) for b in vi])
                for j, b in enumerate(vi):
                    cs = counts_to_spans(counts[j]) if counts[j] is not None else uniform_char_spans(len(tn[b]), lens_l[b])
                    tok_ids[b], spans[b] = token_spans(self.tok, tn[b], cs, self.max_tok)
                    source[b] = "viterbi" if counts[j] is not None else "uniform"
            todo_greedy = [b for b in range(B) if not tn[b]]
        elif mode != "greedy":
            raise ValueError(mode)
        if todo_greedy:
            arg = logits.argmax(-1).cpu().numpy()
            for b in todo_greedy:
                text, cs = self.chars.greedy_segments(arg[b, :lens_l[b]].tolist())
                if text.strip():
                    tok_ids[b], spans[b] = token_spans(self.tok, text, cs, self.max_tok)
                    source[b] = "greedy"
        for b in range(B):
            if not spans[b]:
                k = max(1, lens_l[b] // 15)
                spans[b], tok_ids[b], source[b] = uniform_char_spans(k, max(1, lens_l[b])), None, "pseudo"
        mask = spans_to_mask(spans, lens_l, T).to(logits.device)
        n_tok = torch.tensor([len(s) for s in spans], device=logits.device)
        maxp = logits.softmax(-1).max(-1).values                                    # (B,T)
        mf = mask.float()
        conf = (mf * maxp[:, None, :]).sum(-1) / mf.sum(-1).clamp(min=1)
        return Segmentation(tok_ids=tok_ids, mask=mask, n_tok=n_tok, source=source, conf=conf)

    def speech_inputs(self, enc: dict, seg: Segmentation, src_langs: List[str]):
        """[lang] e_1..e_N [</s>] — the speech counterpart of the NLLB source format."""
        emb = self.nllb.model.encoder
        if self.sab_mode == "anchored":
            B0, N0 = seg.mask.shape[:2]
            ids = torch.zeros(B0, N0, dtype=torch.long, device=seg.mask.device)
            has = torch.zeros(B0, N0, dtype=torch.bool, device=seg.mask.device)
            for b, t in enumerate(seg.tok_ids):
                if t:
                    ids[b, :len(t)] = torch.tensor(t[:N0], device=ids.device)
                    has[b, :len(t)] = True
            with torch.no_grad():
                base = nllb_token_embeds(emb, ids) * has[..., None].to(torch.float32)
            e = self.sab(enc["h"], seg.mask, base, seg.conf)
        elif self.sab_mode == "acoustic":
            e = self.sab(enc["h"], seg.mask)
        else:
            raise ValueError(self.sab_mode)
        B, N, D = e.shape
        dev = e.device
        lang_emb = nllb_token_embeds(emb, torch.tensor([self.tok.lang_ids[l] for l in src_langs], device=dev)).to(e.dtype)
        eos_emb = nllb_token_embeds(emb, torch.tensor([self.tok.eos_id], device=dev))[0].to(e.dtype)
        L = int(seg.n_tok.max()) + 2
        X = e.new_zeros(B, L, D)
        M = torch.zeros(B, L, dtype=torch.bool, device=dev)
        X[:, 0] = lang_emb
        for b in range(B):
            n = int(seg.n_tok[b])
            X[b, 1:1 + n] = e[b, :n]
            X[b, 1 + n] = eos_emb
            M[b, :n + 2] = True
        return X, M, e

    def speech_memory(self, enc: dict, seg: Segmentation, src_langs: List[str]):
        X, M, e = self.speech_inputs(enc, seg, src_langs)
        mem = self.nllb.model.encoder(inputs_embeds=X, attention_mask=M.long()).last_hidden_state
        return mem, M, e

    # ------------------------------------------------------------------ text ---------------
    def encode_text(self, input_ids, attention_mask):
        return self.nllb.model.encoder(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state

    def fuse(self, mem, mask, vis, has_vis, force_gate=None):
        """Returns (memory, gate, gate_logit); gate/logit are None when no item of the batch has an image."""
        if not bool(has_vis.any()):
            return mem, None, None
        return self.vgate(mem, mask, vis.to(mem.device), has_vis.to(mem.device), force_gate)

    # ------------------------------------------------------------------ decoder -------------
    def decoder_logprobs(self, memory, mem_mask, dec_in, labels):
        """Log-probabilities (N_valid, V) at the valid label positions only (the 256k LM head is huge)."""
        h = self.nllb.model.decoder(input_ids=dec_in, encoder_hidden_states=memory,
                                    encoder_attention_mask=mem_mask.long(), use_cache=False).last_hidden_state
        sel = labels != -100
        return self.nllb.lm_head(h[sel]).float().log_softmax(-1), sel

    @staticmethod
    def seq_loss(logp, sel, batch, label_smoothing=0.1):
        dev = logp.device
        labels = batch["labels"].to(dev)
        nll = -logp.gather(1, labels[sel][:, None]).squeeze(1)
        flat = (1 - label_smoothing) * nll - label_smoothing * logp.mean(-1) if label_smoothing > 0 else nll
        ce = torch.zeros(labels.shape, device=dev, dtype=flat.dtype)
        ce[sel] = flat
        w = batch["tok_weights"].to(dev) * sel.float()
        per = (ce * w).sum(1) / w.sum(1).clamp(min=1e-6)
        sw = batch["sample_weight"].to(dev)
        return (per * sw).sum() / sw.sum().clamp(min=1e-6), per

    @torch.no_grad()
    def teacher_topk(self, memory, mem_mask, dec_in, sel, k: int):
        h = self.nllb.model.decoder(input_ids=dec_in, encoder_hidden_states=memory,
                                    encoder_attention_mask=mem_mask.long(), use_cache=False).last_hidden_state
        v, i = self.nllb.lm_head(h[sel]).topk(k, dim=-1)  # top-k before up-casting: no (N, 256k) fp32 copy
        return torch.softmax(v.float(), -1), i

    @staticmethod
    def kd_loss(logp, sel, t_prob, t_idx, batch):
        w = batch["tok_weights"].to(logp.device)[sel]
        kd = -(t_prob * logp.gather(1, t_idx)).sum(-1)
        return (kd * w).sum() / w.sum().clamp(min=1e-6)

    # ------------------------------------------------------------------ generation ----------
    @torch.no_grad()
    def generate(self, memory, mem_mask, tgt_langs: List[str], beams=4, nret=1, max_new_tokens=200):
        """Beam search in the target language(s); returns (texts grouped per input, token ids)."""
        B = memory.shape[0]
        nret = min(nret, beams)
        prefix = torch.tensor([[self.tok.decoder_start_id, self.tok.lang_ids[l]] for l in tgt_langs],
                              device=memory.device)
        out = self.nllb.generate(encoder_outputs=BaseModelOutput(last_hidden_state=memory),
                                 attention_mask=mem_mask.long(), decoder_input_ids=prefix, num_beams=beams,
                                 num_return_sequences=nret, max_new_tokens=max_new_tokens, do_sample=False,
                                 early_stopping=True, length_penalty=1.0)
        seqs = (out if isinstance(out, torch.Tensor) else out.sequences)[:, 2:]
        texts = [self.tok.decode(s.tolist()) for s in seqs]
        return [texts[i * nret:(i + 1) * nret] for i in range(B)], seqs

    @torch.no_grad()
    def score_texts(self, memory, mem_mask, texts: List[str], langs: List[str], chunk: int = 8) -> List[List[float]]:
        """Teacher-forced per-token log-probabilities of given hypotheses (incl. language tag and </s>)."""
        out = []
        for s in range(0, len(texts), chunk):
            tt, ll = texts[s:s + chunk], langs[s:s + chunk]
            lab = _pad_labels([self.tok.tgt(t, l) for t, l in zip(tt, ll)], -100).to(memory.device)
            dec_in = decoder_inputs(lab, self.tok.decoder_start_id, self.tok.pad_id)
            logp, sel = self.decoder_logprobs(memory[s:s + chunk], mem_mask[s:s + chunk], dec_in, lab)
            tok_lp = torch.zeros(lab.shape, device=memory.device)
            tok_lp[sel] = logp.gather(1, lab[sel][:, None]).squeeze(1)
            out += [tok_lp[i][sel[i]].tolist() for i in range(len(tt))]
        return out

    def tts_cond(self, langs, domains, genders, device):
        li = torch.tensor([self.langs.index(l) for l in langs], device=device)
        di = torch.tensor([TTS_DOMAINS[d] for d in domains], device=device)
        gi = torch.tensor([TTS_GENDERS.get(g, len(TTS_GENDERS)) for g in genders], device=device)
        return self.tts.cond(li, di, gi)

    def resolve_tts_condition(self, lang: str, domain: Optional[str] = None, gender: Optional[str] = None
                              ) -> Tuple[str, str]:
        """(domain, gender) actually seen with `lang` in TTS training — an unseen embedding is noise
        (the v1 failure). Preference: the requested pair, then any seen pair of the language."""
        li = self.langs.index(lang)
        seen = [(d, g) for (l, d, g) in self.tts.seen_conds if l == li]
        if not seen:
            raise RuntimeError(f"TTS was never trained for {lang}")
        inv_d = {v: k for k, v in TTS_DOMAINS.items()}
        inv_g = {v: k for k, v in TTS_GENDERS.items()}
        want = (TTS_DOMAINS.get(domain, -1), TTS_GENDERS.get(gender, len(TTS_GENDERS)) if gender else -1)
        for d, g in seen:
            if d == want[0] and (want[1] == -1 or g == want[1]):
                return inv_d[d], inv_g.get(g, "NA")
        for d, g in seen:
            if d == want[0]:
                return inv_d[d], inv_g.get(g, "NA")
        d, g = Counter(seen).most_common(1)[0][0]
        return inv_d[d], inv_g.get(g, "NA")


# =============================================================================================
#           EMA TEACHER + MASKED POSTERIOR DISTILLATION (MPD)  — novel UDA objective
# =============================================================================================
class EMATeacher:
    """Mean-teacher copy of the speech encoder + CTC head (fp32, may live on a 2nd GPU).
    The EMA decay is warmed up as min(decay, (1+n)/(10+n)) so the teacher tracks the student quickly
    while the CTC head is still being learnt, and the top-K layer outputs are captured with forward
    hooks (identical semantics across transformers versions)."""

    def __init__(self, speech: SpeechEncoder, decay: float, top_k: int, device):
        self.device = device
        self.decay = decay
        self.n_updates = 0
        self.lengths_fn = speech.lengths
        self.w2v = copy.deepcopy(speech.w2v).to(device).eval()
        self.ctc = copy.deepcopy(speech.ctc_head).to(device).eval()
        for p in list(self.w2v.parameters()) + list(self.ctc.parameters()):
            p.requires_grad = False
        s_named = dict(speech.w2v.named_parameters())
        self.names = [n for n, _ in self.w2v.named_parameters() if s_named[n].requires_grad]
        t_named = dict(self.w2v.named_parameters())
        self.pairs = [(t_named[n], s_named[n]) for n in self.names]
        self.pairs += list(zip(self.ctc.parameters(), speech.ctc_head.parameters()))
        self._captured: List[torch.Tensor] = []
        for layer in self.w2v.encoder.layers[-top_k:]:
            layer.register_forward_hook(self._hook)

    def _hook(self, module, inputs, output):
        self._captured.append(output[0] if isinstance(output, tuple) else output)

    @torch.no_grad()
    def update(self):
        d = min(self.decay, (1.0 + self.n_updates) / (10.0 + self.n_updates))
        for pt, ps in self.pairs:
            pt.mul_(d).add_(ps.detach().to(pt.device, pt.dtype), alpha=1 - d)
        self.n_updates += 1

    @torch.no_grad()
    def __call__(self, x, am):
        x, am = x.to(self.device), am.to(self.device)
        self._captured = []
        with amp_ctx(self.device):
            o = self.w2v(x, attention_mask=am)
            logits = self.ctc(o.last_hidden_state)
        hs = self._captured
        self._captured = []
        fm = lengths_to_mask(self.lengths_fn(am).to(logits.device), logits.shape[1])
        # data2vec target: average of instance-normalised top-K layer outputs (valid frames only)
        y = sum(masked_instance_norm(h.float(), fm) for h in hs) / len(hs)
        return logits.float(), y

    def state_dict(self):
        """Only the EMA-updated tensors (frozen layers are identical to the pretrained backbone)."""
        t_named = dict(self.w2v.named_parameters())
        return {"w2v": {n: t_named[n].detach().cpu() for n in self.names}, "ctc": self.ctc.state_dict(),
                "n_updates": self.n_updates}

    def load_state_dict(self, sd):
        t_named = dict(self.w2v.named_parameters())
        if set(sd["w2v"]) != set(self.names):
            raise RuntimeError("teacher checkpoint does not match the EMA-updated parameter set")
        with torch.no_grad():
            for n, v in sd["w2v"].items():
                t_named[n].copy_(v.to(t_named[n].device, t_named[n].dtype))
        self.ctc.load_state_dict(sd["ctc"])
        self.n_updates = int(sd["n_updates"])


def mpd_loss(model: KORA, teacher: EMATeacher, batch: dict, mc: ModelConfig, device) -> Tuple[torch.Tensor, dict]:
    """Masked Posterior Distillation.
    MSDA (Damianos et al., 2025) cascades self-supervision (stage 1) and Meta pseudo-labelling
    (stage 2). MPD fuses both at the FRAME level inside one objective: the student sees span-masked
    target-domain audio and must predict, at masked frames, (i) the EMA teacher's CTC posteriors —
    a soft, frame-level pseudo-label kept only where the teacher is confident, with blank frames
    down-weighted to prevent blank collapse — and (ii) the teacher's data2vec latent targets, which
    keep learning where posteriors are unreliable. (MPD's loss RISES once the teacher becomes confident:
    more frames pass the threshold and masked frames are harder than unmasked ones — expected.)"""
    x, am = batch["x"].to(device), batch["am"].to(device)
    t_logits, y = teacher(x, am)
    fm = lengths_to_mask(model.speech.lengths(am), t_logits.shape[1])
    msk = span_mask(fm, mc.mpd_mask_prob, mc.mpd_mask_len) & fm
    h, _ = model.speech(x, am, mask_time_indices=msk)
    if h.shape[1] != t_logits.shape[1]:
        raise RuntimeError("student/teacher frame counts differ")
    t_logits, y = t_logits.to(device), y.to(device)
    s_logp = model.speech.ctc_head(h).float().log_softmax(-1)
    p_t = t_logits.softmax(-1)
    conf, arg = p_t.max(-1)
    c = (conf >= mc.mpd_conf_thr).float() * torch.where(arg == 0, torch.full_like(conf, mc.mpd_blank_weight),
                                                         torch.ones_like(conf)) * msk.float()
    kl = (p_t * (torch.log(p_t.clamp(min=1e-8)) - s_logp)).sum(-1)
    l_post = (c * kl).sum() / c.sum().clamp(min=1.0)
    pred = model.speech.latent_head(h).float()
    l_lat = F.smooth_l1_loss(pred[msk], y[msk]) if bool(msk.any()) else pred.sum() * 0.0
    stats = dict(mpd_conf_frac=float((c > 0).float().sum() / msk.float().sum().clamp(min=1)))
    return l_post + mc.mpd_lambda_latent * l_lat, stats


# =============================================================================================
#                       CTC SELF-ALIGNMENT  (durations for the TTS branch)
# =============================================================================================
def ctc_frames_to_mel(counts: List[int], n_mel: int, ctc_fps: float, mel_fps: float) -> List[int]:
    """Converts per-token CTC frame counts into per-token mel-frame durations summing exactly to n_mel."""
    cum = np.cumsum([0] + list(counts)) / ctc_fps * mel_fps
    b = np.round(cum).astype(int)
    b[-1] = n_mel
    b = np.maximum.accumulate(np.clip(b, 0, n_mel))
    d = np.diff(b)
    assert int(d.sum()) == n_mel and (d >= 0).all()
    return d.tolist()


# =============================================================================================
#     ROUTE-AGREEMENT PSEUDO-LABELLING (RAPL, route-balanced) + AGREEMENT-MASKED TOKEN PLs (AMT-PL)
# =============================================================================================
class LengthKDE:
    """Joint density of (log duration, log #chars) on labelled source data (Gheini et al.'s Ratio-KDE),
    exposed as a percentile score in [0,1] so it can enter RAPL's geometric mean."""

    def __init__(self, durs: List[float], lens: List[int]):
        from scipy.stats import gaussian_kde
        X = np.vstack([np.log(np.asarray(durs) + 1e-3), np.log(np.asarray(lens) + 1.0)])
        self.kde = gaussian_kde(X)
        self.ref = np.sort(self.kde(X))

    def score(self, durs, lens) -> np.ndarray:
        X = np.vstack([np.log(np.asarray(durs) + 1e-3), np.log(np.asarray(lens) + 1.0)])
        return np.searchsorted(self.ref, self.kde(X)) / len(self.ref)


def route_mbr(routes: Dict[str, List[str]], normalized: bool = False, within: float = 0.1,
              selectable: Optional[Sequence[str]] = None) -> Tuple[str, str, float]:
    """ROUTE-BALANCED MBR. v1 pooled all hypotheses, so a route contributing 4 near-identical n-best entries
    always out-voted a route contributing one (KORA-mbr == KORA-direct). Here a hypothesis is scored by
    its mean chrF agreement with every OTHER route (each route = one vote, whatever its n-best size).
    Agreement inside its own route is used ONLY to break (near-)ties: added to the utility, it would hand a
    route with several near-duplicate n-best entries a bonus that a single-hypothesis route can never get.
    With a single non-empty route this reduces to ordinary MBR. Returns (hypothesis, its route, utility).
    `within` > 0 enables the tie-break (utilities equal to within `within` chrF points count as tied)."""
    key = normalize_text if normalized else (lambda s: s)
    R = {}
    for r, cs in routes.items():
        uniq = list(dict.fromkeys(c for c in cs if c and c.strip()))
        if uniq:
            R[r] = uniq
    if not R:
        return "", "", 0.0
    cand_routes = [r for r in R if selectable is None or r in selectable] or list(R)
    keys = {r: [key(c) for c in cs] for r, cs in R.items()}
    scored = []
    for r in cand_routes:
        for i, c in enumerate(R[r]):
            ci = keys[r][i]
            others = [float(np.mean([sent_chrf(o, ci) for o in keys[q]])) for q in R if q != r]
            same = [sent_chrf(o, ci) for j, o in enumerate(keys[r]) if j != i]
            s_same = float(np.mean(same)) if same else 0.0
            u = float(np.mean(others)) if others else s_same  # single route: ordinary MBR
            scored.append((u, s_same, c, r))
    top = max(u for u, _, _, _ in scored)
    tied = [x for x in scored if x[0] >= top - max(within, 1e-9)]  # candidates in the scan order
    u, _, c, r = max(tied, key=lambda x: x[1]) if within > 0 else tied[0]
    return c, r, u


def word_agreement(hyp: str, alt: str) -> List[bool]:
    """For each whitespace word of `hyp`: is it matched (after normalisation) in the alternative route?"""
    hw = [normalize_text(w) for w in hyp.split()]
    aw = [normalize_text(w) for w in alt.split()]
    agree = [False] * len(hw)
    for blk in difflib.SequenceMatcher(a=hw, b=aw, autojunk=False).get_matching_blocks():
        for k in range(blk.size):
            agree[blk.a + k] = True
    return agree


def token_weights_from_words(tok: TextTok, text: str, agree: List[bool], w_min: float) -> List[float]:
    """Maps word-level route agreement onto the exact label sequence built by the collator
    ([lang] tokens </s>) using the fast tokenizer's character offsets."""
    ids, offs = tok.encode_with_offsets(text)
    spans = [(m.start(), m.end()) for m in re.finditer(r"\S+", text)]
    if len(spans) != len(agree):
        raise ValueError("word segmentation mismatch between agreement and offsets")
    w = []
    for (s, e) in offs:
        wi = next((k for k, (a, b) in enumerate(spans) if a <= s < b or a < e <= b), None)
        w.append(1.0 if (wi is None or agree[wi]) else w_min)
    assert len(w) == len(ids)
    return [1.0] + w + [float(np.mean(w)) if w else 1.0]


class KoraDecoding:
    """Decoding primitives shared by the pseudo-labeller, the dev evaluation and the inferencer."""

    def __init__(self, cfg: KoraConfig, model: KORA, tok: TextTok, chars: CharVocab, featurizer: SpeechFeaturizer,
                 vis: Optional[VisStore], device):
        self.cfg, self.model, self.tok, self.chars, self.feat, self.vis = cfg, model, tok, chars, featurizer, vis
        self.device = torch.device(device)

    def _ac(self):
        return amp_ctx(self.device)

    @torch.no_grad()
    def encode(self, wavs: List[np.ndarray]) -> dict:
        x, am = self.feat(wavs)
        with self._ac():
            return self.model.eval().encode_speech(x.to(self.device), am.to(self.device))

    @torch.no_grad()
    def ctc_logps(self, enc) -> List[np.ndarray]:
        lp = enc["ctc_logits"].float().log_softmax(-1)
        lens = enc["fmask"].sum(1).tolist()
        return [lp[i, :int(lens[i])].cpu().numpy() for i in range(lp.shape[0])]

    @torch.no_grad()
    def ctc_greedy(self, enc) -> List[str]:
        arg = enc["ctc_logits"].argmax(-1).cpu().numpy()
        lens = enc["fmask"].sum(1).tolist()
        return [self.chars.decode_ctc(arg[i, :int(lens[i])].tolist()) for i in range(arg.shape[0])]

    def ctc_nbest(self, logps: List[np.ndarray], beam: int, n: int) -> List[List[Tuple[str, float]]]:
        out = []
        for lp in logps:
            seen: Dict[str, float] = {}
            for ids, s in ctc_prefix_beam_search(lp, beam=beam):
                t = self.chars.ids_to_text(ids)
                if t not in seen:
                    seen[t] = s
            out.append(list(seen.items())[:n] or [("", 0.0)])
        return out

    @torch.no_grad()
    def memory(self, enc, src_langs: List[str], seg_mode: str = "greedy", texts: Optional[List[str]] = None,
               vis_rows: Optional[List[int]] = None, gate_mode: str = "learned"):
        with self._ac():
            seg = self.model.segment(enc, texts, seg_mode)
            mem, mm, _ = self.model.speech_memory(enc, seg, src_langs)
            gates = [None] * len(src_langs)
            if vis_rows is not None and gate_mode != "off":
                v, hv = self.vis.get(vis_rows)
                mem, g, _ = self.model.fuse(mem, mm, v.to(self.device), hv.to(self.device),
                                            force_gate=1.0 if gate_mode == "open" else None)
                if g is not None:
                    gates = g.tolist()
        return mem, mm, gates, seg

    @torch.no_grad()
    def nbest(self, mem, mm, tgt_langs: List[str], beams: int, n: int) -> List[List[str]]:
        with self._ac():
            out, _ = self.model.generate(mem, mm, tgt_langs, beams=beams, nret=n,
                                         max_new_tokens=self.cfg.eval.max_new_tokens)
        return out

    @torch.no_grad()
    def aed_scores(self, mem_i, mm_i, texts: List[str], lang: str) -> List[float]:
        """Sum of token log-probabilities (the trivially forced language tag excluded)."""
        with self._ac():
            lps = self.model.score_texts(mem_i.expand(len(texts), -1, -1), mm_i.expand(len(texts), -1), texts,
                                         [lang] * len(texts))
        return [float(np.sum(l[1:])) for l in lps]

    @torch.no_grad()
    def ctc_scores(self, lp: np.ndarray, texts: List[str]) -> List[float]:
        """Exact CTC log-likelihood of each text (all alignments), -inf when it cannot be aligned."""
        T = lp.shape[0]
        tg = [self.chars.encode(t) for t in texts]
        valid = [i for i, t in enumerate(tg) if t]
        out = [-np.inf] * len(texts)
        if not valid or T == 0:
            return out
        lpt = torch.from_numpy(lp)[:, None, :].expand(T, len(valid), lp.shape[1]).contiguous()
        targets = torch.cat([torch.tensor(tg[i], dtype=torch.long) for i in valid])
        tl = torch.tensor([len(tg[i]) for i in valid], dtype=torch.long)
        nll = F.ctc_loss(lpt, targets, torch.full((len(valid),), T, dtype=torch.long), tl, blank=0,
                         reduction="none", zero_infinity=False)
        for j, i in enumerate(valid):
            v = float(nll[j])
            out[i] = -v if np.isfinite(v) else -np.inf
        return out

    @torch.no_grad()
    def joint(self, enc, langs: List[str], lam: float, beams: int, n_ctc: int = 5) -> List[str]:
        """Two-route joint decoding: CTC prefix-beam n-best ∪ AED n-best (from the greedy-segmented SAB
        memory), each candidate rescored with λ·log P_CTC + (1-λ)·log P_AED (attention rescoring of the
        union, cf. WeNet; v1 only re-ranked the AED n-best, so it could never escape an AED failure).
        Same code path as the dev selection and the multi-mode evaluation (decode_asr_all)."""
        return decode_asr_all(self, enc, langs, beams, [lam], ["joint"], n_ctc)[f"joint@{lam}"]

    @torch.no_grad()
    def text_memory(self, texts: List[str], src_langs: List[str], vis_rows=None, gate_mode="learned"):
        ids = _pad_labels([self.tok.src(t, l) for t, l in zip(texts, src_langs)], self.tok.pad_id).to(self.device)
        am = (ids != self.tok.pad_id).long()
        gates = [None] * len(texts)
        with self._ac():
            mem = self.model.eval().encode_text(ids, am)
            if vis_rows is not None and gate_mode != "off":
                v, hv = self.vis.get(vis_rows)
                mem, g, _ = self.model.fuse(mem, am.bool(), v.to(self.device), hv.to(self.device),
                                            force_gate=1.0 if gate_mode == "open" else None)
                if g is not None:
                    gates = g.tolist()
        return mem, am, gates

    @torch.no_grad()
    def translate_texts(self, texts, src_langs, tgt_lang, beams, vis_rows=None, gate_mode="learned", n=1):
        mem, am, gates = self.text_memory(texts, src_langs, vis_rows, gate_mode)
        return self.nbest(mem, am, [tgt_lang] * len(texts), beams, n), gates


class PseudoLabeler:
    def __init__(self, cfg: KoraConfig, dec: KoraDecoding, timer: Timer):
        self.cfg, self.dec, self.timer = cfg, dec, timer
        self.model, self.tok = dec.model, dec.tok
        self.pc = cfg.pl

    @torch.no_grad()
    def label_speech(self, entries: List[dict], kdes: Dict[str, LengthKDE], out_path: str) -> List[dict]:
        """Runs every route on every unlabeled utterance and scores them (resumable)."""
        missing = sorted({e["lang"] for e in entries} - set(kdes))
        if missing:
            raise RuntimeError(f"no length KDE for {missing}")
        pc = self.pc
        log = JsonlLog(out_path)
        done = {r["uid"] for r in log.rows}
        todo = sorted([e for e in entries if e["uid"] not in done], key=lambda e: (e["dur"], e["uid"]))
        self.model.eval()
        try:
            for s in range(0, len(todo), pc.pl_batch):
                self.timer.check()
                chunk = todo[s:s + pc.pl_batch]
                self._label_batch(chunk, kdes, log)
                log.flush()
                if (s // pc.pl_batch) % 20 == 0:
                    LOG.info(f"  PL {s + len(chunk)}/{len(todo)}")
        finally:
            log.close()
        by_uid = {r["uid"]: r for r in read_jsonl(out_path)}
        return [by_uid[e["uid"]] for e in entries]

    def _label_batch(self, chunk: List[dict], kdes, log: JsonlLog):
        pc, D = self.pc, self.dec
        n = len(chunk)
        langs = [e["lang"] for e in chunk]
        enc = D.encode([load_audio(e["audio"]) for e in chunk])
        # transcript routes: CTC prefix beam search and the AED decoder reading the greedy SAB memory
        logps = D.ctc_logps(enc)
        ctc_nb = D.ctc_nbest(logps, pc.ctc_beam, pc.nbest)
        mem, mm, _, _ = D.memory(enc, langs, "greedy")
        aed_nb = [[normalize_text(a) for a in x] for x in D.nbest(mem, mm, langs, pc.beams, pc.nbest)]
        t_sel = [route_mbr({"ctc": [t for t, _ in ctc_nb[i]], "aed": aed_nb[i]}, normalized=True,
                           within=pc.mbr_within_route) for i in range(n)]
        t_star = [t for t, _, _ in t_sel]
        t_route = [r for _, r, _ in t_sel]
        ctc_best = [ctc_nb[i][0][0] for i in range(n)]
        aed_best = [aed_nb[i][0] if aed_nb[i] else "" for i in range(n)]
        # translation routes: direct (the same SAB memory, built on the CTC hypothesis' own segmentation and
        # therefore independent of the selected transcript) and cascade (MT of the selected transcript)
        st_nb = D.nbest(mem, mm, ["en"] * n, pc.beams, pc.nbest)
        # both translation routes contribute an n-best of the same size (a 1-best against a 4-best would
        # hand the larger route more chances to win the max, whatever the evidence)
        y_casc_nb = D.translate_texts(t_star, langs, "en", pc.beams, n=pc.nbest)[0]
        y_casc = [y[0] for y in y_casc_nb]
        y_sel = [route_mbr({"cascade": y_casc_nb[i], "direct": st_nb[i]}, within=pc.mbr_within_route)
                 for i in range(n)]
        y_star = [y for y, _, _ in y_sel]
        y_route = [r for _, r, _ in y_sel]
        with amp_ctx(D.device):
            lp_t = self.model.score_texts(mem, mm, t_star, langs)
        for i, e in enumerate(chunk):
            lang = langs[i]
            n_chars = len(ctc_text(t_star[i]))
            s_len = float(kdes[lang].score([e["dur"]], [max(1, n_chars)])[0])
            s_ctc = (1.0 - min(1.0, cer([ctc_best[i]], [aed_best[i]]) / 100.0)) if ctc_best[i] and aed_best[i] else 0.0
            s_route = sent_chrf(y_casc[i], st_nb[i][0]) / 100.0 if st_nb[i] else 0.0
            s_conf = float(np.exp(np.mean(lp_t[i][1:-1]))) if len(lp_t[i]) > 2 else 0.0
            rep = detect_repetition(t_star[i], pc.rep_ngram, pc.rep_max) or \
                detect_repetition(y_star[i], pc.rep_ngram, pc.rep_max)
            ws = [pc.w_ctc_aed, pc.w_route, pc.w_conf, pc.w_len]
            vs = [s_ctc, s_route, s_conf, s_len]
            empty = not t_star[i].strip() or not y_star[i].strip()
            S = 0.0 if (rep or empty) else float(
                np.exp(sum(w * np.log(max(v, 1e-4)) for w, v in zip(ws, vs)) / sum(ws)))
            # AMT-PL token weights: supervise only sub-structures the independent routes agree on.
            alt_t = aed_best[i] if t_route[i] == "ctc" else ctc_best[i]
            tw_t = token_weights_from_words(self.tok, t_star[i], word_agreement(t_star[i], alt_t), pc.token_weight_min)
            alt_y = (st_nb[i][0] if st_nb[i] else "") if y_route[i] == "cascade" else y_casc[i]
            tw_y = token_weights_from_words(self.tok, y_star[i], word_agreement(y_star[i], alt_y), pc.token_weight_min)
            log.append(dict(uid=e["uid"], lang=lang, audio=e["audio"], audio24=e.get("audio24"), dur=e["dur"],
                            domain=e["domain"], t_star=t_star[i], t_route=t_route[i], y_star=y_star[i],
                            y_route=y_route[i], t_ctc=ctc_best[i], t_aed=aed_best[i],
                            y_direct=st_nb[i][0] if st_nb[i] else "", y_casc=y_casc[i],
                            s_ctc_aed=s_ctc, s_route=s_route, s_conf=s_conf, s_len=s_len, repetition=bool(rep),
                            S=S, n_words=len(t_star[i].split()), n_tok_src=len(lp_t[i]),
                            n_tok_tgt=len(self.tok.tgt(y_star[i], "en")),
                            tok_w={lang: tw_t, "en": tw_y}))

    # ------------------------------------------------------------ selection strategies -------
    @staticmethod
    def label_fields(strategy: str) -> Tuple[str, str]:
        """RAPL trains on the route-balanced MBR labels; every baseline strategy on the plain AED outputs."""
        return ("t_star", "y_star") if strategy == "rapl" else ("t_aed", "y_direct")

    def select(self, recs: List[dict], strategy: str, retention: float) -> List[dict]:
        """Per-language selection so that easier languages do not crowd out harder ones."""
        pc = self.pc
        ft, fy = self.label_fields(strategy)
        out = []
        for lang in sorted({r["lang"] for r in recs}):
            R = [r for r in recs if r["lang"] == lang and r[ft].strip() and r[fy].strip()]
            if strategy == "vanilla":
                sel = R
            elif strategy == "confidence":
                sel = sorted(R, key=lambda r: -r["s_conf"])[: int(retention * len(R))]
            elif strategy == "kde":
                sel = sorted(R, key=lambda r: -r["s_len"])[: int(pc.kde_keep * len(R))]
            elif strategy == "xsim":
                sel = sorted(R, key=lambda r: -r["s_xsim"])[: int(pc.xsim_keep * len(R))]
            elif strategy == "kurdish":
                sel = [r for r in R if 1.0 <= r["dur"] <= 30.0 and 90 <= r["n_words"] / (r["dur"] / 60) <= 200
                       and r["s_conf"] >= 0.9 and 0.5 <= r["n_tok_src"] / max(1, r["n_tok_tgt"]) <= 1.5
                       and not r["repetition"]]
            elif strategy == "rapl":
                sel = sorted([r for r in R if r["S"] > 0], key=lambda r: -r["S"])[: int(retention * len(R))]
            else:
                raise ValueError(strategy)
            out += sel
        return out

    def to_train_entries(self, sel: List[dict], variant: "Variant") -> List[dict]:
        ft, fy = self.label_fields(variant.pl_strategy)
        out = []
        for r in sel:
            t, y = normalize_text(r[ft]), r[fy]
            if variant.pl_strategy == "rapl":
                ctc = t if r["s_ctc_aed"] >= self.pc.ctc_agree_thr else None  # CTC only where the routes agree
                tok_w = r["tok_w"] if variant.token_mask else None
                weight = 0.5 + 0.5 * float(r["S"])
            else:
                ctc, tok_w, weight = t, None, 1.0
            out.append(dict(uid="pl_" + r["uid"], audio=r["audio"], dur=r["dur"], lang=r["lang"],
                            targets={r["lang"]: t, "en": y}, seg_text=t, ctc_text=ctc, tok_w=tok_w, weight=weight,
                            domain="bible"))
        return out

    # ------------------------------------------------------------ silver multimodal text -----
    @torch.no_grad()
    def label_text_mmt(self, havg_train: List[dict], vis_index: Dict[str, int], out_path: str,
                       max_per_lang: int, langs: List[str]) -> List[dict]:
        """EN captions -> target language with the image-conditioned route and the text-only route; scored by
        route agreement x round-trip (back-translation) chrF; only agreeing routes become silver data."""
        D = self.dec
        pool = sorted(havg_train, key=lambda r: r["uid"])
        random.Random(0).shuffle(pool)
        pool = pool[:max_per_lang]
        log = JsonlLog(out_path)
        done = {(r["uid"], r["lang"]) for r in log.rows}
        beams = self.pc.beams
        try:
            for lang in langs:
                todo = [r for r in pool if (r["uid"], lang) not in done]
                for s in range(0, len(todo), 32):
                    self.timer.check()
                    ch = todo[s:s + 32]
                    n = len(ch)
                    rows = [vis_index[r["uid"]] for r in ch]
                    y_img, gates = D.translate_texts([r["en"] for r in ch], ["en"] * n, lang, beams, rows, "learned")
                    y_img = [y[0] for y in y_img]
                    y_txt = [y[0] for y in D.translate_texts([r["en"] for r in ch], ["en"] * n, lang, beams)[0]]
                    bt = [y[0] for y in D.translate_texts(y_img, [lang] * n, "en", beams)[0]]
                    for i, r in enumerate(ch):
                        s_agree = sent_chrf(y_txt[i], y_img[i]) / 100
                        s_rt = sent_chrf(r["en"], bt[i]) / 100
                        bad = detect_repetition(y_img[i], self.pc.rep_ngram, self.pc.rep_max) or not y_img[i].strip()
                        S = 0.0 if bad else float(np.sqrt(max(s_agree, 1e-4) * max(s_rt, 1e-4)))
                        log.append(dict(uid=r["uid"], lang=lang, en=r["en"], y=y_img[i], y_txt=y_txt[i], bt=bt[i],
                                        S=S, gate=float(gates[i]) if gates[i] is not None else None, vis_row=rows[i]))
                    log.flush()
        finally:
            log.close()
        return read_jsonl(out_path)


# =============================================================================================
#                              CHECKPOINTING / PIPELINE STATE
# =============================================================================================
def trainable_state_dict(model: nn.Module, half: bool = False) -> Dict[str, torch.Tensor]:
    return {n: (p.detach().cpu().half() if half else p.detach().cpu())
            for n, p in model.named_parameters() if p.requires_grad}


def load_trainable_state(model: nn.Module, sd: Dict[str, torch.Tensor]):
    params = dict(model.named_parameters())
    trainable = {n for n, p in params.items() if p.requires_grad}
    missing, unexpected = trainable - sd.keys(), sd.keys() - params.keys()
    if missing or unexpected:
        raise RuntimeError(f"checkpoint mismatch: missing {sorted(missing)[:5]}, unexpected {sorted(unexpected)[:5]}")
    with torch.no_grad():
        for n, v in sd.items():
            params[n].copy_(v.to(params[n].device, params[n].dtype))


class CheckpointManager:
    """Atomic saves and keep-last-K rotation of resumable step checkpoints."""

    def __init__(self, ckpt_dir: str, keep_last: int):
        self.dir = ckpt_dir
        self.keep = keep_last
        os.makedirs(ckpt_dir, exist_ok=True)

    def path(self, name):
        return os.path.join(self.dir, name)

    def save(self, name: str, state: dict, phase: Optional[str] = None):
        p = self.path(name)
        torch.save(state, p + ".tmp")
        os.replace(p + ".tmp", p)
        if phase is not None:
            for f in self.step_files(phase)[: -self.keep]:
                os.remove(f)

    def step_files(self, phase: str) -> List[str]:
        pat = re.compile(rf"^step_{re.escape(phase)}_(\d+)\.pt$")
        files = [(int(mt.group(1)), f) for f in os.listdir(self.dir) if (mt := pat.match(f))]
        return [self.path(f) for _, f in sorted(files)]

    def latest_for_phase(self, phase: str) -> Optional[str]:
        files = self.step_files(phase)
        return files[-1] if files else None

    def load(self, name_or_path: str, device="cpu"):
        p = self.path(name_or_path) if os.path.basename(name_or_path) == name_or_path else name_or_path
        return torch.load(p, map_location=device, weights_only=False)

    def exists(self, name):
        return os.path.exists(self.path(name))

    def remove(self, name):
        if self.exists(name):
            os.remove(self.path(name))


def import_previous_session(paths: PathConfig):
    """If the output of a previous Kaggle version is attached under /kaggle/input and this session starts
    from scratch, copy its checkpoints, pipeline state, pseudo-labels, TTS data, logs and results so that
    every phase resumes where it stopped. The most advanced attached run is chosen."""
    if os.path.exists(paths.state_path) or not os.path.isdir("/kaggle/input"):
        return
    cands = glob.glob(os.path.join("/kaggle/input", "**", paths.run_name, "pipeline_state.json"), recursive=True)
    if not cands:
        return

    def progress(p):
        st = load_json(p, {})
        return (sum(1 for v in st.values() if v is True), os.path.getmtime(p))

    src_root = os.path.dirname(max(cands, key=progress))
    LOG.info(f"importing the state of a previous session from {src_root}")
    for name in ["models", "pseudo_labels", "logs", "tts_data", "results"]:
        s, d = os.path.join(src_root, name), os.path.join(paths.work_dir, name)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
    for name in ["pipeline_state.json", "char_vocab.json"]:
        s = os.path.join(src_root, name)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(paths.work_dir, name))
    # mel paths recorded by the previous session point to its own working directory
    tts_dir = os.path.join(paths.work_dir, "tts_data")
    for f in glob.glob(os.path.join(tts_dir, "*.jsonl")):
        rows = read_jsonl(f, allow_truncated_tail=True)
        for r in rows:
            if r.get("mel"):
                r["mel"] = os.path.join(tts_dir, "mels", os.path.basename(r["mel"]))
        write_jsonl(f, rows)


# =============================================================================================
#                                          TRAINER
# =============================================================================================
@dataclass
class Variant:
    name: str
    pl_strategy: str = "rapl"
    token_mask: bool = True
    use_mpd: bool = True
    gate_supervision: bool = True
    use_pl: bool = True
    sab_anchor: bool = True   # hypothesis-anchored SAB + encoder matching + text-route distillation


VARIANTS = {
    "rapl_full": Variant("rapl_full"),
    "no_pl": Variant("no_pl", use_pl=False),
    "vanilla_pl": Variant("vanilla_pl", pl_strategy="vanilla", token_mask=False),
    "kde_pl": Variant("kde_pl", pl_strategy="kde", token_mask=False),
    "rapl_no_tokenmask": Variant("rapl_no_tokenmask", token_mask=False),
    "rapl_no_mpd": Variant("rapl_no_mpd", use_mpd=False),
    "no_gate_supervision": Variant("no_gate_supervision", gate_supervision=False),
    "no_sab_anchor": Variant("no_sab_anchor", sab_anchor=False),
}
SPEECH_TASKS = ("asr", "st", "pl", "smmt", "mpd")


class Trainer:
    def __init__(self, cfg: KoraConfig, model: KORA, tok: TextTok, chars: CharVocab, data: dict,
                 vis_store: VisStore, featurizer: SpeechFeaturizer, device, aux_device):
        self.cfg, self.model, self.tok, self.chars, self.data = cfg, model, tok, chars, data
        self.device, self.aux = torch.device(device), torch.device(aux_device)
        self.tc = cfg.train
        self.featurizer = featurizer
        self.collate = Collator(tok, chars, vis_store, featurizer, cfg.train.image_drop)
        self.ckpt = CheckpointManager(cfg.paths.ckpt_dir, cfg.train.keep_last)
        self.state_path = cfg.paths.state_path
        self.state = load_json(self.state_path, {})
        self.hist_path = os.path.join(cfg.paths.log_dir, "history.jsonl")
        self.timer = Timer(cfg.train.max_session_hours)
        self.teacher: Optional[EMATeacher] = EMATeacher(model.speech, cfg.model.ema_decay,
                                                        cfg.model.mpd_top_k_layers, self.aux)
        self.dec = KoraDecoding(cfg, model, tok, chars, featurizer, vis_store, self.device)
        self.pl = PseudoLabeler(cfg, self.dec, self.timer)
        self.tts_dir = cfg.paths.tts_dir
        self.mel_stats_path = os.path.join(self.tts_dir, "mel_stats.json")
        self.mel_fps = cfg.model.tts_sr / cfg.model.tts_hop
        self.ctc_fps = model.speech.fps
        self._ctc_warmup = 0
        self._build_static_entries()

    # ------------------------------------------------------------------ state helpers -------
    def mark(self, key, value=True):
        self.state[key] = value
        save_json(self.state_path, self.state)

    def done(self, key) -> bool:
        return self.state.get(key) is True

    def check_time(self):
        self.timer.check()

    def release_teacher(self):
        self.teacher = None
        free_memory()

    # ------------------------------------------------------------------ entries -------------
    def _build_static_entries(self):
        d = self.data
        par = d["parallel"]
        max_dur = self.cfg.data.max_dur
        vi = d["vis_index"]
        fl_train = [m for m in d["fleurs"] if m["split"] == "train" and m["dur"] <= max_dur]
        self.speech_entries = []
        for m in fl_train:
            norm = ctc_text(m["text"])
            if not norm:
                continue
            tg = {l: t for l, t in par[m["sid"]].items() if l != m["lang"]}
            tg[m["lang"]] = norm   # ASR target = the canonical transcript (shared with the CTC head)
            self.speech_entries.append(dict(uid=m["uid"], audio=m["audio"], dur=m["dur"], lang=m["lang"], targets=tg,
                                            seg_text=norm, ctc_text=norm, domain="fleurs"))
        yf_train = [y for y in d["yfacc"] if y["split"] == "train" and y["dur"] <= max_dur and ctc_text(y["yo"])]
        for y in yf_train:
            norm = ctc_text(y["yo"])
            self.speech_entries.append(dict(uid=y["uid"], audio=y["audio"], dur=y["dur"], lang="yo",
                                            targets={"yo": norm, "en": y["en"]}, seg_text=norm, ctc_text=norm,
                                            domain="yfacc"))
        self.st_entries = [e for e in self.speech_entries if len(e["targets"]) > 1]
        self.mt_entries = []
        for sid in sorted({m["sid"] for m in fl_train}):
            tx = par[sid]
            for a in sorted(tx):
                for b in sorted(tx):
                    if a != b:
                        self.mt_entries.append(dict(src=tx[a], src_lang=a, tgt=tx[b], tgt_lang=b))
        self.mt_bible_entries = []
        for row in d.get("bible_text", []):
            ls = [l for l in self.cfg.all_langs if l in row]
            for a in ls:
                for b in ls:
                    if a != b:
                        self.mt_bible_entries.append(dict(src=row[a], src_lang=a, tgt=row[b], tgt_lang=b))
        self.mmt_entries = []
        for r in d["havg"]:
            if r["split"] == "train":
                row = vi[r["uid"]]
                self.mmt_entries.append(dict(src=r["en"], src_lang="en", tgt=r["ha"], tgt_lang="ha", vis_row=row))
                self.mmt_entries.append(dict(src=r["ha"], src_lang="ha", tgt=r["en"], tgt_lang="en", vis_row=row))
        for y in d["yfacc"]:
            if y["split"] == "train":
                row = vi[y["uid"]]
                self.mmt_entries.append(dict(src=y["en"], src_lang="en", tgt=y["yo"], tgt_lang="yo", vis_row=row))
                self.mmt_entries.append(dict(src=y["yo"], src_lang="yo", tgt=y["en"], tgt_lang="en", vis_row=row))
        # speech + image -> English: REAL Yorùbá speech (YFACC); synthetic Spoken-HaVG only if enabled
        self.smmt_entries = [dict(uid=y["uid"] + "_img", audio=y["audio"], dur=y["dur"], lang="yo",
                                  targets={"en": y["en"], "yo": ctc_text(y["yo"])}, seg_text=ctc_text(y["yo"]),
                                  ctc_text=ctc_text(y["yo"]), vis_row=vi[y["uid"]], domain="yfacc")
                             for y in yf_train]
        self.smmt_entries += [dict(uid=s["uid"], audio=s["audio"], dur=s["dur"], lang="ha",
                                   targets={"en": s["en"], "ha": ctc_text(s["text"])}, seg_text=ctc_text(s["text"]),
                                   ctc_text=ctc_text(s["text"]), vis_row=vi[s["havg_uid"]], domain="spoken_havg")
                              for s in d.get("spoken", []) if s["split"] == "train"]
        self.target_audio = [b for b in d["bible"] if b["split"] == "target_adapt" and b["dur"] <= max_dur]
        self.bible_by_uid = {b["uid"]: b for b in d["bible"]}
        self.mpd_entries = [dict(uid=b["uid"], audio=b["audio"], dur=b["dur"], domain="bible") for b in self.target_audio]
        self.mpd_entries += [dict(uid=m["uid"], audio=m["audio"], dur=m["dur"], domain="fleurs")
                             for m in random.Random(0).sample(fl_train, min(len(fl_train), len(self.mpd_entries) // 2 + 1))]
        for name in ["speech_entries", "st_entries", "mt_entries", "mmt_entries", "target_audio"]:
            if not getattr(self, name):
                raise RuntimeError(f"no training entries for {name}")
        LOG.info(f"entries: speech {len(self.speech_entries)} | st {len(self.st_entries)} | mt {len(self.mt_entries)} | "
                 f"mt_bible {len(self.mt_bible_entries)} | mmt {len(self.mmt_entries)} | "
                 f"speech+image {len(self.smmt_entries)} | target audio {len(self.target_audio)} | mpd {len(self.mpd_entries)}")

    def available_tasks(self, pl_entries=None, tts_entries=None) -> set:
        av = {"asr", "st", "mt", "mmt", "mpd"}
        if self.mt_bible_entries:
            av.add("mt_bible")
        if self.smmt_entries:
            av.add("smmt")
        if pl_entries:
            av.add("pl")
        if tts_entries:
            av.add("tts")
        return av

    def _speech_loader(self, entries, mode, seed):
        ds = SpeechSeqDataset(entries, mode)
        bs = DurationBatchSampler(ds.durations(), self.tc.max_batch_seconds, self.tc.max_batch_utts, seed)
        return infinite_loader(ds, self.collate.speech, batch_sampler=bs, num_workers=self.tc.num_workers)

    def make_loaders(self, weights: Dict[str, float], pl_entries=None, silver=None, tts_entries=None, seed=0):
        L = {}
        tc = self.tc
        for task, w in weights.items():
            if w <= 0:
                continue
            if task == "asr":
                L[task] = self._speech_loader(self.speech_entries, "asr", seed)
            elif task == "st":
                L[task] = self._speech_loader(self.st_entries, "st", seed + 1)
            elif task == "mt":
                L[task] = infinite_loader(TextPairDataset(self.mt_entries), self.collate.text, tc.text_batch,
                                          num_workers=tc.num_workers, seed=seed + 2)
            elif task == "mt_bible":
                L[task] = infinite_loader(TextPairDataset(self.mt_bible_entries), self.collate.text, tc.text_batch,
                                          num_workers=tc.num_workers, seed=seed + 8)
            elif task == "mmt":
                L[task] = infinite_loader(TextPairDataset(self.mmt_entries + (silver or [])), self.collate.text,
                                          tc.text_batch, num_workers=tc.num_workers, seed=seed + 3)
            elif task == "smmt":
                L[task] = self._speech_loader(self.smmt_entries, "smmt", seed + 4)
            elif task == "mpd":
                ds = UnlabeledAudioDataset(self.mpd_entries)
                bs = DurationBatchSampler(ds.durations(), tc.max_batch_seconds * 0.6, tc.max_batch_utts, seed + 5)
                L[task] = infinite_loader(ds, self.collate.speech, batch_sampler=bs, num_workers=tc.num_workers)
            elif task == "pl":
                if not pl_entries:
                    raise RuntimeError("task 'pl' requested without pseudo-labelled entries")
                L[task] = self._speech_loader(pl_entries, "pl", seed + 6)
            elif task == "tts":
                if not tts_entries:
                    raise RuntimeError("task 'tts' requested without TTS entries")
                L[task] = infinite_loader(TTSDataset(tts_entries), self.collate.tts, tc.tts_batch,
                                          num_workers=tc.num_workers, seed=seed + 7)
            else:
                raise ValueError(task)
        return L

    # ------------------------------------------------------------------ optimisation --------
    def build_optimizer(self, total_steps: int):
        groups = defaultdict(list)
        for n, p in self.model.named_parameters():
            if not p.requires_grad:
                continue
            if n.startswith("speech.w2v."):
                g = "speech"
            elif n.startswith("nllb."):
                g = "lora"
            elif n.startswith("tts."):
                g = "tts"
            else:
                g = "new"
            groups[(g, p.ndim >= 2 and "lora_" not in n)].append(p)  # no decay on norms, biases, LoRA
        lrs = dict(speech=self.tc.lr_speech, lora=self.tc.lr_lora, tts=self.tc.lr_tts, new=self.tc.lr_new)
        opt = torch.optim.AdamW([dict(params=v, lr=lrs[g], weight_decay=self.tc.weight_decay if decay else 0.0,
                                      name=f"{g}{'' if decay else '_nodecay'}")
                                 for (g, decay), v in sorted(groups.items())], betas=(0.9, 0.98), eps=1e-6)
        warm = min(self.tc.warmup, max(1, total_steps // 10))

        def lr_lambda(s):
            if s < warm:
                return (s + 1) / warm
            prog = (s - warm) / max(1, total_steps - warm)
            return max(0.05, 0.5 * (1 + math.cos(math.pi * min(1.0, prog))))

        sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_lambda)
        scaler = torch.amp.GradScaler("cuda", enabled=self.tc.fp16 and self.device.type == "cuda")
        return opt, sched, scaler

    # ------------------------------------------------------------------ losses --------------
    def _nll_per_sample(self, memory, mask, batch):
        logp, sel = self.model.decoder_logprobs(memory, mask, batch["decoder_input_ids"].to(memory.device),
                                                batch["labels"].to(memory.device))
        return self.model.seq_loss(logp, sel, batch, label_smoothing=0.0)[1]

    def _gate_losses(self, mem, mask, batch, g, logit, variant: Variant):
        """Counterfactual supervision of the visual-utility gate + visual-awareness margin."""
        vis, has = batch["vis"].to(mem.device), batch["has_vis"].to(mem.device)
        idx = torch.nonzero(has).flatten()
        if len(idx) < 2 or not variant.gate_supervision:
            return {}
        perm = idx[torch.roll(torch.arange(len(idx), device=mem.device), 1)]
        vis_cf = vis.clone()
        vis_cf[idx] = vis[perm]
        f_true, _, _ = self.model.vgate(mem, mask, vis, has, force_gate=1.0)
        f_cf, _, _ = self.model.vgate(mem, mask, vis_cf, has, force_gate=1.0)
        nll_true = self._nll_per_sample(f_true, mask, batch)
        nll_cf = self._nll_per_sample(f_cf, mask, batch)
        delta = (nll_cf - nll_true)[has]
        u = torch.sigmoid(delta.detach() / 0.1)
        l_gate = F.binary_cross_entropy_with_logits(logit[has], u)
        l_aw = F.relu(self.tc.aware_margin - delta).mean()
        return dict(gate=self.tc.lambda_gate * l_gate, aware=self.tc.lambda_aware * l_aw,
                    _cf_delta=float(delta.mean()), _gate_mean=float(g[has].mean()))

    def _ctc_loss(self, enc, batch):
        dev = self.device
        tlens = batch["ctc_lengths"].to(dev)
        valid = tlens > 0
        if not bool(valid.any()):
            return enc["ctc_logits"].new_zeros((), dtype=torch.float)
        lp = enc["ctc_logits"].float().log_softmax(-1).transpose(0, 1)
        l = F.ctc_loss(lp, batch["ctc_targets"].to(dev), enc["fmask"].sum(1), tlens, blank=0, reduction="none",
                       zero_infinity=True)
        l = l / tlens.clamp(min=1).float()
        w = valid.float() * batch["sample_weight"].to(dev)
        return (l * w).sum() / w.sum().clamp(min=1e-6)

    def _speech_seq(self, task: str, batch: dict, variant: Variant, enc: dict, parts: dict):
        """SAB speech->text step. Segmentation comes from the CTC hypothesis (the test-time condition) in
        `sab_greedy_prob` of the batches and from the force-aligned transcript otherwise; losses: CE on the
        targets + top-k distillation from the model's own text route reading the gold transcript +
        token-synchronous NLLB-encoder matching wherever the segmentation's subwords equal the gold ones.
        The 'no_sab_anchor' ablation uses acoustic-only vectors and CE only."""
        m, tc, dev = self.model, self.tc, self.device
        greedy = random.random() < tc.sab_greedy_prob
        seg = m.segment(enc, batch["seg_text"], "greedy" if greedy else "viterbi")
        # diagnostics (logged, not optimised): share of utterances whose CTC alignment failed (uniform /
        # pseudo-token fallback) — high values mean the bridge is fed without a usable alignment
        parts["_seg_fallback"] = float(np.mean([s in ("uniform", "pseudo") for s in seg.source]))
        mem, mmask, _ = m.speech_memory(enc, seg, batch["src_lang"])
        dec_mem = mem
        if task == "smmt" and "vis" in batch:
            dec_mem, g, logit = m.fuse(mem, mmask, batch["vis"], batch["has_vis"])
            if g is not None:
                parts.update(self._gate_losses(mem, mmask, batch, g, logit, variant))
        labels = batch["labels"].to(dev)
        dec_in = batch["decoder_input_ids"].to(dev)
        logp, sel = m.decoder_logprobs(dec_mem, mmask, dec_in, labels)
        parts["seq"], _ = m.seq_loss(logp, sel, batch, tc.label_smoothing)
        if not variant.sab_anchor or task == "pl":
            return
        gold = [self.tok.encode(t)[: m.max_tok] if t else [] for t in batch["seg_text"]]
        t_src = [[self.tok.lang_ids[l]] + g + [self.tok.eos_id] for l, g in zip(batch["src_lang"], gold)]
        t_ids = _pad_labels(t_src, self.tok.pad_id).to(dev)
        t_am = (t_ids != self.tok.pad_id).long()
        was_training = m.nllb.training
        m.nllb.eval()  # the teacher is deterministic: no dropout / LoRA dropout in its targets
        try:
            with torch.no_grad():
                t_mem = m.encode_text(t_ids, t_am)
                t_prob, t_idx = m.teacher_topk(t_mem, t_am.bool(), dec_in, sel, tc.kd_topk)
        finally:
            m.nllb.train(was_training)
        parts["kd"] = tc.lambda_kd * m.kd_loss(logp, sel, t_prob, t_idx, batch)
        # token-synchronous NLLB-encoder matching: same subwords at the same positions -> position-wise MSE
        rows = torch.tensor([seg.tok_ids[b] is not None and seg.tok_ids[b] == gold[b] for b in range(len(gold))],
                            device=dev)
        if greedy:
            parts["_hyp_exact"] = float(rows.float().mean())  # CTC hypothesis spells exactly the gold subwords
        if bool(rows.any()):
            Lc = min(mem.shape[1], t_mem.shape[1])
            valid = mmask[:, :Lc] & t_am[:, :Lc].bool() & rows[:, None]
            dd = ((mem[:, :Lc].float() - t_mem[:, :Lc].float()) ** 2).mean(-1)
            parts["enc"] = tc.lambda_encmatch * (dd * valid).sum() / valid.sum().clamp(min=1)

    def compute(self, task: str, batch: dict, variant: Variant, step: int = 10 ** 9) -> Tuple[torch.Tensor, dict]:
        m, dev = self.model, self.device
        logs = {}
        if task in ("asr", "st", "pl", "smmt"):
            enc = m.encode_speech(batch["x"].to(dev), batch["am"].to(dev))
            parts = {"ctc": self.tc.lambda_ctc * self._ctc_loss(enc, batch)}
            if step >= self._ctc_warmup:  # curriculum: the bridge needs a CTC alignment worth following
                self._speech_seq(task, batch, variant, enc, parts)
        elif task in ("mt", "mt_bible", "mmt"):
            ids, am = batch["input_ids"].to(dev), batch["attention_mask"].to(dev)
            mem = m.encode_text(ids, am)
            mask = am.bool()
            parts = {}
            dec_mem = mem
            if task == "mmt" and "vis" in batch:
                dec_mem, g, logit = m.fuse(mem, mask, batch["vis"], batch["has_vis"])
                if g is not None:
                    parts.update(self._gate_losses(mem, mask, batch, g, logit, variant))
            logp, sel = m.decoder_logprobs(dec_mem, mask, batch["decoder_input_ids"].to(dev), batch["labels"].to(dev))
            parts["seq"], _ = m.seq_loss(logp, sel, batch, self.tc.label_smoothing)
        elif task == "mpd":
            l, st = mpd_loss(m, self.teacher, batch, self.cfg.model, dev)
            parts = {"mpd": l}
            logs.update(st)
        elif task == "tts":
            cond = m.tts_cond(batch["lang"], batch["domain"], batch["gender"], dev)
            parts = m.tts.loss(batch["chars"].to(dev), batch["char_mask"].to(dev), batch["dur"].to(dev),
                               batch["mel"].to(dev), batch["mel_mask"].to(dev), cond, batch["sample_weight"].to(dev))
        else:
            raise ValueError(task)
        loss = sum(v for k, v in parts.items() if not k.startswith("_"))
        for k, v in parts.items():  # '_'-prefixed parts are diagnostics; their names never shadow a loss term
            key = f"{task}/{k.lstrip('_')}"
            if key in logs:
                raise KeyError(f"log key collision: {key}")
            logs[key] = float(v.detach()) if torch.is_tensor(v) else float(v)
        return loss, logs

    # ------------------------------------------------------------------ quick dev eval ------
    @torch.no_grad()
    def dev_eval(self, warn: bool = True) -> Dict[str, float]:
        """FLEURS-dev ASR (CTC and AED through SAB) and ST, plus collapse detectors: output diversity and
        the source-sensitivity index (v1's collapse would have been caught at the first evaluation).
        The multimodal branches are monitored on the HaVG and YFACC dev splits (used for nothing else):
        en->ha MMT with the true vs an incongruent image, and speech+image -> English. They are logged
        but do not enter dev_score, so snapshot selection stays a speech criterion."""
        D = self.dec
        par = self.data["parallel"]
        dev = [x for x in self.data["fleurs"] if x["split"] == "dev" and "en" in par[x["sid"]]]
        res = {}
        per_lang = max(2, self.tc.dev_eval_utts // len(self.cfg.data.african_langs))
        for lang in self.cfg.data.african_langs:
            E = sorted([x for x in dev if x["lang"] == lang], key=lambda x: x["uid"])[:per_lang]
            h_ctc, h_aed, h_st, refs_a, refs_s = [], [], [], [], []
            for s in range(0, len(E), 8):
                ch = E[s:s + 8]
                n = len(ch)
                enc = D.encode([load_audio(e["audio"]) for e in ch])
                h_ctc += D.ctc_greedy(enc)
                mem, mm, _, _ = D.memory(enc, [lang] * n, "greedy")
                h_aed += [x[0] for x in D.nbest(mem, mm, [lang] * n, 1, 1)]
                h_st += [x[0] for x in D.nbest(mem, mm, ["en"] * n, 1, 1)]
                refs_a += [e["text"] for e in ch]
                refs_s += [par[e["sid"]]["en"] for e in ch]
            res[f"wer_ctc_{lang}"] = wer(refs_a, h_ctc)
            res[f"wer_aed_{lang}"] = wer(refs_a, h_aed)
            res[f"chrf_st_{lang}"] = chrf(refs_s, h_st)
            res[f"ssi_st_{lang}"] = source_sensitivity(refs_s, h_st)
            res[f"distinct_st_{lang}"] = distinct_ratio(h_st)
            res[f"distinct_aed_{lang}"] = distinct_ratio(h_aed)
            if warn and (res[f"distinct_st_{lang}"] < 0.5 or res[f"distinct_aed_{lang}"] < 0.5):
                LOG.warning(f"[collapse detector] {lang}: distinct ST {res[f'distinct_st_{lang}']:.2f}, "
                            f"AED {res[f'distinct_aed_{lang}']:.2f}, SSI {res[f'ssi_st_{lang}']:.2f}")
        vi = self.data["vis_index"]
        n_mm = max(2, self.tc.dev_eval_utts // 2)
        hd = sorted([h for h in self.data["havg"] if h["split"] == "dev"], key=lambda h: h["uid"])[:n_mm]
        if len(hd) >= 2:
            rows = [vi[h["uid"]] for h in hd]

            def mmt(vis_rows):
                out = []
                for s in range(0, len(hd), 16):
                    ch = hd[s:s + 16]
                    out += [x[0] for x in D.translate_texts([h["en"] for h in ch], ["en"] * len(ch), "ha", 1,
                                                            vis_rows[s:s + 16])[0]]
                return out

            refs = [h["ha"] for h in hd]
            res["chrf_mmt_en_ha"] = chrf(refs, mmt(rows))
            res["img_delta_mmt"] = res["chrf_mmt_en_ha"] - chrf(refs, mmt(rows[1:] + rows[:1]))
        yd = sorted([y for y in self.data["yfacc"] if y["split"] == "dev"], key=lambda y: y["uid"])[:max(2, n_mm // 2)]
        if len(yd) >= 2:
            hyps = []
            for s in range(0, len(yd), 8):
                ch = yd[s:s + 8]
                enc = D.encode([load_audio(y["audio"]) for y in ch])
                mem, mm, _, _ = D.memory(enc, ["yo"] * len(ch), "greedy", vis_rows=[vi[y["uid"]] for y in ch])
                hyps += [x[0] for x in D.nbest(mem, mm, ["en"] * len(ch), 1, 1)]
            res["chrf_smmt_yo_en"] = chrf([y["en"] for y in yd], hyps)
        res = {k: float(v) for k, v in res.items()}
        L = self.cfg.data.african_langs
        res["dev_score"] = float(np.mean([res[f"chrf_st_{l}"] for l in L]) +
                                 100 - np.mean([min(res[f"wer_ctc_{l}"], res[f"wer_aed_{l}"]) for l in L]))
        self.model.train()
        return res

    # ------------------------------------------------------------------ generic phase -------
    def _state_blob(self, phase, step, opt, sched, scaler):
        rng = dict(py=random.getstate(), np=np.random.get_state(), torch=torch.get_rng_state())
        if torch.cuda.is_available():
            rng["cuda"] = torch.cuda.get_rng_state_all()
        return dict(phase=phase, step=step, model=trainable_state_dict(self.model), optimizer=opt.state_dict(),
                    scheduler=sched.state_dict(), scaler=scaler.state_dict(), teacher=self.teacher.state_dict(),
                    rng=rng, time=time.time(), sab_mode=self.model.sab_mode)

    def _task_schedule(self, phase, tasks, probs, total_steps, mpd_warmup):
        """Deterministic task sequence of a phase (identical after resumption). MPD is not sampled during
        the first `mpd_warmup` steps, while the EMA teacher's CTC head is still untrained."""
        rng = np.random.default_rng(stable_hash(phase))
        sched = rng.choice(len(tasks), size=total_steps, p=probs)
        if "mpd" in tasks and mpd_warmup > 0 and len(tasks) > 1:
            mi = tasks.index("mpd")
            q = probs.copy()
            q[mi] = 0.0
            q /= q.sum()
            early = np.nonzero(sched[:mpd_warmup] == mi)[0]
            sched[early] = rng.choice(len(tasks), size=len(early), p=q)
        return sched

    def train_phase(self, phase: str, total_steps: int, weights: Dict[str, float], variant: Variant,
                    pl_entries=None, silver=None, tts_entries=None, mpd_warmup: int = 0, ctc_warmup: int = 0,
                    dev_eval: bool = True, seed_key: Optional[str] = None):
        """seed_key (default: the phase name) fixes the task schedule and the data order; ablations share one
        key so that they differ only in what their variant changes."""
        if self.done(f"{phase}_done"):
            LOG.info(f"[{phase}] already complete — skipping")
            return
        av = self.available_tasks(pl_entries, tts_entries)
        w = {k: v for k, v in weights.items() if v > 0 and k in av and (k != "mpd" or variant.use_mpd)}
        if not w:
            raise RuntimeError(f"[{phase}] no task has data")
        self._ctc_warmup = ctc_warmup
        self.model.sab_mode = "anchored" if variant.sab_anchor else "acoustic"
        seed_key = seed_key or phase
        tasks = list(w.keys())
        probs = np.asarray([w[t] for t in tasks], dtype=np.float64)
        probs = probs / probs.sum()
        schedule = self._task_schedule(seed_key, tasks, probs, total_steps, mpd_warmup)
        opt, sched, scaler = self.build_optimizer(total_steps)
        start = 0
        last = self.ckpt.latest_for_phase(phase)
        if last:
            st = self.ckpt.load(last)
            load_trainable_state(self.model, st["model"])
            opt.load_state_dict(st["optimizer"])
            sched.load_state_dict(st["scheduler"])
            scaler.load_state_dict(st["scaler"])
            self.teacher.load_state_dict(st["teacher"])
            start = st["step"]
            random.setstate(st["rng"]["py"])
            np.random.set_state(st["rng"]["np"])
            torch.set_rng_state(st["rng"]["torch"])
            if torch.cuda.is_available() and "cuda" in st["rng"]:
                torch.cuda.set_rng_state_all(st["rng"]["cuda"])
            LOG.info(f"[{phase}] resumed from {os.path.basename(last)} at step {start}")
            del st
            free_memory()
        # data order: a session resumed at step `start` draws a fresh permutation instead of replaying the
        # batches the interrupted session already consumed (loaders keep no position across sessions)
        loaders = self.make_loaders(w, pl_entries, silver, tts_entries,
                                    seed=(stable_hash(seed_key) + 7919 * start) % 1_000_003)
        LOG.info(f"[{phase}] training {total_steps} steps | tasks {dict(zip(tasks, [round(float(p), 3) for p in probs]))}")
        self.model.train()
        agg = defaultdict(list)
        t0 = time.time()
        params = [p for g in opt.param_groups for p in g["params"]]
        best = self.state.get(f"best_{phase}")
        last_dev = None
        keep_best = self.tc.keep_best and dev_eval and not phase.startswith("abl_")
        with open(self.hist_path, "a") as hist:
            for step in range(start, total_steps):
                try:
                    self.check_time()
                except SessionTimeout:
                    self.ckpt.save(f"step_{phase}_{step:06d}.pt", self._state_blob(phase, step, opt, sched, scaler), phase)
                    raise
                task = tasks[schedule[step]]
                opt.zero_grad(set_to_none=True)
                n_ok = 0
                for _ in range(self.tc.grad_accum):
                    batch = next(loaders[task])
                    with torch.autocast(device_type="cuda", dtype=torch.float16,
                                        enabled=self.tc.fp16 and self.device.type == "cuda"):
                        loss, logs = self.compute(task, batch, variant, step)
                    if not torch.isfinite(loss):
                        LOG.warning(f"[{phase}] non-finite {task} loss at step {step}, micro-batch skipped")
                        continue
                    if not loss.requires_grad:
                        continue
                    scaler.scale(loss / self.tc.grad_accum).backward()
                    n_ok += 1
                    for k, v in logs.items():
                        agg[k].append(v)
                    agg[f"{task}/total"].append(float(loss.detach()))
                if n_ok:
                    scaler.unscale_(opt)
                    gn = torch.nn.utils.clip_grad_norm_([p for p in params if p.grad is not None], self.tc.clip)
                    scaler.step(opt)
                    scaler.update()
                    agg["grad_norm"].append(float(gn))
                    if task in SPEECH_TASKS and self.teacher is not None:
                        self.teacher.update()
                sched.step()
                if (step + 1) % self.tc.log_every == 0:
                    rec = {k: float(np.mean(v)) for k, v in agg.items()}
                    rec.update(phase=phase, step=step + 1, lr=sched.get_last_lr()[0],
                               sec_per_step=(time.time() - t0) / self.tc.log_every,
                               gpu_mem_gb=torch.cuda.max_memory_allocated() / 1e9 if torch.cuda.is_available() else 0.0)
                    hist.write(json.dumps(rec) + "\n")
                    hist.flush()
                    LOG.info(f"[{phase}] {step + 1}/{total_steps} " + " ".join(
                        f"{k}={v:.3f}" for k, v in rec.items() if k.endswith("total")) + f" lr={rec['lr']:.2e}")
                    agg.clear()
                    t0 = time.time()
                if dev_eval and ((step + 1) % self.tc.eval_every == 0 or step + 1 == total_steps):
                    dv = self.dev_eval(warn=step + 1 > ctc_warmup + self.tc.eval_every)
                    last_dev = dv["dev_score"]
                    dv.update(phase=phase, step=step + 1, kind="dev")
                    hist.write(json.dumps(dv) + "\n")
                    hist.flush()
                    LOG.info(f"[{phase}] dev: " + " ".join(f"{k}={v:.2f}" for k, v in dv.items() if isinstance(v, float)))
                    if keep_best and step + 1 > ctc_warmup and (best is None or last_dev > best):
                        best = last_dev
                        self.ckpt.save(f"best_{phase}.pt", dict(step=step + 1, score=best, sab_mode=self.model.sab_mode,
                                                                model=trainable_state_dict(self.model)))
                        self.mark(f"best_{phase}", best)
                if (step + 1) % self.tc.save_every == 0 and step + 1 < total_steps:
                    self.ckpt.save(f"step_{phase}_{step + 1:06d}.pt",
                                   self._state_blob(phase, step + 1, opt, sched, scaler), phase)
        if keep_best and best is not None and last_dev is not None and best > last_dev + 1e-6 \
                and self.ckpt.exists(f"best_{phase}.pt"):
            st = self.ckpt.load(f"best_{phase}.pt")
            load_trainable_state(self.model, st["model"])
            LOG.info(f"[{phase}] dev-selected snapshot of step {st['step']} restored (dev {best:.2f} > final {last_dev:.2f})")
            del st
        is_abl = phase.startswith("abl_")
        blob = dict(phase=phase, step=total_steps, model=trainable_state_dict(self.model, half=is_abl),
                    sab_mode=self.model.sab_mode)
        if phase == "stage1" or phase.startswith("round"):
            blob["teacher"] = self.teacher.state_dict()  # needed to continue training from this snapshot
        self.ckpt.save(f"final_{phase}.pt", blob)
        for f in self.ckpt.step_files(phase):
            os.remove(f)
        self.ckpt.remove(f"best_{phase}.pt")
        self.mark(f"{phase}_done")
        del opt, sched, scaler, loaders
        free_memory()

    # ------------------------------------------------------------------ TTS alignment -------
    @torch.no_grad()
    def build_tts_entries(self, items: List[dict], tag: str, mel_ex) -> List[dict]:
        """CTC self-alignment (batched Viterbi) -> per-character mel durations (resumable).
        items: {uid, audio (16 kHz), audio24 (24 kHz original) or None, text, lang, domain, gender, weight}"""
        log = JsonlLog(os.path.join(self.tts_dir, f"{tag}.jsonl"))
        done = {r["uid"] for r in log.rows}
        mel_dir = os.path.join(self.tts_dir, "mels")
        os.makedirs(mel_dir, exist_ok=True)
        m = self.model.eval()
        todo = [it for it in items if it["uid"] not in done]
        try:
            for s in range(0, len(todo), 8):
                self.check_time()
                ch = todo[s:s + 8]
                x, am = self.featurizer([load_audio(it["audio"]) for it in ch])
                with amp_ctx(self.device):
                    h, fm = m.speech(x.to(self.device), am.to(self.device))
                    logits = m.speech.ctc_head(h)
                texts = [tts_text(it["text"]) for it in ch]
                targets = [self.chars.encode(t, already_normalized=True) for t in texts]
                counts = ctc_viterbi_batch(logits.float().log_softmax(-1), fm.sum(1), targets)
                for i, it in enumerate(ch):
                    if counts[i] is None:  # label sequence longer than the audio allows: recorded, never retried
                        log.append(dict(uid=it["uid"], failed=True))
                        continue
                    wav24 = load_audio(it["audio24"], 24000) if it.get("audio24") else load_audio(it["audio"], 24000)
                    mel = mel_ex(wav24)
                    dur = ctc_frames_to_mel(counts[i], mel.shape[1], self.ctc_fps, self.mel_fps)
                    mp = os.path.join(mel_dir, f"{it['uid']}.npy")
                    np.save(mp, mel.astype(np.float16))
                    log.append(dict(uid=it["uid"], chars=targets[i], dur=dur, mel=mp, lang=it["lang"],
                                    domain=it["domain"], gender=it["gender"], weight=it["weight"], text=texts[i]))
                log.flush()
        finally:
            log.close()
        m.train()
        keep = {it["uid"] for it in items}
        return [r for r in read_jsonl(log.path) if not r.get("failed") and r["uid"] in keep]

    def tts_entries_from_disk(self, tag: str) -> List[dict]:
        return [r for r in read_jsonl(os.path.join(self.tts_dir, f"{tag}.jsonl"), allow_truncated_tail=True)
                if not r.get("failed")]

    def set_mel_stats(self, entries: List[dict]):
        if not os.path.exists(self.mel_stats_path):
            acc, acc2, n = 0.0, 0.0, 0
            for e in random.Random(0).sample(entries, min(1000, len(entries))):
                mel = np.load(e["mel"]).astype(np.float64)
                acc = acc + mel.sum(1)
                acc2 = acc2 + (mel ** 2).sum(1)
                n += mel.shape[1]
            mean = acc / n
            std = np.sqrt(np.maximum(acc2 / n - mean ** 2, 0.25))
            L = self.model.langs
            seen = sorted({(L.index(e["lang"]), TTS_DOMAINS[e["domain"]], TTS_GENDERS.get(e["gender"], len(TTS_GENDERS)))
                           for e in entries})
            save_json(self.mel_stats_path, dict(mean=mean.tolist(), std=std.tolist(), seen_conds=[list(s) for s in seen]))
        self.apply_mel_stats()

    def apply_mel_stats(self):
        st = load_json(self.mel_stats_path)
        if st is not None:
            self.model.tts.set_mel_stats(st["mean"], st["std"])
            self.model.tts.seen_conds = [tuple(s) for s in st.get("seen_conds", [])]

    def tts_tag(self) -> str:
        return "tts_bible_gold" if self.tc.tts_use_bible_gold else f"tts_pl_round{self.cfg.pl.rounds}"

    def prepare_tts_data(self) -> List[dict]:
        """TTS data aligned by the final recognition model's CTC head. Default: real studio BibleTTS speech
        with its gold text, ADAPTATION split only (test verses never; the recognition branches never saw
        this gold). tts_use_bible_gold=False reproduces the pseudo-label-trained TTS (RAPL labels)."""
        mel_ex = vocos_mel_extractor(self.cfg.model.vocoder_model, self.cfg.model)
        max_dur = self.cfg.data.max_dur
        if self.tc.tts_use_bible_gold:
            items = [dict(uid="tts_" + b["uid"], audio=b["audio"], audio24=b["audio24"], text=b["text"], lang=b["lang"],
                          domain="bible", gender="NA", weight=1.0)
                     for b in self.data["bible"] if b["split"] == "target_adapt" and b["text"] and b["dur"] <= max_dur]
        else:
            R = self.cfg.pl.rounds
            if R == 0:
                raise RuntimeError("pseudo-label TTS needs at least one RAPL round")
            recs = self._refresh_paths(read_jsonl(os.path.join(self.cfg.paths.pl_dir, f"pl_round{R}.jsonl")))
            sel = self.pl.select(recs, "rapl", self.cfg.pl.tts_pl_retention)
            items = [dict(uid="plt_" + s["uid"], audio=s["audio"], audio24=s.get("audio24"), text=s["t_star"],
                          lang=s["lang"], domain="bible", gender="NA", weight=0.5 + 0.5 * s["S"]) for s in sel]
        entries = self.build_tts_entries(items, self.tts_tag(), mel_ex)
        if not entries:
            raise RuntimeError("no TTS training utterance could be aligned")
        LOG.info(f"TTS data: {len(entries)} utterances ({dict(Counter(e['lang'] for e in entries))})")
        self.set_mel_stats(entries)
        return entries

    # ------------------------------------------------------------------ full curriculum -----
    def load_snapshot(self, name: str):
        st = self.ckpt.load(name)
        load_trainable_state(self.model, st["model"])
        self.model.sab_mode = st.get("sab_mode", "anchored")
        if "teacher" in st and self.teacher is not None:
            self.teacher.load_state_dict(st["teacher"])
        del st
        self.apply_mel_stats()
        free_memory()

    def recognition_final(self) -> str:
        return f"final_round{self.cfg.pl.rounds}.pt" if self.cfg.pl.rounds > 0 else "final_stage1.pt"

    def fit(self):
        tc, pc = self.tc, self.cfg.pl
        full = VARIANTS["rapl_full"]
        # ---------------- Stage 1: CTC warm-up -> supervised multi-task through SAB + MPD --------
        self.train_phase("stage1", tc.stage1_steps, tc.stage1_task_weights, full, mpd_warmup=tc.mpd_warmup_steps,
                         ctc_warmup=tc.ctc_warmup_steps)
        # ---------------- Rounds of RAPL -----------------------------------------------------
        kdes = self.fit_kdes()
        for r in range(1, pc.rounds + 1):
            phase = f"round{r}"
            if self.done(f"{phase}_done"):
                continue
            self.load_snapshot("final_stage1.pt" if r == 1 else f"final_round{r - 1}.pt")
            pl_entries, silver = self.prepare_round(r, kdes, full)
            self.train_phase(phase, tc.round_steps[r - 1], tc.round_task_weights, full, pl_entries, silver)
            if tc.prune_intermediate and r > 1:
                self.ckpt.remove(f"final_round{r - 1}.pt")
        # ---------------- TTS on CTC self-alignments -----------------------------------------
        if not self.done("tts_done"):
            self.load_snapshot(self.recognition_final())
            tts_entries = self.prepare_tts_data()
            self.train_phase("tts", tc.tts_steps, {"tts": 1.0}, full, tts_entries=tts_entries, dev_eval=False)
            if tc.prune_intermediate and pc.rounds > 0 and self.ckpt.exists("final_tts.pt"):
                self.ckpt.remove(self.recognition_final())
        self.load_snapshot("final_tts.pt")

    def fit_kdes(self) -> Dict[str, LengthKDE]:
        kdes = {}
        for lang in self.cfg.data.african_langs:
            E = [e for e in self.speech_entries if e["lang"] == lang]
            kdes[lang] = LengthKDE([e["dur"] for e in E], [len(e["ctc_text"]) for e in E])
        return kdes

    def prepare_round(self, r: int, kdes, variant: Variant):
        pl_path = os.path.join(self.cfg.paths.pl_dir, f"pl_round{r}.jsonl")
        if not self.done(f"round{r}_pl_done"):
            LOG.info(f"[round{r}] pseudo-labelling {len(self.target_audio)} target-domain utterances")
            self.pl.label_speech(self.target_audio, kdes, pl_path)
            self.mark(f"round{r}_pl_done")
        recs = read_jsonl(pl_path)
        return self.entries_from_pl(recs, variant, self.cfg.pl.retention_schedule[r - 1], r)

    def _refresh_paths(self, recs: List[dict]) -> List[dict]:
        """Pseudo-label records written by an earlier session carry that session's audio paths; they are
        re-resolved from the current manifest (the processed cache may live elsewhere now)."""
        out = []
        for r in recs:
            b = self.bible_by_uid.get(r["uid"])
            out.append(dict(r, audio=b["audio"], audio24=b.get("audio24")) if b else r)
        return out

    def entries_from_pl(self, recs, variant: Variant, retention: float, r: int):
        pc = self.cfg.pl
        recs = self._refresh_paths(recs)
        sel = self.pl.select(recs, variant.pl_strategy, retention) if variant.use_pl else []
        pl_entries = self.pl.to_train_entries(sel, variant)
        save_json(os.path.join(self.cfg.paths.pl_dir, f"selection_round{r}_{variant.name}.json"),
                  [s["uid"] for s in sel])
        silver_path = os.path.join(self.cfg.paths.pl_dir, "silver_mmt.jsonl")
        if not self.done("silver_done"):
            self.pl.label_text_mmt([h for h in self.data["havg"] if h["split"] == "train"], self.data["vis_index"],
                                   silver_path, pc.text_pl_max_per_lang,
                                   [l for l in self.cfg.data.african_langs if l != "ha"])
            self.mark("silver_done")
        srecs = read_jsonl(silver_path)
        silver = []
        for lang in sorted({s["lang"] for s in srecs}):
            S = sorted([s for s in srecs if s["lang"] == lang and s["S"] > 0], key=lambda s: (-s["S"], s["uid"]))
            for s in S[: int(pc.text_pl_retention * len(S))]:
                w = 0.5 + 0.5 * s["S"]
                silver.append(dict(src=s["en"], src_lang="en", tgt=s["y"], tgt_lang=lang, vis_row=s["vis_row"], weight=w))
                silver.append(dict(src=s["y"], src_lang=lang, tgt=s["en"], tgt_lang="en", vis_row=s["vis_row"], weight=w))
        LOG.info(f"[round{r}/{variant.name}] PL speech {len(pl_entries)} | silver MMT {len(silver)}")
        return pl_entries, silver

    def run_ablations(self) -> List[str]:
        """Training ablations from the SAME Stage-1 warm start and the SAME round-1 pseudo-labels."""
        tc = self.tc
        names = ["rapl_full"] + list(tc.ablations)
        unknown = [n for n in names if n not in VARIANTS]
        if unknown:
            raise ValueError(f"unknown ablations {unknown}")
        recs = read_jsonl(os.path.join(self.cfg.paths.pl_dir, "pl_round1.jsonl"))
        for name in names:
            v = VARIANTS[name]
            phase = f"abl_{name}"
            if self.done(f"{phase}_done"):
                continue
            self.load_snapshot("final_stage1.pt")
            pl_entries, silver = self.entries_from_pl(recs, v, self.cfg.pl.retention_schedule[0], 1)
            w = dict(tc.round_task_weights)
            if not v.use_pl:  # no pseudo-labels of any kind: neither RAPL speech labels nor silver MMT text
                w["pl"] = 0.0
                silver = None
            if not self.ckpt.latest_for_phase(phase):  # same RNG stream for every variant (resume restores its own)
                seed_everything(tc.seed)
            self.train_phase(phase, tc.ablation_steps, w, v, pl_entries, silver, seed_key="ablations")
        return names


# =============================================================================================
#                                         INFERENCER
# =============================================================================================
class KoraInferencer:
    """All inference modes of KORA with persistent outputs.
       ASR          : ctc (greedy) | ctcbeam (prefix beam) | aed (SAB->decoder) | joint (CTC ∪ AED rescoring)
       ST           : direct (SAB) | cascade (dev-selected transcript -> MT) | mbr (route-balanced MBR)
       joint        : transcript + translation from ONE speech encoding
       MT / MMT     : text (+ image, gate learned | off | forced open)
       Speech+image : spoken caption + image -> translation
       TTS          : text -> speech (Vocos 24 kHz), only for trained (language, domain) conditions
       S2ST         : speech -> text in target language -> speech"""

    def __init__(self, cfg: KoraConfig, model: KORA, dec: KoraDecoding, device, vocoder: Optional[Vocoder]):
        self.cfg, self.model, self.dec, self.device = cfg, model, dec, torch.device(device)
        self.tok, self.chars = dec.tok, dec.chars
        self.vocoder = vocoder
        self.asr_mode = "joint"          # replaced by the dev-selected mode (Evaluator.select_decoding)
        self.joint_lambda = 0.5          # replaced by the dev-selected value

    # ------------------------------------------------------------------ ASR ------------------
    @torch.no_grad()
    def transcribe(self, wavs: List[np.ndarray], langs: List[str], mode: Optional[str] = None, beams: int = 5,
                   lam: Optional[float] = None) -> List[str]:
        mode = mode or self.asr_mode
        lam = self.joint_lambda if lam is None else lam
        D = self.dec
        enc = D.encode(wavs)
        if mode == "ctc":
            return D.ctc_greedy(enc)
        if mode == "ctcbeam":
            return [nb[0][0] for nb in D.ctc_nbest(D.ctc_logps(enc), self.cfg.pl.ctc_beam, 1)]
        if mode == "aed":
            mem, mm, _, _ = D.memory(enc, langs, "greedy")
            return [normalize_text(n[0]) for n in D.nbest(mem, mm, langs, beams, 1)]
        if mode == "joint":
            return D.joint(enc, langs, lam, beams)
        raise ValueError(mode)

    # ------------------------------------------------------------------ ST -------------------
    @torch.no_grad()
    def translate_speech(self, wavs, src_langs, tgt_lang="en", route="mbr", beams=5, vis_rows=None,
                         gate_mode="learned"):
        D = self.dec
        enc = D.encode(wavs)
        n = len(wavs)
        mem, mm, gates, _ = D.memory(enc, src_langs, "greedy", vis_rows=vis_rows, gate_mode=gate_mode)
        nret = min(beams, 4) if route == "mbr" else 1
        direct = D.nbest(mem, mm, [tgt_lang] * n, beams, nret)
        if route == "direct":
            return [d[0] for d in direct], gates
        if route not in ("cascade", "mbr"):
            raise ValueError(route)
        transcripts = self._transcripts_from_enc(enc, src_langs, beams)
        casc_nb, _ = D.translate_texts(transcripts, src_langs, tgt_lang, beams, vis_rows, gate_mode, n=nret)
        if route == "cascade":
            return [c[0] for c in casc_nb], gates
        # the cascade route also proposes the MT of the greedy CTC transcript. It is a CANDIDATE of the same
        # route, not a route of its own (two cascades share the MT system and usually the transcript, and would
        # out-vote the direct route), and it takes the place of the last n-best entry so that both routes offer
        # the same number of candidates
        greedy = D.ctc_greedy(enc)
        casc_g = [c[0] for c in D.translate_texts(greedy, src_langs, tgt_lang, beams, vis_rows, gate_mode)[0]]
        out = [route_mbr({"direct": direct[i], "cascade": casc_nb[i][:max(1, nret - 1)] + [casc_g[i]]},
                         within=self.cfg.pl.mbr_within_route)[0] for i in range(n)]
        return out, gates

    def _transcripts_from_enc(self, enc, langs, beams) -> List[str]:
        D = self.dec
        if self.asr_mode == "ctc":
            return D.ctc_greedy(enc)
        if self.asr_mode == "ctcbeam":
            return [nb[0][0] for nb in D.ctc_nbest(D.ctc_logps(enc), self.cfg.pl.ctc_beam, 1)]
        if self.asr_mode == "aed":
            mem, mm, _, _ = D.memory(enc, langs, "greedy")
            return [normalize_text(n[0]) for n in D.nbest(mem, mm, langs, beams, 1)]
        return D.joint(enc, langs, self.joint_lambda, beams)

    @torch.no_grad()
    def joint(self, wavs, langs, tgt_lang="en", beams=5):
        """Joint transcription + translation from a single speech encoding (route-balanced MBR)."""
        D = self.dec
        enc = D.encode(wavs)
        transcripts = self._transcripts_from_enc(enc, langs, beams)
        mem, mm, _, _ = D.memory(enc, langs, "greedy")
        k = min(beams, 4)
        direct = D.nbest(mem, mm, [tgt_lang] * len(wavs), beams, k)
        casc = D.translate_texts(transcripts, langs, tgt_lang, beams, n=k)[0]
        trans = [route_mbr({"direct": direct[i], "cascade": casc[i]}, within=self.cfg.pl.mbr_within_route)[0]
                 for i in range(len(wavs))]
        return [dict(transcript=a, translation=b) for a, b in zip(transcripts, trans)]

    # ------------------------------------------------------------------ MT / MMT -------------
    @torch.no_grad()
    def translate_text(self, texts, src_lang, tgt_lang, beams=5, vis_rows=None, gate_mode="learned"):
        """Returns (translations, gates); gates are None for text-only decoding."""
        out, gates = self.dec.translate_texts(texts, [src_lang] * len(texts), tgt_lang, beams, vis_rows, gate_mode)
        return [o[0] for o in out], gates

    @torch.no_grad()
    def counterfactual_utility(self, texts, src_lang, refs, tgt_lang, vis_rows) -> Tuple[List[float], List[float]]:
        """Test-time Δ = NLL(ref | incongruent image) - NLL(ref | true image), gate forced open;
        compared with the learned gate g to check that the gate predicts real visual utility."""
        D = self.dec
        mem, am, _ = D.text_memory(texts, [src_lang] * len(texts))
        v, hv = D.vis.get(vis_rows)
        v, hv = v.to(self.device), hv.to(self.device)
        perm = torch.roll(torch.arange(len(texts), device=self.device), 1)
        with amp_ctx(self.device):
            _, g, _ = self.model.fuse(mem, am.bool(), v, hv)
            f1, _, _ = self.model.fuse(mem, am.bool(), v, hv, force_gate=1.0)
            f2, _, _ = self.model.fuse(mem, am.bool(), v[perm], hv, force_gate=1.0)
            l1 = self.model.score_texts(f1, am, refs, [tgt_lang] * len(refs))
            l2 = self.model.score_texts(f2, am, refs, [tgt_lang] * len(refs))
        delta = [float(np.mean(a) - np.mean(b)) for a, b in zip(l1, l2)]
        return delta, g.tolist()

    # ------------------------------------------------------------------ TTS / S2ST -----------
    @torch.no_grad()
    def synthesize(self, texts: List[str], lang: str, domain: Optional[str] = "bible", gender: Optional[str] = None,
                   steps=None, temperature=0.667, length_scale=1.0) -> Tuple[List[np.ndarray], List[np.ndarray]]:
        m = self.model.eval()
        domain, gender = m.resolve_tts_condition(lang, domain, gender)
        cond = m.tts_cond([lang], [domain], [gender], self.device)
        wavs, mels = [], []
        for t in texts:
            ids = self.chars.encode(tts_text(t), already_normalized=True)
            if not ids:
                raise ValueError(f"nothing to synthesise in {t!r}")
            chars = torch.tensor([ids], device=self.device)
            cm = torch.ones_like(chars, dtype=torch.bool)
            gen = torch.Generator(device=self.device).manual_seed(stable_hash(t))
            mel, mask, _ = m.tts.synthesize(chars, cm, cond, steps or self.cfg.model.fm_steps, temperature,
                                            length_scale, generator=gen)
            mel = mel[0][:, mask[0]]
            mels.append(mel.float().cpu().numpy())
            wavs.append(self.vocoder(mel.float()))
        return wavs, mels

    @torch.no_grad()
    def speech_to_speech(self, wavs, src_langs, tgt_lang, beams=5):
        """Speech -> translated text (route-balanced MBR) -> speech. An empty translation yields 0.1 s of
        silence instead of an exception, so one failed utterance cannot abort a whole evaluation block."""
        texts, _ = self.translate_speech(wavs, src_langs, tgt_lang, "mbr", beams)
        ok = [i for i, t in enumerate(texts) if self.chars.encode(tts_text(t), already_normalized=True)]
        out = [np.zeros(int(0.1 * self.cfg.model.tts_sr), dtype=np.float32) for _ in texts]
        if ok:
            synth, _ = self.synthesize([texts[i] for i in ok], tgt_lang)
            for i, w in zip(ok, synth):
                out[i] = w
        return texts, out


# =============================================================================================
#                              EXTERNAL BASELINES (real models)
# =============================================================================================
class Baselines:
    """Off-the-shelf systems, each loaded once and kept until release()."""

    def __init__(self, cfg: KoraConfig, tok: TextTok, device):
        self.cfg, self.tok, self.device = cfg, tok, device
        self._m: Dict[str, object] = {}
        self._mms_lang = None

    def release(self):
        self._m.clear()
        self._mms_lang = None
        free_memory()

    def _whisper(self):
        if "whisper" not in self._m:
            from transformers import WhisperForConditionalGeneration, WhisperProcessor
            proc = WhisperProcessor.from_pretrained(self.cfg.eval.whisper_model)
            model = _from_pretrained(WhisperForConditionalGeneration, self.cfg.eval.whisper_model,
                                     dtype=torch.float16).to(self.device).eval()
            self._m["whisper"] = (proc, model)
        return self._m["whisper"]

    @torch.no_grad()
    def whisper(self, wavs: List[np.ndarray], lang: str, task: str) -> List[str]:
        proc, model = self._whisper()
        out = []
        for s in range(0, len(wavs), 8):
            feats = proc.feature_extractor(wavs[s:s + 8], sampling_rate=16000, return_tensors="pt").input_features
            ids = model.generate(feats.to(self.device, torch.float16), language=self.cfg.data.whisper_codes[lang],
                                 task=task, max_new_tokens=200)
            out += [t.strip() for t in proc.tokenizer.batch_decode(ids, skip_special_tokens=True)]
        return out

    def _mms(self, lang: str):
        from transformers import Wav2Vec2ForCTC, AutoProcessor
        if "mms_asr" not in self._m:
            proc = AutoProcessor.from_pretrained(self.cfg.eval.mms_asr_model)
            model = _from_pretrained(Wav2Vec2ForCTC, self.cfg.eval.mms_asr_model, dtype=torch.float16).to(self.device).eval()
            self._m["mms_asr"] = (proc, model)
        proc, model = self._m["mms_asr"]
        if self._mms_lang != lang:  # documented MMS adapter switching
            code = self.cfg.data.mms_codes[lang]
            proc.tokenizer.set_target_lang(code)
            model.load_adapter(code)
            self._mms_lang = lang
        return proc, model

    @torch.no_grad()
    def mms_asr(self, wavs: List[np.ndarray], lang: str) -> List[str]:
        proc, model = self._mms(lang)
        out = []
        for w in wavs:
            inp = proc.feature_extractor(w, sampling_rate=16000, return_tensors="pt")
            logits = model(inp["input_values"].to(self.device, torch.float16)).logits
            out.append(proc.tokenizer.decode(logits.argmax(-1)[0].tolist()).strip())
        return out

    @torch.no_grad()
    def nllb(self, texts: List[str], src: str, tgt: str) -> List[str]:
        """Off-the-shelf NLLB-200 (same checkpoint as KORA's text backbone, without adaptation). Inputs are
        built exactly like NLLB's own format ([src_lang] tokens </s>) through KORA's TextTok."""
        if "nllb" not in self._m:
            self._m["nllb"] = _from_pretrained(AutoModelForSeq2SeqLM, self.cfg.model.text_model,
                                               dtype=torch.float16).to(self.device).eval()
        model = self._m["nllb"]
        out = []
        for s in range(0, len(texts), 16):
            ids = _pad_labels([self.tok.src(t, src) for t in texts[s:s + 16]], self.tok.pad_id).to(self.device)
            gen = model.generate(input_ids=ids, attention_mask=(ids != self.tok.pad_id).long(),
                                 forced_bos_token_id=self.tok.lang_ids[tgt], num_beams=self.cfg.eval.beams,
                                 max_new_tokens=200)
            out += [self.tok.decode(g.tolist()) for g in gen]
        return out

    @torch.no_grad()
    def mms_tts(self, texts: List[str], lang: str) -> List[np.ndarray]:
        """MMS-TTS (VITS) waveforms resampled to 24 kHz. Only languages with a released model are allowed."""
        if lang not in self.cfg.eval.mms_tts_langs:
            raise ValueError(f"MMS-TTS has no model for {lang}")
        key = f"mms_tts_{lang}"
        if key not in self._m:
            from transformers import VitsModel
            name = self.cfg.eval.mms_tts_prefix + self.cfg.data.mms_codes[lang]
            self._m[key] = (AutoTokenizer.from_pretrained(name), VitsModel.from_pretrained(name).to(self.device).eval())
        tk, model = self._m[key]
        out = []
        for t in texts:
            inp = tk(t, return_tensors="pt").to(self.device)
            if inp["input_ids"].shape[1] < 2:  # e.g. an empty cascade translation: silence, not an abort
                LOG.warning(f"MMS-TTS ({lang}): no symbols in {t!r}; 0.1 s of silence instead")
                out.append(np.zeros(int(0.1 * 24000), dtype=np.float32))
                continue
            torch.manual_seed(stable_hash(t))
            w = model(**inp).waveform[0].float().cpu().numpy()
            out.append(resample(w, model.config.sampling_rate, 24000))
        return out


class SonarEmbedder:
    """SONAR text encoder (Duquenne et al., 2023; the successor of LASER, 200 NLLB languages incl.
    Lingala) — sentence embeddings by mean pooling, as in the reference usage of the HF port."""

    def __init__(self, cfg: KoraConfig, device):
        from transformers.models.m2m_100.modeling_m2m_100 import M2M100Encoder
        self.device = device
        self.tok = TextTok(cfg.eval.sonar_model, cfg.data.nllb_codes, decoder_start_id=None)
        self.enc = _from_pretrained(M2M100Encoder, cfg.eval.sonar_model, dtype=torch.float16).to(device).eval()

    @torch.no_grad()
    def embed(self, texts: List[str], langs: List[str], bs: int = 64) -> torch.Tensor:
        out = []
        for s in range(0, len(texts), bs):
            ids = _pad_labels([self.tok.src(t, l) for t, l in zip(texts[s:s + bs], langs[s:s + bs])],
                              self.tok.pad_id).to(self.device)
            am = (ids != self.tok.pad_id).long()
            h = self.enc(input_ids=ids, attention_mask=am).last_hidden_state.float()
            m = am.unsqueeze(-1).float()
            out.append(F.normalize((h * m).sum(1) / m.sum(1), dim=-1).cpu())
        return torch.cat(out)


class UTMOS:
    """UTMOS22 strong learner (SpeechMOS) from torch.hub."""

    def __init__(self, cfg: KoraConfig, device):
        self.device = device
        self.pred = torch.hub.load(cfg.eval.utmos_repo, cfg.eval.utmos_model, trust_repo=True).to(device).eval()

    @torch.no_grad()
    def __call__(self, wav: np.ndarray, sr: int) -> float:
        return float(self.pred(torch.from_numpy(wav).float()[None].to(self.device), sr)[0])


# =============================================================================================
#                                         EVALUATOR
# =============================================================================================
def decode_asr_all(D: KoraDecoding, enc, langs: List[str], beams: int, lams: Sequence[float],
                   modes: Sequence[str], n_ctc: int = 5) -> Dict[str, List[str]]:
    """Every ASR decoding mode from ONE speech encoding (dev selection and multi-mode evaluation).
    Keys: 'ctc', 'ctcbeam', 'aed', 'joint@<λ>'."""
    out: Dict[str, List[str]] = {}
    need_nb = any(m in ("ctcbeam", "joint") for m in modes)
    need_aed = any(m in ("aed", "joint") for m in modes)
    if "ctc" in modes:
        out["ctc"] = D.ctc_greedy(enc)
    logps = D.ctc_logps(enc) if need_nb else None
    ctc_nb = D.ctc_nbest(logps, max(D.cfg.pl.ctc_beam, n_ctc), n_ctc) if need_nb else None
    if "ctcbeam" in modes:
        out["ctcbeam"] = [nb[0][0] for nb in ctc_nb]
    if need_aed:
        mem, mm, _, _ = D.memory(enc, langs, "greedy")
        aed_nb = D.nbest(mem, mm, langs, beams, beams)
        if "aed" in modes:
            out["aed"] = [normalize_text(a[0]) for a in aed_nb]
    if "joint" in modes:
        res = {lam: [] for lam in lams}
        for i in range(len(langs)):
            cands = [c for c in dict.fromkeys([t for t, _ in ctc_nb[i]] + [normalize_text(a) for a in aed_nb[i]]) if c]
            if not cands:
                for lam in lams:
                    res[lam].append("")
                continue
            cs = D.ctc_scores(logps[i], cands)
            aes = D.aed_scores(mem[i:i + 1], mm[i:i + 1], cands, langs[i])
            for lam in lams:
                sc = [lam * c + (1 - lam) * a if np.isfinite(c) else -np.inf for c, a in zip(cs, aes)]
                k = int(np.argmax(sc)) if np.isfinite(max(sc)) else int(np.argmax(aes))
                res[lam].append(cands[k])
        for lam in lams:
            out[f"joint@{lam}"] = res[lam]
    return out


class Evaluator:
    """Full evaluation suite for the article. Every block is cached in results/all_results.json and the
    time budget is checked before each block, so an interrupted evaluation resumes where it stopped."""

    def __init__(self, cfg: KoraConfig, trainer: Trainer, device, aux_device):
        self.cfg, self.tr, self.device, self.aux = cfg, trainer, torch.device(device), torch.device(aux_device)
        self.model, self.tok, self.chars, self.data = trainer.model, trainer.tok, trainer.chars, trainer.data
        self.vocoder = Vocoder(cfg.model.vocoder_model, self.aux)
        self.dec = trainer.dec
        self.inf = KoraInferencer(cfg, self.model, self.dec, device, self.vocoder)
        self.base = Baselines(cfg, self.tok, self.aux)
        self.P = cfg.paths
        self.rp = os.path.join(self.P.results_dir, "all_results.json")
        self.R = load_json(self.rp, {})
        self.ec = cfg.eval
        self.langs = cfg.data.african_langs
        self.check = trainer.check_time
        self._sonar: Optional[SonarEmbedder] = None
        self._utmos: Optional[UTMOS] = None
        self._build_sets()
        if self.has("decoding"):
            self.inf.asr_mode = self.R["decoding"]["asr_mode"]
            self.inf.joint_lambda = self.R["decoding"]["joint_lambda"]

    # ------------------------------------------------------------------ bookkeeping ---------
    def save(self):
        save_json(self.rp, self.R)

    def has(self, *keys):
        d = self.R
        for k in keys:
            if not isinstance(d, dict) or k not in d:
                return False
            d = d[k]
        return True

    def put(self, value, *keys):
        d = self.R
        for k in keys[:-1]:
            d = d.setdefault(k, {})
        d[keys[-1]] = value
        self.save()

    def save_preds(self, name: str, rows: List[dict]):
        write_jsonl(os.path.join(self.P.pred_dir, f"{name}.jsonl"), rows)

    def load_preds(self, name: str) -> List[dict]:
        return read_jsonl(os.path.join(self.P.pred_dir, f"{name}.jsonl"))

    def _cap(self, E, n=None):
        n = n or self.ec.max_eval_utts
        E = sorted(E, key=lambda e: e["uid"])
        if not n or len(E) <= n:
            return E
        return [E[i] for i in np.linspace(0, len(E) - 1, n).astype(int)]

    def _build_sets(self):
        d = self.data
        par = d["parallel"]
        fl = lambda m: dict(m, en=par[m["sid"]].get("en"))
        self.fleurs_test = {l: self._cap([fl(m) for m in d["fleurs"] if m["lang"] == l and m["split"] == "test"])
                            for l in self.langs}
        self.fleurs_dev = {l: self._cap([fl(m) for m in d["fleurs"] if m["lang"] == l and m["split"] == "dev"],
                                        self.ec.dev_select_utts // 2) for l in self.langs}
        self.bible_test = {l: self._cap([m for m in d["bible"] if m["lang"] == l and m["split"] == "target_test"])
                           for l in self.langs}
        self.bible_dev = {l: self._cap([m for m in d["bible"] if m["lang"] == l and m["split"] == "target_dev"],
                                       self.ec.dev_select_utts // 2) for l in self.langs}
        yf = lambda y: dict(uid=y["uid"], audio=y["audio"], dur=y["dur"], lang="yo", text=y["yo"], yo=y["yo"],
                            en=y["en"], vis_uid=y["uid"], domain="yfacc")
        self.yfacc_test = self._cap([yf(y) for y in d["yfacc"] if y["split"] == "test"])
        test_sids = sorted({m["sid"] for m in d["fleurs"] if m["split"] == "test"})
        self.text_test = [dict(sid=s, **par[s]) for s in test_sids]
        cap2 = 2 * (self.ec.max_eval_utts or 0) or None
        self.mmt_sets = {"test": (self._cap([dict(h, vis_uid=h["uid"]) for h in d["havg"] if h["split"] == "test"], cap2), "ha"),
                         "challenge": (self._cap([dict(h, vis_uid=h["uid"]) for h in d["havg"] if h["split"] == "challenge"], cap2), "ha")}
        if self.yfacc_test:
            self.mmt_sets["yfacc"] = (self.yfacc_test, "yo")
        self.spoken_sets = {s: self._cap([h for h in d.get("spoken", []) if h["split"] == s]) for s in ["test", "challenge"]}
        for name, sets in [("FLEURS test", self.fleurs_test), ("BibleTTS test", self.bible_test),
                           ("BibleTTS dev", self.bible_dev)]:
            empty = [k for k, v in sets.items() if not v]
            if empty:
                raise RuntimeError(f"{name}: empty evaluation set(s) {empty}")

    def _asr_sets(self) -> Dict[str, Dict[str, List[dict]]]:
        s = {"fleurs": self.fleurs_test, "bible": self.bible_test}
        if self.yfacc_test:
            s["yfacc"] = {"yo": self.yfacc_test}
        return s

    def _st_sets_en(self) -> Dict[str, Dict[str, List[dict]]]:
        """Speech -> English test sets: FLEURS, BibleTTS (World English Bible refs), YFACC."""
        s = {"fleurs": {l: [e for e in E if e.get("en")] for l, E in self.fleurs_test.items()},
             "bible": {l: [e for e in E if e.get("en")] for l, E in self.bible_test.items()}}
        if self.yfacc_test:
            s["yfacc"] = {"yo": self.yfacc_test}
        return {k: {l: E for l, E in v.items() if E} for k, v in s.items()}

    @staticmethod
    def _wavs(E, sr=16000):
        return [load_audio(e["audio"], sr) for e in E]

    @staticmethod
    def _batched(items, fn, bs=8):
        out = []
        for s in range(0, len(items), bs):
            out += fn(items[s:s + bs])
        return out

    # ------------------------------------------------------------------ metric blocks -------
    def asr_metrics(self, refs, hyps):
        e, n = error_stats(refs, hyps, "word")
        lo, hi = error_rate_bootstrap(e, n, self.ec.n_bootstrap)
        return dict(WER=100 * e.sum() / n.sum(), WER_CI=[lo, hi], CER=cer(refs, hyps),
                    CER_nospace=cer(refs, hyps, nospace=True), WER_notone=wer(refs, hyps, True),
                    CER_notone=cer(refs, hyps, True), WER_ortho=wer(refs, hyps, strip_ortho=True),
                    distinct=distinct_ratio(hyps), n=len(refs))

    def mt_metrics(self, refs, hyps):
        lo, hi = bootstrap_ci(bleu, refs, hyps, max(100, self.ec.n_bootstrap // 5))
        return dict(BLEU=bleu(refs, hyps), BLEU_CI=[lo, hi], chrF2pp=chrf(refs, hyps),
                    SSI=source_sensitivity(refs, hyps), distinct=distinct_ratio(hyps), n=len(refs))

    # ------------------------------------------------------------------ decoding selection --
    def select_decoding(self):
        """ASR decoding mode and joint λ chosen on FLEURS-dev + BibleTTS-dev (never on test)."""
        if self.has("decoding"):
            self.inf.asr_mode = self.R["decoding"]["asr_mode"]
            self.inf.joint_lambda = self.R["decoding"]["joint_lambda"]
            return
        self.check()
        lams = list(self.ec.joint_lambdas)
        modes = ["ctc", "ctcbeam", "aed", "joint"]
        errs = defaultdict(lambda: [0.0, 0.0])
        for sets in (self.fleurs_dev, self.bible_dev):
            for lang, E in sets.items():
                for s in range(0, len(E), 8):
                    ch = E[s:s + 8]
                    out = decode_asr_all(self.dec, self.dec.encode(self._wavs(ch)), [lang] * len(ch), self.ec.beams,
                                         lams, modes)
                    refs = [e["text"] for e in ch]
                    for k, hyps in out.items():
                        e_, n_ = error_stats(refs, hyps)
                        errs[k][0] += float(e_.sum())
                        errs[k][1] += float(n_.sum())
        dev_wer = {k: 100 * e / max(1.0, n) for k, (e, n) in errs.items()}
        best = min(dev_wer, key=dev_wer.get)
        mode = best.split("@")[0]
        # λ of the joint mode is tuned on dev even when another mode wins: the KORA-joint rows use it too
        lam = float(min((k for k in dev_wer if k.startswith("joint@")), key=dev_wer.get).split("@")[1])
        self.inf.asr_mode, self.inf.joint_lambda = mode, lam
        self.put(dict(asr_mode=mode, joint_lambda=lam, dev_wer=dev_wer), "decoding")
        LOG.info(f"dev-selected ASR decoding: {mode} (λ={lam}) | dev WER {json.dumps({k: round(v, 2) for k, v in dev_wer.items()})}")

    # ------------------------------------------------------------------ speech (any system) -
    def eval_asr_system(self, system: str, fn, bs: int = 8):
        """fn(wavs, lang) -> hypotheses; on FLEURS test, the held-out BibleTTS test and YFACC test."""
        for sname, per_lang in self._asr_sets().items():
            for lang, E in per_lang.items():
                if self.has("asr", system, f"{sname}/{lang}"):
                    continue
                self.check()
                hyps = self._batched(E, lambda ch: fn(self._wavs(ch), lang), bs)
                self._put_asr(system, sname, lang, E, hyps)

    def _put_asr(self, system, sname, lang, E, hyps):
        refs = [e["text"] for e in E]
        self.save_preds(f"asr__{system}__{sname}__{lang}",
                        [dict(uid=e["uid"], dur=e["dur"], ref=r, hyp=h) for e, r, h in zip(E, refs, hyps)])
        self.put(self.asr_metrics(refs, hyps), "asr", system, f"{sname}/{lang}")
        LOG.info(f"ASR {system} {sname}/{lang}: WER {self.R['asr'][system][f'{sname}/{lang}']['WER']:.2f}")

    def eval_kora_asr(self, tag: str, modes: List[str]):
        """Several KORA decoding modes from one encoding per batch."""
        lam = self.inf.joint_lambda
        for sname, per_lang in self._asr_sets().items():
            for lang, E in per_lang.items():
                todo = [m for m in modes if not self.has("asr", f"{tag}-{m}", f"{sname}/{lang}")]
                if not todo:
                    continue
                self.check()
                hyps = {m: [] for m in todo}
                for s in range(0, len(E), 8):
                    ch = E[s:s + 8]
                    out = decode_asr_all(self.dec, self.dec.encode(self._wavs(ch)), [lang] * len(ch), self.ec.beams,
                                         [lam], todo)
                    for m in todo:
                        hyps[m] += out[f"joint@{lam}" if m == "joint" else m]
                for m in todo:
                    self._put_asr(f"{tag}-{m}", sname, lang, E, hyps[m])

    def _alias_selected(self, tag: str):
        """'<tag>-sel' = the dev-selected decoding mode (used for significance and the headline tables)."""
        src = f"{tag}-{self.inf.asr_mode}"
        if not self.has("asr", src):
            return
        self.put(copy.deepcopy(self.R["asr"][src]), "asr", f"{tag}-sel")
        for sname, per_lang in self._asr_sets().items():
            for lang in per_lang:
                p = os.path.join(self.P.pred_dir, f"asr__{src}__{sname}__{lang}.jsonl")
                if os.path.exists(p):
                    shutil.copy2(p, os.path.join(self.P.pred_dir, f"asr__{tag}-sel__{sname}__{lang}.jsonl"))

    def eval_st(self, system: str, fn, set_name: str, per_lang: Dict[str, List[dict]], tgt: str, ref_fn,
                bs: int = 8, limit: Optional[int] = None):
        """fn(wavs, src_lang, tgt_lang) -> translations."""
        for src, E in per_lang.items():
            key = f"{set_name}/{src}-{tgt}"
            if self.has("st", system, key):
                continue
            E = [e for e in E if ref_fn(e)]
            if limit:
                E = E[:limit]
            if not E:
                continue
            self.check()
            hyps = self._batched(E, lambda ch: fn(self._wavs(ch), src, tgt), bs)
            refs = [ref_fn(e) for e in E]
            self.save_preds(f"st__{system}__{set_name}__{src}-{tgt}",
                            [dict(uid=e["uid"], ref=r, hyp=h) for e, r, h in zip(E, refs, hyps)])
            self.put(self.mt_metrics(refs, hyps), "st", system, key)

    def eval_kora_speech(self, tag: str, full: bool):
        inf, b = self.inf, self.ec.beams
        modes = ["ctc", "ctcbeam", "aed", "joint"] if full else list(dict.fromkeys(["ctc", inf.asr_mode]))
        self.eval_kora_asr(tag, modes)
        self._alias_selected(tag)
        for route in (["direct", "cascade", "mbr"] if full else ["direct"]):
            fn = lambda w, s, t, route=route: inf.translate_speech(w, [s] * len(w), t, route, b)[0]
            for set_name, per_lang in self._st_sets_en().items():
                self.eval_st(f"{tag}-{route}", fn, set_name, per_lang, "en", lambda e: e.get("en"))
        if full:
            par = self.data["parallel"]
            n = max(50, (self.ec.max_eval_utts or 400) // 2)
            for route in ["direct", "cascade"]:
                fn = lambda w, s, t, route=route: inf.translate_speech(w, [s] * len(w), t, route, b)[0]
                for tgt in self.langs:
                    per = {src: [e for e in self.fleurs_test[src] if tgt in par[e["sid"]]] for src in self.langs if src != tgt}
                    self.eval_st(f"{tag}-{route}", fn, "fleurs", per, tgt, lambda e, tgt=tgt: par[e["sid"]].get(tgt),
                                 limit=n)

    # ------------------------------------------------------------------ baselines -----------
    def eval_baselines(self):
        big = 10 ** 9  # baselines receive a whole evaluation set at once (they batch internally)
        self.eval_asr_system("Whisper-medium", lambda w, lang: self.base.whisper(w, lang, "transcribe"), big)
        for set_name, per_lang in self._st_sets_en().items():
            self.eval_st("Whisper-medium", lambda w, s, t: self.base.whisper(w, s, "translate"), set_name, per_lang,
                         "en", lambda e: e.get("en"), big)
        self.eval_asr_system("MMS-1B-all", lambda w, lang: self.base.mms_asr(w, lang), big)
        for set_name, per_lang in self._st_sets_en().items():  # cascade MMS-ASR -> NLLB-200 on the saved transcripts
            for src, E in per_lang.items():
                key = f"{set_name}/{src}-en"
                if self.has("st", "MMS→NLLB", key):
                    continue
                self.check()
                by = {e["uid"]: e for e in E}
                rows = [p for p in self.load_preds(f"asr__MMS-1B-all__{set_name}__{src}") if p["uid"] in by]
                hyps = self.base.nllb([p["hyp"] for p in rows], src, "en")
                refs = [by[p["uid"]]["en"] for p in rows]
                self.save_preds(f"st__MMS→NLLB__{set_name}__{src}-en",
                                [dict(uid=p["uid"], ref=r, hyp=h) for p, r, h in zip(rows, refs, hyps)])
                self.put(self.mt_metrics(refs, hyps), "st", "MMS→NLLB", key)

    # ------------------------------------------------------------------ text MT / MMT -------
    def eval_text_mt(self):
        T = self.text_test[: (self.ec.max_eval_utts or len(self.text_test))]
        jobs = []
        for src in self.langs:
            for a, b in [(src, "en"), ("en", src)]:
                rows = [r for r in T if a in r and b in r]
                jobs.append((f"flores/{a}-{b}", a, b, [r[a] for r in rows], [r[b] for r in rows]))
            E = [e for e in self.bible_test[src] if e.get("en")]
            jobs.append((f"bible/{src}-en", src, "en", [e["text"] for e in E], [e["en"] for e in E]))
        for key, a, b, srcs, refs in jobs:
            if not srcs:
                continue
            for system in ["KORA", "NLLB-600M"]:
                if self.has("mt", system, key):
                    continue
                self.check()
                if system == "KORA":
                    hyps = self._batched(srcs, lambda ch: self.inf.translate_text(ch, a, b, self.ec.beams)[0], 16)
                else:
                    hyps = self.base.nllb(srcs, a, b)
                self.save_preds(f"mt__{system}__{key.replace('/', '__')}",
                                [dict(src=s, ref=r, hyp=h) for s, r, h in zip(srcs, refs, hyps)])
                self.put(self.mt_metrics(refs, hyps), "mt", system, key)

    def eval_mmt(self):
        vi = self.data["vis_index"]
        for sname, (E, L2) in self.mmt_sets.items():
            rows = [vi[e["vis_uid"]] for e in E]
            shuffled = rows[1:] + rows[:1]  # incongruent images (Elliott 2018-style adversarial test)
            for a, b in [("en", L2), (L2, "en")]:
                srcs, refs = [e[a] for e in E], [e[b] for e in E]
                confs = {"KORA (image, learned gate)": (rows, "learned"), "KORA (text only)": (None, "off"),
                         "KORA (image, gate forced open)": (rows, "open"),
                         "KORA (incongruent image)": (shuffled, "learned"),
                         "KORA (incongruent, gate open)": (shuffled, "open")}
                key = f"{sname}/{a}-{b}"
                for system, (vr, gm) in confs.items():
                    if self.has("mmt", system, key):
                        continue
                    self.check()
                    hyps, gates = [], []
                    for s in range(0, len(srcs), 16):
                        h, g = self.inf.translate_text(srcs[s:s + 16], a, b, self.ec.beams,
                                                       vr[s:s + 16] if vr is not None else None, gm)
                        hyps += h
                        gates += g
                    self.save_preds(f"mmt__{system}__{sname}__{a}-{b}",
                                    [dict(uid=e["uid"], src=s, ref=r, hyp=h, gate=g)
                                     for e, s, r, h, g in zip(E, srcs, refs, hyps, gates)])
                    res = self.mt_metrics(refs, hyps)
                    res["gate_mean"] = float(np.mean([g for g in gates if g is not None])) if vr is not None else None
                    self.put(res, "mmt", system, key)
                if not self.has("mmt", "NLLB-600M (text)", key):
                    self.check()
                    hyps = self.base.nllb(srcs, a, b)
                    self.save_preds(f"mmt__NLLB-600M (text)__{sname}__{a}-{b}",
                                    [dict(uid=e["uid"], src=s, ref=r, hyp=h) for e, s, r, h in zip(E, srcs, refs, hyps)])
                    self.put(self.mt_metrics(refs, hyps), "mmt", "NLLB-600M (text)", key)
            # gate vs counterfactual utility (does the gate predict real visual utility?)
            if not self.has("gate_analysis", sname):
                self.check()
                from scipy.stats import spearmanr
                deltas, gates = [], []
                for s in range(0, len(E), 16):
                    ch = E[s:s + 16]
                    if len(ch) < 2:
                        continue
                    d_, g_ = self.inf.counterfactual_utility([e["en"] for e in ch], "en", [e[L2] for e in ch], L2,
                                                             [vi[e["vis_uid"]] for e in ch])
                    deltas += d_
                    gates += g_
                self.put(dict(delta=deltas, gate=gates, spearman=float(spearmanr(gates, deltas).correlation),
                              frac_helpful=float(np.mean(np.array(deltas) > 0))), "gate_analysis", sname)

    def eval_spoken_mmt(self):
        """Speech + image -> English on YFACC test (REAL Yorùbá speech, REAL Flickr8k images)."""
        vi = self.data["vis_index"]
        sets = {}
        if self.yfacc_test:
            sets["yfacc"] = (self.yfacc_test, "yo", [vi[e["vis_uid"]] for e in self.yfacc_test])
        for s, E in self.spoken_sets.items():
            if E:
                sets[f"synthetic_havg_{s}"] = (E, "ha", [vi[e["havg_uid"]] for e in E])
        for sname, (E, L, rows) in sets.items():
            shuffled = rows[1:] + rows[:1]
            refs = [e["en"] for e in E]
            confs = {"KORA (speech+image)": (rows, "learned"), "KORA (speech only)": (None, "off"),
                     "KORA (speech+incongruent image)": (shuffled, "learned")}
            for system, (vr, gm) in confs.items():
                if self.has("smmt", system, sname):
                    continue
                self.check()
                hyps, gates = [], []
                for s in range(0, len(E), 8):
                    ch = E[s:s + 8]
                    h, g = self.inf.translate_speech(self._wavs(ch), [L] * len(ch), "en", "direct", self.ec.beams,
                                                     vr[s:s + 8] if vr is not None else None, gm)
                    hyps += h
                    gates += g
                self.save_preds(f"smmt__{system}__{sname}", [dict(uid=e["uid"], ref=r, hyp=h, gate=g)
                                                              for e, r, h, g in zip(E, refs, hyps, gates)])
                self.put(self.mt_metrics(refs, hyps), "smmt", system, sname)
            if not self.has("smmt", "MMS→NLLB", sname):
                self.check()
                hyps = self.base.nllb(self.base.mms_asr(self._wavs(E), L), L, "en")
                self.save_preds(f"smmt__MMS→NLLB__{sname}", [dict(uid=e["uid"], ref=r, hyp=h)
                                                             for e, r, h in zip(E, refs, hyps)])
                self.put(self.mt_metrics(refs, hyps), "smmt", "MMS→NLLB", sname)

    # ------------------------------------------------------------------ TTS / S2ST ----------
    def utmos(self) -> UTMOS:
        if self._utmos is None:
            self._utmos = UTMOS(self.cfg, self.aux)
        return self._utmos

    def eval_tts(self):
        n = self.ec.tts_eval_utts
        for sname, per_lang in [("bible", self.bible_test), ("fleurs", self.fleurs_test)]:
            for lang, E in per_lang.items():
                E = [e for e in E if tts_text(e["text"])][:n]
                texts = [e["text"] for e in E]
                systems = ["KORA-TTS"] + (["MMS-TTS (VITS)"] if lang in self.ec.mms_tts_langs else []) + \
                          (["Ground truth (BibleTTS)"] if sname == "bible" else [])
                for system in systems:
                    key = f"{sname}/{lang}"
                    if self.has("tts", system, key):
                        continue
                    self.check()
                    if system == "KORA-TTS":
                        wavs = self.inf.synthesize(texts, lang)[0]
                    elif system.startswith("MMS-TTS"):
                        wavs = self.base.mms_tts(texts, lang)
                    else:
                        wavs = [load_audio(e["audio24"], 24000) for e in E]
                    adir = os.path.join(self.P.audio_dir, "tts", system.split()[0], sname, lang)
                    for e, w in list(zip(E, wavs))[: self.ec.n_audio_samples]:
                        save_wav(os.path.join(adir, f"{e['uid']}.wav"), w, 24000)
                    w16 = [resample(w, 24000, 16000) for w in wavs]
                    judge_kora = self._batched(w16, lambda ch: self.inf.transcribe(ch, [lang] * len(ch)))
                    judge_mms = self.base.mms_asr(w16, lang)
                    res = dict(CER_judge_MMS=cer(texts, judge_mms), WER_judge_MMS=wer(texts, judge_mms),
                               CER_judge_KORA=cer(texts, judge_kora), n=len(texts),
                               dur_ratio=float(np.mean([len(a) / 16000 / e["dur"] for a, e in zip(w16, E)])),
                               UTMOS=float(np.mean([self.utmos()(w, 16000) for w in w16[:50]])))
                    if sname == "bible" and not system.startswith("Ground"):
                        res["MCD_dB"] = float(np.mean([mcd_dtw(load_audio(e["audio"]), w) for e, w in zip(E[:50], w16[:50])]))
                    self.put(res, "tts", system, key)

    def eval_s2st(self):
        par = self.data["parallel"]
        n = self.ec.s2st_eval_utts
        for src in self.langs:
            for tgt in self.langs:
                if src == tgt:
                    continue
                E = [e for e in self.fleurs_test[src] if tgt in par[e["sid"]]][:n]
                if not E:
                    raise RuntimeError(f"S2ST {src}->{tgt}: no parallel test utterance")
                refs = [par[e["sid"]][tgt] for e in E]
                key = f"{src}-{tgt}"
                if not self.has("s2st", "KORA (ST→TTS, shared model)", key):
                    self.check()
                    texts, wavs = [], []
                    for s in range(0, len(E), 8):
                        t, w = self.inf.speech_to_speech(self._wavs(E[s:s + 8]), [src] * len(E[s:s + 8]), tgt, self.ec.beams)
                        texts += t
                        wavs += w
                    for e, w in list(zip(E, wavs))[: self.ec.n_audio_samples]:
                        save_wav(os.path.join(self.P.audio_dir, "s2st", key, f"{e['uid']}.wav"), w, 24000)
                    asr = self.base.mms_asr([resample(w, 24000, 16000) for w in wavs], tgt)
                    self.put(dict(text_BLEU=bleu(refs, texts), text_chrF=chrf(refs, texts),
                                  **self._asr_scores(refs, asr), n=len(E)), "s2st", "KORA (ST→TTS, shared model)", key)
                # the cascade baseline needs an MMS-TTS voice in the target language (none for Lingala)
                if tgt in self.ec.mms_tts_langs and not self.has("s2st", "MMS-ASR→NLLB→MMS-TTS", key):
                    self.check()
                    t = self.base.nllb(self.base.mms_asr(self._wavs(E), src), src, tgt)
                    back = self.base.mms_asr([resample(x, 24000, 16000) for x in self.base.mms_tts(t, tgt)], tgt)
                    self.put(dict(text_BLEU=bleu(refs, t), text_chrF=chrf(refs, t), **self._asr_scores(refs, back),
                                  n=len(E)), "s2st", "MMS-ASR→NLLB→MMS-TTS", key)

    @staticmethod
    def _asr_scores(refs, asr) -> dict:
        """ASR-BLEU / ASR-chrF: the ASR judge emits lowercase text without punctuation, so references and
        transcripts are both normalised (the usual ASR-BLEU protocol); text_* scores stay on raw text."""
        r, h = [normalize_text(x) for x in refs], [normalize_text(x) for x in asr]
        return dict(ASR_BLEU=bleu(r, h), ASR_chrF=chrf(r, h))

    # ------------------------------------------------------------------ PL analysis ---------
    def sonar(self) -> SonarEmbedder:
        if self._sonar is None:
            self._sonar = SonarEmbedder(self.cfg, self.aux)
        return self._sonar

    def xsim_scores(self, recs: List[dict], r: int) -> Dict[str, float]:
        """SONAR cosine between the transcript (source language) and the translation (English) of every
        pseudo-label — the LASER-style filter of Gheini et al. (2023) with LASER's successor."""
        path = os.path.join(self.P.pl_dir, f"xsim_round{r}.json")
        xs = load_json(path, {})
        todo = [x for x in recs if x["uid"] not in xs]
        if todo:
            son = self.sonar()
            zs = son.embed([x["t_aed"] for x in todo], [x["lang"] for x in todo])
            zt = son.embed([x["y_direct"] for x in todo], ["en"] * len(todo))
            xs.update({x["uid"]: float(c) for x, c in zip(todo, (zs * zt).sum(-1).tolist())})
            save_json(path, xs)
        return xs

    def eval_pseudo_labels(self):
        from sklearn.metrics import roc_auc_score
        from scipy.stats import spearmanr
        gold = {b["uid"]: b["text"] for b in self.data["bible"] if b["split"] == "target_adapt" and b["text"]}
        for r in range(1, self.cfg.pl.rounds + 1):
            key = f"round{r}"
            if self.has("pl_analysis", key):
                continue
            self.check()
            recs = [x for x in read_jsonl(os.path.join(self.P.pl_dir, f"pl_round{r}.jsonl")) if x["uid"] in gold]
            if not recs:
                raise RuntimeError(f"no gold transcript for any round-{r} pseudo-label")
            xs = self.xsim_scores(recs, r)
            for x in recs:
                x["s_xsim"] = xs[x["uid"]]
            q = self.cfg.pl.retention_schedule[r - 1]
            strat = {}
            for name, st in [("Vanilla PL (all)", "vanilla"), ("Confidence top-q", "confidence"),
                             ("Ratio-KDE (Gheini'23)", "kde"), ("SONAR xsim, LASER-style (Gheini'23)", "xsim"),
                             ("Multi-filter (Mohammadamini'25)", "kurdish"), ("RAPL (ours)", "rapl")]:
                sel = self.tr.pl.select(recs, st, q)
                if not sel:
                    strat[name] = dict(retention=0.0, hours=0.0, WER=None, CER=None, per_lang={})
                    continue
                lab = self.tr.pl.label_fields(st)[0]
                refs, hyps = [gold[s["uid"]] for s in sel], [s[lab] for s in sel]
                strat[name] = dict(retention=100 * len(sel) / len(recs), hours=sum(s["dur"] for s in sel) / 3600,
                                   WER=wer(refs, hyps), CER=cer(refs, hyps),
                                   per_lang={l: wer([gold[s["uid"]] for s in sel if s["lang"] == l],
                                                    [s[lab] for s in sel if s["lang"] == l])
                                             for l in self.langs if any(s["lang"] == l for s in sel)})
            # quality-retention curves for single-view scores vs RAPL
            curves = {}
            keys = {"RAPL S (ours)": "S", "AED confidence": "s_conf", "Ratio-KDE": "s_len", "SONAR xsim": "s_xsim",
                    "CTC↔AED agreement": "s_ctc_aed", "direct↔cascade agreement": "s_route"}
            rand = np.random.default_rng(0).random(len(recs))
            for q_ in np.linspace(0.1, 1.0, 10):
                k_n = max(1, int(round(q_ * len(recs))))
                for name, k in list(keys.items()) + [("random", None)]:
                    order = np.argsort(-rand) if k is None else np.argsort([-x[k] for x in recs], kind="stable")
                    sel = [recs[i] for i in order[:k_n]]
                    curves.setdefault(name, []).append([float(q_), cer([gold[s["uid"]] for s in sel], [s["t_aed"] for s in sel])])
                order = np.argsort([-x["S"] for x in recs], kind="stable")
                sel = [recs[i] for i in order[:k_n]]
                curves.setdefault("RAPL S + route-balanced label (ours)", []).append(
                    [float(q_), cer([gold[s["uid"]] for s in sel], [s["t_star"] for s in sel])])
            # AMT-PL: does word-level route disagreement detect real errors?
            y_err, y_dis = [], []
            for s in recs:
                alt = s["t_aed"] if s.get("t_route") == "ctc" else s["t_ctc"]
                agree = word_agreement(s["t_star"], alt)
                correct = word_agreement(s["t_star"], normalize_text(gold[s["uid"]]))
                y_err += [int(not c) for c in correct]
                y_dis += [int(not a) for a in agree]
            auroc = float(roc_auc_score(y_err, y_dis)) if len(set(y_err)) > 1 and len(set(y_dis)) > 1 else float("nan")
            tp = sum(1 for e, d in zip(y_err, y_dis) if e and d)
            utt_cer = [cer([gold[s["uid"]]], [s["t_star"]]) for s in recs]
            per_lang_rho = {}
            for l in self.langs:
                idx = [i for i, s in enumerate(recs) if s["lang"] == l]
                if len(idx) > 10:
                    per_lang_rho[l] = float(spearmanr([recs[i]["S"] for i in idx], [utt_cer[i] for i in idx]).correlation)
            nonempty = [i for i, s in enumerate(recs) if s["t_star"].strip()]
            self.put(dict(strategies=strat, curves=curves, word_error_detection=dict(
                AUROC=auroc, precision=tp / max(1, sum(y_dis)), recall=tp / max(1, sum(y_err)),
                word_error_rate=float(np.mean(y_err)) if y_err else float("nan")),
                spearman_S_vs_CER=float(spearmanr([s["S"] for s in recs], utt_cer).correlation),
                spearman_S_vs_CER_nonempty=float(spearmanr([recs[i]["S"] for i in nonempty],
                                                           [utt_cer[i] for i in nonempty]).correlation)
                if len(nonempty) > 10 else float("nan"),
                spearman_per_lang=per_lang_rho, n=len(recs),
                scores=[dict(S=s["S"], cer=c, lang=s["lang"]) for s, c in zip(recs, utt_cer)]),
                "pl_analysis", key)

    # ------------------------------------------------------------------ domain analysis -----
    @torch.no_grad()
    def embed_domains(self, tag: str):
        if self.has("domain", tag):
            return
        self.check()
        n = self.ec.n_tsne_points // 2
        pts = []
        for dom, sets in [("fleurs", self.fleurs_test), ("bible", self.bible_test)]:
            E = [e for l in self.langs for e in sets[l][: max(1, n // len(self.langs))]]
            for s in range(0, len(E), 8):
                ch = E[s:s + 8]
                enc = self.dec.encode(self._wavs(ch))
                h = enc["h"].float()
                fm = enc["fmask"].unsqueeze(-1).float()
                z = ((h * fm).sum(1) / fm.sum(1)).cpu().numpy()
                pts += [dict(z=z[i].tolist(), domain=dom, lang=ch[i]["lang"]) for i in range(len(ch))]
        from sklearn.linear_model import LogisticRegression
        from sklearn.model_selection import cross_val_score
        from sklearn.manifold import TSNE
        Z = np.asarray([p["z"] for p in pts])
        y = np.asarray([p["domain"] == "bible" for p in pts]).astype(int)
        Zs = (Z - Z.mean(0)) / (Z.std(0) + 1e-6)
        acc = float(cross_val_score(LogisticRegression(max_iter=2000, C=0.1), Zs, y, cv=5).mean())
        A, B = Zs[y == 0], Zs[y == 1]

        def rbf(X, Y, g):
            return np.exp(-g * ((X[:, None] - Y[None]) ** 2).sum(-1))

        g = 1.0 / max(np.median(((Zs[:, None] - Zs[None]) ** 2).sum(-1)), 1e-6)
        mmd = float(rbf(A, A, g).mean() + rbf(B, B, g).mean() - 2 * rbf(A, B, g).mean())
        xy = TSNE(n_components=2, perplexity=max(2, min(30, len(Zs) // 4)), random_state=0, init="pca").fit_transform(Zs)
        self.put(dict(domain_clf_acc=acc, proxy_A_distance=2 * (1 - 2 * (1 - acc)), mmd2=mmd,
                      tsne=[dict(x=float(a), y=float(b), domain=p["domain"], lang=p["lang"]) for (a, b), p in zip(xy, pts)]),
                 "domain", tag)

    # ------------------------------------------------------------------ efficiency ----------
    def eval_params(self):
        if self.has("efficiency", "params"):
            return
        m = self.model
        shared = m.nllb.model.shared

        def part(mod, skip_emb=True, trainable=False):
            return sum(p.numel() for n, p in mod.named_parameters()
                       if (not skip_emb or not n.startswith("embed_tokens")) and (p.requires_grad or not trainable))

        rows = [dict(module=f"speech encoder ({self.cfg.model.speech_model.split('/')[-1]})",
                     params_M=count_params(m.speech.w2v) / 1e6, trainable_M=count_params(m.speech.w2v, True) / 1e6),
                dict(module="CTC + latent heads", params_M=(count_params(m.speech.ctc_head) + count_params(m.speech.latent_head)) / 1e6,
                     trainable_M=(count_params(m.speech.ctc_head, True) + count_params(m.speech.latent_head, True)) / 1e6),
                dict(module="Subword-Anchored Bridge (SAB)", params_M=count_params(m.sab) / 1e6,
                     trainable_M=count_params(m.sab, True) / 1e6),
                dict(module="NLLB-200 shared embedding / LM head", params_M=count_params(shared) / 1e6,
                     trainable_M=count_params(shared, True) / 1e6),
                dict(module="NLLB-200 encoder (+LoRA)", params_M=part(m.nllb.model.encoder) / 1e6,
                     trainable_M=part(m.nllb.model.encoder, trainable=True) / 1e6),
                dict(module="NLLB-200 decoder (+LoRA)", params_M=part(m.nllb.model.decoder) / 1e6,
                     trainable_M=part(m.nllb.model.decoder, trainable=True) / 1e6),
                dict(module="CS-VUG gate", params_M=count_params(m.vgate) / 1e6, trainable_M=count_params(m.vgate, True) / 1e6),
                dict(module="Flow-matching TTS", params_M=count_params(m.tts) / 1e6, trainable_M=count_params(m.tts, True) / 1e6),
                dict(module="TOTAL", params_M=count_params(m) / 1e6, trainable_M=count_params(m, True) / 1e6)]
        self.put(rows, "efficiency", "params")

    def eval_rtf(self):
        """Dedicated real-time-factor benchmark (v1 accumulated timings as a side-effect of blocks that are
        skipped on resume, hence an empty table). Warm-up, CUDA-synchronised, cached once measured."""
        if self.has("efficiency", "rtf"):
            return
        self.check()
        k = max(2, self.ec.rtf_utts // len(self.langs))
        inf, b = self.inf, self.ec.beams
        jobs = {"ASR ctc": lambda w, l: inf.transcribe(w, [l] * len(w), "ctc", b),
                f"ASR {inf.asr_mode} (dev-selected)": lambda w, l: inf.transcribe(w, [l] * len(w), None, b),
                "ST direct": lambda w, l: inf.translate_speech(w, [l] * len(w), "en", "direct", b),
                "ST route-balanced MBR": lambda w, l: inf.translate_speech(w, [l] * len(w), "en", "mbr", b)}
        rows = []
        for lang in self.langs:
            wavs = self._wavs(self.fleurs_test[lang][:k])
            audio_s = sum(len(w) for w in wavs) / 16000.0
            for name, fn in jobs.items():
                fn(wavs[:1], lang)  # warm-up (kernels, caches)
                cuda_sync()
                t0 = time.time()
                for s in range(0, len(wavs), 8):
                    fn(wavs[s:s + 8], lang)
                cuda_sync()
                rows.append(dict(task=f"{name} [{lang}]", compute_s=round(time.time() - t0, 3), audio_s=round(audio_s, 2)))
            texts = [e["text"] for e in self.bible_test[lang][:k] if tts_text(e["text"])]
            if texts:
                inf.synthesize(texts[:1], lang)
                cuda_sync()
                t0 = time.time()
                out, _ = inf.synthesize(texts, lang)
                cuda_sync()
                rows.append(dict(task=f"TTS [{lang}]", compute_s=round(time.time() - t0, 3),
                                 audio_s=round(sum(len(w) for w in out) / self.cfg.model.tts_sr, 2)))
        for r in rows:
            r["RTF"] = round(r["compute_s"] / r["audio_s"], 4) if r["audio_s"] > 0 else None
        self.put(rows, "efficiency", "rtf")
        if torch.cuda.is_available():
            self.put(torch.cuda.max_memory_allocated(self.device) / 1e9, "efficiency", "peak_gpu_mem_gb")

    # ------------------------------------------------------------------ significance --------
    def eval_significance(self):
        if self.has("significance"):
            return
        self.check()
        out = []
        n = max(200, self.ec.n_bootstrap // 2)

        def common(a, b, keyfmt, k):
            pa, pb = self.load_preds(keyfmt.format(sys=a, k=k)), self.load_preds(keyfmt.format(sys=b, k=k))
            if not pa or not pb:
                LOG.warning(f"significance {a} vs {b} on {k}: predictions missing, skipped")
                return None
            ida = {p["uid"]: p for p in pa}
            pairs = [(ida[p["uid"]], p) for p in pb if p["uid"] in ida]
            if len(pairs) < 10:  # a bootstrap over fewer items is meaningless
                LOG.warning(f"significance {a} vs {b} on {k}: only {len(pairs)} paired predictions, skipped")
                return None
            return pairs

        asr_keys = [f"{s}__{l}" for s, per in self._asr_sets().items() for l in per]
        for base in ["Whisper-medium", "MMS-1B-all", "S1-sel"]:
            for k in asr_keys:
                pairs = common(base, "KORA-sel", "asr__{sys}__{k}", k)
                if pairs is None:
                    continue
                refs = [p["ref"] for p, _ in pairs]
                ea, _ = error_stats(refs, [p["hyp"] for p, _ in pairs])
                eb, nn_ = error_stats(refs, [q["hyp"] for _, q in pairs])
                out.append(dict(task="ASR", set=k, baseline=base, system=f"KORA ({self.inf.asr_mode}, dev-selected)",
                                metric="WER", baseline_score=100 * ea.sum() / nn_.sum(),
                                system_score=100 * eb.sum() / nn_.sum(), p_value=paired_bootstrap_errors(ea, eb, n)))

        def bleu_pair(task, base, system, keyfmt, keys):
            for k in keys:
                pairs = common(base, system, keyfmt, k)
                if pairs is None:
                    continue
                refs = [p["ref"] for p, _ in pairs]
                ha, hb = [p["hyp"] for p, _ in pairs], [q["hyp"] for _, q in pairs]
                out.append(dict(task=task, set=k, baseline=base, system=system, metric="BLEU",
                                baseline_score=bleu(refs, ha), system_score=bleu(refs, hb),
                                p_value=paired_bootstrap(bleu, refs, ha, hb, n=n, higher_is_better=True)))

        st_keys = [f"{s}__{l}-en" for s, per in self._st_sets_en().items() for l in per]
        for base in ["Whisper-medium", "MMS→NLLB", "S1-direct", "KORA-direct", "KORA-cascade"]:
            bleu_pair("ST", base, "KORA-mbr", "st__{sys}__{k}", st_keys)
        mmt_keys = [f"{s}__{a}-{b}" for s, (_, L2) in self.mmt_sets.items() for a, b in [("en", L2), (L2, "en")]]
        bleu_pair("MMT", "KORA (text only)", "KORA (image, learned gate)", "mmt__{sys}__{k}", mmt_keys)
        bleu_pair("MMT", "NLLB-600M (text)", "KORA (image, learned gate)", "mmt__{sys}__{k}", mmt_keys)
        if self.yfacc_test:
            bleu_pair("Speech+image", "KORA (speech only)", "KORA (speech+image)", "smmt__{sys}__{k}", ["yfacc"])
        self.put(out, "significance")

    # ------------------------------------------------------------------ ablations -----------
    def eval_ablations(self, names: List[str]):
        vi = self.data["vis_index"]
        n = max(60, (self.ec.max_eval_utts or 400) // 3)
        for name in names:
            if self.has("ablation", name):
                continue
            self.check()
            self.tr.load_snapshot(f"final_abl_{name}.pt")
            res = {}
            bw = []
            for l in self.langs:
                E = self.bible_test[l][:n]
                bw.append(wer([e["text"] for e in E],
                              self._batched(E, lambda ch: self.inf.transcribe(self._wavs(ch), [l] * len(ch)))))
            res["Bible WER (avg)"] = float(np.mean(bw))
            fb = []
            for l in self.langs:
                E = [e for e in self.fleurs_test[l] if e.get("en")][:n]
                fb.append(bleu([e["en"] for e in E], self._batched(
                    E, lambda ch: self.inf.translate_speech(self._wavs(ch), [l] * len(ch), "en", "direct", 4)[0])))
            res["FLEURS ST BLEU (avg)"] = float(np.mean(fb))
            E = self.mmt_sets["test"][0][: 2 * n]
            rows = [vi[e["vis_uid"]] for e in E]
            idx = list(range(len(E)))
            h1 = self._batched(idx, lambda ii: self.inf.translate_text([E[i]["en"] for i in ii], "en", "ha", 4,
                                                                         [rows[i] for i in ii])[0], 16)
            h2 = self._batched(idx, lambda ii: self.inf.translate_text([E[i]["en"] for i in ii], "en", "ha", 4,
                                                                         [rows[(i + 1) % len(E)] for i in ii])[0], 16)
            refs = [e["ha"] for e in E]
            res["HaVG en→ha BLEU"] = bleu(refs, h1)
            res["Image awareness ΔBLEU"] = bleu(refs, h1) - bleu(refs, h2)
            self.put(res, "ablation", name)

    # ------------------------------------------------------------------ orchestration -------
    def run_all(self, ablation_names: List[str]):
        # 0) decoding choices are made on dev with the final model
        self.tr.load_snapshot("final_tts.pt")
        self.select_decoding()
        # 1) Stage-1 model (before RAPL rounds) — isolates the effect of pseudo-labelling / UDA
        if not self.has("done", "S1"):
            self.tr.load_snapshot("final_stage1.pt")
            self.eval_kora_speech("S1", full=False)
            self.embed_domains("S1 (supervised + MPD)")
            self.put(True, "done", "S1")
        # 2) final KORA
        self.tr.load_snapshot("final_tts.pt")
        self.eval_kora_speech("KORA", full=True)
        self.embed_domains("KORA (after RAPL rounds)")
        self.eval_text_mt()
        self.eval_mmt()
        self.eval_spoken_mmt()
        self.eval_tts()
        self.eval_s2st()
        self.qualitative_examples()
        self.eval_params()
        self.eval_rtf()
        # 3) external baselines, pseudo-label analyses, significance
        self.eval_baselines()
        self.eval_pseudo_labels()
        self._sonar = None
        self.eval_significance()
        # 4) training ablations
        self.eval_ablations(ablation_names)
        self.base.release()
        self._utmos = None
        free_memory()
        self.tr.load_snapshot("final_tts.pt")

    def qualitative_examples(self):
        if self.has("qualitative"):
            return
        self.check()
        ex = []
        groups = [("FLEURS", l, [e for e in self.fleurs_test[l] if e.get("en")][:3]) for l in self.langs]
        groups += [("BibleTTS", l, [e for e in self.bible_test[l] if e.get("en")][:2]) for l in self.langs]
        if self.yfacc_test:
            groups.append(("YFACC", "yo", self.yfacc_test[:3]))
        for set_name, l, E in groups:
            if not E:
                continue
            for e, r in zip(E, self.inf.joint(self._wavs(E), [l] * len(E), "en", self.ec.beams)):
                ex.append(dict(set=set_name, lang=l, reference_transcript=e["text"], kora_transcript=r["transcript"],
                               reference_translation=e.get("en", ""), kora_translation=r["translation"]))
        self.put(ex, "qualitative")


# =============================================================================================
#                                        VISUALISATION
# =============================================================================================
PAL = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e6e5e0"
SYSTEM_COLOR: Dict[str, str] = {}  # colour follows the entity, never its rank


def sys_color(name: str) -> str:
    if name not in SYSTEM_COLOR:
        SYSTEM_COLOR[name] = PAL[len(SYSTEM_COLOR) % len(PAL)]
    return SYSTEM_COLOR[name]


for _n in ["KORA", "S1", "Whisper-medium", "MMS-1B-all", "MMS→NLLB", "NLLB-600M", "MMS-TTS", "Ground truth"]:
    sys_color(_n)


def _family(name: str) -> str:
    for k, fam in [("S1", "S1"), ("Whisper", "Whisper-medium"), ("MMS-1B", "MMS-1B-all"), ("MMS→NLLB", "MMS→NLLB"),
                   ("MMS-ASR", "MMS→NLLB"), ("NLLB", "NLLB-600M"), ("MMS-TTS", "MMS-TTS"), ("Ground", "Ground truth")]:
        if name.startswith(k):
            return fam
    return "KORA" if name.startswith("KORA") else name


plt.rcParams.update({"figure.dpi": 110, "savefig.dpi": 300, "axes.edgecolor": INK2, "axes.labelcolor": INK,
                     "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True, "grid.color": GRID,
                     "grid.linewidth": 0.6, "axes.spines.top": False, "axes.spines.right": False,
                     "font.size": 9, "legend.frameon": False, "lines.linewidth": 2.0})


class Visualizer:
    def __init__(self, cfg: KoraConfig, evaluator: Evaluator):
        self.cfg, self.ev = cfg, evaluator
        self.R, self.tr, self.inf = evaluator.R, evaluator.tr, evaluator.inf
        self.dir = cfg.paths.fig_dir
        self.langs = cfg.data.african_langs
        self.failed: List[str] = []

    def _save(self, fig, name):
        fig.tight_layout()
        for ext in ("png", "pdf"):
            fig.savefig(os.path.join(self.dir, f"{name}.{ext}"), bbox_inches="tight")
        plt.close(fig)

    @staticmethod
    def _grouped_bars(ax, groups, systems, values, ylabel, lower_better=True):
        n = len(systems)
        w = 0.8 / max(1, n)
        x = np.arange(len(groups))
        shades = defaultdict(int)
        for i, s in enumerate(systems):
            fam = _family(s)
            alpha = [1.0, 0.7, 0.5, 0.35, 0.25][min(4, shades[fam])]
            shades[fam] += 1
            vals = [values.get((g, s), np.nan) for g in groups]
            ax.bar(x + (i - (n - 1) / 2) * w, vals, w * 0.92, color=sys_color(fam), alpha=alpha, label=s,
                   edgecolor="white", linewidth=1.0)
        ax.set_xticks(x)
        ax.set_xticklabels(groups)
        ax.set_ylabel(ylabel + (" (↓)" if lower_better else " (↑)"))
        ax.legend(fontsize=7, ncol=2)

    def training_curves(self):
        H = [h for h in read_jsonl(self.tr.hist_path, allow_truncated_tail=True) if not str(h["phase"]).startswith("abl_")]
        T = [h for h in H if h.get("kind") != "dev"]
        if not T:
            return
        df = pd.DataFrame(T)
        phases = list(dict.fromkeys(df["phase"]))
        offs, acc = {}, 0
        for p in phases:
            offs[p] = acc
            acc += int(df[df.phase == p]["step"].max())
        df["gstep"] = df["step"] + df["phase"].map(offs)
        cols = [c for c in df.columns if c.endswith("/total")]
        nc = 3
        nr = int(math.ceil(len(cols) / nc))
        fig, axes = plt.subplots(nr, nc, figsize=(10, 2.4 * nr), squeeze=False)
        for i, c in enumerate(cols):
            ax = axes[i // nc][i % nc]
            s = df[["gstep", c]].dropna().sort_values("gstep")
            ax.plot(s["gstep"], s[c].rolling(5, min_periods=1).mean(), color=PAL[0], marker="o", ms=2.5)
            for p in phases[1:]:
                ax.axvline(offs[p], color=INK2, lw=0.8, ls="--")
            ax.set_title(c.replace("/total", "").upper(), fontsize=9)
            ax.set_xlabel("global step")
        for j in range(len(cols), nr * nc):
            axes[j // nc][j % nc].axis("off")
        self._save(fig, "fig_training_curves")
        dd = pd.DataFrame([h for h in H if h.get("kind") == "dev"])
        if dd.empty:
            return
        dd["gstep"] = dd["step"] + dd["phase"].map(offs)
        dd = dd.sort_values("gstep")
        mm_keys = [(k, lab) for k, lab in [("chrf_mmt_en_ha", "HaVG en→ha (image)"),
                                           ("img_delta_mmt", "image Δ (true − incongruent)"),
                                           ("chrf_smmt_yo_en", "YFACC speech+image→en")] if k in dd.columns]
        fig, axs = plt.subplots(1, 3 + bool(mm_keys), figsize=(12 + 4 * bool(mm_keys), 3))
        for i, l in enumerate(self.langs):
            axs[0].plot(dd["gstep"], dd[f"wer_ctc_{l}"], color=PAL[i], marker="o", ms=3, label=f"{LANG_NAMES[l]} CTC")
            axs[0].plot(dd["gstep"], dd[f"wer_aed_{l}"], color=PAL[i], ls="--", marker="s", ms=3, label=f"{LANG_NAMES[l]} AED")
            axs[1].plot(dd["gstep"], dd[f"chrf_st_{l}"], color=PAL[i], marker="o", ms=4, label=LANG_NAMES[l])
            axs[2].plot(dd["gstep"], dd[f"ssi_st_{l}"], color=PAL[i], marker="o", ms=4, label=LANG_NAMES[l])
        axs[0].set_ylabel("dev WER (↓)")
        axs[1].set_ylabel("dev ST chrF++ (↑)")
        axs[2].set_ylabel("dev ST source-sensitivity (↑)")
        axs[2].axhline(0, color=INK2, lw=0.8)
        for i, (k, lab) in enumerate(mm_keys):
            s_ = dd[["gstep", k]].dropna()
            axs[3].plot(s_["gstep"], s_[k], color=PAL[3 + i], marker="o", ms=4, label=lab)
        if mm_keys:
            axs[3].set_ylabel("dev multimodal chrF++ (↑)")
            axs[3].axhline(0, color=INK2, lw=0.8)
        for a in axs:
            a.set_xlabel("global step")
            a.legend(fontsize=6)
            for p in phases[1:]:
                a.axvline(offs[p], color=INK2, lw=0.8, ls="--")
        self._save(fig, "fig_dev_curves")

    def asr_bars(self):
        A = self.R["asr"]
        systems = [s for s in ["KORA-sel", "KORA-ctc", "KORA-aed", "KORA-joint", "S1-sel", "Whisper-medium", "MMS-1B-all"]
                   if s in A]
        sets = [s for s in ["fleurs", "bible", "yfacc"] if any(k.startswith(s + "/") for sy in systems for k in A[sy])]
        titles = {"fleurs": "FLEURS test (in-domain)", "bible": "BibleTTS held-out (target domain, UDA)",
                  "yfacc": "YFACC test (real spoken captions)"}
        fig, axs = plt.subplots(1, len(sets), figsize=(5 * len(sets), 3.2), squeeze=False)
        for ax, sname in zip(axs[0], sets):
            ls = [l for l in self.langs if any(f"{sname}/{l}" in A[s] for s in systems)]
            vals = {(LANG_NAMES[l], s): A[s][f"{sname}/{l}"]["WER"] for s in systems for l in ls if f"{sname}/{l}" in A[s]}
            self._grouped_bars(ax, [LANG_NAMES[l] for l in ls], systems, vals, "WER %")
            ax.set_title(titles[sname])
        self._save(fig, "fig_asr_wer")
        fig, ax = plt.subplots(figsize=(5, 3))
        vals = {}
        for s in systems:
            if "fleurs/yo" in A[s]:
                r = A[s]["fleurs/yo"]
                vals[("tone-sensitive", s)] = r["WER"]
                vals[("tone-insensitive", s)] = r["WER_notone"]
        self._grouped_bars(ax, ["tone-sensitive", "tone-insensitive"], systems, vals, "Yorùbá WER %")
        self._save(fig, "fig_yoruba_tone")

    def st_bars(self):
        S = self.R["st"]
        systems = [s for s in ["KORA-mbr", "KORA-direct", "KORA-cascade", "S1-direct", "Whisper-medium", "MMS→NLLB"] if s in S]
        for sname in ["fleurs", "bible", "yfacc"]:
            ls = [l for l in self.langs if any(f"{sname}/{l}-en" in S[s] for s in systems)]
            if not ls:
                continue
            fig, axs = plt.subplots(1, 2, figsize=(10, 3.2))
            for ax, met in zip(axs, ["BLEU", "chrF2pp"]):
                vals = {(LANG_NAMES[l] + "→En", s): S[s][f"{sname}/{l}-en"][met]
                        for s in systems for l in ls if f"{sname}/{l}-en" in S[s]}
                self._grouped_bars(ax, [LANG_NAMES[l] + "→En" for l in ls], systems, vals, met, lower_better=False)
            fig.suptitle({"fleurs": "FLEURS", "bible": "BibleTTS (World English Bible refs)", "yfacc": "YFACC"}[sname])
            self._save(fig, f"fig_st_scores_{sname}")
        for sysname in ["KORA-direct", "KORA-cascade"]:
            if sysname not in S:
                continue
            for met, cmap in [("chrF2pp", "Blues"), ("SSI", "Greens")]:
                M = np.full((len(self.langs), len(self.langs)), np.nan)
                for i, a in enumerate(self.langs):
                    for j, b in enumerate(self.langs):
                        r = S[sysname].get(f"fleurs/{a}-{b}")
                        if a != b and r is not None and r.get(met) is not None:
                            M[i, j] = r[met]
                if not np.isfinite(M).any():
                    continue
                fig, ax = plt.subplots(figsize=(4, 3.4))
                im = ax.imshow(M, cmap=cmap, vmin=min(0, np.nanmin(M)), vmax=max(1e-6, np.nanmax(M)))
                ax.set_xticks(range(len(self.langs)))
                ax.set_yticks(range(len(self.langs)))
                ax.set_xticklabels([LANG_NAMES[l] for l in self.langs])
                ax.set_yticklabels([LANG_NAMES[l] for l in self.langs])
                ax.set_xlabel("target text")
                ax.set_ylabel("source speech")
                ax.grid(False)
                for i in range(len(self.langs)):
                    for j in range(len(self.langs)):
                        if np.isfinite(M[i, j]):
                            ax.text(j, i, f"{M[i, j]:.1f}", ha="center", va="center", fontsize=8,
                                    color="white" if M[i, j] > np.nanmax(M) * 0.6 else INK)
                fig.colorbar(im, ax=ax, label="chrF++" if met == "chrF2pp" else "source-sensitivity (chrF++ pts)")
                ax.set_title(sysname, fontsize=8)
                self._save(fig, f"fig_st_african_{met}_{sysname}")

    def collapse_fig(self):
        """Output diversity vs source sensitivity of every ST system: a collapsed system sits at (0, 0)."""
        pts = [(sy, k, v["distinct"], v["SSI"]) for sy, d in self.R.get("st", {}).items() for k, v in d.items()
               if v.get("SSI") is not None and np.isfinite(v["SSI"])]
        if not pts:
            return
        fig, ax = plt.subplots(figsize=(6, 3.6))
        for fam in dict.fromkeys(_family(p[0]) for p in pts):
            q = [p for p in pts if _family(p[0]) == fam]
            ax.scatter([p[2] for p in q], [p[3] for p in q], s=18, color=sys_color(fam), label=fam, alpha=0.8,
                       edgecolors="white", linewidths=0.4)
        ax.axhline(0, color=INK2, lw=0.8, ls="--")
        ax.set_xlabel("distinct outputs / inputs")
        ax.set_ylabel("source-sensitivity index (chrF++ pts)")
        ax.legend(fontsize=7)
        self._save(fig, "fig_collapse_diagnostics")

    def mmt_figs(self):
        M = self.R["mmt"]
        systems = [s for s in ["KORA (image, learned gate)", "KORA (image, gate forced open)", "KORA (text only)",
                               "KORA (incongruent image)", "NLLB-600M (text)"] if s in M]
        groups = [g for g in ["test/en-ha", "challenge/en-ha", "test/ha-en", "challenge/ha-en", "yfacc/en-yo", "yfacc/yo-en"]
                  if any(g in M[s] for s in systems)]
        vals = {(g, s): M[s][g]["BLEU"] for g in groups for s in systems if g in M[s]}
        fig, ax = plt.subplots(figsize=(11, 3.2))
        self._grouped_bars(ax, groups, systems, vals, "BLEU", lower_better=False)
        ax.set_title("Multimodal MT (HaVG, YFACC): effect of the image and of the utility gate")
        self._save(fig, "fig_mmt")
        for sname, g in self.R.get("gate_analysis", {}).items():
            fig, axs = plt.subplots(1, 2, figsize=(9, 3))
            axs[0].scatter(g["delta"], g["gate"], s=10, color=PAL[0], alpha=0.6, edgecolors="white", linewidths=0.4)
            axs[0].axvline(0, color=INK2, lw=0.8, ls="--")
            axs[0].set_xlabel("counterfactual utility Δ = NLL(incongruent) − NLL(true) [nats]")
            axs[0].set_ylabel("learned gate g")
            axs[0].set_title(f"{sname}: Spearman ρ = {g['spearman']:.3f}")
            axs[1].hist(g["gate"], bins=30, color=PAL[0], edgecolor="white")
            axs[1].set_xlabel("gate value g")
            axs[1].set_ylabel("count")
            self._save(fig, f"fig_gate_analysis_{sname}")

    def pl_figs(self):
        for rk, pa in self.R.get("pl_analysis", {}).items():
            fig, ax = plt.subplots(figsize=(6, 3.6))
            for i, (name, pts) in enumerate(pa["curves"].items()):
                pts = np.asarray(pts)
                style = dict(lw=2.6) if "ours" in name else dict(lw=1.4, alpha=0.9)
                ax.plot(100 * pts[:, 0], pts[:, 1], color=PAL[i % len(PAL)] if name != "random" else INK2,
                        ls="--" if name == "random" else "-", label=name, **style)
            ax.set_xlabel("retained pseudo-labels (%)")
            ax.set_ylabel("CER of retained pseudo-labels vs hidden gold (↓)")
            ax.legend(fontsize=7)
            self._save(fig, f"fig_pl_quality_retention_{rk}")
            sc = pa["scores"]
            fig, ax = plt.subplots(figsize=(5, 3.4))
            for i, l in enumerate(self.langs):
                xs = [s["S"] for s in sc if s["lang"] == l]
                ys = [min(100, s["cer"]) for s in sc if s["lang"] == l]
                rho = pa.get("spearman_per_lang", {}).get(l)
                ax.scatter(xs, ys, s=9, color=PAL[i], alpha=0.55, edgecolors="white", linewidths=0.3,
                           label=f"{LANG_NAMES[l]}" + (f" (ρ={rho:.2f})" if rho is not None else ""))
            ax.set_xlabel("RAPL score S")
            ax.set_ylabel("utterance CER vs gold (%)")
            ax.set_title(f"pooled ρ = {pa['spearman_S_vs_CER']:.3f} · non-empty ρ = {pa['spearman_S_vs_CER_nonempty']:.3f}",
                         fontsize=8)
            ax.legend()
            self._save(fig, f"fig_pl_score_vs_cer_{rk}")

    def domain_figs(self):
        D = self.R.get("domain", {})
        if not D:
            return
        fig, axs = plt.subplots(1, len(D), figsize=(5 * len(D), 4), squeeze=False)
        markers = {"ha": "o", "yo": "s", "ln": "^"}
        for ax, (tag, d) in zip(axs[0], D.items()):
            for i, dom in enumerate(["fleurs", "bible"]):
                for l in self.langs:
                    pts = np.asarray([(p["x"], p["y"]) for p in d["tsne"] if p["domain"] == dom and p["lang"] == l])
                    if len(pts):
                        ax.scatter(pts[:, 0], pts[:, 1], s=12, color=PAL[i], marker=markers.get(l, "o"), alpha=0.6,
                                   edgecolors="white", linewidths=0.3,
                                   label=f"{'FLEURS' if dom == 'fleurs' else 'BibleTTS'} · {LANG_NAMES[l]}")
            ax.set_title(f"{tag}\nMMD²={d['mmd2']:.3f} · domain-clf acc={100 * d['domain_clf_acc']:.1f}%", fontsize=8)
            ax.set_xticks([])
            ax.set_yticks([])
            ax.legend(fontsize=6)
        self._save(fig, "fig_domain_tsne")

    def tts_figs(self):
        ents = self.tr.tts_entries_from_disk(self.tr.tts_tag())
        if ents:
            e = ents[0]
            mel = np.load(e["mel"]).astype(np.float32)
            fig, ax = plt.subplots(figsize=(10, 3))
            ax.imshow(mel, origin="lower", aspect="auto", cmap="magma")
            ax.grid(False)
            b = np.cumsum(e["dur"])
            for x, c, d in zip(b, [self.tr.chars.itos[c] for c in e["chars"]], e["dur"]):
                ax.axvline(x, color="white", lw=0.4, alpha=0.6)
                ax.text(x - d / 2, mel.shape[0] - 6, c, color="white", fontsize=6, ha="center")
            ax.set_xlabel(f"mel frame ({1000 / self.tr.mel_fps:.1f} ms)")
            ax.set_ylabel("mel bin")
            ax.set_title("CTC self-alignment used as TTS durations (no external aligner)")
            self._save(fig, "fig_ctc_self_alignment")
        mel_ex = vocos_mel_extractor(self.cfg.model.vocoder_model, self.cfg.model)
        items = [next(e for e in self.ev.bible_test[l] if tts_text(e["text"])) for l in self.langs]
        fig, axs = plt.subplots(len(items), 3, figsize=(12, 2.4 * len(items)), squeeze=False)
        for i, it in enumerate(items):
            gt = mel_ex(load_audio(it["audio24"], 24000))
            _, mels = self.inf.synthesize([it["text"]], it["lang"])
            mms = None
            if it["lang"] in self.cfg.eval.mms_tts_langs:
                mms = mel_ex(self.ev.base.mms_tts([it["text"]], it["lang"])[0])
            for j, (title, m) in enumerate([("ground truth", gt), ("KORA-TTS", mels[0]), ("MMS-TTS", mms)]):
                ax = axs[i][j]
                ax.grid(False)
                if m is None:
                    ax.text(0.5, 0.5, f"no MMS-TTS model for {LANG_NAMES[it['lang']]}", ha="center", va="center",
                            transform=ax.transAxes, color=INK2)
                    ax.set_xticks([])
                    ax.set_yticks([])
                    continue
                ax.imshow(m, origin="lower", aspect="auto", cmap="magma")
                ax.set_title(f"{title} · {LANG_NAMES[it['lang']]}", fontsize=8)
        self._save(fig, "fig_tts_mel_comparison")

    def ctc_posterior_fig(self):
        e = self.ev.fleurs_test[self.langs[0]][0]
        enc = self.ev.dec.encode([load_audio(e["audio"])])
        p = enc["ctc_logits"][0].float().softmax(-1)[enc["fmask"][0]].cpu().numpy()
        top = np.argsort(-p.max(0))[:30]
        fig, ax = plt.subplots(figsize=(10, 3.5))
        ax.imshow(p[:, top].T, aspect="auto", origin="lower", cmap="Blues")
        ax.set_yticks(range(len(top)))
        ax.set_yticklabels([self.tr.chars.itos[t] for t in top], fontsize=6)
        ax.set_xlabel("frame (20 ms)")
        ax.grid(False)
        ax.set_title("CTC posteriors (top-30 symbols)")
        self._save(fig, "fig_ctc_posteriors")

    def wer_by_duration(self):
        rows = []
        for l in self.langs:
            for sys_ in ["KORA-sel", "Whisper-medium", "MMS-1B-all"]:
                for p in read_jsonl(os.path.join(self.cfg.paths.pred_dir, f"asr__{sys_}__fleurs__{l}.jsonl")):
                    e, n = error_stats([p["ref"]], [p["hyp"]])
                    rows.append(dict(system=sys_, dur=p["dur"], e=e[0], n=n[0]))
        if not rows:
            return
        df = pd.DataFrame(rows)
        edges = [0, 5, 10, 15, 20, self.cfg.data.eval_max_dur + 0.5]
        labels = ["0-5 s", "5-10 s", "10-15 s", "15-20 s", f"20-{self.cfg.data.eval_max_dur:.0f} s"]
        df["bin"] = pd.cut(df["dur"], edges, labels=labels)
        g = df.groupby(["bin", "system"], observed=False).agg(e=("e", "sum"), n=("n", "sum")).reset_index()
        g["wer"] = 100 * g["e"] / g["n"].clip(lower=1)
        vals = {(str(r["bin"]), r["system"]): r["wer"] for _, r in g.iterrows() if r["n"] > 0}
        fig, ax = plt.subplots(figsize=(7, 3))
        self._grouped_bars(ax, labels, list(dict.fromkeys(df["system"])), vals, "WER %")
        self._save(fig, "fig_wer_by_duration")

    def efficiency_fig(self):
        rtf = [r for r in self.R.get("efficiency", {}).get("rtf", []) if r.get("RTF") is not None]
        if not rtf:
            return
        fig, ax = plt.subplots(figsize=(7, 0.3 * len(rtf) + 1))
        ax.barh([r["task"] for r in rtf], [r["RTF"] for r in rtf], color=PAL[0], edgecolor="white")
        ax.set_xlabel("real-time factor (↓)")
        self._save(fig, "fig_rtf")

    def ablation_fig(self):
        A = self.R.get("ablation", {})
        if not A:
            return
        metrics = ["Bible WER (avg)", "FLEURS ST BLEU (avg)", "HaVG en→ha BLEU", "Image awareness ΔBLEU"]
        fig, axs = plt.subplots(1, len(metrics), figsize=(13, 3))
        names = list(A.keys())
        for ax, m in zip(axs, metrics):
            ax.barh(names, [A[n][m] for n in names], color=[PAL[0] if n == "rapl_full" else PAL[1] for n in names],
                    edgecolor="white")
            ax.set_title(m + (" (↓)" if "WER" in m else " (↑)"), fontsize=8)
        self._save(fig, "fig_ablations")

    def make_all(self):
        for fn in [self.training_curves, self.asr_bars, self.st_bars, self.collapse_fig, self.mmt_figs, self.pl_figs,
                   self.domain_figs, self.tts_figs, self.ctc_posterior_fig, self.wer_by_duration, self.efficiency_fig,
                   self.ablation_fig]:
            try:
                fn()
                LOG.info(f"figure block {fn.__name__} done")
            except Exception as e:  # a figure must never discard hours of evaluation; it is reported instead
                LOG.exception(f"figure block {fn.__name__} FAILED: {e}")
                self.failed.append(f"{fn.__name__}: {type(e).__name__}: {e}")
                plt.close("all")


# =============================================================================================
#                                     TABLES / REPORT
# =============================================================================================
def _is_missing(v) -> bool:
    return v is None or (isinstance(v, (float, np.floating)) and not np.isfinite(v))


def df_to_markdown(df: pd.DataFrame) -> str:
    fmt = lambda v: ("–" if _is_missing(v) else f"{v:.2f}" if isinstance(v, (float, np.floating)) else str(v))
    cols = list(df.columns)
    lines = ["| " + " | ".join(map(str, cols)) + " |", "|" + "|".join(["---"] * len(cols)) + "|"]
    for _, r in df.iterrows():
        lines.append("| " + " | ".join(fmt(r[c]) for c in cols) + " |")
    return "\n".join(lines)


def df_to_latex(df: pd.DataFrame, caption: str, label: str) -> str:
    esc = lambda s: str(s).replace("\\", r"\textbackslash{}").replace("_", r"\_").replace("%", r"\%") \
        .replace("&", r"\&").replace("#", r"\#").replace("→", r"$\rightarrow$").replace("↔", r"$\leftrightarrow$") \
        .replace("Δ", r"$\Delta$").replace("±", r"$\pm$").replace("λ", r"$\lambda$")
    fmt = lambda v: ("--" if _is_missing(v) else f"{v:.2f}" if isinstance(v, (float, np.floating)) else esc(v))
    cols = list(df.columns)
    out = [r"\begin{table}[t]", r"\centering", r"\small", r"\caption{" + esc(caption) + "}", r"\label{" + label + "}",
           r"\begin{tabular}{l" + "r" * (len(cols) - 1) + "}", r"\toprule",
           " & ".join(esc(c) for c in cols) + r" \\", r"\midrule"]
    for _, r in df.iterrows():
        out.append(" & ".join(fmt(r[c]) for c in cols) + r" \\")
    out += [r"\bottomrule", r"\end{tabular}", r"\end{table}"]
    return "\n".join(out)


class ReportWriter:
    NOTES = [
        "All speech is REAL: FLEURS (read Wikipedia sentences), BibleTTS (studio Bible readings) and YFACC (spoken "
        "Yorùbá captions of Flickr8k images, one speaker). Images are real (Visual Genome for HaVG, Flickr8k for YFACC).",
        "BibleTTS adaptation-split transcripts are never used by the recognition/translation branches (unsupervised "
        "domain adaptation); they ARE used to train the TTS voice. Test verses are used by no training step.",
        "eBible text is used for text-only target-domain MT; every chapter with audio anywhere in the experiment is "
        "excluded from it. Bible-domain speech translation is scored against the World English Bible (public domain).",
        "BibleTTS file names are not reliable verse ids (all Yorùbá clips and many Hausa clips are shifted; many Hausa "
        "clips are sub-verse segments). Verses are identified by matching the transcript against the same translation "
        "in eBible. Only clips that are exactly one whole verse (same text and length, no section heading read "
        "aloud, no second clip of that verse) receive an English reference; verses next to a WEB renumbering are "
        "never used as references or MT pairs.",
        "MMS-1B-all and MMS-TTS were trained on MMS-lab New-Testament recordings; comparisons on the BibleTTS "
        "domain may therefore favour the MMS baselines.",
        "MMS-TTS has no Lingala model: the MMS-TTS and MMS cascade S2ST baselines are reported for Hausa and "
        "Yorùbá targets only.",
        "CER counts spaces (standard). CER_nospace is a diagnostic: a large WER/CER_nospace ratio reveals word-"
        "boundary errors. WER_ortho removes orthography-only marks (the Hausa Bible breve, e.g. 'yă').",
        "SSI (source-sensitivity index) = chrF++ against true references minus chrF++ against references of other "
        "inputs; SSI ≈ 0 means the outputs do not depend on the input (decoder collapse).",
        "Evaluation utterances are limited to <= {eval_max_dur:.0f} s (Whisper's decoding window); training "
        "utterances to <= {max_dur:.0f} s. ASR decoding mode and joint λ are selected on dev sets only.",
        "The 'SONAR xsim' pseudo-label filter implements the LASER-style filter of Gheini et al. (2023) with SONAR, "
        "the successor of LASER that covers Lingala.",
        "The 'no_sab_anchor' ablation starts, like every ablation, from the anchored Stage-1 model: its acoustic-only "
        "head is freshly initialised at that point and trained for the ablation budget only. It measures swapping the "
        "bridge after the warm start; the controlled from-scratch comparison is the SAB learnability check (README §6).",
        "YFACC English targets are the Flickr8k captions, detokenised ('a man 's hat .' -> 'A man's hat.') so that "
        "all English targets and references share one convention.",
    ]

    def __init__(self, cfg: KoraConfig, R: dict, stats: dict, failed_figures: Optional[List[str]] = None):
        self.cfg, self.R, self.stats = cfg, R, stats
        self.langs = cfg.data.african_langs
        self.tables: List[Tuple[str, str, pd.DataFrame]] = []
        self.failed = failed_figures or []

    def add(self, name, caption, df):
        if df is None or df.empty:
            return
        self.tables.append((name, caption, df))
        df.to_csv(os.path.join(self.cfg.paths.table_dir, f"{name}.csv"), index=False)
        with open(os.path.join(self.cfg.paths.table_dir, f"{name}.tex"), "w") as f:
            f.write(df_to_latex(df, caption, f"tab:{name}"))

    def _asr_table(self, sname):
        rows = []
        for sys_, d in self.R.get("asr", {}).items():
            row = dict(system=sys_)
            ok = False
            for l in self.langs:
                r = d.get(f"{sname}/{l}")
                if r is None:
                    continue
                ok = True
                row[f"{l} WER"] = r["WER"]
                row[f"{l} CER"] = r["CER"]
                row[f"{l} CER_nospace"] = r["CER_nospace"]
                row[f"{l} WER_ortho"] = r["WER_ortho"]
                row[f"{l} WER CI"] = f"[{r['WER_CI'][0]:.1f}, {r['WER_CI'][1]:.1f}]"
            if ok:
                rows.append(row)
        return pd.DataFrame(rows)

    def _st_table(self, sname):
        rows = []
        for sys_, d in self.R.get("st", {}).items():
            row, ok = dict(system=sys_), False
            for l in self.langs:
                r = d.get(f"{sname}/{l}-en")
                if r:
                    ok = True
                    row[f"{l}→en BLEU"] = r["BLEU"]
                    row[f"{l}→en chrF++"] = r["chrF2pp"]
                    row[f"{l}→en SSI"] = r["SSI"]
            if ok:
                rows.append(row)
        return pd.DataFrame(rows)

    def build(self):
        R, L, s = self.R, self.langs, self.stats
        self.add("t01_datasets", "Corpora used (utterances / hours; all speech is real).", pd.DataFrame(
            [dict(language=LANG_NAMES[l], fleurs_train=s["fleurs"][l]["train"], fleurs_dev=s["fleurs"][l]["dev"],
                  fleurs_test=s["fleurs"][l]["test"], fleurs_h=s["fleurs_hours"][l],
                  bible_adapt=s["bibletts"][l]["target_adapt"], bible_dev=s["bibletts"][l]["target_dev"],
                  bible_test=s["bibletts"][l]["target_test"], bible_h=s["bibletts_hours"][l],
                  bible_test_en_refs=s["bible_test_with_english_ref"][l],
                  yfacc=(sum(s["yfacc_real_speech"].values()) if l == "yo" else 0)) for l in L]))
        for sname, cap in [("fleurs", "ASR on FLEURS test (in-domain). WER/CER in %, 95% bootstrap CI."),
                           ("bible", "Unsupervised domain adaptation: ASR on held-out BibleTTS (gold never used by ASR)."),
                           ("yfacc", "ASR on YFACC test (real spoken Yorùbá image captions).")]:
            self.add(f"t02_asr_{sname}", cap, self._asr_table(sname))
        rows = []
        for sys_, d in R.get("asr", {}).items():
            for sname in ["fleurs", "yfacc"]:
                r = d.get(f"{sname}/yo")
                if r:
                    rows.append(dict(system=sys_, set=sname, **{"yo WER": r["WER"], "yo WER (tone-insensitive)": r["WER_notone"],
                                                                "yo CER": r["CER"], "yo CER (tone-insensitive)": r["CER_notone"]}))
        self.add("t03_yoruba_tones", "Yorùbá tone-diacritic sensitivity (dot-below always kept).", pd.DataFrame(rows))
        self.add("t04_st_x_en", "Speech translation X→English on FLEURS test.", self._st_table("fleurs"))
        self.add("t04b_st_bible_x_en", "Speech translation X→English on BibleTTS test (World English Bible references).",
                 self._st_table("bible"))
        self.add("t04c_st_yfacc", "Speech translation Yorùbá→English on YFACC test (speech only).", self._st_table("yfacc"))
        rows = []
        for sys_ in ["KORA-direct", "KORA-cascade"]:
            d = R.get("st", {}).get(sys_, {})
            rows += [dict(system=sys_, pair=f"{a}→{b}", BLEU=d[f"fleurs/{a}-{b}"]["BLEU"], chrF=d[f"fleurs/{a}-{b}"]["chrF2pp"],
                          SSI=d[f"fleurs/{a}-{b}"]["SSI"]) for a in L for b in L if a != b and f"fleurs/{a}-{b}" in d]
        self.add("t05_st_african", "Many-to-many speech translation between African languages (FLEURS).", pd.DataFrame(rows))
        rows = []
        for sys_, dd in R.get("mt", {}).items():
            row = dict(system=sys_)
            for k, v in dd.items():
                row[k + " BLEU"] = v["BLEU"]
                row[k + " chrF++"] = v["chrF2pp"]
            rows.append(row)
        self.add("t06_text_mt", "Text MT on FLEURS (FLORES) and Bible-domain test sentences.", pd.DataFrame(rows))
        rows = [dict(system=sys_, **{k + " BLEU": v["BLEU"] for k, v in dd.items()}) for sys_, dd in R.get("mmt", {}).items()]
        self.add("t07_mmt", "Multimodal MT: Hausa Visual Genome (test / challenge) and YFACC (Flickr8k images).",
                 pd.DataFrame(rows))
        self.add("t08_gate", "Does the learned gate predict counterfactual visual utility?", pd.DataFrame(
            [dict(set=k, spearman_gate_vs_delta=v["spearman"], frac_image_helpful=v["frac_helpful"],
                  mean_gate=float(np.mean(v["gate"])) if v["gate"] else None) for k, v in R.get("gate_analysis", {}).items()]))
        rows = [dict(system=sys_, **{f"{k} BLEU": v["BLEU"] for k, v in dd.items()},
                     **{f"{k} chrF++": v["chrF2pp"] for k, v in dd.items()}) for sys_, dd in R.get("smmt", {}).items()]
        self.add("t09_speech_image", "Speech+image→English on YFACC (REAL Yorùbá speech, REAL images).", pd.DataFrame(rows))
        rows = [dict(system=sys_, set=k, **{m: v.get(m) for m in ["CER_judge_MMS", "WER_judge_MMS", "CER_judge_KORA",
                                                                     "MCD_dB", "UTMOS", "dur_ratio"]})
                for sys_, dd in R.get("tts", {}).items() for k, v in dd.items()]
        self.add("t10_tts", "TTS: intelligibility (external MMS-ASR judge), MCD vs studio reference, UTMOS.", pd.DataFrame(rows))
        rows = [dict(system=sys_, pair=k, **v) for sys_, dd in R.get("s2st", {}).items() for k, v in dd.items()]
        self.add("t11_s2st", "Speech-to-speech translation between African languages (ASR-BLEU via MMS-ASR).", pd.DataFrame(rows))
        for rk, pa in R.get("pl_analysis", {}).items():
            rows = [dict(strategy=k, **{m: v[m] for m in ["retention", "hours", "WER", "CER"]},
                         **{f"WER {l}": v["per_lang"].get(l) for l in L}) for k, v in pa["strategies"].items()]
            self.add(f"t12_pl_strategies_{rk}", f"Pseudo-label quality vs hidden gold ({rk}).", pd.DataFrame(rows))
            wd = pa["word_error_detection"]
            self.add(f"t13_amt_detection_{rk}", "Word-level route disagreement as a pseudo-label error detector.",
                     pd.DataFrame([dict(AUROC=wd["AUROC"], precision=wd["precision"], recall=wd["recall"],
                                        base_word_error_rate=wd["word_error_rate"],
                                        spearman_S_vs_CER=pa["spearman_S_vs_CER"],
                                        spearman_nonempty=pa["spearman_S_vs_CER_nonempty"],
                                        **{f"spearman_{l}": pa["spearman_per_lang"].get(l) for l in L})]))
        self.add("t14_domain_gap", "Source/target representation gap of the speech encoder.", pd.DataFrame(
            [dict(model=k, MMD2=v["mmd2"], domain_classifier_acc=100 * v["domain_clf_acc"], proxy_A_distance=v["proxy_A_distance"])
             for k, v in R.get("domain", {}).items()]))
        self.add("t15_ablations", "Training ablations (same Stage-1 start, same budget, same round-1 pseudo-labels).",
                 pd.DataFrame([dict(variant=k, **v) for k, v in R.get("ablation", {}).items()]))
        self.add("t16_params", "Parameters (millions).", pd.DataFrame(R.get("efficiency", {}).get("params", [])))
        self.add("t17_rtf", "Inference speed (real-time factor, dedicated benchmark).",
                 pd.DataFrame(R.get("efficiency", {}).get("rtf", [])))
        self.add("t18_significance", "Paired bootstrap significance (p-value that the system is not better).",
                 pd.DataFrame(R.get("significance", [])))
        self.add("t19_qualitative", "Qualitative joint transcription + translation examples.",
                 pd.DataFrame(R.get("qualitative", [])))
        rows = [dict(task="ST", system=sy, set=k, distinct=v.get("distinct"), SSI=v.get("SSI"), chrF=v.get("chrF2pp"))
                for sy, d in R.get("st", {}).items() for k, v in d.items()]
        rows += [dict(task="ASR", system=sy, set=k, distinct=v.get("distinct"), SSI=None, chrF=None)
                 for sy, d in R.get("asr", {}).items() for k, v in d.items()]
        self.add("t20_collapse_diagnostics", "Collapse diagnostics: output diversity and source sensitivity.",
                 pd.DataFrame(rows))
        dec = R.get("decoding")
        if dec:
            self.add("t21_decoding_selection", f"Dev-set selection of the ASR decoding mode (selected: {dec['asr_mode']}, "
                                               f"λ={dec['joint_lambda']}).",
                     pd.DataFrame([dict(mode=k, dev_WER=v) for k, v in dec["dev_wer"].items()]))

    def write(self):
        self.build()
        dc = self.cfg.data
        md = [f"# KORA v2 — results report ({datetime.datetime.now():%Y-%m-%d %H:%M})", "",
              "All numbers are produced by this run; baselines are real off-the-shelf models evaluated on identical subsets.",
              "", "## Notes", ""] + [f"- {n.format(eval_max_dur=dc.eval_max_dur, max_dur=dc.max_dur)}" for n in self.NOTES] + [""]
        if self.failed:
            md += ["## Figure blocks that failed", ""] + [f"- {f}" for f in self.failed] + [""]
        for name, cap, df in self.tables:
            md += [f"## {name}: {cap}", "", df_to_markdown(df), ""]
        figs = sorted(glob.glob(os.path.join(self.cfg.paths.fig_dir, "*.png")))
        md += ["## Figures", ""] + [f"- `{os.path.relpath(f, self.cfg.paths.results_dir)}`" for f in figs]
        with open(os.path.join(self.cfg.paths.results_dir, "REPORT.md"), "w", encoding="utf-8") as f:
            f.write("\n".join(md))
        LOG.info(f"report written: {len(self.tables)} tables, {len(figs)} figures")


# =============================================================================================
#                               EXPORT / RELOAD FOR INFERENCE
# =============================================================================================
def export_bundle(cfg: KoraConfig, model: KORA, chars: CharVocab, mel_stats: dict, path: str):
    torch.save(dict(config=cfg.to_dict(), chars=chars.itos, model=trainable_state_dict(model), mel_stats=mel_stats,
                    sab_mode=model.sab_mode, transformers=transformers.__version__, torch=torch.__version__),
               path + ".tmp")
    os.replace(path + ".tmp", path)
    LOG.info(f"inference bundle saved to {path} ({os.path.getsize(path) / 1e6:.0f} MB)")


def load_bundle(path: str, device) -> Tuple[KORA, TextTok, CharVocab, KoraConfig, SpeechFeaturizer]:
    """Rebuild KORA from the pretrained backbones + the saved trainable weights and TTS statistics."""
    b = torch.load(path, map_location="cpu", weights_only=False)
    cfg = KoraConfig(run_name=b["config"]["run_name"])
    for sec in ["data", "model", "pl", "train", "eval"]:
        for k, v in b["config"][sec].items():
            setattr(getattr(cfg, sec), k, v)
    chars = CharVocab(b["chars"])
    tok = TextTok(cfg.model.text_model, cfg.data.nllb_codes,
                  AutoConfig.from_pretrained(cfg.model.text_model).decoder_start_token_id)
    model = KORA(cfg, chars, tok)
    load_trainable_state(model, b["model"])
    model.sab_mode = b.get("sab_mode", "anchored")
    model.tts.set_mel_stats(b["mel_stats"]["mean"], b["mel_stats"]["std"])
    model.tts.seen_conds = [tuple(s) for s in b["mel_stats"].get("seen_conds", [])]
    return model.to(device).eval(), tok, chars, cfg, SpeechFeaturizer(cfg.model.speech_model)


def verify_bundle(path: str, model: KORA):
    """Reloads the exported bundle on CPU and checks that every trainable tensor and the TTS statistics
    are bit-identical to the model in memory."""
    m2 = load_bundle(path, torch.device("cpu"))[0]
    ref, got = trainable_state_dict(model), trainable_state_dict(m2)
    bad = [k for k in ref if not torch.equal(ref[k], got[k])]
    bad += [n for n in ("mel_mean", "mel_std") if not torch.equal(getattr(model.tts, n).cpu(), getattr(m2.tts, n))]
    if sorted(model.tts.seen_conds) != sorted(m2.tts.seen_conds):
        bad.append("seen_conds")
    del m2
    free_memory()
    if bad:
        raise RuntimeError(f"exported bundle differs from the trained model: {bad[:5]}")
    LOG.info("inference bundle verified (reloaded weights are identical)")


def environment_info() -> dict:
    return dict(python=sys.version.split()[0], torch=torch.__version__, transformers=transformers.__version__,
                platform=platform.platform(), kaggle=IS_KAGGLE, cuda=torch.cuda.is_available(),
                gpus=[torch.cuda.get_device_name(i) for i in range(torch.cuda.device_count())])


# =============================================================================================
#                                            MAIN
# =============================================================================================
def main():
    cfg = KoraConfig()
    cfg.paths.make()
    setup_logger(cfg.paths.log_dir)
    if not torch.cuda.is_available() and os.environ.get("KORA_ALLOW_CPU") != "1":
        raise RuntimeError("KORA requires a CUDA GPU (Kaggle: Accelerator = GPU T4 x2 or P100)")
    import_previous_session(cfg.paths)
    seed_everything(cfg.train.seed)
    device = torch.device("cuda:0") if torch.cuda.is_available() else torch.device("cpu")
    aux = torch.device("cuda:1") if torch.cuda.device_count() > 1 else device
    LOG.info(f"KORA v2 | device={device} aux={aux} | {environment_info()}")
    cfg.save(os.path.join(cfg.paths.results_dir, "config.json"))
    save_json(os.path.join(cfg.paths.results_dir, "environment.json"), environment_info())

    # ---------------------------------------------------------------- data -----------------
    data = DataHub(cfg).build_all(device)
    vis_store = VisStore(data["vis_path"], len(data["vis_index"]), 2 + cfg.data.vis_grid ** 2, cfg.model.vis_dim)

    # ---------------------------------------------------------------- vocabularies ---------
    if os.path.exists(cfg.paths.vocab_path):
        chars = CharVocab.load(cfg.paths.vocab_path)
    else:
        chars = CharVocab.build([m["text"] for m in data["fleurs"] if m["split"] == "train"] +
                                [y["yo"] for y in data["yfacc"] if y["split"] == "train"] +
                                [s["text"] for s in data["spoken"] if s["split"] == "train"])
        chars.save(cfg.paths.vocab_path)
    tok = TextTok(cfg.model.text_model, cfg.data.nllb_codes,
                  AutoConfig.from_pretrained(cfg.model.text_model).decoder_start_token_id)
    featurizer = SpeechFeaturizer(cfg.model.speech_model)
    LOG.info(f"char vocab {len(chars)} | NLLB vocab {len(tok)} | speech front-end {featurizer.kind}")

    # ---------------------------------------------------------------- model ----------------
    model = KORA(cfg, chars, tok).to(device)
    LOG.info(f"KORA params: total {count_params(model) / 1e6:.1f}M | trainable {count_params(model, True) / 1e6:.1f}M")
    trainer = Trainer(cfg, model, tok, chars, data, vis_store, featurizer, device, aux)
    try:
        trainer.fit()
        abl = trainer.run_ablations()
        trainer.load_snapshot("final_tts.pt")
        bundle = os.path.join(cfg.paths.results_dir, "kora_final_bundle.pt")
        if not trainer.done("bundle_verified"):
            export_bundle(cfg, model, chars, load_json(trainer.mel_stats_path), bundle)
            verify_bundle(bundle, model)
            trainer.mark("bundle_verified")
        trainer.release_teacher()
        evaluator = Evaluator(cfg, trainer, device, aux)
        evaluator.run_all(abl)
        viz = Visualizer(cfg, evaluator)
        viz.make_all()
        ReportWriter(cfg, evaluator.R, data["stats"], viz.failed).write()
        LOG.info(f"DONE. Results in {cfg.paths.results_dir}")
    except SessionTimeout:
        LOG.info("Session time budget reached — everything done so far is saved. Re-run this notebook with this "
                 "version's output attached as input and KORA continues from where it stopped.")


if __name__ == "__main__":
    main()
