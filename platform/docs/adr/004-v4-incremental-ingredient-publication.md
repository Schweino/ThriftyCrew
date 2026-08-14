# ADR 004: Incremental ingredient publication

Status: accepted for flags-off implementation; production cutover requires the recorded parity, canary, rollback, and soak gates.

## Decision

Grocery ingredients, recipes, rankings, and promotions have independent version boundaries. A runtime ingredient is a versioned D1 definition. Its public value is one immutable snapshot containing exactly seven terminal Omaha store rows and one atomically moved per-ingredient current pointer. First-party evidence remains immutable in R2.

Ingredient publication is O(1) in catalog size and O(7) in store resolution. It may not read or mutate Git commodity configuration, create worktrees, deploy code, rematch products outside the ingredient candidate set, build a native/global release, swap the legacy release pointer, or recalculate unrelated recipes.

The seven store producer lanes and seven independent verifier lanes are store-oriented batches of at most 50 ingredients. A challenge blocks only its store. Publication requires all seven terminal results, at least one verified price, and different producer/verifier evidence. All-seven independently verified absence is permanent until an audited operator override.

## Rollout and rollback

`dynamic_ingredient_catalog_v4`, `store_catalog_batch_v4`, `incremental_ingredient_publish_v4`, and `incremental_recipe_resume_v4` begin `off` and support shadow, canary, and enforce. Public pointer changes are compare-and-swap. Failed origin verification restores only the affected ingredient pointer. Legacy data remains readable through the 30-day soak.

Healthy-path SLO excludes a declared retailer CAPTCHA/challenge, prolonged outage, or incomplete coverage; these are blocked states and cannot be converted to not-found.
