# A3ESpotter V5: MLT-19 + public CJK merge, with fixes from the V4 run

`a3espotter_v5.py` is the full V4 script with the changes below. Run it the same way, as a Kaggle notebook cell or with `python a3espotter_v5.py`.

## What the V4 run showed, and what V5 changes

| Evidence (V4 logs / figures) | Diagnosis | V5 change |
|---|---|---|
| IC15 test: det H 0.764 but E2E H 0.431, while matched words have 1-NED 0.83 | Recognition loses most points, usually on 1–2 characters | Strip re-reading, a scene-word strip training stream, consensus script prior, calibrated E2E confidence threshold |
| Val CTC 1.86 vs train CTC 0.90; teacher-forced word accuracy 0.38 | The recogniser over-fits a small amount of clean data | Merged CJK data, strip stream, CTC confidence penalty |
| Vocabulary capped at 1,500 symbols | Any CJK word with one missing character dropped out of CTC | 8,000-symbol vocabulary, extended without changing the indices of existing characters (no weights lost) |
| 7 Chinese / 1 Korean / 1 Japanese predictions on all-Latin IC15; in the t-SNE they sit inside the Latin cluster | Script-head errors; the PMI prior then pushes Latin words towards CJK | Consensus script posterior and an entropy-gated prior |
| "Rejected by the text verifier: 0" | min_score=0.80 already removes everything the verifier would reject; nothing was tuned on the test domain | Held-out IC15 split; operating point calibrated on it |
| Early stopping fired one epoch after the resume | Patience was already exhausted in the checkpoint | Checked before training; a new stage warm-starts from the best checkpoint |
| Prediction figures half empty, labels unreadable | Fixed 22×5.5 in canvas, tiny labels, no ground-truth (GT) overlay | Figure sized to the image aspect, readable labels, GT colours |

## What the first V5 Kaggle run showed, and what V5.1 changes

| Evidence (V5 Kaggle log) | Diagnosis | V5.1 change |
|---|---|---|
| `62.02s/it`, `11:46:58` left for epoch 1 of 687 steps | The model ran on the **CPU**. The same step measured on a 4-core CPU here takes 40–60 s, and data loading costs only ~0.1 s per image, so it is not an input bottleneck. | The run prints its GPUs and **stops at once when no GPU is visible** (`require_gpu`, on by default on Kaggle). `cudnn.benchmark` is off, because input shapes change every step. A speed projection (s/step, data-wait share, minutes per epoch, sessions needed) is printed after 30 steps. |
| A single training process | Only one GPU can be used. | **GPU T4 x2**: one training process per GPU (details below). |
| One epoch takes 11 h; a checkpoint only at epoch end | A session can end before the first checkpoint. | **`latest_model.pth` every 20 steps** (`save_every_steps`), with the exact position in the epoch. Training stops cleanly before Kaggle's 12-h limit (`max_session_hours = 11`); the next session continues at the same step. |
| `20002 images in .../rects have several equally plausible GT files - skipped` | `ReCTS.zip` holds the same labels twice (`gt/` and `gt_unicode/`). | Duplicate annotation copies are recognised (identical boxes), and the copy whose text decodes best is used. GT files for *different* images with the same name are still skipped. |
| `Epoch 1/250`, `lr=1.09e-06` | Silent start from scratch: no V4 checkpoint was found. | A **stage banner** states resume / warm / scratch, lists the checkpoints it saw, and says how to attach the V4 output. Attached inputs are searched 7 levels deep, and the most advanced same-stage checkpoint is the one resumed. |
| ~1 h of downloads in every session | Nothing reused the finished downloads. | An attached copy of the download folder is used as is, and nothing in it is downloaded again. Attached index / hash caches are reused. |
| `[discover] no public CJK scene-text set found ...` after 8 successful downloads | Misleading message. | One line per set says where it came from (attached / found by signature / downloaded), plus the list of sets that are not available. |

**How the two GPUs are used**
- **Launch:** one process per GPU is forked from the notebook process, so it works when the script is pasted into a cell; no `torchrun` or script file is needed.
- **Data:** every process draws the same mixture sample sequence and trains on its own shard of it (positions `rank::world`), with `batch_size / world` images per GPU. Global batch, learning-rate schedule and steps per epoch are therefore the same as on one GPU.
- **Gradients:** averaged by an explicit, bucketed all-reduce after `backward`. One training step runs several forward passes (scene batch, word-strip batch), which `DistributedDataParallel` does not support.
- **Rank 0:** keeps the EMA, validates, evaluates and writes the checkpoints. The other process waits on a separate control channel, so a long evaluation cannot time out the GPU channel.
- **Crashes:** if a process dies (for example a DataLoader worker killed for memory), both are restarted from the last 20-step checkpoint.
- **Fallback:** if CUDA was already initialised by an earlier notebook cell, the GPUs cannot be used from forked processes, and the run falls back to one GPU with a message saying so.

