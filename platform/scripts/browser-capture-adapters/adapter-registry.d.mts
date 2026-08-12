export interface CaptureAdapterManifest {
  id: string;
  store: "aldi" | "fareway" | "sams" | "walmart";
  version: string;
  module: string;
  sha256: string;
  capabilities: string[];
  rate: { maxConcurrent: number; minimumDelayMs: number; maxTermsPerLegacyChunk: number };
}
export function captureAdapterManifest(store: string): Promise<CaptureAdapterManifest>;
export function captureAdapterRegistry(): Promise<Record<string, CaptureAdapterManifest>>;
export function validateCaptureAdapterManifest(manifest: CaptureAdapterManifest): CaptureAdapterManifest;
