import { afterEach, describe, expect, it, vi } from "vitest";
import type { DirectCaptureArtifact } from "@thriftycrew/contracts";
import type { CurrentBridgeArtifact } from "./legacy";
import { deduplicateDirectObservations, deployConfiguration, deployConfigurationDelta, MutationClient, publishNativeRelease } from "./client";
import type { NativeReleaseArtifact } from "./native";

describe("configuration deployment", () => {
  it("reports an already-active configuration without laundering a temporary doctor failure", async () => {
    const request = vi.fn().mockResolvedValue({ ok: true, id: "cfg_test", active: true, httpStatus: 200 });
    const client = { request } as unknown as MutationClient;
    const configuration = {
      id: "cfg_test",
      sourceCommit: "test",
      contentHash: "a".repeat(64),
      categories: [],
      commodities: [],
      knownWrong: [],
    } as unknown as CurrentBridgeArtifact["configuration"];

    await expect(deployConfiguration(client, configuration)).resolves.toEqual({
      ok: true,
      configurationId: "cfg_test",
      active: true,
      idempotent: true,
      activation: null,
    });
    expect(request).toHaveBeenCalledTimes(1);
    expect(request).not.toHaveBeenCalledWith("/internal/doctor", expect.anything());
  });

  it("clones the active configuration and uploads only changed commodities", async () => {
    const paths: string[] = [];
    const request = vi.fn(async (pathname: string, _options?: unknown) => {
      paths.push(pathname);
      if (pathname === "/internal/configurations") return { active: false };
      if (pathname.endsWith("/clone-active")) return { ok: true, commodityIds: ["unchanged"] };
      if (pathname.endsWith("/commodities")) return { ok: true };
      if (pathname.includes("/known-wrong")) return { ok: true };
      if (pathname.endsWith("/activate")) return { ok: true };
      throw new Error(`unexpected path ${pathname}`);
    });
    const configuration = { id: "cfg_delta", sourceCommit: "test", contentHash: "a".repeat(64), categories: [], knownWrong: [{ id: "rule-1" }], commodities: [
      { id: "unchanged", label: "Unchanged", unit: "oz", categoryId: "pantry", include: ["unchanged"], exclude: [] },
      { id: "new-item", label: "New Item", unit: "oz", categoryId: "pantry", include: ["new item"], exclude: [] },
    ] } as unknown as CurrentBridgeArtifact["configuration"];
    await deployConfigurationDelta({ request } as unknown as MutationClient, configuration, ["new-item"]);
    expect(paths).toEqual(["/internal/configurations", "/internal/configurations/cfg_delta/clone-active",
      "/internal/configurations/cfg_delta/commodities", "/internal/configurations/cfg_delta/known-wrong?replace=1",
      "/internal/configurations/cfg_delta/activate"]);
    const commodityPayload = request.mock.calls.find(([pathname]) => String(pathname).endsWith("/commodities"))?.[1] as { json: { commodities: Array<{ id: string }> } };
    expect(commodityPayload.json.commodities.map((commodity) => commodity.id)).toEqual(["new-item"]);
  });

  it("repairs cloned commodities whose durable fingerprint differs from source control", async () => {
    const request = vi.fn(async (pathname: string, _options?: unknown) => {
      if (pathname === "/internal/configurations") return { active: false };
      if (pathname.endsWith("/clone-active")) return { commodityIds: ["drifted"], commodityFingerprints: { drifted: "stale" } };
      return { ok: true };
    });
    const configuration = { id: "cfg_repair", sourceCommit: "test", contentHash: "b".repeat(64), categories: [], knownWrong: [], commodities: [
      { id: "drifted", label: "Drifted", unit: "oz", categoryId: "pantry", include: ["new exact rule"], exclude: ["wrong form"] },
    ] } as unknown as CurrentBridgeArtifact["configuration"];
    await deployConfigurationDelta({ request } as unknown as MutationClient, configuration, []);
    const payload = request.mock.calls.find(([pathname]) => String(pathname).endsWith("/commodities"))?.[1] as { json: { commodities: Array<{ id: string }> } };
    expect(payload.json.commodities.map((commodity) => commodity.id)).toEqual(["drifted"]);
  });
});