## Datasets: downloaded automatically from the original sources

With `auto_download_sources = True` (the default), every set below is fetched from its original host on the first run.

- **Download behaviour:**
  - Downloads resume after an interruption.
  - Each file is checked against its size or MD5 where these are known, and every zip is CRC-tested.
  - An HTML login or error page is never saved as data.
  - Archives are extracted safely (no path traversal, no links), and nested zips are unpacked.
  - A `.complete` marker means a finished set is never downloaded twice.
  - The disk always keeps a reserve (`download_min_free_gb`); if space runs out, the sets at the end of `download_names` are the ones skipped.
- **Where it goes on Kaggle:** the data lands in `/tmp/a3espotter_data`. That disk is wiped between sessions. An attached copy of this folder is used as is, and sets attached in their original layout are found by file signature. Either way, nothing attached is downloaded again.

| Key | Script | Set | Original source (auto) | Notes |
|---|---|---|---|---|
| `lsvt` | zh | LSVT-19, 30k street views | Baidu CDN (organiser), HTTPS, 8.9 GB | sizes verified |
| `rects` | zh | ReCTS-19, 20k signboards | CVC/RRC `datasets.cvc.uab.es` | host's HTTPS chain fails verification → HTTP, then unverified HTTPS (`download_allow_legacy_tls`) + zip CRC |
| `kaist` | ko | KAIST Scene Text, ~3k images | IAPR-TC11 (HTTP only) | nested zips unpacked; malformed XML parsed tolerantly |
| `art` | zh + Latin | ArT-19, 5.6k images (curved) | Baidu CDN, HTTPS, 1.7 GB | sizes verified |
| `synthmlt_ja/ko/zh` | ja / ko / zh | ICDAR-2019 MLT synthetic set (E2E-MLT) | CTU `ptak.felk.cvut.cz` (HTTP only) | if unreachable, falls back to a third-party Hugging Face LMDB of its word crops (recognition only) |
| `rctw17` | zh | RCTW-17, 8k images | **none scriptable** | the HUST mirror is offline and the organisers now distribute the training set only through Baidu Pan; add direct URLs (e.g. your own copy of `train_images.zip.001/.002` + `train_gts.zip`) to `Config.custom_download_urls['rctw17']`, or attach a copy |
| IC15 (base) | Latin | ICDAR-2015 train + test | RRC, MD5-verified (the MMOCR dataset-zoo URLs) | Kaggle copy as a fallback if the RRC refuses |
| MLT-19 (base) | 10 scripts | MLT-2019 train | RRC needs a free account | your Kaggle copy is used (attached, or fetched with `kagglehub`) |

Free real-photo Japanese scene text with quad annotations is scarce beyond MLT itself. DOST needs RRC registration, and AI-Hub Korean data is only distributed inside Korea. Any extra set can be added as an explicit spec in the `icdar`/`mlt`, `rctw`, `rects`, `lsvt`, `art`, `kaist` or `paddle` format.

## Cross-check (second pass)

Four independent reviews covered the whole file (data/config, multi-source merge, model/losses/evaluation, engine/trainer/main). Every finding below was reproduced or traced, then fixed.

**Labels and targets**
- Box jitter was proportional to line *length*, so it cut 1–3 characters off long CJK lines while their full label was kept. It is now proportional to text height.
- CTC trained on words up to 15% outside the crop. The minimum visible fraction is now 98%.
- Arabic/Hebrew labels were in logical order while the RoI is read left to right. Targets now use visual order (simplified bidi), and decoding converts back.
- The E2E normaliser stripped Hindi/Bangla vowel signs, so wrong final vowels counted as correct.
- `・` (U+30FB) made Chinese lines Japanese.
- Upper-case accented letters were separate classes.
- Synthetic-only Hangul syllables were dropped from the vocabulary.

**Model and memory**
- The V4 strip-pool convolutions had swapped kernels (two-thirds of their weights dead). They are fixed, and old checkpoints are converted exactly.
- Recognition logits are assembled without scatter copies; the padding frames no longer go through softmax, and the entropy term uses a bounded subset.
- `rectify_strip` anti-aliases each axis separately.

**Data merge**
- Discovery could pick the wrong image folder: test images paired with train labels, LSVT labels on ArT photos, a missed nested folder, or a BOM-prefixed file. Folders are now chosen by key overlap, never above the search root, with test/val excluded.
- Images are paired with annotations by folder as well as name.
- A truncated or HTML download was accepted as complete.
- The index cache went stale (it now includes a file fingerprint).
- One broken label file stopped the run.
- Worker memory: the index and the crop index are numpy-backed, so forked workers share them.

