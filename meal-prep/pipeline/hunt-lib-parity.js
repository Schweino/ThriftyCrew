export const meta = {
  name: 'hunt-lib-parity',
  description: 'Run the shared vectors against hunt-lib.js itself - ZERO agent calls',
  phases: [{ title: 'Parity' }],
}

// =====================================================================================================
// THE JS HALF OF THE PARITY GATE (PLAN-recipe-hunter-v3 section 4.2, D9).
//
// hunt_lib.py --parity runs `hunt-lib-vectors.json` against the Python port. This runs the SAME file
// against hunt-lib.js. A vector green on one side and red on the other is a port defect, which is the
// only thing this gate looks for.
//
// THIS FILE IS PART TEMPLATE, PART GENERATED, and the split matters.
//
// A workflow script cannot read the repo, so hunt-lib.js's text has to be COPIED in here. The estate
// has done that by hand once already - hunt-lib.selftest.js (2026-08-16) inlined a duplicate and
// carried a header warning that the two would drift, which is a warning, not a mechanism. So the copy
// is written mechanically instead:
//
//   C:\Codex\Python312\python.exe hunt_lib.py --emit-parity
//
// It rewrites everything between the GENERATED markers below from the shipped files and stamps
// hunt-lib.js's SHA-256 next to the copy. `hunt_lib.py --selftest` re-hashes the shipped file and FIRES
// if the stamp no longer matches - so a hunt-lib.js edit that forgets to regenerate is a finding rather
// than a suite quietly testing yesterday's code.
//
// MEASURED 2026-08-24, and the reason the source is spliced as CODE rather than carried as a string:
// the first build of this runner passed hunt-lib.js's text in `args` and evaluated it with
// `new Function`, which is the only shape that could test the shipped bytes with no copy at all. The
// harness refuses - "EvalError: Code generation from strings disallowed for this context" - and the
// runner reported that limitation instead of silently falling back to a duplicate, which is the
// behavior its header asked for. A generated splice is the honest second-best: still one copy, but a
// copy no human writes and a hash nobody can forget to check.
//
// The five channel scenarios are the one thing that cannot travel as data - async semantics are not
// expressible as a vector - so they exist twice, once here and once in hunt_lib.py's _chan_scenario.
// Both are named the same and a change to one means changing the other.
// =====================================================================================================

// >>> GENERATED-HUNT-LIB-BEGIN (rewritten by hunt_lib.py --emit-parity; do not hand-edit)
// hunt-lib.js @ b5092ddf42b8f717, 21177 bytes, spliced verbatim apart from the `export` keyword
// hunt-lib.js
// =====================================================================================================
// The pure decision logic of the Recipe Hunter orchestrator, separated from the agent plumbing so it
// can be TESTED. Every function here is deterministic: no agents, no filesystem, no clock.
//
// WHY THIS FILE EXISTS. Every load-bearing .ps1 in this estate carries a self-test. The orchestrator
// that SPENDS THE TOKENS carried none, and eleven of the twelve defects in the 2026-08-15/16 runs lived
// in it - each one found by burning millions of tokens in production rather than by a fixture:
//
//   B5  a null agent result treated as an explicit rejection      -> 14 false rejections reported
//   B6  retry budgets keyed by batch SHAPE, so they never saturated -> 657 failed calls, zero progress
//   B7  "pass" compared against 'PASS'                            -> 12 real passes read as failures
//   B8  -Terms 'a,b' bound as ONE composite string                -> recipes parked forever, silently
//   B9  WIP limit + closed lanes = unwakeable producers            -> caught in review, never ran
//   B10 a double NO-GO stranded 10 recipes in `waved` with no exit -> 2 clean recipes held hostage
//   B11 a repair agent's claim believed without checking the files -> a whole re-audit paid for nothing
//
// Each is now a fixture in selfTest() below. The rule is the estate's own: a gate whose founding bug is
// not frozen next to it drifts back into the dead-guard pile.
//
// There is no local Node runtime, so these fixtures run INSIDE a Workflow invocation with ZERO agent
// calls - see hunt-orchestrator.js `args.selftest`. Cost to run: nothing.
// =====================================================================================================

// -----------------------------------------------------------------------------------------------------
// VERDICT PARSING (B7). An agent verdict is free text from a model. Compare the FIRST TOKEN, case-
// insensitively, so "pass" / "PASS" / "PASS (with notes)" all read alike - while "NO-GO" can never be
// mistaken for "GO", because its first token is "NO-GO".
// -----------------------------------------------------------------------------------------------------
const firstToken = v =>
  String(v == null ? '' : v).trim().toUpperCase().split(/[^A-Z-]+/).filter(Boolean)[0] || ''
const isPass = v => firstToken(v) === 'PASS'
const isGo = v => firstToken(v) === 'GO'
const isRejected = v => firstToken(v) === 'REJECTED'
const normState = v => String(v == null ? '' : v).trim().toLowerCase()

// -----------------------------------------------------------------------------------------------------
// TERM MARSHALLING (B8). PowerShell binds `-Terms 'a,b'` to a [string[]] of ONE element - the literal
// "a,b" - which can never match an ingredient-queue entry, so the recipe parks forever while its
// ingredients sit CARRIED. Terms must be emitted as separate quoted strings.
// -----------------------------------------------------------------------------------------------------
const quoteTerms = terms =>
  (terms || []).filter(Boolean).map(t => `'${String(t).replace(/'/g, "''")}'`).join(',')
const termHasComma = t => String(t == null ? '' : t).includes(',')

// -----------------------------------------------------------------------------------------------------
// RETRY ACCOUNTING (B6). Budgets are keyed PER SLUG, never per batch shape. The map lane pulls a new
// slug combination each cycle, so a shape-keyed budget minted a fresh allowance every time and never
// saturated - 657 failed calls against a session limit that only a clock could clear.
// -----------------------------------------------------------------------------------------------------
function bumpRetries(counts, slugs, stage) {
  const list = (Array.isArray(slugs) ? slugs : [slugs]).filter(Boolean)
  let worst = 0
  for (const s of list) {
    const key = `${stage}:${s}`
    const n = (counts.get(key) || 0) + 1
    counts.set(key, n)
    if (n > worst) worst = n
  }
  return worst
}

