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

## Addendum 2026-08-22 (second) — phase 2: one process owns the card

Phase 1 made the baseline honest and stopped the loop citing itself. Phase 2 is
not about accuracy at all. It is about a rule that existed only as a sentence,
and about paying for the helper's opinion while the card is already warm.

Nothing in this phase changes what may price a cell, and nothing in it routes,
filters or rejects anything. The contested lane records scores. **Phase 2
caches; phase 3 decides.** Keeping those two acts apart is what will let phase 3
measure its filter against a set that was scored before anyone knew what the
filter would do.

### 1. The rule that was a sentence

`tools\local-llm\serve.ps1` carried this, from 2026-08-22:

> ON-DEMAND ONLY. NEVER SCHEDULED. [...] start this by hand when a job needs it;
> STOP IT BEFORE 07:00; nothing in Task Scheduler or the pipeline may start it.

That rule was never really about scheduling. It was about the card: llama-server
takes ~13 GB of 16 and the semantic sidecar sweep needs ~3, so the two cannot be
resident together. With nothing owning the ordering, the only safe owner was a
human — and `audit-semantic-identity.ps1`'s nvidia-smi guard could only ever say
NO, turning a forgotten teardown into a BLIND semantic sweep the next morning.

`graph\pipeline\nightly.ps1` owns the ordering now:

    emit -> sweep -> SIDECAR EXITS -> llama-server -> resolve -> Stage 1 -> LLAMA-SERVER EXITS

It stops llama-server in a `finally` block that runs on success, on failure, on
timeout and on Ctrl-C, and it will not start it while the sidecar's own python
is alive or the card is short of room. The nvidia-smi guard is unchanged and is
now a **backstop for a rule something enforces**, rather than the rule itself.
So the doctrine narrows rather than relaxes: nothing may start llama-server
except this chain, and nothing may schedule this chain except
`install-nightly-task.ps1`.

Two clocks, because they fail differently. `-HardStop` (06:30) protects the
07:00 ad pull and the 08:00 daily capture, both of which run the sweep, and is
meaningless if the system clock jumps; `-MaxMinutes` (150) is immune to the
clock and knows nothing about 07:00. The deadline is the **earlier** of the two,
so either one alone gets the card back. Killing `resolve` at the deadline is
safe by construction: `resolve_pending` checkpoints every batch and re-selects
only rows still unsettled, so a killed run resumes where it stopped.

**Measured, 2026-08-22, full chain on the live graph:**

| stage | s | outcome |
|---|---|---|
| emit | 2 | 338 contested of 21,092 questions, read-only |
| sweep | 95 | 3 lanes, sidecar exits |
| serve | 8 | llama-server up, 4 slots |
| resolve | 410 (first run) / 2 (nothing left) | 338 model calls -> 306 `llm_rejected`, 21 `llm_match_unverified`, 11 `escalated` |
| stage1 | 25 | learning proposals |
| stop | 2 | card back, 14,864 MiB free |

The refusal paths were exercised, not just fixtured: a 5-minute window refuses
and starts nothing, and a run with no sidecar interpreter records `sweep BLIND`
and carries on to the model half. `grocery\out\logs\graph-nightly-status.json`
is written on every path including the refusals, because "the chain did not run"
and "the chain ran clean" have to be different weeks on the scorecard.

**One bug, found by running it.** The first version had `Log` write to the
success stream. A PowerShell function returns *everything* written there, so
`Stop-Llama`'s return value was two log lines plus a boolean and the status file
recorded `card_free: ["[20:39:53] stopping...", "[20:39:56] llama-server down...",
true]`. `Log` now writes via `[Console]::WriteLine`, and the self-test asserts
that `@(Log 'x')` has zero elements — a fixture proven able to fail before it
was trusted.

### 2. The helper's opinion, bought while the models are already resident

The sweep gained a third lane. It scores the pairs the deterministic layers
could not settle, and it embeds every product name the resolve lane will later
want a vector for.

**The contested set comes from the resolver, not from the sidecar.**
`resolve.py --emit-contested` runs pass 1 in memory, writes one JSON file and
touches nothing else — read-only on a database a publish may be reading, 1.9 s
for 21,092 questions. The alternative, letting the sidecar decide for itself
what "contested" means, is the two-implementations bug this estate keeps getting
bitten by (pu-lib had three; the category-exclude bake drifted 2,165 patterns).
`pending_questions()` is now the one implementation, called by both.

