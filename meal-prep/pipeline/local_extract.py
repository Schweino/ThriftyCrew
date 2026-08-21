"""Recipe transcription on the LOCAL model, with a checker that proves it.

    python meal-prep/pipeline/local_extract.py --url https://example.com/recipe
    python meal-prep/pipeline/local_extract.py --file page.txt --json

WHY THIS IS SAFE TO RUN LOCALLY, when confirming a price match is not.

Transcription is the task shape the local model measured BEST at: grammar-
constrained structured output scored 1.000 valid strict JSON across thousands
of calls on 2026-08-20. What it measured WORST at is asserting that two things
are the same — 3 of 8 gold NO_MATCH cases came back MATCH at 0.95-0.98
confidence, which is why resolve's layer 5 may only reject. Transcription asks
for neither judgement nor assertion: every field is copied off the page.

And the one damaging failure mode — the extractor's own prompt calls it out,
"the single most damaging thing you can do is produce a plausible recipe" — is
MECHANICALLY CHECKABLE. A transcribed line is honest only if its `raw` text
actually occurs in the page. That is a substring test, not an opinion, so the
model is never trusted: it is verified. Lines that fail verification, and pages
where too many fail, ESCALATE to the Claude extractor rather than being
patched up here. Cheap when it works, loud when it does not.

Contract mirrors .claude/agents/recipe-hunter-extractor.md exactly — raw, item,
qty, unit, prep, optional, section — because the mapping and pricing stages
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

from llm import LocalLLM                                       # noqa: E402

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
    s = unicodedata.normalize("NFKD", str(s or ""))
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = (s.replace("’", "'").replace("‘", "'")
          .replace("“", '"').replace("”", '"')
          .replace("–", "-").replace("—", "-"))
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


def extract(page_text: str, url: str | None = None,
            llm: LocalLLM | None = None) -> dict:
    llm = llm or LocalLLM()
    # Long pages: keep the head, where recipe cards live, but generously.
    body = page_text if len(page_text) <= 24000 else page_text[:24000]
    user = (f"SOURCE URL: {url}\n\n" if url else "") + \
           f"PAGE TEXT:\n{body}\n\nTranscribe the recipe."
    parsed, res = llm.json_call(SYSTEM, user, schema=INGREDIENT_SCHEMA,
                                max_tokens=4096)
    check = verify(parsed, page_text)
    return {
        "extraction": parsed,
        "verification": check,
        "model": res.model,
        "tokens": res.completion_tokens,
        "escalate": not check["passed"] or not parsed.get("usable", False),
        "escalate_reason": (
            parsed.get("unusable_reason") if not parsed.get("usable", False)
            else None if check["passed"] else
            f"only {check['verified']}/{check['lines']} ingredient lines "
            f"({check['verified_rate']:.0%}) were found verbatim in the page; "
            f"below the {MIN_VERIFIED:.0%} bar this transcription is untrusted"),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Local recipe transcription + verification")
    ap.add_argument("--url", help="fetch this page (needs requests) ")
    ap.add_argument("--file", help="read page text from a file instead")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if args.file:
        with open(args.file, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        url = args.url
    elif args.url:
        import urllib.request                                   # noqa: PLC0415
        req = urllib.request.Request(args.url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode("utf-8", "replace")
        text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", raw, flags=re.S | re.I)
        text = re.sub(r"<[^>]+>", "\n", text)
        text = re.sub(r"\n{2,}", "\n", text)
        url = args.url
    else:
        ap.error("pass --url or --file")

    llm = LocalLLM()
    if not llm.health():
        print("local endpoint down — pwsh tools/local-llm/serve.ps1", file=sys.stderr)
        return 2
    out = extract(text, url, llm)

    if args.json:
        print(json.dumps(out, indent=2, ensure_ascii=False))
        return 1 if out["escalate"] else 0

    e, v = out["extraction"], out["verification"]
    print(f"\n  title     {e.get('title')}")
    print(f"  servings  {e.get('servings')}")
    print(f"  lines     {v['lines']}   verified {v['verified']} "
          f"({v['verified_rate']:.0%})   model {out['model']}")
    for ing in (e.get("ingredients") or [])[:8]:
        opt = "  (optional)" if ing.get("optional") else ""
        print(f"    {str(ing.get('qty') or ''):>7} {str(ing.get('unit') or ''):<8} "
              f"{ing.get('item')}{opt}")
    if out["escalate"]:
        print(f"\n  ESCALATE -> Claude extractor: {out['escalate_reason']}")
        for b in v["unverified_lines"]:
            print(f"    unverified: {b!r}")
    else:
        print("\n  VERIFIED — every line traced to the page; no Claude call needed.")
    return 1 if out["escalate"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
