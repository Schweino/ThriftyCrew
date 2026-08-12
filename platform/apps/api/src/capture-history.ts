import { CAPTURE_SEMANTICS_CUTOVER } from "@thriftycrew/contracts";

export function requiresCaptureHistoryAssessment(captureMethod: string, capturedTo: string): boolean {
  return captureMethod !== "legacy_bridge"
    && Date.parse(capturedTo) >= Date.parse(CAPTURE_SEMANTICS_CUTOVER);
}