**The lane lives in the sweep and not in a script of its own** for a reason
that is easy to miss: `score_cache` prunes on save to the texts *that run* saw
(`keep_only=_seen_texts`), so a vector produced by any other process is evicted
the next time the sweep saves. One process, one cache, one save.

**Measured on the 2026-08-22 corpus** (588 commodities, 2,860 board pairs,
37,340 product rows, 338 contested):

| | cold cache | warm cache |
|---|---|---|
| whole sweep | 51.0 s | **0.4 s** |
| contested lane | 3.2 s | 0.0 s |
| models loaded onto the card | both | **neither** |
| embed / rerank lookups | 12,375 + 8,481 misses | 14,024 + 8,189 hits, **0 misses** |

The steady-state cost of the third lane is not "small". `embedder_loaded: false`
and `gpu_sec: 0.0` on the warm run: the helper's opinion on every contested pair
and 4,051 warm vectors cost **no GPU time at all** on a day the shelf has not
moved. That is the whole argument for putting it here.

Of 338 contested pairs, 315 scored and **23 named a commodity the sidecar has no
definition for** — the recipe namespace and the staple catalogue are not the
same set. Those are reported and counted, never guessed at.

### 3. What the stock cross-encoder already says — an observation, not a gate

Recorded because it is free and because phase 3's fine-tune needs a *before*.
The contested scores are sharply bimodal: the 90th percentile is **0.024**, and
what sits above it reads right by eye (`Fresh Green Peppers` -> Bell Peppers at
0.822 against a peer median of 0.893). That is the shape a very-low-score filter
wants, and it is the first evidence that §2 step 2 can exist.

Two honest limits on it, both recorded in the artefact rather than argued away:

* **93 of 315 pairs have `peer_n = 0`** — the commodity ships nothing today, so
  there is no peer distribution to calibrate against. An absolute floor cannot
  substitute: this sweep already learned that short generic names score low
  against everything, so a global bar just selects for short names and flags
  "Yellow Bananas" as suspicious bananas. Phase 3 owes those 93 an answer that
  is not a global threshold.
* Nothing here is validated against a label. These are **the stock model's**
  scores on rows nobody has adjudicated. The §6 training set does not contain
  them, which is exactly what will make §4's audit row honest later — and is
  also why no number in this section is a gate.

### 4. On the scorecard

`scorecard.ps1` gained a local-lane section fed by the two run artefacts rather
than by the graph, because neither fact is a decision and neither belongs in
`decision_log`. It distinguishes BLIND from zero everywhere, and it prints one
line that is about *right now* rather than about last week:

    *** THE CARD WAS NOT HANDED BACK - llama-server may still hold it, and the
        next semantic sweep will go BLIND ***

Phase 2's before/after, as the scorecard reads it: the local lane went from
absent (no chain, no helper scores, `nightly BLIND`) to `nightly ran ... card
handed back, 14,864 MiB free` and `helper scored 315 of 338`. Tokens per Claude
ruling is unchanged and was expected to be: this phase asked Claude nothing, and
the lever that moves that number is phase 3's filter and phase 5's packet.

## Addendum 2026-08-22 (third) — phase 3 prep, and the eval that was measuring the shelf

Three gaps stood between phase 2 and training a helper. Closing them turned up a
fourth that matters more than the other three together.

### 1. The gate a fine-tune must clear was measuring board churn, not the model

`commodity_text()` is *label + up to 5 of the products the board currently
accepts*. That is correct for the nightly sweep, which is scoring today's board.
It also means every score in the estate is a function of what the shelf looked
like that morning.

**Measured. Same pinned model, byte-identical `positives.json` and
`negatives.json`, only the commodity text changed:**

| commodity text | TASK A AUC | known-wrong caught at a 100/2816 budget |
|---|---|---|
| label + exemplars | **0.9705** | 17/25 |
| label alone | **0.7921** | 0/25 |

