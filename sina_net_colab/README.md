# SINA-Net v4 — Google Colab edition

The v4 SINA-Net training and evaluation script, adapted to Google Colab's G4 runtime. The network, losses and
training recipe are unchanged, and v4 checkpoints load as-is. On top of that, the Colab edition adds automatic
dataset handling, persistence on Google Drive, and a full evaluation and analysis suite.

| File | What it is |
|---|---|
| `sina_net_v4_colab.py` | The whole pipeline in one file. Paste it into one Colab cell, or run `!python sina_net_v4_colab.py --preset deblur`. |
| `SINA_Net_v4_Colab.ipynb` | Ready-made notebook: mount Drive → load the definitions → choose a preset → run. |
| `make_notebook.py` | Rebuilds the notebook from the `.py`. Run it after editing the script. |

## Running on Colab

1. **Runtime → Change runtime type → G4 GPU.** G4 is the NVIDIA RTX PRO 6000 Blackwell Server Edition (96 GB, sm_120,
   native bf16), per the Colab release notes of 2026‑03‑25. T4, L4, A100 and H100 are detected and handled too.
2. Open the notebook, or paste the script into a cell, and run it. Approve the Google Drive pop-up when it appears.
3. When a session ends, start a new one and run the same cells again. Training resumes from Drive.

Shell usage (mount Drive in a cell first):

```
!python sina_net_v4_colab.py --preset deblur                    # all_in_one | deblur | defocus | derain | denoise
!python sina_net_v4_colab.py --preset deblur --eval-only        # evaluation + analysis from best.pth
!python sina_net_v4_colab.py --preset deblur --training-ablation --max-session-hours 23.5
python sina_net_v4_colab.py --selftest                          # CPU, synthetic data, a few minutes
```

## What lives where

```
/content/drive/MyDrive/Datasets/<GoPro|HIDE|DPDD|Rain13K|SIDD>/   verified archives + manifest.json (downloaded ONCE)
/content/drive/MyDrive/SINA-Net-v4/models/      latest.pth, best.pth, train_log.csv, val_log.csv
/content/drive/MyDrive/SINA-Net-v4/inferences/  restored images (16-bit PNG for DPDD), results.json
/content/drive/MyDrive/SINA-Net-v4/figures/     every figure, as a grid and as single images
/content/drive/MyDrive/SINA-Net-v4/tables/      every table as .md .tex .csv .png
/content/drive/MyDrive/SINA-Net-v4/ablation/    training-ablation runs (resumable)
/content/drive/MyDrive/SINA-Net-v4/REPORT.md    all tables and a figure index on one page
/content/sina_local/                            fast local SSD: extracted datasets, tile cache, working checkpoints
```

**Why Drive holds archives, not extracted images.** About 50,000 small PNGs take hours to sync through the Drive
mount and are slow to read back. A dozen large archives upload in minutes, and each new session extracts them to the
local SSD in a few minutes. If you place extracted folders on Drive yourself, the script finds and uses them too.

**Why only `latest.pth` and `best.pth` go to Drive.** A file deleted on the Drive mount moves to the Drive Trash and
keeps counting against your quota for 30 days. So rolling snapshots stay on the local disk. The two Drive files are
refreshed every 30 minutes (`drive_sync_minutes`) and at every validation, stop, interrupt or crash.

## Batch size on large GPUs

The global batch of every stage follows Restormer's progressive schedule (64 at 128 px down to 8 at 384 px) and is
never changed. What adapts is how that batch is split into micro-batch × GPUs × gradient-accumulation steps. The
largest micro-batch that fits is used, so that accumulation is as low as possible:

1. At start-up, an eager probe measures memory for each patch size.
2. After `torch.compile`, the plan is recomputed from the measured compiled-to-eager activation-memory ratio.
   Compiled blocks keep far fewer intermediate tensors, so eager figures over-state the memory needed.
3. After `adapt_batch_after` (30) iterations of every stage, the running step's real peak memory is read. If a
   larger split of the same global batch fits within `probe_memory_fraction` (85 %), the micro-batch grows, e.g.
   32 × 2 → 64 × 1. This costs one recompilation. The measurement also refines the plan for the stages still to come.
