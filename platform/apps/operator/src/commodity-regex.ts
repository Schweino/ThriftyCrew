export function normalizeCommodityRegexPattern(value: string): string {
  const pattern = value.trim();
  return pattern.startsWith("(?i)") ? pattern.slice(4) : pattern;
}

export function compileCommodityRegexPattern(value: string): RegExp {
  return new RegExp(normalizeCommodityRegexPattern(value), "i");
}

export function parseCatalogJson<T>(value: string): T {
  return JSON.parse(value.replace(/^\uFEFF/, "")) as T;
}
