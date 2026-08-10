import { assertObservationArithmetic, deterministicId, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

type ServerChaosKind = "run-interruption" | "wrong-basis" | "referenced-commodity-delete";

async function recordChaos(env: WorkerEnv, kind: ServerChaosKind, passed: boolean, evidence: Record<string, unknown>): Promise<string> {
  const observedAt = new Date().toISOString();
  const periodKey = `${kind}-${observedAt.slice(0, 10)}`;
  const eventId = await deterministicId("evidence", "chaos-drill", periodKey);
  await env.DB.prepare(
    `INSERT INTO evidence_gate_events (id, gate, period_key, source_ref, status, evidence_json, observed_at)
     VALUES (?1, 'chaos-drill', ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT(gate, period_key, source_ref) DO UPDATE SET
       status = excluded.status, evidence_json = excluded.evidence_json, observed_at = excluded.observed_at`,
  ).bind(eventId, periodKey, kind, passed ? "pass" : "fail", stableJson(evidence), observedAt).run();
  return eventId;
}

async function runInterruption(env: WorkerEnv): Promise<Record<string, unknown>> {
  const before = await env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'").first<{ release_id: string }>();
  if (!before) throw new Error("run-interruption drill requires a current release");
  const suffix = crypto.randomUUID();
  const job = `chaos-run-interruption-${suffix}`;
  const runId = `run_chaos_interruption_${suffix}`;
  const startedAt = new Date().toISOString();
  await env.DB.prepare(
    `INSERT OR IGNORE INTO job_schedules (job, cron, max_gap_minutes, active)
     VALUES (?1, '0 0 1 1 *', 525600, 0)`,
  ).bind(job).run();
  await env.DB.prepare(
    `INSERT INTO job_runs
       (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, actor_id, input_json)
     VALUES (?1, ?2, 'test', ?3, ?3, ?3, 'started', 'operator:chaos-drill', '{}')`,
  ).bind(runId, job, startedAt).run();
  const finishedAt = new Date().toISOString();
  await env.DB.prepare(
    `UPDATE job_runs SET status = 'timed_out', heartbeat_at = ?2, finished_at = ?2,
            error = 'deliberate V3 interrupted-run drill'
      WHERE id = ?1 AND status = 'started'`,
  ).bind(runId, finishedAt).run();
  const [run, after] = await Promise.all([
    env.DB.prepare("SELECT status, finished_at FROM job_runs WHERE id = ?1").bind(runId).first<{ status: string; finished_at: string }>(),
    env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'").first<{ release_id: string }>(),
  ]);
  const passed = run?.status === "timed_out" && after?.release_id === before.release_id;
  await env.DB.batch([
    env.DB.prepare("DELETE FROM job_runs WHERE id = ?1").bind(runId),
    env.DB.prepare("DELETE FROM job_schedules WHERE job = ?1").bind(job),
  ]);
  return { passed, runId, runStatus: run?.status ?? null, beforeReleaseId: before.release_id, afterReleaseId: after?.release_id ?? null };
}

function wrongBasis(): Record<string, unknown> {
  let rejection: string | null = null;
  try {
    assertObservationArithmetic({
      externalProductKey: "chaos-wrong-basis",
      name: "Wrong basis fixture",
      sizeText: "16 oz",
      package: {},
      kind: "everyday",
      currency: "USD",
      purchasePriceMinor: 400,
      purchaseQuantity: 1,
      packageCount: 1,
      capturedBasisUnit: "oz",
      capturedBasisQtyMicros: 16_000_000,
      normalizedBasisUnit: "oz",
      normalizedBasisQtyMicros: 16_000_000,
      perUnitMicros: 4_000_000,
      loyaltyRequired: false,
      membershipRequired: false,
      rawPriceText: "$4.00",
      rawSizeText: "16 oz",
      capturedAt: new Date().toISOString(),
    });
  } catch (error) {
    rejection = error instanceof Error ? error.message : "unknown arithmetic rejection";
  }
  return { passed: Boolean(rejection?.includes("per-unit mismatch")), rejection, boundary: "assertObservationArithmetic used by insertObservations" };
}

async function referencedCommodityDelete(env: WorkerEnv): Promise<Record<string, unknown>> {
  const suffix = crypto.randomUUID().replaceAll("-", "");
  const configurationId = `cfg_chaos_${suffix}`;
  const categoryId = `category_chaos_${suffix}`;
  const commodityId = `commodity-chaos-${suffix}`;
  const rulingId = `wrong_chaos_${suffix}`;
  const contentHash = suffix.padEnd(64, "0").slice(0, 64);
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO configuration_versions (id, source_commit, content_hash, active) VALUES (?1, 'chaos-drill', ?2, 0)",
    ).bind(configurationId, contentHash),
    env.DB.prepare("INSERT INTO categories (id, label, sort_order) VALUES (?1, 'Chaos drill', 999999)").bind(categoryId),
    env.DB.prepare(
      "INSERT INTO commodities (id, configuration_id, label, basis_unit, category_id, active) VALUES (?1, ?2, 'Chaos fixture', 'each', ?3, 1)",
    ).bind(commodityId, configurationId, categoryId),
    env.DB.prepare(
      `INSERT INTO known_wrong_rules
         (id, configuration_id, commodity_id, normalized_name, ruling, evidence)
       VALUES (?1, ?2, ?3, 'chaos fixture', 'deliberate foreign-key reference', 'controlled production drill')`,
    ).bind(rulingId, configurationId, commodityId),
  ]);
  let rejection: string | null = null;
  try {
    await env.DB.prepare("DELETE FROM commodities WHERE id = ?1 AND configuration_id = ?2").bind(commodityId, configurationId).run();
  } catch (error) {
    rejection = error instanceof Error ? error.message : "unknown delete rejection";
  }
  const retained = await env.DB.prepare(
    "SELECT id FROM commodities WHERE id = ?1 AND configuration_id = ?2",
  ).bind(commodityId, configurationId).first();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM known_wrong_rules WHERE id = ?1").bind(rulingId),
    env.DB.prepare("DELETE FROM commodities WHERE id = ?1 AND configuration_id = ?2").bind(commodityId, configurationId),
    env.DB.prepare("DELETE FROM categories WHERE id = ?1").bind(categoryId),
    env.DB.prepare("DELETE FROM configuration_versions WHERE id = ?1").bind(configurationId),
  ]);
  return { passed: Boolean(rejection && retained), rejection, retainedBeforeCleanup: Boolean(retained), fixtureConfigurationId: configurationId };
}

export async function runServerChaosDrill(env: WorkerEnv, kind: string): Promise<Record<string, unknown>> {
  let result: Record<string, unknown>;
  if (kind === "run-interruption") result = await runInterruption(env);
  else if (kind === "wrong-basis") result = wrongBasis();
  else if (kind === "referenced-commodity-delete") result = await referencedCommodityDelete(env);
  else throw new Error("unknown chaos drill; use run-interruption, wrong-basis, or referenced-commodity-delete");
  const eventId = await recordChaos(env, kind as ServerChaosKind, result.passed === true, result);
  return { ok: result.passed === true, kind, eventId, ...result };
}
