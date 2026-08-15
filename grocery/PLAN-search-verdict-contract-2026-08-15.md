# PLAN: the search-verdict contract (three-state store search, retry ladder, unit passthrough)

Written 2026-08-15 for handoff. Everything in here was learned from the Recipe Hunter trial run that day;
nothing is speculative. The implementer should read this file top to bottom before touching code, then keep
the Evidence section open while writing the fixtures - every must-fire fixture below is a real event from
that trial, not an invented example.

## The defect class, in one sentence

Every store-search lane in the estate currently conflates three different outcomes - "searched and found
nothing", "search returned something unusable", and "could not really search at all" - into one thin result,
and a thin result reads exactly like an absence, so the flow's failure mode is confidently recording
`not-carried` for products sitting on the shelf.

## Evidence (2026-08-15 trial, all verified)

E1. `probe-ingredient.ps1 'chipotle powder'` -> NO-CANDIDATES at BOTH server stores. `'ground chipotle'` ->
    the actual jar at Baker's ($14.49 / 2.3 oz). The first query would have recorded not-carried for a
    shelved product.
E2. `probe-ingredient.ps1 'cumin seeds'` at Baker's -> exactly ONE hit, a Carol's Daughter HAIR CONDITIONER
    (made with black cumin seed oil). `'cumin'` -> Tampico Cumin Whole, $1.69/1 oz. A one-hit result is not
    evidence of anything except that the query was too narrow.
E3. `'cornmeal'` -> zero at Family Fare; `'corn meal'` -> the store-brand 32 oz bag. A SPACE changed the
    answer. Same shape: `'brown lentils'` -> zero at FF, `'lentils'` -> Our Family Lentils.
E4. `'guajillo chile'` -> NO-CANDIDATES at both stores; `'guajillo'` -> the dried pods at both. Adding the
    MORE precise word made the result WORSE. Extra qualifiers shrink the set toward zero, they do not re-rank.
E5. Aldi (storefront search, in-app browser pane): searching `fennel` renders the literal text
    `No results for "fennel" - Browse related items` and THEN renders 29 `a[href*="/products/"]` tiles that
    are SUGGESTIONS (parsley, green onions). Green onions appeared as a "result" for bean-sprouts, fennel,
    AND chili-garlic-sauce. Counting tiles says 29; the truth is 0. Any tile-count-based carriage ruling on
    an Instacart-platform storefront (Aldi, Fareway) is unsound without the no-results check first.
E6. Fareway session verified on the WRONG STORE: Apollo cache `retailerLocation 513473`, coordinates
    41.63,-93.62 (Des Moines - Euclid), while Omaha is `531573` / "17070 Audrey Street, Omaha NE 68136",
    zoneId 917. The on-screen label alone was NOT the tell; the Apollo address was. Prices read from that
    session would have been real Fareway prices for the wrong city.
E7. Walmart search -> "Robot or human?" page. A genuine bot wall. That is `blocked`/UNUSABLE, and it must
    never decay into not-carried.
E8. Prior art already in the estate (grocery-method-fareway.md, 2026-08-03 sweep): "Terms that return an
    empty grid are usually TRANSIENT, not genuinely absent - 6 came back empty and all 6 returned 6-28
    candidates on a single retry with a flat 7s wait." The transient-retry rule below is that lesson,
    promoted from prose into the contract.
E9. `fennel` has unit `each` (the BULB) and `coconut` has unit `each` (the WHOLE FRUIT). Tier-1/tier-2
    tooling never printed the unit, so the only thing standing between "11 fennel-seed shakers" and a wrong
    carriage ruling was the operator happening to know the unit from elsewhere. Two near-misses in one run.

## The contract

One verdict object, produced by EVERY search lane (server probe, Aldi/Fareway storefront, Walmart/Sam's
Next.js, Hy-Vee rendered page), before any adjudication happens:

```
{
  state:      'MATCHES' | 'EMPTY' | 'UNUSABLE',
  term_used:  '<the exact query string that produced this state>',
  attempts:   [ { term, state, hits, note } ... ],   # the full retry ladder, in order
  hits:       [ { name, price, size, url } ... ],     # only when MATCHES
  reason:     '<for EMPTY/UNUSABLE: the human-checkable why>'
}
```

