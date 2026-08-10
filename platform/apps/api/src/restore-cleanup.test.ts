import { describe, expect, it } from "vitest";
import { isMissingMultipartUploadError } from "./restore-cleanup";

describe("restore cleanup", () => {
  it("treats Cloudflare's case-varied missing-upload response as an idempotent cleanup", () => {
    expect(isMissingMultipartUploadError(new Error("abortMultipartUpload: The specified multipart upload does not exist. (10024)"))).toBe(true);
    expect(isMissingMultipartUploadError(new Error("permission denied"))).toBe(false);
  });
});
