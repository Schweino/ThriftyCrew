import { deterministicId, stableJson } from "@thriftycrew/domain";
import type { MutationIdentity, WorkerEnv } from "./env";
import { readBrowserCaptureSla } from "./browser-capture-sla";
import { compactConfiguration } from "./configuration-archive";

export function jobStatusRequiresAlert(status: string): boolean {
  return status === "failed" || status === "timed_out" || status === "missed";
}

export function archivalCapacityStatus(usagePercentMillis: number, projectedLimitAt: string | null, observedAt: string): "healthy" | "armed" | "critical" {
  const projectedDays = projectedLimitAt ? (Date.parse(projectedLimitAt) - Date.parse(observedAt)) / 86_400_000 : Number.POSITIVE_INFINITY;
  if (usagePercentMillis >= 90_000 || projectedDays <= 30) return "critical";
  if (usagePercentMillis >= 70_000 || projectedDays <= 180) return "armed";
  return "healthy";
}

export function robustMonthlyGrowth(history: Array<{ database_bytes: number; observed_at: string }>, currentBytes: number, observedAt: string): number {
  const points = [...history, { database_bytes: currentBytes, observed_at: observedAt }]
    .filter((point) => Number.isFinite(Date.parse(point.observed_at)))
    .sort((left, right) => Date.parse(left.observed_at) - Date.parse(right.observed_at));
  const dailyRates: number[] = [];
  for (let index = 1; index < points.length; index += 1) {
    const previous = points[index - 1]!;
    const current = points[index]!;
    const days = (Date.parse(current.observed_at) - Date.parse(previous.observed_at)) / 86_400_000;
    if (days > 0) dailyRates.push((current.database_bytes - previous.database_bytes) / days);
  }
  const positive = dailyRates.filter((rate) => rate > 0).sort((left, right) => left - right);
  if (positive.length === 0) return 0;
  const middle = Math.floor(positive.length / 2);
  const median = positive.length % 2 ? positive[middle]! : (positive[middle - 1]! + positive[middle]!) / 2;
  return Math.round(median * 30);
}

export function controlPlaneProofPass(checks: ReadonlyArray<{ required: boolean; ok: boolean }>): boolean {
  return checks.every((check) => !check.required || check.ok);
}

export async function runControlPlaneProof(env: WorkerEnv, scheduledTime: number): Promise<void> {
  const observedAt = new Date(scheduledTime).toISOString();
  const day = observedAt.slice(0, 10);
  const proofId = await deterministicId("control-plane-proof", day);
  const existing = await env.DB.prepare("SELECT status FROM control_plane_proofs WHERE id = ?1").bind(proofId).first();
  if (existing) return;
  const [configuration, release, hardGuards, recipeIssues, backup, orphanExecutions, capacity, browser] = await Promise.all([
    env.DB.prepare(
      `SELECT version.id, version.content_hash, archive.status AS archive_status
         FROM configuration_versions version LEFT JOIN configuration_archives archive ON archive.configuration_id = version.id
        WHERE version.active = 1`,
    ).first<{ id: string; content_hash: string; archive_status: string | null }>(),
    env.DB.prepare(
      `SELECT release.id, release.configuration_id, release.published_at
         FROM current_releases current JOIN releases release ON release.id = current.release_id
        WHERE current.market_id = 'omaha'`,
    ).first<{ id: string; configuration_id: string; published_at: string }>(),
    env.DB.prepare(
      `SELECT COUNT(*) AS count FROM guard_results result
        JOIN guard_definitions definition ON definition.id = result.guard_id
        JOIN current_releases current ON current.release_id = result.release_id
       WHERE definition.severity = 'hard' AND result.status <> 'pass'`,
    ).first<{ count: number }>(),
    env.DB.prepare(
      `SELECT COUNT(*) AS count FROM release_recipe_costs cost
        JOIN current_releases current ON current.release_id = cost.release_id
       WHERE cost.status <> 'complete'`,
    ).first<{ count: number }>(),
    env.DB.prepare(
      `SELECT id, finished_at FROM backup_exports
        WHERE status = 'completed' AND finished_at >= datetime(?1, '-36 hours')
        ORDER BY finished_at DESC LIMIT 1`,
    ).bind(observedAt).first<{ id: string; finished_at: string }>(),
    env.DB.prepare(
      `SELECT run.id, run.job, run.started_at FROM job_runs run JOIN job_schedules schedule ON schedule.job = run.job
        WHERE run.status = 'started' AND COALESCE(schedule.authority_executor, schedule.executor) IN ('pc','cloudflare-workflow')
          AND NOT EXISTS (
            SELECT 1 FROM operation_leases lease
             WHERE lease.holder_id = run.id AND lease.released_at IS NULL AND lease.expires_at > ?1
          )`,
    ).bind(observedAt).all(),
    env.DB.prepare("SELECT status, projected_limit_at, usage_percent_millis, observed_at FROM archival_forecasts ORDER BY observed_at DESC LIMIT 1").first<{ status: string; projected_limit_at: string | null; usage_percent_millis: number; observed_at: string }>(),
    readBrowserCaptureSla(env.DB, new Date(scheduledTime)),
  ]);
  const checks = [
    { id: "configuration-archive", required: true, ok: configuration?.archive_status === "verified", detail: configuration ?? null },
    { id: "release-pointer", required: true, ok: Boolean(release && configuration && release.configuration_id === configuration.id), detail: release ?? null },
    { id: "hard-guards", required: true, ok: (hardGuards?.count ?? 1) === 0, detail: hardGuards ?? null },
    { id: "recipe-costs", required: true, ok: (recipeIssues?.count ?? 1) === 0, detail: recipeIssues ?? null },
    { id: "backup-rpo", required: true, ok: Boolean(backup), detail: backup ?? null },
    { id: "execution-fencing", required: true, ok: orphanExecutions.results.length === 0, detail: orphanExecutions.results },
    { id: "d1-capacity", required: true, ok: capacity?.status !== "critical", detail: capacity ?? null },
    { id: "browser-capture", required: browser.enforced && browser.deadlineExpired, ok: browser.ready, detail: browser },
  ];
  const status = controlPlaneProofPass(checks) ? "pass" : "fail";
  await env.DB.prepare(
    `INSERT INTO control_plane_proofs (id, status, source_commit, checks_json, observed_at)
     VALUES (?1, ?2, ?3, ?4, ?5)`,
  ).bind(proofId, status, env.DEPLOYED_COMMIT ?? "unknown", stableJson(checks), observedAt).run();
  if (status === "fail") await raiseOperationalAlert(env, "control-plane-proof", "Daily cross-plane proof failed", { proofId, checks }, { notification: "digest", deferMinutes: 15, observedAt });
  else await resolveOperationalAlert(env, "control-plane-proof", { proofId, checks }, { recoveryTitle: "Daily cross-plane proof recovered" });
}

