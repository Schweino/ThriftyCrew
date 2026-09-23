# I60: the three lesson fixes, shown before anything is republished

## What Brad does

The before and after of the three finance lessons (30, 31, 37), the checks, and the commands that swap only the
changed passages into the live posts. Nothing is republished until you run them.

**APPLIED 2026-09-19 at 08:57 UTC. Brad approved it in chat after reading the exact passages below.** The swap
ran exactly as written here, from the main checkout through `ops\review-staged.ps1`, and all three PUTs were
sent (exit 0). Lesson 30 (`6a43b4155e9f16000182e978`) is now at `updated_at` 2026-09-19T08:57:44.000Z, journal
entry `d756b254abd8`. Lesson 31 (`6a43b4165e9f16000182e97d`) is at 2026-09-19T08:57:44.000Z, journal
`250aff606263`. Lesson 37 (`6a43b4185e9f16000182e99b`) is at 2026-09-19T08:57:45.000Z, journal `67ada48d4147`.
All three are still published and paid, and only the body changed. The checks are recorded in backlog I60. What
this file still asks for is bringing `content/lessons/` and the substack mirrors up to the live text. After
that, delete the file, as its last line says.

Backlog I60. Prepared 2026-09-19 at base commit ceed001cc. Nothing was sent to Ghost: every live read was a
GET, and the republish below was rehearsed with writes STAGED (queued, never sent), then the queue was
discarded.

**Rewritten in your voice, 2026-09-19.** You read the first version and said *"It MUST be in my own voice."*
It read like an analyst. Every replacement paragraph below is now rewritten off your own live sentences
(lessons 2, 9, 28, 29, 33, 36, 41 and 42 plus the live 30, 31 and 37, all read by GET that day, and lesson
35 from the July rewrite in `archive/ghost-config/voice-rewrite/rewrites/`). No fact or
number moved: every figure is the one re-derived below, and the lesson 30 paragraph still carries the source,
the years, after-inflation and fees your I112 ruling asks for, just said plainly. Under each passage is the
line of yours it was modelled on. The rehearsal and the rate audit were both re-run on this text.

## The short version

1. **Do not republish from the lesson files in `content/lessons/`.** They are an OLDER draft than what is
   live. The live posts are the July 2026 voice rewrite (kept in
   `archive/ghost-config/voice-rewrite/rewrites/`), and the repo files never got it. Publishing a whole file
   would ship the fix AND undo the rewrite: 24, 32 and 24 em dashes back onto lessons 30, 31 and 37 (live has
   0), the "For yourself" question block removed from all three, and lesson 31's 401(k) limit rolled back from
   "For 2026, $24,500" to "For 2024, $23,000". Measured by paragraph: of the live paragraphs, only 21 of 48
   (lesson 30), 19 of 50 (lesson 31) and 12 of 42 (lesson 37) match the repo file word for word.
2. **So the right republish swaps only the changed passages inside the live post** and leaves every other
   word, the visibility and the paywall exactly as they are. The command for that is at the bottom.
3. **Two of the three fixes had errors, and one did not meet your rate-of-return ruling (I112).** The text
   below is corrected. Please read it before approving.
   - Lesson 30 said "about a third" of years since 1928 finished down. It is 26 of 98, about one in four.
     It also named no source and said nothing about fees, which your I112 ruling requires. Fixed.
   - Lesson 37 said paying "$4,800 of interest" in school keeps a $27,000 loan at $27,000. It does not: that
     takes about $7,020 (the interest is $146.25 a month). It also compounded the interest yearly, which is
     not how federal student loans work. Fixed, and every number re-derived.
   - Lesson 31's arithmetic checks out exactly. The em dash was taken out and the wording is now yours.

## Lesson 30: Boring Wins: Index Funds 101

Live post: `week-30-boring-wins-index-funds-101`, paid.

**Now (live):**

> Some of those companies will have a bad year. Some will have a great year. But you're not betting on any
> single one. You own all of them. What matters is how the whole group does, and historically, large-company
> U.S. stocks as a group have grown significantly over long time periods.

**After (two paragraphs):**

> Some of those companies will have a bad year. Some will have a great year. But you're not betting on any
> single one. You own all of them. What matters is how the whole group does. So how has the whole group done?
> From 1928 through 2025, the S&P 500 grew about 10% a year, with the dividends put back in. After inflation,
> it's closer to 7%. Those aren't my numbers. They come from Professor Aswath Damodaran at NYU Stern, who keeps
> the year-by-year record. And they're before fees. Whatever a fund charges you comes out of that.
>
> Now, that doesn't mean 10% every year. Not even close. Of those 98 years, 26 finished down. That's about
> one year in four. The 10% is what showed up across decades, not what shows up on a Tuesday.

