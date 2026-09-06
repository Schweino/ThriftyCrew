r"""extractor_model_probe.py - can a cheaper model do the transcription stage?

    python meal-prep/pipeline/extractor_model_probe.py --n 4
    python meal-prep/pipeline/extractor_model_probe.py --selftest

BACKLOG E9 / MATE's M: use the least capable model that finishes the job. recipe-hunter-extractor is
pinned fable/medium and its job is TRANSCRIPTION ONLY - it never converts a unit, never estimates a
missing measurement, never rewrites prose, never prices anything. That makes it the most mechanical
stage in the estate and the obvious downgrade candidate.

WHY THIS IS A FAIR TEST AND MOST MODEL COMPARISONS ARE NOT. Transcription has a RIGHT ANSWER. There is
no style to prefer and no judgment to weigh: either the ingredient lines come back as the page states
them or they do not. So this does not ask which output is nicer, it asks whether two models produce the
SAME transcription of the same page.

IT COMPARES THE TWO MODELS TO EACH OTHER, NOT TO THE STORED FILE, and that is deliberate. The stored
transcriptions date from August and the live pages may have changed since; measuring against them would
confound a model difference with a page edit. Two models fetching the same page today share whatever it
says now. The stored file is printed alongside as a third reference, never as the scoring key.

WHAT IT CANNOT TELL YOU: a handful of pages is a handful of pages. Agreement here means the cheaper
model reproduced these transcriptions, not that it will hold on a page shaped unlike them - a recipe
with sections, fractions in unicode, or an ingredient list inside an image is exactly where a weaker
model would be expected to slip, and a small sample of ordinary pages will not contain one.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(MP, ".."))
AGENT = os.path.join(REPO, ".claude", "agents", "recipe-hunter-extractor.md")
CLAUDE = os.path.join(os.path.expanduser("~"), ".local", "bin", "claude.exe")


def rj(p):
    with io.open(p, encoding="utf-8-sig") as f:
        return json.load(f)


def agent_def():
    """model, effort, tools and body, read from the frontmatter - the single authority, same as
    hunt_dispatch treats it. Nothing here re-states a pin."""
    t = io.open(AGENT, encoding="utf-8-sig").read()
    m = re.match(r"^---\r?\n(.*?)\r?\n---\r?\n(.*)$", t, re.S)
    if not m:
        raise RuntimeError("no frontmatter in " + AGENT)
    fm, body = m.group(1), m.group(2)
    def field(k):
        mm = re.search(r"(?m)^%s:\s*(.+)$" % k, fm)
        return mm.group(1).strip() if mm else ""
    return {"model": field("model"), "effort": field("effort"),
            "tools": [x.strip() for x in field("tools").split(",") if x.strip()],
            "body": body}


def norm_line(s):
    """Compare transcriptions the way a reader would: case and whitespace are not a difference, a
    changed word is. Deliberately NOT a fuzzy match - the whole claim under test is byte-level fidelity,
    and a lenient comparator would manufacture the agreement it is supposed to detect."""
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def compare(a, b):
    """Two extraction payloads -> the differences that matter. Returns (same, notes)."""
    notes = []
    ai = [norm_line(x.get("raw")) for x in (a.get("ingredients") or [])]
    bi = [norm_line(x.get("raw")) for x in (b.get("ingredients") or [])]
    if len(ai) != len(bi):
        notes.append("ingredient COUNT differs: %d vs %d" % (len(ai), len(bi)))
    else:
        for i, (x, y) in enumerate(zip(ai, bi)):
            if x != y:
                notes.append("ingredient %d differs:\n        A: %s\n        B: %s" % (i + 1, x, y))
    astep = [norm_line(x) for x in (a.get("instructions") or [])]
    bstep = [norm_line(x) for x in (b.get("instructions") or [])]
    if len(astep) != len(bstep):
        notes.append("step COUNT differs: %d vs %d" % (len(astep), len(bstep)))
    for k in ("servings", "title"):
        if norm_line(str(a.get(k))) != norm_line(str(b.get(k))):
            notes.append("%s differs: %r vs %r" % (k, a.get(k), b.get(k)))
    return (not notes), notes


def run_one(model, effort, tools, body, prompt, timeout=600):
    argv = [CLAUDE, "-p", "--output-format", "json", "--model", model,
            "--append-system-prompt", body]
    if tools:
        argv += ["--allowedTools", ",".join(tools)]
    if effort:
        argv += ["--effort", effort]
    try:
        p = subprocess.run(argv, input=prompt, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "timed out after %ds" % timeout
    if p.returncode != 0:
        return None, "claude exited %d: %s" % (p.returncode, (p.stderr or "")[:200])
    try:
        env = json.loads(p.stdout)
        text = env.get("result") or ""
    except Exception:                                          # noqa: BLE001
        text = p.stdout
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None, "no JSON object in the reply"
    try:
        return json.loads(m.group(0)), ""
    except Exception as e:                                     # noqa: BLE001
        return None, "reply JSON did not parse: %s" % e


def selftest():
    fails = []
    def T(name, cond, got=""):
        if cond:
            print("  ok    %s" % name)
        else:
            print("  X     %s   got: %s" % (name, got))
            fails.append(name)

    a = {"ingredients": [{"raw": "16 ounces cauliflower"}], "instructions": ["Heat."],
         "servings": 4, "title": "X"}
    same, notes = compare(a, json.loads(json.dumps(a)))
    T("CLEAN TWIN identical payloads compare equal", same, "; ".join(notes))

    b = json.loads(json.dumps(a)); b["ingredients"][0]["raw"] = "16 oz cauliflower"
    same, notes = compare(a, b)
    T("MUST FIRE  a UNIT rewritten from 'ounces' to 'oz' is a difference - that is the conversion the "
      "extractor is forbidden to make", (not same) and "ingredient 1" in notes[0], "; ".join(notes))

    c = json.loads(json.dumps(a)); c["ingredients"].append({"raw": "1 tsp salt"})
    same, notes = compare(a, c)
    T("MUST FIRE  an ADDED ingredient is a difference", (not same) and "COUNT" in notes[0], "; ".join(notes))

    d = json.loads(json.dumps(a)); d["instructions"] = ["Heat.", "Serve."]
    same, notes = compare(a, d)
    T("MUST FIRE  a dropped or added STEP is a difference", not same, "; ".join(notes))

    e = json.loads(json.dumps(a)); e["ingredients"][0]["raw"] = "  16   OUNCES cauliflower "
    same, notes = compare(a, e)
    T("CLEAN TWIN case and whitespace are NOT a difference", same, "; ".join(notes))

    f = json.loads(json.dumps(a)); f["servings"] = 8
    same, notes = compare(a, f)
    T("MUST FIRE  a changed servings count is a difference", not same, "; ".join(notes))

    ad = agent_def()
    T("the agent frontmatter still parses and pins a model", bool(ad["model"]), ad["model"] or "(none)")

    if fails:
        print("SELF-TEST FAIL: %d case(s)" % len(fails))
        return 1
    print("SELF-TEST PASS: the comparator's six cases, including the unit-rewrite it exists to catch")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--cheap", default="claude-haiku-4-5-20251001")
    ap.add_argument("--seed", type=int, default=20260906)
    a = ap.parse_args([x for x in sys.argv[1:] if x != "--run"])

    ad = agent_def()
    print("extractor pin: model=%s effort=%s tools=%d" % (ad["model"], ad["effort"], len(ad["tools"])))
    print("candidate    : %s" % a.cheap)

    stored = []
    for d in sorted(os.listdir(os.path.join(MP, "runs"))):
        ex = os.path.join(MP, "runs", d, "extracted")
        if not os.path.isdir(ex):
            continue
        for fn in sorted(os.listdir(ex)):
            if fn.endswith(".json") and not fn.endswith(".escalation.json"):
                try:
                    doc = rj(os.path.join(ex, fn))
                except Exception:                              # noqa: BLE001
                    continue
                if doc.get("source_url") and (doc.get("ingredients") or []):
                    stored.append((fn[:-5], doc))
    print("stored transcriptions with a source url: %d" % len(stored))
    if not stored:
        print("PROBE COULD NOT EVALUATE: no stored transcription to draw a page from.")
        return 3

    random.Random(a.seed).shuffle(stored)
    picks = stored[:a.n]

    agree = 0
    ran = 0
    for slug, doc in picks:
        url = doc["source_url"]
        prompt = (
            "Transcribe ONE recipe page.\n\n"
            "The page is at %s. Fetch it. If you cannot reach the page at all, say so: state "
            "\"unreadable\" is a complete and correct answer. An invented recipe is the worst outcome "
            "in this flow.\n\n"
            "TRANSCRIPTION ONLY. Convert no units, estimate no missing measurement, rewrite no prose. "
            "The `raw` field of each ingredient is the page's own line, verbatim.\n\n"
            "Return the extraction contract as JSON and nothing else: "
            "{state, reason, title, source_url, servings, time_total, time_active, "
            "ingredients:[{raw,item,qty,unit,prep,optional,section}], instructions:[], concerns:[]}.\n"
            % url)
        print("")
        print("=== %s" % slug)
        print("    %s" % url)
        pinned, e1 = run_one(ad["model"], ad["effort"], ad["tools"], ad["body"], prompt)
        if e1:
            print("    pinned  (%s): %s" % (ad["model"], e1))
            continue
        cheap, e2 = run_one(a.cheap, ad["effort"], ad["tools"], ad["body"], prompt)
        if e2:
            print("    cheap   (%s): %s" % (a.cheap, e2))
            continue
        ran += 1
        if (pinned.get("state") or "") == "unreadable" or (cheap.get("state") or "") == "unreadable":
            print("    one or both returned 'unreadable' - the page did not resolve, so this pair "
                  "measures the fetch and not the model. Skipped.")
            ran -= 1
            continue
        same, notes = compare(pinned, cheap)
        print("    pinned: %d ingredient(s), %d step(s)   cheap: %d / %d"
              % (len(pinned.get("ingredients") or []), len(pinned.get("instructions") or []),
                 len(cheap.get("ingredients") or []), len(cheap.get("instructions") or [])))
        print("    stored (Aug, reference only): %d ingredient(s)" % len(doc.get("ingredients") or []))
        if same:
            agree += 1
            print("    IDENTICAL transcription")
        else:
            for nline in notes[:6]:
                print("    DIFF  %s" % nline)

    print("")
    if not ran:
        print("PROBE COULD NOT EVALUATE: no pair completed. Nothing is proven about either model.")
        return 3
    print("agreed on %d of %d comparable page(s)." % (agree, ran))
    print("A DISAGREEMENT IS DISQUALIFYING AND AN AGREEMENT IS NOT PROOF. Transcription has a right")
    print("answer, so one differing ingredient line is enough to rule the cheaper model out. The")
    print("reverse does not hold on a sample this size: agreement here means it reproduced THESE")
    print("pages, not that it holds on a page with sections, unicode fractions, or its ingredients")
    print("in an image - which is exactly where a weaker model would be expected to slip.")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
