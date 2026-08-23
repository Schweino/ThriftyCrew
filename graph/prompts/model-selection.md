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

## Prompt v4 — showing the model this board's prior rulings (2026-08-20)

The resolve prompt shipped v1-v3 giving the model the commodity label, its unit
basis and up to eight include patterns. Nothing else. The human review packet
for the *same question* carried the exclude patterns, the confirmed siblings and
the known-wrong list — so the estate was teaching its reviewer and starving its
model, with 2,551 adjudicated rejections banked and unread (43 of them on
powdered-sugar alone).

v4 retrieves the prior rulings most similar to the listing under judgement —
up to 6 rejections and 3 confirmations, ranked by word overlap, because a
rejection only teaches when it resembles the question and dumping all 43 would
bury the useful one.

**Measured, leave-one-out, on 60 gold cases whose commodities carry history.**
Leave-one-out is not optional: many gold cases ARE banked rejections, and a case
appearing among its own examples measures memorisation rather than learning.

| | blind (v3) | with priors (v4) |
|---|---|---|
| FALSE MATCH (the dangerous error) | 14/26 = 54% | **7-8/26 = 29%** |
| correct | 38 | **48-49** |
| escalated to a human | 7 | **3** |
| false reject (missed merge) | 1/34 | 1/34 unchanged |

Two independent runs agreed. Roughly half the dangerous error and half the
review load, with no new missed merges, from labels already paid for.

**This does NOT re-open the reject-only decision.** A 29% false-match rate is
still far too high to let a local MATCH price a cell; the gain is that fewer
bogus leads reach the confirm-match queue and more candidates are correctly
pruned. The asymmetry stands on the same evidence it always did.

Cost: the prompt grows by roughly 100-150 tokens. Prefill measured 0.26s of a
2.74s call at v3, so the added latency is small against the accuracy bought.

## Qwen3.8-27B UD-Q3_K_XL (llama.cpp b10509, CUDA 13.3) — 2026-08-22 18:57

- verdict: **FAIL** (586s)
- valid strict JSON: 1.000 (n=40) PASS
- resolution agreement: 0.786 (priors=none, n=120, abstain 0.14) FAIL
- median decode: 45.5 tok/s PASS
- context headroom: 2430 prompt tokens PASS

```json
{
  "extract": {
    "n": 40,
    "valid": 40,
    "valid_rate": 1.0,
    "median_tok_s": 45.46926627590318,
    "mean_tok_s": 45.62460550988752,
    "failures": []
  },
  "resolution": {
    "priors": "none",
    "n": 120,
    "agree": 81,
    "disagree": 22,
    "unsure": 17,
    "agreement_rate": 0.7864077669902912,
    "abstain_rate": 0.14166666666666666,
    "errors": [
      {
        "commodity": "chicken-thighs",
        "product": "Tyson All Natural Fresh Chicken Drumsticks",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly contains 'Chicken Drumsticks', which directly matches the commodity name 'Chicken Thighs / Drumsticks' and the surfac"
      },
      {
        "commodity": "canned-chicken",
        "product": "Swanson Original White Chunk Fully Cooked Chicken, Ready to Eat, Simpl",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing is 'Swanson Original White Chunk Fully Cooked Chicken'. The commodity is 'Canned Chicken Breast'. In grocery retail semantics, '"
      },
      {
        "commodity": "microwave-popcorn",
        "product": "Smartfood White Cheddar Cheese Popcorn, 0.625 oz., 50 pk.",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is 'Smartfood White Cheddar Cheese Popcorn'. While the specific words 'microwave' are not in the title, Smartfood popcorn is a p"
      },
      {
        "commodity": "chocolate-milk",
        "product": "Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate 8 o",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing is 'Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate'. This is a packaged retail product containing milk and c"
      },
      {
        "commodity": "granola-bars",
        "product": "Nature Valley Crispy Creamy Wafer Bars, Peanut Butter Chocolate, 28 ct",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is a 'Wafer Bar' which falls under the general category of granola bars in retail classification. The known surface pattern 'che"
      },
      {
        "commodity": "cherries",
        "product": "Fareway Unsweetened & Pitted Dark Sweet Cherries",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names 'Cherries', which matches the commodity name. While 'Pitted' and 'Dark Sweet' describe specific processing and "
      },
      {
        "commodity": "bratwurst",
        "product": "Johnsonville Dr Pepper Inspired Sausage 19 Oz",
        "gold": "MATCH",
        "got": "NO_MATCH",
        "conf": 0.95,
        "why": "The product is explicitly labeled as 'Sausage' and 'Dr Pepper Inspired', which is a distinct flavor profile and product type from the generi"
      },
      {
        "commodity": "toaster-pastries",
        "product": "Pillsbury Frozen Toaster Strudel Pastries, Apple, 6 Ct, 11.7 oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly contains 'Toaster Strudel Pastries', which is the specific product name for toaster pastries (often referred to as Po"
      },
      {
        "commodity": "ground-cloves",
        "product": "Spice Supreme Spice Ground Cloves",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly contains the phrase 'Ground Cloves', which directly matches the commodity name and the known surface pattern 'ground\\"
      },
      {
        "commodity": "chili-beans",
        "product": "(2 pack) STAGG DYNAMITE HOT Chili with Beans Beef, Shelf-Stable, 15 oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.9,
        "why": "The listing contains 'Chili with Beans', which matches the known surface pattern 'chili\\s+(?:style\\s+)?be
```

