# Blind accuracy review protocol

`blind-cell-v1` measures a published board independently of the matcher and release guards that produced it.
The draw first freezes a release and 100 stratified store/commodity cells. Reviewers receive immutable source
facts but not engine scores, winner reasoning, or guard outcomes.

## Verdicts

- `right`: the captured product is the stated commodity, its package and price basis are internally compatible,
  and any available shelf taxonomy does not contradict the match.
- `wrong`: the product is a different commodity or a material product, package, price, or basis fact is false.
- `cannot_tell`: the frozen facts are ambiguous or conflict and an official source cannot resolve the conflict.

A missing product URL is not automatically `cannot_tell` when the frozen product name, package, price, and
taxonomy unambiguously establish the cell. A URL slug alone is never sufficient. When a source URL is present,
the reviewer uses the official retailer page for suspicious, conflicting, or unusually low cells. A page that
requires a current store context is compared only with the same location and price mode captured by the batch.

Every verdict records the protocol version, reviewed fields, method, rationale, frozen release, and official
source details when used. `cannot_tell` is excluded from the Wilson denominator. Findings are fixed through the
normal authored-config, rematch, guarded-release, and Ghost-reconciliation path; the sampled release itself is
never rewritten.

The weekly draw is complete only when every sampled ordinal has a verdict. Missing the seven-day deadline opens
a hard triage incident. Status reports the observed accuracy and standard 95% Wilson interval for the latest
completed draw.

## Capture-time semantic protections

Starting at `2026-08-12T05:00:00Z`, direct captures preserve a verified product identity bundle wherever the
source exposes stable identifiers, enforce a per-source identity-coverage floor, and preserve explicit offer
semantics for every accepted observation. Browser captures additionally attest visible page state for
every row and independently repeat all deterministic risk targets. API/fresh-catalog captures bind the active
logical field paths and non-null value types into separate semantic-contract and full-shape fingerprints.

Before a batch can validate, hard guards compare stable identifiers, price meaning, and the current API semantic
fingerprint with prior promoted truth. The history guard stops a fourfold price or package-basis discontinuity
for the same retailer product. A first schema fingerprint establishes a baseline; a later semantic-field drift
rejects the batch and opens triage, while unrelated optional-shape changes remain visible in evidence without
silently redefining the contract.
