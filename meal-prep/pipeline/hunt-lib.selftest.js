export const meta = {
  name: 'hunt-lib-selftest',
  description: 'Run hunt-lib.js fixtures with ZERO agent calls',
  phases: [{ title: 'SelfTest' }],
}

// SUPERSEDED 2026-08-24 by `hunt-lib-parity.js` (PLAN-recipe-hunter-v3 section 4.2, D9). Kept for
// history; do not extend it, and do not read a green run here as the parity gate.
//
// Everything below is a HAND-COPIED duplicate of hunt-lib.js, and the paragraph that used to sit
// here said so: "if they drift, the fixtures are testing something that is no longer shipped, which
// is worse than having no fixtures at all". That is a warning, not a mechanism, and a warning is
// what this estate keeps discovering it had instead of a check.
//
// The replacement keeps the one unavoidable part - a workflow script cannot read the repo, so the
// copy has to exist - and removes the human from it: `hunt_lib.py --emit-parity` splices hunt-lib.js
// in mechanically and stamps its SHA-256, and `hunt_lib.py --selftest` re-hashes the shipped file
// and FIRES if the two have drifted. It also runs the fixtures as SHARED VECTORS
// (`hunt-lib-vectors.json`) against both hunt-lib.js and hunt_lib.py, which is what the parity gate
// actually asks for and what this file cannot do at all.

const firstToken = v => String(v == null ? '' : v).trim().toUpperCase().split(/[^A-Z-]+/).filter(Boolean)[0] || ''
const isPass = v => firstToken(v) === 'PASS'
const isGo = v => firstToken(v) === 'GO'
const quoteTerms = terms => (terms || []).filter(Boolean).map(t => `'${String(t).replace(/'/g, "''")}'`).join(',')
const termHasComma = t => String(t == null ? '' : t).includes(',')

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

function makeBreaker({ threshold = 5, maxCalls = 900 } = {}) {
  let consecutive = 0, calls = 0, open = false, reason = ''
  return {
    get open() { return open }, get reason() { return reason },
    countCall() { calls += 1 },
    note(ok) {
      if (ok) { consecutive = 0; return }
      consecutive += 1
      if (consecutive >= threshold && !open) { open = true; reason = `${consecutive} consecutive failures` }
    },
    checkBudget() { if (!open && calls >= maxCalls) { open = true; reason = `budget ${calls}/${maxCalls}` } return open },
  }
}

function planTrim(waveSlugs, perSlug, alreadyRepaired) {
  const blocked = [], clean = []
  for (const s of waveSlugs) {
    const v = perSlug && perSlug[s]
    if (v && String(v).toUpperCase().startsWith('BLOCK')) blocked.push(s); else clean.push(s)
  }
  return { clean, blocked, toReject: alreadyRepaired ? blocked : [], toRepair: alreadyRepaired ? [] : blocked, canPublishClean: clean.length > 0 }
}

function chooseScope(blockerKind, repairedSlugs) {
  if (blockerKind === 'shared-data' || !repairedSlugs || repairedSlugs.length === 0) return { scope: 'whole-wave' }
  return { scope: repairedSlugs.join(',') }
}
function scopeIsLegal(scope, blockerKind) { if (blockerKind === 'shared-data') return scope === 'whole-wave'; return true }

function repairClaimHolds({ claimedChanged, mtimesBefore, mtimesAfter }) {
  if (!claimedChanged || claimedChanged.length === 0) return { ok: true }
  const untouched = claimedChanged.filter(f => (mtimesAfter[f] || 0) <= (mtimesBefore[f] || 0))
  return untouched.length === 0 ? { ok: true } : { ok: false, untouched }
}

function inBand(cal, carbs, { calMin, calMax, carbMax }) {
  if (typeof cal !== 'number' || typeof carbs !== 'number') return { ok: true }
  if (cal < calMin) return { ok: false }
  if (cal > calMax) return { ok: false }
  if (carbs > carbMax) return { ok: false }
  return { ok: true }
}

