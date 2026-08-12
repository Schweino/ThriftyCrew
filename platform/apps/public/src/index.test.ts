import { describe, expect, it, vi } from "vitest";
import worker from "./index";

describe("credential-free public Worker gateway", () => {
  it("forwards requests through the control service binding and adds edge headers", async () => {
    const fetch = vi.fn(async () => Response.json({ ok: true }));
    const response = await worker.fetch(
      new Request("https://tc-grocery-public.curly-unit-51a6.workers.dev/api/v2/status"),
      { CONTROL: { fetch } as unknown as Fetcher, APP_ENV: "test" },
    );
    expect(fetch).toHaveBeenCalledOnce();
    expect(response.status).toBe(200);
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("does not proxy arbitrary Host headers to the privileged Worker", async () => {
    const fetch = vi.fn();
    const response = await worker.fetch(
      new Request("https://attacker.example/internal/doctor"),
      { CONTROL: { fetch } as unknown as Fetcher, APP_ENV: "test" },
    );
    expect(response.status).toBe(421);
    expect(fetch).not.toHaveBeenCalled();
  });
});
