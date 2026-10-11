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

## Datasets: downloaded automatically from the original sources

With `auto_download_sources = True` (the default), every set below is fetched from its original host on the first run.

- **Download behaviour:**
  - Downloads resume after an interruption.
  - Each file is checked against its size or MD5 where these are known, and every zip is CRC-tested.
  - An HTML login or error page is never saved as data.
  - Archives are extracted safely (no path traversal, no links), and nested zips are unpacked.
  - A `.complete` marker means a finished set is never downloaded twice.
  - The disk always keeps a reserve (`download_min_free_gb`); if space runs out, the sets at the end of `download_names` are the ones skipped.
- **Where it goes on Kaggle:** the data lands in `/tmp/a3espotter_data`. That disk is wiped between sessions, so save the folder as a Kaggle dataset and attach it to skip the download next time. Attached copies are found by file signature.

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

Four independent reviews covered the whole file. Every finding below was reproduced or traced, then fixed.

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

**Evaluation and inference**
- Validation recognition metrics were a random subsample.
- A full 1-NED (misses and false alarms count as 1) is reported next to the matched-pairs version.
- Two latent crashes are fixed: a dtype cast and a missing `detach()`.

## Running on Kaggle

1. Attach the V4 notebook output so that `best_model.pth` is found under `/kaggle/input`, or set `init_checkpoint`.
2. Enable Internet, then run. The log prints:
   - the download progress;
   - the discovered sources;
   - each source's share of the training mix;
   - the vocabulary extension.
3. Stage `v5_cjk_merge` then fine-tunes for `finetune_epochs` (60). After that, the operating point is calibrated on the IC15 held-out split, and IC15 test inference runs with it.

## What was verified here

**CPU smoke tests** ran on a synthetic data tree with one sample of every annotation format:
- training from scratch;
- resume;
- warm start from a V4-shaped checkpoint;
- strip re-reading, calibration and figures with oracle detection maps.

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

**Not verified here:**
- a GPU/AMP run and any accuracy number;
- the multi-GB downloads end to end: this sandbox can reach Baidu's CDN and Hugging Face, but its proxy blocks plain HTTP, so the HTTP-only hosts could not be tested.

The first Kaggle run is the real test.
