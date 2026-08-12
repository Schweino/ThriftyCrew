-- @policy expand-contract
-- Release-neutral recipe bundles are immutable content-addressed objects. Many
-- releases may reference the same object, so the release mapping cannot make
-- object_key globally unique.

CREATE TABLE release_recipe_payload_refs (
  release_id TEXT NOT NULL REFERENCES releases(id),
  recipe_slug TEXT NOT NULL,
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  object_key TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (release_id, recipe_slug)
) STRICT;

CREATE INDEX release_recipe_payload_refs_lookup
  ON release_recipe_payload_refs(recipe_slug, release_id);

CREATE INDEX release_recipe_payload_refs_content
  ON release_recipe_payload_refs(content_hash, object_key);

INSERT INTO release_recipe_payload_refs
  (release_id, recipe_slug, content_hash, object_key, byte_length, created_at)
SELECT release_id, recipe_slug, content_hash, object_key, byte_length, created_at
  FROM release_recipe_payloads;

PRAGMA optimize;