// -----------------------------------------------------------------------------------------------------
// CIRCUIT BREAKER (B6). agent() returns a bare null on failure - the script never sees the error text -
// so the breaker matches on SHAPE: consecutive failures run-wide, any success resetting the count.
// Isolated flakiness never trips it; a hard wall trips it almost immediately.
// -----------------------------------------------------------------------------------------------------
function makeBreaker({ threshold = 5, maxCalls = 900 } = {}) {
  let consecutive = 0, calls = 0, open = false, reason = ''
  return {
    get open() { return open },
    get reason() { return reason },
    get calls() { return calls },
    countCall() { calls += 1 },
    note(ok) {
      if (ok) { consecutive = 0; return }
      consecutive += 1
      if (consecutive >= threshold && !open) {
        open = true
        reason = `${consecutive} consecutive agent failures run-wide - a systemic wall, not per-recipe flakiness`
      }
    },
    checkBudget() {
      if (!open && calls >= maxCalls) { open = true; reason = `agent call budget reached (${calls}/${maxCalls})` }
      return open
    },
    trip(r) { if (!open) { open = true; reason = r } },
  }
}

// -----------------------------------------------------------------------------------------------------
// WAVE TRIM (B10). Plan section S8: on NO-GO the blocking slugs LEAVE the wave - to one repair, or to
// rejected-audit - and the trimmed manifest re-audits. Without this, a double NO-GO left all ten
// recipes in `waved`, a state whose only exits are published / rejected-audit / qa-passed / written,
// and nothing ever picks them up again. Two audit-clean recipes sat hostage to eight blocked ones.
// -----------------------------------------------------------------------------------------------------
function planTrim(waveSlugs, perSlug, alreadyRepaired, blockerKind) {
  const blocked = [], clean = []
  for (const s of waveSlugs) {
    const v = perSlug && perSlug[s]
    if (v && String(v).toUpperCase().startsWith('BLOCK')) blocked.push(s); else clean.push(s)
  }
  // A SHARED-DATA BLOCKER IS NOT THIS RECIPE'S DEFECT, AND MUST NOT SPEND ITS ONE REPAIR
  // (2026-08-28). Wave 11 of hunt-2026-08-27-highprotein made a recipe TERMINAL with zero open
  // defects of its own: a gate red over three PHANTOM specs in OTHER recipes, and a board-wide
  // cheddar price. Neither was its owner's to fix; both were closed hours later. See the python
  // twin for the full account. An absent kind spends the budget exactly as before.
  const shared = String(blockerKind || '').trim().toLowerCase() === 'shared-data'
  const terminal = Boolean(alreadyRepaired) && !shared
  return {
    clean,
    blocked,
    // A slug that has already had its one repair cycle is terminal; anything else goes back for repair.
    toReject: terminal ? blocked : [],
    toRepair: terminal ? [] : blocked,
    // Publishing the clean remainder is the whole point: never hold good recipes for bad neighbours.
    canPublishClean: clean.length > 0,
  }
}

// -----------------------------------------------------------------------------------------------------
// RE-AUDIT SCOPE (v2.1 B2, and the B-4 gate). Recipe-local blockers re-audit ONLY the repaired slugs;
// shared-data blockers (a map entry, a DB row, the cost basis) REQUIRE the whole wave, because the fix
// moved every recipe's numbers. Declaring the scope is mandatory; defaulting to whole-wave is what made
// the 2026-08-15 shakedown spend 31% of its tokens on three audits.
// -----------------------------------------------------------------------------------------------------
function chooseScope(blockerKind, repairedSlugs) {
  if (blockerKind === 'shared-data' || !repairedSlugs || repairedSlugs.length === 0) {
    return { scope: 'whole-wave', why: 'the fix moved shared data, so every recipe in the wave has new numbers' }
  }
  return { scope: repairedSlugs.join(','), why: 'the blocker was recipe-local, so nothing outside the repaired slugs moved' }
}
// The gate half: a narrow scope is only legal when the change really was recipe-local.
function scopeIsLegal(scope, blockerKind) {
  if (blockerKind === 'shared-data') return scope === 'whole-wave'
  return true
}

// -----------------------------------------------------------------------------------------------------
// POSTCONDITIONS (B11). A repair agent reported success having changed nothing; the only thing that
// caught it was paying for a second full audit, which checked file mtimes itself. Verify the claim
// BEFORE paying for the expensive next stage. "Nothing needed changing" is a legitimate answer and is
// treated differently from "I changed X" with X untouched.
// -----------------------------------------------------------------------------------------------------
function repairClaimHolds({ claimedChanged, mtimesBefore, mtimesAfter }) {
  if (!claimedChanged || claimedChanged.length === 0) return { ok: true, reason: 'no change claimed' }
  const untouched = claimedChanged.filter(f => (mtimesAfter[f] || 0) <= (mtimesBefore[f] || 0))
  if (untouched.length === 0) return { ok: true, reason: 'every claimed file changed' }
  return { ok: false, reason: `claimed to change but did not: ${untouched.join(', ')}`, untouched }
}

// -----------------------------------------------------------------------------------------------------
// MACRO BAND. A band has a ceiling as well as a floor: a recipe computing to 660 fails exactly like one
// computing to 390. Recipes are never adjusted to fit - that would make the card a false claim.
// -----------------------------------------------------------------------------------------------------
// THE BAND IS A RUN PARAMETER, AND PROTEIN IS PART OF IT (Brad's ruling 2026-08-24). `proteinMin` is
// optional - a band that does not state one has no protein rule, which keeps every older vector green.
// An absent protein number passes and says so: this is a retirement gate, and retiring a good dish on
// a number nobody read is the mirror of D8's worse-than-no-gate case.
function inBand(cal, carbs, { calMin, calMax, carbMax, proteinMin }, protein) {
  if (typeof cal !== 'number' || typeof carbs !== 'number') return { ok: true, reason: 'not reported' }
  if (cal < calMin) return { ok: false, reason: `${cal} cal below the ${calMin} floor` }
  if (cal > calMax) return { ok: false, reason: `${cal} cal above the ${calMax} ceiling` }
  if (carbs > carbMax) return { ok: false, reason: `${carbs}g carbs above the ${carbMax} limit` }
  if (typeof proteinMin === 'number') {
    if (typeof protein !== 'number') return { ok: true, reason: 'protein not reported' }
    if (protein < proteinMin) return { ok: false, reason: `${protein}g protein below the ${proteinMin} floor` }
  }
  return { ok: true, reason: '' }
}

