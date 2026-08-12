import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import {
  acquireControllerLane,
  acknowledgeCaptureChallenge,
  browserCaptureJournalDueState,
  captureCoordinatorStatus,
  commitSessionChunk,
  completeSessionWorkUnits,
  heartbeatCaptureWork,
  leaseCaptureWork,
  openCaptureChallenge,
  readSessionPayload,
  closeCaptureJournals,
  readPlannerJournal,
  readSessionJournal,
  replacePlannerJournal,
  replaceSessionWorkUnits,
  resolveCaptureChallenge,
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

  it("atomically journals payload bodies, work completion, leases, and human challenges", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-coordinator-"));
    roots.push(root);
    const file = path.join(root, "capture-journal.sqlite");
    const directory = path.join(root, "session");
    const started = new Date("2026-08-12T12:00:00.000Z");
    const draft = { sessionId: "session", store: "aldi", chunks: [] as Array<{ id: string; file: string; sha256: string; createdAt: string }> };
    upsertSessionJournal(directory, draft, file);
    replaceSessionWorkUnits(directory, "aldi", "discovery", [
      { key: "eggs", ordinal: 0, payload: { query: "eggs" } },
      { key: "milk", ordinal: 1, payload: { query: "milk" } },
    ], started.toISOString(), file);

    const first = leaseCaptureWork("executor-1", "aldi", started, 60_000, file) as { acquired: boolean; work: { id: string; unitKey: string } };
    expect(first.acquired).toBe(true);
    expect(first.work.unitKey).toBe("eggs");
    expect(heartbeatCaptureWork("executor-1", first.work.id, new Date(started.getTime() + 1_000), 60_000, {}, file)).toMatchObject({ renewed: true });

    const body = new TextEncoder().encode(JSON.stringify({ version: 2, phase: "discovery", store: "aldi", terms: [{ query: "eggs", outcome: "success" }], rows: [] }));
    const entry = { id: "chunk-abc", file: "0000-chunk-abc.json", sha256: "a".repeat(64), createdAt: started.toISOString() };
    draft.chunks.push(entry);
    commitSessionChunk(directory, draft, entry, body, file);
    expect(new TextDecoder().decode(readSessionPayload(directory, entry.id, file)?.body)).toContain('"eggs"');

    const challenge = openCaptureChallenge("aldi", { reason: "wall" }, new Date(started.getTime() + 2_000), file);
    expect(leaseCaptureWork("executor-2", "aldi", new Date(started.getTime() + 10_000), 60_000, file)).toMatchObject({ acquired: false });
    expect(acknowledgeCaptureChallenge(challenge.id, new Date(started.getTime() + 3_000), file)).toMatchObject({ acknowledged: true, requiresCanary: true });
    expect(resolveCaptureChallenge(challenge.id, false, new Date(started.getTime() + 4_000), file)).toMatchObject({ resolved: false });
    expect(resolveCaptureChallenge(challenge.id, true, new Date(started.getTime() + 5_000), file)).toMatchObject({ resolved: true });
    const resumed = leaseCaptureWork("executor-2", "aldi", new Date(started.getTime() + 12_000), 60_000, file) as { acquired: boolean; work: { unitKey: string } };
    expect(resumed.acquired).toBe(true);
    expect(resumed.work.unitKey).toBe("milk");
    const blockedBody = new TextEncoder().encode(JSON.stringify({ version: 2, phase: "discovery", store: "aldi", terms: [{ query: "milk", outcome: "blocked", reason: "wall" }], rows: [] }));
    const blockedEntry = { id: "chunk-blocked", file: "0001-chunk-blocked.json", sha256: "b".repeat(64), createdAt: new Date(started.getTime() + 13_000).toISOString() };
    draft.chunks.push(blockedEntry);
    commitSessionChunk(directory, draft, blockedEntry, blockedBody, file);
    expect((captureCoordinatorStatus(file) as { work: Array<{ unit_key?: string; unitKey?: string; status: string }> }).work)
      .toEqual(expect.arrayContaining([expect.objectContaining({ status: "blocked" })]));
    const secondChallenge = openCaptureChallenge("aldi", { reason: "wall again" }, new Date(started.getTime() + 14_000), file);
    acknowledgeCaptureChallenge(secondChallenge.id, new Date(started.getTime() + 15_000), file);
    resolveCaptureChallenge(secondChallenge.id, true, new Date(started.getTime() + 16_000), file);
    expect(leaseCaptureWork("executor-3", "aldi", new Date(started.getTime() + 22_000), 60_000, file)).toMatchObject({ acquired: true });
    completeSessionWorkUnits(directory, "discovery", ["milk"], "chunk-def", file);
  });

  it("answers weekly browser freshness from journaled queue truth without scanning artifact files", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-due-journal-"));
    roots.push(root);
    const file = path.join(root, "capture-journal.sqlite");
    for (const sourceId of ["direct-aldi-browser", "direct-fareway-browser", "direct-sams-browser", "direct-walmart-browser"]) {
      const manifest = {
        captureSummary: { capturedTo: "2026-08-12T12:00:00.000Z", coverageMode: "full" },
        receipt: { remote: { status: "promoted", matching: { status: "passed" } } },
      };
      upsertQueueJournalJob({ id: sourceId, directory: path.join(root, sourceId), sourceId, status: "completed", enqueuedAt: "2026-08-12T12:01:00.000Z", nextAttemptAt: "2026-08-12T12:01:00.000Z", manifestJson: JSON.stringify(manifest) }, file);
    }
    expect(browserCaptureJournalDueState(new Date("2026-08-13T12:00:00.000Z"), file)).toMatchObject({
      status: "fresh", authority: "capture-journal", completed: expect.arrayContaining(["direct-aldi-browser", "direct-walmart-browser"]),
    });
  });
});