## Qwen3.8-27B UD-Q3_K_XL (llama.cpp b10509, CUDA 13.3) — 2026-08-22 19:04

- verdict: **FAIL** (404s)  <- **NOT a gate verdict.** This run passed `--skip-extract`
  and the recorder of the day wrote the unmeasured bars as `0.000 FAIL` instead of
  SKIPPED. Corrected in `bench.py` the same hour; the two lines are marked below
  rather than deleted, because a record that quietly repairs itself is not a record.
- valid strict JSON: 0.000 (n=0) FAIL   <- NOT MEASURED (extraction skipped)
- resolution agreement: 0.830 (priors=loo, n=120, abstain 0.07) FAIL
- median decode: 0.0 tok/s FAIL   <- NOT MEASURED (extraction skipped)
- context headroom: 2430 prompt tokens PASS

```json
{
  "extract": {
    "n": 0,
    "valid": 0,
    "valid_rate": 0.0,
    "median_tok_s": 0.0,
    "mean_tok_s": 0.0,
    "failures": [],
    "skipped": true
  },
  "resolution": {
    "priors": "loo",
    "n": 120,
    "agree": 93,
    "disagree": 19,
    "unsure": 8,
    "agreement_rate": 0.8303571428571429,
    "abstain_rate": 0.06666666666666667,
    "errors": [
      {
        "commodity": "chicken-thighs",
        "product": "Tyson All Natural Fresh Chicken Drumsticks",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly contains 'Chicken Drumsticks', which directly matches the commodity name 'Chicken Thighs / Drumsticks'. The modifiers"
      },
      {
        "commodity": "egg-noodles",
        "product": "Campbell's Chicken Noodle Soup Dry Egg Noodle Recipe 22.400 Oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly contains the phrase 'Dry Egg Noodle', which matches the commodity 'Egg Noodles'. Although it is a recipe mix for soup"
      },
      {
        "commodity": "chili-beans",
        "product": "Chili, W/Beans Our Family",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing 'Chili, W/Beans Our Family' describes a prepared dish of chili containing beans. The previously rejected items (Hormel, Wendy's,"
      },
      {
        "commodity": "sesame-oil",
        "product": "Dynasty Sesame Seed Oil 5 Oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names 'Sesame Seed Oil', which matches the commodity 'Sesame Oil'. The known surface pattern 'sesame\\s+oil' is presen"
      },
      {
        "commodity": "pizza-sauce",
        "product": "Melinda's Sauce Pizza Hot Sc Ranch",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.9,
        "why": "The listing contains the phrase 'Sauce Pizza', which is a direct lexical match for the commodity 'Pizza Sauce' (accounting for token order)."
      },
      {
        "commodity": "microwave-popcorn",
        "product": "Smartfood White Cheddar Cheese Popcorn, 0.625 oz., 50 pk.",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is 'Smartfood White Cheddar Cheese Popcorn'. In the grocery domain, 'popcorn' sold in small individual packages (0.625 oz) is th"
      },
      {
        "commodity": "chocolate-milk",
        "product": "Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate 8 o",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing is 'Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate'. This is a packaged, ready-to-drink chocolate milk bever"
      },
      {
        "commodity": "granola-bars",
        "product": "Nature Valley Crispy Creamy Wafer Bars, Peanut Butter Chocolate, 28 ct",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is a 'Nature Valley Crispy Creamy Wafer Bar'. While the specific variety is 'Crispy' rather than 'Chewy', the board's known surf"
      },
      {
        "commodity": "cherries",
        "product": "Fareway Unsweetened & Pitted Dark Sweet Cherries",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names 'Dark Sweet Cherries', which matches the commodity 'Cherries'. The descriptor 'Pitted' indicates a preparation "
      },
      {
        "commodity": "toaster-pastries",
        "product": "Pillsbury Frozen Toaster Strudel Pastries, Apple, 6 Ct, 11.7 oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing 'Pillsbury Frozen Toaster Strudel Pastries' matches the known surface pattern 'toaster\\s+pastr'. Although previous adjudications"
      }
    ]
  },
  "context": {
    "ok": true
```