// -----------------------------------------------------------------------------------------------------
// CHANNEL (B9). Lanes block on promises, never on timers - there is no clock in the sandbox. close()
// must wake BOTH takers and backpressure-parked producers, or a producer parks forever and the run
// hangs instead of exiting.
// -----------------------------------------------------------------------------------------------------
function chan() {
  const items = [], waiters = [], spaceWaiters = []
  let closed = false
  return {
    push(x) { items.push(x); const w = waiters.shift(); if (w) w() },
    close() { closed = true; waiters.splice(0).forEach(w => w()); spaceWaiters.splice(0).forEach(w => w()) },
    isClosed() { return closed },
    size() { return items.length },
    async waitForSpace(limit) { while (items.length >= limit && !closed) await new Promise(r => spaceWaiters.push(r)) },
    async take() {
      for (;;) {
        if (items.length) { const v = items.shift(); spaceWaiters.splice(0).forEach(w => w()); return v }
        if (closed) return null
        await new Promise(r => waiters.push(r))
      }
    },
    // Blocks ONLY for the first item, then sweeps whatever is already queued. Never waits to fill a
    // quota - that is the difference between a buffer and a batch, and getting it wrong (B3) made the
    // pipeline take 8-10 minutes to produce its first flowing recipe.
    async takeBatch(n) {
      const first = await this.take()
      if (first === null) return null
      const batch = [first]
      while (batch.length < n && items.length) batch.push(items.shift())
      return batch
    },
  }
}

