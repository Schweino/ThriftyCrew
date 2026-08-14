import { Hono, type MiddlewareHandler } from "hono";
import { cache } from "cloudflare:workers";
import { captureBatchProductsQuery } from "./capture-batch-products";
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
  captureEvidenceUploadFinalizeSchema,
  captureEvidenceUploadSessionSchema,
  evidenceMetadataSchema,
  engineParityReportSchema,
  entitlementVerificationRecordSchema,
  evidenceGateRecordSchema,
  jobDispatchSchema,
  jobRunCreateSchema,
  jobRunUpdateSchema,
  matchDecisionReconcileSchema,
  matchDecisionDeltaReconcileSchema,
  matchDecisionRebindSchema,
  matchDecisionsChunkSchema,
  matchRunSchema,
  milestoneAccrualSchema,
  observationChunkSchema,
  observationExistenceSchema,
  observationReferencesSchema,
  operationalAlertSchema,
  agentRegistrySchema,
  agentEvaluationRecordSchema,
  agentWorkItemClaimSchema,
  agentWorkItemCompleteSchema,
  agentWorkItemFailSchema,
  ingredientCampaignControlSchema,
  ingredientPricingWaveCreateSchema,
  ingredientPublicationBatchCreateSchema,
  ingredientPublicationExternalVerifySchema,
  ingredientPublicationVerifySchema,
  ingredientResolutionProposalSchema,
  ingredientPublicationFailureSchema,
  ingredientPriceResearchSchema,
  ingredientQaNotFoundSchema,
  ingredientQaPricedSchema,
  ingredientQaRetrySchema,
  ingredientQaResolutionSchema,
  ingredientStoreCheckClaimSchema,
  ingredientStoreCheckFailSchema,
  ingredientStoreCheckHeartbeatSchema,
  ingredientStoreCheckReopenSchema,
  ingredientStoreCaptureResultSchema,
  ingredientStoreQaCompleteSchema,
  ingredientStoreQaRejectSchema,
  ingredientCaptureChallengeOpenSchema,
  ingredientCaptureChallengeResolveSchema,
  ingredientEvidenceUploadSchema,
  pipelineOutboxAcknowledgeSchema,
  pipelineOutboxClaimSchema,
  pipelineOutboxNackSchema,
  recipeSuggestionRequestSchema,
  recipeWaveSnapshotSchema,
  recipeWavePublicationSchema,
  loginCanaryProbeSchema,
  archivalForecastSchema,
  archivePlanSchema,
  canonicalCleanupPlanSchema,
  canonicalCleanupExecuteSchema,
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
  promotionCalendarSyncSchema,
  promotionRequestClaimSchema,
  promotionRequestCompleteSchema,
  sourceSentinelResultSchema,
  telemetryEventSchema,
  triageResolveSchema,
  triagePlanSchema,
  OFFER_SNAPSHOT_CUTOVER,
} from "@thriftycrew/contracts";
import { decodeEvidenceUpload } from "./evidence-upload";
import { requiresCaptureHistoryAssessment } from "./capture-history";
import { deterministicId, digestHex, semanticObservationId, semanticProductVersion, stableJson } from "@thriftycrew/domain";
import { isEngineSnapshotEncoding } from "@thriftycrew/engine";
import { GhostEntitlementProvider, type Entitlement } from "@thriftycrew/entitlements";
import { authenticateMutation } from "./auth";
import { createRelease, findBatch, insertObservations, insertRecipeCosts, insertReleaseCells, upsertGuardResult } from "./database";
import { evaluateNotBlindGuard, evaluateReleaseGuards } from "./release-guards";
import { evaluateReleaseIntegrity } from "./release-integrity";
import { reconcileInactiveConfigurationDecisions } from "./match-decision-reconciliation";
import { checkpointPassedMatchRun } from "./match-run-checkpoint";
import { createAccuracyDraw, latestAccuracySummary, markOverdueAccuracyDraws, readAccuracyDraw, recordAccuracyVerdicts } from "./accuracy";
import { reconcileGhostRotation, runGhostClobberDrill } from "./ghost-reconciliation";
import { dispatchGithubJob, dispatchRegisteredAgent, githubWorkflowRuns, jobStatusRequiresAlert, raiseOperationalAlert, recordAudit, resolveOperationalAlert, resolveRecoveredJobRunAlerts, runArchivalForecast, runControlPlaneProof, runD1RecoveryCheckpoint, runScheduledOperations, scheduleGap } from "./operations";
import {
  buildEngineSnapshotShard,
  readEngineSnapshot,
  readEngineSnapshotIdentity,
  readEngineSnapshotManifest,
  readEngineSnapshotShard,
  type EngineSnapshotProfile,
  type EngineSourceMode,
} from "./engine-snapshot";
import { memberStatusHtml } from "./member-status";
import { accrueMilestoneEvidence, milestoneEvidenceSummary } from "./milestone-evidence";
import { runServerChaosDrill } from "./chaos-drills";
import { engineMayWriteCaptureSource } from "./capture-authorization";
import { evaluateContentPromotion } from "./content-batches";
import { recipeCommodityIds } from "./recipe-commodity-catalog";
import { claimAgentWorkItem, completeAgentWorkItem, enqueueIngredientDefinitionPlan, failAgentWorkItem, ingredientCampaignSnapshot, reconcileIngredientCampaign, reconcileIngredientHolds } from "./agent-work-items";
import { claimStoreChecks, createPricingWave, failStoreCheck, heartbeatStoreCheck, ingredientCampaignProgress, ingredientPipelineStatus, pipelineEvents, pricingWaveStatus, reconcileTerminalPricingJobs, reopenTerminalStoreCheckForCorrection, resolveClaimedStoreCheckFromCatalog } from "./ingredient-pricing-v2";
import { acknowledgePipelineOutbox, claimPipelineOutbox, nackPipelineOutbox } from "./pipeline-outbox";
import { completeIngredientStoreCapture, completeIngredientStoreQa, rejectIngredientStoreQa, uploadIngredientEvidence } from "./ingredient-independent-qa";
import { acknowledgeIngredientChallenge, openIngredientChallenge, resolveIngredientChallenge } from "./ingredient-challenges";
import { materializeHotCatalog } from "./hot-catalog";
import { attachIngredientProposal, createIngredientPublicationBatch, failIngredientPublicationBatch, ingredientPublicationProofPlan, materializeIngredientPublicationCaptures, verifyIngredientPublicationExternal, verifyIngredientPublicationCandidate } from "./ingredient-publication-v2";
import { releasePayloadObjectKey } from "./release-payloads";
import { assertLoginCanaryEvidenceHasNoEmail } from "./login-canary";
import { isMissingMultipartUploadError } from "./restore-cleanup";
import { validateBrowserCaptureEvidence, validateScreenshotEvidence } from "./evidence-validation";
import { buildReleaseRecipeBundles, buildReleaseRecipeDetailArchive, compactReleaseRecipeDetails, readCurrentRecipeBundle } from "./recipe-bundles";
import { backfillProductEntities, backfillReleaseReasons, buildProductEntitySuggestions } from "./data-maintenance";
import { readBrowserCaptureSla } from "./browser-capture-sla";
import { buildCaptureTermInserts } from "./capture-seal";
import { createDirectEvidenceUpload, createDirectObjectDownload } from "./capture-direct-upload";
import { issueCaptureUploadAttempt, type CaptureUploadAttempt } from "./capture-upload-attempts";
import { assessProductHistory, assessSourceSchema, type ProductHistoryRow } from "./capture-semantic-guards";
import { handleGithubActionsWebhook } from "./github-recovery";
import { acquireOperationLease, activeDeploymentBlockers, releaseOperationLease, renewOperationLease } from "./orchestration";
import { archiveConfiguration, compactConfiguration, rehydrateConfiguration } from "./configuration-archive";
import { transitionReadiness } from "./transitions";
import { cachedPublicJson, PublicJsonError, releaseEtag } from "./public-cache";
import { assertRetentionCandidatesStillUnprotected, readRetentionCandidates, readRetentionProtectionSummary } from "./retention";
import { planR2GarbageCollection, sweepR2GarbageCollection } from "./r2-gc";
import { compactHistoricalTriage } from "./triage-compaction";
import { runPromotionLifecycle } from "./promotion-lifecycle";
import type { MutationIdentity, MutationRole, WorkerEnv } from "./env";
export { D1BackupWorkflow } from "./backup-workflow";
export { D1RestoreDrillWorkflow } from "./restore-workflow";
export { CaptureValidationWorkflow } from "./capture-validation-workflow";

type Bindings = { Bindings: WorkerEnv; Variables: { identity: MutationIdentity } };
const app = new Hono<Bindings>();

app.use("*", async (context, next) => {
  await next();
  const explicitlyCacheable = context.req.method === "GET" && (
    context.req.path === "/api/v2/board"
    || context.req.path.startsWith("/api/v2/board/")
    || context.req.path === "/api/v2/feed"
    || context.req.path === "/api/v2/top5"
    || context.req.path === "/api/v2/free-rotation"
    || context.req.path === "/api/v2/recipes"
    || context.req.path.startsWith("/api/v2/recipes/")
    || context.req.path.startsWith("/api/v2/recipe-feed/")
  );
  if (!explicitlyCacheable) {
    const headers = new Headers(context.res.headers);
    headers.set("cache-control", "no-store");
    context.res = new Response(context.res.body, { status: context.res.status, statusText: context.res.statusText, headers });
  }
});

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

