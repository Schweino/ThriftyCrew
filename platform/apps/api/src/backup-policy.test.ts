import { describe, expect, it } from "vitest";
import { D1_EXPORT_POLL_STEP_CONFIG, d1ExportPollPayload } from "./backup-policy";

describe("D1 export polling", () => {
  it("keeps polling long enough for an asynchronous export without exponential gaps", () => {
    expect(D1_EXPORT_POLL_STEP_CONFIG.retries).toEqual({
      limit: 120,
      delay: "15 seconds",
      backoff: "constant",
    });
    expect(D1_EXPORT_POLL_STEP_CONFIG.timeout).toBe("2 minutes");
  });

  it("sends both fields required by Cloudflare's production polling contract", () => {
    expect(d1ExportPollPayload("bookmark-123")).toEqual({ output_format: "polling", current_bookmark: "bookmark-123" });
  });
});
