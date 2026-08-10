import { describe, expect, it, vi } from "vitest";
import type { CurrentBridgeArtifact } from "./legacy";
import { deployConfiguration, MutationClient } from "./client";

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

describe("GitHub OIDC authorization", () => {
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
});
