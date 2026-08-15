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

/*
  ---------------------------------------------------------------------------------------------
  THE WALL HANDOFF: raise a WINDOWS alert, then WAIT for Brad to click Done.
  ---------------------------------------------------------------------------------------------
  A CAPTCHA is the one obstacle no agent may solve on its own, so the only correct behaviour is:
  say so loudly, hand control back, and resume on an explicit human go-ahead.

  *** THE ALERT IS notify-desktop.ps1, NOT A BROWSER NOTIFICATION. *** (Brad, 2026-08-15: "It can't
  be a chrome alert - it must be a Windows System alert.") A page-origin Notification is a Chrome
  toast: it needs per-site permission, it dies with the tab, and it is not a system-level prompt.
  notify-desktop.ps1 already existed for exactly this - it shows a detached Windows prompt, and
  clicking Done writes out\notify-ack-<store>.json, which IS the resume handshake (built for Brad's
  2026-08-13 request, same ask). Do not reintroduce a Notification-API path here.

  A browser page cannot launch a Windows process, so the handoff is a two-part contract and the
  DRIVER (the session or scheduled job running the sweep) bridges it:

      agent  : on a wall, publishes window.__tcWall = {store, term, why, at} and then BLOCKS,
               polling window.__tcResume until the driver sets it.
      driver : sees __tcWall -> runs  notify-desktop.ps1 -Store <s> -Detail <d>
                             -> runs  notify-desktop.ps1 -WaitForAck <s>   (blocks on the click)
                             -> sets  window.__tcResume = 'done' | 'stop'

  The on-page overlay stays, but only as a VISIBLE STATE for whoever looks at the tab - it is not
  the alert and not the primary callback. Its buttons still work as a manual override so the run is
  never wedged if the driver dies.

  STOP is a first-class answer, not just Done. Being forced to clear a wall to end a run would be
  its own trap, and a run Brad abandons must end cleanly rather than hang.
*/

/**
 * Publish the wall state, show the in-tab overlay, and block until the driver (or a click)
 * answers. Resolves 'done' (cleared, resume) or 'stop' (end the run cleanly).
 */
function waitForOperator(storeName, term, why) {
  return new Promise(resolve => {
    // The signal the driver polls for. Set BEFORE any UI work so a wall is never invisible to it.
    window.__tcWall = { store: storeName, term, why, at: new Date().toISOString() };
    window.__tcResume = null;

    let settled = false;
    const finish = answer => {
      if (settled) return;
      settled = true;
      clearInterval(poll);
      const el = document.getElementById('tc-wall-overlay');
      if (el) el.remove();
      window.__tcWall = null;
      window.__tcResume = null;
      resolve(answer);
    };

    // The Windows prompt's Done click reaches us as window.__tcResume, set by the driver.
    const poll = setInterval(() => {
      if (window.__tcResume === 'done' || window.__tcResume === 'stop') finish(window.__tcResume);
    }, 500);

    const prev = document.getElementById('tc-wall-overlay');
    if (prev) prev.remove();

    const wrap = document.createElement('div');
    wrap.id = 'tc-wall-overlay';
    wrap.style.cssText = [
      'position:fixed', 'inset:0', 'z-index:2147483647',
      'background:rgba(8,12,20,.92)', 'display:flex', 'align-items:center', 'justify-content:center',
      'font-family:system-ui,Segoe UI,Arial,sans-serif', 'color:#fff',
    ].join(';');

    const card = document.createElement('div');
    card.style.cssText = [
      'max-width:560px', 'padding:28px 32px', 'border-radius:14px',
      'background:#121a2b', 'border:1px solid #2b3a55',
      'box-shadow:0 20px 60px rgba(0,0,0,.6)', 'text-align:left',
    ].join(';');

    const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    card.innerHTML =
      `<div style="font-size:13px;letter-spacing:.14em;text-transform:uppercase;color:#ff9a3c;margin-bottom:10px">Bot wall / CAPTCHA</div>` +
      `<div style="font-size:22px;font-weight:600;margin-bottom:14px">${esc(storeName)} is blocking the pull</div>` +
      `<div style="font-size:15px;line-height:1.55;color:#c6d2e6">` +
      `Blocked on <b style="color:#fff">${esc(term)}</b> (${esc(why)}).<br><br>` +
      `A <b style="color:#fff">Windows alert</b> has been raised - clear the CAPTCHA in this window, then click ` +
      `<b style="color:#fff">Done</b> on that alert. The sweep resumes from exactly where it stopped and nothing ` +
      `already collected is lost.<br><br>` +
      `<span style="color:#8fa2bf;font-size:13px">The buttons below are a manual override if the Windows alert did not appear.</span>` +
      `</div>` +
      `<div style="margin-top:24px;display:flex;gap:12px">` +
      `<button id="tc-wall-done" style="flex:1;padding:14px 18px;font-size:16px;font-weight:600;border:0;border-radius:9px;background:#2f9e5a;color:#fff;cursor:pointer">Done - I cleared it</button>` +
      `<button id="tc-wall-stop" style="padding:14px 18px;font-size:15px;border:1px solid #44536e;border-radius:9px;background:transparent;color:#c6d2e6;cursor:pointer">Stop the run</button>` +
      `</div>`;

    wrap.appendChild(card);
    document.body.appendChild(wrap);

    card.querySelector('#tc-wall-done').onclick = () => finish('done');
    card.querySelector('#tc-wall-stop').onclick = () => finish('stop');
  });
}

