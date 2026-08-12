import assert from "node:assert/strict";
import test from "node:test";
import { applyLegacyAliases, serveCompatibleFeed, unwrapPromotedFeed } from "./feed-compat.mjs";

const payload = {
  release_id: "rel_current",
  ingredients: { chicken: { price: 2.19 } },
  recipes: { dinner: { per_serving: 3.35 } },
};

test("unwraps only a complete, internally consistent promoted feed", () => {
  assert.deepEqual(unwrapPromotedFeed({ ok: true, releaseId: "rel_current", payload }), payload);
  assert.throws(
    () => unwrapPromotedFeed({ ok: true, releaseId: "rel_other", payload }),
    /release IDs do not match/,
  );
  assert.throws(
    () => unwrapPromotedFeed({ ok: true, releaseId: "rel_current", payload: { ...payload, recipes: {} } }),
    /no recipes/,
  );
});

test("serves the unwrapped V3 payload with release-aware cache headers", async () => {
  const request = new Request("https://smp-feed.example/smp-feed.json");
  const response = await serveCompatibleFeed(request, {
    ASSETS: { fetch: async () => Response.json({ ingredients: {} }) },
  }, async () =>
    Response.json({ ok: true, releaseId: "rel_current", payload }),
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-tc-feed-source"), "v3-promoted-release");
  assert.equal(response.headers.get("x-tc-release-id"), "rel_current");
  assert.deepEqual(await response.json(), { ...payload, ingredient_count: 1 });
});

test("carries legacy recipe aliases forward using current promoted prices", () => {
  const current = {
    ...payload,
    ingredients: { "ground-beef-93-7": { cheapest: 6.99, unit: "lb" } },
  };
  const result = applyLegacyAliases(current, {
    ingredients: { "93-7-ground-beef": { cheapest: 6.17, alias_of: "ground-beef-93-7" } },
  });
  assert.deepEqual(result.ingredients["93-7-ground-beef"], {
    cheapest: 6.99,
    unit: "lb",
    alias_of: "ground-beef-93-7",
  });
  assert.equal(result.ingredient_count, 2);
});

test("falls back to the last static feed when the promoted endpoint is unavailable", async () => {
  const env = {
    ASSETS: {
      fetch: async () => Response.json({ release_id: "rel_fallback", ingredients: {}, recipes: {} }),
    },
  };
  const response = await serveCompatibleFeed(
    new Request("https://smp-feed.example/smp-feed.json"),
    env,
    async () => new Response("down", { status: 503 }),
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-tc-feed-source"), "static-fallback");
  assert.equal((await response.json()).release_id, "rel_fallback");
});
