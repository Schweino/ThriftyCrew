import { describe, expect, it } from "vitest";
import { createDirectEvidenceUpload } from "./capture-direct-upload";

describe("direct R2 evidence upload", () => {
  it("mints a short-lived one-object PUT URL with signed evidence metadata", async () => {
    const result = await createDirectEvidenceUpload({
      CLOUDFLARE_ACCOUNT_ID: "a".repeat(32),
      R2_ACCESS_KEY_ID: "access-key",
      R2_SECRET_ACCESS_KEY: "secret-key",
      R2_EVIDENCE_BUCKET: "evidence",
    } as never, {
      uploadSessionId: "upload-1", objectKey: "batches/batch-1/evidence-1", evidenceId: "evidence-1",
      kind: "manifest", contentType: "application/json", sha256: "b".repeat(64),
      contentMd5: "1B2M2Y8AsgTpgAmY7PhCfg==", expiresSeconds: 120,
    });
    const url = new URL(result.url);
    expect(url.pathname).toBe("/evidence/batches/batch-1/evidence-1");
    expect(url.searchParams.get("X-Amz-Expires")).toBe("120");
    expect(url.searchParams.get("X-Amz-Signature")).toMatch(/^[a-f0-9]{64}$/);
    expect(result.headers).toMatchObject({
      "content-type": "application/json",
      "content-md5": "1B2M2Y8AsgTpgAmY7PhCfg==",
      "x-amz-meta-sha256": "b".repeat(64),
      "x-amz-meta-evidenceid": "evidence-1",
      "x-amz-meta-uploadsessionid": "upload-1",
    });
  });
});
