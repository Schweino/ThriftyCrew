import { afterEach, describe, expect, it, vi } from "vitest";
import type { CurrentBridgeArtifact } from "./legacy";
import { deployConfiguration, MutationClient, publishNativeRelease } from "./client";
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
});

describe("native release publication", () => {
  it("treats a deterministic release published by a concurrent executor as idempotent success", async () => {
    let releaseReads = 0;
    const request = vi.fn(async (pathname: string) => {
      if (pathname === "/internal/releases") {
        releaseReads += 1;
        return { ok: true, state: releaseReads === 1 ? "draft" : "published" };
      }
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
