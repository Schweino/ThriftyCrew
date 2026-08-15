import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { checkpointAdapterChunk, materializeAdapterStream } from "./adapter-protocol.mjs";

const roots = [];
afterEach(async () => Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))));

describe("browser adapter streaming protocol", () => {
  it("checkpoints each completed term and reproduces the compatibility chunk", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-adapter-stream-"));
    roots.push(root);
    const file = path.join(root, "chunk.json");
    const canary = { observedAt: "2026-08-12T15:00:00.000Z" };
    const first = { version: 2, phase: "discovery", store: "walmart", canary, terms: [{ query: "milk", outcome: "success" }], rows: [{ q: "milk", id: "1" }] };
    await checkpointAdapterChunk(file, first, 0);
    const second = { ...first, terms: [...first.terms, { query: "eggs", outcome: "empty" }], rows: first.rows };
    await checkpointAdapterChunk(file, second, 1);
    const stream = `${file}.ndjson`;
    expect((await readFile(stream, "utf8")).trim().split(/\r?\n/)).toHaveLength(3);
    expect(await materializeAdapterStream(stream)).toEqual(second);
    expect(JSON.parse(await readFile(file, "utf8"))).toEqual(second);
  });

  it("preserves an immutable checkpoint and reports an uninitialized controller session without challenge semantics", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "tc-adapter-missing-session-"));
    roots.push(root);
    const file = path.join(root, "chunk.json");
    const sessionDirectory = path.join(root, "session");
    const chunk = { version: 2, phase: "discovery", store: "sams",
      canary: { observedAt: "2026-08-14T23:00:00.000Z", locationId: "8146", priceMode: "Pickup" },
      terms: [{ query: "almonds", outcome: "success" }], rows: [{ q: "almonds", id: "1" }] };

    let message = "";
    try { await checkpointAdapterChunk(file, chunk, 0, sessionDirectory); }
    catch (error) { message = String(error?.message ?? error); }

    expect(message).toMatch(/capture session is not initialized/);
    expect(message).toMatch(/immutable adapter checkpoint preserved/);
    expect(message).not.toMatch(/challenge|block page|human.verification|captcha/i);
    expect(JSON.parse(await readFile(file, "utf8"))).toEqual(chunk);
    expect(await materializeAdapterStream(`${file}.ndjson`)).toEqual(chunk);
  });
});
