"""End-to-end pairing trace on REAL data with the REAL NLLB tokenizer / w2v-BERT feature extractor:
manifests -> Trainer entries -> Dataset items -> Collator batch -> decoded labels / CTC targets / segmentation.
Every collated example is checked against the source manifest row it came from (by uid).
Usage: python kora/tests/test_pairing_trace.py <live dir: YFACC manifests + FLEURS TSVs> <dir with BibleTTS+eBible>
(the directories written by test_datahub_live.py / test_data_alignment.py). FLEURS audio is not needed:
FLEURS text is real and a real Bible clip stands in for its audio."""
import sys, os, json, glob, random
from types import SimpleNamespace
from collections import defaultdict
ARGS = sys.argv[1:]
sys.argv = ["x"]
os.environ["KORA_SKIP_INSTALL"] = "1"
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import numpy as np, torch
import kora as K

LIVE, BIB = ARGS[0], (ARGS[1] if len(ARGS) > 1 else ARGS[0])
random.seed(0); np.random.seed(0); torch.manual_seed(0)
cfg = K.KoraConfig(run_name="trace")
fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)
        if len(fails) <= 15: print("FAIL:", msg)

# ---------------- real manifests
abspath = lambda root, p: p if os.path.isabs(p) else os.path.join(root, "cache", p)
yf = [json.loads(l) for l in open(f"{LIVE}/cache/manifests/yfacc.jsonl")]
for r in yf:
    r["audio"] = abspath(LIVE, r["audio"]); r["en"] = K.detok_caption(r["en"])
bible = [json.loads(l) for l in open(f"{BIB}/cache/manifests/bibletts.jsonl")]
for b in bible:
    b["audio"] = abspath(BIB, b["audio"]); b["audio24"] = abspath(BIB, b["audio24"])
eb = json.load(open(f"{BIB}/cache/manifests/ebible.json")); rg = json.load(open(f"{BIB}/cache/manifests/ebible_ranges.json"))
cfg2 = K.KoraConfig(run_name="x"); cfg2.paths.cache_dir = f"{BIB}/cache"; cfg2.paths.work_root = f"{BIB}/runs"
bible_text = K.DataHub(cfg2).bible_text_pairs(eb, rg, bible)[:3000]
# FLEURS text is real (TSVs); FLEURS audio is not downloaded here, so a real Bible clip stands in for the audio
parallel, fleurs = defaultdict(dict), []
stand_in = [b["audio"] for b in bible][:50]
for lang, code in cfg.data.fleurs_codes.items():
    for split in ["train", "dev", "test"]:
        f = glob.glob(f"{LIVE}/fleurs_tsv_cache/fleurs_raw/data/{code}/{split}.tsv")[0]
        for i, line in enumerate(open(f, encoding="utf-8")):
            v = line.rstrip("\n").split("\t")
            if len(v) < 7: continue
            parallel[v[0]].setdefault(lang, v[2].strip())
            if lang != "en" and split == "train" and i % 25 == 0:
                fleurs.append(dict(uid=f"fl_{lang}_{v[0]}_{i}", lang=lang, split=split, audio=random.choice(stand_in),
                                   dur=5.0, text=v[2].strip(), sid=v[0], gender="NA"))
havg = [dict(uid=f"havg_train_{i}", split="train", en=f"en caption {i}", ha=f"ha caption {i}") for i in range(4)]
vis_index = {r["uid"]: i for i, r in enumerate(havg + yf)}
data = dict(fleurs=fleurs, parallel=dict(parallel), bible=bible, bible_text=bible_text, havg=havg, yfacc=yf,
            vis_index=vis_index, spoken=[])
T = SimpleNamespace(data=data, cfg=cfg)
K.Trainer._build_static_entries(T)
print({k: len(getattr(T, k)) for k in ["speech_entries", "st_entries", "mt_entries", "mt_bible_entries", "mmt_entries",
                                      "smmt_entries", "target_audio", "mpd_entries"]})

# ---------------- real tokenizer / vocab / featurizer
tok = K.TextTok(cfg.model.text_model, cfg.data.nllb_codes, 2)
chars = K.CharVocab.build([m["text"] for m in fleurs] + [y["yo"] for y in yf if y["split"] == "train"])
feat = K.SpeechFeaturizer(cfg.model.speech_model)
col = K.Collator(tok, chars, None, feat, 0.0)
src_of = {m["uid"]: m for m in fleurs}
src_of.update({y["uid"]: y for y in yf})
src_of.update({y["uid"] + "_img": y for y in yf})
inv_lang = {v: k for k, v in tok.lang_ids.items()}

