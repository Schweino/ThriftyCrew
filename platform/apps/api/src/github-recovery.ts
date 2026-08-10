import { deterministicId, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";
import { raiseOperationalAlert, resolveOperationalAlert } from "./operations";

const encoder = new TextEncoder();
const ACTIONABLE_CONCLUSIONS = new Set(["failure", "timed_out", "stale", "startup_failure", "action_required"]);
const AUTOMATIC_INFRASTRUCTURE_CONCLUSIONS = new Set(["timed_out", "stale", "startup_failure"]);
const OPERATIONAL_EVENTS = new Set(["schedule", "workflow_dispatch", "repository_dispatch"]);
const TRANSIENT_FAILURE = /(?:returned|status(?:\s+code)?|http)\s*(?:429|5\d\d)\b|\b(?:429|500|502|503|504)\s*\((?:internal error|bad gateway|service unavailable|gateway timeout)\)|\b(?:econnreset|etimedout|econnrefused|enotfound|socket hang up|connection reset|service unavailable|internal error|bad gateway|gateway timeout|temporarily unavailable)\b|(?:hosted\s+)?runner.*(?:lost|disconnected|unavailable)/i;
const DETERMINISTIC_FAILURE = /\b(?:assertionerror|tests? failed|typecheck(?:ing)? failed|compile(?:r|ation)? error|permission denied|unauthorized|forbidden|schema validation|contract failed|migration failed|unknown recovery job|invalid configuration)\b|\bTS\d{4}:|(?:returned|status(?:\s+code)?|http)\s*(?:400|401|403|404|409|422)\b/i;

export interface GithubFailureDecision {
  action: "retry" | "alert" | "ignore";
  reason: string;
}

interface GithubWorkflowRunPayload {
  action?: string;
  repository?: { full_name?: string };
  workflow?: { id?: number; name?: string; path?: string } | null;
  workflow_run?: {
    id?: number;
    run_attempt?: number;
    name?: string;
    workflow_id?: number;
    event?: string;
    status?: string;
    conclusion?: string | null;
    head_branch?: string | null;
    head_sha?: string;
    html_url?: string;
  };
}

interface GithubWorkflowJobsResponse {
  jobs?: Array<{
    id?: number;
    name?: string;
    conclusion?: string | null;
  }>;
}

interface GithubAnnotation {
  title?: string | null;
  message?: string;
  raw_details?: string | null;
}

interface FailedJobDiagnostic {
  id: number;
  name: string;
  conclusion: string;
  text: string;
}

function constantTimeEqual(left: string, right: string): boolean {
  const max = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < max; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

async function hmacHex(secret: string, body: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    Uint8Array.from(encoder.encode(secret)).buffer,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, Uint8Array.from(body).buffer);
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function verifyGithubWebhookSignature(secret: string, body: Uint8Array, signature: string | null): Promise<boolean> {
  if (!signature?.startsWith("sha256=")) return false;
  const expected = `sha256=${await hmacHex(secret, body)}`;
  return constantTimeEqual(expected, signature.toLowerCase());
}

export function classifyGithubFailure(input: {
  conclusion: string;
  event: string;
  runAttempt: number;
  diagnostics: readonly string[];
  maxAttempts?: number;
}): GithubFailureDecision {
  if (!ACTIONABLE_CONCLUSIONS.has(input.conclusion)) return { action: "ignore", reason: `conclusion ${input.conclusion || "unknown"} is not a failure` };
  const maxAttempts = Math.max(1, input.maxAttempts ?? 2);
  if (input.runAttempt >= maxAttempts) return { action: "alert", reason: `automatic retry limit of ${maxAttempts} attempts reached` };
  if (input.conclusion === "action_required") return { action: "alert", reason: "GitHub requires a human approval or action" };
  if (AUTOMATIC_INFRASTRUCTURE_CONCLUSIONS.has(input.conclusion)) return { action: "retry", reason: `GitHub reported ${input.conclusion}` };
  const diagnosticText = input.diagnostics.join("\n");
  if (DETERMINISTIC_FAILURE.test(diagnosticText)) return { action: "alert", reason: "diagnostics indicate a deterministic code, configuration, authentication, or validation failure" };
  if (TRANSIENT_FAILURE.test(diagnosticText)) return { action: "retry", reason: "diagnostics indicate a transient service, network, or runner failure" };
  if (OPERATIONAL_EVENTS.has(input.event)) return { action: "retry", reason: `bounded retry for an operational ${input.event} run` };
  return { action: "alert", reason: `unclassified ${input.event || "unknown"} failure is not safe to retry automatically` };
}

function githubHeaders(token: string): HeadersInit {
  return {
    accept: "application/vnd.github+json",
    authorization: `Bearer ${token}`,
    "user-agent": "tc-grocery-v3-autorecovery",
    "x-github-api-version": "2026-03-10",
  };
}

async function fetchFailedJobDiagnostics(env: WorkerEnv, runId: number): Promise<FailedJobDiagnostic[]> {
  if (!env.GITHUB_DISPATCH_TOKEN || !env.GITHUB_REPOSITORY) return [];
  const base = `https://api.github.com/repos/${env.GITHUB_REPOSITORY}`;
  const response = await fetch(`${base}/actions/runs/${runId}/jobs?filter=latest&per_page=100`, {
    headers: githubHeaders(env.GITHUB_DISPATCH_TOKEN),
  });
  if (!response.ok) throw new Error(`GitHub workflow jobs request returned ${response.status}`);
  const jobs = await response.json<GithubWorkflowJobsResponse>();
  const failed = (jobs.jobs ?? []).filter((job) => job.id && ACTIONABLE_CONCLUSIONS.has(job.conclusion ?? "")).slice(0, 20);
  return Promise.all(failed.map(async (job) => {
    const [annotationsResponse, logResponse] = await Promise.all([
      fetch(`${base}/check-runs/${job.id}/annotations?per_page=50`, { headers: githubHeaders(env.GITHUB_DISPATCH_TOKEN!) }),
      fetch(`${base}/actions/jobs/${job.id}/logs`, { headers: githubHeaders(env.GITHUB_DISPATCH_TOKEN!) }),
    ]);
    const annotations = annotationsResponse.ok ? await annotationsResponse.json<GithubAnnotation[]>() : [];
    const log = logResponse.ok ? (await logResponse.text()).slice(-200_000) : "";
    return {
      id: job.id!,
      name: job.name ?? `job-${job.id}`,
      conclusion: job.conclusion ?? "failure",
      text: `${annotations.map((annotation) => `${annotation.title ?? ""}\n${annotation.message ?? ""}\n${annotation.raw_details ?? ""}`).join("\n")}\n${log}`,
    };
  }));
}

async function updateWebhookLedger(
  env: WorkerEnv,
  ledgerId: string,
  status: "delivered" | "failed" | "suppressed",
  detail: Record<string, unknown>,
): Promise<void> {
  await env.DB.prepare(
    "UPDATE alert_deliveries SET status = ?2, detail_json = ?3, finished_at = CURRENT_TIMESTAMP WHERE id = ?1",
  ).bind(ledgerId, status, stableJson(detail)).run();
}

async function rerunFailedJobs(env: WorkerEnv, runId: number): Promise<void> {
  if (!env.GITHUB_DISPATCH_TOKEN || !env.GITHUB_REPOSITORY) throw new Error("GitHub Actions recovery credentials are not configured");
  const response = await fetch(`https://api.github.com/repos/${env.GITHUB_REPOSITORY}/actions/runs/${runId}/rerun-failed-jobs`, {
    method: "POST",
    headers: githubHeaders(env.GITHUB_DISPATCH_TOKEN),
    body: JSON.stringify({ enable_debug_logging: false }),
  });
  if (response.status !== 201) throw new Error(`GitHub failed-job rerun returned ${response.status}`);
}

export async function processGithubWorkflowRun(
  env: WorkerEnv,
  deliveryId: string,
  payload: GithubWorkflowRunPayload,
): Promise<{ duplicate?: boolean; decision: string }> {
  const run = payload.workflow_run;
  const repository = payload.repository?.full_name;
  if (payload.action !== "completed" || !run?.id || !repository) return { decision: "ignored-malformed" };
  if (!env.GITHUB_REPOSITORY || repository.toLowerCase() !== env.GITHUB_REPOSITORY.toLowerCase()) return { decision: "ignored-repository" };

  const runAttempt = Math.max(1, run.run_attempt ?? 1);
  const conclusion = run.conclusion ?? "unknown";
  const event = run.event ?? "unknown";
  const ledgerId = await deterministicId("github-workflow-webhook", String(run.id), String(runAttempt));
  const alertKey = `github-run:${run.id}`;
  const baseDetail = {
    deliveryId,
    repository,
    workflowId: run.workflow_id ?? payload.workflow?.id ?? null,
    workflowName: run.name ?? payload.workflow?.name ?? null,
    workflowPath: payload.workflow?.path ?? null,
    runId: run.id,
    runAttempt,
    event,
    conclusion,
    headBranch: run.head_branch ?? null,
    headSha: run.head_sha ?? null,
    url: run.html_url ?? null,
  };
  const inserted = await env.DB.prepare(
    `INSERT OR IGNORE INTO alert_deliveries (id, alert_key, channel, status, attempt, detail_json)
     VALUES (?1, ?2, 'github-webhook', 'started', 1, ?3)`,
  ).bind(ledgerId, `${alertKey}:attempt:${runAttempt}`, stableJson(baseDetail)).run();
  if ((inserted.meta.changes ?? 0) === 0) return { duplicate: true, decision: "duplicate" };

  if (!ACTIONABLE_CONCLUSIONS.has(conclusion)) {
    const recovered = conclusion === "success" && runAttempt > 1;
    await updateWebhookLedger(env, ledgerId, "suppressed", { ...baseDetail, decision: recovered ? "recovered" : "ignored" });
    if (recovered) await resolveOperationalAlert(env, alertKey, { ...baseDetail, resolution: "A later GitHub Actions attempt completed successfully." });
    return { decision: recovered ? "recovered" : "ignored" };
  }

  let diagnostics: FailedJobDiagnostic[] = [];
  let diagnosticError: string | null = null;
  try {
    diagnostics = await fetchFailedJobDiagnostics(env, run.id);
  } catch (error) {
    diagnosticError = error instanceof Error ? error.message : "GitHub job diagnostics are unavailable";
  }
  const maxAttempts = Number.isInteger(Number(env.GITHUB_AUTO_RECOVERY_MAX_ATTEMPTS))
    ? Math.max(1, Number(env.GITHUB_AUTO_RECOVERY_MAX_ATTEMPTS))
    : 2;
  const decision = classifyGithubFailure({
    conclusion,
    event,
    runAttempt,
    diagnostics: diagnostics.map((job) => job.text),
    maxAttempts,
  });
  const detail = {
    ...baseDetail,
    decision: decision.action,
    reason: decision.reason,
    failedJobs: diagnostics.map((job) => ({ id: job.id, name: job.name, conclusion: job.conclusion })),
    diagnosticError,
    maxAttempts,
  };

  if (decision.action === "retry") {
    try {
      await rerunFailedJobs(env, run.id);
      await updateWebhookLedger(env, ledgerId, "delivered", { ...detail, recovery: "rerun-failed-jobs-requested" });
      await raiseOperationalAlert(
        env,
        alertKey,
        `GitHub Actions auto-recovery started for ${run.name ?? payload.workflow?.name ?? run.id}`,
        { ...detail, recovery: "rerun-failed-jobs-requested" },
        { notification: "digest", deferMinutes: 15 },
      );
      return { decision: "retry-requested" };
    } catch (error) {
      const recoveryError = error instanceof Error ? error.message : "GitHub failed-job rerun failed";
      await updateWebhookLedger(env, ledgerId, "failed", { ...detail, recovery: "failed", recoveryError });
      await raiseOperationalAlert(env, alertKey, `GitHub Actions auto-recovery failed for ${run.name ?? payload.workflow?.name ?? run.id}`, { ...detail, recovery: "failed", recoveryError });
      return { decision: "retry-failed" };
    }
  }

  await updateWebhookLedger(env, ledgerId, "delivered", detail);
  await raiseOperationalAlert(env, alertKey, `GitHub Actions requires attention: ${run.name ?? payload.workflow?.name ?? run.id}`, detail);
  return { decision: "alerted" };
}

export async function handleGithubActionsWebhook(
  request: Request,
  env: WorkerEnv,
  executionContext: Pick<ExecutionContext, "waitUntil">,
): Promise<Response> {
  if (!env.GITHUB_WEBHOOK_SECRET) return Response.json({ ok: false, error: "GitHub webhook is not configured" }, { status: 503 });
  const body = new Uint8Array(await request.arrayBuffer());
  if (!(await verifyGithubWebhookSignature(env.GITHUB_WEBHOOK_SECRET, body, request.headers.get("x-hub-signature-256")))) {
    return Response.json({ ok: false, error: "invalid GitHub webhook signature" }, { status: 401 });
  }
  const event = request.headers.get("x-github-event") ?? "unknown";
  const deliveryId = request.headers.get("x-github-delivery") ?? crypto.randomUUID();
  if (event === "ping") return Response.json({ ok: true, event: "ping" });
  if (event !== "workflow_run") return Response.json({ ok: true, event, ignored: true }, { status: 202 });
  let payload: GithubWorkflowRunPayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(body)) as GithubWorkflowRunPayload;
  } catch {
    return Response.json({ ok: false, error: "invalid GitHub webhook JSON" }, { status: 400 });
  }
  executionContext.waitUntil(processGithubWorkflowRun(env, deliveryId, payload));
  return Response.json({ ok: true, event, accepted: true }, { status: 202 });
}
