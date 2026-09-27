# KORA v2: speech, text and image translation, transcription and speech synthesis for Hausa, Yorùbá and Lingála

`kora.py` is the corrected single-file Kaggle pipeline. It keeps v1's contributions (RAPL, AMT-PL, MPD, CS-VUG and CTC self-alignment for TTS), fixes what the v1 logs showed to be broken, and replaces synthetic speech with real speech.

## 1. What went wrong in v1, and the fix

| v1 symptom (from your logs) | Root cause found in the code | v2 fix |
|---|---|---|
| Every ST output was "This is the only way to get the most out of a person's experience."; each language's AED transcripts were nearly identical; X→Y chrF++ depended only on the target column; ST loss plateaued at ≈5 vs ≈3.4 for MT | The speech memory came from a randomly initialised 2-layer bridge and went straight into the frozen NLLB decoder's cross-attention. The only link between speech and text was a mean-pooled InfoNCE term (λ=0.1). The decoder never learned to read the memory and fell back on its language-model prior. The CTC head was fine (FLEURS CER 11–30 %) | **Subword-Anchored Bridge (SAB)**, described in §2. A CTC-only warm-up runs first. Dev evaluation adds collapse detectors: output diversity and the source-sensitivity index (SSI). The best dev snapshot is kept |
| `KORA-joint` equalled `KORA-aed` to 10 decimals | `_joint_rescore` only re-ranked the AED n-best with CTC. When every AED hypothesis has collapsed, re-ranking cannot help | Real two-route decoding: the CTC prefix-beam n-best and the AED n-best are pooled and rescored with λ·log P_CTC + (1−λ)·log P_AED. The mode and λ are chosen on **dev** sets |
| `KORA-mbr` equalled `KORA-direct` | MBR pooled all hypotheses, so 4 near-identical direct n-best entries always out-voted the single cascade hypothesis | **Route-balanced MBR**: a hypothesis is scored by its agreement with the *other* routes, and every route carries the same weight |
| `KORA-cascade` was below `KORA-direct` for Hausa | The cascade was built on the collapsed AED transcripts | Cascades use the dev-selected ASR output |
| RAPL pseudo-labels had 57–100 % CER (the AED error level) | The transcript label was chosen only among AED candidates; CTC could vote but never be chosen | CTC n-best and AED n-best are both candidate routes (route-balanced) |
| TTS produced a time-invariant "mean spectrum" | At inference, TTS conditioned on domain `bible` / gender `NA`, embeddings that were **never trained**. Training used FLEURS only, because no pseudo-label reached the 0.6 score threshold (max S ≈ 0.31) | TTS trains on real studio BibleTTS speech with its gold text (adaptation split only; the ASR/ST branches never see that gold). Inference refuses conditions it has not seen. The decoder trains on random 2.7 s crops (Matcha-TTS style), with a longer schedule |
| `t17_rtf.csv` was empty | RTF timings were a side-effect of evaluation blocks that were skipped on resume | Dedicated RTF benchmark (warm-up, CUDA sync), cached once measured |
| Bible ln: WER 71 with CER 2.6 | CER was computed with **spaces removed**, which hides word-boundary errors | Standard CER (spaces count), plus `CER_nospace` as a diagnostic and `WER_ortho` (the Hausa Bible writes a breve, e.g. *yă*, that FLEURS does not) |
| Significance tests compared the collapsed `KORA-joint` | Hard-coded system name | Tests use the dev-selected decoding mode |
| "Spoken-HaVG" speech was synthetic MMS-TTS | — | Replaced by **YFACC**: 6 k real spoken Yorùbá captions of real Flickr8k images. Synthetic speech is off by default |

