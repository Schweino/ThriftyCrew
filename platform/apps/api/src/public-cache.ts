interface CloudflareCacheStorage extends CacheStorage {
  default?: Cache;
}

export interface PublicJsonValue {
  body: unknown;
  etag: string;
  releaseId: string;
}

export class PublicJsonError extends Error {
  constructor(message: string, readonly status: 404 | 500) {
    super(message);
  }
}

function edgeCache(): Cache | null {
  return (globalThis.caches as CloudflareCacheStorage | undefined)?.default ?? null;
}

function cacheKey(request: Request): Request {
  return new Request(request.url, { method: "GET" });
}

function notModified(request: Request, response: Response): Response {
  const requested = request.headers.get("if-none-match");
  const etag = response.headers.get("etag");
  if (!requested || !etag || !requested.split(",").map((value) => value.trim()).includes(etag)) return response;
  const headers = new Headers();
  for (const name of ["etag", "cache-control", "cache-tag", "x-release-id", "vary"]) {
    const value = response.headers.get(name);
    if (value) headers.set(name, value);
  }
  return new Response(null, { status: 304, headers });
}

export function releaseEtag(contentHash: string): string {
  return `"sha256-${contentHash}"`;
}

export async function cachedPublicJson(request: Request, load: () => Promise<PublicJsonValue>): Promise<Response> {
  const cache = edgeCache();
  const key = cacheKey(request);
  if (cache) {
    try {
      const hit = await cache.match(key);
      if (hit) return notModified(request, hit);
    } catch (error) {
      console.warn("public edge cache read failed", { url: request.url, error: error instanceof Error ? error.message : String(error) });
    }
  }

  let value: PublicJsonValue;
  try {
    value = await load();
  } catch (error) {
    if (error instanceof PublicJsonError) {
      return Response.json({ ok: false, error: error.message }, { status: error.status });
    }
    throw error;
  }
  const response = Response.json(value.body, {
    headers: {
      "cache-control": "public, max-age=60, stale-while-revalidate=300",
      "cache-tag": `grocery-public,grocery-release-${value.releaseId}`,
      etag: value.etag,
      "x-release-id": value.releaseId,
    },
  });
  if (cache) {
    try {
      await cache.put(key, response.clone());
    } catch (error) {
      console.warn("public edge cache write failed", { url: request.url, error: error instanceof Error ? error.message : String(error) });
    }
  }
  return notModified(request, response);
}
