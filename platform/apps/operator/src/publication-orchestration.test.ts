import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

describe("recipe publication coordination", () => {
  it("defers while daily-engine owns the coordinator and promotes ready browser captures before content", async () => {
    const script = await readFile(new URL("../../../scripts/run-pc-agent-cycle.ps1", import.meta.url), "utf8");
    const functionStart = script.indexOf("function Publish-ReadyRecipeContent");
    const functionEnd = script.indexOf("function Start-IngredientPricingDrain", functionStart);
    const publication = script.slice(functionStart, functionEnd);
    const lockCheck = publication.indexOf("platform-job-daily-engine.lock");
    const browserPromotion = publication.indexOf("tc capture promote-ready-browser");
    const contentPromotion = publication.indexOf("tc content promote-ready");
    const nativePublication = publication.indexOf("tc engine publish-native");

    expect(functionStart).toBeGreaterThanOrEqual(0);
    expect(lockCheck).toBeGreaterThanOrEqual(0);
    expect(browserPromotion).toBeGreaterThan(lockCheck);
    expect(contentPromotion).toBeGreaterThan(browserPromotion);
    expect(nativePublication).toBeGreaterThan(contentPromotion);
    expect(publication).toContain("grocery publication deferred");
  });
});
