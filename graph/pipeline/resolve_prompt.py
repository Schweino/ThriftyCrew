"""The resolver's layer-5 prompt text, split out of resolve.py (file-size budget, 2026-09-29).

resolve.py re-imports both names; PROMPT_VERSION stays in resolve.py and is bumped on ANY change
to RESOLVE_SYSTEM or _resolve_user.
"""
from __future__ import annotations


# The live layer-5 system prompt, resolve.PROMPT_VERSION. A scorer may pass `system=` to
# build_resolve_prompt (Resolver(system_prompt=...)) to try a CANDIDATE without editing this text
# (graph/bench/hillclimb_prompt.py, W5 of design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md);
# promoting one is a reviewed commit that edits THIS constant and bumps PROMPT_VERSION.
RESOLVE_SYSTEM = (
        "You adjudicate whether a grocery store's product listing IS a given "
        "commodity on an Omaha price-comparison board.\n\n"
        "DOMAIN RULES (this board's semantics, not general knowledge):\n"
        "- The board prices PACKAGED RETAIL PRODUCTS. A branded, packaged item is "
        "a valid instance of a commodity. 'Jennie-O Ground Turkey 16oz' IS ground turkey.\n"
        "- Store brands and national brands both count. Brand is never a reason to reject.\n"
        "- Package SIZE is never a reason to reject; the board normalises per unit.\n"
        "- REJECT when the product is a different FOOD, a different CUT or GRADE than "
        "the commodity names, a prepared/cooked form when the commodity is raw, or a "
        "non-food item that merely mentions the food.\n"
        "- A variety difference IS a rejection when the commodity names the variety "
        "(Deglet Noor dates are NOT Medjool dates; 93/7 turkey is not 85/15).\n\n"
        "BIAS: prefer a missed match over a false one. If the listing is ambiguous, "
        "answer UNSURE rather than guessing — a wrong MATCH publishes a wrong price.\n"
        "Cite the specific words that decide it. Output JSON only."
)


def _resolve_user(cc: CompiledCommodity, product_name: str, examples: dict | None,
                  inc: list) -> str:
    parts = [f"COMMODITY: {cc.label}",
             f"sold by: {cc.unit or 'unspecified'}",
             f"known surface patterns: {inc}"]

    # PRIOR RULINGS — this estate's own labelled history for THIS commodity.
    #
    # Until 2026-08-20 the model judged blind: it got the include patterns and
    # nothing else, while the human review packet for the same question carried
    # the excludes, the confirmed siblings and the known-wrong list. We were
    # teaching the reviewer and starving the model, with 2,551 adjudicated
    # rejections sitting unused (43 of them on powdered-sugar alone).
    #
    # These are not hints, they are decisions this board already made, and the
    # model's measured weakness is exactly the one they address: it asserts
    # MATCH on adjacent products at 0.95+ confidence. Showing it the adjacent
    # products that were already ruled out is the cheapest correction available,
    # and it costs no training run - the labels exist.
    #
    # WHOSE rulings (v5, 2026-08-22, plan section 3.1). v4 showed every banked
    # ruling, and 90% of them were the model's OWN unreviewed rejections - so
    # "already ruled" meant "you said so last week", and a wrong rejection
    # recruited its neighbours. Only ADJUDICATED rulings now speak with the
    # board's authority. Model-consensus rulings (helper + LLM, plan section 4)
    # appear in a separate list labelled tentative, so the model can weigh them
    # without mistaking them for decisions. Single-model rulings appear nowhere.
    # See graph/lib/authority.py and Resolver.prior_rulings.
    if examples:
        rejected = examples.get("rejected") or []
        confirmed = examples.get("confirmed") or []
        t_rejected = examples.get("tentative_rejected") or []
        t_confirmed = examples.get("tentative_confirmed") or []
        if rejected:
            parts.append("\nALREADY RULED **NOT** THIS COMMODITY by an adjudicator "
                         "(do not repeat these mistakes):")
            parts += [f"  - {r!r}" for r in rejected]
        if confirmed:
            parts.append("\nALREADY RULED **YES** by an adjudicator - this is what "
                         "belonging looks like:")
            parts += [f"  - {c!r}" for c in confirmed]
        if t_rejected or t_confirmed:
            parts.append("\nTENTATIVE, machine-only and NOT reviewed by an "
                         "adjudicator. Weigh these; they are not decided:")
            parts += [f"  - probably NOT this commodity: {r!r}" for r in t_rejected]
            parts += [f"  - probably IS this commodity: {c!r}" for c in t_confirmed]
    parts.append(f"\nSTORE PRODUCT LISTING: {product_name!r}\n")
    parts.append("Is this listing that commodity?")
    return "\n".join(parts)
