"""Size parsing and per-unit price normalisation.

The board compares PER-UNIT prices, never sticker prices: "$4.88 for 8 oz" and
"$5.56 for 16 oz" only become comparable once both are cents-per-ounce. This
module turns a store's free-text size string into (quantity, canonical_unit) and
computes the per-unit price.

It is deliberately CONSERVATIVE. When a size string cannot be parsed with
confidence it returns None rather than guessing, because a wrong unit basis
silently produces a wrong "cheapest" crown — the single failure mode this estate
exists to prevent. An unparsed size costs one empty cell; a mis-parsed one
publishes a lie.

Canonical bases mirror the legacy board: 'lb' for weight, 'oz' for fluid volume,
'ct' for count, 'each' for indivisible items.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# unit vocabulary
# ---------------------------------------------------------------------------

WEIGHT_TO_OZ = {
    "oz": 1.0, "ounce": 1.0, "ounces": 1.0,
    "lb": 16.0, "lbs": 16.0, "pound": 16.0, "pounds": 16.0, "#": 16.0,
    "g": 0.035274, "gram": 0.035274, "grams": 0.035274,
    "kg": 35.274, "kilogram": 35.274,
}

VOLUME_TO_FLOZ = {
    "fl oz": 1.0, "floz": 1.0, "fluid ounce": 1.0, "fl. oz": 1.0,
    "ml": 0.033814, "milliliter": 0.033814,
    "l": 33.814, "liter": 33.814, "litre": 33.814,
    "qt": 32.0, "quart": 32.0,
    "pt": 16.0, "pint": 16.0,
    "gal": 128.0, "gallon": 128.0,
}

COUNT_WORDS = {"ct", "count", "pk", "pack", "each", "ea", "dozen", "doz", "rolls", "roll"}

_NUM = r"(\d+(?:\.\d+)?(?:\s*/\s*\d+)?)"


@dataclass
class Size:
    qty: float
    unit: str            # canonical: 'oz' (weight) | 'floz' | 'ct'
    basis: str           # 'weight' | 'volume' | 'count'
    multiplier: int = 1  # e.g. "12 x 8 oz" -> multiplier 12

    @property
    def total(self) -> float:
        return self.qty * self.multiplier


def _num(text: str) -> float | None:
    """Parse a number that may be a fraction ('1/2') or a decimal."""
    text = text.strip()
    if "/" in text:
        try:
            a, b = text.split("/", 1)
            return float(a.strip()) / float(b.strip())
        except (ValueError, ZeroDivisionError):
            return None
    try:
        return float(text)
    except ValueError:
        return None


def parse_size(text: str | None) -> Size | None:
    """Parse a store size string into a canonical Size, or None if unsure.

    Handles the forms these seven stores actually emit:
        "8 oz"            "16.9 fl oz"      "2 Liter"       "1 lb"
        "4.7-6.1 lb"      "12 Count"        "6 Pack"        "12 x 8 oz"
        "30 ct."          "3 ct., 29 oz."   "18.2 Oz"
    """
    if not text:
        return None
    t = str(text).strip().lower().replace(" ", " ")
    if not t:
        return None

    # Multipacks. Two spellings, and missing the second one was a large,
    # systematic parity defect: "72 pk 0.67 oz" was read as 0.67 oz, so a
    # 72-count cheese pack priced at exactly 72x the true per-ounce rate. The
    # give-away was that the graph/board ratio equalled the pack count on every
    # such row (72.01, 47.99, 24.00, 11.99).
    #
    # Only treat "N pk/ct" as a MULTIPLIER when another quantity follows it. A
    # bare "6 ct" is a count basis in its own right, not a multiplier, and
    # conflating them would break every count-priced commodity.
    mult = 1
    for pat in (rf"{_NUM}\s*(?:x|×)\s*(?={_NUM})",
                rf"{_NUM}\s*(?:pk|pack|ct|count)\.?,?\s+(?={_NUM})"):
        mx = re.search(pat, t)
        if mx:
            v = _num(mx.group(1))
            if v and v >= 1:
                mult = int(v)
                t = t[mx.end():]
            break

    # a range ("4.7-6.1 lb") -> take the midpoint, which is what a shopper pays on average
    rng = re.search(rf"{_NUM}\s*[-–]\s*{_NUM}\s*([a-z.\s]+)", t)
    if rng:
        lo, hi = _num(rng.group(1)), _num(rng.group(2))
        unit_txt = rng.group(3)
        if lo and hi and hi >= lo:
            s = _classify((lo + hi) / 2.0, unit_txt)
            if s:
                s.multiplier = mult
                return s

    # volume first: "fl oz" must beat the bare "oz" weight rule
    for pat, table, basis, canon in (
        (rf"{_NUM}\s*(fl\.?\s*oz|fluid\s+ounces?)", VOLUME_TO_FLOZ, "volume", "floz"),
        (rf"{_NUM}\s*(ml|milliliters?|l|liters?|litres?|qt|quarts?|pt|pints?|gal|gallons?)\b",
         VOLUME_TO_FLOZ, "volume", "floz"),
        (rf"{_NUM}\s*(lbs?|pounds?|#|oz|ounces?|kg|kilograms?|g|grams?)\b",
         WEIGHT_TO_OZ, "weight", "oz"),
    ):
        m = re.search(pat, t)
        if m:
            qty, unit_txt = _num(m.group(1)), m.group(2).strip().replace(".", "")
            factor = table.get(unit_txt) or table.get(unit_txt.rstrip("s"))
            if qty and factor:
                return Size(qty * factor, canon, basis, mult)

    # count last — the weakest signal
    mc = re.search(rf"{_NUM}\s*(ct|count|pk|pack|ea|each|dozen|doz|rolls?)\b", t)
    if mc:
        qty, w = _num(mc.group(1)), mc.group(2)
        if qty:
            if w in ("dozen", "doz"):
                qty *= 12
            return Size(qty, "ct", "count", mult)

    # A BARE unit word with no number means a quantity of one, and the sticker is
    # already the unit price. product-urls stores per-pound meat as
    # {"price": 2.19, "size": "lb"} — refusing that as unparseable threw away the
    # single largest source of board cells (86% of live cells have such an entry).
    bare = t.strip().strip(".").strip("/")
    if bare in WEIGHT_TO_OZ:
        return Size(WEIGHT_TO_OZ[bare], "oz", "weight", mult)
    if bare in VOLUME_TO_FLOZ:
        return Size(VOLUME_TO_FLOZ[bare], "floz", "volume", mult)
    if bare in COUNT_WORDS:
        return Size(12.0 if bare in ("dozen", "doz") else 1.0, "ct", "count", mult)

    return None


def _classify(qty: float, unit_txt: str) -> Size | None:
    u = unit_txt.strip().replace(".", "").split()[0] if unit_txt.strip() else ""
    if u in WEIGHT_TO_OZ:
        return Size(qty * WEIGHT_TO_OZ[u], "oz", "weight")
    if u in VOLUME_TO_FLOZ:
        return Size(qty * VOLUME_TO_FLOZ[u], "floz", "volume")
    if u in COUNT_WORDS:
        return Size(qty, "ct", "count")
    return None


_ENGINE_RE = re.compile(r"(\d+(?:\.\d+)?)\s*(¢|c|\$)?\s*/\s*([a-z]+)", re.IGNORECASE)


def parse_engine_unit_price(text: str | None) -> tuple[float | None, str | None]:
    """Parse a unit price the LEGACY ENGINE already computed and verified.

    Captures carry the pipeline's own answer per row:
        wm_unit_price : "61.0 ¢/oz"
        engine_check  : "0.61/oz [size 8 oz]"

    Preferring these over re-deriving from the size string is the correct call
    twice over. They were produced by compare-deals' real Get-UnitPrice and, for
    Walmart, verified to reproduce the store's OWN published unit price — so they
    are more trustworthy than any parser written here. And using them makes board
    parity a test of the graph's plumbing rather than a test of this module's
    size-string regexes, which is what the Phase 2 gate is actually asking.

    Returns (value_in_dollars, unit) or (None, None).
    """
    if not text:
        return None, None
    m = _ENGINE_RE.search(str(text))
    if not m:
        return None, None
    try:
        val = float(m.group(1))
    except ValueError:
        return None, None
    # "61.0 ¢/oz" is cents; "0.61/oz" and "$0.61/oz" are dollars.
    if m.group(2) in ("¢", "c", "C"):
        val /= 100.0
    unit = m.group(3).lower()
    if unit in ("lbs", "pounds", "pound"):
        unit = "lb"
    elif unit in ("ounce", "ounces"):
        unit = "oz"
    return round(val, 4), unit


# How many of unit X are in one unit Y, for the conversions that are exact.
# Anything not listed here is NOT convertible and must not be guessed at.
_CONVERT: dict[tuple[str, str], float] = {
    ("oz", "lb"): 16.0,
    ("lb", "oz"): 1 / 16.0,
    ("floz", "gal"): 128.0, ("floz", "gallon"): 128.0,
    ("floz", "qt"): 32.0, ("floz", "quart"): 32.0,
    ("floz", "pt"): 16.0, ("floz", "pint"): 16.0,
    ("floz", "l"): 33.814, ("floz", "liter"): 33.814,
    ("ml", "l"): 1000.0,
    ("g", "kg"): 1000.0,
    # eggs are declared per dozen on the board but parse as a count
    ("ct", "dozen"): 12.0, ("ct", "doz"): 12.0,
    ("ct", "each"): 1.0, ("each", "ct"): 1.0,
}


def reconcile_unit(value: float | None, from_unit: str | None,
                   to_unit: str | None) -> tuple[float | None, str | None]:
    """Convert a per-unit price from one basis to another, or refuse.

    This exists because a unit price is meaningless without its basis, and the
    two sources disagree: the capture engine reports milk at price-per-FLUID-OUNCE
    while the board declares milk's basis as per-GALLON. Comparing those two
    numbers directly says milk costs $0.022, which would hand it a fake
    "cheapest" crown by a factor of 128.

    Returns (None, None) when the conversion is not exact. Refusing is correct:
    an unconvertible row costs one empty cell, whereas a guessed conversion
    publishes a wrong price — the asymmetry this whole module is built around.
    """
    if value is None or not from_unit:
        return None, None
    f = str(from_unit).strip().lower()
    t = str(to_unit or "").strip().lower()

    # Normalise spellings BEFORE comparing. This map is the one place a surface
    # form is canonicalised — the same rule ids.STORE_CANON follows for store
    # names: add the form here, never "fix" it at a call site.
    #
    # fl_oz is not hypothetical: commodities.json declares BOTH 'floz' (74
    # commodities) and 'fl_oz' (5). Without the underscore forms below,
    # reconcile_unit could not convert fl_oz even TO ITSELF, so those five
    # commodities silently refused every derived price they were ever offered.
    # The graph adapts to the legacy catalog's surface forms; it does not write
    # back to commodities.json to tidy them (dual-write only).
    alias = {"fl oz": "floz", "fl_oz": "floz", "fl. oz": "floz", "fl-oz": "floz",
             "fluid ounce": "floz", "fluid ounces": "floz", "fluid_ounce": "floz",
             "ounce": "oz", "ounces": "oz",
             "pounds": "lb", "lbs": "lb", "pound": "lb", "each": "each", "ea": "each",
             "count": "ct", "counts": "ct", "gallon": "gal", "gallons": "gal",
             "grams": "gram", "g": "gram",
             "sqft": "sq_ft", "sq ft": "sq_ft", "square foot": "sq_ft",
             "square feet": "sq_ft", "dozens": "dozen"}
    f = alias.get(f, f)
    t = alias.get(t, t)

    if not t or f == t:
        return value, f
    factor = _CONVERT.get((f, t))
    if factor is None:
        return None, None
    return round(value * factor, 4), t


def coerce_price(v) -> float | None:
    """Accept the several ways a price is written across this estate.

    Captures store floats, product-urls stores "$10.35", some lanes store "1.49"
    as a bare string, and Sam's reject rows store "" for missing. Coercing here
    rather than at each call site means a caller cannot forget and crash on a
    string, which is exactly what happened the first time product-urls prices
    were fed to per_unit().
    """
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    m = re.search(r"-?\d+(?:\.\d+)?", str(v).replace(",", ""))
    return float(m.group()) if m else None


# A count WORD is required, but the parentheses are not. The original pattern
# demanded "(8 ct)" and so missed every "Brioche Buns, 6 Count", "Tortillas, 8
# Count" and "Ice Pops, 18 Ct" in the corpus — 745 of 3,783 each-basis rows,
# each priced as a SINGLE item and therefore overstated by its own pack count
# (the 18-count popsicles read $5.99 each instead of $0.33).
#
# The conservatism that mattered is kept: a BARE number is still never used,
# because in a product name it is far more often a flavour, a percentage or a
# size ("2% Milk", "100 Calorie"). What is accepted is a number immediately
# followed by an explicit count word, which is not something a flavour looks like.
_NAME_COUNT = re.compile(r"\b(\d+)\s*(?:ct|count|pk|pack)s?\.?\b", re.IGNORECASE)


def count_from_name(name: str | None) -> int | None:
    """Pull a pack count out of a PRODUCT NAME, e.g. 'Fresh Sweet Corn (4 Ct)'.

    Some lanes put the count in the name and leave the size field as a bare
    "1 pk", which reads as a single unit and prices a 4-ear corn pack at 4x the
    true per-ear rate. Only a parenthesised count is accepted: a bare number in
    a name is far too often a flavour, a percentage, or a size already counted
    ("2% Milk", "100 Calorie"), and guessing there would invent prices.
    """
    if not name:
        return None
    m = _NAME_COUNT.search(str(name))
    if not m:
        return None
    try:
        v = int(m.group(1))
    except ValueError:
        return None
    return v if 1 < v <= 144 else None


# A measure sitting next to a CONTAINER noun in a product name is the size of
# ONE item ("12 Fl Oz Cans", "1.65 oz bars"), so a pack of N holds N times it.
_CONTAINER = (r"(?:cans?|bottles?|cups?|pouch(?:es)?|bars?|sticks?|packets?|"
              r"boxes|bags?|jars?|tubs?|rolls?|sleeves?|tubes?)")
_MEASURE = (r"(fl\.?\s*oz|fluid\s+ounces?|oz|ounces?|ml|milliliters?|"
            r"l|liters?|litres?|g|grams?|kg|lbs?|pounds?|sq\.?\s*ft|square\s+feet)")

_NAME_PER_ITEM = re.compile(rf"{_NUM}\s*-?\s*{_MEASURE}\.?\s*-?\s*{_CONTAINER}\b", re.IGNORECASE)
_NAME_MEASURE = re.compile(rf"{_NUM}\s*-?\s*{_MEASURE}\b", re.IGNORECASE)


def _measure_to_size(qty: float, raw_unit: str) -> "Size | None":
    """Turn a (number, unit-word) pair into a canonical Size."""
    u = re.sub(r"[.\s]+", " ", raw_unit.strip().lower()).strip()
    u = {"fl oz": "fl oz", "fluid ounce": "fl oz", "fluid ounces": "fl oz"}.get(u, u)
    if u in VOLUME_TO_FLOZ:
        return Size(qty * VOLUME_TO_FLOZ[u], "floz", "volume")
    if u in ("sq ft", "sqft", "square feet", "square foot"):
        return Size(qty, "sq_ft", "area")
    if u in WEIGHT_TO_OZ:
        return Size(qty * WEIGHT_TO_OZ[u], "oz", "weight")
    return None


def size_from_name(product_name: str | None, count: float) -> "Size | None":
    """Recover a pack's true measure from its NAME when the size field gave only
    a count: "Rc Cola Soda, 12 Fl Oz Cans" at 24 ea is 288 fl oz, not 24 of
    nothing. Roughly 4,670 rows carry their real size only in the name.

    Deliberately as conservative as count_from_name, and for the same reason —
    a bare number in a product name is very often a flavour, a percentage or a
    brand ("2% Milk", "100 Calorie", "7UP"), and inventing a size publishes a
    wrong per-unit price. Two rules keep it honest:

      * The number must be immediately followed by a UNIT word. A naked number
        is never used.
      * With a count above 1 the measure must also sit against a CONTAINER noun
        ("12 fl oz cans"), which is what marks it as the size of one item. Left
        unqualified it could equally be the pack TOTAL, and multiplying a total
        by the count inflates the size — and so understates the per-unit price,
        which is the direction that steals a cheapest-crown.

    A count of exactly 1 needs no such proof: one item's size IS the total, so
    any explicit measure in the name can be taken at face value.
    """
    if not product_name or count <= 0:
        return None
    m = _NAME_PER_ITEM.search(str(product_name))
    if m:
        q = _num(m.group(1))
        s = _measure_to_size(q, m.group(2)) if q is not None else None
        return Size(s.qty * count, s.unit, s.basis) if s else None
    if count == 1:
        m = _NAME_MEASURE.search(str(product_name))
        if m:
            q = _num(m.group(1))
            return _measure_to_size(q, m.group(2)) if q is not None else None
    return None


# An ad line that offers a CHOICE — "Jack Link's Beef Jerky or Pepperidge Farm
# Goldfish, $5.99" — names two products and one price, and nothing says which
# size the price is per. Weekly ads are full of them.
_CHOICE_AD = re.compile(
    r"\b(?:or)\b(?=[^,]*\b(?:oz|ct|lb|pk|pack|fl|count|each|ea)\b)"   # "A or B 12 oz"
    r"|\b\d+(?:\.\d+)?\s*(?:oz|ct|lb|fl\.?\s*oz)\b[^,]*\bor\b",       # "30 oz or ..."
    re.IGNORECASE)


def names_multiple_products(product_name: str | None) -> bool:
    """True when a listing offers a CHOICE of products under one price.

    Such a row is a correct MATCH (the commodity really is on offer) but cannot
    yield a per-unit price: the price attaches to whichever item the shopper
    picks, and the two rarely share a size. Measured 2026-08-20: "Duke's
    Mayonnaise 30 oz or Heinz Ketchup 32 oz" priced the bakers mayonnaise cell
    11% under the board, and "Jack Link's Beef Jerky or Pepperidge Farm ..."
    did the same to beef-jerky. Refusing costs one empty ad price; guessing
    publishes a number no shelf will honour.
    """
    if not product_name:
        return False
    return bool(_CHOICE_AD.search(str(product_name)))


def per_unit(price, size_text: str | None,
             commodity_unit: str | None = None,
             product_name: str | None = None) -> tuple[float | None, str | None]:
    """Price per canonical unit.

    Returns (value, unit) or (None, None) when the size cannot be parsed
    confidently. `commodity_unit` is the board's declared basis for the
    commodity ('lb', 'oz', 'ct', 'each'); when it is 'lb' the weight answer is
    converted from per-ounce to per-pound so it matches the legacy board.
    """
    price = coerce_price(price)
    if price is None:
        return None, None
    s = parse_size(size_text)

    # A size of "1 pk"/"1 ct" carries no information; if the NAME states the
    # count, use it. Applied only when the parsed size is a single unit, so a
    # real size is never overridden by a number scraped out of a name.
    if s is not None and s.basis == "count" and s.total <= 1:
        n = count_from_name(product_name)
        if n:
            s = Size(float(n), "ct", "count", 1)

    # An 'each'-basis commodity is priced per ITEM, and that is true whether or
    # not a size parsed. Bread declares 'each' and its listings carry "20 oz";
    # deriving $/oz there and then asking reconcile_unit for oz -> each refuses
    # forever, which is how ~6,097 rows across 75 commodities went unpriceable
    # while the live board happily showed "$1.69 each" for the same listing.
    # The board's rule, read off comparison-*.json: price divided by the pack
    # COUNT (bar soap $0.4988/bar, buns $0.1658/bun), or the sticker price when
    # there is no count. Mirror it exactly — a weight on the label never turns
    # an each-priced commodity into a per-ounce one.
    if (commodity_unit or "").lower() in ("each", "ea"):
        n = 1.0
        if s and s.basis == "count" and s.total > 0:
            n = float(s.total)
        elif s and s.multiplier and s.multiplier > 1:
            # "18 pk 1.65 fl oz" parses as VOLUME with multiplier 18 — and for
            # an each-basis commodity that multiplier IS the pack count. Without
            # this the size parsed perfectly and was then ignored, pricing an
            # 18-count box of ice pops at the full $5.99 per pop.
            n = float(s.multiplier)
        else:
            c = count_from_name(product_name)
            if c:
                n = float(c)
        return round(float(price) / n, 4), "each"

    if not s or s.total <= 0:
        # No size to divide by; for a count basis the sticker IS the unit price.
        if (commodity_unit or "").lower() in ("ct", "count"):
            return float(price), "each"
        return None, None

    # A COUNT cannot answer a weight/volume/area basis on its own ("24 ea" says
    # nothing about fluid ounces). Before giving up, look for the pack's real
    # measure in the product name — see size_from_name for why that is safe.
    if s.basis == "count" and (commodity_unit or "").lower() not in (
            "", "ct", "count", "each", "ea", "pk", "pack", "dozen"):
        named = size_from_name(product_name, s.total)
        if named and named.total > 0:
            s = named

    pu = float(price) / s.total
    unit = s.unit
    if s.basis == "weight" and (commodity_unit or "").lower() in ("lb", "lbs", "pound"):
        pu *= 16.0
        unit = "lb"
    elif s.unit == "oz" and (commodity_unit or "").lower() in ("floz", "fl oz"):
        # Stores routinely write a bare "oz" for a liquid ("Sparkling Ice ...
        # 17 oz"). When the COMMODITY's declared basis is fluid ounces, a bare
        # ounce reading is that store's shorthand for fl oz, not a weight. This
        # is scoped to that case only -- weight and volume ounces are otherwise
        # never interchangeable, which is why reconcile_unit refuses the pair.
        unit = "floz"
    return round(pu, 4), unit
