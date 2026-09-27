"""Empirical alignment audit of every paired resource KORA trains or evaluates on (network + CPU, ~30-40 min).
Pairs are checked by translating/recognising one side with an independent model and comparing the result with
its partner versus with a DERANGED partner (another item's). Correct pairing => aligned score >> shuffled score.
  text pairs  : NLLB-200-600M translation -> chrF++ against the paired text
  audio<->text: MMS-1B-all (language adapter) -> CER against the paired transcript
Usage: python kora/tests/test_data_alignment.py <live cache dir with manifests (from test_datahub_live.py --yfacc)>
                                                [<cache dir with BibleTTS for ha yo ln>] [--audio-only]"""
import json
import os
import random
import sys
from collections import Counter, defaultdict

os.environ.setdefault("KORA_SKIP_INSTALL", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import torch  # noqa: E402

import kora as K  # noqa: E402

random.seed(0)
AUDIO_ONLY = "--audio-only" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
LIVE = ARGS[0]
BIBLE = ARGS[1] if len(ARGS) > 1 else LIVE
CODES = {"ha": "hau_Latn", "yo": "yor_Latn", "ln": "lin_Latn", "en": "eng_Latn"}
tok = K.TextTok("facebook/nllb-200-distilled-600M", CODES, 2)
from transformers import AutoModelForSeq2SeqLM  # noqa: E402
nllb = None if AUDIO_ONLY else AutoModelForSeq2SeqLM.from_pretrained("facebook/nllb-200-distilled-600M").eval()
torch.set_num_threads(4)


def absolute(root, p):
    """Manifests store paths relative to the processed-cache root (DataHub.save_manifest)."""
    return p if os.path.isabs(p) else os.path.join(root, "cache", p)
REPORT = os.path.join(LIVE, "alignment_report.json")
report = json.load(open(REPORT)) if os.path.exists(REPORT) else {}


def save_report():  # after every check, so an interrupted audit keeps what it measured
    json.dump(report, open(REPORT, "w"), indent=1, ensure_ascii=False)


def translate(texts, src, tgt, bs=12):
    out = []
    for s in range(0, len(texts), bs):
        ids = K._pad_labels([tok.src(t, src) for t in texts[s:s + bs]], tok.pad_id)
        with torch.no_grad():
            g = nllb.generate(input_ids=ids, attention_mask=(ids != tok.pad_id).long(), num_beams=2,
                              forced_bos_token_id=tok.lang_ids[tgt], max_new_tokens=96)
        out += [tok.decode(x.tolist()) for x in g]
    return out


def pair_check(name, srcs, tgts, src_lang, tgt_lang, n=40):
    if AUDIO_ONLY:
        return
    idx = list(range(len(srcs)))
    random.shuffle(idx)
    idx = idx[:n]
    s, t = [srcs[i] for i in idx], [tgts[i] for i in idx]
    hyp = translate(s, src_lang, tgt_lang)
    aligned = K.chrf(t, hyp)
    shuffled = K.chrf([t[(i + 7) % len(t)] for i in range(len(t))], hyp)
    per = [K.sent_chrf(r, h) for r, h in zip(t, hyp)]
    low = sum(1 for p in per if p < 15)
    report[name] = dict(n=len(s), chrF_aligned=round(aligned, 1), chrF_shuffled=round(shuffled, 1),
                        items_below_15=low)
    save_report()
    print(f"{name:42s} aligned {aligned:5.1f} | shuffled {shuffled:5.1f} | items<15: {low}/{len(s)}", flush=True)
    worst = sorted(zip(per, s, t, hyp))[:2]
    for p, a, b, h in worst:
        print(f"     worst {p:4.1f}: SRC {a[:70]!r}\n                 REF {b[:70]!r}\n                 MT  {h[:70]!r}")
    assert aligned > shuffled + 10, f"{name}: pairs do not look aligned"


# ------------------------------------------------------------------ FLEURS n-way parallelism
cfg = K.KoraConfig(run_name="align")
cfg.paths.cache_dir = os.path.join(LIVE, "fleurs_tsv_cache")
cfg.paths.work_root = os.path.join(LIVE, "runs_align")
cfg.paths.make()
hub = K.DataHub(cfg)
rows = defaultdict(dict)
multi = Counter()
for lang, code in cfg.data.fleurs_codes.items():
    for split in ["dev", "test"]:
        with open(hub._fleurs_tsv(code, split), encoding="utf-8") as f:
            for line in f:
                v = line.rstrip("\n").split("\t")
                if len(v) < 7:
                    continue
                sid, raw = v[0], v[2].strip()
                if sid in rows[lang] and rows[lang][sid] != raw:
                    multi[lang] += 1
                rows[lang].setdefault(sid, raw)
print("FLEURS dev+test sentence ids:", {l: len(r) for l, r in rows.items()},
      "| conflicting transcripts for one id:", dict(multi))
common = sorted(set(rows["ha"]) & set(rows["yo"]) & set(rows["ln"]) & set(rows["en"]))
print("ids shared by ha, yo, ln, en:", len(common))
for l in ["ha", "yo", "ln"]:
    pair_check(f"FLEURS {l}->en (same sentence id)", [rows[l][s] for s in common], [rows["en"][s] for s in common], l, "en")
pair_check("FLEURS ha->yo (same sentence id)", [rows["ha"][s] for s in common], [rows["yo"][s] for s in common], "ha", "yo")

# ------------------------------------------------------------------ YFACC captions (yo <-> en)
yf = [json.loads(l) for l in open(os.path.join(LIVE, "cache", "manifests", "yfacc.jsonl"))]
pair_check("YFACC yo caption -> Flickr8k en caption", [r["yo"] for r in yf], [r["en"] for r in yf], "yo", "en")
caps = json.load(open(os.path.join(LIVE, "cache", "manifests", "flickr8k_captions.json")))
print("YFACC caption keys by index:", Counter(r["flickr_key"].split("#")[1] for r in yf))

# ------------------------------------------------------------------ eBible MT pairs
eb = json.load(open(os.path.join(BIBLE, "cache", "manifests", "ebible.json")))
rg = json.load(open(os.path.join(BIBLE, "cache", "manifests", "ebible_ranges.json")))
bible = [json.loads(l) for l in open(os.path.join(BIBLE, "cache", "manifests", "bibletts.jsonl"))]
cfg2 = K.KoraConfig(run_name="align2")
cfg2.paths.cache_dir, cfg2.paths.work_root = os.path.join(BIBLE, "cache"), os.path.join(BIBLE, "runs")
pairs = K.DataHub(cfg2).bible_text_pairs(eb, rg, bible)
for l in ["ha", "yo", "ln"]:
    P = [p for p in pairs if l in p and "en" in p]
    pair_check(f"eBible {l}->en MT pairs", [p[l] for p in P], [p["en"] for p in P], l, "en")

# ------------------------------------------------------------------ BibleTTS transcripts -> WEB English refs
for l in ["ha", "yo", "ln"]:
    B = [b for b in bible if b["lang"] == l and b["en"]]
    if len(B) >= 20:
        pair_check(f"BibleTTS {l} transcript -> WEB ref", [b["text"] for b in B], [b["en"] for b in B], l, "en")

# ------------------------------------------------------------------ audio <-> transcript (MMS-1B-all)
from transformers import AutoProcessor, Wav2Vec2ForCTC  # noqa: E402
proc = AutoProcessor.from_pretrained("facebook/mms-1b-all")
mms = Wav2Vec2ForCTC.from_pretrained("facebook/mms-1b-all").eval()


def mms_asr(paths, code):
    proc.tokenizer.set_target_lang(code)
    mms.load_adapter(code)
    out = []
    for p in paths:
        w = K.load_audio(p, 16000)
        inp = proc.feature_extractor(w, sampling_rate=16000, return_tensors="pt")
        with torch.no_grad():
            lg = mms(inp["input_values"]).logits
        out.append(proc.tokenizer.decode(lg.argmax(-1)[0].tolist()))
    return out


def audio_check(name, items, code, n=8):
    items = random.sample(items, min(n, len(items)))
    hyp = mms_asr([r["audio"] for r in items], code)
    refs = [r["text"] for r in items]
    aligned = K.cer(refs, hyp)
    shuffled = K.cer([refs[(i + 3) % len(refs)] for i in range(len(refs))], hyp)
    report[name] = dict(n=len(items), CER_aligned=round(aligned, 1), CER_shuffled=round(shuffled, 1))
    save_report()
    print(f"{name:42s} CER aligned {aligned:5.1f} | shuffled {shuffled:5.1f}", flush=True)
    print(f"     e.g. REF {refs[0][:70]!r}\n          MMS {hyp[0][:70]!r}")
    assert aligned < shuffled - 15, f"{name}: audio and transcripts do not look paired"


audio_check("YFACC audio <-> Yorùbá caption", [dict(audio=absolute(LIVE, r["audio"]), text=r["yo"]) for r in yf], "yor")
for l, code in [("ha", "hau"), ("yo", "yor"), ("ln", "lin")]:
    audio_check(f"BibleTTS {l} audio <-> transcript",
                [dict(audio=absolute(BIBLE, b["audio"]), text=b["text"]) for b in bible if b["lang"] == l and b["text"]],
                code)
print("ALIGNMENT AUDIT PASSED")
