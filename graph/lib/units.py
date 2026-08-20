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

    # multipack: "12 x 8 oz" / "3 ct., 29 oz."
    mult = 1
    mx = re.search(rf"{_NUM}\s*(?:x|×)\s*(?={_NUM})", t)
    if mx:
        v = _num(mx.group(1))
        if v and v >= 1:
            mult = int(v)
            t = t[mx.end():]

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

    # normalise a few spellings
    alias = {"fl oz": "floz", "fluid ounce": "floz", "ounce": "oz", "ounces": "oz",
             "pounds": "lb", "lbs": "lb", "pound": "lb", "each": "each", "ea": "each",
             "count": "ct", "gallon": "gal"}
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


def per_unit(price, size_text: str | None,
             commodity_unit: str | None = None) -> tuple[float | None, str | None]:
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
    if not s or s.total <= 0:
        # 'each'-based commodities have no size to parse; the sticker IS the unit price.
        if (commodity_unit or "").lower() in ("each", "ea", "ct"):
            return float(price), "each"
        return None, None

    pu = float(price) / s.total
    unit = s.unit
    if s.basis == "weight" and (commodity_unit or "").lower() in ("lb", "lbs", "pound"):
        pu *= 16.0
        unit = "lb"
    return round(pu, 4), unit
