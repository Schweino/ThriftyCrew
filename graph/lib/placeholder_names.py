"""Capture-time rejection of TEST/PLACEHOLDER product names.

A store's own catalog occasionally carries a vendor's test listing as a real,
priced, purchasable row. `Test Id 1 Homekist Fudge Grahams` (Walmart item
105676485) is the case that produced this module: it came off a real Omaha
search page at $2.26, its visible card price agreed with the __NEXT_DATA__
line price, it survived the marketplace-seller filter and the engine
unit-price check, and it landed on commodity:staple:graham-crackers with
confidence 1.0. Every price guard we own passed it, because nothing about the
price was wrong. Only the NAME was, and only a human in the confirm-match
review caught it.

So the control has to be a NAME control, and it has to run at capture time —
at the moment a row is turned into a PriceObservation — not in review. A row
rejected here never becomes a pricing candidate, never reaches a reviewer, and
never has a chance to crown a cell.

The patterns live in grocery/placeholder-name-patterns.json so that this module
and the PowerShell lane (capture-lib.ps1) reject exactly the same names. See
that file for the rule on what may be added: structural patterns only. A bare
`\btest\b` would eat America's Test Kitchen; a bare `xxx` would eat
vitaminwater XXX and Melinda's XXXX Reserve habanero - all real, priceable
products already sitting in our captures.

Run this file directly to execute the round-trip self-test:
    C:/Codex/Python312/python.exe graph/lib/placeholder_names.py
"""

from __future__ import annotations

import json
import os
import re

_HERE = os.path.dirname(os.path.abspath(__file__))
LIBRARY = os.path.normpath(os.path.join(_HERE, "..", "..", "grocery",
                                        "placeholder-name-patterns.json"))

_compiled: list[re.Pattern] | None = None


def _load() -> list[re.Pattern]:
    global _compiled
    if _compiled is None:
        with open(LIBRARY, encoding="utf-8") as fh:
            lib = json.load(fh)
        # A malformed pattern must be loud, not silently skipped: this library is
        # a guard, and a guard that quietly drops half its rules is worse than no
        # guard at all.
        _compiled = [re.compile(p, re.IGNORECASE) for p in lib["patterns"]]
    return _compiled


def is_placeholder_name(name) -> bool:
    """True if `name` reads as vendor test/placeholder data rather than a product.

    A missing or empty name is NOT a placeholder — callers already have their own
    handling for nameless rows, and answering True here would quietly reroute
    those into the placeholder counter and hide them.
    """
    if not name:
        return False
    text = str(name)
    return any(p.search(text) for p in _load())


def _self_test() -> int:
    with open(LIBRARY, encoding="utf-8") as fh:
        lib = json.load(fh)
    fails = 0
    for n in lib["must_match"]:
        if not is_placeholder_name(n):
            print(f"FAIL  should be rejected but passed: {n}")
            fails += 1
    for n in lib["must_not_match"]:
        if is_placeholder_name(n):
            hit = [p.pattern for p in _load() if p.search(n)]
            print(f"FAIL  real product rejected by {hit}: {n}")
            fails += 1
    for edge in (None, "", 0):
        if is_placeholder_name(edge):
            print(f"FAIL  empty input treated as placeholder: {edge!r}")
            fails += 1
    total = len(lib["must_match"]) + len(lib["must_not_match"])
    if fails:
        print(f"{fails} FAILED of {total}")
    else:
        print(f"placeholder_names: all {total} self-tests pass "
              f"({len(lib['patterns'])} patterns)")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(_self_test())
