const DEFAULT_PROMOTED_FEED_URL = "https://www.thriftycrew.com/api/v2/feed";

export function unwrapPromotedFeed(value) {
  if (!value || value.ok !== true || typeof value.releaseId !== "string") {
    throw new Error("promoted feed envelope is invalid");
  }
  const payload = value.payload;
  if (!payload || typeof payload !== "object") throw new Error("promoted feed payload is missing");
  if (payload.release_id !== value.releaseId) throw new Error("promoted feed release IDs do not match");
  if (!payload.ingredients || Object.keys(payload.ingredients).length === 0) {
    throw new Error("promoted feed has no ingredients");
  }
  if (!payload.recipes || Object.keys(payload.recipes).length === 0) {
    throw new Error("promoted feed has no recipes");
  }
  return payload;
}

export async function fetchPromotedFeed(env, fetchImpl = fetch) {
  const url = env.PROMOTED_FEED_URL || DEFAULT_PROMOTED_FEED_URL;
  const request = new Request(url, { headers: { Accept: "application/json" } });
  const response = env.PUBLIC_API
    ? await env.PUBLIC_API.fetch(request)
    : await fetchImpl(request, { cf: { cacheEverything: true, cacheTtl: 60 } });
  if (!response.ok) throw new Error(`promoted feed returned ${response.status}`);
  return unwrapPromotedFeed(await response.json());
}

export function applyLegacyAliases(payload, legacyPayload) {
  const legacyIngredients = legacyPayload?.ingredients;
  if (!legacyIngredients || typeof legacyIngredients !== "object") return payload;
  const ingredients = { ...payload.ingredients };
  for (const [alias, legacyIngredient] of Object.entries(legacyIngredients)) {
    const target = legacyIngredient?.alias_of;
    if (typeof target !== "string" || ingredients[alias] || !ingredients[target]) continue;
    ingredients[alias] = { ...ingredients[target], alias_of: target };
  }
  return { ...payload, ingredient_count: Object.keys(ingredients).length, ingredients };
}

export async function serveCompatibleFeed(request, env, fetchImpl = fetch) {
  const fallback = await env.ASSETS.fetch(new Request(new URL("/smp-feed.json", request.url)));
  try {
    const promoted = await fetchPromotedFeed(env, fetchImpl);
    let legacyPayload;
    try { legacyPayload = await fallback.clone().json(); } catch { legacyPayload = null; }
    const payload = applyLegacyAliases(promoted, legacyPayload);
    const etag = `"${payload.release_id}"`;
    const headers = {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "public, max-age=60, stale-while-revalidate=300",
      ETag: etag,
      "X-TC-Feed-Source": "v3-promoted-release",
      "X-TC-Release-Id": payload.release_id,
      "Access-Control-Allow-Origin": "*",
    };
    if (request.headers.get("If-None-Match") === etag) return new Response(null, { status: 304, headers });
    return new Response(request.method === "HEAD" ? null : JSON.stringify(payload), { status: 200, headers });
  } catch (error) {
    const headers = new Headers(fallback.headers);
    headers.set("Cache-Control", "public, max-age=30, stale-while-revalidate=300");
    headers.set("X-TC-Feed-Source", "static-fallback");
    headers.set("X-TC-Feed-Warning", "promoted-feed-unavailable");
    headers.set("Access-Control-Allow-Origin", "*");
    return new Response(request.method === "HEAD" ? null : fallback.body, {
      status: fallback.status,
      statusText: fallback.statusText,
      headers,
    });
  }
}