The exemplars are doing nearly all the work. And the consequence was already
sitting in the repo unnoticed: with the same eval files, `backtest.py` reported
**24/24 recall on 2026-08-01 and 17/25 on 2026-08-22**. The model did not
change. The board did.

Two things follow, and the second one edits the plan:

* A stock-vs-candidate comparison must pin **both sides** to one frozen
  `commodity-defs.json`. `sidecar/freeze_eval.py` takes the snapshot;
  `--defs` on `backtest.py` and `hardeval.py` consumes it. The snapshot is
  tracked, for the reason `.gitignore` already gives about the gold set: a
  record that does not outlive the machine that produced it is not a record.
  (`/sidecar/data/` had to become `/sidecar/data/*` first — git does not descend
  into an excluded directory, so the negation could never have matched.)
* **§6's gate "still 100% recall on the 24 known defects" cannot stand as
  written.** Stock itself is at 17/25 today. A candidate cannot be held to a bar
  the incumbent fails. The honest restatement is *no worse than stock, measured
  the same day against the same frozen defs* — which is what the frozen baseline
  below exists to make possible.

### 2. §6 names the weaker of the two evals

The plan says re-run `backtest.py`. The estate had already written down why that
is not enough: its 25 negatives are all dramatically wrong — bath soap as
coconut oil, dog food as meat — so it never asks a hard question, and when the
lane met the real board it flagged 173 pairs that were all correct.
`hardeval.py` exists precisely because of that, and its GOLD negatives are the
adjudicated rulings. Run both; **the GOLD number is the one that decides.**

**The frozen stock baseline, `--tag phase3-frozen`, defs `phase3-baseline`:**

| | value |
|---|---|
| TASK A AUC (cross-encoder, dramatic negatives) | 0.9705 |
| hardeval AUC, OLD negatives | 0.8941 |
| **hardeval AUC, GOLD negatives (the one that decides)** | **0.8312** |
| hardeval AUC, MINED near-misses | *no data* |
| TASK C discovery | #1 rank for 5 of 6 blind commodities |

The three-week-old report says 0.8641 on GOLD. Comparing a fine-tune against
that number would have credited it with 0.03 of board drift.

### 3. The corpus did not exist, and is smaller than the plan implies

`tools/local-llm/finetune-probe/build_corpus.py` looks like the thing but builds
prompt→completion JSONL for the 27B (§10). A cross-encoder needs
`(query, doc, label)`. `sidecar/build_pair_corpus.py` is that builder: read-only
on the graph under `PRAGMA query_only`, doc text from the frozen snapshot,
holdout **by commodity family** from the graph's own `in_category` edges so the
test is cold by construction — the standard phase 1 held the bench to.

**What it actually yields:**

| | rows |
|---|---|
| raw labelled pairs | 5,738 |
| after dedup by (commodity, product) | 4,232 |
| train | 2,950 — **+2,571 / −379** |
| test (families: dairy, oils, pet, snacks, veg) | 1,282 — **+1,105 / −177** |
| excluded by design: single-model rejections | 3,315 |

Two things worth stating before anyone plans a training run on this:

* **556 unique hard negatives, against 3,676 positives — 6.6:1.** The plan's §6
  reads as though the negative pile were several thousand; dedup collapses it,
  because the same pair is banked as a gold NO_MATCH *and* a known-wrong *and*
  an adjudicated rejection. The imbalance has to be handled deliberately.
* Excluding the 3,315 single-model rejections is not fastidiousness. Phase 1
  stopped citing them as precedent because a wrong rejection was becoming the
  reason to reject its neighbours; training on them is the same disease with a
  worse prognosis, because retrieval can be changed and weights cannot. It is
  also the only reason §4's audit row means anything — the helper's verdict on
  those rows stays genuinely out-of-sample.

One pair carried both labels and was **dropped, not guessed at**. 307 accepted
pairs and 40 gold matches name a commodity the sidecar has no definition for —
the recipe namespace again, reported rather than silently trained on.

### 4. The negatives that matter most have never been produced

Every hardeval report to date says `mined: 0`. The mining stage exists
(`hardeval.py --stage mine` → `export-identity-eval.ps1 -Label`) and its output
has never been labelled. Those are the **near-miss** negatives: a real product
paired with a commodity that is semantically close but whose own regex rejects
it — Wimmer's Wieners against Hot Dogs, Kroger Olive Oil Mayo against
Mayonnaise.

