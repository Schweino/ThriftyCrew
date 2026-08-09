import { Hono, type MiddlewareHandler } from "hono";
import { zValidator } from "@hono/zod-validator";
import {
  accuracyDrawCreateSchema,
  accuracyVerdictsSchema,
  captureBatchCreateSchema,
  captureBatchSealSchema,
  configurationCategoriesChunkSchema,
  configurationCommoditiesChunkSchema,
  configurationCreateSchema,
  configurationKnownWrongChunkSchema,
  evidenceMetadataSchema,
  jobDispatchSchema,
  jobRunCreateSchema,
  jobRunUpdateSchema,
  matchDecisionsChunkSchema,
  observationChunkSchema,
  recipeCostsChunkSchema,
  releaseCellsChunkSchema,
  releaseCreateSchema,
  releaseFreeRotationChunkSchema,
  releaseTop5ChunkSchema,
  releaseGuardResultSchema,
  releasePayloadSchema,
  scheduleDocumentSchema,
  telemetryEventSchema,
  triageResolveSchema,
} from "@thriftycrew/contracts";
import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import { authenticateMutation } from "./auth";
import { createRelease, findBatch, insertObservations, insertRecipeCosts, insertReleaseCells, upsertGuardResult } from "./database";
import { evaluateNotBlindGuard, evaluateReleaseGuards } from "./release-guards";
import { createAccuracyDraw, latestAccuracySummary, markOverdueAccuracyDraws, readAccuracyDraw, recordAccuracyVerdicts } from "./accuracy";
import { reconcileGhostRotation } from "./ghost-reconciliation";
import { dispatchGithubJob, recordAudit, runScheduledOperations } from "./operations";
import type { MutationIdentity, MutationRole, WorkerEnv } from "./env";
export { D1BackupWorkflow } from "./backup-workflow";

type Bindings = { Bindings: WorkerEnv; Variables: { identity: MutationIdentity } };
const app = new Hono<Bindings>();

