r"""audit_corpus_provenance.py - how much of our evidence is a recorded FAILURE?

    python ops/audit_corpus_provenance.py            # the report
    python ops/audit_corpus_provenance.py --selftest # frozen fixtures, hermetic

WHY THIS EXISTS (2026-09-07, backlog E23). Fixtures and golden files here are assembled from bugs we
found and cases we already handle correctly. Cases that failed silently were never written down, so
they are absent from the evidence - and E23's sharp point is that **their absence is invisible in the
score**. Publication bias at least leaves a cliff in the p-value distribution; ours leaves nothing.

The instance that made it concrete: the dedup test set was 31 pairs drawn from 168 ruled duplicates,
and the 135 that dropped out did so because the twin had left the candidate pool - which is what
happens when a recipe is ACCEPTED and built. The surviving evidence was filtered toward the
pipeline's successes by exactly the mechanism this item describes, and nothing said so until somebody
printed the denominator.

SO THIS PRINTS THE DENOMINATOR FOR EVERY CORPUS. Per registered corpus: how many cases came from a
recorded FAILURE, how many from a SUCCESS, and how many from a source that is neither - with the
counts beside every share, because a share without its population is what got us here.

WHAT IT DOES NOT DO. It does not judge whether a mix is right: a matcher corpus SHOULD be heavy on
adjudicated failures and an identity corpus should not, and no rule here can know which is which. It
makes the mix visible. E23's own mitigation is a work habit - record the case at the moment it fails,
including the ones fixed by hand and moved on from - and a habit is not something a script enforces.

THE ONE THING IT DOES RATCHET is corpora with NO recoverable provenance at all. A corpus whose rows
do not say where they came from cannot answer this question even in principle, and that number may
only go DOWN.

Exit 0 = clean. 2 = a NEW corpus with no provenance. 3 = could not evaluate.
Read the verdict LINE, not the number (backlog E2).
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
BASELINE = os.path.join(HERE, "corpus-provenance-baseline.json")

EXIT_CLEAN, EXIT_FINDING, EXIT_CANNOT_RUN = 0, 2, 3

# THE REGISTERED CORPORA. A named list because adding one is a decision: a corpus this file does not
# know about is a corpus whose provenance nobody is looking at, and silence would read as health.
# (path, format) - "jsonl" or "json-array".
CORPORA = [
    ("graph/gold/gold.jsonl", "jsonl"),
    ("graph/gold/hunter-gold.jsonl", "jsonl"),
    ("graph/gold/escalation-review.jsonl", "jsonl"),
    ("sidecar/data/eval-positives.json", "json-array"),
]

# HOW A SOURCE READS. Every entry is a judgement and it is written down rather than inferred, because
# "is this case a failure we recorded or a success we already handled" is exactly the question E23
# says nobody is asking.
FAILURE_SOURCES = (
    "known-wrong.json",            # adjudicated wrong-product rulings: a recorded failure by definition
    "commodity-dupe-allowlist",    # a duplicate somebody had to rule on
)
SUCCESS_SOURCES = (
    "product-urls.json",           # links the estate already accepted - cases we handle correctly
    "hunter-event:",               # an ingredient the hunter mapped successfully
)
NEITHER_SOURCES = (
    "escalation-review",           # the automatic path could not settle it and a reasoner did. Hard,
                                   # but not a recorded failure of a shipped answer - counting it
                                   # either way would flatter or damn the corpus by definition.
)


def classify(source: str) -> str:
    """failure / success / neither / unknown, from the row's own source string."""
    s = (source or "").strip()
    if not s:
        return "unknown"
    for p in FAILURE_SOURCES:
        if p in s:
            return "failure"
    for p in SUCCESS_SOURCES:
        if p in s:
            return "success"
    for p in NEITHER_SOURCES:
        if p in s:
            return "neither"
    return "unknown"


def summarise(rows) -> dict:
    """Counts per class plus the label mix. Every share is reported WITH its denominator by the
    caller; this returns the raw counts so it cannot be otherwise."""
    out = {"n": 0, "failure": 0, "success": 0, "neither": 0, "unknown": 0,
           "no_source": 0, "labels": {}}
    for r in rows:
        out["n"] += 1
        src = r.get("source")
        if not src:
            out["no_source"] += 1
        out[classify(src)] += 1
        lab = str(r.get("label", "?"))
        out["labels"][lab] = out["labels"].get(lab, 0) + 1
    return out


def repaired(baseline, read_this_run, still_missing):
    """Which baselined corpora may now leave the list.

    ONLY ONE WE ACTUALLY READ. sidecar/data/eval-positives.json is gitignored, so a worktree simply
    does not have it - and "in the baseline, not in this run's findings" would read that absence as a
    repair and drop it forever, on the strength of a run that never opened the file. Same shape
    lib/ratchet.ps1 refuses: a detector that saw nothing recording zero as the permanent ceiling.
    """
    return sorted((set(baseline) & set(read_this_run)) - set(still_missing))


