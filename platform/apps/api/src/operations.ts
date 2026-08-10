import { deterministicId, stableJson } from "@thriftycrew/domain";
import type { MutationIdentity, WorkerEnv } from "./env";

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

export async function raiseOperationalAlert(
  env: WorkerEnv,
  alertKey: string,
  title: string,
  evidence: Record<string, unknown>,
): Promise<{ triageId: string; delivery: string }> {
  const triageId = await deterministicId("triage", "operational_alert", alertKey);
  await env.DB.prepare(
    `INSERT INTO triage_items
       (id, source_kind, source_ref, severity, status, title, evidence_json)
     VALUES (?1, 'operational_alert', ?2, 'hard', 'open', ?3, ?4)
     ON CONFLICT(source_ref) DO UPDATE SET
       status = CASE WHEN triage_items.status = 'resolved' THEN 'open' ELSE triage_items.status END,
       title = excluded.title, evidence_json = excluded.evidence_json, updated_at = CURRENT_TIMESTAMP,
       resolved_at = NULL`,
  ).bind(triageId, alertKey, title, stableJson(evidence)).run();
  const delivery = await deliverAlert(env, alertKey, title, stableJson(evidence));
  return { triageId, delivery };
}

export async function resolveOperationalAlert(
  env: WorkerEnv,
  alertKey: string,
  evidence: Record<string, unknown>,
): Promise<{ triageId: string; resolved: boolean; idempotent: boolean }> {
  const triageId = await deterministicId("triage", "operational_alert", alertKey);
  const existing = await env.DB.prepare(
    "SELECT status FROM triage_items WHERE id = ?1 AND source_kind = 'operational_alert'",
  ).bind(triageId).first<{ status: string }>();
  if (!existing || existing.status === "resolved") return { triageId, resolved: Boolean(existing), idempotent: true };
  await env.DB.prepare(
    `UPDATE triage_items
        SET status = 'resolved', resolution_json = ?2, updated_at = CURRENT_TIMESTAMP,
            resolved_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND status <> 'resolved'`,
  ).bind(triageId, stableJson(evidence)).run();
  return { triageId, resolved: true, idempotent: false };
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
  await env.DB.prepare(
    `INSERT INTO watchdog_dispatches (id, job, idempotency_key, reason, status)
     VALUES (?1, ?2, ?3, ?4, 'started')`,
  ).bind(dispatchId, job, idempotencyKey, reason).run();
  if (!env.GITHUB_DISPATCH_TOKEN || !env.GITHUB_REPOSITORY || !env.GITHUB_WORKFLOW_FILE) {
    const detail = { error: "GitHub recovery dispatch is not configured" };
    await env.DB.prepare(
      "UPDATE watchdog_dispatches SET status = 'failed', detail_json = ?2, finished_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(dispatchId, stableJson(detail)).run();
    await raiseOperationalAlert(env, `dispatch-unconfigured:${job}`, `Recovery dispatch is not configured for ${job}`, detail);
    return { dispatchId, status: "failed", idempotent: false };
  }
  try {
    const response = await fetch(
      `https://api.github.com/repos/${env.GITHUB_REPOSITORY}/actions/workflows/${env.GITHUB_WORKFLOW_FILE}/dispatches`,
      {
        method: "POST",
        headers: {
          accept: "application/vnd.github+json",
          authorization: `Bearer ${env.GITHUB_DISPATCH_TOKEN}`,
          "content-type": "application/json",
          "user-agent": "tc-grocery-v3-watchdog",
          "x-github-api-version": "2022-11-28",
        },
        body: JSON.stringify({ ref, inputs: { recovery_job: job, recovery_reason: reason } }),
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
  return log
    .replaceAll(/\x1B\[[0-?]*[ -/]*[@-~]/g, "")
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .slice(-60)
    .map((line) => line
      .replaceAll(/(github_pat_|gh[pousr]_)[A-Za-z0-9_]+/gi, "$1[REDACTED]")
      .replaceAll(/(authorization:\s*(?:bearer|token)\s+)[^\s]+/gi, "$1[REDACTED]")
      .replaceAll(/((?:secret|token|password|TC_LOCAL_MUTATION_SECRET)\s*[=:]\s*)[^\s]+/gi, "$1[REDACTED]")
      .slice(0, 600));
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
  const schedules = await env.DB.prepare(
    `SELECT s.job, s.max_gap_minutes, s.dispatch_on_gap,
            MAX(COALESCE(r.heartbeat_at, r.finished_at, r.started_at, r.scheduled_for)) AS latest
       FROM job_schedules s
       LEFT JOIN job_runs r ON r.job = s.job
      WHERE s.active = 1 AND s.job <> 'ledger-watchdog'
      GROUP BY s.job, s.max_gap_minutes, s.dispatch_on_gap
      ORDER BY s.job`,
  ).all<{ job: string; max_gap_minutes: number; dispatch_on_gap: number; latest: string | null }>();
  const stale: string[] = [];
  for (const schedule of schedules.results) {
    const latest = schedule.latest ? Date.parse(schedule.latest) : Number.NaN;
    const ageMinutes = Number.isFinite(latest) ? Math.floor((scheduledTime - latest) / 60_000) : null;
    if (ageMinutes !== null && ageMinutes <= schedule.max_gap_minutes) continue;
    stale.push(schedule.job);
    const evidence = { job: schedule.job, latest: schedule.latest, ageMinutes, maxGapMinutes: schedule.max_gap_minutes, checkedAt: scheduledFor };
    await raiseOperationalAlert(env, `schedule-gap:${schedule.job}`, `Scheduled job ${schedule.job} exceeded its maximum gap`, evidence);
    if (schedule.dispatch_on_gap === 1) {
      const hour = scheduledFor.slice(0, 13).replaceAll(/[^0-9]/g, "");
      await dispatchGithubJob(env, schedule.job, `watchdog gap at ${scheduledFor}`, `watchdog-${schedule.job}-${hour}`);
    }
  }
  await env.DB.prepare(
    `UPDATE job_runs SET status = 'completed', heartbeat_at = ?2, finished_at = ?2, stats_json = ?3
      WHERE id = ?1 AND status = 'started'`,
  ).bind(runId, new Date().toISOString(), stableJson({ checked: schedules.results.length, stale })).run();
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
  const parts = localScheduleParts(scheduledTime);
  if (parts.hour !== "04" || parts.minute !== "30") return;
  const localDate = `${parts.year}-${parts.month}-${parts.day}`;
  const instanceId = `d1-backup-${localDate}`;
  const recorded = await env.DB.prepare("SELECT id FROM backup_exports WHERE id = ?1")
    .bind(`backup_${instanceId}`).first();
  if (recorded) return;
  try {
    await env.BACKUP_WORKFLOW.create({ id: instanceId, params: { trigger: "worker-cron", localDate } });
  } catch (error) {
    // A deterministic Workflow ID makes concurrent/retried cron delivery safe.
    const message = error instanceof Error ? error.message : "unknown workflow create failure";
    if (!message.toLowerCase().includes("already")) throw error;
  }
}
