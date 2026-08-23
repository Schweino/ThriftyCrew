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
