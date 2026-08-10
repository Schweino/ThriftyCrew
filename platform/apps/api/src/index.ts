import { Hono, type MiddlewareHandler } from "hono";
import { zValidator } from "@hono/zod-validator";
import {
  accuracyDrawCreateSchema,
  accuracyVerdictsSchema,
  captureBatchAbandonSchema,
  captureBatchCreateSchema,
  captureBatchSealSchema,
  contentBatchAuditSchema,
  contentBatchCreateSchema,
  contentBatchItemsSchema,
  contentItemSchema,
  configurationCategoriesChunkSchema,
  configurationCommoditiesChunkSchema,
  configurationCreateSchema,
  configurationKnownWrongChunkSchema,
  evidenceMetadataSchema,
  engineParityReportSchema,
  entitlementVerificationRecordSchema,
  evidenceGateRecordSchema,
  jobDispatchSchema,
  jobRunCreateSchema,
  jobRunUpdateSchema,
  matchDecisionReconcileSchema,
  matchDecisionsChunkSchema,
  matchRunSchema,
  milestoneAccrualSchema,
  observationChunkSchema,
  operationalAlertSchema,
  agentRegistrySchema,
  agentEvaluationRecordSchema,
  agentWorkItemClaimSchema,
  agentWorkItemCompleteSchema,
  agentWorkItemFailSchema,
  recipeSuggestionRequestSchema,
  recipeWaveSnapshotSchema,
  recipeWavePublicationSchema,
  loginCanaryProbeSchema,
  archivalForecastSchema,
  archivePlanSchema,
  recipeCostsChunkSchema,
  releaseCellsChunkSchema,
  releaseCreateSchema,
  releaseFreeRotationChunkSchema,
  releaseTop5ChunkSchema,
  releaseGuardResultSchema,
  releasePayloadSchema,
  restoreDrillCleanupSchema,
  restoreDrillRecordSchema,
  scheduleDocumentSchema,
  sourceSentinelResultSchema,
  telemetryEventSchema,
  triageResolveSchema,
  triagePlanSchema,
} from "@thriftycrew/contracts";
import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import { GhostEntitlementProvider, type Entitlement } from "@thriftycrew/entitlements";
import { authenticateMutation } from "./auth";
import { createRelease, findBatch, insertObservations, insertRecipeCosts, insertReleaseCells, upsertGuardResult } from "./database";
import { evaluateNotBlindGuard, evaluateReleaseGuards } from "./release-guards";
import { createAccuracyDraw, latestAccuracySummary, markOverdueAccuracyDraws, readAccuracyDraw, recordAccuracyVerdicts } from "./accuracy";
import { reconcileGhostRotation, runGhostClobberDrill } from "./ghost-reconciliation";
import { dispatchGithubJob, dispatchRegisteredAgent, githubWorkflowRuns, jobStatusRequiresAlert, raiseOperationalAlert, recordAudit, resolveOperationalAlert, resolveRecoveredJobRunAlerts, runArchivalForecast, runScheduledOperations, scheduleGap } from "./operations";
import { readEngineSnapshot, readEngineSnapshotIdentity, type EngineSnapshotProfile, type EngineSourceMode } from "./engine-snapshot";
import { memberStatusHtml } from "./member-status";
import { accrueMilestoneEvidence, milestoneEvidenceSummary } from "./milestone-evidence";
import { runServerChaosDrill } from "./chaos-drills";
import { engineMayWriteCaptureSource } from "./capture-authorization";
import { evaluateContentPromotion } from "./content-batches";
import { claimAgentWorkItem, completeAgentWorkItem, failAgentWorkItem } from "./agent-work-items";
import { assertLoginCanaryEvidenceHasNoEmail } from "./login-canary";
import { isMissingMultipartUploadError } from "./restore-cleanup";
import { validateBrowserCaptureEvidence, validateScreenshotEvidence } from "./evidence-validation";
import type { MutationIdentity, MutationRole, WorkerEnv } from "./env";
export { D1BackupWorkflow } from "./backup-workflow";
export { D1RestoreDrillWorkflow } from "./restore-workflow";

type Bindings = { Bindings: WorkerEnv; Variables: { identity: MutationIdentity } };
const app = new Hono<Bindings>();

function jsonError(message: string, status: 400 | 401 | 403 | 404 | 409 | 422 | 500 | 502 = 400): Response {
  return Response.json({ ok: false, error: message }, { status });
}

function entitlementProvider(env: WorkerEnv): GhostEntitlementProvider {
  if (!env.GHOST_PUBLIC_ORIGIN) throw new Error("Ghost public origin is not configured");
  return new GhostEntitlementProvider(env.GHOST_PUBLIC_ORIGIN);
}

async function resolveEntitlement(request: Request, env: WorkerEnv): Promise<Entitlement> {
  return entitlementProvider(env).resolve(request);
}

function requireMutation(roles: readonly MutationRole[]): MiddlewareHandler<Bindings> {
  return async (context, next) => {
    try {
      const identity = await authenticateMutation(context.req.raw, context.env, roles);
      context.set("identity", identity);
      return await next();
    } catch (error) {
      return context.json({ ok: false, error: error instanceof Error ? error.message : "unauthorized" }, 401);
    }
  };
}

function requireIdentityRole(roles: readonly MutationRole[]): MiddlewareHandler<Bindings> {
  return async (context, next) => {
    const identity = context.get("identity");
    if (!identity) return context.json({ ok: false, error: "authenticated mutation identity is missing" }, 401);
    if (!roles.includes(identity.role)) return context.json({ ok: false, error: "mutation role is not authorized for this operation" }, 403);
    return await next();
  };
}

function requireGithubWorkflowScope(): MiddlewareHandler<Bindings> {
  return async (context, next) => {
    const identity = context.get("identity");
    if (identity.authMethod !== "github_oidc" || !identity.workflowRef) return next();
    const pathname = new URL(context.req.url).pathname;
    if (identity.registeredAgentId) {
      const capabilities = new Set(identity.capabilities ?? []);
      const method = context.req.method.toUpperCase();
      const authorized =
        (pathname.startsWith("/internal/agent-work-items") && capabilities.has("write:ledger"))
        || (pathname === "/internal/agent-evaluations" && capabilities.has("write:ledger"))
        || (pathname === `/internal/agents/${identity.registeredAgentId}/authorize` && capabilities.has("write:ledger"))
        || (pathname === `/internal/agents/${identity.registeredAgentId}/evaluation-status` && capabilities.has("write:ledger"))
        || (pathname.startsWith("/internal/job-runs") && capabilities.has("write:ledger"))
        || (pathname.startsWith("/internal/triage") && method === "GET" && capabilities.has("read:evidence"))
        || (pathname.startsWith("/internal/triage") && method === "POST" && capabilities.has("write:triage-plan"))
        || (pathname.startsWith("/internal/source-sentinels") && capabilities.has("write:sentinel-finding"))
        || (pathname.startsWith("/internal/content-batches") && (capabilities.has("read:content") || capabilities.has("write:content-stage")))
        || (pathname.startsWith("/internal/accuracy") && capabilities.has("write:ledger"))
        || (pathname === "/internal/operational-alerts" && capabilities.has("write:ledger"));
      if (!authorized) return context.json({ ok: false, error: "agent workflow is outside its registered capability boundary" }, 403);
    }
    if (identity.workflowRef.includes("/platform-restore.yml@") && pathname !== "/internal/restore-drills/trigger") {
      return context.json({ ok: false, error: "restore workflow may only trigger the deterministic restore drill" }, 403);
    }
    return next();
  };
}

async function requireDraftRelease(db: D1Database, releaseId: string): Promise<Response | null> {
  const release = await db.prepare("SELECT state FROM releases WHERE id = ?1").bind(releaseId).first<{ state: string }>();
  if (!release) return jsonError("release not found", 404);
  if (release.state !== "draft") return jsonError(`release content is immutable in ${release.state} state`, 409);
  return null;
}

