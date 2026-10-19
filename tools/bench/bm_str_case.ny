# bm_str_case - str case mapping, predicates and whitespace splitting
# (round 84: the methods read the Unicode database now; this measures that
# the ASCII fast paths kept their speed and what non-ASCII text costs):
# lower/upper/title/casefold/split/strip/isalpha/isdigit over ASCII words,
# then over Latin-1, Greek and Cyrillic words. Runs under python3 too.
import time

ASCII_WORDS = ["alpha", "Beta", "GAMMA", "delta,", "Epsilon", "zeta.", "eta", "theta42",
               "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi"]
UNI_WORDS = ["Ärger", "straße", "Ölçü", "çà", "Ελλάδα", "αθήνα", "ΣΟΦΙΑ", "Москва",
             "привет", "ЁЖ", "naïve", "café", "Ñandú", "øre", "Łódź", "ŽÝ"]


def make(words, n):
    out = []
    k = 7
    for i in range(n):
        k = (k * 1103515245 + 12345) % 2147483648
        out.append(words[k % len(words)])
    return " ".join(out)


def work(text, rounds):
    total = 0
    for r in range(rounds):
        low = text.lower()
        up = text.upper()
        total += len(low) + len(up) + len(text.title()) + len(text.casefold())
        for w in text.split():
            w2 = w.strip(".,")
            if w2.isalpha():
                total += 1
            if w2.isdigit():
                total += 2
            if w2.lower() == w2:
                total += 3
    return total


def main():
    t0 = time.perf_counter()
    a = make(ASCII_WORDS, 20000)
    u = make(UNI_WORDS, 20000)
    ta = work(a, 6)
    tu = work(u, 6)
    t1 = time.perf_counter()
    print("result", ta, tu, len(a.upper()), len(u.upper()))
    print("bench_time", t1 - t0)

main()
