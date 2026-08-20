# Phase 0 model selection record

Appended by `graph/bench/bench.py`. Each block is one candidate
measured on this box against the plan's acceptance bars.
The chosen primary model is whichever most recently PASSED.

## Qwen3.8-27B UD-Q3_K_XL (llama.cpp b10509, CUDA 13.3) — 2026-08-20 04:50

- verdict: **PASS** (295s)
- valid strict JSON: 1.000 (n=40) PASS
- resolution agreement: 0.900 (n=30, abstain 0.00) PASS
- median decode: 46.1 tok/s PASS
- context headroom: 2430 prompt tokens PASS

```json
{
  "extract": {
    "n": 40,
    "valid": 40,
    "valid_rate": 1.0,
    "median_tok_s": 46.105829356120076,
    "mean_tok_s": 46.117267091219105,
    "failures": []
  },
  "resolution": {
    "n": 30,
    "agree": 27,
    "disagree": 3,
    "unsure": 0,
    "agreement_rate": 0.9,
    "abstain_rate": 0.0,
    "errors": [
      {
        "commodity": "all-purpose-cleaner",
        "product": "Pledge Multisurface Cleaner, Rainshower, 3 ct., 29 oz.",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing contains 'Multisurface Cleaner', which matches the known surface pattern 'multi[\\s-]*(?:purpose|surface)\\s+cleaner'. In the cont"
      },
      {
        "commodity": "five-spice-powder",
        "product": "Spice Supreme oriental five spices, 3.5-oz. plastic shaker",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly contains the phrase 'five spices', which matches the known surface pattern and the core identity of the commodity 'Ch"
      },
      {
        "commodity": "beef-jerky",
        "product": "Old trapper Hot & Spicy Beef Jerky, 18 oz.",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly contains the phrase 'Beef Jerky', which directly matches the commodity name and the known surface pattern 'beef\\s+jer"
      }
    ]
  },
  "context": {
    "ok": true,
    "prompt_tokens": 2430,
    "tok_s": 1.1537877407246686
  }
}
```

## Addendum 2026-08-20 — bench decomposition and the reject-only decision

The 0.900 headline agreement above decomposes by gold label as:

| gold label | n | correct |
|---|---|---|
| MATCH | 22 | 22 (100%) |
| NO_MATCH | 8 | 5 (62.5%) |

All three errors were FALSE MATCHES (`all-purpose-cleaner`, `five-spice-powder`,
`beef-jerky`) at confidence 0.95, 0.95 and 0.98 — every one above the 0.75
escalation threshold, so every one would have landed as `llm_confirmed` and been
eligible to price a cell. Confidence does not discriminate this model's false
matches.

The bench also samples gold `match` cases, 73% of which the deterministic layers
already settle — but layer 5 only ever sees rows where NO include and NO exclude
pattern matched, by construction the least-signal rows in the corpus. 0.900 is
therefore an optimistic upper bound for the population the layer actually
serves.

**Decision: layer 5 is reject-only.** The local model may emit `llm_rejected`
(confident NO_MATCH — a wrong rejection costs one empty cell) or
`llm_match_unverified` (confident MATCH — a lead for the Claude reviewer, barred
from pricing). `llm_confirmed` is written only by the reviewer. See
`pipeline/resolve.py` and `schema.md`; prompt/policy version
`resolve-v3-reject-only`.