4. Each measurement is saved to `models/compiled_caps.json`, so later sessions start with the right split. An OOM
   lowers the cap permanently, via `oom_caps.json`.

Memory left free after this is not wasted time. It only means the fixed global batch needs less than the GPU
provides; filling it would require changing the batch recipe.

## Datasets (full versions, verified)

| Folder | Content | Archive size |
|---|---|---|
| `GoPro` | train 2,103 + test 1,111 pairs | 4.1 + 2.4 GB |
| `HIDE` | test 2,025 pairs | 4.2 GB |
| `DPDD` | train 350 + val 74 + test 76 scenes (16-bit, centre/left/right views) | 11.8 + 2.6 + 2.6 GB |
| `Rain13K` | train 13,711 + Rain100H/L, Test100/1200/2800 | 1.2 + 1.4 GB |
| `SIDD` | **SIDD-Medium sRGB (all 320 pairs)** + official validation blocks (`.mat`) | 13.2 + 0.5 GB |

These are the archives the Restormer authors distribute (their `download_data.py` Google Drive IDs). The script tries
these sources in order:

1. The Hugging Face mirror `laoduanaaa/Image_Restoration_Datasets`. Its files are byte-identical to the Drive ones,
   and their sizes and sha256 were checked against the Hub metadata on 2026‑09‑28.
2. `gdown`.
3. A Drive-API server-side copy, which gets around Google Drive's "quota exceeded" error.
4. For SIDD only: the official York University server.

Every download is sha256- or md5-verified before it is used.

The first download needs about 45 GB free on Drive and roughly 60 GB free on the local disk.

## What the evaluation produces

| Output | Details |
|---|---|
| Main table | Full-resolution results under the standard protocols: RGB/uint8 for GoPro/HIDE/SIDD, Y channel for deraining, float for DPDD + MAE, plus LPIPS. Also per-image runtime, and the mean gain with a 95 % bootstrap CI. |
| Paper-style figures | Zoom-inset comparisons at the region where the model gains most, error maps on a shared scale, local-gain maps, spectra, frequency-resolved error reduction, and galleries of the best and hardest images. |
| "Confusion" matrices | Two linear probes on held-out test images: one on the analytic degradation signature, one on the learned embedding (motion blur / defocus / rain / noise / clean). Also a quality-transition matrix and a gain-by-pixel-class matrix. |
| Attention analysis | Peakedness and temperature atlases, query footprints at their true full-resolution positions, mean attention distance, homeostasis feedback and collapse rate. |
| Other internals | Wiener gains, coherence gates, degradation fingerprints, FiLM modulation, effective receptive fields. |
| Complexity | Exact parameter counts and **complete** FLOPs: every executed ATen op is counted, and any op without a costing rule is listed by name. Also memory traffic, a measured roofline, and pure eval-mode latency. All of this is given for the whole model, each main component and each operator type. |
| SOTA tables, 2021–2026 | Numbers copied from each method's own paper. Third-party values and non-comparable protocols are flagged. |
| Ablations | Paired test-time knock-outs with bootstrap CIs and Wilcoxon tests. Optionally, a training ablation where each component is removed and the model retrained from scratch. |
| Claims audit | Each novelty claim is marked SUPPORTED, NOT SUPPORTED, CONTRADICTED, INCONCLUSIVE or NOT TESTED, based on those measurements. |

## Verified here (CPU container, no GPU)

- `--selftest` runs the whole pipeline end to end on synthetic data: training, evaluation, every figure and table,
  the profiler, knock-out and training ablations, the claims audit and the report.
- Drive persistence was checked with a simulated mount: checkpoints are mirrored; a "new session" with the local disk
  wiped resumes from Drive at the exact iteration; eval-only mode loads `best.pth`.
- The download manager was run against a local HTTP server: a corrupt source is rejected by its sha256 and the next
  source is used; the archive is saved to Drive once; a later session re-extracts it from Drive; extracted folders
  already on Drive are detected.
- All ten Hugging Face archive URLs are live, with the expected sizes and sha256.

**Not verified here:** GPU execution. That covers AMP, `torch.compile` on sm_120, the micro-batch probe and the
latency numbers. The start-up compile check falls back to eager mode on any compiler error, and the crash guard does
the same after a native crash.
