import { describe, expect, it } from "vitest";
import { classifyGhostSession, ghostCookieFacts, ghostMemberStatus, GhostEntitlementProvider } from "./index";

const now = "2026-08-09T12:00:00.000Z";

describe("Ghost entitlement seven-state matrix", () => {
  it.each([
    ["anonymous", { cookiePresent: false }, false],
    ["free", { cookiePresent: true, member: { status: "free" as const } }, false],
    ["paid", { cookiePresent: true, member: { status: "paid" as const } }, true],
    ["expired", { cookiePresent: true, member: { status: "expired" as const } }, false],
    ["cancelled", { cookiePresent: true, member: { status: "cancelled" as const } }, false],
    ["signed_out", { cookiePresent: true, explicitlySignedOut: true }, false],
    ["cookie_expired", { cookiePresent: true, cookieExpiresAt: "2026-08-08T12:00:00.000Z", member: { status: "paid" as const } }, false],
  ])("classifies %s server-side", (state, facts, allowed) => {
    expect(classifyGhostSession(facts, now)).toMatchObject({ state, mayUseProtectedTools: allowed });
  });
});

describe("Ghost member adapter", () => {
  it("recognizes and expires a Ghost member JWT cookie without trusting the client", () => {
    const payload = btoa(JSON.stringify({ exp: Math.floor(Date.parse("2026-08-08T12:00:00.000Z") / 1000) })).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    expect(ghostCookieFacts(`ghost-members-ssr=x.${payload}.sig`, now)).toMatchObject({ cookiePresent: true, cookieExpiresAt: "2026-08-08T12:00:00.000Z" });
  });

  it("maps Ghost subscription truth without granting cancelled or expired access", () => {
    expect(ghostMemberStatus({ paid: true, subscriptions: [{ status: "active" }] }, now)).toBe("paid");
    expect(ghostMemberStatus({ paid: false, subscriptions: [{ status: "canceled" }] }, now)).toBe("cancelled");
    expect(ghostMemberStatus({ paid: false, subscriptions: [{ status: "incomplete_expired" }] }, now)).toBe("expired");
  });

  it("forwards only the server request cookie and resolves a free member", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("cookie")).toBe("ghost-members-ssr=opaque");
      return Response.json({ paid: false, status: "free", subscriptions: [] });
    }) as typeof fetch;
    try {
      const result = await new GhostEntitlementProvider("https://example.com").resolve(new Request("https://worker.test/api", { headers: { cookie: "ghost-members-ssr=opaque" } }));
      expect(result).toMatchObject({ state: "free", authenticated: true, mayUseProtectedTools: false });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