**Modelled on:** your lesson 28 habit of a short flat line right after a claim, *"That's not opinion. It's
arithmetic."*, your lesson 28 question-and-answer *"Most people assume... But it doesn't win."*, and your own
lesson 30 line *"They're not trying to get rich by Tuesday."* The fee
sentence hands straight to your next live paragraph, which already opens on index funds being cheap to own.

**How the numbers were checked.** The yearly S&P 500 returns (dividends included) were read off Damodaran's
own page (pages.stern.nyu.edu/~adamodar, histretSP) on 2026-09-19: 98 years, 1928 through 2025. From those,
the compound average is 10.02% a year and 26 of the 98 years are negative (26.5%). The simple (arithmetic)
average is 11.86%, which is why the text says "grew about 10% a year" (the steady yearly pace that lands on
the same total) and never "on average". The "closer to 7% after inflation" figure is
Damodaran's 6.9% real as quoted by secondary sites that cite his data; I did not recompute it from CPI myself.

**What changed from the repo's fix and why.** The repo version said "about a third finished down" (wrong, it
is about a quarter), gave no source and no fee note (both required by I112), and said "on average", which
could be read as the 11.86% simple average.

## Lesson 31: The 401(k) and "Free Money"

Live post: `week-31-the-401-k-and-free-money`, paid.

**Now (live):**

> Take two people. One starts contributing to a 401(k) at 22 and never bumps her contributions past what
> captures the full match. The other waits until 32 to start. By retirement, the early starter, even though
> she contributed the same annual amount, can end up with dramatically more money, simply because she started
> 10 years sooner. That extra decade of compound growth does a lot of heavy lifting.

**After (three paragraphs):**

