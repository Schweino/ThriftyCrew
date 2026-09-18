# PLAN: Baker's weekly ad from its own text feed, priced by the Kroger API (2026-09-18)

Brad's ruling, 2026-09-18: the Baker's weekly ad is captured automatically every week. We already know the timing.
We do not re-check all 602 terms; we check what the new ad puts on sale, and the old ad needs nothing.

## Why this exists (measured 2026-09-18)

- The Kroger API lane (`pull-regular-bakers-api.ps1`) asks 7 of 602 terms a day (capture-policy quarterly rotation,
  default call cap 25). It prices a sale correctly when it asks, but it cannot DISCOVER what newly went on sale.
- The only discovery path was the flyer (`out\bakers\bakers-deals-<date>.json`), a vision read of przone page images
  done by the Wednesday Chrome agent, retired 2026-08-22. It landed by hand in 5 of 8 ad weeks since. The week of
  09-09 it supplied 17 Baker's sale cells and 3 crowns (clementines, coffee-pods, pasta-sauce) the API had not.
- The OLD ad needs no work: every stored promo row carries `ad_to` and its regular price, and compare-deals refuses
  expired ad prices (0 of 526 Baker's cells priced from the expired 09-09 ad on 09-17).

## The source (found 2026-09-18, headless, no key, no cookie)

`https://oms-kroger-webapp-da-classic-api-prod.przone.net`
- `GET /api/dacs/<adId>?location=61500319` returns adId, weekNumber, startDate, endDate, circularType, pages[].
- `GET /api/dacs/<adId>/pages/<eventPageId>?location=61500319` returns contents[]; each `contentType: "Offer"` has a
  `mapConfig` JSON string whose `content` holds `id`, `headline`, `bodyCopy`, and `stores` (location numbers).
- Measured for the 09-16..09-22 ad: 14 pages, 169 offers, 169 unique, all 169 list Saddlecreek 61500319.
- PRICES ARE NOT IN IT (2 of 169 bodies carry a `$`). It is the LIST. The Kroger product API supplies the price.
- Gated, do not build on: `/api/dacs/<id>/offers/<id>` ("Api Key was not provided"), `/api/dacs?location=` (401),
  `api.kroger.com/digitalads/v1/circulars` (400 with our client-credentials token).

**The adId is a GUID that changes weekly and is the ONE browser-dependent input.** Loading
`https://www.bakersplus.com/weeklyad` (Saddlecreek store set) requests `/api/dacs/<adId>?location=61500319`, readable
from `performance.getEntriesByType('resource')`. One page load a week, no vision.

## The build

1. **Ad id capture (browser, once per ad week).** Inside the 08:00 daily capture's existing real-Chrome driver, when
   Baker's ad has rolled over (ad-schedule.json, or no ad-id file for the current window), load the weekly-ad page
   once and write `out\bakers\bakers-ad-id-<startDate>.json` {adId, location, captured, source_url}. Also accept a
   hand-supplied adId via parameter so a person can recover a missed week. VERIFY the fetched ad's startDate/endDate
   contain today before trusting it.
2. **Ad list pull (headless).** New `grocery\pull-bakers-ad-list.ps1`: reads the ad-id file, fetches the dacs root and
   every page, keeps offers whose `stores` include 61500319, writes `out\bakers\bakers-ad-list-<startDate>.json`
   {ad_id, week_number, ad_from, ad_to, offers[{id, headline, body, page}]}. Refuses (exit non-zero, loud) on 0 offers,
   a window not containing today, or a page fetch failure. Never guesses.
3. **Route the list onto terms with the ENGINE'S matcher, not word matching.** Naive phrase matching linked only 41 of
   169 offers to a Baker's term (misses: pasta sauce, chicken breasts, soda, bath tissue, detergent). Split each
   offer's text on ` or ` / `;` into candidate product phrases, route each through `match-lib.ps1`
   (`Resolve-Commodity`, the same matcher compare-deals uses), and map the commodity to its Baker's search term(s)
   from the term list the API lane already uses. Record the unrouted offers in the list file (they are evidence, e.g.
   alcohol and non-tracked goods, never silently dropped).
4. **Ask those terms first on ad day.** In `capture-policy-lib.ps1`, add the routed ad terms at the HEAD of Baker's
   worklist as `ad_terms`, the same mechanism as Walmart's `ruling_terms` (derived, empties itself once a
   bakers-regular file proves each term was asked inside the current ad window). Their calls come out of a separate
   ad-day allowance, not the rotation drip, so the quarterly cursor never advances over a displaced term. The Kroger
   API's documented limit is far above this (tens of terms vs thousands of calls a day); state the cap used.
