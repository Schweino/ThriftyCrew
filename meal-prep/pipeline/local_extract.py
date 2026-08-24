"""Recipe transcription on the LOCAL model, with a checker that proves it.

    python meal-prep/pipeline/local_extract.py --url https://example.com/recipe
    python meal-prep/pipeline/local_extract.py --file page.txt --json
    python meal-prep/pipeline/local_extract.py --from-jsonld --file page.html --url <URL> --json
    python meal-prep/pipeline/local_extract.py --selftest

D6 (2026-08-23) added RUNG 1, `--from-jsonld`, and the ladder it sits at the top of
(PLAN-recipe-hunter-v3 section 3 S3, thresholds in section 4.5):

  rung 1  the page's own JSON-LD Recipe block. Ingredients, instructions and servings are
          PARSED, not transcribed - they are the publisher's machine statement about its own
          recipe. Only the per-line field split (item/qty/unit/prep) needs a model, and that
          sub-task is verifiable line by line: `raw` is the JSON-LD line BY CONSTRUCTION, qty
          and unit must re-substring into it, and the split must round-trip over the line's
          non-glue tokens. ANY failing line sends the WHOLE page to rung 2 - a page whose
          split is untrustworthy on one line is not a page to trust on the other nine.
  rung 2  this file's original full-page transcription at the 85% substring bar.
  rung 3  the Claude extractor, for pages rungs 1 and 2 could not settle. NOT for hours
          nobody started llama-server: a down server is exit 2 BLOCKED, never an escalation,
          because a sweep that quietly promotes every page to a Claude agent because the card
          was idle re-creates the v2 cost structure in one unattended evening.

The JSON-LD parsing is harvest.py's, imported. A third JSON-LD parser in this estate would be
the pu-lib trap with a new face; fetch-recipe.ps1 and harvest.py are already two.

EXIT CODES (section 4.5's convention, and this file now completes the mapping):
  0 settled   1 escalate (the findings case here)   2 could-not-run (server down, no input)

WHY THIS IS SAFE TO RUN LOCALLY, when confirming a price match is not.

Transcription is the task shape the local model measured BEST at: grammar-
constrained structured output scored 1.000 valid strict JSON across thousands
of calls on 2026-08-20. What it measured WORST at is asserting that two things
are the same - 3 of 8 gold NO_MATCH cases came back MATCH at 0.95-0.98
confidence, which is why resolve's layer 5 may only reject. Transcription asks
for neither judgement nor assertion: every field is copied off the page.

And the one damaging failure mode - the extractor's own prompt calls it out,
"the single most damaging thing you can do is produce a plausible recipe" - is
MECHANICALLY CHECKABLE. A transcribed line is honest only if its `raw` text
actually occurs in the page. That is a substring test, not an opinion, so the
model is never trusted: it is verified. Lines that fail verification, and pages
where too many fail, ESCALATE to the Claude extractor rather than being
patched up here. Cheap when it works, loud when it does not.

Contract mirrors .claude/agents/recipe-hunter-extractor.md exactly - raw, item,
qty, unit, prep, optional, section - because the mapping and pricing stages
downstream already speak it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "graph", "lib"))

sys.path.insert(0, HERE)

from llm import LocalLLM                                       # noqa: E402

# D6: the JSON-LD parsers are harvest.py's, imported rather than re-implemented. find_recipe_node,
# ingredient_lines, flatten_instructions, extract_number and parse_yield already exist there with
# fixtures, shape-matched to fetch-recipe.ps1's PowerShell implementations. A third copy in this
# file would be the pu-lib trap with a new face (PLAN v3 section 3 S3, build note 1).
import harvest                                                 # noqa: E402

# Share of lines that must verify before the page is accepted at all. Below
# this the transcription is not "mostly right", it is untrusted: a model that
# invented a fifth of a recipe may have quietly reworded the rest.
MIN_VERIFIED = 0.85

INGREDIENT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["title", "servings", "ingredients", "instructions", "usable"],
    "properties": {
        "usable": {"type": "boolean",
                   "description": "false when the page is a listicle, video-only, "
                                  "paywalled, or has no actual recipe"},
        "unusable_reason": {"type": ["string", "null"]},
        "title": {"type": ["string", "null"]},
        "servings": {"type": ["string", "null"],
                     "description": "AS STATED on the page; null when not stated"},
        "total_time": {"type": ["string", "null"]},
        "ingredients": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["raw", "item", "qty", "unit", "prep", "optional", "section"],
                "properties": {
                    "raw": {"type": "string",
                            "description": "the line EXACTLY as printed, verbatim"},
                    "item": {"type": "string"},
                    "qty": {"type": ["string", "null"]},
                    "unit": {"type": ["string", "null"]},
                    "prep": {"type": ["string", "null"]},
                    "optional": {"type": "boolean"},
                    "section": {"type": ["string", "null"]},
                },
            },
        },
        "instructions": {"type": "array", "items": {"type": "string"}},
    },
}

SYSTEM = (
    "You TRANSCRIBE one recipe page. You are a transcriber, not a cook.\n\n"
    "The single most damaging thing you can do is produce a plausible recipe "
    "instead of the one on the page. Every field is COPIED, never inferred.\n\n"
    "RULES:\n"
    "- `raw` must be the ingredient line character-for-character as printed. It "
    "is checked against the page text; an invented line is caught and rejected.\n"
    "- NEVER convert a unit. '1 stick butter' stays '1 stick butter'.\n"
    "- NEVER invent a measurement. 'salt to taste' -> qty null, unit null, "
    "optional true.\n"
    "- NEVER merge or split lines. Two onion lines stay two lines.\n"
    "- NEVER normalise a plural, spelling or brand toward what you think is wanted.\n"
    "- servings AS STATED, or null. Do not infer it from pan size or volume.\n"
    "- `item` is the food with brand and preparation stripped: 'chicken thighs'.\n"
    "- `prep` is what follows the comma as an instruction: 'diced', 'drained'.\n"
    "- `section` is the sub-recipe heading the line sits under, else null.\n"
    "- If the page is a listicle, video-only, paywalled, or has no recipe, set "
    "usable false and say why in unusable_reason.\n"
    "Output JSON only."
)


def _norm(s: str) -> str:
    """Whitespace/quote/accent-insensitive form for substring checking.

    Deliberately forgiving about PRESENTATION and strict about CONTENT: a page
    may render '1½ cups' with a non-breaking space or a curly apostrophe, and
    failing a true transcription over typography would send honest work to
    Claude. It is not forgiving about words or numbers.
    """
    s = str(s or "")
    # A vulgar fraction is ONE character that NFKD fuses onto the digit before it: "1½" becomes
    # "11/2", which reads as eleven halves and matches nothing a model could sensibly type. Split it
    # off first, so a page's "1½ cups" and a split's "1 1/2" are the same string here.
    s = "".join((" " + unicodedata.normalize("NFKD", c))
                if unicodedata.decomposition(c).startswith("<fraction>") else c for c in s)
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = (s.replace("’", "'").replace("‘", "'")
          .replace("“", '"').replace("”", '"')
          .replace("–", "-").replace("—", "-")
          # NFKD turns a vulgar fraction into a FRACTION SLASH (U+2044), not an ASCII one, so
          # a model's "1 1/2" would never match the page's "1 1/2" without this line.
          .replace("⁄", "/"))
    return re.sub(r"\s+", " ", s).strip().lower()


def verify(result: dict, page_text: str) -> dict:
    """Prove each transcribed line occurs in the page. No model involved."""
    hay = _norm(page_text)
    lines = result.get("ingredients") or []
    ok, bad = [], []
    for ing in lines:
        raw = _norm(ing.get("raw"))
        # A bare fragment proves nothing; require some substance before crediting.
        if len(raw) >= 4 and raw in hay:
            ok.append(ing)
        else:
            bad.append(ing)
    total = len(lines)
    rate = len(ok) / total if total else 0.0
    return {
        "lines": total,
        "verified": len(ok),
        "unverified": len(bad),
        "verified_rate": round(rate, 4),
        "unverified_lines": [b.get("raw") for b in bad][:10],
        # An empty ingredient list is a failure, not a clean pass.
        "passed": bool(total) and rate >= MIN_VERIFIED,
    }


# =====================================================================================================
# RUNG 1 - the page's own JSON-LD, split per line by the local model and proven line by line
# (PLAN-recipe-hunter-v3 section 3 S3 + section 4.5's "Local line-split acceptance")
# =====================================================================================================

SPLIT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["item", "qty", "unit", "prep", "optional", "section"],
    "properties": {
        "item": {"type": "string", "description": "the food itself, in the line's own words"},
        "qty": {"type": ["string", "null"], "description": "the amount AS PRINTED, or null"},
        "unit": {"type": ["string", "null"], "description": "the unit AS PRINTED, or null"},
        "prep": {"type": ["string", "null"]},
        "optional": {"type": "boolean"},
        "section": {"type": ["string", "null"]},
    },
}

# `raw` is deliberately ABSENT from that schema. In rung 1 the raw line is the publisher's own
# machine statement and is copied in by construction, so there is no invented-line failure mode
# here at all - the model is never in a position to author it. Rung 2 still asks for `raw` and
# still checks it against the page, because there the model IS the only reader of the page.
# THE PROMPT IS PART OF THE THRESHOLD, and this wording was earned by measurement.
#
# The first draft said item was "the food itself, brand and preparation stripped" and said nothing
# about the trailing parentheticals publishers put in their own JSON-LD. Measured on a 7-publisher
# pilot (2026-08-23), that settled 1 page in 7: the model obediently STRIPPED "small" from "small
# onion", "extra virgin" from "extra virgin olive oil", "divided" from a cheese line, and dropped
# "(or gluten-free flour mix)" and "(at least 3/4-inch thick, about 2 pounds)" entirely - and every
# one of those is a word the round-trip check is right to demand back. The check was not too strict;
# the instruction was telling the model to throw material away. So the prompt now states the rule
# the checker actually enforces: every word of the line lands SOMEWHERE.
SPLIT_SYSTEM = (
    "You split ONE printed ingredient line into fields. You copy; you never convert, "
    "normalise, or invent.\n"
    "- qty: the amount EXACTLY as printed ('1 1/2', '2 to 3', '1/2'), or null when the line "
    "states none. It is checked as a substring of the line.\n"
    "- unit: the unit EXACTLY as printed ('cup', 'Tbsp', 'lb.', 'clove', 'can', 'oz.'), or "
    "null. Also checked as a substring. Never expand an abbreviation.\n"
    "- item: the food as the line names it, KEEPING every describing word - size ('small', "
    "'large'), cut ('boneless', 'bone-in'), grade ('extra virgin', 'low fat'), form ('shredded', "
    "'grated', 'riced'), variety ('elbow', 'panko'). Drop ONLY a brand name.\n"
    "- prep: everything else the line says - what to do to it ('diced', 'drained', 'divided'), "
    "and the WHOLE of any note in brackets ('see notes', 'or gluten-free flour mix', 'at least "
    "3/4-inch thick, about 2 pounds'). Null only when the line says nothing beyond the food.\n"
    "- optional: true when the line says optional, 'to taste', 'for serving', 'for topping', or "
    "'for garnish' - and the words that say so still go in prep, because the flag is not a place "
    "to put words.\n"
    "- section: the sub-recipe heading the line carries, else null.\n"
    "A bracketed PRICE like ($0.16) is the publisher's own cost note, not part of the food. "
    "Leave it out of every field.\n"
    "EVERY WORD of the line must appear in one of these fields, apart from glue words like "
    "'of', 'the', 'and', 'or', 'to' and 'for'. A word you leave out of all of them is a word you "
    "have deleted from the recipe, and the checker will send this page back. Output JSON only."
)

# THE COVERAGE ALLOWANCE, and it is LOCAL TO THIS CHECK ON PURPOSE.
#
# Section 4.5: "qty+unit+item+prep must jointly cover >=90% of raw's non-stopword tokens". These
# are the glue words a correct split legitimately drops. This list is NOT find-similar's STOP list
# and must never import it: that list exists to kill name-identity noise and deliberately swallows
# words like "chicken", which a split must never be excused from covering. Two lists, two jobs;
# sharing them would quietly excuse the exact omissions this check exists to catch.
COVERAGE_STOP = frozenset(("of", "the", "a", "and", "or", "to", "into", "for", "plus"))

COVERAGE_MIN = 0.90

# The words that state optionality, and therefore the words the `optional` boolean accounts for.
# Deliberately short: these are the exact signals the split prompt names.
OPTIONAL_WORDS = frozenset(("optional", "taste", "garnish", "desired"))

# ONE annotation is struck from the line before it is counted, and only this one: a bracketed
# CURRENCY amount. Budget Bytes prints its own per-ingredient cost inside its JSON-LD lines
# ("2 cloves garlic ($0.16)"), and $0.16 is not a property of the garlic - it is the publisher
# talking about its grocery bill. MEASURED 2026-08-23: it fails 17 of 17 lines on a budgetbytes
# page, i.e. every page from that publisher, and the only way for a split to "cover" it would be
# to stuff a dollar amount into prep, where the mapper and the pricer would then read it as
# something the recipe says about the food. Excusing it is strictly better than demanding it.
# This is an ANNOTATION rule, not a stopword: it removes a bracketed price, never a word.
_PRICE_ANNOTATION = re.compile(r"\(\s*\$\s*[\d.,]+\s*\)")

_TOKEN = re.compile(r"[a-z0-9]+(?:[./][a-z0-9]+)*")


def _cov_tokens(s: str) -> list:
    """Content tokens of a normalised string. Punctuation-only fragments never survive the
    pattern, so they need no separate exclusion."""
    text = _PRICE_ANNOTATION.sub(" ", _norm(s))
    return [t for t in _TOKEN.findall(text) if t not in COVERAGE_STOP]


def verify_split(raw: str, fields: dict) -> dict:
    """Rung 1's per-line proof. No page needed: `raw` IS the page's own statement.

    Three tests, all mechanical, all from section 4.5:
      1. qty, when stated, re-substrings into raw verbatim (after typography normalisation).
      2. unit likewise. An expanded abbreviation ('tablespoon' for 'Tbsp') fails here, which is
         the point - the engine owns unit conversion and a helpful expansion overrides it.
      3. round-trip: qty + unit + item + prep jointly cover >=90% of raw's non-glue tokens. This
         is the test that catches a split which quietly DROPS half a line ("boneless skinless"),
         because a dropped word substrings nothing and would otherwise pass tests 1 and 2.
    """
    reasons = []
    hay = _norm(raw)
    for name in ("qty", "unit"):
        v = fields.get(name)
        if v is None or str(v).strip() == "":
            continue
        if _norm(v) not in hay:
            reasons.append("%s %r is not in the line" % (name, str(v)))
    want = _cov_tokens(raw)
    have = set()
    for name in ("qty", "unit", "item", "prep"):
        have.update(_cov_tokens(fields.get(name) or ""))
    # A BOOLEAN COVERS THE WORDS THAT SET IT. MEASURED 2026-08-23: the only escalation left in the
    # 7-publisher pilot after the prompt fix was "1/4 teaspoon cayenne pepper (optional)", where the
    # model read the line perfectly - optional TRUE - and the round-trip then failed it for not
    # ALSO writing the word "optional" into a text field. The line was fully transcribed; the
    # covering set was just looking in four fields when the answer was in a fifth. Note the
    # direction: this only ever excuses the word when the flag is SET. A line that says "(optional)"
    # while the model returns optional false still fails, because then the word really was dropped.
    if fields.get("optional"):
        have.update(OPTIONAL_WORDS)
    covered = [t for t in want if t in have]
    rate = (len(covered) / len(want)) if want else 0.0
    if not want:
        reasons.append("the line has no content tokens to cover")
    elif rate < COVERAGE_MIN:
        missed = [t for t in want if t not in have]
        reasons.append("round-trip covered %.0f%% of the line (bar %.0f%%); dropped %s"
                       % (100 * rate, 100 * COVERAGE_MIN, ", ".join(missed[:6])))
    return {"ok": not reasons, "coverage": round(rate, 4), "reasons": reasons}


def split_line(raw: str, llm: LocalLLM) -> dict:
    """One grammar-forced field split. Short prompt, short answer - this is the call shape the
    box measured at 2.74 s, and the shape that fans across all four slots."""
    parsed, _res = llm.json_call(SPLIT_SYSTEM, "LINE: %s" % raw, schema=SPLIT_SCHEMA,
                                 max_tokens=256)
    return parsed if isinstance(parsed, dict) else {}


def _iso_duration(v):
    """'PT1H15M' -> '1 hour 15 minutes'. Mechanical and lossless: JSON-LD states durations in
    ISO 8601 and the intake head wants them readable. Anything that is not an ISO duration is
    passed through verbatim - this formats, it never guesses."""
    if v is None:
        return None
    s = str(v).strip()
    if not s:
        return None
    m = re.fullmatch(r"P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", s, re.I)
    if not m:
        return s
    d, h, mi, _sec = (int(x) if x else 0 for x in m.groups())
    h += d * 24
    parts = []
    if h:
        parts.append("%d hour%s" % (h, "" if h == 1 else "s"))
    if mi:
        parts.append("%d minute%s" % (mi, "" if mi == 1 else "s"))
    return " ".join(parts) if parts else s


def extract_from_jsonld(html: str, url: str | None = None, llm: LocalLLM | None = None,
                        pool=None, splitter=None) -> dict:
    """RUNG 1. Returns the same {extraction, verification, escalate, ...} envelope rung 2 does.

    `pool` is an existing ThreadPoolExecutor (jobs <= serve.ps1 -Slots); `splitter` is the
    per-line callable, injected so the fixtures can prove the verifier without the GPU.
    """
    node = harvest.recipe_jsonld(html or "")
    if node is None:
        return _rung1_miss("no JSON-LD Recipe block on this page")
    lines = harvest.ingredient_lines(node)
    if not lines:
        return _rung1_miss("the JSON-LD Recipe block states no recipeIngredient lines")

    call = splitter or (lambda raw: split_line(raw, llm or LocalLLM(timeout=180)))
    if pool is not None:
        fields = list(pool.map(call, lines))
    else:
        fields = [call(x) for x in lines]

    ings, failures = [], []
    for raw, f in zip(lines, fields):
        f = f if isinstance(f, dict) else {}
        chk = verify_split(raw, f)
        ings.append({
            # BY CONSTRUCTION. Whatever the model returned for a raw-like field is discarded:
            # the publisher's line is the line.
            "raw": raw,
            "item": (f.get("item") or "").strip(),
            "qty": f.get("qty") or None,
            "unit": f.get("unit") or None,
            "prep": f.get("prep") or None,
            "optional": bool(f.get("optional")),
            "section": f.get("section") or None,
        })
        if not chk["ok"]:
            # `coverage` rides along because the daemon's retry rule keys on it (the D9 pin:
            # retry once when the ONE failing line was a near-miss at >=0.85). Without it here,
            # the rule would have to re-run the verifier to learn a number it already computed.
            failures.append({"raw": raw, "coverage": chk["coverage"], "reasons": chk["reasons"]})

    total = len(lines)
    good = total - len(failures)
    check = {
        # The section 4.5 block: the same six keys with the same meanings as rung 2's, so
        # downstream code does not care which rung settled a page. `bar` and `failures` are
        # additions, not a second shape - rung 1's bar is ALL lines, not 85% of them.
        "lines": total,
        "verified": good,
        "unverified": len(failures),
        "verified_rate": round(good / total, 4) if total else 0.0,
        "unverified_lines": [f["raw"] for f in failures][:10],
        "passed": bool(total) and not failures,
        "bar": "every line (rung 1)",
        "failures": failures[:10],
    }
    name = node.get("name")
    extraction = {
        "usable": True,
        "unusable_reason": None,
        "title": name if isinstance(name, str) and name.strip() else None,
        "servings": harvest.parse_yield(node.get("recipeYield")),
        "total_time": _iso_duration(node.get("totalTime")),
        "active_time": _iso_duration(node.get("prepTime")),
        "ingredients": ings,
        "instructions": harvest.flatten_instructions(node.get("recipeInstructions")),
    }
    return {
        "extraction": extraction,
        "verification": check,
        "model": "local (per-line split)",
        "tokens": 0,
        "rung": 1,
        "extracted_by": "jsonld-local",
        "escalate": not check["passed"],
        "escalate_reason": (
            None if check["passed"] else
            "%d of %d JSON-LD ingredient lines failed the split check: %s"
            % (len(failures), total,
               "; ".join("%s -> %s" % (f["raw"][:60], f["reasons"][0]) for f in failures[:3]))),
    }


def _rung1_miss(reason: str) -> dict:
    """Rung 1 does not APPLY to this page. That is an escalation to rung 2, not a failure of
    anything, and emphatically not a could-not-run."""
    return {
        "extraction": {"usable": False, "unusable_reason": reason, "title": None,
                       "servings": None, "total_time": None, "active_time": None,
                       "ingredients": [], "instructions": []},
        "verification": {"lines": 0, "verified": 0, "unverified": 0, "verified_rate": 0.0,
                         "unverified_lines": [], "passed": False,
                         "bar": "every line (rung 1)", "failures": []},
        "model": None, "tokens": 0, "rung": 1, "extracted_by": "jsonld-local",
        "escalate": True, "escalate_reason": reason,
    }


# =====================================================================================================
# THE ONE EXTRACTION CONTRACT (section 4.5), regardless of which rung settled the page
# =====================================================================================================

def to_contract(out: dict, url: str = None, title_hint: str = None) -> dict:
    """The `<RunDir>\\extracted\\<slug>.json` document. The same shape the Claude extractor
    returns, plus `extracted_by` and the verifier's block, so nothing downstream has to ask
    which rung settled the page."""
    e = out.get("extraction") or {}
    v = out.get("verification") or {}
    settled = not out.get("escalate")
    servings = e.get("servings")
    if isinstance(servings, str):
        servings = servings.strip() or None
    return {
        "state": "ok" if settled else "escalate",
        "reason": None if settled else out.get("escalate_reason"),
        "title": e.get("title") or title_hint,
        "source_url": url,
        "servings": servings,
        "time_total": e.get("total_time"),
        "time_active": e.get("active_time"),
        "ingredients": [{k: i.get(k) for k in
                         ("raw", "item", "qty", "unit", "prep", "optional", "section")}
                        for i in (e.get("ingredients") or [])],
        "instructions": list(e.get("instructions") or []),
        "concerns": list(e.get("concerns") or []),
        "extracted_by": out.get("extracted_by"),
        "verification": v,
    }


# RUNG 2's CONTEXT BUDGET, and the reason it is a constant rather than a hope.
#
# serve.ps1's `-c 16384` is the TOTAL KV budget and llama.cpp SPLITS it across `--parallel`
# slots, so the default 4 slots give each caller 4,096 tokens. Rung 2 sends ~24k chars of page
# (~6.5k tokens) and asks for 4,096 back: ~11k, which does not fit a 4,096-token slot. The
# failure mode if it is attempted anyway is the dangerous one - the page is truncated at the slot
# ceiling, the model transcribes what it was given, and every line it DID return substrings
# cleanly, so the verifier passes a recipe that is quietly missing its last five ingredients.
# Substring verification proves what is there; it cannot prove what is absent. So the budget is
# checked BEFORE the call and a slot too small is a named BLOCK (exit 2), never a short read.
RUNG2_OUT_TOKENS = 4096
RUNG2_PAGE_CHARS = 24000
RUNG2_CHARS_PER_TOKEN = 3.5          # conservative for tag-stripped English recipe prose
RUNG2_MIN_SLOT_CTX = int(RUNG2_OUT_TOKENS + RUNG2_PAGE_CHARS / RUNG2_CHARS_PER_TOKEN + 512)


def slot_context(llm: LocalLLM | None = None) -> int | None:
    """Tokens available to ONE slot, read from llama-server rather than assumed.

    /props reports the per-slot context of the running server, which is the only honest source:
    -c and --parallel are start-time flags nothing downstream can see.
    """
    import urllib.request                                       # noqa: PLC0415
    llm = llm or LocalLLM(timeout=10)
    base = llm.endpoint.rsplit("/v1", 1)[0]
    try:
        with urllib.request.urlopen(base + "/props", timeout=10) as r:
            props = json.loads(r.read().decode("utf-8", "replace"))
    except Exception:
        return None
    for path in (("default_generation_settings", "n_ctx"), ("n_ctx",)):
        node = props
        for key in path:
            node = node.get(key) if isinstance(node, dict) else None
        if isinstance(node, int) and node > 0:
            return node
    return None


def extract(page_text: str, url: str | None = None,
            llm: LocalLLM | None = None, max_chars: int = RUNG2_PAGE_CHARS) -> dict:
    # 600 s explicitly: this is the one caller that asks for 4096 tokens from a 24k-char page.
    # LocalLLM's default dropped to 120 s on 2026-08-22 for every short structured call; a full
    # recipe transcription can legitimately run several minutes, so it keeps the long bound here.
    llm = llm or LocalLLM(timeout=600)
    # Long pages: keep the head, where recipe cards live, but generously.
    body = page_text if len(page_text) <= max_chars else page_text[:max_chars]
    user = (f"SOURCE URL: {url}\n\n" if url else "") + \
           f"PAGE TEXT:\n{body}\n\nTranscribe the recipe."
    parsed, res = llm.json_call(SYSTEM, user, schema=INGREDIENT_SCHEMA,
                                max_tokens=RUNG2_OUT_TOKENS)
    check = verify(parsed, page_text)
    return {
        "extraction": parsed,
        "verification": check,
        "model": res.model,
        "tokens": res.completion_tokens,
        "rung": 2,
        "extracted_by": "local-page",
        "escalate": not check["passed"] or not parsed.get("usable", False),
        "escalate_reason": (
            parsed.get("unusable_reason") if not parsed.get("usable", False)
            else None if check["passed"] else
            f"only {check['verified']}/{check['lines']} ingredient lines "
            f"({check['verified_rate']:.0%}) were found verbatim in the page; "
            f"below the {MIN_VERIFIED:.0%} bar this transcription is untrusted"),
    }


SERVER_DOWN = (
    "local-extract: BLOCKED. llama-server is not answering at %s.\n"
    "  Start it by hand (section 4.4: the card is hand-held; nightly.ps1 owns 21:30-06:30 and a\n"
    "  hunt run must be off the card before the 07:00 ad pull), then run this again:\n"
    "      pwsh tools/local-llm/serve.ps1\n"
    "  Nothing was extracted. A down server is NOT an escalation to the Claude extractor - rung 3\n"
    "  exists for pages the local pass failed on, not for hours nobody started the server."
)


def page_text_from_html(html: str) -> str:
    """The rung-2 view of a page: tags out, text kept. Rung 1 needs the raw HTML instead, because
    the JSON-LD lives inside a <script> block this strips."""
    text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", html, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", "\n", text)
    return re.sub(r"\n{2,}", "\n", text)


def _read_input(args, ap):
    """Returns (raw_html_or_text, url). --file is read verbatim so rung 1 can see the JSON-LD."""
    if args.file:
        with open(args.file, encoding="utf-8-sig", errors="replace") as fh:
            return fh.read(), args.url
    if args.url:
        import urllib.request                                   # noqa: PLC0415
        req = urllib.request.Request(args.url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read().decode("utf-8", "replace"), args.url
    ap.error("pass --url or --file")


def main() -> int:
    ap = argparse.ArgumentParser(description="Local recipe transcription + verification")
    ap.add_argument("--url", help="fetch this page (or just name it, with --file)")
    ap.add_argument("--file", help="read the page from a file instead")
    ap.add_argument("--from-jsonld", dest="from_jsonld", action="store_true",
                    help="RUNG 1: parse the page's JSON-LD and split each line locally")
    ap.add_argument("--jobs", type=int, default=4,
                    help="rung-1 line splits in flight; coupled to serve.ps1 -Slots")
    ap.add_argument("--out", help="write the section 4.5 extraction contract to this path")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    raw, url = _read_input(args, ap)

    llm = LocalLLM(timeout=600)
    if not llm.health():
        print(SERVER_DOWN % llm.endpoint, file=sys.stderr)
        print("LOCAL-EXTRACT-COMPLETE")
        return 2

    if args.from_jsonld:
        from concurrent.futures import ThreadPoolExecutor        # noqa: PLC0415
        jobs = max(1, int(args.jobs))
        split_llm = LocalLLM(timeout=180)
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            out = extract_from_jsonld(raw, url, split_llm, pool=pool)
    else:
        ctx = slot_context(llm)
        if ctx is not None and ctx < RUNG2_MIN_SLOT_CTX:
            print(("local-extract: BLOCKED. This server gives each slot %d tokens and rung 2 needs "
                   "~%d\n  (a %d-char page plus %d output). -c is the TOTAL KV budget and llama.cpp "
                   "splits it\n  across --parallel slots, so restart narrow for full-page work:\n"
                   "      pwsh tools/local-llm/serve.ps1 -Slots 1\n"
                   "  Refusing rather than truncating: a page cut at the slot ceiling still "
                   "substring-verifies\n  line by line, so a short read would pass the checker "
                   "with ingredients silently missing.")
                  % (ctx, RUNG2_MIN_SLOT_CTX, RUNG2_PAGE_CHARS, RUNG2_OUT_TOKENS), file=sys.stderr)
            print("LOCAL-EXTRACT-COMPLETE")
            return 2
        out = extract(page_text_from_html(raw) if args.file or args.url else raw, url, llm)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(to_contract(out, url), fh, indent=2, ensure_ascii=False)

    if args.json:
        print(json.dumps(out, indent=2, ensure_ascii=False))
        print("LOCAL-EXTRACT-COMPLETE")
        return 1 if out["escalate"] else 0

    e, v = out["extraction"], out["verification"]
    print(f"\n  title     {e.get('title')}")
    print(f"  servings  {e.get('servings')}")
    print(f"  rung      {out.get('rung')}  ({out.get('extracted_by')})")
    print(f"  lines     {v['lines']}   verified {v['verified']} "
          f"({v['verified_rate']:.0%})   model {out['model']}")
    for ing in (e.get("ingredients") or [])[:8]:
        opt = "  (optional)" if ing.get("optional") else ""
        print(f"    {str(ing.get('qty') or ''):>7} {str(ing.get('unit') or ''):<8} "
              f"{ing.get('item')}{opt}")
    if out["escalate"]:
        print(f"\n  ESCALATE -> next rung: {out['escalate_reason']}")
        for b in v["unverified_lines"]:
            print(f"    unverified: {b!r}")
    else:
        print("\n  VERIFIED - every line traced to the page; no Claude call needed.")
    print("LOCAL-EXTRACT-COMPLETE")
    return 1 if out["escalate"] else 0


# =====================================================================================================
# FIXTURES. Every one of them runs without the GPU: the per-line splitter is injected, so what is
# under test is the VERIFIER, which is the part that decides whether a page is trusted.
# =====================================================================================================

def _page(lines, name="Test Skillet", yld="4", extra=""):
    node = {"@context": "https://schema.org", "@type": "Recipe", "name": name,
            "recipeYield": yld, "recipeIngredient": lines,
            "recipeInstructions": [{"@type": "HowToStep", "text": "Cook it."}]}
    if extra:
        node["totalTime"] = extra
    return ('<html><head><script type="application/ld+json">' + json.dumps(node) +
            "</script></head><body><p>prose</p></body></html>")


def selftest() -> int:
    import subprocess                                           # noqa: PLC0415
    import tempfile                                             # noqa: PLC0415
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    # ---- the parsers are harvest's, not a third copy -------------------------------------------
    T("the JSON-LD parsers are harvest.py's, imported (no third parser in this estate)",
      extract_from_jsonld.__globals__["harvest"].find_recipe_node.__module__ == "harvest",
      extract_from_jsonld.__globals__["harvest"].find_recipe_node.__module__)

    # ---- rung 2: the invented-line check that has always been this file's point ------------------
    page = "1 lb chicken thighs\n2 cups rice\n1 tsp salt"
    honest = {"ingredients": [{"raw": "1 lb chicken thighs"}, {"raw": "2 cups rice"},
                              {"raw": "1 tsp salt"}]}
    invented = {"ingredients": [{"raw": "1 lb chicken thighs"}, {"raw": "2 cups rice"},
                                {"raw": "1 cup heavy cream"}]}
    T("CLEAN TWIN a true transcription verifies against the page", verify(honest, page)["passed"])
    T("MUST FIRE  an invented line fails the substring check",
      verify(invented, page)["unverified"] == 1 and not verify(invented, page)["passed"],
      json.dumps(verify(invented, page)))

    # ---- rung 1: the three tests of section 4.5 --------------------------------------------------
    raw = "1 1/2 lb boneless skinless chicken thighs, diced"
    good = {"qty": "1 1/2", "unit": "lb", "item": "boneless skinless chicken thighs",
            "prep": "diced", "optional": False, "section": None}
    T("CLEAN TWIN a faithful split passes all three rung-1 tests",
      verify_split(raw, good)["ok"], json.dumps(verify_split(raw, good)))

    dropped = dict(good, item="chicken thighs")
    T("MUST FIRE  a split that DROPS tokens fails the round-trip check",
      not verify_split(raw, dropped)["ok"], json.dumps(verify_split(raw, dropped)))

    T("MUST FIRE  a qty that is not in the line is refused",
      not verify_split(raw, dict(good, qty="2"))["ok"],
      json.dumps(verify_split(raw, dict(good, qty="2"))))
    T("MUST FIRE  an EXPANDED unit is refused - the engine owns unit conversion",
      not verify_split("2 Tbsp olive oil", {"qty": "2", "unit": "tablespoons",
                                            "item": "olive oil", "prep": None})["ok"],
      "accepted 'tablespoons' for 'Tbsp'")
    T("CLEAN TWIN the unit as printed passes",
      verify_split("2 Tbsp olive oil", {"qty": "2", "unit": "Tbsp", "item": "olive oil",
                                        "prep": None})["ok"])
    T("a stated-amount-free line is fine with null qty/unit",
      verify_split("salt and pepper to taste",
                   {"qty": None, "unit": None, "item": "salt and pepper",
                    "prep": "to taste"})["ok"])
    T("typography does not fail an honest split: a vulgar fraction matches '1 1/2'",
      verify_split("1\u00bd cups milk", {"qty": "1 1/2", "unit": "cups", "item": "milk",
                                          "prep": None})["ok"],
      json.dumps(verify_split("1\u00bd cups milk", {"qty": "1 1/2", "unit": "cups",
                                                     "item": "milk", "prep": None})))

    # ---- the coverage allowance is LOCAL and is not find-similar's STOP list ----------------------
    T("the coverage allowance holds only glue words", COVERAGE_STOP == frozenset(
        ("of", "the", "a", "and", "or", "to", "into", "for", "plus")), ",".join(sorted(COVERAGE_STOP)))
    T("MUST FIRE  'chicken' is NOT excusable - importing find-similar's STOP list would excuse it",
      "chicken" not in COVERAGE_STOP and not verify_split(
          "1 lb chicken", {"qty": "1", "unit": "lb", "item": "", "prep": None})["ok"],
      "a split dropping the food itself passed")
    T("a publisher's bracketed PRICE is struck from the line, not demanded of the split",
      verify_split("2 cloves garlic ($0.16)",
                   {"qty": "2", "unit": "cloves", "item": "garlic", "prep": None})["ok"],
      json.dumps(verify_split("2 cloves garlic ($0.16)",
                              {"qty": "2", "unit": "cloves", "item": "garlic", "prep": None})))
    T("MUST FIRE  the price rule strikes a PRICE only - a bracketed note is still demanded",
      not verify_split("2 tablespoons flour (or gluten-free flour mix)",
                       {"qty": "2", "unit": "tablespoons", "item": "flour", "prep": None})["ok"],
      "a bracketed note was excused")
    T("the `optional` flag covers the word that sets it - the line IS fully transcribed",
      verify_split("1/4 teaspoon cayenne pepper (optional)",
                   {"qty": "1/4", "unit": "teaspoon", "item": "cayenne pepper", "prep": None,
                    "optional": True})["ok"],
      json.dumps(verify_split("1/4 teaspoon cayenne pepper (optional)",
                              {"qty": "1/4", "unit": "teaspoon", "item": "cayenne pepper",
                               "prep": None, "optional": True})))
    T("MUST FIRE  and only when the flag is SET - an unset flag means the word was dropped",
      not verify_split("1/4 teaspoon cayenne pepper (optional)",
                       {"qty": "1/4", "unit": "teaspoon", "item": "cayenne pepper", "prep": None,
                        "optional": False})["ok"],
      "a dropped '(optional)' was excused with the flag unset")
    T("CLEAN TWIN glue words a correct split drops do not fail it",
      verify_split("1 can of diced tomatoes",
                   {"qty": "1", "unit": "can", "item": "diced tomatoes", "prep": None})["ok"])

    # ---- ANY failing line sends the WHOLE page to rung 2 -----------------------------------------
    ten = ["%d cup rice" % (i + 1) for i in range(9)] + ["1 lb chicken thighs"]

    def faithful(line):
        m = re.match(r"([\d /]+) (cup|lb) (.+)", line)
        return {"qty": m.group(1).strip(), "unit": m.group(2), "item": m.group(3),
                "prep": None, "optional": False, "section": None}

    clean = extract_from_jsonld(_page(ten), "u", splitter=faithful)
    T("CLEAN TWIN ten faithful splits settle the page at rung 1",
      clean["verification"]["passed"] and not clean["escalate"],
      json.dumps(clean["verification"]))

    def one_bad(line):
        f = faithful(line)
        return dict(f, item="") if line.endswith("chicken thighs") else f

    dirty = extract_from_jsonld(_page(ten), "u", splitter=one_bad)
    T("MUST FIRE  ONE failing line of ten sends the WHOLE page to rung 2",
      dirty["escalate"] and dirty["verification"]["unverified"] == 1
      and dirty["verification"]["verified"] == 9,
      json.dumps(dirty["verification"]))
    T("  and the escalation names the line and the reason it failed",
      "chicken" in (dirty["escalate_reason"] or ""), str(dirty["escalate_reason"]))
    T("  and each failures[] entry carries the line's coverage - the daemon's retry rule keys on it",
      isinstance(dirty["verification"]["failures"][0].get("coverage"), float),
      json.dumps(dirty["verification"]["failures"][0]))

    # ---- raw is BY CONSTRUCTION: the model cannot author it ---------------------------------------
    liar = extract_from_jsonld(
        _page(["1 lb chicken thighs"]), "u",
        splitter=lambda l: {"raw": "1 lb wagyu ribeye", "qty": "1", "unit": "lb",
                            "item": "chicken thighs", "prep": None})
    T("MUST FIRE  a model-authored `raw` is DISCARDED - rung 1 copies the publisher's line",
      liar["extraction"]["ingredients"][0]["raw"] == "1 lb chicken thighs",
      liar["extraction"]["ingredients"][0]["raw"])

    # ---- rung 1 does not apply: escalate to rung 2, never could-not-run ---------------------------
    miss = extract_from_jsonld("<html><body>no structured data</body></html>", "u",
                               splitter=faithful)
    T("a page with no JSON-LD escalates to rung 2 (it is not a could-not-run)",
      miss["escalate"] and "no JSON-LD" in miss["escalate_reason"], str(miss["escalate_reason"]))
    T("CLEAN TWIN an empty recipeIngredient list escalates too, and does not crash",
      extract_from_jsonld(_page([]), "u", splitter=faithful)["escalate"])

    # ---- the one contract, whichever rung settled it ----------------------------------------------
    c = to_contract(clean, "https://example.com/x", title_hint="Fallback")
    T("the section 4.5 contract carries every named field",
      all(k in c for k in ("state", "reason", "title", "source_url", "servings", "time_total",
                           "time_active", "ingredients", "instructions", "concerns",
                           "extracted_by", "verification")), ",".join(sorted(c)))
    T("a settled rung-1 page is stamped extracted_by jsonld-local, state ok",
      c["extracted_by"] == "jsonld-local" and c["state"] == "ok", json.dumps(c)[:200])
    T("MUST FIRE  ZERO unverified lines are in a settled contract",
      c["verification"]["unverified"] == 0 and c["verification"]["passed"])
    T("every ingredient in the contract carries the seven agreed fields",
      all(sorted(i) == ["item", "optional", "prep", "qty", "raw", "section", "unit"]
          for i in c["ingredients"]), json.dumps(c["ingredients"][:1]))
    T("servings comes from parse_yield, so an ambiguous yield is null rather than a guess",
      to_contract(extract_from_jsonld(_page(["1 cup rice"], yld="6-8"), "u",
                                      splitter=faithful), "u")["servings"] is None)

    # ---- ISO durations format, they never guess ---------------------------------------------------
    T("'PT1H15M' formats as '1 hour 15 minutes'", _iso_duration("PT1H15M") == "1 hour 15 minutes",
      str(_iso_duration("PT1H15M")))
    T("'PT45M' formats as '45 minutes'", _iso_duration("PT45M") == "45 minutes",
      str(_iso_duration("PT45M")))
    T("a non-ISO time string passes through verbatim, never reinterpreted",
      _iso_duration("about an hour") == "about an hour", str(_iso_duration("about an hour")))

    # ---- the rung-2 context budget ----------------------------------------------------------------
    T("rung 2's slot requirement exceeds a 4-slot split of serve.ps1's default -c 16384",
      RUNG2_MIN_SLOT_CTX > 16384 // 4, str(RUNG2_MIN_SLOT_CTX))
    T("  and fits a 1-slot server at the same total budget",
      RUNG2_MIN_SLOT_CTX <= 16384, str(RUNG2_MIN_SLOT_CTX))

    # ---- END-TO-END DRILL: a down server is exit 2 BLOCKED, never a silent escalation -------------
    td = tempfile.mkdtemp(prefix="lex-drill-")
    pg = os.path.join(td, "page.html")
    with open(pg, "w", encoding="utf-8") as fh:
        fh.write(_page(["1 lb chicken thighs"]))
    env = dict(os.environ, TC_LLM_ENDPOINT="http://127.0.0.1:59117/v1")
    out_path = os.path.join(td, "contract.json")
    r = subprocess.run([sys.executable, os.path.abspath(__file__), "--from-jsonld",
                        "--file", pg, "--url", "https://example.com/x", "--out", out_path,
                        "--json"], capture_output=True, text=True, env=env, timeout=180)
    blob = (r.stdout or "") + (r.stderr or "")
    T("DRILL     a down llama-server exits 2 (could-not-run), not 1 (escalate)",
      r.returncode == 2, "exit %s" % r.returncode)
    T("DRILL     and it NAMES the server and how to start it",
      "llama-server" in blob and "serve.ps1" in blob, blob[:200])
    T("DRILL     and it writes NO extraction - a blocked rung settles nothing",
      not os.path.exists(out_path), "wrote %s" % out_path)
    T("DRILL     the completion marker is printed even when blocked",
      "LOCAL-EXTRACT-COMPLETE" in blob, blob[-120:])

    print("")
    if bad:
        print("local_extract selftest: %d FAILED - %s" % (len(bad), "; ".join(bad[:4])))
        print("LOCAL-EXTRACT-COMPLETE")
        return 1
    print("local_extract selftest: all green")
    print("LOCAL-EXTRACT-COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