> Take two people. Both put $3,000 a year into a 401(k) and never raise it. One starts at 22. The other waits
> until 32. Let's say both earn 7% a year on average, and both stop at 65.
>
> The early starter ends up with about $743,000. The late starter ends up with about $357,000. Same yearly
> amount. Same finish line. The early starter has more than double. She put in $30,000 more and walked away
> with about $386,000 more. Read that again. $30,000 more in. $386,000 more out. That extra decade of compound
> growth did the heavy lifting.
>
> (Quick reality check: no real market hands you a steady 7% every single year. These numbers show the shape
> of the gap, not a promise about anybody's account.)

**Modelled on:** your lesson 28, *"The second person contributed six times more money and ended up behind.
Read that again. Six times more money. Still behind."* The caveat copies the shape of your lesson 28 aside,
*"(Quick reminder: these examples are illustrative...)"*, and "heavy lifting" is kept from your live lesson 31.

**How the numbers were checked.** $3,000 deposited at the end of each year at 7%: 43 years (22 to 65) gives
$743,329, 33 years (32 to 65) gives $356,800, a gap of $386,529, a ratio of 2.08, and $30,000 more paid in.
Every figure in the text matches. The 7% is a made-up rate labelled "Let's say", which your I112 ruling
exempts. The arithmetic is the repo's fix; the wording is new.

## Lesson 37: Student Loans Without the Panic

Live post: `week-37-student-loans-without-the-panic`, paid. Two passages change.

**Passage 1, now (live):**

> Not making full payments. Not heroic sacrifice. Just paying the interest as it builds, or more when they
> can, so the balance doesn't quietly balloon. Even $50 or $100 a month during the school years keeps the
> original amount from swelling. It's the compounding principle in reverse. Stop the interest from stacking,
> and the payoff timeline shrinks dramatically.

**Passage 1, after (five paragraphs):**

> Not making full payments. Not heroic sacrifice. Just paying the interest as it builds, or more when they
> can, so the balance doesn't quietly balloon.
>
> Here's what that's actually worth. Say your kid borrows $27,000 in federal unsubsidized loans at 6.5% and
> leaves them alone for four years of school. About $7,020 of interest piles up. The day repayment starts,
> that interest gets added to the balance. So your kid isn't paying back $27,000. They're paying back about
> $34,000. (That's not counting the six-month grace period after graduation, which adds about $880 more.)
>
> Now pay it back at $300 a month. Starting from $34,000, that takes about 14 years and 9 months. Starting
> from $27,000, it takes about 10 years and 4 months. That's more than four extra years of payments.
>
> How do you keep it at $27,000? Pay the interest as it shows up. That's about $146 a month, or roughly $7,020
> over the four years. Do that, and your kid pays about $15,800 less after graduation. Even counting what they
> paid during school, they come out about $8,800 ahead.
>
> Can't swing $146 a month? Even $50 or $100 keeps the balance from swelling as far. It's the compounding
> principle in reverse. Stop the interest from stacking, and the payoff timeline gets shorter.

**Modelled on:** your lesson 33, *"Here's what that actually costs. A $500 balance at 25% interest, paid off
at only the minimum payment, takes roughly three years to clear. And your kid ends up paying somewhere around
$640..."*, and your lesson 35 opener *"Say your teen has $300 in their account..."*. The question-then-answer
lines follow your lesson 2, *"Reasonable, right? Wrong."* "More than four extra years" is 177 minus 124
months, 53 months, so 4 years 5 months.

**Passage 2, now (live):**

> Scholarships, grants, community college for the first two years, in-state tuition, and living at home can
> all dramatically cut the total borrowed. These options aren't consolation prizes. They're smart moves that
> Future You will appreciate enormously.

**Passage 2, after:**

> Scholarships, grants, community college for the first two years, in-state tuition, and living at home all
> cut how much has to be borrowed in the first place. How much each one saves depends on the schools you're
> actually looking at, so price your kid's real options. Don't guess. These options aren't consolation prizes.
> They're smart moves that Future You will appreciate enormously.

**Modelled on:** your own live sentence it replaces (the list and the last two sentences are yours, kept
word for word), and your lesson 37 exercise, *"You can find both with a basic search."* No number was
invented and "dramatically" was cut. The first version said "rather than trusting a rule of thumb", which
read oddly one paragraph after your own rule of thumb, so it is gone.

**How the numbers were checked.** Federal loans add interest as simple interest and capitalise it when
repayment starts: $27,000 x 6.5% x 4 years = $7,020, so repayment starts on $34,020. The six-month grace
period is $877.50 more. Paid at $300 a month at 6.5%: $34,020 takes 177 months (14 years 9 months) and
$52,900 in total; $27,000 takes 124 months (10 years 4 months) and $37,122. Holding the balance flat in school
costs $146.25 a month, $7,020 over 48 months. So $15,778 less after graduation, and $8,758 less counting the
$7,020 paid in school. The 6.5% and $27,000 are the lesson's own example figures, not a claim about today's
rate.

**What was wrong in the repo's fix.** It said $7,700 of interest (that is yearly compounding, not how
federal loans add interest), a start of $34,700, "about 15 years", "$17,700 less paid", and "for $4,800 of
interest payments made during school". The last part cannot be true: $4,800 is $100 a month, which does not
cover the $146.25 a month of interest, so the balance would still grow to about $29,220. Paying $100 a
month gives 139 months (11 years 7 months) of repayment, not 10 years 4 months.

## Checks on the corrected text

- **Rate-of-return ruling (I112):** all eleven replacement paragraphs of the voice rewrite, run through
  `ops/audit-lesson-rate-claims.ps1` in a temp tree with a temp baseline on 2026-09-19: 11 paragraphs, 2 rate
  claims, 1 labelled illustration (lesson 31's "Let's say ... 7%"), 1 fully qualified (lesson 30: source,
  1928 through 2025, after inflation, fees, all in the one paragraph), 0 unqualified, exit 0. The repo's own lesson 30
  fix is on that audit's worklist today as missing a source and fees (`lesson-30...md:33`, and its substack
  mirror), and so is its own must-fire fixture. Lesson 37 is about borrowing, which the ruling does not cover.
- **No em dashes** in any replacement paragraph.
- **Paywall and visibility stay identical.** All three posts are `visibility: paid` with no in-body paywall
  card, so the whole lesson is members-only. The swap sends only two fields, the body and the `updated_at`
  Ghost uses to refuse a stale write, so visibility, tags, excerpt, meta and SEO fields, the code injection
  and the publish date are not sent and cannot change. The script also refuses to run if a post is not
  `paid` when it starts.
- **Rehearsed, not sent.** The script below was re-run on the voice rewrite on 2026-09-19 from the main
  checkout with writes staged to a scratch queue and the journal cleared: 3 PUTs queued, each sending only
  `html` and `updated_at`. Decoded and compared block by block with the live bodies, each changes only the
  intended blocks (lesson 30: 1 block becomes 2; lesson 31: 1 becomes 3; lesson 37: 1 becomes 5, plus 1
  replaced) and nothing else, with no em dash in any new body. The queue was then deleted, and a fresh GET
  showed all three posts still at their July `updated_at` (30: 2026-07-03T11:28:13, 31: 2026-07-05T11:02:38,
  37: 2026-07-03T11:28:09), so nothing reached Ghost.

