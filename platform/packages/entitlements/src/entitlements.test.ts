import { describe, expect, it } from "vitest";
import { classifyGhostSession } from "./index";

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