5. **Checks follow the new producer.** `check-ad-cycles.ps1`'s Baker's backing decision (ad-schedule-backing-lib) and
   `audit-row-age` / the capture watchdog's AD STALE count treat a current `bakers-ad-list` plus asked ad terms as the
   ad being captured. The old flyer file stops being expected. The alert must still fire when the list or the asks
   did not land.
6. **Retire the flyer dependency** in `$adSupplement` for Baker's once 5 is green, keeping old flyer files readable.

## Proof (gated like any triage code item)

- MUST FIRE: a frozen copy of the 09-16 dacs root + pages; the pull writes 169 offers and the router yields the
  pasta-sauce, coffee-pods and chicken-breast terms. A list whose window excludes today refuses. 0 offers refuses.
- CLEAN TWIN: on a non-ad day with a current list already asked, Baker's worklist is the normal 7-term rotation.
- MUST FIRE: the watchdog/check-ad-cycles still pages when the ad rolled over and no list landed.
- Live: run the pull for the current 09-16..09-22 ad today, ask its terms once, rebuild, and read the pasta-sauce,
  coffee-pods and clementines Baker's cells on the live board (they were lost when the 09-09 flyer expired).

## Rollback

Remove `ad_terms` from the worklist and the two new scripts; the API lane returns to rotation-only. No data migration.

## Built 2026-09-18 (landed b92c93874)

- `grocery\pull-bakers-ad-list.ps1` (list + routing + refusals), `capture-policy-lib.ps1` (`Get-BakersAdOwed`,
  `Get-BakersAskPlan`, `Get-BakersAdCaptureState`, worklist `ad_terms`), the API lane asking owed ad terms first,
  `check-ad-cycles` / `ad-schedule-backing-lib` / `audit-ad-status` / `audit-row-age` judging Baker's on the list plus
  its asks, and `capture-run` + `pull-browser-stores.py --bakers-ad-id-out` reading the id once per ad week.
- Routing on the 09-16 ad: 169 offers, 90 routed onto 85 search terms, 79 unrouted (listed in the file). Brand-only
  headlines of tracked goods (Pepsi, Tide, Doritos, Swanson, Progresso, Dasani...) are the main unrouted class; filed
  to the weekly lane rather than widened here, because that is a catalogue change.
- Cap used: Baker's 250 search terms a day (StoreCallCap, basis 'proposed'); the ad takes the expiry allowance,
  250 - 7 = 243. The Kroger Products API's published daily limit was NOT confirmed on 2026-09-18 (its docs pages
  render client-side); the claim above that it is thousands a day is the plan's, unverified here.
- The Chrome read: the first live load from a brand-new profile saw no `/api/dacs` request in 90 s; a second load
  minutes later (another fresh profile) saw 15, with Saddlecreek preselected. Cause of the first miss not
  established, so the driver now reloads once on a miss and records the page's title, text and frames.

## Not in scope

Pricing basket offers ("buy 5 save $1"), BOGO interpretation: the Kroger API's own promo price is what we record, the
same as every other API row. Hy-Vee, Aldi, Family Fare and Fareway ad lanes are untouched.
