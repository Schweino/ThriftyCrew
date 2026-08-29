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
export const firstToken = v =>
  String(v == null ? '' : v).trim().toUpperCase().split(/[^A-Z-]+/).filter(Boolean)[0] || ''
export const isPass = v => firstToken(v) === 'PASS'
export const isGo = v => firstToken(v) === 'GO'
export const isRejected = v => firstToken(v) === 'REJECTED'
export const normState = v => String(v == null ? '' : v).trim().toLowerCase()

// -----------------------------------------------------------------------------------------------------
// TERM MARSHALLING (B8). PowerShell binds `-Terms 'a,b'` to a [string[]] of ONE element - the literal
// "a,b" - which can never match an ingredient-queue entry, so the recipe parks forever while its
// ingredients sit CARRIED. Terms must be emitted as separate quoted strings.
// -----------------------------------------------------------------------------------------------------
export const quoteTerms = terms =>
  (terms || []).filter(Boolean).map(t => `'${String(t).replace(/'/g, "''")}'`).join(',')
export const termHasComma = t => String(t == null ? '' : t).includes(',')

// -----------------------------------------------------------------------------------------------------
// RETRY ACCOUNTING (B6). Budgets are keyed PER SLUG, never per batch shape. The map lane pulls a new
// slug combination each cycle, so a shape-keyed budget minted a fresh allowance every time and never
// saturated - 657 failed calls against a session limit that only a clock could clear.
// -----------------------------------------------------------------------------------------------------
export function bumpRetries(counts, slugs, stage) {
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
export function makeBreaker({ threshold = 5, maxCalls = 900 } = {}) {
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
export function planTrim(waveSlugs, perSlug, alreadyRepaired, blockerKind) {
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
export function chooseScope(blockerKind, repairedSlugs) {
  if (blockerKind === 'shared-data' || !repairedSlugs || repairedSlugs.length === 0) {
    return { scope: 'whole-wave', why: 'the fix moved shared data, so every recipe in the wave has new numbers' }
  }
  return { scope: repairedSlugs.join(','), why: 'the blocker was recipe-local, so nothing outside the repaired slugs moved' }
}
// The gate half: a narrow scope is only legal when the change really was recipe-local.
export function scopeIsLegal(scope, blockerKind) {
  if (blockerKind === 'shared-data') return scope === 'whole-wave'
  return true
}

// -----------------------------------------------------------------------------------------------------
// POSTCONDITIONS (B11). A repair agent reported success having changed nothing; the only thing that
// caught it was paying for a second full audit, which checked file mtimes itself. Verify the claim
// BEFORE paying for the expensive next stage. "Nothing needed changing" is a legitimate answer and is
// treated differently from "I changed X" with X untouched.
// -----------------------------------------------------------------------------------------------------
export function repairClaimHolds({ claimedChanged, mtimesBefore, mtimesAfter }) {
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
export function inBand(cal, carbs, { calMin, calMax, carbMax, proteinMin }, protein) {
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
export function chan() {
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
export async function selfTest(log = console.log) {
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
