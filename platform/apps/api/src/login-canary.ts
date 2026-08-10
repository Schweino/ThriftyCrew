const EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i;

export function assertLoginCanaryEvidenceHasNoEmail(value: unknown, path = "evidence"): void {
  if (typeof value === "string") {
    if (EMAIL_PATTERN.test(value)) throw new Error(`login-canary ${path} contains an email address`);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertLoginCanaryEvidenceHasNoEmail(item, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    if (/e-?mail|member_email/i.test(key)) throw new Error(`login-canary ${path}.${key} is an email field`);
    assertLoginCanaryEvidenceHasNoEmail(nested, `${path}.${key}`);
  }
}
