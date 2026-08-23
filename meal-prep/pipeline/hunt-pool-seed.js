export const meta = {
  name: 'recipe-hunt-pool-seed',
  description: 'v3 phase-1 bridge: rule on harvested candidate dossiers with one decider call per batch',
  phases: [
    { title: 'Decide' },
  ],
}

// ---------------------------------------------------------------------------------------------
// hunt-pool-seed.js - the PHASE 1 BRIDGE of PLAN-recipe-hunter-v3 (section 6).
//
// WHAT IT REPLACES. hunt-orchestrator.js's front end: 12 sourcer workers (245 agents, 325,543,422
// tokens, 43.3% of run wf_11382034-6fd), 8 dedup adjudicators sharding a raw pool (333 agents,
// 242,157,676 tokens, 32.2%), and a decider that then re-read the corpus to rule. 578 front-end
// agents produced 91 accepted recipes, 44 of which died as dupes.
//
// In v3 the discovery, fetching, band arithmetic, signature and first-pass dedup all happen locally
// in harvest.py for zero tokens, and what reaches Claude is a DOSSIER: 2-3 KB of pre-qualified
// evidence per candidate. What is left is exactly the decider's monopoly - cross-pool judgment.
//
// THE BRIDGE'S SHAPE, and why it is this shape:
//   1. OUTSIDE the sandbox:  harvest.py --dossier --count N --out <file>   (no tokens, no agents)
//   2. HERE:                 one recipe-dedup-selector call per <=10 dossiers, inline, schema'd out
//   3. OUTSIDE the sandbox:  decide_apply.py --verdict <file> ...          (no tokens, no agents)
//
// Step 3 deliberately does NOT happen in here. The Workflow sandbox has no filesystem and no shell,
// so applying a verdict from inside it would mean spawning a full Claude agent whose entire job is to
// run one PowerShell line - finding F2, the single largest source of pointless agents in v2's wave
// lane. The judgment plane returns rulings; the mechanics plane writes them. That is the v3 division
// of labour, and honouring it here means the bridge costs exactly ONE agent per ten candidates and
// nothing else. When the daemon lands (D9) step 3 becomes a function call in the same process, and
// nothing about steps 1 and 2 changes.
//
// hunt/adjudicate lanes: OFF. There is no sourcing here at all - the backlog is the supply. The
// existing hunt-orchestrator.js in DRAIN mode carries whatever this seeds onward from `selected`.
//
// INPUT (the Workflow tool's `args`): { runId, batches: [ [dossier, ...], ... ] }
//   or { runId, dossiers: [dossier, ...] } and this script batches them itself.
// OUTPUT: { runId, verdicts: [ <DECIDE payload>, ... ], batches: n, candidates: n }
// ---------------------------------------------------------------------------------------------

const BATCH = 10   // section S2: one decider call per <=10 candidates. A CAP, not a quota.

// The DECIDE schema (section 4.5). NORMATIVE COPY LIVES IN hunt_lib.py - this is the harness-side
// hint that shapes the model's output. The two cannot silently drift into disagreement, because
// decide_apply.py validates every verdict against hunt_lib.validate_decide before writing anything
// and refuses the whole payload (exit 2, nothing written) if it does not conform. One enforcement
// point, even though the hint has to be repeated in a language that cannot import the module.
const DECIDE = {
  type: 'object',
  properties: {
    decisions: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          slug: { type: 'string' },
          verdict: { type: 'string', description: 'accepted | rejected-dupe | rejected-not-fit | deferred' },
          reason: { type: 'string' },
          dupe_of: { type: 'array', items: { type: 'string' } },
          record: {
            type: 'object',
            description: 'written to considered-dishes verbatim, -By decider',
            properties: {
              name: { type: 'string' },
              protein: { type: 'string' },
              method: { type: 'string' },
              verdict: { type: 'string' },
              reason: { type: 'string' },
            },
            required: ['name', 'protein', 'method', 'verdict', 'reason'],
          },
        },
        required: ['slug', 'verdict', 'reason', 'record'],
      },
    },
    note: { type: 'string' },
  },
  required: ['decisions'],
}

const input = args || {}
const runId = input.runId || 'unnamed-run'
const target = input.target || 0
let batches = input.batches
if (!batches) {
  const all = input.dossiers || (input.dossier && input.dossier.candidates) || []
  batches = []
  for (let i = 0; i < all.length; i += BATCH) batches.push(all.slice(i, i + BATCH))
}
if (!batches.length) {
  log('pool-seed: no dossiers in args - nothing to rule on. Run harvest.py --dossier first.')
  return { runId, verdicts: [], batches: 0, candidates: 0 }
}

