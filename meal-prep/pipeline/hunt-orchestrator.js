export const meta = {
  name: 'recipe-hunt-lowcarb-proving',
  description: '100 dinner recipes at 400-650 cal / <=35g carbs per serving, continuous lane model per PLAN v2 section 2.4',
  phases: [
    { title: 'Hunt' },
    { title: 'Select' },
    { title: 'Extract' },
    { title: 'Map' },
    { title: 'Price' },
    { title: 'Write' },
    { title: 'QA' },
    { title: 'Wave' },
    { title: 'Instrument' },
  ],
}

// ---------------------------------------------------------------------------------------------
// SUPERSEDED FRONT END (2026-08-23, PLAN-recipe-hunter-v3 phase 1). The hunt and adjudicate lanes
// below - 12 sourcers and 8 dedup adjudicators, 75.5% of run wf_11382034-6fd's tokens - are replaced
// in v3 by the harvest plane (meal-prep\pipeline\harvest.py, zero tokens) plus ONE decider call per
// ten pre-qualified dossiers (hunt-pool-seed.js). This file is kept because everything from `extract`
// downstream is still the architecture of record and DRAIN mode still carries a seeded run to
// publication; the v3 bridge seeds `selected` and hands off here. Do not restore the sourcer lanes to
// "fix" an empty candidate queue - the backlog is the supply now. Phase 3 (D9) ports the whole file
// to hunt-daemon.py under section 4.2's parity gate.
// ---------------------------------------------------------------------------------------------
// Architecture of record: design\PLAN-recipe-hunter-v2-2026-08-15.md section 2.4 (lane model),
// section 3 (stage specs), plus design\PLAN-recipe-hunter-v2.1-2026-08-15.md section 5 (proving run).
// This is a LANE model, not a per-recipe pipeline. The price lane in particular is a self-looping
// queue drainer batching up to 10 terms ACROSS recipes, because ingredient-queue.ps1 is keyed by
// TERM and dedupes across recipes - pricing one recipe at a time throws that dedup away and opens
// seven store sessions for two or three terms.
// ---------------------------------------------------------------------------------------------

const RUN = 'C:\\Codex\\ThriftyCrew\\meal-prep\\runs\\hunt-2026-08-15-lowcarb-100'
const HR = 'C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\hunt-run.ps1'
const IQ = 'C:\\Codex\\ThriftyCrew\\grocery\\ingredient-queue.ps1'
const DIGEST = 'C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\catalog-digest.json'
// The pipeline dir, so prompts can name the query tools instead of the files they wrap. Every one of
// these exists to make an agent ASK a question rather than LOAD a corpus - measured 2026-08-16, the
// hunt and select lanes were 75.5% of a 751M-token run, most of it repeated context.
const PIPE = 'C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline'
const RUNID = 'hunt-2026-08-15-lowcarb-100'
const TARGET = 100
const WAVE_SIZE = 10          // plan default; 100 recipes = 10 waves = 10 audits, not 20
const MAX_ROUNDS = 10         // per hunt worker
const CAL_MIN = 400
const CAL_MAX = 650
const CARB_MAX = 35
const COND = 'between 400 and 650 calories per serving AND 35 g carbohydrate or less per serving; budget meal-prep dinner; scalable to 14 servings; no seafood'

// section 2.4 lane caps
const CAP = { extract: 3, map: 2, write: 3, qa: 2 }

// Brad's direction 2026-08-15: 20 workers across hunting and deduping (12 hunt + 8 adjudicate).
// The workflow harness caps CONCURRENT agents at min(16, cpus-2) = 16 on this box, for the WHOLE run.
// 20 front-end workers therefore cannot all be alive at once, and left unchecked they would hold every
// slot and starve extract/map/price/write/qa - including publishing. HUNT_BACKPRESSURE is what stops
// that: a sourcer that finds the candidate queue already deep parks itself instead of hunting more,
// which hands its slot to whatever is downstream. Queues as buffers, per Brad's chart.
// ---------------------------------------------------------------------------------------------
// DRAIN MODE (Brad's direction 2026-08-16): source nothing new, carry what is already in the
// pipeline all the way down the chain and publish it.
//
// The hunt/adjudicate/decide lanes are switched off entirely. That alone would produce an empty run,
// because this script rebuilds its in-memory queues from scratch on every launch and normally fills
// them by hunting - the recipes in flight live in the run dir's state files, not in the workflow's
// memory. So the lanes are SEEDED below from the real state, read off disk before launch with
// hunt-run.ps1 -Status and the state files themselves. Each recipe enters at the lane matching the
// state it actually stopped at, and flows down from there under its own steam.
// ---------------------------------------------------------------------------------------------
const DRAIN_ONLY = true

// Seeded from state\*.json on 2026-08-16, AFTER repairing the -Terms comma bug and re-deriving.
// extracted -> map, priced -> write, written -> qa, qa-passed -> straight into a wave.
// Re-read from state\*.json on 2026-08-16 after the partial drain, so this reflects where every recipe
// ACTUALLY stopped - not where the first seed put it.
// Re-read from state\*.json 2026-08-16 AFTER the vocabulary work, the board commodities reaching the
// feed, and the phantom repairs. All 24 in-flight intakes now build; every cost gate is green.
const SEED = {
  extracted: [
    'methi-malai-murgh-creamy-fenugreek-chicken', 'mexican-chorizo-egg-casserole',
    'pork-chile-verde-stew', 'pulled-pork-stuffed-peppers',
    'slow-cooker-korean-galbi-jjim-short-ribs', 'spinach-artichoke-chicken-casserole',
    'turkey-meatballs-cream-sauce-skillet', 'turkey-parmesan-meatball-bake',
  ],
  priced: [
    'balsamic-sirloin-steak-sheet-pan', 'basque-chicken-peppers-chilindron',
    'braised-pork-shoulder-fennel-tomato', 'chicken-bacon-ranch-cauliflower-bake',
    'chicken-marsala-skillet', 'creamy-garlic-herb-wine-pork-chops',
    'garlic-butter-steak-bites-zucchini', 'italian-sausage-stuffed-peppers-bake',
    'jalapeno-popper-chicken-casserole',
  ],
  written: [],
  // 9 through QA. NOT seeded with the 10 sitting in `waved` - those belong to wave 1 and the trim
  // returns the audit-clean ones to this pool itself. Seeding them here as well would double-count
  // them and close a wave over recipes another wave already owns.
  qaPassed: [
    'flank-steak-parmesan-green-beans', 'keto-cheeseburger-skillet', 'low-carb-steak-fajita-skillet',
    'low-carb-taco-cabbage-beef-skillet', 'low-carb-turkey-cauliflower-mushroom-casserole',
    'philly-cheesesteak-stuffed-peppers', 'sheet-pan-smoked-sausage-broccoli-cheddar',
    'sheet-pan-tandoori-chicken-cauliflower', 'spinach-provolone-stuffed-flank-steak-rolls',
  ],
  // One genuinely parked recipe. The price lane retries it; unchecked is never not-carried.
  parked: [
    { slug: 'low-carb-beef-meatloaf', terms: ['90/10 ground beef', 'unsweetened ketchup'] },
  ],
}

const HUNT_WORKERS = 12
const DEDUP_WORKERS = 8
// Candidates (not pools) waiting to be adjudicated before sourcers stand down. 8 adjudicators sweeping up
// to 3 each means ~24 in flight covers the whole dedup lane; past that, hunting is only building a backlog
// and should yield its slots to extract/map/price/write/qa.
const HUNT_BACKPRESSURE = 24
const MAP_BATCH = 5   // section S4: mapper micro-batches of up to 5 recipes
const PRICE_BATCH = 10 // section 2.4: up to 10 absent terms per pricer invocation, across recipes