State meanings and the ONLY conclusions each allows:

| state    | meaning                                                                  | allowed conclusion |
|----------|--------------------------------------------------------------------------|--------------------|
| MATCHES  | a real result grid with >= 1 genuine product row                         | adjudicate normally (a MATCH is still not a carriage ruling - the pricer judges "is this the ingredient") |
| EMPTY    | explicit no-results, or only a suggestion/related-items block, AFTER the full retry ladder | `not-carried` for that store |
| UNUSABLE | bot wall, CAPTCHA, wrong-store identity, timeout, page never rendered    | `blocked` - NEVER not-carried |

Hard rules the contract encodes (each one is an Evidence item):

R1. NO-RESULTS PHRASE BEFORE TILE COUNT (E5). If the page contains a no-results phrase ("No results for",
    "couldn't find", "did not match", "0 results"), the state is EMPTY-so-far regardless of how many product
    links render. Tiles below a no-results phrase are suggestions.
R2. THE RETRY LADDER (E1-E4). A multi-word term whose first query lands EMPTY or returns 0-1 hits is NOT
    concluded; it walks a deterministic ladder and the verdict records every rung:
      rung 1: the full term as given
      rung 2: the term with QUALIFIER words stripped:
              qualifiers = powder, ground, dried, whole, seeds, seed, fresh, chopped, sliced, raw, chile,
              chiles, sauce*  (*only when >2 words remain without it)
              'chipotle powder' -> 'chipotle'; 'cumin seeds' -> 'cumin'; 'guajillo chile' -> 'guajillo'
      rung 3: spacing variants - joined and split forms of compound words
              'corn meal' <-> 'cornmeal'; 'bean sprouts' <-> 'beansprouts'
      rung 4: the single longest word of the term ('brown lentils' -> 'lentils')
    Stop at the first rung that yields MATCHES with >= 2 genuine hits (>= 1 is acceptable only when the hit
    plausibly IS the ingredient - one hair-conditioner hit is why the threshold exists, E2). A rung that
    widens the candidate pool NEVER widens the ruling: every hit still goes through adjudication. The ladder
    exists to prevent false absence, not to manufacture presence.
R3. TRANSIENT RETRY (E8). A browser-lane EMPTY (no no-results phrase, just a blank grid) gets ONE flat-7s
    retry of the same term before the ladder advances. Six of six Fareway empties resolved this way.
R4. IDENTITY BEFORE ANY VERDICT (E6, E7). Wrong store, wrong club, wrong fulfillment mode, bot wall =>
    UNUSABLE for that store for the whole batch. The check is store-specific and machine-readable, never the
    on-screen label alone:
      Aldi:    body text matches /In-Store[^|]{0,40}ALDI - OLA 42 - Omaha/ (mode AND store in one line)
      Fareway: Apollo cache GetRetailerLocationAddress -> lineOneString == '17070 Audrey Street' (E6:
               retailerLocation 531573; shopId is REISSUABLE, never compare it), header reads In-Store
      Sam's:   club header is an Omaha club (13130 L St 68137)
      Hy-Vee:  store selector reads 'Omaha #01, NE'
      Walmart: no store toggle; UNUSABLE only on bot wall/timeout
