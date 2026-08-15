/*
  pull-agent-lib.js  --  the shared discipline every store's browser pull agent runs on.

  WHY A LIB AND NOT FOUR COPIES
  -----------------------------
  Each walled store needs its own agent because each storefront is genuinely different: Sam's is a
  Next.js search page, Aldi is an Instacart product API, Fareway is Instacart with an Apollo cache,
  Walmart is its own thing. What is NOT different is the discipline around them -- pacing, jitter,
  backoff, the three-state verdict, resumability, and the timing ledger. Copying that into four files
  is the duplicated-constant trap (a fix lands in one copy and the other three keep the old bug), so
  it lives here once and each agent supplies only its store-specific parts.

  WHAT EACH AGENT MUST SUPPLY
  ---------------------------
      storeName      display name, must match stores.json
      storageKey     localStorage key for resumable results
      profile        { delayMs, jitterMs, retries, backoffMs, wallLimit }  -- mirrors stores.json
      assertIdentity ()      -> {..} describing the store/club, or THROWS if we are not on it
      probe          (term)  -> { state:'MATCHES'|'EMPTY'|'UNUSABLE', rows:[], why }

  THE RULES THIS LIB EXISTS TO ENFORCE
  ------------------------------------
  1. A BLOCKED SEARCH IS NEVER AN EMPTY ONE. 2026-08-15: the Sam's sweep recorded both identically,
     so afterwards nothing could say whether `milk gallon` was missing because Sam's lacks it or
     because we were walled. Sam's sells milk. A false EMPTY is a silent claim the store does not
     stock an item -- worse than a missing row, because a missing row is visibly missing.
     UNUSABLE is the third state and a wall is ALWAYS UNUSABLE.
  2. STOP WHEN BLOCKED. Pushing on after the wall is up collects nothing and deepens the block.
  3. NEVER TRUST A PRICE WITHOUT ASSERTING THE STORE FIRST. Prices are per-store/per-club, and a
     sweep against the wrong location is real data in the wrong basis -- the hardest kind to catch
     later, because every number looks plausible. Fareway once read plausibly while sitting on
     Des Moines.
  4. LEAVE A MEASUREMENT BEHIND. The 2026-08-15 run recorded no timing whatsoever, so after it
     walled there was no way to say what rate caused it. An agent that cannot report its own cadence
     can never move its profile from `proposed` to `measured`. Every run now emits a timing ledger.
  5. PACE WITH JITTER. A metronome-exact interval is itself a bot signature.
*/

const sleep = ms => new Promise(r => setTimeout(r, ms));

/** Base delay plus jitter, so the cadence is ragged rather than machine-regular. */
function pacedDelay(base, jitter) {
  return base + Math.floor(Math.random() * (jitter || 0));
}

/**
 * Build the timing ledger. Separate from runPacedSweep because not every agent is a term sweep --
 * Aldi's is a product-slug lookup with a different loop shape. The MEASUREMENT is shared even where
 * the loop is not; forcing every store into one loop to share it would be the wrong kind of reuse.
 */
function finishLedger({ t0, requests, delayMs, jitterMs, firstWallAfter }) {
  const elapsedMs = Date.now() - t0;
  return {
    configuredDelayMs:      `${delayMs}+0..${jitterMs || 0}`,
    elapsedMs,
    requests,
    observedMeanIntervalMs: requests ? Math.round(elapsedMs / requests) : null,
    firstWallAfterTerms:    firstWallAfter,
    verdict: firstWallAfter === null || firstWallAfter === undefined
      ? 'CLEAN - no wall. Safe to promote to confidence:measured, recording observedMeanIntervalMs.'
      : `WALLED after ${firstWallAfter} settled item(s). A new ceiling, NOT a safe rate - raise the delay, keep confidence:proposed.`,
  };
}

/**
 * Run a paced, resumable, instrumented sweep for one store.
 * Returns a summary whose `timing` block is what promotes a pull_profile to confidence:measured.
 */
