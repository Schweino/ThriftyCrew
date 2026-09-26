"""units_selftest.py - per_unit's each-basis boundaries (backlog I222, 2026-09-18).

    python graph/lib/units_selftest.py --selftest

WHAT IT GUARDS.

1. A RATE IS NOT A PACKAGE. per_unit(0.99, 'lb', 'each', ...) returned (0.99, 'each'): Fareway's
   "Whole Cantaloupe or Honeydew Melons, $0.99 lb" priced cantaloupe at $0.99 EACH, 0.29x the median
   and inside flag_outliers' 5x blind range, the false-cheap direction. An each-basis row whose size is a
   price rate ("lb", "/lb", "per lb", "$0.99/lb") is now refused, because converting needs a known weight
   per item and the graph holds none. The board already refused it (compare-deals writes it UNPRICED).

2. A MULTI-PACK IS DIVIDED BY ITS PACK. Bar soap "3.75 oz 8 Bars" at $12.97 and water "( Pack of 24 )"
   at $28.49 were priced as ONE each, because count_from_name needs "N ct/pk" with only spaces between.
   each_pack_count reads the spellings those rows carry, size field first, and never a choice-ad name.

The founding values are the real rows from graph.db on 2026-09-18 (read from a copy).

HERMETIC. Pure function calls; nothing reads or writes a file.

EXIT: 0 all cases pass, 1 at least one failed. Read the verdict LINE, not the number.
"""
# The self-test imports units.py from this directory and reads no data file.
# gate-inputs: graph\lib\units.py
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from units import per_unit, is_rate_size, each_pack_count   # noqa: E402

_fails: list[str] = []
_ran = 0
CASES = 14


def T(label: str, ok: bool, got: object = "") -> None:
    global _ran
    _ran += 1
    if ok:
        print("  ok    " + label)
    else:
        _fails.append(label)
        print("  FAILED " + label + "   got: " + repr(got))


def run() -> int:
    try:
        # ---- 1. a per-pound rate under an each basis ---------------------------------------------
        got = per_unit(0.99, "lb", "each", "Whole Cantaloupe or Honeydew Melons")
        T("MUST FIRE  Fareway cantaloupe $0.99 'lb' under an each basis is refused, not read as "
          "$0.99 each", got == (None, None), got)
        got = per_unit(0.99, "lb", "each", "Athena, Cantaloupe or Honey Dew Whole Melons")
        T("MUST FIRE  the second Fareway row (Athena melons, $0.99 'lb') is refused too",
          got == (None, None), got)
        got = per_unit(0.99, "$0.99/lb", "each", "Cantaloupe")
        T("MUST FIRE  a size spelled '$0.99/lb' is a rate and is refused under each",
          got == (None, None), got)
        got = per_unit(1.29, "per lb", "each", "Honeydew")
        T("MUST FIRE  a size spelled 'per lb' is a rate and is refused under each",
          got == (None, None), got)

        # ---- 2. multi-packs divided by their pack -----------------------------------------------
        got = per_unit(12.97, "30.023 oz", "each",
                       "Dove Beauty Bar Soap For Sensitive Skin, 3.75 oz 8 Bars")
        T("MUST FIRE  Dove '3.75 oz 8 Bars' $12.97 prices per bar (1.6213), not per pack",
          got == (1.6213, "each"), got)
        got = per_unit(28.49, "569.8 fl oz", "each",
                       "Poland Spring Water ,Sport with Flip Cap 23.7 Oz ( Pack of 24 )")
        T("MUST FIRE  Poland Spring '( Pack of 24 )' $28.49 prices per bottle (1.1871)",
          got == (1.1871, "each"), got)
        got = per_unit(5.29, "32 pk .5 L btls", "each", "Fareway Purified or Spring Water")
        T("MUST FIRE  Fareway size '32 pk .5 L btls' $5.29 prices per bottle (0.1653)",
          got == (0.1653, "each"), got)

        # ---- 3. what must still work ------------------------------------------------------------
        got = per_unit(0.99, "lb", "lb", "Bananas")
        T("CLEAN TWIN  the same 'lb' row under a POUND basis still prices $0.99/lb",
          got == (0.99, "lb"), got)
        got = per_unit(2.5, "each", "each", "Fresh Cantaloupe, Each")
        T("CLEAN TWIN  Walmart cantaloupe 'each' $2.50 still prices $2.50 each",
          got == (2.5, "each"), got)
        got = per_unit(1.69, "20 oz", "each", "Bread")
        T("CLEAN TWIN  a PACKAGE weight under each ('20 oz' bread) still prices the sticker, 1.69",
          got == (1.69, "each"), got)
        got = per_unit(12.97, "30.023 oz", "each", "Dove Men+Care 3 in 1 Bar Cleanser")
        T("CLEAN TWIN  a singular '1 Bar' is not a pack count: sticker 12.97 stands",
          got == (12.97, "each"), got)
        T("MUST NOT FIRE  a package size is not a rate: '3 lb', '1 lb/bag', '1/2 lb', '20 oz'",
          not any(is_rate_size(t) for t in ("3 lb", "1 lb/bag", "1/2 lb", "20 oz")),
          [t for t in ("3 lb", "1 lb/bag", "1/2 lb", "20 oz") if is_rate_size(t)])
        got = each_pack_count("each", "Capri Sun 10-Pack or Kroger Purified Water 24-Pack, 8 fl oz")
        T("MUST NOT FIRE  a choice-ad name is never read for a pack count",
          got is None, got)
        got = each_pack_count("24-Pack, 16.9 fl oz", "Ozarka 24-Pack 16.9 fl oz or Pepsi, 6-Pack")
        T("CLEAN TWIN  the size field is still read on a choice-ad row: '24-Pack' gives 24",
          got == 24, got)
    except Exception as e:                                # noqa: BLE001
        _fails.append("suite raised: %r" % (e,))
        print("  FAILED suite raised: %r" % (e,))

    if _ran != CASES and not _fails:
        _fails.append("ran %d of %d cases" % (_ran, CASES))
    if _fails:
        print("SELF-TEST FAIL: units %d of %d case(s) failed, %d ran" % (len(_fails), CASES, _ran))
        return 1
    print("SELF-TEST PASS: units %d of %d cases - a per-pound rate never prices an each commodity, "
          "and a multi-pack is divided by its pack" % (_ran, CASES))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(run())
    print("usage: units_selftest.py --selftest")
    sys.exit(2)
