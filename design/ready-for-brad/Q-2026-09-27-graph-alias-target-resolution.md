# Q-2026-09-27: the alias you accepted today cannot be switched on yet, and 52 others are stuck the same way

**The issue.** You accepted the dog food alias on the approvals page today, and the acceptance is
recorded. It cannot be switched on, because the proposal names the food "dog-food-dry" while our catalog
calls that same food "dog-food". The learning loop refuses to guess which food a name means, so it parks
the change rather than apply it to the wrong one. That refusal is right. What is wrong is that the loop
keeps naming the food by its PRINTED name ("Dog Food (dry)") turned into an id, and our catalog never
uses those.

**Why it matters.** This is not one alias. Counting only the ones still live: 51 proposals are waiting
for a ruling and 2 are already accepted and parked, across 16 different foods. Another 15 with the same
problem were rejected, so those need nothing. Each live one is a small accuracy improvement sitting
still, and every parked accept is a decision somebody already made that never took effect. The alias
itself was checked against every product name we have ever captured: it touches one product, "Premium
Dry Doog Food", and nothing else, so no risk is hiding in it.

**My recommendation: yes, teach the loop to read the printed name.** Add one step to how it matches a
food: turn each food's printed name into an id and compare against that too. Measured before proposing
it, that step resolves all 16 of those food names, covering 68 proposals in total, and 0 of them became
ambiguous, so nothing is guessed. Eight other stuck proposals stay stuck, because their names match no
food we carry, which is the honest answer for them.

Two safeguards come with it and both stay. Any change still has to pass the accuracy check against our
gold examples before it goes live. And every proposal approved under the old matching goes back for a
fresh look first, so nothing applies that nobody reviewed under the new rule; that costs three
re-reviews, two of which are the jasmine rice pair.

**The alternative, if you would rather not touch the matching.** Fix it at the source: change what the
loop is told to write down so it uses our catalog's id rather than the printed name. Cleaner in
principle, slower in practice, because the proposals already written stay stuck until somebody re-runs
them.

**What I did not do.** I made neither change. Applying your accept was today's job; changing how the
loop matches foods moves 68 other proposals, which is your call, not mine.

The counts, the exact rule and the fixtures it would need are in the backlog item filed with this,
`design/backlog-inbox/approvals-graph-alias-2026-09-27.md`.
