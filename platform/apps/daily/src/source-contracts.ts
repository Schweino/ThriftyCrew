import type { DirectCaptureArtifact } from "@thriftycrew/contracts";

export interface SourceContract {
  sourceId: string;
  minimumRows: number;
  minimumTermCompletionPercent: number;
  minimumTaxonomyPercent: number;
  requiredPriceMode: boolean;
  allowedPriceModes?: string[];
  maximumRejectedPercent?: number;
}

export interface SourceContractCheck {
  key: string;
  status: "pass" | "fail";
  detail: string;
}

export function evaluateSourceContract(artifact: DirectCaptureArtifact, contract: SourceContract): { status: "pass" | "fail"; checks: SourceContractCheck[] } {
  if (artifact.sourceId !== contract.sourceId) throw new Error(`contract ${contract.sourceId} cannot evaluate ${artifact.sourceId}`);
  const attempted = artifact.terms.filter((term) => term.outcome !== "not_attempted");
  const completed = attempted.filter((term) => term.outcome === "success" || term.outcome === "empty");
  const completionPercent = artifact.terms.length ? Math.floor(completed.length * 100 / artifact.terms.length) : artifact.observations.length ? 100 : 0;
  const taxonomyPercent = artifact.observations.length
    ? Math.floor(artifact.observations.filter((row) => Boolean(row.taxonomyPath)).length * 100 / artifact.observations.length)
    : 0;
  const rejectedRows = typeof artifact.audit.rejectedRows === "number" ? artifact.audit.rejectedRows : 0;
  const inputRows = typeof artifact.audit.inputRows === "number" ? artifact.audit.inputRows : artifact.observations.length + rejectedRows;
  const rejectedPercent = inputRows > 0 ? Math.floor(rejectedRows * 100 / inputRows) : 0;
  const canonicalMode = (value: string) => value.toLowerCase().replaceAll(/[_\s-]+/g, "").replace("clubpickup", "club");
  const allowedModes = contract.allowedPriceModes?.map(canonicalMode) ?? [];
  const checks: SourceContractCheck[] = [
    { key: "minimum-rows", status: artifact.observations.length >= contract.minimumRows ? "pass" : "fail", detail: `${artifact.observations.length} rows; requires ${contract.minimumRows}` },
    { key: "term-completion", status: completionPercent >= contract.minimumTermCompletionPercent ? "pass" : "fail", detail: `${completionPercent}% complete; requires ${contract.minimumTermCompletionPercent}%` },
    { key: "taxonomy-presence", status: taxonomyPercent >= contract.minimumTaxonomyPercent ? "pass" : "fail", detail: `${taxonomyPercent}% taxonomy; requires ${contract.minimumTaxonomyPercent}%` },
    { key: "market-attestation", status: artifact.marketVerified && artifact.locationVerified ? "pass" : "fail", detail: `market=${artifact.marketVerified}; location=${artifact.locationVerified}` },
    { key: "price-mode-attestation", status: !contract.requiredPriceMode || artifact.priceModeVerified ? "pass" : "fail", detail: `priceModeVerified=${artifact.priceModeVerified}` },
    { key: "price-mode-exact", status: allowedModes.length === 0 || allowedModes.includes(canonicalMode(artifact.priceMode)) ? "pass" : "fail", detail: `${artifact.priceMode}; allowed=${contract.allowedPriceModes?.join(",") ?? "any"}` },
    { key: "rejection-rate", status: contract.maximumRejectedPercent === undefined || rejectedPercent <= contract.maximumRejectedPercent ? "pass" : "fail", detail: `${rejectedPercent}% rejected; maximum ${contract.maximumRejectedPercent ?? "unbounded"}%` },
    { key: "observation-shape", status: artifact.observations.every((row) => row.externalProductKey && row.name && row.rawPriceText && row.capturedAt) ? "pass" : "fail", detail: "required product, name, price and capture fields" },
  ];
  return { status: checks.every((check) => check.status === "pass") ? "pass" : "fail", checks };
}
