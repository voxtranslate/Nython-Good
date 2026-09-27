"""LIVE data-source test (network): eBible, a capped BibleTTS stream, YFACC + Flickr8k, and the visual cache
(with a tiny random SigLIP). Run:  python kora/tests/test_datahub_live.py [--yfacc]   (YFACC streams 6.8 GB)."""
import os
import sys
import tempfile

os.environ.setdefault("KORA_SKIP_INSTALL", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import kora as K  # noqa: E402


def main():
    tmp = os.environ.get("KORA_LIVE_DIR") or tempfile.mkdtemp(prefix="kora_live_")
    K.setup_logger(os.path.join(tmp, "logs"))
    cfg = K.KoraConfig(run_name="live")
    cfg.paths.work_root, cfg.paths.cache_dir = os.path.join(tmp, "runs"), os.path.join(tmp, "cache")
    cfg.paths.make()
    d = cfg.data
    d.bibletts_max_dev_utts, d.bibletts_max_train_utts_per_lang, d.bibletts_min_test_utts = 5, 30, 60
    hub = K.DataHub(cfg)
    eb, ranges = hub.build_ebible()
    assert "Cyrus" in eb["en"]["EZR 1:2"]
    print("merged-verse lines:", {l: len(r) for l, r in ranges.items()})
    print("eBible:", {l: len(v) for l, v in eb.items()})
    d.african_langs = [a for a in sys.argv[1:] if not a.startswith("--")] or ["yo"]
    bible = hub.build_bibletts(eb, ranges)
    from collections import Counter
    print("BibleTTS yo splits:", Counter(b["split"] for b in bible))
    test = [b for b in bible if b["split"] == "target_test"]
    assert len(test) >= 60 and all(b["text"] for b in test)
    ok = [b for b in bible if b["vref"]]
    print(f"text-matched verses: {len(ok)}/{len(bible)}; file-name id wrong for "
          f"{sum(1 for b in ok if b['vref'] != b['vref_file'])}; mean score {sum(b['vref_score'] for b in ok) / max(1, len(ok)):.1f}")
    for lg in sorted({b["lang"] for b in test}):
        tl = [b for b in test if b["lang"] == lg]
        print(lg, "test clips with an English reference:", sum(1 for b in tl if b["en"]), "/", len(tl))
    assert sum(1 for b in test if b["en"]) > 0.4 * len(test), "English WEB references missing"
    assert {b["orig_split"] for b in bible if b["split"] == "target_dev"} == {"dev"}
    for b in test[:4]:
        print("example:", b["vref_file"], "->", b["vref"], "|", b["text"][:50], "|", (b["en"] or "")[:60])
    pairs = hub.bible_text_pairs(eb, ranges, bible)
    used_ch = {v.rsplit(":", 1)[0] for b in bible for v in [b["vref"], b["vref_file"]] if v}
    assert not any(p["vref"].rsplit(":", 1)[0] in used_ch for p in pairs)
    print("eBible MT verses:", len(pairs))
    # manifests are relative and reload from the cache
    again = K.DataHub(cfg).build_bibletts(eb, ranges)
    assert [b["uid"] for b in again] == [b["uid"] for b in bible] and os.path.isabs(again[0]["audio"])
    if "--yfacc" in sys.argv:
        yf = hub.build_yfacc()
        print("YFACC:", Counter(r["split"] for r in yf), yf[0]["yo"], "|", yf[0]["en"], "|", yf[0]["dur"])
        import soundfile as sf
        durs = [r["dur"] for r in yf]
        print("YFACC hours:", sum(durs) / 3600, "min/max dur", min(durs), max(durs), sf.info(yf[0]["audio"]))
        # tiny random SigLIP for the visual cache code path (box / no box)
        from transformers import SiglipVisionConfig, SiglipVisionModel
        tiny = os.path.join(tmp, "tiny_siglip")
        SiglipVisionModel(SiglipVisionConfig(hidden_size=16, intermediate_size=32, num_hidden_layers=1,
                                             num_attention_heads=2, image_size=32, patch_size=8)).save_pretrained(tiny)
        cfg.model.vision_model, cfg.model.vis_dim = tiny, 16
        rows = [dict(r) for r in yf[:5]] + [dict(yf[0], uid="boxed", box=[10, 10, 40, 30])]
        path, index = hub.build_visual_cache(rows, "cpu")
        vs = K.VisStore(path, len(index), 2 + cfg.data.vis_grid ** 2, 16)
        v, has = vs.get([0, 5, -1])
        assert has.tolist() == [True, True, False] and v.shape == (3, 18, 16)
        print("visual cache ok")
    print("LIVE DATA TEST PASSED", tmp)


if __name__ == "__main__":
    main()
