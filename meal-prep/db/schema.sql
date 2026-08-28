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

-- db\ingredients.json's `aliases`: the OTHER names one price row legitimately answers to. This is a
-- namespace, not a second row - the estate's rule is that aliases live in the vocabulary and never become
-- their own item (a "Smoked Sausage" item row would carry its own bid, its own gpu and its own macros, and
-- the next reader would price it twice). Modelling it as a table is what lets a spec keep writing the name
-- it actually calls for while every join still lands on the one row that holds the price.
--
-- IT ALSO MAKES A STANDING RULING CHECKABLE. Brad, 2026-08-16 (ruling 9): Andouille and generic smoked
-- sausage alias to the PORK row, NEVER to Smoked Turkey Sausage - that would corrupt protein stamping.
-- With this table the ruling is a row with a foreign key, so a future edit that re-points it at the turkey
-- row is a visible diff in a keyed table instead of a string moved between two arrays.
CREATE TABLE item_alias (
  alias TEXT PRIMARY KEY,              -- one owner per alias; a contested alias must be adjudicated, not stored twice
  item  TEXT NOT NULL REFERENCES item(name)
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
-- `item` is the RESOLVED price row and `canon` is the name the spec document actually wrote. They differ
-- exactly when the spec costs an ingredient by an adjudicated alias, which is legal: an alias IS an
-- identity (rebid-ingredient.ps1 selects spec blocks by canon OR item), so flattening the spec's word into
-- the row name would erase the identity the rebid tool selects on. Keeping both means the FK lands on the
-- real row AND the document's own word survives the round trip.
CREATE TABLE spec_ingredient (
  slug  TEXT NOT NULL REFERENCES spec(slug),
  item  TEXT NOT NULL REFERENCES item(name),
  canon TEXT NOT NULL,                 -- what the spec wrote: the item name, or an alias of it
  grams REAL,
  bid   TEXT REFERENCES commodity(id),
  PRIMARY KEY (slug, item)
);

CREATE INDEX idx_item_bid        ON item(bid);
CREATE INDEX idx_spec_ing_item   ON spec_ingredient(item);
CREATE INDEX idx_spec_ing_bid    ON spec_ingredient(bid);
CREATE INDEX idx_item_alias_item ON item_alias(item);
