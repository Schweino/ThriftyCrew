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
});
