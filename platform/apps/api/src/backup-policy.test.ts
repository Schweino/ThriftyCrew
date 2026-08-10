import { describe, expect, it } from "vitest";
import { D1_EXPORT_POLL_STEP_CONFIG } from "./backup-policy";

describe("D1 export polling", () => {
  it("keeps polling long enough for an asynchronous export without exponential gaps", () => {
    expect(D1_EXPORT_POLL_STEP_CONFIG.retries).toEqual({
      limit: 60,
      delay: "15 seconds",
      backoff: "constant",
    });
    expect(D1_EXPORT_POLL_STEP_CONFIG.timeout).toBe("2 minutes");
  });
});