Other bugs fixed along the way:
- `facebook/w2v-bert-2.0` ships with `apply_spec_augment=False`, which would silently disable MPD's masking. It is now forced on.
- A missing `masked_spec_embed` is now created.
- KD top-k is taken before up-casting (avoids a 1 GB fp32 copy).
- The prefix beam search no longer lets zero-probability prefixes into the beam.
- A failing figure no longer aborts a finished evaluation.
- Pseudo-label and mel paths are re-resolved after a session import.
- BibleTTS transcripts are kept whatever their order in the archive.
- Significance tests skip (with a warning) instead of crashing when fewer than 10 predictions pair up.

**Data problem found while testing: BibleTTS file names are not reliable verse IDs.** I matched clip transcripts against the same Biblica translation in eBible:
- **All** Yorùbá clips are shifted (e.g. `COL_001_Verse_010` contains COL 1:9).
- Many Hausa clips are shifted or are *sub-verse* segments.
- Lingála clips are correct.

v2 identifies each verse by text (rapidfuzz, same book ±1 chapter). Only whole-verse clips get an English (World English Bible) reference. Every chapter that has audio is excluded from the eBible MT data.

**Corrections to my earlier reading of your logs:**
- MPD is a KL + latent-regression loss, not a 3-way classifier, so its plateau near ln 3 means nothing. MPD rises once the teacher becomes confident, which is expected.
- `normalize_text` already applied NFC to both sides and kept the dot-below in the "tone-insensitive" metric. That metric was correct.

## 2. Components (novel parts kept, improved or added)

- **SAB, Subword-Anchored Bridge (new).**
  - The model's own CTC head cuts speech into one segment per **NLLB subword**: batched GPU CTC-Viterbi on the gold transcript during training, the CTC hypothesis at test time.
  - Each segment is attention-pooled into one vector that *replaces the token embedding* at the input of the LoRA-adapted NLLB encoder, in the format `[lang] e₁…e_N </s>`.
  - Because the speech sequence is token-synchronous with the text, three position-wise losses tie the modalities together: embedding anchoring, NLLB-encoder-output matching, and top-k distillation from the model's own text route.
  - 25 % of batches are segmented by the CTC hypothesis instead of the gold alignment, so training sees the same conditions as inference.
  - Related work: CTC compression (Gaido et al. 2021), word-aligned contrastive learning WACO (Ouyang et al. 2023, external aligner), cross-modal KD (Liu et al. 2019; Tang et al. 2021).
  - SAB differs in three ways: it aligns at the *MT tokenizer's* granularity, it uses its *own* CTC, and the pooled vectors live in NLLB's frozen embedding space.
- **CTC self-alignment (kept).** Now one batched GPU Viterbi shared by SAB and the TTS durations.
- **RAPL (improved).** Route-balanced MBR; CTC and AED transcript routes; direct vs cascade translation routes.
- **AMT-PL (kept).** The alternative route is now genuinely independent of the selected label.
- **MPD (kept).** Works with w2v-BERT and wav2vec2 front-ends.
- **CS-VUG (kept).** Also trained and evaluated on *real* speech+image (YFACC).
- **Collapse diagnostics (new).**
  - SSI = chrF++ against the true references minus chrF++ against references of other inputs.
  - Also reported: output diversity.
  - Both are used during training (dev detector) and in the final tables.
- **Speech encoder.** `facebook/w2v-bert-2.0`, the SeamlessM4T-v2 encoder, far stronger for low-resource ASR than MMS-300m. Any wav2vec2-family checkpoint still works.

## 3. Data (all real speech and real images)

| Source | Used for | Licence |
|---|---|---|
| FLEURS ha/yo/ln (+en text), `google/fleurs` | ASR, many-to-many ST, text MT | CC BY 4.0 |
| BibleTTS ha/yo/ln, OpenSLR 129 (official dev/test books; test topped up with whole held-out chapters) | target-domain audio: UDA for ASR/ST, TTS voice, Bible-domain test | CC BY-SA 4.0 |
| eBible (`BibleNLP/ebible`): Biblica open ha/yo/ln, World English Bible | verse identification, Bible-domain English references, text-only target-domain MT (used chapters excluded) | CC BY-SA / public domain |
| Hausa Visual Genome (`HausaNLP/HausaVG`) | MMT en↔ha on real images | CC BY-NC-SA 4.0 |
| YFACC (`kamperh/yfacc`) + Flickr8k images (`jxie/flickr8k`) | real Yorùbá speech+image→English, MMT en↔yo, Yorùbá ASR | CC BY-SA 4.0 / Flickr8k terms |