// =====================================================================================================
// FIXTURES. Must-fire + clean twin for every defect above.
// =====================================================================================================
async function selfTest(log = console.log) {
  let bad = 0
  const T = (name, ok, got) => {
    if (ok) log(`  ok    ${name}`)
    else { log(`  X     ${name}   got: ${got}`); bad++ }
  }

  // ---- B7 verdict parsing
  T('MUST FIRE  lowercase "pass" IS a pass (the bug that stalled every wave)', isPass('pass'), firstToken('pass'))
  T('CLEAN TWIN uppercase PASS is a pass', isPass('PASS'), firstToken('PASS'))
  T('"PASS (with notes)" is a pass', isPass('PASS (with notes)'), firstToken('PASS (with notes)'))
  T('MUST FIRE  "FAIL" is not a pass', !isPass('FAIL'), firstToken('FAIL'))
  T('MUST FIRE  "NO-GO" is NEVER read as GO', !isGo('NO-GO') && !isGo('no-go'), firstToken('NO-GO'))
  T('CLEAN TWIN "GO" is GO, and so is "go"', isGo('GO') && isGo('go'), firstToken('go'))
  T('MUST FIRE  a null verdict is not a pass and not a GO', !isPass(null) && !isGo(null), firstToken(null))
  T('MUST FIRE  an empty verdict is not a GO', !isGo(''), firstToken(''))

  // ---- B8 term marshalling
  T('MUST FIRE  a comma inside a single term is detected', termHasComma('green bell pepper,shaved beef steak'), 'not detected')
  T('CLEAN TWIN a normal term carries no comma', !termHasComma('bacon bits'), 'false positive')
  T('MUST FIRE  two terms quote as TWO arguments, not one joined string',
    quoteTerms(['green bell pepper', 'shaved beef steak']) === "'green bell pepper','shaved beef steak'",
    quoteTerms(['green bell pepper', 'shaved beef steak']))
  T("an apostrophe in a term is escaped for PowerShell", quoteTerms(["hy-vee's own"]) === "'hy-vee''s own'", quoteTerms(["hy-vee's own"]))

  // ---- B6 retries + breaker
  {
    const c = new Map()
    bumpRetries(c, ['a', 'b'], 'map')
    bumpRetries(c, ['a', 'x'], 'map')            // a DIFFERENT batch shape containing 'a'
    T('MUST FIRE  a slug carries its retries across DIFFERENT batch shapes', c.get('map:a') === 2, String(c.get('map:a')))
    T('CLEAN TWIN a slug seen once has one retry', c.get('map:x') === 1, String(c.get('map:x')))
    T('retries are per STAGE, not global', bumpRetries(c, ['a'], 'write') === 1, 'leaked across stages')
  }
  {
    const b = makeBreaker({ threshold: 5, maxCalls: 900 })
    for (let i = 0; i < 4; i++) b.note(false)
    T('CLEAN TWIN four failures do not trip the breaker', !b.open, 'tripped early')
    b.note(true); b.note(false); b.note(false)
    T('CLEAN TWIN a success resets the streak (per-recipe flakiness never trips it)', !b.open, 'tripped on flakiness')
    for (let i = 0; i < 5; i++) b.note(false)
    T('MUST FIRE  five consecutive failures trip the breaker', b.open, 'did not trip')
  }
  {
    const b = makeBreaker({ threshold: 5, maxCalls: 3 })
    b.countCall(); b.countCall(); b.countCall()
    T('MUST FIRE  the call budget trips before the harness 1000-cap kills the run', b.checkBudget(), 'no trip')
  }

  // ---- B10 wave trim
  {
    const t = planTrim(['a', 'b', 'c'], { a: 'BLOCK', b: 'GO', c: 'GO' }, false)
    T('MUST FIRE  clean recipes are NOT held hostage by a blocked neighbour', t.clean.join(',') === 'b,c', t.clean.join(','))
    T('the blocked slug goes back for its one repair', t.toRepair.join(',') === 'a' && t.toReject.length === 0, t.toRepair.join(','))
    const t2 = planTrim(['a', 'b', 'c'], { a: 'BLOCK', b: 'GO', c: 'GO' }, true)
    T('MUST FIRE  after its repair cycle a blocker is terminal, never re-repaired', t2.toReject.join(',') === 'a' && t2.toRepair.length === 0, t2.toReject.join(','))
    const t3 = planTrim(['a', 'b'], { a: 'BLOCK', b: 'BLOCK' }, true)
    T('MUST FIRE  an all-blocked wave publishes NOTHING', !t3.canPublishClean, 'would publish')
  }

  // ---- B-4 scope
  {
    T('shared-data blockers force a whole-wave re-audit', chooseScope('shared-data', ['a']).scope === 'whole-wave', chooseScope('shared-data', ['a']).scope)
    T('recipe-local blockers scope to the repaired slugs only', chooseScope('recipe-local', ['a', 'b']).scope === 'a,b', chooseScope('recipe-local', ['a', 'b']).scope)
    T('MUST FIRE  a narrow scope on a shared-data fix is ILLEGAL', !scopeIsLegal('a,b', 'shared-data'), 'allowed')
    T('CLEAN TWIN whole-wave is always legal', scopeIsLegal('whole-wave', 'shared-data') && scopeIsLegal('whole-wave', 'recipe-local'), 'refused')
  }

  // ---- B11 postconditions
  {
    const before = { 'a.json': 100, 'b.json': 100 }
    T('MUST FIRE  a repair claiming a file it never touched is refused',
      !repairClaimHolds({ claimedChanged: ['a.json'], mtimesBefore: before, mtimesAfter: { 'a.json': 100 } }).ok, 'accepted')
    T('CLEAN TWIN a real repair passes',
      repairClaimHolds({ claimedChanged: ['a.json'], mtimesBefore: before, mtimesAfter: { 'a.json': 200 } }).ok, 'refused')
    T('CLEAN TWIN "nothing needed changing" is a legitimate answer, not a lie',
      repairClaimHolds({ claimedChanged: [], mtimesBefore: before, mtimesAfter: before }).ok, 'refused')
    T('MUST FIRE  one untouched file among several is still caught',
      !repairClaimHolds({ claimedChanged: ['a.json', 'b.json'], mtimesBefore: before, mtimesAfter: { 'a.json': 200, 'b.json': 100 } }).ok, 'missed')
  }

  // ---- macro band
  T('MUST FIRE  below the floor fails', !inBand(390, 10, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'passed')
  T('MUST FIRE  above the CEILING fails (a band has two edges)', !inBand(660, 10, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'passed')
  T('MUST FIRE  over the carb limit fails', !inBand(500, 36, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'passed')
  T('CLEAN TWIN mid-band passes', inBand(500, 20, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'failed')
  T('CLEAN TWIN the exact edges are inside the band', inBand(400, 35, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'edge rejected')

  // ---- macro band: the PROTEIN FLOOR (2026-08-24, the band is a run parameter)
  {
    const b = { calMin: 500, calMax: 650, carbMax: 40, proteinMin: 50 }
    T('MUST FIRE  under the protein floor fails', !inBand(520, 20, b, 47).ok, 'passed')
    T('CLEAN TWIN the protein floor is inclusive', inBand(520, 20, b, 50).ok, 'edge rejected')
    T('CLEAN TWIN unread protein passes and SAYS SO', inBand(520, 20, b, null).reason === 'protein not reported', 'wrong reason')
    T('MUST FIRE  a band stating no floor does not invent one', inBand(520, 20, { calMin: 500, calMax: 650, carbMax: 40 }, 12).ok, 'invented a floor')
    // Fails BOTH clauses (45g carbs over 40, 30g protein under 50), so only the ORDER decides the
    // reason. The first shape of this assertion used 90g protein, cleared the floor, and proved nothing.
    T('MUST FIRE  carbs are judged BEFORE protein - clause order is the contract',
      inBand(520, 45, b, 30).reason === '45g carbs above the 40 limit', 'wrong clause fired first')
  }

  // ---- B9 channel
  {
    const c = chan()
    c.push(1); c.push(2); c.push(3)
    const b = await c.takeBatch(5)
    T('takeBatch sweeps what is queued without waiting to fill', b.length === 3, String(b.length))
    c.close()
    T('a closed empty channel returns null rather than hanging', (await c.take()) === null, 'hung or returned a value')
  }
  {
    const c = chan()
    c.push('x')
    const one = await c.takeBatch(5)
    T('MUST FIRE  a lone item is taken alone, immediately (streaming, not batching)', one.length === 1, String(one.length))
  }
  {
    // B9 itself: a producer parked on backpressure must be woken by close(), or the run hangs forever.
    const c = chan()
    c.push(1); c.push(2)
    let released = false
    const parked = c.waitForSpace(2).then(() => { released = true })
    c.close()
    await parked
    T('MUST FIRE  close() releases a producer parked on backpressure (the hang bug)', released, 'still parked')
  }
  {
    const c = chan()
    const got = []
    const consumer = (async () => { for (;;) { const v = await c.take(); if (v === null) break; got.push(v) } })()
    c.push('a'); c.push('b'); c.close()
    await consumer
    T('items pushed before close are drained, not discarded', got.join(',') === 'a,b', got.join(','))
  }

  if (bad > 0) { log(`hunt-lib SELF-TEST FAIL (${bad})`); return { ok: false, failures: bad } }
  log('hunt-lib SELF-TEST PASS')
  return { ok: true, failures: 0 }
}

// >>> GENERATED-HUNT-LIB-END

// >>> GENERATED-VECTORS-BEGIN (rewritten by hunt_lib.py --emit-parity; do not hand-edit)
const VECTORS = {"what": "Shared test vectors for the hunt-lib parity gate (PLAN-recipe-hunter-v3 section 4.2). ONE file, TWO implementations: hunt_lib.py --parity runs them against the Python port, and hunt-lib-parity.js runs them against hunt-lib.js inside a zero-agent Workflow invocation. A vector green on one side and red on the other is a port defect, which is the only thing this gate looks for. Every vector below is an assertion hunt-lib.js's own selfTest already made; the fixtures were PORTED, not rewritten.", "kinds": {"call": "a pure function: `fn` applied to `args`, deep-equal against `expect`", "retries": "a SEQUENCE of bumpRetries(counts, slugs, stage) calls sharing one counter, because B6 is about state carried BETWEEN calls; expect {counts, returns}", "breaker": "a sequence of breaker operations against one breaker; expect {open, calls}", "chan": "a NAMED async scenario, because channel semantics are not expressible as data. Both runners implement the same five scenario bodies under the same names - this is the one place the suite exists twice, so a change here means changing both."}, "vectors": [{"id": "B7-lowercase-pass", "kind": "call", "fn": "isPass", "args": ["pass"], "expect": true, "must_fire": true, "note": "lowercase 'pass' IS a pass - the bug that stalled every wave"}, {"id": "B7-uppercase-pass", "kind": "call", "fn": "isPass", "args": ["PASS"], "expect": true, "must_fire": false, "note": "uppercase PASS is a pass"}, {"id": "B7-pass-with-notes", "kind": "call", "fn": "isPass", "args": ["PASS (with notes)"], "expect": true, "must_fire": false, "note": "'PASS (with notes)' is a pass"}, {"id": "B7-fail-is-not-pass", "kind": "call", "fn": "isPass", "args": ["FAIL"], "expect": false, "must_fire": true, "note": "'FAIL' is not a pass"}, {"id": "B7-nogo-is-not-go", "kind": "call", "fn": "isGo", "args": ["NO-GO"], "expect": false, "must_fire": true, "note": "'NO-GO' is NEVER read as GO - its first token is NO-GO"}, {"id": "B7-nogo-lower-is-not-go", "kind": "call", "fn": "isGo", "args": ["no-go"], "expect": false, "must_fire": true, "note": "and neither is 'no-go'"}, {"id": "B7-go-is-go", "kind": "call", "fn": "isGo", "args": ["GO"], "expect": true, "must_fire": false, "note": "'GO' is GO"}, {"id": "B7-go-lower-is-go", "kind": "call", "fn": "isGo", "args": ["go"], "expect": true, "must_fire": false, "note": "and so is 'go'"}, {"id": "B7-null-not-pass", "kind": "call", "fn": "isPass", "args": [null], "expect": false, "must_fire": true, "note": "a null verdict is not a pass"}, {"id": "B7-null-not-go", "kind": "call", "fn": "isGo", "args": [null], "expect": false, "must_fire": true, "note": "a null verdict is not a GO"}, {"id": "B7-empty-not-go", "kind": "call", "fn": "isGo", "args": [""], "expect": false, "must_fire": true, "note": "an empty verdict is not a GO"}, {"id": "B7-firstToken-pass", "kind": "call", "fn": "firstToken", "args": ["pass"], "expect": "PASS", "must_fire": false, "note": "the token itself, so a disagreement points at the splitter"}, {"id": "B7-firstToken-nogo", "kind": "call", "fn": "firstToken", "args": ["NO-GO on 3 slugs"], "expect": "NO-GO", "must_fire": true, "note": "the hyphen stays inside the token - that is what keeps NO-GO out of GO"}, {"id": "B7-firstToken-null", "kind": "call", "fn": "firstToken", "args": [null], "expect": "", "must_fire": false, "note": "null yields the empty token, never the string 'null'"}, {"id": "B7-firstToken-punct", "kind": "call", "fn": "firstToken", "args": ["  ...GO!  "], "expect": "GO", "must_fire": false, "note": "leading punctuation is not a token"}, {"id": "B7-rejected", "kind": "call", "fn": "isRejected", "args": ["rejected - not carried"], "expect": true, "must_fire": false, "note": "isRejected reads the same way"}, {"id": "B7-rejected-negative", "kind": "call", "fn": "isRejected", "args": ["ok"], "expect": false, "must_fire": true, "note": "'ok' is not a rejection"}, {"id": "B7-normState", "kind": "call", "fn": "normState", "args": ["  Priced "], "expect": "priced", "must_fire": false, "note": "state strings are compared normalised, never raw"}, {"id": "B7-normState-null", "kind": "call", "fn": "normState", "args": [null], "expect": "", "must_fire": false, "note": "a null state is the empty string, not 'null'"}, {"id": "B8-comma-inside-term", "kind": "call", "fn": "termHasComma", "args": ["green bell pepper,shaved beef steak"], "expect": true, "must_fire": true, "note": "a comma inside a single term is detected"}, {"id": "B8-normal-term", "kind": "call", "fn": "termHasComma", "args": ["bacon bits"], "expect": false, "must_fire": false, "note": "a normal term carries no comma"}, {"id": "B8-two-terms-quote-as-two", "kind": "call", "fn": "quoteTerms", "args": [["green bell pepper", "shaved beef steak"]], "expect": "'green bell pepper','shaved beef steak'", "must_fire": true, "note": "two terms quote as TWO arguments, not one joined string"}, {"id": "B8-apostrophe-escaped", "kind": "call", "fn": "quoteTerms", "args": [["hy-vee's own"]], "expect": "'hy-vee''s own'", "must_fire": false, "note": "an apostrophe is doubled - the only escape a single-quoted PS string has"}, {"id": "B8-three-terms", "kind": "call", "fn": "quoteTerms", "args": [["a", "b,with,commas", "c"]], "expect": "'a','b,with,commas','c'", "must_fire": true, "note": "three elements, one of them carrying commas - the PS 5.1 collection rule says fixtures over collections use at least three"}, {"id": "B8-empty-and-falsy-dropped", "kind": "call", "fn": "quoteTerms", "args": [["a", "", null, "b"]], "expect": "'a','b'", "must_fire": false, "note": "an empty term is dropped rather than quoted into an empty argument"}, {"id": "B6-retries-across-batch-shapes", "kind": "retries", "args": [[["a", "b"], "map"], [["a", "x"], "map"], [["a"], "write"]], "expect": {"counts": {"map:a": 2, "map:b": 1, "map:x": 1, "write:a": 1}, "returns": [1, 2, 1]}, "must_fire": true, "note": "a slug carries its retries across DIFFERENT batch shapes, and retries are per STAGE - the two halves of B6's 657 failed calls"}, {"id": "B6-four-failures-do-not-trip", "kind": "breaker", "args": {"threshold": 5, "maxCalls": 900, "ops": [["note", false], ["note", false], ["note", false], ["note", false]]}, "expect": {"open": false, "calls": 0}, "must_fire": false, "note": "four failures do not trip the breaker"}, {"id": "B6-success-resets-the-streak", "kind": "breaker", "args": {"threshold": 5, "maxCalls": 900, "ops": [["note", false], ["note", false], ["note", false], ["note", false], ["note", true], ["note", false], ["note", false]]}, "expect": {"open": false, "calls": 0}, "must_fire": false, "note": "a success resets the streak, so per-recipe flakiness never trips it"}, {"id": "B6-five-consecutive-trip", "kind": "breaker", "args": {"threshold": 5, "maxCalls": 900, "ops": [["note", false], ["note", false], ["note", false], ["note", false], ["note", true], ["note", false], ["note", false], ["note", false], ["note", false], ["note", false]]}, "expect": {"open": true, "calls": 0}, "must_fire": true, "note": "five consecutive failures trip the breaker - a wall, not flakiness"}, {"id": "B6-call-budget-trips", "kind": "breaker", "args": {"threshold": 5, "maxCalls": 3, "ops": [["countCall"], ["countCall"], ["countCall"], ["checkBudget"]]}, "expect": {"open": true, "calls": 3}, "must_fire": true, "note": "the call budget trips before a runaway loop can eat the run"}, {"id": "B6-budget-not-reached", "kind": "breaker", "args": {"threshold": 5, "maxCalls": 3, "ops": [["countCall"], ["countCall"], ["checkBudget"]]}, "expect": {"open": false, "calls": 2}, "must_fire": false, "note": "under budget, the breaker stays shut"}, {"id": "B6-explicit-trip", "kind": "breaker", "args": {"threshold": 5, "maxCalls": 900, "ops": [["trip", "operator stop"]]}, "expect": {"open": true, "calls": 0}, "must_fire": false, "note": "an explicit trip opens it without any failure at all"}, {"id": "B10-clean-not-held-hostage", "kind": "call", "fn": "planTrim", "args": [["a", "b", "c"], {"a": "BLOCK", "b": "GO", "c": "GO"}, false], "expect": {"clean": ["b", "c"], "blocked": ["a"], "toReject": [], "toRepair": ["a"], "canPublishClean": true}, "must_fire": true, "note": "clean recipes are NOT held hostage by a blocked neighbour, and the blocker goes back for its one repair"}, {"id": "B10-repaired-blocker-is-terminal", "kind": "call", "fn": "planTrim", "args": [["a", "b", "c"], {"a": "BLOCK", "b": "GO", "c": "GO"}, true], "expect": {"clean": ["b", "c"], "blocked": ["a"], "toReject": ["a"], "toRepair": [], "canPublishClean": true}, "must_fire": true, "note": "after its repair cycle a blocker is terminal, never re-repaired"}, {"id": "B10-all-blocked-publishes-nothing", "kind": "call", "fn": "planTrim", "args": [["a", "b"], {"a": "BLOCK", "b": "BLOCK"}, true], "expect": {"clean": [], "blocked": ["a", "b"], "toReject": ["a", "b"], "toRepair": [], "canPublishClean": false}, "must_fire": true, "note": "an all-blocked wave publishes NOTHING"}, {"id": "B10-blocked-prefix-match", "kind": "call", "fn": "planTrim", "args": [["a", "b", "c"], {"a": "BLOCKED: cost drift", "b": "go", "c": "GO"}, false], "expect": {"clean": ["b", "c"], "blocked": ["a"], "toReject": [], "toRepair": ["a"], "canPublishClean": true}, "must_fire": false, "note": "the per-slug verdict is matched on the BLOCK prefix, case-insensitively"}, {"id": "B10-unlisted-slug-is-clean", "kind": "call", "fn": "planTrim", "args": [["a", "b", "c"], {"a": "BLOCK"}, false], "expect": {"clean": ["b", "c"], "blocked": ["a"], "toReject": [], "toRepair": ["a"], "canPublishClean": true}, "must_fire": false, "note": "a slug the auditor said nothing about is clean, not blocked"}, {"id": "B4-shared-data-forces-whole-wave", "kind": "call", "fn": "chooseScope", "args": ["shared-data", ["a"]], "expect": {"scope": "whole-wave", "why": "the fix moved shared data, so every recipe in the wave has new numbers"}, "must_fire": true, "note": "shared-data blockers force a whole-wave re-audit"}, {"id": "B4-recipe-local-scopes-narrow", "kind": "call", "fn": "chooseScope", "args": ["recipe-local", ["a", "b"]], "expect": {"scope": "a,b", "why": "the blocker was recipe-local, so nothing outside the repaired slugs moved"}, "must_fire": false, "note": "recipe-local blockers scope to the repaired slugs only"}, {"id": "B4-no-repaired-slugs-is-whole-wave", "kind": "call", "fn": "chooseScope", "args": ["recipe-local", []], "expect": {"scope": "whole-wave", "why": "the fix moved shared data, so every recipe in the wave has new numbers"}, "must_fire": true, "note": "an empty repair list cannot justify a narrow scope"}, {"id": "B4-narrow-on-shared-is-illegal", "kind": "call", "fn": "scopeIsLegal", "args": ["a,b", "shared-data"], "expect": false, "must_fire": true, "note": "a narrow scope on a shared-data fix is ILLEGAL"}, {"id": "B4-whole-wave-legal-on-shared", "kind": "call", "fn": "scopeIsLegal", "args": ["whole-wave", "shared-data"], "expect": true, "must_fire": false, "note": "whole-wave is always legal"}, {"id": "B4-whole-wave-legal-on-local", "kind": "call", "fn": "scopeIsLegal", "args": ["whole-wave", "recipe-local"], "expect": true, "must_fire": false, "note": "and a shared-data-sized audit of a local fix is merely expensive, not illegal"}, {"id": "B11-untouched-file-refused", "kind": "call", "fn": "repairClaimHolds", "args": [["a.json"], {"a.json": 100, "b.json": 100}, {"a.json": 100}], "expect": {"ok": false, "reason": "claimed to change but did not: a.json", "untouched": ["a.json"]}, "must_fire": true, "note": "a repair claiming a file it never touched is refused"}, {"id": "B11-real-repair-passes", "kind": "call", "fn": "repairClaimHolds", "args": [["a.json"], {"a.json": 100, "b.json": 100}, {"a.json": 200}], "expect": {"ok": true, "reason": "every claimed file changed"}, "must_fire": false, "note": "a real repair passes"}, {"id": "B11-nothing-needed-changing", "kind": "call", "fn": "repairClaimHolds", "args": [[], {"a.json": 100}, {"a.json": 100}], "expect": {"ok": true, "reason": "no change claimed"}, "must_fire": false, "note": "'nothing needed changing' is a legitimate answer, treated differently from a false claim"}, {"id": "B11-one-untouched-among-three", "kind": "call", "fn": "repairClaimHolds", "args": [["a.json", "b.json", "c.json"], {"a.json": 100, "b.json": 100, "c.json": 100}, {"a.json": 200, "b.json": 100, "c.json": 300}], "expect": {"ok": false, "reason": "claimed to change but did not: b.json", "untouched": ["b.json"]}, "must_fire": true, "note": "one untouched file among three is still caught"}, {"id": "band-below-floor", "kind": "call", "fn": "inBand", "args": [390, 10, {"calMin": 400, "calMax": 650, "carbMax": 35}], "expect": {"ok": false, "reason": "390 cal below the 400 floor"}, "must_fire": true, "note": "below the floor fails"}, {"id": "band-above-ceiling", "kind": "call", "fn": "inBand", "args": [660, 10, {"calMin": 400, "calMax": 650, "carbMax": 35}], "expect": {"ok": false, "reason": "660 cal above the 650 ceiling"}, "must_fire": true, "note": "above the CEILING fails - a band has two edges"}, {"id": "band-over-carbs", "kind": "call", "fn": "inBand", "args": [500, 36, {"calMin": 400, "calMax": 650, "carbMax": 35}], "expect": {"ok": false, "reason": "36g carbs above the 35 limit"}, "must_fire": true, "note": "over the carb limit fails"}, {"id": "band-mid", "kind": "call", "fn": "inBand", "args": [500, 20, {"calMin": 400, "calMax": 650, "carbMax": 35}], "expect": {"ok": true, "reason": ""}, "must_fire": false, "note": "mid-band passes"}, {"id": "band-edges-inclusive", "kind": "call", "fn": "inBand", "args": [400, 35, {"calMin": 400, "calMax": 650, "carbMax": 35}], "expect": {"ok": true, "reason": ""}, "must_fire": false, "note": "the exact edges are inside the band"}, {"id": "band-not-reported", "kind": "call", "fn": "inBand", "args": [null, 10, {"calMin": 400, "calMax": 650, "carbMax": 35}], "expect": {"ok": true, "reason": "not reported"}, "must_fire": false, "note": "an unreported macro is not a band failure - the band gate rules on numbers, and a missing number is a different problem for a different stage"}, {"id": "band-protein-below-floor", "kind": "call", "fn": "inBand", "args": [520, 20, {"calMin": 500, "calMax": 650, "carbMax": 40, "proteinMin": 50}, 47], "expect": {"ok": false, "reason": "47g protein below the 50 floor"}, "must_fire": true, "note": "a run band may state a protein FLOOR (Brad 2026-08-24, the band is a run parameter) and a dish under it is out of band"}, {"id": "band-protein-at-floor", "kind": "call", "fn": "inBand", "args": [520, 20, {"calMin": 500, "calMax": 650, "carbMax": 40, "proteinMin": 50}, 50], "expect": {"ok": true, "reason": ""}, "must_fire": false, "note": "the floor is inclusive, exactly as the cal floor is"}, {"id": "band-protein-not-reported", "kind": "call", "fn": "inBand", "args": [520, 20, {"calMin": 500, "calMax": 650, "carbMax": 40, "proteinMin": 50}, null], "expect": {"ok": true, "reason": "protein not reported"}, "must_fire": false, "note": "an unread protein number PASSES and says so - this is a retirement gate, and retiring a good dish on a number nobody read is D8 worse-than-no-gate in the other direction"}, {"id": "band-no-protein-rule", "kind": "call", "fn": "inBand", "args": [520, 20, {"calMin": 500, "calMax": 650, "carbMax": 40}, 12], "expect": {"ok": true, "reason": ""}, "must_fire": true, "note": "a band that states NO floor must not invent one - this is what keeps every pre-2026-08-24 band vector green"}, {"id": "band-carbs-judged-before-protein", "kind": "call", "fn": "inBand", "args": [520, 45, {"calMin": 500, "calMax": 650, "carbMax": 40, "proteinMin": 50}, 30], "expect": {"ok": false, "reason": "45g carbs above the 40 limit"}, "must_fire": true, "note": "clause ORDER is part of the contract. This dish fails BOTH clauses (45g carbs over 40, 30g protein under 50) so only the ORDER decides the reason - the first shape of this vector used 90g protein, cleared the floor, and proved nothing."}, {"id": "B9-takeBatch-sweeps", "kind": "chan", "scenario": "takeBatch-sweeps", "expect": 3, "must_fire": false, "note": "takeBatch sweeps what is queued without waiting to fill"}, {"id": "B9-closed-empty-returns-null", "kind": "chan", "scenario": "closed-empty-returns-null", "expect": true, "must_fire": false, "note": "a closed empty channel returns null rather than hanging"}, {"id": "B9-lone-item-immediate", "kind": "chan", "scenario": "lone-item-immediate", "expect": 1, "must_fire": true, "note": "a lone item is taken alone, immediately - streaming, not batching (B3 cost 8-10 minutes to the first flowing recipe)"}, {"id": "B9-close-releases-parked", "kind": "chan", "scenario": "close-releases-parked", "expect": true, "must_fire": true, "note": "close() releases a producer parked on backpressure - the hang bug itself"}, {"id": "B9-drain-before-close", "kind": "chan", "scenario": "drain-before-close", "expect": "a,b", "must_fire": false, "note": "items pushed before close are drained, not discarded"}, {"id": "B10-shared-blocker-does-not-spend-the-repair", "kind": "call", "fn": "planTrim", "args": [["a", "b"], {"a": "BLOCK", "b": "GO"}, true, "shared-data"], "expect": {"clean": ["b"], "blocked": ["a"], "toReject": [], "toRepair": ["a"], "canPublishClean": true}, "must_fire": true, "note": "the repair is already spent, but the blocker was a gate red over ANOTHER recipe's data - the slug goes back to be re-waved, never to rejected-audit, which is terminal"}, {"id": "B10-recipe-local-blocker-is-still-terminal", "kind": "call", "fn": "planTrim", "args": [["a", "b"], {"a": "BLOCK", "b": "GO"}, true, "recipe-local"], "expect": {"clean": ["b"], "blocked": ["a"], "toReject": ["a"], "toRepair": [], "canPublishClean": true}, "must_fire": true, "note": "the one-repair rule keeps its teeth: a defect in THIS recipe, already repaired once, is still terminal"}, {"id": "B10-unknown-blocker-kind-spends-the-repair", "kind": "call", "fn": "planTrim", "args": [["a", "b"], {"a": "BLOCK", "b": "GO"}, true, ""], "expect": {"clean": ["b"], "blocked": ["a"], "toReject": ["a"], "toRepair": [], "canPublishClean": true}, "must_fire": true, "note": "an audit that did not say what kind of blocker it found gets the OLD behaviour - the exemption is granted on evidence, never on silence"}]}
const SRC_SHA = "b5092ddf42b8f717"
// >>> GENERATED-VECTORS-END

if (!VECTORS || !VECTORS.vectors) throw new Error('hunt-lib-parity: no vectors embedded. Run `C:\\Codex\\Python312\\python.exe hunt_lib.py --emit-parity`.')
if (typeof planTrim !== 'function') throw new Error('hunt-lib-parity: hunt-lib.js was not spliced in. Run `C:\\Codex\\Python312\\python.exe hunt_lib.py --emit-parity`.')

const canon = v => {
  const walk = x => {
    if (Array.isArray(x)) return x.map(walk)
    if (x && typeof x === 'object') {
      const o = {}
      for (const k of Object.keys(x).sort()) o[k] = walk(x[k])
      return o
    }
    return x
  }
  return JSON.stringify(walk(v))
}

const CALLS = {
  firstToken: a => firstToken(...a),
  isPass: a => isPass(...a),
  isGo: a => isGo(...a),
  isRejected: a => isRejected(...a),
  normState: a => normState(...a),
  quoteTerms: a => quoteTerms(...a),
  termHasComma: a => termHasComma(...a),
  planTrim: a => planTrim(...a),
  chooseScope: a => chooseScope(...a),
  scopeIsLegal: a => scopeIsLegal(...a),
  // the JS signature takes ONE object; the vector carries the three arguments positionally so the
  // Python side can spread them. Adapting here keeps the vector file implementation-neutral.
  repairClaimHolds: a => repairClaimHolds({ claimedChanged: a[0], mtimesBefore: a[1], mtimesAfter: a[2] }),
  inBand: a => inBand(...a),
}

async function chanScenario(name) {
  if (name === 'takeBatch-sweeps') {
    const c = chan(); c.push(1); c.push(2); c.push(3)
    return (await c.takeBatch(5)).length
  }
  if (name === 'closed-empty-returns-null') {
    const c = chan(); c.push(1); c.push(2); c.push(3)
    await c.takeBatch(5); c.close()
    return (await c.take()) === null
  }
  if (name === 'lone-item-immediate') {
    const c = chan(); c.push('x')
    return (await c.takeBatch(5)).length
  }
  if (name === 'close-releases-parked') {
    const c = chan(); c.push(1); c.push(2)
    let released = false
    const parked = c.waitForSpace(2).then(() => { released = true })
    c.close()
    await parked
    return released
  }
  if (name === 'drain-before-close') {
    const c = chan(); const got = []
    const consumer = (async () => { for (;;) { const v = await c.take(); if (v === null) break; got.push(v) } })()
    c.push('a'); c.push('b'); c.close()
    await consumer
    return got.join(',')
  }
  throw new Error(`unknown chan scenario ${name}`)
}

async function runOne(v) {
  const kind = v.kind || 'call'
  if (kind === 'call') {
    const fn = CALLS[v.fn]
    if (!fn) throw new Error(`the vector file names a function this runner does not have: ${v.fn}`)
    return fn(v.args || [])
  }
  if (kind === 'retries') {
    const counts = new Map(); const returns = []
    for (const step of v.args) returns.push(bumpRetries(counts, step[0], step[1]))
    const obj = {}
    for (const [k, n] of counts) obj[k] = n
    return { counts: obj, returns }
  }
  if (kind === 'breaker') {
    const b = makeBreaker({ threshold: v.args.threshold, maxCalls: v.args.maxCalls })
    for (const op of v.args.ops || []) {
      if (op[0] === 'note') b.note(op[1])
      else if (op[0] === 'countCall') b.countCall()
      else if (op[0] === 'checkBudget') b.checkBudget()
      else if (op[0] === 'trip') b.trip(op[1])
      else throw new Error(`unknown breaker op ${op[0]}`)
    }
    return { open: b.open, calls: b.calls }
  }
  if (kind === 'chan') return await chanScenario(v.scenario)
  throw new Error(`unknown vector kind ${kind}`)
}

phase('Parity')
const rows = []
let bad = 0
for (const v of VECTORS.vectors) {
  let got, ok
  try {
    got = await runOne(v)
    ok = canon(got) === canon(v.expect)
  } catch (e) {
    got = `THREW: ${String(e).slice(0, 200)}`
    ok = false
  }
  if (!ok) { bad += 1; log(`  X  ${v.must_fire ? 'MUST FIRE ' : 'CLEAN TWIN'} ${v.id}  expected ${canon(v.expect)}, got ${canon(got)}`) }
  rows.push({ id: v.id, ok, must_fire: !!v.must_fire, got: ok ? '' : canon(got), expect: canon(v.expect) })
}
log(`hunt-lib parity (javascript): ${rows.length - bad}/${rows.length} green   [hunt-lib.js @ ${SRC_SHA}]`)
return { impl: 'javascript', total: rows.length, failed: bad, src_sha: SRC_SHA, rows }
