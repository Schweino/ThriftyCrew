"""THE DEDUP PROMPT DRILL, part 2 of 2: ask the LOCAL model one forced choice per pair, in BOTH
orders, name-only and with ingredients. Zero Claude tokens, zero network beyond localhost.

WHY THIS IS COMMITTED. It produced the table in `design\\EVAL-dedup-shortlist-2026-09-04.md`
section 8 that retired the ingest refusal path (P1c). Measured 2026-09-04 on 434 pairs: 1,736 calls,
608 s.

  design                                  recall on 134 dupes   wrong refusals on 300 published
  B  forced choice, names, ONE order       60.4%                 6.00%
  C  forced choice, names, BOTH orders     43.3%                 4.67%
  D  forced choice, INGREDIENTS, BOTH      23.9%                 2.00%

THE COMPARISON THAT MATTERS IS C vs D, and it is internally valid: same prompt, same pairs, same
model, same grammar, the ingredient lines the only difference. The comparison that is NOT available
is against the earlier forced-choice figure of 8.4%/0-of-300 - that prompt was never implemented and
its text is recorded nowhere, which is exactly why this file exists.

Needs llama-server up (tools\\local-llm\\serve.ps1 -Slots 1). Reads pairs.json; writes only its own
results file.

    C:\\Codex\\Python312\\python.exe meal-prep\\pipeline\\dedup_prompt_drill_ask.py [pairs.json] [out.json]
"""
import json, io, os, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PAIRS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "pairs.json")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "ask-results.json")
URL = "http://127.0.0.1:8080/completion"
NL = chr(10)

RUBRIC = ("You are deduplicating a recipe catalog. Two dinners are THE SAME DINNER when a reader "
          "would not buy both: same main protein, same cooking method, same sauce or flavour "
          "identity. A different vehicle for the same filling (taco vs burrito vs bowl) is the SAME "
          "dinner. A genuinely different plate that happens to share ingredients is NOT.")


def prompt(a, b, with_ings):
    p = [RUBRIC, "Recipe A: %s" % a["name"]]
    if with_ings:
        p.append("A ingredients: %s" % "; ".join(a["lines"]))
    p.append("Recipe B: %s" % b["name"])
    if with_ings:
        p.append("B ingredients: %s" % "; ".join(b["lines"]))
    p.append("Are A and B the same dinner, or different dinners? Answer with one word.")
    p.append("Answer:")
    return NL.join(p)


def ask(text, timeout=90):
    body = json.dumps({"prompt": text, "grammar": 'root ::= ("same" | "different")',
                       "n_predict": 4, "temperature": 0.0}).encode("utf-8")
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return (json.loads(r.read().decode("utf-8", errors="replace")).get("content") or "").strip().lower()


def main():
    with io.open(PAIRS, encoding="utf-8") as f:
        d = json.load(f)
    rows = [("positive", p) for p in d["positives"]] + [("negative", p) for p in d["negatives"]]
    out = []
    t0 = time.time()
    for i, (kind, p) in enumerate(rows):
        rec = {"kind": kind, "a": p["a"]["name"], "b": p["b"]["name"],
               "a_slug": p["a"]["slug"], "b_slug": p["b"]["slug"], "score": p.get("score")}
        for tag, wi in (("C", False), ("D", True)):
            f1 = ask(prompt(p["a"], p["b"], wi))
            f2 = ask(prompt(p["b"], p["a"], wi))
            rec[tag] = [f1, f2]
            rec[tag + "_fires"] = (f1 == "same" and f2 == "same")
            rec[tag + "_one"] = (f1 == "same")          # design B: one order only
        out.append(rec)
        if (i + 1) % 25 == 0:
            el = time.time() - t0
            print("  %d/%d  %.0fs elapsed, %.1fs/pair" % (i + 1, len(rows), el, el / (i + 1)),
                  flush=True)
    with io.open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)

    def tally(kind, tag):
        s = [r for r in out if r["kind"] == kind]
        return sum(1 for r in s if r[tag]), len(s)

    print("")
    print("design                                   recall (positives)   wrong refusals (negatives)")
    for tag, label in (("C_one", "B  names only, ONE order"),
                       ("C_fires", "C  names only, BOTH orders"),
                       ("D_one", "D1 ingredients, ONE order"),
                       ("D_fires", "D  ingredients, BOTH orders")):
        rp, np_ = tally("positive", tag)
        rn, nn = tally("negative", tag)
        print("%-38s %3d/%-3d (%4.1f%%)      %3d/%-3d (%4.2f%%)"
              % (label, rp, np_, 100.0 * rp / max(1, np_), rn, nn, 100.0 * rn / max(1, nn)))
    print("")
    print("WRONG REFUSALS under D (ingredients, both orders) - Brad rules on the PAIRS:")
    for r in out:
        if r["kind"] == "negative" and r["D_fires"]:
            print("  %.4f  %s  ||  %s" % (r["score"] or 0, r["a"], r["b"]))
    print("-> %s   (%.0f s total)" % (OUT, time.time() - t0))


main()
