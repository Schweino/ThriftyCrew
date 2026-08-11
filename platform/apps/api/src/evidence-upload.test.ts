import { gzipSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { decodeEvidenceUpload } from "./evidence-upload";

describe("capture evidence upload encoding", () => {
  it("accepts a bounded gzip body and restores the exact evidence bytes", async () => {
    const source = new TextEncoder().encode(JSON.stringify({ rows: Array.from({ length: 10_000 }, (_, index) => ({ index, value: "browser truth" })) }));
    const encoded = new Uint8Array(gzipSync(source));
    const decoded = await decodeEvidenceUpload(encoded, "gzip", String(source.byteLength));
    expect(decoded).toEqual(source);
  });

  it("rejects an unsupported encoding or a false decoded length", async () => {
    const source = new TextEncoder().encode("capture evidence");
    const encoded = new Uint8Array(gzipSync(source));
    await expect(decodeEvidenceUpload(encoded, "br", String(source.byteLength))).rejects.toThrow("unsupported");
    await expect(decodeEvidenceUpload(encoded, "gzip", String(source.byteLength + 1))).rejects.toThrow("decoded length");
  });
});