## Qwen3.8-27B UD-Q3_K_XL (llama.cpp b10509, CUDA 13.3) — 2026-08-22 19:20

- verdict: **FAIL** (420s)
- valid strict JSON: 1.000 (n=40) PASS
- resolution agreement: 0.790 (priors=none, n=120, abstain 0.12) FAIL
- median decode: 42.3 tok/s PASS
- context headroom: 2430 prompt tokens PASS

```json
{
  "extract": {
    "n": 40,
    "valid": 40,
    "valid_rate": 1.0,
    "median_tok_s": 42.28352031604919,
    "mean_tok_s": 42.3127461798966,
    "failures": []
  },
  "resolution": {
    "priors": "none",
    "jobs": 4,
    "n": 120,
    "agree": 83,
    "disagree": 22,
    "unsure": 15,
    "agreement_rate": 0.7904761904761904,
    "abstain_rate": 0.125,
    "errors": [
      {
        "commodity": "chicken-thighs",
        "product": "Tyson All Natural Fresh Chicken Drumsticks",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly contains 'Chicken Drumsticks', which directly matches the commodity name 'Chicken Thighs / Drumsticks' and the surfac"
      },
      {
        "commodity": "baby-wipes",
        "product": "Parent's Choice Flushable Melon Berry Scented Wipes (Choose Your Count",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names the product as 'Wipes' ('...Scented Wipes'). While it specifies 'Flushable' and a specific scent ('Melon Berry'"
      },
      {
        "commodity": "egg-noodles",
        "product": "Campbell's Chicken Noodle Soup Dry Egg Noodle Recipe 22.400 Oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly contains the phrase 'Dry Egg Noodle', which matches the commodity 'Egg Noodles'. Although it is a recipe kit for soup"
      },
      {
        "commodity": "canned-chicken",
        "product": "Swanson Original White Chunk Fully Cooked Chicken, Ready to Eat, Simpl",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing is 'Swanson Original White Chunk Fully Cooked Chicken'. The commodity is 'Canned Chicken Breast'. In grocery retail semantics, '"
      },
      {
        "commodity": "microwave-popcorn",
        "product": "Smartfood White Cheddar Cheese Popcorn, 0.625 oz., 50 pk.",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is 'Popcorn' sold in a '50 pk.' (pack), which aligns with the commodity 'Microwave Popcorn'. While the listing does not explicit"
      },
      {
        "commodity": "chocolate-milk",
        "product": "Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate 8 o",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing is 'Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate'. This is a packaged retail product containing chocolate "
      },
      {
        "commodity": "granola-bars",
        "product": "Nature Valley Crispy Creamy Wafer Bars, Peanut Butter Chocolate, 28 ct",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is a packaged retail bar snack ('Wafer Bars') which falls under the general category of granola bars in grocery classification. "
      },
      {
        "commodity": "cherries",
        "product": "Fareway Unsweetened & Pitted Dark Sweet Cherries",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing contains the word 'Cherries', which matches the commodity name. Although the product is 'Pitted' and 'Dark Sweet' (a variety), t"
      },
      {
        "commodity": "toaster-pastries",
        "product": "Pillsbury Frozen Toaster Strudel Pastries, Apple, 6 Ct, 11.7 oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing contains 'Toaster Strudel Pastries', which is the specific product name for toaster pastries (often referred to as Pop-Tarts or "
      },
      {
        "commodity": "ground-cloves",
        "product": "Spice Supreme Spice Ground Cloves",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly contains the phrase 'Ground Cloves', which directly matches the co
```