That is the class the helper will actually meet. On the contested set nearly
every pair is similar-and-wrong or similar-and-right; almost none is
soap-versus-coconut-oil. A corpus without near-misses teaches the model
something the stock weights already know, and an eval without them cannot
measure the only improvement worth having.

**This is the highest-value item before §6, and it is cheap** — the mining is a
bi-encoder pass and the labelling is the existing regex, applied on the
PowerShell side where the rules live. `build_pair_corpus.py` picks up
`mine-labelled.json` automatically the moment it exists.

## Addendum 2026-08-22 (fourth) — the helper was blind to 97% of the questions

Phase 2 shipped a contested lane that scored 15 of 435 pairs and reported the
other 420 as "no sidecar definition". That line was accurate and easy to read
past. It is the whole ballgame.

### 1. Two catalogues, one of them invisible

`grocery/audit-semantic-identity.ps1` builds the sidecar's `commodity-defs.json`
from `grocery/commodities.json` — the **staple** catalogue, 588 entries. The
graph holds **687** commodities across two namespaces, and the contested set is
almost entirely the other one:

| | n |
|---|---|
| contested questions on the live graph | 435 |
| staple namespace | 15 |
| **recipe namespace** | **420 (97%)** |

Of the 44 distinct recipe commodities involved, 12 are in
`grocery/recipe-commodities.json` and **32 are defined nowhere the sidecar can
read** — they arrive through the recipe-board import and live only in the graph.

`graph/pipeline/emit_commodity_defs.py` (read-only, `PRAGMA query_only`) emits
definitions for all 687 from the graph. This does not touch the division of
labour: PowerShell still owns the regex, because `commodity_text()` deliberately
excludes the regex — it needs a label and some accepted examples, both of which
the graph has for both namespaces.

**With graph-sourced definitions the contested lane scores 435 of 435.**

### 2. A silent-wrong-answer bug in phase 2's own lane

**33 bare ids name a commodity in BOTH namespaces** — `milk`, `butter`,
`brown-sugar`, `carrots`, `peanut-butter`, `honey`. Phase 2's lane keyed on the
bare `def_id`, so a recipe question could be scored against the staple's text.

That is worse than a missing score, and the reason is the asymmetry this whole
plan keeps returning to: a missing score is a cache miss anyone can see, and for
two near-identical foods a wrong one is *plausible* and would never be
questioned. The lane now resolves on the full node id and permits the bare-id
fallback only when the namespaces agree; a mismatch is refused and counted
(`refused_wrong_namespace`).

Worth recording that the first fix was itself wrong: the node-id index was built
from `defs_by_id`, which is keyed by bare id and had already collapsed the 33
colliding entries — reintroducing the same collision one level up. It is built
from the defs list now. `sweep.py --selftest` fixtures the refusal with a
MUST-FIRE and three clean twins, and runs daily in `test-auditors` (SKIPped, not
failed, where the sidecar venv is absent — torch on the cloud runner is a
watcher that goes BLIND).

No pair was scored against the wrong namespace in practice: today's one
colliding contested pair is `commodity:staple:brown-sugar`, so the namespaces
agreed. The guard has caught nothing yet. That is the point of fixturing it.

### 3. The switch is NOT safe to make wholesale, and here is the number

`sweep.py` now takes `--defs` and `--tag`, so a comparison runs off the daily
path and cannot overwrite the findings the alert de-dupes against. Run both ways
on the same corpus, same models:

| lane | today | graph defs | new | **gone** |
|---|---|---|---|---|
| identity | 181 | 255 | 204 | **130** |
| coverage | 86 | 147 | 95 | 34 |
| contested scored | 15 | **435** | — | — |

The net "+74 identity findings" hides a near-total reshuffle: only ~51 of the
current 181 survive. The cause is not the 66 added recipe commodities — it is
that the graph draws exemplars from `instance_of` (everything the board has ever
accepted) while the PowerShell prep draws them from today's comparison board, so
**547 of 588 staple definitions change text**, and the identity lane's cut is
relative to a peer median that moves with them.

