# Backlog run 2026-09-19: follow-ups from I167 (the adopted Ghost pages)

Filed by the I167 item agent. The 197 pages are exported under `content\ghost-adopted\` and declared in
`ops\ghost-page-estate.json`, so their numbers can now be read. Nothing below was checked yet unless it says so.

## The adopted calculators have never been checked against a known answer
`OPEN` `run-0919` `2-WAY` `RUNG1 READ`

15 of the 197 adopted pages carry a calculator script (counted 2026-09-19 as the files under
`content\ghost-adopted\` whose html contains a script tag): 50-30-20-budget-calculator, 52-week-savings-challenge,
compound-growth-calculator, debt-payoff-calculator, debt-payoff-tracker, emergency-fund-calculator,
hourly-to-salary-calculator, monthly-budget-worksheet, mortgage-payment-calculator, net-worth-calculator,
no-spend-challenge-calendar, savings-goal-calculator, true-cost-of-a-car, unit-price-comparison-calculator,
weekly-meal-prep-planner. Read by eye only, the first obvious checks are:

- mortgage-payment-calculator: the standard amortising payment with property tax and insurance added monthly.
  Check one textbook case (for example 300,000 at 6% over 30 years is about 1,798.65 a month principal and interest)
  and that the default inputs a reader first sees give a sensible number.
- compound-growth-calculator: monthly compounding with deposits at the END of each month. Say so on the page, or
  check the copy does not promise start-of-month deposits.
- debt-payoff-calculator: a month-by-month simulation capped at 1,200 months that reports "payment too low" when the
  payment does not cover the interest. Check the months and total interest against one worked case.
- hourly-to-salary-calculator: defaults of 40 hours and 52 weeks, no unpaid time off. Check the copy says so.
- true-cost-of-a-car: depreciation is price minus resale, running costs are monthly insurance and gas times 12 plus
  yearly maintenance, times years. No financing cost. Check the page does not call it the full cost of a financed car.
- Every page with a dollar limit, a tax figure or a year in its prose (for example sep-ira says "For 2026 you can put
  in up to 25 percent"): a dated figure goes stale every January. List them and pick an owner.

The rate-of-return rule (`.claude\rules\site-and-publish.md`, Brad 2026-09-12) is checked by
`ops\audit-lesson-rate-claims.ps1` over markdown under `content\` only, so it does not read these html pages.

## The other half of the July 2026 bulk post set counts as produced only because something mentions it
`OPEN` `run-0919` `2-WAY` `RUNG1 MEASURE`

Measured 2026-09-19 against live Ghost: 391 posts were published on 2026-07-04 and 2026-07-05. 196 are adopted under
I167. The other 195 pass the census because their slug appears as a whole token in some tracked file, and for 47 of
them no file under a producer-shaped path names it (the paths tried: `site\`, `content\lessons\`, `content\substack\`,
`meal-prep\db\recipes\`, `meal-prep\engine\`, `meal-prep\pipeline\`, `grocery\*.ps1`, `.claude\skills\`; a rough cut,
stated as such). Examples: `fsa`, `joint-bank-account`, `how-much-house-can-i-afford`, `how-to-max-out-your-roth-ira`.
They are named in backlog text, meal-prep archives, crawl state and similar, which is the census's stated weakness
(a mention counts as produced). By 2026-09-19 nine of the 196 adopted posts and the refunds page were already
"named" that way, by the backlog's own text about I167 (checked at d5f567178). Worth deciding whether the rest of the July set should be adopted the same way, so its numbers come
into reach too.
