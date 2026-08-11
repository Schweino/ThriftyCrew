import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";

const require = createRequire(import.meta.url);

export function captureJournalPath(environment = process.env) {
  if (environment.TC_CAPTURE_JOURNAL) return path.resolve(environment.TC_CAPTURE_JOURNAL);
  return path.join(environment.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "ThriftyCrew", "grocery-v3", "capture-journal.sqlite");
}

const databases = new Map();
function db(environment = process.env) {
  const file = captureJournalPath(environment);
  if (databases.has(file)) return databases.get(file);
  mkdirSync(path.dirname(file), { recursive: true });
  const { DatabaseSync } = require("node:sqlite");
  const database = new DatabaseSync(file);
  database.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = FULL;
    PRAGMA busy_timeout = 5000;
    CREATE TABLE IF NOT EXISTS lane_state (store TEXT PRIMARY KEY, state_json TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS lane_leases (store TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at INTEGER NOT NULL, acquired_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS controller_state (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at TEXT NOT NULL);
  `);
  databases.set(file, database);
  return database;
}

export function readLaneState(store, fallback, environment = process.env) {
  const row = db(environment).prepare("SELECT state_json FROM lane_state WHERE store = ?").get(store);
  return row?.state_json ? { ...fallback, ...JSON.parse(row.state_json) } : fallback;
}

export function writeLaneState(store, state, environment = process.env) {
  db(environment).prepare(`
    INSERT INTO lane_state (store, state_json, updated_at) VALUES (?, ?, ?)
    ON CONFLICT(store) DO UPDATE SET state_json = excluded.state_json, updated_at = excluded.updated_at
  `).run(store, JSON.stringify(state), new Date().toISOString());
}

export function acquireLaneLease(store, owner, now = new Date(), ttlMs = 15 * 60_000, environment = process.env) {
  const database = db(environment);
  database.prepare("DELETE FROM lane_leases WHERE expires_at <= ?").run(now.getTime());
  const result = database.prepare(`
    INSERT INTO lane_leases (store, owner, expires_at, acquired_at) VALUES (?, ?, ?, ?)
    ON CONFLICT(store) DO UPDATE SET owner = excluded.owner, expires_at = excluded.expires_at, acquired_at = excluded.acquired_at
      WHERE lane_leases.expires_at <= ?
  `).run(store, owner, now.getTime() + ttlMs, now.toISOString(), now.getTime());
  return result.changes === 1;
}

export function releaseLaneLease(store, owner, environment = process.env) {
  db(environment).prepare("DELETE FROM lane_leases WHERE store = ? AND owner = ?").run(store, owner);
}

export function acquireControllerLane(store, owner, now = new Date(), ttlMs = 15 * 60_000, environment = process.env) {
  const database = db(environment);
  database.exec("BEGIN IMMEDIATE");
  try {
    database.prepare("DELETE FROM lane_leases WHERE expires_at <= ?").run(now.getTime());
    const existing = database.prepare("SELECT owner FROM lane_leases WHERE store = ?").get(store);
    if (existing && existing.owner !== owner) {
      database.exec("ROLLBACK");
      return { acquired: false, reason: "store-active" };
    }
    const active = database.prepare("SELECT COUNT(*) AS count FROM lane_leases").get().count;
    if (!existing && active >= 2) {
      database.exec("ROLLBACK");
      return { acquired: false, reason: "controller-capacity" };
    }
    database.prepare(`INSERT INTO lane_leases (store, owner, expires_at, acquired_at) VALUES (?, ?, ?, ?)
      ON CONFLICT(store) DO UPDATE SET owner = excluded.owner, expires_at = excluded.expires_at, acquired_at = excluded.acquired_at`)
      .run(store, owner, now.getTime() + ttlMs, now.toISOString());
    database.exec("COMMIT");
    return { acquired: true, active: Number(active) + (existing ? 0 : 1) };
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
}

export function closeBrowserCaptureJournals() {
  for (const database of databases.values()) database.close();
  databases.clear();
}
