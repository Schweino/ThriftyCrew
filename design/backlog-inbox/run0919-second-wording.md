## the baker's and family fare regular pulls ask each term one way, so no derived not-carried entry can ever qualify

`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

**Source.** Brad's approval of I221 on 2026-09-19, which landed the two-search rule: `grocery/not-carried-lib.ps1`
trusts a `derived` not-carried entry only when at least two DIFFERENTLY WORDED searches, each empty or with no
matching row, sit inside `recheck_days`. Brad approved this follow-up in the same message.

**What is wrong.** `grocery/pull-regular-bakers-api.ps1` and `grocery/pull-regular-familyfare.ps1` ask each term with
one wording, so a term that comes back empty or with rows our matcher rejects is never asked a second way. Under the
new rule that means no derived entry can qualify: on 2026-09-19 the branch build of the deals page from
`comparison-2026-09-17.json` logged `not-carried: 0 of 24 entr(y/ies) trusted and shown; not shown: 24 single-search`,
and I221's dry run of `derive-not-carried` over that day's captures refused 63 candidates on one wording (58 Family
Fare, 5 Baker's). The "Doesn't carry" label therefore reaches a reader only by a hand declaration.

**The build.** When a term comes back empty or unmatched, ask one more, differently worded search in the same pull
and record its term text in the capture. `grocery/search-verdict-lib.ps1`'s `Get-RetryLadder` (line 89) already
produces the second wording, and its header has the measured case for why: four of ten terms in the 2026-08-15 trial
would have been mis-ruled on their first query. Captures must keep the `term` text for both searches, or
`derive-not-carried` cannot tell the wordings apart. The wording test is `Get-TcNotCarriedSearchKey` (case,
punctuation, word order and a plural `s` do not count as a new wording), so the ladder's second rung must differ by
that test. Fixture: a MUST FIRE where the first wording is empty and the pull records a second search, and a CLEAN
TWIN where a first-wording match asks nothing more.

**Reader effect, so it is Brad's to see before it lands.** Once captures carry two wordings, `derive-not-carried
-Apply` can write entries that pass the rule and the deals page will show "Doesn't carry" for them. That is a page
change: prepare it, count the cells that would change, and hold it for Brad.

**Also.** `grocery/audit-coverage-gaps.ps1:319` still reads `not-carried.json` for itself and honours every unexpired
entry, single-search or not, so the 24 entries still silence their coverage gaps until 2026-11-19. It should read
through `not-carried-lib.ps1` like the page and the writer do. Moving it would reopen those 24 gaps in that audit, which
is the honest answer, but say so in the change.
