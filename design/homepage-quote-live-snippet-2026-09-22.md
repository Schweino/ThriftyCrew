# Homepage quote: the live snippet to paste (2026-09-22)

**For Brad, in your browser.** Ghost integration tokens cannot write Settings, so this is a paste, not a publish.
Ruling A (2026-09-21): the homepage quote "Fourteen servings at about $2.40 each" becomes live. Plan item
`discovered:homepage-quote-live-2026-09-21`, ruling id `Q-homepage-injection-session`.

## Do this only after the alfredo rebuild is live

The quote reads the price of `/free-chicken-alfredo/` from the feed. Until the rebuilt engine recipe is published
AND the feed carries `recipes["free-chicken-alfredo"].everyday_ps` (a landing dependency, see the plan), the span
shows its fallback. That is safe (a real price on the fill's own basis, never blank), but the paste is only worth
doing once those two have landed. The integrator tells you when.

**Checked 2026-09-23 (integrator):** `/free-chicken-alfredo/` is live and public; its built card and its live post
both carry `data-tc-fallback="2.00" data-tc-asof="2026-09-22T08:14:34"`, and the live card fills `~$2.00` against the
served feed of `2026-09-23T00:21:31`, so 2.00 is a real price on the fill's own basis today. The served feed does NOT
yet carry `recipes["free-chicken-alfredo"]` (566 recipes, no alfredo), so until the next daily export ships it the
pasted span shows that 2.00 fallback. The Step 2 text is on the live homepage exactly once. Queue item
`2026-09-23-749d31` owns the feed key.

## Step 1. Re-read the fallback right before you paste

The fallback below was stamped at build time on 2026-09-22 against the feed generated `2026-09-22T08:14:34`:
**2.00** (the rebuilt card's own fill, everyday prices, whole packages, per serving). At paste time the integrator
reads the current one from the built card, so the fallback is never older than the build it came from:

```
powershell -NoProfile -Command "[regex]::Match((Get-Content meal-prep\db\built\free-chicken-alfredo.body.html -Raw), 'data-tc-fallback=\"([^\"]+)\"[^>]*data-tc-asof=\"([^\"]+)\"').Groups[1..2].Value"
```

Put that number in BOTH places marked `2.00` below, and that timestamp in `data-tc-asof`.

## Step 2. Settings > Code injection: find this exact text

Search both boxes. `design/PLAN-live-recipe-prices-2026-09-21.md` measured the quote inside the Site Footer script
(after `</main>`, gated on `body.home-template`); the memory on the homepage redo records the `mts-home` block in the
Site Header. Whichever box holds it is the one to edit, and it holds it exactly once (one occurrence on the live
homepage, read 2026-09-22).

```html
<a class="mts-free-card" href="/free-chicken-alfredo/"><span class="mts-q">&ldquo;Fourteen servings at about $2.40 each. Dinner sorted, money saved.&rdquo;</span><span class="mts-l">Chicken Alfredo &rarr;</span></a>
```

(It sits in the "Read these free" grid of the homepage block, after the "Why Meal Prep" card. Use the editor's find.)

## Step 3. Replace it with this

```html
<a class="mts-free-card" href="/free-chicken-alfredo/"><span class="mts-q">&ldquo;Fourteen servings at <span data-tc-live-price data-tc-slug="free-chicken-alfredo" data-tc-field="cost_ps" data-tc-basis="feed-everyday-whole-package" data-tc-fallback="2.00" data-tc-asof="2026-09-22T08:14:34">~$2.00</span> each. Dinner sorted, money saved.&rdquo;</span><span class="mts-l">Budget Chicken Alfredo &rarr;</span></a>
```

The span is exactly what `Format-TcLivePriceSpan -Slug free-chicken-alfredo -Field cost_ps` writes, so every check that
knows a live placeholder knows this one. "about" went away because the `~` already says it.

## Step 4. Add the fill script once, at the very end of Site Footer

```html
<script src="https://feed.thriftycrew.com/tc-live-price.js" defer></script>
```

This is the same fill every recipe card runs (generated from the card template by
`meal-prep/pipeline/build-live-price-script.ps1`, served from the feed Worker beside `smp-feed.json`). It touches
only `[data-tc-live-price]` spans, so it is inert on every page that has none. A recipe card that loads it too is
harmless: it guards against running twice and reads the same feed.

## Step 5. Check it (375 px and desktop)

1. Open https://www.thriftycrew.com/ in a private window. The card reads "Fourteen servings at ~$X.XX each", where X.XX
   is today's feed value, not 2.00, once `everyday_ps` has shipped.
2. In DevTools, the span carries `data-tc-filled="X.XX"`. No attribute means the feed did not fill it and you are
   seeing the fallback.
3. At 375 px wide the card does not wrap badly and nothing scrolls sideways.
4. The next morning's `sitewide-prices` lane reports `(home)` one literal lower than its mark of 3 and says
   RATCHET CAN TIGHTEN; the mark is lowered in a commit.

## Two more literals on the same homepage (optional, same session, your call)

The monitor counts three grocery literals on the homepage; the quote is one. The other two are in the same
injection block, and ruling A named only the quote, so these are offered, not done:

- `A meal-prep batch from the recipes inside feeds you all week at $2 to $3 a plate, and this week&#39;s cheapest lands at $1.54.`
  -> `A meal-prep batch from the recipes inside feeds you all week for a fraction of that, and every recipe shows its live cost per serving.`
  ("$1.54" is a typed cheapest-recipe price too; nothing shows it is refreshed.)
- `Most land at $2 to $3 a plate.` -> `Every one shows its live cost per serving.`

"Takeout runs $12 to $15" and "$25 of takeout is almost a week of home dinners" are restaurant prices, not grocery
prices, and are outside ruling C and the monitor's shape.

## Roll back

Paste the Step 2 text back over the Step 3 text and remove the Step 4 tag. Nothing else reads either.
