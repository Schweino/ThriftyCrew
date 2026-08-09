export type EntitlementState = "anonymous" | "free" | "paid" | "expired" | "cancelled" | "signed_out" | "cookie_expired";

export interface Entitlement {
  state: EntitlementState;
  authenticated: boolean;
  tier: "anonymous" | "free" | "paid";
  mayUseProtectedTools: boolean;
}

export interface GhostSessionFacts {
  cookiePresent: boolean;
  cookieExpiresAt?: string;
  explicitlySignedOut?: boolean;
  member?: { status: "free" | "paid" | "expired" | "cancelled" };
}

export interface EntitlementProvider {
  resolve(request: Request): Promise<Entitlement>;
}

export function classifyGhostSession(facts: GhostSessionFacts, nowIso: string): Entitlement {
  if (facts.explicitlySignedOut) return { state: "signed_out", authenticated: false, tier: "anonymous", mayUseProtectedTools: false };
  if (!facts.cookiePresent) return { state: "anonymous", authenticated: false, tier: "anonymous", mayUseProtectedTools: false };
  if (facts.cookieExpiresAt && facts.cookieExpiresAt <= nowIso) return { state: "cookie_expired", authenticated: false, tier: "anonymous", mayUseProtectedTools: false };
  if (!facts.member) return { state: "anonymous", authenticated: false, tier: "anonymous", mayUseProtectedTools: false };
  if (facts.member.status === "paid") return { state: "paid", authenticated: true, tier: "paid", mayUseProtectedTools: true };
  if (facts.member.status === "free") return { state: "free", authenticated: true, tier: "free", mayUseProtectedTools: false };
  return { state: facts.member.status, authenticated: true, tier: "free", mayUseProtectedTools: false };
}
