import { deterministicId, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

type DerivedGate = "shadow-ingest-day" | "semantic-parity-day" | "direct-chrome-week" | "beta-release-day" | "beta-week" | "accuracy-week";

const REQUIRED_BROWSER_SOURCES = [
  "direct-aldi-browser",
  "direct-fareway-browser",
  "direct-sams-browser",
  "direct-walmart-browser",
] as const;

export function centralDateKey(instant: Date): string {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Chicago",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(instant).map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export function addCalendarDays(dateKey: string, days: number): string {
  const [year, month, day] = dateKey.split("-").map(Number);
  if (!year || !month || !day) throw new Error(`invalid date key ${dateKey}`);
  return new Date(Date.UTC(year, month - 1, day + days)).toISOString().slice(0, 10);
}

export function weekStartKey(dateKey: string): string {
  const day = new Date(`${dateKey}T12:00:00.000Z`).getUTCDay();
  return addCalendarDays(dateKey, -(day === 0 ? 6 : day - 1));
}

export function consecutiveDateCount(keys: readonly string[]): number {
  const unique = [...new Set(keys)].sort().reverse();
  if (unique.length === 0) return 0;
  let count = 1;
  let expected = addCalendarDays(unique[0]!, -1);
  for (const key of unique.slice(1)) {
    if (key !== expected) break;
    count += 1;
    expected = addCalendarDays(expected, -1);
  }
  return count;
}

function chicagoSqlModifier(instant: Date): string {
  const value = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago",
    timeZoneName: "shortOffset",
  }).formatToParts(instant).find((part) => part.type === "timeZoneName")?.value ?? "GMT-6";
  const match = value.match(/GMT([+-]\d{1,2})(?::(\d{2}))?/);
  if (!match) return "-360 minutes";
  const hours = Number(match[1]);
  const minutes = Number(match[2] ?? 0) * Math.sign(hours || 1);
  const totalMinutes = hours * 60 + minutes;
  return `${totalMinutes >= 0 ? "+" : ""}${totalMinutes} minutes`;
}

async function recordDerivedGate(
  env: WorkerEnv,
  gate: DerivedGate,
  periodKey: string,
  sourceRef: string,
  pass: boolean,
  observedAt: string,
  evidence: Record<string, unknown>,
): Promise<{ gate: DerivedGate; periodKey: string; status: "pass" | "fail"; eventId: string }> {
  const eventId = await deterministicId("evidence", gate, periodKey, sourceRef);
  const status = pass ? "pass" : "fail";
  await env.DB.prepare(
    `INSERT INTO evidence_gate_events (id, gate, period_key, source_ref, status, evidence_json, observed_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
     ON CONFLICT(gate, period_key, source_ref) DO UPDATE SET
       status = excluded.status, evidence_json = excluded.evidence_json, observed_at = excluded.observed_at`,
  ).bind(eventId, gate, periodKey, sourceRef, status, stableJson(evidence), observedAt).run();
  return { gate, periodKey, status, eventId };
}

interface ReleaseInputSummary {
  batch_count: number;
  store_count: number;
  legacy_batches: number;
  invalid_identity: number;
  rejected_or_blocked_terms: number;
  stale_batches: number;
  unmatched_batches: number;
}