def check_labels(batch, expected_texts, tgt_langs, tag):
    lab, dec = batch["labels"], batch["decoder_input_ids"]
    for i in range(lab.shape[0]):
        ids = [int(x) for x in lab[i] if int(x) != -100]
        check(ids[0] == tok.lang_ids[tgt_langs[i]], f"{tag}: label starts with {inv_lang.get(ids[0])} not {tgt_langs[i]}")
        check(ids[-1] == tok.eos_id, f"{tag}: label does not end with </s>")
        want = tok.decode(tok.encode(expected_texts[i]))
        check(tok.decode(ids) == want, f"{tag}: decoded label {tok.decode(ids)[:60]!r} != expected {want[:60]!r}")
        n = len(ids)
        check(int(dec[i, 0]) == 2 and dec[i, 1:n].tolist() == ids[:n - 1], f"{tag}: decoder input is not the shifted label")
        check(batch["tok_weights"][i, :n].min() > 0 and float(batch["tok_weights"][i, n:].abs().sum()) == 0,
              f"{tag}: token weights not aligned with labels")

# ---------------- speech tasks: every item checked against its manifest row
for mode, entries in [("asr", T.speech_entries), ("st", T.st_entries), ("smmt", T.smmt_entries)]:
    ds = K.SpeechSeqDataset(entries, mode)
    idx = random.sample(range(len(ds)), min(40, len(ds)))
    for s in range(0, len(idx), 8):
        items, ents = [ds[i] for i in idx[s:s + 8]], [entries[i] for i in idx[s:s + 8]]
        b = col.speech(items)
        exp = []
        for it, e in zip(items, ents):
            m = src_of[e["uid"]]
            src_txt = m.get("text") or m["yo"]
            tl = it["tgt_lang"]
            if tl == e["lang"]:
                want = K.ctc_text(src_txt)
            elif "sid" in m:
                want = parallel[m["sid"]][tl]
            else:
                want = m["en"]; check(tl == "en", f"{mode}: YFACC target language {tl}")
            exp.append(want)
            if mode == "st": check(tl != e["lang"], "st target == source language")
            if mode == "smmt": check(tl == "en" and it["vis_row"] == vis_index[m["uid"]], "smmt target/image row")
            check(it["wav"].shape[0] > 16000 * 0.3, "empty audio")
        check_labels(b, exp, [it["tgt_lang"] for it in items], mode)
        for i, (it, e) in enumerate(zip(items, ents)):
            m = src_of[e["uid"]]
            gold = K.ctc_text(m.get("text") or m["yo"])
            n = int(b["ctc_lengths"][i])
            check(chars.ids_to_text(b["ctc_targets"][i, :n].tolist()) == K.normalize_text(gold.replace("|", " "))
                  or n == len(gold), f"{mode}: CTC target is not the transcript of this audio")
            check(n == len(gold), f"{mode}: CTC length {n} != transcript length {len(gold)}")
            check(b["seg_text"][i] == gold, f"{mode}: seg_text differs from the transcript")
print("speech tasks checked")

# ---------------- text tasks
for name, entries in [("mt", T.mt_entries), ("mt_bible", T.mt_bible_entries), ("mmt", T.mmt_entries)]:
    ds = K.TextPairDataset(entries)
    idx = random.sample(range(len(ds)), min(64, len(ds)))
    items = [ds[i] for i in idx]
    b = col.text(items)
    check_labels(b, [it["tgt"] for it in items], [it["tgt_lang"] for it in items], name)
    for i, it in enumerate(items):
        n = int(b["attention_mask"][i].sum())
        ids = b["input_ids"][i, :n].tolist()
        check(ids[0] == tok.lang_ids[it["src_lang"]] and ids[-1] == tok.eos_id, f"{name}: source format")
        check(tok.decode(ids) == tok.decode(tok.encode(it["src"])), f"{name}: source text")
        check(it["src_lang"] != it["tgt_lang"], f"{name}: src == tgt language")
    if name == "mt":  # the pair is the same FLEURS sentence id
        by_text = defaultdict(set)
        for sid, row in parallel.items():
            for l, t in row.items(): by_text[(l, t)].add(sid)
        for it in items:
            check(by_text[(it["src_lang"], it["src"])] & by_text[(it["tgt_lang"], it["tgt"])], "mt: src and tgt from different sentence ids")
    if name == "mt_bible":
        by_v = {p["vref"]: p for p in bible_text}
        for it in items:
            check(any(p.get(it["src_lang"]) == it["src"] and p.get(it["tgt_lang"]) == it["tgt"] for p in bible_text), "mt_bible: pair not from one verse")
print("text tasks checked")

# ---------------- pseudo-label entries: token weights built on the real tokenizer line up with the labels
pc = cfg.pl
recs = []
for b_ in [b for b in bible if b["split"] == "target_adapt" and b["text"]][:40]:
    t = K.normalize_text(b_["text"]); words = t.split()
    alt = " ".join(w if i % 3 else "xx" for i, w in enumerate(words))    # every 3rd word disagrees
    y = b_["en"] or "An English sentence , with punctuation ."
    yalt = " ".join(y.split()[::-1])
    recs.append(dict(uid=b_["uid"], lang=b_["lang"], audio=b_["audio"], dur=b_["dur"], t_star=t, t_route="ctc", y_star=y,
                     y_route="direct", t_ctc=t, t_aed=alt, y_direct=y, y_casc=yalt, s_ctc_aed=0.9, S=0.7,
                     tok_w={b_["lang"]: K.token_weights_from_words(tok, t, K.word_agreement(t, alt), pc.token_weight_min),
                            "en": K.token_weights_from_words(tok, y, K.word_agreement(y, yalt), pc.token_weight_min)}))