**Training runs across Kaggle sessions**
- A new session silently restarted the stage instead of resuming. A same-stage checkpoint attached from the previous session (or set as `init_checkpoint`) is now copied in and resumed.
- A checkpoint cut off mid-write blocked every later run. Checkpoints are now written atomically, the best checkpoint is written before the latest, the previous latest is kept as a fallback, and unreadable files are moved aside.
- Resumed sessions replayed session 1's sample order. The samplers are now offset by epoch.
- A DataLoader worker crash poisoned the validation and strip loaders. All loaders are now rebuilt and validation/evaluation retried.
- Archived checkpoints are named after the stage stored in each file.

**Evaluation and inference**
- Validation recognition metrics were a random subsample.
- A full 1-NED (misses and false alarms count as 1) is reported next to the matched-pairs version.
- Two latent crashes are fixed: a dtype cast and a missing `detach()`.
- The attention figure showed the last strip batch's map; it now shows the whole-image pass.
- Validation losses were averaged over batches that had no such RoIs.
- Tile offsets are aligned to the network stride.
- The calibrated operating point is stored with the weights it was calibrated for (`best_model.pth`, or `final_ema_model.pth`).

## Running on Kaggle

1. **Settings → Accelerator → GPU T4 x2**, and turn Internet on. Use a fresh kernel: this cell must be the first one that uses the GPU.
2. **Warm start (strongly recommended):** attach the V4 notebook's output (*Add Input → Your Work → the V4 notebook*), or set `Config.init_checkpoint`. The stage then needs `finetune_epochs` (60) instead of 250 epochs from scratch. The banner at the start says which mode was chosen and why.
3. **Run it as a commit** (*Save Version → Save & Run All*). The run stops by itself after `max_session_hours` (11 h), after writing `outputs/models/latest_model.pth`, so the version finishes normally and its output is kept.
4. **Next session:** attach that version's output (*Add Input → this notebook → Output*) and run again. The log says `Resumed stage 'v5_cjk_merge' at epoch E, step S/687`, and training continues on the next sample of the same draw. Repeat until the stage completes; calibration on the IC15 held-out split and test inference then run automatically.
5. **Optional, to skip the ~1 h download:** upload `/tmp/a3espotter_data` as a private Kaggle dataset and attach it. It is larger than the 20 GB notebook-output limit, so this needs the Kaggle API with your token. The run detects the attached copy and downloads nothing.

The 30-step speed projection in the log shows how many sessions the stage needs. If it reports that most of the step is spent waiting for data (the GPUs share 4 CPU cores), lower `strip_batch_images`.

## What was verified here

**CPU smoke tests** ran on a synthetic data tree with one sample of every annotation format:
- training from scratch;
- resume;
- warm start from a V4-shaped checkpoint;
- strip re-reading, calibration and figures with oracle detection maps;
- the attached-checkpoint, truncated-checkpoint and worker-crash paths.

**V5.1 training-lifecycle tests.** The multi-process path ran on CPU with 2 processes over `gloo`; on Kaggle it uses `nccl` on the GPUs.
- **Exact resume, one process:** a run interrupted at step 8 of 12 and then resumed trains on exactly the same sample sequence as an uninterrupted run, in both epochs.
- **2-process training:**
  - after 24 steps both processes hold bit-identical weights;
  - each process receives exactly its half of the single-process sample sequence.
- **Stop and resume across process counts:**
  - a stop requested by one process only stops both at the same step;
  - resuming on 2 processes, or on 1, continues at sample 16 of the same draw.
- **Crash recovery:**
  - one process: a DataLoader-worker crash continues the epoch at the crashed step, with the same draw;
  - two processes: the crash restarts both processes from the step-5 checkpoint, and they end with identical weights.
- **ReCTS pairing:** the `gt/` + `gt_unicode/` layout is resolved, a mojibake copy loses to the clean one, and GT files of different images are still skipped.
- **Attached download folder:** detected, including the word-crop fallback.

**Found and fixed while testing:** the forked training processes deadlocked in their first CPU tensor copy, because GNU OpenMP's thread pool was inherited from the parent. Each training process now uses one intra-op thread, as PyTorch's DataLoader workers do.

**Downloader tests** ran against a local server:
- resume after a dropped connection;
- login-page detection and mirror fallback;
- MD5 rejection;
- nested and split archives;
- path traversal.

**Unit checks:**
- long-line CTC buckets and gradients;
- Hangul row initialisation;
- the leakage guard;
- the bidi round trip;
- exact conversion of the V4 strip-pool weights;
- the real Hugging Face SynthMLT Japanese LMDB, read through the crop dataset.

**Not verified here (no GPU in this sandbox):**
- the `nccl` run on two real T4s, and AMP;
- the actual seconds per step on a T4, and any accuracy number;
- the multi-GB downloads end to end: this sandbox's proxy blocks plain HTTP, so the HTTP-only hosts could not be tested.

The next Kaggle run's log will show the step time (the `data=` / `gpu=` fields in the progress bar and the `[speed]` line).