async function runPacedSweep(agent, worklist, opts = {}) {
  const p         = agent.profile;
  const delayMs   = opts.delayMs   ?? p.delayMs;
  const jitterMs  = opts.jitterMs  ?? p.jitterMs ?? 0;
  const retries   = opts.retries   ?? p.retries  ?? 3;
  const backoffMs = opts.backoffMs ?? p.backoffMs ?? 20000;
  const wallLimit = opts.wallLimit ?? p.wallLimit ?? 3;

  const ctx = agent.assertIdentity();          // throws unless we are provably on the right store
  const res = JSON.parse(localStorage.getItem(agent.storageKey) || '{}');

  const t0 = Date.now();
  let requests = 0, done = 0, walled = 0, consecutiveWalls = 0;
  let firstWallAfter = null;                   // terms settled before the FIRST wall of this run

  for (const term of worklist) {
    // Resume: keep settled verdicts, retry only what we were blocked on.
    if (res[term] && res[term].v !== 'UNUSABLE') continue;

    let settled = false;
    for (let attempt = 0; attempt < retries && !settled; attempt++) {
      let r;
      try {
        requests++;
        r = await agent.probe(term);
      } catch (e) {
        r = { state: 'UNUSABLE', rows: [], why: 'probe threw: ' + (e && e.message) };
      }

      if (r.state === 'UNUSABLE') {
        if (firstWallAfter === null) firstWallAfter = done;
        res[term] = { v: 'UNUSABLE', why: r.why || 'blocked', rows: [] };
        await sleep(backoffMs * Math.pow(2, attempt));      // 20s, 40s, 80s
        continue;
      }

      res[term] = { v: r.state, why: r.why || null, rows: r.rows || [] };
      settled = true;
    }

    if (settled) { consecutiveWalls = 0; done++; }
    else         { consecutiveWalls++;   walled++; }

    localStorage.setItem(agent.storageKey, JSON.stringify(res));   // persist every term

    if (consecutiveWalls >= wallLimit) {
      console.warn(
        `${agent.storeName}: STOPPING after ${consecutiveWalls} consecutive blocked terms. Continuing ` +
        `would record the rest of the worklist as UNUSABLE and deepen the block. Wait, then re-run the ` +
        `SAME worklist -- settled terms are skipped and UNUSABLE ones retried.`
      );
      break;
    }

    await sleep(pacedDelay(delayMs, jitterMs));
  }

  const v = Object.values(res);
  const summary = {
    store:     agent.storeName,
    context:   ctx,
    matches:   v.filter(x => x.v === 'MATCHES').length,
    empty:     v.filter(x => x.v === 'EMPTY').length,
    unusable:  v.filter(x => x.v === 'UNUSABLE').length,
    thisRun:   { settled: done, walled },
    remaining: worklist.filter(t => !res[t] || res[t].v === 'UNUSABLE').length,
    /*
      THE NUMBERS THAT PROMOTE A PROFILE FROM `proposed` TO `measured`.
      Paste them into stores.json -> <store> -> pull_profile.evidence. Only a CLEAN verdict
      licenses confidence:measured; a wall is another ceiling observation, not a safe rate.
    */
    timing: finishLedger({ t0, requests, delayMs, jitterMs, firstWallAfter }),
  };
  console.log(`${agent.storeName} sweep:`, summary);
  return summary;
}

/** Export MATCHES rows as q|n|lp|up|id. EMPTY/UNUSABLE deliberately emit nothing -- see samsSweepVerdicts. */
function sweepToCsv(storageKey, rowToCells) {
  const res = JSON.parse(localStorage.getItem(storageKey) || '{}');
  const out = [];
  for (const [term, r] of Object.entries(res)) {
    if (r.v !== 'MATCHES') continue;
    for (const p of r.rows) out.push([term, ...rowToCells(p)].join('|'));
  }
  return out.join('\n');
}

/** The verdict ledger: which terms were checked, and which we never actually got to see. */
function sweepVerdicts(storageKey) {
  const res = JSON.parse(localStorage.getItem(storageKey) || '{}');
  return Object.entries(res).map(([t, r]) => [t, r.v, r.why ?? ''].join('|')).join('\n');
}

/** Terms still owed a real look -- feed straight back in as the next worklist. */
function sweepRemaining(storageKey, worklist) {
  const res = JSON.parse(localStorage.getItem(storageKey) || '{}');
  return worklist.filter(t => !res[t] || res[t].v === 'UNUSABLE');
}