const total = batches.reduce((n, b) => n + b.length, 0)
log(`pool-seed: ${total} pre-qualified candidate(s) in ${batches.length} batch(es), one decider call each`)

phase('Decide')

// SERIAL, and the accepted list is THREADED FORWARD. The decide lane is a singleton by design: one
// decider sees every acceptance in the run, and that is the whole reason a cross-batch twin is
// catchable at all. The first build of this bridge dispatched each batch with no memory of the last,
// and it showed immediately - on 2026-08-23 the decider rejected `antipasto-salad` in batch 1 and
// then accepted its twin `antipasto-pasta-salad` in batch 2, and accepted two different chicken
// salads across the two. v2's decider was handed "already accepted this run"; dropping that turned
// one decider into N independent ones wearing the same name.
const verdicts = []
const acceptedSoFar = []
for (let i = 0; i < batches.length; i++) {
  const cands = batches[i]
  const v = await agent(
`DECIDE on ${cands.length === 1 ? 'this ONE candidate' : `these ${cands.length} candidates`} for run ${runId}.

You are the single decider for this run. Every candidate below has already been mechanically
qualified by the harvest plane: enumerated from a known publisher, fetched, its band read from the
page's own JSON-LD, its signature derived from its ingredients and instructions, and its nearest
neighbours scored two different ways. Nothing has been ruled a duplicate - that is the call only you
make.

HOW TO READ THE DOSSIER, because two of these fields decide most of the hard calls:
 - Every neighbour carries \`side\`. **live-catalog** means that dish is ALREADY PUBLISHED - accepting a
   near-twin of it duplicates the catalog. **backlog** means it is another harvested candidate nobody
   has ruled on; a close backlog neighbour is a question about which of the two to keep, not a
   catalog dupe. \`catalog_checked\` says how many live recipes were searched and how many matched, so
   an empty live-match list is EVIDENCE OF ABSENCE, not a gap. The catalog has been searched for you.
   You do not need to open catalog-digest.json or any other corpus, and you should not.
 - \`batch_concerns\` flags what may not survive a 14-serving batch (cold-plate, breakfast,
   cook-to-order, not-a-main). These are FLAGS, not verdicts - a taco salad and a frittata both trip
   them and both can be fine. But this board sells high-protein batch DINNERS, so a flagged candidate
   has to earn its place as one.
${acceptedSoFar.length ? `\nALREADY ACCEPTED EARLIER IN THIS RUN (${acceptedSoFar.length}) - check every candidate against these too, they are yours:\n${acceptedSoFar.map(a => `  ${a.slug} - ${a.name}`).join('\n')}\n` : ''}${target ? `\nThis run is aiming for ${target} recipes. Do not pad to reach it; more candidates are in the backlog.\n` : ''}
Read every dossier. Rule on every candidate. Return the DECIDE object and nothing else.

DOSSIERS
${JSON.stringify(cands, null, 1)}`,
    { agentType: 'recipe-dedup-selector', label: `decide:${cands.length}x`, phase: 'Decide', schema: DECIDE })

  if (v === null) {
    // B5: a null is a transport failure, not a verdict. These candidates are NOT ruled - they stay
    // `taken` in the pool and the operator releases them; recording them as rejected would erase
    // real candidates on the strength of a timeout.
    log(`pool-seed: batch ${i + 1} returned nothing after retries - ${cands.length} candidate(s) UNRULED (STUCK, never rejected)`)
    verdicts.push({ batch: i + 1, stuck: true, slugs: cands.map(c => c.slug) })
    continue
  }
  const d = v.decisions || []
  const accepted = d.filter(x => x.verdict === 'accepted')
  accepted.forEach(x => acceptedSoFar.push({ slug: x.slug, name: (x.record && x.record.name) || x.slug }))
  log(`pool-seed: batch ${i + 1}/${batches.length} ruled ${d.length} (${accepted.length} accepted, ${acceptedSoFar.length} running total)`)
  verdicts.push(Object.assign({ batch: i + 1 }, v))
}

const ruled = verdicts.reduce((n, v) => n + ((v.decisions || []).length), 0)
const accepted = verdicts.reduce((n, v) => n + ((v.decisions || []).filter(x => x.verdict === 'accepted').length), 0)
log(`pool-seed: ${ruled} of ${total} candidate(s) ruled, ${accepted} accepted.`)
log('pool-seed: apply with  decide_apply.py --verdict <file> --run-dir <dir> --run <id>  (the box writes, not the sandbox)')

return { runId, verdicts, batches: batches.length, candidates: total, ruled, accepted }
