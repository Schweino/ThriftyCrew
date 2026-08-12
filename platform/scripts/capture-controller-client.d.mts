export const CAPTURE_CONTROLLER_PIPE: string;
export function captureControllerRequest(pathname: string, body?: Record<string, unknown>, environment?: NodeJS.ProcessEnv, timeoutMs?: number): Promise<(Record<string, unknown> & { controllerReachable: true }) | null>;
