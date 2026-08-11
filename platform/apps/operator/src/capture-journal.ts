import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import type { DatabaseSync } from "node:sqlite";

export interface JournalQueueJob {
  id: string;
  directory: string;
  sourceId: string;
  status: string;
  enqueuedAt: string;
  nextAttemptAt: string;
  manifestJson: string;
}

export interface JournalLaneState {
  store: string;
  consecutiveFailures: number;
  dynamicDelayMs: number;
  lastOutcome?: string;
  lastLatencyMs?: number;
  lastCompletedAt?: string;
  circuitOpenUntil?: string | null;
}

function journalFile(environment: NodeJS.ProcessEnv = process.env): string {
  if (environment.TC_CAPTURE_JOURNAL) return path.resolve(environment.TC_CAPTURE_JOURNAL);
  if (environment.NODE_ENV === "test") return ":memory:";
  const localData = environment.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local");
  return path.join(localData, "ThriftyCrew", "grocery-v3", "capture-journal.sqlite");
}

const databases = new Map<string, DatabaseSync>();
const require = createRequire(import.meta.url);

function database(file = journalFile()): DatabaseSync {
  const key = path.resolve(file === ":memory:" ? path.join(process.cwd(), ".capture-journal-memory") : file);
  const existing = databases.get(key);
  if (existing) return existing;
  if (file !== ":memory:") mkdirSync(path.dirname(file), { recursive: true });
  const { DatabaseSync } = require("node:sqlite") as typeof import("node:sqlite");
  const db = new DatabaseSync(file);
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = FULL;
    PRAGMA busy_timeout = 5000;
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS queue_jobs (
      id TEXT PRIMARY KEY,
      directory TEXT NOT NULL UNIQUE,
      source_id TEXT NOT NULL,
      status TEXT NOT NULL,
      enqueued_at TEXT NOT NULL,
      next_attempt_at TEXT NOT NULL,
      manifest_json TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS queue_jobs_status_due_idx ON queue_jobs(status, next_attempt_at, enqueued_at);
    CREATE TABLE IF NOT EXISTS queue_leases (
      job_id TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      acquired_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS capture_sessions (
      directory TEXT PRIMARY KEY,
      session_id TEXT NOT NULL UNIQUE,
      store TEXT NOT NULL,
      draft_json TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS capture_chunks (
      session_directory TEXT NOT NULL,
      chunk_id TEXT NOT NULL,
      file TEXT NOT NULL,
      sha256 TEXT NOT NULL,
      ordinal INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY(session_directory, chunk_id)
    );
    CREATE TABLE IF NOT EXISTS planner_history (
      namespace TEXT NOT NULL,
      query_key TEXT NOT NULL,
      stats_json TEXT NOT NULL,
      observed_at TEXT NOT NULL,
      PRIMARY KEY(namespace, query_key)
    );
    CREATE TABLE IF NOT EXISTS lane_state (
      store TEXT PRIMARY KEY,
      state_json TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS lane_leases (
      store TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      acquired_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS controller_state (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  `);
  databases.set(key, db);
  return db;
}

export function upsertQueueJournalJob(job: JournalQueueJob, file?: string): void {
  database(file).prepare(`
    INSERT INTO queue_jobs (id, directory, source_id, status, enqueued_at, next_attempt_at, manifest_json, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      directory = excluded.directory, source_id = excluded.source_id, status = excluded.status,
      enqueued_at = excluded.enqueued_at, next_attempt_at = excluded.next_attempt_at,
      manifest_json = excluded.manifest_json, updated_at = excluded.updated_at
  `).run(job.id, job.directory, job.sourceId, job.status, job.enqueuedAt, job.nextAttemptAt, job.manifestJson, new Date().toISOString());
}

export function queueJournalJobs(file?: string): JournalQueueJob[] {
  return database(file).prepare(`
    SELECT id, directory, source_id AS sourceId, status, enqueued_at AS enqueuedAt,
           next_attempt_at AS nextAttemptAt, manifest_json AS manifestJson
      FROM queue_jobs ORDER BY enqueued_at, id
  `).all() as unknown as JournalQueueJob[];
}

export function acquireQueueJournalLease(jobId: string, owner: string, now: Date, leaseMs = 15 * 60_000, file?: string): boolean {
  const db = database(file);
  db.prepare("DELETE FROM queue_leases WHERE expires_at <= ?").run(now.getTime());
  const result = db.prepare(`
    INSERT INTO queue_leases (job_id, owner, expires_at, acquired_at) VALUES (?, ?, ?, ?)
    ON CONFLICT(job_id) DO UPDATE SET owner = excluded.owner, expires_at = excluded.expires_at, acquired_at = excluded.acquired_at
      WHERE queue_leases.expires_at <= ?
  `).run(jobId, owner, now.getTime() + leaseMs, now.toISOString(), now.getTime());
  return result.changes === 1;
}

export function releaseQueueJournalLease(jobId: string, owner: string, file?: string): void {
  database(file).prepare("DELETE FROM queue_leases WHERE job_id = ? AND owner = ?").run(jobId, owner);
}

export function upsertSessionJournal(directory: string, draft: { sessionId: string; store: string; chunks?: Array<{ id: string; file: string; sha256: string; createdAt: string }> }, file?: string): void {
  const db = database(file);
  const now = new Date().toISOString();
  db.prepare(`
    INSERT INTO capture_sessions (directory, session_id, store, draft_json, updated_at) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(directory) DO UPDATE SET session_id = excluded.session_id, store = excluded.store,
      draft_json = excluded.draft_json, updated_at = excluded.updated_at
  `).run(path.resolve(directory), draft.sessionId, draft.store, JSON.stringify(draft), now);
  for (const [ordinal, chunk] of (draft.chunks ?? []).entries()) {
    db.prepare(`
      INSERT INTO capture_chunks (session_directory, chunk_id, file, sha256, ordinal, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_directory, chunk_id) DO UPDATE SET
        file = excluded.file, sha256 = excluded.sha256, ordinal = excluded.ordinal, created_at = excluded.created_at
    `).run(path.resolve(directory), chunk.id, chunk.file, chunk.sha256, ordinal, chunk.createdAt);
  }
}

export function readSessionJournal<T>(directory: string, file?: string): T | null {
  const row = database(file).prepare("SELECT draft_json FROM capture_sessions WHERE directory = ?").get(path.resolve(directory)) as { draft_json?: string } | undefined;
  return row?.draft_json ? JSON.parse(row.draft_json) as T : null;
}

export function readPlannerJournal(namespace: string, file?: string): Record<string, Record<string, unknown>> {
  const rows = database(file).prepare("SELECT query_key, stats_json FROM planner_history WHERE namespace = ? ORDER BY query_key").all(namespace) as unknown as Array<{ query_key: string; stats_json: string }>;
  return Object.fromEntries(rows.map((row) => [row.query_key, JSON.parse(row.stats_json) as Record<string, unknown>]));
}

export function replacePlannerJournal(namespace: string, values: Record<string, Record<string, unknown>>, observedAt: string, file?: string): void {
  const db = database(file);
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare("DELETE FROM planner_history WHERE namespace = ?").run(namespace);
    const insert = db.prepare("INSERT INTO planner_history (namespace, query_key, stats_json, observed_at) VALUES (?, ?, ?, ?)");
    for (const [key, value] of Object.entries(values)) insert.run(namespace, key, JSON.stringify(value), observedAt);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

export function captureJournalPath(environment: NodeJS.ProcessEnv = process.env): string {
  return journalFile(environment);
}

export function closeCaptureJournals(): void {
  for (const db of databases.values()) db.close();
  databases.clear();
}
