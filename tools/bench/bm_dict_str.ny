# bm_dict_str - dictionary and string work: word counting over generated
# text (split, lower, strip, dict get/set, sorting by a key), string
# building with join and f-strings, and json round trips (json.dumps /
# json.loads of nested dicts and lists). Runs under python3 too.
import json
import time

WORDS = ["alpha", "Beta", "gamma", "delta,", "Epsilon", "zeta.", "eta", "theta",
         "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho",
         "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega!"]


def make_text(n):
    out = []
    k = 7
    for i in range(n):
        k = (k * 1103515245 + 12345) % 2147483648
        out.append(WORDS[k % len(WORDS)])
    return " ".join(out)


def count_words(text):
    counts = {}
    for w in text.split():
        w = w.strip(".,!").lower()
        counts[w] = counts.get(w, 0) + 1
    return counts


def top(counts, n):
    items = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return items[:n]


def build_records(counts):
    recs = []
    for w in sorted(counts):
        recs.append({"word": w, "count": counts[w], "upper": w.upper(),
                     "tags": [w[:1], w[-1:], str(len(w))], "id": f"{w}-{counts[w]}"})
    return recs


def main():
    t0 = time.perf_counter()
    text = make_text(60000)
    counts = count_words(text)
    best = top(counts, 5)
    total = 0
    for rnd in range(40):
        recs = build_records(counts)
        s = json.dumps({"round": rnd, "records": recs})
        back = json.loads(s)
        total += len(s) + len(back["records"])
        parts = []
        for r in back["records"]:
            parts.append(r["id"] + ":" + r["upper"])
        total += len(",".join(parts))
    t1 = time.perf_counter()
    print("result", len(counts), best[0][0], best[0][1], total)
    print("bench_time", t1 - t0)

main()
