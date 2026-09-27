"""Unit tests for KORA v2's decoding / alignment algorithms (CPU, no model downloads except the NLLB tokenizer).
Run:  KORA_SKIP_INSTALL=1 python -m pytest -q kora/tests/test_algorithms.py   (or python this_file.py)"""
import itertools
import os
import sys

import numpy as np
import torch

os.environ.setdefault("KORA_SKIP_INSTALL", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import kora as K  # noqa: E402


def _collapse(path, blank=0):
    out, prev = [], None
    for p in path:
        if p != prev and p != blank:
            out.append(p)
        prev = p
    return tuple(out)


def _brute_best_path(lp, target, blank=0):
    T, C = lp.shape
    best, best_path = -np.inf, None
    for path in itertools.product(range(C), repeat=T):
        if _collapse(path, blank) == tuple(target):
            s = sum(lp[t, p] for t, p in enumerate(path))
            if s > best:
                best, best_path = s, path
    return best_path


def _counts_from_path(path, L, blank=0):
    """Frames per label: a label owns its frames and the following blanks; leading blanks go to label 0."""
    counts = [0] * L
    k, prev = -1, None
    for p in path:
        if p != blank and p != prev:
            k += 1
        counts[max(k, 0)] += 1
        prev = p
    return counts


def test_viterbi_matches_brute_force():
    rng = np.random.default_rng(0)
    for trial in range(40):
        T, C = rng.integers(3, 7), 4
        L = int(rng.integers(1, 4))
        target = [int(x) for x in rng.integers(1, C, size=L)]
        lp = np.log(rng.dirichlet(np.ones(C), size=T))
        ref = _brute_best_path(lp, target)
        got = K.ctc_viterbi_batch(torch.tensor(lp)[None], torch.tensor([T]), [target])[0]
        if ref is None:
            assert got is None, (trial, target, got)
        else:
            assert got == _counts_from_path(ref, L), (trial, target, ref, got)
            assert sum(got) == T and min(got) >= 1


def test_viterbi_batch_padding_consistent():
    rng = np.random.default_rng(1)
    B, Tm, C = 5, 30, 6
    lp = torch.log(torch.tensor(rng.dirichlet(np.ones(C), size=(B, Tm))))
    lens = torch.tensor([30, 12, 25, 7, 18])
    targets = [[int(x) for x in rng.integers(1, C, size=n)] for n in [9, 4, 1, 3, 0]]
    batch = K.ctc_viterbi_batch(lp, lens, targets)
    for b in range(B):
        single = K.ctc_viterbi_batch(lp[b:b + 1, :lens[b]], lens[b:b + 1], [targets[b]])[0]
        assert batch[b] == single, (b, batch[b], single)
        if single is not None:
            assert sum(single) == int(lens[b])
    assert batch[4] is None  # empty target


def _brute_marginals(lp, blank=0):
    T, C = lp.shape
    probs = {}
    for path in itertools.product(range(C), repeat=T):
        lab = _collapse(path, blank)
        probs[lab] = np.logaddexp(probs.get(lab, -np.inf), sum(lp[t, p] for t, p in enumerate(path)))
    return probs


def test_prefix_beam_search_exact_with_wide_beam():
    rng = np.random.default_rng(2)
    for _ in range(15):
        T, C = 5, 3
        lp = np.log(rng.dirichlet(np.ones(C) * 0.7, size=T))
        ref = _brute_marginals(lp)
        res = K.ctc_prefix_beam_search(lp, beam=500, skip=(), prune_logp=-1e9, max_cands=C)
        for prefix, score in res:
            assert abs(ref[prefix] - score) < 1e-6, (prefix, ref[prefix], score)
        best_ref = max(ref, key=ref.get)
        assert res[0][0] == best_ref


def test_greedy_segments_alignment_invariants():
    chars = K.CharVocab(["<blank>", "<unk>", "|", "a", "b", "c"])
    rng = np.random.default_rng(3)
    for _ in range(200):
        T = int(rng.integers(1, 40))
        ids = rng.choice([0, 0, 0, 1, 2, 3, 4, 5], size=T).tolist()
        text, spans = chars.greedy_segments(ids)
        assert len(text) == len(spans)
        assert text == text.strip() and "  " not in text
        for s, e in spans:
            assert 0 <= s < e <= T
        if spans:
            assert all(spans[k][1] <= spans[k + 1][0] for k in range(len(spans) - 1))
        assert K.normalize_text(text) == chars.decode_ctc(ids)


def test_token_spans_and_mask():
    tok = K.TextTok("facebook/nllb-200-distilled-600M", {"ha": "hau_Latn", "yo": "yor_Latn", "en": "eng_Latn"}, 2)
    text = K.ctc_text("Àwọn ọmọ Lefi jẹ́ mẹ́rìnléláàádọ́rin (74).")
    spans = K.uniform_char_spans(len(text), 200)
    ids, tsp = K.token_spans(tok, text, spans, 160)
    assert ids == tok.encode(text)
    assert len(ids) == len(tsp) and all(0 <= s < e <= 200 for s, e in tsp)
    m = K.spans_to_mask([tsp, tsp[:3]], [200, 50], 200)
    assert m.shape == (2, len(tsp), 200) and m[1, 3:].sum() == 0 and m[1].any(-1)[:3].all()


def test_route_balanced_mbr_is_not_dominated_by_nbest_size():
    direct = ["this is the only way to get the most out of it"] * 4
    cascade = ["the aspect ratio of this format is three to two"]
    cascade_ctc = ["the aspect ratio of the format is 3 to 2"]
    y, route, _ = K.route_mbr({"direct": direct, "cascade": cascade, "cascade_ctc": cascade_ctc})
    assert route.startswith("cascade"), (y, route)
    y1, r1, _ = K.route_mbr({"direct": ["a b c", "a b d"]})
    assert r1 == "direct" and y1 in ("a b c", "a b d")
    assert K.route_mbr({"x": ["", " "]}) == ("", "", 0.0)


def test_metrics_and_normalisation():
    s = "Àwọn ọmọ Lefi, jẹ́ mẹ́rìnléláàádọ́rin (74)!"
    n = K.normalize_text(s)
    assert K.normalize_text(n) == n
    assert K.normalize_text("yă tafi", strip_ortho=True) == "ya tafi"
    assert K.cer(["ab cd"], ["abcd"]) > 0 and K.cer(["ab cd"], ["abcd"], nospace=True) == 0
    refs = [f"sentence number {i} about topic {i * 7}" for i in range(20)]
    assert abs(K.source_sensitivity(refs, ["the same output"] * 20)) < 1.0
    assert K.source_sensitivity(refs, refs) > 20, K.source_sensitivity(refs, refs)
    assert K.distinct_ratio(["x"] * 5) == 0.2
    d = K.ctc_frames_to_mel([3, 1, 5, 2], 200, 50.0, 93.75)
    assert sum(d) == 200 and min(d) >= 0



def test_flickr_caption_detokenisation():
    cases = {"The dog 's mouth is open .": "The dog's mouth is open.",
             'a sign reading " HOMELESS HELPS " near a site .': 'A sign reading "HOMELESS HELPS" near a site.',
             "Two dogs ( one black ) play , outside .": "Two dogs (one black) play, outside.",
             "It is n't here .": "It isn't here.", "a cyclist": "A cyclist"}
    for src, want in cases.items():
        got = K.detok_caption(src)
        assert got == want, (src, got)
        assert K.detok_caption(got) == got  # idempotent (cached manifests are re-detokenised on load)


def test_route_mbr_same_route_candidates_share_one_vote():
    # two cascade candidates that agree with each other must not out-vote a direct route they disagree with
    direct = ["the man walks to the market"]
    casc = ["a woman sings in the church", "a woman sings in the church"]
    _, r_old, _ = K.route_mbr({"direct": direct, "cascade": [casc[0]], "cascade_ctc": [casc[1]]})
    assert r_old != "direct"  # the old 3-route layout handed the cascade a 100-chrF self-vote
    u_d = K.route_mbr({"direct": direct, "cascade": casc}, selectable=["direct"])[2]
    u_c = K.route_mbr({"direct": direct, "cascade": casc}, selectable=["cascade"])[2]
    assert abs(u_d - u_c) < 1e-6, (u_d, u_c)  # one vote each: the two routes are now symmetric

if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