describe("direct capture observation deduplication", () => {
  const observation = {
    externalProductKey: "sku-1", name: "Test Product", sizeText: "16 oz", kind: "everyday",
    currency: "USD", purchasePriceMinor: 299, purchaseQuantity: 1, packageCount: 1,
    capturedBasisUnit: "oz", capturedBasisQtyMicros: 16_000_000,
    normalizedBasisUnit: "oz", normalizedBasisQtyMicros: 16_000_000,
    perUnitMicros: 186_875, rawPriceText: "$2.99", rawSizeText: "16 oz",
    capturedAt: "2026-08-11T12:00:00.000Z", package: { count: 1, size: 16, unit: "oz" },
    loyaltyRequired: false, membershipRequired: false,
  } as DirectCaptureArtifact["observations"][number];

  it("removes byte-equivalent deterministic observation retries", () => {
    expect(deduplicateDirectObservations([observation, { ...observation }])).toEqual({
      observations: [observation],
      duplicatesAvoided: 1,
    });
  });

  it("retains genuinely different offer facts", () => {
    expect(deduplicateDirectObservations([observation, {
      ...observation, purchasePriceMinor: 399, perUnitMicros: 249_375, rawPriceText: "$3.99",
    }])).toMatchObject({ duplicatesAvoided: 0, observations: [{ purchasePriceMinor: 299 }, { purchasePriceMinor: 399 }] });
  });

  it("ignores volatile capture provenance while preserving distinct term membership", () => {
    const second = { ...observation, package: { ...observation.package, rawIndex: 99, source: "retry" }, capturedAt: "2026-08-12T12:00:00.000Z" };
    expect(deduplicateDirectObservations([observation, second])).toMatchObject({ duplicatesAvoided: 1 });
    expect(deduplicateDirectObservations([observation, { ...second, termKey: "milk" }])).toMatchObject({ duplicatesAvoided: 0 });
  });
});

describe("native release publication", () => {
  it("resumes after a finalized graph without replaying complete release stages", async () => {
    const paths: string[] = [];
    const request = vi.fn(async (pathname: string) => {
      paths.push(pathname);
      if (pathname === "/internal/releases") return { ok: true, state: "draft" };
      if (pathname === "/internal/releases/rel_native_resume") return { ok: true, progress: { graph_finalized: 1 } };
      if (pathname.endsWith("/recipe-bundles")) return { ok: true, count: 0, next: null };
      if (pathname.endsWith("/validate")) return { ok: true };
      if (pathname.endsWith("/publish")) return { ok: true };
      throw new Error(`unexpected release resume request: ${pathname}`);
    });
    const artifact = {
      releaseId: "rel_native_resume", marketId: "omaha", configurationId: "cfg_test", inputManifest: {},
      inputBatchIds: [], inputHash: "a".repeat(64), cells: [{ commodityId: "milk" }], recipeCosts: [{ recipeSlug: "meal" }],
      freeRotation: [], top5: [], payloads: { board: {} }, graph: { parentReleaseId: "parent", dependencyHash: "b".repeat(64), nodes: [{}] },
      audit: { commodities: 507, stores: 7 },
    } as unknown as NativeReleaseArtifact;
    await expect(publishNativeRelease({ request } as unknown as MutationClient, artifact)).resolves.toMatchObject({ ok: true });
    expect(paths.some((pathname) => pathname.endsWith("/cells") || pathname.endsWith("/graph-nodes") || pathname.endsWith("/graph-finalize"))).toBe(false);
  });

  it("treats a deterministic release published by a concurrent executor as idempotent success", async () => {
    let releaseReads = 0;
    const request = vi.fn(async (pathname: string) => {
      if (pathname === "/internal/releases") {
        releaseReads += 1;
        return { ok: true, state: releaseReads === 1 ? "draft" : "published" };
      }
      if (pathname === "/internal/releases/rel_native_test") return { ok: true, progress: { graph_finalized: 0 } };
      throw new Error("PUT returned 409: release content is immutable in published state");
    });
    const artifact = {
      releaseId: "rel_native_test",
      marketId: "omaha",
      configurationId: "cfg_test",
      inputManifest: {},
      inputBatchIds: [],
      inputHash: "a".repeat(64),
      cells: [], recipeCosts: [], freeRotation: [], top5: [], payloads: {},
      audit: { commodities: 507, stores: 7 },
    } as unknown as NativeReleaseArtifact;

    await expect(publishNativeRelease({ request } as unknown as MutationClient, artifact)).resolves.toMatchObject({
      ok: true, releaseId: "rel_native_test", state: "published", idempotent: true, concurrentPublication: true,
    });
    expect(releaseReads).toBe(2);
  });
});

