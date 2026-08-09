ALTER TABLE observations
  ADD COLUMN basis_options_json TEXT NOT NULL DEFAULT '[]'
  CHECK (json_valid(basis_options_json));