**130 GONE is the line that stops this shipping as-is.** Those are pairs the
estate is being shown today and would stop being shown, with no event marking
it — a guard silently narrowing, which this board rates worse than a noisy one.
The 95 new coverage findings, by contrast, look real on inspection (`beef-base`,
`fajita-seasoning`, `enchilada-sauce`, `cheddar-cheese-shredded` — recipe
commodities with genuinely unmatched products).

So the measurement recommends splitting what phase 3 needs from what it does not:
**give the contested lane the graph definitions and leave identity and coverage
on the staple catalogue**, which is a zero-diff change to the daily alert and
takes the helper from 3% to 100% coverage. Unifying the two def sets is a
separate piece of work whose cost is now known and is not small.

Nothing in this addendum has been wired into the daily path. `emit_commodity_defs.py`
writes a file nothing reads yet.

## Addendum 2026-08-23 — phase 3: the near-misses, the helper, and a gate with its arguments backwards

Phase 3 is §6 (train the helper), §2 step 2 (the filter) and the def split the fourth
addendum recommended. §4's audit set is deliberately not here — it costs a review
session and was deferred. Nothing in this phase is wired into the nightly chain, and
nothing in it can price a cell: `v_current_rows` admits `include_hit` and
`llm_confirmed` only, so the one new status is structurally incapable of it.

### 1. The negatives that had never been produced, produced

`mined: 0` in every hardeval report was not neglect, it was a missing half-pipeline.
`hardeval.py --stage mine` worked; `export-identity-eval.ps1 -Label`, which its own
output told you to run next, **had no `-Label` parameter**. Written, and the round
trip costs 22 seconds of GPU: mine 13 s, label 9 s.

**Top-k alone mines noise.** Unfiltered top-8 gives 22,547 pairs and the bottom of
that pile is `Cantaloupe -> cornmeal` at cos 0.278 — a true negative, an easy one, and
one that would have flattered the MINED AUC. The filter is RELATIVE to the product's
own commodity (`--margin`, default 0.08), because this corpus already learned that
short generic names score low against everything and an absolute floor just selects
for short names. 4,785 kept, 17,762 dropped. **553 candidates beat their own owner** —
`Demings Pink Salmon` reads more like canned-salmon than salmon, `Kroger Cut Asparagus
Spears` more like canned-asparagus.

    corpus 4,232 -> 8,872 rows. +3,676 / -5,196, from 6.6:1 the other way.

Two builder bugs, both surfaced by the new rows. Mined rows speak bare ids while every
other source carries a graph node id, and both the contradiction check and the FAMILY
that decides the holdout key on that id — so a mined negative for a held-out family
would have trained against its own test set. And a regex could delete a ruling: `Great
Value Baked Cheddar Cheese Penguin Crackers` is a confirmed cheese-cracker whose own
regex rejects it, so the contradiction rule correctly refused to guess and dropped
BOTH rows. A mined pair is a mechanical proposal; a ruling is a ruling. Three pairs,
and they are also the only visible sample of the mining rule's error rate.

### 2. The gate had its arguments backwards

`hardeval.py` fed the cross-encoder `(commodity_text, product)`. Every other rerank
call site in the estate is product-first: `backtest.py:160`, all three sweep lanes,
and the `query`/`doc` columns of the training corpus. A cross-encoder is not symmetric.

It survived because the **stock model barely notices**: GOLD 0.8312 reversed against
0.8329 correct. A fine-tune notices enormously, because it learned one order and only
one — **ft-v1 measured GOLD 0.6918 reversed and 0.9940 correct.** So the file the third
addendum promoted to "the number that decides", on the first day it had to decide
anything, would have thrown away a candidate that beats the incumbent everywhere.

The tell had been in the repo for a day, unread: hardeval reported OLD 0.8941 while
backtest reported 0.9705 **on the same 25 negatives**. After the fix both say 0.9705.
Two files that disagreed about one number now agree, which is the check that says the
fix is right rather than merely different.

### 3. And the deciding gate could not have decided anyway

`eval-positives.json` IS the accepted board pairs and `negatives-gold.json` IS the
known-wrong rulings — both are §6 training sources. Scoring a fine-tune on them is
in-sample. `--holdout-from` restricts every set to the commodity families the corpus
held out, so the cold row is the one to believe.

