-- schema.sql - the relational shape of the ingredient layer (2026-08-08, Brad approved).
--
-- WHY. Four JSON files have to agree about the same nouns, and until now nothing STRUCTURALLY enforced it -
-- agreement was enforced by guards written after each incident (Turkey Bacon's bid pointing at PORK, six
-- items with macros but no price row, Garlic Powder counted in a recipe's macros with no cost line). Every
-- one of those is a foreign key. Here they are declared once, and SQLite refuses the write instead.
--
-- SCOPE, deliberately. This models the TABULAR stores: commodities, ingredients (price+bid), macros, and
-- the density VALUES. It does NOT try to absorb db\densities.json's prose - that file is a decision record
-- as much as a table (its basis_reconciliation and rice_basis notes carry the sourced reasoning for why two
-- files legitimately disagree about a canned bean), and flattening it into rows would destroy the argument
-- while keeping the numbers. The 542 recipe specs stay as documents for the same reason; only their
-- ingredient rows are indexed here, so the joins can be checked.

PRAGMA foreign_keys = ON;

-- the priceable namespace: commodities.json's roster UNION the feed's ingredient ids. Bids resolve against
-- the feed, which is wider than the roster (pork-loin, 93-7-ground-beef and penne-pasta are priced without
-- being roster commodities), so modelling this as the roster alone reports ~900 false broken references.
CREATE TABLE commodity (
  id        TEXT PRIMARY KEY,
  label     TEXT,
  unit      TEXT,
  in_roster INTEGER NOT NULL DEFAULT 0   -- 1 = present in commodities.json, 0 = feed-only
);

-- db\ingredients.json: what an ingredient costs and which board row prices it
CREATE TABLE item (
  name           TEXT PRIMARY KEY,
  bid            TEXT REFERENCES commodity(id),
  gpu            REAL,
  unit           TEXT,
  board          TEXT,
  buy_pkg_g      REAL,
  buy_pkg_label  TEXT,
  pantry_pkg_g   REAL,
  pantry_pkg_label TEXT,
  note           TEXT
);

-- food-macros-db.json: PER SERVING macros. serving_qty/serving_unit describe what one serving IS, which is
-- why a comparison against a per-one-unit density MUST divide by serving_qty (45 g per 0.25 cup is 180
-- g/cup - the same number densities.json holds for Rice, not a 4x disagreement).
CREATE TABLE item_macro (
  item          TEXT PRIMARY KEY REFERENCES item(name),
  brand         TEXT,
  serving_grams REAL,
  serving_qty   REAL,
  serving_unit  TEXT,
  calories      REAL,
  protein_g     REAL,
  carbs_g       REAL,
  fat_g         REAL,
  notes         TEXT
);

-- db\densities.json's per-unit values (the prose stays in the JSON, which remains the authority for WHY)
CREATE TABLE item_density (
  item  TEXT NOT NULL REFERENCES item(name),
  unit  TEXT NOT NULL,
  grams REAL NOT NULL,
  PRIMARY KEY (item, unit)
);

-- recipe specs: documents on disk, indexed here so the joins are checkable
CREATE TABLE spec (
  slug    TEXT PRIMARY KEY,
  name    TEXT,
  cal     INTEGER,
  protein INTEGER,
  cost_ps TEXT
);
CREATE TABLE spec_ingredient (
  slug  TEXT NOT NULL REFERENCES spec(slug),
  item  TEXT NOT NULL REFERENCES item(name),
  grams REAL,
  bid   TEXT REFERENCES commodity(id),
  PRIMARY KEY (slug, item)
);

CREATE INDEX idx_item_bid        ON item(bid);
CREATE INDEX idx_spec_ing_item   ON spec_ingredient(item);
CREATE INDEX idx_spec_ing_bid    ON spec_ingredient(bid);
