import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import {
  acquireControllerLane,
  closeCaptureJournals,
  readPlannerJournal,
  readSessionJournal,
  replacePlannerJournal,
  serializeCaptureJournal,
  upsertQueueJournalJob,
  upsertSessionJournal,
} from "./capture-journal";

const roots: string[] = [];
afterEach(async () => {
  closeCaptureJournals();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("unified persistent capture journal", () => {
  it("stores queue, session, planner, and controller state in one recoverable SQLite image", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-journal-"));
    roots.push(root);
    const file = path.join(root, "capture-journal.sqlite");
    const now = new Date("2026-08-11T20:00:00.000Z");
    upsertQueueJournalJob({ id: "job", directory: root, sourceId: "direct-aldi-browser", status: "pending", enqueuedAt: now.toISOString(), nextAttemptAt: now.toISOString(), manifestJson: "{}" }, file);
    upsertSessionJournal(root, { sessionId: "session", store: "aldi", chunks: [] }, file);
    replacePlannerJournal("aldi", { eggs: { attempts: 1 } }, now.toISOString(), file);
    expect(acquireControllerLane("aldi", "test", now, 60_000, { ...process.env, TC_CAPTURE_JOURNAL: file })).toMatchObject({ acquired: true });
    expect(readSessionJournal<{ sessionId: string }>(root, file)?.sessionId).toBe("session");
    expect(readPlannerJournal("aldi", file).eggs).toEqual({ attempts: 1 });

    const serialized = serializeCaptureJournal(file);
    const restored = path.join(root, "restored.sqlite");
    await writeFile(restored, serialized);
    const database = new DatabaseSync(restored, { readOnly: true });
    expect((database.prepare("PRAGMA integrity_check").get() as Record<string, unknown>).integrity_check).toBe("ok");
    expect((database.prepare("SELECT COUNT(*) AS count FROM queue_jobs").get() as { count: number }).count).toBe(1);
    expect((database.prepare("SELECT COUNT(*) AS count FROM capture_sessions").get() as { count: number }).count).toBe(1);
    expect((database.prepare("SELECT COUNT(*) AS count FROM lane_leases").get() as { count: number }).count).toBe(1);
    database.close();
  });
});