export async function accrueMilestoneEvidence(env: WorkerEnv, now = new Date()): Promise<Record<string, unknown>> {
  const observedAt = now.toISOString();
  const dayKey = centralDateKey(now);
  const weekKey = weekStartKey(dayKey);
  const sqlModifier = chicagoSqlModifier(now);
  const release = await env.DB.prepare(
    `SELECT r.id, r.configuration_id, r.published_at
       FROM current_releases c JOIN releases r ON r.id = c.release_id
      WHERE c.market_id = 'omaha'`,
  ).first<{ id: string; configuration_id: string; published_at: string }>();
  if (!release) throw new Error("cannot accrue milestone evidence without a current Omaha release");
  const expectedStores = (await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM store_locations WHERE market_id = 'omaha' AND active = 1",
  ).first<{ count: number }>())?.count ?? 0;
  const inputs = await env.DB.prepare(
    `SELECT COUNT(*) AS batch_count,
            COUNT(DISTINCT source.store_location_id) AS store_count,
            SUM(CASE WHEN source.capture_method = 'legacy_bridge' THEN 1 ELSE 0 END) AS legacy_batches,
            SUM(CASE WHEN batch.market_verified = 0 OR batch.location_verified = 0 OR batch.price_mode_verified = 0 THEN 1 ELSE 0 END) AS invalid_identity,
            SUM(CASE WHEN batch.rejected_terms > 0 OR batch.blocked_terms > 0 THEN 1 ELSE 0 END) AS rejected_or_blocked_terms,
            SUM(CASE WHEN julianday(?2) - julianday(batch.captured_to) > CAST(COALESCE(json_extract(source.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER) THEN 1 ELSE 0 END) AS stale_batches,
            SUM(CASE WHEN NOT EXISTS (
              SELECT 1 FROM match_runs matching
               WHERE matching.batch_id = batch.id AND matching.configuration_id = ?3 AND matching.status = 'passed'
            ) THEN 1 ELSE 0 END) AS unmatched_batches
       FROM release_input_batches input
       JOIN capture_batches batch ON batch.id = input.batch_id
       JOIN capture_sources source ON source.id = batch.source_id
      WHERE input.release_id = ?1`,
  ).bind(release.id, observedAt, release.configuration_id).first<ReleaseInputSummary>();
  if (!inputs) throw new Error("current release has no input summary");
  const hardGuardFailures = (await env.DB.prepare(
    `SELECT COUNT(*) AS count
       FROM guard_results result JOIN guard_definitions definition ON definition.id = result.guard_id
      WHERE result.release_id = ?1 AND definition.severity = 'hard' AND result.status <> 'pass'`,
  ).bind(release.id).first<{ count: number }>())?.count ?? 0;
  const rejectedToday = (await env.DB.prepare(
    `SELECT COUNT(*) AS count FROM capture_batches
      WHERE status = 'rejected' AND date(ingested_at, ?1) = ?2`,
  ).bind(sqlModifier, dayKey).first<{ count: number }>())?.count ?? 0;
  const releaseDay = await env.DB.prepare("SELECT date(?1, ?2) AS day").bind(release.published_at, sqlModifier).first<{ day: string }>();
  const shadowEvidence = {
    releaseId: release.id,
    expectedStores,
    ...inputs,
    hardGuardFailures,
    rejectedToday,
  };
  const shadowPass = releaseDay?.day === dayKey
    && inputs.store_count === expectedStores
    && inputs.legacy_batches === 0
    && inputs.invalid_identity === 0
    && inputs.stale_batches === 0
    && inputs.unmatched_batches === 0
    && hardGuardFailures === 0;
  const events: Array<Record<string, unknown>> = [await recordDerivedGate(env, "shadow-ingest-day", dayKey, "production-daily", shadowPass, observedAt, shadowEvidence)];

  const parity = await env.DB.prepare(
    `SELECT id, compared_cells, diff_count, status, observed_at
       FROM engine_parity_runs
      WHERE mode = 'direct' AND current_release_id = ?1 AND date(observed_at, ?2) = ?3
      ORDER BY observed_at DESC LIMIT 1`,
  ).bind(release.id, sqlModifier, dayKey).first<{ id: string; compared_cells: number; diff_count: number; status: string; observed_at: string }>();
  const parityPass = Boolean(parity && parity.status === "passed" && parity.diff_count === 0 && parity.compared_cells > 0);
  events.push(await recordDerivedGate(env, "semantic-parity-day", dayKey, "production-daily", parityPass, observedAt, {
    releaseId: release.id,
    parityRun: parity ?? null,
  }));

  let edge: Record<string, unknown> = { ok: false, error: "Ghost public origin is not configured" };
  if (env.GHOST_PUBLIC_ORIGIN) {
    try {
      const url = new URL("/api/v2/releases/current", env.GHOST_PUBLIC_ORIGIN);
      url.searchParams.set("milestone_probe", observedAt);
      const response = await fetch(url, { headers: { accept: "application/json", "cache-control": "no-cache" } });
      const body = await response.json() as { releaseId?: string; ok?: boolean };
      edge = { httpStatus: response.status, releaseId: body.releaseId ?? null, ok: response.ok && body.releaseId === release.id };
    } catch (error) {
      edge = { ok: false, error: error instanceof Error ? error.message : "edge verification failed" };
    }
  }
  const betaPass = shadowPass && edge.ok === true;
  events.push(await recordDerivedGate(env, "beta-release-day", dayKey, "production-daily", betaPass, observedAt, {
    releaseId: release.id,
    publishedAt: release.published_at,
    edge,
    shadowPass,
  }));

  const browserRows = await env.DB.prepare(
    `WITH ranked AS (
       SELECT source.id AS source_id, batch.id AS batch_id, batch.coverage_mode,
              batch.captured_to, batch.status,
              ROW_NUMBER() OVER (PARTITION BY source.id ORDER BY batch.captured_to DESC, batch.id DESC) AS ordinal
         FROM capture_sources source
         JOIN capture_batches batch ON batch.source_id = source.id
        WHERE source.id IN (${REQUIRED_BROWSER_SOURCES.map((_, index) => `?${index + 1}`).join(",")})
          AND batch.status IN ('promoted','superseded')
          AND date(batch.captured_to, ?5) BETWEEN ?6 AND ?7
     )
     SELECT ranked.*,
            EXISTS (SELECT 1 FROM evidence_objects evidence WHERE evidence.batch_id = ranked.batch_id AND evidence.kind = 'screenshot') AS has_screenshot,
            EXISTS (SELECT 1 FROM match_runs matching WHERE matching.batch_id = ranked.batch_id AND matching.status = 'passed') AS has_match
       FROM ranked WHERE ordinal = 1 ORDER BY source_id`,
  ).bind(...REQUIRED_BROWSER_SOURCES, sqlModifier, weekKey, addCalendarDays(weekKey, 6)).all<{
    source_id: string; batch_id: string; coverage_mode: string; captured_to: string; status: string; has_screenshot: number; has_match: number;
  }>();
  const chromePass = browserRows.results.length === REQUIRED_BROWSER_SOURCES.length
    && browserRows.results.every((row) => ["full", "partial"].includes(row.coverage_mode) && row.has_screenshot === 1 && row.has_match === 1);
  events.push(await recordDerivedGate(env, "direct-chrome-week", weekKey, "required-browser-sources", chromePass, observedAt, {
    requiredSources: REQUIRED_BROWSER_SOURCES,
    batches: browserRows.results,
  }));

  const accuracy = await env.DB.prepare(
    `SELECT draw.id, draw.sampled_count, draw.completed_at,
            COUNT(verdict.id) AS verdict_count
       FROM accuracy_draws draw LEFT JOIN operator_verdicts verdict ON verdict.draw_id = draw.id
      WHERE draw.status = 'completed' AND date(draw.completed_at, ?1) BETWEEN ?2 AND ?3
      GROUP BY draw.id, draw.sampled_count, draw.completed_at
      ORDER BY draw.completed_at DESC LIMIT 1`,
  ).bind(sqlModifier, weekKey, addCalendarDays(weekKey, 6)).first<{ id: string; sampled_count: number; completed_at: string; verdict_count: number }>();
  const accuracyPass = Boolean(accuracy && accuracy.sampled_count === 100 && accuracy.verdict_count === accuracy.sampled_count);
  events.push(await recordDerivedGate(env, "accuracy-week", weekKey, "blind-n100", accuracyPass, observedAt, { draw: accuracy ?? null }));

  const closedWeek = addCalendarDays(weekKey, -7);
  const closedEnd = addCalendarDays(closedWeek, 6);
  const closedCounts = await env.DB.prepare(
    `SELECT gate, COUNT(DISTINCT period_key) AS count
       FROM evidence_gate_events
      WHERE status = 'pass' AND (
        (gate = 'beta-release-day' AND period_key BETWEEN ?1 AND ?2)
        OR (gate IN ('direct-chrome-week','accuracy-week') AND period_key = ?1)
      ) GROUP BY gate`,
  ).bind(closedWeek, closedEnd).all<{ gate: string; count: number }>();
  const counts = Object.fromEntries(closedCounts.results.map((row) => [row.gate, row.count]));
  const betaWeekPass = counts["beta-release-day"] === 7 && counts["direct-chrome-week"] === 1 && counts["accuracy-week"] === 1;
  events.push(await recordDerivedGate(env, "beta-week", closedWeek, "closed-production-week", betaWeekPass, observedAt, {
    weekEnd: closedEnd,
    betaReleaseDays: counts["beta-release-day"] ?? 0,
    directChromeWeek: counts["direct-chrome-week"] ?? 0,
    accuracyWeek: counts["accuracy-week"] ?? 0,
  }));

  return { ok: events.every((event) => event.status === "pass" || event.gate === "beta-week"), observedAt, dayKey, weekKey, releaseId: release.id, events };
}