export async function runConfigurationLifecycle(env: WorkerEnv, scheduledTime: number): Promise<void> {
  const observedAt = new Date(scheduledTime).toISOString();
  const runId = await deterministicId("run", "configuration-lifecycle-daily", observedAt.slice(0, 10));
  const existing = await env.DB.prepare("SELECT status FROM job_runs WHERE id = ?1").bind(runId).first<{ status: string }>();
  if (existing?.status === "completed") return;
  await env.DB.prepare(
    `INSERT INTO job_runs (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, actor_id, input_json)
     VALUES (?1, 'configuration-lifecycle-daily', 'schedule', ?2, ?2, ?2, 'started', 'cloudflare:scheduled', '{}')
     ON CONFLICT(id) DO UPDATE SET started_at = ?2, heartbeat_at = ?2, finished_at = NULL, status = 'started', error = NULL`,
  ).bind(runId, observedAt).run();
  try {
    const candidates = await env.DB.prepare(
      `SELECT version.id FROM configuration_versions version
        JOIN configuration_archives archive ON archive.configuration_id = version.id AND archive.status = 'verified'
       WHERE version.active = 0
         AND NOT EXISTS (SELECT 1 FROM configuration_compactions compacted WHERE compacted.configuration_id = version.id)
         AND version.id <> COALESCE((
           SELECT release.configuration_id FROM releases release
            WHERE release.state IN ('published','superseded')
              AND release.configuration_id <> COALESCE((SELECT id FROM configuration_versions WHERE active = 1), '')
            ORDER BY release.published_at DESC LIMIT 1
         ), '')
       ORDER BY version.deployed_at LIMIT 3`,
    ).all<{ id: string }>();
    const compacted: Array<Record<string, unknown>> = [];
    for (const candidate of candidates.results) compacted.push(await compactConfiguration(env, candidate.id, "cloudflare:scheduled"));
    const finishedAt = new Date().toISOString();
    await env.DB.prepare("UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3 WHERE id = ?1")
      .bind(runId, finishedAt, stableJson({ candidates: candidates.results.length, compacted })).run();
    await resolveOperationalAlert(env, "configuration-lifecycle", { runId, compacted });
  } catch (error) {
    const message = error instanceof Error ? error.message : "configuration lifecycle failed";
    const finishedAt = new Date().toISOString();
    await env.DB.prepare("UPDATE job_runs SET status = 'failed', heartbeat_at = ?2, finished_at = ?2, error = ?3 WHERE id = ?1")
      .bind(runId, finishedAt, message).run();
    await raiseOperationalAlert(env, "configuration-lifecycle", "Configuration archival lifecycle failed", { runId, error: message }, { notification: "digest", deferMinutes: 15, observedAt });
    throw error;
  }
}

export function scheduleGap(
  latestAt: string | null,
  monitoringStartedAt: string | null,
  checkedAt: number,
  maxGapMinutes: number,
): { stale: boolean; ageMinutes: number | null; basis: "run" | "monitoring-grace" | "unknown" } {
  const latestRun = Date.parse(latestAt ?? "");
  const monitoringStart = Date.parse(monitoringStartedAt ?? "");
  const hasRun = Number.isFinite(latestRun);
  const hasMonitoringStart = Number.isFinite(monitoringStart);
  if (!hasRun && !hasMonitoringStart) return { stale: true, ageMinutes: null, basis: "unknown" };
  const useMonitoringGrace = hasMonitoringStart && (!hasRun || monitoringStart > latestRun);
  const basis = useMonitoringGrace ? "monitoring-grace" : "run";
  const parsed = useMonitoringGrace ? monitoringStart : latestRun;
  const ageMinutes = Math.max(0, Math.floor((checkedAt - parsed) / 60_000));
  return { stale: ageMinutes > maxGapMinutes, ageMinutes, basis };
}

export async function d1DatabaseFileSize(env: WorkerEnv): Promise<number> {
  if (!env.D1_REST_API_TOKEN || !env.CLOUDFLARE_ACCOUNT_ID || !env.D1_DATABASE_ID) {
    throw new Error("D1 database metadata credentials are not configured");
  }
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/d1/database/${env.D1_DATABASE_ID}?fields=file_size`,
    { headers: { authorization: `Bearer ${env.D1_REST_API_TOKEN}` } },
  );
  const body = await response.json() as { success?: boolean; errors?: unknown[]; result?: { file_size?: number } };
  const fileSize = body.result?.file_size;
  if (!response.ok || body.success !== true || typeof fileSize !== "number" || !Number.isFinite(fileSize) || fileSize < 0) {
    throw new Error(`D1 database metadata request failed with ${response.status}: ${stableJson(body.errors ?? [])}`);
  }
  return fileSize;
}

export function githubDispatchInputs(workflowFile: string, job: string, reason: string): Record<string, unknown> {
  if (workflowFile === "platform-agents.yml") return { inputs: { agent_job: job } };
  if (workflowFile === "platform-restore.yml" || workflowFile.startsWith("agent-")) return {};
  return { inputs: { recovery_job: job, recovery_reason: reason } };
}

export function githubActionsDispatchEnabled(env: Pick<WorkerEnv, "GITHUB_ACTIONS_DISPATCH_ENABLED">): boolean {
  return env.GITHUB_ACTIONS_DISPATCH_ENABLED === "1";
}

export async function resolveRecoveredJobRunAlerts(
  env: WorkerEnv,
  job: string,
  recoveryRunId: string,
  observedAt: string,
): Promise<number> {
  const alerts = await env.DB.prepare(
    `SELECT triage.source_ref
       FROM triage_items triage
       JOIN job_runs failed ON failed.id = substr(triage.source_ref, 9)
      WHERE triage.source_kind = 'operational_alert'
        AND triage.source_ref LIKE 'job-run:%'
        AND triage.status <> 'resolved'
        AND failed.job = ?1
        AND failed.status IN ('failed', 'timed_out', 'missed')
        AND failed.id <> ?2`,
  ).bind(job, recoveryRunId).all<{ source_ref: string }>();
  for (const row of alerts.results) {
    await resolveOperationalAlert(env, row.source_ref, {
      resolution: "A later durable run for the same job completed successfully.",
      job,
      recoveryRunId,
      observedAt,
    });
  }
  return alerts.results.length;
}

export async function recordAudit(
  env: WorkerEnv,
  identity: Pick<MutationIdentity, "agentId" | "authMethod">,
  action: string,
  resourceKind: string,
  resourceId: string | null,
  outcome: "accepted" | "rejected" | "failed",
  detail: Record<string, unknown> = {},
): Promise<void> {
  const id = `audit_${crypto.randomUUID()}`;
  await env.DB.prepare(
    `INSERT INTO audit_events
       (id, actor_id, auth_method, action, resource_kind, resource_id, outcome, detail_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  ).bind(id, identity.agentId, identity.authMethod, action, resourceKind, resourceId, outcome, stableJson(detail)).run();
}