## Qwen3.8-27B UD-Q3_K_XL (llama.cpp b10509, CUDA 13.3) — 2026-08-22 19:24

- verdict: **NOT A GATE RUN** (220s)
- valid strict JSON: SKIPPED (--skip-extract; resolution-only re-run, not a gate verdict)
- resolution agreement: 0.825 (priors=loo, n=120, abstain 0.05) FAIL
- median decode: SKIPPED (--skip-extract)
- context headroom: 2430 prompt tokens PASS

```json
{
  "extract": {
    "n": 0,
    "valid": 0,
    "valid_rate": 0.0,
    "median_tok_s": 0.0,
    "mean_tok_s": 0.0,
    "failures": [],
    "skipped": true
  },
  "resolution": {
    "priors": "loo",
    "jobs": 4,
    "n": 120,
    "agree": 94,
    "disagree": 20,
    "unsure": 6,
    "agreement_rate": 0.8245614035087719,
    "abstain_rate": 0.05,
    "errors": [
      {
        "commodity": "chicken-thighs",
        "product": "Tyson All Natural Fresh Chicken Drumsticks",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly contains the words 'Chicken Drumsticks', which directly matches the commodity name 'Chicken Thighs / Drumsticks'. The"
      },
      {
        "commodity": "egg-noodles",
        "product": "Campbell's Chicken Noodle Soup Dry Egg Noodle Recipe 22.400 Oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names the product as 'Dry Egg Noodle Recipe'. While it is a soup mix, the core dry pasta component is identified as '"
      },
      {
        "commodity": "sesame-oil",
        "product": "Dynasty Sesame Seed Oil 5 Oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing contains the exact phrase 'Sesame Seed Oil', which matches the known surface pattern and the core commodity name. The reference "
      },
      {
        "commodity": "microwave-popcorn",
        "product": "Smartfood White Cheddar Cheese Popcorn, 0.625 oz., 50 pk.",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is 'Smartfood White Cheddar Cheese Popcorn'. While the known surface patterns explicitly look for the word 'microwave', the doma"
      },
      {
        "commodity": "chocolate-milk",
        "product": "Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate 8 o",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing is 'Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate'. This is a packaged, ready-to-drink chocolate milk produ"
      },
      {
        "commodity": "granola-bars",
        "product": "Nature Valley Crispy Creamy Wafer Bars, Peanut Butter Chocolate, 28 ct",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is a 'Nature Valley Crispy Creamy Wafer Bar'. While the specific sub-type is 'Crispy' rather than 'Chewy', it falls under the br"
      },
      {
        "commodity": "cherries",
        "product": "Fareway Unsweetened & Pitted Dark Sweet Cherries",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names 'Cherries', which matches the commodity name. The descriptors 'Pitted' and 'Dark Sweet' refer to the preparatio"
      },
      {
        "commodity": "toaster-pastries",
        "product": "Pillsbury Frozen Toaster Strudel Pastries, Apple, 6 Ct, 11.7 oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing 'Pillsbury Frozen Toaster Strudel Pastries' matches the known surface pattern 'toaster\\s+pastr'. 'Toaster Strudel' is a branded "
      },
      {
        "commodity": "ground-cloves",
        "product": "Spice Supreme Spice Ground Cloves",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly contains the phrase 'Ground Cloves', which directly matches the commodity name and the known surface pattern 'ground\\"
      },
      {
        "commodity": "rice-noodles",
        "product": "Ka'Me Stir Fry Hokkien Noodles, 14.2oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is 'Hokkien Noodles'. In the context of packaged Asian grocery items (specifically the Ka'Me brand which is already established "
      }
    ]
  },
  "context": 
```

