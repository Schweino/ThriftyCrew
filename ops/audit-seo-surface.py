#!/usr/bin/env python
"""Measure the published SEO surface so an SEO change becomes falsifiable.

BACKLOG I24. The estate had no measurement of its own search surface at all: no Search
Console series, and of 26 scripts in `ops/` not one read a published page's title,
description or image. The single baseline that exists, `seo-baseline-2026-08-31`, was
hand-read off the Search Console UI on one day and cannot be re-read. So any SEO change
shipped today is unfalsifiable, which is the same standard this estate applies to a price.

WHAT THIS MEASURES, AND WHAT IT DELIBERATELY DOES NOT.

I24 names two options. The first, a scheduled Search Console API read, needs a new
credential and is not this file's to create. This is the second: a static audit of the
surface we ourselves publish, which needs no credential and is the half that is in our
control.

It reads `meal-prep/db/built/*.head.html`, which carry the JSON-LD `Recipe` block shipped
verbatim to Ghost. That block is what Google parses, so these numbers are about the real
surface rather than about an intermediate.

**It does NOT measure crawlable teaser length, and that omission is deliberate.** The
baseline records ~49 crawlable words on a paywalled recipe. That was read from the LIVE
page, where Ghost gates member-only content at serve time. The local built file is
`html|paywall|html` with the marker sitting around 90% of the way through, so counting
words before the marker here returns roughly 5,900 - two orders of magnitude off, because
it is a different surface. Measuring it locally and calling it crawlable would be a
fabricated number. To measure that honestly you have to fetch the live page logged out.

**It does not measure Google's response either.** Position, impressions and clicks need
the Search Console API. This measures the input, not the outcome, and cannot on its own
say whether ranking moved.

WHAT IT FOUND ON THE FIRST RUN, 2026-09-07, and one of these was missed by the hand-read:

  584 recipes, 2 distinct `Recipe.image` values across all of them
  535 share one image, the site logo, which the baseline recorded
   49 carry an EMPTY image string, which it did not

An empty `Recipe.image` is not the same defect as a shared one. A shared image is a weak
signal; an empty required property can invalidate the Recipe rich result outright, so those
49 are plausibly worse off than the 535. Nobody had counted them.

RATCHET, per lib/ratchet.ps1 (backlog I15). Each metric has a direction, a fall in the wrong
one fails, and the recipe count is checked because a walk that finds almost nothing looks
identical to a tree that got clean. Baselined at the first measurement so it is NOT red on
day one: this records the exposure and stops it getting worse, which is the shape that does
not teach people to ignore red.

Exit 0 = nothing regressed. 1 = something did. 2 = could not evaluate, never a pass.
Last line is the marker lib/guard-contract.ps1 requires.
"""

from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
BUILT = os.path.join(REPO, "meal-prep", "db", "built")
BASELINE = os.path.join(HERE, "seo-surface-baseline.json")
SERIES = os.path.join(REPO, "grocery", "out", "seo-surface")

# metric -> direction that is an IMPROVEMENT. A move the other way fails.
DIRECTION = {
    "distinct_images": "up",
    "empty_image": "down",
    "missing_description": "down",
    "duplicate_descriptions": "down",
    "missing_name": "down",
}


def die(msg: str) -> None:
    print("COULD NOT EVALUATE: %s" % msg)
    print("SEO-SURFACE-COMPLETE")
    raise SystemExit(2)


def field(text: str, name: str) -> str | None:
    """Pull a top-level JSON-LD string field. Tolerant of the PowerShell-emitted
    spacing in these files (`"name":  "value"`)."""
    m = re.search(r'"%s"\s*:\s*"((?:[^"\\]|\\.)*)"' % re.escape(name), text)
    return m.group(1) if m else None


def measure(heads: list[str]) -> dict:
    images, descs, names = collections.Counter(), collections.Counter(), 0
    empty_image = missing_desc = missing_name = 0
    for h in heads:
        try:
            t = open(h, encoding="utf-8-sig", errors="replace").read()
        except Exception:                                            # noqa: BLE001
            continue
        img = field(t, "image")
        if img is None or img == "":
            empty_image += 1
        else:
            images[img] += 1
        d = field(t, "description")
        if not d:
            missing_desc += 1
        else:
            descs[d] += 1
        if not field(t, "name"):
            missing_name += 1
        else:
            names += 1
    return {
        "recipes": len(heads),
        "distinct_images": len(images),
        "empty_image": empty_image,
        "missing_description": missing_desc,
        "missing_name": missing_name,
        "duplicate_descriptions": sum(c - 1 for c in descs.values() if c > 1),
        "distinct_descriptions": len(descs),
    }


def collect() -> dict:
    if not os.path.isdir(BUILT):
        die("no built recipes at %s. In a worktree or a fresh checkout this tree is "
            "absent, and an empty walk is not a clean surface." % BUILT)
    heads = sorted(glob.glob(os.path.join(BUILT, "*.head.html")))
    if len(heads) < 50:
        die("found only %d built recipes. That is the walk broken, not the catalogue "
            "empty - 584 were present on 2026-09-07." % len(heads))
    return measure(heads)


def report(got: dict) -> None:
    print("published SEO surface, from %d built recipes:" % got["recipes"])
    for k in ("distinct_images", "empty_image", "distinct_descriptions",
              "duplicate_descriptions", "missing_description", "missing_name"):
        print("  %-24s %d" % (k, got[k]))