function chan() {
  const items = [], waiters = [], spaceWaiters = []
  let closed = false
  return {
    push(x) { items.push(x); const w = waiters.shift(); if (w) w() },
    close() { closed = true; waiters.splice(0).forEach(w => w()); spaceWaiters.splice(0).forEach(w => w()) },
    size() { return items.length },
    async waitForSpace(limit) { while (items.length >= limit && !closed) await new Promise(r => spaceWaiters.push(r)) },
    async take() {
      for (;;) {
        if (items.length) { const v = items.shift(); spaceWaiters.splice(0).forEach(w => w()); return v }
        if (closed) return null
        await new Promise(r => waiters.push(r))
      }
    },
    async takeBatch(n) {
      const first = await this.take()
      if (first === null) return null
      const batch = [first]
      while (batch.length < n && items.length) batch.push(items.shift())
      return batch
    },
  }
}

phase('SelfTest')
const results = []
let bad = 0
const T = (name, ok, got) => { if (ok) { results.push(`ok    ${name}`) } else { results.push(`X     ${name}   got: ${got}`); bad++ } }

T('MUST FIRE  lowercase "pass" IS a pass', isPass('pass'), firstToken('pass'))
T('CLEAN TWIN uppercase PASS is a pass', isPass('PASS'), firstToken('PASS'))
T('"PASS (with notes)" is a pass', isPass('PASS (with notes)'), firstToken('PASS (with notes)'))
T('MUST FIRE  "FAIL" is not a pass', !isPass('FAIL'), firstToken('FAIL'))
T('MUST FIRE  "NO-GO" is NEVER read as GO', !isGo('NO-GO') && !isGo('no-go'), firstToken('NO-GO'))
T('CLEAN TWIN "GO"/"go" are GO', isGo('GO') && isGo('go'), firstToken('go'))
T('MUST FIRE  null verdict is neither pass nor GO', !isPass(null) && !isGo(null), firstToken(null))
T('MUST FIRE  empty verdict is not GO', !isGo(''), firstToken(''))

T('MUST FIRE  a comma inside one term is detected', termHasComma('green bell pepper,shaved beef steak'), 'no')
T('CLEAN TWIN a normal term has no comma', !termHasComma('bacon bits'), 'false positive')
T('MUST FIRE  two terms quote as TWO args', quoteTerms(['green bell pepper', 'shaved beef steak']) === "'green bell pepper','shaved beef steak'", quoteTerms(['green bell pepper', 'shaved beef steak']))
T('an apostrophe is escaped', quoteTerms(["hy-vee's own"]) === "'hy-vee''s own'", quoteTerms(["hy-vee's own"]))