async function deliverAlert(env: WorkerEnv, alertKey: string, subject: string, body: string): Promise<"delivered" | "failed" | "suppressed"> {
  if (!env.OPS_ALERT_URL || !env.OPS_ALERT_AUTH) return "suppressed";
  const previous = await env.DB.prepare(
    `SELECT status FROM alert_deliveries
      WHERE alert_key = ?1 AND channel = 'ops-alert' AND created_at > datetime('now', '-6 hours')
      ORDER BY created_at DESC LIMIT 1`,
  ).bind(alertKey).first<{ status: string }>();
  if (previous?.status === "delivered") return "suppressed";
  const attempt = ((await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM alert_deliveries WHERE alert_key = ?1 AND channel = 'ops-alert'",
  ).bind(alertKey).first<{ count: number }>())?.count ?? 0) + 1;
  const id = `alert_${crypto.randomUUID()}`;
  await env.DB.prepare(
    `INSERT INTO alert_deliveries (id, alert_key, channel, status, attempt)
     VALUES (?1, ?2, 'ops-alert', 'started', ?3)`,
  ).bind(id, alertKey, attempt).run();
  try {
    const response = await fetch(env.OPS_ALERT_URL, {
      method: "POST",
      headers: { "content-type": "application/json", "x-notify-auth": env.OPS_ALERT_AUTH },
      body: JSON.stringify({ subject, body }),
    });
    if (!response.ok) throw new Error(`ops alert returned ${response.status}`);
    await env.DB.prepare(
      "UPDATE alert_deliveries SET status = 'delivered', finished_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(id).run();
    return "delivered";
  } catch (error) {
    await env.DB.prepare(
      "UPDATE alert_deliveries SET status = 'failed', detail_json = ?2, finished_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(id, stableJson({ error: error instanceof Error ? error.message : "unknown alert failure" })).run();
    return "failed";
  }
}

export type OperationalNotificationMode = "immediate" | "digest" | "silent";

export interface OperationalAlertOptions {
  notification?: OperationalNotificationMode;
  deferMinutes?: number;
  observedAt?: string;
}

export function operationalNotificationDueAt(observedAt: string, deferMinutes: number): string {
  const timestamp = Date.parse(observedAt);
  if (!Number.isFinite(timestamp) || !Number.isFinite(deferMinutes) || deferMinutes < 0) throw new Error("invalid operational notification delay");
  return new Date(timestamp + deferMinutes * 60_000).toISOString();
}

export function operationalIncidentIsNew(existingStatus: string | null | undefined): boolean {
  return existingStatus === null || existingStatus === undefined || existingStatus === "resolved";
}

export function operationalDigestMemberKey(alertKey: string, notifyAfter: string): string {
  return `${alertKey}@${notifyAfter}`;
}

export async function raiseOperationalAlert(
  env: WorkerEnv,
  alertKey: string,
  title: string,
  evidence: Record<string, unknown>,
  options: OperationalAlertOptions = {},
): Promise<{ triageId: string; delivery: string }> {
  const notification = options.notification ?? "immediate";
  const observedAt = options.observedAt ?? new Date().toISOString();
  let storedEvidence = notification === "digest"
    ? { ...evidence, _notification: { mode: notification, notifyAfter: operationalNotificationDueAt(observedAt, options.deferMinutes ?? 15) } }
    : { ...evidence, ...(notification === "silent" ? { _notification: { mode: notification } } : {}) };
  const triageId = await deterministicId("triage", "operational_alert", alertKey);
  const existing = await env.DB.prepare(
    "SELECT status, evidence_json FROM triage_items WHERE id = ?1 AND source_kind = 'operational_alert'",
  ).bind(triageId).first<{ status: string; evidence_json: string }>();
  const newIncident = operationalIncidentIsNew(existing?.status);
  if (!newIncident && notification === "digest" && existing?.evidence_json) {
    try {
      const prior = JSON.parse(existing.evidence_json) as Record<string, unknown>;
      const priorNotification = prior._notification as Record<string, unknown> | undefined;
      if (priorNotification?.mode === "digest" && typeof priorNotification.notifyAfter === "string") {
        storedEvidence = { ...storedEvidence, _notification: { mode: "digest", notifyAfter: priorNotification.notifyAfter } };
      }
    } catch { /* malformed old evidence is replaced by the validated current shape */ }
  }
  await env.DB.prepare(
    `INSERT INTO triage_items
       (id, source_kind, source_ref, severity, status, title, evidence_json)
     VALUES (?1, 'operational_alert', ?2, 'hard', 'open', ?3, ?4)
     ON CONFLICT(source_ref) DO UPDATE SET
       status = CASE WHEN triage_items.status = 'resolved' THEN 'open' ELSE triage_items.status END,
       title = excluded.title, evidence_json = excluded.evidence_json,
       updated_at = CASE WHEN triage_items.status = 'resolved' THEN CURRENT_TIMESTAMP ELSE triage_items.updated_at END,
       resolved_at = CASE WHEN triage_items.status = 'resolved' THEN NULL ELSE triage_items.resolved_at END`,
  ).bind(triageId, alertKey, title, stableJson(storedEvidence)).run();
  const delivery = notification === "immediate"
    ? newIncident ? await deliverAlert(env, alertKey, title, stableJson(evidence)) : "suppressed"
    : notification === "digest" ? "deferred" : "suppressed";
  return { triageId, delivery };
}

export interface OperationalResolutionOptions {
  recoveryTitle?: string;
}

export async function resolveOperationalAlert(
  env: WorkerEnv,
  alertKey: string,
  evidence: Record<string, unknown>,
  options: OperationalResolutionOptions = {},
): Promise<{ triageId: string; resolved: boolean; idempotent: boolean; recoveryDelivery?: string }> {
  const triageId = await deterministicId("triage", "operational_alert", alertKey);
  const existing = await env.DB.prepare(
    "SELECT status, updated_at, evidence_json FROM triage_items WHERE id = ?1 AND source_kind = 'operational_alert'",
  ).bind(triageId).first<{ status: string; updated_at: string; evidence_json: string }>();
  if (!existing || existing.status === "resolved") return { triageId, resolved: Boolean(existing), idempotent: true };
  await env.DB.prepare(
    `UPDATE triage_items
        SET status = 'resolved', resolution_json = ?2, updated_at = CURRENT_TIMESTAMP,
            resolved_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND status <> 'resolved'`,
  ).bind(triageId, stableJson(evidence)).run();
  let recoveryDelivery: string | undefined;
  if (options.recoveryTitle) {
    let digestMemberKey = "";
    try {
      const prior = JSON.parse(existing.evidence_json) as { _notification?: { notifyAfter?: unknown } };
      if (typeof prior._notification?.notifyAfter === "string") {
        digestMemberKey = operationalDigestMemberKey(alertKey, prior._notification.notifyAfter);
      }
    } catch { /* malformed legacy evidence has no digest membership key */ }
    const previouslyNotified = await env.DB.prepare(
      `SELECT 1 AS found FROM alert_deliveries
        WHERE status = 'delivered' AND channel IN ('ops-alert', 'ops-digest-member')
          AND ((alert_key = ?1 AND created_at >= ?2) OR (?3 <> '' AND alert_key = ?3)) LIMIT 1`,
    ).bind(alertKey, existing.updated_at, digestMemberKey).first<{ found: number }>();
    if (previouslyNotified) recoveryDelivery = await deliverAlert(env, `${alertKey}:recovered`, options.recoveryTitle, stableJson(evidence));
  }
  return { triageId, resolved: true, idempotent: false, ...(recoveryDelivery ? { recoveryDelivery } : {}) };
}

export async function flushOperationalAlertDigest(env: WorkerEnv, observedAt = new Date().toISOString()): Promise<{ due: number; delivery: string; membersRecorded: number }> {
  const due = await env.DB.prepare(
    `SELECT t.id, t.source_ref, t.title, t.evidence_json,
            json_extract(t.evidence_json, '$._notification.notifyAfter') AS notify_after
       FROM triage_items t
      WHERE t.source_kind = 'operational_alert' AND t.status <> 'resolved'
        AND json_extract(t.evidence_json, '$._notification.mode') = 'digest'
        AND json_extract(t.evidence_json, '$._notification.notifyAfter') <= ?1
        AND NOT EXISTS (
          SELECT 1 FROM alert_deliveries d
           WHERE d.channel IN ('ops-alert', 'ops-digest-member') AND d.status = 'delivered'
             AND (
               d.alert_key = t.source_ref || '@' || json_extract(t.evidence_json, '$._notification.notifyAfter')
               OR (d.alert_key = t.source_ref AND d.created_at >= datetime(json_extract(t.evidence_json, '$._notification.notifyAfter')))
             )
        )
      ORDER BY t.created_at, t.id LIMIT 100`,
  ).bind(observedAt).all<{ id: string; source_ref: string; title: string; evidence_json: string; notify_after: string }>();
  if (due.results.length === 0) return { due: 0, delivery: "suppressed", membersRecorded: 0 };
  const incidents = due.results.map((row) => {
    let evidence: Record<string, unknown> = {};
    try {
      evidence = JSON.parse(row.evidence_json) as Record<string, unknown>;
    } catch {
      evidence = { parseError: true };
    }
    delete evidence._notification;
    return { key: row.source_ref, title: row.title, evidence };
  });
  const digestKey = await deterministicId("operational-digest", observedAt, stableJson(incidents.map((incident) => incident.key)));
  const delivery = await deliverAlert(env, digestKey, `ThriftyCrew alert digest: ${incidents.length} unresolved`, stableJson({ observedAt, incidents }));
  if (delivery !== "delivered") return { due: incidents.length, delivery, membersRecorded: 0 };
  for (const row of due.results) {
    const memberKey = operationalDigestMemberKey(row.source_ref, row.notify_after);
    const memberId = await deterministicId("alert-digest-member", memberKey);
    await env.DB.prepare(
      `INSERT OR IGNORE INTO alert_deliveries
         (id, alert_key, channel, status, attempt, detail_json, finished_at)
       VALUES (?1, ?2, 'ops-digest-member', 'delivered', 1, ?3, CURRENT_TIMESTAMP)`,
    ).bind(memberId, memberKey, stableJson({ digestKey, observedAt, sourceRef: row.source_ref, notifyAfter: row.notify_after })).run();
  }
  return { due: incidents.length, delivery, membersRecorded: incidents.length };
}

export async function dispatchGithubJob(
  env: WorkerEnv,
  job: string,
  reason: string,
  idempotencyKey: string,
  ref = "main",
): Promise<{ dispatchId: string; status: "dispatched" | "failed" | "suppressed"; idempotent: boolean }> {
  const existing = await env.DB.prepare(
    "SELECT id, status FROM watchdog_dispatches WHERE idempotency_key = ?1",
  ).bind(idempotencyKey).first<{ id: string; status: "dispatched" | "failed" | "suppressed" }>();
  if (existing) return { dispatchId: existing.id, status: existing.status, idempotent: true };
  const dispatchId = `dispatch_${crypto.randomUUID()}`;
  const schedule = await env.DB.prepare("SELECT workflow_file FROM job_schedules WHERE job = ?1 AND active = 1")
    .bind(job).first<{ workflow_file: string | null }>();
  const workflowFile = (schedule?.workflow_file ?? env.GITHUB_WORKFLOW_FILE)?.split("/").at(-1);
  await env.DB.prepare(
    `INSERT INTO watchdog_dispatches (id, job, idempotency_key, reason, status)
     VALUES (?1, ?2, ?3, ?4, 'started')`,
  ).bind(dispatchId, job, idempotencyKey, reason).run();
  if (!githubActionsDispatchEnabled(env)) {
    await env.DB.prepare(
      "UPDATE watchdog_dispatches SET status = 'suppressed', detail_json = ?2, finished_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(dispatchId, stableJson({ reason: "automatic GitHub Actions dispatch is disabled; local execution is authoritative" })).run();
    return { dispatchId, status: "suppressed", idempotent: false };
  }
  if (!env.GITHUB_DISPATCH_TOKEN || !env.GITHUB_REPOSITORY || !workflowFile) {
    const detail = { error: "GitHub recovery dispatch is not configured" };
    await env.DB.prepare(
      "UPDATE watchdog_dispatches SET status = 'failed', detail_json = ?2, finished_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(dispatchId, stableJson(detail)).run();
    await raiseOperationalAlert(env, `dispatch-unconfigured:${job}`, `Recovery dispatch is not configured for ${job}`, detail);
    return { dispatchId, status: "failed", idempotent: false };
  }
  try {
    const response = await fetch(
      `https://api.github.com/repos/${env.GITHUB_REPOSITORY}/actions/workflows/${workflowFile}/dispatches`,
      {
        method: "POST",
        headers: {
          accept: "application/vnd.github+json",
          authorization: `Bearer ${env.GITHUB_DISPATCH_TOKEN}`,
          "content-type": "application/json",
          "user-agent": "tc-grocery-v3-watchdog",
          "x-github-api-version": "2022-11-28",
        },
        body: JSON.stringify({
          ref,
          ...githubDispatchInputs(workflowFile, job, reason),
        }),
      },
    );
    if (response.status !== 204) throw new Error(`GitHub workflow dispatch returned ${response.status}`);
    await env.DB.prepare(
      "UPDATE watchdog_dispatches SET status = 'dispatched', finished_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(dispatchId).run();
    return { dispatchId, status: "dispatched", idempotent: false };
  } catch (error) {
    const detail = { error: error instanceof Error ? error.message : "unknown dispatch failure" };
    await env.DB.prepare(
      "UPDATE watchdog_dispatches SET status = 'failed', detail_json = ?2, finished_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(dispatchId, stableJson(detail)).run();
    await raiseOperationalAlert(env, `dispatch-failed:${job}`, `Recovery dispatch failed for ${job}`, detail);
    return { dispatchId, status: "failed", idempotent: false };
  }
}

export async function dispatchRegisteredAgent(env: WorkerEnv, agentId: string): Promise<{ dispatched: boolean; workflowFile: string; reason?: string }> {
  const row = await env.DB.prepare(
    "SELECT workflow_ref, plane FROM agent_registry WHERE id = ?1 AND active = 1 AND enabled = 1",
  ).bind(agentId).first<{ workflow_ref: string | null; plane: string }>();
  const match = row?.workflow_ref?.match(/\/\.github\/workflows\/([^@]+)@/);
  const workflowFile = match?.[1];
  if (!workflowFile) throw new Error("registered agent workflow is not configured");
  if (row?.plane === "pc") return { dispatched: false, workflowFile, reason: "PC execution plane is authoritative" };
  if (!githubActionsDispatchEnabled(env)) return { dispatched: false, workflowFile, reason: "automatic GitHub Actions dispatch is disabled" };
  if (!env.GITHUB_DISPATCH_TOKEN || !env.GITHUB_REPOSITORY) throw new Error("registered agent dispatch is not configured");
  const response = await fetch(`https://api.github.com/repos/${env.GITHUB_REPOSITORY}/actions/workflows/${encodeURIComponent(workflowFile)}/dispatches`, {
    method: "POST",
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${env.GITHUB_DISPATCH_TOKEN}`,
      "content-type": "application/json",
      "user-agent": "tc-grocery-v3-agent-chain",
      "x-github-api-version": "2022-11-28",
    },
    body: JSON.stringify({ ref: "main" }),
  });
  if (!response.ok) throw new Error(`registered agent dispatch returned ${response.status}`);
  return { dispatched: true, workflowFile };
}

async function dispatchPendingRegisteredAgents(env: WorkerEnv): Promise<void> {
  const queued = await env.DB.prepare(
    `SELECT DISTINCT agent_id FROM agent_work_items
      WHERE state IN ('queued', 'retryable') AND available_at <= CURRENT_TIMESTAMP
     UNION
     SELECT 'triage-developer' AS agent_id FROM triage_items triage
      WHERE triage.status = 'planned' AND NOT EXISTS (
        SELECT 1 FROM agent_work_items work
         WHERE work.agent_id = 'triage-developer' AND work.source_ref = triage.id
           AND work.state IN ('leased', 'completed')
      )`,
  ).all<{ agent_id: string }>();
  for (const row of queued.results) {
    try {
      const dispatch = await dispatchRegisteredAgent(env, row.agent_id);
      await resolveOperationalAlert(env, `agent-dispatch:${row.agent_id}`, {
        agentId: row.agent_id,
        ...dispatch,
        resolution: dispatch.dispatched ? "Registered agent dispatch succeeded." : "The authoritative execution plane does not require GitHub dispatch.",
      });
    } catch (error) {
      await raiseOperationalAlert(env, `agent-dispatch:${row.agent_id}`, `Registered agent dispatch failed for ${row.agent_id}`, {
        agentId: row.agent_id,
        error: error instanceof Error ? error.message : "unknown dispatch failure",
      });
    }
  }
}

interface GithubWorkflowRunResponse {
  workflow_runs?: Array<{
    id?: number;
    event?: string;
    status?: string;
    conclusion?: string | null;
    head_sha?: string;
    created_at?: string;
    updated_at?: string;
    html_url?: string;
  }>;
}

interface GithubWorkflowJobsResponse {
  jobs?: Array<{
    id?: number;
    name?: string;
    status?: string;
    conclusion?: string | null;
    started_at?: string;
    completed_at?: string | null;
    steps?: Array<{
      name?: string;
      status?: string;
      conclusion?: string | null;
      number?: number;
    }>;
  }>;
}

interface GithubAnnotationResponse {
  path?: string;
  start_line?: number;
  end_line?: number;
  annotation_level?: string;
  title?: string | null;
  message?: string;
}

async function githubJson<T>(env: WorkerEnv, url: string): Promise<T> {
  const response = await fetch(url, {
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${env.GITHUB_DISPATCH_TOKEN}`,
      "user-agent": "tc-grocery-v3-operator",
      "x-github-api-version": "2022-11-28",
    },
  });
  if (!response.ok) throw new Error(`GitHub Actions API returned ${response.status}`);
  return response.json<T>();
}

async function githubText(env: WorkerEnv, url: string): Promise<string> {
  const response = await fetch(url, {
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${env.GITHUB_DISPATCH_TOKEN}`,
      "user-agent": "tc-grocery-v3-operator",
      "x-github-api-version": "2022-11-28",
    },
  });
  if (!response.ok) throw new Error(`GitHub Actions log API returned ${response.status}`);
  return response.text();
}

function sanitizedDiagnosticTail(log: string): string[] {
  const lines = log
    .replaceAll(/\x1B\[[0-?]*[ -/]*[@-~]/g, "")
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => line
      .replaceAll(/(github_pat_|gh[pousr]_)[A-Za-z0-9_]+/gi, "$1[REDACTED]")
      .replaceAll(/(authorization:\s*(?:bearer|token)\s+)[^\s]+/gi, "$1[REDACTED]")
      .replaceAll(/((?:secret|token|password|TC_LOCAL_MUTATION_SECRET)\s*[=:]\s*)[^\s]+/gi, "$1[REDACTED]")
      .slice(0, 600));
  if (lines.length <= 60) return lines;

  // GitHub jobs often emit a long cleanup sequence after the useful failure. Preserve bounded
  // context around strong error signals as well as the final tail so operators see both cause
  // and teardown without exposing an unbounded job log.
  const strongSignal = /##\[error\]|\b(?:fatal|exception|traceback)\b|\[err_[a-z0-9_]+\]|required production date/i;
  const weakSignal = /(?:^|\s)(?:error|failed|failure)(?::|\s|$)/i;
  const contextIndexes = new Set<number>();
  const collectContext = (pattern: RegExp, limit: number) => {
    for (let index = 0; index < lines.length && contextIndexes.size < limit; index += 1) {
      if (!pattern.test(lines[index] ?? "")) continue;
      for (let cursor = Math.max(0, index - 2); cursor <= Math.min(lines.length - 1, index + 2) && contextIndexes.size < limit; cursor += 1) {
        contextIndexes.add(cursor);
      }
    }
  };
  collectContext(strongSignal, 30);
  collectContext(weakSignal, 30);
  for (let index = lines.length - 1; index >= 0 && contextIndexes.size < 60; index -= 1) contextIndexes.add(index);
  return [...contextIndexes].sort((left, right) => left - right).slice(-60).map((index) => lines[index] as string);
}

/**
 * Return a deliberately narrow, log-free view of recent workflow health.
 * This keeps the configured GitHub token inside the Worker while exposing
 * enough step metadata for an operator to diagnose pre-ledger failures.
 */
export async function githubWorkflowRuns(env: WorkerEnv, requestedLimit = 5): Promise<{ runs: Array<Record<string, unknown>> }> {
  if (!env.GITHUB_DISPATCH_TOKEN || !env.GITHUB_REPOSITORY || !env.GITHUB_WORKFLOW_FILE) {
    throw new Error("GitHub Actions inspection is not configured");
  }
  const limit = Math.max(1, Math.min(10, Math.trunc(requestedLimit)));
  const workflow = encodeURIComponent(env.GITHUB_WORKFLOW_FILE);
  const base = `https://api.github.com/repos/${env.GITHUB_REPOSITORY}`;
  const response = await githubJson<GithubWorkflowRunResponse>(env, `${base}/actions/workflows/${workflow}/runs?per_page=${limit}`);
  const runs = await Promise.all((response.workflow_runs ?? []).slice(0, limit).map(async (run) => {
    const jobs = run.id
      ? await githubJson<GithubWorkflowJobsResponse>(env, `${base}/actions/runs/${run.id}/jobs?per_page=20`)
      : { jobs: [] };
    const sanitizedJobs = await Promise.all((jobs.jobs ?? []).map(async (job) => {
      let annotations: GithubAnnotationResponse[] = [];
      let diagnosticTail: string[] = [];
      let diagnosticError: string | null = null;
      if (job.id && job.conclusion === "failure") {
        try {
          annotations = await githubJson<GithubAnnotationResponse[]>(env, `${base}/check-runs/${job.id}/annotations?per_page=50`);
        } catch {
          try {
            diagnosticTail = sanitizedDiagnosticTail(await githubText(env, `${base}/actions/jobs/${job.id}/logs`));
          } catch (error) {
            diagnosticError = error instanceof Error ? error.message : "failed job diagnostics are unavailable";
          }
        }
      }
      return {
        id: job.id ?? null,
        name: job.name ?? null,
        status: job.status ?? null,
        conclusion: job.conclusion ?? null,
        startedAt: job.started_at ?? null,
        completedAt: job.completed_at ?? null,
        steps: (job.steps ?? []).map((step) => ({
          name: step.name ?? null,
          status: step.status ?? null,
          conclusion: step.conclusion ?? null,
          number: step.number ?? null,
        })),
        annotations: annotations.map((annotation) => ({
          path: annotation.path ?? null,
          startLine: annotation.start_line ?? null,
          endLine: annotation.end_line ?? null,
          level: annotation.annotation_level ?? null,
          title: annotation.title ?? null,
          message: annotation.message ?? null,
        })),
        diagnosticTail,
        diagnosticError,
      };
    }));
    return {
      id: run.id ?? null,
      event: run.event ?? null,
      status: run.status ?? null,
      conclusion: run.conclusion ?? null,
      headSha: run.head_sha ?? null,
      createdAt: run.created_at ?? null,
      updatedAt: run.updated_at ?? null,
      url: run.html_url ?? null,
      jobs: sanitizedJobs,
    };
  }));
  return { runs };
}

export async function runLedgerWatchdog(env: WorkerEnv, scheduledTime: number): Promise<void> {
  const scheduledFor = new Date(scheduledTime).toISOString();
  const runId = await deterministicId("run", "ledger-watchdog", scheduledFor);
  await env.DB.prepare(
    `INSERT INTO job_runs
       (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, actor_id, input_json)
     VALUES (?1, 'ledger-watchdog', 'schedule', ?2, ?2, ?2, 'started', 'cloudflare:scheduled', '{}')
     ON CONFLICT(id) DO NOTHING`,
  ).bind(runId, scheduledFor).run();
  const overdueExecutions = await env.DB.prepare(
    `SELECT run.id, run.job, run.started_at, run.lease_resource, run.lease_fence, schedule.lease_minutes
       FROM job_runs run JOIN job_schedules schedule ON schedule.job = run.job
      WHERE run.status = 'started' AND run.id <> ?1
        AND datetime(run.started_at, '+' || schedule.lease_minutes || ' minutes') <= datetime(?2)
        AND NOT EXISTS (
          SELECT 1 FROM operation_leases lease
           WHERE lease.holder_id = run.id AND lease.fence = run.lease_fence
             AND lease.released_at IS NULL AND lease.expires_at > ?2
        )`,
  ).bind(runId, scheduledFor).all<{ id: string; job: string; started_at: string; lease_resource: string | null; lease_fence: number | null; lease_minutes: number }>();
  for (const overdue of overdueExecutions.results) {
    await env.DB.prepare(
      `UPDATE job_runs SET status = 'timed_out', heartbeat_at = ?2, finished_at = ?2,
              error = 'execution exceeded its lease runtime without a current fence'
        WHERE id = ?1 AND status = 'started'`,
    ).bind(overdue.id, scheduledFor).run();
    await raiseOperationalAlert(env, `job-run:${overdue.id}`, `Scheduled job ${overdue.job} timed out`, {
      runId: overdue.id, job: overdue.job, startedAt: overdue.started_at, leaseMinutes: overdue.lease_minutes, checkedAt: scheduledFor,
    }, { notification: "digest", deferMinutes: 15, observedAt: scheduledFor });
  }
  const schedules = await env.DB.prepare(
    `SELECT s.job, s.max_gap_minutes, s.dispatch_on_gap, s.monitoring_started_at,
            MAX(COALESCE(r.heartbeat_at, r.finished_at, r.started_at, r.scheduled_for)) AS latest
       FROM job_schedules s
       LEFT JOIN job_runs r ON r.job = s.job
      WHERE s.active = 1 AND s.job <> 'ledger-watchdog'
      GROUP BY s.job, s.max_gap_minutes, s.dispatch_on_gap, s.monitoring_started_at
      ORDER BY s.job`,
  ).all<{ job: string; max_gap_minutes: number; dispatch_on_gap: number; monitoring_started_at: string | null; latest: string | null }>();
  const stale: string[] = [];
  for (const schedule of schedules.results) {
    const health = scheduleGap(schedule.latest, schedule.monitoring_started_at, scheduledTime, schedule.max_gap_minutes);
    if (!health.stale) {
      await resolveOperationalAlert(env, `schedule-gap:${schedule.job}`, {
        job: schedule.job,
        latest: schedule.latest,
        monitoringStartedAt: schedule.monitoring_started_at,
        ageMinutes: health.ageMinutes,
        maxGapMinutes: schedule.max_gap_minutes,
        basis: health.basis,
        checkedAt: scheduledFor,
      });
      continue;
    }
    stale.push(schedule.job);
    const evidence = { job: schedule.job, latest: schedule.latest, monitoringStartedAt: schedule.monitoring_started_at, ageMinutes: health.ageMinutes, maxGapMinutes: schedule.max_gap_minutes, basis: health.basis, checkedAt: scheduledFor };
    await raiseOperationalAlert(env, `schedule-gap:${schedule.job}`, `Scheduled job ${schedule.job} exceeded its maximum gap`, evidence, { notification: "digest", deferMinutes: 15, observedAt: scheduledFor });
    if (schedule.dispatch_on_gap === 1) {
      const hour = scheduledFor.slice(0, 13).replaceAll(/[^0-9]/g, "");
      await dispatchGithubJob(env, schedule.job, `watchdog gap at ${scheduledFor}`, `watchdog-${schedule.job}-${hour}`);
    }
  }
  await env.DB.prepare(
    `UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3
      WHERE id = ?1 AND status = 'started'`,
  ).bind(runId, new Date().toISOString(), stableJson({ checked: schedules.results.length, stale, timedOut: overdueExecutions.results.map((run) => run.id) })).run();
}

export async function runBrowserCaptureSla(env: WorkerEnv, scheduledTime: number): Promise<void> {
  const observedAt = new Date(scheduledTime).toISOString();
  const runId = await deterministicId("run", "browser-capture-sla", observedAt.slice(0, 13));
  await env.DB.prepare(
    `INSERT INTO job_runs
       (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, actor_id, input_json)
     VALUES (?1, 'browser-capture-sla', 'schedule', ?2, ?2, ?2, 'started', 'cloudflare:scheduled', '{}')
     ON CONFLICT(id) DO UPDATE SET started_at = ?2, heartbeat_at = ?2, finished_at = NULL, status = 'started', error = NULL`,
  ).bind(runId, observedAt).run();
  try {
    const assessment = await readBrowserCaptureSla(env.DB, new Date(scheduledTime));
    if (assessment.ready) {
      await resolveOperationalAlert(env, "browser-capture-sla", { ...assessment, checkedAt: observedAt }, {
        recoveryTitle: "Weekly browser capture SLA recovered",
      });
    } else if (assessment.enforced && assessment.deadlineExpired) {
      await raiseOperationalAlert(env, "browser-capture-sla", "Weekly browser capture SLA missed its retry deadline", {
        ...assessment,
        checkedAt: observedAt,
      }, { notification: "digest", deferMinutes: 15, observedAt });
    }
    await resolveOperationalAlert(env, "browser-capture-sla-monitor", { checkedAt: observedAt, status: "completed" });
    await env.DB.prepare(
      "UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3 WHERE id = ?1",
    ).bind(runId, new Date().toISOString(), stableJson(assessment)).run();
  } catch (error) {
    const message = error instanceof Error ? error.message : "browser capture SLA monitor failed";
    const finishedAt = new Date().toISOString();
    await env.DB.prepare("UPDATE job_runs SET status = 'failed', heartbeat_at = ?2, finished_at = ?2, error = ?3 WHERE id = ?1")
      .bind(runId, finishedAt, message).run();
    await raiseOperationalAlert(env, "browser-capture-sla-monitor", "Browser capture SLA monitor failed", {
      error: message,
      checkedAt: observedAt,
    }, { notification: "digest", deferMinutes: 15, observedAt });
    throw error;
  }
}

export async function runArchivalForecast(env: WorkerEnv, scheduledTime: number, force = false): Promise<void> {
  const observedAt = new Date(scheduledTime).toISOString();
  const runId = await deterministicId("run", "archival-forecast-daily", force ? observedAt : observedAt.slice(0, 10));
  const existing = await env.DB.prepare("SELECT status FROM job_runs WHERE id = ?1").bind(runId).first<{ status: string }>();
  if (existing?.status === "completed") return;
  if (existing) {
    await env.DB.prepare(
      `UPDATE job_runs
          SET scheduled_for = ?2, started_at = ?2, heartbeat_at = ?2, finished_at = NULL,
              status = 'started', error = NULL, actor_id = 'cloudflare:scheduled'
        WHERE id = ?1`,
    ).bind(runId, observedAt).run();
  } else {
    await env.DB.prepare(
      `INSERT INTO job_runs (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, actor_id, input_json)
       VALUES (?1, 'archival-forecast-daily', 'schedule', ?2, ?2, ?2, 'started', 'cloudflare:scheduled', '{}')`,
    ).bind(runId, observedAt).run();
  }
  try {
    const [databaseBytes, observations, protectedRows, history] = await Promise.all([
      d1DatabaseFileSize(env),
      env.DB.prepare("SELECT COUNT(*) AS count, MIN(captured_at) AS oldest FROM observations").first<{ count: number; oldest: string | null }>(),
      env.DB.prepare("SELECT COUNT(DISTINCT observation_id) AS count FROM release_cells WHERE observation_id IS NOT NULL").first<{ count: number }>(),
      env.DB.prepare("SELECT database_bytes, observed_at FROM archival_forecasts ORDER BY observed_at DESC LIMIT 8").all<{ database_bytes: number; observed_at: string }>(),
    ]);
    const databaseLimitBytes = Number(env.D1_DATABASE_LIMIT_BYTES ?? 10 * 1024 * 1024 * 1024);
    const monthlyGrowthBytes = robustMonthlyGrowth(history.results, databaseBytes, observedAt);
    const usagePercentMillis = Math.floor(databaseBytes * 100_000 / databaseLimitBytes);
    const projectedLimitAt = monthlyGrowthBytes > 0
      ? new Date(scheduledTime + Math.max(0, databaseLimitBytes - databaseBytes) / monthlyGrowthBytes * 30 * 86_400_000).toISOString()
      : null;
    const status = archivalCapacityStatus(usagePercentMillis, projectedLimitAt, observedAt);
    const forecastId = await deterministicId("archival-forecast", observedAt);
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO archival_forecasts
           (id, database_bytes, database_limit_bytes, observation_count, monthly_growth_bytes,
            oldest_observation_at, protected_observation_count, threshold_percent, usage_percent_millis,
            projected_limit_at, status, observed_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 70, ?8, ?9, ?10, ?11)`,
      ).bind(forecastId, databaseBytes, databaseLimitBytes, observations?.count ?? 0, monthlyGrowthBytes,
        observations?.oldest ?? null, protectedRows?.count ?? 0, usagePercentMillis, projectedLimitAt, status, observedAt),
      env.DB.prepare("UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3 WHERE id = ?1")
        .bind(runId, new Date().toISOString(), stableJson({ forecastId, databaseBytes, databaseLimitBytes, usagePercentMillis, monthlyGrowthBytes, projectedLimitAt, status })),
    ]);
    if (status !== "healthy") await raiseOperationalAlert(env, "d1-archive-capacity", `D1 archival threshold is ${status}`, { forecastId, databaseBytes, databaseLimitBytes, usagePercentMillis, monthlyGrowthBytes, projectedLimitAt });
    else await resolveOperationalAlert(env, "d1-archive-capacity", { forecastId, databaseBytes, usagePercentMillis, projectedLimitAt });
    await resolveOperationalAlert(env, "schedule-gap:archival-forecast-daily", { forecastId, runId, observedAt, status: "completed" });
    await resolveOperationalAlert(env, `archival-forecast:${observedAt.slice(0, 10)}`, { forecastId, runId, observedAt, status: "completed" });
    await resolveRecoveredJobRunAlerts(env, "archival-forecast-daily", runId, observedAt);
  } catch (error) {
    const message = error instanceof Error ? error.message : "archival forecast failed";
    const finishedAt = new Date().toISOString();
    await env.DB.prepare("UPDATE job_runs SET status = 'failed', heartbeat_at = ?2, finished_at = ?2, error = ?3 WHERE id = ?1")
      .bind(runId, finishedAt, message).run();
    await raiseOperationalAlert(env, `archival-forecast:${observedAt.slice(0, 10)}`, "Daily D1 archival forecast failed", { error: message, observedAt }, { notification: "digest", deferMinutes: 15, observedAt });
    throw error;
  }
}

function localScheduleParts(scheduledTime: number): Record<string, string> {
  return Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Chicago",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date(scheduledTime)).map((part) => [part.type, part.value]),
  );
}

export async function runScheduledOperations(env: WorkerEnv, scheduledTime: number): Promise<void> {
  await runLedgerWatchdog(env, scheduledTime);
  await dispatchPendingRegisteredAgents(env);
  await flushOperationalAlertDigest(env, new Date(scheduledTime).toISOString());
  const parts = localScheduleParts(scheduledTime);
  const localDate = `${parts.year}-${parts.month}-${parts.day}`;
  if (parts.minute === "00") await runBrowserCaptureSla(env, scheduledTime);
  if (parts.hour === "04" && parts.minute === "30") {
    const instanceId = `d1-backup-${localDate}`;
    const recorded = await env.DB.prepare("SELECT id FROM backup_exports WHERE id = ?1")
      .bind(`backup_${instanceId}`).first();
    if (!recorded) {
      try {
        await env.BACKUP_WORKFLOW.create({ id: instanceId, params: { trigger: "worker-cron", localDate } });
      } catch (error) {
        const message = error instanceof Error ? error.message : "unknown workflow create failure";
        if (!message.toLowerCase().includes("already")) throw error;
      }
    }
  }
  if (parts.hour === "05" && parts.minute === "15") await runArchivalForecast(env, scheduledTime);
  if (parts.hour === "05" && parts.minute === "45") await runControlPlaneProof(env, scheduledTime);
  if (parts.hour === "06" && parts.minute === "00") await runConfigurationLifecycle(env, scheduledTime);
}