def has_provenance(summary: dict) -> bool:
    """A corpus can answer E23's question only if its rows say where they came from.

    ANY row carrying a source is enough to make the question answerable; a corpus where NONE does is
    the one that cannot, in principle, and is what this file ratchets on.
    """
    return summary["n"] > 0 and summary["no_source"] < summary["n"]


def read_corpus(path, fmt):
    """Rows, or None when the file is not there. Tolerant per row: one bad line must not lose a corpus."""
    if not os.path.exists(path):
        return None
    rows = []
    if fmt == "jsonl":
        with io.open(path, encoding="utf-8-sig") as f:
            for ln in f:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    r = json.loads(ln)
                except Exception:                                  # noqa: BLE001
                    continue
                if isinstance(r, dict):
                    rows.append(r)
        return rows
    try:
        with io.open(path, encoding="utf-8-sig") as f:
            doc = json.load(f)
    except Exception:                                              # noqa: BLE001
        return []
    return [r for r in (doc or []) if isinstance(r, dict)]


def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("audit_corpus_provenance self-test")
    print("")

    # MUST FIRE - the founding classifications.
    T("MUST FIRE  a known-wrong ruling is a RECORDED FAILURE, which is the evidence E23 says we are short of",
      classify("known-wrong.json") == "failure", classify("known-wrong.json"))
    T("MUST FIRE  an accepted product link is a SUCCESS - a case we already handle",
      classify("product-urls.json") == "success", classify("product-urls.json"))
    T("MUST FIRE  a corpus whose rows carry NO source cannot answer the question at all",
      not has_provenance(summarise([{"label": "MATCH"}, {"label": "MATCH"}])),
      "reported as answerable")
    T("MUST FIRE  a source nobody classified reads as unknown rather than being quietly counted as a success",
      classify("some-new-file.json") == "unknown", classify("some-new-file.json"))

    # MUST NOT FIRE - the legal inputs.
    T("MUST NOT FIRE  an escalation is NEITHER - the automatic path could not settle it, which is not "
      "the same as a shipped answer being wrong, and counting it either way flatters or damns by definition",
      classify("escalation-review") == "neither", classify("escalation-review"))
    T("MUST NOT FIRE  a corpus where SOME rows carry a source can answer the question",
      has_provenance(summarise([{"source": "known-wrong.json"}, {"label": "x"}])), "reported unanswerable")
    T("MUST NOT FIRE  an empty corpus is not reported as having provenance, and does not throw",
      not has_provenance(summarise([])), "empty read as answerable")
    T("MUST NOT FIRE  a hunter event is a SUCCESS, not a failure - the mapper got it right",
      classify("hunter-event:quinoa-casserole") == "success", classify("hunter-event:quinoa-casserole"))

    # CLEAN TWIN - adjacent behaviour that still works.
    s = summarise([{"source": "known-wrong.json", "label": "NO_MATCH"},
                   {"source": "product-urls.json", "label": "MATCH"},
                   {"source": "escalation-review", "label": "MATCH"}])
    T("CLEAN TWIN the counts add up to n, so no row is silently dropped from the denominator",
      s["failure"] + s["success"] + s["neither"] + s["unknown"] == s["n"], json.dumps(s))
    T("CLEAN TWIN the label mix is carried too - a corpus of only MATCH rows says something a source "
      "mix cannot", s["labels"] == {"NO_MATCH": 1, "MATCH": 2}, json.dumps(s["labels"]))
    T("CLEAN TWIN a missing file reads as None, not as an empty corpus - absent and empty are "
      "different answers", read_corpus(os.path.join(REPO, "nope-not-here.jsonl"), "jsonl") is None,
      "an absent corpus read as empty")

    # THE RATCHET'S OWN TRAP, pinned because I wrote it wrong first. eval-positives.json is
    # gitignored, so a worktree does not have it - and "in the baseline, not in this run's findings"
    # would then read as REPAIRED and drop it forever.
    # a.json was read and now carries provenance; b.json was not on disk at all this run.
    got = repaired(["a.json", "b.json"], ["a.json"], [])
    T("MUST FIRE  THE TRAP THIS RATCHET WOULD HAVE FALLEN INTO - a corpus that was NOT READ this run "
      "must not leave the baseline, because absence is not a repair",
      "b.json" not in got, str(got))
    T("CLEAN TWIN a corpus that WAS read and now carries provenance does leave it - the list is "
      "allowed to shrink on evidence, just not on silence",
      got == ["a.json"], str(got))
    T("CLEAN TWIN a corpus read and STILL missing its provenance stays on the list",
      repaired(["a.json"], ["a.json"], ["a.json"]) == [], str(repaired(["a.json"], ["a.json"], ["a.json"])))

    if bad:
        print("")
        print("SELF-TEST FAIL: %d check(s)" % len(bad))
        print("CORPUS-PROVENANCE-SELFTEST-COMPLETE")
        return 1
    print("")
    print("SELF-TEST PASS: 5 must-fire cases including the absence-is-not-a-repair trap this "
          "ratchet would have fallen into, 4 must-not-fire cases led by the escalation that is "
          "neither, and 5 clean twins")
    print("CORPUS-PROVENANCE-SELFTEST-COMPLETE")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="how much of our evidence is a recorded failure")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--update", action="store_true", help="retrain the no-provenance baseline")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    seen, blind = [], []
    for rel, fmt in CORPORA:
        rows = read_corpus(os.path.join(REPO, rel.replace("/", os.sep)), fmt)
        if rows is None:
            blind.append(rel)
            continue
        seen.append((rel, summarise(rows)))

    if not seen:
        print("CORPUS PROVENANCE BLIND: none of the %d registered corpora are on disk, which means "
              "the paths moved rather than the estate having no evidence." % len(CORPORA))
        print("CORPUS-PROVENANCE-COMPLETE blind=no-corpora")
        return EXIT_CANNOT_RUN

    print("evidence provenance, over %d corpus/corpora on disk (%d registered)" % (len(seen), len(CORPORA)))
    print("")
    noprov = []
    for rel, s in seen:
        if not has_provenance(s):
            noprov.append(rel)
            print("  %-40s %5d row(s) - NO SOURCE on any row, so it cannot answer this question at all"
                  % (rel, s["n"]))
            continue
        print("  %-40s %5d row(s): %d from a recorded FAILURE, %d from a SUCCESS we already handle, "
              "%d neither, %d unclassified source"
              % (rel, s["n"], s["failure"], s["success"], s["neither"], s["unknown"]))
        print("  %-40s        labels: %s" % ("", ", ".join("%s %d" % kv for kv in sorted(s["labels"].items()))))
    for rel in blind:
        print("  %-40s not on disk (gitignored or not built here)" % rel)

    tot = sum(s["n"] for _, s in seen)
    fails = sum(s["failure"] for _, s in seen)
    print("")
    print("  %d of %d row(s) across the corpora on disk come from a recorded failure." % (fails, tot))
    print("  That number is REPORTED, not judged: a matcher corpus should be heavy on adjudicated")
    print("  failures and an identity corpus should not, and no rule here knows which is which.")

    base = None
    if os.path.exists(BASELINE):
        try:
            with io.open(BASELINE, encoding="utf-8-sig") as f:
                base = json.load(f).get("no_provenance")
        except Exception:                                          # noqa: BLE001
            base = None
    if base is None or a.update:
        with io.open(BASELINE, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"no_provenance": sorted(noprov),
                       "note": ("Corpora whose rows carry no source at all, so they cannot answer "
                                "'how much of this evidence is a recorded failure' even in "
                                "principle. This list may only get SHORTER.")}, f, indent=2)
            f.write("\n")
        print("")
        print("  baseline written: %d corpus/corpora with no provenance. The list may only get shorter."
              % len(noprov))
        print("CORPUS-PROVENANCE-COMPLETE corpora=%d noprov=%d" % (len(seen), len(noprov)))
        return EXIT_CLEAN

    missing = sorted(set(base) - set(rel for rel, _ in seen))
    for rel in missing:
        print("  %-40s in the baseline and NOT READ this run - still owed provenance, not repaired" % rel)
    new = sorted(set(noprov) - set(base))
    if new:
        print("")
        print("CORPUS PROVENANCE AUDIT FAILED: %d NEW corpus/corpora carry no source on any row: %s. "
              "A corpus that cannot say where its cases came from cannot be checked for the bias E23 "
              "describes - its successes and its failures are indistinguishable, and the absence of "
              "the ones we never wrote down stays invisible."
              % (len(new), ", ".join(new)))
        print("CORPUS-PROVENANCE-COMPLETE corpora=%d noprov=%d new=%d" % (len(seen), len(noprov), len(new)))
        return EXIT_FINDING

    # ONLY A CORPUS WE ACTUALLY READ CAN BE CALLED FIXED. eval-positives.json is gitignored, so in a
    # worktree it is simply absent - and `set(base) - set(noprov)` would then read absence as a
    # repair and drop it from the baseline forever, on the strength of a run that never opened it.
    # Same shape lib/ratchet.ps1 refuses: a detector that saw nothing recording zero as the ceiling.
    fixed = repaired(base, [rel for rel, _ in seen], noprov)
    if fixed:
        with io.open(BASELINE, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"no_provenance": sorted(noprov),
                       "note": ("Corpora whose rows carry no source at all. This list may only get "
                                "SHORTER.")}, f, indent=2)
            f.write("\n")
        print("")
        print("  TIGHTENED: %s now carry provenance. The list may only get shorter." % ", ".join(fixed))
    print("")
    print("corpus-provenance: PASSED - %d corpus/corpora reported, %d still carrying no source at all "
          "(unchanged from the baseline)." % (len(seen), len(noprov)))
    print("CORPUS-PROVENANCE-COMPLETE corpora=%d noprov=%d" % (len(seen), len(noprov)))
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())
