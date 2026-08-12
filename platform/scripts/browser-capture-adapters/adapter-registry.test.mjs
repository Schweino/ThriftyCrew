import { describe, expect, it } from "vitest";
import { captureAdapterRegistry, validateCaptureAdapterManifest } from "./adapter-registry.mjs";

describe("browser adapter registry", () => {
  it("pins every real-Chrome store to a validated source hash and conservative rate contract", async () => {
    const registry = await captureAdapterRegistry();
    expect(Object.keys(registry).sort()).toEqual(["aldi", "fareway", "sams", "walmart"]);
    for (const manifest of Object.values(registry)) {
      expect(validateCaptureAdapterManifest(manifest)).toBe(manifest);
      expect(manifest.sha256).toMatch(/^[a-f0-9]{64}$/);
      expect(manifest.rate.maxConcurrent).toBe(1);
    }
  });
});
