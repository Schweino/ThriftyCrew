import { appendFile, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { captureControllerRequest } from "../capture-controller-client.mjs";

function streamPath(file) {
  return `${file}.ndjson`;
}

async function atomicJson(file, value) {
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${crypto.randomUUID()}`;
  await writeFile(temporary, `${JSON.stringify(value)}\n`, "utf8");
  await rename(temporary, file);
}

async function appendEvent(file, event) {
  const target = streamPath(file);
  await mkdir(path.dirname(target), { recursive: true });
  await appendFile(target, `${JSON.stringify(event)}\n`, { encoding: "utf8", flush: true });
}

async function ensureHeader(file, chunk) {
  try {
    const first = (await readFile(streamPath(file), "utf8")).split(/\r?\n/, 1)[0];
    const header = JSON.parse(first);
    if (header.type !== "capture-header" || header.store !== chunk.store || header.phase !== chunk.phase) throw new Error("adapter stream belongs to another capture chunk");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    await appendEvent(file, { protocol: "tc-browser-capture", version: 1, type: "capture-header", phase: chunk.phase, store: chunk.store, canary: chunk.canary, createdAt: new Date().toISOString() });
  }
}

/**
 * Store adapters emit one durable protocol event per completed product read.
 * The compact JSON mirror preserves compatibility with the deterministic
 * session validator while the NDJSON stream is the crash-resume source.
 */
export async function checkpointAdapterChunk(file, chunk, previousCount = 0, sessionDirectory) {
  if (!chunk || chunk.version !== 2 || !["discovery", "verification"].includes(chunk.phase)) throw new Error("invalid adapter checkpoint");
  await ensureHeader(file, chunk);
  if (chunk.phase === "discovery") {
    for (let index = previousCount; index < chunk.terms.length; index += 1) {
      const term = chunk.terms[index];
      const query = term.query;
      const termColumn = chunk.store === "walmart" || chunk.store === "sams" ? "q" : "term";
      await appendEvent(file, { protocol: "tc-browser-capture", version: 1, type: "discovery-result", ordinal: index, term, rows: chunk.rows.filter((row) => String(row[termColumn] ?? "").trim() === query) });
    }
  } else {
    for (let index = previousCount; index < chunk.verifications.length; index += 1) {
      await appendEvent(file, { protocol: "tc-browser-capture", version: 1, type: "verification-result", ordinal: index, verification: chunk.verifications[index] });
    }
  }
  await atomicJson(file, chunk);
  let controllerCommit;
  if (sessionDirectory) {
    const delta = chunk.phase === "discovery"
      ? { ...chunk, terms: chunk.terms.slice(previousCount), rows: chunk.rows.filter((row) => chunk.terms.slice(previousCount).some((term) => String(row[chunk.store === "walmart" || chunk.store === "sams" ? "q" : "term"] ?? "").trim() === term.query)) }
      : { ...chunk, verifications: chunk.verifications.slice(previousCount) };
    const commitFile = `${file}.controller-${crypto.randomUUID()}.json`;
    await writeFile(commitFile, `${JSON.stringify(delta)}\n`, "utf8");
    try {
      controllerCommit = await captureControllerRequest("/v1/sessions/commit-file", { directory: path.resolve(sessionDirectory), chunkFile: path.resolve(commitFile) }, process.env, 30_000, true);
      if (!controllerCommit) throw new Error("persistent capture controller is unavailable for atomic adapter commit");
      if (controllerCommit.ok !== true) throw new Error(String(controllerCommit.error ?? "capture controller rejected adapter result"));
    } finally { await rm(commitFile, { force: true }); }
  }
  return { file, streamFile: streamPath(file), events: chunk.phase === "discovery" ? chunk.terms.length : chunk.verifications.length, ...(controllerCommit ? { controllerCommit } : {}) };
}

export async function materializeAdapterStream(file) {
  const events = (await readFile(file, "utf8")).split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
  const header = events[0];
  if (header?.protocol !== "tc-browser-capture" || header?.type !== "capture-header") throw new Error("adapter stream header is invalid");
  if (header.phase === "discovery") {
    const results = events.filter((event) => event.type === "discovery-result").sort((left, right) => left.ordinal - right.ordinal);
    return { version: 2, phase: "discovery", store: header.store, canary: header.canary, terms: results.map((event) => event.term), rows: results.flatMap((event) => event.rows) };
  }
  const results = events.filter((event) => event.type === "verification-result").sort((left, right) => left.ordinal - right.ordinal);
  return { version: 2, phase: "verification", store: header.store, canary: header.canary, verifications: results.map((event) => event.verification) };
}