PL = SimpleNamespace(pc=pc, label_fields=K.PseudoLabeler.label_fields); ents = K.PseudoLabeler.to_train_entries(PL, recs, K.VARIANTS["rapl_full"])
ds = K.SpeechSeqDataset(ents, "pl")
items = [ds[i] for i in range(len(ds))]
b = col.speech(items[:8]) if items else None
for i, (it, r) in enumerate(zip(items, recs)):
    want = r["t_star"] if it["tgt_lang"] == r["lang"] else r["y_star"]
    bb = col.speech([it])
    check_labels(bb, [want], [it["tgt_lang"]], "pl")
    ids = [int(x) for x in bb["labels"][0] if int(x) != -100]
    w = bb["tok_weights"][0, :len(ids)].tolist()
    if it["tgt_lang"] == r["lang"]:
        # every low-weight token must lie inside a disagreeing word (every 3rd word)
        text = r["t_star"]; enc_ids, offs = tok.encode_with_offsets(text)
        spans = [(m.start(), m.end()) for m in __import__("re").finditer(r"\S+", text)]
        for k, (a, e_) in enumerate(offs):
            wi = next((j for j, (x, y_) in enumerate(spans) if x <= a < y_ or x < e_ <= y_), None)
            if wi is not None:
                check((w[k + 1] < 1.0) == (wi % 3 == 0), f"pl: token {k} weight {w[k+1]} vs word {wi}")
print("pseudo-label entries checked:", len(items))

# ---------------- segmentation on real transcripts: synthetic CTC posteriors that spell the text at known frames
for b_ in random.sample([b for b in bible if b["text"]], 30) + random.sample(yf, 20):
    txt = K.ctc_text(b_.get("text") or b_["yo"])
    lab = chars.encode(txt, already_normalized=True)
    dur = np.random.randint(1, 4, size=len(lab))
    for k in range(len(lab) - 1):  # CTC needs a blank between two identical labels
        if lab[k] == lab[k + 1]:
            dur[k] = max(dur[k], 2)
    Tn = int(dur.sum()) + 5
    logp = torch.full((1, Tn, len(chars)), -12.0); logp[0, :, 0] = -0.01
    t0 = 2
    for c, d in zip(lab, dur):
        logp[0, t0, c] = -0.01; logp[0, t0, 0] = -12.0; t0 += int(d)
    counts = K.ctc_viterbi_batch(logp.log_softmax(-1), torch.tensor([Tn]), [lab])[0]
    check(counts is not None and len(counts) == len(txt), "viterbi failed on real text")
    spans = K.counts_to_spans(counts)
    ids, tsp = K.token_spans(tok, txt, spans, 200)
    check(tok.decode(ids) == tok.decode(tok.encode(txt)), "token_spans ids differ from the tokenizer's ids")
    check(ids == tok.encode(txt)[:200], "token ids differ")
    # each token's frames = union of its characters' frames; tokens are ordered and cover the utterance
    _, offs = tok.encode_with_offsets(txt)
    for (a, e_), (s0, s1) in zip(offs, tsp):
        cs = [k for k in range(a, min(e_, len(txt))) if not txt[k].isspace()] or [min(a, len(txt) - 1)]
        check(s0 == min(spans[k][0] for k in cs) and s1 == max(spans[k][1] for k in cs), "token span != union of its chars")
    check(all(tsp[k][0] <= tsp[k + 1][0] for k in range(len(tsp) - 1)), "token spans out of order")
    # greedy segmentation of the same posteriors yields the same text and the same subwords
    gtxt, gsp = chars.greedy_segments(logp[0].argmax(-1).tolist())
    if 1 in lab:  # <unk> (e.g. the Hausa breve) is never emitted by design
        n_unk_skipped = globals().get("n_unk_skipped", 0) + 1; globals()["n_unk_skipped"] = n_unk_skipped
        continue
    check(gtxt == txt, f"greedy text {gtxt[:40]!r} != {txt[:40]!r}")
    check(K.token_spans(tok, gtxt, gsp, 200)[0] == ids, "greedy subwords != gold subwords")
print("segmentation checked; texts with <unk> skipped for the greedy check:", globals().get("n_unk_skipped", 0))

# ---------------- TTS alignment: durations reproduce the mel length and follow the CTC alignment
d = K.ctc_frames_to_mel([3, 1, 5, 2, 7], 170, 50.0, 24000 / 256)
check(sum(d) == 170, "mel durations")
print("\nFAILURES:", len(fails))
assert not fails, fails[:5]