**Frozen defs both sides (`phase3-baseline`), same day, same corpus:**

| run | OLD | GOLD | MINED |
|---|---|---|---|
| stock | 0.9705 | 0.8329 | 0.9559 |
| ft-v1 | 0.9948 | 0.9940 | 0.9977 |
| stock, COLD | 0.9857 | 0.9572 | 0.9567 |
| **ft-v1, COLD** | **0.9938** | **0.9920** | **0.9925** |

    backtest TASK A AUC     0.9705 -> 0.9948
    known-wrong @100 budget  17/25 -> 24/25   (in-sample; @30 budget 12 -> 23)
    TASK C discovery        identical - the fine-tune touches the cross-encoder only
    training holdout AUC    0.9127 -> 0.9672  (mined-only 0.9249 -> 0.9792)

Cold GOLD is n=6 and should be read as such; cold MINED (n=964) is the number with
weight behind it. §6's gate as the third addendum restated it — no worse than stock,
same day, same frozen defs — is met on every set, cold and warm. 139 seconds of
training, no new dependencies (a plain torch loop; sentence-transformers' trainer
would have wanted `datasets` + `accelerate` in the venv the 07:00 sweep runs on).

### 4. The peer hole was diagnosed wrong, and the fix is smaller than feared

The plan says ~30% of contested pairs have `peer_n = 0` because the commodity ships
nothing today. At 435 pairs it is **420 — 97%** — and all 54 contested commodities
have accepted products in the graph. The peers were missing because the peer source is
the identity lane's BOARD pairs (the staple catalogue) while 97% of contested questions
are recipe commodities. **Wrong catalogue, not empty shelf**, so the absolute floor the
plan feared is not needed and there is nothing to argue about.

`loo_peers()` builds the distribution from a definition's own accepted examples, each
scored against the OTHER examples — leave-one-out, because `commodity_text()` is label
+ those very examples and scoring one against a document containing it returns ~1.0.
Phase 1 made the same ruling about retrieved priors; `--priors loo` is where. Under two
exemplars it returns nothing and the row says `peer_source: none` rather than inventing
a floor. Over 435: `exemplars_loo` 419, `board` 15, `none` 1.

One consequence worth recording: the trained helper is confident enough that its LOO
peer medians sit at ~0.9999 for nearly every commodity, so a peer-relative threshold
degenerates into an absolute one. That is not the trap the identity lane fell into —
the helper does not have the short-generic-name pathology, because it was trained on
exactly those pairs — but it does mean the peer columns are calibration for the PINNED
model's score and near-useless for the helper's.

### 5. The filter, and the number that sets its threshold

`resolve.py --helper-scores` turns on §2 step 2. It refuses a scores file with no
`helper_model`: the pinned model was never measured as a filter, and phase 2 said so.

**§2 step 2's other safeguard does not exist.** "Very low score AND no partial include
hit" — the contested set IS the `no_include_hit` rows, that being what makes them
contested, so the second condition is true of every candidate by construction. The
threshold is the only protection there is.

So it is measured twice. On the cold corpus holdout:

| reject below | catches of 1,073 cold negatives | costs of 718 true pairs |
|---|---|---|
| 1e-5 | 0 | 0 |
| **1e-4** | **469 (43.7%)** | **2 (0.28%)** |
| 1e-3 | 733 (68.3%) | 8 (1.11%) |
| 1e-2 | 864 (80.5%) | 35 (4.87%) |

The distribution is a cliff; there is no threshold that rejects anything at zero cost.
What makes 0.28% acceptable is what it replaces: the local model's own false-reject
rate on this population is 3/150 = **2.0%** (`priors_ablation`, unchanged across v4 and
v5). The filter is about seven times safer than the call it removes, and writes the
same class of verdict — single-model, never precedent, never able to price.

And against the model directly, on live data, no review session needed — the 435
contested pairs of 2026-08-22 already carry the local model's own banked verdicts:

| reject below | filtered of 435 | the model also REJECTED | the model MATCHED |
|---|---|---|---|
| **1e-4** | **21** | **19** | **0** |
| 1e-3 | 48 | 41 | 5 |
| 1e-2 | 76 | 54 | 16 |

