# A3ESpotter V5: MLT-19 + public CJK merge, with fixes from the V4 run

`a3espotter_v5.py` is the full V4 script with the changes below. Run it the same way, as a Kaggle notebook cell or with `python a3espotter_v5.py`.

## What the V4 run showed, and what V5 changes

| Evidence (V4 logs / figures) | Diagnosis | V5 change |
|---|---|---|
| IC15 test: det H 0.764 but E2E H 0.431, while matched words have 1-NED 0.83 | Recognition loses most points, usually on 1–2 characters | Strip re-reading (described below), scene-word strip training stream, consensus script prior, calibrated E2E confidence threshold |
| Val CTC 1.86 vs train CTC 0.90; teacher-forced word accuracy 0.38 | The recogniser over-fits a small amount of clean data | Merged CJK data, strip stream, CTC confidence penalty |
| Vocabulary capped at 1,500 symbols | Any CJK word with one missing character dropped out of CTC | 8,000-symbol vocabulary, extended without changing the indices of existing characters (no weights lost); new rows initialised from characters that share Unicode components |
| 7 Chinese / 1 Korean / 1 Japanese predictions on all-Latin IC15; in the t-SNE they sit inside the Latin cluster | Script-head errors; the PMI prior then pushes Latin words towards CJK | Consensus script posterior (script head × script implied by the CTC posteriors) and an entropy-gated prior |
| "Rejected by the text verifier: 0" | min_score=0.80 already removes everything the verifier would reject; nothing was tuned on the test domain | Held-out IC15 split; operating point (input size, min_score, verifier threshold, read policy, E2E confidence) calibrated on it |
| Early stopping fired one epoch after the resume | Patience was already exhausted in the checkpoint | Checked before training; a new stage warm-starts from the best checkpoint with a fresh schedule |
| `gn=12.2`, `grad_clip=10` | Nearly every step is clipped | Clip value kept; the clipped fraction is now logged and plotted |
| (code review) | Lines longer than `max_seq_len` were truncated but still trained CTC; the crop stream masked out the right part of every word | Both fixed; CTC-infeasible and strongly curved targets are excluded |
| Prediction figures half empty, labels unreadable | Fixed 22×5.5 in canvas, tiny cv2 labels, no ground-truth (GT) overlay | Figure sized to the image aspect, readable labels, GT colours (correct / wrong text / false positive / missed / don't-care) |

## Public Chinese / Japanese / Korean sources (`PUBLIC_SOURCE_CATALOG`)

All sources match MLT's characteristics: natural scenes, multi-oriented quadrilateral or polygon boxes, transcriptions, and `###`/illegible don't-care regions. Check each licence before use. RRC pages need a free account.

| Key | Script | Set | Format read by V5 | Direct link |
|---|---|---|---|---|
| `rctw17` | zh | RCTW-17, 8k images | `x1..y4,difficult,"text"` per image | manual: rctw.vlrlab.net/dataset.html |
| `rects` | zh | ReCTS-19, 20k signboards | per-image JSON `lines[]` | datasets.cvc.uab.es/rrc/ReCTS.zip |
| `lsvt` | zh | LSVT-19, 30k street views | one JSON, polygons | dataset-bj.cdn.bcebos.com/lsvt/… |
| `art` | zh + Latin | ArT-19, 5.6k images (curved) | one JSON, polygons + `language` | dataset-bj.cdn.bcebos.com/art/… |
| `kaist` | ko | KAIST Scene Text, ~3k images | XML word boxes + characters | iapr-tc11.org/dataset/KAIST_SceneText/KAIST_all.zip |
| `synthmlt_{zh,ja,ko}` | zh / ja / ko | ICDAR-2019 MLT synthetic set (E2E-MLT) | MLT txt, vertex order auto-repaired | ptak.felk.cvut.cz/public_datasets/SyntText/… |

Free real-photo Japanese scene text with quad annotations is scarce beyond MLT itself. DOST needs RRC registration, and AI-Hub Korean data is only distributed inside Korea. Any extra set can be added as an explicit spec in the `icdar`/`mlt`, `rctw`, `rects`, `lsvt`, `art`, `kaist` or `paddle` format.

## Running on Kaggle

1. Attach the V4 notebook output, so `best_model.pth` is found under `/kaggle/input`, or set `init_checkpoint`.
2. Attach any of the sets above as Kaggle datasets. They are found by file signature, so dataset slugs don't matter. Alternatively, enable Internet and set `auto_download_sources = True`; this downloads several GB to `/kaggle/tmp`.
3. Run. The log prints the discovered sources, the merged per-source sampling shares, and the vocabulary extension. Stage `v5_cjk_merge` then fine-tunes for `finetune_epochs` (60) at `finetune_lr`. After training, the operating point is calibrated on the IC15 held-out split, and IC15 test inference runs with it.

## What was verified here

CPU smoke tests ran on a synthetic data tree that has one sample of every annotation format:
- training from scratch;
- resume;
- warm start from a V4-shaped checkpoint with a smaller vocabulary;
- strip re-reading, calibration and figures with oracle detection maps;
- unit checks for the long-line CTC buckets and gradients, Hangul row initialisation, the leakage guard, safe archive extraction, the sampler and the parsers.

Not verified here: a GPU / AMP run, real dataset downloads, and any accuracy number. The first Kaggle run is the real test.
