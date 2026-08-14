import { mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";

const require = createRequire(import.meta.url);
const databases = new Map();

export function captureJournalPath(environment = process.env) {
  if (environment.TC_CAPTURE_JOURNAL) return path.resolve(environment.TC_CAPTURE_JOURNAL);
  if (environment.NODE_ENV === "test") return ":memory:";
  return path.join(environment.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "ThriftyCrew", "grocery-v3", "capture-journal.sqlite");
}

function database(file = captureJournalPath()) {
  const key = file === ":memory:" ? path.join(process.cwd(), ".capture-journal-memory") : path.resolve(file);
  if (databases.has(key)) return databases.get(key);
  if (file !== ":memory:") mkdirSync(path.dirname(file), { recursive: true });
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(file);
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = FULL;
    PRAGMA busy_timeout = 5000;
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS queue_jobs (
      id TEXT PRIMARY KEY, directory TEXT NOT NULL UNIQUE, source_id TEXT NOT NULL, status TEXT NOT NULL,
      enqueued_at TEXT NOT NULL, next_attempt_at TEXT NOT NULL, manifest_json TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS queue_jobs_status_due_idx ON queue_jobs(status, next_attempt_at, enqueued_at);
    CREATE TABLE IF NOT EXISTS queue_leases (
      job_id TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at INTEGER NOT NULL, acquired_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS capture_sessions (
      directory TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE, store TEXT NOT NULL, draft_json TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS capture_session_state (
      session_directory TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE, store TEXT NOT NULL,
      phase TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS capture_chunks (
      session_directory TEXT NOT NULL, chunk_id TEXT NOT NULL, file TEXT NOT NULL, sha256 TEXT NOT NULL,
      ordinal INTEGER NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(session_directory, chunk_id)
    );
    CREATE TABLE IF NOT EXISTS capture_payloads (
      session_directory TEXT NOT NULL, payload_id TEXT NOT NULL, kind TEXT NOT NULL, file TEXT NOT NULL,
      sha256 TEXT NOT NULL, content_type TEXT NOT NULL, body BLOB NOT NULL, created_at TEXT NOT NULL,
      PRIMARY KEY(session_directory, payload_id)
    );
    CREATE TABLE IF NOT EXISTS capture_work_units (
      id TEXT PRIMARY KEY, session_directory TEXT NOT NULL, store TEXT NOT NULL, phase TEXT NOT NULL,
      unit_key TEXT NOT NULL, ordinal INTEGER NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL,
      priority INTEGER NOT NULL DEFAULT 0, available_at INTEGER NOT NULL, lease_owner TEXT,
      lease_expires_at INTEGER, attempts INTEGER NOT NULL DEFAULT 0, result_chunk_id TEXT,
      last_error TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      UNIQUE(session_directory, phase, unit_key)
    );
    CREATE INDEX IF NOT EXISTS capture_work_due_idx ON capture_work_units(status, available_at, priority DESC, ordinal);
    CREATE TABLE IF NOT EXISTS capture_executors (
      owner TEXT PRIMARY KEY, store TEXT, current_unit_id TEXT, metadata_json TEXT NOT NULL,
      last_heartbeat_at INTEGER NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS capture_challenges (
      id TEXT PRIMARY KEY, store TEXT NOT NULL, session_directory TEXT, work_unit_id TEXT,
      status TEXT NOT NULL, detail_json TEXT NOT NULL, opened_at TEXT NOT NULL,
      acknowledged_at TEXT, resolved_at TEXT, updated_at TEXT NOT NULL
    );
    DROP INDEX IF EXISTS capture_challenge_open_store_idx;
    CREATE UNIQUE INDEX IF NOT EXISTS capture_challenge_open_store_idx ON capture_challenges(store) WHERE status IN ('open', 'acknowledged');
    CREATE TABLE IF NOT EXISTS store_rate_budgets (
      store TEXT PRIMARY KEY, tokens REAL NOT NULL, capacity REAL NOT NULL, refill_ms INTEGER NOT NULL,
      last_refill_at INTEGER NOT NULL, next_eligible_at INTEGER NOT NULL, pressure REAL NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS store_rate_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, store TEXT NOT NULL, observed_at INTEGER NOT NULL, outcome TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS store_rate_events_window_idx ON store_rate_events(store, observed_at);
    CREATE TABLE IF NOT EXISTS planner_history (
      namespace TEXT NOT NULL, query_key TEXT NOT NULL, stats_json TEXT NOT NULL, observed_at TEXT NOT NULL,
      PRIMARY KEY(namespace, query_key)
    );
    CREATE TABLE IF NOT EXISTS lane_state (store TEXT PRIMARY KEY, state_json TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS lane_leases (store TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at INTEGER NOT NULL, acquired_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS controller_state (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS capture_source_state (
      job_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, captured_to TEXT NOT NULL, coverage_mode TEXT NOT NULL,
      local_status TEXT NOT NULL, remote_status TEXT, match_status TEXT, enqueued_at TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS capture_source_latest_idx ON capture_source_state(source_id, captured_to DESC, enqueued_at DESC);
    CREATE TABLE IF NOT EXISTS capture_catalog_products (
      store TEXT NOT NULL, product_key TEXT NOT NULL, name TEXT NOT NULL, size_text TEXT NOT NULL,
      taxonomy_path TEXT, purchase_price_minor INTEGER NOT NULL, page_url TEXT NOT NULL,
      first_observed_at TEXT NOT NULL, last_observed_at TEXT NOT NULL, last_session_at TEXT NOT NULL,
      PRIMARY KEY(store, product_key)
    );
    CREATE INDEX IF NOT EXISTS capture_catalog_stale_idx ON capture_catalog_products(store, last_observed_at, product_key);
    CREATE TABLE IF NOT EXISTS capture_catalog_query_edges (
      store TEXT NOT NULL, query_key TEXT NOT NULL, product_key TEXT NOT NULL,
      first_observed_at TEXT NOT NULL, last_observed_at TEXT NOT NULL, observations INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY(store, query_key, product_key),
      FOREIGN KEY(store, product_key) REFERENCES capture_catalog_products(store, product_key)
    );
    CREATE INDEX IF NOT EXISTS capture_catalog_query_idx ON capture_catalog_query_edges(store, query_key, last_observed_at DESC);
  `);
  databases.set(key, db);
  return db;
}

export function replaceCatalogSnapshot(store, rows, sessionAt = new Date().toISOString(), file) {
  const db = database(file);
  const product = db.prepare(`INSERT INTO capture_catalog_products
    (store, product_key, name, size_text, taxonomy_path, purchase_price_minor, page_url, first_observed_at, last_observed_at, last_session_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(store, product_key) DO UPDATE SET name=excluded.name, size_text=excluded.size_text,
      taxonomy_path=COALESCE(excluded.taxonomy_path, capture_catalog_products.taxonomy_path),
      purchase_price_minor=excluded.purchase_price_minor, page_url=excluded.page_url,
      last_observed_at=MAX(capture_catalog_products.last_observed_at, excluded.last_observed_at),
      last_session_at=excluded.last_session_at`);
  const edge = db.prepare(`INSERT INTO capture_catalog_query_edges
    (store, query_key, product_key, first_observed_at, last_observed_at, observations)
    VALUES (?, ?, ?, ?, ?, 1) ON CONFLICT(store, query_key, product_key) DO UPDATE SET
      last_observed_at=MAX(capture_catalog_query_edges.last_observed_at, excluded.last_observed_at),
      observations=capture_catalog_query_edges.observations + 1`);
  db.exec("BEGIN IMMEDIATE");
  try {
    for (const row of rows) {
      product.run(store, row.productKey, row.name, row.sizeText, row.taxonomyPath ?? null,
        row.purchasePriceMinor, row.pageUrl, row.observedAt, row.observedAt, sessionAt);
      edge.run(store, row.queryKey, row.productKey, row.observedAt, row.observedAt);
    }
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
  return { store, products: new Set(rows.map((row) => row.productKey)).size, edges: rows.length, sessionAt };
}

export function readCatalogQueryStats(store, now = new Date(), file) {
  const rows = database(file).prepare(`SELECT edge.query_key, COUNT(*) AS product_count,
    MAX(edge.last_observed_at) AS last_observed_at, SUM(edge.observations) AS observations
    FROM capture_catalog_query_edges edge WHERE edge.store = ? GROUP BY edge.query_key`).all(store);
  return Object.fromEntries(rows.map((row) => [row.query_key, {
    productCount: Number(row.product_count), observations: Number(row.observations),
    lastObservedAt: row.last_observed_at,
    ageDays: Math.max(0, Math.floor((now.getTime() - Date.parse(row.last_observed_at)) / 86_400_000)),
  }]));
}

export function catalogRefreshPlan(store, maxAgeDays = 7, limit = 500, now = new Date(), file) {
  const cutoff = new Date(now.getTime() - maxAgeDays * 86_400_000).toISOString();
  return database(file).prepare(`SELECT product_key AS productKey, name, size_text AS sizeText,
    taxonomy_path AS taxonomyPath, purchase_price_minor AS previousPriceMinor, page_url AS pageUrl,
    last_observed_at AS lastObservedAt FROM capture_catalog_products
    WHERE store = ? AND last_observed_at <= ? ORDER BY last_observed_at, product_key LIMIT ?`).all(store, cutoff, limit);
}

export function upsertQueueJournalJob(job, file) {
  const db = database(file);
  let parsedManifest;
  let durableManifestJson = job.manifestJson;
  try {
    parsedManifest = JSON.parse(job.manifestJson);
    if (parsedManifest.receipt && typeof parsedManifest.receipt === "object") {
      const receipt = { ...parsedManifest.receipt };
      delete receipt.remoteCheckedAt;
      durableManifestJson = JSON.stringify({ ...parsedManifest, receipt });
    }
  } catch { /* malformed manifests are surfaced by the queue validator */ }
  db.prepare(`INSERT INTO queue_jobs
    (id, directory, source_id, status, enqueued_at, next_attempt_at, manifest_json, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET directory=excluded.directory, source_id=excluded.source_id, status=excluded.status,
      enqueued_at=excluded.enqueued_at, next_attempt_at=excluded.next_attempt_at,
      manifest_json=excluded.manifest_json, updated_at=excluded.updated_at
    WHERE queue_jobs.directory IS NOT excluded.directory OR queue_jobs.source_id IS NOT excluded.source_id
      OR queue_jobs.status IS NOT excluded.status OR queue_jobs.enqueued_at IS NOT excluded.enqueued_at
      OR queue_jobs.next_attempt_at IS NOT excluded.next_attempt_at OR queue_jobs.manifest_json IS NOT excluded.manifest_json`)
    .run(job.id, job.directory, job.sourceId, job.status, job.enqueuedAt, job.nextAttemptAt, durableManifestJson, new Date().toISOString());
  try {
    const manifest = parsedManifest ?? JSON.parse(job.manifestJson);
    const summary = manifest.captureSummary;
    if (summary?.capturedTo && summary?.coverageMode) {
      const remote = manifest.receipt?.remote;
      db.prepare(`INSERT INTO capture_source_state
        (job_id, source_id, captured_to, coverage_mode, local_status, remote_status, match_status, enqueued_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(job_id) DO UPDATE SET local_status=excluded.local_status,
        remote_status=excluded.remote_status, match_status=excluded.match_status, updated_at=excluded.updated_at
        WHERE capture_source_state.local_status IS NOT excluded.local_status
          OR capture_source_state.remote_status IS NOT excluded.remote_status
          OR capture_source_state.match_status IS NOT excluded.match_status`)
        .run(job.id, job.sourceId, summary.capturedTo, summary.coverageMode, job.status, remote?.status ?? null,
          remote?.matching?.status ?? null, job.enqueuedAt, new Date().toISOString());
    }
  } catch { /* malformed manifests are surfaced by the queue validator */ }
}

function centralDateParts(instant) {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit", weekday: "short" }).formatToParts(instant);
  const value = Object.fromEntries(parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  return { dateKey: `${value.year}-${value.month}-${value.day}`, weekday: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(value.weekday) };
}

function shiftDateKey(dateKey, days) {
  const date = new Date(`${dateKey}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

export function browserCaptureJournalDueState(now = new Date(), file) {
  const required = ["direct-aldi-browser", "direct-fareway-browser", "direct-sams-browser", "direct-walmart-browser"];
  const db = database(file);
  const current = centralDateParts(now);
  const weekStart = shiftDateKey(current.dateKey, -((current.weekday - 3 + 7) % 7));
  const rows = db.prepare(`SELECT state.* FROM capture_source_state state JOIN (
    SELECT source_id, MAX(captured_to || '|' || enqueued_at) AS latest FROM capture_source_state GROUP BY source_id
  ) ranked ON ranked.source_id = state.source_id AND ranked.latest = state.captured_to || '|' || state.enqueued_at`).all();
  if (!required.every((source) => rows.some((row) => row.source_id === source))) return null;
  const due = [], inflight = [], completed = [];
  for (const source of required) {
    const row = rows.find((candidate) => candidate.source_id === source);
    const captureDate = centralDateParts(new Date(row.captured_to)).dateKey;
    const currentWeek = captureDate >= weekStart;
    const ready = currentWeek && row.coverage_mode === "full" && row.local_status === "completed"
      && ["promoted", "superseded"].includes(row.remote_status) && row.match_status === "passed";
    if (ready) completed.push(source);
    else if (currentWeek && ["pending", "retrying", "completed"].includes(row.local_status)) inflight.push(source);
    else due.push(source);
  }
  return { status: due.length ? "due" : inflight.length ? "inflight" : "fresh", weekStart, due, inflight, completed, authority: "capture-journal" };
}

export function queueJournalJobs(file) {
  return database(file).prepare(`SELECT id, directory, source_id AS sourceId, status, enqueued_at AS enqueuedAt,
    next_attempt_at AS nextAttemptAt, manifest_json AS manifestJson FROM queue_jobs ORDER BY enqueued_at, id`).all();
}

export function acquireQueueJournalLease(jobId, owner, now, leaseMs = 15 * 60_000, file) {
  const db = database(file);
  db.prepare("DELETE FROM queue_leases WHERE expires_at <= ?").run(now.getTime());
  return db.prepare(`INSERT INTO queue_leases (job_id, owner, expires_at, acquired_at) VALUES (?, ?, ?, ?)
    ON CONFLICT(job_id) DO UPDATE SET owner=excluded.owner, expires_at=excluded.expires_at, acquired_at=excluded.acquired_at
    WHERE queue_leases.expires_at <= ?`).run(jobId, owner, now.getTime() + leaseMs, now.toISOString(), now.getTime()).changes === 1;
}

export function releaseQueueJournalLease(jobId, owner, file) {
  database(file).prepare("DELETE FROM queue_leases WHERE job_id = ? AND owner = ?").run(jobId, owner);
}

export function upsertSessionJournal(directory, draft, file) {
  const db = database(file);
  const now = new Date().toISOString();
  db.prepare(`INSERT INTO capture_sessions (directory, session_id, store, draft_json, updated_at) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(directory) DO UPDATE SET session_id=excluded.session_id, store=excluded.store,
      draft_json=excluded.draft_json, updated_at=excluded.updated_at`)
    .run(path.resolve(directory), draft.sessionId, draft.store, JSON.stringify(draft), now);
  db.prepare(`INSERT INTO capture_session_state (session_directory, session_id, store, phase, updated_at)
    VALUES (?, ?, ?, 'initialized', ?) ON CONFLICT(session_directory) DO UPDATE SET
    session_id=excluded.session_id, store=excluded.store, updated_at=excluded.updated_at`)
    .run(path.resolve(directory), draft.sessionId, draft.store, now);
  for (const [ordinal, chunk] of (draft.chunks ?? []).entries()) db.prepare(`INSERT INTO capture_chunks
    (session_directory, chunk_id, file, sha256, ordinal, created_at) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(session_directory, chunk_id) DO UPDATE SET file=excluded.file, sha256=excluded.sha256,
      ordinal=excluded.ordinal, created_at=excluded.created_at`)
    .run(path.resolve(directory), chunk.id, chunk.file, chunk.sha256, ordinal, chunk.createdAt);
}

export function commitSessionChunk(directory, draft, entry, body, file) {
  const db = database(file);
  const resolved = path.resolve(directory);
  const now = new Date().toISOString();
  db.exec("BEGIN IMMEDIATE");
  try {
    const prior = db.prepare("SELECT sha256 FROM capture_payloads WHERE session_directory = ? AND payload_id = ?").get(resolved, entry.id);
    if (prior && prior.sha256 !== entry.sha256) throw new Error(`capture payload identity collision for ${entry.id}`);
    db.prepare(`INSERT INTO capture_sessions (directory, session_id, store, draft_json, updated_at) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(directory) DO UPDATE SET session_id=excluded.session_id, store=excluded.store,
        draft_json=excluded.draft_json, updated_at=excluded.updated_at`)
      .run(resolved, draft.sessionId, draft.store, JSON.stringify(draft), now);
    db.prepare(`INSERT INTO capture_chunks (session_directory, chunk_id, file, sha256, ordinal, created_at)
      VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(session_directory, chunk_id) DO UPDATE SET
      file=excluded.file, sha256=excluded.sha256, ordinal=excluded.ordinal, created_at=excluded.created_at`)
      .run(resolved, entry.id, entry.file, entry.sha256, draft.chunks.findIndex((chunk) => chunk.id === entry.id), entry.createdAt);
    db.prepare(`INSERT INTO capture_payloads
      (session_directory, payload_id, kind, file, sha256, content_type, body, created_at)
      VALUES (?, ?, 'chunk', ?, ?, 'application/json', ?, ?)
      ON CONFLICT(session_directory, payload_id) DO UPDATE SET file=excluded.file, sha256=excluded.sha256,
      content_type=excluded.content_type, body=excluded.body, created_at=excluded.created_at`)
      .run(resolved, entry.id, entry.file, entry.sha256, body, entry.createdAt);
    const parsed = JSON.parse(Buffer.from(body).toString("utf8").replace(/^\uFEFF/, ""));
    const outcomes = parsed.phase === "discovery"
      ? (parsed.terms ?? []).map((term) => ({ key: term.query, outcome: term.outcome, reason: term.reason }))
      : (parsed.verifications ?? []).map((verification) => ({ key: verification.rowKey, outcome: verification.outcome, reason: verification.reason }));
    const transition = db.prepare(`UPDATE capture_work_units SET status = ?, result_chunk_id = ?, available_at = ?,
      lease_owner = NULL, lease_expires_at = NULL, last_error = ?, updated_at = ?
      WHERE session_directory = ? AND phase = ? AND unit_key = ?`);
    const affectedOwners = new Set();
    for (const item of outcomes) {
      const leased = db.prepare(`SELECT lease_owner FROM capture_work_units
        WHERE session_directory = ? AND phase = ? AND unit_key = ?`).get(resolved, parsed.phase, item.key);
      if (leased?.lease_owner) affectedOwners.add(leased.lease_owner);
      const terminal = parsed.phase === "discovery" ? ["success", "empty"].includes(item.outcome) : item.outcome === "observed";
      const blocked = item.outcome === "blocked";
      transition.run(terminal ? "completed" : blocked ? "blocked" : "queued", entry.id,
        terminal || blocked ? Date.now() : Date.now() + 60_000, terminal ? null : String(item.reason ?? `${item.outcome} requires retry`).slice(0, 2000),
        now, resolved, parsed.phase, item.key);
    }
    for (const owner of affectedOwners) db.prepare(`DELETE FROM capture_executors WHERE owner = ?
      AND NOT EXISTS (SELECT 1 FROM capture_work_units WHERE lease_owner = ? AND status = 'leased')`).run(owner, owner);
    const remaining = Number(db.prepare(`SELECT COUNT(*) AS count FROM capture_work_units
      WHERE session_directory = ? AND phase = ? AND status <> 'completed'`).get(resolved, parsed.phase).count);
    if (remaining === 0) db.prepare(`UPDATE capture_session_state SET phase = ?, updated_at = ? WHERE session_directory = ?`)
      .run(parsed.phase === "discovery" ? "verification_plan_required" : "ready_to_finalize", now, resolved);
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

export function readSessionPayload(directory, payloadId, file) {
  const row = database(file).prepare(`SELECT file, sha256, content_type AS contentType, body, kind, created_at AS createdAt
    FROM capture_payloads WHERE session_directory = ? AND payload_id = ?`).get(path.resolve(directory), payloadId);
  if (!row) return null;
  return { ...row, body: new Uint8Array(row.body) };
}

export function storeSessionEvidence(directory, input, file) {
  const db = database(file);
  const resolved = path.resolve(directory);
  const prior = db.prepare("SELECT sha256 FROM capture_payloads WHERE session_directory = ? AND payload_id = ?").get(resolved, input.id);
  if (prior && prior.sha256 !== input.sha256) throw new Error(`capture evidence identity collision for ${input.id}`);
  db.prepare(`INSERT INTO capture_payloads
    (session_directory, payload_id, kind, file, sha256, content_type, body, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(session_directory, payload_id) DO UPDATE SET
    file=excluded.file, sha256=excluded.sha256, content_type=excluded.content_type, body=excluded.body, created_at=excluded.created_at`)
    .run(resolved, input.id, input.kind, input.file, input.sha256, input.contentType, input.body, input.createdAt);
}

export function sessionEvidence(directory, file) {
  return database(file).prepare(`SELECT payload_id AS id, kind, file, sha256, content_type AS contentType,
    length(body) AS byteLength, created_at AS createdAt FROM capture_payloads
    WHERE session_directory = ? AND kind <> 'chunk' ORDER BY created_at, payload_id`).all(path.resolve(directory));
}

export function replaceSessionWorkUnits(directory, store, phase, units, observedAt = new Date().toISOString(), file) {
  const db = database(file);
  const resolved = path.resolve(directory);
  const nowMs = Date.parse(observedAt);
  db.exec("BEGIN IMMEDIATE");
  try {
    const insert = db.prepare(`INSERT INTO capture_work_units
      (id, session_directory, store, phase, unit_key, ordinal, payload_json, status, priority, available_at,
       attempts, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, 0, ?, ?)
      ON CONFLICT(session_directory, phase, unit_key) DO UPDATE SET payload_json=excluded.payload_json,
        priority=excluded.priority, ordinal=excluded.ordinal, updated_at=excluded.updated_at
      WHERE capture_work_units.status <> 'completed'`);
    for (const unit of units) {
      const id = `work-${createHash("sha256").update(`${resolved}|${phase}|${unit.key}`).digest("hex").slice(0, 32)}`;
      insert.run(id, resolved, store, phase, unit.key, unit.ordinal, JSON.stringify(unit.payload ?? {}), unit.priority ?? 0, nowMs, observedAt, observedAt);
    }
    const session = db.prepare("SELECT session_id FROM capture_sessions WHERE directory = ?").get(resolved);
    if (session) db.prepare(`INSERT INTO capture_session_state (session_directory, session_id, store, phase, updated_at)
      VALUES (?, ?, ?, ?, ?) ON CONFLICT(session_directory) DO UPDATE SET phase=excluded.phase, updated_at=excluded.updated_at`)
      .run(resolved, session.session_id, store, phase === "verification" && units.length === 0 ? "ready_to_finalize" : phase, observedAt);
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

export function setCaptureSessionPhase(sessionId, phase, observedAt = new Date().toISOString(), file) {
  const allowed = ["initialized", "discovery", "verification_plan_required", "verification", "ready_to_finalize", "finalized", "enqueued", "abandoned"];
  if (!allowed.includes(phase)) throw new Error(`unsupported capture session phase: ${phase}`);
  const changed = database(file).prepare("UPDATE capture_session_state SET phase = ?, updated_at = ? WHERE session_id = ?")
    .run(phase, observedAt, sessionId).changes;
  return { changed: changed === 1, sessionId, phase };
}

export function abandonCaptureSessionWork(directory, reason, observedAt = new Date().toISOString(), file) {
  const db = database(file);
  const resolved = path.resolve(directory);
  const session = db.prepare("SELECT session_id FROM capture_session_state WHERE session_directory = ?").get(resolved);
  if (!session) return { abandoned: false, idempotent: true, reason: "session-not-journaled" };
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(`UPDATE capture_work_units SET status = 'cancelled', lease_owner = NULL, lease_expires_at = NULL,
      last_error = ?, updated_at = ? WHERE session_directory = ? AND status <> 'completed'`).run(String(reason).slice(0, 2000), observedAt, resolved);
    db.prepare("DELETE FROM capture_executors WHERE current_unit_id IN (SELECT id FROM capture_work_units WHERE session_directory = ?)").run(resolved);
    db.prepare("UPDATE capture_session_state SET phase = 'abandoned', updated_at = ? WHERE session_directory = ?").run(observedAt, resolved);
    db.exec("COMMIT");
    return { abandoned: true, idempotent: false, sessionId: session.session_id, sessionDirectory: resolved };
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

export function completeSessionWorkUnits(directory, phase, unitKeys, resultChunkId = "reconciled", file) {
  const db = database(file);
  const statement = db.prepare(`UPDATE capture_work_units SET status = 'completed', result_chunk_id = ?,
    lease_owner = NULL, lease_expires_at = NULL, last_error = NULL, updated_at = ?
    WHERE session_directory = ? AND phase = ? AND unit_key = ?`);
  const now = new Date().toISOString();
  const resolved = path.resolve(directory);
  for (const key of unitKeys) statement.run(resultChunkId, now, resolved, phase, key);
  const remaining = Number(db.prepare(`SELECT COUNT(*) AS count FROM capture_work_units
    WHERE session_directory = ? AND phase = ? AND status <> 'completed'`).get(resolved, phase).count);
  if (remaining === 0 && unitKeys.length > 0) db.prepare("UPDATE capture_session_state SET phase = ?, updated_at = ? WHERE session_directory = ?")
    .run(phase === "discovery" ? "verification_plan_required" : "ready_to_finalize", now, resolved);
}

const RATE_DEFAULTS = {
  aldi: { capacity: 1, refillMs: 5_000, hourly: 360, daily: 1_800 }, fareway: { capacity: 2, refillMs: 2_000, hourly: 900, daily: 3_000 },
  sams: { capacity: 1, refillMs: 3_000, hourly: 600, daily: 2_500 }, walmart: { capacity: 2, refillMs: 1_500, hourly: 900, daily: 3_000 },
};

function reserveStoreToken(db, store, nowMs) {
  const defaults = RATE_DEFAULTS[store];
  if (!defaults) return { allowed: false, retryAt: nowMs + 60_000 };
  db.prepare("DELETE FROM store_rate_events WHERE observed_at < ?").run(nowMs - 24 * 60 * 60_000);
  const hourly = Number(db.prepare("SELECT COUNT(*) AS count FROM store_rate_events WHERE store = ? AND observed_at >= ?").get(store, nowMs - 60 * 60_000).count);
  const daily = Number(db.prepare("SELECT COUNT(*) AS count FROM store_rate_events WHERE store = ? AND observed_at >= ?").get(store, nowMs - 24 * 60 * 60_000).count);
  if (hourly >= defaults.hourly || daily >= defaults.daily) {
    const windowMs = hourly >= defaults.hourly ? 60 * 60_000 : 24 * 60 * 60_000;
    const oldest = db.prepare("SELECT MIN(observed_at) AS observedAt FROM store_rate_events WHERE store = ? AND observed_at >= ?").get(store, nowMs - windowMs);
    return { allowed: false, retryAt: Number(oldest.observedAt) + windowMs + 1, budget: hourly >= defaults.hourly ? "hourly" : "daily" };
  }
  let row = db.prepare("SELECT * FROM store_rate_budgets WHERE store = ?").get(store);
  if (!row) {
    db.prepare(`INSERT INTO store_rate_budgets
      (store, tokens, capacity, refill_ms, last_refill_at, next_eligible_at, pressure, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 0, ?)`)
      .run(store, defaults.capacity, defaults.capacity, defaults.refillMs, nowMs, nowMs, new Date(nowMs).toISOString());
    row = db.prepare("SELECT * FROM store_rate_budgets WHERE store = ?").get(store);
  }
  const elapsed = Math.max(0, nowMs - Number(row.last_refill_at));
  const refillMs = Math.max(defaults.refillMs, Number(row.refill_ms));
  const capacity = Number(row.capacity);
  const tokens = Math.min(capacity, Number(row.tokens) + elapsed / refillMs);
  const nextEligible = Math.max(Number(row.next_eligible_at), nowMs);
  if (tokens < 1 || nextEligible > nowMs) {
    const retryAt = Math.max(nextEligible, nowMs + Math.ceil((1 - tokens) * refillMs));
    db.prepare("UPDATE store_rate_budgets SET tokens = ?, last_refill_at = ?, updated_at = ? WHERE store = ?")
      .run(tokens, nowMs, new Date(nowMs).toISOString(), store);
    return { allowed: false, retryAt };
  }
  db.prepare("UPDATE store_rate_budgets SET tokens = ?, last_refill_at = ?, next_eligible_at = ?, updated_at = ? WHERE store = ?")
    .run(tokens - 1, nowMs, nowMs + refillMs, new Date(nowMs).toISOString(), store);
  db.prepare("INSERT INTO store_rate_events (store, observed_at, outcome) VALUES (?, ?, 'leased')").run(store, nowMs);
  return { allowed: true, retryAt: nowMs + refillMs };
}

export function leaseCaptureWork(owner, requestedStore, now = new Date(), ttlMs = 5 * 60_000, file, requestedCount = 1) {
  const db = database(file);
  const nowMs = now.getTime();
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(`UPDATE capture_work_units SET status = 'queued', lease_owner = NULL, lease_expires_at = NULL,
      available_at = ?, updated_at = ? WHERE status = 'leased' AND lease_expires_at <= ?`)
      .run(nowMs, now.toISOString(), nowMs);
    // Executor rows are capacity reservations, not independent leases. A
    // controller restart can outlive the work lease's in-memory finally
    // handler, so remove any executor that no longer owns leased work before
    // enforcing the one-lane-per-store, four-store concurrency ceiling.
    db.prepare(`DELETE FROM capture_executors WHERE NOT EXISTS (
      SELECT 1 FROM capture_work_units work
      WHERE work.lease_owner = capture_executors.owner AND work.status = 'leased'
    )`).run();
    db.prepare("DELETE FROM capture_executors WHERE last_heartbeat_at <= ?").run(nowMs - 10 * 60_000);
    const candidates = db.prepare(`SELECT work.* FROM capture_work_units work
      WHERE work.status = 'queued' AND work.available_at <= ?
        AND (? IS NULL OR work.store = ?)
        AND NOT EXISTS (SELECT 1 FROM capture_challenges c WHERE c.store = work.store AND c.status IN ('open', 'acknowledged'))
        AND NOT EXISTS (SELECT 1 FROM capture_executors active WHERE active.store = work.store)
        AND ((SELECT COUNT(DISTINCT store) FROM capture_executors) < 4
          OR EXISTS (SELECT 1 FROM capture_executors active WHERE active.store = work.store))
      ORDER BY CASE WHEN work.attempts = 0 THEN 0 ELSE 1 END, work.priority DESC, work.available_at, work.ordinal LIMIT 16`).all(nowMs, requestedStore || null, requestedStore || null);
    let selected;
    let retryAt;
    for (const candidate of candidates) {
      const token = reserveStoreToken(db, candidate.store, nowMs);
      retryAt = retryAt === undefined ? token.retryAt : Math.min(retryAt, token.retryAt);
      if (token.allowed) { selected = candidate; break; }
    }
    if (!selected) { db.exec("COMMIT"); return { acquired: false, reason: candidates.length ? "rate-limited" : "no-work", retryAt }; }
    const count = Math.max(1, Math.min(5, Number(requestedCount) || 1));
    const selectedBatch = db.prepare(`SELECT * FROM capture_work_units
      WHERE status = 'queued' AND available_at <= ? AND store = ? AND session_directory = ? AND phase = ?
      ORDER BY CASE WHEN attempts = 0 THEN 0 ELSE 1 END, priority DESC, available_at, ordinal LIMIT ?`).all(nowMs, selected.store, selected.session_directory, selected.phase, count);
    const expiresAt = nowMs + Math.max(30_000, Math.min(ttlMs, 30 * 60_000));
    // A work candidate can only be selected when its store has no active
    // executor. Any adapter lane left for that store is therefore orphaned
    // (most commonly after a controller restart) and must not block the new
    // fenced executor for the remainder of the adapter's 15-minute TTL.
    db.prepare("DELETE FROM lane_leases WHERE store = ?").run(selected.store);
    const lease = db.prepare(`UPDATE capture_work_units SET status = 'leased', lease_owner = ?, lease_expires_at = ?,
      attempts = attempts + 1, updated_at = ? WHERE id = ? AND status = 'queued'`);
    for (const work of selectedBatch) lease.run(owner, expiresAt, now.toISOString(), work.id);
    db.prepare(`INSERT INTO capture_executors (owner, store, current_unit_id, metadata_json, last_heartbeat_at, updated_at)
      VALUES (?, ?, ?, '{}', ?, ?) ON CONFLICT(owner) DO UPDATE SET store=excluded.store,
      current_unit_id=excluded.current_unit_id, last_heartbeat_at=excluded.last_heartbeat_at, updated_at=excluded.updated_at`)
      .run(owner, selected.store, selected.id, nowMs, now.toISOString());
    db.exec("COMMIT");
    const works = selectedBatch.map((work) => ({ id: work.id, sessionDirectory: work.session_directory, store: work.store,
      phase: work.phase, unitKey: work.unit_key, ordinal: work.ordinal, payload: JSON.parse(work.payload_json),
      attempts: Number(work.attempts) + 1, leaseExpiresAt: new Date(expiresAt).toISOString() }));
    return { acquired: true, work: works[0], works };
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

export function heartbeatCaptureWork(owner, workId, now = new Date(), ttlMs = 5 * 60_000, metadata = {}, file) {
  const db = database(file);
  const expiresAt = now.getTime() + Math.max(30_000, Math.min(ttlMs, 30 * 60_000));
  const changed = db.prepare(`UPDATE capture_work_units SET lease_expires_at = ?, updated_at = ?
    WHERE id = ? AND status = 'leased' AND lease_owner = ?`).run(expiresAt, now.toISOString(), workId, owner).changes;
  if (!changed) return { renewed: false };
  db.prepare(`INSERT INTO capture_executors (owner, current_unit_id, metadata_json, last_heartbeat_at, updated_at)
    VALUES (?, ?, ?, ?, ?) ON CONFLICT(owner) DO UPDATE SET current_unit_id=excluded.current_unit_id,
    metadata_json=excluded.metadata_json, last_heartbeat_at=excluded.last_heartbeat_at, updated_at=excluded.updated_at`)
    .run(owner, workId, JSON.stringify(metadata), now.getTime(), now.toISOString());
  return { renewed: true, leaseExpiresAt: new Date(expiresAt).toISOString() };
}

export function failCaptureWork(owner, workId, error, retryAt = new Date(), file) {
  const db = database(file);
  const status = retryAt ? "queued" : "failed";
  db.prepare(`UPDATE capture_work_units SET status = ?, available_at = ?, lease_owner = NULL,
    lease_expires_at = NULL, last_error = ?, updated_at = ? WHERE id = ? AND lease_owner = ?`)
    .run(status, retryAt?.getTime?.() ?? Date.now(), String(error).slice(0, 2000), new Date().toISOString(), workId, owner);
  db.prepare("DELETE FROM capture_executors WHERE owner = ?").run(owner);
}

export function openCaptureChallenge(store, detail = {}, now = new Date(), file) {
  const db = database(file);
  const existing = db.prepare("SELECT id FROM capture_challenges WHERE store = ? AND status IN ('open', 'acknowledged')").get(store);
  if (existing) return { id: existing.id, idempotent: true };
  const id = `challenge-${store}-${now.toISOString().replace(/[^0-9]/g, "").slice(0, 14)}-${crypto.randomUUID().slice(0, 8)}`;
  db.prepare(`INSERT INTO capture_challenges
    (id, store, session_directory, work_unit_id, status, detail_json, opened_at, updated_at)
    VALUES (?, ?, ?, ?, 'open', ?, ?, ?)`)
    .run(id, store, detail.sessionDirectory ? path.resolve(detail.sessionDirectory) : null, detail.workUnitId ?? null, JSON.stringify(detail), now.toISOString(), now.toISOString());
  db.prepare(`UPDATE capture_work_units SET status = 'blocked', lease_owner = NULL, lease_expires_at = NULL,
    last_error = ?, updated_at = ? WHERE store = ? AND status = 'leased'`)
    .run(String(detail.reason ?? "retailer challenge detected").slice(0, 2000), now.toISOString(), store);
  db.prepare("DELETE FROM capture_executors WHERE store = ?").run(store);
  return { id, idempotent: false };
}

export function acknowledgeCaptureChallenge(id, now = new Date(), file) {
  const db = database(file);
  const challenge = db.prepare("SELECT store FROM capture_challenges WHERE id = ? AND status = 'open'").get(id);
  if (!challenge) return { acknowledged: false };
  db.prepare(`UPDATE capture_challenges SET status = 'acknowledged', acknowledged_at = ?, updated_at = ? WHERE id = ?`)
    .run(now.toISOString(), now.toISOString(), id);
  return { acknowledged: true, store: challenge.store, requiresCanary: true };
}

export function resolveCaptureChallenge(id, canaryPassed, now = new Date(), file) {
  const db = database(file);
  const challenge = db.prepare("SELECT store FROM capture_challenges WHERE id = ? AND status = 'acknowledged'").get(id);
  if (!challenge || canaryPassed !== true) return { resolved: false, requiresCanary: true };
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(`UPDATE capture_challenges SET status = 'resolved', resolved_at = ?, updated_at = ? WHERE id = ?`)
      .run(now.toISOString(), now.toISOString(), id);
    db.prepare(`UPDATE capture_work_units SET status = 'queued', available_at = ?, updated_at = ?
      WHERE store = ? AND status = 'blocked'`).run(now.getTime(), now.toISOString(), challenge.store);
    const lane = db.prepare("SELECT state_json FROM lane_state WHERE store = ?").get(challenge.store);
    if (lane?.state_json) {
      const state = JSON.parse(lane.state_json);
      db.prepare("UPDATE lane_state SET state_json = ?, updated_at = ? WHERE store = ?")
        .run(JSON.stringify({ ...state, consecutiveFailures: 0, circuitOpenUntil: null, lastOutcome: "canary_passed", lastCompletedAt: now.toISOString() }), now.toISOString(), challenge.store);
    }
    db.exec("COMMIT");
    return { resolved: true, store: challenge.store };
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

export function recordStoreRateResult(store, outcome, latencyMs, now = new Date(), file) {
  const db = database(file);
  const defaults = RATE_DEFAULTS[store];
  if (!defaults) throw new Error(`unsupported browser store ${store}`);
  const current = db.prepare("SELECT pressure, refill_ms FROM store_rate_budgets WHERE store = ?").get(store);
  const failure = outcome === "blocked" || outcome === "rejected";
  const latencyPressure = Math.max(0, Math.min(2, (Number(latencyMs) - 8_000) / 20_000));
  const pressure = failure ? Math.min(10, Number(current?.pressure ?? 0) + (outcome === "blocked" ? 4 : 1) + latencyPressure)
    : Math.max(0, Number(current?.pressure ?? 0) * 0.75 - 0.25 + latencyPressure);
  const refillMs = Math.max(defaults.refillMs, Math.min(60_000, Math.round(defaults.refillMs * (1 + pressure))));
  const jitter = Math.round(refillMs * (0.1 + Math.random() * 0.2));
  const cooldown = outcome === "blocked" ? 30 * 60_000 : failure ? refillMs + jitter : refillMs + jitter;
  db.prepare(`INSERT INTO store_rate_budgets
    (store, tokens, capacity, refill_ms, last_refill_at, next_eligible_at, pressure, updated_at)
    VALUES (?, 0, ?, ?, ?, ?, ?, ?) ON CONFLICT(store) DO UPDATE SET tokens=excluded.tokens,
      capacity=excluded.capacity, refill_ms=excluded.refill_ms, last_refill_at=excluded.last_refill_at,
      next_eligible_at=excluded.next_eligible_at, pressure=excluded.pressure, updated_at=excluded.updated_at`)
    .run(store, defaults.capacity, refillMs, now.getTime(), now.getTime() + cooldown, pressure, now.toISOString());
  return { store, pressure, refillMs, nextEligibleAt: new Date(now.getTime() + cooldown).toISOString(), latencyMs: Math.max(0, Math.round(latencyMs)) };
}

export function captureCoordinatorStatus(file, now = new Date()) {
  const db = database(file);
  const work = db.prepare("SELECT store, phase, status, COUNT(*) AS count FROM capture_work_units GROUP BY store, phase, status ORDER BY store, phase, status").all();
  const challenges = db.prepare("SELECT id, store, status, detail_json AS detailJson, opened_at AS openedAt, acknowledged_at AS acknowledgedAt FROM capture_challenges WHERE status <> 'resolved' ORDER BY opened_at").all()
    .map((row) => ({ ...row, detail: JSON.parse(row.detailJson), detailJson: undefined }));
  const executors = db.prepare("SELECT owner, store, current_unit_id AS currentUnitId, last_heartbeat_at AS lastHeartbeatAt FROM capture_executors ORDER BY owner").all();
  const budgets = db.prepare("SELECT store, tokens, capacity, refill_ms AS refillMs, next_eligible_at AS nextEligibleAt, pressure FROM store_rate_budgets ORDER BY store").all();
  const lanes = db.prepare(`SELECT lease.store, lease.owner, lease.expires_at AS expiresAt, lease.acquired_at AS acquiredAt,
    state.state_json AS stateJson FROM lane_leases lease LEFT JOIN lane_state state ON state.store = lease.store
    WHERE lease.expires_at > ? ORDER BY lease.store`).all(now.getTime()).map((row) => ({ ...row, state: row.stateJson ? JSON.parse(row.stateJson) : null, stateJson: undefined }));
  const sessions = db.prepare("SELECT session_id AS sessionId, session_directory AS sessionDirectory, store, phase, updated_at AS updatedAt FROM capture_session_state ORDER BY updated_at DESC").all();
  return { sessions, work, challenges, executors, lanes, budgets };
}

export function readSessionJournal(directory, file) {
  const row = database(file).prepare("SELECT draft_json FROM capture_sessions WHERE directory = ?").get(path.resolve(directory));
  return row?.draft_json ? JSON.parse(row.draft_json) : null;
}

export function readPlannerJournal(namespace, file) {
  const rows = database(file).prepare("SELECT query_key, stats_json FROM planner_history WHERE namespace = ? ORDER BY query_key").all(namespace);
  return Object.fromEntries(rows.map((row) => [row.query_key, JSON.parse(row.stats_json)]));
}

export function replacePlannerJournal(namespace, values, observedAt, file) {
  const db = database(file);
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare("DELETE FROM planner_history WHERE namespace = ?").run(namespace);
    const insert = db.prepare("INSERT INTO planner_history (namespace, query_key, stats_json, observed_at) VALUES (?, ?, ?, ?)");
    for (const [key, value] of Object.entries(values)) insert.run(namespace, key, JSON.stringify(value), observedAt);
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

function laneDatabase(environment) { return database(captureJournalPath(environment)); }

export function readLaneState(store, fallback, environment = process.env) {
  const row = laneDatabase(environment).prepare("SELECT state_json FROM lane_state WHERE store = ?").get(store);
  return row?.state_json ? { ...fallback, ...JSON.parse(row.state_json) } : fallback;
}

export function writeLaneState(store, state, environment = process.env) {
  laneDatabase(environment).prepare(`INSERT INTO lane_state (store, state_json, updated_at) VALUES (?, ?, ?)
    ON CONFLICT(store) DO UPDATE SET state_json=excluded.state_json, updated_at=excluded.updated_at`)
    .run(store, JSON.stringify(state), new Date().toISOString());
}

export function acquireLaneLease(store, owner, now = new Date(), ttlMs = 15 * 60_000, environment = process.env) {
  const db = laneDatabase(environment);
  db.prepare("DELETE FROM lane_leases WHERE expires_at <= ?").run(now.getTime());
  return db.prepare(`INSERT INTO lane_leases (store, owner, expires_at, acquired_at) VALUES (?, ?, ?, ?)
    ON CONFLICT(store) DO UPDATE SET owner=excluded.owner, expires_at=excluded.expires_at, acquired_at=excluded.acquired_at
    WHERE lane_leases.expires_at <= ?`).run(store, owner, now.getTime() + ttlMs, now.toISOString(), now.getTime()).changes === 1;
}

export function releaseLaneLease(store, owner, environment = process.env) {
  laneDatabase(environment).prepare("DELETE FROM lane_leases WHERE store = ? AND owner = ?").run(store, owner);
}

export function acquireControllerLane(store, owner, now = new Date(), ttlMs = 15 * 60_000, environment = process.env) {
  const db = laneDatabase(environment);
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare("DELETE FROM lane_leases WHERE expires_at <= ?").run(now.getTime());
    const existing = db.prepare("SELECT owner FROM lane_leases WHERE store = ?").get(store);
    if (existing && existing.owner !== owner) { db.exec("ROLLBACK"); return { acquired: false, reason: "store-active" }; }
    const active = Number(db.prepare("SELECT COUNT(*) AS count FROM lane_leases").get().count);
    if (!existing && active >= 4) { db.exec("ROLLBACK"); return { acquired: false, reason: "controller-capacity" }; }
    db.prepare(`INSERT INTO lane_leases (store, owner, expires_at, acquired_at) VALUES (?, ?, ?, ?)
      ON CONFLICT(store) DO UPDATE SET owner=excluded.owner, expires_at=excluded.expires_at, acquired_at=excluded.acquired_at`)
      .run(store, owner, now.getTime() + ttlMs, now.toISOString());
    db.exec("COMMIT");
    return { acquired: true, active: active + (existing ? 0 : 1) };
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

export function serializeCaptureJournal(file = captureJournalPath()) {
  const db = database(file);
  db.exec("PRAGMA wal_checkpoint(FULL)");
  if (typeof db.serialize !== "function") throw new Error("capture journal serialization requires Node 24.16 or newer");
  return db.serialize();
}

export function closeCaptureJournals() {
  for (const db of databases.values()) db.close();
  databases.clear();
}

export const closeBrowserCaptureJournals = closeCaptureJournals;