app.use("/internal/*", requireMutation(["capture", "engine", "operator"]));
app.use("/internal/*", requireGithubWorkflowScope());
app.use("/internal/capture-batches", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/capture-batches/*", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/configurations", requireIdentityRole(["engine", "operator"]));
app.use("/internal/configurations/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/match-decisions", requireIdentityRole(["engine", "operator"]));
app.use("/internal/match-runs", requireIdentityRole(["engine", "operator"]));
app.use("/internal/job-runs", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/job-runs/*", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/operational-alerts", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/jobs/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/schedules/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/agents/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/agent-work-items/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/agent-evaluations", requireIdentityRole(["engine", "operator"]));
app.use("/internal/recipe-suggestions", requireIdentityRole(["engine", "operator"]));
app.use("/internal/recipe-waves/*", requireIdentityRole(["operator"]));
app.use("/internal/login-canary-probes", requireIdentityRole(["capture", "operator"]));
app.use("/internal/content-batches", requireIdentityRole(["engine", "operator"]));
app.use("/internal/content-batches/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/source-sentinels", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/source-sentinels/*", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/archival/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/backups/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/restore-drills", requireIdentityRole(["operator"]));
app.use("/internal/restore-drills/*", requireIdentityRole(["operator"]));
app.use("/internal/evidence-gates", requireIdentityRole(["operator"]));
app.use("/internal/evidence-gates/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/entitlement-verifications", requireIdentityRole(["operator"]));
app.use("/internal/entitlement-verifications/*", requireIdentityRole(["operator"]));
app.use("/internal/releases", requireIdentityRole(["engine", "operator"]));
app.use("/internal/releases/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/accuracy/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/triage", requireIdentityRole(["engine", "operator"]));
app.use("/internal/triage/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/doctor", requireIdentityRole(["engine", "operator"]));
app.use("/internal/engine/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/drills/*", requireIdentityRole(["operator"]));

app.get("/api/v2/status", async (context) => {
  const [release, schedules, accuracy, triage, milestones, agentWork, evaluations, loginCanaries] = await Promise.all([
    context.env.DB.prepare(
      `SELECT r.id, r.published_at, r.summary_json
         FROM current_releases c JOIN releases r ON r.id = c.release_id
        WHERE c.market_id = 'omaha'`,
    ).first<{ id: string; published_at: string; summary_json: string }>(),
    context.env.DB.prepare(
      `SELECT s.job, s.cron, COALESCE(s.authority_executor, s.executor) AS executor, s.timezone, s.owner, s.proof, s.max_gap_minutes,
              s.lifecycle, s.retirement_gate, s.monitoring_started_at,
              (SELECT status FROM job_runs r WHERE r.job = s.job ORDER BY COALESCE(r.started_at, r.scheduled_for) DESC LIMIT 1) AS status,
              (SELECT COALESCE(heartbeat_at, finished_at, started_at, scheduled_for) FROM job_runs r WHERE r.job = s.job ORDER BY COALESCE(heartbeat_at, finished_at, started_at, scheduled_for) DESC LIMIT 1) AS latest_at
         FROM job_schedules s WHERE s.active = 1 ORDER BY s.job`,
    ).all(),
    latestAccuracySummary(context.env.DB),
    context.env.DB.prepare(
      "SELECT status, COUNT(*) AS count FROM triage_items GROUP BY status ORDER BY status",
    ).all<{ status: string; count: number }>(),
    milestoneEvidenceSummary(context.env.DB),
    context.env.DB.prepare("SELECT state, COUNT(*) AS count FROM agent_work_items GROUP BY state ORDER BY state").all<{ state: string; count: number }>(),
    context.env.DB.prepare(
      `SELECT registry.id AS agent_id, registry.execution_config_hash,
              MAX(CASE WHEN evaluation.passed = 1 THEN evaluation.evaluated_at END) AS passed_at
         FROM agent_registry registry LEFT JOIN agent_evaluations evaluation
           ON evaluation.agent_id = registry.id AND evaluation.execution_config_hash = registry.execution_config_hash
        WHERE registry.active = 1 GROUP BY registry.id, registry.execution_config_hash ORDER BY registry.id`,
    ).all(),
    context.env.DB.prepare(
      `SELECT store_id, run_id, COUNT(*) AS probes,
              SUM(CASE WHEN status = 'healthy' THEN 1 ELSE 0 END) AS healthy_probes,
              MAX(observed_at) AS latest_at
         FROM login_canary_probes GROUP BY store_id, run_id ORDER BY latest_at DESC LIMIT 20`,
    ).all(),
  ]);
  const checkedAt = new Date();
  const jobs = schedules.results.map((row) => {
    const item = row as Record<string, unknown>;
    const maxGap = typeof item.max_gap_minutes === "number" ? item.max_gap_minutes : 0;
    const health = scheduleGap(
      typeof item.latest_at === "string" ? item.latest_at : null,
      typeof item.monitoring_started_at === "string" ? item.monitoring_started_at : null,
      checkedAt.getTime(),
      maxGap,
    );
    return { ...item, stale: health.stale, age_minutes: health.ageMinutes, freshness_basis: health.basis };
  });
  return context.json({
    ok: true,
    environment: context.env.APP_ENV,
    deployment: { commit: context.env.DEPLOYED_COMMIT ?? "unknown" },
    currentRelease: release ? { id: release.id, publishedAt: release.published_at, summary: JSON.parse(release.summary_json) } : null,
    jobs,
    accuracy,
    milestones,
    agents: {
      workItems: Object.fromEntries(agentWork.results.map((row) => [row.state, row.count])),
      evaluations: evaluations.results,
    },
    loginCanaries: loginCanaries.results,
    triage: Object.fromEntries(triage.results.map((row) => [row.status, row.count])),
    checkedAt: checkedAt.toISOString(),
  });
});

app.get("/v2/status", (context) => context.redirect("/api/v2/status", 307));

// A deliberately isolated Sessions API pilot. Public release routes remain on
// the primary binding until this canary proves latency and consistency benefits.
app.get("/api/v2/replica-canary", async (context) => {
  const started = Date.now();
  const session = context.env.DB.withSession("first-primary");
  const query = await session.prepare(
    `SELECT r.id, r.published_at
       FROM current_releases c JOIN releases r ON r.id = c.release_id
      WHERE c.market_id = 'omaha'`,
  ).run<{ id: string; published_at: string }>();
  const result = query.results[0] ?? null;
  const meta = query.meta as typeof query.meta & { served_by_region?: string; served_by_primary?: boolean };
  context.header("cache-control", "no-store");
  return context.json({
    ok: result !== null,
    constraint: "first-primary",
    release: result ?? null,
    bookmark: session.getBookmark() ?? null,
    latencyMs: Date.now() - started,
    servedByRegion: meta.served_by_region ?? null,
    servedByPrimary: meta.served_by_primary ?? null,
  });
});

app.get("/api/v2/entitlement", async (context) => {
  try {
    const entitlement = await resolveEntitlement(context.req.raw, context.env);
    context.header("cache-control", "private, no-store");
    context.header("vary", "cookie");
    if (entitlement.authenticated) context.header("set-cookie", "tc_member_signed_out=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0");
    return context.json({ ok: true, entitlement });
  } catch (error) {
    return context.json({ ok: false, error: error instanceof Error ? error.message : "Entitlement provider failed" }, 503);
  }
});

const renderMemberStatus: MiddlewareHandler<Bindings> = async (context) => {
  try {
    const entitlement = await resolveEntitlement(context.req.raw, context.env);
    context.header("cache-control", "private, no-store");
    context.header("vary", "cookie");
    context.header("x-robots-tag", "noindex, nofollow");
    if (entitlement.authenticated) context.header("set-cookie", "tc_member_signed_out=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0");
    return context.html(memberStatusHtml(entitlement));
  } catch (error) {
    return context.html(memberStatusHtml({ state: "anonymous", authenticated: false, tier: "anonymous", mayUseProtectedTools: false }), 503);
  }
};

app.get("/member-status", renderMemberStatus);
app.get("/member-status/", renderMemberStatus);
app.get("/v3-member-status", renderMemberStatus);
app.get("/api/v2/member-status-page", renderMemberStatus);

app.post("/api/v2/session/signout", (context) => {
  context.header("cache-control", "private, no-store");
  context.header("set-cookie", "tc_member_signed_out=1; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=300");
  if (context.req.header("accept")?.includes("text/html")) return context.redirect("/api/v2/member-status-page", 303);
  return context.json({ ok: true, state: "signed_out" });
});

app.post("/api/v2/session/resume", (context) => {
  context.header("cache-control", "private, no-store");
  context.header("set-cookie", "tc_member_signed_out=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0");
  if (context.req.header("accept")?.includes("text/html")) return context.redirect("/api/v2/member-status-page", 303);
  return context.json({ ok: true, state: "resumed" });
});

app.get("/v2/entitlement", (context) => context.redirect("/api/v2/entitlement", 307));

app.post("/api/v2/events", zValidator("json", telemetryEventSchema), (context) => {
  if (!context.env.FUNNEL_ANALYTICS) return context.json({ ok: false, error: "Funnel telemetry is unavailable" }, 503);
  const event = context.req.valid("json");
  const releaseId = event.releaseId ?? "none";
  context.env.FUNNEL_ANALYTICS.writeDataPoint({
    indexes: [`${event.path}|${event.memberTier}`],
    blobs: [event.event, event.path, event.memberTier, releaseId, event.product ?? ""],
    doubles: [1, Date.now()],
  });
  return context.json({ ok: true }, 202);
});

app.post("/v2/events", (context) => app.fetch(new Request(new URL("/api/v2/events", context.req.url), context.req.raw), context.env));

app.get("/api/v2/board", async (context) => {
  const row = await context.env.DB.prepare(
    `SELECT r.id AS release_id, r.published_at, p.payload_json, p.object_key
       FROM current_releases c
       JOIN releases r ON r.id = c.release_id
       JOIN release_payloads p ON p.release_id = r.id AND p.kind = 'board'
      WHERE c.market_id = 'omaha'`,
  ).first<{ release_id: string; published_at: string; payload_json: string; object_key: string | null }>();
  if (!row) return context.json({ ok: false, error: "No published Omaha release" }, 404);
  let board: unknown;
  if (row.object_key) {
    const object = await context.env.EVIDENCE.get(row.object_key);
    if (!object) return context.json({ ok: false, error: "Published board payload is unavailable" }, 500);
    board = await object.json();
  } else {
    board = JSON.parse(row.payload_json);
  }
  context.header("cache-control", "public, max-age=60, stale-while-revalidate=300");
  return context.json({ ok: true, releaseId: row.release_id, publishedAt: row.published_at, board });
});

app.get("/v2/board", (context) => context.redirect("/api/v2/board", 307));

async function currentPayload(env: WorkerEnv, kind: "board" | "feed" | "top5" | "free_rotation" | "recipes"): Promise<{
  releaseId: string;
  publishedAt: string;
  payload: unknown;
} | null> {
  const row = await env.DB.prepare(
    `SELECT r.id AS release_id, r.published_at, p.payload_json, p.object_key
       FROM current_releases c
       JOIN releases r ON r.id = c.release_id
       JOIN release_payloads p ON p.release_id = r.id AND p.kind = ?1
      WHERE c.market_id = 'omaha'`,
  ).bind(kind).first<{ release_id: string; published_at: string; payload_json: string; object_key: string | null }>();
  if (!row) return null;
  const payload = row.object_key ? await env.EVIDENCE.get(row.object_key).then((object) => object?.json()) : JSON.parse(row.payload_json);
  if (payload === undefined) throw new Error(`Published ${kind} payload is unavailable`);
  return { releaseId: row.release_id, publishedAt: row.published_at, payload };
}

app.get("/api/v2/releases/current", async (context) => {
  const row = await context.env.DB.prepare(
    `SELECT r.id, r.market_id, r.published_at, r.summary_json
       FROM current_releases c JOIN releases r ON r.id = c.release_id
      WHERE c.market_id = 'omaha'`,
  ).first<{ id: string; market_id: string; published_at: string; summary_json: string }>();
  if (!row) return context.json({ ok: false, error: "No published Omaha release" }, 404);
  return context.json({ ok: true, releaseId: row.id, market: row.market_id, publishedAt: row.published_at, summary: JSON.parse(row.summary_json) });
});

for (const kind of ["feed", "top5", "free_rotation", "recipes"] as const) {
  app.get(`/api/v2/${kind === "free_rotation" ? "free-rotation" : kind}`, async (context) => {
    const current = await currentPayload(context.env, kind);
    if (!current) return context.json({ ok: false, error: `No published ${kind} payload` }, 404);
    context.header("cache-control", "public, max-age=60, stale-while-revalidate=300");
    return context.json({ ok: true, ...current });
  });
}

app.get("/api/v2/board/:commodity", async (context) => {
  const current = await currentPayload(context.env, "board");
  if (!current) return context.json({ ok: false, error: "No published board payload" }, 404);
  const board = current.payload as { commodities?: Array<{ id?: string }> };
  const commodity = board.commodities?.find((item) => item.id === context.req.param("commodity"));
  if (!commodity) return context.json({ ok: false, error: "Commodity not found" }, 404);
  return context.json({ ok: true, releaseId: current.releaseId, publishedAt: current.publishedAt, commodity });
});

app.get("/api/v2/recipes/:slug", async (context) => {
  const current = await currentPayload(context.env, "recipes");
  if (!current) return context.json({ ok: false, error: "No published recipe payload" }, 404);
  const payload = current.payload as { recipes?: Array<{ slug?: string }> };
  const recipe = payload.recipes?.find((item) => item.slug === context.req.param("slug"));
  if (!recipe) return context.json({ ok: false, error: "Recipe not found" }, 404);
  return context.json({ ok: true, releaseId: current.releaseId, publishedAt: current.publishedAt, recipe });
});

app.get("/api/v2/member/recipes/:slug", async (context) => {
  const slug = context.req.param("slug");
  const release = await context.env.DB.prepare(
    `SELECT r.id AS release_id, r.published_at, f.intended_visibility
       FROM current_releases c
       JOIN releases r ON r.id = c.release_id
       LEFT JOIN release_free_rotation f ON f.release_id = r.id AND f.recipe_slug = ?1
      WHERE c.market_id = 'omaha'`,
  ).bind(slug).first<{ release_id: string; published_at: string; intended_visibility: string | null }>();
  if (!release) return context.json({ ok: false, error: "No published recipe release" }, 404);
  let entitlement: Entitlement = { state: "anonymous", authenticated: false, tier: "anonymous", mayUseProtectedTools: false };
  if (release.intended_visibility !== "public") {
    try {
      entitlement = await resolveEntitlement(context.req.raw, context.env);
    } catch (error) {
      return context.json({ ok: false, error: error instanceof Error ? error.message : "Entitlement provider failed" }, 503);
    }
    if (!entitlement.mayUseProtectedTools) {
      context.header("cache-control", "private, no-store");
      context.header("vary", "cookie");
      return context.json({ ok: false, error: "Paid membership is required", entitlement }, entitlement.authenticated ? 403 : 401);
    }
  }
  const current = await currentPayload(context.env, "recipes");
  const payload = current?.payload as { recipes?: Array<{ slug?: string }> } | undefined;
  const recipe = payload?.recipes?.find((item) => item.slug === slug);
  if (!recipe) return context.json({ ok: false, error: "Recipe not found" }, 404);
  context.header("cache-control", "private, no-store");
  context.header("vary", "cookie");
  return context.json({ ok: true, releaseId: release.release_id, publishedAt: release.published_at, entitlement, recipe });
});

app.get("/v2/releases/current", (context) => context.redirect("/api/v2/releases/current", 307));
app.get("/v2/board/:commodity", (context) => context.redirect(`/api/v2/board/${context.req.param("commodity")}`, 307));
app.get("/v2/recipes", (context) => context.redirect("/api/v2/recipes", 307));
app.get("/v2/recipes/:slug", (context) => context.redirect(`/api/v2/recipes/${context.req.param("slug")}`, 307));
app.get("/v2/feed", (context) => context.redirect("/api/v2/feed", 307));

app.post("/internal/configurations", zValidator("json", configurationCreateSchema), async (context) => {
  const body = context.req.valid("json");
  const existing = await context.env.DB.prepare(
    `SELECT content_hash, active, expected_categories, expected_commodities, expected_rules, expected_known_wrong
       FROM configuration_versions WHERE id = ?1`,
  ).bind(body.id).first<{
    content_hash: string; active: number; expected_categories: number; expected_commodities: number; expected_rules: number; expected_known_wrong: number;
  }>();
  if (existing) {
    if (existing.content_hash !== body.contentHash) return jsonError("configuration id already exists with different content", 409);
    const expectationsMatch = existing.expected_categories === body.expectedCategories
      && existing.expected_commodities === body.expectedCommodities
      && existing.expected_rules === body.expectedRules
      && existing.expected_known_wrong === body.expectedKnownWrong;
    if (!expectationsMatch) {
      if (existing.active === 1) return jsonError("active configuration expectations cannot be changed", 409);
      await context.env.DB.prepare(
        `UPDATE configuration_versions
            SET expected_categories = ?2, expected_commodities = ?3, expected_rules = ?4, expected_known_wrong = ?5
          WHERE id = ?1 AND active = 0`,
      ).bind(body.id, body.expectedCategories, body.expectedCommodities, body.expectedRules, body.expectedKnownWrong).run();
    }
    return context.json({ ok: true, configurationId: body.id, active: existing.active === 1, idempotent: true });
  }
  await context.env.DB.prepare(
    `INSERT INTO configuration_versions
       (id, source_commit, content_hash, expected_categories, expected_commodities, expected_rules, expected_known_wrong)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
  ).bind(body.id, body.sourceCommit, body.contentHash, body.expectedCategories, body.expectedCommodities, body.expectedRules, body.expectedKnownWrong).run();
  return context.json({ ok: true, configurationId: body.id, active: false, idempotent: false }, 201);
});

app.put("/internal/configurations/:id/categories", zValidator("json", configurationCategoriesChunkSchema), async (context) => {
  const configurationId = context.req.param("id");
  const config = await context.env.DB.prepare("SELECT active FROM configuration_versions WHERE id = ?1").bind(configurationId).first<{ active: number }>();
  if (!config) return jsonError("configuration not found", 404);
  if (config.active === 1) return jsonError("active configuration is immutable", 409);
  const statements: D1PreparedStatement[] = [];
  for (const category of context.req.valid("json").categories) {
    statements.push(context.env.DB.prepare(
      `INSERT INTO categories (id, label, sort_order) VALUES (?1, ?2, ?3)
       ON CONFLICT(id) DO UPDATE SET label = excluded.label, sort_order = excluded.sort_order`,
    ).bind(category.id, category.label, category.sortOrder));
    statements.push(context.env.DB.prepare(
      "INSERT OR IGNORE INTO configuration_categories (configuration_id, category_id) VALUES (?1, ?2)",
    ).bind(configurationId, category.id));
  }
  await context.env.DB.batch(statements);
  return context.json({ ok: true, accepted: context.req.valid("json").categories.length });
});

app.put("/internal/configurations/:id/commodities", zValidator("json", configurationCommoditiesChunkSchema), async (context) => {
  const configurationId = context.req.param("id");
  const config = await context.env.DB.prepare("SELECT active FROM configuration_versions WHERE id = ?1").bind(configurationId).first<{ active: number }>();
  if (!config) return jsonError("configuration not found", 404);
  if (config.active === 1) return jsonError("active configuration is immutable", 409);
  const statements: D1PreparedStatement[] = [];
  for (const commodity of context.req.valid("json").commodities) {
    statements.push(context.env.DB.prepare(
      `INSERT INTO commodities (id, configuration_id, label, basis_unit, category_id)
       VALUES (?1, ?2, ?3, ?4, ?5)
       ON CONFLICT(id, configuration_id) DO UPDATE SET
         label = excluded.label, basis_unit = excluded.basis_unit, category_id = excluded.category_id`,
    ).bind(commodity.id, configurationId, commodity.label, commodity.basisUnit, commodity.categoryId));
    for (const [kind, patterns] of [["include", commodity.include], ["exclude", commodity.exclude]] as const) {
      for (const pattern of patterns) {
        const ruleId = await deterministicId("rule", configurationId, commodity.id, kind, pattern);
        statements.push(context.env.DB.prepare(
          `INSERT OR IGNORE INTO match_rules
             (id, configuration_id, commodity_id, kind, pattern, reason, priority)
           VALUES (?1, ?2, ?3, ?4, ?5, 'authored configuration', 0)`,
        ).bind(ruleId, configurationId, commodity.id, kind, pattern));
      }
    }
  }
  for (let offset = 0; offset < statements.length; offset += 90) {
    await context.env.DB.batch(statements.slice(offset, offset + 90));
  }
  return context.json({ ok: true, accepted: context.req.valid("json").commodities.length });
});

app.put("/internal/configurations/:id/known-wrong", zValidator("json", configurationKnownWrongChunkSchema), async (context) => {
  const configurationId = context.req.param("id");
  const config = await context.env.DB.prepare("SELECT active FROM configuration_versions WHERE id = ?1").bind(configurationId).first<{ active: number }>();
  if (!config) return jsonError("configuration not found", 404);
  if (config.active === 1) return jsonError("active configuration is immutable", 409);
  if (context.req.query("replace") === "1") {
    await context.env.DB.prepare("DELETE FROM known_wrong_rules WHERE configuration_id = ?1").bind(configurationId).run();
  }
  const rules = await Promise.all(context.req.valid("json").rules.map(async (rule) => ({
    ...rule,
    id: await deterministicId("known-wrong", configurationId, rule.id),
  })));
  const statements = rules.map((rule) => context.env.DB.prepare(
    `INSERT INTO known_wrong_rules
       (id, configuration_id, commodity_id, store_location_id, external_product_key, normalized_name, ruling, evidence)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
     ON CONFLICT(id) DO UPDATE SET
       commodity_id = excluded.commodity_id, store_location_id = excluded.store_location_id,
       external_product_key = excluded.external_product_key, normalized_name = excluded.normalized_name,
       ruling = excluded.ruling, evidence = excluded.evidence`,
  ).bind(rule.id, configurationId, rule.commodityId, rule.storeLocationId ?? null, rule.externalProductKey ?? null, rule.normalizedName ?? null, rule.ruling, rule.evidence));
  for (let offset = 0; offset < statements.length; offset += 90) await context.env.DB.batch(statements.slice(offset, offset + 90));
  return context.json({ ok: true, accepted: statements.length, replaced: context.req.query("replace") === "1" });
});

app.post("/internal/configurations/:id/activate", async (context) => {
  const configurationId = context.req.param("id");
  const row = await context.env.DB.prepare(
    `SELECT v.expected_categories, v.expected_commodities, v.expected_rules, v.expected_known_wrong,
             (SELECT COUNT(*) FROM configuration_categories c WHERE c.configuration_id = v.id) AS categories,
             (SELECT COUNT(*) FROM commodities c WHERE c.configuration_id = v.id) AS commodities,
             (SELECT COUNT(*) FROM match_rules r WHERE r.configuration_id = v.id) AS rules,
             (SELECT COUNT(*) FROM known_wrong_rules k WHERE k.configuration_id = v.id) AS known_wrong
       FROM configuration_versions v WHERE v.id = ?1`,
  ).bind(configurationId).first<{
    expected_categories: number; expected_commodities: number; expected_rules: number; expected_known_wrong: number;
    categories: number; commodities: number; rules: number; known_wrong: number;
  }>();
  if (!row) return jsonError("configuration not found", 404);
  const complete = row.categories === row.expected_categories
    && row.commodities === row.expected_commodities
    && row.rules === row.expected_rules
    && row.known_wrong === row.expected_known_wrong;
  if (!complete) return jsonError(`configuration counts do not match: ${stableJson(row)}`, 422);
  await context.env.DB.batch([
    context.env.DB.prepare("UPDATE configuration_versions SET active = 0 WHERE active = 1 AND id <> ?1").bind(configurationId),
    context.env.DB.prepare("UPDATE configuration_versions SET active = 1, deployed_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(configurationId),
  ]);
  return context.json({ ok: true, configurationId, active: true, counts: { categories: row.categories, commodities: row.commodities, rules: row.rules, knownWrong: row.known_wrong } });
});

app.put("/internal/match-decisions", zValidator("json", matchDecisionsChunkSchema), async (context) => {
  const decisions = context.req.valid("json").decisions;
  const statements: D1PreparedStatement[] = [];
  for (const decision of decisions) {
    const decisionId = await deterministicId("match", decision.configurationId, decision.productId, decision.commodityId);
    statements.push(context.env.DB.prepare(
      `UPDATE match_decisions
          SET superseded_at = CURRENT_TIMESTAMP
        WHERE product_id = ?1 AND superseded_at IS NULL
          AND (configuration_id <> ?2 OR commodity_id <> ?3)`,
    ).bind(decision.productId, decision.configurationId, decision.commodityId));
    statements.push(context.env.DB.prepare(
      `INSERT INTO match_decisions
         (id, product_id, commodity_id, configuration_id, decided_by, reason)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)
       ON CONFLICT(id) DO UPDATE SET
         decided_by = excluded.decided_by,
         reason = excluded.reason,
         decided_at = CURRENT_TIMESTAMP,
         superseded_at = NULL`,
    ).bind(decisionId, decision.productId, decision.commodityId, decision.configurationId, decision.decidedBy, decision.reason));
  }
  for (let offset = 0; offset < statements.length; offset += 90) {
    await context.env.DB.batch(statements.slice(offset, offset + 90));
  }
  return context.json({ ok: true, accepted: decisions.length });
});

app.post("/internal/match-decisions/reconcile", zValidator("json", matchDecisionReconcileSchema), async (context) => {
  const body = context.req.valid("json");
  const batch = await findBatch(context.env.DB, body.batchId);
  if (!batch) return jsonError("capture batch not found", 404);
  const configuration = await context.env.DB.prepare(
    "SELECT id FROM configuration_versions WHERE id = ?1 AND active = 1",
  ).bind(body.configurationId).first<{ id: string }>();
  if (!configuration) return jsonError("match reconciliation must use the active configuration", 422);
  const updated = await context.env.DB.prepare(
    `UPDATE match_decisions
        SET superseded_at = CURRENT_TIMESTAMP
      WHERE configuration_id = ?2 AND superseded_at IS NULL
        AND product_id IN (
          SELECT DISTINCT p.id
            FROM observations o
            JOIN product_versions pv ON pv.id = o.product_version_id
            JOIN products p ON p.id = pv.product_id
           WHERE o.batch_id = ?1
        )
        AND product_id NOT IN (SELECT value FROM json_each(?3))`,
  ).bind(body.batchId, body.configurationId, stableJson(body.retainedProductIds)).run();
  await recordAudit(context.env, context.get("identity"), "matching.reconcile", "capture_batch", body.batchId, "accepted", {
    configurationId: body.configurationId,
    retained: body.retainedProductIds.length,
    superseded: updated.meta.changes,
  });
  return context.json({ ok: true, batchId: body.batchId, retained: body.retainedProductIds.length, superseded: updated.meta.changes });
});

app.get("/internal/capture-batches/:id/products", async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const configuration = await context.env.DB.prepare(
    "SELECT id, content_hash FROM configuration_versions WHERE active = 1",
  ).first<{ id: string; content_hash: string }>();
  if (!configuration) return jsonError("active configuration not found", 422);
  const products = await context.env.DB.prepare(
    `WITH ranked AS (
       SELECT p.id AS product_id, p.external_key, p.store_location_id,
              pv.name, pv.normalized_name, pv.taxonomy_path,
              o.normalized_basis_unit, o.normalized_basis_qty_micros,
              ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY o.captured_at DESC, o.id DESC) AS ordinal
         FROM observations o
         JOIN product_versions pv ON pv.id = o.product_version_id
         JOIN products p ON p.id = pv.product_id
        WHERE o.batch_id = ?1
     )
     SELECT product_id, external_key, store_location_id, name, normalized_name,
            taxonomy_path, normalized_basis_unit, normalized_basis_qty_micros
       FROM ranked WHERE ordinal = 1 ORDER BY product_id`,
  ).bind(batch.id).all();
  return context.json({
    ok: true,
    batchId: batch.id,
    sourceId: batch.source_id,
    status: batch.status,
    configurationId: configuration.id,
    configurationHash: configuration.content_hash,
    products: products.results,
  });
});

app.get("/internal/capture-batches/:id/status", async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  const privileged = identity.role === "operator" || identity.role === "engine";
  if (!privileged && batch.agent_id !== identity.agentId) return jsonError("capture batch belongs to another agent", 403);
  if (identity.sourceIds && !identity.sourceIds.includes(batch.source_id)) return jsonError("agent is not authorized for this capture source", 403);
  const matching = await context.env.DB.prepare(
    `SELECT id, status, product_count, matched_count, unmatched_count, collision_count,
            aisle_rejected_count, created_at
       FROM match_runs WHERE batch_id = ?1 ORDER BY created_at DESC, id DESC LIMIT 1`,
  ).bind(batch.id).first<Record<string, unknown>>();
  const evidence = await context.env.DB.prepare(
    `SELECT kind, COUNT(*) AS count FROM evidence_objects WHERE batch_id = ?1 GROUP BY kind ORDER BY kind`,
  ).bind(batch.id).all<{ kind: string; count: number }>();
  return context.json({
    ok: batch.status === "promoted" || batch.status === "superseded",
    batchId: batch.id,
    sourceId: batch.source_id,
    status: batch.status,
    coverageMode: batch.coverage_mode,
    capturedTo: batch.captured_to,
    matching: matching ?? null,
    evidence: evidence.results,
  });
});

app.post("/internal/match-runs", zValidator("json", matchRunSchema), async (context) => {
  const body = context.req.valid("json");
  const batch = await findBatch(context.env.DB, body.batchId);
  if (!batch) return jsonError("capture batch not found", 404);
  const configuration = await context.env.DB.prepare(
    "SELECT id, content_hash FROM configuration_versions WHERE id = ?1 AND active = 1",
  ).bind(body.configurationId).first<{ id: string; content_hash: string }>();
  if (!configuration) return jsonError("match run must use the active configuration", 422);
  const actual = await context.env.DB.prepare(
    `SELECT COUNT(DISTINCT p.id) AS products,
            COUNT(DISTINCT CASE WHEN m.product_id IS NOT NULL THEN p.id END) AS matched
       FROM observations o
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       LEFT JOIN match_decisions m ON m.product_id = p.id
         AND m.configuration_id = ?2 AND m.superseded_at IS NULL
      WHERE o.batch_id = ?1`,
  ).bind(body.batchId, body.configurationId).first<{ products: number; matched: number }>();
  if (!actual || actual.products !== body.productCount || actual.matched !== body.matchedCount) {
    return jsonError(`match report does not match persisted decisions: ${stableJson({ actual, reported: { products: body.productCount, matched: body.matchedCount } })}`, 409);
  }
  const status = body.collisionCount === 0 ? "passed" : "failed";
  const existing = await context.env.DB.prepare("SELECT status FROM match_runs WHERE id = ?1").bind(body.id).first<{ status: string }>();
  if (existing) return context.json({ ok: existing.status === "passed", runId: body.id, status: existing.status, idempotent: true });
  await context.env.DB.prepare(
    `INSERT INTO match_runs
       (id, batch_id, configuration_id, input_hash, status, product_count, matched_count,
        unmatched_count, collision_count, aisle_rejected_count, detail_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`,
  ).bind(body.id, body.batchId, body.configurationId, body.inputHash, status, body.productCount, body.matchedCount,
    body.unmatchedCount, body.collisionCount, body.aisleRejectedCount, stableJson(body.detail)).run();
  if (body.collisionCount > 0) {
    const triageId = await deterministicId("triage", "match-run", body.id);
    await context.env.DB.prepare(
      `INSERT OR IGNORE INTO triage_items
         (id, source_kind, source_ref, severity, status, title, evidence_json)
       VALUES (?1, 'operational_alert', ?2, 'hard', 'open', ?3, ?4)`,
    ).bind(triageId, body.id, `Native matching found ${body.collisionCount} unresolved collisions`, stableJson(body.detail)).run();
  }
  await recordAudit(context.env, context.get("identity"), "matching.complete", "capture_batch", body.batchId,
    status === "passed" ? "accepted" : "failed", { runId: body.id, ...body });
  return context.json({ ok: status === "passed", runId: body.id, status, idempotent: false }, status === "passed" ? 201 : 422);
});

app.put("/internal/schedules/sync", zValidator("json", scheduleDocumentSchema), async (context) => {
  const document = context.req.valid("json");
  const identity = context.get("identity");
  if (identity.role !== "operator" && identity.role !== "engine") {
    return context.json({ ok: false, error: "operator or engine identity required" }, 403);
  }
  const statements = document.schedules.map((schedule) => context.env.DB.prepare(
    `INSERT INTO job_schedules
       (job, cron, max_gap_minutes, active, executor, authority_executor, timezone, owner, proof, dispatch_on_gap,
        lifecycle, authority_version, retirement_gate, workflow_file, monitoring_started_at)
     VALUES (?1, ?2, ?3, ?10, ?4, ?5, ?6, ?7, ?8, ?9, ?11, ?12, ?13, ?14, CURRENT_TIMESTAMP)
     ON CONFLICT(job) DO UPDATE SET
       cron = excluded.cron, max_gap_minutes = excluded.max_gap_minutes, active = excluded.active,
       executor = excluded.executor, authority_executor = excluded.authority_executor,
       timezone = excluded.timezone, owner = excluded.owner,
       proof = excluded.proof, dispatch_on_gap = excluded.dispatch_on_gap,
       lifecycle = excluded.lifecycle, authority_version = excluded.authority_version,
       retirement_gate = excluded.retirement_gate, workflow_file = excluded.workflow_file,
       monitoring_started_at = COALESCE(job_schedules.monitoring_started_at, CURRENT_TIMESTAMP)`,
  ).bind(
    schedule.id,
    schedule.cron,
    schedule.maxGapMinutes,
    schedule.executor === "codex-automation" ? "pc" : schedule.executor,
    schedule.executor,
    document.timezone,
    schedule.owner,
    schedule.proof,
    schedule.dispatchOnGap ? 1 : 0,
    schedule.monitorInLedger && schedule.lifecycle !== "retired" ? 1 : 0,
    schedule.lifecycle,
    document.version,
    schedule.retirementGate ?? null,
    schedule.workflowFile ?? null,
  ));
  const placeholders = document.schedules.map((_, index) => `?${index + 1}`).join(", ");
  statements.push(context.env.DB.prepare(
    `UPDATE job_schedules SET active = 0 WHERE job NOT IN (${placeholders})`,
  ).bind(...document.schedules.map((schedule) => schedule.id)));
  await context.env.DB.batch(statements);
  await recordAudit(context.env, identity, "schedules.sync", "schedule_authority", `v${document.version}`, "accepted", {
    count: document.schedules.length,
    timezone: document.timezone,
  });
  return context.json({ ok: true, version: document.version, schedules: document.schedules.length });
});

app.put("/internal/agents/sync", zValidator("json", agentRegistrySchema), async (context) => {
  const registry = context.req.valid("json");
  const repository = context.env.GITHUB_REPOSITORY ?? context.env.GITHUB_OIDC_REPOSITORY;
  if (!repository) return jsonError("GitHub repository is not configured", 500);
  const statements = registry.agents.map((agent) => context.env.DB.prepare(
    `INSERT INTO agent_registry
       (id, registry_version, enabled, plane, schedule_id, prompt_file, prompt_sha256, model_id,
        fallback_model_id, monthly_budget_microusd, criticality, capabilities_json,
        input_contracts_json, output_contract, fixture_files_json, provider, reasoning_effort,
        reserve_budget_percent, workflow_ref, reusable_workflow_ref, execution_config_hash, active, synced_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
             ?16, ?17, ?18, ?19, ?20, ?21, 1, CURRENT_TIMESTAMP)
     ON CONFLICT(id) DO UPDATE SET
       registry_version = excluded.registry_version, enabled = excluded.enabled, plane = excluded.plane,
       schedule_id = excluded.schedule_id, prompt_file = excluded.prompt_file,
       prompt_sha256 = excluded.prompt_sha256, model_id = excluded.model_id,
       fallback_model_id = excluded.fallback_model_id,
       monthly_budget_microusd = excluded.monthly_budget_microusd, criticality = excluded.criticality,
       capabilities_json = excluded.capabilities_json, input_contracts_json = excluded.input_contracts_json,
       output_contract = excluded.output_contract, fixture_files_json = excluded.fixture_files_json,
       provider = excluded.provider, reasoning_effort = excluded.reasoning_effort,
       reserve_budget_percent = excluded.reserve_budget_percent, workflow_ref = excluded.workflow_ref,
       reusable_workflow_ref = excluded.reusable_workflow_ref, execution_config_hash = excluded.execution_config_hash,
       active = 1, synced_at = CURRENT_TIMESTAMP`,
  ).bind(agent.id, registry.version, agent.enabled ? 1 : 0, agent.plane, agent.scheduleId ?? null,
    agent.promptFile, agent.promptSha256, agent.model, agent.fallbackModel ?? null,
    agent.monthlyBudgetMicrousd, agent.criticality, stableJson(agent.capabilities),
    stableJson(agent.inputContracts), agent.outputContract, stableJson(agent.fixtureFiles),
    agent.provider, agent.reasoningEffort, agent.reserveBudgetPercent,
    `${repository}/${agent.workflowFile}@refs/heads/main`,
    `${repository}/${agent.reusableWorkflowFile}@refs/heads/main`, agent.executionConfigHash));
  const placeholders = registry.agents.map((_, index) => `?${index + 1}`).join(", ");
  statements.push(context.env.DB.prepare(`UPDATE agent_registry SET active = 0 WHERE id NOT IN (${placeholders})`).bind(...registry.agents.map((agent) => agent.id)));
  await context.env.DB.batch(statements);
  await recordAudit(context.env, context.get("identity"), "agents.sync", "agent_registry", `v${registry.version}`, "accepted", { agents: registry.agents.length, pricingEffectiveAt: registry.pricingEffectiveAt });
  return context.json({ ok: true, version: registry.version, agents: registry.agents.length });
});

app.get("/internal/agents/:id/authorize", async (context) => {
  const identity = context.get("identity");
  if (identity.registeredAgentId && identity.registeredAgentId !== context.req.param("id")) return jsonError("an agent may only authorize its own execution", 403);
  const estimated = Number(context.req.query("estimatedCostMicrousd") ?? "0");
  if (!Number.isInteger(estimated) || estimated < 0) return jsonError("estimatedCostMicrousd must be a nonnegative integer", 422);
  const agent = await context.env.DB.prepare(
    `SELECT id, enabled, model_id, fallback_model_id, monthly_budget_microusd, criticality,
            reserve_budget_percent, execution_config_hash
       FROM agent_registry WHERE id = ?1 AND active = 1`,
  ).bind(context.req.param("id")).first<{ id: string; enabled: number; model_id: string; fallback_model_id: string | null; monthly_budget_microusd: number; criticality: string; reserve_budget_percent: number; execution_config_hash: string }>();
  if (!agent || agent.enabled !== 1) return jsonError("agent is unknown or disabled", 404);
  const evaluation = await context.env.DB.prepare(
    `SELECT id FROM agent_evaluations WHERE agent_id = ?1 AND execution_config_hash = ?2 AND passed = 1 ORDER BY evaluated_at DESC LIMIT 1`,
  ).bind(agent.id, agent.execution_config_hash).first<{ id: string }>();
  if (!evaluation) return jsonError("agent execution is blocked until this exact execution configuration passes evaluation", 422);
  const month = new Date().toISOString().slice(0, 7);
  const budget = await context.env.DB.prepare(
    `SELECT routine_spent_microusd, reserve_spent_microusd, routine_reserved_microusd, reserve_reserved_microusd
       FROM agent_budget_months WHERE agent_id = ?1 AND month_key = ?2`,
  ).bind(agent.id, month).first<{ routine_spent_microusd: number; reserve_spent_microusd: number; routine_reserved_microusd: number; reserve_reserved_microusd: number }>();
  const routineLimit = Math.floor(agent.monthly_budget_microusd * (100 - agent.reserve_budget_percent) / 100);
  const reserveLimit = agent.monthly_budget_microusd - routineLimit;
  const routineCommitted = (budget?.routine_spent_microusd ?? 0) + (budget?.routine_reserved_microusd ?? 0);
  const reserveCommitted = (budget?.reserve_spent_microusd ?? 0) + (budget?.reserve_reserved_microusd ?? 0);
  const workItemId = context.req.query("workItemId");
  const work = workItemId ? await context.env.DB.prepare("SELECT severity FROM agent_work_items WHERE id = ?1 AND agent_id = ?2").bind(workItemId, agent.id).first<{ severity: string }>() : null;
  const canUseReserve = Boolean(work && work.severity !== "optional" && agent.criticality !== "optional");
  const routineAvailable = Math.max(0, routineLimit - routineCommitted);
  const reserveNeeded = estimated > routineAvailable ? estimated : 0;
  const allowed = reserveNeeded === 0 || (canUseReserve && reserveCommitted + reserveNeeded <= reserveLimit);
  const modelId = reserveNeeded > 0 && agent.fallback_model_id ? agent.fallback_model_id : agent.model_id;
  return context.json({ ok: allowed, allowed, modelId, evaluationId: evaluation.id, budgetClass: reserveNeeded > 0 ? "reserve" : "routine", budget: { month, limitMicrousd: agent.monthly_budget_microusd, routineLimitMicrousd: routineLimit, reserveLimitMicrousd: reserveLimit, routineCommittedMicrousd: routineCommitted, reserveCommittedMicrousd: reserveCommitted, estimatedMicrousd: estimated }, requiresOperator: !allowed && agent.criticality !== "optional" }, allowed ? 200 : 422);
});

app.get("/internal/agents/:id/evaluation-status", async (context) => {
  const identity = context.get("identity");
  if (identity.registeredAgentId && identity.registeredAgentId !== context.req.param("id")) return jsonError("an agent may only inspect its own evaluation", 403);
  const agent = await context.env.DB.prepare("SELECT execution_config_hash FROM agent_registry WHERE id = ?1 AND active = 1 AND enabled = 1").bind(context.req.param("id")).first<{ execution_config_hash: string }>();
  if (!agent) return jsonError("agent is unknown or disabled", 404);
  const evaluation = await context.env.DB.prepare(
    `SELECT id, model_id, corpus_hash, score_millis, threshold_millis, evaluated_at
       FROM agent_evaluations WHERE agent_id = ?1 AND execution_config_hash = ?2 AND passed = 1
       ORDER BY evaluated_at DESC LIMIT 1`,
  ).bind(context.req.param("id"), agent.execution_config_hash).first<Record<string, unknown>>();
  return context.json({ ok: true, current: Boolean(evaluation), executionConfigHash: agent.execution_config_hash, evaluation: evaluation ?? null });
});

app.post("/internal/agent-evaluations", zValidator("json", agentEvaluationRecordSchema), async (context) => {
  const body = context.req.valid("json");
  const identity = context.get("identity");
  if (identity.registeredAgentId && identity.registeredAgentId !== body.agentId) return jsonError("an agent may only record its own evaluation", 403);
  const agent = await context.env.DB.prepare("SELECT execution_config_hash FROM agent_registry WHERE id = ?1 AND active = 1").bind(body.agentId).first<{ execution_config_hash: string }>();
  if (!agent || agent.execution_config_hash !== body.executionConfigHash) return jsonError("evaluation does not match the active execution configuration", 409);
  if (body.passed !== (body.scoreMillis >= body.thresholdMillis) || body.passedCount > body.caseCount) return jsonError("evaluation pass calculation is inconsistent", 422);
  await context.env.DB.prepare(
    `INSERT INTO agent_evaluations
       (id, agent_id, execution_config_hash, model_id, corpus_hash, evaluator_version,
        case_count, passed_count, score_millis, threshold_millis, passed, detail_json, evaluated_at, actor_id)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
     ON CONFLICT(id) DO NOTHING`,
  ).bind(body.id, body.agentId, body.executionConfigHash, body.modelId, body.corpusHash, body.evaluatorVersion,
    body.caseCount, body.passedCount, body.scoreMillis, body.thresholdMillis, body.passed ? 1 : 0,
    stableJson(body.detail), body.evaluatedAt, identity.agentId).run();
  return context.json({ ok: body.passed, evaluationId: body.id, passed: body.passed }, body.passed ? 201 : 422);
});

app.post("/internal/agent-work-items/claim", zValidator("json", agentWorkItemClaimSchema), async (context) => {
  try {
    const item = await claimAgentWorkItem(context.env.DB, context.get("identity"), context.req.valid("json"));
    return context.json({ ok: true, item });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "work-item claim failed", 422);
  }
});

app.post("/internal/agent-work-items/:id/complete", zValidator("json", agentWorkItemCompleteSchema), async (context) => {
  try {
    const identity = context.get("identity");
    const body = context.req.valid("json");
    const result = await completeAgentWorkItem(context.env.DB, identity, context.req.param("id"), body);
    if (identity.registeredAgentId === "accuracy-headless") {
      await recordAccuracyVerdicts(context.env.DB, accuracyVerdictsSchema.parse(body.output), identity.agentId);
    }
    const nextAgentId = typeof result.nextAgentId === "string" ? result.nextAgentId : null;
    let dispatch: Record<string, unknown> | null = null;
    if (nextAgentId) {
      try {
        dispatch = await dispatchRegisteredAgent(context.env, nextAgentId);
      } catch (error) {
        dispatch = { dispatched: false, error: error instanceof Error ? error.message : "unknown dispatch failure" };
        await raiseOperationalAlert(context.env, `agent-dispatch:${nextAgentId}`, `Registered agent dispatch failed for ${nextAgentId}`, dispatch);
      }
    }
    return context.json({ ok: true, ...result, dispatch });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "work-item completion failed", 409);
  }
});

app.post("/internal/agent-work-items/:id/fail", zValidator("json", agentWorkItemFailSchema), async (context) => {
  try {
    return context.json({ ok: true, ...await failAgentWorkItem(context.env.DB, context.get("identity"), context.req.param("id"), context.req.valid("json")) });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "work-item failure failed", 409);
  }
});

app.post("/internal/recipe-suggestions", zValidator("json", recipeSuggestionRequestSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may create a recipe suggestion request", 403);
  const body = context.req.valid("json");
  await context.env.DB.prepare(
    `INSERT INTO recipe_suggestion_requests (id, request_text, source_ref, requested_at)
     VALUES (?1, ?2, ?3, ?4) ON CONFLICT(id) DO NOTHING`,
  ).bind(body.id, body.request, body.sourceRef, body.requestedAt).run();
  return context.json({ ok: true, requestId: body.id }, 201);
});

app.post("/internal/recipe-waves/snapshot", zValidator("json", recipeWaveSnapshotSchema), async (context) => {
  const body = context.req.valid("json");
  const batch = await context.env.DB.prepare("SELECT status, content_hash FROM content_batches WHERE id = ?1").bind(body.contentBatchId).first<{ status: string; content_hash: string | null }>();
  if (!batch || batch.status !== "promoted") return jsonError("recipe wave requires a promoted immutable content batch", 409);
  const release = await context.env.DB.prepare(
    `SELECT release.* FROM current_releases current JOIN releases release ON release.id = current.release_id
      WHERE current.market_id = 'omaha'`,
  ).first<Record<string, unknown>>();
  if (!release) return jsonError("recipe wave requires a current release", 409);
  const snapshot = {
    capturedAt: new Date().toISOString(),
    releaseId: release.id,
    configurationId: release.configuration_id,
    inputHash: release.input_hash,
    boardHash: release.board_hash,
    recipeHash: release.recipe_hash,
    summary: JSON.parse(String(release.summary_json ?? "{}")),
    contentBatchId: body.contentBatchId,
    contentHash: batch.content_hash,
  };
  await context.env.DB.prepare(
    `INSERT INTO recipe_wave_runs (id, content_batch_id, pre_wave_release_id, snapshot_json, status)
     VALUES (?1, ?2, ?3, ?4, 'snapshotted') ON CONFLICT(id) DO NOTHING`,
  ).bind(body.id, body.contentBatchId, release.id, stableJson(snapshot)).run();
  return context.json({ ok: true, waveId: body.id, snapshot }, 201);
});

app.post("/internal/recipe-waves/:id/published", zValidator("json", recipeWavePublicationSchema), async (context) => {
  const body = context.req.valid("json");
  const current = await context.env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'").first<{ release_id: string }>();
  if (!current || current.release_id !== body.releaseId) return jsonError("the claimed wave release is not the current published release", 409);
  const update = await context.env.DB.prepare(
    `UPDATE recipe_wave_runs SET wave_release_id = ?2, status = 'published', updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND status = 'snapshotted'`,
  ).bind(context.req.param("id"), body.releaseId).run();
  if ((update.meta.changes ?? 0) !== 1) return jsonError("recipe wave is not awaiting publication", 409);
  return context.json({ ok: true, waveId: context.req.param("id"), releaseId: body.releaseId });
});

app.post("/internal/recipe-waves/:id/corrective-release", async (context) => {
  const wave = await context.env.DB.prepare("SELECT * FROM recipe_wave_runs WHERE id = ?1").bind(context.req.param("id")).first<Record<string, unknown>>();
  if (!wave || wave.status !== "published" || !wave.wave_release_id) return jsonError("recipe wave is not eligible for correction", 409);
  const current = await context.env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'").first<{ release_id: string }>();
  if (!current || current.release_id !== wave.wave_release_id) return jsonError("current release changed after the wave; refusing to clobber it", 409);
  const source = await context.env.DB.prepare("SELECT * FROM releases WHERE id = ?1").bind(String(wave.pre_wave_release_id)).first<Record<string, unknown>>();
  if (!source) return jsonError("pre-wave immutable release no longer exists", 409);
  const correctiveId = `rel_corrective_${crypto.randomUUID().replaceAll("-", "")}`;
  const inputManifest = { kind: "recipe-wave-corrective-v1", waveId: wave.id, preWaveReleaseId: wave.pre_wave_release_id, supersedesWaveReleaseId: wave.wave_release_id };
  const inputHash = await digestHex(stableJson({ correctiveId, inputManifest, sourceInputHash: source.input_hash }));
  const statements: D1PreparedStatement[] = [
    context.env.DB.prepare(
      `INSERT INTO releases
         (id, market_id, configuration_id, input_manifest_json, input_hash, state, board_hash, recipe_hash, summary_json)
       SELECT ?1, market_id, configuration_id, ?2, ?3, 'draft', board_hash, recipe_hash, summary_json
         FROM releases WHERE id = ?4`,
    ).bind(correctiveId, stableJson(inputManifest), inputHash, source.id),
    context.env.DB.prepare("INSERT INTO release_input_batches SELECT ?1, batch_id, ordinal FROM release_input_batches WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_cells SELECT ?1, commodity_id, store_location_id, observation_id, status, is_crown, display_per_unit_micros, display_unit, reason_json FROM release_cells WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_recipe_costs SELECT ?1, recipe_slug, status, batch_cost_minor, serving_cost_minor, servings, missing_ingredients_json, detail_json FROM release_recipe_costs WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_payloads SELECT ?1, kind, payload_json, content_hash FROM release_payloads WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_top5 SELECT ?1, protein, rank, recipe_slug, serving_cost_minor FROM release_top5 WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_free_rotation SELECT ?1, recipe_slug, intended_visibility, protein, rank FROM release_free_rotation WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_feed_entries SELECT ?1, entry_key, ordinal, payload_json FROM release_feed_entries WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("UPDATE recipe_wave_runs SET corrective_release_id = ?2, status = 'corrective_draft', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(wave.id, correctiveId),
  ];
  await context.env.DB.batch(statements);
  await recordAudit(context.env, context.get("identity"), "recipe_wave.corrective_release", "recipe_wave", String(wave.id), "accepted", { correctiveId, preWaveReleaseId: source.id, waveReleaseId: wave.wave_release_id });
  return context.json({ ok: true, waveId: wave.id, correctiveReleaseId: correctiveId, next: [`validate ${correctiveId}`, `publish ${correctiveId}`] }, 201);
});

app.post("/internal/recipe-waves/:id/corrected", async (context) => {
  const wave = await context.env.DB.prepare("SELECT corrective_release_id, status FROM recipe_wave_runs WHERE id = ?1").bind(context.req.param("id")).first<{ corrective_release_id: string | null; status: string }>();
  if (!wave || wave.status !== "corrective_draft" || !wave.corrective_release_id) return jsonError("recipe wave has no corrective draft", 409);
  const current = await context.env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'").first<{ release_id: string }>();
  if (!current || current.release_id !== wave.corrective_release_id) return jsonError("corrective release is not current", 409);
  await context.env.DB.prepare("UPDATE recipe_wave_runs SET status = 'corrected', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(context.req.param("id")).run();
  return context.json({ ok: true, waveId: context.req.param("id"), correctiveReleaseId: wave.corrective_release_id });
});

app.post("/internal/login-canary-probes", zValidator("json", loginCanaryProbeSchema), async (context) => {
  const body = context.req.valid("json");
  const evidenceText = stableJson(body.evidence);
  try { assertLoginCanaryEvidenceHasNoEmail(body.evidence); } catch (error) { return jsonError(error instanceof Error ? error.message : "login-canary evidence contains personal data", 422); }
  await context.env.DB.prepare(
    `INSERT INTO login_canary_probes
       (id, store_id, run_id, ordinal, status, signal, evidence_json, observed_at, actor_id)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) ON CONFLICT(id) DO NOTHING`,
  ).bind(body.id, body.storeId, body.runId, body.ordinal, body.status, body.signal,
    evidenceText, body.observedAt, context.get("identity").agentId).run();
  const pair = await context.env.DB.prepare(
    `SELECT ordinal, status, observed_at FROM login_canary_probes
      WHERE run_id = ?1 AND store_id = ?2 ORDER BY ordinal`,
  ).bind(body.runId, body.storeId).all<{ ordinal: number; status: string; observed_at: string }>();
  const first = pair.results.find((row) => row.ordinal === 1);
  const second = pair.results.find((row) => row.ordinal === 2);
  const separationMinutes = first && second ? (Date.parse(second.observed_at) - Date.parse(first.observed_at)) / 60000 : null;
  const passed = Boolean(first && second && first.status === "healthy" && second.status === "healthy" && separationMinutes !== null && separationMinutes >= 9 && separationMinutes <= 30);
  return context.json({ ok: true, probeId: body.id, pairComplete: Boolean(first && second), passed, separationMinutes }, 201);
});

app.post("/internal/jobs/:job/dispatch", zValidator("json", jobDispatchSchema), async (context) => {
  const job = context.req.param("job");
  const schedule = await context.env.DB.prepare(
    "SELECT job FROM job_schedules WHERE job = ?1 AND active = 1",
  ).bind(job).first();
  if (!schedule) return jsonError("unknown or inactive job", 404);
  const body = context.req.valid("json");
  const result = await dispatchGithubJob(context.env, job, body.reason, body.idempotencyKey, body.ref);
  await recordAudit(context.env, context.get("identity"), "job.dispatch", "job_schedule", job, result.status === "dispatched" ? "accepted" : "failed", result);
  return context.json({ ok: result.status === "dispatched", ...result }, result.status === "dispatched" ? 202 : 500);
});

app.get("/internal/jobs/github-runs", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may inspect GitHub workflow runs", 403);
  const requestedLimit = Number(context.req.query("limit") ?? "5");
  if (!Number.isInteger(requestedLimit) || requestedLimit < 1 || requestedLimit > 10) return jsonError("limit must be an integer from 1 through 10", 422);
  try {
    return context.json({ ok: true, ...await githubWorkflowRuns(context.env, requestedLimit) });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "GitHub Actions inspection failed", 502);
  }
});

app.get("/internal/engine/snapshot", async (context) => {
  const requested = context.req.query("mode") ?? "legacy";
  if (!(["legacy", "direct", "all"] as const).includes(requested as EngineSourceMode)) return jsonError("engine mode must be legacy, direct, or all", 422);
  const requestedProfile = context.req.query("profile") ?? "release";
  if (!(["release", "parity"] as const).includes(requestedProfile as EngineSnapshotProfile)) return jsonError("engine snapshot profile must be release or parity", 422);
  try {
    return context.json(await readEngineSnapshot(context.env, requested as EngineSourceMode, requestedProfile as EngineSnapshotProfile));
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "engine snapshot failed", 422);
  }
});

app.post("/internal/engine/parity", zValidator("json", engineParityReportSchema), async (context) => {
  const body = context.req.valid("json");
  const existing = await context.env.DB.prepare("SELECT status, diff_count FROM engine_parity_runs WHERE id = ?1").bind(body.runId).first<{ status: string; diff_count: number }>();
  if (existing) return context.json({ ok: existing.status === "passed", runId: body.runId, status: existing.status, diffCount: existing.diff_count, idempotent: true });
  // The CLI already computed parity from the immutable full snapshot. Rebuilding all candidate/product rows
  // here only to authenticate four identity fields exceeded Worker CPU limits at production scale.
  const snapshot = await readEngineSnapshotIdentity(context.env, body.mode);
  if (snapshot.currentReleaseId !== body.currentReleaseId || snapshot.configurationId !== body.configurationId || snapshot.inputHash !== body.inputHash || stableJson(snapshot.inputBatchIds) !== stableJson([...body.inputBatchIds].sort())) {
    return jsonError("parity report does not match the current immutable engine snapshot", 409);
  }
  const status = body.diffCount === 0 ? "passed" : "failed";
  await context.env.DB.prepare(
    `INSERT INTO engine_parity_runs
       (id, mode, current_release_id, configuration_id, input_hash, input_batch_ids_json,
        compared_cells, diff_count, status, detail_json, observed_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`,
  ).bind(body.runId, body.mode, body.currentReleaseId, body.configurationId, body.inputHash, stableJson([...body.inputBatchIds].sort()), body.comparedCells, body.diffCount, status, stableJson({ diffs: body.diffs }), body.observedAt).run();
  if (body.diffCount > 0) {
    const triageId = await deterministicId("triage", "engine-parity", body.runId);
    await context.env.DB.prepare(
      `INSERT OR IGNORE INTO triage_items
         (id, source_kind, source_ref, severity, status, title, evidence_json)
       VALUES (?1, 'operational_alert', ?2, 'warning', 'open', ?3, ?4)`,
    ).bind(triageId, body.runId, `Native ${body.mode} engine has ${body.diffCount} parity differences`, stableJson({ runId: body.runId, inputHash: body.inputHash, diffs: body.diffs })).run();
  }
  await recordAudit(context.env, context.get("identity"), "engine.parity", "engine_parity_run", body.runId, status === "passed" ? "accepted" : "failed", { mode: body.mode, comparedCells: body.comparedCells, diffCount: body.diffCount });
  return context.json({ ok: status === "passed", runId: body.runId, status, diffCount: body.diffCount, idempotent: false }, status === "passed" ? 201 : 422);
});

app.post("/internal/backups/trigger", async (context) => {
  const instanceId = `d1-backup-manual-${crypto.randomUUID()}`;
  const forceReplica = context.req.query("replica") === "1";
  await context.env.BACKUP_WORKFLOW.create({ id: instanceId, params: { trigger: "operator", forceReplica } });
  await recordAudit(context.env, context.get("identity"), "backup.trigger", "workflow", instanceId, "accepted");
  return context.json({ ok: true, instanceId, forceReplica }, 202);
});

app.post("/internal/restore-drills/trigger", async (context) => {
  const now = new Date();
  const quarter = `${now.getUTCFullYear()}-Q${Math.floor(now.getUTCMonth() / 3) + 1}`;
  const quarterStart = new Date(Date.UTC(now.getUTCFullYear(), Math.floor(now.getUTCMonth() / 3) * 3, 1)).toISOString();
  const force = context.req.query("force") === "1";
  const passed = await context.env.DB.prepare(
    "SELECT id FROM restore_drills WHERE status = 'passed' AND started_at >= ?1 ORDER BY started_at DESC LIMIT 1",
  ).bind(quarterStart).first<{ id: string }>();
  if (passed && !force) return context.json({ ok: true, instanceId: passed.id.replace(/^restore_/, ""), quarter, idempotent: true }, 200);
  const attempts = await context.env.DB.prepare(
    "SELECT COUNT(*) AS count FROM job_runs WHERE job = 'restore-drill-quarterly' AND started_at >= ?1",
  ).bind(quarterStart).first<{ count: number }>();
  const instanceId = `d1-restore-${quarter}-a${(attempts?.count ?? 0) + 1}`;
  try {
    await context.env.RESTORE_WORKFLOW.create({ id: instanceId, params: { trigger: force ? "operator-forced" : "operator-or-schedule" } });
  } catch (error) {
    const message = error instanceof Error ? error.message : "restore workflow create failed";
    if (!message.toLowerCase().includes("already")) throw error;
  }
  await recordAudit(context.env, context.get("identity"), "restore_drill.trigger", "workflow", instanceId, "accepted", { quarter, force });
  return context.json({ ok: true, instanceId, quarter, force, idempotent: false }, 202);
});

app.post("/internal/restore-drills/cleanup", zValidator("json", restoreDrillCleanupSchema), async (context) => {
  const body = context.req.valid("json");
  const normalizedObjectKey = `restore-normalized/${body.instanceId}/${body.backupId}/${body.dumpSha256}.sql`;
  const normalizedStagingObjectKey = `restore-normalized-staging/${body.instanceId}/${body.backupId}/${body.dumpSha256}.multipart.sql`;
  const recoveryObjectPrefix = `restore-recovery/${body.instanceId}/`;
  let multipartStatus = "aborted";
  try {
    await context.env.BACKUPS.resumeMultipartUpload(normalizedStagingObjectKey, body.uploadId).abort();
  } catch (error) {
    if (!isMissingMultipartUploadError(error)) throw error;
    multipartStatus = "absent";
  }
  await context.env.BACKUPS.delete([normalizedObjectKey, normalizedStagingObjectKey]);
  let cursor: string | undefined;
  let deletedRecoveryObjects = 0;
  do {
    const listed = await context.env.BACKUPS.list({ prefix: recoveryObjectPrefix, limit: 1_000, ...(cursor ? { cursor } : {}) });
    const keys = listed.objects.map((object) => object.key);
    if (keys.length > 0) {
      await context.env.BACKUPS.delete(keys);
      deletedRecoveryObjects += keys.length;
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  await recordAudit(context.env, context.get("identity"), "restore_drill.cleanup", "workflow", body.instanceId, "accepted", {
    multipartStatus,
    normalizedObjectKey,
    normalizedStagingObjectKey,
    recoveryObjectPrefix,
    deletedRecoveryObjects,
  });
  return context.json({ ok: true, instanceId: body.instanceId, multipartStatus, deletedRecoveryObjects });
});

app.get("/internal/restore-drills", async (context) => {
  const rows = await context.env.DB.prepare(
    "SELECT * FROM restore_drills ORDER BY started_at DESC LIMIT 100",
  ).all<Record<string, unknown>>();
  return context.json({ ok: true, drills: rows.results.map((row) => ({
    ...row,
    evidence: JSON.parse(String(row.evidence_json ?? "{}")),
    evidence_json: undefined,
  })) });
});

app.post("/internal/restore-drills", zValidator("json", restoreDrillRecordSchema), async (context) => {
  const body = context.req.valid("json");
  const backup = await context.env.DB.prepare("SELECT id FROM backup_exports WHERE id = ?1").bind(body.backupId).first();
  if (!backup) return jsonError("backup export not found", 404);
  const existing = await context.env.DB.prepare(
    "SELECT backup_id, scratch_database_id, dump_sha256, status FROM restore_drills WHERE id = ?1",
  ).bind(body.id).first<{ backup_id: string; scratch_database_id: string; dump_sha256: string; status: string }>();
  if (existing) {
    const sameIdentity = existing.backup_id === body.backupId
      && existing.scratch_database_id === body.scratchDatabaseId
      && existing.dump_sha256 === body.dumpSha256;
    if (!sameIdentity) return jsonError("restore drill id already belongs to different evidence", 409);
    if (existing.status === body.status) return context.json({ ok: true, drillId: body.id, status: existing.status, idempotent: true });
    if (existing.status !== "started") return jsonError(`restore drill is immutable in ${existing.status} state`, 409);
    await context.env.DB.prepare(
      "UPDATE restore_drills SET status = ?2, finished_at = ?3, evidence_json = ?4 WHERE id = ?1",
    ).bind(body.id, body.status, body.finishedAt ?? null, stableJson(body.evidence)).run();
  } else {
    await context.env.DB.prepare(
      `INSERT INTO restore_drills
         (id, backup_id, scratch_database_id, dump_sha256, status, started_at, finished_at, evidence_json)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
    ).bind(body.id, body.backupId, body.scratchDatabaseId, body.dumpSha256, body.status, body.startedAt, body.finishedAt ?? null, stableJson(body.evidence)).run();
  }
  await recordAudit(context.env, context.get("identity"), "restore_drill.record", "restore_drill", body.id, body.status === "passed" ? "accepted" : body.status === "failed" ? "failed" : "accepted", body.evidence);
  return context.json({ ok: body.status !== "failed", drillId: body.id, status: body.status, idempotent: false }, body.status === "failed" ? 422 : 201);
});

app.get("/internal/evidence-gates", async (context) => {
  const gate = context.req.query("gate");
  const rows = gate
    ? await context.env.DB.prepare("SELECT * FROM evidence_gate_events WHERE gate = ?1 ORDER BY observed_at DESC LIMIT 500").bind(gate).all<Record<string, unknown>>()
    : await context.env.DB.prepare("SELECT * FROM evidence_gate_events ORDER BY observed_at DESC LIMIT 500").all<Record<string, unknown>>();
  return context.json({ ok: true, events: rows.results.map((row) => ({ ...row, evidence: JSON.parse(String(row.evidence_json ?? "{}")), evidence_json: undefined })) });
});

app.post("/internal/evidence-gates", zValidator("json", evidenceGateRecordSchema), async (context) => {
  const body = context.req.valid("json");
  const existing = await context.env.DB.prepare(
    "SELECT gate, period_key, source_ref, status FROM evidence_gate_events WHERE id = ?1",
  ).bind(body.id).first<{ gate: string; period_key: string; source_ref: string; status: string }>();
  if (existing) {
    const identical = existing.gate === body.gate && existing.period_key === body.periodKey && existing.source_ref === body.sourceRef && existing.status === body.status;
    if (!identical) return jsonError("evidence event id already belongs to different evidence", 409);
    return context.json({ ok: body.status === "pass", eventId: body.id, status: body.status, idempotent: true });
  }
  try {
    await context.env.DB.prepare(
      `INSERT INTO evidence_gate_events (id, gate, period_key, source_ref, status, evidence_json, observed_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
    ).bind(body.id, body.gate, body.periodKey, body.sourceRef, body.status, stableJson(body.evidence), body.observedAt).run();
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "evidence gate insert failed", 409);
  }
  await recordAudit(context.env, context.get("identity"), "evidence_gate.record", "evidence_gate_event", body.id, body.status === "pass" ? "accepted" : "failed", body.evidence);
  return context.json({ ok: body.status === "pass", eventId: body.id, status: body.status, idempotent: false }, body.status === "pass" ? 201 : 422);
});

app.post("/internal/evidence-gates/accrue", zValidator("json", milestoneAccrualSchema), async (context) => {
  try {
    const result = await accrueMilestoneEvidence(context.env, new Date(), context.req.valid("json").edgeProof);
    await recordAudit(context.env, context.get("identity"), "evidence_gate.accrue", "evidence_gate_event", null, "accepted", result);
    return context.json(result);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "milestone evidence accrual failed", 422);
  }
});

app.get("/internal/entitlement-verifications", async (context) => {
  const rows = await context.env.DB.prepare("SELECT * FROM entitlement_verifications ORDER BY verified_at DESC LIMIT 500").all<Record<string, unknown>>();
  return context.json({ ok: true, verifications: rows.results.map((row) => ({ ...row, evidence: JSON.parse(String(row.evidence_json ?? "{}")), evidence_json: undefined })) });
});

app.post("/internal/entitlement-verifications", zValidator("json", entitlementVerificationRecordSchema), async (context) => {
  const body = context.req.valid("json");
  const existing = await context.env.DB.prepare("SELECT state, client_kind, status FROM entitlement_verifications WHERE id = ?1")
    .bind(body.id).first<{ state: string; client_kind: string; status: string }>();
  if (existing) {
    const identical = existing.state === body.state && existing.client_kind === body.clientKind && existing.status === body.status;
    if (!identical) return jsonError("entitlement verification id already belongs to different evidence", 409);
    return context.json({ ok: body.status === "pass", verificationId: body.id, status: body.status, idempotent: true });
  }
  await context.env.DB.prepare(
    `INSERT INTO entitlement_verifications
       (id, adapter_version, state, client_kind, status, evidence_json, verified_at, verified_by)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  ).bind(body.id, body.adapterVersion, body.state, body.clientKind, body.status, stableJson(body.evidence), body.verifiedAt, context.get("identity").agentId).run();
  await recordAudit(context.env, context.get("identity"), "entitlement.verify", "entitlement_verification", body.id, body.status === "pass" ? "accepted" : "failed", body.evidence);
  return context.json({ ok: body.status === "pass", verificationId: body.id, status: body.status, idempotent: false }, body.status === "pass" ? 201 : 422);
});

app.post("/internal/job-runs", zValidator("json", jobRunCreateSchema), async (context) => {
  const body = context.req.valid("json");
  const identity = context.get("identity");
  if (identity.registeredAgentId) {
    if (body.agentId !== identity.registeredAgentId) return jsonError("registered workflow job identity mismatch", 403);
    const assignment = await context.env.DB.prepare("SELECT schedule_id FROM agent_registry WHERE id = ?1 AND active = 1").bind(identity.registeredAgentId).first<{ schedule_id: string | null }>();
    if (!assignment?.schedule_id || assignment.schedule_id !== body.job) return jsonError("registered agent is not assigned to this schedule", 403);
  }
  const schedule = await context.env.DB.prepare("SELECT job FROM job_schedules WHERE job = ?1 AND active = 1").bind(body.job).first();
  if (!schedule) return jsonError("unknown or inactive job", 404);
  const existing = await context.env.DB.prepare("SELECT job, status FROM job_runs WHERE id = ?1").bind(body.id).first<{ job: string; status: string }>();
  if (existing) {
    if (existing.job !== body.job) return jsonError("job run id belongs to another job", 409);
    return context.json({ ok: true, runId: body.id, status: existing.status, idempotent: true });
  }
  let budgetReservation: { agentId: string; month: string; estimatedCostMicrousd: number; budgetClass: "routine" | "reserve" } | undefined;
  if (body.agentId) {
    const agent = await context.env.DB.prepare(
      "SELECT enabled, prompt_sha256, model_id, fallback_model_id, monthly_budget_microusd, criticality, reserve_budget_percent FROM agent_registry WHERE id = ?1 AND active = 1",
    ).bind(body.agentId).first<{ enabled: number; prompt_sha256: string; model_id: string; fallback_model_id: string | null; monthly_budget_microusd: number; criticality: string; reserve_budget_percent: number }>();
    if (!agent || agent.enabled !== 1) return jsonError("agent is unknown or disabled", 404);
    if (body.promptHash !== agent.prompt_sha256) return jsonError("agent prompt hash differs from the active registry", 409);
    if (body.modelId !== agent.model_id && body.modelId !== agent.fallback_model_id) return jsonError("agent model is not authorized by the active registry", 409);
    const month = new Date().toISOString().slice(0, 7);
    const budget = await context.env.DB.prepare(
      `SELECT routine_spent_microusd, reserve_spent_microusd, routine_reserved_microusd, reserve_reserved_microusd
         FROM agent_budget_months WHERE agent_id = ?1 AND month_key = ?2`,
    ).bind(body.agentId, month).first<{ routine_spent_microusd: number; reserve_spent_microusd: number; routine_reserved_microusd: number; reserve_reserved_microusd: number }>();
    const routineLimit = Math.floor(agent.monthly_budget_microusd * (100 - agent.reserve_budget_percent) / 100);
    const reserveLimit = agent.monthly_budget_microusd - routineLimit;
    const routineCommitted = (budget?.routine_spent_microusd ?? 0) + (budget?.routine_reserved_microusd ?? 0);
    const reserveCommitted = (budget?.reserve_spent_microusd ?? 0) + (budget?.reserve_reserved_microusd ?? 0);
    const workItemId = typeof body.input.workItemId === "string" ? body.input.workItemId : null;
    const work = workItemId ? await context.env.DB.prepare("SELECT severity FROM agent_work_items WHERE id = ?1 AND agent_id = ?2").bind(workItemId, body.agentId).first<{ severity: string }>() : null;
    const routineAvailable = Math.max(0, routineLimit - routineCommitted);
    const useReserve = body.estimatedCostMicrousd > routineAvailable;
    const reserveNeeded = useReserve ? body.estimatedCostMicrousd : 0;
    if (useReserve && (!work || work.severity === "optional" || agent.criticality === "optional" || reserveCommitted + reserveNeeded > reserveLimit)) return jsonError("agent budget class is exhausted or the work item is not reserve-eligible", 422);
    budgetReservation = { agentId: body.agentId, month, estimatedCostMicrousd: body.estimatedCostMicrousd, budgetClass: useReserve ? "reserve" : "routine" };
  }
  const status = body.startedAt ? "started" : "scheduled";
  const insertRun = context.env.DB.prepare(
    `INSERT INTO job_runs
       (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, input_json,
        executor_run_id, actor_id, prompt_hash, input_hash, model_id, agent_id, ledger_mode,
        mutation_authorized, estimated_cost_microusd, budget_class)
     VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)`,
  ).bind(
    body.id,
    body.job,
    body.triggerKind,
    body.scheduledFor ?? null,
    body.startedAt ?? null,
    status,
    stableJson(body.input),
    body.executorRunId ?? null,
    identity.agentId,
    body.promptHash ?? null,
    body.inputHash ?? null,
    body.modelId ?? null,
    body.agentId ?? null,
    body.ledgerMode,
    body.mutationAuthorized ? 1 : 0,
    body.estimatedCostMicrousd,
    budgetReservation?.budgetClass ?? null,
  );
  if (budgetReservation) {
    const reserveBudget = context.env.DB.prepare(
      `INSERT INTO agent_budget_months
         (agent_id, month_key, spent_microusd, reserved_microusd, routine_reserved_microusd, reserve_reserved_microusd)
       VALUES (?1, ?2, 0, ?3, ?4, ?5)
       ON CONFLICT(agent_id, month_key) DO UPDATE SET
         reserved_microusd = reserved_microusd + excluded.reserved_microusd,
         routine_reserved_microusd = routine_reserved_microusd + excluded.routine_reserved_microusd,
         reserve_reserved_microusd = reserve_reserved_microusd + excluded.reserve_reserved_microusd,
         updated_at = CURRENT_TIMESTAMP`,
    ).bind(budgetReservation.agentId, budgetReservation.month, budgetReservation.estimatedCostMicrousd,
      budgetReservation.budgetClass === "routine" ? budgetReservation.estimatedCostMicrousd : 0,
      budgetReservation.budgetClass === "reserve" ? budgetReservation.estimatedCostMicrousd : 0);
    await context.env.DB.batch([insertRun, reserveBudget]);
  } else {
    await insertRun.run();
  }
  return context.json({ ok: true, runId: body.id, status, idempotent: false }, 201);
});

app.patch("/internal/job-runs/:id", zValidator("json", jobRunUpdateSchema), async (context) => {
  const body = context.req.valid("json");
  const current = await context.env.DB.prepare("SELECT job, status, started_at, finished_at, trigger_kind, executor_run_id, agent_id, estimated_cost_microusd, budget_class FROM job_runs WHERE id = ?1").bind(context.req.param("id")).first<{
    job: string; status: string; started_at: string | null; finished_at: string | null; trigger_kind: string; executor_run_id: string | null; agent_id: string | null; estimated_cost_microusd: number; budget_class: "routine" | "reserve" | null;
  }>();
  if (!current) return jsonError("job run not found", 404);
  const updateIdentity = context.get("identity");
  if (updateIdentity.registeredAgentId && current.agent_id !== updateIdentity.registeredAgentId) return jsonError("registered agent may only update its own job run", 403);
  if (current.status === body.status && current.finished_at === (body.finishedAt ?? null)) {
    return context.json({ ok: true, runId: context.req.param("id"), status: current.status, idempotent: true });
  }
  const allowed: Record<string, string[]> = {
    scheduled: ["started", "missed", "cancelled"],
    started: ["completed", "failed", "timed_out", "cancelled"],
  };
  if (!allowed[current.status]?.includes(body.status)) return jsonError(`invalid job transition ${current.status} -> ${body.status}`, 409);
  const startedAt = body.startedAt ?? current.started_at;
  if (body.status !== "missed" && !startedAt) return jsonError("startedAt is required once a job starts", 422);
  await context.env.DB.prepare(
    `UPDATE job_runs SET status = ?2, started_at = ?3, heartbeat_at = ?4, finished_at = ?5,
       output_hash = ?6, input_tokens = ?7, output_tokens = ?8, cache_read_tokens = ?9,
       cache_write_tokens = ?10, cost_microusd = ?11, stats_json = ?12, error = ?13
      WHERE id = ?1`,
  ).bind(
    context.req.param("id"),
    body.status,
    startedAt,
    body.heartbeatAt ?? body.finishedAt ?? startedAt,
    body.finishedAt ?? null,
    body.outputHash ?? null,
    body.usage.inputTokens,
    body.usage.outputTokens,
    body.usage.cacheReadTokens,
    body.usage.cacheWriteTokens,
    body.usage.costMicrousd,
    stableJson(body.stats),
    body.error ?? null,
  ).run();
  if (current.agent_id) {
    const month = new Date(startedAt ?? body.finishedAt ?? Date.now()).toISOString().slice(0, 7);
    await context.env.DB.prepare(
      `UPDATE agent_budget_months
          SET spent_microusd = spent_microusd + ?3,
              reserved_microusd = MAX(0, reserved_microusd - ?4),
              routine_spent_microusd = routine_spent_microusd + CASE WHEN ?5 = 'routine' THEN ?3 ELSE 0 END,
              reserve_spent_microusd = reserve_spent_microusd + CASE WHEN ?5 = 'reserve' THEN ?3 ELSE 0 END,
              routine_reserved_microusd = MAX(0, routine_reserved_microusd - CASE WHEN ?5 = 'routine' THEN ?4 ELSE 0 END),
              reserve_reserved_microusd = MAX(0, reserve_reserved_microusd - CASE WHEN ?5 = 'reserve' THEN ?4 ELSE 0 END),
              updated_at = CURRENT_TIMESTAMP
        WHERE agent_id = ?1 AND month_key = ?2`,
    ).bind(current.agent_id, month, body.usage.costMicrousd, current.estimated_cost_microusd, current.budget_class ?? "routine").run();
  }
  if (body.status === "completed") {
    await resolveRecoveredJobRunAlerts(
      context.env,
      current.job,
      context.req.param("id"),
      body.finishedAt ?? new Date().toISOString(),
    );
  }
  const alert = jobStatusRequiresAlert(body.status)
    ? await raiseOperationalAlert(
      context.env,
      `job-run:${context.req.param("id")}`,
      `Scheduled job ${current.job} ended ${body.status}`,
      {
        runId: context.req.param("id"),
        job: current.job,
        status: body.status,
        triggerKind: current.trigger_kind,
        executorRunId: current.executor_run_id,
        startedAt,
        finishedAt: body.finishedAt ?? null,
        error: body.error ?? null,
        stats: body.stats,
      },
      { notification: "digest", deferMinutes: 15, observedAt: body.finishedAt ?? new Date().toISOString() },
    )
    : null;
  return context.json({ ok: true, runId: context.req.param("id"), status: body.status, idempotent: false, alert });
});

app.get("/internal/content-batches", async (context) => {
  const rows = await context.env.DB.prepare("SELECT * FROM content_batches ORDER BY created_at DESC LIMIT 100").all<Record<string, unknown>>();
  return context.json({ ok: true, batches: rows.results });
});

app.post("/internal/content-batches", zValidator("json", contentBatchCreateSchema), async (context) => {
  const body = context.req.valid("json");
  const existing = await context.env.DB.prepare("SELECT status, input_hash, prompt_hash FROM content_batches WHERE id = ?1").bind(body.id)
    .first<{ status: string; input_hash: string; prompt_hash: string }>();
  if (existing) {
    if (existing.input_hash !== body.inputHash || existing.prompt_hash !== body.promptHash) return jsonError("content batch id belongs to different immutable inputs", 409);
    return context.json({ ok: true, batchId: body.id, status: existing.status, idempotent: true });
  }
  await context.env.DB.prepare(
    `INSERT INTO content_batches (id, kind, input_hash, prompt_hash, source_refs_json, created_by)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  ).bind(body.id, body.kind, body.inputHash, body.promptHash, stableJson(body.sourceRefs), context.get("identity").agentId).run();
  await recordAudit(context.env, context.get("identity"), "content_batch.create", "content_batch", body.id, "accepted", { kind: body.kind, sourceRefs: body.sourceRefs.length });
  return context.json({ ok: true, batchId: body.id, status: "staging", idempotent: false }, 201);
});

app.post("/internal/content-batches/:id/items", zValidator("json", contentBatchItemsSchema), async (context) => {
  const body = context.req.valid("json");
  const batch = await context.env.DB.prepare("SELECT status FROM content_batches WHERE id = ?1").bind(context.req.param("id")).first<{ status: string }>();
  if (!batch) return jsonError("content batch not found", 404);
  if (batch.status !== "staging") return jsonError(`content batch items are immutable in ${batch.status}`, 409);
  const statements: D1PreparedStatement[] = [];
  for (const [ordinal, item] of body.items.entries()) {
    const content = stableJson(item);
    const hash = await digestHex(content);
    statements.push(context.env.DB.prepare(
      `INSERT INTO content_batch_items (batch_id, slug, ordinal, content_json, content_hash)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    ).bind(context.req.param("id"), item.slug, ordinal, content, hash));
  }
  await context.env.DB.batch(statements);
  return context.json({ ok: true, batchId: context.req.param("id"), items: body.items.length }, 201);
});

app.post("/internal/content-batches/:id/audit", zValidator("json", contentBatchAuditSchema), async (context) => {
  const body = context.req.valid("json");
  const batch = await context.env.DB.prepare("SELECT status FROM content_batches WHERE id = ?1").bind(context.req.param("id")).first<{ status: string }>();
  if (!batch) return jsonError("content batch not found", 404);
  if (batch.status !== "staging") return jsonError(`content batch cannot be audited from ${batch.status}`, 409);
  const count = await context.env.DB.prepare("SELECT COUNT(*) AS count FROM content_batch_items WHERE batch_id = ?1").bind(context.req.param("id")).first<{ count: number }>();
  if (!count?.count) return jsonError("content batch has no items", 422);
  const hard = body.findings.filter((finding) => finding.severity === "hard").length;
  const warnings = body.findings.filter((finding) => finding.severity === "warning").length;
  const auditId = await deterministicId("content-audit", context.req.param("id"), body.auditorAgentId, body.promptHash);
  await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT INTO content_batch_audits
         (id, batch_id, auditor_agent_id, prompt_hash, findings_json, hard_findings, warning_findings)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
    ).bind(auditId, context.req.param("id"), body.auditorAgentId, body.promptHash, stableJson(body.findings), hard, warnings),
    context.env.DB.prepare("UPDATE content_batches SET status = ?2, sealed_at = CURRENT_TIMESTAMP WHERE id = ?1")
      .bind(context.req.param("id"), hard > 0 ? "rejected" : "audited"),
  ]);
  return context.json({ ok: hard === 0, batchId: context.req.param("id"), auditId, hardFindings: hard, warningFindings: warnings }, hard === 0 ? 201 : 422);
});

app.post("/internal/content-batches/:id/promote", async (context) => {
  const batchId = context.req.param("id");
  const batch = await context.env.DB.prepare("SELECT status FROM content_batches WHERE id = ?1").bind(batchId).first<{ status: string }>();
  if (!batch) return jsonError("content batch not found", 404);
  if (batch.status === "promoted") return context.json({ ok: true, batchId, status: "promoted", idempotent: true });
  if (batch.status !== "audited") return jsonError(`content batch cannot be promoted from ${batch.status}`, 409);
  const rows = await context.env.DB.prepare("SELECT content_json FROM content_batch_items WHERE batch_id = ?1 ORDER BY ordinal").bind(batchId).all<{ content_json: string }>();
  const items = rows.results.map((row) => contentItemSchema.parse(JSON.parse(row.content_json)));
  const commodities = await context.env.DB.prepare(
    `SELECT c.id FROM commodities c JOIN configuration_versions v ON v.id = c.configuration_id WHERE v.active = 1`,
  ).all<{ id: string }>();
  const guard = await evaluateContentPromotion(items, new Set(commodities.results.map((row) => row.id)));
  if (!guard.ok) {
    await context.env.DB.prepare("UPDATE content_batches SET status = 'rejected', content_hash = ?2 WHERE id = ?1").bind(batchId, guard.contentHash).run();
    await recordAudit(context.env, context.get("identity"), "content_batch.promote", "content_batch", batchId, "rejected", { findings: guard.findings });
    return context.json({ ok: false, batchId, status: "rejected", guardVersion: "recipe-content-v1", findings: guard.findings }, 422);
  }
  const promotionId = await deterministicId("content-promotion", batchId, guard.contentHash);
  await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT INTO content_promotions
         (id, batch_id, promoted_by, deterministic_guard_version, content_hash, detail_json)
       VALUES (?1, ?2, ?3, 'recipe-content-v1', ?4, ?5)`,
    ).bind(promotionId, batchId, context.get("identity").agentId, guard.contentHash, stableJson({ findings: guard.findings })),
    context.env.DB.prepare("UPDATE content_batches SET status = 'promoted', promoted_at = CURRENT_TIMESTAMP, content_hash = ?2 WHERE id = ?1")
      .bind(batchId, guard.contentHash),
  ]);
  await recordAudit(context.env, context.get("identity"), "content_batch.promote", "content_batch", batchId, "accepted", { promotionId, contentHash: guard.contentHash });
  return context.json({ ok: true, batchId, status: "promoted", promotionId, guardVersion: "recipe-content-v1", contentHash: guard.contentHash, warnings: guard.findings }, 201);
});

app.post("/internal/source-sentinels", zValidator("json", sourceSentinelResultSchema), async (context) => {
  const body = context.req.valid("json");
  const source = await context.env.DB.prepare("SELECT id FROM capture_sources WHERE id = ?1 AND active = 1").bind(body.sourceId).first();
  if (!source) return jsonError("unknown or inactive source", 404);
  const id = await deterministicId("source-sentinel", body.sourceId, String(body.contractVersion), body.observedAt);
  await context.env.DB.prepare(
    `INSERT INTO source_sentinel_results
       (id, source_id, contract_version, status, checks_json, evidence_json, observed_at, actor_id)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
     ON CONFLICT(id) DO NOTHING`,
  ).bind(id, body.sourceId, body.contractVersion, body.status, stableJson(body.checks), stableJson(body.evidence), body.observedAt, context.get("identity").agentId).run();
  if (body.status === "fail") await raiseOperationalAlert(context.env, `source-contract:${body.sourceId}`, `Source contract failed for ${body.sourceId}`, { checks: body.checks, evidence: body.evidence, observedAt: body.observedAt });
  else await resolveOperationalAlert(context.env, `source-contract:${body.sourceId}`, { checks: body.checks, observedAt: body.observedAt });
  return context.json({ ok: body.status === "pass", resultId: id, status: body.status }, body.status === "pass" ? 201 : 422);
});

app.post("/internal/archival/forecasts", zValidator("json", archivalForecastSchema), async (context) => {
  const body = context.req.valid("json");
  const usagePercentMillis = Math.floor(body.databaseBytes * 100_000 / body.databaseLimitBytes);
  const status = usagePercentMillis >= 90_000 ? "critical" : usagePercentMillis >= body.thresholdPercent * 1000 ? "armed" : "healthy";
  const projectedLimitAt = body.monthlyGrowthBytes > 0
    ? new Date(Date.parse(body.observedAt) + Math.max(0, body.databaseLimitBytes - body.databaseBytes) / body.monthlyGrowthBytes * 30 * 24 * 60 * 60 * 1000).toISOString()
    : null;
  const id = await deterministicId("archival-forecast", body.observedAt);
  await context.env.DB.prepare(
    `INSERT INTO archival_forecasts
       (id, database_bytes, database_limit_bytes, observation_count, monthly_growth_bytes,
        oldest_observation_at, protected_observation_count, threshold_percent, usage_percent_millis,
        projected_limit_at, status, observed_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`,
  ).bind(id, body.databaseBytes, body.databaseLimitBytes, body.observationCount, body.monthlyGrowthBytes,
    body.oldestObservationAt, body.protectedObservationCount, body.thresholdPercent, usagePercentMillis,
    projectedLimitAt, status, body.observedAt).run();
  if (status !== "healthy") await raiseOperationalAlert(context.env, "d1-archive-capacity", `D1 archival threshold is ${status}`, { id, ...body, usagePercentMillis, projectedLimitAt });
  else await resolveOperationalAlert(context.env, "d1-archive-capacity", { id, usagePercentMillis, projectedLimitAt });
  return context.json({ ok: status !== "critical", id, status, usagePercentMillis, projectedLimitAt }, status === "critical" ? 422 : 201);
});

app.post("/internal/archival/forecast/run", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may run the archival forecast", 403);
  const observedAt = Date.now();
  await runArchivalForecast(context.env, observedAt);
  await recordAudit(context.env, context.get("identity"), "archival_forecast.run", "job", "archival-forecast-daily", "accepted", {
    observedAt: new Date(observedAt).toISOString(),
  });
  return context.json({ ok: true, job: "archival-forecast-daily", observedAt: new Date(observedAt).toISOString() });
});

app.post("/internal/archival/plan", zValidator("json", archivePlanSchema), async (context) => {
  const body = context.req.valid("json");
  const minimumCutoff = Date.now() - 18 * 30 * 24 * 60 * 60 * 1000;
  if (Date.parse(body.cutoffAt) > minimumCutoff) return jsonError("archive cutoff must retain at least 18 months", 422);
  const forecast = await context.env.DB.prepare("SELECT status, usage_percent_millis FROM archival_forecasts ORDER BY observed_at DESC LIMIT 1")
    .first<{ status: string; usage_percent_millis: number }>();
  const rows = await context.env.DB.prepare(
    `SELECT o.id
       FROM observations o
      WHERE o.captured_at < ?1
        AND NOT EXISTS (SELECT 1 FROM release_cells rc WHERE rc.observation_id = o.id)
        AND NOT EXISTS (SELECT 1 FROM archive_manifest_observations amo WHERE amo.observation_id = o.id)
      ORDER BY o.captured_at, o.id
      LIMIT ?2`,
  ).bind(body.cutoffAt, body.maximumRows).all<{ id: string }>();
  const ids = rows.results.map((row) => row.id);
  const protectedCount = (await context.env.DB.prepare(
    `SELECT COUNT(DISTINCT o.id) AS count FROM observations o JOIN release_cells rc ON rc.observation_id = o.id WHERE o.captured_at < ?1`,
  ).bind(body.cutoffAt).first<{ count: number }>())?.count ?? 0;
  const protectedRefsHash = await digestHex(stableJson({ cutoffAt: body.cutoffAt, protectedCount }));
  const result = { cutoffAt: body.cutoffAt, candidates: ids.length, protectedCount, protectedRefsHash, forecast: forecast ?? null };
  if (body.dryRun) return context.json({ ok: true, dryRun: true, ...result });
  if (!forecast || !["armed", "critical"].includes(forecast.status)) return jsonError("archive execution is disarmed while D1 capacity is healthy", 409);
  if (!ids.length) return jsonError("archive plan has no eligible observations", 422);
  const manifestId = await deterministicId("archive-manifest", body.cutoffAt, protectedRefsHash, ...ids);
  const statements: D1PreparedStatement[] = [context.env.DB.prepare(
    `INSERT INTO archive_manifests (id, cutoff_at, format, row_count, status, protected_refs_hash, detail_json)
     VALUES (?1, ?2, 'parquet', ?3, 'planned', ?4, ?5)`,
  ).bind(manifestId, body.cutoffAt, ids.length, protectedRefsHash, stableJson({ forecast }))];
  for (const observationId of ids) statements.push(context.env.DB.prepare(
    "INSERT INTO archive_manifest_observations (manifest_id, observation_id) VALUES (?1, ?2)",
  ).bind(manifestId, observationId));
  for (let offset = 0; offset < statements.length; offset += 80) await context.env.DB.batch(statements.slice(offset, offset + 80));
  return context.json({ ok: true, dryRun: false, manifestId, ...result }, 201);
});

app.get("/internal/archival/:id/export", async (context) => {
  const manifest = await context.env.DB.prepare("SELECT id, status, cutoff_at, protected_refs_hash FROM archive_manifests WHERE id = ?1")
    .bind(context.req.param("id")).first<{ id: string; status: string; cutoff_at: string; protected_refs_hash: string }>();
  if (!manifest) return jsonError("archive manifest not found", 404);
  const rows = await context.env.DB.prepare(
    `SELECT o.*, pv.product_id, pv.name, pv.normalized_name, pv.size_text, pv.product_url,
            pv.image_url, pv.taxonomy_path, p.store_location_id, p.external_key, b.source_id
       FROM archive_manifest_observations amo
       JOIN observations o ON o.id = amo.observation_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       JOIN capture_batches b ON b.id = o.batch_id
      WHERE amo.manifest_id = ?1 ORDER BY o.captured_at, o.id`,
  ).bind(manifest.id).all<Record<string, unknown>>();
  return context.json({ ok: true, manifest, rows: rows.results });
});

app.put("/internal/archival/:id/parquet", async (context) => {
  const manifest = await context.env.DB.prepare("SELECT id, status, row_count FROM archive_manifests WHERE id = ?1")
    .bind(context.req.param("id")).first<{ id: string; status: string; row_count: number }>();
  if (!manifest) return jsonError("archive manifest not found", 404);
  if (manifest.status !== "planned") return jsonError(`archive manifest cannot accept bytes in ${manifest.status}`, 409);
  const body = await context.req.arrayBuffer();
  const bytes = new Uint8Array(body);
  const parquetMagic = bytes.length >= 8
    && new TextDecoder().decode(bytes.slice(0, 4)) === "PAR1"
    && new TextDecoder().decode(bytes.slice(-4)) === "PAR1";
  if (!parquetMagic) return jsonError("archive object is not a complete Parquet file", 422);
  const sha256 = await digestHex(bytes);
  const objectKey = `observations/${new Date().toISOString().slice(0, 10).replaceAll("-", "/")}/${manifest.id}.parquet`;
  await context.env.ARCHIVE.put(objectKey, body, { httpMetadata: { contentType: "application/vnd.apache.parquet" }, customMetadata: { manifestId: manifest.id, sha256, rows: String(manifest.row_count) } });
  const stored = await context.env.ARCHIVE.head(objectKey);
  if (!stored || stored.size !== bytes.byteLength) return jsonError("archive object failed post-write size verification", 500);
  await context.env.DB.prepare(
    "UPDATE archive_manifests SET object_key = ?2, byte_length = ?3, sha256 = ?4, status = 'verified', verified_at = CURRENT_TIMESTAMP WHERE id = ?1",
  ).bind(manifest.id, objectKey, stored.size, sha256).run();
  await recordAudit(context.env, context.get("identity"), "archive.verify", "archive_manifest", manifest.id, "accepted", { objectKey, byteLength: stored.size, sha256, rowCount: manifest.row_count });
  return context.json({ ok: true, manifestId: manifest.id, status: "verified", objectKey, byteLength: stored.size, sha256 });
});

app.post("/internal/capture-batches", zValidator("json", captureBatchCreateSchema), async (context) => {
  const body = context.req.valid("json");
  const identity = context.get("identity");
  if (identity.sourceIds && !identity.sourceIds.includes(body.sourceId)) return jsonError("agent is not authorized for this capture source", 403);
  const source = await context.env.DB.prepare("SELECT id, capture_method FROM capture_sources WHERE id = ?1 AND active = 1").bind(body.sourceId).first<{ id: string; capture_method: string }>();
  if (!source) return jsonError("unknown or inactive capture source", 404);
  if (identity.role === "engine" && !engineMayWriteCaptureSource(source.id, source.capture_method)) {
    return jsonError("engine identities may only create migration-bridge or approved direct-headless batches", 403);
  }
  const existing = await context.env.DB.prepare(
    "SELECT id, status FROM capture_batches WHERE agent_id = ?1 AND idempotency_key = ?2",
  ).bind(identity.agentId, body.idempotencyKey).first<{ id: string; status: string }>();
  if (existing) return context.json({ ok: true, batchId: existing.id, status: existing.status, idempotent: true });
  const batchId = `batch_${crypto.randomUUID()}`;
  await context.env.DB.prepare(
    `INSERT INTO capture_batches
       (id, source_id, coverage_mode, captured_from, captured_to, valid_from, valid_to, expected_terms,
        expected_pages, market_verified, location_verified, price_mode_verified, agent_id, idempotency_key)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)`,
  ).bind(
    batchId,
    body.sourceId,
    body.coverageMode,
    body.capturedFrom,
    body.capturedTo,
    body.validFrom ?? null,
    body.validTo ?? null,
    body.expectedTerms ?? null,
    body.expectedPages ?? null,
    body.marketVerified ? 1 : 0,
    body.locationVerified ? 1 : 0,
    body.priceModeVerified ? 1 : 0,
    identity.agentId,
    body.idempotencyKey,
  ).run();
  return context.json({ ok: true, batchId, status: "open", idempotent: false }, 201);
});

app.post("/internal/capture-batches/:id/abandon", zValidator("json", captureBatchAbandonSchema), async (context) => {
  const identity = context.get("identity");
  if (identity.role !== "operator") return jsonError("only an operator may abandon a capture batch", 403);
  const batchId = context.req.param("id");
  const batch = await context.env.DB.prepare(
    "SELECT status, validation_summary_json FROM capture_batches WHERE id = ?1",
  ).bind(batchId).first<{ status: string; validation_summary_json: string | null }>();
  if (!batch) return jsonError("capture batch not found", 404);
  const reason = context.req.valid("json").reason;
  if (batch.status === "rejected" && batch.validation_summary_json) {
    try {
      const summary = JSON.parse(batch.validation_summary_json) as { abandoned?: boolean; reason?: string };
      if (summary.abandoned === true && summary.reason === reason) {
        return context.json({ ok: true, batchId, status: "rejected", idempotent: true });
      }
    } catch {
      // A malformed historical summary is not proof that this operator action already occurred.
    }
  }
  if (batch.status !== "open") return jsonError(`only an open batch may be abandoned (current status: ${batch.status})`, 409);
  const abandonedAt = new Date().toISOString();
  const summary = { abandoned: true, reason, abandonedBy: identity.agentId, abandonedAt };
  const update = await context.env.DB.prepare(
    `UPDATE capture_batches
        SET status = 'rejected', validation_summary_json = ?2, sealed_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND status = 'open'`,
  ).bind(batchId, stableJson(summary)).run();
  if ((update.meta.changes ?? 0) !== 1) return jsonError("capture batch changed while it was being abandoned", 409);
  await recordAudit(context.env, identity, "capture.abandon", "capture_batch", batchId, "accepted", summary);
  return context.json({ ok: true, batchId, status: "rejected", idempotent: false });
});

app.post("/internal/capture-batches/:id/observations", zValidator("json", observationChunkSchema), async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  const engineOwnedCapture = identity.role === "engine" && engineMayWriteCaptureSource(batch.source_id, batch.capture_method);
  if (identity.role !== "capture" && identity.role !== "operator" && !engineOwnedCapture) return jsonError("mutation role is not authorized for capture content", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
  if (identity.sourceIds && !identity.sourceIds.includes(batch.source_id)) return jsonError("agent is not authorized for this capture source", 403);
  try {
    const result = await insertObservations(context.env.DB, batch, context.req.valid("json").observations);
    return context.json({ ok: true, ...result });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "observation insert failed", 422);
  }
});

app.put("/internal/capture-batches/:id/evidence", async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  const engineOwnedCapture = identity.role === "engine" && engineMayWriteCaptureSource(batch.source_id, batch.capture_method);
  if (identity.role !== "capture" && identity.role !== "operator" && !engineOwnedCapture) return jsonError("mutation role is not authorized for capture evidence", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
  if (identity.sourceIds && !identity.sourceIds.includes(batch.source_id)) return jsonError("agent is not authorized for this capture source", 403);
  if (batch.status !== "open") return jsonError("evidence can only be added to an open batch", 409);
  const metadataResult = evidenceMetadataSchema.safeParse({
    id: context.req.header("x-evidence-id"),
    kind: context.req.header("x-evidence-kind"),
    sha256: context.req.header("x-content-sha256"),
    expiresAt: context.req.header("x-expires-at") || undefined,
  });
  if (!metadataResult.success) return jsonError(metadataResult.error.message, 422);
  const bytes = new Uint8Array(await context.req.arrayBuffer());
  if (bytes.byteLength > 20 * 1024 * 1024) return jsonError("evidence object exceeds 20 MiB", 422);
  const actualHash = await digestHex(bytes);
  if (actualHash !== metadataResult.data.sha256) return jsonError("evidence hash does not match content", 422);
  const contentType = context.req.header("content-type") || "application/octet-stream";
  if (metadataResult.data.kind === "screenshot") {
    try { validateScreenshotEvidence(bytes, contentType); }
    catch (error) { return jsonError(error instanceof Error ? error.message : "invalid screenshot evidence", 422); }
  }
  const objectKey = `batches/${batch.id}/${metadataResult.data.id}`;
  const existingEvidence = await context.env.DB.prepare(
    "SELECT object_key, sha256 FROM evidence_objects WHERE id = ?1 AND batch_id = ?2",
  ).bind(metadataResult.data.id, batch.id).first<{ object_key: string; sha256: string }>();
  if (existingEvidence) {
    if (existingEvidence.sha256 !== actualHash) return jsonError("evidence id already exists with different content", 409);
    return context.json({ ok: true, evidenceId: metadataResult.data.id, objectKey: existingEvidence.object_key, idempotent: true });
  }
  await context.env.EVIDENCE.put(objectKey, bytes, { httpMetadata: { contentType }, customMetadata: { sha256: actualHash, kind: metadataResult.data.kind } });
  await context.env.DB.prepare(
    `INSERT INTO evidence_objects (id, batch_id, object_key, kind, content_type, byte_length, sha256, expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  ).bind(metadataResult.data.id, batch.id, objectKey, metadataResult.data.kind, contentType, bytes.byteLength, actualHash, metadataResult.data.expiresAt ?? null).run();
  return context.json({ ok: true, evidenceId: metadataResult.data.id, objectKey }, 201);
});

app.post("/internal/capture-batches/:id/seal", zValidator("json", captureBatchSealSchema), async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  const engineOwnedCapture = identity.role === "engine" && engineMayWriteCaptureSource(batch.source_id, batch.capture_method);
  if (identity.role !== "capture" && identity.role !== "operator" && !engineOwnedCapture) return jsonError("mutation role is not authorized to seal captures", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
  if (identity.sourceIds && !identity.sourceIds.includes(batch.source_id)) return jsonError("agent is not authorized for this capture source", 403);
  if (batch.status !== "open") return jsonError("batch is already sealed", 409);
  const body = context.req.valid("json");
  const attempted = body.terms.filter((term) => term.outcome !== "not_attempted").length;
  const successful = body.terms.filter((term) => term.outcome === "success").length;
  const empty = body.terms.filter((term) => term.outcome === "empty").length;
  const rejected = body.terms.filter((term) => term.outcome === "rejected").length;
  const blocked = body.terms.filter((term) => term.outcome === "blocked").length;
  const flyerPages = await context.env.DB.prepare(
    "SELECT COUNT(*) AS count FROM evidence_objects WHERE batch_id = ?1 AND kind = 'flyer_page'",
  ).bind(batch.id).first<{ count: number }>();
  const capturedPages = flyerPages?.count ?? 0;
  const observationCount = (await context.env.DB.prepare(
    "SELECT COUNT(*) AS count FROM observations WHERE batch_id = ?1",
  ).bind(batch.id).first<{ count: number }>())?.count ?? 0;
  const predecessor = await context.env.DB.prepare(
    `SELECT prior.id, COUNT(o.id) AS observation_count
       FROM capture_batches prior
       LEFT JOIN observations o ON o.batch_id = prior.id
      WHERE prior.source_id = ?1 AND prior.coverage_mode = ?2 AND prior.status IN ('validated','promoted') AND prior.id <> ?3
      GROUP BY prior.id, prior.captured_to
      ORDER BY prior.captured_to DESC LIMIT 1`,
  ).bind(batch.source_id, batch.coverage_mode, batch.id).first<{ id: string; observation_count: number }>();
  const collapseFloor = predecessor ? Math.ceil(predecessor.observation_count * 0.6) : 0;
  const collapsePass = !predecessor || observationCount >= collapseFloor;
  const identityPass = batch.market_verified === 1 && batch.location_verified === 1 && batch.price_mode_verified === 1;
  const capturedToMillis = Date.parse(batch.captured_to);
  const captureAgeMillis = Date.now() - capturedToMillis;
  const freshnessPass = Number.isFinite(capturedToMillis)
    && captureAgeMillis >= -5 * 60 * 1000
    && captureAgeMillis <= batch.max_age_days * 24 * 60 * 60 * 1000;
  const termEnvelopePass = batch.coverage_mode !== "full" || batch.expected_terms === null || attempted === batch.expected_terms;
  const pageEnvelopePass = batch.expected_pages === null || capturedPages === batch.expected_pages;
  const completePass = termEnvelopePass && pageEnvelopePass;
  const evidenceRows = await context.env.DB.prepare(
    "SELECT object_key, kind, sha256 FROM evidence_objects WHERE batch_id = ?1 ORDER BY id",
  ).bind(batch.id).all<{ object_key: string; kind: string; sha256: string }>();
  const browserEvidence = batch.capture_method === "browser"
    ? await validateBrowserCaptureEvidence(context.env.EVIDENCE, {
      sourceId: batch.source_id,
      coverageMode: batch.coverage_mode,
      capturedFrom: batch.captured_from,
      capturedTo: batch.captured_to,
      expectedTerms: batch.expected_terms,
    }, evidenceRows.results)
    : { pass: true, detail: { required: false } };
  const status = identityPass && completePass && collapsePass && freshnessPass && browserEvidence.pass ? "validated" : "rejected";
  const statements: D1PreparedStatement[] = body.terms.map((term) => context.env.DB.prepare(
    `INSERT INTO capture_terms (batch_id, term_key, ordinal, outcome, row_count, reason)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  ).bind(batch.id, term.termKey, term.ordinal, term.outcome, term.rowCount, term.reason ?? null));
  statements.push(context.env.DB.prepare(
    `UPDATE capture_batches SET status = ?2, attempted_terms = ?3, successful_terms = ?4, empty_terms = ?5,
       rejected_terms = ?6, blocked_terms = ?7, captured_pages = ?8, evidence_manifest_key = ?9,
       validation_summary_json = ?10, sealed_at = CURRENT_TIMESTAMP WHERE id = ?1`,
  ).bind(batch.id, status, attempted, successful, empty, rejected, blocked, capturedPages, body.evidenceManifestKey ?? null, stableJson({ identityPass, termEnvelopePass, pageEnvelopePass, collapsePass, freshnessPass, browserEvidencePass: browserEvidence.pass, browserEvidence: browserEvidence.detail, captureAgeMillis, maxAgeDays: batch.max_age_days, observationCount, predecessorBatchId: predecessor?.id ?? null, predecessorObservationCount: predecessor?.observation_count ?? null, collapseFloor })));
  for (const [guardId, pass, eligible, examined, detail] of [
    ["batch-location", identityPass, 3, 3, {}],
    ["batch-completeness", completePass, (batch.expected_terms ?? 0) + (batch.expected_pages ?? 0), attempted + capturedPages, {}],
    ["batch-collapse", collapsePass, predecessor ? 2 : 0, predecessor ? 2 : 0, { observationCount, predecessorBatchId: predecessor?.id ?? null, predecessorObservationCount: predecessor?.observation_count ?? null, collapseFloor }],
    ["batch-freshness", freshnessPass, 1, 1, { capturedTo: batch.captured_to, captureAgeMillis, maxAgeDays: batch.max_age_days }],
    ["batch-browser-evidence", browserEvidence.pass, batch.capture_method === "browser" ? 3 : 0, batch.capture_method === "browser" ? 3 : 0, browserEvidence.detail],
  ] as const) {
    const resultId = await deterministicId("guard", batch.id, guardId);
    statements.push(context.env.DB.prepare(
      `INSERT INTO guard_results (id, guard_id, batch_id, status, eligible_count, examined_count, finding_count, detail_json)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
    ).bind(resultId, guardId, batch.id, pass ? "pass" : "fail", eligible, Math.min(eligible, examined), pass ? 0 : 1, stableJson(detail)));
  }
  await context.env.DB.batch(statements);
  return context.json({ ok: status === "validated", batchId: batch.id, status, counts: { attempted, successful, empty, rejected, blocked, capturedPages } }, status === "validated" ? 200 : 422);
});

app.get("/internal/capture-batches/promoted", async (context) => {
  const identity = context.get("identity");
  if (identity.role !== "engine" && identity.role !== "operator") return jsonError("mutation role is not authorized to list promoted batches", 403);
  const batches = await context.env.DB.prepare(
    `SELECT id, source_id, coverage_mode, captured_to
       FROM capture_batches WHERE status = 'promoted'
      ORDER BY source_id, captured_to DESC, id`,
  ).all();
  return context.json({ ok: true, batches: batches.results });
});

app.get("/internal/capture-batches/ready-browser", async (context) => {
  const identity = context.get("identity");
  if (identity.role !== "engine" && identity.role !== "operator") return jsonError("mutation role is not authorized to select promotion candidates", 403);
  const rows = await context.env.DB.prepare(
    `SELECT batch.id, batch.source_id, batch.captured_to, batch.coverage_mode,
            COUNT(observation.id) AS observation_count
       FROM capture_batches batch
       JOIN capture_sources source ON source.id = batch.source_id
       LEFT JOIN observations observation ON observation.batch_id = batch.id
      WHERE batch.status = 'validated' AND source.capture_method = 'browser'
      GROUP BY batch.id, batch.source_id, batch.captured_to, batch.coverage_mode
      ORDER BY batch.captured_to, batch.id`,
  ).all<Record<string, unknown>>();
  return context.json({ ok: true, batches: rows.results });
});

app.post("/internal/capture-batches/:id/promote", async (context) => {
  const identity = context.get("identity");
  if (identity.role !== "engine" && identity.role !== "operator") return jsonError("mutation role is not authorized to promote captures", 403);
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  if (batch.status === "promoted") return context.json({ ok: true, batchId: batch.id, status: batch.status, idempotent: true });
  if (batch.status !== "validated") return jsonError(`capture batch cannot be promoted from ${batch.status}`, 409);
  const previous = await context.env.DB.prepare(
    "SELECT id FROM capture_batches WHERE source_id = ?1 AND status = 'promoted' AND id <> ?2",
  ).bind(batch.source_id, batch.id).all<{ id: string }>();
  const statements = previous.results.map((row) => context.env.DB.prepare(
    "UPDATE capture_batches SET status = 'superseded', superseded_by = ?2 WHERE id = ?1 AND status = 'promoted'",
  ).bind(row.id, batch.id));
  statements.push(context.env.DB.prepare(
    "UPDATE capture_batches SET status = 'promoted', promoted_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'validated'",
  ).bind(batch.id));
  await context.env.DB.batch(statements);
  return context.json({ ok: true, batchId: batch.id, status: "promoted", superseded: previous.results.map((row) => row.id), idempotent: false });
});

app.post("/internal/releases", zValidator("json", releaseCreateSchema), async (context) => {
  const requested = context.req.valid("json");
  const expectedInputHash = await digestHex(stableJson({ inputManifest: requested.inputManifest, inputBatchIds: requested.inputBatchIds }));
  if (expectedInputHash !== requested.inputHash) return jsonError("release input hash does not bind the manifest and promoted batch snapshot", 422);
  const configuration = await context.env.DB.prepare(
    "SELECT active FROM configuration_versions WHERE id = ?1",
  ).bind(requested.configurationId).first<{ active: number }>();
  if (!configuration || configuration.active !== 1) return jsonError("release configuration is not active", 422);
  const batches = await Promise.all(requested.inputBatchIds.map((batchId) => context.env.DB.prepare(
    `SELECT b.id, b.status, l.market_id
       FROM capture_batches b
       JOIN capture_sources s ON s.id = b.source_id
       JOIN store_locations l ON l.id = s.store_location_id
      WHERE b.id = ?1`,
  ).bind(batchId).first<{ id: string; status: string; market_id: string }>()));
  const invalidBatches = requested.inputBatchIds.filter((batchId, index) => !batches[index] || batches[index]!.status !== "promoted" || batches[index]!.market_id !== requested.marketId);
  if (invalidBatches.length > 0) return jsonError(`release snapshot includes missing, unpromoted, or wrong-market batches: ${invalidBatches.join(", ")}`, 422);
  const existing = await context.env.DB.prepare(
    "SELECT id, input_hash, state FROM releases WHERE id = ?1 OR (market_id = ?2 AND input_hash = ?3) LIMIT 1",
  ).bind(requested.id, requested.marketId, requested.inputHash).first<{ id: string; input_hash: string; state: string }>();
  if (existing) {
    if (existing.id !== requested.id || existing.input_hash !== requested.inputHash) {
      return jsonError("release identity conflicts with an existing release", 409);
    }
    return context.json({ ok: true, releaseId: existing.id, state: existing.state, idempotent: true });
  }
  try {
    await createRelease(context.env.DB, requested);
    return context.json({ ok: true, releaseId: requested.id, state: "draft", idempotent: false }, 201);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "release creation failed", 409);
  }
});

app.put("/internal/releases/:id/cells", zValidator("json", releaseCellsChunkSchema), async (context) => {
  const stateError = await requireDraftRelease(context.env.DB, context.req.param("id"));
  if (stateError) return stateError;
  await insertReleaseCells(context.env.DB, context.req.param("id"), context.req.valid("json").cells);
  return context.json({ ok: true, accepted: context.req.valid("json").cells.length });
});

app.put("/internal/releases/:id/recipe-costs", zValidator("json", recipeCostsChunkSchema), async (context) => {
  const stateError = await requireDraftRelease(context.env.DB, context.req.param("id"));
  if (stateError) return stateError;
  await insertRecipeCosts(context.env.DB, context.req.param("id"), context.req.valid("json").costs);
  return context.json({ ok: true, accepted: context.req.valid("json").costs.length });
});

app.put("/internal/releases/:id/free-rotation", zValidator("json", releaseFreeRotationChunkSchema), async (context) => {
  const releaseId = context.req.param("id");
  const stateError = await requireDraftRelease(context.env.DB, releaseId);
  if (stateError) return stateError;
  const statements = context.req.valid("json").entries.map((entry) => context.env.DB.prepare(
    `INSERT INTO release_free_rotation (release_id, recipe_slug, intended_visibility, protein, rank)
     VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT(release_id, recipe_slug) DO UPDATE SET
       intended_visibility = excluded.intended_visibility, protein = excluded.protein, rank = excluded.rank`,
  ).bind(releaseId, entry.recipeSlug, entry.intendedVisibility, entry.protein ?? null, entry.rank ?? null));
  for (let offset = 0; offset < statements.length; offset += 90) await context.env.DB.batch(statements.slice(offset, offset + 90));
  return context.json({ ok: true, accepted: statements.length });
});

app.put("/internal/releases/:id/top5", zValidator("json", releaseTop5ChunkSchema), async (context) => {
  const releaseId = context.req.param("id");
  const stateError = await requireDraftRelease(context.env.DB, releaseId);
  if (stateError) return stateError;
  const statements = context.req.valid("json").entries.map((entry) => context.env.DB.prepare(
    `INSERT INTO release_top5 (release_id, protein, rank, recipe_slug, serving_cost_minor)
     VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT(release_id, protein, rank) DO UPDATE SET
       recipe_slug = excluded.recipe_slug, serving_cost_minor = excluded.serving_cost_minor`,
  ).bind(releaseId, entry.protein, entry.rank, entry.recipeSlug, entry.servingCostMinor));
  for (let offset = 0; offset < statements.length; offset += 90) await context.env.DB.batch(statements.slice(offset, offset + 90));
  return context.json({ ok: true, accepted: statements.length });
});

app.put("/internal/releases/:id/payload", zValidator("json", releasePayloadSchema), async (context) => {
  const stateError = await requireDraftRelease(context.env.DB, context.req.param("id"));
  if (stateError) return stateError;
  const body = context.req.valid("json");
  const serialized = stableJson(body.payload);
  if (await digestHex(serialized) !== body.contentHash) return jsonError("payload content hash mismatch", 422);
  const releaseId = context.req.param("id");
  const bytes = new TextEncoder().encode(serialized);
  const useObjectStorage = bytes.byteLength > 512 * 1024;
  const objectKey = useObjectStorage ? `releases/${releaseId}/${body.kind}-${body.contentHash}.json` : null;
  if (objectKey) {
    await context.env.EVIDENCE.put(objectKey, bytes, {
      httpMetadata: { contentType: "application/json; charset=utf-8" },
      customMetadata: { sha256: body.contentHash, kind: body.kind, releaseId },
    });
  }
  await context.env.DB.prepare(
    `INSERT INTO release_payloads (release_id, kind, payload_json, content_hash, object_key, byte_length)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT(release_id, kind) DO UPDATE SET
       payload_json = excluded.payload_json,
       content_hash = excluded.content_hash,
       object_key = excluded.object_key,
       byte_length = excluded.byte_length`,
  ).bind(releaseId, body.kind, useObjectStorage ? '{}' : serialized, body.contentHash, objectKey, bytes.byteLength).run();
  return context.json({ ok: true, storage: useObjectStorage ? "object" : "inline", byteLength: bytes.byteLength });
});

app.put("/internal/releases/:id/guards", zValidator("json", releaseGuardResultSchema), async (context) => {
  const stateError = await requireDraftRelease(context.env.DB, context.req.param("id"));
  if (stateError) return stateError;
  const submitted = context.req.valid("json");
  const definition = await context.env.DB.prepare(
    "SELECT severity FROM guard_definitions WHERE id = ?1 AND active = 1",
  ).bind(submitted.guardId).first<{ severity: string }>();
  if (!definition) return jsonError("unknown or inactive guard", 404);
  if (definition.severity === "hard") return jsonError("hard guards are evaluated by the release service", 403);
  await upsertGuardResult(context.env.DB, context.req.param("id"), submitted);
  return context.json({ ok: true });
});

app.post("/internal/releases/:id/validate", async (context) => {
  const releaseId = context.req.param("id");
  const release = await context.env.DB.prepare("SELECT state, summary_json FROM releases WHERE id = ?1").bind(releaseId).first<{ state: string; summary_json: string }>();
  if (!release) return jsonError("release not found", 404);
  if (release.state !== "draft" && release.state !== "validating") return jsonError(`release cannot be validated from ${release.state}`, 409);
  const summary = JSON.parse(release.summary_json) as { expectedCommodities: number; expectedStores: number; expectedRecipes: number; expectedFreeRotation?: number };
  const expectedFreeRotation = summary.expectedFreeRotation ?? 0;
  const releaseIdentity = await context.env.DB.prepare(
    "SELECT configuration_id, market_id FROM releases WHERE id = ?1",
  ).bind(releaseId).first<{ configuration_id: string; market_id: string }>();
  if (!releaseIdentity) return jsonError("release not found", 404);
  const [cellStats, recipeStats, payloadStats, invalidCellStats, rotationStats, top5Stats, invalidRankedRecipes] = await Promise.all([
    context.env.DB.prepare("SELECT COUNT(*) AS rows, COUNT(DISTINCT commodity_id) AS commodities, COUNT(DISTINCT store_location_id) AS stores FROM release_cells WHERE release_id = ?1").bind(releaseId).first<{ rows: number; commodities: number; stores: number }>(),
    context.env.DB.prepare("SELECT COUNT(*) AS rows, SUM(CASE WHEN status = 'incomplete' THEN 1 ELSE 0 END) AS incomplete FROM release_recipe_costs WHERE release_id = ?1").bind(releaseId).first<{ rows: number; incomplete: number | null }>(),
    context.env.DB.prepare("SELECT COUNT(*) AS rows FROM release_payloads WHERE release_id = ?1 AND kind IN ('board','feed','top5','free_rotation','recipes')").bind(releaseId).first<{ rows: number }>(),
    context.env.DB.prepare(
      `SELECT COUNT(*) AS invalid
         FROM release_cells c
        WHERE c.release_id = ?1 AND (
          NOT EXISTS (SELECT 1 FROM commodities x WHERE x.id = c.commodity_id AND x.configuration_id = ?2 AND x.active = 1)
          OR NOT EXISTS (SELECT 1 FROM store_locations l WHERE l.id = c.store_location_id AND l.market_id = ?3 AND l.active = 1)
        )`,
    ).bind(releaseId, releaseIdentity.configuration_id, releaseIdentity.market_id).first<{ invalid: number }>(),
    context.env.DB.prepare("SELECT COUNT(*) AS rows FROM release_free_rotation WHERE release_id = ?1 AND intended_visibility = 'public'").bind(releaseId).first<{ rows: number }>(),
    context.env.DB.prepare("SELECT COUNT(*) AS rows FROM release_top5 WHERE release_id = ?1").bind(releaseId).first<{ rows: number }>(),
    context.env.DB.prepare(
      `SELECT ranked.recipe_slug, ranked.surface
         FROM (
           SELECT recipe_slug, 'top5' AS surface FROM release_top5 WHERE release_id = ?1
           UNION ALL
           SELECT recipe_slug, 'free_rotation' AS surface FROM release_free_rotation WHERE release_id = ?1 AND intended_visibility = 'public'
         ) ranked
         LEFT JOIN release_recipe_costs costs ON costs.release_id = ?1 AND costs.recipe_slug = ranked.recipe_slug
        WHERE costs.recipe_slug IS NULL OR costs.status <> 'complete'
        ORDER BY ranked.surface, ranked.recipe_slug`,
    ).bind(releaseId).all<{ recipe_slug: string; surface: string }>(),
  ]);
  const expectedCellRows = summary.expectedCommodities * summary.expectedStores;
  const surfacePass = cellStats?.rows === expectedCellRows
    && cellStats.commodities === summary.expectedCommodities
    && cellStats.stores === summary.expectedStores
    && recipeStats?.rows === summary.expectedRecipes
    && payloadStats?.rows === 5
    && rotationStats?.rows === expectedFreeRotation
    && top5Stats?.rows === expectedFreeRotation
    && (invalidCellStats?.invalid ?? 0) === 0;
  const recipePass = invalidRankedRecipes.results.length === 0;
  await upsertGuardResult(context.env.DB, releaseId, {
    guardId: "release-surface-counts",
    status: surfacePass ? "pass" : "fail",
    eligibleCount: expectedCellRows + summary.expectedRecipes + expectedFreeRotation * 2 + 5,
    examinedCount: Math.min(expectedCellRows + summary.expectedRecipes + expectedFreeRotation * 2 + 5, (cellStats?.rows ?? 0) + (recipeStats?.rows ?? 0) + (rotationStats?.rows ?? 0) + (top5Stats?.rows ?? 0) + (payloadStats?.rows ?? 0)),
    findings: surfacePass ? [] : [{ key: "surface-count-mismatch", message: "Release surfaces do not match authored expectations", evidence: { cellStats, recipeStats, payloadStats, rotationStats, top5Stats, invalidCellStats, summary } }],
    detail: {},
  });
  await evaluateReleaseGuards(context.env.DB, {
    releaseId,
    configurationId: releaseIdentity.configuration_id,
    marketId: releaseIdentity.market_id,
    expectedCommodities: summary.expectedCommodities,
    expectedStores: summary.expectedStores,
    expectedRecipes: summary.expectedRecipes,
  });
  await upsertGuardResult(context.env.DB, releaseId, {
    guardId: "release-recipe-completeness",
    status: recipePass ? "pass" : "fail",
    eligibleCount: (top5Stats?.rows ?? 0) + (rotationStats?.rows ?? 0),
    examinedCount: (top5Stats?.rows ?? 0) + (rotationStats?.rows ?? 0),
    findings: invalidRankedRecipes.results.map((row) => ({ key: `${row.surface}:${row.recipe_slug}`, message: "Incomplete or missing recipe entered a price-ranked public surface", evidence: { recipeSlug: row.recipe_slug, surface: row.surface } })),
    detail: { incompleteRecipes: recipeStats?.incomplete ?? 0, policy: "incomplete recipes remain auditable and are excluded from ranked/public surfaces" },
  });
  await evaluateNotBlindGuard(context.env.DB, releaseId);
  const missingHard = await context.env.DB.prepare(
    `SELECT d.id
       FROM guard_definitions d
       LEFT JOIN guard_results r ON r.guard_id = d.id AND r.release_id = ?1
      WHERE d.active = 1 AND d.scope = 'release' AND d.severity = 'hard'
        AND (r.id IS NULL OR r.status <> 'pass')
      ORDER BY d.id`,
  ).bind(releaseId).all<{ id: string }>();
  const valid = missingHard.results.length === 0;
  await context.env.DB.prepare(
    "UPDATE releases SET state = ?2, validated_at = CASE WHEN ?2 = 'validated' THEN CURRENT_TIMESTAMP ELSE NULL END WHERE id = ?1",
  ).bind(releaseId, valid ? "validated" : "rejected").run();
  return context.json({ ok: valid, releaseId, state: valid ? "validated" : "rejected", blockingGuards: missingHard.results.map((item) => item.id) }, valid ? 200 : 422);
});

app.post("/internal/releases/:id/publish", async (context) => {
  const releaseId = context.req.param("id");
  const release = await context.env.DB.prepare("SELECT market_id, state, validated_at FROM releases WHERE id = ?1").bind(releaseId).first<{ market_id: string; state: string; validated_at: string | null }>();
  if (!release) return jsonError("release not found", 404);
  if (release.state !== "validated") return jsonError("only validated releases may publish", 409);
  if (!release.validated_at || Date.now() - Date.parse(release.validated_at.endsWith("Z") ? release.validated_at : `${release.validated_at}Z`) > 15 * 60_000) {
    return jsonError("release validation is older than the 15 minute publish window", 409);
  }
  const blocking = await context.env.DB.prepare(
    `SELECT d.id FROM guard_definitions d
       LEFT JOIN guard_results r ON r.guard_id = d.id AND r.release_id = ?1
      WHERE d.active = 1 AND d.scope = 'release' AND d.severity = 'hard'
        AND (r.id IS NULL OR r.status <> 'pass')`,
  ).bind(releaseId).all();
  if (blocking.results.length > 0) return jsonError("release has missing or failing hard guards", 422);
  const current = await context.env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = ?1").bind(release.market_id).first<{ release_id: string }>();
  const statements: D1PreparedStatement[] = [];
  if (current && current.release_id !== releaseId) statements.push(context.env.DB.prepare("UPDATE releases SET state = 'superseded' WHERE id = ?1 AND state = 'published'").bind(current.release_id));
  statements.push(context.env.DB.prepare("UPDATE releases SET state = 'published', published_at = CURRENT_TIMESTAMP WHERE id = ?1 AND state = 'validated'").bind(releaseId));
  statements.push(context.env.DB.prepare(
    `INSERT INTO current_releases (market_id, release_id, updated_at) VALUES (?1, ?2, CURRENT_TIMESTAMP)
     ON CONFLICT(market_id) DO UPDATE SET release_id = excluded.release_id, updated_at = CURRENT_TIMESTAMP`,
  ).bind(release.market_id, releaseId));
  await context.env.DB.batch(statements);
  return context.json({ ok: true, releaseId, state: "published", previousReleaseId: current?.release_id ?? null });
});

app.post("/internal/releases/:id/reject", async (context) => {
  const releaseId = context.req.param("id");
  const release = await context.env.DB.prepare("SELECT state FROM releases WHERE id = ?1").bind(releaseId).first<{ state: string }>();
  if (!release) return jsonError("release not found", 404);
  if (!["draft", "validating", "validated"].includes(release.state)) return jsonError(`release cannot be rejected from ${release.state}`, 409);
  await context.env.DB.prepare("UPDATE releases SET state = 'rejected', validated_at = NULL WHERE id = ?1").bind(releaseId).run();
  return context.json({ ok: true, releaseId, state: "rejected" });
});

app.post("/internal/releases/:id/reconcile-ghost", async (context) => {
  try {
    const result = await reconcileGhostRotation(context.env, context.req.param("id"));
    return context.json({ ok: result.status === "verified", ...result }, result.status === "verified" ? 200 : 422);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "Ghost reconciliation failed", 422);
  }
});

app.post("/internal/releases/:id/drill-ghost-clobber", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may run a Ghost clobber drill", 403);
  const releaseId = context.req.param("id");
  const observedAt = new Date().toISOString();
  let result: Awaited<ReturnType<typeof runGhostClobberDrill>>;
  try {
    result = await runGhostClobberDrill(context.env, releaseId);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "Ghost clobber drill failed", 422);
  }
  const eventId = await deterministicId("evidence", "ghost-clobber", releaseId, observedAt.slice(0, 10));
  await context.env.DB.prepare(
    `INSERT INTO evidence_gate_events (id, gate, period_key, source_ref, status, evidence_json, observed_at)
     VALUES (?1, 'chaos-drill', ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT(gate, period_key, source_ref) DO UPDATE SET
       status = excluded.status, evidence_json = excluded.evidence_json, observed_at = excluded.observed_at`,
  ).bind(eventId, `ghost-clobber-${observedAt.slice(0, 10)}`, releaseId, result.passed ? "pass" : "fail", stableJson(result), observedAt).run();
  await recordAudit(context.env, context.get("identity"), "ghost.clobber_drill", "release", releaseId, result.passed ? "accepted" : "failed", result);
  return context.json({ ok: result.passed, eventId, ...result }, result.passed ? 200 : 422);
});

app.post("/internal/drills/:kind", async (context) => {
  try {
    const result = await runServerChaosDrill(context.env, context.req.param("kind"));
    await recordAudit(context.env, context.get("identity"), "chaos_drill.run", "evidence_gate_event", String(result.eventId), result.ok === true ? "accepted" : "failed", result);
    return context.json(result, result.ok === true ? 200 : 422);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "chaos drill failed", 422);
  }
});

app.post("/internal/accuracy/draws", zValidator("json", accuracyDrawCreateSchema), async (context) => {
  try {
    const result = await createAccuracyDraw(context.env.DB, context.req.valid("json"));
    return context.json({ ok: true, ...result }, result.idempotent ? 200 : 201);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "accuracy draw failed", 422);
  }
});

app.get("/internal/accuracy/draw", async (context) => {
  const reveal = context.req.query("reveal") === "1";
  if (reveal && context.get("identity").role !== "operator") return jsonError("only an operator may reveal sampled board answers", 403);
  const draw = await readAccuracyDraw(context.env.DB, context.req.query("id"), reveal);
  if (!draw) return jsonError("accuracy draw not found", 404);
  return context.json({ ok: true, draw });
});

app.post("/internal/accuracy/verdicts", zValidator("json", accuracyVerdictsSchema), async (context) => {
  try {
    const identity = context.get("identity");
    if (identity.registeredAgentId && identity.registeredAgentId !== "accuracy-headless") return jsonError("only the registered accuracy agent may submit automated verdicts", 403);
    const result = await recordAccuracyVerdicts(context.env.DB, context.req.valid("json"), identity.agentId);
    return context.json({ ok: true, ...result });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "accuracy verdict failed", 422);
  }
});

app.get("/internal/triage", async (context) => {
  const requestedStatus = context.req.query("status") ?? "open";
  if (!["open", "planned", "resolved", "needs_operator", "all"].includes(requestedStatus)) return jsonError("invalid triage status", 422);
  const rows = requestedStatus === "all"
    ? await context.env.DB.prepare("SELECT * FROM triage_items ORDER BY created_at, id LIMIT 1000").all()
    : await context.env.DB.prepare("SELECT * FROM triage_items WHERE status = ?1 ORDER BY created_at, id LIMIT 1000").bind(requestedStatus).all();
  return context.json({ ok: true, items: rows.results });
});

app.get("/internal/triage/:id/review", async (context) => {
  const triageId = context.req.param("id");
  const item = await context.env.DB.prepare("SELECT * FROM triage_items WHERE id = ?1").bind(triageId).first<Record<string, unknown>>();
  if (!item) return jsonError("triage item not found", 404);
  let source: Record<string, unknown> | null = null;
  if (item.source_kind === "guard_finding") {
    source = await context.env.DB.prepare(
      `SELECT finding.*, result.release_id, result.guard_id, result.status AS guard_status,
              result.eligible_count, result.examined_count, result.detail_json AS guard_detail_json,
              release.state AS release_state, release.input_hash, release.configuration_id
         FROM guard_findings finding
         JOIN guard_results result ON result.id = finding.result_id
         JOIN releases release ON release.id = result.release_id
        WHERE finding.id = ?1`,
    ).bind(String(item.source_ref)).first<Record<string, unknown>>();
  } else if (item.source_kind === "accuracy_gap") {
    source = await context.env.DB.prepare(
      `SELECT draw.*, COUNT(verdict.id) AS verdict_count
         FROM accuracy_draws draw LEFT JOIN operator_verdicts verdict ON verdict.draw_id = draw.id
        WHERE draw.id = ?1 GROUP BY draw.id`,
    ).bind(String(item.source_ref)).first<Record<string, unknown>>();
  }
  const current = await context.env.DB.prepare(
    `SELECT release.id, release.published_at, release.configuration_id, release.input_hash
       FROM current_releases current JOIN releases release ON release.id = current.release_id
      WHERE current.market_id = 'omaha'`,
  ).first<Record<string, unknown>>();
  await recordAudit(context.env, context.get("identity"), "triage.review", "triage_item", triageId, "accepted", { sourceKind: item.source_kind });
  return context.json({ ok: true, readOnly: true, item, source, currentRelease: current });
});

app.post("/internal/operational-alerts", zValidator("json", operationalAlertSchema), async (context) => {
  const body = context.req.valid("json");
  const identity = context.get("identity");
  const alertKey = `${identity.agentId}:${body.key}`;
  const evidence = { ...body.evidence, observedAt: body.observedAt, agentId: identity.agentId };
  const result = body.status === "firing"
    ? await raiseOperationalAlert(context.env, alertKey, body.title, evidence)
    : await resolveOperationalAlert(context.env, alertKey, evidence);
  await recordAudit(context.env, identity, `operational_alert.${body.status}`, "triage_item", result.triageId, "accepted", evidence);
  return context.json({ ok: true, status: body.status, ...result }, body.status === "firing" ? 201 : 200);
});

app.post("/internal/triage/run", async (context) => {
  const overdueAccuracyDraws = await markOverdueAccuracyDraws(context.env.DB);
  const queue = await context.env.DB.prepare(
    `SELECT status, severity, COUNT(*) AS count FROM triage_items
      WHERE status <> 'resolved' GROUP BY status, severity ORDER BY status, severity`,
  ).all();
  await recordAudit(context.env, context.get("identity"), "triage.run", "triage_queue", null, "accepted", {
    overdueAccuracyDraws,
    queue: queue.results,
  });
  return context.json({ ok: true, overdueAccuracyDraws, queue: queue.results });
});

app.post("/internal/triage/reconcile", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may reconcile triage", 403);
  const recoverable = await context.env.DB.prepare(
    `SELECT t.id, failed.release_id AS failed_release_id, failed.guard_id,
            current.release_id AS recovery_release_id
       FROM triage_items t
       JOIN guard_findings finding ON finding.id = t.source_ref
       JOIN guard_results failed ON failed.id = finding.result_id
       JOIN releases rejected ON rejected.id = failed.release_id AND rejected.state = 'rejected'
       JOIN current_releases current ON current.market_id = rejected.market_id
      WHERE t.source_kind = 'guard_finding' AND t.status <> 'resolved'
        AND EXISTS (
          SELECT 1 FROM guard_results recovered
           WHERE recovered.release_id = current.release_id
             AND recovered.guard_id = failed.guard_id
             AND recovered.status = 'pass'
        )
      ORDER BY t.id`,
  ).all<{ id: string; failed_release_id: string; guard_id: string; recovery_release_id: string }>();
  const backupRecovery = await context.env.DB.prepare(
    `SELECT backup.id AS backup_id, replica.id AS replica_id
       FROM backup_exports backup
       JOIN backup_replicas replica ON replica.backup_id = backup.id AND replica.status = 'completed'
      WHERE backup.status = 'completed'
      ORDER BY backup.finished_at DESC LIMIT 1`,
  ).first<{ backup_id: string; replica_id: string }>();
  const failedBackupItems = await context.env.DB.prepare(
    `SELECT id FROM triage_items
      WHERE source_kind = 'operational_alert' AND title = 'Nightly D1 backup failed'
        AND status <> 'resolved' ORDER BY created_at, id`,
  ).all<{ id: string }>();
  const recoveredBackups = backupRecovery
    ? failedBackupItems.results.map((row) => ({ id: row.id, ...backupRecovery }))
    : [];
  const recoveredParity = await context.env.DB.prepare(
    `SELECT t.id, parity.id AS parity_id, parity.diff_count
       FROM triage_items t
       JOIN engine_parity_runs parity ON parity.id = (
         SELECT candidate.id FROM engine_parity_runs candidate
          WHERE candidate.mode = 'legacy' AND candidate.status = 'passed' AND candidate.diff_count = 0
            AND julianday(candidate.observed_at) > julianday(t.created_at)
          ORDER BY candidate.observed_at DESC LIMIT 1
       )
      WHERE t.source_kind = 'operational_alert' AND t.title LIKE 'Native legacy engine has % parity differences'
        AND t.status <> 'resolved'`,
  ).all<{ id: string; parity_id: string; diff_count: number }>();
  const recoveredJobRuns = await context.env.DB.prepare(
    `SELECT triage.id, failed.job, recovery.id AS recovery_run_id, recovery.finished_at
       FROM triage_items triage
       JOIN job_runs failed ON failed.id = substr(triage.source_ref, 9)
       JOIN job_runs recovery ON recovery.id = (
         SELECT candidate.id FROM job_runs candidate
          WHERE candidate.job = failed.job AND candidate.status = 'completed'
            AND julianday(candidate.finished_at) > julianday(COALESCE(failed.finished_at, failed.started_at, triage.created_at))
          ORDER BY candidate.finished_at DESC LIMIT 1
       )
      WHERE triage.source_kind = 'operational_alert'
        AND triage.source_ref LIKE 'job-run:%'
        AND triage.status <> 'resolved'
        AND failed.status IN ('failed', 'timed_out', 'missed')`,
  ).all<{ id: string; job: string; recovery_run_id: string; finished_at: string }>();
  const recoveredScheduleGaps = await context.env.DB.prepare(
    `SELECT triage.id, schedule.job, recovery.id AS recovery_run_id, recovery.finished_at
       FROM triage_items triage
       JOIN job_schedules schedule ON triage.source_ref = 'schedule-gap:' || schedule.job
       JOIN job_runs recovery ON recovery.id = (
         SELECT candidate.id FROM job_runs candidate
          WHERE candidate.job = schedule.job AND candidate.status = 'completed'
          ORDER BY candidate.finished_at DESC LIMIT 1
       )
      WHERE triage.source_kind = 'operational_alert'
        AND triage.status <> 'resolved'
        AND julianday('now') - julianday(recovery.finished_at) <= schedule.max_gap_minutes / 1440.0`,
  ).all<{ id: string; job: string; recovery_run_id: string; finished_at: string }>();
  const recoveredSourceContracts = await context.env.DB.prepare(
    `SELECT triage.id, sentinel.id AS sentinel_id, sentinel.source_id, sentinel.observed_at
       FROM triage_items triage
       JOIN source_sentinel_results sentinel ON sentinel.id = (
         SELECT candidate.id FROM source_sentinel_results candidate
          WHERE triage.source_ref = 'source-contract:' || candidate.source_id
            AND candidate.status = 'pass'
            AND julianday(candidate.observed_at) > julianday(triage.created_at)
          ORDER BY candidate.observed_at DESC LIMIT 1
       )
      WHERE triage.source_kind = 'operational_alert'
        AND triage.source_ref LIKE 'source-contract:%'
        AND triage.status <> 'resolved'`,
  ).all<{ id: string; sentinel_id: string; source_id: string; observed_at: string }>();
  const restoreFailures = await context.env.DB.prepare(
    `SELECT id, source_ref FROM triage_items
      WHERE source_kind = 'operational_alert'
        AND title = 'Quarterly D1 restore drill failed'
        AND status <> 'resolved'
      ORDER BY created_at DESC, id DESC`,
  ).all<{ id: string; source_ref: string }>();
  const latestRestoreFailure = restoreFailures.results[0];
  const supersededRestoreFailures = latestRestoreFailure
    ? restoreFailures.results.slice(1).map((row) => ({ ...row, latest_source_ref: latestRestoreFailure.source_ref }))
    : [];
  const cleanupCandidates = await context.env.DB.prepare(
    `SELECT id, source_ref, title, evidence_json
       FROM triage_items
      WHERE source_kind = 'operational_alert' AND status <> 'resolved'
        AND (source_ref LIKE 'restore-scratch-cleanup:%'
          OR source_ref LIKE 'restore-multipart-cleanup:%'
          OR source_ref LIKE 'restore-normalized-cleanup:%'
          OR source_ref LIKE 'restore-normalized-staging-cleanup:%'
          OR source_ref LIKE 'restore-recovery-cleanup:%')
      ORDER BY id`,
  ).all<{ id: string; source_ref: string; title: string; evidence_json: string }>();
  const recoveredCleanup: Array<{ id: string; sourceRef: string; proof: Record<string, unknown> }> = [];
  for (const row of cleanupCandidates.results) {
    let evidence: Record<string, unknown>;
    try {
      evidence = JSON.parse(row.evidence_json) as Record<string, unknown>;
    } catch {
      continue;
    }
    if (row.source_ref.startsWith("restore-multipart-cleanup:")
      && typeof evidence.error === "string"
      && evidence.error.toLowerCase().includes("specified multipart upload does not exist")) {
      recoveredCleanup.push({ id: row.id, sourceRef: row.source_ref, proof: { providerResult: "multipart upload absent" } });
      continue;
    }
    const objectKey = typeof evidence.normalizedObjectKey === "string"
      ? evidence.normalizedObjectKey
      : typeof evidence.normalizedStagingObjectKey === "string" ? evidence.normalizedStagingObjectKey : null;
    if (row.source_ref.startsWith("restore-multipart-cleanup:") && objectKey) {
      const uploadId = row.source_ref.slice("restore-multipart-cleanup:".length);
      try {
        await context.env.BACKUPS.resumeMultipartUpload(objectKey, uploadId).abort();
        recoveredCleanup.push({ id: row.id, sourceRef: row.source_ref, proof: { bucket: "tc-grocery-v3-backups", objectKey, uploadId, abortRetried: true } });
        continue;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (message.toLowerCase().includes("multipart upload does not exist")) {
          recoveredCleanup.push({ id: row.id, sourceRef: row.source_ref, proof: { bucket: "tc-grocery-v3-backups", objectKey, uploadId, providerResult: "multipart upload absent" } });
          continue;
        }
      }
    }
    if (objectKey && !row.source_ref.startsWith("restore-multipart-cleanup:") && !(await context.env.BACKUPS.head(objectKey))) {
      recoveredCleanup.push({ id: row.id, sourceRef: row.source_ref, proof: { bucket: "tc-grocery-v3-backups", objectKey, exists: false } });
      continue;
    }
    if (typeof evidence.recoveryObjectPrefix === "string") {
      const prefix = evidence.recoveryObjectPrefix;
      if (/^restore-recovery\/[a-zA-Z0-9._:-]+\/$/.test(prefix)) {
        let cursor: string | undefined;
        let deletedObjects = 0;
        do {
          const listed = await context.env.BACKUPS.list({ prefix, limit: 1_000, ...(cursor ? { cursor } : {}) });
          const keys = listed.objects.map((object) => object.key);
          if (keys.length > 0) {
            await context.env.BACKUPS.delete(keys);
            deletedObjects += keys.length;
          }
          cursor = listed.truncated ? listed.cursor : undefined;
        } while (cursor);
        const remaining = await context.env.BACKUPS.list({ prefix, limit: 1 });
        if (remaining.objects.length === 0) {
          recoveredCleanup.push({ id: row.id, sourceRef: row.source_ref, proof: { bucket: "tc-grocery-v3-backups", prefix, deletedObjects, objects: 0 } });
          continue;
        }
      }
    }
    if (typeof evidence.scratchDatabaseId === "string" && context.env.D1_REST_API_TOKEN && context.env.CLOUDFLARE_ACCOUNT_ID) {
      const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${context.env.CLOUDFLARE_ACCOUNT_ID}/d1/database/${encodeURIComponent(evidence.scratchDatabaseId)}`, {
        headers: { authorization: `Bearer ${context.env.D1_REST_API_TOKEN}` },
      });
      if (response.status === 404) {
        recoveredCleanup.push({ id: row.id, sourceRef: row.source_ref, proof: { scratchDatabaseId: evidence.scratchDatabaseId, exists: false } });
      }
    }
  }
  const observedAt = new Date().toISOString();
  for (let offset = 0; offset < recoverable.results.length; offset += 90) {
    await context.env.DB.batch(recoverable.results.slice(offset, offset + 90).map((row) => context.env.DB.prepare(
      `UPDATE triage_items
          SET status = 'resolved', plan_ref = 'auto-plan://rejected-candidate-superseded',
              resolution_json = ?2, updated_at = CURRENT_TIMESTAMP, resolved_at = CURRENT_TIMESTAMP
        WHERE id = ?1 AND status <> 'resolved'`,
    ).bind(row.id, stableJson({
      resolution: "The failing candidate was rejected before publication; the current release passes the same hard guard.",
      failedReleaseId: row.failed_release_id,
      recoveryReleaseId: row.recovery_release_id,
      guardId: row.guard_id,
      observedAt,
    }))));
  }
  const operationalRecoveries = [
    ...recoveredBackups.map((row) => ({
      id: row.id,
      planRef: "auto-plan://later-backup-replicated",
      resolution: {
        resolution: "A later backup completed and replicated to the secondary bucket. Restore health remains tracked by its own drill incident.",
        backupId: row.backup_id,
        replicaId: row.replica_id,
        observedAt,
      },
    })),
    ...recoveredParity.results.map((row) => ({
      id: row.id,
      planRef: "auto-plan://parity-regression-cleared",
      resolution: {
        resolution: "A later legacy parity run compared the full surface with zero differences.",
        parityRunId: row.parity_id,
        diffCount: row.diff_count,
        observedAt,
      },
    })),
    ...recoveredJobRuns.results.map((row) => ({
      id: row.id,
      planRef: "auto-plan://later-job-run-completed",
      resolution: {
        resolution: "A later durable run for the same job completed successfully.",
        job: row.job,
        recoveryRunId: row.recovery_run_id,
        finishedAt: row.finished_at,
        observedAt,
      },
    })),
    ...recoveredScheduleGaps.results.map((row) => ({
      id: row.id,
      planRef: "auto-plan://schedule-heartbeat-recovered",
      resolution: {
        resolution: "A successful run is now recorded inside the schedule's maximum gap.",
        job: row.job,
        recoveryRunId: row.recovery_run_id,
        finishedAt: row.finished_at,
        observedAt,
      },
    })),
    ...recoveredSourceContracts.results.map((row) => ({
      id: row.id,
      planRef: "auto-plan://source-contract-recovered",
      resolution: {
        resolution: "A later source-contract observation passed for the same source.",
        sourceId: row.source_id,
        sentinelId: row.sentinel_id,
        sourceObservedAt: row.observed_at,
        observedAt,
      },
    })),
    ...supersededRestoreFailures.map((row) => ({
      id: row.id,
      planRef: "auto-plan://restore-attempt-superseded",
      resolution: {
        resolution: "A newer restore attempt supersedes this failed attempt; the newest hard incident remains open until a drill passes.",
        sourceRef: row.source_ref,
        activeSourceRef: row.latest_source_ref,
        observedAt,
      },
    })),
    ...recoveredCleanup.map((row) => ({
      id: row.id,
      planRef: "auto-plan://cleanup-absence-verified",
      resolution: {
        resolution: "The exact cleanup target is verified absent.",
        sourceRef: row.sourceRef,
        proof: row.proof,
        observedAt,
      },
    })),
  ];
  for (let offset = 0; offset < operationalRecoveries.length; offset += 90) {
    await context.env.DB.batch(operationalRecoveries.slice(offset, offset + 90).map((row) => context.env.DB.prepare(
      `UPDATE triage_items
          SET status = 'resolved', plan_ref = ?2, resolution_json = ?3,
              updated_at = CURRENT_TIMESTAMP, resolved_at = CURRENT_TIMESTAMP
        WHERE id = ?1 AND status <> 'resolved'`,
    ).bind(row.id, row.planRef, stableJson(row.resolution))));
  }
  const resolved = recoverable.results.length + operationalRecoveries.length;
  await recordAudit(context.env, context.get("identity"), "triage.reconcile", "triage_queue", null, "accepted", {
    resolved,
    observedAt,
  });
  return context.json({
    ok: true,
    resolved,
    observedAt,
    recoveryCounts: {
      backupFailures: recoveredBackups.length,
      supersededRestoreFailures: supersededRestoreFailures.length,
      cleanupCandidates: cleanupCandidates.results.length,
      cleanupRecovered: recoveredCleanup.length,
    },
  });
});

app.post("/internal/triage/:id/resolve", zValidator("json", triageResolveSchema), async (context) => {
  const body = context.req.valid("json");
  const existing = await context.env.DB.prepare("SELECT id FROM triage_items WHERE id = ?1").bind(context.req.param("id")).first();
  if (!existing) return jsonError("triage item not found", 404);
  if (body.status === "planned") {
    const parsedPlan = triagePlanSchema.safeParse(body.resolution);
    if (!parsedPlan.success) return jsonError(`planned triage items require the typed reviewer plan: ${parsedPlan.error.message}`, 422);
    if (parsedPlan.data.triageId !== context.req.param("id")) return jsonError("reviewer plan belongs to a different triage item", 409);
  }
  await context.env.DB.prepare(
    `UPDATE triage_items
        SET status = ?2, plan_ref = ?3, resolution_json = ?4, updated_at = CURRENT_TIMESTAMP,
            resolved_at = CASE WHEN ?2 = 'resolved' THEN CURRENT_TIMESTAMP ELSE NULL END
      WHERE id = ?1`,
  ).bind(context.req.param("id"), body.status, body.planRef ?? null, stableJson(body.resolution)).run();
  return context.json({ ok: true, triageId: context.req.param("id"), status: body.status });
});

app.get("/internal/doctor", async (context) => {
  const overdueAccuracyDraws = await markOverdueAccuracyDraws(context.env.DB);
  const [configuration, release, hardGuards, triage, batches] = await Promise.all([
    context.env.DB.prepare("SELECT id, deployed_at FROM configuration_versions WHERE active = 1").first(),
    context.env.DB.prepare(
      `SELECT current.release_id, current.updated_at, release.configuration_id
         FROM current_releases current JOIN releases release ON release.id = current.release_id
        WHERE current.market_id = 'omaha'`,
    ).first(),
    context.env.DB.prepare(
      `SELECT r.status, COUNT(*) AS count FROM guard_results r
        JOIN current_releases c ON c.release_id = r.release_id
       GROUP BY r.status`,
    ).all(),
    context.env.DB.prepare("SELECT status, COUNT(*) AS count FROM triage_items GROUP BY status").all(),
    context.env.DB.prepare("SELECT status, COUNT(*) AS count FROM capture_batches GROUP BY status").all(),
  ]);
  const healthy = Boolean(configuration && release)
    && (configuration as { id?: string } | null)?.id === (release as { configuration_id?: string } | null)?.configuration_id
    && hardGuards.results.every((row) => (row as { status: string }).status === "pass")
    && !triage.results.some((row) => (row as { status: string; count: number }).status === "open" && (row as { count: number }).count > 0);
  return context.json({ ok: healthy, configuration, release, hardGuards: hardGuards.results, triage: triage.results, batches: batches.results, overdueAccuracyDraws }, healthy ? 200 : 422);
});

app.all("/board-beta*", (context) => context.env.ASSETS.fetch(context.req.raw));
app.all("/omaha-grocery-prices*", (context) => context.env.ASSETS.fetch(context.req.raw));
app.all("/tools/*", (context) => context.env.ASSETS.fetch(context.req.raw));
app.all("*", (context) => context.env.ASSETS.fetch(context.req.raw));

app.onError((error, context) => {
  console.error(error);
  return context.json({ ok: false, error: context.env.APP_ENV === "production" ? "Internal error" : error.message }, 500);
});

export default {
  async fetch(request: Request, env: WorkerEnv, executionContext: ExecutionContext): Promise<Response> {
    return await app.fetch(request, env, executionContext);
  },
  scheduled(controller: ScheduledController, env: WorkerEnv, executionContext: ExecutionContext): void {
    executionContext.waitUntil(runScheduledOperations(env, controller.scheduledTime));
  },
};
