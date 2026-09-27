"""End-to-end CPU smoke test of KORA v2 with TINY random models and synthetic audio.
It exercises every training phase (stage-1 with CTC warm-up + SAB + MPD, RAPL round, silver MMT, TTS on CTC
self-alignment, ablations), session-timeout resumption, the complete evaluator (heavy external baselines are
replaced by stubs), the figures and the report. Numbers are meaningless; the point is that every code path runs.
Run:  python kora/tests/smoke_test.py   (downloads only the NLLB tokenizer, the w2v-BERT feature-extractor config
and the 54 MB Vocos vocoder)."""
import os
import shutil
import sys
import tempfile

os.environ.setdefault("KORA_SKIP_INSTALL", "1")
os.environ.setdefault("KORA_ALLOW_CPU", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402
from transformers import M2M100Config, M2M100ForConditionalGeneration, Wav2Vec2BertConfig, Wav2Vec2BertModel  # noqa: E402
from transformers import Wav2Vec2Config, Wav2Vec2Model  # noqa: E402

import kora as K  # noqa: E402

SENT = {
    "ha": ["duk da haka ba za a iya", "ina son ruwa sosai", "yara suna wasa a waje", "gida ne mai kyau",
           "mun tafi kasuwa jiya", "rana tana haske", "sarki ya ce su zo", "littafi yana kan tebur"],
    "yo": ["àwọn ọmọ lefi jẹ́ mẹ́rin", "ajá kan ń sáré", "ọkùnrin kan wà níbẹ̀", "omi tútù dára",
           "a lọ sí ọjà lánàá", "oòrùn ń tàn", "ọba sọ pé kí wọ́n wá", "ìwé wà lórí tábìlì"],
    "ln": ["bato nyonso bakendaki", "mwana azali kosakana", "ndako ya kitoko", "tokendaki na zando",
           "moi ezali kongenga", "mokonzi alobaki ete bayaka", "buku ezali likolo ya mesa", "mai ezali malamu"],
    "en": ["however it cannot be used", "i like water very much", "children are playing outside", "a good house",
           "we went to the market yesterday", "the sun is shining", "the king said they should come",
           "the book is on the table"],
}


def tone(path, dur, sr, seed):
    rng = np.random.default_rng(seed)
    t = np.arange(int(dur * sr)) / sr
    w = 0.1 * np.sin(2 * np.pi * (200 + 50 * seed % 300) * t) + 0.02 * rng.standard_normal(len(t))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sf.write(path, w.astype(np.float32), sr)
    return path


def build_data(root, cfg):
    fleurs, parallel = [], {}
    for i in range(8):
        parallel[str(i)] = {l: SENT[l][i].capitalize() + "." for l in ["ha", "yo", "ln", "en"]}
    k = 0
    for lang in ["ha", "yo", "ln"]:
        for split, sids in [("train", range(0, 5)), ("dev", range(5, 7)), ("test", range(5, 8))]:
            for sid in sids:
                dur = 1.0 + 0.2 * (k % 5)
                p = tone(os.path.join(root, "fleurs", lang, split, f"{sid}.wav"), dur, 16000, k)
                fleurs.append(dict(uid=f"fleurs_{lang}_{split}_{sid}", lang=lang, split=split, audio=p, dur=dur,
                                   text=parallel[str(sid)][lang], sid=str(sid), gender="FEMALE", domain="fleurs"))
                k += 1
    bible = []
    for lang in ["ha", "yo", "ln"]:
        for split, n in [("target_dev", 2), ("target_test", 3), ("target_adapt", 6)]:
            for j in range(n):
                dur = 1.2 + 0.3 * (j % 3)
                p16 = tone(os.path.join(root, "bible", lang, split, f"{j}.flac"), dur, 16000, k)
                p24 = tone(os.path.join(root, "bible24", lang, split, f"{j}.flac"), dur, 24000, k)
                bible.append(dict(uid=f"bible_{lang}_{split}_{j}", lang=lang, split=split, audio=p16, audio24=p24,
                                  dur=dur, text=SENT[lang][j % 8], vref=f"GEN 1:{k}", en=SENT["en"][j % 8],
                                  domain="bible", orig_split="train", gold_hidden=split == "target_adapt"))
                k += 1
    bible_text = [dict(vref=f"EXO 1:{i}", **{l: SENT[l][i] for l in ["ha", "yo", "ln", "en"]}) for i in range(5)]
    havg = [dict(uid=f"havg_{s}_{i}", split=s, image=None, box=[0, 0, 5, 5], en=SENT["en"][i], ha=SENT["ha"][i])
            for s, n in [("train", 4), ("test", 3), ("challenge", 3)] for i in range(n)]
    yfacc = []
    for s, n in [("train", 4), ("dev", 2), ("test", 3)]:
        for i in range(n):
            p = tone(os.path.join(root, "yfacc", s, f"{i}.flac"), 1.5, 16000, k)
            k += 1
            yfacc.append(dict(uid=f"yfacc_{s}_{i}", split=s, audio=p, dur=1.5, lang="yo", yo=SENT["yo"][i],
                              en=SENT["en"][i], image=None, box=None, domain="yfacc", speaker="S001"))
    rows = havg + yfacc
    vis_index = {r["uid"]: i for i, r in enumerate(rows)}
    n_tok = 2 + cfg.data.vis_grid ** 2
    vp = os.path.join(root, "vis.f16")
    mm = np.memmap(vp, dtype=np.float16, mode="w+", shape=(len(rows), n_tok, cfg.model.vis_dim))
    mm[:] = np.random.default_rng(0).standard_normal(mm.shape).astype(np.float16)
    mm.flush()
    L = ["ha", "yo", "ln"]
    stats = dict(
        fleurs={l: {s: sum(1 for m in fleurs if m["lang"] == l and m["split"] == s) for s in ["train", "dev", "test"]} for l in L},
        fleurs_hours={l: 0.01 for l in L},
        bibletts={l: {s: sum(1 for m in bible if m["lang"] == l and m["split"] == s)
                      for s in ["target_dev", "target_test", "target_adapt"]} for l in L},
        bibletts_hours={l: 0.01 for l in L}, bible_test_with_english_ref={l: 3 for l in L}, ebible_mt_verses=5,
        havg={}, yfacc_real_speech={"train": 4, "dev": 2, "test": 3}, yfacc_hours=0.01, spoken_havg_synthetic={})
    return dict(fleurs=fleurs, parallel=parallel, bible=bible, bible_text=bible_text, ebible_langs=L + ["en"],
                havg=havg, yfacc=yfacc, vis_path=vp, vis_index=vis_index, spoken=[], stats=stats)


def tiny_cfg(tmp):
    cfg = K.KoraConfig(run_name="smoke")
    cfg.paths.work_root = os.path.join(tmp, "runs")
    cfg.paths.cache_dir = os.path.join(tmp, "cache")
    m, d, p, t, e = cfg.model, cfg.data, cfg.pl, cfg.train, cfg.eval
    m.speech_trainable_top_layers, m.sab_hidden, m.lora_r, m.gate_hidden, m.vis_dim = 1, 32, 4, 16, 16
    m.tts_dim, m.tts_enc_layers, m.tts_dec_blocks, m.tts_heads, m.fm_steps, m.tts_crop_frames = 32, 1, 1, 2, 2, 40
    m.mpd_top_k_layers = 2
    d.vis_grid = 1
    p.rounds, p.retention_schedule, p.beams, p.nbest, p.ctc_beam, p.pl_batch, p.text_pl_max_per_lang = 1, [0.9], 2, 2, 3, 4, 3
    t.stage1_steps, t.round_steps, t.tts_steps, t.ctc_warmup_steps, t.mpd_warmup_steps = 10, [4], 4, 2, 3
    t.max_batch_seconds, t.max_batch_utts, t.text_batch, t.tts_batch, t.grad_accum, t.num_workers = 12, 4, 4, 2, 1, 0
    t.log_every, t.eval_every, t.save_every, t.dev_eval_utts, t.kd_topk = 2, 5, 3, 6, 4
    t.ablations, t.ablation_steps = ["no_sab_anchor", "vanilla_pl"], 2
    e.max_eval_utts, e.beams, e.max_new_tokens, e.n_bootstrap, e.dev_select_utts = 4, 2, 6, 10, 4
    e.tts_eval_utts, e.s2st_eval_utts, e.rtf_utts, e.n_audio_samples, e.n_tsne_points, e.joint_lambdas = 2, 2, 3, 1, 24, [0.3, 0.7]
    cfg.paths.make()
    return cfg


def tiny_models(tok, cfg):
    nllb = M2M100ForConditionalGeneration(M2M100Config(
        vocab_size=len(tok), d_model=32, encoder_layers=1, decoder_layers=1, encoder_attention_heads=2,
        decoder_attention_heads=2, encoder_ffn_dim=64, decoder_ffn_dim=64, max_position_embeddings=256,
        scale_embedding=True, pad_token_id=1, bos_token_id=0, eos_token_id=2, decoder_start_token_id=2))
    w2v = Wav2Vec2BertModel(Wav2Vec2BertConfig(
        hidden_size=32, num_hidden_layers=2, num_attention_heads=2, intermediate_size=64,
        feature_projection_input_dim=160, conv_depthwise_kernel_size=5, mask_time_prob=0.05,
        left_max_position_embeddings=16, right_max_position_embeddings=4, output_hidden_size=32))
    return nllb, w2v


class FakeBaselines:
    def __init__(self, *a, **k):
        pass

    def release(self):
        pass

    def whisper(self, wavs, lang, task):
        return ["hello world"] * len(wavs)

    def mms_asr(self, wavs, lang):
        return [SENT[lang][i % 8] if lang in SENT else "a" for i in range(len(wavs))]

    def nllb(self, texts, src, tgt):
        return [t[::-1] for t in texts]

    def mms_tts(self, texts, lang):
        return [np.random.default_rng(0).standard_normal(24000).astype(np.float32) * 0.01 for _ in texts]


class FakeSonar:
    def __init__(self, *a, **k):
        pass

    def embed(self, texts, langs):
        g = torch.Generator().manual_seed(0)
        return torch.nn.functional.normalize(torch.randn(len(texts), 8, generator=g), dim=-1)


def main():
    tmp = tempfile.mkdtemp(prefix="kora_smoke_")
    K.setup_logger(os.path.join(tmp, "logs"))
    cfg = tiny_cfg(tmp)
    data = build_data(os.path.join(tmp, "data"), cfg)
    vis = K.VisStore(data["vis_path"], len(data["vis_index"]), 2 + cfg.data.vis_grid ** 2, cfg.model.vis_dim)
    chars = K.CharVocab.build([m["text"] for m in data["fleurs"]] + [y["yo"] for y in data["yfacc"]], min_count=1)
    tok = K.TextTok("facebook/nllb-200-distilled-600M", cfg.data.nllb_codes, 2)
    feat = K.SpeechFeaturizer("facebook/w2v-bert-2.0")
    torch.manual_seed(0)
    nllb, w2v = tiny_models(tok, cfg)
    model = K.KORA(cfg, chars, tok, nllb=nllb, speech_backbone=w2v)
    dev = torch.device("cpu")

    # ---- 1) session timeout inside stage 1, then resumption by a fresh Trainer --------------------------
    tr = K.Trainer(cfg, model, tok, chars, data, vis, feat, dev, dev)
    calls = {"n": 0}

    def flaky():
        calls["n"] += 1
        if calls["n"] == 6:
            raise K.SessionTimeout()

    tr.check_time = flaky
    try:
        tr.fit()
        raise AssertionError("expected a SessionTimeout")
    except K.SessionTimeout:
        pass
    assert tr.ckpt.latest_for_phase("stage1") is not None, "no resumable checkpoint written"
    tr = K.Trainer(cfg, model, tok, chars, data, vis, feat, dev, dev)
    tr.fit()
    for key in ["stage1_done", "round1_done", "tts_done", "silver_done", "round1_pl_done"]:
        assert tr.done(key), key
    assert model.tts.seen_conds, "TTS conditions were not recorded"
    # every task's loss (both SAB segmentation modes) runs forward + backward at least once
    recs = K.read_jsonl(os.path.join(cfg.paths.pl_dir, "pl_round1.jsonl"))
    assert recs and all(r["t_route"] in ("ctc", "aed") for r in recs)
    pl_entries, silver = tr.entries_from_pl(recs, K.VARIANTS["rapl_full"], 1.0, 1)
    tts_entries = tr.tts_entries_from_disk(tr.tts_tag())
    assert tts_entries, "no TTS entries"
    variant = K.VARIANTS["rapl_full"]
    for task in ["asr", "st", "mt", "mt_bible", "mmt", "smmt", "mpd", "pl", "tts"]:
        for greedy in ([0.0, 1.0] if task in ("asr", "st", "smmt") else [0.0]):
            tr.tc.sab_greedy_prob = greedy
            L = tr.make_loaders({task: 1.0}, pl_entries=pl_entries or [dict(e, targets={e["lang"]: "a", "en": "b"},
                                seg_text="a", ctc_text="a", domain="bible") for e in tr.speech_entries[:2]],
                                silver=silver, tts_entries=tts_entries)
            model.train()
            loss, logs = tr.compute(task, next(L[task]), variant, step=10 ** 6)
            loss.backward()
            model.zero_grad(set_to_none=True)
            print(f"task {task:8s} greedy={greedy}: loss={float(loss):.3f} parts={sorted(logs)}")
    tr.tc.sab_greedy_prob = 0.25
    abl = tr.run_ablations()
    tr.load_snapshot("final_tts.pt")
    # every phase is idempotent
    tr2 = K.Trainer(cfg, model, tok, chars, data, vis, feat, dev, dev)
    tr2.fit()

    # ---- 2) the whole evaluation with stubbed external baselines ---------------------------------------
    K.Baselines = FakeBaselines
    K.SonarEmbedder = FakeSonar
    K.UTMOS = lambda cfg, device: (lambda wav, sr: 3.0)
    tr.release_teacher()
    ev = K.Evaluator(cfg, tr, vis, dev, dev)
    ev.run_all(abl)
    R = ev.R
    for block in ["asr", "st", "mt", "mmt", "gate_analysis", "smmt", "tts", "s2st", "pl_analysis", "domain",
                  "efficiency", "significance", "ablation", "qualitative", "decoding"]:
        assert block in R and (R[block] or block == "significance"), f"missing result block {block}"
    assert R["efficiency"]["rtf"], "RTF table is empty"
    assert any(k.startswith("bible/") for k in R["st"]["KORA-mbr"]), "no Bible-domain ST"
    assert "KORA-sel" in R["asr"] and "yfacc/yo" in R["asr"]["KORA-sel"]
    viz = K.Visualizer(cfg, ev)
    viz.make_all()
    assert not viz.failed, viz.failed
    K.ReportWriter(cfg, ev.R, data["stats"], viz.failed).write()
    assert os.path.exists(os.path.join(cfg.paths.results_dir, "REPORT.md"))
    n_tab = len(os.listdir(cfg.paths.table_dir))
    n_fig = len([f for f in os.listdir(cfg.paths.fig_dir) if f.endswith(".png")])
    print(f"tables: {n_tab} files, figures: {n_fig}")

    # ---- 3) wav2vec2-family front-end (MMS) also runs through SAB and MPD --------------------------------
    w2 = Wav2Vec2Model(Wav2Vec2Config(hidden_size=32, num_hidden_layers=2, num_attention_heads=2, intermediate_size=64,
                                      conv_dim=(16, 16), conv_stride=(5, 64), conv_kernel=(10, 64),
                                      num_conv_pos_embeddings=16, num_conv_pos_embedding_groups=2,
                                      mask_time_prob=0.05, do_stable_layer_norm=True, feat_extract_norm="layer"))
    m2 = K.KORA(cfg, chars, tok, nllb=tiny_models(tok, cfg)[0], speech_backbone=w2)
    f2 = K.SpeechFeaturizer("x", kind="wav2vec2")
    x, am = f2([np.random.randn(16000).astype(np.float32), np.random.randn(24000).astype(np.float32)])
    enc = m2.encode_speech(x, am)
    seg = m2.segment(enc, ["duk da haka", "ina son"], "viterbi")
    mem, mm_, e = m2.speech_memory(enc, seg, ["ha", "ha"])
    teacher = K.EMATeacher(m2.speech, 0.999, 2, dev)
    l, _ = K.mpd_loss(m2, teacher, dict(x=x, am=am), cfg.model, dev)
    l.backward()
    print("wav2vec2 path ok:", tuple(mem.shape), float(l))
    print("SMOKE TEST PASSED", tmp)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
