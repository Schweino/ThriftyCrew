# WHICH ROW REPRESENTS A STORE for one commodity. Lives here as ONE function rather than inline at the
# ranker so -SelfTest exercises the rule the board actually runs; an inline sort can only be tested by
# transcribing it, and a transcribed test passes while the original regresses. Keys, in order:
#   1. per-unit price     - the whole point of the board; nothing below can make a cell dearer
#   2. can we link it     - 2026-08-22, an unlinkable row cannot be verified or re-found
#   3. smaller package    - 2026-08-31, a case pack ties its own single unit and must not beat it
#   4. product name       - a TOTAL order, so the winner is reproducible
#
# KEY 4 IS NOT DECORATION. The 2026-08-22 note above this rule reasoned "sorting is stable, so rows equal
# on both keys keep their previous relative order" - that is not true on this runtime. Windows PowerShell
# 5.1's Sort-Object is NOT a stable sort and has no -Stable parameter (that arrived in PowerShell 6), so
# rows equal on every key came out in an arbitrary order that could differ run to run on the same input.
# Caught while proving the key-3 fixture must-fire: with key 3 removed the case-pack test still PASSED,
# because the winner was being decided by luck rather than by any rule. A board cell has to be
# reproducible, so the comparison ends on something total.
function Select-StoreWinner($rows) {
  $rows |
    Sort-Object @{Expression = { $_.unit_price }},
                @{Expression = { if ($_.has_identity) { 0 } else { 1 } }},
                @{Expression = { $s = Get-PackOz $_.size_text $_.name; if ($null -eq $s -or $s -le 0) { [double]::MaxValue } else { [double]$s } }},
                @{Expression = { [string]$_.name }} |
    Select-Object -First 1
}
# WHICH STORE WEARS THE CROWN when two stores' winners cost the SAME per unit (2026-09-19, backlog I175).
# This was `$byStore | Sort-Object unit_price`, and 5.1's Sort-Object is not stable, so a cross-store tie was
# decided by the sort's internals. Measured on comparison-2026-09-17: 22 of 572 commodities had rank 1 and
# rank 2 at an exactly equal per-unit price, and on 2 of them (collard-greens, rhubarb) reversing the input
# order alone changed cheapest_store. Keys, in order:
#   1. per-unit price  - unchanged, so no cell's price and no genuinely cheaper crown can move
#   2. no membership   - a tie never sends a reader to a store they must pay to shop at
#   3. store name      - a TOTAL order (store names are distinct), so the crown is reproducible
function Select-CrossStoreRank($winners) {
  @($winners |
    Sort-Object @{Expression = { $_.unit_price }},
                @{Expression = { if ($_.membership) { 1 } else { 0 } }},
                @{Expression = { [string]$_.store }})
}
