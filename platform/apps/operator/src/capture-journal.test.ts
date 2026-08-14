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
  failCaptureWork,
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
    const journal = new DatabaseSync(file);
    journal.prepare("INSERT INTO lane_state (store, state_json, updated_at) VALUES (?, ?, ?)")
      .run("aldi", JSON.stringify({ consecutiveFailures: 1, circuitOpenUntil: new Date(started.getTime() + 30 * 60_000).toISOString(), lastOutcome: "blocked" }), started.toISOString());
    journal.close();
    expect(leaseCaptureWork("executor-2", "aldi", new Date(started.getTime() + 10_000), 60_000, file)).toMatchObject({ acquired: false });
    expect(acknowledgeCaptureChallenge(challenge.id, new Date(started.getTime() + 3_000), file)).toMatchObject({ acknowledged: true, requiresCanary: true });
    expect(resolveCaptureChallenge(challenge.id, false, new Date(started.getTime() + 4_000), file)).toMatchObject({ resolved: false });
    expect(resolveCaptureChallenge(challenge.id, true, new Date(started.getTime() + 5_000), file)).toMatchObject({ resolved: true });
    const resumedJournal = new DatabaseSync(file, { readOnly: true });
    const resumedLane = JSON.parse((resumedJournal.prepare("SELECT state_json FROM lane_state WHERE store = ?").get("aldi") as { state_json: string }).state_json);
    resumedJournal.close();
    expect(resumedLane).toMatchObject({ consecutiveFailures: 0, circuitOpenUntil: null, lastOutcome: "canary_passed" });
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

  it("leases an ordered bounded store-local adapter batch under one lane owner", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-batch-lease-"));
    roots.push(root);
    const file = path.join(root, "capture-journal.sqlite");
    const directory = path.join(root, "session");
    const started = new Date("2026-08-12T12:00:00.000Z");
    upsertSessionJournal(directory, { sessionId: "session", store: "walmart", chunks: [] }, file);
    replaceSessionWorkUnits(directory, "walmart", "discovery", Array.from({ length: 7 }, (_, ordinal) => ({
      key: `term-${ordinal}`, ordinal, payload: { query: `term ${ordinal}` },
    })), started.toISOString(), file);
    const leased = leaseCaptureWork("executor-batch", "walmart", started, 5 * 60_000, file, 5) as {
      acquired: boolean; work: { unitKey: string }; works: Array<{ unitKey: string; payload: { query: string } }>;
    };
    expect(leased.acquired).toBe(true);
    expect(leased.work.unitKey).toBe("term-0");
    expect(leased.works.map((work) => work.payload.query)).toEqual(["term 0", "term 1", "term 2", "term 3", "term 4"]);
    expect(leaseCaptureWork("other", "walmart", new Date(started.getTime() + 5_000), 60_000, file, 2)).toMatchObject({ acquired: false });
  });

  it("reclaims expired executors before applying the global store-capacity limit", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-expired-executors-"));
    roots.push(root);
    const file = path.join(root, "capture-journal.sqlite");
    const started = new Date("2026-08-12T12:00:00.000Z");
    for (const store of ["walmart", "aldi", "fareway"] as const) {
      const directory = path.join(root, store);
      upsertSessionJournal(directory, { sessionId: `session-${store}`, store, chunks: [] }, file);
      replaceSessionWorkUnits(directory, store, "discovery", [{ key: `${store}-term`, ordinal: 0, payload: { query: `${store} term` } }], started.toISOString(), file);
    }
    expect(leaseCaptureWork("expired-walmart", "walmart", started, 30_000, file)).toMatchObject({ acquired: true });
    expect(leaseCaptureWork("expired-aldi", "aldi", started, 30_000, file)).toMatchObject({ acquired: true });
    expect(leaseCaptureWork("fareway-after-expiry", "fareway", new Date(started.getTime() + 31_000), 30_000, file)).toMatchObject({ acquired: true });
    expect((captureCoordinatorStatus(file) as { executors: Array<{ owner: string }> }).executors.map((executor) => executor.owner)).toEqual(["fareway-after-expiry"]);
  });

  it("fences an orphan adapter lane when new coordinator work is leased", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-orphan-lane-"));
    roots.push(root);
    const file = path.join(root, "capture-journal.sqlite");
    const environment = { ...process.env, TC_CAPTURE_JOURNAL: file };
    const started = new Date("2026-08-12T12:00:00.000Z");
    const directory = path.join(root, "aldi");
    upsertSessionJournal(directory, { sessionId: "session-aldi", store: "aldi", chunks: [] }, file);
    replaceSessionWorkUnits(directory, "aldi", "discovery", [{ key: "eggs", ordinal: 0, payload: { query: "eggs" } }], started.toISOString(), file);
    expect(acquireControllerLane("aldi", "orphan-adapter", started, 15 * 60_000, environment)).toMatchObject({ acquired: true });
    expect(leaseCaptureWork("new-executor", "aldi", new Date(started.getTime() + 1_000), 60_000, file)).toMatchObject({ acquired: true });
    expect(acquireControllerLane("aldi", "new-adapter", new Date(started.getTime() + 2_000), 15 * 60_000, environment)).toMatchObject({ acquired: true });
  });

  it("does not let a retryable failure starve untouched store work", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-retry-order-"));
    roots.push(root);
    const file = path.join(root, "capture-journal.sqlite");
    const directory = path.join(root, "sams");
    const started = new Date("2026-08-12T12:00:00.000Z");
    upsertSessionJournal(directory, { sessionId: "session-sams", store: "sams", chunks: [] }, file);
    replaceSessionWorkUnits(directory, "sams", "discovery", ["first", "second", "third"].map((key, ordinal) => ({ key, ordinal, priority: 100 - ordinal, payload: { query: key } })), started.toISOString(), file);
    const first = leaseCaptureWork("retry-executor", "sams", started, 60_000, file) as { work: { id: string; unitKey: string } };
    expect(first.work.unitKey).toBe("first");
    failCaptureWork("retry-executor", first.work.id, "temporary retailer rejection", new Date(started.getTime() + 1_000), file);
    const next = leaseCaptureWork("fresh-executor", "sams", new Date(started.getTime() + 4_000), 60_000, file) as { work: { unitKey: string } };
    expect(next.work.unitKey).toBe("second");
  });

  it("permits one isolated lane for each of the four browser retailers", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-capture-four-store-capacity-"));
    roots.push(root);
    const file = path.join(root, "capture-journal.sqlite");
    const started = new Date("2026-08-12T12:00:00.000Z");
    for (const store of ["aldi", "fareway", "sams", "walmart"] as const) {
      const directory = path.join(root, store);
      upsertSessionJournal(directory, { sessionId: `session-${store}`, store, chunks: [] }, file);
      replaceSessionWorkUnits(directory, store, "discovery", [{ key: `${store}-term`, ordinal: 0, payload: { query: `${store} term` } }], started.toISOString(), file);
      expect(leaseCaptureWork(`executor-${store}`, store, started, 60_000, file)).toMatchObject({ acquired: true });
    }
    expect((captureCoordinatorStatus(file) as { executors: Array<{ store: string }> }).executors).toHaveLength(4);
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