## Qwen3.8-27B UD-Q3_K_XL (llama.cpp b10509, CUDA 13.3) — 2026-08-22 19:28

- verdict: **NOT A GATE RUN** (227s)
- valid strict JSON: SKIPPED (--skip-extract; resolution-only re-run, not a gate verdict)
- resolution agreement: 0.860 (priors=loo-all, n=120, abstain 0.05) FAIL
- median decode: SKIPPED (--skip-extract)
- context headroom: 2430 prompt tokens PASS

```json
{
  "extract": {
    "n": 0,
    "valid": 0,
    "valid_rate": 0.0,
    "median_tok_s": 0.0,
    "mean_tok_s": 0.0,
    "failures": [],
    "skipped": true
  },
  "resolution": {
    "priors": "loo-all",
    "jobs": 4,
    "n": 120,
    "agree": 98,
    "disagree": 16,
    "unsure": 6,
    "agreement_rate": 0.8596491228070176,
    "abstain_rate": 0.05,
    "errors": [
      {
        "commodity": "chicken-thighs",
        "product": "Tyson All Natural Fresh Chicken Drumsticks",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly names 'Chicken Drumsticks', which is one of the two specific cuts defined in the commodity 'Chicken Thighs / Drumstic"
      },
      {
        "commodity": "egg-noodles",
        "product": "Campbell's Chicken Noodle Soup Dry Egg Noodle Recipe 22.400 Oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names the product as 'Dry Egg Noodle Recipe'. While it is a soup mix, the core dry noodle component is identified as "
      },
      {
        "commodity": "chili-beans",
        "product": "Chili, W/Beans Our Family",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing 'Chili, W/Beans Our Family' explicitly contains 'W/Beans', which is a standard abbreviation for 'With Beans'. This matches the c"
      },
      {
        "commodity": "canned-chicken",
        "product": "Swanson Original White Chunk Fully Cooked Chicken, Ready to Eat, Simpl",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.9,
        "why": "The listing is 'Swanson Original White Chunk Fully Cooked Chicken... 2.6 oz Pouch'. The known surface patterns include 'chunk\\s+chicken' and"
      },
      {
        "commodity": "sesame-oil",
        "product": "Dynasty Sesame Seed Oil 5 Oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names 'Sesame Seed Oil', which matches the commodity 'Sesame Oil'. The known positive example 'HOUSE OF TSANG Sesame "
      },
      {
        "commodity": "microwave-popcorn",
        "product": "Smartfood White Cheddar Cheese Popcorn, 0.625 oz., 50 pk.",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The product is 'Smartfood White Cheddar Cheese Popcorn'. While the name does not explicitly contain the word 'microwave', Smartfood popcorn "
      },
      {
        "commodity": "chocolate-milk",
        "product": "Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate 8 o",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing is 'Carnation Breakfast Essentials Ready To Drink, Rich Milk Chocolate'. This is a packaged, ready-to-drink chocolate milk bever"
      },
      {
        "commodity": "cherries",
        "product": "Fareway Unsweetened & Pitted Dark Sweet Cherries",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing explicitly names 'Dark Sweet Cherries', which is a specific variety of fresh cherry. The terms 'Pitted' and 'Unsweetened' descri"
      },
      {
        "commodity": "toaster-pastries",
        "product": "Pillsbury Frozen Toaster Strudel Pastries, Apple, 6 Ct, 11.7 oz",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.95,
        "why": "The listing 'Pillsbury Frozen Toaster Strudel Pastries' matches the known surface pattern 'toaster\\s+pastr'. Although 'Toaster Strudel' is a"
      },
      {
        "commodity": "ground-cloves",
        "product": "Spice Supreme Spice Ground Cloves",
        "gold": "NO_MATCH",
        "got": "MATCH",
        "conf": 0.98,
        "why": "The listing explicitly contains the words 'Ground Cloves', which directly matches the commodity name and the known surface pattern 'ground\\s"
      }
    ]
  },
  "context": {
    "o
```

## Addendum 2026-08-22 — the honest cold-start baseline, and prompt v5 (authority tiers)

Two things were measured this session, both on the live graph, both re-runnable.
The GPU was held on demand and released; the 07:00 sweep was never at risk.