export async function milestoneEvidenceSummary(db: D1Database): Promise<Record<string, unknown>> {
  const rows = await db.prepare(
    `SELECT gate, period_key, status FROM evidence_gate_events
      WHERE status = 'pass' ORDER BY gate, period_key`,
  ).all<{ gate: string; period_key: string; status: string }>();
  const byGate = new Map<string, string[]>();
  for (const row of rows.results) {
    const values = byGate.get(row.gate) ?? [];
    values.push(row.period_key);
    byGate.set(row.gate, values);
  }
  const entitlementStates = await db.prepare(
    "SELECT DISTINCT state FROM entitlement_verifications WHERE status = 'pass' ORDER BY state",
  ).all<{ state: string }>();
  const definitions = [
    { gate: "shadow-ingest-day", required: 14, consecutive: true },
    { gate: "semantic-parity-day", required: 14, consecutive: true },
    { gate: "direct-chrome-week", required: 4, consecutive: false },
    { gate: "beta-release-day", required: 30, consecutive: true },
    { gate: "beta-week", required: 4, consecutive: false },
    { gate: "accuracy-week", required: 4, consecutive: false },
    { gate: "chaos-drill", required: 4, consecutive: false },
    { gate: "route-rollback", required: 1, consecutive: false },
  ];
  const gates = definitions.map((definition) => {
    const periods = [...new Set(byGate.get(definition.gate) ?? [])];
    const achieved = definition.consecutive ? consecutiveDateCount(periods) : periods.length;
    return { ...definition, achieved, complete: achieved >= definition.required, periods };
  });
  const requiredEntitlements = ["anonymous", "free", "paid", "expired", "cancelled", "signed_out", "cookie_expired"];
  const states = entitlementStates.results.map((row) => row.state);
  return {
    complete: gates.every((gate) => gate.complete) && requiredEntitlements.every((state) => states.includes(state)),
    gates,
    entitlements: { required: requiredEntitlements, verified: states, complete: requiredEntitlements.every((state) => states.includes(state)) },
  };
}
