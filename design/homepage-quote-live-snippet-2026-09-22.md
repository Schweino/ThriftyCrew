# Homepage: the live snippet to paste, ALL THREE values in ONE edit (2026-09-22, extended 2026-09-23)

**For Brad, in your browser.** Ghost integration tokens cannot write Settings, so this is a paste, not a publish.
Two rulings are in it:

- Ruling A (2026-09-21, `Q-homepage-injection-session`): the quote "Fourteen servings at about $2.40 each" becomes live.
- `Q-homepage-two-more-literals` (plan-2026-09-22-6), Brad 2026-09-23, verbatim: **"Make them live"**. The two other
  typed grocery literals on the homepage, "$2 to $3 a plate" (twice) and "this week's cheapest lands at $1.54", now
  render from the feed at view time.

Everything below was checked on 2026-09-23 against the LIVE `codeinjection_foot`, read through the Ghost Admin API with
a GET only (nothing was written): 64,544 characters, and each of the three find strings in Step 2 occurs there
**exactly once** (and not at all in `codeinjection_head`). After all four changes the footer is **65,311 characters,
224 under Ghost's 65,535 hard limit**, and every inline script in it still parses (`node --check`, 8 of 8).

## What the three live values mean (the definitions live in the code, stated once)

| Span field | Reads | Definition | Today (feed generated 2026-09-23T00:21:31) |
|---|---|---|---|
| `cost_ps` (slug `free-chicken-alfredo`) | `recipes["free-chicken-alfredo"].everyday_ps` | the alfredo card's own fill: everyday prices, whole packages, per serving | not in the served feed yet, so it shows its fallback **~$2.00** (queue `2026-09-23-749d31` owns the key) |
| `cheapest_ps` | `recipe_stats.cheapest.everyday_ps` | the lowest `everyday_ps` over PUBLISHED recipes that are NOT HELD | **~$1.13** (`pizza-pasta-bowls`, 566 recipes) |
| `ps_range` | `recipe_stats.p25`, `recipe_stats.p75` | the 25th and 75th percentiles of that same population (linear interpolation), each rounded half-up to a whole dollar by the fill: the middle half of the catalogue. "$A" alone when both round alike | p25 2.91, p75 4.03, so **"$3 to $4"** |

`recipe_stats` is written by `meal-prep/pipeline/feed-everyday-ps.ps1` (called by `grocery/export-feed.ps1` every day),
the fields are registered in `meal-prep/lib/render-tokens.ps1`, and the fill is `fillLivePrices()` in
`meal-prep/pipeline/tpl2-scaler-prefix.html`, generated into `public/tc-live-price.js`. The copy said "$2 to $3" and
"$1.54"; today's feed says "$3 to $4" and "~$1.13". That difference is the reason for the ruling.

**Every span has a real fallback:** with no feed, or a feed without `recipe_stats`, the reader sees the stamped text
above, which is a real value of the same definition as of the `data-tc-asof` stamp. A range whose low end rounds below
$1, or a cheapest of 0, is refused and the fallback stays.

## Step 1. Re-read the fallbacks right before you paste (optional, the ones below are real as of 2026-09-23)

```
powershell -NoProfile -Command "$f = [IO.File]::ReadAllText('public\smp-feed.json') | ConvertFrom-Json; $f.generated; $f.recipe_stats | ConvertTo-Json -Compress"
```

If they moved, put `cheapest.everyday_ps` (two decimals) in the `cheapest_ps` span's `data-tc-fallback` and text,
`round(p25)-round(p75)` in both `ps_range` spans' `data-tc-fallback` with the text `$A to $B`, and `generated` in each
`data-tc-asof`. Or ask the integrator: `Format-TcLivePriceSpan` writes all three.

## Step 2 and 3. Settings > Code injection > Site Footer: three find-and-replace pairs

Use the editor's find on the **Site Footer** box. Each find string below occurs exactly once there.

**Pair 1 (the alfredo quote, ruling A). Find:**

```html
<a class="mts-free-card" href="/free-chicken-alfredo/"><span class="mts-q">&ldquo;Fourteen servings at about $2.40 each. Dinner sorted, money saved.&rdquo;</span><span class="mts-l">Chicken Alfredo &rarr;</span></a>
```

**Replace with:**

```html
<a class="mts-free-card" href="/free-chicken-alfredo/"><span class="mts-q">&ldquo;Fourteen servings at <span data-tc-live-price data-tc-slug="free-chicken-alfredo" data-tc-field="cost_ps" data-tc-basis="feed-everyday-whole-package" data-tc-fallback="2.00" data-tc-asof="2026-09-22T08:14:34">~$2.00</span> each. Dinner sorted, money saved.&rdquo;</span><span class="mts-l">Budget Chicken Alfredo &rarr;</span></a>
```