{
  const c = new Map()
  bumpRetries(c, ['a', 'b'], 'map')
  bumpRetries(c, ['a', 'x'], 'map')
  T('MUST FIRE  retries follow the SLUG across batch shapes', c.get('map:a') === 2, String(c.get('map:a')))
  T('CLEAN TWIN a once-seen slug has one retry', c.get('map:x') === 1, String(c.get('map:x')))
  T('retries are per stage', bumpRetries(c, ['a'], 'write') === 1, 'leaked')
}
{
  const b = makeBreaker({ threshold: 5 })
  for (let i = 0; i < 4; i++) b.note(false)
  T('CLEAN TWIN four failures do not trip', !b.open, 'tripped')
  b.note(true); b.note(false); b.note(false)
  T('CLEAN TWIN a success resets the streak', !b.open, 'tripped on flakiness')
  for (let i = 0; i < 5; i++) b.note(false)
  T('MUST FIRE  five consecutive failures trip', b.open, 'no trip')
}
{
  const b = makeBreaker({ threshold: 5, maxCalls: 3 })
  b.countCall(); b.countCall(); b.countCall()
  T('MUST FIRE  the call budget trips before the harness cap', b.checkBudget(), 'no trip')
}
{
  const t = planTrim(['a', 'b', 'c'], { a: 'BLOCK', b: 'GO', c: 'GO' }, false)
  T('MUST FIRE  clean recipes are not held hostage', t.clean.join(',') === 'b,c', t.clean.join(','))
  T('a blocker goes back for one repair', t.toRepair.join(',') === 'a', t.toRepair.join(','))
  const t2 = planTrim(['a', 'b', 'c'], { a: 'BLOCK', b: 'GO', c: 'GO' }, true)
  T('MUST FIRE  after its repair a blocker is terminal', t2.toReject.join(',') === 'a', t2.toReject.join(','))
  const t3 = planTrim(['a', 'b'], { a: 'BLOCK', b: 'BLOCK' }, true)
  T('MUST FIRE  an all-blocked wave publishes nothing', !t3.canPublishClean, 'would publish')
}
{
  T('shared-data forces whole-wave', chooseScope('shared-data', ['a']).scope === 'whole-wave', 'no')
  T('recipe-local scopes to repaired slugs', chooseScope('recipe-local', ['a', 'b']).scope === 'a,b', 'no')
  T('MUST FIRE  narrow scope on shared-data is ILLEGAL', !scopeIsLegal('a,b', 'shared-data'), 'allowed')
  T('CLEAN TWIN whole-wave always legal', scopeIsLegal('whole-wave', 'shared-data'), 'refused')
}
{
  const before = { 'a.json': 100, 'b.json': 100 }
  T('MUST FIRE  a repair that touched nothing is refused', !repairClaimHolds({ claimedChanged: ['a.json'], mtimesBefore: before, mtimesAfter: { 'a.json': 100 } }).ok, 'accepted')
  T('CLEAN TWIN a real repair passes', repairClaimHolds({ claimedChanged: ['a.json'], mtimesBefore: before, mtimesAfter: { 'a.json': 200 } }).ok, 'refused')
  T('CLEAN TWIN "nothing needed changing" is legitimate', repairClaimHolds({ claimedChanged: [], mtimesBefore: before, mtimesAfter: before }).ok, 'refused')
  T('MUST FIRE  one untouched file among several is caught', !repairClaimHolds({ claimedChanged: ['a.json', 'b.json'], mtimesBefore: before, mtimesAfter: { 'a.json': 200, 'b.json': 100 } }).ok, 'missed')
}
T('MUST FIRE  below the floor fails', !inBand(390, 10, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'passed')
T('MUST FIRE  above the CEILING fails', !inBand(660, 10, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'passed')
T('MUST FIRE  over the carb limit fails', !inBand(500, 36, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'passed')
T('CLEAN TWIN mid-band passes', inBand(500, 20, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'failed')
T('CLEAN TWIN exact edges are inside', inBand(400, 35, { calMin: 400, calMax: 650, carbMax: 35 }).ok, 'edge rejected')

{
  const c = chan()
  c.push(1); c.push(2); c.push(3)
  const b = await c.takeBatch(5)
  T('takeBatch sweeps without waiting to fill', b.length === 3, String(b.length))
  c.close()
  T('a closed empty channel returns null', (await c.take()) === null, 'hung')
}
{
  const c = chan()
  c.push('x')
  const one = await c.takeBatch(5)
  T('MUST FIRE  a lone item is taken alone (streaming)', one.length === 1, String(one.length))
}
{
  const c = chan()
  c.push(1); c.push(2)
  let released = false
  const parked = c.waitForSpace(2).then(() => { released = true })
  c.close()
  await parked
  T('MUST FIRE  close() releases a backpressure-parked producer (the hang bug)', released, 'still parked')
}
{
  const c = chan()
  const got = []
  const consumer = (async () => { for (;;) { const v = await c.take(); if (v === null) break; got.push(v) } })()
  c.push('a'); c.push('b'); c.close()
  await consumer
  T('items pushed before close are drained', got.join(',') === 'a,b', got.join(','))
}

results.forEach(r => log('  ' + r))
log(bad > 0 ? `hunt-lib SELF-TEST FAIL (${bad})` : 'hunt-lib SELF-TEST PASS')
return { ok: bad === 0, failures: bad, total: results.length, results }