function jsonError(message: string, status: 400 | 401 | 403 | 404 | 409 | 422 | 500 = 400): Response {
  return Response.json({ ok: false, error: message }, { status });
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

async function requireDraftRelease(db: D1Database, releaseId: string): Promise<Response | null> {
  const release = await db.prepare("SELECT state FROM releases WHERE id = ?1").bind(releaseId).first<{ state: string }>();
  if (!release) return jsonError("release not found", 404);
  if (release.state !== "draft") return jsonError(`release content is immutable in ${release.state} state`, 409);
  return null;
}

app.use("/internal/*", requireMutation(["capture", "engine", "operator"]));
app.use("/internal/capture-batches", requireIdentityRole(["capture", "operator"]));
app.use("/internal/capture-batches/*", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/configurations", requireIdentityRole(["engine", "operator"]));
app.use("/internal/configurations/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/match-decisions", requireIdentityRole(["engine", "operator"]));
app.use("/internal/job-runs", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/job-runs/*", requireIdentityRole(["capture", "engine", "operator"]));
app.use("/internal/jobs/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/schedules/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/backups/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/releases", requireIdentityRole(["engine", "operator"]));
app.use("/internal/releases/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/accuracy/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/triage", requireIdentityRole(["engine", "operator"]));
app.use("/internal/triage/*", requireIdentityRole(["engine", "operator"]));
app.use("/internal/doctor", requireIdentityRole(["engine", "operator"]));

app.get("/api/v2/status", async (context) => {
  const [release, schedules, accuracy, triage] = await Promise.all([
    context.env.DB.prepare(
      `SELECT r.id, r.published_at, r.summary_json
         FROM current_releases c JOIN releases r ON r.id = c.release_id
        WHERE c.market_id = 'omaha'`,
    ).first<{ id: string; published_at: string; summary_json: string }>(),
    context.env.DB.prepare(
      `SELECT s.job, s.cron, s.executor, s.timezone, s.owner, s.proof, s.max_gap_minutes,
              (SELECT status FROM job_runs r WHERE r.job = s.job ORDER BY COALESCE(r.started_at, r.scheduled_for) DESC LIMIT 1) AS status,
              (SELECT COALESCE(heartbeat_at, finished_at, started_at, scheduled_for) FROM job_runs r WHERE r.job = s.job ORDER BY COALESCE(heartbeat_at, finished_at, started_at, scheduled_for) DESC LIMIT 1) AS latest_at
         FROM job_schedules s WHERE s.active = 1 ORDER BY s.job`,
    ).all(),
    latestAccuracySummary(context.env.DB),
    context.env.DB.prepare(
      "SELECT status, COUNT(*) AS count FROM triage_items GROUP BY status ORDER BY status",
    ).all<{ status: string; count: number }>(),
  ]);
  const checkedAt = new Date();
  const jobs = schedules.results.map((row) => {
    const item = row as Record<string, unknown>;
    const latestAt = typeof item.latest_at === "string" ? Date.parse(item.latest_at) : Number.NaN;
    const maxGap = typeof item.max_gap_minutes === "number" ? item.max_gap_minutes : 0;
    return { ...item, stale: !Number.isFinite(latestAt) || checkedAt.getTime() - latestAt > maxGap * 60_000 };
  });
  return context.json({
    ok: true,
    environment: context.env.APP_ENV,
    currentRelease: release ? { id: release.id, publishedAt: release.published_at, summary: JSON.parse(release.summary_json) } : null,
    jobs,
    accuracy,
    triage: Object.fromEntries(triage.results.map((row) => [row.status, row.count])),
    checkedAt: checkedAt.toISOString(),
  });
});

app.get("/v2/status", (context) => context.redirect("/api/v2/status", 307));

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
  const statements = context.req.valid("json").rules.map((rule) => context.env.DB.prepare(
    `INSERT INTO known_wrong_rules
       (id, configuration_id, commodity_id, store_location_id, external_product_key, normalized_name, ruling, evidence)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
     ON CONFLICT(id) DO UPDATE SET
       commodity_id = excluded.commodity_id, store_location_id = excluded.store_location_id,
       external_product_key = excluded.external_product_key, normalized_name = excluded.normalized_name,
       ruling = excluded.ruling, evidence = excluded.evidence`,
  ).bind(rule.id, configurationId, rule.commodityId, rule.storeLocationId ?? null, rule.externalProductKey ?? null, rule.normalizedName ?? null, rule.ruling, rule.evidence));
  for (let offset = 0; offset < statements.length; offset += 90) await context.env.DB.batch(statements.slice(offset, offset + 90));
  return context.json({ ok: true, accepted: statements.length });
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
      `INSERT OR IGNORE INTO match_decisions
         (id, product_id, commodity_id, configuration_id, decided_by, reason)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
    ).bind(decisionId, decision.productId, decision.commodityId, decision.configurationId, decision.decidedBy, decision.reason));
  }
  for (let offset = 0; offset < statements.length; offset += 90) {
    await context.env.DB.batch(statements.slice(offset, offset + 90));
  }
  return context.json({ ok: true, accepted: decisions.length });
});

app.put("/internal/schedules/sync", zValidator("json", scheduleDocumentSchema), async (context) => {
  const document = context.req.valid("json");
  const identity = context.get("identity");
  const statements = document.schedules.map((schedule) => context.env.DB.prepare(
    `INSERT INTO job_schedules
       (job, cron, max_gap_minutes, active, executor, timezone, owner, proof, dispatch_on_gap)
     VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?7, ?8)
     ON CONFLICT(job) DO UPDATE SET
       cron = excluded.cron, max_gap_minutes = excluded.max_gap_minutes, active = 1,
       executor = excluded.executor, timezone = excluded.timezone, owner = excluded.owner,
       proof = excluded.proof, dispatch_on_gap = excluded.dispatch_on_gap`,
  ).bind(
    schedule.id,
    schedule.cron,
    schedule.maxGapMinutes,
    schedule.executor,
    document.timezone,
    schedule.owner,
    schedule.proof,
    schedule.dispatchOnGap ? 1 : 0,
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

app.post("/internal/backups/trigger", async (context) => {
  const instanceId = `d1-backup-manual-${crypto.randomUUID()}`;
  await context.env.BACKUP_WORKFLOW.create({ id: instanceId, params: { trigger: "operator" } });
  await recordAudit(context.env, context.get("identity"), "backup.trigger", "workflow", instanceId, "accepted");
  return context.json({ ok: true, instanceId }, 202);
});

app.post("/internal/job-runs", zValidator("json", jobRunCreateSchema), async (context) => {
  const body = context.req.valid("json");
  const schedule = await context.env.DB.prepare("SELECT job FROM job_schedules WHERE job = ?1 AND active = 1").bind(body.job).first();
  if (!schedule) return jsonError("unknown or inactive job", 404);
  const existing = await context.env.DB.prepare("SELECT job, status FROM job_runs WHERE id = ?1").bind(body.id).first<{ job: string; status: string }>();
  if (existing) {
    if (existing.job !== body.job) return jsonError("job run id belongs to another job", 409);
    return context.json({ ok: true, runId: body.id, status: existing.status, idempotent: true });
  }
  const status = body.startedAt ? "started" : "scheduled";
  await context.env.DB.prepare(
    `INSERT INTO job_runs
       (id, job, trigger_kind, scheduled_for, started_at, heartbeat_at, status, input_json,
        executor_run_id, actor_id, prompt_hash, input_hash, model_id)
     VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`,
  ).bind(
    body.id,
    body.job,
    body.triggerKind,
    body.scheduledFor ?? null,
    body.startedAt ?? null,
    status,
    stableJson(body.input),
    body.executorRunId ?? null,
    context.get("identity").agentId,
    body.promptHash ?? null,
    body.inputHash ?? null,
    body.modelId ?? null,
  ).run();
  return context.json({ ok: true, runId: body.id, status, idempotent: false }, 201);
});

app.patch("/internal/job-runs/:id", zValidator("json", jobRunUpdateSchema), async (context) => {
  const body = context.req.valid("json");
  const current = await context.env.DB.prepare("SELECT status, started_at, finished_at FROM job_runs WHERE id = ?1").bind(context.req.param("id")).first<{ status: string; started_at: string | null; finished_at: string | null }>();
  if (!current) return jsonError("job run not found", 404);
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
  return context.json({ ok: true, runId: context.req.param("id"), status: body.status, idempotent: false });
});

app.post("/internal/capture-batches", zValidator("json", captureBatchCreateSchema), async (context) => {
  const body = context.req.valid("json");
  const identity = context.get("identity");
  if (identity.sourceIds && !identity.sourceIds.includes(body.sourceId)) return jsonError("agent is not authorized for this capture source", 403);
  const source = await context.env.DB.prepare("SELECT id FROM capture_sources WHERE id = ?1 AND active = 1").bind(body.sourceId).first();
  if (!source) return jsonError("unknown or inactive capture source", 404);
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

app.post("/internal/capture-batches/:id/observations", zValidator("json", observationChunkSchema), async (context) => {
  const batch = await findBatch(context.env.DB, context.req.param("id"));
  if (!batch) return jsonError("capture batch not found", 404);
  const identity = context.get("identity");
  if (identity.role !== "capture" && identity.role !== "operator") return jsonError("mutation role is not authorized for capture content", 403);
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
  if (identity.role !== "capture" && identity.role !== "operator") return jsonError("mutation role is not authorized for capture evidence", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
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
  const objectKey = `batches/${batch.id}/${metadataResult.data.id}`;
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
  if (identity.role !== "capture" && identity.role !== "operator") return jsonError("mutation role is not authorized to seal captures", 403);
  if (batch.agent_id !== identity.agentId && identity.role !== "operator") return jsonError("batch belongs to another agent", 403);
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
  const termEnvelopePass = batch.coverage_mode !== "full" || batch.expected_terms === null || attempted === batch.expected_terms;
  const pageEnvelopePass = batch.expected_pages === null || capturedPages === batch.expected_pages;
  const completePass = termEnvelopePass && pageEnvelopePass;
  const status = identityPass && completePass && collapsePass ? "validated" : "rejected";
  const statements: D1PreparedStatement[] = body.terms.map((term) => context.env.DB.prepare(
    `INSERT INTO capture_terms (batch_id, term_key, ordinal, outcome, row_count, reason)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  ).bind(batch.id, term.termKey, term.ordinal, term.outcome, term.rowCount, term.reason ?? null));
  statements.push(context.env.DB.prepare(
    `UPDATE capture_batches SET status = ?2, attempted_terms = ?3, successful_terms = ?4, empty_terms = ?5,
       rejected_terms = ?6, blocked_terms = ?7, captured_pages = ?8, evidence_manifest_key = ?9,
       validation_summary_json = ?10, sealed_at = CURRENT_TIMESTAMP WHERE id = ?1`,
  ).bind(batch.id, status, attempted, successful, empty, rejected, blocked, capturedPages, body.evidenceManifestKey ?? null, stableJson({ identityPass, termEnvelopePass, pageEnvelopePass, collapsePass, observationCount, predecessorBatchId: predecessor?.id ?? null, predecessorObservationCount: predecessor?.observation_count ?? null, collapseFloor })));
  for (const [guardId, pass, eligible, examined, detail] of [
    ["batch-location", identityPass, 3, 3, {}],
    ["batch-completeness", completePass, (batch.expected_terms ?? 0) + (batch.expected_pages ?? 0), attempted + capturedPages, {}],
    ["batch-collapse", collapsePass, predecessor ? 2 : 0, predecessor ? 2 : 0, { observationCount, predecessorBatchId: predecessor?.id ?? null, predecessorObservationCount: predecessor?.observation_count ?? null, collapseFloor }],
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
  const [cellStats, recipeStats, payloadStats, invalidCellStats, rotationStats, top5Stats] = await Promise.all([
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
  const recipePass = (recipeStats?.incomplete ?? 0) === 0;
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
    eligibleCount: recipeStats?.rows ?? 0,
    examinedCount: recipeStats?.rows ?? 0,
    findings: recipePass ? [] : [{ key: "incomplete-recipes", message: `${recipeStats?.incomplete ?? 0} recipes have missing required ingredient prices`, evidence: {} }],
    detail: {},
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

app.post("/internal/accuracy/draws", zValidator("json", accuracyDrawCreateSchema), async (context) => {
  try {
    const result = await createAccuracyDraw(context.env.DB, context.req.valid("json"));
    return context.json({ ok: true, ...result }, result.idempotent ? 200 : 201);
  } catch (error) {
    return jsonError(error instanceof Error ? error.message : "accuracy draw failed", 422);
  }
});

app.get("/internal/accuracy/draw", async (context) => {
  const draw = await readAccuracyDraw(context.env.DB, context.req.query("id"));
  if (!draw) return jsonError("accuracy draw not found", 404);
  return context.json({ ok: true, draw });
});

app.post("/internal/accuracy/verdicts", zValidator("json", accuracyVerdictsSchema), async (context) => {
  try {
    const result = await recordAccuracyVerdicts(context.env.DB, context.req.valid("json"), context.get("identity").agentId);
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

app.post("/internal/triage/:id/resolve", zValidator("json", triageResolveSchema), async (context) => {
  const body = context.req.valid("json");
  const existing = await context.env.DB.prepare("SELECT id FROM triage_items WHERE id = ?1").bind(context.req.param("id")).first();
  if (!existing) return jsonError("triage item not found", 404);
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
    context.env.DB.prepare("SELECT release_id, updated_at FROM current_releases WHERE market_id = 'omaha'").first(),
    context.env.DB.prepare(
      `SELECT r.status, COUNT(*) AS count FROM guard_results r
        JOIN current_releases c ON c.release_id = r.release_id
       GROUP BY r.status`,
    ).all(),
    context.env.DB.prepare("SELECT status, COUNT(*) AS count FROM triage_items GROUP BY status").all(),
    context.env.DB.prepare("SELECT status, COUNT(*) AS count FROM capture_batches GROUP BY status").all(),
  ]);
  const healthy = Boolean(configuration && release)
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