Zero disagreement at the default and five at the next decade is what sets it there.
4.8% fewer model calls is modest, and modest is the right size for a first filter whose
failure mode is a cell that never gets priced. Two of the 21 were headed for
`escalated`, so the filter also removes them from Claude's queue — the phase's goal
rather than a side effect, but a real change to what a reviewer is shown.

Exercised on a COPY of the graph, never the live one: 19 filtered of 412 contested,
`v_current_rows` unchanged at 15,648. `helper_rejected` is bankable, ranks just below
`llm_rejected`, and `authority.py` rules it `single_model` even behind five `banked: `
prefixes.

### 6. The def split, and what it does not touch

`sweep.py --contested-defs` gives LANE 3 the graph's definitions and leaves identity
and coverage on the staple catalogue. Measured: **identity 181, coverage 86 —
byte-identical to the daily numbers** — while contested goes 15 -> 435. The wholesale
switch stays refused for the reason the fourth addendum gave: 130 identity findings
would silently stop being shown.

### 7. Wired, the same night

All three switches are on. `emit -> DEFS -> sweep -> serve -> resolve (behind the
filter) -> stage1 -> stop`, run end to end at 01:24 and clean, card handed back.

The load-bearing decision is WHERE the flags default. `audit-semantic-identity.ps1`
holds them, not the caller: the nightly chain is not the only thing that runs the
sweep - the 07:00 and 08:00 jobs do too - so flags passed by one caller would have
meant the last sweep of the day silently overwrote `contested-scores.json` with a
15-of-435 version scored by the pinned model, and the scorecard would have read the
BEFORE forever. One default, every caller, one file.

`contested-scores-history.jsonl` now gets one trimmed line per run (~40 KB), because
the snapshot was the reason nobody could look at more than one night, and an
overwritten night cannot be re-scored - the definitions it read have moved on.

Tonight's run scored 0 of 0: the 21:30 chain had already settled everything, and the
next capture makes the next contested set. That is the steady state this plan aims at.

### 8. On the scorecard

The local lane now prints which model held the opinion, which def set it read, and what
the filter rejected, distinguishing "rejected 0" from "the filter is off" from BLIND.
Before the wiring it read `scored 15 of 435`, `scored by the PINNED model`,
`routes nothing`; after it reads `defs commodity-defs-graph.json`, `scored by
sidecar/models/resolve-ce-v1`, `routes reject-only`. It also separates ARMED-AND-QUIET
from OFF, because zero rejections with a trained helper means nothing fell below the
threshold, while zero without one means resolve.py refused to filter at all - a
configuration fact, not a result.

### 9. What phase 3 did not do

§4's audit set (helper YES / LLM NO, where the ~35 missing cells live) is not built.
It is the one part of the phase that costs a Claude review session, and it wants a few
nights of contested scores from the trained helper behind it rather than one.

One correction to the brief that framed this session: there was **one** night of
contested scores, not several, and `contested-scores.json` is a snapshot the sweep
overwrites rather than a history — so "look at more than one night" was not available
on any timeline. If nightly accumulation is wanted, that is a change worth making
deliberately.

## Addendum 2026-08-23 (second) — round 2, an adjudicator, and why v2 lost

Phase 3 shipped ft-v1 and wired it. This is the same night's follow-on, on a card the
nightly chain had already handed back.

### 1. Round 1 was mined by the wrong model

`mine-products.json` → top-k by the **bi-encoder** → pairs the bi-encoder finds
confusable. The thing being trained is a **cross-encoder**, which finds different things
confusable. `--rerank-with` scores every top-k candidate with a trained copy and also
keeps the ones IT still believes: **436 pairs beyond the cosine margin, 431 never
surfaced by round 1**.

What that pile is, read before training on it: canned corn against `frozen-corn`, heavy
cream against `whipped-cream`, liquid detergent against `laundry-pods`, fresh salmon
against `canned-salmon`. FORM and PACK confusions — the wrong-crown class this board
exists to prevent, and the class a regex is blind to.

### 2. The hazard, and the measurement that retires it

A mined pair's label is the candidate commodity's regex, and the pairs a good model
scores highest are exactly the ones most likely to be MISLABELLED. Round-2 mining
concentrates the corpus on those pairs, so it concentrates the label error too.

