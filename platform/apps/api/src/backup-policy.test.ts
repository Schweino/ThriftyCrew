import { describe, expect, it } from "vitest";
import { D1_EXPORT_POLL_STEP_CONFIG, d1ExportPollPayload, d1ExportTerminalError } from "./backup-policy";

describe("D1 export polling", () => {
  it("keeps polling long enough for an asynchronous export without exponential gaps", () => {
    expect(D1_EXPORT_POLL_STEP_CONFIG.retries).toEqual({
      limit: 240,
      delay: "1 minute",
      backoff: "constant",
    });
    expect(D1_EXPORT_POLL_STEP_CONFIG.timeout).toBe("2 minutes");
  });

  it("sends both fields required by Cloudflare's production polling contract", () => {
    expect(d1ExportPollPayload("bookmark-123")).toEqual({ output_format: "polling", current_bookmark: "bookmark-123" });
  });

  it("keeps polling multipart progress but stops on an explicit terminal error", () => {
    expect(d1ExportTerminalError({ status: "error" })).toBeNull();
    expect(d1ExportTerminalError({ status: "error", error: "  export cancelled  " })).toBe("export cancelled");
    expect(d1ExportTerminalError({ status: "complete" })).toBeNull();
  });
});
