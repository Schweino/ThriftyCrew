import type { ObservationInput } from "@thriftycrew/contracts";

const encoder = new TextEncoder();

export function normalizeName(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

export function expectedPerUnitMicros(priceMinor: number, normalizedBasisQtyMicros: number): number {
  if (!Number.isSafeInteger(priceMinor) || priceMinor < 0) throw new Error("priceMinor must be a non-negative safe integer");
  if (!Number.isSafeInteger(normalizedBasisQtyMicros) || normalizedBasisQtyMicros <= 0) {
    throw new Error("normalizedBasisQtyMicros must be a positive safe integer");
  }
  const result = Math.round((priceMinor * 10_000 * 1_000_000) / normalizedBasisQtyMicros);
  if (!Number.isSafeInteger(result)) throw new Error("normalized unit price exceeds safe integer range");
  return result;
}

export function assertObservationArithmetic(observation: ObservationInput, toleranceMicros = 2): void {
  const expected = expectedPerUnitMicros(observation.purchasePriceMinor, observation.normalizedBasisQtyMicros);
  if (Math.abs(expected - observation.perUnitMicros) > toleranceMicros) {
    throw new Error(`per-unit mismatch: received ${observation.perUnitMicros}, expected ${expected}`);
  }
}

export function stableJson(value: unknown): string {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((item) => item === undefined ? "null" : stableJson(item)).join(",")}]`;
  const object = value as Record<string, unknown>;
  return `{${Object.keys(object).filter((key) => object[key] !== undefined).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(",")}}`;
}

export async function digestHex(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string" ? encoder.encode(value) : value;
  const digest = await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes).buffer);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function deterministicId(prefix: string, ...parts: string[]): Promise<string> {
  return `${prefix}_${(await digestHex(parts.join("\u001f"))).slice(0, 32)}`;
}

export function centsFromLegacyDollars(value: number): number {
  if (!Number.isFinite(value) || value < 0) throw new Error("legacy dollar amount must be non-negative and finite");
  return Math.round(value * 100);
}

export function microsFromLegacyPerUnit(value: number): number {
  if (!Number.isFinite(value) || value < 0) throw new Error("legacy per-unit amount must be non-negative and finite");
  return Math.round(value * 1_000_000);
}
