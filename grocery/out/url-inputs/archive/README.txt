ARCHIVED 2026-07-29.

merge-product-urls.ps1 folds every out\url-inputs\store-*-urls.json into product-urls.json on EVERY run.
These two were snapshots from earlier pulls whose link prices no longer match the board, so every merge
silently re-injected them. Concretely: on 2026-07-29 the Fareway file re-created ~40 links that quote a PACK
price where the board holds a per-unit one - hamburger buns board \.166/each vs link \.88 for the 8-pack,
dryer sheets \.0328 vs \.94 a box, facial tissues \.0186 vs \.99 - which guards.ps1 reads as 24x, 100x
and 120x factor mismatches and refuses to publish. Reverting product-urls.json cleaned it; the very next
merge brought all of them straight back. That is the trap grocery-browser-exfil already warned about
("ARCHIVE the store-*-urls.json out of url-inputs - two stale fareway/ff files were silently re-merging
every run"), still live months later.

Nothing is lost. product-urls.json already holds the merged, PRUNED result (365 Fareway, 331 Family Fare
links, every one re-priced through the same lib prune-bad-links uses), and build-fareway-regular.ps1
regenerates store-fareway1-urls.json from the NEXT Fareway pull with that pull's own price+size - so the
input file self-heals against a current board instead of dragging a stale one forward.

RULE: a store-*-urls.json is an INPUT for one pull, not a standing source. Archive it once it has been
merged, or it will keep resurrecting links the board has moved past.