describe("GitHub OIDC authorization", () => {
  it("carries the acquired execution fence on every scheduled mutation", async () => {
    let headers = new Headers();
    vi.stubGlobal("fetch", vi.fn(async (_url: URL, init?: RequestInit) => {
      headers = new Headers(init?.headers);
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }));
    const client = new MutationClient({
      origin: "https://example.test", agentId: "test", secret: "fixture-secret",
      jobRunId: "run_daily", leaseFence: 7,
    });
    await client.request("/internal/test", { json: { value: 1 } });
    expect(headers.get("x-tc-job-run")).toBe("run_daily");
    expect(headers.get("x-tc-lease-fence")).toBe("7");
  });

  it("refreshes a cached token before it expires during a long operation", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-10T19:00:00Z"));
    const token = (exp: number, label: string) => `header.${Buffer.from(JSON.stringify({ exp, label })).toString("base64url")}.signature`;
    const first = token(Math.floor(Date.now() / 1_000) + 120, "first");
    const second = token(Math.floor(Date.now() / 1_000) + 300, "second");
    const provider = vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second);
    const authorizations: string[] = [];
    vi.stubGlobal("fetch", vi.fn(async (_url: URL, init?: RequestInit) => {
      authorizations.push(new Headers(init?.headers).get("authorization") ?? "");
      return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "content-type": "application/json" } });
    }));
    const client = new MutationClient({ origin: "https://example.test", agentId: "test", oidcTokenProvider: provider });

    await client.request("/internal/first");
    vi.setSystemTime(new Date("2026-08-10T19:01:10Z"));
    await client.request("/internal/second");

    expect(provider).toHaveBeenCalledTimes(2);
    expect(authorizations).toEqual([`Bearer ${first}`, `Bearer ${second}`]);
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it.each([
    ["GET", undefined],
    ["POST", { value: "post" }],
    ["PUT", { value: "put" }],
    ["PATCH", { value: "patch" }],
  ] as const)("retries an explicit expired-token 401 once for %s with a rebuilt envelope", async (method, json) => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-10T19:00:00Z"));
    const token = (label: string) => `header.${Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1_000) + 300, label })).toString("base64url")}.signature`;
    const first = token("first");
    const second = token("second");
    const provider = vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second);
    const requests: Array<{ authorization: string; timestamp: string; nonce: string; body: Uint8Array }> = [];
    vi.stubGlobal("fetch", vi.fn(async (_url: URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      const requestBody = init?.body instanceof Blob ? new Uint8Array(await init.body.arrayBuffer()) : new Uint8Array();
      requests.push({
        authorization: headers.get("authorization") ?? "",
        timestamp: headers.get("x-tc-timestamp") ?? "",
        nonce: headers.get("x-tc-nonce") ?? "",
        body: requestBody,
      });
      if (requests.length === 1) {
        vi.setSystemTime(new Date("2026-08-10T19:00:01Z"));
        return new Response(JSON.stringify({ ok: false, error: "GitHub OIDC token is expired" }), { status: 401 });
      }
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }));
    const client = new MutationClient({ origin: "https://example.test", agentId: "test", oidcTokenProvider: provider });

    await expect(client.request("/internal/test", { method, ...(json === undefined ? {} : { json }) })).resolves.toMatchObject({ ok: true, httpStatus: 200 });

    expect(provider).toHaveBeenCalledTimes(2);
    expect(requests).toHaveLength(2);
    expect(requests.map((request) => request.authorization)).toEqual([`Bearer ${first}`, `Bearer ${second}`]);
    expect(requests[0]?.timestamp).not.toBe(requests[1]?.timestamp);
    expect(requests[0]?.nonce).not.toBe(requests[1]?.nonce);
    expect(requests[0]?.body).toEqual(requests[1]?.body);
  });

  it("surfaces a second expired-token 401 without another retry", async () => {
    const token = (label: string) => `header.${Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1_000) + 300, label })).toString("base64url")}.signature`;
    const provider = vi.fn().mockResolvedValueOnce(token("first")).mockResolvedValueOnce(token("second"));
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ok: false, error: "GitHub OIDC token is expired" }), { status: 401 }));
    vi.stubGlobal("fetch", fetchMock);
    const client = new MutationClient({ origin: "https://example.test", agentId: "test", oidcTokenProvider: provider });

    await expect(client.request("/internal/test", { json: { value: 1 } })).rejects.toThrow("returned 401: GitHub OIDC token is expired");
    expect(provider).toHaveBeenCalledTimes(2);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("does not retry another 401 or an HMAC-authenticated request", async () => {
    const provider = vi.fn().mockResolvedValue("header.eyJleHAiOjQxMDI0NDQ4MDB9.signature");
    const genericFetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ ok: false, error: "mutation role is not authorized" }), { status: 401 }));
    vi.stubGlobal("fetch", genericFetch);
    const oidcClient = new MutationClient({ origin: "https://example.test", agentId: "test", oidcTokenProvider: provider });
    await expect(oidcClient.request("/internal/test")).rejects.toThrow("mutation role is not authorized");
    expect(genericFetch).toHaveBeenCalledTimes(1);
    expect(provider).toHaveBeenCalledTimes(1);

    const expiredFetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ ok: false, error: "GitHub OIDC token is expired" }), { status: 401 }));
    vi.stubGlobal("fetch", expiredFetch);
    const hmacClient = new MutationClient({ origin: "https://example.test", agentId: "test", secret: "fixture-secret" });
    await expect(hmacClient.request("/internal/test")).rejects.toThrow("GitHub OIDC token is expired");
    expect(expiredFetch).toHaveBeenCalledTimes(1);
  });
});