/**
 * Block until the wall is cleared. Returns 'done' | 'stop'.
 * The Windows alert itself is raised by the DRIVER via notify-desktop.ps1 -- see the contract above.
 * This function's job is to make the wall VISIBLE (window.__tcWall) and to stop the sweep dead until
 * a human answers, which is the part that must never be skipped.
 */
async function awaitWallCleared(storeName, term, why) {
  console.warn(
    `${storeName}: BOT WALL on "${term}" (${why}). Published window.__tcWall for the driver, which ` +
    `raises the Windows alert (notify-desktop.ps1). Waiting for Done.`
  );
  return waitForOperator(storeName, term, why);
}

/** Base delay plus jitter, so the cadence is ragged rather than machine-regular. */
function pacedDelay(base, jitter) {
  return base + Math.floor(Math.random() * (jitter || 0));
}

/**
 * Build the timing ledger. Separate from runPacedSweep because not every agent is a term sweep --
 * Aldi's is a product-slug lookup with a different loop shape. The MEASUREMENT is shared even where
 * the loop is not; forcing every store into one loop to share it would be the wrong kind of reuse.
 */
function finishLedger({ t0, requests, delayMs, jitterMs, firstWallAfter, pausedMs = 0, hiddenSamples = 0, totalSamples = 0 }) {
  const elapsedMs = Date.now() - t0;
  // Time spent waiting on a human is NOT part of our request cadence. Leaving it in would inflate
  // observedMeanIntervalMs by however long Brad took to clear a CAPTCHA, and that number is exactly
  // what promotes a profile to `measured` - so a slow coffee break would read as a safe slow rate.
  const activeMs = Math.max(0, elapsedMs - pausedMs);
  return {
    configuredDelayMs:      `${delayMs}+0..${jitterMs || 0}`,
    elapsedMs,
    pausedMs,
    activeMs,
    requests,
    observedMeanIntervalMs: requests ? Math.round(activeMs / requests) : null,
    firstWallAfterTerms:    firstWallAfter,
    /*
      Was the tab hidden while we swept? Chrome throttles timers in hidden tabs, so a slow run has
      two completely different explanations - the store was slow, or we were being throttled - and
      without this the ledger cannot tell them apart. Measured 2026-08-15 rather than assumed: a
      388-term sweep ran at 5.3-6.1s/term with the Chrome window unfocused the whole time, i.e. an
      unfocused window did NOT throttle it. Keep recording it so that stays a fact, not a memory.
    */
    hiddenPct: totalSamples ? Math.round((hiddenSamples / totalSamples) * 100) : null,
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
  let wallPauses = 0, pausedMs = 0;            // how often we had to hand off, and for how long
  let stopped = false;
  let hiddenSamples = 0, totalSamples = 0;     // was the tab visible while we swept? (see finishLedger)

  // A term the operator cleared a wall for is worth retrying immediately rather than leaving
  // UNUSABLE for a later run - that is the whole point of waiting for them.
  const queue = worklist.slice();
  for (let qi = 0; qi < queue.length; qi++) {
    const term = queue[qi];
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

    totalSamples++;
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') hiddenSamples++;

    if (settled) { consecutiveWalls = 0; done++; }
    else         { consecutiveWalls++;   walled++; }

    localStorage.setItem(agent.storageKey, JSON.stringify(res));   // persist every term

    /*
      THE HANDOFF. Retries with backoff have already failed, so this is a real wall, not a blip.
      A CAPTCHA is the one obstacle an agent must never try to solve, so: alert Brad on both
      surfaces and WAIT. On 'done' we re-queue this term and carry on from exactly here; on 'stop'
      we end cleanly. Either way nothing already collected is lost - every term is persisted as it
      settles. Continuing blindly instead would record the rest of the worklist as UNUSABLE and
      deepen the block, which is what the 2026-08-15 run did.
    */
    if (consecutiveWalls >= wallLimit) {
      const pauseAt = Date.now();
      const answer = await awaitWallCleared(agent.storeName, term, res[term]?.why || 'blocked');
      pausedMs += Date.now() - pauseAt;
      wallPauses++;

      if (answer === 'stop') {
        console.warn(`${agent.storeName}: stopped by operator. Re-run the same worklist later to finish the tail.`);
        stopped = true;
        break;
      }
      consecutiveWalls = 0;
      queue.push(term);          // he cleared it - give this term a real look
      continue;                  // skip the pace delay; the pause was longer than any of them
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
    thisRun:   { settled: done, walled, wallPauses, pausedMs, stoppedByOperator: stopped },
    remaining: worklist.filter(t => !res[t] || res[t].v === 'UNUSABLE').length,
    /*
      THE NUMBERS THAT PROMOTE A PROFILE FROM `proposed` TO `measured`.
      Paste them into stores.json -> <store> -> pull_profile.evidence. Only a CLEAN verdict
      licenses confidence:measured; a wall is another ceiling observation, not a safe rate.
    */
    timing: finishLedger({ t0, requests, delayMs, jitterMs, firstWallAfter, pausedMs, hiddenSamples, totalSamples }),
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
