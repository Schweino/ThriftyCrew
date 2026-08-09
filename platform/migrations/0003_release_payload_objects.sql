ALTER TABLE release_payloads ADD COLUMN object_key TEXT;
ALTER TABLE release_payloads ADD COLUMN byte_length INTEGER CHECK (byte_length IS NULL OR byte_length >= 0);

CREATE UNIQUE INDEX release_payload_object_key
  ON release_payloads(object_key)
  WHERE object_key IS NOT NULL;