There is no public image-grounded data for Lingála. Lingála MMT uses silver captions on HaVG's real images, as in v1. No images are generated.

## 4. Running on Kaggle

1. Notebook settings: GPU T4 ×2, Internet on. Add a `HF_TOKEN` secret if you want faster Hugging Face downloads (optional).
2. Paste `kora.py` into a cell (or `%run kora.py`). Each session stops cleanly at 11.25 h.
3. **Save Version**, attach that version's output as input to the next session, and run again. Everything resumes: data, phases, pseudo-labels, evaluation blocks.

Estimated budget on 2×T4 (not measured here, there is no GPU in this environment):

| Phase | Steps | Estimate |
|---|---|---|
| Data preparation (FLEURS, BibleTTS stream, YFACC 6.8 GB, Flickr8k, eBible, HaVG, SigLIP features) | — | ≈1–1.5 h per session (the scratch disk is wiped between sessions; attach a processed cache to skip it) |
| Stage 1 (CTC warm-up 2 k + SAB multi-task + MPD) | 16 000 | ≈9 h |
| 2 RAPL rounds (pseudo-labelling ≈1 h each + training) | 2 × 4 000 | ≈6.5 h |
| TTS (alignment + flow matching) | 40 000 | ≈2 h |
| 8 training ablations | 8 × 2 000 | ≈9 h |
| Evaluation (dev selection, all blocks, baselines) | — | ≈4 h |

That is about 30 GPU-hours, i.e. 3–4 sessions (Kaggle's weekly quota is about 30 h). To shrink the run, reduce these in `TrainConfig`: `stage1_steps`, `round_steps`, `ablations`, `ablation_steps`, `tts_steps`.

## 5. What was verified here, and what was not

Verified (CPU, this environment):
- `tests/test_algorithms.py`:
  - batched Viterbi = brute-force best path;
  - prefix beam search = exact marginals with a wide beam;
  - segmentation invariants;
  - NLLB offsets → token spans;
  - route-balanced MBR;
  - metrics.
- `tests/smoke_test.py`, with tiny random NLLB / w2v-BERT, synthetic audio and stubbed heavy baselines. It covers every training phase, including timeout → resume from a step checkpoint, forward+backward of every task in both segmentation modes, the whole evaluator, 25 figures and 24 tables. It passes on **transformers 4.46.3 and 5.17**.
- `tests/test_datahub_live.py`, against the live sources:
  - eBible;
  - BibleTTS streaming for all three languages, with verse matching;
  - the full YFACC + Flickr8k build (5 000 / 514 / 519 clips);
  - the SigLIP visual-cache code path.
- The real NLLB-600M reads SAB's `inputs_embeds` exactly like tokens (max |Δ| = 0).
- `tests/sab_learnability.py`: SAB with the real NLLB-600M on synthetic character-coded speech (see §6).

Not verified:
- **Full-scale GPU training and the final WER/BLEU/MOS numbers.** Memory and speed figures are estimates.
- The external baselines (Whisper, MMS, SONAR, UTMOS) ran only as stubs; their code is unchanged from v1 apart from inputs.

Known limits:
- There is no English TTS, so S2ST covers African↔African only.
- MMS baselines were trained on Bible recordings, so they are likely favoured on the BibleTTS domain.
- YFACC is a single speaker with 8 s padded, noisy clips.

## 6. SAB learnability check (real NLLB-600M, synthetic speech)

See `tests/sab_learnability.py`. Results are reported in the PR / chat message for this change.