R5. UNIT PASSTHROUGH (E9). Every surface that prints candidates prints the commodity's unit beside the term,
    with the each-clarifier: `fennel (each - the whole item, not a seed/spice form)`. The unit comes from
    commodities.json (fall back: recipe-board row's `unit`).

## Where to implement

### 1. New shared lib: `grocery/search-verdict-lib.ps1`

Pure functions only, no network, dot-sourced by both PowerShell callers. Contents:

- `Get-RetryLadder([string]$Term)` -> ordered, de-duplicated string[] implementing R2 rungs 1-4.
- `Test-NoResultsPhrase([string]$PageText)` -> bool implementing R1's phrase list.
- `New-SearchVerdict($State, $TermUsed, $Attempts, $Hits, $Reason)` -> the contract object.
- `Get-CommodityUnit([string]$IdOrTerm)` is NOT here - it needs file access; it lives in the callers, which
  already load commodities.json.

CRITICAL, ALREADY PAID FOR TWICE IN THIS ESTATE: the self-test switch must be NAMESPACED, e.g.
`-SearchVerdictSelfTest`, never `-SelfTest`. Dot-sourcing runs the lib's param() block IN THE CALLER'S
SCOPE; a lib declaring `[switch]$SelfTest` silently resets the caller's own `$SelfTest` to false. On
2026-08-15 that exact mistake disarmed pull-regular-familyfare's hermetic self-test and ran a LIVE Freshop
pull instead. See ff-price-lib.ps1's header for the worked example to copy.

Self-test fixtures (hermetic, must-fire + clean twin, per the estate's guard-fixture rule):
- ladder('chipotle powder') contains 'chipotle' before any single-word rung (E1)
- ladder('cumin seeds') contains 'cumin' (E2)
- ladder('corn meal') contains 'cornmeal' AND ladder('cornmeal') contains 'corn meal' (E3)
- ladder('guajillo chile') contains 'guajillo' (E4)
- ladder('lentils') == @('lentils')  (single word: no ladder, clean twin)
- Test-NoResultsPhrase on the literal Aldi capture `No results for "fennel" Browse related items or try
  another search` -> $true (E5, frozen verbatim)
- Test-NoResultsPhrase on a normal grid header -> $false (clean twin)

### 2. `grocery/probe-ingredient.ps1` (exists; modify)

- Replace the single-query search in `Probe-Bakers` / `Probe-FamilyFare` with the ladder: walk
  `Get-RetryLadder`, stop per R2, return the verdict object inside each store block (keep the existing
  `state: OK/ERROR/NO-CREDENTIALS` wrapper; add `verdict`).
- Emit `attempts` in both text and -Json output so a reader can SEE that 'chipotle powder' failed and
  'chipotle' succeeded - the ladder being visible is what makes a false absence auditable.
- Print the commodity unit line per R5. probe-ingredient already dot-sources ff-price-lib; add
  search-verdict-lib the same way (note again: namespaced switch).
- Its own `-SelfTest` gains one must-fire: a fake results array where the only hit is the hair conditioner
  must NOT produce MATCHES-with-confidence (i.e. 0-1 hits on rung 1 must advance the ladder).
- Existing behavior to preserve: relevance is a SORT HINT; the script still refuses carriage verdicts
  (header comment already explains the Saffron Road noodle incident - do not regress it).

### 3. `grocery/price-ingredient.ps1` (exists; minor)

- Print the unit beside MAPPED/CAPTURE/ABSENT lines (R5). One line per term. Nothing else changes - its
  two-board resolution was fixed 2026-08-15 and is correct.

### 4. `C:\Codex\ThriftyCrew\.claude\agents\recipe-hunter-pricer.md` (exists; modify prose)

The browser lanes cannot share PowerShell code, so the agent's instructions carry the SAME contract in
prose. Add a section "The search-verdict contract" that states R1-R5 with the store-specific identity checks
from R4, the ladder from R2, and the flat-7s transient retry from R3. Replace the current ad-hoc "retry with
the head noun" sentence with the full ladder. Require the agent to record, in every
`ingredient-queue.ps1 -Record ... -Evidence`, WHICH ladder rung produced the ruling and (for EMPTY) that the
no-results phrase was checked - evidence like "rung 2 'chipotle': 12 tiles, no no-results banner, none are
the powder" is checkable; "not found" is not.

Also fold in the two browser findings from 2026-08-15 that are already written into the agent but must
survive any rewrite: Aldi's two-step In-Store switch (select, then Confirm - the first click alone silently
does nothing) and cold-sessions-default-to-Delivery.

### 5. `grocery/ingredient-queue.ps1` (exists; do NOT change states)

The queue's states (carried / not-carried / blocked / error) already map 1:1 onto the contract
(MATCHES-adjudicated-yes / EMPTY-final / UNUSABLE / tool failure). Do not add states. Optionally: reject a
`-State not-carried` whose `-Evidence` does not mention a ladder rung or the no-results check - same spirit
as the existing rule that a carried claim without a price is refused. Low priority.

## The Fareway store-switch (separate, smaller task)

The session must be switched Des Moines -> Omaha (Brad's standing instruction: Fareway is ALWAYS Omaha,
In-Store). What is known:

- The picker opens: storefront -> "Change store" (the one under the In-Store option) -> dialog "Near 50313,
  Choose an In-Store location" with a search input.
- Synthetic value-setting does NOT work: native setter + input events (both single-shot and per-character)
  left the list pinned to "Near 50313". The zip field's value visibly holds '68136' but the store list never
  re-queries. It is a controlled/debounced places-autocomplete.
- NOT yet tried, in order of cheapness: (a) `mcp__Claude_Browser__form_input` on that field (purpose-built
  for controlled inputs); (b) `computer type` into the focused field - requires the Browser pane to be
  VISIBLE (a hidden pane does not composite; screenshot/click time out with exactly that error); (c) the
  claude-in-chrome extension once connected - real keystrokes, and it also carries Brad's logged-in Sam's
  session, which the in-app pane never will.
- After any switch: re-verify per R4 via the Apollo address (531573 / 17070 Audrey Street), NOT the label,
  and confirm the header reads In-Store. Then the two silent Fareway extractor defects and their capture-time
  avoidances are already documented in grocery-method-fareway.md - read it before extracting anything.

## Verification gates (run all before calling this done)

1. `search-verdict-lib.ps1 -SearchVerdictSelfTest` passes; `probe-ingredient.ps1 -SelfTest` passes;
   `pull-regular-familyfare.ps1 -SelfTest` STILL passes (the dot-source clobber canary).
2. Live: `probe-ingredient.ps1 'chipotle powder' 'cumin seeds' 'corn meal' 'guajillo chile'` - all four must
   reach MATCHES on a ladder rung, with the rung visible in output. These are E1-E4 re-run for real.
3. Live twin: `probe-ingredient.ps1 'purple unicorn fruit'` walks the full ladder and lands EMPTY - the
   ladder must not manufacture presence.
4. Browser (when a browser surface is available): Aldi `fennel` must come back EMPTY with reason naming the
   no-results banner, not 29 suggestion tiles (E5 re-run).
5. `ingredient-queue.ps1 -SelfTest` still passes (nothing there should change).
6. Commit message: write it via a quoted heredoc (`git commit -F - <<'EOF'`), never an interpolating shell
   string - backticks/$ in an unquoted message were command-substituted on 2026-08-15 and corrupted the
   recorded numbers ($45 became 5).

## PS 5.1 traps the implementer WILL otherwise hit (all hit during this build, references in-repo)

- Dot-sourced param() clobber -> namespaced self-test switches (ff-price-lib.ps1 header).
- `powershell -File script.ps1 -Slugs a,b` marshals the array as ONE string 'a,b'; use -Command with a real
  array (reanchor-machine-fields was silently a no-op this way on 2026-08-15).
- `@(ConvertFrom-Json ...)` double-wraps a JSON array (price-ingredient.ps1 has the worked comment).
- `Get-Content -Raw` decodes ANSI and mangles non-ASCII; use `[IO.File]::ReadAllText(..., UTF8)` (the
  catalog carries (R)/(TM) glyphs inside regexes).
- Naming a local accumulator `$out` when a param declares `[string]$Out` coerces the ArrayList to String
  (grocery-method-fareway.md).

## Do NOT

- Do not weaken Rule B (one store carrying = CARRIED; not-carried only when all seven CHECKED) or the
  queue's unchecked-is-never-not-carried invariant - the trial proved both are load-bearing.
- Do not let the retry ladder rule on carriage. It gathers candidates; adjudication stays a judgment call
  (the $14.49 Spice Islands chipotle at Baker's is still flagged as double the usual price and unverified -
  a MATCHES verdict did not make it publishable).
- Do not touch pull-order-*.txt, compare-deals, or any publish path from this work. The contract is a
  read-side improvement; nothing here writes a board cell.
