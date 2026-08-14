export type DefinitionSyncItem = { commodityId: string; correctionId: string };

export function planDefinitionSync(audit: any, input: { offset: number; limit: number; excluded: Set<string> }) {
  const unmapped = audit?.unmapped ?? {};
  const blockingKeys = ["missingConfig", "configNotInRun", "knownWrongCommodityNotInRun", "knownWrongStore"];
  const blockingCount = blockingKeys.reduce((sum, key) => sum + (Array.isArray(unmapped[key]) ? unmapped[key].length : 0), 0);
  const reversed = Array.isArray(unmapped.reversedKnownWrong) ? unmapped.reversedKnownWrong : [];
  if (audit?.summary?.total !== 573 || audit?.summary?.invalid !== 0 || !Array.isArray(audit?.definitions)
    || audit.definitions.length !== 573 || blockingCount !== 0 || reversed.length !== 3
    || reversed.some((row: any) => !String(row.reversed_on ?? "").trim() || !String(row.reversed_by ?? "").trim())) {
    throw new Error("definition sync requires the complete clean post-foil 573-definition audit artifact");
  }
  const definitions: DefinitionSyncItem[] = audit.definitions.filter((row: any) => row.changed === true
    && !input.excluded.has(String(row.commodityId))).map((row: any) => ({ commodityId: String(row.commodityId),
      correctionId: `authored-identity-v1-${String(row.commodityId)}` }));
  return { total: definitions.length, page: definitions.slice(input.offset, input.offset + input.limit), nextOffset:
    Math.min(definitions.length, input.offset + input.limit), reversedKnownWrong: reversed.length };
}