def audit() -> int:
    got = collect()
    report(got)
    if not os.path.isfile(BASELINE):
        die("no baseline at %s. Write one with --freeze after reading the numbers above."
            % BASELINE)
    base = json.load(open(BASELINE, encoding="utf-8"))

    fails = []
    # A COLLAPSED CATALOGUE IS A BROKEN WALK, NOT A CLEAN SURFACE.
    if got["recipes"] < base.get("recipes", 0) * 0.9:
        fails.append("recipe count fell from %d to %d, more than 10%%. That is the walk, "
                     "not the catalogue." % (base["recipes"], got["recipes"]))
    for k, want in DIRECTION.items():
        b, g = base.get(k), got.get(k)
        if b is None:
            continue
        if want == "up" and g < b:
            fails.append("%s FELL %d -> %d (higher is better)" % (k, b, g))
        if want == "down" and g > b:
            fails.append("%s ROSE %d -> %d (lower is better)" % (k, b, g))

    for f in fails:
        print("FAIL  " + f)
    print("%d metric(s) checked, %d regressed" % (len(DIRECTION), len(fails)))
    if fails:
        print("VERDICT: FAIL - the published SEO surface got worse.")
    else:
        print("VERDICT: PASS - nothing regressed. Note the baseline itself records a known "
              "exposure: %d recipes share %d distinct image(s) and %d carry an empty one."
              % (got["recipes"], got["distinct_images"], got["empty_image"]))
    print("SEO-SURFACE-COMPLETE")
    return 1 if fails else 0


# ---------------------------------------------------------------------------
# Hermetic self-test of the PARSER, on fixtures. run-gates discovers this; the
# data audit above is not hermetic and belongs in the daily chain, per
# run-gates.ps1's own header.
# ---------------------------------------------------------------------------
GOOD = '{"@type": "Recipe", "name":  "A", "description":  "d one", "image":  "https://x/1.jpg"}'
EMPTY_IMG = '{"@type": "Recipe", "name":  "B", "description":  "d two", "image":  ""}'
NO_DESC = '{"@type": "Recipe", "name":  "C", "image":  "https://x/2.jpg"}'
DUP = '{"@type": "Recipe", "name":  "D", "description":  "d one", "image":  "https://x/1.jpg"}'


def selftest() -> int:
    import tempfile
    fails, ran = [], 0

    def check(name, ok, detail=""):
        nonlocal ran
        ran += 1
        if not ok:
            fails.append("%-52s %s" % (name, detail))

    tmp = tempfile.mkdtemp()
    try:
        for i, body in enumerate((GOOD, EMPTY_IMG, NO_DESC, DUP)):
            with open(os.path.join(tmp, "r%d.head.html" % i), "w", encoding="utf-8") as f:
                f.write('<script type="application/ld+json">\n%s\n</script>' % body)
        got = measure(sorted(glob.glob(os.path.join(tmp, "*.head.html"))))

        check("MUST FIRE  an empty image string is counted as empty",
              got["empty_image"] == 1, repr(got))
        check("MUST FIRE  a missing description is counted",
              got["missing_description"] == 1, repr(got))
        check("MUST FIRE  a repeated description counts as a duplicate",
              got["duplicate_descriptions"] == 1, repr(got))
        # CLEAN TWIN. Without this, a parser that returned zero for everything
        # would satisfy none of the above and still look broken-but-passing on
        # a real tree where the counts happen to be zero.
        check("CLEAN TWIN  distinct images counted, empty NOT among them",
              got["distinct_images"] == 2, repr(got))
        check("CLEAN TWIN  every fixture was seen",
              got["recipes"] == 4, repr(got))
        # MUST NOT FIRE - proves the field reader is not matching anything it sees.
        check("MUST NOT FIRE  a name is present on every fixture",
              got["missing_name"] == 0, repr(got))
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    for line in fails:
        print("FAIL  " + line)
    print("%d case(s), %d failed" % (ran, len(fails)))
    print("VERDICT: %s" % ("FAIL - the surface parser is wrong, so every number it "
                           "reports is wrong" if fails else
                           "PASS - the parser distinguishes empty, missing and duplicate"))
    print("SEO-SURFACE-SELFTEST-COMPLETE")
    return 1 if fails else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Published SEO surface audit.")
    ap.add_argument("--audit", action="store_true", help="measure the built recipes")
    ap.add_argument("--selftest", action="store_true", help="hermetic parser fixtures")
    ap.add_argument("--freeze", action="store_true", help="write the current numbers as baseline")
    ap.add_argument("--series", action="store_true", help="also append a dated series file")
    a = ap.parse_args()
    if a.selftest:
        raise SystemExit(selftest())
    if a.freeze:
        got = collect()
        report(got)
        with open(BASELINE, "w", encoding="utf-8", newline="\n") as f:
            json.dump(got, f, indent=2)
            f.write("\n")
        print("froze baseline to %s" % BASELINE)
        raise SystemExit(0)
    if a.audit:
        rc = audit()
        if a.series:
            import datetime
            os.makedirs(SERIES, exist_ok=True)
            day = datetime.date.today().isoformat()
            p = os.path.join(SERIES, "seo-surface-%s.json" % day)
            with open(p, "w", encoding="utf-8", newline="\n") as f:
                json.dump(collect(), f, indent=2)
                f.write("\n")
            print("wrote %s" % p)
        raise SystemExit(rc)
    ap.print_help()
    raise SystemExit(2)