**Pair 2 (the value paragraph: the range and the cheapest). Find:**

```html
A meal-prep batch from the recipes inside feeds you all week at $2 to $3 a plate, and this week&#39;s cheapest lands at $1.54.
```

**Replace with:**

```html
A meal-prep batch from the recipes inside feeds you all week at <span data-tc-live-price data-tc-field="ps_range" data-tc-basis="feed-everyday-whole-package-iqr" data-tc-fallback="3-4" data-tc-asof="2026-09-23T00:21:31">$3 to $4</span> a plate, and this week&#39;s cheapest lands at <span data-tc-live-price data-tc-field="cheapest_ps" data-tc-basis="feed-everyday-whole-package-min" data-tc-fallback="1.13" data-tc-asof="2026-09-23T00:21:31">~$1.13</span>.
```

**Pair 3 (the Meal Prep tile). Find:**

```html
Most land at $2 to $3 a plate.
```

**Replace with:**

```html
Most land at <span data-tc-live-price data-tc-field="ps_range" data-tc-basis="feed-everyday-whole-package-iqr" data-tc-fallback="3-4" data-tc-asof="2026-09-23T00:21:31">$3 to $4</span> a plate.
```

All three sit inside the homepage block's JavaScript template literal (the `s.innerHTML = \`...\`` in the footer
script). Double quotes are safe there and none of the new text contains a backtick or `${`.

## Step 4. Add the fill script ONCE, as the very last line of Site Footer

```html
<script src="https://feed.thriftycrew.com/tc-live-price.js" defer></script>
```

It is not in the footer today. It touches only `[data-tc-live-price]` spans, so it is inert on every page without one.
The homepage block is injected on DOMContentLoaded, after a deferred script has run; the script fills again when the
feed arrives and once more at `load`, so the injected spans are reached either way. A recipe card that also loads it is
harmless: it guards against running twice and reads the same feed.

## Step 5. Check it (375 px and desktop)

1. Open https://www.thriftycrew.com/ in a private window. The value paragraph reads "at $3 to $4 a plate, and this
   week's cheapest lands at ~$1.13" (or whatever today's feed says), the Meal Prep tile reads "Most land at $3 to $4 a
   plate", and the quote reads "Fourteen servings at ~$2.00 each" until the alfredo key ships.
2. In DevTools each span carries `data-tc-filled` (`3-4`, `1.13`). No attribute means the feed did not fill it and you
   are seeing the fallback.
3. At 375 px wide the paragraph, the tile and the quote card do not wrap badly and nothing scrolls sideways.
4. The next morning's `sitewide-prices` lane reports `(home)` below its mark of 3 (a live span is not a literal) and
   says RATCHET CAN TIGHTEN; the mark is lowered in a commit.

## Noticed, not in this edit: the "Cheapest dinner" chip says a different number

The gold chip `#tc-chip-dinner` (also `$1.54` in the footer) is already filled by the footer's own script, but from a
DIFFERENT definition: the minimum `per_serving` over recipes with at least 550 calories (`$1.10` on today's feed), where
the sentence above now says the minimum `everyday_ps` (`~$1.13`). Two numbers for one "cheapest" on one page is the
same-fact-twice shape. It is recorded as `Q-homepage-dinner-chip-basis` in plan-2026-09-22-6 for your call; nothing here
changes it.

"Takeout runs $12 to $15" and "$25 of takeout" are restaurant prices, outside every ruling.

## Optional Pair 4, same class, NOT in the ruling (your call, `Q-mealprep-banner-literal` in plan-6)

Further down the same footer, the block gated on `body.tag-meal-prep.post-template` (so it renders on every meal-prep
post, not the homepage) says "an honest cost per serving (most land around $2&ndash;3 a plate)". It is the same typed
range, and no monitor sees it: `monitor-sitewide-prices` reads posts WITHOUT their scripts, and this text exists only
inside a script. The ruling named the homepage's two literals, so this is offered, not done. If you want it, it is one
more pair in the same edit. Find (occurs once):

```html
most land around $2&ndash;3 a plate
```

Replace with:

```html
most land around <span data-tc-live-price data-tc-field="ps_range" data-tc-basis="feed-everyday-whole-package-iqr" data-tc-fallback="3-4" data-tc-asof="2026-09-23T00:21:31">$3 to $4</span> a plate
```

With Pair 4 the footer is 65,472 characters, **63 under the 65,535 limit**: it fits, and it leaves almost no room for
the next edit, which is a reason on its own to weigh it.

## Roll back

Paste each find string back over its replacement and remove the Step 4 tag. Nothing else reads them.
