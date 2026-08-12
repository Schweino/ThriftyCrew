import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { decryptCaptureJournalEnvelope, encryptCaptureJournalEnvelope } from "./capture-journal-envelope";

describe("encrypted capture journal envelope", () => {
  it("round-trips a serialized journal without exposing plaintext", () => {
    const key = randomBytes(32);
    const plain = Buffer.from("SQLite format 3\u0000private capture queue state".repeat(20));
    const encrypted = encryptCaptureJournalEnvelope(plain, key);
    expect(Buffer.from(encrypted).includes(plain)).toBe(false);
    expect(Buffer.from(decryptCaptureJournalEnvelope(encrypted, key))).toEqual(plain);
  });

  it("rejects tampering and the wrong recovery key", () => {
    const key = randomBytes(32);
    const encrypted = encryptCaptureJournalEnvelope(Buffer.from("journal"), key);
    encrypted[encrypted.length - 1] = encrypted[encrypted.length - 1]! ^ 1;
    expect(() => decryptCaptureJournalEnvelope(encrypted, key)).toThrow();
    expect(() => decryptCaptureJournalEnvelope(encryptCaptureJournalEnvelope(Buffer.from("journal"), key), randomBytes(32))).toThrow();
  });
});