## What else differs between live and the repo (a whole-file republish would ship all of it)

- The whole July voice rewrite is missing from `content/lessons/lesson-30|31|37*.md` and from the substack
  mirrors: sentence-level rewording in most paragraphs, the "For yourself" question block, and the em dashes
  (24, 32, 24 in the files, 0 live).
- Lesson 31's 401(k) limit: live says 2026 and $24,500, the file says 2024 and $23,000.
- The repo file keeps the italic hook line as body text; live carries it only as the post excerpt.
- Not touched by the swap, noticed while reading: the paywall structured data in the code injection of all
  three posts names the OLD domain (`simplemoneyplaybook.com`). A GET of every post tagged financial-lessons
  found 52 of 56 lessons that way (the other 4 are free and carry none). The `publish-lesson.ps1` path would
  have rewritten it for these three only, to the ghost.io host rather than www.thriftycrew.com, so it would
  not have fixed it either. That is its own item.

## Why not `publish-lesson.ps1`

It is the lesson skill's publish path and it upserts by slug, but it replaces the WHOLE body, so it needs a
correct whole-body source, and the repo has none (see above). It also resends the title, excerpt, meta
fields, tags and the paywall code injection, so the code injection would change on these three posts. The
swap below is narrower and keeps the rest of each post as it is.

## The command (for Brad, or a run Brad has approved)

From the MAIN checkout (`C:\Codex\ThriftyCrew`, which holds `meal-prep\.ghostkey`), save the script below as
a scratch file, for example `%TEMP%\i60-swap.ps1`, then:

```powershell
cd C:\Codex\ThriftyCrew
$env:TC_STAGE_WRITES = "$env:TEMP\i60-queue.jsonl"   # queue the writes; nothing is sent yet
powershell -NoProfile -File "$env:TEMP\i60-swap.ps1"   # reads the live posts, queues 3 PUTs
powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TC_STAGE_WRITES          # look at the queue
$env:TC_WRITE_JOURNAL = 'ops\ghost-journal.jsonl'      # keep a before-image of each post, for ops\revert-ghost-write.ps1
powershell -NoProfile -File ops\review-staged.ps1 -Queue $env:TC_STAGE_WRITES -Apply   # SENDS them
Remove-Item Env:\TC_STAGE_WRITES, Env:\TC_WRITE_JOURNAL
```

If any post changed after 2026-09-19, the script stops before queueing anything for it, and Ghost itself
refuses a queued write whose `updated_at` is stale. Afterwards: open each post signed in and read the new
paragraphs; open it signed out and check the new text is NOT shown (the paywall, in the direction that loses
money). Then bring `content/lessons/` and the substack mirrors up to the live text as a separate change.

