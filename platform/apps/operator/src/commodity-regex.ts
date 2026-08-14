export function normalizeCommodityRegexPattern(value: string): string {
  const pattern = value.trim();
  return pattern.startsWith("(?i)") ? pattern.slice(4) : pattern;
}

export function compileCommodityRegexPattern(value: string): RegExp {
  return new RegExp(normalizeCommodityRegexPattern(value), "i");
}

export function commodityPhraseExclusionPattern(value: string): string {
  const tokens = value.trim().match(/[a-z0-9]+/gi) ?? [];
  if (tokens.length === 0) throw new Error("commodity exclusion phrase has no searchable tokens");
  return `\\b${tokens.map((token) => token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("\\s+")}\\b`;
}

export function parseCatalogJson<T>(value: string): T {
  return JSON.parse(value.replace(/^\uFEFF/, "")) as T;
}