### 1. The baseline every later phase is measured against

The 0.900 at the top of this file was 30 gold cases with **no priors at all**,
while production has sent retrieved priors since prompt v4 — so it was neither
the production number nor a labelled cold-start number. `bench.py` now takes
`--priors {none,loo,loo-all}` and records which one it ran. n=120, same probe
set, gold-drawn, deterministic layers OFF:

| priors | agreement | abstain | what it is |
|---|---|---|---|
| `none` | **0.786 / 0.790** (two runs) | 0.14 / 0.12 | **COLD START. The baseline.** |
| `loo` (v5, adjudicated only) | 0.825 / 0.830 | 0.05 / 0.07 | what production sends today |
| `loo-all` (v4, every banked ruling) | 0.860 | 0.05 | what production sent before today |

**0.79, not 0.900, is the number to beat.** It is what the model knows about a
commodity it has never been taught — 6.5% of the gold corpus by construction
(MEASURE doc §2.1) and 100% of every new commodity. The gap between 0.79 and
0.83 is the entire value of the board's retrieved memory on this population;
§3.2's memory-by-meaning has to beat 0.83 to be worth its complexity.

Both `none` runs agree to 0.004 across independent samples, so the third decimal
is noise and the second is not.

Concurrency: the probe now issues 4 calls at once (`--jobs 4`, coupled to
`serve.ps1 -Slots`). 120 cases fell from 9m46s to 2m43s, ~3.6x, with the same
answers — the calls are independent, temperature is 0.1 and the grammar is
unchanged. `bench_extract` stays single-stream on purpose: it measures decode
tok/s, and concurrent streams share memory bandwidth.

### 2. Prompt v5 — `resolve-v5-reject-only-adjudicated-priors`

`_verdict_index` cited every banked ruling as precedent regardless of who made
it. Measured on the live graph, **3,315 of the 3,692 `llm_rejected` rows are the
local model's own unreviewed work** (the plan said 1,145; that count used
`reason LIKE 'llm%'`, which misses every row re-banked behind a `banked: `
prefix — see graph/lib/authority.py). The model was being shown its own guesses
under the heading ALREADY RULED. `question_verdicts.decided_by` could not fix it:
`state.py` derived it from the status prefix, so a Claude reviewer's ruling was
stamped `model` too, and the column held two values across 4,141 rows.

v5 shows **adjudicated rulings only** (human, the review lane, known-wrong).
Model-consensus rulings get a separate list labelled tentative — provisioned for
the phase-3 helper, empty today. Single-model rulings are shown nowhere; they
still prune their own row, they just stop testifying about other rows.

**Leave-one-out, 2 x 120 gold cases whose commodities carry history**
(`graph/bench/priors_ablation.py`, seeds 20260822 / 20260823; totals over 240):

| | no priors | v4 (all rulings) | **v5 (adjudicated only)** |
|---|---|---|---|
| FALSE MATCH (the dangerous error) | 41/90 = 46% | 34/90 = 38% | **33/90 = 37%** |
| correct | 158 | 191 | **188** |
| escalated | 39 | 12 | **16** |
| false reject (missed merge) | 2/150 | 3/150 | **3/150 unchanged** |
| priors shown per case | 0 | 5.9 | **3.3** |

**The fix is free on the metric that matters.** Dropping 3,315 self-citations
left the dangerous error where it was (34 -> 33, inside run-to-run noise: the two
runs alone differ by 2) and the false-reject rate identical. It costs about 4
extra escalations per 240 — cases the model now declines instead of deciding on
its own past word, which is the safe direction and the one this board's bias
picks. The prompt also shrinks by ~2.6 examples.

The bench's own `loo-all` 0.860 vs `loo` 0.825 is the same effect read through a
cruder metric: a pool stuffed with rejections nudges the model toward NO_MATCH,
which flatters an agreement rate on a NO_MATCH-heavy contested set while doing
nothing for false MATCH. Agreement rate is not the metric this lane is graded
on; false MATCH and false reject are.

**This does not re-open reject-only.** A 37% false-match rate on the contested
slice is nowhere near safe enough to price a cell, and nothing here changes what
may (`v_current_cell`, `llm_confirmed` from the review lane only).