So the labels were adjudicated. A Fable agent ruled on all 224 pairs ft-v1 scores above
0.9, given the product name and the commodity's accepted examples and nothing else — no
score, no regex, no board access, the same independence rule §2 step 3 applies to the
local model. 224 answered, 0 join misses, 0 strays.

    YES 3    NO 212    UNSURE 9

**The regex was right 95% of the time on the hardest slice available.** And two of the
three YES verdicts INDEPENDENTLY REPRODUCE rulings the estate already holds — the Penguin
cheddar crackers and No Yolks Egg White Noodles are both gold matches whose mined label
phase 3a had to overrule. The agent had neither.

UNSURE is not a label: those 9 are dropped from the corpus rather than falling back to
the regex, because the regex is what was in doubt.

The third YES is a live board defect, reported and never applied
(`out/mined-rule-gaps.json`): `Lunch Mate Mesquite Turkey Breast 9 OZ` is priced as
`turkey-breast` and reads as sliced lunchmeat.

### 3. The rigged arena, named rather than used

The round-2 test set is NOT a fair arena: its negatives were selected *because* ft-v1
scores them high, so it is rigged against ft-v1 by construction. Stock confirms it —
0.9064 there against 0.9127 on the round-1 holdout; the set is simply harder. The fair
arenas are the round-1 holdout (chosen by the bi-encoder before either model existed)
and the 435 live contested pairs (which no corpus contains).

    model | A: AUC  neg<1e-4  TRUE lost | B: filtered  agreed  DISAGREED
    stock | 0.9126      108          5  |          9        8          0
    ft-v1 | 0.9672      469          2  |         21       19          0
    ft-v2 | 0.9652      461          2  |         19       17          1   <- rejected
    ft-v3 | 0.9674      434          0  |         18       17          0   <- promoted

    cold hardeval |    OLD   GOLD   MINED     (GOLD/OLD independent of every model)
    stock         | 0.9857 0.9572  0.9504
    ft-v1         | 0.9938 0.9920  0.9862
    ft-v2         | 0.9954 0.9891  0.9866
    ft-v3         | 0.9958 0.9939  0.9881

### 4. Why ft-v2 lost, which is the useful part

ft-v2 is the round-2 corpus with REGEX labels. It lost both gates. The diagnostic:

    round-2-only negatives    still believed > 0.5
    v2's TRAIN split (275)    ft-v1 160/275  ->  ft-v2   2/275
    held-out TEST split (153) ft-v1  95/153  ->  ft-v2  44/153

It memorised what it saw and **generalised partially to unseen negatives of the same
class** (mean 0.657 → 0.314). The signal is real and it transfers. It simply cost more
calibration elsewhere than it bought — 8 fewer negatives caught at the operating point,
and one live disagreement where v1 had none.

And because the adjudication then showed the labels were 95% right, **v2's loss was
never label noise**. It is a genuine capacity trade-off, which means the next round needs
more data or a different loss, not better labels. That is a more useful thing to know
than a win would have been.

### 5. What was promoted, and the trade it makes

ft-v3 — the same corpus with adjudicated labels — beats v1 on all three cold hardeval
numbers including GOLD, the one the third addendum designated as deciding, and disagrees
with the local model on 0 of 435. One line in `audit-semantic-identity.ps1`; v1 stays on
disk and that line is the whole revert.

The trade is named rather than buried: **18 filtered a night where v1 filtered 21,
bought with ZERO false rejects on the cold holdout where v1 loses 2.** For a reject-only
filter whose failure mode is a cell that never gets priced, fewer-and-safer is the right
side of that.

**1e-4 stays**, checked rather than assumed: both models hit their first live
disagreement at 3e-4, so v3's own optimum is the same cut v1 was calibrated at.
Promoting a model on the previous model's threshold would have under-used it.

### 6. Where an agent helped and where it would not have

The mine → label → build → train → gate path is deterministic scripts, and the binding
constraint is one 16 GB card that holds exactly one training run at a time — so fan-out
buys no wall-clock and a model in that path would only add nondeterminism to a
measurement. The one non-deterministic weakness was the LABELS, and that is the only
place an agent was used. Four ran concurrently because none of them needed the card.
