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

export interface GhostMemberSession {
  paid?: boolean;
  status?: string;
  subscriptions?: Array<{
    status?: string;
    current_period_end?: string | number;
    cancel_at_period_end?: boolean;
    canceled_at?: string | number | null;
  }>;
}

const anonymous: Entitlement = { state: "anonymous", authenticated: false, tier: "anonymous", mayUseProtectedTools: false };

export function classifyGhostSession(facts: GhostSessionFacts, nowIso: string): Entitlement {
  if (facts.explicitlySignedOut) return { state: "signed_out", authenticated: false, tier: "anonymous", mayUseProtectedTools: false };
  if (!facts.cookiePresent) return anonymous;
  if (facts.cookieExpiresAt && facts.cookieExpiresAt <= nowIso) return { state: "cookie_expired", authenticated: false, tier: "anonymous", mayUseProtectedTools: false };
  if (!facts.member) return anonymous;
  if (facts.member.status === "paid") return { state: "paid", authenticated: true, tier: "paid", mayUseProtectedTools: true };
  if (facts.member.status === "free") return { state: "free", authenticated: true, tier: "free", mayUseProtectedTools: false };
  return { state: facts.member.status, authenticated: true, tier: "free", mayUseProtectedTools: false };
}

function cookiePairs(header: string): Array<{ name: string; value: string }> {
  return header.split(";").map((part) => {
    const separator = part.indexOf("=");
    return separator < 0
      ? { name: part.trim(), value: "" }
      : { name: part.slice(0, separator).trim(), value: part.slice(separator + 1).trim() };
  }).filter((item) => item.name.length > 0);
}

function jwtExpiry(value: string): string | undefined {
  try {
    const decoded = decodeURIComponent(value).replace(/^s:/, "");
    const parts = decoded.split(".");
    if (parts.length !== 3 || !parts[1]) return undefined;
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parts[1].length / 4) * 4, "=");
    const payload = JSON.parse(atob(base64)) as { exp?: number };
    return typeof payload.exp === "number" ? new Date(payload.exp * 1000).toISOString() : undefined;
  } catch {
    return undefined;
  }
}

export function ghostCookieFacts(cookieHeader: string, nowIso: string): Pick<GhostSessionFacts, "cookiePresent" | "cookieExpiresAt" | "explicitlySignedOut"> {
  const cookies = cookiePairs(cookieHeader);
  const explicitlySignedOut = cookies.some((item) => item.name === "tc_member_signed_out" && item.value === "1");
  const ghostCookies = cookies.filter((item) => /ghost.*member|member.*ghost|members-ssr/i.test(item.name));
  const expiries = ghostCookies.map((item) => jwtExpiry(item.value)).filter((value): value is string => value !== undefined).sort();
  const cookieExpiresAt = expiries.at(0);
  return {
    cookiePresent: ghostCookies.length > 0,
    ...(cookieExpiresAt ? { cookieExpiresAt } : {}),
    ...(explicitlySignedOut ? { explicitlySignedOut: true } : {}),
  };
}

function asEpoch(value: string | number | undefined | null): number | undefined {
  if (typeof value === "number") return value > 10_000_000_000 ? value : value * 1000;
  if (typeof value !== "string") return undefined;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export function ghostMemberStatus(member: GhostMemberSession, nowIso: string): "free" | "paid" | "expired" | "cancelled" {
  const status = member.status?.toLowerCase();
  if (member.paid === true || status === "paid" || status === "comped" || status === "gift") return "paid";
  const subscriptions = member.subscriptions ?? [];
  const now = Date.parse(nowIso);
  if (subscriptions.some((subscription) => ["canceled", "cancelled"].includes(subscription.status?.toLowerCase() ?? "") || (subscription.cancel_at_period_end === true && (asEpoch(subscription.current_period_end) ?? 0) <= now))) return "cancelled";
  if (subscriptions.some((subscription) => ["expired", "incomplete_expired"].includes(subscription.status?.toLowerCase() ?? "") || ((asEpoch(subscription.current_period_end) ?? Number.POSITIVE_INFINITY) <= now))) return "expired";
  return "free";
}

export class GhostEntitlementProvider implements EntitlementProvider {
  constructor(private readonly publicOrigin: string, private readonly timeoutMs = 4_000) {}

  async resolve(request: Request): Promise<Entitlement> {
    const nowIso = new Date().toISOString();
    const cookie = request.headers.get("cookie") ?? "";
    const facts = ghostCookieFacts(cookie, nowIso);
    if (facts.explicitlySignedOut || !facts.cookiePresent || (facts.cookieExpiresAt && facts.cookieExpiresAt <= nowIso)) {
      return classifyGhostSession(facts, nowIso);
    }

    const abort = new AbortController();
    const timeout = setTimeout(() => abort.abort("Ghost member session timed out"), this.timeoutMs);
    try {
      const response = await fetch(new URL("/members/api/member/", this.publicOrigin), {
        headers: { cookie, accept: "application/json", "user-agent": "ThriftyCrew-V3-Entitlements/1.0" },
        redirect: "manual",
        signal: abort.signal,
      });
      if (response.status === 204 || response.status === 401 || response.status === 403) {
        return classifyGhostSession(facts, nowIso);
      }
      if (!response.ok) throw new Error(`Ghost member session returned ${response.status}`);
      const member = await response.json() as GhostMemberSession;
      return classifyGhostSession({ ...facts, member: { status: ghostMemberStatus(member, nowIso) } }, nowIso);
    } finally {
      clearTimeout(timeout);
    }
  }
}