// ---------------------------------------------------------------------------------------------
// channels: no timers available in this sandbox, so lanes block on promises, never on polling
// ---------------------------------------------------------------------------------------------
function chan() {
  const items = []
  const waiters = []
  const spaceWaiters = []   // producers parked by backpressure, woken when a consumer takes
  let closed = false
  return {
    push(x) { items.push(x); const w = waiters.shift(); if (w) w() },
    close() { closed = true; waiters.splice(0).forEach(w => w()); spaceWaiters.splice(0).forEach(w => w()) },
    isClosed() { return closed },
    size() { return items.length },
    // Park until the backlog drops below `limit`. There are no timers in this sandbox, so this waits on
    // a consumer actually taking an item rather than polling a clock.
    async waitForSpace(limit) {
      while (items.length >= limit && !closed) {
        await new Promise(r => spaceWaiters.push(r))
      }
    },
    async take() {
      for (;;) {
        if (items.length) {
          const v = items.shift()
          spaceWaiters.splice(0).forEach(w => w())
          return v
        }
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

async function pool(n, worker) {
  await Promise.all(Array.from({ length: n }, (_, i) => worker(i)))
}

// AN AGENT CALL RETURNING NULL IS NOT A VERDICT. It means the call itself never completed - a session
// limit, a timeout, an infra error - and the agent never looked at the recipe at all. Treating that the
// same as an explicit rejection is the bug that struck this run on 2026-08-15: a session-limit outage
// killed the mapper mid-batch, and every recipe in that batch got recorded as 'rejected-not-carried'
// with detail 'mapper rejected', when the mapper had never actually ruled on any of them - the real
// hunt-run state file still read 'extracted'. Only a schema-shaped result with an explicit negative
// field (status:'rejected', verdict:'FAIL', etc) is a real verdict. A null result gets retried; only
// after retries are exhausted does the recipe stop, and even then it is recorded as STUCK, never as
// REJECTED - because no one ever rendered a verdict on it.
const MAX_STAGE_RETRIES = 2
const retryCounts = new Map()

// ---------------------------------------------------------------------------------------------
// THE CIRCUIT BREAKER, and why retry budgets alone were not enough.
//
// On 2026-08-16 this run burned 16.1M tokens and 657 failed agent calls making ZERO progress, then
// died on the harness's own 1000-call cap. Every one of those failures was the same session limit,
// which does not clear on retry - it clears at a wall-clock time. Two things let it run away:
//
//   1. Retry budgets were keyed by BATCH SHAPE (the sorted slug list). The map lane pulls a fresh
//      combination of slugs off the queue each cycle, so every new grouping minted a brand-new
//      untouched 3-attempt budget. The budget never saturated because the key never repeated.
//      Fixed below: retries are now accounted PER SLUG, so a recipe that has burned its attempts
//      does not get a fresh allowance by landing in a different batch.
//
//   2. Nothing was watching run-wide. Each lane only saw its own local failures, so eight lanes
//      independently concluded "just one more try" against a wall none of them could see whole.
//
// agent() returns a bare null on failure - the script never receives the error text - so the breaker
// cannot match on "session limit". It watches the SHAPE instead: consecutive failures run-wide, with
// any success resetting the count. Per-recipe flakiness produces isolated nulls between successes and
// never trips it; a hard wall produces an unbroken run of them and trips it almost immediately.
// ---------------------------------------------------------------------------------------------
const CIRCUIT_THRESHOLD = 5      // consecutive run-wide failures before we stop dispatching
const MAX_AGENT_CALLS = 900      // the harness kills the workflow at 1000; stop short and exit clean
let consecutiveFailures = 0
let agentCalls = 0
let circuitOpen = false
let circuitReason = ''

function tripCircuit(reason) {
  if (circuitOpen) return
  circuitOpen = true
  circuitReason = reason
  log(`*** CIRCUIT BREAKER OPEN: ${reason}`)
  log('*** No further agent calls will be dispatched. Lanes are draining; the run dir keeps every')
  log('*** completed recipe, and a resume re-enters exactly where each one stopped.')
  // Wake every blocked lane so they observe circuitOpen and unwind instead of hanging on take().
  candCh.close(); decideCh.close(); extractCh.close(); mapCh.close(); writeCh.close(); qaCh.close(); priceWake.close()
  notifyWip()
}

function noteAgentResult(ok) {
  if (ok) { consecutiveFailures = 0; return }
  consecutiveFailures += 1
  if (consecutiveFailures >= CIRCUIT_THRESHOLD) {
    tripCircuit(`${consecutiveFailures} consecutive agent failures run-wide - this is a systemic wall (session limit, auth, or outage), not per-recipe flakiness. Retrying it only burns tokens against a clock.`)
  }
}

// True when a lane should stop dispatching new work entirely.
function halted() {
  if (circuitOpen) return true
  if (agentCalls >= MAX_AGENT_CALLS) {
    tripCircuit(`agent call budget reached (${agentCalls}/${MAX_AGENT_CALLS}) - stopping short of the harness's 1000-call kill so the run exits cleanly and stays resumable`)
    return true
  }
  return false
}

// slugs may be one slug or an array (batch calls). Retries are accounted per slug either way.
async function withRetry(fn, slugs, stage) {
  const list = (Array.isArray(slugs) ? slugs : [slugs]).filter(Boolean)
  for (;;) {
    if (halted()) return null
    agentCalls += 1
    const r = await fn()
    if (r !== null && r !== undefined) { noteAgentResult(true); return r }
    noteAgentResult(false)
    if (circuitOpen) return null
    let worst = 0
    for (const s of list) {
      const key = `${stage}:${s}`
      const n = (retryCounts.get(key) || 0) + 1
      retryCounts.set(key, n)
      if (n > worst) worst = n
    }
    if (worst > MAX_STAGE_RETRIES) {
      log(`${stage}: ${list.join(',')} - out of retries after ${worst} attempts; marking STUCK, not rejected`)
      return null
    }
    log(`${stage}: ${list.join(',')} - no response (agent call failed), retry ${worst}/${MAX_STAGE_RETRIES}`)
  }
}
// ---------------------------------------------------------------------------------------------
// NEVER COMPARE AN AGENT'S VERDICT STRING WITH ===. On 2026-08-16 every source-QA agent returned
// verdict "pass" in lowercase against a check of `!== 'PASS'`, so all 12 genuine passes were read as
// failures: each one burned a spurious owner-routed repair cycle plus a re-QA, qaPassed never grew,
// and no wave ever closed - the pipeline looked stalled while it was actually succeeding. Only the QA
// agents refusing to write a rejection they could not substantiate ("no state file was written; the
// run is unchanged") kept it from permanently killing passing recipes, since rejected-qa is terminal.
//
// A verdict is free text from a model. Normalise case, trim, and compare the FIRST TOKEN so that
// "pass", "PASS", and "PASS (with notes)" all read alike, while "NO-GO" can never be mistaken for
// "GO" (its first token is "NO-GO", which is not "GO").
const firstToken = v => String(v == null ? '' : v).trim().toUpperCase().split(/[^A-Z-]+/).filter(Boolean)[0] || ''
const isPass = v => firstToken(v) === 'PASS'
const isGo = v => firstToken(v) === 'GO'
const isRejected = v => firstToken(v) === 'REJECTED'
const normState = v => String(v == null ? '' : v).trim().toLowerCase()

function stuck(slug, stage, detail) {
  const c = record(slug, { status: 'stuck', state: null, detail: `${stage}: ${detail}` })
  outcomes.push(c)
  notifyWip()
}

const candCh = chan()     // sourcer pools -> adjudicators
const decideCh = chan()   // adjudicated lane verdicts -> the single decider
const extractCh = chan()
const mapCh = chan()
const writeCh = chan()
const qaCh = chan()

// Every lane invocation is recorded as it is dispatched, so audit-lane-shape.ps1 can judge the SHAPE of
// the work afterwards. The state files and the queue record only the RESULT: a run that priced 9 terms in
// 8 sessions and one that priced them in a single batch leave byte-identical evidence without this log.
// EVERY dispatch is logged at BOTH ends. The start line says what was asked for; the end line is what
// makes duration measurable at all, because this sandbox forbids Date.now() so the orchestrator cannot
// time its own calls - the agent stamps both ends itself.
//
// The wave lane (audit, publish, review, trim, repair) carried NO logging until 2026-08-16, which is
// why 37 agents and 24M tokens landed under `unknown` in the first real cost measurement - and the
// audit is the single most expensive stage in the flow, measured at 31% of tokens in v2.1. The most
// expensive thing we had was the thing we could not see.
function laneLog(laneName, label, items) {
  const list = (items || []).filter(Boolean).join(',').replace(/'/g, "''")
  const lbl = String(label).replace(/'/g, "''")
  return `FIRST, before doing any work, record that this invocation started:
  powershell -NoProfile -File ${HR} -Lane -RunDir ${RUN} -LaneName ${laneName} -Label '${lbl}' -Items '${list}' -By orchestrator -Event start

LAST, once your work is done and just before you return, record that it finished:
  powershell -NoProfile -File ${HR} -Lane -RunDir ${RUN} -LaneName ${laneName} -Label '${lbl}' -Items '${list}' -By orchestrator -Event end

Both lines matter. The pair is the only measurement of how long this stage takes, and a stage nobody
can measure is a stage nobody can make faster.
`
}

const REC = new Map()          // slug -> ctx
const absentTerms = new Set()  // union of unpriced terms across recipes (the queue dedupes these too)
const pricingSlugs = new Set() // recipes sitting in `pricing`
const priceWake = chan()       // signals the singleton price lane that there is work
const outcomes = []

function record(slug, patch) {
  const c = REC.get(slug) || { slug }
  Object.assign(c, patch)
  REC.set(slug, c)
  return c
}
function finish(slug, status, state, detail) {
  const c = record(slug, { status, state, detail })
  outcomes.push(c)
  notifyWip()   // a resolved recipe frees WIP, which may release a parked sourcer
  return c
}

const SHELL = `You run PowerShell on Windows. Repo root C:\\Codex\\ThriftyCrew. Run dir ${RUN}.
Every state move goes through ${HR}; nothing else writes run state.
If your output file already exists, do not redo the work - read it and report.`

const RULES = `HARD RULES (design\\PLAN-recipe-hunter-v2-2026-08-15.md and the recipe-hunter skill):
- Rule B: an ingredient is CARRIED if ONE of the seven Omaha stores has it. Rejection needs ZERO stores.
- Unchecked is NEVER not-carried. A bot wall or timeout leaves the term PENDING and the recipe PARKED.
- No stage mints a commodity id. New-commodity proposals go to the commodity-registrar agent; the run
  never edits commodity files; the ingredient maps item_id: null meanwhile (safe pantry-static pricing).
- Never run spec-guards.ps1 full mode against db\\recipes specs (plan section 0a.2, the \\uXXXX trap).
- db\\recipes is the only spec home; the run dir holds intake\\<slug>.json (plan section 0a.3).
- Never weaken a guard to get a recipe through.`

// ---------------------------------------------------------------------------------------------
// schemas
// ---------------------------------------------------------------------------------------------
const CANDS = { type: 'object', properties: { round: { type: 'number' }, candidates: { type: 'array', items: { type: 'object', properties: {
  name: { type: 'string' }, slug: { type: 'string' }, protein: { type: 'string' }, cuisine: { type: 'string' },
  source_url: { type: 'string' }, source_servings: { type: 'number' }, src_cal: { type: 'number' },
  src_carbs: { type: 'number' }, method: { type: 'string' },
  unmapped: { type: 'array', items: { type: 'string' } }, why: { type: 'string' },
}, required: ['name', 'slug', 'source_url', 'src_cal', 'src_carbs'] } } }, required: ['round', 'candidates'] }

const SEL = { type: 'object', properties: { selected: { type: 'array', items: { type: 'object', properties: {
  name: { type: 'string' }, slug: { type: 'string' }, source_url: { type: 'string' }, protein: { type: 'string' },
  src_cal: { type: 'number' }, src_carbs: { type: 'number' },
  unmapped: { type: 'array', items: { type: 'string' } },
}, required: ['name', 'slug', 'source_url'] } }, note: { type: 'string' } }, required: ['selected'] }

const STAGE = { type: 'object', properties: { slug: { type: 'string' }, status: { type: 'string' },
  state: { type: 'string' }, detail: { type: 'string' } }, required: ['slug', 'status', 'state'] }

const MAPPED = { type: 'object', properties: { results: { type: 'array', items: { type: 'object', properties: {
  slug: { type: 'string' }, status: { type: 'string', description: 'ok | rejected' },
  state: { type: 'string', description: 'mapped -> then pricing or priced' },
  absent_terms: { type: 'array', items: { type: 'string' }, description: 'blocking terms enqueued for the pricer' },
  optional_absent: { type: 'array', items: { type: 'string' } },
  registrar_rulings: { type: 'string' }, detail: { type: 'string' },
}, required: ['slug', 'status', 'state'] } } }, required: ['results'] }

const DERIVE = { type: 'object', properties: { resolved: { type: 'array', items: { type: 'object', properties: {
  slug: { type: 'string' }, state: { type: 'string' }, detail: { type: 'string' },
}, required: ['slug', 'state'] } }, still_pending_terms: { type: 'array', items: { type: 'string' } } },
  required: ['resolved'] }

const WRITE = { type: 'object', properties: { slug: { type: 'string' }, status: { type: 'string' }, state: { type: 'string' },
  cal_per_serving: { type: 'number' }, carbs_per_serving: { type: 'number' }, protein_per_serving: { type: 'number' },
  cost_per_serving: { type: 'number' }, detail: { type: 'string' } }, required: ['slug', 'status', 'state'] }

const QA = { type: 'object', properties: { slug: { type: 'string' }, verdict: { type: 'string' },
  owner: { type: 'string' }, findings: { type: 'string' } }, required: ['slug', 'verdict'] }

const WAVECLOSE = { type: 'object', properties: { wave: { type: 'number' },
  slugs: { type: 'array', items: { type: 'string' } }, batch: { type: 'string' } }, required: ['wave', 'slugs'] }

const AUDIT = { type: 'object', properties: { verdict: { type: 'string' },
  blocking_slugs: { type: 'array', items: { type: 'string' } }, blocker_kind: { type: 'string' },
  owner: { type: 'string' }, summary: { type: 'string' } }, required: ['verdict'] }

const REPAIRCHECK = { type: 'object', properties: {
  changed_count: { type: 'number', description: 'how many wave specs are NEWER than the audit file' },
  changed: { type: 'array', items: { type: 'string' } },
  untouched: { type: 'array', items: { type: 'string' } },
  detail: { type: 'string' } }, required: ['changed_count'] }

const PUB = { type: 'object', properties: { ok: { type: 'boolean' }, published: { type: 'array', items: { type: 'string' } },
  held: { type: 'array', items: { type: 'string' } }, collateral: { type: 'number' }, refusal: { type: 'string' } },
  required: ['ok'] }

// ---------------------------------------------------------------------------------------------
// WAVE lane (serial) - section 2.4
// ---------------------------------------------------------------------------------------------
const qaPassed = []
let waveChain = Promise.resolve()
let waveNo = 0
const waveResults = []

function maybeCloseWave(force) {
  if (!force && qaPassed.length < WAVE_SIZE) return
  if (force && qaPassed.length === 0) return
  const n = Math.min(WAVE_SIZE, qaPassed.length)
  qaPassed.splice(0, n)
  waveNo += 1
  const k = waveNo
  const drain = !!force
  waveChain = waveChain.then(() => runWave(k, drain)).catch(e => log(`wave ${k} threw: ${String(e).slice(0, 300)}`))
}

// -----------------------------------------------------------------------------------------------
// A4 / PLAN SECTION S8. A wave that cannot publish must NOT strand its recipes. On 2026-08-16 a
// double NO-GO left ten recipes sitting in `waved` - a state whose only exits are published,
// rejected-audit, qa-passed and written - and nothing ever picked them up again, because WaveClose
// only gathers `qa-passed`. Two of those ten were audit-clean and publishable, held hostage by eight
// that were not. Blocking slugs leave the wave; the clean remainder goes back in line for the next one.
// -----------------------------------------------------------------------------------------------
async function trimWave(wk, slugs, audit, batch, repairSpent) {
  const blockers = ((audit && audit.blocking_slugs) || []).filter(Boolean)
  const perSlug = {}
  slugs.forEach(s => { perSlug[s] = blockers.includes(s) ? 'BLOCK' : 'GO' })
  // If the auditor named nobody, every slug is blocked: a NO-GO that blames the wave as a whole is
  // not a licence to publish any of it.
  const allBlocked = blockers.length === 0
  const clean = allBlocked ? [] : slugs.filter(s => !blockers.includes(s))
  const blocked = allBlocked ? slugs.slice() : blockers.filter(s => slugs.includes(s))

  log(`WAVE ${wk}: trimming - ${blocked.length} blocked, ${clean.length} clean${allBlocked ? ' (auditor named no slugs, so the whole wave is blocked)' : ''}`)

  await agent(`${SHELL}
${laneLog("audit", `wave-${wk}:trim`, slugs)}
Wave ${wk} of run ${RUNID} could not publish. Trim it per plan section S8 so nothing strands in \`waved\`.

BLOCKED (${blocked.length}): ${blocked.join(', ') || '(none)'}
CLEAN   (${clean.length}): ${clean.join(', ') || '(none)'}

For each BLOCKED slug - it has ${repairSpent ? 'ALREADY had its one repair cycle, so it is terminal' : 'not yet been repaired'}:
${repairSpent
  ? `  ${HR} -Advance -RunDir ${RUN} -Slug <s> -To rejected-audit -By auditor -Detail '<the auditor's reason>'`
  : `  ${HR} -Advance -RunDir ${RUN} -Slug <s> -To qa-passed -By auditor -Detail 'trimmed out of wave ${wk} for repair'`}

For each CLEAN slug, return it to the pool so a later wave can carry it:
  ${HR} -Advance -RunDir ${RUN} -Slug <s> -To qa-passed -By auditor -Detail 'audit-clean, trimmed out of blocked wave ${wk}'

A clean recipe must NEVER be rejected for its neighbours' defects. Report what you advanced, per slug.`,
    { label: `wave-${wk}:trim`, phase: 'Wave' })

  // The clean ones rejoin the in-memory wave queue too, or they would sit in `qa-passed` on disk while
  // this process believes they are still waved and never closes another wave over them.
  clean.forEach(s => { if (!qaPassed.includes(s)) qaPassed.push(s) })
  log(`WAVE ${wk}: ${clean.length} clean recipe(s) returned to the pool for the next wave`)
}

async function runWave(k, drain) {
  // Publishing is the one lane that must never start on a dying run: a half-dispatched wave leaves the
  // ledger open and the audit stranded. If the breaker is open, the qa-passed recipes simply wait in
  // the run dir for the next resume, which is exactly what they are designed to do.
  if (halted()) { log(`WAVE ${k}: not starting - run halted; qa-passed recipes wait for the next resume`); return }
  const close = await agent(`${SHELL}
${laneLog("audit", `wave-${k}:close`, ["wave-close"])}
Close the next hunt wave.
  powershell -NoProfile -File ${HR} -WaveClose -RunDir ${RUN}${drain ? ' -Drain' : ''}
It writes waves\\wave-<k>.json and opens batch-ledger batch ${RUNID}-w<k>, stamping select, map, write and
build-specs as "streamed pre-wave". Read the wave json back; report the wave number, its exact slug list,
and the batch id. If it closed empty or refused, report wave 0 with an empty slug list.`,
    { label: `wave-${k}:close`, phase: 'Wave', schema: WAVECLOSE })

  if (!close || !close.slugs || close.slugs.length === 0) { log(`WAVE ${k}: nothing to close`); return }
  const slugs = close.slugs
  const wk = close.wave
  const batch = close.batch || `${RUNID}-w${wk}`
  log(`WAVE ${wk}: ${slugs.length} recipes - ${slugs.join(', ')}`)

  let audit = await agent(`${laneLog("audit", `wave-${wk}:audit`, slugs)}
Audit wave ${wk} of run ${RUNID} before it publishes.
Run dir: ${RUN}. Wave file: ${RUN}\\waves\\wave-${wk}.json. Slugs: ${slugs.join(', ')}.
scope: whole-wave  (first audit of this wave)

FIRST, before reading anything, run the mechanical battery and audit its residue (v3 S8 / Phase 0):
  powershell -NoProfile -File C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\wave-preaudit.ps1 -RunDir ${RUN} -Wave ${wk}
Report at ${RUN}\\waves\\wave-${wk}.preaudit.json. Exit 0 clean, 1 findings, 2 could-not-run - and exit 2
is a BLOCKED stage, never a pass. It does not audit and it cannot issue a GO; you remain the authority
and may re-derive anything in it.

This run's conditions: ${COND}. Verify each recipe's per-serving macros against that in addition to your
normal battery (macros vs labels, cost sanity, gates, mapping soundness, card fidelity).

Report to ${RUN}\\waves\\wave-${wk}.audit.md. FIRST line exactly GO or NO-GO. SECOND line exactly
"scope: whole-wave". On GO also run:
  powershell -NoProfile -File C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\batch-ledger.ps1 -Stamp -Batch ${batch} -Stage audit -Detail '<n>/<n> GO'
Report the verdict, blocking slugs, whether each blocker is recipe-local or shared-data, and the repair owner.`,
    { agentType: 'recipe-batch-auditor', label: `wave-${wk}:audit`, phase: 'Wave', schema: AUDIT })

  if (audit && !isGo(audit.verdict)) {
    const blockers = (audit.blocking_slugs || []).filter(Boolean)
    log(`WAVE ${wk}: NO-GO on ${blockers.join(', ') || 'the wave'} (${audit.blocker_kind}) - one repair cycle`)
    const owner = audit.owner === 'extractor' ? 'recipe-hunter-extractor'
      : audit.owner === 'mapper' ? 'recipe-ingredient-mapper' : 'recipe-writer'
    await agent(`${SHELL}
${RULES}
${laneLog("audit", `wave-${wk}:repair`, blockers)}
The batch auditor returned NO-GO on wave ${wk} of run ${RUNID}.
Read ${RUN}\\waves\\wave-${wk}.audit.md and repair EXACTLY what it blocks on.
Blocking slugs: ${blockers.join(', ') || '(whole wave)'}
Auditor summary: ${(audit.summary || '').slice(0, 1500)}

Repair through the sanctioned path: rebuild via
  pipeline\\build-v2-spec.ps1 -InFile ${RUN}\\intake\\<slug>.json -RunCost
Never hand-edit a spec. Do not weaken any gate. If a recipe cannot be repaired:
  ${HR} -Advance -RunDir ${RUN} -Slug <s> -To rejected-audit -By auditor -Detail '<why>'
Report exactly what you changed, per slug. If nothing needed changing, SAY SO explicitly - that is a
legitimate answer and is treated differently from claiming a change that did not happen.
List the files you changed, one per line, under a final line reading "CHANGED FILES:".`,
      { agentType: owner, label: `wave-${wk}:repair`, phase: 'Wave' })

    // ---------------------------------------------------------------------------------------------
    // A3 POSTCONDITION. On 2026-08-16 a repair agent reported success on wave 1 having changed
    // nothing at all - the specs and db\ingredients.json were untouched since before the first audit.
    // The ONLY thing that caught it was paying for a second full audit, the most expensive agent in
    // the flow. Verifying the claim costs one cheap shell call. "Nothing needed changing" is fine;
    // "I changed X" with X untouched is not, and must not buy a re-audit.
    // ---------------------------------------------------------------------------------------------
    const post = await agent(`${SHELL}
${laneLog("audit", `wave-${wk}:verify-repair`, slugs)}
Verify what the repair actually changed for wave ${wk}, before we pay for a re-audit.

For each wave slug, report the LastWriteTime of C:\\Codex\\ThriftyCrew\\meal-prep\\db\\recipes\\<slug>.json
and of C:\\Codex\\ThriftyCrew\\meal-prep\\db\\ingredients.json. Compare against the audit file's own
LastWriteTime (${RUN}\\waves\\wave-${wk}.audit.md).

Report: which specs are NEWER than the audit (genuinely repaired), and which are OLDER (untouched).
Report honestly - a repair that changed nothing is a finding, not something to smooth over. This exact
check is what exposed a false repair claim on 2026-08-16.`,
      { label: `wave-${wk}:verify-repair`, phase: 'Wave', schema: REPAIRCHECK })

    if (post && post.changed_count === 0) {
      log(`WAVE ${wk}: the repair changed NOTHING (${post.detail || 'no files newer than the audit'}) - not paying for a re-audit`)
      waveResults.push({ wave: wk, slugs, published: [], held: [], verdict: 'NO-GO', note: 'repair claim did not hold: no file changed' })
      await trimWave(wk, slugs, audit, batch, true)
      return
    }

    // B-4 SCOPE GATE. Recipe-local blockers re-audit only the repaired slugs; a shared-data fix moved
    // every recipe's numbers and REQUIRES the whole wave. Declaring the scope is mandatory - the
    // 2026-08-15 shakedown spent 31% of its tokens on three audits, one of which re-verified a whole
    // wave after a single prose field changed in a single spec.
    const scope = (audit.blocker_kind === 'shared-data' || blockers.length === 0) ? 'whole-wave' : blockers.join(',')
    const why = audit.blocker_kind === 'shared-data'
      ? 'the fix moved shared data (map entry / DB row / cost basis), so every recipe in the wave has new numbers'
      : 'the blocker was recipe-local, so nothing outside the repaired slugs moved'
    if (audit.blocker_kind === 'shared-data' && scope !== 'whole-wave') {
      throw new Error(`scope gate: a shared-data blocker may not re-audit narrowly (got '${scope}')`)
    }
    log(`WAVE ${wk}: re-audit scope: ${scope} (${audit.blocker_kind})`)
    audit = await agent(`${laneLog("audit", `wave-${wk}:reaudit`, slugs)}
Re-audit wave ${wk} of run ${RUNID} AFTER the repair.
Run dir: ${RUN}. Wave file: ${RUN}\\waves\\wave-${wk}.json.
scope: ${scope}
Reason: ${why}.

Re-verify only what that scope covers. Overwrite ${RUN}\\waves\\wave-${wk}.audit.md; FIRST line exactly
GO or NO-GO; SECOND line exactly "scope: ${scope}". The audit file must end up NEWER than every spec it
certifies (wave-publish P1b refuses a stale GO). On GO run:
  powershell -NoProfile -File C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\batch-ledger.ps1 -Stamp -Batch ${batch} -Stage audit -Detail '<n>/<n> GO'`,
      { agentType: 'recipe-batch-auditor', label: `wave-${wk}:reaudit`, phase: 'Wave', schema: AUDIT })
  }

  if (!audit || !isGo(audit.verdict)) {
    log(`WAVE ${wk}: still NO-GO after one repair cycle`)
    waveResults.push({ wave: wk, slugs, published: [], held: [], verdict: 'NO-GO' })
    await trimWave(wk, slugs, audit, batch, true)
    return
  }

  const pub = await agent(`${SHELL}
${laneLog("publish", `wave-${wk}:publish`, slugs)}
Publish wave ${wk} of run ${RUNID}. The audit reads GO and is stamped on batch ${batch}.
  powershell -NoProfile -File C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\wave-publish.ps1 -RunDir ${RUN} -Wave ${wk}

This is the ONLY sanctioned publish path. Do not call publish-recipe.ps1 or engine\\publish.ps1 directly
(plan section 0a.1: publish-recipe hardcodes visibility and would re-paywall every hand-freed free dinner).
Do not git add -A.

If a gate REFUSES, stop and report the refusal verbatim. Do not work around it, do not add anything to the
P8 allowlist, do not re-run with a weakened flag. A P8 provenance refusal means the cards point at an
endpoint this estate does not produce, and the correct response is to say so.

Capture: which slugs published, the collateral count it prints ("<n> wave slugs + <m> collateral carried by
propagate"), and any slug the E6/E7 serveability arm drafted and moved to held.`,
    { label: `wave-${wk}:publish`, phase: 'Wave', schema: PUB })

  if (!pub || !pub.ok) {
    log(`WAVE ${wk}: publish refused - ${((pub && pub.refusal) || '').slice(0, 200)}`)
    waveResults.push({ wave: wk, slugs, published: [], held: [], verdict: 'PUBLISH-REFUSED', refusal: pub && pub.refusal })
    return
  }

  const published = pub.published || []
  const held = pub.held || []
  log(`WAVE ${wk}: published ${published.length}, held ${held.length}, collateral ${pub.collateral || 0}`)

  const review = await agent(`${laneLog("review", `wave-${wk}:review`, published)}
Post-publish review of run ${RUNID} wave ${wk}, which just shipped.
WAVE SLUGS (${published.length}): ${published.join(', ')}
COLLATERAL carried by propagate: ${pub.collateral || 0} additional recipes republished in the same push.
Review BOTH numbers (plan section 4): propagate carries every dirty spec by design, so a review scoped to
the wave alone samples a fraction of what actually shipped.
${held.length ? `Serveability-held: ${held.join(', ')} - confirm these are DRAFTS, not live, and recorded held.` : ''}

Check live pages, pushed commits, data integrity and gates. Report bugs with fixes. Then:
  batch-ledger.ps1 -Stamp -Batch ${batch} -Stage post-publish-review -Detail '<verdict>'
  batch-ledger.ps1 -Close -Batch ${batch}
(both under C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\)
Then for each verified slug: ${HR} -Advance -RunDir ${RUN} -Slug <s> -To verified -By post-publish-reviewer`,
    { agentType: 'post-publish-reviewer', label: `wave-${wk}:review`, phase: 'Wave' })

  waveResults.push({ wave: wk, slugs, published, held, verdict: 'GO',
    collateral: pub.collateral || 0, review: String(review || '').slice(0, 2000) })
}

// ---------------------------------------------------------------------------------------------
// EXTRACT lane - cap 3 (section 2.4)
// ---------------------------------------------------------------------------------------------
async function extractLane() {
  await pool(CAP.extract, async () => {
    for (;;) {
      const c = await extractCh.take()
      if (c === null) return
      if (halted()) return
      const r = await withRetry(() => agent(`${SHELL}
${laneLog('extract', c.slug, [c.slug])}
Transcribe ONE sourced recipe. Slug: ${c.slug}. Source: ${c.source_url}

FETCH FROM CACHE - the sourcer already fetched this page:
  powershell -NoProfile -File ${PIPE}\\fetch-recipe.ps1 -Url '${c.source_url || '<source_url from the candidate file>'}'
It serves the cached body (no network, no second fetch of a page we already paid for) and returns the
page's own schema.org JSON-LD Recipe block when present. Two recipes died on 404s in the 2026-08-16 run
AFTER a sourcer had already read them successfully; the cache is why that cannot happen again.

TRANSCRIBING FROM JSON-LD IS STILL TRANSCRIBING THE PAGE - it is the page's own machine-readable
statement of its recipe, and it is more reliable than prose-reading a rendered blog. What remains
forbidden is transcribing from the SOURCER'S DESCRIPTION of a page. If the JSON-LD and the visible page
disagree, that is a finding to report, not a preference to exercise.
Write ${RUN}\\extracted\\${c.slug}.json: ingredients exactly as the page states them (measurement, unit and
name verbatim), stated servings, stated nutrition if any, and the cooking steps. Mark garnish/optional
lines optional - an optional line never blocks and never rejects a recipe.

TRANSCRIPTION ONLY. Do not convert units. Do not estimate a missing measurement. Do not reconstruct a page
you could not read - state: "unreadable" is a complete and correct answer. An invented recipe is the worst
outcome in this flow because nothing downstream can catch it.

Then: ${HR} -Advance -RunDir ${RUN} -Slug ${c.slug} -To extracted -By extractor
or:   ${HR} -Advance -RunDir ${RUN} -Slug ${c.slug} -To rejected-unreadable -By extractor -Detail '<why>'`,
        { agentType: 'recipe-hunter-extractor', label: `extract:${c.slug}`, phase: 'Extract', schema: STAGE }), c.slug, 'extract')

      if (r === null) {
        stuck(c.slug, 'extract', `no response after ${MAX_STAGE_RETRIES + 1} attempts - never actually extracted, hunt-run state is untouched`)
      } else if (isRejected(r.status)) {
        finish(c.slug, 'rejected', r.state || 'rejected-unreadable', r.detail || 'extractor rejected')
      } else {
        mapCh.push(record(c.slug, { ...c, state: 'extracted' }))
      }
    }
  })
  mapCh.close()
}

// ---------------------------------------------------------------------------------------------
// MAP lane - cap 2, micro-batches of up to 5 recipes (section S4)
// The mapper also runs the cheap board question and enqueues absent terms BEFORE advancing to
// `pricing`, so a recipe in `pricing` always has its full term set on the queue (section 2.2).
// ---------------------------------------------------------------------------------------------
async function mapLane() {
  await pool(CAP.map, async () => {
    for (;;) {
      const batch = await mapCh.takeBatch(MAP_BATCH)
      if (batch === null) return
      if (halted()) return
      const slugs = batch.map(b => b.slug)
      log(`map: micro-batch of ${slugs.length} (${slugs.join(', ')})`)

      const r = await withRetry(() => agent(`${SHELL}
${RULES}
${laneLog('map', `micro-batch of ${slugs.length}`, slugs)}
Map this MICRO-BATCH of ${slugs.length} recipes (plan section S4 batches up to 5 per invocation).
Slugs: ${slugs.join(', ')}
Transcriptions: ${RUN}\\extracted\\<slug>.json      Write: ${RUN}\\mapped\\<slug>.json

For EACH recipe:
0. RESOLVE EVERY INGREDIENT NAME AGAINST THE VOCABULARY FIRST. This is the single most expensive
   mistake this pipeline has made. db\\ingredients.json is a CLOSED vocabulary of ~301 canon names.
   build-v2-spec matches them EXACTLY, so an invented name silently costs $0.00 and the recipe ships a
   price that excludes it. On 2026-08-16 recipes wrote "Cream Cheese", "Sour Cream", "Broccoli" and
   "Portobello Mushrooms" while the vocabulary stocked "1/3 Fat Cream Cheese", "Light Sour Cream",
   "Broccoli Florets" and "White Mushrooms" - four live pages went out understating cost and a whole
   run's worth of recipes was blocked chasing prices that were never missing.

   For EVERY ingredient:
     powershell -NoProfile -File ${PIPE}\\ingredient-vocab.ps1 -Query '<ingredient name>'
   Exit 0 = it resolves; use that EXACT canon name in the intake. Exit 3 = it does not, and the nearest
   rows are printed with a DIFFERENT-FORM flag where the near name is a different food.

   NEVER invent a canon name and NEVER pick a near match yourself. If nothing resolves, report it as a
   vocabulary proposal - rename, alias, or new row - and hold the recipe rather than guessing. "Dry
   White Wine" is not "White Wine Vinegar"; "Fresh Parsley" is not "Dried Parsley"; "Broccoli Florets"
   is frozen, which its name hides and only its bid reveals. A plausible wrong match is worse than a
   visible miss, because nothing downstream ever fires again.

   ${PIPE}\\ingredient-resolutions.ps1 -Query -Term '<t>' carries prior rulings, including whether a bid
   is wired. A recipe whose ingredient resolves but has NO bid must HOLD at mapped - do not let it reach
   the writer, because the spec build will refuse and the writing will have been paid for already.

1. Map every ingredient to a canonical board commodity id, or reject it with evidence. Add label-accurate
   food-DB entries for anything new. This run's recipes must land between ${CAL_MIN} and ${CAL_MAX} cal
   and at or under ${CARB_MAX} g carbs per serving, so a guessed macro here becomes a false claim on a
   published card - and with a calorie CEILING as well as a floor, an inflated row fails the gate just as
   surely as a deflated one.
2. Mark each ingredient blocking or optional.
3. Ask the CHEAP pricing question for every term:
     powershell -NoProfile -File C:\\Codex\\ThriftyCrew\\grocery\\price-ingredient.ps1 <term>
   It answers from the board and today's captures in milliseconds and reads BOTH boards - the weekly
   comparison-*.json AND recipe-board.json. Reading only the weekly one makes pork-loin and
   boneless-skinless-chicken-thigh look like zero coverage and falsely rejects good recipes.
4. Terms the board CANNOT answer get enqueued BEFORE the state moves (section 2.2 - a recipe in 'pricing'
   must already carry its full term set on the queue):
     powershell -NoProfile -File ${IQ} -Add -Term '<term>' -Recipe '<slug>' -Why '<recipe needs it for X>'
   The queue is keyed by TERM and dedupes across recipes - if two recipes in this batch need the same
   term, add it once per recipe (the queue attaches both slugs to the one item). Never enqueue an
   optional line as blocking.
5. Advance:
     ${HR} -Advance -RunDir ${RUN} -Slug <s> -To mapped -By mapper
   then ALWAYS through pricing, whether or not you found anything blocking (NOTE THE QUOTING below -
   this is not a style preference). With blocking terms:
     ${HR} -Advance -RunDir ${RUN} -Slug <s> -To pricing -By mapper -Terms 'term one','term two' -OptionalTerms 'garnish one'
   with none:
     ${HR} -Advance -RunDir ${RUN} -Slug <s> -To pricing -By mapper

   NEVER -To priced FROM mapped. As of 2026-08-26 (Q2) the state machine REFUSES that transition and
   the advance will exit 1. It used to be the shortcut for "every term answered from disk", and it was
   a hole: -To pricing is where hunt-run runs the CARRIAGE UNION, deriving blocking ingredients from
   the mapped bids themselves. An ingredient can map perfectly to a real commodity id and still be a
   food no Omaha store stocks - doubanjiang, rice-cakes and ground-sumac all did - so "every term
   answered from disk" is your account of the recipe, not a carriage verdict, and going straight to
   priced on it is how an unbuyable recipe reaches a paid page. Advance to pricing and let the union
   read it; if nothing blocks, hunt-run -Derive moves it to priced on its own.

   PASS EACH TERM AS ITS OWN QUOTED STRING, comma-SEPARATED, never as one comma-joined string.
   PowerShell binds -Terms 'a,b' to a [string[]] of ONE element, the literal "a,b" - not two terms. That
   composite string can never match a queue entry, so -Derive scores it PENDING forever and the recipe
   parks permanently and silently. This bit two recipes in this very run on 2026-08-16
   (philly-cheesesteak-stuffed-peppers sat parked while BOTH its ingredients were already CARRIED).
   Correct:   -Terms 'green bell pepper','shaved beef steak'
   BROKEN:    -Terms 'green bell pepper,shaved beef steak'
   A single term needs no comma at all: -Terms 'bacon bits'

Do NOT open a store, do NOT probe, do NOT rule on carriage - that is the pricer lane's job.
Any new-commodity proposal goes to the commodity-registrar agent first; record its ruling in the mapped file.
Report one result per slug, including the exact absent terms you enqueued.`,
        { agentType: 'recipe-ingredient-mapper', label: `map:${slugs.length}x`, phase: 'Map', schema: MAPPED }), slugs, 'map')

      if (r === null) {
        if (circuitOpen) {
          // The breaker is open - do NOT requeue, or the items bounce around a closed pipeline.
          batch.forEach(b => stuck(b.slug, 'map', 'run halted by circuit breaker before mapping - resumable'))
          return
        }
        // The batch call failed after retries but the run is otherwise healthy. Requeue individually;
        // retries are accounted per slug now, so this cannot mint a fresh budget by regrouping.
        log(`map: batch of ${slugs.length} got no response after retries - requeuing items individually`)
        batch.forEach(b => mapCh.push(b))
        continue
      }

      const results = r.results || []
      for (const b of batch) {
        const res = results.find(x => x && x.slug === b.slug)
        if (!res) {
          // The batch call succeeded but did not report on this slug - still not a verdict. Give it its
          // own retry budget rather than treat "the mapper didn't get to it" as "the mapper rejected it".
          const key = `map:${b.slug}`
          const n = (retryCounts.get(key) || 0) + 1
          retryCounts.set(key, n)
          if (n > MAX_STAGE_RETRIES) {
            stuck(b.slug, 'map', `mapper never reported on this slug after ${n} batch attempts`)
          } else {
            log(`map: ${b.slug} absent from a reported batch, retry ${n}/${MAX_STAGE_RETRIES}`)
            mapCh.push(b)
          }
          continue
        }
        if (isRejected(res.status)) {
          finish(b.slug, 'rejected', res.state || 'rejected-not-carried', res.detail || 'mapper rejected')
          continue
        }
        const absent = (res.absent_terms || []).filter(Boolean)
        record(b.slug, { ...b, registrar: res.registrar_rulings })
        if (absent.length === 0 && normState(res.state) === 'priced') {
          writeCh.push(record(b.slug, { state: 'priced' }))
        } else {
          absent.forEach(t => absentTerms.add(t))
          pricingSlugs.add(b.slug)
          record(b.slug, { state: 'pricing', absent })
          priceWake.push(b.slug)
        }
      }
    }
  })
  priceWake.close()   // no further terms can arrive; the price lane drains what is left and closes
}

// ---------------------------------------------------------------------------------------------
// PRICE lane - SINGLETON, self-looping queue drainer (section 2.4)
// "snapshot pending terms -> spawn pricer -> record -> repeat until the queue drains and no recipe
//  upstream can add more". Batches up to 10 terms ACROSS recipes.
// ---------------------------------------------------------------------------------------------
let priceInvocations = 0
async function priceLane() {
  for (;;) {
    const woke = await priceWake.take()
    if (woke === null && absentTerms.size === 0) break
    if (halted()) break
    // GREEDY EXHAUSTIVE SERVICE - which is what plan section 2.4's own loop says: "snapshot pending
    // terms -> spawn pricer -> record -> repeat". The lane takes whatever is pending the moment it is
    // free, up to 10 per invocation, and never waits for a full batch. Under load this converges to full
    // batches on its own, because terms keep arriving during the minutes each invocation takes; when
    // arrivals are sparse it prices a lone term immediately instead of holding its recipe hostage to a
    // batch preference. Wall-safety lives in the SINGLETON - never two pricers, never N tabs per store
    // domain - not in refusing to run a small batch. (A wait-for-full-batch policy here also created a
    // real deadlock against the hunt lane's WIP limit, which greedy service structurally removes.)
    while (absentTerms.size > 0) {
      if (halted()) break
      const terms = Array.from(absentTerms).slice(0, PRICE_BATCH)
      terms.forEach(t => absentTerms.delete(t))
      priceInvocations += 1
      const n = priceInvocations
      log(`price lane [singleton] invocation ${n}: ${terms.length} term(s) across ${pricingSlugs.size} recipe(s)`)

      await agent(`${SHELL}
${RULES}
${laneLog('price', `queue batch ${n}`, terms)}
Price this batch of terms the board has never carried. These come from SEVERAL recipes at once - the
ingredient queue is keyed by term and dedupes across recipes, which is exactly why this lane batches.

TERMS (${terms.length}): ${terms.join(', ')}

You are the ONLY pricer alive right now, by design (plan section 2.4). Open your proven-safe shape: the
2 server stores plus ONE tab per browser store, in-store mode verified per store, one search per term.
N concurrent pricers means N tabs per store domain, which is the sweep shape that walled Walmart at 55 of
526 terms and Sam's at 205. Throughput comes from batching terms inside THIS invocation, never from more
pricers.

A candidate row is not a price. probe-ingredient.ps1 gathers; YOU adjudicate. Probing "saffron" at Baker's
ranks "Saffron Road Drunken Noodles" above the actual jar because the brand name contains the word.

Record every verdict with evidence, per term per store:
  powershell -NoProfile -File ${IQ} -Record -Term '<t>' -Store '<store>' -State carried|not-carried|blocked|error -Price <p> -Size '<size>' -Item '<exact item name>' -Evidence '<what you saw>'
A store you could not reach is blocked/error, which reads as PENDING - never as not-carried. A carried
claim without a price is refused by the script, correctly: a carriage claim with no price is not evidence.
Do not write board cells.

Report the resulting verdict for each term (CARRIED / NOT-CARRIED / PENDING) and, for any PENDING, exactly
which stores are still unchecked and why.`,
        { agentType: 'recipe-hunter-pricer', label: `price:batch-${n}`, phase: 'Price' })

      // section 2.2: derived counts are the ONLY thing that moves a recipe out of pricing/parked
      const d = await agent(`${SHELL}
${laneLog("price", `derive-after-batch-${n}`, terms)}
Recompute derived pricing state from ground truth and report what moved.
  powershell -NoProfile -File ${HR} -Derive -RunDir ${RUN}
Then for each of these recipes read ${RUN}\\state\\<slug>.json and report its CURRENT state:
  ${Array.from(pricingSlugs).join(', ')}
Also report which queue terms are still PENDING:
  powershell -NoProfile -File ${IQ} -List -Status pending

Report honestly: priced, parked or rejected-not-carried per slug. Never round a PENDING up into priced or
down into rejected.`,
        { label: `derive:after-batch-${n}`, phase: 'Price', schema: DERIVE })

      for (const rr of (d && d.resolved) || []) {
        if (!rr || !pricingSlugs.has(rr.slug)) continue
        if (normState(rr.state) === 'priced') {
          pricingSlugs.delete(rr.slug)
          writeCh.push(record(rr.slug, { state: 'priced' }))
        } else if (normState(rr.state) === 'rejected-not-carried') {
          pricingSlugs.delete(rr.slug)
          finish(rr.slug, 'rejected', 'rejected-not-carried', rr.detail || 'no Omaha store carries a blocking ingredient')
        }
        // parked: stays in pricingSlugs; a later batch may resolve it
      }
    }
    if (woke === null) break
  }
  // anything still parked when the lane closes is a parked outcome, never a rejection
  for (const slug of pricingSlugs) {
    finish(slug, 'parked', 'parked', 'blocking ingredient still PENDING - see ingredient-queue for unchecked stores')
  }
  writeCh.close()
}

// ---------------------------------------------------------------------------------------------
// WRITE lane - cap 3 (section 2.4) + the macro gate for this run's conditions
// ---------------------------------------------------------------------------------------------
async function writeLane() {
  await pool(CAP.write, async () => {
    for (;;) {
      const c = await writeCh.take()
      if (c === null) return
      if (halted()) return
      const r = await withRetry(() => agent(`${SHELL}
${RULES}
${laneLog('write', c.slug, [c.slug])}
Write recipe ${c.slug} in Brad's voice and build its spec.
Inputs: ${RUN}\\extracted\\${c.slug}.json (the transcription - the recipe of record)
        ${RUN}\\mapped\\${c.slug}.json (commodity ids, food-DB rows)

Produce ONE intake JSON at ${RUN}\\intake\\${c.slug}.json, then assemble the spec:
  powershell -NoProfile -File C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\build-v2-spec.ps1 -InFile ${RUN}\\intake\\${c.slug}.json -RunCost
build-v2-spec's write-time guards are the v2 enforcers; spec-guards.ps1 full mode is forbidden here.

Voice rails: Brad's Morgan-Freeman-meets-Dave-Ramsey tone, no em dashes. Fit the EXISTING framework and the
existing card generators. Scale to 14 servings.

THIS RUN'S CONDITIONS: ${COND}
Report the computed PER-SERVING calories, carbs, protein and cost from the BUILT spec. Report the real
numbers. Do not adjust a recipe to hit the target and do not round toward it.

Then: ${HR} -Advance -RunDir ${RUN} -Slug ${c.slug} -To spec-built -By writer
      ${HR} -Advance -RunDir ${RUN} -Slug ${c.slug} -To written -By writer`,
        { agentType: 'recipe-writer', label: `write:${c.slug}`, phase: 'Write', schema: WRITE }), c.slug, 'write')

      if (r === null) { stuck(c.slug, 'write', `no response after ${MAX_STAGE_RETRIES + 1} attempts - never actually written`); continue }
      if (isRejected(r.status)) { finish(c.slug, 'rejected', 'rejected-qa', r.detail || 'writer rejected'); continue }

      const cal = r.cal_per_serving, carb = r.carbs_per_serving
      record(c.slug, { cal, carbs: carb, protein: r.protein_per_serving, cost: r.cost_per_serving })
      if (typeof cal === 'number' && typeof carb === 'number'
          && (cal < CAL_MIN || cal > CAL_MAX || carb > CARB_MAX)) {
        log(`macro gate: ${c.slug} built at ${cal} cal / ${carb}g carbs - outside ${CAL_MIN}-${CAL_MAX} cal / <=${CARB_MAX}g, retiring`)
        await agent(`${SHELL}
${laneLog("write", `macro-reject:${c.slug}`, [c.slug])}
Recipe ${c.slug} built at ${cal} cal and ${carb} g carbs per serving, missing this run's conditions
(${COND}). Retire it - do not adjust the recipe to make the numbers fit:
  ${HR} -Advance -RunDir ${RUN} -Slug ${c.slug} -To rejected-qa -By macro-gate -Detail 'macro gate: ${cal} cal / ${carb}g carbs per serving'`,
          { label: `macro-reject:${c.slug}`, phase: 'Write' })
        finish(c.slug, 'rejected', 'rejected-qa', `macro gate: ${cal} cal / ${carb}g carbs`)
        continue
      }
      qaCh.push(record(c.slug, { state: 'written' }))
    }
  })
  qaCh.close()
}

// ---------------------------------------------------------------------------------------------
// QA lane - cap 2 (section 2.4), one owner-routed repair cycle (section S7)
// ---------------------------------------------------------------------------------------------
async function qaLane() {
  await pool(CAP.qa, async () => {
    for (;;) {
      const c = await qaCh.take()
      if (c === null) return
      if (halted()) return
      // Log EVERY attempt, not just the first. Suppressing the retry's laneLog was hiding the
      // most expensive QA calls in the run - a retry re-reads the whole spec and the whole
      // transcription, so attempt 2 costs more than attempt 1, and it was landing under
      // `unattributed`. The attempt number rides in the label so the pairing stays unique.
      const p = (attempt) => `${laneLog('qa', attempt === 1 ? c.slug : `${c.slug}:attempt${attempt}`, [c.slug])}
Fidelity check on ONE built recipe: ${c.slug}.
Built spec: C:\\Codex\\ThriftyCrew\\meal-prep\\db\\recipes\\${c.slug}.json
Transcription it came from: ${RUN}\\extracted\\${c.slug}.json
Live source page: ${c.source_url || `(not passed to you - read the source_url out of ${RUN}\\extracted\\${c.slug}.json, which records the page this recipe was transcribed from)`}
${attempt > 1 ? 'This is the RE-QA after one owner-routed repair cycle. A second FAIL is terminal (rejected-qa).' : ''}

FIRST, before reading anything, run the mechanical battery and judge its residue (v3 S7 / Phase 0):
  C:\\Codex\\Python312\\python.exe C:\\Codex\\ThriftyCrew\\meal-prep\\pipeline\\coverage_check.py --battery --spec C:\\Codex\\ThriftyCrew\\meal-prep\\db\\recipes\\${c.slug}.json --source ${RUN}\\extracted\\${c.slug}.json --run-dir ${RUN}
Report at ${RUN}\\qa\\${c.slug}.battery.json. Exit 0 clean, 1 findings, 2 could-not-run - and exit 2 is a
BLOCKED stage, never a pass. It settles coverage, the scaling ratio, prose numbers, credit/URL, the dash
sweep and the servings claim with numbers; its findings are questions for you, not verdicts.

Anchor on the transcription always; read the live page too when the domain is fetchable. A BLOCKED DOMAIN
IS NEVER A FINDING AGAINST THE RECIPE - it makes the transcription the sole anchor and the verdict says so.
Catch invented, dropped and drifted ingredients and steps.
Verdict JSON to ${RUN}\\qa\\${c.slug}.json. Verdict only - never edit, re-extract or price.
On PASS: ${HR} -Advance -RunDir ${RUN} -Slug ${c.slug} -To qa-passed -By source-qa
Report PASS or FAIL, and on FAIL the owner (writer for prose/card, extractor for transcription, mapper for mapping).`

      // Two DISTINCT retry budgets, keyed qa1/qa2, so an infra failure on either attempt never gets
      // confused with an explicit FAIL - and critically, an infra failure on attempt 1 must not be
      // allowed to fall through and consume the recipe's one legitimate repair cycle (the bug here
      // before this fix: `q && q.verdict !== 'PASS'` treats q===null as "skip the FAIL branch", which
      // then landed on `if (!q)` and rejected the recipe as QA-failed WITHOUT EVER RETRYING - zero
      // retries were attempted for a QA call that simply never ran).
      let q = await withRetry(() => agent(p(1), { agentType: 'recipe-source-qa', label: `qa:${c.slug}`, phase: 'QA', schema: QA }), c.slug, 'qa1')
      if (q === null) { stuck(c.slug, 'qa', `initial QA got no response after ${MAX_STAGE_RETRIES + 1} attempts - no verdict was ever rendered`); continue }

      if (!isPass(q.verdict)) {
        const owner = q.owner === 'extractor' ? 'recipe-hunter-extractor'
          : q.owner === 'mapper' ? 'recipe-ingredient-mapper' : 'recipe-writer'
        log(`QA FAIL ${c.slug} -> one repair cycle by ${owner}`)
        await agent(`${SHELL}
${RULES}
${laneLog("qa", `repair:${c.slug}`, [c.slug])}
Source-QA failed recipe ${c.slug} and routed the repair to you. This is the ONE repair cycle it gets; a
second failure is terminal, so fix the actual finding rather than papering over it.
Findings: ${(q.findings || '').slice(0, 2000)}
QA file: ${RUN}\\qa\\${c.slug}.json
Rebuild through build-v2-spec.ps1 -InFile ${RUN}\\intake\\${c.slug}.json -RunCost if the spec changes.
Never hand-edit a spec. Report what you changed.`,
          { agentType: owner, label: `repair:${c.slug}`, phase: 'QA' })

        q = await withRetry(() => agent(p(2), { agentType: 'recipe-source-qa', label: `re-qa:${c.slug}`, phase: 'QA', schema: QA }), c.slug, 'qa2')
        if (q === null) { stuck(c.slug, 'qa', `re-QA after repair got no response after ${MAX_STAGE_RETRIES + 1} attempts - the repair cycle was spent but no verdict was ever rendered`); continue }

        if (!isPass(q.verdict)) {
          await agent(`${SHELL}
${laneLog("qa", `qa-reject:${c.slug}`, [c.slug])}
Recipe ${c.slug} failed source-QA twice - terminal per plan section S7:
  ${HR} -Advance -RunDir ${RUN} -Slug ${c.slug} -To rejected-qa -By source-qa -Detail 'failed QA twice: ${((q.findings || 'see qa file')).slice(0, 150)}'`,
            { label: `qa-reject:${c.slug}`, phase: 'QA' })
          finish(c.slug, 'rejected', 'rejected-qa', 'failed source-QA twice')
          continue
        }
      }

      finish(c.slug, 'qa-passed', 'qa-passed', '')
      qaPassed.push(c.slug)
      maybeCloseWave(false)
    }
  })
}

// ---------------------------------------------------------------------------------------------
// HUNT / ADJUDICATE / DECIDE - three CONTINUOUS lanes with NO barrier between them.
//
// Brad's pipeline chart: every agent is a continuous consumer on a queue, and none of them ever
// pauses. The previous build ran hunt -> adjudicate -> decide as three awaited barriers per round,
// so hunting stopped dead while deduping ran, and deduping sat idle while hunting ran. These three
// lanes now run at the same time: the sourcers keep hunting while the adjudicators rule the pool
// they just produced and the decider selects out of the pool before that.
//
// DEVIATIONS FROM PLAN section 2.4, at Brad's direction 2026-08-15 (see success-criteria.md):
//   - HUNT runs 12 concurrent sourcers on disjoint protein-x-method lanes, not 1 at a time.
//   - Dedup is split in two: 8 concurrent ADJUDICATORS shard the expensive catalog comparison, and
//     ONE serial DECIDER does the part that cannot shard - cross-lane duplicates, the final pick,
//     and the single write to accepted-slugs.json. Streaming the decider actually strengthens
//     cross-lane dedup: it checks every arriving pick against everything accepted so far.
// ---------------------------------------------------------------------------------------------
const acceptedSlugs = []
let targetReached = false

// WIP LIMIT. The harness allows 16 concurrent agents for the entire run, and this script defines 32
// workers. Backpressure on the candidate queue alone does NOT protect the back half: the adjudicators
// drain that queue fast, so its depth stays low, so 12 sourcers would keep hunting and keep holding ~12
// of the 16 slots - while extract, map, the singleton pricer, write, qa and publishing fight over the
// remaining 4. Hunting is the one lane that can always find more work to do, so it is the one that has
// to yield. Gate it on recipes accepted but not yet resolved, which is the actual measure of how much
// unfinished work is already in the building.
const MAX_WIP = 25
function wip() { return acceptedSlugs.length - outcomes.length }

const wipWaiters = []
function notifyWip() { wipWaiters.splice(0).forEach(w => w()) }
async function waitForWip() {
  // The circuitOpen check is load-bearing, not defensive. Once the breaker trips, no recipe can
  // resolve, so wip() can never fall - a sourcer parked here would be woken by tripCircuit, re-test
  // the condition, and park again forever, and huntLane would never return, and Promise.all over the
  // lanes would never settle. The run would hang instead of exiting cleanly.
  while (wip() >= MAX_WIP && !targetReached && !circuitOpen) {
    await new Promise(r => wipWaiters.push(r))
  }
}

// 12 lanes, disjoint on (protein x method). Disjointness is what lets them hunt concurrently without
// re-finding each other's dishes - two workers on "chicken" would collide constantly; chicken-braise and
// chicken-skillet do not. 147 chicken / 138 beef / 141 turkey / 118 pork recipes are already live, so
// every lane is digging in an already-crowded catalog and needs to push into its corners.
const LANES = [
  { key: 'chicken-braise', brief: 'CHICKEN, braised or stewed only - regional braises, curries, cacciatore-style, cream braises. No skillet sautes, no oven casseroles; other workers own those.' },
  { key: 'chicken-skillet', brief: 'CHICKEN, skillet and pan only - one-pan sautes, fajita-style, creamy pan sauces, stir-fry style without a rice base. No braises, no casseroles.' },
  { key: 'chicken-bake', brief: 'CHICKEN, oven only - casseroles bound with cheese and eggs rather than pasta, sheet-pan dinners, baked smothered dishes. No stovetop-only dishes.' },
  { key: 'beef-slow', brief: 'BEEF, slow-cooker and braise only - pot roast style, barbacoa, short rib, chuck braises. No ground beef skillets, no steak.' },
  { key: 'beef-skillet', brief: 'GROUND BEEF and skillet beef only - taco and burrito bowls without the rice, cheeseburger skillets, stir-fry style beef. No slow-cooker, no roasts.' },
  { key: 'beef-roast', brief: 'BEEF roasts and steak only - tri-tip, sirloin, flank, meatloaf-style bakes. No ground beef skillets, no slow-cooker braises.' },
  { key: 'pork-chop', brief: 'PORK chops and tenderloin only - pan-seared, smothered, baked. The pork lane is the thinnest in the catalog at 118, so dig hard. No sausage, no shoulder.' },
  { key: 'pork-sausage', brief: 'SAUSAGE-forward and bacon-forward dishes only - sausage and vegetable bakes, sausage skillets, kielbasa dishes. No chops, no shoulder.' },
  { key: 'pork-shoulder', brief: 'PORK shoulder, butt and carnitas-style only - slow-cooked, shredded, braised. No chops, no sausage.' },
  { key: 'turkey-skillet', brief: 'GROUND TURKEY, skillet only - turkey taco bowls, turkey and vegetable skillets, turkey meatballs cooked on the stovetop. No bakes.' },
  { key: 'turkey-bake', brief: 'TURKEY, oven only - turkey casseroles, turkey meatloaf, baked turkey meatballs. No skillet dishes.' },
  { key: 'egg-cheese', brief: 'EGG-AND-CHEESE-BOUND bakes where the dish identity is the bake rather than the meat - crustless quiches, frittata bakes, cheese-bound casseroles. Any meat may appear as a component, but the dish must be identified by its egg/cheese structure, not by the protein.' },
]

// ---- HUNT lane: 12 sourcers, each looping its own protein-x-method slice, never waiting on dedup ----
async function huntLane() {
  if (DRAIN_ONLY) {
    log('DRAIN MODE: hunt lane disabled - sourcing nothing new')
    candCh.close()
    return
  }
  phase('Hunt')
  await Promise.all(LANES.map(async L => {
    let round = 0
    while (!targetReached && round < MAX_ROUNDS) {
      // Backpressure: if the adjudicators are already carrying a deep backlog, this sourcer stands down
      // rather than hunting more nobody can process yet. That returns its concurrency slot to the lanes
      // downstream, which is the only thing keeping 20 front-end workers from starving publishing.
      await candCh.waitForSpace(HUNT_BACKPRESSURE)   // dedup lane saturated
      await waitForWip()                             // back half of the pipeline saturated
      if (targetReached) break
      if (halted()) break
      round += 1
      const r = round
      const res = await agent(`${laneLog('hunt', `${L.key} round ${r}`, [L.key])}
Source budget high-protein meal-prep DINNER candidates for the Thrifty Crew catalog.
Round ${r}. YOUR LANE: ${L.key}. ${L.brief}
Stay inside your lane - three other sourcers are working the other proteins right now, and the dedup
adjudicators are ruling your PREVIOUS round's pool while you hunt this one. Nothing waits on you and you
wait on nothing.

CONDITIONS: ${COND}
This is a BAND, with a ceiling as well as a floor: ${CAL_MIN}-${CAL_MAX} calories per serving and no more
than ${CARB_MAX} g carbs. Only return a candidate whose PUBLISHED nutrition clears that on the source page's
own numbers, and aim for the MIDDLE of the band (roughly 450-600 cal, 30 g carbs or less), because our
computed macros from label-accurate food-DB rows will not land exactly on the source's and a candidate
sitting at 645 cal will fail our own gate as easily as one at 655. A candidate with no published nutrition
is acceptable ONLY if the dish is structurally low-carb and moderate-calorie (meat + fat + non-starchy
vegetables, no rice/pasta/potato/bread/bean base) - say so explicitly in "why".

KNOW WHICH LANES ARE ALREADY FULL before you hunt:
  powershell -NoProfile -File ${PIPE}\\make-saturation.ps1 -Brief
It lists the (protein x sauce-family) regions the catalog has already filled. You MAY bring a dish from
a saturated region - but you must name the axis that makes it distinct, in "why". This is guidance to
argue with, not a filter. It exists because the 2026-08-15 run found, fetched and adjudicated FIVE
creamy pork-chop skillets and FOUR creamy chicken skillets before rejecting them all as duplicates -
48% of that run's recipes died as dupes, after being paid for.

PRICER-LANE EXERCISE (design\\PLAN-recipe-hunter-v2.1-2026-08-15.md section 5.1): this is the proving run for
the pricer lane, and the shakedown's bias was to AVOID candidates with unmapped ingredients. Invert that. Do
NOT filter out a good recipe because a signature ingredient may be absent from the board - flag it in
"unmapped" and let the selector decide. A few genuinely-absent ingredients in this batch are a FEATURE: they
are what proves the queue and the pricer lane work in anger.

Still required: scalable to 14 servings, no seafood.

DEDUPE BY QUERYING, NOT BY LOADING. Do NOT read catalog-digest.json - it is 111,942 bytes and the hunt
and select lanes together burned 75.5% of the last run's tokens largely on repeated context. Instead:

  powershell -NoProfile -File ${PIPE}\\find-similar.ps1 -Name '<dish name>' -Protein ${L.key.split('-')[0]}
      -> the ~5 nearest catalog recipes, about 1KB, with the words they share

  powershell -NoProfile -File ${PIPE}\\considered-dishes.ps1 -Query -Name '<dish>' -Protein <p> -Method <m>
      -> has this estate ALREADY ruled on this dish? Exit 3 means yes, with the reason. ADVISORY: you may
         still bring it, but say in "why" what makes it distinct from the prior ruling.

  ${RUN}\\accepted-slugs.json - still read this; the decider appends to it continuously.

CHECK THE PUBLISHER BEFORE YOU FETCH:
  powershell -NoProfile -File ${PIPE}\\source-domains.ps1 -Brief
      -> BLOCKED domains (do not fetch, do not retry), UNRELIABLE ones to avoid, and which publishers
         carry JSON-LD. On 2026-08-16 a sourcer fetched thespruceeats - blocked in its own prompt - and
         the recipe 404'd after paying for the search AND the fetch.

FETCH CHEAPLY. Use the helper rather than pulling a whole page into context:
  powershell -NoProfile -File ${PIPE}\\fetch-recipe.ps1 -Url '<url>'
      -> caches the page (so the extractor never re-fetches it) and returns the page's own schema.org
         JSON-LD Recipe block when present: ingredients, instructions AND nutrition. Measured on a real
         budgetbytes page, the rendered HTML is 591,477 bytes and the JSON-LD block is about 4K - a 97%
         cut. It also records the fetch outcome against the domain ledger automatically.
      Reject on the SEARCH SNIPPET where you can - identity is visible in a snippet, nutrition is not,
      so a snippet may rule out a duplicate but may never establish the band.

RETURN THE MOMENT YOU HAVE ONE VERIFIED CANDIDATE. Do not keep searching to fill a quota - a candidate
you are holding is a candidate the rest of the pipeline cannot start on. The dedup adjudicators are idle
right now waiting for it, and you will be re-invoked immediately to find the next one.
If you happened to verify others in the same search pass, include them too; just never keep searching in
order to accumulate more. One verified candidate beats five unverified ones every time.

Write each candidate to its own file: ${RUN}\\candidates\\<slug>.json
Include src_cal and src_carbs per serving. Verified means you READ the page's nutrition, not that a search
snippet implied it.`,
        { agentType: 'recipe-sourcer', label: `hunt:r${r}:${L.key}`, phase: 'Hunt', schema: CANDS })

      // Sourcer rounds are not retried - a round that finds nothing is a normal outcome, not a fault.
      // But a NULL result is still an agent-call failure and must feed the breaker, or a systemic wall
      // hitting only the hunt lane would spin 12 workers forever without ever tripping it.
      agentCalls += 1
      noteAgentResult(res !== null && res !== undefined)
      if (circuitOpen) break

      const cands = (res && res.candidates) || []
      if (cands.length === 0) { log(`hunt ${L.key} r${r}: nothing found`); continue }
      // Push each candidate SEPARATELY. The queue carries recipes, not pools, so an adjudicator can start
      // on the first one while this sourcer is still returning - and the next sourcer round starts now.
      cands.forEach(c => candCh.push({ lane: L, round: r, cand: c }))
      log(`hunt ${L.key} r${r}: +${cands.length} -> select (queue depth ${candCh.size()})`)
    }
  }))
  candCh.close()
}

// ---- ADJUDICATE lane: 8 workers pulling candidates off the queue the instant sourcers produce them ----
async function adjudicateLane() {
  if (DRAIN_ONLY) {
    log('DRAIN MODE: dedup adjudicators disabled - nothing new to rule on')
    decideCh.close()
    return
  }
  await pool(DEDUP_WORKERS, async () => {
    for (;;) {
      // takeBatch blocks ONLY for the first item, then sweeps up whatever else is already sitting there.
      // A lone candidate is adjudicated alone, immediately; a backlog is absorbed a few at a time. It
      // never waits to fill a quota, which is the difference between buffering and batching.
      const items = await candCh.takeBatch(3)
      if (items === null) return
      if (halted()) return
      const cands = items.map(i => i.cand)
      const lanes = [...new Set(items.map(i => i.lane.key))].join(', ')
      const v = await withRetry(() => agent(`${laneLog('select', `adjudicate ${cands.length}`, cands.map(c => c.slug))}
Adjudicate ${cands.length === 1 ? 'ONE candidate' : `these ${cands.length} candidates`} for run ${RUNID}.
Do not select, do not write shared state. From hunt lane(s): ${lanes}.
${cands.map(c => `  ${c.slug} - ${c.name} (${c.src_cal} cal / ${c.src_carbs}g carbs) ${c.source_url}\n    file: ${RUN}\\candidates\\${c.slug}.json`).join('\n')}

Other adjudicators are ruling other candidates right now, the decider is consuming your verdicts as they
land, and the sourcers are still hunting. Rule what is in front of you and return - do not wait for more.

Rule EACH candidate KEEP or DUPE against:
  - the catalog, QUERIED not loaded. Do NOT read catalog-digest.json (111,942 bytes, and this lane plus
    hunt were 75.5% of the last run's tokens). Per candidate:
        powershell -NoProfile -File ${PIPE}\\find-similar.ps1 -Name '<dish>' -Protein <p>
    It returns the ~5 nearest catalog recipes with the words they share - about 1KB.
  - prior rulings, so this estate never re-adjudicates a dish it has already judged:
        powershell -NoProfile -File ${PIPE}\\considered-dishes.ps1 -Query -Name '<dish>' -Protein <p> -Method <m>
    Exit 3 means there IS a prior ruling; the reason is printed. Treat it as strong prior art, not as a
    verdict - the decider still rules.
  - ${RUN}\\accepted-slugs.json - READ IT FRESH each time, the decider appends to it continuously
"Beef chili" and "beef chili mac" are different dishes; "chicken tikka masala" twice is not. Give each
ruling one sentence of evidence naming the catalog recipe it duplicates, if any.

CONDITIONS: ${COND}. Also rule NOT-FIT on any candidate whose published numbers do not clear that.
Do NOT penalise a candidate for carrying unmapped ingredients - per v2.1 section 5.1 this run exists partly
to exercise the pricer lane, so absent-ingredient picks are wanted, not avoided.

For each KEEP, note which dishes in OTHER proteins it could plausibly collide with (e.g. "this is
structurally the same dish as a turkey version") so the decider can catch what you cannot see - you are
looking at a handful of candidates, not the whole run.

Write your verdicts to ${RUN}\\selected\\<slug>.verdict.json, one file per candidate.
Do NOT write accepted-slugs.json. Do NOT advance any recipe state. Those belong to the decider, which is
consuming your verdicts as they land.`,
        { agentType: 'recipe-dedup-selector', label: `dedup:${cands.length}x`, phase: 'Select' }), cands.map(c => c.slug), 'adjudicate')

      if (v === null) {
        if (circuitOpen) {
          // Never requeue into a closed pipeline. These are pre-acceptance candidates that were never
          // ruled on - they are not in accepted-slugs and hold no run state, so they simply drop and
          // a later run re-sources them. Nothing is lost that was ever committed to.
          log(`adjudicate: dropping ${cands.length} unadjudicated candidate(s) - run halted, they were never accepted`)
          return
        }
        // Pushing these to the decider anyway (the original bug here) sends it to read verdict files
        // that were never written - it would either hallucinate a decision or silently drop the
        // candidates with no record at all. Send them back for a clean re-adjudication instead.
        log(`adjudicate: batch of ${cands.length} got no response after retries - re-queuing for adjudication`)
        items.forEach(i => candCh.push(i))
        continue
      }
      cands.forEach(c => decideCh.push({ cand: c, verdict: v }))
    }
  })
  decideCh.close()
}

// ---- DECIDE lane: ONE worker, consuming verdicts as they arrive. The single writer of shared state ----
async function decideLane() {
  if (DRAIN_ONLY) {
    log('DRAIN MODE: decider disabled - accepting nothing new')
    extractCh.close()
    return
  }
  for (;;) {
    // Same greedy take: one candidate is decided alone the instant it arrives; a backlog is swept up to
    // 5 at a time. The decider never idles waiting for company and never holds a candidate back.
    const items = await decideCh.takeBatch(5)
    if (items === null) break
    if (halted()) break
    if (targetReached) {
      log(`decide: target already met - discarding ${items.length}`)
      continue
    }
    const cands = items.map(i => i.cand)
    const need = TARGET - acceptedSlugs.length

    const sel = await withRetry(() => agent(`${laneLog('select', `decide ${cands.length}`, cands.map(c => c.slug))}
DECIDE on ${cands.length === 1 ? 'ONE adjudicated candidate' : `these ${cands.length} adjudicated candidates`} for run ${RUNID}.
You are the SINGLE decider for this whole run and the ONLY writer of shared state. More candidates are
being adjudicated right now and will reach you next; the sourcers are still hunting behind them. Decide on
what is in front of you and return.

${cands.map(c => `  ${c.slug} - ${c.name} (${c.src_cal} cal / ${c.src_carbs}g carbs)\n    verdict: ${RUN}\\selected\\${c.slug}.verdict.json`).join('\n')}

We still need ${need} recipe(s) to reach ${TARGET}.
Already accepted this run (${acceptedSlugs.length}): ${acceptedSlugs.join(', ') || '(nothing yet)'}

Your job is the part that could NOT be sharded:
1. CROSS-LANE DUPLICATES. Each adjudicator saw only a handful of candidates from one hunt lane. A dish it
   kept may be the same dish as one already accepted from another protein - "the same dish in beef and in
   turkey" is invisible to it and visible to you, because you alone see every acceptance in this run.
   Check each KEEP against the accepted list above AND against ${RUN}\\accepted-slugs.json fresh. The
   adjudicator's cross-protein flags are leads, not a complete list.
2. ACCEPT or REJECT each one, keeping the run's protein mix balanced rather than letting one lane run away
   with it. Rejecting is correct when a candidate is weak or collides - more are coming continuously and
   you never need to fill the target from what is in front of you. Do not pad.
3. RECORD EVERY RULING IN THE ESTATE'S MEMORY. You are the only writer of it. For EACH candidate you
   rule on - accepted or rejected:
     powershell -NoProfile -File ${PIPE}\\considered-dishes.ps1 -Record -Slug <s> -Name '<name>' -Protein <p> -Method <m> -Verdict <accepted|rejected-dupe|...> -Reason '<one sentence>' -DupeOf '<slug>','<slug>' -Run ${RUNID} -By decider
   This is what stops the next run re-sourcing, re-adjudicating and re-deciding the same dishes: 44 of
   91 recipes died as duplicates on 2026-08-16 and left no trace outside the run dir, so every future
   run would have paid for them again. Record rejections especially - they are the ones that repeat.

4. THE SINGLE WRITE. Append every accepted slug to ${RUN}\\accepted-slugs.json (create it as a JSON array
   if absent) and write ${RUN}\\selected\\<slug>.selected.json per acceptance. Nothing else writes those.

You may overrule the adjudicator, but not silently - say why in the selection note.

Per SELECTED slug: ${HR} -Advance -RunDir ${RUN} -Slug <s> -To sourced -By sourcer -Detail '<source url>'
             then: ${HR} -Advance -RunDir ${RUN} -Slug <s> -To selected -By selector
Per DUPE slug:    ${HR} -Advance -RunDir ${RUN} -Slug <s> -To sourced -By sourcer -Detail '<url>'
             then: ${HR} -Advance -RunDir ${RUN} -Slug <s> -To rejected-dupe -By selector -Detail '<why>'`,
      { agentType: 'recipe-dedup-selector', label: `decide:${cands.length}x`, phase: 'Select', schema: SEL }), cands.map(c => c.slug), 'decide')

    if (sel === null) {
      // No verdict was ever rendered - these candidates were adjudicated but never decided on. Marking
      // them 'rejected: took nothing' (the pre-fix behavior) would silently erase them from the report
      // with no way to tell "genuinely weak" from "the decider never ran". Record them stuck instead.
      cands.forEach(c => stuck(c.slug, 'decide', `no response after ${MAX_STAGE_RETRIES + 1} attempts - adjudicated but never decided`))
      continue
    }
    const picked = (sel.selected || []).filter(s => s && s.slug)
    if (picked.length === 0) { log(`decide: rejected all ${cands.length}`); continue }
    picked.forEach(p => {
      if (acceptedSlugs.length >= TARGET) return
      acceptedSlugs.push(p.slug)
      record(p.slug, p)
      extractCh.push(p)   // straight into extraction the moment it is accepted
    })
    log(`decide: +${picked.length} -> ${acceptedSlugs.length}/${TARGET} accepted (extraction starts now)`)
    if (acceptedSlugs.length >= TARGET) {
      targetReached = true
      log(`TARGET MET at ${acceptedSlugs.length} - sourcers will stop after their current round`)
    }
  }
  extractCh.close()
}

// ---------------------------------------------------------------------------------------------
// EVERY LANE STARTS AT ONCE AND RUNS UNTIL ITS INPUT IS EXHAUSTED. No lane waits for another lane to
// finish a round; each one closes its downstream channel only when its own input has drained, which is
// what lets a recipe be in QA while another is being extracted while the sourcers are still hunting.
// ---------------------------------------------------------------------------------------------
// SEED BEFORE THE LANES START. Closing a channel does not discard what is already in it - take()
// drains the buffer first and only then returns null - so seeding here survives the immediate closes
// that the disabled front-end lanes perform. Order matters only in that this must precede Promise.all.
if (DRAIN_ONLY) {
  SEED.extracted.forEach(s => { record(s, { slug: s, state: 'extracted' }); mapCh.push(REC.get(s)) })
  SEED.priced.forEach(s => { record(s, { slug: s, state: 'priced' }); writeCh.push(REC.get(s)) })
  SEED.written.forEach(s => { record(s, { slug: s, state: 'written' }); qaCh.push(REC.get(s)) })
  SEED.qaPassed.forEach(s => { record(s, { slug: s, state: 'qa-passed' }); qaPassed.push(s) })
  SEED.parked.forEach(p => {
    record(p.slug, { slug: p.slug, state: 'pricing' })
    pricingSlugs.add(p.slug)
    p.terms.forEach(t => absentTerms.add(t))
    priceWake.push(p.slug)
  })
  // These count as accepted work already in the building, so the WIP limit reflects reality.
  const all = [...SEED.extracted, ...SEED.priced, ...SEED.written, ...SEED.qaPassed, ...SEED.parked.map(p => p.slug)]
  all.forEach(s => acceptedSlugs.push(s))
  log(`DRAIN MODE seeded ${all.length} in-flight recipes: ${SEED.extracted.length} -> map, ${SEED.priced.length} -> write, ${SEED.written.length} -> qa, ${SEED.qaPassed.length} already qa-passed, ${SEED.parked.length} -> price`)
  log(`${absentTerms.size} unpriced term(s) queued: ${Array.from(absentTerms).join(', ')}`)
  // 6 qa-passed already clear the wave gate the moment a wave can close; the rest arrive as they finish.
  maybeCloseWave(false)
}

log(`starting 8 concurrent lanes: hunt(${LANES.length}) -> adjudicate(${DEDUP_WORKERS}) -> decide(1) -> extract(${CAP.extract}) -> map(${CAP.map}) -> price(1 singleton) -> write(${CAP.write}) -> qa(${CAP.qa})`)
log(`target ${TARGET} recipes, ${CAL_MIN}-${CAL_MAX} cal / <=${CARB_MAX}g carbs, waves of ${WAVE_SIZE}`)
log(`harness caps CONCURRENT agents at 16; ${LANES.length + DEDUP_WORKERS} front-end workers share that with the ${CAP.extract + CAP.map + 1 + CAP.write + CAP.qa} downstream, throttled by backpressure at ${HUNT_BACKPRESSURE} queued pools`)
await Promise.all([
  huntLane(),
  adjudicateLane(),
  decideLane(),
  extractLane(),
  mapLane(),
  priceLane(),
  writeLane(),
  qaLane(),
])
const accepted = acceptedSlugs

const stuckCount = outcomes.filter(o => o.status === 'stuck').length
log(`lanes drained: ${outcomes.length} recipes resolved (${stuckCount} STUCK - no verdict ever rendered, distinct from rejected), ${priceInvocations} pricer invocation(s), ${agentCalls} agent calls`)
if (circuitOpen) {
  log(`RUN HALTED EARLY: ${circuitReason}`)
  log('Nothing is lost. hunt-run.ps1 -Status is the truth, and every recipe resumes from its real state.')
}
if (stuckCount > 0) {
  log(`STUCK detail: ${outcomes.filter(o => o.status === 'stuck').map(o => `${o.slug} (${o.detail})`).join(' | ')}`)
}

maybeCloseWave(true)
await waveChain
if (qaPassed.length > 0) { maybeCloseWave(true); await waveChain }

// ---------------------------------------------------------------------------------------------
// v2.1 section 5.2 + 5.3: instrumentation and the proving-run verifications
// ---------------------------------------------------------------------------------------------
phase('Instrument')
// If the breaker tripped, the instrumentation agents would be three more calls into the same wall -
// and their output would describe a truncated run as if it were a finished one. Skip them and say so.
const [usage, proof] = circuitOpen ? ['(skipped - run halted early)', '(skipped - run halted early)'] : await parallel([
  () => agent(`${SHELL}
${laneLog("review", "instrument:usage", ["usage"])}
Compile per-stage token usage for run ${RUNID} into ${RUN}\\usage.jsonl (v2.1 plan section 5.2).
The workflow's subagent transcripts are JSONL under:
  C:\\Users\\Owner\\.claude\\projects\\C--Codex-ThriftyCrew\\b1e6837d-41aa-4ba9-bd67-4132dfde30e4\\subagents\\workflows\\
Find this run's directory (the newest one), read each agent-*.jsonl, and sum input/output tokens per agent
from the usage records. Write one JSON object per line to usage.jsonl:
  {"stage":"<label prefix e.g. hunt|select|extract|map|price|write|qa|wave>","label":"<agent label>","input":<n>,"output":<n>}
Then append a final summary line with the totals and the per-recipe cost:
  {"stage":"TOTAL","recipes_published":<n>,"input":<n>,"output":<n>,"per_recipe":<n>}
The v2.1 target is 200-250k tokens per recipe at wave size 10, against the shakedown's 786k. Report the
totals and whether the run hit that target. If the transcripts do not carry usage records, say so plainly
rather than estimating - a fabricated number here defeats the whole point of instrumenting the run.`,
    { label: 'instrument:usage', phase: 'Instrument' }),

  () => agent(`${SHELL}
${laneLog("review", "instrument:proving-checks", ["proving"])}
Verify the three things v2.1 plan section 5.3 says this proving run must establish. Report evidence, and
report FAILURE plainly if the evidence is not there - this is the run that is supposed to catch these.

(a) THE PRICER LANE STAYED A SINGLETON. ${priceInvocations} pricer invocation(s) were dispatched. Read the
    workflow transcripts (newest dir under C:\\Users\\Owner\\.claude\\projects\\C--Codex-ThriftyCrew\\b1e6837d-41aa-4ba9-bd67-4132dfde30e4\\subagents\\workflows\\)
    and confirm no two recipe-hunter-pricer agents overlapped in time. Confirm each invocation's per-store
    tab behaviour matched its definition (one tab per browser store, in-store mode proved per store).

(b) hunt-run -Derive MOVED RECIPES OFF REAL QUEUE VERDICTS, not fixtures. Read
    ${RUN}\\state\\*.json histories and the live ingredient queue
    (powershell -NoProfile -File ${IQ} -List). For every recipe that left 'pricing', show the queue
    evidence that justified it: which store carried the term, at what price, with what item name. Flag any
    recipe that moved to 'priced' without a CARRIED verdict backing every blocking term.

(c) MID-RUN RESUME. Run: powershell -NoProfile -File ${HR} -Status -RunDir ${RUN}
    Confirm it prints the buckets and the parked worklist, and state whether a killed session could
    genuinely re-enter from it. NOTE HONESTLY that a real kill/resume drill was NOT performed during this
    run unless you find evidence that it was - do not claim a drill that did not happen.

Write your findings to ${RUN}\\proving-run-verification.md.`,
    { label: 'instrument:proving-checks', phase: 'Instrument' }),
])

const status = circuitOpen ? '(skipped - run halted early; hunt-run.ps1 -Status is the record)' : await agent(`${SHELL}
${laneLog("review", "final-report", ["report"])}
Write the final run report for ${RUNID} to ${RUN}\\report.md and report it back.
  powershell -NoProfile -File ${HR} -Status -RunDir ${RUN}

FIVE buckets, never rounded into each other (plan section 3's four, plus STUCK - this orchestrator's own
addition, since a 2026-08-16 session-limit outage proved it necessary):
- PUBLISHED: live URLs per wave, with auditor and reviewer verdicts, plus the collateral count per wave.
- PARKED: the recipe, the ingredient, and exactly which stores are still unchecked and why. This is the
  resume worklist, not a failure list.
- HELD: anything the serveability gate rolled back - slug, what the feed could not price, what must be
  fixed. Never report a held recipe as published.
- REJECTED: which ingredient failed and which stores were checked, or the dupe/unreadable/QA/macro reason.
  Every REJECTED slug here has an EXPLICIT verdict behind it from the stage that rejected it - a real
  ruling was rendered, not inferred from an agent call that never completed.
- STUCK (list these separately, by slug, with the detail string from each): a stage's agent call failed
  repeatedly and no verdict was ever rendered - NOT a content-based rejection. These are resumable: run
  the orchestrator again and they re-enter the lane that stalled. Read them from the STUCK detail below.
STUCK this run (${stuckCount}): ${outcomes.filter(o => o.status === 'stuck').map(o => `${o.slug} [${o.detail}]`).join('; ') || '(none)'}

Plus: commodity-registrar rulings and their follow-ups, and the ledger status of every wave.

Also fold in ${RUN}\\usage.jsonl (token economics) and ${RUN}\\proving-run-verification.md (the section 5.3
checks) as their own sections, since this run is the v2.1 proving run.`,
  { label: 'final-report', phase: 'Instrument' })

return {
  runId: RUNID,
  halted: circuitOpen,
  haltReason: circuitReason || null,
  agentCalls,
  accepted: accepted.length,
  priceInvocations,
  waves: waveResults,
  outcomes: outcomes.map(o => ({ slug: o.slug, status: o.status, state: o.state, cal: o.cal, carbs: o.carbs, cost: o.cost, detail: o.detail })),
  usage: String(usage || '').slice(0, 3000),
  provingChecks: String(proof || '').slice(0, 3000),
  report: String(status || '').slice(0, 4000),
}
