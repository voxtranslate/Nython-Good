"""Learnability check of the Subword-Anchored Bridge with the REAL NLLB-200-600M (CPU, ~20 min).
Synthetic "speech": every character of a real Hausa Bible verse becomes 3-5 noisy frames of a fixed random
160-d vector, so a tiny w2v-BERT can learn CTC quickly. After a CTC warm-up, the model is trained on
Hausa->English (World English Bible) through SAB exactly as in KORA (CE + anchoring + encoder matching + KD).
On held-out verses we measure whether direct speech translation carries source information (SSI, distinct
outputs) and how close it gets to the text route (NLLB translating the gold transcript).
Run: python kora/tests/sab_learnability.py <path to ebible.json> [--no-anchor]"""
import json
import os
import random
import sys
import time
from types import SimpleNamespace

os.environ.setdefault("KORA_SKIP_INSTALL", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import numpy as np  # noqa: E402
import torch  # noqa: E402
from transformers import AutoModelForSeq2SeqLM, Wav2Vec2BertConfig, Wav2Vec2BertModel  # noqa: E402

import kora as K  # noqa: E402

torch.manual_seed(0)
random.seed(0)
np.random.seed(0)
eb = json.load(open(sys.argv[1]))
anchor = "--no-anchor" not in sys.argv
pairs = [(K.ctc_text(eb["ha"][v]), eb["en"][v]) for v in sorted(eb["ha"]) if v in eb["en"]]
pairs = [p for p in pairs if 25 <= len(p[0]) <= 70 and len(p[1]) <= 90]
random.shuffle(pairs)
train, test = pairs[:600], pairs[600:640]
chars = K.CharVocab.build([p[0] for p in pairs], min_count=1)
rng = np.random.default_rng(0)
proto = rng.standard_normal((len(chars), 160)).astype(np.float32)


def speech(text):
    frames = []
    for i in chars.encode(text):
        for _ in range(rng.integers(3, 6)):
            frames.append(proto[i] + 0.3 * rng.standard_normal(160).astype(np.float32))
    return np.stack(frames)


cfg = K.KoraConfig(run_name="sab")
m_, t_ = cfg.model, cfg.train
m_.speech_trainable_top_layers, m_.sab_hidden, m_.lora_r, m_.grad_checkpointing, m_.speech_layerdrop = 3, 256, 8, False, 0.0
tok = K.TextTok("facebook/nllb-200-distilled-600M", cfg.data.nllb_codes, 2)
nllb = AutoModelForSeq2SeqLM.from_pretrained("facebook/nllb-200-distilled-600M")
w2v = Wav2Vec2BertModel(Wav2Vec2BertConfig(hidden_size=128, num_hidden_layers=3, num_attention_heads=4, intermediate_size=256,
                                           feature_projection_input_dim=160, conv_depthwise_kernel_size=5,
                                           mask_time_prob=0.0, left_max_position_embeddings=32,
                                           right_max_position_embeddings=8, output_hidden_size=128))
model = K.KORA(cfg, chars, tok, nllb=nllb, speech_backbone=w2v)
for p in model.speech.w2v.feature_projection.parameters():
    p.requires_grad = True   # random tiny encoder: train everything
col = K.Collator(tok, chars, None, None)
fake = SimpleNamespace(model=model, tc=t_, device=torch.device("cpu"), tok=tok)
t_.sab_greedy_prob, t_.kd_topk = 0.25, 16
variant = K.Variant("sab", sab_anchor=anchor)
opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=5e-4)


def batch_of(items):
    feats = [speech(s) for s, _ in items]
    T = max(len(f) for f in feats)
    x = torch.zeros(len(feats), T, 160)
    am = torch.zeros(len(feats), T, dtype=torch.long)
    for i, f in enumerate(feats):
        x[i, :len(f)] = torch.from_numpy(f)
        am[i, :len(f)] = 1
    lab, dec_in, tw = col._targets([e for _, e in items], ["en"] * len(items), [None] * len(items))
    ctc = [chars.encode(s) for s, _ in items]
    return dict(x=x, am=am, labels=lab, decoder_input_ids=dec_in, tok_weights=tw, src_lang=["ha"] * len(items),
                tgt_lang=["en"] * len(items), sample_weight=torch.ones(len(items)), seg_text=[s for s, _ in items],
                ctc_targets=K._pad_labels(ctc, 0), ctc_lengths=torch.tensor([len(c) for c in ctc]))


t0 = time.time()
for step in range(500):
    model.train()
    b = batch_of(random.sample(train, 8))
    enc = model.encode_speech(b["x"], b["am"])
    parts = {"ctc": K.Trainer._ctc_loss(fake, enc, b)}
    if step >= 150:
        K.Trainer._speech_seq(fake, "st", b, variant, enc, parts)
    loss = sum(v for k, v in parts.items() if not k.startswith("_"))
    opt.zero_grad()
    loss.backward()
    torch.nn.utils.clip_grad_norm_([p for p in model.parameters() if p.requires_grad], 1.0)
    opt.step()
    if step % 50 == 0 or step == 499:
        print(step, f"{time.time() - t0:.0f}s", {k: round(float(v), 3) for k, v in parts.items()}, flush=True)

model.eval()
feat = lambda wavs: (None, None)
refs, hyps, casc, ctc_h = [], [], [], []
with torch.no_grad():
    for s in range(0, len(test), 8):
        items = test[s:s + 8]
        b = batch_of(items)
        enc = model.encode_speech(b["x"], b["am"])
        arg = enc["ctc_logits"].argmax(-1)
        lens = enc["fmask"].sum(1)
        ctc_h += [chars.decode_ctc(arg[i, :lens[i]].tolist()) for i in range(len(items))]
        seg = model.segment(enc, None, "greedy")
        mem, mm, _ = model.speech_memory(enc, seg, ["ha"] * len(items))
        hyps += [h[0] for h in model.generate(mem, mm, ["en"] * len(items), beams=4, max_new_tokens=60)[0]]
        ids = K._pad_labels([tok.src(t, "ha") for t, _ in items], tok.pad_id)
        tm = model.encode_text(ids, (ids != tok.pad_id).long())
        casc += [h[0] for h in model.generate(tm, (ids != tok.pad_id).long(), ["en"] * len(items), beams=4, max_new_tokens=60)[0]]
        refs += [e for _, e in items]
print("variant:", "SAB + anchoring/enc-match/KD" if anchor else "SAB, CE only")
print("CTC CER on held-out:", round(K.cer([s for s, _ in test], ctc_h), 2))
print("direct ST  chrF++", round(K.chrf(refs, hyps), 2), "SSI", round(K.source_sensitivity(refs, hyps), 2),
      "distinct", K.distinct_ratio(hyps))
print("text route chrF++", round(K.chrf(refs, casc), 2), "SSI", round(K.source_sensitivity(refs, casc), 2))
print("agreement direct vs text route (chrF++):", round(K.chrf(casc, hyps), 2))
for i in range(4):
    print("REF:", refs[i], "\n  TXT:", casc[i], "\n  SAB:", hyps[i])