function requireValidExecutionFence(): MiddlewareHandler<Bindings> {
  return async (context, next) => {
    const runId = context.req.header("x-tc-job-run");
    const fenceText = context.req.header("x-tc-lease-fence");
    if (!runId && !fenceText) return await next();
    if (!runId || !fenceText || !/^[1-9][0-9]*$/.test(fenceText)) return jsonError("execution fence headers are incomplete", 409);
    const run = await context.env.DB.prepare(
      `SELECT run.status, run.lease_resource, run.lease_fence, schedule.lease_minutes
         FROM job_runs run JOIN job_schedules schedule ON schedule.job = run.job
        WHERE run.id = ?1`,
    ).bind(runId).first<{ status: string; lease_resource: string | null; lease_fence: number | null; lease_minutes: number }>();
    const fence = Number(fenceText);
    if (!run?.lease_resource || run.lease_fence !== fence) return jsonError("execution fence is stale", 409);
    if (["completed", "failed", "missed", "timed_out", "cancelled"].includes(run.status)
      && context.req.method === "PATCH" && context.req.path === `/internal/job-runs/${runId}`) return await next();
    if (run.status !== "started") return jsonError("execution is not active", 409);
    const renewed = await renewOperationLease(context.env.DB, run.lease_resource, runId, fence, run.lease_minutes);
    if (!renewed) return jsonError("execution lease expired or was superseded", 409);
    return await next();
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

function requireRegisteredAgentScope(): MiddlewareHandler<Bindings> {
  return async (context, next) => {
    const identity = context.get("identity");
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
    if (identity.authMethod === "github_oidc" && identity.workflowRef?.includes("/platform-restore.yml@") && pathname !== "/internal/restore-drills/trigger") {
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
app.use("/internal/*", requireValidExecutionFence());
app.use("/internal/*", requireRegisteredAgentScope());
app.use("/internal/capture-batches", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/capture-batches/*", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/capture-metrics", requireIdentityRole(["engine", "operator"]));
app.use("/internal/capture-journal-checkpoints", requireIdentityRole(["capture", "operator"]));
app.use("/internal/capture-journal-checkpoints/*", requireIdentityRole(["capture", "operator"]));
app.use("/internal/configurations", requireIdentityRole(["engine", "operator"]));
app.use("/internal/configurations/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/match-decisions", requireIdentityRole(["engine", "operator"]));
app.use("/internal/match-decisions/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/match-runs", requireIdentityRole(["engine", "operator"]));
app.use("/internal/match-runs/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/job-runs", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/job-runs/*", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/operational-alerts", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/jobs/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/schedules/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/promotions/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/agents/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/agent-work-items/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/agent-evaluations", requireIdentityRole(["engine", "operator"]));
app.use("/internal/recipe-suggestions", requireIdentityRole(["engine", "operator"]));
app.use("/internal/ingredient-gaps", requireIdentityRole(["engine", "operator"]));
app.use("/internal/recipe-waves/*", requireIdentityRole(["operator"]));
app.use("/internal/login-canary-probes", requireIdentityRole(["capture", "operator"]));
app.use("/internal/content-batches", requireIdentityRole(["engine", "operator"]));
app.use("/internal/content-batches/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/source-sentinels", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/source-sentinels/*", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/archival/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/maintenance/*", requireIdentityRole(["operator"]));
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
app.use("/internal/deployments/*", requireIdentityRole(["operator"]));
app.use("/internal/cache/*", requireIdentityRole(["operator"]));
app.use("/internal/transitions/*", requireIdentityRole(["operator"]));
app.use("/internal/control-plane/*", requireIdentityRole(["operator"]));
app.use("/internal/engine/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/drills/*", requireIdentityRole(["operator"]));

app.post("/webhooks/github/actions", (context) => handleGithubActionsWebhook(context.req.raw, context.env, context.executionCtx));

app.post("/internal/cache/purge", async (context) => {
  const result = await cache.purge({ tags: ["grocery-public"], pathPrefixes: ["/api/v2/"] });
  await recordAudit(context.env, context.get("identity"), "public_cache.purge", "cache", "grocery-public", result.success ? "accepted" : "failed", { success: result.success, errors: result.errors });
  return context.json({ ok: result.success, ...result }, result.success ? 200 : 502);
});

app.get("/api/v2/status", async (context) => {
  const checkedAt = new Date();
  const [release, schedules, accuracy, triage, milestones, agentWork, evaluations, loginCanaries, browserCaptureSla, browserCaptureTelemetry] = await Promise.all([
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
    readBrowserCaptureSla(context.env.DB, checkedAt),
    context.env.DB.prepare(
      `WITH ranked AS (
         SELECT source_id, cycle_start, coverage_mode, expected_terms, attempted_terms,
                success_terms, empty_terms, rejected_terms, blocked_terms, not_attempted_terms,
                retry_count, chunk_count, duration_ms, term_duration_p50_ms, term_duration_p95_ms,
                projected_rows, observation_count, taxonomy_rows, accuracy_policy_version, discovery_rows,
                required_verification_rows, matched_verification_rows, unresolved_verification_rows,
                price_agreement_rows, single_channel_rows, anomaly_rows, retrieval_complete_terms, recorded_at,
                unique_products, discovery_edges, duplicate_product_references, product_reads_required,
                verification_reuse, immutable_shard_count,
                ROW_NUMBER() OVER (PARTITION BY source_id ORDER BY cycle_start DESC, recorded_at DESC) AS ordinal
           FROM browser_capture_metrics
       )
       SELECT source_id, cycle_start, coverage_mode, expected_terms, attempted_terms,
              success_terms, empty_terms, rejected_terms, blocked_terms, not_attempted_terms,
              retry_count, chunk_count, duration_ms, term_duration_p50_ms, term_duration_p95_ms,
              projected_rows, observation_count, taxonomy_rows, accuracy_policy_version, discovery_rows,
              required_verification_rows, matched_verification_rows, unresolved_verification_rows,
              price_agreement_rows, single_channel_rows, anomaly_rows, retrieval_complete_terms, recorded_at
              , unique_products, discovery_edges, duplicate_product_references, product_reads_required,
                verification_reuse, immutable_shard_count
         FROM ranked WHERE ordinal = 1 ORDER BY source_id`,
    ).all(),
  ]);
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
    browserCaptureSla,
    browserCaptureTelemetry: browserCaptureTelemetry.results,
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
  return cachedPublicJson(context.req.raw, async () => {
    const row = await context.env.DB.prepare(
    `SELECT r.id AS release_id, r.published_at, p.payload_json, p.object_key, p.content_hash
       FROM current_releases c
       JOIN releases r ON r.id = c.release_id
       JOIN release_payloads p ON p.release_id = r.id AND p.kind = 'board'
      WHERE c.market_id = 'omaha'`,
    ).first<{ release_id: string; published_at: string; payload_json: string; object_key: string | null; content_hash: string }>();
    if (!row) throw new PublicJsonError("No published Omaha release", 404);
    const board = row.object_key
      ? await context.env.EVIDENCE.get(row.object_key).then((object) => object?.json())
      : JSON.parse(row.payload_json);
    if (board === undefined) throw new PublicJsonError("Published board payload is unavailable", 500);
    return {
      body: { ok: true, releaseId: row.release_id, publishedAt: row.published_at, board },
      etag: releaseEtag(row.content_hash),
      releaseId: row.release_id,
    };
  });
});

app.get("/v2/board", (context) => context.redirect("/api/v2/board", 307));

async function currentPayload(env: WorkerEnv, kind: "board" | "feed" | "top5" | "free_rotation" | "recipes"): Promise<{
  releaseId: string;
  publishedAt: string;
  payload: unknown;
  contentHash: string;
} | null> {
  const row = await env.DB.prepare(
    `SELECT r.id AS release_id, r.published_at, p.payload_json, p.object_key, p.content_hash
       FROM current_releases c
       JOIN releases r ON r.id = c.release_id
       JOIN release_payloads p ON p.release_id = r.id AND p.kind = ?1
      WHERE c.market_id = 'omaha'`,
  ).bind(kind).first<{ release_id: string; published_at: string; payload_json: string; object_key: string | null; content_hash: string }>();
  if (!row) return null;
  const payload = row.object_key ? await env.EVIDENCE.get(row.object_key).then((object) => object?.json()) : JSON.parse(row.payload_json);
  if (payload === undefined) throw new Error(`Published ${kind} payload is unavailable`);
  return { releaseId: row.release_id, publishedAt: row.published_at, payload, contentHash: row.content_hash };
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
    return cachedPublicJson(context.req.raw, async () => {
      const current = await currentPayload(context.env, kind);
      if (!current) throw new PublicJsonError(`No published ${kind} payload`, 404);
      const { contentHash, ...publicPayload } = current;
      return { body: { ok: true, ...publicPayload }, etag: releaseEtag(contentHash), releaseId: current.releaseId };
    });
  });
}

app.get("/api/v2/board/:commodity", async (context) => {
  return cachedPublicJson(context.req.raw, async () => {
    const current = await currentPayload(context.env, "board");
    if (!current) throw new PublicJsonError("No published board payload", 404);
    const board = current.payload as { commodities?: Array<{ id?: string }> };
    const commodity = board.commodities?.find((item) => item.id === context.req.param("commodity"));
    if (!commodity) throw new PublicJsonError("Commodity not found", 404);
    return {
      body: { ok: true, releaseId: current.releaseId, publishedAt: current.publishedAt, commodity },
      etag: releaseEtag(current.contentHash),
      releaseId: current.releaseId,
    };
  });
});

app.get("/api/v2/recipes/:slug", async (context) => {
  return cachedPublicJson(context.req.raw, async () => {
    const slug = context.req.param("slug");
    const scenarioRows = await context.env.DB.prepare(
      `SELECT scenario_kind, store_location_key, status, batch_cost_minor, serving_cost_minor,
              missing_ingredients_json, content_hash
         FROM current_recipe_scenarios WHERE market_id = 'omaha' AND recipe_slug = ?1
        ORDER BY scenario_kind, store_location_key`,
    ).bind(slug).all<{ scenario_kind: string; store_location_key: string; status: string; batch_cost_minor: number | null; serving_cost_minor: number | null; missing_ingredients_json: string; content_hash: string }>();
    const scenarios: Record<string, unknown> = {};
    for (const row of scenarioRows.results) {
      const value = { status: row.status, batchCostMinor: row.batch_cost_minor, servingCostMinor: row.serving_cost_minor, missingIngredients: JSON.parse(row.missing_ingredients_json) };
      if (row.scenario_kind === "selected-store-checkout") {
        const selected = scenarios.selectedStoreCheckout && typeof scenarios.selectedStoreCheckout === "object" ? scenarios.selectedStoreCheckout as Record<string, unknown> : {};
        selected[row.store_location_key] = value;
        scenarios.selectedStoreCheckout = selected;
      } else {
        const key = row.scenario_kind.replace(/-([a-z])/g, (_, letter: string) => letter.toUpperCase());
        scenarios[key] = value;
      }
    }
    const scenarioHash = await digestHex(stableJson(scenarioRows.results.map((row) => row.content_hash)));
    const bundled = await readCurrentRecipeBundle(context.env, slug);
    const bundledRecipe = bundled?.bundle.recipe && typeof bundled.bundle.recipe === "object" && !Array.isArray(bundled.bundle.recipe)
      ? bundled.bundle.recipe as Record<string, unknown> : {};
    if (bundled) return {
      body: { ok: true, releaseId: bundled.releaseId, publishedAt: bundled.publishedAt, recipe: { ...bundledRecipe, scenarios } },
      etag: releaseEtag(await digestHex(`${bundled.releaseId}:${bundled.contentHash}:${scenarioHash}`)),
      releaseId: bundled.releaseId,
    };
    const current = await currentPayload(context.env, "recipes");
    if (!current) throw new PublicJsonError("No published recipe payload", 404);
    const payload = current.payload as { recipes?: Array<{ slug?: string }> };
    const recipe = payload.recipes?.find((item) => item.slug === slug);
    if (!recipe) throw new PublicJsonError("Recipe not found", 404);
    return {
      body: { ok: true, releaseId: current.releaseId, publishedAt: current.publishedAt, recipe: { ...recipe, scenarios } },
      etag: releaseEtag(await digestHex(`${current.contentHash}:${scenarioHash}`)),
      releaseId: current.releaseId,
    };
  });
});

app.get("/api/v2/recipe-feed/:slug", async (context) => {
  return cachedPublicJson(context.req.raw, async () => {
    const bundled = await readCurrentRecipeBundle(context.env, context.req.param("slug"));
    if (!bundled) throw new PublicJsonError("Recipe feed not found", 404);
    return {
      body: bundled.bundle.feed,
      etag: releaseEtag(await digestHex(`${bundled.releaseId}:${bundled.contentHash}`)),
      releaseId: bundled.releaseId,
    };
  });
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
  const bundled = await readCurrentRecipeBundle(context.env, slug);
  let recipe = bundled?.bundle.recipe;
  if (!recipe) {
    const current = await currentPayload(context.env, "recipes");
    const payload = current?.payload as { recipes?: Array<{ slug?: string }> } | undefined;
    recipe = payload?.recipes?.find((item) => item.slug === slug);
  }
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
      `DELETE FROM configuration_match_rules
        WHERE configuration_id = ?1
          AND definition_id IN (SELECT id FROM match_rule_definitions WHERE commodity_id = ?2)`,
    ).bind(configurationId, commodity.id));
    statements.push(context.env.DB.prepare(
      `INSERT INTO commodities (id, configuration_id, label, basis_unit, category_id, band_min_micros, band_max_micros, match_priority)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
       ON CONFLICT(id, configuration_id) DO UPDATE SET
         label = excluded.label, basis_unit = excluded.basis_unit, category_id = excluded.category_id,
         band_min_micros = excluded.band_min_micros, band_max_micros = excluded.band_max_micros,
         match_priority = excluded.match_priority`,
    ).bind(commodity.id, configurationId, commodity.label, commodity.basisUnit, commodity.categoryId, commodity.bandMinMicros ?? null, commodity.bandMaxMicros ?? null, commodity.matchPriority ?? 0));
    for (const [kind, patterns] of [["include", commodity.include], ["exclude", commodity.exclude]] as const) {
      for (const pattern of patterns) {
        const ruleId = await deterministicId("rule-definition", commodity.id, kind, pattern, "authored configuration", "0");
        statements.push(context.env.DB.prepare(
          `INSERT OR IGNORE INTO match_rule_definitions
             (id, commodity_id, kind, pattern, reason, priority)
           VALUES (?1, ?2, ?3, ?4, 'authored configuration', 0)`,
        ).bind(ruleId, commodity.id, kind, pattern));
        statements.push(context.env.DB.prepare(
          "INSERT OR IGNORE INTO configuration_match_rules (configuration_id, definition_id) VALUES (?1, ?2)",
        ).bind(configurationId, ruleId));
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
  await rehydrateConfiguration(context.env, configurationId, context.get("identity").agentId);
  const row = await context.env.DB.prepare(
    `SELECT v.expected_categories, v.expected_commodities, v.expected_rules, v.expected_known_wrong,
             (SELECT COUNT(*) FROM configuration_categories c WHERE c.configuration_id = v.id) AS categories,
             (SELECT COUNT(*) FROM commodities c WHERE c.configuration_id = v.id) AS commodities,
             ((SELECT COUNT(*) FROM match_rules r WHERE r.configuration_id = v.id)
               + (SELECT COUNT(*) FROM configuration_match_rules r WHERE r.configuration_id = v.id)) AS rules,
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
  const archive = await archiveConfiguration(context.env, configurationId);
  await context.env.DB.batch([
    context.env.DB.prepare("UPDATE configuration_versions SET active = 0 WHERE active = 1 AND id <> ?1").bind(configurationId),
    context.env.DB.prepare("UPDATE configuration_versions SET active = 1, deployed_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(configurationId),
  ]);
  return context.json({ ok: true, configurationId, active: true, archive, counts: { categories: row.categories, commodities: row.commodities, rules: row.rules, knownWrong: row.known_wrong } });
});

app.post("/internal/configurations/:id/archive", async (context) => {
  const configurationId = context.req.param("id");
  const archive = await archiveConfiguration(context.env, configurationId);
  return context.json({ ok: true, configurationId, archive });
});

app.post("/internal/configurations/:id/rehydrate", async (context) => {
  try {
    const result = await rehydrateConfiguration(context.env, context.req.param("id"), context.get("identity").agentId);
    return context.json({ ok: true, ...result });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "configuration rehydration failed", 409);
  }
});

app.get("/internal/configurations/archives", async (context) => {
  const rows = await context.env.DB.prepare(
    `SELECT version.id, version.content_hash, version.active, version.deployed_at,
            archive.object_key, archive.byte_length, archive.sha256, archive.status, archive.verified_at
       FROM configuration_versions version LEFT JOIN configuration_archives archive ON archive.configuration_id = version.id
      ORDER BY version.deployed_at DESC`,
  ).all();
  return context.json({ ok: true, configurations: rows.results });
});

app.post("/internal/configurations/:id/compact", async (context) => {
  try {
    const compacted = await compactConfiguration(context.env, context.req.param("id"), context.get("identity").agentId);
    return context.json({ ok: true, ...compacted });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "configuration compaction failed", 409);
  }
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
         superseded_at = NULL
       WHERE match_decisions.decided_by <> excluded.decided_by
          OR match_decisions.reason <> excluded.reason
          OR match_decisions.superseded_at IS NOT NULL`,
    ).bind(decisionId, decision.productId, decision.commodityId, decision.configurationId, decision.decidedBy, decision.reason));
  }
  let superseded = 0;
  let decisionWrites = 0;
  for (let offset = 0; offset < statements.length; offset += 90) {
    const results = await context.env.DB.batch(statements.slice(offset, offset + 90));
    results.forEach((result, index) => {
      if ((offset + index) % 2 === 0) superseded += result.meta.changes ?? 0;
      else decisionWrites += result.meta.changes ?? 0;
    });
  }
  return context.json({
    ok: true,
    accepted: decisions.length,
    decisionWrites,
    superseded,
    unchanged: Math.max(0, decisions.length - decisionWrites),
  });
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
            FROM capture_batch_observations member
            JOIN observations o ON o.id = member.observation_id
            JOIN product_versions pv ON pv.id = o.product_version_id
            JOIN products p ON p.id = pv.product_id
           WHERE member.batch_id = ?1
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

app.post("/internal/match-decisions/rebind", zValidator("json", matchDecisionRebindSchema), async (context) => {
  const body = context.req.valid("json");
  const batch = await findBatch(context.env.DB, body.batchId);
  if (!batch) return jsonError("capture batch not found", 404);
  const target = await context.env.DB.prepare(
    "SELECT id FROM configuration_versions WHERE id = ?1 AND active = 1",
  ).bind(body.targetConfigurationId).first<{ id: string }>();
  if (!target) return jsonError("match decision rebind target must be the active configuration", 422);
  const baseline = await context.env.DB.prepare(
    `SELECT id, input_hash, product_count, matched_count, unmatched_count, collision_count, aisle_rejected_count
       FROM match_runs
      WHERE batch_id = ?1 AND configuration_id = ?2 AND status = 'passed'
      ORDER BY created_at DESC, id DESC LIMIT 1`,
  ).bind(body.batchId, body.sourceConfigurationId).first<Record<string, unknown>>();
  if (!baseline) return jsonError("passed source-configuration match baseline not found", 409);
  const excluded = stableJson([...new Set(body.excludedProductIds)]);
  const cloneId = `'match_rebind_' || ?3 || '_' || decision.product_id`;
  const membership = `decision.product_id IN (
    SELECT DISTINCT product.id
      FROM capture_batch_observations member
      JOIN observations observation ON observation.id = member.observation_id
      JOIN product_versions version ON version.id = observation.product_version_id
      JOIN products product ON product.id = version.product_id
     WHERE member.batch_id = ?1
  )`;
  const results = await context.env.DB.batch([
    context.env.DB.prepare(`INSERT OR IGNORE INTO match_decisions
      (id, product_id, commodity_id, configuration_id, decided_by, reason, superseded_at)
      SELECT ${cloneId}, decision.product_id, decision.commodity_id, ?3, decision.decided_by,
             decision.reason || '; unchanged classification rebound from ' || ?2, CURRENT_TIMESTAMP
        FROM match_decisions decision
       WHERE decision.configuration_id = ?2 AND decision.superseded_at IS NULL
         AND ${membership}
         AND decision.product_id NOT IN (SELECT value FROM json_each(?4))
         AND EXISTS (SELECT 1 FROM commodities commodity
                      WHERE commodity.id = decision.commodity_id AND commodity.configuration_id = ?3)`)
      .bind(body.batchId, body.sourceConfigurationId, body.targetConfigurationId, excluded),
    context.env.DB.prepare(`UPDATE match_decisions AS decision
      SET superseded_at = CURRENT_TIMESTAMP
      WHERE decision.configuration_id = ?2 AND decision.superseded_at IS NULL
        AND ${membership}
        AND decision.product_id NOT IN (SELECT value FROM json_each(?4))
        AND EXISTS (SELECT 1 FROM match_decisions clone
                     WHERE clone.id = 'match_rebind_' || ?3 || '_' || decision.product_id
                       AND clone.configuration_id = ?3)`)
      .bind(body.batchId, body.sourceConfigurationId, body.targetConfigurationId, excluded),
    context.env.DB.prepare(`UPDATE match_decisions AS decision
      SET superseded_at = NULL
      WHERE decision.configuration_id = ?3
        AND decision.id = 'match_rebind_' || ?3 || '_' || decision.product_id
        AND decision.product_id IN (
          SELECT DISTINCT product.id
            FROM capture_batch_observations member
            JOIN observations observation ON observation.id = member.observation_id
            JOIN product_versions version ON version.id = observation.product_version_id
            JOIN products product ON product.id = version.product_id
           WHERE member.batch_id = ?1
        )
        AND decision.product_id NOT IN (SELECT value FROM json_each(?4))
        AND NOT EXISTS (SELECT 1 FROM match_decisions active
                         WHERE active.product_id = decision.product_id AND active.superseded_at IS NULL)`)
      .bind(body.batchId, body.sourceConfigurationId, body.targetConfigurationId, excluded),
  ]);
  const response = {
    ok: true,
    batchId: body.batchId,
    sourceConfigurationId: body.sourceConfigurationId,
    targetConfigurationId: body.targetConfigurationId,
    excluded: body.excludedProductIds.length,
    inserted: results[0]?.meta.changes ?? 0,
    superseded: results[1]?.meta.changes ?? 0,
    activated: results[2]?.meta.changes ?? 0,
    baseline,
  };
  await recordAudit(context.env, context.get("identity"), "matching.incremental-rebind", "capture_batch", body.batchId, "accepted", response);
  return context.json(response);
});

app.post("/internal/match-decisions/reconcile-delta", zValidator("json", matchDecisionDeltaReconcileSchema), async (context) => {
  const body = context.req.valid("json");
  const batch = await findBatch(context.env.DB, body.batchId);
  if (!batch) return jsonError("capture batch not found", 404);
  const target = await context.env.DB.prepare(
    "SELECT id FROM configuration_versions WHERE id = ?1 AND active = 1",
  ).bind(body.configurationId).first<{ id: string }>();
  if (!target) return jsonError("delta reconciliation must use the active configuration", 422);
  const affected = stableJson([...new Set(body.affectedProductIds)]);
  const retained = stableJson([...new Set(body.retainedProductIds)]);
  const updated = await context.env.DB.prepare(`UPDATE match_decisions
    SET superseded_at = CURRENT_TIMESTAMP
    WHERE superseded_at IS NULL
      AND product_id IN (SELECT value FROM json_each(?2))
      AND product_id NOT IN (SELECT value FROM json_each(?3))
      AND product_id IN (
        SELECT DISTINCT product.id
          FROM capture_batch_observations member
          JOIN observations observation ON observation.id = member.observation_id
          JOIN product_versions version ON version.id = observation.product_version_id
          JOIN products product ON product.id = version.product_id
         WHERE member.batch_id = ?1
      )`).bind(body.batchId, affected, retained).run();
  const retainedCount = body.retainedProductIds.length === 0 ? 0 : Number((await context.env.DB.prepare(`SELECT COUNT(DISTINCT decision.product_id) AS count
    FROM match_decisions decision
    WHERE decision.configuration_id = ?1 AND decision.superseded_at IS NULL
      AND decision.product_id IN (SELECT value FROM json_each(?2))`).bind(body.configurationId, retained).first<{ count: number }>())?.count ?? 0);
  if (retainedCount !== new Set(body.retainedProductIds).size) return jsonError("delta reconciliation retained products lack active target decisions", 409);
  const response = { ok: true, batchId: body.batchId, affected: body.affectedProductIds.length,
    retained: body.retainedProductIds.length, superseded: updated.meta.changes ?? 0 };
  await recordAudit(context.env, context.get("identity"), "matching.incremental-reconcile", "capture_batch", body.batchId, "accepted", response);
  return context.json(response);
});

app.get("/internal/configurations/active-metadata", async (context) => {
  const active = await context.env.DB.prepare(
    "SELECT id, source_commit, content_hash FROM configuration_versions WHERE active = 1",
  ).first<{ id: string; source_commit: string | null; content_hash: string }>();
  return active ? context.json({ ok: true, configurationId: active.id, sourceCommit: active.source_commit, contentHash: active.content_hash })
    : jsonError("active configuration not found", 404);
});

app.post("/internal/configurations/:id/clone-active", async (context) => {
  const configurationId = context.req.param("id");
  const target = await context.env.DB.prepare("SELECT active FROM configuration_versions WHERE id = ?1").bind(configurationId).first<{ active: number }>();
  if (!target) return jsonError("configuration not found", 404);
  if (target.active === 1) return context.json({ ok: true, configurationId, idempotent: true });
  const source = await context.env.DB.prepare("SELECT id, source_commit FROM configuration_versions WHERE active = 1 AND id <> ?1")
    .bind(configurationId).first<{ id: string; source_commit: string | null }>();
  if (!source) return jsonError("active configuration clone source not found", 409);
  await context.env.DB.batch([
    context.env.DB.prepare(`INSERT OR IGNORE INTO configuration_categories (configuration_id, category_id)
      SELECT ?1, category_id FROM configuration_categories WHERE configuration_id = ?2`).bind(configurationId, source.id),
    context.env.DB.prepare(`INSERT OR IGNORE INTO commodities
      (id, configuration_id, label, basis_unit, category_id, band_min_micros, band_max_micros, match_priority)
      SELECT id, ?1, label, basis_unit, category_id, band_min_micros, band_max_micros, match_priority
        FROM commodities WHERE configuration_id = ?2`).bind(configurationId, source.id),
    context.env.DB.prepare(`INSERT OR IGNORE INTO configuration_match_rules (configuration_id, definition_id)
      SELECT ?1, definition_id FROM configuration_match_rules WHERE configuration_id = ?2`).bind(configurationId, source.id),
  ]);
  const knownWrong = await context.env.DB.prepare(`SELECT commodity_id,store_location_id,external_product_key,normalized_name,ruling,evidence
    FROM known_wrong_rules WHERE configuration_id = ?1 ORDER BY id`).bind(source.id).all<Record<string, unknown>>();
  const statements = await Promise.all(knownWrong.results.map(async (rule) => context.env.DB.prepare(`INSERT OR IGNORE INTO known_wrong_rules
    (id,configuration_id,commodity_id,store_location_id,external_product_key,normalized_name,ruling,evidence)
    VALUES (?1,?2,?3,?4,?5,?6,?7,?8)`).bind(await deterministicId("known-wrong-clone", configurationId, stableJson(rule)), configurationId,
    rule.commodity_id, rule.store_location_id, rule.external_product_key, rule.normalized_name, rule.ruling, rule.evidence)));
  for (let offset = 0; offset < statements.length; offset += 90) await context.env.DB.batch(statements.slice(offset, offset + 90));
  const cloned = await context.env.DB.prepare("SELECT id FROM commodities WHERE configuration_id = ?1 ORDER BY id").bind(configurationId).all<{ id: string }>();
  return context.json({ ok: true, configurationId, sourceConfigurationId: source.id, sourceCommit: source.source_commit,
    commodityIds: cloned.results.map((row) => row.id), idempotent: false });
});

app.post("/internal/match-decisions/reconcile-inactive", async (context) => {
  const reconciliation = await reconcileInactiveConfigurationDecisions(context.env.DB);
  await recordAudit(context.env, context.get("identity"), "matching.reconcile-inactive", "configuration",
    reconciliation.activeConfigurationId ?? "missing", "accepted", { ...reconciliation });
  return context.json({ ok: true, reconciliation });
});

app.get("/internal/capture-batches/:id/products", async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const configuration = await context.env.DB.prepare(
    "SELECT id, content_hash FROM configuration_versions WHERE active = 1",
  ).first<{ id: string; content_hash: string }>();
  if (!configuration) return jsonError("active configuration not found", 422);
  const products = await context.env.DB.prepare(captureBatchProductsQuery).bind(batch.id).all();
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
  const validation = await context.env.DB.prepare(
    `SELECT workflow_instance_id, status, attempts, result_status, pipeline_stage, match_run_id,
            configuration_id, configuration_hash, promoted_at, pipeline_completed_at, error,
            created_at, started_at, completed_at
       FROM capture_validation_jobs WHERE batch_id = ?1`,
  ).bind(batch.id).first<Record<string, unknown>>();
  return context.json({
    ok: batch.status === "promoted" || batch.status === "superseded",
    batchId: batch.id,
    sourceId: batch.source_id,
    status: batch.status,
    coverageMode: batch.coverage_mode,
    capturedTo: batch.captured_to,
    matching: matching ?? null,
    validation: validation ?? null,
    evidence: evidence.results,
  });
});

app.get("/internal/capture-metrics", async (context) => {
  const requestedLimit = Number.parseInt(context.req.query("limit") ?? "25", 10);
  const limit = Number.isFinite(requestedLimit) ? Math.min(100, Math.max(1, requestedLimit)) : 25;
  const metrics = await context.env.DB.prepare(
    `SELECT batch_id, session_id, source_id, cycle_start, coverage_mode,
            expected_terms, attempted_terms, success_terms, empty_terms, rejected_terms,
            blocked_terms, not_attempted_terms, retry_count, chunk_count, duration_ms,
            term_duration_p50_ms, term_duration_p95_ms, projected_rows, observation_count,
            taxonomy_rows, accuracy_policy_version, discovery_rows, required_verification_rows,
            matched_verification_rows, unresolved_verification_rows, price_agreement_rows,
            single_channel_rows, anomaly_rows, retrieval_complete_terms, recorded_at
            , unique_products, discovery_edges, duplicate_product_references, product_reads_required,
              verification_reuse, immutable_shard_count
       FROM browser_capture_metrics
      ORDER BY recorded_at DESC, source_id LIMIT ?1`,
  ).bind(limit).all();
  return context.json({ ok: true, metrics: metrics.results });
});

app.get("/internal/match-runs/:id", async (context) => {
  const row = await context.env.DB.prepare(
    `SELECT id, batch_id, configuration_id, input_hash, status, product_count, matched_count,
            unmatched_count, collision_count, aisle_rejected_count, detail_json, created_at
       FROM match_runs WHERE id = ?1`,
  ).bind(context.req.param("id")).first<Record<string, unknown> & { detail_json: string }>();
  if (!row) return context.json({ ok: false, found: false, error: "match run not found" }, 404);
  const actual = await context.env.DB.prepare(
    `SELECT COUNT(DISTINCT product.id) AS products,
            COUNT(DISTINCT CASE WHEN decision.product_id IS NOT NULL THEN product.id END) AS matched
       FROM capture_batch_observations member
       JOIN observations observation ON observation.id = member.observation_id
       JOIN product_versions version ON version.id = observation.product_version_id
       JOIN products product ON product.id = version.product_id
       LEFT JOIN match_decisions decision ON decision.product_id = product.id
        AND decision.configuration_id = ?2 AND decision.superseded_at IS NULL
      WHERE member.batch_id = ?1`,
  ).bind(String(row.batch_id), String(row.configuration_id)).first<{ products: number; matched: number }>();
  const { detail_json: detailJson, ...run } = row;
  return context.json({ ok: true, found: true, run: { ...run, detail: JSON.parse(detailJson), actual,
    integrity: Number(actual?.products ?? -1) === Number(row.product_count) && Number(actual?.matched ?? -1) === Number(row.matched_count) } });
});

app.post("/internal/capture-batches/:id/match-checkpoint", async (context) => {
  if (context.get("identity").role !== "operator" && context.get("identity").role !== "engine") {
    return jsonError("only an operator or engine may checkpoint a match run", 403);
  }
  const batchId = context.req.param("id");
  try {
    const checkpoint = await checkpointPassedMatchRun(context.env.DB, batchId);
    await recordAudit(context.env, context.get("identity"), "matching.integrity_checkpoint", "capture_batch", batchId,
      "accepted", checkpoint);
    return context.json({ ok: true, ...checkpoint }, checkpoint.idempotent ? 200 : 201);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "match-run checkpoint failed", 409);
  }
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
       FROM capture_batch_observations member
       JOIN observations o ON o.id = member.observation_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       LEFT JOIN match_decisions m ON m.product_id = p.id
         AND m.configuration_id = ?2 AND m.superseded_at IS NULL
      WHERE member.batch_id = ?1`,
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
  const inactiveDecisionReconciliation = status === "passed"
    ? await reconcileInactiveConfigurationDecisions(context.env.DB)
    : null;
  return context.json({ ok: status === "passed", runId: body.id, status, idempotent: false, inactiveDecisionReconciliation }, status === "passed" ? 201 : 422);
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
        lifecycle, authority_version, retirement_gate, workflow_file, monitoring_started_at, lease_minutes)
     VALUES (?1, ?2, ?3, ?10, ?4, ?5, ?6, ?7, ?8, ?9, ?11, ?12, ?13, ?14, CURRENT_TIMESTAMP, ?15)
     ON CONFLICT(job) DO UPDATE SET
       cron = excluded.cron, max_gap_minutes = excluded.max_gap_minutes,
       executor = excluded.executor, authority_executor = excluded.authority_executor,
       timezone = excluded.timezone, owner = excluded.owner,
       proof = excluded.proof, dispatch_on_gap = excluded.dispatch_on_gap,
       lifecycle = CASE WHEN job_schedules.lifecycle = 'retired' THEN 'retired' ELSE excluded.lifecycle END,
       active = CASE WHEN job_schedules.lifecycle = 'retired' THEN 0 ELSE excluded.active END,
       authority_version = excluded.authority_version,
       retirement_gate = excluded.retirement_gate, workflow_file = excluded.workflow_file,
       lease_minutes = excluded.lease_minutes,
       monitoring_started_at = CASE
         WHEN job_schedules.authority_version <> excluded.authority_version
           OR job_schedules.executor <> excluded.executor
           OR job_schedules.cron <> excluded.cron
           OR job_schedules.active <> excluded.active THEN CURRENT_TIMESTAMP
         ELSE COALESCE(job_schedules.monitoring_started_at, CURRENT_TIMESTAMP)
       END`,
  ).bind(
    schedule.id,
    schedule.cron,
    schedule.maxGapMinutes,
    schedule.executor === "codex-automation" || schedule.executor === "pc-startup" ? "pc" : schedule.executor,
    schedule.executor,
    document.timezone,
    schedule.owner,
    schedule.proof,
    schedule.dispatchOnGap ? 1 : 0,
    schedule.monitorInLedger && schedule.lifecycle !== "retired" && !schedule.suspended ? 1 : 0,
    schedule.lifecycle,
    document.version,
    schedule.retirementGate ?? null,
    schedule.workflowFile ?? null,
    schedule.leaseMinutes,
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
  for (const agent of registry.agents.filter((candidate) => candidate.enabled && candidate.plane === "pc")) {
    await resolveOperationalAlert(context.env, `agent-dispatch:${agent.id}`, {
      agentId: agent.id,
      plane: agent.plane,
      registryVersion: registry.version,
      resolution: "PC execution is authoritative; no GitHub dispatch is expected.",
    });
  }
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
    const result = await completeAgentWorkItem(context.env, identity, context.req.param("id"), body);
    if (identity.registeredAgentId === "accuracy-headless") {
      await recordAccuracyVerdicts(context.env.DB, accuracyVerdictsSchema.parse(body.output), identity.agentId);
    }
    const nextAgentId = typeof result.nextAgentId === "string" ? result.nextAgentId : null;
    let dispatch: Record<string, unknown> | null = null;
    if (nextAgentId) {
      try {
        dispatch = await dispatchRegisteredAgent(context.env, nextAgentId);
        await resolveOperationalAlert(context.env, `agent-dispatch:${nextAgentId}`, {
          agentId: nextAgentId,
          ...dispatch,
          resolution: dispatch.dispatched ? "Registered agent dispatch succeeded." : "The authoritative execution plane does not require GitHub dispatch.",
        });
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
  if (body.mode === "missing-ingredients") {
    await context.env.DB.prepare(
      `INSERT INTO ingredient_discovery_batches
         (request_id, target_missing_ingredients, target_published_ingredients)
       VALUES (?1, ?2, ?3) ON CONFLICT(request_id) DO NOTHING`,
    ).bind(body.id, body.targetMissingIngredients, body.targetPublishedIngredients ?? body.targetMissingIngredients).run();
  }
  return context.json({
    ok: true, requestId: body.id, mode: body.mode,
    targetMissingIngredients: body.mode === "missing-ingredients" ? body.targetMissingIngredients : null,
    targetPublishedIngredients: body.mode === "missing-ingredients" ? (body.targetPublishedIngredients ?? body.targetMissingIngredients) : null,
  }, 201);
});

app.get("/internal/ingredient-gaps", async (context) => {
  const requestedStatus = context.req.query("status");
  const allowed = new Set(["pending", "researching", "ready_to_publish", "published", "permanently_unavailable", "needs_operator"]);
  if (requestedStatus && !allowed.has(requestedStatus)) return jsonError("unknown ingredient gap status", 400);
  const gaps = await context.env.DB.prepare(
    `SELECT gap.id, gap.normalized_name, gap.display_name,
            CASE WHEN gap.qa_resolution IS NOT NULL THEN 'resolved_' || gap.qa_resolution ELSE gap.status END AS status,
            gap.commodity_id, gap.qa_resolution, gap.qa_resolution_commodity_id, gap.qa_resolved_at,
            CASE WHEN ?1 = 'ready_to_publish' THEN gap.research_json ELSE NULL END AS research_json,
            gap.first_seen_at, gap.updated_at, COUNT(occurrence.request_id) AS occurrence_count
       FROM ingredient_gaps gap
       LEFT JOIN ingredient_gap_occurrences occurrence ON occurrence.gap_id = gap.id
      WHERE (?1 IS NULL OR (gap.status = ?1 AND (?1 <> 'needs_operator' OR gap.qa_resolution IS NULL)))
      GROUP BY gap.id ORDER BY gap.first_seen_at DESC, gap.id LIMIT 500`,
  ).bind(requestedStatus ?? null).all();
  const batches = await context.env.DB.prepare(
    `SELECT batch.request_id, batch.target_missing_ingredients, batch.target_published_ingredients,
            batch.desired_pricing_workers, batch.publish_batch_size, batch.paused_at, batch.discovery_frozen_at,
            batch.unique_missing_ingredients, batch.source_round, batch.state, batch.created_at, batch.updated_at,
            COUNT(DISTINCT CASE WHEN gap.status = 'published' THEN gap.id END) AS published_ingredients,
            COUNT(DISTINCT CASE WHEN gap.status = 'pending' THEN gap.id END) AS pending_ingredients,
            COUNT(DISTINCT CASE WHEN gap.status = 'researching' THEN gap.id END) AS researching_ingredients,
            COUNT(DISTINCT CASE WHEN gap.status = 'ready_to_publish' THEN gap.id END) AS ready_to_publish_ingredients,
            COUNT(DISTINCT CASE WHEN gap.status = 'permanently_unavailable' THEN gap.id END) AS permanently_unavailable_ingredients,
            COUNT(DISTINCT CASE WHEN gap.status = 'needs_operator' AND gap.qa_resolution IS NULL THEN gap.id END) AS needs_operator_ingredients,
            COUNT(DISTINCT CASE WHEN gap.qa_resolution IS NOT NULL THEN gap.id END) AS resolved_qa_ingredients
       FROM ingredient_discovery_batches batch
       LEFT JOIN ingredient_gap_occurrences occurrence ON occurrence.request_id = batch.request_id
       LEFT JOIN ingredient_gaps gap ON gap.id = occurrence.gap_id
      GROUP BY batch.request_id ORDER BY batch.created_at DESC LIMIT 100`,
  ).all();
  const holds = await context.env.DB.prepare(
    `SELECT status, COUNT(*) AS count FROM recipe_ingredient_holds GROUP BY status ORDER BY status`,
  ).all();
  return context.json({ ok: true, status: requestedStatus ?? null, gaps: gaps.results, batches: batches.results, holds: holds.results });
});

app.post("/internal/ingredient-gaps/reconcile", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may reconcile ingredient publication", 403);
  await reconcileIngredientHolds(context.env.DB);
  return context.json({ ok: true, reconciled: true });
});

app.post("/internal/ingredient-campaigns/:id/control", zValidator("json", ingredientCampaignControlSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may control an ingredient campaign", 403);
  const requestId = context.req.param("id");
  const body = context.req.valid("json");
  const existing = await ingredientCampaignSnapshot(context.env.DB, requestId);
  if (!existing) return jsonError("ingredient campaign not found", 404);
  if (body.action === "pause") {
    await context.env.DB.batch([
      context.env.DB.prepare("UPDATE ingredient_discovery_batches SET paused_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1").bind(requestId),
      context.env.DB.prepare("UPDATE recipe_suggestion_requests SET status = 'running', updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'queued'").bind(requestId),
    ]);
  } else if (body.action === "freeze-discovery") {
    await context.env.DB.batch([
      context.env.DB.prepare("UPDATE ingredient_discovery_batches SET discovery_frozen_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1").bind(requestId),
      context.env.DB.prepare("UPDATE recipe_suggestion_requests SET status = 'running', updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'queued'").bind(requestId),
    ]);
    await reconcileIngredientCampaign(context.env.DB, requestId);
  } else if (body.action === "resume-discovery") {
    await context.env.DB.prepare(
      "UPDATE ingredient_discovery_batches SET discovery_frozen_at = NULL, updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1",
    ).bind(requestId).run();
    await reconcileIngredientCampaign(context.env.DB, requestId);
  } else {
    await context.env.DB.prepare(
      `UPDATE ingredient_discovery_batches
          SET target_published_ingredients = COALESCE(?2, target_published_ingredients),
              desired_pricing_workers = COALESCE(?3, desired_pricing_workers),
              publish_batch_size = COALESCE(?4, publish_batch_size),
              paused_at = CASE WHEN ?5 = 'resume' THEN NULL ELSE paused_at END,
              updated_at = CURRENT_TIMESTAMP WHERE request_id = ?1`,
    ).bind(requestId, body.targetPublishedIngredients ?? null, body.desiredPricingWorkers ?? null,
      body.publishBatchSize ?? null, body.action).run();
    await reconcileIngredientCampaign(context.env.DB, requestId);
  }
  return context.json({ ok: true, campaign: await ingredientCampaignSnapshot(context.env.DB, requestId) });
});

app.post("/internal/ingredient-gaps/qa-retry", zValidator("json", ingredientQaRetrySchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may retry ingredient QA", 403);
  const body = context.req.valid("json");
  const candidates = await context.env.DB.prepare(
    `SELECT id FROM ingredient_gaps
      WHERE status = 'needs_operator' AND publication_attempts = 0
        AND json_extract(research_json, '$.disposition') = 'needs_operator'
      ORDER BY first_seen_at, id LIMIT 50`,
  ).all<{ id: string }>();
  const requested = body.gapIds ? new Set(body.gapIds) : null;
  const gapIds = candidates.results.map((row) => row.id).filter((id) => !requested || requested.has(id));
  if (gapIds.length > 0) {
    await context.env.DB.batch(gapIds.map((gapId) => context.env.DB.prepare(
      `UPDATE ingredient_gaps SET status = 'pending', qa_attempts = qa_attempts + 1,
          research_work_item_id = NULL, updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'needs_operator'`,
    ).bind(gapId)));
  }
  const campaigns = await context.env.DB.prepare(
    `SELECT DISTINCT occurrence.request_id FROM ingredient_gap_occurrences occurrence
      WHERE occurrence.gap_id IN (SELECT id FROM ingredient_gaps WHERE qa_attempts > 0)`,
  ).all<{ request_id: string }>();
  for (const campaign of campaigns.results) await reconcileIngredientCampaign(context.env.DB, campaign.request_id);
  return context.json({ ok: true, retried: gapIds });
});

app.post("/internal/ingredient-pricing/waves", zValidator("json", ingredientPricingWaveCreateSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may create an ingredient pricing wave", 403);
  try {
    const result = await createPricingWave(context.env.DB, context.req.valid("json"));
    return context.json({ ok: true, ...result }, 201);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "ingredient pricing wave creation failed", 409);
  }
});

app.post("/internal/ingredient-pricing/proposals", zValidator("json", ingredientResolutionProposalSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may attach an ingredient proposal", 403);
  try { return context.json({ ok: true, ...await attachIngredientProposal(context.env.DB, context.req.valid("json")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient proposal failed", 409); }
});

app.post("/internal/ingredient-pricing/proposals/plan", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may queue ingredient definition planning", 403);
  try { return context.json({ ok: true, ...await enqueueIngredientDefinitionPlan(context.env.DB, 50) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient definition planning failed", 409); }
});

app.post("/internal/ingredient-pricing/checks/:id/reopen-correction", zValidator("json", ingredientStoreCheckReopenSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may reopen a terminal store check", 403);
  try { return context.json({ ok: true, ...await reopenTerminalStoreCheckForCorrection(context.env.DB, context.req.param("id"), context.req.valid("json")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "store-check correction failed", 409); }
});

app.post("/internal/ingredient-publication/batches", zValidator("json", ingredientPublicationBatchCreateSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may seal an ingredient publication batch", 403);
  try { return context.json({ ok: true, ...await createIngredientPublicationBatch(context.env.DB, context.req.valid("json")) }, 201); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient publication batch failed", 409); }
});

app.post("/internal/ingredient-publication/batches/:id/fail-predeployment", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may fail an ingredient publication batch", 403);
  try {
    const body = await context.req.json<{ detail?: unknown }>();
    return context.json({ ok: true, ...await failIngredientPublicationBatch(context.env.DB, context.req.param("id"), String(body.detail ?? "predeployment publication failure")) });
  } catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient publication failure transition failed", 409); }
});

app.post("/internal/ingredient-publication/batches/:id/materialize", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may materialize ingredient publication captures", 403);
  try { return context.json({ ok: true, ...await materializeIngredientPublicationCaptures(context.env.DB, context.req.param("id")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient publication materialization failed", 409); }
});

app.get("/internal/ingredient-publication/batches/:id/proof-plan", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may read an ingredient publication proof plan", 403);
  try { return context.json({ ok: true, ...await ingredientPublicationProofPlan(context.env, context.req.param("id")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient publication proof plan failed", 409); }
});

app.post("/internal/ingredient-publication/batches/:id/verify", zValidator("json", ingredientPublicationExternalVerifySchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may verify an ingredient publication", 403);
  try { return context.json({ ok: true, ...await verifyIngredientPublicationExternal(context.env, context.req.param("id"), context.req.valid("json")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient publication verification failed", 409); }
});

app.post("/internal/ingredient-publication/batches/:id/prepublish-verify", zValidator("json", ingredientPublicationVerifySchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may verify an ingredient publication candidate", 403);
  try { return context.json({ ok: true, ...await verifyIngredientPublicationCandidate(context.env, context.req.param("id"), context.req.valid("json").releaseId) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient prepublication verification failed", 409); }
});

app.post("/internal/ingredient-pricing/catalog/materialize", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may materialize the pricing catalog", 403);
  try {
    return context.json({ ok: true, ...await materializeHotCatalog(context.env.DB) });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "hot catalog materialization failed", 422);
  }
});

app.get("/internal/ingredient-pricing/waves/:id", async (context) => {
  const status = await pricingWaveStatus(context.env.DB, context.req.param("id"));
  return status ? context.json({ ok: true, wave: status }) : jsonError("ingredient pricing wave not found", 404);
});

app.get("/internal/ingredient-pricing/status", async (context) => context.json({ ok: true, status: await ingredientPipelineStatus(context.env.DB) }));
app.get("/internal/ingredient-pricing/progress", async (context) => context.json({ ok: true,
  progress: await ingredientCampaignProgress(context.env.DB, context.req.query("requestId")) }));
app.post("/internal/ingredient-pricing/reconcile", async (context) => context.json({ ok: true,
  ...await reconcileTerminalPricingJobs(context.env, 50) }));

app.get("/internal/ingredient-pricing/publication-ready", async (context) => {
  const rows = await context.env.DB.prepare(
    `SELECT job.gap_id, job.id AS pricing_job_id FROM ingredient_pricing_jobs job
      WHERE job.state = 'ready_to_publish' AND job.commodity_proposal_json IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM ingredient_publication_members member
          JOIN ingredient_publication_batches batch ON batch.id = member.batch_id
          WHERE member.gap_id = job.gap_id AND member.state != 'failed' AND batch.state != 'sealed'
        )
      ORDER BY job.updated_at, job.id LIMIT 50`,
  ).all();
  return context.json({ ok: true, gaps: rows.results });
});

app.post("/internal/ingredient-pricing/backfill", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may backfill ingredient pricing", 403);
  const rows = await context.env.DB.prepare(
    `SELECT gap.id FROM ingredient_gaps gap
      WHERE gap.status NOT IN ('published','permanently_unavailable')
        AND gap.qa_resolution IS NULL
        AND NOT EXISTS (SELECT 1 FROM ingredient_pricing_jobs job WHERE job.gap_id = gap.id AND job.market_id = 'omaha')
      ORDER BY gap.first_seen_at, gap.id LIMIT 200`,
  ).all<{ id: string }>();
  if (rows.results.length === 0) return context.json({ ok: true, backfilled: 0, waveId: null });
  const gapIds = rows.results.map((row) => row.id);
  const inputHash = await digestHex(stableJson({ kind: "ingredient-v2-backfill", gapIds }));
  const waveId = await deterministicId("pricing-wave-backfill", inputHash);
  const wave = await createPricingWave(context.env.DB, { id: waveId, campaignId: null, sourceKind: "backfill", gapIds,
    targetAvailable: gapIds.length, deadlineAt: null, inputHash });
  return context.json({ ok: true, backfilled: gapIds.length, ...wave });
});

app.get("/internal/pipeline/events", async (context) => {
  const after = Math.max(0, Number(context.req.query("after") ?? "0"));
  const limit = Math.min(200, Math.max(1, Number(context.req.query("limit") ?? "100")));
  if (!Number.isInteger(after) || !Number.isInteger(limit)) return jsonError("pipeline event cursor is invalid", 400);
  return context.json({ ok: true, ...await pipelineEvents(context.env.DB, after, limit) });
});

app.post("/internal/pipeline/outbox/claim", zValidator("json", pipelineOutboxClaimSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local coordinator may claim pipeline events", 403);
  try { return context.json({ ok: true, events: await claimPipelineOutbox(context.env.DB, context.req.valid("json")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "outbox claim failed", 409); }
});

app.post("/internal/pipeline/outbox/:id/ack", zValidator("json", pipelineOutboxAcknowledgeSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local coordinator may acknowledge pipeline events", 403);
  const id = Number(context.req.param("id"));
  if (!Number.isInteger(id) || id < 1) return jsonError("outbox id is invalid", 400);
  try { await acknowledgePipelineOutbox(context.env.DB, id, context.req.valid("json")); return context.json({ ok: true, id }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "outbox acknowledgement failed", 409); }
});

app.post("/internal/pipeline/outbox/:id/nack", zValidator("json", pipelineOutboxNackSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local coordinator may nack pipeline events", 403);
  const id = Number(context.req.param("id"));
  if (!Number.isInteger(id) || id < 1) return jsonError("outbox id is invalid", 400);
  try { await nackPipelineOutbox(context.env.DB, id, context.req.valid("json")); return context.json({ ok: true, id }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "outbox nack failed", 409); }
});

app.post("/internal/ingredient-pricing/store-checks/claim", zValidator("json", ingredientStoreCheckClaimSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local operator coordinator may claim store checks", 403);
  try {
    return context.json({ ok: true, checks: await claimStoreChecks(context.env.DB, context.req.valid("json")) });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "store-check claim failed", 409);
  }
});

app.post("/internal/ingredient-pricing/store-checks/:id/heartbeat", zValidator("json", ingredientStoreCheckHeartbeatSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local operator coordinator may renew store checks", 403);
  try {
    await heartbeatStoreCheck(context.env.DB, context.req.param("id"), context.req.valid("json"));
    return context.json({ ok: true, checkId: context.req.param("id") });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "store-check heartbeat failed", 409);
  }
});

app.post("/internal/ingredient-pricing/store-checks/:id/catalog-resolve", zValidator("json", ingredientStoreCheckHeartbeatSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local operator coordinator may resolve catalog checks", 403);
  try {
    return context.json({ ok: true, result: await resolveClaimedStoreCheckFromCatalog(context.env.DB, context.req.param("id"), context.req.valid("json")) });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "catalog resolution failed", 409);
  }
});

app.post("/internal/ingredient-pricing/store-checks/:id/complete", (context) =>
  jsonError("legacy direct completion is disabled; submit capture evidence and independent QA", 404));

app.post("/internal/ingredient-pricing/store-checks/:id/capture-result", zValidator("json", ingredientStoreCaptureResultSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local capture coordinator may submit store evidence", 403);
  try { return context.json({ ok: true, result: await completeIngredientStoreCapture(context.env, context.req.param("id"), context.req.valid("json")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "store capture completion failed", 409); }
});

app.post("/internal/ingredient-pricing/evidence", zValidator("json", ingredientEvidenceUploadSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local capture coordinator may upload ingredient evidence", 403);
  try { return context.json({ ok: true, evidence: await uploadIngredientEvidence(context.env, context.req.valid("json")) }, 201); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient evidence upload failed", 409); }
});

app.post("/internal/ingredient-pricing/store-checks/:id/qa-complete", zValidator("json", ingredientStoreQaCompleteSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the independent QA coordinator may complete store QA", 403);
  try { return context.json({ ok: true, aggregate: await completeIngredientStoreQa(context.env, context.req.param("id"), context.req.valid("json")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "store QA completion failed", 409); }
});
app.post("/internal/ingredient-pricing/store-checks/:id/qa-reject", zValidator("json", ingredientStoreQaRejectSchema), async (context) => {
  try { return context.json({ ok: true, result: await rejectIngredientStoreQa(context.env, context.req.param("id"), context.req.valid("json")) }); }
  catch (error) { return context.json({ ok: false, error: error instanceof Error ? error.message : String(error) }, 409); }
});

app.post("/internal/ingredient-pricing/store-checks/:id/challenge-open", zValidator("json", ingredientCaptureChallengeOpenSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the capture coordinator may open an ingredient challenge", 403);
  try { return context.json({ ok: true, ...await openIngredientChallenge(context.env.DB, context.req.param("id"), context.req.valid("json")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient challenge open failed", 409); }
});

app.post("/internal/ingredient-pricing/challenges/:id/acknowledge", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the capture callback may acknowledge an ingredient challenge", 403);
  try { return context.json({ ok: true, ...await acknowledgeIngredientChallenge(context.env.DB, context.req.param("id")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient challenge acknowledgement failed", 409); }
});

app.post("/internal/ingredient-pricing/challenges/:id/resolve", zValidator("json", ingredientCaptureChallengeResolveSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the capture coordinator may resolve an ingredient challenge", 403);
  try { return context.json({ ok: true, ...await resolveIngredientChallenge(context.env.DB, context.req.param("id"), context.req.valid("json")) }); }
  catch (error) { return jsonError(error instanceof Error ? error.message : "ingredient challenge resolution failed", 409); }
});

app.post("/internal/ingredient-pricing/store-checks/:id/catalog-qa", (context) =>
  jsonError("legacy catalog QA is disabled; use independent store QA", 404));

app.post("/internal/ingredient-pricing/store-checks/:id/fail", zValidator("json", ingredientStoreCheckFailSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only the local operator coordinator may fail store checks", 403);
  try {
    await failStoreCheck(context.env.DB, context.req.param("id"), context.req.valid("json"));
    return context.json({ ok: true, checkId: context.req.param("id") });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "store-check failure failed", 409);
  }
});

app.post("/internal/ingredient-gaps/:id/qa-not-found", zValidator("json", ingredientQaNotFoundSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may resolve ingredient store QA", 403);
  const gapId = context.req.param("id");
  const body = context.req.valid("json");
  const row = await context.env.DB.prepare(
    "SELECT status, qa_resolution, research_json FROM ingredient_gaps WHERE id = ?1",
  ).bind(gapId).first<{ status: string; qa_resolution: string | null; research_json: string | null }>();
  if (!row || !["needs_operator", "permanently_unavailable"].includes(row.status) || row.qa_resolution !== null || !row.research_json) {
    return jsonError("ingredient QA item is not open with durable research evidence", 409);
  }
  const prior = ingredientPriceResearchSchema.parse(JSON.parse(row.research_json));
  const target = prior.stores.find((store) => store.storeLocationId === body.storeLocationId);
  if (!target || !["blocked", "ambiguous", "not_found"].includes(target.outcome)) {
    return jsonError("store QA may only replace a blocked, ambiguous, or previously resolved not-found check", 409);
  }
  const checkedAt = new Date().toISOString();
  const stores = prior.stores.map((store) => store.storeLocationId === body.storeLocationId ? {
    ...store,
    outcome: "not_found" as const,
    checkedAt,
    sourceUrl: body.sourceUrl,
    evidenceSummary: body.evidenceSummary,
    searchComplete: true,
    qualifyingProductsExamined: 0,
    locationVerified: true,
    priceModeVerified: true,
    productName: null,
    packageText: null,
    packagePriceMinor: null,
    normalizedBasisQtyMicros: null,
    normalizedBasisUnit: null,
    perUnitMicros: null,
    validFrom: null,
    validTo: null,
    availabilityText: null,
    offerKind: null,
    fulfillmentMode: null,
    sellerName: null,
    loyaltyRequired: false,
    membershipRequired: false,
  } : store);
  const allResolved = stores.every((store) => store.outcome === "priced" || store.outcome === "not_found");
  const anyPriced = stores.some((store) => store.outcome === "priced");
  const allNotFound = stores.every((store) => store.outcome === "not_found");
  if (anyPriced && !prior.commodityProposal) return jsonError("priced ingredient QA is missing its commodity proposal", 409);
  const disposition = anyPriced ? "available" : allNotFound ? "permanently_unavailable" : "needs_operator";
  const research = ingredientPriceResearchSchema.parse({
    ...prior,
    researchedAt: checkedAt,
    stores,
    disposition,
    commodityProposal: anyPriced ? prior.commodityProposal : null,
    summary: allNotFound
      ? `Operator-assisted first-party QA completed the final blocked store check. All seven Omaha stores now have completed location-bound searches with no qualifying in-stock ${prior.ingredientName} product.`
      : allResolved
        ? `Operator-assisted first-party QA completed all seven Omaha store checks for ${prior.ingredientName}; verified prices and completed not-found outcomes are ready for publication.`
        : `Operator-assisted first-party QA resolved ${body.storeLocationId} as not found; another blocked or ambiguous Omaha store check still requires review.`,
  });
  const nextStatus = allNotFound ? "permanently_unavailable" : allResolved && anyPriced ? "ready_to_publish" : "needs_operator";
  const update = await context.env.DB.prepare(
    `UPDATE ingredient_gaps SET status = ?2, commodity_id = ?3, research_json = ?4, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND status IN ('needs_operator', 'permanently_unavailable') AND qa_resolution IS NULL`,
  ).bind(gapId, nextStatus, research.commodityProposal?.id ?? null, JSON.stringify(research)).run();
  if ((update.meta.changes ?? 0) !== 1) return jsonError("ingredient QA item changed during resolution", 409);
  const campaigns = await context.env.DB.prepare(
    "SELECT DISTINCT request_id FROM ingredient_gap_occurrences WHERE gap_id = ?1",
  ).bind(gapId).all<{ request_id: string }>();
  for (const campaign of campaigns.results) await reconcileIngredientCampaign(context.env.DB, campaign.request_id);
  await reconcileIngredientHolds(context.env.DB);
  return context.json({ ok: true, gapId, storeLocationId: body.storeLocationId, disposition: research.disposition });
});

app.post("/internal/ingredient-gaps/:id/qa-priced", zValidator("json", ingredientQaPricedSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may resolve ingredient store QA", 403);
  const gapId = context.req.param("id");
  const body = context.req.valid("json");
  const row = await context.env.DB.prepare(
    "SELECT status, qa_resolution, research_json FROM ingredient_gaps WHERE id = ?1",
  ).bind(gapId).first<{ status: string; qa_resolution: string | null; research_json: string | null }>();
  if (!row || row.status !== "needs_operator" || row.qa_resolution !== null || !row.research_json) {
    return jsonError("ingredient QA item is not open with durable research evidence", 409);
  }
  const prior = ingredientPriceResearchSchema.parse(JSON.parse(row.research_json));
  const target = prior.stores.find((store) => store.storeLocationId === body.store.storeLocationId);
  if (!target || !["blocked", "ambiguous", "not_found", "priced"].includes(target.outcome)) {
    return jsonError("store QA target is not replaceable", 409);
  }
  const commodityProposal = prior.commodityProposal ?? body.commodityProposal ?? null;
  if (!commodityProposal) return jsonError("the first verified price requires a commodity proposal", 422);
  const stores = prior.stores.map((store) => store.storeLocationId === body.store.storeLocationId ? body.store : store);
  const allResolved = stores.every((store) => store.outcome === "priced" || store.outcome === "not_found");
  const research = ingredientPriceResearchSchema.parse({
    ...prior,
    researchedAt: body.store.checkedAt,
    stores,
    disposition: allResolved ? "available" : "needs_operator",
    commodityProposal,
    summary: allResolved
      ? `Operator-assisted first-party QA completed all seven Omaha store checks for ${prior.ingredientName}; verified prices and completed not-found outcomes are ready for publication.`
      : `Operator-assisted first-party QA recorded a verified ${body.store.storeLocationId} price for ${prior.ingredientName}; another blocked or ambiguous Omaha store check still requires review.`,
  });
  const update = await context.env.DB.prepare(
    `UPDATE ingredient_gaps SET status = ?2, commodity_id = ?3, research_json = ?4, publication_error = NULL, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND status = 'needs_operator' AND qa_resolution IS NULL`,
  ).bind(gapId, allResolved ? "ready_to_publish" : "needs_operator", commodityProposal.id, JSON.stringify(research)).run();
  if ((update.meta.changes ?? 0) !== 1) return jsonError("ingredient QA item changed during resolution", 409);
  const campaigns = await context.env.DB.prepare(
    "SELECT DISTINCT request_id FROM ingredient_gap_occurrences WHERE gap_id = ?1",
  ).bind(gapId).all<{ request_id: string }>();
  for (const campaign of campaigns.results) await reconcileIngredientCampaign(context.env.DB, campaign.request_id);
  await reconcileIngredientHolds(context.env.DB);
  return context.json({ ok: true, gapId, storeLocationId: body.store.storeLocationId, status: allResolved ? "ready_to_publish" : "needs_operator" });
});

app.post("/internal/ingredient-gaps/:id/qa-resolution", zValidator("json", ingredientQaResolutionSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may resolve ingredient QA", 403);
  const gapId = context.req.param("id");
  const body = context.req.valid("json");
  if (body.commodityId) {
    const active = await context.env.DB.prepare(
      `SELECT commodity.id FROM commodities commodity
        JOIN configuration_versions version ON version.id = commodity.configuration_id
       WHERE version.active = 1 AND commodity.active = 1 AND commodity.id = ?1 LIMIT 1`,
    ).bind(body.commodityId).first();
    if (!active) return jsonError("QA alias target is not an active commodity", 422);
  }
  const update = await context.env.DB.prepare(
    `UPDATE ingredient_gaps SET qa_resolution = ?2, qa_resolution_commodity_id = ?3,
        qa_resolved_at = CURRENT_TIMESTAMP, publication_error = ?4, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND status = 'needs_operator' AND qa_resolution IS NULL`,
  ).bind(gapId, body.resolution, body.commodityId, body.reason).run();
  if ((update.meta.changes ?? 0) !== 1) return jsonError("ingredient QA item is not open", 409);
  await context.env.DB.prepare(
    `UPDATE ingredient_pricing_jobs SET state = 'failed', updated_at = CURRENT_TIMESTAMP
      WHERE gap_id = ?1 AND state NOT IN ('public_verified','permanently_unavailable','failed')`,
  ).bind(gapId).run();
  await reconcileIngredientHolds(context.env.DB);
  return context.json({ ok: true, gapId, resolution: body.resolution, commodityId: body.commodityId });
});

app.post("/internal/ingredient-gaps/:id/publication-failure", zValidator("json", ingredientPublicationFailureSchema), async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may record ingredient publication failure", 403);
  const gapId = context.req.param("id");
  const body = context.req.valid("json");
  const update = await context.env.DB.prepare(
    `UPDATE ingredient_gaps SET publication_attempts = publication_attempts + 1, publication_error = ?2,
       status = CASE WHEN ?3 = 1 THEN 'needs_operator' ELSE status END, updated_at = CURRENT_TIMESTAMP
     WHERE id = ?1 AND status = 'ready_to_publish'`,
  ).bind(gapId, body.error, body.requiresJudgment ? 1 : 0).run();
  if ((update.meta.changes ?? 0) !== 1) return jsonError("ingredient is not awaiting publication", 409);
  if (body.requiresJudgment) {
    const campaigns = await context.env.DB.prepare(
      "SELECT DISTINCT request_id FROM ingredient_gap_occurrences WHERE gap_id = ?1",
    ).bind(gapId).all<{ request_id: string }>();
    for (const campaign of campaigns.results) await reconcileIngredientCampaign(context.env.DB, campaign.request_id);
  }
  return context.json({ ok: true, gapId, requiresJudgment: body.requiresJudgment });
});

app.post("/internal/ingredient-gaps/:id/publication-retry", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may retry ingredient publication", 403);
  const gapId = context.req.param("id");
  const update = await context.env.DB.prepare(
    `UPDATE ingredient_gaps SET status = 'ready_to_publish', publication_error = NULL, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND status = 'needs_operator' AND qa_resolution IS NULL AND publication_attempts > 0
        AND json_extract(research_json, '$.disposition') = 'available'`,
  ).bind(gapId).run();
  if ((update.meta.changes ?? 0) !== 1) return jsonError("ingredient publication QA item is not retryable", 409);
  const campaigns = await context.env.DB.prepare(
    "SELECT DISTINCT request_id FROM ingredient_gap_occurrences WHERE gap_id = ?1",
  ).bind(gapId).all<{ request_id: string }>();
  for (const campaign of campaigns.results) await reconcileIngredientCampaign(context.env.DB, campaign.request_id);
  return context.json({ ok: true, gapId, status: "ready_to_publish" });
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
    context.env.DB.prepare("INSERT INTO release_cells (release_id, commodity_id, store_location_id, observation_id, status, is_crown, display_per_unit_micros, display_unit, reason_json, reason_hash) SELECT ?1, commodity_id, store_location_id, observation_id, status, is_crown, display_per_unit_micros, display_unit, reason_json, reason_hash FROM release_cells WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_recipe_costs SELECT ?1, recipe_slug, status, batch_cost_minor, serving_cost_minor, servings, missing_ingredients_json, detail_json FROM release_recipe_costs WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_top5 SELECT ?1, protein, rank, recipe_slug, serving_cost_minor FROM release_top5 WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_free_rotation SELECT ?1, recipe_slug, intended_visibility, protein, rank FROM release_free_rotation WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("INSERT INTO release_feed_entries SELECT ?1, entry_key, ordinal, payload_json FROM release_feed_entries WHERE release_id = ?2").bind(correctiveId, source.id),
    context.env.DB.prepare("UPDATE recipe_wave_runs SET corrective_release_id = ?2, status = 'corrective_draft', updated_at = CURRENT_TIMESTAMP WHERE id = ?1").bind(wave.id, correctiveId),
  ];
  await context.env.DB.batch(statements);
  const sourcePayloads = await context.env.DB.prepare(
    "SELECT kind, payload_json, content_hash, object_key, byte_length FROM release_payloads WHERE release_id = ?1 ORDER BY kind",
  ).bind(source.id).all<{ kind: string; payload_json: string; content_hash: string; object_key: string | null; byte_length: number | null }>();
  for (const payload of sourcePayloads.results) {
    const bytes = payload.object_key
      ? await context.env.EVIDENCE.get(payload.object_key).then((object) => object?.arrayBuffer()).then((value) => value ? new Uint8Array(value) : null)
      : new TextEncoder().encode(payload.payload_json);
    if (!bytes) return jsonError(`corrective source payload ${payload.kind} is unavailable`, 409);
    const objectKey = `releases/${correctiveId}/${payload.kind}-${payload.content_hash}.json`;
    await context.env.EVIDENCE.put(objectKey, bytes, { httpMetadata: { contentType: "application/json; charset=utf-8" }, customMetadata: { sha256: payload.content_hash, kind: payload.kind, releaseId: correctiveId } });
    await context.env.DB.prepare(
      "INSERT INTO release_payloads (release_id, kind, payload_json, content_hash, object_key, byte_length) VALUES (?1, ?2, '{}', ?3, ?4, ?5)",
    ).bind(correctiveId, payload.kind, payload.content_hash, objectKey, bytes.byteLength).run();
  }
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
  const observedAt = context.req.query("observedAt");
  if (observedAt && !Number.isFinite(Date.parse(observedAt))) return jsonError("engine snapshot observedAt must be an ISO timestamp", 422);
  try {
    return context.json(await readEngineSnapshot(context.env, requested as EngineSourceMode, requestedProfile as EngineSnapshotProfile, observedAt));
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "engine snapshot failed", 422);
  }
});

app.put("/internal/promotions/calendars/sync", zValidator("json", promotionCalendarSyncSchema), async (context) => {
  const body = context.req.valid("json");
  const statements = body.calendars.map((calendar) => context.env.DB.prepare(
    `INSERT INTO retailer_ad_calendars
       (store_location_id, store_name, capture_lane, expected_start_weekday, current_valid_from,
        current_valid_to, detected_at, source_evidence_json, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, CURRENT_TIMESTAMP)
     ON CONFLICT(store_location_id) DO UPDATE SET
       store_name = excluded.store_name, capture_lane = excluded.capture_lane,
       expected_start_weekday = excluded.expected_start_weekday,
       current_valid_from = excluded.current_valid_from, current_valid_to = excluded.current_valid_to,
       detected_at = excluded.detected_at, source_evidence_json = excluded.source_evidence_json,
       updated_at = CURRENT_TIMESTAMP`,
  ).bind(calendar.storeLocationId, calendar.storeName, calendar.captureLane, calendar.expectedStartWeekday,
    calendar.validFrom, calendar.validTo, body.observedAt, stableJson(calendar.evidence)));
  await context.env.DB.batch(statements);
  await recordAudit(context.env, context.get("identity"), "promotion_calendars.sync", "promotion_calendar", "omaha", "accepted", {
    observedAt: body.observedAt, calendars: body.calendars.map((item) => [item.storeLocationId, item.validFrom, item.validTo]),
  });
  return context.json({ ok: true, calendars: statements.length });
});

app.get("/internal/promotions/status", async (context) => {
  const [calendars, due, latest] = await Promise.all([
    context.env.DB.prepare("SELECT * FROM retailer_ad_calendars ORDER BY store_location_id").all(),
    context.env.DB.prepare("SELECT * FROM promotion_capture_requests WHERE status IN ('queued','leased','failed') ORDER BY due_at, store_location_id LIMIT 100").all(),
    context.env.DB.prepare("SELECT * FROM promotion_boundary_runs ORDER BY observed_at DESC LIMIT 1").first(),
  ]);
  return context.json({ ok: true, calendars: calendars.results, requests: due.results, latest });
});

app.post("/internal/promotions/reconcile", async (context) => {
  const result = await runPromotionLifecycle(context.env, Date.now());
  await recordAudit(context.env, context.get("identity"), "promotion_lifecycle.reconcile", "promotion_boundary_run", result.runId, "accepted", result);
  return context.json({ ok: true, ...result });
});

app.get("/internal/promotions/requests/due", async (context) => {
  const lane = context.req.query("lane");
  if (lane && lane !== "headless" && lane !== "browser") return jsonError("promotion lane must be headless or browser", 422);
  const rows = await context.env.DB.prepare(
    `SELECT request.id, request.store_location_id, calendar.store_name, request.request_kind,
            request.capture_lane, request.window_valid_from, request.window_valid_to, request.due_at,
            request.status, request.attempts
       FROM promotion_capture_requests request
       JOIN retailer_ad_calendars calendar ON calendar.store_location_id = request.store_location_id
      WHERE request.status IN ('queued','failed') AND julianday(request.due_at) <= julianday('now', '+15 minutes')
        AND (?1 IS NULL OR request.capture_lane = ?1)
      ORDER BY request.due_at, request.store_location_id LIMIT 20`,
  ).bind(lane ?? null).all();
  return context.json({ ok: true, requests: rows.results });
});

app.post("/internal/promotions/requests/claim", zValidator("json", promotionRequestClaimSchema), async (context) => {
  const body = context.req.valid("json");
  const leaseExpiresAt = new Date(Date.parse(body.observedAt) + body.leaseMinutes * 60_000).toISOString();
  const candidates = await context.env.DB.prepare(
    `SELECT id FROM promotion_capture_requests
      WHERE capture_lane = ?1
        AND (status IN ('queued','failed') OR (status = 'leased' AND lease_expires_at <= ?2))
        AND julianday(due_at) <= julianday(?2, '+15 minutes')
      ORDER BY due_at, store_location_id LIMIT ?3`,
  ).bind(body.lane, body.observedAt, body.limit).all<{ id: string }>();
  const claimed: string[] = [];
  for (const row of candidates.results) {
    const updated = await context.env.DB.prepare(
      `UPDATE promotion_capture_requests
          SET status = 'leased', lease_owner = ?2, lease_expires_at = ?3, updated_at = ?4
        WHERE id = ?1 AND (status IN ('queued','failed') OR (status = 'leased' AND lease_expires_at <= ?4))`,
    ).bind(row.id, body.owner, leaseExpiresAt, body.observedAt).run();
    if ((updated.meta.changes ?? 0) > 0) claimed.push(row.id);
  }
  if (claimed.length === 0) return context.json({ ok: true, requests: [], leaseExpiresAt });
  const placeholders = claimed.map((_, index) => `?${index + 1}`).join(",");
  const requests = await context.env.DB.prepare(
    `SELECT request.id, request.store_location_id, calendar.store_name, request.request_kind,
            request.capture_lane, request.window_valid_from, request.window_valid_to, request.due_at,
            request.status, request.attempts, request.lease_owner, request.lease_expires_at
       FROM promotion_capture_requests request
       JOIN retailer_ad_calendars calendar ON calendar.store_location_id = request.store_location_id
      WHERE request.id IN (${placeholders}) ORDER BY request.due_at, request.store_location_id`,
  ).bind(...claimed).all();
  return context.json({ ok: true, requests: requests.results, leaseExpiresAt });
});

app.post("/internal/promotions/requests/complete", zValidator("json", promotionRequestCompleteSchema), async (context) => {
  const body = context.req.valid("json");
  const statements = body.requestIds.map((id) => context.env.DB.prepare(
    `UPDATE promotion_capture_requests
        SET status = ?2, attempts = attempts + 1, result_json = ?3, last_error = ?4,
            completed_at = CASE WHEN ?2 = 'completed' THEN ?5 ELSE NULL END, updated_at = ?5,
            lease_owner = NULL, lease_expires_at = NULL
      WHERE id = ?1 AND status IN ('queued','leased','failed')`,
  ).bind(id, body.status, stableJson(body.result), body.error ?? null, body.completedAt));
  await context.env.DB.batch(statements);
  await recordAudit(context.env, context.get("identity"), "promotion_requests.complete", "promotion_request", body.requestIds.join(","), body.status === "completed" ? "accepted" : "failed", body);
  return context.json({ ok: body.status === "completed", requests: body.requestIds.length, status: body.status });
});

app.get("/internal/engine/snapshot-manifest", async (context) => {
  const requested = context.req.query("mode") ?? "direct";
  if (!(["legacy", "direct", "all"] as const).includes(requested as EngineSourceMode)) return jsonError("engine mode must be legacy, direct, or all", 422);
  const observedAt = context.req.query("observedAt");
  if (observedAt && !Number.isFinite(Date.parse(observedAt))) return jsonError("engine snapshot observedAt must be an ISO timestamp", 422);
  try {
    return context.json(await readEngineSnapshotManifest(context.env, requested as EngineSourceMode, observedAt));
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "engine snapshot manifest failed", 422);
  }
});

app.post("/internal/engine/snapshot-shards/:batchId/build", async (context) => {
  const requested = context.req.query("mode") ?? "direct";
  if (!(["legacy", "direct", "all"] as const).includes(requested as EngineSourceMode)) return jsonError("engine mode must be legacy, direct, or all", 422);
  const observedAt = context.req.query("observedAt");
  if (observedAt && !Number.isFinite(Date.parse(observedAt))) return jsonError("engine snapshot observedAt must be an ISO timestamp", 422);
  try {
    const result = await buildEngineSnapshotShard(context.env, context.req.param("batchId"), requested as EngineSourceMode, observedAt);
    await recordAudit(context.env, context.get("identity"), "engine_snapshot_shard.build", "capture_batch", context.req.param("batchId"), "accepted", {
      mode: requested, idempotent: result.idempotent, contentHash: result.shard.content_hash, byteLength: result.shard.byte_length,
    });
    return context.json(result);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "engine snapshot shard build failed", 422);
  }
});

app.get("/internal/engine/snapshot-shards/:batchId", async (context) => {
  const configurationId = context.req.query("configurationId");
  const matchRunId = context.req.query("matchRunId");
  if (!configurationId || !matchRunId) return jsonError("configurationId and matchRunId are required", 422);
  try {
    return context.json(await readEngineSnapshotShard(context.env, context.req.param("batchId"), configurationId, matchRunId));
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "engine snapshot shard read failed", 422);
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
  // A workflow can fail before it creates its job_run. Include an entropy
  // suffix so the next forced drill never reuses Cloudflare's immutable
  // instance id in that case.
  const instanceId = `d1-restore-${quarter}-a${(attempts?.count ?? 0) + 1}-${crypto.randomUUID().slice(0, 8)}`;
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
  const schedule = await context.env.DB.prepare("SELECT job, lease_minutes FROM job_schedules WHERE job = ?1 AND active = 1").bind(body.job).first<{ job: string; lease_minutes: number }>();
  if (!schedule) return jsonError("unknown or inactive job", 404);
  const existing = await context.env.DB.prepare("SELECT job, status, lease_resource, lease_fence FROM job_runs WHERE id = ?1").bind(body.id).first<{ job: string; status: string; lease_resource: string | null; lease_fence: number | null }>();
  if (existing) {
    if (existing.job !== body.job) return jsonError("job run id belongs to another job", 409);
    const lease = existing.lease_resource && existing.lease_fence
      ? await context.env.DB.prepare("SELECT resource, holder_id AS holderId, owner_kind AS ownerKind, fence, acquired_at AS acquiredAt, heartbeat_at AS heartbeatAt, expires_at AS expiresAt FROM operation_leases WHERE resource = ?1 AND holder_id = ?2 AND fence = ?3 AND released_at IS NULL")
        .bind(existing.lease_resource, body.id, existing.lease_fence).first()
      : null;
    return context.json({ ok: true, runId: body.id, status: existing.status, lease, idempotent: true });
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
  const leaseResource = `job:${body.job}`;
  const lease = status === "started" ? await acquireOperationLease(context.env.DB, {
    resource: leaseResource,
    holderId: body.id,
    ownerKind: "job",
    leaseMinutes: schedule.lease_minutes,
    metadata: { job: body.job, actorId: identity.agentId, deploymentSafe: false },
  }) : null;
  if (status === "started" && !lease) {
    const active = await context.env.DB.prepare(
      "SELECT holder_id, fence, acquired_at, heartbeat_at, expires_at FROM operation_leases WHERE resource = ?1 AND released_at IS NULL",
    ).bind(leaseResource).first();
    return context.json({ ok: false, error: "job already has an active execution", job: body.job, resource: leaseResource, active }, 409);
  }
  const insertRun = context.env.DB.prepare(
    `INSERT INTO job_runs
       (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, input_json,
        executor_run_id, actor_id, prompt_hash, input_hash, model_id, agent_id, ledger_mode,
        mutation_authorized, estimated_cost_microusd, budget_class, lease_resource, lease_fence)
     VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)`,
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
    lease?.resource ?? null,
    lease?.fence ?? null,
  );
  try {
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
  } catch (error) {
    if (lease) await releaseOperationLease(context.env.DB, lease.resource, body.id, lease.fence);
    throw error;
  }
  return context.json({ ok: true, runId: body.id, status, lease, idempotent: false }, 201);
});

app.patch("/internal/job-runs/:id", zValidator("json", jobRunUpdateSchema), async (context) => {
  const body = context.req.valid("json");
  const current = await context.env.DB.prepare("SELECT job, status, started_at, finished_at, trigger_kind, executor_run_id, agent_id, estimated_cost_microusd, budget_class, lease_resource, lease_fence FROM job_runs WHERE id = ?1").bind(context.req.param("id")).first<{
    job: string; status: string; started_at: string | null; finished_at: string | null; trigger_kind: string; executor_run_id: string | null; agent_id: string | null; estimated_cost_microusd: number; budget_class: "routine" | "reserve" | null; lease_resource: string | null; lease_fence: number | null;
  }>();
  if (!current) return jsonError("job run not found", 404);
  const updateIdentity = context.get("identity");
  if (updateIdentity.registeredAgentId && current.agent_id !== updateIdentity.registeredAgentId) return jsonError("registered agent may only update its own job run", 403);
  if (current.status === body.status && current.finished_at === (body.finishedAt ?? null)) {
    if (current.lease_resource && current.lease_fence) {
      await releaseOperationLease(context.env.DB, current.lease_resource, context.req.param("id"), current.lease_fence, body.finishedAt ?? new Date().toISOString());
    }
    return context.json({ ok: true, runId: context.req.param("id"), status: current.status, idempotent: true });
  }
  const allowed: Record<string, string[]> = {
    scheduled: ["started", "missed", "cancelled"],
    started: ["completed", "failed", "timed_out", "cancelled"],
  };
  if (!allowed[current.status]?.includes(body.status)) return jsonError(`invalid job transition ${current.status} -> ${body.status}`, 409);
  const startedAt = body.startedAt ?? current.started_at;
  if (body.status !== "missed" && !startedAt) return jsonError("startedAt is required once a job starts", 422);
  let startedLease: Awaited<ReturnType<typeof acquireOperationLease>> = null;
  if (current.status === "scheduled" && body.status === "started") {
    const policy = await context.env.DB.prepare("SELECT lease_minutes FROM job_schedules WHERE job = ?1").bind(current.job).first<{ lease_minutes: number }>();
    startedLease = await acquireOperationLease(context.env.DB, {
      resource: `job:${current.job}`, holderId: context.req.param("id"), ownerKind: "job", leaseMinutes: policy?.lease_minutes ?? 180,
      metadata: { job: current.job, actorId: updateIdentity.agentId, deploymentSafe: false },
    });
    if (!startedLease) return jsonError("job already has an active execution", 409);
  }
  await context.env.DB.prepare(
    `UPDATE job_runs SET status = ?2, started_at = ?3, heartbeat_at = ?4, finished_at = ?5,
       output_hash = ?6, input_tokens = ?7, output_tokens = ?8, cache_read_tokens = ?9,
       cache_write_tokens = ?10, cost_microusd = ?11, stats_json = ?12, error = ?13,
       lease_resource = COALESCE(lease_resource, ?14), lease_fence = COALESCE(lease_fence, ?15)
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
    startedLease?.resource ?? null,
    startedLease?.fence ?? null,
  ).run();
  if (["completed", "failed", "missed", "timed_out", "cancelled"].includes(body.status)) {
    const resource = current.lease_resource ?? startedLease?.resource;
    const fence = current.lease_fence ?? startedLease?.fence;
    if (resource && fence) await releaseOperationLease(context.env.DB, resource, context.req.param("id"), fence, body.finishedAt ?? new Date().toISOString());
  }
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
  const parsedItems = rows.results.map((row) => contentItemSchema.safeParse(JSON.parse(row.content_json)));
  const invalidItem = parsedItems.find((result) => !result.success);
  if (invalidItem && !invalidItem.success) {
    const contentHash = await digestHex(stableJson(rows.results.map((row) => JSON.parse(row.content_json))));
    const findings = [{ key: "legacy-incomplete-meal-contract", severity: "hard" as const, message: "recipe batch predates the V2 complete-meal contract or fails its component requirements" }];
    await context.env.DB.prepare("UPDATE content_batches SET status = 'rejected', content_hash = ?2 WHERE id = ?1").bind(batchId, contentHash).run();
    await recordAudit(context.env, context.get("identity"), "content_batch.promote", "content_batch", batchId, "rejected", { findings, issues: invalidItem.error.issues });
    return context.json({ ok: false, batchId, status: "rejected", guardVersion: "recipe-content-v2", findings }, 422);
  }
  const items = parsedItems.flatMap((result) => result.success ? [result.data] : []);
  const commodities = await context.env.DB.prepare(
    `SELECT c.id FROM commodities c JOIN configuration_versions v ON v.id = c.configuration_id WHERE v.active = 1`,
  ).all<{ id: string }>();
  const guard = await evaluateContentPromotion(items, recipeCommodityIds(commodities.results));
  if (!guard.ok) {
    await context.env.DB.prepare("UPDATE content_batches SET status = 'rejected', content_hash = ?2 WHERE id = ?1").bind(batchId, guard.contentHash).run();
    await recordAudit(context.env, context.get("identity"), "content_batch.promote", "content_batch", batchId, "rejected", { findings: guard.findings });
    return context.json({ ok: false, batchId, status: "rejected", guardVersion: "recipe-content-v2", findings: guard.findings }, 422);
  }
  const promotionId = await deterministicId("content-promotion", batchId, guard.contentHash);
  await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT INTO content_promotions
         (id, batch_id, promoted_by, deterministic_guard_version, content_hash, detail_json)
       VALUES (?1, ?2, ?3, 'recipe-content-v2', ?4, ?5)`,
    ).bind(promotionId, batchId, context.get("identity").agentId, guard.contentHash, stableJson({ findings: guard.findings })),
    context.env.DB.prepare("UPDATE content_batches SET status = 'promoted', promoted_at = CURRENT_TIMESTAMP, content_hash = ?2 WHERE id = ?1")
      .bind(batchId, guard.contentHash),
  ]);
  await recordAudit(context.env, context.get("identity"), "content_batch.promote", "content_batch", batchId, "accepted", { promotionId, contentHash: guard.contentHash });
  return context.json({ ok: true, batchId, status: "promoted", promotionId, guardVersion: "recipe-content-v2", contentHash: guard.contentHash, warnings: guard.findings }, 201);
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
  await runArchivalForecast(context.env, observedAt, true);
  await recordAudit(context.env, context.get("identity"), "archival_forecast.run", "job", "archival-forecast-daily", "accepted", {
    observedAt: new Date(observedAt).toISOString(),
  });
  return context.json({ ok: true, job: "archival-forecast-daily", observedAt: new Date(observedAt).toISOString() });
});

app.post("/internal/archival/plan", zValidator("json", archivePlanSchema), async (context) => {
  const body = context.req.valid("json");
  const minimumCutoff = Date.now() - 24 * 60 * 60 * 1000;
  if (Date.parse(body.cutoffAt) > minimumCutoff) return jsonError("archive cutoff must retain a 24 hour ingestion safety window", 422);
  const forecast = await context.env.DB.prepare("SELECT status, usage_percent_millis FROM archival_forecasts ORDER BY observed_at DESC LIMIT 1")
    .first<{ status: string; usage_percent_millis: number }>();
  const [ids, protection] = await Promise.all([
    readRetentionCandidates(context.env.DB, body.cutoffAt, body.maximumRows),
    readRetentionProtectionSummary(context.env.DB, body.cutoffAt),
  ]);
  const protectedRefsHash = await digestHex(stableJson({ cutoffAt: body.cutoffAt, protection }));
  const result = { cutoffAt: body.cutoffAt, candidates: ids.length, ...protection, protectedRefsHash, forecast: forecast ?? null };
  if (body.dryRun) return context.json({ ok: true, dryRun: true, ...result });
  if (!ids.length) return jsonError("archive plan has no eligible observations", 422);
  const manifestId = await deterministicId("archive-manifest", body.cutoffAt, protectedRefsHash, ...ids);
  const statements: D1PreparedStatement[] = [context.env.DB.prepare(
    `INSERT INTO archive_manifests (id, cutoff_at, format, row_count, status, protected_refs_hash, detail_json)
     VALUES (?1, ?2, 'parquet', ?3, 'planned', ?4, ?5)`,
  ).bind(manifestId, body.cutoffAt, ids.length, protectedRefsHash, stableJson({
    forecast, safetyWindowHours: 24, selection: "dependency-aware-v2", protection: protection.byReason,
    storageAuthority: "r2-parquet",
  }))];
  for (let offset = 0; offset < ids.length; offset += 500) statements.push(context.env.DB.prepare(
    `INSERT INTO archive_manifest_observations (manifest_id, observation_id)
     SELECT ?1, value FROM json_each(?2)`,
  ).bind(manifestId, stableJson(ids.slice(offset, offset + 500))));
  await context.env.DB.batch(statements);
  return context.json({ ok: true, dryRun: false, manifestId, ...result }, 201);
});

app.get("/internal/archival/:id/export", async (context) => {
  const manifest = await context.env.DB.prepare("SELECT id, status, cutoff_at, protected_refs_hash FROM archive_manifests WHERE id = ?1")
    .bind(context.req.param("id")).first<{ id: string; status: string; cutoff_at: string; protected_refs_hash: string }>();
  if (!manifest) return jsonError("archive manifest not found", 404);
  const rows = await context.env.DB.prepare(
    `SELECT o.*, pv.product_id, pv.name, pv.normalized_name, pv.size_text, pv.product_url,
            pv.image_url, pv.taxonomy_path, p.store_location_id, p.external_key, b.source_id,
            (SELECT json_group_array(json_object('batch_id', member.batch_id, 'term_key', member.term_key,
              'observed_at', member.observed_at, 'source_payload_key', member.source_payload_key,
              'evidence_object_id', member.evidence_object_id, 'provenance_json', json(member.provenance_json),
              'carried', member.carried)) FROM capture_observation_memberships member
              WHERE member.observation_id = o.id) AS memberships_json
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
  const partitionDate = new Date().toISOString().slice(0, 10);
  const objectKey = `observations/schema=1/store=multi/date=${partitionDate}/source=historical-backfill/${manifest.id}-${sha256}.parquet`;
  await context.env.ARCHIVE.put(objectKey, body, { httpMetadata: { contentType: "application/vnd.apache.parquet" }, customMetadata: { manifestId: manifest.id, sha256, rows: String(manifest.row_count) } });
  const stored = await context.env.ARCHIVE.head(objectKey);
  if (!stored || stored.size !== bytes.byteLength) return jsonError("archive object failed post-write size verification", 500);
  await context.env.DB.batch([
    context.env.DB.prepare(
      "UPDATE archive_manifests SET object_key = ?2, byte_length = ?3, sha256 = ?4, status = 'verified', verified_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(manifest.id, objectKey, stored.size, sha256),
    context.env.DB.prepare(
      `INSERT OR IGNORE INTO object_store_objects
         (content_hash, object_key, object_kind, format, byte_length, row_count, schema_version, verified_at)
       VALUES (?1, ?2, 'observation-partition', 'parquet', ?3, ?4, 1, CURRENT_TIMESTAMP)`,
    ).bind(sha256, objectKey, stored.size, manifest.row_count),
  ]);
  await recordAudit(context.env, context.get("identity"), "archive.verify", "archive_manifest", manifest.id, "accepted", { objectKey, byteLength: stored.size, sha256, rowCount: manifest.row_count });
  return context.json({ ok: true, manifestId: manifest.id, status: "verified", objectKey, byteLength: stored.size, sha256 });
});

app.post("/internal/engine/measurements", async (context) => {
  const body = await context.req.json<Record<string, unknown>>().catch(() => ({} as Record<string, unknown>));
  const releaseId = String(body.releaseId ?? "");
  const inputHash = String(body.inputHash ?? "");
  const encoding = String(body.encoding ?? "");
  const integers = ["matchedCandidates", "unmatchedCandidates", "responseBytes", "snapshotFetchMs", "nativeBuildMs", "publishMs", "totalMs"] as const;
  if (!releaseId || !/^[a-f0-9]{64}$/.test(inputHash) || !isEngineSnapshotEncoding(encoding)) {
    return jsonError("engine measurement identity is invalid", 422);
  }
  const values = Object.fromEntries(integers.map((key) => [key, Number(body[key])])) as Record<(typeof integers)[number], number>;
  if (integers.some((key) => !Number.isInteger(values[key]) || (values[key] ?? -1) < 0)) return jsonError("engine measurement values must be non-negative integers", 422);
  const release = await context.env.DB.prepare("SELECT id, input_hash FROM releases WHERE id = ?1").bind(releaseId).first<{ id: string; input_hash: string }>();
  if (!release || release.input_hash !== inputHash) return jsonError("engine measurement does not identify a persisted release", 409);
  const id = await deterministicId("engine-snapshot-measurement", releaseId, inputHash, String(values.totalMs));
  await context.env.DB.prepare(
    `INSERT OR IGNORE INTO engine_snapshot_measurements
       (id, input_hash, release_id, encoding, matched_candidates, unmatched_candidates, response_bytes,
        snapshot_fetch_ms, native_build_ms, publish_ms, total_ms, detail_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`,
  ).bind(id, inputHash, releaseId, encoding, values.matchedCandidates, values.unmatchedCandidates, values.responseBytes,
    values.snapshotFetchMs, values.nativeBuildMs, values.publishMs, values.totalMs,
    stableJson({ profile: "ordinary-incremental-release", source: "tc-engine-publish-native" })).run();
  return context.json({ ok: true, measurementId: id });
});

app.get("/internal/engine/measurements", async (context) => {
  const rows = await context.env.DB.prepare(
    "SELECT * FROM engine_snapshot_measurements ORDER BY measured_at DESC LIMIT 25",
  ).all();
  return context.json({ ok: true, measurements: rows.results });
});

app.get("/internal/engine/current-release-graph", async (context) => {
  const marketId = context.req.query("marketId") ?? "omaha";
  const afterKind = context.req.query("afterKind") ?? "";
  const afterKey = context.req.query("afterKey") ?? "";
  const current = await context.env.DB.prepare(
    `SELECT current.release_id, graph.dependency_hash
       FROM current_releases current LEFT JOIN release_graphs graph ON graph.release_id = current.release_id
      WHERE current.market_id = ?1`,
  ).bind(marketId).first<{ release_id: string; dependency_hash: string | null }>();
  if (!current) return jsonError("current release graph not found", 404);
  const rows = await context.env.DB.prepare(
    `SELECT node_kind, node_key, dependency_hash, content_hash, payload_json
       FROM release_graph_nodes
      WHERE release_id = ?1 AND node_kind IN ('cell', 'recipe')
        AND (?2 = '' OR node_kind > ?2 OR (node_kind = ?2 AND node_key > ?3))
      ORDER BY node_kind, node_key LIMIT 100`,
  ).bind(current.release_id, afterKind, afterKey).all<{
    node_kind: "cell" | "recipe"; node_key: string; dependency_hash: string; content_hash: string; payload_json: string;
  }>();
  const nodes = await Promise.all(rows.results.map(async (row) => {
    const payload = JSON.parse(row.payload_json) as unknown;
    if (await digestHex(stableJson(payload)) !== row.content_hash) throw new Error(`current release node cache is corrupt: ${row.node_key}`);
    return { kind: row.node_kind, key: row.node_key, dependencyHash: row.dependency_hash,
      contentHash: row.content_hash, payload };
  }));
  const last = rows.results.at(-1);
  return context.json({ ok: true, version: 1, parentReleaseId: current.release_id,
    dependencyHash: current.dependency_hash ?? "0".repeat(64), nodes,
    next: rows.results.length === 100 && last ? { kind: last.node_kind, key: last.node_key } : null });
});

app.post("/internal/archival/:id/execute", zValidator("json", canonicalCleanupExecuteSchema), async (context) => {
  const manifest = await context.env.DB.prepare(
    `SELECT id, status, cutoff_at, row_count, object_key, byte_length, sha256, protected_refs_hash, completed_at
       FROM archive_manifests WHERE id = ?1`,
  ).bind(context.req.param("id")).first<{
    id: string; status: string; cutoff_at: string; row_count: number; object_key: string | null;
    byte_length: number | null; sha256: string | null; protected_refs_hash: string; completed_at: string | null;
  }>();
  if (!manifest) return jsonError("archive manifest not found", 404);
  if (manifest.completed_at) return context.json({ ok: true, manifestId: manifest.id, status: "completed", idempotent: true });
  if (manifest.status !== "verified" || !manifest.object_key || manifest.sha256 !== context.req.valid("json").archiveSha256) {
    return jsonError("verified archive hash confirmation is required", 409);
  }
  const stored = await context.env.ARCHIVE.head(manifest.object_key);
  if (!stored || stored.size !== manifest.byte_length || stored.customMetadata?.sha256 !== manifest.sha256) {
    return jsonError("verified archive object is no longer intact", 409);
  }
  const protection = await readRetentionProtectionSummary(context.env.DB, manifest.cutoff_at);
  const protectedRefsHash = await digestHex(stableJson({ cutoffAt: manifest.cutoff_at, protection }));
  if (protectedRefsHash !== manifest.protected_refs_hash) return jsonError("release references changed after archive planning", 409);
  const archivedIds = await context.env.DB.prepare(
    "SELECT observation_id FROM archive_manifest_observations WHERE manifest_id = ?1 ORDER BY observation_id",
  ).bind(manifest.id).all<{ observation_id: string }>();
  try {
    await assertRetentionCandidatesStillUnprotected(context.env, manifest.cutoff_at, archivedIds.results.map((row) => row.observation_id));
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "archive candidates gained a protected dependency", 409);
  }
  const invalid = await context.env.DB.prepare(
    `SELECT COUNT(*) AS count FROM archive_manifest_observations archived
      WHERE archived.manifest_id = ?1 AND (
        NOT EXISTS(SELECT 1 FROM observations current WHERE current.id = archived.observation_id)
      )`,
  ).bind(manifest.id).first<{ count: number }>();
  if ((invalid?.count ?? 0) > 0) return jsonError("archive candidates gained a protected reference or are no longer present", 409);
  const expiresAt = new Date(Date.now() + 5 * 60_000).toISOString();
  await context.env.DB.batch([
    context.env.DB.prepare("INSERT OR REPLACE INTO maintenance_leases (kind, run_id, expires_at) VALUES ('verified-archive', ?1, ?2)").bind(manifest.id, expiresAt),
    context.env.DB.prepare("DELETE FROM capture_observation_memberships WHERE observation_id IN (SELECT observation_id FROM archive_manifest_observations WHERE manifest_id = ?1)").bind(manifest.id),
    context.env.DB.prepare("DELETE FROM observation_fingerprints WHERE observation_id IN (SELECT observation_id FROM archive_manifest_observations WHERE manifest_id = ?1)").bind(manifest.id),
    context.env.DB.prepare("DELETE FROM semantic_fact_canonicals WHERE observation_id IN (SELECT observation_id FROM archive_manifest_observations WHERE manifest_id = ?1)").bind(manifest.id),
    context.env.DB.prepare("DELETE FROM observations WHERE id IN (SELECT observation_id FROM archive_manifest_observations WHERE manifest_id = ?1)").bind(manifest.id),
    context.env.DB.prepare("DELETE FROM product_versions WHERE NOT EXISTS (SELECT 1 FROM observations o WHERE o.product_version_id = product_versions.id)"),
    context.env.DB.prepare("DELETE FROM maintenance_leases WHERE kind = 'verified-archive' AND run_id = ?1").bind(manifest.id),
    context.env.DB.prepare("UPDATE archive_manifests SET completed_at = CURRENT_TIMESTAMP WHERE id = ?1 AND completed_at IS NULL").bind(manifest.id),
  ]);
  await recordAudit(context.env, context.get("identity"), "archive.execute", "archive_manifest", manifest.id, "accepted", {
    rows: manifest.row_count, archive: manifest.object_key, sha256: manifest.sha256, cutoffAt: manifest.cutoff_at,
  });
  return context.json({ ok: true, manifestId: manifest.id, status: "completed", removedFacts: manifest.row_count, idempotent: false });
});

app.post("/internal/canonical-cleanup/index", async (context) => {
  const after = context.req.query("after") ?? "";
  const rows = await context.env.DB.prepare(
    `SELECT o.id, origin.source_id, pv.product_id, pv.name, pv.size_text, pv.product_url,
            pv.taxonomy_path, pv.identity_json, o.kind, o.currency, o.purchase_price_minor,
            o.regular_price_minor, o.purchase_quantity, o.package_count, o.captured_basis_unit,
            o.captured_basis_qty_micros, o.normalized_basis_unit, o.normalized_basis_qty_micros,
            o.per_unit_micros, o.basis_options_json, o.loyalty_required, o.membership_required,
            o.raw_price_text, o.raw_size_text, o.valid_from, o.valid_to, o.price_semantics_json,
            o.offer_snapshot_json
       FROM observations o
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN capture_batches origin ON origin.id = o.batch_id
       LEFT JOIN observation_fingerprints fingerprint ON fingerprint.observation_id = o.id
      WHERE fingerprint.observation_id IS NULL AND o.id > ?1
      ORDER BY o.id LIMIT 500`,
  ).bind(after).all<Record<string, unknown>>();
  const statements: D1PreparedStatement[] = [];
  for (const row of rows.results) {
    const identity = JSON.parse(String(row.identity_json ?? "{}")) as { brand?: string };
    const canonicalVersionHash = await digestHex(stableJson(semanticProductVersion({
      name: String(row.name), sizeText: String(row.size_text), productUrl: row.product_url ? String(row.product_url) : undefined,
      taxonomyPath: row.taxonomy_path ? String(row.taxonomy_path) : undefined, identity,
    })));
    const canonicalVersionId = await deterministicId("pver", String(row.product_id), canonicalVersionHash);
    const semantic = await semanticObservationId(String(row.source_id), canonicalVersionId, {
      kind: String(row.kind), currency: String(row.currency), purchasePriceMinor: Number(row.purchase_price_minor),
      ...(row.regular_price_minor === null ? {} : { regularPriceMinor: Number(row.regular_price_minor) }),
      purchaseQuantity: Number(row.purchase_quantity), packageCount: Number(row.package_count),
      capturedBasisUnit: String(row.captured_basis_unit), capturedBasisQtyMicros: Number(row.captured_basis_qty_micros),
      normalizedBasisUnit: String(row.normalized_basis_unit), normalizedBasisQtyMicros: Number(row.normalized_basis_qty_micros),
      perUnitMicros: Number(row.per_unit_micros), basisOptions: JSON.parse(String(row.basis_options_json)),
      loyaltyRequired: Number(row.loyalty_required) === 1, membershipRequired: Number(row.membership_required) === 1,
      rawPriceText: String(row.raw_price_text), rawSizeText: String(row.raw_size_text),
      ...(row.valid_from === null ? {} : { validFrom: String(row.valid_from) }),
      ...(row.valid_to === null ? {} : { validTo: String(row.valid_to) }),
      priceSemantics: JSON.parse(String(row.price_semantics_json)), offerSnapshot: JSON.parse(String(row.offer_snapshot_json)),
    });
    statements.push(context.env.DB.prepare(
      "INSERT OR IGNORE INTO observation_fingerprints (observation_id, semantic_hash) VALUES (?1, ?2)",
    ).bind(String(row.id), semantic.hash));
  }
  for (let offset = 0; offset < statements.length; offset += 90) await context.env.DB.batch(statements.slice(offset, offset + 90));
  return context.json({ ok: true, indexed: rows.results.length, nextCursor: rows.results.at(-1)?.id ?? after });
});

app.post("/internal/canonical-cleanup/canonicals", async (context) => {
  const after = context.req.query("after") ?? "";
  const groups = await context.env.DB.prepare(
    `SELECT semantic_hash FROM observation_fingerprints
      WHERE semantic_hash > ?1
      GROUP BY semantic_hash HAVING COUNT(*) > 1
      ORDER BY semantic_hash LIMIT 500`,
  ).bind(after).all<{ semantic_hash: string }>();
  if (!groups.results.length) return context.json({ ok: true, indexed: 0, nextCursor: after });
  const hashes = groups.results.map((row) => row.semantic_hash);
  const rows = await context.env.DB.prepare(
    `SELECT fingerprint.semantic_hash, o.id, o.captured_at,
            EXISTS(SELECT 1 FROM release_cells cell WHERE cell.observation_id = o.id) AS protected
       FROM observation_fingerprints fingerprint
       JOIN observations o ON o.id = fingerprint.observation_id
      WHERE fingerprint.semantic_hash IN (SELECT value FROM json_each(?1))
      ORDER BY fingerprint.semantic_hash, protected DESC, o.captured_at DESC, o.id`,
  ).bind(stableJson(hashes)).all<{ semantic_hash: string; id: string; captured_at: string; protected: number }>();
  const canonicals = new Map<string, string>();
  for (const row of rows.results) if (!canonicals.has(row.semantic_hash)) canonicals.set(row.semantic_hash, row.id);
  const statements = [...canonicals].map(([semanticHash, observationId]) => context.env.DB.prepare(
    `INSERT INTO semantic_fact_canonicals (semantic_hash, observation_id, selected_at)
     VALUES (?1, ?2, CURRENT_TIMESTAMP)
     ON CONFLICT(semantic_hash) DO UPDATE SET observation_id = excluded.observation_id, selected_at = excluded.selected_at`,
  ).bind(semanticHash, observationId));
  for (let offset = 0; offset < statements.length; offset += 90) await context.env.DB.batch(statements.slice(offset, offset + 90));
  return context.json({ ok: true, indexed: canonicals.size, nextCursor: hashes.at(-1) });
});

const canonicalDuplicateCandidatesSql = `SELECT fingerprint.observation_id AS duplicate_id,
       canonical.observation_id AS canonical_id, fingerprint.semantic_hash AS semantic_key, o.captured_at
  FROM observation_fingerprints fingerprint
  JOIN semantic_fact_canonicals canonical ON canonical.semantic_hash = fingerprint.semantic_hash
  JOIN observations o ON o.id = fingerprint.observation_id
 WHERE fingerprint.observation_id <> canonical.observation_id
   AND NOT EXISTS (SELECT 1 FROM release_cells cell WHERE cell.observation_id = fingerprint.observation_id)
   AND NOT EXISTS (SELECT 1 FROM archive_manifest_observations archived WHERE archived.observation_id = fingerprint.observation_id)
   AND NOT EXISTS (SELECT 1 FROM canonical_cleanup_rows prior WHERE prior.duplicate_observation_id = fingerprint.observation_id)
 ORDER BY o.captured_at, fingerprint.observation_id LIMIT ?1`;

app.post("/internal/canonical-cleanup/plan", zValidator("json", canonicalCleanupPlanSchema), async (context) => {
  const body = context.req.valid("json");
  const [candidates, protectedRows] = await Promise.all([
    context.env.DB.prepare(canonicalDuplicateCandidatesSql).bind(body.maximumRows).all<{ duplicate_id: string; canonical_id: string; semantic_key: string; captured_at: string }>(),
    context.env.DB.prepare("SELECT DISTINCT observation_id FROM release_cells WHERE observation_id IS NOT NULL ORDER BY observation_id").all<{ observation_id: string }>(),
  ]);
  const protectedRefsHash = await digestHex(stableJson(protectedRows.results.map((row) => row.observation_id)));
  const summary = { candidates: candidates.results.length, protectedCount: protectedRows.results.length, protectedRefsHash };
  if (body.dryRun) return context.json({ ok: true, dryRun: true, ...summary });
  if (!candidates.results.length) return jsonError("canonical cleanup plan has no eligible duplicates", 422);
  const runId = await deterministicId("canonical-cleanup", protectedRefsHash, ...candidates.results.map((row) => `${row.duplicate_id}:${row.canonical_id}`));
  const statements: D1PreparedStatement[] = [context.env.DB.prepare(
    `INSERT INTO canonical_cleanup_runs (id, status, row_count, protected_refs_hash, detail_json)
     VALUES (?1, 'planned', ?2, ?3, ?4) ON CONFLICT(id) DO NOTHING`,
  ).bind(runId, candidates.results.length, protectedRefsHash, stableJson({ semanticPolicy: "canonical-offer-v1" }))];
  for (let offset = 0; offset < candidates.results.length; offset += 400) statements.push(context.env.DB.prepare(
    `INSERT OR IGNORE INTO canonical_cleanup_rows
       (run_id, duplicate_observation_id, canonical_observation_id, semantic_key)
     SELECT ?1, json_extract(value, '$.duplicate_id'), json_extract(value, '$.canonical_id'), json_extract(value, '$.semantic_key')
       FROM json_each(?2)`,
  ).bind(runId, stableJson(candidates.results.slice(offset, offset + 400))));
  await context.env.DB.batch(statements);
  return context.json({ ok: true, dryRun: false, runId, ...summary }, 201);
});

app.get("/internal/canonical-cleanup/:id/export", async (context) => {
  const run = await context.env.DB.prepare("SELECT id, status, row_count, protected_refs_hash FROM canonical_cleanup_runs WHERE id = ?1")
    .bind(context.req.param("id")).first<Record<string, unknown>>();
  if (!run) return jsonError("canonical cleanup run not found", 404);
  const rows = await context.env.DB.prepare(
    `SELECT map.canonical_observation_id, map.semantic_key, o.*, pv.product_id, pv.name, pv.normalized_name,
            pv.size_text, pv.product_url, pv.image_url, pv.taxonomy_path, p.store_location_id, p.external_key,
            origin.source_id,
            (SELECT json_group_array(json_object('batch_id', member.batch_id, 'term_key', member.term_key,
              'observed_at', member.observed_at, 'source_payload_key', member.source_payload_key,
              'evidence_object_id', member.evidence_object_id, 'provenance_json', json(member.provenance_json),
              'carried', member.carried)) FROM capture_observation_memberships member WHERE member.observation_id = o.id) AS memberships_json
       FROM canonical_cleanup_rows map
       JOIN observations o ON o.id = map.duplicate_observation_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       JOIN capture_batches origin ON origin.id = o.batch_id
      WHERE map.run_id = ?1 ORDER BY o.captured_at, o.id`,
  ).bind(context.req.param("id")).all<Record<string, unknown>>();
  return context.json({ ok: true, run, rows: rows.results });
});

app.put("/internal/canonical-cleanup/:id/parquet", async (context) => {
  const run = await context.env.DB.prepare("SELECT id, status, row_count FROM canonical_cleanup_runs WHERE id = ?1")
    .bind(context.req.param("id")).first<{ id: string; status: string; row_count: number }>();
  if (!run) return jsonError("canonical cleanup run not found", 404);
  if (run.status !== "planned") return jsonError(`canonical cleanup cannot accept bytes in ${run.status}`, 409);
  const bytes = new Uint8Array(await context.req.arrayBuffer());
  const parquetMagic = bytes.length >= 8 && new TextDecoder().decode(bytes.slice(0, 4)) === "PAR1" && new TextDecoder().decode(bytes.slice(-4)) === "PAR1";
  if (!parquetMagic) return jsonError("cleanup archive is not a complete Parquet file", 422);
  const sha256 = await digestHex(bytes);
  const objectKey = `canonical-cleanup/${new Date().toISOString().slice(0, 10).replaceAll("-", "/")}/${run.id}.parquet`;
  await context.env.ARCHIVE.put(objectKey, bytes, { httpMetadata: { contentType: "application/vnd.apache.parquet" }, customMetadata: { runId: run.id, sha256, rows: String(run.row_count) } });
  const stored = await context.env.ARCHIVE.head(objectKey);
  if (!stored || stored.size !== bytes.byteLength || stored.customMetadata?.sha256 !== sha256) return jsonError("cleanup archive failed post-write verification", 500);
  await context.env.DB.prepare("UPDATE canonical_cleanup_runs SET status = 'verified', object_key = ?2, byte_length = ?3, sha256 = ?4, verified_at = CURRENT_TIMESTAMP WHERE id = ?1")
    .bind(run.id, objectKey, stored.size, sha256).run();
  return context.json({ ok: true, runId: run.id, status: "verified", objectKey, byteLength: stored.size, sha256 });
});

app.post("/internal/canonical-cleanup/:id/execute", zValidator("json", canonicalCleanupExecuteSchema), async (context) => {
  const run = await context.env.DB.prepare("SELECT id, status, row_count, object_key, byte_length, sha256, protected_refs_hash FROM canonical_cleanup_runs WHERE id = ?1")
    .bind(context.req.param("id")).first<{ id: string; status: string; row_count: number; object_key: string | null; byte_length: number | null; sha256: string | null; protected_refs_hash: string }>();
  if (!run) return jsonError("canonical cleanup run not found", 404);
  if (run.status === "completed") return context.json({ ok: true, runId: run.id, status: run.status, idempotent: true });
  if (run.status !== "verified" || !run.object_key || run.sha256 !== context.req.valid("json").archiveSha256) return jsonError("verified archive hash confirmation is required", 409);
  const stored = await context.env.ARCHIVE.head(run.object_key);
  if (!stored || stored.size !== run.byte_length || stored.customMetadata?.sha256 !== run.sha256) return jsonError("verified cleanup archive is no longer intact", 409);
  const protectedRows = await context.env.DB.prepare("SELECT DISTINCT observation_id FROM release_cells WHERE observation_id IS NOT NULL ORDER BY observation_id").all<{ observation_id: string }>();
  if (await digestHex(stableJson(protectedRows.results.map((row) => row.observation_id))) !== run.protected_refs_hash) return jsonError("release references changed after cleanup planning", 409);
  const invalid = await context.env.DB.prepare(
    `SELECT COUNT(*) AS count FROM canonical_cleanup_rows map
      WHERE map.run_id = ?1 AND (
        EXISTS(SELECT 1 FROM release_cells cell WHERE cell.observation_id = map.duplicate_observation_id)
        OR EXISTS(SELECT 1 FROM archive_manifest_observations archived WHERE archived.observation_id = map.duplicate_observation_id)
        OR NOT EXISTS(SELECT 1 FROM observations canonical WHERE canonical.id = map.canonical_observation_id)
      )`,
  ).bind(run.id).first<{ count: number }>();
  if ((invalid?.count ?? 0) > 0) return jsonError("cleanup candidates gained a protected reference or lost their canonical fact", 409);
  const expiresAt = new Date(Date.now() + 5 * 60_000).toISOString();
  await context.env.DB.batch([
    context.env.DB.prepare("INSERT OR REPLACE INTO maintenance_leases (kind, run_id, expires_at) VALUES ('canonical-cleanup', ?1, ?2)").bind(run.id, expiresAt),
    context.env.DB.prepare(
      `INSERT INTO capture_observation_memberships
         (batch_id, observation_id, term_key, observed_at, source_payload_key, evidence_object_id, provenance_json, carried)
       SELECT member.batch_id, map.canonical_observation_id, member.term_key, member.observed_at,
              member.source_payload_key, member.evidence_object_id, member.provenance_json, 1
         FROM canonical_cleanup_rows map JOIN capture_observation_memberships member ON member.observation_id = map.duplicate_observation_id
        WHERE map.run_id = ?1
       ON CONFLICT(batch_id, observation_id, term_key) DO UPDATE SET
         observed_at = MAX(capture_observation_memberships.observed_at, excluded.observed_at),
         source_payload_key = COALESCE(excluded.source_payload_key, capture_observation_memberships.source_payload_key),
         evidence_object_id = COALESCE(excluded.evidence_object_id, capture_observation_memberships.evidence_object_id),
         provenance_json = excluded.provenance_json, carried = 1`,
    ).bind(run.id),
    context.env.DB.prepare("DELETE FROM capture_observation_memberships WHERE observation_id IN (SELECT duplicate_observation_id FROM canonical_cleanup_rows WHERE run_id = ?1)").bind(run.id),
    context.env.DB.prepare("DELETE FROM observation_fingerprints WHERE observation_id IN (SELECT duplicate_observation_id FROM canonical_cleanup_rows WHERE run_id = ?1)").bind(run.id),
    context.env.DB.prepare("DELETE FROM observations WHERE id IN (SELECT duplicate_observation_id FROM canonical_cleanup_rows WHERE run_id = ?1)").bind(run.id),
    context.env.DB.prepare("DELETE FROM product_versions WHERE NOT EXISTS (SELECT 1 FROM observations o WHERE o.product_version_id = product_versions.id)"),
    context.env.DB.prepare("DELETE FROM maintenance_leases WHERE kind = 'canonical-cleanup' AND run_id = ?1").bind(run.id),
    context.env.DB.prepare("UPDATE canonical_cleanup_runs SET status = 'completed', completed_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'verified'").bind(run.id),
  ]);
  await recordAudit(context.env, context.get("identity"), "canonical_cleanup.execute", "canonical_cleanup", run.id, "accepted", { rows: run.row_count, archive: run.object_key, sha256: run.sha256 });
  return context.json({ ok: true, runId: run.id, status: "completed", removedFacts: run.row_count, idempotent: false });
});

app.post("/internal/capture-batches", zValidator("json", captureBatchCreateSchema), async (context) => {
  const body = context.req.valid("json");
  const identity = context.get("identity");
  if (identity.sourceIds && !identity.sourceIds.includes(body.sourceId)) return jsonError("agent is not authorized for this capture source", 403);
  const source = await context.env.DB.prepare("SELECT id, store_location_id, capture_method, price_mode FROM capture_sources WHERE id = ?1 AND active = 1").bind(body.sourceId).first<{ id: string; store_location_id: string; capture_method: string; price_mode: string }>();
  if (!source) return jsonError("unknown or inactive capture source", 404);
  const canonicalMode = (value: string) => value.toLowerCase().replaceAll(/[_\s-]+/g, "").replace("clubpickup", "club");
  if (canonicalMode(body.priceMode) !== canonicalMode(source.price_mode)) return jsonError(`capture price mode ${body.priceMode} does not match source contract ${source.price_mode}`, 422);
  if (identity.role === "engine" && !engineMayWriteCaptureSource(source.id, source.capture_method)) {
    return jsonError("engine identities may only create migration-bridge or approved direct-headless batches", 403);
  }
  const existing = await context.env.DB.prepare(
    "SELECT id, status FROM capture_batches WHERE agent_id = ?1 AND idempotency_key = ?2",
  ).bind(identity.agentId, body.idempotencyKey).first<{ id: string; status: string }>();
  if (existing) return context.json({ ok: true, batchId: existing.id, storeLocationId: source.store_location_id, status: existing.status, idempotent: true });
  const batchId = `batch_${crypto.randomUUID()}`;
  await context.env.DB.prepare(
    `INSERT INTO capture_batches
       (id, source_id, coverage_mode, captured_from, captured_to, valid_from, valid_to, expected_terms,
        expected_pages, market_verified, location_verified, price_mode_verified, price_mode, agent_id, idempotency_key,
        source_contract_fingerprint, source_shape_fingerprint, source_schema_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)`,
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
    body.priceMode,
    identity.agentId,
    body.idempotencyKey,
    body.sourceSchema?.contractFingerprint ?? null,
    body.sourceSchema?.shapeFingerprint ?? null,
    stableJson(body.sourceSchema ?? {}),
  ).run();
  return context.json({ ok: true, batchId, storeLocationId: source.store_location_id, status: "open", idempotent: false }, 201);
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

app.post("/internal/capture-batches/:id/observations/existing", zValidator("json", observationExistenceSchema), async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  const engineOwnedCapture = identity.role === "engine" && engineMayWriteCaptureSource(batch.source_id, batch.capture_method);
  if (identity.role !== "capture" && identity.role !== "operator" && !engineOwnedCapture) return jsonError("mutation role is not authorized for capture content", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
  const ids = context.req.valid("json").observationIds;
  const rows = await context.env.DB.prepare(
    `SELECT o.id FROM json_each(?1) requested
       JOIN observations o ON o.id = requested.value
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       JOIN capture_batches origin ON origin.id = o.batch_id
      WHERE p.store_location_id = ?2 AND origin.source_id = ?3`,
  ).bind(stableJson(ids), batch.store_location_id, batch.source_id).all<{ id: string }>();
  return context.json({ ok: true, existingIds: rows.results.map((row) => row.id), missingIds: ids.filter((id) => !rows.results.some((row) => row.id === id)) });
});

app.post("/internal/capture-batches/:id/observation-references", zValidator("json", observationReferencesSchema), async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  if (batch.status !== "open") return jsonError(`batch ${batch.id} is not open`, 409);
  const identity = context.get("identity");
  const engineOwnedCapture = identity.role === "engine" && engineMayWriteCaptureSource(batch.source_id, batch.capture_method);
  if (identity.role !== "capture" && identity.role !== "operator" && !engineOwnedCapture) return jsonError("mutation role is not authorized for capture content", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
  const references = context.req.valid("json").references;
  const requestedIds = [...new Set(references.map((reference) => reference.observationId))];
  const valid = await context.env.DB.prepare(
    `SELECT o.id FROM json_each(?1) requested
       JOIN observations o ON o.id = requested.value
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       JOIN capture_batches origin ON origin.id = o.batch_id
      WHERE p.store_location_id = ?2 AND origin.source_id = ?3`,
  ).bind(stableJson(requestedIds), batch.store_location_id, batch.source_id).all<{ id: string }>();
  const validIds = new Set(valid.results.map((row) => row.id));
  if (validIds.size !== requestedIds.length) return jsonError("one or more carried observations do not belong to this capture source and location", 422);
  for (const reference of references) {
    if (reference.observedAt < batch.captured_from || reference.observedAt > batch.captured_to) return jsonError(`carried observation ${reference.observationId} falls outside the batch capture interval`, 422);
    const snapshot = reference.provenance.offerSnapshot;
    if (snapshot && typeof snapshot === "object" && !Array.isArray(snapshot)
      && (snapshot as Record<string, unknown>).observedAt !== reference.observedAt) return jsonError(`carried observation ${reference.observationId} snapshot time does not match membership`, 422);
  }
  const statements = references.map((reference) => context.env.DB.prepare(
    `INSERT INTO capture_observation_memberships
       (batch_id, observation_id, term_key, observed_at, source_payload_key, evidence_object_id, provenance_json, carried)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1)
     ON CONFLICT(batch_id, observation_id, term_key) DO UPDATE SET
       observed_at = MAX(capture_observation_memberships.observed_at, excluded.observed_at),
       source_payload_key = COALESCE(excluded.source_payload_key, capture_observation_memberships.source_payload_key),
       evidence_object_id = COALESCE(excluded.evidence_object_id, capture_observation_memberships.evidence_object_id),
       provenance_json = excluded.provenance_json, carried = 1`,
  ).bind(batch.id, reference.observationId, reference.termKey ?? "", reference.observedAt,
    reference.sourcePayloadKey ?? null, reference.evidenceObjectId ?? null, stableJson(reference.provenance)));
  for (let offset = 0; offset < statements.length; offset += 80) await context.env.DB.batch(statements.slice(offset, offset + 80));
  return context.json({ ok: true, referenced: references.length, uniqueFacts: requestedIds.length });
});

app.put("/internal/capture-journal-checkpoints", async (context) => {
  const identity = context.get("identity");
  const ciphertextSha256 = context.req.header("x-content-sha256") ?? "";
  const plaintextSha256 = context.req.header("x-journal-plaintext-sha256") ?? "";
  const schemaText = context.req.header("x-journal-schema") ?? "";
  const createdAt = context.req.header("x-checkpoint-created-at") ?? "";
  if (!/^[a-f0-9]{64}$/.test(ciphertextSha256) || !/^[a-f0-9]{64}$/.test(plaintextSha256)) {
    return jsonError("journal checkpoint hashes must be lowercase SHA-256 hex", 422);
  }
  if (!/^[1-9][0-9]*$/.test(schemaText)) return jsonError("journal schema must be a positive integer", 422);
  const journalSchema = Number(schemaText);
  const createdTime = Date.parse(createdAt);
  if (!Number.isFinite(createdTime) || Math.abs(Date.now() - createdTime) > 24 * 60 * 60_000) {
    return jsonError("checkpoint creation time must be within 24 hours of ingestion", 422);
  }
  const bytes = new Uint8Array(await context.req.arrayBuffer());
  // The journal now contains compressed, content-addressed in-progress chunks
  // and proof images, not only coordination metadata. Keep the ceiling below
  // the paid Workers request limit while allowing a complete four-store cycle.
  if (bytes.byteLength < 32 || bytes.byteLength > 75 * 1024 * 1024) return jsonError("encrypted journal checkpoint must be 32 bytes through 75 MiB", 422);
  if (await digestHex(bytes) !== ciphertextSha256) return jsonError("journal checkpoint ciphertext hash does not match content", 422);
  const checkpointId = await deterministicId("capture-journal-checkpoint", identity.agentId, plaintextSha256);
  const existing = await context.env.DB.prepare(
    "SELECT object_key, ciphertext_sha256, byte_length, created_at FROM capture_journal_checkpoints WHERE id = ?1",
  ).bind(checkpointId).first<{ object_key: string; ciphertext_sha256: string; byte_length: number; created_at: string }>();
  if (existing) {
    const object = await context.env.EVIDENCE.head(existing.object_key);
    if (object && object.size === existing.byte_length && object.customMetadata?.ciphertextsha256 === existing.ciphertext_sha256) {
      return context.json({ ok: true, checkpointId, objectKey: existing.object_key, createdAt: existing.created_at, idempotent: true });
    }
    const repairedAt = new Date().toISOString();
    await context.env.EVIDENCE.put(existing.object_key, bytes, {
      httpMetadata: { contentType: "application/vnd.thriftycrew.capture-journal+encrypted" },
      customMetadata: { ciphertextsha256: ciphertextSha256, plaintextsha256: plaintextSha256, journalschema: schemaText, agentid: identity.agentId },
    });
    const repaired = await context.env.EVIDENCE.head(existing.object_key);
    if (!repaired || repaired.size !== bytes.byteLength || repaired.customMetadata?.ciphertextsha256 !== ciphertextSha256) {
      return jsonError("journal checkpoint repair could not be verified after R2 storage", 502);
    }
    await context.env.DB.prepare(
      `UPDATE capture_journal_checkpoints SET ciphertext_sha256 = ?2, byte_length = ?3, verified_at = ?4 WHERE id = ?1`,
    ).bind(checkpointId, ciphertextSha256, bytes.byteLength, repairedAt).run();
    return context.json({ ok: true, checkpointId, objectKey: existing.object_key, createdAt: existing.created_at, repairedAt, idempotent: true, repaired: true });
  }
  const safeTime = new Date(createdTime).toISOString().replace(/[:.]/g, "-");
  const objectKey = `capture-journals/${encodeURIComponent(identity.agentId)}/${safeTime}-${plaintextSha256.slice(0, 16)}.tcj`;
  await context.env.EVIDENCE.put(objectKey, bytes, {
    httpMetadata: { contentType: "application/vnd.thriftycrew.capture-journal+encrypted" },
    customMetadata: { ciphertextsha256: ciphertextSha256, plaintextsha256: plaintextSha256, journalschema: schemaText, agentid: identity.agentId },
  });
  const stored = await context.env.EVIDENCE.head(objectKey);
  if (!stored || stored.size !== bytes.byteLength || stored.customMetadata?.ciphertextsha256 !== ciphertextSha256) {
    await context.env.EVIDENCE.delete(objectKey);
    return jsonError("journal checkpoint could not be verified after R2 storage", 502);
  }
  const verifiedAt = new Date().toISOString();
  await context.env.DB.prepare(
    `INSERT INTO capture_journal_checkpoints
       (id, agent_id, object_key, ciphertext_sha256, plaintext_sha256, byte_length, journal_schema, created_at, verified_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
  ).bind(checkpointId, identity.agentId, objectKey, ciphertextSha256, plaintextSha256, bytes.byteLength, journalSchema, new Date(createdTime).toISOString(), verifiedAt).run();
  const expired = await context.env.DB.prepare(
    `SELECT id, object_key FROM capture_journal_checkpoints
      WHERE agent_id = ?1 AND created_at < datetime('now', '-30 days') ORDER BY created_at ASC LIMIT 25`,
  ).bind(identity.agentId).all<{ id: string; object_key: string }>();
  if (expired.results.length > 0) {
    await Promise.all(expired.results.map((row) => context.env.EVIDENCE.delete(row.object_key)));
    await context.env.DB.prepare(
      `DELETE FROM capture_journal_checkpoints
        WHERE agent_id = ?1 AND created_at < datetime('now', '-30 days')`,
    ).bind(identity.agentId).run();
  }
  return context.json({ ok: true, checkpointId, objectKey, createdAt: new Date(createdTime).toISOString(), verifiedAt, idempotent: false }, 201);
});

app.get("/internal/capture-journal-checkpoints/latest", async (context) => {
  const identity = context.get("identity");
  const requestedAgentId = context.req.query("agentId");
  if (requestedAgentId && identity.role !== "operator" && requestedAgentId !== identity.agentId) {
    return jsonError("a capture agent may only restore its own journal", 403);
  }
  const agentId = identity.role === "operator" && requestedAgentId ? requestedAgentId : identity.agentId;
  const checkpoint = await context.env.DB.prepare(
    `SELECT id, object_key, ciphertext_sha256, plaintext_sha256, byte_length, journal_schema, created_at, verified_at
       FROM capture_journal_checkpoints WHERE agent_id = ?1 ORDER BY created_at DESC LIMIT 1`,
  ).bind(agentId).first<{ id: string; object_key: string; ciphertext_sha256: string; plaintext_sha256: string; byte_length: number; journal_schema: number; created_at: string; verified_at: string }>();
  if (!checkpoint) return jsonError("no capture journal checkpoint exists", 404);
  const object = await context.env.EVIDENCE.head(checkpoint.object_key);
  if (!object || object.size !== checkpoint.byte_length || object.customMetadata?.ciphertextsha256 !== checkpoint.ciphertext_sha256) {
    return jsonError("latest journal checkpoint is missing or failed R2 metadata verification", 502);
  }
  const download = await createDirectObjectDownload(context.env, checkpoint.object_key);
  return context.json({
    ok: true,
    checkpoint: {
      id: checkpoint.id,
      agentId,
      ciphertextSha256: checkpoint.ciphertext_sha256,
      plaintextSha256: checkpoint.plaintext_sha256,
      byteLength: checkpoint.byte_length,
      journalSchema: checkpoint.journal_schema,
      createdAt: checkpoint.created_at,
      verifiedAt: checkpoint.verified_at,
      downloadUrl: download.url,
      downloadExpiresIn: download.expiresIn,
    },
  });
});

app.get("/internal/maintenance/architecture", async (context) => {
  const [reasons, products, releases] = await Promise.all([
    context.env.DB.prepare("SELECT COUNT(*) AS count FROM release_cells WHERE reason_hash IS NULL").first<{ count: number }>(),
    context.env.DB.prepare(
      `SELECT COUNT(DISTINCT p.id) AS count FROM products p JOIN product_versions pv ON pv.product_id = p.id
        WHERE NOT EXISTS (SELECT 1 FROM product_entity_links link WHERE link.product_id = p.id)
          AND (json_extract(pv.identity_json, '$.gtin') IS NOT NULL OR json_extract(pv.identity_json, '$.upc') IS NOT NULL)`,
    ).first<{ count: number }>(),
    context.env.DB.prepare(
      `SELECT release.id, release.state,
              COUNT(cost.recipe_slug) AS costs,
              COUNT(detail.recipe_slug) AS detail_objects,
              SUM(CASE WHEN detail.compacted_at IS NOT NULL THEN 1 ELSE 0 END) AS compacted
         FROM releases release
         LEFT JOIN release_recipe_costs cost ON cost.release_id = release.id
         LEFT JOIN recipe_cost_detail_objects detail ON detail.release_id = cost.release_id AND detail.recipe_slug = cost.recipe_slug
        GROUP BY release.id, release.state ORDER BY release.created_at`,
    ).all<{ id: string; state: string; costs: number; detail_objects: number; compacted: number | null }>(),
  ]);
  return context.json({ ok: true, releaseReasonsRemaining: reasons?.count ?? 0, entityProductsRemaining: products?.count ?? 0, releases: releases.results });
});

app.post("/internal/maintenance/architecture", async (context) => {
  const body: Record<string, unknown> = await context.req.json<Record<string, unknown>>().catch(() => ({} as Record<string, unknown>));
  const action = String(body.action ?? "");
  const limit = Math.max(1, Math.min(500, Number(body.limit ?? 200)));
  try {
    if (action === "release-reasons") return context.json({ ok: true, action, ...(await backfillReleaseReasons(context.env, limit)) });
    if (action === "product-entities") return context.json({ ok: true, action, ...(await backfillProductEntities(context.env, limit)) });
    if (action === "entity-suggestions") return context.json({ ok: true, action, ...(await buildProductEntitySuggestions(context.env, limit)) });
    const releaseId = String(body.releaseId ?? "");
    if (!releaseId) return jsonError("recipe detail maintenance requires releaseId", 422);
    if (action === "recipe-detail-build") return context.json({ ok: true, action, releaseId, ...(await buildReleaseRecipeDetailArchive(context.env, releaseId)) });
    if (action === "recipe-detail-compact") return context.json({ ok: true, action, ...(await compactReleaseRecipeDetails(context.env, releaseId)) });
    return jsonError("unsupported architecture maintenance action", 422);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "architecture maintenance failed", 422);
  }
});

app.get("/internal/storage/releases", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may inspect immutable release migration state", 403);
  const rows = await context.env.DB.prepare(
    `SELECT release.id, release.state, release.created_at, graph.root_hash,
            CASE WHEN current.release_id IS NULL THEN 0 ELSE 1 END AS is_current
       FROM releases release
       LEFT JOIN release_graphs graph ON graph.release_id = release.id
       LEFT JOIN current_releases current ON current.release_id = release.id
      ORDER BY release.created_at`,
  ).all<{ id: string; state: string; created_at: string; root_hash: string | null; is_current: number }>();
  return context.json({ ok: true, releases: rows.results });
});

app.post("/internal/storage/gc/plan", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may plan R2 garbage collection", 403);
  const body = await context.req.json<Record<string, unknown>>().catch(() => ({} as Record<string, unknown>));
  const graceDays = Number(body.graceDays ?? 7);
  const maximumObjects = Number(body.maximumObjects ?? 500);
  if (!Number.isInteger(graceDays) || graceDays < 2 || graceDays > 90) return jsonError("R2 garbage collection graceDays must be 2-90", 422);
  if (!Number.isInteger(maximumObjects) || maximumObjects < 1 || maximumObjects > 2_000) return jsonError("R2 garbage collection maximumObjects must be 1-2000", 422);
  try {
    const result = await planR2GarbageCollection(context.env, { graceDays, maximumObjects, execute: body.execute === true });
    await recordAudit(context.env, context.get("identity"), "storage.gc.plan", "r2_gc_run", result.runId, "accepted", result);
    return context.json(result, body.execute === true ? 201 : 200);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "R2 garbage collection planning failed", 422);
  }
});

app.post("/internal/storage/gc/:id/sweep", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may sweep R2 garbage collection", 403);
  const body = await context.req.json<Record<string, unknown>>().catch(() => ({} as Record<string, unknown>));
  try {
    const result = await sweepR2GarbageCollection(context.env, context.req.param("id"), body.execute === true);
    await recordAudit(context.env, context.get("identity"), "storage.gc.sweep", "r2_gc_run", context.req.param("id"), "accepted", result);
    return context.json(result);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "R2 garbage collection sweep failed", 409);
  }
});

app.post("/internal/storage/backfill-release/:id", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may backfill immutable release history", 403);
  const releaseId = context.req.param("id");
  const release = await context.env.DB.prepare(
    "SELECT id, market_id, input_hash, created_at FROM releases WHERE id = ?1",
  ).bind(releaseId).first<{ id: string; market_id: string; input_hash: string; created_at: string }>();
  if (!release) return jsonError("release not found", 404);
  const existing = await context.env.DB.prepare("SELECT root_hash, object_key, node_count FROM release_graphs WHERE release_id = ?1")
    .bind(releaseId).first<{ root_hash: string; object_key: string; node_count: number }>();
  if (existing) return context.json({ ok: true, releaseId, ...existing, idempotent: true });
  const [cells, costs, payloadRows, top5, rotation, parent, current] = await Promise.all([
    context.env.DB.prepare(
      `SELECT commodity_id, store_location_id, observation_id, status, is_crown, display_per_unit_micros, display_unit, reason_json
         FROM release_cells_with_reasons WHERE release_id = ?1 ORDER BY commodity_id, store_location_id`,
    ).bind(releaseId).all<Record<string, unknown>>(),
    context.env.DB.prepare(
      `SELECT recipe_slug, status, batch_cost_minor, serving_cost_minor, servings, missing_ingredients_json
         FROM release_recipe_costs WHERE release_id = ?1 ORDER BY recipe_slug`,
    ).bind(releaseId).all<Record<string, unknown>>(),
    context.env.DB.prepare("SELECT kind, payload_json, object_key FROM release_payloads WHERE release_id = ?1 ORDER BY kind")
      .bind(releaseId).all<{ kind: string; payload_json: string; object_key: string | null }>(),
    context.env.DB.prepare("SELECT protein, rank, recipe_slug, serving_cost_minor FROM release_top5 WHERE release_id = ?1 ORDER BY protein, rank")
      .bind(releaseId).all<Record<string, unknown>>(),
    context.env.DB.prepare("SELECT recipe_slug, intended_visibility, protein, rank FROM release_free_rotation WHERE release_id = ?1 ORDER BY protein, rank, recipe_slug")
      .bind(releaseId).all<Record<string, unknown>>(),
    context.env.DB.prepare("SELECT id FROM releases WHERE market_id = ?1 AND created_at < ?2 ORDER BY created_at DESC LIMIT 1")
      .bind(release.market_id, release.created_at).first<{ id: string }>(),
    context.env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = ?1").bind(release.market_id).first<{ release_id: string }>(),
  ]);
  const keepHotPayloads = current?.release_id === releaseId;
  const nodes: Array<{ kind: string; key: string; dependencyHash: string; contentHash: string; objectKey: string; byteLength: number; payloadText?: string }> = [];
  const addNode = async (kind: string, key: string, payload: unknown) => {
    const serialized = stableJson(payload);
    const contentHash = await digestHex(serialized);
    const dependencyHash = await digestHex(stableJson({ version: "historical-backfill-v1", kind, key, contentHash }));
    const objectKey = `release-nodes/schema=1/kind=${kind}/prefix=${contentHash.slice(0, 2)}/${contentHash}.json`;
    const bytes = new TextEncoder().encode(serialized);
    if (!await context.env.ARCHIVE.head(objectKey)) await context.env.ARCHIVE.put(objectKey, bytes, {
      httpMetadata: { contentType: "application/json; charset=utf-8" }, customMetadata: { sha256: contentHash, schema: "release-node-v1", kind },
    });
    const stored = await context.env.ARCHIVE.head(objectKey);
    if (!stored || stored.size !== bytes.byteLength || stored.customMetadata?.sha256 !== contentHash) throw new Error(`historical release node failed verification: ${kind}/${key}`);
    nodes.push({ kind, key, dependencyHash, contentHash, objectKey, byteLength: bytes.byteLength,
      ...(keepHotPayloads ? { payloadText: serialized } : {}) });
  };
  const historicalRecipes = costs.results.map((row) => ({
      recipeSlug: row.recipe_slug, status: row.status, batchCostMinor: row.batch_cost_minor,
      servingCostMinor: row.serving_cost_minor, servings: row.servings,
      missingIngredients: JSON.parse(String(row.missing_ingredients_json)),
    }));
  await addNode("cells", "all", cells.results);
  await addNode("recipes", "summaries", historicalRecipes);
  await addNode("ranking", "top5", top5.results);
  await addNode("rotation", "free", rotation.results);
  let payloadCount = 0;
  for (const row of payloadRows.results) {
    const payload = row.object_key ? await context.env.EVIDENCE.get(row.object_key).then((object) => object?.json()) : JSON.parse(row.payload_json);
    if (payload !== undefined) {
      await addNode("payload", row.kind, payload);
      payloadCount += 1;
    }
  }
  if (payloadCount === 0) {
    // A prior projection compactor may have removed D1 payload pointers before
    // the object-graph cutover. The content-addressed R2 payloads remain and
    // are sufficient to recover the public historical release snapshot.
    const prefix = `releases/${releaseId}/`;
    let cursor: string | undefined;
    do {
      const listed = await context.env.EVIDENCE.list({ prefix, limit: 1000, ...(cursor ? { cursor } : {}) });
      for (const object of listed.objects) {
        const suffix = object.key.slice(prefix.length);
        const match = suffix.match(/^([^/]+)-[a-f0-9]{64}\.json$/);
        if (!match) continue;
        const payload = await context.env.EVIDENCE.get(object.key).then((value) => value?.json());
        if (payload !== undefined) {
          await addNode("payload", match[1]!, payload);
          payloadCount += 1;
        }
      }
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);
  }
  // Stream detailed recipe calculations in bounded chunks. Keeping the bytes
  // out of the manifest builder prevents historical cutover memory from
  // growing with the recipe catalog.
  const detailChunkSize = 20;
  for (let offset = 0; ; offset += detailChunkSize) {
    const detailRows = await context.env.DB.prepare(
      `SELECT cost.recipe_slug, cost.detail_json, detail.object_key AS detail_object_key
         FROM release_recipe_costs cost LEFT JOIN recipe_cost_detail_objects detail
           ON detail.release_id = cost.release_id AND detail.recipe_slug = cost.recipe_slug
        WHERE cost.release_id = ?1 ORDER BY cost.recipe_slug LIMIT ?2 OFFSET ?3`,
    ).bind(releaseId, detailChunkSize, offset).all<{ recipe_slug: string; detail_json: string; detail_object_key: string | null }>();
    if (detailRows.results.length === 0) break;
    const details = await Promise.all(detailRows.results.map(async (row) => {
      let detail = JSON.parse(row.detail_json) as Record<string, unknown>;
      if (detail.archived === true && row.detail_object_key) {
        const object = await context.env.EVIDENCE.get(row.detail_object_key);
        if (object) detail = await object.json<Record<string, unknown>>();
      }
      return { recipeSlug: row.recipe_slug, detail };
    }));
    await addNode("recipe-details", String(offset).padStart(6, "0"), details);
    if (detailRows.results.length < detailChunkSize) break;
  }
  nodes.sort((left, right) => left.kind.localeCompare(right.kind) || left.key.localeCompare(right.key));
  const dependencyHash = await digestHex(stableJson(nodes.map((node) => [node.kind, node.key, node.dependencyHash])));
  const manifest = { version: 1, releaseId, parentReleaseId: parent?.id ?? null, inputHash: release.input_hash, dependencyHash,
    nodes: nodes.map((node) => ({ kind: node.kind, key: node.key, dependencyHash: node.dependencyHash, contentHash: node.contentHash })) };
  const manifestText = stableJson(manifest);
  const rootHash = await digestHex(manifestText);
  const manifestBytes = new TextEncoder().encode(manifestText);
  const objectKey = `release-manifests/schema=1/market=${release.market_id}/${releaseId}-${rootHash}.json`;
  await context.env.ARCHIVE.put(objectKey, manifestBytes, {
    httpMetadata: { contentType: "application/json; charset=utf-8" }, customMetadata: { sha256: rootHash, schema: "release-manifest-v1", releaseId },
  });
  const statements: D1PreparedStatement[] = nodes.flatMap((node) => [context.env.DB.prepare(
    `INSERT OR IGNORE INTO object_store_objects
       (content_hash, object_key, object_kind, format, byte_length, schema_version, verified_at)
     VALUES (?1, ?2, 'release-node', 'json', ?3, 1, CURRENT_TIMESTAMP)`,
  ).bind(node.contentHash, node.objectKey, node.byteLength)]);
  statements.push(context.env.DB.prepare(
    `INSERT OR IGNORE INTO object_store_objects
       (content_hash, object_key, object_kind, format, byte_length, row_count, schema_version, verified_at)
     VALUES (?1, ?2, 'release-manifest', 'json', ?3, ?4, 1, CURRENT_TIMESTAMP)`,
  ).bind(rootHash, objectKey, manifestBytes.byteLength, nodes.length));
  statements.push(context.env.DB.prepare(
    `INSERT INTO release_graphs
       (release_id, parent_release_id, root_hash, object_key, node_count, changed_node_count, reused_node_count, dependency_hash, byte_length, finalized_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?5, 0, ?6, ?7, CURRENT_TIMESTAMP)`,
  ).bind(releaseId, parent?.id ?? null, rootHash, objectKey, nodes.length, dependencyHash, manifestBytes.byteLength));
  if (current?.release_id === releaseId) for (const node of nodes) statements.push(context.env.DB.prepare(
    `INSERT OR REPLACE INTO release_graph_nodes
       (release_id, node_kind, node_key, dependency_hash, content_hash, payload_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  ).bind(releaseId, node.kind, node.key, node.dependencyHash, node.contentHash,
    node.payloadText ?? "{}"));
  for (let offset = 0; offset < statements.length; offset += 80) await context.env.DB.batch(statements.slice(offset, offset + 80));
  return context.json({ ok: true, releaseId, rootHash, objectKey, nodes: nodes.length, current: current?.release_id === releaseId, idempotent: false });
});

app.post("/internal/storage/compact-releases", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may compact historical release projections", 403);
  const releases = await context.env.DB.prepare(
    `SELECT release.id FROM releases release JOIN release_graphs graph ON graph.release_id = release.id
      WHERE release.state IN ('superseded', 'rejected')
        AND (EXISTS (SELECT 1 FROM release_cells cell WHERE cell.release_id = release.id
                      AND NOT EXISTS (SELECT 1 FROM accuracy_draw_cells sample
                                       WHERE sample.release_id = cell.release_id
                                         AND sample.commodity_id = cell.commodity_id
                                         AND sample.store_location_id = cell.store_location_id))
          OR EXISTS (SELECT 1 FROM release_recipe_costs cost WHERE cost.release_id = release.id)
          OR EXISTS (SELECT 1 FROM release_payloads payload WHERE payload.release_id = release.id))
      ORDER BY release.created_at LIMIT 5`,
  ).all<{ id: string }>();
  const results = [];
  for (const release of releases.results) {
    const before = await context.env.DB.prepare(
      `SELECT (SELECT COUNT(*) FROM release_cells WHERE release_id = ?1) AS cells,
              (SELECT COUNT(*) FROM release_recipe_costs WHERE release_id = ?1) AS recipes`,
    ).bind(release.id).first<{ cells: number; recipes: number }>();
    await context.env.DB.batch([
      context.env.DB.prepare("DELETE FROM recipe_cost_detail_objects WHERE release_id = ?1").bind(release.id),
      context.env.DB.prepare("DELETE FROM release_recipe_payload_refs WHERE release_id = ?1").bind(release.id),
      context.env.DB.prepare("DELETE FROM release_recipe_payloads WHERE release_id = ?1").bind(release.id),
      context.env.DB.prepare("DELETE FROM release_recipe_scenarios WHERE release_id = ?1").bind(release.id),
      context.env.DB.prepare("DELETE FROM release_recipe_costs WHERE release_id = ?1").bind(release.id),
      context.env.DB.prepare("DELETE FROM release_top5 WHERE release_id = ?1").bind(release.id),
      context.env.DB.prepare("DELETE FROM release_free_rotation WHERE release_id = ?1").bind(release.id),
      context.env.DB.prepare("DELETE FROM release_payloads WHERE release_id = ?1").bind(release.id),
      context.env.DB.prepare(
        `DELETE FROM release_cells WHERE release_id = ?1
          AND NOT EXISTS (SELECT 1 FROM accuracy_draw_cells sample
                           WHERE sample.release_id = release_cells.release_id
                             AND sample.commodity_id = release_cells.commodity_id
                             AND sample.store_location_id = release_cells.store_location_id)`,
      ).bind(release.id),
      context.env.DB.prepare("DELETE FROM release_graph_nodes WHERE release_id = ?1").bind(release.id),
    ]);
    results.push({ releaseId: release.id, cells: before?.cells ?? 0, recipes: before?.recipes ?? 0 });
  }
  await context.env.DB.prepare(
    "DELETE FROM release_reason_blobs WHERE NOT EXISTS (SELECT 1 FROM release_cells cell WHERE cell.reason_hash = release_reason_blobs.content_hash)",
  ).run();
  const remaining = await context.env.DB.prepare(
    `SELECT COUNT(*) AS count FROM releases release
      WHERE release.state IN ('superseded', 'rejected') AND NOT EXISTS (SELECT 1 FROM release_graphs graph WHERE graph.release_id = release.id)`,
  ).first<{ count: number }>();
  return context.json({ ok: true, compacted: results, historicalReleasesWithoutGraph: remaining?.count ?? 0 });
});

app.post("/internal/capture-batches/:id/evidence-upload-sessions", zValidator("json", captureEvidenceUploadSessionSchema), async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  if (identity.role !== "capture" && identity.role !== "operator") return jsonError("mutation role is not authorized for direct capture evidence", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
  if (identity.sourceIds && !identity.sourceIds.includes(batch.source_id)) return jsonError("agent is not authorized for this capture source", 403);
  if (batch.status !== "open") return jsonError("evidence can only be added to an open batch", 409);
  const body = context.req.valid("json");
  const existingEvidence = await context.env.DB.prepare(
    "SELECT object_key, sha256, byte_length FROM evidence_objects WHERE id = ?1 AND batch_id = ?2",
  ).bind(body.id, batch.id).first<{ object_key: string; sha256: string; byte_length: number }>();
  if (existingEvidence) {
    if (existingEvidence.sha256 !== body.sha256 || existingEvidence.byte_length !== body.byteLength) return jsonError("evidence id already exists with different content", 409);
    return context.json({ ok: true, evidenceId: body.id, objectKey: existingEvidence.object_key, finalized: true, idempotent: true });
  }
  let attempt: CaptureUploadAttempt;
  try {
    attempt = await issueCaptureUploadAttempt(context.env, {
      batchId: batch.id, requestedBy: identity.agentId, evidenceId: body.id, kind: body.kind,
      contentType: body.contentType, sha256: body.sha256, contentMd5: body.contentMd5, byteLength: body.byteLength,
    });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "direct evidence upload attempt could not be issued", 409);
  }
  if (attempt.status === "finalized") return jsonError("finalized upload attempt is missing its authoritative evidence record", 409);
  const expiresSeconds = Math.max(60, Math.floor((Date.parse(attempt.expires_at) - Date.now()) / 1000));
  const upload = await createDirectEvidenceUpload(context.env, {
    uploadSessionId: attempt.id, objectKey: attempt.object_key, evidenceId: body.id, kind: body.kind,
    contentType: body.contentType, sha256: body.sha256, contentMd5: body.contentMd5, expiresSeconds,
  });
  return context.json({ ok: true, uploadSessionId: attempt.id, evidenceId: body.id, objectKey: attempt.object_key, attemptNumber: attempt.attempt_number, expiresAt: attempt.expires_at, ...upload }, 201);
});

app.post("/internal/capture-batches/:id/evidence-upload-sessions/finalize", zValidator("json", captureEvidenceUploadFinalizeSchema), async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  if (identity.role !== "capture" && identity.role !== "operator") return jsonError("mutation role is not authorized for direct capture evidence", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
  if (identity.sourceIds && !identity.sourceIds.includes(batch.source_id)) return jsonError("agent is not authorized for this capture source", 403);
  if (batch.status !== "open") return jsonError("evidence can only be finalized on an open batch", 409);
  const body = context.req.valid("json");
  const upload = await context.env.DB.prepare(
    `SELECT id, requested_by, evidence_id, object_key, kind, content_type, expected_sha256,
            expected_bytes, status, expires_at
       FROM capture_evidence_upload_attempts WHERE id = ?1 AND batch_id = ?2`,
  ).bind(body.uploadSessionId, batch.id).first<{
    id: string; requested_by: string; evidence_id: string; object_key: string; kind: string; content_type: string;
    expected_sha256: string; expected_bytes: number; status: string; expires_at: string;
  }>();
  if (!upload) return jsonError("direct evidence upload session not found", 404);
  if (upload.requested_by !== identity.agentId && identity.role !== "operator") return jsonError("upload session belongs to another agent", 403);
  if (upload.status === "finalized") return context.json({ ok: true, uploadSessionId: upload.id, evidenceId: upload.evidence_id, objectKey: upload.object_key, idempotent: true });
  if (Date.parse(upload.expires_at) < Date.now()) {
    await context.env.DB.prepare("UPDATE capture_evidence_upload_attempts SET status = 'expired' WHERE id = ?1").bind(upload.id).run();
    return jsonError("direct evidence upload session expired", 409);
  }
  const object = await context.env.EVIDENCE.head(upload.object_key);
  if (!object) return jsonError("direct evidence object has not reached R2", 409);
  const metadata = object.customMetadata ?? {};
  const metadataPass = metadata.sha256 === upload.expected_sha256
    && metadata.kind === upload.kind
    && metadata.evidenceid === upload.evidence_id
    && metadata.uploadsessionid === upload.id;
  if (object.size !== upload.expected_bytes || !metadataPass) {
    await context.env.DB.prepare("UPDATE capture_evidence_upload_attempts SET status = 'rejected' WHERE id = ?1").bind(upload.id).run();
    return jsonError("direct evidence object metadata or length does not match the signed upload session", 422);
  }
  if (upload.kind === "screenshot") {
    const screenshot = await context.env.EVIDENCE.get(upload.object_key);
    if (!screenshot) return jsonError("direct screenshot evidence disappeared during finalization", 409);
    try { validateScreenshotEvidence(new Uint8Array(await screenshot.arrayBuffer()), upload.content_type); }
    catch (error) {
      await context.env.DB.prepare("UPDATE capture_evidence_upload_attempts SET status = 'rejected' WHERE id = ?1").bind(upload.id).run();
      return jsonError(error instanceof Error ? error.message : "invalid screenshot evidence", 422);
    }
  }
  await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT INTO evidence_objects (id, batch_id, object_key, kind, content_type, byte_length, sha256)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
    ).bind(upload.evidence_id, batch.id, upload.object_key, upload.kind, upload.content_type, upload.expected_bytes, upload.expected_sha256),
    context.env.DB.prepare(
      "UPDATE capture_evidence_upload_attempts SET status = 'finalized', finalized_at = CURRENT_TIMESTAMP WHERE id = ?1",
    ).bind(upload.id),
  ]);
  return context.json({ ok: true, uploadSessionId: upload.id, evidenceId: upload.evidence_id, objectKey: upload.object_key }, 201);
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
  let bytes: Uint8Array;
  try {
    bytes = await decodeEvidenceUpload(
      new Uint8Array(await context.req.arrayBuffer()),
      context.req.header("content-encoding"),
      context.req.header("x-uncompressed-length"),
    );
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "invalid evidence upload", 422);
  }
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

app.put("/internal/capture-batches/:id/observation-partition", async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  const engineOwnedCapture = identity.role === "engine" && engineMayWriteCaptureSource(batch.source_id, batch.capture_method);
  if (identity.role !== "capture" && identity.role !== "operator" && !engineOwnedCapture) return jsonError("mutation role is not authorized for capture partitions", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
  if (batch.status !== "open") return jsonError("observation partitions can only be added to an open batch", 409);
  const expectedHash = context.req.header("x-content-sha256") ?? "";
  const rowCount = Number(context.req.header("x-row-count"));
  const minObservedAt = context.req.header("x-min-observed-at") ?? "";
  const maxObservedAt = context.req.header("x-max-observed-at") ?? "";
  const schemaVersion = Number(context.req.header("x-schema-version"));
  if (!/^[a-f0-9]{64}$/.test(expectedHash) || !Number.isSafeInteger(rowCount) || rowCount <= 0
    || schemaVersion !== 1 || !Number.isFinite(Date.parse(minObservedAt)) || !Number.isFinite(Date.parse(maxObservedAt))
    || minObservedAt < batch.captured_from || maxObservedAt > batch.captured_to || maxObservedAt < minObservedAt) {
    return jsonError("observation partition metadata is invalid or outside the batch interval", 422);
  }
  const bytes = new Uint8Array(await context.req.arrayBuffer());
  const parquetMagic = bytes.length >= 8 && new TextDecoder().decode(bytes.slice(0, 4)) === "PAR1"
    && new TextDecoder().decode(bytes.slice(-4)) === "PAR1";
  if (!parquetMagic) return jsonError("observation partition is not a complete Parquet file", 422);
  const actualHash = await digestHex(bytes);
  if (actualHash !== expectedHash) return jsonError("observation partition hash does not match content", 422);
  const existing = await context.env.DB.prepare(
    `SELECT partition.content_hash, object.object_key
       FROM observation_partitions partition JOIN object_store_objects object ON object.content_hash = partition.content_hash
      WHERE partition.batch_id = ?1`,
  ).bind(batch.id).first<{ content_hash: string; object_key: string }>();
  if (existing) {
    if (existing.content_hash !== actualHash) return jsonError("capture batch already has a different immutable observation partition", 409);
    return context.json({ ok: true, batchId: batch.id, objectKey: existing.object_key, sha256: actualHash, idempotent: true });
  }
  const partitionDate = minObservedAt.slice(0, 10);
  const objectKey = `observations/schema=1/store=${encodeURIComponent(batch.store_location_id)}/date=${partitionDate}/source=${encodeURIComponent(batch.source_id)}/${batch.id}-${actualHash}.parquet`;
  const object = await context.env.ARCHIVE.head(objectKey);
  if (!object) await context.env.ARCHIVE.put(objectKey, bytes, {
    httpMetadata: { contentType: "application/vnd.apache.parquet" },
    customMetadata: { sha256: actualHash, rows: String(rowCount), schema: "grocery-observation-v1", batchId: batch.id },
  });
  const stored = await context.env.ARCHIVE.head(objectKey);
  if (!stored || stored.size !== bytes.byteLength || stored.customMetadata?.sha256 !== actualHash) return jsonError("observation partition failed post-write verification", 500);
  await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT OR IGNORE INTO object_store_objects
         (content_hash, object_key, object_kind, format, byte_length, row_count, schema_version, verified_at)
       VALUES (?1, ?2, 'observation-partition', 'parquet', ?3, ?4, 1, CURRENT_TIMESTAMP)`,
    ).bind(actualHash, objectKey, stored.size, rowCount),
    context.env.DB.prepare(
      `INSERT INTO observation_partitions
         (batch_id, source_id, store_location_id, partition_date, content_hash, row_count, min_observed_at, max_observed_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
    ).bind(batch.id, batch.source_id, batch.store_location_id, partitionDate, actualHash, rowCount, minObservedAt, maxObservedAt),
  ]);
  return context.json({ ok: true, batchId: batch.id, objectKey, sha256: actualHash, byteLength: stored.size, rowCount }, 201);
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
  let parquetPartitionRows: number | null = null;
  if (batch.capture_method !== "legacy_bridge") {
    const partition = await context.env.DB.prepare(
      "SELECT row_count FROM observation_partitions WHERE batch_id = ?1",
    ).bind(batch.id).first<{ row_count: number }>();
    if (!partition) return jsonError("capture cannot seal before its immutable Parquet observation partition is verified", 422);
    parquetPartitionRows = partition.row_count;
    const hotRows = await context.env.DB.prepare(
      "SELECT COUNT(*) AS count FROM capture_batch_observations WHERE batch_id = ?1",
    ).bind(batch.id).first<{ count: number }>();
    if (partition.row_count !== (hotRows?.count ?? 0)) return jsonError("Parquet partition row count does not match the canonical capture batch", 422);
  }
  if (new Set(body.terms.map((term) => term.termKey)).size !== body.terms.length) return jsonError("capture term keys must be unique", 422);
  if (new Set(body.terms.map((term) => term.ordinal)).size !== body.terms.length) return jsonError("capture term ordinals must be unique", 422);
  if (batch.capture_method === "browser") {
    const workflowHeader = context.req.header("x-tc-validation-workflow");
    let workflowInstanceId = `capture-${batch.id}`.replace(/[^a-zA-Z0-9_-]/g, "-").slice(0, 100);
    if (!workflowHeader) {
      const sealJson = stableJson(body);
      const prior = await context.env.DB.prepare(
        `SELECT seal_json, status, result_status, attempts, workflow_instance_id, configuration_id, configuration_hash
           FROM capture_validation_jobs WHERE batch_id = ?1`,
      ).bind(batch.id).first<{ seal_json: string; status: string; result_status: string | null; attempts: number; workflow_instance_id: string; configuration_id: string | null; configuration_hash: string | null }>();
      if (prior && prior.seal_json !== sealJson) return jsonError("capture validation job is already bound to different seal content", 409);
      if (!prior) {
        const configuration = await context.env.DB.prepare(
          "SELECT id, content_hash FROM configuration_versions WHERE active = 1",
        ).first<{ id: string; content_hash: string }>();
        if (!configuration) return jsonError("active configuration not found", 422);
        await context.env.DB.prepare(
          `INSERT INTO capture_validation_jobs
             (batch_id, workflow_instance_id, requested_by, seal_json, status, configuration_id, configuration_hash)
           VALUES (?1, ?2, ?3, ?4, 'pending', ?5, ?6)`,
        ).bind(batch.id, workflowInstanceId, identity.agentId, sealJson, configuration.id, configuration.content_hash).run();
      } else if (!prior.configuration_id || !prior.configuration_hash) {
        return jsonError("capture validation job is missing its seal-time configuration pin", 409);
      } else if (prior.status === "failed") {
        workflowInstanceId = `${workflowInstanceId.slice(0, 80)}-retry-${prior.attempts + 1}`;
        await context.env.DB.prepare(
          `UPDATE capture_validation_jobs SET workflow_instance_id = ?2, requested_by = ?3, status = 'pending',
             result_status = NULL, error = NULL, completed_at = NULL WHERE batch_id = ?1`,
        ).bind(batch.id, workflowInstanceId, identity.agentId).run();
      } else {
        workflowInstanceId = prior.workflow_instance_id;
      }
      if (prior?.status === "completed") {
        return context.json({ ok: prior.result_status === "validated", batchId: batch.id, status: prior.result_status ?? "rejected", validationWorkflow: workflowInstanceId }, prior.result_status === "validated" ? 200 : 422);
      }
      if (!context.env.CAPTURE_VALIDATION_WORKFLOW) throw new Error("capture validation workflow binding is unavailable");
      try {
        await context.env.CAPTURE_VALIDATION_WORKFLOW.create({ id: workflowInstanceId, params: { batchId: batch.id } });
      } catch (error) {
        // A client retry races safely with the already-created deterministic instance.
        const message = error instanceof Error ? error.message : String(error);
        if (!/already|exist|duplicate|conflict/i.test(message)) throw error;
      }
      return context.json({ ok: true, batchId: batch.id, status: "validating", validationWorkflow: workflowInstanceId }, 202);
    }
    const job = await context.env.DB.prepare(
      "SELECT workflow_instance_id, seal_json FROM capture_validation_jobs WHERE batch_id = ?1",
    ).bind(batch.id).first<{ workflow_instance_id: string; seal_json: string }>();
    if (!job || job.workflow_instance_id !== workflowHeader || job.seal_json !== stableJson(body) || identity.role !== "operator") {
      return jsonError("capture validation workflow proof is invalid", 403);
    }
  }
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
    "SELECT COUNT(*) AS count FROM capture_batch_observations WHERE batch_id = ?1",
  ).bind(batch.id).first<{ count: number }>())?.count ?? 0;
  const parquetPartitionPass = batch.capture_method === "legacy_bridge" || parquetPartitionRows === observationCount;
  const taxonomyRows = batch.capture_method === "browser"
    ? (await context.env.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM capture_batch_observations member
         JOIN observations o ON o.id = member.observation_id
         JOIN product_versions pv ON pv.id = o.product_version_id
        WHERE member.batch_id = ?1 AND pv.taxonomy_path IS NOT NULL AND TRIM(pv.taxonomy_path) <> ''`,
    ).bind(batch.id).first<{ count: number }>())?.count ?? 0
    : 0;
  const predecessor = await context.env.DB.prepare(
    `SELECT prior.id, COUNT(o.observation_id) AS observation_count
       FROM capture_batches prior
       LEFT JOIN capture_batch_observations o ON o.batch_id = prior.id
      WHERE prior.source_id = ?1 AND prior.coverage_mode = ?2 AND prior.status IN ('validated','promoted') AND prior.id <> ?3
      GROUP BY prior.id, prior.captured_to
      ORDER BY prior.captured_to DESC LIMIT 1`,
  ).bind(batch.source_id, batch.coverage_mode, batch.id).first<{ id: string; observation_count: number }>();
  let collapseFloor = predecessor ? Math.ceil(predecessor.observation_count * 0.6) : 0;
  let collapsePass = !predecessor || observationCount >= collapseFloor;
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
    "SELECT object_key, kind, sha256, byte_length FROM evidence_objects WHERE batch_id = ?1 ORDER BY id",
  ).bind(batch.id).all<{ object_key: string; kind: string; sha256: string; byte_length: number }>();
  const captureTermsSha256 = await digestHex(stableJson(body.terms));
  const browserEvidence = batch.capture_method === "browser"
    ? await validateBrowserCaptureEvidence(context.env.EVIDENCE, {
      sourceId: batch.source_id,
      coverageMode: batch.coverage_mode,
      capturedFrom: batch.captured_from,
      capturedTo: batch.captured_to,
      expectedTerms: batch.expected_terms,
    }, evidenceRows.results, body.browserEvidenceAttestation, captureTermsSha256)
    : { pass: true, detail: { required: false }, metrics: null };
  if (batch.capture_method === "browser" && predecessor && browserEvidence.metrics) {
    const priorDiscovery = await context.env.DB.prepare(
      "SELECT discovery_rows FROM browser_capture_metrics WHERE batch_id = ?1",
    ).bind(predecessor.id).first<{ discovery_rows: number }>();
    if (priorDiscovery && priorDiscovery.discovery_rows > 0) {
      collapseFloor = Math.ceil(priorDiscovery.discovery_rows * 0.6);
      collapsePass = browserEvidence.metrics.discoveryRows >= collapseFloor;
    }
  }
  const captureSemanticsRequired = requiresCaptureHistoryAssessment(batch.capture_method, batch.captured_to);
  const priceSemantics = await context.env.DB.prepare(
    `SELECT COUNT(*) AS eligible,
            SUM(CASE WHEN json_extract(price_semantics_json, '$.ambiguity') = 0
                      AND json_extract(price_semantics_json, '$.unitPriceMinor') = purchase_price_minor
                      AND json_extract(price_semantics_json, '$.qualifyingQuantity') >= 1
                      AND ABS(json_extract(price_semantics_json, '$.totalPriceMinor')
                          - purchase_price_minor * json_extract(price_semantics_json, '$.qualifyingQuantity')) <= 1
                     THEN 1 ELSE 0 END) AS examined
       FROM capture_batch_observations member
       JOIN observations ON observations.id = member.observation_id
      WHERE member.batch_id = ?1`,
  ).bind(batch.id).first<{ eligible: number; examined: number | null }>();
  const priceSemanticsEligible = priceSemantics?.eligible ?? 0;
  const priceSemanticsExamined = priceSemantics?.examined ?? 0;
  const priceSemanticsPass = !captureSemanticsRequired || (priceSemanticsEligible > 0 && priceSemanticsExamined === priceSemanticsEligible);

  // Producers validate this shape before upload, but the seal owns the trust
  // boundary. Re-read the immutable rows and prove that source-native offer
  // identity, price, size, timestamp, and denormalized availability agree with
  // the canonical observation before the batch can become visible.
  const offerSnapshotRequired = batch.capture_method !== "legacy_bridge"
    && Date.parse(batch.captured_to) >= Date.parse(OFFER_SNAPSHOT_CUTOVER);
  const offerSnapshots = offerSnapshotRequired ? await context.env.DB.prepare(
    `SELECT COUNT(*) AS eligible,
            SUM(CASE WHEN json_extract(o.offer_snapshot_json, '$.version') = 1
                      AND json_extract(o.offer_snapshot_json, '$.retailerProductId') = p.external_key
                      AND json_extract(o.offer_snapshot_json, '$.productName') = pv.name
                      AND json_extract(o.offer_snapshot_json, '$.sizeText') = pv.size_text
                      AND TRIM(json_extract(o.offer_snapshot_json, '$.sizeText')) <> ''
                      AND json_extract(o.offer_snapshot_json, '$.purchasePriceMinor') = o.purchase_price_minor
                      AND json_extract(o.offer_snapshot_json, '$.priceSemantics.unitPriceMinor') = o.purchase_price_minor
                      AND COALESCE(json_extract(member.provenance_json, '$.offerSnapshot.observedAt'), json_extract(o.offer_snapshot_json, '$.observedAt')) = member.observed_at
                      AND LENGTH(TRIM(json_extract(o.offer_snapshot_json, '$.rawPriceText'))) > 0
                      AND LENGTH(TRIM(json_extract(o.offer_snapshot_json, '$.sourceUrl'))) > 0
                      AND json_extract(o.offer_snapshot_json, '$.availability.status') = o.availability_status
                      AND json_extract(o.offer_snapshot_json, '$.availability.fulfillmentMode') = o.fulfillment_mode
                      AND (o.seller_name IS NULL OR json_extract(o.offer_snapshot_json, '$.sellerName') = o.seller_name)
                     THEN 1 ELSE 0 END) AS examined
       FROM capture_observation_memberships member
       JOIN observations o ON o.id = member.observation_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
      WHERE member.batch_id = ?1`,
  ).bind(batch.id).first<{ eligible: number; examined: number | null }>() : { eligible: 0, examined: 0 };
  const offerSnapshotEligible = offerSnapshots?.eligible ?? 0;
  const offerSnapshotExamined = offerSnapshots?.examined ?? 0;
  const offerSnapshotPass = !offerSnapshotRequired
    || (offerSnapshotEligible > 0 && offerSnapshotExamined === offerSnapshotEligible);

  const historyRows = captureSemanticsRequired ? await context.env.DB.prepare(
    `WITH current_rows AS (
       SELECT p.id AS product_id, p.external_key,
              o.id AS current_observation_id, pv.name AS current_name, pv.size_text AS current_size_text,
              o.per_unit_micros AS current_per_unit_micros, o.normalized_basis_unit AS current_basis_unit,
              o.normalized_basis_qty_micros AS current_basis_qty_micros, pv.identity_json AS current_identity_json,
              member.observed_at AS current_captured_at
         FROM capture_batch_observations member
         JOIN observations o ON o.id = member.observation_id
         JOIN product_versions pv ON pv.id = o.product_version_id
         JOIN products p ON p.id = pv.product_id WHERE member.batch_id = ?1
     ), prior_ranked AS (
       SELECT pv.product_id, o.id AS prior_observation_id, pv.name AS prior_name, pv.size_text AS prior_size_text,
              o.per_unit_micros AS prior_per_unit_micros, o.normalized_basis_unit AS prior_basis_unit,
              o.normalized_basis_qty_micros AS prior_basis_qty_micros, pv.identity_json AS prior_identity_json,
              prior_member.observed_at AS prior_captured_at,
              ROW_NUMBER() OVER (PARTITION BY pv.product_id ORDER BY prior_member.observed_at DESC) AS history_rank
         FROM capture_batch_observations prior_member
         JOIN observations o ON o.id = prior_member.observation_id
         JOIN product_versions pv ON pv.id = o.product_version_id
         JOIN capture_batches b ON b.id = prior_member.batch_id
        WHERE prior_member.batch_id <> ?1 AND b.status IN ('validated','promoted','superseded')
          AND pv.product_id IN (SELECT DISTINCT product_id FROM current_rows)
          AND prior_member.observed_at < (SELECT MAX(current_captured_at) FROM current_rows)
     )
     SELECT current_rows.product_id, current_rows.external_key, current_rows.current_observation_id,
            current_rows.current_name, current_rows.current_size_text, current_rows.current_per_unit_micros,
            current_rows.current_basis_unit, current_rows.current_basis_qty_micros, current_rows.current_identity_json,
            prior_ranked.prior_observation_id, prior_ranked.prior_name, prior_ranked.prior_size_text,
            prior_ranked.prior_per_unit_micros, prior_ranked.prior_basis_unit, prior_ranked.prior_basis_qty_micros,
            prior_ranked.prior_identity_json
       FROM current_rows LEFT JOIN prior_ranked ON prior_ranked.product_id = current_rows.product_id
        AND prior_ranked.history_rank = 1 AND prior_ranked.prior_captured_at < current_rows.current_captured_at`,
  ).bind(batch.id).all<ProductHistoryRow>() : { results: [] as ProductHistoryRow[] };
  const historyAssessment = assessProductHistory(historyRows.results);
  const skuIdentityPass = !captureSemanticsRequired || historyAssessment.identityFindings.length === 0;
  const changePointPass = !captureSemanticsRequired || historyAssessment.changePointFindings.length === 0;

  const sourceSchemaRequired = captureSemanticsRequired && batch.capture_method !== "browser";
  const priorSchema = sourceSchemaRequired ? await context.env.DB.prepare(
    `SELECT source_contract_fingerprint FROM capture_batches
      WHERE source_id = ?1 AND id <> ?2 AND status IN ('validated','promoted','superseded')
        AND source_contract_fingerprint IS NOT NULL
      ORDER BY captured_to DESC LIMIT 1`,
  ).bind(batch.source_id, batch.id).first<{ source_contract_fingerprint: string }>() : null;
  const schemaAssessment = assessSourceSchema(batch.source_contract_fingerprint, priorSchema?.source_contract_fingerprint ?? null, sourceSchemaRequired);
  const status = identityPass && completePass && collapsePass && freshnessPass && browserEvidence.pass && parquetPartitionPass
    && priceSemanticsPass && offerSnapshotPass && skuIdentityPass && changePointPass && schemaAssessment.pass ? "validated" : "rejected";
  // Capture terms are staged while the batch is still private/open. Run each packed
  // insert separately so a full catalog cannot make one D1 transaction exceed its
  // aggregate execution ceiling. The UPSERT makes a retry safe after any partial
  // staging failure. Only the final status/metrics/guards transition is atomic.
  try {
    for (const insert of buildCaptureTermInserts(batch.id, body.terms)) {
      await context.env.DB.prepare(insert.sql).bind(...insert.bindings).run();
    }
    const persistedTerms = await context.env.DB.prepare(
      "SELECT COUNT(*) AS count FROM capture_terms WHERE batch_id = ?1",
    ).bind(batch.id).first<{ count: number }>();
    if ((persistedTerms?.count ?? 0) !== body.terms.length) {
      throw new Error(`capture term staging count mismatch: expected ${body.terms.length}, stored ${persistedTerms?.count ?? 0}`);
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : "unknown D1 term staging failure";
    console.error("capture seal term staging failed", { batchId: batch.id, sourceId: batch.source_id, termCount: body.terms.length, detail });
    return jsonError(`capture seal term staging failed: ${detail}`, 500);
  }
  const statements: D1PreparedStatement[] = [];
  statements.push(context.env.DB.prepare(
    `UPDATE capture_batches SET status = ?2, attempted_terms = ?3, successful_terms = ?4, empty_terms = ?5,
       rejected_terms = ?6, blocked_terms = ?7, captured_pages = ?8, evidence_manifest_key = ?9,
       validation_summary_json = ?10, sealed_at = CURRENT_TIMESTAMP WHERE id = ?1`,
  ).bind(batch.id, status, attempted, successful, empty, rejected, blocked, capturedPages, body.evidenceManifestKey ?? null, stableJson({ identityPass, termEnvelopePass, pageEnvelopePass, collapsePass, freshnessPass, parquetPartitionPass, browserEvidencePass: browserEvidence.pass, browserEvidence: browserEvidence.detail, priceSemanticsPass, offerSnapshotPass, skuIdentityPass, changePointPass, sourceSchemaPass: schemaAssessment.pass, sourceSchema: schemaAssessment.detail, captureAgeMillis, maxAgeDays: batch.max_age_days, observationCount, predecessorBatchId: predecessor?.id ?? null, predecessorObservationCount: predecessor?.observation_count ?? null, collapseFloor })));
  if (browserEvidence.metrics) {
    const metrics = browserEvidence.metrics;
    statements.push(context.env.DB.prepare(
      `INSERT INTO browser_capture_metrics (
         batch_id, session_id, source_id, cycle_start, coverage_mode,
         expected_terms, attempted_terms, success_terms, empty_terms, rejected_terms,
         blocked_terms, not_attempted_terms, retry_count, chunk_count, duration_ms,
         term_duration_p50_ms, term_duration_p95_ms, projected_rows, observation_count, taxonomy_rows,
         accuracy_policy_version, discovery_rows, required_verification_rows, matched_verification_rows,
         unresolved_verification_rows, price_agreement_rows, single_channel_rows, anomaly_rows, retrieval_complete_terms,
         page_state_attested_rows, promotion_semantics_rows, unique_products, discovery_edges,
         duplicate_product_references, product_reads_required, verification_reuse, immutable_shard_count,
         daily_shard_count, likely_winner_rows, confirmed_winner_rows
       ) VALUES (
         ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
         ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20,
         ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31,
         ?32, ?33, ?34, ?35, ?36, ?37, ?38, ?39, ?40
       )`,
    ).bind(
      batch.id, metrics.sessionId, metrics.sourceId, metrics.cycleStart, metrics.coverageMode,
      metrics.expectedTerms, metrics.attemptedTerms, metrics.successTerms, metrics.emptyTerms, metrics.rejectedTerms,
      metrics.blockedTerms, metrics.notAttemptedTerms, metrics.retryCount, metrics.chunkCount, metrics.durationMs,
      metrics.termDurationP50Ms, metrics.termDurationP95Ms, metrics.projectedRows, observationCount, taxonomyRows,
      metrics.accuracyPolicyVersion, metrics.discoveryRows, metrics.requiredVerificationRows, metrics.matchedVerificationRows,
      metrics.unresolvedVerificationRows, metrics.priceAgreementRows, metrics.singleChannelRows, metrics.anomalyRows, metrics.retrievalCompleteTerms,
      metrics.pageStateAttestedRows, metrics.promotionSemanticsRows,
      metrics.uniqueProducts ?? 0, metrics.discoveryEdges ?? 0, metrics.duplicateProductReferences ?? 0,
      metrics.productReadsRequired ?? 0, metrics.verificationReuse ?? 0, metrics.immutableShardCount ?? 0,
      metrics.dailyShardCount, metrics.likelyWinnerRows, metrics.confirmedWinnerRows,
    ));
    for (const shard of body.browserEvidenceAttestation?.dailyShards ?? []) statements.push(context.env.DB.prepare(
      `INSERT INTO browser_capture_shards
         (batch_id, shard_date, ordinal, content_hash, term_count, row_count, chunk_count, first_observed_at, last_observed_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
    ).bind(batch.id, shard.date, shard.ordinal, shard.contentHash, shard.termCount, shard.rowCount, shard.chunkCount, shard.firstObservedAt, shard.lastObservedAt));
    const confirmations = body.browserEvidenceAttestation?.offerConfirmations ?? [];
    for (let offset = 0; offset < confirmations.length; offset += 14) {
      const confirmationChunk = confirmations.slice(offset, offset + 14);
      statements.push(context.env.DB.prepare(
        `INSERT INTO capture_offer_confirmations
           (batch_id, product_key, discovery_hash, purchase_price_minor, discovered_at, confirmed_at, confirmation_kind)
         VALUES ${confirmationChunk.map(() => "(?, ?, ?, ?, ?, ?, 'browser-independent-read')").join(", ")}`,
      ).bind(...confirmationChunk.flatMap((confirmation) => [batch.id, confirmation.productKey, confirmation.discoveryHash, confirmation.purchasePriceMinor, confirmation.discoveredAt, confirmation.confirmedAt])));
    }
  }
  for (const [guardId, pass, eligible, examined, detail] of [
    ["batch-parquet-partition", parquetPartitionPass, batch.capture_method === "legacy_bridge" ? 0 : observationCount, batch.capture_method === "legacy_bridge" ? 0 : (parquetPartitionRows ?? 0), { required: batch.capture_method !== "legacy_bridge", rows: parquetPartitionRows }],
    ["batch-location", identityPass, 3, 3, {}],
    ["batch-completeness", completePass, (batch.expected_terms ?? 0) + (batch.expected_pages ?? 0), attempted + capturedPages, {}],
    ["batch-collapse", collapsePass, predecessor ? 2 : 0, predecessor ? 2 : 0, { observationCount, predecessorBatchId: predecessor?.id ?? null, predecessorObservationCount: predecessor?.observation_count ?? null, collapseFloor }],
    ["batch-freshness", freshnessPass, 1, 1, { capturedTo: batch.captured_to, captureAgeMillis, maxAgeDays: batch.max_age_days }],
    ["batch-browser-evidence", browserEvidence.pass, batch.capture_method === "browser" ? 3 : 0, batch.capture_method === "browser" ? 3 : 0, browserEvidence.detail],
    ["batch-browser-accuracy", batch.capture_method !== "browser" || browserEvidence.detail.accuracyPass === true, batch.capture_method === "browser" ? 10 : 0, batch.capture_method === "browser" ? 10 : 0, browserEvidence.detail],
    ["batch-price-semantics", priceSemanticsPass, captureSemanticsRequired ? priceSemanticsEligible : 0, captureSemanticsRequired ? priceSemanticsExamined : 0, { required: captureSemanticsRequired, eligible: priceSemanticsEligible, examined: priceSemanticsExamined }],
    ["batch-offer-snapshot", offerSnapshotPass, offerSnapshotRequired ? offerSnapshotEligible : 0, offerSnapshotRequired ? offerSnapshotExamined : 0, { required: offerSnapshotRequired, eligible: offerSnapshotEligible, examined: offerSnapshotExamined }],
    ["batch-sku-identity", skuIdentityPass, captureSemanticsRequired ? historyRows.results.length : 0, captureSemanticsRequired ? historyRows.results.length : 0, { required: captureSemanticsRequired, findingCount: historyAssessment.identityFindings.length, findings: historyAssessment.identityFindings.slice(0, 200) }],
    ["batch-change-point", changePointPass, captureSemanticsRequired ? historyRows.results.length : 0, captureSemanticsRequired ? historyRows.results.length : 0, { required: captureSemanticsRequired, findingCount: historyAssessment.changePointFindings.length, findings: historyAssessment.changePointFindings.slice(0, 200) }],
    ["batch-source-schema", schemaAssessment.pass, sourceSchemaRequired ? 1 : 0, sourceSchemaRequired ? 1 : 0, { ...schemaAssessment.detail, currentShapeFingerprint: batch.source_shape_fingerprint }],
  ] as const) {
    const resultId = await deterministicId("guard", batch.id, guardId);
    statements.push(context.env.DB.prepare(
      `INSERT INTO guard_results (id, guard_id, batch_id, status, eligible_count, examined_count, finding_count, detail_json)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
    ).bind(resultId, guardId, batch.id, pass ? "pass" : "fail", eligible, Math.min(eligible, examined), pass ? 0 : 1, stableJson(detail)));
    if (!pass) {
      const findingId = await deterministicId("finding", resultId, "capture-rejected");
      const message = `${guardId} rejected capture ${batch.id}`;
      statements.push(context.env.DB.prepare(
        `INSERT INTO guard_findings (id, result_id, finding_key, message, evidence_json)
         VALUES (?1, ?2, 'capture-rejected', ?3, ?4)`,
      ).bind(findingId, resultId, message, stableJson(detail)));
      const triageId = await deterministicId("triage", "guard_finding", findingId);
      statements.push(context.env.DB.prepare(
        `INSERT INTO triage_items (id, source_kind, source_ref, severity, status, title, evidence_json)
         VALUES (?1, 'guard_finding', ?2, 'hard', 'open', ?3, ?4)
         ON CONFLICT(source_ref) DO UPDATE SET
           status = CASE WHEN triage_items.status = 'resolved' THEN 'open' ELSE triage_items.status END,
           title = excluded.title, evidence_json = excluded.evidence_json, updated_at = CURRENT_TIMESTAMP, resolved_at = NULL`,
      ).bind(triageId, findingId, message, stableJson({ batchId: batch.id, sourceId: batch.source_id, guardId, detail })));
    }
  }
  try {
    await context.env.DB.batch(statements);
  } catch (error) {
    const detail = error instanceof Error ? error.message : "unknown D1 finalization failure";
    console.error("capture seal finalization failed", { batchId: batch.id, sourceId: batch.source_id, statementCount: statements.length, detail });
    return jsonError(`capture seal finalization failed: ${detail}`, 500);
  }
  return context.json({ ok: status === "validated", batchId: batch.id, status, counts: { attempted, successful, empty, rejected, blocked, capturedPages } }, status === "validated" ? 200 : 422);
});

app.get("/internal/capture-batches/promoted", async (context) => {
  const identity = context.get("identity");
  if (identity.role !== "engine" && identity.role !== "operator") return jsonError("mutation role is not authorized to list promoted batches", 403);
  const observedAt = new Date().toISOString();
  const batches = await context.env.DB.prepare(
    `WITH ranked AS (
       SELECT id, source_id, coverage_mode, captured_to,
              ROW_NUMBER() OVER (PARTITION BY source_id ORDER BY captured_to DESC, promoted_at DESC, id DESC) AS ordinal
         FROM capture_batches
        WHERE status IN ('promoted','superseded')
          AND (valid_from IS NULL OR valid_from <= ?1)
          AND (valid_to IS NULL OR valid_to > ?1)
     ), selected AS (
       SELECT * FROM ranked WHERE ordinal = 1
     ), ranked_runs AS (
       SELECT run.batch_id, run.matched_count,
              ROW_NUMBER() OVER (PARTITION BY run.batch_id ORDER BY run.created_at DESC, run.id DESC) AS ordinal
         FROM match_runs run JOIN configuration_versions configuration ON configuration.id = run.configuration_id
        WHERE run.status = 'passed' AND configuration.active = 1
     ), active_counts AS (
       SELECT selected.id AS batch_id,
              COUNT(DISTINCT CASE WHEN decision.product_id IS NOT NULL THEN product.id END) AS matched_count
         FROM selected
         LEFT JOIN capture_batch_observations member ON member.batch_id = selected.id
         LEFT JOIN observations observation ON observation.id = member.observation_id
         LEFT JOIN product_versions version ON version.id = observation.product_version_id
         LEFT JOIN products product ON product.id = version.product_id
         LEFT JOIN match_decisions decision ON decision.product_id = product.id
          AND decision.configuration_id = (SELECT id FROM configuration_versions WHERE active = 1)
          AND decision.superseded_at IS NULL
        GROUP BY selected.id
     )
     SELECT ranked.id, ranked.source_id, source.store_location_id, ranked.coverage_mode, ranked.captured_to,
            CASE WHEN run.batch_id IS NOT NULL AND run.matched_count = active_counts.matched_count THEN 1 ELSE 0 END AS has_active_match
       FROM selected ranked JOIN capture_sources source ON source.id = ranked.source_id
       LEFT JOIN ranked_runs run ON run.batch_id = ranked.id AND run.ordinal = 1
       LEFT JOIN active_counts ON active_counts.batch_id = ranked.id
      ORDER BY source_id`,
  ).bind(observedAt).all();
  return context.json({ ok: true, batches: batches.results });
});

app.get("/internal/capture-batches/ready-browser", async (context) => {
  const identity = context.get("identity");
  if (identity.role !== "engine" && identity.role !== "operator") return jsonError("mutation role is not authorized to select promotion candidates", 403);
  const rows = await context.env.DB.prepare(
    `SELECT batch.id, batch.source_id, batch.captured_to, batch.coverage_mode,
            COUNT(observation.observation_id) AS observation_count
       FROM capture_batches batch
       JOIN capture_sources source ON source.id = batch.source_id
       LEFT JOIN capture_batch_observations observation ON observation.batch_id = batch.id
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
  const inactiveDecisionReconciliation = await reconcileInactiveConfigurationDecisions(context.env.DB);
  return context.json({ ok: true, batchId: batch.id, status: "promoted", superseded: previous.results.map((row) => row.id), idempotent: false, inactiveDecisionReconciliation });
});

app.post("/internal/releases", zValidator("json", releaseCreateSchema), async (context) => {
  const requested = context.req.valid("json");
  const expectedInputHash = await digestHex(stableJson({ inputManifest: requested.inputManifest, inputBatchIds: requested.inputBatchIds }));
  if (expectedInputHash !== requested.inputHash) return jsonError("release input hash does not bind the manifest and promoted batch snapshot", 422);
  const configuration = await context.env.DB.prepare(
    "SELECT active FROM configuration_versions WHERE id = ?1",
  ).bind(requested.configurationId).first<{ active: number }>();
  if (!configuration || configuration.active !== 1) return jsonError("release configuration is not active", 422);
  const snapshotObservedAt = requested.snapshotObservedAt ?? new Date().toISOString();
  const batches = await Promise.all(requested.inputBatchIds.map((batchId) => context.env.DB.prepare(
    `SELECT b.id, b.status, b.valid_from, b.valid_to, l.market_id
       FROM capture_batches b
       JOIN capture_sources s ON s.id = b.source_id
       JOIN store_locations l ON l.id = s.store_location_id
      WHERE b.id = ?1`,
  ).bind(batchId).first<{ id: string; status: string; valid_from: string | null; valid_to: string | null; market_id: string }>()));
  const invalidBatches = requested.inputBatchIds.filter((_batchId, index) => {
    const batch = batches[index];
    return !batch
      || !["promoted", "superseded"].includes(batch.status)
      || batch.market_id !== requested.marketId
      || (batch.valid_from !== null && batch.valid_from > snapshotObservedAt)
      || (batch.valid_to !== null && batch.valid_to <= snapshotObservedAt);
  });
  if (invalidBatches.length > 0) return jsonError(`release snapshot includes missing, ineligible, or wrong-market batches at ${snapshotObservedAt}: ${invalidBatches.join(", ")}`, 422);
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

app.put("/internal/releases/:id/graph-nodes", async (context) => {
  const releaseId = context.req.param("id");
  const stateError = await requireDraftRelease(context.env.DB, releaseId);
  if (stateError) return stateError;
  const body = await context.req.json<{ nodes?: unknown[] }>().catch(() => ({} as { nodes?: unknown[] }));
  if (!Array.isArray(body.nodes) || body.nodes.length < 1 || body.nodes.length > 100) return jsonError("release graph node chunk must contain 1-100 nodes", 422);
  const current = await context.env.DB.prepare(
    `SELECT current.release_id FROM current_releases current
       JOIN releases draft ON draft.market_id = current.market_id WHERE draft.id = ?1`,
  ).bind(releaseId).first<{ release_id: string }>();
  const prepared: Array<{
    kind: string; key: string; dependencyHash: string; contentHash: string; bytes: Uint8Array;
    objectKey: string; reusedFrom: string | null; alreadyStored: boolean; globallyStored: boolean;
  }> = [];
  for (const raw of body.nodes) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return jsonError("release graph node is invalid", 422);
    const value = raw as Record<string, unknown>;
    const kind = String(value.kind ?? "");
    const key = String(value.key ?? "");
    const dependencyHash = String(value.dependencyHash ?? "");
    const contentHash = String(value.contentHash ?? "");
    if (!/^(cell|recipe|payload|top5|free-rotation)$/.test(kind) || !key || key.length > 500
      || !/^[a-f0-9]{64}$/.test(dependencyHash) || !/^[a-f0-9]{64}$/.test(contentHash)) return jsonError("release graph node identity is invalid", 422);
    const serialized = stableJson(value.payload);
    if (await digestHex(serialized) !== contentHash) return jsonError(`release graph node content hash mismatch: ${kind}/${key}`, 422);
    const bytes = new TextEncoder().encode(serialized);
    const objectKey = `release-nodes/schema=1/kind=${kind}/prefix=${contentHash.slice(0, 2)}/${contentHash}.json`;
    prepared.push({ kind, key, dependencyHash, contentHash, bytes, objectKey,
      reusedFrom: null, alreadyStored: false, globallyStored: false });
  }
  const requested = stableJson(prepared.map((item) => ({
    kind: item.kind, key: item.key, dependencyHash: item.dependencyHash, contentHash: item.contentHash,
  })));
  const matches = await context.env.DB.prepare(
    `WITH requested AS (
       SELECT json_extract(value, '$.kind') AS kind, json_extract(value, '$.key') AS node_key,
              json_extract(value, '$.dependencyHash') AS dependency_hash,
              json_extract(value, '$.contentHash') AS content_hash
         FROM json_each(?1)
     )
     SELECT node.release_id, node.node_kind, node.node_key,
            CASE WHEN node.release_id = ?2 THEN 'draft' ELSE 'prior' END AS scope
       FROM requested JOIN release_graph_nodes node
         ON node.node_kind = requested.kind AND node.node_key = requested.node_key
        AND node.dependency_hash = requested.dependency_hash AND node.content_hash = requested.content_hash
      WHERE node.release_id = ?2 OR node.release_id = ?3`,
  ).bind(requested, releaseId, current?.release_id ?? "").all<{
    release_id: string; node_kind: string; node_key: string; scope: "draft" | "prior";
  }>();
  const matchByNode = new Map<string, typeof matches.results[number]>();
  for (const match of matches.results) {
    const matchKey = `${match.node_kind}\u0000${match.node_key}`;
    if (!matchByNode.has(matchKey) || match.scope === "draft") matchByNode.set(matchKey, match);
  }
  for (const item of prepared) {
    const match = matchByNode.get(`${item.kind}\u0000${item.key}`);
    item.alreadyStored = match?.scope === "draft";
    item.reusedFrom = match?.scope === "prior" ? match.release_id : null;
  }
  const globalObjects = await context.env.DB.prepare(
    `SELECT content_hash FROM object_store_objects
      WHERE content_hash IN (SELECT value FROM json_each(?1))`,
  ).bind(stableJson(prepared.map((item) => item.contentHash))).all<{ content_hash: string }>();
  const globallyStored = new Set(globalObjects.results.map((item) => item.content_hash));
  for (const item of prepared) item.globallyStored = globallyStored.has(item.contentHash);
  const pendingUploads = prepared.filter((item) => !item.alreadyStored && !item.reusedFrom && !item.globallyStored);
  for (let offset = 0; offset < pendingUploads.length; offset += 20) {
    await Promise.all(pendingUploads.slice(offset, offset + 20).map(async (item) => {
      if (await context.env.ARCHIVE.head(item.objectKey)) return;
      await context.env.ARCHIVE.put(item.objectKey, item.bytes, {
        httpMetadata: { contentType: "application/json; charset=utf-8" },
        customMetadata: { sha256: item.contentHash, schema: "release-node-v1", kind: item.kind },
      });
    }));
  }
  const statements: D1PreparedStatement[] = [];
  for (const item of prepared) {
    if (!item.alreadyStored && !item.reusedFrom && !item.globallyStored) {
      const stored = await context.env.ARCHIVE.head(item.objectKey);
      if (!stored || stored.size !== item.bytes.byteLength || stored.customMetadata?.sha256 !== item.contentHash) return jsonError(`release graph node failed verification: ${item.kind}/${item.key}`, 500);
      statements.push(context.env.DB.prepare(
        `INSERT OR IGNORE INTO object_store_objects
           (content_hash, object_key, object_kind, format, byte_length, schema_version, verified_at)
         VALUES (?1, ?2, 'release-node', 'json', ?3, 1, CURRENT_TIMESTAMP)`,
      ).bind(item.contentHash, item.objectKey, stored.size));
    }
    statements.push(context.env.DB.prepare(
      `INSERT INTO release_graph_nodes
         (release_id, node_kind, node_key, dependency_hash, content_hash, payload_json, reused_from_release_id)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
       ON CONFLICT(release_id, node_kind, node_key) DO UPDATE SET
         dependency_hash = excluded.dependency_hash, content_hash = excluded.content_hash,
         payload_json = excluded.payload_json, reused_from_release_id = excluded.reused_from_release_id`,
    ).bind(releaseId, item.kind, item.key, item.dependencyHash, item.contentHash,
      new TextDecoder().decode(item.bytes), item.reusedFrom));
  }
  for (let offset = 0; offset < statements.length; offset += 80) await context.env.DB.batch(statements.slice(offset, offset + 80));
  return context.json({ ok: true, accepted: prepared.length,
    reused: prepared.filter((item) => item.reusedFrom).length,
    resumed: prepared.filter((item) => item.alreadyStored).length,
    contentAddressedHits: prepared.filter((item) => item.globallyStored).length });
});

app.post("/internal/releases/:id/graph-finalize", async (context) => {
  const releaseId = context.req.param("id");
  const stateError = await requireDraftRelease(context.env.DB, releaseId);
  if (stateError) return stateError;
  const body = await context.req.json<Record<string, unknown>>().catch(() => ({} as Record<string, unknown>));
  const dependencyHash = String(body.dependencyHash ?? "");
  const parentReleaseId = body.parentReleaseId ? String(body.parentReleaseId) : null;
  if (!/^[a-f0-9]{64}$/.test(dependencyHash)) return jsonError("release graph dependency hash is invalid", 422);
  const release = await context.env.DB.prepare("SELECT market_id, input_hash FROM releases WHERE id = ?1").bind(releaseId).first<{ market_id: string; input_hash: string }>();
  if (!release) return jsonError("release not found", 404);
  const current = await context.env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = ?1").bind(release.market_id).first<{ release_id: string }>();
  if ((current?.release_id ?? null) !== parentReleaseId) return jsonError("release graph parent is no longer the promoted release", 409);
  const rows = await context.env.DB.prepare(
    `SELECT node_kind, node_key, dependency_hash, content_hash, reused_from_release_id
       FROM release_graph_nodes WHERE release_id = ?1 ORDER BY node_kind, node_key`,
  ).bind(releaseId).all<{ node_kind: string; node_key: string; dependency_hash: string; content_hash: string; reused_from_release_id: string | null }>();
  if (rows.results.length === 0) return jsonError("release graph has no nodes", 422);
  const manifest = { version: 1, releaseId, parentReleaseId, inputHash: release.input_hash, dependencyHash, nodes: rows.results.map((row) => ({
    kind: row.node_kind, key: row.node_key, dependencyHash: row.dependency_hash, contentHash: row.content_hash,
  })) };
  const serialized = stableJson(manifest);
  const rootHash = await digestHex(serialized);
  const bytes = new TextEncoder().encode(serialized);
  const objectKey = `release-manifests/schema=1/market=${release.market_id}/${releaseId}-${rootHash}.json`;
  await context.env.ARCHIVE.put(objectKey, bytes, {
    httpMetadata: { contentType: "application/json; charset=utf-8" },
    customMetadata: { sha256: rootHash, schema: "release-manifest-v1", releaseId },
  });
  const stored = await context.env.ARCHIVE.head(objectKey);
  if (!stored || stored.size !== bytes.byteLength || stored.customMetadata?.sha256 !== rootHash) return jsonError("release graph manifest failed post-write verification", 500);
  const reused = rows.results.filter((row) => row.reused_from_release_id).length;
  await context.env.DB.batch([
    context.env.DB.prepare(
      `INSERT OR IGNORE INTO object_store_objects
         (content_hash, object_key, object_kind, format, byte_length, row_count, schema_version, verified_at)
       VALUES (?1, ?2, 'release-manifest', 'json', ?3, ?4, 1, CURRENT_TIMESTAMP)`,
    ).bind(rootHash, objectKey, stored.size, rows.results.length),
    context.env.DB.prepare(
      `INSERT INTO release_graphs
         (release_id, parent_release_id, root_hash, object_key, node_count, changed_node_count, reused_node_count, dependency_hash, byte_length, finalized_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, CURRENT_TIMESTAMP)
       ON CONFLICT(release_id) DO UPDATE SET root_hash = excluded.root_hash, object_key = excluded.object_key,
         node_count = excluded.node_count, changed_node_count = excluded.changed_node_count,
         reused_node_count = excluded.reused_node_count, dependency_hash = excluded.dependency_hash,
         byte_length = excluded.byte_length, finalized_at = excluded.finalized_at`,
    ).bind(releaseId, parentReleaseId, rootHash, objectKey, rows.results.length, rows.results.length - reused, reused, dependencyHash, stored.size),
  ]);
  return context.json({ ok: true, releaseId, rootHash, objectKey, nodes: rows.results.length, changed: rows.results.length - reused, reused });
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
  const objectKey = releasePayloadObjectKey(releaseId, body.kind, body.contentHash);
  const existing = await context.env.EVIDENCE.head(objectKey);
  if (!existing) {
    await context.env.EVIDENCE.put(objectKey, bytes, {
      httpMetadata: { contentType: "application/json; charset=utf-8" },
      customMetadata: { sha256: body.contentHash, kind: body.kind, schema: "release-payload-v2" },
    });
  } else if (existing.size !== bytes.byteLength || existing.customMetadata?.sha256 !== body.contentHash) {
    return jsonError(`content-addressed ${body.kind} payload verification failed`, 500);
  }
  await context.env.DB.prepare(
    `INSERT INTO release_payloads (release_id, kind, payload_json, content_hash, object_key, byte_length)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT(release_id, kind) DO UPDATE SET
       payload_json = excluded.payload_json,
       content_hash = excluded.content_hash,
       object_key = excluded.object_key,
       byte_length = excluded.byte_length`,
  ).bind(releaseId, body.kind, '{}', body.contentHash, objectKey, bytes.byteLength).run();
  return context.json({ ok: true, storage: "object", byteLength: bytes.byteLength });
});

app.post("/internal/releases/:id/recipe-bundles", async (context) => {
  const release = await context.env.DB.prepare("SELECT id, state FROM releases WHERE id = ?1").bind(context.req.param("id")).first<{ id: string; state: string }>();
  if (!release) return jsonError("release not found", 404);
  if (!['draft', 'validating'].includes(release.state)) return jsonError(`release recipe bundles are immutable in ${release.state} state`, 409);
  try {
    const result = await buildReleaseRecipeBundles(context.env, context.req.param("id"), context.req.query("after") ?? "", 100);
    return context.json({ ok: true, releaseId: context.req.param("id"), ...result });
  } catch (error) {
    console.error("release recipe bundle build failed", { releaseId: context.req.param("id"), after: context.req.query("after") ?? "", error });
    return jsonError(error instanceof Error ? error.message : "release recipe bundle build failed", 500);
  }
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
  // A rejected artifact is immutable, but the validator implementation is
  // versioned with the worker. Permit an explicit operator retry after a guard
  // defect is corrected so the same bytes can be re-evaluated without an
  // expensive and semantically pointless release rebuild.
  if (!["draft", "validating", "rejected"].includes(release.state)) return jsonError(`release cannot be validated from ${release.state}`, 409);
  if (release.state === "rejected") {
    const reopened = await context.env.DB.prepare(
      "UPDATE releases SET state = 'validating', validated_at = NULL WHERE id = ?1 AND state = 'rejected'",
    ).bind(releaseId).run();
    if ((reopened.meta.changes ?? 0) !== 1) return jsonError("release validation retry lost its state fence", 409);
  }
  const summary = JSON.parse(release.summary_json) as { expectedCommodities: number; expectedStores: number; expectedRecipes: number; expectedFreeRotation?: number };
  const expectedFreeRotation = summary.expectedFreeRotation ?? 0;
  const releaseIdentity = await context.env.DB.prepare(
    "SELECT configuration_id, market_id, input_manifest_json FROM releases WHERE id = ?1",
  ).bind(releaseId).first<{ configuration_id: string; market_id: string; input_manifest_json: string }>();
  if (!releaseIdentity) return jsonError("release not found", 404);
  const bundleCount = await context.env.DB.prepare(
    "SELECT COUNT(*) AS count FROM release_recipe_payload_refs WHERE release_id = ?1",
  ).bind(releaseId).first<{ count: number }>();
  if ((bundleCount?.count ?? 0) !== summary.expectedRecipes) {
    return jsonError(`release recipe bundles are incomplete: expected ${summary.expectedRecipes}, found ${bundleCount?.count ?? 0}`, 409);
  }
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
  await evaluateReleaseIntegrity(context.env, releaseId);
  const manifestKind = String((JSON.parse(releaseIdentity.input_manifest_json) as Record<string, unknown>).kind ?? "");
  if (manifestKind !== "legacy-current-bridge") {
    const [graph, graphNodes, scenarios] = await Promise.all([
      context.env.DB.prepare("SELECT node_count, changed_node_count, reused_node_count FROM release_graphs WHERE release_id = ?1").bind(releaseId).first<{ node_count: number; changed_node_count: number; reused_node_count: number }>(),
      context.env.DB.prepare("SELECT COUNT(*) AS count FROM release_graph_nodes WHERE release_id = ?1").bind(releaseId).first<{ count: number }>(),
      context.env.DB.prepare("SELECT COUNT(*) AS count FROM release_recipe_scenarios WHERE release_id = ?1").bind(releaseId).first<{ count: number }>(),
    ]);
    const expectedGraphNodes = expectedCellRows + summary.expectedRecipes + 7;
    const graphPass = graph?.node_count === expectedGraphNodes && graphNodes?.count === expectedGraphNodes
      && (graph.changed_node_count + graph.reused_node_count === graph.node_count);
    await upsertGuardResult(context.env.DB, releaseId, {
      guardId: "release-object-graph", status: graphPass ? "pass" : "fail", eligibleCount: expectedGraphNodes,
      examinedCount: Math.min(expectedGraphNodes, graphNodes?.count ?? 0),
      findings: graphPass ? [] : [{ key: "release-graph-incomplete", message: "Content-addressed release graph is incomplete", evidence: { graph, graphNodes, expectedGraphNodes } }],
      detail: { graph },
    });
    const expectedScenarios = summary.expectedRecipes * (4 + summary.expectedStores);
    const scenarioPass = scenarios?.count === expectedScenarios;
    await upsertGuardResult(context.env.DB, releaseId, {
      guardId: "release-recipe-scenarios", status: scenarioPass ? "pass" : "fail", eligibleCount: expectedScenarios,
      examinedCount: Math.min(expectedScenarios, scenarios?.count ?? 0),
      findings: scenarioPass ? [] : [{ key: "recipe-scenario-count", message: "First-class recipe scenarios are incomplete", evidence: { actual: scenarios?.count ?? 0, expected: expectedScenarios } }],
      detail: { scenarioKinds: ["utilized", "register-checkout", "non-member-checkout", "everyday-baseline", "selected-store-checkout"] },
    });
  }
  await evaluateNotBlindGuard(context.env.DB, releaseId);
  const missingHard = await context.env.DB.prepare(
    `SELECT d.id
       FROM guard_definitions d
       LEFT JOIN guard_results r ON r.guard_id = d.id AND r.release_id = ?1
      WHERE d.active = 1 AND d.scope = 'release' AND d.severity = 'hard'
        AND (r.id IS NULL OR r.status <> 'pass')
        AND (?2 <> 'legacy-current-bridge' OR d.id NOT IN ('release-object-graph', 'release-recipe-scenarios'))
      ORDER BY d.id`,
  ).bind(releaseId, manifestKind).all<{ id: string }>();
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
  statements.push(context.env.DB.prepare("DELETE FROM current_recipe_scenarios WHERE market_id = ?1").bind(release.market_id));
  statements.push(context.env.DB.prepare(
    `INSERT INTO current_recipe_scenarios
       (market_id, release_id, recipe_slug, scenario_kind, store_location_key, status, batch_cost_minor,
        serving_cost_minor, missing_ingredients_json, content_hash, updated_at)
     SELECT ?1, release_id, recipe_slug, scenario_kind, store_location_key, status, batch_cost_minor,
            serving_cost_minor, missing_ingredients_json, content_hash, CURRENT_TIMESTAMP
       FROM release_recipe_scenarios WHERE release_id = ?2`,
  ).bind(release.market_id, releaseId));
  statements.push(context.env.DB.prepare("UPDATE releases SET state = 'published', published_at = CURRENT_TIMESTAMP WHERE id = ?1 AND state = 'validated'").bind(releaseId));
  statements.push(context.env.DB.prepare(
    `INSERT INTO current_releases (market_id, release_id, updated_at) VALUES (?1, ?2, CURRENT_TIMESTAMP)
     ON CONFLICT(market_id) DO UPDATE SET release_id = excluded.release_id, updated_at = CURRENT_TIMESTAMP`,
  ).bind(release.market_id, releaseId));
  await context.env.DB.batch(statements);
  if (current && current.release_id !== releaseId) {
    const historicalRoot = await context.env.DB.prepare(
      "SELECT root_hash FROM release_graphs WHERE release_id = ?1",
    ).bind(current.release_id).first<{ root_hash: string }>();
    if (!historicalRoot) {
      await raiseOperationalAlert(context.env, `release-projection-compaction:${current.release_id}`,
        "Superseded release projection retained until immutable history is verified",
        { releaseId, previousReleaseId: current.release_id, reason: "release graph is absent" },
        { notification: "digest", deferMinutes: 30 });
    } else try {
      await context.env.DB.batch([
        context.env.DB.prepare("DELETE FROM recipe_cost_detail_objects WHERE release_id = ?1").bind(current.release_id),
        context.env.DB.prepare("DELETE FROM release_recipe_payload_refs WHERE release_id = ?1").bind(current.release_id),
        context.env.DB.prepare("DELETE FROM release_recipe_payloads WHERE release_id = ?1").bind(current.release_id),
        context.env.DB.prepare("DELETE FROM release_recipe_scenarios WHERE release_id = ?1").bind(current.release_id),
        context.env.DB.prepare("DELETE FROM release_recipe_costs WHERE release_id = ?1").bind(current.release_id),
        context.env.DB.prepare("DELETE FROM release_top5 WHERE release_id = ?1").bind(current.release_id),
        context.env.DB.prepare("DELETE FROM release_free_rotation WHERE release_id = ?1").bind(current.release_id),
        context.env.DB.prepare("DELETE FROM release_payloads WHERE release_id = ?1").bind(current.release_id),
        context.env.DB.prepare(
          `DELETE FROM release_cells WHERE release_id = ?1
            AND NOT EXISTS (SELECT 1 FROM accuracy_draw_cells sample
                             WHERE sample.release_id = release_cells.release_id
                               AND sample.commodity_id = release_cells.commodity_id
                               AND sample.store_location_id = release_cells.store_location_id)`,
        ).bind(current.release_id),
        context.env.DB.prepare("DELETE FROM release_graph_nodes WHERE release_id = ?1").bind(current.release_id),
      ]);
      await context.env.DB.prepare(
        `DELETE FROM release_reason_blobs WHERE NOT EXISTS
          (SELECT 1 FROM release_cells cell WHERE cell.reason_hash = release_reason_blobs.content_hash)`,
      ).run();
    } catch (error) {
      await raiseOperationalAlert(context.env, `release-projection-compaction:${current.release_id}`, "Superseded hot release projection compaction failed", {
        releaseId, previousReleaseId: current.release_id, error: error instanceof Error ? error.message : String(error),
      }, { notification: "digest", deferMinutes: 30 });
    }
  }
  let cachePurged = false;
  let cachePurgeErrors: Array<{ code: number; message: string }> = [];
  try {
    // Tags remove content-addressed release responses; the path prefix also
    // evicts any pre-tag legacy/error entries that may share these public URLs.
    const purge = await cache.purge({ tags: ["grocery-public"], pathPrefixes: ["/api/v2/"] });
    cachePurged = purge.success;
    cachePurgeErrors = purge.errors;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    cachePurgeErrors = [{ code: 0, message }];
  }
  try {
    if (cachePurged) {
      await resolveOperationalAlert(context.env, "public-cache-purge", { releaseId, purgedAt: new Date().toISOString() });
    } else {
      await raiseOperationalAlert(context.env, "public-cache-purge", "Published release cache purge failed", { releaseId, errors: cachePurgeErrors });
    }
  } catch (error) {
    // Publication already committed atomically. Alert persistence must not turn
    // that successful state change into a misleading 500/retry response.
    console.error("public cache purge alert persistence failed", { releaseId, error: error instanceof Error ? error.message : String(error) });
  }
  return context.json({ ok: true, releaseId, state: "published", previousReleaseId: current?.release_id ?? null, cachePurged, cachePurgeErrors });
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
    const drawRef = String(item.source_ref).split("#", 1)[0]!;
    source = await context.env.DB.prepare(
      `SELECT draw.*, COUNT(verdict.id) AS verdict_count
         FROM accuracy_draws draw LEFT JOIN operator_verdicts verdict ON verdict.draw_id = draw.id
        WHERE draw.id = ?1 GROUP BY draw.id`,
    ).bind(drawRef).first<Record<string, unknown>>();
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
      WHERE source_kind = 'operational_alert' AND title IN ('Nightly D1 backup failed', 'Weekly D1 full export failed', 'D1 Time Travel and R2 lake manifest backup failed')
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
            AND julianday(COALESCE(candidate.started_at, candidate.scheduled_for, candidate.finished_at))
              > julianday(COALESCE(failed.started_at, failed.scheduled_for, failed.finished_at, triage.created_at))
          ORDER BY COALESCE(candidate.started_at, candidate.scheduled_for, candidate.finished_at) DESC LIMIT 1
       )
      WHERE triage.source_kind = 'operational_alert'
        AND triage.source_ref LIKE 'job-run:%'
        AND triage.status <> 'resolved'
        AND failed.status IN ('failed', 'timed_out', 'missed')`,
  ).all<{ id: string; job: string; recovery_run_id: string; finished_at: string }>();
  const recoveredEnginePublications = await context.env.DB.prepare(
    `SELECT triage.id, failed.id AS failed_run_id, release.id AS recovery_release_id, release.published_at
       FROM triage_items triage
       JOIN job_runs failed ON failed.id = substr(triage.source_ref, 9) AND failed.job = 'daily-engine'
       JOIN current_releases current ON current.market_id = 'omaha'
       JOIN releases release ON release.id = current.release_id
      WHERE triage.source_kind = 'operational_alert'
        AND triage.source_ref LIKE 'job-run:%'
        AND triage.status <> 'resolved'
        AND failed.status IN ('failed', 'timed_out', 'missed')
        AND julianday(release.published_at)
          > julianday(COALESCE(failed.started_at, failed.scheduled_for, failed.finished_at, triage.created_at))`,
  ).all<{ id: string; failed_run_id: string; recovery_release_id: string; published_at: string }>();
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
        AND title IN ('Quarterly D1 restore drill failed', 'R2 lake and D1 Time Travel recovery drill failed')
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
    ...recoveredEnginePublications.results.map((row) => ({
      id: row.id,
      planRef: "auto-plan://later-release-published",
      resolution: {
        resolution: "A later guarded native release published successfully after this failed engine attempt.",
        failedRunId: row.failed_run_id,
        recoveryReleaseId: row.recovery_release_id,
        publishedAt: row.published_at,
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

app.post("/internal/triage/compact", async (context) => {
  if (context.get("identity").role !== "operator") return jsonError("only an operator may compact historical triage", 403);
  const body = await context.req.json<{ execute?: unknown; limit?: unknown }>().catch(() => ({} as { execute?: unknown; limit?: unknown }));
  const execute = body.execute === true;
  const limit = body.limit === undefined ? 75 : Number(body.limit);
  if (!Number.isInteger(limit) || limit < 1 || limit > 75) return jsonError("triage compaction limit must be 1-75 result groups", 422);
  try {
    const result = await compactHistoricalTriage(context.env, { execute, limit });
    await recordAudit(context.env, context.get("identity"), "triage.compact", "triage_archive", "archiveId" in result ? String(result.archiveId) : null,
      "accepted", result);
    return context.json(result);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "historical triage compaction failed", 409);
  }
});

app.get("/internal/releases/:id", async (context) => {
  const release = await context.env.DB.prepare(
    "SELECT id, market_id, configuration_id, input_hash, state, validated_at, published_at FROM releases WHERE id = ?1",
  ).bind(context.req.param("id")).first<Record<string, unknown>>();
  if (!release) return context.json({ ok: false, found: false, error: "release not found" }, 404);
  const progress = await context.env.DB.prepare(
    `SELECT
       (SELECT COUNT(*) FROM release_cells WHERE release_id = ?1) AS cells,
       (SELECT COUNT(*) FROM release_recipe_costs WHERE release_id = ?1) AS recipe_costs,
       (SELECT COUNT(*) FROM release_payloads WHERE release_id = ?1) AS payloads,
       (SELECT COUNT(*) FROM release_graph_nodes WHERE release_id = ?1) AS graph_nodes,
       EXISTS(SELECT 1 FROM release_graphs WHERE release_id = ?1) AS graph_finalized,
       (SELECT COUNT(*) FROM release_recipe_payload_refs WHERE release_id = ?1) AS recipe_bundles`,
  ).bind(context.req.param("id")).first<Record<string, unknown>>();
  return context.json({ ok: true, found: true, release, progress });
});

app.get("/internal/engine/snapshot-identity", async (context) => {
  const requested = context.req.query("mode") ?? "direct";
  if (!(["legacy", "direct", "all"] as const).includes(requested as EngineSourceMode)) return jsonError("engine mode must be legacy, direct, or all", 422);
  const observedAt = context.req.query("observedAt");
  if (observedAt && !Number.isFinite(Date.parse(observedAt))) return jsonError("engine snapshot observedAt must be an ISO timestamp", 422);
  try {
    return context.json({ ok: true, ...await readEngineSnapshotIdentity(context.env, requested as EngineSourceMode, observedAt) });
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "engine snapshot identity failed", 422);
  }
});

app.post("/internal/backups/checkpoint", async (context) => {
  const result = await runD1RecoveryCheckpoint(context.env, Date.now(), true);
  await recordAudit(context.env, context.get("identity"), "recovery.checkpoint", "recovery_checkpoint", String(result.checkpointId), "accepted", result);
  return context.json(result, 201);
});

app.post("/internal/deployments/preflight", async (context) => {
  const payload = await context.req.json().catch(() => ({})) as { sourceCommit?: unknown };
  const sourceCommit = typeof payload.sourceCommit === "string" && /^[a-f0-9]{40}$/.test(payload.sourceCommit)
    ? payload.sourceCommit
    : null;
  if (!sourceCommit) return jsonError("deployment preflight requires a full git commit", 422);
  const checkedAt = new Date().toISOString();
  const id = await deterministicId("deployment-check", sourceCommit, checkedAt);
  const deploymentLease = await acquireOperationLease(context.env.DB, {
    resource: "control:deployment", holderId: id, ownerKind: "deployment", leaseMinutes: 15, now: checkedAt,
    metadata: { sourceCommit, actorId: context.get("identity").agentId, deploymentSafe: true },
  });
  if (!deploymentLease) return jsonError("another deployment is already draining the control plane", 409);
  const blockers = await activeDeploymentBlockers(context.env.DB, checkedAt);
  if (blockers.length) await releaseOperationLease(context.env.DB, deploymentLease.resource, id, deploymentLease.fence, checkedAt);
  await context.env.DB.prepare(
    `INSERT INTO deployment_checks (id, source_commit, actor_id, status, blocker_count, blockers_json, checked_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
  ).bind(id, sourceCommit, context.get("identity").agentId, blockers.length ? "blocked" : "clear", blockers.length, stableJson(blockers), checkedAt).run();
  return context.json({ ok: blockers.length === 0, checkId: id, sourceCommit, checkedAt, blockers, deploymentLease }, blockers.length ? 409 : 200);
});

app.post("/internal/deployments/complete", async (context) => {
  const payload = await context.req.json().catch(() => ({})) as { checkId?: unknown; fence?: unknown; outcome?: unknown };
  if (typeof payload.checkId !== "string" || typeof payload.fence !== "number" || !["deployed", "failed"].includes(String(payload.outcome))) {
    return jsonError("deployment completion requires checkId, fence, and outcome", 422);
  }
  const released = await releaseOperationLease(context.env.DB, "control:deployment", payload.checkId, payload.fence);
  return context.json({ ok: released, checkId: payload.checkId, outcome: payload.outcome, released }, released ? 200 : 409);
});

app.get("/internal/transitions/readiness", async (context) => {
  const schedules = await transitionReadiness(context.env.DB);
  return context.json({ ok: true, eligible: schedules.filter((schedule) => schedule.eligible === true).length, schedules });
});

app.post("/internal/control-plane/prove", async (context) => {
  await runControlPlaneProof(context.env, Date.now(), true);
  const proof = await context.env.DB.prepare("SELECT id, status, source_commit, checks_json, observed_at FROM control_plane_proofs ORDER BY observed_at DESC LIMIT 1").first<Record<string, unknown>>();
  return context.json({ ok: proof?.status === "pass", proof }, proof?.status === "pass" ? 200 : 422);
});

app.post("/internal/transitions/:job/retire", async (context) => {
  const job = context.req.param("job");
  const readiness = await transitionReadiness(context.env.DB);
  const schedule = readiness.find((candidate) => candidate.job === job);
  if (!schedule) return jsonError("transition schedule not found", 404);
  if (schedule.eligible !== true) return context.json({ ok: false, error: "retirement evidence gate is incomplete", schedule }, 409);
  const retiredAt = new Date().toISOString();
  await context.env.DB.batch([
    context.env.DB.prepare("UPDATE job_schedules SET lifecycle = 'retired', active = 0 WHERE job = ?1 AND lifecycle = 'transition'").bind(job),
    context.env.DB.prepare(
      `INSERT INTO transition_retirements (schedule_id, retirement_gate, evidence_json, retired_by, retired_at)
       VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(schedule_id) DO NOTHING`,
    ).bind(job, String(schedule.retirement_gate), stableJson(schedule.evidence), context.get("identity").agentId, retiredAt),
  ]);
  return context.json({ ok: true, job, status: "retired", retiredAt, evidence: schedule.evidence });
});

app.get("/internal/doctor", async (context) => {
  const overdueAccuracyDraws = await markOverdueAccuracyDraws(context.env.DB);
  const [configuration, release, hardGuards, triage, batches, leases, capacity, deploymentCheck] = await Promise.all([
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
    context.env.DB.prepare("SELECT resource, holder_id, owner_kind, fence, heartbeat_at, expires_at FROM operation_leases WHERE released_at IS NULL AND expires_at > CURRENT_TIMESTAMP ORDER BY acquired_at").all(),
    context.env.DB.prepare("SELECT status, usage_percent_millis, monthly_growth_bytes, projected_limit_at, observed_at FROM archival_forecasts ORDER BY observed_at DESC LIMIT 1").first(),
    context.env.DB.prepare("SELECT status, blocker_count, checked_at, source_commit FROM deployment_checks ORDER BY checked_at DESC LIMIT 1").first(),
  ]);
  const healthy = Boolean(configuration && release)
    && (configuration as { id?: string } | null)?.id === (release as { configuration_id?: string } | null)?.configuration_id
    && hardGuards.results.every((row) => (row as { status: string }).status === "pass")
    && !triage.results.some((row) => (row as { status: string; count: number }).status === "open" && (row as { count: number }).count > 0);
  return context.json({ ok: healthy, configuration, release, hardGuards: hardGuards.results, triage: triage.results, batches: batches.results, activeLeases: leases.results, capacity, deploymentCheck, overdueAccuracyDraws }, healthy ? 200 : 422);
});

app.all("/board-beta*", (context) => context.env.ASSETS.fetch(context.req.raw));
app.all("/omaha-grocery-prices*", (context) => context.env.ASSETS.fetch(context.req.raw));
app.all("/tools/*", (context) => context.env.ASSETS.fetch(context.req.raw));
app.all("*", (context) => context.env.ASSETS.fetch(context.req.raw));

app.onError((error, context) => {
  console.error(error);
  const identity = context.get("identity");
  const maySeeInternalDetail = context.req.path.startsWith("/internal/") && identity?.role === "operator";
  return context.json({
    ok: false,
    error: context.env.APP_ENV === "production" && !maySeeInternalDetail ? "Internal error" : error.message,
  }, 500);
});

export default {
  async fetch(request: Request, env: WorkerEnv, executionContext: ExecutionContext): Promise<Response> {
    return await app.fetch(request, env, executionContext);
  },
  scheduled(controller: ScheduledController, env: WorkerEnv, executionContext: ExecutionContext): void {
    executionContext.waitUntil(runScheduledOperations(env, controller.scheduledTime));
  },
};
