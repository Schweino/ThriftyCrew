const ENGINE_HEADLESS_METHODS = new Set(["api", "freshop"]);

export function engineMayWriteCaptureSource(sourceId: string, captureMethod: string): boolean {
  if (sourceId.startsWith("legacy-") && captureMethod === "legacy_bridge") return true;
  return sourceId.startsWith("direct-")
    && sourceId.endsWith("-headless")
    && ENGINE_HEADLESS_METHODS.has(captureMethod);
}