```powershell
# i60-swap.ps1. Run from the MAIN checkout. Refuses to run unless writes are staged.
$ErrorActionPreference = 'Stop'
. .\lib\ghost-lib.ps1
if (-not $env:TC_STAGE_WRITES) { throw 'Set $env:TC_STAGE_WRITES first, so the writes queue for review instead of going out.' }
$api = 'https://map-to-success.ghost.io'
$key = Get-GhostKey

$swaps = @(
  @{ Slug = 'week-30-boring-wins-index-funds-101'
     Old  = @'
<p>Some of those companies will have a bad year. Some will have a great year. But you're not betting on any single one. You own all of them. What matters is how the whole group does, and historically, large-company U.S. stocks as a group have grown significantly over long time periods.</p>
'@
     New  = @'
<p>Some of those companies will have a bad year. Some will have a great year. But you're not betting on any single one. You own all of them. What matters is how the whole group does. So how has the whole group done? From 1928 through 2025, the S&amp;P 500 grew about 10% a year, with the dividends put back in. After inflation, it's closer to 7%. Those aren't my numbers. They come from Professor Aswath Damodaran at NYU Stern, who keeps the year-by-year record. And they're before fees. Whatever a fund charges you comes out of that.</p><p>Now, that doesn't mean 10% every year. Not even close. Of those 98 years, 26 finished down. That's about one year in four. The 10% is what showed up across decades, not what shows up on a Tuesday.</p>
'@ },
  @{ Slug = 'week-31-the-401-k-and-free-money'
     Old  = @'
<p>Take two people. One starts contributing to a 401(k) at 22 and never bumps her contributions past what captures the full match. The other waits until 32 to start. By retirement, the early starter, even though she contributed the same annual amount, can end up with dramatically more money, simply because she started 10 years sooner. That extra decade of compound growth does a lot of heavy lifting.</p>
'@
     New  = @'
<p>Take two people. Both put $3,000 a year into a 401(k) and never raise it. One starts at 22. The other waits until 32. Let's say both earn 7% a year on average, and both stop at 65.</p><p>The early starter ends up with about $743,000. The late starter ends up with about $357,000. Same yearly amount. Same finish line. The early starter has more than double. She put in $30,000 more and walked away with about $386,000 more. Read that again. $30,000 more in. $386,000 more out. That extra decade of compound growth did the heavy lifting.</p><p>(Quick reality check: no real market hands you a steady 7% every single year. These numbers show the shape of the gap, not a promise about anybody's account.)</p>
'@ },
  @{ Slug = 'week-37-student-loans-without-the-panic'
     Old  = @'
<p>Not making full payments. Not heroic sacrifice. Just paying the interest as it builds, or more when they can, so the balance doesn't quietly balloon. Even $50 or $100 a month during the school years keeps the original amount from swelling. It's the compounding principle in reverse. Stop the interest from stacking, and the payoff timeline shrinks dramatically.</p>
'@
     New  = @'
<p>Not making full payments. Not heroic sacrifice. Just paying the interest as it builds, or more when they can, so the balance doesn't quietly balloon.</p><p>Here's what that's actually worth. Say your kid borrows $27,000 in federal unsubsidized loans at 6.5% and leaves them alone for four years of school. About $7,020 of interest piles up. The day repayment starts, that interest gets added to the balance. So your kid isn't paying back $27,000. They're paying back about $34,000. (That's not counting the six-month grace period after graduation, which adds about $880 more.)</p><p>Now pay it back at $300 a month. Starting from $34,000, that takes about 14 years and 9 months. Starting from $27,000, it takes about 10 years and 4 months. That's more than four extra years of payments.</p><p>How do you keep it at $27,000? Pay the interest as it shows up. That's about $146 a month, or roughly $7,020 over the four years. Do that, and your kid pays about $15,800 less after graduation. Even counting what they paid during school, they come out about $8,800 ahead.</p><p>Can't swing $146 a month? Even $50 or $100 keeps the balance from swelling as far. It's the compounding principle in reverse. Stop the interest from stacking, and the payoff timeline gets shorter.</p>
'@ },
  @{ Slug = 'week-37-student-loans-without-the-panic'
     Old  = @'
<p>Scholarships, grants, community college for the first two years, in-state tuition, and living at home can all dramatically cut the total borrowed. These options aren't consolation prizes. They're smart moves that Future You will appreciate enormously.</p>
'@
     New  = @'
<p>Scholarships, grants, community college for the first two years, in-state tuition, and living at home all cut how much has to be borrowed in the first place. How much each one saves depends on the schools you're actually looking at, so price your kid's real options. Don't guess. These options aren't consolation prizes. They're smart moves that Future You will appreciate enormously.</p>
'@ }
)

foreach ($slug in @($swaps | ForEach-Object { $_.Slug } | Select-Object -Unique)) {
  $hdr = @{ Authorization = "Ghost $(Get-GhostJWT -Key $key)"; 'Accept-Version' = 'v5.0'; 'Content-Type' = 'application/json' }
  $p = (Invoke-GhostApi -Uri "$api/ghost/api/admin/posts/slug/$slug/?formats=html" -Headers $hdr).posts[0]
  if ($p.visibility -ne 'paid') { throw "$slug visibility is '$($p.visibility)', expected 'paid'. Stopping." }
  $html = [string]$p.html
  foreach ($s in @($swaps | Where-Object { $_.Slug -eq $slug })) {
    $old = $s.Old.Trim(); $new = $s.New.Trim()
    $n = ([regex]::Matches($html, [regex]::Escape($old))).Count
    if ($n -ne 1) { throw "$slug : the old passage appears $n times, expected exactly 1. The live post changed after 2026-09-19. Stopping." }
    $html = $html.Replace($old, $new)
  }
  $body = @{ posts = @(@{ html = $html; updated_at = $p.updated_at }) } | ConvertTo-Json -Depth 5
  $null = Invoke-GhostApi -Method 'PUT' -Uri "$api/ghost/api/admin/posts/$($p.id)/?source=html" -Headers $hdr -Body ([Text.Encoding]::UTF8.GetBytes($body))
  Write-Host "queued: $slug (visibility paid, updated_at $($p.updated_at))"
}
```

`?source=html` is how these three posts were last written (the July rewrite used it), so Ghost rebuilds each
post's editor blocks from the new body the same way it did then.

Delete this file once the three posts are republished and `content/lessons/` matches them.
